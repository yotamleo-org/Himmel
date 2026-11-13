#!/usr/bin/env bash
# test-tick-pool-stale.sh — tick.sh --pool-stale re-checks every Live-state
# `pool-disposition:` line whose target names a ticket key or `PR <n>` and reports
# pool-stale=<n>:<KEY>,... when every named blocker is Done or merged (`?` for an unreadable
# target, never stale; a still-open target stays quiet), and residual-unversioned=<n>:<KEY>,...
# for open residuals of open focus-version tickets that carry no fixVersion, leaving out a To Do
# ticket below High whose last release ruling is its own BACKLOG (or a MOVE to backlog). Fixture mirror and
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
mk() { # <num> <status> <statusCategory> <fixVersions json> <labels json> <relates json> [priority, default Medium]
    printf -- '---\nkey: "HIMMEL-%s"\ntype: "Task"\nstatus: "%s"\nstatusCategory: "%s"\npriority: "%s"\nlabels: %s\nfixVersions: %s\nparent: null\nlinks:\n  blocks: []\n  blocked_by: []\n  relates: %s\n---\n\n# HIMMEL-%s: t\n\n## Description\n\nbody\n' \
        "$1" "$2" "$3" "${7:-Medium}" "$5" "$4" "$6" "$1" > "$M/HIMMEL-$1.md"
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
printf '%s NMF=%s\n' "$*" "${GH_READ_NO_MAIN_FALLBACK:-}" >> "$PS_GH_LOG"
[ ! -f "$PS_GH_FAIL" ] || exit 1
case "$*" in
    *"api graphql"*)
        [ ! -f "$PS_GH_REPO_NULL" ] || { printf '{"data":{"repository":null}}\n'; exit 0; }
        out=""; nf=""
        for n in $(printf '%s\n' "$*" | grep -oE 'issueOrPullRequest\(number:[0-9]+\)' | grep -oE '[0-9]+'); do
            case "$n" in
                5001|999002|99999|4919|4943|5171) v='{"__typename":"PullRequest","state":"MERGED"}' ;;
                5002) v='{"__typename":"PullRequest","state":"OPEN"}' ;;
                5004|999001|4761) v='{"__typename":"PullRequest","state":"CLOSED"}' ;;
                999005) v='{"__typename":"Issue","state":"OPEN"}' ;;
                *) v=null; nf="$n" ;;
            esac
            out="${out:+$out,}\"p$n\":$v"
        done
        if [ -n "$nf" ]; then
            printf '{"data":{"repository":{%s}},"errors":[{"type":"NOT_FOUND"}]}\n' "$out"
            printf 'gh: Could not resolve to an issue or pull request with the number of %s.\n' "$nf" >&2
            exit 1
        fi
        printf '{"data":{"repository":{%s}}}\n' "$out" ;;
    *) printf '5001\tMERGED\n5002\tOPEN\n5004\tCLOSED\n' ;;
esac
EOF
chmod +x "$WORK/gh"
export PS_GH_LOG="$WORK/gh.log" PS_GH_FAIL="$WORK/gh.fail" PS_GH_REPO_NULL="$WORK/gh.reponull" NEXT_DISPATCH_MIRROR="$M" TICK_GH_CMD="$WORK/gh" HIMMEL_QUOTA_DIR="$WORK/quota"

doc() { # <name> <disposition line>...: a chief doc whose Live state holds those lines
    local f="$WORK/$1.md"; shift
    { printf '# chief\n\n## Live state\n'; for l in "$@"; do printf '%s\n' "$l"; done; printf '\n## Results\npool-disposition: HIMMEL-120 slice HIMMEL-901 outside the live state\n'; } > "$f"
    printf '%s' "$f"
}
pd='pool-disposition:'
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
    'pool-disposition: HIMMEL-107 question waits on PR 5002 and HIMMEL-901')"
check 'open targets, a still-open co-blocker and a ref-less target stay quiet' '0' "$(field pool-stale "$d")"
check 'one batched gh read serves all PR targets' '1' "$(wc -l < "$PS_GH_LOG" | tr -d ' ')"
l="$pd HIMMEL-108 question waits on PR 5004"; d="$(doc closedpr "$l")"
check 'a target naming a closed-unmerged PR reports it stale: its cause is gone' '1:HIMMEL-108' "$(field pool-stale "$d")"

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

