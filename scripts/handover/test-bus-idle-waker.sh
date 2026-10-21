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
export BUS_WAKER_STATE_DIR="$tmp/wstate"
mkdir -p "$HANDOVER_DIR/inbox/.cursor"

# Fake qdbus6: processId answers $QPID (or $QPID_LATER after its first call),
# getAllDisplayedText prints $QSCREEN (a screen copied from a real konsole), and
# every other call (sendText) is recorded in $QLOG, one per line; fake bus prints
# $BUS_N. $tmp/proc stands in for /proc.
FIX="$HERE/fixtures/bus-waker"
cat > "$tmp/qdbus" <<'EOF'
#!/usr/bin/env bash
case "$3" in
  org.kde.konsole.Session.processId)
    if [ -n "${QPID_LATER:-}" ] && [ -e "$QLOG.pid" ]; then printf '%s\n' "$QPID_LATER"; else printf '%s\n' "$QPID"; fi
    : > "$QLOG.pid" ;;
  org.kde.konsole.Session.getAllDisplayedText) cat "$QSCREEN" ;;
  *) printf '%s\n' "$*" >> "$QLOG" ;;
esac
EOF
cat > "$tmp/bus" <<'EOF'
#!/usr/bin/env bash
[ "$1" = unread ] && printf '%s\n' "${BUS_N:-0}"
EOF
chmod +x "$tmp/qdbus" "$tmp/bus"
export QLOG="$tmp/qlog" QPID=4242 QSCREEN="$FIX/screen-idle.txt" BUS_WAKER_PROC="$tmp/proc"
mkdir -p "$tmp/proc/4242" "$tmp/proc/4343" "$tmp/proc/4444" "$tmp/proc/4646"
printf 'claude\0-n\0legX\0' > "$tmp/proc/4242/cmdline"
printf 'claude\0-n\0HIMMEL-nextleg-2026-10-19H-roadmap-console\0' > "$tmp/proc/4343/cmdline"
printf 'zsh\0' > "$tmp/proc/4444/cmdline"
printf 'python3\0-n\0legX\0' > "$tmp/proc/4646/cmdline"
FIXED='You have unread himmel messages: read them now.'

run() { # run <polls> <grace> [extra args]; env BUS_N / inbox decide the count
  local polls="$1" grace="$2"; shift 2
  : > "$QLOG"; rm -f "$QLOG.pid"
  BUS_WAKER_QDBUS="$tmp/qdbus" BUS_WAKER_BUS="$tmp/bus" \
    bash "$WAKER" --name legX --service org.kde.konsole-1 --session /Sessions/3 \
    --poll 0.2 --grace "$grace" --rewake 100 --max-polls "$polls" "$@" >/dev/null 2>&1
  RUN_RC=$?
}

echo "== waker =="
BUS_N=0 run 4 0
[ "$RUN_RC" -eq 0 ] && [ ! -s "$QLOG" ] && pass "nothing unread: nothing sent" || fail "nothing unread but sent: $(cat "$QLOG")"

BUS_N=2 run 3 60
[ "$RUN_RC" -eq 0 ] && [ ! -s "$QLOG" ] && pass "unread inside the grace window (hook may still deliver): nothing sent" || fail "sent inside grace"

BUS_N=2 run 8 0.5
n=$(grep -c sendText "$QLOG")
[ "$RUN_RC" -eq 0 ] && [ "$n" -eq 1 ] && pass "unread past grace: exactly one prompt (rewake holds the next)" || fail "wanted 1 sendText, got $n"
grep -qF "org.kde.konsole-1 /Sessions/3 org.kde.konsole.Session.sendText ${FIXED}"$'\r' "$QLOG" \
  && pass "the injected text is the fixed sentence plus Enter" || fail "text differs: $(cat -A "$QLOG")"

BUS_N=abc run 6 0
[ "$RUN_RC" -eq 0 ] && [ ! -s "$QLOG" ] && pass "a non-numeric count sends nothing" || fail "non-numeric count sent"

# Content never travels: an inbox line carrying a command is counted, not typed.
printf 'from=con $(touch %s/pwned); rm -rf ~\n' "$tmp" > "$HANDOVER_DIR/inbox/legX.md"
printf '0' > "$HANDOVER_DIR/inbox/.cursor/legX"
BUS_N=0 run 8 0.5
if grep -qF "$FIXED" "$QLOG" && ! grep -q -e 'pwned' -e 'rm -rf' "$QLOG" && [ ! -e "$tmp/pwned" ]; then
  pass "inbox line wakes with the fixed text only, never its content"
else fail "inbox wake: $(cat "$QLOG")"; fi

