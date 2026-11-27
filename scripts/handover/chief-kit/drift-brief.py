#!/usr/bin/env python3
"""drift-brief.py - the actionable rows of the open nightly drift issue (label fork-drift),
and the worker brief that lands them. No model call, no network: it reads the issue body
(stdin or --body-file) and scripts/upstreams/pin-holds.json.

  count --holds <pin-holds.json> [--body-file <file>]
      prints the number of actionable rows: every Needs-update table row, plus every
      HELD row of the body whose hold in pin-holds.json has ended (its `eligible` 72 h
      buffer has cleared, by pin-scan.py's own hold_in_force, with DRIFT_NOW as the clock).
      A hold still in force, or one with no `eligible`, is never counted.

  brief --holds <pin-holds.json> --out <bucket dir> --worktree <abs path> --chief <session>
        --worker <label> --date <YYYY-MM-DD> [--key <ticket key>] [--body-file <file>]
      writes <bucket>/[<key>-]<worker>-drift-4470-<date>.md for exactly those rows, in the
      shape of a hand-written drift brief, and prints its path. With no actionable row it
      writes nothing and exits 1; an existing brief or a failed token mint
      (worker-token.sh) also exits 1.
      With --dependabot-prs <#a,#b> and --prs-file <`gh pr list --json
      number,title,headRefName,body,files`> it writes the combined brief,
      [<key>-]<worker>-dependabot-drift-4470-<date>.md: those PRs and the rows, in one bump PR.
      A PR touching a scripts/ci/core-paths.txt path is left out and named apart, and a row whose
      package a given PR carries is dropped or narrowed. One flag alone, or a number that is
      not in the file, exits 2.

tick.sh runs `count` on a copy of the open issue's body it re-reads at most once an hour
(no open issue counts 0); the chief runs `brief` when the wake names rows.
"""
import argparse
import importlib.util
import json
import os
import re
import secrets
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
PIN_SCAN = os.path.join(HERE, "..", "..", "upstreams", "pin-scan.py")
CORE_PATHS = os.path.join(HERE, "..", "..", "ci", "core-paths.txt")
CI_IMAGE = ".github/ci-image/"
CI_WORKFLOW = ".github/workflows/ci.yml"
ALLOW_LIST = "scripts/ci/release-age-allow.txt"


def read_body(path):
    if path in ("", "-"):
        return sys.stdin.read()
    with open(path, encoding="utf-8", errors="replace") as f:
        return f.read()


def needs_update_rows(body):
    """The data rows of the `### Needs update` table: (name, kind, current, target, action)."""
    rows, in_section, in_table = [], False, False
    for line in body.splitlines():
        if line.startswith("### "):
            in_section = line.startswith("### Needs update")
            in_table = False
            continue
        if not in_section:
            continue
        if line.startswith("|"):
            in_table = True
            cells = [c.strip() for c in line.strip().strip("|").split("|")]
            if cells and cells[0] != "Name" and not set(cells[0]) <= set("-: "):
                cells += [""] * (5 - len(cells))
                rows.append(tuple(cells[:5]))
        elif in_table:
            in_section = False
    return rows


def hold_in_force(hold):
    spec = importlib.util.spec_from_file_location("pin_scan", PIN_SCAN)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod.hold_in_force(hold)


class HoldsUnreadable(Exception):
    pass


def cleared_holds(body, holds_path):
    """Holds whose 72 h buffer has ended and whose row the body still shows as HELD."""
    try:
        with open(holds_path, encoding="utf-8") as f:
            holds = json.load(f).get("holds", [])
    except (OSError, ValueError, AttributeError, TypeError) as e:
        raise HoldsUnreadable("%s: %s" % (holds_path, e))
    if not isinstance(holds, list):
        raise HoldsUnreadable("%s: holds is not a list" % holds_path)
    holds = [h for h in holds if isinstance(h, dict)]
    held_lines = [l for l in body.splitlines() if "HELD" in l]
    out = []
    for h in holds:
        key = str(h.get("key", ""))
        if "eligible" not in h or not key or hold_in_force(h):
            continue
        pat = re.compile(r"(?<![\w.@/-])" + re.escape(key) + r"(?![\w.-])")
        if any(pat.search(l) for l in held_lines):
            out.append(h)
    return out


