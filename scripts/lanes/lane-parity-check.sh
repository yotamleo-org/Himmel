#!/usr/bin/env bash
# scripts/lanes/lane-parity-check.sh - fails when a guard is wired on one CLI lane
# (Claude Code, Codex CLI, Gemini through Antigravity) and missing on another with
# no recorded reason.
#
# Reads the table between <!-- BEGIN cli-lane-parity --> and <!-- END cli-lane-parity -->
# in docs/internals/lane-parity.md: `| capability | claude | codex | antigravity |`.
# Each lane cell is one of
#   has[: note]               the lane has the capability
#   structural: <reason>      the lane cannot have it (the CLI has no such tool or role)
#   gap-ticketed: <reason>    a launcher, hook or adapter edit owed under a ticket
# A `guard:<hook>.sh` row is also checked against the real wiring of each lane:
#   claude        PreToolUse in .claude/settings.json and the himmel-ops plugin hooks.json
#   codex         PreToolUse in .codex/hooks.json
#   antigravity   the PreToolUse tool arms of scripts/hooks/antigravity-hook-adapter.sh
# and a hook wired on any lane with no row fails.
#
# Usage: bash scripts/lanes/lane-parity-check.sh [--root <dir>] [--doc <file>]
# Exit: 0 pass, 1 drift found, 2 usage or unreadable input.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
DOC=""

while [ $# -gt 0 ]; do
    case "$1" in
        --root) [ $# -ge 2 ] || { echo "lane-parity-check: --root needs a value" >&2; exit 2; }; ROOT="$2"; shift 2 ;;
        --doc) [ $# -ge 2 ] || { echo "lane-parity-check: --doc needs a value" >&2; exit 2; }; DOC="$2"; shift 2 ;;
        *) echo "lane-parity-check: unknown argument: $1" >&2; exit 2 ;;
    esac
done
[ -n "$DOC" ] || DOC="$ROOT/docs/internals/lane-parity.md"

command -v jq >/dev/null 2>&1 || { echo "lane-parity-check: jq not on PATH" >&2; exit 2; }

CLAUDE_SRC="$ROOT/.claude/settings.json $ROOT/marketplace/plugins/himmel-ops/hooks/hooks.json"
CODEX_SRC="$ROOT/.codex/hooks.json"
ADAPTER="$ROOT/scripts/hooks/antigravity-hook-adapter.sh"
for f in $CLAUDE_SRC $CODEX_SRC $ADAPTER "$DOC"; do
    [ -f "$f" ] || { echo "lane-parity-check: missing input: $f" >&2; exit 2; }
done

[ -r "$HERE/../lib/prim.sh" ] || { echo "lane-parity-check: scripts/lib/prim.sh unreadable" >&2; exit 2; }
# shellcheck source=../lib/prim.sh
. "$HERE/../lib/prim.sh"
T="$(tmpdir)" || exit 2
trap 'rm -rf "$T"' EXIT

names_of() {
    grep -oE '[A-Za-z0-9_-]+\.sh' | grep -vxE 'run-node\.sh|resolve-node\.sh|run-hook\.sh|antigravity-hook-adapter\.sh' | sort -u
}

: > "$T/claude.raw"
for f in $CLAUDE_SRC; do
    jq -r '.hooks.PreToolUse[]?.hooks[]?.command // empty' "$f" >> "$T/claude.raw" || { echo "lane-parity-check: unreadable json: $f" >&2; exit 2; }
done
names_of < "$T/claude.raw" > "$T/claude.txt"

jq -r '.hooks.PreToolUse[]?.hooks[]?.command // empty' "$CODEX_SRC" | sed 's/.*--sandbox//' | tr '+' '\n' | names_of > "$T/codex.txt" \
    || { echo "lane-parity-check: unreadable json: $CODEX_SRC" >&2; exit 2; }

sed -n '/^build_claude_payload() {/,$p' "$ADAPTER" | sed -e 's/^[[:space:]]*#.*//' -e 's/[[:space:]]#.*//' | names_of > "$T/antigravity.txt"

