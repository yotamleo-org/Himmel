#!/usr/bin/env bash
# scripts/guardrails/test-himmel-adapters.sh - shape and coverage of the fork registry
#
# Platform guard: POSIX bash 3.2+, jq.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../lib/fixture-tempdir.sh" || exit 1
TMP=$(fixture_mktemp_dir) || exit 1
trap 'rm -rf "$TMP"' EXIT
check() { # name actual expected
  if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: got '$2' want '$3'"; fi
}

ROWS="yotamleo-org/caveman yotamleo-org/claude-hud yotamleo-org/claude-obsidian yotamleo-org/claude-squad yotamleo-org/claude-statusline yotamleo-org/claude-video yotamleo-org/codex yotamleo-org/codex-plugin-cc yotamleo-org/core yotamleo-org/effective-html yotamleo-org/graphify yotamleo-org/hermes-agent yotamleo-org/himmel-voice yotamleo-org/home-assistant.io yotamleo-org/obsidian-second-brain yotamleo-org/obsidian-skills yotamleo-org/qmd yotamleo-org/twitter-cli"
MERGE_TRUE="yotamleo-org/graphify yotamleo-org/himmel-voice yotamleo-org/obsidian-skills yotamleo-org/qmd"
CORE_ROWS="yotamleo-org/graphify yotamleo-org/qmd"
# the recorded output of `gh repo list yotamleo-org --fork --json name` (2026-10-19)
FORK_LIST="$HERE/fixtures/himmel-adapters/yotamleo-org-forks.json"
# the recorded output of `gh repo list yotamleo-org --source --json name,isFork` for the
# first-party adapter repos (2026-10-26)
FIRST_PARTY_LIST="$HERE/fixtures/himmel-adapters/yotamleo-org-first-party.json"

registry_checks() { # registry file
  local REG=$1 ADOPTED=$2
check "registry parses as a JSON array" "$(jq -r 'type' "$REG" 2>/dev/null)" "array"
check "every fork row is yotamleo-org/<a fork in the recorded gh repo list>" "$(jq -n -r --slurpfile reg "$REG" --slurpfile forks "$FORK_LIST" '[$reg[0][] | select(.upstream != null) | .nwo | select((split("/")[0] != "yotamleo-org") or ((split("/")[1]) as $n | any($forks[0][]; .name == $n) | not))] | length' 2>/dev/null)" "0"
check "every first-party row is yotamleo-org/<a non-fork in the recorded gh repo list>" "$(jq -n -r --slurpfile reg "$REG" --slurpfile own "$FIRST_PARTY_LIST" '[$reg[0][] | select(.upstream == null) | .nwo | select((split("/")[0] != "yotamleo-org") or ((split("/")[1]) as $n | any($own[0][]; .name == $n and .isFork == false) | not))] | length' 2>/dev/null)" "0"
check "every fork and first-party repo has a row, none extra" "$(jq -r '[.[].nwo] | sort | join(" ")' "$REG" 2>/dev/null)" "$ROWS"
check "no nwo is listed twice" "$(jq -r '[.[].nwo] | length - (unique | length)' "$REG" 2>/dev/null)" "0"
check "every row has the seven fields" "$(jq -r '[.[] | select((keys - ["pin_branch"] | sort) != ["himmel_branch","merge_allowed","nwo","pin_site","role","tier","upstream"])] | length' "$REG" 2>/dev/null)" "0"
check "every role is one of the five" "$(jq -r '[.[] | select(.role | IN("runtime-dependency","upstream-contribution","vendored-source","dormant","first-party") | not)] | length' "$REG" 2>/dev/null)" "0"
check "every row has a tier of CORE, LIGHT or PARK" "$(jq -r '[.[] | select(.tier | IN("CORE","LIGHT","PARK") | not)] | length' "$REG" 2>/dev/null)" "0"
check "CORE only for the forks himmel runs on" "$(jq -r '[.[] | select(.tier == "CORE") | .nwo] | sort | join(" ")' "$REG" 2>/dev/null)" "$CORE_ROWS"
check "obsidian-skills tracks its true upstream obsidianmd/obsidian-skills" "$(jq -r '[.[] | select(.nwo == "yotamleo-org/obsidian-skills") | .upstream] | first' "$REG" 2>/dev/null)" "obsidianmd/obsidian-skills"
check "role first-party exactly when upstream is null" "$(jq -r '[.[] | select((.role == "first-party") != (.upstream == null))] | length' "$REG" 2>/dev/null)" "0"
check "merge_allowed is a boolean and himmel_branch a non-empty string" "$(jq -r '[.[] | select((.merge_allowed | type) != "boolean" or (.himmel_branch | type) != "string" or .himmel_branch == "")] | length' "$REG" 2>/dev/null)" "0"
check "every upstream is an owner/name, or null for a first-party repo" "$(jq -r '[.[] | select(.upstream != null) | select((.upstream | type) != "string" or (.upstream | test("^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$") | not))] | length' "$REG" 2>/dev/null)" "0"
check "pin_site is null or a non-empty string" "$(jq -r '[.[] | select(.pin_site != null and ((.pin_site | type) != "string" or .pin_site == ""))] | length' "$REG" 2>/dev/null)" "0"
check "merge_allowed true only for the repos we merge into" "$(jq -r '[.[] | select(.merge_allowed) | .nwo] | sort | join(" ")' "$REG" 2>/dev/null)" "$MERGE_TRUE"
# a fork block in upstreams.json drives /fork-resync and the drift check's fork-behind probe
check "every upstreams.json fork block names its registry row's himmel_branch" "$(jq -n -r --slurpfile reg "$REG" --slurpfile up "$HERE/../upstreams.json" '[$up[0].entries[] | select(.fork) | .name as $n | (.fork.fork_repo | sub("\\.git$"; "") | split("/") | last) as $r | ([$reg[0][] | select((.nwo | split("/")[1]) == $r) | .himmel_branch] | first) as $b | select($b == null or $b != .fork.branch) | "\($n):\(.fork.branch)"] | if length == 0 then "none" else join(" ") end' 2>/dev/null)" "none"
check "every pin_branch row has a fork block in upstreams.json" "$(jq -n -r --slurpfile reg "$REG" --slurpfile up "$HERE/../upstreams.json" '[$reg[0][] | select(has("pin_branch")) | (.nwo | split("/")[1]) as $r | select(any($up[0].entries[]; .fork and ((.fork.fork_repo | sub("\\.git$"; "") | split("/") | last) == $r)) | not) | .nwo] | if length == 0 then "none" else join(" ") end' 2>/dev/null)" "none"
check "every pin_branch is himmel-main-upstream-<synced_base> of its fork block" "$(jq -n -r --slurpfile reg "$REG" --slurpfile up "$HERE/../upstreams.json" '[$reg[0][] | select(has("pin_branch")) | .pin_branch as $p | (.nwo | split("/")[1]) as $r | ([$up[0].entries[] | select(.fork and ((.fork.fork_repo | sub("\\.git$"; "") | split("/") | last) == $r))] | first) as $e | select($e != null) | (if ($e.synced_base | type) == "string" and $e.synced_base != "" then "himmel-main-upstream-" + $e.synced_base else null end) as $want | select($p != $want) | .nwo] | if length == 0 then "none" else join(" ") end' 2>/dev/null)" "none"
check "no nwo is in both himmel-adapters.json and himmel-adopted.json" "$(jq -n -r --slurpfile reg "$REG" --slurpfile ad "$ADOPTED" '[$reg[0][].nwo] as $r | [$ad[0][]? | .nwo | select(. as $n | $r | index($n))] | length' 2>/dev/null)" "0"
}