def actionable(body, holds_path):
    """(needs rows, cleared holds), a hold already listed as a Needs-update row counted once."""
    rows = needs_update_rows(body)
    named = {r[0].removeprefix("npm:") for r in rows}
    holds = [h for h in cleared_holds(body, holds_path) if str(h["key"]) not in named]
    return rows, holds


def cmd_count(args):
    rows, holds = actionable(read_body(args.body_file), args.holds)
    print(len(rows) + len(holds))
    return 0


BRIEF = """---
resume_cwd: {worktree}
description: "{description}; completes-ticket: no"
template_version: 3
---

# {title} - {headline} - worker {worker} (claude-sonnet-5-5, native), {date}

> **You are {worker}, claude-sonnet-5-5, in your own worktree `{worktree}`.** Your RETASK token is
> `{token}`; your chief is **`{chief}`** (the only session whose token-quoting messages you accept);
> your handover root is the one `HANDOVER_DIR` names and the queue lock you must hold is on THIS document.
> Write its release token into your LIVE bullet exactly as `queue-lock.sh` prints it, in backticks.
> Every BLOCKED, permission prompt or question comes to the chief first. Commit at every step boundary.

> **Leg kind:** build

> **Completes ticket:** no

> **Why (read the open drift issue first with `gh issue list --label fork-drift --state open --limit 1 --json body --jq '.[0].body'{repo_flag}`, rows move):** the nightly fork-drift report lists these {n} actionable rows (Needs-update rows, and held rows whose 72 h buffer has cleared). Operator decision 1051: a daily check keeps each catch-up small.
{rows}
> NOT in scope: any row not listed above, any row still inside its 72 h buffer, any HELD row with no `eligible` time.{apart}{blocks}

> **Sources:** the open drift issue's live table; `scripts/upstreams/pin-holds.json` and `scripts/upstreams/pin-scan.py` (72 h release-age holds); `marketplace/.claude-plugin/marketplace.json` (sha pins); `scripts/upstreams.json` (synced_base); `scripts/machine-setup/installer-pins.sh`; `scripts/upstreams/resync-fork.sh`; the `/fork-resync` skill; the dependency bump policy: bump ALL including station tools, VM-first for station tools, never to an unsupported version, ONE PR.

> **Prior art:** the first drift backlog landing, the nightly drift check that holds every kind of pin, and the pin-scan eligible field; source: the Jira search for issue 4470.
> Before you design, run `bash {primary}/scripts/lib/qmd-bounded.sh query -c jira-himmel "fork drift report pin bump station tool VM first"` and `bash {primary}/scripts/lib/qmd-bounded.sh query -c luna "fork drift report pin bump station tool VM first"`, and `bash scripts/graphify/worker-graph.sh explain "pin-scan.py"`, and cite what each returned, or write none found with the query you ran. Send each search as its own tool call, with no other call in the same response: a call sent beside one that a hook rewrites is refused unrun. Run the wrapper as the whole command: no `cd`, pipe, redirect or chained command (it already caps its output). Your Results carry a `graph-qmd: <what each returned and whether used>` bullet.

> **Contract:**
> 1. Acquire the lock with `bash {primary}/scripts/handover/queue-lock.sh acquire <this document, absolute path>`. LIVE; paste `git log -1 --format=%H` and the base-ancestor check. Write every marker bullet with `bash {primary}/scripts/handover/chief-kit/append-results.sh`, never the Edit tool. A bullet never contains the greater-than sign; write `to`.
> 2. Deliverables, per row above: each upstream sha pin in marketplace.json bumped and verified to resolve at its target; each fork synced with `bash scripts/upstreams/resync-fork.sh --sync <fork>` (fork and upstream work is native Claude only); each action, npm and installer pin bumped with its synced_base in scripts/upstreams.json. **Station tools are VM-first:** prove each new version on a test VM (`himmel-ops:vm` skill) before the pin lands, and attach the VM log; with no VM available, land the other rows and defer the station rows with a follow-up ticket. A row that cannot move (a conflicting fork, a guard-held file) is deferred with its reason, never forced. Never upgrade the live station before its VM proof.{deliverables}
> 3. Tests: impacted suites from `bash scripts/cr/impacted-suites.sh`, each run as `bash scripts/quiet-run.sh suite -- bash <test-*.sh>`, with a verdict per suite; a fresh `check-plugin-drift` or pin-scan run on the branch showing each in-scope row current.
> 4. Ship: commit `chore(deps): [{key_text}] {headline}`, standing ship sequence, trailers in the FIRST commit (`Platforms tested: linux`; `Security reviewed: manual - what you checked`). completes-ticket: no. The PR body carries `## Ticket coverage` per row and a `Remaining:` line. Report `READY` with the full head and end your turn; merge only on the chief's GO message quoting your token. Merge forward on conflicts, never rebase.

> **Writes:** marketplace/ scripts/upstreams/ scripts/upstreams.json scripts/machine-setup/ site/package.json site/package-lock.json scripts/hooks/check-oxlint-complexity.sh scripts/hooks/check-oxlint-hardening.sh{writes_extra}

> **Writes note:** marketplace.json pins and forked plugin dirs, pin-holds.json, installer pins, upstreams.json synced_base, site package files for the astro rows only{own_files}; the two oxlint hook files only for an oxlint row's OXLINT_VERSION pin. Stay off scripts/lib/, every other file under scripts/hooks/ and {workflow_ban}

> **Do not:** upgrade a station tool on the live station before its VM proof; run any paid model call; force-push; touch a fork whose branch is HELD.

## Results (newest at the bottom)
"""


