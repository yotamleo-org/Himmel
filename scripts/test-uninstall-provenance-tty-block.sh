#!/usr/bin/env bash
# shellcheck disable=SC2015,SC2034 # lib is read by the sourced fixture's helpers
# test-uninstall-provenance-tty-block.sh -- the RED61-RED79b cases (TTY sidecars, the working-principles block, the reconcile report).
# One of four files (test-uninstall-provenance.sh, -qmd, -legacy, -tty-block) split from one 525 s
# suite so no CI shard is bounded by it. The shared fixture is
# scripts/lib/tests/testlib-uninstall-provenance.sh; each piece ends with its own real-ledger tripwire.
# jq-only. Usage: bash scripts/test-uninstall-provenance-tty-block.sh
set -u
here="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
lib="$repo_root/scripts/lib"

# shellcheck source=lib/tests/testlib-uninstall-provenance.sh
# shellcheck disable=SC1091
. "$here/lib/tests/testlib-uninstall-provenance.sh"

echo "==== RED61 (HIMMEL-3787 S2b, spec 5.5): a TTY [r]estore on a user-modified file saves the live bytes to a sidecar FIRST ===="
new_case red61
DEST61="$CASE_DIR/cwd/scripts/red61.sh"
seed_modified_unit "$DEST61"
SIDE61="$DEST61.himmel-uninstall-backup"
# "y" answers the Proceed? confirm, "r" the per-unit [k]eep/[r]estore offer.
out61=$(RUN_TTY_ANSWER=$'y\nr' run_uninstall --skip-tasks --skip-plugins --skip-hooks)
check "RED61: uninstall completed" "$(printf '%s\n' "$out61" | tr -d '\r' | grep -c '^Uninstall complete\.$')" "1"
check "RED61: the sidecar holds the operator's live bytes" \
  "$(cat "$SIDE61" 2>/dev/null)" "$(printf '#!/bin/sh\necho operator-edited-after-install')"
check "RED61: the file was restored to the pre-himmel original" \
  "$(cat "$DEST61")" "$(printf '#!/bin/sh\necho original-user-script')"
check "RED61: the report names the sidecar path" \
  "$([ "$(printf '%s\n' "$out61" | grep -c -F -- "$SIDE61")" -ge 1 ] && echo yes || echo no)" "yes"

echo "==== RED61b (HIMMEL-3787 S2b): --yes never restores, even on a TTY, and writes no sidecar ===="
new_case red61b
DEST61B="$CASE_DIR/cwd/scripts/red61b.sh"
seed_modified_unit "$DEST61B"
out61b=$(RUN_TTY_ANSWER=r run_uninstall --yes --skip-tasks --skip-plugins --skip-hooks)
check "RED61b: uninstall completed" "$(printf '%s\n' "$out61b" | tr -d '\r' | grep -c '^Uninstall complete\.$')" "1"
check "RED61b: --yes leaves the operator's edit in place" \
  "$(cat "$DEST61B")" "$(printf '#!/bin/sh\necho operator-edited-after-install')"
check "RED61b: --yes writes no sidecar" \
  "$([ -e "$DEST61B.himmel-uninstall-backup" ] && echo yes || echo no)" "no"

echo "==== RED61c (HIMMEL-3787 S2b): a sidecar that cannot be written fails closed -- no restore, failed, backup kept ===="
new_case red61c
DEST61C="$CASE_DIR/cwd/scripts/red61c.sh"
seed_modified_unit "$DEST61C"
# an earlier save already sits at the sidecar path: never clobbered, so the
# save is refused and the restore must not run.
printf 'earlier-save\n' > "$DEST61C.himmel-uninstall-backup"
out61c=$(RUN_TTY_ANSWER=$'y\nr' run_uninstall --skip-tasks --skip-plugins --skip-hooks)
check "RED61c: uninstall reported INCOMPLETE, not complete" "$(printf '%s\n' "$out61c" | tr -d '\r' | grep -c '^Uninstall INCOMPLETE')" "1"
check "RED61c: the live file is NOT restored" \
  "$(cat "$DEST61C")" "$(printf '#!/bin/sh\necho operator-edited-after-install')"
check "RED61c: the earlier save is untouched" \
  "$(cat "$DEST61C.himmel-uninstall-backup")" "earlier-save"
check "RED61c: the backup is kept" "$([ -f "$BACKUP_SM" ] && echo yes || echo no)" "yes"
check "RED61c: a failed outcome row is written" \
  "$(jq -r 'select(.op=="failed") | .op' "$(prov_dir)/provenance.jsonl" 2>/dev/null | head -n1)" "failed"


