#!/usr/bin/env bash
# scripts/lanes/bench/scorecard/fleet-scorecard.sh - one per-worker scorecard for
# real fleet legs, claudex and native side by side.
#
# Platform guard: no .ps1 twin, by design. POSIX bash 3.2+ and python3 (stdlib
# only); it runs under git bash unchanged.
#
# Usage:
#   fleet-scorecard.sh (--manifest <x.fleet.json> | --doc <worker doc>)... [--since <ISO8601>]
#       [--prs <file>] [--cr-ledger <p>] [--verdicts <dir>] [--chief-doc <md>]...
#       [--denials <jsonl>] [--mirror <dir>] [--tz <zone>] [--out <local path>]
#
# Reads only the ledgers below and writes nothing but --out (default stdout).
# It makes no network call: --prs is a file the operator fetched beforehand,
#   gh pr list --state all --limit 5000 --json number,title,body,state,mergedAt,headRefName,headRefOid,mergeCommit
# An --out that names a URL is refused; the report is never published.
#
# Sources and defaults:
#   legs        each manifest's legs[] (doc, label, added, lane), a relative doc path read
#               against the manifest's dir; a bare --doc has no launch time and no lane, and
#               its label is scorecard-lib.sh's leg_label of the file name. --since keeps a
#               manifest leg added at or after it, a bare doc dated on or after its day.
#   chief docs  --chief-doc, else each manifest's sibling <stem>.md
#   verdicts    --verdicts, else verdicts/ beside the first worker doc (judge_accuracy's reader)
#   CR ledger   --cr-ledger, else cr_ledger_eval's default (findings folded by its fold)
#   denials     --denials, else ~/.himmel/state/classifier-denials.jsonl, joined on the doc's
#               resume_cwd worktree
#   mirror      --mirror, else judge_accuracy's Jira mirror (caused-by bugs)
#   clock       a bullet's HH:MM is read in --tz (default the local zone) on the launch day,
#               rolling to the next day when the clock goes backwards
#
# Per leg, output quality: judge GO / NO-GO records on the leg's PRs (console GOs left out)
# with Blocker and Major lines; CR findings by severity over the reviewed heads of the leg's
# branch; /pr-check rounds to the first head every critic scored with no critical and no
# important; pushes after the first READY (distinct heads named in later bullets); main reds
# a chief doc's MAIN-RED line pins on the PR; escapes within 7 days of the merge, from
# escapes.py's signals over the PRs and bugs dated up to that day.
# Fleet management: launch (the manifest's added) to the first LIVE and the first READY;
# chief interventions = FINDING asks + nudges + EXPANSION / REDIRECT requests + rulings
# beyond the asks (a ruling that answers an ask is not a second intervention; a nudge,
# request or prompt seen in both the worker doc and the chief doc counts once); protocol
# misses (LIVE shape, READY shape, unmarked or coined bullets, a relay with no SUCCESSION
# quote-back, a merge with no WRAPPED); delivery (a chief entry in the doc = inbox, a bus
# record = bus, else message); stalls (BLOCKED / HALTED / PARKED-BANK bullets, chief-doc idle
# ticks, prompt parks); guard denials; cost-eq per merged PR from its leg-burn line.
# A source that is absent prints `n/a (<reason>)`, never 0. Per lane: totals and medians.
#
# ponytail: interventions read only what lands in a doc; a SendMessage ruling to a native
# leg shows only through its RESOLVED bullet, and a nudge only when the chief doc logs it.
# Blocker and Major are counted by a line prefix in the verdict text; a severity header from
# write-verdict.sh is the upgrade path.
#
# Exit: 0 done; 2 refused input.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/scorecard-lib.sh
. "$HERE/lib/scorecard-lib.sh"

args=()
while [ $# -gt 0 ]; do
    case "$1" in
        --doc)
            [ $# -ge 2 ] || { echo "fleet-scorecard: --doc needs a value" >&2; exit 2; }
            args+=(--doc "$2" --label "$(leg_label "$(basename "$2" .md)")"); shift 2 ;;
        --label) echo "fleet-scorecard: --label is derived from --doc" >&2; exit 2 ;;
        *) args+=("$1"); shift ;;
    esac
done

exec python3 -I - "$HERE" ${args[@]+"${args[@]}"} <<'PY'
import argparse
import json
import os
import re
import statistics
import sys
from datetime import datetime, timedelta, timezone

