#!/usr/bin/env bash
# test-luna-index-hygiene.sh — hermetic: a scratch vault, a scratch qmd config
# and index, no network. The qmd rows run the real qmd against the scratch
# index and SKIP when qmd is not installed.
set -uo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
SUT="$REPO/scripts/luna/luna-index-hygiene.sh"
PASS=0; FAIL=0; SKIP=0
W="$(mktemp -d -t luna-index-hygiene.XXXXXX)" || exit 1; trap 'rm -rf "$W"' EXIT

check() { if [ "$2" = "$3" ]; then PASS=$((PASS+1)); echo "ok - $1";
  else FAIL=$((FAIL+1)); echo "FAIL - $1: expected '$2' got '$3'"; fi; }

# The luna block is copied from the live ~/.config/qmd/index.yml (a sibling
# collection with its own ignore list included), not hand-written.
write_cfg() {
  cat > "$1" <<EOF
collections:
  himmel:
    path: /srv/himmel
    pattern: "**/*.md"
    ignore:
      - "graphify-out/**"
      - "**/fixtures/**"
  luna:
    path: $2
    pattern: "**/*.md"
  ggs-local:
    path: /srv/ggs-local
    pattern: "**/*.md"
models:
  embed: hf:ggml-org/embeddinggemma-300M-GGUF/embeddinggemma-300M-Q8_0.gguf
EOF
}

# The fixture the ticket names: a graph export note and a graphify report.
make_vault() {
  mkdir -p "$1/60-Maps/graph" "$1/graphify-out/d" "$1/notes"
  echo "# x" > "$1/60-Maps/graph/x.md"
  echo "# r" > "$1/graphify-out/d/GRAPH_REPORT.md"
  echo "# n" > "$1/notes/n.md"
}

indexed() {  # indexed <cfg-dir> : the collection's file list as the real qmd sees it
  QMD_CONFIG_DIR="$1" XDG_CACHE_HOME="$1/cache" qmd ls luna 2>/dev/null | sed 's|.*qmd://luna/||' | sort | tr '\n' ' '
}

# --- RED: with no ignore list both generated files are indexed ----------------
if command -v qmd >/dev/null 2>&1; then
  V="$W/qv"; C="$W/qc"; mkdir -p "$C/cache"; make_vault "$V"
  write_cfg "$C/index.yml" "$V"
  QMD_CONFIG_DIR="$C" XDG_CACHE_HOME="$C/cache" qmd update >/dev/null 2>&1
  check "RED: unconfigured luna indexes the graph export and the report" \
    "60-Maps/graph/x.md graphify-out/d/GRAPH_REPORT.md notes/n.md " "$(indexed "$C")"
  bash "$SUT" --vault "$V" --qmd-config "$C/index.yml" --apply >/dev/null 2>&1
  QMD_CONFIG_DIR="$C" XDG_CACHE_HOME="$C/cache" qmd update >/dev/null 2>&1
  check "after apply + qmd update only the note stays indexed" "notes/n.md " "$(indexed "$C")"
else
  SKIP=$((SKIP+1)); echo "skip - qmd not installed: qmd-backed rows"
fi

# --- config rewrite ----------------------------------------------------------
V="$W/v1"; make_vault "$V"; CFG="$W/c1.yml"; write_cfg "$CFG" "$V"
cp "$CFG" "$W/c1.orig"
bash "$SUT" --vault "$V" --qmd-config "$CFG" >/dev/null 2>&1
check "dry-run leaves the qmd config untouched" 0 "$(cmp -s "$CFG" "$W/c1.orig" && echo 0 || echo 1)"
check "dry-run adds no .graphifyignore" 0 "$([ ! -e "$V/.graphifyignore" ] && echo 0 || echo 1)"

bash "$SUT" --vault "$V" --qmd-config "$CFG" --apply >/dev/null 2>&1
luna_ign="$(awk '/^  luna:/{f=1;next} f&&/^  [^ ]/{f=0} f&&/^      - /{print $2}' "$CFG" | tr '\n' ' ')"
check "luna gains the three ignore entries" \
  '"graphify-out/**" "60-Maps/graph/**" "handovers/**/verdicts/*/scratch/**" ' "$luna_ign"
him_ign="$(awk '/^  himmel:/{f=1;next} f&&/^  [^ ]/{f=0} f&&/^      - /{print $2}' "$CFG" | tr '\n' ' ')"
check "himmel's own ignore list is untouched" '"graphify-out/**" "**/fixtures/**" ' "$him_ign"
check "other collections and models survive" 3 "$(grep -c -E '^  (ggs-local|himmel):$|^models:$' "$CFG")"
cp "$CFG" "$W/c1.once"
bash "$SUT" --vault "$V" --qmd-config "$CFG" --apply >/dev/null 2>&1
check "a second apply is a no-op" 0 "$(cmp -s "$CFG" "$W/c1.once" && echo 0 || echo 1)"