echo "==== RED64 (HIMMEL-3787 S2b, ruling 2026-09-29): a TTY [d]elete on a user-modified created file saves the live bytes to a sidecar FIRST ===="
new_case red64
DEST64="$CASE_DIR/cwd/scripts/red64.sh"
seed_created_unit "$DEST64"
SIDE64="$DEST64.himmel-uninstall-backup"
out64=$(RUN_TTY_ANSWER=$'y\nd' run_uninstall --skip-tasks --skip-plugins --skip-hooks)
check "RED64: uninstall completed" "$(printf '%s\n' "$out64" | tr -d '\r' | grep -c '^Uninstall complete\.$')" "1"
check "RED64: the sidecar holds the operator's live bytes" \
  "$(cat "$SIDE64" 2>/dev/null)" "$(printf '#!/bin/sh\necho operator-edited-created-file')"
check "RED64: the file was deleted" "$([ -e "$DEST64" ] && echo present || echo gone)" "gone"
check "RED64: the report names the sidecar path" \
  "$([ "$(printf '%s\n' "$out64" | grep -c -F -- "$SIDE64")" -ge 1 ] && echo yes || echo no)" "yes"

echo "==== RED64b (HIMMEL-3787 S2b): Enter keeps the file; --yes (tty or not) never deletes; no sidecar in either ===="
new_case red64b
DEST64B="$CASE_DIR/cwd/scripts/red64b.sh"
seed_created_unit "$DEST64B"
out64b=$(RUN_TTY_ANSWER=$'y\n' run_uninstall --skip-tasks --skip-plugins --skip-hooks)
check "RED64b (Enter): uninstall completed" "$(printf '%s\n' "$out64b" | tr -d '\r' | grep -c '^Uninstall complete\.$')" "1"
check "RED64b: the default (Enter) keeps the operator's edit" \
  "$(cat "$DEST64B")" "$(printf '#!/bin/sh\necho operator-edited-created-file')"
out64b2=$(RUN_TTY_ANSWER=d run_uninstall --yes --skip-tasks --skip-plugins --skip-hooks)
check "RED64b (--yes tty): uninstall completed" "$(printf '%s\n' "$out64b2" | tr -d '\r' | grep -c '^Uninstall complete\.$')" "1"
check "RED64b: --yes on a tty never deletes" \
  "$(cat "$DEST64B")" "$(printf '#!/bin/sh\necho operator-edited-created-file')"
run_uninstall --yes --skip-tasks --skip-plugins --skip-hooks >/dev/null
check "RED64b: a non-tty --yes run never deletes" \
  "$(cat "$DEST64B")" "$(printf '#!/bin/sh\necho operator-edited-created-file')"
check "RED64b: no sidecar written by any keep path" \
  "$([ -e "$DEST64B.himmel-uninstall-backup" ] && echo yes || echo no)" "no"

echo "==== RED64c (HIMMEL-3787 S2b): a [d]elete whose sidecar cannot be written fails closed -- file kept, failed row, non-zero ===="
new_case red64c
DEST64C="$CASE_DIR/cwd/scripts/red64c.sh"
seed_created_unit "$DEST64C"
printf 'earlier-save\n' > "$DEST64C.himmel-uninstall-backup"
out64c=$(RUN_TTY_ANSWER=$'y\nd' run_uninstall --skip-tasks --skip-plugins --skip-hooks)
rc64c=$?
check "RED64c: uninstall reported INCOMPLETE, not complete" "$(printf '%s\n' "$out64c" | tr -d '\r' | grep -c '^Uninstall INCOMPLETE')" "1"
check "RED64c: the live file is NOT deleted" \
  "$(cat "$DEST64C")" "$(printf '#!/bin/sh\necho operator-edited-created-file')"
check "RED64c: the earlier save is untouched" \
  "$(cat "$DEST64C.himmel-uninstall-backup")" "earlier-save"
check "RED64c: a failed outcome row is written" \
  "$(jq -r 'select(.op=="failed") | .op' "$(prov_dir)/provenance.jsonl" 2>/dev/null | head -n1)" "failed"
check "RED64c: the run exits non-zero" "$([ "$rc64c" -ne 0 ] && echo nonzero || echo zero)" "nonzero"

echo "==== RED62 (HIMMEL-3787 S2b, J1408A F1): a failed backups-dir mv must not move the ledger into retained-* ===="
new_case red62
DEST62="$CASE_DIR/cwd/scripts/red62.sh"
seed_modified_unit "$DEST62"
chmod 0555 "$(prov_dir)/provenance-backups"
run_uninstall --yes --purge-state --keep-backups --skip-tasks --skip-plugins --skip-hooks >/dev/null
chmod 0755 "$(prov_dir)/provenance-backups"
check "RED62: the ledger stays live when the backups could not be retained" \
  "$([ -f "$(prov_dir)/provenance.jsonl" ] && echo live || echo moved)" "live"
check "RED62: the backups stay where the ledger points" \
  "$([ -f "$BACKUP_SM" ] && echo yes || echo no)" "yes"

