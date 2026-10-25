#!/usr/bin/env python3
"""mine-tasks.py - mine lane-quality real tasks from merged changes.

A real task is one merged squash commit that changed a test-*.sh file and some
code: the agent gets the ticket text and the tree at the commit's first parent
(the base), and acceptance is the merged version of that test, kept hidden.

  candidates  list merged changes that could be tasks, one JSON object per line
  emit        write task directories for chosen merge commits
  validate    keep a task only if its hidden tests fail at the base and pass at the merge
  accept      (called by a task's accept.sh) run the hidden tests over a tree

Each command takes --help. The source is tagged from the ticket: bug (Jira type
Bug), escape (a post-merge escape or regression), else proof-first.

Hidden files are stored gzipped as tasks/<id>/hidden/<path>.ref.gz (mtime 0, so a
re-emit is byte-identical): CI never discovers them as suites, the qmd index
(**/*.md) and grep never see their text, and .graphifyignore keeps them out of
the graph. The prompt carries the ticket summary and
description with code blocks and failure text removed, plus the names of the
checks the hidden tests add. It is written to tasks/<id>/fixture/prompt.md: the
ticket text is recorded data, kept verbatim, as the docs gates treat fixtures.
"""

import argparse
import gzip
import json
import os
import re
import shutil
import signal
import subprocess
import sys
import tempfile

SUBJECT = re.compile(r"^[a-z]+(\([^)]*\))?!?: \[([A-Z][A-Z0-9]*-\d+)\] .* \(#(\d+)\)$")
TEST = re.compile(r"(^|/)test-[^/]*\.sh$")
FIXTURE = re.compile(r"(^|/)fixtures/")
EXCLUDE = re.compile(r"^(scripts/hooks/|\.github/|scripts/eval/lane-quality/)")
FAILURE = re.compile(r"\bFAIL(ED)?\b|^\s*not ok\b|Traceback|\bexit (code|status) \d|\brc[= ]\d|^\s*\$ ")
# a user's home directory name in ticket text, replaced by <user> in the prompt
HOME_PATH = re.compile(r"(/home/|/Users/|[A-Za-z]:[\\/]Users[\\/])(?!\.)([^/\\\s]{2,})")
ESCAPE = re.compile(r"\b(escape[sd]?|regression|post-merge|broke|broken)\b", re.I)
# an added line calling a test helper with a prose label: check "…", eq "…", contains "…"
CHECK = re.compile(r"""^\+\s*([a-z_][a-z0-9_]*)\s+(?:"([^"$`]*\s[^"$`]*)"|'([^'$`]*\s[^'$`]*)')""")
NOT_CHECK = re.compile(r"^(echo|printf|bash|sh|cp|mv|rm|mkdir|cat|trap|local|export|declare|readonly|read|cd|source"
                       r"|grep|sed|awk|jq|git|exit|return|die|fail|bad|warn|log|note|info|err|error|python3|node|env"
                       r"|timeout|touch|chmod|ln|tee|sleep|eval|exec|set|unset|mk\w*|write\w*)$")
DATE = "2026-01-01T00:00:00Z"


def git(repo, *args, text=True):
    return subprocess.run(["git", "-C", repo, *args], check=True, capture_output=True, text=text).stdout


def trust_patterns(repo, rev):
    try:
        body = git(repo, "show", "%s:scripts/ci/ci-trust-paths.txt" % rev)
    except subprocess.CalledProcessError:
        return []
    out = []
    for line in body.splitlines():
        line = line.strip()
        if line and not line.startswith("#"):
            try:
                out.append(re.compile(line))
            except re.error:
                pass
    return out


def ticket_meta(mirror, key):
    """(summary, description, type) from a Jira mirror file, empty when absent."""
    path = os.path.join(mirror, "%s.md" % key)
    if not os.path.isfile(path):
        return "", "", ""
    body = open(path, encoding="utf-8").read()
    typ = ""
    m = re.match(r"^---\n(.*?)\n---\n", body, re.S)
    if m:
        t = re.search(r'^type:\s*"?([^"\n]+)"?\s*$', m.group(1), re.M)
        typ = t.group(1).strip() if t else ""
        body = body[m.end():]
    s = re.search(r"^# %s: (.*)$" % re.escape(key), body, re.M)
    summary = s.group(1).strip() if s else ""
    d = re.search(r"^## Description\n(.*?)(?=^## |\Z)", body, re.S | re.M)
    return summary, (d.group(1).strip() if d else ""), typ


def source_of(typ, summary, description):
    if typ.lower() == "bug":
        return "bug"
    if ESCAPE.search(summary) or ESCAPE.search(description[:400]):
        return "escape"
    return "proof-first"


