#!/usr/bin/env bash
# test-leg-graph-rationale.sh -- leg-graph.sh prints the stored `rationale` text of a semantic
# node under its NODE line (query) and a Rationale line (explain). graphify keeps the text on
# the node but its printer never shows it. Stub rows run everywhere; the
# five-question table runs the real graphify against scripts/graphify/fixtures/rationale-graph.json
# and is skipped when graphify is not installed.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/leg-graph.sh"
FIXTURE="$HERE/fixtures/rationale-graph.json"
FAILS=0
pass() { echo "  ok: $1"; }
fail() { echo "  FAIL: $1"; FAILS=$((FAILS+1)); }

T="$(mktemp -d "${TMPDIR:-/tmp}/leg-graph-rationale.XXXXXX")" || exit 1
trap 'rm -rf "$T"' EXIT
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
P="$T/primary"
git init -q -b main "$P"
git -C "$P" commit -q --allow-empty -m base
mkdir -p "$P/graphify-out" "$T/bin"
cp "$FIXTURE" "$P/graphify-out/graph.json"
run() { (cd "$P" && PATH="$T/bin:$PATH" bash "$SCRIPT" "$@" 2>"$T/err"); }

HALT='Halt/narrowing needs no token (fail-safe asymmetry)'
REASON='An attacker who can only make the child do less has a mild DoS'

# Stub graphify: verbatim shape of the real query / explain output on the fixture.
cat > "$T/bin/graphify" <<'STUB'
#!/bin/sh
case "$1" in
  query)
    echo "Graph: x (14 nodes) | Traversal: BFS depth=2 | Start: ['Halt'] | 2 nodes found"
    echo ""
    echo "NODE Halt/narrowing needs no token (fail-safe asymmetry) [src=docs/internals/retask-channel.md loc=None community=]"
    echo "NODE Need [src=scripts/board-model.ts loc=L16 community=]"
    echo "EDGE Need --calls [EXTRACTED]--> Need" ;;
  explain)
    echo "Node: Halt/narrowing needs no token (fail-safe asymmetry)"
    echo "  ID:        retask_halt"
    echo "  Source:    docs/internals/retask-channel.md None"
    echo "  Type:      concept" ;;
esac
STUB
chmod +x "$T/bin/graphify"

# T1: query shows the stored reason right under the semantic node, and only there.
out="$(run query "why does a halt need no token")"
if grep -A1 "^NODE $HALT" <<<"$out" | grep -q "RATIONALE: $REASON"; then pass "T1 query prints the rationale under its NODE line"
else fail "T1 out='$out'"; fi
if [ "$(grep -c '^NODE ' <<<"$out")" = 2 ] && [ "$(grep -c 'RATIONALE:' <<<"$out")" = 1 ]; then pass "T1b NODE lines unchanged, one rationale line"
else fail "T1b out='$out'"; fi

# T2: explain gets a Rationale line.
out="$(run explain "$HALT")"
if grep -q "^  Rationale: $REASON" <<<"$out"; then pass "T2 explain prints the rationale"
else fail "T2 out='$out'"; fi

# T3: an unreadable graph fails open, exit code and text unchanged.
cp "$P/graphify-out/graph.json" "$T/graph.good"
printf 'not json' > "$P/graphify-out/graph.json"
out="$(run query "q")"; rc=$?
if [ "$rc" = 0 ] && grep -q '^NODE Need ' <<<"$out" && ! grep -q 'RATIONALE:' <<<"$out" && grep -q 'append-rationale' "$T/err"; then pass "T3 unreadable graph prints the plain answer and says so"
else fail "T3 rc=$rc out='$out' err=$(cat "$T/err")"; fi
cp "$T/graph.good" "$P/graphify-out/graph.json"

# T4: control characters in a rationale never reach the terminal, long text is capped.
python3 -I - "$P/graphify-out/graph.json" <<'PY'
import json, sys
p = sys.argv[1]
g = json.load(open(p))
for n in g["nodes"]:
    if n["id"] == "retask_halt":
        n["rationale"] = "bad\x1b[31m red\nline " + "x" * 600
json.dump(g, open(p, "w"))
PY
out="$(run query "q")"
line="$(grep 'RATIONALE:' <<<"$out")"
if [ -n "$line" ] && ! grep -q "$(printf '\033')" <<<"$line" && [ "${#line}" -le 420 ] && grep -q '\.\.\.$' <<<"$line"; then pass "T4 control characters stripped, text capped"
else fail "T4 line='$line'"; fi
cp "$T/graph.good" "$P/graphify-out/graph.json"

# T5: the five spot-check questions against the fixture, real graphify.
if command -v graphify >/dev/null 2>&1; then
  rm -f "$T/bin/graphify"
  carried=0
  while IFS='|' read -r q text want; do
    out="$(run query "$text")"; rc=$?
    n_nodes="$(grep -c '^NODE ' <<<"$out")"
    if [ "$rc" != 0 ] || [ "$n_nodes" = 0 ]; then fail "T5 $q graphify answered rc=$rc with $n_nodes nodes"; continue; fi
    if [ -n "$want" ]; then
      if grep -F 'RATIONALE:' <<<"$out" | grep -qF "$want"; then carried=$((carried+1)); pass "T5 $q answer carries the reason text ($n_nodes nodes)"
      else fail "T5 $q answer lacks the reason text"; fi
    else
      if ! grep -q 'RATIONALE:' <<<"$out"; then pass "T5 $q has no reason-bearing node in the fixture, nothing invented"
      else fail "T5 $q printed a rationale it should not have"; fi
    fi
  done <<EOF
Q1|why does the graphify egress block exist and which corpora does it protect|
Q2|why does a RETASK narrowing or halt need no token while an expansion does|$REASON
Q3|how do a console and a leg relate|
Q4|why is the graph path verb banned|
Q5|why does the Jira transition at merge need an explicit flag completes-ticket|closes the ticket only on --jira-transition
EOF
  echo "  five-question table: $carried of 5 answers carry the reason text"
else
  echo "  skip: T5 five-question table (graphify not installed)"
fi

if [ "$FAILS" -ne 0 ]; then echo "$FAILS FAILURES"; exit 1; fi
echo "ALL PASS"