out() { TOKEN='' bash "$SUT" --pool-stale --doc "$1" 2>/dev/null; }
l="$pd HIMMEL-131 question after PR #999001 the doctor edit, ZZ 11-09"; d="$(doc r1 "$l")"
check 'R1 a PR the old list does not return is judged' '1:HIMMEL-131' "$(field pool-stale "$d")"
p='^STALE-DISPOSITION HIMMEL-131 line=[0-9a-f]\{12\} PR#999001=CLOSED$'
check 'R1 its detail line names the PR and its state' 1 "$(out "$d" | grep -c "$p")"
l="$pd HIMMEL-132 question after HIMMEL-901 drafted in ZA-1, ZZ 11-11"; d="$(doc r2 "$l")"
check 'R2 a wave label is text, not a ticket' '1:HIMMEL-132' "$(field pool-stale "$d")"
p='^STALE-DISPOSITION HIMMEL-132 line=[0-9a-f]\{12\} HIMMEL-901=Done$'
check 'R2 its detail line names only the project key' 1 "$(out "$d" | grep -c "$p")"
l="$pd HIMMEL-133 question waits on PR 999777"; l2="$pd HIMMEL-134 question waits on PR 999001"; d="$(doc r3 "$l" "$l2")"
check 'R3 a gh exit 1 with partial data still judges the other PRs' '1:HIMMEL-134,?' "$(field pool-stale "$d")"
l="$pd HIMMEL-135 question waits on PR 999005"; d="$(doc r3b "$l")"
check 'R3b an issue number reads ?, never stale' '?' "$(field pool-stale "$d")"
: > "$PS_GH_REPO_NULL"
l="$pd HIMMEL-131 question after PR #999001"; d="$(doc r3c "$l")"
r3c="$(TOKEN='' bash "$SUT" --pool-stale --doc "$d" 2>/dev/null)"; r3c_rc=$?
check 'R3c a null repository reads every PR ?' '?' "$(printf '%s\n' "$r3c" | sed -n 's/^pool-stale=//p')"
check 'R3c the run still prints residual-unversioned= and exits 0' '1 0' "$(printf '%s\n' "$r3c" | grep -c '^residual-unversioned=') $r3c_rc"
rm -f "$PS_GH_REPO_NULL"
: > "$PS_GH_LOG"
l="$pd HIMMEL-137 question waits on PR #999001"; l2="$pd HIMMEL-138 question waits on PR #999001 and #999002"; d="$(doc r4 "$l" "$l2")"
field pool-stale "$d" > /dev/null
check 'R4 one query names every PR once' '1' "$(wc -l < "$PS_GH_LOG" | tr -d ' ')"
check 'R4 the query names each PR alias once' '1 1' "$(grep -o 'p999001:' "$PS_GH_LOG" | wc -l | tr -d ' ') $(grep -o 'p999002:' "$PS_GH_LOG" | wc -l | tr -d ' ')"
# shellcheck disable=SC2016  # $owner and $name are literal GraphQL variable names, not shell expansions
p='-F owner={owner} -F name={repo} .*query(\$owner:String!,\$name:String!)'
check 'R4 owner and repo travel as gh placeholders and query variables' 1 "$(grep -c -- "$p" "$PS_GH_LOG")"
check 'R4 the read never falls back to the main token on a rate limit' 1 "$(grep -c 'NMF=1$' "$PS_GH_LOG")"
v5='HIMMEL-136 question waits on PR #999002 and #99999, after HIMMEL-901'
h5="$(printf '%s' "$v5" | sha256sum | cut -c1-12)"
d="$(doc r5 "$pd $v5")"
check 'R5 the detail line names every target, numerically sorted, with the line hash' "STALE-DISPOSITION HIMMEL-136 line=$h5 HIMMEL-901=Done PR#99999=MERGED PR#999002=MERGED" "$(out "$d" | grep '^STALE-DISPOSITION')"

RB="$WORK/routerbin"; mkdir -p "$RB" "$WORK/envroot" "$WORK/rhome" "$WORK/rcfg"
printf 'himmel_github_token_vm2=dummyreadtoken\n' > "$WORK/envroot/.env"
cat > "$RB/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s TOKEN=%s\n' "$*" "${GH_TOKEN:-}" >> "$PS_ROUTER_LOG"
printf '{"data":{"repository":{"p999777":null}},"errors":[{"type":"NOT_FOUND"}]}\n'
if [ -n "${PS_ROUTER_PRSHAPE:-}" ]; then
    printf 'gh: Could not resolve to a PullRequest with the number of 999777.\n' >&2
else
    printf 'gh: Could not resolve to an issue or pull request with the number of 999777.\n' >&2
fi
exit 1
EOF
chmod +x "$RB/gh"
export PS_ROUTER_LOG="$WORK/router.log"
rt() {
    (
        unset GH_TOKEN GITHUB_TOKEN himmel_github_token_vm2 CREDENTIALS_DIRECTORY GH_READ_QUIET GH_READ_OFF
        PATH="$RB:$PATH" GH_READ_ENV_ROOT="$WORK/envroot" HOME="$WORK/rhome" GH_CONFIG_DIR="$WORK/rcfg" \
            HIMMEL_SECRETS_KEYRING=off HIMMEL_CONFIG_DIR="$WORK/rcfg" TICK_GH_CMD='' TOKEN='' "$@"
    )
}
l="$pd HIMMEL-139 question waits on PR 999777"; d="$(doc r6 "$l")"
: > "$PS_ROUTER_LOG"
r6="$(rt bash "$SUT" --pool-stale --doc "$d" 2>/dev/null | sed -n 's/^pool-stale=//p')"
check 'R6 a NOT_FOUND number through the router makes one call' '1' "$(wc -l < "$PS_ROUTER_LOG" | tr -d ' ')"
check 'R6 that call rides the read token' 1 "$(grep -c 'TOKEN=dummyreadtoken$' "$PS_ROUTER_LOG")"
check 'R6 the call is an api graphql query for the issueOrPullRequest alias' 1 "$(grep -c '^api graphql .*p999777:issueOrPullRequest(number:999777)' "$PS_ROUTER_LOG")"
check 'R6 the unread PR reads ?' '?' "$r6"
: > "$PS_ROUTER_LOG"
rt env PS_ROUTER_PRSHAPE=1 bash "$HERE/../../lib/gh-read.sh" api graphql -f 'query=query{repository(owner:"o",name:"r"){p999777:pullRequest(number:999777){state}}}' > /dev/null 2>&1
check 'R6c the router retries a pullRequest NOT_FOUND on the main token (why D1 asks for issueOrPullRequest)' '2 TOKEN=' "$(wc -l < "$PS_ROUTER_LOG" | tr -d ' ') $(sed -n '2s/.* \(TOKEN=.*\)$/\1/p' "$PS_ROUTER_LOG")"
r6d="$(rt env PS_ROUTER_PRSHAPE=1 bash "$SUT" --pool-stale --doc "$d" 2>&1 >/dev/null)"
check 'R6d a router warning reaches the tick stderr' 1 "$(printf '%s\n' "$r6d" | grep -c '^gh-read: read token refused')"

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

