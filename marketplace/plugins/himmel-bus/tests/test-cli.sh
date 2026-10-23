#!/usr/bin/env bash
# himmel-bus CLI (T10): `bus send` (stamped from process ancestry), `--doc`
# mirror, `bus gc`, `bus status --unacked` with computed expiry.
#
# A bound identity needs a real `claude`-named ancestor, so the driver below runs
# under a symlink to bash called `claude`, points the registered peer at itself,
# and spawns the CLI as its child. State lives in a throwaway XDG_STATE_HOME.
#
# Usage: bash marketplace/plugins/himmel-bus/tests/test-cli.sh
set -uo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
REPO="$(cd "$HERE/../../.." && pwd)"
BUS="$HERE/bin/bus"
INBOX_SEND="$REPO/scripts/handover/console-kit/inbox-send.sh"

failures=0
pass() { printf '  PASS  %s\n' "$1"; }
fail() { printf '  FAIL  %s\n' "$1"; failures=$((failures+1)); }
check() { # check <label> <command...>
  local label="$1"; shift
  if "$@" >/dev/null 2>&1; then pass "$label"; else fail "$label"; fi
}

tmp=$(mktemp -d "${TMPDIR:-/tmp}/bus-cli.XXXXXX") || exit 1
# The store refuses a symlinked path component, and macOS /tmp is a symlink.
tmp=$(cd -P "$tmp" && pwd -P) || exit 1
trap 'rm -rf "$tmp"' EXIT
export XDG_STATE_HOME="$tmp/state"
mkdir -m 700 "$XDG_STATE_HOME"
export HANDOVER_DIR="$tmp/handovers"
mkdir "$HANDOVER_DIR"
ln -s "$(command -v bash)" "$tmp/claude"

# Node helper: lib() runs a snippet against the store with ROOT/NAME bound.
lib() {
  node --input-type=module -e "
    import * as store from '$HERE/lib/store.mjs';
    import * as identity from '$HERE/lib/identity.mjs';
    const root = await store.busRoot();
    $1
  "
}

# Driver: bash running as `claude` (node renames its own comm, bash does not).
# It points <name> at itself, then runs the CLI as its child.
cat > "$tmp/repoint.mjs" <<EOF
import { readFile, writeFile } from 'node:fs/promises';
import * as store from '$HERE/lib/store.mjs';
const [name, pid, start] = process.argv.slice(2);
const file = (await store.busRoot()) + '/peers/' + name + '.json';
const peer = JSON.parse(await readFile(file, 'utf8'));
await writeFile(file, JSON.stringify({ ...peer, pid: Number(pid), start }) + '\n');
EOF
cat > "$tmp/as.sh" <<'EOF'
name="$1"; shift
start=$(cut -d' ' -f22 "/proc/$$/stat")
node "$REPOINT" "$name" "$$" "$start" || exit 1
"$BUS_CLI" "$@"
EOF
as() { REPOINT="$tmp/repoint.mjs" BUS_CLI="$BUS" "$tmp/claude" "$tmp/as.sh" "$@"; }

# A bound identity is read from /proc (identity.mjs procStat), so a host with no
# procfs (macOS) cannot bind one: the sections that act as a bound peer are
# skipped there and the store-level ones still run.
HAVE_PROC=1; [ -r /proc/self/stat ] || HAVE_PROC=0
skip_section() { printf '  SKIP  %s: no /proc on this host, identity binding is Linux-only\n' "$1"; }
# ago <days>: a touch -t stamp <days> back (GNU or BSD date).
ago() { local s=$(( $(date +%s) - $1 * 86400 )); date -d "@$s" +%Y%m%d%H%M.%S 2>/dev/null || date -r "$s" +%Y%m%d%H%M.%S; }

"$BUS" register con --role console
"$BUS" register legA --role leg --console con
"$BUS" register legB --role leg --console con
"$BUS" register other --role console
"$BUS" register otherLeg --role leg --console other
printf 'rule one\n' > "$tmp/body"

