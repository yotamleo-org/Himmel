#!/usr/bin/env bash
# test-board.sh — Hermetic tests for board.mjs, the generator of the
# console's progress board (console-board.html). tick.sh and gh are stubbed (a
# BOARD_TICK override and a PATH stub), so the suite reads no queue, process,
# scheduler or GitHub state. The board<->tick freshness round trip (board.mjs
# output read back by the REAL tick.sh) is pinned in test-tick.sh, where the tick
# stubs already live.
#
# PLATFORM GUARD: no .ps1 twin, by design. The console kit is Linux-only (tick.sh
# reads pgrep, atq and the konsole launch logs); this suite exercises a kit script.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="$HERE/board.mjs"
if ! command -v node >/dev/null 2>&1; then
    printf 'SKIP - test-board.sh (node not installed)\n'
    exit 0
fi
W="$(mktemp -d "${TMPDIR:-/tmp}/board-test.XXXXXX")" || exit 1
trap 'rm -rf "$W"' EXIT
fails=0

pass() { printf 'ok - %s\n' "$1"; }
fail() { printf 'FAIL - %s\n' "$1"; fails=$((fails + 1)); }
contains() {
    case "$2" in *"$3"*) pass "$1" ;; *) fail "$1 (missing '$3')" ;; esac
}
lacks() {
    case "$2" in *"$3"*) fail "$1 (found '$3')" ;; *) pass "$1" ;; esac
}
same() {
    if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (got '$2', want '$3')"; fi
}

B="$W/bucket"
mkdir -p "$B" "$W/bin" "$W/repo"
# the failures panel reads these ledgers; never the operator's own.
export HIMMEL_LEG_FAILURES_LEDGER="$W/leg-failures.jsonl" HIMMEL_FAILURE_ROUTES_LOG="$W/failure-routes.log.jsonl" HIMMEL_EVAL_RUNS_LEDGER="$W/eval-runs.jsonl"
# the bank lift row reads the lift's `show` output through this stub,
# never the operator's lift file or account. BANK_LIFT_STUB_OUT is a fixture file
# of `show` output; unset prints the no-lift output.
cat > "$W/bin/bank-lift-stub" <<'STUB'
#!/usr/bin/env bash
[ "$1" = show ] || exit 2
if [ -n "${BANK_LIFT_STUB_OUT:-}" ]; then cat "$BANK_LIFT_STUB_OUT"; else printf 'bank-lift: none\nbank-lift: INVALID: missing\n'; fi
STUB
chmod +x "$W/bin/bank-lift-stub"
export BOARD_BANK_LIFT="$W/bin/bank-lift-stub"
# Session transcripts (console cost, succession eval) come from BOARD_TRANSCRIPTS: an
# empty dir here, so no row ever reads the operator's own ~/.claude/projects.
mkdir -p "$W/tx-none"
export BOARD_TRANSCRIPTS="$W/tx-none"
# the CR-loop line reads the CR ledger and the Jira mirror; never the operator's own.
export CR_LEDGER="$W/no-cr-ledger.jsonl" BOARD_MIRROR="$W/no-mirror"
# the overdue-classes panel reads known-findings.sh --ladder; never the live ledger.
export BOARD_KNOWN_FINDINGS="$W/bin/no-known-findings"

# The tick stub records its argv and prints a fixed line + fingerprint. N1..N7
# cover every phase; the fleet is 9/15 with six idle slots. N12 (issue #1336):
# tail=FINDING with a lock reported lost at the same time -- the tick reports
# both independently of any leg-doc prose.
cat > "$W/bin/tick-stub" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" > "$TICK_ARGV_LOG"
[ "${TICK_STUB_FAIL:-0}" -eq 0 ] || exit 1
printf '%s\n' 'TICK 12:34 hb=skip legs=N1:FRESH,N2:FRESH,N3:FRESH,N4:FRESH,N5:WRAPPED,N6:FRESH,N7:FRESH,N12:STALE livestate=ok procs=6 models=sonnet:6 ceiling=ok atq=0 suites=0alive/0dead prs=#2001,#2002 bank=5h8/wk42/codex=? fill=28 tails=N1:LIVE,N2:LIVE,N3:READY,N4:LIVE,N5:WRAPPED,N6:READY,N7:BLOCKED,N12:FINDING inbox=none tick=UNKNOWN fleet='"${TICK_STUB_FLEET:-9/15}"' capacity=UNDERFILLED:6 gql=4321/13:00 orphans=none nonces=ok legset=ok board=MISSING'
printf '%s\n' 'board-fp=deadbeefdeadbeef'
STUB
chmod +x "$W/bin/tick-stub"

# gh stub: open PRs, merged PRs (this shift, and the per-epic search) and per-PR
# `pr view` state from files.
cat > "$W/bin/gh" <<'STUB'
#!/usr/bin/env bash
[ -z "${GH_CWD_LOG:-}" ] || pwd -P >> "$GH_CWD_LOG"
case "$*" in
    "pr view "*) [ -f "$GH_VIEW/$3.json" ] && cat "$GH_VIEW/$3.json" || exit 1 ;;
    *"--state open"*) cat "$GH_OPEN" ;;
    *"--state merged"*"in:title"*) cat "$GH_EPIC" ;;
    *"--state merged"*) cat "$GH_MERGED" ;;
    *) exit 1 ;;
esac
STUB
chmod +x "$W/bin/gh"

# Sessions stub (Ask 3): sourced, then claude_sessions() is called, same as
# board.mjs invokes the real claude-sessions.sh. Empty by default -- no window is ever
# "still open" unless a test explicitly points BOARD_SESSIONS elsewhere. Never the real
# process census.
cat > "$W/bin/sessions-empty.sh" <<'STUB'
claude_sessions() { :; }
STUB

cat > "$W/open.json" <<'JSON'
[
 {"number":2001,"title":"feat(x): [HIMMEL-3332] slice S3","headRefName":"feat/himmel-3332-s3","isDraft":false,
  "statusCheckRollup":[{"conclusion":"SUCCESS","status":"COMPLETED"},{"conclusion":"SUCCESS","status":"COMPLETED"},{"state":"SUCCESS"}]},
 {"number":2002,"title":"feat(y): [HIMMEL-3340] verdict bar","headRefName":"feat/himmel-3340-bar","isDraft":false,
  "statusCheckRollup":[{"conclusion":"FAILURE","status":"COMPLETED"},{"conclusion":"","status":"IN_PROGRESS"}]},
 {"number":2003,"title":"feat(v): [HIMMEL-3380] no checks yet","headRefName":"feat/himmel-3380","isDraft":false,"statusCheckRollup":[]}
]
JSON
cat > "$W/merged.json" <<'JSON'
[
 {"number":1990,"title":"feat(z): [HIMMEL-3332] S1","mergedAt":"2026-09-21T09:00:00Z","headRefName":"feat/himmel-3332-s1"},
 {"number":1995,"title":"fix(w): [HIMMEL-3348] harden","mergedAt":"2026-09-21T10:00:00Z","headRefName":"fix/himmel-3348"}
]
JSON
cat > "$W/epic.json" <<'JSON'
[
 {"number":1990,"title":"feat(z): [HIMMEL-3332] S1"},
 {"number":1985,"title":"feat(z): [HIMMEL-3332] S2"},
 {"number":1500,"title":"docs: mentions HIMMEL-3332 in passing, not the cited key"}
]
JSON

# `gh pr view` answers for PRs the merged-this-shift panel does not list: 1700 merged
# long ago (outside the 24 h window), 1701 closed unmerged.
mkdir -p "$W/view"
printf '%s\n' '{"state":"MERGED"}' > "$W/view/1700.json"
printf '%s\n' '{"state":"CLOSED"}' > "$W/view/1701.json"

# Leg docs: the ticket key is the doc's leading token, the label its N<k>.
mkleg() {  # mkleg <name> <bullet>...
    local name="$1"; shift
    printf '%s\n' '# leg' '## Results' "$@" > "$B/$name-2026-09-21-RESUME.md"
}
# A lock token that straddles the 130-char clip must not survive as a fragment.
pad190="$(printf '%190s' '' | tr ' ' x)"
mkleg HIMMEL-3340-N1-alpha "- 12:00 LIVE — working ${pad190:0:93} lock cachyos-x8664-pid424242 after"
# A later section's bullet naming another (merged) PR must not overwrite the leg's PR.
printf '%s\n' '# leg' '## Results' '- 12:00 LIVE — PR 2002 open, watching CI' '' '## Notes' \
    '- 13:00 unrelated later-section bullet: see PR 1990 merged' \
    > "$B/HIMMEL-3340-N2-beta-2026-09-21-RESUME.md"
mkleg HIMMEL-3332-N3-gamma '- 12:00 LIVE — building' '- 12:10 READY 2001 0123456789abcdef GREEN'
mkleg HIMMEL-3348-N4-delta '- 12:00 MERGED #1995 → 0123abc'
mkleg HIMMEL-3300-N5-eps '- 12:00 WRAPPED — released'
mkleg HIMMEL-3350-N6-zeta '- 12:00 READY-TO-OPEN — /pr-check clean, not opened'
mkleg HIMMEL-3351-N7-eta '- 12:00 BLOCKED — the push was refused <script>alert(1)</script>'
mkleg HIMMEL-3370-N8-theta '- 12:00 LIVE — PR 1700 open, watching CI'
mkleg HIMMEL-3371-N9-iota '- 12:00 LIVE — PR 1701 open, watching CI'
# a bullet that merely CITES a PR is not the leg's PR. N10 has no PR of
# its own, so it keeps its phase; a citation in any form (#n, PR #n, PR n merged, a
# /pull/ URL) attributes nothing.
mkleg HIMMEL-3377-N10-lambda '- 12:00 LIVE — working' '- 12:20 FINDING scope-shrunk — #1995 (HIMMEL-3348, in the base) already shipped; see PR #1995 merged, PR 1995 merged, https://github.com/o/r/pull/1995'
mkleg HIMMEL-3378-N11-mu '- 12:00 LIVE — building; PR 1995 merged upstream, so #1995 is in the base'
# Regression (issue #1336): a leg whose LAST line is a long FINDING must not hide a
# lost/stale lock reported by the tick at the same time. The tick line above marks
# N12 tail=FINDING, lock=STALE; board.mjs must surface both, not just the FINDING.
pad180="$(printf '%180s' '' | tr ' ' q)"
mkleg HIMMEL-3379-N12-xi '- 12:00 LIVE — working' "- 12:30 FINDING ${pad180} needs a ruling"
# Two docs share a label; Live state names one by doc stem (N18) or by nonce (N19).
# The newer-by-mtime doc is the wrong one in both.
mkleg HIMMEL-3375-N18-iota '- 12:00 LIVE — the right doc'
mkleg HIMMEL-9998-N18-other '- 12:00 LIVE — a previous shift reused this label'
# shellcheck disable=SC2016  # backtick token, literal fixture text
printf '%s\n' '# leg' '> RETASK token `V-N19-cafe1919`' '## Results' '- 12:00 LIVE — the right doc' \
    > "$B/HIMMEL-3376-N19-kappa-2026-09-21-RESUME.md"
# The wrong doc quotes a LONGER token that merely starts with the entry nonce.
# shellcheck disable=SC2016  # backtick token, literal fixture text
mkleg HIMMEL-9997-N19-old '- 12:00 LIVE — a previous shift reused this label, token `V-N19-cafe1919zz`'
touch -d '2 hours ago' "$B/HIMMEL-3375-N18-iota-2026-09-21-RESUME.md" "$B/HIMMEL-3376-N19-kappa-2026-09-21-RESUME.md"  # gnu-ok: console kit is Linux-only

# The console doc: legs carry nonces + lock tokens (which must never reach the
# board); a Results bullet quotes both again in prose.
DOC="$B/HIMMEL-nextleg-2026-09-21V-console.md"
# shellcheck disable=SC2016  # backtick leg spans, literal fixture text
printf '%s\n' '# console' '' '## Live state' '' \
    'legs: `N1:V-N1-aaaa1111:cachyos-x8664-pid111111:111`' \
    '  `N2:V-N2-bbbb2222:cachyos-x8664-pid222222:222`' \
    '  `N3:V-N3-cccc3333:cachyos-x8664-pid333333:333`' \
    '  `N4:V-N4-dddd4444:cachyos-x8664-pid444444:444`' \
    '  `N5:V-N5-9999aaaa:cachyos-x8664-pid555555:555`' \
    '  `N6:V-N6-eeee5555:cachyos-x8664-pid666666:666`' \
    '  `N7:V-N7-ffff6666:cachyos-x8664-pid777777:777`' \
    '  `N8:V-N8-aaaa0808:cachyos-x8664-pid808080:808`' \
    '  `N9:V-N9-bbbb0909:cachyos-x8664-pid909090:909`' \
    '  `N10:V-N10-aaaa1010:cachyos-x8664-pid101010:1010`' \
    '  `N11:V-N11-bbbb1111:cachyos-x8664-pid111011:1011`' \
    '  `N12:V-N12-aaaa1212:cachyos-x8664-pid121212:1212`' \
    '  `N16_x.y-z:V-N16-aaaa1616:cachyos-x8664-pid161616:1616`' \
    '  `N15:V-N15-aaaa1515:cachyos-x8664-pid151515`' \
    '  `N17:V-N17-aaaa1717::1717`' \
    '  `HIMMEL-3375-N18-iota-2026-09-21-RESUME:V-N18-aaaa1818:cachyos-x8664-pid181818:1818`' \
    '  `N19:V-N19-cafe1919:cachyos-x8664-pid191919:1919`' \
    '- detail `N13:V-N13-aaaa1313:cachyos-x8664-pid131313:1313` is under the block, not in it' \
    'queue: N1 (3340), N2 (3340)' \
    'last GO: `1022:a87f5d946d8b4002ae9641864f82cffb1ac8a4b7`' \
    'acked: none' \
    'epics: HIMMEL-3332=4' \
    'decisions: ship the Telegram bridge restart?; widen the fleet cap to 20?' \
    '' '## Results (newest at the bottom)' \
    '- DISPATCH N1 — token `V-N1-aaaa1111`, lock `cachyos-x8664-pid111111`, window 5' \
    '- lock cachyos-x8664-pid830420 was released at wrap; the console doc alone keeps it' \
    '- DISPATCH AA-N1 — nonce AA-N1-abcdef12, stem form AB-HIMMEL-3340-N1-alpha-cafe0123 (two-letter consoles)' \
    '- RULING <b>bold</b> & ampersand' \
    > "$DOC"

