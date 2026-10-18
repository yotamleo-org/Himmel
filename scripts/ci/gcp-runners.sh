#!/usr/bin/env bash
# gcp-runners.sh -- the ephemeral GCP spot CI runner pool.
# Run it on the station.
#
#   bash scripts/ci/gcp-runners.sh up [N]   top the pool back up to N live VMs (default 2, max 4)
#   bash scripts/ci/gcp-runners.sh watch N [--interval 60]   foreground loop: re-run `up N` every interval
#                                           while CI_GCP is on; on CI_GCP off or SIGTERM run `down` and exit
#   bash scripts/ci/gcp-runners.sh down     delete every pool VM, deregister offline gcp runners
#   bash scripts/ci/gcp-runners.sh status   list pool VMs and registered gcp runners
#
# Each VM is a SPOT instance (--max-run-duration, termination action DELETE)
# running gcp-runner-startup.sh: one --ephemeral runner labelled gcp, one job,
# then power off. ci.yml routes shell-unit-shard to [self-hosted, gcp] while
# repo variable CI_GCP is 'on' (dispatch or same-repo pull_request, operator accounts only);
# `gh variable set CI_GCP --body off` is the instant kill switch.
#
# No service-account key exists (org policy): every gcloud call impersonates
# the runner SA from the operator's own gcloud login. The runner VMs get no SA
# and no scopes. Each VM gets its OWN just-in-time runner config (one runner,
# one job, no shared token) as a metadata FILE, never an argv, plus the runner-side
# fork guard scripts/vm/ci-runner/job-started-hook.sh (ACTIONS_RUNNER_HOOK_JOB_STARTED).
# Once a runner is online `up` removes the jit-config key from that VM's metadata, so
# the config does not outlive its read; the proxy env of gcp-net.sh rides along as the
# proxy-env metadata file (the subnet has no other way out).
#
# ponytail: pool size is whatever `up` was last told (gcp-runner-autoscale.sh tops it up
# from the queue depth); upgrade to a budget kill switch and a regional CPU quota pin
# (operator-side, after the live proof).
set -u

REPO="${GCP_RUNNERS_REPO:-yotamleo/Himmel}"
PROJECT="${GCP_RUNNERS_PROJECT:-himmel-ci}"
SA="${GCP_RUNNERS_SA:-himmel-ci-runner@himmel-ci.iam.gserviceaccount.com}"
ZONE="${GCP_RUNNERS_ZONE:-us-central1-a}"
MACHINE="${GCP_RUNNERS_MACHINE:-e2-standard-2}"
MAX_RUN="45m"
ONLINE_WAIT="${GCP_RUNNERS_ONLINE_WAIT:-600}"
ONLINE_POLL="${GCP_RUNNERS_ONLINE_POLL:-10}"
POOL_LABEL="himmel-ci-runner=gcp"
MAX_N=4
NET="${GCP_RUNNERS_NET:-himmel-ci-net}"
LOCKFILE="${GCP_RUNNERS_LOCK:-${TMPDIR:-/tmp}/gcp-runners.lock}"
GCLOUD="${GCLOUD:-$HOME/google-cloud-sdk/bin/gcloud}"
GH="${GH:-gh}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

die() { echo "gcp-runners: $1" >&2; exit "${2:-1}"; }

gc() { "$GCLOUD" "$@" --project="$PROJECT" --impersonate-service-account="$SA"; }

# pool_vms -> "name status zone" per pool VM (zone falls back to $ZONE when empty)
pool_vms() { gc compute instances list --filter="labels.himmel-ci-runner=gcp" --format="value(name,status,zone.basename())"; }

# need_net: runner VMs never use the default VPC; refuse until the dedicated subnet exists.
need_net() {
    gc compute networks subnets describe "$NET" --region="${ZONE%-*}" > /dev/null 2>&1 \
        || die "subnet $NET does not exist; create it with scripts/ci/gcp-net.sh first (never the default VPC)"
}

