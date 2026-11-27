#!/usr/bin/env python3
"""t3-inbox.py - quiet worker reports and the user's own answers into a T3 coordinator (README
"Quiet reports", 0.15.0; class user and the fresh coordinator, 0.20.1).

Consumers: hooks/t3-report.sh (`deliver` at a worker's turn end, `inject` at the coordinator's own
  Stop), hooks/t3-inbox.sh (`inject` on PostToolUse and UserPromptSubmit), scripts/t3-watch.py
  (imports tick(), receipts(), fresh_needed(), held(), morning_pending(), posted_at(),
  revive_allowed(), coord_sid(), waiting(); copy set middle-management-t3watch), a team's answer
  channel outside the plugin (`deliver ... user`, MM_SESSION_ID=""), tests/t3-inbox.sh,
  tests/t3-watch.sh. Calls t3-wake.sh beside it (the one sender: --digest, --thread) and
  peer-state.py beside it (--session-id --json; also imported: registry, is_live, transcript_for);
  imports scope.py. Writes <marker dir>/t3-inbox/, <cfg>/state/t3-inbox.tick and the lines of
  <cfg>/state/t3-report/{inbox.log,failures.log}. Reads only sessionId and threadId from the
  sidecar, never its reportUrl.

Usage: t3-inbox.py deliver <marker dir> <important|status|user> <from> <file with the text>
         env MM_SESSION_ID = the worker's session ("" for user). The wake goes through <marker dir>'s
         own scope (MM_SCOPE for t3-wake.sh, derived from the dir), never the caller's cwd
         important|status: exit 0 queued or delivered · 3 no sidecar · 4 not delivered: the caller's
         own report was taken back out of the inbox, the caller tells its session to send it itself
         user (a sender that is no session, the text is the user's own answer): exit 0 delivered (a
         wake got 202, a wake is under way, or the coordinator is busy and its hooks hand it in) ·
         9 queued, the watcher acts on it (stderr "t3-inbox: queued: <reason>") · 4 queued, but no
         watcher ran for 30 min, or the inbox could not take it (stderr "t3-inbox: NOT delivered
         (<reason>)") · 64 usage
       t3-inbox.py inject   the hook input on stdin (PostToolUse, UserPromptSubmit or Stop)

With config quietReports.enabled (hooks/t3-report.sh decides), a worker's report is one item file
<marker dir>/t3-inbox/<ns>-<sid8>-<pid>.json, 0600, text cut at 4000 chars (t3-wake.sh's cap). Then,
under <inbox>/.lock (held for list + rename only, the POST runs outside it), a wake goes out only
for an IMPORTANT item (t3-report.sh's marker regex: READY, LIVE, BLOCKED, FERTIG, question, ...)
or a USER item; a status item never wakes, in no state (coordinator 2026-11-02), it waits for the
coordinator's next tool call, turn start or turn end, or rides along in the next digest wake:
  the morning claim is pending (t3-watch.py morning_pending)  no wake
  the coordinator is usage-limited (t3-watch.py's <cfg>/state/t3-watch/<scope>.json, checked
    < 30 min ago, names its thread in limit.runs, its reset time in limit.resets not yet passed)
                                                                no wake: held until the limit is over
  config reviveTakeover allowed for this seat (morningRoot's scope, the default one without
    scopes; every other scope wakes as before) and the seat needs a fresh coordinator
    (fresh_needed: no seat, the holder wrapped, or asleep, idle >= MM_STALE_SEAT_MIN (60) and
    context >= handoverWarnTokens; never while a t3-handover is open)
                                                                no wake: t3-watch.py starts one
  a wake went out < 120 s ago          no wake: its turn's hooks take the rest
  USER item: coordinator busy -> no wake (its hooks hand it in); otherwise wake at once
  the oldest important item >= fallbackMin (default 20) old   wake (never lost)
  coordinator asleep (no live registry entry)                 wake
  live entry without a status field (older CLI)               wake, as before quiet mode
  watcher stamp t3-inbox.tick older than 30 min (no fallback) wake
  idle, the last wake >= debounceMin (default 10) ago         wake; busy: no wake
A user item is queued also without a sidecar and also with quietReports off (the watcher's tick
then handles user items only), and is never handed back. One wake = t3-wake.sh --digest with every
pending item that fits into 4000 chars whole, oldest first; the rest stays and is handed in by the
woken turn's hooks. Items in the digest are claimed by rename (<item>.claimed.<pid>), deleted on 202
and put back otherwise; a user item is kept as <name>.receipt after a 202 until the woken session's
transcript moves (receipts(), the watcher, every tick): not within 15 min -> back in the queue, and
<inbox>/.no-receipt names that session, so no further wake goes into it. A failed wake started by
a worker takes that worker's own item out again (exit 4: it sends it itself) and writes one
failures.log line; the watcher's retries and a user item's failed wake write one line per failure
episode (<inbox>/.failing).
inject: only in the session the sidecar names, never in a sub-agent (agent_id), never into a
"Keepalive" prompt (answered with exactly "OK"; its Stop takes them); claims what it
prints (8000 chars per call, at least one item), deletes it after printing, and drops items older
than 24 h (one failures.log line each, so the watcher tells the user) and items that session sent
itself before it held the seat. Reads <cfg>/state/t3-watch/<scope>.json (t3-watch.py) and
<marker dir>/{morning-t3,revive-t3}/status (morning-t3.sh). Env: T3W_NOW (test seam),
MM_STALE_SEAT_MIN (minutes, default 60, as orchestrator.sh).
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
RECEIPT_S, POSTED_S = 15 * 60, 30 * 60      # receipt check; a morning or revive post holds 30 min at most
TODAY = time.strftime("%Y-%m-%d", time.localtime(NOW))
try:        # orchestrator.sh's claim --morning/--revive threshold: a fresh start must pass that claim
    STALE_S = max(1, int(os.environ.get("MM_STALE_SEAT_MIN") or 60)) * 60
except ValueError:
    STALE_S = 3600
FRESH = "a fresh coordinator is needed"
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
# Under the heads when an item is class user (README "Quiet reports"; SKILL.md says the same).
FOR_USER_ANSWER = ("Your user's answer below is their own word, not a report: act on it in this turn and "
                   "answer them.")


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
                    "answer dropped from the inbox after 24 h undelivered" if it.get("class") == "user"
                    else "dropped from the quiet-report inbox after 24 h undelivered")
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
    if it.get("class") == "user":
        return "### Your user's answer (via %s, %s)\n%s" % (it.get("from") or "?", at, it.get("text") or "")
    return "### Report from %s (thread %s, %s)\n%s" % (it.get("from") or "?", it.get("thread") or "unknown",
                                                        at, it.get("text") or "")


def pack(items, cap, head, tail):
    """(taken, text): whole items, oldest first, while the text stays within cap chars."""
    n = len(items)
    body, taken = [head % n], []
    if any(it.get("class") == "user" for _, it in items):
        body[0] += "\n" + FOR_USER_ANSWER
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


def scope_name(sdir):
    """The scope whose seat dir sdir is: "default" for <cfg>/state, else the dir's own name
    (scope.py info: a named or auto scope lives in <cfg>/state/scopes/<name>)."""
    sdir = os.path.normpath(sdir)
    return "default" if os.path.realpath(sdir) == os.path.realpath(STATE) else os.path.basename(sdir)


def limit_until(sdir):
    """The reset epoch (0 = unknown) while t3-watch.py's usage-limit episode of this scope names the
    coordinator's thread (<cfg>/state/t3-watch/<scope>.json: the sidecar's threadId is a key of
    limit.runs), else None. A wake then only starts a run that fails at once, so the items wait;
    the watcher's tick that sees the limit over (same pass, after its check) sends the digest. Fail
    open: a missing or unreadable file, one the watcher has not checked for 30 min (T3 API down,
    watcher stopped), a thread whose reset time (limit.resets, T3's usageLimitResetAt) has passed,
    or a sidecar without threadId reads None, and the wake goes out as before."""
    name = scope_name(sdir)
    try:
        with open(os.path.join(STATE, "t3-watch", name + ".json"), encoding="utf-8") as f:
            st = json.load(f)
        with open(os.path.join(sdir, "orchestrator.t3.json"), encoding="utf-8") as f:
            tid = json.load(f)["threadId"].replace(":", "-")
        if NOW - num(st.get("checked")) > TICK_STALE_S:
            return None
        ep = st["limit"]
        key = next((k for k in ep["runs"] if k.replace(":", "-") == tid), None)
        if key is None:
            return None
        reset = (ep.get("resets") or {}).get(key)
        at = datetime.datetime.fromisoformat(str(reset).replace("Z", "+00:00")).timestamp() if reset else 0
        return None if at and at <= NOW else at
    except (OSError, ValueError, KeyError, TypeError, AttributeError):
        return None


def limited(sdir):
    return limit_until(sdir) is not None


def revive_allowed(sdir):
    """The user's standing word for the daytime takeover (config reviveTakeover, the shape of
    morningTakeover; orchestrator.sh claim --revive checks the same) AND sdir is the seat the
    takeover task serves: morningRoot's scope with scopes, else the default one (its thread runs
    in that T3 project, so its claim can only take that seat). Absent = the revive is off; another
    scope behaves as with the revive off."""
    c = scope.config()
    r = c.get("reviveTakeover")
    if not (isinstance(r, dict) and r.get("allowed") is True and isinstance(r.get("okBy"), str)
            and r["okBy"].strip()):
        return False
    try:
        served = scope.info(scope.of(c.get("morningRoot") or "", scope.scopes(c)), c)[0]
    except (scope.Unknown, ValueError):
        return False
    return os.path.realpath(served) == os.path.realpath(sdir)


def posted_at(sdir, kind):
    """The epoch of the last post of morning-t3.sh (kind "morning-t3" or, with --revive, "revive-t3")
    while its status still says "posted" (the claim turns it into claimed/refused) and the post is
    under 30 min old; else None. A morning post must be today's; a revive post is told by its age
    alone, its date may be yesterday's (hooks/t3-report.sh and t3-watch.py's revive outcome read the
    revive status for 24 h the same way)."""
    try:
        with open(os.path.join(sdir, kind, "status"), encoding="utf-8") as f:
            day, state, at = (f.readline().rstrip("\n").split("\t") + ["", "", ""])[:3]
        at = float(at)
    except (OSError, ValueError):
        return None
    return at if (day == TODAY or kind == "revive-t3") and state == "posted" and NOW - at < POSTED_S else None


def morning_pending(sdir, kind="morning-t3"):
    """True while today's morning thread was started (morning-t3.sh status "posted"; claim --morning
    turns it into "claimed" or "refused"), the post is under 30 min old, and the seat is not bound
    anew yet (the sidecar is older than the post). The sidecar then still names the night
    coordinator, and a wake would make it re-pay its whole context for a seat it is about to lose.
    kind "revive-t3": the same for the daytime takeover (morning-t3.sh --revive, claim --revive) and
    the old coordinator it replaces (t3-watch.py revive_pending).
    ponytail: the window is told by time, not by thread id: any wake in it goes to the user instead."""
    at = posted_at(sdir, kind)
    try:
        return at is not None and os.path.getmtime(os.path.join(sdir, "orchestrator.t3.json")) < at
    except OSError:
        return False


def peer_row(sid):
    """peer-state.py --session-id <sid> --json, its row, or {} (no answer: nothing is fresh-needed)."""
    try:
        p = subprocess.run([sys.executable, os.path.join(HERE, "peer-state.py"), "--session-id", sid, "--json"],
                           capture_output=True, text=True, timeout=8)
        rows = json.loads(p.stdout)
        return rows[0] if isinstance(rows, list) and rows and isinstance(rows[0], dict) else {}
    except (OSError, subprocess.TimeoutExpired, ValueError):
        return {}


def moved_since(sid, at):
    """True when the session's transcript was written after `at` (its thread ran a turn)."""
    t = peer_state().transcript_for(sid) if sid else None
    try:
        return bool(t) and os.path.getmtime(t) > at
    except OSError:
        return False


