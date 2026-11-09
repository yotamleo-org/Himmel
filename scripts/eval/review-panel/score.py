#!/usr/bin/env python3
"""scripts/eval/review-panel/score.py - score critic-panel output against the
seed key (HIMMEL-4649): recall, precision and false-positive rate per critic,
per class and for the panel as a whole, with n and Wilson 95% intervals; one
row per sweep into the eval-runs ledger (scripts/eval/lib/eval_runs.py).

  score.py lint  [--fixtures DIR] [--key FILE] [--min-real N] [--src REPO]
  score.py score --outputs DIR --critics a,b [--fixtures DIR] [--key FILE]
                 [--only case-01,case-02] [--window N] [--json OUT]
                 [--ledger PATH | --no-ledger] [--meta-json J] [--model M]
  score.py cbs-paths  <rev> [--repo R]     the critic behaviour set (cbs.txt) expanded at <rev>
  score.py cbs-hash   <rev> [--repo R]     64-hex over those paths and their bytes
  score.py confighash <rev> [--repo R]     the eval config at <rev>: fixture set, key, paid roster, window
  score.py stamp <outputs-dir> [--fixtures D] [--key F] [--panel CMD] [--tiers T] [--only IDS] [--repo R]   record the
                                           swept tree (run.sh does it)
  score.py export-row <outputs-dir> [--repo R] [--results FILE]   append one gate row (HEAD's hashes; refuses
                                           outputs whose swept.json is unclean or names other hashes)
  score.py verify-row <row-json> <outputs-dir> [--tree REV] [--repo R]   exit 1 unless the row re-scores so
  score.py gate <base> <head> [--target-class C]... [--repo R]   keep | no-loss | loss | unmeasured | mismatch
  score.py scorer-identity [--json]        the running scorer's identity (read-only; rows carry it)

Inputs. fixtures/case-NN.patch are the frozen synthetic diffs the panel reviews,
fixtures/real-*.patch real escapes (a multi-file diff with a `base` sha, the
`fix` commit that repaired it, an optional `context_seed` file outside the diff
and an optional frozen <id>.intent.md); key/seeds.json maps each case to its
twin pair, kind (seeded | clean), split (open | sealed) and defects
({id, class, file, line}). <outputs>/<id>.md is the panel's stdout for that
case, <outputs>/<id>.err its stderr (optional).

Merge gate (HIMMEL-8426). A <rev> is a git tree-ish of --repo (default this
checkout); files are read from the tree, never the work tree. results.jsonl
holds one row per sweep; gate reads the head tree's rows and prints
eval_feedback.gate_verdict: exit 0 keep / no-loss, 1 loss / unmeasured / mismatch, 2 error.

Split (README "Open and sealed seeds"). Every metric is also reported per half
as open.<metric> and sealed.<metric>, each with its own interval. Tuning
(eval_feedback.py) reads the open half only; the sealed half only grades
whether a change is kept. Lint refuses a case with no split, twins in
different halves, and a class with no pair in one half.

Matching (README "Matching rules"). A finding is a `- [<critic>-<n>]: <text>
[<file>:<line>]` bullet under Critical / Important / Suggestions. It hits a
defect when the file matches and |line - seed line| <= window (default 3)
(a LOCATION hit), and its text matches the defect class's keyword pattern
(a CLASS hit). recall counts defects with a location+class hit; recall_loc
counts location hits only (the upper bound, so a brittle keyword list shows
as a gap, not a silent loss); recall_gating counts hits at Critical or
Important, the severities the CR gate blocks on. precision = findings that
hit some defect / all findings. fp_rate = clean twins with >= 1 Critical or
Important finding / clean twins scored. These are automated diagnostic proxies,
not verified accuracy; each is also written under its explicit name:
key_match_recall, key_match_recall_gating, location_match_recall,
key_match_precision, labelled_clean_block_rate.

Exit: 0 scored / lint clean; 1 lint problems; 2 refused input.
Stdlib only; no network, no model call.
"""
import argparse
import datetime
import fnmatch
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import uuid

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "lib"))
import eval_feedback  # noqa: E402
import eval_runs  # noqa: E402
from wilson import wilson  # noqa: E402

EVAL_ID = "review-panel"
SOURCE = "scripts/eval/review-panel/score.py"
DEFAULT_WINDOW = 3
GATING = ("crit", "imp")
CASE_FILE = re.compile(r"^(case|real|delta)-[^/]+\.patch$")
DELTA_SUFFIX = ".delta.patch"  # <id>.delta.patch: the fix delta of a delta case (key "delta": true)
# Repo-relative paths the gate reads from a tree.
REL = "scripts/eval/review-panel"
CBS_LIST, RESULTS = REL + "/cbs.txt", REL + "/results.jsonl"
FIXTURES_REL, KEY_REL = REL + "/fixtures", REL + "/key/seeds.json"
CRITICS_REL = "scripts/cr/critics.json"
ROSTER_TIER = "paid"  # run.sh's default --tiers: the roster a gate sweep runs
PANEL_REL = "scripts/cr/critic-panel.sh"
LEAK_MIN = 12  # a fix line shorter than this (fi, done, a brace) is too common to prove a leak

# Class keyword patterns, matched case-insensitively against a finding's text.
# Deliberately broad: location already pins the finding to the seeded lines, so
# the class check only has to tell "the bug" from "some other remark here".
# ponytail: hand-written keywords, tuned on canned text only; recall_loc bounds
# the loss - hand-label the first real sweep's location-only hits and retune.
CLASS_PATTERNS = {
    "logic": r"off[- ]by[- ]one|one (too many|too few|fewer|extra|more|less)|invert|revers|wrong "
             r"(comparison|condition|operator|direction|count|boundary)|boundary|logic|always "
             r"(true|false|fails?|gives? up|retr)|never (retr|true|false)|immediately|"
             r"incorrect(ly)? (count|compar|condition)|keeps? (one )?fewer|deletes? (one|the newest)|"
             r"(should|must) be [<>]=?|[<>]=? (should|must)",
    "quoting": r"quot|word[- ]?split|glob|IFS|whitespace|spaces? in|\$\(ls|parsing ls|ls output",
    "fail-open": r"fail[s]?[- ]?open|fail[- ]closed|fails? (open|closed)|allow(s|ed)? .{0,40}"
                 r"(error|fail|missing|unreadable|invalid|malformed|exception)|"
                 r"(error|fail\w*|missing|unreadable|invalid|malformed|exception).{0,60}"
                 r"(allow|accept|pass|true|bypass)|bypass|swallow|suppress|silenc|"
                 r"2>/dev/null|returns? true|treated as (valid|allow)",
    "toctou": r"toctou|race|time[- ]of[- ]check|check[- ](then|and)[- ]\w+|symlink|atomic|"
              r"concurrent|noclobber|predictable|world[- ]writable|between the (check|exist)|"
              r"o_excl|mkstemp|mkdir",
    "test-cannot-fail": r"(cannot|can't|can never|never|always) (fail|pass)|vacuous|tautolog|"
                        r"itself|same (call|expression|value)|both sides|PIPESTATUS|pipefail|"
                        r"(status|rc|exit code) of (tee|the pipeline|the last)|tee'?s (exit|status)|"
                        r"not (actually )?(test|check|assert|verif)|no(thing)? (is )?(tested|checked|asserted)",
    "scope-creep": r"unrelated|scope|not mentioned|undocumented|unannounced|unexplained|"
                   r"silent(ly)? (chang|lower|rais|reduc|increas|shorten)|behaviou?r change|"
                   r"(retention|timeout|default)\b.{0,40}(chang|lower|rais|reduc|increas|shorten|from)|"
                   r"(chang|lower|rais|reduc|increas|shorten)\w*.{0,40}(retention|timeout|default)",
    "cross-file": r"caller|reader|consumer|other file|not updated|out of sync",
    "spec-miss": r"ticket|definition of done|requirement|asked|does not implement",
}
CLASSES = sorted(CLASS_PATTERNS)

# Strings that tie a fixture or a transcript to the key. A fixture carrying any
# of them (or a hint word) is refused by lint; a transcript carrying one is a
# leak: the critic saw (or echoed) the answer, so the sweep is inconclusive.
# ponytail: string evidence only - a critic that read the key and never echoed
# it is not caught; scan the critic's tool-call log once hermes records one.
KEY_MARKERS = ("review-panel/key", "seeds.json")
HINT_WORDS = re.compile(r"\b(seed(ed|s)?|inject(ed|ion)?|planted|defect|canary)\b", re.I)

SECTION = re.compile(r"^## (Critical Issues|Important Issues|Suggestions|"
                     r"Already Dispositioned Re-raises|Dropped Citations|Note|REVIEW NOT PERFORMED)")
