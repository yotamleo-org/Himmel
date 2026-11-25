---
description: Rebase a carried fork onto upstream.
argument-hint: [name] [--dry-run]
---

The third repair path. `/drift-fix` handles the two easy classes — a version pin
in the repo (`mode: base`) and an installed binary (`mode: probe`). This one
handles the class that has no cheap fix: a **fork**.

`qmd` carries a `fork` block again: it is SHA-pinned via
`_qmd_fork_ref()` in `scripts/lib/qmd-bin.sh` to a `yotamleo/qmd` commit whose
launcher forwards signals, until tobi/qmd#1030 lands (then it returns
to upstream). It had been de-forked once before. A registry entry with a `fork` block records, in
`synced_base`, the highest upstream STABLE tag that fork actually sits on.

**The trap this command exists to prevent:** when upstream tags past
`synced_base`, the entry reads BEHIND, and the one-line "fix" — bump
`synced_base` — is a lie. It marks the fork as carrying an upstream base it never
rebased onto, and the guard goes quiet while the fork drifts further. That is why
a genuine SHA-pinned fork deliberately has **no `version_pin`** (qmd's shape again
since its launcher fork) and why `apply-drift-bump.sh` returns SKIP for it
rather than being taught to handle it.

The real fix is a rebase, and a rebase can conflict. That needs judgment, which
is why this is a runbook and not a shell script.

**Syncing a fork is upkeep, never a PR.** A registered fork
(`scripts/guardrails/himmel-adapters.json`, non-null `upstream`) is synced by
`bash scripts/upstreams/resync-fork.sh --sync <owner/repo>`: no carried commits
→ it says `use-upstream` (point pins and installs at upstream, no sync);
carried commits → `gh repo sync` of the fork's default branch plus a rebase of
our commits onto upstream, pushed straight to the himmel branch. A conflict
stops and names the paths. No sync PR, no judge, no CodeRabbit on upstream
code; `block-fork-sync-pr.sh` refuses a `gh pr create` that tries. The unflagged
`--sync` moves the default branch and force-pushes the himmel branch, so only an
operator runs it, by hand. The drift fix's step 2C and the audit-only
`HIMMEL-ForkResync` cadence use `--sync --dry-run` only. The steps
below audit the pin of an `upstreams.json` `fork` block; the PR in step 7 is the
himmel pin move, never a PR into the fork.

**Rules that hold throughout.**

1. **Never bump `synced_base` without a completed rebase.** If you cannot finish
   the re-sync, leave the entry BEHIND. A truthful BEHIND is the product here.
2. **Never push to the fork remote until the rebased result is clean, tested and
   additive-or-declared.**

`--dry-run` = report the rebase result, change nothing, push nothing.

---

## 1. Ground the run

Work from the PRIMARY checkout. `git fetch origin`, confirm a clean tree and
`main` at `origin/main`. A dirty tree aborts the run — never stash or reset
someone else's work.

## 2. Find the drifting forks

```bash
bash scripts/check-plugin-drift.sh
```

Take every `BEHIND` entry that declares a **`fork`** block in
`scripts/upstreams.json`. If a `name` argument was given, restrict to it.

Nothing BEHIND with a `fork` block → report "no fork drift" and stop. This is
the expected outcome whenever no fork is drifting — today only `qmd` declares a
`fork` block, and it reads BEHIND only once upstream tags past
its `synced_base`.

