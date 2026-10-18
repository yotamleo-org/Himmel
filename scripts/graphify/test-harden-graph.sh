#!/usr/bin/env bash
# test-harden-graph.sh — hermetic tests for harden-graph.py, the
# idempotent post-update step that bridges doc nodes naming a code file to
# that file's AST node and adds allowlisted subprocess-exec code-fact edges.
# Run: bash scripts/graphify/test-harden-graph.sh
# Platform guard (gitbash-only): pure bash + python3, no .ps1 twin needed.
# shellcheck disable=SC2015  # A && pass || fail is the intentional test-assert idiom (pass/fail echo, always rc 0)
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/harden-graph.py"
FAILS=0
pass() { echo "  ok: $1"; }
fail() { echo "  FAIL: $1"; FAILS=$((FAILS+1)); }

WS="$(mktemp -d "${TMPDIR:-/tmp}/harden-graph-test.XXXXXX")" || { echo "FAIL: mktemp -d failed"; exit 1; }
trap 'rm -rf "$WS"' EXIT

# Fixture: one ghost pair (doc label names an existing code file's basename,
# unique -> safe merge), one ambiguous pair (two AST files share a basename),
# one allowlisted subprocess-exec fact.
make_fixture() {
  local dir="$1"
  mkdir -p "$dir"
  cat > "$dir/graph.json" <<'JSON'
{
  "directed": false,
  "multigraph": false,
  "graph": {},
  "nodes": [
    {"id": "doc_x", "label": "foo.mjs router", "source_file": "docs/x.md", "file_type": "concept"},
    {"id": "scripts_foo", "label": "foo.mjs", "source_file": "scripts/foo.mjs", "file_type": "code", "source_location": "L1"},
    {"id": "doc_y", "label": "util.sh", "source_file": "docs/y.md", "file_type": "concept"},
    {"id": "a_util", "label": "util.sh", "source_file": "a/util.sh", "file_type": "code", "source_location": "L1"},
    {"id": "b_util", "label": "util.sh", "source_file": "b/util.sh", "file_type": "code", "source_location": "L1"},
    {"id": "scripts_fanout", "label": "fanout-plan.mjs", "source_file": "scripts/lanes/fanout-plan.mjs", "file_type": "code", "source_location": "L1"},
    {"id": "scripts_resolve", "label": "resolve.mjs", "source_file": "scripts/lanes/resolve.mjs", "file_type": "code", "source_location": "L1"}
  ],
  "links": [],
  "hyperedges": []
}
JSON
  cat > "$dir/allowlist.json" <<'JSON'
[
  {"source_file": "scripts/lanes/fanout-plan.mjs", "target_file": "scripts/lanes/resolve.mjs", "relation": "calls", "source_location": "L105", "note": "test fixture"}
]
JSON
}

# --- T1: first run adds exactly the expected bridge + calls edge, skips the
# ambiguous pair, and prints the right counts ---
echo "T1: first run adds bridge + code-fact, skips ambiguous"
D1="$WS/t1"; make_fixture "$D1"
out1=$( python3 "$SCRIPT" --out "$D1" --allowlist "$D1/allowlist.json" ); rc1=$?
[ "$rc1" -eq 0 ] || fail "T1 exit 0 (got $rc1): $out1"
echo "$out1" | grep -qF "bridges=1 code-facts=1 skipped-ambiguous=1 skipped-path-mismatch=0 unchanged=0" \
  && pass "T1 summary line has the right counts" \
  || fail "T1 summary line wrong: $out1"

if python3 - "$D1/graph.json" <<'PY'
import json, sys
g = json.load(open(sys.argv[1]))
links = g["links"]
assert len(links) == 2, f"expected 2 links, got {len(links)}: {links}"
bridge = next(e for e in links if e["hardened"] == "doc-label-names-code-file")
assert bridge["source"] == "doc_x" and bridge["target"] == "scripts_foo", bridge
assert bridge["relation"] == "references"
assert bridge["confidence"] == "EXTRACTED"
assert bridge["confidence_score"] == 1.0
assert bridge["source_file"] == "docs/x.md"
assert bridge["weight"] == 1.0
fact = next(e for e in links if e["hardened"] == "subprocess-exec")
assert fact["source"] == "scripts_fanout" and fact["target"] == "scripts_resolve", fact
assert fact["relation"] == "calls"
assert fact["source_location"] == "L105"
assert not any(e["source"] == "doc_y" for e in links), "ambiguous util.sh must not be bridged"
print("OK")
PY
then
  pass "T1 graph.json holds exactly the expected edges"