SEV = {"Critical Issues": "crit", "Important Issues": "imp", "Suggestions": "sug"}
BULLET = re.compile(r"^- \[([A-Za-z0-9._]+(?:-[A-Za-z0-9._]+)*?)-(\d+)\]: (.*?)\s*\[([^\]\s]+):(\d+)\]\s*$")
GUARD = "citation-guard"
CITATION_GUARD = re.compile(r"^- \[" + GUARD + r"-[0-9a-f]{16}\]: \S")
GUARD_SHAPED = re.compile(r"^- \[" + GUARD + r"-")
FINDING_SHAPED = re.compile(r"^- \[[A-Za-z0-9._-]+-\d+\]")
UNAVAILABLE = re.compile(r"^- ([A-Za-z0-9._-]+): unavailable\b")
HEADER = re.compile(r"^# Critic Panel Review \((\d+)/(\d+) critics responded\)\s*$")
AVAIL = re.compile(r"^panel-availability: ([A-Za-z0-9._-]+) (.*)$")
AVAIL_OK = re.compile(r"^(?:ok(?: responding-model\(([^)]*)\))?|fallback\(([^)]*)\))\s*$")
REASON = re.compile(r"\breason=([A-Za-z0-9._-]+)")
SKIP_OUTSIDE_HEADER = ("tier-excluded", "keep-one-skipped")
SKIP_IN_HEADER = ("critic-skipped",)
PRE_LAUNCH = "panel-deadline"
CATEGORIES = ("answer", "protocol-skip", "failure", "inconsistent", "unknown")
PROXY_ALIASES = {"key_match_recall": "recall", "key_match_recall_gating": "recall_gating",
                 "location_match_recall": "recall_loc", "key_match_precision": "precision",
                 "labelled_clean_block_rate": "fp_rate"}
HEX64 = re.compile(r"^[0-9a-f]{64}$")
MANIFEST = "run-manifest.json"
# The panel's own environment settings a sweep may carry; each is recorded in the manifest's protocol.
RECORDED_OVERRIDES = ("CRITIC_TIMEOUT_SECS", "CRITIC_PANEL_TOTAL_TIMEOUT_SECS", "CRITIC_KILL_GRACE_SECS",
                      "CRITIC_PARALLEL", "CRITIC_FIRST_PASS_CAP_BYTES")
# A stderr line of a case whose panel exited 0 that still says the run went wrong.
ANOMALY = re.compile(r"unbound variable|command not found|Traceback \(most recent call last\)|syntax error")


def norm_path(p):
    p = p.strip()
    for pre in ("a/", "b/", "./"):
        if p.startswith(pre):
            p = p[len(pre):]
    return p


def load_key(path):
    with open(path, encoding="utf-8") as fh:
        key = json.load(fh)
    if not isinstance(key, dict) or "cases" not in key or "canary" not in key:
        raise ValueError("key needs canary and cases")
    return key


def patch_files(text):
    """{new-file path: {added new-file line numbers}} of a git diff (a deleted file is left out)."""
    files, path, new_line = {}, None, None
    for line in text.splitlines():
        if line.startswith("diff --git "):
            path, new_line = None, None
        elif line.startswith("+++ "):
            path = None if line[4:].strip() == "/dev/null" else norm_path(line[4:])
            if path:
                files.setdefault(path, set())
        elif line.startswith("@@"):
            m = re.match(r"@@ -\d+(?:,\d+)? \+(\d+)(?:,\d+)? @@", line)
            new_line = int(m.group(1)) if m and path else None
        elif new_line is not None:
            if line.startswith("+"):
                files[path].add(new_line)
                new_line += 1
            elif line.startswith(" ") or line == "":
                # An empty line is a blank context line whose leading space the
                # repo's trailing-whitespace hook strips (git apply reads it so).
                new_line += 1
    return files


def added_text(text):
    """The stripped added lines of a diff."""
    return {ln[1:].strip() for ln in text.splitlines() if ln.startswith("+") and not ln.startswith("+++")}


def fix_leaks(src, fix, case_text, intent):
    """Added lines of the fixing commit (>= LEAK_MIN chars) found in the seeded case's added lines or intent.
    ponytail: exact stripped-line match only; a reworded copy of the fix passes, upgrade = token-overlap score."""
    out = subprocess.run(["git", "-C", src, "show", "--format=", "--no-color", "--no-ext-diff", fix],
                         capture_output=True, text=True, errors="replace")
    if out.returncode != 0:
        raise ValueError("fix %s is not a commit of %s" % (fix, src))
    mine = added_text(case_text)
    return sorted(ln for ln in added_text(out.stdout) if len(ln) >= LEAK_MIN and (ln in mine or ln in intent))


def apply_problem(fixtures, key_path, cid, src):
    """None when run.sh --case-repo builds the case on its base tree, else the reason it did not."""
    tmp = tempfile.mkdtemp(prefix="review-panel-apply.")
    try:
        r = subprocess.run(["bash", os.path.join(HERE, "run.sh"), "--case-repo", cid, "--out",
                            os.path.join(tmp, "repo"), "--fixtures", fixtures, "--key", key_path, "--src", src],
                           capture_output=True, text=True, errors="replace")
        return None if r.returncode == 0 else (r.stderr.strip().splitlines() or ["rc %d" % r.returncode])[-1]
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def delta_apply_problem(round1, delta):
    """None when the delta applies on the tree the round-1 diff builds, else the reason it does not."""
    tmp = tempfile.mkdtemp(prefix="review-panel-delta.")
    try:
        for name, body in (("round1.patch", round1), ("delta.patch", delta)):
            with open(os.path.join(tmp, name), "w", encoding="utf-8") as fh:
                fh.write(body)
        for name in ("round1.patch", "delta.patch"):
            # No --unsafe-paths: git refuses a path that leaves the working area (the cwd, outside a checkout).
            r = subprocess.run(["git", "apply", "--directory", "tree", name],
                               capture_output=True, text=True, errors="replace", cwd=tmp)
            if r.returncode != 0:
                return "%s: %s" % (name, (r.stderr.strip().splitlines() or ["rc %d" % r.returncode])[-1])
        return None
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def lint(fixtures, key_path, min_real=0, src=None):
    problems = []
    try:
        key = load_key(key_path)
    except (OSError, ValueError) as e:
        return ["key %s: %s" % (key_path, e)], 0, 0
    cases = key["cases"]
    names = os.listdir(fixtures)
    files = sorted(f[:-6] for f in names if CASE_FILE.match(f) and not f.endswith(DELTA_SUFFIX))
    if sorted(cases) != files:
        problems.append("fixtures and key disagree: only-fixture=%s only-key=%s"
                        % (sorted(set(files) - set(cases)), sorted(set(cases) - set(files))))
    # A delta case (key "delta": true) is <id>.patch (the round-1 diff) plus <id>.delta.patch (the fix delta,
    # which holds the seed); a delta patch of any other case is an orphan.
    for n in sorted(names):
        if n.endswith(DELTA_SUFFIX) and not (cases.get(n[:-len(DELTA_SUFFIX)], {}).get("delta") is True):
            problems.append("%s: a delta patch of a case the key does not mark delta" % n)
    n_real = sum(1 for f in files if f.startswith("real-"))
    if n_real < min_real:
        problems.append("only %d real-* cases, --min-real wants %d" % (n_real, min_real))
    pairs, splits, pair_classes = {}, {}, {}
    for cid in files:
        with open(os.path.join(fixtures, cid + ".patch"), encoding="utf-8") as fh:
            text = fh.read()
        ipath = os.path.join(fixtures, cid + ".intent.md")
        intent = open(ipath, encoding="utf-8", errors="replace").read() if os.path.isfile(ipath) else ""
        c = cases.get(cid)
        is_delta = bool(c) and c.get("delta") is True
        dtext = None
        if is_delta:
            dpath = os.path.join(fixtures, cid + DELTA_SUFFIX)
            if os.path.isfile(dpath):
                with open(dpath, encoding="utf-8") as fh:
                    dtext = fh.read()
            else:
                problems.append("%s: a delta case needs %s%s" % (cid, cid, DELTA_SUFFIX))
        for label, body in ((cid, text), (cid + ".delta", dtext or "")):
            for marker in (key["canary"],) + KEY_MARKERS:
                if marker in body or (body is text and marker in intent):
                    problems.append("%s: carries key marker %r" % (label, marker))
            m = HINT_WORDS.search(body)
            if m:
                problems.append("%s: carries hint word %r" % (label, m.group(0)))
        if not c:
            continue
        if is_delta and dtext is not None and not c.get("base"):
            why = delta_apply_problem(text, dtext)
            if why:
                problems.append("%s: the delta does not apply on the round-1 diff: %s" % (cid, why))
        # A delta case's seed sits in the delta; its twin comparison reads the delta too.
        diff = patch_files((dtext or "") if is_delta else text)
        ctx = norm_path(c.get("context_seed") or "")
        if c.get("kind") not in ("seeded", "clean"):
            problems.append("%s: kind must be seeded or clean" % cid)
        if (c.get("kind") == "seeded") != bool(c.get("defects")):
            problems.append("%s: a seeded case needs defects and a clean one none" % cid)
        for d in c.get("defects", []):
            f = norm_path(d.get("file", ""))
            if d.get("class") not in CLASS_PATTERNS:
                problems.append("%s: unknown class %r" % (cid, d.get("class")))
            if f in diff:
                if d.get("line") not in diff[f]:
                    problems.append("%s: seed line %r is not an added line of its diff" % (cid, d.get("line")))
            elif not (ctx and f == ctx):
                problems.append("%s: seed file %r is neither in the diff %s nor the context_seed"
                                % (cid, d.get("file"), sorted(diff)))
        if c.get("split") not in ("open", "sealed"):
            problems.append("%s: split must be open or sealed" % cid)
        if c.get("base") or c.get("fix"):
            src = src or toplevel()
        if c.get("base"):
            why = apply_problem(fixtures, key_path, cid, src)
            if why:
                problems.append("%s: the diff does not build on its base %s: %s" % (cid, c["base"], why))
        if c.get("kind") == "seeded" and c.get("fix"):
            try:
                leaked = fix_leaks(src, c["fix"], text, intent)
            except ValueError as e:
                problems.append("%s: %s" % (cid, e))
                leaked = []
            if leaked:
                problems.append("%s: carries %d line(s) of its fix %s, e.g. %r" % (cid, len(leaked), c["fix"], leaked[0]))
        seeds = {norm_path(d.get("file", "")) for d in c.get("defects", [])} & set(diff)
        pairs.setdefault(c.get("pair"), []).append((c.get("kind"), set(diff), seeds))
        splits.setdefault(c.get("pair"), set()).add(c.get("split"))
        for d in c.get("defects", []):
            pair_classes.setdefault(c.get("pair"), set()).add(d.get("class"))
    for pair, members in sorted(pairs.items()):
        kinds = sorted(k for k, _, _ in members)
        # The clean twin holds every in-diff seed file of the seeded twin (one-file cases: the same file).
        ok = kinds == ["clean", "seeded"]
        if ok:
            (_, sp, seeds), (_, cp, _) = sorted(members, key=lambda m: m[0] != "seeded")
            ok = seeds <= cp and bool(sp & cp)
        if not ok:
            problems.append("pair %s: needs one seeded and one clean twin sharing the seed's file, got %s"
                            % (pair, [(k, sorted(p)) for k, p, _ in members]))
        if len(splits[pair]) != 1:
            problems.append("pair %s: its twins are in different halves of the split" % pair)
    halves = {}
    for pair, classes in pair_classes.items():
        for cls in classes:
            for half in splits[pair]:
                halves.setdefault(cls, set()).add(half)
    for cls, got in sorted(halves.items()):
        if not {"open", "sealed"} <= got:
            problems.append("class %s: needs a pair in each half of the split, got %s" % (cls, sorted(map(str, got))))
    n_seeded = sum(1 for c in cases.values() if c.get("kind") == "seeded")
    return problems, n_seeded, len(cases) - n_seeded


