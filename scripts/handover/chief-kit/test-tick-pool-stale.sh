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
KP=HIMMEL
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
export JIRA_PROJECT_KEY=HIMMEL
export PS_GH_LOG="$WORK/gh.log" PS_GH_FAIL="$WORK/gh.fail" PS_GH_REPO_NULL="$WORK/gh.reponull" NEXT_DISPATCH_MIRROR="$M" TICK_GH_CMD="$WORK/gh" HIMMEL_QUOTA_DIR="$WORK/quota"
mkdir -p "$WORK/state" "$WORK/no-release-declared"
export TICK_STATE_DIR="$WORK/state" HIMMEL_RELEASE_STATE_DIR="$WORK/no-release-declared" PS_REAL_SUT="$SUT"
cat > "$WORK/tick-chain.sh" <<'EOF'
#!/usr/bin/env bash
doc="" repo="" prev=""
for a in "$@"; do case "$prev" in --doc) doc="$a" ;; --repo) repo="$a" ;; esac; prev="$a"; done
case " $* " in *" --pool-stale "*) [ -z "$doc" ] || bash "$PS_REAL_SUT" --pool-holds --doc "$doc" ${repo:+--repo "$repo"} > /dev/null ;; esac
exec bash "$PS_REAL_SUT" "$@"
EOF
chmod +x "$WORK/tick-chain.sh"
SUT="$WORK/tick-chain.sh"

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
d="$(doc stalekey "pool-disposition: $KP-101 slice $KP-901 then the rest")"
check 'a target naming a Done ticket reports it stale' '1:HIMMEL-101' "$(field pool-stale "$d")"
check 'a ticket-only target reads no PR (no gh call)' '0' "$(wc -l < "$PS_GH_LOG" | tr -d ' ')"

d="$(doc stalepr "pool-disposition: $KP-102 close PR 5001 merged")"
check 'a target naming a merged PR reports it stale' '1:HIMMEL-102' "$(field pool-stale "$d")"
d="$(doc stalepr2 "pool-disposition: $KP-102 question waits on PR #5001 ($KP-901)")"
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

d="$(doc prlist "pool-disposition: $KP-117 question waits on PR 5001 and 5002, $KP-901")"
check 'every PR of a blocker list counts: a merged first PR and a still-open second stay quiet' '0' "$(field pool-stale "$d")"

d="$(doc unreadkey "pool-disposition: $KP-105 question waits on $KP-999")"
check 'a key target missing from the mirror prints ?, never stale' '?' "$(field pool-stale "$d")"
d="$(doc unreadpr "pool-disposition: $KP-109 question waits on PR 7777")"
check 'a PR the batch read does not list prints ?' '?' "$(field pool-stale "$d")"
: > "$PS_GH_FAIL"
d="$(doc ghfail "pool-disposition: $KP-102 close PR 5001")"
check 'a failed gh read prints ?, never stale' '?' "$(field pool-stale "$d")"
d="$(doc ghfailkey "pool-disposition: $KP-101 slice $KP-901")"
check 'a failed gh read does not touch a key-only stale target' '1:HIMMEL-101' "$(field pool-stale "$d")"
rm -f "$PS_GH_FAIL"

d="$(doc mixed "pool-disposition: $KP-101 slice $KP-901" "pool-disposition: $KP-105 question waits on $KP-999" "pool-disposition: $KP-102 close PR 5001")"
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
for pk in APP APP2 ZZ_Q; do
    sed "s/HIMMEL-/$pk-/g" "$M/HIMMEL-110.md" > "$M/$pk-110.md"; sed "s/HIMMEL-/$pk-/g" "$M/HIMMEL-115.md" > "$M/$pk-115.md"
done
sed "s/HIMMEL-110/HIMMEL-901/; s/HIMMEL-115/APP2-117/g" "$M/HIMMEL-115.md" > "$M/APP2-117.md"
sed "s/HIMMEL-110/ZZ_Q-110/; s/HIMMEL-115/ZZ_Q-118/g; s/labels: .*/labels: []/" "$M/HIMMEL-115.md" > "$M/ZZ_Q-118.md"
check 'residuals whose relates link names another project key (digits, underscore) are counted exactly; one with no qualifying relation or no label is not' '4:APP-115,APP2-115,HIMMEL-115,ZZ_Q-115' "$(field residual-unversioned "$d")"
rm -f "$M"/APP-1*.md "$M"/APP2-1*.md "$M"/ZZ_Q-1*.md

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

d="$(doc rerule "pool-disposition: $KP-101 slice $KP-901" "pool-disposition: $KP-101 question waits on $KP-902")"
check 'a later disposition of the same key supersedes an older stale one' '0' "$(field pool-stale "$d")"
d="$(doc rerule2 "pool-disposition: $KP-101 question waits on $KP-902" "pool-disposition: $KP-101 slice $KP-901")"
check 'the later of two dispositions decides: an older open one does not mask a stale one' '1:HIMMEL-101' "$(field pool-stale "$d")"
d="$(doc rerule3 "pool-disposition: $KP-101 slice $KP-901" "pool-disposition: $KP-101 question operator decision 268")"
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