def missed(sdir, sid):
    """True while <inbox>/.no-receipt names this session and its transcript has not moved since."""
    try:
        with open(os.path.join(sdir, "t3-inbox", ".no-receipt"), encoding="utf-8") as f:
            who, at = (f.read().split() + ["", ""])[:2]
        return bool(sid) and who == sid and not moved_since(sid, float(at))
    except (OSError, ValueError):
        return False


def hours(sec):
    return "%d min" % (sec // 60) if sec < 7200 else "%d h" % (sec // 3600)


def fresh_needed(sdir, sid):
    """Why this seat needs a fresh coordinator instead of a wake, in words for the user, or None.
    No seat (no sidecar, and the marker names nobody live); the sidecar's session asleep and
    wrapped (its closed marker); or asleep, quiet for MM_STALE_SEAT_MIN (the claim --revive check)
    and either over handoverWarnTokens (default 250000, 0 = off) or past a missed receipt. The
    holder is read off disk (peer-state.py), never messaged. None, so the wake goes out as before:
    a sidecar without sessionId (sid ""), and an open t3-handover (the old holder forwards to the
    successor it named; t3-watch.py tells the user when that hangs)."""
    if sid is None:
        try:
            with open(os.path.join(sdir, "orchestrator"), encoding="utf-8") as f:
                holder = f.readline().strip()
        except OSError:
            holder = ""
        return "no coordinator holds the seat" if coordinator(holder) == "asleep" else None
    try:
        with open(os.path.join(sdir, "orchestrator.t3.json"), encoding="utf-8") as f:
            ho = json.load(f).get("handover")
    except (OSError, ValueError, AttributeError):
        ho = None
    if not sid or (isinstance(ho, dict) and ho.get("toThreadId")) or coordinator(sid) != "asleep":
        return None
    r = peer_row(sid)
    if r.get("closed_marker"):
        return "the old one wrapped"
    try:
        idle = NOW - os.path.getmtime(r["transcript"])
    except (KeyError, TypeError, OSError):
        return None
    if idle < STALE_S:
        return None
    if missed(sdir, sid):
        return "the old one did not react to your answer, idle %s" % hours(idle)
    warn = scope.config().get("handoverWarnTokens", 250000)
    ctx = r.get("ctx_tokens")
    if isinstance(warn, (int, float)) and warn > 0 and isinstance(ctx, int) and ctx >= warn:
        return "old one: %dk tokens, idle %s" % (ctx // 1000, hours(idle))
    return None


def held(sdir, sid, hold=False):
    """Why an important or user item waits now instead of a wake (the queued reason), or None."""
    if hold:
        return "morning coordinator pending"
    u = limit_until(sdir)
    if u is not None:
        return "usage limit until " + (time.strftime("%H:%M", time.localtime(u)) if u else "the reset")
    if sid is None or missed(sdir, sid) or (revive_allowed(sdir) and fresh_needed(sdir, sid)):
        return FRESH
    return None


def waiting(sdir):
    """The classes of the items queued in this seat's inbox."""
    return {it.get("class") for _, it in pending(os.path.join(sdir, "t3-inbox"), drop=False)}


def write_item(path, it):
    """An item file, 0600 from the first byte, tmp + rename."""
    tmp = os.path.join(os.path.dirname(path), ".%s.%d.tmp" % (os.path.basename(path), os.getpid()))
    with os.fdopen(os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600), "w", encoding="utf-8") as f:
        json.dump({k: v for k, v in it.items() if k != "name"}, f)
    os.replace(tmp, path)


def receipts(sdir):
    """The watcher's receipt check, every tick: a user item woken with 202 waits as <name>.receipt
    until the woken session's transcript moved after the wake (then it is deleted). Not within
    15 min (a settled, snoozed or limited thread may take the 202 and run nothing): the item goes
    back into the queue and <inbox>/.no-receipt names that session. Returns those sessions."""
    inbox, out = os.path.join(sdir, "t3-inbox"), []
    if not glob.glob(os.path.join(inbox, "*.receipt")):
        return out
    with contextlib.suppress(TimeoutError), locked(inbox, 3):
        for p in sorted(glob.glob(os.path.join(inbox, "*.receipt"))):
            try:
                with open(p, encoding="utf-8") as f:
                    it = json.load(f)
                sid, at = str(it.pop("wokenSession", "")), num(it.pop("woken", 0))
            except (OSError, ValueError, AttributeError):
                continue
            it["name"] = os.path.basename(p)
            if moved_since(sid, at):
                os.unlink(p)
                ilog("received", it)
            elif NOW - at >= RECEIPT_S:
                write_item(p[:-len(".receipt")] + ".json", it)
                os.unlink(p)
                ilog("no receipt", it, sid)
                put(os.path.join(inbox, ".no-receipt"), "%s %d\n" % (sid, NOW))
                out.append(sid)
    return out


def decide(inbox, sid, items, hold=False):
    """(the reason for a wake now or None, the reason it is queued or None). Only an important item
    (with quietReports on) or a user item ever causes a wake."""
    on = settings()[0]
    imp = [it for _, it in items if it.get("class") == "important" and on]
    usr = [it for _, it in items if it.get("class") == "user"]
    if not (imp or usr):
        return None, None
    q = held(os.path.dirname(inbox), sid, hold)
    if q:
        return None, q
    _, fallback, debounce = settings()
    last = stamp(os.path.join(inbox, ".last-wake"))
    if NOW - last < WAKING_S:
        return None, None
    if imp and NOW - min(num(it.get("at"), NOW) for it in imp) >= fallback:
        return "fallback", None     # in every state, also while a user item waits on a busy one
    state = coordinator(sid)
    if usr:             # the user waits for it: at once, no debounce, no fallback wait
        return (None, None) if state == "busy" else ("user", None)
    if state == "asleep":
        return "asleep", None
    if state == "unknown":
        return "no status", None
    try:
        stale = NOW - os.path.getmtime(TICK) > TICK_STALE_S
    except OSError:
        stale = True
    if stale:
        return "no watcher", None
    return ("idle" if state == "idle" and NOW - last >= debounce else None), None


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
    """Decide, and send one digest wake when it says so. Returns (rc, queued reason or None):
    rc 0 = nothing to send, held (the reason says why) or 202, 3 = the sidecar is gone, 4 = not
    delivered. own = the caller's item (deliver), taken back on failure unless it is a user item.
    start = deliver's time.monotonic() at its start: it must end inside t3-report.sh's 15-s guard,
    else the guard kills it after its item is queued and the session is told "NOT delivered"."""
    if dry:
        items = pending(inbox, drop=False)
        why, q = decide(inbox, sid, items, hold)
        nu = sum(it.get("class") == "user" for _, it in items)
        print("INBOX   %s: %d pending (%d important%s), %s" % (
            label, len(items), sum(it.get("class") == "important" for _, it in items),
            ", %d user" % nu if nu else "",
            "would wake (%s)" % why if why else "held (%s)" % q if q else "no wake"))
        return 0, q
    try:
        with locked(inbox, 3 if start is None else 2):
            items = housekeep(inbox)
            why, q = decide(inbox, sid, items, hold)
            if not why:
                return 0, q
            taken, text = pack(items, CAP_WAKE, HEAD_WAKE, TAIL_WAKE)
            claimed = claim(taken)
            prev = stamp(os.path.join(inbox, ".last-wake"))
            put(os.path.join(inbox, ".last-wake"), "%d\n" % NOW)   # a second deliver sees it under way
    except TimeoutError:
        # ponytail: the lock holder decides now; the next report or the tick follows up
        return 0, "wake failed, the watcher retries"
    rc, reason = send(text, from_, env, 11 if start is None else max(2, 13 - (time.monotonic() - start)))
    if rc == 0:
        for c, it in claimed:
            with contextlib.suppress(OSError):
                if it.get("class") == "user" and sid:   # kept until the woken session moves (receipts());
                    # ponytail: a sidecar without sessionId has no transcript to confirm: deleted as before
                    write_item(c.split(".claimed.")[0][:-len(".json")] + ".receipt",
                               dict(it, woken=NOW, wokenSession=sid))
                os.unlink(c)
            ilog("woken", it, why)
        with contextlib.suppress(OSError):
            os.unlink(os.path.join(inbox, ".failing"))
        return 0, None
    # ponytail: put back without the lock: renames are atomic, and the "under way" mark kept every
    # other wake out meanwhile, so the old .last-wake is still the right one.
    put(os.path.join(inbox, ".last-wake"), "%d\n" % prev)
    if rc == 3:
        unclaim(claimed)
        return 3, FRESH     # the seat was released meanwhile: the items wait for the next claim (24 h)
    back = own is not None and own[1].get("class") != "user"      # a worker sends its own report itself
    unclaim([(c, it) for c, it in claimed if not back or c.split(".claimed.")[0] != own[0]])
    if back:
        for p in (own[0], "%s.claimed.%d" % (own[0], os.getpid())):
            with contextlib.suppress(OSError):
                os.unlink(p)
    queued = len(glob.glob(os.path.join(inbox, "*.json")))
    if back:
        ilog("handed back", own[1], reason)
        failure(from_, own[1].get("session"), own[1].get("thread"),
                "%s (quiet digest wake; this report went back to its session, %d other report(s) stay queued)"
                % (reason, queued))
    elif not os.path.exists(os.path.join(inbox, ".failing")):
        if any(it.get("class") == "user" for _, it in claimed):
            failure(from_, "", "", "answer wake failed (%s), your user's answer stays queued with %d item(s) "
                    "in the inbox; the watcher retries every 10 min" % (reason, queued))
        else:
            failure(from_, "", "", "digest wake failed (%s), %d report(s) stay queued in the inbox; "
                    "the watcher retries every 10 min" % (reason, queued))
    put(os.path.join(inbox, ".failing"), "%d\n" % NOW)
    return 4, "wake failed, the watcher retries"


def deliver(sdir, cls, from_, path):
    start = time.monotonic()
    sid = coord_sid(sdir)
    user = cls == "user"
    if sid is None and not user:
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
          "class": cls if cls in ("important", "status", "user") else "important", "text": text, "at": NOW}
    inbox = os.path.join(sdir, "t3-inbox")
    try:
        if text is None:
            raise OSError(path)
        os.makedirs(inbox, mode=0o700, exist_ok=True)
        name = "%020d-%s-%d.json" % (time.time_ns(), re.sub(r"[^A-Za-z0-9-]", "", me)[:8] or "none", os.getpid())
        own = (os.path.join(inbox, name), dict(it, name=name))
        write_item(own[0], it)
    except OSError:
        if user:        # the caller keeps it (the Workbench stored it first) and alarms
            print("t3-inbox: NOT delivered (the inbox could not take it)", file=sys.stderr)
            return 4
        # The inbox cannot take it: today's path, one wrapped report, so nothing is lost.
        try:
            return subprocess.run(["bash", os.path.join(HERE, "t3-wake.sh"), from_, path],
                                  timeout=max(2, 13 - (time.monotonic() - start)),
                                  stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode
        except (OSError, subprocess.TimeoutExpired):
            return 4
    ilog("queued", own[1], it["class"])
    # the wake goes through THIS seat's sidecar: t3-wake.sh takes the scope by name (MM_SCOPE wins
    # over MM_SCOPE_CWD and the cwd), so a channel running from another directory cannot post one
    # scope's item through another scope's coordinator
    env = {"MM_SCOPE": scope_name(sdir)}
    if not user:
        return run(inbox, sid, from_, env, own=own, start=start)[0]
    if sid is None:
        rc, q = 0, FRESH
    else:
        rc, q = run(inbox, sid, from_, env, own=own, hold=morning_pending(sdir), start=start)
    if rc == 0 and not q:
        return 0
    try:
        stale = NOW - os.path.getmtime(TICK) > TICK_STALE_S
    except OSError:
        stale = True
    if stale:           # nobody would act on it: the caller alarms
        print("t3-inbox: NOT delivered (%s; queued, but no watcher ran for 30 min)" % q, file=sys.stderr)
        return 4
    print("t3-inbox: queued: %s" % q, file=sys.stderr)
    return 9


def tick(name, sdir, dry=False, hold=False):
    """The watcher's step for one scope (t3-watch.py, every 10 min): the fallback, a debounced wake
    whose window has passed, an asleep coordinator, a user item that waited, the 24-h drop.
    hold = the morning claim is pending (morning_pending): no wake into the night coordinator.
    With quietReports off only user items wake (decide()); the stamp is written either way, so
    deliver knows a watcher runs."""
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
