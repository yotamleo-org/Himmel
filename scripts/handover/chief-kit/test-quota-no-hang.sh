#!/usr/bin/env bash
# shellcheck disable=SC2016  # the single-quoted bodies are scripts written to files and run by bash -c, expanded there
# scripts/handover/chief-kit/test-quota-no-hang.sh - T1 of the shared PR watcher plan, the RED suite for the quota gate.
#
#   test-quota-no-hang.sh [--caller <name>] [--mode <stub mode>] [--keep] [--strict] [--full]
#     --caller  run one caller's rows (go.sh, ready-check.sh, cr-disposition.sh, tick.sh,
#               next-dispatchable.sh, check-ci.sh, chief-wait.sh, pr-sweep.sh; scans =
#               status-sweep.sh and focus-refresh.sh)
#     --mode    run one stub mode only (debugging a row); --keep leaves the scratch tree
#               (each row's out and stub.log) and prints its path
#     --strict  ignore the KNOWN-RED marks: every failing row fails the suite (T1 pastes this)
#     --full    hung rows at DEFAULT settings (the only proof of a hung bound; up to ~45 min,
#               run once per caller by hand at T12). Without it hung rows use the scaled seams
#               and prove the branch taken (exit and wording), not the bound.
#
# Row output: PASS | FAIL | SKIP absent | KNOWN-RED <task> <caller> <mode> <assertion>
# A KNOWN-RED row that fails is reported and does not fail the suite; one that PASSES does
# (UNEXPECTED-PASS), which forces the flip when its task lands.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
FIXDIR="$HERE/testdata/quota"

ONLY="" STRICT=0 FULL=0 MODE_ONLY="" KEEP=0
while [ "$#" -gt 0 ]; do
    case "$1" in
        --keep) KEEP=1; shift ;;
        --caller) ONLY="${2:-}"; shift 2 2>/dev/null || shift "$#" ;;
        --mode) MODE_ONLY="${2:-}"; shift 2 2>/dev/null || shift "$#" ;;
        --strict) STRICT=1; shift ;;
        --full) FULL=1; shift ;;
        *) echo "usage: test-quota-no-hang.sh [--caller <name>] [--strict] [--full]" >&2; exit 2 ;;
    esac
done
case "$ONLY" in *.sh) ONLY="${ONLY%.sh}" ;; esac

tmp="$(mktemp -d "${TMPDIR:-/tmp}/quota-no-hang.XXXXXX")" || { echo "FAIL: mktemp -d failed" >&2; exit 1; }
tmp="$(cd "$tmp" && pwd)"
cleanup() {
    local p
    for p in $(jobs -p 2>/dev/null); do kill "$p" 2>/dev/null; done
    pkill -f "$tmp" 2>/dev/null || true
    if [ "$KEEP" = 1 ]; then echo "kept: $tmp" >&2; else rm -rf "$tmp"; fi
}
trap cleanup EXIT

REAL_QUOTA="${HOME:-/nonexistent}/.himmel/state/quota"
RUN_ID="9$(date +%s)$$"
: > "$tmp/fixture-ids"
# quota_leaked <dir>: rc 0 when this run reached <dir> (the run id in a file, or a blocked marker
# named for one of this run's fixture heads), 1 when it did not, 2 when the scan failed.
quota_leaked() {
    local d="$1" id grc
    [ -d "$d" ] || return 1
    grep -rqF "$RUN_ID" "$d" 2>/dev/null; grc=$?
    [ "$grc" -eq 1 ] || return "$grc"
    while IFS= read -r id; do
        [ -z "$(find "$d/blocked" -maxdepth 1 -name "*.$id" 2>/dev/null)" ] || return 0
    done < "$tmp/fixture-ids"
    return 1
}
( while :; do if quota_leaked "$REAL_QUOTA"; then : > "$tmp/quota-leak"; fi; sleep 0.5; done ) &

STUBBIN="$tmp/stubbin"; mkdir -p "$STUBBIN"
cat > "$STUBBIN/gh" <<'STUB'
#!/usr/bin/env bash
mode="${STUB_MODE:-healthy}"
tok=main
[ -n "${STUB_READ_TOKEN:-}" ] && [ "${GH_TOKEN:-}" = "$STUB_READ_TOKEN" ] && tok=read
[ -z "${STUB_LOG:-}" ] || printf '%s %s %s\n' "$(date +%s)" "$tok" "$*" >> "$STUB_LOG"
bucket=core
case "${1:-}" in
    pr) [ "${2:-}" = diff ] || bucket=graphql ;;
    issue | repo) bucket=graphql ;;
    api) case "$*" in *graphql*) bucket=graphql ;; esac ;;
esac
probe=0
case "$*" in *rateLimit* | "api rate_limit"* | "api -i user"* | "api user"*) probe=1 ;; esac
fx() { grep -v '^# ' "$STUB_FIXDIR/$1"; }
now=$(date +%s)
refused=0
case "$mode" in
    gql-out | gql-200) [ "$bucket" = graphql ] && refused=1 ;;
    rest-out) [ "$bucket" = core ] && refused=1 ;;
    both-out | secondary | reset-past | reset-absent | reset-absurd) refused=1 ;;
    main-only) [ "$tok" = main ] && refused=1 ;;
    read-only) [ "$tok" = read ] && refused=1 ;;
    hung) exec sleep 600 ;;
    hung-after-probe) [ "$probe" = 1 ] || exec sleep 600 ;;
    main-hung) [ "$tok" = main ] && exec sleep 600 ;;
    gql-late)
        if [ "$bucket" = graphql ] && [ "$probe" = 0 ]; then
            echo x >> "${STUB_LOG:-/dev/null}.gql"
            [ "$(wc -l < "${STUB_LOG:-/dev/null}.gql" 2> /dev/null || echo 0)" -gt 1 ] && refused=1
        fi ;;
esac
case "$mode" in
    reset-past) reset=$((now - 3600)) ;;
    reset-absent) reset="" ;;
    reset-absurd) reset=4102444800 ;;
    *) reset=$((now + 1800)) ;;
