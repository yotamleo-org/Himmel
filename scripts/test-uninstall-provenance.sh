#!/usr/bin/env bash
# shellcheck disable=SC2015
# test-uninstall-provenance.sh -- the RED3-RED19 cases (ledger-driven excision basics, settings, trust keys).
# One of four files (test-uninstall-provenance.sh, -qmd, -legacy, -tty-block) split from one 525 s
# suite so no CI shard is bounded by it. The shared fixture is
# scripts/lib/tests/testlib-uninstall-provenance.sh; each piece ends with its own real-ledger tripwire.
# jq-only. Usage: bash scripts/test-uninstall-provenance.sh
set -u
here="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
lib="$repo_root/scripts/lib"

# shellcheck source=lib/tests/testlib-uninstall-provenance.sh
# shellcheck disable=SC1091
. "$here/lib/tests/testlib-uninstall-provenance.sh"

echo "==== RED3: plugin ownership via ledger register rows ===="
new_case red3
( prov_begin --writer install-plugins.sh -- seed-red3 >/dev/null
  prov_record register plugin - --unit himmel-ops@himmel --scope machine --class code \
    --writer install-plugins.sh --row plugins --field 'cli_scope="user"' --field preexisted=false >/dev/null
  prov_record register plugin - --unit context7@claude-plugins-official --scope machine --class code \
    --writer install-plugins.sh --row plugins --field 'cli_scope="user"' --field preexisted=true >/dev/null
  prov_record register marketplace - --unit himmel --scope machine --class code \
    --writer install-plugins.sh --row marketplaces --field 'cli_scope="user"' --field preexisted=false >/dev/null
  prov_record register marketplace - --unit claude-plugins-official --scope machine --class code \
    --writer install-plugins.sh --row marketplaces --field 'cli_scope="user"' --field preexisted=true >/dev/null
  prov_end ok >/dev/null )
printf '[{"id":"himmel-ops@himmel","scope":"user"},{"id":"context7@claude-plugins-official","scope":"user"}]\n' > "$CASE_PLUGINS_JSON"
printf '[{"name":"himmel"},{"name":"claude-plugins-official"}]\n' > "$CASE_MARKETPLACES_JSON"
run_uninstall --yes --keep-telegram-state --skip-tasks --skip-hooks --skip-settings >/dev/null
context7_kept=$(jq -r '[.[] | select(.id=="context7@claude-plugins-official")] | length>0' "$CASE_PLUGINS_JSON")
himmelops_removed=$(jq -r '[.[] | select(.id=="himmel-ops@himmel")] | length==0' "$CASE_PLUGINS_JSON")
check "RED3 uninstall: ledger-preexisted plugin kept, himmel-installed plugin removed" \
  "$context7_kept $himmelops_removed" "true true"

echo "==== RED4: adopter-scripts file restore with backup+mode ===="
new_case red4
mkdir -p "$CASE_DIR/cwd/scripts"
DEST4="$CASE_DIR/cwd/scripts/foo.sh"
printf '#!/bin/sh\necho original-user-script\n' > "$DEST4"
chmod 700 "$DEST4"
ORIG4_BYTES=$(cat "$DEST4")
ORIG4_MODE=$(_prov_mode "$DEST4")
SNAP4=$(mktemp "$SUITE_TMP/SNAP4.XXXXXX") || exit 1
cp -p "$DEST4" "$SNAP4"
# simulate adopt.sh's real overwrite (copy_recorded): new bytes, new mode
printf '#!/bin/sh\necho himmel-installed-script\n' > "$DEST4"
chmod 755 "$DEST4"
( prov_begin --writer adopt.sh -- seed-red4 >/dev/null
  prov_record replace file "$DEST4" --scope project --class code --row adopter-scripts \
    --writer adopt.sh --pre-file "$SNAP4" --backup --post-file "$DEST4" >/dev/null
  prov_end ok >/dev/null )
rm -f "$SNAP4"
run_uninstall --yes --keep-telegram-state --skip-tasks --skip-plugins --skip-hooks --skip-settings >/dev/null
AFTER4_BYTES=$(cat "$DEST4")
AFTER4_MODE=$(_prov_mode "$DEST4")
check "RED4 uninstall: adopter-scripts file restored from ledger backup (bytes+mode)" \
  "$AFTER4_BYTES|$AFTER4_MODE" "$ORIG4_BYTES|$ORIG4_MODE"

echo "==== RED5: user-modified file protected (kept, not restored/removed) ===="
new_case red5
mkdir -p "$CASE_DIR/cwd/scripts"
DEST5="$CASE_DIR/cwd/scripts/bar.sh"
printf '#!/bin/sh\necho original-user-script\n' > "$DEST5"
SNAP5=$(mktemp "$SUITE_TMP/SNAP5.XXXXXX") || exit 1
cp -p "$DEST5" "$SNAP5"
printf '#!/bin/sh\necho himmel-installed-script\n' > "$DEST5"
( prov_begin --writer adopt.sh -- seed-red5 >/dev/null
  prov_record replace file "$DEST5" --scope project --class code --row adopter-scripts \
    --writer adopt.sh --pre-file "$SNAP5" --backup --post-file "$DEST5" >/dev/null
  prov_end ok >/dev/null )
rm -f "$SNAP5"
# the operator edits the file again AFTER install recorded it -- current
# bytes no longer match the ledger's recorded post-sha.
printf '#!/bin/sh\necho operator-edited-after-install\n' > "$DEST5"
USER_MODIFIED5_BYTES=$(cat "$DEST5")
out5=$(run_uninstall --yes --keep-telegram-state --skip-tasks --skip-plugins --skip-hooks --skip-settings)
AFTER5_BYTES=$(cat "$DEST5")
kept_line5=$(printf '%s\n' "$out5" | grep -c -E 'kept.*bar\.sh.*user-modified')
check "RED5 uninstall: user-modified adopter-script kept as-is + reported user-modified" \
  "$AFTER5_BYTES|$kept_line5" "$USER_MODIFIED5_BYTES|1"