echo "== send: identity and stamping =="
out=$("$BUS" send legA "$tmp/body" 2>&1); rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q 'identity unbound'; then pass "send from an unbound process is refused"; else fail "send from an unbound process (rc=$rc: $out)"; fi
check "unbound send wrote nothing" test ! -e "$XDG_STATE_HOME/himmel/bus/log/legA.jsonl"

if [ "$HAVE_PROC" = 1 ]; then
out=$(as con send legA "$tmp/body" 2>&1); rc=$?
if [ "$rc" -eq 0 ] && [ "$out" = "sent #1 to legA" ]; then pass "console sends to its leg"; else fail "console send (rc=$rc: $out)"; fi
rec=$(lib "console.log(JSON.stringify((await store.scan(root, 'legA'))[0]))")
case "$rec" in *'"f":"con"'*'"c":1'*|*'"c":1'*'"f":"con"'*) pass "record is stamped f=con with c=1" ;; *) fail "record stamping: $rec" ;; esac
out=$(as con send otherLeg "$tmp/body" 2>&1); rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q 'no edge to otherLeg'; then pass "send to another console's leg is refused"; else fail "edge refusal (rc=$rc: $out)"; fi
out=$(as legA send legB "$tmp/body" 2>&1); rc=$?
if [ "$rc" -ne 0 ]; then pass "leg to sibling is refused"; else fail "leg to sibling allowed: $out"; fi
printf 'x%.0s' $(seq 1 1600) > "$tmp/big"
out=$(as con send legA "$tmp/big" 2>&1); rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q 'needs --summary'; then pass "body over 1500 bytes needs a summary"; else fail "summary rule (rc=$rc: $out)"; fi
out=$(as con send legA "$tmp/big" --summary "big one" 2>&1); rc=$?
if [ "$rc" -eq 0 ]; then pass "body over 1500 bytes with --summary is sent"; else fail "summary send (rc=$rc: $out)"; fi

echo "== send: --re acks =="
as legA send con "$tmp/body" --re 1 >/dev/null 2>&1; rc=$?
if [ "$rc" -eq 0 ] && grep -q '"re"' "$XDG_STATE_HOME/himmel/bus/ack/legA.jsonl" 2>/dev/null; then pass "--re writes an ack row under the acker"; else fail "--re ack (rc=$rc)"; fi
out=$(as legA send con "$tmp/body" --re 9 2>&1); rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q 'no message #9'; then pass "--re of an unknown message is refused"; else fail "--re unknown (rc=$rc: $out)"; fi

echo "== send --doc: byte-identical to inbox-send.sh --doc =="
mkdir "$tmp/inbox-ref"
for _ in 1 2 3; do
  printf '# leg doc\n\n## Console Rulings (newest at the bottom)\n- 00:00 old\n\n## Results\n' > "$tmp/doc-bus.md"
  cp "$tmp/doc-bus.md" "$tmp/doc-ref.md"
  printf '%s\0%s\0%s\0' claude -n con > "$tmp/cmdline"
  before=$(date +%H:%M)
  as con send legA "$tmp/body" --doc "$tmp/doc-bus.md" >/dev/null 2>&1; bus_rc=$?
  HANDOVER_DIR="$tmp/inbox-ref" CLAUDE_PID=1 SESSION_NAME_CMDLINE_FILE="$tmp/cmdline" bash "$INBOX_SEND" legA --file "$tmp/body" --doc "$tmp/doc-ref.md" >/dev/null 2>&1
  after=$(date +%H:%M)
  [ "$before" = "$after" ] && break
done
if [ "$bus_rc" -eq 0 ] && cmp -s "$tmp/doc-bus.md" "$tmp/doc-ref.md" && grep -q 'from=con rule one' "$tmp/doc-bus.md"; then pass "--doc mirror is byte-identical to inbox-send.sh --doc"; else fail "--doc mirror differs (rc=$bus_rc)"; diff "$tmp/doc-bus.md" "$tmp/doc-ref.md"; fi
check "--doc leaves no inbox file in the real handover root" test -z "$(ls -A "$HANDOVER_DIR")"
n0=$(lib "console.log((await store.scan(root, 'legA')).length)")
out=$(as con send legA "$tmp/body" --doc "$tmp/no-such-doc.md" 2>&1); rc=$?
n=$(lib "console.log((await store.scan(root, 'legA')).length)")
if [ "$rc" -ne 0 ] && [ "$n" = "$n0" ]; then pass "a missing --doc refuses before anything is sent"; else fail "missing --doc (rc=$rc, legA log=$n): $out"; fi
else skip_section "send as a bound peer, --re acks, --doc mirror"; fi