esac
if [ "$probe" = 1 ]; then
    rem=4000
    [ "$refused" = 0 ] || rem=0
    [ "$refused" = 0 ] || [ "$mode" != secondary ] || rem=0
    case "$*" in
        *" -i "* | *"-i "*)
            printf 'HTTP/2.0 %s\r\nX-Ratelimit-Remaining: %s\r\n' "$([ "$rem" = 0 ] && echo '403 Forbidden' || echo '200 OK')" "$rem"
            [ -z "${STUB_RUN_ID:-}" ] || printf 'X-Ratelimit-Limit: %s\r\n' "$STUB_RUN_ID"
            [ -z "$reset" ] || printf 'X-Ratelimit-Reset: %s\r\n' "$reset"
            [ "$mode" != secondary ] || printf 'Retry-After: 60\r\n'
            printf '\r\n{"data":{"rateLimit":{"remaining":%s}}}\n' "$rem"
            [ "$rem" != 0 ] || exit 1
            exit 0 ;;
        *)
            json=$(printf '{"resources":{"core":{"limit":5000,"remaining":%s,"reset":%s},"graphql":{"limit":5000,"remaining":%s,"reset":%s}}}' "$rem" "${reset:-0}" "$rem" "${reset:-0}")
            jq_f=""
            prev=""
            for a in "$@"; do [ "$prev" = --jq ] && jq_f="$a"; prev="$a"; done
            if [ -n "$jq_f" ]; then printf '%s' "$json" | jq -r "$jq_f"; else printf '%s\n' "$json"; fi
            exit 0 ;;
    esac
fi
if [ "$refused" = 1 ]; then
    case "$mode" in
        secondary)
            case "$*" in *" -i "*) printf 'HTTP/2.0 403 Forbidden\r\nRetry-After: 60\r\n\r\n' ;; esac
            echo 'gh: You have exceeded a secondary rate limit. Please wait a few minutes before you try again. (HTTP 403)' >&2
            exit 1 ;;
        gql-200)
            printf '{"errors":[{"type":"RATE_LIMITED","message":"API rate limit already exceeded for user ID 88616986."}]}\n'
            fx 55498a23-F1.txt >&2
            exit 1 ;;
    esac
    if [ "$bucket" = graphql ]; then
        fx 55498a23-F1.txt >&2
    else
        fx 32a082f4-F2.txt
        fx c5d6911e-F3.txt >&2
    fi
    exit 1
fi
# healthy: the caller's next gh answers (the ready-pass gh, or the tick fixture's gh). That gh may
# fall through to "the next gh on PATH", which would be this stub again, so a re-entered stub
# goes straight to the terminal gh instead of looping.
self=$(cd "$(dirname "$0")" && pwd)
if [ "${STUB_PASS:-0}" = 1 ]; then
    [ -x "${STUB_FINAL_GH:-/nonexistent}" ] && exec "$STUB_FINAL_GH" "$@"
    exit 0
fi
export STUB_PASS=1
if [ -x "${STUB_NEXT_GH:-/nonexistent}" ]; then exec "$STUB_NEXT_GH" "$@"; fi
IFS=:
for d in $PATH; do
    [ "$d" = "$self" ] && continue
    [ -x "$d/gh" ] && exec "$d/gh" "$@"
done
exit 0
STUB
chmod +x "$STUBBIN/gh"

FINALBIN="$tmp/finalbin"; mkdir -p "$FINALBIN"
cat > "$FINALBIN/gh" <<'STUB'
#!/usr/bin/env bash
case "$*" in
    "repo view --json nameWithOwner"*) printf 'o/r\n' ;;
esac
exit 0
STUB
chmod +x "$FINALBIN/gh"

ENVROOT="$tmp/envroot"; mkdir -p "$ENVROOT"
printf 'himmel_github_token_vm2=readtok123\n' > "$ENVROOT/.env"

RES="$tmp/res"; mkdir -p "$RES"
emit() { printf '%s\n' "$*" >> "$RES/$CUR.txt"; }   # emit <status> <caller> <mode> <assertion> [detail]

known_task() {
    awk -v c="$1" -v m="$2" -v a="$3" '$2 == c && $3 == m && $4 == a { print $1; exit }' <<'KNOWN'
KNOWN
}

# 'head branch' from the spec list is not a phrase here: cr-disposition's HONEST rate-limit wording
# contains it ("rate limit hit reading PR #N's head branch"). The false form is "cannot read PR".
FALSE_PHRASES=("no valid disposition" "0 free" "POOL-EMPTY" "cannot read PR" "cannot resolve the PR" "cannot resolve owner/repo" "[FAIL]" "open PRs unknown" "READY-GO FAIL" "TRUST: refused" "must be OPEN" "ready-check=FAIL" "ci=PENDING" "disposition=open:?")
false_phrase_in() {
    local p
    for p in "${FALSE_PHRASES[@]}"; do
        case "$1" in *"$p"*) printf '%s' "$p"; return 0 ;; esac
    done
    return 1
}
names_limit() {
    # tick.sh prints a stall= field of its own on every line, so for it only a quota= field names the limit
    if [ "${3:-}" = tick.sh ]; then
        if [ "$1" = rate ]; then grep -qE ' quota=[^ ]+' <<< "$2"; else grep -qE ' quota=[^ ]*:stall' <<< "$2"; fi
    elif [ "$1" = rate ]; then
        grep -qiE 'QUOTA-PAUSE|rate[ -]limit|quota' <<< "$2"
    else
        grep -qiE 'GH-STALL|stall|timed out|time out' <<< "$2"
    fi
}

exec_row() {
    local bound="$1"
    shift
    local t0 t1
    t0=$(date +%s)
    timeout -k 3 "$((bound * 3))" "$@" > "$ROW_DIR/out" 2>&1 < /dev/null
    ROW_RC=$?
    t1=$(date +%s)
    ROW_SECS=$((t1 - t0))
    ROW_OUT="$(cat "$ROW_DIR/out" 2>/dev/null)"  # read-sink-ok: the row's own capture file
}

