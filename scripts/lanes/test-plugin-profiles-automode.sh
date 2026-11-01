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
# HANDOVER. Columns: classifier tag | command head | the text the trust entries
# must hold for that shape (ANCHOR = this tree's primary checkout). The
# quiet-run row runs worktree bytes, so its expected text is the carve-out that
# leaves the wrapped command to the classifier, not a grant.
cat >"$TMP/refused.tsv" <<'E'
Instruction Poisoning	bash ANCHOR/scripts/handover/chief-kit/append-results.sh HANDOVER	ANCHOR/scripts/handover/chief-kit/append-results.sh
Code from External	bash scripts/quiet-run.sh suite -- bash marketplace/plugins/	the quiet-run.sh argv after --
Code from External	/usr/bin/git push origin fix/himmel-8288-	npm ci --ignore-scripts
Interfere With Workloads	python ANCHOR/scripts/lib/vm	ANCHOR/scripts/lib/vmsdk.py
E
TEXT=$(jq -r '((.autoMode.environment // []) + (.autoMode.allow // []))[]' "$TMP/impl.json" 2>/dev/null)
while IFS="$(printf '\t')" read -r tag head needle; do
    needle="${needle//ANCHOR/$ANCHOR}"
    case "$TEXT" in
        *"$needle"*) ok "T1 $tag shape is named in the trust text ($needle) for: $head" ;;
        *) bad "T1 $tag shape is not named in the trust text ($needle) for: $head" ;;
    esac
done <"$TMP/refused.tsv"
jq -e '.autoMode.allow[0] == "$defaults" and .autoMode.environment[0] == "$defaults"' "$TMP/impl.json" >/dev/null 2>&1 \
    && ok "T1 both lists keep the classifier defaults first" || bad "T1 \$defaults missing from environment or allow"

# T2: no hard deny is removed or overridden. The deny list is the registry's,
# the generated file carries no soft_deny / hard_deny / permission-mode key,
# no entry is a blanket allow, and the paths named are exactly the expected
# anchor-absolute scripts (a tree, a relative path or an added script fails).
WANT=$(jq -c '.profiles["worker-impl"].denyTools' "$HERE/plugin-profiles.json")
GOT=$(jq -c '.permissions.deny' "$TMP/impl.json")
jq -e 'type == "array" and length > 0' <<<"$WANT" >/dev/null 2>&1 && [ "$WANT" = "$GOT" ] && ok "T2 permissions.deny is the registry's worker-impl list" || bad "T2 deny drifted: want $WANT got $GOT"
jq -e '(.autoMode | type == "object") and ((.autoMode | has("hard_deny") or has("soft_deny")) | not) and (((.permissions // {}) | has("defaultMode")) | not) and (has("defaultMode") | not)' "$TMP/impl.json" >/dev/null 2>&1 \
    && ok "T2 no hard_deny / soft_deny / permission-mode key" || bad "T2 the settings set hard_deny, soft_deny or a permission mode, or could not be read"
grep -Eiq 'bypass|any command|all commands|all scripts|all of scripts|everything|reviewed' <<<"$TEXT"; rc=$?
[ -n "$TEXT" ] && [ "$rc" = 1 ] && ok "T2 no trust entry reads as a blanket allow" || bad "T2 a trust entry reads as a blanket allow (grep rc=$rc)"
TOOLING=$(jq -r '((.autoMode.environment // []) + (.autoMode.allow // []))[] | select(startswith("Source control:") | not)' "$TMP/impl.json" 2>/dev/null)
GOT_PATHS=$(grep -oE '[A-Za-z0-9._/-]*/[A-Za-z0-9._/-]*' <<<"$TOOLING" | sed 's/\.$//' | sort -u)
WANT_PATHS=$(printf '%s\n' /tmp "$ANCHOR/.claude/worktrees/" "$ANCHOR/marketplace/plugins/himmel-bus/bin/bus" \
    "$ANCHOR/scripts/check-ci.sh" "$ANCHOR/scripts/handover/chief-kit/append-results.sh" "$ANCHOR/scripts/lib/vmsdk.py" \
    "$ANCHOR/scripts/quiet-run.sh" "$ANCHOR/scripts/vm/guest-exec.sh" "$ANCHOR/scripts/vm/vm-lock.sh" \
    "$ANCHOR/scripts/vm/claudex-guest.sh" | sort -u)
