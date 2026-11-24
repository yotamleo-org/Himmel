#!/usr/bin/env bash
set -uo pipefail

unset ARMAUTOMERGE CR_MERGE_GATE_OK CR_REQUIRE_CROSS_MODEL
export FORCE_COLOR=3
export HIMMEL_POLICY_FOLLOWS_HOME=1

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$SCRIPT_DIR/../lib"
# shellcheck source=scripts/lib/timeout-bin.sh
# shellcheck disable=SC1091
. "$LIB_DIR/timeout-bin.sh"
# shellcheck source=scripts/lib/fixture-tempdir.sh
# shellcheck disable=SC1091
. "$LIB_DIR/fixture-tempdir.sh"

PASS=0
FAIL=0
LAST_CLEAR_OUT=""
pass() { PASS=$((PASS + 1)); }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL: $1" >&2; }

REPO_TEMPLATE=""
FLOOR_KEYS=$(fixture_mktemp_dir) || { echo "FAIL: mktemp for the key dir failed" >&2; exit 1; }
trap '[ -n "$REPO_TEMPLATE" ] && rm -rf "$REPO_TEMPLATE"; rm -rf "$FLOOR_KEYS"' EXIT
export CR_FLOOR_KEY_DIR="$FLOOR_KEYS/keys"
printf '{"allowFrom":["12345"]}\n' > "$FLOOR_KEYS/access.json"
export TELEGRAM_ACCESS_PATH="$FLOOR_KEYS/access.json"
export MERGE_BLOCK_ALERT_CMD=true

build_repo_template() {
    REPO_TEMPLATE=$(fixture_mktemp_dir) || return 1
    (
        fixture_enter_git_init_dir "$REPO_TEMPLATE" || exit 1
        git init -q -b main .
        git config user.email t@t.t; git config user.name t
        echo hi > f.txt
        git add f.txt
        git commit -qm "base"
        git checkout -qb feat/x
        echo more >> f.txt
        echo ':' > g.sh
        git add g.sh
        git commit -qam "work"
        git init -q --bare .git/test-origin.git
        git remote add origin .git/test-origin.git
        git push -q -u origin feat/x
    ) >/dev/null 2>&1 || { rm -rf "$REPO_TEMPLATE"; return 1; }
    mkdir -p "$REPO_TEMPLATE/scripts/cr" "$REPO_TEMPLATE/scripts/lib" "$REPO_TEMPLATE/scripts/lint" "$REPO_TEMPLATE/bin" \
        || { rm -rf "$REPO_TEMPLATE"; return 1; }
    local f
    for f in clear-review-marker.sh ledger-append.sh blast-scope.cjs anchor-handoff.sh set-impl-family.sh review-round.sh ledger-amend-auth.js claude-floor.mjs; do
        cp "$SCRIPT_DIR/$f" "$REPO_TEMPLATE/scripts/cr/$f" \
            || { echo "FAIL: cp $f into template failed" >&2; rm -rf "$REPO_TEMPLATE"; return 1; }
    done
    for f in chokepoint-seam-guard.sh env-alias.sh legacy-names.sh shared-branch-lock.sh review-default-base.sh timeout-bin.sh merge-block-alert.sh; do
        cp "$LIB_DIR/$f" "$REPO_TEMPLATE/scripts/lib/$f" \
            || { echo "FAIL: cp $f into template failed" >&2; rm -rf "$REPO_TEMPLATE"; return 1; }
    done
    cp "$SCRIPT_DIR/../lint/check-history-comments.sh" "$SCRIPT_DIR/../lint/ticket-refs.awk" "$SCRIPT_DIR/../lint/ticket-ref-allow.tsv" "$REPO_TEMPLATE/scripts/lint/" \
        || { echo "FAIL: cp history-comments gate files into template failed" >&2; rm -rf "$REPO_TEMPLATE"; return 1; }
    git -C "$REPO_TEMPLATE" add -A scripts/cr scripts/lib scripts/lint bin \
        || { echo "FAIL: git add of template scaffold failed" >&2; rm -rf "$REPO_TEMPLATE"; return 1; }
}

make_repo() {
    tmp=$(fixture_mktemp_dir) || return 1
    cp -r "$REPO_TEMPLATE"/. "$tmp"/ || { rm -rf "$tmp"; return 1; }
}

write_marker() {
    local tmp="$1" sha="$2" base ts="2026-12-01T10:00:00+00:00"
    base=$(git -C "$tmp" rev-parse --verify refs/heads/main)
    mkdir -p "$tmp/.git/cr-pending/feat"
    printf '%s | %s | full | origin | refs/heads/feat/x | .git/test-origin.git | %s\n' "$ts" "$sha" "$base" > "$tmp/.git/cr-pending/feat/x"
}

write_ledger() {
    local tmp="$1" l; shift
    : > "$tmp/.git/cr-critic-scores.jsonl"
    for l in "$@"; do printf '%s\n' "$l" >> "$tmp/.git/cr-critic-scores.jsonl"; done
}

