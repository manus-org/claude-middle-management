#!/usr/bin/env bash
# middle-management plugin — the stuck-coordinator heartbeat (one tick).
# Consumers: templates/systemd/orch-heartbeat.service (started every 10 min by
#            orch-heartbeat.timer; both installed as USER units by /middle-management-setup,
#            which copies this script's directory to <config dir>/middle-management-heartbeat/);
#            tests/heartbeat.sh (drives every branch against fixtures);
#            by hand: `orch-heartbeat.sh classify <transcript.jsonl>` when triaging a stall;
#            itself, once per named scope (README "Scopes"), with OHB_SCOPE set.
#            Nothing else calls this script. Calls poke-session.py, peer-state.py and, only with
#            a "scopes" key or "scopeMode": "per-root" in the config, scope.py (all beside it).
#            Skips a coordinator bound to a T3 thread (sidecar orchestrator.t3.json next to its
#            marker, written by orchestrator.sh t3-bind): t3-watch.py watches that one.
#
# One tick does:
#   who coordinates  ->  is that session alive (liveness rule F1, incl. the procStart PID-reuse
#   guard)  ->  does its transcript show a turn that never got an answer  ->  alarm the user
#   ONCE through the configured notifyCommand, then poke the session over its own Unix socket
#   until it answers again or GIVE_UP_H hours are up.
# A poke is a socket write (poke-session.py beside this file): no `claude` process, no model
# call, no quota - the transport must not depend on the resource a usage limit exhausts.
# It re-triggers an IDLE session; a session asleep inside an API retry only buffers it. So this
# is a net for DEAD TURNS, and merely harmless otherwise.
# Second, independent job (keep_warm, before the coordinator check): ANY live, unwrapped interactive, non-SDK session
# idle 45 to 55 minutes that waits on a question (peer-state.py --waiting) or carries a hold file
# gets one fixed "reply ok" ping, so its prompt cache is read (cheap) instead of going cold (its
# whole context again). At most 3 per wait phase; never a session parked on a permission prompt.
# Linux only: /proc/<pid>/stat, systemd user units, GNU date. Arm, disarm, uninstall and the
# alarm lines: skill middle-management, section "Recovery after a kill".
#
# Never prints a secret: notifyCommand is executed, never echoed; the peer token is read by
# poke-session.py and never echoed either.
set -Eeuo pipefail

# --- thresholds (guesses, which is why they are named) -------------------------------------
STUCK_MIN=15        # transcript silent for longer than this AND an unanswered turn => STUCK
ALARM_MIN=45        # stuck for this long => alarm #1 + first poke
POKE_EVERY=60       # minutes between pokes afterwards
GIVE_UP_H=24        # stop poking after this long, one final alarm
TAIL_LINES=1000     # records read from the end of the transcript (one tail-read per tick).
                    # Headroom, not a guarantee: a fully burned retry budget is ~320-360 records
                    # after the prompt, and sidechain traffic is unbounded - classify() widens to
                    # the whole file when the window holds no user record.

# --- paths (env-overridable so the test can drive every branch without touching real state) --
# The config dir honors CLAUDE_CONFIG_DIR like Claude Code itself (empty = unset). No
# config-check.sh dependency on purpose: the installed copy keeps running when the plugin moves.
DIR=$(cd "$(dirname "$0")" && pwd)
CFG_DIR=${CLAUDE_CONFIG_DIR:-$HOME/.claude}
CFG_FILE=${OHB_CONFIG:-$CFG_DIR/middle-management.json}
REG=${OHB_REG:-$CFG_DIR/sessions}
MARKER=${OHB_MARKER:-$CFG_DIR/state/orchestrator}
PROJECTS=${OHB_PROJECTS:-$CFG_DIR/projects}
STATE=${OHB_STATE_DIR:-$CFG_DIR/state/orch-heartbeat}
HB_DIR=${OHB_DIR:-$DIR}            # the poke prompt and the sender live beside this script
POKE_PROMPT=$HB_DIR/orch-heartbeat-poke.md
POKE_SENDER=$HB_DIR/poke-session.py
# Episodes are "<sessionId>.json"; the latch file deliberately has NO .json suffix, because
# housekeeping deletes *.json of foreign coordinators and both it and last-tick must survive.
LATCH=$STATE/latches
TICKFILE=$STATE/last-tick
# Test seams: when set, an alarm or a poke is appended to that file instead of being sent.
ALARM_SINK=${OHB_ALARM_SINK:-}
POKE_SINK=${OHB_POKE_SINK:-}

TICK_NOTE=started
SCOPED=""; jq -e '([.scopes | arrays | .[]] | length > 0) or (.scopeMode == "per-root")' "$CFG_FILE" >/dev/null 2>&1 && SCOPED=1

log() { printf '%s\n' "$*" >&2; }   # goes to the journal

