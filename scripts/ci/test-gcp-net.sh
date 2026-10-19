#!/usr/bin/env bash
# scripts/ci/test-gcp-net.sh -- regression suite for scripts/ci/gcp-net.sh, the
# zero-ingress VPC and allowlisting egress proxy under the GCP CI runners. gcloud
# is a stub on $GCLOUD; no live call is made. Pins: net-up builds the custom-mode
# VPC, the Private-Google-Access subnet, the NAT, one shielded squid proxy VM
# with no external IP, and a firewall policy whose only runner egress is the
# proxy port (plus the Google APIs by exact FQDN) under a deny-all ingress and a
# deny-all egress rule; the proxy allowlist covers the hosts ci.yml fetches and
# denies the rest; debug-on/off touch only the IAP rule; net-up is idempotent;
# a failed lookup is never read as absence; every gcloud call is impersonated and
# never touches the default VPC.
#
# Usage: bash scripts/ci/test-gcp-net.sh
# Exit codes: 0 -- all cases passed; 1 -- at least one failed.
# shellcheck disable=SC2015  # `grep && ok || bad` is the pass/fail line; ok never fails
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SUT="$ROOT/scripts/ci/gcp-net.sh"
SA="himmel-ci-runner@himmel-ci.iam.gserviceaccount.com"
RANGE="10.10.0.0/24"  # leak-allow: private-lan-ip the runner subnet's own CIDR in the dedicated runner VPC
PROXY_IP="10.10.0.10"  # leak-allow: private-lan-ip the proxy's fixed address inside the dedicated runner VPC
fails=0
ok()  { echo "ok - $1"; }
bad() { echo "FAIL - $1" >&2; fails=$((fails + 1)); }

T="$(mktemp -d -t gcp-net-test.XXXXXX)" || exit 1
trap 'rm -rf "$T"' EXIT

# describe exits 1 with gcloud's "was not found" (resource absent) unless
# $STUB_EXISTS is set, or with a PERMISSION_DENIED error when $STUB_DESCRIBE_ERR
# is set; STUB_FAIL=<word> makes any call whose text contains the word fail. A
# --metadata-from-file=startup-script=<file> is copied to $STUB_LOG.startup, as
# net-up deletes its temp file.
cat > "$T/gcloud" <<'STUB'
#!/usr/bin/env bash
printf 'GCLOUD %s\n' "$*" >> "$STUB_LOG"
for a in "$@"; do
    case "$a" in --metadata-from-file=startup-script=*) cp "${a#*=startup-script=}" "$STUB_LOG.startup" ;; esac
done
[ -n "${STUB_FAIL:-}" ] && case "$*" in *"$STUB_FAIL"*) exit 1 ;; esac
case "$*" in
    *" describe "*)
        case "$*" in *"associations describe"*) echo "ERROR: (gcloud.compute.network-firewall-policies.associations) Invalid choice: 'describe'." >&2; exit 2 ;; esac
        if [ -n "${STUB_EXISTS:-}" ]; then case "$*" in *"network-firewall-policies describe"*"--format=json"*)
            if [ -n "${STUB_NO_ASSOC:-}" ]; then echo '{"name": "himmel-ci-net-policy", "associations": []}'
            else echo '{"name": "himmel-ci-net-policy", "associations": [{"attachmentTarget": "https://www.googleapis.com/compute/v1/projects/himmel-ci/global/networks/himmel-ci-net", "name": "himmel-ci-net-assoc"}]}'; fi
            exit 0 ;; esac; fi
        if [ -n "${STUB_RULE_ERR:-}" ]; then case "$*" in *"rules describe"*) printf '%s\n' "$STUB_RULE_ERR" >&2; exit 1 ;; esac; fi
        if [ -n "${STUB_DESCRIBE_ERR:-}" ]; then echo "ERROR: (gcloud) PERMISSION_DENIED: caller lacks permission" >&2; exit 1; fi
        [ -n "${STUB_EXISTS:-}" ] || { echo "ERROR: (gcloud) The resource 'projects/himmel-ci/x' was not found" >&2; exit 1; } ;;
esac
exit 0
STUB
chmod +x "$T/gcloud"