judge_row() {
    local caller="$1" mode="$2" bound="$3" want="$4" class="$5" fp
    local killed=0
    case "$ROW_RC" in 124 | 137) killed=1 ;; esac
    if [ "$killed" = 1 ]; then
        emit "FAIL $caller $mode bound UNBOUNDED killed after ${ROW_SECS}s (limit $((bound * 3))s)"
    elif [ "$ROW_SECS" -le "$bound" ]; then
        emit "PASS $caller $mode bound ${ROW_SECS}s<=${bound}s"
    else
        emit "FAIL $caller $mode bound ${ROW_SECS}s>${bound}s"
    fi
    case "$class" in
        none)  # the mode refuses nothing this caller reads: it proceeds, rc 0, and claims no limit
            emit "PASS $caller $mode names-limit n/a"
            if [ "$ROW_RC" = 0 ]; then emit "PASS $caller $mode exit rc=0"; else emit "FAIL $caller $mode exit rc=$ROW_RC want 0 (nothing it reads is refused)"; fi ;;
        maybe)  # whether this caller reads the refused account is not fixed by the spec: bound and phrases only
            emit "PASS $caller $mode names-limit n/a"
            emit "PASS $caller $mode exit rc=$ROW_RC n/a" ;;
        boundonly)  # the healthy stub cannot answer this caller's whole flow: the bound is the only claim
            emit "PASS $caller $mode names-limit n/a"
            emit "PASS $caller $mode exit rc=$ROW_RC n/a"
            emit "PASS $caller $mode no-false-phrase n/a"
            return 0 ;;
        *)
            if names_limit "$class" "$ROW_OUT" "$caller"; then
                emit "PASS $caller $mode names-limit"
            else
                emit "FAIL $caller $mode names-limit output does not name the limit"
            fi
            if [ "$ROW_RC" = "$want" ]; then
                emit "PASS $caller $mode exit rc=$ROW_RC"
            else
                emit "FAIL $caller $mode exit rc=$ROW_RC want $want"
            fi ;;
    esac
    if fp=$(false_phrase_in "$ROW_OUT"); then
        emit "FAIL $caller $mode no-false-phrase said '$fp'"
    else
        emit "PASS $caller $mode no-false-phrase"
    fi
}

base_env() {
    local cdir="$1" mode="$2" scaled="$3"
    printf '%s\n' \
        "HOME=$cdir/home" "GH_TOKEN=maintok" "STUB_READ_TOKEN=readtok123" "STUB_FIXDIR=$FIXDIR" \
        "STUB_MODE=$mode" "STUB_LOG=$ROW_DIR/stub.log" "HIMMEL_QUOTA_DIR=$cdir/quota" "STUB_RUN_ID=$RUN_ID" \
        "GH_PR_SNAPSHOT_CACHE_DIR=$cdir/snap" "GH_READ_ENV_ROOT=$ENVROOT" "TMPDIR=$cdir/tmp" \
        "PATH=$STUBBIN:${READY_BIN:-$cdir/none}:$FINALBIN:$PATH" "GH_BUDGET_JITTER_MAX=0" \
        "STUB_FINAL_GH=$FINALBIN/gh" "STUB_NEXT_GH=${READY_BIN:+$READY_BIN/gh}"
    if [ "$scaled" = 1 ]; then
        printf '%s\n' "GH_READ_TIMEOUT=2" "GHQ_PROBE_TIMEOUT=1" "READY_CHECK_DEADLINE=6" "GO_DEADLINE=12" \
            "TICK_DEADLINE_SEC=6" "CHIEF_WAIT_TICK_TIMEOUT=20" "NEXT_DISPATCH_DEADLINE=10" \
            "CR_DISPOSITION_GH_TIMEOUT=3" "CHIEF_WAIT_READY_CI_TIMEOUT=5" "CHIEF_WAIT_DISPOSITION_TIMEOUT=8" \
            "NEXT_DISPATCH_GH_TIMEOUT=3" "CHIEF_WAIT_DISPATCH_TIMEOUT=8"
    fi
}

RATE_MODES="gql-out rest-out both-out gql-200 main-only read-only reset-past reset-absent reset-absurd secondary"
HUNG_MODES="hung hung-after-probe"
XM=""

mode_class() { case "$1" in hung | hung-after-probe | main-hung) echo stall ;; *) echo rate ;; esac; }

run_mode() {
    local caller="$1" mode="$2" bound="$3" want="$4"
    shift 4
    local scaled=1 class
    class=$(mode_class "$mode")
    [ "$class" = rate ] && bound="${RATE_BOUND:-$bound}"
    [ "$class" = rate ] && scaled=0
    [ "$class" = stall ] && [ "$FULL" = 1 ] && scaled=0 && bound=$(full_bound "$caller" "$mode")
    ROW_DIR="$cdir/rows/$mode"; mkdir -p "$ROW_DIR"
    local envs=()
    local l
    while IFS= read -r l; do envs+=("$l"); done < <(base_env "$cdir" "$mode" "$scaled"; [ -z "${EXTRA_ENV:-}" ] || printf '%s\n' "$EXTRA_ENV")
    # The loader skips a key that is already set, so an ambient himmel_github_token_vm2 would beat the
    # fixture token and put a REAL credential in reach of a row. Unset every ambient token first.
    exec_row "$bound" env -u HIMMEL_CONSOLE_LEG -u HIMMEL_CONSOLE_RELAY -u CHIEF_SESSION_NAME \
        -u himmel_github_token_vm2 -u GITHUB_TOKEN -u GH_ENTERPRISE_TOKEN -u GITHUB_ENTERPRISE_TOKEN "${envs[@]}" "$@"
    if [ "$class" = rate ] && [ -n "${AFFECT_FN:-}" ]; then
        case "$("$AFFECT_FN" "$mode")" in no) class=none ;; maybe) class=maybe ;; boundonly) class=boundonly ;; esac
    fi
    judge_row "$caller" "$mode" "$bound" "$want" "$class"
}

setup_caller_dir() {
    cdir="$tmp/$1"
    mkdir -p "$cdir/home" "$cdir/quota" "$cdir/snap" "$cdir/tmp" "$cdir/rows"
}

gate_fixture() {
    # shellcheck source=scripts/handover/chief-kit/testlib-ready-pass.sh
    # shellcheck disable=SC1091
    . "$HERE/testlib-ready-pass.sh"
    READY_BIN="$cdir/ready-bin"
    ready_pass_bin "$READY_BIN"
    GATE_REPO="$cdir/repo"
    git init -q "$GATE_REPO" || return 1
    SHA=$(ready_pass_repo "$GATE_REPO") || return 1
    ready_pass_ledger "$GATE_REPO" "$SHA" || return 1
    printf '%s\n' "$SHA" >> "$tmp/fixture-ids"
    export READY_STUB_HEAD="$SHA"
}