HERE = sys.argv[1]
sys.path.insert(0, os.path.normpath(os.path.join(HERE, "..", "..", "..", "eval")))
import escapes  # noqa: E402  (it puts eval/lib, cr-ledger and judge-accuracy on sys.path)
import cr_ledger_eval  # noqa: E402
import judge_accuracy  # noqa: E402

MARKERS = {"LIVE", "FINDING", "RESOLVED", "READY", "BLOCKED", "HALTED", "WRAPPED", "PARKED-BANK", "RESUMED", "SUCCESSION"}
COINED = {"SHIPPED", "MERGED"}
BULLET = re.compile(r"^- (\d{1,2}):(\d{2}) (.*)$")
CHIEF = re.compile(r"^\[[^\]]+\] from=\S+ (.*)$")
SHA = re.compile(r"\b[0-9a-f]{40}\b")
READY_OK = re.compile(r"^READY \d+ [0-9a-f]{40} GREEN\b")
COST = re.compile(r"^leg-burn:.*\bcost-eq=([0-9.]+)k\b", re.M)
BLOCKER = re.compile(r"^\s*[-*]\s*(?:\*\*)?(?:BLOCKING|Blocker)\b", re.I | re.M)
MAJOR = re.compile(r"^\s*[-*]\s*(?:\*\*)?Major\b", re.I | re.M)
NUDGE = re.compile(r"\bnudge", re.I)
EXPAND = re.compile(r"\b(EXPANSION|REDIRECT)\b")
PROMPT = re.compile(r"AskUserQuestion|permission prompt|parked-on-prompt", re.I)
IDLE = re.compile(r"\b(IDLE|STUCK|PARKED)")
WEEK = timedelta(days=7)


def refuse(msg):
    print("fleet-scorecard: " + msg, file=sys.stderr)
    sys.exit(2)


def na(reason):
    return "n/a (%s)" % reason


def num(x):
    return "%g" % x


def read(path):
    with open(path, encoding="utf-8", errors="replace") as fh:
        return fh.read()


def args():
    ap = argparse.ArgumentParser(prog="fleet-scorecard.sh")
    ap.add_argument("here")
    ap.add_argument("--manifest", action="append", default=[])
    ap.add_argument("--doc", action="append", default=[])
    ap.add_argument("--label", action="append", default=[])
    ap.add_argument("--since")
    ap.add_argument("--prs")
    ap.add_argument("--cr-ledger")
    ap.add_argument("--verdicts")
    ap.add_argument("--chief-doc", action="append", default=[])
    ap.add_argument("--denials")
    ap.add_argument("--mirror")
    ap.add_argument("--tz")
    ap.add_argument("--out")
    a = ap.parse_args()
    if not a.manifest and not a.doc:
        refuse("give at least one --manifest or --doc")
    if a.out and re.match(r"^[A-Za-z][A-Za-z0-9+.-]*://", a.out):
        refuse("--out is a local path, never a URL: " + a.out)
    return a


def zone(name):
    from zoneinfo import ZoneInfo
    if not name:
        # a real zone, so a cohort that crosses a DST change keeps its local times
        try:
            if os.environ.get("TZ"):
                return ZoneInfo(os.environ["TZ"])
            with open("/etc/localtime", "rb") as fh:
                return ZoneInfo.from_file(fh)
        except Exception:
            return datetime.now().astimezone().tzinfo
    if name.upper() == "UTC":
        return timezone.utc
    try:
        return ZoneInfo(name)
    except Exception:
        refuse("unknown --tz: " + name)


def legs_of(a, since):
    legs, seen = [], {}
    for m in a.manifest:
        try:
            data = json.loads(read(m))
        except (OSError, ValueError) as e:
            refuse("unreadable manifest %s: %s" % (m, e))
        for leg in data.get("legs") or []:
            doc = leg.get("doc") or ""
            if doc and not os.path.isabs(doc):
                doc = os.path.join(os.path.dirname(os.path.abspath(m)), doc)
            added = judge_accuracy.when(leg.get("added") or "")
            if since and (added is None or added < since):
                continue
            key = os.path.realpath(doc)
            if key in seen:
                old = seen[key]
                if added and (old["added"] is None or added < old["added"]):
                    old["added"] = added
                continue
            seen[key] = {"doc": doc, "label": leg.get("label") or os.path.basename(doc),
                         "lane": leg.get("lane") or None, "added": added}
            legs.append(seen[key])
    for doc, label in zip(a.doc, a.label):
        key = os.path.realpath(doc)
        if key in seen:
            continue
        day = re.search(r"(\d{4}-\d{2}-\d{2})\.md$", doc)
        if since and day and day.group(1) < since.date().isoformat():
            continue
        seen[key] = {"doc": doc, "label": label, "lane": None, "added": None}
        legs.append(seen[key])
    legs.sort(key=lambda g: (int(re.sub(r"\D", "", g["label"]) or 0), g["label"]))
    return legs


