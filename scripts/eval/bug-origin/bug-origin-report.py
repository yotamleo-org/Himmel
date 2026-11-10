#!/usr/bin/env python3
"""scripts/eval/bug-origin/bug-origin-report.py - how bugs got in, per class and per review layer.

A bug fix's PR body carries one line, the record of how the bug got in:

  bug-origin: <#pr|sha|unknown> <class> — <reason>

  class: test-gap, design-gap, review-deferred, unknown, review-miss:<layers> (cr, judge, panel, comma-separated),
         residual:<token>, trigger:<token>, commit:<hex sha>

The class is the fixer's reading and the report never re-classifies it. The report counts review-miss:cr, :judge
and :panel, review-miss:multi (two or three layers), review-deferred, residual, trigger, commit and unknown.

The ledger: `ingest` writes one markdown file per fix PR whose body (else the seed) carries the line, at
<HANDOVER_DIR>/<user>/<project bucket>/bug-origin/<pr>.md (the user and bucket from the handover registry entry of this
checkout, else USER_SLUG and the checkout's name; --ledger-dir overrides; the root is found as the shell tooling finds it:
HANDOVER_DIR in the environment, else the config files, else the primary checkout's .env, else its handovers/
directory). The row is front matter (with the PR's merge time, `merged`) plus one plain line
a search finds; it is the source of truth and needs no tracker. `report` reads a PR's ledger row first, then its body,
then the seed, and prints `ledger: <n> rows from <dir>` (or `ledger: none (set HANDOVER_DIR or pass --ledger-dir)`) first.
`sync` comments each unsynced row's line once on the first [KEY] of its PR title, whatever the issue type. It needs a Jira
project key where the Jira CLI finds one (JIRA_PROJECT_KEY in the environment, else himmel.conf.local and himmel.conf in
$HIMMEL_CONFIG_DIR or ~/.himmel, else the .env of the checkout it runs in): no key is `jira sync skipped: not
configured`, exit 0; a key and no Jira CLI to run (--jira-cmd not executable, or no scripts/jira/dist/index.js) is
refused, exit 2; a Jira error warns, leaves the row for the next run and exits 1. Rows land only when `ingest` runs: by hand, and
after each merge from scripts/handover/merge-on-green.sh, which ingests the merged PR alone. A row is created with a
link that fails if the file exists, so ingests racing for one PR leave the first row as it was.
`report --class C` keeps the rows of class C (or a family: review-miss matches review-miss:cr; review-miss:multi a
row with two or more layers; review-miss:cr a row whose layers hold cr, so it also matches review-miss:cr,judge); a
class with no rows reports none, and a class that is none of the report's classes is refused, exit 2. A ledger row
off the line grammar, or in a file not named for its own PR, is left out and counted.

For each review-miss row the report shows what each review layer has on record for the introducing PR:

  on record: <names>                a review row or a GO verdict from before the merge
  not read                          the source was not given or could not be read, which is no evidence
  no coverage before <first ts>     the PR merged before the source's first row
  not on record                     the source was read and shows no review (CodeRabbit leaves no row on a clean pass)

  report --prs FILE [--seed FILE] [--cr-ledger FILE] [--verdicts DIR]... [--mirror DIR] [--days N] [--record] [--ledger FILE]
         [--ledger-dir DIR] [--class C]

  ingest --prs FILE [--seed FILE] [--ledger-dir DIR]

  sync [--ledger-dir DIR] [--jira-cmd PATH]

  trace --base REF --head REF [--prs FILE] [--cr-ledger FILE] [--verdicts DIR]...

--prs is `gh pr list --state merged --limit 10000 --json number,title,body,mergedAt,headRefName,headRefOid,mergeCommit`;
trace needs only number,mergedAt,headRefName,headRefOid,mergeCommit.
trace blames, at the merge base, the lines base..head changes and prints up to three commits with their PR, `adjacent`
when only an add-only hunk's neighbours point at it, and the evidence above. It leaves out tests, fixtures and data
files unless nothing else changed, and defaults --cr-ledger to <git-common-dir>/cr-critic-scores.jsonl. Read the
candidates and choose: blame points at the last hand on a line, which a rename or a sweep can hide.
report and trace write nothing without --record; ingest writes ledger rows and sync marks them. Exit 0 done; 1 a seed PR outside the snapshot; 2 refused input.
Stdlib plus git only; no model call, and no network except the Jira comments of `sync`.
"""
import argparse
import collections
import datetime
import fcntl
import json
import os
import re
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, ".."))
sys.path.insert(0, os.path.join(HERE, "..", "lib"))
sys.path.insert(0, os.path.join(HERE, "..", "cr-ledger"))
sys.path.insert(0, os.path.join(HERE, "..", "judge-accuracy"))
import escapes  # noqa: E402
import cr_ledger_eval  # noqa: E402
import eval_runs  # noqa: E402
import judge_accuracy  # noqa: E402