export TICK_STATE_DIR="$WORK/state"
GR="$WORK/grepo"; mkdir -p "$WORK/notarepo"
gnew() { rm -rf "$GR"; git init -q "$GR"; }
gc() {
    GIT_COMMITTER_DATE="$1" GIT_AUTHOR_DATE="$1" git -C "$GR" -c user.name=t -c user.email=t@t commit -q --allow-empty -m "$2" && git -C "$GR" rev-parse --short HEAD
}
cout() { TOKEN='' bash "$SUT" --pool-stale --doc "$1" --repo "${2:-$GR}" ${3:+--prior "$3"} 2>/dev/null; }
ofield() { printf '%s\n' "$2" | sed -n "s/^$1=//p"; }
named() { printf '%s\n' "$3" | sed -n "s/^$2=//p" | tr ':' ',' | tr ',' '\n' | grep -c "^$1\$"; }
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
    "CHANGED-DISPOSITION HIMMEL-151 line=$(hash12 "$v10") HIMMEL-902=open @$c1=2-behind since HIMMEL-902 $c2 via HIMMEL-902 $c3 [HIMMEL-902] B2 the second slice" \
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
sub110='[HIMMEL-110] another open parent'
c110="$(gc 2026-11-10T06:00:00Z "$sub110")"
v2t="HIMMEL-158 question after HIMMEL-902 and HIMMEL-110 (ZZ 11-08)"
p2t="^CHANGED-DISPOSITION HIMMEL-158 .* since HIMMEL-902 $c2 via HIMMEL-110 $c110 "
check 'two open parents: the oldest merge keeps its own target, the newest its own' 1 "$(cout "$(doc HIMMEL-nextleg-2026-11-10ZZ-r2t "$pd $v2t")" | grep -c "$p2t")"

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

# the YO lines are verbatim but for one token: 9622's @6eb44fbbe names the fixture's stand-in commit
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

# a `question decision <N>` line stops counting as dispositioned while its key carries a CLOSE-OR-DISPATCH row
cdd="$WORK/cod9561"; mkdir -p "$cdd/state"
{ printf '# chief\n\n## Live state\n'
  printf '%s\n' 'pool-disposition: HIMMEL-6829 question decision 847 (needs a chief note; never closed without operator words)' \
      'pool-disposition: HIMMEL-6830 question decision 847 (no drift row)' \
      'pool-disposition: HIMMEL-6831 slice HIMMEL-901 (the rest)' \
      'pool-disposition: HIMMEL-6832 close HIMMEL-901 (Done)'; } > "$cdd/chief.md"
printf '# disposition HIMMEL-%s listed LOCAL\n' 6829 6830 6831 6832 > "$cdd/rows"
cdrows() { TICK_STATE_DIR="$cdd/state" TOKEN='' bash "$SUT" --pool-dispositions --doc "$cdd/chief.md" < "$cdd/rows" 2>/dev/null; }
cdun() { printf '%s\n' "$1" | sed -n 's/^# pool-unresolved \([a-z]*\) \(HIMMEL-[0-9]*\) .*/\1 \2/p' | paste -sd, -; }
cdo="$(cdrows)"
check '9561 control: with no drift file every line is dispositioned' '4/0/4/0' "$(printf '%s\n' "$cdo" | sed -n 's/^# pool-counts //p')"
printf '%s\n' 'CLOSE-OR-DISPATCH HIMMEL-6829 In Progress with no open PR, no live owner and no event since 2026-11-10T18:00:00Z (73 h); last PR #5155, owed: x | writer=jira | fix=y' \
    'CLOSE-OR-DISPATCH HIMMEL-6831 In Progress with no open PR, no live owner and no event since 2026-11-10T18:00:00Z (73 h); last PR #5156, owed: x | writer=jira | fix=y' \
    'CLOSE-OR-DISPATCH HIMMEL-6832 In Progress with no open PR, no live owner and no event since 2026-11-10T18:00:00Z (73 h); last PR #5157, owed: x | writer=jira | fix=y' \
    'UNOWNED HIMMEL-6830 In Progress with no open PR and no live owner | writer=a | fix=b' 'sdrift=4:44444444' > "$cdd/focus-drift.txt"
cdo="$(cdrows)"
check '9561 a question decision line over a CLOSE-OR-DISPATCH row is class stale' 'stale HIMMEL-6829' "$(cdun "$cdo")"
check '9561 it is the only unresolved line: the question line over an UNOWNED row, a slice line and a close line stay dispositioned' '4/0/3/1' "$(printf '%s\n' "$cdo" | sed -n 's/^# pool-counts //p')"
cdkey=HIMMEL-6829
check '9561 its text names the row and the remedy' 1 "$(printf '%s\n' "$cdo" | grep -c "^# pool-unresolved stale $cdkey .*CLOSE-OR-DISPATCH.*close .*name a worker")"

