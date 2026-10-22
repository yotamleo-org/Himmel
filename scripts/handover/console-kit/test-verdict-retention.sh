#!/usr/bin/env bash
# shellcheck disable=SC2015,SC2016  # A && B || C is intentional in check()/contains(); the backticks are the verdict line's literal text
# scripts/handover/console-kit/test-verdict-retention.sh - suite for
# verdict-retention.sh:
#   1. archive is a dry run by default: it lists the one dir whose PR has been
#      closed past the age and moves nothing, writes no ledger row
#   2. --apply appends one ledger row per verdict file (qid, pr, head, verdict,
#      model, written-at, sha256, archive path), then moves only that dir to
#      archive/<YYYY-MM>/verdicts/<qid>/; an open-PR dir and a dir with no pr:
#      line stay in place
#   3. go_trust_verdict (the parser go.sh --trust-reviewed calls) still accepts
#      the open-PR fixture after the apply
#   4. a rerun appends no second row; a PR closed inside the age, a failing PR
#      lookup and a dir holding a non-verdict entry all keep the dir
#   5. inside a git bucket the move is a git rename
#      a verdict head that is not a commit of the target repo keeps the dir
#      (the pr: line names no repo, so a fork's PR number is not proven)
#   6. prune removes only judge-scratch dirs older than the age whose PR is
#      provably closed (live verdict dir or ledger row, head in the repo);
#      an open, unresolvable or unproven one is kept; dry-run by default,
#      never a file, a symlink or a young dir, and refuses a cache inside the
#      handover root
#   7. prune --unproven-older-than (off by default) also takes old scratch with
#      no PR to prove, but never an open PR, a failed lookup or a foreign head
#
# Hermetic: temp dir and a scratch HOME only; the real vault and cache are
# never read. Platform guard: POSIX bash 3.2+ with GNU or BSD date.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/verdict-retention.sh"
WRITER="$HERE/write-verdict.sh"
REPO="$(cd "$HERE/../../.." && pwd)"
SHA_A=0123456789abcdef0123456789abcdef01234567
SHA_B=89abcdef0123456789abcdef0123456789abcdef
SHA_F=fedcba9876543210fedcba9876543210fedcba98   # a head that is not a commit of the target repo
NOW=1792540800   # 2026-10-21T00:00:00Z

tmp="$(mktemp -d "${TMPDIR:-/tmp}/verdict-retention-test.XXXXXX")" || { echo "FAIL: mktemp -d failed" >&2; exit 1; }
scratch="/tmp/claude-$(id -u)"
[ -d "$scratch" ] || mkdir -m 700 "$scratch" || { echo "FAIL: cannot create $scratch" >&2; exit 1; }
evd="$(mktemp -d "$scratch/verdict-retention-test.XXXXXX")" || { echo "FAIL: mktemp -d in $scratch failed" >&2; rm -rf "$tmp"; exit 1; }
trap 'rm -rf "$tmp" "$evd"' EXIT
tmp="$(cd "$tmp" && pwd -P)"
root="$tmp/root"
mkdir -p "$root" "$tmp/home/.config/himmel" || exit 1
printf '%s\n' 0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef > "$tmp/home/.config/himmel/go-hmac.key"
export HOME="$tmp/home" USER_SLUG=tuser HIMMEL_VERDICT_MODEL=test-model HIMMEL_VERDICT_EFFORT=high

fails=0
check()    { [ "$2" = "$3" ] && echo "ok - $1" || { echo "FAIL - $1: [$2]!=[$3]"; fails=$((fails+1)); }; }
contains() { case "$2" in *"$3"*) echo "ok - $1" ;; *) echo "FAIL - $1: output does not contain [$3]"; fails=$((fails+1)) ;; esac; }
lacks()    { case "$2" in *"$3"*) echo "FAIL - $1: output contains [$3]"; fails=$((fails+1)) ;; *) echo "ok - $1" ;; esac; }

