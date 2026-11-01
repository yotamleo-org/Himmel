#!/usr/bin/env python3
"""cache-health.py - scripted per-role prompt-cache metrics with threshold alerts (HIMMEL-5672).

No LLM, no claude -p: reads session transcripts under <projects-root>, writes a
metrics JSON plus a rolling history under <state-dir>, and notifies only on a
real threshold crossing.

  cache-health.py check  --state-dir D [--root R] [--now EPOCH] [--notify-cmd CMD] [--dry-run]
  cache-health.py report [--root R] [--now EPOCH]        # print today's numbers, write nothing

Metrics (see docs/internals/cache-health.md for the metrics.json schema):
  hit = cache_read / (cache_read + cache_creation + input), rows deduped by
  message id. Per role (chief, worker, subagent, bridge, other), over a RECENT
  window (default 24h) and a BASELINE window (the 7 days before it).

Alert rules (every default is a flag):
  role-drop        (roles in --alert-roles, default console,worker) a role's recent hit rate is more than --drop-pts (3) below its baseline
  session-low      (same roles) a session over --session-min-tokens (1M) with hit below --session-hit (90 %)
  compactions      mean compactions per active worker above --compactions-max (4)
Hysteresis: a crossing is notified once; it stays quiet while it stays crossed; a
role-drop clears only once it is back within --clear-pts (2) of baseline, and a
single recovery message goes out. Session-low keys expire silently when the
session leaves the window.

The notify command is called with ONE argument (the message); exit 0 = delivered.
State is committed only for delivered messages, so a failed send retries next run.
"""
import argparse, fcntl, json, os, re, subprocess, sys, time
from collections import defaultdict
from datetime import datetime

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "lib"))
from env_alias import legacy_names_on

ROLES = ["console", "worker", "subagent", "bridge", "other"]
HISTORY_KEEP = 24 * 30  # hourly runs, 30 days


def ts(s):
    try:
        return datetime.fromisoformat(s.replace("Z", "+00:00")).timestamp()
    except Exception:
        return None


def classify(path, title, first):
    if "/subagents/" in path:
        return "subagent"
    t = title or ""
    if "-console" in t or t.endswith("-chief"):
        return "console"
    if re.search(r"HIMMEL-\d+-.*N\d+|leg[A-Z]?\d+|-N\d+", t):
        return "worker"
    if first.startswith("You are Telegram bridge session"):
        return "bridge"
    return "other"


def parse_session(path):
    """-> (title, role, turns, compaction_timestamps). turns: (ts, input, read, c5, c1)."""
    title, first, seen, turns, comps = None, "", set(), [], []
    try:
        with open(path, errors="replace") as f:
            for line in f:
                if line.startswith('{"type":"custom-title"'):
                    try:
                        title = json.loads(line).get("customTitle") or title
                    except Exception:
                        pass
                    continue
                if '"compact_boundary"' in line and '"subtype"' in line:
                    try:
                        comps.append(ts(json.loads(line).get("timestamp", "")))
                    except Exception:
                        comps.append(None)
                    continue
                if not first and '"type":"user"' in line[:300] and '"role":"user"' in line:
                    try:
                        c = json.loads(line).get("message", {}).get("content", "")
                        first = c if isinstance(c, str) else "".join(
                            b.get("text", "") for b in c if isinstance(b, dict) and b.get("type") == "text")
                    except Exception:
                        pass
                if '"usage"' not in line or '"role":"assistant"' not in line:
                    continue
                try:
                    d = json.loads(line)
                except Exception:
                    continue
                m = d.get("message") or {}
                u = m.get("usage")
                if not u or m.get("model") == "<synthetic>":
                    continue
                mid = m.get("id") or d.get("uuid")
                if mid in seen:
                    continue
                seen.add(mid)
                cc = u.get("cache_creation") or {}
                c1 = cc.get("ephemeral_1h_input_tokens", 0) or 0
                c5 = cc.get("ephemeral_5m_input_tokens", 0) or 0
                if not cc:
                    c5 = u.get("cache_creation_input_tokens", 0) or 0
                turns.append((ts(d.get("timestamp", "")), u.get("input_tokens", 0) or 0,
                              u.get("cache_read_input_tokens", 0) or 0, c5, c1))
    except FileNotFoundError:
        return None  # pruned between the glob and the read
    return title, classify(path, title, first), turns, comps


