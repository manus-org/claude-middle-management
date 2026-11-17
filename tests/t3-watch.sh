#!/usr/bin/env bash
# middle-management plugin: T3 watcher + sender matrix (fake HOME, local stubs, sends nothing real).
# Consumers: tests/run.sh (runs it with the other matrices); by hand from the repo root:
#   bash tests/t3-watch.sh
#
#   A  t3-wake.sh: 202 / 429 / timeout, no sidecar, unusable sidecar, Keepalive, thread lookup, --stats
#   B  t3-watch.py: no sidecar, healthy, scope separation
#   C  usage limit, workers only: notify once, onLimitCommand, 30-min probe cadence, wake, resolved,
#      "limit over" once per (thread, run id) across several periods
#   D  usage limit, coordinator too: Keepalive retry, "limit over" after the Keepalive went through
#   E  click pending >10 min · F stuck run >3 h · G other failure once per run id
#   H  report lost · I T3 API problems, I2 T3 URL (t3Url, loopback default) · J no coordinator · K dry-run · L topics.py hook · M handover
#   N  morning takeover pending: no wake into the night coordinator, notify instead
#   O  quiet reports: the inbox tick (fallback, never for status, debounce, dry-run, morning hold,
#      T3 API down, one failures line per episode, 24-h drop, held while the coordinator is
#      usage-limited and one digest when the limit is over)
#   Z  no webhook URL or token in any output
# One local HTTP stub serves both the T3 shell (GET, checks the protocol header and the bearer) and
# the webhook (POST, answers 202, 429 or sleeps past the timeout). `claude` is a stub on PATH.
# Time is driven with T3W_NOW from T0 = today 10:00 (like tests/topics.sh): the once-a-day notices
# and the morning hold read the day, so no offset below may cross midnight by accident, whatever the
# wall clock says when this runs. The scripts run from a copy, like the installed unit.
set -uo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
SRC=$ROOT/plugins/middle-management/scripts
TMP=$(mktemp -d /tmp/t3-watch-test.XXXXXX)
SP=""
trap '[ -n "$SP" ] && kill "$SP" 2>/dev/null; rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok()    { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad()   { FAIL=$((FAIL+1)); printf '  FAIL %s\n     expected: %s\n     got:      %s\n' "$1" "$2" "$3"; }
is()    { [ "$2" = "$3" ] && ok "$1" || bad "$1" "$3" "$2"; }
has()   { case "$3" in *"$2"*) ok "$1" ;; *) bad "$1" "contains: $2" "$3" ;; esac; }
lacks() { case "$3" in *"$2"*) bad "$1" "lacks: $2" "$3" ;; *) ok "$1" ;; esac; }

S=$TMP/s; mkdir -p "$S"
cp "$SRC"/{t3-watch.py,t3-wake.sh,t3-inbox.py,peer-state.py,t3-token.sh,scope.py,config-check.sh} "$S/"
H=$TMP/home; CFG=$H/.claude; mkdir -p "$CFG/state" "$H/.t3/userdata/logs/provider" "$TMP/bin" "$TMP/repo" "$TMP/ff"
TOKEN="tok-$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')"
printf '%s\n' "$TOKEN" > "$TMP/token"; chmod 600 "$TMP/token"
PORT=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')
SECRET="hooksecret$RANDOM$RANDOM"
URL="http://127.0.0.1:$PORT/api/hooks/task%3Areport/$SECRET"

cat > "$TMP/stub.py" <<'EOF'
import http.server, json, os, sys, time
D, TOK = sys.argv[2], open(sys.argv[3]).read().strip()
def rd(n, d=""):
    try: return open(os.path.join(D, n)).read().strip()
    except OSError: return d
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        open(os.path.join(D, "get.log"), "a").write("GET\n")
        if self.headers.get("x-t3-orchestration-protocol") != "2": return self.answer(400)
        if self.headers.get("authorization") != "Bearer " + TOK: return self.answer(401)
        code = int(rd("shell.code", "200"))
        self.answer(code, open(os.path.join(D, "shell.json"), "rb").read() if code == 200 else b"")
    def do_POST(self):
        b = self.rfile.read(int(self.headers.get("content-length", 0)))
        mode = rd("hook.mode", "202")
        open(os.path.join(D, "hook.log"), "ab").write(b.rstrip(b"\n") + b"\n")   # first: no late write
        if mode == "sleep": time.sleep(3); mode = "202"
        self.answer(int(mode))
    def answer(self, code, body=b""):
        self.send_response(code); self.send_header("content-length", str(len(body))); self.end_headers()
        try: self.wfile.write(body)
        except OSError: pass          # the timeout case: the client has gone
    def log_message(self, *a): pass
http.server.ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
EOF
python3 "$TMP/stub.py" "$PORT" "$TMP" "$TMP/token" & SP=$!

cat > "$TMP/bin/claude" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$TMP/probe.log"
case "\$(cat "$TMP/probe.mode" 2>/dev/null)" in
  ok) echo '{"is_error":false,"result":"ok"}' ;;
  *)  echo '{"is_error":true,"result":"You have hit your limit","api_error_status":429,"api_error_code":"usage_limit_reached"}' ;;
esac
EOF
chmod +x "$TMP/bin/claude"

cat > "$CFG/middle-management.json" <<EOF
{"notifyCommand": "tee -a $TMP/all-notify.log >> $TMP/notify.log; printf '\\\\n----\\\\n' >> $TMP/notify.log",
 "onLimitCommand": "echo \"\$@\" >> $TMP/onlimit.log",
 "t3TokenFile": "$TMP/token",
 "t3Url": "http://127.0.0.1:$PORT",
 "scopes": [{"name": "ff", "root": "$TMP/ff", "board": "$TMP/ff-board.md"}]}
EOF
SIDE=$CFG/state/orchestrator.t3.json
sidecar() {  # $1 = coordinator thread id
  printf '{"sessionId":"sid-coord","threadId":"%s","title":"Koordinator","model":"claude-fable-5","reportTaskId":"task:report","reportUrl":"%s"}\n' "$1" "$URL" > "$SIDE"
  chmod 600 "$SIDE"; }

