#!/usr/bin/env bash
# test-suggest-missing-path.sh — suite for the PostToolUseFailure missing-path hint.
# The suite is the spec.
#
# The behaviour rows run the INSTALLED hooks.json command with CLAUDE_PLUGIN_ROOT on
# this plugin dir, so a hook that is not wired (or wired to the wrong event or
# matcher) prints nothing and fails the moved-file rows. The timing row runs the
# script directly: it measures the hook, not node's start-up.
#
# Usage: bash marketplace/plugins/himmel-ops/hooks/test-suggest-missing-path.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_DIR="$(cd "$HERE/.." && pwd)"
HIMMEL_ROOT="$(cd "$HERE/../../../.." && pwd)"
FAILED=0

TMP="$(mktemp -d "${TMPDIR:-/tmp}/missing-path.XXXXXX")" || exit 1
trap 'rm -rf "$TMP"' EXIT

plugin_cmd=$(jq -r '.hooks.PostToolUseFailure[] | select(.matcher == "Bash") | .hooks[].command | select(contains("suggest-missing-path.sh"))' "$PLUGIN_DIR/hooks/hooks.json")

REPO="$TMP/repo"
HANDOVER="$TMP/handovers"
OUTSIDE="$TMP/outside"
mkdir -p "$REPO/scripts/handover" "$REPO/docs/internals" "$HANDOVER/me/proj" "$OUTSIDE"
git init -q "$REPO"
: >"$REPO/scripts/handover/queue-lock.sh"
: >"$REPO/docs/internals/release-manager.md"
for d in a b c d e; do mkdir -p "$REPO/pkg/$d"; : >"$REPO/pkg/$d/index.md"; done
: >"$HANDOVER/me/proj/proj-note.md"
: >"$OUTSIDE/queue-lock.sh"
git -C "$REPO" add -A

payload() {
    jq -n --arg t "$1" --arg e "$2" --arg c "$3" \
        '{session_id:"s-missing",hook_event_name:"PostToolUseFailure",cwd:$c,tool_name:$t,tool_input:{command:"x"},error:$e}'
}

run_case() {
    OUT=$(cd "${2:-$REPO}" && printf '%s' "$1" | env CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" \
        CLAUDE_PROJECT_DIR="${2:-$REPO}" HANDOVER_DIR="$HANDOVER" \
        sh -c "${plugin_cmd:-exit 0}" 2>/dev/null)
    RC=$?
}

assert_eq() {
    if [ "$3" = "$2" ]; then
        echo "PASS $1 ($3)"
    else
        echo "FAIL $1 - expected $2, got $3"
        FAILED=$((FAILED + 1))
    fi
}

assert_contains() {
    case "$3" in
        *"$2"*) echo "PASS $1" ;;
        *) echo "FAIL $1 - did not contain: $2"
           echo "  got: $3"
           FAILED=$((FAILED + 1)) ;;
    esac
}

assert_empty() {
    if [ -z "$2" ]; then
        echo "PASS $1"
    else
        echo "FAIL $1 - expected no output"
        echo "  got: $2"
        FAILED=$((FAILED + 1))
    fi
}

assert_eq "wired: one Bash-matched PostToolUseFailure command" 1 "$(printf '%s' "$plugin_cmd" | grep -c suggest-missing-path.sh)"
if git -C "$HIMMEL_ROOT" grep -q suggest-missing-path -- .claude/settings.json 2>/dev/null; then
    echo "FAIL not wired in .claude/settings.json"
    FAILED=$((FAILED + 1))
else
    echo "PASS not wired in .claude/settings.json"
fi

run_case "$(payload Bash "Exit code 127
bash: scripts/handover/chief-kit/queue-lock.sh: No such file or directory" "$REPO")"
assert_eq "moved file, relative: exit 0" 0 "$RC"
assert_contains "moved file, relative: names the real path" "scripts/handover/queue-lock.sh" "$OUT"
assert_contains "moved file, relative: valid additionalContext envelope" '"hookEventName":"PostToolUseFailure"' "$(printf '%s' "$OUT" | jq -c .hookSpecificOutput 2>/dev/null)"

run_case "$(payload Bash "cat: $REPO/docs/release-manager.md: No such file or directory" "$REPO")"
assert_contains "moved file, absolute: names the real path" "docs/internals/release-manager.md" "$OUT"