echo "==== RED6: missing ledger -- six overwrite-prone rows protected (hud-config's own path), plugins skipped; a legacy pre-HIMMEL-3334 swept-path leftover is kept while the statusLine stays wired ===="
new_case red6
mkdir -p "$HOME/.claude/plugins/claude-hud"
cat > "$CASE_SETTINGS" <<JSON
{
  "statusLine": {"type":"command","command":"bash \"$repo_root/marketplace/plugins/claude-hud/dist/index.js\""},
  "env": {"HANDOVER_DIR": "/opt/red6-handover"}
}
JSON
printf '{"display":{"customLineCommand":"bash \\"/fake/scripts/statusline/hud-custom-lines.sh\\""}}\n' \
  > "$HOME/.claude/claude-hud.json"
# a leftover config at the pre-migration swept path
# (plugins/claude-hud/config.json, inside Claude Code's plugin-manager
# sweep) is ledger-independent -- gated by unwire_hud_config's
# customLineCommand shape check -- but it is KEPT while the statusLine
# is still wired (here the no-ledger branch protects the statusLine), so an
# upgraded-but-not-yet-rewired install keeps its HUD; the row's OWN (new,
# un-swept) path is protected too, asserted separately below.
printf '{"display":{"customLineCommand":"bash \\"/fake/scripts/statusline/hud-custom-lines.sh\\""}}\n' \
  > "$HOME/.claude/plugins/claude-hud/config.json"
printf '[{"id":"himmel-ops@himmel","scope":"user"}]\n' > "$CASE_PLUGINS_JSON"
printf '[{"name":"himmel"}]\n' > "$CASE_MARKETPLACES_JSON"
LEDGER_PATH6=$(prov_ledger_path)
out6=$(run_uninstall --yes --keep-telegram-state --skip-tasks --skip-hooks)
warn6=$(printf '%s\n' "$out6" | grep -c -F "provenance: no ledger at $LEDGER_PATH6; pre-existing units cannot be told from himmel's — the six overwrite-prone rows are kept")
statusline_kept6=$(jq -r 'has("statusLine")' "$CASE_SETTINGS")
handover_kept6=$(jq -r '.env.HANDOVER_DIR // "ABSENT"' "$CASE_SETTINGS")
hud_kept6=$([ -f "$HOME/.claude/claude-hud.json" ] && echo yes || echo no)
hud_legacy_kept6=$([ -f "$HOME/.claude/plugins/claude-hud/config.json" ] && echo yes || echo no)
plugin_kept6=$(jq -r '[.[] | select(.id=="himmel-ops@himmel")] | length>0' "$CASE_PLUGINS_JSON")
check "RED6 uninstall: no ledger -> warning printed + statusLine/HANDOVER_DIR/hud-config(new path)/plugins protected, legacy swept-path leftover kept while statusLine is wired" \
  "$warn6|$statusline_kept6|$handover_kept6|$hud_kept6|$hud_legacy_kept6|$plugin_kept6" "1|true|/opt/red6-handover|yes|yes|true"

echo "==== RED7: foreign ledger (recorded home != current home) -- same warning + statusLine protected ===="
new_case red7
# shellcheck disable=SC2030  # the foreign HOME is deliberately subshell-local
( HOME="$CASE_DIR/foreign-home"
  prov_begin --writer test-uninstall-provenance.sh -- seed-red7 >/dev/null
  prov_end ok >/dev/null )
cat > "$CASE_SETTINGS" <<JSON
{
  "statusLine": {"type":"command","command":"bash \"$repo_root/marketplace/plugins/claude-hud/dist/index.js\""}
}
JSON
LEDGER_PATH7=$(prov_ledger_path)
out7=$(run_uninstall --yes --keep-telegram-state --skip-tasks --skip-plugins --skip-hooks)
warn7=$(printf '%s\n' "$out7" | grep -c -F "provenance: no ledger at $LEDGER_PATH7; pre-existing units cannot be told from himmel's — the six overwrite-prone rows are kept")
statusline_kept7=$(jq -r 'has("statusLine")' "$CASE_SETTINGS")
check "RED7 uninstall: foreign-home ledger -> same no-ledger warning + statusLine protected" \
  "$warn7|$statusline_kept7" "1|true"

echo "==== RED8: --dry-run --purge-state provenance cleanup DRY lines are the LAST two ===="
new_case red8
( prov_begin --writer test-uninstall-provenance.sh -- seed-red8 >/dev/null
  prov_end ok >/dev/null )
BACKUPS_DIR8="$(prov_dir)/provenance-backups"
LEDGER_PATH8="$(prov_ledger_path)"
out8=$(run_uninstall --dry-run --purge-state --skip-tasks --skip-plugins --skip-hooks)
last_dry8=$(printf '%s\n' "$out8" | grep '^DRY:' | tail -n 2)
expected8=$'DRY: rm -rf -- '"$BACKUPS_DIR8"$'\n''DRY: rm -f -- '"$LEDGER_PATH8"
check "RED8 uninstall --dry-run --purge-state: provenance cleanup is the LAST two DRY lines" \
  "$last_dry8" "$expected8"

echo "==== RED9 (codex-1): --dry-run never prunes provenance-backups/ ===="
new_case red9
mkdir -p "$CASE_DIR/cwd/scripts"
DEST9="$CASE_DIR/cwd/scripts/red9.sh"
printf '#!/bin/sh\necho orig9\n' > "$DEST9"
SNAP9=$(mktemp "$SUITE_TMP/SNAP9.XXXXXX") || exit 1; cp -p "$DEST9" "$SNAP9"
printf '#!/bin/sh\necho himmel9\n' > "$DEST9"
( prov_begin --writer adopt.sh -- seed-red9 >/dev/null
  prov_record replace file "$DEST9" --scope project --class code --row adopter-scripts \
    --writer adopt.sh --pre-file "$SNAP9" --backup --post-file "$DEST9" >/dev/null
  prov_end ok >/dev/null )
