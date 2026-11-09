#!/usr/bin/env bash
# shellcheck disable=SC2015,SC2016 # cond && pass || fail: pass and fail always return 0; the fixtures hold literal backticks and the prose holds <placeholders>
# Tests that minerva seals each critic return to the bytes the critic read.
# Usage: bash marketplace/plugins/himmel-ops/scripts/test-minerva-critic-seal.sh
# Exit: 0 all rows pass, 1 a row failed, 2 a missing tool (bun, git, jq, node, python3).
#
# The commands under test are EXTRACTED from minerva's SKILL.md (the checkout block, the core-check
# command, the generator line, the seal command), so the suite cannot drift from the prose. It works
# in a fixture folder and runs send-file with BRIDGE_ROOT on that fixture: nothing reaches Telegram.
# The critic is a canned return file; no model runs here.
set -uo pipefail
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY CLAUDE_PLUGIN_ROOT

REPO_ROOT="$(cd "$(dirname "$0")/../../../.." && pwd -P)"
SKILL="$REPO_ROOT/marketplace/plugins/himmel-ops/skills/minerva/SKILL.md"
CHOKE_HOOK="$REPO_ROOT/scripts/hooks/block-chokepoint-env-prefix.sh"
LITERAL_HOOK="$REPO_ROOT/scripts/hooks/guard-pr-check-literal.sh"
ROUTE="$REPO_ROOT/scripts/telegram/chief-route.ts"
GEN="$REPO_ROOT/scripts/telegram/spec-page-gen.py"
SEALSH="$REPO_ROOT/scripts/handover/chief-kit/critic-seal.sh"

for tool in bun git jq node python3; do
  command -v "$tool" >/dev/null 2>&1 || { echo "FATAL: $tool is needed"; exit 2; }
done
[ -f "$SKILL" ] || { echo "FATAL: $SKILL not found"; exit 2; }

PASS=0 FAIL=0
pass() { printf '  PASS  %s\n' "$1"; PASS=$((PASS+1)); }
fail() { printf '  FAIL  %s\n' "$1"; [ -n "${2:-}" ] && printf '        got: %s\n' "$2"; FAIL=$((FAIL+1)); }
has() { case "$3" in *"$2"*) pass "$1" ;; *) fail "$1" "$3" ;; esac; }
lacks() { case "$3" in *"$2"*) fail "$1" "$3" ;; *) pass "$1" ;; esac; }

T="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/minerva-critic-seal.XXXXXX")" && pwd -P)" || exit 1
trap 'rm -rf "$T"' EXIT

sha() { sha256sum "$1" | cut -d' ' -f1; }
g() { git -c user.name=t -c user.email=t@t -c init.defaultBranch=main -c commit.gpgsign=false "$@"; }

# ---- what the skill says: the four texts, each in its own fence ----
BLOCK="$(awk '/# >>> himmel checkout for the critic seal/{f=1} f{print} /# <<< himmel checkout for the critic seal/{if(f)exit}' "$SKILL")"
line_of() { grep -m1 "^[[:space:]]*$1" "$SKILL" | sed 's/^[[:space:]]*//'; }
CORELINE="$(line_of 'node <himmel>/scripts/jira/dist/index.js release core-check')"
GENLINE="$(line_of 'python3 -I <himmel>/scripts/telegram/spec-page-gen.py')"
SEALLINE="$(line_of 'bash <himmel>/scripts/handover/chief-kit/critic-seal.sh')"

P_PATHS="<the build's paths>"
P_SPECBASE='<spec-file minus .md>'
P_FILE='<file under review>'
PATHS='marketplace/plugins/himmel-ops/skills/minerva/SKILL.md,marketplace/plugins/himmel-ops/.claude-plugin/plugin.json,marketplace/plugins/himmel-ops/scripts/test-minerva-critic-seal.sh,docs/handover/chief-sections/telegram-files.md'
# fill <text> <himmel> <spec> <verdict> <file> <sha>: the placeholders as the spec names them
fill() {
  local t="$1"
  t="${t//'<himmel>'/$2}"; t="${t//"$P_PATHS"/$PATHS}"; t="${t//'<ticket>'/KEY-1}"
  t="${t//"$P_SPECBASE"/${3%.md}}"; t="${t//'<spec-file>'/$3}"
  t="${t//'<verdict-file>'/$4}"; t="${t//"$P_FILE"/$5}"; t="${t//'<sha the critic quoted>'/$6}"
  printf '%s' "$t"
}

