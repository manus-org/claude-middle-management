#!/usr/bin/env python3
"""t3-inbox.py - quiet worker reports into a T3 coordinator (README "Quiet reports", 0.15.0).

Consumers: hooks/t3-report.sh (`deliver` at a worker's turn end, `inject` at the coordinator's own
  Stop), hooks/t3-inbox.sh (`inject` on PostToolUse and UserPromptSubmit), scripts/t3-watch.py
  (imports tick(), copy set middle-management-t3watch), tests/t3-inbox.sh, tests/t3-watch.sh.
  Calls t3-wake.sh beside it (the one sender: --digest, --thread); imports scope.py and
  peer-state.py beside it. Writes <marker dir>/t3-inbox/, <cfg>/state/t3-inbox.tick and the lines of
  <cfg>/state/t3-report/{inbox.log,failures.log}. Reads only sessionId from the sidecar, never its
  reportUrl.

Usage: t3-inbox.py deliver <marker dir> <important|status> <from> <file with the report>
         env MM_SESSION_ID = the worker's session, MM_SCOPE_CWD (handed on to t3-wake.sh)
         exit 0 queued or delivered · 3 no sidecar · 4 not delivered: the caller's own report was
         taken back out of the inbox, the caller tells its session to send it itself
       t3-inbox.py inject   the hook input on stdin (PostToolUse, UserPromptSubmit or Stop)

With config quietReports.enabled (hooks/t3-report.sh decides), a worker's report is one item file
<marker dir>/t3-inbox/<ns>-<sid8>-<pid>.json, 0600, text cut at 4000 chars (t3-wake.sh's cap). Then,
under <inbox>/.lock (held for list + rename only, the POST runs outside it), a wake goes out only
for an IMPORTANT item (t3-report.sh's marker regex: READY, LIVE, BLOCKED, FERTIG, question, ...);
a status item never wakes, in no state (coordinator 2026-11-02), it waits for the coordinator's
next tool call, turn start or turn end, or rides along in the next digest wake:
  the coordinator is usage-limited (t3-watch.py's <cfg>/state/t3-watch/<scope>.json, checked
    < 30 min ago, names its thread in limit.runs)               no wake: held until the limit is over
  a wake went out < 120 s ago          no wake: its turn's hooks take the rest
  the oldest important item >= fallbackMin (default 20) old   wake (never lost)
  coordinator asleep (no live registry entry)                 wake
  live entry without a status field (older CLI)               wake, as before quiet mode
  watcher stamp t3-inbox.tick older than 30 min (no fallback) wake
  idle, the last wake >= debounceMin (default 10) ago         wake; busy: no wake
One wake = t3-wake.sh --digest with every pending item that fits into 4000 chars whole, oldest
first; the rest stays and is handed in by the woken turn's hooks. Items in the digest are claimed by
rename (<item>.claimed.<pid>), deleted on 202 and put back otherwise. A failed wake started by a
worker takes that worker's own item out again (exit 4: it sends it itself) and writes one
failures.log line; the watcher's retries write one line per failure episode (<inbox>/.failing).
inject: only in the session the sidecar names, never in a sub-agent (agent_id), never into a
"Keepalive" prompt (answered with exactly "OK"; its Stop takes them); claims what it
prints (8000 chars per call, at least one item), deletes it after printing, and drops items older
than 24 h (one failures.log line each, so the watcher tells the user) and items that session sent
itself before it held the seat. Reads <cfg>/state/t3-watch/<scope>.json (t3-watch.py). Env: T3W_NOW
(test seam).
"""
import contextlib, datetime, glob, importlib.util, json, os, re, subprocess, sys, tempfile, time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import scope  # noqa: E402  (beside this file)

