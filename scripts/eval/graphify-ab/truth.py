#!/usr/bin/env python3
"""truth.py -- ground truth and exact-match scorer for the graphify A/B task set
(HIMMEL-5317).

    truth.py compute [--rev SHA]                  -> JSON {truth-rule: [items]}
    truth.py score --truth RULE --answer FILE [--rev SHA]
                                                  -> JSON {correct, precision, recall, ...}

Truth is computed from `git` objects at --rev (default: tasks.json base_sha), so
it never depends on the working tree an agent runs in. The rubric is an exact
set match on the answer's final `ANSWER: [...]` line; precision/recall are
reported alongside so a near-miss is visible, but only `correct` gates.
"""
import json
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
TASKS = os.path.join(HERE, "tasks.json")
REPO = os.path.dirname(os.path.dirname(os.path.dirname(HERE)))


def git(*args, cwd=None):
    r = subprocess.run(["git", *args], cwd=cwd or REPO, capture_output=True, text=True)
    if r.returncode not in (0, 1):  # grep exits 1 on no match
        raise SystemExit("git %s failed: %s" % (" ".join(args), r.stderr.strip()))
    return r.stdout


def base_sha():
    with open(TASKS) as f:
        return json.load(f)["base_sha"]


def grep_files(rev, needle):
    out = git("grep", "-l", "-F", needle, rev, "--", "scripts")
    return sorted(line.split(":", 1)[1] for line in out.splitlines() if ":" in line)


def is_test(path):
    return os.path.basename(path).startswith("test-")


def under_fixtures(path):
    return "fixtures" in path.split("/")[:-1]


def mustrun_members(rev):
    src = git("show", "%s:scripts/hooks/run-hook-with-bash.js" % rev)
    m = re.search(r"MUST_RUN_CHAIN_MEMBERS = new Set\(\[(.*?)\]\);", src, re.S)
    body = "\n".join(l for l in m.group(1).splitlines() if not l.strip().startswith("//"))
    return sorted(re.findall(r"'([^']+)'", body))


def graphify_bin_suites(rev):
    return [p for p in grep_files(rev, "graphify-bin.sh") if is_test(p)]


def go_sh_scripts(rev):
    return [p for p in grep_files(rev, "console-kit/go.sh")
            if p.endswith(".sh") and not is_test(p) and not under_fixtures(p)
            and p != "scripts/handover/console-kit/go.sh"]


def trust_list_mentions(rev):
    return [p for p in grep_files(rev, "ci-trust-paths.txt")
            if not is_test(p) and ".test." not in os.path.basename(p)
            and not under_fixtures(p) and p != "scripts/ci/ci-trust-paths.txt"]


def qmd_only_profiles(rev):
    d = json.loads(git("show", "%s:scripts/lanes/plugin-profiles.json" % rev))
    return sorted(n for n, p in d["profiles"].items()
                  if isinstance(p, dict) and p.get("mcpServers") == ["qmd"])


RULES = {
    "mustrun-members": mustrun_members,
    "graphify-bin-suites": graphify_bin_suites,
    "go-sh-scripts": go_sh_scripts,
    "trust-list-mentions": trust_list_mentions,
    "qmd-only-profiles": qmd_only_profiles,
}


def parse_answer(text):
    """Items of the LAST `ANSWER: [...]` line, or None when absent/malformed."""
    lines = re.findall(r"^\s*ANSWER:\s*(.*?)\s*$", text, re.M)
    if not lines:
        return None
    try:
        arr = json.loads(lines[-1])
    except ValueError:
        return None
    if not isinstance(arr, list) or not all(isinstance(x, str) for x in arr):
        return None
    return sorted({x.strip().strip("`") for x in arr})


def score(truth, text):
    ans = parse_answer(text)
    if ans is None:
        return {"correct": False, "parsed": False, "precision": 0.0, "recall": 0.0,
                "n_truth": len(truth), "n_answer": 0}
    t, a = set(truth), set(ans)
    hit = len(t & a)
    return {"correct": t == a, "parsed": True,
            "precision": hit / len(a) if a else 0.0,
            "recall": hit / len(t) if t else 1.0,
            "n_truth": len(t), "n_answer": len(a)}


def main(argv):
    if len(argv) < 1 or argv[0] not in ("compute", "score"):
        print(__doc__, file=sys.stderr)
        return 2
    rev = base_sha()
    rest = argv[1:]
    if "--rev" in rest:
        rev = rest[rest.index("--rev") + 1]
    if argv[0] == "compute":
        print(json.dumps({k: f(rev) for k, f in RULES.items()}, indent=1))
        return 0
    try:
        rule = rest[rest.index("--truth") + 1]
        path = rest[rest.index("--answer") + 1]
        fn = RULES[rule]
    except (ValueError, IndexError, KeyError):
        print(__doc__, file=sys.stderr)
        return 2
    with open(path) as f:
        print(json.dumps(score(fn(rev), f.read())))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
