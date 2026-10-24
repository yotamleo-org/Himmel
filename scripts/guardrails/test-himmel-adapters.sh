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

FORKS="yotamleo-org/caveman yotamleo-org/claude-hud yotamleo-org/claude-obsidian yotamleo-org/claude-squad yotamleo-org/claude-statusline yotamleo-org/claude-video yotamleo-org/codex yotamleo-org/codex-plugin-cc yotamleo-org/core yotamleo-org/effective-html yotamleo-org/graphify yotamleo-org/hermes-agent yotamleo-org/home-assistant.io yotamleo-org/obsidian-second-brain yotamleo-org/obsidian-skills yotamleo-org/qmd yotamleo-org/twitter-cli"
MERGE_TRUE="yotamleo-org/claude-video yotamleo-org/graphify yotamleo-org/obsidian-second-brain yotamleo-org/obsidian-skills yotamleo-org/qmd yotamleo-org/twitter-cli"
# the recorded output of `gh repo list yotamleo-org --fork --json name` (2026-10-19)
FORK_LIST="$HERE/fixtures/himmel-adapters/yotamleo-org-forks.json"

check "registry parses as a JSON array" "$(jq -r 'type' "$REG" 2>/dev/null)" "array"
check "every nwo is yotamleo-org/<a fork in the recorded gh repo list>" "$(jq -n -r --slurpfile reg "$REG" --slurpfile forks "$FORK_LIST" '[$reg[0][].nwo | select((split("/")[0] != "yotamleo-org") or ((split("/")[1]) as $n | any($forks[0][]; .name == $n) | not))] | length' 2>/dev/null)" "0"
check "every fork has a row, none extra" "$(jq -r '[.[].nwo] | sort | join(" ")' "$REG" 2>/dev/null)" "$FORKS"
check "no nwo is listed twice" "$(jq -r '[.[].nwo] | length - (unique | length)' "$REG" 2>/dev/null)" "0"
check "every row has the six fields" "$(jq -r '[.[] | select((keys | sort) != ["himmel_branch","merge_allowed","nwo","pin_site","role","upstream"])] | length' "$REG" 2>/dev/null)" "0"
check "every role is one of the four" "$(jq -r '[.[] | select(.role | IN("runtime-dependency","upstream-contribution","vendored-source","dormant") | not)] | length' "$REG" 2>/dev/null)" "0"
check "merge_allowed is a boolean and himmel_branch a non-empty string" "$(jq -r '[.[] | select((.merge_allowed | type) != "boolean" or (.himmel_branch | type) != "string" or .himmel_branch == "")] | length' "$REG" 2>/dev/null)" "0"
check "every upstream is an owner/name" "$(jq -r '[.[] | select((.upstream | type) != "string" or (.upstream | test("^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$") | not))] | length' "$REG" 2>/dev/null)" "0"
check "pin_site is null or a non-empty string" "$(jq -r '[.[] | select(.pin_site != null and ((.pin_site | type) != "string" or .pin_site == ""))] | length' "$REG" 2>/dev/null)" "0"
check "merge_allowed true only for the forks we merge into" "$(jq -r '[.[] | select(.merge_allowed) | .nwo] | sort | join(" ")' "$REG" 2>/dev/null)" "$MERGE_TRUE"
# a fork block in upstreams.json drives /fork-resync and the drift check's fork-behind probe
check "every upstreams.json fork block names its registry row's himmel_branch" "$(jq -n -r --slurpfile reg "$REG" --slurpfile up "$HERE/../upstreams.json" '[$up[0].entries[] | select(.fork) | .name as $n | (.fork.fork_repo | sub("\\.git$"; "") | split("/") | last) as $r | ([$reg[0][] | select((.nwo | split("/")[1]) == $r) | .himmel_branch] | first) as $b | select($b == null or $b != .fork.branch) | "\($n):\(.fork.branch)"] | if length == 0 then "none" else join(" ") end' 2>/dev/null)" "none"

if [ "$fails" -eq 0 ]; then
  echo "PASS - test-himmel-adapters.sh"
else
  echo "FAIL - test-himmel-adapters.sh ($fails failure(s))"
  exit 1
fi