run_case "$(payload Bash "ls: cannot access 'scripts/queue-lock.sh': No such file or directory" "$REPO")"
assert_contains "moved file, quoted ls form: names the real path" "scripts/handover/queue-lock.sh" "$OUT"

run_case "$(payload Bash "python3: can't open file '$REPO/tools/queue-lock.sh': [Errno 2] No such file or directory" "$REPO")"
assert_contains "moved file, python form: names the real path" "scripts/handover/queue-lock.sh" "$OUT"

run_case "$(payload Bash "bash: $HANDOVER/me/proj-note.md: No such file or directory" "$REPO")"
assert_contains "moved file under the handover root: names the real path" "$HANDOVER/me/proj/proj-note.md" "$OUT"

run_case "$(payload Bash "bash: scripts/nowhere/ghost.sh: No such file or directory" "$REPO")"
assert_eq "exists nowhere: exit 0" 0 "$RC"
assert_empty "exists nowhere: no hint" "$OUT"

run_case "$(payload Bash "bash: $OUTSIDE/gone/queue-lock.sh: No such file or directory" "$REPO")"
assert_eq "outside the repo: exit 0" 0 "$RC"
assert_empty "outside the repo: no hint though the basename exists in the repo" "$OUT"

run_case "$(payload Bash "bash: queue-lock.sh: No such file or directory" "$OUTSIDE/..")"
assert_empty "relative path from a cwd outside any repo: no hint" "$OUT"

run_case "$(payload Bash "bash: scripts/handover/queue-lock.sh: No such file or directory" "$REPO")"
assert_empty "the path exists: no hint" "$OUT"

run_case "$(payload Bash "Exit code 1
grep: no match" "$REPO")"
assert_empty "no missing-path error: no hint" "$OUT"

run_case "$(payload Read "bash: scripts/chief-kit/queue-lock.sh: No such file or directory" "$REPO")"
assert_empty "a tool other than Bash: no hint" "$OUT"

run_case "$(payload Bash "cat: docs/index.md: No such file or directory" "$REPO")"
assert_eq "five same-name files: exactly three named" 3 "$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.additionalContext' | grep -o 'pkg/[a-e]/index.md' | wc -l | tr -d ' ')"

run_case 'not json at all' "$REPO"
assert_eq "garbage input: exit 0" 0 "$RC"
assert_empty "garbage input: no output" "$OUT"

run_case "$(payload Bash "bash: scripts/chief-kit/queue-lock.sh: No such file or directory" "$TMP/does-not-exist")" "$REPO"
assert_eq "unreadable cwd: exit 0" 0 "$RC"

BIG="$TMP/big"
git init -q "$BIG"
mkdir -p "$BIG/src"
i=0
while [ "$i" -lt 50 ]; do
    mkdir -p "$BIG/src/d$i"
    j=0
    while [ "$j" -lt 100 ]; do : >"$BIG/src/d$i/f$j.txt"; j=$((j + 1)); done
    i=$((i + 1))
done
mkdir -p "$BIG/scripts"
: >"$BIG/scripts/needle.sh"
git -C "$BIG" add -A
big_payload=$(payload Bash "bash: tools/needle.sh: No such file or directory" "$BIG")
case "$(date +%s%N 2>/dev/null)" in *[!0-9]* | "") have_ns=no ;; *) have_ns=yes ;; esac
if [ "$have_ns" = yes ]; then
    start=$(date +%s%N)
    out=$(cd "$BIG" && printf '%s' "$big_payload" | HANDOVER_DIR="$HANDOVER" bash "$PLUGIN_DIR/hooks/suggest-missing-path.sh" 2>/dev/null)
    end=$(date +%s%N)
    ms=$(( (end - start) / 1000000 ))
    assert_contains "timing: 5,000-file repo still finds the file" "scripts/needle.sh" "$out"
    if [ "$ms" -lt 100 ]; then
        echo "PASS timing: ${ms} ms on $(git -C "$BIG" ls-files | wc -l | tr -d ' ') files (under 100 ms)"
    else
        echo "FAIL timing: ${ms} ms on a 5,000-file repo (limit 100 ms)"
        FAILED=$((FAILED + 1))
    fi
else
    echo "SKIP timing: date has no nanosecond clock on this platform"
fi

if [ "$FAILED" -eq 0 ]; then
    echo "ALL PASS"
    exit 0
fi
echo "$FAILED FAILED"
exit 1
