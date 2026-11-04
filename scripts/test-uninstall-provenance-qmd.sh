#!/usr/bin/env bash
# shellcheck disable=SC2015,SC2034 # the CASE_QMD_* values are read by run_uninstall in the sourced fixture
# test-uninstall-provenance-qmd.sh -- the RED20-RED32 cases (the qmd fork checkout and collection).
# One of four files (test-uninstall-provenance.sh, -qmd, -legacy, -tty-block) split from one 525 s
# suite so no CI shard is bounded by it. The shared fixture is
# scripts/lib/testlib-uninstall-provenance.sh; each piece ends with its own real-ledger tripwire.
# jq-only. Usage: bash scripts/test-uninstall-provenance-qmd.sh
set -u
here="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
lib="$repo_root/scripts/lib"

# shellcheck source=lib/testlib-uninstall-provenance.sh
# shellcheck disable=SC1091
. "$here/lib/testlib-uninstall-provenance.sh"

echo "==== RED20 (HIMMEL-3332 slice3): install-created qmd kept by default, removed under --purge-state; stub never removed ===="
# Fixture shape mirrors the real prov_record call sites (scripts/lib/qmd-bin.sh
# lines 595-655, scripts/lib/fix-qmd-stub.sh line 66): fork checkout is a
# `create file` row on the build stamp, the bun-global link is a `create
# symlink` row (--post-text stores the target string's SHA, never the
# literal), the collection is a `register collection` row (path arg `-`,
# ownership by unit name), and the stub patch is a `replace file` row with
# --backup that NEVER gates a removal (chief ruling, 2026-09-23).
new_case red20a
CASE_QMD_FORK_DIR="$CASE_DIR/qmd-fork"
CASE_BUN_INSTALL="$CASE_DIR/bun"
mkdir -p "$CASE_QMD_FORK_DIR"
STAMP20A="$CASE_QMD_FORK_DIR/.himmel-build-ok"; printf 'ok\n' > "$STAMP20A"
GLOBAL_DIR20A="$CASE_BUN_INSTALL/install/global/node_modules/@tobilu/qmd"
mkdir -p "$(dirname "$GLOBAL_DIR20A")"
ln -s "$CASE_QMD_FORK_DIR" "$GLOBAL_DIR20A"
STUB20A="$CASE_DIR/stub-qmd-20a"; printf 'patched stub\n' > "$STUB20A"
cp "$STUB20A" "$SUITE_TMP/red20a-stub-before"
printf 'orig stub\n' > "$SUITE_TMP/red20a-stub-pre"
( prov_begin --writer install.sh -- seed-red20a >/dev/null
  prov_record create file "$STAMP20A" --pre-absent --post-file "$STAMP20A" --scope machine --class code \
    --row qmd-fork --writer qmd-bin.sh --field preexisted=false >/dev/null
  prov_record create symlink "$GLOBAL_DIR20A" --post-text "$CASE_QMD_FORK_DIR" --scope machine --class code \
    --row qmd-fork --writer qmd-bin.sh --field preexisted=false >/dev/null
  prov_record register collection - --unit qmd-vault --post-text "$CASE_QMD_FORK_DIR" --scope machine --class code \
    --row qmd-fork --writer qmd-bin.sh --field preexisted=false >/dev/null
  prov_record replace file "$STUB20A" --pre-file "$SUITE_TMP/red20a-stub-pre" --backup --post-file "$STUB20A" \
    --scope machine --class code --row qmd-fork --writer fix-qmd-stub.sh --field preexisted=false >/dev/null
  prov_end ok >/dev/null )
out20a=$(run_uninstall --yes --skip-tasks --skip-plugins --skip-hooks); rc20a=$?
check "RED20a: uninstall exit status" "$rc20a" "0"
check "RED20a: default run keeps the fork checkout dir" "$([ -d "$CASE_QMD_FORK_DIR" ] && echo yes || echo no)" "yes"
check "RED20a: default run keeps the build stamp byte-identical" "$(cat "$STAMP20A" 2>/dev/null)" "ok"
check "RED20a: default run keeps the global symlink pointed at the fork dir" \
  "$(readlink "$GLOBAL_DIR20A" 2>/dev/null)" "$CASE_QMD_FORK_DIR"
check "RED20a: default run never calls qmd collection remove" \
  "$(grep -c 'collection remove' "$CASE_DIR/qmd.log" 2>/dev/null || echo 0)" "0"
check "RED20a: default run keeps the stub byte-identical" "$(cat "$STUB20A")" "$(cat "$SUITE_TMP/red20a-stub-before")"
check "RED20a: stub kept line printed" \
  "$(printf '%s\n' "$out20a" | grep -c 'qmd plugin stub himmel patched')" "1"