export GCLOUD="$T/gcloud" STUB_LOG="$T/log"
run() { : > "$STUB_LOG"; rm -f "$STUB_LOG.startup"; bash "$SUT" "$@" > "$T/out" 2>&1; echo $?; }
# rules_create -> the logged `rules create` lines
rules_create() { grep 'network-firewall-policies rules create' "$STUB_LOG"; }
# covered <host> <squid conf>: 0 when a dstdomain entry matches the host (exact, or
# a leading-dot entry for the domain and its subdomains).
covered() {
    local h="$1" f="$2" d
    while read -r d; do
        case "$d" in
            .*) [ "$h" = "${d#.}" ] && return 0; case "$h" in *"$d") return 0 ;; esac ;;
            *) [ "$h" = "$d" ] && return 0 ;;
        esac
    done < <(sed -n -E 's/^acl allowed_hosts dstdomain (-n )?//p' "$f")
    return 1
}

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
order="$(grep -o -E 'networks create|subnets create|routers create|nats create|instances create|network-firewall-policies create|associations create' "$STUB_LOG" | tr '\n' ',')"
want="networks create,subnets create,routers create,nats create,instances create,network-firewall-policies create,associations create,"
if [ "$order" = "$want" ]; then ok "pieces are created in dependency order, association last"; else bad "create order: $order"; fi

# 2b. the proxy VM: one squid host, no external IP, shielded, minimal identity, no SSH.
pvm="$(grep 'compute instances create' "$STUB_LOG")"
if [ "$(echo "$pvm" | grep -c .)" -eq 1 ]; then ok "exactly one VM is created by net-up"; else bad "net-up creates $(echo "$pvm" | grep -c .) VMs"; fi
for f in --no-address --shielded-secure-boot --shielded-vtpm --shielded-integrity-monitoring --no-service-account --no-scopes \
    --machine-type=e2-micro --boot-disk-type=pd-standard --zone=us-central1-a --subnet=himmel-ci-net "--private-network-ip=$PROXY_IP" \
    --metadata=block-project-ssh-keys=TRUE; do
    if echo "$pvm" | grep -q -F -- "$f"; then ok "proxy VM carries $f"; else bad "proxy VM lacks $f"; fi
done
if echo "$pvm" | grep -q -E -- '--address|--network-interface|access-config'; then bad "proxy VM may get an external address"; else ok "proxy VM has no external address flag"; fi

# 3. deny-all ingress and deny-all egress exist, log, and are the lowest-precedence rules.
ing="$(rules_create | grep -- '--direction=INGRESS' | grep -- '--action=deny')"
egr="$(rules_create | grep -- '--direction=EGRESS' | grep -- '--action=deny')"
if [ -n "$ing" ] && echo "$ing" | grep -q -- '--src-ip-ranges=0.0.0.0/0' && echo "$ing" | grep -q -- '--enable-logging' && echo "$ing" | grep -q -- '--layer4-configs=all'; then ok "deny-all ingress rule logs"; else bad "deny-all ingress missing or not logging: $ing"; fi
if [ -n "$egr" ] && echo "$egr" | grep -q -- '--dest-ip-ranges=0.0.0.0/0' && echo "$egr" | grep -q -- '--enable-logging' && echo "$egr" | grep -q -- '--layer4-configs=all'; then ok "deny-all egress rule logs"; else bad "deny-all egress missing or not logging: $egr"; fi
maxallow="$(rules_create | grep -- '--action=allow' | sed -E 's/.*rules create ([0-9]+) .*/\1/' | sort -n | tail -1)"
mindeny="$(rules_create | grep -- '--action=deny' | sed -E 's/.*rules create ([0-9]+) .*/\1/' | sort -n | head -1)"
if [ -n "$maxallow" ] && [ -n "$mindeny" ] && [ "$maxallow" -lt "$mindeny" ]; then ok "every allow outranks every deny"; else bad "allow max=$maxallow deny min=$mindeny"; fi

# 4. the allow rules: runners reach only the proxy port (and the Google APIs by exact
#    FQDN); only the proxy host may open to the world, and only on web ports.
allow_egress="$(rules_create | grep -- '--action=allow' | grep -- '--direction=EGRESS')"
allow_ingress="$(rules_create | grep -- '--action=allow' | grep -- '--direction=INGRESS')"
world="$(rules_create | grep -- '--action=allow' | grep -E -- '0\.0\.0\.0/0|::/0')"
if [ "$(echo "$world" | grep -c .)" -eq 1 ] && echo "$world" | grep -q -- "--src-ip-ranges=$PROXY_IP/32" && echo "$world" | grep -q -- '--layer4-configs=tcp:80,tcp:443'; then
    ok "the one allow rule open to the world is sourced from the proxy IP, tcp:80/443 only"
