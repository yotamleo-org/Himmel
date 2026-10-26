#!/usr/bin/env bash
# guard-leg-cache-ttl.sh — old path of guard-worker-cache-ttl.sh, kept while settings and
# wire-hook-bash.mjs still name it. Sourced rather than exec'd so the
# hook-integrity closure walk verifies the renamed file.
#
# Platform guard (gitbash-only): one `.` of a sibling file; runs unchanged under
# Git Bash on Windows or POSIX bash 3.2+. No .ps1 twin needed.
. "$(dirname "${BASH_SOURCE[0]}")/guard-worker-cache-ttl.sh"