modes_for() { if [ -n "$MODE_ONLY" ]; then printf '%s\n' "$MODE_ONLY"; else printf '%s %s %s\n' "$RATE_MODES" "$HUNG_MODES" "$XM"; fi; }

affect_cr_disposition() { case "$1" in rest-out | read-only) echo no ;; *) echo yes ;; esac; }
affect_ready_check() { case "$1" in read-only) echo no ;; main-only) echo maybe ;; *) echo yes ;; esac; }
affect_go() { case "$1" in read-only) echo no ;; *) echo yes ;; esac; }

drive_cr_disposition() {
    CUR=cr-disposition.sh
    local script="$HERE/cr-disposition.sh" m
    [ -f "$script" ] || { emit "SKIP absent cr-disposition.sh"; return 0; }
    setup_caller_dir cr-disposition
    gate_fixture || { emit "FAIL cr-disposition.sh setup gate_fixture"; return 0; }
    cd "$GATE_REPO" || return 0
    AFFECT_FN=affect_cr_disposition RATE_BOUND=5
    for m in $(modes_for); do
        run_mode cr-disposition.sh "$m" 6 2 bash "$script" check 77 "$SHA"
    done
}

drive_ready_check() {
    CUR=ready-check.sh
    local script="$HERE/ready-check.sh" m
    [ -f "$script" ] || { emit "SKIP absent ready-check.sh"; return 0; }
    setup_caller_dir ready-check
    gate_fixture || { emit "FAIL ready-check.sh setup gate_fixture"; return 0; }
    cd "$GATE_REPO" || return 0
    AFFECT_FN=affect_ready_check RATE_BOUND=15 XM="gql-late"
    for m in $(modes_for); do
        run_mode ready-check.sh "$m" 8 2 bash "$script" 77 "$SHA"
    done
}

drive_go() {
    CUR=go.sh
    local script="$HERE/go.sh" m
    [ -f "$script" ] || { emit "SKIP absent go.sh"; return 0; }
    setup_caller_dir go
    gate_fixture || { emit "FAIL go.sh setup gate_fixture"; return 0; }
    mkdir -p "$cdir/root"
    cd "$GATE_REPO" || return 0
    AFFECT_FN=affect_go RATE_BOUND=20 XM="gql-late main-hung"
    for m in $(modes_for); do
        rm -rf "$cdir/root/.locks"
        EXTRA_ENV="HANDOVER_DIR=$cdir/root"
        run_mode go.sh "$m" 14 11 bash "$script" 77 "$SHA"
        if [ "$(affect_go "$m")" = no ] && [ "$(mode_class "$m")" = rate ]; then
            emit "PASS go.sh $m no-go-written n/a"
        elif [ -e "$cdir/root/.locks/go/77.$SHA" ]; then
            emit "FAIL go.sh $m no-go-written a GO file exists after a refused read"
        else
            emit "PASS go.sh $m no-go-written"
        fi
    done
    EXTRA_ENV=""
}

affect_nd() { case "$1" in read-only) echo no ;; *) echo yes ;; esac; }

nd_fixture() {
    local M
    M="$cdir/jira-mirror/HIMMEL"; mkdir -p "$M" "$cdir/notcore"
    printf -- '---\nkey: "HIMMEL-1"\ntype: "Task"\nstatus: "To Do"\nstatusCategory: "x"\npriority: "High"\nlabels: []\nfixVersions: ["v1.0.1"]\nparent: null\nlinks:\n  blocks: []\n  blocked_by: []\n  relates: []\n---\n\n# HIMMEL-1: a free ticket\n\n## Description\n\nEdit scripts/lib/alpha.sh only.\n\nDoD\n- the row is green\n\nProof\n- a RED row that fails before the change\n' > "$M/HIMMEL-1.md"
    printf 'v1.0.1\tfalse\t\n' > "$cdir/jira-mirror/HIMMEL.versions.tsv"
    cat > "$cdir/notcore/index.js" <<'NCEOF'
const a = process.argv.slice(2);
if (a[0] === 'release' && a[1] === 'core-check') for (const k of a.slice(a.indexOf('--key') + 1)) console.log('NOT-CORE ' + k);
else { console.error('stub jira: unknown command ' + a.join(' ')); process.exit(2); }
NCEOF
    printf '#!/usr/bin/env bash\nfor k in "$@"; do printf "%%s\\tLOCAL-NATIVE\\tstub\\n" "$k"; done\n' > "$cdir/classify"
    chmod +x "$cdir/classify"
    mkdir -p "$cdir/git-none"
    git -C "$cdir/git-none" init -q -b main && git -C "$cdir/git-none" -c user.name=t -c user.email=t@example.com -c commit.gpgsign=false -c core.hooksPath=/dev/null commit -q --allow-empty -m init \
        || return 1
    ND_ENV="$(printf '%s\n' "NEXT_DISPATCH_MIRROR=$M" "NEXT_DISPATCH_CLASSIFY_CMD=$cdir/classify" "NEXT_DISPATCH_JIRA_CLI=$cdir/notcore/index.js" \
        "NEXT_DISPATCH_GIT_DIR=$cdir/git-none" "NEXT_DISPATCH_MAIN_REF=main" "NEXT_DISPATCH_BODY_CACHE=off" \
        "TICKET_STATUS_STATE_DIR=$cdir/ts-none" "HIMMEL_ADMISSIONS_LEDGER=$cdir/ledger-none.jsonl" "HANDOVER_DIR=$cdir/h")"
    mkdir -p "$cdir/h"
}

drive_next_dispatchable() {
    CUR=next-dispatchable.sh
    local script="$HERE/next-dispatchable.sh" m
    [ -f "$script" ] || { emit "SKIP absent next-dispatchable.sh"; return 0; }
    setup_caller_dir nd
    nd_fixture || { emit "FAIL next-dispatchable.sh setup git fixture"; return 0; }
    AFFECT_FN=affect_nd RATE_BOUND=25 XM="gql-late"
    EXTRA_ENV="$ND_ENV"
    for m in $(modes_for); do
        rm -f "$cdir/quota/quota.tsv"
        run_mode next-dispatchable.sh "$m" 12 0 bash "$script" --top 5
    done
    EXTRA_ENV=""
}