real_scripts="$(cd "$HERE/../.." && pwd)"
sk="$WORK/kit/scripts"; mkdir -p "$sk/handover/chief-kit"
for f in "$real_scripts"/*; do [ "${f##*/}" = handover ] || ln -s "$f" "$sk/${f##*/}"; done
for f in "$real_scripts"/handover/*; do [ "${f##*/}" = chief-kit ] || ln -s "$f" "$sk/handover/${f##*/}"; done
for f in "$HERE"/*; do ln -s "$f" "$sk/handover/chief-kit/${f##*/}"; done
rm "$sk/handover/chief-kit/next-dispatchable.sh" "$sk/handover/chief-kit/tick.sh"
ln -s "$PS_REAL_SUT" "$sk/handover/chief-kit/tick.sh"
cat > "$sk/handover/chief-kit/next-dispatchable.sh" <<'EOF'
#!/usr/bin/env bash
case " $* " in *" --dispositions "*)
    # the parent is `timeout`; a bash is re-niced by some stations' ananicy rules, a timeout is not
    printf 'x\n' >> "$PS_LAUNCH_LOG"; ps -o ni= -p "$PPID" | tr -d ' ' >> "$PS_NICE_LOG"
    printf '%s\n' "$*" >> "$PS_LAUNCH_LOG.args"
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
check '10378 T4: control: the snapshot launch logs its --owners' 1 "$(tail -n 1 "$pl_log.args" | grep -c -- '--owners')"
check '10378 T4: the pool snapshot gets leg keys only, not the cloud key' 0 "$(tail -n 1 "$pl_log.args" | grep -o -- '--owners .*' | grep -c ZZTEST-7)"
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

write_holds() {
    local stem="${1##*/}"
    printf '{"ts":"x","mode":"on","rows":%s,"prs":%s}\n' "$2" "$3" > "$TICK_STATE_DIR/pool-holds-${stem%.md}.json"
}
real_field() { TOKEN='' bash "$PS_REAL_SUT" --pool-stale --doc "$2" 2>/dev/null | sed -n "s/^$1=//p"; }
hk=HIMMEL
d="$(doc hs-slice "$pd $hk-160 slice PR 3905 lands first")"
write_holds "$d" '[]' '{"3905":"MERGED"}'
check 'a slice naming a merged PR is still stale (from the holds file prs map)' '1:HIMMEL-160' "$(real_field pool-stale "$d")"
: > "$PS_GH_LOG"; real_field pool-stale "$d" > /dev/null
check 'pool_stale makes no gh call of its own' 0 "$(wc -l < "$PS_GH_LOG" | tr -d ' ')"
d="$(doc hs-none "$pd $hk-161 slice $hk-901 then the rest" "$pd $hk-162 close PR 5001" "$pd $hk-163 park soon wake=date:2099-01-01")"
rm -f "$TICK_STATE_DIR/pool-holds-hs-none.json"
hn="$(TOKEN='' bash "$PS_REAL_SUT" --pool-stale --doc "$d" 2>/dev/null)"
check 'no holds file: key targets still judged, PR targets and wake= lines ?' '1:HIMMEL-161,?' "$(printf '%s\n' "$hn" | sed -n 's/^pool-stale=//p')"
check 'no holds file: residual-unversioned= still printed' 1 "$(printf '%s\n' "$hn" | grep -c '^residual-unversioned=[0-9]')"
write_holds "$d" '[]' '{"5001":"MERGED"}'; touch -d '31 minutes ago' "$TICK_STATE_DIR/pool-holds-hs-none.json"  # gnu-ok: chief kit is Linux-only
check 'an old holds file reads its PR targets ?' '1:HIMMEL-161,?' "$(real_field pool-stale "$d")"
d="$(doc hs-unread "$pd $hk-164 hold on the merge wake=pr:4999")"
write_holds "$d" '[]' 'null'
check 'a holds file whose PR read failed reads a wake line ?, never an all-clear' '?' "$(real_field pool-stale "$d")"

hp="$WORK/hp"; mkdir -p "$hp/rel/v1.1.3" "$hp/state"; printf '{}\n' > "$hp/rel/v1.1.3/release.json"
d="$hp/HIMMEL-nextleg-2026-11-15HP-roadmap-chief.md"
printf '# chief\n\nrelease: v1.1.3\n\n## Live state\n%s\n%s\n\n## Results\n' \
    "$pd HIMMEL-9190 hold waits on PR 5002 upstream wake=pr:5002" \
    "$pd HIMMEL-9191 hold until then authority=O-v1.1.3-0001 wake=date:$(date -u -d yesterday +%Y-%m-%d)" > "$d"  # gnu-ok: chief kit is Linux-only
jq -n --arg t "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '{ts: $t, status: "OK", words_records: [{id: "O-v1.1.3-0001", decision: "9", keys: ["HIMMEL-9191"], op: "none", verbatim: "keep it held"}], asks_operator_keys: []}' \
    > "$hp/state/release-state-HIMMEL-nextleg-2026-11-15HP-roadmap-chief.json"
printf '{"schema":1,"workers":[]}\n' > "$hp/manifest.json"
hp_run() {
    printf '5002\tfork/fix\tfalse\tbob\t%s\n' "$1" > "$hp/open.tsv"
    TICK_STATE_DIR="$hp/state" HIMMEL_RELEASE_STATE_DIR="$hp/rel" bash "$PS_REAL_SUT" --pool-holds --doc "$d" --open-prs "$hp/open.tsv" --workers-from "$hp/manifest.json" > /dev/null 2>&1
    TICK_STATE_DIR="$hp/state" HIMMEL_RELEASE_STATE_DIR="$hp/rel" TOKEN='' bash "$PS_REAL_SUT" --pool-stale --doc "$d" 2>/dev/null
}
hpo="$(hp_run true)"
check 'the outside PR flags stale through the producer; a past date beside the operator words does not' '1:HIMMEL-9190' "$(printf '%s\n' "$hpo" | sed -n 's/^pool-stale=//p')"
check 'the outside line names its cause' 1 "$(printf '%s\n' "$hpo" | grep -c "^STALE-DISPOSITION $hk-9190 line=[0-9a-f]* PR#5002=OPEN outside-PR=unwatched\$")"
check 'a past date never fires: no wake=date: cause (decisions 1281, 1282)' 0 "$(printf '%s\n' "$hpo" | grep -c "wake=date:[0-9-]*=fired")"
check 'an open same-repo PR is not stale (I6)' '0' "$(hp_run false | sed -n 's/^pool-stale=//p')"

