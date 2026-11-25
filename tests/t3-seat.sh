#!/usr/bin/env bash
# middle-management plugin: the T3 seat matrix, fake HOME, sends nothing real.
# Consumers: tests/run.sh (runs it with the other matrices); by hand from the repo root:
#   bash tests/t3-seat.sh
#   A  orchestrator.sh t3-bind / status / t3-handover / handover claim / takeover wake / previous / release
#   B  the asleep guard: claim and release <id> refuse, --t3-asleep-ok overrides
#   C  session-role.sh: asleep T3 coordinator, T3 worker lines, T3 coordinator lines, the short hints
#      on a second message, former coordinator
#   D  scopeMode per-root: two roots, no catch-all, a standalone session
#   E  peer-state.py: thread column, "asleep (T3)" · F orch-heartbeat.sh skips a T3-bound coordinator
#   G  the morning takeover: claim --morning gated by morningTakeover, quiet check, backfill, predecessor note
#   H  coordinatorModelRule: the claim line (default, off, user rule; plain and --morning), config-check validate
#   I  handoverTokens / handoverWarnTokens: the coordinator banner's hand-over and warn lines (fake transcripts),
#      no line for a Keepalive prompt, config-check validate
#   Z  no webhook URL in any output
# The takeover wake runs the REAL t3-wake.sh against a local HTTP stub that logs the request path.
set -uo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
P=$ROOT/plugins/middle-management
ORCH=$P/scripts/orchestrator.sh; ROLE=$P/hooks/session-role.sh
TMP=$(mktemp -d /tmp/t3-seat-test.XXXXXX)
PIDS=""
trap 'for p in $PIDS; do kill "$p" 2>/dev/null; done; rm -rf "$TMP"' EXIT
PASS=0; FAIL=0; ALL=""
ok()    { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad()   { FAIL=$((FAIL+1)); printf '  FAIL %s\n     expected: %s\n     got:      %s\n' "$1" "$2" "$3"; }
is()    { [ "$2" = "$3" ] && ok "$1" || bad "$1" "$3" "$2"; }
has()   { case "$3" in *"$2"*) ok "$1" ;; *) bad "$1" "contains: $2" "$3" ;; esac; }
lacks() { case "$3" in *"$2"*) bad "$1" "lacks: $2" "$3" ;; *) ok "$1" ;; esac; }

PORT=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')
cat > "$TMP/stub.py" <<'EOF'
import http.server, os, sys
D = sys.argv[2]
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        b = self.rfile.read(int(self.headers.get("content-length", 0)))
        open(os.path.join(D, "hook.log"), "ab").write(self.path.encode() + b" " + b + b"\n")
        self.send_response(202); self.send_header("content-length", "0"); self.end_headers()
    def log_message(self, *a): pass
http.server.ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
EOF
python3 "$TMP/stub.py" "$PORT" "$TMP" & PIDS="$PIDS $!"
for _ in $(seq 50); do curl -s -o /dev/null "http://127.0.0.1:$PORT/" && break; sleep 0.1; done
S1="secretone$RANDOM$RANDOM"; S2="secrettwo$RANDOM$RANDOM"
U1="http://127.0.0.1:$PORT/api/hooks/t1/$S1"; U2="http://127.0.0.1:$PORT/api/hooks/t2/$S2"

new_home() { local h; h=$(mktemp -d -p "$TMP"); mkdir -p "$h/.claude/sessions" "$h/.claude/state" "$h/.t3/userdata/logs/provider"; echo "$h"; }
# as_s <home> <name> <cwd> <orchestrator args...>: run orchestrator.sh as session sess-<name> (stdin passes through)
as_s() {
  HOME="$1" CLAUDE_CONFIG_DIR="" T3CODE_HOME="$1/.t3" bash -c 'printf "{\"pid\":%s,\"name\":\"%s\",\"sessionId\":\"sess-%s\",\"kind\":\"interactive\",\"cwd\":\"%s\"}\n" "$$" "$1" "$1" "$2" > "$HOME/.claude/sessions/$$.json"
    bash "$3" "${@:4}"; rc=$?; rm -f "$HOME/.claude/sessions/$$.json"; exit $rc' _ "$2" "$3" "$ORCH" "${@:4}" 2>&1
}
live() {  # <home> <name> <cwd>: a live registry entry (a sleep) for sess-<name>
  sleep 300 >/dev/null 2>&1 </dev/null & local p=$!; PIDS="$PIDS $p"
  printf '{"pid":%s,"name":"%s","sessionId":"sess-%s","kind":"interactive","cwd":"%s"}\n' "$p" "$2" "$2" "$3" > "$1/.claude/sessions/$p.json"; echo "$p"; }
me() {  # <home> <name> <cwd>: this test shell as sess-<name> (for the role hook)
  printf '{"pid":%s,"name":"%s","sessionId":"sess-%s","kind":"interactive","cwd":"%s"}\n' "$$" "$2" "$2" "$3" > "$1/.claude/sessions/$$.json"; }
role() {  # <home> <sessionId> [T3 home or ""]
  printf '{"session_id":"%s"}' "$2" | HOME="$1" CLAUDE_CONFIG_DIR="" CLAUDE_PLUGIN_ROOT="$P" T3CODE_HOME="${3-$1/.t3}" bash "$ROLE" 2>&1; }
plog() { printf '{"session_id":"%s"}\n' "$3" > "$1/.t3/userdata/logs/provider/events.$2.log"; }  # <home> <thread> <sid>