# shell '<json list of thread overrides>' - each merges onto a healthy, idle, top-level thread
shell() {
  python3 - "$TMP/shell.json" "$TMP/repo" "$TMP/ff" "$1" <<'EOF'
import json, sys
out, repo, ff, spec = sys.argv[1:]
base = {"id": "", "projectId": "p1", "title": "", "status": "completed", "activityRunStatus": None,
        "activeRunId": None, "latestRunId": "run:1", "lastError": None, "lastErrorClass": None,
        "usageLimitResetAt": None, "pendingRuntimeRequest": None, "itemCount": 10, "settledAt": None,
        "archivedAt": None, "deletedAt": None, "lineage": None,
        "modelSelection": {"instanceId": "claudeAgent", "model": "claude-opus-5-5"}}
ts = []
for o in json.loads(spec):
    t = dict(base); t.update(o); t.setdefault("title", t["id"]); ts.append(t)
json.dump({"schemaVersion": 2, "threads": ts, "archivedThreads": [],
           "projects": [{"id": "p1", "workspaceRoot": repo}, {"id": "p2", "workspaceRoot": ff}]}, open(out, "w"))
EOF
}
COORD_OK='{"id":"mcp:coord","title":"Koordinator","model":"x","modelSelection":{"model":"claude-fable-5"}}'
LIMITED='"status":"failed","lastErrorClass":"usage_limit","usageLimitResetAt":"2026-10-20T08:00:00.000Z"'

T0=$(date -d "today 10:00" +%s)   # a fixed hour, never the clock: +600 s or +1800 s must stay on T0's day
tick() {  # $1 = seconds after T0; extra args to t3-watch.py
  local at=$1; shift
  HOME="$H" CLAUDE_CONFIG_DIR="" T3CODE_HOME="" CLAUDE_CODE_SESSION_ID="" T3CODE_PORT=1 \
    T3W_NOW=$((T0 + at)) PATH="$TMP/bin:$PATH" python3 "$S/t3-watch.py" "$@" 2>>"$TMP/stderr.log"
}
wakecall() {  # $1 = from, $2 = file|--keepalive; env passes through
  HOME="$H" CLAUDE_CONFIG_DIR="" T3CODE_HOME="" CLAUDE_CODE_SESSION_ID="" T3_WAKE_TIMEOUT=1 \
    bash "$S/t3-wake.sh" "$@" 2>>"$TMP/stderr.log"
}
reset() { rm -rf "$CFG/state/t3-watch" "$TMP/notify.log" "$TMP/hook.log" "$TMP/probe.log" "$TMP/onlimit.log" "$TMP/get.log"
          rm -f "$TMP/shell.code" "$TMP/hook.mode" "$TMP/probe.mode"
          [ -f "$CFG/state/t3-report/failures.log" ] && : > "$CFG/state/t3-report/failures.log"; }
notes()  { cat "$TMP/notify.log" 2>/dev/null; }
nnote()  { cat "$TMP/notify.log" 2>/dev/null | grep -c '^----$'; }
hooks()  { cat "$TMP/hook.log" 2>/dev/null; }
nhook()  { [ -f "$TMP/hook.log" ] && wc -l < "$TMP/hook.log" | tr -d ' ' || echo 0; }
nprobe() { [ -f "$TMP/probe.log" ] && wc -l < "$TMP/probe.log" | tr -d ' ' || echo 0; }
for _ in $(seq 50); do curl -s -o /dev/null "http://127.0.0.1:$PORT/" && break; sleep 0.1; done

# ------------------------------------------------------------------------------------------ A --
echo "A. t3-wake.sh"
echo "the report text" > "$TMP/r.txt"
wakecall lane-x "$TMP/r.txt"; is "no sidecar -> exit 3" "$?" 3
sidecar mcp:coord
printf '{"session_id":"sid-w9"}\n' > "$H/.t3/userdata/logs/provider/events.mcp:w9.log"
MM_SESSION_ID=sid-w9 wakecall lane-x "$TMP/r.txt"; is "202 -> exit 0" "$?" 0
B=$(hooks | tail -1)
is "body: from/session/thread/report" "$(printf '%s' "$B" | jq -c '[.from,.session,.thread,.report]')" '["lane-x","sid-w9","mcp:w9","the report text"]'
# The line for the coordinator, pinned once here and in tests/t3-inbox.sh (FOR_COORDINATOR in t3-wake.sh and t3-inbox.py).
FC="For the coordinator, not for your user: take these reports in and book them. In a turn a worker report or a wake started, write to your user only what matters to them: nothing if nothing does, one short line if something is new, never an earlier answer again."
is "body: a worker's report: head with from + thread, the line for the coordinator under it, then the report" "$(printf '%s' "$B" | jq -r .prompt)" "Report from lane-x (thread mcp:w9):
$FC
the report text"
is "posts.tsv counts the delivered post" "$(tail -1 "$CFG/state/t3-report/posts.tsv")" "$(date +%F)	lane-x	sid-w9	mcp:w9"
MM_SESSION_ID="" wakecall telegram-user "$TMP/r.txt"
is "a sender that is no session (your user's channel poller) -> wrapped as before, no line for the coordinator" "$(hooks | tail -1 | jq -r .prompt)" "Report from telegram-user (thread unknown): the report text"
MM_SESSION_ID=sid-w9 wakecall coord-two --notice "$TMP/r.txt"; is "--notice (t3-bind's takeover wake) -> exit 0" "$?" 0
is "...a session's notice: wrapped as before, no line for the coordinator" "$(hooks | tail -1 | jq -r .prompt)" "Report from coord-two (thread mcp:w9): the report text"
is "...its session and thread stay in the body" "$(hooks | tail -1 | jq -c '[.session,.thread]')" '["sid-w9","mcp:w9"]'
printf '{"session_id":"sid-w9"}\n' > "$H/.t3/userdata/logs/provider/events.mcp-other.log"
MM_SESSION_ID=sid-w9 wakecall lane-x "$TMP/r.txt"
is "two provider logs name the session -> thread unknown" "$(hooks | tail -1 | jq -r .thread)" unknown
rm -f "$H/.t3/userdata/logs/provider/events.mcp-other.log"
python3 -c 'print("x" * 5000)' > "$TMP/long.txt"
wakecall lane-x "$TMP/long.txt"
is "report cut at 4000 chars" "$(hooks | tail -1 | jq -r '.report | length')" 4000
MM_SESSION_ID="" wakecall t3-watch --keepalive
is "--keepalive body is exactly Keepalive" "$(hooks | tail -1 | jq -c '[.from,.session,.report]')" '["t3-watch","","Keepalive"]'
is "--keepalive prompt is exactly Keepalive (never wrapped)" "$(hooks | tail -1 | jq -r .prompt)" Keepalive
echo 429 > "$TMP/hook.mode"
MM_SESSION_ID=sid-w9 wakecall lane-x "$TMP/r.txt"; is "429 -> exit 4" "$?" 4
has "failures.log names the reason" "http 429" "$(tail -1 "$CFG/state/t3-report/failures.log")"
echo sleep > "$TMP/hook.mode"
wakecall lane-x "$TMP/r.txt"; is "timeout -> exit 4" "$?" 4
has "timeout logged as http 000" "http 000" "$(tail -1 "$CFG/state/t3-report/failures.log")"
rm -f "$TMP/hook.mode"
is "failures.log has 2 lines" "$(wc -l < "$CFG/state/t3-report/failures.log" | tr -d ' ')" 2
chmod 644 "$SIDE"; wakecall lane-x "$TMP/r.txt"; is "sidecar readable by others -> exit 4" "$?" 4; chmod 600 "$SIDE"
MM_SCOPE_CWD="$TMP/ff" wakecall lane-ff "$TMP/r.txt"; is "other scope without sidecar -> exit 3" "$?" 3
MM_SCOPE=ff wakecall lane-ff "$TMP/r.txt"; is "MM_SCOPE=ff without sidecar -> exit 3" "$?" 3
MM_SCOPE=default wakecall t3-watch --keepalive; is "MM_SCOPE=default finds the sidecar" "$?" 0
OUT=$(HOME="$H" CLAUDE_CONFIG_DIR="" python3 "$S/t3-watch.py" --stats)
has "--stats counts per day and thread" "$(date +%F)	1	mcp:w9	lane-x" "$OUT"
has "--stats counts the watcher's posts" "$(date +%F)	2	unknown	t3-watch" "$OUT"
: > "$CFG/state/t3-report/failures.log"