else
  fail "T1 graph.json content wrong"
fi

# --- T2: idempotent re-run -> unchanged=1, byte-identical graph.json ---
# cmp -s (not sha256sum) checks byte-identity directly: an absent/failing
# checksum tool would silently compare two empty strings and false-pass
#, whereas a missing cmp itself fails loudly.
echo "T2: re-run is idempotent and byte-identical"
cp "$D1/graph.json" "$D1/graph.json.before"
out2=$( python3 "$SCRIPT" --out "$D1" --allowlist "$D1/allowlist.json" ); rc2=$?
[ "$rc2" -eq 0 ] || fail "T2 exit 0 (got $rc2): $out2"
echo "$out2" | grep -qF "unchanged=1" && pass "T2 reports unchanged=1" || fail "T2 did not report unchanged=1: $out2"
cmp -s "$D1/graph.json.before" "$D1/graph.json" && pass "T2 graph.json byte-identical after re-run" || fail "T2 graph.json changed on re-run"

# --- T3: --dry-run writes nothing ---
echo "T3: --dry-run writes nothing"
D3="$WS/t3"; make_fixture "$D3"
cp "$D3/graph.json" "$D3/graph.json.before"
out3=$( python3 "$SCRIPT" --out "$D3" --allowlist "$D3/allowlist.json" --dry-run ); rc3=$?
[ "$rc3" -eq 0 ] || fail "T3 exit 0 (got $rc3): $out3"
echo "$out3" | grep -qF "bridges=1 code-facts=1 skipped-ambiguous=1 skipped-path-mismatch=0 unchanged=0" \
  && pass "T3 dry-run still reports the real counts" || fail "T3 dry-run counts wrong: $out3"
cmp -s "$D3/graph.json.before" "$D3/graph.json" && pass "T3 dry-run left graph.json untouched" || fail "T3 dry-run wrote to graph.json"

# --- T4: malformed JSON -> exit 1 ---
echo "T4: malformed graph.json -> exit 1"
D4="$WS/t4"; mkdir -p "$D4"
printf '{not json' > "$D4/graph.json"
out4=$( python3 "$SCRIPT" --out "$D4" 2>&1 ); rc4=$?
[ "$rc4" -eq 1 ] && pass "T4 malformed JSON exits 1" || fail "T4 expected exit 1, got $rc4: $out4"

# --- T5: missing graph.json -> exit 1 (unreadable input, not a crash) ---
echo "T5: missing graph.json -> exit 1"
D5="$WS/t5-missing"
out5=$( python3 "$SCRIPT" --out "$D5" 2>&1 ); rc5=$?
[ "$rc5" -eq 1 ] && pass "T5 missing graph.json exits 1" || fail "T5 expected exit 1, got $rc5: $out5"

# --- T6: cost.json note is appended only on a real (non-dry, non-unchanged) run ---
echo "T6: cost.json newest run note carries the harden summary"
D6="$WS/t6"; make_fixture "$D6"
cat > "$D6/cost.json" <<'JSON'
{"runs": [{"date": "2026-09-01T00:00:00Z", "input_tokens": 1, "output_tokens": 0, "files": 1, "note": "semantic pass"}], "total_input_tokens": 1, "total_output_tokens": 0}
JSON
python3 "$SCRIPT" --out "$D6" --allowlist "$D6/allowlist.json" >/dev/null
if python3 - "$D6/cost.json" <<'PY'
import json, sys
c = json.load(open(sys.argv[1]))
note = c["runs"][-1]["note"]
assert note.startswith("semantic pass; harden-graph:"), note
assert "bridges=1 code-facts=1 skipped-ambiguous=1 skipped-path-mismatch=0 unchanged=0" in note, note
print("OK")
PY
then
  pass "T6 cost.json note carries the harden summary"
else
  fail "T6 cost.json note wrong"
fi
before_mtime=$(stat -c %Y "$D6/cost.json" 2>/dev/null || stat -f %m "$D6/cost.json")
sleep 1
python3 "$SCRIPT" --out "$D6" --allowlist "$D6/allowlist.json" >/dev/null
after_mtime=$(stat -c %Y "$D6/cost.json" 2>/dev/null || stat -f %m "$D6/cost.json")
[ "$before_mtime" = "$after_mtime" ] && pass "T6 unchanged re-run leaves cost.json untouched" || fail "T6 unchanged re-run rewrote cost.json"

