#!/usr/bin/env bash
# test-json-writers-final-newline.sh — every chief-kit writer that puts a JSON
# file in the handover tree ends the file with a newline. The luna vault's
# auto-commit runs end-of-file-fixer, which refuses a commit that stages a file
# without one, so one such file stalls every vault sync behind it.
#   1. gen-briefs.py's <workers>.out
#   2. fleet-manifest.sh's *.fleet.json (add, then remove)
# GEN_BRIEFS overrides the script under test (the RED control). Hermetic: temp
# dir only, the worktree step is stubbed. bash 3.2-safe.
#
# Run: bash scripts/handover/chief-kit/test-json-writers-final-newline.sh
# shellcheck disable=SC2015  # A && B || C is intentional in the pass/fail reporting lines, as in test-gen-briefs.sh
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
GEN="${GEN_BRIEFS:-$HERE/gen-briefs.py}"
MANIFEST="$HERE/fleet-manifest.sh"

fails=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; fails=$((fails + 1)); }
# read-sink-ok: $2 is always a fixture path this suite built under its own mktemp dir
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
# the core gate always asks the jira CLI (scripts/jira/dist is untracked, absent in CI): a fixture stand-in calls every key NOT-CORE
mkdir -p "$WORK/stub-jira"
cat > "$WORK/stub-jira/index.js" <<'STUBEOF'
const a = process.argv.slice(2);
if (a[0] === 'release' && a[1] === 'core-check') for (const k of a.slice(a.indexOf('--key') + 1)) console.log('NOT-CORE ' + k);
else { console.error('stub jira: unknown command ' + a.join(' ')); process.exit(2); }
STUBEOF
export GEN_BRIEFS_JIRA_CLI="$WORK/stub-jira/index.js"

cat > "$WORK/workers.json" <<'EOF'
[
 {"label":"N901","keys":["HIMMEL-9001"],"slug":"plain-fix","branch":"fix/himmel-9001-plain-fix","title":"a plain fix","desc":"fix the plain thing","why":"it is broken","prior":"none found (qmd jira-himmel plain thing)","scope":"`scripts/x/`","scope_short":"scripts/x","commit":"fix(x): [HIMMEL-9001] fix the plain thing"}
]
EOF

out="$(python3 "$GEN" "$WORK/workers.json" --base 4ccb59dd6de2eba962c75f136096cd7b721ae312 --chief HIMMEL-nextleg-2026-10-08BZ-roadmap-chief --bucket "$WORK/bucket" --date 2026-10-08 --repo "$WORK/repo" --handover-root "$WORK/handovers" --work-dir "$WORK/w" --deadline 1791475000 2>&1)" \
    && pass "gen-briefs.py generates a fixture workers file" || fail "gen-briefs.py failed: $out"
ends_nl "gen-briefs.py <workers>.out ends with a newline" "$WORK/workers.json.out"

D="$WORK/HIMMEL-1-N61-a-2026-10-20-RESUME.md"
M="$WORK/console.fleet.json"
if command -v flock >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
    listed() { jq -r --arg d "$D" '[.workers[] | select(.doc == $d)] | length' "$M" 2>/dev/null; }
    bash "$MANIFEST" add "$M" "$D" >/dev/null 2>&1 && [ "$(listed)" = 1 ] && ends_nl "fleet-manifest.sh add leaves a final newline" "$M" || fail "fleet-manifest.sh add failed to list the doc"
    bash "$MANIFEST" remove "$M" "$D" >/dev/null 2>&1 && [ "$(listed)" = 0 ] && ends_nl "fleet-manifest.sh remove leaves a final newline" "$M" || fail "fleet-manifest.sh remove failed to drop the doc"
else
    echo "skip - fleet-manifest rows: need flock and jq"
fi

if [ "$fails" -eq 0 ]; then
    echo "PASS - test-json-writers-final-newline.sh"
    exit 0
fi
echo "FAIL - test-json-writers-final-newline.sh ($fails failure(s))"
exit 1