install_retained_mkdir_counter() {
  local log="$1" real_mkdir
  real_mkdir=$(command -v mkdir)
  # shellcheck disable=SC2016 # style-only: the stub's $@ and $a must stay literal
  printf '#!/bin/sh\nfor a in "$@"; do case "$a" in */retained-*) echo x >> "%s" ;; esac; done\nexec "%s" "$@"\n' \
    "$log" "$real_mkdir" > "$SUITE_TMP/bin/mkdir"
  chmod +x "$SUITE_TMP/bin/mkdir"
}
remove_retained_mkdir_counter() { rm -f "$SUITE_TMP/bin/mkdir"; }

echo "==== RED63 (HIMMEL-3787 S2b, J1408A F2): an unwritable base dir fails fast, not after ~53 s of EACCES retries ===="
new_case red63
DEST63="$CASE_DIR/cwd/scripts/red63.sh"
seed_modified_unit "$DEST63"
chmod 0555 "$(prov_dir)"
MKDIR63_LOG="$CASE_DIR/mkdir63.log"
install_retained_mkdir_counter "$MKDIR63_LOG"
_t63=$SECONDS
out63=$(run_uninstall --yes --purge-state --keep-backups --skip-tasks --skip-plugins --skip-hooks)
_d63=$((SECONDS - _t63))
remove_retained_mkdir_counter
chmod 0755 "$(prov_dir)"
_n63=$(wc -l < "$MKDIR63_LOG" 2>/dev/null | tr -d ' ')
check "RED63: gives up at once (at most 2 retained-* mkdir attempts)" \
  "$([ "${_n63:-0}" -ge 1 ] && [ "${_n63:-0}" -le 2 ] && echo bounded || echo "attempts:${_n63:-none}")" "bounded"
check "RED63: finishes inside the 60 s backstop" "$([ "$_d63" -lt 60 ] && echo fast || echo slow:$_d63)" "fast"
check "RED63: the real mkdir error is surfaced" \
  "$([ "$(printf '%s\n' "$out63" | grep -c -i 'permission denied')" -ge 1 ] && echo yes || echo no)" "yes"

echo "==== RED65 (HIMMEL-3787 S2c, spec 5.3): a v2 install's .ours snapshots are accounted for -- --purge-state is not refused as an orphan ===="
new_case red65
mkdir -p "$CASE_DIR/cwd/scripts"
DEST65="$CASE_DIR/cwd/scripts/red65.sh"
printf '#!/bin/sh\necho himmel-installed-script\n' > "$DEST65"
# A create (pre absent) holds NO .pre.backup -- its only file under
# provenance-backups/ is the .ours snapshot, so the orphan scan can only
# account for it by knowing the row's top-level .snap.
( prov_begin --writer adopt.sh -- seed-red65 >/dev/null
  prov_record create file "$DEST65" --scope project --class code --row adopter-scripts \
    --writer adopt.sh --pre-absent --post-file "$DEST65" >/dev/null
  prov_end ok >/dev/null )
SNAPS65=$(find "$(prov_dir)/provenance-backups" -type f -name '*.ours' | wc -l | tr -d ' ')
check "RED65 setup: the writer left exactly one .ours snapshot" "$SNAPS65" "1"
out65=$(run_uninstall --yes --purge-state --skip-tasks --skip-plugins --skip-hooks 2>&1); rc65=$?
check "RED65: --purge-state on a v2 install exits 0" "$rc65" "0"
check "RED65: no orphan-backup refusal for the .ours snapshot" \
  "$(printf '%s\n' "$out65" | grep -c 'orphan backup')" "0"
check "RED65: the snapshot is purged with the state (no orphan left behind)" \
  "$(find "$(prov_dir)/provenance-backups" -type f 2>/dev/null | wc -l | tr -d ' ')" "0"

# ---- S2d: the himmel-marked working-principles block ---------------

echo "==== RED66 (HIMMEL-3787 S2d, spec 2): wire_user_claude_md records a block row -- sha of the BEGIN..END text, a snapshot, file_created ===="
new_case red66
# shellcheck disable=SC2031  # HOME is new_case's top-level export, not a subshell
T66="$HOME/.claude/CLAUDE.md"
seed_block "$T66"
ROW66=$(jq -c 'select(.kind=="block")' "$HIMMEL_PROVENANCE_DIR/provenance.jsonl" 2>/dev/null)
check "RED66: exactly one block row for the created file" "$(printf '%s\n' "$ROW66" | grep -c .)" "1"
check "RED66: insert, class code, row user-claude-md, file_created true" \
  "$(printf '%s' "$ROW66" | jq -r '[.op,.class,.manifest_row,(.file_created|tostring)] | join(" ")' 2>/dev/null)" \
  "insert code user-claude-md true"
check "RED66: the marker id is recorded" "$(printf '%s' "$ROW66" | jq -r '.marker // ""')" "HIMMEL:working-principles"
check "RED66: post.sha is the sha of the BEGIN..END text" \
  "$(printf '%s' "$ROW66" | jq -r '.post.sha // ""')" "$(prov_sha_text "$(block_text)")"
