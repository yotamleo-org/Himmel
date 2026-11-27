#!/usr/bin/env bash
# scripts/handover/chief-kit/test-not-ready.sh - suite: not-ready.sh, the one reason the launcher
# would refuse each open ticket.
#
# Platform guard: Linux bash 3.2+ (GNU touch -d, stat -c, pgrep), as the script itself.
# SUT=<path> runs the rows against a copy of the script; NR_SRC_ROOT=<dir> points R-markers at a copy of
# the upstream sources. Both exist for mutation runs.
# shellcheck disable=SC2016  # single-quoted text here is a stand-in body or a literal pinned in a source file
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="${SUT:-$HERE/not-ready.sh}"
SRC_ROOT="${NR_SRC_ROOT:-$HERE/../../..}"
FX="$HERE/fixtures/not-ready"
TAB=$'\t'

W="$(mktemp -d "${TMPDIR:-/tmp}/not-ready-test.XXXXXX")" || { echo "FAIL: mktemp -d failed" >&2; exit 1; }
W="$(cd "$W" && pwd -P)"
trap 'rm -rf "$W"' EXIT
unset GIT_DIR GIT_WORK_TREE HANDOVER_DIR USER_SLUG TICK_STATE_DIR TICK_POOL_TTL NEXT_DISPATCH_MIRROR HIMMEL_JIRA_MIRROR \
    HIMMEL_TEST_FIXTURE NOT_READY_PRIMARY NOT_READY_STATE_DIR NOT_READY_NOW NOT_READY_DEADLINE NOT_READY_TICK_CMD \
    NOT_READY_JIRA_CLI NOT_READY_ROUNDS_CMD

NOW=1795000000
P=HIMMEL
pass=0; fails=0; ERR=""

cat > "$W/standin" <<'EOF'
#!/usr/bin/env bash
seam="$(basename "$0")"
printf '%s %s\n' "$seam" "$*" >> "$FIXTURE/calls.log"
if [ "$seam" = NOT_READY_TICK_CMD ]; then
    cmp -s - "$FIXTURE/expect.stdin" || exit 98
fi
[ "$*" = "$(cat "$FIXTURE/$seam.argv")" ] || exit 97
if [ -f "$FIXTURE/$seam.slow" ]; then
    if [ "$(cat "$FIXTURE/$seam.slow")" = escape ]; then
        exec setsid --wait bash -c 'echo up > "$0.up"; sleep 12; :' "$FIXTURE/marker-child"
    fi
    [ "$(cat "$FIXTURE/$seam.slow")" != trap ] || trap '' TERM
    bash -c 'echo up > "$0.up"; sleep 10; :' "$FIXTURE/marker-child" &
    sleep 10
fi
grep -v '^## ' "$FIXTURE/$seam.out"
exit "$(cat "$FIXTURE/$seam.rc")"
EOF
chmod +x "$W/standin"

CN=0
newcase() {
    CN=$((CN + 1))
    C="$W/c$CN"
    mkdir -p "$C/home" "$C/tmp" "$C/state" "$C/mirror" "$C/specs" "$C/bin" "$C/seam" \
        "$C/primary/scripts/handover/chief-kit"
    DOC="$C/doc.md"; printf '%s\n' '# chief doc' '## Live state' > "$DOC"
    local s
    for s in NOT_READY_TICK_CMD NOT_READY_JIRA_CLI NOT_READY_ROUNDS_CMD; do
        cp "$W/standin" "$C/seam/$s"; echo 0 > "$C/$s.rc"
    done
    printf '%s\n' '# readiness v1.1.3 blocked=0 chief-sign=0 rows-stale=0' '# pool-counts 1/0/1/0' > "$C/NOT_READY_TICK_CMD.out"
    cp "$FX/bucket-check-recorded.txt" "$C/NOT_READY_JIRA_CLI.out"
    cp "$FX/rounds-recorded.json" "$C/NOT_READY_ROUNDS_CMD.out"
    printf '%s\n' "--pool-dispositions --doc $DOC" > "$C/NOT_READY_TICK_CMD.argv"
    printf '%s\n' "round-status --all --specs $C/specs --json" > "$C/NOT_READY_ROUNDS_CMD.argv"
    for s in "$C/primary/scripts/handover/chief-kit/next-dispatchable.sh" "$C/bin/gh" "$C/bin/curl"; do
        printf '#!/usr/bin/env bash\necho "$0 $*" >> "%s/forbidden.log"\n' "$C" > "$s"; chmod +x "$s"
    done
}

snap_path() { printf '%s/tick-pool-%s' "$1" "$(printf '%s\n%s' "$2" "$3" | cksum | cut -d' ' -f1)"; }