rm -f "$SNAP9"
BACKUP9=$(find "$(prov_dir)/provenance-backups" -type f | head -n1)
# assert rc=0 BEFORE the survival check. A backup that survives
# an uninstall that crashed early looks identical to one that survives a
# clean dry-run, so the survival check alone is vacuous against a crash.
# (--skip-settings used to be withheld here because it skipped the
# unwire_settings `_LEDGER_PROTECTED=""` reset and the script then aborted
# on an unbound variable; uninstall.sh now initialises it once globally, so
# that is no longer a hazard and the rc check would catch it if it returned.)
run_uninstall --dry-run --yes --keep-telegram-state --skip-tasks --skip-plugins --skip-hooks >/dev/null
rc9=$?
check "RED9 codex-1: dry-run uninstall exits 0" "$rc9" "0"
check "RED9 codex-1: dry-run does not prune the backup file" \
  "$([ -n "$BACKUP9" ] && [ -f "$BACKUP9" ] && echo yes || echo no)" "yes"

echo "==== RED10 (codex-2): adopter-scripts filtered to the current project root ===="
new_case red10
mkdir -p "$CASE_DIR/cwd/scripts" "$CASE_DIR/sibling/scripts"
DEST10A="$CASE_DIR/cwd/scripts/in-project.sh"
DEST10B="$CASE_DIR/sibling/scripts/other-project.sh"
printf '#!/bin/sh\necho a-original\n' > "$DEST10A"
printf '#!/bin/sh\necho b-original\n' > "$DEST10B"
SNAP10A=$(mktemp "$SUITE_TMP/SNAP10A.XXXXXX") || exit 1; cp -p "$DEST10A" "$SNAP10A"
SNAP10B=$(mktemp "$SUITE_TMP/SNAP10B.XXXXXX") || exit 1; cp -p "$DEST10B" "$SNAP10B"
printf '#!/bin/sh\necho a-himmel\n' > "$DEST10A"
printf '#!/bin/sh\necho b-himmel\n' > "$DEST10B"
B10B_INSTALLED=$(cat "$DEST10B")
( prov_begin --writer adopt.sh -- seed-red10 >/dev/null
  prov_record replace file "$DEST10A" --scope project --class code --row adopter-scripts \
    --writer adopt.sh --pre-file "$SNAP10A" --backup --post-file "$DEST10A" >/dev/null
  prov_record replace file "$DEST10B" --scope project --class code --row adopter-scripts \
    --writer adopt.sh --pre-file "$SNAP10B" --backup --post-file "$DEST10B" >/dev/null
  prov_end ok >/dev/null )
rm -f "$SNAP10A" "$SNAP10B"
run_uninstall --yes --keep-telegram-state --skip-tasks --skip-plugins --skip-hooks >/dev/null
AFTER10B=$(cat "$DEST10B")
check "RED10 codex-2: sibling-project adopter-scripts file untouched" "$AFTER10B" "$B10B_INSTALLED"

echo "==== RED11 (codex-8): file_created=false ledger row passes --file-created no ===="
new_case red11
# RED7's HOME override, `( HOME set inside a subshell )`, closed long before this line; HOME here is the
# suite's own scratch HOME, exactly as intended.
# shellcheck disable=SC2031
RULE11="$HOME/.claude/CLAUDE.md"
printf '<!-- BEGIN HIMMEL:working-principles -->\n## Working principles\n- think first\n<!-- END HIMMEL:working-principles -->\n' > "$RULE11"
( prov_begin --writer test-uninstall-provenance.sh -- seed-red11 >/dev/null
  prov_record create block "$RULE11" --scope user --class code \
    --writer test-uninstall-provenance.sh --field file_created=false --pre-absent --post-json '"x"' >/dev/null
  prov_end ok >/dev/null )
run_uninstall --yes --keep-telegram-state --skip-tasks --skip-plugins --skip-hooks >/dev/null
check "RED11 codex-8: file_created=false keeps the rule file (not deleted)" \
  "$([ -f "$RULE11" ] && echo yes || echo no)" "yes"

echo "==== RED12 (codex-9): a failed unit in the adopter-scripts loop halts iteration ===="
new_case red12
mkdir -p "$CASE_DIR/cwd/scripts"
DEST12A="$CASE_DIR/cwd/scripts/aaa-fails.sh"
DEST12B="$CASE_DIR/cwd/scripts/zzz-second.sh"
printf '#!/bin/sh\necho a-original\n' > "$DEST12A"
printf '#!/bin/sh\necho b-original\n' > "$DEST12B"
SNAP12A=$(mktemp "$SUITE_TMP/SNAP12A.XXXXXX") || exit 1; cp -p "$DEST12A" "$SNAP12A"
SNAP12B=$(mktemp "$SUITE_TMP/SNAP12B.XXXXXX") || exit 1; cp -p "$DEST12B" "$SNAP12B"
printf '#!/bin/sh\necho a-himmel\n' > "$DEST12A"
printf '#!/bin/sh\necho b-himmel\n' > "$DEST12B"
B12B_INSTALLED=$(cat "$DEST12B")
( prov_begin --writer adopt.sh -- seed-red12 >/dev/null
  prov_record replace file "$DEST12A" --scope project --class code --row adopter-scripts \
    --writer adopt.sh --pre-file "$SNAP12A" --backup --post-file "$DEST12A" >/dev/null
  prov_record replace file "$DEST12B" --scope project --class code --row adopter-scripts \
    --writer adopt.sh --pre-file "$SNAP12B" --backup --post-file "$DEST12B" >/dev/null
  prov_end ok >/dev/null )
