#!/usr/bin/env bash
# shellcheck disable=SC2015
# test-minerva-spec-gate.sh — minerva-spec-gate.sh refuses the
# Stage-2 spec critic unless the spec carries an estimate record (effort-assess
# output that passed its DoD), an Alternatives section and a Definition-of-done
# section. Fixtures: one missing each, then a filled one that passes.
set -u
here="$(cd "$(dirname "$0")" && pwd)"
gate="$here/minerva-spec-gate.sh"
tool="$here/../skills/effort-assess/effort_assess.py"
td="$(mktemp -d "${TMPDIR:-/tmp}/minerva-gate.XXXXXX")" || { echo "FAIL - mktemp"; exit 1; }
trap 'rm -rf "$td"' EXIT
fails=0
ok(){ echo "ok - $1"; }
bad(){ echo "FAIL - $1"; fails=$((fails+1)); }

python3 "$tool" ticket --low S --high S --g1 no --deps none --scope-file a.sh --red r --goal G2 --alternative x >"$td/est.json" 2>/dev/null
# a refused estimate: no RED, so dod.passed is false (the tool exits 1 but still prints the record)
python3 "$tool" ticket --low S --high S --g1 no --deps none --scope-file a.sh >"$td/refused.json" 2>/dev/null

mkspec(){ # <file> <estimate line or -> <alt yes|no> <dod yes|no>
  { echo "# Spec"; echo
    [ "$2" = "-" ] || echo "$2"
    echo; echo "## Problem"; echo "text"; echo
    echo "## Alternatives considered"; [ "$3" = yes ] && { echo "1. keep the midpoint"; echo "2. variant A"; }; echo
    echo "## Definition of done"; [ "$4" = yes ] && echo "- gate fires on a bare spec, passes when filled"; echo
    echo "## ASSUMPTIONS"; echo "- none"
  } >"$1"
}

expect_refuse(){ # <label> <needle> <spec>
  local out rc
  out="$(bash "$gate" "$3" 2>&1)"; rc=$?
  [ "$rc" -ne 0 ] && ok "$1: non-zero exit" || bad "$1: expected non-zero exit"
  case "$out" in *"$2"*) ok "$1: names $2";; *) bad "$1: output lacks [$2]: $out";; esac
}

# RED fixtures: each missing exactly one requirement
mkspec "$td/no-est.md" - yes yes;                                    expect_refuse "no estimate record" "estimate" "$td/no-est.md"
mkspec "$td/dangling.md" "Estimate record: $td/nope.json" yes yes;   expect_refuse "estimate file missing" "estimate" "$td/dangling.md"
mkspec "$td/refused.md" "Estimate record: $td/refused.json" yes yes; expect_refuse "estimate refused by DoD" "estimate" "$td/refused.md"
mkspec "$td/no-alt.md" "Estimate record: $td/est.json" no yes;       expect_refuse "no alternatives" "alternatives" "$td/no-alt.md"
mkspec "$td/no-dod.md" "Estimate record: $td/est.json" yes no;       expect_refuse "no DoD" "definition of done" "$td/no-dod.md"
expect_refuse "missing spec file" "spec" "$td/absent.md"

# the filled fixture passes (absolute path, then a path relative to the spec)
mkspec "$td/good.md" "Estimate record: $td/est.json" yes yes
bash "$gate" "$td/good.md" >/dev/null 2>&1 && ok "filled spec passes (absolute record)" || bad "filled spec should pass"
mkspec "$td/rel.md" "Estimate record: est.json" yes yes
bash "$gate" "$td/rel.md" >/dev/null 2>&1 && ok "filled spec passes (record relative to spec)" || bad "relative record should pass"

# exact heading text, and a section ends at ANY H1 or H2
mkspec_raw(){ # <file> <alt heading> <dod heading>; both sections get a body
  { echo "# Spec"; echo; echo "Estimate record: $td/est.json"; echo
    echo "$2"; echo "- body"; echo
    echo "$3"; echo "- body"; echo
  } >"$1"
}
mkspec_raw "$td/prefix-alt.md" "## Alternatives-not-considered" "## Definition of done"
expect_refuse "prefix-only alternatives heading" "alternatives" "$td/prefix-alt.md"
mkspec_raw "$td/prefix-dod.md" "## Alternatives considered" "## Definition of done later"
expect_refuse "prefix-only DoD heading" "definition of done" "$td/prefix-dod.md"
{ echo "# Spec"; echo; echo "Estimate record: $td/est.json"; echo
  echo "## Alternatives considered"; echo; echo "# Notes"; echo "belongs to the H1, not to alternatives"; echo
  echo "## Definition of done"; echo "- ok"; } >"$td/h1-end.md"
expect_refuse "H1 ends the alternatives section" "alternatives" "$td/h1-end.md"
mkspec_raw "$td/mixed-case.md" "## alternatives CONSIDERED" "## Definition Of Done  "
bash "$gate" "$td/mixed-case.md" >/dev/null 2>&1 && ok "case and trailing space tolerated" || bad "case/trailing-space heading should pass"

# brainstorming (superpowers 7.x) names the same section "Approaches"
mkspec_raw "$td/approaches.md" "## Approaches" "## Definition of done"
bash "$gate" "$td/approaches.md" >/dev/null 2>&1 && ok "## Approaches counts as the alternatives section" || bad "## Approaches should pass as the alternatives section"
{ echo "# Spec"; echo; echo "Estimate record: $td/est.json"; echo
  echo "## Approaches"; echo
  echo "## Definition of done"; echo "- ok"; } >"$td/empty-approaches.md"
