#!/usr/bin/env python3
"""docs_review.py: review a docs diff against the operator's own remarks.

  check   [--rules F] (--pr N | --range A..B | --diff FILE|-) [--whole-file]
  learn   [--rules F] (--pattern REGEX | --judgement) --rule TEXT --source TEXT --quote TEXT [--date D]
  confirm [--rules F] ID --by TEXT
  list    [--rules F]

check prints `path:line: ID rule | matched: text` per finding, one CHECK line
per judgement rule per changed page, and exits 1 when there is a finding.
learn appends a candidate rule; confirm makes it active. Usage errors exit 2.
"""
import argparse
import datetime
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULT_RULES = os.path.join(HERE, "rules.tsv")
FIELDS = ["id", "state", "kind", "pattern", "rule", "date", "source", "quote"]
EXEMPT = ("docs/archive/", "docs/release/")
STRUCTURE = re.compile(r"^\s*([#|>*+<]|-|\d+[.)]\s|```|~~~)")
FENCE = re.compile(r"^(`{3,}|~{3,})")
HUNK = re.compile(r"^@@ -\d+(?:,(\d+))? \+(\d+)(?:,(\d+))? @@")


def die(msg):
    print(f"docs-review: {msg}", file=sys.stderr)
    sys.exit(2)


def load_rules(path):
    try:
        with open(path, encoding="utf-8") as fh:
            lines = fh.read().splitlines()
    except OSError as exc:
        die(f"cannot read rules file {path}: {exc}")
    if not lines or lines[0] != "\t".join(FIELDS):
        die(f"{path}:1: want the header {' '.join(FIELDS)!r}, tab-separated")
    rules = []
    for n, line in enumerate(lines[1:], start=2):
        if not line.strip():
            continue
        cols = line.split("\t")
        if len(cols) != len(FIELDS):
            die(f"{path}:{n}: want {len(FIELDS)} tab-separated columns, got {len(cols)}")
        rule = dict(zip(FIELDS, cols))
        if rule["state"] not in ("active", "candidate"):
            print(f"docs-review: {path}:{n}: {rule['id']} has unknown state {rule['state']!r}, skipped",
                  file=sys.stderr)
        if rule["kind"] == "pattern":
            try:
                re.compile(rule["pattern"])
            except re.error as exc:
                die(f"{path}:{n}: {rule['id']} has a broken pattern: {exc}")
        elif rule["kind"] == "prose" and not re.fullmatch(r"[1-9][0-9]*", rule["pattern"]):
            die(f"{path}:{n}: {rule['id']} prose threshold must be a positive number, got {rule['pattern']!r}")
        rules.append(rule)
    return rules


def is_docs_page(path):
    if path.startswith(EXEMPT):
        return False
    return path == "README.md" or (path.startswith("docs/") and path.endswith((".md", ".html")))


def run(cmd, timeout=120):
    try:
        return subprocess.run(cmd, capture_output=True, text=True, encoding="utf-8",
                              errors="replace", timeout=timeout)
    except (OSError, subprocess.TimeoutExpired) as exc:
        die(f"{cmd[0]} failed: {exc}")


def git(*args):
    out = run(["git", *args])
    if out.returncode != 0:
        die(f"git {' '.join(args)} failed: {out.stderr.strip()}")
    return out.stdout


def unquote(path):
    """Git quotes a path holding non-ASCII or special characters C-style:
    `"b/docs/\\303\\251.md"`."""
    path = path.strip()
    if len(path) > 1 and path.startswith('"') and path.endswith('"'):
        raw = path[1:-1].encode("utf-8").decode("unicode_escape")
        path = raw.encode("latin-1").decode("utf-8", "replace")
    return path


def diff_path(target):
    """The new-side path of a `+++` header, or None for /dev/null."""
    target = unquote(target)
    if target == "/dev/null":
        return None
    if not target.startswith("b/"):
        die(f"unsupported diff header '+++ {target}': want a b/ prefix (no --no-prefix)")
    return target[2:]