EVAL_ID = "bug-origin"
SOURCE = "scripts/eval/bug-origin/bug-origin-report.py"
# What the report counts: a many-layer review-miss counts under review-miss:multi, a payload class under its prefix.
CLASSES = ("test-gap", "design-gap", "review-miss:cr", "review-miss:judge", "review-miss:panel", "review-miss:multi",
           "review-deferred", "residual", "trigger", "commit", "unknown")
LAYERS = ("cr", "panel", "judge")
CLEAN_PASS = " (a clean pass leaves no row)"
REPORT_FIELDS = ("number", "title", "body", "mergedAt", "headRefName", "headRefOid", "mergeCommit")

# The ERE of ready-check.sh's bug_origin_state; line-table.tsv runs through both. Classes: test-gap, design-gap,
# review-deferred, unknown, review-miss:<layers> (cr, judge, panel, comma-separated), residual:<token>, trigger:<token>
# and commit:<hex sha>. The payload forms are the chief's reading of the operator's R3 list, which gives no payloads.
# ponytail: one class per fix, upgrade path repeatable lines counted per class
LINE = re.compile(r"^bug-origin:[ \t]+(?:(#[0-9]+|[0-9a-f]{7,40})[ \t]+(" + judge_accuracy.CLASS_PATTERN + r")"
                  r"|(unknown)[ \t]+(unknown))[ \t]+(?:—|-)[ \t]+([^ \t].*)$")
JIRA_TIMEOUT = 60
FENCE = re.compile(r"^ {0,3}(`{3,}|~{3,})(.*)$")
KEY = re.compile(r"\[([A-Za-z][A-Za-z0-9]*-[0-9]+)\]")
SUBJECT_PR = re.compile(r"\(#(\d+)\)\s*$")

TRACE_FIELDS = ("number", "mergedAt", "headRefName", "headRefOid", "mergeCommit")
HUNK = re.compile(r"^@@ -(\d+)(?:,(\d+))? \+")
NOT_CODE = re.compile(r"(^|/)(test-[^/]*|test_[^/]*|[^/]*\.test\.[^/]*|[^/]*_test\.[^/]*)$"
                      r"|(^|/)(tests?|fixtures?|testdata)/|\.(tsv|jsonl|json|csv|lock)$")

Sources = collections.namedtuple("Sources", "rev recs ledger_read ledger_first verdicts_read verdicts_first")
Candidate = collections.namedtuple("Candidate", "sha count pr adjacent evidence")


def parse_body(body):
    """(state, fields): state none, malformed, duplicate or ok; fields {origin, class, reason} only when ok."""
    lines, fence = [], None
    for line in (body or "").replace("\r", "").split("\n"):
        m = FENCE.match(line)
        if fence:
            if m and m.group(1)[0] == fence[0] and len(m.group(1)) >= len(fence) and not m.group(2).strip(" \t"):
                fence = None
        elif m and not (m.group(1)[0] == "`" and "`" in m.group(2)):
            fence = m.group(1)
        elif line.startswith("bug-origin:"):
            lines.append(line)
    if not lines:
        return "none", None
    parsed = [LINE.match(line) for line in lines]
    if not all(parsed):
        return "malformed", None
    if len(parsed) > 1:
        return "duplicate", None
    g = parsed[0].groups()
    return "ok", {"origin": g[0] or g[2], "class": g[1] or g[3], "reason": g[4].rstrip()}


