#!/usr/bin/env bash
# test-tick-pool-stale.sh — tick.sh --pool-stale re-checks every Live-state
# `pool-disposition:` line whose target names a ticket key or `PR <n>` and reports
# pool-stale=<n>:<KEY>,... when every named blocker is Done or merged (`?` for an unreadable
# target, never stale; a still-open target stays quiet), and residual-unversioned=<n>:<KEY>,...
# for open residuals of open focus-version tickets that carry no fixVersion. Fixture mirror and
# a stub gh (TICK_GH_CMD) only: no Jira, GitHub or live chief doc is touched.
#
# SUT overrides the script under test (the RED control: a tick without --pool-stale fails
# every row). PLATFORM GUARD: the chief kit is Linux-only. bash 3.2-safe.
#
# Run: bash scripts/handover/chief-kit/test-tick-pool-stale.sh
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="${SUT:-$HERE/tick.sh}"

fails=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; fails=$((fails + 1)); }
check() { # <name> <expected> <actual>
    if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (want '$2' got '$3')"; fi
}

WORK="$(mktemp -d "${TMPDIR:-/tmp}/tick-pool-stale-test.XXXXXX")" || exit 1
trap 'rm -rf "$WORK"' EXIT
M="$WORK/mirror/HIMMEL"; mkdir -p "$M"
printf 'v1.1.3\tfalse\t\n' > "$WORK/mirror/HIMMEL.versions.tsv"
mk() { # <num> <status> <statusCategory> <fixVersions json> <labels json> <relates json>
    printf -- '---\nkey: "HIMMEL-%s"\ntype: "Task"\nstatus: "%s"\nstatusCategory: "%s"\npriority: "Medium"\nlabels: %s\nfixVersions: %s\nparent: null\nlinks:\n  blocks: []\n  blocked_by: []\n  relates: %s\n---\n\n# HIMMEL-%s: t\n\n## Description\n\nbody\n' \
        "$1" "$2" "$3" "$5" "$4" "$6" "$1" > "$M/HIMMEL-$1.md"
}
mk 901 "Done" Done '["v1.1.3"]' '[]' '[]'
mk 902 "In Progress" "In Progress" '["v1.1.3"]' '[]' '[]'
# residuals: 110 is the open focus-version ticket; 111 is its unversioned residual
mk 110 "To Do" "To Do" '["v1.1.3"]' '[]' '["relates to HIMMEL-111","relates to HIMMEL-112"]'
mk 111 "To Do" "To Do" '[]' '["residual","residual-depth-1"]' '["relates to HIMMEL-110"]'
mk 112 "To Do" "To Do" '["v1.1.3"]' '["residual-depth-1"]' '["relates to HIMMEL-110"]'
mk 113 "Done" Done '[]' '["residual-depth-1"]' '["relates to HIMMEL-110"]'
mk 114 "To Do" "To Do" '[]' '["residual-depth-1"]' '["relates to HIMMEL-901"]'
mk 116 "To Do" "To Do" '[]' '[]' '["relates to HIMMEL-110"]'

cat > "$WORK/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$PS_GH_LOG"
[ ! -f "$PS_GH_FAIL" ] || exit 1
printf '5001\tMERGED\n5002\tOPEN\n5004\tCLOSED\n'
EOF
chmod +x "$WORK/gh"
export PS_GH_LOG="$WORK/gh.log" PS_GH_FAIL="$WORK/gh.fail" NEXT_DISPATCH_MIRROR="$M" TICK_GH_CMD="$WORK/gh"

doc() { # <name> <disposition line>...: a chief doc whose Live state holds those lines
    local f="$WORK/$1.md"; shift
    { printf '# chief\n\n## Live state\n'; for l in "$@"; do printf '%s\n' "$l"; done; printf '\n## Results\npool-disposition: HIMMEL-120 slice HIMMEL-901 outside the live state\n'; } > "$f"
    printf '%s' "$f"
}
field() { # <field> <doc>: the value of one --pool-stale output field
    TOKEN='' bash "$SUT" --pool-stale --doc "$2" 2>/dev/null | sed -n "s/^$1=//p"
}

: > "$PS_GH_LOG"
d="$(doc stalekey 'pool-disposition: HIMMEL-101 slice HIMMEL-901 then the rest')"
check 'a target naming a Done ticket reports it stale' '1:HIMMEL-101' "$(field pool-stale "$d")"
check 'a ticket-only target reads no PR (no gh call)' '0' "$(wc -l < "$PS_GH_LOG" | tr -d ' ')"

d="$(doc stalepr 'pool-disposition: HIMMEL-102 close PR 5001 merged')"
check 'a target naming a merged PR reports it stale' '1:HIMMEL-102' "$(field pool-stale "$d")"
d="$(doc stalepr2 'pool-disposition: HIMMEL-102 question waits on PR #5001 (HIMMEL-901)')"
check 'every named blocker Done or merged (PR # form and a key) reports stale' '1:HIMMEL-102' "$(field pool-stale "$d")"

