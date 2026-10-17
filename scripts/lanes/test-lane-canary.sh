#!/usr/bin/env bash
# selector: tree-scan
# lane-canary.sh reports PASS / FAIL / SKIP per lane, never leaves
# a window or lock behind, and its brief template passes brief-lint.
# Platform: POSIX bash 3.2+. Launcher, closer, lock and append are fixtures; the
# real launch is the live POC is covered by the live POC.
# shellcheck disable=SC2016,SC2015,SC2012  # fixture scripts are literal; A && ok || bad is the suite's idiom
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
RUNNER="${LANE_CANARY:-$HERE/lane-canary.sh}"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "PASS: $1"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

T="$(mktemp -d "${TMPDIR:-/tmp}/lane-canary.XXXXXX")" || exit 1; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/root"
: > "$T/dotenv"
# an operator's real keys must not turn the unconfigured-lane case into a launch
unset OPENROUTER_API_KEY DEEPSEEK_API_KEY

# Fake launcher: the doc is the 6th argv (--profile P --lane L <name> <doc> ...).
# The two bullets are the exact lines the real native canary leg wrote (live
# POC, 2026-10-11, lane-canary-native-poc1.md).
cat > "$T/launcher.sh" <<'EOF'
#!/usr/bin/env bash
doc="$6"
echo "$*" >> "$LC_T/launched.log"
pwd >> "$LC_T/cwd.log"
case "$FAKE_MODE" in
    ok)     printf -- '- 16:51 LIVE — canary native first bullet\n- 16:51 WRAPPED — canary native done\n' >> "$doc" ;;
    wrapnolive) printf -- '- 16:51 WRAPPED — canary native done\n' >> "$doc" ;;
    liveonly) printf -- '- 16:51 LIVE — canary native first bullet\n' >> "$doc" ;;
    crash)  exit 3 ;;
    silent) sleep 30 ;;
esac
EOF
printf '#!/usr/bin/env bash\necho "$1" >> "$LC_T/closed.log"\n' > "$T/closer.sh"
printf '#!/usr/bin/env bash\ncase "$1" in status) echo free ;; release) echo "$2" >> "$LC_T/released.log" ;; esac\n' > "$T/lock.sh"
printf '#!/usr/bin/env bash\nprintf -- "- 12:00 %%s\\n" "$2" >> "$1"\n' > "$T/append.sh"

run() { # run <mode> <timeout> [extra args...]
    mode="$1"; to="$2"; shift 2
    rm -f "$T/launched.log" "$T/closed.log" "$T/released.log" "$T/root/"*
    FAKE_MODE="$mode" LC_T="$T" CANARY_LAUNCHER="$T/launcher.sh" CANARY_CLOSER="$T/closer.sh" \
        CANARY_LOCK="$T/lock.sh" CANARY_APPEND="$T/append.sh" CANARY_ROOT="$T/root" \
        CANARY_REPO="$T" CANARY_DOTENV="$T/dotenv" CANARY_POLL_SEC=1 CANARY_LOCK_WAIT=2 \
        bash "$RUNNER" --timeout "$to" --out "$T/report.json" "$@"
}

# T1: a leg that wraps passes, and its window is closed.
out="$(run ok 10 --lanes native)"; rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q "native *PASS"; then ok "T1 wrapping leg is PASS, exit 0"; else bad "T1 rc=$rc out=$out"; fi
grep -q '"native":{"result":"PASS"' "$T/report.json" 2>/dev/null && ok "T1 report.json carries PASS" || bad "T1 report: $(cat "$T/report.json" 2>/dev/null)"
[ -s "$T/closed.log" ] && ok "T1 window closed" || bad "T1 closer not called"