echo "== A: bind, status, handover, takeover wake, release =="
H=$(new_home); SIDE=$H/.claude/state/orchestrator.t3.json
OUT=$(as_s "$H" c1 "$H" claim); has "c1 claims" "OK: this session" "$OUT"
OUT=$(printf 'not a url\n' | as_s "$H" c1 "$H" t3-bind --thread mcp:t-c1 --title "coord one" --task task-1 --model fable)
has "t3-bind without a URL -> refused" "REFUSED: stdin carries no usable" "$OUT"; [ -e "$SIDE" ] && bad "...no sidecar" none "$SIDE" || ok "...no sidecar"
OUT=$(printf '%s\n' "$U1" | as_s "$H" c1 "$H" t3-bind --thread mcp:t-c1 --title "coord one"); has "t3-bind missing flags -> usage" "Usage: orchestrator.sh t3-bind" "$OUT"
OUT=$(printf '%s\n' "$U1" | as_s "$H" w1 "$H" t3-bind --thread x --title x --task x --model x); has "t3-bind by a non-holder -> refused" "REFUSED: this session does not hold" "$OUT"
OUT=$(printf '%s\n' "$U1" | as_s "$H" c1 "$H" t3-bind --thread mcp:t-c1 --title "coord one" --task task-1 --model fable); ALL="$ALL$OUT"
has "t3-bind -> OK" "OK: T3 thread mcp:t-c1" "$OUT"; has "...names the model-change rule" "After a model or effort change: a new report task" "$OUT"
lacks "...a first bind names no task to delete (never the one just bound)" "delete_scheduled_task" "$OUT"
is "...sidecar mode 0600" "$(stat -c %a "$SIDE")" 600
is "...sidecar fields" "$(jq -c '[.sessionId,.threadId,.title,.model,.reportTaskId,(.reportUrl|length>0),has("previous")]' "$SIDE")" '["sess-c1","mcp:t-c1","coord one","fable","task-1",true,false]'
OUT=$(as_s "$H" c1 "$H" status); ALL="$ALL$OUT"; has "status shows thread + title" 'thread mcp:t-c1 "coord one"' "$OUT"
OUT=$(as_s "$H" w1 "$H" t3-handover --to-thread mcp:t-c2 --to-title "coord two"); has "t3-handover by a non-holder -> refused" "REFUSED" "$OUT"
OUT=$(as_s "$H" c1 "$H" t3-handover --to-thread mcp:t-c2 --to-title "coord two"); has "t3-handover -> OK" "OK: handover to" "$OUT"
is "...handover field" "$(jq -c '[.handover.toThreadId,.handover.toTitle,(.handover.since|type)]' "$SIDE")" '["mcp:t-c2","coord two","number"]'
is "...still 0600" "$(stat -c %a "$SIDE")" 600
has "status shows the open handover" "handover open to coord two" "$(as_s "$H" c1 "$H" status)"
# c1 is alive and working: a stranger's claim is BUSY, the named successor takes the seat
C1P=$(live "$H" c1 "$H")
OUT=$(as_s "$H" x9 "$H" claim); has "a stranger's claim over a live c1 -> BUSY" "BUSY" "$OUT"
OUT=$(as_s "$H" c2 "$H" claim --thread mcp:wrong); has "...a wrong --thread -> BUSY" "BUSY" "$OUT"
plog "$H" mcp-t-c2 sess-c2
OUT=$(as_s "$H" c2 "$H" claim); has "the successor (thread from its provider log) takes the seat" "HANDOVER:" "$OUT"
has "...OK" "OK: this session" "$OUT"; is "...marker names c2" "$(cat "$H/.claude/state/orchestrator")" sess-c2
is "...sidecar still names c1 until t3-bind" "$(jq -r .sessionId "$SIDE")" sess-c1
OUT=$(printf '%s\n' "$U2" | as_s "$H" c2 "$H" t3-bind --thread mcp:t-c2 --title "coord two" --task task-2 --model opus); ALL="$ALL$OUT"
has "c2 t3-bind -> the previous holder is woken" "Woke the previous holder coord one" "$OUT"
has "...the wake went to the OLD address" "/api/hooks/t1/$S1" "$(grep 'seat taken over' "$TMP/hook.log")"
has "...with the takeover text" "seat taken over by coord two (thread mcp:t-c2)" "$(cat "$TMP/hook.log")"
TW=$(grep 'seat taken over' "$TMP/hook.log" | sed 's/^[^ ]* //')
is "...a notice, not a report: head and text, no line for the coordinator (the old holder is a worker now)" "$(jq -r .prompt <<<"$TW")" "Report from coord two (thread mcp:t-c2): seat taken over by coord two (thread mcp:t-c2)"
is "...still from the successor's session and thread" "$(jq -c '[.session,.thread]' <<<"$TW")" '["sess-c2","mcp:t-c2"]'
is "...posts.tsv counts it under the successor" "$(tail -1 "$H/.claude/state/t3-report/posts.tsv")" "$(date +%F)	coord two	sess-c2	mcp:t-c2"
lacks "...nothing went to the new address" "$S2" "$(cat "$TMP/hook.log")"
is "...previous = c1" "$(jq -c '.previous | [.sessionId,.threadId,.reportTaskId]' "$SIDE")" '["sess-c1","mcp:t-c1","task-1"]'
lacks "...a takeover bind names no task to delete (the old holder deletes its own)" "delete_scheduled_task" "$OUT"
is "...no handover any more" "$(jq -r 'has("handover")' "$SIDE")" false
N=$(wc -l < "$TMP/hook.log")
OUT=$(printf '%s\n' "$U2" | as_s "$H" c2 "$H" t3-bind --thread mcp:t-c2 --title "coord two" --task task-3 --model fable)
has "a re-bind with a new task names the OLD one to delete" "Delete the old report task now: delete_scheduled_task task-2" "$OUT"
lacks "...never the task just bound" "delete_scheduled_task task-3" "$OUT"
OUT=$(printf '%s\n' "$U2" | as_s "$H" c2 "$H" t3-bind --thread mcp:t-c2 --title "coord two" --task task-3 --model fable)
lacks "a re-bind with the same task names nothing to delete" "delete_scheduled_task" "$OUT"
is "a re-bind keeps previous" "$(jq -r '.previous.sessionId + " " + .reportTaskId' "$SIDE")" "sess-c1 task-3"
is "...and wakes nobody" "$(wc -l < "$TMP/hook.log")" "$N"
OUT=$(as_s "$H" c2 "$H" status); ALL="$ALL$OUT"; has "status shows the previous holder" "previous holder coord one" "$OUT"
OUT=$(as_s "$H" c2 "$H" release); ALL="$ALL$OUT"
has "release -> names the report task to delete" "delete_scheduled_task task-3" "$OUT"
[ -e "$SIDE" ] && bad "release deletes the sidecar" gone present || ok "release deletes the sidecar"
kill "$C1P" 2>/dev/null

echo "== B: the asleep guard =="
H=$(new_home); SIDE=$H/.claude/state/orchestrator.t3.json
as_s "$H" c1 "$H" claim >/dev/null; printf '%s\n' "$U1" | as_s "$H" c1 "$H" t3-bind --thread mcp:t-c1 --title "coord one" --task task-1 --model m >/dev/null
# c1's process is gone now (as_s removed its registry entry): asleep in T3
OUT=$(as_s "$H" w1 "$H" claim); has "claim over an asleep holder -> refused" "REFUSED: the coordinator sess-c1 is asleep" "$OUT"
has "...says how to wake it" "t3_thread_send mcp:t-c1" "$OUT"; is "...marker unchanged" "$(cat "$H/.claude/state/orchestrator")" sess-c1
OUT=$(as_s "$H" w1 "$H" release sess-c1); has "release <id> of an asleep holder -> refused" "REFUSED: sess-c1 is asleep" "$OUT"
has "...names the override" "release sess-c1 --t3-asleep-ok" "$OUT"
has "status still names the binding" 'thread mcp:t-c1' "$(as_s "$H" w1 "$H" status)"
OUT=$(as_s "$H" w1 "$H" release sess-c1 --t3-asleep-ok); has "release <id> --t3-asleep-ok -> OK" "OK: the marker pointing" "$OUT"
has "...tells to delete the old report task" "delete_scheduled_task task-1" "$OUT"
[ -e "$SIDE" ] || [ -e "$H/.claude/state/orchestrator" ] && bad "...marker and sidecar gone" gone present || ok "...marker and sidecar gone"
as_s "$H" c1 "$H" claim >/dev/null; printf '%s\n' "$U1" | as_s "$H" c1 "$H" t3-bind --thread mcp:t-c1 --title "coord one" --task task-1 --model m >/dev/null
OUT=$(as_s "$H" w1 "$H" claim --t3-asleep-ok); has "claim --t3-asleep-ok -> override" "OVERRIDE (--t3-asleep-ok)" "$OUT"
has "...tells to delete the old report task" "delete_scheduled_task task-1" "$OUT"; has "...OK" "OK: this session" "$OUT"
[ -e "$SIDE" ] && bad "...old sidecar deleted" gone present || ok "...old sidecar deleted"
rm -f "$H/.claude/state/orchestrator"; as_s "$H" c1 "$H" claim >/dev/null   # no sidecar: 0.10.0 behaviour
has "no sidecar -> a gone holder is taken over at once (unchanged)" "no longer running" "$(as_s "$H" w1 "$H" claim)"