du="$WORK/du"; DUM="$du/mirror/HIMMEL"; mkdir -p "$du/rel/v1.1.3" "$du/state" "$du/w" "$DUM"; printf '{}\n' > "$du/rel/v1.1.3/release.json"
printf 'v1.1.3\tfalse\t\n' > "$du/mirror/HIMMEL.versions.tsv"
du_now=2026-11-22T12:00:00Z
du_cursor() { printf '{"lastSync":"%s"%s}\n' "$1" "${2:+,$2}" > "$DUM/.cursor.json"; }
du_cursor 2026-11-22T11:00:00Z
du_key() { printf -- '---\nkey: "HIMMEL-%s"\nstatus: "%s"\nstatusCategory: "%s"\nfixVersions: ["v1.1.3"]\n---\n\n# HIMMEL-%s: t\n' "$1" "$2" "$3" "$1" > "$DUM/HIMMEL-$1.md"; }
du_key 10713 "To Do" "To Do"; du_key 903 "To Do" "To Do"; du_key 905 Done Done
du_stem=HIMMEL-nextleg-2026-11-22DU-roadmap-chief
du_doc="$du/$du_stem.md"; du_file="$du/state/pool-holds-$du_stem.json"
du_mk() { printf '%s\n' '# chief' '' 'release: v1.1.3' '' '## Live state' "$@" '' '## Results' > "$du_doc"; }
du_rows() { local k; for k in "$@"; do printf '# disposition HIMMEL-%s listed LOCAL\n' "$k"; done > "$du/rows"; }
du_env() { env TICK_NOW="$du_now" TICK_STATE_DIR="$du/state" HIMMEL_RELEASE_STATE_DIR="$du/rel" NEXT_DISPATCH_MIRROR="$DUM" "$@"; }
du_holds() {
    jq -n --arg t "$du_now" '{ts: $t, status: "OK", asks_operator_keys: [],
        words_records: [{id: "O-v1.1.3-0001", decision: "9", keys: ["HIMMEL-207", "HIMMEL-213", "HIMMEL-214"], op: "none", verbatim: "keep it held"}]}' \
        > "$du/state/release-state-$du_stem.json"
    du_env bash "$PS_REAL_SUT" --pool-holds --doc "$du_doc" "$@" > /dev/null 2>&1
}
du_class() { jq -r --arg k "HIMMEL-$1" '.rows[] | select(.key == $k) | .class' "$du_file" 2>/dev/null; }
du_reason() { jq -r --arg k "HIMMEL-$1" '.rows[] | select(.key == $k) | .reason' "$du_file" 2>/dev/null; }
du_pd() { du_env bash "$PS_REAL_SUT" --pool-dispositions --doc "$du_doc" < "$du/rows" 2>/dev/null; }
du_stale() { du_env TOKEN='' bash "$PS_REAL_SUT" --pool-stale --doc "$du_doc" 2>/dev/null | sed -n 's/^pool-stale=//p'; }
: > "$du/open.tsv"; printf '{"schema":1,"workers":[]}\n' > "$du/manifest.json"
du_in=(--open-prs "$du/open.tsv" --workers-from "$du/manifest.json")
du_nothing='holds nothing: no live holder (decisions 1281, 1282)'

du_mk "$pd HIMMEL-7006 hold HIMMEL-7006 wake=date:2026-11-24 (AY 11-22, from the AU roadmap chief audit: v1.1.3 cut chain, VERSION, CHANGELOG, tag; confirm with the release manager that TAG-READY is tracked, then slice the cut)" \
    "$pd HIMMEL-9917 slice HIMMEL-9917 wake=date:2026-11-23 (AY 11-22 AU audit: merge-from-any-directory denial bug; AU said close by 11-22; audit the code rows, then close or slice)" \
    "$pd HIMMEL-9850 hold HIMMEL-9342 wake=date:2026-11-29 (AY 11-22 AU audit: tick under 20 CPU-s; folds into 9342 o14)" \
    "$pd HIMMEL-9525 question HIMMEL-9525 wake=date:2026-11-23 (AY 11-22 AU audit: hook cache dirs, about 30079 to clean; destructive, needs the operator, or close if the hook fix merged)" \
    "$pd HIMMEL-9190 hold decision 1228 wake=date:2026-11-23 (AY 11-22 AU audit: semantic API opt-in on the Mac station; Goomal session)" \
    "$pd HIMMEL-9252 hold HIMMEL-9569 wake=date:2026-11-23 (AY 11-22 AU audit: graph-data VM proof plus Mac adopter confirmation; gates a ticket close; Goomal session)" \
    "$pd HIMMEL-10377 hold waits on the chief signature under decision 1120 wake=date:2026-11-23 (AN 11-22 01:15Z re-read, ticket-auditor): docs worker dispatch after signing" \
    "$pd HIMMEL-10531 hold waits on the o62 harvest probe wake=date:2026-11-23 (AN 11-22 01:15Z re-read, ticket-auditor): code merged #5650; probe ok after the 11-22 harvest, then cadence-armed green" \
    "$pd HIMMEL-10069 hold waits on the chief recording the r4 spec signature wake=date:2026-11-23 (AN 11-22 01:15Z re-read, ticket-auditor): spec-check NO-SPEC; brief F10069a ready" \
    "$pd HIMMEL-8620 slice decision 1210 wake=date:2026-11-23 (hard-fail at 20k, allowlist the four; INTAKE Q-v1.1.3-5438; split follow-up HIMMEL-10713" \
    "$pd HIMMEL-8957 slice decision 1210 wake=date:2026-11-23 (dry-run count plus per-clip price worker owed; paid rerun needs a second GO)" \
    "$pd HIMMEL-10088 hold HIMMEL-10088 wake=date:2026-11-23 (AW audit: C69 OK, bare query no 401; only a full qmd embed proof left, then close o23 o24)" \
    "$pd HIMMEL-8823 hold HIMMEL-8823 wake=date:2026-11-23 (AW audit: S7 station first run is a chief run, no worker)" \
    "$pd HIMMEL-10660 slice HIMMEL-10660 wake=date:2026-11-23 (AW audit: design and plan r5 done; chief reads r5 verdict, signs, files build slices)" \
    "$pd HIMMEL-9569 hold decision 1228 wake=date:2026-11-23 (AY 11-22: B1 PRs merged; Mac VM e2e o86 and Goomal round trip o87 run in the 11-23 Goomal session)"