# ---- fixtures ----
# newfix <name>: a spec with a diagram, a plan, a decisions folder, a bridge root
newfix() {
  F="$T/$1"; S="$F/specs"; BR="$F/bridge"
  SPEC="$S/designs/x.md"; HTML="$S/designs/x.html"; PLAN="$S/plans/x.md"
  mkdir -p "$S/designs" "$S/plans" "$S/decisions" "$BR"
  printf '# Fixture spec\n\n## Diagrams\n\n```svg\n<svg viewBox="0 0 10 10" xmlns="http://www.w3.org/2000/svg"><rect x="1" y="1" width="8" height="8"/></svg>\n```\n\n## After\n\nText after the diagram.\n' > "$SPEC"
  printf '# Fixture plan\n\n## Task 1\n\nDo it.\n' > "$PLAN"
}
# gen_page [direct]: the page beside the spec, by the extracted generator line, or the generator itself
gen_page() {
  if [ "${1:-}" != direct ] && [ -n "$GENLINE" ]; then
    bash -c "$(fill "$GENLINE" "$REPO_ROOT" "$SPEC" "" "" "")" >/dev/null 2>&1
  else
    python3 -I "$GEN" "$SPEC" "$HTML" >/dev/null 2>&1
  fi
}
# ret <file> <verdict line> <sha> <path> ...: a canned critic return
ret() {
  local file="$1" verdict="$2"; shift 2
  { echo "Canned critic return."; while [ $# -ge 2 ]; do printf 'READ-SHA256 %s %s\n' "$1" "$2"; shift 2; done; printf '\n%s\n' "$verdict"; } > "$file"
}
retspec() { QS_MD="$(sha "$SPEC")"; QS_HTML="$(sha "$HTML")"; ret "$SPEC.critic-spec-r$1.md" "$2" "$QS_MD" "$SPEC" "$QS_HTML" "$HTML"; }
retplan() { QP_PLAN="$(sha "$PLAN")"; QP_SPEC="$(sha "$SPEC")"; ret "$SPEC.critic-plan-r$1.md" "$2" "$QP_PLAN" "$PLAN" "$QP_SPEC" "$SPEC"; }
stub() { printf 'Earlier round.\n\n%s\n' "$2" > "$SPEC.critic-$1.md"; }
# seal1 <verdict> <file> <sha>: the extracted seal command, or the script itself with DIRECT=1. SEALRC 127 when the prose has none.
seal1() {
  if [ "${DIRECT:-}" = 1 ]; then SEALOUT="$(bash "$SEALSH" "$1" "$2" "$3" 2>&1)"; SEALRC=$?
  elif [ -z "$SEALLINE" ]; then SEALOUT="no seal command in SKILL.md"; SEALRC=127
  else SEALOUT="$(bash -c "$(fill "$SEALLINE" "$REPO_ROOT" "$SPEC" "$1" "$2" "$3")" 2>&1)"; SEALRC=$?
  fi
}
sealspec() { seal1 "$SPEC.critic-spec-r$1.md" "$SPEC" "$QS_MD"; seal1 "$SPEC.critic-spec-r$1.md" "$HTML" "$QS_HTML"; }
sealplan() { seal1 "$SPEC.critic-plan-r$1.md" "$PLAN" "$QP_PLAN"; seal1 "$SPEC.critic-plan-r$1.md" "$SPEC" "$QP_SPEC"; }
# send <path>: send-file against the fixture bridge root; QUEUED is the file it queued
send() {
  SOUT="$(BRIDGE_ROOT="$BR" bun "$ROUTE" send-file 1 "$1" 2>&1)"; SRC=$?
  QUEUED=""; [ "$SRC" -eq 0 ] && QUEUED="${SOUT##*queued }"
}
accepted() { send "$2"; [ "$SRC" -eq 0 ] && pass "$1" || fail "$1" "$SOUT"; }
refused() { send "$2"; if [ "$SRC" -ne 0 ]; then has "$1" "$3" "$SOUT"; else fail "$1" "accepted: $SOUT"; fi; }

echo "== a: the seal step leaves one CONTENT-SHA256 line per file, above the verdict line =="
newfix a; gen_page; retspec 1 "SPEC CLEAN"; retplan 1 "PLAN CLEAN"
if [ -z "$SEALLINE" ]; then fail "a: the seal command is in SKILL.md (a bash line starting bash <himmel>/scripts/handover/chief-kit/critic-seal.sh)"; else
  sealspec 1; [ "$SEALRC" -eq 0 ] || fail "a: sealing the spec return" "$SEALOUT"
  sealplan 1; [ "$SEALRC" -eq 0 ] || fail "a: sealing the plan return" "$SEALOUT"
  for r in "$SPEC.critic-spec-r1.md" "$SPEC.critic-plan-r1.md"; do
    n="$(grep -c '^CONTENT-SHA256 ' "$r")"; tail2="$(grep -v '^$' "$r" | tail -n 2 | head -n 1)"; last="$(grep -v '^$' "$r" | tail -n 1)"
    [ "$n" = 2 ] && pass "a: $(basename "$r") has one seal per file" || fail "a: $(basename "$r") has one seal per file" "$n lines"
    case "$tail2:$last" in CONTENT-SHA256\ *:*CLEAN) pass "a: the seals sit just above the verdict line of $(basename "$r")" ;; *) fail "a: the seals sit just above the verdict line of $(basename "$r")" "$tail2 / $last" ;; esac
  done