else bad "world-open allow rules: $world"; fi
bad_egress="$(echo "$allow_egress" | grep -v -- "--dest-ip-ranges=$PROXY_IP/32" | grep -v -- '--dest-fqdns=' | grep -v -- "--src-ip-ranges=$PROXY_IP/32")"
if [ -z "$bad_egress" ]; then ok "every allow-egress rule is proxy-bound, proxy-sourced or FQDN-scoped"; else bad "unscoped allow-egress: $bad_egress"; fi
runner_to_proxy="$(echo "$allow_egress" | grep -- "--dest-ip-ranges=$PROXY_IP/32")"
if [ "$(echo "$runner_to_proxy" | grep -c .)" -eq 1 ] && echo "$runner_to_proxy" | grep -q -- '--layer4-configs=tcp:3128 '; then ok "runners' only proxy egress is tcp:3128"; else bad "runner->proxy egress: $runner_to_proxy"; fi
if echo "$allow_egress" | grep -- '--dest-fqdns=' | grep -q -F '*'; then bad "an FQDN rule carries a wildcard (Standard-tier FQDN objects reject them)"; else ok "no FQDN rule carries a wildcard"; fi
n_fq="$(echo "$allow_egress" | grep -c -- '--dest-fqdns=')"
if [ "$n_fq" -eq 1 ] && echo "$allow_egress" | grep -- '--dest-fqdns=' | grep -q 'storage.googleapis.com'; then ok "one FQDN rule remains: the Google APIs"; else bad "FQDN rules: $n_fq"; fi
if [ "$(echo "$allow_ingress" | grep -c .)" -eq 1 ] && echo "$allow_ingress" | grep -q -- "--src-ip-ranges=$RANGE" && echo "$allow_ingress" | grep -q -- "--dest-ip-ranges=$PROXY_IP/32" \
    && echo "$allow_ingress" | grep -q -- '--layer4-configs=tcp:3128'; then
    ok "the only allow ingress is runners to the proxy on tcp:3128 (debug is off by default)"
else bad "allow ingress by default: $allow_ingress"; fi

# 5. the proxy allowlist (squid conf shipped in the startup script): the fixture is
#    every https host ci.yml fetches; GitHub's documented runner hosts too.
conf="$STUB_LOG.startup"
[ -s "$conf" ] && ok "net-up ships a startup script with the squid config" || bad "no startup script captured"
if grep -q -E '^http_port 3128$' "$conf" && grep -q -E '^http_access deny all$' "$conf" && ! grep -q -E '^http_access allow all$' "$conf" \
    && [ "$(grep '^http_access' "$conf" | tail -1)" = "http_access deny all" ]; then ok "squid listens on 3128 and ends with http_access deny all"; else bad "squid access rules"; fi
grep -q -E '^acl safe_ports port 80 443$' "$conf" && grep -q -E '^http_access deny !safe_ports$' "$conf" && ok "squid allows only ports 80 and 443" || bad "squid port restriction missing"
# an IP-literal CONNECT must not pass on a reverse-DNS name: every dstdomain line
# is -n, and the IP-literal denies (v4 and v6) come before the allow.
nacl="$(grep -c -E '^acl allowed_hosts dstdomain ' "$conf")"
nflag="$(grep -c -E '^acl allowed_hosts dstdomain -n ' "$conf")"
if [ "$nacl" -gt 0 ] && [ "$nacl" = "$nflag" ]; then ok "every squid dstdomain line is -n ($nflag)"; else bad "squid dstdomain lines without -n: $((nacl - nflag)) of $nacl"; fi
ln_allow="$(grep -n -E '^http_access allow allowed_hosts$' "$conf" | head -1 | cut -d: -f1)"
ln_v4="$(grep -n -E '^http_access deny ip4_dst$' "$conf" | head -1 | cut -d: -f1)"
ln_v6="$(grep -n -E '^http_access deny ip6_dst$' "$conf" | head -1 | cut -d: -f1)"
if grep -q -F 'acl ip4_dst dstdom_regex -n ^[0-9.]+$' "$conf" && grep -q -F 'acl ip6_dst dstdom_regex -n :' "$conf" \
    && [ -n "$ln_allow" ] && [ -n "$ln_v4" ] && [ -n "$ln_v6" ] && [ "$ln_v4" -lt "$ln_allow" ] && [ "$ln_v6" -lt "$ln_allow" ]; then ok "squid denies IP-literal destinations (v4, v6) before the allow"; else bad "squid IP-literal denies missing or after the allow"; fi