du_rows 7006 9917 9850 9525 9190 9252 10377 10531 10069 8620 8957 10088 8823 10660 9569
du_holds "${du_in[@]}"
du1="$(du_pd)"
check 'D1: every give-up BC 11-23 line reads no-authority: a date holds nothing' \
    'HIMMEL-10069 HIMMEL-10088 HIMMEL-10377 HIMMEL-10531 HIMMEL-10660 HIMMEL-7006 HIMMEL-8823 HIMMEL-8957 HIMMEL-9190 HIMMEL-9252 HIMMEL-9525 HIMMEL-9569 HIMMEL-9850 HIMMEL-9917 ' \
    "$(printf '%s\n' "$du1" | sed -n "s/^# pool-unresolved no-authority \(HIMMEL-[0-9]*\) wake=date $du_nothing: .*/\1/p" | sort | tr '\n' ' ')"
check 'D1: HIMMEL-8620, a decision slice, has no pool-unresolved line' 0 "$(printf '%s\n' "$du1" | grep -c '^# pool-unresolved [a-z-]* HIMME[L]-8620 ')"
check 'D1 field: pool-unheld= lists exactly the no-authority keys, not HIMMEL-8620' \
    'pool-unheld=14:HIMMEL-10069,HIMMEL-10088,HIMMEL-10377,HIMMEL-10531,HIMMEL-10660,HIMMEL-7006,HIMMEL-8823,HIMMEL-8957,HIMMEL-9190,HIMMEL-9252,HIMMEL-9525,HIMMEL-9569,HIMMEL-9850,HIMMEL-9917' \
    "$(printf '%s\n' "$du1" | grep '^pool-unheld=')"
du_seed() { cp "$du/rows" "$du/state/tick-pool-$(printf '%s\n%s' "$(realpath -m "$du_doc")" "$(realpath -m "$DUM")" | cksum | cut -d' ' -f1).rows"; }
du_tick() { du_env TICK_POOL_WAIT=0 TICK_POOL_MIN_SECS=99999 TOKEN='' bash "$PS_REAL_SUT" --doc "$du_doc" "$@" 2>/dev/null; }
sed -i '/^## Live state$/a pool-disposition: HIMMEL-9001 hold x wake=date:2026-11-21' "$du_doc"  # gnu-ok: chief kit is Linux-only
: > "$du/flag"; : > "$du/R.md"
sed -i "/^## Live state\$/a queue: 5737 HELD wake=file:$du/flag resume=$du/R.md" "$du_doc"  # gnu-ok: chief kit is Linux-only
du_rows 7006 9917 9850 9525 9190 9252 10377 10531 10069 8620 8957 10088 8823 10660 9569 9001; du_seed
du6="$(du_tick)"; du6v="$(du_tick --verbose)"
du6k='15:HIMMEL-10069,HIMMEL-10088,HIMMEL-10377,HIMMEL-10531,HIMMEL-10660,HIMMEL-7006,HIMMEL-8823,HIMMEL-8957,HIMMEL-9001,HIMMEL-9190,HIMMEL-9252,HIMMEL-9525,HIMMEL-9569,HIMMEL-9850,HIMMEL-9917'
check 'D6: the full tick prints the compact pool-unheld= field' "$du6k" "$(printf '%s\n' "$du6" | sed -n 's/.* pool-unheld=\([^ ]*\).*/\1/p')"
check 'D6: the verbose tick prints the plain pool-unheld: line' "pool-unheld: $du6k" "$(printf '%s\n' "$du6v" | grep '^pool-unheld: ')"
check 'H6: the queue: line wake=file: still fires relaunch= (out of scope, unchanged)' "5737:$du/R.md" "$(printf '%s\n' "$du6" | sed -n 's/.* relaunch=\([^ ]*\).*/\1/p')"
check 'D6: a date-only line past its date carries no fired cause' 0 "$(cat "$du"/state/tick-pool-stale-*.out <(printf '%s\n' "$du6v") | grep -c 'wake=date:2026-11-21=fired')"
du_mk "$pd HIMMEL-8620 slice decision 1210 wake=date:2026-11-23 - split follow-up HIMMEL-10713"
du_rows 8620; du_seed
check 'D6: a doc with nothing unheld has no compact pool-unheld= field' 0 "$(du_tick | grep -c ' pool-unheld=')"

