#!/usr/bin/env bash
set -u -o pipefail
export TZ='Etc/GMT-2'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
APPLY="$PLUGIN_DIR/tools/apply-clip-actions.mjs"
TIMELINE="$PLUGIN_DIR/tools/daily-timeline.mjs"

pass=0
fail=0
assert() {
    local desc="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        echo "  PASS  $desc"; pass=$((pass+1))
    else
        echo "  FAIL  $desc"
        echo "         expected: $expected"
        echo "         actual:   $actual"
        fail=$((fail+1))
    fi
}

D0="2026-06-27"
D="2026-06-28"
LEDGER_NAME=".apply-clip-actions.ledger.jsonl"

tmp="$(mktemp -d "${TMPDIR:-/tmp}/apply-clip-actions.XXXXXX")" || exit 1
trap 'rm -rf "$tmp"' EXIT

sha() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$@"; else shasum -a 256 "$@"; fi; }
tree_hash() {
    ( cd "$1" && find . -type f ! -name "$LEDGER_NAME" | LC_ALL=C sort \
        | while read -r f; do sha "$f"; done | sha | cut -d' ' -f1 )
}
count() { grep -c -- "$1" "$2" 2>/dev/null || true; }
lines() { wc -l "$1" | awk '{print $1}'; }

mkclip() {
    local name="$1" triaged_at="$2" tag="${3:-}" extra="${4:-}"
    local f="$P/Clippings/_evidence/$name.md"
    {
        echo "---"
        echo "title: \"Clip $name\""
        echo "type: article"
        echo "status: reviewed"
        echo "processed: true"
        echo "triaged_at: $triaged_at"
        echo "evidence_kind:"
        echo "  - concepts"
        if [ -n "$tag" ]; then echo "tags:"; echo "  - $tag"; fi
        if [ -n "$extra" ]; then echo "$extra"; fi
        echo "---"
        echo "Synthetic body for $name."
    } > "$f"
}

P="$tmp/pristine"
mkdir -p "$P/Clippings/_evidence" "$P/60-Maps" "$P/50-Journal/Daily"

cat > "$P/60-Maps/Alpha-MOC.md" <<'EOF'
---
type: moc
title: "Alpha MOC"
tags:
  - alpha
  - moc
---

# Alpha

Intro.

## Evidence

- [[Clippings/_evidence/alpha-1|Clip alpha-1]] — seeded by hand

## Notes

Keep this section last.
EOF
cat > "$P/60-Maps/Beta-MOC.md" <<'EOF'
---
type: moc
title: "Beta MOC"
tags:
  - beta
  - moc
---

# Beta

No evidence section yet.
EOF
printf -- '---\r\ntype: moc\r\ntitle: "Gamma MOC"\r\ntags:\r\n  - gamma\r\n  - moc\r\n---\r\n\r\n# Gamma\r\n\r\n## Evidence\r\n\r\n- [[Clippings/_evidence/seed]] — seed\r\n' > "$P/60-Maps/Gamma-MOC.md"

for n in alpha-1 alpha-2 alpha-3; do mkclip "$n" "$D0" alpha; done
for n in beta-1 beta-2; do mkclip "$n" "$D0" beta; done
mkclip eval-1 "$D0" "" 'source: "https://github.com/example/tool"'
for n in arch-1 arch-2 arch-3 arch-4; do mkclip "$n" "$D0" ""; done
mkclip gamma-1 "$D" gamma
for n in arch-5 arch-6; do mkclip "$n" "$D" ""; done
mkclip arch-fail "$D" "" 'harvest_status: failed'
mkclip tick-1 "$D" himmel

node "$TIMELINE" --vault "$P" --date "$D0" >/dev/null 2>&1
node "$TIMELINE" --vault "$P" --date "$D" >/dev/null 2>&1
NOTE="$P/50-Journal/Daily/$D.md"

echo "Test group 0: fixture sanity"
assert "day note lists 12 open actions (5 today + 7 carried)" "12" "$(count '^- \[ \] ' "$NOTE")"