def parse_review(text):
    """(findings, unavailable critics, performed). A finding is a dict with
    critic, sev, file, line, text, at (its stdout line number); bullets outside the three severity
    sections (re-raises, dropped citations) are not findings. The panel's
    citation-guard Critical is one, under the pseudo-critic GUARD. unavailable maps each critic an
    unavailable bullet names to (its reason= or None, the bullet's line number)."""
    findings, unavailable, performed, sev, in_note = [], {}, True, None, False
    declared, counted, malformed = {}, {}, 0
    for at, line in enumerate(text.splitlines(), 1):
        m = SECTION.match(line)
        if m:
            name = m.group(1)
            sev = SEV.get(name)
            if sev:
                n = re.search(r"\((\d+) found\)", line)
                declared[sev] = int(n.group(1)) if n else -1
                counted.setdefault(sev, 0)
            in_note = name == "Note"
            if name == "REVIEW NOT PERFORMED":
                performed = False
            continue
        if line.startswith("Unavailable critics:"):
            in_note = True
            continue
        u = UNAVAILABLE.match(line)
        if u and (in_note or not performed):
            r = REASON.search(line)
            unavailable.setdefault(u.group(1), (r.group(1) if r else None, at))
            continue
        # Count only bullets BULLET parses: a malformed one (no [file:line])
        # leaves the count short of the heading, so the case is unscored
        # rather than scored with that finding lost.
        # The guard's bullet (a critic cited a line that does not exist and the
        # panel dropped it) is a blocking Critical of the panel, so on a clean
        # twin it is a real false block. It counts toward the heading and is
        # kept as a panel-level finding (no location, so it never hits a
        # defect); member_metrics counts it for fp_rate only.
        if sev and CITATION_GUARD.match(line):
            counted[sev] += 1
            findings.append({"critic": GUARD, "sev": sev, "text": line, "file": "", "line": 0, "at": at})
            continue
        b = BULLET.match(line)
        if b and sev:
            critic = b.group(1)
            counted[sev] += 1
            findings.append({"critic": critic, "sev": sev, "text": b.group(3),
                             "file": norm_path(b.group(4)), "line": int(b.group(5)), "at": at})
        elif sev and (FINDING_SHAPED.match(line) or GUARD_SHAPED.match(line)):
            # Finding-shaped but rejected by BULLET: flagged apart from the
            # declared count, which a hand-edited heading can make agree.
            malformed += 1
    # The panel prints all three severity headings, each with its bullet count,
    # on every completed review; a transcript missing a heading or a bullet was
    # cut short and is not a zero-finding review.
    if not text.lstrip().startswith("# Critic Panel Review") or set(SEV.values()) - set(declared) \
            or declared != counted or malformed:
        performed = False
    return findings, unavailable, performed


def _absence(reason):
    if reason in SKIP_OUTSIDE_HEADER:
        return "protocol-skip", False, False
    if reason in SKIP_IN_HEADER:
        return "protocol-skip", False, True
    if reason == PRE_LAUNCH:
        return "failure", True, False
    if reason is None:
        return "unknown", None, None
    return "failure", True, True


def case_participation(roster, text, stderr, findings, performed):
    """{critic: {state, category, effective, header_included, reason, evidence, responding_model}} for one case.

    state is answered | unavailable | unknown; category answer | protocol-skip | failure | inconsistent | unknown;
    evidence lists stdout:/stderr: line references, never raw text. An answer is a valid finding or an ok/fallback
    receipt; an absence is an unavailable bullet or receipt. A critic with neither is an answer only when the header
    N/M reconciles: M equals the header-counted critics and the N answer slots left are exactly those critics. Any
    other unaccounted critic stays unknown (no failure reason is inferred), and an answer beside an absence, absences
    that disagree, non-rostered finding slugs or impossible counts are inconsistent."""
    rec = {s: {"answer": [], "absence": [], "launched": [], "model": None} for s in roster}
    foreign = False
    for f in findings:
        if f["critic"] == GUARD:
            continue
        if f["critic"] in rec:
            rec[f["critic"]]["answer"].append("stdout:%d" % f.get("at", 0))
        else:
            foreign = True
    for slug, (reason, at) in parse_review(text)[1].items():
        if slug in rec:
            rec[slug]["absence"].append((reason, "stdout:%d" % at))
    for at, line in enumerate(stderr.splitlines(), 1):
        m = AVAIL.match(line)
        if not m or m.group(1) not in rec:
            continue
        r, rest, ref = rec[m.group(1)], m.group(2), "stderr:%d" % at
        ok = AVAIL_OK.match(rest)
        if ok:
            r["answer"].append(ref)
            r["model"] = ok.group(1) or ok.group(2) or r["model"]
        elif rest.startswith("unavailable"):
            reason = REASON.search(rest)
            r["absence"].append((reason.group(1) if reason else None, ref))
        else:
            r["launched"].append(ref)
    header, header_ref = None, []
    for at, line in enumerate(text.splitlines(), 1):
        h = HEADER.match(line)
        if h:
            header, header_ref = (int(h.group(1)), int(h.group(2))), ["stdout:%d" % at]
            break

    out, pending = {}, []
    for slug in roster:
        r = rec[slug]
        ev = r["answer"] + [ref for _, ref in r["absence"]] + r["launched"]
        kinds = {_absence(reason) for reason, _ in r["absence"]}
        if r["answer"] and r["absence"]:
            out[slug] = _part("unknown", "inconsistent", None, None, "an answer and an unavailable receipt", ev)
        elif len(kinds) > 1:
            out[slug] = _part("unknown", "inconsistent", None, None, "unavailable receipts that disagree", ev)
        elif r["absence"]:
            cat, eff, hdr = kinds.pop()
            if hdr is False and r["launched"]:
                hdr = True
            reasons = sorted({str(reason) for reason, _ in r["absence"]})
            out[slug] = _part("unavailable", cat, eff, hdr, ",".join(reasons), ev)
        elif r["answer"]:
            out[slug] = _part("answered", "answer", True, True, "a finding or an ok receipt", ev, r["model"])
        elif r["launched"]:
            out[slug] = _part("unavailable", "failure", True, True, "a fallback chain that never answered", ev)
        else:
            pending.append(slug)

    def unknown_all(why):
        for slug in roster:
            out[slug] = _part("unknown", "inconsistent", None, None, why, out.get(slug, {}).get("evidence", []))
    if foreign:
        unknown_all("finding slugs outside the roster")
        return out
    if not performed or header is None:
        for slug in pending:
            out[slug] = _part("unknown", "unknown", None, None, "the review did not complete", [])
        return out
    n, m = header
    counted = [s for s in roster if s not in pending and out[s]["header_included"] is True]
    answered = sum(1 for s in out if out[s]["state"] == "answered")
    absent = sum(1 for s in counted if out[s]["state"] == "unavailable")
    if n > m or answered > n or absent > m - n or len(counted) > m:
        unknown_all("header %d/%d cannot hold the receipts" % (n, m))
        return out
    phase_unknown = any(out[s]["header_included"] is None for s in out)
    if pending and not phase_unknown and m == len(counted) + len(pending) and n - answered == len(pending):
        for slug in pending:
            out[slug] = _part("answered", "answer", True, True, "header %d/%d reconciles" % (n, m), header_ref)
    else:
        for slug in pending:
            out[slug] = _part("unknown", "unknown", None, None, "no receipt and header %d/%d does not settle it"
                              % (n, m), [])
    return out


def _part(state, category, effective, header, reason, evidence, model=None):
    return {"state": state, "category": category, "effective": effective, "header_included": header,
            "reason": reason, "evidence": list(evidence), "responding_model": model if state == "answered" else None}


