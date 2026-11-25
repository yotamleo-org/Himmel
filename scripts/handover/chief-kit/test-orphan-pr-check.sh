#!/usr/bin/env bash
# test-orphan-pr-check.sh — Exercises orphan-pr-check.sh: every open PR must be owned by a
# ticket whose worker record (<state dir>/workers/<KEY>.json) reads anything but wrapped or
# none, or be named on the chief doc's `queue:` line; each orphan prints
# `UNMAPPED <n> <branch>` and the exit is 1. The PR list comes from a fixture file
# (ORPHAN_PR_CHECK_PRS, the shape of `gh pr list --json number,headRefName,isCrossRepository,author`);
# the worker records from a scratch state dir (TICKET_STATUS_STATE_DIR). bash 3.2-safe.
#
# ORPHAN_PR_CHECK overrides the script under test (the RED control).
#
# Run: bash scripts/handover/chief-kit/test-orphan-pr-check.sh
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
OPC="${ORPHAN_PR_CHECK:-$HERE/orphan-pr-check.sh}"

fails=0
check() { # <name> <expected> <actual>
    if [ "$2" = "$3" ]; then echo "PASS: $1"; else echo "FAIL: $1 (want '$2' got '$3')"; fails=$((fails + 1)); fi
}

WORK="$(mktemp -d "${TMPDIR:-/tmp}/orphan-pr-check-test.XXXXXX")" || { echo "mktemp -d failed" >&2; exit 1; }
trap 'rm -rf "$WORK"' EXIT

export TICKET_STATUS_STATE_DIR="$WORK/state"
READTOK=ghp_READTOKEN0123456789
mkdir -p "$WORK/root" "$WORK/emptyroot" "$WORK/tt"
printf 'himmel_github_token_vm2=%s\n' "$READTOK" > "$WORK/root/.env"
: > "$WORK/emptyroot/.env"
ln -s "$HERE/fixtures/gh-two-token-stub.sh" "$WORK/tt/gh"
export GH_READ_ENV_ROOT="$WORK/emptyroot" HIMMEL_SECRETS_KEYRING=off
unset GH_TOKEN GITHUB_TOKEN himmel_github_token_vm2 CREDENTIALS_DIRECTORY
mkdir -p "$TICKET_STATUS_STATE_DIR/workers"
record() { # <KEY> <state> — one worker record
    printf '{"key":"%s","state":"%s","prs":{"1":{"open":true}}}\n' "$1" "$2" > "$TICKET_STATUS_STATE_DIR/workers/$1.json"
}

DOC="$WORK/HIMMEL-nextleg-2026-11-01A-chief.md"
write_doc() { # <queue line value>
    # shellcheck disable=SC2016  # the backticks are literal markdown
    printf '# chief\n\n## Live state\n\nlegs: `N1:n:t:1`\nqueue: %s\nlast GO: none\n\n## Results\n- 08:00 LIVE — one\n' "$1" > "$DOC"
}

PRS="$WORK/prs.json"
pr() { # <number> <branch> [author login] [isCrossRepository] — one fixture entry
    printf '{"number":%s,"headRefName":"%s","author":{"login":"%s"},"isCrossRepository":%s}' "$1" "$2" "${3:-yotamleo}" "${4:-false}"
}
prs() { # <entry>... — write the gh fixture
    local sep="" out="["
    while [ "$#" -ge 1 ]; do out="$out$sep$1"; sep=","; shift; done
    printf '%s]\n' "$out" > "$PRS"
}
run() { # sets rc and out
    out="$(ORPHAN_PR_CHECK_PRS="$PRS" bash "$OPC" --doc "$DOC" 2>"$WORK/err")"; rc=$?
}

# --- an orphan: its ticket has no record and nothing holds it (RED on main: no check exists)
write_doc "none"
prs "$(pr 103 fix/himmel-333-gamma)"
run
check "no record: exits 1" "1" "$rc"
check "no record: names the PR and its branch" "UNMAPPED 103 fix/himmel-333-gamma" "$out"

# --- a record that reads wrapped or none leaves the PR unowned; every other state owns it
record HIMMEL-333 wrapped
run
check "record state wrapped: unowned" "UNMAPPED 103 fix/himmel-333-gamma" "$out"
record HIMMEL-333 none
run
check "record state none: unowned" "UNMAPPED 103 fix/himmel-333-gamma" "$out"
for st in live idle IDLE-HELD parked unknown; do
    record HIMMEL-333 "$st"
    run
    check "record state $st: owned, exits 0" "0" "$rc"
done

# --- a PR's open flag in the record is not read: a stale open:true on a wrapped record stays unowned
record HIMMEL-333 wrapped
run
check "a wrapped record with a stale open flag is still unowned" "1" "$rc"

# --- a draft is still an open PR (the fixture carries no draft filter)
prs "$(pr 104 fix/himmel-444-delta)"
record HIMMEL-444 wrapped
run
check "a PR of a wrapped ticket is unowned whether or not it is a draft" "UNMAPPED 104 fix/himmel-444-delta" "$out"

