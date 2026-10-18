#!/usr/bin/env bash
# gcp-runner-autoscale.sh -- one autoscale tick for the ephemeral GCP runner pool.
# Run it on the station from the himmel-gcp-autoscale systemd user timer.
#
#   bash scripts/ci/gcp-runner-autoscale.sh
#
# While repo variable CI_GCP is 'on', counts the queued workflow_job entries labelled
# gcp and runs `gcp-runners.sh up <depth>`, depth capped at 4 (the trial caps 8 vCPUs).
# CI_GCP off or an empty queue does nothing; an unreadable CI_GCP or queue fails the tick
# without creating a VM.
#
# ponytail: depth is the queued gcp jobs alone, and `up N` counts busy VMs as live, so a
# queue behind busy runners is topped up on the tick after one finishes; upgrade to
# live + queued once the live proof shows the wait matters.
set -uo pipefail

REPO="${GCP_RUNNERS_REPO:-yotamleo/Himmel}"
GH="${GH:-gh}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNNERS="${GCP_AUTOSCALE_RUNNERS:-$HERE/gcp-runners.sh}"
MAX_N=4

die() { echo "gcp-runner-autoscale: $1" >&2; exit "${2:-1}"; }

var="$("$GH" variable get CI_GCP --repo "$REPO")" || die "could not read CI_GCP"
[ "$var" = "on" ] || { echo "gcp-runner-autoscale: CI_GCP is '$var', nothing to do"; exit 0; }

# A queued gcp job can sit in a run that is already in_progress (its other jobs started).
runs="$("$GH" api --paginate "repos/$REPO/actions/runs?status=queued&per_page=100" --jq '.workflow_runs[].id')" || die "could not list queued runs"
running="$("$GH" api --paginate "repos/$REPO/actions/runs?status=in_progress&per_page=100" --jq '.workflow_runs[].id')" || die "could not list in-progress runs"
runs="$runs"$'\n'"$running"
depth=0
while read -r id; do
    [ -n "$id" ] || continue
    jobs="$("$GH" api --paginate "repos/$REPO/actions/runs/$id/jobs?per_page=100" --jq '.jobs[] | select(.status=="queued" and any(.labels[]; .=="gcp")) | .id')" || die "could not list jobs of run $id"
    n="$(grep -c . <<< "$jobs")"
    depth=$((depth + n))
done <<< "$runs"

[ "$depth" -gt 0 ] || { echo "gcp-runner-autoscale: no queued gcp job"; exit 0; }
[ "$depth" -le "$MAX_N" ] || depth="$MAX_N"
echo "gcp-runner-autoscale: scaling the pool to $depth"
bash "$RUNNERS" up "$depth" || die "up $depth failed"