fi

echo "== b: send-file accepts the .md and the generated .html with no hand seal =="
newfix b; gen_page; retspec 1 "SPEC CLEAN"; retplan 1 "PLAN CLEAN"
[ -n "$GENLINE" ] && pass "b: the generator line is in SKILL.md" || fail "b: the generator line is in SKILL.md (a bash line starting python3 -I <himmel>/scripts/telegram/spec-page-gen.py)"
[ -n "$SEALLINE" ] && { sealspec 1; sealplan 1; } || fail "b: the seal command is in SKILL.md"
accepted "b: the .md is accepted" "$SPEC"
accepted "b: the generated .html is accepted" "$HTML"
[ -n "$QUEUED" ] && [ -f "$QUEUED" ] && pass "b: the fixture outbox holds the page" || fail "b: the fixture outbox holds the page" "${QUEUED:-nothing queued}"

echo "== c: a byte added after the seal is refused, naming the change =="
newfix c; gen_page; retspec 1 "SPEC CLEAN"; retplan 1 "PLAN CLEAN"
[ -n "$SEALLINE" ] && { sealspec 1; sealplan 1; } || fail "c: the seal command is in SKILL.md"
printf 'x' >> "$SPEC"
refused "c: the edited spec is refused, with the hash mismatch message" "$SPEC" "changed since"

echo "== d: control, a return from before this change is refused for having no seal =="
newfix d; gen_page direct; retspec 1 "SPEC CLEAN"; retplan 1 "PLAN CLEAN"
refused "d: no seal line is refused as such, not as a missing plan critic" "$HTML" "has no CONTENT-SHA256"

echo "== e: each extracted text is allowed by both hooks; the refused shapes are denied =="
newfix e
hook() { # hook <script> <command>: HRC, HOUT, HERR
  local payload; payload="$(jq -cn --arg c "$2" --arg d "$REPO_ROOT" '{tool_name:"Bash",tool_input:{command:$c},cwd:$d}')"
  HOUT="$(printf '%s' "$payload" | env -u ENV_PREFIX_GUARD_OK -u CHOKEPOINT_REGISTRY bash "$1" 2>"$T/herr")"; HRC=$?; HERR="$(cat "$T/herr")"
  HDEC="$(printf '%s' "$HOUT" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null || true)"
}
allow() { hook "$2" "$3"; [ "$HRC" -eq 0 ] && [ "$HDEC" != deny ] && pass "$1" || fail "$1" "rc=$HRC decision=$HDEC $HERR"; }
deny() { hook "$2" "$3"; [ "$HRC" -eq 2 ] && pass "$1" || fail "$1" "rc=$HRC decision=$HDEC ${HERR%%$'\n'*}"; }
ESEAL="$(printf '%064d' 0)"
if [ -z "$BLOCK" ] || [ -z "$CORELINE" ] || [ -z "$GENLINE" ] || [ -z "$SEALLINE" ]; then
  fail "e: all four texts are in SKILL.md" "block=${#BLOCK} core=${#CORELINE} gen=${#GENLINE} seal=${#SEALLINE} bytes"