# --- T7: no cost.json -> never created ---
echo "T7: harden never creates cost.json"
D7="$WS/t7"; make_fixture "$D7"
python3 "$SCRIPT" --out "$D7" --allowlist "$D7/allowlist.json" >/dev/null
[ ! -f "$D7/cost.json" ] && pass "T7 cost.json still absent" || fail "T7 harden created cost.json"

# --- T8: allowlist source_file missing at its exact path must NOT fall back
# to a same-basename file elsewhere -- that would fabricate a false,
# confidence-1.0 "calls" edge ---
echo "T8: allowlist entry requires an exact source_file path match, no basename fallback"
D8="$WS/t8"; mkdir -p "$D8"
cat > "$D8/graph.json" <<'JSON'
{
  "directed": false,
  "multigraph": false,
  "graph": {},
  "nodes": [
    {"id": "unrelated_fanout", "label": "fanout-plan.mjs", "source_file": "other/place/fanout-plan.mjs", "file_type": "code", "source_location": "L1"},
    {"id": "scripts_resolve", "label": "resolve.mjs", "source_file": "scripts/lanes/resolve.mjs", "file_type": "code", "source_location": "L1"}
  ],
  "links": [],
  "hyperedges": []
}
JSON
cat > "$D8/allowlist.json" <<'JSON'
[
  {"source_file": "scripts/lanes/fanout-plan.mjs", "target_file": "scripts/lanes/resolve.mjs", "relation": "calls", "source_location": "L105", "note": "test fixture"}
]
JSON
out8=$( python3 "$SCRIPT" --out "$D8" --allowlist "$D8/allowlist.json" ); rc8=$?
[ "$rc8" -eq 0 ] || fail "T8 exit 0 (got $rc8): $out8"
echo "$out8" | grep -qF "code-facts=0" \
  && pass "T8 no code-fact edge when allowlisted source_file is absent at its exact path" \
  || fail "T8 fabricated a code-fact edge via basename fallback: $out8"

# --- T9: a pre-existing edge between the same two nodes in REVERSE order
# must count as a duplicate too -- graph.json is undirected/non-multigraph, so
# (u, v) and (v, u) are the same edge ---
echo "T9: reverse-order existing edge is recognized as the same undirected edge"
D9="$WS/t9"; mkdir -p "$D9"
cat > "$D9/graph.json" <<'JSON'
{
  "directed": false,
  "multigraph": false,
  "graph": {},
  "nodes": [
    {"id": "scripts_fanout", "label": "fanout-plan.mjs", "source_file": "scripts/lanes/fanout-plan.mjs", "file_type": "code", "source_location": "L1"},
    {"id": "scripts_resolve", "label": "resolve.mjs", "source_file": "scripts/lanes/resolve.mjs", "file_type": "code", "source_location": "L1"}
  ],
  "links": [
    {"source": "scripts_resolve", "target": "scripts_fanout", "relation": "references"}
  ],
  "hyperedges": []
}
JSON
cat > "$D9/allowlist.json" <<'JSON'
[
  {"source_file": "scripts/lanes/fanout-plan.mjs", "target_file": "scripts/lanes/resolve.mjs", "relation": "calls", "source_location": "L105", "note": "test fixture"}
]
JSON
out9=$( python3 "$SCRIPT" --out "$D9" --allowlist "$D9/allowlist.json" ); rc9=$?
[ "$rc9" -eq 0 ] || fail "T9 exit 0 (got $rc9): $out9"
echo "$out9" | grep -qF "code-facts=0 skipped-ambiguous=0 skipped-path-mismatch=0 unchanged=1" \
  && pass "T9 reverse-order existing edge suppresses the duplicate" \
  || fail "T9 added a duplicate reverse-direction edge: $out9"

