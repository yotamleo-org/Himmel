#!/usr/bin/env bash
# test-json-writers-final-newline.sh — every console-kit writer that puts a JSON
# file in the handover tree ends the file with a newline. The luna vault's
# auto-commit runs end-of-file-fixer, which refuses a commit that stages a file
# without one, so one such file stalls every vault sync behind it.
#   1. gen-briefs.py's <legs>.out
#   2. fleet-manifest.sh's *.fleet.json (add, then remove)
# GEN_BRIEFS overrides the script under test (the RED control). Hermetic: temp
# dir only, the worktree step is stubbed. bash 3.2-safe.
#
# Run: bash scripts/handover/console-kit/test-json-writers-final-newline.sh
# shellcheck disable=SC2015  # A && B || C is intentional in the pass/fail reporting lines, as in test-gen-briefs.sh
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
GEN="${GEN_BRIEFS:-$HERE/gen-briefs.py}"
MANIFEST="$HERE/fleet-manifest.sh"

fails=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; fails=$((fails + 1)); }
ends_nl() { [ -s "$2" ] && [ "$(tail -c1 "$2" | od -An -c | tr -d ' ')" = '\n' ] && pass "$1" || fail "$1 (last byte is not a newline: $2)"; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/json-final-nl-test.XXXXXX")" || exit 1
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/repo"

cat > "$WORK/wt.sh" <<'EOF'
#!/usr/bin/env bash
echo "created worktree $1"
EOF
chmod +x "$WORK/wt.sh"
export GEN_BRIEFS_WORKTREE_CMD="$WORK/wt.sh" GEN_BRIEFS_NO_WT_CHECK=1

cat > "$WORK/legs.json" <<'EOF'
[
 {"label":"N901","keys":["HIMMEL-9001"],"slug":"plain-fix","branch":"fix/himmel-9001-plain-fix","title":"a plain fix","desc":"fix the plain thing","why":"it is broken","prior":"none found (qmd jira-himmel plain thing)","scope":"`scripts/x/`","scope_short":"scripts/x","commit":"fix(x): [HIMMEL-9001] fix the plain thing"}
]
EOF

out="$(python3 "$GEN" "$WORK/legs.json" --base 4ccb59dd6de2eba962c75f136096cd7b721ae312 --console HIMMEL-nextleg-2026-10-08BZ-roadmap-console --bucket "$WORK/bucket" --date 2026-10-08 --repo "$WORK/repo" --handover-root "$WORK/handovers" --work-dir "$WORK/w" --deadline 1791475000 2>&1)" \
    && pass "gen-briefs.py generates a fixture legs file" || fail "gen-briefs.py failed: $out"
ends_nl "gen-briefs.py <legs>.out ends with a newline" "$WORK/legs.json.out"

D="$WORK/HIMMEL-1-N61-a-2026-10-20-RESUME.md"
M="$WORK/console.fleet.json"
if command -v flock >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
    bash "$MANIFEST" add "$M" "$D" >/dev/null 2>&1
    ends_nl "fleet-manifest.sh add leaves a final newline" "$M"
    bash "$MANIFEST" remove "$M" "$D" >/dev/null 2>&1
    ends_nl "fleet-manifest.sh remove leaves a final newline" "$M"
else
    echo "skip - fleet-manifest rows: need flock and jq"
fi

if [ "$fails" -eq 0 ]; then
    echo "PASS - test-json-writers-final-newline.sh"
    exit 0
fi
echo "FAIL - test-json-writers-final-newline.sh ($fails failure(s))"
exit 1
