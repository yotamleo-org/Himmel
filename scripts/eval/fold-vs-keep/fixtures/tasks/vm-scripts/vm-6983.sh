#!/usr/bin/env bash
# vm-6983: the setup UI's CodeRabbit section, its secret-form examples, and states (a) and armed.
source "$(dirname "$0")/_lib.sh"
SHA=50b65e535a641ad5a1a2d0aed68ea7ecf8d4c36f
vm_fresh
# shellcheck disable=SC2088 # the guest shell expands the tilde
out="$(stage "$SHA" '~/scratch-6983')"; expect head "$out" "$SHA"
cat >"$WORK/p.sh" <<'EOF'
ck() { if [ "$2" = 0 ]; then echo "CHECK $1 PASS"; else echo "CHECK $1 FAIL ${3:-}"; fi; }
export PATH="$HOME/.bun/bin:$PATH"
cd ~/scratch-6983 || exit 1
nohup node scripts/himmelctl/bin.js ui --port 0 >/tmp/ui.log 2>&1 </dev/null &
for _ in $(seq 1 20); do grep -q '#t=' /tmp/ui.log && break; sleep 1; done
U="$(head -1 /tmp/ui.log)"; P="$(printf '%s' "$U" | sed 's#.*:\([0-9]*\)/.*#\1#')"; K="${U##*#t=}"
api() { curl -s -H "X-Himmel-Token: $K" "http://127.0.0.1:$P/api/setup"; }
j="$(api)"; [ -n "$j" ]; ck ui-serves $? "$(sed 's/#t=.*/#t=<redacted>/' /tmp/ui.log | head -2)"
c="$(printf '%s' "$j" | jq -c .coderabbit)"; echo "$c"
[ "$(printf '%s' "$c" | jq -r .requirement)" = optional ]; ck requirement-optional $?
printf '%s' "$c" | jq -r '.steps[]' | grep -q 'https://github.com/apps/coderabbitai'; ck app-link $?
[ "$(printf '%s' "$c" | jq '.steps | length')" = 3 ]; ck three-steps $?
m="$(printf '%s' "$j" | jq -r '[.secrets[] | select(.collect == "file") | select(.example == "") | .name] | join(",")')"
[ -z "$m" ]; ck examples-on-settable-forms $? "missing: $m"
[ "$(printf '%s' "$c" | jq -r .installed)" = unknown ] && [ "$(printf '%s' "$c" | jq -r '.manual != null')" = true ]; ck state-a-unknown-manual $?
git config --local himmel.coderabbit true
[ "$(api | jq -r .coderabbit.armed)" = true ]; ck armed-true $?
git config --local --unset himmel.coderabbit
pkill -f 'himmelctl/bin.js ui'
EOF
tally "$(guest_script p.sh 600)"
final
