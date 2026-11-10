#!/usr/bin/env python3
"""t3-settle.py - settle idle T3 Code threads from a script, over the T3 server's WebSocket RPC.

Consumers: the coordinator's settle step (skills morning-ritual, middle-management, wrap;
  commands/orchestrator.md), tests/t3-settle.sh, by hand. Calls nothing beside it.

Usage: t3-settle.py [--apply] --children-of <threadId>   the idle, unsettled sub-agent children of that thread
       t3-settle.py [--apply] <threadId>...              exactly the named threads
Default is a dry run: one line per candidate `<threadId>  <status>  <title>`, with --children-of one
`skipped <id>: <reason>` per child that is not idle (settled ones left out), then the count.
--apply sends one `thread.settle` per thread and prints `settled <id>` or `REFUSED <id>: <reason>`.

Why a script: the MCP tool t3_thread_organize refuses from a background sub-agent (parent_not_active);
the server's own RPC has no live-run requirement. Route: GET <t3Url>/ws?orchestrationProtocol=2 with
`Authorization: Bearer <token>`, Effect-RPC JSON frames, method orchestration.dispatchCommand.
Idle = not settled, archived or deleted, no live run (status / activityRunStatus not preparing,
queued, starting, running, waiting), no pending request, no sub-agent of its own still running (its
own pendingBackgroundTasks empty, none of its children listed live), and not a childThreadId in its parent's
pendingBackgroundTasks: a sub-agent child row carries no run state of its own (it reads "idle" while
the sub-agent runs), only its parent lists it as live. While the parent's run is live that list
is empty (filled only once the run completes), so a sub-agent child of a live parent is never idle; and
a sub-agent child must also be quiet for QUIET_S (its updatedAt moves with every item while it works). A thread that is not idle is never sent.
Config (<CLAUDE_CONFIG_DIR or ~/.claude>/middle-management.json, the file config-check.sh checks):
t3Url (default http://127.0.0.1:$T3CODE_PORT, 8470 when unset), t3TokenFile (default
~/.config/t3-threads/token, refused when group/other can read it). The token only goes into request
headers, never into argv, output or logs.
Exit 0 all settled (or a clean dry run), 1 any refusal, T3 unreachable or not understood, 2 usage or config.
"""
import base64, datetime, hashlib, json, os, socket, ssl, sys, time, urllib.error, urllib.parse, urllib.request, uuid

LIVE = {"preparing", "queued", "starting", "running", "waiting"}
QUIET_S = 120   # ponytail: a heuristic last guard for a child whose parent is not in the shell list;
                # such a child silent >2 min in one tool call would still pass
NEWER = "T3 Code may have changed after an update: update this plugin, or tell its maintainer."
USAGE = "usage: t3-settle.py [--apply] --children-of <threadId> | t3-settle.py [--apply] <threadId>..."


def die(code, msg):
    print("t3-settle: " + msg, file=sys.stderr)
    sys.exit(code)


def config():
    path = os.path.join(os.environ.get("CLAUDE_CONFIG_DIR") or os.path.expanduser("~/.claude"), "middle-management.json")
    try:
        with open(path, encoding="utf-8") as f:
            c = json.load(f)
    except FileNotFoundError:
        return {}
    except (OSError, ValueError) as e:
        die(2, "cannot read %s (%s)" % (path, e.__class__.__name__))
    if not isinstance(c, dict):
        die(2, path + " is not a JSON object")
    return c


def token(cfg):
    path = os.path.expanduser(cfg.get("t3TokenFile") or "~/.config/t3-threads/token")
    try:
        if os.stat(path).st_mode & 0o077:
            die(2, "refusing token file %s: group or other can read it (chmod 600 it)" % path)
        with open(path, encoding="utf-8") as f:
            return f.read().strip()
    except OSError:
        die(2, "no T3 token at %s (config key t3TokenFile; /middle-management-setup step 8 makes one)" % path)


def shell(base, tok):
    req = urllib.request.Request(base + "/api/orchestration/shell", headers={
        "authorization": "Bearer " + tok, "x-t3-orchestration-protocol": "2"})
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            body = json.load(r)
    except urllib.error.HTTPError as e:
        if e.code in (401, 403):
            die(2, "T3 Code rejects the token (HTTP %d); /middle-management-setup step 8 makes a new one" % e.code)
        die(1, "the thread list answered HTTP %d. %s" % (e.code, NEWER))
    except ValueError:
        die(1, "the thread list is not JSON. " + NEWER)
    except (urllib.error.URLError, OSError) as e:
        die(1, "T3 Code does not answer at %s (%s)" % (base, getattr(e, "reason", e)))
    ok = isinstance(body, dict) and isinstance(body.get("threads"), list) and all(
        isinstance(t, dict) and all(k in t for k in ("id", "title", "status", "settledAt", "archivedAt", "lineage"))
        for t in body["threads"])
    if not ok:
        die(1, "the thread list lacks keys this script reads. " + NEWER)
    return body