def loc_hit(f, d, window):
    return f["file"] == norm_path(d["file"]) and abs(f["line"] - d["line"]) <= d.get("window", window)


def class_hit(f, d):
    return re.search(CLASS_PATTERNS[d["class"]], f["text"], re.I) is not None


def ratio(k, n):
    return (k / n) if n else None


def score(outputs, fixtures, key_path, critics, only=None, window=DEFAULT_WINDOW):
    key = load_key(key_path)
    cases = key["cases"]
    ids = sorted(cases) if not only else [c for c in only if c in cases]
    if only and len(ids) != len(only):
        raise ValueError("--only names cases the key lacks: %s" % sorted(set(only) - set(cases)))
    leak_markers = (key["canary"],) + KEY_MARKERS

    roster = sorted(set(critics))
    per_case, leaks, unscored, case_evidence = {}, [], [], {}
    for cid in ids:
        md = os.path.join(outputs, cid + ".md")
        err = os.path.join(outputs, cid + ".err")
        text = open(md, encoding="utf-8", errors="replace").read() if os.path.isfile(md) else ""
        etext = open(err, encoding="utf-8", errors="replace").read() if os.path.isfile(err) else ""
        if any(m in text or m in etext for m in leak_markers):
            leaks.append(cid)
        findings, _, performed = parse_review(text)
        rc = os.path.join(outputs, cid + ".rc")
        if os.path.isfile(rc) and open(rc).read().strip() != "0":
            performed = False  # the panel exits 0 only when >= 1 critic responded
        part = case_participation(roster, text, etext, findings, performed)
        foreign = sorted({f["critic"] for f in findings} - set(roster) - {GUARD})
        case_evidence[cid] = {"performed": performed and not foreign, "non_rostered": foreign, "critics": part}
        if not performed or foreign:
            unscored.append(cid)
            continue
        per_case[cid] = (findings, part)
    members = roster + ["panel"]

    metrics, ci, case_rows = {}, {}, {}
    n_defects = sum(len(cases[c]["defects"]) for c in ids)
    member_metrics(members, per_case, cases, window, "", metrics, ci, case_rows)
    for half in ("open", "sealed"):
        part = {cid: v for cid, v in per_case.items() if cases[cid].get("split") == half}
        if part:
            member_metrics(members, part, cases, window, half + ".", metrics, ci, {})
    metrics.update({"defects": n_defects, "cases": len(ids), "unscored": len(unscored),
                    "leaked": len(leaks)})
    status = "inconclusive" if (leaks or len(unscored) == len(ids)) else ("partial" if unscored else "ok")
    responded = {"scored": len(per_case),
                 "critics": {who: sum(1 for cid in per_case if per_case[cid][1][who]["state"] == "answered")
                             for who in roster}}
    coverage = {"scored": len(per_case), "critics": {
        who: {cat: sum(1 for cid in per_case if per_case[cid][1][who]["category"] == cat) for cat in CATEGORIES}
        for who in roster}}
    reasons = provenance_reasons(outputs)
    if status != "ok":
        reasons.append("status-" + status)
    for cat, why in (("inconsistent", "participation-inconsistent"), ("unknown", "participation-unknown")):
        if any(c[cat] for c in coverage["critics"].values()):
            reasons.append(why)
    return {"status": status, "metrics": metrics, "ci": ci, "cases": case_rows, "responded": responded,
            "leaks": leaks, "unscored": unscored, "critics": roster, "window": window,
            "case_evidence": case_evidence, "coverage": coverage, "decision_eligible": not reasons,
            "ineligibility_reasons": reasons}


def member_metrics(members, per_case, cases, window, prefix, metrics, ci, case_rows):
    """Fill metrics and ci (names prefixed) and the panel's case_rows from the scored cases."""
    for who in members:
        hit = hit_loc = hit_gate = 0
        defects = true_f = all_f = clean_n = clean_fp = seeded_n = 0
        by_class = {c: [0, 0] for c in CLASSES}
        for cid, (findings, part) in sorted(per_case.items()):
            if who != "panel" and part[who]["state"] != "answered":
                continue
            blocks = findings if who == "panel" else [f for f in findings if f["critic"] == who]
            mine = [f for f in blocks if f["critic"] != GUARD]
            c = cases[cid]
            all_f += len(mine)
            true_f += sum(1 for f in mine if any(loc_hit(f, d, window) and class_hit(f, d) for d in c["defects"]))
            if c["kind"] == "clean":
                clean_n += 1
                fp = any(f["sev"] in GATING for f in blocks)
                clean_fp += fp
                if who == "panel":
                    case_rows[cid] = {"findings": len(mine), "fp": fp}
                continue
            seeded_n += 1
            got = 0
            for d in c["defects"]:
                defects += 1
                by_class[d["class"]][1] += 1
                lh = [f for f in mine if loc_hit(f, d, window)]
                ch = [f for f in lh if class_hit(f, d)]
                hit_loc += bool(lh)
                hit += bool(ch)
                hit_gate += any(f["sev"] in GATING for f in ch)
                by_class[d["class"]][0] += bool(ch)
                got += bool(ch)
            if who == "panel":
                case_rows[cid] = {"findings": len(mine), "hit": got, "defects": len(c["defects"])}
        vals = {
            "recall": (hit, defects), "recall_loc": (hit_loc, defects),
            "recall_gating": (hit_gate, defects), "precision": (true_f, all_f),
            "fp_rate": (clean_fp, clean_n),
        }
        vals.update({new: vals[old] for new, old in PROXY_ALIASES.items()})
        for name, (k, n) in vals.items():
            metrics["%s%s.%s" % (prefix, who, name)] = ratio(k, n)
            b = wilson(k, n)
            if b:
                ci["%s%s.%s" % (prefix, who, name)] = b
        metrics["%s%s.findings" % (prefix, who)] = all_f
        metrics["%s%s.seeded_scored" % (prefix, who)] = seeded_n
        metrics["%s%s.clean_scored" % (prefix, who)] = clean_n
        for cls, (k, n) in by_class.items():
            if n:
                metrics["%s%s.class.%s.recall" % (prefix, who, cls)] = ratio(k, n)
                metrics["%s%s.class.%s.n" % (prefix, who, cls)] = n


def _sha(b):
    return hashlib.sha256(b).hexdigest()


def fixture_digest(ids, blobs, key_bytes):
    """The fixture set's hash: each case's .patch, then every other per-case file (.intent.md), then the key.
    blobs maps a fixtures-dir file name to its bytes. A patch-only set hashes as it did before HIMMEL-8426."""
    h = hashlib.sha256()
    for cid in ids:
        h.update(cid.encode())
        h.update(_sha(blobs.get(cid + ".patch", b"")).encode())
        for name in sorted(n for n in blobs if n.startswith(cid + ".") and n != cid + ".patch"):
            h.update(name.encode())
            h.update(_sha(blobs[name]).encode())
    h.update(_sha(key_bytes).encode())
    return h.hexdigest()[:16]


def fixture_set_hash(fixtures, key_path, ids):
    blobs = {}
    for n in os.listdir(fixtures):
        if os.path.isfile(os.path.join(fixtures, n)):
            with open(os.path.join(fixtures, n), "rb") as fh:
                blobs[n] = fh.read()
    with open(key_path, "rb") as fh:
        return fixture_digest(ids, blobs, fh.read())


def eval_config(fixture_set, critics):
    """The config a sweep's ledger row and its gate row fingerprint."""
    return {"fixture_set": fixture_set, "critics": critics, "window": DEFAULT_WINDOW,
            "classes": CLASSES, "gating": list(GATING),
            "class_patterns": hashlib.sha256(json.dumps(CLASS_PATTERNS, sort_keys=True).encode()).hexdigest()[:16]}


# --- the merge gate: everything below reads a git tree, never the work tree ---------------

def toplevel(start=HERE):
    r = subprocess.run(["git", "-C", start, "rev-parse", "--show-toplevel"], capture_output=True, text=True)
    if r.returncode != 0:
        raise ValueError("%s is not inside a git checkout" % start)
    return r.stdout.strip()


def _git(repo, *args):
    r = subprocess.run(["git", "-C", repo] + list(args), capture_output=True)
    if r.returncode != 0:
        raise ValueError("git %s: %s" % (" ".join(args), r.stderr.decode(errors="replace").strip()))
    return r.stdout


def tree_files(repo, rev):
    return [p for p in _git(repo, "ls-tree", "-r", "-z", "--name-only", rev, "--").decode().split("\0") if p]


def tree_blob(repo, rev, path):
    """The bytes of <rev>:<path>, or None when the tree lacks it."""
    r = subprocess.run(["git", "-C", repo, "cat-file", "blob", "%s:%s" % (rev, path)], capture_output=True)
    return r.stdout if r.returncode == 0 else None


def cbs_paths(repo, rev):
    """The tracked files of <rev> that cbs.txt names: one `dir/` prefix or fnmatch glob per line, a glob
    matching within its own directory depth. A tree without cbs.txt has none (HIMMEL-8426 A29)."""
    raw = tree_blob(repo, rev, CBS_LIST)
    if raw is None:
        return []
    pats = [ln.strip() for ln in raw.decode().splitlines() if ln.strip() and not ln.strip().startswith("#")]
    return sorted(f for f in tree_files(repo, rev)
                  if any(f.startswith(p) if p.endswith("/")
                         else fnmatch.fnmatchcase(f, p) and f.count("/") == p.count("/") for p in pats))


