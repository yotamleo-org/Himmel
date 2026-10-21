#!/usr/bin/env bash
# test-semantic-seeds.sh -- a plain-language query that names no file starts graphify from the
# files whose content matches its meaning. graphify seeds on the question's words against node
# labels, so "how does a console hand work to a leg" started from one-word labels and the file that
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
got="$(seeds "how does a console hand work to a leg")"
case "$got" in glossary\ *) pass "S1 console and leg question leads with the glossary" ;; *) fail "S1 got='$got'" ;; esac

# S2: a path-word match beats a test copy of it unless the question names tests.
got="$(seeds "how long does the prompt cache keep a prefix warm")"
case "$got" in pc\ *) pass "S2 prompt cache question leads with the doc, not the test file" ;; *) fail "S2 got='$got'" ;; esac

# S3: a question sharing no word with the graph, and an unreadable graph, seed nothing.
got="$(seeds "what colour are the planets") $(python3 -I "$SEM" seeds "$T/missing.json" "how does a console hand work to a leg" 2>/dev/null | tr '\n' ' ')"
if [ "$got" = " " ]; then pass "S3 no match or unreadable graph seeds nothing"
else fail "S3 got='$got'"; fi

# S3b: plural and singular forms tokenize alike ("consoles" matches the Console label).
got="$(seeds "how do consoles and legs relate")"
case "$got" in glossary\ *) pass "S3b plural question matches singular labels" ;; *) fail "S3b got='$got'" ;; esac

cat > "$T/bin/graphify" <<STUB
#!/bin/sh
[ "\$1" = --help ] && { echo "  --rationale"; exit 0; }
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
out="$(run query "how does a console hand work to a leg")"; rc=$?
calls="$(cat "$T/calls")"
if [ "$rc" = 0 ] && [ "$(wc -l < "$T/calls")" = 2 ] \
  && grep -qx -- "query how does a console hand work to a leg --rationale --seed glossary --seed runc --seed go_sh --budget 4000" <<<"$calls" \
  && grep -qx -- "query how does a console hand work to a leg --rationale --budget 4000" <<<"$calls"; then
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
run query "how does a console hand work to a leg" --seed need >/dev/null; rc=$?
calls="$(cat "$T/calls")"
if [ "$rc" = 0 ] && [ "$calls" = "query how does a console hand work to a leg --rationale --seed need --budget 8000" ]; then pass "S6 explicit --seed runs unchanged"
else fail "S6 calls='$calls'"; fi

# S7: a question matching nothing runs as before: one call.
run query "what colour are the planets" >/dev/null; rc=$?
calls="$(cat "$T/calls")"
if [ "$rc" = 0 ] && [ "$calls" = "query what colour are the planets --rationale --budget 8000" ]; then pass "S7 no match, one unchanged call"
else fail "S7 calls='$calls'"; fi

# W: a small corpus for the weak-seed and eval-corpus rows. effort.ts and check-best-effort.sh are the
# only files sharing a word with the weak question; the eval directory holds the best match for the strong one.
python3 -I - "$T/weak.json" <<'PY'
import json, sys
def node(i, label, src, ft="code", **kw):
    n = {"id": i, "label": label, "norm_label": label.lower(), "file_type": ft, "source_file": src, "source_location": "L1"}
    n.update(kw)
    return n
nodes = [
    node("ql_doc", "queue-lock.md", "docs/handover/queue-lock.md", "document"),
    node("ql_sh", "queue-lock.sh", "scripts/handover/queue-lock.sh"),
    node("ql_rule", "Queue lock", "docs/handover/queue-lock.md", "concept", rationale="One session holds the lock on a handover document at a time."),
    node("eff_ts", "effort.ts", "plugins/hud/src/effort.ts"),
    node("eff_sh", "check-best-effort.sh", "scripts/hooks/check-best-effort.sh"),
    node("ci_md", "check-ci.md", "commands/check-ci.md", "document", rationale="CI exit codes and the effort of waiting."),
    node("gl", "glossary.md", "docs/glossary.md", "document"),
    node("hk", "block-edit.sh", "scripts/hooks/block-edit.sh"),
    node("lib", "lib.sh", "scripts/lib/lib.sh"),
    node("ev", "queue-lock-handover-document.py", "scripts/eval/retrieval-eval/queue-lock-handover-document.py"),
]
json.dump({"nodes": nodes, "links": []}, open(sys.argv[1], "w"))
PY
STRONGQ="how does the queue lock hold a handover document"
WEAKQ="what does the effort setting change for a session"