# a release-manager ruling that puts a versionless residual in the backlog (outcome BACKLOG, or a MOVE to
# backlog) is a placement, not an unversioned ticket. The last [release-ruling ...] comment of the ticket
# decides, and only a ruling of the ticket's own key under the Comments heading counts.
rl() { # <R-id> <verb> <key num> <op> <from>-<to> <outcome> <class>: one ruling comment line, as the writer emits it
    printf '[release-ruling %s] RULING %s Q-v1.1.3-0001 %s HIMMEL-%s %s %s %s %s sector=Quality & proof — defer:test: RM ruling.\nAuthority: rm. Audit copy; the release ledger is the record.\n' "$1" "$1" "$2" "$3" "$4" "$5" "$6" "$7"
}
rr() { # <ticket num> <rl args>: append a ruling comment to a mirror ticket
    local n="$1" f head=''; shift
    f="$M/HIMMEL-$n.md"
    grep -q '^## Comments' "$f" || head='
## Comments
'
    { printf '%s' "$head"; printf '\n### Yotam Leopold — 2026-11-05T17:28:32.880+0100\n\n'; rl "$@"; } >> "$f"
}
res() { mk "$1" "To Do" "To Do" '[]' '["residual","residual-depth-1"]' '["relates to HIMMEL-110"]'; }
res 118; rr 118 R-v1.1.3-0002 INTAKE 118 none backlog→backlog BACKLOG backlog
check 'a BACKLOG-ruled versionless residual is not counted' '1:HIMMEL-115' "$(field residual-unversioned "$d")"
res 119; rr 119 R-v1.1.3-0003 INTAKE 119 none backlog→backlog BACKLOG backlog
check 'a second BACKLOG-ruled ticket is not counted either' '1:HIMMEL-115' "$(field residual-unversioned "$d")"
rr 119 R-v1.1.3-0004 INTAKE 119 add backlog→v1.1.3 ADMIT current
check 'a later ADMIT ruling reopens the count: only the latest ruling decides' '2:HIMMEL-115,HIMMEL-119' "$(field residual-unversioned "$d")"
res 121; rr 121 R-v1.1.3-0005 REVERSION 121 remove v1.1.4→backlog MOVE backlog
check 'a ticket moved to the backlog by a ruling is not counted' '2:HIMMEL-115,HIMMEL-119' "$(field residual-unversioned "$d")"
res 122; rr 122 R-v1.1.3-0006 DISCHARGE 122 none backlog→backlog REJECT backlog
check 'a DISCHARGE REJECT that carries class backlog places nothing: the ticket is counted' '3:HIMMEL-115,HIMMEL-119,HIMMEL-122' "$(field residual-unversioned "$d")"
res 123; rr 123 R-v1.1.3-0007 INTAKE 123 none backlog→backlog AD-HOC backlog
check 'an AD-HOC ruling that carries class backlog places nothing: the ticket is counted' '4:HIMMEL-115,HIMMEL-119,HIMMEL-122,HIMMEL-123' "$(field residual-unversioned "$d")"
res 124; rr 124 R-v1.1.3-0008 INTAKE 999 none backlog→backlog BACKLOG backlog
check "a ruling line quoting another ticket's BACKLOG ruling does not hide this ticket" '5:HIMMEL-115,HIMMEL-119,HIMMEL-122,HIMMEL-123,HIMMEL-124' "$(field residual-unversioned "$d")"
res 125; { printf '\n'; rl R-v1.1.3-0009 INTAKE 125 none backlog→backlog BACKLOG backlog; } >> "$M/HIMMEL-125.md"
check 'a ruling line in the description, above any Comments heading, does not hide the ticket' '6:HIMMEL-115,HIMMEL-119,HIMMEL-122,HIMMEL-123,HIMMEL-124,HIMMEL-125' "$(field residual-unversioned "$d")"
res 126; rr 126 R-v1.1.3-0010 INTAKE 126 none backlog→backlog BACKLOG backlog
check 'an older BACKLOG ruling hides the ticket' '6:HIMMEL-115,HIMMEL-119,HIMMEL-122,HIMMEL-123,HIMMEL-124,HIMMEL-125' "$(field residual-unversioned "$d")"
printf '\n### Yotam Leopold — 2026-11-05T18:00:00.000+0100\n\n[release-ruling R-v1.1.3-0011] RULING garbage\n' >> "$M/HIMMEL-126.md"
check 'a malformed latest ruling line keeps the ticket counted over an older BACKLOG ruling' '7:HIMMEL-115,HIMMEL-119,HIMMEL-122,HIMMEL-123,HIMMEL-124,HIMMEL-125,HIMMEL-126' "$(field residual-unversioned "$d")"
list7='7:HIMMEL-115,HIMMEL-119,HIMMEL-122,HIMMEL-123,HIMMEL-124,HIMMEL-125,HIMMEL-126'
# only a To Do ticket below High is hidden: one in progress or at High or above is still owed a version
mk 127 "In Progress" "In Progress" '[]' '["residual","residual-depth-1"]' '["relates to HIMMEL-110"]'; rr 127 R-v1.1.3-0012 INTAKE 127 none backlog→backlog BACKLOG backlog
check 'a BACKLOG-ruled ticket that is now in progress stays counted' "8:${list7#7:},HIMMEL-127" "$(field residual-unversioned "$d")"
mk 128 "To Do" "To Do" '[]' '["residual","residual-depth-1"]' '["relates to HIMMEL-110"]' High; rr 128 R-v1.1.3-0013 INTAKE 128 none backlog→backlog BACKLOG backlog
check 'a BACKLOG-ruled To Do ticket of priority High stays counted' "9:${list7#7:},HIMMEL-127,HIMMEL-128" "$(field residual-unversioned "$d")"
mk 129 "To Do" "To Do" '[]' '["residual","residual-depth-1"]' '["relates to HIMMEL-110"]' Highest; rr 129 R-v1.1.3-0014 INTAKE 129 none backlog→backlog BACKLOG backlog
check 'a BACKLOG-ruled To Do ticket of priority Highest stays counted' "10:${list7#7:},HIMMEL-127,HIMMEL-128,HIMMEL-129" "$(field residual-unversioned "$d")"
# a MOVE into a version places the ticket in that version, not in the backlog
mk 130 "To Do" "To Do" '[]' '["residual","residual-depth-1"]' '["relates to HIMMEL-110"]'; rr 130 R-v1.1.3-0015 REVERSION 130 move backlog→v1.1.4 MOVE v1.1.4
check 'a last ruling that MOVEs the ticket into a version does not hide it' "11:${list7#7:},HIMMEL-127,HIMMEL-128,HIMMEL-129,HIMMEL-130" "$(field residual-unversioned "$d")"
rm -f "$M"/HIMMEL-118.md "$M"/HIMMEL-119.md "$M"/HIMMEL-12[1-9].md "$M"/HIMMEL-130.md

