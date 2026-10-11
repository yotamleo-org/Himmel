#!/usr/bin/env bash
# selector: tree-scan
# HIMMEL-5230: lane-canary.sh reports PASS / FAIL / SKIP per lane, never leaves
# a window or lock behind, and its brief template passes brief-lint.
# Platform: POSIX bash 3.2+. Launcher, closer, lock and append are fixtures; the
# real launch is the live POC recorded on HIMMEL-5230.
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

echo "RESULT: pass=$PASS fail=$FAIL"
[ "$FAIL" -eq 0 ]
