#!/usr/bin/env bash
# gcp-net.sh -- the locked-down network for the ephemeral GCP CI runners.
# Run it on the station.
#
#   bash scripts/ci/gcp-net.sh net-up      create the VPC, subnet, NAT, proxy VM and firewall policy (idempotent)
#   bash scripts/ci/gcp-net.sh net-down    delete all of it, in reverse order
#   bash scripts/ci/gcp-net.sh status      what exists, and whether the IAP debug rule is on
#   bash scripts/ci/gcp-net.sh debug-on    allow IAP-only SSH (35.235.240.0/20, tcp:22) into the runners
#   bash scripts/ci/gcp-net.sh debug-off   remove that rule (the default state)
#   bash scripts/ci/gcp-net.sh proxy-env   print the HTTPS_PROXY/HTTP_PROXY/NO_PROXY (and lowercase) a runner exports
#
# gcp-runners.sh places its VMs on the subnet named himmel-ci-net with no
# external IP; that name is the only coupling between the two scripts.
#
# The model: a custom-mode VPC (no default allow rules), no external IPs, and ONE
# global network firewall policy that is the whole rule set. Ingress is denied
# outright. A runner's only way out is tcp:3128 to ONE squid proxy VM on the same
# subnet (fixed internal address, no external IP, egress through Cloud NAT); the
# proxy allows the hosts in PROXY_HOSTS and refuses everything else, which is how
# wildcard hosts such as .githubusercontent.com are allowed (Standard-tier FQDN
# firewall objects reject wildcards). The one FQDN rule left is the exact Google
# API hosts, reached over Private Google Access. Both deny rules log, so a blocked
# connection is visible in Cloud Logging.
#
# The allowlist is data: edit PROXY_HOSTS (a leading dot means the domain and its
# subdomains; sources: docs.github.com "Communication requirements for
# self-hosted runners", .github/workflows/ci.yml and gcp-runner-startup.sh) or
# GCP_HOSTS, then re-run net-up.
#
# No service-account key exists (org policy): every gcloud call impersonates
# the runner SA from the operator's own gcloud login.
#
# ponytail: the allowlist is a static host list and a changed one reaches an
# existing proxy only at its next boot (net-up refreshes the startup script, it
# does not reset the VM); upgrade to a reset-on-change step if the list churns.
# ponytail: one e2-micro proxy is a single point of failure with limited
# throughput; upgrade to a larger machine type or a managed instance group if
# runner traffic outgrows it.
set -u

PROJECT="${GCP_NET_PROJECT:-himmel-ci}"
SA="${GCP_NET_SA:-himmel-ci-runner@himmel-ci.iam.gserviceaccount.com}"
REGION="${GCP_NET_REGION:-us-central1}"
NET="himmel-ci-net"
SUBNET="himmel-ci-net"
RANGE="10.10.0.0/24"  # leak-allow: private-lan-ip the runner subnet's own CIDR in a dedicated VPC
ROUTER="himmel-ci-router"
NAT="himmel-ci-nat"
POLICY="himmel-ci-net-policy"
ASSOC="himmel-ci-net-assoc"
IAP_RANGE="35.235.240.0/20"
PROXY_VM="himmel-ci-proxy"
PROXY_ZONE="${GCP_NET_ZONE:-${REGION}-a}"
PROXY_IP="10.10.0.10"  # leak-allow: private-lan-ip the proxy's fixed address inside the dedicated runner VPC
PROXY_PORT=3128
GCLOUD="${GCLOUD:-$HOME/google-cloud-sdk/bin/gcloud}"

# Rule priorities: lower wins. Allows sit below the denies.
PRIO_IAP=500
PRIO_RUNNER_PROXY=1000
PRIO_PROXY_IN=1010
PRIO_PROXY_OUT=1015
PRIO_GCP=1020
PRIO_DENY_IN=60000
PRIO_DENY_OUT=60001

# Squid dstdomain entries: a leading dot is the domain and every subdomain. Never
# list a name and a dot-suffix that covers it (squid rejects the overlap).
PROXY_HOSTS=(
    github.com api.github.com codeload.github.com ghcr.io
    github-cloud.s3.amazonaws.com dependabot-actions.githubapp.com api.snapcraft.io
    .githubusercontent.com .pkg.github.com .blob.core.windows.net
    registry.npmjs.org pypi.org files.pythonhosted.org nodejs.org
    archive.ubuntu.com security.ubuntu.com "$REGION.gce.archive.ubuntu.com"
)
GCP_HOSTS=(
    oauth2.googleapis.com logging.googleapis.com monitoring.googleapis.com
    storage.googleapis.com compute.googleapis.com
)