# drop_jit VM... -> wait until each VM's runner is online (the startup script has then
# read its config), then remove jit-config from that VM's metadata. A runner that never
# comes online within ONLINE_WAIT loses the key anyway: the config must not idle there.
# A key that cannot be removed gets its VM deleted; returns 1 if any VM could not be cleaned.
drop_jit() {
    local deadline=$((SECONDS + ONLINE_WAIT)) pending=("$@") left online vm failed=0
    while [ "${#pending[@]}" -gt 0 ]; do
        online="$("$GH" api --paginate "repos/$REPO/actions/runners" --jq '.runners[] | select(.status=="online") | .name')" || online=""
        left=()
        for vm in "${pending[@]}"; do
            if grep -qxF "$vm" <<< "$online" || [ "$SECONDS" -ge "$deadline" ]; then
                if ! gc compute instances remove-metadata "$vm" --zone="$ZONE" --keys=jit-config; then
                    echo "gcp-runners: could not remove jit-config from $vm, deleting it" >&2
                    gc compute instances delete "$vm" --zone="$ZONE" --quiet || echo "gcp-runners: could not delete $vm" >&2
                    failed=1
                fi
            else
                left+=("$vm")
            fi
        done
        pending=(${left[@]+"${left[@]}"})
        [ "${#pending[@]}" -eq 0 ] || sleep "$ONLINE_POLL"
    done
    return "$failed"
}

cmd_up() {
    local n="${1:-2}"
    case "$n" in ''|*[!0-9]*) die "up: N must be a positive integer, got '$n'" 2 ;; esac
    [ "$n" -ge 1 ] || die "up: N must be at least 1" 2
    [ "$n" -le "$MAX_N" ] || die "up: N=$n exceeds the hard max $MAX_N (the trial caps 8 vCPUs)" 2

    [ "${GCP_RUNNERS_UNAME:-$(uname -s)}" = Linux ] || die "up: Linux only (the pool lock needs flock)"
    need_net
    exec 9> "$LOCKFILE" || die "cannot open lock $LOCKFILE"
    flock -n 9 || die "another up is already running, refusing to count the pool twice"

    local live=0 name status zone vms
    vms="$(pool_vms)" || die "pool discovery failed, refusing to create VMs for an unknown pool"
    while read -r name status zone; do
        [ -n "$name" ] || continue
        case "$status" in
            TERMINATED|STOPPED|SUSPENDED) gc compute instances delete "$name" --zone="${zone:-$ZONE}" --quiet || die "could not delete stopped VM $name" ;;
            *) live=$((live + 1)) ;;
        esac
    done <<< "$vms"

    local need=$((n - live))
    [ "$need" -gt 0 ] || { echo "gcp-runners: pool already has $live live VM(s), nothing to create"; return 0; }

    local tmpd i stamp vm created=()
    # up_fail MSG -> strip jit-config from every VM already created, then die: no config outlives a failed up.
    up_fail() { [ "${#created[@]}" -eq 0 ] || ONLINE_WAIT=0 drop_jit "${created[@]}"; die "$1"; }
    tmpd="$(mktemp -d -t gcp-runners.XXXXXX)" || die "mktemp failed"
    # shellcheck disable=SC2064  # expand now: tmpd is local and gone when the trap fires
    trap "rm -rf '$tmpd'" EXIT
    chmod 700 "$tmpd"
    bash "$HERE/gcp-net.sh" proxy-env > "$tmpd/proxy-env" || die "gcp-net.sh proxy-env failed"
    [ -s "$tmpd/proxy-env" ] || die "empty proxy env"
    stamp="$(date +%m%d%H%M%S)"
    for i in $(seq 1 "$need"); do
        vm="himmel-ci-$stamp-$i"
        "$GH" api -X POST "repos/$REPO/actions/runners/generate-jitconfig" \
            -f "name=$vm" -F runner_group_id=1 -f 'labels[]=self-hosted' -f 'labels[]=gcp' --jq .encoded_jit_config > "$tmpd/$vm.jit" \
            || up_fail "JIT config request failed for $vm"
        [ -s "$tmpd/$vm.jit" ] || up_fail "empty JIT config for $vm"
        created+=("$vm")  # before the call: a create whose response was lost may still have made the VM
        gc compute instances create "$vm" \
            --zone="$ZONE" --machine-type="$MACHINE" \
            --image-family=ubuntu-2404-lts-amd64 --image-project=ubuntu-os-cloud \
            --boot-disk-size=50GB \
            --provisioning-model=SPOT --max-run-duration="$MAX_RUN" --instance-termination-action=DELETE \
            --labels="$POOL_LABEL" \
            --network="$NET" --subnet="$NET" --no-address \
            --no-service-account --no-scopes \
            --metadata="runner-repo=$REPO" \
            --metadata-from-file="startup-script=$HERE/gcp-runner-startup.sh,job-started-hook=$HERE/../vm/ci-runner/job-started-hook.sh,proxy-env=$tmpd/proxy-env,jit-config=$tmpd/$vm.jit" \
            || up_fail "instances create failed for $vm"
    done
    drop_jit "${created[@]}" || die "jit-config cleanup failed, the VM(s) it covered were deleted"
    echo "gcp-runners: created $need VM(s); pool target $n"
}

