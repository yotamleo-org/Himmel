#!/usr/bin/env bash
# DEPRECATED alias, kept so old callers keep sourcing: use worker-identity.sh.
# Sourced, it loads worker-identity.sh and prints nothing.
case "${BASH_SOURCE[0]}" in */*) _leg_identity_alias_dir="${BASH_SOURCE[0]%/*}" ;; *) _leg_identity_alias_dir=. ;; esac
# shellcheck source=scripts/lib/worker-identity.sh
# shellcheck disable=SC1091
. "$_leg_identity_alias_dir/worker-identity.sh"
