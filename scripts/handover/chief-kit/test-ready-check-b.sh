#!/usr/bin/env bash
# scripts/handover/chief-kit/test-ready-check-b.sh - ready-check.sh suite, part b: the disposition, carry, chain and terminal deferral rows of check 7.
# Setup, stubs and helpers are shared in test_ready_check_lib.sh. `gh` is a PATH stub; `jq` and `git` are real.
# shellcheck disable=SC2015,SC2034,SC2153,SC2154  # A && B || C is intentional in check()/contains(), as in test-go.sh; stub state and helpers are shared through the sourced lib
set -uo pipefail
# shellcheck source=test_ready_check_lib.sh
. "$(cd "$(dirname "$0")" && pwd)/test_ready_check_lib.sh"

REVHEAD=cafebabecafebabecafebabecafebabecafebabe
SEED_BRANCH=feat/himmel-100-thing
# --- disposition: a code-changing push after a judged head, the chief's signed follow-up disposition row at the new head carries the deferral ---
# Row 7 reads a disposition row only where cr-disposition.sh check reads it: the full PR head, this PR, a Critical or Important finding, a valid mac.
DISP_HOME="$tmp/disp-home"; mkdir -p "$DISP_HOME/.config/himmel"
printf '%s\n' 0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef > "$DISP_HOME/.config/himmel/go-hmac.key"
DISP_ATT=ci-green,no-data-loss,no-weakened-guard
RUN_HOME="$DISP_HOME"
# seed_imp_deferral <KEY> <head> [severity]: a finding deferred to KEY at <head>, the row a worker leaves before the judge rules
seed_imp_deferral() {
    printf '{"kind":"finding","ts":"2026-01-01T00:00:01Z","branch":"%s","head":"%s","model":"codex","finding_id":"codex-imp","severity":"%s","verdict":"deferred","deferred_to":"%s","fu_class":"polish","reason":"out of scope","artifact":"diff","perspective":"off"}\n' "$SEED_BRANCH" "$2" "${3:-imp}" "$1" >> "$LEDGER"
}
# seed_disp <disposition> [head] [branch] [finding head] [pr] [signed: yes|no] [mac disposition]: the amend row cr-disposition.sh record writes for codex-imp, signed as it signs
seed_disp() {
    local d="$1" hd="${2:-$SHA}" br="${3:-$SEED_BRANCH}" fh="${4:-$REVHEAD}" pr="${5:-77}" sign="${6:-yes}" md="${7:-$1}" mac=m
    if [ "$sign" = yes ]; then
        mac=$(HOME="$DISP_HOME" bash -c '. "$1"; go_msg_mac himmel-disposition-v1 "$2"' _ "$TP_ANCHOR/scripts/lib/go-gate.sh" "$pr|$hd|$br|codex-imp|$fh|$md|judge:j1|$DISP_ATT") || mac=m
    fi
    printf '{"kind":"amend","ts":"2026-01-01T00:00:03Z","branch":"%s","head":"%s","finding_id":"codex-imp","artifact":"diff","perspective":"off","target_head":"%s","set":{"disposition":"%s"},"source":"judge:j1","attest":["ci-green","no-data-loss","no-weakened-guard"],"pr":%s,"mac":"%s"}\n' "$br" "$hd" "$fh" "$d" "$pr" "$mac" >> "$LEDGER"
}
# seed_judge_go <head>: the audit row review-round.sh judge-go writes for a delta-noop GO
seed_judge_go() {
    printf '{"kind":"judge-go","ts":"2026-01-01T00:00:02Z","branch":"%s","head":"%s","status":"ok","source":"judge:j1/delta-noop-%s"}\n' "$SEED_BRANCH" "$1" "$1" >> "$LEDGER"
}
BODY50='## Ticket coverage\n- ask one: deferred -> HIMMEL-50\n'
BODY201='## Ticket coverage\n- ask one: deferred -> HIMMEL-201\n'
DEADHEAD=deadbeefdeadbeefdeadbeefdeadbeefdeadbeef

reset_stubs
STUB_BODY="$BODY50"
seed_imp_deferral HIMMEL-50 "$REVHEAD"; seed_judge_go "$SHA"; seed_disp follow-up:HIMMEL-50
rc=0; out="$(run)" || rc=$?
check "disposition: a signed follow-up row at the head carries the older deferral: exit 0" "$rc" "0"
contains "disposition: signed follow-up row: check 7 passes" "$out" "[PASS] 7."

reset_stubs
STUB_BODY="$BODY50"
seed_imp_deferral HIMMEL-50 "$REVHEAD"; seed_judge_go "$SHA"
rc=0; out="$(run)" || rc=$?
check "disposition: the judge-go row alone does not carry the deferral: exit 1" "$rc" "1"
contains "disposition: no follow-up row: names the key" "$out" "HIMMEL-50 is deferred in the body but has no deferred_to row"

reset_stubs
STUB_BODY="$BODY50"
seed_imp_deferral HIMMEL-50 "$REVHEAD"; seed_disp follow-up:HIMMEL-50 "$SHA" "$SEED_BRANCH" "$REVHEAD" 77 no
rc=0; out="$(run)" || rc=$?
check "disposition: a follow-up row with no valid mac does not count: exit 1" "$rc" "1"
contains "disposition: unsigned row: names the key" "$out" "HIMMEL-50 is deferred in the body but has no deferred_to row"

reset_stubs
STUB_BODY="$BODY50"
seed_imp_deferral HIMMEL-50 "$REVHEAD"; seed_disp follow-up:HIMMEL-50 "$SHA" "$SEED_BRANCH" "$REVHEAD" 77 yes follow-up:HIMMEL-201
rc=0; out="$(run)" || rc=$?
check "disposition: a mac signed for another disposition does not count: exit 1" "$rc" "1"