grep -q -E '^forwarded_for delete$' "$conf" && grep -q -E '^via off$' "$conf" && ok "squid does not forward client addresses (forwarded_for delete, via off)" || bad "squid forwarded_for/via not hardened"
hosts="$(grep -o -E 'https://[a-zA-Z0-9.-]+' "$ROOT/.github/workflows/ci.yml" | sed 's#https://##' | sort -u)"
[ -n "$hosts" ] || bad "fixture: ci.yml yielded no https hosts"
for h in $hosts; do
    if covered "$h" "$conf"; then ok "ci.yml host $h is on the proxy allowlist"; else bad "ci.yml host $h is not allowed"; fi
done
for h in github.com api.github.com codeload.github.com objects.githubusercontent.com results-receiver.actions.githubusercontent.com \
    pipelines.actions.githubusercontent.com ghcr.io npm.pkg.github.com acct123.blob.core.windows.net registry.npmjs.org pypi.org; do
    if covered "$h" "$conf"; then ok "runner host $h is on the proxy allowlist"; else bad "runner host $h missing"; fi
done
for h in example.com evil.githubusercontent.com.attacker.net core.windows.net.attacker.net acct123.table.core.windows.net; do
    if covered "$h" "$conf"; then bad "$h must not be on the proxy allowlist"; else ok "$h is not on the proxy allowlist"; fi
done

# 6. every gcloud call is impersonated, in project himmel-ci, never the default VPC.
total="$(grep -c '^GCLOUD ' "$STUB_LOG")"
imp="$(grep '^GCLOUD ' "$STUB_LOG" | grep -c -- "--impersonate-service-account=$SA")"
prj="$(grep '^GCLOUD ' "$STUB_LOG" | grep -c -- '--project=himmel-ci')"
if [ "$total" -gt 0 ] && [ "$total" -eq "$imp" ] && [ "$total" -eq "$prj" ]; then ok "all $total gcloud calls impersonate the runner SA in himmel-ci"; else bad "calls=$total impersonated=$imp project=$prj"; fi
if grep '^GCLOUD ' "$STUB_LOG" | grep -q -E '(network|networks|--network)[= ]default( |$)'; then bad "a call targets the default VPC"; else ok "no call targets the default VPC"; fi

# 7. net-up is idempotent: with everything present it creates nothing, updates every
#    rule, and refreshes the proxy's startup script without recreating the VM.
export STUB_EXISTS=1
rc="$(run net-up)"
if [ "$rc" -eq 0 ] && ! grep -q -E ' create ' "$STUB_LOG"; then ok "net-up on an existing network creates nothing"; else bad "idempotency: rc=$rc creates=$(grep -c ' create ' "$STUB_LOG")"; fi
n_upd="$(grep -c 'network-firewall-policies rules update' "$STUB_LOG")"
if [ "$n_upd" -eq 6 ]; then ok "net-up on existing rules updates all 6 in place, so an edited allowlist is deployed"; else bad "rules update count: $n_upd"; fi
if grep -q 'instances add-metadata himmel-ci-proxy .*--metadata-from-file=startup-script=' "$STUB_LOG" && grep -q -E '^acl allowed_hosts dstdomain' "$STUB_LOG.startup" \
    && ! grep -q 'instances reset' "$STUB_LOG"; then ok "net-up refreshes the proxy startup script in place and does not reset the VM"; else bad "no startup-script refresh on an existing proxy"; fi
unset STUB_EXISTS

# 8. a failing create fails net-up (no silent half-built network).
export STUB_FAIL="routers create"
rc="$(run net-up)"
if [ "$rc" -ne 0 ] && ! grep -q 'network-firewall-policies' "$STUB_LOG"; then ok "net-up stops at the first failed create"; else bad "failed router create: rc=$rc"; fi
unset STUB_FAIL
export STUB_FAIL="instances create"
rc="$(run net-up)"
if [ "$rc" -ne 0 ] && ! grep -q 'network-firewall-policies create' "$STUB_LOG"; then ok "net-up never builds the policy when the proxy VM fails"; else bad "failed proxy create: rc=$rc"; fi
unset STUB_FAIL