echo "Test group 1: dry run (default mode)"
A="$tmp/A"; cp -R "$P" "$A"
h0="$(tree_hash "$A")"
out="$(node "$APPLY" --vault "$A" --date "$D" --limit 50 2>&1)"; rc=$?
assert "dry run exits 0" "0" "$rc"
assert "dry run leaves the tree byte-identical" "$h0" "$(tree_hash "$A")"
assert "dry run creates no ledger" "no" "$([ -e "$A/$LEDGER_NAME" ] && echo yes || echo no)"
assert "one 'would' line per apply-eligible action (10)" "10" "$(printf '%s\n' "$out" | grep -c '^would ')"
assert "3 folds would apply" "3" "$(printf '%s\n' "$out" | grep -c '^would fold ')"
assert "7 archives would apply" "7" "$(printf '%s\n' "$out" | grep -c '^would archive ')"
assert "evaluate clip never offered" "0" "$(printf '%s\n' "$out" | grep -c 'eval-1')"
assert "ticket clip never offered" "0" "$(printf '%s\n' "$out" | grep -c 'tick-1')"
out="$(node "$APPLY" --vault "$A" --date "$D" 2>&1)"
assert "default limit bounds a dry run to 5 lines" "5" "$(printf '%s\n' "$out" | grep -c '^would ')"
out="$(node "$APPLY" --vault "$A" --date "$D" --limit 3 2>&1)"
assert "--limit 3 bounds a dry run to 3 lines" "3" "$(printf '%s\n' "$out" | grep -c '^would ')"

echo "Test group 2: apply --limit 5"
out="$(node "$APPLY" --vault "$A" --date "$D" --apply --limit 5 2>&1)"; rc=$?
L="$A/$LEDGER_NAME"
assert "apply exits 0" "0" "$rc"
assert "exactly 5 actions applied" "5" "$(printf '%s\n' "$out" | grep -c '^✓ ')"
assert "5 ledger lines appended" "5" "$(lines "$L")"
ids1="$(grep -o '"id":"[0-9a-f]*"' "$L" | sort)"
cp -R "$A" "$tmp/B"
out="$(node "$APPLY" --vault "$A" --date "$D" --apply --limit 5 2>&1)"
assert "second run applies the other 5" "5" "$(printf '%s\n' "$out" | grep -c '^✓ ')"
assert "ledger now holds 10 lines" "10" "$(lines "$L")"
assert "10 distinct action ids" "10" "$(grep -o '"id":"[0-9a-f]*"' "$L" | sort -u | wc -l | tr -d ' ')"
h1="$(tree_hash "$A")"
out="$(node "$APPLY" --vault "$A" --date "$D" --apply --limit 5 2>&1)"
assert "third run applies nothing" "0" "$(printf '%s\n' "$out" | grep -c '^✓ ')"
assert "third run leaves the tree byte-identical" "$h1" "$(tree_hash "$A")"
assert "third run adds no ledger line" "10" "$(lines "$L")"

echo "Test group 3: what an apply writes"
AR="$A/Clippings/_evidence/arch-1.md"
assert "archived clip carries archived: true" "1" "$(count '^archived: true$' "$AR")"
assert "archived clip carries archived_at: <apply date>" "1" "$(count "^archived_at: $D\$" "$AR")"
assert "archived clip keeps status: reviewed" "1" "$(count '^status: reviewed$' "$AR")"
assert "archived clip stays in _evidence/" "yes" "$([ -f "$AR" ] && echo yes || echo no)"
assert "evaluate clip is not stamped" "0" "$(count '^archived' "$A/Clippings/_evidence/eval-1.md")"
assert "ticket clip is not stamped" "0" "$(count '^archived' "$A/Clippings/_evidence/tick-1.md")"
AL="$A/60-Maps/Alpha-MOC.md"
assert "fold added the fresh clip links (alpha-2, alpha-3)" "2" "$(grep -cE 'alpha-[23]' "$AL")"
assert "fold did not repeat the seeded link" "1" "$(grep -c 'alpha-1' "$AL")"
assert "fold landed inside ## Evidence, before ## Notes" "yes" "$(awk '/alpha-3/{a=NR} /^## Notes/{n=NR} END{print (a && n && a<n) ? "yes" : "no"}' "$AL")"
BE="$A/60-Maps/Beta-MOC.md"
assert "map without Evidence gets one ## Evidence heading" "1" "$(grep -c '^## Evidence$' "$BE")"
assert "both beta clips linked" "2" "$(grep -cE 'beta-[12]' "$BE")"
GA="$A/60-Maps/Gamma-MOC.md"
assert "CRLF map stays CRLF on every line" "$(lines "$GA")" "$(grep -c $'\r' "$GA")"
assert "gamma clip linked" "1" "$(grep -c 'gamma-1' "$GA")"

