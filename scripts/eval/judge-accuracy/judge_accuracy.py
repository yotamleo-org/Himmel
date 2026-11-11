#!/usr/bin/env python3
"""scripts/eval/judge-accuracy/judge_accuracy.py - the weekly judge-outcome job (the running
judge eval): joins the persisted verdict records to PR state, main CI and caused-by bugs,
and appends one `judge-accuracy` row to the eval-runs ledger (scripts/eval/lib/eval_runs.py).

  judge_accuracy.py run   --verdicts DIR --prs FILE [--main-runs FILE] [--mirror DIR] [--queue FILE]
                          [--until ISO] [--days N] [--ledger P | --no-ledger] [--class C [--bug-origin-dir DIR]]
  judge_accuracy.py queue [--queue FILE]
  judge_accuracy.py rule  <id> <S|P|N> --evidence TEXT [--by NAME] [--queue FILE]

Inputs. --verdicts is the bucket's verdicts/ tree (verdicts/<qid>/<name>.md, write-verdict.sh's format).
--prs is `gh pr list --state all --json number,state,mergedAt,headRefOid,mergeCommit`; --main-runs is
`gh run list --branch main --json databaseId,headSha,conclusion,createdAt`; --mirror is the Jira mirror
(default ~/.himmel/state/jira-mirror/HIMMEL). The window is the verdicts written in [until - days, until).

Join.
  escape     a PR merged at the head of a GO record in the window written before the merge, and either a Bug
             whose `caused-by: #<pr>` names it (sure) or a candidate ruled S (sure) or P (plausible). A PR
             counts once. A PR merged past its GO'd head or before its GO is coverage, never scored, and only
             those GOs give its class and model. Merges, verdicts, bugs and main runs from `until` on, or undated, are ignored.
  candidate  an escape signal whose cause no caused-by on the PR already settles: a Bug created after the merge
             that cites the PR and has no caused-by line, or a failed main run on the merge commit
             (ci-selection); and a NO-GO overturned by a
             GO at the same head. Each goes once to the adjudication queue; a judge-ro call
             (opus, high) rules it S / P / N with `rule`, and a ruled id is never asked again.
  procedural a NO-GO that only buys a delta round; left out of every rate.
  overridden a NO-GO whose PR merged at that head with no GO for it: a chief decision, never "wrong".
  cause      an escape through a failed main run or a main-red Bug is ci-selection, else review.
Per class (the PR's GO records' class lines) and per model (the last GO's model): n, escapes,
escape_rate with a Wilson 95 % interval, and escape_excess = the interval's low end minus the overall
rate, above 0 only when the class is worse than the whole. A row is partial while a candidate in its
window is unruled, so the feedback step (eval_feedback.py) never takes it as a baseline.

--class C counts only the escapes whose fix PR has class C in the bug-origin ledger (C or a family: review-miss
matches review-miss:cr; review-miss:multi a row with two or more layers, review-miss:cr a row whose layers hold cr); a
class with no rows counts none, an unknown class is refused, and a failed main run (no fix row) counts for no class.
The ledger is --bug-origin-dir, else <root>/<user>/<project bucket>/bug-origin, the root being what the shell tooling
finds (the live HANDOVER_DIR, else the config files in $HIMMEL_CONFIG_DIR or ~/.himmel, else the primary checkout's
.env, else its handovers/ directory); none to read is refused. With
--class and no Jira mirror the ledger rows give the bugs, so the filter works without Jira; unfiltered numbers read the
mirror. A filtered run is not a row of the real ledger's series: with --class, --ledger P or --no-ledger is required (exit 2
otherwise), and the row in an explicit ledger carries the class in its config.

QUEUE ROW (v 1, append-only): v, ts, kind "candidate" | "ruling", id, then
  candidate  pr, signal "bug" | "red-main" | "nogo", ref, question
  ruling     ruling "S" | "P" | "N", by, evidence
  Path: $HIMMEL_JUDGE_ADJUDICATION, else ~/.himmel/eval/judge-accuracy/adjudication.jsonl.

Exit: 0 done; 1 refused ruling (unknown or already ruled id); 2 refused input.
Stdlib only; no network.
"""
import argparse
import fcntl
import json
import os
import re
import socket
import subprocess
import sys
from datetime import datetime, timedelta, timezone

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "lib"))
import eval_runs  # noqa: E402
from wilson import wilson  # noqa: E402