wv() {
    env -u HIMMEL_CONSOLE_LEG -u HIMMEL_CONSOLE_JUDGE -u HIMMEL_CONSOLE_RELAY \
        HANDOVER_DIR="$root" CLAUDE_CODE_SESSION_ID=sess-6915 bash "$WRITER" "$@"
}
verdict_rc() {
    (
        unset HIMMEL_CONSOLE_LEG
        export HANDOVER_DIR="$root"
        # shellcheck source=scripts/lib/handover-path.sh
        # shellcheck disable=SC1091
        . "$REPO/scripts/lib/handover-path.sh" || exit 9
        # shellcheck source=scripts/lib/go-gate.sh
        # shellcheck disable=SC1091
        . "$REPO/scripts/lib/go-gate.sh" || exit 9
        r=$(go_resolve_root "$REPO") || exit 8
        go_trust_verdict "$r" "$1" "$2" "$REPO" "$3" >/dev/null
    )
}
scope=$(
    # shellcheck source=scripts/lib/go-gate.sh
    # shellcheck disable=SC1091
    . "$REPO/scripts/lib/go-gate.sh" && go_verdict_scope "$REPO"
) || { echo "FAIL: cannot resolve the verdict scope"; exit 1; }
vdir="$root/$scope/verdicts"
bucket="$root/$scope"

ev="$evd/evidence.md"
printf 'class: option-parsing\n\n## Evidence checked\n\n- read the parser\n' > "$ev"
wv qopen GO "$SHA_A" --pr 501 --evidence-file "$ev" >/dev/null 2>&1 || { echo "FAIL: fixture qopen"; exit 1; }
wv qclosed GO "$SHA_B" --pr 502 --evidence-file "$ev" >/dev/null 2>&1 || { echo "FAIL: fixture qclosed"; exit 1; }
wv qrecent GO "$SHA_B" --pr 503 --evidence-file "$ev" >/dev/null 2>&1 || { echo "FAIL: fixture qrecent"; exit 1; }
wv qlookup GO "$SHA_B" --pr 504 --evidence-file "$ev" >/dev/null 2>&1 || { echo "FAIL: fixture qlookup"; exit 1; }
wv qscratch GO "$SHA_B" --pr 502 --evidence-file "$ev" >/dev/null 2>&1 || { echo "FAIL: fixture qscratch"; exit 1; }
wv qforeign GO "$SHA_F" --pr 502 --evidence-file "$ev" >/dev/null 2>&1 || { echo "FAIL: fixture qforeign"; exit 1; }
mkdir -p "$vdir/qscratch/scratch"
mkdir -p "$vdir/qnopr"
printf '# VERDICT qnopr - judge\n\nwritten-at: 2026-09-01T00:00:00Z\n\n## Verdict\n\n**GO** for head `%s`.\n\nmodel: old\n' "$SHA_A" > "$vdir/qnopr/judge.md"

# The PR lookup stand-in: prints "<STATE> <closedAt>" for the PR number in $1.
stub="$tmp/pr-state.sh"
cat > "$stub" <<'EOF'
#!/usr/bin/env bash
case "$1" in
    501) echo "OPEN" ;;
    502) echo "CLOSED 2026-10-01T00:00:00Z" ;;
    503) echo "MERGED 2026-10-16T00:00:00Z" ;;
    *) exit 1 ;;
esac
EOF
chmod +x "$stub"
# The repo-proof stand-in: `<repo> <sha>`, rc 0 when the commit is in the repo.
hstub="$tmp/head-check.sh"
cat > "$hstub" <<EOF
#!/usr/bin/env bash
[ "\$2" != "$SHA_F" ]
EOF
chmod +x "$hstub"
ret() {
    env HANDOVER_DIR="$root" HIMMEL_VERDICT_PR_STATE_CMD="$stub" HIMMEL_VERDICT_HEAD_CHECK_CMD="$hstub" HIMMEL_VERDICT_NOW="$NOW" bash "$SCRIPT" "$@"
}

# --- 1. dry run by default -------------------------------------------------
rc=0; out=$(ret archive 2>&1) || rc=$?
check "1: dry run rc 0" "$rc" 0
contains "1: lists the closed dir" "$out" "MOVE qclosed"
lacks "1: does not list the open-PR dir" "$out" "MOVE qopen"
contains "1: lists the no-pr dir as kept" "$out" "KEEP qnopr"
contains "1: a head outside the target repo is kept, repo not proven" "$out" "KEEP qforeign head fedcba987654 not found"
lacks "1: the foreign-head dir is not listed for a move" "$out" "MOVE qforeign"
check "1: nothing moved" "$([ -d "$vdir/qclosed" ] && echo yes)" yes
check "1: no ledger written" "$([ -e "$vdir/_ledger.jsonl" ] && echo yes || echo no)" no

