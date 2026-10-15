#!/usr/bin/env bash
# test-parked-on-prompt.sh — Hermetic tests for parked-on-prompt.sh, which
# reads the trust shadow ledger and names a leg whose newest ledger row is an
# unanswered permission prompt. The ledger is a fixture under a temp dir
# (--ledger); the real ~/.claude/himmel/trust ledger is never read.
#
# PLATFORM GUARD: no .ps1 twin, by design — the console kit is Linux-only
# (GNU date -d); this Bash 3.2 suite exercises that platform-specific script.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="$HERE/parked-on-prompt.sh"
W="$(mktemp -d "${TMPDIR:-/tmp}/parked-on-prompt-test.XXXXXX")" || exit 1
trap 'rm -rf "$W"' EXIT
fails=0

pass() { printf 'ok - %s\n' "$1"; }
fail() { printf 'FAIL - %s\n' "$1"; fails=$((fails + 1)); }
eq() { # eq <label> <expected> <actual>
    if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (expected '$2', got '$3')"; fi
}

S1=11111111-1111-4111-8111-111111111111
S2=22222222-2222-4222-8222-222222222222
ago() { date -u -d "-$1 minutes" +%Y-%m-%dT%H:%M:%S.000Z; }  # gnu-ok: Linux-only kit
row() { # row <minutes-ago> <session> <kind> [notification_type]
    if [ -n "${4:-}" ]; then
        printf '{"ts":"%s","kind":"%s","session_id":"%s","notification_type":"%s"}\n' "$(ago "$1")" "$3" "$2" "$4"
    else
        printf '{"ts":"%s","kind":"%s","session_id":"%s"}\n' "$(ago "$1")" "$3" "$2"
    fi
}
doc() { # doc <name> <session-id> -> path of a leg doc whose frontmatter names the session
    printf -- '---\nresume_cwd: /x\nsession_ids: %s\n---\n\n# leg\n' "$2" > "$W/$1.md"
    printf '%s\n' "$W/$1.md"
}
run() { bash "$SUT" --ledger "$W/ledger.jsonl" "$@" 2>/dev/null; }

D1="$(doc legA "$S1")"

# a permission_request nobody answered, older than the floor
{ row 30 "$S1" request; row 12 "$S1" permission_request; } > "$W/ledger.jsonl"
eq 'unanswered permission_request older than the floor is parked' 'parked=legA:12m' "$(run --min 5 "$D1")"

# the operator answered: an outcome row follows
{ row 12 "$S1" permission_request; row 11 "$S1" outcome; } > "$W/ledger.jsonl"
eq 'a later outcome row clears it' 'parked=none' "$(run --min 5 "$D1")"

# too fresh to call parked
{ row 1 "$S1" permission_request; } > "$W/ledger.jsonl"
eq 'younger than the floor is not parked' 'parked=none' "$(run --min 5 "$D1")"

# the Notification surface
{ row 9 "$S1" notification permission_prompt; } > "$W/ledger.jsonl"
eq 'a permission_prompt notification is parked' 'parked=legA:9m' "$(run --min 5 "$D1")"
{ row 9 "$S1" notification idle_prompt; } > "$W/ledger.jsonl"
eq 'an idle_prompt notification is not parked' 'parked=none' "$(run --min 5 "$D1")"

# another session's later rows never answer this session's prompt
{ row 12 "$S1" permission_request; row 2 "$S2" outcome; } > "$W/ledger.jsonl"
eq 'rows of another session do not clear it' 'parked=legA:12m' "$(run --min 5 "$D1")"

# two legs, one parked
D2="$(doc legB "$S2")"
eq 'only the parked leg is named' 'parked=legA:12m' "$(run --min 5 "$D1" "$D2")"

# no ledger, no session_ids
rm -f "$W/ledger.jsonl"
eq 'no ledger is parked=none' 'parked=none' "$(run --min 5 "$D1")"
printf '# no frontmatter\n' > "$W/bare.md"
{ row 12 "$S1" permission_request; } > "$W/ledger.jsonl"
eq 'a doc without session_ids is skipped' 'parked=none' "$(run --min 5 "$W/bare.md")"

# the floor comes from TICK_PARKED_MIN when --min is absent
eq 'TICK_PARKED_MIN sets the floor' 'parked=none' "$(TICK_PARKED_MIN=20 run "$D1")"

# a trailing option with no value terminates instead of looping
out="$(timeout 5 bash "$SUT" --ledger "$W/ledger.jsonl" "$D1" --min 2>/dev/null)"; rc=$?
eq 'a trailing --min terminates' '0:parked=legA:12m' "$rc:$out"
out="$(timeout 5 bash "$SUT" "$D1" --ledger 2>/dev/null)"; rc=$?
eq 'a trailing --ledger terminates' '0:parked=none' "$rc:$out"

# a relaunched leg appends a new session id (oldest first): only the newest
# id that has rows is judged
D3="$(doc legC "$S1,$S2")"
{ row 900 "$S1" permission_request; row 3 "$S2" outcome; } > "$W/ledger.jsonl"
eq 'an old parked session does not park the relaunched leg' 'parked=none' "$(run --min 5 "$D3")"
{ row 900 "$S1" permission_request; row 8 "$S2" permission_request; } > "$W/ledger.jsonl"
eq 'the newest session parked is named with its own age' 'parked=legC:8m' "$(run --min 5 "$D3")"
{ row 900 "$S1" permission_request; } > "$W/ledger.jsonl"
eq 'a newest id without rows falls back to the previous id' 'parked=legC:900m' "$(run --min 5 "$D3")"

[ "$fails" -eq 0 ] || { printf '%s failure(s)\n' "$fails"; exit 1; }
printf 'all passed\n'