d="$(doc rerule 'pool-disposition: HIMMEL-101 slice HIMMEL-901' 'pool-disposition: HIMMEL-101 question waits on HIMMEL-902')"
check 'a later disposition of the same key supersedes an older stale one' '0' "$(field pool-stale "$d")"
d="$(doc rerule2 'pool-disposition: HIMMEL-101 question waits on HIMMEL-902' 'pool-disposition: HIMMEL-101 slice HIMMEL-901')"
check 'the later of two dispositions decides: an older open one does not mask a stale one' '1:HIMMEL-101' "$(field pool-stale "$d")"
d="$(doc rerule3 'pool-disposition: HIMMEL-101 slice HIMMEL-901' 'pool-disposition: HIMMEL-101 question operator decision 268')"
check 'a later ref-less disposition of the same key supersedes an older stale one' '0' "$(field pool-stale "$d")"

# a disposition carries the head sha it was ruled at (`@<sha>`); one more than TICK_POOL_MAX_MERGES
# commits behind main is stale though its named blocker is still open, so a copied-forward hold expires
R="$WORK/repo"; git init -q "$R"
for n in 1 2 3 4 5; do git -C "$R" -c user.name=t -c user.email=t@t commit -q --allow-empty -m "c$n"; done
old="$(git -C "$R" rev-parse --short=10 HEAD~4)"; young="$(git -C "$R" rev-parse --short=10 HEAD~1)"
afield() { TOKEN='' TICK_POOL_MAX_MERGES=3 bash "$SUT" --pool-stale --doc "$2" --repo "$R" 2>/dev/null | sed -n "s/^$1=//p"; }
l="$pd HIMMEL-120 question waits on HIMMEL-902 @$old"; d="$(doc aged "$l")"
check 'a disposition ruled 4 merges ago is stale though its blocker is open' '1:HIMMEL-120' "$(afield pool-stale "$d")"
l="$pd HIMMEL-120 question waits on HIMMEL-902 @$young"; d="$(doc young "$l")"
check 'a disposition ruled 1 merge ago stays quiet' '0' "$(afield pool-stale "$d")"
l="$pd HIMMEL-121 question operator decision 268 @$old"; d="$(doc agedbare "$l")"
check 'a ref-less disposition ruled long ago is stale too' '1:HIMMEL-121' "$(afield pool-stale "$d")"
l="$pd HIMMEL-120 question waits on HIMMEL-902 @deadbeef01"; d="$(doc unknownsha "$l")"
check 'a sha the repo does not know prints ?, never stale' '?' "$(afield pool-stale "$d")"
l="$pd HIMMEL-101 slice HIMMEL-901 @deadbeef01"; d="$(doc unknownshadone "$l")"
check 'an unknown sha leaves a line with only Done blockers unjudged: ?, not stale' '?' "$(afield pool-stale "$d")"