# 9. debug-on adds ONLY the IAP rule; debug-off removes ONLY it.
rc="$(run debug-on)"
n_calls="$(grep -c '^GCLOUD ' "$STUB_LOG")"
iap="$(rules_create)"
if [ "$rc" -eq 0 ] && echo "$iap" | grep -q -- '--src-ip-ranges=35.235.240.0/20' && echo "$iap" | grep -q -- '--layer4-configs=tcp:22' \
    && echo "$iap" | grep -q -- '--direction=INGRESS' && echo "$iap" | grep -q -- '--action=allow'; then ok "debug-on creates the IAP-only tcp:22 allow rule"; else bad "debug-on: rc=$rc rule=$iap"; fi
if [ "$(echo "$iap" | grep -c .)" -eq 1 ] && ! grep -q -E 'networks|routers|associations|instances|rules delete|rules update' "$STUB_LOG"; then ok "debug-on touches nothing but that rule ($n_calls calls)"; else bad "debug-on touched more than the IAP rule"; fi
export STUB_EXISTS=1
rc="$(run debug-off)"
if [ "$rc" -eq 0 ] && [ "$(grep -c 'network-firewall-policies rules delete' "$STUB_LOG")" -eq 1 ] && ! grep -q -E ' create |networks|routers|instances' "$STUB_LOG"; then ok "debug-off deletes exactly one rule and creates nothing"; else bad "debug-off: rc=$rc"; fi
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
order="$(grep -o -E 'associations delete|network-firewall-policies delete|instances delete|nats delete|routers delete|subnets delete|networks delete' "$STUB_LOG" | tr '\n' ',')"
want="nats delete,routers delete,associations delete,network-firewall-policies delete,instances delete,subnets delete,networks delete,"
if [ "$order" = "$want" ]; then ok "net-down cuts NAT before detaching the policy, then deletes in dependency order, proxy VM included"; else bad "net-down order: $order"; fi
export GCP_NET_ZONE=us-east1-b GCP_NET_REGION=us-east1
unset STUB_EXISTS
rc="$(run net-up)"
if [ "$rc" -eq 0 ] && grep -F 'instances create' "$STUB_LOG" | grep -q -F -- '--zone=us-east1-b'; then ok "GCP_NET_ZONE places the proxy in a valid zone of an overridden region"; else bad "zone override: rc=$rc"; fi
unset GCP_NET_ZONE GCP_NET_REGION
export STUB_EXISTS=1
grep '^GCLOUD ' "$STUB_LOG" | grep -q -E ' (delete|create) .*default' && bad "net-down touched a default resource" || ok "net-down never touches default"
unset STUB_EXISTS

# 11. status reads and never writes, and shows the proxy.
export STUB_EXISTS=1
rc="$(run status)"
if [ "$rc" -eq 0 ] && ! grep -q -E ' (create|delete|update) ' "$STUB_LOG" && grep -q 'describe' "$STUB_LOG"; then ok "status only reads"; else bad "status: rc=$rc"; fi
if grep -q -E '^proxy himmel-ci-proxy.*present' "$T/out"; then ok "status shows the proxy VM"; else bad "status lacks the proxy line: $(cat "$T/out")"; fi
unset STUB_EXISTS

# 12. a failed lookup (permission, auth, API) is not "absent": nothing is created
# or deleted on it, the command fails, and status reports it as unknown.
export STUB_DESCRIBE_ERR=1
rc="$(run debug-off)"
if [ "$rc" -ne 0 ] && ! grep -q -E ' (delete|create|update) ' "$STUB_LOG"; then ok "debug-off fails on a lookup error instead of reporting the rule absent"; else bad "debug-off lookup error: rc=$rc"; fi
rc="$(run net-up)"
if [ "$rc" -ne 0 ] && ! grep -q -E ' (delete|create|update|add-metadata) ' "$STUB_LOG"; then ok "net-up creates nothing on a lookup error"; else bad "net-up lookup error: rc=$rc"; fi
rc="$(run net-down)"
if [ "$rc" -ne 0 ] && ! grep -q -E ' (delete|create|update) ' "$STUB_LOG"; then ok "net-down deletes nothing on a lookup error"; else bad "net-down lookup error: rc=$rc"; fi
rc="$(run status)"
if [ "$rc" -eq 0 ] && grep -q 'unknown' "$T/out" && ! grep -q 'absent' "$T/out"; then ok "status reports a failed lookup as unknown"; else bad "status lookup error: rc=$rc out=$(cat "$T/out")"; fi
unset STUB_DESCRIBE_ERR