def parse_doc(leg, tz):
    """The doc's resume_cwd and its bullets: (dt, marker, text, is_chief)."""
    try:
        text = read(leg["doc"])
    except OSError:
        return None
    m = re.search(r"^resume_cwd: *(\S+)", text, re.M)
    leg["cwd"] = m.group(1) if m else None
    if leg["added"]:
        prev = leg["added"].astimezone(tz)
    else:
        day = re.search(r"(\d{4}-\d{2}-\d{2})\.md$", leg["doc"])
        prev = datetime.fromisoformat(day.group(1)).replace(tzinfo=tz) if day else None
    bullets = []
    for line in text.splitlines():
        b = BULLET.match(line)
        if not b:
            continue
        dt = None
        if prev is not None:
            dt = prev.replace(hour=int(b.group(1)), minute=int(b.group(2)), second=0, microsecond=0)
            # sections interleave, so only a jump back of half a day is midnight
            if dt + timedelta(hours=12) < prev:
                dt += timedelta(days=1)
            prev = max(prev, dt)
        rest = b.group(3)
        c = CHIEF.match(rest)
        word = rest.split()[0].rstrip(":—") if rest.split() and not c else ""
        if rest.startswith(("bus-adopt:", "bus #", "SUCCESSION accepted:")):
            word = "SUCCESSION" if rest.startswith("SUCCESSION") else "script"
        bullets.append({"dt": dt, "word": word, "text": c.group(1) if c else rest, "chief": bool(c),
                        "bus": rest.startswith("bus #"), "hm": clock(line)})
    return bullets


def clock(line):
    """A bullet's HH:MM as minutes past midnight, or None."""
    b = BULLET.match(line)
    return int(b.group(1)) * 60 + int(b.group(2)) if b else None


def events(worker, chief):
    """One intervention logged in both docs lands within minutes in each: pair those, count the rest."""
    left = [t for t in worker if t is not None]
    n = len(worker)
    for t in chief:
        hit = next((w for w in left if t is not None and min(abs(t - w), 1440 - abs(t - w)) <= 5), None)
        if hit is None:
            n += 1
        else:
            left.remove(hit)
    return n


def minutes(a, b):
    return round((b - a).total_seconds() / 60)


def leg_prs(leg, bullets, prs):
    branch = None
    if leg.get("cwd"):
        branch = os.path.basename(leg["cwd"].rstrip("/")).replace("+", "/", 1)
    leg["branch"] = branch
    cited = {int(m.group(1)) for b in bullets if not b["chief"] and b["word"] == "READY"
             for m in [re.match(r"READY (\d+)", b["text"])] if m}
    if prs is None:
        return None
    return [p for p in prs if (branch and p.get("headRefName") == branch) or p.get("number") in cited]


def judge_cell(mine, recs, vdir):
    if recs is None:
        return na("no verdicts dir: %s" % vdir), None
    nums = {p["number"] for p in mine}
    go = nogo = blk = maj = 0
    for r in recs:
        if r["pr"] not in nums or r["console"]:
            continue
        if r["verdict"] == "GO":
            go += 1
        else:
            nogo += 1
        t = read(os.path.join(vdir, r["qid"], r["name"] + ".md"))
        blk += len(BLOCKER.findall(t))
        maj += len(MAJOR.findall(t))
    cell = "GO %d, NO-GO %d" % (go, nogo)
    if blk or maj:
        cell += " (blocker %d, major %d)" % (blk, maj)
    return cell, (go, nogo, blk, maj)


