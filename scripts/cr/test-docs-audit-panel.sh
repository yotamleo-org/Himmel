#!/usr/bin/env bash
# Smoke test for scripts/cr/docs-audit-panel.sh.
#
# Hermetic: builds a throwaway "toolroot" fixture (mirroring the real
# scripts/cr, scripts/lib, scripts/guardrails layout so the SUT's
# SCRIPT_DIR/HIMMEL_ROOT derivation resolves inside the fixture) plus a
# throwaway git repo the SUT's own git commands run against. The real
# critic-panel.sh is NEVER on disk under the fixture's HIMMEL_ROOT - a stub
# takes its place, so the (paid, real-money) critic panel can never be
# invoked no matter what the SUT does. PATH is stripped of rtk's install dir
# for every SUT invocation, so the SUT's `command -v rtk` fails unless a row
# puts the STUB rtk (below) on PATH on purpose: only T3f and T7d do, so the
# real rtk is never run and can never write its own cache/log files outside
# this fixture.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUT_SRC="$DIR/docs-audit-panel.sh"

fail=0
check() { [ "$1" = "$2" ] || { echo "FAIL: $3 - got '$1' want '$2'"; fail=1; }; }
contains() {
    case "$1" in
        *"$2"*) : ;;
        *) echo "FAIL: $3 - expected output to contain '$2', got: $1"; fail=1 ;;
    esac
}
not_contains() {
    case "$1" in
        *"$2"*) echo "FAIL: $3 - unexpectedly contains '$2'"; fail=1 ;;
        *) : ;;
    esac
}

tmp="$(mktemp -d -t docs-audit-panel-test.XXXXXX)"; trap 'rm -rf "$tmp"' EXIT

# A throwaway HOME: CR_REQUIRE_CROSS_MODEL is gate policy, read from
# $HOME/.himmel/config.json .policy and never from the process env.
export HOME="$tmp/home"
# The policy dir comes from the account entry; this seam points it back at HOME.
export HIMMEL_POLICY_FOLLOWS_HOME=1
mkdir -p "$HOME/.himmel"
# set_policy <value> - write the policy file; "" leaves the key out.
set_policy() {
    if [ -n "$1" ]; then printf '{"version":1,"policy":{"CR_REQUIRE_CROSS_MODEL":"%s"}}\n' "$1" > "$HOME/.himmel/config.json"
    else printf '{"version":1,"policy":{}}\n' > "$HOME/.himmel/config.json"; fi
}

# --- Fixture toolroot: docs-audit-panel.sh (SUT) + the two real libs it
# sources + a STUBBED critic-panel.sh, all under one throwaway HIMMEL_ROOT. ---
root="$tmp/root"
mkdir -p "$root/scripts/cr" "$root/scripts/lib" "$root/scripts/guardrails"
cp "$SUT_SRC" "$root/scripts/cr/docs-audit-panel.sh"
cp "$DIR/anchor-handoff.sh" "$DIR/base-resolver.sh" "$root/scripts/cr/"
cp "$DIR/../lib/load-dotenv.sh" "$DIR/../lib/chokepoint-seam-guard.sh" "$root/scripts/lib/"
cp "$DIR/../guardrails/lib.sh" "$root/scripts/guardrails/lib.sh"
SUT="$root/scripts/cr/docs-audit-panel.sh"

STUB_MARKER="$tmp/stub-called"
STUB="$root/scripts/cr/critic-panel.sh"
cat > "$STUB" <<'STUBEOF'
#!/usr/bin/env bash
# swallow the piped diff, like the real panel does (STUB_STDIN keeps a copy)
if [ -n "${STUB_STDIN:-}" ]; then cat > "$STUB_STDIN"; else cat >/dev/null; fi
[ -n "${STUB_MARKER:-}" ] && : > "$STUB_MARKER"
[ -n "${STUB_ARGS:-}" ] && printf '%s\n' "$*" > "$STUB_ARGS"
[ -n "${STUB_OUT:-}" ] && printf '%s\n' "$STUB_OUT"
[ -n "${STUB_ERR:-}" ] && printf '%s\n' "$STUB_ERR" >&2
exit "${STUB_RC:-0}"
STUBEOF
chmod +x "$STUB"
export STUB_MARKER

