#!/usr/bin/env python3
"""t3-watch.py - the T3 Code watcher of middle-management: one tick, no model (plan 1.4, 1.4b).

Consumers: templates/systemd/t3-watch.service (started every 10 min by t3-watch.timer; both
  installed as USER units by /middle-management-setup), tests/t3-watch.sh, by hand for
  `--dry-run` / `--stats`. Calls t3-wake.sh, scope.py, t3-inbox.py (imported: the quiet-reports
  tick) and, when it exists, topics.py (all beside it, copy set middle-management-t3watch). Reads
  <cfg>/state/t3-report/{failures.log,posts.tsv}, which t3-wake.sh and t3-inbox.py write, and
  <seat dir>/morning-t3/status, which morning-t3.sh writes.

Usage: t3-watch.py [--dry-run] | --stats
  --dry-run  print every notify, wake and probe instead of doing it, keep no state; scopes without
             a sidecar are evaluated too (the coordinator is then unknown)
  --stats    posts per day and sending thread, from posts.tsv

Per scope with a sidecar (<marker dir>/orchestrator.t3.json), over the unsettled, non-archived,
top-level threads of the scope's T3 project(s), the coordinator thread included:
  usage-limited  lastErrorClass usage_limit, no live run -> notify once per thread and episode; a
                 thread leaves the episode on a live run or a latest run completed after the limited
                 one (lastErrorClass is not trusted to clear);
                 every 30 min: coordinator limited -> t3-wake.sh --keepalive (that run is the retry);
                 only workers limited -> probe their model with one tiny headless `claude -p`, and
                 when it passes wake the coordinator with "limit over for ...". A coordinator that
                 recovers after a Keepalive gets that wake at once. "limit over" goes once per
                 (thread, run id): an announced thread is not probed again until its run id changes,
                 so the probe stops when every limited thread was announced. Episode end -> one
                 "resolved".
                 onLimitCommand (config, optional) runs once per episode with the thread ids.
  click pending  pendingRuntimeRequest seen for >10 min -> notify once per request
  other failure  status failed, another class -> wake the coordinator once per run id (the
                 coordinator's own failure is notified instead: waking it would start a new run)
  stuck run      a live run whose (activeRunId, itemCount) has not changed for >3 h -> notify once
                 per run. ponytail: itemCount, not updatedAt, because updatedAt also moves on
                 lifecycle edits (pin, visit, settle); itemCount grows only with real items.
  report lost    new lines in failures.log -> notify once per line (batched per tick)
  no coordinator the sidecar's thread is gone, settled or archived -> notify once per episode
  handover       sidecar.handover {toThreadId, toTitle, since} older than 30 min while the sidecar
                 still names the old holder -> notify once per handover
  morning        while today's morning thread is started (<seat dir>/morning-t3/status "posted", written
                 by morning-t3.sh, not yet "claimed"/"refused" by claim --morning), at most 30 min
                 after the post, and the sidecar is older than that post, the sidecar still names the
                 night coordinator, which is about to lose the seat: nothing wakes it. "limit over" and
                 "other failure" go to the user as a notify instead, the Keepalive retry is skipped.
Plus: topics.py tick --scope <name> for every scope when topics.py exists (with or without sidecar),
and with config quietReports.enabled the inbox tick of t3-inbox.py for every scope (README "Quiet
reports": the fallback wake, a debounced wake whose window has passed, the 24-h drop; no wake while
the morning claim is pending), also when the T3 API is down: it needs only the inbox and the webhook.
It runs after the scope checks, so while <cfg>/state/t3-watch/<scope>.json names the coordinator in
limit.runs (and the reset time in limit.resets has not passed) t3-inbox.py holds the digest; the
tick that ends the episode, or the first one past the reset time, sends it.
A T3 API problem (HTTP 400 / missing keys, token rejected, server down twice in a row) -> one
notify per kind and day, never a crash. Secrets: the token (config t3TokenFile, default
~/.config/t3-threads/token, refused when group/other can read it) only goes into a request header;
notifyCommand / onLimitCommand are executed, never echoed; the webhook URL is t3-wake.sh's alone.
The T3 server: config t3Url, default http://127.0.0.1:$T3CODE_PORT (8470 when unset).
Env: T3CODE_PORT, T3W_NOW (epoch, test seam), CLAUDE_CONFIG_DIR.
Exit 0, or 1 when a notify could not be delivered (systemd's OnFailure alarm then fires).
"""
import collections, datetime, importlib.util, json, os, re, subprocess, sys, tempfile, time, urllib.error, urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import scope  # noqa: E402  (beside this file)

