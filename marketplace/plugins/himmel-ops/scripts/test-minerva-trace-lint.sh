#!/usr/bin/env bash
# shellcheck disable=SC2015,SC2016
# test-minerva-trace-lint.sh — minerva's terminal lint refuses a
# surface-shaped spec with no Fact ownership matrix, a spec with no Invariants
# section, and a plan that names no test for an invariant. RED fixture:
# fixtures/minerva-trace-lint/red-spec.md;
# the GREEN spec is that fixture plus the two sections, built here.
set -u
here="$(cd "$(dirname "$0")" && pwd)"
lint="$here/minerva-trace-lint.sh"
red="$here/fixtures/minerva-trace-lint/red-spec.md"
td="$(mktemp -d "${TMPDIR:-/tmp}/minerva-trace.XXXXXX")" || { echo "FAIL - mktemp"; exit 1; }
trap 'rm -rf "$td"' EXIT
cd "$(git -C "$here" rev-parse --show-toplevel)" || { echo "FAIL - no repo root"; exit 1; }
fails=0
ok(){ echo "ok - $1"; }
bad(){ echo "FAIL - $1"; fails=$((fails+1)); }

expect_refuse(){ # <label> <needle> <spec> <plan>
  local out rc
  out="$(bash "$lint" "$3" "$4" 2>&1)"; rc=$?
  [ "$rc" -eq 1 ] && ok "$1: exit 1" || bad "$1: expected exit 1, got $rc: $out"
  case "$out" in *"$2"*) ok "$1: names $2";; *) bad "$1: output lacks [$2]: $out";; esac
}
expect_pass(){ # <label> <spec> <plan>
  local out
  out="$(bash "$lint" "$2" "$3" 2>&1)" && ok "$1" || bad "$1: expected pass: $out"
}

# a real repo path, so the matrix's path rule is exercised against disk
repo_path="marketplace/plugins/himmel-ops/scripts/minerva-spec-gate.sh"
fact_ok="## Fact ownership