# S8: files under the retrieval-eval directory never seed, even when they match best.
got="$(python3 -I "$SEM" seeds "$T/weak.json" "$STRONGQ" | tr '\n' ' ')"
case " $got" in
  *" ev "*) fail "S8 eval directory seeded: '$got'" ;;
  " ql_doc "*) pass "S8 the eval directory is not a seed candidate" ;;
  *) fail "S8 got='$got'" ;;
esac

# S9: no retrieval-eval question appears verbatim anywhere under scripts/graphify.
python3 -I - "$HERE/../eval/retrieval-eval/questions.jsonl" >"$T/questions.txt" <<'PY'
import json, sys
for line in open(sys.argv[1], encoding="utf-8"):
    if line.strip():
        print(json.loads(line)["q"])
PY
qrc=$?
hits=""
grepbad=""
[ "$qrc" = 0 ] || grepbad=" extractor rc=$qrc"
while IFS= read -r q; do
  h="$(git -C "$HERE" grep -i -l -F -e "$q" -- . 2>/dev/null)"; grc=$?
  case "$grc" in
    0) hits="$hits $h" ;;
    1) ;;
    *) grepbad="$grepbad rc=$grc" ;;
  esac
done <"$T/questions.txt"
if [ -s "$T/questions.txt" ] && [ -z "$hits" ] && [ -z "$grepbad" ]; then pass "S9 no eval question text under scripts/graphify"
else fail "S9 eval question text found in:$hits (git grep errors:$grepbad)"; fi

# S10: a weak seed (one shared word, a low score for this corpus) gets 2000 tokens, not 8000, and a header naming the seed.
out="$(run query "$WEAKQ" --graph "$T/weak.json")"; rc=$?
calls="$(cat "$T/calls")"
if [ "$rc" = 0 ] && grep -q '^leg-graph: LOW CONFIDENCE seed plugins/hud/src/effort.ts' <<<"$out" \
  && [ "$(grep -c -- '--budget 1000$' <<<"$calls")" = 2 ] && ! grep -q -- '--budget [48]000' <<<"$calls"; then
  pass "S10 weak seed: low-confidence header, 2000-token budget split in halves"
else fail "S10 rc=$rc calls='$calls' out='$out'"; fi

# S11: a strong seed is unchanged: full budget, no header.
out="$(run query "$STRONGQ" --graph "$T/weak.json")"; rc=$?
calls="$(cat "$T/calls")"
if [ "$rc" = 0 ] && ! grep -q 'LOW CONFIDENCE' <<<"$out" && [ "$(grep -c -- '--budget 4000$' <<<"$calls")" = 2 ]; then
  pass "S11 strong seed keeps the full budget and no header"
else fail "S11 rc=$rc calls='$calls' out='$out'"; fi

# S12: a caller's own --budget is honoured even for a weak seed.
out="$(run query "$WEAKQ" --graph "$T/weak.json" --budget 6000)"; rc=$?
calls="$(cat "$T/calls")"
if [ "$rc" = 0 ] && ! grep -q 'LOW CONFIDENCE' <<<"$out" && [ "$(grep -c -- '--budget 3000$' <<<"$calls")" = 2 ]; then
  pass "S12 explicit --budget on a weak seed is not scaled"
else fail "S12 rc=$rc calls='$calls' out='$out'"; fi

