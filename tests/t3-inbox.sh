#!/usr/bin/env bash
# middle-management plugin: quiet reports (scripts/t3-inbox.py, hooks/t3-inbox.sh, the quiet branch of
# hooks/t3-report.sh), fake HOME, a local webhook stub; sends nothing real.
# Consumers: tests/run.sh (runs it with the other matrices); by hand from the repo root:
#   bash tests/t3-inbox.sh
#   A  config shape (config-check.sh validate)
#   B  deliver: a status report never wakes (asleep, idle, busy, past fallbackMin); an important one
#      wakes an asleep coordinator with a digest of every pending item, waits while it is busy, is
#      debounced while idle; no status field and a stale watcher stamp wake as before
#   C  inject: PostToolUse / UserPromptSubmit / Stop print and delete; a sub-agent (agent_id) and
#      other sessions get nothing; the 8000 cap; own reports and items past 24 h are dropped
#   D  a failed wake: the caller's own item goes back to it (exit 4), the others stay, one line
#   E  races: two delivers -> one wake; an inject during a wake; two injects -> every item once
#   F  caps: a 9000-char item is cut at 4000 and drains; the digest stays within 4000
#   G  hooks/t3-report.sh: quiet on -> the inbox, the coordinator's Stop hands it in once; off -> as before
#   H  hooks/t3-inbox.sh fast path, hooks.json registration
#   Z  no webhook secret anywhere
# The clock is T3W_NOW; the coordinator's registry entry points at a sleep process (live) or is gone.
set -uo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
P=$ROOT/plugins/middle-management
IB=$P/scripts/t3-inbox.py
TMP=$(mktemp -d /tmp/t3-inbox-test.XXXXXX)
SP=""; CP=""
trap '[ -n "$SP" ] && kill "$SP" 2>/dev/null; [ -n "$CP" ] && kill "$CP" 2>/dev/null; rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok()    { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad()   { FAIL=$((FAIL+1)); printf '  FAIL %s\n     expected: %s\n     got:      %s\n' "$1" "$2" "$3"; }
is()    { [ "$2" = "$3" ] && ok "$1" || bad "$1" "$3" "$2"; }
has()   { case "$3" in *"$2"*) ok "$1" ;; *) bad "$1" "contains: $2" "$3" ;; esac; }
lacks() { case "$3" in *"$2"*) bad "$1" "lacks: $2" "$3" ;; *) ok "$1" ;; esac; }

H=$TMP/home; CFG=$H/.claude; ST=$CFG/state; IN=$ST/t3-inbox
mkdir -p "$ST" "$CFG/sessions" "$H/.t3/userdata/logs/provider"
printf '{"session_id":"sid-w1"}\n' > "$H/.t3/userdata/logs/provider/events.mcp-w1.log"
PORT=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')
SECRET="hooksecret$RANDOM$RANDOM"; URL="http://127.0.0.1:$PORT/api/hooks/task/$SECRET"
cat > "$TMP/stub.py" <<'EOF'
import http.server, os, sys, time
D = sys.argv[2]
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        b = self.rfile.read(int(self.headers.get("content-length", 0)))
        open(os.path.join(D, "hook.log"), "ab").write(b.rstrip(b"\n") + b"\n")
        code = open(os.path.join(D, "hook.code")).read().strip()
        if code == "sleep":
            time.sleep(2); code = "202"
        self.send_response(int(code)); self.send_header("content-length", "0"); self.end_headers()
    def log_message(self, *a): pass
http.server.ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
EOF
echo 202 > "$TMP/hook.code"; python3 "$TMP/stub.py" "$PORT" "$TMP" & SP=$!
for _ in $(seq 50); do curl -s -o /dev/null "http://127.0.0.1:$PORT/" && break; sleep 0.1; done
printf '{"sessionId":"sid-coord","threadId":"mcp:coord","title":"Koordinator","model":"m","reportTaskId":"t","reportUrl":"%s"}\n' "$URL" > "$ST/orchestrator.t3.json"
chmod 600 "$ST/orchestrator.t3.json"
printf '{"quietReports":{"enabled":true}}\n' > "$CFG/middle-management.json"
sleep 600 >/dev/null 2>&1 </dev/null & CP=$!

