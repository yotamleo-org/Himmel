#!/usr/bin/env bash
# scripts/lanes/bench/scorecard/fleet-scorecard.sh - one per-worker scorecard for
# real fleet workers, claudex and native side by side.
#
# Platform guard: POSIX bash 3.2+ and python3 (stdlib only).
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
#   workers        each manifest's workers[] (doc, label, added, lane), a relative doc path read
#               against the manifest's dir; a bare --doc has no launch time and no lane, and
#               its label is scorecard-lib.sh's worker_label of the file name. --since keeps a
#               manifest worker added at or after it, a bare doc dated on or after its day.
#   chief docs  --chief-doc, else each manifest's sibling <stem>.md
#   verdicts    --verdicts, else verdicts/ beside the first worker doc (judge_accuracy's reader)
#   CR ledger   --cr-ledger, else cr_ledger_eval's default (findings folded by its fold)
#   denials     --denials, else ~/.himmel/state/classifier-denials.jsonl, joined on the doc's
#               resume_cwd worktree; a doc that resumes in the primary checkout has none
#   mirror      --mirror, else judge_accuracy's Jira mirror (caused-by bugs)
#   clock       a bullet's HH:MM is read in --tz (default the local zone) on the launch day,
#               rolling to the next day when the clock goes backwards
#
# Per worker, output quality: judge GO / NO-GO records on the worker's PRs (chief GOs left out)
# with Blocker and Major lines; CR findings by severity over the reviewed heads of the worker's
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
# record = bus, else message); stalls (BLOCKED / HALTED / parked bullets, chief-doc idle
# ticks, prompt parks); guard denials; cost-eq per merged PR from its worker-burn line.
# A source that is absent prints `n/a (<reason>)`, never 0. Per lane: totals and medians.
#
# ponytail: interventions read only what lands in a doc; a SendMessage ruling to a native
# worker shows only through its RESOLVED bullet, and a nudge only when the chief doc logs it.
# Blocker and Major are counted by a line prefix in the verdict text; a severity header from
# write-verdict.sh is the upgrade path.
#
#   fleet-scorecard.sh --exposure-screen SCREEN.json --out SCREEN-RESULT.json
#       The free B1a screen: over a frozen, complete inventory of worker parents, the
#       share of priced cost in the first five parent calls strictly after each compaction boundary.
#       NO-OP below 3 %, QUALIFIED at 3 % or more, INCONCLUSIVE when coverage is incomplete. Reads
#       only the files SCREEN names (each pinned by sha256), runs model-price.mjs's loader and
#       validator and compaction-trigger-report.py --json --min-peak 0, and writes only --out.
#       It makes no model call, no Jira write and no network call. Exit 0 NO-OP or QUALIFIED,
#       3 INCONCLUSIVE, 2 malformed input or an unsupported lever (B2).
#
# Exit: 0 done; 2 refused input; 3 INCONCLUSIVE (--exposure-screen only).
# Platform guard for --exposure-screen: also node, for model-price.mjs.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/scorecard-lib.sh
. "$HERE/lib/scorecard-lib.sh"

args=()
while [ $# -gt 0 ]; do
    case "$1" in
        --doc)
            [ $# -ge 2 ] || { echo "fleet-scorecard: --doc needs a value" >&2; exit 2; }
            args+=(--doc "$2" --label "$(worker_label "$(basename "$2" .md)")"); shift 2 ;;
        --doc=*)
            v="${1#--doc=}"
            args+=(--doc "$v" --label "$(worker_label "$(basename "$v" .md)")"); shift ;;
        --label|--label=*) echo "fleet-scorecard: --label is derived from --doc" >&2; exit 2 ;;
        *) args+=("$1"); shift ;;
    esac
done

exec python3 -I - "$HERE" ${args[@]+"${args[@]}"} <<'PY'
import argparse
import calendar
import hashlib
import json
import os
import re
import statistics
import subprocess
import sys
from datetime import date, datetime, timedelta, timezone

