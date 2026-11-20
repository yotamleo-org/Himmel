#!/usr/bin/env bash
# Test stub for scripts/telegram/restart-bridge.sh, not shipped logic. The suite copies it into
# the fixture checkout. It logs every call; `status` answers per $RST/restart-bridge.running
# (a file: the launcher reports one bridge process) or "no bridge process(es) found".
RST=${RST:?RST must point at the test dir}
echo "restart-bridge $*" >> "$RST/restart-bridge.log"
if [ "${1:-}" = status ]; then
    if [ -f "$RST/restart-bridge.running" ]; then
        echo "[restart-bridge] status: 1 bridge process(es):"
        echo "  supervisor pid 1"
    else
        echo "[restart-bridge] status: no bridge process(es) found"
    fi
fi
[ "${1:-}" = stop ] && rm -f "$RST/restart-bridge.running"
[ "${1:-}" = start ] && : > "$RST/restart-bridge.running"
exit 0