new_case red20b
CASE_QMD_FORK_DIR="$CASE_DIR/qmd-fork"
CASE_BUN_INSTALL="$CASE_DIR/bun"
# a real fork checkout is always a git work tree; a plain
# directory is the "unknown state" the fix now keeps rather than removes, so
# this --purge-state-removes fixture needs a clean git checkout to reach rm.
_red_seed_git_fork "$CASE_QMD_FORK_DIR"
STAMP20B="$CASE_QMD_FORK_DIR/.himmel-build-ok"
GLOBAL_DIR20B="$CASE_BUN_INSTALL/install/global/node_modules/@tobilu/qmd"
mkdir -p "$(dirname "$GLOBAL_DIR20B")"
ln -s "$CASE_QMD_FORK_DIR" "$GLOBAL_DIR20B"
STUB20B="$CASE_DIR/stub-qmd-20b"; printf 'patched stub\n' > "$STUB20B"
CASE_QMD_COLLECTION_PATH="$CASE_QMD_FORK_DIR"
cp "$STUB20B" "$SUITE_TMP/red20b-stub-before"
printf 'orig stub\n' > "$SUITE_TMP/red20b-stub-pre"
( prov_begin --writer install.sh -- seed-red20b >/dev/null
  prov_record create file "$STAMP20B" --pre-absent --post-file "$STAMP20B" --scope machine --class code \
    --row qmd-fork --writer qmd-bin.sh --field preexisted=false >/dev/null
  prov_record create symlink "$GLOBAL_DIR20B" --post-text "$CASE_QMD_FORK_DIR" --scope machine --class code \
    --row qmd-fork --writer qmd-bin.sh --field preexisted=false >/dev/null
  prov_record register collection - --unit qmd-vault --post-text "$CASE_QMD_FORK_DIR" --scope machine --class code \
    --row qmd-fork --writer qmd-bin.sh --field preexisted=false >/dev/null
  prov_record replace file "$STUB20B" --pre-file "$SUITE_TMP/red20b-stub-pre" --backup --post-file "$STUB20B" \
    --scope machine --class code --row qmd-fork --writer fix-qmd-stub.sh --field preexisted=false >/dev/null
  prov_end ok >/dev/null )
out20b=$(run_uninstall --yes --purge-state --skip-tasks --skip-plugins --skip-hooks); rc20b=$?
check "RED20b: uninstall exit status" "$rc20b" "0"
check "RED20b: --purge-state removes the fork checkout dir" "$([ -e "$CASE_QMD_FORK_DIR" ] && echo yes || echo no)" "no"
check "RED20b: --purge-state removes the global symlink" "$([ -L "$GLOBAL_DIR20B" ] && echo yes || echo no)" "no"
check "RED20b: --purge-state calls qmd collection remove qmd-vault" \
  "$(grep -c 'collection remove qmd-vault' "$CASE_DIR/qmd.log" 2>/dev/null || echo 0)" "1"
check "RED20b: --purge-state STILL never touches the stub" "$(cat "$STUB20B")" "$(cat "$SUITE_TMP/red20b-stub-before")"
check "RED20b: stub kept line still printed under --purge-state" \
  "$(printf '%s\n' "$out20b" | grep -c 'qmd plugin stub himmel patched')" "1"

echo "==== RED21 (HIMMEL-3332 slice3): pre-existing qmd (no qmd-fork ledger rows) survives both modes byte-identical ===="
# The real qmd-bin.sh only ever calls _qmd_prov_record when IT created the
# path (preexisted=false); a pre-existing fork/symlink/collection gets no row
# at all (scripts/lib/qmd-bin.sh lines 590-657). A ledger session that
# recorded something unrelated (so LEDGER_OK=1) but nothing for qmd-fork is
# the realistic pre-existing-qmd shape, not an absent ledger (that is RED22).
new_case red21a
CASE_QMD_FORK_DIR="$CASE_DIR/qmd-fork"
CASE_BUN_INSTALL="$CASE_DIR/bun"
mkdir -p "$CASE_QMD_FORK_DIR"
STAMP21A="$CASE_QMD_FORK_DIR/.himmel-build-ok"; printf 'preexisting\n' > "$STAMP21A"
GLOBAL_DIR21A="$CASE_BUN_INSTALL/install/global/node_modules/@tobilu/qmd"
mkdir -p "$(dirname "$GLOBAL_DIR21A")"
ln -s "$CASE_QMD_FORK_DIR" "$GLOBAL_DIR21A"
STUB21A="$CASE_DIR/stub-qmd-21a"; printf 'preexisting stub\n' > "$STUB21A"
cp "$STUB21A" "$SUITE_TMP/red21a-stub-before"
( prov_begin --writer install.sh -- seed-red21a >/dev/null
  prov_record noop json-key "$CASE_SETTINGS" --unit '/unrelated' --scope user --class code --row user-settings \
    --writer install.sh --pre-json 'null' --post-json 'null' --field preexisted=true >/dev/null
  prov_end ok >/dev/null )
out21a=$(run_uninstall --yes --skip-tasks --skip-plugins --skip-hooks); rc21a=$?
check "RED21a: uninstall exit status" "$rc21a" "0"
check "RED21a: default run keeps the fork checkout stamp byte-identical" "$(cat "$STAMP21A")" "preexisting"
check "RED21a: default run keeps the global symlink pointed at the fork dir" \
  "$(readlink "$GLOBAL_DIR21A" 2>/dev/null)" "$CASE_QMD_FORK_DIR"
check "RED21a: default run keeps the stub byte-identical" "$(cat "$STUB21A")" "$(cat "$SUITE_TMP/red21a-stub-before")"
check "RED21a: stub kept line printed" \
  "$(printf '%s\n' "$out21a" | grep -c 'qmd plugin stub himmel patched')" "1"

new_case red21b
CASE_QMD_FORK_DIR="$CASE_DIR/qmd-fork"
CASE_BUN_INSTALL="$CASE_DIR/bun"
mkdir -p "$CASE_QMD_FORK_DIR"
STAMP21B="$CASE_QMD_FORK_DIR/.himmel-build-ok"; printf 'preexisting\n' > "$STAMP21B"
GLOBAL_DIR21B="$CASE_BUN_INSTALL/install/global/node_modules/@tobilu/qmd"
mkdir -p "$(dirname "$GLOBAL_DIR21B")"
ln -s "$CASE_QMD_FORK_DIR" "$GLOBAL_DIR21B"
STUB21B="$CASE_DIR/stub-qmd-21b"; printf 'preexisting stub\n' > "$STUB21B"
cp "$STUB21B" "$SUITE_TMP/red21b-stub-before"
( prov_begin --writer install.sh -- seed-red21b >/dev/null
  prov_record noop json-key "$CASE_SETTINGS" --unit '/unrelated' --scope user --class code --row user-settings \
    --writer install.sh --pre-json 'null' --post-json 'null' --field preexisted=true >/dev/null
  prov_end ok >/dev/null )
