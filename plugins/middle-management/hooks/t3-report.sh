#!/usr/bin/env bash
# middle-management plugin: Stop hook, a session's report into its T3 coordinator (plan 1.3, D0).
# Consumers: hooks/hooks.json (Stop registration), tests/t3-report.sh, tests/morning-t3.sh (D).
#   Reads <seat dir>/morning-t3/status (scripts/morning-t3.sh). Calls scripts/t3-wake.sh (the
#   one sender), scripts/config-check.sh and, with scopes or scopeMode per-root, scripts/scope.py.
#
# Every session that is not the CURRENT coordinator (a worker, or a former coordinator after a
# takeover) sends the last text of each turn to the coordinator of its scope. Nothing happens unless:
# T3CODE_HOME is set (a T3 Code thread) · the scope has a sidecar <marker dir>/orchestrator.t3.json ·
# this session is not sidecar.sessionId · it is not today's morning thread before its claim · the text is not empty and not exactly "OK" (the answer to a
# Keepalive) · the turn is not an interim one while a sub-agent of this session runs (held, sent with
# the next turn that sends; see "Interim turn") · the text differs from the last one sent (sha256 in
# <cfg>/state/t3-report/<sessionId>).
# No stop_hook_active skip (review r1 F4): a turn continued after another Stop hook's block carries
# the real answer. A report that is not delivered is never silent: t3-wake.sh logs it to
# failures.log (the watcher notifies), and this hook blocks ONCE per text, never on a continuation,
# telling the session to send it itself. The reportUrl is never read or printed here.
set -u

PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
S="$PLUGIN_ROOT/scripts"
[ -n "${T3CODE_HOME:-}" ] || exit 0
command -v jq >/dev/null 2>&1 || { echo '{"systemMessage":"middle-management: jq is not installed, the T3 report hook cannot deliver this report"}'; exit 0; }

IN=$(cat)
SID=$(jq -r '.session_id // empty' <<<"$IN")
[ -n "$SID" ] || exit 0
CFG_DIR="$(bash "$S/config-check.sh" dir)"
CFG_FILE="$(bash "$S/config-check.sh" file)"

