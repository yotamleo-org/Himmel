#!/usr/bin/env bash
# scripts/docs/check-dev-graph.sh — fail when docs/guide/dev-graph/graph.json no
# longer matches the code it names.
#
# ponytail: binds structure, not caption meaning. A node's anchor must still
# occur exactly once in its file and every exit code / WAKE kind / check / marker
# of a covered table must be mapped or listed unmapped with a reason; whether a
# summary still describes the behaviour stays a reviewer's call. Table parsers
# read the scripts' comment headers and printf shapes, floors live in graph.json
# (visible in the diff that lowers one); an AST or a generated table is the upgrade.
#
# Usage: check-dev-graph.sh [--graph <file>] [--root <dir>] [--suite <file>] [--table]
#   --graph  default <root>/docs/guide/dev-graph/graph.json
#   --root   default the repo root; every source file is resolved under it
#   --suite  default scripts/docs/test-dev-graph.sh; its text must name every
#            source basename (impacted-suites.sh selects a suite by basename)
#   --table  also print the resolved `id  file:line  anchor` table for reviewers
# Exit: 0 clean, 1 drift (every failure printed as `FAIL <id> <file>: why`),
#       2 usage or unreadable graph.
#
# Anchors are fixed strings (grep -F) without backslash or tab. Line numbers are
# resolved here and never committed.
#
# Platform guard (gitbash-only): bash 3.2+, jq, awk, grep, sort, comm.
set -u

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
GRAPH=
SUITE=
TABLE=0
while [ "$#" -gt 0 ]; do
  case $1 in
    --graph) GRAPH=${2:-}; shift 2 || exit 2 ;;
    --root) ROOT=${2:-}; shift 2 || exit 2 ;;
    --suite) SUITE=${2:-}; shift 2 || exit 2 ;;
    --table) TABLE=1; shift ;;
    *) echo "usage: check-dev-graph.sh [--graph <file>] [--root <dir>] [--suite <file>] [--table]" >&2; exit 2 ;;
  esac
done
[ -n "$GRAPH" ] || GRAPH=$ROOT/docs/guide/dev-graph/graph.json
[ -n "$SUITE" ] || SUITE=$ROOT/scripts/docs/test-dev-graph.sh