else
  for h in "$CHOKE_HOOK" "$LITERAL_HOOK"; do
    allow "e: the checkout block is allowed by $(basename "$h")" "$h" "$BLOCK"
    allow "e: the core-check command is allowed by $(basename "$h")" "$h" "$(fill "$CORELINE" "$REPO_ROOT" "$SPEC" "" "" "")"
    allow "e: the generator line is allowed by $(basename "$h")" "$h" "$(fill "$GENLINE" "$REPO_ROOT" "$SPEC" "" "" "")"
    allow "e: the seal command is allowed by $(basename "$h")" "$h" "$(fill "$SEALLINE" "$REPO_ROOT" "$SPEC" "$SPEC.critic-spec-r1.md" "$SPEC" "$ESEAL")"
  done
  R4='A="$(node <himmel>/scripts/jira/dist/index.js release core-check --paths <the build'\''s paths> --key <ticket> --core-paths <himmel>/scripts/ci/core-paths.txt 2>&1)"; case "$A" in "NOT-CORE "*) echo "no page: $A" ;; *) echo "page: $A" ;; esac'
  LOOP='H=""; for H in "${HIMMEL_REPO:-}" "$(git rev-parse --show-toplevel 2>/dev/null)" "$HOME/Documents/github/himmel"; do
  [ -f "$H/scripts/handover/chief-kit/critic-seal.sh" ] && { echo "$H"; break; }
done'
  deny "e: the seal by a variable path is denied by the second hook" "$LITERAL_HOOK" "bash \"\$R/scripts/handover/chief-kit/critic-seal.sh\" /s/v /s/x.md $ESEAL"
  deny "e: an env prefix on merge-on-green is denied by the first hook" "$CHOKE_HOOK" "ARMAUTOMERGE=1 bash scripts/handover/merge-on-green.sh"
  deny "e: the r4 decision line is denied by the second hook" "$LITERAL_HOOK" "$(fill "$R4" "$REPO_ROOT" "$SPEC" "" "" "")"
  deny "e: the refused loop is denied by the second hook" "$LITERAL_HOOK" "$LOOP"
fi

echo "== f: the prose carries the steps =="
flat() { tr '\n' ' ' | tr -s ' '; }
STAGE2="$(awk '/^## Stage 2/{f=1;next} /^## /{f=0} f' "$SKILL" | flat)"
STAGE4="$(awk '/^## Stage 4/{f=1;next} /^## /{f=0} f' "$SKILL" | flat)"
for w in 'READ-SHA256' 'bash <himmel>/scripts/handover/chief-kit/critic-seal.sh' 'exactly `NOT-CORE <ticket>`' 'a refused command' 'as an `svg` fence under' 'give the critic no hash yourself' 'write that line by hand'; do
  case "$STAGE2" in *"$w"*) pass "f: Stage 2 holds: $w" ;; *) fail "f: Stage 2 holds: $w" ;; esac
done
for w in 'critic-seal.sh' 'minerva-trace-lint.sh'; do
  case "$STAGE4" in *"$w"*) pass "f: Stage 4 names $w" ;; *) fail "f: Stage 4 names $w" ;; esac
done

echo "== g: a return with no quoted sha is refused and the file is unchanged =="
newfix g; gen_page; QS_MD="$(sha "$SPEC")"; QS_HTML="$(sha "$HTML")"
ret "$SPEC.critic-spec-r1.md" "SPEC CLEAN"
cp "$SPEC.critic-spec-r1.md" "$T/g-before"
seal1 "$SPEC.critic-spec-r1.md" "$SPEC" "$QS_MD"
if [ "$SEALRC" -eq 127 ]; then fail "g: the seal command is in SKILL.md"; else
  [ "$SEALRC" -ne 0 ] && pass "g: the seal step is refused" || fail "g: the seal step is refused" "rc=$SEALRC"
  has "g: the refusal says the return does not quote it" "does not quote" "$SEALOUT"
fi
cmp -s "$T/g-before" "$SPEC.critic-spec-r1.md" && pass "g: the return is unchanged" || fail "g: the return is unchanged"

echo "== h: control, a partial seal passes for the file sealed (the ceiling) =="
newfix h; gen_page direct; retspec 1 "SPEC CLEAN"; retplan 1 "PLAN CLEAN"
DIRECT=1 seal1 "$SPEC.critic-spec-r1.md" "$SPEC" "$QS_MD"
DIRECT=1 seal1 "$SPEC.critic-plan-r1.md" "$PLAN" "$QP_PLAN"
accepted "h: the .md is accepted" "$SPEC"
accepted "h: the plan is accepted" "$PLAN"
refused "h: the .html, sealed by no critic, is refused" "$HTML" "has no seal for the bytes"

