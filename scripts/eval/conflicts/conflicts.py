#!/usr/bin/env python3
"""conflicts.py - the conflict recorder (slice S3 of the no-file-holds work): detect a hand-resolved merge conflict on a PR head, and
write one exclusive ledger file per merged PR.

  detect   --repo-dir R --head SHA --base-ref REF [--pr N]
  record   --snapshot FILE --repo-dir R --base-ref REF [--ledger-dir L] [--source S]
  backfill --since ISO --repo-dir R --base-ref REF [--ledger-dir L]

detect prints one TAB-separated line per conflicted file, "<file>\\tother_prs [<n>, ...]\\t<resolution>\\t<merge sha>",
with resolution merged | ours | theirs | deleted. ours = the branch's side won (main's change to the file was dropped).
A clean merge prints nothing. A head with more than 20 merge commits (or any git read that fails) prints
"unknown (over 20 merges)" / "unknown (<reason>)" and lists no file. A head missing from the object store (a fork PR,
with --pr N) gets one bounded `git fetch --no-write-fetch-head origin refs/pull/N/head`; the flag keeps the shared
FETCH_HEAD untouched (a plain fetch races other git commands reading it).

record reads a `gh pr view --json number,title,body,mergedAt,mergeCommit,headRefOid,isCrossRepository` snapshot and
writes <ledger>/conflicts/<pr>.jsonl exclusively (temp file + link(2)), one JSON line per conflicted or reported file.
It prints ONE machine line, which merge-on-green (S4) reads: "wrote:<N> <file> vs #<n> <resolution>[; ...]" | "none" |
"kept" (the file already existed; its bytes are left alone) | "unknown" (detection failed; nothing written, the
backfill can rebuild it). Without --ledger-dir the directory is judge_accuracy.ledger_dir's rule with its subdir
swapped to conflicts; --ledger-dir L puts the file at L/conflicts/<pr>.jsonl (for tests).

backfill reads the PRs merged since --since from `gh pr list` and records each one with source: backfill.

  week [--days N] [--repo-dir R] [--base-ref REF] [--ledger-dir L]

week prints two lines from the ledger, git and one `gh run list` read, never typed by hand: the count line
("conflicts 7d: <files> files in <prs> PRs (...); later: reverted <n>, red main <n> | unknown, bug-origin <n>; top files: ...")
and "harm: #<pr> <why>, conflict files <f>; ..." (or "harm: none"). Reverted reads one bounded git log of REF; red main is the
first completed ci.yml main run containing the merge commit; bug-origin is a <ledger>/bug-origin row whose origin is #<pr>.

parse_body(text) is the one reader of the PR body's `## Conflicts resolved` section, shared with ready-check (S5) and
merge-on-green (S4): [(path, [pr numbers], note)].

Exit: 0 done; 2 refused input. Stdlib only.
"""
import argparse
import json
import os
import re
import subprocess
import sys
from datetime import datetime, timedelta, timezone

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "judge-accuracy"))
import judge_accuracy  # noqa: E402

SUBDIR = "conflicts"
MAX_MERGES = 20
GIT_SECS = 30
GH_SECS = 30
BACKFILL_LIMIT = 500
NOTE_MAX = 300
TRUST_LIST = "scripts/ci/ci-trust-paths.txt"

SECTION = re.compile(r"^## Conflicts resolved[ \t]*$")
ITEM = re.compile(r"^[-*][ \t]+`?(.+?)`?[ \t]+vs[ \t]+(#[0-9]+(?:[ \t]*,[ \t]*#[0-9]+)*)[ \t]*(?::[ \t]*(.*?))?[ \t]*$")
SQUASH_PR = re.compile(r"\(#([0-9]+)\)\s*$")
KEY = re.compile(r"\[([A-Z][A-Z0-9]*-[0-9]+)\]")


class Unknown(Exception):
    pass


