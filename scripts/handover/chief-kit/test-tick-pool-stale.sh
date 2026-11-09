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

# --- the detached pool snapshot refreshes only when an input changed (the mirror's .cursor.json lastSync,
# the fleet manifest's mtime, the chief doc's mtime), never inside TICK_POOL_MIN_SECS, and runs at nice +10.
# The kit is the real one file by file; its next-dispatchable.sh is a stub that logs each launch and its nice.
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
    printf '# disposition HIMMEL-1 in-flight owned by worker N1\n' ;;
esac
EOF
pl_dir="$WORK/pl"; mkdir -p "$pl_dir"
pl_doc="$(doc pooldoc)"
pl_log="$pl_dir/launch.log"; pl_nice="$pl_dir/nice.log"
pl_tick() { TOKEN='' TICK_STATE_DIR="$pl_dir/state" PS_LAUNCH_LOG="$pl_log" PS_NICE_LOG="$pl_nice" bash "$sk/handover/chief-kit/tick.sh" --doc "$pl_doc" 2>/dev/null; }
pl_n() { if [ -f "$pl_log" ]; then wc -l < "$pl_log" | tr -d ' '; else echo 0; fi; }
pl_rows() { find "$pl_dir/state" -name 'tick-pool-*.rows' 2>/dev/null; }
pl_age() { local r; r="$(pl_rows)"; [ -z "$r" ] || touch -d "$1" "$r"; }  # gnu-ok: chief kit is Linux-only
printf '{"lastSync":"2026-11-01T00:00:00Z"}\n' > "$M/.cursor.json"
pl_tick > /dev/null
check 'the first tick launches a snapshot' 1 "$(pl_n)"
pl_age '20 minutes ago'
pl_tick > /dev/null
check 'a second tick past the floor with unchanged inputs launches no second snapshot' 1 "$(pl_n)"
pl_age '2 hours ago'
pl_out="$(pl_tick)"
check 'an unchanged-input skip still serves the counts (the snapshot is kept fresh, not left to expire)' 1 "$(printf '%s\n' "$pl_out" | grep -c ' pool=[0-9]')"
printf '{"lastSync":"2026-11-01T00:10:00Z"}\n' > "$M/.cursor.json"
pl_age '20 minutes ago'
pl_tick > /dev/null
check 'a mirror sync between two ticks launches the next snapshot' 2 "$(pl_n)"
pl_age '20 minutes ago'
touch "$pl_doc"
pl_tick > /dev/null
check 'a changed chief doc launches a snapshot past the floor' 3 "$(pl_n)"
pl_age '20 minutes ago'
printf '%s\tZZTEST-7\t\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "${pl_doc%/*}/cloud-sessions.tsv"
pl_tick > /dev/null
check 'a changed owner set (a cloud session now owns a key) launches a snapshot past the floor' 4 "$(pl_n)"
printf '{"lastSync":"2026-11-01T00:20:00Z"}\n' > "$M/.cursor.json"
pl_tick > /dev/null
check 'a changed input inside the floor still launches nothing' 4 "$(pl_n)"
pl_nice_want=$(( $(nice) + 10 )); [ "$pl_nice_want" -le 19 ] || pl_nice_want=19
check 'every launched snapshot runs at nice +10' "$(printf '%s\n%s\n%s\n%s' "$pl_nice_want" "$pl_nice_want" "$pl_nice_want" "$pl_nice_want")" "$(cat "$pl_nice")"

printf '\n%d failure(s)\n' "$fails"
[ "$fails" -eq 0 ]
