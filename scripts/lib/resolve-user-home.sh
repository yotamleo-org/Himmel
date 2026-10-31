#!/usr/bin/env bash
# resolve-user-home.sh — cross-platform user-home + default-vault resolution
#, extracted verbatim from scripts/luna/pipeline-cadence.sh
# so other cadence scripts can share it instead of
# carrying their own copy.
#
# CANONICAL copy of the cross-platform home/vault resolution. Spec A16
# deliberately converted scripts/luna/pipeline-cadence.sh ONLY;
# the remaining copies — including cadence-format.sh's byte-identical
# cadence_user_home() — are converted separately.
#
# Sourced, not executed. bash 3.2-safe; no side effects.

# User-home resolution (generalized from default_vault): $HOME, with /tmp as
# the last-resort floor when it is unset.
resolve_user_home() {
    printf '%s' "${HOME:-/tmp}"
}

# Default vault resolution (cross-platform). Honors
# LUNA_VAULT_PATH first — the vault path adopt.sh persists into
# .claude/settings.json and himmel-doctor probes first — so an
# adopted setup needs no --vault. Otherwise fall back to <home>/Documents/luna
# via the shared cross-platform home resolver. Explicit --vault
# always overrides (parsed by the caller).
default_vault() {
    if [ -n "${LUNA_VAULT_PATH:-}" ]; then
        printf '%s' "$LUNA_VAULT_PATH"
        return
    fi
    printf '%s/Documents/luna' "$(resolve_user_home)"
}