# The scope comes from the directory the session was STARTED in (its registry cwd), like the role
# banner; the hook input's cwd only when the registry has no entry.
START=$(cat "$CFG_DIR"/sessions/*.json 2>/dev/null \
  | jq -r --arg id "$SID" 'select(.sessionId == $id) | .cwd | strings' 2>/dev/null | head -1)
[ -n "$START" ] || START=$(jq -r '.cwd // empty' <<<"$IN")
SDIR="$CFG_DIR/state"
if jq -e '([.scopes | arrays | .[]] | length > 0) or (.scopeMode == "per-root")' "$CFG_FILE" >/dev/null 2>&1; then
  # ponytail: an unresolvable scope (git failed) sends nothing; t3-wake.sh fails closed the same way.
  L=$(python3 "$S/scope.py" of "$START" 2>/dev/null) || exit 0
  IFS=$'\t' read -r _ SDIR _ <<<"$L"
fi
SIDE="$SDIR/orchestrator.t3.json"
[ -f "$SIDE" ] || exit 0
COORD=$(jq -r '.sessionId // empty' "$SIDE" 2>/dev/null)
[ -n "$COORD" ] && [ "$COORD" != "$SID" ] || exit 0
# Morning takeover pending (README "Morning coordinator in T3 Code"): today's morning trigger started
# a thread (morning-t3.sh status "posted", not yet "claimed"/"refused" by claim --morning), the post
# is under 30 min old, and the sidecar still predates it, so it names the night coordinator. A session
# started after that post (the morning thread itself, or one started alongside it) does not send its
# turn into that thread: the night coordinator must not re-pay its context for a seat it is about to
# lose. Never silently: the held turn becomes a line in failures.log, which t3-watch.py sends to the
# user ("report lost"), and the session is told once. 30 min bounds a post whose thread never came.
# ponytail: told by start time, not by thread id; 120 s slack for the POST answer arriving late.
# After a refused claim (status "refused", 5th column = the claimer) only the refused morning thread
# itself stays held for the day: the user already got the REFUSED notice through notifyCommand, so
# its turns are not lost silently, and they never wake the night coordinator. Everyone else reports.
MST="$SDIR/morning-t3/status"
if [ -f "$MST" ]; then
  IFS=$'\t' read -r MD MS MAT _ MBY _ < "$MST"
  case "$MAT" in ''|*[!0-9]*) MAT="" ;; esac
  if [ "$MD" = "$(date +%F)" ] && [ "$MS" = refused ] && [ -n "${MBY:-}" ] && [ "$MBY" = "$SID" ]; then
    RDIR="$CFG_DIR/state/t3-report"; mkdir -p "$RDIR" 2>/dev/null
    [ "$(cat "$RDIR/$SID.held" 2>/dev/null)" = "refused $MD" ] && exit 0
    printf 'refused %s\n' "$MD" > "$RDIR/$SID.held" 2>/dev/null
    echo '{"systemMessage":"middle-management: your claim --morning was refused, so your turns are NOT sent to the night coordinator (your user got the REFUSED notice). Wait for your user in this thread."}'
    exit 0
  fi
  if [ -n "$MAT" ] && [ "$MD" = "$(date +%F)" ] && [ "$MS" = posted ] && [ $(( $(date +%s) - MAT )) -lt 1800 ] \
     && [ "$(stat -c %Y "$SIDE" 2>/dev/null || echo 0)" -lt "$MAT" ]; then
    SAT=$(cat "$CFG_DIR"/sessions/*.json 2>/dev/null \
      | jq -r --arg id "$SID" 'select(.sessionId == $id) | .startedAt | numbers' 2>/dev/null | head -1)
    if [ -n "$SAT" ] && [ $(( ${SAT%.*} / 1000 )) -ge $(( MAT - 120 )) ]; then
      RDIR="$CFG_DIR/state/t3-report"; mkdir -p "$RDIR" 2>/dev/null
      # once per session and post (failures.log line + systemMessage): one "report lost" notify, not one per turn
      [ "$(cat "$RDIR/$SID.held" 2>/dev/null)" = "$MAT" ] && exit 0
      printf '%s\n' "$MAT" > "$RDIR/$SID.held" 2>/dev/null
      HFROM=$(cat "$CFG_DIR"/sessions/*.json 2>/dev/null | jq -r --arg id "$SID" 'select(.sessionId == $id) | .name | strings' 2>/dev/null | head -1)
      printf '%s\t%s\t%s\tunknown\theld: the morning thread has not claimed the seat yet, so its turns are not sent to the night coordinator until it claims (at most 30 min); read them in that session\n' \
        "$(date -Is)" "${HFROM:-session ${SID:0:8}}" "$SID" >> "$RDIR/failures.log" 2>/dev/null
      echo '{"systemMessage":"middle-management: this turn was NOT sent to the coordinator: the morning thread has not claimed the seat yet (it would wake the night coordinator). Your user is told through the watcher; claim first if you are the morning thread."}'
      exit 0
    fi
  fi
fi

TEXT=$(jq -r '.last_assistant_message // empty | strings' <<<"$IN")
if [ -z "$TEXT" ]; then   # fallback: the text blocks of the last assistant entry in the transcript
  TR=$(jq -r '.transcript_path // empty' <<<"$IN")
  [ -f "$TR" ] && TEXT=$(tail -n 400 "$TR" | jq -rs '[.[] | select(.type == "assistant")
      | [.message.content[]? | select(.type == "text") | .text] | select(length > 0) | join("\n")] | last // empty' 2>/dev/null)
fi
TRIM=$(printf '%s' "$TEXT" | tr -d '[:space:]')
[ -n "$TRIM" ] && [ "$TRIM" != OK ] || TEXT=""

RDIR="$CFG_DIR/state/t3-report"; mkdir -p "$RDIR" 2>/dev/null
SUM=$(printf '%s' "$TEXT" | sha256sum | cut -d' ' -f1)
[ "$(cat "$RDIR/$SID" 2>/dev/null)" = "$SUM" ] && TEXT=""
PEND="$RDIR/$SID.pending"
FROM=$(cat "$CFG_DIR"/sessions/*.json 2>/dev/null \
  | jq -r --arg id "$SID" 'select(.sessionId == $id) | .name | strings' 2>/dev/null | head -1)

# Interim turn (F14): one of this session's sub-agents is still running, so a sub-agent completion
# turn does not wake the coordinator with a short status. Held only when the text does not look like
# a report (short, no READY/LIVE/blocked marker, no question, no "Close this tab."): a report is sent
# at once (a58212a2-W6: a READY written while a reviewer ran was lost). A held text is never dropped:
# it waits in <sid>.pending and goes out with the next turn that sends, even a short or empty one.
# ponytail: held.log, not failures.log: t3-watch.py turns each failures.log line into a "report lost"
# notify, and a held text is delayed, not lost. One line + one systemMessage per hold, not per turn.
if jq -e '[.background_tasks // [] | .[]? | select(type == "object" and .type == "subagent"
        and ((.status // "running") | test("^(completed|failed|killed|stopped|cancelled|canceled|done|error)$") | not))]
       | length > 0' <<<"$IN" >/dev/null 2>&1 \
   && [ "${#TEXT}" -le "${T3_REPORT_INTERIM_MAX:-500}" ] \
   && ! grep -qE '\b(READY|LIVE|BLOCKED|[Bb]locked)\b|Close this tab\.|\?[[:space:]]*$' <<<"$TEXT"; then
  [ -n "$TEXT" ] || exit 0
  [ -f "$PEND" ] && case "$(cat "$PEND")" in *"$TEXT") exit 0 ;; esac
  if [ ! -f "$PEND" ]; then
    printf '%s\t%s\t%s\tunknown\theld: sub-agent running · %s · %s\n' "$(date -Is)" "${FROM:-session ${SID:0:8}}" "$SID" "$SID" "${SUM:0:12}" \
      >> "$RDIR/held.log" 2>/dev/null
    jq -cn --arg t "$(jq -r '.threadId // "?"' "$SIDE" 2>/dev/null)" \
      '{systemMessage: "middle-management: report held while a sub-agent runs; it will be sent with your next turn, or send it now via t3_thread_send \($t)"}'
  fi
  (umask 077; { [ -s "$PEND" ] && printf '\n\n'; printf '%s' "$TEXT"; } >> "$PEND")
  exit 0
fi
if [ -s "$PEND" ]; then   # the held text(s) first, then this turn's text
  [ -n "$TEXT" ] || SUM=$(sha256sum < "$PEND" | cut -d' ' -f1)   # flush only: the block-once key
  TEXT="$(cat "$PEND")${TEXT:+$'\n\n'$TEXT}"; rm -f "$PEND"
fi
[ -n "$TEXT" ] || exit 0

TMP=$(umask 077; mktemp) || exit 0
printf '%s' "$TEXT" > "$TMP"
# Guard: the sender must end inside the hook's timeout (hooks.json: 20 s), else the hook is killed
# before the failure line and the block below, and the lost report is silent (review r1 F1).
GUARD=(); command -v timeout >/dev/null 2>&1 && GUARD=(timeout "${T3_REPORT_BUDGET:-15}")
MM_SESSION_ID="$SID" MM_SCOPE_CWD="$START" "${GUARD[@]}" bash "$S/t3-wake.sh" "${FROM:-session ${SID:0:8}}" "$TMP" >/dev/null 2>&1; RC=$?
rm -f "$TMP"
[ "$RC" = 124 ] && printf '%s\t%s\t%s\tunknown\tsender timed out after %ss\n' "$(date -Is)" "${FROM:-session ${SID:0:8}}" "$SID" \
  "${T3_REPORT_BUDGET:-15}" >> "$RDIR/failures.log" 2>/dev/null
case "$RC" in
  0) printf '%s\n' "$SUM" > "$RDIR/$SID"; exit 0 ;;
  3) exit 0 ;;    # the sidecar went away meanwhile (release): no coordinator to report to
esac
# Not delivered. Block once per text, never on a continuation (no loop).
[ "$(jq -r '.stop_hook_active // false' <<<"$IN")" = true ] && exit 0
[ "$(cat "$RDIR/$SID.blocked" 2>/dev/null)" = "$SUM" ] && exit 0
printf '%s\n' "$SUM" > "$RDIR/$SID.blocked"
jq -cn --arg t "$(jq -r '.threadId // "?"' "$SIDE" 2>/dev/null)" \
  '{decision: "block", reason: "report NOT delivered to the coordinator: send it yourself with t3_thread_send \($t)"}'
exit 0