# changed (spec D5): a line whose open parent merged a slice after the line's anchor (its @sha commit
# time or its newest chief stamp, whichever is later) reads changed. Every doc is named with the
# reference date the stamp's year comes from; the fixture repo's commit dates are set to the minute.
export TICK_STATE_DIR="$WORK/state"
GR="$WORK/grepo"; mkdir -p "$WORK/notarepo"
gnew() { rm -rf "$GR"; git init -q "$GR"; }
gc() { # <ISO instant> <subject>: one first-parent commit dated then; prints its short sha
    GIT_COMMITTER_DATE="$1" GIT_AUTHOR_DATE="$1" git -C "$GR" -c user.name=t -c user.email=t@t commit -q --allow-empty -m "$2" && git -C "$GR" rev-parse --short HEAD
}
cout() { TOKEN='' bash "$SUT" --pool-stale --doc "$1" --repo "${2:-$GR}" ${3:+--prior "$3"} 2>/dev/null; }  # <doc> [repo] [prior]
ofield() { printf '%s\n' "$2" | sed -n "s/^$1=//p"; }
named() { printf '%s\n' "$3" | sed -n "s/^$2=//p" | tr ':' ',' | tr ',' '\n' | grep -c "^$1\$"; }  # <key> <field> <output>: 1 when the field names the key
hash12() { printf '%s' "$1" | sha256sum | cut -c1-12; }

gnew
c1="$(gc 2026-11-08T10:00:00Z 'base')"
sub2='[HIMMEL-902] B1 the first slice'; sub3='[HIMMEL-902] B2 the second slice'
c2="$(gc 2026-11-09T12:00:00Z "$sub2")"
c3="$(gc 2026-11-09T15:00:00Z "$sub3")"
v10="HIMMEL-151 question after HIMMEL-902 its B1 slice @$c1"
d10="$(doc HIMMEL-nextleg-2026-11-10ZZ-r10 "$pd $v10")"
o10="$(cout "$d10")"
check 'R10 an open parent merged since @sha reads changed' '1:HIMMEL-151' "$(ofield pool-changed "$o10")"
check 'R10 the detail line names every target, the first merge since the anchor and the newest' \
    "CHANGED-DISPOSITION HIMMEL-151 line=$(hash12 "$v10") HIMMEL-902=open @$c1=2-behind since $c2 via HIMMEL-902 $c3 [HIMMEL-902] B2 the second slice" \
    "$(printf '%s\n' "$o10" | grep '^CHANGED-DISPOSITION')"
check 'R10 a changed line is not stale' '0' "$(ofield pool-stale "$o10")"

printf '%s\n' "$o10" > "$WORK/r19.prior"
o19="$(cout "$d10" "$WORK/notarepo" "$WORK/r19.prior")"
check 'R19 a changed verdict survives a failed git read' "$(printf '%s\n' "$o10" | grep '^CHANGED-DISPOSITION') carried" "$(printf '%s\n' "$o19" | grep '^CHANGED-DISPOSITION')"
check 'R19 the carried key stays in the field beside ?' '1:HIMMEL-151,?' "$(ofield pool-changed "$o19")"
mk 902 "Done" Done '["v1.1.3"]' '[]' '[]'
check 'R19 control: a Done parent releases the changed verdict' 0 "$(cout "$d10" "$WORK/notarepo" "$WORK/r19.prior" | grep -c '^CHANGED-DISPOSITION')"
mk 902 "In Progress" "In Progress" '["v1.1.3"]' '[]' '[]'
d19="$(doc HIMMEL-nextleg-2026-11-10ZZ-r19 "$pd $v10 edited")"
check 'R19 control: an edited line releases it too' 0 "$(cout "$d19" "$WORK/notarepo" "$WORK/r19.prior" | grep -c '^CHANGED-DISPOSITION')"

