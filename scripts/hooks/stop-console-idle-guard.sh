#!/usr/bin/env bash
# stop-console-idle-guard.sh — old path of stop-chief-idle-guard.sh, kept while settings and
# wire-hook-bash.mjs still name it. Sourced rather than exec'd so the
# hook-integrity closure walk verifies the renamed file.
#
# Platform guard (gitbash-only): one `.` of a sibling file; runs unchanged under
# Git Bash on Windows or POSIX bash 3.2+. No .ps1 twin needed.
. "$(dirname "${BASH_SOURCE[0]}")/stop-chief-idle-guard.sh"