def family(cls):
    """The key the report counts a class under: review-miss with several layers is review-miss:multi, a payload class its prefix."""
    if cls.startswith("review-miss:"):
        layers = sorted(set(cls.split(":", 1)[1].split(",")))
        return "review-miss:multi" if len(layers) > 1 else "review-miss:" + layers[0]
    head = cls.split(":", 1)[0]
    return head if head in ("residual", "trigger", "commit") else cls


def layer_of(critic):
    """The review layer of a critic name, or None for a name that is no review."""
    name = critic.split(":", 1)[0]
    if name == "judge" or name.startswith("judge-"):
        return "judge"
    if name.startswith("coderabbit"):
        return "cr"
    if name in ("codex", "claude", "sonnet", "opus") or name.startswith(("codex-", "claude-", "gpt-")):
        return "panel"
    return None


def commit_to_pr(sha, merged, repo="."):
    """The PR of a commit: the one snapshot merge oid it prefixes, else the subject's (#n), else None."""
    hits = [n for n, p in merged.items() if ((p.get("mergeCommit") or {}).get("oid") or "").startswith(sha)]
    if hits:
        return hits[0] if len(hits) == 1 else None
    r = subprocess.run(["git", "-C", repo, "log", "-1", "--format=%s", sha, "--"], capture_output=True, text=True)
    m = SUBJECT_PR.search(r.stdout) if r.returncode == 0 else None
    return int(m.group(1)) if m else None