def changed(repo, sha):
    """[(status, path)] for one commit against its first parent."""
    out = git(repo, "diff-tree", "--no-commit-id", "-r", "--name-status", "--no-renames", "%s^" % sha, sha)
    rows = []
    for line in out.splitlines():
        st, _, path = line.partition("\t")
        rows.append((st[:1], path))
    return rows


def describe(repo, sha, mirror, trust, max_files, max_lines):
    """The candidate record for one commit, or None when it is not a task."""
    subject = git(repo, "log", "-1", "--format=%s", sha).strip()
    m = SUBJECT.match(subject)
    if not m:
        return None
    rows = changed(repo, sha)
    paths = [p for _, p in rows]
    if not paths or len(paths) > max_files:
        return None
    if any(EXCLUDE.search(p) or any(t.search(p) for t in trust) for p in paths):
        return None
    tests = sorted(p for st, p in rows if st in "AM" and TEST.search(p))
    fixtures = sorted(p for st, p in rows if st in "AM" and FIXTURE.search(p) and not TEST.search(p))
    code = [p for p in paths if p not in tests and p not in fixtures]
    if not tests or not code:
        return None
    stat = git(repo, "diff", "--numstat", "%s^" % sha, sha)
    lines = sum(int(a) + int(b) for a, b, _ in (l.split("\t", 2) for l in stat.splitlines()) if a.isdigit() and b.isdigit())
    if lines > max_lines:
        return None
    key, pr = m.group(2), int(m.group(3))
    summary, description, typ = ticket_meta(mirror, key)
    return {"merge_sha": git(repo, "rev-parse", sha).strip(), "base_sha": git(repo, "rev-parse", "%s^" % sha).strip(),
            "ticket": key, "pr": pr, "subject": subject, "tests": tests, "fixtures": fixtures, "code": sorted(code),
            "lines": lines, "source": source_of(typ, summary, description), "has_ticket_text": bool(summary)}


def cmd_candidates(a):
    trust = trust_patterns(a.repo, a.rev)
    args = ["log", "--first-parent", "--format=%H", a.rev]
    if a.since:
        args.insert(3, "--since=%s" % a.since)
    n = 0
    for sha in git(a.repo, *args).split():
        if a.limit and n >= a.limit:
            break
        try:
            rec = describe(a.repo, sha, a.mirror, trust, a.max_files, a.max_lines)
        except subprocess.CalledProcessError:
            continue  # a root commit has no parent
        if rec:
            print(json.dumps(rec))
            n += 1
    return 0


def clean_text(text):
    """The ticket text without fenced blocks, failure output or shell transcripts."""
    text = re.sub(r"```.*?```", "", text, flags=re.S)
    keep = [l for l in text.splitlines() if not FAILURE.search(l)]
    text = HOME_PATH.sub(r"\1<user>", "\n".join(keep))
    return re.sub(r"\n{3,}", "\n\n", text).strip()


def check_names(repo, sha, tests):
    names = []
    for t in tests:
        for line in git(repo, "diff", "%s^" % sha, sha, "--", t).splitlines():
            m = CHECK.match(line)
            label = m and (m.group(2) or m.group(3))
            if label and not NOT_CHECK.match(m.group(1)) and not FAILURE.search(label):
                names.append((t, label.strip()))
    return names


def scope_of(paths):
    dirs = sorted({(os.path.dirname(p) + "/") if "/" in p else p for p in paths})
    return [d for d in dirs if not any(d != o and o.endswith("/") and d.startswith(o) for o in dirs)]


ACCEPT = """#!/usr/bin/env bash
# Hidden acceptance for a mined real task: the merged tests in hidden/ replace
# the agent's copies in a scratch copy of its tree, then run there.
# Usage: accept.sh <tree> [fixture-sha]
HERE="$(cd "$(dirname "$0")" && pwd)"
exec python3 "$HERE/../../mine-tasks.py" accept "$HERE" "$@"
"""