# S13: a named file anchors the query, so a weak semantic match does not shrink it.
out="$(run query "does lib.sh care about the effort setting for a session" --graph "$T/weak.json")"; rc=$?
calls="$(cat "$T/calls")"
if [ "$rc" = 0 ] && ! grep -q 'LOW CONFIDENCE' <<<"$out" && grep -q -- '--seed lib' <<<"$calls" && [ "$(grep -c -- '--budget 4000$' <<<"$calls")" = 2 ]; then
  pass "S13 an anchored query keeps the full budget"
else fail "S13 rc=$rc calls='$calls' out='$out'"; fi

# A: a fleet corpus written in the old vocabulary (leg, console) beside lane-worker files whose
# names already say worker in another sense; the registry marks those other-sense.
python3 -I - "$T/alias.json" <<'PY'
import json, sys
def node(i, label, src, ft="code", **kw):
    n = {"id": i, "label": label, "norm_label": label.lower(), "file_type": ft, "source_file": src, "source_location": "L1"}
    n.update(kw)
    return n
nodes = [
    node("arm_leg", "headed-arm-leg.sh", "scripts/handover/console-kit/headed-arm-leg.sh"),
    node("arm_fn", "start_leg_session()", "scripts/handover/console-kit/headed-arm-leg.sh", rationale="The console starts a leg in its own window."),
    node("preface", "leg-preface.md", "docs/handover/leg-preface.md", "document"),
    node("pf_rule", "Report to the console", "docs/handover/leg-preface.md", "concept", rationale="A leg reports a blocker to its console first."),
    node("stop_w", "stop-worker.sh", "scripts/lanes/stop-worker.sh"),
    node("stop_fn", "stop_lane_worker()", "scripts/lanes/stop-worker.sh", rationale="Stops a lane worker process."),
    node("rec_w", "reconcile-workers.sh", "scripts/handover/reconcile-workers.sh"),
    node("rec_fn", "reconcile_worker_rows()", "scripts/handover/reconcile-workers.sh"),
    node("await_w", "await-glm-worker.sh", "scripts/lanes/await-glm-worker.sh"),
    node("pc", "prompt-cache.md", "docs/internals/prompt-cache.md", "document"),
    node("hud_w", "git-worker.ts", "plugins/hud/src/git-worker.ts", rationale="A worker thread polls git status for the worker pool."),
]
json.dump({"nodes": nodes, "links": []}, open(sys.argv[1], "w"))
PY
aseeds() { python3 -I "$SEM" seeds "$T/alias.json" "$1" | tr '\n' ' '; }

# S14: a new-vocabulary question seeds the file written in the old one, not a lane-worker file.
got="$(aseeds "how does the chief start a worker")"
case "$got" in arm_leg\ *) pass "S14 chief/worker question leads with headed-arm-leg.sh" ;; *) fail "S14 got='$got'" ;; esac
got="$(aseeds "how does the chief arm a worker")"
case "$got" in arm_leg\ *) pass "S14b the arm phrasing leads with headed-arm-leg.sh" ;; *) fail "S14b got='$got'" ;; esac

# S15: the same for a doc: the leg preface answers how a worker reports to the chief.
got="$(aseeds "how does a worker report a blocker to the chief")"
case "$got" in preface\ *) pass "S15 worker/chief question leads with the leg preface" ;; *) fail "S15 got='$got'" ;; esac

# S16: a question about the lane worker itself still leads with it.
got="$(aseeds "how does stop-worker.sh stop a lane worker")"
case "$got" in stop_w\ *) pass "S16 a lane-worker question keeps stop-worker.sh first" ;; *) fail "S16 got='$got'" ;; esac

# S17: registry words alone never bring a file in: an old-term question asked in the new
# vocabulary seeds no file whose only match is "worker" in another sense.
got="$(aseeds "what is a wave of legs")"
case "$got" in *_w\ *) fail "S17 got='$got'" ;; *) pass "S17 swapped-in words alone seed no worker-sense file" ;; esac

if [ "$FAILS" -ne 0 ]; then echo "$FAILS FAILURES"; exit 1; fi
echo "ALL PASS"
