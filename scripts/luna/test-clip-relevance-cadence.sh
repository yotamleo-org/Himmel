#!/usr/bin/env bash
# selector: tree-scan
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
if [ "\$1" = "-l" ]; then
    [ -f "$CR/readfail" ] && { echo "crontab: cannot read: permission denied" >&2; exit 1; }
    [ -f "$CR/tab" ] && { cat "$CR/tab"; exit 0; }; echo "no crontab for test" >&2; exit 1
fi
[ -f "$CR/fail" ] && exit 1
cat >"$CR/tab"
EOF
chmod +x "$STUB/crontab"
cat >"$STUB/claude" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >"$TMP/claude.args"
printf '%s\n' "\$@" >"$TMP/claude.argv"
printf '%s|%s\n' "\${ANTHROPIC_API_KEY-unset}" "\${ANTHROPIC_AUTH_TOKEN-unset}" >"$TMP/claude.env"
echo x >>"$TMP/claude.calls"
[ -f "$TMP/note.fixture" ] && { note="\$(bash "$CAD" note-path)"; mkdir -p "\$(dirname "\$note")"; cp "$TMP/note.fixture" "\$note"; }
if [ -f "$TMP/claude.json" ]; then cat "$TMP/claude.json"; else echo '{"is_error":false,"result":"done"}'; fi
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
sort_lines() { python3 -I -c 'import sys; print("\n".join(sorted(sys.stdin.read().splitlines())))'; }
allowed_in_runner() { sed -n 's/.*--allowedTools //p' "$1" | sed 's/ < \/dev\/null.*$//' | python3 -I -c 'import shlex,sys; print("\n".join(sorted(shlex.split(sys.stdin.read()))))'; }
allowed_in_argv() { sed -n '/^--allowedTools$/,$p' "$1" | sed 1d | sort_lines; }
ALLOWED_EXPECT="$(printf '%s\n' "Read" "Grep" "Edit(/$TMP/notes/**)" \
    "Bash(python3 -I scripts/luna/clip-relevance-collect.py:*)" \
    "Bash(bash scripts/luna/clip-relevance-cadence.sh note-path)" \
    "Bash(bash scripts/luna/clip-relevance-cadence.sh check:*)" \
    "Bash(node $REPO/scripts/jira/dist/index.js list:*)" \
    "Bash(node $REPO/scripts/jira/dist/index.js get:*)" | sort_lines)"
reset_run() { rm -f "$TMP/send.log" "$TMP/alerts.log" "$TMP/notes/2026-11-20"*.md; rm -rf "$TMP/alert-sent"; }

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
check "the runner's --allowedTools is exactly the expected eight entries: Jira list and get only, writes allowed by an Edit rule on the note folder (Write(path) rules match nothing), no bare Edit, Write or Bash(node ...)" \
    '[ "$(allowed_in_runner "$REAL_PF")" = "$ALLOWED_EXPECT" ] && [ "$(allowed_in_runner "$REAL_PF" | wc -l)" = 8 ]'
check "the runner's --tools is exactly Read,Grep,Write,Bash" '[ "$(sed -n "s/.*--tools \([^ ]*\) --allowedTools.*/\1/p" "$REAL_PF")" = "Read,Grep,Write,Bash" ]'
check "the runner hands the result to finish" 'grep -q "clip-relevance-cadence.sh.* finish " "$REAL_PF"'
LUNA_VAULT_PATH=/data/luna bash "$CAD" arm --force >/dev/null 2>&1
check "the arming shell's LUNA_VAULT_PATH is baked into the runner, since cron has none" 'grep -q "^LUNA_VAULT_PATH=/data/luna$" "$RUNNER"'
env -u LUNA_VAULT_PATH bash "$CAD" arm --force >/dev/null 2>&1
check "no LUNA_VAULT_PATH is baked when the arming shell has none, so the collector keeps its default" '! grep -q "LUNA_VAULT_PATH" "$RUNNER"'
baked_of() { bash -c "$(grep '^PATH=' "$1"); printf %s \"\$PATH\""; }
resolves_in() { bash -c 'PATH="$1"; command -v "$2"' _ "$1" "$2"; }
mkdir -p "$TMP/.mount_fixA/usr/bin" "$TMP/.mount_fixB/lib"
PATH="$TMP/.mount_fixA/usr/bin:$TMP/.mount_fixB/lib:$PATH" bash "$CAD" arm --force >/dev/null 2>&1
baked_path="$(baked_of "$RUNNER")"
check "the baked PATH holds no temporary folder from the arming shell, and keeps the system defaults" \
    '[ -n "$baked_path" ] && case ":$baked_path:" in *"/.mount_"*|*":$TMP"*) false ;; *) true ;; esac && case ":$baked_path:" in *":/usr/bin:"*) true ;; *) false ;; esac && case ":$baked_path:" in *":/bin:"*) true ;; *) false ;; esac && case ":$baked_path:" in *":/usr/local/bin:"*) true ;; *) false ;; esac'