# --- A tiny real git repo: the SUT's git commands run against this as CWD. --
repo="$tmp/repo"
mkdir -p "$repo"
(
    cd "$repo" || exit 1
    git init -q -b main .
    git config user.email t@t
    git config user.name t
    git config commit.gpgsign false
    echo base > f.txt
    git add f.txt
    git commit -q -m init
    git checkout -q -b feat
    echo change >> f.txt
    git commit -q -am change
)
head_feat="$(git -C "$repo" rev-parse feat)"
head_main="$(git -C "$repo" rev-parse main)"

# PATH with rtk's actual install dir stripped (see file header) - resolved
# via `command -v`, not a hardcoded `.local/bin` guess, so this stays
# hermetic wherever rtk happens to be installed.
rtk_bin="$(command -v rtk 2>/dev/null || true)"
if [ -n "$rtk_bin" ]; then
    rtk_dir="$(cd "$(dirname "$rtk_bin")" && pwd)"
    SAFE_PATH="$(printf '%s\n' "$PATH" | tr ':' '\n' | grep -v -x -F "$rtk_dir" | tr '\n' ':')"
else
    SAFE_PATH="$PATH"
fi
SAFE_PATH="${SAFE_PATH%:}"

stdout_file="$tmp/out.txt"
stderr_file="$tmp/err.txt"
run_sut() {
    rm -f "$STUB_MARKER"
    ( cd "$repo" && PATH="$SAFE_PATH" bash "$SUT" "$@" ) >"$stdout_file" 2>"$stderr_file"
    echo $?
}

# 1. Missing --head refuses with usage error, exit 2.
rc=$(run_sut --branch feat)
check "$rc" "2" "T1 rc"
contains "$(cat "$stderr_file")" "docs-audit-panel: --head is required" "T1 stderr"
check "$(cat "$stdout_file")" "" "T1 stdout"

# 2. Missing --branch refuses with usage error, exit 2.
rc=$(run_sut --head "$head_feat")
check "$rc" "2" "T2 rc"
contains "$(cat "$stderr_file")" "docs-audit-panel: --branch is required" "T2 stderr"
check "$(cat "$stdout_file")" "" "T2 stdout"

# 3. Policy unset, the critic still runs. ready-check item 4 and the
# merge gate need a non-Claude row at the head whatever the policy says.
unset CR_REQUIRE_CROSS_MODEL CR_PROFILE 2>/dev/null || true
set_policy ""
export STUB_OUT="[docsaudit-1] some finding" STUB_ERR="panel-availability: fake ok" STUB_RC=0
rc=$(run_sut --head "$head_feat" --branch feat)
check "$rc" "0" "T3 rc"
check "$(cat "$stdout_file")" "[docsaudit-1] some finding" "T3 stdout carries the findings"
check "$(cat "$stderr_file")" "panel-availability: fake ok" "T3 stderr carries the availability line"
[ -e "$STUB_MARKER" ] || { echo "FAIL: T3 the critic must run with the policy unset"; fail=1; }

# 3b. A falsy policy value runs it too.
set_policy 0
rc=$(run_sut --head "$head_feat" --branch feat)
check "$rc" "0" "T3b rc"
[ -e "$STUB_MARKER" ] || { echo "FAIL: T3b the critic must run with the policy falsy"; fail=1; }

# 3c. An unreadable policy file changes nothing: the lane no longer reads it.
printf 'not json' > "$HOME/.himmel/config.json"
rc=$(run_sut --head "$head_feat" --branch feat)
check "$rc" "0" "T3c rc"
[ -e "$STUB_MARKER" ] || { echo "FAIL: T3c the critic must run with an unreadable policy file"; fail=1; }
not_contains "$(cat "$stderr_file")" "could not read CR_REQUIRE_CROSS_MODEL" "T3c no policy note"
set_policy ""

