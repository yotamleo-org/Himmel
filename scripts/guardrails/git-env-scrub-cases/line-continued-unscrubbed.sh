#!/usr/bin/env bash
# RED: the quoted git payload sits on the continuation line of a `bash -c`.
set -euo pipefail
bash -c \
    'git -C "$0" rev-parse --git-common-dir' "$1"