def parse_body(text):
    """[(path, [pr numbers], note)] from the `## Conflicts resolved` section: lines `- path vs #n[, #m]: note` up to the next `## `."""
    rows, inside = [], False
    for line in (text or "").replace("\r", "").split("\n"):
        if SECTION.match(line):
            inside = True
        elif line.startswith("## "):
            inside = False
        elif inside:
            m = ITEM.match(line)
            if m:
                rows.append((m.group(1), [int(n) for n in re.findall(r"[0-9]+", m.group(2))], (m.group(3) or "")[:NOTE_MAX]))
    return rows


def git(repo, *args, ok=(0,)):
    env = {k: v for k, v in os.environ.items() if k not in ("GIT_DIR", "GIT_WORK_TREE", "GIT_COMMON_DIR", "GIT_INDEX_FILE")}
    env["GIT_TERMINAL_PROMPT"] = "0"
    try:
        r = subprocess.run(["git", "-C", repo] + list(args), capture_output=True, timeout=GIT_SECS, env=env)
    except (subprocess.TimeoutExpired, OSError) as e:
        raise Unknown("git %s: %s" % (args[0], type(e).__name__))
    if r.returncode not in ok:
        raise Unknown("git %s exit %d" % (args[0], r.returncode))
    return r.returncode, r.stdout


def text(repo, *args):
    return git(repo, *args)[1].decode("utf-8", "replace").strip()


def blob(repo, commit, path):
    rc, out = git(repo, "rev-parse", "--verify", "--quiet", "%s:%s" % (commit, path), ok=(0, 1))
    return out.decode().strip() if rc == 0 else ""


def have(repo, sha):
    try:
        git(repo, "cat-file", "-e", sha + "^{commit}")
        return True
    except Unknown:
        return False


def detect(repo, head, base, pr=None):
    try:
        if not have(repo, head) and pr:
            git(repo, "fetch", "--no-write-fetch-head", "origin", "refs/pull/%d/head" % pr)
        if not have(repo, head):
            raise Unknown("head %s not in the object store" % head[:12])
        merges = text(repo, "rev-list", "--merges", head, "--not", base).split()
        if len(merges) > MAX_MERGES:
            return [], "over 20 merges"
        rows = {}
        for m in merges:
            parents = text(repo, "rev-list", "--parents", "-n", "1", m).split()[1:]
            if len(parents) != 2:
                raise Unknown("merge %s has %d parents" % (m[:12], len(parents)))
            p1, p2 = parents
            rc, out = git(repo, "merge-tree", "--write-tree", "--name-only", "--no-messages", "-z", p1, p2, ok=(0, 1))
            if rc == 0:
                continue
            names = [n.decode("utf-8", "replace") for n in out.split(b"\0")[1:] if n]
            mb = text(repo, "merge-base", p1, p2)
            for f in names:
                subjects = text(repo, "log", "--format=%s", "%s..%s" % (mb, p2), "--", f).split("\n")
                others = sorted({int(n) for s in subjects for n in SQUASH_PR.findall(s)})
                if f in rows:
                    rows[f]["other_prs"] = sorted(set(rows[f]["other_prs"]) | set(others))
                    continue
                bm, b1, b2 = blob(repo, m, f), blob(repo, p1, f), blob(repo, p2, f)
                res = "deleted" if not bm else "ours" if bm == b1 else "theirs" if bm == b2 else "merged"
                rows[f] = {"file": f, "other_prs": others, "resolution": res, "merge": m}
        return list(rows.values()), ""
    except Unknown as e:
        return [], str(e)


def gh_json(repo, *args):
    try:
        r = subprocess.run(["gh"] + list(args), capture_output=True, text=True, timeout=GH_SECS, cwd=repo)
    except (subprocess.TimeoutExpired, OSError):
        return None
    if r.returncode != 0:
        return None
    try:
        return json.loads(r.stdout)
    except ValueError:
        return None


def outside_pr(repo, n):
    d = gh_json(repo, "pr", "view", str(n), "--json", "isCrossRepository")
    return bool(isinstance(d, dict) and d.get("isCrossRepository"))


def trust_patterns(repo, base):
    try:
        raw = text(repo, "show", "%s:%s" % (base, TRUST_LIST))
    except Unknown:
        return []
    pats = []
    for line in raw.split("\n"):
        line = line.strip()
        if line and not line.startswith("#"):
            try:
                pats.append(re.compile(line))
            except re.error:
                pass
    return pats