# --- Dependabot's PRs are not a worker's: by author and by branch
prs "$(pr 4439 dependabot/npm_and_yarn/foo-1.2 app/dependabot)"
run
check "a Dependabot PR (app/dependabot author) is not an orphan" "0" "$rc"
prs "$(pr 4440 chore/bump 'dependabot[bot]')"
run
check "a Dependabot PR (dependabot[bot] author) is not an orphan" "0" "$rc"
prs "$(pr 4441 dependabot/go_modules/bar-3.4)"
run
check "a dependabot/ branch is not an orphan" "0" "$rc"
prs "$(pr 4442 chore/hand-bump yotamleo)"
run
check "a non-Dependabot PR with no ticket in its branch is an orphan" "UNMAPPED 4442 chore/hand-bump" "$out"

# --- a fork PR is not ours
prs "$(pr 4500 fix/himmel-555-fork contributor true)"
run
check "a fork PR is not an orphan" "0" "$rc"

# --- a PR held on the queue: line, by ticket key and by PR number
RESUME_DOC=/h/N1-beta-RESUME.md
write_doc "HIMMEL-222, hold wake=pr:4951 resume=$RESUME_DOC"
prs "$(pr 102 feat/himmel-222-beta)"
run
check "queue-held by ticket key: exits 0" "0" "$rc"
write_doc "#102 held (adapter merge) wake=done:HIMMEL-9032 resume=$RESUME_DOC"
run
check "queue-held by PR number: exits 0" "0" "$rc"
write_doc "#102 HELD wake=file:/h/specs/decisions/d-1216.txt resume=$RESUME_DOC"
run
check "10716 a HELD entry with a file trigger and a resume doc holds the PR" "0" "$rc"
write_doc "#102 HELD waits on 4951"
run
check "10716 a HELD entry with no trigger reads as unowned" "1:UNMAPPED 102 feat/himmel-222-beta" "$rc:$out"
write_doc "#102 HELD wake=pr:4951"
run
check "10716 a HELD entry with a trigger and no resume doc reads as unowned" "1:UNMAPPED 102 feat/himmel-222-beta" "$rc:$out"
write_doc "#102 HELD resume=$RESUME_DOC"
run
check "10716 a HELD entry with a resume doc and no trigger reads as unowned" "1:UNMAPPED 102 feat/himmel-222-beta" "$rc:$out"
write_doc "#102 HELD wake=pr:soon resume=relative/doc.md"
run
check "10716 a malformed trigger or a relative resume path reads as unowned" "1:UNMAPPED 102 feat/himmel-222-beta" "$rc:$out"
write_doc "#103 HELD wake=pr:102 resume=$RESUME_DOC"
run
check "10716 a PR named only as another entry's trigger is not held by it" "1:UNMAPPED 102 feat/himmel-222-beta" "$rc:$out"
write_doc "#103 HELD waits on 102 wake=pr:102 resume=$RESUME_DOC"
run
check "10716 a blocker PR named in an armed entry's prose stays unowned" "1:UNMAPPED 102 feat/himmel-222-beta" "$rc:$out"
write_doc "#103 HELD-until 102 wake=pr:102 resume=$RESUME_DOC"
run
check "10716 a hyphen-joined hold word still ends the held names" "1:UNMAPPED 102 feat/himmel-222-beta" "$rc:$out"
write_doc "#4400 HELD wake=pr:4951 resume=$RESUME_DOC | #102 HELD wake=pr:4951 resume=$RESUME_DOC | #4401 HELD waits"
gone="$(ORPHAN_PR_CHECK_PRS="$PRS" bash "$OPC" --gone-held --doc "$DOC" 2>/dev/null)"
check "10716 --gone-held names only the armed entry whose PR is no longer open" "1:1" "$(printf '%s\n' "$gone" | grep -c .):$(printf '%s\n' "$gone" | grep -c '^#4400 HELD')"
write_doc "#4400 #102 HELD wake=pr:4951 resume=$RESUME_DOC"
check "10716 --gone-held keeps an entry that still names an open PR" "" "$(ORPHAN_PR_CHECK_PRS="$PRS" bash "$OPC" --gone-held --doc "$DOC" 2>/dev/null)"
write_doc "#102 (adapter merge)"
run
check "9599 a PR named on the queue: line with no hold word is unowned" "1:UNMAPPED 102 feat/himmel-222-beta" "$rc:$out"
write_doc "4951 merging | 102 222 N5162 handed off, relaunch after 4951 merges | 4660 8992 HELD until 9032"
run
check "9599 a narrative segment that names the PR and no hold is unowned" "1:UNMAPPED 102 feat/himmel-222-beta" "$rc:$out"
write_doc "4951 merging | 102 222 HELD until 9032 Task 2 wake=pr:9032 resume=$RESUME_DOC | 4660 8992 relaunch"
run
check "9599 a HELD segment names the PR: exits 0" "0" "$rc"
write_doc "102 222 threshold tuning, withheld relaunch wake=pr:9032 resume=$RESUME_DOC"
run
check "9599 hold inside another word does not hold the PR" "1:UNMAPPED 102 feat/himmel-222-beta" "$rc:$out"
write_doc "102 222 hold2, held_x wake=pr:9032 resume=$RESUME_DOC"
run
check "9599 hold followed by a digit or an underscore does not hold the PR" "1:UNMAPPED 102 feat/himmel-222-beta" "$rc:$out"
write_doc "4951 merging || prior US queue: 102 222 HELD until 9032 wake=pr:9032 resume=$RESUME_DOC"
run
check "9599 a hold in a prior-queue segment after || does not hold the PR" "1:UNMAPPED 102 feat/himmel-222-beta" "$rc:$out"
write_doc "none"
run
check "the same PR with the hold gone is unowned" "UNMAPPED 102 feat/himmel-222-beta" "$out"
write_doc "#1020, HIMMEL-2222 HELD wake=pr:9032 resume=$RESUME_DOC"
run
check "a longer number or key does not hold the PR" "1" "$rc"
write_doc "none"