die() { echo "gcp-net: $1" >&2; exit "${2:-1}"; }

gc() { "$GCLOUD" "$@" --project="$PROJECT" --impersonate-service-account="$SA"; }

# join_csv <host>... -> comma-joined
join_csv() { local IFS=,; echo "$*"; }

# present <describe args...>: 0 = present, 1 = confirmed absent (gcloud says not
# found), 2 = the lookup itself failed (auth, permission, API): never absence.
present() {
    local err
    err="$(gc "$@" 2>&1 > /dev/null)" && return 0
    case "$err" in
        *[Nn]ot\ [Ff]ound*|*NOT_FOUND*|*"does not exist"*|*"does not contain a rule at priority"*) return 1 ;;
    esac
    echo "gcp-net: lookup failed: $err" >&2
    return 2
}

# ensure <label> <describe args...> -- <create args...>: create only when confirmed absent.
ensure() {
    local label="$1"; shift
    local -a dsc=()
    while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do dsc+=("$1"); shift; done
    shift
    present "${dsc[@]}"
    case $? in
        0) echo "gcp-net: $label exists" ;;
        1) gc "$@" || die "creating $label failed"
           echo "gcp-net: $label created" ;;
        *) die "checking $label failed" ;;
    esac
}

# drop <label> <describe args...> -- <delete args...>: delete only when confirmed present.
drop() {
    local label="$1"; shift
    local -a dsc=()
    while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do dsc+=("$1"); shift; done
    shift
    present "${dsc[@]}"
    case $? in
        0) gc "$@" || die "deleting $label failed"
           echo "gcp-net: $label deleted" ;;
        1) echo "gcp-net: $label absent" ;;
        *) die "checking $label failed" ;;
    esac
}

POL=(--firewall-policy="$POLICY" --global-firewall-policy)

# rule <priority> <label> <rule args...>: create the rule, or update it in place
# when it exists, so an edited allowlist reaches the deployed policy on re-run.
rule() {
    local prio="$1" label="$2"; shift 2
    present compute network-firewall-policies rules describe "$prio" "${POL[@]}"
    case $? in
        0) gc compute network-firewall-policies rules update "$prio" "${POL[@]}" "$@" \
               || die "updating rule $prio ($label) failed"
           echo "gcp-net: rule $prio ($label) updated" ;;
        1) gc compute network-firewall-policies rules create "$prio" "${POL[@]}" "$@" \
               || die "creating rule $prio ($label) failed"
           echo "gcp-net: rule $prio ($label) created" ;;
        *) die "checking rule $prio ($label) failed" ;;
    esac
}

# startup_script <file>: the proxy VM's boot script, which installs squid and
# writes a config that allows only PROXY_HOSTS on ports 80/443.
startup_script() {
    local h
    {
        echo '#!/bin/bash'
        echo 'set -e'
        echo 'export DEBIAN_FRONTEND=noninteractive'
        echo 'apt-get update -qq'
        echo 'apt-get install -y -qq squid'
        echo "cat > /etc/squid/squid.conf <<'SQUIDCONF'"
        echo "http_port $PROXY_PORT"
        echo 'acl safe_ports port 80 443'
        echo 'http_access deny !safe_ports'
        # -n: match the name the client sent, never a reverse-DNS name of an IP literal.
        echo 'acl ip4_dst dstdom_regex -n ^[0-9.]+$'
        echo 'acl ip6_dst dstdom_regex -n :'
        echo 'http_access deny ip4_dst'
        echo 'http_access deny ip6_dst'
        for h in "${PROXY_HOSTS[@]}"; do echo "acl allowed_hosts dstdomain -n $h"; done
        echo 'http_access allow allowed_hosts'
        echo 'http_access deny all'
        echo 'cache deny all'
        echo 'forwarded_for delete'
        echo 'via off'
        echo 'SQUIDCONF'
        echo 'systemctl enable squid'  # t13b-ok: text written into the proxy VM startup script, not run here
        echo 'systemctl restart squid'
    } > "$1"
}