T0=$(date +%s)
coord() {  # asleep | busy | idle | nostatus
  case $1 in
    asleep)   rm -f "$CFG/sessions/coord.json" ;;
    nostatus) printf '{"pid":%s,"sessionId":"sid-coord","kind":"interactive","name":"coord"}\n' "$CP" > "$CFG/sessions/coord.json" ;;
    *)        printf '{"pid":%s,"sessionId":"sid-coord","kind":"interactive","name":"coord","status":"%s"}\n' "$CP" "$1" > "$CFG/sessions/coord.json" ;;
  esac; }
fresh() { touch -d "@$((T0 + $1))" "$ST/t3-inbox.tick"; }   # the watcher's stamp, at T0 + $1
env_() { env HOME="$H" CLAUDE_CONFIG_DIR="" T3CODE_HOME="$H/.t3" T3_WAKE_TIMEOUT=3 "$@"; }
dl() {  # $1 = seconds after T0, $2 class, $3 from, $4 text [, $5 session]; prints the exit code
  printf '%s' "$4" > "$TMP/r.$3.txt"
  env_ T3W_NOW=$((T0 + $1)) MM_SESSION_ID="${5:-sid-$3}" MM_SCOPE_CWD="$TMP" \
    python3 "$IB" deliver "$ST" "$2" "$3" "$TMP/r.$3.txt" 2>>"$TMP/stderr.log"; echo $?; }
inj() {  # $1 = seconds after T0, $2 = hook input JSON
  printf '%s' "$2" | env_ T3W_NOW=$((T0 + $1)) python3 "$IB" inject 2>>"$TMP/stderr.log"; }