echo "== i: the checkout block prints the primary checkout in every branch =="
PRIM="$T/prim"; WT="$T/wt"; OUT="$T/outside"; HOMEFX="$T/home"; EMPTYHOME="$T/emptyhome"
mkdir -p "$PRIM/scripts/lib" "$PRIM/scripts/ci" "$OUT" "$HOMEFX/Documents/github/himmel/scripts/lib" "$EMPTYHOME"
: > "$PRIM/scripts/lib/initiative-workers.sh"; echo 'x' > "$PRIM/scripts/ci/core-paths.txt"; : > "$HOMEFX/Documents/github/himmel/scripts/lib/initiative-workers.sh"
g init -q "$PRIM"; g -C "$PRIM" add -A; g -C "$PRIM" commit -qm base; g -C "$PRIM" worktree add -q -b wt "$WT"
blockrun() { # blockrun <cwd> <HOME> [HIMMEL_REPO]: what the block prints
  ( cd "$1" && GIT_CEILING_DIRECTORIES="$T" HOME="$2" env -u HIMMEL_REPO ${3:+HIMMEL_REPO="$3"} bash -c "$BLOCK" 2>/dev/null )
}
if [ -z "$BLOCK" ]; then fail "i: the checkout block is in SKILL.md (markers # >>> / # <<< himmel checkout for the critic seal)"; else
  [ "$(blockrun "$OUT" "$EMPTYHOME" "$PRIM")" = "$PRIM" ] && pass "i: HIMMEL_REPO set: the primary" || fail "i: HIMMEL_REPO set: the primary" "$(blockrun "$OUT" "$EMPTYHOME" "$PRIM")"
  [ "$(blockrun "$PRIM" "$EMPTYHOME")" = "$PRIM" ] && pass "i: unset, in the primary: the primary" || fail "i: unset, in the primary: the primary" "$(blockrun "$PRIM" "$EMPTYHOME")"
  [ "$(blockrun "$WT" "$EMPTYHOME")" = "$PRIM" ] && pass "i: unset, in a worktree: the primary, not the worktree" || fail "i: unset, in a worktree: the primary, not the worktree" "$(blockrun "$WT" "$EMPTYHOME")"
  [ "$(blockrun "$OUT" "$HOMEFX")" = "$HOMEFX/Documents/github/himmel" ] && pass "i: unset, outside any checkout, HOME holds one: that one" || fail "i: unset, outside any checkout, HOME holds one: that one" "$(blockrun "$OUT" "$HOMEFX")"
  [ -z "$(blockrun "$OUT" "$EMPTYHOME")" ] && pass "i: no checkout anywhere: nothing" || fail "i: no checkout anywhere: nothing" "$(blockrun "$OUT" "$EMPTYHOME")"
fi

echo "== j: at the cap =="
newfix j; gen_page; stub spec-r1 "SPEC FINDINGS 1"; stub spec-r2 "SPEC FINDINGS 1"; retspec 3 "SPEC FINDINGS 1"
if [ -z "$SEALLINE" ]; then fail "j: the seal command is in SKILL.md"; else
  sealspec 3
  refused "j: spec r3 FINDINGS, no plan critic file: refused" "$HTML" "no plan critic file"
  retplan 1 "PLAN FINDINGS 1"; sealplan 1
  refused "j: plan r1 FINDINGS: refused" "$HTML" "not 'PLAN CLEAN'"
  retplan 2 "PLAN CLEAN"; sealplan 2
  accepted "j: plan r2 CLEAN: accepted" "$HTML"
  has "j: it opens with the findings block" 'open-findings' "$(cat "$QUEUED" 2>/dev/null)"
  retplan 3 "PLAN FINDINGS 1"; sealplan 3
  accepted "j: plan r3 FINDINGS: accepted" "$HTML"
  newfix j2; gen_page; stub spec-r1 "SPEC FINDINGS 1"; stub spec-r2 "SPEC FINDINGS 1"; retspec 3 "SPEC CLEAN"; sealspec 3; retplan 1 "PLAN CLEAN"; sealplan 1
  accepted "j: spec r3 CLEAN: accepted" "$HTML"
  lacks "j: with no findings block" 'open-findings' "$(cat "$QUEUED" 2>/dev/null)"
fi