tools_ok=1
for t in bash claude node python3 git jq bun; do
    exp="$(command -v "$t" 2>/dev/null)"; [ -n "$exp" ] || continue
    [ "$(resolves_in "$baked_path" "$t")" = "$exp" ] || { tools_ok=0; echo "    unresolved: $t (want $exp)"; }
done
check "the baked PATH still resolves every tool the arming shell resolved (bash claude node python3 git jq bun) to the same file" '[ "$tools_ok" = 1 ]'
printf '#!/bin/sh\nexit 0\n' >"$TMP/.mount_fixA/usr/bin/node"; chmod +x "$TMP/.mount_fixA/usr/bin/node"
PATH="$TMP/.mount_fixA/usr/bin:$PATH" bash "$CAD" arm --force >/dev/null 2>&1
baked_path="$(baked_of "$RUNNER")"
check "a tool that sits first in a temporary folder is skipped: the folder is not baked and node resolves to the next one on PATH" \
    'case ":$baked_path:" in *"/.mount_"*) false ;; *) [ "$(resolves_in "$baked_path" node)" = "$(PATH="${PATH//$TMP\/.mount_fixA\/usr\/bin:/}" command -v node)" ] ;; esac'
rm -f "$TMP/.mount_fixA/usr/bin/node"
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
cp "$TMP/note.fixture" "$TMP/note.good"
printf 'PROCEED\n' >"$TMP/verdict"; rm -f "$TMP/send.log" "$TMP/alerts.log"
export ANTHROPIC_API_KEY=sk-test-sentinel ANTHROPIC_AUTH_TOKEN=tok-test-sentinel
bash "$RUNNER" >"$TMP/fire-ok.out" 2>&1; rc=$?
unset ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN
check "PROCEED runs claude once, rc 0" '[ "$rc" = 0 ] && [ "$(wc -l <"$TMP/claude.calls")" = 1 ]'
check "claude never sees an exported ANTHROPIC_API_KEY or ANTHROPIC_AUTH_TOKEN (env -u): both read unset" '[ "$(cat "$TMP/claude.env")" = "unset|unset" ]'
check "claude is handed exactly the expected --allowedTools set and --tools list" \
    '[ "$(allowed_in_argv "$TMP/claude.argv")" = "$ALLOWED_EXPECT" ] && [ "$(sed -n "/^--tools\$/{n;p;}" "$TMP/claude.argv")" = "Read,Grep,Write,Bash" ]'
check "claude gets the runbook, the pinned model, the explicit mode and JSON output" \
    'grep -q -- "/clip-relevance-weekly" "$TMP/claude.args" && grep -q -- "--model claude-sonnet-5-5" "$TMP/claude.args" && grep -q -- "--permission-mode dontAsk" "$TMP/claude.args" && grep -q -E -- "--max-turns [0-9]+" "$TMP/claude.args" && grep -q -- "--output-format json" "$TMP/claude.args" && grep -q -E -- "(^| )-p( |$)" "$TMP/claude.args"'