STATE = os.path.join(scope.CFG, "state")
RDIR = os.path.join(STATE, "t3-report")
TICK = os.path.join(STATE, "t3-inbox.tick")
NOW = float(os.environ.get("T3W_NOW") or time.time())
CAP_ITEM, CAP_WAKE, CAP_INJECT = 4000, 4000, 8000
WAKING_S, CLAIM_S, TTL_S, TICK_STALE_S = 120, 300, 24 * 3600, 30 * 60
# Directly under every head that hands worker reports to the coordinator. t3-wake.sh's single report
# carries the same text (FOR_COORDINATOR there); tests/t3-inbox.sh and tests/t3-watch.sh pin both.
# The "In a turn a worker report or a wake started" qualifier keeps it from contradicting HEAD_INJECT's
# last sentence, which reaches the coordinator inside a turn its user started as well.
FOR_COORDINATOR = ("For the coordinator, not for your user: take these reports in and book them. In a turn a worker "
                   "report or a wake started, write to your user only what matters to them: nothing if nothing does, "
                   "one short line if something is new, never an earlier answer again.")
HEAD_WAKE = "Worker reports (quiet), %d waiting, oldest first:\n" + FOR_COORDINATOR
TAIL_WAKE = "(%d more arrive as hook context in this turn)"
HEAD_INJECT = ("Worker reports (quiet): %d arrived without a turn of their own, oldest first.\n" + FOR_COORDINATOR +
               "\nHandle them in the turn you are in; do not answer each one with a chat message of its own. Only if "
               "your user started this turn: its last text is the full answer to them again, the new point added, "
               "never a one-line addendum.")
TAIL_INJECT = "(%d more follow with your next tool call or turn)"


def settings():
    """(enabled, fallback s, debounce s) from the config; a wrong shape reads as the default."""
    q = scope.config().get("quietReports")
    q = q if isinstance(q, dict) else {}

    def minutes(k, d):
        v = q.get(k)
        return (v if isinstance(v, (int, float)) and not isinstance(v, bool) and v > 0 else d) * 60
    return q.get("enabled") is True, minutes("fallbackMin", 20), minutes("debounceMin", 10)


def num(v, d=0.0):
    return float(v) if isinstance(v, (int, float)) and not isinstance(v, bool) else d


def stamp(path):
    try:
        with open(path, encoding="utf-8") as f:
            return float(f.read().strip() or 0)
    except (OSError, ValueError):
        return 0.0


def put(path, text):
    tmp = "%s.%d.tmp" % (path, os.getpid())
    with open(tmp, "w", encoding="utf-8") as f:
        f.write(text)
    os.replace(tmp, path)


def now_iso():
    return datetime.datetime.now().astimezone().isoformat(timespec="seconds")   # date -Is, like t3-wake.sh


def ilog(event, it, note=""):
    """One inbox.log line per item event; never the text, never a URL."""
    os.makedirs(RDIR, exist_ok=True)
    with open(os.path.join(RDIR, "inbox.log"), "a", encoding="utf-8") as f:
        f.write("\t".join([now_iso(), event, str(it.get("from") or "?"), str(it.get("session") or "-"),
                           str(it.get("name") or "?"), note]).rstrip("\t") + "\n")


def failure(from_, sid, thread, reason):
    """A line in failures.log, which t3-watch.py sends to the user (t3-wake.sh's 5 columns)."""
    os.makedirs(RDIR, exist_ok=True)
    with open(os.path.join(RDIR, "failures.log"), "a", encoding="utf-8") as f:
        f.write("%s\t%s\t%s\t%s\t%s\n" % (now_iso(), from_, sid or "-", thread or "unknown", reason))


def coord_sid(sdir):
    """The sessionId the scope's sidecar names, or None (no sidecar). Nothing else is kept."""
    try:
        with open(os.path.join(sdir, "orchestrator.t3.json"), encoding="utf-8") as f:
            v = json.load(f).get("sessionId")
    except (OSError, ValueError, AttributeError):
        return None
    return v if isinstance(v, str) and v else ""