install_snap() {
    local base; base="$(snap_path "$C/state" "$DOC" "$C/mirror")"
    grep -v '^## ' "$1" > "$base.rows"
    echo "fingerprint" > "$base.fp"
    touch -d "@$((NOW - 60))" "$base.rows" "$base.fp"
    cp "$base.rows" "$C/expect.stdin"
    SNAP="$base"
}
snap() {
    cp "$FX/base-handmade.rows" "$C/snap.rows"
    [ $# -eq 0 ] || printf '%s\n' "$@" >> "$C/snap.rows"
    install_snap "$C/snap.rows"
}
d() { printf '# disposition %s %s' "$1" "$2"; }
design_row() { printf 'DESIGN\t%s\t%s\tHigh\tv1.1.3\ttitle\tfiles=-' "$1" "$2"; }
keys() {
    printf '%s\n' "$@" > "$C/keys"
    printf '%s\n' "release bucket-check --mirror $C/mirror $*" > "$C/NOT_READY_JIRA_CLI.argv"
}
bucket() { printf '%s\n' "$@" > "$C/NOT_READY_JIRA_CLI.out"; }
bucket_in() { local k; for k in "$@"; do echo "IN $k current=v1.1.3 via=mirror"; done > "$C/NOT_READY_JIRA_CLI.out"; }
tick_says() { printf '%s\n' '# pool-counts 1/0/1/0' "$@" > "$C/NOT_READY_TICK_CMD.out"; }

fail() { ERR="$ERR
    $*"; }

run_script() {
    OUT="$(env HOME="$C/home" TMPDIR="$C/tmp" PATH="$C/bin:$PATH" FIXTURE="$C" HIMMEL_TEST_FIXTURE=1 \
        NOT_READY_STATE_DIR="$C/state" NOT_READY_PRIMARY="$C/primary" NOT_READY_NOW="$NOW" \
        NOT_READY_TICK_CMD="$C/seam/NOT_READY_TICK_CMD" NOT_READY_JIRA_CLI="$C/seam/NOT_READY_JIRA_CLI" \
        NOT_READY_ROUNDS_CMD="$C/seam/NOT_READY_ROUNDS_CMD" "$@" \
        timeout 60 bash "$SUT" --doc "$DOC" --keys "$C/keys" --version v1.1.3 --mirror "$C/mirror" --specs "$C/specs" 2>"$C/err")"
    RC=$?
}

run_case() {
    run_script "$@"
    [ "$RC" -eq 0 ] || { fail "exit $RC: $(cat "$C/err")"; return; }
    local trailer; trailer="$(tail -n 1 <<<"$OUT")"
    case "$trailer" in
        'not-ready: complete '* | 'not-ready: partial '*) ;;
        *) fail "no usable trailer, last line [$trailer]"; return ;;
    esac
    grep -qE '^# not-ready version=v1\.1\.3 pass_age_s=[0-9]+ owner_unknown=[0-9]+ blind=.+$' <<<"$(head -n 1 <<<"$OUT")" || fail "bad header [$(head -n 1 <<<"$OUT")]"
    [ "$(sed '1d;$d' <<<"$OUT" | cut -f1)" = "$(cat "$C/keys")" ] || fail "key lines differ from --keys: $OUT"
    [ "$(sed '1d;$d' <<<"$OUT" | awk -F'\t' 'NF != 3' | wc -l)" -eq 0 ] || fail "a key line is not 3 fields: $OUT"
    local n r nj ru re sum
    read -r n r nj ru re <<<"$(sed -E 's/^not-ready: [a-z]+ n=([0-9]+) refused=([0-9]+) not_judged=([0-9]+) running=([0-9]+) ready=([0-9]+)$/\1 \2 \3 \4 \5/' <<<"$trailer")"
    sum=$(( ${r:-0} + ${nj:-0} + ${ru:-0} + ${re:-0} ))
    [ "${n:-x}" = "$(wc -l < "$C/keys" | tr -d ' ')" ] && [ "$sum" = "$n" ] || fail "trailer counts do not add up: $trailer"
}

line_of() { grep "^$1$TAB" <<<"$OUT" || true; }
expect() {
    local l cls det; l="$(line_of "$1")"
    cls="$(cut -f2 <<<"$l")"; det="$(cut -f3 <<<"$l")"
    [ "$cls" = "$2" ] || { fail "$1: class [$cls] want [$2] ($det)"; return; }
    [ $# -lt 3 ] || case "$det" in *"$3"*) ;; *) fail "$1: detail [$det] lacks [$3]" ;; esac
}
completeness() {
    case "$(tail -n 1 <<<"$OUT")" in "not-ready: $1 "*) ;; *) fail "trailer is not $1: $(tail -n 1 <<<"$OUT")" ;; esac
}
blind_is() {
    local got; got="$(head -n 1 <<<"$OUT" | sed 's/.* blind=//')"
    [ "$got" = "$1" ] || fail "blind=[$got] want [$1]"
}
has() { grep -qF -e "$1" <<<"$OUT" || fail "output lacks [$1]: $OUT"; }
banner() {
    [ "$RC" -eq 0 ] || fail "exit $RC: $(cat "$C/err")"
    [ "$(wc -l <<<"$OUT" | tr -d ' ')" -eq 2 ] || fail "banner form is two lines: $OUT"
    grep -qE '^# not-ready version=v1\.1\.3 .* banner=' <<<"$(head -n 1 <<<"$OUT")" || fail "no banner header: $OUT"
    case "$(tail -n 1 <<<"$OUT")" in 'not-ready: unavailable '*"$1"*) ;; *) fail "trailer lacks unavailable [$1]: $OUT" ;; esac
}

row() {
    ERR=""
    "$2"
    if [ -z "$ERR" ]; then echo "  PASS: $1"; pass=$((pass + 1)); else echo "  FAIL: $1$ERR"; fails=$((fails + 1)); fi
}

r_version() {
    newcase; snap "$(d "$P-9915" 'listed LOCAL')"; keys HIMMEL-9915; run_case
    expect HIMMEL-9915 version 'none current=v1.1.3 open=358'
    newcase; snap "$(d "$P-8020" 'listed LOCAL')" "$(d "$P-9432" 'listed LOCAL')"; keys HIMMEL-8020 HIMMEL-9432
    bucket "NONE HIMMEL-8020 $C/mirror" 'APPROVED HIMMEL-9432 decision=12 record=r1'; run_case
    expect HIMMEL-8020 ready; expect HIMMEL-9432 ready; completeness complete
}

r_status() {
    newcase; snap "$(d "$P-10215" 'listed RESUME')"; keys HIMMEL-10215; run_case
    expect HIMMEL-10215 status 'Done in the Jira mirror'
}