# --- alarm: the configured notifyCommand (config key), the text as $1 and on stdin. ---------
# Never gates anything: an alarm that cannot be delivered is journaled and the tick goes on.
# ponytail: the same lines live in unit-failure-alarm.sh on purpose - the two scripts have
# different contracts, and coupling them would make the heartbeat's alarm path depend on a
# script whose job is "a systemd unit failed".
# The text is written for a person on a phone: emoji + headline, a blank line, one fact per line.
alarm() {
  local text="$1" cmd rc=0
  if [ -n "$ALARM_SINK" ]; then   # one alarm per sink line, so the test can count them
    printf '%s\n' "${text//$'\n'/ | }" >> "$ALARM_SINK" || log "heartbeat: alarm sink unwritable - $text"
    return 0
  fi
  cmd=$(jq -r '.notifyCommand // ""' "$CFG_FILE" 2>/dev/null || true)
  if [ -z "$cmd" ]; then
    log "heartbeat: no notifyCommand in $CFG_FILE - alarm NOT delivered: $text"; return 0
  fi
  # Output discarded, not journaled: a failing command may echo a URL that carries a token.
  sh -c "$cmd" notify "$text" <<<"$text" >/dev/null 2>&1 || rc=$?   # <<<: see unit-failure-alarm.sh send()
  [ "$rc" -eq 0 ] || log "heartbeat: notifyCommand failed (exit $rc) - the message was: $text"
  return 0
}

# --- latches: keep a branch that fires in every tick from buzzing the user's phone ----------
# should_alarm <key> <once|seconds>. A repeating alarm says since when: STREAK is the time of the
# first alarm of this run of repeats (empty on the first one); a gap of two periods starts anew.
should_alarm() {
  local key=$1 ttl=$2 now last cur first
  now=$(date +%s); STREAK=""
  # A corrupt latch file must not INVERT the latch (it would make every branch alarm on every
  # tick, forever): read it defensively and rewrite it from scratch when it is unreadable.
  cur=$(jq -c . "$LATCH" 2>/dev/null) || cur=""
  case "$cur" in ''|null) cur='{}' ;; esac
  last=$(printf '%s' "$cur" | jq -r --arg k "$key" '(.[$k] // 0) | tostring' 2>/dev/null || echo 0)
  case "$last" in ''|*[!0-9]*) last=0 ;; esac
  first=$now
  if [ "$ttl" = once ]; then
    [ "$last" -gt 0 ] && return 1
  else
    [ $((now - last)) -lt "$ttl" ] && return 1
    first=$(printf '%s' "$cur" | jq -r --arg k "$key~since" '(.[$k] // 0) | tostring' 2>/dev/null || echo 0)
    case "$first" in ''|*[!0-9]*) first=0 ;; esac
    if [ "$first" -gt 0 ] && [ $((now - last)) -lt $((2 * ttl)) ]; then STREAK=$first; else first=$now; fi
  fi
  printf '%s' "$cur" | jq -c --arg k "$key" --argjson t "$now" --argjson f "$first" '. + {($k): $t, ($k + "~since"): $f}' \
    > "$LATCH.$$.tmp" && mv "$LATCH.$$.tmp" "$LATCH"
  return 0
}
# The line a repeat carries (empty on the first alarm), after should_alarm <key> <seconds>.
again() { [ -n "${STREAK:-}" ] && printf '\nStill so since %s (this repeats at most every %s min).' "$(when "$STREAK")" "$(( $1 / 60 ))"; return 0; }