SNAP66=$(printf '%s' "$ROW66" | jq -r '.snap // ""')
check "RED66: the .ours snapshot holds exactly the block text" \
  "$([ -n "$SNAP66" ] && [ -f "$SNAP66" ] && [ "$(cat "$SNAP66")" = "$(block_text)" ] && echo same || echo differs)" "same"
new_case red66b
# shellcheck disable=SC2031  # HOME is new_case's top-level export, not a subshell
T66B="$HOME/.claude/CLAUDE.md"
seed_block "$T66B" $'# mine\nbe kind\n'
check "RED66b: appended to a user file -> file_created false" \
  "$(jq -r 'select(.kind=="block") | (.file_created|tostring)' "$HIMMEL_PROVENANCE_DIR/provenance.jsonl" 2>/dev/null)" "false"
new_case red66c
# shellcheck disable=SC2031  # HOME is new_case's top-level export, not a subshell
T66C="$HOME/.codex/AGENTS.md"
seed_block "$T66C"
check "RED66c: the Codex target records under row user-agents-md" \
  "$(jq -r 'select(.kind=="block") | .manifest_row' "$HIMMEL_PROVENANCE_DIR/provenance.jsonl" 2>/dev/null)" "user-agents-md"

echo "==== RED67 (HIMMEL-3787 S2d): a clean block is removed and recorded -- the file install created goes with it, in BOTH rule files ===="
new_case red67
# shellcheck disable=SC2031  # HOME is new_case's top-level export, not a subshell
T67C="$HOME/.claude/CLAUDE.md"
# shellcheck disable=SC2031  # HOME is new_case's top-level export, not a subshell
T67A="$HOME/.codex/AGENTS.md"
seed_block "$T67C"; seed_block "$T67A"
run_uninstall_fx "${BLK_UNINSTALL_ARGS[@]}" >/dev/null 2>&1; rc67=$?
check "RED67: exits 0" "$rc67" "0"
check "RED67: CLAUDE.md install created is gone" "$([ -e "$T67C" ] && echo present || echo gone)" "gone"
check "RED67: AGENTS.md install created is gone" "$([ -e "$T67A" ] && echo present || echo gone)" "gone"
check "RED67: an outcome row per block, both removed:ours" "$(block_outcomes)" "removed:ours removed:ours"

echo "==== RED67b (HIMMEL-3787 S2d): a block appended to the user's file is stripped, the user's bytes come back exactly ===="
new_case red67b
# shellcheck disable=SC2031  # HOME is new_case's top-level export, not a subshell
T67B="$HOME/.claude/CLAUDE.md"
seed_block "$T67B" $'# mine\nbe kind\n'
run_uninstall_fx "${BLK_UNINSTALL_ARGS[@]}" >/dev/null 2>&1; rc67b=$?
check "RED67b: exits 0" "$rc67b" "0"
check "RED67b: the user's own bytes are back exactly" "$(cat "$T67B"; printf x)" "$(printf '# mine\nbe kind\nx')"
check "RED67b: outcome removed:ours" "$(block_outcomes)" "removed:ours"

echo "==== RED68 (HIMMEL-3787 S2d): a user edit OUTSIDE the block survives -- only himmel's block goes ===="
new_case red68
# shellcheck disable=SC2031  # HOME is new_case's top-level export, not a subshell
T68="$HOME/.claude/CLAUDE.md"
seed_block "$T68" $'# mine\nbe kind\n'
printf 'a line the user added after install\n' >> "$T68"
sed -i.bak '1s/.*/# mine (edited)/' "$T68"; rm -f "$T68.bak"
run_uninstall_fx "${BLK_UNINSTALL_ARGS[@]}" >/dev/null 2>&1; rc68=$?
check "RED68: exits 0" "$rc68" "0"
check "RED68: both user edits kept, block gone" "$(cat "$T68"; printf x)" \
  "$(printf '# mine (edited)\nbe kind\na line the user added after install\nx')"
check "RED68: outcome removed:ours" "$(block_outcomes)" "removed:ours"

echo "==== RED69 (HIMMEL-3787 S2d): a user edit INSIDE the block keeps the whole file, reported, exit 0 ===="
new_case red69
# shellcheck disable=SC2031  # HOME is new_case's top-level export, not a subshell
T69="$HOME/.claude/CLAUDE.md"
seed_block "$T69" $'# mine\n'
awk -v b="$BLK_BEGIN" '{print} $0==b{print "an edit the user made inside himmel block"}' "$T69" > "$T69.new" && mv "$T69.new" "$T69"
cp "$T69" "$CASE_DIR/red69.before"
out69=$(run_uninstall_fx "${BLK_UNINSTALL_ARGS[@]}" 2>&1); rc69=$?
check "RED69: exits 0 (kept units are reported, not a failure)" "$rc69" "0"
check "RED69: file byte-identical" "$(cmp -s "$T69" "$CASE_DIR/red69.before" && echo same || echo differs)" "same"
check "RED69: outcome kept:user-modified" "$(block_outcomes)" "kept:user-modified"
check "RED69: the run says the block was kept" "$(printf '%s\n' "$out69" | grep -c '^  kept .*CLAUDE.md (user-modified)$')" "1"
check "RED69: no sidecar written for a kept block" "$([ -e "$T69.himmel-uninstall-backup" ] && echo present || echo none)" "none"
check "RED69: no STILL WIRED probe failure" "$(printf '%s\n' "$out69" | grep -c 'STILL WIRED')" "0"