r_bucket() {
    newcase; snap "$(d "$P-8020" 'listed LOCAL')" "$(d "$P-9432" 'listed LOCAL')"; keys HIMMEL-8020 HIMMEL-9432
    bucket 'FAILED HIMMEL-8020 the live read failed' 'IN HIMMEL-9432 current=v1.1.3 via=mirror'; run_case
    expect HIMMEL-8020 cannot-judge 'the live read failed'; expect HIMMEL-9432 ready; completeness complete
    newcase; snap "$(d "$P-8020" 'blocker HIMMEL-1 (To Do, live)')" "$(d "$P-9432" 'listed LOCAL')"; keys HIMMEL-8020 HIMMEL-9432
    echo 1 > "$C/NOT_READY_JIRA_CLI.rc"; run_case
    expect HIMMEL-8020 dispatch:blocker; expect HIMMEL-9432 cannot-judge 'bucket-check:'; completeness partial; blind_is bucket-check
    newcase; snap "$(d "$P-9915" 'listed LOCAL')"; keys HIMMEL-9915
    bucket 'OUTSIDE HIMMEL-9915 none current=v1.1.4 open=40'; run_case
    expect HIMMEL-9915 cannot-judge 'bucket-version:'; completeness partial; blind_is bucket-version
    newcase; snap "$(d "$P-9432" 'listed LOCAL')"; keys HIMMEL-9432
    bucket 'IN HIMMEL-9432 current=v1.1.4 via=mirror'; run_case
    expect HIMMEL-9432 cannot-judge 'bucket-version:'
    newcase; snap "$(d "$P-8020" 'listed LOCAL')" "$(d "$P-9432" 'listed LOCAL')"; keys HIMMEL-8020 HIMMEL-9432
    bucket 'IN HIMMEL-9432 current=v1.1.3 via=mirror'; run_case
    expect HIMMEL-8020 cannot-judge 'bucket-check:'; expect HIMMEL-9432 cannot-judge 'bucket-check:'; blind_is bucket-check
}

r_unsigned() {
    newcase
    snap "$(d "$P-8020" 'listed DESIGN')" "$(d "$P-10216" 'listed DESIGN')" "$(d "$P-9432" 'spec-needs-operator O-1')" \
        "$(d "$P-9816" 'listed DESIGN')" "$(design_row "$P-8020" NO-SPEC)" "$(design_row "$P-10216" SPEC-STALE)"
    keys HIMMEL-8020 HIMMEL-10216 HIMMEL-9432 HIMMEL-9816
    bucket_in HIMMEL-8020 HIMMEL-10216 HIMMEL-9432 HIMMEL-9816; run_case
    expect HIMMEL-8020 unsigned-design 'NO-SPEC; no rounds yet'
    expect HIMMEL-10216 unsigned-design 'SPEC-STALE; spec r2 plan r1 next full'
    expect HIMMEL-9432 unsigned-design "needs the operator's signature (O-1)"
    expect HIMMEL-9816 cannot-judge 'listed DESIGN'
}

r_round_cap() {
    newcase; snap "$(d "$P-10012" 'listed DESIGN')" "$(design_row "$P-10012" NO-SPEC)"; keys HIMMEL-10012
    bucket_in HIMMEL-10012; run_case
    expect HIMMEL-10012 round-cap 'spec round 7'
    newcase; snap "$(d "$P-8020" 'listed DESIGN')" "$(design_row "$P-8020" NO-SPEC)"; keys HIMMEL-8020
    cp "$FX/rounds-error-handmade.json" "$C/NOT_READY_ROUNDS_CMD.out"; run_case
    expect HIMMEL-8020 cannot-judge 'ledger row 2 does not verify'
    newcase; snap "$(d "$P-8020" 'listed DESIGN')" "$(design_row "$P-8020" NO-SPEC)"; keys HIMMEL-8020
    echo 1 > "$C/NOT_READY_ROUNDS_CMD.rc"; run_case
    expect HIMMEL-8020 unsigned-design 'NO-SPEC; rounds unread'; completeness partial; blind_is rounds
}

r_held() {
    newcase; snap "$(d "$P-8020" 'listed LOCAL')" "$(d "$P-9432" 'listed RESUME')" "$(d "$P-9816" 'listed CLOUD')"
    keys HIMMEL-8020 HIMMEL-9432 HIMMEL-9816
    tick_says '# pool-parked HIMMEL-8020' '# readiness-held c HIMMEL-9432 blocker=123 age=2h' \
        '# pool-unresolved unchecked HIMMEL-9816 no holds file: HIMMEL-9816 park x'
    run_case
    expect HIMMEL-8020 held '# pool-parked HIMMEL-8020'
    expect HIMMEL-9432 held '# readiness-held c HIMMEL-9432'
    expect HIMMEL-9816 cannot-judge 'pool-unresolved unchecked'
    local says
    for says in '# readiness ?' '# pool-counts ?'; do
        newcase; snap "$(d "$P-9432" 'listed LOCAL')"; keys HIMMEL-9432; tick_says "$says"; run_case
        expect HIMMEL-9432 cannot-judge "tick-reading: $says"; completeness partial; blind_is tick-reading
    done
    newcase; snap "$(d "$P-9432" 'listed LOCAL')"; keys HIMMEL-9432; echo 1 > "$C/NOT_READY_TICK_CMD.rc"; run_case
    expect HIMMEL-9432 cannot-judge 'tick-reading:'; blind_is tick-reading
    newcase; snap "$(d "$P-9432" 'listed LOCAL')"; keys HIMMEL-9432; : > "$C/NOT_READY_TICK_CMD.out"; run_case
    expect HIMMEL-9432 cannot-judge 'tick-reading:'; blind_is tick-reading
}