out21b=$(run_uninstall --yes --purge-state --skip-tasks --skip-plugins --skip-hooks); rc21b=$?
check "RED21b: uninstall exit status" "$rc21b" "0"
check "RED21b: --purge-state still keeps a pre-existing fork checkout stamp byte-identical" "$(cat "$STAMP21B")" "preexisting"
check "RED21b: --purge-state still keeps the global symlink pointed at the fork dir" \
  "$(readlink "$GLOBAL_DIR21B" 2>/dev/null)" "$CASE_QMD_FORK_DIR"
check "RED21b: --purge-state never calls qmd collection remove for an unrecorded collection" \
  "$(grep -c 'collection remove' "$CASE_DIR/qmd.log" 2>/dev/null || echo 0)" "0"
check "RED21b: --purge-state still keeps the stub byte-identical" "$(cat "$STUB21B")" "$(cat "$SUITE_TMP/red21b-stub-before")"
check "RED21b: stub kept line still printed under --purge-state" \
  "$(printf '%s\n' "$out21b" | grep -c 'qmd plugin stub himmel patched')" "1"

echo "==== RED22 (HIMMEL-3332 slice3): no ledger at all -- --purge-state keeps qmd, it cannot tell installed from pre-existing ===="
new_case red22
CASE_QMD_FORK_DIR="$CASE_DIR/qmd-fork"
CASE_BUN_INSTALL="$CASE_DIR/bun"
mkdir -p "$CASE_QMD_FORK_DIR"
STAMP22="$CASE_QMD_FORK_DIR/.himmel-build-ok"; printf 'no-ledger\n' > "$STAMP22"
GLOBAL_DIR22="$CASE_BUN_INSTALL/install/global/node_modules/@tobilu/qmd"
mkdir -p "$(dirname "$GLOBAL_DIR22")"
ln -s "$CASE_QMD_FORK_DIR" "$GLOBAL_DIR22"
STUB22="$CASE_DIR/stub-qmd-22"; printf 'no-ledger stub\n' > "$STUB22"
cp "$STUB22" "$SUITE_TMP/red22-stub-before"
# no prov_begin/prov_record/prov_end at all -- a pre-ledger install.
out22=$(run_uninstall --yes --purge-state --skip-tasks --skip-plugins --skip-hooks); rc22=$?
check "RED22: uninstall exit status" "$rc22" "0"
check "RED22: --purge-state with no ledger keeps the fork checkout stamp byte-identical" "$(cat "$STAMP22")" "no-ledger"
check "RED22: --purge-state with no ledger keeps the global symlink pointed at the fork dir" \
  "$(readlink "$GLOBAL_DIR22" 2>/dev/null)" "$CASE_QMD_FORK_DIR"
check "RED22: --purge-state with no ledger never calls qmd collection remove" \
  "$(grep -c 'collection remove' "$CASE_DIR/qmd.log" 2>/dev/null || echo 0)" "0"
check "RED22: --purge-state with no ledger keeps the stub byte-identical" "$(cat "$STUB22")" "$(cat "$SUITE_TMP/red22-stub-before")"
check "RED22: no-ledger kept message printed" \
  "$(printf '%s\n' "$out22" | grep -c 'provenance cannot tell a himmel-created qmd')" "1"
check "RED22: stub kept line printed" \
  "$(printf '%s\n' "$out22" | grep -c 'qmd plugin stub himmel patched')" "1"

echo "==== RED23 (HIMMEL-3332 slice3 chief ruling 1): a redirected/tampered fork-checkout stamp path is refused, never rm -rf'd ===="
# The ledger's recorded path for the qmd-fork file-create row resolves
# OUTSIDE the expected fork dir (QMD_FORK_DIR at record time != at uninstall
# time, or a tampered row) -- qmd_unwire_fork_checkout must refuse rather
# than rm -rf whatever dirname(path) turns out to be.
new_case red23
CASE_QMD_FORK_DIR="$CASE_DIR/qmd-fork"
CASE_BUN_INSTALL="$CASE_DIR/bun"
mkdir -p "$CASE_QMD_FORK_DIR"
DECOY23="$CASE_DIR/decoy-dir"
mkdir -p "$DECOY23"
STAMP23="$DECOY23/.himmel-build-ok"; printf 'decoy\n' > "$STAMP23"
( prov_begin --writer install.sh -- seed-red23 >/dev/null
  prov_record create file "$STAMP23" --pre-absent --post-file "$STAMP23" --scope machine --class code \
    --row qmd-fork --writer qmd-bin.sh --field preexisted=false >/dev/null
  prov_end ok >/dev/null )
out23=$(run_uninstall --yes --purge-state --skip-tasks --skip-plugins --skip-hooks); rc23=$?
check "RED23: uninstall reports incomplete (halted) rather than a silent success" "$rc23" "2"
check "RED23: the decoy dir is NOT removed" "$([ -d "$DECOY23" ] && echo yes || echo no)" "yes"
check "RED23: the decoy stamp survives byte-identical" "$(cat "$STAMP23" 2>/dev/null)" "decoy"
check "RED23: a refusal warning is printed" \
  "$(printf '%s\n' "$out23" | grep -c 'refusing to remove unexpected path')" "1"