def row_line(r):
    name, kind, cur, target, action = r
    return "> - %s (%s): %s to %s - %s" % (name, kind, cur, target, action)


def hold_line(h):
    return "> - %s (%s, held row, 72 h buffer cleared at %s): %s to %s - %s" % (
        h["key"], h.get("eco", "?"), h["eligible"], h.get("current", "?"),
        h.get("latest_reviewed", "?"), " ".join(str(h.get("reason", "")).split()))


# git-env-ok: every GIT_* name is dropped from the environment the child git gets
CHILD_ENV = {k: v for k, v in os.environ.items() if not k.startswith("GIT_")}


def git_out(*args):
    try:
        return subprocess.run(["git", "-C", HERE, *args], capture_output=True, text=True,
                              timeout=10, env=CHILD_ENV).stdout.strip()
    except (OSError, subprocess.SubprocessError):
        return ""


def origin_slug():
    """owner/name of the origin remote, or empty when it cannot be read."""
    m = re.search(r"[:/]([^/:]+/[^/]+?)(?:\.git)?$", git_out("remote", "get-url", "origin"))
    return m.group(1) if m else ""


def primary_checkout():
    """The primary checkout of the repo this script lives in (a worktree's git common dir parent)."""
    out = git_out("rev-parse", "--path-format=absolute", "--git-common-dir")
    return os.path.dirname(out) if out.endswith("/.git") else os.path.realpath(os.path.join(HERE, "..", "..", ".."))


def mint_token(doc, worker):
    """Generation 1 of the worker's RETASK token from the token record, or None on failure.
    The child reads the ambient HANDOVER_DIR, as the chief's readers do."""
    prefix = "D-%s" % worker
    r = subprocess.run(["bash", os.path.join(HERE, "worker-token.sh"), "mint", doc, prefix],
                       capture_output=True, text=True, timeout=120)
    if r.returncode == 3:
        print("drift-brief: token not recorded (worker-token.sh refused)", file=sys.stderr)
        return "%s-%s" % (prefix, secrets.token_hex(4))
    if r.returncode != 0 or not r.stdout.strip():
        print("drift-brief: worker-token.sh mint failed (rc %d): %s" % (r.returncode, " ".join(r.stderr.split())),
              file=sys.stderr)
        return None
    return r.stdout.strip()


DELIVERABLES = """
> - Each Dependabot PR's bump lands. A hashed requirements file gets its hashes regenerated, not left as Dependabot wrote them.
> - A bump under `.github/ci-image/` owes the CI image digest repin in `.github/workflows/ci.yml`, as a second PR on the same ticket after the first merges and the image rebuilds.
> - A security PR whose lockfile entry is younger than 3 days gets a `scripts/ci/release-age-allow.txt` line naming the advisory; remove the line once the release is 3 days old.
> - Close every PR in the Dependabot PRs block before WRAPPED. A landed one: `gh pr close <n> --comment "Superseded by #<merged pr>"`. A deferred one (red, held or unsupported): `gh pr close <n> --comment "Deferred: <reason>, tracked in <KEY>"`, with a `deferred → <KEY>` coverage line. None of them stays open after the leg.
> - A PR closed unmerged tells Dependabot not to raise that version again, so the deferral ticket is its only record: file it at High or above, naming the PR and its advisory if it has one."""