# 3d. Policy off, critic out of quota: the lane degrades at exit 0, drops the
# findings, says the head is held, and writes no ok row of its own.
ledger="$repo/.git/cr-critic-scores.jsonl"
rm -f "$ledger"
export STUB_RC=1 STUB_OUT="should-be-discarded" STUB_ERR="panel-availability: codex unavailable (quota)"
rc=$(run_sut --head "$head_feat" --branch feat)
check "$rc" "0" "T3d rc (degrade, not abort)"
check "$(cat "$stdout_file")" "" "T3d stdout (findings discarded)"
contains "$(cat "$stderr_file")" "panel-availability: codex unavailable (quota)" "T3d re-emits the availability line"
contains "$(cat "$stderr_file")" "ready-check item 4 and the merge gate hold this head" "T3d names the hold"
[ -e "$STUB_MARKER" ] || { echo "FAIL: T3d stub was never invoked"; fail=1; }
[ ! -e "$ledger" ] || { echo "FAIL: T3d the lane wrote a ledger row of its own"; fail=1; }

# 3e. No temp file: nothing is reviewed, so the panel never runs, and the lane
# degrades at exit 0 naming the hold.
rm -f "$STUB_MARKER"
rc=0
( cd "$repo" && TMPDIR="$tmp/no-such-dir" PATH="$SAFE_PATH" bash "$SUT" --head "$head_feat" --branch feat ) \
    >"$stdout_file" 2>"$stderr_file" || rc=$?
check "$rc" "0" "T3e rc"
contains "$(cat "$stderr_file")" "mktemp failed - check free space in TMPDIR) - ready-check item 4" "T3e names the cause and the hold"
[ ! -e "$STUB_MARKER" ] || { echo "FAIL: T3e the panel ran without a temp file"; fail=1; }

# 3f. No temp file on the rtk retry: the first run's availability rows still
# reach stderr. A stub rtk on PATH removes the temp dir, so the retry's mktemp
# fails. Only this row and 7d use it.
mkdir -p "$tmp/rtk-stub" "$tmp/vanishing"
RTK_MARKER="$tmp/rtk-called"
cat > "$tmp/rtk-stub/rtk" <<'RTKEOF'
#!/usr/bin/env bash
printf '%s\n' "$*" > "$RTK_MARKER"
[ -z "${RTK_WIPE_TMPDIR:-}" ] || rm -rf "$TMPDIR"
echo "diff --git a/f.txt b/f.txt"
RTKEOF
chmod +x "$tmp/rtk-stub/rtk"
rc=0
( cd "$repo" && RTK_MARKER="$RTK_MARKER" RTK_WIPE_TMPDIR=1 TMPDIR="$tmp/vanishing" PATH="$tmp/rtk-stub:$SAFE_PATH" bash "$SUT" --head "$head_feat" --branch feat ) \
    >"$stdout_file" 2>"$stderr_file" || rc=$?
check "$rc" "0" "T3f rc"
contains "$(cat "$stderr_file")" "panel-availability: codex unavailable (quota)" "T3f keeps the first run's availability row"
contains "$(cat "$stderr_file")" "mktemp failed - check free space in TMPDIR) - ready-check item 4" "T3f names the cause and the hold"

# 3g. origin/main ahead of local main, and the clone has not fetched it yet:
# the pin is the fetched origin tip, the one critic-panel.sh verifies against.
origin_bare="$tmp/origin.git"
git clone -q --bare "$repo" "$origin_bare"
git -C "$origin_bare" symbolic-ref HEAD refs/heads/main
lagging="$tmp/lagging"
git clone -q "$origin_bare" "$lagging"
git -C "$lagging" checkout -q feat
origin_new="$(git -C "$origin_bare" -c user.email=t@t -c user.name=t commit-tree "$head_main^{tree}" -p "$head_main" -m next)"
git -C "$origin_bare" update-ref refs/heads/main "$origin_new"
STUB_ARGS="$tmp/stub-args"
rm -f "$STUB_MARKER" "$STUB_ARGS"
rc=0
( cd "$lagging" && STUB_RC=0 STUB_ARGS="$STUB_ARGS" PATH="$SAFE_PATH" bash "$SUT" --head "$head_feat" --branch feat ) \
    >"$stdout_file" 2>"$stderr_file" || rc=$?
check "$rc" "0" "T3g rc"
contains "$(cat "$STUB_ARGS" 2>/dev/null)" "--base-sha $origin_new" "T3g pins the fetched origin tip"
check "$(git -C "$lagging" rev-parse main)" "$head_main" "T3g local main stayed behind"

