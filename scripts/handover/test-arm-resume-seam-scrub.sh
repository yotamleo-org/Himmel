#!/usr/bin/env bash
# test-arm-resume-seam-scrub.sh -- F2: `at` snapshots the
# submitting shell's env, so an arm made from inside a consult handed the
# resumed session WORKER_SESSION_PROFILE_NO_SETTING_SOURCES (and the rest of the launch
# seam: the shim, its binary, the profile files). The at job body now clears
# chief_context_launch_seam_env_names before claude starts.
#
# Everything here uses a STUB claude -- a real arm launches a real paid
# session. The at job body comes from `arm-resume.sh --dry-run` (the same
# $launch_lines the real `at` heredoc receives) and is run with the seam vars
# exported, exactly the env atd would replay.
#
# RED control: on the pre-fix body the stub sees every seam var still set.
#
# Usage: bash scripts/handover/test-arm-resume-seam-scrub.sh
# Exit:  0 = all pass, 1 = one or more failures.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ARM="$SCRIPT_DIR/arm-resume.sh"

TMP=$(mktemp -d "${TMPDIR:-/tmp}/arm-resume-seam-scrub.XXXXXX") || exit 1
trap 'rm -rf "$TMP"' EXIT
. "$SCRIPT_DIR/../lib/fleet-slots-shield.sh"
fleet_slots_shield "$TMP" || exit 1
export ARM_RESUME_LOG_DIR="$TMP/arm-logs"
export CADENCE_USAGE_CACHE="$TMP/bank-cache.json" CLAUDE_USAGE_CACHE="$TMP/bank-cache.json"
export SKILL_TELEMETRY_DIR="$TMP/telemetry"
export WORKSPACE_TRUST_CONFIG="$TMP/claude-trust.json"
export HIMMEL_FLOW_RUNS_LEDGER="$TMP/flow-runs.jsonl"
unset HIMMEL_HEADROOM_PROXY HEADROOM_BIN ARMAUTOMERGE 2>/dev/null || true
mkdir -p "$TMP/dotenv-empty"
export ARM_RESUME_DOTENV_ROOT="$TMP/dotenv-empty"

FAILED=0
assert_eq() {
    local label="$1" expected="$2" actual="$3"
    if [ "$actual" = "$expected" ]; then echo "PASS $label"
    else echo "FAIL $label -- expected '$expected', got '$actual'"; FAILED=$((FAILED + 1)); fi
}

WORK_REPO="$TMP/work-repo"
mkdir -p "$WORK_REPO"
git init -q "$WORK_REPO"
HANDOVER_DIR="$TMP/statedocs/handovers"
mkdir -p "$HANDOVER_DIR"
git init -q "$TMP/statedocs"
future_time() { python3 -c 'import datetime; print((datetime.datetime.now()+datetime.timedelta(minutes=30)).strftime("%H:%M"))'; }
HANDOVER="$HANDOVER_DIR/handover-seam.md"
printf -- '---\nsession_kind: test\nresume_cwd: %s\n---\n# Test handover\n' "$WORK_REPO" > "$HANDOVER"

SCHED_STUB="$TMP/sched-stub"
mkdir -p "$SCHED_STUB"
printf '#!/usr/bin/env bash\nexit 0\n' > "$SCHED_STUB/atq"
printf '#!/usr/bin/env bash\nexit 0\n' > "$SCHED_STUB/at"
printf '#!/usr/bin/env bash\nexit 1\n' > "$SCHED_STUB/powershell"
chmod +x "$SCHED_STUB/atq" "$SCHED_STUB/at" "$SCHED_STUB/powershell"
export FLEET_PS_CMD="$SCHED_STUB/atq"

# Stub claude: record which of the watched vars it can see.
STUB_BIN="$TMP/stub-bin"
mkdir -p "$STUB_BIN"
cat > "$STUB_BIN/claude" <<'EOF'
#!/usr/bin/env bash
for v in $WATCH; do
    if [ -n "${!v+x}" ]; then echo "$v=set"; else echo "$v=gone"; fi
done > "$CLAUDE_REC"
exit 0
EOF
chmod +x "$STUB_BIN/claude"

BODY=$(env PATH="$SCHED_STUB:$PATH" OSTYPE=linux-gnu bash "$ARM" --time "$(future_time)" \
        --handover "$HANDOVER" --dry-run 2>&1 \
      | awk '/^DRY arm-resume: would at -t/{on=1; next} /^    CMD$/{on=0} on{sub(/^    /,""); print}')