: > "$PS_GH_LOG"
d="$(doc quiet \
    'pool-disposition: HIMMEL-103 question waits on PR 5002' \
    'pool-disposition: HIMMEL-104 question waits on HIMMEL-902' \
    'pool-disposition: HIMMEL-106 question operator decision 268' \
    'pool-disposition: HIMMEL-107 question waits on PR 5002 and HIMMEL-901' \
    'pool-disposition: HIMMEL-108 question waits on PR 5004')"
check 'open or closed-unmerged targets, a still-open co-blocker and a ref-less target stay quiet' '0' "$(field pool-stale "$d")"
check 'one batched gh read serves all PR targets' '1' "$(wc -l < "$PS_GH_LOG" | tr -d ' ')"

d="$(doc prlist 'pool-disposition: HIMMEL-117 question waits on PR 5001 and 5002, HIMMEL-901')"
check 'every PR of a blocker list counts: a merged first PR and a still-open second stay quiet' '0' "$(field pool-stale "$d")"

d="$(doc unreadkey 'pool-disposition: HIMMEL-105 question waits on HIMMEL-999')"
check 'a key target missing from the mirror prints ?, never stale' '?' "$(field pool-stale "$d")"
d="$(doc unreadpr 'pool-disposition: HIMMEL-109 question waits on PR 7777')"
check 'a PR the batch read does not list prints ?' '?' "$(field pool-stale "$d")"
: > "$PS_GH_FAIL"
d="$(doc ghfail 'pool-disposition: HIMMEL-102 close PR 5001')"
check 'a failed gh read prints ?, never stale' '?' "$(field pool-stale "$d")"
d="$(doc ghfailkey 'pool-disposition: HIMMEL-101 slice HIMMEL-901')"
check 'a failed gh read does not touch a key-only stale target' '1:HIMMEL-101' "$(field pool-stale "$d")"
rm -f "$PS_GH_FAIL"

d="$(doc mixed 'pool-disposition: HIMMEL-101 slice HIMMEL-901' 'pool-disposition: HIMMEL-105 question waits on HIMMEL-999' 'pool-disposition: HIMMEL-102 close PR 5001')"
check 'stale keys are named and an unreadable target adds ?' '2:HIMMEL-101,HIMMEL-102,?' "$(field pool-stale "$d")"
before="$(cat "$d")"
field pool-stale "$d" > /dev/null
check 'the chief doc is never rewritten' "$before" "$(cat "$d")"

d="$(doc none 'priority: 110')"
check 'a doc with no pool-disposition line reports 0' '0' "$(field pool-stale "$d")"
check 'no doc reports skip' 'skip' "$(TOKEN='' bash "$SUT" --pool-stale 2>/dev/null | sed -n 's/^pool-stale=//p')"
check 'no Jira mirror reports skip' 'skip' "$(NEXT_DISPATCH_MIRROR="$WORK/no-such-mirror" TOKEN='' bash "$SUT" --pool-stale --doc "$d" 2>/dev/null | sed -n 's/^pool-stale=//p')"

check 'an open unversioned residual of an open focus-version ticket is counted' '1:HIMMEL-111' "$(field residual-unversioned "$d")"
rm -f "$M/HIMMEL-111.md"
check 'a versioned, Done, closed-parent or unlabeled ticket is not an unversioned residual' '0' "$(field residual-unversioned "$d")"
check 'no mirror reports residual-unversioned=skip' 'skip' "$(NEXT_DISPATCH_MIRROR="$WORK/no-such-mirror" TOKEN='' bash "$SUT" --pool-stale --doc "$d" 2>/dev/null | sed -n 's/^residual-unversioned=//p')"

mk 115 "To Do" "To Do" '[]' '["other", "residual-depth-1"]' '["relates to HIMMEL-110"]'
check 'a label list with spaces after the commas still counts the residual' '1:HIMMEL-115' "$(field residual-unversioned "$d")"

d="$(doc rerule 'pool-disposition: HIMMEL-101 slice HIMMEL-901' 'pool-disposition: HIMMEL-101 question waits on HIMMEL-902')"
check 'a later disposition of the same key supersedes an older stale one' '0' "$(field pool-stale "$d")"
d="$(doc rerule2 'pool-disposition: HIMMEL-101 question waits on HIMMEL-902' 'pool-disposition: HIMMEL-101 slice HIMMEL-901')"
check 'the later of two dispositions decides: an older open one does not mask a stale one' '1:HIMMEL-101' "$(field pool-stale "$d")"
d="$(doc rerule3 'pool-disposition: HIMMEL-101 slice HIMMEL-901' 'pool-disposition: HIMMEL-101 question operator decision 268')"
check 'a later ref-less disposition of the same key supersedes an older stale one' '0' "$(field pool-stale "$d")"

printf '\n%d failure(s)\n' "$fails"
[ "$fails" -eq 0 ]