# --- several PRs: only the orphans print, in order
record HIMMEL-111 live
prs "$(pr 101 fix/himmel-111-alpha)" "$(pr 103 fix/himmel-333-gamma)" "$(pr 4439 dependabot/x app/dependabot)" "$(pr 105 chore/no-key)"
record HIMMEL-333 wrapped
run
check "mixed set: one line per orphan" "UNMAPPED 103 fix/himmel-333-gamma
UNMAPPED 105 chore/no-key" "$out"

# --- no open PR
prs
run
check "no open PR: exits 0" "0" "$rc"

# --- an unreadable or malformed PR list is neither an orphan nor an all-clear
rm -f "$PRS"
run
check "unavailable PR list: exits 3" "3" "$rc"
check "unavailable PR list: says so on stderr" "1" "$(grep -c 'unavailable' "$WORK/err")"
printf '{}\n' > "$PRS"
run
check "a PR list that is not an array: exits 3" "3" "$rc"
printf '[{}]\n' > "$PRS"
run
check "a PR entry with no number: exits 3, no fictitious orphan" "3" "$rc"
check "a PR entry with no number: prints no UNMAPPED line" "" "$out"

# --- a malformed author field is not an all-clear: the PR is still read, as a non-Dependabot one
printf '[{"number":107,"headRefName":"fix/himmel-777-odd","author":"someone"}]\n' > "$PRS"
run
check "a PR whose author is not an object is still checked, never an all-clear" "UNMAPPED 107 fix/himmel-777-odd" "$out"

# --- an unreadable chief doc cannot name a hold, so the check is unavailable, not a pile of orphans
prs "$(pr 108 fix/himmel-888-held)"
out="$(ORPHAN_PR_CHECK_PRS="$PRS" bash "$OPC" --doc "$WORK/no-such-chief-doc.md" 2>/dev/null)"; rc=$?
check "an unreadable chief doc: exits 3" "3" "$rc"
check "an unreadable chief doc: prints no UNMAPPED line" "" "$out"

# --- an unparsable worker record cannot show the PR unowned
prs "$(pr 106 fix/himmel-666-broken)"
printf 'not json\n' > "$TICKET_STATUS_STATE_DIR/workers/HIMMEL-666.json"
run
check "an unparsable record is not an orphan" "0" "$rc"

mkdir -p "$WORK/ghbin"
cat > "$WORK/ghbin/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$OPC_GH_LOG"
[ "$1 $2" != "pr list" ] || printf '[{"number":109,"headRefName":"fix/himmel-999-quota"}]\n'
EOF
chmod +x "$WORK/ghbin/gh"
qplant() {
    local now; now=$(date +%s)
    mkdir -p "$1"
    printf 'main\tgraphql\t%s\t5000\t%s\t%s\t%s\nmain\tcore\t4000\t5000\t%s\t%s\tok\n' "$2" "$((now + 1800))" "$now" "$3" "$((now + 1800))" "$now" > "$1/quota.tsv"
}
qrun() {
    : > "$WORK/gh.log"
    if [ "$1" = - ]; then
        out="$(env -u HIMMEL_QUOTA_DIR -u ORPHAN_PR_CHECK_PRS PATH="$WORK/ghbin:$PATH" OPC_GH_LOG="$WORK/gh.log" bash "$OPC" --doc "$DOC" --repo "$WORK" 2>"$WORK/err")"; rc=$?
    else
        out="$(env -u ORPHAN_PR_CHECK_PRS HIMMEL_QUOTA_DIR="$1" PATH="$WORK/ghbin:$PATH" OPC_GH_LOG="$WORK/gh.log" bash "$OPC" --doc "$DOC" --repo "$WORK" 2>"$WORK/err")"; rc=$?
    fi
}
write_doc "none"
qplant "$WORK/q-out" 0 refused
qrun "$WORK/q-out"
check "a paused GitHub: exits 3 with no UNMAPPED line" "3:" "$rc:$out"
check "a paused GitHub: the pause line is on stderr" "1" "$(grep -c '^QUOTA-PAUSE github graphql token=main remaining=0 .*caller=orphan-pr-check nothing-was-judged$' "$WORK/err")"
check "a paused GitHub: says unavailable on stderr" "1" "$(grep -c 'orphan-pr-check: unavailable' "$WORK/err")"
check "a paused GitHub: no gh call" "0" "$(wc -l < "$WORK/gh.log" | tr -d ' ')"
qplant "$TICKET_STATUS_STATE_DIR/quota" 0 refused
qrun -
check "with no HIMMEL_QUOTA_DIR the state dir's readings pause it" "3:0" "$rc:$(wc -l < "$WORK/gh.log" | tr -d ' ')"
qplant "$WORK/q-ok" 4000 ok
qrun "$WORK/q-ok"
check "RED control: a healthy budget reads the list and finds the orphan" "1:UNMAPPED 109 fix/himmel-999-quota" "$rc:$out"
check "RED control: a healthy budget prints no pause line" "0" "$(grep -c 'QUOTA-PAUSE\|GH-STALL' "$WORK/err")"