echo "== C: session-role banners =="
H=$(new_home); SIDE=$H/.claude/state/orchestrator.t3.json
as_s "$H" c1 "$H" claim >/dev/null; printf '%s\n' "$U1" | as_s "$H" c1 "$H" t3-bind --thread mcp:t-c1 --title "coord one" --task task-1 --model m >/dev/null
me "$H" w1 "$H"
OUT=$(role "$H" sess-w1); ALL="$ALL$OUT"
has "asleep T3 coordinator -> worker banner" 'Session role: WORKER ("w1"). The coordinator is asleep in T3 thread "coord one" (mcp:t-c1)' "$OUT"
has "...report = last text, sent by the Stop hook only with the line" "delivered to the coordinator by the Stop hook ONLY when a line" "$OUT"
has "...the line says what matters to the user" 'starts with "For your user: <one line>" (what in it matters to your user); "For your user: nothing" or no' "$OUT"
has "...without it nothing is sent, unless a token" "such line: nothing is sent, unless the text carries READY, LIVE, BLOCKED, ERROR, BUG, CRITICAL," "$OUT"
has "...an answer to the coordinator is a report" "every answer to the coordinator's t3_thread_send; never" "$OUT"
has "...the user in this thread is answered here" "Your user talking to you in this thread: answer them here, without" "$OUT"
has "...never SendMessage/poke" "Never SendMessage" "$OUT"; has "...tools first, report last" "Tools first, report last" "$OUT"
has "...Keepalive -> OK" 'exactly "Keepalive": answer exactly "OK" and nothing else' "$OUT"
has "...book READY/LIVE/BLOCKED/question with topics.py entry" "Book every READY / LIVE / BLOCKED / question report first" "$OUT"
has "...the command shape incl. --waits-on" 'scripts/topics.py" entry --status <s> [--stage ready|live] [--waits-on "user · <q> · rec: <r>"] "<headline>"' "$OUT"
has "...a lane's first entry needs no --new" "the first entry creates it" "$OUT"
has "...T3 worktree is not removed" "belongs to T3: never /wt done" "$OUT"
lacks "...not stale" "not visibly alive" "$OUT"; lacks "...no release hint" "release sess-c1" "$OUT"
OUT=$(role "$H" sess-w1); ALL="$ALL$OUT"
lacks "second message of the T3 worker -> the short hint" "Book every READY" "$OUT"
has "...report channel, the report line, what to report and Keepalive in one line" 'Your report = the last text of a turn; the Stop hook sends it only when a line starts with "For your user: <one line>" ("For your user: nothing" is not sent), or it carries READY, LIVE, BLOCKED, ERROR, BUG, CRITICAL, SECURITY or a question. Report those, your wrap and every answer to the coordinator (something only for it: "For your user: nothing new · <point>"), never interim status; your user talking to you here gets the answer here, no report line unless the coordinator must act. Never SendMessage or poke a T3 coordinator, never message other workers. A message that is exactly "Keepalive": answer exactly "OK" and nothing else.' "$OUT"
has "...names the asleep coordinator" 'The coordinator is asleep in T3 thread "coord one" (mcp:t-c1)' "$OUT"
is "...at most five lines" "$(( $(printf '%s\n' "$OUT" | grep -c .) <= 5 ))" 1
CP=$(live "$H" c1 "$H")   # the coordinator wakes: the role line changes, the rules do not
OUT=$(role "$H" sess-w1); ALL="$ALL$OUT"
has "coordinator awake -> the live role line" 'The coordinator is T3 thread "coord one" (mcp:t-c1) ("c1").' "$OUT"
lacks "...still the short hint, no re-print" "Book every READY" "$OUT"
kill "$CP" 2>/dev/null; for _ in 1 2 3 4 5 6 7 8 9 10; do kill -0 "$CP" 2>/dev/null || break; sleep 0.2; done
OUT=$(role "$H" sess-w1); ALL="$ALL$OUT"
has "asleep again -> the asleep line" "The coordinator is asleep in" "$OUT"
lacks "...still the short hint" "Book every READY" "$OUT"
OUT=$(role "$H" sess-w1 ""); has "a non-T3 worker -> report through t3-wake.sh" "scripts/t3-wake.sh\" \"w1\"" "$OUT"
has "...its first line says what matters to the user" 'its first line says what in it matters to your user: "For your user: <one line>" or' "$OUT"
has "...what to report, never interim" "SECURITY finding and every answer to the coordinator; never interim status." "$OUT"
lacks "...no T3 worktree line" "belongs to T3" "$OUT"
lacks "...no topics.py line (outside T3 the banner is unchanged)" "topics.py" "$OUT"
rm -f "$SIDE"
has "no sidecar -> the 0.10.0 stale hint" "not visibly alive" "$(role "$H" sess-w1)"
# live T3 coordinator
rm -f "$H/.claude/sessions/$$.json"; rm -f "$H/.claude/state/orchestrator"
as_s "$H" c1 "$H" claim >/dev/null; printf '%s\n' "$U1" | as_s "$H" c1 "$H" t3-bind --thread mcp:t-c1 --title "coord one" --task task-1 --model m >/dev/null
me "$H" c1 "$H"; live "$H" w1 "$H" >/dev/null
OUT=$(role "$H" sess-c1); ALL="$ALL$OUT"
has "T3 coordinator banner" "Session role: ORCHESTRATOR" "$OUT"
has "T3 coordinator banner: a wrap is the cue for the settle check" "in T3: run the settle check" "$OUT"
has "...starts lanes itself" "larger packages go to worker sessions: start it yourself (t3_thread_launch) and name its model." "$OUT"
has "...settles a wrapped lane and its sub-agent threads in the same turn" "settle its thread and its sub-agent threads in the same turn" "$OUT"
has "...sweeps at seat take, after every wrap, before handover" "Sweep for finished, unsettled threads when you take the seat, after every wrap and before you hand over." "$OUT"
has "...cleanup at the merge, same turn, T3 worktree once settled" "(/wt <name> done <topic>; a T3 worktree once its thread is settled), delete its branch, and put the" "$OUT"
has "...one lane = one session, launched by itself" "a new lane gets a FRESH session — start it yourself (t3_thread_launch)" "$OUT"
lacks "...never asks the user to open a lane session" "ask your user to open one" "$OUT"
has "...a new report task on a model change" "After a model or effort change: a NEW report task" "$OUT"
has "...no t3_thread_wait after t3_thread_send" "do not t3_thread_wait after" "$OUT"
has "...forward late reports after a takeover" "forward every report that" "$OUT"
has "...bookkeeping first, answer last" "Your user sees only the last text of a turn they started: bookkeeping first, answer last" "$OUT"
has "...the full answer again only in a turn the user started" "after your answer in a turn they started: end with the full answer again" "$OUT"
has "...a turn a report started: only what matters" "turn a worker report or a wake started, write only what matters to them (often nothing)" "$OUT"
has "...Keepalive -> OK" 'exactly "Keepalive": answer exactly "OK"' "$OUT"
has "...names its binding" 'T3 thread "coord one" (mcp:t-c1), report task task-1' "$OUT"
has "...book reports, answers and OKs with topics.py" 'scripts/topics.py" entry --topic <key> ... or answer --topic <key> "<text>"' "$OUT"
has "...quiet mode off (no config): every report is a turn" "themselves as turns of this thread" "$OUT"
printf '{"quietReports":{"enabled":true}}\n' > "$H/.claude/middle-management.json"
OUT=$(role "$H" sess-c1); ALL="$ALL$OUT"
has "...quiet mode on: the quiet reports line" 'Worker reports may arrive inside your turn as "Worker reports (quiet)"' "$OUT"
has "...only marked turns arrive, important = anything but nothing" 'only turns with a "For your user:" line or a CAPITAL token), quiet mode: a turn' "$OUT"
has "...the wake rule" 'for a report ("For your user: nothing" alone is none), digested.' "$OUT"
has "...handled in the turn, no reply per report" "do not open a chat reply per report" "$OUT"
lacks "...not the every-report-is-a-turn line" "as turns of this thread" "$OUT"
has "...the rest of the line stays" "Task or ask a worker with t3_thread_send <its thread id>" "$OUT"
OUT=$(role "$H" sess-c1); ALL="$ALL$OUT"
lacks "second message of the T3 coordinator -> the short hint" "RE-WAKE checklist" "$OUT"
has "...the event duties in one line, settle and the last text included" "At events: a lane reports done and wrapped → settle it and its sub-agent threads; a lane's pull request is merged → clean up its lane in the same turn; a task starts → check your tokens; your user started the turn → bookkeeping first, answer last, never a one-line addendum; a worker report or a wake started it → only what matters to them, restated in their next turn." "$OUT"
has "...the seat binding, quiet mode, Keepalive" 'T3 Code: your seat is bound to T3 thread "coord one" (mcp:t-c1), report task task-1; worker reports arrive by themselves (quiet mode). A message that is exactly "Keepalive": answer exactly "OK"' "$OUT"
has "...where the full rules are" "Full rules: skill middle-management:middle-management" "$OUT"
is "...at most five lines plus the worker list" "$(( $(printf '%s\n' "$OUT" | grep -vc '^Current workers') <= 5 ))" 1
rm -f "$H/.claude/middle-management.json"
OUT=$(role "$H" sess-c1 ""); lacks "a coordinator outside T3 gets no T3 lines" "T3 Code" "$OUT"
lacks "...no settle sentence outside T3" "unsettled threads" "$OUT"
has "...cleanup at the merge outside T3" "a lane's pull request is merged -> in the same turn stop" "$OUT"
has "...plain /wt done there" "(/wt <name> done <topic>), delete its branch, and put the" "$OUT"
has "...starts lanes itself where the host lets it, else asks the user" "start it yourself where your host lets you, else ask your user to open one and name the model" "$OUT"
jq 'del(.reportUrl) | .sessionId = "sess-other"' "$SIDE" > "$TMP/x"; cp "$TMP/x" "$SIDE"
has "T3 coordinator without its binding -> told to t3-bind" "no thread binding yet" "$(role "$H" sess-c1)"
# former coordinator: the successor bound, this session is "previous"
jq '.sessionId = "sess-c2" | .previous = {sessionId:"sess-c1", threadId:"mcp:t-c1", reportTaskId:"task-1"}' "$SIDE" > "$TMP/x"; cp "$TMP/x" "$SIDE"
echo sess-c2 > "$H/.claude/state/orchestrator"; live "$H" c2 "$H" >/dev/null
OUT=$(role "$H" sess-c1)
has "former coordinator -> worker banner" 'Session role: WORKER ("c1")' "$OUT"
has "...forward late reports, delete the old task last" "delete_scheduled_task task-1" "$OUT"
rm -f "$H/.claude/sessions/$$.json"