du_mk "$pd HIMMEL-218 slice later into HIMMEL-903" "$pd HIMMEL-219 hold x wake=date:2026-11-25"
du_rows 218 219
du_unheld() { du_pd | grep '^pool-unheld='; }
rm -f "$du_file"
check 'D4: no holds file: the unowned key is listed and the unread give-up line adds +?' 'pool-unheld=1+?:HIMMEL-218' "$(du_unheld)"
du_holds "${du_in[@]}"; touch -d '31 minutes ago' "$du_file"  # gnu-ok: chief kit is Linux-only
check 'D4: a holds file 31 min old: the unowned key is listed with +?' 'pool-unheld=1+?:HIMMEL-218' "$(du_unheld)"
du_h31="$(du_pd | grep '^# pool-unresolved ')"
touch -d '35 minutes ago' "$du_file"  # gnu-ok: chief kit is Linux-only
check 'H5: the pool-unresolved block of a holds file 35 min old equals the block at 31 min' "$du_h31" "$(du_pd | grep '^# pool-unresolved ')"
du_holds "${du_in[@]}"; jq '.release = "v9.9.9"' "$du_file" > "$du_file.tmp" && mv "$du_file.tmp" "$du_file"
check 'D4: a holds file written for v9.9.9: the unowned key is listed with +?' 'pool-unheld=1+?:HIMMEL-218' "$(du_unheld)"
du_holds "${du_in[@]}"; touch -d '29 minutes ago' "$du_file"  # gnu-ok: chief kit is Linux-only
check 'D4: a holds file 29 min old judges the give-up line: no +?' 'pool-unheld=2:HIMMEL-218,HIMMEL-219' "$(du_unheld)"
check 'P7: the usage text names TICK_POOL_MIRROR_MAX and its default 21600' 1 "$(bash "$PS_REAL_SUT" --help 2>&1 | grep -c 'TICK_POOL_MIRROR_MAX.*21600')"

du_absent="$du/state/flag-not-yet"
du_mk "$pd HIMMEL-201 hold x wake=date:2026-11-25,pr:5002" "$pd HIMMEL-202 hold x wake=pr:5002" \
    "$pd HIMMEL-203 hold x wake=date:2026-11-25,pr:5001" "$pd HIMMEL-204 hold x wake=pr:5001" \
    "$pd HIMMEL-205 park x wake=date:2026-12-22" "$pd HIMMEL-206 park x wake=date:2026-13-45" \
    "$pd HIMMEL-207 hold x authority=O-v1.1.3-0001 wake=date:2026-11-21" "$pd HIMMEL-208 hold x wake=date:2026-11-21" \
    "$pd HIMMEL-209 park x wake=date:2026-11-25" "$pd HIMMEL-210 hold x wake=file:$du_absent" \
    "$pd HIMMEL-211 hold x wake=pr:5002" "$pd HIMMEL-212 hold x wake=pr:5002,file:$du_absent" \
    "$pd HIMMEL-213 hold x authority=O-v1.1.3-0001" "$pd HIMMEL-214 hold x authority=O-v1.1.3-0001 wake=file:$du_absent" \
    "$pd HIMMEL-215 hold x wake=date:2026-11-25,file:$du_absent"
du_holds "${du_in[@]}"
check 'D2: a date beside an open pr: changes nothing: wake, as the pr: alone' 'wake wake' "$(du_class 201) $(du_class 202)"
check 'D2: a date beside a merged pr: changes nothing: no-authority, as the pr: alone' 'no-authority no-authority' "$(du_class 203) $(du_class 204)"
check 'D2: a well-formed date 30 days out is a timer like any date, not invalid' "no-authority wake=date $du_nothing" "$(du_class 205) $(du_reason 205)"
check 'D2: a malformed date stays invalid with its reason' 'invalid wake=date:2026-13-45 is not a date' "$(du_class 206) $(du_reason 206)"
check 'D3: the operator words plus a past date: authority' authority "$(du_class 207)"
check 'D3: a past date alone: no-authority, a date holds nothing' "no-authority wake=date $du_nothing" "$(du_class 208) $(du_reason 208)"
check 'D3: a past date beside the operator words is not stale' 0 "$(du_stale | grep -c 'HIMME[L]-207')"
du_rows 201 202 203 204 205 206 207 208 210 211 212 213 214 215
printf '# disposition HIMMEL-209 in-flight owned by N1\n' >> "$du/rows"
check 'D5: a date-only line whose key is in flight has no pool-unresolved line' 0 "$(du_pd | grep -c '^# pool-unresolved [a-z-]* HIMME[L]-209 ')"
check 'H6: wake=file: alone holds nothing' "no-authority wake=file $du_nothing" "$(du_class 210) $(du_reason 210)"
check 'H6: a file part beside an open pr: changes nothing' 'wake wake' "$(du_class 211) $(du_class 212)"
check 'H6: a file part beside the operator words changes nothing' 'authority authority' "$(du_class 213) $(du_class 214)"
check 'H6: a date and a file name each timer kind in one reason' "no-authority wake=date,file $du_nothing" "$(du_class 215) $(du_reason 215)"