EVAL_ID = "judge-accuracy"
SOURCE = "scripts/eval/judge-accuracy/judge_accuracy.py"
QUEUE_ENV = "HIMMEL_JUDGE_ADJUDICATION"
MIRROR = os.path.expanduser("~/.himmel/state/jira-mirror/HIMMEL")
DAYS = 28
RULINGS = ("S", "P", "N")
VERDICT = re.compile(r"^\*\*(GO|NO-GO)\*\* for head `([0-9a-f]+)`", re.M)
# ponytail: a phrase match for round-buying NO-GOs, as the judge-accuracy audit sorted them; a `procedural:`
# header from write-verdict.sh is the upgrade path.
PROCEDURAL = re.compile(r"\b(buys?|grants?) (one|a|the) delta round\b|\bprocedural\b", re.I)
CAUSED_BY = re.compile(r"caused-by:\s*#?(\d+|unknown)\b", re.I)
CITE = re.compile(r"(?:#|/pull/)(\d+)\b")


# ponytail: one alias, opus -> claude-opus-5-5 (decision 194: two spellings, one model row); a family
# table is the upgrade path when a second alias shows up in the verdicts.
MODEL_ALIAS = {"opus": "claude-opus-5-5"}


def queue_path(path=None):
    return path or os.environ.get(QUEUE_ENV) or os.path.expanduser("~/.himmel/eval/judge-accuracy/adjudication.jsonl")


def when(s):
    """An aware datetime from an ISO stamp (Z, +02:00 or +0200), or None."""
    try:
        d = datetime.fromisoformat(re.sub(r"([+-]\d{2})(\d{2})$", r"\1:\2", s.strip().replace("Z", "+00:00")))
    except (AttributeError, ValueError):
        return None
    return d if d.tzinfo else d.replace(tzinfo=timezone.utc)


def header(text, key):
    m = re.search(r"^%s: *(.*?) *$" % re.escape(key), text, re.M)
    return m.group(1) if m else None


def parse_verdict(path):
    """One verdict record, or None for a file with no canonical verdict line."""
    text = open(path, encoding="utf-8", errors="replace").read()
    m = VERDICT.search(text)
    if not m:
        return None
    name = os.path.splitext(os.path.basename(path))[0]
    pr, prior = header(text, "pr"), header(text, "prior")
    model, effort = header(text, "model"), header(text, "effort")
    classes = set()
    for line in re.findall(r"^class: *(.*)$", text, re.M):
        classes.update(c.strip() for c in line.split(","))
    return {
        "qid": os.path.basename(os.path.dirname(path)), "name": name, "verdict": m.group(1), "head": m.group(2),
        "pr": int(pr) if pr and pr.isdigit() else None,
        "prior": prior if prior in ("GO", "NO-GO") else None,
        "model": None if model in (None, "", "unknown") else MODEL_ALIAS.get(model, model),
        "effort": None if effort in (None, "", "unknown") else effort,
        "classes": sorted(classes - {"", "none", "n/a"}),
        "at": when(header(text, "written-at") or ""),
        "console": name.startswith(("console", "chief")),
        "procedural": m.group(1) == "NO-GO" and PROCEDURAL.search(text) is not None,
    }


def load_verdicts(root):
    if not os.path.isdir(root):
        raise ValueError("no verdict dir: %s" % root)
    recs, unparsed = [], 0
    for qid in sorted(os.listdir(root)):
        d = os.path.join(root, qid)
        if not os.path.isdir(d):
            continue
        for f in sorted(os.listdir(d)):
            if f.endswith(".md"):
                r = parse_verdict(os.path.join(d, f))
                if r:
                    recs.append(r)
                else:
                    unparsed += 1
    return recs, unparsed


def load_bugs(mirror):
    """Bug tickets of the mirror: key, labels, created, caused-by target and the PRs the text cites."""
    bugs = []
    if not os.path.isdir(mirror):
        raise ValueError("no Jira mirror: %s" % mirror)
    for f in sorted(os.listdir(mirror)):
        if not f.endswith(".md"):
            continue
        text = open(os.path.join(mirror, f), encoding="utf-8", errors="replace").read()
        if header(text, "type") != '"Bug"':
            continue
        try:
            labels = json.loads(header(text, "labels") or "[]")
        except ValueError:
            labels = []
        body = text.split("\n---\n", 1)[-1]
        cb = CAUSED_BY.search(body)
        bugs.append({"key": os.path.splitext(f)[0], "labels": labels, "created": when((header(text, "created") or "").strip('"')),
                     "caused_by": cb.group(1).lower() if cb else None,
                     "cites": {int(n) for n in CITE.findall(body)}})
    return bugs


