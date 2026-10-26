#!/usr/bin/env bash
# workers.sh — read-only workers view for the config UI's Health page.
# Composes the existing owners and parses nothing itself: the handover root from
# `load_dotenv HANDOVER_DIR` + `handover_root`, the workers from `fleet-manifest.sh
# list`, each worker's status from `worker_tail_status` and description from
# `worker_description`. Prints one JSON object:
#   {"manifest": "<path>", "legs": [{"doc": "<path>", "status": "<marker>", "description": "<text>"}]}
#   {"manifest": null, "legs": []}     no *.fleet.json under the root
# Exit 3 when there is no handover root. `himmelctl ui` is launched without
# HANDOVER_DIR, and a bare handover_root would fall back to a worktree's
# handovers/ stub, so resolve from the station anchor: the
# primary checkout, the parent of git's common dir.
# ponytail: two callers (probes.js and this script) spell the anchor+dotenv
# prelude, upgrade path: a handover_root_station helper in handover-path.sh when a third caller appears.
# Bash 3.2-compatible; needs jq.
self=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
common=$(git -C "$self" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) && anchor=$(cd "$common/.." && pwd) || anchor=$(cd "$self/../.." && pwd)

# shellcheck source=../lib/load-dotenv.sh
. "$self/../lib/load-dotenv.sh"
# shellcheck source=../lib/handover-path.sh
. "$self/../lib/handover-path.sh"
# shellcheck source=../lib/worker-tail-status.sh
. "$self/../lib/worker-tail-status.sh"
# shellcheck source=../lib/worker-identity.sh
. "$self/../lib/worker-identity.sh"

load_dotenv --root "$anchor" HANDOVER_DIR
root=$(cd "$anchor" && handover_root 2>/dev/null) || { echo "legs: no handover root" >&2; exit 3; }

best=""
while IFS= read -r f; do
    if [ -z "$best" ] || [ "$f" -nt "$best" ]; then best="$f"; fi
done < <(find "$root" -maxdepth 4 -type f -name '*.fleet.json' 2>/dev/null) # gnu-ok: BSD find also supports -maxdepth

if [ -z "$best" ]; then
    echo '{"manifest": null, "legs": []}'
    exit 0
fi

docs=$(bash "$self/../handover/chief-kit/fleet-manifest.sh" list "$best") || { echo "legs: fleet-manifest list failed for $best" >&2; exit 1; }
rows=""
while IFS= read -r d; do
    [ -n "$d" ] || continue
    rows="$rows$d	$(worker_tail_status "$d")	$(worker_description "$d" | tr -s '\t\n' ' ')
"
done <<EOF
$docs
EOF
jq -n --arg m "$best" --arg rows "$rows" '{manifest: $m, legs: [$rows | split("\n")[] | select(length > 0) | split("\t") | {doc: .[0], status: (.[1] // ""), description: (.[2] // "")}]}'
