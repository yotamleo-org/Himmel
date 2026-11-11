#!/usr/bin/env bash
# chain-add.sh — the chain registry writer (himmel.chain-registry/1, the file chain-state.mjs and
# chain-render.py read): joins two linked open tickets in one chain.
#
#   chain-add.sh <KEY1> <KEY2> [--goal "<goal line>"] [--id <chain id>] [--version <V>]
#                [--registry FILE] [--mirror DIR]
#
# The two keys must be open, share a fixVersion (--version V: both carry V) and be joined by a Jira
# Blocks link either way, all as the Jira mirror reads them. Then:
#   - a chain already holding both: nothing changes (exit 0);
#   - one chain holding either key: the other key joins it, and the chain keeps its goal;
#   - no chain holding either: a new chain opens with the --goal line (required here) under --id, or
#     an id made of the goal's first five words.
# A goal (whenever given) has at least 3 words and at most 90 characters, chain-state.mjs's rule.
# The registry is checked with chain-state.mjs before the write and the result is checked before it
# replaces the file; any refusal leaves the registry byte for byte. Keys in two different chains are
# refused: merging chains is the chief's call, by hand.
#
# Defaults: --registry <handover root>/<user slug>/himmel/chains.json (focus-refresh.sh's path; an
# absent registry is refused, never created), --mirror ~/.himmel/state/jira-mirror/<JIRA_PROJECT_KEY
# or HIMMEL>. The write holds the doc lock (worker-doc-lock.sh) on the registry.
#
# Exit: 0 written or already joined; 1 refused (registry unchanged); 2 usage.
# PLATFORM GUARD: Linux-only kit; bash, python3, node, sha256sum, flock.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
    echo "usage: chain-add.sh <KEY1> <KEY2> [--goal \"<goal line>\"] [--id <chain id>] [--version <V>] [--registry FILE] [--mirror DIR]" >&2
    exit 2
}
refuse() { echo "chain-add: refused, registry unchanged: $1" >&2; exit 1; }

[ "$#" -ge 2 ] || usage
k1="$1" k2="$2"; shift 2
[[ "$k1" =~ ^HIMMEL-[0-9]+$ ]] && [[ "$k2" =~ ^HIMMEL-[0-9]+$ ]] && [ "$k1" != "$k2" ] || usage
goal="" id="" version="" reg="" mir=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        --goal|--id|--version|--registry|--mirror)
            [ "$#" -ge 2 ] || usage
            case "$1" in
                --goal) goal="$2" ;; --id) id="$2" ;; --version) version="$2" ;;
                --registry) reg="$2" ;; --mirror) mir="$2" ;;
            esac
            shift 2 ;;
        *) usage ;;
    esac
done

if [ -z "$reg" ]; then
    # shellcheck source=../../lib/handover-path.sh
    . "$HERE/../../lib/handover-path.sh"
    # shellcheck source=../../lib/user-slug.sh
    . "$HERE/../../lib/user-slug.sh"
    # shellcheck source=../../lib/load-dotenv.sh
    . "$HERE/../../lib/load-dotenv.sh"
    load_dotenv --root "$(_load_dotenv_primary_for "$HERE/../../.." 2>/dev/null)" HANDOVER_DIR USER_SLUG 2>/dev/null || true # swallow-ok: an unreadable .env leaves the resolver's own fallback; a registry that is not there is refused below
    root="$(handover_root 2>/dev/null)" || refuse "no handover root resolves: pass --registry"  # swallow-ok: no default registry path refuses, naming --registry
    slug="$(cd "$HERE/../../.." && user_slug 2>/dev/null)" || refuse "no user slug resolves: pass --registry"  # swallow-ok: no default registry path refuses, naming --registry
    reg="$root/$slug/himmel/chains.json"
fi
[ -n "$mir" ] || mir="$HOME/.himmel/state/jira-mirror/${JIRA_PROJECT_KEY:-HIMMEL}"
[ -f "$reg" ] || refuse "no chain registry at $reg"
[ -d "$mir" ] || refuse "no Jira mirror at $mir"

# shellcheck source=../../lib/prim.sh
. "$HERE/../../lib/prim.sh" || refuse "cannot load prim.sh"
tmp="$(tmpdir)" || refuse "cannot make a temp dir"
new=""
trap 'rm -rf "$tmp"; [ -z "$new" ] || rm -f "$new"' EXIT
mkdir "$tmp/state"
valid() { # <registry file>: chain-state.mjs reads it, or the reason is on $tmp/err
    node "$HERE/chain-state.mjs" --json --registry "$1" --mirror "$mir" --state "$tmp/state" > /dev/null 2> "$tmp/err" \
        && ! grep -q '^chain-state:' "$tmp/err"
}

