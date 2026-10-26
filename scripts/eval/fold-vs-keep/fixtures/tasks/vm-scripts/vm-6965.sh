#!/usr/bin/env bash
# vm-6965: a project adopt ships both preflight libs, and each prints a valid verdict.
source "$(dirname "$0")/_lib.sh"
SHA=f87b09047a5a84e95ff22288f1d98a55066387af
vm_fresh
out="$(stage "$SHA" /tmp/br6965)"; expect head "$out" "$SHA"
cat >"$WORK/p.sh" <<'EOF'
ck() { if [ "$2" = 0 ]; then echo "CHECK $1 PASS"; else echo "CHECK $1 FAIL ${3:-}"; fi; }
rm -rf /tmp/vmscratch-6965 && mkdir /tmp/vmscratch-6965 && cd /tmp/vmscratch-6965 && git init -q -b main . || exit 1
timeout 600 bash /tmp/br6965/scripts/adopt.sh --profile core --scope project --target /tmp/vmscratch-6965 >/tmp/a.out 2>&1; ck adopt-rc $? "$(tail -3 /tmp/a.out)"
ls scripts/lib/usage-preflight.sh scripts/lib/bank-preflight.sh; ck both-libs $?
cache=absent; [ -f /tmp/claude/statusline-usage-cache.json ] && cache=present; echo "usage cache: $cache"
for lib in usage-preflight bank-preflight; do
    o="$(timeout 60 bash scripts/lib/$lib.sh 2>&1)"; echo "$o"; v="$(printf '%s\n' "$o" | tail -1)"
    case "$cache:$v" in
        *:PROCEED|*:SKIPPED-BANK*|absent:BANK-UNKNOWN) ck "$lib-verdict" 0 ;;
        *) ck "$lib-verdict" 1 "cache=$cache verdict=$v" ;;
    esac
done
cd / && rm -rf /tmp/vmscratch-6965
EOF
tally "$(guest_script p.sh 900)"
final
