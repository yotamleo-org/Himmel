#!/usr/bin/env bash
# vm-6958: the himmel-guard plugin is on by default in the starter install.
source "$(dirname "$0")/_lib.sh"
SHA=cbaf8ea9478e7d5483c35c318290610a084aee5a
vm_fresh
out="$(stage "$SHA" /tmp/himmel-6958)"; expect head "$out" "$SHA"
cat >"$WORK/p.sh" <<'EOF'
ck() { if [ "$2" = 0 ]; then echo "CHECK $1 PASS"; else echo "CHECK $1 FAIL ${3:-}"; fi; }
bash /tmp/himmel-6958/scripts/adopt.sh --profile core --scope user >/tmp/adopt.out 2>&1; ck adopt-rc $? "$(tail -3 /tmp/adopt.out)"
v="$(jq -r '.enabledPlugins["himmel-guard@himmel"]' ~/.claude/settings.json)"; [ "$v" = true ]; ck enabled-setting $? "$v"
l="$(claude plugin list 2>&1 | grep -A3 'himmel-guard@himmel')"; echo "$l"
printf '%s' "$l" | grep -q 'enabled'; ck plugin-list-enabled $?
mkdir -p /tmp/vm6958-dir
hook="$(ls ~/.claude/plugins/cache/himmel/himmel-guard/*/hooks/block-destructive-commands.sh | head -1)"
printf '%s\n' '{"tool_name":"Bash","tool_input":{"command":"rm -rf /tmp/vm6958-dir"}}' >/tmp/vm6958-in.json
d="$(bash "$hook" </tmp/vm6958-in.json 2>&1)"; rc=$?; echo "$d"
{ [ "$rc" = 2 ] || printf '%s' "$d" | grep -q '"deny"'; }; ck hook-denies $? "rc=$rc"
[ -d /tmp/vm6958-dir ]; ck dir-survives $?
bash /tmp/himmel-6958/scripts/machine-setup/plugin-profile.sh disable himmel-guard@himmel 2>&1 | tail -3
l="$(claude plugin list 2>&1 | grep -A3 'himmel-guard@himmel')"; echo "$l"
printf '%s' "$l" | grep -q 'disabled'; ck plugin-list-disabled $?
v="$(jq -r '.enabledPlugins["himmel-guard@himmel"]' ~/.claude/settings.json)"; [ "$v" = false ]; ck disabled-setting $? "$v"
EOF
tally "$(guest_script p.sh 900)"
final
