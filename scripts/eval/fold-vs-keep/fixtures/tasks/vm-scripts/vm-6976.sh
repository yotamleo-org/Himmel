#!/usr/bin/env bash
# vm-6976: adopt.sh installs a no-force-push pre-push gate, idempotently.
source "$(dirname "$0")/_lib.sh"
SHA=08ff222371d08c36a723ffafe42164dacc31eff0
vm_fresh
out="$(stage "$SHA" /tmp/wt)"; expect head "$out" "$SHA"
cat >"$WORK/p.sh" <<'EOF'
ck() { if [ "$2" = 0 ]; then echo "CHECK $1 PASS"; else echo "CHECK $1 FAIL ${3:-}"; fi; }
G="git -c user.name=eval -c user.email=eval@example.invalid"
rm -rf /tmp/origin.git /tmp/scratch
git init -q --bare /tmp/origin.git && git init -q -b main /tmp/scratch && cd /tmp/scratch || exit 1
echo a >a.txt && git add a.txt && $G commit -q -m "chore: [#1] base" && git remote add origin /tmp/origin.git && git push -q origin main
[ ! -e .pre-commit-config.yaml ]; ck no-precommit-config $?
timeout 600 bash /tmp/wt/scripts/adopt.sh --profile core --scope project --target /tmp/scratch >/tmp/adopt1.out 2>&1; ck adopt-rc $? "$(tail -3 /tmp/adopt1.out)"
before="$(git -C /tmp/origin.git rev-parse main)"
git checkout -q --orphan x && git rm -q -rf --cached . >/dev/null && echo b >b.txt && git add b.txt && $G commit -q -m "chore: [#1] unrelated"
p="$(timeout 120 git push --force origin HEAD:refs/heads/main 2>&1)"; rc=$?; echo "$p"
[ "$rc" != 0 ]; ck force-push-refused $? "rc=$rc"
printf '%s' "$p" | grep -q "Force-push to 'main' is not allowed"; ck refusal-message $?
[ "$(git -C /tmp/origin.git rev-parse main)" = "$before" ]; ck origin-unchanged $?
timeout 600 bash /tmp/wt/scripts/adopt.sh --profile core --scope project --target /tmp/scratch >/tmp/adopt2.out 2>&1; ck adopt-again-rc $?
n="$(grep -c 'bash "$fp_gate"' /tmp/scratch/.git/hooks/pre-push)"; [ "$n" = 1 ]; ck gate-wired-once $? "count=$n"
EOF
tally "$(guest_script p.sh 1500)"
final