def parse_diff(text):
    """Return {path: [(line_no, text), ...]} of the added lines.

    A hunk's line counts say where it ends, so an added line that itself
    starts with `++ ` is content, not a file header. A pure rename or copy
    has no `+++` header; its `rename to` / `copy to` line names the page.
    """
    pages, path, line_no, old_left, new_left = {}, None, 0, 0, 0
    for raw in text.split("\n"):
        if old_left > 0 or new_left > 0:
            if raw.startswith("+"):
                if path is not None:
                    pages[path].append((line_no, raw[1:]))
                line_no += 1
                new_left -= 1
            elif raw.startswith("-"):
                old_left -= 1
            elif not raw.startswith("\\"):
                line_no += 1
                old_left -= 1
                new_left -= 1
            continue
        if raw.startswith("+++ "):
            path = diff_path(raw[4:])
            if path is not None:
                pages.setdefault(path, [])
            continue
        if raw.startswith(("rename to ", "copy to ")):
            pages.setdefault(unquote(raw.split(" ", 2)[2]), [])
        hunk = HUNK.match(raw)
        if hunk:
            old_left = int(hunk.group(1) or 1)
            line_no = int(hunk.group(2))
            new_left = int(hunk.group(3) or 1)
    return pages


def prose_runs(lines, threshold):
    """Yield (first_line, last_line, count) for runs of >= threshold prose lines.

    Blank lines do not break a run; a heading, list, table, quote, HTML or
    code fence does, and fenced code is never prose. Line numbers must be
    contiguous for two lines to share a run.
    """
    run, fence, prev = [], "", None
    for line_no, text in lines + [(None, "#")]:
        if line_no is not None and prev is not None and line_no != prev + 1:
            if len(run) >= threshold:
                yield run[0], run[-1], len(run)
            run = []
        prev = line_no
        stripped = text.strip()
        marker = FENCE.match(stripped)
        in_fence = bool(fence)
        if marker and not fence:
            fence = marker.group(1)
        elif marker and stripped == marker.group(1) and marker.group(1).startswith(fence):
            fence = ""
        if not stripped:
            continue
        if in_fence or fence or STRUCTURE.match(text) or line_no is None:
            if len(run) >= threshold:
                yield run[0], run[-1], len(run)
            run = []
            continue
        run.append(line_no)


def review(pages, rules, bodies):
    """bodies holds each page at the head when the head is known; the prose
    rule reads it so a fence opened above a hunk is seen, and reports only
    runs that hold an added line. A bare --diff has no head: added lines only."""
    findings, checks = [], []
    active = [r for r in rules if r["state"] == "active"]
    for path in sorted(pages):
        if not is_docs_page(path):
            continue
        lines = pages[path]
        for rule in active:
            if rule["kind"] == "pattern":
                rx = re.compile(rule["pattern"])
                for line_no, text in lines:
                    m = rx.search(text)
                    if m:
                        findings.append((path, line_no, rule, f"matched: {m.group(0).strip()}"))
            elif rule["kind"] == "prose" and path.endswith(".md"):
                added = [n for n, _ in lines]
                for first, last, count in prose_runs(bodies.get(path, lines), int(rule["pattern"])):
                    if not any(first <= n <= last for n in added):
                        continue
                    findings.append((path, first, rule, f"{count} prose lines ({first}-{last}) with no list, table or heading"))
            elif rule["kind"] == "judgement":
                checks.append((path, rule))
    findings.sort(key=lambda f: (f[0], f[1], f[2]["id"]))
    return findings, checks


def pr_head(pr):
    head = run(["gh", "pr", "view", str(pr), "--json", "headRefOid", "--jq", ".headRefOid"]).stdout.strip()
    if not head:
        die(f"cannot read the head of PR {pr}")
    return head


def one_line(value):
    """No tab and no line break of any kind load_rules would split on."""
    return "\t" not in value and value.splitlines() in ([], [value])


def cmd_check(args):
    rules = load_rules(args.rules)
    head = None
    if args.pr:
        head = pr_head(args.pr)
        diff = run(["gh", "pr", "diff", str(args.pr)])
        if diff.returncode != 0:
            die(f"gh pr diff {args.pr} failed: {diff.stderr.strip()}")
        text = diff.stdout
        if pr_head(args.pr) != head:
            die(f"PR {args.pr} moved while its diff was read; run it again")
        if run(["git", "cat-file", "-e", head]).returncode != 0:
            git("fetch", "-q", "origin", f"pull/{args.pr}/head")
    elif args.range:
        if args.range.startswith("-"):
            die(f"--range {args.range!r} starts with a dash; want A..B")
        text = git("diff", "--no-color", "--no-ext-diff", "--no-relative",
                   "--src-prefix=a/", "--dst-prefix=b/", "--end-of-options", args.range)
        head = args.range.split("..")[-1].lstrip(".") or "HEAD"
    else:
        try:
            text = sys.stdin.read() if args.diff == "-" else open(args.diff, encoding="utf-8").read()
        except OSError as exc:
            die(f"cannot read diff {args.diff}: {exc}")
        if args.whole_file:
            die("--whole-file needs --pr or --range")
    if not re.search(r"^(diff --git |\+\+\+ )", text, re.M):
        die("no file header in the input; is it a unified diff?")
    pages = parse_diff(text)
    bodies = {}
    if head:
        for path in [p for p in pages if is_docs_page(p)]:
            bodies[path] = list(enumerate(git("show", "--end-of-options", f"{head}:{path}").split("\n"), start=1))
    if args.whole_file:
        pages.update(bodies)
    findings, checks = review(pages, rules, bodies)
    for path, line_no, rule, detail in findings:
        print(f"{path}:{line_no}: {rule['id']} {rule['rule']} | {detail}")
    for path, rule in checks:
        print(f"CHECK {path}: {rule['id']} {rule['rule']}")
    for rule in rules:
        if rule["state"] == "candidate":
            print(f"CANDIDATE {rule['id']} awaits one confirmation: {rule['rule']}")
    reviewed = sorted({p for p in pages if is_docs_page(p)})
    print(f"docs-review: {len(findings)} finding(s) in {len({f[0] for f in findings})} page(s), "
          f"{len(reviewed)} page(s) reviewed, {len(checks)} judgement check(s)")
    return 1 if findings else 0


