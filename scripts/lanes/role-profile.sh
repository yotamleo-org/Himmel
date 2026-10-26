#!/usr/bin/env bash
# scripts/lanes/role-profile.sh - the role-to-profile rule.
# Prints the plugin profile a session resumed from a handover doc should run
# under. Precedence:
#   1. an explicit `profile: <name>` line in the doc's first 60 lines (a worker
#      brief field; the override that wins over any inference)
#   2. a chief doc (its first heading says CHIEF, or the file name carries
#      `console`)                                      -> chief
#   3. a worker doc (carries a RETASK token)              -> worker-impl
#   4. anything else                                   -> user  (stderr note)
# Usage: role-profile.sh <doc>      stdout: profile name, rc 0; rc 2 on no doc.
# Platform: POSIX bash 3.2+.
set -u
DOC="${1:-}"
# shellcheck disable=SC2015  # the braced group exits; A && B || C is the intended guard
[ -n "$DOC" ] && [ -f "$DOC" ] || { echo "role-profile: usage: role-profile.sh <handover doc> (not a file: '$DOC')" >&2; exit 2; }
HEAD60="$(head -n 60 "$DOC")"
# `profile: design` / `> profile: design` / `- profile: \`design\``
# shellcheck disable=SC2016  # backticks in the sed regex are literal
EXPLICIT="$(printf '%s\n' "$HEAD60" | sed -n -E 's/^[>* -]*profile:[[:space:]]*`?([A-Za-z0-9._-]+)`?[[:space:]]*$/\1/p' | head -n 1)"
if [ -n "$EXPLICIT" ]; then printf '%s\n' "$EXPLICIT"; exit 0; fi
BASE="$(basename "$DOC")"
FIRST_HEADING="$(printf '%s\n' "$HEAD60" | grep -m1 '^# ')"
case "$FIRST_HEADING" in *CHIEF*) echo chief; exit 0 ;; esac
case "$BASE" in *console*|*-chief.md) echo chief; exit 0 ;; esac
if grep -q 'RETASK token' "$DOC"; then echo worker-impl; exit 0; fi
echo "role-profile: $BASE is neither a chief nor a worker doc; defaulting to profile 'user'" >&2
echo user
