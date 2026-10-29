#!/usr/bin/env bash
# guard-console-foreground.sh — old path of guard-chief-foreground.sh, kept while settings and
# wire-hook-bash.mjs still name it. Sourced rather than exec'd so the
# hook-integrity closure walk verifies the renamed file.
#
# Platform guard: one `.` of a sibling file; any POSIX bash 3.2+.
. "$(dirname "${BASH_SOURCE[0]}")/guard-chief-foreground.sh"