affect_tick() { case "$1" in read-only) echo maybe ;; main-only) echo maybe ;; *) echo yes ;; esac; }

drive_tick() {
    CUR=tick.sh
    local script="$HERE/tick.sh" m
    [ -f "$script" ] || { emit "SKIP absent tick.sh"; return 0; }
    [ -r "$HERE/tick-test-fixture.sh" ] || { emit "FAIL tick.sh setup tick-test-fixture.sh unreadable"; return 0; }
    setup_caller_dir tick
    AFFECT_FN=affect_tick RATE_BOUND=60
    for m in $(modes_for); do
        run_mode tick.sh "$m" 10 0 bash -c '. "$1"; export PATH="$2:$PATH" STUB_NEXT_GH="$W/bin/gh"; exec bash "$SUT"' \
            "$HERE/test-quota-no-hang.sh" "$HERE/tick-test-fixture.sh" "$STUBBIN"
    done
}

affect_check_ci() { case "$1" in read-only | main-only) echo boundonly ;; *) echo yes ;; esac; }

drive_check_ci() {
    CUR=check-ci.sh
    local script="$ROOT/scripts/check-ci.sh" m
    [ -f "$script" ] || { emit "SKIP absent check-ci.sh"; return 0; }
    setup_caller_dir check-ci
    gate_fixture || { emit "FAIL check-ci.sh setup gate_fixture"; return 0; }
    cd "$GATE_REPO" || return 0
    mkdir -p "$cdir/checkci-bin"
    cat > "$cdir/checkci-bin/gh" <<'STUB'
#!/usr/bin/env bash
case "$*" in
    "pr view 77 --json url,reviewDecision,headRefOid,baseRefName"*)
        printf 'https://github.com/o/r/pull/77\tnull\t%s\tmain\n' "$READY_STUB_HEAD"
        exit 0 ;;
esac
exec "$CHECKCI_NEXT_GH" "$@"
STUB
    chmod +x "$cdir/checkci-bin/gh"
    EXTRA_ENV="CHECKCI_NEXT_GH=$READY_BIN/gh"
    READY_BIN="$cdir/checkci-bin"
    AFFECT_FN=affect_check_ci RATE_BOUND=20
    for m in $(modes_for); do
        run_mode check-ci.sh "$m" 12 2 bash "$script" 77 --max-wait 5 --settle 0 --grace 1
    done
    EXTRA_ENV=""
}

affect_cw() { case "$1" in read-only) echo no ;; *) echo yes ;; esac; }