# T2 (control): a leg that never writes a bullet FAILs although the brief text
# itself names WRAPPED, and the runner wraps + closes it.
out="$(run silent 3 --lanes native)"; rc=$?
if [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q "native *FAIL.*no first bullet"; then ok "T2 silent leg is FAIL (not fooled by brief text), exit 1"; else bad "T2 rc=$rc out=$out"; fi
[ -s "$T/closed.log" ] && [ -s "$T/released.log" ] && ok "T2 timed-out leg is closed and its lock released" || bad "T2 leftovers: closed=$(cat "$T/closed.log" 2>/dev/null) released=$(cat "$T/released.log" 2>/dev/null)"

# T3: first bullet but no WRAPPED.
out="$(run liveonly 3 --lanes native)"; rc=$?
if [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q "no WRAPPED\|but no WRAPPED"; then ok "T3 live-only leg is FAIL"; else bad "T3 rc=$rc out=$out"; fi

# T4: launcher dies before any bullet.
out="$(run crash 10 --lanes native)"; rc=$?
if [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q "launcher exit 3"; then ok "T4 launcher crash is FAIL with its exit code"; else bad "T4 rc=$rc out=$out"; fi

# T5: an unconfigured lane is SKIP and never launched.
out="$(run ok 10 --lanes openrouter)"; rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q "openrouter *SKIP.*not configured" && [ ! -e "$T/launched.log" ]; then ok "T5 unconfigured lane SKIPs without launching"; else bad "T5 rc=$rc out=$out"; fi

# T6: native uses haiku, claudex takes the launcher default.
printf 'x\n' > "$T/claude-codex"; mkdir -p "$T/scripts"; : > "$T/scripts/claude-codex"
run ok 10 --lanes native,claudex >/dev/null
if grep -q "claude-haiku-5-5" "$T/launched.log" && [ "$(grep -c -- '--lane claudex' "$T/launched.log")" -eq 1 ] && ! grep -- '--lane claudex' "$T/launched.log" | grep -q haiku; then ok "T6 cheapest model per lane"; else bad "T6 launches: $(cat "$T/launched.log")"; fi

# T7: the rendered brief passes brief-lint and names no placeholder; the
# canary leg's cwd is the repo it was given, never a worktree path. A PASS
# prunes its files, so render through a failing leg, which keeps its doc.
run liveonly 2 --lanes claudex >/dev/null
doc="$(ls "$T/root"/lane-canary-claudex-*.md 2>/dev/null | head -1)"
if [ -n "$doc" ] && bash "$REPO/scripts/handover/console-kit/brief-lint.sh" "$doc" 2>/dev/null && ! grep -q '@[A-Z]*@' "$doc" && grep -q "^resume_cwd: $T$" "$doc"; then ok "T7 rendered brief lints and has no placeholders"; else bad "T7 doc=$doc"; fi

# T8: the leg is launched from the repo it was given, not the caller's cwd.
if [ -s "$T/cwd.log" ] && [ "$(sort -u "$T/cwd.log")" = "$(cd "$T" && pwd -P)" ]; then ok "T8 launched from the primary repo"; else bad "T8 cwd: $(cat "$T/cwd.log" 2>/dev/null)"; fi

# T9: a PASS prunes its generated files; a FAIL keeps its doc for diagnosis.
run ok 10 --lanes native >/dev/null
[ -z "$(find "$T/root" -name 'lane-canary-native-*' | head -1)" ] && ok "T9 PASS prunes its files" || bad "T9 left: $(ls "$T/root")"

# T10: a WRAPPED bullet with no LIVE first bullet is FAIL, not PASS.
out="$(run wrapnolive 10 --lanes native)"; rc=$?
if [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q "native *FAIL.*no LIVE"; then ok "T10 WRAPPED without LIVE is FAIL"; else bad "T10 rc=$rc out=$out"; fi

# T11: a flag missing its value exits 2 instead of looping.
out="$(timeout 10 bash "$RUNNER" --lanes 2>&1)"; rc=$?
if [ "$rc" -eq 2 ]; then ok "T11 trailing --lanes exits 2"; else bad "T11 rc=$rc out=$out"; fi

# T12: an unwritable report path makes the run FAIL.
out="$(run ok 10 --lanes native --out "$T/no-such-dir/report.json" 2>&1)"; rc=$?
if [ "$rc" -eq 1 ]; then ok "T12 unwritable report is exit 1"; else bad "T12 rc=$rc out=$out"; fi

# T13: a lane list with no lane in it (or an empty element) is a usage error.
out="$(timeout 10 bash "$RUNNER" --lanes , 2>&1)"; rc=$?
if [ "$rc" -eq 2 ]; then ok "T13 comma-only --lanes exits 2"; else bad "T13 rc=$rc out=$out"; fi

# T14: a zero or fractional poll interval is a usage error, not a stuck lock-wait.
out="$(CANARY_POLL_SEC=0 CANARY_ROOT="$T/root" timeout 10 bash "$RUNNER" --lanes native 2>&1)"; rc=$?
if [ "$rc" -eq 2 ]; then ok "T14 CANARY_POLL_SEC=0 exits 2"; else bad "T14 rc=$rc out=$out"; fi

# T15: a zero spelled 00 is still zero.
out="$(CANARY_POLL_SEC=00 CANARY_ROOT="$T/root" timeout 10 bash "$RUNNER" --lanes native 2>&1)"; rc=$?
if [ "$rc" -eq 2 ]; then ok "T15 CANARY_POLL_SEC=00 exits 2"; else bad "T15 rc=$rc out=$out"; fi

# T16: a repo path with sed metacharacters renders verbatim into the brief.
mkdir -p "$T/a&b|c"
rm -f "$T/root/"*
FAKE_MODE=liveonly LC_T="$T" CANARY_LAUNCHER="$T/launcher.sh" CANARY_CLOSER="$T/closer.sh" \
    CANARY_LOCK="$T/lock.sh" CANARY_APPEND="$T/append.sh" CANARY_ROOT="$T/root" \
    CANARY_REPO="$T/a&b|c" CANARY_DOTENV="$T/dotenv" CANARY_POLL_SEC=1 CANARY_LOCK_WAIT=2 \
    bash "$RUNNER" --timeout 2 --out "$T/report.json" --lanes native >/dev/null 2>&1
doc="$(ls "$T/root"/lane-canary-native-*.md 2>/dev/null | head -1)"
if [ -n "$doc" ] && grep -qF "resume_cwd: $T/a&b|c" "$doc"; then ok "T16 sed metacharacters in the repo path are escaped"; else bad "T16 doc=$doc"; fi

# T17: with no CANARY_ROOT and no --out, the default report lands under the handover root.
mkdir -p "$T/hd"
FAKE_MODE=ok LC_T="$T" CANARY_LAUNCHER="$T/launcher.sh" CANARY_CLOSER="$T/closer.sh" \
    CANARY_LOCK="$T/lock.sh" CANARY_APPEND="$T/append.sh" HANDOVER_DIR="$T/hd" \
    CANARY_REPO="$T" CANARY_DOTENV="$T/dotenv" CANARY_POLL_SEC=1 CANARY_LOCK_WAIT=2 \
    bash "$RUNNER" --timeout 10 --lanes native >/dev/null 2>&1
if [ -s "$T/hd/.canary/latest.json" ]; then ok "T17 default report lands under HANDOVER_DIR/.canary"; else bad "T17 no $T/hd/.canary/latest.json"; fi

echo "RESULT: pass=$PASS fail=$FAIL"
[ "$FAIL" -eq 0 ]
