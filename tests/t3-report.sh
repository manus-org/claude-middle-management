#!/usr/bin/env bash
# middle-management plugin: the T3 Stop hook matrix (hooks/t3-report.sh), fake HOME, sends nothing real.
# Consumers: tests/run.sh (runs it with the other matrices); by hand from the repo root:
#   bash tests/t3-report.sh
# Part 1 runs the hook from a plugin copy whose scripts/t3-wake.sh is a stub (records what it was
# asked to send, answers with the exit code in $TMP/wake.rc). Part 2 runs the REAL t3-wake.sh
# against a local HTTP stub (202 / 500) and checks that the webhook URL never reaches any output.
set -uo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
P=$ROOT/plugins/middle-management
TMP=$(mktemp -d /tmp/t3-report-test.XXXXXX)
SP=""
trap '[ -n "$SP" ] && kill "$SP" 2>/dev/null; rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok()    { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad()   { FAIL=$((FAIL+1)); printf '  FAIL %s\n     expected: %s\n     got:      %s\n' "$1" "$2" "$3"; }
is()    { [ "$2" = "$3" ] && ok "$1" || bad "$1" "$3" "$2"; }
has()   { case "$3" in *"$2"*) ok "$1" ;; *) bad "$1" "contains: $2" "$3" ;; esac; }
lacks() { case "$3" in *"$2"*) bad "$1" "lacks: $2" "$3" ;; *) ok "$1" ;; esac; }

# --- the plugin copy with the stub sender ---
C=$TMP/plugin; mkdir -p "$C/hooks" "$C/scripts"
cp "$P/hooks/t3-report.sh" "$C/hooks/"; cp "$P/scripts/config-check.sh" "$P/scripts/scope.py" "$C/scripts/"
cat > "$C/scripts/t3-wake.sh" <<EOF
#!/usr/bin/env bash
{ printf 'from=%s session=%s cwd=%s\n' "\$1" "\$MM_SESSION_ID" "\$MM_SCOPE_CWD"; cat "\$2"; printf '\n--\n'; } >> "$TMP/wake.log"
exit "\$(cat "$TMP/wake.rc" 2>/dev/null || echo 0)"
EOF
cat > "$C/scripts/t3-inbox.py" <<EOF
import sys
open("$TMP/inbox.log", "a").write(sys.argv[3] + "\\n")   # quiet mode: deliver <dir> <class> <from> <file>
EOF
H=$TMP/home; CFG=$H/.claude; mkdir -p "$CFG/state" "$CFG/sessions" "$H/.t3"
reg() {  # $1 sessionId $2 name $3 cwd
  printf '{"pid":1,"sessionId":"%s","name":"%s","cwd":"%s","kind":"interactive"}\n' "$1" "$2" "$3" > "$CFG/sessions/$1.json"; }
side() {  # $1 sidecar dir $2 coordinator sessionId [$3 url]
  mkdir -p "$1"; printf '{"sessionId":"%s","threadId":"mcp:coord-1","title":"lane coordinator","model":"m","reportTaskId":"task-1","reportUrl":"%s"}\n' \
    "$2" "${3:-http://127.0.0.1:9/never}" > "$1/orchestrator.t3.json"; chmod 600 "$1/orchestrator.t3.json"; }
hook() {  # $1 = Stop input JSON; env T3 = T3CODE_HOME (default set)
  printf '%s' "$1" | HOME="$H" CLAUDE_CONFIG_DIR="" CLAUDE_PLUGIN_ROOT="$C" T3CODE_HOME="${T3-$H/.t3}" bash "$C/hooks/t3-report.sh" 2>&1; }
inp() {  # $1 sid $2 text [$3 extra json fields]
  jq -cn --arg s "$1" --arg t "$2" --argjson x "${3:-{\}}" '{session_id: $s, cwd: "/tmp", last_assistant_message: $t} + $x'; }
