#!/usr/bin/env bash
# middle-management plugin: t3-settle.py matrix (fake HOME, local stub server, settles nothing real).
# Consumers: tests/run.sh (runs it with the other matrices); by hand from the repo root:
#   bash tests/t3-settle.sh
#
#   A  dry run --children-of: only idle sub-agent children (quiet >2 min), each skipped one with its
#      reason, nothing sent
#   B  --apply on one named thread: one masked thread.settle, ping answered, 64-bit frame read
#   C  --apply --children-of with a server refusal -> exit 1
#   D  named threads that are not idle are refused without being sent -> exit 1, among them a
#      parent whose own sub-agent still runs
#   E  unreachable server / protocol not understood -> exit 1
#   F  usage and config errors -> exit 2
#   Z  the token appears in no output
# One local stub serves the T3 shell (GET, checks the protocol header and the bearer) and the
# WebSocket RPC (/ws?orchestrationProtocol=2: 101 upgrade, a ping first, a noise frame, then the Exit).
set -uo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
SRC=$ROOT/plugins/middle-management/scripts
TMP=$(mktemp -d /tmp/t3-settle-test.XXXXXX)
SP=""
trap '[ -n "$SP" ] && kill "$SP" 2>/dev/null; rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok()    { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad()   { FAIL=$((FAIL+1)); printf '  FAIL %s\n     expected: %s\n     got:      %s\n' "$1" "$2" "$3"; }
is()    { [ "$2" = "$3" ] && ok "$1" || bad "$1" "$3" "$2"; }
has()   { case "$3" in *"$2"*) ok "$1" ;; *) bad "$1" "contains: $2" "$3" ;; esac; }
lacks() { case "$3" in *"$2"*) bad "$1" "lacks: $2" "$3" ;; *) ok "$1" ;; esac; }

H=$TMP/home; CFG=$H/.claude; D=$TMP/d; mkdir -p "$CFG" "$D"
TOKEN="tok-$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')"
printf '%s\n' "$TOKEN" > "$TMP/token"; chmod 600 "$TMP/token"
PORT=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')
printf '{"t3Url": "http://127.0.0.1:%s", "t3TokenFile": "%s"}\n' "$PORT" "$TMP/token" > "$CFG/middle-management.json"

kid() {  # id parent [extra json]
  printf '{"id":"%s","title":"T %s","status":"idle","activityRunStatus":null,"settledAt":null,"archivedAt":null,"deletedAt":null,"pendingRuntimeRequest":null,"pendingBackgroundTasks":[],"updatedAt":"2026-01-01T00:00:00Z","lineage":{"parentThreadId":"%s","relationshipToParent":"subagent"}%s}' "$1" "$1" "$2" "${3:-}"
}
{
  printf '{"threads":['
  printf '{"id":"mcp:parent","title":"Parent","status":"completed","activityRunStatus":null,"settledAt":null,"archivedAt":null,"pendingRuntimeRequest":null,"lineage":{"parentThreadId":null,"relationshipToParent":null},"pendingBackgroundTasks":[{"kind":"subagent","childThreadId":"kid-live"}]},'
  kid kid-a mcp:parent; printf ','
  kid kid-refuse mcp:parent; printf ','
  kid kid-live mcp:parent; printf ','
  kid kid-settled mcp:parent ',"settledAt":"2026-11-10T10:00:00Z"'; printf ','
  kid kid-run mcp:parent ',"status":"running","activityRunStatus":"running"'; printf ','
  kid kid-ask mcp:parent ',"pendingRuntimeRequest":{"kind":"approval"}'; printf ','
  kid kid-fresh mcp:parent ",\"updatedAt\":\"$(date -u +%Y-%m-%dT%H:%M:%S.000Z)\""; printf ','
  kid kid-other mcp:other
  printf '],"archivedThreads":[{"id":"arch-1"}],"projects":[]}\n'
} > "$D/shell.json"
cp "$D/shell.json" "$TMP/shell.good"