cmd_down() {
    local name status
    local zone vms ids id failed=0
    vms="$(pool_vms)" || die "pool discovery failed"
    while read -r name status zone; do
        [ -n "$name" ] || continue
        gc compute instances delete "$name" --zone="${zone:-$ZONE}" --quiet || failed=1
    done <<< "$vms"
    ids="$("$GH" api --paginate "repos/$REPO/actions/runners" --jq '.runners[] | select(.status=="offline" and any(.labels[]; .name=="gcp")) | .id')" || die "runner listing failed"
    while read -r id; do
        [ -n "$id" ] || continue
        "$GH" api -X DELETE "repos/$REPO/actions/runners/$id" || failed=1
    done <<< "$ids"
    [ "$failed" -eq 0 ] || die "down: at least one delete failed, the pool is not clean"
    echo "gcp-runners: pool deleted"
}

cmd_watch() {
    local n="${1:-2}" interval=60
    case "$n" in ''|*[!0-9]*) die "watch: N must be a positive integer, got '$n'" 2 ;; esac
    if [ "$n" -lt 1 ] || [ "$n" -gt "$MAX_N" ]; then die "watch: N must be 1..$MAX_N" 2; fi
    shift
    if [ "${1:-}" = "--interval" ]; then interval="${2:-}"; fi
    case "$interval" in ''|*[!0-9]*) die "watch: --interval must be a positive integer" 2 ;; esac
    [ "$interval" -ge 1 ] || die "watch: --interval must be at least 1" 2

    need_net
    local stop=0 var
    trap 'stop=1' TERM INT
    while [ "$stop" -eq 0 ]; do
        if var="$("$GH" variable get CI_GCP --repo "$REPO")"; then
            [ "$var" = "on" ] || { echo "gcp-runners: CI_GCP is '$var', stopping"; break; }
            ( cmd_up "$n" ) || echo "gcp-runners: top-up failed, retrying next interval" >&2
        else
            echo "gcp-runners: could not read CI_GCP, skipping this interval" >&2
        fi
        sleep "$interval" & wait $!
    done
    ( cmd_down )
}

cmd_status() {
    pool_vms || die "pool discovery failed"
    "$GH" api --paginate "repos/$REPO/actions/runners" --jq '.runners[] | select(any(.labels[]; .name=="gcp")) | "\(.name) \(.status)"'
}

case "${1:-}" in
    up) shift; cmd_up "$@" ;;
    down) cmd_down ;;
    watch) shift; cmd_watch "$@" ;;
    status) cmd_status ;;
    *) die "usage: gcp-runners.sh up [N] | watch N [--interval S] | down | status" 2 ;;
esac