check "the note's Telegram block is sent once, as a cadence:clip-relevance message" \
    '[ "$(grep -c "^cadence:clip-relevance|" "$TMP/send.log")" = 1 ] && head -1 "$TMP/send.log" | grep -q "^cadence:clip-relevance|Clip relevance, week to 2026-11-20: 1 new of 2 candidates.$" && grep -q "1. Cap native message volume per session pair" "$TMP/send.log" && ! grep -q "^## " "$TMP/send.log"'
check "a good run raises no alert" '[ ! -s "$TMP/alerts.log" ]'
check "the first note of the day is the plain dated name, and the log and message name it" \
    '[ -s "$TMP/notes/2026-11-20.md" ] && grep -q "note $TMP/notes/2026-11-20.md, message sent" "$TMP/runner/clip-relevance-cadence.log" && grep -q "^Note: specs/audits/clip-relevance/2026-11-20.md$" "$TMP/send.log"'

echo "3b. a run never replaces a note it already wrote"
first_sum="$(cksum "$TMP/notes/2026-11-20.md")"
rm -f "$TMP/send.log" "$TMP/alerts.log"; rm -rf "$TMP/alert-sent"
check "note-path with the day's note present names the first free numbered name, inside the note folder" \
    '[ "$(bash "$CAD" note-path)" = "$TMP/notes/2026-11-20-2.md" ]'
bash "$RUNNER" >"$TMP/fire-second.out" 2>&1; rc=$?
check "a second run the same day leaves the first note byte for byte and writes 2026-11-20-2.md" \
    '[ "$rc" = 0 ] && [ "$(cksum "$TMP/notes/2026-11-20.md")" = "$first_sum" ] && [ -s "$TMP/notes/2026-11-20-2.md" ]'
check "the log line names the note actually written" 'grep -q "note $TMP/notes/2026-11-20-2.md, message sent" "$TMP/runner/clip-relevance-cadence.log"'
check "the Telegram message names the note actually written, though the model wrote the plain name" \
    '[ "$(grep -c "^cadence:clip-relevance|" "$TMP/send.log")" = 1 ] && grep -q "^Note: specs/audits/clip-relevance/2026-11-20-2.md$" "$TMP/send.log" && ! grep -q "^Note: specs/audits/clip-relevance/2026-11-20.md$" "$TMP/send.log"'
check "the second note passes the same check as the first" '[ ! -s "$TMP/alerts.log" ]'
rm -f "$TMP/send.log"
bash "$RUNNER" >"$TMP/fire-third.out" 2>&1
check "a third run writes 2026-11-20-3.md and leaves the first two alone" \
    '[ -s "$TMP/notes/2026-11-20-3.md" ] && [ "$(cksum "$TMP/notes/2026-11-20.md")" = "$first_sum" ] && [ "$(ls "$TMP/notes" | wc -l)" = 3 ] && grep -q "^Note: specs/audits/clip-relevance/2026-11-20-3.md$" "$TMP/send.log"'
rm -f "$TMP/notes/2026-11-20-2.md" "$TMP/notes/2026-11-20-3.md"

