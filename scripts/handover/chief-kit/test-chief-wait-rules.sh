#!/usr/bin/env bash
# Table/wake integration uses the same offline process fixture as the stream.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
exec python3 -I "$HERE/test-chief-wait-stream.py" Stream.test_rules_table_is_the_printed_contract Stream.test_station_repair_aged_queue_and_mon_wakes