cat > "$TMP/stub.py" <<'EOF'
import base64, hashlib, http.server, json, os, sys
D, TOK = sys.argv[2], open(sys.argv[3]).read().strip()
def log(s): open(os.path.join(D, "srv.log"), "a").write(s + "\n")
class H(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    def log_message(self, *a): pass
    def answer(self, code, body=b""):
        self.send_response(code); self.send_header("content-length", str(len(body))); self.end_headers()
        self.wfile.write(body)
    def do_GET(self):
        if self.headers.get("authorization") != "Bearer " + TOK: return self.answer(401)
        if self.path == "/api/orchestration/shell":
            if self.headers.get("x-t3-orchestration-protocol") != "2": return self.answer(400)
            return self.answer(200, open(os.path.join(D, "shell.json"), "rb").read())
        if self.path != "/ws?orchestrationProtocol=2": return self.answer(426)
        if os.path.exists(os.path.join(D, "ws.426")): return self.answer(426)
        acc = base64.b64encode(hashlib.sha1((self.headers["sec-websocket-key"] + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode()).digest()).decode()
        self.wfile.write(("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
                          "Sec-WebSocket-Accept: %s\r\n\r\n" % acc).encode()); self.wfile.flush()
        self.send(b"hi", 0x9)
        while True:
            fr = self.recv()
            if fr is None: return
            op, data = fr
            if op == 0x8: log("close"); return
            if op == 0xA: log("pong " + data.decode()); continue
            m = json.loads(data); p = m["payload"]
            log("%s %s %s cid=%d" % (m["tag"], p.get("type"), p.get("threadId"), len(p.get("commandId", ""))))
            ex = {"_tag": "Failure", "cause": [{"_tag": "Fail", "error": {"_tag": "OrchestrationV2DispatchCommandError",
                  "message": "Thread kid-refuse is still running. Stop it before settling."}}]} \
                if "refuse" in p["threadId"] else {"_tag": "Success", "value": {"sequence": 7, "pad": "x" * 70000}}
            self.send(json.dumps({"_tag": "Chunk", "requestId": "99", "values": []}).encode())
            self.send(json.dumps({"_tag": "Exit", "requestId": m["id"], "exit": ex}).encode())
    def send(self, data, op=0x1):
        n = len(data)
        self.wfile.write(bytes([0x80 | op]) + (bytes([n]) if n < 126 else bytes([126]) + n.to_bytes(2, "big")
                         if n < 65536 else bytes([127]) + n.to_bytes(8, "big")) + data); self.wfile.flush()
    def recv(self):
        h = self.rfile.read(2)
        if len(h) < 2: return None
        if not h[1] & 0x80: log("UNMASKED")
        n = h[1] & 0x7F
        if n >= 126: n = int.from_bytes(self.rfile.read(2 if n == 126 else 8), "big")
        mk = self.rfile.read(4) if h[1] & 0x80 else b"\0\0\0\0"
        return h[0] & 0x0F, bytes(b ^ mk[i % 4] for i, b in enumerate(self.rfile.read(n)))
http.server.ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
EOF
python3 "$TMP/stub.py" "$PORT" "$D" "$TMP/token" & SP=$!
for _ in $(seq 50); do python3 -c "import socket; socket.create_connection(('127.0.0.1',$PORT),1)" 2>/dev/null && break; sleep 0.1; done

ALL=""
run() { OUT=$(HOME=$H CLAUDE_CONFIG_DIR=$CFG T3CODE_PORT= python3 "$SRC/t3-settle.py" "$@" 2>&1); RC=$?; ALL="$ALL$OUT"; }
srv() { cat "$D/srv.log" 2>/dev/null; }

echo "A. dry run --children-of"
run --children-of mcp:parent
is "dry run exits 0" "$RC" 0
is "dry run lists the two idle children, in order" "$(printf '%s\n' "$OUT" | grep -c '^kid-')" 2
has "line format <id>  <status>  <title>" "kid-a  idle  T kid-a" "$OUT"
has "kid-refuse is a candidate" "kid-refuse  idle" "$OUT"
for k in kid-live kid-settled kid-run kid-ask kid-fresh kid-other mcp:parent; do lacks "dry run does not offer $k" "$k " "$OUT"; done
has "skipped live child named with its reason" "skipped kid-live: sub-agent still running" "$OUT"
has "skipped running child named" "skipped kid-run: run running" "$OUT"
has "skipped asking child named" "skipped kid-ask: waiting on an approval or question" "$OUT"
has "skipped fresh child named" "skipped kid-fresh: sub-agent active in the last 120 s" "$OUT"
lacks "a settled child is done, not listed as skipped" "kid-settled" "$OUT"
lacks "another parent's child is not listed" "kid-other" "$OUT"
has "count line" "2 would be settled; add --apply to settle them." "$OUT"
is "dry run sends nothing" "$(srv)" ""

echo "B. --apply one named thread"
run --apply kid-a
is "apply kid-a exits 0" "$RC" 0
is "prints settled kid-a" "$OUT" "settled kid-a"
has "one thread.settle via dispatchCommand with a uuid commandId" "orchestration.dispatchCommand thread.settle kid-a cid=36" "$(srv)"
has "the server's ping was answered" "pong hi" "$(srv)"
has "the socket was closed" "close" "$(srv)"
lacks "every client frame was masked" "UNMASKED" "$(srv)"
: > "$D/srv.log"

echo "C. --apply --children-of with a refusal"
run --apply --children-of mcp:parent
is "a refusal exits 1" "$RC" 1
has "settled kid-a" "settled kid-a" "$OUT"
has "REFUSED with the server's reason" "REFUSED kid-refuse: Thread kid-refuse is still running. Stop it before settling." "$OUT"
is "exactly two commands sent" "$(grep -c dispatchCommand "$D/srv.log")" 2
: > "$D/srv.log"

echo "D. named threads that are not idle"
run --apply kid-live kid-settled kid-run kid-ask kid-fresh arch-1 nope
is "not-idle names exit 1" "$RC" 1
has "running sub-agent refused" "REFUSED kid-live: not idle: sub-agent still running" "$OUT"
has "settled refused" "REFUSED kid-settled: not idle: settled" "$OUT"
has "running run refused" "REFUSED kid-run: not idle: run running" "$OUT"
has "pending request refused" "REFUSED kid-ask: not idle: waiting on an approval or question" "$OUT"
has "sub-agent active in the last 2 min refused" "REFUSED kid-fresh: not idle: sub-agent active in the last 120 s" "$OUT"
has "archived refused" "REFUSED arch-1: not idle: archived" "$OUT"
has "unknown refused" "REFUSED nope: not idle: no such thread" "$OUT"
is "none of them was sent (no WebSocket opened)" "$(srv)" ""
run kid-live
is "dry run of a not-idle name exits 1" "$RC" 1
run mcp:parent
is "dry run: parent with a live sub-agent exits 1 (refused, the named-thread convention)" "$RC" 1
has "parent refused with its reason" "REFUSED mcp:parent: not idle: its own sub-agent is still running" "$OUT"
has "parent not offered" "0 would be settled" "$OUT"
run --apply mcp:parent
is "--apply on that parent exits 1" "$RC" 1
has "--apply refuses the parent" "REFUSED mcp:parent: not idle: its own sub-agent is still running" "$OUT"
is "the parent was not sent" "$(srv)" ""

echo "E. unreachable / not understood"
cp "$CFG/middle-management.json" "$TMP/cfg.bak"
printf '{"t3Url": "http://127.0.0.1:1", "t3TokenFile": "%s"}\n' "$TMP/token" > "$CFG/middle-management.json"
run --children-of mcp:parent
is "unreachable exits 1" "$RC" 1
has "says T3 does not answer" "T3 Code does not answer at http://127.0.0.1:1" "$OUT"
cp "$TMP/cfg.bak" "$CFG/middle-management.json"
echo '{"threads":[{"id":"x"}]}' > "$D/shell.json"
run --children-of mcp:parent
is "shell without the keys exits 1" "$RC" 1
has "says T3 may have changed" "T3 Code may have changed after an update" "$OUT"
cp "$TMP/shell.good" "$D/shell.json"
touch "$D/ws.426"
run --apply kid-a
is "upgrade refused (426) exits 1" "$RC" 1
has "426 named, T3 may have changed" "HTTP 426. T3 Code may have changed" "$OUT"
rm -f "$D/ws.426"

echo "F. usage and config errors"
run; is "no args exits 2" "$RC" 2
has "usage printed" "usage: t3-settle.py" "$OUT"
run --children-of; is "--children-of without id exits 2" "$RC" 2
run --children-of a b; is "--children-of with two ids exits 2" "$RC" 2
run --bogus kid-a; is "unknown option exits 2" "$RC" 2
run --apply; is "--apply alone exits 2" "$RC" 2
run --children-of mcp:nobody; is "unknown parent exits 2" "$RC" 2
chmod 644 "$TMP/token"; run kid-a; is "token readable by others exits 2" "$RC" 2
has "says chmod 600" "chmod 600" "$OUT"; chmod 600 "$TMP/token"
echo '{nope' > "$CFG/middle-management.json"; run kid-a; is "unparseable config exits 2" "$RC" 2
cp "$TMP/cfg.bak" "$CFG/middle-management.json"
printf '%s\n' "wrong-$TOKEN" > "$TMP/token2"; chmod 600 "$TMP/token2"
printf '{"t3Url": "http://127.0.0.1:%s", "t3TokenFile": "%s"}\n' "$PORT" "$TMP/token2" > "$CFG/middle-management.json"
run kid-a; is "token rejected exits 2" "$RC" 2
cp "$TMP/cfg.bak" "$CFG/middle-management.json"

echo "Z. no secret in any output"
lacks "the token appears in no output" "${TOKEN#tok-}" "$ALL"
EM=$(printf '\xe2\x80\x94')
is "no em dash in the new files" "$(grep -l "$EM" "$SRC/t3-settle.py" "$0" 2>/dev/null)" ""

echo
echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
