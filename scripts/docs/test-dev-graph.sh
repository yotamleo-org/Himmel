#!/usr/bin/env bash
# test-dev-graph.sh — scripts/docs/check-dev-graph.sh fails when the development
# graph (docs/guide/dev-graph/graph.json) no longer matches the code it names.
#
# J-DG0 rows, each on a fixture root with a one-script graph (no real repo
# state is touched):
#   (a) a removed, duplicated or unresolvable anchor fails, naming node + file;
#   (b) a new exit code / WAKE kind / check / marker with no graph decision fails;
#   (c) a reshaped table header (parser finds fewer codes than its floor) fails;
#   integrity (dangling edge, duplicate id, missing pos, unjoined walkthrough);
#   selection (a source basename the suite does not name fails);
# then the real graph passes against the real tree.
#
# Source basenames the real graph binds. impacted-suites.sh selects a suite by
# basename, so each is named here literally (check-dev-graph.sh enforces it):
#   console.sh console-wait.sh tick.sh next-dispatchable.sh gen-briefs.py
#   headed-arm-leg.sh running-a-console.md leg-preface.md check-commit-msg.sh
#   .pre-commit-config.yaml check-cr-before-push.sh pr-check.md
#   panel-first-pass.sh review-round.sh glossary.md grant-round.sh
#   check-cr-marker-on-pr-create.sh check-ci.sh ready-check.sh judge-ladder.sh
#   write-verdict.sh verdict-go.sh go.sh merge-on-green.sh
#   block-unresolved-cr-merge.sh wrap-subtree-check.sh leg-event.sh
#   residual-lines.sh wrap-merged.sh close-wrapped-leg.sh succession-tracker.sh
#
# Platform guard (gitbash-only): bash 3.2+, jq, awk, grep.
# Usage: bash scripts/docs/test-dev-graph.sh
set -u

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
CHECK="$ROOT/scripts/docs/check-dev-graph.sh"
SELF="$ROOT/scripts/docs/test-dev-graph.sh"

pass=0
fail=0
ok() { pass=$((pass + 1)); echo "ok - $*"; }
bad() { fail=$((fail + 1)); echo "not ok - $*"; }

TMP=$(mktemp -d "${TMPDIR:-/tmp}/dev-graph-test.XXXXXX") || exit 2
trap 'rm -rf "$TMP"' EXIT

command -v jq >/dev/null 2>&1 || { echo "not ok - jq not installed (the checker needs it, so nothing here could run)"; exit 1; }

# --- fixture ---------------------------------------------------------------
# fx <dir>: a root holding tool.sh (exit table), wake.sh (WAKE kinds),
# gate.sh (numbered checks), preface.md (status markers), a suite naming them
# all, and a graph that covers every one of them.
fx() {
  d=$1
  mkdir -p "$d/bin"
  cat > "$d/bin/tool.sh" <<'EOF'
#!/usr/bin/env bash
# Exit codes:
#   0   ok
#   10  refused thing
#   11  other thing
# Env:
exit 0
EOF
  cat > "$d/bin/wake.sh" <<'EOF'
#!/usr/bin/env bash
printf 'WAKE alpha\n'
printf 'WAKE beta %s\n' "$x"
printf 'WAKE gamma complete %s\n' "$x"
EOF
  cat > "$d/bin/gate.sh" <<'EOF'
#!/usr/bin/env bash
# Checks:
#   1. first check
#  10. tenth check
# Exit codes:
#   0 - pass
EOF
  cat > "$d/preface.md" <<'EOF'
bullet not
starting with `LIVE` / `READY` /
`WRAPPED`, invisible.
EOF
  cat > "$d/suite.txt" <<'EOF'
tool.sh wake.sh gate.sh preface.md
EOF
  cat > "$d/graph.json" <<'EOF'
{
  "version": 1,
  "lanes": [{"id": "console", "label": "Console"}],
  "nodes": [
    {"id": "n.a", "lane": "console", "phase": "dispatch", "label": "A", "summary": "a",
     "sources": [{"file": "bin/tool.sh", "anchor": "refused thing"}],
     "pos": {"wide": {"x": 1, "y": 1}, "narrow": {"y": 1}}},
    {"id": "n.b", "lane": "console", "phase": "build", "label": "B", "summary": "b",
     "sources": [],
     "pos": {"wide": {"x": 2, "y": 1}, "narrow": {"y": 2}}}
  ],
  "edges": [
    {"id": "e.ab", "from": "n.a", "to": "n.b", "kind": "refusal", "exit": 10,
     "condition": "c", "sources": [{"file": "bin/tool.sh", "anchor": "refused thing"}]},
    {"id": "e.ba", "from": "n.b", "to": "n.a", "kind": "flow", "condition": "c", "sources": []}
  ],
  "walkthroughs": [
    {"id": "w1", "title": "t", "steps": [{"at": "n.a", "caption": "x"}, {"at": "n.b", "caption": "y"}, {"at": "n.a", "caption": "z", "ghost": "e.ab"}]}
  ],
  "coverage": {
    "bin/tool.sh": {"table": "exit", "floor": 3, "mapped": {"10": "e.ab"}, "unmapped": {"0": "success", "11": "operational"}},
    "bin/wake.sh": {"table": "wake", "floor": 3, "mapped": {"alpha": "e.ab"}, "unmapped": {"beta": "x", "gamma complete": "x"}},
    "bin/gate.sh": {"table": "checks", "floor": 2, "mapped": {"1": "e.ab", "10": "e.ab"}, "unmapped": {}},
    "preface.md": {"table": "markers", "floor": 3, "mapped": {"LIVE": "n.a", "WRAPPED": "n.b"}, "unmapped": {"READY": "x"}}
  }
}
EOF
}

