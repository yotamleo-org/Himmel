#!/usr/bin/env bash
# test-leg-graph-rationale.sh -- leg-graph.sh asks graphify for the stored `rationale` text of a
# semantic node (--rationale: a WHY suffix on the NODE line for query, a Rationale line for
# explain) and ranks why/how answers by it. Stub rows run everywhere; the five-question table
# runs the real graphify against scripts/graphify/fixtures/rationale-graph.json and is skipped
# when the installed graphify does not take --rationale.
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

# Every stub below prints the rationale text only when --rationale is passed, as graphify does.
# Stub graphify: verbatim shape of the real query / explain output on the fixture.
cat > "$T/bin/graphify" <<'STUB'
#!/bin/sh
why=""
for a in "$@"; do [ "$a" = "--rationale" ] && why=" WHY An attacker who can only make the child do less has a mild DoS, not a compromise."; done
case "$1" in
  query)
    echo "Graph: x (14 nodes) | Traversal: BFS depth=2 | Start: ['Halt'] | 2 nodes found"
    echo ""
    echo "NODE Halt/narrowing needs no token (fail-safe asymmetry) [src=docs/internals/retask-channel.md loc=None community=]$why"
    echo "NODE Need [src=scripts/board-model.ts loc=L16 community=]"
    echo "EDGE Need --calls [EXTRACTED]--> Need" ;;
  explain)
    echo "Node: Halt/narrowing needs no token (fail-safe asymmetry)"
    echo "  ID:        retask_halt"
    echo "  Source:    docs/internals/retask-channel.md None"
    echo "  Type:      concept"
    [ -n "$why" ] && echo "  Rationale:${why#' WHY'}" ;;
esac
STUB
chmod +x "$T/bin/graphify"

# T1: query shows the stored reason on the semantic node's line, and only there.
out="$(run query "why does a halt need no token")"
if grep "^NODE $HALT" <<<"$out" | grep -q "\] WHY $REASON"; then pass "T1 query prints the rationale on its NODE line"
else fail "T1 out='$out'"; fi
if [ "$(grep -c '^NODE ' <<<"$out")" = 2 ] && [ "$(grep -c '\] WHY ' <<<"$out")" = 1 ]; then pass "T1b NODE lines unchanged, one rationale"
else fail "T1b out='$out'"; fi

# T2: explain gets a Rationale line.
out="$(run explain "$HALT")"
if grep -q "^  Rationale: $REASON" <<<"$out"; then pass "T2 explain prints the rationale"
else fail "T2 out='$out'"; fi

# Stub graphify for the ranking rows: name-matched code nodes come first, as on the live graph.
cat > "$T/bin/graphify" <<'STUB'
#!/bin/sh
why=""
for a in "$@"; do [ "$a" = "--rationale" ] && why=" WHY An attacker who can only make the child do less has a mild DoS, not a compromise."; done
echo "Graph: x (14 nodes) | Traversal: BFS depth=2 | Start: ['Need', 'Token'] | 4 nodes found"
echo ""
echo "NODE Need [src=scripts/board-model.ts loc=L16 community=]"
echo "NODE Token [src=scripts/ansi.ts loc=L11 community=]"
echo "NODE RETASK channel [src=AGENTS.md loc=Subagent policy community=]"
echo "NODE Halt/narrowing needs no token (fail-safe asymmetry) [src=docs/internals/retask-channel.md loc=None community=]$why"
echo "EDGE Need --calls [EXTRACTED]--> Need"
STUB
chmod +x "$T/bin/graphify"

# T7: a why question lists the rationale node first, then the doc node, then code.
out="$(run query "why does a halt need no token")"
order="$(grep "^NODE " <<<"$out" | sed "s/^NODE //; s/ \[src=.*//" | tr "\n" "|")"
if [ "$order" = "$HALT|RETASK channel|Need|Token|" ] && grep "^NODE $HALT" <<<"$out" | grep -q "\] WHY $REASON" && [ "$(tail -1 <<<"$out")" = "EDGE Need --calls [EXTRACTED]--> Need" ]; then pass "T7 why question ranks rationale, then doc, then code nodes"
else fail "T7 order='$order' out='$out'"; fi

# T8: a question that is not why/how keeps graphify's order byte for byte.
want="$(PATH="$T/bin:$PATH" graphify query x --rationale)"
for q in "what is the RETASK channel" "Token" "show me how-to docs" "how-to docs for jira" "reason codes for transition"; do
  out="$(run query "$q")"
  if [ "$out" = "$want" ]; then pass "T8 '$q' keeps graphify's order"
  else fail "T8 '$q' out='$out'"; fi
done

# T10: a flag before the question still ranks the answer: the question is the first non-flag argument.
out="$(run query --budget 6000 "why does a halt need no token")"
order="$(grep "^NODE " <<<"$out" | sed "s/^NODE //; s/ \[src=.*//" | tr "\n" "|")"
if [ "$order" = "$HALT|RETASK channel|Need|Token|" ]; then pass "T10 --budget before the question still ranks it"
else fail "T10 order='$order'"; fi