# 3h. A repo with an origin that cannot be fetched aborts, as the full lane
# does: the cached ref may be stale, so the pin cannot be trusted.
git -C "$lagging" remote set-url origin "$tmp/no-such-origin.git"
rm -f "$STUB_MARKER"
rc=0
( cd "$lagging" && STUB_RC=0 PATH="$SAFE_PATH" bash "$SUT" --head "$head_feat" --branch feat ) \
    >"$stdout_file" 2>"$stderr_file" || rc=$?
check "$rc" "7" "T3h rc"
contains "$(cat "$stderr_file")" "docs-audit-panel ABORT - could not fetch origin/main" "T3h names the fetch"
[ ! -e "$STUB_MARKER" ] || { echo "FAIL: T3h the panel ran on an unfetched base"; fail=1; }

# 3i. A diff base that names no commit aborts at exit 7 and the
# panel never runs. A repo with only `trunk` has no origin and no main to fall
# back to, so the base the resolver names does not resolve.
nobase="$tmp/nobase"
mkdir -p "$nobase"
(
    cd "$nobase" || exit 1
    git init -q -b trunk .
    git config user.email t@t
    git config user.name t
    git config commit.gpgsign false
    echo base > f.txt
    git add f.txt
    git commit -q -m init
)
nobase_head="$(git -C "$nobase" rev-parse trunk)"
rm -f "$STUB_MARKER"
rc=0
( cd "$nobase" && STUB_RC=0 PATH="$SAFE_PATH" bash "$SUT" --head "$nobase_head" --branch trunk ) \
    >"$stdout_file" 2>"$stderr_file" || rc=$?
check "$rc" "7" "T3i rc (unresolvable diff base aborts)"
contains "$(cat "$stderr_file")" "docs-audit-panel ABORT - diff base " "T3i names the base"
contains "$(cat "$stderr_file")" "does not resolve to a commit. Nothing was reviewed and nothing was recorded" "T3i says nothing was recorded"
[ ! -e "$STUB_MARKER" ] || { echo "FAIL: T3i the panel ran on an unresolvable diff base"; fail=1; }

# 3j. A failed git diff holds the head, naming the hold, and the
# panel never runs. A head with no common ancestor makes `git diff base...head`
# fail ("no merge base").
orphan_head="$(git -C "$repo" -c user.email=t@t -c user.name=t commit-tree "$(git -C "$repo" hash-object -t tree /dev/null)" -m orphan)"
rm -f "$STUB_MARKER"
rc=0
( cd "$repo" && STUB_RC=0 PATH="$SAFE_PATH" bash "$SUT" --head "$orphan_head" --branch feat ) \
    >"$stdout_file" 2>"$stderr_file" || rc=$?
check "$rc" "0" "T3j rc (a failed diff degrades, not aborts)"
contains "$(cat "$stderr_file")" "git diff failed rc=" "T3j names the diff failure"
contains "$(cat "$stderr_file")" "docs-audit: no critic ok row from this run - ready-check item 4 and the merge gate hold this head until a re-run records avail ok" "T3j names the hold"
[ ! -e "$STUB_MARKER" ] || { echo "FAIL: T3j the panel ran after a failed diff"; fail=1; }

# 4. CR_PROFILE=none wins even under CR_REQUIRE_CROSS_MODEL: prints the
# claude-only note, panel never invoked, exit 0.
set_policy 1
export CR_PROFILE=none
rc=$(run_sut --head "$head_feat" --branch feat)
check "$rc" "0" "T4 rc"
check "$(cat "$stdout_file")" "" "T4 stdout"
check "$(cat "$stderr_file")" "docs-audit: claude-only (CR_PROFILE=none) - cross-model critic not launched; marker stays closed under CR_REQUIRE_CROSS_MODEL until a non-Claude responder exists or CR_PROFILE is unset; with the policy off the marker clears and the merge gate passes, but ready-check item 4 still fails with no non-Claude row at the head" "T4 stderr"
[ ! -e "$STUB_MARKER" ] || { echo "FAIL: T4 stub was invoked under CR_PROFILE=none"; fail=1; }

# 4b. CR_PROFILE=none is the opt-out with the policy off too.
set_policy ""
rc=$(run_sut --head "$head_feat" --branch feat)
check "$rc" "0" "T4b rc"
[ ! -e "$STUB_MARKER" ] || { echo "FAIL: T4b stub was invoked under CR_PROFILE=none with the policy off"; fail=1; }