echo "==== RED69b (HIMMEL-3787 S2d): a TTY [d]elete answer never deletes a user-edited block ===="
new_case red69b
# shellcheck disable=SC2031  # HOME is new_case's top-level export, not a subshell
T69B="$HOME/.claude/CLAUDE.md"
seed_block "$T69B" $'# mine\n'
awk -v b="$BLK_BEGIN" '{print} $0==b{print "an edit the user made inside himmel block"}' "$T69B" > "$T69B.new" && mv "$T69B.new" "$T69B"
cp "$T69B" "$CASE_DIR/red69b.before"
# "y" answers the Proceed? confirm (a lone "d" would abort there and never reach
# any unit -- the vacuous shape this row first shipped with), "d" would answer a
# per-unit [k]eep/[d]elete offer if the block were ever offered one.
rc69b=0
out69b=$(RUN_TTY_ANSWER=$'y\nd' run_uninstall_fx --keep-telegram-state --skip-tasks --skip-plugins --skip-hooks 2>&1) || rc69b=$?
[ "$rc69b" -eq 0 ] || printf '%s\n' "$out69b" | tail -n 15 | sed 's/^/    | /'
check "RED69b: the run got past the Proceed? confirm and exited 0" "$rc69b" "0"
check "RED69b: uninstall completed" "$(printf '%s\n' "$out69b" | tr -d '\r' | grep -c '^Uninstall complete\.$')" "1"
check "RED69b: the edited block file is byte-identical after a 'd' answer" \
  "$(cmp -s "$T69B" "$CASE_DIR/red69b.before" && echo same || echo differs)" "same"
check "RED69b: outcome kept:user-modified" "$(block_outcomes)" "kept:user-modified"
check "RED69b: no [d]elete offer was printed for the block" \
  "$(printf '%s\n' "$out69b" | grep -c -F '[d]elete')" "0"

echo "==== RED70 (HIMMEL-3787 S2d): torn markers -- a BEGIN with no END, an END with no BEGIN -- keep the file, reported, exit 0 ===="
new_case red70
# shellcheck disable=SC2031  # HOME is new_case's top-level export, not a subshell
T70="$HOME/.claude/CLAUDE.md"
seed_block "$T70" $'# mine\n'
grep -vxF "$BLK_END" "$T70" > "$T70.new"; mv "$T70.new" "$T70"
cp "$T70" "$CASE_DIR/red70.before"
run_uninstall_fx "${BLK_UNINSTALL_ARGS[@]}" >/dev/null 2>&1; rc70=$?
check "RED70: torn END -- exits 0" "$rc70" "0"
check "RED70: torn END -- file byte-identical" "$(cmp -s "$T70" "$CASE_DIR/red70.before" && echo same || echo differs)" "same"
check "RED70: torn END -- outcome kept:block-malformed" "$(block_outcomes)" "kept:block-malformed"
new_case red70b
# shellcheck disable=SC2031  # HOME is new_case's top-level export, not a subshell
T70B="$HOME/.claude/CLAUDE.md"
seed_block "$T70B" $'# mine\n'
grep -vxF "$BLK_BEGIN" "$T70B" > "$T70B.new"; mv "$T70B.new" "$T70B"
cp "$T70B" "$CASE_DIR/red70b.before"
run_uninstall_fx "${BLK_UNINSTALL_ARGS[@]}" >/dev/null 2>&1; rc70b=$?
check "RED70b: torn BEGIN -- exits 0" "$rc70b" "0"
check "RED70b: torn BEGIN -- file byte-identical" "$(cmp -s "$T70B" "$CASE_DIR/red70b.before" && echo same || echo differs)" "same"
check "RED70b: torn BEGIN -- outcome kept:block-malformed" "$(block_outcomes)" "kept:block-malformed"

echo "==== RED71 (HIMMEL-3787 S2d): a duplicated block is never guessed at -- kept, reported, exit 0 ===="
new_case red71
# shellcheck disable=SC2031  # HOME is new_case's top-level export, not a subshell
T71="$HOME/.claude/CLAUDE.md"
seed_block "$T71" $'# mine\n'
{ printf '\n'; block_text; } >> "$T71"
cp "$T71" "$CASE_DIR/red71.before"
run_uninstall_fx "${BLK_UNINSTALL_ARGS[@]}" >/dev/null 2>&1; rc71=$?
check "RED71: exits 0" "$rc71" "0"
check "RED71: file byte-identical" "$(cmp -s "$T71" "$CASE_DIR/red71.before" && echo same || echo differs)" "same"
check "RED71: outcome kept:block-malformed" "$(block_outcomes)" "kept:block-malformed"