drive_chief_wait() {
    CUR=chief-wait.sh
    local script="$HERE/chief-wait.sh" m bound rb scaled class envs l pid hb samp tsent t0 t1 killed
    [ -f "$script" ] || { emit "SKIP absent chief-wait.sh"; return 0; }
    [ -r "$HERE/tick-test-fixture.sh" ] || { emit "FAIL chief-wait.sh setup tick-test-fixture.sh unreadable"; return 0; }
    setup_caller_dir cw
    gate_fixture || { emit "FAIL chief-wait.sh setup gate_fixture"; return 0; }
    nd_fixture || { emit "FAIL chief-wait.sh setup nd fixture"; return 0; }
    # An empty mirror: a pool with a row raises its own pool-unresolved wake (a different event) and would
    # end the run before the gate paths this suite measures. A healthy empty pool says POOL-EMPTY
    # legitimately, so that phrase is only false while a gate is refused (affect_cw read-only = healthy).
    rm -f "$cdir/jira-mirror/HIMMEL/HIMMEL-1.md"
    local inbox="$cdir/h/consoles/c.md" doc="$cdir/h/HIMMEL-9-N1.md" legs="$cdir/legs.json"
    mkdir -p "$cdir/h/consoles" "$cdir/denial-acks"
    printf '# worker\n\n## Results\n- 11:00 READY 77 %s GREEN\n' "$SHA" > "$doc"
    printf '{"schema":1,"workers":[{"label":"N1","doc":"%s"}]}\n' "$doc" > "$legs"
    printf '#!/usr/bin/env bash\nexec bash -c '"'"'. "$1"; export PATH="$2:$PATH" STUB_NEXT_GH="$W/bin/gh"; shift 2; exec bash "$SUT" "$@"'"'"' "%s" "%s" "%s" "$@"\n' \
        "$HERE/test-quota-no-hang.sh" "$HERE/tick-test-fixture.sh" "$STUBBIN" > "$cdir/tick-real.sh"
    printf '#!/usr/bin/env bash\necho PROCEED\n' > "$cdir/bank.sh"
    printf '#!/usr/bin/env bash\nexit 0\n' > "$cdir/off.sh"
    printf '#!/usr/bin/env bash\nexit 2\n' > "$cdir/budget-off.sh"
    chmod +x "$cdir/tick-real.sh" "$cdir/bank.sh" "$cdir/off.sh" "$cdir/budget-off.sh"
    cd "$GATE_REPO" || return 0
    for m in $(modes_for); do
        class=$(mode_class "$m")
        scaled=1; bound=30; rb=110
        [ "$class" = rate ] && scaled=0 && bound=$rb
        [ "$class" = stall ] && [ "$FULL" = 1 ] && scaled=0 && bound=$(full_bound chief-wait.sh "$m")
        ROW_DIR="$cdir/rows/$m"; mkdir -p "$ROW_DIR"
        rm -f "$inbox".wait* "$cdir/h/consoles/c.md.wait"* "$inbox.cursor"; : > "$inbox"; : > "$inbox.announced"
        rm -rf "$cdir/quota/blocked" "$cdir/quota/quota.tsv"
        printf 'N9\n' > "$inbox.wait.unwatched"
        envs=()
        while IFS= read -r l; do envs+=("$l"); done < <(base_env "$cdir" "$m" "$scaled"; printf '%s\n' "$ND_ENV" \
            "CHIEF_WAIT_TICK=$cdir/tick-real.sh" "CHIEF_WAIT_USAGE=$cdir/bank.sh" "CHIEF_WAIT_INTERVAL=1" "CHIEF_WAIT_POLL_SEC=0.2" \
            "CHIEF_WAIT_FAIL_WAKE=1000" "CHIEF_WAIT_PAGE_CMD=$cdir/off.sh" "CHIEF_WAIT_BUDGET=$cdir/budget-off.sh" \
            "CHIEF_WAIT_ORPHAN=$cdir/off.sh" "WAIT_SWEEP_CMD=$cdir/off.sh" "WAIT_FOCUS_CMD=$cdir/off.sh" \
            "HIMMEL_DENIAL_ACK_DIR=$cdir/denial-acks" "HIMMEL_FLAG_AUTO_GO=off" \
            "STUB_FLEET_LINE=bank-preflight: FLEET native=8 claudex=0 openrouter=0 reserved=0 total=8/8")
        t0=$(date +%s)
        env -u HIMMEL_CONSOLE_LEG -u HIMMEL_CONSOLE_RELAY -u CHIEF_SESSION_NAME -u himmel_github_token_vm2 -u GITHUB_TOKEN \
            "${envs[@]}" timeout -k 3 "$((bound * 3))" bash "$script" "$inbox" --workers-from "$legs" \
            > "$ROW_DIR/out" 2>&1 < /dev/null &
        pid=$!
        samp="" tsent="" prev=waiting sdone="" stopped=0
        while kill -0 "$pid" 2> /dev/null; do
            hb=$(cat "$inbox.wait" 2> /dev/null)
            case "$hb" in
                *state=sampling*)
                    if [ "$prev" != sampling ] && [ -z "$samp" ]; then
                        samp=$(date +%s)
                        printf 'status please\n' >> "$inbox"; tsent=$(date +%s)
                    fi
                    prev=sampling ;;
                *state=waiting*)
                    [ "$prev" != sampling ] || [ -n "$sdone" ] || sdone=$(date +%s)
                    prev=waiting ;;
            esac
            if [ -n "$tsent" ] && [ -n "$sdone" ] && [ $(($(date +%s) - tsent)) -gt $((bound + 5)) ]; then
                stopped=1; kill "$pid" 2> /dev/null; break
            fi
            sleep 0.5
        done
        wait "$pid" 2> /dev/null; ROW_RC=$?
        pkill -f "$inbox" 2> /dev/null || true
        [ "$stopped" = 0 ] || ROW_RC=0
        t1=$(date +%s)
        [ -n "$sdone" ] || sdone=$t1
        ROW_OUT="$(cat "$ROW_DIR/out" 2> /dev/null)"  # read-sink-ok: the row's own capture file
        killed=0; case "$ROW_RC" in 124 | 137) killed=1 ;; esac
        if [ "$killed" = 1 ]; then
            emit "FAIL chief-wait.sh $m bound UNBOUNDED killed after $((t1 - t0))s (limit $((bound * 3))s)"
        elif [ -z "$samp" ]; then
            emit "FAIL chief-wait.sh $m bound the waiter never reached state=sampling"
        elif [ $((sdone - samp)) -le "$bound" ]; then
            emit "PASS chief-wait.sh $m bound sample $((sdone - samp))s<=${bound}s"
        else
            emit "FAIL chief-wait.sh $m bound sample $((sdone - samp))s>${bound}s"
        fi
        emit "PASS chief-wait.sh $m names-limit n/a (a gate that is out prints no waiter line; the tick's quota= names it)"
        if [ "$(affect_cw "$m")" = no ] && [ "$class" = rate ]; then
            emit "PASS chief-wait.sh $m exit n/a"
            emit "PASS chief-wait.sh $m telegram-latency n/a"
            emit "PASS chief-wait.sh $m no-false-wake n/a"
            emit "PASS chief-wait.sh $m ready-unspent n/a"
        else
            if [ "$killed" = 0 ] && [ -n "$tsent" ] && grep -q '^WAKE telegram' <<< "$ROW_OUT" && [ $((t1 - tsent)) -le $((bound + 5)) ]; then
                emit "PASS chief-wait.sh $m telegram-latency $((t1 - tsent))s"
            else
                emit "FAIL chief-wait.sh $m telegram-latency no WAKE telegram within $((bound + 5))s of the line (waited $((t1 - ${tsent:-$t0}))s; the run ended on: $(printf '%s' "$ROW_OUT" | grep -m1 '^WAKE' | cut -c1-90))"
            fi
            if grep -q '^WAKE ready' <<< "$ROW_OUT"; then
                emit "FAIL chief-wait.sh $m no-false-wake a refused gate woke the chief with a READY verdict"
            else
                emit "PASS chief-wait.sh $m no-false-wake"
            fi
            if grep -qxF "77 $SHA" "$inbox.wait.readywoke" 2> /dev/null; then
                emit "FAIL chief-wait.sh $m ready-unspent the READY row is spent in readywoke"
            else
                emit "PASS chief-wait.sh $m ready-unspent"
            fi
            if [ "$killed" = 1 ]; then emit "FAIL chief-wait.sh $m exit rc=$ROW_RC"; else emit "PASS chief-wait.sh $m exit rc=$ROW_RC"; fi
        fi
        if [ "$(affect_cw "$m")" = no ] && [ "$class" = rate ]; then
            emit "PASS chief-wait.sh $m no-false-phrase n/a (nothing is refused: an empty pool is a real one)"
        elif fp=$(false_phrase_in "$ROW_OUT"); then
            emit "FAIL chief-wait.sh $m no-false-phrase said '$fp'"
        else
            emit "PASS chief-wait.sh $m no-false-phrase"
        fi
    done
}

affect_scans() { case "$1" in read-only) echo no ;; *) echo yes ;; esac; }
affect_focus() { case "$1" in read-only) echo maybe ;; *) echo yes ;; esac; }

no_list_row() {
    if [ "$(mode_class "$2")" = rate ] && [ "$("$AFFECT_FN" "$2")" != yes ]; then
        emit "PASS $1 $2 no-list-call n/a"
    elif [ ! -r "$ROW_DIR/stub.log" ]; then
        emit "FAIL $1 $2 no-list-call the stub log is missing"
    elif grep -q ' pr list' "$ROW_DIR/stub.log"; then
        emit "FAIL $1 $2 no-list-call the stub logged a PR list"
    else
        emit "PASS $1 $2 no-list-call"
    fi
}