# --- T10: an allowlisted dotfile-style path (leading "." that is not a "./"
# prefix) must match itself exactly, never get mangled by a character-class
# lstrip into an unrelated same-tail path ---
echo "T10: allowlist source_file starting with a bare dot matches exactly, no character-class stripping"
D10="$WS/t10"; mkdir -p "$D10"
cat > "$D10/graph.json" <<'JSON'
{
  "directed": false,
  "multigraph": false,
  "graph": {},
  "nodes": [
    {"id": "dotfile_tool", "label": "tool.sh", "source_file": ".config/tool.sh", "file_type": "code", "source_location": "L1"},
    {"id": "decoy_tool", "label": "tool.sh", "source_file": "config/tool.sh", "file_type": "code", "source_location": "L1"},
    {"id": "scripts_resolve", "label": "resolve.mjs", "source_file": "scripts/lanes/resolve.mjs", "file_type": "code", "source_location": "L1"}
  ],
  "links": [],
  "hyperedges": []
}
JSON
cat > "$D10/allowlist.json" <<'JSON'
[
  {"source_file": ".config/tool.sh", "target_file": "scripts/lanes/resolve.mjs", "relation": "calls", "source_location": "L1", "note": "test fixture"}
]
JSON
out10=$( python3 "$SCRIPT" --out "$D10" --allowlist "$D10/allowlist.json" ); rc10=$?
[ "$rc10" -eq 0 ] || fail "T10 exit 0 (got $rc10): $out10"
echo "$out10" | grep -qF "code-facts=1" \
  && pass "T10 dotfile-style source_file resolves" \
  || fail "T10 did not add the code-fact edge: $out10"
if python3 - "$D10/graph.json" <<'PY'
import json, sys
g = json.load(open(sys.argv[1]))
fact = next(e for e in g["links"] if e["hardened"] == "subprocess-exec")
assert fact["source"] == "dotfile_tool", f"expected dotfile_tool, got {fact['source']} (mangled by lstrip)"
print("OK")
PY
then
  pass "T10 code-fact edge points at the exact dotfile path, not the decoy"
else
  fail "T10 code-fact edge points at the wrong node (lstrip character-class bug)"
fi

# --- T11: an explicit --allowlist path that does not exist is a typo, not
# the normal "no allowlist yet" case -- it must exit 1, never silently
# suppress every code-fact edge while reporting success ---
echo "T11: explicit --allowlist pointing nowhere exits 1, not a silent no-op"
D11="$WS/t11"; make_fixture "$D11"
out11=$( python3 "$SCRIPT" --out "$D11" --allowlist "$D11/does-not-exist.json" 2>&1 ); rc11=$?
[ "$rc11" -eq 1 ] && pass "T11 missing explicit --allowlist exits 1" || fail "T11 expected exit 1, got $rc11: $out11"

# --- T12: a doc token with a directory component that CONTRADICTS the only
# same-basename AST file must NOT fall back to a bare-basename guess -- it is
# unresolved and counted in skipped-path-mismatch, never bridged (a resolver
# with a basename fallback would bridge it) ---
echo "T12: directory-qualified token with no matching path is unresolved, not basename-guessed"
D12="$WS/t12"; mkdir -p "$D12"
cat > "$D12/graph.json" <<'JSON'
{
  "directed": false,
  "multigraph": false,
  "graph": {},
  "nodes": [
    {"id": "doc_mismatch", "label": "nonexistent/foo.mjs file", "source_file": "docs/z.md", "file_type": "concept"},
    {"id": "scripts_foo", "label": "foo.mjs", "source_file": "scripts/foo.mjs", "file_type": "code", "source_location": "L1"}
  ],
  "links": [],
  "hyperedges": []
}
JSON
out12=$( python3 "$SCRIPT" --out "$D12" ); rc12=$?
[ "$rc12" -eq 0 ] || fail "T12 exit 0 (got $rc12): $out12"
echo "$out12" | grep -qF "bridges=0 code-facts=0 skipped-ambiguous=0 skipped-path-mismatch=1 unchanged=1" \
  && pass "T12 directory-qualified mismatch is skipped-path-mismatch, not bridged" \
  || fail "T12 summary wrong (RED: pre-fix resolver bridges via basename fallback): $out12"

# --- T13: a partial-but-correct token (directory component that matches a
# SUFFIX of the real path, not the whole thing) resolves by path suffix --
# this is the common real-corpus shape (docs writing "lanes/resolve.mjs" for
# "scripts/lanes/resolve.mjs") that a strict bare-token-only rule would drop
echo "T13: directory-qualified token resolves by unique path suffix"
D13="$WS/t13"; mkdir -p "$D13"
cat > "$D13/graph.json" <<'JSON'
{
  "directed": false,
  "multigraph": false,
  "graph": {},
  "nodes": [
    {"id": "doc_suffix", "label": "lanes/resolve.mjs module", "source_file": "docs/w.md", "file_type": "concept"},
    {"id": "scripts_resolve", "label": "resolve.mjs", "source_file": "scripts/lanes/resolve.mjs", "file_type": "code", "source_location": "L1"}
  ],
  "links": [],
  "hyperedges": []
}
JSON
out13=$( python3 "$SCRIPT" --out "$D13" ); rc13=$?
[ "$rc13" -eq 0 ] || fail "T13 exit 0 (got $rc13): $out13"
echo "$out13" | grep -qF "bridges=1 code-facts=0 skipped-ambiguous=0 skipped-path-mismatch=0 unchanged=0" \
  && pass "T13 partial-but-correct token bridges via path suffix" \
  || fail "T13 suffix match failed: $out13"