run() {  # run <extra args...> -- prints board.mjs stdout; rc in $rc
    PATH="$W/bin:$PATH" BOARD_TICK="$W/bin/tick-stub" TICK_ARGV_LOG="$W/argv.log" \
        BOARD_SESSIONS="${BOARD_SESSIONS:-$W/bin/sessions-empty.sh}" \
        GH_OPEN="${BOARD_TEST_GH_OPEN:-$W/open.json}" GH_MERGED="$W/merged.json" GH_EPIC="$W/epic.json" GH_VIEW="$W/view" \
        node "$SUT" --doc "$DOC" --repo "$W/repo" "$@" 2>"$W/stderr.log"
}

out="$(run)"; rc=$?
board="$B/console-board.html"
if [ "$rc" -eq 0 ] && [ "$out" = "$board" ] && [ -f "$board" ]; then
    pass 'prints the path of console-board.html written next to the console doc'
else
    fail "board path (rc=$rc out='$out' stderr=$(cat "$W/stderr.log" 2>/dev/null))"
fi
html="$(cat "$board" 2>/dev/null)"
# a healthy lookup warns of nothing (the failure cases are pinned below).
lacks 'a healthy label lookup prints no stderr warning (HIMMEL-3369)' "$(cat "$W/stderr.log")" 'leg labels unavailable'
lacks 'a healthy label lookup renders no unavailable banner (HIMMEL-3369)' "$html" 'labels-unavailable'

# --- secrets: a board is published to a URL, so no nonce or lock token may reach it
for secret in aaaa1111 bbbb2222 cccc3333 dddd4444 eeee5555 ffff6666 pid111111 pid222222 pid333333 pid830420 pid4242 'V-N1-' 'x8664' abcdef12 cafe0123 'AA-N1-' aaaa0808 bbbb0909 aaaa1616 aaaa1313 aaaa1818 cafe1919 pid808080 pid181818 aaaa1212 pid121212; do
    lacks "no nonce/lock-token text in the board: $secret" "$html" "$secret"
done
contains 'the legs are named by label' "$html" 'data-label="N3"'

# --- escaping: leg bullets and Results are prose from other sessions
lacks 'a <script> in a leg bullet is escaped' "$html" '<script>alert(1)'
contains 'the escaped script text is still visible' "$html" '&lt;script&gt;alert(1)'
lacks 'a <b> in a Results bullet is escaped' "$html" '<b>bold</b>'

# --- phases: LIVE -> READY-TO-OPEN -> PR open -> READY -> MERGED -> WRAPPED
contains 'no PR, no marker: LIVE' "$html" 'data-label="N1" data-phase="LIVE"'
contains 'an open PR the leg names: PR open' "$html" 'data-label="N2" data-phase="PR open"'
contains 'READY tail + open PR: READY' "$html" 'data-label="N3" data-phase="READY"'
contains 'the leg names a merged PR: MERGED (archive)' "$(cat "$B/console-board-archive.html")" 'N4 HIMMEL-3348 MERGED'
contains 'a FINDING bullet citing a merged PR keeps its phase and gets no PR (HIMMEL-3374)' "$html" '<b>N10</b> <span class="tk">HIMMEL-3377</span> <span class="ph">LIVE</span><p>'
contains 'a LIVE bullet citing a merged PR gets no PR either (HIMMEL-3374)' "$html" '<b>N11</b> <span class="tk">HIMMEL-3378</span> <span class="ph">LIVE</span><p>'
contains 'lock released + WRAPPED tail: WRAPPED (archive)' "$(cat "$B/console-board-archive.html")" 'N5 HIMMEL-3300 WRAPPED'
contains 'READY tail with no PR anywhere: READY-TO-OPEN' "$html" 'data-label="N6" data-phase="READY-TO-OPEN"'
contains 'a CI-red PR is flagged on its leg' "$html" 'data-ci="failing"'
contains 'a green PR (check runs + a commit status) reads green' "$html" 'data-label="N3" data-phase="READY" data-ci="green"'
contains 'the phase ladder counts legs per phase' "$html" 'data-ladder="READY" data-count="1"'

# --- attention: what needs the console, and the operator's own decisions
contains 'a BLOCKED leg is listed as needing the console' "$html" 'data-need="N7"'
contains 'a READY leg awaits GO' "$html" 'data-need="N3"'
contains 'a READY-TO-OPEN leg awaits the console' "$html" 'data-need="N6"'
# Regression (issue #1336): a long FINDING tail must not hide a lock the tick
# reports lost in the same tick line. RED before the fix: board.mjs checked
# tail === 'FINDING' before lostLock, so the lock text never rendered.
contains 'a FINDING leg with a lost lock still shows the lock (issue #1336)' "$html" '<b>N12</b> FINDING — needs a ruling · lock STALE — lost or stale'
contains 'the Live-state decisions: line renders as open operator decisions' "$html" 'widen the fleet cap to 20?'
# orphans-wip=: in-work tickets nobody holds are listed under the supervisor panel.
cat > "$W/bin/tick-stub-ow" <<'STUB'
#!/usr/bin/env bash
"$(dirname "$0")/tick-stub" "$@" | sed "s/^TICK .*/& orphans-wip=$TICK_STUB_OW/"
STUB
chmod +x "$W/bin/tick-stub-ow"
run_ow() {  # run_ow <orphans-wip value> -- the rendered board html
    PATH="$W/bin:$PATH" BOARD_TICK="$W/bin/tick-stub-ow" TICK_STUB_OW="$1" TICK_ARGV_LOG="$W/argv-ow.log" \
        BOARD_SESSIONS="$W/bin/sessions-empty.sh" \
        GH_OPEN="$W/open.json" GH_MERGED="$W/merged.json" GH_EPIC="$W/epic.json" GH_VIEW="$W/view" \
        node "$SUT" --doc "$DOC" --repo "$W/repo" --out "$W/ow-board.html" >/dev/null 2>"$W/stderr.log"
    cat "$W/ow-board.html"
}
ow_panel() { printf '%s\n' "$1" | sed -n '/Needs the supervisor session/,/<\/section>/p'; }
ow_html="$(run_ow '2:HIMMEL-901,HIMMEL-902')"
contains 'an orphaned in-work ticket is listed under Needs the supervisor session' "$(ow_panel "$ow_html")" 'data-orphan="HIMMEL-901"'
contains 'every named orphan is listed' "$(ow_panel "$ow_html")" 'data-orphan="HIMMEL-902"'
ow_html="$(run_ow 6)"
contains 'an orphan count above five reads as a count line' "$(ow_panel "$ow_html")" 'data-orphans="6"'
ow_html="$(run_ow 0)"
lacks 'zero orphans adds no orphan row' "$(ow_panel "$ow_html")" 'data-orphan'
ow_html="$(run_ow '?')"
lacks 'an unknown orphan read adds no orphan row' "$(ow_panel "$ow_html")" 'data-orphan'
# a ';' inside parentheses does not split a decision.
DOCD="$B/HIMMEL-nextleg-2026-09-21V-console-d.md"
sed 's/^decisions: .*/decisions: A (x; y); B?/' "$DOC" > "$DOCD"  # gnu-ok: console kit is Linux-only
PATH="$W/bin:$PATH" BOARD_TICK="$W/bin/tick-stub" TICK_ARGV_LOG="$W/argv-d.log" \
    BOARD_SESSIONS="$W/bin/sessions-empty.sh" \
    GH_OPEN="$W/open.json" GH_MERGED="$W/merged.json" GH_EPIC="$W/epic.json" GH_VIEW="$W/view" \
    node "$SUT" --doc "$DOCD" --repo "$W/repo" --out "$W/d-board.html" >/dev/null 2>"$W/stderr.log"
dpanel="$(sed -n '/Open operator decisions/,/<\/section>/p' "$W/d-board.html")"
same 'a parenthetical ; keeps one decision whole: exactly two items (HIMMEL-3944)' "$(printf '%s\n' "$dpanel" | grep -c '<li>')" '2'
contains 'the parenthetical decision renders whole (HIMMEL-3944)' "$dpanel" '<li>A (x; y)</li>'

# --- epics: merged/total from the declared total + the merged PRs citing the key
contains 'a declared epic shows merged/total' "$html" 'data-epic="HIMMEL-3332" data-merged="2" data-total="4"'
lacks 'a PR that only mentions the key in prose is not counted' "$html" 'data-merged="3"'

# --- fleet: N/cap with idle capacity highlighted
contains 'fleet renders N/cap' "$html" 'data-fleet="9/15"'
contains 'idle capacity is highlighted' "$html" 'data-idle="6"'

# --- merged this shift + fingerprint + title
contains 'merged PRs this shift are listed in the archive' "$(cat "$B/console-board-archive.html")" 'PR #1995 merged'
contains 'the tick fingerprint is embedded for tick.sh board=' "$html" '<meta name="console-board-fp" content="deadbeefdeadbeef">'
contains 'the page has a name title, not a summary' "$html" '<title>Supervisor Session Board</title>'
contains 'the page themes for dark mode' "$html" 'prefers-color-scheme: dark'

# --- tick input: the console's own arm (absolute leg docs), no token, no heartbeat
argv="$(cat "$W/argv.log" 2>/dev/null)"
contains 'tick is asked for the fingerprint' "$argv" '--emit-fp'
contains 'tick reads the console doc' "$argv" "--doc $DOC"
contains 'leg docs are discovered by label from the bucket' "$argv" "$B/HIMMEL-3332-N3-gamma-2026-09-21-RESUME.md"
lacks 'a board render never passes the console token (no heartbeat)' "$argv" '--token'
run --legs "$B/HIMMEL-3340-N1-alpha-2026-09-21-RESUME.md" >/dev/null
contains 'an explicit --legs is passed through, not re-discovered' "$(cat "$W/argv.log")" "--legs $B/HIMMEL-3340-N1-alpha-2026-09-21-RESUME.md"
lacks 'an explicit --legs is not widened by discovery' "$(cat "$W/argv.log")" 'N3-gamma'

# --- degraded: a failing tick still leaves a board, marked as such (fp empty)
out="$(TICK_STUB_FAIL=1 run)"; rc=$?
contains 'a failing tick still renders a board (rc 0)' "rc=$rc" 'rc=0'
contains 'and says the tick was unavailable' "$(cat "$board")" 'tick unavailable'
lacks 'and embeds no fingerprint that would read ok' "$(cat "$board")" 'name="console-board-fp" content="deadbeef'

# --- the follow-ups deferred from the first board
# Results parse is section-bounded: a later section's bullet is not the leg's Results.
lacks "a later section's bullet is not the leg's last Results bullet" "$html" 'unrelated later-section'
# Merged detection reads the PR itself, not the 24 h merged panel.
contains 'a PR merged outside the 24 h panel still reads MERGED (gh pr view, archive)' "$(cat "$B/console-board-archive.html")" 'N8 HIMMEL-3370 MERGED'
contains 'a closed-unmerged PR does not read MERGED' "$html" 'data-label="N9" data-phase="LIVE"'
# READY-TO-OPEN says what it is waiting for, not "lost lock".
contains 'a READY-TO-OPEN leg is explained as awaiting the PR open' "$html" 'awaiting PR open'
lacks 'a READY-TO-OPEN leg with a fresh lock is not called lost or stale' "$html" 'lock FRESH — lost or stale'
# A PR with no checks yet is not green.
contains 'an empty check rollup reads pending, not green' "$html" '<li data-ci="pending"><b>#2003</b>'
# The legs: block reads exactly as tick.sh's grammar: four non-empty fields, the
# tick's label class, every terminator.
contains 'a label with _ . - is a leg (tick label class)' "$html" 'data-label="N16_x.y-z"'
lacks 'a detail bullet under the block adds no phantom leg' "$html" 'data-label="N13"'
lacks 'a three-field span is not an entry' "$html" 'data-label="N15"'
lacks 'a span with an empty field is not an entry' "$html" 'data-label="N17"'
# Leg-doc discovery follows the leg's identity, not label + mtime alone.
contains 'a doc stem in Live state resolves that exact doc' "$html" '<b>N18</b> <span class="tk">HIMMEL-3375</span>'
contains 'a reused label resolves to the doc holding the entry nonce' "$html" '<b>N19</b> <span class="tk">HIMMEL-3376</span>'

