#!/usr/bin/env bash
set -uo pipefail
cd "$(dirname "$0")" || exit 1
exec bash test-arm-resume.sh --only "1879-lapse"
