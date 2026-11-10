#!/usr/bin/env bash
# scripts/handover/chief-kit/test-close-facts.sh - suite: close-facts.sh, the
# local merged-or-not proof a worker close feeds to `worktree.sh prune --only
# --pr-cache`.
#
# Platform guard: Linux/macOS bash 3.2+ (git 2.38+ for `merge-tree --write-tree`).
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
CF="$HERE/close-facts.sh"
REAL_GIT="$(command -v git)"

W="$(mktemp -d "${TMPDIR:-/tmp}/close-facts-test.XXXXXX")" || { echo "FAIL: mktemp -d failed" >&2; exit 1; }
trap 'rm -rf "$W"' EXIT
unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null GIT_TERMINAL_PROMPT=0

pass=0; fails=0
ok()   { echo "  PASS: $1"; pass=$((pass+1)); }
bad()  { echo "  FAIL: $1"; [ $# -lt 2 ] || printf '    %s\n' "$2"; fails=$((fails+1)); }
check()    { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "[$2] != [$3]"; fi; }
contains() { if grep -q -F -e "$3" <<< "$2"; then ok "$1"; else bad "$1" "output does not contain [$3]: $2"; fi; }

if [ ! -f "$CF" ]; then
    bad "close-facts.sh exists" "$CF is missing"
    echo "test-close-facts: $pass passed, $fails failed"
    exit 1
fi
# shellcheck source=scripts/handover/chief-kit/close-facts.sh
. "$CF" || { bad "close-facts.sh sources"; exit 1; }

mkdir -p "$W/bin-gh"
GH_LOG="$W/gh.log"
cat > "$W/bin-gh/gh" <<STUB
#!/usr/bin/env bash
echo "gh \$*" >> "$GH_LOG"
exit 1
STUB
chmod +x "$W/bin-gh/gh"
export PATH="$W/bin-gh:$PATH"

mkdir -p "$W/bin-oldgit"
cat > "$W/bin-oldgit/git" <<STUB
#!/usr/bin/env bash
for a in "\$@"; do [ "\$a" = merge-tree ] && exit 129; done
exec "$REAL_GIT" "\$@"
STUB
chmod +x "$W/bin-oldgit/git"

g() { local d="$1"; shift; "$REAL_GIT" -C "$d" "$@"; }
# setline <file> <n> <text>: replace line n (portable: no sed -i).
setline() { sed "${2}s/.*/$3/" "$1" > "$1.tmp" && mv "$1.tmp" "$1"; }

mk_repo() {
    "$REAL_GIT" init -q -b main "$1"
    g "$1" config user.email t@test.com
    g "$1" config user.name t
    g "$1" config commit.gpgsign false
    g "$1" config core.hooksPath /dev/null
    g "$1" remote add origin https://github.com/owner/repo.git
    seq 1 30 | sed 's/^/l/' > "$1/a.txt"
    echo b > "$1/b.txt"
    g "$1" add -A
    g "$1" commit -q -m base
    BASE=$(g "$1" rev-parse HEAD)
    g "$1" update-ref refs/remotes/origin/main "$BASE"
}
mk_branch() {
    g "$1" checkout -q -b "$2" "$BASE"
    setline "$1/a.txt" 2 "$3"
    if [ -n "${4:-}" ]; then setline "$1/a.txt" 28 "$4"; fi
    echo c > "$1/c.txt"
    g "$1" add -A
    g "$1" commit -q -m "wip $2"
    g "$1" rev-parse HEAD
}
squash_onto_main() {
    g "$1" checkout -q main
    g "$1" merge --squash -q "$2" >/dev/null 2>&1
    g "$1" commit -q -m "$3"
    SQ=$(g "$1" rev-parse HEAD)
    g "$1" update-ref refs/remotes/origin/main "$SQ"
}
mk_doc() { printf '## Results (newest at the bottom)\n- 10:00 LIVE - go\n- 10:30 READY %s %s GREEN\n' "$2" "$3" > "$1"; }

ROW41=$'owner/repo\tfeat\tmerged\t'

echo "ROW: merged proof from local git"
R="$W/r1"; mk_repo "$R"; H=$(mk_branch "$R" feat "TWO"); squash_onto_main "$R" feat "feat: x (#41)"
mk_doc "$W/d1.md" 41 "$H"
rm -f "$GH_LOG"
out=$(merged_proof "$R" "$W/d1.md" feat "$H")
check "merged proof from local git: one merged row, tip as head" "$out" "${ROW41}${H}"
check "merged proof from local git: gh log is empty" "$([ -s "$GH_LOG" ] && cat "$GH_LOG" || echo EMPTY)" "EMPTY"
check "merged proof ignores a poisoned repository-redirecting environment" "$(GIT_OBJECT_DIRECTORY=/nonexistent GIT_PREFIX=/nonexistent merged_proof "$R" "$W/d1.md" feat "$H")" "${ROW41}${H}"
check "doc_ready_head names the head" "$(doc_ready_head "$W/d1.md" 41)" "$H"
check "doc_ready_head for another PR is empty" "$(doc_ready_head "$W/d1.md" 40)" ""
check "merged_commit_of finds the squash" "$(merged_commit_of "$R" 41)" "$SQ"
check "branch cache writer: header, scope, row, trailer" "$(write_branch_cache "$R" feat "${ROW41}${H}")" \
"# nwo=owner/repo
# scope=branch feat
${ROW41}${H}
# complete rows=1"

echo "ROW: doc_pr"
printf -- '- 10:00 LIVE - go\n- 10:20 READY 41 %s GREEN\n- 10:40 MERGED 42 abc\n' "$H" > "$W/d-pr.md"
check "doc_pr takes the newest READY or MERGED bullet" "$(doc_pr "$W/d-pr.md")" "42"
printf -- '- READY 41 %s GREEN\n' "$H" > "$W/d-pr-bare.md"
check "doc_pr reads a READY bullet with no timestamp" "$(doc_pr "$W/d-pr-bare.md")" "41"
printf -- '- 10:20 **READY 43 %s GREEN**\n' "$H" > "$W/d-pr-bold.md"
check "doc_pr reads a bold READY bullet" "$(doc_pr "$W/d-pr-bold.md")" "43"
check "merged_proof reads a READY bullet with no timestamp" "$(merged_proof "$R" "$W/d-pr-bare.md" feat "$H")" "${ROW41}${H}"
printf -- '- 10:00 LIVE - go\n' > "$W/d-nopr.md"
check "doc_pr is empty when the doc names none" "$(doc_pr "$W/d-nopr.md")" ""

echo "ROW: M1 missing"
R="$W/r2"; mk_repo "$R"; H=$(mk_branch "$R" feat "TWO"); squash_onto_main "$R" feat "feat: x"
mk_doc "$W/d2.md" 41 "$H"
check "M1 missing: no (#41) subject gives no row" "$(merged_proof "$R" "$W/d2.md" feat "$H")" ""

echo "ROW: M2 missing"
R="$W/r3"; mk_repo "$R"; H=$(mk_branch "$R" feat "TWO"); squash_onto_main "$R" feat "feat: x (#41)"
g "$R" checkout -q feat; echo more > "$R/d.txt"; g "$R" add -A; g "$R" commit -q -m "after the head"
TIP=$(g "$R" rev-parse HEAD)
mk_doc "$W/d3.md" 41 "$H"
check "M2 missing: tip one commit past the READY head gives no row" "$(merged_proof "$R" "$W/d3.md" feat "$TIP")" ""

echo "ROW: M3 missing"
R="$W/r4"; mk_repo "$R"; H=$(mk_branch "$R" feat "TWO")
g "$R" checkout -q -b big feat; echo o > "$R/other.txt"; g "$R" add -A; g "$R" commit -q -m "PR 40 also touches another file"
squash_onto_main "$R" big "other: y (#40)"
mk_doc "$W/d4.md" 40 "$H"
mt_out=$(g "$R" merge-tree --write-tree "$SQ" "$H" 2>/dev/null)
check "M3 missing: fixture holds M4 (H is wholly inside the squash of PR 40)" "$mt_out" "$(g "$R" rev-parse "$SQ^{tree}")"
check "M3 missing: doc names PR 40, a merged PR touching other files, gives no row" "$(merged_proof "$R" "$W/d4.md" feat "$H")" ""

echo "ROW: M4 missing (R17)"
R="$W/r5"; mk_repo "$R"; H=$(mk_branch "$R" feat "H-two")
g "$R" checkout -q -b h2 "$BASE"; setline "$R/a.txt" 2 "H2-two"; echo c > "$R/c.txt"; g "$R" add -A; g "$R" commit -q -m "rewritten head"
squash_onto_main "$R" h2 "feat: x (#41)"
mk_doc "$W/d5.md" 41 "$H"
check "M4 missing: squash of a rewritten head with H's file set, different content, gives no row" "$(merged_proof "$R" "$W/d5.md" feat "$H")" ""

echo "ROW: M4 tree changes on a clean merge"
R="$W/r6"; mk_repo "$R"; H=$(mk_branch "$R" feat "TWO" "TWENTY-EIGHT")
g "$R" checkout -q -b h2 "$BASE"; setline "$R/a.txt" 2 "TWO"; echo c > "$R/c.txt"; g "$R" add -A; g "$R" commit -q -m "rewritten head without the second hunk"
squash_onto_main "$R" h2 "feat: x (#41)"
mk_doc "$W/d6.md" 41 "$H"
mt_out=$(g "$R" merge-tree --write-tree "$SQ" "$H" 2>/dev/null); mt_rc=$?
check "M4 tree changes: fixture merge-tree is clean (rc 0)" "$mt_rc" "0"
if [ "$mt_out" != "$(g "$R" rev-parse "$SQ^{tree}")" ]; then ok "M4 tree changes: merged tree is not S^{tree}"; else bad "M4 tree changes: merged tree is not S^{tree}" "fixture is not a clean tree-changing merge"; fi
check "M4 tree changes on a clean merge: no row" "$(merged_proof "$R" "$W/d6.md" feat "$H")" ""
R="$W/r6c"; mk_repo "$R"; H=$(mk_branch "$R" feat "TWO" "TWENTY-EIGHT"); squash_onto_main "$R" feat "feat: x (#41)"
mk_doc "$W/d6c.md" 41 "$H"
check "M4 holds: S is the squash of H itself, one row" "$(merged_proof "$R" "$W/d6c.md" feat "$H")" "${ROW41}${H}"

echo "ROW: merge-tree unavailable"
R="$W/r7"; mk_repo "$R"; H=$(mk_branch "$R" feat "TWO"); squash_onto_main "$R" feat "feat: x (#41)"
mk_doc "$W/d7.md" 41 "$H"
check "merge-tree unavailable (rc 129): no row" "$(PATH="$W/bin-oldgit:$PATH" merged_proof "$R" "$W/d7.md" feat "$H")" ""
check "merge-tree unavailable: the same repo proves with a working git" "$(merged_proof "$R" "$W/d7.md" feat "$H")" "${ROW41}${H}"

echo "ROW: revert subject"
R="$W/r8"; mk_repo "$R"; H=$(mk_branch "$R" feat "TWO")
g "$R" checkout -q main; echo r > "$R/r.txt"; g "$R" add -A; g "$R" commit -q -m 'Revert "feat: x (#41)" (#42)'
RV=$(g "$R" rev-parse HEAD); g "$R" update-ref refs/remotes/origin/main "$RV"
check "revert subject: no commit for 41" "$(merged_commit_of "$R" 41)" ""
check "revert subject: the revert is the commit for 42" "$(merged_commit_of "$R" 42)" "$RV"
mk_doc "$W/d8.md" 41 "$H"
check "revert subject: no row" "$(merged_proof "$R" "$W/d8.md" feat "$H")" ""

echo "ROW: stale origin"
R="$W/r9"; mk_repo "$R"; H=$(mk_branch "$R" feat "TWO"); squash_onto_main "$R" feat "feat: x (#41)"
g "$R" update-ref refs/remotes/origin/main "$BASE"
mk_doc "$W/d9.md" 41 "$H"
check "stale origin: the squash exists but origin/main never fetched it: no row" "$(merged_proof "$R" "$W/d9.md" feat "$H")" ""

echo "ROW: no_work_proof"
R="$W/r10"; mk_repo "$R"; g "$R" branch nw "$BASE"; TIP=$(g "$R" rev-parse nw)
printf -- '- 10:00 LIVE - go\n' > "$W/d10.md"
check "no_work_proof: zero ahead, no origin ref, no PR in the doc: a 0-row branch file" "$(no_work_proof "$R" "$W/d10.md" nw "$TIP")" \
"# nwo=owner/repo
# scope=branch nw
# complete rows=0"
g "$R" update-ref refs/remotes/origin/nw "$TIP"
check "no_work_proof: origin ref present: nothing" "$(no_work_proof "$R" "$W/d10.md" nw "$TIP")" ""
g "$R" update-ref -d refs/remotes/origin/nw
g "$R" checkout -q nw; echo x > "$R/x.txt"; g "$R" add -A; g "$R" commit -q -m ahead
TIP1=$(g "$R" rev-parse HEAD)
check "no_work_proof: one commit ahead: nothing" "$(no_work_proof "$R" "$W/d10.md" nw "$TIP1")" ""
mk_doc "$W/d10b.md" 41 "$TIP"
check "no_work_proof: doc names a PR: nothing" "$(no_work_proof "$R" "$W/d10b.md" nw "$TIP")" ""
printf -- '- 10:40 MERGED 42 abc\n' > "$W/d10c.md"
check "no_work_proof: doc names a PR in a MERGED bullet: nothing" "$(no_work_proof "$R" "$W/d10c.md" nw "$TIP")" ""
printf -- '- 10:40 READY soon\n' > "$W/d10d.md"
check "no_work_proof: doc has a READY bullet with no number: nothing" "$(no_work_proof "$R" "$W/d10d.md" nw "$TIP")" ""

echo
echo "test-close-facts: $pass passed, $fails failed"
[ "$fails" -eq 0 ]