def peer_state():
    spec = importlib.util.spec_from_file_location("peer_state", os.path.join(HERE, "peer-state.py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def coordinator(sid):
    """asleep | busy | idle | unknown (a live entry without status). Liveness = peer-state.py's rule."""
    ps = peer_state()
    e = ps.registry()[0].get(sid) if sid else None
    if not (e and e.get("kind") == "interactive" and ps.is_live(e.get("pid"), e.get("procStart"))):
        return "asleep"
    return e.get("status") if e.get("status") in ("busy", "idle") else "unknown"


@contextlib.contextmanager
def locked(inbox, wait):
    """flock on <inbox>/.lock, at most `wait` s; TimeoutError after that (the item stays queued)."""
    import fcntl
    fd = os.open(os.path.join(inbox, ".lock"), os.O_CREAT | os.O_RDWR, 0o600)
    try:
        end = time.monotonic() + wait
        while True:
            try:
                fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except BlockingIOError:
                if time.monotonic() >= end:
                    raise TimeoutError(inbox)
                time.sleep(0.05)
        yield
    finally:
        os.close(fd)


def pending(inbox, drop=True):
    """[(path, item)] of the unclaimed items, oldest first. An unreadable one (never written by
    deliver: tmp + rename) would block nothing but sit forever, so it is dropped (logged)."""
    out = []
    for p in glob.glob(os.path.join(inbox, "*.json")):
        try:
            with open(p, encoding="utf-8") as f:
                it = json.load(f)
            if not isinstance(it, dict):
                raise ValueError
        except (OSError, ValueError):
            if drop:
                with contextlib.suppress(OSError):
                    os.unlink(p)
                ilog("dropped", {"name": os.path.basename(p)}, "unreadable")
            continue
        it["name"] = os.path.basename(p)
        out.append((p, it))
    return sorted(out, key=lambda x: (num(x[1].get("at"), NOW), x[1]["name"]))


def housekeep(inbox):
    """Under the lock. A claim older than 5 min goes back (its consumer died between claim and
    delete: sent twice rather than never); an item older than 24 h is dropped with a log line
    (its coordinator released the seat, or never took a turn)."""
    for p in glob.glob(os.path.join(inbox, "*.json.claimed.*")):
        with contextlib.suppress(OSError):
            if NOW - os.path.getmtime(p) > CLAIM_S:
                os.replace(p, p.split(".claimed.")[0])
    keep = []
    for p, it in pending(inbox):
        if NOW - num(it.get("at"), NOW) > TTL_S:
            with contextlib.suppress(OSError):
                os.unlink(p)
            ilog("dropped", it, "older than 24 h")
            # loud: a report held through a long usage limit must not vanish into inbox.log alone
            failure(it.get("from") or "?", it.get("session"), it.get("thread"),
                    "dropped from the quiet-report inbox after 24 h undelivered")
        else:
            keep.append((p, it))
    return keep


def claim(items):
    """Rename each to <path>.claimed.<pid>; returns [(claimed path, item)] of what this process won."""
    out = []
    for p, it in items:
        c = "%s.claimed.%d" % (p, os.getpid())
        try:
            os.replace(p, c)
            os.utime(c, (NOW, NOW))     # the 5-min clock of housekeep() starts now
        except OSError:
            continue
        out.append((c, it))
    return out


def unclaim(claimed):
    for c, _ in claimed:
        with contextlib.suppress(OSError):
            os.replace(c, c.split(".claimed.")[0])


def entry(it):
    at = time.strftime("%H:%M", time.localtime(num(it.get("at"), NOW)))
    return "### Report from %s (thread %s, %s)\n%s" % (it.get("from") or "?", it.get("thread") or "unknown",
                                                        at, it.get("text") or "")


def pack(items, cap, head, tail):
    """(taken, text): whole items, oldest first, while the text stays within cap chars."""
    n = len(items)
    body, taken = [head % n], []
    size = len(body[0])
    for p, it in items:
        e, left = entry(it), n - len(taken) - 1
        if size + 1 + len(e) + (1 + len(tail % left) if left else 0) > cap:
            break
        taken.append((p, it))
        body.append(e)
        size += 1 + len(e)
    if len(taken) < n:
        body.append(tail % (n - len(taken)))
    return taken, "\n".join(body)


def limited(sdir):
    """True while t3-watch.py's usage-limit episode of this scope names the coordinator's thread
    (<cfg>/state/t3-watch/<scope>.json: the sidecar's threadId is a key of limit.runs). A wake then
    only starts a run that fails at once, so the items wait; the watcher's tick that sees the limit
    over (same pass, after its check) sends the digest. Fail open: a missing or unreadable file, one
    the watcher has not checked for 30 min (T3 API down, watcher stopped) or a sidecar without
    threadId reads False, and the wake goes out as before."""
    name = "default" if os.path.realpath(sdir) == os.path.realpath(STATE) else os.path.basename(sdir)
    try:
        with open(os.path.join(STATE, "t3-watch", name + ".json"), encoding="utf-8") as f:
            st = json.load(f)
        with open(os.path.join(sdir, "orchestrator.t3.json"), encoding="utf-8") as f:
            tid = json.load(f)["threadId"]
        if NOW - num(st.get("checked")) > TICK_STALE_S:
            return False
        return tid.replace(":", "-") in {k.replace(":", "-") for k in st["limit"]["runs"]}
    except (OSError, ValueError, KeyError, TypeError, AttributeError):
        return False


def decide(inbox, sid, items, hold=False):
    """The reason for a wake now, or None. Only an important item ever causes one."""
    imp = [it for _, it in items if it.get("class") == "important"]
    if not imp or hold or limited(os.path.dirname(inbox)):
        return None
    _, fallback, debounce = settings()
    last = stamp(os.path.join(inbox, ".last-wake"))
    if NOW - last < WAKING_S:
        return None
    if NOW - min(num(it.get("at"), NOW) for it in imp) >= fallback:
        return "fallback"
    state = coordinator(sid)
    if state == "asleep":
        return "asleep"
    if state == "unknown":
        return "no status"
    try:
        stale = NOW - os.path.getmtime(TICK) > TICK_STALE_S
    except OSError:
        stale = True
    if stale:
        return "no watcher"
    return "idle" if state == "idle" and NOW - last >= debounce else None


def send(text, from_, env, limit=11):
    """t3-wake.sh --digest; (exit code, reason). Its stderr carries the reason, never the URL."""
    with tempfile.NamedTemporaryFile("w", prefix="t3-inbox.", suffix=".txt", delete=False) as f:
        f.write(text)
    try:
        p = subprocess.run(["bash", os.path.join(HERE, "t3-wake.sh"), from_, "--digest", f.name],
                           env=dict(os.environ, MM_SESSION_ID="", **env), capture_output=True,
                           text=True, timeout=limit)
        rc, err = p.returncode, p.stderr
    except (OSError, subprocess.TimeoutExpired):
        rc, err = 4, "t3-wake.sh did not end within %d s" % limit
    finally:
        os.unlink(f.name)
    m = re.search(r"NOT delivered \((.*)\)", err)
    return rc, (m.group(1) if m else ((err.strip().splitlines() or ["exit %s" % rc])[-1])[:200])


def run(inbox, sid, from_, env, own=None, hold=False, dry=False, label="", start=None):
    """Decide, and send one digest wake when it says so. 0 = nothing to send or 202, 3 = the
    sidecar is gone, 4 = not delivered. own = the caller's item (deliver), taken back on failure.
    start = deliver's time.monotonic() at its start: it must end inside t3-report.sh's 15-s guard,
    else the guard kills it after its item is queued and the session is told "NOT delivered"."""
    if dry:
        items = pending(inbox, drop=False)
        why = decide(inbox, sid, items, hold)
        print("INBOX   %s: %d pending (%d important), %s" % (
            label, len(items), sum(it.get("class") == "important" for _, it in items),
            "would wake (%s)" % why if why else
            "held (coordinator usage-limited)" if limited(os.path.dirname(inbox)) else "no wake"))
        return 0
    try:
        with locked(inbox, 3 if start is None else 2):
            items = housekeep(inbox)
            why = decide(inbox, sid, items, hold)
            if not why:
                return 0
            taken, text = pack(items, CAP_WAKE, HEAD_WAKE, TAIL_WAKE)
            claimed = claim(taken)
            prev = stamp(os.path.join(inbox, ".last-wake"))
            put(os.path.join(inbox, ".last-wake"), "%d\n" % NOW)   # a second deliver sees it under way
    except TimeoutError:
        return 0        # ponytail: the lock holder decides now; the next report or the tick follows up
    rc, reason = send(text, from_, env, 11 if start is None else max(2, 13 - (time.monotonic() - start)))
    if rc == 0:
        for c, it in claimed:
            with contextlib.suppress(OSError):
                os.unlink(c)
            ilog("woken", it, why)
        with contextlib.suppress(OSError):
            os.unlink(os.path.join(inbox, ".failing"))
        return 0
    # ponytail: put back without the lock: renames are atomic, and the "under way" mark kept every
    # other wake out meanwhile, so the old .last-wake is still the right one.
    put(os.path.join(inbox, ".last-wake"), "%d\n" % prev)
    if rc == 3:
        unclaim(claimed)
        return 3        # the seat was released meanwhile: the items wait for the next claim (24 h)
    unclaim([(c, it) for c, it in claimed if own is None or c.split(".claimed.")[0] != own[0]])
    if own is not None:
        for p in (own[0], "%s.claimed.%d" % (own[0], os.getpid())):
            with contextlib.suppress(OSError):
                os.unlink(p)
    queued = len(glob.glob(os.path.join(inbox, "*.json")))
    if own is not None:
        ilog("handed back", own[1], reason)
        failure(from_, own[1].get("session"), own[1].get("thread"),
                "%s (quiet digest wake; this report went back to its session, %d other report(s) stay queued)"
                % (reason, queued))
    elif not os.path.exists(os.path.join(inbox, ".failing")):
        failure(from_, "", "", "digest wake failed (%s), %d report(s) stay queued in the inbox; "
                "the watcher retries every 10 min" % (reason, queued))
    put(os.path.join(inbox, ".failing"), "%d\n" % NOW)
    return 4


def deliver(sdir, cls, from_, path):
    start = time.monotonic()
    sid = coord_sid(sdir)
    if sid is None:
        return 3
    me = os.environ.get("MM_SESSION_ID", "")
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            text = f.read().rstrip("\n")
        thread = subprocess.run(["bash", os.path.join(HERE, "t3-wake.sh"), "--thread"], capture_output=True,
                                text=True, timeout=5).stdout.strip() or "unknown"
    except (OSError, subprocess.TimeoutExpired):
        text, thread = None, "unknown"
    if text is not None and len(text) > CAP_ITEM:
        text = text[:CAP_ITEM] + "\n[cut at %d of %d chars]" % (CAP_ITEM, len(text))
    it = {"from": from_, "session": me, "thread": thread,
          "class": cls if cls in ("important", "status") else "important", "text": text, "at": NOW}
    inbox = os.path.join(sdir, "t3-inbox")
    try:
        if text is None:
            raise OSError(path)
        os.makedirs(inbox, mode=0o700, exist_ok=True)
        name = "%020d-%s-%d.json" % (time.time_ns(), re.sub(r"[^A-Za-z0-9-]", "", me)[:8] or "none", os.getpid())
        tmp = os.path.join(inbox, ".%s.tmp" % name)
        with os.fdopen(os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600), "w", encoding="utf-8") as f:
            json.dump(it, f)
        own = (os.path.join(inbox, name), dict(it, name=name))
        os.replace(tmp, own[0])
    except OSError:
        # The inbox cannot take it: today's path, one wrapped report, so nothing is lost.
        try:
            return subprocess.run(["bash", os.path.join(HERE, "t3-wake.sh"), from_, path],
                                  timeout=max(2, 13 - (time.monotonic() - start)),
                                  stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode
        except (OSError, subprocess.TimeoutExpired):
            return 4
    ilog("queued", own[1], it["class"])
    return run(inbox, sid, from_, {}, own=own, start=start)


def tick(name, sdir, dry=False, hold=False):
    """The watcher's step for one scope (t3-watch.py, every 10 min): the fallback, a debounced wake
    whose window has passed, an asleep coordinator, the 24-h drop. hold = the morning claim is
    pending (t3-watch.py morning_pending): no wake into the night coordinator."""
    if not settings()[0]:
        return
    if not dry:
        os.makedirs(STATE, exist_ok=True)
        with open(TICK, "a"):
            os.utime(TICK, (NOW, NOW))      # deliver: a fresh stamp = the fallback runs
    inbox = os.path.join(sdir, "t3-inbox")
    if not os.path.isdir(inbox):
        return
    sid = coord_sid(sdir)
    if sid is None:
        if not dry:
            with contextlib.suppress(TimeoutError), locked(inbox, 3):
                housekeep(inbox)
        return
    run(inbox, sid, "t3-watch", {"MM_SCOPE": name}, hold=hold, dry=dry, label="scope " + name)


def inject():
    try:
        inp = json.load(sys.stdin)
    except ValueError:
        return 0
    if not isinstance(inp, dict) or inp.get("agent_id"):
        return 0                # a sub-agent's tool call (F1): its context is not the coordinator's
    sid, event = inp.get("session_id"), inp.get("hook_event_name")
    if not (isinstance(sid, str) and sid) or event not in ("PostToolUse", "UserPromptSubmit", "Stop"):
        return 0
    if event == "Stop" and inp.get("stop_hook_active"):
        return 0                # a continuation: never a second block (no loop)
    if event == "UserPromptSubmit" and str(inp.get("prompt") or "").strip() == "Keepalive":
        return 0                # answered with exactly "OK": the Stop drain hands them in right after
    for sdir in [STATE] + sorted(glob.glob(os.path.join(STATE, "scopes", "*"))):
        inbox = os.path.join(sdir, "t3-inbox")
        if not glob.glob(os.path.join(inbox, "*.json")) or coord_sid(sdir) != sid:
            continue
        try:
            with locked(inbox, 2):
                items = []
                for p, it in housekeep(inbox):
                    if it.get("session") == sid:    # sent by this session before it held the seat
                        with contextlib.suppress(OSError):
                            os.unlink(p)
                        ilog("dropped", it, "own report")
                    else:
                        items.append((p, it))
                if not items:
                    return 0
                taken, text = pack(items, CAP_INJECT, HEAD_INJECT, TAIL_INJECT)
                claimed = claim(taken)
        except TimeoutError:
            return 0            # a concurrent consumer holds it; the next call takes the rest
        if not claimed:
            return 0
        out = {"decision": "block", "reason": text} if event == "Stop" else \
            {"hookSpecificOutput": {"hookEventName": event, "additionalContext": text}}
        sys.stdout.write(json.dumps(out) + "\n")
        sys.stdout.flush()      # printed first, deleted after: a crash in between sends it twice, never 0 times
        for c, it in claimed:
            with contextlib.suppress(OSError):
                os.unlink(c)
            ilog("injected", it, event)
        return 0                # ponytail: one session holds one seat, so the first match is the only one
    return 0


def main(argv):
    if argv[:1] == ["deliver"] and len(argv) == 5:
        return deliver(*argv[1:])
    if argv == ["inject"]:
        return inject()
    print(__doc__.split("\n\n")[2], file=sys.stderr)
    return 64


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