echo "==== RED24 (HIMMEL-3332 slice3 chief ruling 1): a noop (not create) fork-checkout row keeps the dir even under --purge-state ===="
new_case red24
CASE_QMD_FORK_DIR="$CASE_DIR/qmd-fork"
CASE_BUN_INSTALL="$CASE_DIR/bun"
mkdir -p "$CASE_QMD_FORK_DIR"
STAMP24="$CASE_QMD_FORK_DIR/.himmel-build-ok"; printf 'noop\n' > "$STAMP24"
( prov_begin --writer install.sh -- seed-red24 >/dev/null
  prov_record noop file "$STAMP24" --pre-file "$STAMP24" --post-file "$STAMP24" --scope machine --class code \
    --row qmd-fork --writer qmd-bin.sh --field preexisted=true >/dev/null
  prov_end ok >/dev/null )
out24=$(run_uninstall --yes --purge-state --skip-tasks --skip-plugins --skip-hooks); rc24=$?
check "RED24: uninstall exit status" "$rc24" "0"
check "RED24: a noop row keeps the fork checkout dir under --purge-state" "$([ -d "$CASE_QMD_FORK_DIR" ] && echo yes || echo no)" "yes"
check "RED24: a noop row keeps the stamp byte-identical" "$(cat "$STAMP24" 2>/dev/null)" "noop"
check "RED24: a noop row is reported kept, not removed" \
  "$(printf '%s\n' "$out24" | grep -c 'removed:.*qmd fork checkout')" "0"

echo "==== RED25 (HIMMEL-3332 slice3 chief ruling 1): a file-create row under a DIFFERENT row id is never touched by qmd dirname-removal ===="
# prov_read_units --row qmd-fork scopes the whole qmd unwire loop; a row filed
# under any other id must never reach qmd_unwire_fork_checkout, no matter its
# kind or ops. Prove it with a decoy dir that a matching bug WOULD remove.
new_case red25
CASE_QMD_FORK_DIR="$CASE_DIR/qmd-fork"
CASE_BUN_INSTALL="$CASE_DIR/bun"
mkdir -p "$CASE_QMD_FORK_DIR"
OTHERROW25="$CASE_DIR/other-row-dir"
mkdir -p "$OTHERROW25"
STAMP25="$OTHERROW25/.himmel-build-ok"; printf 'other-row\n' > "$STAMP25"
( prov_begin --writer install.sh -- seed-red25 >/dev/null
  prov_record create file "$STAMP25" --pre-absent --post-file "$STAMP25" --scope machine --class code \
    --row not-qmd-fork --writer qmd-bin.sh --field preexisted=false >/dev/null
  prov_end ok >/dev/null )
out25=$(run_uninstall --yes --purge-state --skip-tasks --skip-plugins --skip-hooks); rc25=$?
check "RED25: uninstall exit status" "$rc25" "0"
check "RED25: a file row under a different row id is never removed" "$([ -d "$OTHERROW25" ] && echo yes || echo no)" "yes"
check "RED25: its stamp survives byte-identical" "$(cat "$STAMP25" 2>/dev/null)" "other-row"
check "RED25: the qmd unwire loop never even mentions the other-row path" \
  "$(printf '%s\n' "$out25" | grep -c "$OTHERROW25")" "0"

echo "==== RED26 (HIMMEL-3332 slice3, critic panel codex-1): qmd collection remove runs before the fork checkout/symlink are unwired ===="
# A real qmd_cmd resolves through the bun-global symlink into the fork
# checkout's dist/cli/qmd.js, or (failing that) a `qmd` already on PATH.
# Removing the fork checkout or the global symlink before calling `qmd
# collection remove` can leave `qmd_cmd` unable to resolve at all in a real
# install. QMD_ORDER_CHECK_FORK_DIR/QMD_ORDER_CHECK_SYMLINK make the fake qmd
# stub fail exactly the way a real one would if the unwire loop got the order
# wrong, independent of which path a real qmd_cmd would have taken.
new_case red26
CASE_QMD_FORK_DIR="$CASE_DIR/qmd-fork"
CASE_BUN_INSTALL="$CASE_DIR/bun"
# a real fork checkout is always a git work tree; a plain
# directory is the "unknown state" the fix now keeps rather than removes, so
# this --purge-state-removes fixture needs a clean git checkout to reach rm.
_red_seed_git_fork "$CASE_QMD_FORK_DIR"
STAMP26="$CASE_QMD_FORK_DIR/.himmel-build-ok"
GLOBAL_DIR26="$CASE_BUN_INSTALL/install/global/node_modules/@tobilu/qmd"
mkdir -p "$(dirname "$GLOBAL_DIR26")"
ln -s "$CASE_QMD_FORK_DIR" "$GLOBAL_DIR26"
CASE_QMD_ORDER_CHECK_FORK_DIR="$CASE_QMD_FORK_DIR"
CASE_QMD_ORDER_CHECK_SYMLINK="$GLOBAL_DIR26"
CASE_QMD_COLLECTION_PATH="$CASE_QMD_FORK_DIR"
( prov_begin --writer install.sh -- seed-red26 >/dev/null
  prov_record create file "$STAMP26" --pre-absent --post-file "$STAMP26" --scope machine --class code \
    --row qmd-fork --writer qmd-bin.sh --field preexisted=false >/dev/null
  prov_record create symlink "$GLOBAL_DIR26" --post-text "$CASE_QMD_FORK_DIR" --scope machine --class code \
    --row qmd-fork --writer qmd-bin.sh --field preexisted=false >/dev/null
  prov_record register collection - --unit qmd-vault --post-text "$CASE_QMD_FORK_DIR" --scope machine --class code \
    --row qmd-fork --writer qmd-bin.sh --field preexisted=false >/dev/null
  prov_end ok >/dev/null )