def cr_cells(branch, ledger_rows, folded, ledger):
    if ledger_rows is None:
        return na("no CR ledger: %s" % ledger), na("no CR ledger: %s" % ledger), None, None
    if not branch:
        return na("no resume_cwd"), na("no resume_cwd"), None, None
    sev = {"critical": 0, "important": 0, "suggestion": 0}
    for f in folded:
        if f["branch"] == branch and f["severity"] in sev:
            sev[f["severity"]] += 1
    heads, scores = [], {}
    for r in ledger_rows:
        if r.get("branch") != branch or r.get("kind") not in ("score", "avail", "finding"):
            continue
        h = r.get("head") or ""
        if h not in heads:
            heads.append(h)
        if r.get("kind") == "score":
            scores.setdefault(h, []).append(not (r.get("critical") or r.get("important")))
    if not heads:
        return "not reviewed", "not reviewed", None, None
    findings = "crit %d, imp %d, sug %d over %d heads" % (sev["critical"], sev["important"], sev["suggestion"], len(heads))
    scored = [h for h in heads if h in scores]
    rounds = next((i + 1 for i, h in enumerate(scored) if all(scores[h])), None)
    rcell = str(rounds) if rounds else "not clean after %d" % len(scored)
    return findings, rcell, sum(sev.values()), rounds


def pushes_after_ready(bullets, mine):
    first = next((i for i, b in enumerate(bullets) if not b["chief"] and b["word"] == "READY"), None)
    if first is None:
        return na("no READY yet"), None
    m = SHA.search(bullets[first]["text"])
    skip = {m.group(0)} if m else set()
    skip |= {(p.get("mergeCommit") or {}).get("oid") for p in mine or []}
    later = {s for b in bullets[first + 1:] if not b["chief"] and b["word"] != "WRAPPED"
             for s in SHA.findall(b["text"])} - skip
    return str(len(later)), len(later)


def escapes_cell(merged, prs, bugs):
    counts = {}
    for p in merged:
        cut = judge_accuracy.when(p["mergedAt"]) + WEEK
        sub = [q for q in prs if q.get("mergedAt") and judge_accuracy.when(q["mergedAt"]) <= cut]
        sub_bugs = [b for b in bugs or [] if not b["created"] or b["created"] <= cut]
        _, sig, _ = escapes.signals(sub, sub_bugs)
        for kind, _lv in sig.get(p["number"], ()):
            counts[kind] = counts.get(kind, 0) + 1
    cell = ", ".join("%s %d" % (k, counts[k]) for k in sorted(counts)) or "none"
    if bugs is None:
        cell += " (caused-by n/a: no Jira mirror)"
    return cell