case "$BODY" in *"cd "*) echo "PASS S0 dry-run yields an at body" ;; *) echo "FAIL S0 no at body"; FAILED=$((FAILED + 1)) ;; esac

NSS=WORKER_SESSION_PROFILE_NO_SETTING_SOURCES
RETIRED_NSS=LEG_PROFILE_NO_SETTING_SOURCES # old-term-ok
SEAM="HEADED_ARM_LAUNCHER HEADED_ARM_LAUNCHER_ENV HEADED_ARM_LAUNCHER_ENV_LINES
      WORKER_SESSION_PROFILE_SETTINGS WORKER_SESSION_PROFILE_PREFACE WORKER_SESSION_PROFILE_MCP_CONFIG
      WORKER_SESSION_PROFILE_NO_SETTING_SOURCES WORKER_SESSION_CLAUDE_BIN"
KEEP="HIMMEL_CONSOLE_LEG HANDOVER_DIR HIMMEL_WORKER"
REC="$TMP/rec"
# The env atd replays: the consult's seam plus a worker identity that must survive.
# No pty (HIMMEL_PTY_SCRIPT_CMD points nowhere): the bare fallback runs the stub directly.
# shellcheck disable=SC2086
env PATH="$STUB_BIN:$PATH" CLAUDE_REC="$REC" WATCH="$SEAM $KEEP" HIMMEL_PTY_SCRIPT_CMD="$TMP/no-such-script" \
    HEADED_ARM_LAUNCHER=/x/shim.sh \
    HEADED_ARM_LAUNCHER_ENV=A=1 HEADED_ARM_LAUNCHER_ENV_LINES=B=2 HIMMEL_CONSOLE_LEG=1 HANDOVER_DIR="$HANDOVER_DIR" HIMMEL_WORKER=1 \
    WORKER_SESSION_PROFILE_SETTINGS=/x/s.json WORKER_SESSION_PROFILE_PREFACE=/x/p.md \
    WORKER_SESSION_PROFILE_MCP_CONFIG=/x/m.json WORKER_SESSION_PROFILE_NO_SETTING_SOURCES=1 \
    WORKER_SESSION_CLAUDE_BIN=/x/claude \
    sh -c "$BODY" </dev/null >"$TMP/job.out" 2>&1
R=$(cat "$REC" 2>/dev/null)
for v in $SEAM; do
    assert_eq "S1 the resumed session does not inherit $v" "$v=gone" "$(printf '%s\n' "$R" | grep "^$v=")"
done
# Counter-examples: identity and guard vars are NOT launch seam; clearing them would widen.
for v in $KEEP; do
    assert_eq "S2 the resumed session keeps $v" "$v=set" "$(printf '%s\n' "$R" | grep "^$v=")"
done

# clearing the seam (above) leaves a resumed consult as a bare, UNconfined
# claude, so arm-resume refuses to arm from inside a consult at all (fail closed).
rc=0
OUT3=$(env PATH="$SCHED_STUB:$PATH" OSTYPE=linux-gnu "$NSS=1" bash "$ARM" --time "$(future_time)" \
        --handover "$HANDOVER" --dry-run 2>&1) || rc=$?
assert_eq "S3 arm-resume from inside a consult refuses (exit 2)" "2" "$rc"
case "$OUT3" in *"refusing to arm from inside a consult"*) echo "PASS S3 refusal says why" ;; *) echo "FAIL S3 refusal text missing: $OUT3"; FAILED=$((FAILED + 1)) ;; esac
case "$OUT3" in *"would at -t"*) echo "FAIL S3 an at body was still produced"; FAILED=$((FAILED + 1)) ;; *) echo "PASS S3 no at body" ;; esac
# Counter-example: an empty value is not a consult (the shim confines only on exactly 1,
# but any non-empty value refuses, fail closed); empty still arms.
rc=0
env PATH="$SCHED_STUB:$PATH" OSTYPE=linux-gnu "$NSS=" bash "$ARM" --time "$(future_time)" \
    --handover "$HANDOVER" --dry-run >/dev/null 2>&1 || rc=$?