# 5. Empty diff (head == base) prints the skip note, panel never invoked.
set_policy 1
unset CR_PROFILE 2>/dev/null || true
rc=$(run_sut --head "$head_main" --branch main)
check "$rc" "0" "T5 rc"
check "$(cat "$stdout_file")" "" "T5 stdout"
check "$(cat "$stderr_file")" "docs-audit cross-model critic skipped: empty diff (marker will stay closed under CR_REQUIRE_CROSS_MODEL unless another non-Claude avail-ok row exists; ready-check item 4 fails this head on the same condition)" "T5 stderr"
[ ! -e "$STUB_MARKER" ] || { echo "FAIL: T5 stub was invoked on an empty diff"; fail=1; }

# 6. Stubbed panel exit 7 (input-pin mismatch): ABORT, exit 7, nothing on
# stdout, the exact ABORT block on stderr and nothing else
# (never a degrade).
set_policy 1
unset CR_PROFILE 2>/dev/null || true
export STUB_RC=7 STUB_OUT="should-be-discarded" STUB_ERR="panel-availability: fake unavailable (rc=7)"
rc=$(run_sut --head "$head_feat" --branch feat)
check "$rc" "7" "T6 rc"
check "$(cat "$stdout_file")" "" "T6 stdout"
expect_abort="/pr-check ABORT - docs-audit critic-panel.sh exit 7: the checkout or the diff
base moved since step 1, so the review inputs no longer match the branch/SHA/base
the ledger would stamp. Nothing was reviewed and
nothing was recorded. Re-run /pr-check from step 1."
check "$(cat "$stderr_file")" "$expect_abort" "T6 stderr exact ABORT block"
[ -e "$STUB_MARKER" ] || { echo "FAIL: T6 stub was never invoked"; fail=1; }

# 7. Stubbed panel exit 1 (all critics failed): fail-OPEN degrade, not an
# abort - findings discarded (stdout empty), a loud stderr message, exit 0.
set_policy 1
unset CR_PROFILE 2>/dev/null || true
export STUB_RC=1 STUB_OUT="should-be-discarded" STUB_ERR="panel-availability: fake unavailable (rc=1)"
rc=$(run_sut --head "$head_feat" --branch feat)
check "$rc" "0" "T7 rc (degrade, not abort)"
check "$(cat "$stdout_file")" "" "T7 stdout (findings discarded)"
contains "$(cat "$stderr_file")" "docs-audit cross-model critic unavailable (all critics failed) - record any panel-availability unavailable rows; under CR_REQUIRE_CROSS_MODEL the marker will stay closed until a non-Claude critic records avail ok" "T7 stderr all-critics-failed note"
contains "$(cat "$stderr_file")" "panel-availability: fake unavailable (rc=1)" "T7 stderr re-emits the panel's availability line"
[ -e "$STUB_MARKER" ] || { echo "FAIL: T7 stub was never invoked"; fail=1; }

# 7b. panel exit 6 is the deliberate certify refusal, not a failed
# panel: same fail-open degrade, but the message must say REFUSED.
set_policy 1
unset CR_PROFILE 2>/dev/null || true
export STUB_RC=6 STUB_OUT="should-be-discarded" STUB_ERR="panel-availability: fake unavailable (rc=6)"
rc=$(run_sut --head "$head_feat" --branch feat)
check "$rc" "0" "T7b rc (degrade, not abort)"
check "$(cat "$stdout_file")" "" "T7b stdout (findings discarded)"
contains "$(cat "$stderr_file")" "docs-audit critic panel REFUSED to certify this run (exit 6" "T7b stderr names the refusal"
case "$(cat "$stderr_file")" in *"all critics failed"*) echo "FAIL: T7b exit 6 must not read as all critics failed"; fail=1 ;; esac

