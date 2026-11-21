#!/usr/bin/env bash
# Offline read of the bridge monitor's actual text-state contract.
# shellcheck disable=SC2154  # fails is assigned by the shared tick fixture
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/tick-test-fixture.sh"
mkdir -p "$W/bridge/monitor"
export BRIDGE_ROOT="$W/bridge"
printf 'down 1794800000 refused: send failed\n' > "$BRIDGE_ROOT/monitor/state"
contains 'down monitor tick field' "$(bash "$SUT")" 'mon-down=1794800000'
contains 'down monitor verbose field' "$(bash "$SUT" --verbose)" 'mon-down: 1794800000'
printf 'ok\n' > "$BRIDGE_ROOT/monitor/state"
not_contains 'healthy monitor has no down field' "$(bash "$SUT")" 'mon-down='
printf 'down nope invalid\n' > "$BRIDGE_ROOT/monitor/state"
contains 'unread monitor is unknown' "$(bash "$SUT")" 'mon-down=?'
exit "$fails"