assert_eq "S3 an empty no-setting-sources flag still arms (exit 0)" "0" "$rc"
# The retired name no longer marks a consult: it is ignored and the arm proceeds.
rc=0
env PATH="$SCHED_STUB:$PATH" OSTYPE=linux-gnu "$RETIRED_NSS=1" bash "$ARM" --time "$(future_time)" \
    --handover "$HANDOVER" --dry-run >/dev/null 2>&1 || rc=$?
assert_eq "S3 the retired no-setting-sources name is ignored and still arms (exit 0)" "0" "$rc"

# the read-only --list-temp-arms sweep arms nothing, so a consult may run it,
# but ONLY as the sole argument; every other mode, or the flag beside one, still refuses.
rc=0
OUT4=$(env PATH="$SCHED_STUB:$PATH" OSTYPE=linux-gnu "$NSS=1" bash "$ARM" --list-temp-arms 2>&1) || rc=$?
case "$OUT4" in *"refusing to arm from inside a consult"*) echo "FAIL S4 --list-temp-arms refused in a consult: $OUT4"; FAILED=$((FAILED + 1)) ;; *) echo "PASS S4 --list-temp-arms is not refused in a consult" ;; esac
case "$rc" in 0|16|18) echo "PASS S4 sweep ran (exit $rc)" ;; *) echo "FAIL S4 sweep exit $rc"; FAILED=$((FAILED + 1)) ;; esac
for combo in "--list-temp-arms --dry-run" "--dry-run --list-temp-arms" "--list-temp-arms --time 23:59" "--list-temp-arms --force" "--time 23:59 --handover $HANDOVER --dry-run"; do
    rc=0
    # shellcheck disable=SC2086
    OUT5=$(env PATH="$SCHED_STUB:$PATH" OSTYPE=linux-gnu "$NSS=1" bash "$ARM" $combo 2>&1) || rc=$?
    assert_eq "S4 consult + '$combo' refuses (exit 2)" "2" "$rc"
    case "$OUT5" in *"refusing to arm from inside a consult"*) echo "PASS S4 '$combo' refusal says why" ;; *) echo "FAIL S4 '$combo' refusal text missing: $OUT5"; FAILED=$((FAILED + 1)) ;; esac
done

MARK_LINE="export HIMMEL_BRIDGE_SESSION=1"
printf '#!/usr/bin/env bash\nexit 0\n' > "$SCHED_STUB/crontab"
printf '#!/usr/bin/env bash\nexit 0\n' > "$SCHED_STUB/headroom"
chmod +x "$SCHED_STUB/crontab" "$SCHED_STUB/headroom"
mkdir -p "$TMP/apps/Terminal.app" "$TMP/runners"
dry_body() {
    local mark="$1" kind="$2" plat=linux-gnu term=none proxy=
    case "$kind" in runner) plat=darwin23 ;; command) plat=darwin23 term=Terminal ;; at-proxied) proxy=1 ;; esac
    local -a envs=(env -u HIMMEL_BRIDGE_SESSION PATH="$STUB_BIN:$SCHED_STUB:$PATH" OSTYPE="$plat"
                   ARM_TERMINAL_APP="$term" ARM_APP_DIRS="$TMP/apps" ARM_RUNNER_DIR="$TMP/runners")
    [ "$mark" = 1 ] && envs+=(HIMMEL_BRIDGE_SESSION=1)
    [ -n "$proxy" ] && envs+=(HIMMEL_HEADROOM_PROXY=1 HEADROOM_BIN="$SCHED_STUB/headroom")
    "${envs[@]}" bash "$ARM" --time "$(future_time)" --handover "$HANDOVER" --dry-run 2>/dev/null \
      | case "$kind" in
          at|at-proxied) awk '/^DRY arm-resume: would at -t/{on=1; next} /^    CMD$/{on=0} on{sub(/^    /,""); print}' ;;
          runner)  awk '/^DRY arm-resume: runner \(/{on=1; next} /^DRY arm-resume:/{on=0} on{sub(/^    /,""); print}' ;;
          command) awk '/^DRY arm-resume: command file \(/{on=1; next} /^DRY arm-resume:/{on=0} on{sub(/^    /,""); print}' ;;
        esac
}
marker_after_scrub() {
    printf '%s\n' "$1" | awk -v m="$MARK_LINE" '
        { s = s $0 "\n" }
        END {
            pm = index(s, m); pl = index(s, "unset ARMAUTOMERGE"); ps = index(s, "unset WORKER_SESSION_PROFILE_SETTINGS")
            if (pm && pl && pm < pl && (ps == 0 || ps < pm)) print "ok"; else print "bad m=" pm " launch=" pl " scrub=" ps
        }'
}
for kind in at at-proxied runner command; do
    B1=$(dry_body 1 "$kind")
    case "$B1" in *"claude"*) ;; *) echo "FAIL T18 $kind: no body printed"; FAILED=$((FAILED + 1)); continue ;; esac
    [ "$kind" = at-proxied ] && case "$B1" in *"mode=proxied"*) ;; *) echo "FAIL T18 at-proxied: the body is not the proxied form"; FAILED=$((FAILED + 1)) ;; esac
    case "$B1" in *"$MARK_LINE"*) echo "PASS T18 $kind body carries the marker export" ;;
        *) echo "FAIL T18 $kind body has no '$MARK_LINE'"; FAILED=$((FAILED + 1)) ;; esac
    assert_eq "T18 $kind marker sits after the seam scrub, before claude" "ok" "$(marker_after_scrub "$B1")"
    B0=$(dry_body 0 "$kind")
    case "$B0" in *HIMMEL_BRIDGE_SESSION*) echo "FAIL T18 $kind body names the marker with none in the caller's env"; FAILED=$((FAILED + 1)) ;;
        *) echo "PASS T18 $kind body names no marker without one" ;; esac
