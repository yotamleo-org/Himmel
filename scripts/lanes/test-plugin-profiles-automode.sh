#!/usr/bin/env bash
# test-plugin-profiles-automode.sh -- the worker --settings file that
# plugin-profiles.mjs generates declares himmel's own tooling to the auto-mode
# classifier (autoMode.environment / autoMode.allow), so a worker whose brief
# is a tool result is not refused for running it. Hard denies stay in force.
# Scratch HOME only; never reads or writes the station's settings.
# Usage: bash scripts/lanes/test-plugin-profiles-automode.sh   (bash 3.2-safe)
# shellcheck disable=SC2015  # ok() cannot fail; A && ok || bad is the intended guard
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd -P)"
ROOT="$(cd "$HERE/../.." && pwd -P)"
CLI="$HERE/plugin-profiles.mjs"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/pp-automode.XXXXXX") && [ -d "$TMP" ] || { echo "FAIL mktemp"; exit 1; }
trap 'rm -rf "$TMP"' EXIT
FAILED=0
ok() { echo "PASS $1"; }
bad() { echo "FAIL $1"; FAILED=$((FAILED + 1)); }

# The anchor the CLI names: the primary checkout behind this tree.
COMMON=$(git -C "$ROOT" rev-parse --path-format=absolute --git-common-dir)
ANCHOR="${COMMON%/.git}"

gen() { # $1 = profile; prints the generated settings JSON
    (cd "$ROOT" && env -u HIMMEL_REPO -u CLAUDE_CONFIG_DIR HOME="$TMP" USERPROFILE="$TMP" \
        PLUGIN_PROFILES_ADAPTERS="$ROOT/scripts/guardrails/himmel-adapters.json" node "$CLI" "$1")
}
gen worker-impl >"$TMP/impl.json"; rc=$?
[ "$rc" = 0 ] && ok "T0 worker-impl settings generate (rc=0)" || bad "T0 rc=$rc"

# T1 fixture: refused command heads copied from the station's
# ~/.himmel/state/classifier-denials.jsonl (the 2026-10-27..31 census rows),
# with the station checkout path written as ANCHOR and the handover root as
# HANDOVER. Columns: classifier tag | command head | the himmel tool the trust
# text must name for that shape.
cat >"$TMP/refused.tsv" <<'E'
Instruction Poisoning	bash ANCHOR/scripts/handover/chief-kit/append-results.sh HANDOVER	scripts/handover/chief-kit/append-results.sh
Code from External	bash scripts/quiet-run.sh suite -- bash marketplace/plugins/	scripts/quiet-run.sh
Code from External	/usr/bin/git push origin fix/himmel-8288-	npm ci --ignore-scripts
Interfere With Workloads	python ANCHOR/scripts/lib/vm	himmel-ar-
E
TEXT=$(jq -r '((.autoMode.environment // []) + (.autoMode.allow // []))[]' "$TMP/impl.json" 2>/dev/null)
while IFS="$(printf '\t')" read -r tag head needle; do
    case "$TEXT" in
        *"$needle"*) ok "T1 $tag shape is named in the trust text ($needle) for: $head" ;;
        *) bad "T1 $tag shape is not named in the trust text ($needle) for: $head" ;;
    esac
done <"$TMP/refused.tsv"
case "$TEXT" in
    *"$ANCHOR/scripts/"*) ok "T1 the trust text names the anchor's absolute scripts path" ;;
    *) bad "T1 the trust text does not name $ANCHOR/scripts/" ;;
esac
jq -e '.autoMode.allow[0] == "$defaults" and .autoMode.environment[0] == "$defaults"' "$TMP/impl.json" >/dev/null 2>&1 \
    && ok "T1 both lists keep the classifier defaults first" || bad "T1 \$defaults missing from environment or allow"

# T2: no hard deny is removed or overridden. The deny list is the registry's,
# the generated file carries no soft_deny / hard_deny / permission-mode key,
# and no entry is a blanket allow.
WANT=$(jq -c '.profiles["worker-impl"].denyTools' "$HERE/plugin-profiles.json")
GOT=$(jq -c '.permissions.deny' "$TMP/impl.json")
[ -n "$WANT" ] && [ "$WANT" = "$GOT" ] && ok "T2 permissions.deny is the registry's worker-impl list" || bad "T2 deny drifted: want $WANT got $GOT"
jq -e '(.autoMode | has("hard_deny") or has("soft_deny")) or (.permissions | has("defaultMode")) or has("defaultMode")' "$TMP/impl.json" >/dev/null 2>&1 \
    && bad "T2 the settings set hard_deny, soft_deny or a permission mode" || ok "T2 no hard_deny / soft_deny / permission-mode key"
if printf '%s\n' "$TEXT" | grep -Eiq 'bypass|any command|all commands|all scripts|everything'; then
    bad "T2 a trust entry reads as a blanket allow"
else ok "T2 no trust entry reads as a blanket allow"; fi
printf '%s\n' "$TEXT" | grep -q 'Not covered:' && ok "T2 the tooling entries state what is not covered" || bad "T2 no Not covered clause"

# T3: a composed profile list carries the allow entries once.
gen worker-impl,code-ui >"$TMP/composed.json"; rc=$?
[ "$rc" = 0 ] && jq -e '([.autoMode.allow[] | select(. == "$defaults")] | length) == 1 and (.autoMode.allow | length) == ([.autoMode.allow[]] | unique | length) and (.autoMode.allow | length) > 1' "$TMP/composed.json" >/dev/null 2>&1 \
    && ok "T3 a composed list unions autoMode.allow once" || bad "T3 composed autoMode.allow wrong (rc=$rc)"

[ "$FAILED" = 0 ] && { echo "ALL PASS"; exit 0; }
echo "$FAILED FAILED"; exit 1