def cmd_emit(a):
    trust = trust_patterns(a.repo, "HEAD")
    rc = 0
    for sha in a.sha:
        rec = describe(a.repo, sha, a.mirror, trust, a.max_files, a.max_lines)
        if not rec:
            print("emit: %s is not a candidate" % sha, file=sys.stderr)
            rc = 1
            continue
        summary, description, _ = ticket_meta(a.mirror, rec["ticket"])
        if not summary:
            print("emit: %s has no ticket text in %s" % (rec["ticket"], a.mirror), file=sys.stderr)
            rc = 1
            continue
        tid = "real-%s-%d" % (rec["ticket"].lower(), rec["pr"])
        d = os.path.join(a.tasks_dir, tid)
        if os.path.exists(d):
            shutil.rmtree(d)
        os.makedirs(os.path.join(d, "hidden"))
        names = check_names(a.repo, rec["merge_sha"], rec["tests"])
        body = ["# %s" % summary, "", clean_text(description) or "(no description)", "", "## What to deliver", "",
                "Make the change this ticket asks for, in this repository. It is checked by these test files,"
                " which you may add to or change:", ""]
        body += ["- `%s`" % t for t in rec["tests"]]
        if names:
            body += ["", "The checks it must pass include:", ""]
            body += ["- `%s`: %s" % (t, n) for t, n in names]
        body += ["", "Run the tests you touch before you finish. Report what you changed and what you checked."]
        os.makedirs(os.path.join(d, "fixture"))
        with open(os.path.join(d, "fixture", "prompt.md"), "w", encoding="utf-8") as fh:
            fh.write("\n".join(body) + "\n")
        for p in rec["tests"] + rec["fixtures"]:
            dst = os.path.join(d, "hidden", p + ".ref.gz")
            os.makedirs(os.path.dirname(dst), exist_ok=True)
            with open(dst, "wb") as fh:
                fh.write(gzip.compress(git(a.repo, "show", "%s:%s" % (rec["merge_sha"], p), text=False), mtime=0))
        why = ("%d code file(s), %d changed lines; the hidden %s must go from failing at the base to passing,"
               " checked by %d named check(s)" % (len(rec["code"]), rec["lines"], ", ".join(rec["tests"]), len(names)))
        modes = git(a.repo, "ls-tree", rec["merge_sha"], "--", *(rec["tests"] + rec["fixtures"])).splitlines()
        task = {"id": tid, "ticket": rec["ticket"], "pr": rec["pr"], "merge_sha": rec["merge_sha"],
                "base_sha": rec["base_sha"], "set": a.set, "source": rec["source"], "why_hard": why,
                "tests": rec["tests"], "fixtures": rec["fixtures"],
                "exec": sorted(l.split("\t", 1)[1] for l in modes if l.startswith("100755 ")),
                "scope": scope_of(rec["code"] + rec["tests"] + rec["fixtures"])}
        with open(os.path.join(d, "task.json"), "w", encoding="utf-8") as fh:
            json.dump(task, fh, indent=2)
            fh.write("\n")
        acc = os.path.join(d, "accept.sh")
        with open(acc, "w", encoding="utf-8") as fh:
            fh.write(ACCEPT)
        os.chmod(acc, 0o755)
        print(d)
    return rc


def overlay_path(root, rel):
    """root/rel with no symlink on the way: a link the agent left there is removed, never followed."""
    cur = root
    for part in rel.split("/"):
        cur = os.path.join(cur, part)
        if os.path.islink(cur):
            os.unlink(cur)
    os.makedirs(os.path.dirname(cur), exist_ok=True)
    return cur