HERE = sys.argv[1]
sys.path.insert(0, os.path.normpath(os.path.join(HERE, "..", "..", "..", "eval")))
import escapes  # noqa: E402  (it puts eval/lib, cr-ledger and judge-accuracy on sys.path)
import cr_ledger_eval  # noqa: E402
import judge_accuracy  # noqa: E402

sys.path.insert(0, os.path.normpath(os.path.join(HERE, "..", "..", "..", "lib")))
import status_marker  # noqa: E402

COINED = {"SHIPPED", "MERGED"}
BULLET = re.compile(r"^- (\d{1,2}):(\d{2}) (.*)$")
CHIEF = re.compile(r"^\[[^\]]+\] from=\S+ (.*)$")
SHA = re.compile(r"\b[0-9a-f]{40}\b")
READY_OK = re.compile(r"^READY \d+ [0-9a-f]{40} GREEN\b")
COST = re.compile(r"^(?:worker|leg)-burn:.*\bcost-eq=([0-9.]+)k\b", re.M)
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
    ap = argparse.ArgumentParser(prog="fleet-scorecard.sh", allow_abbrev=False)
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
    ap.add_argument("--exposure-screen")
    a = ap.parse_args()
    if a.out and re.match(r"^[A-Za-z][A-Za-z0-9+.-]*://", a.out):
        refuse("--out is a local path, never a URL: " + a.out)
    if a.exposure_screen is not None:
        if not a.out:
            refuse("--exposure-screen needs --out")
        if any([a.manifest, a.doc, a.since, a.prs, a.cr_ledger, a.verdicts, a.chief_doc, a.denials, a.mirror, a.tz]):
            refuse("--exposure-screen takes only --out")
        return a
    if not a.manifest and not a.doc:
        refuse("give at least one --manifest or --doc")
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


def workers_of(a, since):
    workers, seen = [], {}
    for m in a.manifest:
        try:
            data = json.loads(read(m))
        except (OSError, ValueError) as e:
            refuse("unreadable manifest %s: %s" % (m, e))
        for wk in data.get("workers") or data.get("legs") or []:
            doc = wk.get("doc") or ""
            if doc and not os.path.isabs(doc):
                doc = os.path.join(os.path.dirname(os.path.abspath(m)), doc)
            added = judge_accuracy.when(wk.get("added") or "")
            if since and (added is None or added < since):
                continue
            key = os.path.realpath(doc)
            if key in seen:
                old = seen[key]
                if added and (old["added"] is None or added < old["added"]):
                    old["added"] = added
                continue
            seen[key] = {"doc": doc, "label": wk.get("label") or os.path.basename(doc),
                         "lane": wk.get("lane") or None, "added": added}
            workers.append(seen[key])
    for doc, label in zip(a.doc, a.label):
        key = os.path.realpath(doc)
        if key in seen:
            continue
        day = re.search(r"(\d{4}-\d{2}-\d{2})\.md$", doc)
        if since and day and day.group(1) < since.date().isoformat():
            continue
        seen[key] = {"doc": doc, "label": label, "lane": None, "added": None}
        workers.append(seen[key])
    workers.sort(key=lambda g: (int(re.sub(r"\D", "", g["label"]) or 0), g["label"]))
    return workers


def parse_doc(wk, tz):
    """The doc's resume_cwd and its bullets: (dt, marker, text, is_chief)."""
    try:
        text = read(wk["doc"])
    except OSError:
        return None
    m = re.search(r"^resume_cwd: *(\S+)", text, re.M)
    wk["cwd"] = m.group(1) if m else None
    if wk["added"]:
        prev = wk["added"].astimezone(tz)
    else:
        day = re.search(r"(\d{4}-\d{2}-\d{2})\.md$", wk["doc"])
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
        word = (status_marker.parse(line) or rest.split()[0].rstrip(":—")) if rest.split() and not c else ""
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


def worker_prs(wk, bullets, prs):
    branch = None
    if wk.get("cwd"):
        branch = os.path.basename(wk["cwd"].rstrip("/")).replace("+", "/", 1)
    wk["branch"] = branch
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