calls() { grep -c '^from=' "$TMP/wake.log" 2>/dev/null || echo 0; }
last()  { awk '/^from=/{b="";next} /^--$/{next} {b=b $0 "\n"} END{printf "%s", b}' "$TMP/wake.log"; }  # body of the last send

reg sess-w worker-1 "$H"; reg sess-c coord "$H"; reg sess-old old-coord "$H"

echo "== gates =="
OUT=$(T3="" hook "$(inp sess-w "For your user: done 1")"); is "no T3CODE_HOME -> silent" "$OUT" ""; is "...nothing sent" "$(calls)" 0
OUT=$(hook "$(inp sess-w "For your user: done 1")"); is "no sidecar -> silent" "$OUT" ""; is "...nothing sent" "$(calls)" 0
side "$CFG/state" sess-c
OUT=$(hook "$(inp sess-c "For your user: coordinator text")"); is "the coordinator itself -> silent" "$OUT" ""; is "...nothing sent" "$(calls)" 0

echo "== worker report =="
OUT=$(hook "$(inp sess-w "READY: lane x merged")"); is "worker -> no output on success" "$OUT" ""
is "worker -> one send" "$(calls)" 1
has "...the last text is the report" "READY: lane x merged" "$(cat "$TMP/wake.log")"
has "...from = registry name, session id passed" "from=worker-1 session=sess-w cwd=$H" "$(cat "$TMP/wake.log")"
[ -s "$CFG/state/t3-report/sess-w" ] && ok "...sha recorded" || bad "...sha recorded" "file" "none"
hook "$(inp sess-w "READY: lane x merged")" >/dev/null; is "duplicate text -> not sent again" "$(calls)" 1
hook "$(inp sess-w "For your user: the continued answer" '{"stop_hook_active":true}')" >/dev/null
is "stop_hook_active continuation still posts" "$(calls)" 2
hook "$(inp sess-w "OK")" >/dev/null; hook "$(inp sess-w " OK
")" >/dev/null; is "exactly OK (a Keepalive answer) -> not echoed" "$(calls)" 2
hook "$(inp sess-w "")" >/dev/null; is "empty text, no transcript -> nothing" "$(calls)" 2
TR=$TMP/tr.jsonl
printf '%s\n' '{"type":"user","message":{"content":"go"}}' \
  '{"type":"assistant","message":{"content":[{"type":"text","text":"For your user: from the transcript"},{"type":"tool_use","name":"x"}]}}' > "$TR"
hook "$(jq -cn --arg t "$TR" '{session_id:"sess-w", transcript_path:$t}')" >/dev/null
is "transcript fallback -> sent" "$(calls)" 3; has "...its text" "from the transcript" "$(tail -3 "$TMP/wake.log")"

echo "== what is a report (0.20.0) =="
reg sess-s worker-s "$H"; R=$CFG/state/t3-report; RUN='{"background_tasks":[{"type":"subagent","status":"running"}]}'
N=$(calls)
OUT=$(hook "$(inp sess-s "Looked at the config, moving on to the tests.")")
is "unmarked prose -> not sent" "$(calls)" "$N"; is "...silently" "$OUT" ""
[ -e "$R/sess-s" ] && bad "...no sha recorded" "no file" "file" || ok "...no sha recorded"
hook "$(inp sess-s "The lane is ready to build; the stack is live on 3000. No errors, one question left.")" >/dev/null
is "lowercase ready/live/errors/question in prose -> not sent" "$(calls)" "$N"
hook "$(inp sess-s "Waiting for the reviewer." "$RUN")" >/dev/null
is "an interim turn while a sub-agent runs -> not sent" "$(calls)" "$N"
[ -e "$R/held.log" ] && bad "no held.log any more" "no file" "file" || ok "...and no held.log"
[ -e "$R/sess-s.pending" ] && bad "no .pending any more" "no file" "file" || ok "...and no .pending"
hook "$(inp sess-s "For your user: PR #12 is up for review.")" >/dev/null
is "marker line -> sent" "$(calls)" $((N+1)); is "...the whole text" "$(last)" "For your user: PR #12 is up for review."
hook "$(inp sess-s "$(printf 'Done with package 3.\n\n**For your user:** the PR is up')")" >/dev/null
is "marker on a later line, markdown bold -> sent" "$(calls)" $((N+2))
hook "$(inp sess-s "> for your user: quoted, lower case")" >/dev/null
is "marker after '> ', any case -> sent" "$(calls)" $((N+3))
hook "$(inp sess-s "As I said, For your user: is the line.")" >/dev/null
is "marker in mid-line -> not sent" "$(calls)" $((N+3))
hook "$(inp sess-s "1. For your user: numbered list")" >/dev/null
is "marker after a list number '1. ' -> sent (r1 F6)" "$(calls)" $((N+4))
hook "$(inp sess-s '`For your user:` in backticks')" >/dev/null
is "marker in backticks -> sent (r1 F6)" "$(calls)" $((N+5))
N=$(calls); K=0
for T in "READY" "LIVE" "BLOCKED" "FERTIG" "CRITICAL" "SECURITY" "BUG" "ERROR" "PROBLEM" "FAILED" "FAILING" \
         "Question: x" "Frage: y" "wartet auf z" "Close this tab." "which palette?"; do
  K=$((K+1)); hook "$(inp sess-s "token $K in an unmarked text: $T")" >/dev/null