def score(leg, ctx):
    q, f, v = {}, {}, {}
    bullets = parse_doc(leg, ctx["tz"])
    lane = leg["lane"] or "unknown"
    q["lane"] = f["lane"] = lane
    t = re.match(r"([A-Z][A-Z0-9]+-\d+)-", os.path.basename(leg["doc"]))
    q["ticket"] = t.group(1) if t else na("no ticket in doc name")
    if bullets is None:
        reason = na("no worker doc: %s" % leg["doc"])
        for k in ("PR", "state", "judge", "cr", "rounds", "pushes", "reds", "escapes"):
            q[k] = reason
        for k in ("live", "ready", "interventions", "breakdown", "protocol", "delivery", "stalls", "denials", "cost"):
            f[k] = reason
        return q, f, {"merged": None, "in_flight": None}
    worker = [b for b in bullets if not b["chief"]]
    chief_entries = [b for b in bullets if b["chief"]]
    mine = leg_prs(leg, bullets, ctx["prs"])
    merged = [p for p in mine or [] if p.get("mergedAt")]
    wrapped = any(b["word"] == "WRAPPED" for b in worker)

    # output quality
    if mine is None:
        q["PR"] = na("no --prs")
    else:
        q["PR"] = ", ".join(str(p["number"]) for p in sorted(mine, key=lambda p: p["number"])) or "none"
    if mine is None:
        q["state"] = na("no --prs")
        v["merged"] = v["in_flight"] = None
    else:
        q["state"] = "merged" if merged else ("wrapped unmerged" if wrapped else "in flight")
        v["merged"] = bool(merged)
        v["in_flight"] = q["state"] == "in flight"
    nopr = na("no --prs") if mine is None else (na("no PR") if not mine else None)
    if nopr:
        q["judge"] = nopr
    else:
        q["judge"], v["judge"] = judge_cell(mine, ctx["recs"], ctx["vdir"])
    q["cr"], q["rounds"], v["cr"], v["rounds"] = cr_cells(leg.get("branch"), ctx["ledger_rows"], ctx["folded"], ctx["ledger"])
    q["pushes"], _ = pushes_after_ready(bullets, mine)
    if nopr:
        q["reds"] = nopr
    elif not ctx["chief_text"]:
        q["reds"] = na("no chief doc")
    else:
        nums = {p["number"] for p in mine}
        q["reds"] = str(sum(1 for m in re.finditer(r"MAIN-RED\b.*?caused-by:\s*#(\d+)", ctx["chief_text"])
                            if int(m.group(1)) in nums))
    q["escapes"] = nopr or (escapes_cell(merged, ctx["prs"], ctx["bugs"]) if merged else na("not merged"))

    # fleet management
    live = next((b for b in worker if b["word"] == "LIVE"), None)
    ready = next((b for b in worker if b["word"] == "READY"), None)
    for key, b, what in (("live", live, "LIVE"), ("ready", ready, "READY")):
        if not leg["added"]:
            f[key] = na("no manifest launch time")
        elif not b:
            f[key] = na("no %s bullet" % what if what == "LIVE" else "no READY yet")
        else:
            v[key] = minutes(leg["added"], b["dt"])
            f[key] = "%dm" % v[key]
    asks = sum(1 for b in worker if b["word"] == "FINDING")
    resolved = sum(1 for b in worker if b["word"] == "RESOLVED")
    relays = [b for b in chief_entries if "SUCCESSION relay" in b["text"]]
    nudge_at = [b["hm"] for b in chief_entries if b not in relays and NUDGE.search(b["text"])]
    expand_at = [b["hm"] for b in chief_entries
                 if b not in relays and not NUDGE.search(b["text"]) and EXPAND.search(b["text"])]
    rulings = max(resolved, len(chief_entries) - len(relays) - len(nudge_at) - len(expand_at))
    label = re.compile(r"\b%s\b" % re.escape(leg["label"]))
    stem = os.path.splitext(os.path.basename(leg["doc"]))[0]
    chief_lines = [ln for ln in ctx["chief_text"].splitlines() if label.search(ln)] if ctx["chief_text"] else []
    nudges = events(nudge_at, [clock(ln) for ln in chief_lines if NUDGE.search(ln)])
    expands = events(expand_at, [clock(ln) for ln in chief_lines if not NUDGE.search(ln) and EXPAND.search(ln)])
    if ctx["chief_text"]:
        v["interventions"] = asks + nudges + expands + max(0, rulings - asks)
        f["interventions"] = str(v["interventions"])
        f["breakdown"] = "%d/%d/%d/%d" % (asks, rulings, nudges, expands)
    else:
        f["interventions"] = na("no chief doc")
        f["breakdown"] = "%d/%d/n/a/n/a" % (asks, rulings)
    miss = []
    if not live:
        miss.append("no LIVE")
    elif not (re.search(r"`[^`]+`", live["text"]) and "effort=" in live["text"] and "model=" in live["text"]):
        miss.append("live-shape")
    bad_ready = sum(1 for b in worker if b["word"] == "READY" and not READY_OK.match(b["text"]))
    if bad_ready:
        miss.append("ready-shape %d" % bad_ready)
    unmarked = sum(1 for b in worker if b["word"] not in MARKERS | COINED | {"script"})
    coined = sum(1 for b in worker if b["word"] in COINED)
    if unmarked:
        miss.append("unmarked %d" % unmarked)
    if coined:
        miss.append("coined %d" % coined)
    if relays and not any(b["word"] == "SUCCESSION" and b["text"].startswith("SUCCESSION accepted") for b in worker):
        miss.append("no succession quote-back")
    if merged and not wrapped:
        miss.append("no WRAPPED")
    f["protocol"] = "miss: " + ", ".join(miss) if miss else "ok"
    via = [w for w, hit in (("inbox", chief_entries), ("bus", [b for b in worker if b["bus"]])) if hit]
    f["delivery"] = "+".join(via) or "message"
    blocked = sum(1 for b in worker if b["word"] in ("BLOCKED", "HALTED", "PARKED-BANK"))
    prompt = events([b["hm"] for b in worker if PROMPT.search(b["text"])],
                    [clock(ln) for ln in chief_lines if PROMPT.search(ln)])
    stalls = ["blocked %d" % blocked] if blocked else []
    if ctx["chief_text"]:
        idle = sum(1 for ln in ctx["chief_text"].splitlines() if "slug=" in ln and stem in ln and IDLE.search(ln))
        if idle:
            stalls.append("idle %d" % idle)
    else:
        stalls.append("idle n/a (no chief doc)")
    if prompt:
        stalls.append("prompt %d" % prompt)
    f["stalls"] = ", ".join(stalls) or "none"
    if ctx["denials"] is None:
        f["denials"] = na("no denial log: %s" % ctx["denials_path"])
    elif not leg.get("cwd"):
        f["denials"] = na("no resume_cwd")
    else:
        wt = os.path.basename(leg["cwd"].rstrip("/"))
        v["denials"] = sum(1 for d in ctx["denials"] if (d.get("cwd") == leg["cwd"] or d.get("session_title") == wt)
                           and (ctx["since"] is None or (judge_accuracy.when(d.get("ts") or "") or ctx["since"]) >= ctx["since"]))
        f["denials"] = str(v["denials"])
    if mine is None:
        f["cost"] = na("no --prs")
    elif not merged:
        f["cost"] = na("not merged")
    else:
        costs = [COST.search(p.get("body") or "") for p in merged]
        if not all(costs):
            f["cost"] = na("no leg-burn line")
        else:
            v["costs"] = [float(c.group(1)) for c in costs]
            v["cost"] = sum(v["costs"]) / len(merged)
            f["cost"] = "%.1fk" % v["cost"]
    return q, f, v