out26=$(run_uninstall --yes --purge-state --skip-tasks --skip-plugins --skip-hooks); rc26=$?
check "RED26: uninstall exit status (collection remove succeeded while fork/symlink still resolved)" "$rc26" "0"
check "RED26: --purge-state still removes the fork checkout dir" "$([ -e "$CASE_QMD_FORK_DIR" ] && echo yes || echo no)" "no"
check "RED26: --purge-state still removes the global symlink" "$([ -L "$GLOBAL_DIR26" ] && echo yes || echo no)" "no"
check "RED26: --purge-state still calls qmd collection remove qmd-vault" \
  "$(grep -c 'collection remove qmd-vault' "$CASE_DIR/qmd.log" 2>/dev/null || echo 0)" "1"
check "RED26: the fake qmd never saw the fork checkout already removed" \
  "$(printf '%s\n' "$out26" | grep -c 'already removed')" "0"

echo "==== RED27 (HIMMEL-3524): a qmd fork checkout carrying user work is kept, never rm -rf'd, even under --purge-state ===="
# qmd_unwire_fork_checkout's ledger verdict only proves himmel CREATED the
# checkout; it says nothing about what has happened in it since. A real fork
# checkout is a git work tree, so the fix checks its live git state before
# removing it: a dirty tree (tracked-file edit or untracked file) or an
# unpushed local commit is user work the ledger cannot see, and must be kept.
new_case red27a
CASE_QMD_FORK_DIR="$CASE_DIR/qmd-fork"
_red_seed_git_fork "$CASE_QMD_FORK_DIR"
( prov_begin --writer install.sh -- seed-red27a >/dev/null
  prov_record create file "$CASE_QMD_FORK_DIR/.himmel-build-ok" --pre-absent --post-file "$CASE_QMD_FORK_DIR/.himmel-build-ok" \
    --scope machine --class code --row qmd-fork --writer qmd-bin.sh --field preexisted=false >/dev/null
  prov_end ok >/dev/null )
out27a=$(run_uninstall --yes --purge-state --skip-tasks --skip-plugins --skip-hooks); rc27a=$?
check "RED27a: uninstall exit status" "$rc27a" "0"
check "RED27a: a clean git fork checkout IS removed under --purge-state" "$([ -e "$CASE_QMD_FORK_DIR" ] && echo yes || echo no)" "no"
check "RED27a: a removed line is printed" \
  "$(printf '%s\n' "$out27a" | grep -c 'removed:.*qmd fork checkout')" "1"

new_case red27b
CASE_QMD_FORK_DIR="$CASE_DIR/qmd-fork"
_red_seed_git_fork "$CASE_QMD_FORK_DIR"
printf 'edited by the user\n' > "$CASE_QMD_FORK_DIR/tracked.txt"
( prov_begin --writer install.sh -- seed-red27b >/dev/null
  prov_record create file "$CASE_QMD_FORK_DIR/.himmel-build-ok" --pre-absent --post-file "$CASE_QMD_FORK_DIR/.himmel-build-ok" \
    --scope machine --class code --row qmd-fork --writer qmd-bin.sh --field preexisted=false >/dev/null
  prov_end ok >/dev/null )
out27b=$(run_uninstall --yes --purge-state --skip-tasks --skip-plugins --skip-hooks); rc27b=$?
check "RED27b: uninstall exit status" "$rc27b" "0"
check "RED27b: a fork checkout with a modified tracked file is KEPT under --purge-state" \
  "$([ -e "$CASE_QMD_FORK_DIR" ] && echo yes || echo no)" "yes"
check "RED27b: the edit survives byte-identical" "$(cat "$CASE_QMD_FORK_DIR/tracked.txt")" "edited by the user"
check "RED27b: a user-modified kept line is printed" \
  "$(printf '%s\n' "$out27b" | grep -c 'kept:.*user-modified: uncommitted changes')" "1"

new_case red27c
CASE_QMD_FORK_DIR="$CASE_DIR/qmd-fork"
_red_seed_git_fork "$CASE_QMD_FORK_DIR"
printf 'new file\n' > "$CASE_QMD_FORK_DIR/untracked.txt"
( prov_begin --writer install.sh -- seed-red27c >/dev/null
  prov_record create file "$CASE_QMD_FORK_DIR/.himmel-build-ok" --pre-absent --post-file "$CASE_QMD_FORK_DIR/.himmel-build-ok" \
    --scope machine --class code --row qmd-fork --writer qmd-bin.sh --field preexisted=false >/dev/null
  prov_end ok >/dev/null )
out27c=$(run_uninstall --yes --purge-state --skip-tasks --skip-plugins --skip-hooks); rc27c=$?
check "RED27c: uninstall exit status" "$rc27c" "0"
check "RED27c: a fork checkout with an untracked file is KEPT under --purge-state" \
  "$([ -e "$CASE_QMD_FORK_DIR" ] && echo yes || echo no)" "yes"
check "RED27c: the untracked file survives" "$([ -f "$CASE_QMD_FORK_DIR/untracked.txt" ] && echo yes || echo no)" "yes"
check "RED27c: a user-modified kept line is printed" \
  "$(printf '%s\n' "$out27c" | grep -c 'kept:.*user-modified: uncommitted changes')" "1"

new_case red27d
CASE_QMD_FORK_DIR="$CASE_DIR/qmd-fork"
_red_seed_git_fork "$CASE_QMD_FORK_DIR"
printf 'local work\n' > "$CASE_QMD_FORK_DIR/tracked.txt"
git -C "$CASE_QMD_FORK_DIR" commit -q -am "local unpushed commit"
( prov_begin --writer install.sh -- seed-red27d >/dev/null
  prov_record create file "$CASE_QMD_FORK_DIR/.himmel-build-ok" --pre-absent --post-file "$CASE_QMD_FORK_DIR/.himmel-build-ok" \
    --scope machine --class code --row qmd-fork --writer qmd-bin.sh --field preexisted=false >/dev/null
  prov_end ok >/dev/null )