echo "Test group 4: daily timeline after an apply"
node "$TIMELINE" --vault "$tmp/B" --date "$D" >/dev/null 2>&1
BN="$tmp/B/50-Journal/Daily/$D.md"
leak=0
for id in $(printf '%s\n' "$ids1" | sed 's/.*:"\(.*\)"/\1/'); do
    [ "$(grep -c "act:$id " "$BN")" = "0" ] || leak=$((leak+1))
done
assert "none of the 5 applied actions is listed" "0" "$leak"
assert "the 7 unapplied actions are still listed" "7" "$(count '^- \[ \] ' "$BN")"
assert "the Evaluate tool action is still listed" "1" "$(count 'Evaluate tool' "$BN")"
cp -R "$A" "$tmp/C"
node "$TIMELINE" --vault "$tmp/C" --date "$D" >/dev/null 2>&1
CN="$tmp/C/50-Journal/Daily/$D.md"
assert "no Fold or Archive action left once all applied" "0" "$(grep -cE '^- \[ \] (\([0-9]+d\) )?(Fold|Archive) ' "$CN")"
assert "Evaluate tool action still listed" "1" "$(count 'Evaluate tool' "$CN")"
assert "ticket action still listed" "1" "$(count 'File a ticket' "$CN")"
assert "timeline re-run is byte-identical" "$(sha "$CN" | cut -d' ' -f1)" "$(node "$TIMELINE" --vault "$tmp/C" --date "$D" >/dev/null 2>&1; sha "$CN" | cut -d' ' -f1)"

echo "Test group 5: revert"
out="$(node "$APPLY" --vault "$A" --date "$D" --revert "$L" 2>&1)"; rc=$?
assert "revert exits 0" "0" "$rc"
assert "revert restores the pristine vault byte for byte" "" "$(diff -r "$P" "$A" --exclude="$LEDGER_NAME" 2>&1)"
assert "revert reports 10 reverted" "1" "$(printf '%s\n' "$out" | grep -c ' 10 reverted')"
out="$(node "$APPLY" --vault "$A" --date "$D" --revert "$L" 2>&1)"; rc=$?
assert "a second revert exits 0" "0" "$rc"
assert "a second revert changes nothing" "" "$(diff -r "$P" "$A" --exclude="$LEDGER_NAME" 2>&1)"
assert "a second revert reports 10 already reverted" "1" "$(printf '%s\n' "$out" | grep -c ' 10 already-reverted')"

echo "Test group 6: divergence guard"
rm -f "$L"
node "$APPLY" --vault "$A" --date "$D" --apply --limit 50 >/dev/null 2>&1
assert "re-apply after a revert writes 10 ledger lines" "10" "$(lines "$L")"
printf 'hand edit\n' >> "$A/60-Maps/Alpha-MOC.md"
printf 'hand edit\n' >> "$A/Clippings/_evidence/arch-2.md"
out="$(node "$APPLY" --vault "$A" --date "$D" --revert "$L" 2>&1)"; rc=$?
assert "revert exits 3 when it refused something" "3" "$rc"
assert "revert refuses the 2 edited pages" "2" "$(printf '%s\n' "$out" | grep -c '^⊘ .*diverged')"
assert "edited map keeps its hand edit" "1" "$(grep -c 'hand edit' "$A/60-Maps/Alpha-MOC.md")"
assert "edited map keeps the folded links" "1" "$(grep -c 'alpha-3' "$A/60-Maps/Alpha-MOC.md")"
assert "edited clip keeps its stamp" "1" "$(count '^archived: true$' "$A/Clippings/_evidence/arch-2.md")"
assert "untouched map is restored" "" "$(diff "$P/60-Maps/Beta-MOC.md" "$A/60-Maps/Beta-MOC.md")"
assert "untouched CRLF map is restored" "" "$(diff "$P/60-Maps/Gamma-MOC.md" "$A/60-Maps/Gamma-MOC.md")"
assert "untouched clip is restored" "" "$(diff "$P/Clippings/_evidence/arch-1.md" "$A/Clippings/_evidence/arch-1.md")"