expect_refuse "empty ## Approaches" "alternatives" "$td/empty-approaches.md"
mkspec_raw "$td/approaches-considered.md" "## Approaches considered" "## Definition of done"
expect_refuse "prefix-only ## Approaches heading" "alternatives" "$td/approaches-considered.md"

repo="$(cd "$here/../../../.." && pwd)"; export HIMMEL_REPO="$repo"
if ! command -v bun >/dev/null 2>&1 || [ ! -f "$repo/scripts/telegram/chief-route.ts" ]; then
  echo "SKIP: sign-shape rows need bun and chief-route.ts"; exit 1
fi
mkshape(){
  local f="$1" fm="$2"; shift 2
  { [ "$fm" = "-" ] || printf -- '---\n%s\n---\n' "$fm"
    echo "# Spec"; echo; echo "Estimate record: $td/est.json"; echo
    echo "## Alternatives considered"; echo "1. keep it"; echo
    echo "## Definition of done"; echo "- the gate runs sign-shape"; echo
    echo "## Critic rounds"; echo
    for l in "$@"; do echo "$l"; done; echo
    echo "## Next"; echo "- none"
  } >"$f"
}
expect_shape_refuse(){
  local out rc label="$1" needle="$2" spec="$3"; shift 3
  out="$(env "$@" bash "$gate" "$spec" 2>&1)"; rc=$?
  [ "$rc" -ne 0 ] && ok "$label: non-zero exit" || bad "$label: expected non-zero exit"
  case "$out" in *"SIGN-SHAPE REFUSED"*"$needle"*) ok "$label: names $needle";; *) bad "$label: output lacks a SIGN-SHAPE REFUSED line with [$needle]: $out";; esac
  case "$out" in *"NOTE: sign-shape not run"*) bad "$label: refused without running sign-shape";; esac
}
mkshape "$td/HIMMEL-1-g1.md" "tickets: HIMMEL-1" "- R1: F1, F2 fixed"
expect_shape_refuse "G-R1 id-list line" "R1: F1, F2 fixed" "$td/HIMMEL-1-g1.md"
rel=HIMMEL-2
mkshape "$td/HIMMEL-1-g2.md" "tickets: HIMMEL-1 (Relates: $rel)" "- R1-F1: fixed"
expect_shape_refuse "G-R2 key-shaped tickets annotation" "tickets line" "$td/HIMMEL-1-g2.md"
mkshape "$td/HIMMEL-1-g3.md" "tickets: HIMMEL-1" "- R1-F1: fixed"; g3="$td/HIMMEL-1-g3.md"
out="$(bash "$gate" "$g3" 2>&1)" && ok "G-R3 bare tickets line and a qualified line pass" || bad "G-R3 should pass: $out"
out_dir="$td/outside"; mkdir -p "$out_dir/empty" "$out_dir/stub/scripts/telegram" "$out_dir/stub/scripts/lib"
cp "$gate" "$out_dir/gate.sh"
out="$(HIMMEL_REPO="$out_dir/empty" bash "$out_dir/gate.sh" "$g3" 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && case "$out" in *"NOTE: sign-shape not run"*) true;; *) false;; esac \
  && ok "G-R4 no checkout: NOTE and pass" || bad "G-R4 expected a NOTE and exit 0 (rc=$rc): $out"
printf '%s\n' 'console.error("usage: bun chief-route.ts <verb>"); process.exit(1);' >"$out_dir/stub/scripts/telegram/chief-route.ts"
: >"$out_dir/stub/scripts/lib/initiative-workers.sh"
out="$(HIMMEL_REPO="$out_dir/stub" bash "$out_dir/gate.sh" "$g3" 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && case "$out" in *"NOTE: sign-shape not run"*) true;; *) false;; esac \
  && ok "G-R5 verb absent: NOTE and pass" || bad "G-R5 expected a NOTE and exit 0 (rc=$rc): $out"
mkdir -p "$td/specs/plans"; printf -- '---\ntickets: HIMMEL-1 (Relates: HIMMEL-2)\n---\n# Plan\n' >"$td/specs/plans/HIMMEL-1-plan.md"
mkshape "$td/HIMMEL-1-g6.md" "tickets: HIMMEL-1
plan: specs/plans/HIMMEL-1-plan.md (r2)" "- R1-F1: fixed"
expect_shape_refuse "G-R6 the named plan's tickets line" "HIMMEL-1-plan.md" "$td/HIMMEL-1-g6.md"
{ printf -- '---\ntickets: HIMMEL-1\n---\nKey: HIMMEL-2\n'; sed 1,3d "$td/HIMMEL-1-g3.md"; } >"$td/HIMMEL-1-g7.md"
expect_shape_refuse "G-R7 Key header disagrees with tickets" "HIMMEL-1-g7.md" "$td/HIMMEL-1-g7.md"
mkshape "$td/HIMMEL-1-g8.md" "tickets: HIMMEL-1" "- R1-F1: fixed" "- R1-F1x: deferred → later"
expect_shape_refuse "G-R8 near-miss at the highest round" "R1-F1x: deferred → later" "$td/HIMMEL-1-g8.md"

[ "$fails" -eq 0 ] && { echo "ALL PASS"; exit 0; } || { echo "$fails FAILED"; exit 1; }
