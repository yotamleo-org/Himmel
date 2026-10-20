#!/usr/bin/env bash
# test-anchor-seeds.sh -- a query that names a file or identifier starts graphify from that node.
# graphify seeds on the question's words, drops tokens of two letters or fewer (go.sh is "go" and
# "sh") and favours one-word labels, so the named file never seeded. leg-graph.sh resolves the
# names with anchor-seeds.py and merges a given-seed answer with graphify's own. Stub rows run
# everywhere; the real-graphify row is skipped when graphify is not installed.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/leg-graph.sh"
ANCHOR="$HERE/anchor-seeds.py"
FAILS=0
pass() { echo "  ok: $1"; }
fail() { echo "  FAIL: $1"; FAILS=$((FAILS+1)); }

T="$(mktemp -d "${TMPDIR:-/tmp}/anchor-seeds.XXXXXX")" || exit 1
trap 'rm -rf "$T"' EXIT
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
P="$T/primary"
git init -q -b main "$P"
git -C "$P" commit -q --allow-empty -m base
mkdir -p "$P/graphify-out" "$T/bin"
G="$P/graphify-out/graph.json"
python3 -I - "$G" <<'PY'
import json, sys
def node(i, label, src, loc="L1", ft="code"):
    return {"id": i, "label": label, "norm_label": label.lower(), "file_type": ft, "source_file": src, "source_location": loc}
nodes = [
    node("go_sh", "go.sh", "scripts/handover/console-kit/go.sh"),
    node("go_write", "write_go_file()", "scripts/handover/console-kit/go.sh", "L20"),
    node("write_file", "write_file()", "scripts/lib/files.sh", "L3"),
    node("write_ts", "Write", "scripts/tools.ts", "L9"),
    node("file_ts", "File", "scripts/tools.ts", "L12"),
    node("deferred", "file-deferred-issues.sh", "scripts/file-deferred-issues.sh"),
    node("lts_sh", "leg-tail-status.sh", "scripts/lib/leg-tail-status.sh"),
    node("lts_fn", "leg_tail_status()", "scripts/lib/leg-tail-status.sh", "L8"),
    node("ql_sh", "queue-lock.sh", "scripts/handover/queue-lock.sh"),
    node("ql_test", "queue-lock.sh", "scripts/handover/tests/queue-lock.sh"),
    node("tail_fn", "tail()", "scripts/lib/text.sh", "L2"),
    node("status_fn", "status()", "scripts/lib/text.sh", "L9"),
]
links = [
    {"source": "go_sh", "target": "go_write", "relation": "contains"},
    {"source": "write_file", "target": "write_ts", "relation": "calls"},
    {"source": "lts_sh", "target": "lts_fn", "relation": "contains"},
]
json.dump({"directed": False, "multigraph": False, "graph": {}, "nodes": nodes, "links": links}, open(sys.argv[1], "w"))
PY
seeds() { python3 -I "$ANCHOR" seeds "$G" "$1" | tr '\n' ' '; }

# A1: a file name with a two-letter stem resolves to its file node.
got="$(seeds "how does go.sh write a GO file")"
if [ "$got" = "go_sh " ]; then pass "A1 go.sh resolves to its file node"
else fail "A1 got='$got'"; fi

# A2: a snake_case identifier resolves to the symbol, not to tail() or status().
got="$(seeds "which file defines leg_tail_status")"
if [ "$got" = "lts_fn " ]; then pass "A2 leg_tail_status resolves to its function"
else fail "A2 got='$got'"; fi

# A3: a kebab stem resolves to the file; a test copy loses to the real file.
got="$(seeds "how does queue-lock release a stale lock")"
if [ "$got" = "ql_sh " ]; then pass "A3 queue-lock resolves to the non-test file"
else fail "A3 got='$got'"; fi

# A4: plain words, and a name that matches nothing, give no seeds.
got="$(seeds "how does a console hand work to a leg") $(seeds "what does foo-bar do")"
if [ "$got" = " " ]; then pass "A4 no name, or an unknown name, seeds nothing"
else fail "A4 got='$got'"; fi

# Stub graphify: logs each call's arguments and answers by mode, as the real printer does.
cat > "$T/bin/graphify" <<STUB
#!/bin/sh
[ "\$1" = --help ] && { echo "  --rationale"; exit 0; }
echo "\$*" >> "$T/calls"
case "\$*" in
  *--seed*)
    echo "Graph: x (12 nodes) | Traversal: BFS depth=2 | Start (given): ['go.sh'] | 2 nodes found"
    echo ""
    echo "NODE go.sh [src=scripts/handover/console-kit/go.sh loc=L1 community=]"
    echo "NODE write_go_file() [src=scripts/handover/console-kit/go.sh loc=L20 community=]"
    echo "EDGE go.sh --contains [EXTRACTED]--> write_go_file()" ;;
  *)
    echo "Graph: x (12 nodes) | Traversal: BFS depth=2 | Start: ['write_file()', 'Write'] | 3 nodes found"
    echo ""
    echo "[!] TRUNCATED: showing 2 of 3 nodes (~4000-token budget). The answer may be among the 1 cut nodes — raise the token budget to 5000 to get all 3 (CLI: --budget 5000, MCP: token_budget=5000) or narrow the query."
    echo ""
    echo "NODE write_file() [src=scripts/lib/files.sh loc=L3 community=]"
    echo "NODE go.sh [src=scripts/handover/console-kit/go.sh loc=L1 community=]"
    echo "EDGE write_file() --calls [EXTRACTED]--> Write"
    echo "... (truncated — 1 more nodes cut by ~4000-token budget. Narrow the query)" ;;