out27d=$(run_uninstall --yes --purge-state --skip-tasks --skip-plugins --skip-hooks); rc27d=$?
check "RED27d: uninstall exit status" "$rc27d" "0"
check "RED27d: a fork checkout with an unpushed local commit is KEPT under --purge-state" \
  "$([ -e "$CASE_QMD_FORK_DIR" ] && echo yes || echo no)" "yes"
check "RED27d: a user-modified kept line is printed" \
  "$(printf '%s\n' "$out27d" | grep -c 'kept:.*user-modified: unpushed local commits')" "1"

echo "==== RED28 (HIMMEL-3534): a qmd fork checkout carrying user data in a git-ignored path is kept ===="
# an earlier change's git-dirty check (RED27) is blind to ignored paths --
# `status --porcelain` never lists them, so a user file placed inside one
# (next to node_modules/ or dist/) read as clean and was silently rm -rf'd.
# The fix diffs ignored paths against an allowlist of what the fork's own
# build creates (node_modules/, dist/): anything else ignored is user work.

new_case red28a
CASE_QMD_FORK_DIR="$CASE_DIR/qmd-fork"
_red_seed_git_fork "$CASE_QMD_FORK_DIR"
# Only the build's own output present -- a real built fork, nothing else.
mkdir -p "$CASE_QMD_FORK_DIR/node_modules" "$CASE_QMD_FORK_DIR/dist"
printf 'pkg\n' > "$CASE_QMD_FORK_DIR/node_modules/pkg.js"
printf 'out\n' > "$CASE_QMD_FORK_DIR/dist/out.js"
( prov_begin --writer install.sh -- seed-red28a >/dev/null
  prov_record create file "$CASE_QMD_FORK_DIR/.himmel-build-ok" --pre-absent --post-file "$CASE_QMD_FORK_DIR/.himmel-build-ok" \
    --scope machine --class code --row qmd-fork --writer qmd-bin.sh --field preexisted=false >/dev/null
  prov_end ok >/dev/null )
out28a=$(run_uninstall --yes --purge-state --skip-tasks --skip-plugins --skip-hooks); rc28a=$?
check "RED28a: uninstall exit status" "$rc28a" "0"
check "RED28a: a fork checkout holding only allowlisted build output IS removed under --purge-state" \
  "$([ -e "$CASE_QMD_FORK_DIR" ] && echo yes || echo no)" "no"
check "RED28a: a removed line is printed" \
  "$(printf '%s\n' "$out28a" | grep -c 'removed:.*qmd fork checkout')" "1"

new_case red28b
CASE_QMD_FORK_DIR="$CASE_DIR/qmd-fork"
_red_seed_git_fork "$CASE_QMD_FORK_DIR"
# A user file dropped into a git-ignored path OUTSIDE the build's allowlist
# (not node_modules/ or dist/) -- e.g. next to the fork's own build output,
# matching the ticket's "a stray personal note" example.
mkdir -p "$CASE_QMD_FORK_DIR/notes"
printf 'secret user note\n' > "$CASE_QMD_FORK_DIR/notes/mine.txt"
( prov_begin --writer install.sh -- seed-red28b >/dev/null
  prov_record create file "$CASE_QMD_FORK_DIR/.himmel-build-ok" --pre-absent --post-file "$CASE_QMD_FORK_DIR/.himmel-build-ok" \
    --scope machine --class code --row qmd-fork --writer qmd-bin.sh --field preexisted=false >/dev/null
  prov_end ok >/dev/null )
out28b=$(run_uninstall --yes --purge-state --skip-tasks --skip-plugins --skip-hooks); rc28b=$?
check "RED28b: uninstall exit status" "$rc28b" "0"
check "RED28b: a fork checkout with a user file in an ignored path outside the allowlist is KEPT under --purge-state" \
  "$([ -e "$CASE_QMD_FORK_DIR" ] && echo yes || echo no)" "yes"
check "RED28b: the user's note survives" "$(cat "$CASE_QMD_FORK_DIR/notes/mine.txt")" "secret user note"
check "RED28b: a user-modified kept line is printed" \
  "$(printf '%s\n' "$out28b" | grep -c 'kept:.*user-modified: ignored files outside the build output')" "1"

new_case red28c
CASE_QMD_FORK_DIR="$CASE_DIR/qmd-fork"
_red_seed_git_fork "$CASE_QMD_FORK_DIR"
# A user file placed INSIDE an allowlisted dir (node_modules/) is still
# removed with the rest of the checkout -- the documented trade-off: the
# allowlist trusts the build's own directories wholesale, it does not
# distinguish a stray file from real build output within them.
mkdir -p "$CASE_QMD_FORK_DIR/node_modules"
printf 'not really a package\n' > "$CASE_QMD_FORK_DIR/node_modules/users-own-file.txt"
( prov_begin --writer install.sh -- seed-red28c >/dev/null
  prov_record create file "$CASE_QMD_FORK_DIR/.himmel-build-ok" --pre-absent --post-file "$CASE_QMD_FORK_DIR/.himmel-build-ok" \
    --scope machine --class code --row qmd-fork --writer qmd-bin.sh --field preexisted=false >/dev/null
  prov_end ok >/dev/null )
out28c=$(run_uninstall --yes --purge-state --skip-tasks --skip-plugins --skip-hooks); rc28c=$?
check "RED28c: uninstall exit status" "$rc28c" "0"
check "RED28c: a user file inside an allowlisted build dir (node_modules/) is REMOVED with the checkout" \
  "$([ -e "$CASE_QMD_FORK_DIR" ] && echo yes || echo no)" "no"
check "RED28c: a removed line is printed" \
  "$(printf '%s\n' "$out28c" | grep -c 'removed:.*qmd fork checkout')" "1"