def why_not(t, live_kids, busy, by_id):
    """'' for an idle thread, else the reason it is not settled."""
    for k in ("settledAt", "archivedAt", "deletedAt"):
        if t.get(k):
            return k[:-2]
    if t["status"] in LIVE or t.get("activityRunStatus") in LIVE:
        return "run %s" % (t.get("activityRunStatus") or t["status"])
    if t.get("pendingRuntimeRequest"):
        return "waiting on an approval or question"
    if t["id"] in live_kids:
        return "sub-agent still running (listed in its parent's pendingBackgroundTasks)"
    if t["id"] in busy:
        return "its own sub-agent is still running (pendingBackgroundTasks)"
    if (t.get("lineage") or {}).get("relationshipToParent") == "subagent":
        # a running parent does not list its working sub-agents yet (the list fills when its run
        # completes), so a live parent protects them; a parent missing from the list: quiet check only
        par = by_id.get((t.get("lineage") or {}).get("parentThreadId"))
        if par and (par["status"] in LIVE or par.get("activityRunStatus") in LIVE):
            return "its parent's run is live (sub-agents are unlisted while it runs)"
        try:
            age = time.time() - datetime.datetime.fromisoformat(str(t.get("updatedAt")).replace("Z", "+00:00")).timestamp()
        except ValueError:
            return "sub-agent without a readable updatedAt"
        if age < QUIET_S:
            return "sub-agent active in the last %d s" % QUIET_S
    return ""


# --- a minimal WebSocket client (RFC 6455): text frames only, which is all Effect-RPC JSON uses ---