# shellcheck source=scripts/handover/chief-kit/worker-doc-lock.sh
. "$HERE/worker-doc-lock.sh"
lrc=0; doc_lock "$reg" chain-add || lrc=$?
[ "$lrc" -ne 1 ] || refuse "cannot lock $reg"
valid "$reg" || refuse "the registry is invalid: $(grep -m1 '^chain-state:' "$tmp/err")"

new="$(mktemp "$reg.XXXXXX")" || refuse "cannot create a temp file next to $reg"
msg="$(python3 -I -c '
import json, os, re, sys
reg, mir, k1, k2, goal, cid, version, out = sys.argv[1:9]
def no(m):
    print(m); sys.exit(1)
if goal and (len(goal.split()) < 3 or len(goal) > 90):
    no("the goal needs at least 3 words and at most 90 characters: %r" % goal)
def issue(k):
    try:
        text = open(os.path.join(mir, k + ".md"), encoding="utf-8").read()
    except OSError:
        no("%s is not in the Jira mirror %s" % (k, mir))
    m = re.match(r"---\n(.*?)\n---\n", text, re.S)
    fm = {}
    for line in (m[1] if m else "").split("\n"):
        kv = re.match(r" *(\w+): (.*)$", line)
        if kv:
            try: fm[kv[1]] = json.loads(kv[2])
            except ValueError: fm[kv[1]] = kv[2]
    if fm.get("key") != k or fm.get("statusCategory") not in ("To Do", "In Progress", "Done") or not isinstance(fm.get("fixVersions"), list):
        no("%s has no readable status or fixVersions in the mirror" % k)
    if fm["statusCategory"] == "Done":
        no("%s is not open (%s)" % (k, fm.get("status")))
    bb = [x for s in (fm.get("blocked_by") or []) for x in re.findall(r"[A-Z][A-Z0-9]*-\d+", str(s))]
    return set(map(str, fm["fixVersions"])), set(bb)
(v1, b1), (v2, b2) = issue(k1), issue(k2)
if version and not (version in v1 and version in v2):
    no("%s and %s are not both in %s" % (k1, k2, version))
if not v1 & v2:
    no("%s and %s share no fixVersion" % (k1, k2))
if k2 not in b1 and k1 not in b2:
    no("%s and %s have no Jira Blocks link either way (link them first)" % (k1, k2))
r = json.load(open(reg, encoding="utf-8"))
holders = [c for c in r["chains"] if k1 in c["members"] or k2 in c["members"]]
both = [c for c in holders if k1 in c["members"] and k2 in c["members"]]
if both:
    print("%s and %s already share %s" % (k1, k2, both[0]["id"])); sys.exit(3)
if len(holders) > 1:
    no("%s and %s are held by chains %s: merge them by hand" % (k1, k2, ", ".join(c["id"] for c in holders)))
if holders:
    c = holders[0]
    k = k2 if k1 in c["members"] else k1
    c["members"].append(k)
    print("added %s to %s (%s)" % (k, c["id"], c["goal"]) + (", its goal kept" if goal and goal != c["goal"] else ""))
else:
    if not goal:
        no("%s and %s are in no chain: a new chain needs --goal" % (k1, k2))
    if not cid:
        words = re.findall(r"[a-z0-9]+", goal.lower())[:5]
        while words and len("-".join(words)) > 41:
            words.pop()
        cid = "-".join(words)
    if not re.fullmatch(r"[a-z0-9][a-z0-9-]{1,40}", cid):
        no("chain id %r is not [a-z0-9][a-z0-9-]{1,40}: pass --id" % cid)
    if any(c["id"] == cid for c in r["chains"]):
        no("chain id %s is taken: pass another --id" % cid)
    r["chains"].append({"id": cid, "goal": goal, "members": [k1, k2]})
    print("opened %s (%s) with %s %s" % (cid, goal, k1, k2))
with open(out, "w", encoding="utf-8") as f:
    f.write(json.dumps(r, indent=2, ensure_ascii=False) + "\n")
' "$reg" "$mir" "$k1" "$k2" "$goal" "$id" "$version" "$new")"
prc=$?
case "$prc" in
    0) ;;
    3) echo "chain-add: $msg"; exit 0 ;;
    1) refuse "${msg:-the registry could not be read}" ;;
    *) refuse "the writer failed (rc=$prc): $msg" ;;
esac
valid "$new" || refuse "the result fails chain-state.mjs: $(grep -m1 '^chain-state:' "$tmp/err")"
chmod --reference="$reg" "$new" || refuse "cannot give the new registry the mode of $reg"  # gnu-ok: Linux-only kit; the write keeps the registry mode
mv -f "$new" "$reg" || refuse "cannot replace $reg"
new=""
echo "chain-add: $msg"