# 13. proxy-env prints what a runner exports to reach the proxy; no gcloud call.
rc="$(run proxy-env)"
env_out="$(cat "$T/out")"
if [ "$rc" -eq 0 ] && [ ! -s "$STUB_LOG" ] && echo "$env_out" | grep -q -F "HTTPS_PROXY=http://$PROXY_IP:3128" && echo "$env_out" | grep -q -F "HTTP_PROXY=http://$PROXY_IP:3128" \
    && echo "$env_out" | grep -E '^NO_PROXY=' | grep -q -F '169.254.169.254' && echo "$env_out" | grep -E '^NO_PROXY=' | grep -q -F '.googleapis.com' \
    && echo "$env_out" | grep -q -F "https_proxy=http://$PROXY_IP:3128" && echo "$env_out" | grep -q -F "http_proxy=http://$PROXY_IP:3128" \
    && echo "$env_out" | grep -E '^no_proxy=' | grep -q -F '169.254.169.254' && echo "$env_out" | grep -E '^no_proxy=' | grep -q -F '.googleapis.com'; then
    ok "proxy-env prints upper- and lowercase http(s)_proxy and a no_proxy for the metadata server and googleapis"
else bad "proxy-env: rc=$rc out=$env_out"; fi

# 14. gcloud's absent-rule error for a firewall-policy rule (captured from the live
# net-up) reads as absence, so the rules are created; a different priority error
# stays a failed lookup and creates nothing.
export STUB_RULE_ERR="ERROR: (gcloud.compute.network-firewall-policies.rules.describe) Invalid value for field 'priority': '1000'. The firewall policy does not contain a rule at priority 1000."
rc="$(run net-up)"
if [ "$rc" -eq 0 ] && [ -n "$(rules_create)" ]; then ok "an absent rule at a priority is read as absence and created"; else bad "absent-rule net-up: rc=$rc out=$(cat "$T/out")"; fi
export STUB_RULE_ERR="ERROR: (gcloud.compute.network-firewall-policies.rules.describe) Invalid value for field 'priority': '1000'. The priority is out of range."
rc="$(run net-up)"
if [ "$rc" -ne 0 ] && [ -z "$(rules_create)" ]; then ok "any other priority error stays a failed lookup"; else bad "other priority error: rc=$rc"; fi
unset STUB_RULE_ERR

# 15. the association is looked up on the policy (gcloud has no associations
# describe): present when the policy lists it, absent when it does not, and a
# failed policy lookup creates nothing.
export STUB_EXISTS=1 STUB_NO_ASSOC=1
rc="$(run net-up)"
if [ "$rc" -eq 0 ] && grep -q 'associations create' "$STUB_LOG" && ! grep -q 'associations describe' "$STUB_LOG"; then ok "a policy listing no association gets one created"; else bad "no-assoc net-up: rc=$rc out=$(cat "$T/out")"; fi
unset STUB_NO_ASSOC
rc="$(run net-up)"
if [ "$rc" -eq 0 ] && ! grep -q 'associations create' "$STUB_LOG"; then ok "a policy listing the association is left alone"; else bad "assoc-present net-up: rc=$rc"; fi
export STUB_DESCRIBE_ERR=1
rc="$(run net-down)"
if [ "$rc" -ne 0 ] && ! grep -q 'associations delete' "$STUB_LOG"; then ok "a failed policy lookup deletes no association"; else bad "assoc lookup error net-down: rc=$rc"; fi
unset STUB_DESCRIBE_ERR
rc="$(run status)"
if [ "$rc" -eq 0 ] && grep -q -E '^association himmel-ci-net-assoc: present' "$T/out"; then ok "status reads the association off the policy"; else bad "status association: rc=$rc out=$(cat "$T/out")"; fi
unset STUB_EXISTS

[ "$fails" -eq 0 ] || { echo "$fails case(s) failed" >&2; exit 1; }
echo "all cases passed"