ttrun() {
    local root="$1"; shift
    : > "$WORK/tt.log"
    out="$(env -u ORPHAN_PR_CHECK_PRS PATH="$WORK/tt:$PATH" GHLOG="$WORK/tt.log" GH_STUB_DELEGATE="$WORK/ghbin/gh" OPC_GH_LOG="$WORK/gh.log" \
        GH_STUB_READ_TOKEN="$READTOK" GH_READ_ENV_ROOT="$root" HIMMEL_QUOTA_DIR="$WORK/q-ok" "$@" bash "$OPC" --doc "$DOC" --repo "$WORK" 2>"$WORK/err")"; rc=$?
    ttlog="$(cat "$WORK/tt.log")"
}
ttrun "$WORK/root" GH_STUB_MAINFAIL=rate
check "two-token: a spent main token still gives a verdict, not unavailable" "1:UNMAPPED 109 fix/himmel-999-quota" "$rc:$out"
check "two-token: the list read logs tok=read" "1" "$(printf '%s\n' "$ttlog" | grep -c '^tok=read argv=pr list ')"
check "two-token: no list read logs tok=main" "0" "$(printf '%s\n' "$ttlog" | grep -c '^tok=main argv=pr list ')"
check "two-token: the read token value never reaches the stub log or the scan's output" "0" "$(printf '%s\n' "$ttlog" "$out" "$(cat "$WORK/err")" | grep -c "$READTOK")"
ttrun "$WORK/root" GH_STUB_READFAIL=rate
check "no-fallback: a rate-limited read token with main healthy reports unavailable, exit 3" "3:" "$rc:$out"
check "no-fallback: says unavailable on stderr" "1" "$(grep -c 'orphan-pr-check: unavailable' "$WORK/err")"
check "no-fallback: the stub log holds the read attempt" "1" "$(printf '%s\n' "$ttlog" | grep -c '^tok=read argv=pr list ')"
check "no-fallback: the stub log holds no tok=main read" "0" "$(printf '%s\n' "$ttlog" | grep -c '^tok=main argv=pr list ')"
ttrun "$WORK/emptyroot"
check "two-token control: an empty root still gives the verdict" "1:UNMAPPED 109 fix/himmel-999-quota" "$rc:$out"
check "two-token control: with no read token the list logs tok=main" "1" "$(printf '%s\n' "$ttlog" | grep -c '^tok=main argv=pr list ')"

GOLD="$HERE/fixtures/orphan-pr-check-golden"
MIRROR="$WORK/mirror"; mkdir -p "$MIRROR"
mkey() {
    printf -- '---\nkey: "HIMMEL-%s"\ntype: "Task"\nstatus: "x"\nstatusCategory: "%s"\npriority: "Medium"\nlabels: []\nfixVersions: []\n---\n\n# HIMMEL-%s: t\n' "$1" "$2" "$1" > "$MIRROR/HIMMEL-$1.md"
}
mkey 901 Done; mkey 902 "To Do"; mkey 903 "In Progress"; mkey 910 "To Do"; mkey 911 "To Do"; mkey 912 "To Do"
PRSALL="$WORK/prs-all.json"
printf '[{"number":4401,"state":"MERGED"},{"number":4402,"state":"OPEN"},{"number":4410,"state":"MERGED"},{"number":4411,"state":"MERGED"},{"number":4412,"state":"OPEN"},{"number":4420,"state":"CLOSED"}]\n' > "$PRSALL"
LIVEQ='#4402 HELD by F2'
LIVEP='pool-disposition: HIMMEL-902 hold PR 4410'
sdoc() {
    local q="$1" l; shift
    {
        # shellcheck disable=SC2016  # the backticks are literal markdown
        printf '# chief\n\n## Live state\n\nlegs: `N1:n:t:1`\nqueue: %s\n' "$q"
        for l in "$@"; do printf '%s\n' "$l"; done
        printf 'last GO: none\n\n## Results\n- 08:00 LIVE — one\n'
    } > "$DOC"
}
srun() {
    out="$(ORPHAN_PR_CHECK_PRS_ALL="${SEAM:-$PRSALL}" bash "$OPC" --stale-report --doc "$DOC" --mirror "$MIRROR" "$@" 2>"$WORK/err")"; rc=$?
}
body() { printf '%s\n' "$out" | grep -v '^input='; }
dq() { printf 'DEAD-QUEUE\t%s\n' "$1"; }
D0='dead-queue=0
done-pool=0'

sdoc "#4401 HELD by F1 (judge owed) | $LIVEQ" "$LIVEP"
srun
check "10777 Q1 a prose-only HELD segment of a merged PR is flagged; the live segment and pool line are not" "0:$(dq '#4401 HELD by F1 (judge owed) ')
dead-queue=1
done-pool=0" "$rc:$(body)"
sdoc "#4402 HELD by F1 (judge owed)" "$LIVEP"
srun
check "10777 Q1.neg the same segment with its PR OPEN is not flagged" "0:$D0" "$rc:$(body)"

