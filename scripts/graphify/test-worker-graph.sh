#!/usr/bin/env bash
# test-worker-graph.sh — worker-graph.sh points graphify at the PRIMARY
# checkout's graphify-out/ from a linked worktree, passes `path` through, and says so
# when the graph is behind the worktree. A graphify stub on PATH echoes what it
# was given, so no real graph is needed. It also answers from the wrapper's own checkout graph when the cwd repo has none, and explains the file node when an ambiguity sits in one file.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/worker-graph.sh"
FAILS=0
pass() { echo "  ok: $1"; }
fail() { echo "  FAIL: $1"; FAILS=$((FAILS+1)); }

T="$(mktemp -d "${TMPDIR:-/tmp}/worker-graph-test.XXXXXX")" || exit 1
# the script under test prints physical paths; macOS's /tmp is a symlink to /private/tmp
T="$(cd "$T" && pwd -P)" || exit 1
trap 'rm -rf "$T"' EXIT
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
P="$T/primary"
git init -q -b main "$P"
git -C "$P" commit -q --allow-empty -m base
BASE="$(git -C "$P" rev-parse HEAD)"
mkdir -p "$P/graphify-out"
printf '{"nodes":[],"built_at_commit": "%s"}\n' "$BASE" > "$P/graphify-out/graph.json"
git -C "$P" worktree add -q -b worker "$T/wt"
mkdir -p "$T/bin"
# shellcheck disable=SC2016  # the stub's own $-expansions must stay literal
printf '#!/bin/sh\n[ "$1" = --help ] && { echo "  --rationale"; exit 0; }\necho "STUB GRAPHIFY_OUT=$GRAPHIFY_OUT ARGS=$*"\n' > "$T/bin/graphify"
chmod +x "$T/bin/graphify"
mkdir -p "$T/home/.himmel" "$T/xdg"
printf '{}\n' > "$T/home/.himmel/config.json"
KIT="$T/kit"
mkdir -p "$KIT/scripts/graphify" "$KIT/scripts/himmelctl/lib"
cp "$HERE/worker-graph.sh" "$HERE"/*.py "$KIT/scripts/graphify/"
cp -R "$HERE/../lib" "$KIT/scripts/lib"
cp "$HERE/../himmelctl/lib/graph-choices.js" "$KIT/scripts/himmelctl/lib/"
git init -q -b main "$KIT"
git -C "$KIT" commit -q --allow-empty -m kit
SCRIPT="$KIT/scripts/graphify/worker-graph.sh"
run() { (cd "$T/wt" && HOME="$T/home" HIMMEL_CONFIG_DIR="$T/home/.himmel" XDG_DATA_HOME="$T/xdg" PATH="$T/bin:$PATH" bash "$SCRIPT" "$@" 2>"$T/err"); }

# T1: query from the worktree resolves to the primary's graphify-out.
out="$(run query "what is X")"; rc=$?
if [ "$rc" = 0 ] && [ "$out" = "STUB GRAPHIFY_OUT=$P/graphify-out ARGS=query what is X --rationale --budget 8000" ]; then
  pass "T1 query from a worktree targets the primary graph"
else fail "T1 rc=$rc out='$out'"; fi

# T1b: a graphify whose help lacks --rationale gets the question unchanged (no flag it would misread).
# shellcheck disable=SC2016  # the stub's own $-expansions must stay literal
printf '#!/bin/sh\n[ "$1" = --help ] && { echo "usage: graphify query"; exit 0; }\necho "STUB ARGS=$*"\n' > "$T/bin/graphify.old"
cp "$T/bin/graphify" "$T/bin/graphify.new"; cp "$T/bin/graphify.old" "$T/bin/graphify"
out="$(run query "what is X")"
if [ "$out" = "STUB ARGS=query what is X --budget 8000" ]; then pass "T1b no --rationale for a graphify without it"
else fail "T1b out='$out'"; fi
cp "$T/bin/graphify.new" "$T/bin/graphify"

# T1c-T1e: a hung graphify must not hang the wrapper. An outer timeout makes a missing bound fail the row, not the suite.
# shellcheck source=../lib/timeout-bin.sh
. "$HERE/../lib/timeout-bin.sh" 2>/dev/null
if [ -n "${_TIMEOUT_BIN:-}" ]; then
  hrun() { (cd "$T/wt" && PATH="$T/bin:$PATH" "$_TIMEOUT_BIN" -k 2 25 bash "$SCRIPT" "$@" 2>"$T/err"); }
  # shellcheck disable=SC2016  # the stub's own $-expansions must stay literal
  printf '#!/bin/sh\n[ "$1" = --help ] && { echo "$GRAPHIFY_NO_AUTO_REFRESH" > "%s/probe-env"; sleep 40; exit 0; }\necho "STUB ARGS=$*"\n' "$T" > "$T/bin/graphify"
  out="$(GRAPH_WRAP_PROBE_SECS=1 hrun query "what is X")"; rc=$?
  if [ "$rc" = 0 ] && [ "$out" = "STUB ARGS=query what is X --budget 8000" ]; then pass "T1c a hung --help probe is cut off and the query still runs"
  else fail "T1c rc=$rc out='$out'"; fi
  if [ "$(cat "$T/probe-env" 2>/dev/null)" = 1 ]; then pass "T1d the probe runs with GRAPHIFY_NO_AUTO_REFRESH=1"
  else fail "T1d probe env='$(cat "$T/probe-env" 2>/dev/null)'"; fi
  # shellcheck disable=SC2016  # the stub's own $-expansions must stay literal
  printf '#!/bin/sh\n[ "$1" = --help ] && { echo "  --rationale"; exit 0; }\nsleep 40\n' > "$T/bin/graphify"
  out="$(GRAPH_WRAP_CALL_SECS=1 hrun query "what is X")"; rc=$?
  if [ "$rc" = 124 ] && grep -q 'was stopped' "$T/err"; then pass "T1e a hung graphify call is cut off and reported"
  else fail "T1e rc=$rc err='$(cat "$T/err")'"; fi
else
  echo "  skip: T1c-T1e (no GNU timeout)"
fi
cp "$T/bin/graphify.new" "$T/bin/graphify"

# T2: graph at the worktree's HEAD → no staleness note.
if ! grep -q behind "$T/err"; then pass "T2 current graph prints no staleness note"
else fail "T2 unexpected note: $(cat "$T/err")"; fi

# T3: worktree two commits ahead of the graph → note names the count.
git -C "$T/wt" commit -q --allow-empty -m a
git -C "$T/wt" commit -q --allow-empty -m b
run explain "Y" >/dev/null
if grep -q '2 commits behind' "$T/err"; then pass "T3 stale graph says how far behind"
else fail "T3 no staleness note: $(cat "$T/err")"; fi

# T4: `path` on a cross-file pair reaches graphify against the primary graph
# (harden-graph.py merges one entity across files into one node).
out="$(run path "docs/a.md" "check.sh")"; rc=$?
if [ "$rc" = 0 ] && [ "$out" = "STUB GRAPHIFY_OUT=$P/graphify-out ARGS=path docs/a.md check.sh --budget 8000" ]; then
  pass "T4 path on a cross-file pair runs against the primary graph"
else fail "T4 rc=$rc out='$out'"; fi

# T5: missing graph → exit 2, says so, never silent.
mv "$P/graphify-out/graph.json" "$P/graphify-out/graph.json.x"
run query q >/dev/null; rc=$?
if [ "$rc" = 2 ] && grep -q 'no graph' "$T/err"; then pass "T5 missing graph is loud"
else fail "T5 rc=$rc err=$(cat "$T/err")"; fi
# T5b: the message says the graph covers code and points a notes search at qmd, not at a vault graph.
if grep -q 'covers code repos' "$T/err" && grep -q 'qmd-bounded.sh query' "$T/err"; then pass "T5b missing-graph message points notes at qmd"
else fail "T5b err=$(cat "$T/err")"; fi
# T5c: the qmd wrapper path in that message exists from a cwd outside the repo (a reader standing in a vault).
qpath="$(grep -o 'bash [^ ]*qmd-bounded.sh' "$T/err" | head -1 | sed 's/^bash //')"
if [ -n "$qpath" ] && [[ $qpath == /* ]] && (cd / && [ -f "$qpath" ]); then pass "T5c the printed qmd path exists from outside the repo"
else fail "T5c qpath='$qpath'"; fi
gpath="$(grep -o 'bash [^ ]*worker-graph.sh' "$T/err" | head -1 | sed 's/^bash //')"
if [ -n "$gpath" ] && [[ $gpath == /* ]] && (cd / && [ -f "$gpath" ]); then pass "T5d the printed graph path exists from outside the repo"
else fail "T5d gpath='$gpath'"; fi

# T6: a larger default --budget is passed; an explicit --budget wins.
mv "$P/graphify-out/graph.json.x" "$P/graphify-out/graph.json"
out="$(run query "q")"
if grep -q -- '--budget [0-9]\{4,\}' <<<"$out"; then pass "T6 default budget is raised"
else fail "T6 out='$out'"; fi
out="$(run query "q" --budget 123)"
if grep -q -- '--budget 123$' <<<"$out" && ! grep -q -- '--budget [0-9]* .*--budget' <<<"$out"; then pass "T6b explicit --budget is respected"
else fail "T6b out='$out'"; fi

out="$(run query "q" --budget=123)"
if grep -q -- '--budget=123$' <<<"$out" && ! grep -q -- '--budget 8000' <<<"$out"; then pass "T6c --budget=N is respected"
else fail "T6c out='$out'"; fi

# T7: a truncated answer gets an explicit re-run line naming the wrapper.
# shellcheck disable=SC2016  # the stub's own $-expansions must stay literal
printf '#!/bin/sh\n[ "$1" = --help ] && { echo "  --rationale"; exit 0; }\necho "[!] TRUNCATED: showing 60 of 223 nodes (~2000-token budget). raise the token budget to 7523 to get all 223 (CLI: --budget 7523)"\necho "NODE a"\n' > "$T/bin/graphify"
out="$(run query "two words")"; rc=$?
if [ "$rc" = 0 ] && grep -q 'NODE a' <<<"$out" && grep -q 'bash scripts/graphify/worker-graph.sh query '"'"'two words'"'"' --budget 7523' "$T/err"; then
  pass "T7 truncation prints a re-run line"
else fail "T7 rc=$rc err=$(cat "$T/err")"; fi

# shellcheck disable=SC2016  # the metacharacters must reach the wrapper literally
out="$(run query 'a$(x)b')"
if grep -qF "query 'a\$(x)b' --budget 7523" "$T/err"; then pass "T7b re-run line single-quotes shell metacharacters"
else fail "T7b err=$(cat "$T/err")"; fi

# T8: missing graph names the wrapper.
mv "$P/graphify-out/graph.json" "$P/graphify-out/graph.json.x"
run query q >/dev/null
if grep -q 'worker-graph.sh' "$T/err"; then pass "T8 missing-graph message names worker-graph.sh"
else fail "T8 err=$(cat "$T/err")"; fi

mkdir -p "$T/seam"
printf '{"nodes":[{"id":"scripts_go","source_file":"scripts/go.sh","label":"go.sh"}],"built_at_commit": "%s"}\n' "$BASE" > "$T/seam/graph.json"
# shellcheck disable=SC2016  # the stub's own $-expansions must stay literal
printf '#!/bin/sh\n[ "$1" = --help ] && { echo "  --rationale"; exit 0; }\necho "GRAPHIFY_OUT=$GRAPHIFY_OUT ARGS=$*" >> "%s/calls"\necho x\n' "$T" > "$T/bin/graphify"
rm -f "$T/calls"
(cd "$T/wt" && HOME="$T/home" HIMMEL_CONFIG_DIR="$T/home/.himmel" XDG_DATA_HOME="$T/xdg" WORKER_GRAPH_OUT="$T/seam" PATH="$T/bin:$PATH" bash "$SCRIPT" query "where is go.sh used" >/dev/null 2>"$T/err"); rc=$?
if [ "$rc" = 0 ] && grep -q "^GRAPHIFY_OUT=$T/seam ARGS=query .*--seed scripts_go .*--budget 4000" "$T/calls" \
   && ! grep -q "GRAPHIFY_OUT=$P/graphify-out" "$T/calls"; then
  pass "T9 worker_graph_out_seam reads the seam's graph and keeps its seeds and budget"
else fail "T9 rc=$rc calls='$(cat "$T/calls" 2>/dev/null)' err='$(cat "$T/err")'"; fi

GCJS="$KIT/scripts/himmelctl/lib/graph-choices.js"
LISTED_OUT="$T/xdg/himmel/graphify/choices/mine/graphify-out"
mkdir -p "$LISTED_OUT"
printf '{"nodes":[],"built_at_commit": "%s"}\n' "$BASE" > "$LISTED_OUT/graph.json"
# shellcheck disable=SC2016  # the stub's own $-expansions must stay literal
printf '#!/bin/sh\n[ "$1" = --help ] && { echo "  --rationale"; exit 0; }\necho "STUB GRAPHIFY_OUT=$GRAPHIFY_OUT ARGS=$*"\n' > "$T/bin/graphify"
mv "$P/graphify-out/graph.json.x" "$P/graphify-out/graph.json"
printf '{"graphify":{"choices":{"version":1,"corpora":[{"name":"mine","root":"%s"}],"primary":"none"}}}\n' "$P" > "$T/home/.himmel/config.json"
out="$(run query "what is X")"; rc=$?
if [ "$rc" = 0 ] && [ "$out" = "STUB GRAPHIFY_OUT=$LISTED_OUT ARGS=query what is X --rationale --budget 8000" ]; then
  pass "W1 a listed repo queries the graph the daily pass builds"
else fail "W1 rc=$rc out='$out'"; fi

printf '{"graphify":{"choices":{"version":1,"corpora":[{"name":"other","root":"%s"}],"primary":"none"}}}\n' "$T/elsewhere" > "$T/home/.himmel/config.json"
out="$(run query "what is X")"; rc=$?
if [ "$rc" = 0 ] && [ "$out" = "STUB GRAPHIFY_OUT=$P/graphify-out ARGS=query what is X --rationale --budget 8000" ]; then
  pass "W2 an unlisted repo behaves as at the merge base"
else fail "W2 rc=$rc out='$out'"; fi

rm -f "$LISTED_OUT/graph.json"
mv "$P/graphify-out/graph.json" "$P/graphify-out/graph.json.x"
printf '{"graphify":{"choices":{"version":1,"corpora":[{"name":"mine","root":"%s"}],"primary":"none"}}}\n' "$P" > "$T/home/.himmel/config.json"
run query q >/dev/null; rc=$?
REMEDY="$(HOME="$T/home" HIMMEL_CONFIG_DIR="$T/home/.himmel" node "$GCJS" remedy)"
if [ "$rc" = 2 ] && grep -qF "$REMEDY" "$T/err" && ! grep -q 'graph-refresh' "$T/err" && grep -q 'worker-graph.sh' "$T/err"; then
  pass "W3 a non-publisher's no-graph message prints the remedy and no refusing command"
else fail "W3 rc=$rc err=$(cat "$T/err")"; fi

printf '{"graphify":{"semantic_api_ok":true}}\n' > "$T/home/.himmel/config.json"
run query q >/dev/null; rc=$?
if [ "$rc" = 2 ] && grep -q 'graph-refresh' "$T/err"; then pass "W4 a publisher keeps the build instruction"
else fail "W4 rc=$rc err=$(cat "$T/err")"; fi

V="$T/vault"
git init -q -b main "$V"
git -C "$V" commit -q --allow-empty -m v
mkdir -p "$KIT/graphify-out"
printf '{"nodes":[],"built_at_commit": "%s"}\n' "$(git -C "$KIT" rev-parse HEAD)" > "$KIT/graphify-out/graph.json"
# shellcheck disable=SC2016  # the stub's own $-expansions must stay literal
printf '#!/bin/sh\n[ "$1" = --help ] && { echo "  --rationale"; exit 0; }\necho "STUB GRAPHIFY_OUT=$GRAPHIFY_OUT ARGS=$*"\n' > "$T/bin/graphify"
vrun() { (cd "$V" && HOME="$T/home" HIMMEL_CONFIG_DIR="$T/home/.himmel" XDG_DATA_HOME="$T/xdg" PATH="$T/bin:$PATH" bash "$SCRIPT" "$@" 2>"$T/err"); }
out="$(vrun explain "X")"; rc=$?
if [ "$rc" = 0 ] && [ "$out" = "STUB GRAPHIFY_OUT=$KIT/graphify-out ARGS=explain X --rationale --budget 8000" ] \
   && grep -qF "NOTE no graph at $V/graphify-out/graph.json; answering from $KIT/graphify-out/graph.json" "$T/err" \
   && ! grep -q 'not an ancestor' "$T/err"; then
  pass "F1 a cwd repo with no graph is answered from the wrapper's own checkout graph"
else fail "F1 rc=$rc out='$out' err='$(cat "$T/err")'"; fi

rm -f "$KIT/graphify-out/graph.json"
vrun explain "X" >/dev/null; rc=$?
want="worker-graph: no graph at $V/graphify-out/graph.json. The graph covers code repos, not notes: to search notes run: bash $KIT/scripts/lib/qmd-bounded.sh query -c <name> \"<question>\". In a code repo, build the graph from its primary checkout (/graph-refresh), then run: bash $KIT/scripts/graphify/worker-graph.sh query|explain|path \"<q>\""
if [ "$rc" = 2 ] && [ "$(cat "$T/err")" = "$want" ]; then pass "F2 with no graph anywhere the no-graph message and exit 2 are unchanged"
else fail "F2 rc=$rc err='$(cat "$T/err")'"; fi

mkdir -p "$T/amb"
printf '{"nodes":[{"id":"s_gate","label":"gate.sh","source_file":"s/gate.sh","metadata":{"kind":"file"}},{"id":"s_gate_sh__entry","label":"gate.sh script","source_file":"s/gate.sh","metadata":{"kind":"bash_entrypoint"}},{"id":"a_tool","label":"tool","source_file":"a/tool.sh","metadata":{"kind":"file"}},{"id":"b_tool","label":"tool","source_file":"b/tool.sh","metadata":{"kind":"file"}}],"built_at_commit": "%s"}\n' "$BASE" > "$T/amb/graph.json"
cat > "$T/bin/graphify" <<'STUB'
#!/bin/sh
[ "$1" = --help ] && { echo "  --rationale"; exit 0; }
case "$2" in
  gate) printf "Ambiguous: 'gate' matches 2 nodes in s/gate.sh.\n  L1\n    id: s_gate\n  L1\n    id: s_gate_sh__entry\nRetry with the full node id.\n"; exit 3 ;;
  tool) printf "Ambiguous: 'tool' matches 2 nodes in different files.\n  a/tool.sh\n    id: a_tool\n  b/tool.sh\n    id: b_tool\nRetry with path::symbol using one of the paths above.\n"; exit 3 ;;
esac
echo "STUB ARGS=$*"
STUB
chmod +x "$T/bin/graphify"
arun() { (cd "$T/wt" && HOME="$T/home" HIMMEL_CONFIG_DIR="$T/home/.himmel" XDG_DATA_HOME="$T/xdg" WORKER_GRAPH_OUT="$T/amb" PATH="$T/bin:$PATH" bash "$SCRIPT" "$@" 2>"$T/err"); }
out="$(arun explain gate)"; rc=$?
if [ "$rc" = 0 ] && [ "$out" = "STUB ARGS=explain s_gate --rationale --budget 8000" ] && grep -q 'explaining its file node s_gate$' "$T/err"; then
  pass "A1 a one-file ambiguity explains the file node"
else fail "A1 rc=$rc out='$out' err='$(cat "$T/err")'"; fi

out="$(arun explain tool)"; rc=$?
if [ "$rc" = 3 ] && [ "$(printf '%s\n' "$out" | head -1)" = "Ambiguous: 'tool' matches 2 nodes in different files." ] && ! grep -q 'file node' "$T/err"; then
  pass "A2 a multi-file ambiguity is untouched"
else fail "A2 rc=$rc out='$out' err='$(cat "$T/err")'"; fi

if [ "$FAILS" -ne 0 ]; then echo "$FAILS FAILURES"; exit 1; fi
echo "ALL PASS"