# run <dir> [extra args]: the checker on fixture <dir>; sets out + rc.
run() {
  d=$1; shift
  out=$(bash "$CHECK" --root "$d" --graph "$d/graph.json" --suite "$d/suite.txt" "$@" 2>&1)
  rc=$?
}

# expect_fail <label> <needle...>: last run exited 1 and printed every needle.
expect_fail() {
  label=$1; shift
  if [ "$rc" -ne 1 ]; then bad "$label: rc=$rc, want 1 :: $out"; return; fi
  for n in "$@"; do
    case $out in
      *"$n"*) ;;
      *) bad "$label: output lacks '$n' :: $out"; return ;;
    esac
  done
  ok "$label"
}

# mut <dir> <jq filter>: rewrite the fixture graph.
mut() { jq "$2" "$1/graph.json" > "$1/graph.tmp" && mv "$1/graph.tmp" "$1/graph.json"; }

# --- control ---------------------------------------------------------------
D=$TMP/base; fx "$D"
run "$D"
if [ "$rc" -eq 0 ]; then ok "control: fixture graph passes"; else bad "control: rc=$rc :: $out"; fi
run "$D" --table
case $out in
  *"n.a"*"bin/tool.sh:4"*) ok "control: --table resolves node n.a to bin/tool.sh:4" ;;
  *) bad "control: --table lacks the resolved file:line :: $out" ;;
esac

# --- (a) anchors -----------------------------------------------------------
D=$TMP/a1; fx "$D"
sed -i.bak 's/refused thing/gone/' "$D/bin/tool.sh"
run "$D"
expect_fail "(a) removed anchor fails naming node and file" "n.a" "e.ab" "bin/tool.sh" "0 times"

D=$TMP/a2; fx "$D"
printf '# refused thing again\n' >> "$D/bin/tool.sh"
run "$D"
expect_fail "(a) duplicated anchor fails" "n.a" "2 times"

D=$TMP/a3; fx "$D"
rm "$D/bin/tool.sh"
run "$D"
expect_fail "(a) missing source file fails" "n.a" "missing"

D=$TMP/a4; fx "$D"
mut "$D" '.nodes[0].sources[0].anchor = ""'
run "$D"
expect_fail "(a) empty anchor fails" "n.a" "empty anchor"

# --- (b) new code with no graph decision ----------------------------------
D=$TMP/b1; fx "$D"
sed -i.bak 's/^#   11  other thing/#   11  other thing\n#   12  brand new refusal/' "$D/bin/tool.sh"
run "$D"
expect_fail "(b) new exit code 12 fails" "bin/tool.sh" "12" "no graph decision"

D=$TMP/b2; fx "$D"
printf "printf 'WAKE delta\\\\n'\n" >> "$D/bin/wake.sh"
run "$D"
expect_fail "(b) new WAKE kind fails" "bin/wake.sh" "delta"

D=$TMP/b3; fx "$D"
sed -i.bak 's/^#   1. first check/#   1. first check\n#   2. second check/' "$D/bin/gate.sh"
run "$D"
expect_fail "(b) new check fails" "bin/gate.sh" "2"

