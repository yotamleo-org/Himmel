#!/usr/bin/env bash
# Drift guard for docs/guide/how-a-change-ships.html, the Workflow page, against
# the ship-loop code it describes.
#
# test-how-a-change-ships.sh checks the page against its data file and that each
# cited string still exists. This suite checks what the page CLAIMS about the
# code: the scripts, commands and switches it names exist, the order it shows is
# the order the code runs, and each behaviour it states is what the code says.
# Cases:
#
#   1. NAMES — every script (<code>x.sh</code>) and slash command (/name) the
#              page names is a file in the tree.
#   2. FLAGS — every environment switch the page names (<code>NAME=1</code> or
#              <code>NAME</code>) and every check-ci exit code it names appears
#              in the code: scripts/, marketplace/ or .claude/, tests excluded.
#   3. ORDER — in a chain the page shows as an order, rows citing the same file
#              follow that file's line order.
#   4. FACTS — each stated behaviour: the code still holds the lines that state
#              it, and the page says it (and not its known wrong wording). A
#              fact pins an executable line where one carries the behaviour,
#              else the script's own contract comment: this guards the page's
#              wording, it does not run the code.
#   5. CONTROL — on a temp copy, a script name the tree lacks fails case 1,
#              the ceiling check moved after the merged-PR check fails case 3,
#              and a changed chief hand-over threshold fails case 4.
#   6. SOURCES — in the workflow model (docs/guide/dev-graph/graph.json), each
#              step with no `sources` and each `m.` move carries either `source`
#              ({file, line, text}: that line of that file still holds the text)
#              or `noSource` (why no code stands behind it). The line is strict:
#              a shifted citation fails and names the line to write. Each cited
#              basename is named on a `# selector: names` line below, so a change
#              to the file selects this suite (impacted-suites.sh reads no other
#              comment line).
#   7. CONTROL — on a temp copy, a reworded cited line and a shifted cited line
#              fail case 6 for a step and for a move, and a step with neither
#              field fails it.
#
# Cited files (basenames, for impacted-suites.sh):
# selector: names _new-worktree.sh check-commit-msg.sh check-worktree-isolation.sh
# selector: names wire-pretooluse-hooks.sh review-merge-gate.sh headed-arm-worker.sh
# selector: names usage-preflight.sh check-ci.sh review-round.sh chief.sh merge-on-green.sh
# selector: names check-no-force-push.sh check-push-target.sh
# selector: names SKILL.md plan-charter.md ticket-standard-check.sh worker-pr-open.sh
# selector: names plugin-profiles.json next-dispatchable.sh effort-route.mjs chief-wait.sh
# selector: names block-unresolved-cr-merge.sh residual-lines.sh wrap-merged.sh
#
# Platform guard (posix-bash): POSIX bash 3.2+, python3, git.
# Usage: bash scripts/docs/test-workflow-page-drift.sh [repo-root]
# Exit:  0 = every case passed, 1 = at least one failed (all are reported).
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "${1:-$HERE/../..}" && pwd)"
DATA_REL="docs/guide/how-a-change-ships/graph.json"
PAGE_REL="docs/guide/how-a-change-ships.html"