rm -f "$SNAP12A" "$SNAP12B"
# Corrupt (not delete) DEST12A's recorded backup: prov_read_verdict only
# checks the backup is present+readable ("restore ours"), so a MISSING
# backup verdicts "keep no-backup" instead and never reaches
# prov_read_apply at all -- no failure, no halt. A backup whose CONTENT no
# longer matches the unit's recorded eff_pre.sha lets the restore copy
# succeed mechanically but fail prov_read_apply's post-restore sha check
# (provenance-read.sh's file-restore case), which is a real `failed`
# outcome -> fail_step -> HALTED=1.
BK12A=$(grep -rl "a-original" "$(prov_dir)/provenance-backups" 2>/dev/null | head -n1)
[ -n "$BK12A" ] || { echo "FAIL - RED12 setup: backup for DEST12A not found"; fails=$((fails+1)); }
printf '#!/bin/sh\necho corrupted-backup\n' > "$BK12A"
run_uninstall --yes --keep-telegram-state --skip-tasks --skip-plugins --skip-hooks >/dev/null
AFTER12B=$(cat "$DEST12B")
check "RED12 codex-9: second adopter-scripts unit untouched after the first failed" \
  "$AFTER12B" "$B12B_INSTALLED"

echo "==== RED13 (codex-4): ledger loaded but silent on statusLine/HANDOVER_DIR/hud -- kept like no-ledger, not stripped; a legacy swept-path leftover is kept while the statusLine stays wired ===="
new_case red13
# RED7's HOME override, `( HOME set inside a subshell )`, closed long before this line; HOME here is the
# suite's own scratch HOME, exactly as intended.
# shellcheck disable=SC2031
HUD13="$HOME/.claude/claude-hud.json"
mkdir -p "$(dirname "$HUD13")"
# a leftover legacy-path config, same reasoning as RED6 --
# kept while the loaded-but-silent ledger keeps the statusLine wired.
# shellcheck disable=SC2031
HUD13_LEGACY="$HOME/.claude/plugins/claude-hud/config.json"
mkdir -p "$(dirname "$HUD13_LEGACY")"
cat > "$CASE_SETTINGS" <<JSON
{
  "statusLine": {"type":"command","command":"bash \"$repo_root/marketplace/plugins/claude-hud/dist/index.js\""},
  "env": {"HANDOVER_DIR": "/opt/red13-handover"}
}
JSON
printf '{"display":{"customLineCommand":"bash \\"/fake/scripts/statusline/hud-custom-lines.sh\\""}}\n' \
  > "$HUD13"
printf '{"display":{"customLineCommand":"bash \\"/fake/scripts/statusline/hud-custom-lines.sh\\""}}\n' \
  > "$HUD13_LEGACY"
# a REAL, loaded ledger (LEDGER_OK=1) that records only an UNRELATED unit --
# never a json-key unit for /statusLine or /env/HANDOVER_DIR, and never a
# file unit for the hud config path -- so every one of these six-row
# fallbacks must trigger on "ledger loaded but silent", not "no ledger".
( prov_begin --writer install-plugins.sh -- seed-red13 >/dev/null
  prov_record register plugin - --unit unrelated-plugin@some-marketplace --scope machine --class code \
    --writer install-plugins.sh --row plugins --field 'cli_scope="user"' --field preexisted=false >/dev/null
  prov_end ok >/dev/null )
out13=$(run_uninstall --yes --keep-telegram-state --skip-tasks --skip-plugins --skip-hooks)
statusline_kept13=$(jq -r 'has("statusLine")' "$CASE_SETTINGS")
handover_kept13=$(jq -r '.env.HANDOVER_DIR // "ABSENT"' "$CASE_SETTINGS")
hud_kept13=$([ -f "$HUD13" ] && echo yes || echo no)
hud_legacy_kept13=$([ -f "$HUD13_LEGACY" ] && echo yes || echo no)
notinledger13=$(printf '%s\n' "$out13" | grep -c 'kept (not in ledger)')
# S6 slice2: workspace-trust is now ledger-decided too, so a
# loaded-but-silent ledger also keeps it "not in ledger" -- a 4th line,
# alongside statusLine, env.HANDOVER_DIR and the hud config.
check "RED13 codex-4: loaded-but-silent ledger keeps statusLine/HANDOVER_DIR/hud-config(new path) like the no-ledger branch, legacy swept-path leftover kept while statusLine is wired" \
  "$statusline_kept13|$handover_kept13|$hud_kept13|$hud_legacy_kept13|$notinledger13" "true|/opt/red13-handover|yes|yes|4"

echo "==== RED14 (codex-5): a halted per-unit settings loop must not fall through to the legacy helper for a unit it never reached ===="
new_case red14
cat > "$CASE_SETTINGS" <<JSON
{
  "env": {"HANDOVER_DIR": "/opt/red14-handover", "LUNA_VAULT_PATH": "/opt/red14-preexisting-vault"}
}
JSON
# Two json-key units on the same settings path: /env/HANDOVER_DIR sorts
# before /env/LUNA_VAULT_PATH (fold groups are alphabetical by unit), so
# corrupting HANDOVER_DIR's backup forces the per-unit loop to halt on the
# FIRST unit -- LUNA_VAULT_PATH (a "keep user-modified" verdict, since its
# current value is the pre-existing one, not the installed one) is never
# reached and never added to _LEDGER_PROTECTED. Without the codex-5 halt
# check, the unconditional legacy helper loop below would still run and
# unwire-luna-vault.sh strips env.LUNA_VAULT_PATH unconditionally.
( prov_begin --writer adopt.sh -- seed-red14 >/dev/null
  prov_record replace json-key "$CASE_SETTINGS" --unit /env/HANDOVER_DIR --scope user --class code \
    --writer adopt.sh --row env --pre-json '"/opt/red14-pre-handover"' --backup --post-json '"/opt/red14-handover"' >/dev/null
  prov_record replace json-key "$CASE_SETTINGS" --unit /env/LUNA_VAULT_PATH --scope user --class code \
    --writer adopt.sh --row env --pre-json '"/opt/red14-preexisting-vault"' --backup --post-json '"/opt/red14-himmel-vault"' >/dev/null
  prov_end ok >/dev/null )