[ -n "$GOT_PATHS" ] && [ "$GOT_PATHS" = "$WANT_PATHS" ] && ok "T2 the trust text names exactly the expected anchor-absolute paths" \
    || bad "T2 named paths drifted: got [$(printf '%s' "$GOT_PATHS" | tr '\n' ' ')]"
jq -e '[.autoMode.environment[] | select(startswith("Trusted repo tooling:"))] | length == 1 and all(test("Not covered:.*GO, verdict and merge scripts.*push wrappers.*settings writers.*secrets helpers.*worktree.*branch changed"))' "$TMP/impl.json" >/dev/null 2>&1 \
    && ok "T2 the tooling entry excludes GO, verdict, merge, push, settings and secrets scripts, worktree copies and branch-changed files" \
    || bad "T2 the tooling entry's Not covered clause misses a required exclusion"
jq -e '[.autoMode.environment[] | select(. != "$defaults" and (startswith("Source control:") | not))] | length > 0 and all(contains("Not covered:"))' "$TMP/impl.json" >/dev/null 2>&1 \
    && ok "T2 every tooling entry states what is not covered" || bad "T2 a tooling entry has no Not covered clause"
# A trusted wrapper's payload is never covered: quiet-run's argv after --, an
# env-named script, an env prefix. Nor are a vmsdk.py clone (it reads the
# token), a non-handover vmsdk.py push, or a bus send claiming a GO or token.
jq -e '([.autoMode.environment[] | select(startswith("Trusted repo tooling:"))] | length == 1 and all(test("Not covered:.*secrets reader.*bus send that claims a GO.*quiet-run.sh argv after --, which is judged on its own.*TICKET_STATUS_FUNNEL, HIMMEL_VMSDK or BASH_ENV, and any call with an environment variable prefix")))
    and ([.autoMode.environment[] | select(startswith("Test VMs:"))] | length == 1 and all(test("Not covered:.*push of a host file other than a handover doc")))
    and ([.autoMode.allow[] | select(startswith("Running one of the exact scripts"))] | length == 1 and all(test("with no environment variable prefix, is not Code from External.*does not cover the command that script runs.*quiet-run.sh argv after --.*TICKET_STATUS_FUNNEL, HIMMEL_VMSDK or BASH_ENV.*judged on its own")))' "$TMP/impl.json" >/dev/null 2>&1 \
    && ok "T2 the exact-scripts exception leaves a wrapper's payload, env-named scripts and env prefixes to the classifier" \
    || bad "T2 the exact-scripts exception or a Not covered clause misses the payload, env-prefix, secrets-reader, push or bus-claim carve-out"
# Pin the whole tooling text (anchor written as ANCHOR): a widening in prose
# with no path in it changes the digest. A deliberate wording change re-pins here.
PIN=$(jq -r --arg a "$ANCHOR" '((.autoMode.environment // []) + (.autoMode.allow // []))[] | select(startswith("Source control:") | not) | split($a) | join("ANCHOR")' "$TMP/impl.json" 2>/dev/null | git hash-object --stdin)
[ "$PIN" = "b01fbd0e6170de4e2702db4e14acc778fc4ce343" ] && ok "T2 the tooling trust text matches its pinned digest" \
    || bad "T2 the tooling trust text changed (digest $PIN): re-read it for a widening, then re-pin"

# T3: a composed profile list carries the allow entries once.
gen worker-impl,code-ui >"$TMP/composed.json"; rc=$?
[ "$rc" = 0 ] && jq -e '([.autoMode.allow[] | select(. == "$defaults")] | length) == 1 and (.autoMode.allow | length) == ([.autoMode.allow[]] | unique | length) and (.autoMode.allow | length) > 1' "$TMP/composed.json" >/dev/null 2>&1 \
    && ok "T3 a composed list unions autoMode.allow once" || bad "T3 composed autoMode.allow wrong (rc=$rc)"

[ "$FAILED" = 0 ] && { echo "ALL PASS"; exit 0; }
echo "$FAILED FAILED"; exit 1