echo "4. failures are loud and send no proposals"
rm -f "$TMP/send.log" "$TMP/alerts.log"; rm -rf "$TMP/alert-sent"; echo 3 >"$TMP/claude.rc"
bash "$RUNNER" >"$TMP/fire-rc.out" 2>&1
check "a failed claude raises the alert and sends no proposal" 'grep -q " clip-relevance claude-rc-3 " "$TMP/alerts.log" && ! grep -q "1 new of 2" "$TMP/send.log"'
rm -f "$TMP/claude.rc"; cp "$TMP/note.good" "$TMP/note.fixture"
reset_run; printf '%s\n' '{"is_error":true,"result":"overloaded"}' >"$TMP/claude.json"
bash "$RUNNER" >"$TMP/fire-iserr.out" 2>&1
check "claude exiting 0 with is_error:true raises claude-error and sends no proposal, though the note is good" 'grep -q " clip-relevance claude-error " "$TMP/alerts.log" && ! grep -q "1 new of 2" "$TMP/send.log"'
reset_run; printf 'this is not json' >"$TMP/claude.json"
bash "$RUNNER" >"$TMP/fire-badjson.out" 2>&1
check "claude exiting 0 with unreadable output raises claude-error and sends no proposal, though the note is good" 'grep -q " clip-relevance claude-error " "$TMP/alerts.log" && ! grep -q "1 new of 2" "$TMP/send.log"'
rm -f "$TMP/claude.json"; reset_run
printf '# thin note\n\n## Candidates\n\n### 1. No search line [new]\n- Change: x\n\n## Telegram message\nhello\n' >"$TMP/note.fixture"
bash "$RUNNER" >"$TMP/fire-bad.out" 2>&1
check "an invalid note raises the alert and sends no proposal" 'grep -q " clip-relevance note-invalid " "$TMP/alerts.log" && ! grep -q "hello" "$TMP/send.log"'
rm -f "$TMP/send.log" "$TMP/alerts.log"; rm -rf "$TMP/alert-sent"; rm -f "$TMP/note.fixture" "$TMP/notes/2026-11-20.md"
bash "$RUNNER" >"$TMP/fire-nonote.out" 2>&1
check "no note at all raises the alert" 'grep -q " clip-relevance note-invalid " "$TMP/alerts.log"'
rm -f "$TMP/send.log" "$TMP/alerts.log"; rm -rf "$TMP/alert-sent"
mkdir -p "$TMP/notes"; printf '## Candidates\n\n## Telegram message\nan earlier run sent this\n' >"$TMP/notes/2026-11-20.md"
bash "$RUNNER" >"$TMP/fire-stale.out" 2>&1
check "a run that returns success without writing a note cannot resend the earlier one, and leaves it untouched" \
    'grep -q " clip-relevance note-invalid " "$TMP/alerts.log" && ! grep -q "an earlier run sent this" "$TMP/send.log" && grep -q "an earlier run sent this" "$TMP/notes/2026-11-20.md"'

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
tg7="$TMP/tg7.md"; tg8="$TMP/tg8.md"
{ printf '## Candidates\n\n'; for i in 1 2 3 4 5; do printf '### %s. C%s [new]\n- Search: s\n\n' "$i" "$i"; done; printf '## Telegram message\nOpening.\n1. a\n2. b\n3. c\n4. d\n5. e\nNote: n\n'; } >"$tg7"
{ cat "$tg7"; printf 'one too many\n'; } >"$tg8"
check "five new candidates fit the Telegram block (opening, five titles, note line: 7 lines)" 'bash "$CAD" check "$tg7" >/dev/null 2>&1'
bash "$CAD" check "$tg8" >"$TMP/check-tg8.out" 2>&1; rc=$?
check "an eighth Telegram line fails" '[ "$rc" = 1 ] && grep -q "longer than 7 lines" "$TMP/check-tg8.out"'
cap_note() { printf '## Candidates\n\n### 1. C [new]\n- Search: s\n\n## Telegram message\n%s\n' "$(printf '%*s' "$1" '' | tr ' ' x)" >"$2"; }
cap_note 1500 "$TMP/cap1500.md"; cap_note 1501 "$TMP/cap1501.md"
check "a Telegram block of exactly 1,500 characters passes" 'bash "$CAD" check "$TMP/cap1500.md" >/dev/null 2>&1'
bash "$CAD" check "$TMP/cap1501.md" >"$TMP/check-cap.out" 2>&1; rc=$?
check "a Telegram block of 1,501 characters fails with the character cap named" '[ "$rc" = 1 ] && grep -q "longer than 1500 characters" "$TMP/check-cap.out"'
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
badhead="$TMP/badhead.md"
{ printf '## Candidates\n\n'; for i in 1 2 3 4 5 6; do printf '### Change %s [new]\n- Search: s\n\n' "$i"; done; printf '## Telegram message\nx\n'; } >"$badhead"
bash "$CAD" check "$badhead" >"$TMP/check-bh.out" 2>&1; rc=$?
check "six unnumbered ### headings in Candidates are refused, not counted as zero candidates" '[ "$rc" = 1 ] && grep -q "not a numbered candidate" "$TMP/check-bh.out"'
zero="$TMP/zero.md"
printf '## Candidates\n\nNothing new this week.\n\n## Telegram message\nNothing new this week.\n' >"$zero"
check "a quiet week with no candidate is valid" 'bash "$CAD" check "$zero" >/dev/null 2>&1'
rm -f "$TMP/notes/2026-11-20"*.md
check "note-path is the note folder plus the day" '[ "$(bash "$CAD" note-path)" = "$TMP/notes/2026-11-20.md" ]'

