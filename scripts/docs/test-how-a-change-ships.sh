#!/usr/bin/env bash
# Suite for docs/guide/how-a-change-ships.html, the delivery graph page, and
# its data file docs/guide/how-a-change-ships/graph.json.
#
# The data file names, for every node of the graph, its reach, its loop and the
# chains of checks that decide each move, each check citing the file and the
# exact string (refusal, exit row, outcome) it stands for. The page is the same
# content as static HTML. Cases:
#
#   1. DATA    — the data file parses; every node, chain row and edge has its
#                fields; ids are unique; every edge joins known nodes.
#   2. SOURCES — every cited file exists in the tree and still holds its cited
#                string. A moved line is only noted: the string is the claim.
#   3. REACH   — "in your project" sources are in scripts/adopt.sh
#                PORTABLE_FILES, "from your himmel clone" sources are not, and
#                "on by default" sources are plugin files.
#   4. PAGE    — with JS off (no scripts, nothing hidden), every node is a
#                <details> holding its label, reach, loop and every chain text,
#                and every edge and node is drawn in the graph.
#   5. SELECT  — every cited file's basename is named below, so
#                scripts/cr/impacted-suites.sh runs this suite when it changes.
#   6. CONTROL — on a temp copy: a renamed source file and a reworded refusal
#                string fail case 2, a source moved into PORTABLE_FILES fails
#                case 3, and a page missing one chain row fails case 4, so no
#                case passes vacuously.
#
# Cited files (basenames, for impacted-suites.sh):
#   adopt.sh usage-preflight.sh headed-arm-worker.sh _new-worktree.sh
#   check-worktree-isolation.sh check-commit-msg.sh block-edit-on-main.sh
#   block-read-secrets.sh block-destructive-commands.sh auto-approve-safe-bash.sh
#   check-push-target.sh check-no-force-push.sh check-cr-before-push.sh
#   check-platforms-tested.sh check-security-reviewed.sh
#   check-ci.sh pr-check.md review-round.sh clear-review-marker.sh
#   check-cr-marker-on-pr-create.sh review-merge-gate.sh ci-green-gate.sh
#   go-gate.sh ready-check.sh go.sh merge-on-green.sh chief.sh relay-batch.sh
#
# Platform guard (posix-bash): POSIX bash 3.2+, python3.
# Usage: bash scripts/docs/test-how-a-change-ships.sh [repo-root]
# Exit:  0 = every case passed, 1 = at least one failed (all are reported).
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "${1:-$HERE/../..}" && pwd)"
SELF="$HERE/test-how-a-change-ships.sh"
DATA_REL="docs/guide/how-a-change-ships/graph.json"
PAGE_REL="docs/guide/how-a-change-ships.html"