# ------------------------------------------------------------------------------------------ B --
echo "B. watcher basics"
reset; rm -f "$SIDE"
shell "[$COORD_OK]"; tick 0
is "no sidecar -> no GET at all" "$([ -f "$TMP/get.log" ] && echo got || echo none)" none
sidecar mcp:coord
shell "[$COORD_OK, {\"id\":\"mcp:w1\"}, {\"id\":\"mcp:ff1\",\"projectId\":\"p2\",$LIMITED}, {\"id\":\"mcp:sub\",\"lineage\":{\"relationshipToParent\":\"subagent\"},$LIMITED}, {\"id\":\"mcp:old\",\"settledAt\":\"x\",$LIMITED}]"
tick 0; is "healthy + foreign scope + sub-agent + settled -> silent, exit 0" "$?/$(nnote)/$(nhook)" "0/0/0"
is "one GET per tick" "$(wc -l < "$TMP/get.log" | tr -d ' ')" 1

# ------------------------------------------------------------------------------------------ C --
echo "C. usage limit, workers only (probe)"
reset
shell "[$COORD_OK, {\"id\":\"mcp:w1\",\"title\":\"lane one\",$LIMITED}]"
tick 0
has "notify headline: what happened" "🔴 Usage limit: 1 session is paused" "$(notes | head -1)"
has "notify names the thread by title, the reset in local time" "• lane one (until $(LC_ALL=C date -d 2026-10-20T08:00:00Z '+%d %b %H:%M'))" "$(notes)"
has "...what happens next" "When the limit is over, the coordinator restarts the paused workers" "$(notes)"
lacks "...no coordinator line when only a worker is limited" "does not resume its own task" "$(notes)"
has "notify says what to do, last (the reset is past)" "Switch the subscription, or wait for the reset." "$(notes | sed -n '/^----$/q;p' | grep . | tail -1)"
is "onLimitCommand got the thread id" "$(cat "$TMP/onlimit.log" 2>/dev/null)" "mcp:w1"
is "no probe at episode start" "$(nprobe)" 0
tick 600; is "latched: no second notify, no probe at +10 min" "$(nnote)/$(nprobe)" "1/0"
tick 1800; is "probe at +30 min" "$(nprobe)" 1
has "probe uses the limited model, no tools, no settings" "-p ok --model claude-opus-5-5 --output-format json --no-session-persistence --strict-mcp-config --tools  --setting-sources" "$(cat "$TMP/probe.log")"
is "probe limited -> no wake" "$(nhook)" 0
tick 2400; is "cadence: no probe at +40 min" "$(nprobe)" 1
echo ok > "$TMP/probe.mode"
tick 3600; is "probe passes at +60 min -> one wake" "$(nprobe)/$(nhook)" "2/1"
R=$(hooks | tail -1 | jq -r .report)
has "wake: limit over" "limit over for:" "$R"
has "wake: names the thread" "lane one (mcp:w1)" "$R"
has "wake: says what to send" "send 'Continue where you left off.' to each" "$R"
is "onLimitCommand once per episode" "$(wc -l < "$TMP/onlimit.log" | tr -d ' ')" 1
shell "[$COORD_OK, {\"id\":\"mcp:w1\",\"title\":\"lane one\",\"status\":\"failed\"}]"
tick 3900; lacks "lastErrorClass cleared, same failed run: still limited" "working again" "$(notes)"
shell "[$COORD_OK, {\"id\":\"mcp:w1\",\"title\":\"lane one\",\"lastErrorClass\":\"usage_limit\"}]"
tick 4000; lacks "completed with the SAME run id: not over" "working again" "$(notes)"
shell "[$COORD_OK, {\"id\":\"mcp:w1\",\"title\":\"lane one\",\"lastErrorClass\":\"usage_limit\",\"latestRunId\":\"run:2\"}]"
tick 4200; has "episode end -> resolved, one line" "🟡 Limit over: the session paused since " "$(notes)"
has "...since the episode start, local time" "$(date -d @"$T0" +%H:%M) is working again." "$(notes)"
tick 4800; is "resolved only once" "$(grep -c 'working again' "$TMP/notify.log")" 1