r_file_held() {
    local holder
    for holder in 'live worker N7' 'open PR 41' 'open PR 41 (idle 9d)' 'held list' 'series S1'; do
        newcase; snap "# overlap HIMMEL-8020 scripts/a.sh with $holder" "$(d "$P-8020" 'listed LOCAL')"; keys HIMMEL-8020; run_case
        expect HIMMEL-8020 file-held "scripts/a.sh with $holder"
    done
    newcase; snap '# overlap HIMMEL-8020 scripts/a.sh with listed HIMMEL-9432' "$(d "$P-8020" 'listed LOCAL')"; keys HIMMEL-8020; run_case
    expect HIMMEL-8020 ready
    local odd
    for odd in '# overlap HIMMEL-8020 scripts/a.sh with mystery 9' '# overlap HIMMEL-8020 also named by outside PR 3 (idle 9d)'; do
        newcase; snap "$odd" "$(d "$P-8020" 'listed LOCAL')"; keys HIMMEL-8020; run_case
        expect HIMMEL-8020 cannot-judge "$odd"
    done
}

r_chain() {
    newcase
    snap "$(d "$P-8020" 'listed LOCAL')" "$(d "$P-9432" 'listed LOCAL')" "$(d "$P-9816" 'listed LOCAL')" "$(d "$P-9915" 'listed LOCAL')"
    keys HIMMEL-8020 HIMMEL-9432 HIMMEL-9816 HIMMEL-9915
    bucket_in HIMMEL-8020 HIMMEL-9432 HIMMEL-9816 HIMMEL-9915
    cp "$FX/chains-handmade.json" "$C/focus-chains.json"; run_case
    expect HIMMEL-8020 ready
    expect HIMMEL-9432 chain "not the chain's next step (next: HIMMEL-8020) in chain demo-chain"
    expect HIMMEL-9816 cannot-judge 'demo-chain'
    expect HIMMEL-9915 cannot-judge 'hand-kept'
    completeness complete
    newcase; snap "$(d "$P-9432" 'listed LOCAL')"; keys HIMMEL-9432; run_case
    expect HIMMEL-9432 ready; completeness complete
    newcase; snap "$(d "$P-9432" 'listed LOCAL')"; keys HIMMEL-9432; echo '[{' > "$C/focus-chains.json"; run_case
    expect HIMMEL-9432 cannot-judge 'chains:'; completeness partial; blind_is chains
    newcase; snap "$(d "$P-9432" 'listed LOCAL')"; keys HIMMEL-9432
    OUT="$(env HOME="$C/home" PATH="$C/bin:$PATH" FIXTURE="$C" HIMMEL_TEST_FIXTURE=1 NOT_READY_STATE_DIR="$C/state" \
        NOT_READY_PRIMARY="$C/primary" NOT_READY_NOW="$NOW" NOT_READY_TICK_CMD="$C/seam/NOT_READY_TICK_CMD" \
        NOT_READY_JIRA_CLI="$C/seam/NOT_READY_JIRA_CLI" NOT_READY_ROUNDS_CMD="$C/seam/NOT_READY_ROUNDS_CMD" \
        bash "$SUT" --doc "$DOC" --keys "$C/keys" --version v1.1.3 --mirror "$C/mirror" --specs "$C/specs" --chains "$C/typo.json" 2>"$C/err")"
    expect HIMMEL-9432 cannot-judge 'chains:'; completeness partial; blind_is chains
}

r_dispatch() {
    local -a words=(blocker blocker partial-merge resume-brief no-scope proof label type platform residual-depth cloud-only classifier classifier owed stackable unowned)
    local -a texts=(
        'blocker HIMMEL-1 (To Do, live)'
        'blocker HIMMEL-1 (To Do, live); blocker-unknown HIMMEL-2'
        'partial-merge (a merged contract=no PR: RESUME row, HANDED-OFF, or needs a chief note)'
        'resume-brief (a wrapped worker resumes it: RESUME row)'
        'no-scope (nothing says what it writes: a chief question)'
        'proof missing: DoD, Proof (the ticket-standard checker could not pass it)'
        'label held'
        'type Epic'
        'platform (dropped-platform title)'
        'residual-depth 2 (no residual-must line, no admissions-ledger row)'
        'cloud-only on the priority line'
        'classification BLOCKED: x'
        'classification BLOCKED'
        'owned next step: chief'
        'stackable on L1 (1/3)'
        'unowned In Progress (no worker, no open PR; not listed: held, blocked, parked or unread)')
    newcase
    local -a ks=() ds=()
    local i
    for i in "${!texts[@]}"; do ks+=("HIMMEL-$((101 + i))"); ds+=("$(d "HIMMEL-$((101 + i))" "${texts[$i]}")"); done
    ks+=(HIMMEL-200); ds+=("$(d "$P-200" 'listed RESUME')" 'NEEDS-CHIEF-NOTE HIMMEL-200: merged PR #5 has no Remaining: line')
    snap "${ds[@]}"; keys "${ks[@]}"; bucket_in "${ks[@]}"; run_case
    for i in "${!texts[@]}"; do expect "HIMMEL-$((101 + i))" "dispatch:${words[$i]}" "${texts[$i]:0:60}"; done
    expect HIMMEL-113 dispatch:classifier
    expect HIMMEL-114 dispatch:owed chief
    expect HIMMEL-200 dispatch:needs-chief-note 'NEEDS-CHIEF-NOTE HIMMEL-200:'
}