def score(wk, ctx):
    q, f, v = {}, {}, {}
    bullets = parse_doc(wk, ctx["tz"])
    lane = wk["lane"] or "unknown"
    q["lane"] = f["lane"] = lane
    t = re.match(r"([A-Z][A-Z0-9]+-\d+)-", os.path.basename(wk["doc"]))
    q["ticket"] = t.group(1) if t else na("no ticket in doc name")
    if bullets is None:
        reason = na("no worker doc: %s" % wk["doc"])
        for k in ("PR", "state", "judge", "cr", "rounds", "pushes", "reds", "escapes"):
            q[k] = reason
        for k in ("live", "ready", "interventions", "breakdown", "protocol", "delivery", "stalls", "denials", "cost"):
            f[k] = reason
        return q, f, {"merged": None, "in_flight": None}
    worker = [b for b in bullets if not b["chief"]]
    chief_entries = [b for b in bullets if b["chief"]]
    mine = worker_prs(wk, bullets, ctx["prs"])
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
    q["cr"], q["rounds"], v["cr"], v["rounds"] = cr_cells(wk.get("branch"), ctx["ledger_rows"], ctx["folded"], ctx["ledger"])
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
        if not wk["added"]:
            f[key] = na("no manifest launch time")
        elif not b:
            f[key] = na("no %s bullet" % what if what == "LIVE" else "no READY yet")
        else:
            v[key] = minutes(wk["added"], b["dt"])
            f[key] = "%dm" % v[key]
    asks = sum(1 for b in worker if b["word"] == "FINDING")
    resolved = sum(1 for b in worker if b["word"] == "RESOLVED")
    relays = [b for b in chief_entries if "SUCCESSION relay" in b["text"]]
    nudge_at = [b["hm"] for b in chief_entries if b not in relays and NUDGE.search(b["text"])]
    expand_at = [b["hm"] for b in chief_entries
                 if b not in relays and not NUDGE.search(b["text"]) and EXPAND.search(b["text"])]
    rulings = max(resolved, len(chief_entries) - len(relays) - len(nudge_at) - len(expand_at))
    label = re.compile(r"\b%s\b" % re.escape(wk["label"]))
    stem = os.path.splitext(os.path.basename(wk["doc"]))[0]
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
    unmarked = sum(1 for b in worker if not status_marker.parse("- " + b["word"])
                   and b["word"] not in COINED | {"script", "SUCCESSION"})
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
    blocked = sum(1 for b in worker if b["word"] in ("BLOCKED", "HALTED") or status_marker.is_parked(b["word"]))
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
    elif not wk.get("cwd"):
        f["denials"] = na("no resume_cwd")
    elif "/.claude/worktrees/" not in wk["cwd"]:
        # the primary checkout is shared by the chief and every session in it
        f["denials"] = na("no worktree: %s" % wk["cwd"])
    else:
        wt = os.path.basename(wk["cwd"].rstrip("/"))
        v["denials"] = sum(1 for d in ctx["denials"] if (d.get("cwd") == wk["cwd"] or d.get("session_title") == wt)
                           and (ctx["since"] is None or (judge_accuracy.when(d.get("ts") or "") or ctx["since"]) >= ctx["since"]))
        f["denials"] = str(v["denials"])
    if mine is None:
        f["cost"] = na("no --prs")
    elif not merged:
        f["cost"] = na("not merged")
    else:
        costs = [COST.search(p.get("body") or "") for p in merged]
        if not all(costs):
            f["cost"] = na("no worker-burn line")
        else:
            v["costs"] = [float(c.group(1)) for c in costs]
            v["cost"] = sum(v["costs"]) / len(merged)
            f["cost"] = "%.1fk" % v["cost"]
    return q, f, v


def lane_rows(scored):
    lanes = {}
    for wk, q, f, v in scored:
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