echo "==== RED72 (HIMMEL-3787 S2d): a missing file is kept as already-absent -- nothing created, exit 0 ===="
new_case red72
# shellcheck disable=SC2031  # HOME is new_case's top-level export, not a subshell
T72="$HOME/.claude/CLAUDE.md"
seed_block "$T72"
rm -f "$T72"
run_uninstall_fx "${BLK_UNINSTALL_ARGS[@]}" >/dev/null 2>&1; rc72=$?
check "RED72: exits 0" "$rc72" "0"
check "RED72: the file was not re-created" "$([ -e "$T72" ] && echo present || echo absent)" "absent"
check "RED72: outcome kept:already-absent" "$(block_outcomes)" "kept:already-absent"

echo "==== RED73 (HIMMEL-3787 S2d): --dry-run writes nothing -- the file, its sidecar, and the ledger are all untouched ===="
new_case red73
# shellcheck disable=SC2031  # HOME is new_case's top-level export, not a subshell
T73="$HOME/.claude/CLAUDE.md"
seed_block "$T73" $'# mine\n'
cp "$T73" "$CASE_DIR/red73.before"
LEDGER73_BEFORE=$(prov_sha_file "$HIMMEL_PROVENANCE_DIR/provenance.jsonl")
out73=$(run_uninstall_fx --dry-run "${BLK_UNINSTALL_ARGS[@]}" 2>&1); rc73=$?
check "RED73: exits 0" "$rc73" "0"
check "RED73: file byte-identical" "$(cmp -s "$T73" "$CASE_DIR/red73.before" && echo same || echo differs)" "same"
check "RED73: no sidecar" "$([ -e "$T73.himmel-uninstall-backup" ] && echo present || echo none)" "none"
check "RED73: ledger byte-identical" "$(prov_sha_file "$HIMMEL_PROVENANCE_DIR/provenance.jsonl")" "$LEDGER73_BEFORE"
check "RED73: the dry run names the strip it would do" "$(printf '%s\n' "$out73" | grep -c 'DRY: would remove block')" "1"


echo "==== RED74 (HIMMEL-3787 S2d, Q5): an UNRECORDED block that is byte-identical to the template is still stripped ===="
new_case red74
# shellcheck disable=SC2031  # HOME is new_case's top-level export, not a subshell
T74="$HOME/.claude/CLAUDE.md"
seed_block_unrecorded "$T74" $'# mine\n'
check "RED74: no ledger at all" "$([ -e "$HIMMEL_PROVENANCE_DIR/provenance.jsonl" ] && echo ledger || echo none)" "none"
run_uninstall_fx "${BLK_UNINSTALL_ARGS[@]}" >/dev/null 2>&1; rc74=$?
check "RED74: exits 0" "$rc74" "0"
check "RED74: the user's own bytes are back exactly" "$(cat "$T74"; printf x)" "$(printf '# mine\nx')"

echo "==== RED74b (HIMMEL-3787 S2d, Q5): same when a ledger exists but holds no block row ===="
new_case red74b
# shellcheck disable=SC2031  # HOME is new_case's top-level export, not a subshell
T74B="$HOME/.claude/CLAUDE.md"
seed_block_unrecorded "$T74B" $'# mine\n'
( prov_begin --writer adopt.sh -- seed-empty >/dev/null; prov_end ok >/dev/null )
run_uninstall_fx "${BLK_UNINSTALL_ARGS[@]}" >/dev/null 2>&1; rc74b=$?
check "RED74b: exits 0" "$rc74b" "0"
check "RED74b: the user's own bytes are back exactly" "$(cat "$T74B"; printf x)" "$(printf '# mine\nx')"

echo "==== RED75 (HIMMEL-3787 S2d, Q5): an UNRECORDED block that differs from the template is kept -- it may hold the user's edits ===="
new_case red75
# shellcheck disable=SC2031  # HOME is new_case's top-level export, not a subshell
T75="$HOME/.claude/CLAUDE.md"
seed_block_unrecorded "$T75" $'# mine\n'
awk -v b="$BLK_BEGIN" '{print} $0==b{print "an edit the user made inside himmel block"}' "$T75" > "$T75.new" && mv "$T75.new" "$T75"
cp "$T75" "$CASE_DIR/red75.before"
out75=$(run_uninstall_fx "${BLK_UNINSTALL_ARGS[@]}" 2>&1); rc75=$?
check "RED75: exits 0 (kept and reported)" "$rc75" "0"
check "RED75: file byte-identical" "$(cmp -s "$T75" "$CASE_DIR/red75.before" && echo same || echo differs)" "same"
check "RED75: the run says why" "$(printf '%s\n' "$out75" | grep -c 'kept (block-unrecorded-modified)')" "1"
check "RED75: no sidecar" "$([ -e "$T75.himmel-uninstall-backup" ] && echo present || echo none)" "none"
check "RED75: no STILL WIRED probe failure" "$(printf '%s\n' "$out75" | grep -c 'STILL WIRED')" "0"