if python3 - "$D13/graph.json" <<'PY'
import json, sys
g = json.load(open(sys.argv[1]))
bridge = next(e for e in g["links"] if e["hardened"] == "doc-label-names-code-file")
assert bridge["source"] == "doc_suffix" and bridge["target"] == "scripts_resolve", bridge
print("OK")
PY
then
  pass "T13 bridge targets the suffix-matched node"
else
  fail "T13 bridge targeted the wrong node"
fi

# --- T14: a directory-qualified token matching a suffix of TWO different AST
# files is ambiguous, not resolved by guessing ---
echo "T14: directory-qualified token matching two path suffixes is ambiguous"
D14="$WS/t14"; mkdir -p "$D14"
cat > "$D14/graph.json" <<'JSON'
{
  "directed": false,
  "multigraph": false,
  "graph": {},
  "nodes": [
    {"id": "doc_ambig", "label": "lib/x.sh script", "source_file": "docs/v.md", "file_type": "concept"},
    {"id": "a_lib_x", "label": "x.sh", "source_file": "a/lib/x.sh", "file_type": "code", "source_location": "L1"},
    {"id": "b_lib_x", "label": "x.sh", "source_file": "b/lib/x.sh", "file_type": "code", "source_location": "L1"}
  ],
  "links": [],
  "hyperedges": []
}
JSON
out14=$( python3 "$SCRIPT" --out "$D14" ); rc14=$?
[ "$rc14" -eq 0 ] || fail "T14 exit 0 (got $rc14): $out14"
echo "$out14" | grep -qF "bridges=0 code-facts=0 skipped-ambiguous=1 skipped-path-mismatch=0 unchanged=1" \
  && pass "T14 two-way suffix match is skipped-ambiguous, not guessed" \
  || fail "T14 summary wrong: $out14"

# --- T15: --root resolves every shell call form into a calls/sources edge
# between the two file nodes; a path in a comment, an echo string or a heredoc
# body is not an edge; $1 and an unassigned variable are counted unresolved ---
echo "T15: shell call forms resolve to calls/sources edges, negatives do not"
D15="$WS/t15"; C15="$D15/corpus"; mkdir -p "$C15/a" "$C15/b" "$C15/scripts"
cat > "$C15/a/caller.sh" <<'SH'
#!/usr/bin/env bash
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SUT="$HERE/t_var.sh"
bash "$HERE/t_here.sh" --flag
sh "$ROOT/b/t_root.sh"
source "$SCRIPT_DIR/t_scriptdir.sh"
. "$(dirname "$0")/t_dirname.sh"
. "${BASH_SOURCE%/*}/t_bsource.sh"
exec bash scripts/t_literal.sh
out="$(HOME=/x bash "$HERE/t_subst.sh" 2>&1)"
"$HERE/t_direct.sh" arg
exec "$HERE/t_exec.sh"
timeout -k 5 60 bash "$SUT"
bash "$fx/scripts/t_tail.sh"
LIBX="$HERE/t_multi.sh"
source "$LIBX"
LIBX="$2"
out="$(printf x | env -u GUARD_OK "$@" bash "$HERE/t_env.sh")"
"$BASH" "$HERE/t_bashvar.sh"
for G in "$HERE/t_for1.sh" "$HERE/t_for2.sh"; do
  bash "$G"
done
bash \
  "$HERE/t_cont.sh"
echo "<<EOF"
echo ok # <<EOF2
bash '$HERE/n_squote.sh'
OUT=/tmp
bash "$OUT/scripts/t_ext.sh"
bash -o pipefail "$HERE/t_opt.sh"
# bash "$HERE/n_comment.sh"
echo "bash $HERE/n_echo.sh"
cat <<EOF
bash "$HERE/n_heredoc.sh"
EOF
bash "$1"
bash "$UNSET_DIR/x.sh"
SH
for f in a/t_here a/t_var b/t_root a/t_scriptdir a/t_dirname a/t_bsource scripts/t_literal a/t_subst a/t_direct a/t_exec scripts/t_tail a/t_multi a/t_env a/t_bashvar a/t_for1 a/t_for2 a/t_cont scripts/t_ext a/t_opt a/n_squote a/n_comment a/n_echo a/n_heredoc; do
  printf '#!/usr/bin/env bash\n' > "$C15/$f.sh"
