#!/usr/bin/env python3
"""Feed the docs reviewer's rules table, and scope a diff's docs pages.

usage:
  docs_remarks.py harvest [--rules F] [--write] [--remarks-file F]
                          [--author LOGIN [--repo OWNER/NAME] [--limit N]]
  docs_remarks.py scope   [--rules F] [--base REF] [--head REF]

harvest: the learn step's intake. Each new operator remark becomes one
`candidate` row of the rules table (default: remarks.tsv beside this file),
with the next id, the rule `pending: the chief writes the rule`, its date,
source and quote. A quote already in the table is skipped. Whitespace runs
(newlines, tabs) in a quote become one space, so a row stays one TSV line.
Sources:
  --remarks-file  the chief's recorded docs remarks, `date<TAB>source<TAB>quote`
                  per line, `#` lines ignored;
  --author        that login's review comments, reviews and PR comments on the
                  last --limit (50) merged PRs that change a docs page (gh).
                  Agents post under the same login, so a thread-resolve reply
                  (`Fixed at`, `Follow-up:`, `Rejected:`), a `@coderabbitai`
                  command and a body with an HTML comment marker are skipped.
Without --write it prints the rows and writes nothing.

scope: the advisory CI step. Lists the docs pages `git diff base...head`
changes (SKILL.md's definition) and the active and candidate rows the judge's
docs-reviewer run applies to them, and checks the table's shape. It reviews
nothing: the review is the judge's skill run. Exit 1 on a malformed table.

Exit 2 on usage.
"""
import argparse
import json
import os
import re
import subprocess
import sys

HEADER = ["id", "state", "rule", "date", "source", "quote"]
STATES = {"active", "candidate", "retired"}
PENDING = "pending: the chief writes the rule"
AGENT_REPLY = re.compile(r"^(Fixed at [0-9a-f]{7,40}\.|Follow-up: [A-Z][A-Z0-9]*-[0-9]+\.|Rejected: |@coderabbitai\b)")


def is_docs_page(path):
    if path == "README.md" or path.startswith("site/"):
        return True
    return (path.startswith("docs/") and path.endswith((".md", ".html"))
            and not path.startswith(("docs/archive/", "docs/release/")))


def flat(text):
    return " ".join(text.split())


def read_rows(path):
    with open(path, encoding="utf-8") as f:
        lines = f.read().splitlines()
    return lines[0].split("\t") if lines else [], [l.split("\t") for l in lines[1:] if l.strip()]


def gh_lines(args):
    out = subprocess.run(["gh", *args], check=True, capture_output=True, text=True).stdout
    return [json.loads(l) for l in out.splitlines() if l.strip()]


def from_gh(author, repo, limit):
    repo_args = ["--repo", repo] if repo else []
    prs = json.loads(subprocess.run(
        ["gh", "pr", "list", *repo_args, "--state", "merged", "--limit", str(limit), "--json", "number,files"],
        check=True, capture_output=True, text=True).stdout)
    slug = repo or "{owner}/{repo}"
    fields = '[.user.login, (.created_at // .submitted_at), (.path // ""), ((.line // .original_line // "") | tostring), (.body // "")] | @json'
    for pr in prs:
        if not any(is_docs_page(f["path"]) for f in pr.get("files") or []):
            continue
        n = pr["number"]
        for kind, endpoint in (("review comment", f"repos/{slug}/pulls/{n}/comments"),
                               ("review", f"repos/{slug}/pulls/{n}/reviews"),
                               ("comment", f"repos/{slug}/issues/{n}/comments")):
            for login, when, path, line, body in gh_lines(["api", "--paginate", endpoint, "--jq", f".[] | {fields}"]):
                body = body.strip()
                if login != author or not body or AGENT_REPLY.match(body) or "<!--" in body:
                    continue
                if path and not is_docs_page(path):
                    continue
                where = f" {path}:{line}" if path else ""
                yield (when or "")[:10], f"PR {n} {kind}{where}", body