def repo_slug(repo):
    try:
        url = text(repo, "remote", "get-url", "origin")
    except Unknown:
        return ""
    m = re.search(r"[:/]([^/:]+/[^/]+?)(?:\.git)?/?$", url)
    return m.group(1) if m else ""


def ledger_root(repo, override):
    if override:
        return os.path.join(override, SUBDIR)
    judge_accuracy.LEDGER_SUBDIR = SUBDIR
    return judge_accuracy.ledger_dir(repo)


def write_exclusive(path, data):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = "%s.tmp-%d-%s" % (path, os.getpid(), os.urandom(8).hex())
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o666)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            fh.write(data)
            fh.flush()
            os.fsync(fh.fileno())
        try:
            os.link(tmp, path)
        except FileExistsError:
            return False
        return True
    finally:
        os.unlink(tmp)


def machine_row(r):
    prs = ",".join("#%d" % n for n in r["other_prs"])
    return "%s vs %s %s" % (r["file"], prs, r["resolution"]) if prs else "%s %s" % (r["file"], r["resolution"])


def record(snap, repo, base, ledger, source):
    pr = int(snap["number"])
    root = ledger_root(repo, ledger)
    if root is None:
        sys.stderr.write("conflicts: no handover root configured; pass --ledger-dir\n")
        sys.exit(2)
    path = os.path.join(root, "%d.jsonl" % pr)
    if os.path.exists(path):
        return "kept"
    head = snap.get("headRefOid") or ""
    found, reason = detect(repo, head, base, pr if snap.get("isCrossRepository") else None)
    if reason:
        return "unknown"
    rows = {r["file"]: dict(r, detected=True, reported=False, note="") for r in found}
    for f, prs, note in parse_body(snap.get("body")):
        if f in rows:
            rows[f].update(reported=True, note=note, other_prs=sorted(set(rows[f]["other_prs"]) | set(prs)))
        else:
            rows[f] = {"file": f, "other_prs": sorted(set(prs)), "resolution": "reported", "merge": "",
                       "detected": False, "reported": True, "note": note}
    if not rows:
        return "none"
    pats = trust_patterns(repo, base)
    slug = repo_slug(repo)
    key = (KEY.search(snap.get("title") or "") or [None, ""])[1]
    mc = snap.get("mergeCommit") or {}
    now = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    outside = {}
    out_rows = []
    for r in rows.values():
        for n in r["other_prs"]:
            if n not in outside:
                outside[n] = outside_pr(repo, n)
        out_rows.append({"v": 1, "repo": slug, "pr": pr, "key": key, "head": head,
                         "merge_commit": mc.get("oid") or "", "merged_at": snap.get("mergedAt") or "",
                         "merge": r["merge"], "file": r["file"], "other_prs": r["other_prs"],
                         "resolution": r["resolution"], "detected": r["detected"], "reported": r["reported"],
                         "note": r["note"], "trust_path": any(p.search(r["file"]) for p in pats),
                         "outside": any(outside[n] for n in r["other_prs"]), "source": source, "recorded_at": now})
    if not write_exclusive(path, "".join(json.dumps(r, sort_keys=True) + "\n" for r in out_rows)):
        return "kept"
    return "wrote:%d %s" % (len(out_rows), "; ".join(machine_row(r) for r in out_rows))


def cmd_detect(a):
    rows, reason = detect(a.repo_dir, a.head, a.base_ref, a.pr)
    if reason:
        print("unknown (%s)" % reason)
    for r in rows:
        print("%s\tother_prs %s\t%s\t%s" % (r["file"], r["other_prs"], r["resolution"], r["merge"]))
    return 0


def cmd_record(a):
    try:
        snap = json.load(open(a.snapshot, encoding="utf-8"))
        int(snap["number"])
    except (OSError, ValueError, KeyError, TypeError):
        sys.stderr.write("conflicts: unreadable snapshot %s\n" % a.snapshot)
        return 2
    print(record(snap, a.repo_dir, a.base_ref, a.ledger_dir, a.source))
    return 0