# --- a failed leg-label lookup is visible, not an empty fleet. The
# BOARD_LEGID seam points at a helper that fails, or labels fewer names than asked.
printf '%s\n' 'return 3' > "$W/legid-fail.sh"
BOARD_LEGID="$W/legid-fail.sh" run --out "$W/fail-board.html" >/dev/null; rc=$?
failhtml="$(cat "$W/fail-board.html" 2>/dev/null)"
failerr="$(cat "$W/stderr.log")"
contains 'a failing label lookup still renders the board (rc 0)' "rc=$rc" 'rc=0'
contains 'a failing label lookup warns on stderr' "$failerr" 'leg labels unavailable'
contains 'a failing label lookup names why' "$failerr" 'the lookup failed'
contains 'a failing label lookup renders the unavailable banner' "$failhtml" 'data-banner="labels-unavailable"'
TICK_STUB_FAIL=1 BOARD_LEGID="$W/legid-fail.sh" run --out "$W/fail-empty-board.html" >/dev/null
failemptyhtml="$(cat "$W/fail-empty-board.html" 2>/dev/null)"
contains 'a failing lookup with no tick legs says so in the Legs panel, not "no legs"' "$failemptyhtml" '<p class="none">worker-session labels unavailable</p>'
lacks 'a failing lookup with no tick legs does not claim no legs' "$failemptyhtml" 'no worker sessions'

# One label for three names: the first leg still renders, the shortfall is reported.
# shellcheck disable=SC2016  # the helper body is literal, evaluated by the board's bash
printf '%s\n' 'leg_label() { [ "$1" = N1 ] && printf N1; }' > "$W/legid-short.sh"
BOARD_LEGID="$W/legid-short.sh" run --out "$W/short-board.html" >/dev/null; rc=$?
shorthtml="$(cat "$W/short-board.html" 2>/dev/null)"
shorterr="$(cat "$W/stderr.log")"
contains 'a short label lookup still renders the board (rc 0)' "rc=$rc" 'rc=0'
contains 'a short label lookup warns with the shortfall' "$shorterr" 'returned 1 of'
contains 'a short label lookup renders the unavailable banner' "$shorthtml" 'data-banner="labels-unavailable"'
contains 'a short label lookup keeps the legs it did label' "$shorthtml" 'data-label="N1"'
lacks 'a short label lookup does not claim no legs' "$shorthtml" 'no worker sessions'

# --- (Ask 3): a WRAPPED leg whose claude window is still alive is its
# own needs-the-console state, derived from an independent process census -- never
# from tick.sh's procs= (which only counts HELD legs). N5 is the fixture's one
# WRAPPED leg (doc stem HIMMEL-3300-N5-eps-2026-09-21); leg_identity() derives its
# undated session name HIMMEL-3300-N5-eps.
cat > "$W/bin/sessions-n5-alive.sh" <<'STUB'
claude_sessions() { printf '999\tHIMMEL-3300-N5-eps\tsonnet\ton\n'; }
STUB
out="$(BOARD_SESSIONS="$W/bin/sessions-n5-alive.sh" run --out "$W/n5-alive-board.html")"; rc=$?
n5html="$(cat "$W/n5-alive-board.html" 2>/dev/null)"
contains 'a WRAPPED leg with a live census match reads WRAPPED, window still open' "$n5html" 'data-label="N5" data-phase="WRAPPED, window still open"'
contains 'it is listed as needing the console' "$n5html" 'data-need="N5"'
contains 'the need row explains why' "$n5html" 'WRAPPED, window still open — '

# The need row says whether the window is safe to close, from the same
# close-wrapped-leg.sh --check a hand-close would run. The refusal text below is
# copied from the real script's wrap-subtree-check output (WITHHELD line, rc 6).
cat > "$W/bin/close-check-safe.sh" <<'STUB'
#!/usr/bin/env bash
[ "$1" = --check ] || exit 2
echo "SAFE-TO-CLOSE: pid 999 (N5) has no live subtree or subagent; nothing was signalled"
STUB
cat > "$W/bin/close-check-busy.sh" <<'STUB'
#!/usr/bin/env bash
[ "$1" = --check ] || exit 2
echo "WITHHELD: 1 process(es) still alive under claude pid 999"
echo "close-wrapped-leg: refusing to signal pid 999 - wrap-subtree-check.sh did not report CLOSABLE (see above); retry shortly" >&2
exit 6
STUB
chmod +x "$W/bin/close-check-safe.sh" "$W/bin/close-check-busy.sh"
BOARD_CLOSE_CHECK="$W/bin/close-check-safe.sh" BOARD_SESSIONS="$W/bin/sessions-n5-alive.sh" run --out "$W/n5-safe-board.html" >/dev/null
contains 'a still-open WRAPPED leg whose close check passes reads safe to close' "$(cat "$W/n5-safe-board.html")" 'WRAPPED, window still open — safe to close'
BOARD_CLOSE_CHECK="$W/bin/close-check-busy.sh" BOARD_SESSIONS="$W/bin/sessions-n5-alive.sh" run --out "$W/n5-busy-board.html" >/dev/null
contains 'a refused close check reads still running with the reason' "$(cat "$W/n5-busy-board.html")" 'still running: WITHHELD: 1 process(es) still alive under claude pid 999'
# a missing check script exits 127: an operational failure, never "still running"
BOARD_CLOSE_CHECK="$W/bin/no-such-close-check.sh" BOARD_SESSIONS="$W/bin/sessions-n5-alive.sh" run --out "$W/n5-missing-board.html" >/dev/null
contains 'a close check that fails to run reads close check failed' "$(cat "$W/n5-missing-board.html")" 'close check failed (rc 127)'
lacks 'a close check that fails to run is never read as still running' "$(cat "$W/n5-missing-board.html")" 'still running'

# No census match (the default empty stub the suite already uses throughout):
# N5 stays plain WRAPPED, as pinned above at line 212. (The ladder itself always
# lists the 'WRAPPED, window still open' phase, at count 0 here -- check the leg's
# own data-phase, not a bare substring of the whole page.)
lacks 'a WRAPPED leg with no census match is never flagged as still open' "$html" 'data-label="N5" data-phase="WRAPPED, window still open"'

# Census unavailable (the sourced helper itself fails): never read as "nothing is
# running" -- falls back to plain WRAPPED, same as no match.
cat > "$W/bin/sessions-fail.sh" <<'STUB'
claude_sessions() { return 1; }
STUB
out="$(BOARD_SESSIONS="$W/bin/sessions-fail.sh" run --out "$W/n5-census-fail-board.html")"; rc=$?
n5failhtml="$(cat "$W/n5-census-fail-board.html" 2>/dev/null)"
contains 'an unavailable census still renders the board (rc 0)' "rc=$rc" 'rc=0'
contains 'and leaves the WRAPPED leg as plain WRAPPED (archive)' "$(cat "$W/n5-census-fail-board-archive.html")" 'N5 HIMMEL-3300 WRAPPED'
lacks 'never flags "still open" on a census it could not read' "$n5failhtml" 'data-label="N5" data-phase="WRAPPED, window still open"'

# --- (Ask 1): --changed re-renders and reports whether the render moved,
# so a console can call ONE kit command after every Live-state mutation; the Artifact
# publish stays a separate model step.
rm -f "$W/changed-board.html"
out1="$(run --out "$W/changed-board.html" --changed)"; rc1=$?
same '--changed on the first render (nothing to compare against) reports CHANGED' "$out1" "CHANGED $W/changed-board.html"
contains '--changed rc is still 0' "rc=$rc1" 'rc=0'
out2="$(run --out "$W/changed-board.html" --changed)"
same '--changed on an identical re-render reports UNCHANGED' "$out2" "UNCHANGED $W/changed-board.html"
out3="$(TICK_STUB_FAIL=1 run --out "$W/changed-board.html" --changed)"
same '--changed after tick goes unavailable (fp now empty, prior fp was real) reports CHANGED' "$out3" "CHANGED $W/changed-board.html"

# --- (Ask 3 x Ask 1): the WRAPPED-window census is read independently
# of tick's --emit-fp, so a window opening on an otherwise-unchanged tick
# fingerprint must still flip --changed to CHANGED.
rm -f "$W/changed-census-board.html"
out4="$(run --out "$W/changed-census-board.html" --changed)"; rc4=$?
same 'census --changed: first render reports CHANGED' "$out4" "CHANGED $W/changed-census-board.html"
contains 'census --changed: rc is still 0' "rc=$rc4" 'rc=0'
out5="$(BOARD_SESSIONS="$W/bin/sessions-n5-alive.sh" run --out "$W/changed-census-board.html" --changed)"
same 'a WRAPPED leg gaining a live window flips CHANGED although tick-fp is unchanged' "$out5" "CHANGED $W/changed-census-board.html"
out6="$(BOARD_SESSIONS="$W/bin/sessions-n5-alive.sh" run --out "$W/changed-census-board.html" --changed)"
same 'the same still-open leg on a re-render reports UNCHANGED' "$out6" "UNCHANGED $W/changed-census-board.html"

# --- tick keeps CI colour and fleet capacity out of board-fp on purpose,
# but the page SHOWS them, so --changed folds a signature of those cells in separately.
rm -f "$W/changed-cf.html"
run --out "$W/changed-cf.html" --changed >/dev/null
same 'ci/fleet --changed: an identical re-render reports UNCHANGED' "$(run --out "$W/changed-cf.html" --changed)" "UNCHANGED $W/changed-cf.html"
sed 's/"conclusion":"FAILURE"/"conclusion":"SUCCESS"/' "$W/open.json" > "$W/open-ci-moved.json"
same 'only a PR CI colour moving (failing to pending) flips --changed' "$(BOARD_TEST_GH_OPEN="$W/open-ci-moved.json" run --out "$W/changed-cf.html" --changed)" "CHANGED $W/changed-cf.html"
same 'and the moved CI colour, re-rendered again, reads UNCHANGED' "$(BOARD_TEST_GH_OPEN="$W/open-ci-moved.json" run --out "$W/changed-cf.html" --changed)" "UNCHANGED $W/changed-cf.html"
same 'only fleet capacity moving flips --changed' "$(BOARD_TEST_GH_OPEN="$W/open-ci-moved.json" TICK_STUB_FLEET=10/15 run --out "$W/changed-cf.html" --changed)" "CHANGED $W/changed-cf.html"
contains 'the tick fingerprint meta is still exactly tick'"'"'s' "$(cat "$W/changed-cf.html")" '<meta name="console-board-fp" content="deadbeefdeadbeef">'