echo "== gc =="
# Rotate legB's log into segments 0 and 1 (each record ~1.4 KB).
lib "
  const b = 'y'.repeat(1400);
  for (let i = 0; i < 400; i++) await store.append(root, 'legB', { i: 'r' + i, t: Date.now(), f: 'con', r: 'legB', b, c: 1 });
"
seg0=$(find "$XDG_STATE_HOME/himmel/bus/log" -name 'legB.0.jsonl.*' | head -1)
if [ -n "$seg0" ]; then pass "setup: legB log rotated into a closed segment"; else fail "setup: no closed segment"; fi
touch -t "$(ago 31)" "$XDG_STATE_HOME"/himmel/bus/log/legB.*.jsonl.*
out=$("$BUS" gc 2>&1)
if [ -e "$seg0" ] && printf '%s' "$out" | grep -q 'kept legB.0 (undelivered)'; then pass "gc keeps an aged segment the cursor has not passed"; else fail "gc undelivered: $out"; fi
# Deliver past segment 0.
lib "const r = await store.read(root, 'legB'); await store.commit(root, 'legB', r.next);"
touch -t "$(ago 29)" "$seg0"
out=$("$BUS" gc 2>&1)
if [ -e "$seg0" ] && ! printf '%s' "$out" | grep -q 'would remove legB.0'; then pass "gc keeps a delivered segment younger than 30 days"; else fail "gc removed a 29-day segment: $out"; fi
touch -t "$(ago 31)" "$seg0"
out=$("$BUS" gc 2>&1)
if [ -e "$seg0" ] && printf '%s' "$out" | grep -q 'would remove legB.0' && printf '%s' "$out" | grep -q 'HIMMEL-5072'; then pass "gc is report-only: names a delivered 31-day segment and the follow-up, deletes nothing"; else fail "gc delivered: $out"; fi
# Halted logs are kept and reported.
lib "
  for (let i = 0; i < 400; i++) await store.append(root, 'otherLeg', { i: 'h' + i, t: Date.now(), f: 'other', r: 'otherLeg', b: 'z'.repeat(1400) });
"
touch -t "$(ago 31)" "$XDG_STATE_HOME"/himmel/bus/log/otherLeg.*.jsonl.*
printf '{"k":1,"off":0,"n":99,"h":"%064d","halted":5}\n' 0 > "$XDG_STATE_HOME/himmel/bus/cur/otherLeg"
out=$("$BUS" gc 2>&1)
if printf '%s' "$out" | grep -q 'kept otherLeg.0 (halted)' && ls "$XDG_STATE_HOME"/himmel/bus/log/otherLeg.0.jsonl.* >/dev/null 2>&1; then pass "gc keeps and reports a halted log"; else fail "gc halted: $out"; fi

# KNOWN BREAK, why gc must not delete yet: store.scan chain-verifies
# from n=0, so a log with a segment removed scans as empty and --re / read #n die.
before=$(lib "console.log((await store.scan(root, 'legB')).length)")
rm -f "$seg0"
after=$(lib "console.log((await store.scan(root, 'legB')).length)")
if [ "$before" -gt 0 ] && [ "$after" = 0 ]; then pass "known break: scan of a log with a removed segment is empty ($before to $after), so gc stays report-only"; else fail "scan break not reproduced (before=$before after=$after)"; fi

if [ "$HAVE_PROC" = 1 ]; then
echo "== status --unacked =="
lib "
  const t = Date.now();
  const mk = (i, age, extra = {}) => ({ i, t: t - age, f: 'con', r: 'legA', b: 'ruling', ...extra });
  await store.append(root, 'legA', mk('old-unacked', 5 * 3600e3, { c: 1 }));
  await store.append(root, 'legA', mk('old-acked', 5 * 3600e3, { c: 1 }));
  await store.append(root, 'legA', mk('fresh-unacked', 60e3, { c: 1 }));
  await store.append(root, 'legA', mk('old-plain', 5 * 3600e3));