D=$TMP/b4; fx "$D"
# shellcheck disable=SC2016
sed -i.bak 's/^`WRAPPED`, invisible./`WRAPPED` \/ `HALTED`, invisible./' "$D/preface.md"
run "$D"
expect_fail "(b) new status marker fails" "preface.md" "HALTED"

D=$TMP/b5; fx "$D"
sed -i.bak '/^#   11  other thing/d' "$D/bin/tool.sh"
run "$D"
expect_fail "(b) a mapped/unmapped code gone from the script fails (stale entry)" "bin/tool.sh" "11" "stale"

D=$TMP/b6; fx "$D"
mut "$D" '.coverage["bin/tool.sh"].unmapped["11"] = ""'
run "$D"
expect_fail "(b) unmapped without a reason fails" "bin/tool.sh" "11" "reason"

D=$TMP/b7; fx "$D"
mut "$D" '.coverage["bin/tool.sh"].mapped["10"] = "e.nope"'
run "$D"
expect_fail "(b) mapped to a missing edge fails" "bin/tool.sh" "e.nope"

# --- (c) reshaped header under the floor ----------------------------------
D=$TMP/c1; fx "$D"
sed -i.bak -e 's/^#   10  refused thing/# - 10: refused thing/' -e 's/^#   11  other thing/# - 11: other thing/' "$D/bin/tool.sh"
mut "$D" '.coverage["bin/tool.sh"] |= (.mapped = {} | .unmapped = {})'
run "$D"
expect_fail "(c) reshaped header: parser under its floor fails, not vacuous" "bin/tool.sh" "floor 3"

# --- integrity -------------------------------------------------------------
D=$TMP/i1; fx "$D"
mut "$D" '.edges[0].to = "n.zzz"'
run "$D"
expect_fail "integrity: dangling edge target fails" "e.ab" "n.zzz"

D=$TMP/i2; fx "$D"
mut "$D" '.nodes[1].id = "n.a"'
run "$D"
expect_fail "integrity: duplicate id fails" "n.a" "duplicate"

D=$TMP/i3; fx "$D"
mut "$D" 'del(.nodes[0].pos.narrow)'
run "$D"
expect_fail "integrity: node without pos.narrow fails" "n.a" "pos"

D=$TMP/i4; fx "$D"
mut "$D" '.edges |= map(select(.id != "e.ba")) | .edges[0].to = "n.a" | .edges[0].from = "n.a"'
run "$D"
expect_fail "integrity: walkthrough steps with no joining edge fail" "w1" "n.a" "n.b"

D=$TMP/i5; fx "$D"
mut "$D" '.walkthroughs[0].steps[2].ghost = "e.nope"'
run "$D"
expect_fail "integrity: walkthrough ghost edge that does not exist fails" "w1" "e.nope"

D=$TMP/i6; fx "$D"
mut "$D" '.nodes[0].lane = "nolane"'
run "$D"
expect_fail "integrity: node in an unknown lane fails" "n.a" "nolane"

D=$TMP/min; fx "$D"
printf '{"version":1}\n' > "$D/graph.json"
run "$D"
if [ "$rc" -eq 2 ]; then ok "integrity: a graph holding only a version is a usage error, not a pass"; else bad "integrity: version-only graph rc=$rc, want 2 :: $out"; fi
D=$TMP/min2; fx "$D"
mut "$D" '.edges = [1]'
run "$D"
if [ "$rc" -eq 2 ]; then ok "integrity: a non-object edge entry is a usage error, not a pass"; else bad "integrity: edges [1] rc=$rc, want 2 :: $out"; fi
D=$TMP/min3; fx "$D"
mut "$D" '.nodes[0].sources = [{"file": 7}]'
run "$D"
if [ "$rc" -eq 2 ]; then ok "integrity: a non-string source file is a usage error, not a pass"; else bad "integrity: file 7 rc=$rc, want 2 :: $out"; fi

# --- selection -------------------------------------------------------------
D=$TMP/s1; fx "$D"
printf 'tool.sh gate.sh preface.md\n' > "$D/suite.txt"
run "$D"
expect_fail "selection: a source basename the suite never names fails" "wake.sh" "suite"