SCREEN_KEYS = {"schema", "lever", "window", "inventory", "export_set", "validation"}
INVENTORY_KEYS = {"window", "scope_root", "complete", "population_review", "top_level_files", "exclusions"}
ENTRY_KEYS = {"relative_path", "session", "role", "role_evidence"}
ROLES = {"worker", "chief", "relay", "other", "unknown"}
WHOLE_FILE = ("1970-01-01T00:00:00Z", "9999-12-31T23:59:59Z")
HEX64 = re.compile(r"^[0-9a-f]{64}$")
RFC3339 = re.compile(r"^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.(\d+))?(Z|[+-]\d{2}:\d{2})$")
MIN_PARENTS = 12
NODE_LOAD = """
import { pathToFileURL } from 'node:url';
const m = await import(pathToFileURL(process.argv[2]).href);
const out = (validation, exports) => process.stdout.write(JSON.stringify({ validation, exports }));
try {
  const { exports, expectedSessions, expectations } = m.loadExportSet(process.argv[1]);
  const validation = m.validateCallExport(exports, expectedSessions, expectations);
  out(validation, exports.map((e) => {
    let manifest = null;
    try { manifest = JSON.parse(e.manifestBytes); } catch { manifest = null; }
    return { lines: e.lines, manifest };
  }));
} catch (e) {
  if (!(e instanceof m.CallExportLoadError)) throw e;
  out(e.validation, []);
}
"""


def parse_us(s):
    m = RFC3339.match(s) if isinstance(s, str) else None
    if not m:
        return None
    try:
        t = datetime(*(int(m.group(i)) for i in range(1, 7)), tzinfo=timezone.utc)
    except ValueError:
        return None
    off = m.group(8)
    shift = 0 if off == "Z" else (1 if off[0] == "+" else -1) * (int(off[1:3]) * 3600 + int(off[4:6]) * 60)
    frac = int((m.group(7) or "")[:6].ljust(6, "0"))
    return (calendar.timegm(t.timetuple()) - shift) * 1_000_000 + frac


