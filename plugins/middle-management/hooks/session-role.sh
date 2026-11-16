#!/usr/bin/env bash
# middle-management plugin — UserPromptSubmit hook (and SessionStart after a compaction or /clear).
# Consumers: hooks/hooks.json (UserPromptSubmit registration; SessionStart, matcher compact|clear,
# re-prints the full text). Writes one stamp per session under <config dir>/state/session-role/
# ("full once, short after", bottom of this file). Reads the coordinator
# marker written by scripts/orchestrator.sh; resolves every path through
# scripts/config-check.sh; runs scripts/open-items.py count in the coordinator branch. Reads the
# T3 sidecar <marker dir>/orchestrator.t3.json (written by scripts/orchestrator.sh t3-bind) for the
# T3 lines; never its reportUrl. Reads the config key quietReports.enabled (README "Quiet reports")
# for the coordinator's report line, and handoverTokens / handoverWarnTokens for its hand-over and
# warn lines (runs scripts/peer-state.py --ctx on the hook input's transcript_path; skipped for a
# prompt that is exactly "Keepalive", as scripts/t3-inbox.py tests it).
#
# Exactly ONE session coordinates, every other session is a worker. Two sources for
# "who coordinates", in this order:
#   1. The marker file <config dir>/state/orchestrator (a sessionId), written by
#      scripts/orchestrator.sh claim. The route for editor sessions, whose tab title
#      never reaches the session registry.
#   2. Fallback: a living session whose peer name starts with "orch"
#      (started as `claude -n orchestrator`). The route for terminal sessions.
# If neither finds a living coordinator, this hook stays SILENT — the regime is off and
# every session works standalone. The role messages below ARE the behavioral contract, printed
# in full once per session and role, as a short hint after that; the skill "middle-management"
# carries the full text as its reference.
# Alive = a registry entry with kind "interactive" whose pid answers kill -0. On the marker
# route the sessionId is the identity and .name is display only; scripts/orchestrator.sh
# follows the same rule (liveness rule F1).
# With a "scopes" key in the config (README "Scopes") the marker, the board and the session list
# are those of this session's scope, resolved by scripts/scope.py from its registry cwd. With
# "scopeMode": "per-root" every project root is a scope, and a session outside all of them
# (scope "none") is standalone: no banner.
set -u

PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
CHECK="$PLUGIN_ROOT/scripts/config-check.sh"

CFG_DIR="$(bash "$CHECK" dir)"
CFG_FILE="$(bash "$CHECK" file)"
REG="$CFG_DIR/sessions"
MARKER="$CFG_DIR/state/orchestrator"
OVERRIDE="$CFG_DIR/state/allow-main-checkout-edits"

# The override nag comes first and needs no jq: a forgotten marker silently disarms the
# checkout guard for every session on this machine. -e, not -f — the guard
# (hooks/protect-main-checkouts.sh) tests -e, so a marker created as a directory disarms it too.
[ -e "$OVERRIDE" ] && printf 'middle-management: override marker active — main-checkout guard is OFF; delete %s when the exception is done\n' "$OVERRIDE"

command -v jq >/dev/null 2>&1 || {
  echo "middle-management: jq not installed — plugin inactive (install jq)"; exit 0; }

[ -d "$REG" ] || {
  echo "middle-management: session registry not found — role detection inactive (requires a recent Claude Code)"
  exit 0; }

# --- preconditions: warn loudly, then carry on with the role logic ---------------
bash "$CHECK" validate; CFG_STATE=$?
# Initialised BEFORE the branches: a roles-only install has no config file (CFG_STATE 2) and
# this hook runs under `set -u` — an unset variable below would abort every message.
BOARD=""
NOTIFY=""
if [ "$CFG_STATE" -eq 1 ]; then
  printf 'middle-management: %s is invalid — worktree guard and wt are DISARMED and blanket-staging protection is forced ON until fixed (run /middle-management-setup)\n' "$CFG_FILE"