v11="HIMMEL-152 question after HIMMEL-902 the rest (ZZ 11-08)"
check 'R11 a date stamp anchors an unstamped line' '1:HIMMEL-152' "$(ofield pool-changed "$(cout "$(doc HIMMEL-nextleg-2026-11-10ZZ-r11 "$pd $v11")")")"
v12="$v11 (ZZ 11-09 15:01Z re-read)"
d12="$(doc HIMMEL-nextleg-2026-11-10ZZ-r12 "$pd $v12")"
check 'R12 a timed re-read stamp clears the line' '0' "$(ofield pool-changed "$(cout "$d12")")"
v12c="HIMMEL-151 question after HIMMEL-902 its B1 slice @$c3"
d12c="$(doc HIMMEL-nextleg-2026-11-10ZZ-r12c "$pd $v12c")"
for n in 1 2 3 4; do gc "2026-11-10T0$n:00:00Z" "other work $n" > /dev/null; done
o12b="$(TICK_POOL_MAX_MERGES=3 cout "$d12")"
check 'R12b a timed stamp never expires' '0 0' "$(named "${v12%% *}" pool-changed "$o12b") $(named "${v12%% *}" pool-stale "$o12b")"
o12c="$(TICK_POOL_MAX_MERGES=3 cout "$d12c")"
check 'R12c an @sha clear expires after TICK_POOL_MAX_MERGES (the cost of clearing with @sha)' '1:HIMMEL-151' "$(ofield pool-stale "$o12c")"
check 'R12c its detail line names the expired sha' "STALE-DISPOSITION HIMMEL-151 line=$(hash12 "$v12c") HIMMEL-902=open @$c3=4-behind" "$(printf '%s\n' "$o12c" | grep '^STALE-DISPOSITION')"

gnew
gc 2026-11-08T10:00:00Z 'base' > /dev/null
gc 2026-11-09T12:00:00Z '[HIMMEL-903] another key' > /dev/null
gc 2026-11-09T13:00:00Z '[HIMMEL-9022] a key that only starts the same' > /dev/null
v13="HIMMEL-153 question after HIMMEL-902 the rest (ZZ 11-08)"
o13="$(cout "$(doc HIMMEL-nextleg-2026-11-10ZZ-r13 "$pd $v13")")"
check 'R13 a merge naming another key does not count' '0 0' "$(named "${v13%% *}" pool-changed "$o13") $(named "${v13%% *}" pool-stale "$o13")"
v14="HIMMEL-154 question after HIMMEL-902 the rest (ZZ 11-08) @deadbee"
o14="$(cout "$(doc HIMMEL-nextleg-2026-11-10ZZ-r14 "$pd $v14")")"
check 'R14 an @sha git cannot read is not changed' '0 ?' "$(named HIMMEL-154 pool-changed "$o14") $(ofield pool-stale "$o14")"

gnew
gc 2026-11-08T10:00:00Z 'base' > /dev/null
gc 2026-11-09T12:00:00Z '[HIMMEL-902] B1 the first slice' > /dev/null
v16="HIMMEL-155 question after HIMMEL-902 the rest (ZZ 11-09)"
d16="$(doc HIMMEL-nextleg-2026-11-10ZZ-r16 "$pd $v16")"
touch -d 2027-11-10T12:00:00Z "$d16"  # gnu-ok: chief kit is Linux-only; the mtime a year on would read 2027-11-09, after the merge
check 'R16 the reference date comes from the doc file name' '1:HIMMEL-155' "$(ofield pool-changed "$(cout "$d16")")"

gnew
gc 2026-12-20T10:00:00Z 'base' > /dev/null
gc 2026-12-31T12:00:00Z '[HIMMEL-902] B1 the first slice' > /dev/null
v17="HIMMEL-156 question after HIMMEL-902 the rest (ZZ 12-30)"
check 'R17 a stamp month after the reference month is last year' '1:HIMMEL-156' "$(ofield pool-changed "$(cout "$(doc HIMMEL-nextleg-2027-01-02ZZ-r17 "$pd $v17")")")"

gnew
gc 2025-11-08T10:00:00Z 'base' > /dev/null
gc 2025-11-09T12:00:00Z '[HIMMEL-902] B1 the first slice' > /dev/null
v18="HIMMEL-157 question after HIMMEL-902 the rest (ZZ 11-09)"
d18="$(doc plain "$pd $v18")"
touch -d 2025-11-10T12:00:00Z "$d18"  # gnu-ok: chief kit is Linux-only; today's date as the reference would read 2026-11-09, after the merge
check 'R18 an undated doc name falls back to the doc mtime' '1:HIMMEL-157' "$(ofield pool-changed "$(cout "$d18")")"