done
is "each always-send token ($K) sends without the marker" "$(calls)" $((N+K))
hook "$(inp sess-s "$(printf 'Should I take the dark one?\nThen I go on.')")" >/dev/null
is "a ? at a line end sends" "$(calls)" $((N+K+1))
N=$(calls); hook "$(inp sess-s "For your user: P1 brief written, reviewer still running" "$RUN")" >/dev/null
is "a marked text while a sub-agent runs -> sent at once" "$(calls)" $((N+1))
printf 'held by 0.19.3' > "$R/sess-s.pending"; printf x > "$R/sess-s.pending.sum"
hook "$(inp sess-s "OK")" >/dev/null; is "a text held by 0.19.3 is not sent" "$(calls)" $((N+1))
{ [ -e "$R/sess-s.pending" ] || [ -e "$R/sess-s.pending.sum" ]; } && bad "old .pending removed" "no file" "file" || ok "...and removed"
printf 'held as a worker' > "$R/sess-c.pending"; hook "$(inp sess-c "For your user: coordinator text")" >/dev/null
[ -f "$R/sess-c.pending" ] && bad "coordinator drops its pending" "no file" "file" || ok "the coordinator drops a text it held as a worker"
is "...and sends nothing" "$(calls)" $((N+1))

echo "== quiet class =="
printf '{"quietReports":{"enabled":true}}\n' > "$CFG/middle-management.json"; QN=0
qcls() { QN=$((QN+1)); hook "$(inp sess-s "$1
($QN)")" >/dev/null; tail -1 "$TMP/inbox.log" 2>/dev/null; }
qnone() { local B; : >> "$TMP/inbox.log"; B=$(wc -l < "$TMP/inbox.log"); qcls "$1" >/dev/null; [ "$(wc -l < "$TMP/inbox.log")" = "$B" ] && echo silent || echo sent; }
is "For your user: nothing -> not sent" "$(qnone "For your user: nothing")" silent
is "**For your user:** Nothing. after a status line -> not sent" "$(qnone "$(printf 'Package 2 done.\n**For your user:** Nothing.')")" silent
is "For your user: nichts -> not sent" "$(qnone "For your user: Nichts.")" silent
is "\`For your user: nothing\` in backticks -> not sent" "$(qnone '`For your user: nothing`')" silent
is "two marker lines, both nothing -> not sent" "$(qnone "$(printf 'For your user: nothing\n- For your user: nothing.')")" silent
is "For your user: <news> -> important" "$(qcls "For your user: the PR is merged")" important
is "nothing first, news on a later marker line -> important (r1 F3)" "$(qcls "$(printf 'For your user: nothing\nFor your user: the PR is merged')")" important
is "nothing + a token -> important" "$(qcls "$(printf 'For your user: nothing\nTests FAILED twice')")" important
is "a token without marker -> important" "$(qcls "BLOCKED on the API key")" important
N=$(wc -l < "$TMP/inbox.log"); hook "$(inp sess-s "just some prose")" >/dev/null
is "unmarked prose -> not delivered to the inbox either" "$(wc -l < "$TMP/inbox.log")" "$N"
rm -f "$CFG/middle-management.json"