def run_hidden(task_dir, tree, timeout):
    """Copy the tree, lay the hidden files over it, run each hidden test; (passed, total, lines)."""
    task = json.load(open(os.path.join(task_dir, "task.json"), encoding="utf-8"))
    work = tempfile.mkdtemp(prefix="lq-accept.")
    home = tempfile.mkdtemp(prefix="lq-home.")
    try:
        dst = os.path.join(work, "t")
        shutil.copytree(tree, dst, symlinks=True)
        if os.path.isfile(os.path.join(dst, ".git")):
            # a linked worktree's .git points at the agent's repo: give the copy its own
            os.unlink(os.path.join(dst, ".git"))
            commit_tree(dst)
        hidden = os.path.join(task_dir, "hidden")
        for root, _, files in os.walk(hidden):
            for f in files:
                src = os.path.join(root, f)
                rel = os.path.relpath(src, hidden)[: -len(".ref.gz")]
                with gzip.open(src, "rb") as fi, open(overlay_path(dst, rel), "wb") as fo:
                    shutil.copyfileobj(fi, fo)
        env = {"HOME": home, "PATH": os.environ.get("PATH", "/usr/bin:/bin"), "TMPDIR": tempfile.gettempdir(),
               "LANG": "C.UTF-8", "GIT_AUTHOR_NAME": "lq", "GIT_AUTHOR_EMAIL": "lq@invalid",
               "GIT_COMMITTER_NAME": "lq", "GIT_COMMITTER_EMAIL": "lq@invalid",
               "GIT_AUTHOR_DATE": DATE, "GIT_COMMITTER_DATE": DATE}
        for rel in task.get("exec", []):
            os.chmod(os.path.join(dst, rel), 0o755)
        passed, out = 0, []
        for t in task["tests"]:
            p = subprocess.Popen(["bash", t], cwd=dst, env=env, stdin=subprocess.DEVNULL,
                                 stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
            try:
                ok = p.wait(timeout=timeout) == 0
            except subprocess.TimeoutExpired:
                ok = False
            finally:
                try:
                    os.killpg(p.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                p.wait()
            passed += ok
            out.append("%s %s" % ("ok" if ok else "FAIL", t))
        return passed, len(task["tests"]), out
    finally:
        shutil.rmtree(work, ignore_errors=True)
        shutil.rmtree(home, ignore_errors=True)


def cmd_accept(a):
    passed, total, out = run_hidden(a.task_dir, a.tree, a.timeout)
    print("\n".join(out))
    print("accept: %d/%d" % (passed, total))
    return 0 if total and passed == total else 1


def tree_repo(repo, sha, dest):
    """sha's tree as the only commit of a new repo, as run.sh makes a task repo."""
    os.makedirs(dest)
    arch = subprocess.run(["git", "-C", repo, "archive", sha], check=True, capture_output=True).stdout
    subprocess.run(["tar", "-x", "-C", dest], input=arch, check=True)
    commit_tree(dest)


def commit_tree(dest):
    """dest's files as the only commit of a new repo in dest."""
    env = dict(os.environ, GIT_AUTHOR_DATE=DATE, GIT_COMMITTER_DATE=DATE)
    for args in (["init", "-q", "-b", "lq-task"], ["add", "-A"],
                 ["-c", "user.name=lane-quality", "-c", "user.email=lane-quality@invalid", "-c", "commit.gpgsign=false",
                  "commit", "-q", "--no-verify", "-m", "lane-quality task base"]):
        subprocess.run(["git", "-C", dest, *args], check=True, capture_output=True, env=env)


def cmd_validate(a):
    task = json.load(open(os.path.join(a.task_dir, "task.json"), encoding="utf-8"))
    tmp = tempfile.mkdtemp(prefix="lq-validate.")
    try:
        res = {}
        for name in ("base", "merge"):
            d = os.path.join(tmp, name)
            tree_repo(a.repo, task["%s_sha" % name], d)
            passed, total, out = run_hidden(a.task_dir, d, a.timeout)
            res[name] = passed == total
            print("%s: %s (%d/%d)" % (name, "passes" if res[name] else "fails", passed, total))
            for line in out:
                print("  " + line)
        good = not res["base"] and res["merge"]
        print("validate: %s %s" % (task["id"], "kept" if good else "refused"))
        return 0 if good else 1
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def main(argv):
    p = argparse.ArgumentParser(prog="mine-tasks.py", description=__doc__.split("\n\n")[0])
    sub = p.add_subparsers(dest="cmd", required=True)
    mirror = os.path.expanduser("~/.himmel/state/jira-mirror/HIMMEL")

    c = sub.add_parser("candidates", help="list merged changes that could be tasks (JSON lines)")
    c.add_argument("--repo", default=".", help="source repository (default: .)")
    c.add_argument("--rev", default="HEAD", help="branch or commit whose first-parent history is read (default: HEAD)")
    c.add_argument("--since", help="only commits after this git date, e.g. 30.days")
    c.add_argument("--limit", type=int, default=0, help="stop after this many candidates (default: no limit)")
    c.add_argument("--mirror", default=mirror, help="Jira mirror directory of <KEY>.md files (default: %(default)s)")
    c.add_argument("--max-files", type=int, default=6, help="most files a change may touch (default: 6)")
    c.add_argument("--max-lines", type=int, default=400, help="most changed lines (default: 400)")

    e = sub.add_parser("emit", help="write task directories for chosen merge commits")
    e.add_argument("--repo", default=".", help="source repository (default: .)")
    e.add_argument("--mirror", default=mirror, help="Jira mirror directory (default: %(default)s)")
    e.add_argument("--tasks-dir", required=True, help="directory the task directories are written under")
    e.add_argument("--sha", action="append", required=True, help="a merge commit to emit (repeatable)")
    e.add_argument("--set", default="capability", choices=["capability", "regression"], help="task set (default: capability)")
    e.add_argument("--max-files", type=int, default=6, help="as for candidates")
    e.add_argument("--max-lines", type=int, default=400, help="as for candidates")

    v = sub.add_parser("validate", help="hidden tests must fail at the base and pass at the merge")
    v.add_argument("task_dir")
    v.add_argument("--repo", default=".", help="source repository holding both commits (default: .)")
    v.add_argument("--timeout", type=int, default=120, help="seconds per test file (default: 120)")

    t = sub.add_parser("accept", help="run a task's hidden tests over a tree (called by accept.sh)")
    t.add_argument("task_dir")
    t.add_argument("tree")
    t.add_argument("fixture_sha", nargs="?", help="ignored; accept.sh takes the same arguments as every task")
    t.add_argument("--timeout", type=int, default=120, help="seconds per test file (default: 120)")

    a = p.parse_args(argv)
    return {"candidates": cmd_candidates, "emit": cmd_emit, "validate": cmd_validate, "accept": cmd_accept}[a.cmd](a)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
