#!/usr/bin/env bash
# twitter-cli-removed.sh — one-shot proof that the twitter CLI is gone from
# himmel: no tracked file outside docs/archive/ and CHANGELOG names it. X links
# go through Scrapling, and nothing updates, pins or fork-tracks the tool.
#
# The pattern is split so this file does not match itself.
#
# Bash 3.2 compatible.
set -uo pipefail

cd "$(dirname "$0")/../.." || exit 1
pat="twitter""-cli"
hits=$(git grep -n -i -F "$pat" -- . ':!docs/archive/' ':!CHANGELOG*' ':!**/CHANGELOG*')
if [ -n "$hits" ]; then
  echo "FAIL tracked files still name $pat:"
  printf '%s\n' "$hits"
  exit 1
fi
echo "ok   no tracked file outside docs/archive and CHANGELOG names $pat"