du_mk "$pd HIMMEL-216 hold x wake=done:HIMMEL-903" "$pd HIMMEL-217 slice HIMMEL-905 then the rest"
du_rows 216 217
du_holds "${du_in[@]}"
check 'D9 owner: done: on a To Do key in the version with no worker and no PR holds nothing' 'no-authority done:HIMMEL-903 has no live owner' "$(du_class 216) $(du_reason 216)"
check 'D9 field: the no-owner done: key is listed' 'pool-unheld=1:HIMMEL-216' "$(du_unheld)"
printf '5003\tfeat/himmel-903-x\tfalse\tbob\tfalse\n' > "$du/open.tsv"
du_holds "${du_in[@]}"
check 'D9 owner: an open PR naming the key in its branch is a live owner' wake "$(du_class 216)"
: > "$du/open.tsv"
du_w="$du/w/HIMMEL-903-N1-x.md"
printf '# w\n\n## Results\n- 10:00 LIVE — on it\n' > "$du_w"
printf '#!/usr/bin/env bash\necho "status: FRESH"\nexit 11\n' > "$du/lock-held.sh"; chmod +x "$du/lock-held.sh"
jq -n --arg d "$du_w" '{schema: 1, workers: [{doc: $d, label: "N1"}]}' > "$du/manifest.json"
TICKET_STATUS_QUEUE_LOCK="$du/lock-held.sh" du_holds "${du_in[@]}"
check 'D9 owner: a live manifest worker on the key is a live owner (S2)' wake "$(du_class 216)"
printf -- '- 11:00 WRAPPED — done\n' >> "$du_w"
TICKET_STATUS_QUEUE_LOCK="$du/lock-held.sh" du_holds "${du_in[@]}"
check 'D9 owner: a wrapped manifest worker owns nothing' no-authority "$(du_class 216)"
jq -n --arg d "$du/w/HIMMEL-903-N2-gone.md" '{schema: 1, workers: [{doc: $d, label: "N2"}]}' > "$du/manifest.json"
du_holds "${du_in[@]}"
check 'D9 owner: a manifest worker whose state reads unknown leaves done: unchecked' unchecked "$(du_class 216)"
printf '{"schema":1,"workers":[]}\n' > "$du/manifest.json"
du_holds --workers-from "$du/manifest.json"
check 'D9 owner: no open-PR list leaves done: unchecked, never no-authority (S1)' unchecked "$(du_class 216)"
printf '{"schema":' > "$du/manifest.json"
du_holds "${du_in[@]}"
check 'D9 owner: a corrupt manifest leaves done: unchecked, never no-authority (S1)' unchecked "$(du_class 216)"
printf '{"schema":1,"workers":[]}\n' > "$du/manifest.json"
du_holds "${du_in[@]}"
check 'D9 mirror: a fresh complete cursor writes mirror_fresh true' true "$(jq -r '.mirror_fresh' "$du_file")"
check 'D9 mirror: a fresh mirror leaves the Done slice target stale' '1:HIMMEL-217' "$(du_stale)"
for du_c in 'lastSync 7 h old' 'complete false' 'absent'; do
    case "$du_c" in
        'lastSync 7 h old') du_cursor 2026-11-22T05:00:00Z ;;
        'complete false') du_cursor 2026-11-22T11:00:00Z '"complete":false' ;;
        absent) rm -f "$DUM/.cursor.json" ;;
    esac
    du_holds "${du_in[@]}"
    check "D9 mirror: a cursor $du_c writes mirror_fresh false" false "$(jq -r '.mirror_fresh' "$du_file")"
    check "D9 mirror: a cursor $du_c leaves done: unchecked" unchecked "$(du_class 216)"
    du9="$(du_pd)"
    check "D9 field: a cursor $du_c makes the key-target slice line unchecked" 1 "$(printf '%s\n' "$du9" | grep -c '^# pool-unresolved unchecked HIMME[L]-217 the Jira mirror is stale or incomplete: HIMME[L]-217 slice HIMME[L]-905 then the rest$')"
    check "D9 field: a cursor $du_c adds +?" 'pool-unheld=0+?' "$(printf '%s\n' "$du9" | grep '^pool-unheld=')"
    check "D9 mirror: a cursor $du_c reads the slice key target ?" '?' "$(du_stale)"
done
printf '5003\tfeat/himmel-903-x\tfalse\tbob\tfalse\n' > "$du/open.tsv"
du_holds "${du_in[@]}"
check 'D9 mirror: a stale mirror leaves done: unchecked even with an open PR on the key' unchecked "$(du_class 216)"
: > "$du/open.tsv"; du_cursor 2026-11-22T11:00:00Z
du_holds "${du_in[@]}"; du9="$(du_pd)"
check 'D9 field: a fresh complete mirror decides the slice line again, the saved stale file notwithstanding' 0 "$(printf '%s\n' "$du9" | grep -c '^# pool-unresolved unchecked HIMME[L]-217 ')"
check 'D9 field: a fresh complete mirror drops the +?' 'pool-unheld=1:HIMMEL-216' "$(printf '%s\n' "$du9" | grep '^pool-unheld=')"
rm -f "$du_file"
check 'S3: no holds file is no mirror verdict: the Done slice target is still stale (the ? is the unread wake= line)' '1:HIMMEL-217,?' "$(du_stale)"
du_cursor 2026-11-22T05:00:00Z
du_off="$du/off.md"; printf '%s\n' '# chief' '' 'release: none' '' '## Live state' "$pd HIMMEL-217 slice HIMMEL-905 then the rest" '' '## Results' > "$du_off"
du_env bash "$PS_REAL_SUT" --pool-holds --doc "$du_off" "${du_in[@]}" > /dev/null 2>&1
check 'S3: a ledger-off doc writes no mirror verdict' null "$(jq -r '.mirror_fresh' "$du/state/pool-holds-off.json")"
check 'S3: a ledger-off doc keeps the Done slice target stale on a stale mirror' '1:HIMMEL-217' "$(du_env TOKEN='' bash "$PS_REAL_SUT" --pool-stale --doc "$du_off" 2>/dev/null | sed -n 's/^pool-stale=//p')"
du_cursor 2026-11-22T11:00:00Z