# --- drawing data: token copy and path endpoints ---------------------------
# The docs page loads its own byte copy of the canonical tokens.css.
tokens_in_sync() { cmp -s "$1" "$2"; }
CANON=$ROOT/site/src/styles/tokens.css
COPY=$ROOT/docs/guide/dev-graph/tokens.css
D=$TMP/tok; mkdir -p "$D"
cp "$CANON" "$D/canon.css"; cp "$CANON" "$D/copy.css"
if tokens_in_sync "$D/canon.css" "$D/copy.css"; then ok "tokens: an identical copy is in sync"; else bad "tokens: an identical copy reads as drifted"; fi
printf ' ' >> "$D/copy.css"
if tokens_in_sync "$D/canon.css" "$D/copy.css"; then bad "tokens: a one-byte edit to the copy still reads as in sync (vacuous)"; else ok "tokens: a one-byte edit to the copy fails the sync"; fi
if tokens_in_sync "$CANON" "$COPY"; then ok "tokens: docs/guide/dev-graph/tokens.css is byte-identical to the canonical file"; else bad "tokens: docs/guide/dev-graph/tokens.css differs from site/src/styles/tokens.css"; fi

# Prints the id of every edge whose wide path is missing, or does not start on its
# source node's box and end on its target's, within 2 px. M/H/V paths only.
# shellcheck disable=SC2016  # jq program text, not shell expansion
PATHS_JQ='
  def pts: reduce (scan("([MHV])\\s*(-?[0-9.]+)(?:\\s*,\\s*(-?[0-9.]+))?")) as $t ({pts: []};
    if $t[0] == "M" then .x = ($t[1] | tonumber) | .y = ($t[2] | tonumber)
    elif $t[0] == "H" then .x = ($t[1] | tonumber)
    else .y = ($t[1] | tonumber) end
    | .pts += [[.x, .y]]) | .pts;
  def onbox($c; $hw; $hh; $p):
    (($p[0] - $c.x) | fabs) as $dx | (($p[1] - $c.y) | fabs) as $dy
    | $dx <= $hw + 2 and $dy <= $hh + 2 and ($dx >= $hw - 2 or $dy >= $hh - 2);
  (.view.wide.box[0] / 2) as $hw | (.view.wide.box[1] / 2) as $hh
  | (.nodes | map({key: .id, value: .pos.wide}) | from_entries) as $at
  | .edges[]
  | . as $e
  | ((.path.wide // "") | pts) as $p
  | select(($p | length) < 2
      or (onbox($at[$e.from]; $hw; $hh; $p[0]) | not)
      or (onbox($at[$e.to]; $hw; $hh; $p[-1]) | not))
  | .id'
paths_bad() { jq -r "$PATHS_JQ" "$1" 2>&1; }

REAL=$ROOT/docs/guide/dev-graph/graph.json
if [ -f "$REAL" ]; then
  bad_ids=$(paths_bad "$REAL")
  if [ -z "$bad_ids" ]; then ok "paths: every edge path starts and ends on its nodes' boxes"; else bad "paths: edges off their boxes: $bad_ids"; fi
  D=$TMP/pathmut; mkdir -p "$D"
  jq '.edges[0].path.wide |= sub("^M(?<x>[0-9]+)"; "M\(.x | tonumber + 10)")' "$REAL" > "$D/moved.json"
  first_id=$(jq -r '.edges[0].id' "$REAL")
  case $(paths_bad "$D/moved.json") in
    *"$first_id"*) ok "paths: a start moved 10 px off its box fails, naming $first_id" ;;
    *) bad "paths: a start moved 10 px off its box still passes (vacuous)" ;;
  esac
  jq 'del(.edges[1].path)' "$REAL" > "$D/missing.json"
  second_id=$(jq -r '.edges[1].id' "$REAL")
  case $(paths_bad "$D/missing.json") in
    *"$second_id"*) ok "paths: an edge with no wide path fails, naming $second_id" ;;
    *) bad "paths: an edge with no wide path still passes (vacuous)" ;;
  esac
fi

# --- the real graph --------------------------------------------------------
if [ -f "$ROOT/docs/guide/dev-graph/graph.json" ]; then
  out=$(bash "$CHECK" 2>&1); rc=$?
  if [ "$rc" -eq 0 ]; then ok "real graph matches the real tree"; else bad "real graph: rc=$rc :: $out"; fi
else
  bad "real graph docs/guide/dev-graph/graph.json is missing"
fi

# every basename the header comment promises is really named in this file
for b in console.sh console-wait.sh tick.sh merge-on-green.sh go.sh check-ci.sh ready-check.sh; do
  if grep -qF "$b" "$SELF"; then :; else bad "suite does not name $b"; fi
done

echo "# $pass passed, $fail failed"
[ "$fail" -eq 0 ]