# proxy_vm <script file>: create the squid VM when confirmed absent, else refresh
# its startup script in place.
proxy_vm() {
    present compute instances describe "$PROXY_VM" --zone="$PROXY_ZONE"
    case $? in
        0) gc compute instances add-metadata "$PROXY_VM" --zone="$PROXY_ZONE" \
               --metadata-from-file=startup-script="$1" || die "refreshing the proxy startup script failed"
           echo "gcp-net: proxy $PROXY_VM exists; startup script refreshed (applies at its next boot)" ;;
        1) gc compute instances create "$PROXY_VM" --zone="$PROXY_ZONE" --machine-type=e2-micro \
               --subnet="$SUBNET" --private-network-ip="$PROXY_IP" --no-address \
               --boot-disk-type=pd-standard --image-family=debian-12 --image-project=debian-cloud \
               --shielded-secure-boot --shielded-vtpm --shielded-integrity-monitoring \
               --no-service-account --no-scopes \
               --metadata=block-project-ssh-keys=TRUE --metadata-from-file=startup-script="$1" \
               || die "creating proxy $PROXY_VM failed"
           echo "gcp-net: proxy $PROXY_VM created" ;;
        *) die "checking proxy $PROXY_VM failed" ;;
    esac
}

cmd_net_up() {
    local startup
    startup="$(mktemp -t gcp-net-startup.XXXXXX)" || die "mktemp failed"
    # shellcheck disable=SC2064
    trap "rm -f '$startup'" EXIT
    startup_script "$startup"

    ensure "network $NET" compute networks describe "$NET" -- \
        compute networks create "$NET" --subnet-mode=custom --bgp-routing-mode=regional \
        --network-firewall-policy-enforcement-order=BEFORE_CLASSIC_FIREWALL
    ensure "subnet $SUBNET" compute networks subnets describe "$SUBNET" --region="$REGION" -- \
        compute networks subnets create "$SUBNET" --network="$NET" --region="$REGION" \
        --range="$RANGE" --enable-private-ip-google-access
    ensure "router $ROUTER" compute routers describe "$ROUTER" --region="$REGION" -- \
        compute routers create "$ROUTER" --network="$NET" --region="$REGION"
    ensure "nat $NAT" compute routers nats describe "$NAT" --router="$ROUTER" --region="$REGION" -- \
        compute routers nats create "$NAT" --router="$ROUTER" --region="$REGION" \
        --auto-allocate-nat-external-ips --nat-all-subnet-ip-ranges \
        --enable-logging --log-filter=ERRORS_ONLY
    proxy_vm "$startup"
    ensure "firewall policy $POLICY" compute network-firewall-policies describe "$POLICY" --global -- \
        compute network-firewall-policies create "$POLICY" --global \
        --description="himmel-ci runners: deny all ingress, egress only to the allowlisting proxy"

    rule "$PRIO_RUNNER_PROXY" "runners to proxy" --direction=EGRESS --action=allow \
        --layer4-configs=tcp:"$PROXY_PORT" --src-ip-ranges="$RANGE" --dest-ip-ranges="$PROXY_IP/32" \
        --description="the only runner egress: the allowlisting proxy"
    rule "$PRIO_PROXY_IN" "proxy ingress" --direction=INGRESS --action=allow \
        --layer4-configs=tcp:"$PROXY_PORT" --src-ip-ranges="$RANGE" --dest-ip-ranges="$PROXY_IP/32" \
        --description="runners reach the proxy port"
    rule "$PRIO_PROXY_OUT" "proxy to the web" --direction=EGRESS --action=allow \
        --layer4-configs=tcp:80,tcp:443 --src-ip-ranges="$PROXY_IP/32" --dest-ip-ranges=0.0.0.0/0 \
        --description="the proxy host's own egress (squid filters by hostname)"
    # ponytail: an FQDN rule matches the hosts' resolved IPs, which Google shares across *.googleapis.com, so it can admit a sibling API host; move these hosts behind the proxy if that matters
    rule "$PRIO_GCP" "google apis egress" --direction=EGRESS --action=allow \
        --layer4-configs=tcp:443 --dest-fqdns="$(join_csv "${GCP_HOSTS[@]}")" \
        --description="Google APIs, exact hosts, via Private Google Access"
    rule "$PRIO_DENY_IN" "deny all ingress" --direction=INGRESS --action=deny \
        --layer4-configs=all --src-ip-ranges=0.0.0.0/0 --enable-logging \
        --description="deny all ingress"
    rule "$PRIO_DENY_OUT" "deny all egress" --direction=EGRESS --action=deny \
        --layer4-configs=all --dest-ip-ranges=0.0.0.0/0 --enable-logging \
        --description="deny all egress not allowlisted above"

    # Last, so the network is never enforced by a half-built policy.
    ensure "policy association $ASSOC" \
        compute network-firewall-policies associations describe --name="$ASSOC" "${POL[@]}" -- \
        compute network-firewall-policies associations create --name="$ASSOC" "${POL[@]}" --network="$NET"
    echo "gcp-net: net-up done; runners belong on subnet $SUBNET ($REGION) with --no-address and the output of: bash scripts/ci/gcp-net.sh proxy-env"
}

