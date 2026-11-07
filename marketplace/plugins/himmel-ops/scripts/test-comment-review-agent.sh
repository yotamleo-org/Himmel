#!/usr/bin/env bash
set -u
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../../../.." && pwd)"
agent="$here/../agents/comment-review.md"
fails=0
ok() { echo "ok - $1"; }
bad() { echo "FAIL - $1"; fails=$((fails + 1)); }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1: [$2]!=[$3]"; fi; }

SICKO_BLOB=4e604bc7049fbf03c1f733cafc1ed61f3200fe47
NOCOMMENTS_BLOB=da76538f5a5007afa8e73075a8366322effc182b

[ -f "$agent" ] || { bad "agents/comment-review.md exists"; echo "$fails failed"; exit 1; }

front="$(awk 'NR == 1 && $0 == "---" { f = 1; next } f && $0 == "---" { exit } f { print }' "$agent")"
body="$(awk 'NR == 1 && $0 == "---" { f = 1; next } f && $0 == "---" { f = 0; next } !f { print }' "$agent")"

check "tools are exactly Read, Grep, Glob" "$(printf '%s\n' "$front" | sed -n 's/^tools: *//p')" "Read, Grep, Glob"
check "model is sonnet" "$(printf '%s\n' "$front" | sed -n 's/^model: *//p')" "sonnet"
check "name is comment-review" "$(printf '%s\n' "$front" | sed -n 's/^name: *//p')" "comment-review"

case "$body" in *"report-only rule overrides"*) ok "the body names the report-only override" ;; *) bad "the body must name the report-only override" ;; esac
case "$body" in *".claude/agents/comment-sicko.md"*) ok "the body points at the charter the dispatch names" ;; *) bad "the body must name the charter path" ;; esac
case "$body" in *"COMMENT-REVIEW <n>"*) ok "the body ends with the COMMENT-REVIEW line" ;; *) bad "the body must define the COMMENT-REVIEW last line" ;; esac
case "$body" in *"[comment-sicko-N]"*) ok "the body defines the finding line" ;; *) bad "the body must define the [comment-sicko-N] line" ;; esac

check "comment-sicko.md is byte-identical to its vendored blob" "$(git hash-object "$root/.claude/agents/comment-sicko.md")" "$SICKO_BLOB"
check "no-comments/SKILL.md is byte-identical to its vendored blob" "$(git hash-object "$root/.claude/skills/no-comments/SKILL.md")" "$NOCOMMENTS_BLOB"

if [ "$fails" -eq 0 ]; then echo "all passed"; else echo "$fails failed"; exit 1; fi