reset_stubs
STUB_BODY="$BODY50"
seed_imp_deferral HIMMEL-50 "$REVHEAD"; seed_disp follow-up:HIMMEL-50 "$SHA" "$SEED_BRANCH" "$REVHEAD" 78
rc=0; out="$(run)" || rc=$?
check "disposition: a signed row of another PR does not count: exit 1" "$rc" "1"

reset_stubs
STUB_BODY="$BODY50"
seed_imp_deferral HIMMEL-50 "$REVHEAD"; seed_disp follow-up:HIMMEL-50 "$SHA"; seed_disp fix-here "$SHA" "$SEED_BRANCH" "$REVHEAD" 78
rc=0; out="$(run)" || rc=$?
check "disposition: a later signed row of another PR does not supersede this PR's row: exit 0" "$rc" "0"

reset_stubs
STUB_BODY="$BODY50"
seed_imp_deferral HIMMEL-50 "$REVHEAD"; seed_disp follow-up:HIMMEL-50 "$SHA"; seed_disp fix-here "$DEADHEAD"
rc=0; out="$(run)" || rc=$?
check "disposition: a later signed row at another head does not supersede the row at the PR head: exit 0" "$rc" "0"

reset_stubs
STUB_BODY="$BODY201"
seed_imp_deferral HIMMEL-50 "$REVHEAD"; seed_disp follow-up:HIMMEL-50 "$SHA"; seed_disp follow-up:HIMMEL-201 "${SHA:0:12}" "$SEED_BRANCH" "$REVHEAD" 77 no
rc=0; out="$(run)" || rc=$?
check "disposition: a head-prefix row cannot shadow the signed row with another key: exit 1" "$rc" "1"
contains "disposition: prefix shadow: names the key" "$out" "HIMMEL-201 is deferred in the body but has no deferred_to row"

reset_stubs
STUB_BODY="$BODY50"
seed_imp_deferral HIMMEL-50 "$REVHEAD"; seed_disp follow-up:HIMMEL-50 "$SHA"; seed_disp follow-up:HIMMEL-201 "${SHA:0:12}" "$SEED_BRANCH" "$REVHEAD" 77 no
rc=0; out="$(run)" || rc=$?
check "disposition: a head-prefix row is ignored and the signed exact row stands: exit 0" "$rc" "0"

reset_stubs
STUB_BODY="$BODY50"
seed_imp_deferral HIMMEL-50 "$REVHEAD"; seed_disp follow-up:HIMMEL-50 "$SHA"; seed_disp follow-up:HIMMEL-201 "$SHA" "$SEED_BRANCH" "$REVHEAD" 77 no
rc=0; out="$(run)" || rc=$?
check "disposition: a later unsigned row at the exact head replaces the signed one, as in cr-disposition: exit 1" "$rc" "1"

reset_stubs
STUB_BODY="$BODY50"
seed_imp_deferral HIMMEL-50 "$REVHEAD" sug; seed_disp follow-up:HIMMEL-50 "$SHA"
rc=0; out="$(run)" || rc=$?
check "disposition: a suggestion finding is no disposition subject: exit 1" "$rc" "1"
contains "disposition: suggestion: names the key" "$out" "HIMMEL-50 is deferred in the body but has no deferred_to row"

reset_stubs
STUB_BODY="$BODY50"
seed_imp_deferral HIMMEL-50 "$REVHEAD"; seed_disp follow-up:HIMMEL-50 "$DEADHEAD"
rc=0; out="$(run)" || rc=$?
check "disposition: a signed row at another head does not count: exit 1" "$rc" "1"

reset_stubs
STUB_BODY="$BODY50"
seed_imp_deferral HIMMEL-50 "$REVHEAD"; seed_disp follow-up:HIMMEL-50 "$SHA" other
rc=0; out="$(run)" || rc=$?
check "disposition: a signed row of another branch does not count: exit 1" "$rc" "1"

reset_stubs
STUB_BODY="$BODY50"
seed_imp_deferral HIMMEL-50 "$REVHEAD"; seed_disp follow-up:HIMMEL-50 "$SHA" "$SEED_BRANCH" "$DEADHEAD"
rc=0; out="$(run)" || rc=$?
check "disposition: a signed row naming no finding of the branch does not count: exit 1" "$rc" "1"

reset_stubs
STUB_BODY="$BODY50"
seed_imp_deferral HIMMEL-50 "$REVHEAD"; seed_disp fix-here "$SHA"
rc=0; out="$(run)" || rc=$?
check "disposition: a signed fix-here row is not a deferral: exit 1" "$rc" "1"

reset_stubs
STUB_BODY="$BODY50"
seed_imp_deferral HIMMEL-50 "$REVHEAD"; seed_disp follow-up:HIMMEL-201 "$SHA"
rc=0; out="$(run)" || rc=$?
check "disposition: a signed follow-up to a key the body does not defer to: exit 1" "$rc" "1"
contains "disposition: other key: the ledger key has no coverage line" "$out" "HIMMEL-201 is deferred in the CR ledger"

reset_stubs
STUB_BODY="$BODY50"
seed_imp_deferral HIMMEL-50 "$REVHEAD"; seed_disp fix-here "$SHA"; seed_disp follow-up:HIMMEL-50 "$SHA"; seed_disp fix-here "$SHA"
rc=0; out="$(run)" || rc=$?
check "disposition: only the latest row at the head counts: exit 1" "$rc" "1"