echo "== D: scopeMode per-root =="
H=$(new_home); mkdir -p "$H/A" "$H/B" "$H/plain"; git -C "$H/A" init -q; git -C "$H/B" init -q
printf '{"scopeMode":"per-root"}\n' > "$H/.claude/middle-management.json"
OUT=$(as_s "$H" a1 "$H/A" claim); has "root A: a1 claims" "OK: this session" "$OUT"; has "...its own scope" "Scope: A-" "$OUT"
OUT=$(as_s "$H" b1 "$H/B" claim); has "root B: b1 claims too (no BUSY across roots)" "OK: this session" "$OUT"
lacks "...not BUSY" "BUSY" "$OUT"
[ -e "$H/.claude/state/orchestrator" ] && bad "no catch-all default marker" none present || ok "no catch-all default marker"
is "two scope marker dirs" "$(ls "$H/.claude/state/scopes" | wc -l)" 2
OUT=$(as_s "$H" p1 "$H/plain" claim); has "outside every root -> claim refused" "REFUSED: this session was started outside every project root" "$OUT"
has "...status says standalone" "Standalone" "$(as_s "$H" p1 "$H/plain" status)"
LA=$(live "$H" a1 "$H/A"); LB=$(live "$H" b1 "$H/B")
me "$H" wa "$H/A"; has "worker in A sees a1" 'The coordinator is "a1"' "$(role "$H" sess-wa)"
me "$H" wb "$H/B"; has "worker in B sees b1" 'The coordinator is "b1"' "$(role "$H" sess-wb)"
me "$H" wp "$H/plain"; is "a session outside every root -> no banner" "$(role "$H" sess-wp)" ""
is "scope.py list names both roots" "$(HOME="$H" CLAUDE_CONFIG_DIR="" python3 "$P/scripts/scope.py" list | cut -f1 | sed 's/-.*//' | sort | tr '\n' ' ')" "A B "
rm -f "$H/.claude/middle-management.json"
OUT=$(as_s "$H" z1 "$H/A" status); lacks "without the key: 0.10.0 (no scope line)" "Scope:" "$OUT"
rm -f "$H/.claude/sessions/$$.json"; kill "$LA" "$LB" 2>/dev/null

