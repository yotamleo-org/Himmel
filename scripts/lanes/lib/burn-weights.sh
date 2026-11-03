#!/usr/bin/env bash
# scripts/lanes/lib/burn-weights.sh - shared token-price weights for
# worker-burn.sh and agg-burn.sh. Cache reads are the cheapest
# token on the bill (0.05-0.1x a fresh input token, per model: see
# cache-read-weights.tsv); cache writes are the
# priciest (~1.25x); these are the coefficients cost-eq is computed with.
# Override any of them via env for a later price change; sourced, not run.
# Setting WORKER_SESSION_BURN_W_CACHE_READ prices every model flat at that value.
# Platform guard: POSIX bash 3.2+ arithmetic only, same as worker-burn.sh,
# which sources it.
_BURN_CR_FLAT="${WORKER_SESSION_BURN_W_CACHE_READ+set}"
: "${WORKER_SESSION_BURN_W_CACHE_READ:=0.1}"
: "${WORKER_SESSION_BURN_W_CACHE_CREATE:=1.25}"
: "${WORKER_SESSION_BURN_W_INPUT:=1}"
: "${WORKER_SESSION_BURN_W_OUTPUT:=5}"
_BURN_CR_TABLE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/cache-read-weights.tsv"

# burn_cache_read_weight <model-id> - the cache-read weight for a model: the first table row whose
# prefix the id starts with, else the default above. Prints the weight; rc 1 when the model has no
# row (the caller counts it as unknown), rc 0 otherwise.
burn_cache_read_weight() {
    if [ -n "$_BURN_CR_FLAT" ]; then printf '%s\n' "$WORKER_SESSION_BURN_W_CACHE_READ"; return 0; fi
    awk -F'\t' -v m="${1:-}" -v d="$WORKER_SESSION_BURN_W_CACHE_READ" '
        $1 !~ /^#/ && $1 != "" && m != "" && index(m, $1) == 1 { print $2; f = 1; exit }
        END { if (!f) { print d; exit 1 } }' "$_BURN_CR_TABLE"
}