class PrNotOpen(Exception):
    pass


def pr_numbers(text):
    items = [i.strip().lstrip("#") for i in text.split(",") if i.strip()]
    if not all(i.isdecimal() for i in items):
        return None
    return list(dict.fromkeys(int(i) for i in items))


def core_hit(files):
    with open(CORE_PATHS, encoding="utf-8") as f:
        pats = [re.compile(l.strip()) for l in f if l.strip() and not l.startswith("#")]
    return next((p for p in files if any(pat.search(p) for pat in pats)), None)


def split_by_carrier(name, dirs, prs):
    pkg = re.escape(re.sub(r"^(npm|pypi|gh):", "", name))
    by = {}
    for pr in prs:
        if not (re.search(r"\bbump `?%s`? from " % pkg, pr["title"], re.I)
                or re.search(r"\bupdates `?%s`? from " % pkg, pr.get("body") or "", re.I)):
            continue
        here = {os.path.dirname(f) for f in pr["paths"]}
        got = [d for d in dirs if d in here]
        if got:
            by[pr["number"]] = got
    taken = {d for got in by.values() for d in got}
    return [d for d in dirs if d not in taken], by


def carry_note(name, left, by):
    if not left:
        return "%s carried by %s" % (name, ", ".join("#%d" % n for n in by))
    return "; ".join("#%d carries %s for %s" % (n, ", ".join(got), name) for n, got in by.items())


def drop_carried(body, rows, holds, prs):
    kept_rows, kept_holds, notes = [], [], []
    for r in rows:
        m = re.match(r"bump (.+?) (to \S.*)$", r[4])
        if m:
            left, by = split_by_carrier(r[0], m.group(1).split(", "), prs)
            if by:
                notes.append(carry_note(r[0], left, by))
                if not left:
                    continue
                r = r[:4] + ("bump %s %s" % (", ".join(left), m.group(2)),)
        kept_rows.append(r)
    for h in holds:
        key = str(h["key"])
        dirs = [d for m in re.finditer(r"(?m)^\s*(?:[a-z]+:)?%s \S+ \(([^)]*)\): HELD" % re.escape(key), body)
                for d in m.group(1).split(", ")]
        left, by = split_by_carrier(key, dirs, prs)
        if by:
            notes.append(carry_note(key, left, by))
            if not left:
                continue
        kept_holds.append(h)
    return kept_rows, kept_holds, notes


def given_prs(numbers, prs_path):
    with open(prs_path, encoding="utf-8") as f:
        by_number = {p["number"]: p for p in json.load(f)}
    for n in numbers:
        if n not in by_number:
            raise PrNotOpen(n)
    return [dict(by_number[n], paths=[f["path"] for f in by_number[n]["files"]]) for n in numbers]


