#!/usr/bin/env bash
# scripts/ci/test-gcp-net.sh -- regression suite for scripts/ci/gcp-net.sh, the
# zero-ingress VPC and FQDN egress allowlist under the GCP CI runners. gcloud is
# a stub on $GCLOUD; no live call is made. Pins: net-up builds the custom-mode
# VPC, the Private-Google-Access subnet, the NAT and the firewall policy with a
# deny-all ingress and a deny-all egress rule, every allow rule carries FQDNs
# (never a 0.0.0.0/0 allow), the allowlist covers the hosts ci.yml fetches,
# debug-on/off touch only the IAP rule, net-up is idempotent, and every gcloud
# call is impersonated and never touches the default VPC.
#
# Usage: bash scripts/ci/test-gcp-net.sh
# Exit codes: 0 -- all cases passed; 1 -- at least one failed.
# shellcheck disable=SC2015  # `grep && ok || bad` is the pass/fail line; ok never fails
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SUT="$ROOT/scripts/ci/gcp-net.sh"
SA="himmel-ci-runner@himmel-ci.iam.gserviceaccount.com"
fails=0
ok()  { echo "ok - $1"; }
bad() { echo "FAIL - $1" >&2; fails=$((fails + 1)); }

T="$(mktemp -d -t gcp-net-test.XXXXXX)" || exit 1
trap 'rm -rf "$T"' EXIT

# describe exits 1 (resource absent) unless $STUB_EXISTS is set; STUB_FAIL=<word>
# makes any call whose text contains the word fail.
cat > "$T/gcloud" <<'STUB'
#!/usr/bin/env bash
printf 'GCLOUD %s\n' "$*" >> "$STUB_LOG"
[ -n "${STUB_FAIL:-}" ] && case "$*" in *"$STUB_FAIL"*) exit 1 ;; esac
case "$*" in
    *" describe "*) [ -n "${STUB_EXISTS:-}" ] || exit 1 ;;
esac
exit 0
STUB
chmod +x "$T/gcloud"

export GCLOUD="$T/gcloud" STUB_LOG="$T/log"
run() { : > "$STUB_LOG"; bash "$SUT" "$@" > "$T/out" 2>&1; echo $?; }
# rules_create -> the logged `rules create` lines
rules_create() { grep 'network-firewall-policies rules create' "$STUB_LOG"; }
# rule_for <priority> -> the one rules-create line with that priority
rule_for() { rules_create | grep -E "rules create $1( |\$)"; }

# 1. no subcommand and an unknown subcommand are usage errors that call gcloud never.
for a in "" bogus; do
    rc="$(run $a)"
    if [ "$rc" -eq 2 ] && [ ! -s "$STUB_LOG" ]; then ok "'${a:-<none>}' is a usage error (rc 2), no gcloud call"; else bad "'${a:-<none>}': rc=$rc"; fi
done

# 2. net-up builds the network pieces, in order, once each.
rc="$(run net-up)"
if [ "$rc" -eq 0 ]; then ok "net-up exits 0"; else bad "net-up rc=$rc: $(cat "$T/out")"; fi
grep -q 'compute networks create himmel-ci-net .*--subnet-mode=custom' "$STUB_LOG" && ok "VPC himmel-ci-net is custom-mode" || bad "no custom-mode VPC create"
grep -q 'compute networks subnets create himmel-ci-net .*--network=himmel-ci-net .*--region=us-central1 .*--enable-private-ip-google-access' "$STUB_LOG" \
    && ok "subnet himmel-ci-net has Private Google Access on, in us-central1" || bad "subnet create lacks network/region/PGA"
grep -q 'compute routers create himmel-ci-router .*--network=himmel-ci-net .*--region=us-central1' "$STUB_LOG" && ok "Cloud Router created" || bad "no router create"
grep -q 'compute routers nats create himmel-ci-nat .*--router=himmel-ci-router' "$STUB_LOG" && ok "Cloud NAT created on the router" || bad "no NAT create"
grep -q 'compute network-firewall-policies create himmel-ci-net-policy .*--global' "$STUB_LOG" && ok "global firewall policy created" || bad "no firewall policy create"
grep -q 'network-firewall-policies associations create .*--firewall-policy=himmel-ci-net-policy .*--network=himmel-ci-net' "$STUB_LOG" \
    && ok "policy is associated with the VPC" || bad "no policy association"
order="$(grep -o -E 'networks create|subnets create|routers create|nats create|network-firewall-policies create|associations create' "$STUB_LOG" | tr '\n' ',')"
want="networks create,subnets create,routers create,nats create,network-firewall-policies create,associations create,"
if [ "$order" = "$want" ]; then ok "pieces are created in dependency order"; else bad "create order: $order"; fi