avail_ok() { printf '{"kind":"avail","head":"%s","model":"codex","status":"ok"}' "$1"; }
tip_row() { printf '{"kind":"%s","ts":"2026-12-01T10:30:00Z","branch":"feat/x","head":"%s","status":"ok"}' "$1" "$2"; }

stub_gh() {
    printf "#!/usr/bin/env bash\nfor a in \"\$@\"; do [ \"\$a\" = \"--head\" ] && exit 0; done\nexit 1\n" > "$1/bin/gh"
    chmod +x "$1/bin/gh"
}
stub_check_ci() {
    printf '#!/usr/bin/env bash\nexit 0\n' > "$1/scripts/check-ci.sh"
    chmod +x "$1/scripts/check-ci.sh"
}

run_clear() {
    local tmp="$1" expected="$2" name="$3"; shift 3
    local rc=0 out
    out=$(cd "$tmp" && env HIMMEL_REPO="$tmp" PATH="$tmp/bin:$PATH" bash "$tmp/scripts/cr/clear-review-marker.sh" "$@" 2>&1) || rc=$?
    LAST_CLEAR_OUT="$out"
    if [ "$rc" -eq "$expected" ]; then pass; else
        fail "$name (expected rc=$expected, got $rc)"; echo "    out: $out" >&2
    fi
}

merge_case() {
    make_repo || exit 1
    git -C "$tmp" commit -qm "scaffold" >/dev/null 2>&1
    printf 'l1\nl2\nl3\nl4\nl5\n' > "$tmp/c.txt"
    git -C "$tmp" add c.txt && git -C "$tmp" commit -qm "scaffold c" -- c.txt
    git -C "$tmp" branch -f main feat/x
    sed 's/^l2$/L2/' "$tmp/c.txt" > "$tmp/c.new" && mv "$tmp/c.new" "$tmp/c.txt"
    git -C "$tmp" commit -qam "A: reviewed head"
    sha=$(git -C "$tmp" rev-parse --verify refs/heads/feat/x)
    git -C "$tmp" checkout -q main
    sed 's/^l4$/L4/' "$tmp/c.txt" > "$tmp/c.new" && mv "$tmp/c.new" "$tmp/c.txt" && git -C "$tmp" commit -qam "main: next to the PR hunk"
    git -C "$tmp" checkout -q feat/x
    git -C "$tmp" merge -q --no-ff --no-edit main >/dev/null 2>&1 || fail "merge_case: merge-forward"
    git -C "$tmp" push -q origin feat/x >/dev/null 2>&1
    B=$(git -C "$tmp" rev-parse --verify refs/heads/feat/x)
    write_marker "$tmp" "$B"
    mkdir -p "$tmp/.git/cr-review-rounds/feat"
    printf '%s\n' "$sha" > "$tmp/.git/cr-review-rounds/feat/x.head"
    stub_gh "$tmp"; stub_check_ci "$tmp"
}

carried() { case "$LAST_CLEAR_OUT" in *"via=clean-merge-forward"*) return 0 ;; esac; return 1; }

build_repo_template || { echo "FAIL: could not build repo template fixture" >&2; exit 1; }

echo "== clear-review-marker.sh tip-row tests =="

merge_case
write_ledger "$tmp" "$(avail_ok "$sha")"
run_clear "$tmp" 0 "1 a clean merge of main with no row at the tip clears -> exit 0"
if carried; then pass; else fail "1: the carry must audit via=clean-merge-forward (got: $LAST_CLEAR_OUT)"; fi
rm -rf "$tmp"

for _kind in evidence impacted round-scope security-audit; do
    merge_case
    write_ledger "$tmp" "$(avail_ok "$sha")" "$(tip_row "$_kind" "$B")"
    run_clear "$tmp" 0 "2 a $_kind row at the tip still clears through the clean merge -> exit 0"
    if carried; then pass; else fail "2: a $_kind row at the tip must still audit via=clean-merge-forward (got: $LAST_CLEAR_OUT)"; fi
    rm -rf "$tmp"
done

merge_case
write_ledger "$tmp" "$(avail_ok "$sha")" "$(avail_ok "$B")"
run_clear "$tmp" 0 "3 an avail review row at the tip clears on its own evidence -> exit 0"
if carried; then fail "3: a review row at the tip must not take the clean-merge-forward carry (got: $LAST_CLEAR_OUT)"; else pass; fi
rm -rf "$tmp"

merge_case
write_ledger "$tmp" "$(avail_ok "$sha")" "$(printf '{"kind":"finding","head":"%s","model":"codex","finding_id":"codex-1","severity":"sug","file":"c.txt","line":1,"verdict":"agreed"}' "$B")"
run_clear "$tmp" 14 "3b a finding row at the tip with no avail row of its own refuses -> exit 14"
if carried; then fail "3b: a finding row at the tip must not take the clean-merge-forward carry"; else pass; fi
rm -rf "$tmp"

echo
echo "clear-review-marker tip rows: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