# DoD-2 frozen replay: the YO doc's pool-disposition lines 170, 181, 197, 204, 215, 230 and 232
# verbatim (HIMMEL-nextleg-2026-11-10YO-roadmap-chief.md), against the PR states and merges of that
# evening. The stub serves the real PR numbers; the one edited token is 9622's @6eb44fbbe, which
# names the stand-in commit of the fixture history in its place.
mk 9137 "In Progress" "In Progress" '["v1.1.3"]' '[]' '[]'
mk 9564 "In Progress" "In Progress" '["v1.1.3"]' '[]' '[]'
gnew
gc 2026-11-10T17:54:00Z '[HIMMEL-9137] T6a the slice B remainder' > /dev/null
standin="$(gc 2026-11-10T19:03:00Z 'the stand-in for 6eb44fbbe')"
gc 2026-11-10T21:45:00Z '[HIMMEL-9564] B1 the release.ts slice' > /dev/null
dyo="$(doc HIMMEL-nextleg-2026-11-10YO-replay \
    "pool-disposition: HIMMEL-7644 question after PR #4761 doctor C52 edit in scripts/himmel-doctor.sh is held by it, and the live auto-lane run with account B's key dead is chief-run (PRs #4919 and #4943 merged) (XA 11-09)" \
    "pool-disposition: HIMMEL-9077 question after HIMMEL-9137 slice B remainder (T6a) is carried by 9137's plan tasks and its held files headed-arm-worker.sh and graphmap-cadence.sh (XA 11-09)" \
    'pool-disposition: HIMMEL-9487 slice decision 878 public-text slice for docs/setup/operator-profile-tbd-delta.md (doctor printed text waits on PR #4761); Writes docs/setup/operator-profile-tbd-delta.md; opus (XA 11-09)' \
    "pool-disposition: HIMMEL-9622 question after HIMMEL-9564 release.ts edit follows 9564 (In Progress, B1 live under N5765f, committed 39cf0a0d5); tick.sh also held by PR 5171 (N5810) (YH 11-10 re-read: blocker still open) @$standin" \
    'pool-disposition: HIMMEL-9448 slice decision 848 spec signed O-v1.1.3-0390 (specs/plans/HIMMEL-9448-adopter-graph-choices.md); XB files the build slice tickets and dispatches them (XB 11-09)' \
    "pool-disposition: HIMMEL-9001 question after HIMMEL-9564 S1b writes scripts/jira/src/release/, in N5765's Writes (bypass go code owed) (XR 11-10)" \
    'pool-disposition: HIMMEL-8597 slice decision 870 worker N5770 config-audit half; doctor half after PR #4761 (XR wave 1) (XR 11-10)')"
: > "$PS_GH_LOG"
oyo="$(TICK_STATE_DIR="$WORK/st-replay" cout "$dyo" "$GR" "$WORK/st-replay/none.out")"
check 'DoD-2 replay: the closed-PR holds read stale' '3:HIMMEL-7644,HIMMEL-9487,HIMMEL-8597' "$(ofield pool-stale "$oyo")"
check 'DoD-2 replay: the holds whose parent merged since read changed' '3:HIMMEL-9077,HIMMEL-9622,HIMMEL-9001' "$(ofield pool-changed "$oyo")"
check 'DoD-2 replay: the stub served the real PR numbers (no live read)' '1 1 1 1' "$(grep -c 'p4761:' "$PS_GH_LOG") $(grep -c 'p4919:' "$PS_GH_LOG") $(grep -c 'p4943:' "$PS_GH_LOG") $(grep -c 'p5171:' "$PS_GH_LOG")"
syo="$(ofield '# stale-file' "$oyo")"
mkdir -p "$(dirname "${syo:-$WORK/none/x}")"; printf '%s\n' "$oyo" > "${syo:-$WORK/none/x}"
printf '# disposition HIMMEL-%s listed LOCAL\n' 7644 9077 9487 9622 9448 9001 8597 > "$WORK/yo.rows"
pyo="$(TICK_STATE_DIR="$WORK/st-replay" TOKEN='' bash "$SUT" --pool-dispositions --doc "$dyo" < "$WORK/yo.rows" 2>/dev/null)"
check 'DoD-2 replay: six keys count unresolved and 9448 stays disposed' '7/0/1/6' "$(printf '%s\n' "$pyo" | sed -n 's/^# pool-counts //p')"
check 'DoD-2 replay: three stale and three changed' 'changed HIMMEL-9001,changed HIMMEL-9077,changed HIMMEL-9622,stale HIMMEL-7644,stale HIMMEL-8597,stale HIMMEL-9487' \
    "$(printf '%s\n' "$pyo" | sed -n 's/^# pool-unresolved \([a-z]*\) \(HIMMEL-[0-9]*\) .*/\1 \2/p' | paste -sd, -)"

real_scripts="$(cd "$HERE/../.." && pwd)"
sk="$WORK/kit/scripts"; mkdir -p "$sk/handover/chief-kit"
for f in "$real_scripts"/*; do [ "${f##*/}" = handover ] || ln -s "$f" "$sk/${f##*/}"; done
for f in "$real_scripts"/handover/*; do [ "${f##*/}" = chief-kit ] || ln -s "$f" "$sk/handover/${f##*/}"; done
for f in "$HERE"/*; do ln -s "$f" "$sk/handover/chief-kit/${f##*/}"; done
rm "$sk/handover/chief-kit/next-dispatchable.sh" "$sk/handover/chief-kit/tick.sh"
ln -s "$SUT" "$sk/handover/chief-kit/tick.sh"
cat > "$sk/handover/chief-kit/next-dispatchable.sh" <<'EOF'
#!/usr/bin/env bash
case " $* " in *" --dispositions "*)
    # the parent is `timeout`; a bash is re-niced by some stations' ananicy rules, a timeout is not
    printf 'x\n' >> "$PS_LAUNCH_LOG"; ps -o ni= -p "$PPID" | tr -d ' ' >> "$PS_NICE_LOG"
    [ -z "${PS_FAIL:-}" ] || exit 1
    printf '# disposition HIMMEL-1 in-flight owned by worker N1\n' ;;