reset_stubs
STUB_BODY="$BODY50"
seed_imp_deferral HIMMEL-50 "$REVHEAD"; seed_disp follow-up:HIMMEL-50 "$SHA"
printf '{"kind":"finding","ts":"2026-01-01T00:00:04Z","branch":"%s","head":"%s","model":"codex","finding_id":"codex-imp","severity":"imp","verdict":"fixed","artifact":"diff","perspective":"off"}\n' "$SEED_BRANCH" "$REVHEAD" >> "$LEDGER"
rc=0; out="$(run)" || rc=$?
check "disposition: a finding recorded again as fixed is no deferral: exit 1" "$rc" "1"
contains "disposition: re-recorded fixed: names the key" "$out" "HIMMEL-50 is deferred in the body but has no deferred_to row"

reset_stubs
STUB_BODY="$BODY50"
seed_imp_deferral HIMMEL-50 "$REVHEAD"; seed_disp follow-up:HIMMEL-50 "$SHA"
printf '{"kind":"amend","ts":"2026-01-01T00:00:04Z","finding_id":"codex-imp","artifact":"diff","perspective":"off","target_head":"%s","set":{"verdict":"fixed"}}\n' "$REVHEAD" >> "$LEDGER"
rc=0; out="$(run)" || rc=$?
check "disposition: a branchless amend that marks the finding fixed ends the deferral: exit 1" "$rc" "1"
RUN_HOME=

reset_stubs
STUB_BODY='## Ticket coverage\n- ask one: deferred -> HIMMEL-50\n'
printf '{"kind":"finding","ts":"t","branch":"%s","head":"%s","model":"codex","finding_id":"codex-9","severity":"sug","verdict":"agreed","artifact":"diff","perspective":"off"}\n{"kind":"amend","ts":"t","branch":"other","target_head":"%s","finding_id":"codex-9","artifact":"diff","perspective":"off","set":{"verdict":"deferred","deferred_to":"HIMMEL-50","fu_class":"polish"}}\n' "$SEED_BRANCH" "$REVHEAD" "$REVHEAD" >> "$LEDGER"
seed_descendant "$REVHEAD"
rc=0; out="$(run)" || rc=$?
check "descendant: an amend of another branch does not defer a finding at the reviewed head: exit 1" "$rc" "1"

# --- carry: a deferral at an earlier reviewed head counts at a later head when a
# clean full round (an ok critic avail row, no finding row) ran there after it ---
# seed_clean [branch] [model]: a critic's ok avail row at the PR head, a full round that found nothing
seed_clean() {
    printf '{"kind":"avail","ts":"2026-01-01T00:00:03Z","branch":"%s","head":"%s","model":"%s","status":"%s","artifact":"diff","perspective":"off"}\n' "${1:-$SEED_BRANCH}" "$SHA" "${2-codex}" "${3:-ok}" >> "$LEDGER"
}

reset_stubs
STUB_BODY='## Ticket coverage\n- ask one: deferred -> HIMMEL-50\n'
seed_deferral HIMMEL-50 "$REVHEAD"; seed_clean
rc=0; out="$(run)" || rc=$?
check "carry: a deferral at an earlier head counts after a clean round at the PR head: exit 0" "$rc" "0"
contains "carry: clean round: check 7 passes" "$out" "[PASS] 7."

reset_stubs
STUB_BODY='## Ticket coverage\n- ask one: done\n'
seed_deferral HIMMEL-50 "$REVHEAD"; seed_clean
rc=0; out="$(run)" || rc=$?
check "carry: a carried deferral absent from the body: exit 1" "$rc" "1"
contains "carry: absent from body: names the key" "$out" "HIMMEL-50 is deferred in the CR ledger"

reset_stubs
STUB_BODY='## Ticket coverage\n- ask one: deferred -> HIMMEL-50\n'
seed_deferral HIMMEL-50 "$REVHEAD"
rc=0; out="$(run)" || rc=$?
check "carry: no round at the PR head, the earlier deferral does not carry: exit 1" "$rc" "1"
contains "carry: no round: names the key" "$out" "HIMMEL-50 is deferred in the body but has no deferred_to row"

reset_stubs
STUB_BODY='## Ticket coverage\n- ask one: deferred -> HIMMEL-50\n'
seed_deferral HIMMEL-50 "$REVHEAD"; seed_clean "" claude
rc=0; out="$(run)" || rc=$?
check "carry: a claude (non-critic) row is not a clean round: exit 1" "$rc" "1"

reset_stubs
STUB_BODY='## Ticket coverage\n- ask one: deferred -> HIMMEL-50\n'
seed_deferral HIMMEL-50 "$REVHEAD"; seed_clean "" codex unavailable
rc=0; out="$(run)" || rc=$?
check "carry: an unavailable critic row is not a clean round: exit 1" "$rc" "1"

reset_stubs
STUB_BODY='## Ticket coverage\n- ask one: deferred -> HIMMEL-50\n'
seed_deferral HIMMEL-50 "$REVHEAD"; seed_clean "" ""
rc=0; out="$(run)" || rc=$?
check "carry: an empty-model row is not a clean round: exit 1" "$rc" "1"

reset_stubs
STUB_BODY='## Ticket coverage\n- ask one: deferred -> HIMMEL-50\n'
seed_deferral HIMMEL-50 "$REVHEAD"; seed_clean "" claude-floor
rc=0; out="$(run)" || rc=$?
check "carry: a claude-floor row is not a clean round: exit 1" "$rc" "1"

reset_stubs
STUB_BODY='## Ticket coverage\n- ask one: deferred -> HIMMEL-50\n'
seed_deferral HIMMEL-50 "$REVHEAD"; seed_clean "" codex-adv
rc=0; out="$(run)" || rc=$?
check "carry: a codex-adv row is not a clean round: exit 1" "$rc" "1"

reset_stubs
STUB_BODY='## Ticket coverage\n- ask one: deferred -> HIMMEL-50\n'
seed_deferral HIMMEL-50 "$REVHEAD"; seed_clean other
rc=0; out="$(run)" || rc=$?
check "carry: a clean round of another branch does not carry: exit 1" "$rc" "1"