reset
shell "[$COORD_OK, {\"id\":\"mcp:w7\",\"title\":\"lane seven\",\"status\":\"failed\",\"lastErrorClass\":\"usage_limit\"}]"
tick 0; has "no usageLimitResetAt -> reset time unknown" "• lane seven (reset time unknown)" "$(notes)"
has "...and the action waits for the reset" "Switch the subscription, or wait for the reset." "$(notes)"
reset
FUT=$(date -u -d @$((T0 + 7200)) +%Y-%m-%dT%H:%M:%S.000Z)
shell "[$COORD_OK, {\"id\":\"mcp:w6\",\"title\":\"lane six\",\"status\":\"failed\",\"lastErrorClass\":\"usage_limit\",\"usageLimitResetAt\":\"$FUT\"}]"
tick 0; has "a future reset -> the action names it" "Switch the subscription, or wait until " "$(notes)"
has "...in local time, as the last line" "$(date -d @$((T0 + 7200)) +%H:%M)." "$(notes | sed -n '/^----$/q;p' | grep . | tail -1)"
reset
shell "[$COORD_OK, {\"id\":\"mcp:w8\",\"title\":\"lane eight\",\"status\":\"running\",\"activityRunStatus\":\"running\",\"activeRunId\":\"r8\",$LIMITED}]"
tick 0; shell "[$COORD_OK, {\"id\":\"mcp:w8\",\"title\":\"lane eight\",$LIMITED}]"; tick 600
shell "[$COORD_OK, {\"id\":\"mcp:w8\",\"title\":\"lane eight\",\"status\":\"running\",\"activityRunStatus\":\"running\",\"activeRunId\":\"r9\",$LIMITED}]"
tick 1200; has "a live run ends the episode, lastErrorClass still set" "working again" "$(notes)"

# "limit over" once per (thread, run id), checked across several 30-min periods
reset; echo ok > "$TMP/probe.mode"
shell "[$COORD_OK, {\"id\":\"mcp:w1\",\"title\":\"lane one\",$LIMITED}]"
tick 0; tick 1800; is "probe passes at +30 min -> one wake" "$(nprobe)/$(nhook)" "1/1"
shell "[$COORD_OK, {\"id\":\"mcp:w1\",\"title\":\"lane one\",$LIMITED}, {\"id\":\"mcp:w2\",\"title\":\"lane two\",$LIMITED}]"
tick 2400; tick 3600; is "a newly limited worker is probed and announced" "$(nprobe)/$(nhook)" "2/2"
has "...naming the new worker" "lane two (mcp:w2)" "$(hooks | tail -1 | jq -r .report)"
lacks "...not the one already announced" "lane one (mcp:w1)" "$(hooks | tail -1 | jq -r .report)"
tick 5400; tick 7200; tick 9000
is "not continued for 3 more periods: no probe, no wake" "$(nprobe)/$(nhook)" "2/2"
shell "[$COORD_OK, {\"id\":\"mcp:w1\",\"title\":\"lane one\",$LIMITED,\"latestRunId\":\"run:3\"}, {\"id\":\"mcp:w2\",\"title\":\"lane two\",$LIMITED}]"
tick 10800; is "a new limited run of an announced worker is announced again" "$(nprobe)/$(nhook)" "3/3"
has "...naming that worker" "lane one (mcp:w1)" "$(hooks | tail -1 | jq -r .report)"
lacks "...not the other" "lane two (mcp:w2)" "$(hooks | tail -1 | jq -r .report)"

# ------------------------------------------------------------------------------------------ D --
echo "D. usage limit, coordinator limited too (Keepalive)"
reset
shell "[{\"id\":\"mcp:coord\",\"title\":\"Koordinator\",$LIMITED}, {\"id\":\"mcp:w1\",\"title\":\"lane one\",$LIMITED}]"
tick 0; has "both threads notified" "• Koordinator (coordinator, until" "$(notes)"; has "...and the worker" "• lane one (until" "$(notes)"
has "...the coordinator's own task does not resume by itself" "The coordinator does not resume its own task" "$(notes)"
tick 1200; is "no retry before 30 min" "$(nhook)" 0
tick 1800; is "retry at +30 min = exactly Keepalive" "$(hooks | jq -r .report)" Keepalive
is "no probe while the coordinator is limited" "$(nprobe)" 0
tick 2400; is "still limited: no second Keepalive at +40 min" "$(nhook)" 1
shell "[{\"id\":\"mcp:coord\",\"title\":\"Koordinator\",\"status\":\"running\",\"activityRunStatus\":\"running\",\"activeRunId\":\"r9\",\"lastErrorClass\":\"usage_limit\"}, {\"id\":\"mcp:w1\",\"title\":\"lane one\",$LIMITED}]"
tick 2700; is "Keepalive run live -> wait" "$(nhook)" 1
shell "[{\"id\":\"mcp:coord\",\"title\":\"Koordinator\",\"status\":\"completed\",\"lastErrorClass\":\"usage_limit\",\"latestRunId\":\"run:2\"}, {\"id\":\"mcp:w1\",\"title\":\"lane one\",$LIMITED}]"
tick 3000; is "Keepalive went through -> limit over, no probe" "$(nhook)/$(nprobe)" "2/0"
has "...naming the worker" "lane one (mcp:w1)" "$(hooks | tail -1 | jq -r .report)"
lacks "...not the coordinator" "Koordinator (mcp:coord)" "$(hooks | tail -1 | jq -r .report)"
tick 3600; tick 4800; tick 6600; tick 8400
is "limit over is sent once, no probe after it (4 more periods)" "$(nhook)/$(nprobe)" "2/0"

# ------------------------------------------------------------------------------------------ E --
echo "E. click pending"
reset
shell "[$COORD_OK, {\"id\":\"mcp:w2\",\"title\":\"lane two\",\"status\":\"waiting\",\"pendingRuntimeRequest\":{\"id\":\"req1\",\"type\":\"approval\"}}]"
tick 0; is "seen first: no notify" "$(nnote)" 0
tick 599; is "9:59 min: no notify" "$(nnote)" 0
tick 600; has "10 min: notify" "⏳ A session waits for your answer: lane two" "$(notes)"
tick 1200; is "once per request" "$(nnote)" 1
shell "[$COORD_OK, {\"id\":\"mcp:w2\",\"title\":\"lane two\",\"status\":\"waiting\",\"pendingRuntimeRequest\":{\"id\":\"req2\"}}]"
tick 1800; tick 2400; is "a new request is a new episode" "$(nnote)" 2

