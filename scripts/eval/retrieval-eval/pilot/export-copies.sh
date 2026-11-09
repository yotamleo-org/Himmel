#!/usr/bin/env bash
# export-copies.sh <repo> <commit> <dest> <manifest> [exclude-path]...
# Exports <repo> at <commit> with `git archive` (never the working tree) into the empty or
# absent <dest>, minus each exclude path (the himmel pilot dir, luna handovers/), then writes
# <manifest>: every file's sha256/size, every symlink's target, the count and the manifest's
# own canonical sha256. Refuses (exit 3) when a symlink points outside the export, an excluded
# path survives, or the file count is not the git tree's count minus the exclusions.
set -uo pipefail
[ $# -ge 4 ] || { echo "usage: export-copies.sh <repo> <commit> <dest> <manifest> [exclude]..." >&2; exit 2; }
repo=$1 commit=$2 dest=$3 manifest=$4; shift 4
if [ -e "$dest" ] && [ -n "$(ls -A "$dest" 2>/dev/null)" ]; then echo "export: refused: $dest is not empty" >&2; exit 3; fi
mkdir -p "$dest" || exit 3
specs=(.)
for x in "$@"; do specs+=(":(exclude)${x%/}"); done
if ! git -C "$repo" archive --format=tar "$commit" -- "${specs[@]}" | tar -x -C "$dest"; then
  echo "export: refused: git archive of $commit failed" >&2; exit 3
fi
tree=$(mktemp "${TMPDIR:-/tmp}/export-tree.XXXXXX") || exit 3
trap 'rm -f "$tree"' EXIT
git -C "$repo" ls-tree -r --name-only -z "$commit" > "$tree" || { echo "export: refused: git ls-tree failed" >&2; exit 3; }
python3 -I - "$dest" "$manifest" "$commit" "$tree" "$@" <<'EOF'
import hashlib, json, os, sys
dest, manifest, commit = sys.argv[1], sys.argv[2], sys.argv[3]
excludes = [x.rstrip("/") for x in sys.argv[5:]]
tree = [p for p in open(sys.argv[4], "rb").read().decode().split("\0") if p]
expected = sum(1 for p in tree if not any(p == x or p.startswith(x + "/") for x in excludes))
root = os.path.realpath(dest)
files, links = {}, {}
for dp, dns, fns in os.walk(dest):
    for n in dns + fns:
        full = os.path.join(dp, n)
        rel = os.path.relpath(full, dest)
        if os.path.islink(full):
            target = os.readlink(full)
            if os.path.commonpath([root, os.path.realpath(full)]) != root:
                sys.exit("export: refused: symlink %s points outside the export (%s)" % (rel, target))
            links[rel] = target
        elif n in fns:
            h = hashlib.sha256(open(full, "rb").read()).hexdigest()
            files[rel] = {"sha256": h, "size": os.path.getsize(full)}
for x in excludes:
    if any(p == x or p.startswith(x + "/") for p in list(files) + list(links)):
        sys.exit("export: refused: excluded path %s survived" % x)
count = len(files) + len(links)
if count != expected:
    sys.exit("export: refused: %d entries exported, git tree minus exclusions has %d" % (count, expected))
body = {"commit": commit, "excludes": excludes, "files": files, "symlinks": links, "count": count}
body["manifest_sha256"] = hashlib.sha256(json.dumps({"files": files, "symlinks": links}, sort_keys=True).encode()).hexdigest()
with open(manifest, "w") as f:
    json.dump(body, f, indent=1, sort_keys=True)
for dp, dns, fns in os.walk(dest):
    for n in fns:
        p = os.path.join(dp, n)
        if not os.path.islink(p):
            os.chmod(p, 0o444)
EOF
rc=$?
[ "$rc" -eq 0 ] || exit 3