# --- `versions: v1.0.0, v1.0.1` renders one Release panel per fixVersion,
# from ONE stubbed Jira CLI call per version (BOARD_JIRA seam, mirrors BOARD_TICK). The
# stub answers from $JIRA_DIR/<version>.tsv in the CLI's `list --labels` row format
# (key, type, status, title, labels; tab-separated) and never touches Jira.
JD="$W/jira"
mkdir -p "$JD"
cat > "$W/bin/jira-stub" <<'STUB'
#!/usr/bin/env bash
printf 'project=%s args=%s\n' "${JIRA_PROJECT_KEY:-}" "$*" >> "$JIRA_ARGV_LOG"
[ "${JIRA_STUB_FAIL:-0}" -eq 0 ] || exit 1
v="$(printf '%s' "$*" | sed -n 's/.*fixVersion = "\([^"]*\)".*/\1/p')"  # gnu-ok: console kit is Linux-only
[ -f "$JIRA_DIR/$v.tsv" ] && cat "$JIRA_DIR/$v.tsv" || exit 1
STUB
chmod +x "$W/bin/jira-stub"
T="$(printf '\t')"
write_v100() {  # write_v100 <done count: 3 or 4>
    {
        printf 'HIMMEL-9001%sBug%sIn Progress%sfix the blocker cachyos-x8664-pid777777 now%sci,v1-blocker\n' "$T" "$T" "$T" "$T"
        printf 'HIMMEL-9002%sTask%sIN CI%snot a blocker%sci\n' "$T" "$T" "$T" "$T"
        printf 'HIMMEL-9003%sTask%sIn Review%sblocker two%sv1-blocker\n' "$T" "$T" "$T" "$T"
        printf 'HIMMEL-9004%sTask%sDone%sshipped a%sv1-blocker\n' "$T" "$T" "$T" "$T"
        printf 'HIMMEL-9005%sTask%sDone%sshipped b%s\n' "$T" "$T" "$T" "$T"
        printf 'HIMMEL-9006%sTask%sDone%sshipped c%sv1-blocker\n' "$T" "$T" "$T" "$T"
        [ "$1" -lt 4 ] || printf 'HIMMEL-9007%sTask%sDone%sshipped d%s\n' "$T" "$T" "$T" "$T"
    } > "$JD/v1.0.0.tsv"
}
write_v100 3
{
    printf 'HIMMEL-9101%sTask%sDone%sfirst%s\n' "$T" "$T" "$T" "$T"
    printf 'HIMMEL-9102%sTask%sTo Do%ssecond%sv1-blocker\n' "$T" "$T" "$T" "$T"
    printf 'HIMMEL-9103%sTask%sClosed%sclosed one%s\n' "$T" "$T" "$T" "$T"
    printf 'HIMMEL-9104%sTask%swont do%swont one%s\n' "$T" "$T" "$T" "$T"
} > "$JD/v1.0.1.tsv"
DOCV="$B/HIMMEL-nextleg-2026-09-21V-console-v.md"
sed 's/^epics: .*/&\nversions: v1.0.0, v1.0.1/' "$DOC" > "$DOCV"  # gnu-ok: console kit is Linux-only
runv() {  # runv <extra args...> -- like run, on the console doc that carries a versions: line
    PATH="$W/bin:$PATH" BOARD_TICK="$W/bin/tick-stub" TICK_ARGV_LOG="$W/argv.log" \
        BOARD_SESSIONS="$W/bin/sessions-empty.sh" BOARD_JIRA="${BOARD_JIRA:-$W/bin/jira-stub}" \
        JIRA_ARGV_LOG="$W/jira-argv.log" JIRA_DIR="$JD" JIRA_PROJECT_KEY=HIMMEL \
        GH_OPEN="$W/open.json" GH_MERGED="$W/merged.json" GH_EPIC="$W/epic.json" GH_VIEW="$W/view" \
        node "$SUT" --doc "$DOCV" --repo "$W/repo" "$@" 2>"$W/stderr.log"
}
rm -f "$W/jira-argv.log"
runv --out "$W/v-board.html" >/dev/null; rc=$?
vhtml="$(cat "$W/v-board.html" 2>/dev/null)"
jargv="$(cat "$W/jira-argv.log" 2>/dev/null)"
contains 'a versions: line still renders a board (rc 0)' "rc=$rc" 'rc=0'
contains 'each version renders done/total' "$vhtml" 'data-release="v1.0.0" data-done="3" data-total="6"'
contains 'the second version renders its own counts, Closed and won'"'"'t do left out of done and total' "$vhtml" 'data-release="v1.0.1" data-done="1" data-total="2"'
contains 'the panel is titled Release <version>' "$vhtml" '<h2>Release v1.0.0</h2>'
contains 'an open v1-blocker ticket is listed with its key' "$vhtml" 'data-blocker="HIMMEL-9001"'
contains 'a listed blocker shows its status' "$vhtml" '<span class="pr">In Progress</span>'
contains 'a second open blocker is listed' "$vhtml" 'data-blocker="HIMMEL-9003"'
lacks 'an open ticket without the v1-blocker label is not listed' "$vhtml" 'HIMMEL-9002'
lacks 'a done v1-blocker ticket is not listed as a blocker' "$vhtml" 'HIMMEL-9004'
lacks 'a lock token in a blocker title is redacted' "$vhtml" 'pid777777'
# a per-status breakdown (To Do / In Progress / In Review / IN CI / Done) per panel.
contains 'v1.0.0 breakdown: In Progress count' "$vhtml" 'data-status="In Progress" data-count="1"'
contains 'v1.0.0 breakdown: In Review count' "$vhtml" 'data-status="In Review" data-count="1"'
contains 'v1.0.0 breakdown: IN CI count' "$vhtml" 'data-status="IN CI" data-count="1"'
contains 'v1.0.0 breakdown: Done count' "$vhtml" 'data-status="Done" data-count="3"'
contains 'v1.0.0 breakdown: To Do count (zero shown)' "$vhtml" 'data-status="To Do" data-count="0"'
contains 'v1.0.1 breakdown: its own To Do count' "$vhtml" 'data-status="To Do" data-count="1"'
contains 'the versions fingerprint meta is present' "$vhtml" 'console-board-versions-fp'
same 'one Jira call per version' "$(printf '%s\n' "$jargv" | grep -c .)" '2'
contains 'the CLI is asked by fixVersion JQL' "$jargv" 'fixVersion = "v1.0.0"'
contains 'the CLI is asked for labels' "$jargv" '--labels'
contains 'the CLI is asked for a high limit' "$jargv" '--limit 1000'
contains 'JIRA_PROJECT_KEY comes from the environment' "$jargv" 'project=HIMMEL'

# A failing CLI reads unavailable per version and never fails the render.
JIRA_STUB_FAIL=1 runv --out "$W/v-fail-board.html" >/dev/null; rc=$?
vfail="$(cat "$W/v-fail-board.html" 2>/dev/null)"
contains 'a failing Jira CLI still renders the board (rc 0)' "rc=$rc" 'rc=0'
contains 'a failing Jira CLI reads unavailable' "$vfail" 'data-release="v1.0.0" data-unavailable="1"'
lacks 'a failing Jira CLI fabricates no counts' "$vfail" 'data-done='
# A missing CLI (nothing at the seam path) reads unavailable too.
BOARD_JIRA="$W/bin/no-such-jira" runv --out "$W/v-missing-board.html" >/dev/null; rc=$?
contains 'a missing Jira CLI still renders the board (rc 0)' "rc=$rc" 'rc=0'
contains 'a missing Jira CLI reads unavailable' "$(cat "$W/v-missing-board.html")" 'data-release="v1.0.0" data-unavailable="1"'

# No versions: line -> nothing extra, and Jira is never called.
rm -f "$W/jira-argv.log"
JIRA_ARGV_LOG="$W/jira-argv.log" BOARD_JIRA="$W/bin/jira-stub" run --out "$W/nov-board.html" >/dev/null
lacks 'no versions: line renders no Release panel' "$(cat "$W/nov-board.html")" 'data-release'
lacks 'no versions: line renders no release fingerprint' "$(cat "$W/nov-board.html")" 'console-board-versions-fp'
if [ ! -e "$W/jira-argv.log" ]; then pass 'no versions: line makes no Jira call'; else fail 'no versions: line made a Jira call'; fi

# The version rows fold into --changed: a count moving flips it, an identical render does not.
rm -f "$W/v-changed.html"
vc1="$(runv --out "$W/v-changed.html" --changed)"
same 'versions --changed: first render reports CHANGED' "$vc1" "CHANGED $W/v-changed.html"
vc2="$(runv --out "$W/v-changed.html" --changed)"
same 'versions --changed: an identical re-render reports UNCHANGED' "$vc2" "UNCHANGED $W/v-changed.html"
write_v100 4
vc3="$(runv --out "$W/v-changed.html" --changed)"
same 'a done count moving flips --changed although tick-fp is unchanged' "$vc3" "CHANGED $W/v-changed.html"
contains 'the tick fingerprint meta is left as tick computed it' "$(cat "$W/v-changed.html")" '<meta name="console-board-fp" content="deadbeefdeadbeef">'
vc4="$(JIRA_STUB_FAIL=1 runv --out "$W/v-changed.html" --changed)"
same 'the CLI going unavailable flips --changed' "$vc4" "CHANGED $W/v-changed.html"
# A blocker retitled in Jira changes what the panel shows, so it flips --changed too.
runv --out "$W/v-changed.html" --changed >/dev/null
sed -i 's/fix the blocker/renamed blocker/' "$JD/v1.0.0.tsv"  # gnu-ok: console kit is Linux-only
vc5="$(runv --out "$W/v-changed.html" --changed)"
same 'a retitled blocker flips --changed' "$vc5" "CHANGED $W/v-changed.html"
# A partial answer (one row that does not parse among valid ones) is not complete totals.
write_v100 3
printf 'garbled line without tabs\n' >> "$JD/v1.0.0.tsv"
runv --out "$W/v-partial.html" >/dev/null; rc=$?
vpart="$(cat "$W/v-partial.html" 2>/dev/null)"
contains 'a partial Jira answer still renders the board (rc 0)' "rc=$rc" 'rc=0'
contains 'a partial Jira answer reads unavailable, not short totals' "$vpart" 'data-release="v1.0.0" data-unavailable="1"'
contains 'a clean version beside a partial one still renders' "$vpart" 'data-release="v1.0.1" data-done="1" data-total="2"'
# A row without the labels column (the CLI with --labels always emits it) would hide blockers.
write_v100 3
printf 'HIMMEL-9008%sTask%sTo Do%sno labels column\n' "$T" "$T" "$T" >> "$JD/v1.0.0.tsv"
runv --out "$W/v-nolabels.html" >/dev/null
contains 'a row missing the labels column reads unavailable' "$(cat "$W/v-nolabels.html" 2>/dev/null)" 'data-release="v1.0.0" data-unavailable="1"'

# --- `release: R1` renders the release manager's lines from ONE `jira release state R1
# --json` call (the same BOARD_JIRA seam): M4 burn-down per version, the leaks, and the
# M1 trend. The stub prints $RM_STATE and exits $RM_RC (3 = the CLI's not-OK exit).
cat > "$W/bin/jira-rm-stub" <<'STUB'
#!/usr/bin/env bash
printf 'args=%s\n' "$*" >> "$JIRA_ARGV_LOG"
[ -f "${RM_STATE:-}" ] && cat "$RM_STATE"
exit "${RM_RC:-0}"
STUB
chmod +x "$W/bin/jira-rm-stub"
cat > "$W/rm-state.json" <<'EOF'
{"release":"R1","status":"OK","mode":"observe","versions":["v1","v2"],
 "leaks":{"unauthorized":["HIMMEL-9201@v1"],"ruled_in_non_member":[]},"integrity":[],
 "burndown":{"v1":{"baseline":5,"baseline_open":3,"admitted_open":2,"emergency_open":1,"deferred_out":1},
             "v2":{"baseline":0,"baseline_open":0,"admitted_open":0,"emergency_open":0,"deferred_out":0}},
 "trend":{"2026-10-20":{"ruled":2},"2026-10-21":{"ruled":1,"out-of-band":1}}}
EOF
DOCR="$B/HIMMEL-nextleg-2026-09-21V-console-r.md"
sed 's/^epics: .*/&\nrelease: R1/' "$DOC" > "$DOCR"  # gnu-ok: console kit is Linux-only
runr() {  # runr <extra args...> -- like run, on the console doc that carries a release: line
    PATH="$W/bin:$PATH" BOARD_TICK="$W/bin/tick-stub" TICK_ARGV_LOG="$W/argv.log" \
        BOARD_SESSIONS="$W/bin/sessions-empty.sh" BOARD_JIRA="$W/bin/jira-rm-stub" \
        JIRA_ARGV_LOG="$W/jira-argv.log" JIRA_PROJECT_KEY=HIMMEL \
        GH_OPEN="$W/open.json" GH_MERGED="$W/merged.json" GH_EPIC="$W/epic.json" GH_VIEW="$W/view" \
        node "$SUT" --doc "$DOCR" --repo "$W/repo" "$@" 2>"$W/stderr.log"
}
rm -f "$W/jira-argv.log"
RM_STATE="$W/rm-state.json" runr --out "$W/r-board.html" >/dev/null; rc=$?
rhtml="$(cat "$W/r-board.html" 2>/dev/null)"
contains 'a release: line still renders a board (rc 0)' "rc=$rc" 'rc=0'
same 'one release state call' "$(cat "$W/jira-argv.log" 2>/dev/null)" 'args=release state R1 --json'
contains 'the release manager panel names the release and its status' "$rhtml" 'data-rm-release="R1" data-status="OK"'
contains 'M4: a version line carries baseline open of baseline' "$rhtml" 'data-burndown="v1" data-baseline-open="3" data-baseline="5"'
contains 'M4: and admitted, emergency and deferred counts' "$rhtml" 'admitted open 2 · emergency open 1 · deferred out 1'
contains 'M4: every version of the release has a line' "$rhtml" 'data-burndown="v2"'
contains 'a leak is listed by key and version' "$rhtml" 'data-leak="HIMMEL-9201@v1"'
contains 'M1 trend: one row per day, by kind' "$rhtml" 'data-trend="2026-10-21">2026-10-21: out-of-band 1 · ruled 1'
contains 'the release fingerprint meta is present' "$rhtml" 'console-board-versions-fp'
RM_STATE="$W/rm-state.json" RM_RC=3 runr --out "$W/r-unknown.html" >/dev/null; rc=$?
contains 'a not-OK state (exit 3) still renders the board (rc 0)' "rc=$rc" 'rc=0'
contains 'a not-OK state still shows its JSON' "$(cat "$W/r-unknown.html")" 'data-rm-release="R1" data-status="OK"'
RM_RC=1 runr --out "$W/r-fail.html" >/dev/null; rc=$?
contains 'a failing release state call still renders the board (rc 0)' "rc=$rc" 'rc=0'
contains 'a failing release state call reads unavailable' "$(cat "$W/r-fail.html")" 'data-rm-release="R1" data-unavailable="1"'
lacks 'no release: line renders no release manager panel' "$(cat "$W/nov-board.html")" 'data-rm-release'

# --- with no --legs, the leg set is the console's fleet manifest
# (<console doc stem>.fleet.json, read through fleet-manifest.sh list -- the same
# validation tick --legs-from uses); no manifest keeps the RESUME-doc scan; an
# explicit --legs wins; a manifest change moves --changed (the tick stub's
# fingerprint is constant, so only board.mjs's own manifest signature can).
M="$W/mf"
mkdir -p "$M"
printf '%s\n' '# console' '## Live state' 'epics: none' '' '## Results' > "$M/console-m.md"
for n in 901 902; do printf '%s\n' "# leg N$n" '## Results' '- 10:00 LIVE — working' > "$M/HIMMEL-9$n-N$n-x-RESUME.md"; done
MDOC="$M/console-m.md"
MFLEET="$M/console-m.fleet.json"
mrun() {
    PATH="$W/bin:$PATH" BOARD_TICK="$W/bin/tick-stub" TICK_ARGV_LOG="$W/argv.log" \
        BOARD_SESSIONS="$W/bin/sessions-empty.sh" \
        GH_OPEN="$W/open.json" GH_MERGED="$W/merged.json" GH_EPIC="$W/epic.json" GH_VIEW="$W/view" \
        node "$SUT" --doc "$MDOC" --repo "$W/repo" --out "$M/board.html" "$@" 2>"$W/stderr.log"
}
mrun >/dev/null
lacks 'no manifest: tick gets no --legs (the RESUME-doc scan stays the fallback, HIMMEL-3988)' "$(cat "$W/argv.log")" "$M/HIMMEL-9901"
printf '{"schema":1,"legs":[{"doc":"%s","label":"N901","added":"2026-10-01T00:00:00Z"}]}\n' "$M/HIMMEL-9901-N901-x-RESUME.md" > "$MFLEET"
mrun --changed >/dev/null
contains 'manifest present: tick is armed with the manifest legs (HIMMEL-3988)' "$(cat "$W/argv.log")" "--legs $M/HIMMEL-9901-N901-x-RESUME.md"
lacks 'manifest present: a RESUME doc it does not list is not armed (HIMMEL-3988)' "$(cat "$W/argv.log")" 'HIMMEL-9902'
contains 'manifest present: the listed leg is on the board' "$(cat "$M/board.html")" 'data-label="N901"'
same 'manifest unchanged: --changed reports UNCHANGED' "$(mrun --changed)" "UNCHANGED $M/board.html"
printf '{"schema":1,"legs":[{"doc":"%s","label":"N901"},{"doc":"%s","label":"N902"}]}\n' "$M/HIMMEL-9901-N901-x-RESUME.md" "$M/HIMMEL-9902-N902-x-RESUME.md" > "$MFLEET"
same 'manifest gained a leg: --changed reports CHANGED (HIMMEL-3988)' "$(mrun --changed)" "CHANGED $M/board.html"
mrun --legs "$M/HIMMEL-9902-N902-x-RESUME.md" >/dev/null
contains 'an explicit --legs wins over the manifest' "$(cat "$W/argv.log")" "--legs $M/HIMMEL-9902-N902-x-RESUME.md"
lacks 'an explicit --legs wins over the manifest (manifest leg not armed)' "$(cat "$W/argv.log")" 'HIMMEL-9901'
printf '%s\n' 'not json' > "$MFLEET"
mrun >/dev/null; rc=$?
contains 'an invalid manifest falls back to the scan, rc 0' "rc=$rc" 'rc=0'
contains 'an invalid manifest is reported on stderr, not silently ignored' "$(cat "$W/stderr.log")" 'fleet manifest'

# --- cost today: one line from the leg cost ledger, never fatal
LC="$W/leg-cost.jsonl"
lcrow() { printf '{"date":"%s","leg":"N1","ticket":"HIMMEL-1","class":"%s","cost_eq":%s}\n' "$1" "$2" "$3"; }
TODAY="$(date +%F)"
{
    lcrow "$TODAY" shepherd 100000
    lcrow "$TODAY" shepherd 300000
    lcrow "$TODAY" impl 2000000
    lcrow 2020-01-01 shepherd 99999999
    printf 'not json\n'
} > "$LC"
LEG_COST_LEDGER="$LC" mrun >/dev/null; rc=$?
same 'cost line: render still succeeds, rc 0' "$rc" "0"
costhtml="$(cat "$M/board.html")"
contains 'cost line: counts only today legs (3, not the 2020 row)' "$costhtml" 'data-cost-legs="3"'
contains 'cost line: total cost-eq' "$costhtml" '2.4M cost-eq'
contains 'cost line: median per class (even n is the mean of the middle two)' "$costhtml" 'shepherd 200k'
contains 'cost line: second class' "$costhtml" 'impl 2.0M'
LEG_COST_LEDGER="$W/no-such-ledger.jsonl" mrun >/dev/null; rc=$?
same 'cost line: absent ledger, rc 0' "$rc" "0"
lacks 'cost line: absent ledger renders nothing' "$(cat "$M/board.html")" 'data-cost-legs'
mkdir -p "$W/ledger-is-a-dir.jsonl"
LEG_COST_LEDGER="$W/ledger-is-a-dir.jsonl" mrun >/dev/null; rc=$?
same 'cost line: unreadable ledger, rc 0' "$rc" "0"
lacks 'cost line: unreadable ledger renders nothing' "$(cat "$M/board.html")" 'data-cost-legs'
{ lcrow "$TODAY" constructor 5000; lcrow "$TODAY" __proto__ 7000; } > "$LC"
LEG_COST_LEDGER="$LC" mrun >/dev/null; rc=$?
contains 'cost line: class names like constructor/__proto__ do not suppress the line' "$(cat "$M/board.html")" 'data-cost-legs="2"'
printf 'not json\n' > "$LC"
LEG_COST_LEDGER="$LC" mrun >/dev/null; rc=$?
lacks 'cost line: a ledger with no usable row today renders nothing' "$(cat "$M/board.html")" 'data-cost-legs'

# --- exploration cost: digest markers, median / worst 5 / flag, threshold by env
XD="$W/leg-digest"
mkdir -p "$XD"
NOWMS="$(( $(date +%s) * 1000 ))"
xrow() { # <session-prefix> <tokens> <cut> <started_ts>
    printf '{"session":"%s-0000","model":"claude-sonnet-5-5","started_ts":%s,"status":"ok","exploration":{"tokens":%s,"sub_tokens":0,"reads":3,"searches":2,"cut":"%s"}}\n' "$1" "$4" "$2" "$3" > "$XD/$1-0000.json"
}
xrow aaaaaaa1 20000 edit "$NOWMS"
xrow aaaaaaa2 30000 edit "$NOWMS"
xrow aaaaaaa3 50000 commit "$NOWMS"
xrow aaaaaaa4 60000 edit "$NOWMS"
xrow aaaaaaa5 70000 edit "$NOWMS"
xrow aaaaaaa6 150000 edit "$NOWMS"
xrow bbbbbbb1 900000 none "$NOWMS"
xrow ccccccc1 800000 edit 1000
LEG_DIGEST_STATE_DIR="$XD" mrun >/dev/null; rc=$?
same 'exploration: render still succeeds, rc 0' "$rc" "0"
xhtml="$(cat "$M/board.html")"
contains 'exploration: six cut sessions (not the cut-none one, not the old one)' "$xhtml" 'data-exploration="6"'
contains 'exploration: median of the six' "$xhtml" 'median 55k tokens before first edit'
contains 'exploration: one session over the 100000 default' "$xhtml" 'data-exploration-over="1"'
contains 'exploration: the worst session leads the table' "$xhtml" 'data-session="aaaaaaa6"'
lacks 'exploration: the table holds only the worst 5' "$xhtml" 'data-session="aaaaaaa1"'
lacks 'exploration: a session with no edit is not in the panel' "$xhtml" 'bbbbbbb1'
LEG_EXPLORATION_FLAG_TOKENS=55000 LEG_DIGEST_STATE_DIR="$XD" mrun >/dev/null; rc=$?
contains 'exploration: the env threshold moves the flag (3 over 55000)' "$(cat "$M/board.html")" 'data-exploration-over="3"'
LEG_DIGEST_STATE_DIR="$W/no-such-dir" mrun >/dev/null; rc=$?
same 'exploration: absent state dir, rc 0' "$rc" "0"
lacks 'exploration: absent state dir renders nothing' "$(cat "$M/board.html")" 'data-exploration'

# --- failure classes this shift: the leg-failures ledger since the
# console lock's start, the router log's latest decision per class, the memory
# inbox count. Never fatal; not part of the fingerprint.
mkdir -p "$W/repo/scripts/handover"
cat > "$W/repo/scripts/handover/queue-lock.sh" <<'STUB'
#!/usr/bin/env bash
[ "$1" = status ] || exit 2
[ -n "${QL_STUB_STARTED:-}" ] || { echo free; exit 0; }
printf '{"session":"s","host":"h","handover":"x","started":"%s","heartbeat":"%s"}\n' "$QL_STUB_STARTED" "$QL_STUB_STARTED"
echo 'status: FRESH'; exit 11
STUB
FL="$W/leg-failures.jsonl"
frow() { printf '{"ts":"%s","leg":"%s","class":"%s","failure":"x","count":%s,"recovered":%s}\n' "$1" "$2" "$3" "$4" "$5"; }
{
    frow 2026-10-07T02:00:00Z N0 old/before-shift 9 false
    frow 2026-10-07T03:01:00Z N1 denied/guard-a 3 true
    frow 2026-10-07T03:02:00Z N2 denied/guard-a 2 false
    frow 2026-10-07T03:03:00Z N2 'suite/test-<b>x</b>.sh' 3 null
    echo 'not json'
} > "$FL"
{
    printf '{"ts":"2026-10-07T02:30:00Z","class":"denied/guard-a","legs":1,"decision":"commented","ticket":"HIMMEL-1"}\n'
    printf '{"ts":"2026-10-07T03:04:00Z","class":"denied/guard-a","legs":2,"decision":"filed","ticket":"HIMMEL-4799"}\n'
} > "$W/failure-routes.log.jsonl"
mkdir -p "$M/failure-loop"
printf '%s\n' '# memory inbox' '- one' '- two' > "$M/failure-loop/memory-inbox.md"
QL_STUB_STARTED=2026-10-07T03:00:00Z mrun >/dev/null; rc=$?
same 'failures panel: render succeeds, rc 0' "$rc" "0"
fhtml="$(cat "$M/board.html")"
fsnap="$(printf '%s\n' "$fhtml" | sed -n '/data-failures=/,/<\/section>/p')"
same 'failures panel: snapshot (HIMMEL-4670)' "$fsnap" '<section class="wide" data-failures="2"><h2>Failure classes — this shift</h2><div class="tscroll"><table><tr><th>class</th><th>worker sessions</th><th>events</th><th>rate</th><th>recovered</th><th>route</th></tr>
<tr data-class="denied/guard-a"><td>denied/guard-a</td><td>2</td><td>5</td><td>—</td><td>50 %</td><td>HIMMEL-4799 (filed 03:04)</td></tr>
<tr data-class="suite/test-&lt;b&gt;x&lt;/b&gt;.sh"><td>suite/test-&lt;b&gt;x&lt;/b&gt;.sh</td><td>1</td><td>3</td><td>—</td><td>—</td><td>signal</td></tr>
</table></div><p class="sub">memory inbox: 2 pending</p></section>'
# the failures table spans the grid row and scrolls inside its own panel;
# the ladder is a vertical label-left count-right list (no wrapping chip row).
# RED control (pre-change board.mjs): no class="wide" on data-failures, no .tscroll
# wrapper, and .ladder is a flex-wrap chip row.
contains 'failures panel: spans the full grid row (HIMMEL-5374)' "$fhtml" '<section class="wide" data-failures="2">'
contains 'failures panel: table scrolls inside its own wrapper (HIMMEL-5374)' "$fhtml" '<div class="tscroll"><table>'
contains 'failures panel: wrapper scrolls horizontally, not the page (HIMMEL-5374)' "$fhtml" '.tscroll { overflow-x:auto; }'
contains 'failures panel: class column never breaks mid-word (HIMMEL-5374)' "$fhtml" 'word-break:normal; overflow-wrap:normal;'
contains 'failures panel: numeric columns right-aligned, nowrap (HIMMEL-5374)' "$fhtml" 'text-align:right; white-space:nowrap;'
contains 'ladder: one row per phase, label left and count right (HIMMEL-5374)' "$fhtml" '.ladder li { display:flex; justify-content:space-between;'
lacks 'ladder: no longer a wrapping chip row (HIMMEL-5374)' "$fhtml" '.ladder { display:flex; flex-wrap:wrap;'
cat > "$HIMMEL_EVAL_RUNS_LEDGER" <<'RATES'
{"eval":"leg-trajectory","run_id":"s1","status":"ok","ts":"2026-10-07T03:01:00Z","lane":"claudex","model":"gpt-6.1-sol","meta":{"leg":"N1","tool_health":[{"agent":{"id":"main","model":"gpt-6.1-sol"},"tool":"Bash","calls":50,"failures":5,"errors":0,"denials":5,"classes":{"denied/guard-a":5}}]}}
RATES
printf '%s\n' '{"ts":"2026-10-07T03:01:00Z","session":"s1","agent":{"id":"main"},"leg":"N1","class":"denied/guard-a","failure":"denied","count":5,"recovered":true}' > "$FL"
QL_STUB_STARTED=2026-10-07T03:00:00Z mrun >/dev/null
contains 'intraday shift cannot use a whole-day denominator' "$(cat "$M/board.html")" '<td>5</td><td>—</td>'
QL_STUB_STARTED=2026-10-07T00:00:00Z mrun >/dev/null
contains 'failure rate uses the aligned-day Bash denominator' "$(cat "$M/board.html")" '<td>5</td><td>10.0 %</td>'
: > "$HIMMEL_EVAL_RUNS_LEDGER"
: > "$FL"
QL_STUB_STARTED=2026-10-07T03:00:00Z mrun >/dev/null
contains 'failures panel: no rows this shift reads the empty line' "$(cat "$M/board.html")" '<p class="none">no leg failures this shift</p>'
mrun >/dev/null; rc=$?
same 'failures panel: no lock start, rc 0' "$rc" "0"
contains 'failures panel: no lock start reads unavailable' "$(cat "$M/board.html")" 'leg failures unavailable'
mkdir -p "$W/fl-dir"
QL_STUB_STARTED=2026-10-07T03:00:00Z HIMMEL_LEG_FAILURES_LEDGER="$W/fl-dir" mrun >/dev/null; rc=$?
same 'failures panel: unreadable ledger, rc 0' "$rc" "0"
contains 'failures panel: unreadable ledger reads unavailable' "$(cat "$M/board.html")" 'leg failures unavailable'
for i in $(seq 1 12); do frow 2026-10-07T03:10:00Z "N$i" "c/k$(printf '%02d' "$i")" 1 false; done > "$FL"
QL_STUB_STARTED=2026-10-07T03:00:00Z mrun >/dev/null
same 'failures panel: the live page shows the top 5 rows' "$(grep -o '<tr data-class=' "$M/board.html" | wc -l | tr -d ' ')" "5"
contains 'failures panel: it says the rest are in the archive' "$(cat "$M/board.html")" 'top 5 of 12 classes; the rest in the archive'
same 'failures panel: the archive holds every class' "$(grep -o '<tr data-class=' "$M/board-archive.html" | wc -l | tr -d ' ')" "12"
: > "$FL"

# --- the suite-flake panel reads the checkout's own reader script.
# RED control (pre-change board.mjs): no data-flakes section at all.
mkdir -p "$W/repo/scripts/observability"
cp "$HERE/../../observability/suite-flake-summary.sh" "$W/repo/scripts/observability/suite-flake-summary.sh"
export SUITE_FLAKE_LEDGER="$W/suite-flake.jsonl" SUITE_FLAKE_REPO_ID=board-test-repo
fknow=$(date +%s)
fk() { printf '{"v":1,"ts":%s,"host":"h","source":"run-shell-tests","kind":"flake","suite":"%s","repo":"%s","case":"c","rc":1,"sha":"s","run":"1"}\n' "$1" "$2" "$3"; }
rm -f "$SUITE_FLAKE_LEDGER"
mrun >/dev/null
contains 'flakes panel: no ledger reads the empty line (HIMMEL-5131)' "$(cat "$M/board.html")" '<section data-flakes="0"><h2>Suite flakes — last 7 days</h2><p class="none">no suite flakes in the last 7 days</p></section>'
{
    fk $((fknow - 100)) test-x.sh board-test-repo
    fk $((fknow - 200)) test-x.sh board-test-repo
    fk $((fknow - 300)) 'test-<b>.sh' board-test-repo
    fk $((fknow - 400)) test-other.sh other-repo
    fk $((fknow - 20 * 86400)) test-old.sh board-test-repo
} > "$SUITE_FLAKE_LEDGER"
mrun >/dev/null; rc=$?
same 'flakes panel: render succeeds, rc 0 (HIMMEL-5131)' "$rc" "0"
same 'flakes panel: per-suite counts for this repo inside the window, escaped' "$(sed -n '/data-flakes=/,/<\/section>/p' "$M/board.html")" '<section data-flakes="2"><h2>Suite flakes — last 7 days</h2><table><tr><th>suite</th><th>flakes</th></tr>
<tr data-suite="test-x.sh"><td>test-x.sh</td><td>2</td></tr>
<tr data-suite="test-&lt;b&gt;.sh"><td>test-&lt;b&gt;.sh</td><td>1</td></tr>
</table></section>'
rm -f "$SUITE_FLAKE_LEDGER"; mkdir -p "$SUITE_FLAKE_LEDGER"
mrun >/dev/null; rc=$?
same 'flakes panel: unreadable ledger, rc 0 (HIMMEL-5131)' "$rc" "0"
contains 'flakes panel: unreadable ledger reads unavailable (HIMMEL-5131)' "$(cat "$M/board.html")" 'suite flakes unavailable'
rmdir "$SUITE_FLAKE_LEDGER"
rm -f "$W/repo/scripts/observability/suite-flake-summary.sh"
mrun >/dev/null
lacks 'flakes panel: a checkout without the reader renders no panel (HIMMEL-5131)' "$(cat "$M/board.html")" 'data-flakes='

# --- a console FOR another checkout shows that checkout's PRs, not himmel's.
# console.sh records the project on the doc's project line; every gh call must
# run there. `none — ...` (a himmel console) keeps --repo. A recorded path that
# is gone reads gh unavailable, never --repo's PRs.
mkdir -p "$W/project"
proj_real="$(cd "$W/project" && pwd -P)"
repo_real="$(cd "$W/repo" && pwd -P)"
DOCP="$B/HIMMEL-nextleg-2026-09-21V-console-p.md"
# shellcheck disable=SC2016  # backtick spans, literal fixture text
{ printf '%s\n' '> The project this console is FOR is **`'"$W/project"'`** — you'; cat "$DOC"; } > "$DOCP"
: > "$W/gh-cwd.log"
GH_CWD_LOG="$W/gh-cwd.log" run --doc "$DOCP" --out "$W/p-board.html" >/dev/null
same 'a foreign console runs every gh call in its project' "$(sort -u "$W/gh-cwd.log")" "$proj_real"
contains 'and lists the project PRs' "$(cat "$W/p-board.html")" '<b>#2001</b>'
contains 'tick still gets --repo (himmel), not the project' "$(cat "$W/argv.log")" "--repo $W/repo "
# shellcheck disable=SC2016  # backtick spans, literal fixture text
{ printf '%s\n' '> The project this console is FOR is **`none — this console runs in the himmel checkout itself`** — you'; cat "$DOC"; } > "$DOCP"
: > "$W/gh-cwd.log"
GH_CWD_LOG="$W/gh-cwd.log" run --doc "$DOCP" --out "$W/p-board.html" >/dev/null
same 'a himmel console (project line reads none) runs gh in --repo' "$(sort -u "$W/gh-cwd.log")" "$repo_real"
# shellcheck disable=SC2016  # backtick spans, literal fixture text
{ printf '%s\n' '> The project this console is FOR is **`'"$W/gone"'`** — you'; cat "$DOC"; } > "$DOCP"
: > "$W/gh-cwd.log"
GH_CWD_LOG="$W/gh-cwd.log" run --doc "$DOCP" --out "$W/p-board.html" >/dev/null
same 'a recorded project that is gone never falls back to --repo' "$(cat "$W/gh-cwd.log")" ''
contains 'and reads gh unavailable' "$(cat "$W/p-board.html")" 'gh unavailable'

# --- bank lift: the lift's `show` output, read-only -- the same
# reason source as the doctor's C34 row. Not part of the fingerprint; never fatal.
BL="$W/bank-lift-show.txt"
bl_html() { BANK_LIFT_STUB_OUT="$1" mrun >/dev/null; rc=$?; cat "$M/board.html"; }
html="$(bl_html '')"
same 'bank lift: no lift renders, rc 0' "$rc" "0"
contains 'bank lift: no lift reads "no lift set"' "$html" '<p class="sub" data-bank-lift="none">weekly budget override: no lift set</p>'
for reason in expired account window trust parse; do
    printf '{\n  "window": "seven_day",\n  "until": 1791000000\n}\nbank-lift: INVALID: %s\n' "$reason" > "$BL"
    contains "bank lift: a set lift that is INVALID shows its reason ($reason)" "$(bl_html "$BL")" \
        "<p class=\"sub\" data-bank-lift=\"invalid\">weekly budget override: lift set but INVALID: $reason</p>"
done
printf '{\n  "window": "seven_day",\n  "until": 1791000000,\n  "standing": false,\n  "account": "0123456789abcdef"\n}\nbank-lift: VALID\n' > "$BL"
html="$(TZ=UTC bl_html "$BL")"
contains 'bank lift: a valid window lift shows its until' "$html" '<p class="sub" data-bank-lift="valid">weekly budget override: VALID until 2026-10-03 04:00 · window</p>'
lacks 'bank lift: the account hash never reaches the board' "$html" '0123456789abcdef'
printf '{"window":"seven_day","until":1791000000,"standing":true}\nbank-lift: VALID\n' > "$BL"
contains 'bank lift: a valid standing lift says standing' "$(TZ=UTC bl_html "$BL")" \
    '<p class="sub" data-bank-lift="valid">weekly budget override: VALID until 2026-10-03 04:00 · standing</p>'
printf 'bank-lift: INVALID: <b>x</b>\n' > "$BL"
contains 'bank lift: an unexpected reason is escaped' "$(bl_html "$BL")" 'INVALID: &lt;b&gt;x&lt;/b&gt;'
printf 'garbage\n' > "$BL"
contains 'bank lift: unparseable show output reads unavailable' "$(bl_html "$BL")" 'data-bank-lift="?">weekly budget override: unavailable</p>'
html="$(BOARD_BANK_LIFT="$W/no-such-lift" mrun >/dev/null; cat "$M/board.html")"
contains 'bank lift: a failing show reads unavailable, never fatal' "$html" 'data-bank-lift="?"'

# --- cloud sessions panel: each cloud-sessions.tsv row with the state
# cloud-liveness.mjs derives, the same derivation as tick.sh's cloud= field. Real
# fixtures: the 2026-10-10 launch rows against the trimmed real `gh pr list` JSON for
# PRs 2314 / 2306 / 1982 (fixtures/cloud-liveness-prs.json). RED control (pre-change
# board.mjs): no "Cloud sessions" section is rendered.
printf '%s\n' '#!/bin/sh' "cat '$HERE/fixtures/cloud-liveness-prs.json'" > "$W/bin/cloud-gh"
printf '%s\n' '#!/bin/sh' "printf '%s\n' 'aaaa	refs/heads/main'" > "$W/bin/cloud-git"
printf '%s\n' '#!/bin/sh' 'exit 1' > "$W/bin/cloud-gh-down"
chmod +x "$W/bin/cloud-gh" "$W/bin/cloud-git" "$W/bin/cloud-gh-down"
cloud_html() {
    TZ=Europe/Berlin CLOUD_LIVENESS_NOW='2026-10-10T16:30:00Z' CLOUD_LIVENESS_GH_CMD="$W/bin/$1" CLOUD_LIVENESS_GIT_CMD="$W/bin/cloud-git" mrun >/dev/null
    cat "$M/board.html"
}
html="$(cloud_html cloud-gh)"
lacks 'cloud: no cloud-sessions.tsv renders no cloud panel (HIMMEL-5163)' "$html" 'Cloud sessions'
printf '%s\t%s\t%s\t%s\n' \
    '2026-10-10T15:56:20' HIMMEL-5077 session_012yMgxSaSskpLb4qrfXBhk1 'claude --teleport session_012yMgxSaSskpLb4qrfXBhk1' \
    '2026-10-10T15:56:43' HIMMEL-4657 session_01BCqPMDHjUE9Z52yEy3J3Uf 'claude --teleport session_01BCqPMDHjUE9Z52yEy3J3Uf' \
    '2026-10-10T15:56:54' HIMMEL-4686 session_0173H75dC4x9nZ7JdeLqYoMc 'claude --teleport session_0173H75dC4x9nZ7JdeLqYoMc' \
    > "$M/cloud-sessions.tsv"
html="$(cloud_html cloud-gh)"
contains 'cloud: the panel is rendered (HIMMEL-5163)' "$html" '<h2>Cloud sessions</h2>'
contains 'cloud: an open PR with CLOUD-DONE and no shepherd is unshepherded, PR named (HIMMEL-5163)' "$html" 'data-cloud-ticket="HIMMEL-5077" data-state="unshepherded" data-stall="yes"><b>HIMMEL-5077</b> unshepherded · PR #2314'
contains 'cloud: a merged cloud PR reads merged, not a stall (HIMMEL-5163)' "$html" 'data-cloud-ticket="HIMMEL-4657" data-state="merged" data-stall="no"><b>HIMMEL-4657</b> merged · PR #2306'
contains 'cloud: a session with no branch or PR reads no-branch (HIMMEL-5163)' "$html" 'data-cloud-ticket="HIMMEL-4686" data-state="no-branch" data-stall="yes"'
html="$(cloud_html cloud-gh-down)"
contains 'cloud: an unreadable forge says so, never fatal (HIMMEL-5163)' "$html" 'data-cloud-panel="unavailable"'
rm -f "$M/cloud-sessions.tsv"

# --- the published board shows live work only; WRAPPED/MERGED legs and
# merged PRs go to a local, never-published, grep-friendly archive beside it.
out="$(run --out "$W/live-only-board.html")"; rc=$?
lhtml="$(cat "$W/live-only-board.html" 2>/dev/null)"
arch="$W/live-only-board-archive.html"
if [ -f "$arch" ]; then ahtml="$(cat "$arch")"; else ahtml=''; fail 'the archive file is written beside the board'; fi
lacks 'live page: a MERGED leg is not rendered (N4)' "$lhtml" 'data-label="N4"'
lacks 'live page: a MERGED leg (PR outside the 24 h window) is not rendered (N8)' "$lhtml" 'data-label="N8"'
lacks 'live page: a WRAPPED leg is not rendered (N5)' "$lhtml" 'data-label="N5"'
lacks 'live page: no merged-PR panel' "$lhtml" 'Merged in the last 24 hours'
lacks 'live page: no merged PR row' "$lhtml" '<b>#1995</b>'
contains 'live page: a live leg stays (N1)' "$lhtml" 'data-label="N1" data-phase="LIVE"'
contains 'live page: a READY leg stays (N3)' "$lhtml" 'data-label="N3" data-phase="READY"'
contains 'live page: open PRs stay' "$lhtml" '<b>#2001</b>'
contains 'live page: the phase ladder stays' "$lhtml" 'data-ladder="READY" data-count="1"'
contains 'live page: the tick fingerprint meta stays' "$lhtml" '<meta name="console-board-fp" content="deadbeefdeadbeef">'
contains 'live page: points at the archive by file name' "$lhtml" 'live-only-board-archive.html'
lacks 'live page: carries none of the archive prose (N4 last bullet)' "$lhtml" '0123abc'
contains 'archive: names the MERGED leg on ONE line with ticket, PR and last bullet' "$ahtml" 'N4 HIMMEL-3348 MERGED PR #1995 — 12:00 MERGED #1995'
contains 'archive: names the out-of-window MERGED leg' "$ahtml" 'N8 HIMMEL-3370 MERGED PR #1700'
contains 'archive: names the WRAPPED leg' "$ahtml" 'N5 HIMMEL-3300 WRAPPED'
contains 'archive: lists merged PRs, one per line' "$ahtml" 'PR #1995 merged — fix(w): [HIMMEL-3348] harden'
lacks 'archive: holds no live leg' "$ahtml" 'N1 HIMMEL-3340 LIVE'
lacks 'archive: nonces and lock tokens are redacted too' "$ahtml" 'pid111111'
lacks 'archive: carries no fingerprint meta (it is never the tick board)' "$ahtml" 'console-board-fp'
lbytes="$(printf '%s' "$lhtml" | wc -c)"
if [ "$lbytes" -lt 15000 ]; then pass "live page stays under 15 KB ($lbytes bytes)"; else fail "live page is $lbytes bytes, want under 15000"; fi

# --- a finished judge doc (last marker VERDICT or WRAPPED) goes to the archive like a
# WRAPPED leg. Its label is the doc stem, which tick.sh's tails= never carries, so the
# board reads the doc's own last marker. The size gate is a real-sized fleet: 25 live
# legs with full-length bullets plus 15 finished judges.
S="$W/size"
mkdir -p "$S"
printf '%s\n' '# console' '## Live state' 'epics: none' '' '## Results' '- 10:10 S LIVE sent to prev: 2 of 25 quoted back' > "$S/console-s.md"
pad300="$(printf '%300s' '' | tr ' ' w)"
mf=''
for n in $(seq 701 725); do
    f="$S/HIMMEL-6$n-N$n-work-2026-10-16-RESUME.md"
    succb=''
    [ "$n" -le 702 ] && succb='- 10:04 LIVE — SUCCESSION accepted: console-s replaces console-prev'
    printf '%s\n' "# leg N$n" '## Results' "- 10:00 LIVE — building ${pad300}" ${succb:+"$succb"} "- 11:00 FINDING — question ${pad300}" > "$f"
    mf="$mf{\"doc\":\"$f\",\"label\":\"N$n\"},"
done
for n in $(seq 801 815); do
    f="$S/HIMMEL-7$n-judge-j$n-2026-10-16-RESUME.md"
    if [ $((n % 2)) -eq 0 ]; then tailb="- 12:00 WRAPPED — verdict sent ${pad300}"; else tailb="- 12:00 VERDICT /x/verdicts/j$n.md — GO for 2$n ${pad300}"; fi
    printf '%s\n' "# judge j$n" '## Results' '- 11:00 LIVE — reading the diff' "$tailb" > "$f"
    mf="$mf{\"doc\":\"$f\",\"label\":\"j$n\"},"
done
printf '{"schema":1,"legs":[%s]}\n' "${mf%,}" > "$S/console-s.fleet.json"
# This fleet's own tick: the 25 legs held and FINDING, the fleet full.
slocks=''; stails=''
for n in $(seq 701 725); do slocks="${slocks}N$n:FRESH,"; stails="${stails}N$n:FINDING,"; done
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "TICK 12:34 hb=skip legs=%s bank=5h8/wk42/codex=? tails=%s fleet=25/25 gql=4321/13:00"\nprintf "%%s\\n" board-fp=feedfacefeedface\n' "${slocks%,}" "${stails%,}" > "$W/bin/tick-stub-size"
chmod +x "$W/bin/tick-stub-size"
PATH="$W/bin:$PATH" BOARD_TICK="$W/bin/tick-stub-size" TICK_ARGV_LOG="$W/argv.log" \
    BOARD_SESSIONS="$W/bin/sessions-empty.sh" \
    GH_OPEN="$W/open.json" GH_MERGED="$W/merged.json" GH_EPIC="$W/epic.json" GH_VIEW="$W/view" \
    node "$SUT" --doc "$S/console-s.md" --repo "$W/repo" --out "$S/board.html" >/dev/null 2>"$W/stderr.log"
shtml="$(cat "$S/board.html" 2>/dev/null)"
sarch="$(cat "$S/board-archive.html" 2>/dev/null)"
lacks 'judge: a VERDICT-tailed judge doc is not on the live page (HIMMEL-5955)' "$shtml" 'HIMMEL-7801-judge-j801'
lacks 'judge: a WRAPPED-tailed judge doc is not on the live page (HIMMEL-5955)' "$shtml" 'HIMMEL-7802-judge-j802'
contains 'judge: the VERDICT-tailed judge is in the archive (HIMMEL-5955)' "$sarch" 'HIMMEL-7801-judge-j801-2026-10-16-RESUME HIMMEL-7801 WRAPPED'
contains 'judge: the WRAPPED-tailed judge is in the archive (HIMMEL-5955)' "$sarch" 'HIMMEL-7802-judge-j802-2026-10-16-RESUME HIMMEL-7802 WRAPPED'
contains 'judge: a live leg of the same fleet stays on the page' "$shtml" 'data-label="N725"'
sbytes="$(printf '%s' "$shtml" | wc -c)"
if [ "$sbytes" -lt 15000 ]; then pass "25 live legs + 15 finished judges: live page under 15 KB ($sbytes bytes, HIMMEL-5955)"; else fail "25 live legs + 15 finished judges: live page is $sbytes bytes, want under 15000 (HIMMEL-5955)"; fi

# --- --json <path> writes the board model (schema himmel.board/1): a legend for every
# colour key, one recommendation per report card, the milestone done/total per Jira
# fixVersion from the versions: line, and no nonce or lock token.
write_v100 3
rm -f "${DOCV%.md}.board.json"
runv --out "$W/j-board.html" --json "$W/board.json" >/dev/null; rc=$?
contains '--json: rc 0' "rc=$rc" 'rc=0'
jtxt="$(cat "$W/board.json" 2>/dev/null)"
contains '--json <path> leaves no board.json beside the console doc (the server fallback must not seed a stale sibling)' "$([ -e "${DOCV%.md}.board.json" ] && echo present || echo absent)" 'absent'
jcheck() {  # jcheck <name> <js expression over M> -- passes when the expression is true
    if printf '%s' "$jtxt" | node -e 'let s="";process.stdin.on("data",(d)=>s+=d).on("end",()=>{let M;try{M=JSON.parse(s)}catch{process.exit(1)}process.exit(eval(process.argv[1])?0:1)})' "$2"; then pass "$1"; else fail "$1"; fi
}
jcheck '--json: schema himmel.board/1' 'M.schema === "himmel.board/1"'
jcheck '--json: legend keys for stage, state, verb, ci, budget and failure' '["stage","state","verb","ci","budget","failure"].every((k) => M.legend[k] && Object.values(M.legend[k]).every((v) => v.color && v.label))'
jcheck '--json: one recommendation per report card' '["velocity","health","tools","roadmap"].every((k) => typeof M.cards[k].recommendation === "string" && M.cards[k].recommendation.length > 0)'
jcheck '--json: milestones are done/total per fixVersion' 'M.milestones.length === 2 && M.milestones[0].version === "v1.0.0" && M.milestones[0].done === 3 && M.milestones[0].total === 6 && M.milestones[1].done === 1 && M.milestones[1].total === 2'
jcheck '--json: roadmap recommendation names the open blockers' 'M.cards.roadmap.recommendation.includes("HIMMEL-9001")'
jcheck '--json: every live leg is a row with a state and stage' 'M.legs.some((l) => l.leg === "N3" && l.state === "ready-for-go" && l.stage === "ready") && M.legs.every((l) => l.state && l.stage)'
jcheck '--json: a READY leg is a go need' 'M.needs_you.some((n) => n.leg === "N3" && n.verb === "go")'
jcheck '--json: finished legs are counted, not listed' 'M.console.archive_legs >= 2 && !M.legs.some((l) => l.leg === "N4" || l.leg === "N5")'
for secret in aaaa1111 pid111111 pid777777 cafe1919 x8664; do
    lacks "--json: no nonce/lock-token text: $secret" "$jtxt" "$secret"
done

# --- console cost and the succession eval come from session transcripts: line 1 names
# the session (custom-title = console doc stem), assistant lines carry message.usage,
# a streamed message repeats its id. Opus-eq = input + cache_read x0.1 + cache_write x2
# + output x5, so each message below is 1000 + 10000 + 20000 + 5000 = 36000.
TX="$W/tx"
mkdir -p "$TX"
txmsg() {  # txmsg <id> <utc time>
    printf '{"type":"assistant","timestamp":"2026-10-16T%s.000Z","message":{"id":"%s","usage":{"input_tokens":1000,"cache_read_input_tokens":100000,"cache_creation_input_tokens":10000,"output_tokens":1000}}}\n' "$2" "$1"
}
{
    printf '%s\n' '{"type":"custom-title","customTitle":"console-s","sessionId":"s1"}'
    txmsg m1 10:00:00; txmsg m1 10:00:01; txmsg m2 10:05:00; txmsg m3 11:30:00
} > "$TX/succ.jsonl"
{
    printf '%s\n' '{"type":"custom-title","customTitle":"console-prev","sessionId":"s0"}'
    txmsg m9 09:50:00; txmsg m10 10:03:00; txmsg m11 10:30:00
} > "$TX/pred.jsonl"
printf '%s\n' '{"type":"custom-title","customTitle":"someone-else","sessionId":"s9"}' "$(txmsg m50 10:01:00)" > "$TX/other.jsonl"
TZ=UTC BOARD_TRANSCRIPTS="$TX" PATH="$W/bin:$PATH" BOARD_TICK="$W/bin/tick-stub-size" TICK_ARGV_LOG="$W/argv.log" \
    BOARD_SESSIONS="$W/bin/sessions-empty.sh" \
    GH_OPEN="$W/open.json" GH_MERGED="$W/merged.json" GH_EPIC="$W/epic.json" GH_VIEW="$W/view" \
    node "$SUT" --doc "$S/console-s.md" --repo "$W/repo" --out "$S/board.html" --json "$S/board.json" >/dev/null 2>"$W/stderr.log"
jtxt="$(cat "$S/board.json" 2>/dev/null)"
jcheck '--json: console cost sums its own messages once each (HIMMEL-5955 5e)' 'M.trends.console_cost.eq === 108000 && M.trends.console_cost.messages === 3'
jcheck '--json: console cost has an hourly trend' 'M.trends.console_cost.hourly.length === 2 && M.trends.console_cost.hourly[0].eq === 72000 && M.trends.console_cost.hourly[1].eq === 36000'
jcheck '--json: console cost sits next to fleet spend' '"fleet_eq" in M.trends.console_cost'
jcheck '--json: succession is a tool-eval row' 'M.trends.tools.length === 1 && M.trends.tools[0].tool === "console-succession" && M.trends.tools[0].from === "console-prev" && M.trends.tools[0].to === "console-s"'
jcheck '--json: succession counts both sessions from successor start to LIVE' 'M.trends.tools[0].turns === 3 && M.trends.tools[0].eq === 108000 && M.trends.tools[0].wall_min === 10'
jcheck '--json: succession counts legs quoted back vs silent' 'M.trends.tools[0].legs_quoted === 2 && M.trends.tools[0].legs_silent === 23'
jcheck '--json: succession passes against the target with a recommendation' 'M.trends.tools[0].pass === true && M.trends.tools[0].target.eq === 457000 && M.trends.tools[0].target.turns === 20 && M.trends.tools[0].recommendation.length > 0'

# --- CR-loop line: rounds per merged PR from the ledger's score heads,
# preflight hits per PR, residual inflow/outflow from the Jira mirror, per-version
# residual slots against the 15 soft cap (a warning colour, never a refusal), open
# restructure tickets, and the plan's before row. RED control (pre-change board.mjs):
# --json has no trends.cr_loop and the page has no data-cr-loop section.
CL="$W/crloop"
mkdir -p "$CL/mirror/HIMMEL"
ago() { date -u -d "$1 days ago" +%Y-%m-%dT%H:%M:%SZ; }
printf '%s\n' '# console' '## Live state' 'epics: none' '' '## Results' > "$CL/console-c.md"
printf '[{"number":3001,"title":"a","mergedAt":"%s","headRefName":"feat/a"},{"number":3002,"title":"b","mergedAt":"%s","headRefName":"feat/b"},{"number":3003,"title":"c","mergedAt":"%s","headRefName":"feat/c"}]\n' \
    "$(ago 1)" "$(ago 2)" "$(ago 10)" > "$CL/merged.json"
{
    for h in h1 h1 h2 h3; do printf '{"kind":"score","ts":"%s","branch":"feat/a","head":"%s","model":"m","critical":0,"important":0,"suggestions":0}\n' "$(ago 1)" "$h"; done
    printf '{"kind":"score","ts":"%s","branch":"feat/b","head":"h4","model":"m","critical":0,"important":0,"suggestions":0}\n' "$(ago 2)"
    for h in o1 o2 o3 o4 o5; do printf '{"kind":"score","ts":"%s","branch":"feat/c","head":"%s","model":"m","critical":0,"important":0,"suggestions":0}\n' "$(ago 10)" "$h"; done
    printf '{"kind":"preflight","ts":"%s","branch":"feat/a","head":"h1","classes":[{"class":"x","state":"fixed"},{"class":"y","state":"waived"}]}\n' "$(ago 1)"
    printf '{"kind":"preflight","ts":"%s","branch":"feat/b","head":"h4","classes":[]}\n' "$(ago 2)"
} > "$CL/ledger.jsonl"
mirror_issue() {  # mirror_issue <key> <labels json> <versions json> <status> <days old> [resolved days ago] [statusCategory]
    {
        printf -- '---\nkey: "%s"\ntype: "Task"\nstatus: "%s"\nstatusCategory: "%s"\nlabels: %s\nfixVersions: %s\n' "$1" "$4" "${7:-$4}" "$2" "$3"
        printf 'created: "%s"\nupdated: "%s"\nresolution: null\n' "$(ago "$5")" "$(ago 0)"
        [ -z "${6:-}" ] || printf 'resolved: "%s"\n' "$(ago "$6")"
        printf -- '---\n\n# %s: t\n' "$1"
    } > "$CL/mirror/HIMMEL/$1.md"
}
mirror_issue HIMMEL-9101 '["residual"]' '["v1.1.3"]' 'To Do' 2
mirror_issue HIMMEL-9102 '["residual-depth-1"]' '["v1.1.3"]' 'To Do' 3
mirror_issue HIMMEL-9103 '["residual"]' '["v1.1.3"]' 'Done' 20
mirror_issue HIMMEL-9104 '["restructure-class-x"]' '[]' 'To Do' 20
mirror_issue HIMMEL-9106 '["residual"]' '["v1.1.3"]' 'Closed' 20 1 Done
mirror_issue HIMMEL-9105 '["theme"]' '["v1.1.3"]' 'To Do' 1
for n in $(seq 9110 9125); do mirror_issue "HIMMEL-$n" '["residual"]' '["v1.1.4"]' 'To Do' 30; done
crrun() {
    PATH="$W/bin:$PATH" BOARD_TICK="$W/bin/tick-stub" TICK_ARGV_LOG="$W/argv.log" \
        BOARD_SESSIONS="$W/bin/sessions-empty.sh" CR_LEDGER="${CL_LEDGER:-$CL/ledger.jsonl}" BOARD_MIRROR="${CL_MIRROR:-$CL/mirror/HIMMEL}" \
        GH_OPEN="$W/open.json" GH_MERGED="$CL/merged.json" GH_EPIC="$W/epic.json" GH_VIEW="$W/view" \
        node "$SUT" --doc "$CL/console-c.md" --repo "$W/repo" --out "$CL/board.html" --json "$CL/board.json" 2>"$W/stderr.log"
}
crrun >/dev/null; rc=$?
contains 'cr-loop: rc 0' "rc=$rc" 'rc=0'
jtxt="$(cat "$CL/board.json" 2>/dev/null)"
chtml="$(cat "$CL/board.html" 2>/dev/null)"
jcheck 'cr-loop --json: rounds per merged PR are distinct score heads per branch, in the window (mean 2, p90 3)' 'M.trends.cr_loop.rounds.prs === 2 && M.trends.cr_loop.rounds.mean === 2 && M.trends.cr_loop.rounds.p90 === 3'
jcheck 'cr-loop --json: preflight hits per PR (2 hits over 2 PRs)' 'M.trends.cr_loop.preflight.hits === 2 && M.trends.cr_loop.preflight.per_pr === 1'
jcheck 'cr-loop --json: residual inflow counts residual-labelled tickets created in the window, not other labels' 'M.trends.cr_loop.residual.inflow === 2'
jcheck 'cr-loop --json: a Done residual with no resolved date makes outflow and net n/a (null), never the updated proxy' 'M.trends.cr_loop.residual.outflow === null && M.trends.cr_loop.residual.net === null && M.trends.cr_loop.residual.outflow_note.includes("HIMMEL-6390")'
jcheck 'cr-loop --json: residual slots per version against the 15 soft cap' 'M.trends.cr_loop.versions.find((v) => v.version === "v1.1.3").slots === 2 && M.trends.cr_loop.versions.find((v) => v.version === "v1.1.4").slots === 16 && M.trends.cr_loop.soft_cap === 15'
jcheck 'cr-loop --json: over the soft cap is flagged, under it is not' 'M.trends.cr_loop.versions.find((v) => v.version === "v1.1.4").over === true && M.trends.cr_loop.versions.find((v) => v.version === "v1.1.3").over === false'
jcheck 'cr-loop --json: open restructure tickets' 'M.trends.cr_loop.restructure_open === 1'
jcheck 'cr-loop --json: the plan section 1 numbers are the before row' 'M.trends.cr_loop.before.rounds_mean === 2.71 && M.trends.cr_loop.before.rounds_p90 === 5 && M.trends.cr_loop.before.residuals_per_merged_pr === 0.41'
contains 'cr-loop html: one data-cr-loop line with rounds per PR and p90' "$chtml" 'rounds/PR 2.0 (p90 3)'
contains 'cr-loop html: residual inflow, with outflow n/a and the ticket that fixes it' "$chtml" 'in 2 · out n/a'
contains 'cr-loop html: a version past 15 carries the warning flag' "$chtml" 'data-cr-version="v1.1.4" data-over="1"'
contains 'cr-loop html: a version under 15 does not' "$chtml" 'data-cr-version="v1.1.3" data-over="0"'
mirror_issue HIMMEL-9103 '["residual"]' '["v1.1.3"]' 'Done' 20 1
crrun >/dev/null
jtxt="$(cat "$CL/board.json" 2>/dev/null)"
jcheck 'cr-loop --json: with a resolved date in the window, outflow is counted and net is inflow minus outflow' 'M.trends.cr_loop.residual.outflow === 1 && M.trends.cr_loop.residual.net === 1'
CL_LEDGER="$W/none.jsonl" CL_MIRROR="$W/none" crrun >/dev/null; rc=$?
jtxt="$(cat "$CL/board.json" 2>/dev/null)"
contains 'cr-loop: an absent ledger and mirror never fail the render (rc 0)' "rc=$rc" 'rc=0'
jcheck 'cr-loop --json: absent ledger and mirror read n/a (null), the before row stays' 'M.trends.cr_loop.rounds.mean === null && M.trends.cr_loop.residual.inflow === null && M.trends.cr_loop.before.rounds_mean === 2.71'
jcheck 'cr-loop --json: no preflight rows yet (S1 not landed) is n/a, not zero' 'M.trends.cr_loop.preflight.per_pr === null'

# --- Cap over-run is a --changed signal: a version crossing the soft cap
# flips CHANGED although tick's fingerprint is unchanged (the stub's is constant).
# RED control (pre-change board.mjs): the cap move reads UNCHANGED.
crchanged() {
    PATH="$W/bin:$PATH" BOARD_TICK="$W/bin/tick-stub" TICK_ARGV_LOG="$W/argv.log" \
        BOARD_SESSIONS="$W/bin/sessions-empty.sh" CR_LEDGER="$CL/ledger.jsonl" BOARD_MIRROR="$CL/mirror/HIMMEL" \
        GH_OPEN="$W/open.json" GH_MERGED="$CL/merged.json" GH_EPIC="$W/epic.json" GH_VIEW="$W/view" \
        node "$SUT" --doc "$CL/console-c.md" --repo "$W/repo" --out "$CL/cap-board.html" --json "$CL/cap-board.json" --changed 2>"$W/stderr.log"
}
rm -f "$CL/cap-board.html"
out="$(crchanged)"; rc=$?
same 'cap --changed: first render reports CHANGED' "$out rc=$rc" "CHANGED $CL/cap-board.html rc=0"
contains 'cap: an over-cap version is embedded as a board signature' "$(cat "$CL/cap-board.html")" 'name="console-board-cap-fp" content="v1.1.4=16"'
out="$(crchanged)"; rc=$?
same 'cap --changed: a re-render with the same over-run reports UNCHANGED' "$out rc=$rc" "UNCHANGED $CL/cap-board.html rc=0"
rm -f "$CL/mirror/HIMMEL/HIMMEL-9124.md" "$CL/mirror/HIMMEL/HIMMEL-9125.md"
out="$(crchanged)"; rc=$?
same 'cap --changed: a version dropping back under the cap flips CHANGED on an unchanged tick fingerprint' "$out rc=$rc" "CHANGED $CL/cap-board.html rc=0"
for n in 9124 9125; do mirror_issue "HIMMEL-$n" '["residual"]' '["v1.1.4"]' 'To Do' 30; done
out="$(crchanged)"; rc=$?
same 'cap --changed: a version crossing the cap again flips CHANGED' "$out rc=$rc" "CHANGED $CL/cap-board.html rc=0"

# --- ICE-parked follow-ups: keys cited as follow-ups in the last 14 days of
# comments that moved to ICE, from the mirror. RED control (pre-change board.mjs): no
# data-ice-followups section and no trends.ice_followups.
ice_issue() {  # ice_issue <key> <comments body>
    { printf -- '---\nkey: "%s"\nstatus: "Done"\nstatusCategory: "Done"\nlabels: []\nfixVersions: []\ncreated: "%s"\nupdated: "%s"\n---\n\n# %s: t\n\n## Description\n\nd\n\n## Comments\n%s\n' "$1" "$(ago 30)" "$(ago 1)" "$1" "$2"; } > "$CL/mirror/HIMMEL/$1.md"
}
ice_issue HIMMEL-9201 "$(printf '\n### Op — %s\n\nMoved to ICE-77. Closing.\n' "$(ago 5)")"
ice_issue HIMMEL-9202 "$(printf '\n### Op — %s\n\nFollow-up: HIMMEL-9201 parked.\n\n### Op — %s\n\nFollow-up HIMMEL-9105 stays open.\n' "$(ago 1)" "$(ago 1)")"
crrun >/dev/null; rc=$?
jtxt="$(cat "$CL/board.json" 2>/dev/null)"
chtml="$(cat "$CL/board.html" 2>/dev/null)"
contains 'ice-followups: rc 0' "rc=$rc" 'rc=0'
jcheck 'ice-followups --json: count and keys are the ICE-moved keys cited as follow-ups in the window' 'M.trends.ice_followups.count === 1 && M.trends.ice_followups.keys.join() === "HIMMEL-9201"'
contains 'ice-followups html: one section with the count and the key' "$chtml" 'data-ice-followups="1"'
contains 'ice-followups html: the key is listed' "$chtml" 'data-ice-key="HIMMEL-9201"'
CL_MIRROR="$W/none" crrun >/dev/null; rc=$?
jtxt="$(cat "$CL/board.json" 2>/dev/null)"
contains 'ice-followups: an absent mirror never fails the render (rc 0)' "rc=$rc" 'rc=0'
jcheck 'ice-followups --json: an absent mirror reads n/a (null count)' 'M.trends.ice_followups.count === null && M.trends.ice_followups.keys.length === 0'
lacks 'ice-followups html: an absent mirror renders no panel' "$(cat "$CL/board.html")" 'data-ice-followups='

# --- classes overdue for escalation: the board reads the PROPOSE lines of
# known-findings.sh --ladder (BOARD_KNOWN_FINDINGS is the seam) and never recomputes the ladder.
cat > "$W/bin/kf-two" <<'STUB'
#!/usr/bin/env bash
[ "$1" = --ladder ] || exit 2
printf '%s\n' 'known-findings ladder: 27 class(es)' 'promotion proposals (printed only):' \
    '  PROPOSE [mktemp-no-template] advisory -> gate recurrences=57 branches=39 host=scripts/lint/shell-lint.sh' \
    '  PROPOSE [hook-fail-direction] advisory -> gate recurrences=19 branches=15 host=a scripts/hooks/ PreToolUse hook' \
    '  PROPOSE [errexit-false-positive] retire disproved=9/10 real_in_30d=0' \
    '  [not-a-proposal] rung=advisory kind=fix agreed=3'
STUB
cat > "$W/bin/kf-none" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' 'known-findings ladder: 27 class(es)' 'promotion proposals (printed only):' '  none'
STUB
chmod +x "$W/bin/kf-two" "$W/bin/kf-none"
BOARD_KNOWN_FINDINGS="$W/bin/kf-two" crrun >/dev/null; rc=$?
jtxt="$(cat "$CL/board.json" 2>/dev/null)"
chtml="$(cat "$CL/board.html" 2>/dev/null)"
contains 'overdue-classes: rc 0' "rc=$rc" 'rc=0'
contains 'overdue-classes html: a section with the count of PROPOSE lines' "$chtml" 'data-overdue-classes="2"'
contains 'overdue-classes html: first proposed class is a row' "$chtml" 'data-overdue-class="mktemp-no-template"'
contains 'overdue-classes html: second proposed class is a row' "$chtml" 'data-overdue-class="hook-fail-direction"'
lacks 'overdue-classes html: a non-PROPOSE ladder line is not a row' "$chtml" 'not-a-proposal'
contains 'overdue-classes html: the row carries the printed proposal text' "$chtml" 'advisory -&gt; gate recurrences=57 branches=39'
lacks 'overdue-classes html: a retire proposal is not an escalation row' "$chtml" 'errexit-false-positive'
jcheck 'overdue-classes --json: the proposed class ids and proposal text, retire excluded' 'M.trends.overdue_classes.length === 2 && M.trends.overdue_classes[0].id === "mktemp-no-template" && M.trends.overdue_classes[0].proposal.startsWith("advisory -> gate recurrences=57")'
BOARD_KNOWN_FINDINGS="$W/bin/kf-none" crrun >/dev/null; rc=$?
contains 'overdue-classes: no proposals is rc 0' "rc=$rc" 'rc=0'
lacks 'overdue-classes html: no proposals renders no panel' "$(cat "$CL/board.html")" 'data-overdue-classes='
BOARD_KNOWN_FINDINGS="$W/bin/absent" crrun >/dev/null; rc=$?
contains 'overdue-classes: an unreadable ladder never fails the render (rc 0)' "rc=$rc" 'rc=0'
lacks 'overdue-classes html: an unreadable ladder renders no panel' "$(cat "$CL/board.html")" 'data-overdue-classes='

# --- usage
PATH="$W/bin:$PATH" node "$SUT" >/dev/null 2>&1; rc=$?
contains 'no --doc is a usage error (rc 2)' "rc=$rc" 'rc=2'
PATH="$W/bin:$PATH" node "$SUT" --doc "$B/nope.md" >/dev/null 2>&1; rc=$?
contains 'a missing console doc is an error (rc 1)' "rc=$rc" 'rc=1'

if [ "$fails" -eq 0 ]; then
    printf '%s\n' 'PASS - test-board.sh'
    exit 0
fi
printf 'FAIL - test-board.sh (%s failure(s))\n' "$fails"
exit 1