r_unknown() {
    local -a texts=(
        'owner unknown: a named worker source could not be fully read (see the # owner unknown line)'
        'core-unknown (not in the mirror: neither core nor a bypass can be proven)'
        'classification none (cloud-route gave no verdict)'
        'below --top 1000'
        'unknown (no drop reason recorded)'
        'frobnicated now'
        'blocker-unknown HIMMEL-2'
        'open PRs unknown (gh failed): ownership cannot be checked'
        'status-events.jsonl unreadable and the key has a merge on main'
        'core-check failed (a gate that cannot run lists no To Do row)'
        'spec-signer-unknown O-1'
        'listed FRESHLANE'
        'tier 5 (outside the priority pool)')
    newcase
    local -a ks=() ds=(
        '# owner unknown: live worker N1 of the chief on A (doc a.md unreadable; keys held: HIMMEL-1); withheld: To Do; reconcile: x'
        '# owner unknown: live worker N1 of the chief on B (doc a.md unreadable; keys held: HIMMEL-1); withheld: To Do; reconcile: x'
        '# owner unknown: live worker N2 of the chief on B (doc b.md unreadable; keys held: HIMMEL-2); withheld: To Do; reconcile: x')
    local i
    for i in "${!texts[@]}"; do ks+=("HIMMEL-$((101 + i))"); ds+=("$(d "HIMMEL-$((101 + i))" "${texts[$i]}")"); done
    snap "${ds[@]}"; keys "${ks[@]}"; bucket_in "${ks[@]}"; run_case
    for i in "${!texts[@]}"; do expect "HIMMEL-$((101 + i))" cannot-judge "${texts[$i]:0:60}"; done
    has ' owner_unknown=2 '
}

r_running() {
    newcase
    snap "$(d "$P-8020" 'owned by live worker N1 of the chief on X')" "$(d "$P-9432" 'in-flight owned by open PR 3')" "$(d "$P-9816" 'owned next step: chief')"
    keys HIMMEL-8020 HIMMEL-9432 HIMMEL-9816; run_case
    expect HIMMEL-8020 running 'live worker N1 of the chief on X'
    expect HIMMEL-9432 running 'open PR 3'
    expect HIMMEL-9816 dispatch:owed
}

r_closing() {
    newcase; snap "$(d "$P-8020" 'listed MERGED-NOT-CLOSED')" "$(d "$P-9432" 'done-pending (a contract=yes merge row; the mirror lags)')"
    keys HIMMEL-8020 HIMMEL-9432; run_case
    expect HIMMEL-8020 needs-closing 'listed MERGED-NOT-CLOSED'; expect HIMMEL-9432 needs-closing 'done-pending'
}

r_cohort() {
    newcase; snap "$(d "$P-8020" 'listed LOCAL')"; keys HIMMEL-8020 HIMMEL-9432; run_case
    expect HIMMEL-8020 ready; expect HIMMEL-9432 cannot-judge 'no disposition'
}

blind_summary() {
    newcase
    sed "s/^# next-dispatchable: .*/&$1/" "$FX/base-handmade.rows" > "$C/snap.rows"
    printf '%s\n' "$(d "$P-8020" 'listed LOCAL')" "$(d "$P-9432" 'blocker HIMMEL-1 (To Do, live)')" >> "$C/snap.rows"
    install_snap "$C/snap.rows"; keys HIMMEL-8020 HIMMEL-9432; run_case
}

r_blind() {
    local m
    for m in 'live workers unknown' 'open PRs unknown' 'merged PRs unknown'; do
        blind_summary ", $m (gh failed)"
        expect HIMMEL-8020 cannot-judge "$m: # next-dispatchable:"; expect HIMMEL-9432 dispatch:blocker
        completeness partial; blind_is "$m"
    done
    blind_summary ', something new'
    expect HIMMEL-8020 cannot-judge 'summary: # next-dispatchable:'; blind_is summary
    for m in 'overlap unknown|# overlap unknown for live worker N1' 'WARN|# WARN CORE-CHECK-FAILED timeout' \
        'warn|# warn: /x/status-events.jsonl is unreadable (denied): merged contract rows are unknown'; do
        newcase; snap "${m#*|}" "$(d "$P-8020" 'listed LOCAL')" "$(d "$P-9432" 'blocker HIMMEL-1 (To Do, live)')"
        keys HIMMEL-8020 HIMMEL-9432; run_case
        expect HIMMEL-8020 cannot-judge "${m%%|*}: ${m#*|}"; expect HIMMEL-9432 dispatch:blocker
        completeness partial; blind_is "${m%%|*}"
    done
    newcase; snap '# warn: HIMMEL-8020 names docs/x.md (not in the repo: a new file, or the collision check is blind)' \
        "$(d "$P-8020" 'listed LOCAL')" "$(d "$P-9432" 'listed LOCAL')"
    keys HIMMEL-8020 HIMMEL-9432; run_case
    expect HIMMEL-8020 cannot-judge 'warn:HIMMEL-8020:'; expect HIMMEL-9432 ready; completeness partial; blind_is warn:HIMMEL-8020
}