Any registry entry that declares a `fork` block is in scope, however it is
pinned — a SHA-pinned fork (qmd's old shape) and a pinned-remote fork whose
marketplace pin is an installable TAG (claude-obsidian's old shape, so
publishing there was a tag re-cut) both ran the nightly rebase-audit here the
same way. Still **not** in scope, each needing its own judgment call — say so
rather than touching them:
- vendored forks with an `UPSTREAM_PIN` (`telegram-himmel`) — a re-vendor plus a file-level delta audit.

## 3. Rebase and audit

```bash
bash scripts/upstreams/resync-fork.sh <name>
```

Scratch clones only; it never touches the live install and never writes to a
remote without `--push`.

| rc | meaning | do |
|----|---------|-----|
| 0 | rebase CLEAN and the delta is still strictly additive | continue to step 4 |
| 1 | already on the target base | nothing to do; if the guard still says BEHIND, the registry disagrees with reality — report that, don't "fix" it by editing `synced_base` |
| 2 | usage / registry / missing git or network | abort and report |
| 3 | SKIP — no `fork` block | not in scope for this command |
| 4 | rebase CONFLICTED, the delta is NOT additive, OR a pin-literal failure (`PIN_FILE_MISSING`/`PIN_NOT_FOUND`/`PIN_AMBIGUOUS`) | a conflict is resolved in the same fix (the fork-rebase step, see below); a pin-literal failure is reported; expected-non-additive entries are the exception |

**Expected-non-additive entries.** An entry whose `fork.note`
declares the delta non-additive BY DESIGN reports rc 4 NON-ADDITIVE on every
healthy audit — `qmd` is such an entry (its reviewed bugfixes until
it was first de-forked; now its `bin/qmd` launcher fix). For such an entry that outcome IS the report — record the drift +
rebase-feasibility result and **continue with the remaining forks**; do not
escalate it and do not let it terminate an unattended sweep. A CONFLICTED
rebase or a pin-literal failure on the SAME entry is still a real
stop-and-escalate — only the declared non-additive shape is expected. A fork
whose carried delta is strictly additive (`claude-obsidian` was one, at
v2.1.1-himmel.1, +10 −0, before that fork was collapsed onto upstream v2.2.0) is NOT such an
entry: its healthy audit result is ADDITIVE, and a NON-ADDITIVE result there
would be a regression to report, not a designed exception.

**On rc 4 CONFLICTED, do the fork-rebase step.** A conflict is work to do, not a
reason to leave the fork behind. Replay the carried commits onto the target in
the scratch clone and resolve every conflict: keep both sides' intent, regenerate
lockfiles with the package manager, never take a whole file from one side, keep
every carried commit, and check the result with `git range-diff`. Then continue
from step 5. Only a fork carrying an operator hold stays BEHIND, and no deferral
ticket is filed. The audit-only `HIMMEL-ForkResync` cadence reports the conflicting
paths, the fork's commit list and the upstream target and stops at step 3; the
resolution is done by the drift fix (`/drift-fix` step 2C) or an operator run of
this command. A non-additive delta that is not declared by design is reported the
same way.

A `PIN_FILE_MISSING`/`PIN_NOT_FOUND`/`PIN_AMBIGUOUS` rc 4 is a DIFFERENT failure
mode — the registry's `fork.pin_file`/`fork.pin_template` is stale, not a
rebase judgment call. Report the pin mismatch instead (entry name, the
missing/ambiguous path or template) — the conflicting-paths/commit-list report
above does not apply.

## 4. Publish the rebased fork

Run step 5's checks against the rebased tip in the scratch clone first, and push
only once they pass. Then push the rebased tip to a NEW branch `himmel-main-upstream-<target>` and a NEW
tag `himmel-pin/<version>-himmel.1`, with a plain `git push` from the scratch
clone, and keep the old tip reachable as tag `himmel-presync/<branch>-<sha12>`.
Never push over the fork's default branch or the himmel branch and never
force-push: moving those is the operator's word. The command, from the scratch
clone (remote `fork`):

```bash
git -C <clone> push --atomic fork HEAD:refs/heads/himmel-main-upstream-<target> HEAD:refs/tags/himmel-pin/<version>-himmel.1 <old-tip>:refs/tags/himmel-presync/<branch>-<sha12>
```

`resync-fork.sh --push` is not used: it force-pushes its own branch.

The modes differ in who runs this step:

- **The audit-only cadence (`HIMMEL-ForkResync`):** STOP at the end of step 3 and
  report the audited result — upstream target, fork commits rebased, whether
  the delta is additive, and the rebased SHA `resync-fork.sh` computed in its
  scratch clone. Nothing is pushed by that run; the fork is brought current by
  the drift fix, which runs this step.
- **The drift fix (`/drift-fix` step 2C) and an operator run:** run step 5's
  checks on the scratch-clone tip, push the new branch and tag as above only if
  they pass, then move the pin in step 6.

Record the new fork SHA (`git -C <clone> rev-parse HEAD`); it is the pin.

## 5. Prove the fork still works

A clean rebase is not evidence the result runs. Before moving the pin, exercise
the thing himmel actually depends on — whatever consumes the pin (a resolver
script, an install step) plus its test suite. For qmd, that is:

```bash
bash scripts/lib/test-qmd-bin.sh
```

If the fork's own test suite is reachable in the scratch clone, run it too. A
failure here means the rebase was clean but wrong — **stop**, do not move the
pin, and report.

## 6. Move the pin — both halves

Two edits that must move together, same discipline as `/drift-fix`:
- the SHA in the entry's `fork.pin_file`, at `fork.pin_template`'s `{sha}` slot
  (for qmd, `_qmd_fork_ref()` in `scripts/lib/qmd-bin.sh`) → the new rebased SHA from step 4;
- `synced_base` in `scripts/upstreams.json` → the upstream tag just rebased onto.

Do this in a worktree (`bash scripts/worktree.sh new --no-prune chore/fork-resync-<name>-<YYYYMMDD>`),
never in the primary checkout.

Then re-run `bash scripts/check-plugin-drift.sh` from the worktree — the entry
must now read **CURRENT**. If it does not, the pin and the push disagree; abort.

## 7. Ticket, review, land

Same as `/drift-fix` steps 6–9:
- File or reuse a Jira ticket (`node <repo-root>/scripts/jira/dist/index.js`,
  absolute path, `--desc-file` for the body).
- Commit with attestation trailers in the FIRST commit — `Platforms tested:` and
  `Security reviewed:` — earned by actually running step 5.
- `/pr-check` until CR is clean, open the PR, watch CI green.
- Merge via `scripts/handover/merge-on-green.sh` (armed — it admits a
  confirmed-private repo, or the ONE configured public origin under
  live-verified branch protection; a fork that is neither is
  refused, exit 12) or `scripts/handover/pr-merge.sh`. **The ≥1-approval rule
  applies to this cadence exactly as it does to a human PR** — green CI is
  necessary, never sufficient.
  `merge-on-green.sh` exits 18 (GitHub-blocked) on a fresh pre-merge `BLOCKED` + `REVIEW_REQUIRED` policy read after green checks, an explicit GitHub base-branch policy / required-check / ruleset rejection at merge time, or `check-ci.sh` exit 5 (a required check never reported, or the required set is unreadable) — once, with one operator DM per (repo, PR, head) and no poll or retry (exit 17 is now the chief-GO refusal only); if no automation identity can satisfy the required review, the merge is a human admin action.
  Never `--admin`, never a branch-protection override. A merge refused for want
  of an approval is the rule working: leave the PR open, report `awaiting
  approval`, and stop. That is a successful run — the himmel pin move waits in a
  reviewable himmel PR, which matters more here than anywhere else in himmel,
  because the pin decides the dependency every machine installs.

The commit body must state plainly: which upstream tag, the fork commits
rebased, that the delta was audited additive, and that the fork was pushed. A
reader six months from now needs to know the fork was genuinely re-based, not
just re-labelled.

---

## Report

Every run, including no-ops:

```text
fork-resync <date>
  forks BEHIND:  <name> (<synced_base> -> <upstream tag>)   (or: none)
  rebase:        CLEAN / CONFLICTED (<paths>) / NON-ADDITIVE (<paths>)
  pushed:        <new fork sha>                             (or: no — <why>)
  tests:         <suite> <pass/fail>
  pin moved:     <file> <old sha> -> <new sha>, synced_base <old> -> <new>
  landed:        <merged PR url>                            (or: <where it stopped, e.g. awaiting approval>)
```

"No fork drift" is the healthy result. Never manufacture a re-sync to show
activity, and never move a pin you did not earn.
