#!/usr/bin/env bash
# scripts/lanes/lib/burn-weights.sh - shared token-price weights for
# leg-burn.sh and agg-burn.sh. Cache reads are the cheapest
# token on the bill (~0.1x a fresh input token); cache writes are the
# priciest (~1.25x); these are the coefficients cost-eq is computed with.
# Override any of them via env for a later price change; sourced, not run.
# Platform guard: no .ps1 twin, by design. POSIX bash 3.2+ arithmetic only; it
# runs under git bash unchanged, same as leg-burn.sh, which sources it.
: "${WORKER_SESSION_BURN_W_CACHE_READ:=${LEG_BURN_W_CACHE_READ:-0.1}}"
: "${WORKER_SESSION_BURN_W_CACHE_CREATE:=${LEG_BURN_W_CACHE_CREATE:-1.25}}"
: "${WORKER_SESSION_BURN_W_INPUT:=${LEG_BURN_W_INPUT:-1}}"
: "${WORKER_SESSION_BURN_W_OUTPUT:=${LEG_BURN_W_OUTPUT:-5}}"
