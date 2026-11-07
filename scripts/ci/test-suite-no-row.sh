#!/usr/bin/env bash
# shellcheck disable=SC2016  # fixture suite bodies are single-quoted on purpose: their $vars must stay literal
# scripts/ci/test-suite-no-row.sh — a suite with no row in suite-tiers.tsv or
# suite-durations.tsv cannot avoid CI. Runs what a PR's shards and
# the shell-unit aggregator run, under SUITE_TIER_MODE=pr, in a throwaway repo
# whose refs/remotes/origin/main is BASE:
#
#   NR1  a PR adding only a new suite and its subject: the lint passes, the
#        selection stays impacted, the suite shows `ran 0` in a shard manifest,
#        the aggregator's verify passes
#   NR2  a later PR that does not touch it: the suite still runs and is required
#   NR3  RED controls: a no-row suite no shard ran, or one that failed, is refused
#   NR4  a PR changing a tier row still forces the full sweep
#
# This suite itself ships with no row in either list, so the PR that added it
# shows a real no-row suite in a CI shard manifest.
#
# Platform guard: bash-only; the shards run on Linux CI.
#
# Usage: bash scripts/ci/test-suite-no-row.sh
# Exit codes: 0 — all cases passed; 1 — at least one failed.
set -uo pipefail

# shellcheck source=run-shell-tests-fixture.sh
# shellcheck disable=SC1091
. "$(cd "$(dirname "$0")" && pwd)/run-shell-tests-fixture.sh"
# shellcheck source=../lib/fixture-tempdir.sh
# shellcheck disable=SC1091
. "$RST_FIXTURE_DIR/../lib/fixture-tempdir.sh"

SRC_ROOT="$(cd "$RST_FIXTURE_DIR/../.." && pwd)"
LINT="$SRC_ROOT/scripts/ci/test-suite-tiers.sh"
VERIFY="$SRC_ROOT/scripts/ci/shard-manifest-verify.sh"
SB="$(fixture_mktemp_dir)" || exit 1
trap 'rm -rf "$SB" "$SUITE_LOCK_SANDBOX"' EXIT
(
  fixture_enter_git_init_dir "$SB" || exit 1
  git init -q
  git config user.email t@e
  git config user.name t
) || exit 1
g() { git -C "$SB" "$@"; }

# Scan root `.` walks these trees; find fails on a missing one.
mkdir -p "$SB/scripts/ci" "$SB/scripts/lib" "$SB/scripts/cr" "$SB/scripts/tools" "$SB/docs" \
         "$SB/templates" "$SB/marketplace" "$SB/packaging"
cp "$RUNNER" "$SB/scripts/ci/run-shell-tests.sh"
cp "$SRC_ROOT/scripts/ci/impacted-selection.sh" "$SB/scripts/ci/impacted-selection.sh"
cp "$SRC_ROOT/scripts/cr/impacted-suites.sh" "$SRC_ROOT/scripts/cr/anchor-handoff.sh" "$SB/scripts/cr/"
for lib in proc-tree.sh git-test-env.sh override-env.sh runtime-preflight.sh suite-semaphore.sh chokepoint-seam-guard.sh; do
  cp "$SRC_ROOT/scripts/lib/$lib" "$SB/scripts/lib/$lib"
done
printf '^scripts/ci/\n' > "$SB/scripts/ci/ci-trust-paths.txt"
TIERS="$SB/scripts/ci/suite-tiers.tsv"
printf '# fixture tiers\nscripts/test-old.sh\tpr\tguard\nscripts/test-idle.sh\tlocal\tbehaviour suite\n' > "$TIERS"
printf 'scripts/test-old.sh\t5\nscripts/test-idle.sh\t5\n' > "$SB/scripts/ci/suite-durations.tsv"

NR_LOG="$SB/ran.log"
export NR_LOG
mksuite() {  # <path> <name> <exit code>
  printf '#!/usr/bin/env bash\n# %s\necho %s >> "$NR_LOG"\nexit %s\n' "$2" "$2" "$3" > "$SB/$1"
}
mksuite scripts/test-old.sh old 0
mksuite scripts/test-idle.sh idle 0
printf 'ran.log\nm/\nsel.txt\ndisc.txt\n' > "$SB/.gitignore"
g add -A; g commit -q -m "chore: base"
BASE=$(g rev-parse HEAD)
g update-ref refs/remotes/origin/main "$BASE"