# The bug-origin ledger: one markdown file per fix PR, <handover root>/<user>/<project bucket>/bug-origin/<pr>.md,
# front matter of one JSON value per key and one plain body line a search can find. It is written by
# bug-origin-report.py; the readers are here because escapes.py and that report already import this module.
LEDGER_SUBDIR = "bug-origin"
LEDGER_ROW = re.compile(r"[0-9]+\.md\Z")
# The grammar of the bug-origin line, which bug-origin-report.py's LINE is built from and a ledger row is checked against.
CLASS_PATTERN = (r"test-gap|design-gap|review-deferred|unknown|review-miss:(?:cr|judge|panel)(?:,(?:cr|judge|panel))*"
                 r"|(?:residual|trigger):[A-Za-z0-9][A-Za-z0-9._/#-]*|commit:[0-9a-f]{7,40}")
ORIGIN_PATTERN = r"#[0-9]+|[0-9a-f]{7,40}|unknown"
REASON_PATTERN = r"[^ \t\r\n](?:[^\r\n]*\S)?"
# What --class accepts: a class the report counts, a family, or a payload class with or without its token.
WANT_PATTERN = (r"test-gap|design-gap|review-deferred|unknown"
                r"|review-miss(?::multi|:(?:cr|judge|panel)(?:,(?:cr|judge|panel))*)?"
                r"|(?:residual|trigger|commit)(?::[A-Za-z0-9][A-Za-z0-9._/#-]*)?")


def primary_checkout(repo="."):
    """The primary checkout of the repo (the git common dir minus /.git, so a worktree resolves to its main tree)."""
    r = subprocess.run(["git", "-C", repo, "rev-parse", "--path-format=absolute", "--git-common-dir"],
                       capture_output=True, text=True)
    common = r.stdout.strip() if r.returncode == 0 else ""
    return os.path.dirname(common) if os.path.basename(common) == ".git" else os.path.abspath(repo)


def conf_value(path, name, unquote=True):
    """The first non-empty value of `name` in a KEY=value file, as the Jira CLI reads one (an inline ` #` comment and quotes dropped), else ''.
    With unquote=False a quoted value keeps its quotes, as the shell loader keeps them."""
    try:
        with open(path, encoding="utf-8") as fh:
            lines = fh.read().split("\n")
    except OSError:
        return ""
    for line in lines:
        line = line.strip()
        key, sep, val = line.partition("=")
        if line.startswith("#") or not sep or key.strip() != name:
            continue
        val = val.strip()
        if val[:1] not in ('"', "'"):
            val = re.split(r"[ \t]#", val, maxsplit=1)[0]
        elif unquote:
            val = val[1:].partition(val[0])[0]
        if val.strip():
            return val.strip()
    return ""


def git_common_dir(path):
    """The git common dir of `path`, with the caller's GIT_* variables scrubbed (they would pick the repo, not `path`), or ''."""
    scrub = {k: v for k, v in os.environ.items() if k not in
             ("GIT_DIR", "GIT_WORK_TREE", "GIT_COMMON_DIR", "GIT_INDEX_FILE", "GIT_CEILING_DIRECTORIES")}
    r = subprocess.run(["git", "-C", path, "rev-parse", "--path-format=absolute", "--git-common-dir"],
                       capture_output=True, text=True, env=scrub)
    return r.stdout.strip() if r.returncode == 0 else ""


def profile_conf(conf, env):
    """The active station profile file, as load-dotenv.sh finds it, or None. The name is HIMMEL_PROFILE in the environment, else
    in himmel.conf.local (never the tracked file); it must be a plain file stem. The profiles directory sits beside the file
    himmel.conf links to, so a himmel.conf that is no link has none."""
    name = env.get("HIMMEL_PROFILE") or conf_value(os.path.join(conf, "himmel.conf.local"), "HIMMEL_PROFILE", unquote=False)
    if not re.fullmatch(r"[A-Za-z0-9_-][A-Za-z0-9._-]*", name or ""):
        return None
    link = os.path.join(conf, "himmel.conf")
    if not os.path.islink(link):
        return None
    target = os.readlink(link)
    if not os.path.isabs(target):
        target = os.path.join(conf, target)
    return os.path.join(os.path.dirname(target), "profiles", name + ".conf")