def stamp(d):
    return d.astimezone(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def load_sources(cr_ledger, verdicts):
    """The review sources; a missing or unreadable one reads as unread, never as an exception."""
    rows, ledger_read = [], False
    if cr_ledger and os.path.isfile(cr_ledger):
        try:
            rows = cr_ledger_eval.load(cr_ledger, None)[0]
            ledger_read = True
        except (OSError, ValueError):
            rows = []
    dated = [t for t in (judge_accuracy.when(str(r.get("ts") or "")) for r in rows) if t]
    recs, verdicts_read, firsts = [], bool(verdicts), []
    for root in verdicts:
        try:
            got = judge_accuracy.load_verdicts(root)[0]
        except (OSError, ValueError):
            verdicts_read = False
            continue
        recs += got
        firsts.append(min((r["at"] for r in got if r["at"]), default=None))
    return Sources(escapes.reviewers(rows), recs, ledger_read, min(dated, default=None), verdicts_read,
                   None if None in firsts or not firsts else min(firsts))


def evidence(p, merged, s):
    """{layer: state} for what each review layer has on record for a merged PR."""
    seen = {layer: set() for layer in LAYERS}
    if p.get("headRefName"):
        for critic in escapes.reviewed_before(s.rev, p):
            layer = layer_of(critic)
            if layer:
                seen[layer].add(critic.split(":", 1)[0])
    seen["judge"] |= escapes.judges(s.recs, merged).get(p["number"], set())
    cut = judge_accuracy.when(p["mergedAt"])
    out = {}
    for layer in LAYERS:
        read = s.ledger_read and (layer != "judge" or s.verdicts_read)
        firsts = [s.ledger_first] + ([s.verdicts_first] if layer == "judge" else [])
        if seen[layer]:
            out[layer] = "on record: " + ", ".join(sorted(seen[layer]))
        elif not read:
            out[layer] = "not read"
        elif None not in firsts and cut < min(firsts):
            out[layer] = "no coverage before " + stamp(min(firsts))
        else:
            out[layer] = "not on record" + (CLEAN_PASS if layer == "cr" else "")
    return out


def title_key(title):
    m = KEY.search(title or "")
    return m.group(1) if m else None


def load_seed(path):
    """{pr: {origin, class, reason}}; a row off the line grammar raises ValueError."""
    seed = {}
    try:
        with open(path, encoding="utf-8") as fh:
            for nr, line in enumerate(fh, 1):
                if not line.strip():
                    continue
                r = json.loads(line)
                state, got = parse_body("bug-origin: %s %s — %s" % (r.get("origin"), r.get("class"), r.get("reason")))
                if state != "ok" or got != {"origin": r["origin"], "class": r["class"], "reason": r["reason"]} or not isinstance(r.get("pr"), int):
                    raise ValueError("seed line %d is off the grammar" % nr)
                seed[r["pr"]] = got
    except (OSError, ValueError, AttributeError) as e:
        raise ValueError("unreadable --seed %s: %s" % (path, e))
    return seed


def load_prs(path, fields):
    prs = judge_accuracy.load_json(path, "--prs")
    for p in prs:
        missing = [f for f in fields if f not in p]
        if missing:
            raise ValueError("--prs is short of %s: gh pr list --json %s" % (", ".join(missing), ",".join(fields)))
    return {p["number"]: p for p in prs if judge_accuracy.when(p.get("mergedAt") or "")}


def origin_pr(row, merged, repo="."):
    """The merged PR an origin names, or None."""
    o = row["origin"]
    if o == "unknown":
        return None
    n = int(o[1:]) if o.startswith("#") else commit_to_pr(o, merged, repo)
    return n if n in merged else None


def collect(merged, seed, days, ledger=None):
    """(rows {pr: row}, unparsed [pr], outside [pr], window start or None).

    The ledger row is read first, then the PR body, then the seed."""
    rows, unparsed = {}, []
    ledger = ledger or {}
    for n, p in merged.items():
        if n in ledger:
            rows[n] = {k: ledger[n][k] for k in ("origin", "class", "reason")}
            continue
        state, got = parse_body(p.get("body"))
        if state == "ok":
            rows[n] = got
        elif state != "none":
            unparsed.append(n)
    outside = sorted(n for n in seed if n not in merged)
    for n, got in seed.items():
        if n in merged:
            rows.setdefault(n, got)
    def at(n):
        return judge_accuracy.when(merged[n]["mergedAt"])
    start = None
    if days is not None:
        start = datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(days=days)
        rows = {n: r for n, r in rows.items() if at(n) >= start}
        unparsed = [n for n in unparsed if at(n) >= start]
    elif rows:
        start = min(at(n) for n in rows)
    return rows, sorted(unparsed), outside, start


def report(merged, rows, unparsed, outside, start, s, bugs, has_seed):
    """Prints the five sections and returns the metrics."""
    m = {"rows": len(rows)}
    if has_seed:
        print("seed: hand-classified by one worker; no second reader checked it")
    if outside:
        print("seed PR outside snapshot: " + ", ".join("#%d" % n for n in outside))
    print("\n## Counts")
    print("rows: %d" % len(rows))
    count = collections.Counter(family(r["class"]) for r in rows.values())
    for c in CLASSES:
        print("%s: %d" % (c, count[c]))
        m["class." + c] = count[c]
    m["review_miss"] = sum(v for c, v in count.items() if c.startswith("review-miss:"))
    print("review-miss: %d" % m["review_miss"])

    credit, lines = collections.Counter(), []
    for n in sorted(rows):
        r = rows[n]
        if not r["class"].startswith("review-miss:"):
            continue
        claimed = r["class"].split(":", 1)[1]
        layers = list(dict.fromkeys(claimed.split(",")))
        o = origin_pr(r, merged)
        head = "fix #%d %s origin %s claimed %s" % (n, title_key(merged[n].get("title")) or "no-key", r["origin"], claimed)
        if o is None:
            lines.append(head + ": origin maps to no PR")
            continue
        e = evidence(merged[o], merged, s)
        for layer in LAYERS:
            credit[layer] += e[layer].startswith("on record")
        line = head + ": " + "; ".join("%s=%s" % (layer, e[layer]) for layer in LAYERS)
        missed = [layer for layer in layers if e[layer].startswith("not on record")]
        if missed:
            line += "; claimed layer " + (e[missed[0]] if len(layers) == 1 else ", ".join("%s %s" % (layer, e[layer]) for layer in missed))
        lines.append(line)
    print("\n## Credit (a row seen by three layers counts in all three, so this may sum above the row count)")
    for layer in LAYERS:
        print("credit %s: %d" % (layer, credit[layer]))
        m["credit." + layer] = credit[layer]
    print("\n## Review-miss rows")
    for line in lines:
        print(line)

    print("\n## Flags")
    by_key = {b["key"]: b for b in bugs or ()}
    flags = collections.Counter()
    for n in sorted(rows):
        r = rows[n]
        o = origin_pr(r, merged)
        if o is not None and (o == n or judge_accuracy.when(merged[o]["mergedAt"]) > judge_accuracy.when(merged[n]["mergedAt"])):
            print("impossible origin: fix #%d origin %s" % (n, r["origin"]))
            flags["impossible_origin"] += 1
        cb = (by_key.get(title_key(merged[n].get("title"))) or {}).get("caused_by")
        if o is not None and cb and cb.isdigit() and int(cb) != o:
            print("caused-by #%s disagrees: fix #%d origin %s" % (cb, n, r["origin"]))
            flags["caused_by_disagrees"] += 1
        if judge_accuracy.CITE.search(r["reason"]):
            print("reason names a PR: fix #%d" % n)
            flags["reason_names_pr"] += 1
    for n in unparsed:
        print("unparsed: #%d" % n)
    for name in ("impossible_origin", "caused_by_disagrees", "reason_names_pr"):
        m["flag." + name] = flags[name]
    m["unparsed"] = len(unparsed)

    print("\n## Coverage")
    if bugs is None:
        print("coverage: n/a (no mirror)")
        return m
    bug_keys = set(by_key)
    window = [n for n, p in merged.items() if start is not None and judge_accuracy.when(p["mergedAt"]) >= start]
    bug_prs = [n for n in window if title_key(merged[n].get("title")) in bug_keys]
    non_bug = sorted(n for n in rows if title_key(merged[n].get("title")) not in bug_keys)
    uncovered = [n for n in window if n not in rows and n not in bug_prs and escapes.FIX.match(merged[n].get("title") or "")]
    m.update({"coverage.bug_prs": len(bug_prs), "coverage.with_row": sum(n in rows for n in bug_prs),
              "coverage.bug_keys": len({title_key(merged[n].get("title")) for n in bug_prs}),
              "coverage.non_bug_rows": len(non_bug), "coverage.uncovered": len(uncovered)})
    print("coverage from %s" % (stamp(start) if start is not None else "no row"))
    print("Bug-ticket PRs: %d" % m["coverage.bug_prs"])
    print("with a row: %d" % m["coverage.with_row"])
    print("distinct Bug keys: %d" % m["coverage.bug_keys"])
    print("rows on non-Bug PRs: %d" % m["coverage.non_bug_rows"])
    for n in non_bug:
        print("non-Bug row: #%d" % n)
    print("fix-titled non-Bug PRs with no row: %d" % m["coverage.uncovered"])
    return m


def load_rows(path):
    """({pr: row} of a ledger directory with the rows off the line grammar left out, how many were left out)."""
    skipped = []
    rows = judge_accuracy.load_ledger(path, skipped)
    return rows, len(skipped)


def body_line(n, key, got):
    """The one plain line of a ledger row, which a search finds whether or not the index reads front matter."""
    return "PR #%d%s bug-origin: %s %s — %s" % (n, " (%s)" % key if key else "", got["origin"], got["class"], got["reason"])


def row_text(n, key, got, source, merged):
    front = [("pr", n), ("bug_key", key), ("origin", got["origin"]), ("class", got["class"]), ("reason", got["reason"]),
             ("source", source), ("ingested", stamp(datetime.datetime.now(datetime.timezone.utc))), ("merged", merged),
             ("synced", False)]
    lines = ["---"] + ["%s: %s" % (k, json.dumps(v, ensure_ascii=False)) for k, v in front] + ["---", body_line(n, key, got)]
    return "\n".join(lines) + "\n"


def write_file(path, text):
    """Write by a temp file in the same directory and rename, so a reader never sees half a row."""
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = "%s.tmp-%d" % (path, os.getpid())
    with open(tmp, "w", encoding="utf-8") as fh:
        fh.write(text)
    os.replace(tmp, path)


def write_once(path, text):
    """Create the row if no file is there and say whether this call did. The temp file is linked into place, so the row appears
    whole or not at all and a link onto an existing row fails: two ingests racing for one PR leave the first row byte for byte."""
    os.makedirs(os.path.dirname(path), exist_ok=True)
    # Created at 0666 and exclusively, so the umask and the directory's default ACL decide the mode, as for any file written here.
    tmp = "%s.tmp-%d-%s" % (path, os.getpid(), os.urandom(8).hex())
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o666)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            fh.write(text)
        os.link(tmp, path)
        return True
    except FileExistsError:
        return False
    finally:
        os.unlink(tmp)