echo "==== RED75b (HIMMEL-3787 S2d, Q5): an UNRECORDED block with a torn marker is kept and reported, exit 0 -- not a halt ===="
new_case red75b
# shellcheck disable=SC2031  # HOME is new_case's top-level export, not a subshell
T75B="$HOME/.claude/CLAUDE.md"
seed_block_unrecorded "$T75B" $'# mine\n'
grep -v -x -F "$BLK_END" "$T75B" > "$T75B.new" && mv "$T75B.new" "$T75B"
cp "$T75B" "$CASE_DIR/red75b.before"
out75b=$(run_uninstall_fx "${BLK_UNINSTALL_ARGS[@]}" 2>&1); rc75b=$?
check "RED75b: exits 0 (kept and reported)" "$rc75b" "0"
check "RED75b: file byte-identical" "$(cmp -s "$T75B" "$CASE_DIR/red75b.before" && echo same || echo differs)" "same"
check "RED75b: the run says kept (block-malformed)" "$(printf '%s\n' "$out75b" | grep -c 'kept (block-malformed)')" "1"
check "RED75b: no sidecar" "$([ -e "$T75B.himmel-uninstall-backup" ] && echo present || echo none)" "none"


# ── the reconcile report ────────────────────────────────────

echo "==== RED76 (HIMMEL-3787 S3): a kept unit's report entry carries its backup path and hand commands ===="
new_case red76
seed_kept_file red76
out76=$(run_uninstall --yes --keep-telegram-state --skip-tasks --skip-plugins --skip-hooks --skip-settings); rc76=$?
check "RED76: exits 0 (kept and reported)" "$rc76" "0"
check "RED76: a Reconcile report heading is printed" "$(printf '%s\n' "$out76" | grep -c '^Reconcile report')" "1"
check "RED76: it counts one unit NEEDS YOU" "$(printf '%s\n' "$out76" | grep -c -E '^  NEEDS YOU +1$')" "1"
check "RED76: the entry names the live path and the plain-words reason" \
  "$(printf '%s\n' "$out76" | grep -c -F "$S3_DEST  file  changed since install")" "1"
check "RED76: the entry carries the backup path" "$(printf '%s\n' "$out76" | grep -c -F "what you had before himmel:  $S3_BACKUP")" "1"
check "RED76: the entry carries the compare command" "$(printf '%s\n' "$out76" | grep -c -F "diff -u $S3_BACKUP $S3_DEST")" "1"
check "RED76: the take-back command saves the live file first" \
  "$(printf '%s\n' "$out76" | grep -c -F "cp -p $S3_DEST $S3_DEST.mine")" "1"
check "RED76: the take-back command refuses to overwrite an existing .mine" \
  "$(printf '%s\n' "$out76" | grep -c -F "test ! -e $S3_DEST.mine && cp -p $S3_DEST $S3_DEST.mine")" "1"
check "RED76: the take-back command is printed" "$(printf '%s\n' "$out76" | grep -c -F "cp $S3_BACKUP $S3_DEST")" "1"
check "RED76: no printed command deletes the live file" "$(printf '%s\n' "$out76" | grep -c -E "(rm|unlink|shred)( -[a-z]+)* .*$S3_DEST")" "0"
check "RED76: the held-backups line counts it" "$(printf '%s\n' "$out76" | grep -c -E '^  backups held: 1 ')" "1"
check "RED76: the backup is still on disk" "$([ -f "$S3_BACKUP" ] && echo yes || echo no)" "yes"

echo "==== RED76b (HIMMEL-3787 S3): a DRY run labels the report DRY and still lists the kept unit ===="
new_case red76b
seed_kept_file red76b
LEDGER76B_BEFORE=$(prov_sha_file "$HIMMEL_PROVENANCE_DIR/provenance.jsonl")
out76b=$(run_uninstall --dry-run --yes --keep-telegram-state --skip-tasks --skip-plugins --skip-hooks --skip-settings); rc76b=$?
check "RED76b: exits 0" "$rc76b" "0"
check "RED76b: the heading carries DRY:" "$(printf '%s\n' "$out76b" | grep -c '^DRY: Reconcile report')" "1"
check "RED76b: the dry report carries the backup path" "$(printf '%s\n' "$out76b" | grep -c -F "what you had before himmel:  $S3_BACKUP")" "1"
check "RED76b: ledger byte-identical after --dry-run" "$(prov_sha_file "$HIMMEL_PROVENANCE_DIR/provenance.jsonl")" "$LEDGER76B_BEFORE"