| Fact | Existing surfaces | Owner after | Non-owners |
|---|---|---|---|
| item health | \`$repo_path\` | the feed | doctor delegates, shown as evidence |
| cadence state | none (grep: \`cadence-state\`) | the feed | n/a |
"
inv_ok="## Invariants

- I1 — one fact is one row, whichever surfaces compute it.
"
printf 'plan\n\n- Task 1: I1 — Test: `scripts/test-feed.sh` feeds a fact from two real sources.\n' >"$td/plan.md"
printf 'plan\n\n- Task 1: I1 is covered somewhere.\n' >"$td/plan-untraced.md"

# RED: the 4254-shaped fixture fails on both missing sections
expect_refuse "RED fixture: no Fact ownership" "fact ownership" "$red" "$td/plan.md"
expect_refuse "RED fixture: no Invariants" "invariants" "$red" "$td/plan.md"

# GREEN: the same fixture with both sections passes
{ cat "$red"; echo; printf '%s\n' "$fact_ok"; printf '%s\n' "$inv_ok"; } >"$td/green.md"
expect_pass "GREEN fixture passes" "$td/green.md" "$td/plan.md"

# an invariant the plan mentions without naming a test
expect_refuse "untraced invariant" "I1" "$td/green.md" "$td/plan-untraced.md"

# a matrix row citing neither an existing path nor a grep record
{ cat "$red"; echo; printf '%s\n' "## Fact ownership

| Fact | Existing surfaces | Owner after | Non-owners |
|---|---|---|---|
| item health | the doctor, probably | the feed | n/a |
"; printf '%s\n' "$inv_ok"; } >"$td/no-grep.md"
expect_refuse "row without path or grep record" "item health" "$td/no-grep.md" "$td/plan.md"

# a cited path that does not exist
sed "s#$repo_path#scripts/no-such-file.sh#" "$td/green.md" >"$td/dangling.md"
expect_refuse "cited path missing" "no-such-file" "$td/dangling.md" "$td/plan.md"

# a glob token is a literal path, never expanded into whatever the cwd holds
sed "s#\`$repo_path\`#\`*\`#" "$td/green.md" >"$td/glob.md"
expect_refuse "glob token not expanded" "cites *," "$td/glob.md" "$td/plan.md"

# a surface word only in the first H2 heading still makes the spec surface-shaped
printf '# Feed rework\n\n## Health\n\nRework it.\n\n## Invariants\n\nnone\n' >"$td/h2-only.md"
expect_refuse "surface word in first H2 heading" "fact ownership" "$td/h2-only.md" "$td/plan.md"

# a stray `none` line does not exempt I<n> lines beside it
sed 's/^- I1 — /none\n- I1 — /' "$td/green.md" >"$td/none-plus.md"
expect_refuse "none beside an I<n> line" "I1" "$td/none-plus.md" "$td/plan-untraced.md"

# a matrix row with an empty owner cell
sed 's/| the feed | doctor delegates/|  | doctor delegates/' "$td/green.md" >"$td/no-owner.md"
expect_refuse "row without an owner" "names no owner" "$td/no-owner.md" "$td/plan.md"

# an unnumbered invariant bullet beside an I<n> line is refused
sed 's/^- I1 — /- every row has one owner.\n- I1 — /' "$td/green.md" >"$td/unnumbered.md"
expect_refuse "unnumbered invariant bullet" "not an I<n> line" "$td/unnumbered.md" "$td/plan.md"

# an unnumbered prose rule at column 0 is refused; an indented continuation is not
sed 's/^- I1 — /Never let two surfaces own a fact.\n- I1 — /' "$td/green.md" >"$td/prose-rule.md"
expect_refuse "unnumbered prose rule" "not an I<n> line" "$td/prose-rule.md" "$td/plan.md"
sed 's/^- I1 — .*/&\n  whichever surfaces compute it./' "$td/green.md" >"$td/continued.md"
expect_pass "indented continuation of an I<n> line passes" "$td/continued.md" "$td/plan.md"

# a Non-owners column alone is not an owner column
sed 's/| Owner after |/| After |/' "$td/green.md" >"$td/non-owners-only.md"
expect_refuse "Non-owners column is not an owner column" "no '## Fact ownership' table" "$td/non-owners-only.md" "$td/plan.md"

# a cited path outside the repo does not count, even when it exists
sed "s#\`$repo_path\`#\`/etc/hosts\`#" "$td/green.md" >"$td/abs.md"
expect_refuse "absolute path refused" "/etc/hosts" "$td/abs.md" "$td/plan.md"
sed "s#\`$repo_path\`#\`../../../../etc/hosts\`#" "$td/green.md" >"$td/dotdot.md"
expect_refuse "path escaping the repo refused" "etc/hosts" "$td/dotdot.md" "$td/plan.md"

# an incomplete grep record does not exempt the row
sed 's/none (grep: `cadence-state`)/none (grep:/' "$td/green.md" >"$td/half-grep.md"
expect_refuse "incomplete grep record" "cadence state" "$td/half-grep.md" "$td/plan.md"

# a non-surface spec needs Invariants (may be none) but no matrix
printf '# Rename a flag\n\n## 1. Goal\n\nRename the flag.\n\n## Invariants\n\nnone\n' >"$td/plain.md"
expect_pass "non-surface spec with Invariants: none passes" "$td/plain.md" "$td/plan.md"

# a backticked word that is not a path (a flag, an identifier) is not a missing file
sed "s#\`$repo_path\`#\`$repo_path\` (\`--held\`, \`ROW_REGISTRIES\`)#" "$td/green.md" >"$td/words.md"
expect_pass "non-path backticked words beside a real path pass" "$td/words.md" "$td/plan.md"
# ...but a cell citing only such words cites no path and no grep record
sed "s#\`$repo_path\`#\`--held\` \`ROW_REGISTRIES\`#" "$td/green.md" >"$td/words-only.md"
expect_refuse "cell of only non-path words is refused" "item health" "$td/words-only.md" "$td/plan.md"
# a bare name with an extension is still a path, so a missing one is refused
sed "s#\`$repo_path\`#\`no-such-top.sh\`#" "$td/green.md" >"$td/top-missing.md"
expect_refuse "missing top-level file refused" "no-such-top.sh" "$td/top-missing.md" "$td/plan.md"

# an optional third argument names the spec's own repo; a path counts if it exists under either root
mkdir -p "$td/own/notes" && printf 'x\n' >"$td/own/notes/only-here.md"
sed "s#\`$repo_path\`#\`notes/only-here.md\`#" "$td/green.md" >"$td/own-path.md"
expect_refuse "path only in the spec's own repo, no second root" "notes/only-here.md" "$td/own-path.md" "$td/plan.md"
out="$(bash "$lint" "$td/own-path.md" "$td/plan.md" "$td/own" 2>&1)" && ok "path in the second root passes" || bad "path in the second root: $out"
out="$(bash "$lint" "$td/dangling.md" "$td/plan.md" "$td/own" 2>&1)"; rc=$?
[ "$rc" -eq 1 ] && ok "path in neither root: exit 1" || bad "path in neither root: expected exit 1, got $rc: $out"

# moving a section cannot switch the check off.
# (a) the surface word sits in a later H2 heading, not the first: still surface-shaped
printf '# Feed rework\n\n## Goal\n\nRework it.\n\n## Health\n\nMore.\n\n## Invariants\n\nnone\n' >"$td/later-h2.md"
expect_refuse "surface word in a later H2 heading" "fact ownership" "$td/later-h2.md" "$td/plan.md"
# (b) a spec that carries a Fact ownership section is checked even with no surface word in its headings
{ printf '# Rename a flag\n\n## 1. Goal\n\nRename the flag.\n\n'; printf '%s\n' "$fact_ok"; printf '%s\n' "$inv_ok"; } >"$td/plain-fo.md"
expect_pass "plain spec with a valid Fact ownership section passes" "$td/plain-fo.md" "$td/plan.md"
sed "s#$repo_path#scripts/no-such-file.sh#" "$td/plain-fo.md" >"$td/plain-fo-bad.md"
expect_refuse "Fact ownership section on a plain spec is still checked" "no-such-file" "$td/plain-fo-bad.md" "$td/plan.md"

# usage errors exit 2
bash "$lint" "$td/absent.md" "$td/plan.md" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 2 ] && ok "missing spec: exit 2" || bad "missing spec: expected exit 2, got $rc"

[ "$fails" -eq 0 ] && { echo "ALL PASS"; exit 0; } || { echo "$fails FAILED"; exit 1; }