esac
EOF
pl_dir="$WORK/pl"; mkdir -p "$pl_dir/tss/workers"
pl_doc="$(doc pooldoc)"
pl_log="$pl_dir/launch.log"; pl_nice="$pl_dir/nice.log"
pl_tick() { TOKEN='' TICK_STATE_DIR="$pl_dir/state" TICKET_STATUS_STATE_DIR="$pl_dir/tss" HIMMEL_ADMISSIONS_LEDGER="$pl_dir/ledger.jsonl" PS_LAUNCH_LOG="$pl_log" PS_NICE_LOG="$pl_nice" bash "$sk/handover/chief-kit/tick.sh" --doc "$pl_doc" ${PL_WF:+--workers-from "$PL_WF"} 2>/dev/null; }
pl_n() { if [ -f "$pl_log" ]; then wc -l < "$pl_log" | tr -d ' '; else echo 0; fi; }
pl_rows() { find "$pl_dir/state" -name 'tick-pool-*.rows' 2>/dev/null; }
pl_age() { local r; r="$(pl_rows)"; [ -z "$r" ] || touch -d "$1" "$r"; }  # gnu-ok: chief kit is Linux-only
pl_fp() { cat "$pl_dir"/state/tick-pool-*.fp 2>/dev/null; }
pl_go() { pl_age '20 minutes ago'; pl_tick > /dev/null; check "$1" "$2" "$(pl_n)"; }  # <name> <launches so far>
printf '{"lastSync":"2026-11-01T00:00:00Z"}\n' > "$M/.cursor.json"
pl_tick > /dev/null
check 'the first tick launches a snapshot' 1 "$(pl_n)"
pl_go 'a second tick past the floor with unchanged inputs launches no second snapshot' 1
pl_age '2 hours ago'
pl_out="$(pl_tick)"
check 'an unchanged-input skip still serves the counts (the snapshot is kept fresh, not left to expire)' 1 "$(printf '%s\n' "$pl_out" | grep -c ' pool=[0-9]')"
printf '{"lastSync":"2026-11-01T00:10:00Z"}\n' > "$M/.cursor.json"
pl_go 'a mirror sync between two ticks launches the next snapshot' 2
touch "$pl_doc"
pl_go 'a changed chief doc launches a snapshot past the floor' 3
printf '%s\tZZTEST-7\t\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "${pl_doc%/*}/cloud-sessions.tsv"
pl_go 'a changed owner set (a cloud session now owns a key) launches a snapshot past the floor' 4
printf 'v1.1.3\ttrue\t\n' > "$WORK/mirror/HIMMEL.versions.tsv"
pl_go 'a changed versions table launches a snapshot past the floor' 5
printf '{"key":"ZZTEST-7"}\n' > "$pl_dir/tss/status-events.jsonl"
pl_go 'a new status-events row launches a snapshot past the floor' 6
printf '{"key":"ZZTEST-7"}\n' > "$pl_dir/ledger.jsonl"
pl_go 'a new admissions ledger row launches a snapshot past the floor' 7
printf '{}\n' > "$pl_dir/tss/workers/w1.json"
pl_go 'a new worker record launches a snapshot past the floor' 8
printf '{"schema":1,"workers":[]}\n' > "$pl_dir/fleet.json"; PL_WF="$pl_dir/fleet.json"
pl_go 'naming a fleet manifest launches a snapshot past the floor' 9
touch -d '3 minutes ago' "$PL_WF"
pl_go 'a changed fleet manifest mtime launches a snapshot past the floor' 10
pl_go 'unchanged inputs after that launch no snapshot' 10
touch -d '2026-11-01 00:05:00' "$pl_dir/ledger.jsonl"
pl_go 'a ledger touched to an older time launches a snapshot' 11
printf '{"key":"ZZTEST-8"}\n' >> "$pl_dir/ledger.jsonl"; touch -d '2026-11-01 00:05:00' "$pl_dir/ledger.jsonl"
pl_go 'an append that leaves the mtime unchanged but grows the file launches a snapshot' 12
pl_age '20 minutes ago'; touch -d '2 hours ago' "$pl_dir"/state/tick-pool-*.fp
pl_tick > /dev/null
check 'unchanged inputs launch a snapshot once the fingerprint is older than TICK_POOL_MAX_SKIP_SECS' 13 "$(pl_n)"
pl_fp_before="$(pl_fp)"
printf '{"lastSync":"2026-11-01T00:30:00Z"}\n' > "$M/.cursor.json"
pl_age '20 minutes ago'
PS_FAIL=1 pl_tick > /dev/null
check 'a changed input launches a snapshot even when that scan will fail' 14 "$(pl_n)"
check 'a failed scan records no fingerprint' "$pl_fp_before" "$(pl_fp)"
pl_go 'the next tick retries after a failed scan' 15
check 'the retried scan records the fingerprint' 1 "$([ "$(pl_fp)" != "$pl_fp_before" ] && echo 1 || echo 0)"
printf '{"lastSync":"2026-11-01T00:40:00Z"}\n' > "$M/.cursor.json"
pl_tick > /dev/null
check 'a changed input inside the floor still launches nothing' 15 "$(pl_n)"
pl_nice_want=$(( $(nice) + 10 )); [ "$pl_nice_want" -le 19 ] || pl_nice_want=19
check 'every launched snapshot runs at nice +10' "$pl_nice_want" "$(sort -u "$pl_nice")"

printf '\n%d failure(s)\n' "$fails"
[ "$fails" -eq 0 ]