def agg(rows):
    """rows: iterable of (input, read, c5, c1)."""
    inp = rd = c5 = c1 = 0
    for a, b, c, d in rows:
        inp += a; rd += b; c5 += c; c1 += d
    den = inp + rd + c5 + c1
    cost = inp + 0.1 * rd + 1.25 * c5 + 2.0 * c1
    return dict(tokens=den,
                hit_pct=round(100 * rd / den, 2) if den else None,
                write_share_pct=round(100 * (1.25 * c5 + 2.0 * c1) / cost, 2) if cost else None,
                w1h_pct=round(100 * c1 / (c1 + c5), 2) if c1 + c5 else None,
                excess=cost - 0.1 * den)


def compute(root, now, recent_h, baseline_d, offender_min, top_n):
    r0 = now - recent_h * 3600
    b0 = r0 - baseline_d * 86400
    def walk_err(e):
        raise e
    files = []
    for dp, _, fns in os.walk(root, onerror=walk_err):
        for fn in fns:
            if fn.endswith(".jsonl"):
                p = os.path.join(dp, fn)
                try:
                    if os.path.getmtime(p) >= b0:
                        files.append(p)
                except FileNotFoundError:
                    pass  # pruned between the walk and the stat
    rec = defaultdict(list)    # role -> turn tuples in the recent window
    base = defaultdict(list)   # role -> turn tuples in the baseline window
    sess_n = defaultdict(set)
    comp = defaultdict(lambda: defaultdict(int))  # role -> session -> count (recent)
    offenders = []
    for p in files:
        parsed = parse_session(p)
        if not parsed:
            continue
        title, role, turns, comps = parsed
        mine = [t for t in turns if t[0] and t[0] >= r0]
        for t in turns:
            if not t[0]:
                continue
            if t[0] >= r0:
                rec[role].append(t[1:])
            elif t[0] >= b0:
                base[role].append(t[1:])
        if not mine:
            continue
        sid = os.path.basename(p)[:-6]
        sess_n[role].add(sid)
        comp[role][sid] += sum(1 for c in comps if c and c >= r0)
        a = agg(t[1:] for t in mine)
        if a["tokens"] >= offender_min:
            offenders.append(dict(session=sid, title=title or sid[:8], role=role,
                                  tokens=a["tokens"], hit_pct=a["hit_pct"],
                                  excess=round(a["excess"]), compactions=comp[role][sid]))
    roles = {}
    for role in ROLES:
        ra, ba = agg(rec[role]), agg(base[role])
        n = len(sess_n[role])
        c = sum(comp[role].values())
        roles[role] = dict(sessions=n, tokens=ra["tokens"], hit_pct=ra["hit_pct"],
                           baseline_hit_pct=ba["hit_pct"], baseline_tokens=ba["tokens"],
                           delta_pts=(round(ra["hit_pct"] - ba["hit_pct"], 2)
                                      if ra["hit_pct"] is not None and ba["hit_pct"] is not None else None),
                           write_share_pct=ra["write_share_pct"], w1h_pct=ra["w1h_pct"],
                           compactions=c, compactions_per_session=round(c / n, 2) if n else None)
    allr = agg(t for r in ROLES for t in rec[r])
    allb = agg(t for r in ROLES for t in base[r])
    offenders.sort(key=lambda o: -o["excess"])
    return dict(schema=1, generated_at=int(now),
                window=dict(recent_hours=recent_h, baseline_days=baseline_d),
                overall=dict(tokens=allr["tokens"], hit_pct=allr["hit_pct"], baseline_hit_pct=allb["hit_pct"],
                             write_share_pct=allr["write_share_pct"], w1h_pct=allr["w1h_pct"]),
                roles=roles, top_offenders=offenders[:top_n]), offenders


def legacy_role(role):
    """The pre-rename role name `leg` reads as `worker` while legacy names are on."""
    return "worker" if role == "leg" and legacy_names_on() else role


def legacy_key(key):
    """An alert key persisted before the rename (`role-drop:leg`) reads as the worker key."""
    return re.sub(r"^(role-drop|compactions):leg$", r"\1:worker", key) if legacy_names_on() else key