def ws_open(base, tok):
    u = urllib.parse.urlsplit(base)
    try:
        s = socket.create_connection((u.hostname, u.port or (443 if u.scheme == "https" else 80)), timeout=30)
        if u.scheme == "https":
            s = ssl.create_default_context().wrap_socket(s, server_hostname=u.hostname)
        key = base64.b64encode(os.urandom(16)).decode()
        s.sendall(("GET %s/ws?orchestrationProtocol=2 HTTP/1.1\r\nHost: %s\r\nUpgrade: websocket\r\n"
                   "Connection: Upgrade\r\nSec-WebSocket-Key: %s\r\nSec-WebSocket-Version: 13\r\n"
                   "Authorization: Bearer %s\r\n\r\n" % (u.path.rstrip("/"), u.netloc, key, tok)).encode())
        f = s.makefile("rb")
        status, hdrs = f.readline().decode("latin-1").split(), {}
        while (line := f.readline().decode("latin-1").strip()):
            k, _, v = line.partition(":")
            hdrs[k.strip().lower()] = v.strip()
    except OSError as e:
        die(1, "T3 Code does not answer at %s (%s)" % (base, e))
    if len(status) < 2 or status[1] != "101":
        code = status[1] if len(status) > 1 else "?"
        if code in ("401", "403"):
            die(2, "T3 Code rejects the token on the WebSocket (HTTP %s)" % code)
        die(1, "the WebSocket upgrade answered HTTP %s. %s" % (code, NEWER))
    want = base64.b64encode(hashlib.sha1((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode()).digest()).decode()
    if hdrs.get("sec-websocket-accept") != want:
        die(1, "the WebSocket upgrade has a wrong Sec-WebSocket-Accept. " + NEWER)
    return s, f


def ws_send(s, payload, op=0x1):
    n, mask = len(payload), os.urandom(4)
    head = bytes([0x80 | op]) + (bytes([0x80 | n]) if n < 126 else bytes([0xFE]) + n.to_bytes(2, "big")
                                 if n < 65536 else bytes([0xFF]) + n.to_bytes(8, "big"))
    s.sendall(head + mask + bytes(b ^ mask[i % 4] for i, b in enumerate(payload)))


def ws_recv(s, f):
    """The next whole text message as a str; answers pings; ConnectionError on close or EOF."""
    buf = b""
    while True:
        h = f.read(2)
        if len(h) < 2:
            raise ConnectionError("connection closed")
        op, n = h[0] & 0x0F, h[1] & 0x7F
        n = int.from_bytes(f.read(2 if n == 126 else 8), "big") if n >= 126 else n
        mask = f.read(4) if h[1] & 0x80 else b""
        data = f.read(n)
        if mask:
            data = bytes(b ^ mask[i % 4] for i, b in enumerate(data))
        if op == 0x8:
            raise ConnectionError("server closed the WebSocket")
        if op == 0x9:
            ws_send(s, data, 0xA)
        elif op in (0x0, 0x1):
            buf += data
            if h[0] & 0x80:
                return buf.decode("utf-8")


def rpc(s, f, rid, method, payload):
    """One Effect-RPC call: ('ok', value) or ('fail', message). Protocol trouble exits 1."""
    ws_send(s, json.dumps({"_tag": "Request", "id": str(rid), "tag": method, "payload": payload,
                           "headers": []}).encode())
    while True:
        try:
            m = json.loads(ws_recv(s, f))
        except (OSError, ConnectionError, ValueError) as e:
            die(1, "no RPC answer from T3 Code (%s). %s" % (e, NEWER))
        if not isinstance(m, dict):
            continue
        if m.get("_tag") == "Ping":
            ws_send(s, b'{"_tag":"Pong"}')
        elif m.get("_tag") == "Defect":
            die(1, "T3 Code rejected the RPC frame (%s). %s" % (str(m.get("defect"))[:200], NEWER))
        elif m.get("_tag") == "Exit" and str(m.get("requestId")) == str(rid):
            ex = m.get("exit") or {}
            if ex.get("_tag") == "Success":
                return "ok", ex.get("value")
            if ex.get("_tag") == "Failure":
                return "fail", message(ex.get("cause"))
            die(1, "an RPC answer this script does not know: %s. %s" % (json.dumps(m)[:200], NEWER))


def message(cause):
    """The first `message` in an Effect Cause tree; else the cause itself, cut."""
    stack = [cause]
    while stack:
        c = stack.pop(0)
        if isinstance(c, dict):
            if isinstance(c.get("message"), str):
                return c["message"]
            stack += list(c.values())
        elif isinstance(c, list):
            stack += c
    return json.dumps(cause)[:200]


def main(argv):
    apply = "--apply" in argv
    args = [a for a in argv if a != "--apply"]
    if args[:1] == ["--children-of"]:
        if len(args) != 2 or not args[1] or args[1].startswith("-"):
            die(2, USAGE)
        parent = args[1]
    elif args and not any(a.startswith("-") or not a for a in args):
        parent = None
    else:
        die(2, USAGE)
    cfg = config()
    base = cfg.get("t3Url") if isinstance(cfg.get("t3Url"), str) and cfg.get("t3Url") else \
        "http://127.0.0.1:%s" % (os.environ.get("T3CODE_PORT") or "8470")
    base = base.rstrip("/")
    tok = token(cfg)
    body = shell(base, tok)
    rows = {t["id"]: t for t in body["threads"]}
    live_kids = {k.get("childThreadId") for t in body["threads"] for k in (t.get("pendingBackgroundTasks") or [])
                 if isinstance(k, dict)}
    busy = {t["id"] for t in body["threads"] if t.get("pendingBackgroundTasks")} | {
        (t.get("lineage") or {}).get("parentThreadId") for t in body["threads"] if t["id"] in live_kids}
    archived = {t.get("id") for t in body.get("archivedThreads") or [] if isinstance(t, dict)}
    refused, todo, skipped = [], [], []   # refused: (id, reason), never sent to the server
    if parent:
        if parent not in rows and parent not in archived:
            die(2, "no thread %s in T3 Code" % parent)
        for t in body["threads"]:
            if (t.get("lineage") or {}).get("parentThreadId") == parent and \
                    (t.get("lineage") or {}).get("relationshipToParent") == "subagent":
                w = why_not(t, live_kids, busy, rows)
                if not w:
                    todo.append(t)
                elif w not in ("settled", "archived", "deleted"):   # those are done, not skipped
                    skipped.append((t["id"], w))
    else:
        for tid in dict.fromkeys(args):
            w = ("archived" if tid in archived else "no such thread") if tid not in rows else why_not(rows[tid], live_kids, busy, rows)
            (refused.append((tid, "not idle: " + w)) if w else todo.append(rows[tid]))
    if not apply:
        for t in todo:
            print("%s  %s  %s" % (t["id"], t["status"], " ".join(str(t["title"] or "untitled").split())))
        for tid, w in skipped:
            print("skipped %s: %s" % (tid, w))
        for tid, w in refused:
            print("REFUSED %s: %s" % (tid, w))
        print("%d would be settled; add --apply to settle %s." % (len(todo), "it" if len(todo) == 1 else "them"))
        return 1 if refused else 0
    for tid, w in refused:
        print("REFUSED %s: %s" % (tid, w))
    if todo:
        s, f = ws_open(base, tok)
        for i, t in enumerate(todo, 1):
            kind, val = rpc(s, f, i, "orchestration.dispatchCommand",
                            {"type": "thread.settle", "commandId": str(uuid.uuid4()), "threadId": t["id"]})
            if kind == "ok":
                print("settled " + t["id"])
            else:
                refused.append((t["id"], val))
                print("REFUSED %s: %s" % (t["id"], val))
        try:
            ws_send(s, b"\x03\xe8", 0x8)   # close 1000; ponytail: no wait for the server's close echo
            s.close()
        except OSError:
            pass
    if not todo and not refused:
        print("nothing to settle")
    return 1 if refused else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