done
python3 - "$D15" <<'PY'
import json, os, sys
d = sys.argv[1]
nodes = []
for root, _, files in os.walk(os.path.join(d, "corpus")):
    for f in files:
        rel = os.path.relpath(os.path.join(root, f), os.path.join(d, "corpus"))
        nid = rel.replace("/", "_").replace(".", "_")
        nodes.append({"id": nid, "label": rel, "source_file": rel, "file_type": "code",
                      "source_location": "L1", "metadata": {"language": "bash", "kind": "file"}})
json.dump({"directed": False, "multigraph": False, "graph": {}, "nodes": nodes, "links": [], "hyperedges": []},
          open(os.path.join(d, "graph.json"), "w"))
PY
out15=$( python3 "$SCRIPT" --out "$D15" --root "$C15" 2>&1 ); rc15=$?
[ "$rc15" -eq 0 ] || fail "T15 exit 0 (got $rc15): $out15"
echo "$out15" | grep -qF "shell-calls=15 shell-sources=4 shell-unresolved=3" \
  && pass "T15 summary counts shell calls, sources and unresolved" \
  || fail "T15 summary wrong: $out15"
if python3 - "$D15/graph.json" <<'PY'
import json, sys
g = json.load(open(sys.argv[1]))
got = {(e["source"], e["target"], e["relation"]) for e in g["links"] if e.get("hardened") == "shell-call"}
want = {("a_caller_sh", t, r) for t, r in [
    ("a_t_here_sh", "calls"), ("a_t_var_sh", "calls"), ("b_t_root_sh", "calls"),
    ("a_t_scriptdir_sh", "sources"), ("a_t_dirname_sh", "sources"), ("a_t_bsource_sh", "sources"),
    ("scripts_t_literal_sh", "calls"), ("a_t_subst_sh", "calls"), ("a_t_direct_sh", "calls"),
    ("a_t_exec_sh", "calls"), ("scripts_t_tail_sh", "calls"), ("a_t_multi_sh", "sources"),
    ("a_t_env_sh", "calls"), ("a_t_bashvar_sh", "calls"), ("a_t_for1_sh", "calls"), ("a_t_for2_sh", "calls"), ("a_t_cont_sh", "calls"), ("scripts_t_ext_sh", "calls"), ("a_t_opt_sh", "calls")]}
missing, extra = want - got, got - want
for m in sorted(missing):
    print(f"  missing case: {m[1]} ({m[2]})")
for x in sorted(extra):
    print(f"  false edge: {x[1]} ({x[2]})")
inferred = {e["target"] for e in g["links"] if e.get("hardened") == "shell-call" and e["confidence"] == "INFERRED"}
if inferred != {"scripts_t_tail_sh", "scripts_t_ext_sh"}:
    print(f"  INFERRED (sandbox-tail) edges: {sorted(inferred)}")
sys.exit(1 if missing or extra or inferred != {"scripts_t_tail_sh", "scripts_t_ext_sh"} else 0)
PY
then
  pass "T15 every call form is an edge and no comment/echo/heredoc/single-quoted path is"
else
  fail "T15 shell edges wrong"
fi
cp "$D15/graph.json" "$D15/graph.json.before"
python3 "$SCRIPT" --out "$D15" --root "$C15" >/dev/null
cmp -s "$D15/graph.json.before" "$D15/graph.json" && pass "T15 re-run adds no shell edge twice" || fail "T15 re-run changed graph.json"