# A consumed inbox line (cursor at EOF) wakes nothing.
wc -c < "$HANDOVER_DIR/inbox/legX.md" | tr -d ' \n' > "$HANDOVER_DIR/inbox/.cursor/legX"
BUS_N=0 run 4 0
[ "$RUN_RC" -eq 0 ] && [ ! -s "$QLOG" ] && pass "a consumed inbox line sends nothing" || fail "consumed inbox woke"

# Exit when the konsole session is gone (fail-safe: no endless loop).
cat > "$tmp/qdbus-dead" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
chmod +x "$tmp/qdbus-dead"
BUS_N=2 BUS_WAKER_QDBUS="$tmp/qdbus-dead" BUS_WAKER_BUS="$tmp/bus" bash "$WAKER" --name legX --service s --session /S --poll 0.2 --grace 0 --rewake 0 --max-polls 50 >/dev/null 2>&1
rc=$?
[ "$rc" -eq 1 ] && pass "a dead session ends the waker with rc=1" || fail "dead session: expected rc=1, got rc=$rc"

# A window with EnableSecuritySensitiveDBusAPI off refuses sendText: named, rc=3.
# Copied from a real qdbus6 run: the error goes to STDOUT, rc=2.
cat > "$tmp/qdbus-denied" <<'EOF'
#!/usr/bin/env bash
printf 'Error: org.freedesktop.DBus.Error.AccessDenied\nSecurity sensitive DBus API is disabled in the settings.\n'
exit 2
EOF
chmod +x "$tmp/qdbus-denied"
BUS_N=2 BUS_WAKER_QDBUS="$tmp/qdbus-denied" BUS_WAKER_BUS="$tmp/bus" bash "$WAKER" --name legX --service s --session /S --poll 0.2 --grace 0 --rewake 0 --max-polls 50 >/dev/null 2>"$tmp/denied-err"
rc=$?
denied_line='bus-idle-waker: sendText denied (konsole security-sensitive D-Bus API is disabled, or this window predates enabling it; enable it, then relaunch the window): legX'
if [ "$rc" -eq 3 ] && grep -qxF "$denied_line" "$tmp/denied-err" && ! grep -q 'session gone' "$tmp/denied-err"; then
  pass "an AccessDenied sendText ends with rc=3 and names the denial, not a gone session"
else fail "denied: expected rc=3, got rc=$rc: $(cat "$tmp/denied-err")"; fi

# The one-line form, on stderr.
cat > "$tmp/qdbus-denied-1l" <<'EOF'
#!/usr/bin/env bash
printf 'org.freedesktop.DBus.Error.AccessDenied: Security sensitive DBus API is disabled in the settings.\n' >&2
exit 2
EOF
chmod +x "$tmp/qdbus-denied-1l"
BUS_N=2 BUS_WAKER_QDBUS="$tmp/qdbus-denied-1l" BUS_WAKER_BUS="$tmp/bus" bash "$WAKER" --name legX --service s --session /S --poll 0.2 --grace 0 --rewake 0 --max-polls 50 >/dev/null 2>"$tmp/denied-err"
rc=$?
if [ "$rc" -eq 3 ] && grep -qxF "$denied_line" "$tmp/denied-err"; then
  pass "a one-line AccessDenied error also ends with rc=3 and the denial line"
else fail "denied one-line: expected rc=3, got rc=$rc: $(cat "$tmp/denied-err")"; fi

bash "$WAKER" --name legX --service s --session >/dev/null 2>&1
rc=$?
[ "$rc" -eq 64 ] && pass "an option with no value is refused (rc=64)" || fail "valueless option: expected rc=64, got rc=$rc"

bash "$WAKER" --name legX --service s --session /S --poll abc >/dev/null 2>&1
rc=$?
[ "$rc" -eq 64 ] && pass "a non-numeric --poll is refused (rc=64)" || fail "bad --poll: expected rc=64, got rc=$rc"

bash "$WAKER" --name legX --service s --session /S --poll 0 >/dev/null 2>&1
rc=$?
[ "$rc" -eq 64 ] && pass "--poll 0 is refused (rc=64)" || fail "--poll 0: expected rc=64, got rc=$rc"

bash "$WAKER" --name legX --service s --session /S --max-polls 0.5 >/dev/null 2>&1
rc=$?
[ "$rc" -eq 64 ] && pass "a fractional --max-polls is refused (rc=64)" || fail "--max-polls 0.5: expected rc=64, got rc=$rc"

printf '08' > "$HANDOVER_DIR/inbox/.cursor/legX"
printf 'aaaaaaa\nbbb\n' > "$HANDOVER_DIR/inbox/legX.md"
BUS_N=0 run 8 0.5
grep -qF "$FIXED" "$QLOG" && pass "a zero-padded cursor still counts bytes in decimal" || fail "08 cursor: $(cat "$QLOG")"