out=$(registry_checks "$HERE/himmel-adapters.json" "$HERE/himmel-adopted.json")
printf '%s\n' "$out"
fails=$(printf '%s\n' "$out" | grep -c '^FAIL')

refused() {
  local name=$1 filter=$2 check_name=$3 adopted=${4:-$HERE/himmel-adopted.json}
  if ! jq "$filter" "$HERE/himmel-adapters.json" > "$TMP/reg.json"; then
    echo "FAIL $name: jq could not build the broken copy"; fails=$((fails + 1)); return
  fi
  case "$(registry_checks "$TMP/reg.json" "$adopted")" in
    *"FAIL $check_name:"*) hit=1 ;;
    *) hit=0 ;;
  esac
  if [ "$hit" -eq 1 ]; then
    echo "ok   $name"
  else
    echo "FAIL $name: the '$check_name' check did not refuse it"; fails=$((fails + 1))
  fi
}
refused "a dormant row with upstream null is refused" 'map(if .nwo == "yotamleo-org/himmel-voice" then .role = "dormant" else . end)' "role first-party exactly when upstream is null"
refused "a first-party row with an upstream is refused" 'map(if .nwo == "yotamleo-org/himmel-voice" then .upstream = "x/y" else . end)' "role first-party exactly when upstream is null"
refused "a row with no tier is refused" 'map(if .nwo == "yotamleo-org/twitter-cli" then del(.tier) else . end)' "every row has a tier of CORE, LIGHT or PARK"
refused "a row with an unknown tier is refused" 'map(if .nwo == "yotamleo-org/twitter-cli" then .tier = "WARM" else . end)' "every row has a tier of CORE, LIGHT or PARK"
refused "a pin_branch that is not himmel-main-upstream-<synced_base> is refused" 'map(if .nwo == "yotamleo-org/qmd" then .pin_branch = "himmel-main-upstream-0.0.0" else . end)' "every pin_branch is himmel-main-upstream-<synced_base> of its fork block"
refused "a pin_branch on a row with no fork block is refused" 'map(if .nwo == "yotamleo-org/obsidian-skills" then .pin_branch = "himmel-main-upstream-1.0.0" else . end)' "every pin_branch row has a fork block in upstreams.json"
refused "an unknown extra key is refused" 'map(if .nwo == "yotamleo-org/qmd" then .pin_banch = "x" else . end)' "every row has the seven fields"
printf '[{"nwo":"yotamleo-org/qmd"}]\n' > "$TMP/adopted-overlap.json"
refused "a repo in both allowlists is refused" '.' "no nwo is in both himmel-adapters.json and himmel-adopted.json" "$TMP/adopted-overlap.json"

if [ "$fails" -eq 0 ]; then
  echo "PASS - test-himmel-adapters.sh"
else
  echo "FAIL - test-himmel-adapters.sh ($fails failure(s))"
  exit 1
fi
