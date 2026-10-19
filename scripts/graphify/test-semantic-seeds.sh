#!/usr/bin/env bash
# test-semantic-seeds.sh -- a plain-language query that names no file starts graphify from the
# files whose content matches its meaning. graphify seeds on the question's words against node
# labels, so "how do a console and a leg relate" started from one-word labels and the file that
# answers it (the glossary) was missing. leg-graph.sh adds semantic-seeds.py's files as --seed
# after any anchor seeds. Stub graphify; every row runs everywhere.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/leg-graph.sh"
SEM="$HERE/semantic-seeds.py"
FAILS=0
pass() { echo "  ok: $1"; }
fail() { echo "  FAIL: $1"; FAILS=$((FAILS+1)); }

T="$(mktemp -d "${TMPDIR:-/tmp}/semantic-seeds.XXXXXX")" || exit 1
trap 'rm -rf "$T"' EXIT
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
P="$T/primary"
git init -q -b main "$P"
git -C "$P" commit -q --allow-empty -m base
mkdir -p "$P/graphify-out" "$T/bin"
G="$P/graphify-out/graph.json"
python3 -I - "$G" <<'PY'
import json, sys
def node(i, label, src, ft="code", **kw):
    n = {"id": i, "label": label, "norm_label": label.lower(), "file_type": ft, "source_file": src, "source_location": "L1"}
    n.update(kw)
    return n
nodes = [
    node("glossary", "glossary.md", "docs/glossary.md", "document"),
    node("gl_console", "Console", "docs/glossary.md", "concept", rationale="A console dispatches legs and never does the ticket work itself."),
    node("gl_leg", "Leg", "docs/glossary.md", "concept", rationale="One ticket, one worktree, one PR."),
    node("runc", "running-a-console.md", "docs/handover/running-a-console.md", "document"),
    node("tok", "Token", "scripts/auth/token.ts"),
    node("need", "Need", "scripts/auth/need.ts"),
    node("pc", "prompt-cache.md", "docs/internals/prompt-cache.md", "document"),
    node("pc_test", "prompt-cache.test.js", "scripts/tests/prompt-cache.test.js"),
    node("go_sh", "go.sh", "scripts/handover/console-kit/go.sh"),
]
json.dump({"directed": False, "multigraph": False, "graph": {}, "nodes": nodes, "links": []}, open(sys.argv[1], "w"))
PY
seeds() { python3 -I "$SEM" seeds "$G" "$1" | tr '\n' ' '; }

# S1: a plain-language question resolves to the file about it, not to one-word code labels.
got="$(seeds "how do a console and a leg relate")"
case "$got" in glossary\ *) pass "S1 console and leg question leads with the glossary" ;; *) fail "S1 got='$got'" ;; esac

# S2: a path-word match beats a test copy of it unless the question names tests.
got="$(seeds "why do cache reads cost less and how long does the prompt cache live")"
case "$got" in pc\ *) pass "S2 prompt cache question leads with the doc, not the test file" ;; *) fail "S2 got='$got'" ;; esac

# S3: a question sharing no word with the graph, and an unreadable graph, seed nothing.
got="$(seeds "what colour are the planets") $(python3 -I "$SEM" seeds "$T/missing.json" "how do a console and a leg relate" 2>/dev/null | tr '\n' ' ')"
if [ "$got" = " " ]; then pass "S3 no match or unreadable graph seeds nothing"
else fail "S3 got='$got'"; fi

# S3b: plural and singular forms tokenize alike ("consoles" matches the Console label).
got="$(seeds "how do consoles and legs relate")"
case "$got" in glossary\ *) pass "S3b plural question matches singular labels" ;; *) fail "S3b got='$got'" ;; esac

cat > "$T/bin/graphify" <<STUB
#!/bin/sh
echo "\$*" >> "$T/calls"
case "\$*" in
  *--seed*)
    echo "Graph: x (9 nodes) | Traversal: BFS depth=2 | Start (given): ['glossary.md'] | 1 nodes found"
    echo ""
    echo "NODE glossary.md [src=docs/glossary.md loc=L1 community=]" ;;
  *)
    echo "Graph: x (9 nodes) | Traversal: BFS depth=2 | Start: ['Need'] | 1 nodes found"
    echo ""
    echo "NODE Need [src=scripts/auth/need.ts loc=L1 community=]" ;;
esac
STUB
chmod +x "$T/bin/graphify"
run() { rm -f "$T/calls"; (cd "$P" && PATH="$T/bin:$PATH" bash "$SCRIPT" "$@" 2>"$T/err"); }

# S4: with no anchor, leg-graph.sh runs a given-seed query from the semantic file plus the keyword query.
out="$(run query "how do a console and a leg relate")"; rc=$?
calls="$(cat "$T/calls")"
if [ "$rc" = 0 ] && [ "$(wc -l < "$T/calls")" = 2 ] \
  && grep -qx -- "query how do a console and a leg relate --seed glossary --seed runc --seed go_sh --budget 4000" <<<"$calls" \
  && grep -qx -- "query how do a console and a leg relate --budget 4000" <<<"$calls"; then
  pass "S4 semantic seed passed to graphify query"
else fail "S4 rc=$rc calls='$calls'"; fi
if grep -m1 '^NODE ' <<<"$out" | grep -q '^NODE glossary.md ' && grep -q '^NODE Need ' <<<"$out"; then pass "S4b merged answer leads with the glossary, keeps the keyword node"
else fail "S4b out='$out'"; fi

# S5: an anchor stays first: go.sh precedes the semantic seeds.
run query "how does go.sh relate a console and a leg" >/dev/null
first="$(grep -m1 -o -- '--seed [a-z_]*' "$T/calls" | head -1)"
if [ "$first" = "--seed go_sh" ]; then pass "S5 anchor seed precedes semantic seeds"
else fail "S5 first='$first' calls='$(cat "$T/calls")'"; fi

# S6: a caller's own --seed is left alone.
run query "how do a console and a leg relate" --seed need >/dev/null
calls="$(cat "$T/calls")"
if [ "$calls" = "query how do a console and a leg relate --seed need --budget 8000" ]; then pass "S6 explicit --seed runs unchanged"
else fail "S6 calls='$calls'"; fi

# S7: a question matching nothing runs as before: one call.
run query "what colour are the planets" >/dev/null
calls="$(cat "$T/calls")"
if [ "$calls" = "query what colour are the planets --budget 8000" ]; then pass "S7 no match, one unchanged call"
else fail "S7 calls='$calls'"; fi

if [ "$FAILS" -ne 0 ]; then echo "$FAILS FAILURES"; exit 1; fi
echo "ALL PASS"