# --pid: the waker armed for a launched konsole stops once that konsole is gone.
sleep 0 & dead=$!; wait "$dead"
: > "$QLOG"
BUS_N=0 BUS_WAKER_QDBUS="$tmp/qdbus" BUS_WAKER_BUS="$tmp/bus" bash "$WAKER" --name legX --service s --session /S --pid "$dead" --poll 0.2 --max-polls 50 >/dev/null 2>"$tmp/pid-err"
rc=$?
if [ "$rc" -eq 0 ] && grep -qxF "bus-idle-waker: konsole pid $dead gone, stopping: legX" "$tmp/pid-err"; then
  pass "--pid: a gone konsole ends the waker with rc=0"
else fail "--pid gone: expected rc=0 and the stop line, got rc=$rc: $(cat "$tmp/pid-err")"; fi
bash "$WAKER" --name legX --service s --session /S --pid 0 >/dev/null 2>&1
rc=$?
[ "$rc" -eq 64 ] && pass "--pid 0 is refused (rc=64): kill -0 0 would probe the process group" || fail "--pid 0: expected rc=64, got rc=$rc"
BUS_N=2 run 3 0 --pid "$$"
[ "$RUN_RC" -eq 0 ] && grep -qF 'unread himmel messages: read them now.' "$QLOG" && pass "--pid: a live konsole still gets the wake" || fail "--pid live: rc=$RUN_RC, qlog: $(cat "$QLOG")"

echo "== dialog and target =="
# Screens copied from a real konsole (Claude Code 2.1.303) through getAllDisplayedText.
QSCREEN="$FIX/screen-permission.txt" BUS_N=2 run 8 0
[ "$RUN_RC" -eq 0 ] && [ ! -s "$QLOG" ] && pass "a pending permission dialog gets no keystroke (Enter would pick 1. Yes)" || fail "typed into a permission dialog: $(cat "$QLOG")"
QSCREEN="$FIX/screen-trust.txt" BUS_N=2 run 8 0
[ "$RUN_RC" -eq 0 ] && [ ! -s "$QLOG" ] && pass "a digit-free menu (the trust dialog) gets no keystroke either" || fail "typed into the trust dialog: $(cat "$QLOG")"
QSCREEN="$FIX/screen-busy.txt" BUS_N=2 run 8 0
[ "$RUN_RC" -eq 0 ] && [ ! -s "$QLOG" ] && pass "a running turn (spinner above the input box) gets no keystroke" || fail "typed into a busy turn: $(cat "$QLOG")"
sed 's/^❯.*/❯ half-typed reply/' "$FIX/screen-idle.txt" > "$tmp/draft-screen"
grep -qFx '❯ half-typed reply' "$tmp/draft-screen" || fail "draft fixture was not generated"
QSCREEN="$tmp/draft-screen" BUS_N=2 run 8 0
[ "$RUN_RC" -eq 0 ] && [ ! -s "$QLOG" ] && pass "an input box holding a draft gets no keystroke (Enter would submit it)" || fail "typed onto a draft: $(cat "$QLOG")"
: > "$tmp/empty-screen"
QSCREEN="$tmp/empty-screen" BUS_N=2 run 8 0
[ "$RUN_RC" -eq 0 ] && [ ! -s "$QLOG" ] && pass "a blank screen (no input box seen) gets no keystroke" || fail "typed blind: $(cat "$QLOG")"
BUS_N=2 run 3 0
if grep -q sendText "$QLOG" && ! sed 's/.*sendText //' "$QLOG" | grep -q '[0-9]'; then
  pass "the idle prompt is woken, and the typed line carries no digit"
else fail "idle wake or digit-free text: $(cat "$QLOG")"; fi
# A leg name wider than the window truncates the box's top rule to ` <name>… ─`.
QSCREEN="$FIX/screen-idle-longname.txt" BUS_N=2 run 3 0
grep -qF "$FIXED" "$QLOG" && pass "an idle prompt under a truncated session-name rule is woken" || fail "long-name idle prompt not woken: $(cat "$QLOG")"
sed 's/^❯.*/❯ half-typed reply/' "$FIX/screen-idle-longname.txt" > "$tmp/draft-longname"
grep -qFx '❯ half-typed reply' "$tmp/draft-longname" || fail "long-name draft fixture was not generated"
QSCREEN="$tmp/draft-longname" BUS_N=2 run 8 0
[ "$RUN_RC" -eq 0 ] && [ ! -s "$QLOG" ] && pass "a draft under a truncated session-name rule gets no keystroke" || fail "typed onto a long-name draft: $(cat "$QLOG")"
QSCREEN="$FIX/screen-nonrule-top.txt" BUS_N=2 run 8 0
[ "$RUN_RC" -eq 0 ] && [ ! -s "$QLOG" ] && pass "a non-rule line ending in the rule character above an empty prompt gets no keystroke" || fail "woke on a non-rule top line: $(cat "$QLOG")"