cmd_net_down() {
    # NAT and router first: cut the internet before the deny policy comes off.
    drop "nat $NAT" compute routers nats describe "$NAT" --router="$ROUTER" --region="$REGION" -- \
        compute routers nats delete "$NAT" --router="$ROUTER" --region="$REGION" --quiet
    drop "router $ROUTER" compute routers describe "$ROUTER" --region="$REGION" -- \
        compute routers delete "$ROUTER" --region="$REGION" --quiet
    drop "policy association $ASSOC" \
        compute network-firewall-policies associations describe --name="$ASSOC" "${POL[@]}" -- \
        compute network-firewall-policies associations delete "$ASSOC" "${POL[@]}"
    drop "firewall policy $POLICY" compute network-firewall-policies describe "$POLICY" --global -- \
        compute network-firewall-policies delete "$POLICY" --global --quiet
    drop "proxy $PROXY_VM" compute instances describe "$PROXY_VM" --zone="$PROXY_ZONE" -- \
        compute instances delete "$PROXY_VM" --zone="$PROXY_ZONE" --quiet
    drop "subnet $SUBNET" compute networks subnets describe "$SUBNET" --region="$REGION" -- \
        compute networks subnets delete "$SUBNET" --region="$REGION" --quiet
    drop "network $NET" compute networks describe "$NET" -- \
        compute networks delete "$NET" --quiet
}

cmd_status() {
    probe() {
        present "$@" 2> /dev/null
        case $? in 0) echo "present" ;; 1) echo "absent" ;; *) echo "unknown (lookup failed)" ;; esac
    }
    echo "network $NET: $(probe compute networks describe "$NET")"
    echo "subnet $SUBNET ($REGION): $(probe compute networks subnets describe "$SUBNET" --region="$REGION")"
    echo "router $ROUTER: $(probe compute routers describe "$ROUTER" --region="$REGION")"
    echo "nat $NAT: $(probe compute routers nats describe "$NAT" --router="$ROUTER" --region="$REGION")"
    echo "proxy $PROXY_VM ($PROXY_IP:$PROXY_PORT): $(probe compute instances describe "$PROXY_VM" --zone="$PROXY_ZONE")"
    echo "policy $POLICY: $(probe compute network-firewall-policies describe "$POLICY" --global)"
    echo "association $ASSOC: $(probe compute network-firewall-policies associations describe --name="$ASSOC" "${POL[@]}")"
    echo "IAP debug rule $PRIO_IAP: $(probe compute network-firewall-policies rules describe "$PRIO_IAP" "${POL[@]}")"
}

cmd_debug_on() {
    rule "$PRIO_IAP" "IAP ssh" --direction=INGRESS --action=allow \
        --layer4-configs=tcp:22 --src-ip-ranges="$IAP_RANGE" \
        --description="debug: IAP-only SSH (OS Login); remove with debug-off"
}

cmd_debug_off() {
    drop "rule $PRIO_IAP (IAP ssh)" \
        compute network-firewall-policies rules describe "$PRIO_IAP" "${POL[@]}" -- \
        compute network-firewall-policies rules delete "$PRIO_IAP" "${POL[@]}"
}

cmd_proxy_env() {
    # Both cases: the Linux runner, apt and curl read the lowercase names.
    local no_proxy="169.254.169.254,metadata.google.internal,.googleapis.com"
    echo "HTTPS_PROXY=http://$PROXY_IP:$PROXY_PORT"
    echo "HTTP_PROXY=http://$PROXY_IP:$PROXY_PORT"
    echo "NO_PROXY=$no_proxy"
    echo "https_proxy=http://$PROXY_IP:$PROXY_PORT"
    echo "http_proxy=http://$PROXY_IP:$PROXY_PORT"
    echo "no_proxy=$no_proxy"
}

case "${1:-}" in
    net-up) cmd_net_up ;;
    net-down) cmd_net_down ;;
    status) cmd_status ;;
    debug-on) cmd_debug_on ;;
    debug-off) cmd_debug_off ;;
    proxy-env) cmd_proxy_env ;;
    *) die "usage: gcp-net.sh net-up | net-down | status | debug-on | debug-off | proxy-env" 2 ;;
esac