RUN="$SB/scripts/ci/run-shell-tests.sh"
NEW=scripts/test-fresh.sh
# new_suite_pr <branch> <exit code> — a PR off BASE adding only a suite and its subject.
new_suite_pr() {
  g checkout -q -B "$1" "$BASE"
  printf '# subject\n' > "$SB/scripts/tools/fresh.sh"
  mksuite "$NEW" fresh "$2"
  g add -A; g commit -q -m "feat: fresh"
}
# shards <n> — every shard as ci.yml runs it, then the aggregator's selection,
# discovery and verify. Sets $vrc and $vout; $M holds every manifest line.
shards() {
  local k=1
  rm -rf "$SB/m"; : > "$NR_LOG"
  while [ "$k" -le "$1" ]; do
    SUITE_TIER_MODE=pr SUITE_IMPACTED_FROM_BASE="$BASE" SUITE_MANIFEST="$SB/m/manifest-shard$k.txt" \
      bash "$RUN" --scan-repo-of-script --shard "$k/$1" . > /dev/null 2>&1
    k=$((k + 1))
  done
  (cd "$SB" && SUITE_TIER_MODE="pr" bash scripts/ci/impacted-selection.sh "$BASE" HEAD) > "$SB/sel.txt"
  SUITE_TIER_MODE="pr" bash "$RUN" --scan-repo-of-script --list . > "$SB/disc.txt" 2>&1
  verify "$1"
  M=$(cat "$SB"/m/manifest-shard*.txt 2>/dev/null)
}
verify() {
  vout=$(SUITE_TIER_MODE=pr SUITE_TIERS_TSV="$TIERS" bash "$VERIFY" --dir "$SB/m" --shards "$1" \
         --selection "$SB/sel.txt" --discovered "$SB/disc.txt" 2>&1); vrc=$?
}

# --- NR1 ---------------------------------------------------------------------
new_suite_pr adds 0
g ls-files > "$SB/tracked.txt"
lout=$(bash "$LINT" --lint --tiers "$TIERS" --trust "$SB/scripts/ci/ci-trust-paths.txt" --tracked "$SB/tracked.txt" 2>&1); lrc=$?
if [ "$lrc" -eq 0 ]; then pass "NR1: the lint passes a new suite with no row"; else fail "NR1: lint rc=$lrc: $lout"; fi
rm -f "$SB/tracked.txt"
if grep -qF "$NEW" "$TIERS" "$SB/scripts/ci/suite-durations.tsv"; then
  fail "NR1: the fixture suite has a row, so this proves nothing"
else
  pass "NR1: the fixture suite has no row in either list"
fi
shards 2
if grepq "$(cat "$SB/sel.txt")" -x 'mode impacted'; then
  pass "NR1: the selection stays impacted, no full run is forced"
else
  fail "NR1: selection: $(head -n 2 "$SB/sel.txt")"
fi
if grepq "$M" -x "ran 0 $NEW"; then pass "NR1: the no-row suite shows ran 0 in a shard manifest"; else fail "NR1: manifests: $M"; fi
if grepq "$M" -x 'skip scripts/test-idle.sh'; then
  pass "NR1: an unimpacted local suite is skipped beside it, so the run is really in pr mode"
else
  fail "NR1: test-idle.sh was not skipped: $M"
fi
if [ "$vrc" -eq 0 ]; then pass "NR1: the aggregator verifies it"; else fail "NR1: verify rc=$vrc: $vout"; fi

# --- NR2 ---------------------------------------------------------------------
g update-ref refs/remotes/origin/main "$(g rev-parse HEAD)"
BASE=$(g rev-parse HEAD)
g checkout -q -B later "$BASE"
printf '# doc\n' > "$SB/scripts/tools/other.sh"
g add -A; g commit -q -m "feat: other"
shards 2
if grepq "$(cat "$SB/sel.txt")" -x "suite $NEW"; then
  fail "NR2: the fixture suite was impacted, so this proves nothing about the floor"
elif grepq "$M" -x "ran 0 $NEW" && [ "$vrc" -eq 0 ]; then
  pass "NR2: a later PR that does not touch the no-row suite still runs it"
else
  fail "NR2: vrc=$vrc $vout manifests: $M"
fi

# --- NR3 ---------------------------------------------------------------------
sed -i.bak "/^ran 0 ${NEW//\//\\/}\$/d" "$SB"/m/manifest-shard*.txt
rm -f "$SB"/m/*.bak
verify 2
if [ "$vrc" -eq 1 ] && grepq "$vout" -F "$NEW never ran"; then
  pass "NR3: RED control: a no-row suite no shard ran is refused"
else
  fail "NR3: dropped ran line: rc=$vrc: $vout"
fi
mksuite "$NEW" fresh 1
g add -A; g commit -q -m "fix: break fresh"
shards 2
if [ "$vrc" -eq 1 ] && grepq "$vout" -F "$NEW ran on shard"; then
  pass "NR3: RED control: a no-row suite that fails is refused"
else
  fail "NR3: failing suite: rc=$vrc: $vout"
fi

# --- NR4 ---------------------------------------------------------------------
g checkout -q -B retier "$BASE"
printf 'scripts/test-fresh.sh\tlocal\tbehaviour suite\n' >> "$TIERS"
g add -A; g commit -q -m "chore: retier"
sel=$(cd "$SB" && SUITE_TIER_MODE="pr" bash scripts/ci/impacted-selection.sh "$BASE" HEAD)
if grepq "$sel" -x 'mode full' && grepq "$sel" -F 'selector-path: scripts/ci/suite-tiers.tsv'; then
  pass "NR4: a PR changing a tier row still forces the full sweep"
else
  fail "NR4: selection: $(head -n 2 <<< "$sel")"
fi

rst_tally