echo "Test group 6b: unappliable, unmatched, empty Evidence, --ledger, --dry-run, vanished page"
E="$tmp/E"; cp -R "$P" "$E"
P_SAVED="$P"; P="$E"; mkclip arch-1 "$D0" "" 'archived: false'; P="$P_SAVED"
rm -f "$E/Clippings/_evidence/arch-3.md" "$E/Clippings/_evidence/arch-4.md"
printf -- '---\ntype: moc\ntitle: "Beta MOC"\ntags:\n  - beta\n  - moc\n---\n\n# Beta\n\n## Evidence' > "$E/60-Maps/Beta-MOC.md"
cp -R "$E" "$tmp/E0"
eh="$(tree_hash "$E")"
out="$(node "$APPLY" --vault "$E" --date "$D" --limit 50 --dry-run 2>&1)"
assert "explicit --dry-run prints the 7 appliable actions" "7" "$(printf '%s\n' "$out" | grep -c '^would ')"
assert "explicit --dry-run changes nothing" "$eh" "$(tree_hash "$E")"
CL="$tmp/custom.jsonl"
out="$(node "$APPLY" --vault "$E" --date "$D" --apply --limit 50 --ledger "$CL" 2>&1)"
assert "summary counts 7 applied of 8 eligible" "1" "$(printf '%s\n' "$out" | grep -c ': 7 applied (3 fold, 4 archive) of 8 eligible')"
assert "summary counts the unmatched actions" "1" "$(printf '%s\n' "$out" | grep -c ', 2 unmatched,')"
assert "summary counts the unappliable action" "1" "$(printf '%s\n' "$out" | grep -c ', 1 unappliable')"
assert "the unappliable clip is reported" "1" "$(printf '%s\n' "$out" | grep -c '^⊘ archive .*arch-1')"
assert "--ledger writes the named ledger" "7" "$(lines "$CL")"
assert "--ledger leaves no default ledger" "no" "$([ -e "$E/$LEDGER_NAME" ] && echo yes || echo no)"
assert "a clip with archived: false is left as it was" "" "$(diff "$tmp/E0/Clippings/_evidence/arch-1.md" "$E/Clippings/_evidence/arch-1.md")"
BE="$E/60-Maps/Beta-MOC.md"
assert "empty Evidence at EOF gets the bullets after a blank line" \
    "$(printf -- '---\ntype: moc\ntitle: "Beta MOC"\ntags:\n  - beta\n  - moc\n---\n\n# Beta\n\n## Evidence\n\n- [[Clippings/_evidence/beta-1|Clip beta-1]]\n- [[Clippings/_evidence/beta-2|Clip beta-2]]')" \
    "$(cat "$BE")"
assert "a map with no final newline keeps having none" "]" "$(tail -c1 "$BE")"
rm -f "$E/Clippings/_evidence/arch-2.md"
out="$(node "$APPLY" --vault "$E" --date "$D" --revert "$CL" 2>&1)"; rc=$?
assert "revert exits 0 when a stamped page has vanished" "0" "$rc"
assert "revert reports the vanished page as already-gone" "1" "$(printf '%s\n' "$out" | grep -c ' 1 already-gone')"
assert "revert restores every page that is still there" "" "$(diff -r "$tmp/E0" "$E" --exclude=arch-2.md 2>&1)"
LIB="$PLUGIN_DIR/tools/lib/clip-actions.mjs" node --input-type=module -e \
    'const { stampArchived } = await import(process.env.LIB); console.log(JSON.stringify(stampArchived("body only", "2026-06-28")))' > "$tmp/stamp.out" 2>&1
assert "a clip with no frontmatter is skipped, not stamped" '{"skip":"no frontmatter"}' "$(cat "$tmp/stamp.out")"

echo "Test group 6c: chained folds revert twice, run lock, # heading ends the section"
G="$tmp/G"; cp -R "$P" "$G"
P_SAVED="$P"; P="$G"; mkclip alpha-d "$D" alpha; P="$P_SAVED"
node "$TIMELINE" --vault "$G" --date "$D" >/dev/null 2>&1
cp -R "$G" "$tmp/G0"
node "$APPLY" --vault "$G" --date "$D" --apply --limit 50 >/dev/null 2>&1
GL="$G/$LEDGER_NAME"
assert "11 actions applied, two of them folds into the same map" "2" "$(grep -c '"map":"60-Maps/Alpha-MOC.md"' "$GL")"
assert "the map holds all four alpha links" "4" "$(grep -cE 'alpha-(1|2|3|d)' "$G/60-Maps/Alpha-MOC.md")"
out="$(node "$APPLY" --vault "$G" --date "$D" --revert "$GL" 2>&1)"; rc=$?
assert "reverting the chained folds exits 0" "0" "$rc"
assert "reverting the chained folds restores the vault byte for byte" "" "$(diff -r "$tmp/G0" "$G" --exclude="$LEDGER_NAME" 2>&1)"
out="$(node "$APPLY" --vault "$G" --date "$D" --revert "$GL" 2>&1)"; rc=$?
assert "a second revert of chained folds exits 0, not 3" "0" "$rc"
assert "a second revert of chained folds reports 11 already-reverted" "1" "$(printf '%s\n' "$out" | grep -c ' 0 reverted, 11 already-reverted, 0 refused')"