drive_scans() {
    CUR=scans
    local m sweep="$HERE/status-sweep.sh" focus="$HERE/focus-refresh.sh" doc
    [ -f "$sweep" ] && [ -f "$focus" ] || { emit "SKIP absent status-sweep.sh or focus-refresh.sh"; return 0; }
    XM=""
    setup_caller_dir scans-sweep
    printf '#!/usr/bin/env bash\nexit 0\n' > "$cdir/jira"; chmod +x "$cdir/jira"
    AFFECT_FN=affect_scans RATE_BOUND=12
    for m in $(modes_for); do
        [ "$m" != hung-after-probe ] || continue
        rm -rf "$cdir/quota/quota.tsv" "$cdir/ts"
        EXTRA_ENV="$(printf '%s\n' "TICKET_STATUS_STATE_DIR=$cdir/ts" "WORKER_SESSION_JIRA_CLI=$cdir/jira")"
        run_mode status-sweep.sh "$m" 12 0 bash "$sweep" --repo o/r
        no_list_row status-sweep.sh "$m"
    done
    setup_caller_dir scans-focus
    printf '#!/usr/bin/env bash\nexit 0\n' > "$cdir/jira"; chmod +x "$cdir/jira"
    mkdir -p "$cdir/doc" "$cdir/mirror"
    doc="$cdir/doc/HIMMEL-nextleg-2026-11-11A-chief.md"
    printf '# chief\nfocus-version: v1.0.1\n' > "$doc"
    AFFECT_FN=affect_focus RATE_BOUND=12
    for m in $(modes_for); do
        [ "$m" != hung-after-probe ] || continue
        rm -rf "$cdir/quota/quota.tsv" "$cdir/ts" "$cdir/doc/focus-state"
        EXTRA_ENV="$(printf '%s\n' "TICKET_STATUS_STATE_DIR=$cdir/ts" "WORKER_SESSION_JIRA_CLI=$cdir/jira" "FR_JIRA=$cdir/jira" \
            "TICK_TRACKER_MIRROR_DIR=$cdir/mirror/HIMMEL" "HANDOVER_DIR=$cdir/h")"
        run_mode focus-refresh.sh "$m" 12 1 bash "$focus" --doc "$doc" --repo o/r
        no_list_row focus-refresh.sh "$m"
    done
    EXTRA_ENV=""
}

drive_pr_sweep() {
    CUR=pr-sweep.sh
    [ -f "$HERE/pr-sweep.sh" ] || { emit "SKIP absent pr-sweep.sh"; return 0; }
    emit "SKIP absent pr-sweep.sh (rows land with T9)"
}

CALLERS="cr-disposition ready-check go tick next-dispatchable check-ci chief-wait scans pr-sweep"
driver_of() {
    case "$1" in
        scans) echo drive_scans ;;
        cr-disposition) echo drive_cr_disposition ;;
        ready-check) echo drive_ready_check ;;
        go) echo drive_go ;;
        tick) echo drive_tick ;;
        next-dispatchable) echo drive_next_dispatchable ;;
        check-ci) echo drive_check_ci ;;
        chief-wait) echo drive_chief_wait ;;
        pr-sweep) echo drive_pr_sweep ;;
    esac
}
out_name_of() { case "$1" in pr-sweep) echo pr-sweep.sh ;; scans) echo scans ;; *) echo "$1.sh" ;; esac; }

suite_rows() {
    CUR=suite
    local f body
    for f in 55498a23-F1.txt 32a082f4-F2.txt c5d6911e-F3.txt; do
        if [ ! -s "$FIXDIR/$f" ]; then
            emit "FAIL suite fixture $f absent"
        elif ! grep -q 'API rate limit' <<< "$(grep -v '^# ' "$FIXDIR/$f")"; then
            emit "FAIL suite fixture $f lacks 'API rate limit'"
        else
            emit "PASS suite fixture $f"
        fi
    done
    for body in \
        "go: refusing the GO for PR #7 at abc - a Critical or Important finding has no valid disposition (above)." \
        "cr-disposition: cannot read PR #7's head branch" \
        "ready-check: [FAIL] 1 head sha unreadable" \
        "next-dispatchable: open PRs unknown (gh failed)" \
        "WAKE ready 77 abc ready-check=FAIL ci=PENDING coverage=FAIL disposition=open:? out=/x" \
        "# 0 free tickets POOL-EMPTY"; do
        if false_phrase_in "$body" > /dev/null; then
            emit "PASS suite false-phrase-red-control flags: ${body%% *}..."
        else
            emit "FAIL suite false-phrase-red-control missed today's wording: $body"
        fi
    done
    if false_phrase_in "QUOTA-PAUSE github graphql token=main remaining=0 floor=500 caller=go nothing-was-judged" > /dev/null; then
        emit "FAIL suite false-phrase-clean-control flagged the honest line"
    else
        emit "PASS suite false-phrase-clean-control"
    fi
    if names_limit rate "gh: API rate limit exceeded" && ! names_limit rate "gh: not found"; then
        emit "PASS suite names-limit-control"
    else
        emit "FAIL suite names-limit-control"
    fi
}

want_caller() { [ -z "$ONLY" ] || [ "$ONLY" = "$1" ] || [ "$ONLY" = "$(out_name_of "$1")" ]; }
if [ -n "$ONLY" ]; then
    known_caller=0
    for c in $CALLERS; do want_caller "$c" && known_caller=1; done
    [ "$known_caller" = 1 ] || { echo "test-quota-no-hang: unknown --caller '$ONLY' (one of: $CALLERS)" >&2; exit 2; }
fi
if [ -n "$MODE_ONLY" ]; then
    known_mode=0
    for m in $RATE_MODES $HUNG_MODES gql-late main-hung; do [ "$m" = "$MODE_ONLY" ] && known_mode=1; done
    [ "$known_mode" = 1 ] || { echo "test-quota-no-hang: unknown --mode '$MODE_ONLY' (one of: $RATE_MODES $HUNG_MODES gql-late main-hung)" >&2; exit 2; }
fi

