#!/usr/bin/env bash
# selector: tree-scan
# scripts/luna/test-clip-relevance-cadence.sh - hermetic suite for the weekly clip-relevance cadence.
# Stub crontab, stub claude, stub preflight, stub Telegram sender, scratch runner and note dirs; never the real
# crontab, ~/.himmel, a vault, a Jira call or a model call.
#  1. arm: dry-run writes nothing, a key is required, one tagged weekly row, a second arm refuses, --force
#     replaces only the exact row, status and disarm read and remove it;
#  2. the generated runner holds the usage check, the pinned model, an explicit permission mode that is not
#     bypass, JSON output, and a tool allowlist with no way to file or edit a ticket;
#  3. firing the runner: SKIPPED-BANK skips, PROCEED runs claude with those flags and sends the note's message;
#  4. a failed claude, an invalid note and a failed send each raise the shared alert and send no proposals;
#  5. check: at most five candidates, each marked and carrying its search, plus a Telegram block.
#
# check() evals its condition, so the single quotes are deliberate.
# shellcheck disable=SC2016,SC2034
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
CAD="$HERE/clip-relevance-cadence.sh"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/clip-relevance-cadence-test.XXXXXX")" || { echo "test-clip-relevance-cadence: mktemp -d failed" >&2; exit 1; }
trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok() { PASS=$((PASS + 1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  FAIL $1"; }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }

echo "0. RED guard: the cadence exists"
check "clip-relevance-cadence.sh is present" '[ -f "$CAD" ]'

STUB="$TMP/stub"; mkdir -p "$STUB" "$TMP/cron"
CR="$TMP/cron"
cat >"$STUB/crontab" <<EOF
#!/usr/bin/env bash
if [ "\$1" = "-l" ]; then [ -f "$CR/tab" ] && { cat "$CR/tab"; exit 0; }; echo "no crontab for test" >&2; exit 1; fi
[ -f "$CR/fail" ] && exit 1
cat >"$CR/tab"
EOF
chmod +x "$STUB/crontab"
cat >"$STUB/claude" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >"$TMP/claude.args"
echo x >>"$TMP/claude.calls"
[ -f "$TMP/note.fixture" ] && { mkdir -p "\$CLIP_RELEVANCE_NOTE_DIR"; cp "$TMP/note.fixture" "\$CLIP_RELEVANCE_NOTE_DIR/\$CLIP_RELEVANCE_TODAY.md"; }
echo '{"is_error":false,"result":"done"}'
exit "\$(cat "$TMP/claude.rc" 2>/dev/null || echo 0)"
EOF
chmod +x "$STUB/claude"
cat >"$STUB/send" <<EOF
#!/usr/bin/env bash
printf '%s|%s\n' "\$HIMMEL_ALERT_KIND" "\$1" >>"$TMP/send.log"
[ -f "$TMP/send.fail" ] && exit 1
exit 0
EOF
chmod +x "$STUB/send"
printf '#!/usr/bin/env bash\ncat "%s/verdict"\n' "$TMP" >"$STUB/preflight"; chmod +x "$STUB/preflight"

export TZ=UTC HOME="$TMP/home"; mkdir -p "$HOME"
export CLIP_RELEVANCE_CRONTAB="$STUB/crontab" CLIP_RELEVANCE_RUNNER_DIR="$TMP/runner" CLIP_RELEVANCE_NOTE_DIR="$TMP/notes"
export CLIP_RELEVANCE_SEND_CMD="$STUB/send" CLIP_RELEVANCE_TODAY=2026-11-20 CLIP_RELEVANCE_PREFLIGHT="$STUB/preflight"
export CLIP_RELEVANCE_ROOT="$REPO" CLIP_RELEVANCE_CLAUDE="$STUB/claude" JIRA_PROJECT_KEY=HIMMEL
export CADENCE_ALERT_FILE="$TMP/alerts.log" CADENCE_ALERT_DEDUPE_DIR="$TMP/alert-sent" CADENCE_ALERT_SEND_CMD="$STUB/send" CADENCE_ALERT_SEND_FAILED_MARK="$TMP/alert-send-failed"
RUNNER="$TMP/runner/clip-relevance-cadence.sh"

echo "1. arm, status, disarm"
bash "$CAD" arm --dry-run >"$TMP/arm-dry.out" 2>&1
check "arm --dry-run writes nothing" '[ ! -f "$CR/tab" ] && [ ! -e "$RUNNER" ] && grep -q "^DRY clip-relevance-cadence" "$TMP/arm-dry.out"'
env -u JIRA_PROJECT_KEY bash "$CAD" arm >"$TMP/arm-nokey.out" 2>&1; rc=$?
check "arm with no JIRA_PROJECT_KEY refuses (rc 2) and changes nothing" '[ "$rc" = 2 ] && grep -q JIRA_PROJECT_KEY "$TMP/arm-nokey.out" && [ ! -f "$CR/tab" ]'
bash "$CAD" arm >"$TMP/arm.out" 2>&1; rc=$?
check "arm exits 0 and installs one tagged weekly row (Monday 08:15)" '[ "$rc" = 0 ] && [ "$(grep -c "# HIMMEL-ClipRelevance$" "$CR/tab")" = 1 ] && grep -q "^15 08 \* \* 1 " "$CR/tab"'
check "the runner is executable" '[ -x "$RUNNER" ]'
bash "$CAD" arm >/dev/null 2>&1; rc=$?
check "a second arm without --force refuses (rc 3)" '[ "$rc" = 3 ]'
bash "$CAD" arm --force --day 3 --time 21:05 >/dev/null 2>&1
check "arm --force --day --time replaces the row" '[ "$(grep -c "# HIMMEL-ClipRelevance$" "$CR/tab")" = 1 ] && grep -q "^05 21 \* \* 3 " "$CR/tab"'
bash "$CAD" arm --force --time 25:00 >/dev/null 2>&1; rc=$?
check "a bad --time refuses (rc 1)" '[ "$rc" = 1 ]'
check "status shows it armed" 'bash "$CAD" status | grep -q "^ARMED .*HIMMEL-ClipRelevance"'
seed_tab() {
    printf '%s\n' '0 3 * * * /usr/bin/backup' '' '15 6 * * * /opt/x/runner.sh # HIMMEL-ClipRelevanceOther' \
        '#30 7 * * 1 /old/runner.sh # HIMMEL-ClipRelevance' '' '45 8 * * 1 /old/clip-relevance-cadence.sh # HIMMEL-ClipRelevance' \
        '5 9 * * * /usr/bin/last' >"$CR/tab"
    cp "$CR/tab" "$TMP/seed.tab"
}
seed_tab
bash "$CAD" arm --force >/dev/null 2>&1; rc=$?
diff "$TMP/seed.tab" "$CR/tab" >"$TMP/seed.diff"
check "arm --force replaces only the exact live row; lookalike, commented, unrelated and blank lines stay" \
    '[ "$rc" = 0 ] && [ "$(grep -c "^<" "$TMP/seed.diff")" = 1 ] && [ "$(grep -c "^>" "$TMP/seed.diff")" = 1 ] && grep -q "^< 45 8 .* # HIMMEL-ClipRelevance$" "$TMP/seed.diff"'
seed_tab
bash "$CAD" disarm >/dev/null 2>&1
diff "$TMP/seed.tab" "$CR/tab" >"$TMP/seed.diff"
check "disarm removes only the exact live row, and the runner" \
    '[ "$(grep -c "^<" "$TMP/seed.diff")" = 1 ] && [ "$(grep -c "^>" "$TMP/seed.diff")" = 0 ] && [ ! -e "$RUNNER" ]'
check "status then says not armed" 'bash "$CAD" status | grep -q "^not armed  HIMMEL-ClipRelevance"'
rm -f "$CR/tab"

echo "2. the generated runner"
bash "$CAD" arm >/dev/null 2>&1
REAL_PF="$TMP/real-pf-runner"
env -u CLIP_RELEVANCE_PREFLIGHT bash "$CAD" arm --force >/dev/null 2>&1; cp "$RUNNER" "$REAL_PF"
check "it asks scripts/lib/usage-preflight.sh before it spends" 'grep -q "scripts/lib/usage-preflight.sh" "$REAL_PF"'
check "the model is pinned" 'grep -q -- "--model claude-sonnet-5-5" "$REAL_PF"'
check "the permission mode is explicit and is not bypass" 'grep -q -- "--permission-mode dontAsk" "$REAL_PF" && ! grep -q -i "bypassPermissions" "$REAL_PF" && ! grep -q -- "--dangerously-skip-permissions" "$REAL_PF"'
check "the result is JSON" 'grep -q -- "--output-format json" "$REAL_PF"'
check "a looping agent is bounded by a turn cap" 'grep -q -E -- "--max-turns [0-9]+" "$REAL_PF"'
check "the weekly runbook is the prompt" 'grep -q -- "/clip-relevance-weekly" "$REAL_PF"'
check "repo search is the Grep tool: no Bash git grep, whose -O flag runs a command" 'grep -q -- "--tools Read,Grep,Write,Bash" "$REAL_PF" && ! grep -q "Bash(git" "$REAL_PF"'
check "the Jira key is baked, since cron has none" 'grep -q "JIRA_PROJECT_KEY=HIMMEL" "$REAL_PF"'
check "the allowlist reads Jira with list and get only: no create, comment or transition" \
    'grep -q "jira/dist/index.js list:" "$REAL_PF" && grep -q "jira/dist/index.js get:" "$REAL_PF" && ! grep -q -E "index.js (create|comment|transition|edit|update)" "$REAL_PF"'
check "a write is allowed only inside the note folder (absolute path rule, //path)" 'grep -qF "Write(/$TMP/notes/**)" "$REAL_PF" && ! grep -q "Edit(" "$REAL_PF"'
check "the runner hands the result to finish" 'grep -q "clip-relevance-cadence.sh.* finish " "$REAL_PF"'
bash "$CAD" arm --force >/dev/null 2>&1

echo "3. firing the runner"
printf 'SKIPPED-BANK\n' >"$TMP/verdict"
bash "$RUNNER" >"$TMP/fire-skip.out" 2>&1; rc=$?
check "SKIPPED-BANK skips: rc 0, claude never called" '[ "$rc" = 0 ] && [ ! -f "$TMP/claude.calls" ] && grep -q "skipped" "$TMP/runner/clip-relevance-cadence.log"'
cat >"$TMP/note.fixture" <<'EOF'
# Clip relevance, week ending 2026-11-20

Clips read 12 (2 thin). Candidates 2: 1 new, 1 already-done.

## Candidates

### 1. Cap native message volume per session pair [new]
- Change: count SendMessage per pair and deny past a limit.
- Clips: Clippings/_evidence/synthetic-one.md
- Search: git grep -n SendMessage -- scripts/hooks returned no counter; Jira text ~ "SendMessage" AND text ~ "cap" returned no match.
- Decision: no hit in the repo or Jira.

### 2. Cap default effort below max [already-done]
- Change: run mechanical chunks at low first.
- Clips: Clippings/_evidence/synthetic-two.md
- Search: git grep -n -i "effort ladder" -- docs found docs/tooling-catalog.md.
- Decision: the repo already does it.

## Telegram message
Clip relevance, week to 2026-11-20: 1 new of 2 candidates.
1. Cap native message volume per session pair
Note: specs/audits/clip-relevance/2026-11-20.md
EOF
printf 'PROCEED\n' >"$TMP/verdict"; rm -f "$TMP/send.log" "$TMP/alerts.log"
bash "$RUNNER" >"$TMP/fire-ok.out" 2>&1; rc=$?
check "PROCEED runs claude once, rc 0" '[ "$rc" = 0 ] && [ "$(wc -l <"$TMP/claude.calls")" = 1 ]'
check "claude gets the runbook, the pinned model, the explicit mode and JSON output" \
    'grep -q -- "/clip-relevance-weekly" "$TMP/claude.args" && grep -q -- "--model claude-sonnet-5-5" "$TMP/claude.args" && grep -q -- "--permission-mode dontAsk" "$TMP/claude.args" && grep -q -E -- "--max-turns [0-9]+" "$TMP/claude.args" && grep -q -- "--output-format json" "$TMP/claude.args" && grep -q -E -- "(^| )-p( |$)" "$TMP/claude.args"'
check "the note's Telegram block is sent once, as a cadence:clip-relevance message" \
    '[ "$(grep -c "^cadence:clip-relevance|" "$TMP/send.log")" = 1 ] && head -1 "$TMP/send.log" | grep -q "^cadence:clip-relevance|Clip relevance, week to 2026-11-20: 1 new of 2 candidates.$" && grep -q "1. Cap native message volume per session pair" "$TMP/send.log" && ! grep -q "^## " "$TMP/send.log"'
check "a good run raises no alert" '[ ! -s "$TMP/alerts.log" ]'

echo "4. failures are loud and send no proposals"
rm -f "$TMP/send.log" "$TMP/alerts.log"; rm -rf "$TMP/alert-sent"; echo 3 >"$TMP/claude.rc"
bash "$RUNNER" >"$TMP/fire-rc.out" 2>&1
check "a failed claude raises the alert and sends no proposal" 'grep -q " clip-relevance claude-rc-3 " "$TMP/alerts.log" && ! grep -q "1 new of 2" "$TMP/send.log"'
rm -f "$TMP/claude.rc" "$TMP/send.log" "$TMP/alerts.log"; rm -rf "$TMP/alert-sent"
printf '# thin note\n\n## Candidates\n\n### 1. No search line [new]\n- Change: x\n\n## Telegram message\nhello\n' >"$TMP/note.fixture"
bash "$RUNNER" >"$TMP/fire-bad.out" 2>&1
check "an invalid note raises the alert and sends no proposal" 'grep -q " clip-relevance note-invalid " "$TMP/alerts.log" && ! grep -q "hello" "$TMP/send.log"'
rm -f "$TMP/send.log" "$TMP/alerts.log"; rm -rf "$TMP/alert-sent"; rm -f "$TMP/note.fixture"
bash "$RUNNER" >"$TMP/fire-nonote.out" 2>&1
check "no note at all raises the alert" 'grep -q " clip-relevance note-invalid " "$TMP/alerts.log"'

echo "5. check"
good="$TMP/good.md"
cat >"$good" <<'EOF'
# Clip relevance, week ending 2026-11-20

## Candidates

### 1. A change [new]
- Search: git grep -n x returned nothing.

### 2. Another [already-tracked]
- Search: Jira text ~ "y" returned HIMMEL-1.

## Telegram message
One line.
EOF
bash "$CAD" check "$good" >"$TMP/check-good.out" 2>&1; rc=$?
check "a valid note passes and prints the message that would be sent" '[ "$rc" = 0 ] && grep -q "2 candidates: 1 new, 0 already-done, 1 already-tracked" "$TMP/check-good.out" && grep -q "^One line.$" "$TMP/check-good.out"'
six="$TMP/six.md"
{ printf '## Candidates\n\n'; for i in 1 2 3 4 5 6; do printf '### %s. C%s [new]\n- Search: s\n\n' "$i" "$i"; done; printf '## Telegram message\nx\n'; } >"$six"
bash "$CAD" check "$six" >"$TMP/check-six.out" 2>&1; rc=$?
check "six candidates fail" '[ "$rc" = 1 ] && grep -q "more than five" "$TMP/check-six.out"'
five="$TMP/five.md"
{ printf '## Candidates\n\n'; for i in 1 2 3 4 5; do printf '### %s. C%s [already-done]\n- Search: s\n\n' "$i" "$i"; done; printf '## Telegram message\nx\n'; } >"$five"
check "five candidates pass" 'bash "$CAD" check "$five" >/dev/null 2>&1'
badstatus="$TMP/badstatus.md"
printf '## Candidates\n\n### 1. C [maybe]\n- Search: s\n\n## Telegram message\nx\n' >"$badstatus"
bash "$CAD" check "$badstatus" >"$TMP/check-bs.out" 2>&1; rc=$?
check "a status other than new, already-done or already-tracked fails" '[ "$rc" = 1 ] && grep -q "status" "$TMP/check-bs.out"'
nosearch="$TMP/nosearch.md"
printf '## Candidates\n\n### 1. C [new]\n- Change: x\n\n## Telegram message\nx\n' >"$nosearch"
bash "$CAD" check "$nosearch" >"$TMP/check-ns.out" 2>&1; rc=$?
check "a candidate with no Search line fails" '[ "$rc" = 1 ] && grep -q "Search" "$TMP/check-ns.out"'
notg="$TMP/notg.md"
printf '## Candidates\n\n### 1. C [new]\n- Search: s\n' >"$notg"
bash "$CAD" check "$notg" >"$TMP/check-nt.out" 2>&1; rc=$?
check "a note with no Telegram block fails" '[ "$rc" = 1 ] && grep -q "Telegram" "$TMP/check-nt.out"'
bash "$CAD" check "$TMP/no-such-note.md" >/dev/null 2>&1; rc=$?
check "a missing note fails" '[ "$rc" = 1 ]'
zero="$TMP/zero.md"
printf '## Candidates\n\nNothing new this week.\n\n## Telegram message\nNothing new this week.\n' >"$zero"
check "a quiet week with no candidate is valid" 'bash "$CAD" check "$zero" >/dev/null 2>&1'
check "note-path is the note folder plus the day" '[ "$(bash "$CAD" note-path)" = "$TMP/notes/2026-11-20.md" ]'

echo "test-clip-relevance-cadence: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
