#!/usr/bin/env bash
# vm-6972b: re-run at merged main 25dea92e: v1.1.2 install, upgrade, then the duplicate scan and its test.
source "$(dirname "$0")/_lib.sh"
SHA=25dea92ec7e8a010383a6337bc5053410a632414
vm_fresh
out="$(stage "$SHA" /tmp/himmel v1.1.2)"; expect head "$out" "$SHA"
cat >"$WORK/p.sh" <<'EOF'
ck() { if [ "$2" = 0 ]; then echo "CHECK $1 PASS"; else echo "CHECK $1 FAIL ${3:-}"; fi; }
G="git -c user.name=eval -c user.email=eval@example.invalid"
mkdir -p /tmp/proj && git -C /tmp/proj init -q -b main && echo hi >/tmp/proj/README.md
git -C /tmp/proj add README.md && $G -C /tmp/proj commit -q -m "chore: [#1] init"
git -C /tmp/himmel checkout -q v1.1.2; ck old-tag $?
cd /tmp/proj || { ck cd-proj 1; exit 1; }
timeout 900 node /tmp/himmel/scripts/himmelctl/bin.js install --scope project >/tmp/inst1.log 2>&1 </dev/null; ck old-install $? "$(tail -3 /tmp/inst1.log)"
git -C /tmp/himmel checkout -q 25dea92ec7e8a010383a6337bc5053410a632414; ck new-checkout $?
timeout 900 node /tmp/himmel/scripts/himmelctl/bin.js install --scope project >/tmp/inst2.log 2>&1 </dev/null; ck new-install $? "$(tail -3 /tmp/inst2.log)"
s="$(timeout 300 bash /tmp/himmel/scripts/install/scan-duplicates.sh /tmp/proj 2>&1)"; src=$?; echo "scan rc=$src"; echo "$s"
[ "$src" = 0 ] && grep -q '^scan-duplicates: ' <<<"$s"; ck scan-reports $? "rc=$src"
cd /tmp/himmel || { ck cd-himmel 1; exit 1; }
t="$(timeout 600 bash scripts/install/test-scan-duplicates.sh 2>&1)"; rc=$?; echo "$t" | tail -5
ck scan-test $rc "rc=$rc"
EOF
tally "$(guest_script p.sh 2400)"
final