esac
STUB
chmod +x "$T/bin/graphify"
run() { rm -f "$T/calls"; (cd "$P" && PATH="$T/bin:$PATH" bash "$SCRIPT" "$@" 2>"$T/err"); }

# A5: a named file runs a given-seed query and a keyword query on half the budget each, and
# merges them: the named file first, no node twice, both start lists in the header.
out="$(run query "how does go.sh write a GO file")"; rc=$?
calls="$(cat "$T/calls")"
order="$(grep '^NODE ' <<<"$out" | sed 's/^NODE //; s/ \[src=.*//' | tr '\n' '|')"
if [ "$rc" = 0 ] && grep -qx -- "query how does go.sh write a GO file --rationale --seed go_sh --seed deferred --budget 4000" <<<"$calls" \
  && grep -qx -- "query how does go.sh write a GO file --rationale --budget 4000" <<<"$calls" && [ "$(wc -l < "$T/calls")" = 2 ]; then
  pass "A5 two graphify calls, half the budget each"
else fail "A5 rc=$rc calls='$calls'"; fi
if [ "$order" = "go.sh|write_go_file()|write_file()|" ] && grep -q "Start (given): \['go.sh'\] | Keyword start: \['write_file()', 'Write'\] | " <<<"$out" \
  && [ "$(grep -c '^EDGE ' <<<"$out")" = 2 ]; then pass "A5b merged answer: named file first, deduplicated, both starts named"
else fail "A5b order='$order' out='$out'"; fi
if grep -q 'TRUNCATED: showing' <<<"$out" && grep -q "leg-graph.sh query 'how does go.sh write a GO file' --budget 10000" "$T/err"; then
  pass "A5c a truncated half still gets a re-run line sized for both halves"
else fail "A5c out='$out' err=$(cat "$T/err")"; fi

# A6: a caller's own --seed is left alone: one call, no anchor seeds added.
run query "how does go.sh write a GO file" --seed write_file >/dev/null
calls="$(cat "$T/calls")"
if [ "$calls" = "query how does go.sh write a GO file --rationale --seed write_file --budget 8000" ]; then pass "A6 an explicit --seed runs unchanged"
else fail "A6 calls='$calls'"; fi

# A7: a question naming nothing, and matching nothing semantically, runs exactly as before: one call, the caller's arguments.
run query "how do planets orbit" >/dev/null
calls="$(cat "$T/calls")"
if [ "$calls" = "query how do planets orbit --rationale --budget 8000" ]; then pass "A7 no anchor, one unchanged call"
else fail "A7 calls='$calls'"; fi

# A9: a budget with a leading zero is decimal, not octal: both halves still run.
run query "how does go.sh write a GO file" --budget 0800 >/dev/null; rc=$?
calls="$(cat "$T/calls")"
if [ "$rc" = 0 ] && grep -qx -- "query how does go.sh write a GO file --rationale --seed go_sh --seed deferred --budget 400" <<<"$calls"; then
  pass "A9 --budget 0800 halves to 400"
else fail "A9 rc=$rc calls='$calls' err=$(cat "$T/err")"; fi

# A10: --graph names the graph the anchors resolve against, not the primary's.
python3 -I - "$T/other.json" <<'PY'
import json, sys
n = {"id": "other_go", "label": "go.sh", "norm_label": "go.sh", "file_type": "code",
     "source_file": "scripts/handover/console-kit/go.sh", "source_location": "L1"}
json.dump({"nodes": [n], "links": []}, open(sys.argv[1], "w"))
PY
run query "how does go.sh write a GO file" --graph "$T/other.json" >/dev/null
calls="$(cat "$T/calls")"
if grep -q -- "--seed other_go " <<<"$calls" && ! grep -q -- "--seed go_sh " <<<"$calls"; then
  pass "A10 anchors resolve in the --graph graph"
else fail "A10 calls='$calls'"; fi

# A8: the real graphify on the fixture: the bare query never reaches go.sh's file, the wrapper
# starts from it.
if command -v graphify >/dev/null 2>&1 && graphify --help 2>&1 | grep -q -- '--rationale'; then
  rm -f "$T/bin/graphify"
  bare="$(GRAPHIFY_OUT="$P/graphify-out" graphify query "how does go.sh write a GO file" --budget 8000 | grep -m1 '^NODE ')"
  first="$(run query "how does go.sh write a GO file" | grep -m1 '^NODE ')"
  if [ "${bare#*\[src=}" != "${first#*\[src=}" ] && grep -q '^NODE go.sh \[src=scripts/handover/console-kit/go.sh ' <<<"$first"; then
    pass "A8 real graphify: the named file leads the answer (bare graphify led with '${bare%% \[src=*}')"
  else fail "A8 bare='$bare' first='$first' err=$(cat "$T/err")"; fi
else
  echo "  skip: A8 real graphify row (graphify missing or without --rationale)"
fi

if [ "$FAILS" -ne 0 ]; then echo "$FAILS FAILURES"; exit 1; fi
echo "ALL PASS"