def handover_root(top, env, anchor=None):
    """The handover root, as go_resolve_root finds it: the live HANDOVER_DIR unless it lies inside the harness repo, the
    anchor's (its inline stub), else himmel.conf.local, the active station profile and himmel.conf in $HIMMEL_CONFIG_DIR
    (else ~/.himmel), else the anchor's .env, else `top`'s own handovers/ directory. `anchor` defaults to `top`."""
    anchor = anchor or top
    live = env.get("HANDOVER_DIR")
    if live:
        common = git_common_dir(live)
        if not common or common != git_common_dir(anchor):
            return live
    conf = env.get("HIMMEL_CONFIG_DIR") or os.path.join(env.get("HOME") or os.path.expanduser("~"), ".himmel")
    files = [os.path.join(conf, "himmel.conf.local"), profile_conf(conf, env), os.path.join(conf, "himmel.conf"), os.path.join(anchor, ".env")]
    return next((v for v in (conf_value(f, "HANDOVER_DIR", unquote=False) for f in files if f) if v), os.path.join(top, "handovers"))


def ledger_dir(repo=".", env=None):
    """The ledger directory of the project that owns `repo`, or None when no handover root is configured.

    Root, as go_resolve_root resolves it (see handover_root): it must be a directory, else there is no ledger. User and
    bucket: the handover registry entry whose path is the repo's primary checkout
    (its user and bucket_name), else USER_SLUG and the checkout's own name, so no project name is hard-coded."""
    env = os.environ if env is None else env
    top = primary_checkout(repo)
    # the anchor is the himmel checkout this script lives in (merge-on-green exports HIMMEL_REPO), which is not the repo
    # the merge runs in when a project other than himmel is merged
    root = handover_root(top, env, primary_checkout(env.get("HIMMEL_REPO") or os.path.dirname(os.path.abspath(__file__))))
    if not os.path.isdir(root):
        return None
    user = env.get("USER_SLUG") or env.get("USER") or "unknown"
    bucket = None
    try:
        with open(env.get("HANDOVER_REGISTRY") or os.path.expanduser("~/.claude/handover/registry.json"), encoding="utf-8") as fh:
            repos = json.load(fh).get("repos") or {}
    except (OSError, ValueError, AttributeError):
        repos = {}
    for name, entry in repos.items():
        if isinstance(entry, dict) and entry.get("path") and os.path.realpath(entry["path"]) == os.path.realpath(top):
            user, bucket = entry.get("user") or user, entry.get("bucket_name") or name
            break
    bucket = bucket or re.sub(r"[^a-z0-9._-]+", "-", os.path.basename(top).lower()).strip("-")
    return os.path.join(root, user, bucket, LEDGER_SUBDIR)


def parse_row(text):
    """A ledger row's front matter as a dict, or None when the file is not a row."""
    lines = text.split("\n")
    if lines[0] != "---":
        return None
    row = {}
    for ln in lines[1:]:
        if ln == "---":
            break
        key, sep, val = ln.partition(": ")
        if not sep:
            return None
        try:
            row[key] = json.loads(val)
        except ValueError:
            return None
    else:
        return None
    if type(row.get("pr")) is not int or not all(isinstance(row.get(k), str) for k in ("origin", "class", "reason")):
        return None
    return row


def row_valid(row):
    """True when a row's origin, class and reason are what the bug-origin line grammar gives."""
    origin, cls, reason = row["origin"], row["class"], row["reason"]
    return (re.fullmatch(ORIGIN_PATTERN, origin) is not None and re.fullmatch(CLASS_PATTERN, cls) is not None
            and (origin != "unknown" or cls == "unknown")
            and re.fullmatch(REASON_PATTERN, reason) is not None and reason == reason.rstrip())


def load_ledger(path, skipped=None):
    """{fix PR: row} of a ledger directory; a missing directory is an empty ledger, a file that is no row is skipped.

    A row off the line grammar, or in a file not named for its own pr, is left out too; `skipped` collects those names."""
    rows = {}
    if not path or not os.path.isdir(path):
        return rows
    for f in sorted(os.listdir(path)):
        if not LEDGER_ROW.match(f):
            continue
        try:
            with open(os.path.join(path, f), encoding="utf-8") as fh:
                row = parse_row(fh.read())
        except OSError:
            continue
        if not row:
            continue
        if f != "%d.md" % row["pr"] or not row_valid(row):
            if skipped is not None:
                skipped.append(f)
            continue
        rows[row["pr"]] = row
    return rows