elif [ "$CFG_STATE" -eq 0 ]; then
  BOARD=$(jq -r '.board // ""' "$CFG_FILE" 2>/dev/null)
  NOTIFY=$(jq -r '.notifyCommand // ""' "$CFG_FILE" 2>/dev/null)
  jq -r '.protectedCheckouts[]? | [.name, .root] | @tsv' "$CFG_FILE" 2>/dev/null \
    | while IFS=$'\t' read -r pc_name pc_root; do
        [ -d "$pc_root" ] || printf 'middle-management: protected checkout "%s" points at %s, which is not a directory — that entry is inert (run /middle-management-setup)\n' "$pc_name" "$pc_root"
      done
fi
# --- role detection ---------------------------------------------------------------
# Stdin is read once: the sessionId, the transcript for the coordinator's hand-over line, and
# whether the prompt is a bare Keepalive (a liveness ping starts no task: no token line).
# A SessionStart call (hooks.json, after a compaction or /clear) carries a "source": it prints the
# full text and never a token line (no task starts there).
{ read -r MY_ID; read -r MY_TP; read -r MY_KA; read -r MY_SRC; } < <(jq -r '.session_id // "", .transcript_path // "",
  ((.prompt // "") | strings | gsub("^\\s+|\\s+$"; "") == "Keepalive"), (.source // "" | strings)' 2>/dev/null)
MY_ID=${MY_ID:-}; MY_TP=${MY_TP:-}; MY_KA=${MY_KA:-false}; MY_SRC=${MY_SRC:-}

# cwd<TAB>name<TAB>sessionId of every living interactive session. The (possibly empty) name comes
# LAST in the jq array: `read` with a tab IFS collapses empty fields, so a nameless session would
# otherwise get its sessionId in the name column and no id at all (found 04.09.2026, case F1).
# The cwd column is never empty ("-") for the same reason.
RAW=$(cat "$REG"/*.json 2>/dev/null \
  | jq -r 'select(.pid and .sessionId and .kind == "interactive")
      | [.pid, .sessionId, (.cwd | if type == "string" and . != "" then . else "-" end), .name // ""] | @tsv' 2>/dev/null \
  | while IFS=$'\t' read -r pid sid cwd name; do
      kill -0 "$pid" 2>/dev/null && printf '%s\t%s\t%s\n' "$cwd" "$name" "$sid"
    done)
# LIVE = name<TAB>sessionId: every session, or with scopes only those of this session's scope (by
# the directory each was started in). A failing resolver fails closed: no banner, never a wrong one.
SCOPE=""; OF=""; PS_SCOPE=""
if [ -n "$RAW" ] && jq -e '([.scopes | arrays | .[]] | length > 0) or (.scopeMode == "per-root")' "$CFG_FILE" >/dev/null 2>&1; then
  MY_CWD=$(printf '%s\n' "$RAW" | awk -F'\t' -v id="$MY_ID" '$3==id{print $1; exit}')
  S=$(python3 "$PLUGIN_ROOT/scripts/scope.py" of "$MY_CWD" 2>/dev/null) \
    && LIVE=$(printf '%s\n' "$RAW" | python3 "$PLUGIN_ROOT/scripts/scope.py" filter "${S%%$'\t'*}" 2>/dev/null) \
    || { printf 'middle-management: scopes are configured but %s/scripts/scope.py failed (python3?), no role this message; fix it or remove the scopes key (/middle-management-setup)\n' "$PLUGIN_ROOT"; exit 0; }
  IFS=$'\t' read -r SCOPE SDIR BOARD <<<"$S"
  [ "$SCOPE" = none ] && exit 0      # per-root: outside every project root = standalone
  MARKER="$SDIR/orchestrator"; OF=" of scope $SCOPE"; PS_SCOPE=" --scope $SCOPE"
else
  LIVE=$(printf '%s\n' "$RAW" | cut -f2-)
fi
[ -z "$LIVE" ] && exit 0

name_of() { printf '%s\n' "$LIVE" | awk -F'\t' -v id="$1" '$2==id{print $1; exit}'; }

ORCH=""; ORCH_ID=""; ORCH_SRC=""; STALE=""
# T3 Code (plan 1.1, 1.5): the seat's thread binding. side reads a field, never reportUrl.
SIDE="$(dirname "$MARKER")/orchestrator.t3.json"
side() { jq -r "$1" "$SIDE" 2>/dev/null; }
SIDE_SID=""; [ -f "$SIDE" ] && SIDE_SID=$(side '.sessionId // empty')
T3T=$(side '"T3 thread \"\(.title // "?")\" (\(.threadId // "?"))"')
if [ -f "$MARKER" ]; then
  MID=$(head -1 "$MARKER" | tr -d '[:space:]')
  if [ -n "$MID" ]; then
    # alive = the id is in LIVE (not: it has a name) — a nameless coordinator is still one
    if printf '%s\n' "$LIVE" | cut -f2 | grep -qxF "$MID"; then
      ORCH_ID="$MID"; ORCH="$(name_of "$MID")"; ORCH_SRC="marker"
    # Asleep is not gone (plan 1.5): T3 ended the idle coordinator's process, its thread still wakes
    # on every message, so this is not a stale seat and nobody is offered its release.
    elif [ -n "$SIDE_SID" ] && [ "$SIDE_SID" = "$MID" ]; then
      ORCH_ID="$MID"; ORCH="asleep"; ORCH_SRC="t3"
    else STALE=1; fi
  fi
fi

NAMED=$(printf '%s\n' "$LIVE" | cut -f1 | grep -i '^orch' | sort -u)
NAMED_COUNT=$(printf '%s' "$NAMED" | grep -c .)

if [ -z "$ORCH_SRC" ]; then
  if [ "$NAMED_COUNT" -eq 0 ]; then
    # Both exits, with a human gate: this hint fires in EVERY living session.
    [ -n "$STALE" ] && printf 'middle-management: the coordinator marker%s points at a session that is not visibly alive (%s) — until someone acts there is no coordinator. Workers keep working their lane, hold every outward coordination the regime routes through the coordinator (posts, tickets, pull requests, asks to the user), close their books when done or blocked, and report to whoever claims next. ONLY if your user wants THIS session to coordinate:\n  take over:   bash %s/scripts/orchestrator.sh claim\n  regime OFF:  bash %s/scripts/orchestrator.sh release %s   (the id is also printed by status)\nOtherwise ignore this.\n' "$OF" "$MID" "$PLUGIN_ROOT" "$PLUGIN_ROOT" "$MID"
    exit 0
  fi
  if [ "$NAMED_COUNT" -gt 1 ]; then
    printf 'SESSION ROLES BROKEN: %s sessions are named "orch*" (%s) and there is no coordinator marker.\n' \
      "$NAMED_COUNT" "$(printf '%s' "$NAMED" | tr '\n' ' ')"
    printf 'Tell your user before you send anything to another session.\n'; exit 0
  fi
  ORCH="$NAMED"; ORCH_SRC="name"
elif [ "$NAMED_COUNT" -ge 1 ] && ! printf '%s\n' "$NAMED" | grep -qxF "$ORCH"; then
  printf 'WARNING: the marker says the coordinator is "%s", but "%s" is also running under an orch* name.\n' \
    "${ORCH:-unnamed}" "$(printf '%s' "$NAMED" | tr '\n' ' ')"
  printf 'The marker wins. Tell your user that two coordinators are in the race.\n'
fi

MY_NAME=$(name_of "$MY_ID")
ROLE_L=""   # the worker's role line; it names the coordinator's liveness, so it stays out of the checksum

# Marker route: identity by sessionId. Name route: by name, but never an empty one.
if { [ "$ORCH_SRC" = marker ] && [ "$MY_ID" = "$ORCH_ID" ]; } \
   || { [ "$ORCH_SRC" = name ] && [ -n "$MY_NAME" ] && [ "$MY_NAME" = "$ORCH" ]; }; then
  # Hand-over line (config handoverTokens, default 300000, 0 = off; also switches the warn line off)
  # and warn line (handoverWarnTokens, default 250000, 0 = off, ignored unless below the mark): the
  # FIRST line of this branch, read when a task starts, so never for a Keepalive.
  # Fail soft: no transcript, no figure, a non-number key = no line, never a broken banner.
  HT=$(jq -r '(.handoverTokens // 300000) | numbers | floor' "$CFG_FILE" 2>/dev/null) || HT=300000
  HW=$(jq -r '(.handoverWarnTokens // 250000) | numbers | floor' "$CFG_FILE" 2>/dev/null) || HW=250000
  if [ "${HT:-0}" -gt 0 ] && [ "$MY_KA" != true ] && [ -z "$MY_SRC" ] && [ -n "$MY_TP" ] \
     && CTX=$(python3 "$PLUGIN_ROOT/scripts/peer-state.py" --ctx "$MY_TP" 2>/dev/null) \
     && [[ "$CTX" =~ ^[0-9]+$ ]]; then
    if [ "$CTX" -ge "$HT" ]; then
      if [ -n "${T3CODE_HOME:-}" ]; then
        HOW='launch the successor (t3_thread_launch), then orchestrator.sh t3-handover --to-thread <id> --to-title <title>.'
      else
        HOW='ask your user for a fresh session, send it the path to your handoff doc, release the seat; it claims (middle-management skill, handover).'
      fi
      if [ "$CTX" -ge $((2 * HT)) ]; then HO_TAIL=' Start nothing else first.'
      else HO_TAIL=' Only a very small task (one line, one answer, one settle) may still be done here first.'; fi
      printf 'CONTEXT %dk tokens, past the hand-over mark of %dk: hand over now — %s%s\n' \
        $((CTX / 1000)) $((HT / 1000)) "$HOW" "$HO_TAIL"
    elif [ "${HW:-0}" -gt 0 ] && [ "$HW" -lt "$HT" ] && [ "$CTX" -ge "$HW" ]; then
      printf 'CONTEXT %dk of %dk. Before you start this task: a big one (a new lane, a plan, an integration run, anything of several steps) → hand over first; a very small one (one line, one answer, one settle) → do it here.\n' \
        $((CTX / 1000)) $((HT / 1000))
    fi
  fi
  # FULL = the whole role text, SHORT = the hint for every later message, DYN = the lines whose
  # content changes per message (inbox count, worker list); see "full once" at the end.
  FULL=$(
  printf 'Session role: ORCHESTRATOR%s ("%s", by %s). You plan with your user and route the work —\n' \
    "$OF" "${MY_NAME:-unnamed}" "$([ "$ORCH_SRC" = marker ] && echo marker || echo name)"
  printf 'you do NOT build yourself. Directly allowed: planning/decision docs, chat/GitHub coordination,\n'
  printf 'tasking workers and sub-agents. NOT yourself: product/repo code, repo git surgery, builds/tests —\n'
  printf 'delegate those. Small clear jobs (one-file fix, research, mechanical sweep) go to a sub-agent in\n'
  # Who starts a lane: the coordinator itself where the host lets it, the user only where it cannot.
  if [ -n "${T3CODE_HOME:-}" ]; then LAUNCH='start it yourself (t3_thread_launch) and name its model'
  else LAUNCH='start it yourself where your host lets you, else ask your user to open one and name the model'; fi
  printf 'THIS session; larger packages go to worker sessions: %s.\n' "$LAUNCH"
  printf 'Fallback where only your user can start one: a package that is clear AND uncritical and only waits\n'
  printf 'for that session — do not wait for hours; run it via sub-agent with the recommended option and record the decision.\n'
  printf 'You are the only session that connects workers — what worker A finds and worker B needs\n'
  printf 'flows through you — and you track who works on what.\n'
  printf 'Resource hygiene is YOUR job: orphaned dev servers, worktrees of merged branches and stale\n'
  printf 'watchers go as soon as their reason is gone (sub-agent, by verified PID lineage, never by\n'
  printf 'pattern) — not when memory runs out. Morning ritual, step 5.\n'
  printf 'Stopping a lane unit and removing its merged, clean, pushed worktree is housekeeping, not\n'
  printf 'destruction — done unasked, at the merge: a lane'"'"'s pull request is merged -> in the same turn stop\n'
  printf 'its unit, remove its worktree (/wt <name> done <topic>%s), delete its branch, and put the\n' \
    "$([ -n "${T3CODE_HOME:-}" ] && echo '; a T3 worktree once its thread is settled')"
  printf '/wt list line into your report. Dirty, unpushed or unmerged: it stays and goes to your user.\n'
  if [ -n "${T3CODE_HOME:-}" ]; then
    printf 'A lane that reports done and wrapped: settle its thread and its sub-agent threads in the same turn\n'
    printf '(t3_thread_organize settle, or t3-settle.py: morning-ritual step 3), after checking it left nothing\n'
    printf 'loose. Sweep for finished, unsettled threads when you take the seat, after every wrap and before you hand over.\n'
    printf 'Your user sees only the last text of a turn they started: bookkeeping first, answer last; reports handled\n'
    printf 'after the answer mean the full answer again as the last text, never a one-line addendum. What arises in a\n'
    printf 'turn a worker report or a wake started is restated in their next turn.\n'
  fi
  if [ -n "${T3CODE_HOME:-}" ]; then
    if [ "$SIDE_SID" = "$MY_ID" ]; then
      printf 'T3 Code: your seat is bound to %s, report task %s. Worker reports arrive by\n' "$T3T" "$(side '.reportTaskId // "?"')"
      # the same test as hooks/t3-report.sh and scripts/t3-watch.py: an otherwise invalid config switches it too
      if jq -e '.quietReports.enabled == true' "$CFG_FILE" >/dev/null 2>&1; then
        printf 'themselves (their Stop hook), quiet mode: a turn of their own only while you sleep or for a READY / blocked /\n'
        printf 'question, digested. Worker reports may arrive inside your turn as "Worker reports (quiet)"; handle them in the\n'
        printf 'turn you are in, do not open a chat reply per report. Task or ask a worker with t3_thread_send <its thread id>\n'
      else
        printf 'themselves as turns of this thread (their Stop hook). Task or ask a worker with t3_thread_send <its thread id>\n'
      fi
      printf '(that wakes it, also after settle); never peer-message or poke a T3 thread, and do not t3_thread_wait after\n'
      printf 't3_thread_send: the answer comes by itself. After a model or effort change: a NEW report task from this\n'
      printf 'thread, t3-bind it, delete_scheduled_task the old one (a re-save keeps the old model). Handover: launch the\n'
      printf 'successor thread, then orchestrator.sh t3-handover --to-thread <id> --to-title <t>; keep seat and report task\n'
      printf 'until it claims. Once a wake "seat taken over by ..." arrives you are a worker: forward every report that\n'
      printf 'still reaches you to the successor with t3_thread_send, finish your wrap, delete your report task last.\n'
      printf 'Book every worker report that is not in the topics state yet, and every answer or OK of your user:\n'
      printf 'python3 "%s/scripts/topics.py" entry --topic <key> ... or answer --topic <key> "<text>".\n' "$PLUGIN_ROOT"
      printf 'A message that is exactly "Keepalive": answer exactly "OK" and nothing else.\n'
    else
      printf 'T3 Code: this seat has no thread binding yet, so no worker report reaches you. Create the report task\n'
      printf 'and run orchestrator.sh t3-bind (/orchestrator, T3 branch).\n'
    fi
  fi
  if [ -n "$SCOPE" ]; then
    printf 'Scope %s: your workers, your board and your cleanup are this scope'"'"'s only. Other scopes\n' "$SCOPE"
    printf 'have their own coordinator; you may message that coordinator directly about anything that\n'
    printf 'crosses scopes, never its workers, and you never stop their servers or remove their worktrees.\n'
  fi
  printf 'One lane = one session: a new lane gets a FRESH session — %s;\n' "$LAUNCH"
  printf 'never stack a second lane into a running session (exception: after ~30 minutes of\n'
  printf 'silence from your user, and only for safe, reversible work). A wrapped session is closed for\n'
  printf 'good. After every wrap, run python3 "%s/scripts/peer-state.py" --wrapped%s and hand\n' "$PLUGIN_ROOT" "$PS_SCOPE"
  printf 'your user the tab list it prints: topic, idle age and the last line each session wrote — the\n'
  if [ -n "${T3CODE_HOME:-}" ]; then
    printf 'text at the bottom of that tab, which is how your user finds it (in T3: run the settle check,\n'
    printf 'morning-ritual step 3, and settle instead). NEVER peer-message a session\n'
  else
    printf 'text at the bottom of that tab, which is how your user finds it. NEVER peer-message a session\n'
  fi
  printf 'that reads as wrapped, and read state off disk before messaging one idle a while: the message\n'
  printf 'makes that session re-pay its ENTIRE context in fresh input tokens.\n'
  printf 'The same reader with --waiting%s lists sessions WAITING on their user: "permission" = MAY be parked\n' "$PS_SCOPE"
  printf 'on a permission prompt (a long-running tool reads the same), "question" = its last turn asks\n'
  printf 'something. Do not message such a session; check the tab'"'"'s last line (peer-state.py\n'
  printf -- '--session-id) before telling your user which tab and why.\n'
  printf 'Every waiting item you put in front of your user carries its link or command line in the SAME\n'
  printf 'line, at every repetition — a reminder they have to scroll for is worthless.\n'
  printf 'After a re-wake or a resume: work the RE-WAKE checklist (top of the board, or the last checklist\n'
  printf 'in your own transcript) before any new task.\n'
  printf 'Sub-agents write long results to a FILE and return you at most ten lines; the file path goes\n'
  printf 'where you track lanes. Your context is for decisions and routing, not raw material — put that\n'
  printf 'instruction in every sub-agent prompt you write.\n'
  printf 'Every sub-agent you announce to your user names its model and whether the strongest model was\n'
  printf 'needed or a cheaper one suffices; briefs name model and effort per role. Cheapest plausible\n'
  printf 'model first, escalate after two failed attempts, never a third try on the same one.\n'
  [ -n "$NOTIFY" ] && printf 'Your off-keyboard channel to your user is configured (notifyCommand): use it for what must reach\nthem away from the desk — plain text, one topic, the fact first. The skill has the call.\n'
  [ -n "$BOARD" ] && printf 'You are the sole writer of the board %s; workers read it and report to you.\n' "$BOARD"
  )
  SHORT=$(
  printf 'Session role: ORCHESTRATOR%s ("%s", by %s). You plan with your user and route the work; you do not build: lanes go to worker sessions, small clear jobs to a sub-agent.\n' \
    "$OF" "${MY_NAME:-unnamed}" "$([ "$ORCH_SRC" = marker ] && echo marker || echo name)"
  # One line for the event duties: the T3 part only where the full text has it.
  printf 'At events: %sa lane'"'"'s pull request is merged → clean up its lane in the same turn; a task starts → check your tokens.\n' \
    "$([ -n "${T3CODE_HOME:-}" ] && echo 'a lane reports done and wrapped → settle it and its sub-agent threads; ')"
  if [ -n "${T3CODE_HOME:-}" ]; then
    printf 'Your user sees only the last text of a turn they started: bookkeeping first, answer last, never a one-line addendum; restate in their next turn what arose in a turn a worker report or a wake started.\n'
    if [ "$SIDE_SID" = "$MY_ID" ]; then
      printf 'T3 Code: your seat is bound to %s, report task %s; worker reports arrive by themselves%s. A message that is exactly "Keepalive": answer exactly "OK" and nothing else.\n' \
        "$T3T" "$(side '.reportTaskId // "?"')" "$(jq -e '.quietReports.enabled == true' "$CFG_FILE" >/dev/null 2>&1 && echo ' (quiet mode)')"
    else
      printf 'T3 Code: this seat has no thread binding yet, so no worker report reaches you: create the report task and run orchestrator.sh t3-bind (/orchestrator, T3 branch).\n'
    fi
  fi
  )
  DYN=$(
  # The open-items inbox: one python run, silent at 0. A failed count must not read as "inbox empty",
  # so it prints one fallback line instead (no traceback); the prompt never fails.
  CLAUDE_CODE_SESSION_ID="$MY_ID" python3 "$PLUGIN_ROOT/scripts/open-items.py" count 2>/dev/null \
    || printf 'Open-items inbox: the count failed; run python3 "%s/scripts/open-items.py" list\n' "$PLUGIN_ROOT"
  printf 'Current workers: %s\n' "$(printf '%s\n' "$LIVE" | cut -f1 | grep -vxF "$ORCH" | tr '\n' ' ')"
  )
else
  # Worker: the role line and the report channel go into both texts; HANDED is dynamic state.
  DYN=""; HANDED=""
  if [ -n "$SIDE_SID" ] && [ "$SIDE_SID" = "$ORCH_ID" ]; then
    # The coordinator lives in a T3 thread: named by thread title + id, not by its changing peer name.
    if [ "$ORCH_SRC" = t3 ]; then
      ROLE_L=$(printf 'Session role: WORKER%s ("%s"). The coordinator is asleep in %s; it is not gone, the next report wakes it.' "$OF" "${MY_NAME:-unnamed}" "$T3T")
    else
      ROLE_L=$(printf 'Session role: WORKER%s ("%s"). The coordinator is %s ("%s").' "$OF" "${MY_NAME:-unnamed}" "$T3T" "${ORCH:-unnamed}")
    fi
    if [ -n "${T3CODE_HOME:-}" ]; then
      CHAN_F=$(printf 'Your report = the last text of your turn: the Stop hook delivers it to the coordinator. Never SendMessage\n'
      printf 'or poke a T3 coordinator, never message other workers. Tools first, report last: only the final text\n'
      printf 'block of a turn arrives. If the hook says "report NOT delivered", send it yourself with t3_thread_send.\n'
      printf 'Book every READY / LIVE / blocked / question report first (key = lane dir or branch, the first entry creates it):\n'
      printf 'python3 "%s/scripts/topics.py" entry --status <s> [--stage ready|live] [--waits-on "user · <q> · rec: <r>"] "<headline>"\n' "$PLUGIN_ROOT"
      printf 'A message that is exactly "Keepalive": answer exactly "OK" and nothing else.')
      CHAN_S='Your report = the last text of your turn (the Stop hook delivers it); never SendMessage or poke a T3 coordinator, never message other workers. A message that is exactly "Keepalive": answer exactly "OK" and nothing else.'
    else
      CHAN_F=$(printf 'Peer messages are not the report channel to a T3 thread. Report with: bash "%s/scripts/t3-wake.sh" "%s" <file with the report>\n' "$PLUGIN_ROOT" "${MY_NAME:-worker}"
      printf '(exit 0 = delivered); never message other workers.')
      CHAN_S=$(printf 'Report with: bash "%s/scripts/t3-wake.sh" "%s" <file with the report> (exit 0 = delivered); never message other workers.' "$PLUGIN_ROOT" "${MY_NAME:-worker}")
    fi
    if [ "$(side '.previous.sessionId // empty')" = "$MY_ID" ]; then
      HANDED=$(printf 'You handed the seat over: forward every report that still reaches you with t3_thread_send %s, finish\n' "$(side '.threadId // "?"')"
      printf 'your wrap, and delete your old report task (delete_scheduled_task %s) as its last step.' "$(side '.previous.reportTaskId // "?"')")
    fi
  else
    ROLE_L=$(printf 'Session role: WORKER%s ("%s"). The coordinator is "%s".' "$OF" "${MY_NAME:-unnamed}" "${ORCH:-unnamed}")
    CHAN_F=$(printf 'Peer messages go ONLY to "%s" — never to other workers; anything another session needs\n' "${ORCH:-unnamed}"
    printf 'goes through the coordinator. When you finish or block, report there yourself.')
    CHAN_S=$(printf 'Peer messages go ONLY to "%s", never to other workers; when you finish or block, report there yourself.' "${ORCH:-unnamed}")
  fi
  FULL=$(
  printf '%s\n%s\n' "$ROLE_L" "$CHAN_F"
  [ -n "$HANDED" ] && printf '%s\n' "$HANDED"
  printf 'You are the SUB-ORCHESTRATOR of your lane: plan review, build, diff review, screenshots and\n'
  printf 'report writing run in sub-agents with fresh context, each prompt naming its model and effort.\n'
  printf 'Every sub-agent writes long output to a FILE and returns you at most ten lines — up to twenty\n'
  printf 'when it carries a decision you must make. You read those reports, not whole files or diffs.\n'
  printf 'End every report to the coordinator with your rough context fill (1/4, 1/2, 3/4): a session\n'
  printf 'that reads everything itself is full within the hour and dies with its lane.\n'
  printf 'Your lane ends with its resources released: unit stopped, worktree removed (/wt <name> done\n'
  printf '<topic>), the /wt list line proving it in your wrap. Need the slot longer? /wt <name> hold.\n'
  [ -n "${T3CODE_HOME:-}" ] && printf 'A worktree under ~/.t3/worktrees/ belongs to T3: never /wt done or git worktree remove it.\n'
  [ -n "$BOARD" ] && printf 'The board %s is read-only for you — the coordinator is its only writer.\n' "$BOARD"
  )
  SHORT=$(
  printf '%s\n%s\n' "$ROLE_L" "$CHAN_S"
  [ -n "$HANDED" ] && printf '%s\n' "$HANDED"
  printf 'You are the SUB-ORCHESTRATOR of your lane: sub-agents do the work and return at most ten lines; end every report with your context fill.\n'
  )
fi
# Both roles wrap, so these lines live outside the branches — one copy, no drift.
TAIL=$(
printf 'Something for later (your user names it, a finding you will not fix, a promise you cannot keep here, work now waiting on someone): write it NOW, same turn: python3 "%s/scripts/open-items.py" add --owner user|coordinator|lane|external:<who> "<what> · next: <step> · src: <who, when> · <path>"\n' "$PLUGIN_ROOT"
# The closed-marker instruction is only actionable where a log exists or the user picked a path
# for one; on a machine with neither it was permanent noise (nothing says where to write it).
# Exit 0 from `session-log` = the path was CHOSEN ($MM_SESSION_LOG or the sessionLog key), so a
# configured-but-not-yet-created log still gets the instruction — that file is one wrap away.
SESSION_LOG="$(bash "$CHECK" session-log)"; LOG_CHOSEN=$?
if [ -f "$SESSION_LOG" ] || [ "$LOG_CHOSEN" -eq 0 ]; then
  printf 'Your wrap entry in the session log ends with one line: - Session: closed · %s\n' "${MY_ID:-<your sessionId>}"
  printf 'When finished: name yourself, your topic, then the literal line "Close this tab." alone at the very end, in every language (middle-management:wrap).\n'
else
  printf 'No session log yet — the middle-management:wrap skill creates it at %s (or set sessionLog via /middle-management-setup).\n' "$SESSION_LOG"
fi
)

# --- full once, short after -------------------------------------------------------------------
# The full text goes out at a session's first message, again whenever it changes (a claim or a
# release switches the role, a plugin update or a config change rewrites it) and again from the
# SessionStart call after a compaction or /clear (hooks.json, matcher compact|clear). Every other
# message gets SHORT plus DYN. The stamp <config dir>/state/session-role/<sessionId> holds the
# checksum of the full text without the worker's role line (a T3 coordinator flips between asleep
# and awake all day; SHORT carries the live line anyway) and with names masked (a T3 peer name
# changes with every wake). Fail soft:
# no usable sessionId, an unreadable or unwritable stamp, or MM_ROLE_FULL=1 = the full text.
# ponytail: one small stamp file per session, never pruned.
SUM_IN="$FULL$TAIL"
[ -n "$ROLE_L" ] && SUM_IN=${SUM_IN//"$ROLE_L"/}
[ -n "$ORCH" ] && SUM_IN=${SUM_IN//"$ORCH"/}
[ -n "$MY_NAME" ] && SUM_IN=${SUM_IN//"$MY_NAME"/}
SUM=$(printf '%s' "$SUM_IN" | cksum)
STAMP=""
[ "${MM_ROLE_FULL:-}" != 1 ] && [[ "$MY_ID" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] && STAMP="$CFG_DIR/state/session-role/$MY_ID"
if [ -n "$STAMP" ] && [ -z "$MY_SRC" ] && [ -n "$SUM" ] && [ "$(cat "$STAMP" 2>/dev/null)" = "$SUM" ]; then
  printf '%s\n' "$SHORT"
  printf 'Full rules: skill middle-management:middle-management (printed in full at your first message, after a role change and after a compaction). Something for later: write it NOW, python3 "%s/scripts/open-items.py" add.\n' "$PLUGIN_ROOT"
  [ -n "$DYN" ] && printf '%s\n' "$DYN"
else
  printf '%s\n' "$FULL"
  [ -n "$DYN" ] && printf '%s\n' "$DYN"
  printf '%s\n' "$TAIL"
  [ -n "$STAMP" ] && [ -n "$SUM" ] && { mkdir -p "${STAMP%/*}" && printf '%s\n' "$SUM" > "$STAMP"; } 2>/dev/null
fi
exit 0