# ------------------------------------------------------------------------------------------ F --
echo "F. stuck run"
reset
RUN='"status":"running","activityRunStatus":"running","activeRunId":"r1"'
shell "[$COORD_OK, {\"id\":\"mcp:w3\",\"title\":\"lane three\",$RUN,\"itemCount\":5}, {\"id\":\"mcp:w4\",\"title\":\"lane four\",$RUN,\"itemCount\":7}]"
tick 0; tick 7200
shell "[$COORD_OK, {\"id\":\"mcp:w3\",\"title\":\"lane three\",$RUN,\"itemCount\":5}, {\"id\":\"mcp:w4\",\"title\":\"lane four\",$RUN,\"itemCount\":8}]"
tick 10799; is "under 3 h: silent" "$(nnote)" 0
tick 10800; has "3 h without a new item: notify" "🔴 A session may hang: lane three" "$(notes)"
lacks "a run with a new item is not stuck" "lane four" "$(notes)"
tick 14400; is "once per run" "$(nnote)" 1

# ------------------------------------------------------------------------------------------ G --
echo "G. other failure"
reset
shell "[$COORD_OK, {\"id\":\"mcp:w5\",\"title\":\"lane five\",\"status\":\"failed\",\"lastErrorClass\":\"provider_error\",\"lastError\":\"Claude API is overloaded (529).\",\"latestRunId\":\"run5\"}]"
tick 0; is "worker failure -> one wake" "$(nhook)" 1
has "wake names thread and class" "other failure in lane five (mcp:w5): provider_error" "$(hooks | jq -r .report)"
tick 600; is "same run id: no second wake" "$(nhook)" 1
shell "[$COORD_OK, {\"id\":\"mcp:w5\",\"title\":\"lane five\",\"status\":\"failed\",\"lastErrorClass\":\"provider_error\",\"latestRunId\":\"run6\"}]"
tick 1200; is "new run id -> wake again" "$(nhook)" 2
shell "[{\"id\":\"mcp:coord\",\"title\":\"Koordinator\",\"status\":\"failed\",\"lastErrorClass\":\"provider_error\",\"latestRunId\":\"c1\"}]"
tick 1800; is "coordinator failure -> notify, no wake" "$(nnote)/$(nhook)" "1/2"
has "...the notify says so" "🔴 The coordinator's last run failed: Koordinator" "$(notes)"
has "...the error class as the last line" "Detail: provider_error" "$(notes | sed -n '/^----$/q;p' | grep . | tail -1)"

# ------------------------------------------------------------------------------------------ H --
echo "H. report lost"
reset; shell "[$COORD_OK]"
echo 429 > "$TMP/hook.mode"; MM_SESSION_ID=sid-w9 wakecall lane-x "$TMP/r.txt"; rm -f "$TMP/hook.mode"
tick 0; has "lost report -> notify" "🔴 1 worker report did not reach the coordinator" "$(notes)"
has "...with sender and reason in words" "lane-x: refused (HTTP 429)" "$(notes)"
tick 600; is "once per line" "$(nnote)" 1
: > "$CFG/state/t3-report/failures.log"; MM_SESSION_ID=sid-w9 T3_WAKE_TIMEOUT=1 bash -c 'echo 503 > '"$TMP"'/hook.mode'
wakecall lane-y "$TMP/r.txt"; rm -f "$TMP/hook.mode"
tick 1200; has "a truncated log is read from the top" " lane-y: refused (HTTP 503)" "$(notes)"
has "...a session's report: read it there" "A report from a session is still in that session" "$(notes)"
reset; shell "[$COORD_OK]"; FL=$CFG/state/t3-report/failures.log
printf '%s\tt3-watch\t-\tunknown\thttp 404\n' "$(date -Is)" >> "$FL"; tick 0
has "the watcher's own wake lost -> named as such" "the watcher's notice: refused (HTTP 404)" "$(notes)"
has "...a message, not a worker report" "🔴 1 message did not reach the coordinator" "$(notes)"
has "...what is retried and what is not" "A notice about a failed session is not retried: check T3 for failed sessions." "$(notes)"
lacks "...no 'read it in the session' for the watcher" "still in that session" "$(notes)"
reset; shell "[$COORD_OK]"
printf '%s\tt3-watch\t-\t-\tdigest wake failed (http 000), 2 report(s) stay queued in the inbox; the watcher retries every 10 min\n' "$(date -Is)" >> "$FL"
printf '%s\tsidecar-check\t-\tunknown\tsidecar mode is not 0600\n' "$(date -Is)" >> "$FL"; tick 0
has "a quiet digest lost -> queued and retried" "quiet-report digest: no answer; the reports stay queued and are retried every 10 min" "$(notes)"
has "a broken sidecar -> what to do in words" "the coordinator's seat file is broken: have the coordinator claim the seat again" "$(notes)"
lacks "...no raw sidecar wording" "0600" "$(notes)"
reset; shell "[$COORD_OK]"
printf '%s\tt3-watch\t-\t-\tdigest wake failed (http 429), 1 report(s) stay queued in the inbox; the watcher retries every 10 min\n' "$(date -Is)" >> "$FL"; tick 0
is "digest lines only -> nothing to do, as the action" "Nothing to do now." "$(notes | sed -n '/^----$/q;p' | grep . | tail -1)"

# ------------------------------------------------------------------------------------------ I --
echo "I. T3 API problems"
reset; shell "[$COORD_OK]"
echo 400 > "$TMP/shell.code"
tick 0; RC=$?; has "400 -> T3 API changed" "⚠️ T3 watcher paused: it no longer understands T3 Code" "$(notes)"; is "...exit 0, no crash" "$RC" 0
has "...says what still works" "Lost reports and topic reminders still come through." "$(notes)"
tick 600; is "once per day" "$(nnote)" 1
lacks "...the first notice has no 'Still'" "Still so since" "$(notes)"
tick 86400; is "the next day it repeats" "$(nnote)" 2
has "...saying since when" "Still so since yesterday $(date -d @"$T0" +%H:%M) (this repeats once a day)." "$(notes)"
rm -f "$TMP/shell.code"; tick 87000; echo 400 > "$TMP/shell.code"; tick 172800
is "...a good answer in between: the next notice is a first one again" "$(nnote)/$(grep -c 'Still so since' "$TMP/notify.log")" "3/1"
reset; python3 -c 'import json; json.dump({"threads":[{"id":"x"}],"projects":[]}, open("'"$TMP"'/shell.json","w"))'
tick 0; has "missing keys -> T3 API changed" "lacks keys" "$(notes)"
reset; shell "[$COORD_OK]"; chmod 644 "$TMP/token"
tick 0; has "group-readable token refused" "its token file is readable by others" "$(notes)"
has "...the fix is the command" "Fix: chmod 600 $TMP/token" "$(notes)"
is "...and never sent" "$([ -f "$TMP/get.log" ] && echo got || echo none)" none
chmod 600 "$TMP/token"
reset
cp "$CFG/middle-management.json" "$TMP/cfg.bak"
jq '.t3Url = "http://127.0.0.1:1"' "$TMP/cfg.bak" > "$CFG/middle-management.json"
HOME="$H" CLAUDE_CONFIG_DIR="" T3W_NOW=$T0 python3 "$S/t3-watch.py" 2>>"$TMP/stderr.log"
is "server down once: silent (restart grace)" "$(nnote)" 0
HOME="$H" CLAUDE_CONFIG_DIR="" T3W_NOW=$((T0+600)) python3 "$S/t3-watch.py" 2>>"$TMP/stderr.log"
has "server down twice: notify" "⚠️ T3 watcher paused: T3 Code does not answer" "$(notes)"