BACKUP14=$(grep -rl 'red14-pre-handover' "$(prov_dir)/provenance-backups" 2>/dev/null | head -n1)
[ -n "$BACKUP14" ] || { echo "FAIL - RED14 setup: backup for HANDOVER_DIR not found"; fails=$((fails+1)); }
printf '%s' '"tampered"' > "$BACKUP14"
run_uninstall --yes --keep-telegram-state --skip-tasks --skip-plugins --skip-hooks >/dev/null
vault_after14=$(jq -r '.env.LUNA_VAULT_PATH // "ABSENT"' "$CASE_SETTINGS")
check "RED14 codex-5: LUNA_VAULT_PATH unit never reached after the halt is left untouched, not legacy-stripped" \
  "$vault_after14" "/opt/red14-preexisting-vault"

echo "==== RED15 (codex-6, HIMMEL-3787 S2a): --purge-state --keep-backups RETAINS ledger + backups, never orphans them ===="
new_case red15
mkdir -p "$CASE_DIR/cwd/scripts"
DEST15="$CASE_DIR/cwd/scripts/red15.sh"
printf '#!/bin/sh\necho original-user-script\n' > "$DEST15"
SNAP15=$(mktemp "$SUITE_TMP/SNAP15.XXXXXX") || exit 1; cp -p "$DEST15" "$SNAP15"
printf '#!/bin/sh\necho himmel-installed-script\n' > "$DEST15"
( prov_begin --writer adopt.sh -- seed-red15 >/dev/null
  prov_record replace file "$DEST15" --scope project --class code --row adopter-scripts \
    --writer adopt.sh --pre-file "$SNAP15" --backup --post-file "$DEST15" >/dev/null
  prov_end ok >/dev/null )
rm -f "$SNAP15"
# the operator edits the file again after install recorded it -- verdict
# "keep user-modified", so its backup is NOT pruned by the ordinary
# per-unit prune (codex-1) and survives to see whether --purge-state /
# --keep-backups treats it correctly.
printf '#!/bin/sh\necho operator-edited-after-install\n' > "$DEST15"
BACKUP15=$(find "$(prov_dir)/provenance-backups" -type f | head -n1)
[ -n "$BACKUP15" ] || { echo "FAIL - RED15 setup: backup for DEST15 not found"; fails=$((fails+1)); }
LEDGER_PATH15="$(prov_ledger_path)"
# (the former note about --skip-settings and the unbound
# `_LEDGER_PROTECTED` was stale -- uninstall.sh initialises it globally now.)
run_uninstall --yes --purge-state --keep-backups --skip-tasks --skip-plugins --skip-hooks >/dev/null
# S2a: the OLD contract left the ledger deleted
# and provenance-backups/ behind as a permanent orphan at these exact paths.
# The fixed contract retain-MOVES both together into one never-auto-deleted
# retained-<stamp>/ directory -- so the old paths are now BOTH gone, and a
# retained-* dir holding both the ledger and the backup content exists.
ledger_gone15=$([ -f "$LEDGER_PATH15" ] && echo present || echo gone)
backup_gone15=$([ -f "$BACKUP15" ] && echo present || echo gone)
RETAINED15=$(find "$(prov_dir)" -maxdepth 1 -type d -name 'retained-*' | head -n1)
retained_ledger15=$([ -n "$RETAINED15" ] && [ -f "$RETAINED15/provenance.jsonl" ] && echo yes || echo no)
retained_backup15=$([ -n "$RETAINED15" ] && find "$RETAINED15/provenance-backups" -type f 2>/dev/null | grep -q . && echo yes || echo no)
check "RED15 codex-6 (S2a): --purge-state --keep-backups retain-moves ledger+backups, no orphan at the old paths" \
  "$ledger_gone15|$backup_gone15|$retained_ledger15|$retained_backup15" "gone|gone|yes|yes"

echo "==== RED16 (R2-codex8): DRY preview never announces removing a unit the ledger pass already kept ===="
new_case red16
printf '{"env":{"HIMMEL_REPO":"/opt/red16-operator-value"}}\n' > "$CASE_SETTINGS"
# A ledger unit for env.HIMMEL_REPO whose recorded post value differs from
# the settings file's CURRENT value (the operator changed it since install)
# -> prov_read_verdict returns "keep user-modified", so ledger_apply_unit
# masks env.HIMMEL_REPO out of the DRY preview via _mask_repo. Before the
# codex-8 fix, himmel_wiring_lines was always called with a literal 0 for
# mask_repo, so the preview still announced removing it despite the ledger
# pass one line above having just kept it.
( prov_begin --writer install.sh -- seed-red16 >/dev/null
  prov_record replace json-key "$CASE_SETTINGS" --unit /env/HIMMEL_REPO --scope machine --class code \
    --writer install.sh --row env --pre-absent --post-json '"/opt/red16-himmel-value"' >/dev/null
  prov_end ok >/dev/null )
out16=$(run_uninstall --dry-run --yes --skip-tasks --skip-plugins --skip-hooks)
kept_line16=$(printf '%s\n' "$out16" | grep -c 'DRY: would keep /env/HIMMEL_REPO (user-modified)')
removed_line16=$(printf '%s\n' "$out16" | grep -c 'would remove env\.HIMMEL_REPO=')
check "RED16 R2-codex8: masked env.HIMMEL_REPO kept once and never also previewed as removed" \
  "$kept_line16|$removed_line16" "1|0"

