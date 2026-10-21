#!/usr/bin/env bash
# luna-index-hygiene.sh — keep generated graph output out of the luna qmd
# collection and out of the graphify AST corpus.
#
# Three idempotent steps, dry-run by default, --apply to write:
#   1. qmd: add the generated-output ignore entries to the named collection's
#      `ignore:` list in the qmd config (index.yml); existing entries and every
#      other collection are left as they are.
#   2. graphify: add the same trees to <vault>/.graphifyignore, which
#      `graphify update` reads at the corpus root, so the hourly AST run stops
#      ingesting graphify's own Obsidian export.
#   3. offload (only with --offload-root): MOVE <vault>/graphify-out to
#      <offload-root>/graphify-snapshots/. Never rm. Refused while a promote
#      lock is held or any file in it changed in the last 24 h, because either
#      means a writer still targets it.
# 60-Maps/graph/ itself is never touched: Obsidian may use the export.
#
# Usage: luna-index-hygiene.sh --vault DIR --qmd-config FILE [--collection luna]
#                              [--offload-root DIR] [--apply]
# Exit: 0 ok, 1 a file write or the offload move failed, 2 usage, 3 collection
# not in the config, 4 unsupported config shape.
set -uo pipefail

VAULT=""; CFG=""; COLLECTION="luna"; OFFLOAD_ROOT=""; APPLY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --vault|--qmd-config|--collection|--offload-root)
      [ $# -ge 2 ] || { echo "luna-index-hygiene: $1 needs a value" >&2; exit 2; } ;;
  esac
  case "$1" in
    --vault) VAULT="${2:-}"; shift 2 ;;
    --qmd-config) CFG="${2:-}"; shift 2 ;;
    --collection) COLLECTION="${2:-}"; shift 2 ;;
    --offload-root) OFFLOAD_ROOT="${2:-}"; shift 2 ;;
    --apply) APPLY=1; shift ;;
    *) echo "luna-index-hygiene: unknown argument '$1'" >&2; exit 2 ;;
  esac
done
[ -d "$VAULT" ] || { echo "luna-index-hygiene: --vault must be an existing directory" >&2; exit 2; }
[ -f "$CFG" ] || { echo "luna-index-hygiene: --qmd-config must be an existing file" >&2; exit 2; }
[ -n "$COLLECTION" ] || { echo "luna-index-hygiene: --collection must not be empty" >&2; exit 2; }

QMD_IGNORE=('graphify-out/**' '60-Maps/graph/**' 'handovers/**/verdicts/*/scratch/**')
GRAPHIFY_IGNORE=('60-Maps/graph/' 'graphify-out/')

mode=$([ "$APPLY" -eq 1 ] && echo apply || echo dry-run)
echo "luna-index-hygiene: $mode vault=$VAULT collection=$COLLECTION"

# --- 1. qmd ignore list -------------------------------------------------------
# ponytail: line-based edit of the two-level index.yml (qmd's own writer has no
# ignore verb), block-style `ignore:` lists only; upgrade path is a qmd
# `collection ignore` verb.
python3 -I - "$CFG" "$COLLECTION" "$APPLY" "${QMD_IGNORE[@]}" <<'PY'
import os, sys
cfg, coll, apply = sys.argv[1], sys.argv[2], sys.argv[3] == "1"
want = sys.argv[4:]
lines = open(cfg).read().split("\n")

def indent(s):
    return len(s) - len(s.lstrip(" "))

start = next((i for i, l in enumerate(lines) if l == "  %s:" % coll), None)
if start is None:
    print("luna-index-hygiene: collection '%s' is not in %s" % (coll, cfg), file=sys.stderr)
    sys.exit(3)
end = start + 1
while end < len(lines) and (lines[end].strip() == "" or indent(lines[end]) > 2):
    end += 1
while end > start + 1 and lines[end - 1].strip() == "":
    end -= 1

