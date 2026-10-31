#!/usr/bin/env bash
# inbox-audit.sh — Per-shift audit for inbox-send.sh's
# chief-side sent-record: every line in an inbox must have a matching ledger
# line, or it is unaccounted for — forged, since inbox-send.sh records every
# bullet before it appends one, or older than the ledger (a reboot clears the
# runtime dir it lives in). Read-only: writes nothing, only reports.
#
# PLATFORM GUARD: audits the
# Linux/konsole-only ledger inbox-send.sh writes (see its own header); no
# Windows-side sent-record exists to audit.
#
# Usage: inbox-audit.sh <inbox-file> <sent-log-dir>
#   <sent-log-dir> is the base passed as HIMMEL_CONSOLE_RUNDIR to
#   inbox-send.sh (or its chief.sh-convention default) — this script
#   accepts a ledger line from either <sent-log-dir>/inbox-sent.log
#   directly or <sent-log-dir>/<sender>/inbox-sent.log one level down.
#
# Every non-blank line is audited, whatever its shape or field order: a
# shape match let a forged bullet with from= before the token pass.
# The sha256 of the line (no trailing newline) must equal the
# 4th whitespace-separated field of some ledger line. Prints "AUDIT ok" and
# exits 0 when every line is matched; otherwise prints one
# "AUDIT UNMATCHED <line>" per miss and exits 1. A missing inbox file or
# sent-log dir, an inbox that cannot be read (e.g. a permission change), or a
# sha256sum or grep failure is a usage error, exit 2 — this audit exists to
# catch forgery, so it fails closed rather than reporting a false "AUDIT ok". A
# final inbox line with no trailing newline is still audited.
#
# bash 3.2-safe, shellcheck-clean, no arrays — matches inbox-send.sh's
# shell dialect (see its own header for why).
set -u

usage() {
    printf 'usage: inbox-audit.sh <inbox-file> <sent-log-dir>\n' >&2
    exit 2
}

[ "$#" -eq 2 ] || usage
inbox="$1"
sent_dir="$2"

[ -f "$inbox" ] || { printf 'inbox-audit: no such inbox file: %s\n' "$inbox" >&2; exit 2; }
[ -d "$sent_dir" ] || { printf 'inbox-audit: no such sent-log dir: %s\n' "$sent_dir" >&2; exit 2; }

# One combined pool of recorded sha256 values, from every inbox-sent.log
# this sent_dir holds — directly at its root, or one level down under a
# per-sender subdirectory. A dir with no ledgers yet yields an empty pool,
# so every token bullet in the inbox correctly comes up unmatched.
ledger_shas="$(cat "$sent_dir"/inbox-sent.log "$sent_dir"/*/inbox-sent.log 2>/dev/null | awk '{ print $4 }')"

unmatched=0
read_failed=0
while IFS= read -r line || [ -n "$line" ]; do
    [ -n "${line//[[:space:]]/}" ] || continue
    if ! sha="$(printf '%s' "$line" | sha256sum)"; then
        printf 'inbox-audit: cannot hash line, aborting: %s\n' "$line" >&2
        exit 2
    fi
    sha="${sha%% *}"
    printf '%s\n' "$ledger_shas" | grep -qxF "$sha"
    match_rc=$?
    if [ "$match_rc" -gt 1 ]; then
        printf 'inbox-audit: cannot match line, aborting: %s\n' "$line" >&2
        exit 2
    fi
    if [ "$match_rc" -eq 1 ]; then
        printf 'AUDIT UNMATCHED %s\n' "$line"
        unmatched=1
    fi
done < "$inbox" || read_failed=1

if [ "$read_failed" -eq 1 ]; then
    printf 'inbox-audit: cannot read %s\n' "$inbox" >&2
    exit 2
fi

if [ "$unmatched" -eq 0 ]; then
    printf 'AUDIT ok\n'
    exit 0
fi
exit 1