echo "I2. T3 URL: config t3Url, default loopback on T3CODE_PORT"
reset; shell "[$COORD_OK]"
jq 'del(.t3Url)' "$TMP/cfg.bak" > "$CFG/middle-management.json"
HOME="$H" CLAUDE_CONFIG_DIR="" T3CODE_HOME="" T3CODE_PORT="$PORT" T3W_NOW=$T0 python3 "$S/t3-watch.py" 2>>"$TMP/stderr.log"
is "no t3Url -> 127.0.0.1:\$T3CODE_PORT, healthy and silent" "$(wc -l < "$TMP/get.log" 2>/dev/null | tr -d ' ')/$(nnote)" "1/0"
lacks "no buildos tailnet IP default in the scripts" "100.125.193.62" "$(cat "$SRC/t3-watch.py" "$SRC/t3-token.sh")"
tok() { HOME="$H" CLAUDE_CONFIG_DIR="" T3CODE_PORT="${1:-1}" T3_BIN=false bash "$S/t3-token.sh" --check 2>&1; }
OUT=$(tok "$PORT"); is "t3-token.sh --check, no t3Url -> loopback on T3CODE_PORT, accepted" "$OUT" "token: accepted"
cp "$TMP/cfg.bak" "$CFG/middle-management.json"
OUT=$(tok 1); is "t3-token.sh --check uses t3Url from the config" "$OUT" "token: accepted"
printf 'wrong\n' > "$TMP/token.bad"; chmod 600 "$TMP/token.bad"
jq --arg t "$TMP/token.bad" '.t3TokenFile = $t' "$TMP/cfg.bak" > "$CFG/middle-management.json"
OUT=$(tok 1); RC=$?; is "...a rejected token -> exit 2, nothing minted" "$RC/$OUT" "2/token: missing or rejected"
cp "$TMP/cfg.bak" "$CFG/middle-management.json"

# ------------------------------------------------------------------------------------------ J --
echo "J. no coordinator"
reset; sidecar mcp:gone; shell "[$COORD_OK]"
tick 0; has "sidecar thread missing -> notify" "🔴 No coordinator: the seat names a closed session" "$(notes)"
has "...names the holder by title" "\"Koordinator\" holds the seat, but it no longer exists." "$(notes)"
tick 600; is "once per episode" "$(nnote)" 1
sidecar mcp:coord; tick 1200; has "back -> resolved, one line" "🟡 Coordinator is back: \"Koordinator\" holds the seat." "$(notes)"

# ------------------------------------------------------------------------------------------ K --
echo "K. dry-run"
reset
shell "[{\"id\":\"mcp:coord\",\"title\":\"Koordinator\",$LIMITED}]"
OUT=$(tick 0 --dry-run); has "dry-run prints the notify" "NOTIFY" "$OUT"
OUT=$(tick 1800 --dry-run); has "dry-run keeps no state (episode starts again)" "NOTIFY" "$OUT"
is "dry-run sends nothing" "$(nnote)/$(nhook)/$([ -d "$CFG/state/t3-watch" ] && ls "$CFG/state/t3-watch" | wc -l || echo 0)" "0/0/0"
rm -f "$SIDE"; OUT=$(tick 0 --dry-run)
has "dry-run evaluates a scope without sidecar" "SCOPE   default: no sidecar" "$OUT"
sidecar mcp:coord

# ------------------------------------------------------------------------------------------ L --
echo "L. topics.py hook"
reset; shell "[$COORD_OK]"
tick 0; is "no topics.py -> skipped silently" "$?" 0
printf 'import sys\nopen("%s/topics.log","a").write(" ".join(sys.argv[1:]) + "\\n")\n' "$TMP" > "$S/topics.py"
tick 600
is "topics.py tick per scope" "$(cat "$TMP/topics.log")" "tick --scope default
tick --scope ff"
rm -f "$S/topics.py"

# ------------------------------------------------------------------------------------------ M --
echo "M. handover"
reset; shell "[$COORD_OK, {\"id\":\"mcp:c2\",\"title\":\"Koordinator 2\"}]"
handover() {  # $1 = sidecar thread id, $2 = since (epoch)
  jq -c --arg t "$1" --argjson s "$2" '.threadId = $t | .handover = {toThreadId: "mcp:c2", toTitle: "Koordinator 2", since: $s}' "$SIDE" > "$SIDE.new"
  mv "$SIDE.new" "$SIDE"; chmod 600 "$SIDE"; }
handover mcp:coord $((T0 - 1000))
tick 0; is "16 min open: silent" "$(nnote)" 0
tick 801; has "over 30 min: notify" "⏳ Coordinator handover stuck: \"Koordinator 2\" has not taken the seat" "$(notes)"
has "...the old holder keeps the seat" "\"Koordinator\" keeps the seat until then." "$(notes)"
has "...what to do" "Open \"Koordinator 2\" in T3 and have it run /orchestrator claim." "$(notes)"
tick 1800; is "once per handover" "$(nnote)" 1
handover mcp:coord $((T0 + 1000)); tick 4000; is "a new handover notifies again" "$(nnote)" 2
reset; handover mcp:c2 $((T0 - 7200)); tick 0
lacks "the successor claimed (sidecar names it): silent" "handover" "$(notes)"
sidecar mcp:coord