reset_stubs
STUB_BODY='## Ticket coverage\n- ask one: deferred -> HIMMEL-50\n'
seed_clean; seed_deferral HIMMEL-50 "$REVHEAD"
rc=0; out="$(run)" || rc=$?
check "carry: a round written before the deferral does not carry it: exit 1" "$rc" "1"

reset_stubs
STUB_BODY='## Ticket coverage\n- ask one: deferred -> HIMMEL-50\n'
SEED_BRANCH=other seed_deferral HIMMEL-50 "$REVHEAD"; seed_clean
rc=0; out="$(run)" || rc=$?
check "carry: a deferral of another branch does not carry: exit 1" "$rc" "1"

reset_stubs
STUB_BODY='## Ticket coverage\n- ask one: deferred -> HIMMEL-50\n'
seed_deferral HIMMEL-50 "$REVHEAD"
printf '{"kind":"finding","ts":"2026-01-01T00:00:04Z","branch":"%s","head":"%s","model":"codex","finding_id":"codex-HIMMEL-50","severity":"sug","verdict":"agreed","artifact":"diff","perspective":"off"}\n' "$SEED_BRANCH" "$SHA" >> "$LEDGER"
seed_clean
rc=0; out="$(run)" || rc=$?
check "carry: a finding re-raised at the PR head blocks the carry: exit 1" "$rc" "1"

reset_stubs
STUB_BODY='## Ticket coverage\n- ask one: deferred -> HIMMEL-50\n'
seed_deferral HIMMEL-50 "$REVHEAD"
printf '{"kind":"finding","ts":"2026-01-01T00:00:04Z","branch":"%s","head":"%s","model":"codex","finding_id":"codex-other","severity":"sug","verdict":"fixed","artifact":"diff","perspective":"off"}\n' "$SEED_BRANCH" "$SHA" >> "$LEDGER"
seed_clean
rc=0; out="$(run)" || rc=$?
check "carry: any finding row at the PR head makes the round not clean: exit 1" "$rc" "1"

reset_stubs
STUB_BODY='## Ticket coverage\n- ask one: deferred -> HIMMEL-50\n'
seed_deferral HIMMEL-50 "$REVHEAD"
printf '{"kind":"amend","ts":"2026-01-01T00:00:04Z","branch":"%s","target_head":"%s","finding_id":"codex-HIMMEL-50","artifact":"diff","perspective":"off","set":{"verdict":"fixed"}}\n' "$SEED_BRANCH" "$REVHEAD" >> "$LEDGER"
seed_clean
rc=0; out="$(run)" || rc=$?
check "carry: a deferral later amended to fixed does not carry: exit 1" "$rc" "1"

reset_stubs
STUB_BODY='## Ticket coverage\n- ask one: deferred -> HIMMEL-50\n'
MIDHEAD=1234567812345678123456781234567812345678
seed_deferral HIMMEL-50 "$REVHEAD"
printf '{"kind":"finding","ts":"2026-01-01T00:00:04Z","branch":"%s","head":"%s","model":"codex","finding_id":"codex-HIMMEL-50","severity":"sug","verdict":"agreed","artifact":"diff","perspective":"off"}\n' "$SEED_BRANCH" "$MIDHEAD" >> "$LEDGER"
seed_clean
rc=0; out="$(run)" || rc=$?
check "carry: a finding re-raised at an intermediate head blocks the earlier deferral: exit 1" "$rc" "1"

reset_stubs
STUB_BODY='## Ticket coverage\n- ask one: deferred -> HIMMEL-50\n'
seed_deferral HIMMEL-50 "$REVHEAD"; seed_deferral HIMMEL-50 "$MIDHEAD"; seed_clean
rc=0; out="$(run)" || rc=$?
check "carry: a deferral recorded again at a later head carries from that row: exit 0" "$rc" "0"
unset SEED_BRANCH

reset_stubs
STUB_BODY='## Ticket coverage\n- ask one: done\n'
printf '{"kind":"finding","ts":"t","branch":"b","head":"%s","model":"codex","finding_id":"codex-9","severity":"sug","verdict":"agreed","artifact":"diff","perspective":"off"}\n{"kind":"amend","ts":"t","branch":"b","target_head":"%s","finding_id":"codex-9","artifact":"diff","perspective":"off","set":{"verdict":"deferred","deferred_to":"HIMMEL-50","fu_class":"polish"}}\n' "$SHA" "$SHA" >> "$LEDGER"
rc=0; out="$(run)" || rc=$?
check "ledger: a deferral made by an amend row is read: exit 1 (absent from body)" "$rc" "1"
contains "ledger: amend deferral: names the key" "$out" "HIMMEL-50 is deferred in the CR ledger"

reset_stubs
STUB_BODY='## Ticket coverage\n- ask one: done\n'
seed_deferral HIMMEL-50
printf '{"kind":"amend","ts":"t","branch":"b","target_head":"%s","finding_id":"codex-HIMMEL-50","artifact":"diff","perspective":"off","set":{"verdict":"fixed"}}\n' "$SHA" >> "$LEDGER"
rc=0; out="$(run)" || rc=$?
check "ledger: a deferral later amended to fixed is not a deferral: exit 0" "$rc" "0"

OLDHEAD=deadbeefdeadbeefdeadbeefdeadbeefdeadbeef