def cbs_hash(repo, rev):
    h = hashlib.sha256()
    for p in cbs_paths(repo, rev):
        h.update(p.encode() + b"\0")
        h.update(_sha(tree_blob(repo, rev, p) or b"").encode())
    return h.hexdigest()


def tree_key(repo, rev):
    raw = tree_blob(repo, rev, KEY_REL)
    if raw is None:
        raise ValueError("%s has no %s" % (rev, KEY_REL))
    return raw


def tree_roster(repo, rev):
    raw = tree_blob(repo, rev, CRITICS_REL)
    panel = json.loads(raw).get("panel", []) if raw else []
    return sorted(r["slug"] for r in panel if isinstance(r, dict) and r.get("tier") == ROSTER_TIER and r.get("slug"))


def run_roster_rows(outputs, tiers=None):
    """The panel rows of <outputs>/critics.run.json in the tiers the sweep ran (the manifest's, else the gate's
    roster tier), or None when the file is missing, malformed or holds no such row."""
    try:
        with open(os.path.join(outputs, "critics.run.json"), encoding="utf-8") as fh:
            panel = json.load(fh).get("panel", [])
    except (OSError, ValueError, AttributeError):
        return None
    if tiers is None:
        try:
            tiers = ((read_manifest(outputs) or {}).get("protocol") or {}).get("tiers")
        except ValueError:
            tiers = None
    tiers = set(str(tiers or ROSTER_TIER).split(","))
    rows = [r for r in panel if isinstance(r, dict) and r.get("slug") and r.get("tier") in tiers] \
        if isinstance(panel, list) else []
    return rows or None


def sweep_roster(outputs, fallback):
    """The critics the sweep ran: the slugs of <outputs>/critics.run.json in the swept tiers, else `fallback`,
    which is a reconstructed roster, never recorded provenance. Only the responded block reads it: the config hash
    keeps the tree's paid roster, so a codex-only sweep still grades at the gate's hash."""
    rows = run_roster_rows(outputs)
    if rows is None:
        print("score.py: %s has no usable critics.run.json: the roster %s is reconstructed from the tree, not "
              "recorded" % (outputs, ",".join(fallback)), file=sys.stderr)
        return fallback
    return sorted(r["slug"] for r in rows)


def read_manifest(outputs):
    """<outputs>/run-manifest.json as a dict, None when absent; ValueError when it is not a manifest."""
    path = os.path.join(outputs, MANIFEST)
    if not os.path.isfile(path):
        return None
    try:
        with open(path, encoding="utf-8") as fh:
            m = json.load(fh)
    except (OSError, ValueError):
        raise ValueError("%s is unreadable" % path)
    if not isinstance(m, dict) or m.get("v") != 1:
        raise ValueError("%s is not a v1 run manifest" % path)
    for k, kind in (("protocol", dict), ("provenance", dict), ("cases", dict), ("inputs", dict), ("critics", list)):
        if not isinstance(m.get(k), kind):
            raise ValueError("%s has a missing or malformed %s" % (path, k))
    if not all(isinstance(c, dict) for c in m.get("critics", [])):
        raise ValueError("%s has a malformed critics entry" % path)
    return m


def provenance_reasons(outputs):
    """Why the execution behind <outputs> is not decision-grade: an empty list when its manifest is a recorded,
    finished execution of a clean, rechecked sweep through the tree's own panel, with a recorded roster and no
    anomaly in the case files as they are now."""
    try:
        m = read_manifest(outputs)
    except ValueError:
        return ["run-manifest-unreadable"]
    if m is None:
        return ["no-run-manifest"]
    reasons = []
    try:
        with open(os.path.join(outputs, STAMP), encoding="utf-8") as fh:
            swept = json.load(fh)
    except (OSError, ValueError):
        swept = None
    if not isinstance(swept, dict) or swept.get("clean") is not True or swept.get("rechecked") is not True \
            or m["protocol"].get("panel") != "tree":
        reasons.append("sweep-unclean")
    if (m.get("provenance") or {}).get("status") != "recorded":
        reasons.append("provenance-reconstructed")
    if not m.get("finished_at"):
        reasons.append("execution-incomplete")
    if not m.get("effective_roster") or run_roster_rows(outputs) is None:
        reasons.append("roster-reconstructed")
    if any(case_anomalies(outputs, cid) for cid in m.get("inputs", {})):
        reasons.append("execution-anomaly")
    return reasons


def case_anomalies(outputs, cid):
    """stderr:<line> references of error lines in a case whose panel exited 0 (or left no rc)."""
    rc = _read(os.path.join(outputs, cid + ".rc")).strip()
    if rc not in ("0", ""):
        return []
    return ["stderr:%d" % n for n, ln in enumerate(_read(os.path.join(outputs, cid + ".err")).splitlines(), 1)
            if ANOMALY.search(ln)]


def _file_sha(path):
    if not os.path.isfile(path):
        return None
    with open(path, "rb") as fh:
        return _sha(fh.read())


def execution_manifest(outputs, repo, fixtures, key, roster, protocol):
    """The v1 run manifest of a sweep about to start: the code under test, corpus, requested and effective roster,
    per-critic configuration, protocol and per-case input digests. roster is the requested slug list; the effective
    rows are critics.run.json's. finished_at, the per-case receipts and anomalies are filled by complete_manifest."""
    rows = run_roster_rows(outputs, protocol.get("tiers"))
    with open(key, encoding="utf-8") as fh:
        cases = json.load(fh)["cases"]
    only = [c for c in str(protocol.get("only") or "").split(",") if c]
    ids = sorted(c for c in cases if not only or c in only)
    inputs, delta = {}, False
    for cid in ids:
        dpath = os.path.join(fixtures, cid + DELTA_SUFFIX)
        is_delta = cases[cid].get("delta") is True and os.path.isfile(dpath)
        delta = delta or is_delta
        inputs[cid] = {"diff_sha256": _file_sha(dpath if is_delta else os.path.join(fixtures, cid + ".patch")),
                       "context_sha256": (_sha(open(os.path.join(fixtures, cid + ".patch"), "rb").read()
                                               + open(dpath, "rb").read()) if is_delta else None),
                       "intent_sha256": _file_sha(os.path.join(fixtures, cid + ".intent.md")),
                       "base": cases[cid].get("base")}
    h = hashlib.sha256()
    for cid in ids:
        h.update(cid.encode() + b"\0" + json.dumps(inputs[cid], sort_keys=True).encode() + b"\0")
    h.update(_sha(open(key, "rb").read()).encode())
    runner = tree_blob(repo, "HEAD", REL + "/run.sh")
    critics = [{"slug": r["slug"], "provider": r.get("provider"), "requested_model": r.get("model"),
                "resolved_model": r.get("model"), "requested_effort": r.get("effort"),
                "resolved_effort": r.get("effort"), "responding_models": [], "cli_version": None}
               for r in (rows or [])]
    return {"v": 1, "execution_id": uuid.uuid4().hex, "started_at": _now(), "finished_at": None,
            "code_under_test_sha": _git(repo, "rev-parse", "HEAD").decode().strip(),
            "cbs_hash": cbs_hash(repo, "HEAD"), "corpus_sha256": h.hexdigest(),
            "requested_roster": sorted(roster) if roster else None,
            "effective_roster": sorted(c["slug"] for c in critics) or None, "critics": critics,
            "protocol": dict(protocol, context_mode="delta" if delta else "none", known_findings="0",
                             triviality="full", runner_sha256=_sha(runner) if runner is not None else None,
                             overrides={k: os.environ[k] for k in RECORDED_OVERRIDES if k in os.environ}),
            "inputs": inputs, "cases": {}, "provenance": {
                "status": "recorded", "evidence": ["score.py stamp"],
                "unknown": [] if rows else ["effective_roster"]}}


def complete_manifest(outputs, manifest):
    """manifest with finished_at, each case's responding-model receipts and anomalies, and each critic's observed
    responding models, read from the sweep's outputs."""
    roster = manifest.get("effective_roster") or []
    seen = {c["slug"]: set(c.get("responding_models") or []) for c in manifest.get("critics", [])}
    cases = {}
    for cid in sorted(manifest.get("inputs") or {}):
        text = _read(os.path.join(outputs, cid + ".md"))
        err = _read(os.path.join(outputs, cid + ".err"))
        findings, _, performed = parse_review(text)
        part = case_participation(roster, text, err, findings, performed)
        models = {s: p["responding_model"] for s, p in part.items() if p["responding_model"]}
        for s, mdl in models.items():
            seen.setdefault(s, set()).add(mdl)
        rc = _read(os.path.join(outputs, cid + ".rc")).strip()
        cases[cid] = {"responding_models": models, "anomalies": case_anomalies(outputs, cid), "rc": rc or None}
    for c in manifest.get("critics", []):
        c["responding_models"] = sorted(seen.get(c["slug"], ()))
    return dict(manifest, finished_at=_now(), cases=cases)


def _read(path):
    return open(path, encoding="utf-8", errors="replace").read() if os.path.isfile(path) else ""


def _now():
    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def bundle_sha256_v2(outputs):
    """64-hex over the case md/err/rc files plus critics.run.json and run-manifest.json, names and content hashes;
    outputs_sha256 stays the legacy raw-output identity."""
    h = hashlib.sha256()
    for n in sorted(os.listdir(outputs)):
        if re.match(r"^(case|real|delta)-.+\.(md|err|rc)$", n) or n in ("critics.run.json", MANIFEST):
            h.update(n.encode() + b"\0")
            h.update(_file_sha(os.path.join(outputs, n)).encode())
    return h.hexdigest()


