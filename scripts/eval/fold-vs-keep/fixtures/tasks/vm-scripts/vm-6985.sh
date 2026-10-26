#!/usr/bin/env bash
# vm-6985: claude-obsidian pinned to v3.0.1 updates in place from main's v2.2.0.
source "$(dirname "$0")/_lib.sh"
SHA=c81b583104097604ad697067deccb09c28c53478
vm_fresh
# shellcheck disable=SC2088 # the guest shell expands the tilde
out="$(stage "$SHA" '~/mp')"; expect head "$out" "$SHA"
cat >"$WORK/p.sh" <<'EOF'
ck() { if [ "$2" = 0 ]; then echo "CHECK $1 PASS"; else echo "CHECK $1 FAIL ${3:-}"; fi; }
cd ~/mp || exit 1
git checkout -q 272eb0bf84f7c2abe3d98a84f88b793247d9ef7e; ck main-base $?
timeout 120 claude plugin marketplace add ~/mp/marketplace 2>&1 | tail -1
timeout 300 claude plugin install claude-obsidian@himmel 2>&1 | tail -1
timeout 60 claude plugin enable claude-obsidian@himmel >/dev/null 2>&1
l="$(timeout 60 claude plugin list 2>&1 | grep -A3 'claude-obsidian@himmel')"; echo "$l"
printf '%s' "$l" | grep -q 'Version: 2.2.0'; ck main-version-2.2.0 $?
printf '%s' "$l" | grep -q 'enabled'; ck main-enabled $?
git checkout -q c81b583104097604ad697067deccb09c28c53478; ck head-checkout $?
timeout 120 claude plugin marketplace update himmel 2>&1 | tail -1
timeout 300 claude plugin update claude-obsidian@himmel 2>&1 | tail -1
l="$(timeout 60 claude plugin list 2>&1 | grep -A3 'claude-obsidian@himmel')"; echo "$l"
printf '%s' "$l" | grep -q 'Version: 3.0.1'; ck head-version-3.0.1 $?
printf '%s' "$l" | grep -q 'enabled'; ck enabled-survived $?
grep -q '"gitCommitSha": "6414e1a2' ~/.claude/plugins/installed_plugins.json; ck head-ref-6414e1a2 $?
C=~/.claude/plugins/cache/himmel/claude-obsidian/3.0.1
ns="$(ls -d "$C"/skills/*/ 2>/dev/null | wc -l)"; na="$(ls "$C"/agents/ 2>/dev/null | wc -l)"; echo "skills=$ns agents=$na"
[ "$ns" = 15 ]; ck skills-15 $? "got $ns"
[ "$na" = 3 ]; ck agents-3 $? "got $na"
PP="bash scripts/machine-setup/plugin-profile.sh"
for v in disable enable; do
    timeout 120 $PP $v claude-obsidian@himmel 2>&1 | tail -1
    want=enabled; [ "$v" = disable ] && want=disabled
    timeout 60 claude plugin list 2>&1 | grep -A3 'claude-obsidian@himmel' | grep -q "$want"; ck "profile-$v" $?
done
EOF
tally "$(guest_script p.sh 1500)"
final
