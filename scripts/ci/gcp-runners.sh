#!/usr/bin/env bash
# gcp-runners.sh -- the ephemeral GCP spot CI runner pool.
# Run it on the station.
#
#   bash scripts/ci/gcp-runners.sh up [N]   top the pool back up to N live VMs (default 2, max 4)
#   bash scripts/ci/gcp-runners.sh down     delete every pool VM, deregister offline gcp runners
#   bash scripts/ci/gcp-runners.sh status   list pool VMs and registered gcp runners
#
# Each VM is a SPOT instance (--max-run-duration, termination action DELETE)
# running gcp-runner-startup.sh: one --ephemeral runner labelled gcp, one job,
# then power off. ci.yml routes shell-unit-shard to [self-hosted, gcp] while
# repo variable CI_GCP is 'on' (push, dispatch, same-repo pull_request only);
# `gh variable set CI_GCP --body off` is the instant kill switch.
#
# No service-account key exists (org policy): every gcloud call impersonates
# the runner SA from the operator's own gcloud login. The runner VMs get no SA
# and no scopes. The 1 h registration token reaches a VM as a metadata FILE,
# never an argv.
#
# ponytail: pool size is whatever `up` was last told, topped up by hand; upgrade
# to an autoscaling timer, a budget kill switch and a regional CPU quota pin
# (follow-up ticket).
set -u

REPO="${GCP_RUNNERS_REPO:-yotamleo/Himmel}"
PROJECT="${GCP_RUNNERS_PROJECT:-himmel-ci}"
SA="${GCP_RUNNERS_SA:-himmel-ci-runner@himmel-ci.iam.gserviceaccount.com}"
ZONE="${GCP_RUNNERS_ZONE:-us-central1-a}"
MACHINE="${GCP_RUNNERS_MACHINE:-e2-standard-2}"
MAX_RUN="30m"
POOL_LABEL="himmel-ci-runner=gcp"
MAX_N=4
GCLOUD="${GCLOUD:-$HOME/google-cloud-sdk/bin/gcloud}"
GH="${GH:-gh}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

die() { echo "gcp-runners: $1" >&2; exit "${2:-1}"; }

gc() { "$GCLOUD" "$@" --project="$PROJECT" --impersonate-service-account="$SA"; }

# pool_vms -> "name status" per pool VM
pool_vms() { gc compute instances list --filter="labels.himmel-ci-runner=gcp" --format="value(name,status)"; }

cmd_up() {
    local n="${1:-2}"
    case "$n" in ''|*[!0-9]*) die "up: N must be a positive integer, got '$n'" 2 ;; esac
    [ "$n" -ge 1 ] || die "up: N must be at least 1" 2
    [ "$n" -le "$MAX_N" ] || die "up: N=$n exceeds the hard max $MAX_N (the trial caps 8 vCPUs)" 2

    local live=0 name status
    while read -r name status; do
        [ -n "$name" ] || continue
        case "$status" in
            TERMINATED|STOPPED|SUSPENDED) gc compute instances delete "$name" --zone="$ZONE" --quiet ;;
            *) live=$((live + 1)) ;;
        esac
    done < <(pool_vms)

    local need=$((n - live))
    [ "$need" -gt 0 ] || { echo "gcp-runners: pool already has $live live VM(s), nothing to create"; return 0; }

    tokfile="$(mktemp -t gcp-runners.XXXXXX)" || die "mktemp failed"
    urlfile="$tokfile.url"
    trap 'rm -f "$tokfile" "$urlfile"' EXIT
    chmod 600 "$tokfile"
    "$GH" api -X POST "repos/$REPO/actions/runners/registration-token" --jq .token > "$tokfile" || die "registration token request failed"
    [ -s "$tokfile" ] || die "empty registration token"
    printf 'https://github.com/%s' "$REPO" > "$urlfile"

    local i stamp
    stamp="$(date +%m%d%H%M%S)"
    for i in $(seq 1 "$need"); do
        gc compute instances create "himmel-ci-$stamp-$i" \
            --zone="$ZONE" --machine-type="$MACHINE" \
            --image-family=ubuntu-2404-lts-amd64 --image-project=ubuntu-os-cloud \
            --boot-disk-size=50GB \
            --provisioning-model=SPOT --max-run-duration="$MAX_RUN" --instance-termination-action=DELETE \
            --labels="$POOL_LABEL" \
            --no-service-account --no-scopes \
            --metadata-from-file="startup-script=$HERE/gcp-runner-startup.sh,reg-token=$tokfile,runner-url=$urlfile" \
            || die "instances create failed for himmel-ci-$stamp-$i"
    done
    echo "gcp-runners: created $need VM(s); pool target $n"
}

cmd_down() {
    local name status
    while read -r name status; do
        [ -n "$name" ] || continue
        gc compute instances delete "$name" --zone="$ZONE" --quiet
    done < <(pool_vms)
    local id
    while read -r id; do
        [ -n "$id" ] || continue
        "$GH" api -X DELETE "repos/$REPO/actions/runners/$id"
    done < <("$GH" api "repos/$REPO/actions/runners" --jq '.runners[] | select(.status=="offline" and any(.labels[]; .name=="gcp")) | .id')
    echo "gcp-runners: pool deleted"
}

cmd_status() {
    pool_vms
    "$GH" api "repos/$REPO/actions/runners" --jq '.runners[] | select(any(.labels[]; .name=="gcp")) | "\(.name) \(.status)"'
}

case "${1:-}" in
    up) shift; cmd_up "$@" ;;
    down) cmd_down ;;
    status) cmd_status ;;
    *) die "usage: gcp-runners.sh up [N] | down | status" 2 ;;
esac
