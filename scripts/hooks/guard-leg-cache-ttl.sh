#!/usr/bin/env bash
# guard-leg-cache-ttl.sh — old path of guard-worker-cache-ttl.sh, kept while settings and
# wire-hook-bash.mjs still name it. Sourced rather than exec'd so the
# hook-integrity closure walk verifies the renamed file.
#
# Platform guard: one `.` of a sibling file; any POSIX bash 3.2+.
. "$(dirname "${BASH_SOURCE[0]}")/guard-worker-cache-ttl.sh"