def row_key(row):
    """The bug key a row names, else the key of its fix PR."""
    return row["bug_key"] if isinstance(row.get("bug_key"), str) else "PR%d" % row["pr"]


def ledger_classes(rows):
    """{"pr": {fix PR: class}, "key": {bug key: [every class a row of that bug has]}} of ledger rows."""
    keys = {}
    for r in rows.values():
        keys.setdefault(row_key(r), []).append(r["class"])
    return {"pr": {n: r["class"] for n, r in rows.items()}, "key": keys}


def ledger_bugs(rows):
    """Bug records (as load_bugs gives them) from the ledger alone, for a project with no Jira mirror.

    A row whose origin is a PR names a bug caused by it; a row with a sha or unknown origin names none. A bug is created
    when its fix PR merged (the row's `merged`), else, for a row written before that key, when the row was ingested."""
    return [{"key": row_key(r), "labels": [], "created": when(r["merged"] if isinstance(r.get("merged"), str) else r.get("ingested") or ""), "caused_by": r["origin"][1:],
             "cites": set()} for r in rows.values() if r["origin"].startswith("#")]


def valid_class(want):
    """True when `want` is a class --class can mean: one the report counts, a family, or a payload class."""
    return re.fullmatch(WANT_PATTERN, want) is not None


def class_match(want, have):
    """True when a row's class `have` (one class, or a list or set of them) is `want` or lies under it.

    A family matches its members (review-miss matches review-miss:cr); review-miss:multi matches a row with two or
    more distinct layers and review-miss:<layers> a row whose layers hold them (review-miss:cr matches review-miss:cr,judge)."""
    if isinstance(have, str):
        have = [have]
    for h in have or ():
        if not h:
            continue
        if h == want or h.startswith(want + ":"):
            return True
        if h.startswith("review-miss:") and want.startswith("review-miss:"):
            layers, wanted = set(h.split(":", 1)[1].split(",")), want.split(":", 1)[1]
            if len(layers) > 1 if wanted == "multi" else set(wanted.split(",")) <= layers:
                return True
    return False


def class_filter(cls, directory):
    """None for no filter; else the ledger's rows. An unknown class, or a filter with no ledger to read, is refused, never read as empty or all."""
    if cls is None:
        return None
    if not valid_class(cls):
        raise ValueError("--class %r is no class the bug-origin report knows (test-gap, design-gap, review-deferred, unknown, "
                         "review-miss[:multi|:<layers>], residual, trigger, commit, with an optional :token)" % cls)
    path = directory or ledger_dir()
    if not path or not os.path.isdir(path):
        raise ValueError("--class needs the bug-origin ledger: set HANDOVER_DIR or pass --bug-origin-dir (none at %s)" % path)
    return load_ledger(path)


def read_queue(path):
    try:
        with open(path, encoding="utf-8") as fh:
            return [json.loads(ln) for ln in fh if ln.strip()]
    except FileNotFoundError:
        return []


def append(path, row):
    row = {"v": 1, "ts": stamp(), "host": socket.gethostname(), "source": SOURCE, **row}
    os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
    line = (json.dumps(row, ensure_ascii=False, separators=(",", ":")) + "\n").encode("utf-8")
    fd = os.open(path, os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o644)
    try:
        os.write(fd, line)
    finally:
        os.close(fd)


def stamp():
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def rate(metrics, ci, name, k, n):
    metrics[name] = (k / n) if n else None
    b = wilson(k, n)
    if b:
        ci[name] = b


def landed(p, until):
    """True when the PR snapshot shows it merged before `until`."""
    at = when((p or {}).get("mergedAt") or "")
    return (p or {}).get("state") == "MERGED" and at is not None and at < until


