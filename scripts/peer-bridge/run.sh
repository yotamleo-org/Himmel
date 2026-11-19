#!/usr/bin/env bash
# run.sh - launcher for the peer bridge poller under launchd (systemd runs the
# poller directly). It loads the bot token from the 0600 env file, runs the
# poller and maps exit 78 (a refusal a restart cannot fix) to 0, so launchd's
# KeepAlive={SuccessfulExit=false} does not respawn it in a loop.
# PEER_BRIDGE_BUN names the bun binary (tests point it at a stub).
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
envfile="$HOME/.config/himmel/peer-bridge/env"

PATH="$HOME/.bun/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"
if [ -r "$envfile" ]; then
    set -a
    # shellcheck disable=SC1090
    . "$envfile"
    set +a
fi

"${PEER_BRIDGE_BUN:-bun}" "$here/poller.ts"
rc=$?
if [ "$rc" -eq 78 ]; then
    echo "run.sh: the poller refused to start (78); not restarting" >&2
    exit 0
fi
exit "$rc"
