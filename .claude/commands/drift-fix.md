---
description: Bump drifted upstream pins via a PR.
argument-hint: [--dry-run]
---

The repair half of the fork-drift loop. The nightly `fork-drift` GitHub Action
only DETECTS drift and refreshes one tracking issue; closing that
loop was always a hand-driven ticket, and those stall — one to "bump
graphify 0.9.22 -> 0.9.23" sat in To Do while the pin advanced past it twice in
unrelated PRs. This runbook is what actually closes it.

Normally fired unattended by `scripts/upstreams/drift-fix-cadence.sh` (daily,
05:00 local). Safe to run by hand — the steps are identical.

**The rule that holds for every step below.**

**Never hand-edit a pin.** `scripts/upstreams/apply-drift-bump.sh` owns the
edit. It moves the in-repo pin literal and `synced_base` together, refuses a
downgrade, and restores both files byte-identical if anything is off. Editing
either spot yourself defeats all of that.

`--dry-run` = run steps 1–4 and report; change nothing.

---

## 1. Ground the run

Work from the PRIMARY checkout (`git rev-parse --git-common-dir`'s parent), not
a worktree. Then:

```bash
git fetch origin
git status --porcelain
```

A dirty tree means someone is mid-work. **Abort** with that fact reported —
never stash, reset, or commit someone else's changes.

The `main == origin/main` confirmation happens in step 1A, **after** the catch-up
pull, not here. Asserting it before pulling would abort every night
the machine simply had not pulled yet — the ordinary case, and the exact case
step 1A exists to fix.

## 1A. Catch this machine up first

```bash
bash scripts/himmel-update.sh
```

**Why here, and why before reading drift.** There are two separate kinds of
staleness and only one of them is a `BEHIND` row:

- **repo pin vs upstream** — what the guard in step 2 reads, repaired by a PR.
- **this machine vs the repo** — invisible to the guard. For a `tag_release` /
  `mode: base` entry the guard reads `synced_base`, a literal in
  `scripts/upstreams.json` that `apply-drift-bump.sh` moves *together with* the
  in-repo pin. So the row flips to `CURRENT` the instant a bump merges, while
  the binary installed on this machine is still the old one. Last night's own
  merged bump is exactly this case.

`himmel-update.sh` is the engine for that second kind (graphify, cli-proxy-api,
qmd, the marketplaces, hermes, the jira dist). Running it first means step 2
reads drift against a machine that is actually current — and its own
`--only <item>` flag is how you re-run a single step that did not land.

**Its outcome is ADVISORY to this runbook: never abort the drift worker on a
non-zero rc.** A failed luna-template upgrade must not stop a graphify pin bump,
and a `skipped` item is not a failure at all. It produces no repo diff and
therefore never opens a PR.

The one failure that WOULD matter is chain item 1, the `git pull` itself — every
argument for running this first assumes the machine actually caught up. So after
it finishes, make the confirmation step 1 deferred:

```bash
git rev-parse main origin/main
```

**They must match.** If they do not, the catch-up pull did not land (a diverged
branch, a non-ff, a dirty tree it refused) — report that and abort the run.
Everything downstream would be reasoning about a checkout that is not what
`origin/main` says it is.

`--dry-run`: use `bash scripts/himmel-update.sh --check` instead — it reports
and mutates nothing. The `main == origin/main` confirmation then only tells you
whether the machine is current, so report it rather than aborting on it.

## 2. Read the drift

```bash
bash scripts/check-plugin-drift.sh
```

Exit codes: `0` all current, `2` drift, `3` incomplete. Anything other than 2
means there is nothing to repair — say so and stop (an exit 3 proves nothing, so
never treat it as "clean").

From the output, collect every `BEHIND` line whose name is a **`tag_release` /
`mode: base`** entry in `scripts/upstreams.json`. Those are the only ones that
carry an in-repo pin this runbook can move. A `BEHIND` line reads:

```text
  graphify: BEHIND   (Graphify-Labs/graphify latest tag v0.9.28; installed 0.9.25 — upgrade)  [A]
```

→ name `graphify`, target version `v0.9.28`.

`npm:<pkg>` / `gh:<owner/repo>` BEHIND lines (the "pinned tools and packages"
section) are **not** registry entries: they are dependency bumps
(lockfile, hook rev, action, `OXLINT_VERSION=`) for a normal `chore(deps)` PR,
not for this runbook. An `OXLINT_VERSION=` bump also bumps `oxlint` in
`scripts/lint/landmines/package.json` and its `bun.lock` in the same PR, or the
test-honesty suite's pin-equality case goes red. Skip them here; a bump held
back on purpose is recorded in `scripts/upstreams/pin-holds.json` and reads
`HELD`, not `BEHIND`.

Do not read "installed 0.9.25" as a probe of the installed binary. That message
is one shared template (`"$repo latest tag $latest; installed $local_ver"`)
printed for EVERY `tag_release` BEHIND case. For `mode: probe` (rtk)
`$local_ver` really is a live binary read; for `mode: base`
(graphify, cli-proxy-api) it is the `synced_base` literal from the registry. The
installed artifact on this machine is step 1A's business, never the guard's.

Also collect every `BEHIND` line whose name is a **`tag_release` / `mode: probe`**
entry (rtk). Those have no repo pin at all — their drift is an
out-of-date binary on THIS machine, repaired in step A below. This is the half a
CI job could never do, and the reason the cadence runs locally.

Also collect every `BEHIND` **`mkt:<name>`** row — an installed marketplace that
has moved upstream. Repaired in step 2B. This runbook used to ignore these, and
they went unrepaired for as long as the registry has had them (issue #518).

Also collect every `BEHIND` row of the `== fork branches ==` section (its
`action=` reads `fork-rebase` or a `gh repo sync` line) and every `BEHIND`
registry entry that declares a `fork` block (qmd, graphify). Those are our forks,
brought current in step 2C of this same run.

**Ignore** the rest, and say which you ignored and why:
- `mode: checkout` entries (hermes-agent) — a checkout to pull, not a version
  bump; step 1A's hermes step is what moves it.
- `commit_head` / vendored forks — a re-sync + delta audit, not a version bump.

## 2A. Upgrade the installed vendor CLIs

Do this BEFORE the branch work — it produces no repo diff, so it must not
influence whether a PR gets opened. Per probe entry collected above:

```bash
bash scripts/upstreams/apply-tool-upgrade.sh <name> <target-version> --unattended
```

With `--dry-run`, add `--dry-run` to each call — it must not touch the
operator's installed CLIs.

**Always pass the target version** from the guard's BEHIND line. Without it the
script cannot tell "already the newest release" from "the upgrade silently did
nothing" — both look like an rc-0 command and an unchanged version — so it
reports rc 1 with the claim marked unverified instead of guessing. With the
target it knows, and not reaching it is a hard rc 4.

**Always pass `--unattended`.** It is the policy gate: it refuses any entry not
marked `upgrade.unattended: true` in the registry. Dropping the flag would
silently overrule an operator decision, in either direction.

Read the flag from the registry — do not assume which entries are gated. As of
2026-07-28 `rtk` is `unattended: true`: the operator explicitly approved that
day, overriding its Tier B default. rtk's entry note records why the reservation existed (BEHIND
is normally its intended steady state; its known git-diff rewrite bug is unfixed upstream) and what
makes unattended acceptable anyway (`upgrade-rtk.sh` backs up, smoke-tests, and
rolls back; `rtk-hook-guard.sh` is fail-OPEN so a broken rtk stops rewriting
Bash rather than blocking it). Flipping that field back to `false` is the
supported way to return rtk to operator-triggered — expect an rc 3 SKIP then.

| rc | meaning | do |
|----|---------|-----|
| 0 | upgraded — prints `UPGRADE <name> <old> -> <new>` | continue |
| 1 | already current | continue |
| 2 | usage / registry / **tool not installed** | report, continue with the others — this script upgrades, it never bootstraps |
| 3 | SKIP — no `upgrade` block, or operator-triggered only | report it in the run summary with the version gap so the operator can decide; do NOT re-run without `--unattended` |
| 4 | ran but the version did NOT advance | **report loudly** — the toolchain is now suspect; name the tool and the version it is stuck on |

An rc 3 is not a failure — it means the entry is gated to the operator. Surface
it as a line they can act on:
`<tool> <old> -> <new> available; operator-triggered: bash scripts/upstreams/apply-tool-upgrade.sh <tool>`

No entry is gated today (rtk is `unattended: true`), so rc 3
should not appear from the cadence — if it does, someone gated an entry
deliberately and the run summary is how they learn it fired.

Never edit `scripts/upstreams.json` to flip an entry's `unattended` flag to get
past an rc 3. That flag is an operator decision, not an obstacle.

## 2B. Confirm the marketplace rows were repaired

**Step 1A already repaired them** — `himmel-update.sh`'s advisory block runs
`scripts/upstreams/update-marketplaces.sh` over exactly these `mkt-manual` rows.
Do NOT run that sweep again here: it is a second round of network updates for
work already done, and its per-row failures were already reported in 1A's
output.

So this step is a READ, not a repair. **Classify on POSITIVE EVIDENCE from 1A's
output — never on a row's absence from it.** Absence has too many causes: a
dirty-tree refusal before the chain even starts, a `--check` run, a `--only`
run, a `cannot run` rc 2 (no `claude` CLI, no `python3`, unreadable registry),
or a missing helper. In every one of those the sweep touched nothing while
mentioning nothing, and "not mentioned" would read as "nothing owed".

First, establish that the sweep RAN TO COMPLETION. Either of these two lines in
1A's output proves it, and nothing else does:

- `update-marketplaces: updated: …` — it swept rows.
- `update-marketplaces: no manual-tier marketplaces installed — nothing to
  update.` — it looked and there were none to sweep. This is a clean rc-0 run,
  not a failure: a `BEHIND mkt:*` row can still exist here, because
  `autoUpdate:true` rows are outside this helper's scope by design.

**If NEITHER line is present, the sweep did not complete: report EVERY
`BEHIND mkt:*` row as UNREPAIRED**, name the cause 1A printed instead (the
`CANNOT RUN` line, the dirty-tree refusal, a skipped step), and stop
classifying. Once one of them IS present:

- the name appears after `updated:` → repaired. Note it and move on.
- the name appears after `update-marketplaces: FAILED:` → a real failure. Name
  it in the run summary with the manual re-run
  (`bash scripts/upstreams/update-marketplaces.sh` from the primary checkout, or
  `claude plugin marketplace update <name>` for the one row) and continue with
  the bump work — a marketplace failure never blocks a pin bump.
- the sweep ran and the name is in neither list → it is `autoUpdate:true`
  (Claude Code refreshes it at session start) or it is `himmel` (chain item 2,
  reported separately in 1A's status table). Nothing is owed here.

Machine-local either way: no repo diff, no PR, and not a reason to open one.

Only run the sweep directly if step 1A was skipped (`--dry-run`, or an abort
before it). **Under `--dry-run` it MUST carry `--check`** —
`bash scripts/upstreams/update-marketplaces.sh --check` — otherwise the bare
form updates real marketplaces during a run that promised to change nothing.
Its rc table is: `0` all selected rows updated or none
needed it; `1` at least one FAILED and the others were still attempted (report
the named rows); `2` cannot run — no `claude` CLI, no `python3`, or an
unreadable/malformed `known_marketplaces.json`, which is **never** clean
("could not look" is not "looked and found nothing"). `--check` lists the rows
and calls the CLI zero times.

## 2C. Bring every fork current — the fork-rebase step

Operator decision 1145: **every drift fix brings every fork we own current.** A
fork whose sync conflicts is not parked on a ticket and not left `BEHIND` with a
note: the conflict is work, and resolving it is a **fork-rebase step** of this
run. The only fork this step leaves behind is one that carries an **operator
hold** (a `HELD` row, or a fork-branch `hold-reason`), and the report names the
hold's reason. A fork that is neither current nor held when the run ends is a
failed run, reported as such — never a "deferred" row and never a new ticket. The
one exception is the move the operator's ruling reserves for the operator: a
fork's default branch is never moved by an unattended run (outcome 1 below).

Per collected fork, one of four outcomes. **Every `resync-fork.sh` call in this
step is an audit: `<name>` mode as written, `--sync` always with `--dry-run`.** The unflagged `--sync` publishes by `gh repo sync` of the default
branch and a forced push over the himmel branch (the default branch for most
registered forks), so only an operator runs it, by hand.

1. **No carried commits** (`use-upstream`): `bash scripts/upstreams/resync-fork.sh
   --sync <owner/repo> --dry-run` says so and moves nothing. Point the pins and
   installs at upstream. A fork that is only behind with no carried commits (the
   report's `gh repo sync` action) needs its default branch fast-forwarded, which is
   the operator's word, not a hold the operator recorded: report it as `OWED to the
   operator: gh repo sync <owner/repo> --branch <branch>`, and the run summary names
   it. It is not shown as `HELD` and not counted as current.
2. **Carried commits, clean rebase**: `bash scripts/upstreams/resync-fork.sh <name>`
   (a registry `fork` block) or `bash scripts/upstreams/resync-fork.sh --sync
   <owner/repo> --dry-run` (a registered adapter fork). rc 0 means the rebase is
   clean in the scratch clone: test it, publish it and move the pin (below).
3. **Carried commits, conflict** (rc 4 `CONFLICTED`, or a non-additive delta on
   an entry whose `fork.note` does not declare it by design): do the **fork-rebase
   step** the script printed. In its scratch clone, replay the carried commits
   onto the target release and resolve every conflict in the same run: keep both
   sides' intent, regenerate lockfiles with the package manager, never take a
   whole file from one side, keep every carried commit (one commit each, none
   dropped or squashed), and check the result with `git range-diff`. Run the fork's
   own tests and the consumer suite from `/fork-resync` step 5 (qmd:
   `bash scripts/lib/test-qmd-bin.sh`). A carried commit that cannot keep its
   behaviour on the new base fails the run on that fork: name the commit and
   the conflicting upstream change, and stop on that fork.
4. **Operator hold**: nothing to do; the report line is `HELD` with the reason.

**Publishing a rebased fork** (outcomes 2 and 3), only after the fork's tests and the
consumer suite pass on the rebased tip (outcome 2 runs them too): from the scratch
clone (`<name>` mode: its `work_dir`; `--sync`: `~/.himmel/fork-resync/sync-<owner>--<repo>`), with a plain
push, no force flag and no `gh repo sync`. First prove the three refs are free (a
plain push would fast-forward an existing branch and accept an identical tag); the
read must exit 2, and any other exit stops the push:

```bash
git -C <clone> ls-remote --exit-code fork refs/heads/himmel-main-upstream-<target> refs/tags/himmel-pin/<version>-himmel.1 refs/tags/himmel-presync/<branch>-<sha12>
```

```bash
git -C <clone> push --atomic fork HEAD:refs/heads/himmel-main-upstream-<target> HEAD:refs/tags/himmel-pin/<version>-himmel.1 <old-tip>:refs/tags/himmel-presync/<branch>-<sha12>
```

That creates a NEW branch and a NEW tag at the rebased tip and keeps the old tip
reachable. If the check or the push fails, report that fork's failure with the git output and stop on it; never retry the push and never reach for a force flag. Never push over the fork's default branch or the himmel branch. Then move the pin and `synced_base` together, in the worktree of step 3,
as `/fork-resync` step 6 describes (the SHA or tag in the entry's `fork.pin_file`,
and `synced_base`); the fork's default branch moves on the operator's word. The same PR sets the fork row's `pin_branch`
in `scripts/guardrails/himmel-adapters.json` to `himmel-main-upstream-<target>`; once the fork's himmel
branch contains the pin commit, the next resync leg drops it. After a pin PR that sets or changes
`pin_branch` merges, `protect-forks.sh --apply --only <fork>` under the chief's
`HIMMEL_FORK_PROTECT_RULING` is owed, and the report names it as owed to the chief.

Per-fork result, one of these, never anything else:

- `CURRENT` — the fork already contained the release.
- `REBASED in this fix` — brought current by this run (name the new tip and tag).
- `HELD` — an operator hold, with the hold's reason.
- `OWED to the operator` — only the default-branch fast-forward of outcome 1, with its command. It is not a failed run.

## 3. Branch first

If step 2 collected no `mode: base` entries and step 2C left no fork pin to move, stop
here and report — including whatever steps 2A and 2C did. **Do not create a
branch or a PR to prove the cadence fired**, and note that a probe upgrade is NOT
a reason to open one: it changed a binary on this machine, not a file in the
repo. A no-op night is a successful run.

Otherwise cut the worktree BEFORE touching a pin, so the edits are never made in
the primary checkout (`git status` there must stay clean — the on-main-write
guard blocks it, and step 1 already promised not to disturb anyone's work):

```bash
bash scripts/worktree.sh new --no-prune chore/drift-bump-<name>-<YYYYMMDD>
```

**Every remaining step runs from that worktree**, including the bumper and the
re-verify — `apply-drift-bump.sh` resolves its target files relative to its own
location, so invoking the worktree's copy edits the worktree's files.

## 4. Bump

Per collected entry, one call:

```bash
bash scripts/upstreams/apply-drift-bump.sh <name> <target-version> --published <the target release's published_at; rc 5 = younger than 72 h, skip it until it ages>
```

An entry with `companion_pins` (cli-proxy-api: `ASSET_SHA256=` beside its
`VERSION=` pin) also needs `--sha256 <64-hex>`, the new release asset's
checksum from that release's own `checksums.txt`; without it the bump exits 2.
The registry, the version pin and every companion move together or not at all.

Handle the exit code — do not paper over any of them:

| rc | meaning | do |
|----|---------|-----|
| 0 | bumped (prints `BUMP <name> <old> -> <new>`) | continue |
| 1 | already at that version | skip it; note the guard/registry disagreement |
| 2 | usage / registry / **downgrade refused** | **abort the whole run** and report — a refused downgrade means the guard reported a version older than the pin, which is an upstream or registry problem, not something to work around |
| 3 | SKIP — no `version_pin`, not auto-bumpable | continue with the others; a fork entry (qmd, graphify) lands here because its pin is a fork SHA, so bumping `synced_base` alone would mark the fork as rebased when it isn't. Its pin moves in step 2C with the rebased tip, never by this script |
| 4 | bump failed, both files restored | **abort** and report — the registry's `version_pin.template` no longer matches the file |
| 5 | release-age gate — `--published` missing, or the target is younger than 72 h | skip it, note the date it ages in; a later night retries it |

`--published` is the release's Releases API `published_at`; for a bare tag with
no release, use the tag's date (an annotated tag's tagger date, else its commit's committer date).

If every entry came back rc 1, rc 3 or rc 5, nothing changed: report why, remove the
worktree (`bash scripts/worktree.sh prune` or `git worktree remove`),
and stop. **Do not open an empty PR.** With `--dry-run`, add `--dry-run` to each
call and stop after this step.

## 5. Verify the bump against upstream

Re-run `bash scripts/check-plugin-drift.sh` from the worktree. **Every bumped
entry must now read `CURRENT`.** If one still reads `BEHIND`, the target version
was misread — abort and report; do not "try the next version".

## 6. Ticket

Every PR carries a Jira ticket. Search first:

```bash
node <repo-root>/scripts/jira/dist/index.js list --jql "project = HIMMEL AND summary ~ 'graphify' AND statusCategory != Done" --limit 10
```

Reuse an open ticket for this exact bump if one exists; otherwise file one
(absolute path from the primary checkout, `--desc-file` for the body — a
heredoc/`$( )` shape gets refused by `block-jira-compound-write.sh`):

```bash
node <repo-root>/scripts/jira/dist/index.js create --type Task --title "Bump <name> pin <old> -> <new> (fork-drift)" --sector "Deployment" --labels standalone --proposed-version <current version> --desc-file <path>
```

`create` also refuses a Task, Story or Bug with no `--sector` or with neither `--parent <EPIC>` nor `--labels standalone`, and one with no placement: `--proposed-version <v>` files it with a `proposed-<v>` label and no fixVersion, and queues its INTAKE request toward `<v>` (refused when no release is declared), while `--fix-version <v>` places it in that version. The line above carries all three.

`create` refuses a body without the seven sections `## Impact` / `## What` /
`## Why` / `## Plan` / `## DoD` / `## Proof` / `## Agent detail`, where Plan and DoD each hold
a real bullet or numbered line. Put the plain block
first (what a user would notice, in plain words); the Agent detail section should
name: the drift guard line, the two files moved, the tracking issue number, and
that this was applied by the nightly cadence.

## 7. Commit

Commit in the worktree. The message needs the attestation trailers in the
**FIRST** commit (a later `--amend` is HARD-blocked in auto-mode):

```text
chore(HIMMEL-<N>): bump <name> pin <old> -> <new> (fork-drift #<issue>)

<one paragraph: which upstream release, what the guard said, that
apply-drift-bump.sh applied both halves mechanically>

Platforms tested: linux
Security reviewed: <token>
```

Both trailers are earned, not decorative — before writing them, actually run:

```bash
bash scripts/upstreams/test-apply-drift-bump.sh
bash scripts/lib/test-graphify-bin.sh      # or the bumped entry's own suite
```

If a suite fails, fix it or abort. Never write a trailer for a run you did not do.

## 8. Review gate

Run `/pr-check` and loop — fix every finding, re-run — until CR is clean. The
CR-marker hook HARD-blocks `gh pr create` until it is. Then open the PR
referencing the ticket.

## 9. Land on main

**The repo rule is ≥1 approval before merge, and this cadence does not get an
exemption for being automated.** An unattended runbook that says "watch CI, then
merge" quietly converts a review requirement into a formality — the one place a
policy bypass is least likely to be noticed, because nobody is watching. So:
green CI is necessary, never sufficient.

Watch CI to green, then hand the merge to the tooling that respects branch
protection — never merge past it:

Armed auto-merge (`ARMAUTOMERGE=1`, `scripts/handover/merge-on-green.sh`) admits
a repo confirmed PRIVATE, or the ONE configured public origin when a live read
shows branch protection on the base branch with BOTH `enforce_admins` enabled
and a non-empty required-status-checks list — `origin` is that
origin, so the armed path is available here. Any other public repo, and an
unreadable or check-less protection read, still refuse (exit 12).
`merge-on-green.sh` exits 18 (GitHub-blocked) on a fresh pre-merge `BLOCKED` + `REVIEW_REQUIRED` policy read after green checks, an explicit GitHub base-branch policy / required-check / ruleset rejection at merge time, or `check-ci.sh` exit 5 (a required check never reported, or the required set is unreadable) — once, with one operator DM per (repo, PR, head) and no poll or retry (exit 17 is now the chief-GO refusal only); if no automation identity can satisfy the required review, the merge is a human admin action.
`scripts/handover/pr-merge.sh` (plain-first) remains the alternative.

**Never `--admin`, never a force-merge, never a branch-protection override.** If
the merge is refused for want of an approval, that is the rule working: leave
the PR open, report it as `awaiting approval` in the run summary, and stop. A
blocked merge is a successful run — the drift is captured in a reviewable PR,
which was the point. Do not retry with a stronger flag, and do not "helpfully"
self-approve.

Then `git pull` on main — the next nightly `fork-drift` run sees the pin
current and **auto-closes the tracking issue**; that is the loop closing.

---

## Report

End every run — including the no-op ones — with:

```text
drift-fix <date>
  machine:  <himmel-update chain status: n updated / n skipped / n failed>  (step 1A)
  guard:    <exit code> — <n> BEHIND (<n> pinned, <n> installed-tool, <n> marketplace)
  upgraded: <tool> <old> -> <new>      (or: none)
  markets:  <name> ...                 (or: none — and name any that FAILED)
  awaiting: <tool> <old> -> <new> — operator-triggered: bash scripts/upstreams/apply-tool-upgrade.sh <tool>
  bumped:   <name> <old> -> <new>      (or: none)
  forks:    <fork>: CURRENT | REBASED in this fix (<new tip>, <tag>) | HELD (<the hold's reason>) | OWED to the operator (<command>)   (one line per fork; OWED is not a failed run)
  skipped:  <name> (<why>) ...
  ticket:   HIMMEL-<N>                 (or: none — nothing bumped)
  landed:   <merged PR url>            (or: <where it stopped, e.g. awaiting approval>)
```

A no-op night is a successful run. Say "no drift" and exit 0 — do not invent
work, and do not open a PR to prove the cadence fired.