def join(recs, prs, runs, bugs, since, until):
    """(metrics, ci, candidates) for the verdicts written in [since, until)."""
    win = [r for r in recs if r["at"] and since <= r["at"] < until]
    judge = [r for r in win if not r["console"]]
    by_pr = {}
    for r in recs:
        if r["pr"] is not None and r["at"] and r["at"] < until:
            by_pr.setdefault(r["pr"], []).append(r)
    m, ci, cands = {}, {}, []

    flips = [r for r in judge if r["prior"] and not r["procedural"]]
    m["flips"] = sum(r["prior"] != r["verdict"] for r in flips)
    m["flip_n"] = len(flips)
    rate(m, ci, "flip_rate", m["flips"], m["flip_n"])

    gos = {}
    for r in win:
        if r["verdict"] == "GO" and r["pr"] is not None:
            gos.setdefault(r["pr"], []).append(r)
    shipped = {n: prs[n] for n in gos if landed(prs.get(n), until)}
    for n, p in shipped.items():
        gos[n] = [g for g in gos[n] if g["head"] == p.get("headRefOid") and g["at"] <= when(p["mergedAt"])]
    merged = {n: p for n, p in shipped.items() if gos[n]}
    m["coverage.merged_past_go"] = len(shipped) - len(merged)
    signals = {n: [] for n in merged}  # pr -> [(level S|P|pending, cause)]
    bugs = [b for b in bugs if b["created"] and b["created"] < until]
    for b in bugs:
        if b["caused_by"] and b["caused_by"].isdigit() and int(b["caused_by"]) in signals:
            signals[int(b["caused_by"])].append(("S", "ci-selection" if "main-red" in b["labels"] else "review"))
    settled = {(n, cause) for n, s in signals.items() for _, cause in s}
    for b in bugs:
        if b["caused_by"] and b["caused_by"].isdigit():
            continue
        cause = "ci-selection" if "main-red" in b["labels"] else "review"
        for n in sorted(b["cites"] & set(merged)):
            at = when(merged[n].get("mergedAt") or "")
            if at and b["created"] and b["created"] > at and (n, cause) not in settled:
                cands.append({"id": "esc:%d:bug:%s" % (n, b["key"]), "pr": n, "signal": "bug", "ref": b["key"],
                              "cause": cause,
                              "question": "Did PR #%d cause the bug %s? S sure, P plausible, N not caused by it."
                                          % (n, b["key"])})
    sha = {(p.get("mergeCommit") or {}).get("oid"): n for n, p in merged.items()}
    for run in runs:
        n = sha.get(run.get("headSha"))
        at = when(run.get("createdAt") or "")
        if (n is not None and (n, "ci-selection") not in settled and run.get("conclusion") == "failure"
                and at and at < until):
            cands.append({"id": "esc:%d:red-main:%s" % (n, run.get("databaseId")), "pr": n, "signal": "red-main",
                          "ref": str(run.get("databaseId")), "cause": "ci-selection",
                          "question": "Did PR #%d break main run %s on its own merge commit? S sure, P plausible, "
                                      "N not caused by it." % (n, run.get("databaseId"))})

    nogos = [r for r in judge if r["verdict"] == "NO-GO" and r["pr"] is not None]
    m["procedural"] = sum(r["procedural"] for r in nogos)
    nogos = [r for r in nogos if not r["procedural"]]
    m["nogo_n"] = len(nogos)
    m["overridden"] = 0
    for r in nogos:
        later = [g for g in by_pr[r["pr"]] if g["verdict"] == "GO" and g["head"] == r["head"]]
        pr = prs.get(r["pr"], {})
        if any(g["at"] and g["at"] > r["at"] for g in later):
            cands.append({"id": "nogo:%s/%s" % (r["qid"], r["name"]), "pr": r["pr"], "signal": "nogo",
                          "ref": r["head"], "cause": None,
                          "question": "Was the NO-GO %s/%s on PR #%d at %s wrong (overturned by a GO at the same "
                                      "head)? S the blocking finding was wrong, P plausibly wrong, N it was right."
                                      % (r["qid"], r["name"], r["pr"], r["head"][:12])})
        elif landed(pr, until) and pr.get("headRefOid") == r["head"]:
            m["overridden"] += 1
    return m, ci, cands, merged, signals, gos, judge, win