L2="$tmp/lock-vault"; cp -R "$P" "$L2"
lh="$(tree_hash "$L2")"
mkdir "$L2/.apply-clip-actions.lock"
node "$APPLY" --vault "$L2" --date "$D" --apply --limit 5 >/dev/null 2>&1; assert "--apply under a held lock exits 2" "2" "$?"
node "$APPLY" --vault "$L2" --date "$D" --revert "$GL" >/dev/null 2>&1; assert "--revert under a held lock exits 2" "2" "$?"
assert "a held lock leaves the vault untouched" "$lh" "$(tree_hash "$L2")"
node "$APPLY" --vault "$L2" --date "$D" >/dev/null 2>&1; assert "a dry run ignores the lock" "0" "$?"
assert "the held lock was not removed by the refused runs" "yes" "$([ -d "$L2/.apply-clip-actions.lock" ] && echo yes || echo no)"
rmdir "$L2/.apply-clip-actions.lock"
node "$APPLY" --vault "$L2" --date "$D" --apply --limit 5 >/dev/null 2>&1; assert "--apply with no lock exits 0" "0" "$?"
assert "a finished run releases its lock" "no" "$([ -e "$L2/.apply-clip-actions.lock" ] && echo yes || echo no)"

LIB="$PLUGIN_DIR/tools/lib/clip-actions.mjs" node --input-type=module -e \
    'const { foldContent } = await import(process.env.LIB); process.stdout.write(foldContent("## Evidence\n\n- a\n\n# Next\n\ntext\n", [{ link: "x", title: "X" }]).next)' > "$tmp/fold.out" 2>&1
assert "a level-1 heading ends the Evidence section" \
    "$(printf '## Evidence\n\n- a\n- [[x|X]]\n\n# Next\n\ntext')" "$(cat "$tmp/fold.out")"

echo "Test group 6d: a map hand-edited between two applies is refused on revert, not reported reverted"
H="$tmp/H"; cp -R "$tmp/G0" "$H"
node "$APPLY" --vault "$H" --date "$D" --apply --limit 6 >/dev/null 2>&1
printf 'hand edit between two applies\n' >> "$H/60-Maps/Alpha-MOC.md"
node "$APPLY" --vault "$H" --date "$D" --apply --limit 50 >/dev/null 2>&1
HL="$H/$LEDGER_NAME"
assert "two folds on the edited map, one before and one after the edit" "2" "$(grep -c '"map":"60-Maps/Alpha-MOC.md"' "$HL")"
out="$(node "$APPLY" --vault "$H" --date "$D" --revert "$HL" 2>&1)"; rc=$?
assert "revert exits 3: the earlier fold sits under a hand edit" "3" "$rc"
assert "the earlier fold on the edited map is refused as diverged" "1" "$(printf '%s\n' "$out" | grep -c '^⊘ 60-Maps/Alpha-MOC.md — diverged')"
assert "the earlier fold on the edited map is not reported already reverted" "0" "$(printf '%s\n' "$out" | grep -c '^= 60-Maps/Alpha-MOC.md')"
assert "revert summary counts 10 reverted and 1 refused" "1" "$(printf '%s\n' "$out" | grep -c ': 10 reverted, 0 already-reverted, 1 refused')"
assert "the earlier fold's links are still in the map" "2" "$(grep -cE 'alpha-[23]' "$H/60-Maps/Alpha-MOC.md")"
assert "the hand edit is kept" "1" "$(grep -c 'hand edit between two applies' "$H/60-Maps/Alpha-MOC.md")"
assert "the later fold was reverted" "0" "$(grep -c 'alpha-d' "$H/60-Maps/Alpha-MOC.md")"
assert "every other page is restored" "" "$(diff -r "$tmp/G0" "$H" --exclude="$LEDGER_NAME" --exclude=Alpha-MOC.md 2>&1)"