rk="$WORK/rk"; mkdir -p "$rk/conf" "$rk/cache" "$rk/home/.himmel/state/jira-mirror/CONFKEY"
printf 'JIRA_PROJECT_KEY=CONFKEY\n' > "$rk/conf/himmel.conf"
: > "$rk/cache/.env"
printf -- '---\nkey: "CONFKEY-901"\nstatus: "Done"\nstatusCategory: "Done"\n---\n\n# CONFKEY-901: t\n' > "$rk/home/.himmel/state/jira-mirror/CONFKEY/CONFKEY-901.md"
printf '# chief\n\n## Live state\npool-disposition: CONFKEY-101 slice CONFKEY-901 then the rest\n\n## Results\n' > "$rk/chief.md"
rk_field() {
    env -u NEXT_DISPATCH_MIRROR HOME="$rk/home" JIRA_PROJECT_KEY= HIMMEL_JIRA_MIRROR= HIMMEL_CONFIG_DIR="$rk/conf" HIMMELCTL_CACHE_DIR="$rk/cache" "$@" \
        TOKEN='' bash "$SUT" --pool-stale --doc "$rk/chief.md" 2>/dev/null | sed -n 's/^pool-stale=//p'
}
check 'a himmel.conf key and no override reads the mirror of that key' '1:CONFKEY-101' "$(rk_field)"
check 'NEXT_DISPATCH_MIRROR still wins over the resolver: its mirror lacks CONFKEY-901, so the target is unreadable' '?' "$(rk_field NEXT_DISPATCH_MIRROR="$M")"

T="$WORK/tickets"; mkdir -p "$T"; cp "$M"/HIMMEL-*.md "$T/"
d="$(doc keybase "pool-disposition: $hk-101 slice $hk-901 then the rest")"
check 'an override directory not named for the project still matches the project key' "1:$hk-101" \
    "$(JIRA_PROJECT_KEY=HIMMEL NEXT_DISPATCH_MIRROR="$T" field pool-stale "$d")"

pk_mirror() {
    local p="$WORK/pk-$1"; mkdir -p "$p"
    printf -- '---\nkey: "%s-110"\nstatus: "Done"\nstatusCategory: "Done"\n---\n\n# %s-110: t\n' "$1" "$1" > "$p/$1-110.md"
    printf -- '---\nkey: "%s-111"\nstatus: "To Do"\nstatusCategory: "To Do"\n---\n\n# %s-111: t\n' "$1" "$1" > "$p/$1-111.md"
    printf '%s' "$p"
}
for k in APP2 MY_APP; do
    p="$(pk_mirror "$k")"
    d="$(doc "key-$k" "pool-disposition: $k-101 slice $k-110")"
    check "a $k disposition naming its Done ticket reports it stale" "1:$k-101" \
        "$(JIRA_PROJECT_KEY=$k NEXT_DISPATCH_MIRROR="$p" field pool-stale "$d")"
done
p="$(pk_mirror APP2)"
v='APP2-151 question after APP2-111 its first slice'
d="$(doc key-carry "$pd $v")"
printf '%s\n' "CHANGED-DISPOSITION APP2-151 line=$(hash12 "$v") APP2-111=open since APP2-111 abc1234 via APP2-111 abc1234 [APP2-111] first" > "$WORK/key-carry.prior"
check 'a carried CHANGED-DISPOSITION record of an APP2 key is read back' '1:APP2-151,?' \
    "$(JIRA_PROJECT_KEY=APP2 NEXT_DISPATCH_MIRROR="$p" ofield pool-changed "$(JIRA_PROJECT_KEY=APP2 NEXT_DISPATCH_MIRROR="$p" cout "$d" "$WORK/notarepo" "$WORK/key-carry.prior")")"
d="$(doc key-carry2 "$pd APP2-152 slice APP2-999")"
printf '%s\n' "STALE-DISPOSITION APP2-152 line=$(hash12 'APP2-152 slice APP2-999') APP2-999=? carried" > "$WORK/key-carry2.prior"
check 'a carried STALE-DISPOSITION record of an APP2 key is read back' '1:APP2-152,?' \
    "$(JIRA_PROJECT_KEY=APP2 NEXT_DISPATCH_MIRROR="$p" ofield pool-stale "$(JIRA_PROJECT_KEY=APP2 NEXT_DISPATCH_MIRROR="$p" cout "$d" "$WORK/notarepo" "$WORK/key-carry2.prior")")"

printf '\n%d failure(s)\n' "$fails"
[ "$fails" -eq 0 ]