echo "== E: peer-state thread column and asleep (T3) =="
H=$(new_home)
A1=aaaaaaaa-1111-2222-3333-444444444444; B1=bbbbbbbb-1111-2222-3333-444444444444; D1=dddddddd-1111-2222-3333-444444444444
mkdir -p "$H/.claude/projects/-x"
for s in $A1 $B1 $D1; do printf '{"type":"assistant","timestamp":"2026-10-20T10:00:00Z","message":{"content":[{"type":"text","text":"working on it"}]}}\n' > "$H/.claude/projects/-x/$s.jsonl"; done
for s in $A1 $B1 $D1; do printf '{"pid":999999,"sessionId":"%s","name":"n-%s","kind":"interactive","cwd":"/x","entrypoint":"sdk-ts"}\n' "$s" "${s:0:4}" > "$H/.claude/sessions/${s:0:4}.json"; done
plog "$H" mcp-$A1 "$A1"; printf 'tool output quoting "session_id":"%s"\n' "$A1" > "$H/.t3/userdata/logs/provider/events.foreign.log"
plog "$H" mcp-$B1 "$B1"; printf 'x\n' >> "$H/.t3/userdata/logs/provider/events.foreign.log"
printf '{"sessionId":"%s","threadId":"t"}\n' "$D1" > "$H/.claude/state/orchestrator.t3.json"
PS() { HOME="$H" CLAUDE_CONFIG_DIR="" T3CODE_HOME="$H/.t3" python3 "$P/scripts/peer-state.py" "$@"; }
J=$(PS --all --json)
is "a session keyed in two logs -> thread unknown" "$(jq -r --arg s $A1 '.[] | select(.session_id==$s) | .thread' <<<"$J")" null
is "a session keyed in one log -> its thread (mcp: restored)" "$(jq -r --arg s $B1 '.[] | select(.session_id==$s) | .thread' <<<"$J")" "mcp:$B1"
is "process gone + T3 thread -> asleep_t3" "$(jq -r --arg s $B1 '.[] | select(.session_id==$s) | .asleep_t3' <<<"$J")" true
is "process gone + named by a sidecar -> asleep_t3" "$(jq -r --arg s $D1 '.[] | select(.session_id==$s) | .asleep_t3' <<<"$J")" true
is "process gone, no thread, no sidecar -> not asleep" "$(jq -r --arg s $A1 '.[] | select(.session_id==$s) | .asleep_t3' <<<"$J")" false
OUT=$(PS); has "the default table lists asleep T3 sessions" "asleep (T3)" "$OUT"; has "...with a THREAD column" "THREAD" "$OUT"
lacks "...not the dead non-T3 one" "n-aaaa" "$OUT"
LOG=$H/log.md; printf '## 2026-10-20\n\n### 23:59 – [n-bbbb] – x\n- Status: completed\n- Session: closed · %s\n' "$B1" > "$LOG"
is "a closed marker wins: wrapped, not asleep" "$(MM_SESSION_LOG=$LOG PS --all --json | jq -r --arg s $B1 '.[] | select(.session_id==$s) | [.wrapped, .asleep_t3] | join(" ")')" "yes false"

echo "== F: orch-heartbeat skips a T3-bound coordinator =="
H=$(new_home); echo sess-hb > "$H/.claude/state/orchestrator"
printf '{"sessionId":"sess-hb","threadId":"t"}\n' > "$H/.claude/state/orchestrator.t3.json"
HOME="$H" CLAUDE_CONFIG_DIR="" OHB_ALARM_SINK="$TMP/alarms" OHB_POKE_SINK="$TMP/pokes" OHB_PEERS=/dev/null bash "$P/scripts/orch-heartbeat.sh" tick >/dev/null 2>&1
has "tick ends as t3-coordinator" "t3-coordinator" "$(cat "$H"/.claude/state/orch-heartbeat/last-tick 2>/dev/null)"
[ -s "$TMP/alarms" ] && bad "...no alarm" none "$(cat "$TMP/alarms")" || ok "...no alarm"