def model_conflict(outputs, model, tiers=None):
    """None when `model` is a model the sweep's effective roster ran, else why it cannot label the run."""
    rows = run_roster_rows(outputs, tiers)
    if rows is None:
        return "--model %s cannot be checked: %s records no roster" % (model, outputs)
    models = sorted({r.get("model") for r in rows if r.get("model")})
    if model not in models:
        return "--model %s is not a model the swept roster runs (%s)" % (model, ", ".join(models) or "none")
    return None


def confighash(repo, rev):
    """eval_runs.config_hash of <rev>'s fixture set and key, its paid roster, the default window and the
    classes; no model (A34). The same function grades export-row and gate."""
    key_bytes = tree_key(repo, rev)
    pre = FIXTURES_REL + "/"
    blobs = {f[len(pre):]: tree_blob(repo, rev, f) for f in tree_files(repo, rev)
             if f.startswith(pre) and "/" not in f[len(pre):]}
    ids = sorted(json.loads(key_bytes)["cases"])
    return eval_runs.config_hash(eval_config(fixture_digest(ids, blobs, key_bytes), tree_roster(repo, rev)))


def outputs_sha256(outputs):
    h = hashlib.sha256()
    for n in sorted(os.listdir(outputs)):
        if re.match(r"^(case|real|delta)-.+\.(md|err|rc)$", n):
            with open(os.path.join(outputs, n), "rb") as fh:
                h.update(n.encode() + b"\0")
                h.update(_sha(fh.read()).encode())
    return h.hexdigest()


SCORER_FILES = (REL + "/score.py", "scripts/eval/lib/wilson.py")


def scorer_digest(repo, rev):
    """64-hex over the scorer files' blobs at <rev> of repo: a pure tree helper."""
    h = hashlib.sha256()
    for p in SCORER_FILES:
        b = tree_blob(repo, rev, p)
        if b is None:
            raise ValueError("%s has no %s" % (rev, p))
        h.update(p.encode() + b"\0")
        h.update(_sha(b).encode())
    return h.hexdigest()


def running_scorer_identity():
    """{scorer_repo, scorer_gitsha, scorer_sha256, scorer_clean, reason} of the code scoring now: this script's own
    checkout and HEAD, with the score.py and wilson.py actually loaded checked byte for byte against that HEAD.
    A missing checkout, or a loaded file that is edited, untracked or loaded from elsewhere, gives scorer_sha256
    None and says why: such a result is diagnostic only."""
    out = {"scorer_repo": None, "scorer_gitsha": None, "scorer_sha256": None, "scorer_clean": False, "reason": ""}
    try:
        repo = toplevel(HERE)
        head = _git(repo, "rev-parse", "HEAD").decode().strip()
    except ValueError as e:
        out["reason"] = "the running scorer has no git checkout and HEAD: %s" % e
        return out
    out.update(scorer_repo=repo, scorer_gitsha=head)
    loaded = {REL + "/score.py": os.path.abspath(__file__),
              "scripts/eval/lib/wilson.py": os.path.abspath(sys.modules[wilson.__module__].__file__)}
    problems = []
    for rel in SCORER_FILES:
        path = loaded[rel]
        if os.path.realpath(path) != os.path.realpath(os.path.join(repo, rel)):
            problems.append("%s is loaded from outside the scorer checkout" % rel)
            continue
        blob = tree_blob(repo, head, rel)
        if blob is None:
            problems.append("%s is not committed at HEAD" % rel)
            continue
        with open(path, "rb") as fh:
            if fh.read() != blob:
                problems.append("%s differs from HEAD" % rel)
    if problems:
        out["reason"] = "; ".join(problems)
        return out
    out.update(scorer_sha256=scorer_digest(repo, head), scorer_clean=True)
    return out


def known_identity(ident):
    sha = ident.get("scorer_sha256")
    return ident.get("scorer_clean") is True and isinstance(sha, str) and HEX64.match(sha) is not None


def settled_identity(before):
    after = running_scorer_identity()
    if after != before:
        return dict(after, scorer_sha256=None, scorer_clean=False,
                    reason="the scorer or its HEAD changed while scoring")
    return before


STAMP = "swept.json"


def stamp(repo, outputs, fixtures, key, panel=None, tiers=ROSTER_TIER, only="", recheck=False, critics=None,
          model=None):
    """Write <outputs>/swept.json: the hashes of the tree run.sh sweeps (HEAD). `clean` is false when the
    working tree differs from HEAD on any gate input (a CBS path, critics.json, or any file of this eval but
    results.jsonl, which export-row writes between sweeps), or the sweep reads other fixtures or another key, runs
    another panel command than the tree's critic-panel.sh, another tier set than the gate's roster, or a
    subset of the cases. recheck (run.sh, after the panel loop) keeps `clean` only when the earlier stamp was
    clean and HEAD and both hashes are unchanged, so a tree edited during the sweep is caught. `rechecked` is
    true only after the recheck, so a sweep interrupted mid-loop (its outputs possibly mixed with an earlier
    sweep's) is refused. The start stamp also writes <outputs>/run-manifest.json (execution_manifest) and refuses
    a --model the effective roster does not run; the recheck completes that manifest."""
    if not recheck and model:
        why = model_conflict(outputs, model, tiers)
        if why:
            raise ValueError(why)
    inputs = cbs_paths(repo, "HEAD") + [REL, CRITICS_REL, ":(exclude)" + RESULTS]
    dirty = _git(repo, "status", "--porcelain", "--", *inputs).strip()
    def same(path, rel):
        return os.path.realpath(path) == os.path.realpath(os.path.join(repo, rel))
    own = (same(fixtures, FIXTURES_REL) and same(key, KEY_REL) and tiers == ROSTER_TIER and not only
           and (panel is None or same(panel, PANEL_REL)))
    rec = {"tree": _git(repo, "rev-parse", "HEAD").decode().strip(), "cbs_hash": cbs_hash(repo, "HEAD"),
           "confighash": confighash(repo, "HEAD"), "clean": not dirty and own, "rechecked": recheck}
    if recheck:
        try:
            with open(os.path.join(outputs, STAMP), encoding="utf-8") as fh:
                prev = json.load(fh)
        except (OSError, ValueError):
            prev = {}
        rec["clean"] = (rec["clean"] and isinstance(prev, dict) and prev.get("clean") is True
                        and all(prev.get(f) == rec[f] for f in ("tree", "cbs_hash", "confighash")))
    os.makedirs(outputs, exist_ok=True)
    with open(os.path.join(outputs, STAMP), "w", encoding="utf-8") as fh:
        json.dump(rec, fh, sort_keys=True)
    if recheck:
        manifest = read_manifest(outputs)
        if manifest is not None and not manifest.get("finished_at"):
            manifest = complete_manifest(outputs, manifest)
    else:
        manifest = execution_manifest(outputs, repo, fixtures, key, [c for c in (critics or "").split(",") if c],
                                      {"tiers": tiers, "only": only or None, "model_label": model or None,
                                       "panel": "tree" if panel is None or same(panel, PANEL_REL) else "other"})
    if manifest is not None:
        with open(os.path.join(outputs, MANIFEST), "w", encoding="utf-8") as fh:
            json.dump(manifest, fh, sort_keys=True, indent=1)
    return rec


def check_stamp(repo, rev, outputs):
    """Refuse outputs run.sh did not sweep from a clean <rev>-equivalent tree."""
    try:
        with open(os.path.join(outputs, STAMP), encoding="utf-8") as fh:
            rec = json.load(fh)
    except (OSError, ValueError):
        raise ValueError("%s has no readable %s: not a run.sh sweep" % (outputs, STAMP))
    if not isinstance(rec, dict) or rec.get("clean") is not True:
        raise ValueError("%s was swept from a working tree that differs from its HEAD, or other fixtures, panel or tiers, or a subset" % outputs)
    for f, want in (("cbs_hash", cbs_hash(repo, rev)), ("confighash", confighash(repo, rev))):
        if rec.get(f) != want:
            raise ValueError("%s was swept at %s %s, %s is at %s" % (outputs, f, str(rec.get(f))[:12], rev, want[:12]))
    # A stamp without the key predates the recheck (the first baseline sweeps); only an explicit false refuses.
    if rec.get("rechecked") is False:
        raise ValueError("%s was never re-stamped after its panel loop: an interrupted sweep" % outputs)


def gate_row(repo, rev, outputs):
    """The results.jsonl row of one sweep's outputs, scored against <rev>'s key and roster."""
    if not os.path.isdir(outputs):
        raise ValueError("no outputs dir: %s" % outputs)
    check_stamp(repo, rev, outputs)
    before = running_scorer_identity()
    with tempfile.NamedTemporaryFile(suffix=".json") as kf:
        kf.write(tree_key(repo, rev))
        kf.flush()
        res = score(outputs, None, kf.name, sweep_roster(outputs, tree_roster(repo, rev)))
    m = res["metrics"]
    keep = ("cases", "defects", "unscored", "leaked")
    ident = settled_identity(before)
    prov = execution_fields(outputs)
    reasons = res["ineligibility_reasons"] + ([] if known_identity(ident) else ["scorer-identity-unverified"])
    return dict({"run_id": os.path.basename(os.path.abspath(outputs)), "tree": _git(repo, "rev-parse", rev).decode().strip(),
                 "cbs_hash": cbs_hash(repo, rev), "confighash": confighash(repo, rev), "status": res["status"],
                 "metrics": {k: v for k, v in m.items() if k in keep or (k.startswith("panel.") and ".class." not in k)},
                 "class_recall": {c: m["panel.class.%s.recall" % c] for c in CLASSES if "panel.class.%s.recall" % c in m},
                 "responded": res["responded"], "outputs_sha256": outputs_sha256(outputs),
                 "scorer_sha256": ident["scorer_sha256"] if known_identity(ident) else None,
                 "scorer_gitsha": ident["scorer_gitsha"], "scorer_reason": ident["reason"] or None,
                 "scored_at": _now(), "decision_eligible": not reasons, "ineligibility_reasons": reasons}, **prov)