echo "==== RED77 (HIMMEL-3787 S3, S2d Minor b): a DRY run's unrecorded kept block is DRY:-labelled and reaches the report ===="
new_case red77
# shellcheck disable=SC2031  # HOME is new_case's top-level export, not a subshell
T77="$HOME/.claude/CLAUDE.md"
seed_block_unrecorded "$T77" $'# mine\n'
awk -v b="$BLK_BEGIN" '{print} $0==b{print "an edit the user made inside himmel block"}' "$T77" > "$T77.new" && mv "$T77.new" "$T77"
( prov_begin --writer adopt.sh -- seed-empty >/dev/null; prov_end ok >/dev/null )
LEDGER77_BEFORE=$(prov_sha_file "$HIMMEL_PROVENANCE_DIR/provenance.jsonl")
out77=$(run_uninstall_fx --dry-run "${BLK_UNINSTALL_ARGS[@]}" 2>&1); rc77=$?
check "RED77: exits 0" "$rc77" "0"
check "RED77: ledger byte-identical after --dry-run" "$(prov_sha_file "$HIMMEL_PROVENANCE_DIR/provenance.jsonl")" "$LEDGER77_BEFORE"
check "RED77: the kept line carries DRY:" "$(printf '%s\n' "$out77" | grep -c '^DRY: would keep (block-unrecorded-modified)')" "1"
check "RED77: no bare 'kept (block-unrecorded-modified)' line under --dry-run" \
  "$(printf '%s\n' "$out77" | grep -c '^  kept (block-unrecorded-modified)')" "0"
check "RED77: the report sees it as NEEDS YOU" "$(printf '%s\n' "$out77" | grep -c -E '^  NEEDS YOU +1$')" "1"
check "RED77: the entry says what to do by hand" "$(printf '%s\n' "$out77" | grep -c '^      remove it by hand between the BEGIN/END markers')" "1"

echo "==== RED78 (HIMMEL-3787 S3, S2d Minor a): a block-malformed entry carries the scanner's own non-empty reason ===="
new_case red78
# shellcheck disable=SC2031  # HOME is new_case's top-level export, not a subshell
T78="$HOME/.claude/CLAUDE.md"
seed_block_unrecorded "$T78" $'# mine\n'
grep -v -x -F "$BLK_END" "$T78" > "$T78.new" && mv "$T78.new" "$T78"
( prov_begin --writer adopt.sh -- seed-empty >/dev/null; prov_end ok >/dev/null )
out78=$(run_uninstall_fx "${BLK_UNINSTALL_ARGS[@]}" 2>&1); rc78=$?
check "RED78: exits 0" "$rc78" "0"
check "RED78: the scanner's reason is printed, not an empty indent" \
  "$(printf '%s\n' "$out78" | grep -c -E '^    [^ ].*1 BEGIN and 0 END markers')" "1"
check "RED78: the report lists it as NEEDS YOU with the same reason" "$(printf '%s\n' "$out78" | grep -c -E '^      why: .*1 BEGIN and 0 END markers')" "1"

echo "==== RED79 (HIMMEL-3787 S3, Q7): a retained-* directory from an earlier purge is listed with its delete command ===="
new_case red79
seed_kept_file red79
RET79="$(prov_dir)/retained-20260101T000000Z"
mkdir -p "$RET79"
out79=$(run_uninstall --yes --keep-telegram-state --skip-tasks --skip-plugins --skip-hooks --skip-settings); rc79=$?
check "RED79: exits 0" "$rc79" "0"
check "RED79: the retained line names the dir and its delete command" \
  "$(printf '%s\n' "$out79" | grep -c -F "retained from an earlier purge: $RET79  (rm -rf $RET79 when done)")" "1"
check "RED79: the retained dir is not deleted" "$([ -d "$RET79" ] && echo yes || echo no)" "yes"

echo "==== RED79b (HIMMEL-3787 S3): a clean uninstall reports zero NEEDS YOU, no held or retained line ===="
new_case red79b
mkdir -p "$CASE_DIR/cwd/scripts"
DEST79B="$CASE_DIR/cwd/scripts/red79b.sh"
printf '#!/bin/sh\necho himmel-installed-script\n' > "$DEST79B"
( prov_begin --writer adopt.sh -- seed-red79b >/dev/null
  prov_record create file "$DEST79B" --pre-absent --scope project --class code --row adopter-scripts \
    --writer adopt.sh --post-file "$DEST79B" >/dev/null
  prov_end ok >/dev/null )
out79b=$(run_uninstall --yes --keep-telegram-state --skip-tasks --skip-plugins --skip-hooks --skip-settings); rc79b=$?
check "RED79b: exits 0" "$rc79b" "0"
check "RED79b: NEEDS YOU is zero" "$(printf '%s\n' "$out79b" | grep -c -E '^  NEEDS YOU +0$')" "1"
check "RED79b: the created file is counted as reverted (removed 1)" "$(printf '%s\n' "$out79b" | grep -c -E '^  reverted +1 +\(removed 1,')" "1"
check "RED79b: no held-backups line" "$(printf '%s\n' "$out79b" | grep -c '^  backups held')" "0"


uninstall_prov_finish