echo "== former coordinator =="
side "$CFG/state" sess-c; jq '.previous = {sessionId:"sess-old", threadId:"mcp:old"}' "$CFG/state/orchestrator.t3.json" > "$TMP/x" \
  && cat "$TMP/x" > "$CFG/state/orchestrator.t3.json"
N=$(calls); hook "$(inp sess-old "For your user: wrap of the old coordinator")" >/dev/null
is "a former coordinator reports into its successor" "$(calls)" $((N+1))

echo "== not delivered =="
echo 4 > "$TMP/wake.rc"
OUT=$(hook "$(inp sess-w "For your user: lost report")")
has "rc 4 -> block" '"decision":"block"' "$OUT"
has "...names the coordinator thread" "send it yourself with t3_thread_send mcp:coord-1" "$OUT"
has "...exact reason text" "report NOT delivered to the coordinator" "$OUT"
OUT=$(hook "$(inp sess-w "For your user: lost report")"); is "same text again -> no second block" "$OUT" ""
OUT=$(hook "$(inp sess-w "For your user: lost again" '{"stop_hook_active":true}')"); is "continuation -> never a block (no loop)" "$OUT" ""
[ -s "$CFG/state/t3-report/sess-w" ] && [ "$(cat "$CFG/state/t3-report/sess-w")" != "$(printf '%s' "For your user: lost report" | sha256sum | cut -d' ' -f1)" ] \
  && ok "a lost report is not recorded as sent" || bad "a lost report is not recorded as sent" "old sha" "lost sha"
echo 3 > "$TMP/wake.rc"; OUT=$(hook "$(inp sess-w "For your user: no sidecar any more")"); is "rc 3 -> silent" "$OUT" ""
echo 0 > "$TMP/wake.rc"

echo "== per-root scopes =="
mkdir -p "$TMP/A" "$TMP/B" "$TMP/plain"; git -C "$TMP/A" init -q; git -C "$TMP/B" init -q
printf '{"scopeMode":"per-root"}\n' > "$CFG/middle-management.json"
rm -f "$CFG/state/orchestrator.t3.json"
SA=$(HOME="$H" CLAUDE_CONFIG_DIR="" python3 "$C/scripts/scope.py" of "$TMP/A" | cut -f2)
side "$SA" sess-ca
reg sess-a worker-a "$TMP/A"; reg sess-b worker-b "$TMP/B"; reg sess-p worker-p "$TMP/plain"
N=$(calls); hook "$(inp sess-a "For your user: report from A")" >/dev/null; is "root A worker -> sent to A's coordinator" "$(calls)" $((N+1))
hook "$(inp sess-b "For your user: report from B")" >/dev/null; is "root B worker (no coordinator there) -> standalone" "$(calls)" $((N+1))
hook "$(inp sess-p "For your user: report from nowhere")" >/dev/null; is "outside every root -> standalone (no catch-all)" "$(calls)" $((N+1))
rm -f "$CFG/middle-management.json"

echo "== real t3-wake.sh against a local stub =="
PORT=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')
SECRET="hooksecret$RANDOM$RANDOM"; URL="http://127.0.0.1:$PORT/api/hooks/task/$SECRET"
cat > "$TMP/stub.py" <<'EOF'
import http.server, os, sys, time
D = sys.argv[2]
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        b = self.rfile.read(int(self.headers.get("content-length", 0)))
        open(os.path.join(D, "hook.log"), "ab").write(b + b"\n")
        code = open(os.path.join(D, "hook.code")).read().strip()
        if code == "hang":            # a server that takes the connection and never answers
            time.sleep(30); code = "202"
        code = int(code)
        self.send_response(code); self.send_header("content-length", "0"); self.end_headers()
    def log_message(self, *a): pass
