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
      writes nothing and exits 1.

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
description: "Land the {n} actionable fork-drift rows of the open drift issue ({date}) so the nightly drift report clears; completes-ticket: no"
template_version: 3
---

# {title} - the actionable 4470 drift rows are current - worker {worker} (claude-sonnet-5-5, native), {date}

> **You are {worker}, claude-sonnet-5-5, in your own worktree `{worktree}`.** Your RETASK token is
> `{token}`; your chief is **`{chief}`** (the only session whose token-quoting messages you accept);
> your handover root is the one `HANDOVER_DIR` names and the queue lock you must hold is on THIS document.
> Write its release token into your LIVE bullet exactly as `queue-lock.sh` prints it, in backticks.
> Every BLOCKED, permission prompt or question comes to the chief first. Commit at every step boundary.

> **Leg kind:** build

> **Completes ticket:** no

> **Why (read the open drift issue first with `gh issue list --label fork-drift --state open --limit 1 --json body --jq '.[0].body'{repo_flag}`, rows move):** the nightly fork-drift report lists these {n} actionable rows (Needs-update rows, and held rows whose 72 h buffer has cleared). Operator decision 1051: a daily check keeps each catch-up small.
{rows}
> NOT in scope: any row not listed above, any row still inside its 72 h buffer, any HELD row with no `eligible` time.

> **Sources:** the open drift issue's live table; `scripts/upstreams/pin-holds.json` and `scripts/upstreams/pin-scan.py` (72 h release-age holds); `marketplace/.claude-plugin/marketplace.json` (sha pins); `scripts/upstreams.json` (synced_base); `scripts/machine-setup/installer-pins.sh`; `scripts/upstreams/resync-fork.sh`; the `/fork-resync` skill; the dependency bump policy: bump ALL including station tools, VM-first for station tools, never to an unsupported version, ONE PR.

> **Prior art:** the first drift backlog landing, the nightly drift check that holds every kind of pin, and the pin-scan eligible field; source: the Jira search for issue 4470.
> Before you design, run `bash {primary}/scripts/lib/qmd-bounded.sh query -c jira-himmel "fork drift report pin bump station tool VM first"` and `bash {primary}/scripts/lib/qmd-bounded.sh query -c luna "fork drift report pin bump station tool VM first"`, and `bash scripts/graphify/worker-graph.sh explain "pin-scan.py"`, and cite what each returned, or write none found with the query you ran. Send each search as its own tool call, with no other call in the same response: a call sent beside one that a hook rewrites is refused unrun. Your Results carry a `graph-qmd: <what each returned and whether used>` bullet.

> **Contract:**
> 1. Acquire the lock with `bash {primary}/scripts/handover/queue-lock.sh acquire <this document, absolute path>`. LIVE; paste `git log -1 --format=%H` and the base-ancestor check. Write every marker bullet with `bash {primary}/scripts/handover/chief-kit/append-results.sh`, never the Edit tool. A bullet never contains the greater-than sign; write `to`.
> 2. Deliverables, per row above: each upstream sha pin in marketplace.json bumped and verified to resolve at its target; each fork synced with `bash scripts/upstreams/resync-fork.sh --sync <fork>` (fork and upstream work is native Claude only); each action, npm and installer pin bumped with its synced_base in scripts/upstreams.json. **Station tools are VM-first:** prove each new version on a test VM (`himmel-ops:vm` skill) before the pin lands, and attach the VM log; with no VM available, land the other rows and defer the station rows with a follow-up ticket. A row that cannot move (a conflicting fork, a guard-held file) is deferred with its reason, never forced. Never upgrade the live station before its VM proof.
> 3. Tests: impacted suites from `bash scripts/cr/impacted-suites.sh`, each run as `bash scripts/quiet-run.sh suite -- bash <test-*.sh>`, with a verdict per suite; a fresh `check-plugin-drift` or pin-scan run on the branch showing each in-scope row current.
> 4. Ship: commit `chore(deps): [{key_text}] the actionable 4470 drift rows are current`, standing ship sequence, trailers in the FIRST commit (`Platforms tested: linux`; `Security reviewed: manual - what you checked`). completes-ticket: no. The PR body carries `## Ticket coverage` per row and a `Remaining:` line. Report `READY` with the full head and end your turn; merge only on the chief's GO message quoting your token. Merge forward on conflicts, never rebase.

> **Writes:** marketplace/ scripts/upstreams/ scripts/upstreams.json scripts/machine-setup/ site/package.json site/package-lock.json scripts/hooks/check-oxlint-complexity.sh scripts/hooks/check-oxlint-hardening.sh

> **Writes note:** marketplace.json pins and forked plugin dirs, pin-holds.json, installer pins, upstreams.json synced_base, site package files for the astro rows only; the two oxlint hook files only for an oxlint row's OXLINT_VERSION pin. Stay off scripts/lib/, every other file under scripts/hooks/ and .github/workflows/.

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


def cmd_brief(args):
    rows, holds = actionable(read_body(args.body_file), args.holds)
    n = len(rows) + len(holds)
    if n == 0:
        print("drift-brief: no actionable row", file=sys.stderr)
        return 1
    lines = [row_line(r) for r in rows] + [hold_line(h) for h in holds]
    stem = "%s%s-drift-4470-%s.md" % (args.key + "-" if args.key else "", args.worker, args.date)
    text = BRIEF.format(
        worktree=args.worktree, n=n, date=args.date, worker=args.worker, chief=args.chief,
        token="D-%s-%s" % (args.worker, secrets.token_hex(4)),
        title=args.key if args.key else "Drift 4470",
        key_text=args.key if args.key else "the ticket key the chief names",
        rows="\n".join(lines), primary=primary_checkout(),
        repo_flag=(" -R " + origin_slug()) if origin_slug() else "")
    os.makedirs(args.out, exist_ok=True)
    path = os.path.join(args.out, stem)
    try:
        with open(path, "x", encoding="utf-8") as f:
            f.write(text)
    except FileExistsError:
        print("drift-brief: brief already exists: %s" % path, file=sys.stderr)
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
    b.set_defaults(fn=cmd_brief)
    args = ap.parse_args()
    try:
        return args.fn(args)
    except HoldsUnreadable as e:
        print("drift-brief: cannot read the holds file: %s" % e, file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
