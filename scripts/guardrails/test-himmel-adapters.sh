#!/usr/bin/env bash
# scripts/guardrails/test-himmel-adapters.sh - shape and coverage of the fork registry
# scripts/guardrails/himmel-adapters.json: every yotamleo fork has exactly one row, each
# row has the six fields with a legal role, and the operator-ruled merge_allowed set holds.
#
# Platform guard (gitbash-only): POSIX bash 3.2+, jq.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REG="$HERE/himmel-adapters.json"
fails=0
check() { # name actual expected
  if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: got '$2' want '$3'"; fails=$((fails + 1)); fi
}

FORKS="yotamleo/caveman yotamleo/claude-hud yotamleo/claude-obsidian yotamleo/claude-squad yotamleo/claude-statusline yotamleo/claude-video yotamleo/codex yotamleo/codex-plugin-cc yotamleo/core yotamleo/effective-html yotamleo/graphify yotamleo/hermes-agent yotamleo/home-assistant.io yotamleo/obsidian-second-brain yotamleo/obsidian-skills yotamleo/qmd yotamleo/twitter-cli"
MERGE_TRUE="yotamleo/claude-video yotamleo/graphify yotamleo/obsidian-skills yotamleo/qmd yotamleo/twitter-cli"

check "registry parses as a JSON array" "$(jq -r 'type' "$REG" 2>/dev/null)" "array"
check "every fork has a row, none extra" "$(jq -r '[.[].nwo] | sort | join(" ")' "$REG" 2>/dev/null)" "$FORKS"
check "no nwo is listed twice" "$(jq -r '[.[].nwo] | length - (unique | length)' "$REG" 2>/dev/null)" "0"
check "every row has the six fields" "$(jq -r '[.[] | select((keys | sort) != ["himmel_branch","merge_allowed","nwo","pin_site","role","upstream"])] | length' "$REG" 2>/dev/null)" "0"
check "every role is one of the four" "$(jq -r '[.[] | select(.role | IN("runtime-dependency","upstream-contribution","vendored-source","dormant") | not)] | length' "$REG" 2>/dev/null)" "0"
check "merge_allowed is a boolean and himmel_branch a non-empty string" "$(jq -r '[.[] | select((.merge_allowed | type) != "boolean" or (.himmel_branch | type) != "string" or .himmel_branch == "")] | length' "$REG" 2>/dev/null)" "0"
check "merge_allowed true only for the forks we merge into" "$(jq -r '[.[] | select(.merge_allowed) | .nwo] | sort | join(" ")' "$REG" 2>/dev/null)" "$MERGE_TRUE"

if [ "$fails" -eq 0 ]; then
  echo "PASS - test-himmel-adapters.sh"
else
  echo "FAIL - test-himmel-adapters.sh ($fails failure(s))"
  exit 1
fi