echo "N. morning takeover pending: the night coordinator is never woken"
morning() {  # posted at T0+1500 s: the hold covers ticks up to T0+3300 s; the sidecar predates the post (T0-relative, like the post)
  mkdir -p "$CFG/state/morning-t3"; printf '%s\tposted\t%s\t1\n' "$(date +%F)" "$((T0 + 1500))" > "$CFG/state/morning-t3/status"; touch -d "@$((T0 - 3600))" "$SIDE"; }
reset; sidecar mcp:coord; morning; echo ok > "$TMP/probe.mode"
shell "[$COORD_OK, {\"id\":\"mcp:morning\",\"title\":\"morning\",$LIMITED}]"
tick 0; has "the limited morning thread is notified" "• morning (until" "$(notes)"
tick 1800; is "probe passes -> no wake into the night coordinator" "$(nprobe)/$(nhook)" "1/0"
has "...the user gets limit over instead" "⏳ Limit over: restart 1 paused session yourself" "$(notes)"
has "...saying the night coordinator is not woken" "The night coordinator \"Koordinator\" is not woken" "$(notes)"
has "...and what to send" "Open it in T3 and send 'Continue where you left off.'" "$(notes)"
tick 3600; is "...once per run id" "$(grep -c 'Limit over: restart' "$TMP/notify.log")" 1
reset; sidecar mcp:coord; morning
shell "[{\"id\":\"mcp:coord\",\"title\":\"Koordinator\",$LIMITED}]"
tick 0; tick 1800; is "limited night coordinator: no Keepalive while the morning claim is pending" "$(nhook)" 0
reset; sidecar mcp:coord; morning
shell "[$COORD_OK, {\"id\":\"mcp:morning\",\"title\":\"morning\",\"status\":\"failed\",\"lastErrorClass\":\"provider_error\",\"lastError\":\"boom\"}]"
tick 0; is "other failure: no wake" "$(nhook)" 0; has "...notify instead" "🔴 A session stopped with an error: morning" "$(notes)"
has "...the raw error only as the last line" "Detail: provider_error: boom" "$(notes | sed -n '/^----$/q;p' | grep . | tail -1)"
reset; sidecar mcp:coord; morning; touch -d "@$((T0 + 3600))" "$SIDE"; echo ok > "$TMP/probe.mode"
shell "[$COORD_OK, {\"id\":\"mcp:w1\",\"title\":\"lane one\",$LIMITED}]"
tick 0; tick 1800; is "the sidecar is newer than the post (bound): wakes as before" "$(nhook)" 1
reset; sidecar mcp:coord; morning; sed -i "s/^$(date +%F)/2000-01-01/" "$CFG/state/morning-t3/status"; echo ok > "$TMP/probe.mode"
shell "[$COORD_OK, {\"id\":\"mcp:w1\",\"title\":\"lane one\",$LIMITED}]"
tick 0; tick 1800; is "an old post: wakes as before" "$(nhook)" 1
reset; sidecar mcp:coord; morning; sed -i "s/\tposted\t/\trefused\t/" "$CFG/state/morning-t3/status"; echo ok > "$TMP/probe.mode"
shell "[$COORD_OK, {\"id\":\"mcp:w1\",\"title\":\"lane one\",$LIMITED}]"
tick 0; tick 1800; is "the morning claim was refused: wakes as before" "$(nhook)" 1
reset; sidecar mcp:coord; morning; echo ok > "$TMP/probe.mode"
shell "[$COORD_OK, {\"id\":\"mcp:w1\",\"title\":\"lane one\",$LIMITED}]"
tick 2400; tick 4200; is "posted 40+ min ago and never claimed: the hold has ended" "$(nhook)" 1
rm -rf "$CFG/state/morning-t3"; sidecar mcp:coord

# ------------------------------------------------------------------------------------------ O --
echo "O. quiet reports: the inbox tick (t3-inbox.py, imported)"
QI=$CFG/state/t3-inbox; QS=$CFG/state/t3-inbox.tick
qitem() {  # $1 = name, $2 = class, $3 = at (seconds after T0), $4 = text [, $5 = inbox dir]
  mkdir -p "${5:-$QI}"; jq -cn --arg c "$2" --argjson a $((T0 + $3)) --arg t "$4" \
    '{from: "w1", session: "sid-w1", thread: "mcp:w1", class: $c, text: $t, at: $a}' > "${5:-$QI}/$1.json"
  chmod 600 "${5:-$QI}/$1.json"; }