def from_file(path):
    with open(path, encoding="utf-8") as f:
        for l in f:
            if not l.strip() or l.startswith("#"):
                continue
            parts = l.rstrip("\n").split("\t", 2)
            if len(parts) == 3:
                yield parts[0], parts[1], parts[2]


def harvest(a):
    if not a.remarks_file and not a.author:
        print("harvest: give --remarks-file and/or --author", file=sys.stderr)
        return 2
    _, rows = read_rows(a.rules)
    seen = {flat(r[5]) for r in rows if len(r) == 6}
    nums = [int(r[0][1:]) for r in rows if re.fullmatch(r"M[0-9]+", r[0])]
    nxt = max(nums, default=0) + 1
    remarks = list(from_file(a.remarks_file)) if a.remarks_file else []
    if a.author:
        remarks += list(from_gh(a.author, a.repo, a.limit))
    new = []
    for date, source, quote in remarks:
        quote = flat(quote)
        if quote in seen:
            continue
        seen.add(quote)
        new.append("\t".join([f"M{nxt:02d}", "candidate", PENDING, date, flat(source), quote]))
        nxt += 1
    for row in new:
        print(row)
    if a.write and new:
        with open(a.rules, "rb+") as f:
            f.seek(0, os.SEEK_END)
            if f.tell():
                f.seek(-1, os.SEEK_END)
                lead = b"" if f.read(1) == b"\n" else b"\n"
            else:
                lead = b""
            f.write(lead + "".join(r + "\n" for r in new).encode("utf-8"))
    print(f"harvest: {len(new)} new candidate row(s){' written to ' + a.rules if a.write and new else ''}", file=sys.stderr)
    return 0


def shape_problems(header, rows):
    problems = [] if header == HEADER else [f"header is {header}, not {HEADER}"]
    ids = set()
    for r in rows:
        rid = r[0]
        if len(r) != 6:
            problems.append(f"{rid} has {len(r)} fields, not 6")
            continue
        if rid in ids:
            problems.append(f"duplicate id {rid}")
        ids.add(rid)
        if r[1] not in STATES:
            problems.append(f"{rid} has state '{r[1]}'")
        if not r[5].strip():
            problems.append(f"{rid} has no quote")
    return problems


def scope(a):
    header, rows = read_rows(a.rules)
    out = subprocess.run(["git", "diff", "--name-status", "-M", f"{a.base}...{a.head}"],
                         check=True, capture_output=True, text=True).stdout
    pages = []
    for l in out.splitlines():
        parts = l.split("\t")
        if is_docs_page(parts[-1]):
            pages.append(f"- {parts[0][0]} {parts[-1]}")
    states = [r[1] for r in rows if len(r) > 1]
    if pages:
        print(f"docs-review scope: {len(pages)} changed docs page(s); the judge runs the docs-reviewer skill on them "
              f"against {states.count('active')} active and {states.count('candidate')} candidate remark(s)")
        print("\n".join(pages))
    else:
        print("docs-review scope: no docs page changed; no docs-reviewer run")
    problems = shape_problems(header, rows)
    for p in problems:
        print(f"::warning::docs-review: {a.rules}: {p}")
    return 1 if problems else 0


def main(argv):
    here = os.path.dirname(os.path.abspath(__file__))
    p = argparse.ArgumentParser(prog="docs_remarks.py", add_help=True)
    sub = p.add_subparsers(dest="cmd", required=True)
    h = sub.add_parser("harvest")
    h.add_argument("--rules", default=os.path.join(here, "remarks.tsv"))
    h.add_argument("--write", action="store_true")
    h.add_argument("--remarks-file")
    h.add_argument("--author")
    h.add_argument("--repo")
    h.add_argument("--limit", type=int, default=50)
    s = sub.add_parser("scope")
    s.add_argument("--rules", default=os.path.join(here, "remarks.tsv"))
    s.add_argument("--base", default="origin/main")
    s.add_argument("--head", default="HEAD")
    a = p.parse_args(argv[1:])
    return harvest(a) if a.cmd == "harvest" else scope(a)


if __name__ == "__main__":
    sys.exit(main(sys.argv))