# 3. deny-all ingress and deny-all egress exist, log, and are the lowest-precedence rules.
ing="$(rules_create | grep -- '--direction=INGRESS' | grep -- '--action=deny')"
egr="$(rules_create | grep -- '--direction=EGRESS' | grep -- '--action=deny')"
if [ -n "$ing" ] && echo "$ing" | grep -q -- '--src-ip-ranges=0.0.0.0/0' && echo "$ing" | grep -q -- '--enable-logging' && echo "$ing" | grep -q -- '--layer4-configs=all'; then ok "deny-all ingress rule logs"; else bad "deny-all ingress missing or not logging: $ing"; fi
if [ -n "$egr" ] && echo "$egr" | grep -q -- '--dest-ip-ranges=0.0.0.0/0' && echo "$egr" | grep -q -- '--enable-logging' && echo "$egr" | grep -q -- '--layer4-configs=all'; then ok "deny-all egress rule logs"; else bad "deny-all egress missing or not logging: $egr"; fi
maxallow="$(rules_create | grep -- '--action=allow' | sed -E 's/.*rules create ([0-9]+) .*/\1/' | sort -n | tail -1)"
mindeny="$(rules_create | grep -- '--action=deny' | sed -E 's/.*rules create ([0-9]+) .*/\1/' | sort -n | head -1)"
if [ -n "$maxallow" ] && [ -n "$mindeny" ] && [ "$maxallow" -lt "$mindeny" ]; then ok "every allow outranks every deny"; else bad "allow max=$maxallow deny min=$mindeny"; fi

# 4. no allow rule opens to 0.0.0.0/0 (or ::/0), and every allow egress rule is FQDN-scoped.
if rules_create | grep -- '--action=allow' | grep -q -E '0\.0\.0\.0/0|::/0'; then bad "an allow rule is open to the world"; else ok "no allow rule uses 0.0.0.0/0"; fi
allow_egress="$(rules_create | grep -- '--action=allow' | grep -- '--direction=EGRESS')"
n_allow="$(echo "$allow_egress" | grep -c .)"
n_fqdn="$(echo "$allow_egress" | grep -c -- '--dest-fqdns=')"
if [ "$n_allow" -ge 1 ] && [ "$n_allow" -eq "$n_fqdn" ]; then ok "all $n_allow allow-egress rules carry --dest-fqdns"; else bad "allow-egress rules=$n_allow with FQDNs=$n_fqdn"; fi
if rules_create | grep -- '--action=allow' | grep -q -- '--direction=INGRESS'; then bad "net-up created an allow ingress rule (debug is off by default)"; else ok "no allow ingress rule by default"; fi

# 5. fixture copied from the real environment: every https host ci.yml fetches is allowed.
#    (the gitleaks release download and the actions the shard setup uses).
hosts="$(grep -o -E 'https://[a-zA-Z0-9.-]+' "$ROOT/.github/workflows/ci.yml" | sed 's#https://##' | sort -u)"
[ -n "$hosts" ] || bad "fixture: ci.yml yielded no https hosts"
for h in $hosts; do
    if echo "$allow_egress" | grep -q -E -- "--dest-fqdns=([^ ]*,)?$h(,| |\$)"; then ok "ci.yml host $h is on the allowlist"; else bad "ci.yml host $h is not allowed"; fi
done
# GitHub's documented self-hosted runner hosts (docs.github.com, Communication requirements).
for h in github.com api.github.com codeload.github.com objects.githubusercontent.com '*.actions.githubusercontent.com' ghcr.io; do
    if echo "$allow_egress" | grep -q -F -- "$h"; then ok "GitHub runner host $h is on the allowlist"; else bad "GitHub runner host $h missing"; fi
done

# 6. every gcloud call is impersonated, in project himmel-ci, never the default VPC.
total="$(grep -c '^GCLOUD ' "$STUB_LOG")"
imp="$(grep '^GCLOUD ' "$STUB_LOG" | grep -c -- "--impersonate-service-account=$SA")"
prj="$(grep '^GCLOUD ' "$STUB_LOG" | grep -c -- '--project=himmel-ci')"
if [ "$total" -gt 0 ] && [ "$total" -eq "$imp" ] && [ "$total" -eq "$prj" ]; then ok "all $total gcloud calls impersonate the runner SA in himmel-ci"; else bad "calls=$total impersonated=$imp project=$prj"; fi
if grep '^GCLOUD ' "$STUB_LOG" | grep -q -E '(network|networks|--network)[= ]default( |$)'; then bad "a call targets the default VPC"; else ok "no call targets the default VPC"; fi