def evaluate(metrics, offenders, a):
    """-> {key: (kind, text)} for every rule currently crossed (entering threshold)
    and {key: kind} for those still inside the clear margin."""
    cross, holding = {}, {}
    alert_roles = [legacy_role(x) for x in a.alert_roles.split(",")]
    for role, r in metrics["roles"].items():
        d = r["delta_pts"]
        if role not in alert_roles:
            continue
        if d is None or r["tokens"] < a.role_min_tokens or r["baseline_tokens"] < a.role_min_tokens:
            holding["role-drop:" + role] = True  # too little data to judge: keep an active alert, raise none
            continue
        if d < -a.drop_pts:
            cross["role-drop:" + role] = "%s hit rate %.1f%% is %.1f pts below its %.1f%% baseline" % (
                role, r["hit_pct"], -d, r["baseline_hit_pct"])
        elif d < -a.clear_pts:
            holding["role-drop:" + role] = True
    worker = metrics["roles"]["worker"]
    if worker["sessions"] and worker["compactions_per_session"] is not None and worker["compactions_per_session"] > a.compactions_max:
        cross["compactions:worker"] = "workers average %.1f compactions each (limit %g) over %d sessions" % (
            worker["compactions_per_session"], a.compactions_max, worker["sessions"])
    for o in offenders:
        if o["role"] in alert_roles and o["tokens"] >= a.session_min_tokens and o["hit_pct"] is not None and o["hit_pct"] < a.session_hit:
            cross["session-low:" + o["session"]] = "%s session %s: %.1f%% hit over %.1fM tokens" % (
                o["role"], o["title"][:40], o["hit_pct"], o["tokens"] / 1e6)
    return cross, holding


def notify(cmd, msg, dry):
    if dry:
        print("DRY notify: " + msg)
        return True
    try:
        return subprocess.run(cmd + [msg], stdin=subprocess.DEVNULL).returncode == 0
    except OSError as e:
        print("cache-health: notify failed: %s" % e, file=sys.stderr)
        return False


def load_json(path, default):
    try:
        with open(path) as f:
            return json.load(f)
    except (OSError, ValueError):
        return default


def write_atomic(path, text):
    tmp = path + ".tmp.%d" % os.getpid()
    with open(tmp, "w") as f:
        f.write(text)
    os.replace(tmp, path)


def cmd_check(a, metrics, offenders):
    sd = a.state_dir
    if not a.dry_run:
        if not a.notify_cmd:
            print("cache-health: check needs --notify-cmd (or --dry-run)", file=sys.stderr)
            return 2
        os.makedirs(sd, exist_ok=True)
        lock = open(os.path.join(sd, "lock"), "w")
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            print("cache-health: another check holds the lock, skipping", file=sys.stderr)
            return 0
    st_path = os.path.join(sd, "alert-state.json")
    active = {legacy_key(k): v for k, v in load_json(st_path, {}).get("active", {}).items()}  # key -> text at crossing
    cross, holding = evaluate(metrics, offenders, a)
    new = {k: v for k, v in cross.items() if k not in active}
    # An active key stays active while crossed or inside the clear margin.
    gone = [k for k in active if k not in cross and k not in holding]
    recovered = [k for k in gone if not k.startswith("session-low:")]
    cmd = shlex_split(a.notify_cmd)
    next_active = {k: v for k, v in active.items() if k in cross or k in holding}
    send_failed = False
    if new:
        lines = ["cache-health ALERT (%d new):" % len(new)] + ["- " + v for v in list(new.values())[:5]]
        if len(new) > 5:
            lines.append("- ...and %d more (see metrics.json)" % (len(new) - 5))
        if notify(cmd, "\n".join(lines), a.dry_run):
            next_active.update(new)
        else:
            send_failed = True
    if recovered:
        msg = "cache-health RECOVERED: " + ", ".join(k.split(":", 1)[0] + " " + k.split(":", 1)[1] for k in recovered)
        if not notify(cmd, msg, a.dry_run):
            send_failed = True
            for k in recovered:  # retry the recovery message next run
                next_active[k] = active[k]
    metrics["alerts"] = dict(active=sorted(next_active), new=sorted(new), recovered=sorted(recovered))
    if a.dry_run:
        print(json.dumps(metrics, indent=2))
        return 0
    write_atomic(os.path.join(sd, "metrics.json"), json.dumps(metrics, indent=2) + "\n")
    write_atomic(st_path, json.dumps(dict(active=next_active)) + "\n")
    hp = os.path.join(sd, "history.jsonl")
    hist = []
    try:
        with open(hp) as f:
            hist = f.read().splitlines()
    except OSError:
        pass
    hist.append(json.dumps(dict(ts=metrics["generated_at"], overall=metrics["overall"]["hit_pct"],
                                roles={r: metrics["roles"][r]["hit_pct"] for r in ROLES})))
    write_atomic(hp, "\n".join(hist[-HISTORY_KEEP:]) + "\n")
    return 3 if send_failed else 0  # state is saved above, so the next run retries