echo "==== RED17 (HIMMEL-3389): a himmel-created empty hooks object is dropped; a pre-existing one survives ===="
# The REAL wire records the /hooks container it creates; uninstall then drops the
# empty object only when that governed /hooks unit says himmel created it.
new_case red17
bash "$lib/wire-pretooluse-hooks.sh" "$CASE_SETTINGS" "C:/fake/himmel" >/dev/null
run_uninstall --yes --keep-telegram-state --skip-tasks --skip-plugins --skip-hooks >/dev/null
check "RED17 HIMMEL-3389: a himmel-created hooks object is gone after uninstall" \
  "$(jq -c '.hooks // "ABSENT"' "$CASE_SETTINGS")" '"ABSENT"'
new_case red17c
printf '{"hooks":{}}\n' > "$CASE_SETTINGS"
bash "$lib/wire-pretooluse-hooks.sh" "$CASE_SETTINGS" "C:/fake/himmel" >/dev/null
run_uninstall --yes --keep-telegram-state --skip-tasks --skip-plugins --skip-hooks >/dev/null
check "RED17 control: a pre-existing empty hooks object survives uninstall" \
  "$(jq -c '.hooks // "ABSENT"' "$CASE_SETTINGS")" '{}'
new_case red17n
printf '{"hooks":null}\n' > "$CASE_SETTINGS"
bash "$lib/wire-pretooluse-hooks.sh" "$CASE_SETTINGS" "C:/fake/himmel" >/dev/null
check "RED17 HIMMEL-3490 precondition: the wire populated the hooks container" \
  "$(jq -r '.hooks | type' "$CASE_SETTINGS")" 'object'
run_uninstall --yes --keep-telegram-state --skip-tasks --skip-plugins --skip-hooks >/dev/null
check "RED17 HIMMEL-3490: an explicit hooks null is restored to null after uninstall" \
  "$(jq -c 'if has("hooks") then .hooks else "ABSENT" end' "$CASE_SETTINGS")" 'null'
new_case red17e
printf '{"env":null}\n' > "$CASE_SETTINGS"
bash "$lib/wire-himmel-repo.sh" "$CASE_SETTINGS" "C:/fake/himmel" >/dev/null
check "RED17 HIMMEL-3490 precondition: the wire populated the env container" \
  "$(jq -r '.env.HIMMEL_REPO // "ABSENT"' "$CASE_SETTINGS")" 'C:/fake/himmel'
run_uninstall --yes --keep-telegram-state --skip-tasks --skip-plugins --skip-hooks >/dev/null
check "RED17 HIMMEL-3490: an explicit env null is restored to null after uninstall" \
  "$(jq -c 'if has("env") then .env else "ABSENT" end' "$CASE_SETTINGS")" 'null'
# The null restore verifies the /env backup like the sibling restores.
# env23_ledger <jq-filter> -- rewrite the governed /env row of the case ledger.
env23_ledger() {
  local led="$HIMMEL_PROVENANCE_DIR/provenance.jsonl"
  jq -c "$1" "$led" > "$led.new" && mv "$led.new" "$led"
}
env23_backup() { jq -r 'select(.unit=="/env" and .pre.backup != null) | .pre.backup' "$HIMMEL_PROVENANCE_DIR/provenance.jsonl" | head -n1; }
env23_case() {
  new_case "$1"
  printf '{"env":null}\n' > "$CASE_SETTINGS"
  bash "$lib/wire-himmel-repo.sh" "$CASE_SETTINGS" "C:/fake/himmel" >/dev/null
}
env23_state() { jq -c 'if has("env") then .env else "ABSENT" end' "$CASE_SETTINGS"; }
env23_case red17m
rm -f "$(env23_backup)"
run_uninstall --yes --keep-telegram-state --skip-tasks --skip-plugins --skip-hooks >/dev/null
check "RED17 HIMMEL-6096: a missing /env backup leaves the empty env container untouched" "$(env23_state)" '"ABSENT"'
env23_case red17b
printf '{bad' > "$(env23_backup)"
run_uninstall --yes --keep-telegram-state --skip-tasks --skip-plugins --skip-hooks >/dev/null
check "RED17 HIMMEL-6096: a corrupt /env backup leaves the empty env container untouched" "$(env23_state)" '"ABSENT"'
env23_case red17s
env23_ledger 'if .unit=="/env" and .pre.backup != null then .pre.sha = "0000000000000000000000000000000000000000000000000000000000000000" else . end'
run_uninstall --yes --keep-telegram-state --skip-tasks --skip-plugins --skip-hooks >/dev/null
check "RED17 HIMMEL-6096: a /env backup that fails its recorded sha leaves the empty env container untouched" "$(env23_state)" '"ABSENT"'
env23_case red17l
env23_ledger 'if .unit=="/env" and .pre.backup != null then del(.pre.sha) else . end'
run_uninstall --yes --keep-telegram-state --skip-tasks --skip-plugins --skip-hooks >/dev/null
check "RED17 HIMMEL-6096 control: a legacy /env row with no recorded sha still restores null" "$(env23_state)" 'null'
new_case red17a
printf '{}\n' > "$CASE_SETTINGS"
bash "$lib/wire-himmel-repo.sh" "$CASE_SETTINGS" "C:/fake/himmel" >/dev/null
run_uninstall --yes --keep-telegram-state --skip-tasks --skip-plugins --skip-hooks >/dev/null
check "RED17 control: an absent env stays absent after uninstall" \
  "$(jq -c 'if has("env") then .env else "ABSENT" end' "$CASE_SETTINGS")" '"ABSENT"'