reset_stubs
STUB_BODY='## Ticket coverage\n- ask one: deferred -> HIMMEL-50\n'
printf '{"kind":"finding","ts":"t","branch":"b","head":"%s","model":"codex","finding_id":"codex-9","severity":"sug","verdict":"agreed","artifact":"diff","perspective":"off"}\n{"kind":"amend","ts":"t","branch":"b","target_head":"%s","finding_id":"codex-9","artifact":"diff","perspective":"off","set":{"head":"%s"}}\n{"kind":"amend","ts":"t","branch":"b","target_head":"%s","finding_id":"codex-9","artifact":"diff","perspective":"off","set":{"verdict":"deferred","deferred_to":"HIMMEL-50","fu_class":"polish"}}\n' "$OLDHEAD" "$OLDHEAD" "$SHA" "$OLDHEAD" >> "$LEDGER"
rc=0; out="$(run)" || rc=$?
check "ledger: a deferral on a finding an amend moved to the PR head counts: exit 0" "$rc" "0"
contains "ledger: moved deferral: check 7 passes" "$out" "[PASS] 7."

reset_stubs
STUB_BODY='## Ticket coverage\n- ask one: done\n'
printf '{"kind":"finding","ts":"t","branch":"b","head":"%s","model":"codex","finding_id":"codex-9","severity":"sug","verdict":"agreed","artifact":"diff","perspective":"off"}\n{"kind":"amend","ts":"t","branch":"b","target_head":"%s","finding_id":"codex-9","artifact":"diff","perspective":"off","set":{"head":"%s"}}\n{"kind":"amend","ts":"t","branch":"b","target_head":"%s","finding_id":"codex-9","artifact":"diff","perspective":"off","set":{"verdict":"deferred","deferred_to":"HIMMEL-50","fu_class":"polish"}}\n' "$OLDHEAD" "$OLDHEAD" "$SHA" "$OLDHEAD" >> "$LEDGER"
rc=0; out="$(run)" || rc=$?
check "ledger: a moved deferral absent from the body: exit 1" "$rc" "1"
contains "ledger: moved deferral absent from body: names the key" "$out" "HIMMEL-50 is deferred in the CR ledger"

reset_stubs
STUB_BODY='## Ticket coverage\n- ask one: deferred -> HIMMEL-50\n'
seed_deferral HIMMEL-50
printf '{"kind":"amend","ts":"t","branch":"b","target_head":"%s","finding_id":"codex-HIMMEL-50","artifact":"diff","perspective":"off","set":{"verdict":"fixed"}}\n' "$SHA" >> "$LEDGER"
seed_deferral HIMMEL-50
rc=0; out="$(run)" || rc=$?
check "ledger: an amend does not reach a finding row written after it: exit 0" "$rc" "0"

reset_stubs
STUB_BODY='## Ticket coverage\n- ask one: done\n'
seed_deferral HIMMEL-50 "$OLDHEAD"
printf '{"kind":"amend","ts":"t","branch":"b","target_head":"%s","finding_id":"codex-HIMMEL-50","artifact":"diff","perspective":"off","set":{"head":"%s"}}\n' "$OLDHEAD" "$SHA" >> "$LEDGER"
printf '{"kind":"finding","ts":"t","branch":"b","head":"%s","model":"codex","finding_id":"codex-HIMMEL-50","severity":"sug","verdict":"fixed","artifact":"diff","perspective":"off"}\n' "$OLDHEAD" >> "$LEDGER"
rc=0; out="$(run)" || rc=$?
check "ledger: a replacement row at the original head supersedes the moved finding: exit 0" "$rc" "0"

reset_stubs
STUB_BODY='## Ticket coverage\n- ask one: done\n'
seed_deferral HIMMEL-50
printf '{"kind":"amend","ts":"t","branch":"b","target_head":"%s","finding_id":"codex-HIMMEL-50","artifact":"diff","perspective":"off","set":{"head":"%s"}}\n' "$SHA" "$OLDHEAD" >> "$LEDGER"
rc=0; out="$(run)" || rc=$?
check "ledger: a deferral an amend moved off the PR head is not a deferral there: exit 0" "$rc" "0"

reset_stubs
STUB_BODY='## Ticket coverage\n- ask one: done\n'
printf 'not json\n' >> "$LEDGER"
rc=0; out="$(run)" || rc=$?
check "ledger: a malformed ledger line is skipped by item 4 but fails item 18 as the merge does: exit 1" "$rc" "1"
contains "ledger: a malformed ledger line: item 4 still passes" "$out" "[PASS] 4."
contains "ledger: a malformed ledger line: item 18 fails" "$out" "[FAIL] 18."

reset_stubs
STUB_BODY='## Ticket coverage\n- ask one: done\n'
seed_deferral HIMMEL-50
rc=0; out="$(run7)" || rc=$?
check "only 7: a ledger deferral absent from the body fails: exit 1" "$rc" "1"
contains "only 7: ledger deferral: names the key" "$out" "HIMMEL-50 is deferred in the CR ledger"

reset_stubs
STUB_BODY='## Ticket coverage\n- ask one: deferred -> HIMMEL-50\n'
seed_deferral HIMMEL-50
rc=0; out="$(run7)" || rc=$?
check "only 7: matching sets pass: exit 0" "$rc" "0"

reset_stubs
STUB_BODY='## Ticket coverage\n- ask one: deferred -> HIMMEL-100\n'
seed_deferral HIMMEL-100
printf 'HIMMEL-100\tHIMMEL-1\n' > "$tmp/links.db"; STUB_LINKS_DB="$tmp/links.db"
rc=0; out="$(run)" || rc=$?
check "self: a deferral to the PR's own ticket is refused though its links name it: exit 1" "$rc" "1"
contains "self: names the own ticket" "$out" "HIMMEL-100 is the PR's own ticket"

reset_stubs
STUB_BODY='## Ticket coverage\n- ask one: deferred -> HIMMEL-0100\n'
seed_deferral HIMMEL-0100
rc=0; out="$(run)" || rc=$?
check "self: a zero-padded spelling of the own ticket is refused though it carries the residual label: exit 1" "$rc" "1"
contains "self: padded spelling is read as Jira's canonical key" "$out" "HIMMEL-100 is the PR's own ticket"