def cmd_brief(args):
    combined = args.dependabot_prs is not None
    if combined != (args.prs_file is not None):
        args.parser.error("--dependabot-prs and --prs-file are given together")
    body = read_body(args.body_file)
    rows, holds = actionable(body, args.holds)
    prs, notes = [], []
    if combined:
        numbers = pr_numbers(args.dependabot_prs)
        if numbers is None:
            args.parser.error("--dependabot-prs takes PR numbers, as #1,#2")
        try:
            given = given_prs(numbers, args.prs_file)
            for pr in given:
                hit = core_hit(pr["paths"])
                if hit:
                    print("drift-brief: PR #%d touches core path %s: route it apart" % (pr["number"], hit), file=sys.stderr)
                    notes.append("core-path PR #%d (%s), left open: route it apart" % (pr["number"], hit))
                else:
                    prs.append(pr)
            rows, holds, carry = drop_carried(body, rows, holds, given)
            notes += carry
        except PrNotOpen as e:
            print("drift-brief: PR #%d is not open" % e.args[0], file=sys.stderr)
            return 2
        except (OSError, ValueError, TypeError, KeyError) as e:
            print("drift-brief: cannot read the PR file or core-paths.txt: %s" % e, file=sys.stderr)
            return 2
    n = len(rows) + len(holds)
    if n == 0 and not prs:
        print("drift-brief: no actionable row", file=sys.stderr)
        return 1
    station = [r for r in rows if combined and r[4].startswith("station tool:")]
    lines = [row_line(r) for r in rows if r not in station] + [hold_line(h) for h in holds]
    extra = dict(
        headline="the actionable 4470 drift rows are current",
        description="Land the %d actionable fork-drift rows of the open drift issue (%s) so the nightly drift report clears" % (n, args.date),
        apart="", blocks="", deliverables="", writes_extra="", own_files="", workflow_ban=".github/workflows/.")
    if combined:
        lines = lines or ["> - no drift row listed apart from the blocks below"]
        paths = list(dict.fromkeys(p for pr in prs for p in pr["paths"]))
        if any(p.startswith(CI_IMAGE) for p in paths) and CI_WORKFLOW not in paths:
            paths.append(CI_WORKFLOW)
        paths.append(ALLOW_LIST)
        blocks = ""
        if station:
            blocks += "\n\n> **Station tools (VM-first, listed apart):**\n" + "\n".join(row_line(r) for r in station)
        if prs:
            blocks += "\n\n> **Dependabot PRs:**\n" + "\n".join(
                "> - #%d %s (%s)" % (pr["number"], " ".join(pr["title"].split()), pr["headRefName"]) for pr in prs)
        extra.update(
            headline="the open Dependabot bumps and the actionable 4470 drift rows land together",
            description="Land the %d open Dependabot bumps and the %d actionable fork-drift rows of the open drift issue (%s) in one bump PR" % (len(prs), n, args.date),
            apart=" Apart: %s." % "; ".join(notes) if notes else "",
            blocks=blocks, deliverables=DELIVERABLES, writes_extra="".join(" " + p for p in paths),
            own_files=", or as a Dependabot PR's own files",
            workflow_ban="every `.github/workflows/` file except `ci.yml` and the Dependabot PRs' own files. "
            "Every `.github/` path and `%s` is a CI trust path, so the READY needs a trust-reviewed GO; the trust paths of this brief: %s." % (
                ALLOW_LIST, ", ".join(p for p in paths if p.startswith(".github/") or p == ALLOW_LIST)))
    stem = "%s%s-%sdrift-4470-%s.md" % (args.key + "-" if args.key else "", args.worker,
                                        "dependabot-" if combined else "", args.date)
    os.makedirs(args.out, exist_ok=True)
    path = os.path.join(args.out, stem)
    exists = "drift-brief: brief already exists: %s" % path
    if os.path.exists(path):
        print(exists, file=sys.stderr)
        return 1
    token = mint_token(path, args.worker)
    if token is None:
        return 1
    text = BRIEF.format(
        worktree=args.worktree, n=n, date=args.date, worker=args.worker, chief=args.chief,
        token=token,
        title=args.key if args.key else "Drift 4470",
        key_text=args.key if args.key else "the ticket key the chief names",
        rows="\n".join(lines), primary=primary_checkout(),
        repo_flag=(" -R " + origin_slug()) if origin_slug() else "", **extra)
    try:
        with open(path, "x", encoding="utf-8") as f:
            f.write(text)
    except FileExistsError:
        print(exists, file=sys.stderr)
        return 1
    print(path)
    return 0


def main():
    ap = argparse.ArgumentParser(prog="drift-brief.py")
    sub = ap.add_subparsers(dest="cmd", required=True)
    c = sub.add_parser("count")
    c.add_argument("--holds", required=True)
    c.add_argument("--body-file", default="-")
    c.set_defaults(fn=cmd_count)
    b = sub.add_parser("brief")
    b.add_argument("--holds", required=True)
    b.add_argument("--body-file", default="-")
    b.add_argument("--out", required=True)
    b.add_argument("--worktree", required=True)
    b.add_argument("--chief", required=True)
    b.add_argument("--worker", required=True)
    b.add_argument("--date", required=True)
    b.add_argument("--key", default="")
    b.add_argument("--dependabot-prs")
    b.add_argument("--prs-file")
    b.set_defaults(fn=cmd_brief, parser=b)
    args = ap.parse_args()
    try:
        return args.fn(args)
    except HoldsUnreadable as e:
        print("drift-brief: cannot read the holds file: %s" % e, file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