new_case red17o
printf '{"env":{"OPERATOR_KEY":"keep"}}\n' > "$CASE_SETTINGS"
bash "$lib/wire-himmel-repo.sh" "$CASE_SETTINGS" "C:/fake/himmel" >/dev/null
run_uninstall --yes --keep-telegram-state --skip-tasks --skip-plugins --skip-hooks >/dev/null
check "RED17 control: a non-empty pre-existing env object is restored as it was" \
  "$(jq -c '.env' "$CASE_SETTINGS")" '{"OPERATOR_KEY":"keep"}'

echo "==== RED18 (HIMMEL-3398): a protected /statusLineX or /env/HIMMEL_REPOX never masks /statusLine or /env/HIMMEL_REPO ===="
# /statusLineX and /env/HIMMEL_REPOX are kept (noop-preexisted), so they land in
# _LEDGER_PROTECTED. /statusLine is a heuristic unit (noop, not preexisted) and
# env.HIMMEL_REPO has no unit at all, so only today's helpers remove them --
# unless a prefix match on the protected list wrongly masks those helpers.
new_case red18
SL18="bash \"$repo_root/marketplace/plugins/claude-hud/dist/index.js\""
jq -n --arg c "$SL18" '{statusLine: {type: "command", command: $c}, statusLineX: "u",
  env: {HIMMEL_REPO: "C:/fake/himmel", HIMMEL_REPOX: "x"}}' > "$CASE_SETTINGS"
( prov_begin --writer install.sh -- seed-red18 >/dev/null
  prov_record noop json-key "$CASE_SETTINGS" --unit /statusLine --scope user --class code --row user-settings \
    --writer wire-statusline.sh --pre-json "$(jq -c .statusLine "$CASE_SETTINGS")" \
    --post-json "$(jq -c .statusLine "$CASE_SETTINGS")" >/dev/null
  prov_record noop json-key "$CASE_SETTINGS" --unit /statusLineX --scope user --class code --row user-settings \
    --writer install.sh --pre-json '"u"' --post-json '"u"' --field preexisted=true >/dev/null
  prov_record noop json-key "$CASE_SETTINGS" --unit /env/HIMMEL_REPOX --scope user --class code --row user-settings \
    --writer install.sh --pre-json '"x"' --post-json '"x"' --field preexisted=true >/dev/null
  prov_end ok >/dev/null )
out18=$(run_uninstall --yes --keep-telegram-state --skip-tasks --skip-plugins --skip-hooks)
check "RED18 HIMMEL-3398: /statusLine and env.HIMMEL_REPO removed; /statusLineX and env.HIMMEL_REPOX kept" \
  "$(jq -c '[has("statusLine"), (.env | has("HIMMEL_REPO")), .statusLineX, .env.HIMMEL_REPOX]' "$CASE_SETTINGS")" \
  '[false,false,"u","x"]'
check "RED18: both protected units reported kept" \
  "$(printf '%s\n' "$out18" | grep -c -E 'kept /(statusLineX|env/HIMMEL_REPOX) \(noop-preexisted\)')" "2"

echo "==== RED19 (HIMMEL-3332 S6 slice2): workspace-trust json-key ledger excision ===="
# applyWorkspaceTrust (himmelctl bin.js) records a json-key row for
# /projects/<dir>/hasTrustDialogAccepted in ~/.claude.json. Today's
# uninstall.sh has no code path that ever reads ~/.claude.json -- these four
# rows are proven RED against the unfixed tree.
# These fixtures put ~/.claude.json under the case's scratch HOME, which the
# wet-run fence reads as a live operator profile. The HOME is a
# temp dir, so lift the fence the way test-uninstall.sh's u_run_fx does --
# for these four calls only.
new_case red19a
# RED7's HOME override, `( HOME set inside a subshell )`, closed long before this line; HOME here is the
# suite's own scratch HOME, exactly as intended.
# shellcheck disable=SC2031
CFG19A="$HOME/.claude.json"
jq -n '{projects: {"/proj": {hasTrustDialogAccepted: true}}}' > "$CFG19A"
cp "$CFG19A" "$SUITE_TMP/red19a-before.json"
( prov_begin --writer himmelctl-bin.js -- seed-red19a >/dev/null
  prov_record create json-key "$CFG19A" --unit '/projects/~1proj/hasTrustDialogAccepted' --scope user --class code \
    --writer himmelctl-bin.js --row workspace-trust --pre-absent --post-json 'true' --field preexisted=false >/dev/null
  prov_end ok >/dev/null )
run_uninstall_fx --yes --skip-tasks --skip-plugins --skip-hooks >/dev/null; check "RED19a: uninstall exit status" "$?" "0"
check "RED19a: install-created trust key is removed" \
  "$(jq -c '.projects."/proj" | has("hasTrustDialogAccepted")' "$CFG19A")" "false"
check "RED19a: rest of the project object is byte-identical" \
  "$(jq -c '.projects."/proj" | del(.hasTrustDialogAccepted)' "$CFG19A")" \
  "$(jq -c '.projects."/proj" | del(.hasTrustDialogAccepted)' "$SUITE_TMP/red19a-before.json")"

new_case red19b
# shellcheck disable=SC2031
CFG19B="$HOME/.claude.json"
jq -n '{projects: {"/proj": {hasTrustDialogAccepted: true, otherKey: "x"}}}' > "$CFG19B"
cp "$CFG19B" "$SUITE_TMP/red19b-before.json"
( prov_begin --writer himmelctl-bin.js -- seed-red19b >/dev/null
  prov_record noop json-key "$CFG19B" --unit '/projects/~1proj/hasTrustDialogAccepted' --scope user --class code \
    --writer himmelctl-bin.js --row workspace-trust --pre-json 'true' --post-json 'true' --field preexisted=true >/dev/null
  prov_end ok >/dev/null )
