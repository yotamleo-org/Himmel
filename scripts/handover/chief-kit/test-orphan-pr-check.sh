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
write_doc "HIMMEL-222, hold"
prs "$(pr 102 feat/himmel-222-beta)"
run
check "queue-held by ticket key: exits 0" "0" "$rc"
write_doc "#102 (adapter merge)"
run
check "queue-held by PR number: exits 0" "0" "$rc"
write_doc "none"
run
check "the same PR with the hold gone is unowned" "UNMAPPED 102 feat/himmel-222-beta" "$out"
write_doc "#1020, HIMMEL-2222"
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
check "waiter: the underfilled streak's first sample still wakes underfilled" "WAKE underfilled" "$(head -n1 "$WORK/w1.out" | cut -c1-16)"
arm "$WORK/w2.out" 20
check "waiter: the next underfilled sample wakes orphan-pr naming the PR" "WAKE orphan-pr 4325" "$(head -n1 "$WORK/w2.out")"
check "waiter: the wake carries the UNMAPPED line" "1" "$(grep -c '^UNMAPPED 4325 fix/himmel-8288-orphan$' "$WORK/w2.out")"
arm "$WORK/w3.out" 4
check "waiter: the same orphan set does not re-wake inside the window" "" "$(cat "$WORK/w3.out")"
check "waiter: the quiet arm was still running when its timeout fired" "124" "$wrc"
printf 'UNMAPPED 4325 fix/himmel-8288-orphan\nUNMAPPED 4400 fix/himmel-9000-new\n' > "$STUB/orphans.out"
arm "$WORK/w4.out" 20
check "waiter: a PR joining the orphan set wakes at once" "WAKE orphan-pr 4325,4400" "$(head -n1 "$WORK/w4.out")"
: > "$STUB/orphans.out"
: > "$STUB/orphan.unavailable"
arm "$WORK/w4u.out" 4
check "waiter: an unavailable read keeps the marker" "yes" "$([ -e "$INBOX.wait.orphan" ] && echo yes || echo no)"
rm -f "$STUB/orphan.unavailable"
arm "$WORK/w5.out" 4
check "waiter: a clean read clears the marker" "no" "$([ -e "$INBOX.wait.orphan" ] && echo yes || echo no)"

[ "$fails" -eq 0 ] || { echo "FAILED: $fails"; exit 1; }
echo "ALL PASS"