def shlex_split(s):
    import shlex
    return shlex.split(s) if s else ["true"]


def cmd_report(metrics):
    o = metrics["overall"]
    print("window: last %gh vs the %gd before it" % (metrics["window"]["recent_hours"], metrics["window"]["baseline_days"]))
    print("%-9s %5s %9s %7s %9s %7s %7s %5s" % ("role", "sess", "tok(M)", "hit%", "baseline", "write%", "1h%", "cmp/s"))
    for r in ROLES:
        x = metrics["roles"][r]
        f = lambda v: "-" if v is None else "%.1f" % v
        print("%-9s %5d %9.1f %7s %9s %7s %7s %5s" % (r, x["sessions"], x["tokens"] / 1e6, f(x["hit_pct"]),
              f(x["baseline_hit_pct"]), f(x["write_share_pct"]), f(x["w1h_pct"]), f(x["compactions_per_session"])))
    print("%-9s %5s %9.1f %7s %9s" % ("ALL", "", o["tokens"] / 1e6, "-" if o["hit_pct"] is None else "%.1f" % o["hit_pct"],
          "-" if o["baseline_hit_pct"] is None else "%.1f" % o["baseline_hit_pct"]))
    for t in metrics["top_offenders"][:5]:
        print("  offender %-8s %6.1fM tok %5s%% hit  %s" % (t["role"], t["tokens"] / 1e6, t["hit_pct"], t["title"][:50]))
    return 0


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("cmd", choices=["check", "report"])
    p.add_argument("--root", default=os.path.expanduser("~/.claude/projects"))
    p.add_argument("--state-dir", default=os.path.expanduser("~/.himmel/state/cache-health"))
    p.add_argument("--now", type=float, default=None)
    p.add_argument("--notify-cmd", default="")
    p.add_argument("--dry-run", action="store_true")
    p.add_argument("--recent-hours", type=float, default=24)
    p.add_argument("--baseline-days", type=float, default=7)
    p.add_argument("--drop-pts", type=float, default=3.0)
    p.add_argument("--clear-pts", type=float, default=2.0)
    p.add_argument("--role-min-tokens", type=float, default=5e6)
    p.add_argument("--session-min-tokens", type=float, default=1e6)
    p.add_argument("--session-hit", type=float, default=90.0)
    p.add_argument("--compactions-max", type=float, default=4.0)
    p.add_argument("--alert-roles", default="console,worker")  # subagent/other/bridge hit rates swing with cold starts: metrics only
    p.add_argument("--top", type=int, default=10)
    a = p.parse_args()
    now = a.now if a.now is not None else time.time()
    if not os.path.isdir(a.root):  # an absent input is not "no data": never clear alerts on it
        print("cache-health: transcript root not found: %s" % a.root, file=sys.stderr)
        return 2
    try:
        metrics, offenders = compute(a.root, now, a.recent_hours, a.baseline_days, a.session_min_tokens, a.top)
    except OSError as e:  # unreadable input is incomplete data: fail rather than clear alerts on it
        print("cache-health: cannot read transcripts: %s" % e, file=sys.stderr)
        return 2
    return cmd_check(a, metrics, offenders) if a.cmd == "check" else cmd_report(metrics)


if __name__ == "__main__":
    sys.exit(main())