def cmd_backfill(a):
    d = judge_accuracy.when(a.since)
    if d is None:
        sys.stderr.write("conflicts: --since is not an ISO time: %s\n" % a.since)
        return 2
    prs = gh_json(a.repo_dir, "pr", "list", "--state", "merged", "--search", "merged:>=%s" % d.strftime("%Y-%m-%d"), "--limit", str(BACKFILL_LIMIT),
                  "--json", "number,title,body,mergedAt,mergeCommit,headRefOid,isCrossRepository")
    if not isinstance(prs, list):
        sys.stderr.write("conflicts: gh pr list failed\n")
        return 2
    if len(prs) >= BACKFILL_LIMIT:
        sys.stderr.write("conflicts: gh returned %d PRs, the most it lists; narrow --since and run again\n" % BACKFILL_LIMIT)
        return 2
    for snap in prs:
        merged = judge_accuracy.when(snap.get("mergedAt") or "")
        if merged is not None and merged < d:
            continue
        print("#%s %s" % (snap["number"], record(snap, a.repo_dir, a.base_ref, a.ledger_dir, "backfill")))
    return 0


def read_ledger_rows(root, cutoff):
    """Every ledger row merged (else recorded) at or after cutoff, from <root>/*.jsonl; an unreadable line is skipped."""
    rows = []
    if not root or not os.path.isdir(root):
        return rows
    for f in sorted(os.listdir(root)):
        if not f.endswith(".jsonl"):
            continue
        try:
            with open(os.path.join(root, f), encoding="utf-8") as fh:
                lines = fh.read().split("\n")
        except OSError:
            continue
        for line in lines:
            try:
                r = json.loads(line)
            except ValueError:
                continue
            when = judge_accuracy.when(r.get("merged_at") or r.get("recorded_at") or "") if isinstance(r, dict) else None
            if when is not None and when >= cutoff and type(r.get("pr")) is int:
                rows.append(r)
    return rows


def reverted_prs(repo, base, since, rows):
    """{pr: short sha of the reverting commit}: one bounded git log of base since `since`, matched on `This reverts commit <merge_commit>`
    or a subject `Revert "...(#<pr>)"`. None when git fails."""
    try:
        out = text(repo, "log", "--max-count=2000", "--since=%s" % since, "--format=%h%x00%s%x00%b%x01", base)
    except Unknown:
        return None
    merges = {r["pr"]: r["merge_commit"] for r in rows if r.get("merge_commit")}
    found = {}
    for entry in out.split("\x01"):
        parts = entry.strip().split("\x00")
        if len(parts) < 3:
            continue
        sha, subject, body = parts[0], parts[1], parts[2]
        for pr, mc in merges.items():
            if pr in found:
                continue
            m = re.match(r'Revert ".*\(#([0-9]+)\)"\s*$', subject)
            if mc in body or (m and int(m.group(1)) == pr):
                found[pr] = sha
    return found


def red_main_prs(repo, rows):
    """{pr: run id}: the first completed ci.yml main run whose head contains the PR's merge commit ended in failure.
    One `gh run list` read. None when gh fails."""
    runs = gh_json(repo, "run", "list", "--workflow", "ci.yml", "--branch", "main", "--limit", "200",
                   "--json", "databaseId,headSha,status,conclusion,createdAt")
    if not isinstance(runs, list):
        return None
    runs = sorted((r for r in runs if isinstance(r, dict) and r.get("status") == "completed"), key=lambda r: r.get("createdAt") or "")
    found = {}
    for r in rows:
        mc = r.get("merge_commit")
        if not mc or r["pr"] in found:
            continue
        for run in runs:
            try:
                git(repo, "merge-base", "--is-ancestor", mc, run.get("headSha") or "")
            except Unknown:
                continue
            if run.get("conclusion") == "failure":
                found[r["pr"]] = run.get("databaseId")
            break
    return found


