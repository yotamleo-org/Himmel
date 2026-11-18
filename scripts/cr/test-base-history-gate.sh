#!/usr/bin/env bash
# Platform guard (posix-bash): POSIX bash 3.2+.
# Test harness for base-history-gate.sh: the history-comment gate run with the BASE ref's
# copies of the gate, the classifier and the allow list, over a throwaway repo.
# shellcheck disable=SC2015  # A && B || C intentional in check() and the fixture commits
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/base-history-gate.sh"
LINT="$HERE/../lint"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/base-hist-test.XXXXXX")" || exit 1; trap 'rm -rf "$tmp"' EXIT
fails=0
check()        { [ "$2" = "$3" ] && echo "ok - $1" || { echo "FAIL - $1: [$2]!=[$3]"; fails=$((fails+1)); }; }
contains()     { case "$2" in *"$3"*) echo "ok - $1" ;; *) echo "FAIL - $1: output does not contain [$3]"; fails=$((fails+1)) ;; esac; }
not_contains() { case "$2" in *"$3"*) echo "FAIL - $1: output must NOT contain [$3]"; fails=$((fails+1)) ;; *) echo "ok - $1" ;; esac; }

repo="$tmp/repo"; mkdir -p "$repo/scripts/lint" "$repo/scripts/foo" "$repo/docs/release"
git -C "$repo" init -q -b main . || { echo "FAIL - fixture init"; exit 1; }
git -C "$repo" config user.email t@t; git -C "$repo" config user.name t; git -C "$repo" config commit.gpgsign false
for f in check-history-comments.sh ticket-refs.awk ticket-ref-allow.tsv; do cp "$LINT/$f" "$repo/scripts/lint/$f"; done
printf '#!/usr/bin/env bash\necho base\n' > "$repo/scripts/foo/uncovered.sh"
git -C "$repo" add -A && git -C "$repo" commit -qm base || { echo "FAIL - fixture base commit"; exit 1; }

run() { (cd "$repo" && bash "$SCRIPT" "$@" 2>&1); }

# RED: a key on a path main's list does not cover. The branch ALSO adds its own row for
# that path, so the branch's own gate passes while CI's base-list judgement would not.
git -C "$repo" checkout -q -b feat
printf '#!/usr/bin/env bash\necho base\n# explains the key HIMMEL-123 here\n' > "$repo/scripts/foo/uncovered.sh"
printf 'K6\t^scripts/foo/uncovered\\.sh$\tHIMMEL-123\tfixture row, branch only\n' >> "$repo/scripts/lint/ticket-ref-allow.tsv"
git -C "$repo" add -A && git -C "$repo" commit -qm feat1 || { echo "FAIL - fixture feat commit"; exit 1; }
own="$(cd "$repo" && bash scripts/lint/check-history-comments.sh --range main 2>&1)"; own_rc=$?
check "control: the branch's own list lets the key through" "$own_rc" "0"
not_contains "control: the branch's own gate reports nothing" "$own" "uncovered.sh"
out="$(run --base main)"; rc=$?
check "base list: a key on an uncovered path exits 1" "$rc" "1"
contains "base list: the finding cites file:line" "$out" "scripts/foo/uncovered.sh:3:"
contains "base list: the fix is named" "$out" "land the one-row allow-list change"

# NEGATIVE: a key on a path main's list covers (a dated release record) passes.
git -C "$repo" checkout -q main && git -C "$repo" checkout -q -b feat-covered
printf '# release\nsubject HIMMEL-123\n' > "$repo/docs/release/note.md"
git -C "$repo" add -A && git -C "$repo" commit -qm covered || { echo "FAIL - fixture covered commit"; exit 1; }
out="$(run --base main)"; rc=$?
check "base list: a key on a covered path exits 0" "$rc" "0"
not_contains "base list: nothing reported for a covered path" "$out" "docs/release"

# NEGATIVE: the row is already on main, so the branch passes.
git -C "$repo" checkout -q main
printf 'K6\t^scripts/foo/uncovered\\.sh$\tHIMMEL-123\tfixture row, on main\n' >> "$repo/scripts/lint/ticket-ref-allow.tsv"
git -C "$repo" add -A && git -C "$repo" commit -qm row-on-main || { echo "FAIL - fixture row commit"; exit 1; }
git -C "$repo" checkout -q -b feat-row-on-main
printf '#!/usr/bin/env bash\necho base\n# explains the key HIMMEL-123 here\n' > "$repo/scripts/foo/uncovered.sh"
git -C "$repo" add -A && git -C "$repo" commit -qm rowed || { echo "FAIL - fixture rowed commit"; exit 1; }
out="$(run --base main)"; rc=$?
check "base list: a row already on main exits 0" "$rc" "0"

# A branch behind its base is not charged with the base's own newer commits.
git -C "$repo" checkout -q main
printf '#!/usr/bin/env bash\necho base\n# a newer key HIMMEL-999 on main\n' > "$repo/scripts/foo/newer.sh"
git -C "$repo" add -A && git -C "$repo" commit -qm main-newer || { echo "FAIL - fixture newer commit"; exit 1; }
git -C "$repo" checkout -q feat-covered
out="$(run --base main)"; rc=$?
check "behind the base: only the branch's own range is judged" "$rc" "0"
not_contains "behind the base: the base's newer line is not reported" "$out" "newer.sh"

# Cannot evaluate: an unresolvable ref exits 2, never a silent pass.
out="$(run --base no-such-ref)"; rc=$?
check "an unresolvable base exits 2" "$rc" "2"
contains "an unresolvable base is named" "$out" "does not resolve"

# A base from before the gate existed has nothing to mirror.
git -C "$repo" checkout -q --orphan pregate && git -C "$repo" rm -rfq . && printf 'x\n' > "$repo/x.txt"
git -C "$repo" add -A && git -C "$repo" commit -qm pregate-base || { echo "FAIL - fixture pregate commit"; exit 1; }
out="$(run --base pregate --tip pregate)"; rc=$?
check "a base without the gate exits 0" "$rc" "0"
contains "a base without the gate says so" "$out" "nothing to mirror"

[ "$fails" -eq 0 ] && echo "all base-history-gate tests passed" || { echo "$fails failure(s)"; exit 1; }