CFG_DIR = scope.CFG
REPORT_DIR = os.path.join(CFG_DIR, "state", "t3-report")
STATE_DIR = os.path.join(CFG_DIR, "state", "t3-watch")
NOW = float(os.environ.get("T3W_NOW") or time.time())
TODAY = time.strftime("%Y-%m-%d", time.localtime(NOW))
RETRY_S, CLICK_S, STUCK_S, HANDOVER_S = 30 * 60, 10 * 60, 3 * 3600, 30 * 60
MORNING_HOLD_S = 30 * 60   # the morning hold ends at the latest 30 min after the post (hooks/t3-report.sh too)
REQUIRED = ("id", "projectId", "title", "status", "activityRunStatus", "activeRunId", "latestRunId",
            "lastError", "lastErrorClass", "usageLimitResetAt", "pendingRuntimeRequest", "itemCount",
            "settledAt", "archivedAt", "modelSelection")
DRY = False
NOTIFY_FAILED = False


def log(msg):
    print("t3-watch: " + msg, file=sys.stderr)


def load(path, default):
    try:
        with open(path, encoding="utf-8") as f:
            v = json.load(f)
        return v if isinstance(v, type(default)) else default
    except (OSError, ValueError):
        return default     # a corrupt state file starts clean, it never inverts a latch


def save(path, value):
    if DRY:
        return
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = "%s.%d.tmp" % (path, os.getpid())
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(value, f, indent=1, sort_keys=True)
    os.replace(tmp, path)


def cut(s, n=45):
    """A title or a detail for a message: whitespace folded, cut at n chars with an ellipsis."""
    s = " ".join(str(s).split())
    return s if len(s) <= n else s[:n - 1].rstrip() + "…"


def title_of(t):
    return cut(t.get("title") or "untitled session")


def when(t):
    """Local time for a message: 23:30, tomorrow 07:00, Thu 07:00, 16 Nov 07:00 (a week or more away)."""
    days = (datetime.date.fromtimestamp(t) - datetime.date.fromtimestamp(NOW)).days
    f = {0: "%H:%M", 1: "tomorrow %H:%M", -1: "yesterday %H:%M"}.get(days, "%a %H:%M" if abs(days) < 7 else "%d %b %H:%M")
    return time.strftime(f, time.localtime(t))


def iso_epoch(s):
    """An ISO timestamp (T3's usageLimitResetAt, `date -Is`) as epoch, None when it does not parse."""
    try:
        return datetime.datetime.fromisoformat(str(s).replace("Z", "+00:00")).timestamp()
    except ValueError:
        return None


def iso_when(s):
    e = iso_epoch(s)
    return "" if e is None else when(e)


def project(scope_name):
    """A named scope in words ("" for default and the global "all"); an auto scope without its hash."""
    if scope_name in ("default", "all"):
        return ""
    return scope_name.rsplit("-", 1)[0] if scope.AUTO.fullmatch(scope_name) else scope_name