def score(recs, unparsed, prs, runs, bugs, since, until, rulings, queued):
    """The ledger metrics and intervals, the new candidates, and the pending count."""
    m, ci, cands, merged, signals, gos, judge, win = join(recs, prs, runs, bugs, since, until)
    pending = 0
    m["false_nogo"] = m["false_nogo_plausible"] = m["nogo_candidates"] = 0
    for c in cands:
        ruling = rulings.get(c["id"])
        if ruling is None:
            pending += 1
        if c["signal"] == "nogo":
            m["nogo_candidates"] += 1
            m["false_nogo"] += ruling == "S"
            m["false_nogo_plausible"] += ruling in ("S", "P")
        elif ruling in ("S", "P"):
            signals[c["pr"]].append((ruling, c["cause"]))
    sure = {n for n, s in signals.items() if any(lv == "S" for lv, _ in s)}
    plaus = {n for n, s in signals.items() if s}
    m["go_merged"] = len(merged)
    m["escapes"], m["escapes_plausible"] = len(sure), len(plaus)
    rate(m, ci, "escape_rate", len(sure), len(merged))
    rate(m, ci, "escape_rate_plausible", len(plaus), len(merged))
    ci_sel = {n for n in sure if any(lv == "S" and cause == "ci-selection" for lv, cause in signals[n])}
    m["cause.ci-selection.escapes"] = len(ci_sel)
    rate(m, ci, "cause.ci-selection.escape_rate", len(ci_sel), len(merged))
    overall = m["escape_rate"]

    groups = {}
    for n in merged:
        judged = sorted((r for r in gos[n] if not r["console"]), key=lambda r: r["at"])
        for c in sorted({c for r in judged for c in r["classes"]}) or ["unclassified"]:
            groups.setdefault("class." + c, set()).add(n)
        groups.setdefault("model." + ((judged[-1]["model"] if judged else None) or "unknown"), set()).add(n)
    for g, members in sorted(groups.items()):
        k = len(members & sure)
        m[g + ".n"], m[g + ".escapes"] = len(members), k
        rate(m, ci, g + ".escape_rate", k, len(members))
        m[g + ".escape_excess"] = round(ci[g + ".escape_rate"]["lo"] - overall, 4)
    for model in sorted({r["model"] or "unknown" for r in judge}):
        fl = [r for r in judge if (r["model"] or "unknown") == model and r["prior"] and not r["procedural"]]
        m["model.%s.flip_n" % model] = len(fl)
        rate(m, ci, "model.%s.flip_rate" % model, sum(r["prior"] != r["verdict"] for r in fl), len(fl))

    m["coverage.records"] = len(judge)
    m["coverage.no_model"] = sum(r["model"] is None for r in judge)
    m["coverage.no_effort"] = sum(r["effort"] is None for r in judge)
    m["coverage.no_pr"] = sum(r["pr"] is None for r in win)
    m["coverage.no_time"] = sum(r["at"] is None for r in recs)
    m["coverage.unparsed"] = unparsed
    nogo_prs = {r["pr"] for r in judge if r["verdict"] == "NO-GO" and r["pr"] is not None}
    m["coverage.merged_without_go"] = sum(1 for n in nogo_prs if landed(prs.get(n), until)
                                          and not any(r["verdict"] == "GO" and r["at"] and r["at"] < until
                                                      for r in recs if r["pr"] == n))
    m["pending"] = pending
    new = [c for c in cands if c["id"] not in queued]
    return m, ci, new, pending


def load_json(path, what):
    if not path:
        return []
    try:
        with open(path, encoding="utf-8") as fh:
            data = json.load(fh)
    except (OSError, ValueError) as e:
        raise ValueError("unreadable %s %s: %s" % (what, path, e))
    if not isinstance(data, list) or not all(isinstance(r, dict) for r in data):
        raise ValueError("%s %s is not a JSON list of objects" % (what, path))
    return data