def berlin_midnight(us):
    from zoneinfo import ZoneInfo
    if us % 1_000_000:
        return None
    dt = datetime.fromtimestamp(us // 1_000_000, ZoneInfo("Europe/Berlin"))
    return dt.date() if (dt.hour, dt.minute, dt.second) == (0, 0, 0) else None


def json_of(raw, what):
    try:
        return json.loads(raw)
    except ValueError as e:
        refuse("%s is not readable JSON: %s" % (what, e))


def ref_of(obj, what, base):
    if (not isinstance(obj, dict) or set(obj) != {"path", "sha256"} or not isinstance(obj["path"], str)
            or not obj["path"] or not isinstance(obj["sha256"], str) or not HEX64.match(obj["sha256"])):
        refuse("malformed ref: " + what)
    path = os.path.realpath(os.path.join(base, obj["path"]))
    try:
        with open(path, "rb") as fh:
            raw = fh.read()
    except OSError as e:
        refuse("unreadable ref %s: %s" % (what, e))
    return path, raw, hashlib.sha256(raw).hexdigest() == obj["sha256"]


def screen_result(a, disposition, why, selected=0, straddlers=0, num=None, den=None):
    complete = disposition != "INCONCLUSIVE"
    res = {"schema": 1, "kind": "exposure-screen", "lever": "B1", "coverage": "complete" if complete else "incomplete",
           "selected": selected, "excluded_straddlers": straddlers,
           "numerator_nano": str(num) if complete else None, "denominator_nano": str(den) if complete else None,
           "share": num / den if complete else None, "disposition": disposition, "reasons": why}
    try:
        with open(a.out, "w", encoding="utf-8") as fh:
            json.dump(res, fh, indent=1)
            fh.write("\n")
    except OSError as e:
        refuse("cannot write --out %s: %s" % (a.out, e))
    print("exposure-screen: %s%s" % (disposition, " (" + ", ".join(why) + ")" if why else ""))
    return 3 if disposition == "INCONCLUSIVE" else 0


def exposure_screen(a):
    price_cli = os.path.normpath(os.path.join(HERE, "..", "..", "model-price.mjs"))
    reader = os.path.normpath(os.path.join(HERE, "..", "..", "..", "eval", "compaction-trigger-report.py"))
    screen_dir = os.path.dirname(os.path.abspath(a.exposure_screen))
    try:
        with open(a.exposure_screen, "rb") as fh:
            screen = json_of(fh.read(), "SCREEN")
    except OSError as e:
        refuse("SCREEN is not readable JSON: %s" % e)
    if not isinstance(screen, dict):
        refuse("SCREEN is not a JSON object")
    if set(screen) != SCREEN_KEYS:
        refuse("SCREEN has unknown field %s or lacks %s" % (sorted(set(screen) - SCREEN_KEYS), sorted(SCREEN_KEYS - set(screen))))
    if screen["schema"] != 1:
        refuse("SCREEN schema must be 1")
    if screen["lever"] != "B1":
        refuse("unsupported lever %r: only B1 has an exposure screen" % (screen["lever"],))
    win = screen["window"]
    if not isinstance(win, dict) or set(win) != {"since", "until", "timezone"} or not isinstance(win["timezone"], str):
        refuse("SCREEN window needs since, until and timezone")
    since_us, until_us = parse_us(win["since"]), parse_us(win["until"])
    if since_us is None or until_us is None or since_us >= until_us:
        refuse("SCREEN window is not an RFC3339 interval")

    inv_path, inv_raw, inv_ok = ref_of(screen["inventory"], "inventory", screen_dir)
    set_path, _, set_ok = ref_of(screen["export_set"], "export_set", screen_dir)
    _, val_raw, val_ok = ref_of(screen["validation"], "validation", screen_dir)
    inv = json_of(inv_raw, "inventory")
    supplied = json_of(val_raw, "validation")
    if not isinstance(inv, dict) or set(inv) != INVENTORY_KEYS or not isinstance(inv["complete"], bool) \
            or not isinstance(inv["scope_root"], str) or not inv["scope_root"] \
            or not isinstance(inv["top_level_files"], list) or not isinstance(inv["exclusions"], list):
        refuse("malformed inventory")
    if inv["window"] != win:
        refuse("inventory window differs from the SCREEN window")
    inv_dir = os.path.dirname(inv_path)
    _, _, review_ok = ref_of(inv["population_review"], "population_review", inv_dir)
    evidence_ok = True
    for f in inv["top_level_files"]:
        if (not isinstance(f, dict) or set(f) != ENTRY_KEYS
                or not all(isinstance(f[k], str) and f[k] for k in ("relative_path", "session", "role"))):
            refuse("malformed inventory entry")
        if f["role"] not in ROLES:
            refuse("inventory role %r is not one of %s" % (f["role"], ", ".join(sorted(ROLES))))
        evidence_ok = ref_of(f["role_evidence"], "role_evidence", inv_dir)[2] and evidence_ok

    why = []

    def add(code):
        if code not in why:
            why.append(code)

    if not (inv_ok and set_ok and val_ok and review_ok and evidence_ok):
        add("ref-hash-mismatch")
    if not inv["complete"]:
        add("population-incomplete")
    if any(f["role"] == "unknown" for f in inv["top_level_files"]):
        add("role-unknown")
    first, last = berlin_midnight(since_us), berlin_midnight(until_us)
    if win["timezone"] != "Europe/Berlin" or first is None or last is None:
        add("window-not-berlin-days")
    else:
        if (last - first).days < 7:
            add("window-too-short")
        if first < date(2026, 11, 9):
            add("window-before-nov-9")
    if why:
        return screen_result(a, "INCONCLUSIVE", why)

    try:
        loaded = subprocess.run(["node", "--input-type=module", "-e", NODE_LOAD, set_path, price_cli],
                                capture_output=True, check=False)
        data = json.loads(loaded.stdout) if loaded.returncode == 0 else None
    except (OSError, ValueError):
        data = None
    if data is None:
        return screen_result(a, "INCONCLUSIVE", ["validator-unavailable"])
    validation = data["validation"]
    if validation["state"] == "invalid":
        refuse("export set is invalid: " + ", ".join(validation["reasons"]))
    if supplied != validation:
        return screen_result(a, "INCONCLUSIVE", ["validation-mismatch"])
    if validation["state"] != "complete":
        return screen_result(a, "INCONCLUSIVE", ["validation-inconclusive"] + validation["reasons"])

    carrier = os.path.dirname(set_path)
    sources, rows = {}, []
    for e in data["exports"]:
        m = e["manifest"]
        if m is None or (m["since"], m["until"]) != WHOLE_FILE:
            add("projection-not-whole-file")
            continue
        root = os.path.realpath(m["root"] if os.path.isabs(m["root"]) else os.path.join(carrier, m["root"]))
        for f in m["files"]:
            sources[os.path.realpath(os.path.join(root, f["relative_path"]))] = f
        rows += [r for r in map(json.loads, filter(str.strip, e["lines"])) if r.get("kind") == "usage-call"]
    by_session = {}
    for r in rows:
        by_session.setdefault((r["parent"], r["session"]), []).append(r)

    scope = os.path.realpath(os.path.join(inv_dir, inv["scope_root"]))
    picked, seen = [], set()
    for f in inv["top_level_files"]:
        if f["role"] != "worker":
            continue
        path = os.path.realpath(os.path.join(scope, f["relative_path"]))
        if path in seen:
            add("path-duplicate")
            continue
        seen.add(path)
        src = sources.get(path)
        if src is None or src["parent"] is not None or src["session"] != f["session"]:
            add("path-missing")
            continue
        picked.append((path, src))
    selected, straddlers = [], 0
    for path, src in picked:
        stamps = [parse_us(c["first_timestamp"]) for c in by_session.get((None, src["session"]), [])]
        if not stamps or None in stamps:
            add("span-unknown")
        elif since_us <= min(stamps) and max(stamps) < until_us:
            selected.append((path, src))
        elif min(stamps) < until_us and max(stamps) >= since_us:
            straddlers += 1
    if len(selected) < MIN_PARENTS:
        add("too-few-parents")
    if why:
        return screen_result(a, "INCONCLUSIVE", why, len(selected), straddlers)

    def frozen():
        for path, src in selected:
            try:
                with open(path, "rb") as fh:
                    raw = fh.read()
            except OSError:
                return False
            if len(raw) != src["bytes"] or hashlib.sha256(raw).hexdigest() != src["sha256"]:
                return False
        return True

    paths = sorted(p for p, _ in selected)
    report = None
    if frozen():
        ran = subprocess.run([sys.executable, "-I", reader, "--json", "--min-peak", "0"] + paths,
                             capture_output=True, check=False)
        try:
            report = json.loads(ran.stdout) if ran.returncode == 0 else None
        except ValueError:
            report = None
    if report is None or not frozen():
        return screen_result(a, "INCONCLUSIVE", ["source-changed" if not frozen() else "reader-failed"], len(selected), straddlers)
    by_path = {}
    for w in report["workers"]:
        by_path.setdefault(w["path"], []).append(w)
    for p in paths:
        if len(by_path.get(p, [])) != 1:
            add("path-missing" if p not in by_path else "path-duplicate")
    if why:
        return screen_result(a, "INCONCLUSIVE", why, len(selected), straddlers)

    union = {}
    for path, src in selected:
        calls = sorted((parse_us(c["first_timestamp"]), c["call_id"], c) for c in by_session[(None, src["session"])])
        for comp in by_path[path][0]["compactions"]:
            t = comp.get("t")
            if isinstance(t, bool) or not isinstance(t, (int, float)):
                add("event-time-invalid")
                continue
            boundary = round(t * 1_000_000)
            for _, call_id, c in [x for x in calls if x[0] > boundary][:5]:
                union[call_id] = c
    sessions = {src["session"] for _, src in selected}
    num = sum(int(c["nano"]) for c in union.values())
    den = sum(int(r["nano"]) for r in rows if (r["session"] in sessions and r["parent"] is None) or r["parent"] in sessions)
    if den == 0:
        add("zero-denominator")
    if why:
        return screen_result(a, "INCONCLUSIVE", why, len(selected), straddlers)
    return screen_result(a, "QUALIFIED" if num * 100 >= den * 3 else "NO-OP", [], len(selected), straddlers, num, den)


def main():
    a = args()
    if a.exposure_screen is not None:
        return exposure_screen(a)
    tz = zone(a.tz)
    since = None
    if a.since:
        since = judge_accuracy.when(a.since)
        if since is None:
            refuse("--since is not an ISO-8601 timestamp: " + a.since)
    workers = workers_of(a, since)
    ctx = {"tz": tz, "since": since}
    ctx["prs"] = None
    if a.prs:
        try:
            ctx["prs"] = judge_accuracy.load_json(a.prs, "--prs")
        except ValueError as e:
            refuse(str(e))
    first_doc = workers[0]["doc"] if workers else (a.manifest or a.doc)[0]
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
    chief_docs = a.chief_doc or [re.sub(r"(\.fleet)?\.json$", "", m) + ".md" for m in a.manifest]
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
    mirror_why = "absent"
    try:
        ctx["bugs"] = judge_accuracy.load_bugs(mirror)
    except ValueError:
        ctx["bugs"] = None
    except OSError:
        ctx["bugs"], mirror_why = None, "unreadable"

    scored = [(wk,) + score(wk, ctx) for wk in workers]
    lanes = {}
    for _, q, _, _ in scored:
        lanes[q["lane"]] = lanes.get(q["lane"], 0) + 1
    out = ["# Fleet scorecard", "",
           "cohort: %d workers (%s)%s; local report, never published" % (
               len(workers), ", ".join("%s %d" % (k, lanes[k]) for k in sorted(lanes)) or "none",
               ", since " + a.since if a.since else ""), "",
           "## Output quality", "",
           table(["worker", "lane", "ticket", "PR", "state", "judge", "CR findings per reviewed head", "rounds to clean",
                  "pushes after READY", "main reds caused", "escapes 7d"],
                 [[wk["label"], q["lane"], q["ticket"], q["PR"], q["state"], q["judge"], q["cr"], q["rounds"],
                   q["pushes"], q["reds"], q["escapes"]] for wk, q, _, _ in scored]), "",
           "## Fleet management", "",
           table(["worker", "lane", "launch to LIVE", "launch to READY", "interventions", "asks/rulings/nudges/expansions",
                  "protocol", "delivery", "stalls", "denials", "cost-eq per merged PR"],
                 [[wk["label"], f["lane"], f["live"], f["ready"], f["interventions"], f["breakdown"], f["protocol"],
                   f["delivery"], f["stalls"], f["denials"], f["cost"]] for wk, _, f, _ in scored]), "",
           "## Per lane", "",
           table(["lane", "workers", "merged", "in flight", "judge GO", "judge NO-GO", "blockers", "majors", "CR findings",
                  "median rounds to clean", "median launch to LIVE", "median launch to READY", "interventions",
                  "median interventions", "denials", "median cost-eq per merged PR"], lane_rows(scored)), "",
           "- interventions: a ruling or nudge sent by SendMessage counts only when a doc logs it, "
           "so a worker with message delivery shows a floor", "",
           "## Sources", "",
           "- manifests: %s" % (", ".join(a.manifest) or "none (bare --doc workers)"),
           "- chief docs: %s%s" % (", ".join(found) or na("none found"),
                                   " (missing: %s)" % ", ".join(c for c in chief_docs if c not in found)
                                   if found and len(found) < len(chief_docs) else ""),
           "- verdicts: %s" % (ctx["vdir"] if ctx["recs"] is not None else na("absent: " + ctx["vdir"])),
           "- CR ledger: %s" % (ledger if ctx["ledger_rows"] is not None else na("absent: " + ledger)),
           "- PRs: %s" % (a.prs or na("no --prs")),
           "- denials: %s%s" % (ctx["denials_path"] if ctx["denials"] is not None else na("absent: " + ctx["denials_path"]),
                                " (%d unreadable row%s)" % (ctx["denials_bad"], "" if ctx["denials_bad"] == 1 else "s")
                                if ctx["denials_bad"] else ""),
           "- Jira mirror: %s" % (mirror if ctx["bugs"] is not None else na(mirror_why + ": " + mirror)), ""]
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