QPID=4343 BUS_N=2 run 3 0
[ "$RUN_RC" -eq 4 ] && [ ! -s "$QLOG" ] && pass "a konsole session running another claude (-n <console>) is refused, rc=4" || fail "foreign target: rc=$RUN_RC, qlog: $(cat "$QLOG")"
QPID=4444 BUS_N=2 run 3 0
[ "$RUN_RC" -eq 4 ] && [ ! -s "$QLOG" ] && pass "a konsole session that is not a named claude (a shell) is refused, rc=4" || fail "shell target: rc=$RUN_RC, qlog: $(cat "$QLOG")"
QPID=4646 BUS_N=2 run 3 0
[ "$RUN_RC" -eq 4 ] && [ ! -s "$QLOG" ] && pass "another program carrying -n <name> is refused, rc=4" || fail "non-claude -n target: rc=$RUN_RC, qlog: $(cat "$QLOG")"
QPID_LATER=4444 BUS_N=2 run 3 0
[ "$RUN_RC" -eq 4 ] && [ ! -s "$QLOG" ] && pass "a session whose process changed after startup is refused before the wake, rc=4" || fail "replaced target: rc=$RUN_RC, qlog: $(cat "$QLOG")"
# A real leg's claude argv, read from /proc/<processId>/cmdline.
mkdir -p "$tmp/proc/4545" && cp "$FIX/cmdline-leg" "$tmp/proc/4545/cmdline"
: > "$QLOG"
QPID=4545 BUS_N=2 BUS_WAKER_QDBUS="$tmp/qdbus" BUS_WAKER_BUS="$tmp/bus" bash "$WAKER" --name HIMMEL-6343-N2734-write-verdict-affects-version-2026-10-19 \
  --service org.kde.konsole-1 --session /Sessions/3 --poll 0.2 --grace 0 --rewake 100 --max-polls 3 >/dev/null 2>&1
rc=$?
[ "$rc" -eq 0 ] && grep -qF "$FIXED" "$QLOG" && pass "a real leg argv naming the session (-n <name>) is accepted" || fail "real leg argv: rc=$rc, qlog: $(cat "$QLOG")"
QPID=4545 BUS_N=2 run 3 0
[ "$RUN_RC" -eq 4 ] && [ ! -s "$QLOG" ] && pass "the same real argv aimed at another --name is refused, rc=4" || fail "real argv, wrong name: rc=$RUN_RC"

echo "== waker state file =="
# A waker that ends on rc=3 or rc=4 leaves <state dir>/<name> holding rc3 or rc4 for the
# console tick; a healthy start clears a stale one, and a clean end leaves none.
rm -rf "$BUS_WAKER_STATE_DIR"
BUS_N=2 BUS_WAKER_QDBUS="$tmp/qdbus-denied" BUS_WAKER_BUS="$tmp/bus" bash "$WAKER" --name legX --service s --session /S --poll 0.2 --grace 0 --rewake 0 --max-polls 50 >/dev/null 2>&1
[ "$(cat "$BUS_WAKER_STATE_DIR/legX" 2>/dev/null)" = rc3 ] && pass "an AccessDenied end (rc=3) leaves state rc3" || fail "rc3 state: '$(cat "$BUS_WAKER_STATE_DIR/legX" 2>/dev/null)'"
QPID=4343 BUS_N=2 run 3 0
[ "$RUN_RC" -eq 4 ] && [ "$(cat "$BUS_WAKER_STATE_DIR/legX" 2>/dev/null)" = rc4 ] && pass "a refused target (rc=4) leaves state rc4" || fail "rc4 state: rc=$RUN_RC '$(cat "$BUS_WAKER_STATE_DIR/legX" 2>/dev/null)'"
BUS_N=0 run 2 0
[ "$RUN_RC" -eq 0 ] && [ ! -e "$BUS_WAKER_STATE_DIR/legX" ] && pass "a healthy start clears a stale rc4 state" || fail "stale state kept: rc=$RUN_RC '$(cat "$BUS_WAKER_STATE_DIR/legX" 2>/dev/null)'"

echo "== succession doc =="
if grep -q 'run `bus adopt <new console>` as the leg' "$REPO/docs/handover/leg-sections/succession.md" && grep -q 'no edge to' "$REPO/docs/handover/leg-sections/succession.md"; then pass "succession.md tells the leg to run bus adopt and why"; else fail "succession.md lacks the bus adopt instruction"; fi

echo "bus-idle-waker: $failures failure(s)"
exit "$failures"