sdoc "MERGED under AV: #4410 329422b3f, #4411 1234567 | $LIVEQ" "$LIVEP"
srun
check "10777 Q2 a MERGED-under record whose #<n> are all merged is flagged; shas are ignored" "0:$(dq 'MERGED under AV: #4410 329422b3f, #4411 1234567 ')
dead-queue=1
done-pool=0" "$rc:$(body)"
sdoc "MERGED under AW: #4412 | MERGED under AX: 1234567 | MERGED under AY: #4410 HIMMEL-903 | MERGED under AZ: #4410, hold #4412"
srun
check "10777 Q2.neg an OPEN PR, no #<n>, an open key, and a later open hold each keep their record" "0:$D0" "$rc:$(body)"
sdoc "MERGED under AV: #4410, PR 4412 still open | MERGED under AV: #4410 (HIMMEL-901-F901a follow-up) | MERGED under AV: #4410 329422b3f"
srun
check "10777 Q2.amb a bare number or a glued key in a merged record keeps it; the sha record still goes" "0:$(dq ' MERGED under AV: #4410 329422b3f')
dead-queue=1
done-pool=0" "$rc:$(body)"

PL1='pool-disposition: HIMMEL-901 hold HIMMEL-900'
sdoc "$LIVEQ" "$PL1" "$LIVEP"
srun
check "10777 Q3 a pool line whose own subject is Done is flagged; the open-subject line is not" "0:$(printf 'DONE-POOL\tHIMMEL-901\t%s' "$PL1")
dead-queue=0
done-pool=1:HIMMEL-901" "$rc:$(body)"
sdoc "$LIVEQ" "$PL1" "$PL1" "$LIVEP"
srun
check "10777 Q3.dup a second identical Done pool line is flagged too" "0:$(printf 'DONE-POOL\tHIMMEL-901\t%s\nDONE-POOL\tHIMMEL-901\t%s' "$PL1" "$PL1")
dead-queue=0
done-pool=2:HIMMEL-901,HIMMEL-901" "$rc:$(body)"
sdoc "$LIVEQ" "$LIVEP"
srun
check "10777 Q3.neg an open subject whose hold target merged is released, never flagged" "0:$D0" "$rc:$(body)"

: > "$WORK/prs-empty.json"
sdoc "#4401 HELD by F1 | $LIVEQ" "$LIVEP"
SEAM="$WORK/prs-empty.json" srun
check "10777 Q4 an empty PR list: exit 3, no flag line" "3::1" "$rc:$out:$(grep -c 'orphan-pr-check: unavailable' "$WORK/err")"
mkdir -p "$WORK/ghall" "$WORK/ghslow"
cat > "$WORK/ghall/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$OPC_GH_LOG"
[ "$1 $2" != "pr list" ] || printf '[{"number":4401,"state":"MERGED"}]\n'
EOF
printf '#!/usr/bin/env bash\nsleep 30\n' > "$WORK/ghslow/gh"
chmod +x "$WORK/ghall/gh" "$WORK/ghslow/gh"
nsrun() {
    local d="$1"; shift
    : > "$WORK/gh.log"
    out="$(env -u ORPHAN_PR_CHECK_PRS -u ORPHAN_PR_CHECK_PRS_ALL PATH="$d:$PATH" OPC_GH_LOG="$WORK/gh.log" HIMMEL_QUOTA_DIR="$WORK/q-ok" "$@" \
        bash "$OPC" --stale-report --doc "$DOC" --mirror "$MIRROR" --repo "$WORK" 2>"$WORK/err")"; rc=$?
}
sdoc "HIMMEL-901 HELD by x | HIMMEL-903 HELD by y"
nsrun "$WORK/ghall" env
check "10777 Q4.nogh a head naming no #<n> makes no PR read and still judges keys" "0:0:$(dq 'HIMMEL-901 HELD by x ')
dead-queue=1
done-pool=0" "$rc:$(wc -l < "$WORK/gh.log" | tr -d ' '):$(body)"
check "10777 Q4.doc an unreadable doc: exit 3, no flag line" "3:" "$(bash "$OPC" --stale-report --doc "$WORK/no-such-doc.md" --mirror "$MIRROR" 2>/dev/null; printf '%s:' "$?")"
sdoc "#4401 HELD by F1 | $LIVEQ"
printf 'not json\n' > "$WORK/prs-bad.json"
SEAM="$WORK/prs-bad.json" srun
check "10777 Q4.json a PR list that is not JSON: exit 3, no flag line" "3:" "$rc:$out"
t0=$SECONDS
nsrun "$WORK/ghslow" env ORPHAN_PR_CHECK_TIMEOUT=2
check "10777 Q4.slow a PR read that outlasts its bound: exit 3 within 10 s, no flag line" "3::fast" "$rc:$out:$([ $((SECONDS - t0)) -lt 10 ] && echo fast || echo slow)"