# --- 2. apply --------------------------------------------------------------
want_sha=$(sha256sum "$vdir/qclosed/judge.md" | awk '{print $1}')
rc=0; out=$(ret archive --apply 2>&1) || rc=$?
check "2: apply rc 0" "$rc" 0
check "2: closed dir moved" "$([ -f "$bucket/archive/2026-10/verdicts/qclosed/judge.md" ] && echo yes)" yes
check "2: closed dir gone from verdicts" "$([ -e "$vdir/qclosed" ] && echo yes || echo no)" no
check "2: open-PR dir stays" "$([ -f "$vdir/qopen/judge.md" ] && echo yes)" yes
check "2: no-pr dir stays" "$([ -f "$vdir/qnopr/judge.md" ] && echo yes)" yes
check "2: foreign-head dir stays" "$([ -f "$vdir/qforeign/judge.md" ] && echo yes)" yes
check "2: foreign-head dir has no ledger row" "$(grep -c qforeign "$vdir/_ledger.jsonl")" 0
check "2: one ledger row for the one file" "$(grep -c . "$vdir/_ledger.jsonl")" 1
row=$(grep qclosed "$vdir/_ledger.jsonl")
check "2: row pr" "$(printf '%s' "$row" | jq -r .pr)" 502
check "2: row verdict" "$(printf '%s' "$row" | jq -r .verdict)" GO
check "2: row head" "$(printf '%s' "$row" | jq -r .head)" "$SHA_B"
check "2: row model" "$(printf '%s' "$row" | jq -r .model)" test-model
check "2: row sha256" "$(printf '%s' "$row" | jq -r .sha256)" "$want_sha"
check "2: row archive path" "$(printf '%s' "$row" | jq -r .archive_path)" "archive/2026-10/verdicts/qclosed/judge.md"
check "2: moved file keeps its bytes" "$(sha256sum "$bucket/archive/2026-10/verdicts/qclosed/judge.md" | awk '{print $1}')" "$want_sha"

# --- 3. the trust gate still reads the open-PR fixture ----------------------
rc=0; verdict_rc qopen "$SHA_A" 501 || rc=$?
check "3: go_trust_verdict still accepts the open-PR GO" "$rc" 0

# --- 4. idempotent and conservative ------------------------------------------
rc=0; out=$(ret archive --apply 2>&1) || rc=$?
check "4: rerun rc 0" "$rc" 0
check "4: rerun adds no row" "$(grep -c . "$vdir/_ledger.jsonl")" 1
check "4: PR closed inside the age stays" "$([ -f "$vdir/qrecent/judge.md" ] && echo yes)" yes
check "4: failing PR lookup keeps the dir" "$([ -f "$vdir/qlookup/judge.md" ] && echo yes)" yes
check "4: dir with a scratch subdir stays" "$([ -d "$vdir/qscratch/scratch" ] && echo yes)" yes
contains "4: scratch dir kept with its reason" "$out" "KEEP qscratch"

# --- 5. git bucket: the move is a rename --------------------------------------
wv qgit GO "$SHA_B" --pr 502 --evidence-file "$ev" >/dev/null 2>&1 || { echo "FAIL: fixture qgit"; exit 1; }
git -C "$bucket" init -q . 2>/dev/null
git -C "$bucket" add verdicts/qgit 2>/dev/null
git -C "$bucket" -c user.name=t -c user.email=t@example.invalid commit -q -m fixture 2>/dev/null
rc=0; ret archive --apply >/dev/null 2>&1 || rc=$?
check "5: git apply rc 0" "$rc" 0
check "5: staged as a rename" "$(git -C "$bucket" status --porcelain -- verdicts/qgit archive/2026-10/verdicts/qgit | cut -c1)" R

# --- 6. scratch pruner ---------------------------------------------------------
cache="$HOME/.cache/himmel/verdicts"
mkdir -p "$tmp/outside" "$cache/young1"
for q in old1 qopen qscratch qlookup qforeign qclosed; do
    mkdir -p "$cache/$q/scratch"
    echo big > "$cache/$q/scratch/f"
    touch -d '30 days ago' "$cache/$q/scratch/f" "$cache/$q/scratch" "$cache/$q"