reset_stubs
STUB_BODY='## Ticket coverage\n- ask one: deferred -> HIMMEL-050\n'
seed_deferral HIMMEL-50
rc=0; out="$(run)" || rc=$?
check "canonical key: a zero-padded spelling of a good target matches its ledger row: exit 0" "$rc" "0"

reset_stubs
STUB_BODY='## Ticket coverage\n- ask one: deferred -> HIMMEL-201\n'
seed_deferral HIMMEL-201
STUB_PR_BRANCH='feat/himmel-201-thing'
rc=0; out="$(run)" || rc=$?
check "self: a residual-labelled own ticket is no deferral target either: exit 1" "$rc" "1"
contains "self: residual-labelled own ticket: names it" "$out" "HIMMEL-201 is the PR's own ticket"

reset_stubs
STUB_BODY='## Ticket coverage\n- ask one: done\n- ask two: deferred -> HIMMEL-200\n'
seed_deferral HIMMEL-200
STUB_LINKS_FAIL=1
rc=0; out="$(run)" || rc=$?
check "links: a failed links lookup fails: exit 1" "$rc" "1"
contains "links: failed lookup: reads UNKNOWN" "$out" "HIMMEL""-200 UNKNOWN (jira links failed for HIMMEL""-100)"
notcontains "links: failed lookup: is not blamed on a raw create" "$out" "raw jira create"

reset_stubs
STUB_BODY='## Ticket coverage\n- ask one: done\n'
chmod 000 "$LEDGER"
if [ -r "$LEDGER" ]; then
    echo "SKIP ledger: an unreadable ledger fails (still readable here, e.g. root)"
else
    rc=0; out="$(run)" || rc=$?
    check "ledger: an unreadable ledger fails check 7: exit 1" "$rc" "1"
    contains "ledger: unreadable: names the cause" "$out" "the CR ledger could not be read"
fi
chmod 600 "$LEDGER"

# --- chain: a deferral carries along a chain of trivial-descendant rows, each naming the reviewed head before it ---
# chain_head <n>: a distinct 40-hex head
chain_head() { printf '%040x' "$1"; }
# seed_hop <head> <reviewed head>: the avail row of a tip cleared as a trivial descendant of <reviewed head>
seed_hop() {
    printf '{"kind":"avail","ts":"2026-01-01T00:00:02Z","branch":"%s","head":"%s","model":"claude","status":"ok","detail":"trivial-descendant of reviewed head %s (HIMMEL'-'5856)"}\n' "$SEED_BRANCH" "$1" "$2" >> "$LEDGER"
}
# seed_clean_at <head>: a critic's ok avail row at <head>, a full round that found nothing
seed_clean_at() {
    printf '{"kind":"avail","ts":"2026-01-01T00:00:03Z","branch":"%s","head":"%s","model":"codex","status":"ok","artifact":"diff","perspective":"off"}\n' "$SEED_BRANCH" "$1" >> "$LEDGER"
}
CH_B=$(chain_head 11); CH_C=$(chain_head 12)
SEED_BRANCH=feat/himmel-100-thing

reset_stubs
STUB_BODY='## Ticket coverage\n- ask one: deferred -> HIMMEL-50\n'
seed_deferral HIMMEL-50 "$REVHEAD"; seed_clean_at "$CH_B"; seed_hop "$CH_C" "$CH_B"; seed_hop "$SHA" "$CH_C"
rc=0; out="$(run)" || rc=$?
check "chain: a deferral carries through two trivial descendants of a cleanly reviewed head: exit 0" "$rc" "0"
contains "chain: two hops: check 7 passes" "$out" "[PASS] 7."

reset_stubs
STUB_BODY='## Ticket coverage\n- ask one: deferred -> HIMMEL-50\n'
seed_deferral HIMMEL-50 "$REVHEAD"; seed_clean_at "$CH_B"; seed_hop "$CH_C" "$CH_B"; seed_hop "$SHA" "$CH_C"
printf '{"kind":"finding","ts":"2026-01-01T00:00:04Z","branch":"%s","head":"%s","model":"codex","finding_id":"codex-HIMMEL-50","severity":"sug","verdict":"agreed","artifact":"diff","perspective":"off"}\n' "$SEED_BRANCH" "$CH_C" >> "$LEDGER"
rc=0; out="$(run)" || rc=$?
check "chain: a finding re-raised at a middle head of the chain stops the carry: exit 1" "$rc" "1"

reset_stubs
STUB_BODY='## Ticket coverage\n- ask one: deferred -> HIMMEL-50\n'
seed_deferral HIMMEL-50 "$REVHEAD"; seed_hop "$CH_B" "$REVHEAD"; seed_hop "$CH_C" "$CH_B"; seed_hop "$SHA" "$CH_C"
printf '{"kind":"finding","ts":"2026-01-01T00:00:04Z","branch":"%s","head":"%s","model":"codex","finding_id":"codex-HIMMEL-50","severity":"sug","verdict":"agreed","artifact":"diff","perspective":"off"}\n' "$SEED_BRANCH" "$CH_B" >> "$LEDGER"
rc=0; out="$(run)" || rc=$?
check "chain: a deferral inside the chain that a later head re-raised does not count: exit 1" "$rc" "1"

reset_stubs
STUB_BODY='## Ticket coverage\n- ask one: deferred -> HIMMEL-50\n'
seed_deferral HIMMEL-50 "$REVHEAD"; seed_hop "$CH_B" "$REVHEAD"; seed_hop "$CH_C" "$CH_B"; seed_hop "$SHA" "$CH_C"
rc=0; out="$(run)" || rc=$?
check "chain: a deferral at the far end of the chain counts: exit 0" "$rc" "0"

