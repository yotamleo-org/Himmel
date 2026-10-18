#!/usr/bin/env bash
# gcp-net.sh -- the locked-down network for the ephemeral GCP CI runners.
# Run it on the station.
#
#   bash scripts/ci/gcp-net.sh net-up      create the VPC, subnet, NAT and firewall policy (idempotent)
#   bash scripts/ci/gcp-net.sh net-down    delete all of it, in reverse order
#   bash scripts/ci/gcp-net.sh status      what exists, and whether the IAP debug rule is on
#   bash scripts/ci/gcp-net.sh debug-on    allow IAP-only SSH (35.235.240.0/20, tcp:22) into the runners
#   bash scripts/ci/gcp-net.sh debug-off   remove that rule (the default state)
#
# gcp-runners.sh places its VMs on the subnet named himmel-ci-net with no
# external IP; that name is the only coupling between the two scripts.
#
# The model: a custom-mode VPC (no default allow rules), no external IPs, Cloud
# NAT for egress, and ONE global network firewall policy that is the whole rule
# set. Ingress is denied outright. Egress is denied by default and opened only
# to FQDNs: GitHub's self-hosted runner hosts, the package hosts ci.yml and the
# runner startup fetch, and the Google APIs the VM uses. No allow rule names
# 0.0.0.0/0. Both deny rules log, so a blocked connection is visible in Cloud
# Logging. FQDN objects need no extra API on the Standard tier; a rule that the
# project refuses fails net-up loudly, there is no fallback to IP ranges.
#
# Sources of the allowlist (edit the three lists below, nothing else):
#   GITHUB_HOSTS  docs.github.com "Communication requirements for self-hosted runners"
#   PKG_HOSTS     .github/workflows/ci.yml (npm ci, pip, setup-bun/-node, gitleaks) and
#                 gcp-runner-startup.sh (apt-get, pip)
#   GCP_HOSTS     Google APIs a runner VM or the ops tooling talks to
#
# No service-account key exists (org policy): every gcloud call impersonates
# the runner SA from the operator's own gcloud login.
#
# ponytail: the allowlist is a static host list, so a new package source needs a
# net-up re-run; upgrade to a per-job proxy that logs the observed hosts
# (follow-up if the list churns).
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
GCLOUD="${GCLOUD:-$HOME/google-cloud-sdk/bin/gcloud}"

# Rule priorities: lower wins. Allows sit below the denies.
PRIO_IAP=500
PRIO_GITHUB=1000
PRIO_PKG=1010
PRIO_GCP=1020
PRIO_DENY_IN=60000
PRIO_DENY_OUT=60001

GITHUB_HOSTS=(
    github.com api.github.com codeload.github.com
    '*.actions.githubusercontent.com' results-receiver.actions.githubusercontent.com
    objects.githubusercontent.com objects-origin.githubusercontent.com
    github-releases.githubusercontent.com github-registry-files.githubusercontent.com
    release-assets.githubusercontent.com github-cloud.githubusercontent.com
    pkg-containers.githubusercontent.com '*.pkg.github.com' ghcr.io
    github-cloud.s3.amazonaws.com dependabot-actions.githubapp.com api.snapcraft.io
    '*.blob.core.windows.net' '*.core.windows.net'
)
PKG_HOSTS=(
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

# ensure <label> <describe args...> -- <create args...>: create only when describe fails.
ensure() {
    local label="$1"; shift
    local -a dsc=()
    while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do dsc+=("$1"); shift; done
    shift
    if gc "${dsc[@]}" > /dev/null 2>&1; then
        echo "gcp-net: $label exists"
    else
        gc "$@" || die "creating $label failed"
        echo "gcp-net: $label created"
    fi
}

# drop <label> <describe args...> -- <delete args...>: delete only when describe succeeds.
drop() {
    local label="$1"; shift
    local -a dsc=()
    while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do dsc+=("$1"); shift; done
    shift
    if gc "${dsc[@]}" > /dev/null 2>&1; then
        gc "$@" || die "deleting $label failed"
        echo "gcp-net: $label deleted"
    else
        echo "gcp-net: $label absent"
    fi
}

POL=(--firewall-policy="$POLICY" --global-firewall-policy)

# rule <priority> <label> <rule-create args...>
rule() {
    local prio="$1" label="$2"; shift 2
    ensure "rule $prio ($label)" \
        compute network-firewall-policies rules describe "$prio" "${POL[@]}" -- \
        compute network-firewall-policies rules create "$prio" "${POL[@]}" "$@"
}

cmd_net_up() {
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
    ensure "firewall policy $POLICY" compute network-firewall-policies describe "$POLICY" --global -- \
        compute network-firewall-policies create "$POLICY" --global \
        --description="himmel-ci runners: deny all ingress, FQDN-allowlisted egress"

    rule "$PRIO_GITHUB" "github egress" --direction=EGRESS --action=allow \
        --layer4-configs=tcp:443 --dest-fqdns="$(join_csv "${GITHUB_HOSTS[@]}")" \
        --description="GitHub self-hosted runner hosts"
    rule "$PRIO_PKG" "package egress" --direction=EGRESS --action=allow \
        --layer4-configs=tcp:80,tcp:443 --dest-fqdns="$(join_csv "${PKG_HOSTS[@]}")" \
        --description="package hosts ci.yml and the runner startup fetch"
    rule "$PRIO_GCP" "google apis egress" --direction=EGRESS --action=allow \
        --layer4-configs=tcp:443 --dest-fqdns="$(join_csv "${GCP_HOSTS[@]}")" \
        --description="Google APIs"
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
    echo "gcp-net: net-up done; runners belong on subnet $SUBNET ($REGION) with --no-address"
}

cmd_net_down() {
    drop "policy association $ASSOC" \
        compute network-firewall-policies associations describe --name="$ASSOC" "${POL[@]}" -- \
        compute network-firewall-policies associations delete "$ASSOC" "${POL[@]}"
    drop "firewall policy $POLICY" compute network-firewall-policies describe "$POLICY" --global -- \
        compute network-firewall-policies delete "$POLICY" --global --quiet
    drop "nat $NAT" compute routers nats describe "$NAT" --router="$ROUTER" --region="$REGION" -- \
        compute routers nats delete "$NAT" --router="$ROUTER" --region="$REGION" --quiet
    drop "router $ROUTER" compute routers describe "$ROUTER" --region="$REGION" -- \
        compute routers delete "$ROUTER" --region="$REGION" --quiet
    drop "subnet $SUBNET" compute networks subnets describe "$SUBNET" --region="$REGION" -- \
        compute networks subnets delete "$SUBNET" --region="$REGION" --quiet
    drop "network $NET" compute networks describe "$NET" -- \
        compute networks delete "$NET" --quiet
}

cmd_status() {
    probe() { if gc "$@" > /dev/null 2>&1; then echo "present"; else echo "absent"; fi; }
    echo "network $NET: $(probe compute networks describe "$NET")"
    echo "subnet $SUBNET ($REGION): $(probe compute networks subnets describe "$SUBNET" --region="$REGION")"
    echo "router $ROUTER: $(probe compute routers describe "$ROUTER" --region="$REGION")"
    echo "nat $NAT: $(probe compute routers nats describe "$NAT" --router="$ROUTER" --region="$REGION")"
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

case "${1:-}" in
    net-up) cmd_net_up ;;
    net-down) cmd_net_down ;;
    status) cmd_status ;;
    debug-on) cmd_debug_on ;;
    debug-off) cmd_debug_off ;;
    *) die "usage: gcp-net.sh net-up | net-down | status | debug-on | debug-off" 2 ;;
esac