# 7. net-up is idempotent: with everything present it creates nothing.
export STUB_EXISTS=1
rc="$(run net-up)"
if [ "$rc" -eq 0 ] && ! grep -q -E ' create ' "$STUB_LOG"; then ok "net-up on an existing network creates nothing"; else bad "idempotency: rc=$rc creates=$(grep -c ' create ' "$STUB_LOG")"; fi
unset STUB_EXISTS

# 8. a failing create fails net-up (no silent half-built network).
export STUB_FAIL="routers create"
rc="$(run net-up)"
if [ "$rc" -ne 0 ] && ! grep -q 'network-firewall-policies' "$STUB_LOG"; then ok "net-up stops at the first failed create"; else bad "failed router create: rc=$rc"; fi
unset STUB_FAIL

# 9. debug-on adds ONLY the IAP rule; debug-off removes ONLY it.
rc="$(run debug-on)"
n_calls="$(grep -c '^GCLOUD ' "$STUB_LOG")"
iap="$(rules_create)"
if [ "$rc" -eq 0 ] && echo "$iap" | grep -q -- '--src-ip-ranges=35.235.240.0/20' && echo "$iap" | grep -q -- '--layer4-configs=tcp:22' \
    && echo "$iap" | grep -q -- '--direction=INGRESS' && echo "$iap" | grep -q -- '--action=allow'; then ok "debug-on creates the IAP-only tcp:22 allow rule"; else bad "debug-on: rc=$rc rule=$iap"; fi
if [ "$(echo "$iap" | grep -c .)" -eq 1 ] && ! grep -q -E 'networks|routers|associations|rules delete|rules update' "$STUB_LOG"; then ok "debug-on touches nothing but that rule ($n_calls calls)"; else bad "debug-on touched more than the IAP rule"; fi
export STUB_EXISTS=1
rc="$(run debug-off)"
if [ "$rc" -eq 0 ] && [ "$(grep -c 'network-firewall-policies rules delete' "$STUB_LOG")" -eq 1 ] && ! grep -q -E ' create |networks|routers' "$STUB_LOG"; then ok "debug-off deletes exactly one rule and creates nothing"; else bad "debug-off: rc=$rc"; fi
prio_off="$(grep 'rules delete' "$STUB_LOG" | sed -E 's/.*rules delete ([0-9]+) .*/\1/')"
unset STUB_EXISTS
run debug-on > /dev/null
prio_on="$(rules_create | sed -E 's/.*rules create ([0-9]+) .*/\1/')"
if [ -n "$prio_on" ] && [ "$prio_on" = "$prio_off" ]; then ok "debug-off deletes the rule debug-on created (priority $prio_on)"; else bad "debug-on priority '$prio_on' vs debug-off '$prio_off'"; fi
export STUB_EXISTS=1
rc="$(run debug-on)"
if [ "$rc" -eq 0 ] && [ -z "$(rules_create)" ]; then ok "debug-on is idempotent"; else bad "debug-on twice: rc=$rc"; fi
unset STUB_EXISTS
# debug-off with no rule present is not an error.
rc="$(run debug-off)"
if [ "$rc" -eq 0 ]; then ok "debug-off with no IAP rule exits 0"; else bad "debug-off absent: rc=$rc"; fi

# 10. net-down removes what net-up built, in reverse order, and only that.
export STUB_EXISTS=1
rc="$(run net-down)"
if [ "$rc" -eq 0 ]; then ok "net-down exits 0"; else bad "net-down rc=$rc: $(cat "$T/out")"; fi
order="$(grep -o -E 'associations delete|network-firewall-policies delete|nats delete|routers delete|subnets delete|networks delete' "$STUB_LOG" | tr '\n' ',')"
want="associations delete,network-firewall-policies delete,nats delete,routers delete,subnets delete,networks delete,"
if [ "$order" = "$want" ]; then ok "net-down deletes in reverse dependency order"; else bad "net-down order: $order"; fi
grep '^GCLOUD ' "$STUB_LOG" | grep -q -E ' (delete|create) .*default' && bad "net-down touched a default resource" || ok "net-down never touches default"
unset STUB_EXISTS

# 11. status reads and never writes.
export STUB_EXISTS=1
rc="$(run status)"
if [ "$rc" -eq 0 ] && ! grep -q -E ' (create|delete|update) ' "$STUB_LOG" && grep -q 'describe' "$STUB_LOG"; then ok "status only reads"; else bad "status: rc=$rc"; fi
unset STUB_EXISTS

[ "$fails" -eq 0 ] || { echo "$fails case(s) failed" >&2; exit 1; }
echo "all cases passed"
