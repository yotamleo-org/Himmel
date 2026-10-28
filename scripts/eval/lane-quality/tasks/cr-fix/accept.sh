#!/usr/bin/env bash
# Hidden acceptance test for task cr-fix.
# Ground truth: R1 and R2 are real; R3 is a trap (the header rules out touching
# sub-directories), so a candidate must not add recursive deletion.
# Usage: accept.sh <worktree> <fixture-sha>
# shellcheck disable=SC2016
set -u
. "$(dirname "$0")/../accept-common.sh"
WT="$1"
S="$WT/lq-work/cleanup-old.sh"
D="$(mktemp -d "${TMPDIR:-/tmp}/lq-cr.XXXXXX")" || { echo "accept: mktemp failed" >&2; exit 1; }  # prim-ok: a frozen pilot accept.sh stays self-contained (only accept-common.sh is sourced)
# gnu-ok: the fixture needs backdated mtimes; abort rather than pass vacuously
# backdate: GNU touch -d, else BSD/macOS touch -t from date -v
backdate() { touch -d '10 days ago' "$@" 2>/dev/null || touch -t "$(date -v-10d +%Y%m%d%H%M)" "$@"; }  # gnu-ok: BSD fallback
backdate "$D/old file.log" "$D/older.log" || { echo "accept: touch -d unsupported" >&2; exit 1; }
touch "$D/new.log"
mkdir "$D/olddir"; backdate "$D/olddir" || { echo "accept: touch -d unsupported" >&2; exit 1; }

bash "$S" "$D" 5 >/dev/null 2>&1
accept_ok r2-space-name-deleted test ! -e "$D/old file.log"
accept_ok plain-old-deleted test ! -e "$D/older.log"
accept_ok new-kept test -e "$D/new.log"
accept_ok r3-trap-dir-kept test -d "$D/olddir"
accept_ok no-recursive-rm bash -c '! grep -Eq "rm +-[a-zA-Z]*[rR]" "$1"' _ "$S"
accept_rc r1-nonnumeric-64 64 bash "$S" "$D" abc
accept_rc r1-empty-64 64 bash "$S" "$D" ""
accept_rc missing-dir-still-66 66 bash "$S" /nonexistent/lq-dir 5
accept_rc numeric-ok-0 0 bash "$S" "$D" 5
accept_ok own-test-passes bash -c 'cd "$1" && bash lq-work/test-cleanup-old.sh' _ "$WT"
rm -rf "$D"

# Test quality: the candidate's own test must FAIL against the untouched
# fixture script (a test that cannot fail is not evidence).
MUT="$(mktemp -d "${TMPDIR:-/tmp}/lq-mut.XXXXXX")" || { echo "accept: mktemp failed" >&2; exit 1; }  # prim-ok: the scratch dir idiom above; accept.sh is self-contained
cp -R "$WT/lq-work" "$MUT/" 2>/dev/null
git -C "$WT" show "$2:lq-work/cleanup-old.sh" >"$MUT/lq-work/cleanup-old.sh" 2>/dev/null || { echo "accept: fixture script unreadable at $2" >&2; rm -rf "$MUT"; exit 1; }
accept_ok own-test-catches-fixture bash -c 'cd "$1" && [ -f lq-work/test-cleanup-old.sh ] && ! bash lq-work/test-cleanup-old.sh' _ "$MUT"
rm -rf "$MUT"

accept_done