# --- T16: a semantic node naming the same entity as a node in another file
# (code-file token, name() symbol, glossary term, /command) is merged into one
# canonical node, its edges redirected; same-name AST symbols, an ambiguous
# token, a code-file token with no AST file node and a prose label outside the
# glossary stay separate ---
echo "T16: same entity across files merges into one canonical node"
D16="$WS/t16"; mkdir -p "$D16"
C16="$WS/t16-root"; mkdir -p "$C16/a" "$C16/b"
: > "$C16/a/.pre-commit-config.yaml"; : > "$C16/b/.pre-commit-config.yaml"
cat > "$D16/graph.json" <<'JSON'
{
  "directed": false,
  "multigraph": false,
  "graph": {},
  "nodes": [
    {"id": "scripts_check", "label": "check.sh", "source_file": "scripts/check.sh", "file_type": "code", "source_location": "L1", "_origin": "ast"},
    {"id": "scripts_check_run", "label": "run()", "source_file": "scripts/check.sh", "file_type": "code", "source_location": "L4", "_origin": "ast"},
    {"id": "docs_a", "label": "a.md", "source_file": "docs/a.md", "file_type": "document", "source_location": "L1", "_origin": "ast"},
    {"id": "docs_a_check", "label": "check.sh", "source_file": "docs/a.md", "file_type": "code", "_origin": "semantic"},
    {"id": "docs_b_check", "label": "scripts/check.sh", "source_file": "docs/b.md", "file_type": "code", "_origin": "semantic"},
    {"id": "docs_b_gate", "label": "Gate", "source_file": "docs/b.md", "file_type": "concept", "_origin": "semantic"},
    {"id": "scripts_lib_do_thing", "label": "do_thing()", "source_file": "scripts/lib.sh", "file_type": "code", "source_location": "L9", "_origin": "ast"},
    {"id": "docs_e_do_thing", "label": "do_thing()", "source_file": "docs/e.md", "file_type": "code", "_origin": "semantic"},
    {"id": "docs_glossary_cr_ledger", "label": "CR ledger", "source_file": "docs/glossary.md", "file_type": "concept", "_origin": "semantic"},
    {"id": "skill_cr_ledger", "label": "CR ledger", "source_file": "skills/pr-check/SKILL.md", "file_type": "concept", "_origin": "semantic"},
    {"id": "docs_f_precommit", "label": ".pre-commit-config.yaml", "source_file": "docs/f.md", "file_type": "code", "_origin": "semantic"},
    {"id": "docs_g_precommit", "label": ".pre-commit-config.yaml", "source_file": "docs/g.md", "file_type": "code", "_origin": "semantic"},
    {"id": "docs_m_helper", "label": "helper()", "source_file": "docs/m.md", "file_type": "code", "_origin": "semantic"},
    {"id": "docs_n_helper", "label": "helper()", "source_file": "docs/n.md", "file_type": "code", "_origin": "semantic"},
    {"id": "t1_assert", "label": "assert_contains()", "source_file": "tests/t1.sh", "file_type": "code", "source_location": "L3", "_origin": "ast"},
    {"id": "t2_assert", "label": "assert_contains()", "source_file": "tests/t2.sh", "file_type": "code", "source_location": "L3", "_origin": "ast"},
    {"id": "docs_h_assert", "label": "assert_contains()", "source_file": "docs/h.md", "file_type": "code", "_origin": "semantic"},
    {"id": "docs_i_checklist", "label": "Verification checklist", "source_file": "docs/i.md", "file_type": "concept", "_origin": "semantic"},
    {"id": "docs_j_checklist", "label": "Verification checklist", "source_file": "docs/j.md", "file_type": "concept", "_origin": "semantic"},
    {"id": "docs_k_pr_check", "label": "/pr-check", "source_file": "docs/k.md", "file_type": "concept", "_origin": "semantic"},
    {"id": "docs_l_pr_check", "label": "/pr-check", "source_file": "docs/l.md", "file_type": "concept", "_origin": "semantic"},
    {"id": "agents_ladder", "label": "Precedence ladder", "source_file": "AGENTS.md", "file_type": "concept", "_origin": "semantic"},
    {"id": "soul_ladder", "label": "Precedence ladder", "source_file": "scripts/hermes/SOUL.md", "file_type": "concept", "_origin": "semantic"}
  ],
  "links": [
    {"source": "scripts_check", "target": "scripts_check_run", "relation": "contains", "_origin": "ast"},
    {"source": "docs_a", "target": "docs_a_check", "relation": "contains", "source_file": "docs/a.md", "_origin": "semantic"},
    {"source": "docs_b_gate", "target": "docs_b_check", "relation": "references", "source_file": "docs/b.md", "_origin": "semantic"},
    {"source": "docs_a_check", "target": "docs_b_check", "relation": "references", "source_file": "docs/a.md", "_origin": "semantic"},
    {"source": "docs_e_do_thing", "target": "docs_b_gate", "relation": "references", "source_file": "docs/e.md", "_origin": "semantic"},
    {"source": "skill_cr_ledger", "target": "docs_b_gate", "relation": "references", "source_file": "skills/pr-check/SKILL.md", "_origin": "semantic"},
    {"source": "docs_g_precommit", "target": "docs_b_gate", "relation": "references", "source_file": "docs/g.md", "_origin": "semantic"}
  ],
  "hyperedges": [
    {"id": "h1", "nodes": ["docs_a_check", "docs_b_check", "docs_b_gate"], "source_file": "docs/b.md", "_origin": "semantic"}
  ]
}
JSON
out16=$( python3 "$SCRIPT" --out "$D16" --root "$C16" ); rc16=$?
[ "$rc16" -eq 0 ] || fail "T16 exit 0 (got $rc16): $out16"
echo "$out16" | grep -qF "identity-merged=6 identity-ambiguous=3" \
  && pass "T16 summary counts merged and ambiguous identities" \
  || fail "T16 summary wrong: $out16"