"
printf '{"i":"old-acked","re":"x","t":1}\n' >> "$XDG_STATE_HOME/himmel/bus/ack/legA.jsonl"
out=$(as con status --unacked 2>&1)
# state_of <id>: the last word of the listing line naming <id> (empty if absent).
state_of() { printf '%s\n' "$out" | grep -F "$1" | awk '{print $NF}'; }
[ "$(state_of old-unacked)" = expired ] && ok=1 || ok=0
if [ "$ok" = 1 ]; then pass "an aged unacked ruling prints expired"; else fail "expired: $out"; fi
if [ "$(state_of fresh-unacked)" = unacked ]; then pass "a fresh unacked ruling prints unacked"; else fail "unacked: $out"; fi
if [ -z "$(state_of old-acked)" ]; then pass "--unacked omits an acked ruling"; else fail "--unacked listed an acked ruling: $out"; fi
if [ -z "$(state_of old-plain)" ]; then pass "expiry applies to c=1 rulings only"; else fail "a c=0 record was listed: $out"; fi
out=$(as con status 2>&1)
if [ "$(state_of old-acked)" = acked ]; then pass "status without --unacked lists acked rulings"; else fail "status all: $out"; fi
out=$(as legA status --unacked --for other 2>&1)
if [ -z "$(state_of old-unacked)" ]; then pass "--for <console> filters to that sender"; else fail "--for filtered nothing: $out"; fi
out=$("$BUS" status --unacked 2>&1); rc=$?
if [ "$rc" -ne 0 ]; then pass "status --unacked from an unbound process is refused"; else fail "unbound status listed: $out"; fi
out=$("$BUS" status legA 2>&1)
case "$out" in live|gone) pass "bus status <name> keeps its live/gone meaning" ;; *) fail "status name: $out" ;; esac

echo "== wait (HIMMEL-4831) =="
"$BUS" register waiter --role leg --console con >/dev/null 2>&1
t0=$(date +%s)
out=$(as waiter wait --timeout 1 2>&1); rc=$?
t1=$(date +%s)
if [ "$rc" -eq 3 ] && [ $((t1 - t0)) -le 5 ]; then pass "wait on an empty inbox times out with exit 3"; else fail "wait timeout (rc=$rc, $((t1 - t0))s): $out"; fi
printf 'wake up rule\n' > "$tmp/wbody"
as con send waiter "$tmp/wbody" >/dev/null 2>&1
out=$(as waiter wait --timeout 5 2>&1); rc=$?
if [ "$rc" -eq 0 ] && grep -q 'from con' <<< "$out" && grep -q 'wake up rule' <<< "$out"; then pass "wait prints a pending message and exits 0"; else fail "wait receive (rc=$rc): $out"; fi
out=$(as waiter wait --timeout 1 2>&1); rc=$?
if [ "$rc" -eq 3 ]; then pass "a printed message is consumed: the next wait times out"; else fail "wait re-delivered (rc=$rc): $out"; fi
( sleep 1; as con send waiter "$tmp/wbody" >/dev/null 2>&1 ) &
t0=$(date +%s)
out=$(as waiter wait --timeout 20 2>&1); rc=$?
t1=$(date +%s)
wait
if [ "$rc" -eq 0 ] && [ $((t1 - t0)) -le 10 ] && grep -q 'wake up rule' <<< "$out"; then pass "wait blocks, then wakes on a later send"; else fail "wait wake (rc=$rc, $((t1 - t0))s): $out"; fi
out=$("$BUS" wait --timeout 1 2>&1); rc=$?
if [ "$rc" -ne 0 ] && [ "$rc" -ne 3 ] && grep -q 'identity unbound' <<< "$out"; then pass "wait from an unbound process is refused, not a timeout"; else fail "unbound wait (rc=$rc): $out"; fi
out=$(as waiter wait --timeout abc 2>&1); rc=$?
if [ "$rc" -ne 0 ] && [ "$rc" -ne 3 ] && grep -q 'positive number of seconds' <<< "$out"; then pass "wait refuses a non-numeric --timeout"; else fail "bad timeout (rc=$rc): $out"; fi
out=$(as waiter wait --timeout 99999999999999999999999999 2>&1); rc=$?
if [ "$rc" -ne 0 ] && [ "$rc" -ne 3 ] && grep -q 'at most 86400 seconds' <<< "$out"; then pass "wait refuses a --timeout beyond the cap"; else fail "huge timeout (rc=$rc): $out"; fi