def notify(scope_name, headline, facts=()):
    """One plain-text message through notifyCommand: the headline (kind emoji first), a blank line,
    then one fact per line ("" = a blank line), the action last; a named scope adds a Project line."""
    global NOTIFY_FAILED
    p = project(scope_name)
    body = (["Project: " + p] if p else []) + [str(f) for f in facts]
    text = "\n".join([headline] + ([""] + body if body else []))
    if DRY:
        print("NOTIFY  " + text.replace("\n", "\n        "))
        return
    cmd = CFG.get("notifyCommand") if isinstance(CFG.get("notifyCommand"), str) else ""
    if not cmd:
        log("no notifyCommand in the config, NOT delivered: " + text)
        NOTIFY_FAILED = True
        return
    try:      # output dropped: a failing command may echo a URL that carries a token
        rc = subprocess.run(["sh", "-c", cmd, "notify", text], input=text, text=True, timeout=60,
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode
    except (OSError, subprocess.TimeoutExpired):
        rc = -1
    if rc != 0:
        log("notifyCommand failed (exit %s), the message was: %s" % (rc, text))
        NOTIFY_FAILED = True


def wake(scope_name, text, keepalive=False):
    """t3-wake.sh into the scope's coordinator; True only when it answered 202."""
    if DRY:
        print("WAKE    scope %s: %s" % (scope_name, "Keepalive" if keepalive else text.replace("\n", " | ")))
        return True
    env = dict(os.environ, MM_SESSION_ID="", MM_SCOPE=scope_name)
    with tempfile.NamedTemporaryFile("w", prefix="t3-watch.", suffix=".txt", delete=False) as f:
        f.write(text)
    try:
        rc = subprocess.run(["bash", os.path.join(HERE, "t3-wake.sh"), "t3-watch",
                             "--keepalive" if keepalive else f.name], env=env, timeout=30,
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode
    except (OSError, subprocess.TimeoutExpired):
        rc = -1
    finally:
        os.unlink(f.name)
    if rc != 0:
        log("t3-wake.sh failed (exit %s) for scope %s" % (rc, scope_name))   # it logged failures.log
    return rc == 0


def probe(model):
    """True = the model answers, False = still usage-limited, None = the probe failed otherwise.
    The logic of slack-threadwatcher's check-usage-limit.py, inlined (no dependency on a skill)."""
    if DRY:
        print("PROBE   claude -p ok --model %s" % model)
        return None
    cmd = ["claude", "-p", "ok", "--model", model, "--output-format", "json", "--no-session-persistence",
           "--strict-mcp-config", "--tools", "", "--setting-sources", ""]
    env = {k: v for k, v in os.environ.items() if not k.startswith("T3CODE_")}  # never a T3 thread
    try:
        p = subprocess.run(cmd, capture_output=True, text=True, timeout=120, cwd="/tmp", env=env)
    except (OSError, subprocess.TimeoutExpired) as e:
        log("probe %s failed: %s" % (model, e.__class__.__name__))
        return None
    try:
        d = json.loads(p.stdout)
        err, text = bool(d.get("is_error")), str(d.get("result", ""))
        if d.get("api_error_status") == 429:
            text += " [429 %s]" % d.get("api_error_code")
    except (ValueError, AttributeError):
        err, text = p.returncode != 0, (p.stdout or "") + "\n" + (p.stderr or "")
    if not err:
        return True
    if re.search(r"usage limit|hit your limit|limit reached|out of (?:extra )?usage|\[429 ", text, re.I):
        return False
    log("probe %s: other error: %s" % (model, text.strip()[:200]))
    return None


def api_problem(gstate, kind, headline, action, detail):
    """One notify per kind and day; the tick then skips the T3 part. What still runs without the
    T3 API, as main() does it: report_lost, the topics tick and the inbox tick."""
    if gstate.setdefault("api", {}).get(kind) != TODAY:
        gstate["api"][kind] = TODAY
        notify("all", "⚠️ T3 watcher paused: " + headline, still(gstate, kind) + [
            "Until it is fixed, you get no notices about usage limits or waiting, stuck or failed sessions.",
            "Lost reports and topic reminders still come through.", action, "Detail: " + detail])


def still(gstate, kind):
    """The daily repeat of a problem that lasts names its first notice; gstate["since"][kind] is
    cleared when it is gone (fetch_shell's good answer, a tick without an internal error)."""
    since = gstate.setdefault("since", {}).setdefault(kind, NOW)
    return ["Still so since %s (this repeats once a day)." % when(since)] if since < NOW else []


T3_NEWER = "T3 Code was probably updated: update this plugin, or tell its maintainer."
NEW_TOKEN = "Fix: run /middle-management-setup, step 8 (T3 Code watcher), for a new token."


def t3_url():
    """Config key t3Url (setup writes it), else this box's T3 server on loopback."""
    u = CFG.get("t3Url")
    return u if isinstance(u, str) and u else "http://127.0.0.1:%s" % (os.environ.get("T3CODE_PORT") or "8470")


def fetch_shell(gstate):
    """The /api/orchestration/shell JSON, or None after reporting why (never raises)."""
    path = os.path.expanduser(CFG.get("t3TokenFile") or "~/.config/t3-threads/token")
    try:
        st = os.stat(path)
        if st.st_mode & 0o077:
            api_problem(gstate, "token-mode", "its token file is readable by others", "Fix: chmod 600 " + path,
                        "it refuses a token file that group or other can read")
            return None
        with open(path, encoding="utf-8") as f:
            tok = f.read().strip()
    except OSError:
        api_problem(gstate, "token-missing", "its T3 token is missing", NEW_TOKEN,
                    "no token file at %s (config key t3TokenFile)" % path)
        return None
    base = t3_url()
    req = urllib.request.Request(base.rstrip("/") + "/api/orchestration/shell", headers={
        "authorization": "Bearer " + tok, "x-t3-orchestration-protocol": "2"})
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            body = json.load(r)
    except urllib.error.HTTPError as e:
        if e.code == 400:
            api_problem(gstate, "api-changed", "it no longer understands T3 Code", T3_NEWER,
                        "the thread list answered HTTP 400 (protocol header, plugin README \"T3 Code\")")
        elif e.code in (401, 403):
            api_problem(gstate, "token-rejected", "T3 Code rejects its token", NEW_TOKEN, "HTTP %d" % e.code)
        else:
            return down(gstate, "HTTP %d" % e.code)
        return None
    except (urllib.error.URLError, OSError, ValueError) as e:
        if isinstance(e, ValueError):
            api_problem(gstate, "api-changed", "it no longer understands T3 Code", T3_NEWER,
                        "the thread list answer is not JSON")
            return None
        return down(gstate, e.__class__.__name__)
    gstate["down"] = 0
    ok = isinstance(body, dict) and isinstance(body.get("threads"), list) \
        and isinstance(body.get("projects"), list) \
        and all(isinstance(t, dict) and all(k in t for k in REQUIRED) for t in body["threads"]) \
        and all(isinstance(p, dict) and "id" in p and "workspaceRoot" in p for p in body["projects"])
    if not ok:
        api_problem(gstate, "api-changed", "it no longer understands T3 Code", T3_NEWER,
                    "the thread list lacks keys the watcher reads")
        return None
    gstate["since"] = {k: v for k, v in gstate.get("since", {}).items() if k == "internal"}  # the API is fine again
    return body


def down(gstate, why):
    """The server did not answer: a T3 restart lasts one tick, so only the second miss notifies."""
    gstate["down"] = int(gstate.get("down", 0)) + 1
    if gstate["down"] >= 2:
        api_problem(gstate, "down", "T3 Code does not answer", "Check that T3 Code is running.",
                    "%s, %d checks in a row" % (why, gstate["down"]))
    return None


def norm(tid):
    return (tid or "").replace(":", "-")


def label(t):
    return "%s (%s)" % (t.get("title") or "untitled", t["id"])


def model_of(t):
    m = t.get("modelSelection")
    return (m.get("model") if isinstance(m, dict) else None) or "unknown"


def err_text(t):
    e = t.get("lastError")
    if isinstance(e, dict):
        e = e.get("message") or json.dumps(e)
    return str(e or "")[:300]


def threads_of(shell, name, ss, coord_id):
    """Top-level threads of the scope's projects that are neither settled nor archived, plus the
    coordinator's row (by id) whatever its state, as (threads, coordinator row or None)."""
    memo = {}
    for p in shell["projects"]:
        try:
            memo[p["id"]] = scope.of(p["workspaceRoot"], ss)
        except scope.Unknown:
            memo[p["id"]] = None      # unknown scope: never watched, never guessed
    # ponytail: sub-agent rows are skipped (84 idle orphans today); their parent reports for them.
    out = [t for t in shell["threads"] if memo.get(t["projectId"]) == name
           and not (t.get("settledAt") or t.get("archivedAt") or t.get("deletedAt"))
           and (t.get("lineage") or {}).get("relationshipToParent") != "subagent"]
    coord = None
    if coord_id:
        coord = next((t for t in shell["threads"] if norm(t["id"]) == norm(coord_id)), None)
        if coord is not None and all(t["id"] != coord["id"] for t in out):
            out.append(coord)
    return out, coord


def morning_pending(sdir):
    """True while today's morning thread was started (morning-t3.sh status "posted"; claim --morning
    turns it into "claimed" or "refused"), the post is under 30 min old, and the seat is not bound
    anew yet (the sidecar is older than the post). The sidecar then still names the night
    coordinator, and a wake would make it re-pay its whole context for a seat it is about to lose.
    ponytail: the window is told by time, not by thread id: any wake in it goes to the user instead."""
    try:
        with open(os.path.join(sdir, "morning-t3", "status"), encoding="utf-8") as f:
            day, state, at = (f.readline().rstrip("\n").split("\t") + ["", "", ""])[:3]
        at = float(at)
    except (OSError, ValueError):
        return False
    if day != TODAY or state != "posted" or NOW - at >= MORNING_HOLD_S:
        return False
    try:
        return os.path.getmtime(os.path.join(sdir, "orchestrator.t3.json")) < at
    except OSError:
        return False


def check_scope(name, sdir, side, shell, ss):
    st_path = os.path.join(STATE_DIR, name + ".json")
    st = load(st_path, {})
    coord_id = side.get("threadId") if isinstance(side.get("threadId"), str) else ""
    threads, coord = threads_of(shell, name, ss, coord_id)
    is_coord = lambda t: coord is not None and t["id"] == coord["id"]  # noqa: E731
    pending = morning_pending(sdir)
    old = '"%s"' % cut(side["title"]) if side.get("title") else ""      # the seat holder the sidecar names
    held = "The night coordinator%s is not woken: this morning's coordinator has not taken the seat yet." % (
        " " + old if old else "")
    live = lambda t: t.get("activityRunStatus") == "running"           # noqa: E731

    # no coordinator: the seat names a thread that is gone, settled or archived
    if side:
        gone = coord is None or bool(coord.get("settledAt") or coord.get("archivedAt") or coord.get("deletedAt"))
        if gone and not st.get("coordless"):
            notify(name, "🔴 No coordinator: the seat names a closed session", [
                "%s holds the seat, but it %s." % (old or "The old coordinator",
                                                   "no longer exists" if coord is None else "is settled or archived"),
                "Worker reports still go to that session.",
                "Start a coordinator session and run /orchestrator claim in it."])
        elif not gone and st.get("coordless"):
            notify(name, '🟡 Coordinator is back: "%s" holds the seat.' % title_of(coord))
        st["coordless"] = gone

    # handover (orchestrator.sh t3-handover): the successor has not claimed within 30 min
    ho = side.get("handover") if isinstance(side.get("handover"), dict) else {}
    to, since = ho.get("toThreadId"), ho.get("since")
    if isinstance(to, str) and to and isinstance(since, (int, float)) and norm(to) != norm(coord_id) \
            and NOW - since > HANDOVER_S:
        key = "%s@%d" % (to, since)
        if st.get("handover") != key:
            succ = '"%s"' % cut(ho["toTitle"]) if ho.get("toTitle") else "the new session"
            notify(name, "⏳ Coordinator handover stuck: %s has not taken the seat" % succ,
                   ["Open since %s; %s keeps the seat until then." % (when(since), old or "the old coordinator"),
                    "Open %s in T3 and have it run /orchestrator claim." % succ])
            st["handover"] = key

    # usage limit
    ep = st.get("limit") or {}
    runs = ep.get("runs", {})       # thread id -> the run that hit the limit

    def recovered(t):
        # The episode ends on a live run or on a latest run that completed AFTER the limited one; it
        # never trusts lastErrorClass to clear. (Verified 2026-10-20: the four threads limited on
        # 16. and 18.10 and resumed later read completed + lastErrorClass null now; the moment it
        # cleared is not visible in the shell, hence the run-id rule.)
        return live(t) or (t.get("status") == "completed" and t.get("latestRunId") != runs.get(t["id"]))
    limited = {t["id"]: t for t in threads
               if (t["id"] in runs and not recovered(t))
               or (t["id"] not in runs and t.get("lastErrorClass") == "usage_limit"
                   and not live(t) and t.get("status") != "completed")}
    nruns = {i: (t.get("latestRunId") if t.get("status") == "failed" else runs.get(i, t.get("latestRunId")))
             for i, t in limited.items()}
    if limited:
        if not ep:
            ep = {"since": NOW, "last_retry": NOW, "notified": [], "keepalive": False}
            cmd = CFG.get("onLimitCommand")
            if isinstance(cmd, str) and cmd:
                if DRY:
                    print("ONLIMIT %d thread ids" % len(limited))
                else:
                    try:
                        subprocess.run(["sh", "-c", cmd, "onlimit"] + sorted(limited), timeout=60,
                                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                    except (OSError, subprocess.TimeoutExpired):
                        log("onLimitCommand failed")
        ep["runs"] = nruns
        # read by t3-inbox.py: past a thread's reset time its held digest goes out without waiting
        # for the next Keepalive to end the episode
        ep["resets"] = {i: t.get("usageLimitResetAt") for i, t in limited.items() if t.get("usageLimitResetAt")}
        new = [t for i, t in sorted(limited.items()) if i not in ep["notified"]]
        if new:
            def until(t):
                u = iso_when(t.get("usageLimitResetAt"))
                return "until " + u if u else "reset time unknown"
            facts = ["• %s (%s%s)" % (title_of(t), "coordinator, " if is_coord(t) else "", until(t)) for t in new] + [""]
            # what happens next, as the code below does it: workers get "limit over" through the
            # coordinator (probe or Keepalive every 30 min); a Keepalive is answered "OK", nothing more
            if not all(map(is_coord, new)):
                facts.append("When the limit is over, the coordinator restarts the paused workers (checked every 30 min).")
            if any(map(is_coord, new)):
                facts.append("The coordinator does not resume its own task: tell it to continue after the reset.")
            last = max((e for e in (iso_epoch(t.get("usageLimitResetAt")) for t in new) if e is not None), default=None)
            notify(name, "🔴 Usage limit: %d session%s paused" % (len(new), " is" if len(new) == 1 else "s are"),
                   facts + ["Switch the subscription, or wait until %s." % when(last) if last and last > NOW
                            else "Switch the subscription, or wait for the reset."])
            ep["notified"] = sorted(set(ep["notified"]) | set(limited))
        # "limit over" goes once per limited (thread, run id): a thread the coordinator did not
        # continue is neither probed nor named again until its run id changes (a new limit).
        freed = {i: r for i, r in (ep.get("freed") or {}).items() if i in nruns and nruns[i] == r}
        workers = [t for i, t in sorted(limited.items()) if not is_coord(t) and i not in freed]

        def limit_over(ts):
            if pending:      # freed below: the watcher names these once, nobody else restarts them
                notify(name, "⏳ Limit over: restart %d paused session%s yourself" % (len(ts), "" if len(ts) == 1 else "s"),
                       ["• " + title_of(t) for t in ts] + ["", held, "Open %s in T3 and send 'Continue where you left off.'"
                                                             % ("it" if len(ts) == 1 else "each")])
                freed.update((t["id"], nruns[t["id"]]) for t in ts)
                return
            if wake(name, "limit over for:\n%s\nsend 'Continue where you left off.' to each (t3_thread_send)."
                    % "\n".join(label(t) for t in ts)):
                freed.update((t["id"], nruns[t["id"]]) for t in ts)

        if coord is not None and coord["id"] in limited:
            if pending:
                pass              # the seat is about to change hands: no Keepalive into the old holder
            elif NOW - ep["last_retry"] >= RETRY_S:
                ep["last_retry"] = NOW
                ep["keepalive"] = wake(name, "", keepalive=True) or ep["keepalive"]
        elif workers and ep.get("keepalive") and coord is not None and not live(coord):
            limit_over(workers)       # the Keepalive run completed after the limited one: switched
            ep["keepalive"], ep["last_retry"] = False, NOW
        elif workers and NOW - ep["last_retry"] >= RETRY_S:
            ep["last_retry"] = NOW
            by_model = collections.defaultdict(list)
            for t in workers:
                by_model[model_of(t)].append(t)
            free = [t for m, ts in sorted(by_model.items()) if probe(m) is True for t in ts]
            if free:
                limit_over(free)
        ep["freed"] = freed
        st["limit"] = ep
    elif ep:
        n = len(ep.get("notified", []))
        notify(name, "🟡 Limit over: the %s paused since %s %s working again." % (
            "session" if n == 1 else "%d sessions" % n, when(ep.get("since", NOW)), "is" if n == 1 else "are"))
        st["limit"] = {}

    # click pending > 10 min, stuck run > 3 h, other failure once per run id
    pend, stuck, failed = st.get("pending", {}), st.get("stuck", {}), st.get("failed", {})
    npend, nstuck, nfailed = {}, {}, {}
    for t in threads:
        tid, req = t["id"], t.get("pendingRuntimeRequest")
        if req:
            key = str(req.get("id")) if isinstance(req, dict) and req.get("id") else json.dumps(req, sort_keys=True)[:200]
            e = pend.get(tid) if (pend.get(tid) or {}).get("key") == key else {"key": key, "first": NOW, "done": False}
            if not e["done"] and NOW - e["first"] >= CLICK_S:
                notify(name, "⏳ A session waits for your answer: %s" % title_of(t),
                       ["Waiting since %s." % when(e["first"]), "Open it in T3 and answer."])
                e["done"] = True
            npend[tid] = e
        elif live(t):
            snap = [t.get("activeRunId"), t.get("itemCount")]
            e = stuck.get(tid) if (stuck.get(tid) or {}).get("snap") == snap else {"snap": snap, "since": NOW, "done": False}
            if not e["done"] and NOW - e["since"] >= STUCK_S:
                notify(name, "🔴 A session may hang: %s" % title_of(t),
                       ["Running, but no new step since %s." % when(e["since"]), "Check it in T3; stop it if it hangs."])
                e["done"] = True
            nstuck[tid] = e
        if t.get("status") == "failed" and not live(t) and t.get("lastErrorClass") != "usage_limit":
            run = t.get("latestRunId") or "?"
            if failed.get(tid) != run:
                detail = "Detail: " + ": ".join(x for x in (t.get("lastErrorClass") or "unknown error",
                                                            cut(err_text(t), 160)) if x)
                if is_coord(t):     # not woken: a wake would start a new run of the failed coordinator
                    notify(name, "🔴 The coordinator's last run failed: %s" % title_of(t),
                           ["The watcher does not restart it.", "Look at it in T3 and nudge it if needed.", detail])
                elif pending:
                    notify(name, "🔴 A session stopped with an error: %s" % title_of(t),
                           [held, "Look at it in T3 and nudge it if needed.", detail])
                else:
                    wake(name, "other failure in %s: %s. %s" % (label(t), t.get("lastErrorClass") or "unknown",
                                                                 err_text(t)))
            nfailed[tid] = run
    # checked: t3-inbox.py holds quiet digests while limit.runs names the coordinator, and only
    # while this stamp is under 30 min old (a watcher that stopped checking never holds a wake)
    st.update(pending=npend, stuck=nstuck, failed=nfailed, checked=NOW)
    save(st_path, st)


def report_lost(gstate):
    path = os.path.join(REPORT_DIR, "failures.log")
    try:
        size = os.path.getsize(path)
    except OSError:
        return
    off = int(gstate.get("failures_offset", 0))
    if size < off:
        off = 0                       # rotated or truncated: read it again from the top
    with open(path, encoding="utf-8", errors="replace") as f:
        f.seek(off)
        lines = [ln.rstrip("\n") for ln in f.read().splitlines() if ln.strip()]
        gstate["failures_offset"] = f.tell()
    if lines:
        # Three kinds of line, each with its own truth: a session's report (its text stays in that
        # session), the watcher's own wake (a Keepalive or "limit over" is retried at the next 30-min
        # retry; an "other failure" wake is not, nfailed is set either way), a quiet digest (queued,
        # the inbox tick retries it on every watcher tick).
        facts, kinds = [], set()
        for i, ln in enumerate(lines):
            c = (ln.split("\t") + [""] * 5)[:5]      # time, from, session id, thread id, reason
            kind = "digest" if c[4].startswith("digest wake failed") else "watcher" if c[1] == "t3-watch" else "session"
            kinds.add(kind)
            if i < 10:
                who = {"digest": "quiet-report digest", "watcher": "the watcher's notice"}.get(kind) \
                    or cut(c[1] or "a session")
                facts.append("• %s: %s" % (" ".join(x for x in (iso_when(c[0]), who) if x), why(c[4])))
        if len(lines) > 10:
            facts.append("• and %d more" % (len(lines) - 10))
        facts.append("")
        if "session" in kinds:
            facts.append("A report from a session is still in that session: read it there, or ask the coordinator to.")
        if "watcher" in kinds:
            facts += ["The watcher retries its usage-limit notices every 30 min.",
                      "A notice about a failed session is not retried: check T3 for failed sessions."]
        if kinds == {"digest"}:
            facts.append("Nothing to do now.")
        noun = "worker report" if kinds == {"session"} else "message"
        notify("all", "🔴 %d %s%s did not reach the coordinator" % (len(lines), noun, "" if len(lines) == 1 else "s"), facts)


def why(reason):
    """A failures.log reason in words: "http <code>" (000 = no answer) and the sidecar checks from
    t3-wake.sh, the morning hold from hooks/t3-report.sh, the two quiet-digest lines from
    t3-inbox.py; anything else cut short."""
    m = re.search(r"\bhttp (\d+)", reason)
    code = ("no answer" if m[1] == "000" else "refused (HTTP %s)" % m[1]) if m else "not delivered"
    if reason.startswith("digest wake failed"):        # the inbox tick runs on every watcher tick
        return code + "; the reports stay queued and are retried every 10 min"
    if "quiet digest wake" in reason:
        return code + "; the report went back to its session"
    if reason.startswith("held: the morning thread"):
        return "held back until this morning's coordinator takes the seat"
    if reason.startswith("sidecar "):                  # mode not 0600 / no usable reportUrl: t3-bind rewrites it
        return "the coordinator's seat file is broken: have the coordinator claim the seat again"
    return code if re.fullmatch(r"http \d+", reason) else cut(reason, 80)


def topics_tick(names):
    tp = os.path.join(HERE, "topics.py")
    if not os.path.isfile(tp):
        return
    for n in names:
        if DRY:
            print("TOPICS  python3 topics.py tick --scope %s" % n)
            continue
        try:
            rc = subprocess.run([sys.executable, tp, "tick", "--scope", n], timeout=120,
                                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode
        except (OSError, subprocess.TimeoutExpired):
            rc = -1
        if rc != 0:
            log("topics.py tick --scope %s failed (exit %s)" % (n, rc))


def stats():
    path = os.path.join(REPORT_DIR, "posts.tsv")
    c = collections.Counter()
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            for ln in f:
                p = (ln.rstrip("\n").split("\t") + ["", "", "", ""])[:4]
                if p[0]:
                    c[(p[0], p[3], p[1])] += 1
    except OSError:
        print("no posts yet (%s)" % path)
        return 0
    print("date\tposts\tthread\tfrom")
    for (d, th, fr), n in sorted(c.items()):
        print("%s\t%d\t%s\t%s" % (d, n, th, fr))
    return 0


def main(argv):
    global DRY, CFG
    if argv == ["--stats"]:
        return stats()
    if argv not in ([], ["--dry-run"]):
        print(__doc__.split("\n\n")[1], file=sys.stderr)
        return 2
    DRY = argv == ["--dry-run"]
    CFG = scope.config()
    ss = scope.scopes(CFG)
    names = ["default"] + [s["name"] for s in ss]
    g_path = os.path.join(STATE_DIR, "global.json")
    gstate = load(g_path, {})
    try:
        report_lost(gstate)
        work = []
        for n in names:
            sdir = scope.info(n, CFG)[0]
            side_path = os.path.join(sdir, "orchestrator.t3.json")
            side = load(side_path, {}) if os.path.isfile(side_path) else None
            if side is not None or DRY:
                work.append((n, sdir, side or {}))
                if DRY and side is None:
                    print("SCOPE   %s: no sidecar, evaluated for the dry run only" % n)
        if work:
            shell = fetch_shell(gstate)
            if shell is not None:
                for n, sdir, side in work:
                    check_scope(n, sdir, side, shell, ss)
        topics_tick(names)
        q = CFG.get("quietReports")
        if isinstance(q, dict) and q.get("enabled") is True:     # off: not even loaded (= before 0.15.0)
            spec = importlib.util.spec_from_file_location("t3_inbox", os.path.join(HERE, "t3-inbox.py"))
            inbox = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(inbox)
            for n in names:
                sdir = scope.info(n, CFG)[0]
                inbox.tick(n, sdir, dry=DRY, hold=morning_pending(sdir))
        gstate.get("since", {}).pop("internal", None)    # a whole tick without an internal error
    except Exception as e:      # never a crash loop: one notify per day, then exit 0
        if gstate.setdefault("api", {}).get("internal") != TODAY:
            gstate["api"]["internal"] = TODAY
            notify("all", "⚠️ T3 watcher hit an internal error", still(gstate, "internal") + [
                "This check stopped at the error; some notices may be missing until it is fixed.",
                "It runs again every 10 min and tells you at most once a day.",
                "To see why: journalctl --user -u t3-watch.service",
                "Detail: %s: %s" % (e.__class__.__name__, cut(e, 160))])
        log("internal error: %r" % e)
    save(g_path, gstate)
    return 1 if NOTIFY_FAILED else 0


CFG = {}
if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