H2="$tmp/H2"; cp -R "$tmp/G0" "$H2"
node "$APPLY" --vault "$H2" --date "$D" --apply --limit 6 >/dev/null 2>&1
cp "$H2/60-Maps/Alpha-MOC.md" "$tmp/alpha-after-first-apply.md"
printf 'hand edit between two applies\n' >> "$H2/60-Maps/Alpha-MOC.md"
node "$APPLY" --vault "$H2" --date "$D" --apply --limit 50 >/dev/null 2>&1
cp "$tmp/alpha-after-first-apply.md" "$H2/60-Maps/Alpha-MOC.md"
out="$(node "$APPLY" --vault "$H2" --date "$D" --revert "$H2/$LEDGER_NAME" 2>&1)"; rc=$?
assert "a map put back to an older recorded state exits 3" "3" "$rc"
assert "the newer apply on that map is refused" "1" "$(printf '%s\n' "$out" | grep -c '^⊘ 60-Maps/Alpha-MOC.md — diverged since fold')"
assert "the older apply on that map is refused too, once the newer one was" "1" "$(printf '%s\n' "$out" | grep -c 'a newer apply on this page was refused')"
assert "the refused map is left as it was" "" "$(diff "$tmp/alpha-after-first-apply.md" "$H2/60-Maps/Alpha-MOC.md")"

echo "Test group 6e: a restore that cannot reproduce the recorded bytes is refused"
K="$tmp/K"; cp -R "$P" "$K"
kh="$(tree_hash "$K")"
kmap_sha="$(sha "$K/60-Maps/Beta-MOC.md" | cut -d' ' -f1)"
zero64="$(printf '%064d' 0)"
printf '{"action":"fold","map":"60-Maps/Beta-MOC.md","map_sha256_before":"%s","map_sha256":"%s","at":0,"appended":"zzz"}\n' "$zero64" "$kmap_sha" > "$tmp/badslice.jsonl"
out="$(node "$APPLY" --vault "$K" --revert "$tmp/badslice.jsonl" 2>&1)"; rc=$?
assert "a block that is not where the ledger says exits 3" "3" "$rc"
assert "a block that is not where the ledger says is refused" "1" "$(printf '%s\n' "$out" | grep -c 'cannot restore the recorded bytes')"
assert "a refused restore leaves the vault untouched" "$kh" "$(tree_hash "$K")"
printf '{"action":"fold","map":"60-Maps/Beta-MOC.md","map_sha256_before":"%s","map_sha256":"%s","at":0,"appended":"---"}\n' "$zero64" "$kmap_sha" > "$tmp/badhash.jsonl"
out="$(node "$APPLY" --vault "$K" --revert "$tmp/badhash.jsonl" 2>&1)"; rc=$?
assert "a restore that does not hash to the recorded bytes exits 3" "3" "$rc"
assert "a restore that does not hash to the recorded bytes is refused" "1" "$(printf '%s\n' "$out" | grep -c 'cannot restore the recorded bytes')"
assert "that refusal leaves the vault untouched" "$kh" "$(tree_hash "$K")"

echo "Test group 7: arguments"
node "$APPLY" --vault "$A" --date "$D" --limit 0 >/dev/null 2>&1; assert "--limit 0 is refused" "1" "$?"
node "$APPLY" --vault "$A" --date "$D" --limit abc >/dev/null 2>&1; assert "--limit abc is refused" "1" "$?"
node "$APPLY" --date "$D" >/dev/null 2>&1; assert "missing --vault is refused" "1" "$?"
node "$APPLY" --vault "$A" --date 2026-13-40 >/dev/null 2>&1; assert "an impossible --date is refused" "1" "$?"
node "$APPLY" --vault "$A" --date "$D" --revert "$tmp/none.jsonl" >/dev/null 2>&1; assert "a missing ledger is refused" "1" "$?"
printf '{"action":"fold","map":"../escape.md","map_sha256_before":"a","map_sha256":"b","at":0,"appended":"x"}\n' > "$tmp/evil.jsonl"
node "$APPLY" --vault "$A" --revert "$tmp/evil.jsonl" >/dev/null 2>&1; assert "a ledger path escaping the vault is refused" "1" "$?"

echo
echo "apply-clip-actions: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