def lane_rows(scored):
    lanes = {}
    for leg, q, f, v in scored:
        lanes.setdefault(q["lane"], []).append(v)
    out = []

    def total(vals):
        known = [x for x in vals if x is not None]
        if not known:
            return "n/a"
        gap = len(vals) - len(known)
        return num(sum(known)) + (" (n/a %d)" % gap if gap else "")

    def count(flags):
        return "n/a" if None in flags else str(sum(1 for x in flags if x))

    def median(vals, unit=""):
        vals = [x for x in vals if x is not None]
        return (num(statistics.median(vals)) + unit) if vals else "n/a"

    for lane in sorted(lanes):
        vs = lanes[lane]
        j = [v.get("judge") for v in vs]
        cost = [c for v in vs for c in v.get("costs", [])]
        out.append([lane, str(len(vs)), count([v.get("merged") for v in vs]),
                    count([v.get("in_flight") for v in vs]),
                    total([x and x[0] for x in j]), total([x and x[1] for x in j]),
                    total([x and x[2] for x in j]), total([x and x[3] for x in j]),
                    total([v.get("cr") for v in vs]), median([v.get("rounds") for v in vs]),
                    median([v.get("live") for v in vs], "m"), median([v.get("ready") for v in vs], "m"),
                    total([v.get("interventions") for v in vs]), median([v.get("interventions") for v in vs]),
                    total([v.get("denials") for v in vs]),
                    ("%.1fk" % statistics.median(cost)) if cost else "n/a"])
    return out


def table(head, rows):
    lines = ["| " + " | ".join(head) + " |", "|" + "---|" * len(head)]
    lines += ["| " + " | ".join(r) + " |" for r in rows]
    return "\n".join(lines)


