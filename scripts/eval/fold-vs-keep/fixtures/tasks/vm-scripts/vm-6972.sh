#!/usr/bin/env bash
# vm-6972: the read-only post-install duplicate scan, after a v1.1.2 to 26e62fee6 install.
source "$(dirname "$0")/_lib.sh"
SHA="$(git rev-parse 26e62fee6)"
vm_fresh
# shellcheck disable=SC2088 # the guest shell expands the tilde
out="$(stage "$SHA" '~/h6972' v1.1.2)"; expect head "$out" "$SHA"
cat >"$WORK/p.sh" <<'EOF'
ck() { if [ "$2" = 0 ]; then echo "CHECK $1 PASS"; else echo "CHECK $1 FAIL ${3:-}"; fi; }
cd ~/h6972 || exit 1
git checkout -q v1.1.2; ck old-tag $?
node scripts/himmelctl/bin.js install --scope user >/tmp/old.log 2>&1; ck old-install $? "$(tail -3 /tmp/old.log)"
mkdir -p /tmp/proj/.claude && cp .claude/settings.json /tmp/proj/.claude/settings.json
git checkout -q 26e62fee6; ck new-checkout $?
node scripts/himmelctl/bin.js install --scope user >/tmp/new.log 2>&1; ck new-install $? "$(tail -3 /tmp/new.log)"
s="$(bash scripts/install/scan-duplicates.sh /tmp/proj 2>&1)"; src=$?; echo "scan rc=$src"; echo "$s"
[ "$src" = 0 ] && grep -q '^scan-duplicates: ' <<<"$s"; ck scan-reports $? "rc=$src"
t="$(bash scripts/install/test-scan-duplicates.sh 2>&1)"; rc=$?; echo "$t" | tail -5
ck scan-test $rc "rc=$rc"
EOF
tally "$(guest_script p.sh 1200)"
final