# --- a pre-existing luna ignore list is merged, not replaced ------------------
V="$W/v2"; make_vault "$V"; CFG="$W/c2.yml"; write_cfg "$CFG" "$V"
awk '{print} /^  luna:/{f=1} f&&/pattern:/{print "    ignore:"; print "      - \"Clippings/_raw/**\""; f=0}' "$CFG" > "$CFG.n" && mv "$CFG.n" "$CFG"
bash "$SUT" --vault "$V" --qmd-config "$CFG" --apply >/dev/null 2>&1
luna_ign="$(awk '/^  luna:/{f=1;next} f&&/^  [^ ]/{f=0} f&&/^      - /{print $2}' "$CFG" | tr '\n' ' ')"
check "existing luna ignore entry kept, new ones appended" \
  '"Clippings/_raw/**" "graphify-out/**" "60-Maps/graph/**" "handovers/**/verdicts/*/scratch/**" ' "$luna_ign"

# --- a config without the collection is refused -------------------------------
printf 'collections:\n  other:\n    path: /x\n' > "$W/c3.yml"
bash "$SUT" --vault "$V" --qmd-config "$W/c3.yml" --apply >/dev/null 2>&1
check "missing collection exits nonzero" 3 "$?"

# --- .graphifyignore: corpus exclusion, existing lines kept, idempotent -------
V="$W/v4"; make_vault "$V"; CFG="$W/c4.yml"; write_cfg "$CFG" "$V"
printf '# keep me\nsessions/\n' > "$V/.graphifyignore"
bash "$SUT" --vault "$V" --qmd-config "$CFG" --apply >/dev/null 2>&1
check ".graphifyignore keeps its lines and gains the two exclusions" \
  "# keep me|sessions/|60-Maps/graph/|graphify-out/" "$(paste -sd'|' "$V/.graphifyignore")"
cp "$V/.graphifyignore" "$W/gi.once"
bash "$SUT" --vault "$V" --qmd-config "$CFG" --apply >/dev/null 2>&1
check ".graphifyignore second apply is a no-op" 0 "$(cmp -s "$V/.graphifyignore" "$W/gi.once" && echo 0 || echo 1)"

# --- offload: a move, never a delete -----------------------------------------
V="$W/v5"; make_vault "$V"; CFG="$W/c5.yml"; write_cfg "$CFG" "$V"; OFF="$W/off"
touch -d '3 days ago' "$V/graphify-out/d/GRAPH_REPORT.md"
bash "$SUT" --vault "$V" --qmd-config "$CFG" --offload-root "$OFF" >/dev/null 2>&1
check "offload dry-run leaves graphify-out in place" 0 "$([ -d "$V/graphify-out" ] && echo 0 || echo 1)"
bash "$SUT" --vault "$V" --qmd-config "$CFG" --offload-root "$OFF" --apply >/dev/null 2>&1
check "offload moves graphify-out out of the vault" 1 "$([ -e "$V/graphify-out" ] && echo 0 || echo 1)"
check "the report is under graphify-snapshots" 1 "$(find "$OFF/graphify-snapshots" -name GRAPH_REPORT.md 2>/dev/null | wc -l | tr -d ' ')"

V="$W/v6"; make_vault "$V"; CFG="$W/c6.yml"; write_cfg "$CFG" "$V"
bash "$SUT" --vault "$V" --qmd-config "$CFG" --offload-root "$W/off6" --apply >/dev/null 2>&1
check "a graphify-out written within 24h is not moved (a writer may target it)" 0 "$([ -f "$V/graphify-out/d/GRAPH_REPORT.md" ] && echo 0 || echo 1)"

V="$W/v7"; make_vault "$V"; CFG="$W/c7.yml"; write_cfg "$CFG" "$V"
touch -d '3 days ago' "$V/graphify-out/d/GRAPH_REPORT.md"; mkdir "$V/graphify-out/.promote.lock"
bash "$SUT" --vault "$V" --qmd-config "$CFG" --offload-root "$W/off7" --apply >/dev/null 2>&1
check "a held promote lock blocks the offload" 0 "$([ -d "$V/graphify-out/.promote.lock" ] && echo 0 || echo 1)"

echo "pass=$PASS fail=$FAIL skip=$SKIP"
[ "$FAIL" -eq 0 ]