def main():
    a = args()
    tz = zone(a.tz)
    since = None
    if a.since:
        since = judge_accuracy.when(a.since)
        if since is None:
            refuse("--since is not an ISO-8601 timestamp: " + a.since)
    legs = legs_of(a, since)
    ctx = {"tz": tz, "since": since}
    ctx["prs"] = None
    if a.prs:
        try:
            ctx["prs"] = judge_accuracy.load_json(a.prs, "--prs")
        except ValueError as e:
            refuse(str(e))
    first_doc = legs[0]["doc"] if legs else (a.manifest or a.doc)[0]
    ctx["vdir"] = a.verdicts or os.path.join(os.path.dirname(os.path.abspath(first_doc)), "verdicts")
    ctx["recs"] = judge_accuracy.load_verdicts(ctx["vdir"])[0] if os.path.isdir(ctx["vdir"]) else None
    ledger = a.cr_ledger or os.environ.get("CR_LEDGER")
    if not ledger:
        try:
            ledger = cr_ledger_eval.default_ledger()
        except SystemExit:
            ledger = "(not in a git checkout)"
    ctx["ledger"] = ledger
    ctx["ledger_rows"] = cr_ledger_eval.load(ledger, None)[0] if os.path.isfile(ledger) else None
    ctx["folded"] = cr_ledger_eval.fold(ctx["ledger_rows"]) if ctx["ledger_rows"] is not None else []
    chief_docs = a.chief_doc or [re.sub(r"\.fleet\.json$", ".md", m) for m in a.manifest]
    found = [c for c in chief_docs if os.path.isfile(c)]
    ctx["chief_text"] = "\n".join(read(c) for c in found)
    ctx["denials_path"] = a.denials or os.path.expanduser("~/.himmel/state/classifier-denials.jsonl")
    ctx["denials"] = None
    ctx["denials_bad"] = 0
    if os.path.isfile(ctx["denials_path"]):
        ctx["denials"] = []
        for line in read(ctx["denials_path"]).splitlines():
            if not line.strip():
                continue
            try:
                row = json.loads(line)
            except ValueError:
                row = None
            if isinstance(row, dict):
                ctx["denials"].append(row)
            else:
                ctx["denials_bad"] += 1
    mirror = a.mirror or judge_accuracy.MIRROR
    try:
        ctx["bugs"] = judge_accuracy.load_bugs(mirror)
    except ValueError:
        ctx["bugs"] = None

    scored = [(leg,) + score(leg, ctx) for leg in legs]
    lanes = {}
    for _, q, _, _ in scored:
        lanes[q["lane"]] = lanes.get(q["lane"], 0) + 1
    out = ["# Fleet scorecard", "",
           "cohort: %d legs (%s)%s; local report, never published" % (
               len(legs), ", ".join("%s %d" % (k, lanes[k]) for k in sorted(lanes)) or "none",
               ", since " + a.since if a.since else ""), "",
           "## Output quality", "",
           table(["leg", "lane", "ticket", "PR", "state", "judge", "CR findings per reviewed head", "rounds to clean",
                  "pushes after READY", "main reds caused", "escapes 7d"],
                 [[leg["label"], q["lane"], q["ticket"], q["PR"], q["state"], q["judge"], q["cr"], q["rounds"],
                   q["pushes"], q["reds"], q["escapes"]] for leg, q, _, _ in scored]), "",
           "## Fleet management", "",
           table(["leg", "lane", "launch to LIVE", "launch to READY", "interventions", "asks/rulings/nudges/expansions",
                  "protocol", "delivery", "stalls", "denials", "cost-eq per merged PR"],
                 [[leg["label"], f["lane"], f["live"], f["ready"], f["interventions"], f["breakdown"], f["protocol"],
                   f["delivery"], f["stalls"], f["denials"], f["cost"]] for leg, _, f, _ in scored]), "",
           "## Per lane", "",
           table(["lane", "legs", "merged", "in flight", "judge GO", "judge NO-GO", "blockers", "majors", "CR findings",
                  "median rounds to clean", "median launch to LIVE", "median launch to READY", "interventions",
                  "median interventions", "denials", "median cost-eq per merged PR"], lane_rows(scored)), "",
           "## Sources", "",
           "- manifests: %s" % (", ".join(a.manifest) or "none (bare --doc legs)"),
           "- chief docs: %s%s" % (", ".join(found) or na("none found"),
                                   " (missing: %s)" % ", ".join(c for c in chief_docs if c not in found)
                                   if found and len(found) < len(chief_docs) else ""),
           "- verdicts: %s" % (ctx["vdir"] if ctx["recs"] is not None else na("absent: " + ctx["vdir"])),
           "- CR ledger: %s" % (ledger if ctx["ledger_rows"] is not None else na("absent: " + ledger)),
           "- PRs: %s" % (a.prs or na("no --prs")),
           "- denials: %s%s" % (ctx["denials_path"] if ctx["denials"] is not None else na("absent: " + ctx["denials_path"]),
                                " (%d unreadable row%s)" % (ctx["denials_bad"], "" if ctx["denials_bad"] == 1 else "s")
                                if ctx["denials_bad"] else ""),
           "- Jira mirror: %s" % (mirror if ctx["bugs"] is not None else na("absent: " + mirror)), ""]
    report = "\n".join(out)
    if a.out:
        try:
            with open(a.out, "w", encoding="utf-8") as fh:
                fh.write(report)
        except OSError as e:
            refuse("cannot write --out %s: %s" % (a.out, e))
    else:
        sys.stdout.write(report)
    return 0


sys.exit(main())
PY