def cmd_week(a):
    cutoff = datetime.now(timezone.utc) - timedelta(days=a.days)
    if a.ledger_dir:
        root, bug_dir = os.path.join(a.ledger_dir, SUBDIR), os.path.join(a.ledger_dir, "bug-origin")
    else:
        root = ledger_root(a.repo_dir, None)
        if root is None:
            sys.stderr.write("conflicts: no handover root configured; pass --ledger-dir\n")
            return 2
        bug_dir = os.path.join(os.path.dirname(root), "bug-origin")
    rows = read_ledger_rows(root, cutoff)
    prs = sorted({r["pr"] for r in rows})
    files = {}
    for r in rows:
        files[r.get("file", "")] = files.get(r.get("file", ""), 0) + 1
    kinds = (("unreported", sum(1 for r in rows if r.get("reported") is False)),
             ("ours", sum(1 for r in rows if r.get("resolution") == "ours")),
             ("trust", sum(1 for r in rows if r.get("trust_path"))),
             ("outside", sum(1 for r in rows if r.get("outside"))))
    reverted = reverted_prs(a.repo_dir, a.base_ref, cutoff.strftime("%Y-%m-%dT%H:%M:%SZ"), rows) if rows else {}
    red = red_main_prs(a.repo_dir, rows) if rows else {}
    origins = {int(m.group(1)) for r in judge_accuracy.load_ledger(bug_dir).values()
               for m in [re.fullmatch(r"#([0-9]+)", r["origin"])] if m}
    blamed = [n for n in prs if n in origins]
    top = sorted(files.items(), key=lambda kv: (-kv[1], kv[0]))[:3]
    line = "conflicts 7d: %d files in %d PRs (%s); later: reverted %s, red main %s, bug-origin %d; top files: %s" % (
        len(rows), len(prs), ", ".join("%s %d" % k for k in kinds),
        "unknown" if reverted is None else len(reverted),
        "unknown" if red is None else "%d%s" % (len(red), " (%s)" % ", ".join("#%d" % n for n in sorted(red)) if red else ""),
        len(blamed), ", ".join("%s (%d)" % kv for kv in top) or "none")
    line = line.replace("conflicts 7d:", "conflicts %dd:" % a.days, 1)
    harm = []
    for n in prs:
        why = []
        if reverted and n in reverted:
            why.append("reverted by %s" % reverted[n])
        if red and n in red:
            why.append("red main run %s (ci.yml)" % red[n])
        if n in blamed:
            why.append("bug-origin")
        if why:
            fl = sorted({r.get("file", "") for r in rows if r["pr"] == n})
            harm.append("#%d %s, conflict files %s" % (n, ", ".join(why), " ".join(fl)))
    print(line)
    print("harm: " + ("; ".join(harm) if harm else "none"))
    return 0


def main(argv=None):
    p = argparse.ArgumentParser(description="conflict recorder")
    sub = p.add_subparsers(dest="verb", required=True)
    d = sub.add_parser("detect")
    d.add_argument("--repo-dir", required=True)
    d.add_argument("--head", required=True)
    d.add_argument("--base-ref", required=True)
    d.add_argument("--pr", type=int)
    r = sub.add_parser("record")
    r.add_argument("--snapshot", required=True)
    r.add_argument("--repo-dir", required=True)
    r.add_argument("--base-ref", required=True)
    r.add_argument("--ledger-dir")
    r.add_argument("--source", default="merge-on-green", choices=("merge-on-green", "backfill"))
    b = sub.add_parser("backfill")
    b.add_argument("--since", required=True)
    b.add_argument("--repo-dir", required=True)
    b.add_argument("--base-ref", required=True)
    b.add_argument("--ledger-dir")
    w = sub.add_parser("week")
    w.add_argument("--days", type=int, default=7)
    w.add_argument("--repo-dir", default=".")
    w.add_argument("--base-ref", default="origin/main")
    w.add_argument("--ledger-dir")
    a = p.parse_args(argv)
    return {"detect": cmd_detect, "record": cmd_record, "backfill": cmd_backfill, "week": cmd_week}[a.verb](a)


if __name__ == "__main__":
    sys.exit(main())