done
echo keep > "$tmp/outside/keepme"
ln -s "$tmp/outside" "$cache/oldlink"
echo '{}' > "$cache/admissions-ledger.jsonl"
touch -d '30 days ago' "$cache/admissions-ledger.jsonl"
touch -h -d '30 days ago' "$cache/oldlink"
rc=0; out=$(ret prune 2>&1) || rc=$?
check "6: prune dry run rc 0" "$rc" 0
contains "6: dry run lists the closed-PR dir" "$out" "PRUNE qscratch"
contains "6: dry run lists the archived dir" "$out" "PRUNE qclosed"
contains "6: an open-PR dir is kept" "$out" "KEEP qopen PR 501 is open"
contains "6: an unresolvable PR is kept" "$out" "KEEP qlookup PR 504 lookup failed"
contains "6: a head outside the target repo is kept" "$out" "KEEP qforeign head fedcba987654 not found"
contains "6: a dir no verdict names is kept" "$out" "KEEP old1 no verdict dir or ledger row names its PR"
lacks "6: the young dir is not even a candidate" "$out" "young1"
check "6: dry run removes nothing" "$([ -d "$cache/qscratch" ] && [ -d "$cache/qclosed" ] && echo yes)" yes
rc=0; out=$(ret prune --apply 2>&1) || rc=$?
check "6: prune apply rc 0" "$rc" 0
check "6: closed-PR dir removed" "$([ -e "$cache/qscratch" ] && echo yes || echo no)" no
check "6: archived dir removed" "$([ -e "$cache/qclosed" ] && echo yes || echo no)" no
check "6: open-PR dir kept" "$([ -d "$cache/qopen" ] && echo yes)" yes
check "6: unresolvable-PR dir kept" "$([ -d "$cache/qlookup" ] && echo yes)" yes
check "6: foreign-head dir kept" "$([ -d "$cache/qforeign" ] && echo yes)" yes
check "6: unnamed dir kept" "$([ -d "$cache/old1" ] && echo yes)" yes
check "6: young dir kept" "$([ -d "$cache/young1" ] && echo yes)" yes
check "6: file in the cache kept" "$([ -f "$cache/admissions-ledger.jsonl" ] && echo yes)" yes
check "6: symlink kept" "$([ -L "$cache/oldlink" ] && echo yes)" yes
check "6: symlink target untouched" "$([ -f "$tmp/outside/keepme" ] && echo yes)" yes
check "6: vault verdicts untouched" "$([ -f "$vdir/qopen/judge.md" ] && echo yes)" yes
mkdir -p "$root/$scope/verdicts/inroot"
touch -d '30 days ago' "$root/$scope/verdicts/inroot"
rc=0; out=$(ret prune --apply --cache "$root/$scope/verdicts" 2>&1) || rc=$?
check "6: a cache inside the handover root is refused" "$rc" 2
check "6: the in-root dir survives" "$([ -d "$root/$scope/verdicts/inroot" ] && echo yes)" yes

# --- 7. --unproven-older-than: opt-in, never an open or foreign PR -----------------
mkdir -p "$cache/qnopr/scratch"
touch -d '30 days ago' "$cache/qnopr/scratch" "$cache/qnopr"
rc=0; out=$(ret prune --unproven-older-than 40 2>&1) || rc=$?
check "7: a cutoff older than the dirs takes nothing" "$(printf '%s\n' "$out" | grep -c '^PRUNE')" 0
rc=0; out=$(ret prune --unproven-older-than 20 2>&1) || rc=$?
check "7: dry run rc 0" "$rc" 0
contains "7: an unnamed dir is listed with its reason" "$out" "PRUNE old1"
contains "7: a no-pr: verdict dir is listed" "$out" "PRUNE qnopr"
contains "7: the reason is shown" "$out" "(unproven: no verdict dir or ledger row names its PR)"
contains "7: an open PR is still kept" "$out" "KEEP qopen PR 501 is open"
contains "7: a failed lookup is still kept" "$out" "KEEP qlookup PR 504 lookup failed"
contains "7: a foreign head is still kept" "$out" "KEEP qforeign head fedcba987654 not found"
check "7: dry run removes nothing" "$([ -d "$cache/old1" ] && [ -d "$cache/qnopr" ] && echo yes)" yes
rc=0; out=$(ret prune --apply --unproven-older-than 20 2>&1) || rc=$?
check "7: apply rc 0" "$rc" 0
check "7: unnamed dir removed" "$([ -e "$cache/old1" ] && echo yes || echo no)" no
check "7: no-pr dir removed" "$([ -e "$cache/qnopr" ] && echo yes || echo no)" no
check "7: open-PR dir kept" "$([ -d "$cache/qopen" ] && echo yes)" yes
check "7: foreign-head dir kept" "$([ -d "$cache/qforeign" ] && echo yes)" yes
check "7: young dir kept" "$([ -d "$cache/young1" ] && echo yes)" yes
rc=0; ret archive --unproven-older-than 20 >/dev/null 2>&1 || rc=$?
check "7: the flag is refused on archive" "$rc" 2