qcoord() { printf '{"pid":%s,"sessionId":"sid-coord","kind":"interactive","status":"%s"}\n' "$$" "$1" > "$CFG/sessions/c.json"; }
qreset() { reset; rm -rf "$QI" "$QS" "$CFG/state/scopes/ff/t3-inbox"; mkdir -p "$CFG/sessions"; shell "[$COORD_OK]"; }
qn() { find "$QI" -maxdepth 1 -name '*.json' 2>/dev/null | wc -l | tr -d ' '; }
qreset; cp "$TMP/cfg.bak" "$CFG/middle-management.json"; qcoord busy; qitem i1 important 0 "READY: lane q"
tick 1500; is "quiet mode off: the tick leaves the inbox alone (no wake, no stamp)" "$(nhook)/$(qn)/$([ -e "$QS" ] && echo stamp || echo none)" "0/1/none"
jq '.quietReports = {enabled: true}' "$TMP/cfg.bak" > "$CFG/middle-management.json"
qreset; qcoord busy; qitem i1 important 0 "READY: lane q"
tick 600; is "on, busy, an important item 10 min old -> no wake" "$(nhook)/$(qn)" "0/1"
[ "$(stat -c %Y "$QS" 2>/dev/null)" = $((T0 + 600)) ] && ok "...the tick stamp is written (deliver: the fallback runs)" || bad "tick stamp" $((T0 + 600)) "$(stat -c %Y "$QS" 2>&1)"
tick 1200; is "...20 min old -> the fallback wake" "$(nhook)/$(qn)" "1/0"
has "...a digest from the watcher" "Worker reports (quiet), 1 waiting, oldest first:" "$(hooks | tail -1 | jq -r .prompt)"
has "...with the report" "READY: lane q" "$(hooks | tail -1 | jq -r .prompt)"
is "...sent as the watcher, unwrapped" "$(hooks | tail -1 | jq -c '[.from, .session, (.prompt == .report)]')" '["t3-watch","",true]'
qreset; qcoord busy; qitem s1 status 0 "only a status"
tick 3000; is "a status item 50 min old -> never a wake (coordinator 2026-11-02)" "$(nhook)/$(qn)" "0/1"
qreset; qcoord idle; mkdir -p "$QI"; printf '%s\n' "$T0" > "$QI/.last-wake"; qitem i2 important 100 "READY: debounced"
tick 300; is "idle, the last wake 5 min ago -> debounced, no wake" "$(nhook)" 0
tick 700; is "...the window has passed -> wake" "$(nhook)/$(qn)" "1/0"
qreset; rm -f "$CFG/sessions/c.json"; qitem i3 important 0 "READY: asleep"
OUT=$(tick 10 --dry-run); has "dry-run prints the inbox" "INBOX   scope default: 1 pending (1 important), would wake (asleep)" "$OUT"
is "...sends nothing, keeps the item and no stamp" "$(nhook)/$(qn)/$([ -e "$QS" ] && echo stamp || echo none)" "0/1/none"
morning; tick 10; is "the morning claim is pending -> no wake into the night coordinator" "$(nhook)/$(qn)" "0/1"
rm -rf "$CFG/state/morning-t3"; sidecar mcp:coord
echo 500 > "$TMP/shell.code"; tick 20
is "the T3 API answers 500 -> the inbox tick still wakes" "$(nhook)/$(qn)" "1/0"
qreset; rm -f "$CFG/sessions/c.json"; qitem i4 important 0 "READY: wake fails"; echo 429 > "$TMP/hook.mode"
tick 10; tick 610; tick 1210
is "a failing wake, three ticks -> one failures.log line (one episode)" "$(grep -c 'digest wake failed' "$CFG/state/t3-report/failures.log")" 1
has "...saying the reports stay queued" "digest wake failed (http 429), 1 report(s) stay queued in the inbox" "$(cat "$CFG/state/t3-report/failures.log")"
is "...the item stays" "$(qn)" 1
rm -f "$TMP/hook.mode"; tick 1810; is "...webhook back -> delivered" "$(qn)" 0
[ -e "$QI/.failing" ] && bad "a 202 ends the episode" "no .failing" ".failing" || ok "a 202 ends the episode"
qreset; qitem old status -90000 "a day old" "$CFG/state/scopes/ff/t3-inbox"
tick 0; is "a scope without sidecar: an item older than 24 h is dropped" "$(ls "$CFG/state/scopes/ff/t3-inbox" | wc -l | tr -d ' ')" 0
has "...with an inbox.log line" "older than 24 h" "$(cat "$CFG/state/t3-report/inbox.log")"
# usage limit: held while the coordinator is limited, one digest in the tick that ends the episode
qreset; rm -f "$CFG/sessions/c.json"; shell "[{\"id\":\"mcp:coord\",\"title\":\"Koordinator\",$LIMITED}]"
qitem h1 important 0 "READY: held in the limit"; qitem h2 status 5 "status: held too"
tick 10; is "coordinator usage-limited, asleep, an important item -> held, no wake" "$(nhook)/$(qn)" "0/2"
OUT=$(tick 20 --dry-run); has "...dry-run says why" "INBOX   scope default: 2 pending (1 important), held (coordinator usage-limited)" "$OUT"
tick 1300; is "...past fallbackMin, still limited -> still held" "$(nhook)/$(qn)" "0/2"
tick 1810; is "...the Keepalive retry still goes out, the items stay" "$(hooks | jq -r .report)/$(qn)" "Keepalive/2"
shell "[{\"id\":\"mcp:coord\",\"title\":\"Koordinator\",\"status\":\"completed\",\"lastErrorClass\":\"usage_limit\",\"latestRunId\":\"run:2\"}]"
tick 2400; is "limit over -> one digest in the same tick" "$(nhook)/$(qn)" "2/0"
has "...with the important item" "READY: held in the limit" "$(hooks | tail -1 | jq -r .prompt)"
has "...and the status item" "status: held too" "$(hooks | tail -1 | jq -r .prompt)"
has "...your user got the limit-over notice" "Limit over" "$(notes)"
tick 3000; is "...nothing more after it" "$(nhook)" 2
qreset; rm -f "$CFG/sessions/c.json"; shell "[{\"id\":\"mcp:coord\",\"title\":\"Koordinator\",$LIMITED}]"
qitem h3 important 0 "READY: T3 API went down"
tick 10; is "limited -> held" "$(nhook)/$(qn)" "0/1"
echo 500 > "$TMP/shell.code"; tick 1900
is "...the T3 API down, the limit file 31 min old -> fail open: the digest goes out" "$(nhook)/$(qn)" "1/0"
rm -f "$TMP/shell.code"
cp "$TMP/cfg.bak" "$CFG/middle-management.json"; rm -rf "$QI" "$QS" "$CFG/sessions/c.json"

# ------------------------------------------------------------------------------------------ Z --
echo "Z. secrets"
ALL=$(cat "$TMP/notify.log" "$TMP/stderr.log" "$CFG/state/t3-report/"* "$CFG/state/t3-watch/"* 2>/dev/null)
lacks "no webhook secret in any output, log or state" "$SECRET" "$ALL"
lacks "no token in any output, log or state" "$TOKEN" "$ALL"
AN=$(cat "$TMP/all-notify.log" 2>/dev/null)
[ -n "$AN" ] && ok "every notify of this run was collected" || bad "every notify collected" "messages" "none"
lacks "no thread id (mcp:...) in any notify" "mcp:" "$AN"
lacks "no model id in any notify" "claude-opus-5-5" "$AN"
lacks "no host/scope prefix in any notify" ", scope " "$AN"
is "no ISO timestamp in any notify" "$(printf '%s\n' "$AN" | grep -cE '[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:')" 0
is "no line starts with the script name" "$(printf '%s\n' "$AN" | grep -c '^t3-watch ')" 0
lacks "no [HH:MM] prefix in the scripts" "[HH:MM]" "$(cat "$SRC/t3-watch.py" "$SRC/t3-wake.sh")"
EM=$(printf '\xe2\x80\x94')   # the em dash, spelled as bytes so this file carries none
NEW="$SRC/t3-watch.py $SRC/t3-wake.sh $SRC/t3-inbox.py $ROOT/plugins/middle-management/templates/systemd/t3-watch.service $ROOT/plugins/middle-management/templates/systemd/t3-watch.timer $0"
# shellcheck disable=SC2086
is "no em dash in the new files" "$(grep -l "$EM" $NEW 2>/dev/null)" ""

echo
echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