r_banner() {
    local gone
    for gone in rows fp; do
        newcase; snap "$(d "$P-8020" 'listed LOCAL')"; keys HIMMEL-8020; rm "$SNAP.$gone"; run_script
        banner "no dispatcher pass yet for $DOC"
    done
    newcase; snap "$(d "$P-8020" 'listed LOCAL')"; keys HIMMEL-8020; touch -d "@$((NOW - 1801))" "$SNAP.rows"; run_script
    banner 'dispatcher pass 1801s old'
    newcase; snap "$(d "$P-8020" 'listed LOCAL')"; keys HIMMEL-8020; touch -d "@$((NOW - 2400))" "$SNAP.fp"; run_case
    expect HIMMEL-8020 ready; has ' pass_age_s=2400 '
    local first
    for first in '# gh-stall GH-STALL graphql 400s' '# quota-pause QUOTA-PAUSE core until 12:00'; do
        newcase; echo "$first" > "$C/one.rows"; install_snap "$C/one.rows"; keys HIMMEL-8020; run_script
        banner "$first"
    done
    newcase; sed 's/^# dropped from v1\.1\.3:/# dropped from v1.1.4:/' "$FX/base-handmade.rows" > "$C/snap.rows"
    install_snap "$C/snap.rows"; keys HIMMEL-8020; run_script
    banner 'v1.1.4'
    newcase; grep -v '^# dropped from' "$FX/base-handmade.rows" > "$C/snap.rows"; install_snap "$C/snap.rows"; keys HIMMEL-8020; run_script
    banner 'dropped from'
    [ ! -e "$C/calls.log" ] || fail "an unusable snapshot ran a child: $(cat "$C/calls.log")"
}

r_order() {
    newcase; snap "$(d "$P-9432" 'listed DESIGN')" "$(design_row "$P-9432" NO-SPEC)"; keys HIMMEL-9432
    cp "$FX/chains-handmade.json" "$C/focus-chains.json"; run_case
    expect HIMMEL-9432 unsigned-design
    newcase; snap '# overlap HIMMEL-8020 scripts/a.sh with live worker N7' "$(d "$P-8020" 'listed LOCAL')"; keys HIMMEL-8020
    tick_says '# pool-parked HIMMEL-8020'; run_case
    expect HIMMEL-8020 held
    newcase; snap '# overlap HIMMEL-9915 scripts/a.sh with live worker N7' "$(d "$P-9915" 'listed LOCAL')"; keys HIMMEL-9915; run_case
    expect HIMMEL-9915 file-held
    newcase; snap '# overlap HIMMEL-9432 scripts/a.sh with live worker N7' "$(d "$P-9432" 'listed LOCAL')"; keys HIMMEL-9432
    cp "$FX/chains-handmade.json" "$C/focus-chains.json"; run_case
    expect HIMMEL-9432 chain
    newcase
    snap '# overlap HIMMEL-9816 scripts/a.sh with live worker N7' "$(d "$P-8020" 'blocker HIMMEL-1 (To Do, live)')" \
        "$(d "$P-9432" 'owned by live worker N1')" "$(d "$P-9816" 'listed LOCAL')"
    keys HIMMEL-8020 HIMMEL-9432 HIMMEL-9816
    bucket 'FAILED HIMMEL-8020 x' 'FAILED HIMMEL-9432 x' 'FAILED HIMMEL-9816 x'
    cp "$FX/chains-handmade.json" "$C/focus-chains.json"
    sed -i 's/"unknown": \[/"unknown": ["HIMMEL-9432", "HIMMEL-8020", /' "$C/focus-chains.json"; run_case  # gnu-ok: Linux-only suite
    expect HIMMEL-8020 dispatch:blocker; expect HIMMEL-9432 running; expect HIMMEL-9816 file-held
}

r_negative() {
    newcase; install_snap "$FX/capture-clean-2026-11-19.rows"; keys HIMMEL-9816
    cp "$FX/tick-reading-recorded.txt" "$C/NOT_READY_TICK_CMD.out"; run_case
    expect HIMMEL-9816 ready; completeness partial; blind_is warn:HIMMEL-6546
}

r_detail() {
    local long want
    long="zzz${TAB}$(printf 'a%.0s' $(seq 1 296))"
    want="zzz $(printf 'a%.0s' $(seq 1 156))"
    newcase; snap "$(d "$P-8020" "$long")"; keys HIMMEL-8020; run_case
    [ "$(line_of "$P-8020" | cut -f3)" = "$want" ] || fail "detail: [$(line_of "$P-8020" | cut -f3)]"
}

r_capture() {
    local -a du=(HIMMEL-11246 HIMMEL-11306 HIMMEL-10925 HIMMEL-11323 HIMMEL-11235 HIMMEL-10926 HIMMEL-10944 HIMMEL-9653 HIMMEL-10380 HIMMEL-10222 HIMMEL-10218 HIMMEL-10069 HIMMEL-10258)
    newcase; install_snap "$FX/capture-dw-2026-11-27.rows"
    local at; at="$(awk -F'\t' '$1 == "capture-dw-2026-11-27.rows" {print $4}' "$FX/captures.tsv")"
    touch -d "@$at" "$SNAP.rows" "$SNAP.fp"
    keys "${du[@]}"; bucket_in "${du[@]}"; run_case NOT_READY_NOW="$((at + 60))"
    expect HIMMEL-11235 running 'live worker N41073'; expect HIMMEL-10222 dispatch:unowned
    [ "$(grep -c "${TAB}cannot-judge${TAB}owner unknown" <<<"$OUT")" -eq 11 ] || fail "want 11 owner-unknown keys: $OUT"
    has ' pass_age_s=60 owner_unknown=14 '; completeness partial; blind_is 'live workers unknown,overlap unknown'
}

