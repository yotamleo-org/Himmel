#!/usr/bin/env bash
# RED: a comment that merely MENTIONS the marker mid-sentence is prose, not an
# exemption. The marker must open its own comment: `# git-env-ok: <reason>`.
# note that a git-env-ok: marker would normally go on its own line
set -euo pipefail
git -C "$1" rev-parse --git-common-dir
