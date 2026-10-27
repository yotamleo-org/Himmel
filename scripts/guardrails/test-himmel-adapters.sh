#!/usr/bin/env bash
# scripts/guardrails/test-himmel-adapters.sh - shape and coverage of the fork registry
# scripts/guardrails/himmel-adapters.json: every yotamleo fork and first-party adapter repo has
# exactly one row, each row has the six fields with a legal role, and the operator-ruled
# merge_allowed set holds. A first-party repo has upstream null and role first-party.
#
# Platform guard (gitbash-only): POSIX bash 3.2+, jq.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../lib/fixture-tempdir.sh" || exit 1
TMP=$(fixture_mktemp_dir) || exit 1
trap 'rm -rf "$TMP"' EXIT
check() { # name actual expected
  if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: got '$2' want '$3'"; fi
}

ROWS="yotamleo-org/caveman yotamleo-org/claude-hud yotamleo-org/claude-obsidian yotamleo-org/claude-squad yotamleo-org/claude-statusline yotamleo-org/claude-video yotamleo-org/codex yotamleo-org/codex-plugin-cc yotamleo-org/core yotamleo-org/effective-html yotamleo-org/graphify yotamleo-org/hermes-agent yotamleo-org/himmel-voice yotamleo-org/home-assistant.io yotamleo-org/obsidian-second-brain yotamleo-org/obsidian-skills yotamleo-org/qmd"
MERGE_TRUE="yotamleo-org/claude-video yotamleo-org/graphify yotamleo-org/himmel-voice yotamleo-org/obsidian-second-brain yotamleo-org/obsidian-skills yotamleo-org/qmd"
# the recorded output of `gh repo list yotamleo-org --fork --json name` (2026-10-19)
FORK_LIST="$HERE/fixtures/himmel-adapters/yotamleo-org-forks.json"
# the recorded output of `gh repo list yotamleo-org --source --json name,isFork` for the
# first-party adapter repos (2026-10-26)
FIRST_PARTY_LIST="$HERE/fixtures/himmel-adapters/yotamleo-org-first-party.json"

registry_checks() { # registry file
  local REG=$1
check "registry parses as a JSON array" "$(jq -r 'type' "$REG" 2>/dev/null)" "array"
check "every fork row is yotamleo-org/<a fork in the recorded gh repo list>" "$(jq -n -r --slurpfile reg "$REG" --slurpfile forks "$FORK_LIST" '[$reg[0][] | select(.upstream != null) | .nwo | select((split("/")[0] != "yotamleo-org") or ((split("/")[1]) as $n | any($forks[0][]; .name == $n) | not))] | length' 2>/dev/null)" "0"
check "every first-party row is yotamleo-org/<a non-fork in the recorded gh repo list>" "$(jq -n -r --slurpfile reg "$REG" --slurpfile own "$FIRST_PARTY_LIST" '[$reg[0][] | select(.upstream == null) | .nwo | select((split("/")[0] != "yotamleo-org") or ((split("/")[1]) as $n | any($own[0][]; .name == $n and .isFork == false) | not))] | length' 2>/dev/null)" "0"
check "every fork and first-party repo has a row, none extra" "$(jq -r '[.[].nwo] | sort | join(" ")' "$REG" 2>/dev/null)" "$ROWS"
check "no nwo is listed twice" "$(jq -r '[.[].nwo] | length - (unique | length)' "$REG" 2>/dev/null)" "0"
check "every row has the six fields" "$(jq -r '[.[] | select((keys | sort) != ["himmel_branch","merge_allowed","nwo","pin_site","role","upstream"])] | length' "$REG" 2>/dev/null)" "0"
check "every role is one of the five" "$(jq -r '[.[] | select(.role | IN("runtime-dependency","upstream-contribution","vendored-source","dormant","first-party") | not)] | length' "$REG" 2>/dev/null)" "0"
check "role first-party exactly when upstream is null" "$(jq -r '[.[] | select((.role == "first-party") != (.upstream == null))] | length' "$REG" 2>/dev/null)" "0"
check "merge_allowed is a boolean and himmel_branch a non-empty string" "$(jq -r '[.[] | select((.merge_allowed | type) != "boolean" or (.himmel_branch | type) != "string" or .himmel_branch == "")] | length' "$REG" 2>/dev/null)" "0"
check "every upstream is an owner/name, or null for a first-party repo" "$(jq -r '[.[] | select(.upstream != null) | select((.upstream | type) != "string" or (.upstream | test("^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$") | not))] | length' "$REG" 2>/dev/null)" "0"
check "pin_site is null or a non-empty string" "$(jq -r '[.[] | select(.pin_site != null and ((.pin_site | type) != "string" or .pin_site == ""))] | length' "$REG" 2>/dev/null)" "0"
check "merge_allowed true only for the repos we merge into" "$(jq -r '[.[] | select(.merge_allowed) | .nwo] | sort | join(" ")' "$REG" 2>/dev/null)" "$MERGE_TRUE"
# a fork block in upstreams.json drives /fork-resync and the drift check's fork-behind probe
check "every upstreams.json fork block names its registry row's himmel_branch" "$(jq -n -r --slurpfile reg "$REG" --slurpfile up "$HERE/../upstreams.json" '[$up[0].entries[] | select(.fork) | .name as $n | (.fork.fork_repo | sub("\\.git$"; "") | split("/") | last) as $r | ([$reg[0][] | select((.nwo | split("/")[1]) == $r) | .himmel_branch] | first) as $b | select($b == null or $b != .fork.branch) | "\($n):\(.fork.branch)"] | if length == 0 then "none" else join(" ") end' 2>/dev/null)" "none"
}

out=$(registry_checks "$HERE/himmel-adapters.json")
printf '%s\n' "$out"
fails=$(printf '%s\n' "$out" | grep -c '^FAIL')

# a broken copy of the real registry must be refused by the role/upstream check itself
refused() { # name jq-filter
  if ! jq "$2" "$HERE/himmel-adapters.json" > "$TMP/reg.json"; then
    echo "FAIL $1: jq could not build the broken copy"; fails=$((fails + 1)); return
  fi
  case "$(registry_checks "$TMP/reg.json")" in
    *"FAIL role first-party exactly when upstream is null:"*) hit=1 ;;
    *) hit=0 ;;
  esac
  if [ "$hit" -eq 1 ]; then
    echo "ok   $1"
  else
    echo "FAIL $1: the role/upstream check did not refuse it"; fails=$((fails + 1))
  fi
}
refused "a dormant row with upstream null is refused" 'map(if .nwo == "yotamleo-org/himmel-voice" then .role = "dormant" else . end)'
refused "a first-party row with an upstream is refused" 'map(if .nwo == "yotamleo-org/himmel-voice" then .upstream = "x/y" else . end)'

if [ "$fails" -eq 0 ]; then
  echo "PASS - test-himmel-adapters.sh"
else
  echo "FAIL - test-himmel-adapters.sh ($fails failure(s))"
  exit 1
fi