run_uninstall_fx --yes --skip-tasks --skip-plugins --skip-hooks >/dev/null; check "RED19b: uninstall exit status" "$?" "0"
check "RED19b: pre-existing trust key survives byte-identical" \
  "$(jq -c . "$CFG19B")" "$(jq -c . "$SUITE_TMP/red19b-before.json")"

new_case red19c
# shellcheck disable=SC2031
CFG19C="$HOME/.claude.json"
# himmel's own row says it wrote "true" at install; the operator has since
# revoked trust (current file has "false") -- verdict must be user-modified.
jq -n '{projects: {"/proj": {hasTrustDialogAccepted: false}}}' > "$CFG19C"
( prov_begin --writer himmelctl-bin.js -- seed-red19c >/dev/null
  prov_record create json-key "$CFG19C" --unit '/projects/~1proj/hasTrustDialogAccepted' --scope user --class code \
    --writer himmelctl-bin.js --row workspace-trust --pre-absent --post-json 'true' --field preexisted=false >/dev/null
  prov_end ok >/dev/null )
run_uninstall_fx --yes --skip-tasks --skip-plugins --skip-hooks >/dev/null; check "RED19c: uninstall exit status" "$?" "0"
check "RED19c: a trust key the user has since revoked is kept (false)" \
  "$(jq -c '.projects."/proj".hasTrustDialogAccepted' "$CFG19C")" "false"

new_case red19d
# shellcheck disable=SC2031
CFG19D="$HOME/.claude.json"
jq -n '{projects: {"/proj": {hasTrustDialogAccepted: true}}}' > "$CFG19D"
cp "$CFG19D" "$SUITE_TMP/red19d-before.json"
# no prov_begin/prov_record/prov_end at all -- a pre-ledger install.
run_uninstall_fx --yes --skip-tasks --skip-plugins --skip-hooks >/dev/null; check "RED19d: uninstall exit status" "$?" "0"
check "RED19d: with no ledger, the trust key is kept exactly as today" \
  "$(jq -c . "$CFG19D")" "$(jq -c . "$SUITE_TMP/red19d-before.json")"

echo "==== sessionend: uninstall removes the session end hook a vault wire added ===="
# sessionend_fresh_luna_clean: a real wire-luna-vault.sh run (vault path, SessionEnd hook and the
# /hooks container it created), read back through the real provenance-read.sh at uninstall.
new_case sefresh
bash "$lib/wire-luna-vault.sh" "$CASE_SETTINGS" "C:/fake/vault" >/dev/null
check "sessionend_fresh_luna_clean precondition: the wire added a SessionEnd entry" \
  "$(jq '[.hooks.SessionEnd[]?.hooks[]?] | length' "$CASE_SETTINGS")" "1"
run_uninstall --yes --keep-telegram-state --skip-tasks --skip-plugins --skip-hooks >/dev/null
check "sessionend_fresh_luna_clean: no SessionEnd key and the himmel-created hooks object is dropped" \
  "$(jq -c '[(.hooks // "ABSENT"), (.env.LUNA_VAULT_PATH // "ABSENT")]' "$CASE_SETTINGS")" '["ABSENT","ABSENT"]'

# sessionend_removed_under_mask: a user-modified trio element protects /hooks/PreToolUse (_mask_hooks=1);
# the session end hook has no ledger unit, so it goes anyway and the modified element stays.
new_case semask
bash "$lib/wire-pretooluse-hooks.sh" "$CASE_SETTINGS" "C:/fake/himmel" >/dev/null
bash "$lib/wire-pretooluse-hooks.sh" --sessionend "$CASE_SETTINGS" "C:/fake/himmel" >/dev/null
jq '.hooks.PreToolUse[0].hooks[0].timeout = 77' "$CASE_SETTINGS" > "$CASE_SETTINGS.new" && mv "$CASE_SETTINGS.new" "$CASE_SETTINGS"
run_uninstall --yes --keep-telegram-state --skip-tasks --skip-plugins --skip-hooks >/dev/null
check "sessionend_removed_under_mask: SessionEnd entry removed, the user-modified PreToolUse element kept" \
  "$(jq -c '[(.hooks.SessionEnd // "ABSENT"), .hooks.PreToolUse[0].hooks[0].timeout]' "$CASE_SETTINGS")" '["ABSENT",77]'

# sessionend_dry_run_previews: --dry-run prints the row and writes nothing.
new_case sedry
bash "$lib/wire-luna-vault.sh" "$CASE_SETTINGS" "C:/fake/vault" >/dev/null
cp "$CASE_SETTINGS" "$SUITE_TMP/sedry-before.json"
out_sedry=$(run_uninstall --dry-run --yes --keep-telegram-state --skip-tasks --skip-plugins --skip-hooks)
check "sessionend_dry_run_previews: the DRY row is printed" \
  "$(printf '%s\n' "$out_sedry" | grep -c "^DRY: remove himmel SessionEnd hook from $CASE_SETTINGS\$")" "1"
check "sessionend_dry_run_previews: the settings file is untouched" \
  "$(jq -cS . "$CASE_SETTINGS")" "$(jq -cS . "$SUITE_TMP/sedry-before.json")"

# sessionend_hooks_null: an explicit `"hooks": null` is restored to null, not left as {}.
new_case senull
printf '{"hooks":null}\n' > "$CASE_SETTINGS"
bash "$lib/wire-luna-vault.sh" "$CASE_SETTINGS" "C:/fake/vault" >/dev/null
run_uninstall --yes --keep-telegram-state --skip-tasks --skip-plugins --skip-hooks >/dev/null
check "sessionend_hooks_null: an explicit hooks null is restored to null after uninstall" \
  "$(jq -c 'if has("hooks") then .hooks else "ABSENT" end' "$CASE_SETTINGS")" 'null'

uninstall_prov_finish