reset_stubs
STUB_BODY='## Ticket coverage\n- ask one: deferred -> HIMMEL-50\n'
seed_deferral HIMMEL-50 "$REVHEAD"; seed_hop "$CH_B" "$REVHEAD"; seed_hop "$CH_C" "$CH_B"; seed_hop "$SHA" "$CH_C"
seed_deferral HIMMEL-50 "$(chain_head 77)"
rc=0; out="$(run)" || rc=$?
check "chain: the same finding recorded again at a head outside the chain does not cancel the chain's deferral: exit 0" "$rc" "0"

reset_stubs
STUB_BODY='## Ticket coverage\n- ask one: deferred -> HIMMEL-50\n'
seed_deferral HIMMEL-50 "$REVHEAD"; seed_hop "$CH_C" "$CH_B"; seed_hop "$SHA" "$CH_C"
rc=0; out="$(run)" || rc=$?
check "chain: no clean round at any head of the chain, the deferral does not carry: exit 1" "$rc" "1"

reset_stubs
STUB_BODY='## Ticket coverage\n- ask one: deferred -> HIMMEL-50\n'
seed_deferral HIMMEL-50 "$REVHEAD"; seed_clean_at "$CH_B"; seed_hop "$CH_C" "$CH_B"; seed_hop "$CH_B" "$SHA"; seed_hop "$SHA" "$CH_C"
rc=0; out="$(run)" || rc=$?
check "chain: a cycle among the descendant rows ends and the carry still holds: exit 0" "$rc" "0"

# --- terminal: a chain-head finding that is already handled (fixed, deferred or disproved) no longer makes the chain "raised" ---
# seed_judge <verdict> [deferred_to]: the judge's finding at the reviewed head $CH_B of the chain
seed_judge() {
    printf '{"kind":"finding","ts":"2026-01-01T00:00:01Z","branch":"%s","head":"%s","model":"judge","finding_id":"IF-j4130-2-G1","severity":"imp","verdict":"%s","deferred_to":"%s","fu_class":"polish","reason":"judged","artifact":"diff","perspective":"off"}\n' "$SEED_BRANCH" "$CH_B" "$1" "${2:-}" >> "$LEDGER"
}
# seed_judge_amend <verdict> [deferred_to]: a later amend of that finding
seed_judge_amend() {
    printf '{"kind":"amend","ts":"2026-01-01T00:00:02Z","branch":"%s","target_head":"%s","finding_id":"IF-j4130-2-G1","artifact":"diff","perspective":"off","set":{"verdict":"%s","deferred_to":"%s"}}\n' "$SEED_BRANCH" "$CH_B" "$1" "${2:-}" >> "$LEDGER"
}
# the shape under test: an earlier-head deferral, a judge finding at the reviewed head, a trivial descendant of it, a clean codex round at the PR head after both
pr4130_shape() {
    reset_stubs
    STUB_BODY='## Ticket coverage\n- ask one: deferred -> HIMMEL-50\n'
    seed_deferral HIMMEL-50 "$REVHEAD"
}

pr4130_shape
seed_judge deferred HIMMEL-201; seed_hop "$SHA" "$CH_B"; seed_clean_at "$SHA"
STUB_BODY='## Ticket coverage\n- ask one: deferred -> HIMMEL-50\n- ask two: deferred -> HIMMEL-201\n'
rc=0; out="$(run)" || rc=$?
check "terminal: a deferred judge finding at the reviewed head does not block the earlier deferral's carry: exit 0" "$rc" "0"
contains "terminal: deferred judge finding: check 7 passes" "$out" "[PASS] 7."

pr4130_shape
seed_judge disproved; seed_hop "$SHA" "$CH_B"; seed_clean_at "$SHA"
rc=0; out="$(run)" || rc=$?
check "terminal: a disproved judge finding at the reviewed head does not block the carry: exit 0" "$rc" "0"

pr4130_shape
seed_judge agreed; seed_judge_amend deferred HIMMEL-201; seed_hop "$SHA" "$CH_B"; seed_clean_at "$SHA"
STUB_BODY='## Ticket coverage\n- ask one: deferred -> HIMMEL-50\n- ask two: deferred -> HIMMEL-201\n'
rc=0; out="$(run)" || rc=$?
check "terminal: a judge finding deferred by a later amend does not block the carry: exit 0" "$rc" "0"

pr4130_shape
seed_judge agreed; seed_hop "$SHA" "$CH_B"; seed_clean_at "$SHA"
rc=0; out="$(run)" || rc=$?
check "terminal: an open judge finding at the reviewed head still blocks the carry: exit 1" "$rc" "1"
contains "terminal: open judge finding: names the key" "$out" "HIMMEL-50 is deferred in the body but has no deferred_to row"

pr4130_shape
seed_judge agreed; seed_judge_amend agreed; seed_hop "$SHA" "$CH_B"; seed_clean_at "$SHA"
rc=0; out="$(run)" || rc=$?
check "terminal: an amend that leaves the judge finding open still blocks the carry: exit 1" "$rc" "1"

pr4130_shape
seed_judge deferred HIMMEL-201; seed_judge_amend agreed; seed_hop "$SHA" "$CH_B"; seed_clean_at "$SHA"
rc=0; out="$(run)" || rc=$?
check "terminal: a deferred judge finding later amended back to open blocks the carry: exit 1" "$rc" "1"

pr4130_shape
seed_judge deferred HIMMEL-201; seed_hop "$SHA" "$CH_B"; seed_clean_at "$SHA"
printf '{"kind":"finding","ts":"2026-01-01T00:00:04Z","branch":"%s","head":"%s","model":"codex","finding_id":"codex-open","severity":"sug","verdict":"agreed","artifact":"diff","perspective":"off"}\n' "$SEED_BRANCH" "$CH_B" >> "$LEDGER"
rc=0; out="$(run)" || rc=$?
check "terminal: a terminal judge finding beside an open one at the chain still blocks the carry: exit 1" "$rc" "1"