# --- classifier ----------------------------------------------------------------------------
# Ignores every record type except user/assistant, ignores records without a timestamp, ignores
# local slash-command echoes and sidechain (sub-agent) records, and compares TIMESTAMPS - never
# file position, because retry records are flushed retroactively and out of order.
# prints: VERDICT<TAB>lastUserISO<TAB>lastAsstISO<TAB>lastUserEpoch
classify_jq() {  # reads transcript lines on stdin; $1 = mtime age in minutes
  jq -Rsr --argjson age "$1" --argjson stuck "$STUCK_MIN" '
    def epoch: sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601;
    def body:  (.message.content // "")
               | if type == "array" then map(if type == "object" then (.text // "") else "" end) | join(" ")
                 else tostring end;
    [ split("\n")[] | select(length > 0) | (fromjson? // empty)
      | select(.timestamp != null and .isSidechain != true) ] as $r
    | ([ $r[] | select(.type == "user")
               # Local slash commands write user records with no answer. The tags are ANCHORED:
               # a tool result that merely quotes one of them is a real turn, not an echo.
               | select((body | test("^\\s*<(local-command-caveat|command-name|local-command-stdout)>")) | not)
               | .timestamp ] | max) as $lu
    | ([ $r[] | select(.type == "assistant" and .isApiErrorMessage != true
                       and (.message.model // "") != "<synthetic>")
               | .timestamp ] | max) as $la
    # No user record at all is HEALTHY (a fresh session) - never RECOVERED: a "recovery"
    # without a prompt to recover from is the shape a truncated read produces, and it would
    # close an open episode on a coordinator that never answered.
    | (if   $lu != null and ($la == null or $lu > $la) then (if $age > $stuck then "STUCK" else "HEALTHY" end)
       elif $lu != null and $la > $lu                  then "RECOVERED"
       else "HEALTHY" end) as $v
    | [$v, ($lu // "-"), ($la // "-"), (if $lu != null then ($lu | epoch | tostring) else "0" end)] | @tsv'
}
classify() {
  local f=$1 age out
  age=$(( ( $(date +%s) - $(stat -c %Y "$f") ) / 60 ))
  out=$(tail -n "$TAIL_LINES" "$f" | classify_jq "$age")
  # The tail window is a cost optimisation, not a guarantee: a burned retry budget can flush
  # hundreds of records AFTER the prompt that got no answer, pushing it out of the window - and
  # a missing lastUser is the one input that flips the verdict to "healthy". So when the window
  # holds no user record at all, re-read the whole file before concluding anything.
  if [ "$(printf '%s' "$out" | cut -f2)" = "-" ]; then
    log "heartbeat: no user record in the last $TAIL_LINES lines of $f - re-reading it whole"
    out=$(classify_jq "$age" < "$f")
  fi
  printf '%s\n' "$out"
}

# --- liveness F1 (registry entry, kind==interactive, kill -0, procStart) --------------------
# prints "<pid>\t<name>"; returns 0 alive, 1 dead, 2 undecidable
entry_of() { cat "$REG"/*.json 2>/dev/null | jq -c --arg id "$1" 'select(.sessionId == $id)' 2>/dev/null | head -1; }
alive() {
  local id=$1 e pid name kind procstart rest actual
  [ -d "$REG" ] && [ -r "$REG" ] || { log "heartbeat: registry $REG unreadable"; return 2; }
  e=$(entry_of "$id")
  [ -z "$e" ] && return 1
  pid=$(printf '%s' "$e" | jq -r '.pid // empty')
  name=$(printf '%s' "$e" | jq -r '.name // "unnamed"')
  kind=$(printf '%s' "$e" | jq -r '.kind // ""')
  procstart=$(printf '%s' "$e" | jq -r '.procStart // ""')
  [ "$kind" = interactive ] || return 1
  [ -n "$pid" ] || return 1
  kill -0 "$pid" 2>/dev/null || return 1
  # PID reuse guard: field 22 of /proc/<pid>/stat. comm may contain spaces, so cut after ") ".
  rest=$(cat "/proc/$pid/stat" 2>/dev/null) || { log "heartbeat: /proc/$pid/stat unreadable"; return 2; }
  rest=${rest##*') '}   # longest match: comm may itself contain ") ", the numeric fields cannot
  actual=$(printf '%s' "$rest" | awk '{print $20}')
  if [ -n "$procstart" ] && [ "$procstart" != "$actual" ]; then
    log "heartbeat: procStart mismatch for pid $pid ($procstart != $actual) - PID reuse"
    return 2
  fi
  printf '%s\t%s\n' "$pid" "$name"
  return 0
}

# --- episode state --------------------------------------------------------------------------
ep_file() { printf '%s/%s.json\n' "$STATE" "$1"; }
ep_get()  { jq -r --arg k "$2" '(.[$k] // "") | tostring' "$(ep_file "$1")" 2>/dev/null || true; }
ep_set()  { # ep_set <id> <k> <v> [<k> <v> ...]   (values are written as strings/numbers as given)
  local id=$1 f cur; shift; f=$(ep_file "$id")
  # Same defence as the latch file: an unreadable episode is rewritten, not carried forward.
  # Without it a corrupt file makes the "stuck" alarm fire on every single tick.
  cur=$(jq -c . "$f" 2>/dev/null) || cur=""
  case "$cur" in ''|null) cur='{}' ;; esac
  local args=() prog='.'
  while [ $# -gt 0 ]; do
    args+=(--arg "k$#" "$1" --arg "v$#" "$2"); prog="$prog + {(\$k$#): \$v$#}"; shift 2
  done
  printf '%s' "$cur" | jq -c "${args[@]}" "$prog" > "$f.$$.tmp" && mv "$f.$$.tmp" "$f"
}

hhmm() { date -d "@$1" +%H:%M; }
# when <epoch>: local time as a person says it: 14:05 · tomorrow 07:00 · yesterday 22:55 · Thu 07:00
# (within six days) · 12 Nov 07:00 (as t3-watch.py and topics.py). ponytail: the same function lives in unit-failure-alarm.sh,
# lane-reaper.sh and morning-headless.sh; each runs from its own copy dir, a shared file would need
# a fifth entry in every copy set.
when() {
  local f='%d %b %H:%M' now; now=$(date +%s)
  case "$(date -d "@$1" +%F)" in
    "$(date +%F)") f=%H:%M ;;
    "$(date -d tomorrow +%F)") f='tomorrow %H:%M' ;;
    "$(date -d yesterday +%F)") f='yesterday %H:%M' ;;
    *) [ $(( $1 - now )) -lt 518400 ] && [ $(( now - $1 )) -lt 518400 ] && f='%a %H:%M' ;;
  esac
  LC_ALL=C date -d "@$1" +"$f"
}
# title <sessionId> <fallback>: the session by its title in words (the one the user gave it, else
# the AI title in its transcript), cut to 45 characters; the fallback when it has neither.
title() {
  local f t LC_ALL=C.UTF-8   # so ${#t} counts characters, not bytes
  f=$(ls -1 "$PROJECTS"/*/"$1".jsonl 2>/dev/null | head -1 || true)
  [ -n "$f" ] && t=$(grep -hF -e '"custom-title"' -e '"ai-title"' "$f" 2>/dev/null | jq -Rrs '
      [ split("\n")[] | (fromjson? // empty) ] as $r
      | ([ $r[] | select(.type == "custom-title") | .customTitle | strings | select(length > 0) ] | last)
        // ([ $r[] | select(.type == "ai-title") | .aiTitle | strings | select(length > 0) ] | last) // empty' 2>/dev/null || true)
  t=${t:-$2}
  [ ${#t} -gt 45 ] && t="${t:0:44}…"
  printf '%s' "$t"
}
# The seat in words: "Coordinator", or "Coordinator of <scope>" for a named scope (README "Scopes");
# an auto scope of scopeMode per-root (<name>-<6 hex>, scope.py AUTO) without its hash.
PROJ=${OHB_SCOPE:-}
[[ $PROJ =~ ^[A-Za-z0-9][A-Za-z0-9_-]*-[0-9a-f]{6}$ ]] && PROJ=${PROJ%-*}
WHO="Coordinator${PROJ:+ of $PROJ}"

# --- the poke ------------------------------------------------------------------------------
poke() { # poke <sessionId> <name> <stuck_since_epoch> <poke_number>
  local id=$1 name=$2 since=$3 n=$4 body rc=0
  if [ -n "$POKE_SINK" ]; then printf '%s poke#%s\n' "$id" "$n" >> "$POKE_SINK"; return 0; fi
  # The prompt file carries a doc header for humans; everything after its first "---" line is
  # the message. Keeping both in one versioned file beats a second file nobody would find.
  # No "---" in the file => send the whole thing, never an empty checklist.
  local text; text=$(sed '1,/^---$/d' "$POKE_PROMPT")   # unreadable file => ERR trap, loudly
  [ -n "$text" ] || text=$(cat "$POKE_PROMPT")
  body=$(mktemp)   # after the text, so a missing prompt file leaves no temp file behind
  { printf 'HEARTBEAT POKE #%s - your session ("%s") has had no answer since %s.' \
      "$n" "$name" "$(hhmm "$since")"
    # With scopes the checklist's roster and board are this scope's (step 3 of the prompt).
    if [ -n "$SCOPED" ]; then
      printf ' Only sessions of scope %s are yours: peer-state.py --scope %s.' "${OHB_SCOPE:-default}" "${OHB_SCOPE:-default}"
      if [ -n "${OHB_SCOPE:-}" ]; then printf ' Its board is %s.' "${OHB_BOARD:-}"; fi
    fi
    printf '\n'
    printf '%s\n' "$text"; } > "$body"
  python3 "$POKE_SENDER" "$id" "$body" >&2 || rc=$?
  rm -f "$body"
  local why
  case "$rc" in
    0) log "heartbeat: poke #$n handed to $name ($id)"; return 0 ;;
    2) why="Its session is not registered as live any more." ;;
    3) why="Its session no longer takes messages (its socket is gone)." ;;
    *) why="The nudge failed." ;;
  esac
  if [ "$(ep_get "$id" poke_error)" != yes ]; then
    ep_set "$id" poke_error yes
    alarm "⚠️ The stuck ${WHO,} cannot be nudged: $(title "$id" "$name")

$why
Further nudges will probably fail the same way, so please look at its tab.
Detail: poke-session exit $rc"
  fi
  return 0
}

# --- housekeeping: an episode belongs to exactly one coordinator ----------------------------
close_foreign_episodes() { # close_foreign_episodes [<current sessionId>]
  local cur=${1:-} f id
  rm -f "$STATE"/*.tmp    # leftovers from a write that died mid-flight; never episodes
  for f in "$STATE"/*.json; do
    [ -e "$f" ] || continue
    id=$(basename "$f" .json)
    [ "$id" = "$cur" ] && continue
    # An episode that recovered is deleted on the spot, so an episode still here that was
    # alarmed never recovered - the user heard the "stuck" line and deserves the closing one.
    if [ "$(ep_get "$id" alarmed)" = yes ]; then
      T=$(title "$id" "")
      alarm "🟡 No longer watching the stuck ${WHO,}${T:+ $T}: another session holds the seat now, or it has ended."
    fi
    rm -f "$f"
    log "heartbeat: removed foreign episode $id"
  done
}

# --- cause, for the recovery line only (never for detection) -------------------------------
limit_cause() { # limit_cause <transcript> <episode start epoch>
  local f=$1 since=$2 r
  # Only a limit whose reset lies AFTER this episode began can be its cause - an older record
  # still inside the tail window belongs to an earlier episode. when() names the day, because
  # a seven_day limit resets days out and a bare HH:MM would read as "in a few minutes".
  r=$(tail -n "$TAIL_LINES" "$f" | jq -Rsr --argjson since "$since" '
    [ split("\n")[] | select(length > 0) | (fromjson? // empty)
      | select(.type == "system" and .subtype == "api_error" and .error.status == 429
               and (.error.rateLimits.resetsAt // null) != null
               and .error.rateLimits.resetsAt >= $since)
      | .error.rateLimits.resetsAt ] | max // empty' 2>/dev/null || true)
  [ -n "$r" ] && printf ' It had hit its usage limit (reset %s).' "$(when "$r")"
  return 0
}

# --- keep-warm ------------------------------------------------------------------------------
# Opt-out machine-wide: <KW_DIR>/off. Opt-in without a detected question: <KW_DIR>/<sessionId>.
# Counter per session: $STATE/keepwarm-<sessionId> = "<pings> <epoch of the last ping>" (no .json
# suffix, so close_foreign_episodes leaves it alone). The session's own "ok" lands within
# KW_GRACE of the ping; activity later than that means it moved, and the wait phase starts over.
# peer-state.py skips the ping and its "ok", so the question still reads; the counter file also
# keeps a session eligible that qualified by hold file only. Test seams: OHB_PEERS (a peer-state --json array), OHB_KEEPWARM_DIR.
KW_DIR=${OHB_KEEPWARM_DIR:-$CFG_DIR/state/keep-warm}
KW_TEXT='KEEPWARM PING (automatic, not from your user, not an answer). Do nothing. Reply with exactly: ok'
KW_FROM=2700; KW_TO=3300; KW_CAP=3; KW_GRACE=300   # seconds idle: ping inside [45, 55) min;
# grace: a slow "ok" must not end the phase, and a real answer inside it costs at most the cap
keep_warm() {
  [ -e "$KW_DIR/off" ] && return 0
  local rows sid idle waiting n last f body now seen=" "
  now=$(date +%s)
  if [ -n "${OHB_PEERS+x}" ]; then rows=$(cat "$OHB_PEERS" 2>/dev/null || true)
  else rows=$(python3 "$HB_DIR/peer-state.py" --json 2>/dev/null) || { log "keep-warm: peer-state.py failed"; return 0; }
  fi
  while IFS=$'\t' read -r sid idle waiting; do
    seen="$seen$sid "; f=$STATE/keepwarm-$sid
    { read -r n last < "$f"; } 2>/dev/null || { n=0; last=0; }
    [ $((now - idle)) -gt $((last + KW_GRACE)) ] && { n=0; rm -f "$f"; }
    [ "$waiting" = permission ] && continue      # a queued message there refreshes nothing
    [ "$waiting" = question ] || [ -e "$KW_DIR/$sid" ] || [ "$n" -gt 0 ] || continue
    [ "$idle" -ge "$KW_FROM" ] && [ "$idle" -lt "$KW_TO" ] && [ "$n" -lt "$KW_CAP" ] || continue
    n=$((n + 1))
    if [ -n "$POKE_SINK" ]; then printf '%s keepwarm#%s\n' "$sid" "$n" >> "$POKE_SINK"
    else
      body=$(mktemp); printf '%s\n' "$KW_TEXT" > "$body"
      POKE_FROM_NAME=keepwarm python3 "$POKE_SENDER" "$sid" "$body" >&2 || log "keep-warm: poke-session exit $? for $sid"
      rm -f "$body"
    fi
    printf '%s %s\n' "$n" "$now" > "$f"
    log "keep-warm: ping #$n/$KW_CAP to $sid (idle $((idle / 60)) min, waiting=$waiting)"
  done < <(printf '%s' "${rows:-[]}" | jq -r '.[] | select(.live == true and .kind == "interactive"
             and ((.entrypoint // "") | startswith("sdk") | not)
             and .wrapped != "yes" and .idle_seconds != null) | [.session_id, .idle_seconds, (.waiting // "-")] | @tsv' 2>/dev/null)
  for f in "$STATE"/keepwarm-*; do              # counters of sessions gone or wrapped
    [ -e "$f" ] || continue
    case "$seen" in *" ${f##*/keepwarm-} "*) ;; *) rm -f "$f" ;; esac
  done
  return 0
}

# ============================ subcommands ===================================================
case "${1:-tick}" in
  # classify is the read-only diagnostic: it prints a verdict and touches NO state, so running
  # it by hand (or from the test) cannot overwrite last-tick or a live episode.
  classify) classify "$2"; exit 0 ;;
  tick) : ;;
  *) echo "usage: orch-heartbeat.sh [tick|classify <transcript.jsonl>]" >&2; exit 1 ;;
esac

mkdir -p "$STATE"
trap 'printf "%s %s\n" "$(date -Is)" "$TICK_NOTE" > "$TICKFILE"' EXIT   # step 10: every tick
# The script's own failure is loud but latched like every other branch: a persistent bug
# must not buzz the user's phone every ten minutes. Exit 0, never non-zero - a failing exit would
# make OnFailure= fire a SECOND, unthrottled alarm on top of this one.
# $BASHPID != $$ means the failure happened inside a command substitution: exiting 0 THERE would
# hand the parent an empty string and a success status, and the tick would sail on with missing
# data. In a subshell the trap re-raises; only the main shell alarms and swallows the exit code.
trap 'rc=$?; if [ "$BASHPID" != "$$" ]; then exit $rc; fi
      if should_alarm internal-error 3600 2>/dev/null; then
        alarm "⚠️ The stuck-coordinator check hit a bug and stopped this run

While it fails, a stuck coordinator can go unnoticed.$(again 3600)
See what failed:
journalctl --user -u orch-heartbeat.service -n 50
Detail: exit $rc at line $LINENO"; fi
      TICK_NOTE="error(exit $rc)"; exit 0' ERR

# 0. Keep-warm runs first and never ends the tick: every branch below may exit early. It is
# machine-wide, so only the top-level tick runs it, never a scope's child tick.
[ -n "${OHB_SCOPE:-}" ] || keep_warm || log "keep-warm: failed this tick"

# 0b. Scopes (README "Scopes"): one child tick per named scope, with that scope's marker and state
# dir; then this tick goes on with the default seat exactly as without scopes. If scope.py fails,
# the default seat is still watched.
if [ -n "$SCOPED" ] && [ -z "${OHB_SCOPE:-}" ]; then
  LIST=$(python3 "$DIR/scope.py" list) || { LIST=""; should_alarm scopes 3600 \
    && alarm "⚠️ Only the main coordinator is watched: the project list cannot be read

The coordinators of the other projects are not checked until it can.$(again 3600)
Check the scopes in the plugin config: /middle-management-setup
Detail: scope.py list failed"; }
  while IFS=$'\t' read -r sn sd sb; do
    [ -n "$sn" ] || continue
    log "heartbeat: scope $sn"
    OHB_SCOPE=$sn OHB_BOARD=$sb OHB_MARKER=$sd/orchestrator OHB_STATE_DIR=$sd/orch-heartbeat \
      bash "$DIR/orch-heartbeat.sh" tick || log "heartbeat: the tick of scope $sn failed"
  done <<<"$LIST"
fi

# The scope's sessions only: "<cwd>\t<rest>" in, "<rest>" out. Unscoped, or scope.py failing in
# the TOP-LEVEL tick: everything, as without scopes, so "only the default seat is watched" stays
# true. In a named scope's child a failure yields no candidates: that seat then rests on its marker.
in_scope() {
  local inp out; inp=$(cat)
  if [ -n "$SCOPED" ] && out=$(printf '%s\n' "$inp" | python3 "$DIR/scope.py" filter "${OHB_SCOPE:-default}"); then
    printf '%s\n' "$out"
  elif [ -z "${OHB_SCOPE:-}" ]; then printf '%s\n' "$inp" | cut -f2-
  fi
}

# 1. Who coordinates? Marker first, then the name fallback session-role.sh implements.
ID=""; NAME=""; SRC=""
if [ -f "$MARKER" ]; then ID=$(head -1 "$MARKER" | tr -d '[:space:]'); SRC=marker; fi
# A T3 coordinator sleeps after 30 idle minutes and reads as dead here; t3-watch.py covers it (plan 1.6).
if [ -n "$ID" ] && [ "$(jq -r '.sessionId // empty' "$(dirname "$MARKER")/orchestrator.t3.json" 2>/dev/null || true)" = "$ID" ]; then
  log "heartbeat: coordinator $ID is bound to a T3 thread, t3-watch covers it"; TICK_NOTE="t3-coordinator"; exit 0
fi

LIVENESS=0
if [ -n "$ID" ]; then
  OUT=$(alive "$ID") || LIVENESS=$?
  if [ "$LIVENESS" = 0 ]; then NAME=${OUT#*$'\t'}; fi
fi

if [ -z "$ID" ] || [ "$LIVENESS" = 1 ]; then
  # No marker, or it points at a session that is not live: the orch*-name fallback.
  # The (possibly empty) name stays LAST in the jq array: `read` with tab-IFS collapses empty
  # middle fields, so a nameless registry entry would otherwise shift its sessionId into the
  # name column (same fix as hooks/session-role.sh).
  # The cwd column is never empty ("-") for the same reason; in_scope drops it again.
  NAMED=$(cat "$REG"/*.json 2>/dev/null \
    | jq -r 'select(.pid and .kind == "interactive")
        | [.pid, (.sessionId // ""), (.cwd | if type == "string" and . != "" then . else "-" end), (.name // "")] | @tsv' 2>/dev/null \
    | while IFS=$'\t' read -r p s c n; do kill -0 "$p" 2>/dev/null && printf '%s\t%s\t%s\n' "$c" "$n" "$s"; done \
    | in_scope | grep -i '^orch' || true)
  COUNT=$(printf '%s' "$NAMED" | grep -c . || true)
  if [ "$COUNT" -gt 1 ]; then
    should_alarm "ambiguous" 3600 && \
      alarm "⚠️ No ${WHO,} is watched: $COUNT sessions have a name starting with orch, and none holds the seat

A stuck coordinator goes unnoticed until one of them claims it.$(again 3600)
In the session that should coordinate:
/orchestrator claim"
    TICK_NOTE="ambiguous-coordinator"; exit 0
  elif [ "$COUNT" = 1 ]; then
    ID=$(printf '%s' "$NAMED" | cut -f2); SRC=name
    # The name route gets the SAME F1 check as the marker route - including the procStart
    # PID-reuse guard. The candidate already passed kind+kill -0 above, so this only ever
    # downgrades it to "undecidable", never the other way round.
    LIVENESS=0; OUT=$(alive "$ID") || LIVENESS=$?
    if [ "$LIVENESS" = 0 ]; then NAME=${OUT#*$'\t'}; else NAME=$(printf '%s' "$NAMED" | cut -f1); fi
  elif [ -n "$ID" ] && [ "$SRC" = marker ]; then
    # Marker names a session that is gone and nothing else coordinates: dead, not stuck.
    if should_alarm "dead:$ID" once; then
      T=$(title "$ID" "")
      alarm "🔴 $WHO has ended${T:+: $T}

Its session is gone, not stuck, and nothing restarts it.
Until someone takes the seat, the sessions work on their own and no one routes their reports.
To appoint a new one, in a fresh session:
/orchestrator claim"
    fi
    close_foreign_episodes ""
    TICK_NOTE="coordinator-dead"; exit 0
  else
    # No marker and no orch* session: the regime is genuinely off.
    close_foreign_episodes ""
    TICK_NOTE="regime-off"; exit 0
  fi
fi

# Anything but a clean "alive" at this point is undecidable: the marker route's "dead" was
# already consumed above, so a non-zero here is an unreadable registry, PID reuse, or a session
# that exited between the fallback's two checks.
if [ "$LIVENESS" != 0 ]; then
  should_alarm "undecidable:$ID" 3600 && \
    alarm "⚠️ Cannot tell whether the ${WHO,} still runs$(T=$(title "$ID" ""); printf '%s' "${T:+: $T}")

Checking again at the next run (every 10 min); nothing to do yet.$(again 3600)
Detail: session registry or process table unreadable, or its process id was reused"
  TICK_NOTE="undecidable"; exit 0
fi

# 2. Housekeeping: episodes of any other coordinator are over.
close_foreign_episodes "$ID"

# 4. The transcript.
TRANSCRIPT=$(ls -1 "$PROJECTS"/*/"$ID".jsonl 2>/dev/null | head -1 || true)
if [ -z "$TRANSCRIPT" ]; then
  should_alarm "transcript:$ID" once && log "heartbeat: no transcript $ID.jsonl under $PROJECTS" && \
    alarm "⚠️ $WHO cannot be watched for stalls: $NAME

Its conversation file is not where the heartbeat looks, so a stall there would go unnoticed.
Everything else works; nothing to do unless this keeps happening.
Detail: no conversation file for this session under the projects folder (the journal names both)"
  TICK_NOTE="no-transcript"; exit 0
fi

# 5. Classify.
IFS=$'\t' read -r VERDICT LAST_USER LAST_ASST LU_EPOCH < <(classify "$TRANSCRIPT")
NOW=$(date +%s)
EP=$(ep_file "$ID")

# 7. Transitions.
if [ "$VERDICT" = RECOVERED ]; then
  if [ -f "$EP" ]; then
    SINCE=$(ep_get "$ID" stuck_since); SINCE=${SINCE:-0}
    MINS=$(( (NOW - SINCE) / 60 ))
    if [ "$(ep_get "$ID" alarmed)" = yes ]; then
      alarm "🟡 $WHO answers again after $MINS min: $(title "$ID" "$NAME").$(limit_cause "$TRANSCRIPT" "$SINCE")"
    fi
    rm -f "$EP"
    log "heartbeat: episode for $ID closed (recovered)"
    TICK_NOTE="recovered ($NAME)"
  else
    TICK_NOTE="healthy ($NAME)"
  fi
  exit 0
fi

if [ "$VERDICT" = HEALTHY ]; then
  # NOT a recovery: HEALTHY also means "mtime is fresh", which says nothing about an answer.
  # An open episode therefore survives - only a real answer (RECOVERED) closes it.
  [ -f "$EP" ] && TICK_NOTE="stuck-but-quiet ($NAME)" || TICK_NOTE="healthy ($NAME)"
  exit 0
fi

# STUCK.
if [ ! -f "$EP" ]; then
  ep_set "$ID" stuck_since "$LU_EPOCH" last_user "$LAST_USER" pokes 0 alarmed no stopped no poke_error no
elif [ "$(ep_get "$ID" last_user)" != "$LAST_USER" ]; then
  # A DIFFERENT turn is now unanswered, so the episode on file is stale: the coordinator did
  # answer in between and no tick happened to observe it (every tick landed mid-turn). Carrying
  # the old episode forward would swallow this stall's alarm, quote the wrong time, and let the
  # 24 h cap fire against the wrong clock and then disarm the heartbeat for good.
  log "heartbeat: new unanswered turn for $ID - episode re-baselined"
  ep_set "$ID" stuck_since "$LU_EPOCH" last_user "$LAST_USER" pokes 0 alarmed no stopped no poke_error no
fi
SINCE=$(ep_get "$ID" stuck_since); SINCE=${SINCE:-$LU_EPOCH}
# stuck_since is the transcript's own lastUser timestamp, not the tick that noticed it.
STUCK_FOR=$(( (NOW - SINCE) / 60 ))

if [ "$(ep_get "$ID" stopped)" = yes ]; then
  TICK_NOTE="stuck ${STUCK_FOR}m, given up ($NAME)"; exit 0
fi

if [ "$STUCK_FOR" -ge $((GIVE_UP_H * 60)) ]; then
  ep_set "$ID" stopped yes
  alarm "🔴 $WHO still stuck after $GIVE_UP_H h, nudges stopped: $(title "$ID" "$NAME")

No answer since $(when "$SINCE"). The heartbeat does not nudge it any more.
Please look at its tab. To replace it, close that tab, then in a fresh session:
/orchestrator claim"
  TICK_NOTE="gave up ($NAME)"; exit 0
fi

if [ "$STUCK_FOR" -lt "$ALARM_MIN" ]; then
  TICK_NOTE="stuck ${STUCK_FOR}m, below alarm threshold ($NAME)"; exit 0
fi

PORT=$(ep_get "$ID" pokes); PORT=${PORT:-0}
LAST_POKE=$(ep_get "$ID" last_poke); LAST_POKE=${LAST_POKE:-0}
if [ "$(ep_get "$ID" alarmed)" != yes ]; then
  alarm "🔴 $WHO stuck since $(when "$SINCE"): $(title "$ID" "$NAME")

No answer to its last turn for $STUCK_FOR min; the cause is not known yet.
It gets a nudge now, and then every $POKE_EVERY min, until $(when $((SINCE + GIVE_UP_H * 3600))).
Look at its tab if you like; otherwise nothing to do. To switch this watch off:
systemctl --user disable --now orch-heartbeat.timer"
  ep_set "$ID" alarmed yes
  PORT=$((PORT + 1)); poke "$ID" "$NAME" "$SINCE" "$PORT"
  ep_set "$ID" pokes "$PORT" last_poke "$NOW"
  TICK_NOTE="stuck ${STUCK_FOR}m, alarmed + poke #$PORT ($NAME)"
elif [ $((NOW - LAST_POKE)) -ge $((POKE_EVERY * 60)) ]; then
  PORT=$((PORT + 1)); poke "$ID" "$NAME" "$SINCE" "$PORT"
  ep_set "$ID" pokes "$PORT" last_poke "$NOW"
  TICK_NOTE="stuck ${STUCK_FOR}m, poke #$PORT ($NAME)"
else
  TICK_NOTE="stuck ${STUCK_FOR}m, next poke pending ($NAME)"
fi
exit 0