ev() { jq -cn --arg s "${2:-sid-coord}" --arg e "$1" '{session_id: $s, hook_event_name: $e}'; }
items() { find "$IN" -maxdepth 1 -name '*.json' 2>/dev/null | wc -l | tr -d ' '; }
texts() { cat "$IN"/*.json 2>/dev/null | jq -r .text; }
nhook() { [ -f "$TMP/hook.log" ] && wc -l < "$TMP/hook.log" | tr -d ' ' || echo 0; }
prompt() { tail -1 "$TMP/hook.log" 2>/dev/null | jq -r .prompt; }
reset() { rm -rf "$IN" "$TMP/hook.log" "$ST/t3-report" "$ST/t3-inbox.tick"; echo 202 > "$TMP/hook.code"; }

# ------------------------------------------------------------------------------------------ A --
echo "A. config shape"
vcfg() { printf '%s' "$1" > "$TMP/cfg/middle-management.json"; CLAUDE_CONFIG_DIR="$TMP/cfg" bash "$P/scripts/config-check.sh" validate; echo $?; }
mkdir -p "$TMP/cfg"
for c in '{"quietReports":{"enabled":true}}' '{"quietReports":{"enabled":false,"fallbackMin":20,"debounceMin":10}}' '{"quietReports":{}}'; do
  is "valid: $c" "$(vcfg "$c")" 0
done
for c in '{"quietReports":true}' '{"quietReports":{"enabled":"yes"}}' '{"quietReports":{"fallbackMin":0}}' '{"quietReports":{"debounceMin":"10"}}'; do
  is "invalid: $c" "$(vcfg "$c")" 1
done

# ------------------------------------------------------------------------------------------ B --
echo "B. deliver"
reset; coord asleep
is "status, coordinator asleep -> queued (exit 0)" "$(dl 0 status w1 "working on step 2")" 0
is "...no wake" "$(nhook)" 0; is "...one item" "$(items)" 1
[ "$(stat -c %a "$IN"/*.json)" = 600 ] && ok "...the item is 0600" || bad "item 0600" 600 "$(stat -c %a "$IN"/*.json)"
is "...it names its thread (t3-wake.sh --thread)" "$(jq -r .thread "$IN"/*.json)" "mcp:w1"
coord idle; fresh 0; dl 10 status w2 "still on it" >/dev/null; is "status, idle -> no wake" "$(nhook)" 0
coord busy; dl 20 status w3 "half way" >/dev/null; is "status, busy -> no wake" "$(nhook)" 0
coord asleep; fresh 1500; dl 1500 status w2 "status past fallbackMin" >/dev/null
is "status items past fallbackMin, asleep -> still no wake (coordinator 2026-11-02)" "$(nhook)/$(items)" "0/4"
is "important, asleep -> one wake" "$(dl 1600 important w4 "READY: lane x merged")/$(nhook)" "0/1"
B=$(tail -1 "$TMP/hook.log")
has "...the digest names the count" "Worker reports (quiet), 5 waiting, oldest first:" "$(prompt)"
for t in "working on step 2" "still on it" "half way" "status past fallbackMin" "READY: lane x merged"; do
  has "...carries \"$t\"" "$t" "$(prompt)"
done
has "...each report with sender and thread" "### Report from w1 (thread mcp:w1, " "$(prompt)"
is "...sent unwrapped, no caller session" "$(printf '%s' "$B" | jq -c '[.from, .session, (.prompt == .report)]')" '["w4","",true]'
is "...the inbox is empty" "$(items)" 0
is "...one inbox.log line per woken item" "$(grep -c '	woken	' "$ST/t3-report/inbox.log")" 5
dl 1650 important w5 "BLOCKED: needs a key" >/dev/null
is "important, asleep, a wake 50 s ago -> no second wake (its turn's hooks take it)" "$(nhook)/$(items)" "1/1"
dl 1800 important w6 "READY: second lane" >/dev/null
is "...200 s later -> the next wake carries both" "$(nhook)" 2
has "...the held one" "BLOCKED: needs a key" "$(prompt)"; has "...and the new one" "READY: second lane" "$(prompt)"

reset; coord idle; fresh 1000
dl 1000 important w1 "READY a" >/dev/null; is "important, idle, no wake yet -> wake" "$(nhook)" 1
dl 1200 important w2 "READY b" >/dev/null; is "...200 s later (inside debounceMin 10) -> no wake" "$(nhook)/$(items)" "1/1"
dl 1700 important w3 "READY c" >/dev/null; is "...700 s after the wake -> one digest wake" "$(nhook)" 2
has "...with the debounced one" "READY b" "$(prompt)"; has "...and the new one" "READY c" "$(prompt)"
printf '{"quietReports":{"enabled":true,"debounceMin":1}}\n' > "$CFG/middle-management.json"
dl 1900 important w1 "READY d" >/dev/null; is "debounceMin 1 from the config: 200 s later -> wake" "$(nhook)" 3
printf '{"quietReports":{"enabled":true}}\n' > "$CFG/middle-management.json"

reset; coord busy; fresh 0
dl 10 important w1 "READY busy" >/dev/null; is "important, busy, watcher fresh -> no wake" "$(nhook)/$(items)" "0/1"
fresh 1250; dl 1250 status w2 "a status report" >/dev/null
is "a report finds an important item past fallbackMin (20 min) -> one digest wake" "$(nhook)" 1
has "...with the old important one" "READY busy" "$(prompt)"; has "...and the status one" "a status report" "$(prompt)"

reset; coord nostatus; fresh 0
dl 10 important w1 "READY no status" >/dev/null; is "important, live entry without a status field -> wake (as before)" "$(nhook)" 1
reset; coord nostatus; fresh 0
dl 10 status w1 "status no status" >/dev/null; is "...but a status report does not" "$(nhook)" 0
reset; coord busy; touch -d "@$((T0 - 3600))" "$ST/t3-inbox.tick"
dl 10 important w1 "READY stale" >/dev/null; is "important, busy, watcher stamp 1 h old -> wake (no fallback runs)" "$(nhook)" 1
reset; coord busy
dl 10 important w1 "READY nostamp" >/dev/null; is "...no stamp at all -> wake" "$(nhook)" 1
reset; coord busy
dl 10 status w1 "status nostamp" >/dev/null; is "...a status report with no stamp -> no wake" "$(nhook)" 0
reset; mv "$ST/orchestrator.t3.json" "$TMP/side.bak"
is "no sidecar -> exit 3, nothing queued" "$(dl 0 important w1 "READY nobody")/$(items)" "3/0"
mv "$TMP/side.bak" "$ST/orchestrator.t3.json"

# ------------------------------------------------------------------------------------------ C --
echo "C. inject"
reset; coord busy; fresh 0
dl 0 important w1 "READY one" >/dev/null; dl 5 status w2 "status two" >/dev/null
OUT=$(inj 10 '{"session_id":"sid-coord","hook_event_name":"PostToolUse","agent_id":"a1","agent_type":"general"}')
is "a sub-agent's tool call (agent_id) -> nothing" "$OUT/$(items)" "/2"
OUT=$(inj 10 "$(ev PostToolUse sid-w1)"); is "a worker session -> nothing" "$OUT/$(items)" "/2"
OUT=$(inj 10 "$(ev PostToolUse)")
is "the coordinator's PostToolUse -> additionalContext" "$(jq -r .hookSpecificOutput.hookEventName <<<"$OUT")" PostToolUse
C=$(jq -r .hookSpecificOutput.additionalContext <<<"$OUT")
has "...the header" "Worker reports (quiet): 2 arrived without a turn of their own" "$C"
has "...the first report" "READY one" "$C"; has "...the second" "status two" "$C"
is "...printed = consumed" "$(items)/$(ls "$IN" | grep -c claimed)" "0/0"
is "...one inbox.log line each" "$(grep -c '	injected	.*	PostToolUse$' "$ST/t3-report/inbox.log")" 2
is "...no wake" "$(nhook)" 0
dl 20 status w3 "three" >/dev/null
OUT=$(inj 30 "$(ev UserPromptSubmit)")
is "UserPromptSubmit -> additionalContext too" "$(jq -r '.hookSpecificOutput | [.hookEventName, (.additionalContext | test("three"))] | @tsv' <<<"$OUT")" "UserPromptSubmit	true"
OUT=$(inj 40 "$(ev PostToolUse)"); is "an empty inbox -> nothing" "$OUT" ""
dl 41 status w4 "keep for after the OK" >/dev/null
OUT=$(inj 42 "$(jq -cn '{session_id:"sid-coord", hook_event_name:"UserPromptSubmit", prompt:"Keepalive\n"}')")
is "a Keepalive prompt (answered with exactly OK) -> nothing injected (review r1 L1)" "$OUT/$(items)" "/1"
OUT=$(inj 43 "$(ev Stop)"); has "...its Stop hands the report in after the OK" "keep for after the OK" "$(jq -r .reason <<<"$OUT")"
X=$(python3 -c 'print("y" * 3500)')
for w in a b c; do dl 50 status "w$w" "$w$X" >/dev/null; done
OUT=$(inj 60 "$(ev PostToolUse)"); C=$(jq -r .hookSpecificOutput.additionalContext <<<"$OUT")
[ "${#C}" -le 8000 ] && ok "3 x 3500 chars -> one injection within 8000 (${#C})" || bad "inject cap 8000" "<= 8000" "${#C}"
has "...the rest follows" "(1 more follow with your next tool call or turn)" "$C"
is "...one item left" "$(items)" 1
OUT=$(inj 61 "$(ev PostToolUse)"); has "...and the next call takes it" "c$X" "$(jq -r .hookSpecificOutput.additionalContext <<<"$OUT")"
dl 70 status coordx "my own earlier report" sid-coord >/dev/null
OUT=$(inj 80 "$(ev PostToolUse)"); is "a report the coordinator sent itself before it held the seat -> dropped, not shown" "$OUT/$(items)" "/0"
has "...logged" "own report" "$(cat "$ST/t3-report/inbox.log")"
dl 0 status w1 "yesterday" >/dev/null
OUT=$(inj 90000 "$(ev PostToolUse)"); is "an item older than 24 h -> dropped" "$OUT/$(items)" "/0"
has "...logged" "older than 24 h" "$(cat "$ST/t3-report/inbox.log")"
dl 100 status w1 "at the turn end" >/dev/null
OUT=$(inj 110 "$(jq -cn '{session_id:"sid-coord", hook_event_name:"Stop", stop_hook_active:true}')")
is "Stop on a continuation -> nothing (no loop)" "$OUT/$(items)" "/1"
OUT=$(inj 110 "$(ev Stop)")
is "Stop -> one block whose reason carries the reports" "$(jq -r '[.decision, (.reason | test("at the turn end"))] | @tsv' <<<"$OUT")" "block	true"
is "...consumed" "$(items)" 0

# ------------------------------------------------------------------------------------------ D --
echo "D. a failed wake"
reset; coord asleep
dl 0 status w1 "status one" >/dev/null; echo 500 > "$TMP/hook.code"
is "important, asleep, webhook 500 -> exit 4" "$(dl 10 important w2 "READY two")" 4
is "...its own item went back to it, the status one stays" "$(items)/$(texts)" "1/status one"
is "...nothing left claimed" "$(ls "$IN" | grep -c claimed)" 0
F=$(cat "$ST/t3-report/failures.log")
is "...one failures.log line" "$(wc -l <<<"$F" | tr -d ' ')" 1
has "...naming sender, reason and the queue" "	w2	sid-w2	unknown	http 500 (quiet digest wake; this report went back to its session, 1 other report(s) stay queued)" "$F"
is "...the wake mark is rolled back" "$(cat "$IN/.last-wake")" 0
echo 202 > "$TMP/hook.code"
dl 30 important w3 "READY three" >/dev/null
is "the next important report wakes with what stayed (POST 2: the 500, then this)" "$(nhook)" 2
has "...the status one" "status one" "$(prompt)"; has "...and the new one" "READY three" "$(prompt)"
[ -e "$IN/.failing" ] && bad "a 202 ends the failure episode" "no .failing" ".failing" || ok "a 202 ends the failure episode"

# ------------------------------------------------------------------------------------------ E --
echo "E. races"
reset; coord idle; fresh 0
dl 0 important ra "READY race a" > "$TMP/rc.a" & W1=$!; dl 0 important rb "READY race b" > "$TMP/rc.b" & W2=$!; wait "$W1" "$W2"
is "two delivers at once -> one wake" "$(nhook)" 1
is "...both exit 0" "$(cat "$TMP/rc.a")$(cat "$TMP/rc.b")" 00
ALL="$(prompt)$(texts)"
is "...each report exactly once (digest or still queued)" "$(grep -o 'READY race a' <<<"$ALL" | wc -l)/$(grep -o 'READY race b' <<<"$ALL" | wc -l)" "1/1"
reset; coord asleep
dl 0 status s1 "status before the wake" >/dev/null; echo sleep > "$TMP/hook.code"
dl 10 important s2 "READY during the wake" > "$TMP/rc.s" & W1=$!
sleep 1; OUT=$(inj 11 "$(ev UserPromptSubmit)"); wait "$W1"
is "an inject while the wake is in flight takes nothing the wake claimed" "$OUT" ""
is "...the wake carried both" "$(grep -c 'status before the wake\|READY during the wake' <<<"$(prompt)")" 2
is "...nothing left" "$(items)/$(ls "$IN" | grep -c claimed)" "0/0"
reset; coord asleep; mkdir -p "$IN"; flock "$IN/.lock" sleep 6 & W1=$!; sleep 0.3
T1=$(date +%s.%N); RC=$(dl 0 important lk "READY while the lock is held"); EL=$(python3 -c "print(round($(date +%s.%N) - $T1, 1))")
is "deliver while another holds the lock 6 s -> exit 0, queued, no wake (review r1 L2)" "$RC/$(items)/$(nhook)" "0/1/0"
python3 -c "import sys; sys.exit(0 if $EL < 4 else 1)" && ok "...it waits 2 s at most (${EL}s), well inside the hook's 15-s guard" || bad "lock wait 2 s" "< 4 s" "${EL}s"
kill "$W1" 2>/dev/null; wait "$W1" 2>/dev/null
reset; coord busy; fresh 0; echo 202 > "$TMP/hook.code"
for i in 1 2 3 4; do dl $i status "p$i" "parallel $i" >/dev/null; done
inj 10 "$(ev PostToolUse)" > "$TMP/o1" & W1=$!; inj 10 "$(ev PostToolUse)" > "$TMP/o2" & W2=$!; wait "$W1" "$W2"
ALL=$(cat "$TMP/o1" "$TMP/o2" | jq -r .hookSpecificOutput.additionalContext)
N=0; for i in 1 2 3 4; do [ "$(grep -o "parallel $i" <<<"$ALL" | wc -l)" = 1 ] && N=$((N+1)); done
is "two injects at once -> every item exactly once" "$N/$(items)" "4/0"

# ------------------------------------------------------------------------------------------ F --
echo "F. caps"
reset; coord busy; fresh 0
dl 0 important w1 "$(python3 -c 'print("x" * 9000)')" >/dev/null
T=$(texts); is "a 9000-char item is cut at 4000 when written" "${T:0:4000}" "$(python3 -c 'print("x" * 4000)')"
has "...with a note" "[cut at 4000 of 9000 chars]" "$T"
OUT=$(inj 10 "$(ev PostToolUse)"); is "...and drains with one inject" "$(items)" 0
has "...whole" "[cut at 4000 of 9000 chars]" "$(jq -r .hookSpecificOutput.additionalContext <<<"$OUT")"
reset; coord asleep; X=$(python3 -c 'print("z" * 1500)')
for w in a b c; do dl 0 status "w$w" "$w$X" >/dev/null; done
dl 5 important w1 "READY big" >/dev/null
P1=$(prompt); [ "${#P1}" -le 4000 ] && ok "a digest stays within 4000 chars (${#P1})" || bad "digest cap 4000" "<= 4000" "${#P1}"
has "...the rest arrives as hook context" "more arrive as hook context in this turn)" "$P1"
LEFT=$(items); [ "$LEFT" -ge 1 ] && ok "...$LEFT item(s) stay for the woken turn" || bad "items stay" ">= 1" "$LEFT"
OUT=$(inj 6 "$(ev UserPromptSubmit)"); is "...the woken turn's UserPromptSubmit takes them" "$(items)" 0
reset; coord asleep
dl 0 important w1 "$(python3 -c 'print("q" * 4000)')" >/dev/null
P1=$(prompt); is "an item too long for any digest -> the wake says it comes as hook context" "$P1" "Worker reports (quiet), 1 waiting, oldest first:
(1 more arrive as hook context in this turn)"
is "...it stays" "$(items)" 1

# ------------------------------------------------------------------------------------------ G --
echo "G. hooks/t3-report.sh"
reset; coord busy; fresh 0
printf '{"pid":1,"sessionId":"sess-w","name":"worker-1","cwd":"%s","kind":"interactive"}\n' "$H" > "$CFG/sessions/w.json"
rep() {  # $1 = Stop input JSON
  printf '%s' "$1" | env_ CLAUDE_PLUGIN_ROOT="$P" bash "$P/hooks/t3-report.sh" 2>&1; }
stop() { jq -cn --arg s "$1" --arg t "$2" --argjson x "${3:-{\}}" '{session_id: $s, cwd: "/tmp", hook_event_name: "Stop", last_assistant_message: $t} + $x'; }
OUT=$(rep "$(stop sess-w "working on step 2")"); is "quiet on: a status turn -> no output" "$OUT" ""
is "...queued, no wake" "$(items)/$(nhook)" "1/0"
is "...class status, from the registry name" "$(jq -r '[.class, .from, .session] | @tsv' "$IN"/*.json)" "status	worker-1	sess-w"
[ -s "$ST/t3-report/sess-w" ] && ok "...recorded as sent (no repeat)" || bad "sha recorded" file none
rep "$(stop sess-w "working on step 2")" >/dev/null; is "...the same text again -> not queued twice" "$(items)" 1
rep "$(stop sess-w "READY: lane done")" >/dev/null
is "a READY turn -> class important (the shared marker regex)" "$(cat "$IN"/*.json | jq -r .class | sort | tr '\n' ' ')" "important status "
is "...busy coordinator -> still no wake" "$(nhook)" 0
OUT=$(rep "$(stop sid-coord "my answer" '{"stop_hook_active":true}')"); is "the coordinator's Stop on a continuation -> nothing" "$OUT/$(items)" "/2"
OUT=$(rep "$(stop sid-coord "my answer")")
is "the coordinator's Stop -> one block with the waiting reports" "$(jq -r '[.decision, (.reason | test("working on step 2")), (.reason | test("READY: lane done"))] | @tsv' <<<"$OUT")" "block	true	true"
is "...handed in = gone" "$(items)" 0
OUT=$(rep "$(stop sid-coord "next answer")"); is "...the next Stop with an empty inbox -> silent" "$OUT" ""
coord asleep; echo 500 > "$TMP/hook.code"
OUT=$(rep "$(stop sess-w "READY: but the webhook is down")")
has "quiet on, wake fails -> the session is told once" "report NOT delivered to the coordinator" "$OUT"
is "...its report is not queued twice" "$(items)" 0
echo 202 > "$TMP/hook.code"
printf '{"quietReports":{"enabled":false}}\n' > "$CFG/middle-management.json"; reset; coord busy
rep "$(stop sess-w "quiet off: sent as before")" >/dev/null
is "quiet off -> one wrapped report as before, no inbox" "$(prompt)/$([ -d "$IN" ] && echo inbox || echo none)" "Report from worker-1 (thread unknown): quiet off: sent as before/none"
printf '{"quietReports":{"enabled":true}}\n' > "$CFG/middle-management.json"

# ------------------------------------------------------------------------------------------ H --
echo "H. hooks/t3-inbox.sh"
reset; coord busy; fresh 0; dl 0 status w1 "via the hook" >/dev/null
hk() { printf '%s' "$1" | env HOME="$H" CLAUDE_CONFIG_DIR="" T3CODE_HOME="${T3-$H/.t3}" CLAUDE_PLUGIN_ROOT="$P" bash "$P/hooks/t3-inbox.sh" 2>&1; }
OUT=$(T3="" hk "$(ev PostToolUse)"); is "no T3 thread -> silent" "$OUT/$(items)" "/1"
OUT=$(hk "$(ev PostToolUse sid-w1)"); is "a session no sidecar names -> silent" "$OUT/$(items)" "/1"
OUT=$(hk "$(jq -cn '{session_id:"sid-coord", hook_event_name:"PostToolUse", agent_id:"a7"}')"); is "the coordinator's sub-agent -> silent" "$OUT/$(items)" "/1"
OUT=$(hk "$(ev PostToolUse)"); has "the coordinator -> the reports" "via the hook" "$OUT"; is "...consumed" "$(items)" 0
OUT=$(hk "$(ev PostToolUse)"); is "an empty inbox -> silent" "$OUT" ""
J=$P/hooks/hooks.json
is "hooks.json: PostToolUse runs it" "$(jq -r '[.hooks.PostToolUse[].hooks[] | select(.command | test("t3-inbox.sh"))] | length' "$J")" 1
is "...with no matcher (every tool) and no statusMessage" "$(jq -c '[.hooks.PostToolUse[] | select(.hooks[].command | test("t3-inbox.sh")) | [.matcher, .hooks[0].statusMessage]] | first' "$J")" "[null,null]"
is "...timeout 5 s at most" "$(jq '[.hooks.PostToolUse[].hooks[] | select(.command | test("t3-inbox.sh")) | .timeout <= 5] | all' "$J")" true
is "hooks.json: UserPromptSubmit runs it" "$(jq -r '[.hooks.UserPromptSubmit[].hooks[] | select(.command | test("t3-inbox.sh"))] | length' "$J")" 1

# ------------------------------------------------------------------------------------------ Z --
echo "Z. secrets"
ALL=$(cat "$TMP/stderr.log" "$ST/t3-report/"* "$IN"/* "$IN"/.* 2>/dev/null)
lacks "no webhook secret in any output, log or inbox file" "$SECRET" "$ALL$OUT"
EM=$(printf '\xe2\x80\x94')
is "no em dash in the new files" "$(grep -l "$EM" "$IB" "$P/hooks/t3-inbox.sh" "$0" 2>/dev/null)" ""

echo
echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