pass=0
fail=0
ok() { pass=$((pass + 1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf 'FAIL %s\n' "$1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/       /'; }

command -v python3 >/dev/null 2>&1 || { echo "FAIL: python3 required" >&2; exit 1; }

TMP=$(mktemp -d "${TMPDIR:-/tmp}/workflow-page-drift.XXXXXX") || exit 1
trap 'rm -rf "$TMP"' EXIT

# check <case> <root> [page]: prints one problem per line, nothing when clean.
# FLAGS greps the real tree ($ROOT); every other case reads <root> only.
check() {
  python3 -I - "$1" "$2" "$DATA_REL" "${3:-$2/$PAGE_REL}" "$ROOT" <<'PY' || echo "checker crashed"
import html, json, os, re, subprocess, sys

case, root, data_rel, page_path, real_root = sys.argv[1:6]
out = []

def read(rel):
    p = os.path.join(root, rel)
    return open(p, encoding="utf-8", errors="replace").read() if os.path.isfile(p) else None

raw = open(page_path, encoding="utf-8").read()
main = raw[raw.find("<main"):raw.find("</main>")]
INLINE = r"</?(?:a|abbr|b|code|em|i|kbd|small|strong|sub|sup)\b[^>]*>"
text = re.sub(INLINE, "", main)
text = re.sub(r"<[^>]+>", " ", text)
text = re.sub(r"\s+", " ", html.unescape(text)).strip()
codes = [re.sub(r"\s+", " ", html.unescape(re.sub(r"<[^>]+>", "", c))).strip()
         for c in re.findall(r"<code>(.*?)</code>", main, flags=re.S)]

if case == "names":
    tree = set()
    for top in ("scripts", ".claude", "marketplace"):
        for d, _, files in os.walk(os.path.join(root, top)):
            tree.update(files)
    for c in sorted(set(codes)):
        if re.fullmatch(r"[\w.-]+\.(sh|js|mjs|ts|py)", c) and c not in tree:
            out.append("page names script %s, which is not in the tree" % c)
        m = re.fullmatch(r"/([a-z][\w-]*)", c)
        if m:
            n = m.group(1)
            plugins = os.path.join(root, "marketplace/plugins")
            homes = [".claude"] + ["marketplace/plugins/" + p for p in (os.listdir(plugins) if os.path.isdir(plugins) else [])]
            if not any(os.path.isfile(os.path.join(root, h, "commands", n + ".md"))
                       or os.path.isfile(os.path.join(root, h, "skills", n, "SKILL.md")) for h in homes):
                out.append("page names command /%s, which no command or skill file defines" % n)

if case == "flags":
    def in_code(token):
        r = subprocess.run(["git", "-C", real_root, "grep", "-qF", "-e", token, "--",
                            "scripts", "marketplace", ".claude",
                            ":(exclude,glob)**/test-*", ":(exclude,glob)**/tests/**"],
                           capture_output=True)
        return r.returncode == 0
    for c in sorted(set(codes)):
        m = re.fullmatch(r"([A-Z][A-Z0-9]*_[A-Z0-9_]+)(=\S*)?", c) or \
            re.fullmatch(r"([A-Z][A-Z0-9]*_[A-Z0-9_]+)=\S+ claude", c)
        if m and not in_code(m.group(1)):
            out.append("page names switch %s, which no script reads" % m.group(1))
    ci = read("scripts/check-ci.sh") or ""
    documented = set(re.findall(r"^#\s+(\d+) — ", ci, flags=re.M))
    for grp in re.findall(r"\(exit ([\d or,]+)\)", text):
        for n in re.findall(r"\d+", grp):
            if n not in documented:
                out.append("page names check-ci exit %s, which check-ci.sh does not document" % n)

if case == "order":
    data = json.loads(read(data_rel))
    # (node, chain title): the chains the page shows as a sequence.
    ORDERED = {("build", "Starting the worktree"), ("build", "Committing"), ("plan", "Starting a worker")}
    for n in data["nodes"]:
        for c in n["chains"]:
            if (n["id"], c["title"]) not in ORDERED:
                continue
            seen = {}
            for r in c["rows"]:
                s = r.get("source")
                if not s:
                    continue
                body = read(s["file"]) or ""
                lines = [i for i, l in enumerate(body.split("\n"), 1) if s["text"] in l]
                if not lines:
                    out.append("node %s row %s: cited string gone from %s" % (n["id"], r["k"], s["file"]))
                    continue
                prev = seen.get(s["file"])
                if prev and lines[0] < prev[1]:
                    out.append("node %s chain '%s': row %s comes after row %s on the page, but %s checks it first (line %d before %d)"
                               % (n["id"], c["title"], r["k"], prev[0], s["file"], lines[0], prev[1]))
                seen[s["file"]] = (r["k"], lines[0])

# Each fact: the code lines that make it true, what the page must say, and the
# wording it must not use. A missing code line means the code moved on: re-check
# the page row and update the fact with it.
FACTS = [
    ("hooks run side by side in an install", "scripts/lib/wire-pretooluse-hooks.sh",
     ["each as its own matcher stanza", "stanza: { matcher: $matcher"],
     ["Each hook that matches the tool sees the call; any one that says no stops it"],
     ["run in order", "the first one that says no", "Every hook sees the call", "Every hook checks the call"]),
    ("worktree: ceiling, then merged PR", "scripts/_new-worktree.sh",
     ["(feat|fix|chore|docs|refactor|test)/", "HIMMEL_WORKTREE_CEILING",
      "uniqueness-vs-merged-PR check skipped (forge unreachable)",
      'BASE_REF="origin/$DEFAULT_BRANCH"'],
     ["(feat, fix, chore, docs, refactor, test)", "Skipped with a warning when the forge cannot be reached",
      "from origin/<default branch>, or your local default branch when there is no remote"],
     []),
    ("launch refuses only an exhausted bank", "scripts/handover/chief-kit/headed-arm-worker.sh",
     ['if [ "$preflight_token" = SKIPPED-BANK ]',
      "Any other verdict (PROCEED, BANK-STALE, BANK-UNKNOWN) falls through.",
      "lane bank exhausted (park and retry later", "fleet-size cap reached",
      "claude-opus-*", "claude-fable-*"],
     ["the usage check says the budget is spent", "A stale or unknown bank reading does not stop the launch", "(opus, fable)"],
     ["does not say PROCEED", "The chief waits for your ruling", "SKIPPED-BANK"]),
    ("an unreadable reviewer holds only in an armed clone", "scripts/lib/review-merge-gate.sh",
     ["- failing open\" >&2; }", "armed clone an unreadable CR ledger holds every hard or required critic"],
     ["where an unreadable review ledger holds every required reviewer and a failed CodeRabbit read holds a required CodeRabbit review"],
     ["but a required reviewer it cannot read holds the merge", "does a required reviewer it cannot read hold the merge"]),
    ("three full review rounds, then one delta round", "scripts/cr/review-round.sh",
     ["After three full rounds the only round left is ONE delta round",
      "A 4th full round and a second delta are refused.",
      "The delta round blocks only on Critical or escape-class",
      "one more delta round per reviewed head", "every one is recorded fixed there",
      "A CI-red reviewed head (delta round spent or not) buys ONE bounded delta"],
     ["Three full rounds used already?", "critical findings or ones that show a flow broken today", "A fourth full round is refused",
      "A judge NO-GO, every finding of that round fixed, or a red CI run buys one more bounded diff-only round"],
     ["escape-class"]),
    ("chief hands over at 45 %", "scripts/handover/chief/chief.sh",
     ['fill_percent="${CHIEF_FILL_PERCENT:-45}"'],
     ["Is the chief's context 45 % full?"],
     []),
    ("a red main warns a green change and does not refuse it", "scripts/handover/merge-on-green.sh",
     ['echo "MAIN-RED advisory:', "via=advisory"],
     ["Allow, with a warning", "does not stop a change whose own checks passed"],
     ["Only a change that declares itself the fix goes through"]),
    ("force push: refused to main, warned elsewhere", "scripts/hooks/check-no-force-push.sh",
     ["Force-push to 'main' is not allowed.", "proceeding with force-push warnings"],
     ["To another branch it goes through with a warning"],
     []),
]

if case == "facts":
    for name, rel, code_has, page_has, page_not in FACTS:
        body = read(rel)
        if body is None:
            out.append("%s: %s is gone" % (name, rel))
            continue
        for s in code_has:
            if s not in body:
                out.append("%s: %s no longer says: %s" % (name, rel, s))
        for s in page_has:
            if s not in text:
                out.append("%s: the page does not say: %s" % (name, s))
        for s in page_not:
            if s in text:
                out.append("%s: the page still says: %s" % (name, s))

if case == "sources":
    model_rel = "docs/guide/dev-graph/graph.json"
    model = json.loads(read(model_rel))
    targets = [("step", n) for n in model["nodes"] if not n.get("sources")] + \
              [("move", e) for e in model["edges"] if e["id"].startswith("m.")]
    if not targets:
        out.append("the model has no step or move for this case to check")
    named = ""
    for head_line in open(os.path.join(real_root, "scripts/docs/test-workflow-page-drift.sh"), encoding="utf-8"):
        if not head_line.startswith("#"):
            break
        if re.match(r"#\s*selector:\s+names\s", head_line):
            named += head_line
    for kind, item in targets:
        where = "%s %s" % (kind, item["id"])
        src, why = item.get("source"), item.get("noSource")
        if bool(src) == bool(why):
            out.append("%s: needs a source or a noSource, exactly one" % where)
            continue
        if why:
            continue
        path, at, want = src.get("file", ""), src.get("line"), src.get("text", "")
        if not path or os.path.isabs(path) or ".." in path.split("/") or not want.strip() or type(at) is not int:
            out.append("%s: source needs a file inside the tree, a line and a text" % where)
            continue
        body = read(path)
        if body is None:
            out.append("%s: cited file missing: %s" % (where, path))
            continue
        if os.path.basename(path) not in named:
            out.append("%s: %s is not named in this suite's Cited files, so a change to it would not select this suite" % (where, os.path.basename(path)))
        lines = body.split("\n")
        if 1 <= at <= len(lines) and want in lines[at - 1]:
            continue
        hits = [i for i, l in enumerate(lines, 1) if want in l]
        if hits:
            out.append("%s: moved to line %d, cited line %s:%d no longer holds: %s (update its line in %s)" % (where, hits[0], path, at, want, model_rel))
        else:
            out.append("%s: the text is gone from %s, cited at line %d: %s" % (where, path, at, want))

for line in out:
    print(line)
PY
}

run_case() {
  local name=$1 r
  r=$(check "$2" "$ROOT")
  if [ -z "$r" ]; then ok "$name"; else bad "$name" "$r"; fi
}

run_case "1. NAMES: every script and command the page names exists" names
run_case "2. FLAGS: every switch and exit code the page names is in the code" flags
run_case "3. ORDER: chains the page shows in order follow the code's order" order
run_case "4. FACTS: every stated behaviour matches the code" facts

# --- 5. CONTROL: a temp copy of the page, its data file and the cited files;
# each mutation must make its case fail.
C="$TMP/copy"
copy_ok=1
for f in $DATA_REL $PAGE_REL scripts/_new-worktree.sh scripts/handover/chief/chief.sh \
    scripts/hooks/check-commit-msg.sh scripts/hooks/check-worktree-isolation.sh \
    scripts/handover/chief-kit/headed-arm-worker.sh scripts/lib/usage-preflight.sh; do
  mkdir -p "$C/$(dirname "$f")" && cp "$ROOT/$f" "$C/$f" 2>/dev/null || copy_ok=0
done
mut() { python3 -I -c 'import sys; p,a,b=sys.argv[1:4]; s=open(p,encoding="utf-8").read(); open(p,"w",encoding="utf-8").write(s.replace(a,b,1))' "$@"; }
if [ "$copy_ok" -ne 1 ]; then
  bad "5. CONTROL: temp copy" "could not copy the page, data file or cited files into $C"
else
  cp "$C/$PAGE_REL" "$TMP/page.html"
  # the page names checks in words, so plant a script name where it shows a branch name
  mut "$TMP/page.html" "<code>feat/login</code>" "<code>new-worktree-gate.sh</code>"
  r=$(check names "$ROOT" "$TMP/page.html")
  if grep -qF "page names script new-worktree-gate.sh" <<< "$r"; then ok "5a. CONTROL: a script the tree lacks fails case 1"; else bad "5a. CONTROL: a script the tree lacks fails case 1" "got: ${r:-nothing}"; fi

  base=$(check order "$C")
  if [ -n "$base" ]; then
    bad "5b. CONTROL: the unchanged copy passes case 3" "$base"
  else
    python3 -I -c 'import sys
p=sys.argv[1]; s=open(p,encoding="utf-8").read().split("\n")
i=next(i for i,l in enumerate(s) if "worktree ceiling reached" in l)
moved=s.pop(i); s.append(moved); open(p,"w",encoding="utf-8").write("\n".join(s))' "$C/scripts/_new-worktree.sh"
    r=$(check order "$C")
    if grep -qF "row merged comes after row ceiling" <<< "$r"; then ok "5b. CONTROL: the ceiling check moved after the merged-PR check fails case 3"; else bad "5b. CONTROL: the ceiling check moved after the merged-PR check fails case 3" "got: ${r:-nothing}"; fi
  fi

  mut "$C/scripts/handover/chief/chief.sh" 'CHIEF_FILL_PERCENT:-45}' 'CHIEF_FILL_PERCENT:-60}'
  r=$(check facts "$C")
  if grep -qF "chief hands over at 45 %: scripts/handover/chief/chief.sh no longer says" <<< "$r"; then ok "5c. CONTROL: a changed hand-over threshold fails case 4"; else bad "5c. CONTROL: a changed hand-over threshold fails case 4" "got: ${r:-nothing}"; fi
fi

run_case "6. SOURCES: each new step and move cites a line that holds its text, or says why it has none" sources

# --- 7. CONTROL: a fresh temp copy of the model and its cited files per mutation;
# prints the id of the mutated step or move, nothing when the model cites none.
S="$TMP/sources"
mut_source() {
  python3 -I - "$ROOT" "$S" "$1" "$2" <<'PY'
import json, os, shutil, sys
root, dest, kind, mode = sys.argv[1:5]
rel = "docs/guide/dev-graph/graph.json"
shutil.rmtree(dest, ignore_errors=True)
model = json.load(open(os.path.join(root, rel), encoding="utf-8"))
cited = [x for x in model["nodes"] + model["edges"] if x.get("source")]
for x in cited:
    path = os.path.join(dest, x["source"]["file"])
    os.makedirs(os.path.dirname(path), exist_ok=True)
    shutil.copyfile(os.path.join(root, x["source"]["file"]), path)
os.makedirs(os.path.dirname(os.path.join(dest, rel)), exist_ok=True)
pool = model["nodes"] if kind == "step" else model["edges"]
target = next((x for x in pool if x.get("source")), None)
if target and mode == "unmark":
    del target["source"]
elif target and mode in ("reword", "shift"):
    src = target["source"]
    path = os.path.join(dest, src["file"])
    lines = open(path, encoding="utf-8").read().split("\n")
    if mode == "reword":
        lines[src["line"] - 1] = lines[src["line"] - 1].replace(src["text"], "REWORDED")
    else:
        lines.insert(0, "")
    open(path, "w", encoding="utf-8").write("\n".join(lines))
json.dump(model, open(os.path.join(dest, rel), "w", encoding="utf-8"))
if target:
    print(target["id"])
PY
}
control_source() { # <name> <step|move> <mode> <what the failure says>
  local id r
  id=$(mut_source "$2" "$3")
  r=$(check sources "$S" "$ROOT/$PAGE_REL")
  if [ -n "$id" ] && grep -qF "$2 $id: $4" <<< "$r"; then ok "$1"; else bad "$1" "id=${id:-none}; got: ${r:-nothing}"; fi
}
mut_source step none >/dev/null
r=$(check sources "$S" "$ROOT/$PAGE_REL")
if [ -z "$r" ]; then ok "7a. CONTROL: the unchanged copy passes case 6"; else bad "7a. CONTROL: the unchanged copy passes case 6" "$r"; fi
control_source "7b. CONTROL: a step's cited line reworded fails case 6" step reword "the text is gone"
control_source "7c. CONTROL: a move's cited line reworded fails case 6" move reword "the text is gone"
control_source "7d. CONTROL: a step's cited line shifted fails case 6" step shift "moved to line"
control_source "7e. CONTROL: a move's cited line shifted fails case 6" move shift "moved to line"
control_source "7f. CONTROL: a step with neither source nor noSource fails case 6" step unmark "needs a source or a noSource"

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