echo "== succession adopt + unread (HIMMEL-6127) =="
"$BUS" register con2 --role console --predecessor con >/dev/null 2>&1
printf 'your console is now con2\n' > "$tmp/relay"
as con send legA "$tmp/relay" >/dev/null 2>&1
out=$(as con2 send legA "$tmp/body" 2>&1); rc=$?
if [ "$rc" -ne 0 ] && grep -q 'no edge to legA' <<< "$out"; then pass "without adopt the successor has no edge to the leg"; else fail "pre-adopt send (rc=$rc): $out"; fi
out=$(as legA adopt con2 2>&1); rc=$?
if [ "$rc" -eq 0 ] && [ "$out" = "adopted: legA console con -> con2" ]; then pass "adopt after a relay prints what it did"; else fail "adopt (rc=$rc): $out"; fi
out=$(as con2 send legA "$tmp/body" 2>&1); rc=$?
if [ "$rc" -eq 0 ]; then pass "after adopt the successor can send to the leg"; else fail "post-adopt send (rc=$rc): $out"; fi
out=$(as legA peers 2>&1)
if grep -q '^con2\b' <<< "$out" && ! grep -q '^con\b' <<< "$out"; then pass "the leg's peers lists the successor, not the predecessor"; else fail "peers: $out"; fi
if grep -qx 'con2 (gone)' <<< "$out"; then pass "peers marks a peer whose process is gone"; else fail "gone peer not marked: $out"; fi
"$BUS" register legL --role leg --console con2 >/dev/null 2>&1
sleep 60 & live_pid=$!
node "$tmp/repoint.mjs" legL "$live_pid" "$(cut -d' ' -f22 "/proc/$live_pid/stat")"
out=$(as con2 peers 2>&1)
kill "$live_pid" 2>/dev/null; wait "$live_pid" 2>/dev/null
if grep -qx 'legA (gone)' <<< "$out"; then pass "the successor's peers lists the leg"; else fail "successor peers: $out"; fi
if grep -qx legL <<< "$out"; then pass "peers prints a live peer bare"; else fail "live peer: $out"; fi
"$BUS" register legU --role leg --console con2 >/dev/null 2>&1
if grep -qx 'legU (unbound)' <<< "$(as con2 peers 2>&1)"; then pass "peers marks a registered, never-bound peer"; else fail "unbound peer not marked"; fi
else skip_section "status --unacked, wait, succession adopt"; fi
"$BUS" register idler --role leg --console con >/dev/null 2>&1
if [ "$HAVE_PROC" = 1 ]; then
as con send idler "$tmp/wbody" >/dev/null 2>&1; as con send idler "$tmp/wbody" >/dev/null 2>&1
if [ "$("$BUS" unread idler 2>&1)" = 1 ]; then pass "unread flags undelivered records without consuming them"; else fail "unread: $("$BUS" unread idler 2>&1)"; fi
if [ "$("$BUS" unread idler 2>&1)" = 1 ]; then pass "unread is read-only"; else fail "unread consumed"; fi
else skip_section "unread of undelivered records"; fi
# A corrupt cursor must still reach the delivery hook's read(), which persists the halt and its notice.
curdir=$(find "$XDG_STATE_HOME" -type d -name cur | head -1)
printf 'not json' > "$curdir/idler"; chmod 600 "$curdir/idler"
out=$("$BUS" unread idler 2>&1)
if [ "$out" = 1 ] && [ "$(cat "$curdir/idler")" = 'not json' ]; then pass "unread leaves a corrupt cursor for the hook to halt with its notice"; else fail "unread on a corrupt cursor: $out / $(cat "$curdir/idler")"; fi

[ "$failures" -eq 0 ] || { echo "FAILED: $failures"; exit 1; }
echo "all passed"