def cmd_ingest(a):
    """Write one ledger row per merged PR whose body (else the seed) carries a bug-origin line; a PR with a row is kept as it is.

    ponytail: rows are write-once, so a body edited after its ingest is not re-read; upgrade path an --update flag."""
    path = a.ledger_dir or judge_accuracy.ledger_dir()
    if not path:
        print("bug-origin-report: refused: no ledger directory: set HANDOVER_DIR or pass --ledger-dir", file=sys.stderr)
        return 2
    try:
        merged = load_prs(a.prs, REPORT_FIELDS)
        seed = load_seed(a.seed) if a.seed else {}
    except ValueError as e:
        print("bug-origin-report: refused: %s" % e, file=sys.stderr)
        return 2
    wrote = kept = 0
    unparsed = []
    for n in sorted(merged):
        p = merged[n]
        state, got = parse_body(p.get("body"))
        source = "body"
        if state != "ok":
            if n not in seed:
                if state != "none":
                    unparsed.append(n)
                continue
            got, source = seed[n], "seed"
        try:
            made = write_once(os.path.join(path, "%d.md" % n), row_text(n, title_key(p.get("title")), got, source, p["mergedAt"]))
        except OSError as e:
            print("bug-origin-report: cannot write the row of #%d under %s: %s" % (n, path, e), file=sys.stderr)
            return 2
        wrote, kept = wrote + made, kept + (not made)
    print("ingest: wrote %d, kept %d" % (wrote, kept))
    for n in unparsed:
        print("unparsed: #%d" % n)
    outside = sorted(n for n in seed if n not in merged)
    if outside:
        print("seed PR outside snapshot: " + ", ".join("#%d" % n for n in outside))
    return 1 if outside else 0


