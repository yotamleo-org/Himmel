#!/usr/bin/env bash
# DEPRECATED alias, kept so old callers keep sourcing: use worker-doc-lock.sh.
# Sourced, it loads worker-doc-lock.sh and prints nothing.
case "${BASH_SOURCE[0]}" in */*) _leg_doc_lock_alias_dir="${BASH_SOURCE[0]%/*}" ;; *) _leg_doc_lock_alias_dir=. ;; esac
# shellcheck source=scripts/handover/chief-kit/worker-doc-lock.sh
# shellcheck disable=SC1091
. "$_leg_doc_lock_alias_dir/worker-doc-lock.sh"