def write_rules(path, rules):
    with open(path, "w", encoding="utf-8") as fh:
        fh.write("\t".join(FIELDS) + "\n")
        for rule in rules:
            fh.write("\t".join(rule[f] for f in FIELDS) + "\n")


def cmd_learn(args):
    rules = load_rules(args.rules)
    kind = "judgement" if args.judgement else "pattern"
    if kind == "pattern":
        try:
            rx = re.compile(args.pattern)
        except re.error as exc:
            die(f"broken pattern {args.pattern!r}: {exc}")
        if rx.search(""):
            die("the pattern matches an empty line and would flag every line")
    values = [args.pattern or "", args.rule, args.date, args.source, args.quote]
    if not all(one_line(v) for v in values):
        die("a field holds a tab or a line break")
    if not all(v.strip() for v in [args.rule, args.source, args.quote]):
        die("--rule, --source and --quote must not be empty")
    nums = [int(r["id"][1:]) for r in rules if re.fullmatch(r"R\d+", r["id"])]
    new_id = f"R{max(nums, default=0) + 1:02d}"
    rules.append(dict(zip(FIELDS, [new_id, "candidate", kind] + values)))
    write_rules(args.rules, rules)
    print(f"{new_id} candidate: {args.rule}")
    return 0


def cmd_confirm(args):
    rules = load_rules(args.rules)
    match = [r for r in rules if r["id"] == args.id]
    if not match:
        die(f"no rule {args.id}")
    if match[0]["state"] != "candidate":
        die(f"{args.id} is {match[0]['state']}, not a candidate")
    if not one_line(args.by) or not args.by.strip():
        die("--by must be one non-empty line")
    match[0]["state"] = "active"
    match[0]["source"] += f"; confirmed {datetime.date.today().isoformat()} by {args.by}"
    write_rules(args.rules, rules)
    print(f"{args.id} active: {match[0]['rule']}")
    return 0


def cmd_list(args):
    for rule in load_rules(args.rules):
        print(f"{rule['id']}\t{rule['state']}\t{rule['kind']}\t{rule['rule']}")
    return 0


def main():
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = p.add_subparsers(dest="cmd", required=True)
    c = sub.add_parser("check")
    src = c.add_mutually_exclusive_group(required=True)
    src.add_argument("--pr", type=int)
    src.add_argument("--range")
    src.add_argument("--diff")
    c.add_argument("--whole-file", action="store_true")
    lr = sub.add_parser("learn")
    kind = lr.add_mutually_exclusive_group(required=True)
    kind.add_argument("--pattern")
    kind.add_argument("--judgement", action="store_true")
    lr.add_argument("--rule", required=True)
    lr.add_argument("--source", required=True)
    lr.add_argument("--quote", required=True)
    lr.add_argument("--date", default=datetime.date.today().isoformat())
    cf = sub.add_parser("confirm")
    cf.add_argument("id")
    cf.add_argument("--by", required=True)
    ls = sub.add_parser("list")
    for sp in (c, lr, cf, ls):
        sp.add_argument("--rules", default=os.environ.get("DOCS_REVIEW_RULES", DEFAULT_RULES))
    args = p.parse_args()
    return {"check": cmd_check, "learn": cmd_learn, "confirm": cmd_confirm, "list": cmd_list}[args.cmd](args)


if __name__ == "__main__":
    sys.exit(main())