echo "== G: the morning takeover (claim --morning) =="
# g_home: c1 bound and asleep (its process gone), its transcript quiet for $1 (a date -d phrase)
g_home() {
  H=$(new_home); SIDE=$H/.claude/state/orchestrator.t3.json; LOG=$H/logs/session-log.md; mkdir -p "$H/logs" "$H/.claude/projects/-x"; : > "$LOG"
  printf '{"sessionLog":"%s","morningTakeover":{"allowed":true,"okBy":"Alex, 2026-10-21"}}\n' "$LOG" > "$H/.claude/middle-management.json"
  as_s "$H" c1 "$H" claim >/dev/null; printf '%s\n' "$U1" | as_s "$H" c1 "$H" t3-bind --thread mcp:t-c1 --title "coord one" --task task-1 --model m >/dev/null
  printf '{"type":"assistant","timestamp":"%s","message":{"content":[{"type":"text","text":"night work done"}]}}\n' \
    "$(date -u -d "$1" +%Y-%m-%dT%H:%M:%SZ)" > "$H/.claude/projects/-x/sess-c1.jsonl"
  touch -d "$1" "$H/.claude/projects/-x/sess-c1.jsonl"
}
g_home "3 hours ago"; jq 'del(.morningTakeover)' "$H/.claude/middle-management.json" > "$TMP/x"; cp "$TMP/x" "$H/.claude/middle-management.json"
OUT=$(as_s "$H" m1 "$H" claim --morning); has "--morning without the standing word -> refused" "needs the user's standing word" "$OUT"
is "...marker unchanged" "$(cat "$H/.claude/state/orchestrator")" sess-c1
jq '.morningTakeover = {allowed: false}' "$H/.claude/middle-management.json" > "$TMP/x"; cp "$TMP/x" "$H/.claude/middle-management.json"
has "allowed false -> refused" "needs the user's standing word" "$(as_s "$H" m1 "$H" claim --morning)"
has "the plain asleep refusal names the morning route" "claim --morning" "$(as_s "$H" m1 "$H" claim)"
g_home "5 minutes ago"
OUT=$(as_s "$H" m1 "$H" claim --morning); has "holder moved 5 min ago -> refused" "REFUSED (--morning): the asleep coordinator sess-c1 moved" "$OUT"
is "...marker unchanged" "$(cat "$H/.claude/state/orchestrator")" sess-c1; [ -e "$SIDE" ] && ok "...sidecar kept" || bad "...sidecar kept" present gone
g_home "3 hours ago"; N0=$(wc -l < "$TMP/hook.log")
OUT=$(as_s "$H" m1 "$H" claim --thread mcp:t-m1 --morning); ALL="$ALL$OUT"
has "asleep + quiet + standing word -> MORNING TAKEOVER" "MORNING TAKEOVER (standing word: Alex, 2026-10-21)" "$OUT"
has "...OK" "OK: this session" "$OUT"; is "...marker names m1" "$(cat "$H/.claude/state/orchestrator")" sess-m1
has "...SETTLE line names the old report task" "delete_scheduled_task task-1" "$OUT"
has "...never message it" "Never t3_thread_send it" "$OUT"
has "...log not completed -> backfilled" "BACKFILLED: wrap entry for \"coord one\"" "$OUT"
has "...the entry closes c1" "- Session: closed · sess-c1" "$(cat "$LOG")"
has "...and says why" "coordinator asleep at the morning takeover, wrap backfilled" "$(cat "$LOG")"
has "...and whose word" "the morning takeover (standing word: Alex, 2026-10-21)" "$(cat "$LOG")"
is "...nobody was woken" "$(wc -l < "$TMP/hook.log")" "$N0"
[ -e "$SIDE" ] && bad "...the old sidecar is gone" gone present || ok "...the old sidecar is gone"
PF=$H/.claude/state/orchestrator.t3.previous.json
is "...the predecessor note, 0600" "$(stat -c %a "$PF" 2>/dev/null)" 600
is "...names thread and task, no URL" "$(jq -c '[.sessionId,.threadId,.reportTaskId,has("reportUrl")]' "$PF")" '["sess-c1","mcp:t-c1","task-1",false]'
has "status shows the predecessor" "Predecessor:  thread mcp:t-c1" "$(as_s "$H" m1 "$H" status)"
OUT=$(printf '%s\n' "$U2" | as_s "$H" m1 "$H" t3-bind --thread mcp:t-m1 --title "morning" --task task-m --model m); ALL="$ALL$OUT"
lacks "t3-bind after the morning takeover wakes nobody" "Woke the previous holder" "$OUT"; is "...no POST" "$(wc -l < "$TMP/hook.log")" "$N0"
is "...previous = c1 from the note" "$(jq -c '.previous | [.sessionId,.threadId,.reportTaskId]' "$SIDE")" '["sess-c1","mcp:t-c1","task-1"]'
[ -e "$PF" ] && bad "...the note is consumed" gone present || ok "...the note is consumed"
# completed log entry -> no backfill
# wrapped (its closed marker in the log) -> no second entry; the marker reader needs a hex sessionId
g_home "3 hours ago"; HX=abcdef12-0000-4000-8000-000000000001
echo "$HX" > "$H/.claude/state/orchestrator"; jq --arg x "$HX" '.sessionId = $x' "$SIDE" > "$TMP/x"; cp "$TMP/x" "$SIDE"
mv "$H/.claude/projects/-x/sess-c1.jsonl" "$H/.claude/projects/-x/$HX.jsonl"
printf '## %s\n\n### %s – [c1] – night\n- Status: completed\n- Session: closed · %s\n' "$(date -d '3 hours ago' +%F)" "$(date -d '3 hours ago' +%H:%M)" "$HX" > "$LOG"
SL=$(wc -l < "$LOG"); OUT=$(as_s "$H" m1 "$H" claim --morning)
has "wrapped (closed marker) -> takeover" "MORNING TAKEOVER" "$OUT"; lacks "...no second wrap entry" "BACKFILLED" "$OUT"; is "...log untouched" "$(wc -l < "$LOG")" "$SL"
# no transcript to read -> fail closed
g_home "3 hours ago"; rm -f "$H/.claude/projects/-x/sess-c1.jsonl"
OUT=$(as_s "$H" m1 "$H" claim --morning); has "holder unreadable -> refused (fail closed)" "could not be read off disk" "$OUT"
is "...marker unchanged" "$(cat "$H/.claude/state/orchestrator")" sess-c1
# a live holder is never taken by --morning
g_home "3 hours ago"; GP=$(live "$H" c1 "$H")
OUT=$(as_s "$H" m1 "$H" claim --morning); has "live holder -> the usual rules (BUSY)" "BUSY" "$OUT"
is "...marker unchanged" "$(cat "$H/.claude/state/orchestrator")" sess-c1; kill "$GP" 2>/dev/null
# a gone holder outside T3 (no sidecar), its log not completed -> taken (as before) and backfilled
g_home "3 hours ago"; rm -f "$SIDE"
OUT=$(as_s "$H" m1 "$H" claim --morning); has "gone non-T3 holder -> taken" "OK: this session" "$OUT"
has "...backfilled" "BACKFILLED" "$OUT"; has "...the entry closes c1" "- Session: closed · sess-c1" "$(cat "$LOG")"
has "...says why" "coordinator gone at the morning takeover" "$(cat "$LOG")"
OUT=$(as_s "$H" m2 "$H" claim); lacks "a plain claim never backfills" "BACKFILLED" "$OUT"

