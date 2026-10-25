#!/usr/bin/env bash
# Suite for the footprint page, docs/setup/footprint.md ("What changes on your
# machine").
#
# The page lists what an install writes and what uninstall does with each
# item. The uninstaller reads scripts/install/uninstall-manifest.tsv, so the
# page is checked against that file: a manifest row the page neither shows nor
# names as left out fails, and so does a page row the manifest does not have.
#
#   1. ROWS     — every id in the page's "Row" column is a manifest id, and
#                 none is listed twice.
#   2. COMPLETE — every manifest id is on the page or in LEFT_OUT below, never
#                 both, and every LEFT_OUT id is still a manifest row.
#   3. CLASS    — each row's "Uninstall" cell agrees with the manifest class:
#                 a state row names --purge-state, a keep row starts with
#                 "Kept" or "Never touched", a code row starts with neither.
#   4. UNDO     — the page links to updating.md#undo, and updating.md carries
#                 an id="undo" anchor.
#   5. CONTROL  — a manifest with an extra row fails case 2, a page with an
#                 unknown id fails case 1, and a state row whose cell drops
#                 --purge-state fails case 3, so none can pass vacuously.
#
# Platform guard (gitbash-only): POSIX bash 3.2+ plus python3, so it runs
# unchanged under Git Bash on Windows. No .ps1 twin needed.
#
# Usage: bash scripts/docs/test-footprint-page.sh [page.md [manifest.tsv]]
# Exit:  0 = every case passed, 1 = at least one failed (all are reported).
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
PAGE="${1:-$ROOT/docs/setup/footprint.md}"
MANIFEST="${2:-$ROOT/scripts/install/uninstall-manifest.tsv}"
UPDATING="$ROOT/docs/setup/updating.md"

pass=0
fail=0
ok() { pass=$((pass + 1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf 'FAIL %s\n' "$1"; [ -n "${2:-}" ] && printf '       %s\n' "$2"; }

command -v python3 >/dev/null 2>&1 || { echo "FAIL: python3 required" >&2; exit 1; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/footprint-page.XXXXXX")" || exit 1
trap 'rm -rf "$TMP"' EXIT

# check <case> <page> <manifest>: prints one violation per line; empty output = clean.
check() {
  python3 -I - "$1" "$2" "$3" "$UPDATING" <<'PY'
import os, re, sys

case, page, manifest, updating = sys.argv[1:5]

# Rows a starter install on Linux or macOS does not write, so the page leaves them out.
LEFT_OUT = {
    "aur-package": "the AUR package payload: pacman owns it",
    "graphify-wiring": "graphify is wired by the luna profile, not by a starter install",
}

klass = {}
for line in open(manifest, encoding="utf-8"):
    if not line.strip() or line.startswith("#"):
        continue
    cols = line.rstrip("\n").split("\t")
    klass[cols[0]] = cols[1]

if not os.path.isfile(page):
    print(f"page missing: {page}")
    sys.exit(0)
text = open(page, encoding="utf-8").read()

rows, header = [], None
for line in text.split("\n"):
    if not line.startswith("|"):
        header = None
        continue
    cells = [c.strip() for c in line.strip().strip("|").split("|")]
    if all(re.fullmatch(r":?-+:?", c) for c in cells):
        continue
    if header is None:
        header = cells
        continue
    if "Row" in header and "Uninstall" in header:
        m = re.fullmatch(r"`([a-z0-9-]+)`", cells[header.index("Row")])
        rows.append((m.group(1) if m else cells[header.index("Row")], cells[header.index("Uninstall")]))

ids = [r for r, _ in rows]
if case == "rows":
    if not rows:
        print("no table with a Row and an Uninstall column")
    for r in sorted(set(ids)):
        if r not in klass:
            print(f"page row {r!r} is not a manifest id")
        if ids.count(r) > 1:
            print(f"page row {r!r} is listed {ids.count(r)} times")
elif case == "complete":
    for r in klass:
        if r in LEFT_OUT and r in ids:
            print(f"manifest row {r!r} is both on the page and left out")
        elif r not in LEFT_OUT and r not in ids:
            print(f"manifest row {r!r} is not on the page (add it, or to LEFT_OUT with a reason)")
    for r in LEFT_OUT:
        if r not in klass:
            print(f"LEFT_OUT row {r!r} is no longer in the manifest")
elif case == "class":
    for r, cell in rows:
        c = klass.get(r)
        if c == "state" and "`--purge-state` removes" not in cell:
            print(f"{r} (state): Uninstall cell does not say --purge-state removes it: {cell}")
        elif c == "keep" and not re.match(r"(Kept|Never touched)", cell):
            print(f"{r} (keep): Uninstall cell does not start with Kept or Never touched: {cell}")
        elif c == "code" and re.match(r"(Kept|Never)", cell):
            print(f"{r} (code): Uninstall cell says it stays: {cell}")
elif case == "undo":
    if "updating.md#undo" not in text:
        print("the page does not link to updating.md#undo")
    if not re.search(r'<a id="undo"></a>', open(updating, encoding="utf-8").read()):
        print('docs/setup/updating.md has no <a id="undo"></a> anchor')
PY
}

run() {
  local name="$1" case="$2" out rc
  out="$(check "$case" "$PAGE" "$MANIFEST")"
  rc=$?
  if [ "$rc" -ne 0 ]; then bad "$name" "checker exited $rc"
  elif [ -z "$out" ]; then ok "$name"
  else bad "$name" "$(printf '%s' "$out" | head -20 | tr '\n' ';')"; fi
}

run "1 ROWS: every page row is a manifest id, once" rows
run "2 COMPLETE: every manifest row is on the page or left out with a reason" complete
run "3 CLASS: each Uninstall cell agrees with the manifest class" class
run "4 UNDO: the page links to updating.md#undo and the anchor exists" undo

# 5. CONTROL
cp "$MANIFEST" "$TMP/manifest.tsv"
printf 'made-up-row\tcode\tnowhere\tfile\t-\t{HOME}/.made-up\t6\ta row the page does not show\tnone\n' >>"$TMP/manifest.tsv"
if [ -n "$(check complete "$PAGE" "$TMP/manifest.tsv")" ]; then ok "5a CONTROL: a manifest row added without a page change fails case 2"; else bad "5a CONTROL: an added manifest row passed case 2"; fi

if [ -f "$PAGE" ]; then
  cp "$PAGE" "$TMP/page.md"
  printf '\n| What | Uninstall | Row |\n|---|---|---|\n| made up | Removed | %smade-up-row%s |\n' '`' '`' >>"$TMP/page.md"
  if [ -n "$(check rows "$TMP/page.md" "$MANIFEST")" ]; then ok "5b CONTROL: an unknown page row fails case 1"; else bad "5b CONTROL: an unknown page row passed case 1"; fi

  sed 's/--purge-state/--purge-nothing/g' "$PAGE" >"$TMP/page-nopurge.md"
  if [ -n "$(check class "$TMP/page-nopurge.md" "$MANIFEST")" ]; then ok "5c CONTROL: a state row without --purge-state fails case 3"; else bad "5c CONTROL: a state row without --purge-state passed case 3"; fi

  tick='`'
  sed "s/${tick}--purge-state${tick} removes/${tick}--purge-state${tick} never removes/g" "$PAGE" >"$TMP/page-negated.md"
  if [ -n "$(check class "$TMP/page-negated.md" "$MANIFEST")" ]; then ok "5d CONTROL: a state row that negates --purge-state fails case 3"; else bad "5d CONTROL: a state row that negates --purge-state passed case 3"; fi
else
  bad "5b/5c CONTROL: page missing: $PAGE"
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