# 7d. Only rc=1 earns the rtk retry, which is a second paid call: rc 2, 5 and 6
# are not the "no valid diff" failure it exists for. A control proves rc=1 does.
for retry_rc in 2 5 6 1; do
    rm -f "$RTK_MARKER"
    rm -f "$tmp/retry-stdin"
    ( cd "$repo" && RTK_MARKER="$RTK_MARKER" STUB_STDIN="$tmp/retry-stdin" STUB_RC="$retry_rc" PATH="$tmp/rtk-stub:$SAFE_PATH" bash "$SUT" --head "$head_feat" --branch feat ) \
        >"$stdout_file" 2>"$stderr_file"
    if [ "$retry_rc" -eq 1 ]; then
        [ -e "$RTK_MARKER" ] || { echo "FAIL: T7d control: rc=1 must retry through rtk"; fail=1; }
        # The retry runs exactly this command over exactly this range,
        # and the panel gets the bytes it returned: a wrong range would mint an ok
        # row on a diff nobody meant to review.
        check "$(cat "$RTK_MARKER" 2>/dev/null)" "proxy git diff $head_main...$head_feat" "T7d the rtk retry command and range"
        check "$(cat "$tmp/retry-stdin" 2>/dev/null)" "diff --git a/f.txt b/f.txt" "T7d the panel gets the rtk retry's diff"
    else
        [ ! -e "$RTK_MARKER" ] || { echo "FAIL: T7d rc=$retry_rc must not retry through rtk"; fail=1; }
    fi
done

# 7f. Panel exit 5 (the findings could not be recorded, so the
# panel left no ok row) is named as such, never "all critics failed", and holds.
set_policy 1
unset CR_PROFILE 2>/dev/null || true
export STUB_RC=5 STUB_OUT="should-be-discarded" STUB_ERR="critic-panel.sh: CR-ledger append failed; review output was emitted but this run is NOT certified"
rc=$(run_sut --head "$head_feat" --branch feat)
check "$rc" "0" "T7f rc (degrade, not abort)"
check "$(cat "$stdout_file")" "" "T7f stdout (findings discarded)"
contains "$(cat "$stderr_file")" "docs-audit critic panel could not record its result on the CR ledger (exit 5" "T7f names the record failure"
contains "$(cat "$stderr_file")" "docs-audit: no critic ok row from this run - ready-check item 4 and the merge gate hold this head" "T7f names the hold"
case "$(cat "$stderr_file")" in *"all critics failed"*) echo "FAIL: T7f exit 5 must not read as all critics failed"; fail=1 ;; esac

# 7e. A refusal the panel could not record holds nothing, so the lane aborts.
export STUB_RC=6 STUB_OUT="should-be-discarded" STUB_ERR="critic-panel.sh: could not record certify-refused on the ledger"
rc=$(run_sut --head "$head_feat" --branch feat)
check "$rc" "7" "T7e rc"
check "$(cat "$stdout_file")" "" "T7e stdout"
contains "$(cat "$stderr_file")" "the refusal could not be recorded on the CR ledger" "T7e names the cause"

# 7c. panel exit 2 from a mktemp failure names it, never "all critics
# failed"; a usage-error exit 2 does not claim mktemp.
set_policy 1
unset CR_PROFILE 2>/dev/null || true
export STUB_RC=2 STUB_OUT="should-be-discarded" STUB_ERR="critic-panel: mktemp failed"
rc=$(run_sut --head "$head_feat" --branch feat)
check "$rc" "0" "T7c rc (degrade, not abort)"
contains "$(cat "$stderr_file")" "docs-audit cross-model critic unavailable (exit 2: critic-panel: mktemp failed - check free space in TMPDIR)" "T7c stderr names the mktemp cause"
case "$(cat "$stderr_file")" in *"all critics failed"*) echo "FAIL: T7c exit 2 must not read as all critics failed"; fail=1 ;; esac
export STUB_RC=2 STUB_OUT="should-be-discarded" STUB_ERR="usage: critic-panel.sh [--worktree <path>]"
rc=$(run_sut --head "$head_feat" --branch feat)
contains "$(cat "$stderr_file")" "docs-audit cross-model critic unavailable (exit 2: usage error: usage: critic-panel.sh [--worktree <path>])" "T7c stderr names the usage cause"
case "$(cat "$stderr_file")" in *"mktemp"*) echo "FAIL: T7c usage-error exit 2 must not claim mktemp"; fail=1 ;; esac