def cmd_run(a):
    until = when(a.until) if a.until else datetime.now(timezone.utc)
    if until is None or a.days <= 0:
        raise ValueError("--until must be an ISO time and --days positive")
    since = until - timedelta(days=a.days)
    recs, unparsed = load_verdicts(a.verdicts)
    pr_rows = load_json(a.prs, "PR snapshot")
    if not all(type(p.get("number")) is int for p in pr_rows):
        raise ValueError("PR snapshot %s has a row without an integer number" % a.prs)
    prs = {p["number"]: p for p in pr_rows}
    runs = load_json(a.main_runs, "main-run snapshot")
    if a.cls is not None and not a.ledger and not a.no_ledger:
        raise ValueError("--class needs --ledger P or --no-ledger: a filtered run is not a row of the real ledger's series")
    ledger = class_filter(a.cls, a.bug_origin_dir)
    # a class filter reads the ledger, so a project with no Jira mirror still works; the unfiltered numbers need the mirror
    bugs = ledger_bugs(ledger) if ledger is not None and not os.path.isdir(a.mirror) else load_bugs(a.mirror)
    if ledger is not None:
        # a bug counts when its fix row has the class; a failed main run has no fix row, so no class
        classes = ledger_classes(ledger)
        bugs = [b for b in bugs if class_match(a.cls, classes["key"].get(b["key"]))]
        runs = []
    qpath = queue_path(a.queue)
    os.makedirs(os.path.dirname(os.path.abspath(qpath)), exist_ok=True)
    with open(qpath + ".lock", "a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        q = read_queue(qpath)
        queued = {r["id"] for r in q if r.get("kind") == "candidate"}
        rulings = {}
        for r in q:
            if r.get("kind") == "ruling":
                rulings.setdefault(r["id"], r["ruling"])
        metrics, ci, new, pending = score(recs, unparsed, prs, runs, bugs, since, until, rulings, queued)
        for c in new:
            append(qpath, {"kind": "candidate", "id": c["id"], "pr": c["pr"],
                           "signal": c["signal"], "ref": c["ref"], "question": c["question"]})
    status = "inconclusive" if not metrics["go_merged"] else "partial" if pending else "ok"
    config = {"judge_accuracy_v": 1, "days": a.days}
    if a.cls is not None:
        config["class"] = a.cls  # a filtered run is its own series, never a row of the unfiltered one
    row = eval_runs.make_row(EVAL_ID, SOURCE, config, metrics,
                             n=metrics["go_merged"], status=status, ci=ci, ci_level=0.95 if ci else None,
                             ci_method="wilson" if ci else None, repo=os.path.join(HERE, "..", "..", ".."),
                             meta={"since": since.strftime("%Y-%m-%dT%H:%M:%SZ"),
                                   "until": until.strftime("%Y-%m-%dT%H:%M:%SZ"), "verdicts": a.verdicts,
                                   "queue": qpath, "new_candidates": len(new)})
    for k in ("go_merged", "escapes", "escape_rate", "escapes_plausible", "flip_rate", "false_nogo", "overridden",
              "procedural", "pending"):
        print("judge-accuracy: %s=%s" % (k, metrics[k]))
    print("judge-accuracy: status=%s new_candidates=%d queue=%s" % (status, len(new), qpath))
    if not a.no_ledger:
        eval_runs.append_safe(row, a.ledger, who="judge-accuracy")
    return 0


def cmd_queue(a):
    q = read_queue(queue_path(a.queue))
    ruled = {r["id"] for r in q if r.get("kind") == "ruling"}
    for r in q:
        if r.get("kind") == "candidate" and r["id"] not in ruled:
            print("%s\tpr=%s\t%s\t%s" % (r["id"], r["pr"], r["signal"], r["question"]))
    return 0


def cmd_rule(a):
    if a.ruling not in RULINGS:
        print("judge-accuracy: a ruling is one of %s" % ", ".join(RULINGS), file=sys.stderr)
        return 2
    qpath = queue_path(a.queue)
    os.makedirs(os.path.dirname(os.path.abspath(qpath)), exist_ok=True)
    with open(qpath + ".lock", "a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        q = read_queue(qpath)
        if not any(r.get("kind") == "candidate" and r["id"] == a.id for r in q):
            print("judge-accuracy: no queued candidate %s" % a.id, file=sys.stderr)
            return 1
        if any(r.get("kind") == "ruling" and r["id"] == a.id for r in q):
            print("judge-accuracy: %s is already ruled; a ruled candidate is never re-asked" % a.id, file=sys.stderr)
            return 1
        append(qpath, {"kind": "ruling", "id": a.id, "ruling": a.ruling, "by": a.by,
                       "evidence": a.evidence})
    print("judge-accuracy: ruled %s %s" % (a.id, a.ruling))
    return 0


def main(argv=None):
    ap = argparse.ArgumentParser(prog="judge_accuracy.py", description=__doc__.split("\n")[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    r = sub.add_parser("run")
    r.add_argument("--verdicts", required=True)
    r.add_argument("--prs", required=True)
    r.add_argument("--main-runs")
    r.add_argument("--mirror", default=MIRROR)
    r.add_argument("--queue")
    r.add_argument("--until")
    r.add_argument("--days", type=int, default=DAYS)
    r.add_argument("--ledger")
    r.add_argument("--no-ledger", action="store_true")
    r.add_argument("--class", dest="cls")
    r.add_argument("--bug-origin-dir")
    q = sub.add_parser("queue")
    q.add_argument("--queue")
    u = sub.add_parser("rule")
    u.add_argument("id")
    u.add_argument("ruling")
    u.add_argument("--evidence", required=True)
    u.add_argument("--by", default="judge-ro")
    u.add_argument("--queue")
    a = ap.parse_args(argv)
    try:
        return {"run": cmd_run, "queue": cmd_queue, "rule": cmd_rule}[a.cmd](a)
    except (OSError, ValueError, KeyError) as e:
        print("judge-accuracy: %s" % e, file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