def jira_command(explicit):
    """The Jira CLI argv, or None when there is none to run."""
    if explicit:
        return [explicit] if os.access(explicit, os.X_OK) else None
    index = os.path.join(judge_accuracy.primary_checkout(), "scripts", "jira", "dist", "index.js")
    return ["node", index] if os.path.isfile(index) else None


def jira_project_key():
    """The Jira project key where the Jira CLI finds it, or '': the environment, then himmel.conf.local and himmel.conf in
    $HIMMEL_CONFIG_DIR (else ~/.himmel), then the .env of the git checkout this runs in and of its primary checkout."""
    key = os.environ.get("JIRA_PROJECT_KEY")
    if key:
        return key
    conf = os.environ.get("HIMMEL_CONFIG_DIR") or os.path.join(os.environ.get("HOME") or os.path.expanduser("~"), ".himmel")
    top = git("rev-parse", "--show-toplevel")
    files = [os.path.join(conf, "himmel.conf.local"), os.path.join(conf, "himmel.conf")]
    files += [os.path.join(d, ".env") for d in ([top.strip()] if top and top.strip() else []) + [judge_accuracy.primary_checkout()]]
    return next((v for v in (judge_accuracy.conf_value(f, "JIRA_PROJECT_KEY") for f in files) if v), "")


def cmd_sync(a):
    """Comment each unsynced row's line on its Bug ticket, once.

    No Jira project key anywhere is a skip. A key with no Jira CLI to run is a failure, exit 2. A Jira error warns, leaves the
    row unsynced and exits 1 when any comment failed; the next run retries it."""
    path = a.ledger_dir or judge_accuracy.ledger_dir()
    if not path:
        print("bug-origin-report: refused: no ledger directory: set HANDOVER_DIR or pass --ledger-dir", file=sys.stderr)
        return 2
    if not jira_project_key():
        print("jira sync skipped: not configured")
        return 0
    cmd = jira_command(a.jira_cmd)
    if cmd is None:
        why = ("--jira-cmd %s is not executable" % a.jira_cmd if a.jira_cmd
               else "no Jira CLI found (scripts/jira/dist/index.js under the checkout; build it with npm run build there)")
        print("bug-origin-report: refused: a Jira project key is set but %s" % why, file=sys.stderr)
        return 2
    if not os.path.isdir(path):
        print("jira sync: 0 updated")
        return 0
    updated = failed = 0
    with open(os.path.join(path, ".sync.lock"), "a") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            print("jira sync skipped: another sync holds the ledger")
            return 0
        for n, row in sorted(judge_accuracy.load_ledger(path).items()):
            key = row.get("bug_key")
            if not isinstance(key, str) or row.get("synced") is True:
                continue
            fd, comment = tempfile.mkstemp(suffix=".md")
            try:
                with os.fdopen(fd, "w", encoding="utf-8") as fh:
                    fh.write(body_line(n, key, row) + "\n")
                ok = subprocess.run(cmd + ["comment", key, "--comment-file", comment], capture_output=True,
                                    timeout=JIRA_TIMEOUT).returncode == 0
            except (OSError, subprocess.TimeoutExpired):
                ok = False
            finally:
                os.unlink(comment)
            if not ok:
                failed += 1
                print("warn: jira comment on %s failed; the row stays unsynced" % key, file=sys.stderr)
                continue
            file = os.path.join(path, "%d.md" % n)
            with open(file, encoding="utf-8") as fh:
                text = fh.read()
            marked = text.replace("\nsynced: false\n", "\nsynced: true\n", 1)
            if marked == text:  # a row with no synced line: add one before the closing delimiter
                end = text.find("\n---\n", 3)
                marked = text[:end] + "\nsynced: true" + text[end:]
            write_file(file, marked)
            updated += 1
    print("jira sync: %d updated%s" % (updated, ", %d failed, retried on the next run" % failed if failed else ""))
    return 1 if failed else 0