http.server.ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
EOF
echo 202 > "$TMP/hook.code"; python3 "$TMP/stub.py" "$PORT" "$TMP" & SP=$!
for _ in $(seq 50); do curl -s -o /dev/null "http://127.0.0.1:$PORT/" && break; sleep 0.1; done
side "$CFG/state" sess-c "$URL"
OUT=$(printf '%s' "$(inp sess-w "For your user: real delivery")" | HOME="$H" CLAUDE_CONFIG_DIR="" CLAUDE_PLUGIN_ROOT="$P" T3CODE_HOME="$H/.t3" bash "$P/hooks/t3-report.sh" 2>&1)
is "202 -> silent" "$OUT" ""
has "...the stub got the report" '"report":"For your user: real delivery"' "$(cat "$TMP/hook.log" 2>/dev/null)"
echo 500 > "$TMP/hook.code"
OUT2=$(printf '%s' "$(inp sess-w "For your user: real failure")" | HOME="$H" CLAUDE_CONFIG_DIR="" CLAUDE_PLUGIN_ROOT="$P" T3CODE_HOME="$H/.t3" bash "$P/hooks/t3-report.sh" 2>&1)
has "500 -> block" '"decision":"block"' "$OUT2"
has "...failures.log line" "http 500" "$(cat "$CFG/state/t3-report/failures.log" 2>/dev/null)"
echo hang > "$TMP/hook.code"
HT=$(jq '[.hooks.Stop[].hooks[] | select(.command | test("t3-report")) | .timeout] | first' "$P/hooks/hooks.json")
T1=$(date +%s)
OUT3=$(printf '%s' "$(inp sess-w "For your user: hanging server")" | HOME="$H" CLAUDE_CONFIG_DIR="" CLAUDE_PLUGIN_ROOT="$P" T3CODE_HOME="$H/.t3" bash "$P/hooks/t3-report.sh" 2>&1)
EL=$(( $(date +%s) - T1 ))
[ "$EL" -lt $((HT - 5)) ] && ok "hanging server: the hook ends ${EL}s < its timeout ${HT}s - 5" || bad "hanging server: hook inside its timeout" "< $((HT - 5))s" "${EL}s"
has "...and still blocks" '"decision":"block"' "$OUT3"
has "...after writing the failures.log line" "worker-1	sess-w	unknown	http 000" "$(tail -1 "$CFG/state/t3-report/failures.log")"
T1=$(date +%s)
OUT4=$(printf '%s' "$(inp sess-w "For your user: slow sender")" | HOME="$H" CLAUDE_CONFIG_DIR="" CLAUDE_PLUGIN_ROOT="$P" T3CODE_HOME="$H/.t3" \
  T3_WAKE_TIMEOUT=30 T3_REPORT_BUDGET=2 bash "$P/hooks/t3-report.sh" 2>&1)
EL=$(( $(date +%s) - T1 ))
[ "$EL" -lt 6 ] && ok "a sender past the budget is cut (${EL}s)" || bad "sender cut at the budget" "< 6s" "${EL}s"
has "...the hook blocks" '"decision":"block"' "$OUT4"
has "...and logs it" "sender timed out after 2s" "$(tail -1 "$CFG/state/t3-report/failures.log")"
[ "$HT" -gt 15 ] && ok "hooks.json timeout ${HT}s > the 15 s sender budget" || bad "hooks.json timeout > budget" "> 15" "$HT"
ALL="$OUT$OUT2$OUT3$OUT4$(cat "$CFG/state/t3-report/"* 2>/dev/null)"
lacks "no URL secret in any output or state file" "$SECRET" "$ALL"
lacks "no [HH:MM] prefix demanded" "[HH:MM]" "$(cat "$P/hooks/t3-report.sh")"

echo
echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