r_path() {
    local tick="$SRC_ROOT/scripts/handover/chief-kit/tick.sh" theirs ours want got
    theirs="$(grep -m 1 -E '^ *pd_base="\$pd_dir/tick-pool-' "$tick")"
    ours="$(grep -m 1 -E '^ *snap_base="\$state_dir/tick-pool-' "$SUT" 2>/dev/null)"
    [ -n "$theirs" ] && [ -n "$ours" ] || { fail "path line missing: tick=[$theirs] script=[$ours]"; return; }
    want="$(pd_dir=/s console_doc='/d/a b.md' nd_mirror=/m bash -c "$theirs; printf %s \"\$pd_base\"")"
    got="$(state_dir=/s doc='/d/a b.md' mirror=/m bash -c "$ours; printf %s \"\$snap_base\"")"
    [ "$want" = "$got" ] || fail "path: tick=$want script=$got"
    local pin
    for pin in '${TICK_POOL_TTL:-1800}' '${TICK_STATE_DIR:-${HOME:-/tmp}/.himmel/state}' '${NEXT_DISPATCH_MIRROR:-'; do
        if ! grep -qF -e "$pin" "$tick" || ! grep -qF -e "$pin" "$SUT"; then fail "default [$pin] is not in both"; fi
    done
    if ! grep -qF 'tick_mirror_default="$(jira_mirror_dir)"' "$tick" || ! grep -qF 'jira_mirror_dir' "$SUT"; then fail "mirror default"; fi
    grep -qF 'stat -c %Y "$pd_base.rows"' "$tick" || fail "the tick no longer ages the .rows file"  # gnu-ok: a literal pinned in tick.sh
    newcase; snap "$(d "$P-8020" 'listed DESIGN')" "$(design_row "$P-8020" NO-SPEC)"; keys HIMMEL-8020
    printf '%s\n' "round-status --all --specs $C/handovers/u1/himmel/specs --json" > "$C/NOT_READY_ROUNDS_CMD.argv"
    mkdir -p "$C/handovers/u1/himmel/specs"
    OUT="$(env HOME="$C/home" TMPDIR="$C/tmp" PATH="$C/bin:$PATH" FIXTURE="$C" HIMMEL_TEST_FIXTURE=1 HANDOVER_DIR="$C/handovers" USER_SLUG=u1 \
        NEXT_DISPATCH_MIRROR="$C/mirror" TICK_STATE_DIR="$C/state" NOT_READY_PRIMARY="$C/primary" NOT_READY_NOW="$NOW" \
        NOT_READY_TICK_CMD="$C/seam/NOT_READY_TICK_CMD" NOT_READY_JIRA_CLI="$C/seam/NOT_READY_JIRA_CLI" \
        NOT_READY_ROUNDS_CMD="$C/seam/NOT_READY_ROUNDS_CMD" timeout 60 bash "$SUT" --doc "$DOC" --keys "$C/keys" --version v1.1.3 2>"$C/err")"
    expect HIMMEL-8020 unsigned-design 'NO-SPEC; no rounds yet'; completeness complete
}

r_markers() {
    OUT="$(python3 -I - "$SUT" "$SRC_ROOT" 2>&1 <<'PY'
import ast, os, re, sys
sut, root = sys.argv[1:3]
try:
    text = open(sut).read()
    block = re.search(r'^MARKERS = (\{.*?^\})$', text, re.M | re.S).group(1)
    table = ast.literal_eval(block)
except (OSError, AttributeError, ValueError, SyntaxError) as e:
    sys.exit('no MARKERS table in the script: %s' % e)
FILES = {'dispatcher': 'scripts/handover/chief-kit/next-dispatchable.sh', 'tick': 'scripts/handover/chief-kit/tick.sh',
         'bucket': 'scripts/jira/src/release/operator-acts.ts', 'rounds': 'scripts/telegram/chief-route.ts'}
# every disposition prefix, blind marker, tick line, verdict word and round field of spec D2 and D1
WANT = '''owner-unknown blocker-unknown open-prs-unknown status-unreadable core-check-failed core-unknown
spec-signer-unknown classification-none below-top unknown-reason owned-by in-flight listed merged-not-closed done-pending
needs-chief-note blocker partial-merge resume-brief no-scope proof-missing label type platform residual-depth cloud-only
classification-blocked owed-step stackable unowned spec-needs-operator design-row lane-local lane-cloud lane-resume
lane-series lane-design hold-live-worker hold-open-pr hold-held-list hold-series hold-listed overlap overlap-unknown
warn-names warn warn-upper summary summary-resume summary-live summary-prs summary-merged dropped-from owner-unknown-line
quota-pause gh-stall pool-parked readiness-held pool-unchecked readiness-blind counts-blind counts bucket-failed
bucket-none bucket-approved bucket-done bucket-in bucket-outside rounds-keys rounds-next rounds-error'''.split()
bad = ['no entry for %s' % k for k in WANT if k not in table]
cache = {}
for name, (src, match, pins) in sorted(table.items()):
    if src not in cache:
        cache[src] = open(os.path.join(root, FILES[src])).read()
    bad += ['%s: %r is not in %s' % (name, p, FILES[src]) for p in pins if p not in cache[src]]
    joined = ' '.join(pins)
    bad += ['%s: match word %r is in no pin' % (name, w) for w in match.split() if w not in joined]
    if not pins or not match:
        bad.append('%s: empty entry' % name)
print('\n'.join(bad))
sys.exit(1 if bad else 0)
PY
)" || fail "$OUT"
}