def cmd_report(a):
    try:
        merged = load_prs(a.prs, REPORT_FIELDS)
        seed = load_seed(a.seed) if a.seed else {}
    except ValueError as e:
        print("bug-origin-report: refused: %s" % e, file=sys.stderr)
        return 2
    try:
        bugs = judge_accuracy.load_bugs(a.mirror) if a.mirror else None
    except (OSError, ValueError):
        bugs = None
    if a.cls is not None and not judge_accuracy.valid_class(a.cls):
        print("bug-origin-report: refused: --class %r is no class this report knows" % a.cls, file=sys.stderr)
        return 2
    ledger_path = a.ledger_dir or judge_accuracy.ledger_dir()
    ledger, off = load_rows(ledger_path)
    rows, unparsed, outside, start = collect(merged, seed, a.days, ledger)
    if ledger_path and os.path.isdir(ledger_path):
        print("ledger: %d rows from %s" % (len(ledger), ledger_path))
    else:
        print("ledger: none (set HANDOVER_DIR or pass --ledger-dir)")
    if off:
        print("ledger rows off the grammar: %d" % off)
    if a.cls is not None:
        print("class filter: " + a.cls)
        rows = {n: r for n, r in rows.items() if judge_accuracy.class_match(a.cls, r["class"])}
        unparsed = []
    s = load_sources(a.cr_ledger, a.verdicts or [])
    m = report(merged, rows, unparsed, outside, start, s, bugs, bool(a.seed))
    if a.record:
        row = eval_runs.make_row(EVAL_ID, SOURCE, {"bug_origin_v": 1, "days": a.days, "seed": bool(a.seed)}, m, n=len(rows))
        eval_runs.append_safe(row, a.ledger, who=EVAL_ID)
    return 1 if outside else 0


def git(*args, repo="."):
    """A git command's stdout, or None when it fails."""
    r = subprocess.run(["git", "-C", repo, *args], capture_output=True, text=True, errors="replace")
    return r.stdout if r.returncode == 0 else None


def read_git(*args, repo="."):
    """A git command's stdout; a failure refuses, so a failed read never looks like a diff that changes nothing."""
    out = git(*args, repo=repo)
    if out is None:
        raise ValueError("git %s failed" % args[0])
    return out


def changed_paths(base, head, repo="."):
    """[(status, base path, head path)] of a diff, renames followed; tests and data left out unless nothing else changed."""
    fields = read_git("diff", "-M", "--name-status", "-z", base, head, repo=repo).split("\0")
    out, i = [], 0
    while i < len(fields) and fields[i]:
        status = fields[i][0]
        if status in "RC":
            out.append((status, fields[i + 1], fields[i + 2]))
            i += 3
        else:
            out.append((status, fields[i + 1], fields[i + 1]))
            i += 2
    kept = [c for c in out if not NOT_CODE.search(c[2])]
    return kept or out


