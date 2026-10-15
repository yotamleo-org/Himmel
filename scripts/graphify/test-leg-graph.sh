#!/usr/bin/env bash
# test-leg-graph.sh — leg-graph.sh points graphify at the PRIMARY
# checkout's graphify-out/ from a linked worktree, refuses `path`, and says so
# when the graph is behind the worktree. A graphify stub on PATH echoes what it
# was given, so no real graph is needed.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/leg-graph.sh"
FAILS=0
pass() { echo "  ok: $1"; }
fail() { echo "  FAIL: $1"; FAILS=$((FAILS+1)); }

T="$(mktemp -d "${TMPDIR:-/tmp}/leg-graph-test.XXXXXX")" || exit 1
trap 'rm -rf "$T"' EXIT
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
P="$T/primary"
git init -q -b main "$P"
git -C "$P" commit -q --allow-empty -m base
BASE="$(git -C "$P" rev-parse HEAD)"
mkdir -p "$P/graphify-out"
printf '{"nodes":[],"built_at_commit": "%s"}\n' "$BASE" > "$P/graphify-out/graph.json"
git -C "$P" worktree add -q -b leg "$T/wt"
mkdir -p "$T/bin"
# shellcheck disable=SC2016  # the stub's own $-expansions must stay literal
printf '#!/bin/sh\necho "STUB GRAPHIFY_OUT=$GRAPHIFY_OUT ARGS=$*"\n' > "$T/bin/graphify"
chmod +x "$T/bin/graphify"
run() { (cd "$T/wt" && PATH="$T/bin:$PATH" bash "$SCRIPT" "$@" 2>"$T/err"); }

# T1: query from the worktree resolves to the primary's graphify-out.
out="$(run query "what is X")"; rc=$?
if [ "$rc" = 0 ] && [ "$out" = "STUB GRAPHIFY_OUT=$P/graphify-out ARGS=query what is X" ]; then
  pass "T1 query from a worktree targets the primary graph"
else fail "T1 rc=$rc out='$out'"; fi

# T2: graph at the worktree's HEAD → no staleness note.
if ! grep -q behind "$T/err"; then pass "T2 current graph prints no staleness note"
else fail "T2 unexpected note: $(cat "$T/err")"; fi

# T3: worktree two commits ahead of the graph → note names the count.
git -C "$T/wt" commit -q --allow-empty -m a
git -C "$T/wt" commit -q --allow-empty -m b
run explain "Y" >/dev/null
if grep -q '2 commits behind' "$T/err"; then pass "T3 stale graph says how far behind"
else fail "T3 no staleness note: $(cat "$T/err")"; fi

# T4: `path` is refused (file-scoped node ids make it wrong).
run path A B >/dev/null; rc=$?
if [ "$rc" = 2 ]; then pass "T4 path refused"; else fail "T4 rc=$rc"; fi

# T5: missing graph → exit 2, says so, never silent.
mv "$P/graphify-out/graph.json" "$P/graphify-out/graph.json.x"
run query q >/dev/null; rc=$?
if [ "$rc" = 2 ] && grep -q 'no graph' "$T/err"; then pass "T5 missing graph is loud"
else fail "T5 rc=$rc err=$(cat "$T/err")"; fi

if [ "$FAILS" -ne 0 ]; then echo "$FAILS FAILURES"; exit 1; fi
echo "ALL PASS"