sdoc "#4401 HIMMEL-901 HELD by x | $LIVEQ" "$LIVEP"
srun
check "10777 Q5 a merged PR and a Done key before the hold word flag the segment" "0:$(dq '#4401 HIMMEL-901 HELD by x ')
dead-queue=1
done-pool=0" "$rc:$(body)"
sdoc "#4401 HIMMEL-903 HELD by x | $LIVEQ"
srun
check "10777 Q5.neg an In Progress key before the hold word keeps the segment" "0:$D0" "$rc:$(body)"
sdoc "#4401 HELD until HIMMEL-903 lands | $LIVEQ"
srun
check "10777 Q5.after a key written after the hold word is not a subject (A16): the segment is flagged" "0:$(dq '#4401 HELD until HIMMEL-903 lands ')
dead-queue=1
done-pool=0" "$rc:$(body)"
sdoc "#4499 HELD by x | $LIVEQ"
srun
check "10777 Q6 a #<n> absent from the PR list is unknown and keeps the segment" "0:$D0" "$rc:$(body)"
sdoc "#4401 HIMMEL-950 HELD by x | $LIVEQ"
srun
check "10777 Q7 a key with no mirror file keeps the segment" "0:$D0" "$rc:$(body)"
sdoc "MERGED under AV: #4410 | HIMMEL-901 HELD by x" "$PL1"
srun --mirror "$WORK/no-such-mirror"
check "10777 Q7.dir no mirror dir: done-pool=?, keys unknown, a merged-only record is still flagged" "0:$(dq 'MERGED under AV: #4410 ')
dead-queue=1
done-pool=?" "$rc:$(body)"
sdoc "$LIVEQ || #4401 HELD by tail"
srun
check "10777 Q8 a dead segment after the first || is not judged" "0:$D0" "$rc:$(body)"

mkdir -p "$WORK/state-golden/workers"
printf '[{"number":102,"headRefName":"feat/himmel-222-beta","author":{"login":"yotamleo"},"isCrossRepository":false},{"number":4400,"headRefName":"fix/himmel-111-alpha","author":{"login":"yotamleo"},"isCrossRepository":false},{"number":4401,"headRefName":"chore/no-key","author":{"login":"yotamleo"},"isCrossRepository":false}]\n' > "$WORK/prs-golden.json"
golden_render() {
    local i=0 line o
    while IFS= read -r line; do
        i=$((i + 1)); write_doc "$line"
        if [ "$1" = held ]; then
            o="$(bash "$OPC" --held --doc "$DOC" 2>&1; printf 'rc=%s\n' "$?")"
        else
            o="$(TICKET_STATUS_STATE_DIR="$WORK/state-golden" ORPHAN_PR_CHECK_PRS="$WORK/prs-golden.json" bash "$OPC" --doc "$DOC" 2>&1; printf 'rc=%s\n' "$?")"
        fi
        printf '== %s\n%s\n' "$i" "$o" | sed 's/$/$/'
    done < "$GOLD/queues.txt"
}
check "10777 Q9 --held prints exactly its golden file" "$(cat "$GOLD/held.golden")" "$(golden_render held)"
check "10777 Q9 the default mode prints exactly its golden file" "$(cat "$GOLD/default.golden")" "$(golden_render default)"
write_doc 'MERGED under AZ: #4410, HELD #4412 wake=pr:4951 resume=/x.md'
check "10777 Q9.merged --held still prints a MERGED-under record that holds a hold word" "$(cat "$GOLD/held-merged.golden")" "$(bash "$OPC" --held --doc "$DOC" 2>&1)"

