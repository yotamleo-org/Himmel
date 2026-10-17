#!/usr/bin/env bash
# test-bus-idle-waker.sh — scripts/handover/bus-idle-waker.sh: a bus message or
# an inbox line for an idle session injects ONE fixed prompt, never content.
# shellcheck disable=SC2015,SC2016  # pass/fail chains and a literal injection fixture
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
WAKER="$HERE/bus-idle-waker.sh"

failures=0
pass() { printf '  PASS  %s\n' "$1"; }
fail() { printf '  FAIL  %s\n' "$1"; failures=$((failures+1)); }

tmp=$(mktemp -d "${TMPDIR:-/tmp}/bus-waker.XXXXXX") || exit 1
trap 'rm -rf "$tmp"' EXIT
export HANDOVER_DIR="$tmp/handovers"
mkdir -p "$HANDOVER_DIR/inbox/.cursor"

# Fake qdbus6 records its argv, one call per line; fake bus prints $BUS_N.
cat > "$tmp/qdbus" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$QLOG"
EOF
cat > "$tmp/bus" <<'EOF'
#!/usr/bin/env bash
[ "$1" = unread ] && printf '%s\n' "${BUS_N:-0}"
EOF
chmod +x "$tmp/qdbus" "$tmp/bus"
export QLOG="$tmp/qlog"
FIXED='You have 2 unread himmel messages: read them now.'

run() { # run <polls> <grace> [extra args]; env BUS_N / inbox decide the count
  local polls="$1" grace="$2"; shift 2
  : > "$QLOG"
  BUS_WAKER_QDBUS="$tmp/qdbus" BUS_WAKER_BUS="$tmp/bus" \
    bash "$WAKER" --name legX --service org.kde.konsole-1 --session /Sessions/3 \
    --poll 0.2 --grace "$grace" --rewake 100 --max-polls "$polls" "$@" >/dev/null 2>&1
}

echo "== waker =="
BUS_N=0 run 4 0
[ ! -s "$QLOG" ] && pass "nothing unread: nothing sent" || fail "nothing unread but sent: $(cat "$QLOG")"

BUS_N=2 run 3 60
[ ! -s "$QLOG" ] && pass "unread inside the grace window (hook may still deliver): nothing sent" || fail "sent inside grace"

BUS_N=2 run 8 0.5
n=$(grep -c sendText "$QLOG")
[ "$n" -eq 1 ] && pass "unread past grace: exactly one prompt (rewake holds the next)" || fail "wanted 1 sendText, got $n"
grep -qF "org.kde.konsole-1 /Sessions/3 org.kde.konsole.Session.sendText ${FIXED}"$'\r' "$QLOG" \
  && pass "the injected text is the fixed sentence plus Enter" || fail "text differs: $(cat -A "$QLOG")"

BUS_N=abc run 6 0
[ ! -s "$QLOG" ] && pass "a non-numeric count sends nothing" || fail "non-numeric count sent"

# Content never travels: an inbox line carrying a command is counted, not typed.
printf 'from=con $(touch %s/pwned); rm -rf ~\n' "$tmp" > "$HANDOVER_DIR/inbox/legX.md"
printf '0' > "$HANDOVER_DIR/inbox/.cursor/legX"
BUS_N=0 run 8 0.5
if grep -qF 'You have 1 unread himmel messages: read them now.' "$QLOG" && ! grep -q -e 'pwned' -e 'rm -rf' "$QLOG" && [ ! -e "$tmp/pwned" ]; then
  pass "inbox line wakes with the fixed text only, never its content"
else fail "inbox wake: $(cat "$QLOG")"; fi

# A consumed inbox line (cursor at EOF) wakes nothing.
wc -c < "$HANDOVER_DIR/inbox/legX.md" | tr -d ' \n' > "$HANDOVER_DIR/inbox/.cursor/legX"
BUS_N=0 run 4 0
[ ! -s "$QLOG" ] && pass "a consumed inbox line sends nothing" || fail "consumed inbox woke"

# Exit when the konsole session is gone (fail-safe: no endless loop).
cat > "$tmp/qdbus-dead" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
chmod +x "$tmp/qdbus-dead"
BUS_N=2 BUS_WAKER_QDBUS="$tmp/qdbus-dead" BUS_WAKER_BUS="$tmp/bus" timeout 20 bash "$WAKER" --name legX --service s --session /S --poll 0.2 --grace 0 --rewake 0 >/dev/null 2>&1
rc=$?
[ "$rc" -ne 124 ] && pass "a dead session ends the waker (rc=$rc)" || fail "waker looped past timeout on a dead session"

echo "== succession doc =="
if grep -q 'bus adopt' "$REPO/docs/handover/leg-sections/succession.md"; then pass "succession.md tells the leg to run bus adopt"; else fail "succession.md has no bus adopt step"; fi

echo "bus-idle-waker: $failures failure(s)"
exit "$failures"