block = lines[start + 1:end]
ig = next((j for j, l in enumerate(block) if l.startswith("    ignore:")), None)
if ig is not None and block[ig].strip() != "ignore:":
    print("luna-index-hygiene: '%s' has an inline ignore list; only block style is supported" % coll, file=sys.stderr)
    sys.exit(4)

have = []
if ig is None:
    insert_at = len(block)
else:
    insert_at = ig + 1
    first = block[insert_at] if insert_at < len(block) else ""
    if first.lstrip().startswith("- ") and not first.startswith("      - "):
        print("luna-index-hygiene: '%s' ignore items are not indented six spaces; refusing to edit" % coll, file=sys.stderr)
        sys.exit(4)
    while insert_at < len(block) and block[insert_at].startswith("      - "):
        have.append(block[insert_at][8:].strip().strip('"').strip("'"))
        insert_at += 1
missing = [w for w in want if w not in have]
if not missing:
    print("luna-index-hygiene: qmd ignore list already complete")
    sys.exit(0)
new = ['      - "%s"' % m for m in missing]
if ig is None:
    new = ["    ignore:"] + new
print("luna-index-hygiene: qmd ignore +%s" % ", ".join(missing))
if apply:
    block[insert_at:insert_at] = new
    lines[start + 1:end] = block
    tmp = cfg + ".hygiene.tmp"
    with open(tmp, "w") as fh:
        fh.write("\n".join(lines))
    os.replace(tmp, cfg)
PY
rc=$?
[ "$rc" -eq 0 ] || exit "$rc"

# --- 2. graphify corpus exclusion --------------------------------------------
GI="$VAULT/.graphifyignore"
gi_missing=()
for entry in "${GRAPHIFY_IGNORE[@]}"; do
  if [ ! -f "$GI" ] || ! grep -qxF "$entry" "$GI"; then gi_missing+=("$entry"); fi
done
if [ "${#gi_missing[@]}" -eq 0 ]; then
  echo "luna-index-hygiene: .graphifyignore already complete"
else
  echo "luna-index-hygiene: .graphifyignore +${gi_missing[*]}"
  if [ "$APPLY" -eq 1 ]; then
    # a file without a trailing newline would fuse its last line with ours
    if [ -s "$GI" ] && [ -n "$(tail -c1 "$GI")" ]; then
      printf '\n' >> "$GI" || { echo "luna-index-hygiene: cannot write $GI" >&2; exit 1; }
    fi
    printf '%s\n' "${gi_missing[@]}" >> "$GI" || { echo "luna-index-hygiene: cannot write $GI" >&2; exit 1; }
  fi
fi

# --- 3. offload the stale in-vault graphify-out -------------------------------
if [ -n "$OFFLOAD_ROOT" ]; then
  SRC="$VAULT/graphify-out"
  if [ ! -d "$SRC" ]; then
    echo "luna-index-hygiene: offload: no $SRC, nothing to move"
  elif [ -e "$SRC/.promote.lock" ]; then
    echo "luna-index-hygiene: offload REFUSED: promote lock held in $SRC" >&2
  elif ! recent="$(find "$SRC" -type f -mmin -1440 -print -quit)"; then
    echo "luna-index-hygiene: offload REFUSED: could not scan $SRC for recent writes" >&2
  elif [ -n "$recent" ]; then
    echo "luna-index-hygiene: offload REFUSED: $SRC has a file written in the last 24 h, a writer may still target it" >&2
  else
    DEST="$OFFLOAD_ROOT/graphify-snapshots/graphify-out-$(date +%Y%m%d-%H%M%S)"
    echo "luna-index-hygiene: offload $SRC -> $DEST"
    if [ "$APPLY" -eq 1 ]; then
      mkdir -p "$OFFLOAD_ROOT/graphify-snapshots" || exit 1
      [ ! -e "$DEST" ] || { echo "luna-index-hygiene: $DEST exists; refusing to overwrite" >&2; exit 1; }
      mv "$SRC" "$DEST" || exit 1
    fi
  fi
fi
exit 0
