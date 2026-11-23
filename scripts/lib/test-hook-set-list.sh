#!/usr/bin/env bash
# shellcheck disable=SC2015
# test-hook-set-list.sh -- the hook-set list in wire-pretooluse-hooks.sh is the one
# source every consumer reads: guardrail-block.mjs GUARDRAILS and its install()
# commands, the chain composer, the unwire patterns, and the PreToolUse wiring
# history of wire-pretooluse-hooks.sh and adopt.sh.
set -u
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../.." && pwd)"
wire="$here/wire-pretooluse-hooks.sh"
fails=0
check(){ [ "$2" = "$3" ] && echo "ok - $1" || { echo "FAIL - $1: [$2]!=[$3]"; fails=$((fails+1)); }; }
td="$(mktemp -d "${TMPDIR:-/tmp}/hook-set-list.XXXXXX")" || exit 1; trap 'rm -rf "$td"' EXIT

list=$(bash "$wire" --print-hook-set)
gate=block-unresolved-cr-merge
trio=$(jq -c --arg g "$gate" '[.[] | select(.name != $g) | {basename: (.name + ".sh"), matcher}]' <<<"$list")

check "list_shape" "$(jq '[.[] | select((.name|type)=="string" and (.matcher|type)=="string" and (.script == ("scripts/hooks/" + .name + ".sh")) and (.aliases|type)=="array")] | length == (. | length)' <<<"$list")" "true"
check "list_names_unique" "$(jq '[.[].name] | length == (unique | length)' <<<"$list")" "true"

got=$(node --input-type=module -e "import('$root/scripts/hooks/guardrail-block.mjs').then(m => console.log(JSON.stringify(m.GUARDRAILS)))")
check "guardrails_equal_list" "$(jq -c . <<<"$got")" "$trio"

check "chain_specs_equal_list" \
  "$(bash "$wire" --print-chain '$CLAUDE_PROJECT_DIR' | jq -c '[.[] | {name, matcher: .stanza.matcher}]')" \
  "$(jq -c '[.[] | {name, matcher}]' <<<"$list")"

check "trio_specs_equal_list" \
  "$(bash "$wire" --print-trio /h | jq -c '[.[] | {basename: (.name + ".sh"), matcher: .stanza.matcher}]')" "$trio"

want=$(bash "$wire" --print-trio /opt/himmel --node /usr/bin/node --bash /bin/bash | jq -c '[.[].cmd] | sort')
got=$(node --input-type=module -e "
import('$root/scripts/hooks/guardrail-block.mjs').then((m) => {
  const d = m.install({}, { nodePath: '/usr/bin/node', bashPath: '/bin/bash', himmelRepo: '/opt/himmel' }) || {};
  const cmds = (d.hooks?.PreToolUse ?? []).flatMap((g) => (g.hooks ?? []).map((h) => h.command));
  console.log(JSON.stringify(cmds.sort()));
});")
check "install_commands_equal_print_trio" "$(jq -c . <<<"$got")" "$want"

pats=$(bash -c '. "$1"; printf "%s\n%s\n" "$_UNWIRE_PRE_PAT" "$_UNWIRE_CHAIN_PAT"' _ "$here/unwire-pretooluse-hooks.sh")
pre=$(sed -n 1p <<<"$pats"); chain=$(sed -n 2p <<<"$pats")
check "unwire_pre_pat_is_trio" "$pre" \
  "$(jq -r --arg g "$gate" '"scripts/hooks/(" + ([.[] | select(.name != $g) | .name, .aliases[]] | join("|")) + ")[.]sh"' <<<"$list")"
check "unwire_pre_pat_spares_gate" "$(printf 'bash x/scripts/hooks/%s.sh' "$gate" | grep -cE "$pre")" "0"

miss=$(jq -r '.[] | .name, .aliases[]' <<<"$list" | while IFS= read -r n; do
  printf 'bash x/scripts/hooks/%s.sh' "$n" | grep -qE "$chain" || printf '%s ' "$n"; done)
check "unwire_chain_pat_matches_all" "$miss" ""

check "history_full_clone" "$(git -C "$root" rev-parse --is-shallow-repository 2>/dev/null)" "false"
known=$(jq -r '.[] | .name, .aliases[]' <<<"$list" | sort -u)
{
  git -C "$root" log -p --format= -- scripts/lib/wire-pretooluse-hooks.sh \
    | grep -E '"matcher"|spec\("|test\("scripts/hooks/\(' \
    | grep -oE 'scripts/hooks/[A-Za-z0-9._-]+[.]sh|spec\("[A-Za-z0-9._-]+"|scripts/hooks/\([^)]*\)'
  git -C "$root" log -p --format= -- scripts/adopt.sh \
    | grep -E 'PreToolUse' | grep -oE 'scripts/hooks/[A-Za-z0-9._-]+[.]sh|[a-z0-9]+(-[a-z0-9]+)+[.]sh'
} > "$td/hist"
seen=$(sed -E 's#^scripts/hooks/##; s#^spec\("##; s#"$##; s#[.]sh$##; s#^\(##; s#\)$##' "$td/hist" | tr '|' '\n' | grep -v '^$' | sort -u)
check "history_scan_nonempty" "$([ -n "$seen" ] && echo yes || echo no)" "yes"
check "history_names_in_list" "$(comm -23 <(printf '%s\n' "$seen") <(printf '%s\n' "$known") | tr '\n' ' ')" ""

[ "$fails" -eq 0 ] && echo "ALL PASS" || { echo "$fails FAILED"; exit 1; }
