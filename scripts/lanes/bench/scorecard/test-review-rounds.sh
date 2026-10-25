#!/usr/bin/env bash
# scripts/lanes/bench/scorecard/test-review-rounds.sh - RED/GREEN suite for
# review-rounds.sh: review rounds per merged PR, read from the round counters
# review-round.sh records per branch, and their per-day distribution.
#
# Builds a fixture counter dir (a nested feat/ branch, a flat one, a PR with no
# counter) and a gh stub returning five merged PRs over two UTC days.
#
# Platform guard: no .ps1 twin, by design, same convention as
# test-merged-count.sh.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/review-rounds.sh"
fails=0

check_eq() {
    name="$1"; actual="$2"; expected="$3"
    if [ "$actual" = "$expected" ]; then
        echo "ok - $name"
    else
        echo "FAIL - $name: expected [$expected] got [$actual]"
        fails=$((fails + 1))
    fi
}

RUN=$(mktemp -d "${TMPDIR:-/tmp}/test-review-rounds.XXXXXX") || { echo "FAIL - setup: mktemp failed"; exit 1; }
trap 'rm -rf "$RUN"' EXIT

STATE="$RUN/cr-review-rounds"
mkdir -p "$STATE/feat" "$STATE/fix"
printf '1\n' > "$STATE/feat/a.round"
printf '2\n' > "$STATE/feat/b.round"
printf '6\n' > "$STATE/fix/c.round"
printf '3\n' > "$STATE/feat/d.round"
printf '4\n' > "$STATE/feat/e.round"
# a counter that is not a number must not be read as a round count
printf 'x\n' > "$STATE/feat/g.round"

cat > "$RUN/gh" <<'EOF'
#!/usr/bin/env bash
cat <<'JSON'
[
 {"number":11,"headRefName":"feat/a","mergedAt":"2026-10-24T08:00:00Z"},
 {"number":12,"headRefName":"feat/b","mergedAt":"2026-10-24T09:00:00Z"},
 {"number":13,"headRefName":"fix/c","mergedAt":"2026-10-24T10:00:00Z"},
 {"number":14,"headRefName":"feat/d","mergedAt":"2026-10-25T08:00:00Z"},
 {"number":15,"headRefName":"feat/e","mergedAt":"2026-10-25T09:00:00Z"},
 {"number":16,"headRefName":"dependabot/npm/x","mergedAt":"2026-10-25T10:00:00Z"},
 {"number":17,"headRefName":"feat/g","mergedAt":"2026-10-25T11:00:00Z"},
 {"number":18,"headRefName":"feat/old","mergedAt":"2026-10-20T11:00:00Z"}
]
JSON
EOF
chmod +x "$RUN/gh"

export REVIEW_ROUNDS_GH="$RUN/gh" REVIEW_ROUNDS_STATE_DIR="$STATE"

out=$(bash "$SCRIPT" --tsv --since 2026-10-24T00:00:00Z --until 2026-10-26T00:00:00Z 2>/dev/null)
check_eq "tsv: one row per merged PR in the window, rounds from the counter" \
    "$(printf '%s\n' "$out" | grep -v '^#' | tr '\t' ' ')" \
    "2026-10-24 11 feat/a 1
2026-10-24 12 feat/b 2
2026-10-24 13 fix/c 6
2026-10-25 14 feat/d 3
2026-10-25 15 feat/e 4
2026-10-25 16 dependabot/npm/x -
2026-10-25 17 feat/g -"

dist=$(bash "$SCRIPT" --since 2026-10-24T00:00:00Z --until 2026-10-26T00:00:00Z 2>/dev/null)
check_eq "distribution: day one count, median, p90, max, top PRs" \
    "$(printf '%s\n' "$dist" | grep '^2026-10-24' | tr '\t' ' ')" \
    "2026-10-24 prs=3 median=2 p90=6 max=6 top=#13:6,#12:2,#11:1 unmeasured=0"
check_eq "distribution: day two, even count median, unmeasured PRs counted apart" \
    "$(printf '%s\n' "$dist" | grep '^2026-10-25' | tr '\t' ' ')" \
    "2026-10-25 prs=2 median=3.5 p90=4 max=4 top=#15:4,#14:3 unmeasured=2"

empty=$(bash "$SCRIPT" --since 2026-11-01T00:00:00Z 2>/dev/null)
check_eq "an empty window prints no day rows" "$(printf '%s\n' "$empty" | grep -c '^20')" "0"

bash "$SCRIPT" >/dev/null 2>&1
check_eq "no --since is a usage error" "$?" "2"

REVIEW_ROUNDS_GH=/nonexistent bash "$SCRIPT" --since 2026-10-24T00:00:00Z >/dev/null 2>&1
check_eq "a failing gh is exit 1, not an empty distribution" "$?" "1"

if [ "$fails" -gt 0 ]; then
    echo "test-review-rounds: $fails failed"
    exit 1
fi
echo "test-review-rounds: all passed"