# --- 8. ledger-backed scratch re-checks its PR; no ancestor cache; every file counts ------
for q in qled qled2 qmix; do
    mkdir -p "$cache/$q/scratch"
    touch -d '30 days ago' "$cache/$q/scratch" "$cache/$q"
done
printf '{"qid":"qled","pr":501,"head":"%s","verdict":"GO"}\n{"qid":"qled2","pr":502,"head":"%s","verdict":"GO"}\n' "$SHA_A" "$SHA_B" >> "$vdir/_ledger.jsonl"
rc=0; out=$(ret prune 2>&1) || rc=$?
contains "8: an archived qid whose PR is open again is kept" "$out" "KEEP qled PR 501 is open"
contains "8: an archived qid whose PR is still closed is listed" "$out" "PRUNE qled2"
rc=0; ret prune --apply >/dev/null 2>&1 || rc=$?
check "8: the reopened-PR scratch survives apply" "$([ -d "$cache/qled" ] && echo yes)" yes
check "8: the closed-PR scratch is removed" "$([ -e "$cache/qled2" ] && echo yes || echo no)" no
rc=0; out=$(ret prune --apply --cache "$tmp" 2>&1) || rc=$?
check "8: a cache that is an ancestor of the handover root is refused" "$rc" 2
check "8: the handover root survives" "$([ -d "$vdir/qopen" ] && echo yes)" yes
wv qmix GO "$SHA_A" --pr 501 --evidence-file "$ev" >/dev/null 2>&1 || { echo "FAIL: fixture qmix"; exit 1; }
printf '# VERDICT qmix - judge\n\nwritten-at: 2026-09-01T00:00:00Z\n\n## Verdict\n\n**GO** for head `%s`.\n\nmodel: old\n' "$SHA_A" > "$vdir/qmix/old.md"
rc=0; out=$(ret prune --unproven-older-than 20 2>&1) || rc=$?
contains "8: a malformed file beside an open-PR file keeps the scratch" "$out" "KEEP qmix PR 501 is open"
rc=0; ret prune --apply --unproven-older-than 20 >/dev/null 2>&1 || rc=$?
check "8: the mixed dir survives apply" "$([ -d "$cache/qmix" ] && echo yes)" yes
mkdir -p "$vdir/qmix2" "$cache/qmix2/scratch"
touch -d '30 days ago' "$cache/qmix2/scratch" "$cache/qmix2"
printf '# VERDICT qmix2 - judge\n\n## Verdict\n\n**GO** for head `short`\n\npr: 501\n' > "$vdir/qmix2/bad.md"
rc=0; out=$(ret prune --unproven-older-than 20 2>&1) || rc=$?
contains "8: a readable pr: line beside a malformed verdict line still counts" "$out" "KEEP qmix2 PR 501 is open"
wv qdots GO "$SHA_B" --pr 502 --evidence-file "$ev" >/dev/null 2>&1 || { echo "FAIL: fixture qdots"; exit 1; }
printf 'x\n' > "$vdir/qdots/..hidden"
rc=0; out=$(ret archive 2>&1) || rc=$?
contains "8: a two-dot entry counts as a non-verdict entry" "$out" "KEEP qdots holds a non-verdict entry (..hidden)"

echo
[ "$fails" -eq 0 ] && echo "all passed" || { echo "$fails failed"; exit 1; }