echo "== k: an edited spec, the plan critic's seal, and operator records =="
newfix k; gen_page; retspec 1 "SPEC CLEAN"; retplan 1 "PLAN CLEAN"
if [ -z "$SEALLINE" ]; then fail "k: the seal command is in SKILL.md"; else
  sealspec 1; sealplan 1
  printf '\nAn edit.\n' >> "$SPEC"; gen_page; retspec 2 "SPEC CLEAN"; sealspec 2
  refused "k: the spec critic re-read it, the plan critic's seal holds: refused naming the plan critic" "$HTML" "changed since the plan critic read it"
  ret "$SPEC.critic-plan-r1.md" "PLAN CLEAN" "$QP_PLAN" "$PLAN"; seal1 "$SPEC.critic-plan-r1.md" "$PLAN" "$QP_PLAN"
  accepted "k: no spec seal on the plan return: accepted (the ceiling)" "$HTML"
  newfix k2; gen_page; stub spec-r1 "SPEC FINDINGS 1"; stub spec-r2 "SPEC FINDINGS 1"; retspec 3 "SPEC CLEAN"; sealspec 3
  stub plan-r1 "PLAN FINDINGS 1"; retplan 2 "PLAN CLEAN"; sealplan 2
  cp "$SPEC" "$T/k-spec-bytes"
  accepted "k: at the cap, unedited: accepted" "$HTML"
  printf 'x' >> "$SPEC"
  refused "k: at the cap, an edit: refused" "$HTML" "changed since the spec critic read it"
  cp "$T/k-spec-bytes" "$SPEC"
  accepted "k: the sealed bytes put back: accepted" "$HTML"
  newfix k3; gen_page; for r in 1 2 3; do stub spec-r$r "SPEC FINDINGS 1"; stub plan-r$r "PLAN FINDINGS 1"; done
  retspec 4 "SPEC CLEAN"; sealspec 4
  [ "$SEALRC" -ne 0 ] && has "k: round 4 with no operator record: the seal is refused, naming the record" "needs an operator record" "$SEALOUT" || fail "k: round 4 with no operator record: the seal is refused" "$SEALOUT"
  printf 'decision 7\n' > "$SPEC.operator-round-r4.md"; printf 'verbatim\n' > "$S/decisions/verbatim-decision-7-x.txt"
  sealspec 4; [ "$SEALRC" -eq 0 ] && pass "k: with a record: the spec return is sealed" || fail "k: with a record: the spec return is sealed" "$SEALOUT"
  retplan 4 "PLAN CLEAN"; sealplan 4; [ "$SEALRC" -eq 0 ] && pass "k: the same record serves the plan critic" || fail "k: the same record serves the plan critic" "$SEALOUT"
  accepted "k: both critics at r4 under one record: accepted" "$HTML"
fi

echo "== l: the core-check command reaches the primary's CLI from a worktree =="
CANNED="$T/canned.txt"; mkdir -p "$PRIM/scripts/jira/dist"
printf 'process.stdout.write(require("fs").readFileSync(%s, "utf8"));\n' "$(printf '%s' "$CANNED" | jq -Rs .)" > "$PRIM/scripts/jira/dist/index.js"
if [ -z "$BLOCK" ] || [ -z "$CORELINE" ]; then fail "l: the checkout block and the core-check command are in SKILL.md"; else
  lrun() { ( cd "$WT" && GIT_CEILING_DIRECTORIES="$T" HOME="$EMPTYHOME" env -u HIMMEL_REPO bash -c "$(fill "$CORELINE" "$(blockrun "$WT" "$EMPTYHOME")" "$SPEC" "" "" "")" 2>&1 ); }
  for ans in CORE UNKNOWN REVIEW BYPASS NOT-CORE; do
    printf 'a line before the answer\n%s KEY-1 some/path\n' "$ans" > "$CANNED"
    got="$(lrun)"; [ "${got##*$'\n'}" = "$ans KEY-1 some/path" ] && pass "l: $ans is the last output line" || fail "l: $ans is the last output line" "$got"
  done
  rm -f "$PRIM/scripts/jira/dist/index.js"; printf 'NOT-CORE KEY-1\n' > "$CANNED"
  got="$(lrun)"
  has "l: with the fake removed, node's module error" "Cannot find module" "$got"
  lacks "l: with the fake removed, no NOT-CORE answer" "NOT-CORE KEY-1" "$got"
fi

echo
printf 'passed=%d failed=%d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