def execution_fields(outputs):
    """The execution identity a score row carries: execution_id, code_under_test_sha (the swept tree, never the
    scoring tree), provenance_status (recorded | reconstructed | missing | unreadable) and bundle_sha256_v2."""
    try:
        m = read_manifest(outputs)
        status = "missing" if m is None else (m.get("provenance") or {}).get("status") or "unknown"
    except ValueError:
        m, status = None, "unreadable"
    code = (m or {}).get("code_under_test_sha")
    if code is None:
        try:
            with open(os.path.join(outputs, STAMP), encoding="utf-8") as fh:
                code = json.load(fh).get("tree")
        except (OSError, ValueError, AttributeError):
            code = None
    return {"execution_id": (m or {}).get("execution_id"), "code_under_test_sha": code,
            "provenance_status": status, "bundle_sha256_v2": bundle_sha256_v2(outputs)}


def panel_mismatch(rows, base_hash, head_hash, confighash):
    """A reason string when the counted rows did not run the same critics, else "" (HIMMEL-8979). A row's
    `responded` is {scored: cases scored, critics: {critic: cases it answered}}; its roster gives each critic one
    of three states: answered every scored case, answered some, answered none. Counted rows at either hash with
    more than one roster make a win-or-loss comparison unequal (the panel drops an unavailable critic per case),
    and so do rows that record a roster beside rows that do not: no verdict, and the rows are named. Like
    gate_verdict it keeps the first row of a run_id.
    ponytail: two partial critics count as alike whatever their case counts, upgrade = compare per-case
    participation once a row records which cases each critic answered.
    ponytail: when every counted row has no `responded` the normal verdict stands. That is the state of the
    HIMMEL-8430 rows today, so the unequal-panel false alarm on that pair stays until the old rows are replaced in
    results.jsonl by rows with a roster (export-row appends, and the first row of a run_id wins, so a re-exported
    row is dropped), upgrade = replace the old baseline and head rows.
    ponytail: side() hand-copies gate_verdict's row selection (eval_feedback.py), upgrade = one shared helper there
    that both call."""
    def side(h, skip_ids=(), skip_bundles=()):
        # the rows gate_verdict counts for hash h: same status and metric tests, first row of a run_id or bundle
        out, ids, bundles = {}, set(skip_ids), set(skip_bundles)
        for r in rows:
            m = r.get("metrics")
            if r.get("cbs_hash") != h or r.get("confighash") != confighash \
                    or r.get("status") not in eval_feedback.GATE_STATUS or not isinstance(m, dict) \
                    or not (eval_runs._num(m.get(eval_feedback.GATE_RECALL))
                            and eval_runs._num(m.get(eval_feedback.GATE_FP))) \
                    or r.get("run_id") in ids or r.get("outputs_sha256") in bundles:
                continue
            ids.add(r.get("run_id"))
            bundles.add(r.get("outputs_sha256"))
            resp = r.get("responded")
            out[r.get("run_id")] = resp if isinstance(resp, dict) and isinstance(resp.get("critics"), dict) else None
        return out, ids, bundles
    base, base_ids, base_bundles = side(base_hash)
    sides = {"baseline": base,
             "head": (side(head_hash) if head_hash == base_hash else side(head_hash, base_ids, base_bundles))[0]}

    def state(resp, n):
        return "all" if n == resp.get("scored") else ("none" if not n else "some")

    def roster(resp):
        return tuple(sorted((c, state(resp, n)) for c, n in resp["critics"].items()))

    def say(side, keep):
        out = []
        for rid, resp in sorted(sides.get(side, {}).items()):
            if keep(resp):
                out.append(rid if resp is None else "%s [%s]" % (rid, ", ".join(
                    "%s %s/%s" % (c, n, resp.get("scored")) for c, n in sorted(resp["critics"].items()))))
        return "; ".join(out) or "none"
    counted = [resp for runs in sides.values() for resp in runs.values()]
    if any(resp is None for resp in counted) and any(resp is not None for resp in counted):
        return ("panel mismatch: some counted rows record which critics answered and others do not, no win or "
                "loss read. without a roster: baseline %s | head %s. with a roster: baseline %s | head %s"
                % (say("baseline", lambda r: r is None), say("head", lambda r: r is None),
                   say("baseline", lambda r: r is not None), say("head", lambda r: r is not None)))
    if len({roster(resp) for resp in counted if resp is not None}) < 2:
        return ""
    return ("panel mismatch: the rows ran different critics, no win or loss read: baseline %s | head %s"
            % (say("baseline", lambda r: True), say("head", lambda r: True)))


def gate(repo, base, head, target_classes=()):
    # ponytail: the scorer filter lives here, not in one shared selector, upgrade = M3's eligibility selector in
    # eval_feedback.py that compare, gate and report all call.
    b, h, c = cbs_hash(repo, base), cbs_hash(repo, head), confighash(repo, head)
    where = {"baseline_cbs_hash": b, "head_cbs_hash": h, "confighash": c}
    ident = running_scorer_identity()
    if not known_identity(ident):
        return "unmeasured", dict(where, scorer_sha256=None, reason="the running scorer has no clean identity (%s): "
                                  "no eval row can be matched to it" % (ident["reason"] or "no valid digest"))
    want = ident["scorer_sha256"]
    raw = tree_blob(repo, head, RESULTS) or b""
    rows = []
    for ln in raw.decode(errors="replace").splitlines():
        try:
            r = json.loads(ln)
        except ValueError:
            continue
        if isinstance(r, dict):
            rows.append(r)
    mine = [r for r in rows if r.get("scorer_sha256") == want]
    legacy = sum(1 for r in rows if not r.get("scorer_sha256"))
    excluded = {"without_scorer_sha256": legacy, "other_scorer": len(rows) - len(mine) - legacy}
    where.update(scorer_sha256=want, scorer_excluded=excluded)
    said = "%d without scorer_sha256, %d of another scorer" % (legacy, excluded["other_scorer"])
    if not mine:
        return "unmeasured", dict(where, reason="no eval rows scored by the running scorer %s (excluded: %s)"
                                  % (want[:12], said))
    mismatch = panel_mismatch(mine, b, h, c)
    if mismatch:
        return "mismatch", dict(where, reason=mismatch)
    verdict, info = eval_feedback.gate_verdict(mine, b, h, c, target_classes)
    if verdict == "unmeasured" and len(mine) < len(rows):
        info = dict(info, reason="%s (rows of other scorers excluded: %s)" % (info["reason"], said))
    return verdict, dict(info, **where)


def report(res):
    m = res["metrics"]
    out = ["review-panel: %d cases, %d defects, unscored=%d, leaked=%d, status=%s"
           % (m["cases"], m["defects"], m["unscored"], m["leaked"], res["status"])]
    for cid in res["leaks"]:
        out.append("LEAK %s: its transcript carries a key marker - the critic saw the answer" % cid)

    def fmt(x):
        return "  -  " if x is None else "%.2f" % x
    out.append("automated proxies, not verified accuracy: key-match = a finding at a labelled defect's place whose "
               "words match its class; location-match = the place only; labelled-clean blocking = a Critical or "
               "Important finding on a labelled-clean twin")
    out.append("%-12s %-9s %-9s %-9s %-9s %-9s %s" % ("critic", "key-match", "location", "key-gate", "key-prec",
                                                      "clean-blk", "n"))
    for who in res["critics"] + ["panel"]:
        out.append("%-12s %-9s %-9s %-9s %-9s %-9s n=%d labelled-defect cases, %d labelled-clean, %d findings" % (
            who, fmt(m.get(who + ".key_match_recall")), fmt(m.get(who + ".location_match_recall")),
            fmt(m.get(who + ".key_match_recall_gating")), fmt(m.get(who + ".key_match_precision")),
            fmt(m.get(who + ".labelled_clean_block_rate")), m.get(who + ".seeded_scored", 0),
            m.get(who + ".clean_scored", 0), m.get(who + ".findings", 0)))
    for who, cats in sorted(res.get("coverage", {}).get("critics", {}).items()):
        out.append("%-12s participation over %d scored cases: %s" % (
            who, res["coverage"]["scored"], ", ".join("%s %d" % (c, cats[c]) for c in CATEGORIES)))
    for who in res["critics"] + ["panel"]:
        parts = ["%s %s (n=%d)" % (c, fmt(m.get("%s.class.%s.recall" % (who, c))), m.get("%s.class.%s.n" % (who, c), 0))
                 for c in CLASSES if ("%s.class.%s.n" % (who, c)) in m]
        if parts:
            out.append("%-12s by class: %s" % (who, "; ".join(parts)))
    return "\n".join(out)