R10="$WORK/q10"; mkdir -p "$R10/mirror" "$R10/scratch"
cp "$MIRROR"/*.md "$R10/mirror/"; cp "$PRSALL" "$R10/prs.json"
sdoc "#4401 HELD by F1 | $LIVEQ" "$PL1" "$LIVEP"
cp "$DOC" "$R10/doc.md"
sum1="$(find "$R10" -type f -exec sha256sum {} + | sort)"
r10="$(cd "$R10/scratch" && ORPHAN_PR_CHECK_PRS_ALL="$R10/prs.json" bash "$OPC" --stale-report --doc "$R10/doc.md" --mirror "$R10/mirror" >/dev/null 2>&1; echo $?)"
sum2="$(find "$R10" -type f -exec sha256sum {} + | sort)"
check "10777 Q10 a run that flags writes no file anywhere in the fixture tree" "0:$sum1" "$r10:$sum2"

sdoc "$LIVEQ" "priority: 901 902 903" "pool-disposition: HIMMEL-901 hold HIMMEL-900" "pool-disposition: HIMMEL-902 hold HIMMEL-900" "pool-disposition: HIMMEL-903 hold HIMMEL-900"
srun
check "10777 Q11 --stale-report and priority-prune.sh --count give one verdict for 901, 902 and 903" "done-pool=1:HIMMEL-901:1/3" "$(printf '%s' "$out" | grep '^done-pool='):$(bash "$HERE/priority-prune.sh" --doc "$DOC" --mirror "$MIRROR" --count 2>/dev/null)"

W12="$WORK/q12"; mkdir -p "$W12/state" "$W12/mirror" "$W12/norel"
cp "$MIRROR"/*.md "$W12/mirror/"
cat > "$W12/gh" <<'EOF'
#!/usr/bin/env bash
case "$*" in
    *"api graphql"*)
        out=""
        for n in $(printf '%s\n' "$*" | grep -oE 'issueOrPullRequest\(number:[0-9]+\)' | grep -oE '[0-9]+'); do
            out="${out:+$out,}\"p$n\":{\"__typename\":\"PullRequest\",\"state\":\"MERGED\"}"
        done
        printf '{"data":{"repository":{%s}}}\n' "$out" ;;
    *) printf '5001\tMERGED\n' ;;
esac
EOF
cat > "$W12/tick-chain.sh" <<'EOF'
#!/usr/bin/env bash
doc="" prev=""
for a in "$@"; do case "$prev" in --doc) doc="$a" ;; esac; prev="$a"; done
[ -z "$doc" ] || bash "$Q12_TICK" --pool-holds --doc "$doc" > /dev/null
exec bash "$Q12_TICK" "$@"
EOF
chmod +x "$W12/gh" "$W12/tick-chain.sh"
sdoc "$LIVEQ" \
    'pool-disposition: HIMMEL-910 close PR 5001 merged' \
    'pool-disposition: HIMMEL-911 slice PR 5001 merged' \
    'pool-disposition: HIMMEL-912 question waits on PR 5001' \
    'pool-disposition: HIMMEL-913 ignore PR 5001' \
    'pool-disposition: himmel-914 close PR 5001'
srun
q12_dp="$(printf '%s\n' "$out" | grep -c '^DONE-POOL')"
q12_tick="$(JIRA_PROJECT_KEY=HIMMEL NEXT_DISPATCH_MIRROR="$W12/mirror" TICK_GH_CMD="$W12/gh" HIMMEL_QUOTA_DIR="$WORK/q-ok" TICK_STATE_DIR="$W12/state" \
    HIMMEL_RELEASE_STATE_DIR="$W12/norel" Q12_TICK="$HERE/tick.sh" TICK_POOL_MAX_MERGES=100000 TOKEN='' \
    bash "$W12/tick-chain.sh" --pool-stale --doc "$DOC" 2>/dev/null | grep '^STALE-DISPOSITION' | cut -d' ' -f2 | tr '\n' ',')"
check "10777 Q12 three well formed released lines: pool_stale reports each, --stale-report none; the two malformed lines are named by neither" "rc0:0:HIMMEL-910,HIMMEL-911,HIMMEL-912," "rc$rc:$q12_dp:$q12_tick"

sdoc "10397/10402 HELD by x | #4401 5599 HELD by x | HIMMEL-901-F901a HELD by x | HIMMEL-901 (see a | b) #4401 HELD | (context | #4401 HELD | more context)"
srun
check "10777 Q13 a bare number, a glued key, a split pair and a three-piece split are all kept" "0:$D0" "$rc:$(body)"
sdoc "#4401 sweeps HELD by F1 (judge owed) | $LIVEQ"
srun
check "10777 Q13.ok digit-free prose beside a gone subject is still flagged" "0:$(dq '#4401 sweeps HELD by F1 (judge owed) ')
dead-queue=1
done-pool=0" "$rc:$(body)"

sdoc "#4401 HELD by F1"
nsrun "$WORK/ghall" env ORPHAN_PR_CHECK_PRS="$PRSALL"
check "10777 Q14 only the open-list seam set: exit 3, no gh call" "3::0" "$rc:$out:$(wc -l < "$WORK/gh.log" | tr -d ' ')"
nsrun "$WORK/ghall" env
check "10777 Q14.ctl neither seam set: exactly one pr list --state all call, and the verdict" "0:1:$(dq '#4401 HELD by F1')
dead-queue=1
done-pool=0" "$rc:$(grep -c '^pr list --state all' "$WORK/gh.log"):$(body)"

sdoc "$LIVEQ" "$LIVEP"; srun
in0="$(printf '%s\n' "$out" | sed -n '$p')"
sdoc "$LIVEQ" 'pool-disposition: HIMMEL-902 hold PR 4411'; srun
in1="$(printf '%s\n' "$out" | sed -n '$p')"
sdoc '#4402 HELD by F3' "$LIVEP"; srun
in2="$(printf '%s\n' "$out" | sed -n '$p')"
sdoc "$LIVEQ" "$LIVEP"; printf -- '- 09:00 an unrelated line\n' >> "$DOC"; srun
in3="$(printf '%s\n' "$out" | sed -n '$p')"
io="$(env -u ORPHAN_PR_CHECK_PRS_ALL bash "$OPC" --stale-report --input-only --doc "$DOC" 2>/dev/null)"
check "10777 Q15 a changed pool line or queue: line changes input=; an unrelated line does not; --input-only agrees" "yes:yes:yes:yes:yes" \
    "$([ "${in0#input=}" != "$in0" ] && echo yes):$([ "$in0" != "$in1" ] && echo yes):$([ "$in0" != "$in2" ] && echo yes):$([ "$in0" = "$in3" ] && echo yes):$([ "$io" = "$in0" ] && echo yes)"

# --- chief-wait.sh: an underfilled wake adds `WAKE orphan-pr <n>` while a PR is unmapped
WAIT="${CHIEF_WAIT:-$HERE/chief-wait.sh}"
STUB="$WORK/stub"; mkdir -p "$STUB"
export STUB
# shellcheck disable=SC2016  # $STUB expands in the generated stub
printf '#!/usr/bin/env bash\ncat "$STUB/tick.line"\n' > "$STUB/tick.sh"
printf '#!/usr/bin/env bash\necho PROCEED\n' > "$STUB/bank.sh"
printf '#!/usr/bin/env bash\nexit 0\n' > "$STUB/off.sh"
printf '#!/usr/bin/env bash\nexit 2\n' > "$STUB/budget-off.sh"
printf '#!/usr/bin/env bash\nprintf "# pool=0/7,LOW\\nPOOL-EMPTY\\n"\n' > "$STUB/dispatch.sh"
# the orphan stub: orphans.out holds its UNMAPPED lines; empty means a clean read
cat > "$STUB/orphan.sh" <<'EOF'
#!/usr/bin/env bash
echo x >> "$STUB/orphan.calls"
[ ! -f "$STUB/orphan.unavailable" ] || exit 3
[ -s "$STUB/orphans.out" ] || exit 0
cat "$STUB/orphans.out"; exit 1
EOF
printf 'TICK 03:00 hb=1m workers=N1:FRESH livestate=ok procs=2 models=x ceiling=ok atq=0 suites=0alive/0dead prs=#10 bank=5h8/wk15/codex=? fill=40 tails=N1:LIVE inbox=none tick=UNKNOWN fleet=3/15 capacity=UNDERFILLED:7 gql=4000/04:00 orphans=none nonces=ok legset=ok board=ok denials=none or=skip fails=none\n' > "$STUB/tick.line"
export CHIEF_WAIT_TICK="$STUB/tick.sh" CHIEF_WAIT_USAGE="$STUB/bank.sh" CHIEF_WAIT_DISPATCH="$STUB/dispatch.sh" CHIEF_WAIT_ORPHAN="$STUB/orphan.sh"
export CHIEF_WAIT_INTERVAL=1 CHIEF_WAIT_POLL_SEC=0.2 CHIEF_WAIT_FAIL_WAKE=1000 CHIEF_WAIT_ORPHAN_SAMPLE_MIN=0
export CHIEF_WAIT_PAGE_CMD="$STUB/off.sh" CHIEF_WAIT_BUDGET="$STUB/budget-off.sh" WAIT_SWEEP_CMD="$STUB/off.sh" WAIT_FOCUS_CMD="$STUB/off.sh"
export HIMMEL_DENIAL_ACK_DIR="$WORK/acks"
mkdir -p "$WORK/bridge/consoles"; INBOX="$WORK/bridge/consoles/c.md"; : > "$INBOX"
write_doc "none"
arm() { timeout "$2" bash "$WAIT" "$INBOX" --workers N1.md --doc "$DOC" > "$1" 2>/dev/null; wrc=$?; }  # gnu-ok: Linux-only kit

printf 'UNMAPPED 4325 fix/himmel-8288-orphan\n' > "$STUB/orphans.out"
arm "$WORK/w1.out" 20
check "waiter: the first underfilled wake exits 0" "0" "$wrc"
check "waiter: the underfilled streak's first sample still wakes underfilled" "WAKE underfilled" "$(head -n1 "$WORK/w1.out" | cut -c1-16)"
arm "$WORK/w2.out" 20
check "waiter: the orphan wake exits 0" "0" "$wrc"
check "waiter: the next underfilled sample wakes orphan-pr naming the PR" "WAKE orphan-pr 4325" "$(head -n1 "$WORK/w2.out")"
check "waiter: the wake carries the UNMAPPED line" "1" "$(grep -c '^UNMAPPED 4325 fix/himmel-8288-orphan$' "$WORK/w2.out")"
arm "$WORK/w3.out" 4
check "waiter: the same orphan set does not re-wake inside the window" "" "$(cat "$WORK/w3.out")"
check "waiter: the quiet arm was still running when its timeout fired" "124" "$wrc"
printf 'UNMAPPED 4325 fix/himmel-8288-orphan\nUNMAPPED 4400 fix/himmel-9000-new\n' > "$STUB/orphans.out"
arm "$WORK/w4.out" 20
check "waiter: the joining-PR wake exits 0" "0" "$wrc"
check "waiter: a PR joining the orphan set wakes at once" "WAKE orphan-pr 4325,4400" "$(head -n1 "$WORK/w4.out")"
: > "$STUB/orphans.out"
: > "$STUB/orphan.unavailable"
calls_before="$(wc -l < "$STUB/orphan.calls")"
arm "$WORK/w4u.out" 4
check "waiter: an unavailable read stays quiet until the timeout (rc 124)" "124" "$wrc"
check "waiter: an unavailable read prints no wake" "" "$(cat "$WORK/w4u.out")"
check "waiter: the unavailable arm ran the check" "yes" "$([ "$(wc -l < "$STUB/orphan.calls")" -gt "$calls_before" ] && echo yes || echo no)"
check "waiter: an unavailable read keeps the marker" "yes" "$([ -e "$INBOX.wait.orphan" ] && echo yes || echo no)"
rm -f "$STUB/orphan.unavailable"
arm "$WORK/w5.out" 4
check "waiter: a clean read clears the marker" "no" "$([ -e "$INBOX.wait.orphan" ] && echo yes || echo no)"

[ "$fails" -eq 0 ] || { echo "FAILED: $fails"; exit 1; }
echo "ALL PASS"