echo "== G2: review fixes - outcome, order, note lifetime =="
mstat() { mkdir -p "$H/.claude/state/morning-t3"; printf '%s\tposted\t%s\t1\n' "$(date +%F)" "$(date +%s)" > "$H/.claude/state/morning-t3/status"; }
g_note() { jq --arg n "cat >> $H/notes" '. + {notifyCommand: $n}' "$H/.claude/middle-management.json" > "$TMP/x"; cp "$TMP/x" "$H/.claude/middle-management.json"; }
g_home "5 minutes ago"; g_note; mstat
OUT=$(as_s "$H" m1 "$H" claim --morning); is "a refused morning claim -> status refused" "$(cut -f2 "$H/.claude/state/morning-t3/status")" refused
is "...names the refused claimer (5th column)" "$(cut -f5 "$H/.claude/state/morning-t3/status")" sess-m1
has "...the user is told" "The morning coordinator could not take over" "$(cat "$H/notes" 2>/dev/null)"
g_home "3 hours ago"; g_note; mstat
OUT=$(as_s "$H" m1 "$H" claim --morning); is "a successful morning claim -> status claimed" "$(cut -f2 "$H/.claude/state/morning-t3/status")" claimed
[ -s "$H/notes" ] && bad "...no refusal notice" none "$(cat "$H/notes")" || ok "...no refusal notice"
g_home "3 hours ago"; jq 'del(.morningTakeover)' "$H/.claude/middle-management.json" > "$TMP/x"; cp "$TMP/x" "$H/.claude/middle-management.json"; g_note; mstat
OUT=$(as_s "$H" m1 "$H" claim --morning); is "no takeover word -> status refused too" "$(cut -f2 "$H/.claude/state/morning-t3/status")" refused
g_home "3 hours ago"; chmod 444 "$H/.claude/state/orchestrator"
OUT=$(as_s "$H" m1 "$H" claim --morning); has "marker not writable -> FAILED" "FAILED" "$OUT"
[ -e "$SIDE" ] && ok "...a claim that did not win keeps the old sidecar" || bad "...a claim that did not win keeps the old sidecar" present gone
[ -e "$H/.claude/state/orchestrator.t3.previous.json" ] && bad "...and writes no predecessor note" none present || ok "...and writes no predecessor note"
lacks "...prints no SETTLE line" "SETTLE" "$OUT"
chmod 644 "$H/.claude/state/orchestrator"
# the note belongs to its claimer: a later claim of another session drops it, a foreign t3-bind ignores it
g_home "3 hours ago"; PF=$H/.claude/state/orchestrator.t3.previous.json
as_s "$H" m1 "$H" claim --morning >/dev/null; is "note written, by m1" "$(jq -r .by "$PF")" sess-m1
OUT=$(as_s "$H" m2 "$H" claim); has "m1 gone, m2 claims" "OK: this session" "$OUT"
[ -e "$PF" ] && bad "...the stale note is dropped" gone present || ok "...the stale note is dropped"
lacks "...status shows no predecessor" "Predecessor" "$(as_s "$H" m2 "$H" status)"
printf '{"sessionId":"sess-c1","threadId":"mcp:t-c1","reportTaskId":"task-1","by":"sess-other"}\n' > "$PF"
printf '%s\n' "$U2" | as_s "$H" m2 "$H" t3-bind --thread mcp:t-m2 --title m2 --task task-m2 --model m >/dev/null
is "a foreign note is not filed as previous" "$(jq -r 'has("previous")' "$SIDE")" false
printf '{"by":"sess-m2"}\n' > "$PF"; as_s "$H" m2 "$H" release >/dev/null
[ -e "$PF" ] && bad "release drops the note" gone present || ok "release drops the note"

echo "== H: coordinatorModelRule =="
H=$(new_home); CF=$H/.claude/middle-management.json
OUT=$(as_s "$H" h1 "$H" claim); has "no config file -> the default model line" "Coordinator model: the highest model available. Compare your model" "$OUT"
has "...names orchestrator_capabilities, first line, hand the seat" 'available models (in T3 Code: orchestrator_capabilities); a better match is listed: say so in your first line and hand the seat to a session on that model' "$OUT"
has "...successor and morning coordinator too" "Your successor and the scheduled morning coordinator get that model too." "$OUT"
printf '{"userName":"u"}\n' > "$CF"; as_s "$H" h1 "$H" release >/dev/null
OUT=$(as_s "$H" h1 "$H" claim); has "key absent -> the default model line" "Coordinator model: the highest model available." "$OUT"
printf '{"coordinatorModelRule":null}\n' > "$CF"; as_s "$H" h1 "$H" release >/dev/null
OUT=$(as_s "$H" h1 "$H" claim); has "key null -> the default model line" "Coordinator model: the highest model available." "$OUT"
printf '{"coordinatorModelRule":""}\n' > "$CF"; as_s "$H" h1 "$H" release >/dev/null
OUT=$(as_s "$H" h1 "$H" claim); lacks "empty string -> off, no model line" "Coordinator model:" "$OUT"
printf '{"coordinatorModelRule":"  "}\n' > "$CF"; as_s "$H" h1 "$H" release >/dev/null
OUT=$(as_s "$H" h1 "$H" claim); lacks "blank key -> off, no model line" "Coordinator model:" "$OUT"
printf '{"coordinatorModelRule":"the highest available Fable"}\n' > "$CF"; as_s "$H" h1 "$H" release >/dev/null
OUT=$(as_s "$H" h1 "$H" claim); has "key set -> the user's rule replaces the default" "Coordinator model: the highest available Fable. Compare your model" "$OUT"
lacks "...and the default is not printed" "the highest model available" "$OUT"
g_home "3 hours ago"; jq '.coordinatorModelRule = "the highest available Fable"' "$H/.claude/middle-management.json" > "$TMP/x"; cp "$TMP/x" "$H/.claude/middle-management.json"
OUT=$(as_s "$H" m1 "$H" claim --thread mcp:t-m1 --morning); has "--morning claim -> the model line too" "Coordinator model: the highest available Fable." "$OUT"
vcfg() { printf '%s' "$1" > "$TMP/vc/middle-management.json"; CLAUDE_CONFIG_DIR="$TMP/vc" bash "$P/scripts/config-check.sh" validate >/dev/null 2>&1; echo $?; }
mkdir -p "$TMP/vc"
is "config-check: a string is valid" "$(vcfg '{"coordinatorModelRule":"the highest Fable"}')" 0
is "config-check: blank is valid" "$(vcfg '{"coordinatorModelRule":""}')" 0
is "config-check: a number is rejected" "$(vcfg '{"coordinatorModelRule":5}')" 1

echo "== I: handoverTokens hand-over line, handoverWarnTokens warn line =="
H=$(new_home); as_s "$H" ho "$H" claim >/dev/null; me "$H" ho "$H"
tx() {  # <tokens>: a fake transcript whose last usage line sums to <tokens>
  printf '{"type":"user","message":{"content":"hi"}}\n{"type":"assistant","message":{"usage":{"input_tokens":1,"cache_creation_input_tokens":0,"cache_read_input_tokens":%s}}}\n' "$(($1 - 1))" > "$TMP/tx.jsonl"; }
hrole() {  # <sessionId> <transcript> [T3 home or ""]
  printf '{"session_id":"%s","transcript_path":"%s"}' "$1" "$2" | HOME="$H" CLAUDE_CONFIG_DIR="" CLAUDE_PLUGIN_ROOT="$P" T3CODE_HOME="${3-$H/.t3}" bash "$ROLE" 2>&1; }
hprompt() {  # <sessionId> <transcript> <prompt as a JSON string>: the same, with the prompt field
  printf '{"session_id":"%s","transcript_path":"%s","prompt":%s}' "$1" "$2" "$3" | HOME="$H" CLAUDE_CONFIG_DIR="" CLAUDE_PLUGIN_ROOT="$P" T3CODE_HOME="$H/.t3" bash "$ROLE" 2>&1; }