r_once() {
    newcase; snap "$(d "$P-8020" 'listed DESIGN')" "$(d "$P-9432" 'listed LOCAL')" "$(design_row "$P-8020" NO-SPEC)"
    keys HIMMEL-8020 HIMMEL-9432
    cp "$FX/chains-handmade.json" "$C/focus-chains.json"
    manifest() { (cd "$C" && find . -type f ! -name calls.log ! -name err -exec sha256sum {} + -exec stat -c '%n %s' {} + | sort); }  # gnu-ok: Linux-only suite
    : > "$C/err"
    local before after; before="$(manifest)"
    run_case
    after="$(manifest)"
    [ "$before" = "$after" ] || fail "the run changed a file: $(diff <(printf '%s\n' "$before") <(printf '%s\n' "$after"))"
    local want
    want="NOT_READY_TICK_CMD --pool-dispositions --doc $DOC
NOT_READY_JIRA_CLI release bucket-check --mirror $C/mirror HIMMEL-8020 HIMMEL-9432
NOT_READY_ROUNDS_CMD round-status --all --specs $C/specs --json"
    [ "$(cat "$C/calls.log" 2>/dev/null)" = "$want" ] || fail "calls: $(cat "$C/calls.log" 2>/dev/null)"
    [ ! -e "$C/forbidden.log" ] || fail "forbidden call: $(cat "$C/forbidden.log")"
    [ -r "$SUT" ] || { fail "no script to read"; return; }
    if grep -q 'next-dispatchable\.sh' <<<"$(grep -vE '^[[:space:]]*#( |$)' "$SUT")"; then fail "a non-comment line names next-dispatchable.sh"; fi
    newcase; snap "$(d "$P-9432" 'listed LOCAL')"; keys HIMMEL-9432; run_case
    ! grep -q '^NOT_READY_ROUNDS_CMD' "$C/calls.log" || fail "round-status ran with no DESIGN row"
}

r_deadline() {
    local mode t0 ms
    for mode in plain trap; do
        newcase; snap "$(d "$P-8020" 'listed DESIGN')" "$(d "$P-9432" 'listed LOCAL')" "$(design_row "$P-8020" NO-SPEC)"
        keys HIMMEL-8020 HIMMEL-9432
        echo "$mode" > "$C/NOT_READY_JIRA_CLI.slow"
        t0="$(date +%s%N)"; run_case NOT_READY_DEADLINE=7; ms=$(( ($(date +%s%N) - t0) / 1000000 ))
        [ "$ms" -le 8000 ] || fail "$mode: took ${ms} ms"
        grep -q '^NOT_READY_JIRA_CLI ' "$C/calls.log" || fail "$mode: the slow stand-in never ran"
        [ -f "$C/marker-child.up" ] || fail "$mode: the slow child never started"
        completeness partial; blind_is 'bucket-check,rounds'
        expect HIMMEL-9432 cannot-judge 'bucket-check:'
        [ "$(grep -c '^not-ready: ' <<<"$OUT")" -eq 1 ] || fail "$mode: want one trailer"
        ! grep -q '^NOT_READY_ROUNDS_CMD' "$C/calls.log" || fail "$mode: a child ran with no budget"
        if pgrep -f "$C/marker-child" >/dev/null 2>&1 || pgrep -f "$C/seam/NOT_READY_JIRA_CLI" >/dev/null 2>&1; then
            fail "$mode: a stand-in process outlived the run"
        fi
    done
    newcase; snap "$(d "$P-9432" 'listed LOCAL')"; keys HIMMEL-9432
    echo escape > "$C/NOT_READY_JIRA_CLI.slow"
    t0="$(date +%s%N)"; run_case NOT_READY_DEADLINE=7; ms=$(( ($(date +%s%N) - t0) / 1000000 ))
    [ "$ms" -le 8000 ] || fail "escape: a child that left the group held the run for ${ms} ms"
    if [ ! -f "$C/marker-child.up" ] || [ "$ms" -lt 3000 ]; then fail "escape: the escaped child never held the run (${ms} ms)"; fi
    expect HIMMEL-9432 cannot-judge 'bucket-check:'
    pkill -f "$C/marker-child" 2>/dev/null || true  # swallow-ok: nothing left to stop is the clean case
}

r_usage() {
    newcase; snap "$(d "$P-8020" 'listed LOCAL')"; keys HIMMEL-8020; echo 'not a key' >> "$C/keys"; run_script
    [ "$RC" -eq 2 ] || fail "a non-key line: exit $RC"
    local args want
    newcase; snap "$(d "$P-8020" 'listed LOCAL')"; keys HIMMEL-8020
    for args in '2|--bogus' "2|--doc $DOC --keys $C/keys" "3|--doc $C/none.md --keys $C/keys --version v1.1.3 --mirror $C/mirror" \
        "3|--doc $DOC --keys $C/none --version v1.1.3 --mirror $C/mirror" "3|--doc $DOC --keys $C/keys --version v1.1.3 --mirror $C/none"; do
        want="${args%%|*}"
        # shellcheck disable=SC2086  # the row's arguments are split on purpose
        HOME="$C/home" timeout 30 bash "$SUT" ${args#*|} >/dev/null 2>&1
        RC=$?
        [ "$RC" -eq "$want" ] || fail "[${args#*|}]: exit $RC want $want"
    done
    newcase; snap "$(d "$P-8020" 'listed LOCAL')"; keys HIMMEL-8020
    run_script HIMMEL_TEST_FIXTURE=
    banner "no dispatcher pass yet for $DOC"
    [ ! -e "$C/calls.log" ] || fail "a seam ran without the fixture flag: $(cat "$C/calls.log")"
    run_case
    expect HIMMEL-8020 ready
}

row R-version r_version
row R-status r_status
row R-bucket r_bucket
row R-unsigned r_unsigned
row R-round-cap r_round_cap
row R-held r_held
row R-file-held r_file_held
row R-chain r_chain
row R-dispatch r_dispatch
row R-unknown r_unknown
row R-running r_running
row R-closing r_closing
row R-cohort r_cohort
row R-blind r_blind
row R-banner r_banner
row R-order r_order
row R-negative r_negative
row R-detail r_detail
row R-capture r_capture
row R-path r_path
row R-markers r_markers
row R-once r_once
row R-deadline r_deadline
row R-usage r_usage

echo "test-not-ready: $pass passed, $fails failed"
[ "$fails" -eq 0 ]
