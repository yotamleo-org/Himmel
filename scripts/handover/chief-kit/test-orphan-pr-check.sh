#!/usr/bin/env bash
# test-orphan-pr-check.sh — Exercises orphan-pr-check.sh: every open PR's head
# branch must map to a live worker doc in the fleet manifest or to a hold on the chief doc's
# `queue:` line; each orphan prints `UNMAPPED <n> <branch>` and the exit is non-zero.
# The `gh pr list --json number,headRefName` output comes from a fixture file
# (ORPHAN_PR_CHECK_PRS). bash 3.2-safe.
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

W_LIVE="$WORK/HIMMEL-111-N1-alpha-2026-11-01.md"
W_DONE="$WORK/HIMMEL-444-N2-delta-2026-11-01.md"
printf '# worker\n## Results\n- 10:00 LIVE — started\n' > "$W_LIVE"
printf '# worker\n## Results\n- 10:00 LIVE — started\n- 11:00 WRAPPED — released the lock\n' > "$W_DONE"

DOC="$WORK/HIMMEL-nextleg-2026-11-01A-chief.md"
write_doc() { # <queue line value>
    # shellcheck disable=SC2016  # the backticks are literal markdown
    printf '# chief\n\n## Live state\n\nlegs: `N1:n:t:1`\nqueue: %s\nlast GO: none\n\n## Results\n- 08:00 LIVE — one\n' "$1" > "$DOC"
}
printf '{"schema":1,"workers":[{"doc":"%s","label":"N1"},{"doc":"%s","label":"N2"}]}\n' "$W_LIVE" "$W_DONE" > "${DOC%.md}.fleet.json"

PRS="$WORK/prs.json"
prs() { # <number branch>... — write the gh fixture
    local sep="" out="["
    while [ "$#" -ge 2 ]; do out="$out$sep{\"number\":$1,\"headRefName\":\"$2\"}"; sep=","; shift 2; done
    printf '%s]\n' "$out" > "$PRS"
}
run() { # sets rc and out
    out="$(ORPHAN_PR_CHECK_PRS="$PRS" bash "$OPC" --doc "$DOC" 2>"$WORK/err")"; rc=$?
}

# --- an orphan: no manifest worker, no queue hold (RED on main: no check exists)
write_doc "none"
prs 103 "fix/himmel-333-gamma"
run
check "orphan: exits 1" "1" "$rc"
check "orphan: names the PR and its branch" "UNMAPPED 103 fix/himmel-333-gamma" "$out"

# --- a PR whose branch names a live manifest worker's ticket
prs 101 "fix/himmel-111-alpha"
run
check "mapped to a live manifest worker: exits 0" "0" "$rc"
check "mapped to a live manifest worker: prints nothing" "" "$out"

# --- a PR held on the queue: line, by ticket key and by PR number
write_doc "HIMMEL-222, hold"
prs 102 "feat/himmel-222-beta"
run
check "queue-held by ticket key: exits 0" "0" "$rc"
write_doc "#102 (adapter merge)"
run
check "queue-held by PR number: exits 0" "0" "$rc"
write_doc "none"
run
check "the same PR with the hold gone is unmapped" "UNMAPPED 102 feat/himmel-222-beta" "$out"

# --- a hold on another PR whose number merely contains this one does not map it
write_doc "#1020, HIMMEL-2222"
run
check "a longer number or key does not hold the PR" "1" "$rc"

# --- a WRAPPED worker is not live: its open PR is the orphan
write_doc "none"
prs 104 "fix/himmel-444-delta"
run
check "WRAPPED worker with an open PR: exits 1" "1" "$rc"
check "WRAPPED worker with an open PR: names it" "UNMAPPED 104 fix/himmel-444-delta" "$out"

# --- several PRs: only the orphans print, in order
prs 101 "fix/himmel-111-alpha" 103 "fix/himmel-333-gamma" 105 "chore/no-key"
run
check "mixed set: one line per orphan" "UNMAPPED 103 fix/himmel-333-gamma
UNMAPPED 105 chore/no-key" "$out"

# --- no open PR
prs
run
check "no open PR: exits 0" "0" "$rc"

# --- an unreadable PR list is not an orphan
rm -f "$PRS"
run
check "unavailable PR list: exits 3, neither an orphan nor an all-clear" "3" "$rc"
check "unavailable PR list: says so on stderr" "1" "$(grep -c 'unavailable' "$WORK/err")"

# --- an unreadable manifest is unavailable too, never "no worker holds this PR"
prs 101 "fix/himmel-111-alpha"
printf 'not json\n' > "${DOC%.md}.fleet.json"
run
check "unreadable manifest: exits 3" "3" "$rc"
printf '{"schema":1,"workers":[{"doc":"%s","label":"N1"},{"doc":"%s","label":"N2"}]}\n' "$W_LIVE" "$W_DONE" > "${DOC%.md}.fleet.json"

# --- --workers-from names another manifest
other="$WORK/other.fleet.json"
printf '{"schema":1,"workers":[]}\n' > "$other"
prs 101 "fix/himmel-111-alpha"
out="$(ORPHAN_PR_CHECK_PRS="$PRS" bash "$OPC" --doc "$DOC" --workers-from "$other" 2>/dev/null)"; rc=$?
check "--workers-from: an empty manifest leaves the PR unmapped" "UNMAPPED 101 fix/himmel-111-alpha" "$out"

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
arm() { timeout "$2" bash "$WAIT" "$INBOX" --workers N1.md --doc "$DOC" > "$1" 2>/dev/null; }  # gnu-ok: Linux-only kit

printf 'UNMAPPED 4325 fix/himmel-8288-orphan\n' > "$STUB/orphans.out"
arm "$WORK/w1.out" 20
check "waiter: the underfilled streak's first sample still wakes underfilled" "WAKE underfilled" "$(head -n1 "$WORK/w1.out" | cut -c1-16)"
arm "$WORK/w2.out" 20
check "waiter: the next underfilled sample wakes orphan-pr naming the PR" "WAKE orphan-pr 4325" "$(head -n1 "$WORK/w2.out")"
check "waiter: the wake carries the UNMAPPED line" "1" "$(grep -c '^UNMAPPED 4325 fix/himmel-8288-orphan$' "$WORK/w2.out")"
arm "$WORK/w3.out" 4
check "waiter: the same orphan set does not re-wake inside the window" "" "$(cat "$WORK/w3.out")"
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