WARN_TAIL=". Before you start this task: a big one (a new lane, a plan, an integration run, anything of several steps) → hand over first; a very small one (one line, one answer, one settle) → do it here."
tx 249000; OUT=$(hrole sess-ho "$TMP/tx.jsonl"); ALL="$ALL$OUT"
lacks "below the warn mark (default 250k) -> no token line" "CONTEXT" "$OUT"
has "...the banner is unchanged" "Session role: ORCHESTRATOR" "$OUT"
tx 299000; OUT=$(hrole sess-ho "$TMP/tx.jsonl"); ALL="$ALL$OUT"
is "past the warn mark, below the mark -> the FIRST line is the warn line" "$(head -1 <<<"$OUT")" "CONTEXT 299k of 300k$WARN_TAIL"
lacks "...no 'hand over now'" "hand over now" "$OUT"
has "...the rest of the banner follows" "Session role: ORCHESTRATOR" "$OUT"
lacks "a Keepalive prompt -> no warn line" "CONTEXT" "$(hprompt sess-ho "$TMP/tx.jsonl" '"Keepalive"')"
has "a normal prompt -> the warn line" "CONTEXT 299k of 300k" "$(hprompt sess-ho "$TMP/tx.jsonl" '"plan the next lane"')"
has "a prompt that only mentions Keepalive -> still the line" "CONTEXT 299k of 300k" "$(hprompt sess-ho "$TMP/tx.jsonl" '"why was Keepalive sent?"')"
tx 412000; OUT=$(hrole sess-ho "$TMP/tx.jsonl"); ALL="$ALL$OUT"
is "past the mark, T3 -> the FIRST line says hand over now, small-task exception" "$(head -1 <<<"$OUT")" \
  "CONTEXT 412k tokens, past the hand-over mark of 300k: hand over now — launch the successor (t3_thread_launch), then orchestrator.sh t3-handover --to-thread <id> --to-title <title>. Only a very small task (one line, one answer, one settle) may still be done here first."
lacks "...below 2x: no 'start nothing else'" "Start nothing else first." "$OUT"
lacks "...and no warn line on top" "of 300k." "$OUT"
lacks "past the mark, Keepalive (whitespace around) -> no line" "CONTEXT" "$(hprompt sess-ho "$TMP/tx.jsonl" '"  Keepalive\n"')"
has "...the rest of the banner follows" "Session role: ORCHESTRATOR" "$OUT"
OUT=$(hrole sess-ho "$TMP/tx.jsonl" ""); L1=$(head -1 <<<"$OUT")
has "past the mark, outside T3 -> the plain handover path" "CONTEXT 412k tokens, past the hand-over mark of 300k: hand over now — ask your user for a fresh session" "$L1"
lacks "...no t3-handover outside T3" "t3-handover" "$L1"
tx 600000; OUT=$(hrole sess-ho "$TMP/tx.jsonl")
has "at 2x the mark -> 'Start nothing else first.' on the first line" "Start nothing else first." "$(head -1 <<<"$OUT")"
lacks "...and no small-task exception there" "very small task" "$(head -1 <<<"$OUT")"
live "$H" w9 "$H" >/dev/null; lacks "a worker never gets the line" "CONTEXT" "$(hrole sess-w9 "$TMP/tx.jsonl")"
lacks "no transcript file -> no line" "CONTEXT" "$(hrole sess-ho "$TMP/none.jsonl")"
printf 'not json\n{"type":"assistant","message":{"usage":{"input_tokens":0}}}\n' > "$TMP/bad.jsonl"
OUT=$(hrole sess-ho "$TMP/bad.jsonl"); lacks "unreadable transcript (no usage figure) -> no line" "CONTEXT" "$OUT"
has "...and the banner still prints" "Session role: ORCHESTRATOR" "$OUT"
lacks "no transcript_path in the input -> no line" "CONTEXT" "$(printf '{"session_id":"sess-ho"}' | HOME="$H" CLAUDE_CONFIG_DIR="" CLAUDE_PLUGIN_ROOT="$P" T3CODE_HOME="$H/.t3" bash "$ROLE" 2>&1)"
printf '{"handoverTokens":0}\n' > "$H/.claude/middle-management.json"
lacks "handoverTokens 0 -> off" "CONTEXT" "$(hrole sess-ho "$TMP/tx.jsonl")"
tx 299000; lacks "handoverTokens 0 -> the warn line is off too" "CONTEXT" "$(hrole sess-ho "$TMP/tx.jsonl")"
printf '{"handoverWarnTokens":0}\n' > "$H/.claude/middle-management.json"
lacks "handoverWarnTokens 0 -> no warn line" "CONTEXT" "$(hrole sess-ho "$TMP/tx.jsonl")"
printf '{"handoverWarnTokens":300000}\n' > "$H/.claude/middle-management.json"; tx 300000
OUT=$(hrole sess-ho "$TMP/tx.jsonl"); has "warn mark at the mark -> ignored, the hand-over line" "past the hand-over mark of 300k" "$OUT"
lacks "...and no warn line" "of 300k." "$OUT"
printf '{"handoverWarnTokens":350000}\n' > "$H/.claude/middle-management.json"; tx 299000
lacks "warn mark above the mark -> ignored, no line below the mark" "CONTEXT" "$(hrole sess-ho "$TMP/tx.jsonl")"
printf '{"handoverTokens":200000,"handoverWarnTokens":100000}\n' > "$H/.claude/middle-management.json"; tx 150000
is "both keys set -> their marks" "$(head -1 <<<"$(hrole sess-ho "$TMP/tx.jsonl")")" "CONTEXT 150k of 200k$WARN_TAIL"
printf '{"handoverTokens":100000}\n' > "$H/.claude/middle-management.json"; tx 150000
has "handoverTokens 100000 -> its mark" "CONTEXT 150k tokens, past the hand-over mark of 100k" "$(hrole sess-ho "$TMP/tx.jsonl")"
rm -f "$H/.claude/sessions/$$.json"
is "config-check: handoverTokens number is valid" "$(vcfg '{"handoverTokens":300000}')" 0
is "config-check: handoverTokens 0 is valid" "$(vcfg '{"handoverTokens":0}')" 0
is "config-check: handoverTokens string is rejected" "$(vcfg '{"handoverTokens":"300k"}')" 1
is "config-check: handoverTokens negative is rejected" "$(vcfg '{"handoverTokens":-1}')" 1
is "config-check: handoverWarnTokens number is valid" "$(vcfg '{"handoverWarnTokens":250000}')" 0
is "config-check: handoverWarnTokens 0 is valid" "$(vcfg '{"handoverWarnTokens":0}')" 0
is "config-check: handoverWarnTokens string is rejected" "$(vcfg '{"handoverWarnTokens":"250k"}')" 1
is "config-check: handoverWarnTokens negative is rejected" "$(vcfg '{"handoverWarnTokens":-5}')" 1

echo "== Z =="
lacks "no webhook secret in any output" "$S1" "$ALL"; lacks "...nor the second" "$S2" "$ALL"
lacks "no [HH:MM] prefix in the changed texts" "[HH:MM]" "$(cat "$ORCH" "$ROLE" "$P/hooks/t3-report.sh")"

echo
echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