full_bound() {
    case "$1:$2" in
        tick.sh:*) echo 100 ;;
        chief-wait.sh:hung) echo 140 ;;
        chief-wait.sh:*) echo 1240 ;;
        next-dispatchable.sh:hung) echo 25 ;;
        next-dispatchable.sh:*) echo 405 ;;
        check-ci.sh:hung) echo 130 ;;
        check-ci.sh:*) echo 255 ;;
        ready-check.sh:hung) echo 125 ;;
        ready-check.sh:*) echo 155 ;;
        go.sh:hung) echo 130 ;;
        go.sh:*) echo 275 ;;
        cr-disposition.sh:*) echo 65 ;;
        *) echo 300 ;;
    esac
}

suite_rows
pids=""
for c in $CALLERS; do
    want_caller "$c" || continue
    d=$(driver_of "$c")
    if ! declare -F "$d" > /dev/null 2>&1; then
        CUR=$(out_name_of "$c"); emit "SKIP absent driver $d (not wired yet)"
        continue
    fi
    (
        cd "$tmp" || exit 1
        "$d"
    ) &
    pids="$pids $!:$c"
done
for pc in $pids; do
    wait "${pc%%:*}" 2> /dev/null
    drc=$?
    CUR=$(out_name_of "${pc#*:}")
    if [ "$drc" != 0 ]; then
        emit "FAIL $CUR driver exited rc=$drc"
    elif [ ! -s "$RES/$CUR.txt" ]; then
        emit "FAIL $CUR driver wrote no rows"
    fi
done

CUR=suite
guard_dir() { # guard_dir <name> <stamp age secs>: a scratch dir holding a quota.tsv of that age
    gd="$tmp/guard-control/$1"; mkdir -p "$gd"
    printf 'main\tgraphql\t4309\t5000\t%s\t%s\tok\n' "$(( $(date +%s) + 1800 ))" "$(( $(date +%s) - $2 ))" > "$gd/quota.tsv"
}
guard_lib() { # guard_lib <dir> <function> <args...>: the library routed at <dir>, answered by the stub gh
    local q="$1"; shift
    ( export HIMMEL_QUOTA_DIR="$q" HOME="$tmp/guard-control/home" PATH="$STUBBIN:$PATH" STUB_MODE=healthy \
        STUB_RUN_ID="$RUN_ID" STUB_FIXDIR="$FIXDIR" GH_TOKEN=maintok GH_READ_ENV_ROOT="$ENVROOT"
      . "$ROOT/scripts/lib/gh-quota.sh"; "$@" ) > /dev/null 2>&1
}
guard_expect() { # guard_expect <name> <want rc> <dir>
    quota_leaked "$3"
    if [ "$?" -eq "$2" ]; then emit "PASS suite guard-control-$1"; else emit "FAIL suite guard-control-$1 the guard did not return $2"; fi
}
mkdir -p "$tmp/guard-control/home"
guard_fid="${RUN_ID}c0ffee"; printf '%s\n' "$guard_fid" >> "$tmp/fixture-ids"
guard_dir marker-fresh 0;  guard_lib "$gd" ghq_mark_blocked 77 "$guard_fid" check-ci.sh graphql rate-limit
guard_expect marker-into-fresh-dir 0 "$gd"
guard_dir refresh-stale 1000; guard_lib "$gd" ghq_refresh
guard_expect refresh-into-stale-dir 0 "$gd"
guard_dir clean-fresh 0
guard_expect clean-dir-passes 1 "$gd"
guard_dir foreign-fresh 0; guard_lib "$gd" ghq_mark_blocked 4242 deadbeefdeadbeef go.sh graphql rate-limit
if [ -n "$(find "$gd/blocked" -maxdepth 1 -type f -name '4242.*' 2>/dev/null)" ]; then emit "PASS suite guard-control-foreign-marker-written"; else emit "FAIL suite guard-control-foreign-marker-written no foreign marker was created, so the negative control proves nothing"; fi
guard_expect foreign-marker-passes 1 "$gd"
quota_leaked "$REAL_QUOTA"; guard_rc=$?
[ "$guard_rc" -ne 2 ] || { sleep 1; quota_leaked "$REAL_QUOTA"; guard_rc=$?; }
if [ -e "$tmp/quota-leak" ] || [ "$guard_rc" -ne 1 ]; then emit "FAIL suite live-quota-path-untouched a stub answer (run $RUN_ID) reached $REAL_QUOTA, or it could not be scanned (rc $guard_rc)"; else emit "PASS suite live-quota-path-untouched"; fi

fails=0 known=0 passes=0 skips=0 unexpected=0
report_file() {
    local line status caller mode assertion rest task
    while IFS= read -r line; do
        status="${line%% *}"; rest="${line#* }"
        case "$status" in
            SKIP) printf 'SKIP %s\n' "$rest"; skips=$((skips + 1)); continue ;;
        esac
        caller="${rest%% *}"; rest="${rest#* }"
        mode="${rest%% *}"; rest="${rest#* }"
        assertion="${rest%% *}"
        task=$(known_task "$caller" "$mode" "$assertion")
        case "$status" in
            PASS)
                if [ -n "$task" ] && [ "$STRICT" = 0 ]; then
                    printf 'UNEXPECTED-PASS %s %s %s %s (marked KNOWN-RED %s: remove the mark)\n' "$caller" "$mode" "$assertion" "" "$task"
                    unexpected=$((unexpected + 1)); fails=$((fails + 1))
                else
                    printf 'PASS %s %s %s\n' "$caller" "$mode" "$assertion"; passes=$((passes + 1))
                fi ;;
            FAIL)
                if [ -n "$task" ] && [ "$STRICT" = 0 ]; then
                    printf 'KNOWN-RED %s %s %s %s\n' "$task" "$caller" "$mode" "$assertion"; known=$((known + 1))
                else
                    printf 'FAIL %s\n' "${line#FAIL }"; fails=$((fails + 1))
                fi ;;
        esac
    done < "$RES_FILE"
}
for f in "$RES"/*.txt; do
    [ -f "$f" ] || continue
    RES_FILE="$f"
    report_file
done
printf 'quota-no-hang: %s pass, %s known-red, %s fail (%s unexpected-pass), %s skip%s\n' \
    "$passes" "$known" "$fails" "$unexpected" "$skips" "$([ "$STRICT" = 1 ] && echo ' [--strict]')"
[ "$fails" -eq 0 ]