# T11: a start node the caller gave stays first, ahead of the doc and rationale tiers.
cat > "$T/bin/graphify" <<'STUB'
#!/bin/sh
why=""
for a in "$@"; do [ "$a" = "--rationale" ] && why=" WHY An attacker who can only make the child do less has a mild DoS, not a compromise."; done
echo "Graph: x (14 nodes) | Traversal: BFS depth=2 | Start (given): ['queue-lock.sh'] | 4 nodes found"
echo ""
echo "NODE queue-lock.sh [src=scripts/handover/queue-lock.sh loc=L1 community=]"
echo "NODE Need [src=scripts/board-model.ts loc=L16 community=]"
echo "NODE RETASK channel [src=AGENTS.md loc=Subagent policy community=]"
echo "NODE Halt/narrowing needs no token (fail-safe asymmetry) [src=docs/internals/retask-channel.md loc=None community=]$why"
STUB
out="$(run query "why does a halt need no token")"
order="$(grep "^NODE " <<<"$out" | sed "s/^NODE //; s/ \[src=.*//" | tr "\n" "|")"
if [ "$order" = "queue-lock.sh|$HALT|RETASK channel|Need|" ]; then pass "T11 a given start node stays above the ranked tiers"
else fail "T11 order='$order'"; fi

# T12: added doc nodes never push the answer past the requested budget (3 chars per token);
# trailing code nodes make room for them instead.
cat > "$T/bin/graphify" <<'STUB'
#!/bin/sh
echo "Graph: x (14 nodes) | Traversal: BFS depth=2 | Start: ['Transition'] | 6 nodes found"
echo ""
echo "NODE Transition [src=scripts/jira/resolution.test.ts loc=L5 community=]"
echo "NODE Need [src=scripts/board-model.ts loc=L16 community=]"
echo "NODE need() [src=scripts/plan-index.sh loc=L25 community=]"
echo "NODE Token [src=scripts/ansi.ts loc=L11 community=]"
echo "NODE egress() [src=scripts/lib/test-claude-lane.sh loc=L45 community=]"
echo "NODE console() [src=scripts/nav.js loc=L9 community=]"
STUB
budget=160
raw="$(PATH="$T/bin:$PATH" graphify query x --rationale)"
limit=$(( budget * 3 > ${#raw} ? budget * 3 : ${#raw} ))
out="$(run query "why does the jira transition at merge need an explicit flag" --budget "$budget")"
if [ "${#out}" -le "$limit" ] && grep -q '^NODE completes-ticket' <<<"$out" && grep -q '^NODE Transition ' <<<"$out"; then pass "T12 added nodes stay inside the budget (${#out} of $limit chars)"
else fail "T12 ${#out} chars over limit $limit: out='$out'"; fi

# T9: a why question whose answer misses the reason node gets it added, from the words of the question.
cat > "$T/bin/graphify" <<'STUB'
#!/bin/sh
echo "Graph: x (14 nodes) | Traversal: BFS depth=2 | Start: ['Transition'] | 2 nodes found"
echo ""
echo "NODE Transition [src=scripts/jira/resolution.test.ts loc=L5 community=]"
echo "NODE Need [src=scripts/board-model.ts loc=L16 community=]"
STUB
out="$(run query "why does the jira transition at merge need an explicit flag")"
first="$(grep -m1 '^NODE ' <<<"$out")"
if [ "${first%% \[src=*}" = "NODE completes-ticket line and Ticket coverage" ] && grep '^NODE completes-ticket' <<<"$out" | grep -q '\] WHY The merge script closes the ticket only on --jira-transition' && [ "$(grep -c '^NODE ' <<<"$out")" -le 5 ] && grep -q '| 2 nodes found (+[1-3] doc/rationale nodes added for a why/how question)$' <<<"$out"; then pass "T9 the reason node missing from the answer is added first, and the header says so"
else fail "T9 out='$out'"; fi

# T5: the five spot-check questions against the fixture, real graphify.
if command -v graphify >/dev/null 2>&1 && graphify --help 2>&1 | grep -q -- '--rationale'; then
  rm -f "$T/bin/graphify"
  carried=0
  while IFS='|' read -r q text want; do
    out="$(run query "$text")"; rc=$?
    n_nodes="$(grep -c '^NODE ' <<<"$out")"
    if [ "$rc" != 0 ] || [ "$n_nodes" = 0 ]; then fail "T5 $q graphify answered rc=$rc with $n_nodes nodes"; continue; fi
    if [ -n "$want" ]; then
      if grep -F '] WHY ' <<<"$out" | grep -qF "$want"; then carried=$((carried+1)); pass "T5 $q answer carries the reason text ($n_nodes nodes)"
      else fail "T5 $q answer lacks the reason text"; fi
    else
      if ! grep -q '\] WHY ' <<<"$out"; then pass "T5 $q has no reason-bearing node in the fixture, nothing invented"
      else fail "T5 $q printed a rationale it should not have"; fi
    fi
  done <<EOF
Q1|why does the graphify egress block exist and which corpora does it protect|
Q2|why does a RETASK narrowing need no token while an expansion does|$REASON
Q3|which role launches a leg and which one watches it|
Q4|why is the graph path verb banned|
Q5|why does the Jira transition at merge need an explicit flag completes-ticket|closes the ticket only on --jira-transition
EOF
  echo "  five-question table: $carried of 5 answers carry the reason text"
else
  echo "  skip: T5 five-question table (graphify missing or without --rationale)"
fi

if [ "$FAILS" -ne 0 ]; then echo "$FAILS FAILURES"; exit 1; fi
echo "ALL PASS"