command -v jq >/dev/null 2>&1 || { echo "check-dev-graph: jq not installed" >&2; exit 2; }
[ -f "$GRAPH" ] || { echo "check-dev-graph: graph not found: $GRAPH" >&2; exit 2; }
jq -e '.version == 1' "$GRAPH" >/dev/null 2>&1 || { echo "check-dev-graph: $GRAPH is not a version 1 graph" >&2; exit 2; }
# Every query below assumes this shape; a jq error inside a $(...) would not count as a
# failure, so a malformed entry must stop the run here instead of passing unseen.
SHAPE='
  def str: type == "string";
  def src: ((.sources // []) | type) == "array"
    and all((.sources // [])[]; type == "object" and (.file | str) and ((.anchor // "") | str));
  (.lanes | type) == "array" and (.nodes | type) == "array" and (.edges | type) == "array"
  and (.walkthroughs | type) == "array" and (.coverage | type) == "object"
  and all(.lanes[]; type == "object" and (.id | str))
  and all(.nodes[]; type == "object" and (.id | str) and (.lane | str) and ((.pos // {}) | type) == "object" and src)
  and all(.edges[]; type == "object" and (.id | str) and (.from | str) and (.to | str) and (.kind | str) and src)
  and all(.walkthroughs[]; type == "object" and (.id | str) and (.steps | type) == "array" and all(.steps[]; type == "object" and (.at | str)))
  and all(.coverage[]; type == "object" and ((.mapped // {}) | type) == "object" and ((.unmapped // {}) | type) == "object")'
jq -e "$SHAPE" "$GRAPH" >/dev/null 2>&1 || { echo "check-dev-graph: $GRAPH is malformed (lanes/nodes/edges/walkthroughs/coverage entries have the wrong shape)" >&2; exit 2; }

TMP=$(mktemp -d "${TMPDIR:-/tmp}/check-dev-graph.XXXXXX") || exit 2
trap 'rm -rf "$TMP"' EXIT

fails=0
fail() { fails=$((fails + 1)); echo "FAIL $*" >&2; }

# --- 1. integrity ----------------------------------------------------------
for id in $(jq -r '[.nodes[].id, .edges[].id] | group_by(.) | map(select(length > 1) | .[0])[]' "$GRAPH"); do
  fail "$id: duplicate id"
done
for row in $(jq -r '(.nodes | map(.id)) as $n | .edges[] | select(([.from, .to] - $n) | length > 0) | "\(.id):\(([.from, .to] - $n) | join(","))"' "$GRAPH"); do
  fail "${row%%:*}: edge endpoint does not exist (${row#*:})"
done
for id in $(jq -r '.nodes[] | select((.pos.wide | type) != "object" or (.pos.narrow | type) != "object") | .id' "$GRAPH"); do
  fail "$id: node lacks pos.wide or pos.narrow"
done
for row in $(jq -r '(.lanes | map(.id)) as $l | .nodes[] | select(.lane | IN($l[]) | not) | "\(.id):\(.lane)"' "$GRAPH"); do
  fail "${row%%:*}: node in unknown lane ${row#*:}"
done
for row in $(jq -r '.edges[] | select(.kind | IN("flow", "decision", "refusal", "loop") | not) | "\(.id):\(.kind)"' "$GRAPH"); do
  fail "${row%%:*}: unknown edge kind ${row#*:}"
done
for row in $(jq -r '(.nodes | map(.id)) as $n | .walkthroughs[] | .id as $w | .steps[] | select(.at | IN($n[]) | not) | "\($w):\(.at)"' "$GRAPH"); do
  fail "${row%%:*}: walkthrough step at unknown node ${row#*:}"
done
for row in $(jq -r '(.edges | map(.id)) as $e | .walkthroughs[] | .id as $w | .steps[] | select(.ghost != null and (.ghost | IN($e[]) | not)) | "\($w):\(.ghost)"' "$GRAPH"); do
  fail "${row%%:*}: walkthrough ghost edge does not exist (${row#*:})"
done
for row in $(jq -r '(.edges | map([.from, .to])) as $E | .walkthroughs[] | .id as $w | .steps as $s | range(1; ($s | length)) | . as $i | $s[$i - 1].at as $a | $s[$i].at as $b | select($a != $b and (($E | index([[$a, $b]])) == null)) | "\($w):\($a):\($b)"' "$GRAPH"); do
  w=${row%%:*}; rest=${row#*:}
  fail "$w: consecutive steps ${rest%%:*} and ${rest#*:} are not joined by an edge"
done

# --- 2. anchors ------------------------------------------------------------
: > "$TMP/files"
jq -r '(.nodes[], .edges[]) | .id as $id | (.sources // [])[] | [$id, .file, (.anchor // "")] | @tsv' "$GRAPH" > "$TMP/sources"
printf '' > "$TMP/resolved"
while IFS="$(printf '\t')" read -r id file anchor; do
  [ -n "$id" ] || continue
  printf '%s\n' "$file" >> "$TMP/files"
  if [ -z "$anchor" ]; then fail "$id $file: empty anchor"; continue; fi
  # shellcheck disable=SC1003
  case $anchor in *'\'*) fail "$id $file: anchor holds a backslash (the loader would mangle it): $anchor"; continue ;; esac
  if [ ! -f "$ROOT/$file" ]; then fail "$id $file: source file missing"; continue; fi
  n=$(grep -oF -- "$anchor" "$ROOT/$file" | wc -l | tr -d ' ')
  if [ "$n" -ne 1 ]; then fail "$id $file: anchor occurs $n times, want exactly 1: $anchor"; continue; fi
  line=$(grep -nF -- "$anchor" "$ROOT/$file" | head -n 1 | cut -d: -f1)
  printf '%s\t%s:%s\t%s\n' "$id" "$file" "$line" "$anchor" >> "$TMP/resolved"
done < "$TMP/sources"

# --- 3. coverage -----------------------------------------------------------
# codes_<table> <file>: the codes the file's table holds now, one per line.
codes_exit() {
  awk '
    /^# Exit codes:/ { on = 1; next }
    on && !/^#/ { exit }
    on && /^# ?[A-Z][A-Za-z\/ ]*:[[:space:]]*$/ { exit }
    on && /^#   [0-9]/ { print $2 }' "$1"
}
codes_checks() {
  awk '
    /^# Checks:/ { on = 1; next }
    on && !/^#/ { exit }
    on && /^#[[:space:]]+[0-9]+\.[[:space:]]/ { s = $2; sub(/\./, "", s); print s }' "$1"
}
codes_wake() {
  grep -oE "printf 'WAKE [a-z-]+( (complete|partial))?" "$1" | sed "s/^printf 'WAKE //"
}
codes_markers() {
  # shellcheck disable=SC2016
  awk '/starting with `LIVE`/ { on = 1 } on { print } on && /RESUMED/ { exit }' "$1" | grep -oE '`[A-Z][A-Z-]+`' | tr -d '`'
}

jq -r '.coverage | keys[]' "$GRAPH" > "$TMP/covfiles"
while IFS= read -r cf; do
  [ -n "$cf" ] || continue
  printf '%s\n' "$cf" >> "$TMP/files"
  table=$(jq -r --arg f "$cf" '.coverage[$f].table // ""' "$GRAPH")
  floor=$(jq -r --arg f "$cf" '.coverage[$f].floor // 0' "$GRAPH")
  if [ ! -f "$ROOT/$cf" ]; then fail "coverage $cf: source file missing"; continue; fi
  case $table in
    exit|checks|wake|markers) ;;
    *) fail "coverage $cf: unknown table kind '$table'"; continue ;;
  esac
  case $floor in ''|*[!0-9]*) fail "coverage $cf: floor is not a number"; continue ;; esac
  "codes_$table" "$ROOT/$cf" | sort -u > "$TMP/parsed"
  parsed_n=$(wc -l < "$TMP/parsed" | tr -d ' ')
  if [ "$floor" -lt 1 ] || [ "$parsed_n" -lt "$floor" ]; then
    fail "coverage $cf: $table parser found $parsed_n code(s), floor $floor (the header shape changed, or the floor is unset)"
  fi
  jq -r --arg f "$cf" '.coverage[$f] | ((.mapped // {}) + (.unmapped // {})) | keys[]' "$GRAPH" | sort -u > "$TMP/declared"
  for code in $(comm -23 "$TMP/parsed" "$TMP/declared" | tr ' ' '_'); do
    fail "coverage $cf: $table '$(printf '%s' "$code" | tr '_' ' ')' has no graph decision (map it to an edge or list it unmapped with a reason)"
  done
  for code in $(comm -13 "$TMP/parsed" "$TMP/declared" | tr ' ' '_'); do
    fail "coverage $cf: $table '$(printf '%s' "$code" | tr '_' ' ')' is in the graph but no longer in the file (stale entry)"
  done
  for row in $(jq -r --arg f "$cf" '(.nodes + .edges | map(.id)) as $ids | .coverage[$f].mapped // {} | to_entries[] | select(.value | IN($ids[]) | not) | "\(.key | gsub(" "; "_")):\(.value)"' "$GRAPH"); do
    fail "coverage $cf: '$(printf '%s' "${row%%:*}" | tr '_' ' ')' maps to missing id ${row#*:}"
  done
  for code in $(jq -r --arg f "$cf" '.coverage[$f].unmapped // {} | to_entries[] | select((.value | type) != "string" or (.value | length) == 0) | .key | gsub(" "; "_")' "$GRAPH"); do
    fail "coverage $cf: unmapped '$(printf '%s' "$code" | tr '_' ' ')' has no reason"
  done
  for code in $(jq -r --arg f "$cf" '.coverage[$f] | ((.mapped // {}) | keys) as $m | ((.unmapped // {}) | keys)[] | select(IN($m[])) | gsub(" "; "_")' "$GRAPH"); do
    fail "coverage $cf: '$(printf '%s' "$code" | tr '_' ' ')' is both mapped and unmapped"
  done
done < "$TMP/covfiles"

# --- 4. selection self-check -----------------------------------------------
if [ ! -f "$SUITE" ]; then
  fail "suite $SUITE: not found (impacted-suites.sh could not select it)"
else
  sort -u "$TMP/files" > "$TMP/uniq-files"
  while IFS= read -r f; do
    b=${f##*/}
    grep -qF -- "$b" "$SUITE" || fail "$f: basename '$b' is not named in the suite $SUITE (a PR editing it would not select the suite)"
  done < "$TMP/uniq-files"
fi

if [ "$TABLE" -eq 1 ]; then
  while IFS="$(printf '\t')" read -r id loc anchor; do
    printf '%-24s %-70s %s\n' "$id" "$loc" "$anchor"
  done < "$TMP/resolved"
fi

nn=$(jq '.nodes | length' "$GRAPH"); ne=$(jq '.edges | length' "$GRAPH")
if [ "$fails" -gt 0 ]; then
  echo "check-dev-graph: FAIL ($fails problem(s); $nn nodes, $ne edges)" >&2
  exit 1
fi
echo "check-dev-graph: PASS ($nn nodes, $ne edges)"