echo "==== RED29 (HIMMEL-3534, regression from HIMMEL-3524/#1175): the build stamp itself never blocks removal ===="
# _qmd_build_stamp (scripts/lib/qmd-bin.sh:82) writes .himmel-build-ok
# untracked at the fork root on every successful build. RED27's dirty-tree
# check (`status --porcelain --untracked-files=normal`) read that file as an
# untracked change on EVERY built fork, so --purge-state never removed one --
# _red_seed_git_fork now seeds the stamp on every case (matching a real
# build), which is what makes RED27a/26/20b exercise this path too.
new_case red29a
CASE_QMD_FORK_DIR="$CASE_DIR/qmd-fork"
_red_seed_git_fork "$CASE_QMD_FORK_DIR"
( prov_begin --writer install.sh -- seed-red29a >/dev/null
  prov_record create file "$CASE_QMD_FORK_DIR/.himmel-build-ok" --pre-absent --post-file "$CASE_QMD_FORK_DIR/.himmel-build-ok" \
    --scope machine --class code --row qmd-fork --writer qmd-bin.sh --field preexisted=false >/dev/null
  prov_end ok >/dev/null )
out29a=$(run_uninstall --yes --purge-state --skip-tasks --skip-plugins --skip-hooks); rc29a=$?
check "RED29a: uninstall exit status" "$rc29a" "0"
check "RED29a: a freshly built (stamp-only-dirty) fork checkout IS removed under --purge-state" \
  "$([ -e "$CASE_QMD_FORK_DIR" ] && echo yes || echo no)" "no"
check "RED29a: never reports the stamp itself as a user modification" \
  "$(printf '%s\n' "$out29a" | grep -c 'kept:.*user-modified')" "0"

echo "==== RED30 (HIMMEL-3525 S16 case f): a collection re-pointed after install survives --purge-state ===="
# The install recorded the collection's live identity token (name, canonical
# path, pattern) read back from qmd; the user then re-pointed the same name at
# another vault. The verdict re-reads the live identity, finds a token himmel
# never recorded, and keeps the collection. The control keeps the live path
# where the install left it, and the collection is removed.
tok30=$(printf 'collection\nqmd-vault\n/vaultA\n**/*.md' | _prov_sha256)
for sub in repointed control; do
  new_case "red30-$sub"
  ( prov_begin --writer install.sh -- "seed-red30-$sub" >/dev/null
    prov_record register collection - --unit qmd-vault --post-text "$tok30" --scope machine --class code \
      --row qmd-fork --writer qmd-bin.sh --field preexisted=false --field identity_v=1 >/dev/null
    prov_end ok >/dev/null )
  if [ "$sub" = repointed ]; then CASE_QMD_COLLECTION_PATH=/vaultB; want=0; else CASE_QMD_COLLECTION_PATH=/vaultA; want=1; fi
  run_uninstall --yes --purge-state --skip-tasks --skip-plugins --skip-hooks >/dev/null; rc30=$?
  check "RED30 $sub: uninstall exit status" "$rc30" "0"
  check "RED30 $sub: qmd collection remove qmd-vault called $want time(s)" \
    "$(grep -c 'collection remove qmd-vault' "$CASE_DIR/qmd.log" 2>/dev/null)" "$want"
  check "RED30 $sub: the verdict read the live identity" \
    "$(grep -c 'collection show qmd-vault' "$CASE_DIR/qmd.log" 2>/dev/null)" "1"
done
unset rc30 tok30 want

echo "==== RED31 (HIMMEL-3525 S17): a plugin/marketplace re-pointed after install survives --purge-state ===="
# Install recorded the marketplace's + plugin's live identity token (design
# §3.2/§3.3); the plugin's own identity folds in the marketplace's live
# token, so re-pointing the marketplace alone is enough to keep BOTH rows --
# no separate cascade logic needed. The control leaves the marketplace
# source where install left it: both remove.
new_case red31-tok
# shellcheck disable=SC2031  # HOME is new_case's top-level export, not a subshell leak
mkdir -p "$HOME/.claude/plugins"
# shellcheck disable=SC2031  # HOME is new_case's top-level export, not a subshell leak
printf '{"himmel":{"source":{"source":"directory","path":"/clone"}}}\n' > "$HOME/.claude/plugins/known_marketplaces.json"
# shellcheck disable=SC2031  # HOME is new_case's top-level export, not a subshell leak
printf '{"version":2,"plugins":{"himmel-ops@himmel":[{"scope":"user"}]}}\n' > "$HOME/.claude/plugins/installed_plugins.json"
mkt_tok31=$(_provid_marketplace '{"unit":"himmel"}')
plug_tok31=$(_provid_plugin '{"unit":"himmel-ops@himmel","fields":{"cli_scope":"user","project_path":"","marketplace":"himmel"}}')