# 8. Stubbed panel exit 0: findings land on stdout ONLY, panel-availability
# lands on stderr ONLY - the two streams never merge.
set_policy 1
unset CR_PROFILE 2>/dev/null || true
export STUB_RC=0 STUB_OUT="[docsaudit-1] some finding" STUB_ERR="panel-availability: fake ok"
rc=$(run_sut --head "$head_feat" --branch feat)
check "$rc" "0" "T8 rc"
check "$(cat "$stdout_file")" "[docsaudit-1] some finding" "T8 stdout carries the findings"
check "$(cat "$stderr_file")" "panel-availability: fake ok" "T8 stderr carries the availability line"
not_contains "$(cat "$stdout_file")" "panel-availability" "T8 stdout must not carry the availability line"
not_contains "$(cat "$stderr_file")" "docsaudit-1" "T8 stderr must not carry the findings"
[ -e "$STUB_MARKER" ] || { echo "FAIL: T8 stub was never invoked"; fail=1; }

# 9. a --head that names no commit in this repo ABORTs at exit 7
# naming the ARGUMENT, before any git command consumes it. Pre-fix, the bare
# `git rev-parse` accepted the well-formed 40-hex value, `git diff` then failed
# rc=128, and the lane reported "cross-model critic unavailable" at exit 0 -
# a caller error wearing a reviewer outage's clothes.
bogus_sha="0000000000000000000000000000000000000000"
set_policy 1
unset CR_PROFILE 2>/dev/null || true
export STUB_RC=0 STUB_OUT="MUST-NOT-REVIEW" STUB_ERR="panel-availability: fake ok"
rc=$(run_sut --head "$bogus_sha" --branch feat)
check "$rc" "7" "T9 rc (unresolvable --head aborts)"
check "$(cat "$stdout_file")" "" "T9 stdout empty"
contains "$(cat "$stderr_file")" "--head $bogus_sha does not resolve to a commit in this repo" "T9 ABORT names the argument"
not_contains "$(cat "$stderr_file")" "critic unavailable" "T9 must not report a critic outage for a caller error"
[ ! -e "$STUB_MARKER" ] || { echo "FAIL: T9 the panel was invoked on an unresolvable pin"; fail=1; }

# 10. NEGATIVE CONTROL for T9: a mutant with the
# T9 guard deleted must RUN, PRODUCE a value, and produce the SPECIFIC wrong
# value - exit 0 plus the misleading "cross-model critic unavailable" line.
# Each property gets its own failure message so a crashed mutant can never pass
# for a reproduced defect. The mutant lives inside the fixture root, because
# the SUT resolves critic-panel.sh from its own SCRIPT_DIR/../.. and a mutant
# written elsewhere could reach the REAL, paid panel.
mutant="$root/scripts/cr/docs-audit-panel.mutant.sh"
awk '
    index($0, "git rev-parse --verify --quiet") && index($0, "head^{commit}") { drop = 1 }
    drop && $0 == "fi" { drop = 0; next }
    !drop { print }
' "$SUT" > "$mutant"
if cmp -s "$SUT" "$mutant"; then
    echo "FAIL: T10 control is VACUOUS - the guard-deleting mutation matched nothing, so the mutant IS the fixed script"; fail=1
elif grep -q 'does not resolve to a commit in this repo' "$mutant"; then
    echo "FAIL: T10 control is VACUOUS - the mutant still carries the guard's ABORT message"; fail=1
else
    rm -f "$STUB_MARKER"
    mutant_rc=0
    ( cd "$repo" && PATH="$SAFE_PATH" bash "$mutant" --head "$bogus_sha" --branch feat ) \
        >"$stdout_file" 2>"$stderr_file" || mutant_rc=$?
    # (a) the SPECIFIC wrong value, not merely "different from 7".
    check "$mutant_rc" "0" "T10 control reproduces the exact defect (exit 0 on an unresolvable pin)"
    # (b) it RAN and produced a value: the outage line is emitted only after
    # the SUT got past arg handling and actually attempted the diff.
    contains "$(cat "$stderr_file")" "docs-audit cross-model critic unavailable - git diff failed rc=" "T10 control RAN and produced the misleading outage message"
fi

unset STUB_RC STUB_OUT STUB_ERR CR_REQUIRE_CROSS_MODEL CR_PROFILE 2>/dev/null || true

[ "$fail" -eq 0 ] && echo "PASS test-docs-audit-panel" || exit 1