def main(argv=None):
    ap = argparse.ArgumentParser(prog="score.py")
    sub = ap.add_subparsers(dest="cmd", required=True)
    pl = sub.add_parser("lint")
    ps = sub.add_parser("score")
    for p in (pl, ps):
        p.add_argument("--fixtures", default=os.path.join(HERE, "fixtures"))
        p.add_argument("--key", default=os.path.join(HERE, "key", "seeds.json"))
    pl.add_argument("--min-real", type=int, default=0)
    pl.add_argument("--src", help="the repo real cases' base and fix commits live in (default this checkout)")
    tree_cmds = {}
    for name in ("cbs-paths", "cbs-hash", "confighash"):
        tree_cmds[name] = sub.add_parser(name)
        tree_cmds[name].add_argument("rev")
    pst = sub.add_parser("stamp")
    pst.add_argument("outputs")
    pst.add_argument("--fixtures", default=os.path.join(HERE, "fixtures"))
    pst.add_argument("--key", default=os.path.join(HERE, "key", "seeds.json"))
    pst.add_argument("--panel", default=None)
    pst.add_argument("--tiers", default=ROSTER_TIER)
    pst.add_argument("--only", default="")
    pst.add_argument("--recheck", action="store_true")
    pst.add_argument("--critics", default="", help="the requested roster, recorded in the run manifest")
    pst.add_argument("--model", default=None, help="the critic model label; refused unless the roster runs it")
    pe = sub.add_parser("export-row")
    pe.add_argument("outputs")
    pe.add_argument("--results", default=os.path.join(HERE, "results.jsonl"))
    pv = sub.add_parser("verify-row")
    pv.add_argument("row")
    pv.add_argument("outputs")
    pv.add_argument("--tree", default="HEAD")
    pg = sub.add_parser("gate")
    pg.add_argument("base")
    pg.add_argument("head")
    pg.add_argument("--target-class", action="append", default=[], choices=CLASSES)
    for p in list(tree_cmds.values()) + [pst, pe, pv, pg]:
        p.add_argument("--repo", help="the git repo the revs name (default this checkout)")
    pid = sub.add_parser("scorer-identity")
    pid.add_argument("--json", action="store_true")
    ps.add_argument("--outputs", required=True)
    ps.add_argument("--critics", default="")
    ps.add_argument("--only", default="")
    ps.add_argument("--window", type=int, default=DEFAULT_WINDOW)
    ps.add_argument("--json")
    ps.add_argument("--ledger")
    ps.add_argument("--no-ledger", action="store_true")
    ps.add_argument("--meta-json", default="{}")
    ps.add_argument("--model", help="the critic model, recorded on the row and in its config")
    a = ap.parse_args(argv)

    if a.cmd == "lint":
        try:
            problems, n_seeded, n_clean = lint(a.fixtures, a.key, a.min_real, a.src)
        except ValueError as e:
            print("score.py: %s" % e, file=sys.stderr)
            return 2
        for p in problems:
            print("lint: %s" % p, file=sys.stderr)
        print("review-panel lint: %d seeded, %d clean, %d problem(s)" % (n_seeded, n_clean, len(problems)))
        return 1 if problems else 0
    if a.cmd == "scorer-identity":
        ident = running_scorer_identity()
        if a.json:
            print(json.dumps(ident, sort_keys=True))
        else:
            print(ident["scorer_sha256"] or "null (%s)" % ident["reason"])
        return 0
    if a.cmd in tree_cmds or a.cmd in ("stamp", "export-row", "verify-row", "gate"):
        try:
            return tree_main(a)
        except (OSError, ValueError, KeyError) as e:
            print("score.py %s: %s" % (a.cmd, e), file=sys.stderr)
            return 2

    try:
        meta = json.loads(a.meta_json)
        if not isinstance(meta, dict):
            raise ValueError("--meta-json must be an object")
        critics = [c for c in a.critics.split(",") if c]
        # The panel header carries counts, not names: without the roster a
        # responding critic with zero findings would drop out of the metrics.
        if not critics:
            raise ValueError("--critics is required (the panel roster)")
        only = [c for c in a.only.split(",") if c]
        if a.model and model_conflict(a.outputs, a.model):
            raise ValueError(model_conflict(a.outputs, a.model))
        before = running_scorer_identity()
        res = score(a.outputs, a.fixtures, a.key, critics, only or None, a.window)
        ident = settled_identity(before)
    except (OSError, ValueError) as e:
        print("score.py: %s" % e, file=sys.stderr)
        return 2
    scorer = {"scorer_sha256": ident["scorer_sha256"] if known_identity(ident) else None,
              "scorer_gitsha": ident["scorer_gitsha"], "scorer_reason": ident["reason"] or None}
    res.update(scorer)
    print(report(res))
    if a.json:
        with open(a.json, "w", encoding="utf-8") as fh:
            json.dump(res, fh, indent=2, sort_keys=True)
    if not a.no_ledger:
        ids = only or sorted(load_key(a.key)["cases"])
        config = dict(eval_config(fixture_set_hash(a.fixtures, a.key, ids), res["critics"]), window=a.window)
        if a.model:
            config["critic_model"] = a.model
        reasons = res["ineligibility_reasons"] + ([] if scorer["scorer_sha256"] else ["scorer-identity-unverified"])
        # cli_version and effort default to the scoring session's own; the critic's are in the run manifest.
        meta = dict(meta, leaks=res["leaks"], unscored=res["unscored"], coverage=res["coverage"],
                    decision_eligible=not reasons, ineligibility_reasons=reasons, cli_version=None, effort=None,
                    **dict(scorer, **execution_fields(a.outputs)))
        row = eval_runs.make_row(EVAL_ID, SOURCE, config, res["metrics"], n=res["metrics"]["cases"], model=a.model,
                                 status=res["status"], ci=res["ci"], ci_level=0.95 if res["ci"] else None,
                                 ci_method="wilson" if res["ci"] else None, cases=res["cases"] or None,
                                 artifact=os.path.abspath(a.outputs), meta=meta, repo=HERE)
        eval_runs.append_safe(row, a.ledger, who="review-panel")
    return 0


ROW_FIELDS = ("status", "metrics", "class_recall", "cbs_hash", "confighash", "outputs_sha256", "responded",
              "scorer_sha256", "bundle_sha256_v2", "execution_id", "code_under_test_sha", "provenance_status",
              "decision_eligible", "ineligibility_reasons")
# Fields a row written before them may lack; such a row is not held to them.
LATER_FIELDS = ("responded", "bundle_sha256_v2", "execution_id", "code_under_test_sha", "provenance_status",
                "decision_eligible", "ineligibility_reasons")


def tree_main(a):
    repo = a.repo or toplevel()
    if a.cmd == "cbs-paths":
        print("\n".join(cbs_paths(repo, a.rev)))
    elif a.cmd == "cbs-hash":
        print(cbs_hash(repo, a.rev))
    elif a.cmd == "confighash":
        print(confighash(repo, a.rev))
    elif a.cmd == "stamp":
        rec = stamp(repo, a.outputs, a.fixtures, a.key, a.panel, a.tiers, a.only, a.recheck, a.critics, a.model)
        if not rec["clean"]:
            print("score.py stamp: the working tree differs from HEAD on a gate input, or the sweep reads other "
                  "fixtures, panel or tiers, or a subset: export-row will refuse this sweep", file=sys.stderr)
    elif a.cmd == "export-row":
        row = gate_row(repo, "HEAD", a.outputs)
        if row["status"] == "inconclusive":
            raise ValueError("%s is inconclusive (a leak, or no case scored): no row" % a.outputs)
        with open(a.results, "a", encoding="utf-8") as fh:
            fh.write(json.dumps(row, sort_keys=True) + "\n")
        print("export-row: %s cbs_hash=%s confighash=%s recall_gating=%s fp_rate=%s scorer=%s -> %s"
              % (row["run_id"], row["cbs_hash"][:12], row["confighash"], row["metrics"].get("panel.recall_gating"),
                 row["metrics"].get("panel.fp_rate"), (row["scorer_sha256"] or "null")[:12], a.results))
        if row["scorer_sha256"] is None:
            print("export-row: diagnostic only, the gate never counts this row: %s" % row["scorer_reason"],
                  file=sys.stderr)
    elif a.cmd == "verify-row":
        claimed = json.loads(a.row)
        got = gate_row(repo, a.tree, a.outputs)
        # A row without a `responded` key is not held to one: verify-row cannot tell a row exported before rosters
        # were recorded from one that dropped the key, and CI never runs verify-row. The gate names such a row only when
        # another counted row records a roster; when every counted row lacks one the normal verdict stands.
        legacy = not claimed.get("scorer_sha256")
        if legacy:
            got = dict(got, metrics={k: v for k, v in got["metrics"].items() if k in (claimed.get("metrics") or {})})
            print("verify-row: scorer identity unverified: the row names no scorer_sha256")
        bad = [f for f in ROW_FIELDS if claimed.get(f) != got[f] and (f not in LATER_FIELDS or f in claimed)
               and not (legacy and f == "scorer_sha256")]
        for f in bad:
            print("verify-row: %s differs: row %s, re-scored %s" % (f, json.dumps(claimed.get(f), sort_keys=True),
                                                                    json.dumps(got[f], sort_keys=True)))
        print("verify-row: %s" % ("MISMATCH " + ",".join(bad) if bad else "the row matches its outputs"))
        return 1 if bad else 0
    else:
        verdict, info = gate(repo, a.base, a.head, a.target_class)
        print("critic-eval gate: %s - %s" % (verdict, info.pop("reason")))
        print(json.dumps(info, sort_keys=True))
        return 0 if verdict in ("keep", "no-loss") else 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
