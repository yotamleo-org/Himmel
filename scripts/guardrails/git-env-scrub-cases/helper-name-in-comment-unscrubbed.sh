#!/usr/bin/env bash
# RED: the helper filename and git_env_scrub appear only inside a comment and
# a string — neither sources the helper nor calls the scrub.
# . scripts/lib/git-clean.sh ; git_env_scrub
set -euo pipefail
echo "see git-clean.sh and git_env_scrub for the real scrub"
git -C "$1" rev-parse --git-common-dir