def touched_lines(base, head, old, new, repo="."):
    """(lines the diff changes, lines beside an add-only hunk), numbered at the base."""
    changed, adjacent = set(), set()
    for line in read_git("diff", "-M", "-U0", base, head, "--", old, new, repo=repo).split("\n"):
        m = HUNK.match(line)
        if not m:
            continue
        start, n = int(m.group(1)), int(m.group(2) or 1)
        if n:
            changed.update(range(start, start + n))
        else:
            adjacent.update({max(start, 1), start + 1})
    return changed, adjacent - changed


def trace(base, head, merged, s, repo="."):
    """Up to three candidates for the commit that introduced what base..head changes, blamed at their merge base."""
    fork = git("merge-base", base, head, repo=repo)
    if fork is None:
        raise ValueError("no merge base of %s and %s" % (base, head))
    fork = fork.strip()
    tally = collections.defaultdict(lambda: [0, 0])
    for status, old, new in changed_paths(fork, head, repo):
        if status == "A":
            continue
        blame = read_git("blame", "-w", "-s", "-l", "--root", fork, "--", old, repo=repo)
        shas = [line.split(" ", 1)[0] for line in blame.split("\n") if line]
        changed, adjacent = touched_lines(fork, head, old, new, repo)
        for lines, slot in ((changed, 0), (adjacent, 1)):
            for nr in lines:
                if nr <= len(shas):
                    tally[shas[nr - 1]][slot] += 1
    top = sorted(tally.items(), key=lambda kv: (-kv[1][0], -kv[1][1], kv[0]))[:3]
    out = []
    for sha, (changed, adjacent) in top:
        n = commit_to_pr(sha, merged or {}, repo)
        e = None
        if n is not None:
            e = evidence(merged[n], merged, s) if merged and n in merged else dict.fromkeys(LAYERS, "not read")
        out.append(Candidate(sha, changed + adjacent, n, not changed, e))
    return out


def cmd_trace(a):
    try:
        merged = load_prs(a.prs, TRACE_FIELDS) if a.prs else None
    except ValueError as e:
        print("bug-origin-report: refused: %s" % e, file=sys.stderr)
        return 2
    ledger = a.cr_ledger
    if not ledger:
        common = git("rev-parse", "--path-format=absolute", "--git-common-dir")
        ledger = os.path.join(common.strip(), "cr-critic-scores.jsonl") if common else None
    try:
        found = trace(a.base, a.head, merged, load_sources(ledger, a.verdicts or []))
    except ValueError as e:
        print("bug-origin-report: refused: %s" % e, file=sys.stderr)
        return 2
    if not found:
        print("no candidate: the diff changes no line that exists at the base")
    for c in found:
        pr = "PR #%d" % c.pr if c.pr is not None else "no PR"
        line = "%s lines=%d %s%s" % (c.sha[:12], c.count, pr, " adjacent" if c.adjacent else "")
        if c.evidence:
            line += ": " + "; ".join("%s=%s" % (layer, c.evidence[layer]) for layer in LAYERS)
        print(line)
    return 0


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    t = sub.add_parser("trace")
    t.add_argument("--base", required=True)
    t.add_argument("--head", required=True)
    t.add_argument("--prs")
    t.add_argument("--cr-ledger")
    t.add_argument("--verdicts", action="append")
    t.set_defaults(func=cmd_trace)
    r = sub.add_parser("report")
    r.add_argument("--prs", required=True)
    r.add_argument("--seed")
    r.add_argument("--cr-ledger")
    r.add_argument("--verdicts", action="append")
    r.add_argument("--mirror")
    r.add_argument("--days", type=int)
    r.add_argument("--record", action="store_true")
    r.add_argument("--ledger")
    r.add_argument("--ledger-dir")
    r.add_argument("--class", dest="cls")
    r.set_defaults(func=cmd_report)
    i = sub.add_parser("ingest")
    i.add_argument("--prs", required=True)
    i.add_argument("--seed")
    i.add_argument("--ledger-dir")
    i.set_defaults(func=cmd_ingest)
    y = sub.add_parser("sync")
    y.add_argument("--ledger-dir")
    y.add_argument("--jira-cmd")
    y.set_defaults(func=cmd_sync)
    a = ap.parse_args(argv)
    return a.func(a)


if __name__ == "__main__":
    sys.exit(main())