cat "$T/claude.txt" "$T/codex.txt" "$T/antigravity.txt" | sort -u > "$T/all.txt"

if ! grep -q '<!-- BEGIN cli-lane-parity -->' "$DOC" || ! grep -q '<!-- END cli-lane-parity -->' "$DOC"; then
    echo "lane-parity-check: anchor <!-- BEGIN/END cli-lane-parity --> missing in $DOC" >&2
    exit 1
fi

awk '
    /<!-- BEGIN cli-lane-parity -->/ { f = 1; next }
    /<!-- END cli-lane-parity -->/   { f = 0 }
    f && /^[[:space:]]*\|/ { print }
' "$DOC" > "$T/rows.txt"

FAIL=0
ROWS=0
GUARDS=0
: > "$T/rowed.txt"

trim() {
    local s="$1"
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    printf '%s' "$s"
}

bad() { echo "FAIL $1" >&2; FAIL=$((FAIL + 1)); }

LANES="claude codex antigravity"
seen_header=0
while IFS= read -r line; do
    case "$line" in
        *[A-Za-z]*) ;;
        *) continue ;;
    esac
    core="${line#*|}"
    core="${core%|*}"
    IFS='|' read -ra cells <<< "$core"
    if [ "$seen_header" = 0 ]; then
        seen_header=1
        h="$(trim "${cells[0]:-}")|$(trim "${cells[1]:-}")|$(trim "${cells[2]:-}")|$(trim "${cells[3]:-}")"
        [ "$h" = "capability|claude|codex|antigravity" ] || { bad "header is '$h', want capability|claude|codex|antigravity"; break; }
        continue
    fi
    if [ "${#cells[@]}" -ne 4 ]; then
        bad "row has ${#cells[@]} cells, want 4: $line"
        continue
    fi
    cap="$(trim "${cells[0]}")"
    cap="${cap//\`/}"
    ROWS=$((ROWS + 1))
    hook=""
    case "$cap" in
        guard:*.sh) hook="${cap#guard:}"; GUARDS=$((GUARDS + 1)); printf '%s\n' "$hook" >> "$T/rowed.txt" ;;
        guard:*) bad "$cap: a guard row names a .sh hook"; continue ;;
    esac
    i=0
    for lane in $LANES; do
        i=$((i + 1))
        cell="$(trim "${cells[$i]}")"
        cell="${cell//\`/}"
        tok="${cell%%:*}"
        tok="$(trim "$tok")"
        reason=""
        case "$cell" in *:*) reason="$(trim "${cell#*:}")" ;; esac
        case "$tok" in
            has) ;;
            structural|gap-ticketed)
                [ -n "$reason" ] || { bad "$cap [$lane]: '$tok' with no recorded reason"; continue; } ;;
            *) bad "$cap [$lane]: cell '$cell' is not has, structural: <reason> or gap-ticketed: <reason>"; continue ;;
        esac
        if [ -n "$hook" ]; then
            if grep -qxF "$hook" "$T/$lane.txt"; then wired=1; else wired=0; fi
            if [ "$tok" = has ] && [ "$wired" = 0 ]; then
                bad "$cap [$lane]: the table says has, the $lane wiring does not carry $hook"
            elif [ "$tok" != has ] && [ "$wired" = 1 ]; then
                bad "$cap [$lane]: the table records '$tok' but the $lane wiring carries $hook (stale reason)"
            fi
        fi
    done
done < "$T/rows.txt"

[ "$seen_header" = 1 ] || bad "no table rows between the cli-lane-parity anchors"

sort -u "$T/rowed.txt" > "$T/rowed.sorted"
while IFS= read -r h; do
    grep -qxF "$h" "$T/rowed.sorted" || bad "guard:$h is wired on a lane and has no row in the table"
done < "$T/all.txt"

if [ "$FAIL" -eq 0 ]; then
    echo "lane-parity-check: PASS ($ROWS rows, $GUARDS guard rows)"
    exit 0
fi
echo "lane-parity-check: FAIL ($FAIL problems)" >&2
exit 1
