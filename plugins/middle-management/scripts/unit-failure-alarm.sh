#!/usr/bin/env bash
# middle-management plugin — the OnFailure= alarm for the heartbeat's systemd user units.
# Consumers: templates/systemd/unit-failure-alarm@.service (installed by /middle-management-setup
#   next to this script's copy); any further user unit may point OnFailure= at
#   unit-failure-alarm@%n.service. tests/heartbeat.sh, section D; tests/morning-headless.sh (cause
#   file), tests/morning-t3.sh (fallback route). Reads the cause file scripts/morning-headless.sh,
#   scripts/morning-t3.sh and scripts/guard-canary.sh leave. Nothing else calls it.
#
# A unit failed, so say so through the configured notifyCommand (config key; the text arrives as
# $1 and on stdin), and through notifyFallbackCommand when that one is missing or fails — an unattended failure must reach a human, never only a journal.
# Usage: unit-failure-alarm.sh <unit name>
# Ships the last 2 lines the unit's own process logged: never point it at a unit whose journal can
# carry a credential. Never prints a secret itself. A unit that knows WHY it failed writes that as
# <latch dir>/<unit>.cause (headline, what it means, what to do); then that text goes out instead,
# once — the file is consumed. Either way the text is written for a person on a phone: emoji +
# headline, a blank line, one fact per line, the command last, at most one `Detail:` line.
#
# LATCHED: at most one alarm per unit per hour. A unit that fails on every start (a bad path, a
# permission, a persistent timeout) would otherwise send 144 messages a day. A repeat says since
# when: <latch>.since keeps the first alarm of the run; a gap of two throttle periods starts anew.
set -uo pipefail

UNIT=${1:-unknown-unit}
CFG_DIR=${CLAUDE_CONFIG_DIR:-$HOME/.claude}
CFG_FILE=${UFA_CONFIG:-$CFG_DIR/middle-management.json}
LATCHDIR=${UFA_LATCH_DIR:-$CFG_DIR/state/unit-failure-alarm}
LATCH=$LATCHDIR/$(printf '%s' "$UNIT" | tr -c 'A-Za-z0-9._-' '_')
mkdir -p "$LATCHDIR" 2>/dev/null || true
NOW=$(date +%s)
LAST=$(cat "$LATCH" 2>/dev/null || echo 0)
case "$LAST" in ''|*[!0-9]*) LAST=0 ;; esac
THROTTLE=${UFA_THROTTLE_SEC:-3600}
if [ $((NOW - LAST)) -lt "$THROTTLE" ]; then
  echo "unit-failure-alarm: $UNIT alarmed $((NOW - LAST))s ago, throttled" >&2
  exit 0
fi
printf '%s\n' "$NOW" > "$LATCH" 2>/dev/null || true
FIRST=$(cat "$LATCH.since" 2>/dev/null); case "$FIRST" in ''|*[!0-9]*) FIRST=$NOW ;; esac
[ $((NOW - LAST)) -lt $((2 * THROTTLE)) ] || FIRST=$NOW
printf '%s\n' "$FIRST" > "$LATCH.since" 2>/dev/null || true
RESULT=$(systemctl --user show "$UNIT" -p Result --value 2>/dev/null || echo unknown)

# when <epoch>: 14:05 · tomorrow 07:00 · yesterday 22:55 · Thu 07:00 (within six days) · 12 Nov 07:00
# ponytail: the same function lives in orch-heartbeat.sh (copy dirs, see there).
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

if [ -s "$LATCH.cause" ]; then
  TEXT=$(head -c 1500 "$LATCH.cause"); rm -f "$LATCH.cause"
else
  # The job by what it does: the plugin's own units by name, any other by its Description=.
  case "$UNIT" in
    orch-heartbeat.service) JOB="The stuck-coordinator check" ;;
    lane-reaper.service) JOB="The lane cleanup" ;;
    t3-watch.service) JOB="The T3 watcher" ;;
    orch-morning-ritual.service) JOB="The morning report" ;;
    orch-morning-t3.service) JOB="The morning coordinator start" ;;
    orch-morning-watchdog.service) JOB="The morning check" ;;
    mm-guard-canary.service) JOB="The guard check" ;;
    *) JOB=$(systemctl --user show "$UNIT" -p Description --value 2>/dev/null || true)
       JOB="The job \"${JOB:-$UNIT}\"" ;;
  esac
  case "$RESULT" in timeout) WHY="It ran too long and was stopped." ;; *) WHY="It stopped with an error." ;; esac
  # The job's own last lines only (_SYSTEMD_USER_UNIT=): -u would add systemd's "Failed with result".
  # Cut by characters (a UTF-8 locale), never by bytes: a split character makes the sender fail.
  LOG=$(LC_ALL=C.UTF-8; l=$(journalctl --user _SYSTEMD_USER_UNIT="$UNIT" -n 2 --no-pager -o cat 2>/dev/null); l=${l//$'\n'/ · }; printf '%s' "${l:0:200}")
  TEXT="🔴 $JOB failed

$WHY The other background jobs are not affected.
See what happened:
journalctl --user -u ${UNIT} -n 50${LOG:+
Detail: $LOG}"
fi
# A repeat names since when, right under the headline.
if [ "$FIRST" != "$NOW" ]; then
  H1=${TEXT%%$'\n'*}; REST=${TEXT#"$H1"}
  TEXT="$H1

Still failing, since $(when "$FIRST") (this alarm repeats at most every $((THROTTLE / 60)) min).${REST#$'\n'}"
fi

# ponytail: the same lines live in orch-heartbeat.sh on purpose (different contracts).
CMD=$(jq -r '.notifyCommand // ""' "$CFG_FILE" 2>/dev/null || true)
# The second route (0.11.1): tried only when notifyCommand is missing or fails, so a dead main
# channel (expired bot token, provider outage) still reaches a human.
FB=$(jq -r '.notifyFallbackCommand // ""' "$CFG_FILE" 2>/dev/null || true)
# Output discarded, not journaled: a failing command may echo a URL that carries a token.
# The text goes in as a here-string, not through a pipe: under pipefail a command that exits before
# the pipe's writer ran (it does not read stdin) made the writer die of SIGPIPE, and a delivered
# message counted as failed. A here-string is written before the command starts.
send() { sh -c "$1" notify "$2" <<<"$2" >/dev/null 2>&1; }
if [ -n "$CMD" ]; then
  send "$CMD" "$TEXT" && exit 0
  echo "unit-failure-alarm: notifyCommand failed for $UNIT" >&2
else
  echo "unit-failure-alarm: no notifyCommand in $CFG_FILE" >&2
fi
if [ -n "$FB" ]; then
  send "$FB" "$TEXT

(Sent the backup way: the usual message channel failed. Please check it.)" \
    && { echo "unit-failure-alarm: delivered through notifyFallbackCommand" >&2; exit 0; }
  echo "unit-failure-alarm: notifyFallbackCommand failed too" >&2
fi
echo "unit-failure-alarm: alarm NOT delivered: $TEXT" >&2
exit 1