for sub in repointed control; do
  new_case "red31-$sub"
  # shellcheck disable=SC2031  # HOME is new_case's top-level export, not a subshell leak
  mkdir -p "$HOME/.claude/plugins"
  if [ "$sub" = repointed ]; then
    # shellcheck disable=SC2031  # HOME is new_case's top-level export, not a subshell leak
    printf '{"himmel":{"source":{"source":"directory","path":"/elsewhere"}}}\n' > "$HOME/.claude/plugins/known_marketplaces.json"
  else
    # shellcheck disable=SC2031  # HOME is new_case's top-level export, not a subshell leak
    printf '{"himmel":{"source":{"source":"directory","path":"/clone"}}}\n' > "$HOME/.claude/plugins/known_marketplaces.json"
  fi
  # shellcheck disable=SC2031  # HOME is new_case's top-level export, not a subshell leak
  printf '{"version":2,"plugins":{"himmel-ops@himmel":[{"scope":"user"}]}}\n' > "$HOME/.claude/plugins/installed_plugins.json"
  ( prov_begin --writer install-plugins.sh -- "seed-red31-$sub" >/dev/null
    prov_record register marketplace - --unit himmel --scope machine --class code \
      --writer install-plugins.sh --row marketplaces --field 'cli_scope="user"' --field preexisted=false \
      --post-text "$mkt_tok31" --field identity_v=1 >/dev/null
    prov_record register plugin - --unit himmel-ops@himmel --scope machine --class code \
      --writer install-plugins.sh --row plugins --field 'cli_scope="user"' --field 'marketplace="himmel"' \
      --field 'project_path=""' --field preexisted=false \
      --post-text "$plug_tok31" --field identity_v=1 >/dev/null
    prov_end ok >/dev/null )
  printf '[{"id":"himmel-ops@himmel","scope":"user"}]\n' > "$CASE_PLUGINS_JSON"
  printf '[{"name":"himmel"}]\n' > "$CASE_MARKETPLACES_JSON"
  out31=$(run_uninstall --yes --purge-state --skip-tasks --skip-hooks --skip-settings); rc31=$?
  check "RED31 $sub: uninstall exit status" "$rc31" "0"
  if [ "$sub" = repointed ]; then
    check "RED31 $sub: marketplace kept (changed since install)" \
      "$(printf '%s\n' "$out31" | grep -c 'kept (changed since install): himmel$')" "1"
    check "RED31 $sub: plugin kept (changed since install)" \
      "$(printf '%s\n' "$out31" | grep -c 'kept (changed since install): himmel-ops@himmel$')" "1"
    check "RED31 $sub: plugin left installed" \
      "$(jq -r '[.[] | select(.id=="himmel-ops@himmel")] | length' "$CASE_PLUGINS_JSON")" "1"
    check "RED31 $sub: marketplace left registered" \
      "$(jq -r '[.[] | select(.name=="himmel")] | length' "$CASE_MARKETPLACES_JSON")" "1"
  else
    check "RED31 $sub: plugin removed" \
      "$(jq -r '[.[] | select(.id=="himmel-ops@himmel")] | length' "$CASE_PLUGINS_JSON")" "0"
    check "RED31 $sub: marketplace removed" \
      "$(jq -r '[.[] | select(.name=="himmel")] | length' "$CASE_MARKETPLACES_JSON")" "0"
  fi
done
unset mkt_tok31 plug_tok31 rc31 out31

echo "==== RED32 (HIMMEL-3525 S18): a cron line edited after install survives --purge-state ===="
# Install recorded the LIVE crontab line's identity token (marker-suffixed
# line, design §3.4); the user then hand-edited that line (same marker,
# different schedule). At base (a816d911) ledger_job_markers emits every
# recorded marker unconditionally with no identity check, so the edited line
# is stripped anyway (see the RED-at-base excerpt in the PR body). The
# verdict now re-reads the live crontab, finds a token himmel never
# recorded, and keeps the line. The control leaves the line exactly where
# install left it: it is removed. A duplicated marker (two lines ending in
# the same marker) is never resolved to one at random: kept,
# identity-unreadable.
tok32=$(printf 'job\n0 3 * * * run.sh # HIMMEL-Qmd-Reindex' | _prov_sha256)
for sub in edited control duplicated; do
  new_case "red32-$sub"
  ( prov_begin --writer cadence-arm -- "seed-red32-$sub" >/dev/null
    prov_record register job - --unit HIMMEL-Qmd-Reindex --scope user --class code \
      --writer cadence-arm --field 'scheduler="cron"' --field preexisted=false \
      --post-text "$tok32" --field identity_v=1 >/dev/null
    prov_end ok >/dev/null )
  CASE_CRONTAB_FILE="$CASE_DIR/crontab.txt"
  case "$sub" in
    edited)     printf '0 4 * * * run.sh # HIMMEL-Qmd-Reindex\n' > "$CASE_CRONTAB_FILE" ;;
    control)    printf '0 3 * * * run.sh # HIMMEL-Qmd-Reindex\n' > "$CASE_CRONTAB_FILE" ;;
    duplicated) printf '0 3 * * * run.sh # HIMMEL-Qmd-Reindex\n0 5 * * * other.sh # HIMMEL-Qmd-Reindex\n' > "$CASE_CRONTAB_FILE" ;;
  esac
  out32=$(run_uninstall --yes --skip-plugins --skip-hooks --skip-settings); rc32=$?
  check "RED32 $sub: uninstall exit status" "$rc32" "0"
  case "$sub" in
    edited)
      check "RED32 $sub: kept cron line (user-modified)" \
        "$(printf '%s\n' "$out32" | grep -c 'kept cron line HIMMEL-Qmd-Reindex (user-modified)')" "1"
      check "RED32 $sub: the edited line survives in the crontab" \
        "$(cat "$CASE_CRONTAB_FILE")" "0 4 * * * run.sh # HIMMEL-Qmd-Reindex" ;;
    control)
      check "RED32 $sub: removed cron job reported" \
        "$(printf '%s\n' "$out32" | grep -c 'removed cron job: HIMMEL-Qmd-Reindex')" "1"
      check "RED32 $sub: the line is gone from the crontab" \
        "$(cat "$CASE_CRONTAB_FILE")" "" ;;
    duplicated)
      check "RED32 $sub: kept cron line (identity-unreadable)" \
        "$(printf '%s\n' "$out32" | grep -c 'kept cron line HIMMEL-Qmd-Reindex (identity-unreadable)')" "1"
      check "RED32 $sub: both duplicated lines survive" \
        "$(wc -l < "$CASE_CRONTAB_FILE" | tr -d ' ')" "2" ;;
  esac
done
unset tok32 rc32 out32


uninstall_prov_finish