done
wrapped_body() {
    HIMMEL_BRIDGE_SESSION=1 PATH="$STUB_BIN:$SCHED_STUB:$PATH" OSTYPE=linux-gnu ARM_TERMINAL_APP=none \
        ARM_APP_DIRS="$TMP/apps" ARM_RUNNER_DIR="$TMP/runners" \
        ARM_UNDER_TEST="$ARM" ARM_TIME="$(future_time)" ARM_DOC="$HANDOVER" \
        bash -c '"$@" env -u HIMMEL_BRIDGE_SESSION bash "$ARM_UNDER_TEST" --time "$ARM_TIME" --handover "$ARM_DOC" --dry-run 2>/dev/null; :' wrap "$@" \
      | awk '/^DRY arm-resume: would at -t/{on=1; next} /^    CMD$/{on=0} on{sub(/^    /,""); print}'
}
for w in "" "nohup" "timeout 60" "nice -n 5"; do
    read -r -a wrap <<<"$w"
    BW=$(wrapped_body "${wrap[@]}")
    case "$BW" in *"claude"*) ;; *) echo "FAIL T18 wrapper '${w:-env -u}': no body printed"; FAILED=$((FAILED + 1)); continue ;; esac
    case "$BW" in *"$MARK_LINE"*) echo "PASS T18 wrapper '${w:-env -u}' still yields a marked body" ;;
        *) echo "FAIL T18 wrapper '${w:-env -u}' dropped the marker"; FAILED=$((FAILED + 1)) ;; esac
done
B_AT=$(dry_body 1 at)
env -u HIMMEL_BRIDGE_SESSION PATH="$STUB_BIN:$PATH" CLAUDE_REC="$TMP/rec-at" WATCH=HIMMEL_BRIDGE_SESSION \
    HIMMEL_PTY_SCRIPT_CMD="$TMP/no-such-script" sh -c "$B_AT" </dev/null >/dev/null 2>&1
assert_eq "T18 the stub claude run from the at body sees the marker" "HIMMEL_BRIDGE_SESSION=set" "$(cat "$TMP/rec-at" 2>/dev/null)"
B_RUN=$(dry_body 1 runner)
mkdir -p "$TMP/arm-logs"
env -i PATH="$STUB_BIN:$SCHED_STUB:/usr/bin:/bin" HOME="$TMP" CLAUDE_REC="$TMP/rec-runner" WATCH=HIMMEL_BRIDGE_SESSION \
    ARM_RESUME_LOG_DIR="$TMP/arm-logs" HIMMEL_FLOW_RUNS_LEDGER="$TMP/flow-runs.jsonl" sh -c "$B_RUN" </dev/null >/dev/null 2>&1
assert_eq "T18 the stub claude run from the crontab runner sees the marker" "HIMMEL_BRIDGE_SESSION=set" "$(cat "$TMP/rec-runner" 2>/dev/null)"

echo "---"
if [ "$FAILED" -gt 0 ]; then echo "FAILED: $FAILED case(s)"; exit 1; fi
echo "PASS all cases"
exit 0