echo "6. the crontab edges"
rm -f "$CR/tab"; rm -rf "$TMP/runner"
bash "$CAD" arm >/dev/null 2>&1
cp "$CR/tab" "$TMP/tab.armed"; cp "$RUNNER" "$TMP/runner.armed"
touch "$CR/readfail"
bash "$CAD" arm --force --time 21:05 >"$TMP/arm-rf.out" 2>&1; rc=$?
check "a crontab that cannot be read (not 'no crontab for') refuses arm: rc 4, the message, row and runner untouched" \
    '[ "$rc" = 4 ] && grep -q "cannot read the crontab" "$TMP/arm-rf.out" && cmp -s "$CR/tab" "$TMP/tab.armed" && cmp -s "$RUNNER" "$TMP/runner.armed"'
bash "$CAD" status >/dev/null 2>&1; rc=$?
check "status exits 1 when the crontab cannot be read" '[ "$rc" = 1 ]'
bash "$CAD" disarm >/dev/null 2>&1; rc=$?
check "disarm exits 4 when the crontab cannot be read, and removes neither the row nor the runner" '[ "$rc" = 4 ] && cmp -s "$CR/tab" "$TMP/tab.armed" && [ -x "$RUNNER" ]'
rm -f "$CR/readfail"
touch "$CR/fail"
bash "$CAD" arm --force --time 21:05 >"$TMP/arm-if.out" 2>&1; rc=$?
rm -f "$CR/fail"
check "a failed crontab install: rc 4, 'crontab install failed', the armed row and runner untouched, no .new left" \
    '[ "$rc" = 4 ] && grep -q "crontab install failed" "$TMP/arm-if.out" && cmp -s "$CR/tab" "$TMP/tab.armed" && cmp -s "$RUNNER" "$TMP/runner.armed" && [ ! -e "$RUNNER.new" ]'
MVF="$TMP/mvfail"; mkdir -p "$MVF"; printf '#!/usr/bin/env bash\nexit 1\n' >"$MVF/mv"; chmod +x "$MVF/mv"
PATH="$MVF:$PATH" bash "$CAD" arm --force --time 21:05 >"$TMP/arm-mv.out" 2>&1; rc=$?
check "a failed runner move restores the previous crontab: rc 4, 'crontab restored', the old row and runner back, no .new left" \
    '[ "$rc" = 4 ] && grep -q "crontab restored" "$TMP/arm-mv.out" && cmp -s "$CR/tab" "$TMP/tab.armed" && cmp -s "$RUNNER" "$TMP/runner.armed" && [ ! -e "$RUNNER.new" ]'
printf '%s\n' '45 8 * * 1 /a/clip-relevance-cadence.sh # HIMMEL-ClipRelevance' '50 9 * * * /b/runner.sh # HIMMEL-ClipRelevance' >"$CR/tab"
cp "$CR/tab" "$TMP/tab.dup"
bash "$CAD" arm --force >"$TMP/arm-dup.out" 2>&1; rc=$?
check "two live tagged rows: arm --force refuses (rc 5), names the second row, crontab untouched" \
    '[ "$rc" = 5 ] && cmp -s "$CR/tab" "$TMP/tab.dup" && grep -q "/b/runner.sh" "$TMP/arm-dup.out"'

echo "test-clip-relevance-cadence: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