# a fixed finding carries only when a clean round was written after its last row or amend
pr4130_shape
seed_judge agreed; seed_judge_amend fixed; seed_hop "$SHA" "$CH_B"; seed_clean_at "$SHA"
rc=0; out="$(run)" || rc=$?
check "terminal: a judge finding fixed by an amend, then a clean round at the PR head, carries: exit 0" "$rc" "0"
contains "terminal: fixed then clean: check 7 passes" "$out" "[PASS] 7."

pr4130_shape
seed_judge agreed; seed_clean_at "$SHA"; seed_judge_amend fixed; seed_hop "$SHA" "$CH_B"
rc=0; out="$(run)" || rc=$?
check "terminal: a clean round written before the fixing amend does not carry: exit 1" "$rc" "1"

pr4130_shape
seed_clean_at "$SHA"; seed_judge fixed; seed_hop "$SHA" "$CH_B"
rc=0; out="$(run)" || rc=$?
check "terminal: a clean round written before the fixed finding row does not carry: exit 1" "$rc" "1"

pr4130_shape
seed_judge fixed; seed_hop "$SHA" "$CH_B"
rc=0; out="$(run)" || rc=$?
check "terminal: a fixed judge finding with no clean round after it does not carry: exit 1" "$rc" "1"

pr4130_shape
printf '{"kind":"finding","ts":"2026-01-01T00:00:01Z","branch":"%s","head":"%s","model":"judge","finding_id":"IF-j4130-2-G1","severity":"imp","verdict":"deferred","deferred_to":"HIMMEL-201","fu_class":"polish","reason":"judged","artifact":"diff","perspective":"off"}\n' "$SEED_BRANCH" "$SHA" >> "$LEDGER"
seed_hop "$SHA" "$CH_B"; seed_clean_at "$SHA"
rc=0; out="$(run)" || rc=$?
check "terminal: a handled finding AT the PR head still blocks the carry: exit 1" "$rc" "1"

# a finding row recorded again for the same identity is judged by its later row alone
pr4130_shape
seed_judge agreed; seed_judge fixed; seed_hop "$SHA" "$CH_B"; seed_clean_at "$SHA"
rc=0; out="$(run)" || rc=$?
# The head is a real commit here (item 19 needs one), so item 18, the merge's own finding gate, reads the
# earlier agreed row at $CH_B as still open and exits 1; this row pins the ticket-coverage carry (item 7).
contains "terminal: an open finding row replaced by a later fixed row of the same identity carries: check 7 passes" "$out" "[PASS] 7. ticket coverage"

pr4130_shape
seed_judge fixed; seed_judge agreed; seed_hop "$SHA" "$CH_B"; seed_clean_at "$SHA"
rc=0; out="$(run)" || rc=$?
check "terminal: a fixed finding row replaced by a later open row of the same identity blocks: exit 1" "$rc" "1"

# the clean round must have reviewed the handled code: its head is the finding's head or a descendant of it
# seed_judge_at <head> <verdict>: the judge's finding at <head>
seed_judge_at() {
    printf '{"kind":"finding","ts":"2026-01-01T00:00:01Z","branch":"%s","head":"%s","model":"judge","finding_id":"IF-j4130-2-G1","severity":"imp","verdict":"%s","reason":"judged","artifact":"diff","perspective":"off"}\n' "$SEED_BRANCH" "$1" "$2" >> "$LEDGER"
}

pr4130_shape
seed_judge_at "$CH_C" fixed; seed_hop "$CH_C" "$CH_B"; seed_hop "$SHA" "$CH_C"; seed_clean_at "$CH_B"
rc=0; out="$(run)" || rc=$?
check "terminal: a clean round at an ANCESTOR of the fixed finding's head does not carry: exit 1" "$rc" "1"

pr4130_shape
seed_judge_at "$CH_C" fixed; seed_hop "$CH_C" "$CH_B"; seed_hop "$SHA" "$CH_C"; seed_clean_at "$CH_C"
rc=0; out="$(run)" || rc=$?
check "terminal: a clean round at the fixed finding's own head carries: exit 0" "$rc" "0"

pr4130_shape
seed_judge_at "$CH_C" fixed; seed_hop "$CH_C" "$CH_B"; seed_hop "$SHA" "$CH_C"; seed_clean_at "$SHA"
rc=0; out="$(run)" || rc=$?
check "terminal: a clean round at a descendant of the fixed finding's head carries: exit 0" "$rc" "0"

# a chain of N hops: the clean round sits N hops before the PR head
chain_of() {
    local n="$1" i prev
    reset_stubs
    STUB_BODY='## Ticket coverage\n- ask one: deferred -> HIMMEL-50\n'
    seed_deferral HIMMEL-50 "$REVHEAD"; seed_clean_at "$(chain_head 100)"
    prev=$(chain_head 100)
    for ((i = 1; i < n; i++)); do seed_hop "$(chain_head $((100 + i)))" "$prev"; prev=$(chain_head $((100 + i))); done
    seed_hop "$SHA" "$prev"
}
chain_of 10
rc=0; out="$(run)" || rc=$?
check "chain: ten hops from the PR head still carry: exit 0" "$rc" "0"
chain_of 11
rc=0; out="$(run)" || rc=$?
check "chain: eleven hops from the PR head are past the cap: exit 1" "$rc" "1"


echo "---"
if [ "$fails" -eq 0 ]; then
    echo "ALL PASS"
    exit 0
else
    echo "$fails FAILED"
    exit 1
fi