pass=0
fail=0
ok() { pass=$((pass + 1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf 'FAIL %s\n' "$1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/       /'; }

command -v python3 >/dev/null 2>&1 || { echo "FAIL: python3 required" >&2; exit 1; }

TMP=$(mktemp -d "${TMPDIR:-/tmp}/how-a-change-ships.XXXXXX") || exit 1
trap 'rm -rf "$TMP"' EXIT

# check <case> <root> [page]: prints one problem per line, nothing when clean.
# Lines starting "note:" are not problems.
check() {
  python3 -I - "$1" "$2" "$DATA_REL" "${3:-$2/$PAGE_REL}" "$SELF" <<'PY' || echo "checker crashed"
import html, json, os, re, sys
from html.parser import HTMLParser

case, root, data_rel, page, self_path = sys.argv[1:6]
real_root = os.path.realpath(root)
out = []

def norm(s):
    return re.sub(r"\s+", " ", s.replace("`", "")).strip()

try:
    data = json.load(open(os.path.join(root, data_rel), encoding="utf-8"))
except Exception as e:
    print("data file unreadable: %s (%s)" % (data_rel, e.__class__.__name__))
    sys.exit(0)

nodes = data.get("nodes") or []
inputs = data.get("inputs") or []
edges = data.get("edges") or []

def rows():
    for n in nodes:
        for c in n.get("chains") or []:
            for r in c.get("rows") or []:
                yield n, c, r

if case == "data":
    if not nodes or not edges or not inputs:
        out.append("data file has no nodes, inputs or edges")
    ids = [x.get("id") for x in nodes + inputs]
    for i in set(ids):
        if ids.count(i) > 1:
            out.append("duplicate id: %s" % i)
    for n in nodes:
        for f in ("id", "label", "what", "reach", "loop", "chains"):
            if not n.get(f):
                out.append("node %s: no %s" % (n.get("id"), f))
        reach = n.get("reach") or {}
        if reach.get("kind") not in ("project", "clone", "plugin", "human") or not reach.get("text"):
            out.append("node %s: reach needs a kind and a text" % n.get("id"))
        for c in n.get("chains") or []:
            if not c.get("title") or not c.get("rows"):
                out.append("node %s: a chain without a title or rows" % n.get("id"))
            keys = [r.get("k") for r in c.get("rows") or []]
            for t in c.get("try") or []:
                if t.get("hit") not in keys:
                    out.append("node %s chain %s: what-if %s hits no row" % (n.get("id"), c.get("title"), t.get("hit")))
    for n, c, r in rows():
        where = "node %s row %s" % (n["id"], r.get("k"))
        for f in ("k", "q", "next"):
            if not r.get(f):
                out.append("%s: no %s" % (where, f))
        o = r.get("outcome") or {}
        if o.get("kind") not in ("allow", "ask", "refuse") or not o.get("text"):
            out.append("%s: outcome needs a kind and a text" % where)
        if not r.get("end") and not r.get("source"):
            out.append("%s: a check row with no source" % where)
    known = set(ids)
    for e in edges:
        if e.get("from") not in known or e.get("to") not in known or not e.get("id") or not e.get("d"):
            out.append("edge %s: needs an id, a path and known ends (%s to %s)" % (e.get("id"), e.get("from"), e.get("to")))

def sources():
    for n, c, r in rows():
        if r.get("source"):
            yield n, r, r["source"]

if case == "sources":
    for n, r, s in sources():
        path, text = s.get("file", ""), s.get("text", "")
        full = os.path.realpath(os.path.join(root, path))
        where = "node %s row %s" % (n["id"], r["k"])
        if not path or not text or os.path.isabs(path) or not full.startswith(real_root + os.sep):
            out.append("%s: source needs a file inside the tree and a text" % where)
            continue
        if not os.path.isfile(full):
            out.append("%s: cited file missing: %s" % (where, path))
            continue
        lines = open(full, encoding="utf-8", errors="replace").read().split("\n")
        hits = [i + 1 for i, l in enumerate(lines) if text in l]
        if not hits:
            out.append("%s: cited string gone from %s: %s" % (where, path, text))
        elif s.get("line") not in hits:
            out.append("note: %s: %s:%s moved to line %d" % (where, path, s.get("line"), hits[0]))

if case == "reach":
    adopt = open(os.path.join(root, "scripts/adopt.sh"), encoding="utf-8").read()
    m = re.search(r"^PORTABLE_FILES=\((.*?)^\)", adopt, flags=re.S | re.M)
    portable = set()
    if not m:
        out.append("scripts/adopt.sh has no PORTABLE_FILES array")
    else:
        for line in m.group(1).splitlines():
            line = line.strip()
            if line and not line.startswith("#"):
                portable.add(line)
    for n, r, s in sources():
        reach = r.get("reach") or n.get("reach") or {}
        kind, path = reach.get("kind"), s.get("file", "")
        where = "node %s row %s (%s)" % (n["id"], r["k"], path)
        if kind == "project" and path not in portable:
            out.append("%s: says '%s' but a starter install does not copy it" % (where, reach.get("text")))
        elif kind == "clone" and path in portable:
            out.append("%s: says '%s' but a starter install copies it" % (where, reach.get("text")))
        elif kind == "plugin" and not path.startswith("marketplace/plugins/"):
            out.append("%s: says '%s' but is not a plugin file" % (where, reach.get("text")))
        elif kind == "human":
            out.append("%s: a cited check under a human node needs its own reach" % where)

if case == "select":
    named = open(self_path, encoding="utf-8").read()
    for b in sorted({os.path.basename(s["file"]) for _, _, s in sources()} | {"adopt.sh"}):
        if not re.search(r"(^|[\s/])%s(\s|$)" % re.escape(b), named, flags=re.M):
            out.append("cited file not named in the suite header: %s" % b)

VOID = {"area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "source", "track", "wbr"}
# Phrasing tags join their text to the words around them; every other tag is a word break.
INLINE = {"a", "abbr", "b", "code", "em", "i", "kbd", "small", "strong", "sub", "sup"}

class Page(HTMLParser):
    """Visible text with JS off: no script/style, nothing under [hidden]."""
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.stack, self.text, self.by_id, self.attrs_seen = [], [], {}, []
    def handle_starttag(self, tag, attrs):
        a = dict(attrs)
        self.attrs_seen.append((tag, a))
        if tag not in INLINE:
            self.handle_data(" ")
        if tag in VOID:
            return
        quiet = tag in ("script", "style", "template") or "hidden" in a
        self.stack.append((tag, a.get("id"), quiet))
        if a.get("id"):
            self.by_id.setdefault(a["id"], [tag, []])
    def handle_startendtag(self, tag, attrs):
        self.attrs_seen.append((tag, dict(attrs)))
    def handle_endtag(self, tag):
        if tag not in INLINE:
            self.handle_data(" ")
        for i in range(len(self.stack) - 1, -1, -1):
            if self.stack[i][0] == tag:
                del self.stack[i:]
                return
    def handle_data(self, d):
        if any(q for _, _, q in self.stack):
            return
        self.text.append(d)
        for _, i, _ in self.stack:
            if i:
                self.by_id[i][1].append(d)

if case == "page":
    if not os.path.isfile(page):
        print("page missing: %s" % page)
        sys.exit(0)
    p = Page()
    p.feed(open(page, encoding="utf-8").read())
    visible = norm("".join(p.text))
    for i in inputs:
        if norm(i["label"]) not in visible:
            out.append("input not on the page: %s" % i["label"])
    drawn_nodes = {a.get("data-node") for t, a in p.attrs_seen if t == "a"}
    drawn_ids = {a.get("id") for _, a in p.attrs_seen}
    for n in nodes:
        nid = "gn-" + n["id"]
        if nid not in drawn_nodes:
            out.append("node %s: not drawn in the graph (no data-node=%s)" % (n["id"], nid))
        tag, parts = p.by_id.get(nid, [None, []])
        if tag != "details":
            out.append("node %s: no <details id=%s>" % (n["id"], nid))
            continue
        body = norm("".join(parts))
        want = [n["label"], n["reach"]["text"], n["what"]] + list(n["loop"])
        for c in n["chains"]:
            want.append(c["title"])
            for r in c["rows"]:
                want += [r["q"], r.get("by") or ""]
                if r.get("reach"):
                    want.append(r["reach"]["text"])
                want += [r["outcome"]["text"], r["next"]]
        pos = 0
        for w in want:
            if not w:
                continue
            at = body.find(norm(w), pos)
            if at < 0:
                out.append("node %s: text not on the page with JS off, or out of order: %s" % (n["id"], norm(w)[:90]))
                continue
            pos = at + len(norm(w))
    for e in edges:
        if e["id"] not in drawn_ids:
            out.append("edge %s: not drawn in the graph" % e["id"])

for line in out:
    print(line)
PY
}

problems() { grep -v '^note:' <<< "$1"; }

run_case() {
  local name=$1 case=$2 r out
  out=$(check "$case" "$ROOT")
  r=$(problems "$out")
  if [ -z "$r" ]; then ok "$name"; else bad "$name" "$r"; fi
  grep '^note:' <<< "$out" | sed 's/^/       /'
}

run_case "1. DATA: nodes, chain rows and edges are complete" data
run_case "2. SOURCES: every cited file and string exists at HEAD" sources
run_case "3. REACH: every reach tag matches the starter install" reach
run_case "4. PAGE: every node, loop and chain text is on the page with JS off" page
run_case "5. SELECT: every cited file is named in this suite" select

# --- 6. CONTROL: a temp copy holding the data file, the page, adopt.sh and
# every cited file; each mutation must make its case fail.
C="$TMP/copy"
mkdir -p "$C"
cited=$(python3 -I -c 'import json,sys; d=json.load(open(sys.argv[1])); print("\n".join(sorted({r["source"]["file"] for n in d["nodes"] for c in n["chains"] for r in c["rows"] if r.get("source")})))' "$ROOT/$DATA_REL" 2>/dev/null)
copy_ok=1
for f in $DATA_REL $PAGE_REL scripts/adopt.sh $cited; do
  mkdir -p "$C/$(dirname "$f")" && cp "$ROOT/$f" "$C/$f" 2>/dev/null || copy_ok=0
done
if [ "$copy_ok" -ne 1 ] || [ -z "$cited" ]; then
  bad "6. CONTROL: temp copy" "could not copy the data file, page or cited files into $C"
else
  first=$(head -n 1 <<< "$cited")
  base=$(problems "$(check sources "$C")")
  if [ -n "$base" ]; then
    bad "6a. CONTROL: the unchanged copy passes case 2" "$base"
  else
    mv "$C/$first" "$C/$first.renamed"
    r=$(problems "$(check sources "$C")")
    mv "$C/$first.renamed" "$C/$first"
    if grep -qF "cited file missing: $first" <<< "$r"; then ok "6a. CONTROL: a renamed source file fails case 2"; else bad "6a. CONTROL: a renamed source file fails case 2" "got: ${r:-nothing}"; fi
  fi

  read -r node row file text <<EOF2
$(python3 -I -c 'import json,sys; d=json.load(open(sys.argv[1]))
for n in d["nodes"]:
  for c in n["chains"]:
    for r in c["rows"]:
      s=r.get("source")
      if s and r["outcome"]["kind"]=="refuse":
        print(n["id"], r["k"], s["file"], s["text"]); sys.exit(0)' "$ROOT/$DATA_REL")
EOF2
  cp "$C/$file" "$TMP/saved"
  python3 -I -c 'import sys; p,t=sys.argv[1],sys.argv[2]; s=open(p,encoding="utf-8").read(); open(p,"w",encoding="utf-8").write(s.replace(t,"reworded"))' "$C/$file" "$text"
  r=$(problems "$(check sources "$C")")
  cp "$TMP/saved" "$C/$file"
  if grep -qF "node $node row $row: cited string gone from $file" <<< "$r"; then ok "6b. CONTROL: a reworded refusal string fails case 2"; else bad "6b. CONTROL: a reworded refusal string fails case 2" "got: ${r:-nothing}"; fi

  clone_src=$(python3 -I -c 'import json,sys; d=json.load(open(sys.argv[1]))
for n in d["nodes"]:
  for c in n["chains"]:
    for r in c["rows"]:
      s=r.get("source"); k=(r.get("reach") or n["reach"])["kind"]
      if s and k=="clone": print(s["file"]); sys.exit(0)' "$ROOT/$DATA_REL")
  cp "$C/scripts/adopt.sh" "$TMP/saved"
  python3 -I -c 'import sys; p,f=sys.argv[1],sys.argv[2]; s=open(p,encoding="utf-8").read(); open(p,"w",encoding="utf-8").write(s.replace("PORTABLE_FILES=(\n","PORTABLE_FILES=(\n  "+f+"\n",1))' "$C/scripts/adopt.sh" "$clone_src"
  r=$(problems "$(check reach "$C")")
  cp "$TMP/saved" "$C/scripts/adopt.sh"
  if grep -qF "($clone_src): says" <<< "$r"; then ok "6c. CONTROL: a himmel-clone source in PORTABLE_FILES fails case 3"; else bad "6c. CONTROL: a himmel-clone source in PORTABLE_FILES fails case 3" "got: ${r:-nothing}"; fi

  # A row whose text is plain words reads the same in the HTML source.
  next=$(python3 -I -c 'import json,re,sys; d=json.load(open(sys.argv[1]))
print(next(r["next"] for n in d["nodes"] for c in n["chains"] for r in c["rows"] if re.fullmatch(r"[A-Za-z ,.]+", r["next"])))' "$ROOT/$DATA_REL")
  python3 -I -c 'import sys; p,t=sys.argv[1],sys.argv[2]; s=open(p,encoding="utf-8").read(); open(p,"w",encoding="utf-8").write(s.replace(t,"",1))' "$C/$PAGE_REL" "$next"
  r=$(problems "$(check page "$C")")
  if grep -qF "text not on the page with JS off" <<< "$r"; then ok "6d. CONTROL: a page missing one chain row fails case 4"; else bad "6d. CONTROL: a page missing one chain row fails case 4" "got: ${r:-nothing}"; fi
fi

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