if python3 - "$D16/graph.json" <<'PY'
import json, sys
g = json.load(open(sys.argv[1]))
ids = {n["id"] for n in g["nodes"]}
gone = {"docs_a_check", "docs_b_check", "docs_e_do_thing", "skill_cr_ledger", "docs_n_helper", "docs_l_pr_check"}
kept = {"scripts_check", "scripts_lib_do_thing", "docs_glossary_cr_ledger", "docs_f_precommit", "docs_g_precommit", "docs_m_helper",
        "t1_assert", "t2_assert", "docs_h_assert", "docs_i_checklist", "docs_j_checklist",
        "docs_k_pr_check", "agents_ladder", "soul_ladder"}
errs = [f"not merged: {i}" for i in gone & ids] + [f"wrongly removed: {i}" for i in kept - ids]
edges = {(e["source"], e["target"], e["relation"]) for e in g["links"]}
for want in [("docs_a", "scripts_check", "contains"), ("docs_b_gate", "scripts_check", "references"),
             ("scripts_lib_do_thing", "docs_b_gate", "references"),
             ("docs_glossary_cr_ledger", "docs_b_gate", "references"),
             ("docs_g_precommit", "docs_b_gate", "references")]:
    if want not in edges:
        errs.append(f"missing redirected edge {want}")
errs += [f"self-loop {e}" for e in edges if e[0] == e[1]]
errs += [f"dangling {e}" for e in edges if e[0] not in ids or e[1] not in ids]
canon = {n["id"]: n for n in g["nodes"]}["scripts_check"]
if canon.get("merged_ids") != ["docs_a_check", "docs_b_check"]:
    errs.append(f"merged_ids wrong: {canon.get('merged_ids')}")
if g["hyperedges"][0]["nodes"] != ["scripts_check", "docs_b_gate"]:
    errs.append(f"hyperedge members wrong: {g['hyperedges'][0]['nodes']}")
for e in errs:
    print("  " + e)
sys.exit(1 if errs else 0)
PY
then
  pass "T16 duplicates merged, edges redirected, distinct same-name entities kept apart"
else
  fail "T16 canonical identity merge wrong"
fi
cp "$D16/graph.json" "$D16/graph.json.before"
out16b=$( python3 "$SCRIPT" --out "$D16" --root "$C16" )
echo "$out16b" | grep -qF "unchanged=1" && cmp -s "$D16/graph.json.before" "$D16/graph.json" \
  && pass "T16 re-run merges nothing twice" || fail "T16 re-run changed graph.json: $out16b"
# An AST definition appearing later absorbs the earlier canonical node AND the
# ids that node had already absorbed.
python3 - "$D16/graph.json" <<'PY'
import json, sys
g = json.load(open(sys.argv[1]))
g["nodes"].append({"id": "scripts_helper", "label": "helper()", "source_file": "scripts/helper.sh",
                   "file_type": "code", "source_location": "L2", "_origin": "ast"})
json.dump(g, open(sys.argv[1], "w"))
PY
python3 "$SCRIPT" --out "$D16" --root "$C16" >/dev/null
got16c=$( python3 -c 'import json,sys; print({n["id"]: n for n in json.load(open(sys.argv[1]))["nodes"]}["scripts_helper"].get("merged_ids"))' "$D16/graph.json" )
[ "$got16c" = "['docs_m_helper', 'docs_n_helper']" ] \
  && pass "T16 a later canonical keeps the ids its alias had absorbed" || fail "T16 merged_ids lost on re-merge: $got16c"

if [ "$FAILS" -ne 0 ]; then echo "$FAILS FAILURES"; exit 1; fi
echo "ALL PASS"
