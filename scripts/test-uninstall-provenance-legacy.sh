#!/usr/bin/env bash
# shellcheck disable=SC2015,SC2034 # lib is read by the sourced fixture's helpers
# test-uninstall-provenance-legacy.sh -- the RED33-RED60 cases (settings containers, legacy-path backups, purge-state refusals).
# One of four files (test-uninstall-provenance.sh, -qmd, -legacy, -tty-block) split from one 525 s
# suite so no CI shard is bounded by it. The shared fixture is
# scripts/lib/uninstall-provenance-fixture.sh; each piece ends with its own real-ledger tripwire.
# jq-only. Usage: bash scripts/test-uninstall-provenance-legacy.sh
set -u
here="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
lib="$repo_root/scripts/lib"

# shellcheck source=lib/uninstall-provenance-fixture.sh
# shellcheck disable=SC1091
. "$here/lib/uninstall-provenance-fixture.sh"

echo "==== RED33 (HIMMEL-3541): settings containers + a scope marketplace entry install created ===="
# install-plugins.sh records a created-when-absent json-key row for the
# enabledPlugins / extraKnownMarketplaces containers and for a scope entry the
# CLI added for a marketplace that already existed (its register row reads
# preexisted, so step 7 keeps the marketplace). Uninstall removes the entry
# and drops each container once empty -- but only one the ledger shows absent.
for sub in created control; do
  new_case "red33-$sub"
  ENTRY33='{"source":{"source":"github","repo":"anthropics/claude-plugins-official"}}'
  # the state after step 4 removed the plugins: same bytes in both sub-cases,
  # only the ledger differs
  printf '{"enabledPlugins":{},"extraKnownMarketplaces":{"claude-plugins-official":%s}}\n' "$ENTRY33" > "$CASE_SETTINGS"
  ( prov_begin --writer install-plugins.sh -- seed-red33 >/dev/null
    prov_record register marketplace - --unit claude-plugins-official --scope machine --class code \
      --writer install-plugins.sh --row marketplaces --field 'cli_scope="user"' --field preexisted=true >/dev/null
    if [ "$sub" = created ]; then
      prov_record create json-key "$CASE_SETTINGS" --unit /extraKnownMarketplaces --pre-absent \
        --post-json "{\"claude-plugins-official\":$ENTRY33}" --scope user --class code --row user-settings --writer install-plugins.sh >/dev/null
      prov_record create json-key "$CASE_SETTINGS" --unit /enabledPlugins --pre-absent \
        --post-json '{"himmel-ops@himmel":true}' --scope user --class code --row user-settings --writer install-plugins.sh >/dev/null
    fi
    prov_record create json-key "$CASE_SETTINGS" --unit /extraKnownMarketplaces/claude-plugins-official --pre-absent \
      --post-json "$ENTRY33" --scope user --class code --row user-settings --writer install-plugins.sh >/dev/null
    prov_end ok >/dev/null )
  printf '[{"name":"claude-plugins-official"}]\n' > "$CASE_MARKETPLACES_JSON"
  run_uninstall --yes --keep-telegram-state --skip-tasks --skip-hooks >/dev/null
  case "$sub" in
    created)
      check "RED33 created: entry removed and both created containers dropped" \
        "$(jq -c . "$CASE_SETTINGS")" '{}' ;;
    control)
      check "RED33 control: entry removed, pre-existing containers kept (empty)" \
        "$(jq -c . "$CASE_SETTINGS")" '{"enabledPlugins":{},"extraKnownMarketplaces":{}}' ;;
  esac
done
unset ENTRY33

echo "==== RED34 (HIMMEL-3334 F1, judge J1269O): a legacy-path replace backup survives a rewire's bare rm -f, restored by uninstall ===="
# Scenario from the verdict: an operator has their own (non-himmel) config at
# the earlier swept path; a pre-PR install REPLACES it there and
# records a ledger `replace` row with a backup of the original bytes -- the
# only place those bytes still exist once wire-statusline.sh's own
# migration later `rm -f`s that path with no provenance of its
# own (scripts/lib/wire-statusline.sh ~406-411) while publishing the new
# un-swept claude-hud.json. Before this fix, uninstall's hud branch only ever
# consulted the ledger for the NEW path ($_p), so the legacy path's own
# `replace` unit was never applied and the operator's bytes stayed lost.
new_case red34
# shellcheck disable=SC2031  # HOME is new_case's top-level export, not a subshell leak
mkdir -p "$HOME/.claude/plugins/claude-hud"
# shellcheck disable=SC2031  # HOME is new_case's top-level export, not a subshell leak
HUD_LEGACY34="$HOME/.claude/plugins/claude-hud/config.json"
# shellcheck disable=SC2031  # HOME is new_case's top-level export, not a subshell leak
HUD_NEW34="$HOME/.claude/claude-hud.json"
printf '{"custom":"operator-pre-himmel-hud-config"}\n' > "$HUD_LEGACY34"
ORIG34_BYTES=$(cat "$HUD_LEGACY34")
SNAP34=$(mktemp "$SUITE_TMP/SNAP34.XXXXXX") || exit 1
cp -p "$HUD_LEGACY34" "$SNAP34"
printf '{"display":{"customLineCommand":"bash \\"%s/scripts/statusline/hud-custom-lines.sh\\""}}\n' "$repo_root" > "$HUD_LEGACY34"
( prov_begin --writer wire-statusline.sh -- seed-red34 >/dev/null
  prov_record replace file "$HUD_LEGACY34" --scope user --class code --row hud-config \
    --writer wire-statusline.sh --pre-file "$SNAP34" --backup --post-file "$HUD_LEGACY34" >/dev/null
  prov_end ok >/dev/null )
rm -f "$SNAP34"
# The rewire's migration: publish the new path, then blow away the legacy one.
printf '{"display":{"customLineCommand":"bash \\"%s/scripts/statusline/hud-custom-lines.sh\\""}}\n' "$repo_root" > "$HUD_NEW34"
rm -f "$HUD_LEGACY34"
run_uninstall --yes --keep-telegram-state --skip-tasks --skip-plugins --skip-hooks >/dev/null
AFTER34_BYTES=$([ -f "$HUD_LEGACY34" ] && cat "$HUD_LEGACY34" || echo "ABSENT")
check "RED34 uninstall: legacy-path replace backup restored after a rewire's bare rm -f" \
  "$AFTER34_BYTES" "$ORIG34_BYTES"

echo "==== RED35 (HIMMEL-3334 C1, judge J1269A): a legacy-path replace backup survives uninstall even when NOT rewired ===="
# Scenario from the verdict (C1): unlike RED34, this box was never re-wired
#  -- the legacy path still holds himmel's own (post-replace)
# bytes when uninstall runs, so the "legacy exists" branch (not the F1
# file-absent branch RED34 covers) is the one that must consult the ledger
# before ever touching the file.
new_case red35
# shellcheck disable=SC2031  # HOME is new_case's top-level export, not a subshell leak
mkdir -p "$HOME/.claude/plugins/claude-hud"
# shellcheck disable=SC2031  # HOME is new_case's top-level export, not a subshell leak
HUD_LEGACY35="$HOME/.claude/plugins/claude-hud/config.json"
printf '{"custom":"operator-pre-himmel-hud-config-35"}\n' > "$HUD_LEGACY35"
ORIG35_BYTES=$(cat "$HUD_LEGACY35")
SNAP35=$(mktemp "$SUITE_TMP/SNAP35.XXXXXX") || exit 1
cp -p "$HUD_LEGACY35" "$SNAP35"
printf '{"display":{"customLineCommand":"bash \\"%s/scripts/statusline/hud-custom-lines.sh\\""}}\n' "$repo_root" > "$HUD_LEGACY35"
( prov_begin --writer wire-statusline.sh -- seed-red35 >/dev/null
  prov_record replace file "$HUD_LEGACY35" --scope user --class code --row hud-config \
    --writer wire-statusline.sh --pre-file "$SNAP35" --backup --post-file "$HUD_LEGACY35" >/dev/null
  prov_end ok >/dev/null )
rm -f "$SNAP35"
# No rewire migration this time: no claude-hud.json at the new path, and the
# legacy file is left in place, exactly as it would be on an un-rewired box.
run_uninstall --yes --keep-telegram-state --skip-tasks --skip-plugins --skip-hooks >/dev/null
AFTER35_BYTES=$([ -f "$HUD_LEGACY35" ] && cat "$HUD_LEGACY35" || echo "ABSENT")
check "RED35 uninstall: legacy-path replace backup restored without a prior rewire" \
  "$AFTER35_BYTES" "$ORIG35_BYTES"

echo "==== RED36 (HIMMEL-3334 I1/JD, judge J1269A): a himmel-shaped legacy file with NO ledger unit is kept, not deleted ===="
# Scenario from the verdict (I1): the ledger is present and has OTHER history
# (so LEDGER_OK=1), but nothing was ever recorded for this legacy path -- no
# ledger evidence himmel owns this file, so it must be left alone even though
# its bytes happen to match himmel's own customLineCommand pattern.
new_case red36
# shellcheck disable=SC2031  # HOME is new_case's top-level export, not a subshell leak
mkdir -p "$HOME/.claude/plugins/claude-hud"
# shellcheck disable=SC2031  # HOME is new_case's top-level export, not a subshell leak
HUD_LEGACY36="$HOME/.claude/plugins/claude-hud/config.json"
printf '{"display":{"customLineCommand":"bash \\"%s/scripts/statusline/hud-custom-lines.sh\\""}}\n' "$repo_root" > "$HUD_LEGACY36"
ORIG36_BYTES=$(cat "$HUD_LEGACY36")
# Unrelated ledger history so LEDGER_OK=1, but no unit for $HUD_LEGACY36 at all.
( prov_begin --writer install-plugins.sh -- seed-red36 >/dev/null
  prov_record register marketplace - --unit claude-plugins-official --scope machine --class code \
    --writer install-plugins.sh --row marketplaces --field 'cli_scope="user"' --field preexisted=true >/dev/null
  prov_end ok >/dev/null )
run_uninstall --yes --keep-telegram-state --skip-tasks --skip-plugins --skip-hooks >/dev/null
AFTER36_BYTES=$([ -f "$HUD_LEGACY36" ] && cat "$HUD_LEGACY36" || echo "ABSENT")
check "RED36 uninstall: himmel-shaped legacy file with no ledger unit is kept" \
  "$AFTER36_BYTES" "$ORIG36_BYTES"

echo "==== RED37 (HIMMEL-3334 N1, judge J1269B): a legacy replace unit the operator edited after install is kept, not restored ===="
# Scenario (JF): like RED35, a pre-PR install REPLACED the operator's own
# config and recorded a ledger `replace` unit with a backup -- but the
# operator then hand-edited the himmel-written file, keeping himmel's
# customLineCommand. Not rewired. Before this fix, the legacy branch called
# prov_read_apply restore directly (no drift check), overwriting the
# operator's post-install edit with the pre-himmel backup.
new_case red37
# shellcheck disable=SC2031  # HOME is new_case's top-level export, not a subshell leak
mkdir -p "$HOME/.claude/plugins/claude-hud"
# shellcheck disable=SC2031  # HOME is new_case's top-level export, not a subshell leak
HUD_LEGACY37="$HOME/.claude/plugins/claude-hud/config.json"
printf '{"custom":"operator-pre-himmel-hud-config-37"}\n' > "$HUD_LEGACY37"
SNAP37=$(mktemp "$SUITE_TMP/SNAP37.XXXXXX") || exit 1
cp -p "$HUD_LEGACY37" "$SNAP37"
printf '{"display":{"customLineCommand":"bash \\"%s/scripts/statusline/hud-custom-lines.sh\\""}}\n' "$repo_root" > "$HUD_LEGACY37"
( prov_begin --writer wire-statusline.sh -- seed-red37 >/dev/null
  prov_record replace file "$HUD_LEGACY37" --scope user --class code --row hud-config \
    --writer wire-statusline.sh --pre-file "$SNAP37" --backup --post-file "$HUD_LEGACY37" >/dev/null
  prov_end ok >/dev/null )
rm -f "$SNAP37"
# The operator's post-install edit, keeping himmel's own command.
printf '{"display":{"customLineCommand":"bash \\"%s/scripts/statusline/hud-custom-lines.sh\\"","operatorKey":"edited-after-install"}}\n' "$repo_root" > "$HUD_LEGACY37"
EDITED37_BYTES=$(cat "$HUD_LEGACY37")
out37dry=$(run_uninstall --dry-run --yes --keep-telegram-state --skip-tasks --skip-plugins --skip-hooks); rc37dry=$?
check "RED37 dry-run: exits 0" "$rc37dry" "0"
check "RED37 dry-run: previews the legacy hud config as kept (user-modified)" \
  "$(printf '%s' "$out37dry" | grep -Fc "would keep $HUD_LEGACY37 (user-modified)")" "1"
AFTER37DRY_BYTES=$(cat "$HUD_LEGACY37")
check "RED37 dry-run: left the operator's edit untouched (preview only)" "$AFTER37DRY_BYTES" "$EDITED37_BYTES"
out37=$(run_uninstall --yes --keep-telegram-state --skip-tasks --skip-plugins --skip-hooks); rc37=$?
check "RED37 wet run: exits 0" "$rc37" "0"
check "RED37 wet run: names the legacy hud config as kept (user-modified)" \
  "$(printf '%s' "$out37" | grep -Fc "kept $HUD_LEGACY37 (user-modified)")" "1"
AFTER37_BYTES=$(cat "$HUD_LEGACY37")
check "RED37 uninstall: legacy-path operator edit survives (not restored over)" \
  "$AFTER37_BYTES" "$EDITED37_BYTES"

echo "==== RED38 (HIMMEL-3334 N2, judge J1269B): a legacy create unit the operator edited after install is kept, not deleted ===="
# Scenario (JG): a pre-PR install CREATED the legacy config (no pre-existing
# file, a `create` unit, no backup). The operator later edited it, keeping
# himmel's command. Not rewired. Before this fix, a unit with no backup fell
# into the pattern-gated rm fallback and deleted the operator's edited file.
new_case red38
# shellcheck disable=SC2031  # HOME is new_case's top-level export, not a subshell leak
mkdir -p "$HOME/.claude/plugins/claude-hud"
# shellcheck disable=SC2031  # HOME is new_case's top-level export, not a subshell leak
HUD_LEGACY38="$HOME/.claude/plugins/claude-hud/config.json"
printf '{"display":{"customLineCommand":"bash \\"%s/scripts/statusline/hud-custom-lines.sh\\""}}\n' "$repo_root" > "$HUD_LEGACY38"
( prov_begin --writer wire-statusline.sh -- seed-red38 >/dev/null
  prov_record create file "$HUD_LEGACY38" --pre-absent --post-file "$HUD_LEGACY38" --scope user --class code \
    --row hud-config --writer wire-statusline.sh --field preexisted=false >/dev/null
  prov_end ok >/dev/null )
printf '{"display":{"customLineCommand":"bash \\"%s/scripts/statusline/hud-custom-lines.sh\\"","operatorKey":"edited-after-install"}}\n' "$repo_root" > "$HUD_LEGACY38"
EDITED38_BYTES=$(cat "$HUD_LEGACY38")
run_uninstall --dry-run --yes --keep-telegram-state --skip-tasks --skip-plugins --skip-hooks >/dev/null; rc38dry=$?
check "RED38 dry-run: exits 0" "$rc38dry" "0"
AFTER38DRY_BYTES=$(cat "$HUD_LEGACY38")
check "RED38 dry-run: left the operator's edit untouched (preview only)" "$AFTER38DRY_BYTES" "$EDITED38_BYTES"
run_uninstall --yes --keep-telegram-state --skip-tasks --skip-plugins --skip-hooks >/dev/null; rc38=$?
check "RED38 wet run: exits 0" "$rc38" "0"
AFTER38_BYTES=$([ -f "$HUD_LEGACY38" ] && cat "$HUD_LEGACY38" || echo "ABSENT")
check "RED38 uninstall: legacy-path operator edit survives (not deleted)" \
  "$AFTER38_BYTES" "$EDITED38_BYTES"

echo "==== RED39 (HIMMEL-3334 N3, judge J1269B): a legacy replace unit whose backup is gone is kept, not a halt ===="
# Scenario (JH): a legacy `replace` unit whose backup file has since been
# pruned or hand-deleted. Not rewired. Before this fix, the legacy branch
# still saw a non-empty backup PATH string, attempted the restore, and
# fail_step halted the whole uninstall with rc=2 when the read failed.
new_case red39
# shellcheck disable=SC2031  # HOME is new_case's top-level export, not a subshell leak
mkdir -p "$HOME/.claude/plugins/claude-hud"
# shellcheck disable=SC2031  # HOME is new_case's top-level export, not a subshell leak
HUD_LEGACY39="$HOME/.claude/plugins/claude-hud/config.json"
printf '{"custom":"operator-pre-himmel-hud-config-39"}\n' > "$HUD_LEGACY39"
SNAP39=$(mktemp "$SUITE_TMP/SNAP39.XXXXXX") || exit 1
cp -p "$HUD_LEGACY39" "$SNAP39"
printf '{"display":{"customLineCommand":"bash \\"%s/scripts/statusline/hud-custom-lines.sh\\""}}\n' "$repo_root" > "$HUD_LEGACY39"
( prov_begin --writer wire-statusline.sh -- seed-red39 >/dev/null
  prov_record replace file "$HUD_LEGACY39" --scope user --class code --row hud-config \
    --writer wire-statusline.sh --pre-file "$SNAP39" --backup --post-file "$HUD_LEGACY39" >/dev/null
  prov_end ok >/dev/null )
rm -f "$SNAP39"
# Prune the backup the ledger row ACTUALLY points at. --backup copies the
# pre-state into its own provenance-backups/<iid>/... file (_prov_backup in
# provenance.sh); deleting $SNAP39 (the staging file passed as --pre-file)
# does not touch that copy, so the real backup path has to be read back out
# of the ledger row itself.
LEDGER39=$(prov_ledger_path)
BACKUP39=$(jq -r --arg p "$HUD_LEGACY39" 'select(.path==$p and .pre.backup != null) | .pre.backup' "$LEDGER39" | tail -n1)
[ -n "$BACKUP39" ] || { echo "RED39 setup: could not find the recorded backup path" >&2; exit 1; }
rm -f "$BACKUP39"
ORIG39_BYTES=$(cat "$HUD_LEGACY39")
run_uninstall --dry-run --yes --keep-telegram-state --skip-tasks --skip-plugins --skip-hooks >/dev/null; rc39dry=$?
check "RED39 dry-run: exits 0 (no-backup is not a halt)" "$rc39dry" "0"
AFTER39DRY_BYTES=$(cat "$HUD_LEGACY39")
check "RED39 dry-run: left the legacy config untouched (preview only)" "$AFTER39DRY_BYTES" "$ORIG39_BYTES"
run_uninstall --yes --keep-telegram-state --skip-tasks --skip-plugins --skip-hooks >/dev/null; rc39=$?
check "RED39 wet run: exits 0 (no-backup is not a halt)" "$rc39" "0"
AFTER39_BYTES=$(cat "$HUD_LEGACY39")
check "RED39 uninstall: legacy-path config with a pruned backup is kept, byte-identical" \
  "$AFTER39_BYTES" "$ORIG39_BYTES"

echo "==== RED40 (HIMMEL-3334 I1, judge J1269C): a migrated-away legacy replace unit whose backup is pruned is kept, not a halt (F1 branch) ===="
# Scenario (JH2, contrived): same setup as RED34 (migrated away, ledger
# replace unit with backup) but the backup itself is gone when uninstall
# runs. Before this fix, the F1 branch (scripts/uninstall.sh ~3237-3251)
# read a non-empty backup PATH string off the ledger row and called
# prov_read_apply restore unconditionally -- prov_read_apply's own missing-
# backup check then failed, WARN + fail_step halted the whole uninstall
# (rc=2). Main has no F1 branch and completes the same input with rc=0.
new_case red40
# shellcheck disable=SC2031  # HOME is new_case's top-level export, not a subshell leak
mkdir -p "$HOME/.claude/plugins/claude-hud"
# shellcheck disable=SC2031  # HOME is new_case's top-level export, not a subshell leak
HUD_LEGACY40="$HOME/.claude/plugins/claude-hud/config.json"
# shellcheck disable=SC2031  # HOME is new_case's top-level export, not a subshell leak
HUD_NEW40="$HOME/.claude/claude-hud.json"
printf '{"custom":"operator-pre-himmel-hud-config-40"}\n' > "$HUD_LEGACY40"
SNAP40=$(mktemp "$SUITE_TMP/SNAP40.XXXXXX") || exit 1
cp -p "$HUD_LEGACY40" "$SNAP40"
printf '{"display":{"customLineCommand":"bash \\"%s/scripts/statusline/hud-custom-lines.sh\\""}}\n' "$repo_root" > "$HUD_LEGACY40"
( prov_begin --writer wire-statusline.sh -- seed-red40 >/dev/null
  prov_record replace file "$HUD_LEGACY40" --scope user --class code --row hud-config \
    --writer wire-statusline.sh --pre-file "$SNAP40" --backup --post-file "$HUD_LEGACY40" >/dev/null
  prov_end ok >/dev/null )
rm -f "$SNAP40"
# The rewire's migration: publish the new path, then blow away the legacy one.
printf '{"display":{"customLineCommand":"bash \\"%s/scripts/statusline/hud-custom-lines.sh\\""}}\n' "$repo_root" > "$HUD_NEW40"
rm -f "$HUD_LEGACY40"
LEDGER40=$(prov_ledger_path)
BACKUP40=$(jq -r --arg p "$HUD_LEGACY40" 'select(.path==$p and .pre.backup != null) | .pre.backup' "$LEDGER40" | tail -n1)
[ -n "$BACKUP40" ] || { echo "RED40 setup: could not find the recorded backup path" >&2; exit 1; }
rm -f "$BACKUP40"
run_uninstall --dry-run --yes --keep-telegram-state --skip-tasks --skip-plugins --skip-hooks >/dev/null; rc40dry=$?
check "RED40 dry-run: exits 0 (no-backup is not a halt)" "$rc40dry" "0"
run_uninstall --yes --keep-telegram-state --skip-tasks --skip-plugins --skip-hooks >/dev/null; rc40=$?
check "RED40 wet run: exits 0 (no-backup is not a halt)" "$rc40" "0"
AFTER40_BYTES=$([ -f "$HUD_LEGACY40" ] && cat "$HUD_LEGACY40" || echo "ABSENT")
check "RED40 uninstall: migrated-away legacy path with a pruned backup stays absent, not resurrected" \
  "$AFTER40_BYTES" "ABSENT"

echo "==== RED41 (HIMMEL-3334 I1, judge J1269C): the natural JH3 path -- restore, prune, sweep, re-uninstall never halts ===="
# Scenario (JH3, natural path from the verdict): (1) a base-era install
# records a replace unit over the operator's own legacy config; (2) a rewire
# migrates the legacy file away; (3) uninstall #1 restores the operator's
# original and its clean-end prune deletes the now-restored unit's backup
# (prov_read_prune_backups, no --keep-backups) -- the fold ignores `restored`
# outcome rows (m1, a follow-up ticket, not this fix), so the unit stays
# live; (4) Claude Code's plugin-dir sweep deletes plugins/claude-hud/,
# taking the just-restored file with it. A reinstall between (4) and the
# second uninstall is a no-op for hud-config here (the legacy path stays
# absent either way) and is omitted. Uninstall #2 must not halt.
new_case red41
# shellcheck disable=SC2031  # HOME is new_case's top-level export, not a subshell leak
mkdir -p "$HOME/.claude/plugins/claude-hud"
# shellcheck disable=SC2031  # HOME is new_case's top-level export, not a subshell leak
HUD_LEGACY41="$HOME/.claude/plugins/claude-hud/config.json"
# shellcheck disable=SC2031  # HOME is new_case's top-level export, not a subshell leak
HUD_NEW41="$HOME/.claude/claude-hud.json"
printf '{"custom":"operator-pre-himmel-hud-config-41"}\n' > "$HUD_LEGACY41"
ORIG41_BYTES=$(cat "$HUD_LEGACY41")
SNAP41=$(mktemp "$SUITE_TMP/SNAP41.XXXXXX") || exit 1
cp -p "$HUD_LEGACY41" "$SNAP41"
printf '{"display":{"customLineCommand":"bash \\"%s/scripts/statusline/hud-custom-lines.sh\\""}}\n' "$repo_root" > "$HUD_LEGACY41"
( prov_begin --writer wire-statusline.sh -- seed-red41 >/dev/null
  prov_record replace file "$HUD_LEGACY41" --scope user --class code --row hud-config \
    --writer wire-statusline.sh --pre-file "$SNAP41" --backup --post-file "$HUD_LEGACY41" >/dev/null
  prov_end ok >/dev/null )
rm -f "$SNAP41"
printf '{"display":{"customLineCommand":"bash \\"%s/scripts/statusline/hud-custom-lines.sh\\""}}\n' "$repo_root" > "$HUD_NEW41"
rm -f "$HUD_LEGACY41"
run_uninstall --yes --keep-telegram-state --skip-tasks --skip-plugins --skip-hooks >/dev/null
AFTER41_FIRST_BYTES=$([ -f "$HUD_LEGACY41" ] && cat "$HUD_LEGACY41" || echo "ABSENT")
check "RED41 setup: uninstall #1 restored the operator's original" "$AFTER41_FIRST_BYTES" "$ORIG41_BYTES"
# The plugin-dir sweep: the just-restored file (and its already-pruned
# backup) are both gone again, while the ledger unit is still live (m1).
# shellcheck disable=SC2031  # HOME is new_case's top-level export, not a subshell leak
rm -rf "$HOME/.claude/plugins/claude-hud"
run_uninstall --dry-run --yes --keep-telegram-state --skip-tasks --skip-plugins --skip-hooks >/dev/null; rc41dry=$?
check "RED41 dry-run #2: exits 0 (no-backup is not a halt)" "$rc41dry" "0"
run_uninstall --yes --keep-telegram-state --skip-tasks --skip-plugins --skip-hooks >/dev/null; rc41=$?
check "RED41 wet uninstall #2: exits 0, no halt on a pruned backup in the F1 branch" "$rc41" "0"
AFTER41_BYTES=$([ -f "$HUD_LEGACY41" ] && cat "$HUD_LEGACY41" || echo "ABSENT")
check "RED41 uninstall #2: legacy path stays absent (no resurrection, no halt)" "$AFTER41_BYTES" "ABSENT"

echo "==== RED42 (HIMMEL-3334 I2, chief ruling on judge J1269C): a no-ledger legacy config the operator edited (not byte-identical to himmel's template) survives ===="
# Scenario (JJ): no ledger at all; a himmel-shaped legacy config (its
# customLineCommand matches himmel's pattern) with an operator-added key
# alongside it. Before this fix, the no-ledger branch's pattern-gated rm
# (unwire_hud_config) only ever checked customLineCommand and deleted the
# file outright, losing the operator's added key.
new_case red42
# shellcheck disable=SC2031  # HOME is new_case's top-level export, not a subshell leak
mkdir -p "$HOME/.claude/plugins/claude-hud"
# shellcheck disable=SC2031  # HOME is new_case's top-level export, not a subshell leak
HUD_LEGACY42="$HOME/.claude/plugins/claude-hud/config.json"
printf '{"display":{"customLineCommand":"bash \\"%s/scripts/statusline/hud-custom-lines.sh\\""},"operatorKey":"edited-e310cc"}\n' \
  "$repo_root" > "$HUD_LEGACY42"
EDITED42_BYTES=$(cat "$HUD_LEGACY42")
run_uninstall --dry-run --yes --keep-telegram-state --skip-tasks --skip-plugins --skip-hooks >/dev/null; rc42dry=$?
check "RED42 dry-run: exits 0" "$rc42dry" "0"
AFTER42DRY_BYTES=$(cat "$HUD_LEGACY42")
check "RED42 dry-run: left the operator's edit untouched (preview only)" "$AFTER42DRY_BYTES" "$EDITED42_BYTES"
run_uninstall --yes --keep-telegram-state --skip-tasks --skip-plugins --skip-hooks >/dev/null; rc42=$?
check "RED42 wet run: exits 0" "$rc42" "0"
AFTER42_BYTES=$([ -f "$HUD_LEGACY42" ] && cat "$HUD_LEGACY42" || echo "ABSENT")
check "RED42 uninstall: no-ledger legacy config edited by the operator (not byte-identical to himmel's template) survives" \
  "$AFTER42_BYTES" "$EDITED42_BYTES"

echo "==== RED43 (HIMMEL-3334 I2, chief ruling on judge J1269C): a no-ledger legacy config byte-identical to himmel's own template is removed ===="
# Scenario (JJ2): the mirror of RED42 -- no ledger at all, but the legacy
# file is exactly himmel's own shipped template (same source RED42 must be
# told apart from). This must still be removed; only an edited/non-template
# file is protected.
new_case red43
# shellcheck disable=SC2031  # HOME is new_case's top-level export, not a subshell leak
mkdir -p "$HOME/.claude/plugins/claude-hud"
# shellcheck disable=SC2031  # HOME is new_case's top-level export, not a subshell leak
HUD_LEGACY43="$HOME/.claude/plugins/claude-hud/config.json"
TEMPLATE43=$(cat "$repo_root/marketplace/plugins/claude-hud/config/himmel-config.json")
TEMPLATE43="${TEMPLATE43//<himmel-path>/$repo_root}"
printf '%s\n' "$TEMPLATE43" > "$HUD_LEGACY43"
PRISTINE43_BYTES=$(cat "$HUD_LEGACY43")
run_uninstall --dry-run --yes --keep-telegram-state --skip-tasks --skip-plugins --skip-hooks >/dev/null; rc43dry=$?
check "RED43 dry-run: exits 0" "$rc43dry" "0"
AFTER43DRY_BYTES=$(cat "$HUD_LEGACY43")
check "RED43 dry-run: left the pristine template untouched (preview only)" "$AFTER43DRY_BYTES" "$PRISTINE43_BYTES"
run_uninstall --yes --keep-telegram-state --skip-tasks --skip-plugins --skip-hooks >/dev/null; rc43=$?
check "RED43 wet run: exits 0" "$rc43" "0"
AFTER43_BYTES=$([ -f "$HUD_LEGACY43" ] && cat "$HUD_LEGACY43" || echo "ABSENT")
check "RED43 uninstall: no-ledger legacy config byte-identical to himmel's own template is removed" \
  "$AFTER43_BYTES" "ABSENT"

echo "==== RED50 (HIMMEL-3637): --purge-state must refuse while a recorded backup's original path has not been restored ===="
# P1 wet-run repro (a): the adopted project lives OUTSIDE this case's
# cwd (run_uninstall always cd's into $CASE_DIR/cwd), so the adopter-scripts
# restore step cannot reach it and the file stays overwritten by himmel's
# copy. --purge-state must then refuse to delete the only backup, not
# silently remove it and exit 0.
new_case red50
PROJDIR50="$CASE_DIR/project"
mkdir -p "$PROJDIR50/scripts"
DEST50="$PROJDIR50/scripts/clean.sh"
printf '#!/bin/sh\necho original-user-script\n' > "$DEST50"
SNAP50=$(mktemp "$SUITE_TMP/SNAP50.XXXXXX") || exit 1
cp -p "$DEST50" "$SNAP50"
printf '#!/bin/sh\necho himmel-installed-script\n' > "$DEST50"
( prov_begin --writer adopt.sh -- seed-red50 >/dev/null
  prov_record replace file "$DEST50" --scope project --class code --row adopter-scripts \
    --writer adopt.sh --pre-file "$SNAP50" --backup --post-file "$DEST50" >/dev/null
  prov_end ok >/dev/null )
rm -f "$SNAP50"
BACKUPS50_BEFORE=$(find "$HIMMEL_PROVENANCE_DIR/provenance-backups" -type f 2>/dev/null | wc -l | tr -d ' ')
check "RED50: setup actually created a backup (control is not vacuous)" "$([ "$BACKUPS50_BEFORE" -gt 0 ] && echo yes || echo no)" "yes"
run_uninstall --yes --skip-tasks --skip-plugins --skip-hooks --skip-settings --purge-state >/dev/null
rc50=$?
BACKUPS50_AFTER=$(find "$HIMMEL_PROVENANCE_DIR/provenance-backups" -type f 2>/dev/null | wc -l | tr -d ' ')
REFUSED50=$([ "$rc50" -ne 0 ] && echo yes || echo no)
check "RED50: --purge-state refuses (non-zero) when the adopted project's backup was never restored" "$REFUSED50" "yes"
check "RED50: refusing means deleting nothing — the backup survives" "$BACKUPS50_AFTER" "$BACKUPS50_BEFORE"

echo "==== RED51 (HIMMEL-3637): an uninstall run from a cwd that is not the recorded project must never exit 0 having restored nothing ===="
new_case red51
PROJDIR51="$CASE_DIR/project"
mkdir -p "$PROJDIR51/scripts"
DEST51="$PROJDIR51/scripts/clean.sh"
printf '#!/bin/sh\necho original-user-script\n' > "$DEST51"
ORIG51_BYTES=$(cat "$DEST51")
SNAP51=$(mktemp "$SUITE_TMP/SNAP51.XXXXXX") || exit 1
cp -p "$DEST51" "$SNAP51"
printf '#!/bin/sh\necho himmel-installed-script\n' > "$DEST51"
( prov_begin --writer adopt.sh -- seed-red51 >/dev/null
  prov_record replace file "$DEST51" --scope project --class code --row adopter-scripts \
    --writer adopt.sh --pre-file "$SNAP51" --backup --post-file "$DEST51" >/dev/null
  prov_end ok >/dev/null )
rm -f "$SNAP51"
run_uninstall --yes --keep-telegram-state --skip-tasks --skip-plugins --skip-hooks --skip-settings >/dev/null
rc51=$?
AFTER51_BYTES=$(cat "$DEST51")
RESTORED51=$([ "$AFTER51_BYTES" = "$ORIG51_BYTES" ] && echo yes || echo no)
REFUSED51=$([ "$rc51" -ne 0 ] && echo yes || echo no)
OUTCOME51=BUG
{ [ "$RESTORED51" = yes ] || [ "$REFUSED51" = yes ]; } && OUTCOME51=ok
check "RED51: uninstall from a non-project cwd either resolves+restores or refuses non-zero (never silent rc=0 with nothing restored)" \
  "$OUTCOME51" "ok"

echo "==== RED52 (HIMMEL-3637): --purge-state must refuse when the recorded project dir itself is gone (J1274O w1 'clone deleted') ===="
# The exact judge repro shape: the adopted project directory is deleted
# entirely (not just left unrestored), so the recorded path's current state
# reads ABSENT and prov_read_verdict says "keep already-absent" rather than
# "restore" -- a distinct code path from RED50/RED51, which both leave the
# project directory on disk.
new_case red52
PROJDIR52="$CASE_DIR/project"
mkdir -p "$PROJDIR52/scripts"
DEST52="$PROJDIR52/scripts/clean.sh"
printf '#!/bin/sh\necho original-user-script\n' > "$DEST52"
SNAP52=$(mktemp "$SUITE_TMP/SNAP52.XXXXXX") || exit 1
cp -p "$DEST52" "$SNAP52"
printf '#!/bin/sh\necho himmel-installed-script\n' > "$DEST52"
( prov_begin --writer adopt.sh -- seed-red52 >/dev/null
  prov_record replace file "$DEST52" --scope project --class code --row adopter-scripts \
    --writer adopt.sh --pre-file "$SNAP52" --backup --post-file "$DEST52" >/dev/null
  prov_end ok >/dev/null )
rm -f "$SNAP52"
rm -rf "$PROJDIR52"
BACKUPS52_BEFORE=$(find "$HIMMEL_PROVENANCE_DIR/provenance-backups" -type f 2>/dev/null | wc -l | tr -d ' ')
check "RED52: setup actually created a backup (control is not vacuous)" "$([ "$BACKUPS52_BEFORE" -gt 0 ] && echo yes || echo no)" "yes"
run_uninstall --yes --skip-tasks --skip-plugins --skip-hooks --skip-settings --purge-state >/dev/null
rc52=$?
BACKUPS52_AFTER=$(find "$HIMMEL_PROVENANCE_DIR/provenance-backups" -type f 2>/dev/null | wc -l | tr -d ' ')
REFUSED52=$([ "$rc52" -ne 0 ] && echo yes || echo no)
check "RED52: --purge-state refuses (non-zero) when the adopted project directory itself is gone" "$REFUSED52" "yes"
check "RED52: refusing means deleting nothing — the backup survives" "$BACKUPS52_AFTER" "$BACKUPS52_BEFORE"

echo "==== RED53 (HIMMEL-3637 R3-codex2): --purge-state must refuse when prov_read_units itself fails, not treat a failed read as zero units ===="
# Round-1 critic finding: 'done <<EOF\n$(prov_read_units)\nEOF' fed an empty
# loop body whether prov_read_units returned zero units OR failed outright --
# both looked identical to the scan. RED53 forces the LATTER: the ledger loads
# fine (LEDGER_OK=1), a recorded backup exists and is unrestored exactly like
# RED50, but prov_read_units' own fold query errors (RED53_FORCE_JQ_FAIL=1's
# jq shim above). The scan must fail closed, exactly as if it had read the
# real unrestored unit, not silently proceed as "nothing to check".
new_case red53
PROJDIR53="$CASE_DIR/project"
mkdir -p "$PROJDIR53/scripts"
DEST53="$PROJDIR53/scripts/clean.sh"
printf '#!/bin/sh\necho original-user-script\n' > "$DEST53"
SNAP53=$(mktemp "$SUITE_TMP/SNAP53.XXXXXX") || exit 1
cp -p "$DEST53" "$SNAP53"
printf '#!/bin/sh\necho himmel-installed-script\n' > "$DEST53"
( prov_begin --writer adopt.sh -- seed-red53 >/dev/null
  prov_record replace file "$DEST53" --scope project --class code --row adopter-scripts \
    --writer adopt.sh --pre-file "$SNAP53" --backup --post-file "$DEST53" >/dev/null
  prov_end ok >/dev/null )
rm -f "$SNAP53"
BACKUPS53_BEFORE=$(find "$HIMMEL_PROVENANCE_DIR/provenance-backups" -type f 2>/dev/null | wc -l | tr -d ' ')
check "RED53: setup actually created a backup (control is not vacuous)" "$([ "$BACKUPS53_BEFORE" -gt 0 ] && echo yes || echo no)" "yes"
export RED53_FORCE_JQ_FAIL=1
run_uninstall --yes --skip-tasks --skip-plugins --skip-hooks --skip-settings --purge-state >/dev/null
rc53=$?
unset RED53_FORCE_JQ_FAIL
BACKUPS53_AFTER=$(find "$HIMMEL_PROVENANCE_DIR/provenance-backups" -type f 2>/dev/null | wc -l | tr -d ' ')
REFUSED53=$([ "$rc53" -ne 0 ] && echo yes || echo no)
check "RED53: --purge-state refuses (non-zero) when prov_read_units itself fails" "$REFUSED53" "yes"
check "RED53: refusing means deleting nothing — the backup survives" "$BACKUPS53_AFTER" "$BACKUPS53_BEFORE"

echo "==== RED54 (HIMMEL-3637 R5-codex1): --purge-state must refuse when a per-row jq check itself fails, not treat the row as backup-less ===="
# Round-5 critic finding: the purge-time scan's per-row backup check
# ('jq -e .eff_pre.backup // empty || continue') could not tell "this row
# genuinely has no backup" from "jq itself failed reading this row" (a
# malformed provenance-ledger line) -- both fell into the same
# `|| continue`. Fixed by validating each row's JSON parseability up front
# (tagged with the pu-json marker comment so this shim can target only that check,
# not prov_read_units' own fold query or any unrelated `jq -e .` validity
# check elsewhere in uninstall.sh's unwire helpers) and by adding `?` to
# the backup-check filter itself, so a legitimate non-object eff_pre (e.g.
# `false`) can no longer produce a jq type-error exit that looked
# identical to a hard failure. RED54 forces the JSON-parseability check to
# fail via the RED54_FORCE_JQ_FAIL shim above, on a row that DOES have a
# genuine, unrestored backup. The scan must fail closed exactly as if it
# had read the real unrestored unit, not silently skip it as unparsable.
new_case red54
PROJDIR54="$CASE_DIR/project"
mkdir -p "$PROJDIR54/scripts"
DEST54="$PROJDIR54/scripts/clean.sh"
printf '#!/bin/sh\necho original-user-script\n' > "$DEST54"
SNAP54=$(mktemp "$SUITE_TMP/SNAP54.XXXXXX") || exit 1
cp -p "$DEST54" "$SNAP54"
printf '#!/bin/sh\necho himmel-installed-script\n' > "$DEST54"
( prov_begin --writer adopt.sh -- seed-red54 >/dev/null
  prov_record replace file "$DEST54" --scope project --class code --row adopter-scripts \
    --writer adopt.sh --pre-file "$SNAP54" --backup --post-file "$DEST54" >/dev/null
  prov_end ok >/dev/null )
rm -f "$SNAP54"
BACKUPS54_BEFORE=$(find "$HIMMEL_PROVENANCE_DIR/provenance-backups" -type f 2>/dev/null | wc -l | tr -d ' ')
check "RED54: setup actually created a backup (control is not vacuous)" "$([ "$BACKUPS54_BEFORE" -gt 0 ] && echo yes || echo no)" "yes"
export RED54_FORCE_JQ_FAIL=1
run_uninstall --yes --skip-tasks --skip-plugins --skip-hooks --skip-settings --purge-state >/dev/null
rc54=$?
unset RED54_FORCE_JQ_FAIL
BACKUPS54_AFTER=$(find "$HIMMEL_PROVENANCE_DIR/provenance-backups" -type f 2>/dev/null | wc -l | tr -d ' ')
REFUSED54=$([ "$rc54" -ne 0 ] && echo yes || echo no)
check "RED54: --purge-state refuses (non-zero) when the per-row backup check itself fails" "$REFUSED54" "yes"
check "RED54: refusing means deleting nothing — the backup survives" "$BACKUPS54_AFTER" "$BACKUPS54_BEFORE"

echo "==== RED55 (HIMMEL-3787): a torn/unparsable ledger row's own backup must refuse --purge-state (backup-dir orphan scan); a healthy row alongside it still restores normally ===="
# Minor (b): a torn row is dropped SILENTLY at ledger LOAD (before it
# ever reaches prov_read_units), so the per-unit scan above never
# sees it and has nothing to refuse on. Simulates a crash mid-append: the
# backup file for DEST_TORN55 was written successfully, but its ledger row
# never finished writing (truncated line, unparsable).
new_case red55
mkdir -p "$CASE_DIR/cwd/scripts"
DEST_GOOD55="$CASE_DIR/cwd/scripts/good.sh"
DEST_TORN55="$CASE_DIR/cwd/scripts/torn.sh"
printf '#!/bin/sh\necho original-good\n' > "$DEST_GOOD55"
printf '#!/bin/sh\necho original-torn\n' > "$DEST_TORN55"
ORIG_GOOD55_BYTES=$(cat "$DEST_GOOD55")
SNAP_GOOD55=$(mktemp "$SUITE_TMP/SNAPG55.XXXXXX") || exit 1
cp -p "$DEST_GOOD55" "$SNAP_GOOD55"
SNAP_TORN55=$(mktemp "$SUITE_TMP/SNAPT55.XXXXXX") || exit 1
cp -p "$DEST_TORN55" "$SNAP_TORN55"
printf '#!/bin/sh\necho himmel-installed-good\n' > "$DEST_GOOD55"
printf '#!/bin/sh\necho himmel-installed-torn\n' > "$DEST_TORN55"
( prov_begin --writer adopt.sh -- seed-red55 >/dev/null
  prov_record replace file "$DEST_GOOD55" --scope project --class code --row adopter-scripts \
    --writer adopt.sh --pre-file "$SNAP_GOOD55" --backup --post-file "$DEST_GOOD55" >/dev/null
  prov_record replace file "$DEST_TORN55" --scope project --class code --row adopter-scripts \
    --writer adopt.sh --pre-file "$SNAP_TORN55" --backup --post-file "$DEST_TORN55" >/dev/null
  prov_end ok >/dev/null )
rm -f "$SNAP_GOOD55" "$SNAP_TORN55"
LEDGER55="$HIMMEL_PROVENANCE_DIR/provenance.jsonl"
BACKUPS55_BEFORE=$(find "$HIMMEL_PROVENANCE_DIR/provenance-backups" -type f ! -name '*.ours' 2>/dev/null | wc -l | tr -d ' ')
check "RED55: setup actually created two backups (control is not vacuous)" "$BACKUPS55_BEFORE" "2"
# truncate the TORN row's own line to half its length so it no longer
# parses as JSON at all -- its backup, created above, is untouched.
TORN55_LINE=$(grep -n -F "$DEST_TORN55" "$LEDGER55" | tail -1 | cut -d: -f1)
[ -n "$TORN55_LINE" ] || { echo "FAIL - RED55 setup: could not find the torn row's own line" >&2; fails=$((fails+1)); }
TORN55_CONTENT=$(sed -n "${TORN55_LINE}p" "$LEDGER55")
TORN55_HALF="${TORN55_CONTENT:0:$((${#TORN55_CONTENT} / 2))}"
awk -v n="$TORN55_LINE" -v r="$TORN55_HALF" 'NR==n{print r; next} {print}' "$LEDGER55" > "$LEDGER55.next" \
  && mv "$LEDGER55.next" "$LEDGER55"
out55=$(run_uninstall --yes --purge-state --skip-tasks --skip-plugins --skip-hooks --skip-settings)
rc55=$?
BACKUPS55_AFTER=$(find "$HIMMEL_PROVENANCE_DIR/provenance-backups" -type f ! -name '*.ours' 2>/dev/null | wc -l | tr -d ' ')
REFUSED55=$([ "$rc55" -ne 0 ] && echo yes || echo no)
warn55=$(printf '%s\n' "$out55" | grep -c -F "refused to purge")
check "RED55: --purge-state refuses (non-zero) when a torn ledger row's own backup is on disk" "$REFUSED55" "yes"
check "RED55: a refusal warning is printed" "$([ "$warn55" -ge 1 ] && echo yes || echo no)" "yes"
check "RED55: refusing means deleting nothing -- both backups survive" "$BACKUPS55_AFTER" "$BACKUPS55_BEFORE"
AFTER_GOOD55_BYTES=$(cat "$DEST_GOOD55")
check "RED55: the good row's unit still restores normally despite the torn row alongside it" \
  "$AFTER_GOOD55_BYTES" "$ORIG_GOOD55_BYTES"

echo "==== RED56 (HIMMEL-3787): a torn ledger row must NOT abort a normal (non-purge) uninstall -- only --purge-state is refused ===="
new_case red56
mkdir -p "$CASE_DIR/cwd/scripts"
DEST_GOOD56="$CASE_DIR/cwd/scripts/good.sh"
printf '#!/bin/sh\necho original-good\n' > "$DEST_GOOD56"
ORIG_GOOD56_BYTES=$(cat "$DEST_GOOD56")
SNAP_GOOD56=$(mktemp "$SUITE_TMP/SNAPG56.XXXXXX") || exit 1
cp -p "$DEST_GOOD56" "$SNAP_GOOD56"
printf '#!/bin/sh\necho himmel-installed-good\n' > "$DEST_GOOD56"
( prov_begin --writer adopt.sh -- seed-red56 >/dev/null
  prov_record replace file "$DEST_GOOD56" --scope project --class code --row adopter-scripts \
    --writer adopt.sh --pre-file "$SNAP_GOOD56" --backup --post-file "$DEST_GOOD56" >/dev/null
  prov_end ok >/dev/null )
rm -f "$SNAP_GOOD56"
LEDGER56="$HIMMEL_PROVENANCE_DIR/provenance.jsonl"
# a garbage line of its own -- never a real row, just a torn tail from a
# crash mid-append that a normal (non-purge) uninstall must tolerate.
printf '{"t":"2026-01-01T00:00:00Z","iid":"x","op":"replace","kind":"fil\n' >> "$LEDGER56"
run_uninstall --yes --keep-telegram-state --skip-tasks --skip-plugins --skip-hooks --skip-settings >/dev/null
rc56=$?
AFTER_GOOD56_BYTES=$(cat "$DEST_GOOD56")
check "RED56: a torn row does not abort a normal (non-purge) uninstall" "$rc56" "0"
check "RED56: the good row's unit still restores normally on a normal uninstall" \
  "$AFTER_GOOD56_BYTES" "$ORIG_GOOD56_BYTES"

echo "==== RED57 (HIMMEL-3787): a backup file with NO ledger row at all -- not even a torn one -- must refuse --purge-state (orphan-backup-dir scan alone, independent of PROV_READ_BAD_ROWS) ===="
# Simulates a crash between writing the backup and appending ANY row for it
# (not even a truncated line): the ledger is fully well-formed and has zero
# bad rows, so RED55's "any bad row refuses" half of the fix has nothing to
# catch this -- only the backup-directory orphan scan (contract 3(b)) can.
new_case red57
mkdir -p "$CASE_DIR/cwd/scripts"
DEST_GOOD57="$CASE_DIR/cwd/scripts/good.sh"
printf '#!/bin/sh\necho original-good\n' > "$DEST_GOOD57"
ORIG_GOOD57_BYTES=$(cat "$DEST_GOOD57")
SNAP_GOOD57=$(mktemp "$SUITE_TMP/SNAPG57.XXXXXX") || exit 1
cp -p "$DEST_GOOD57" "$SNAP_GOOD57"
printf '#!/bin/sh\necho himmel-installed-good\n' > "$DEST_GOOD57"
( prov_begin --writer adopt.sh -- seed-red57 >/dev/null
  prov_record replace file "$DEST_GOOD57" --scope project --class code --row adopter-scripts \
    --writer adopt.sh --pre-file "$SNAP_GOOD57" --backup --post-file "$DEST_GOOD57" >/dev/null
  prov_end ok >/dev/null )
rm -f "$SNAP_GOOD57"
# an orphan backup with NO ledger row referencing it at all -- the ledger
# above is fully well-formed (PROV_READ_BAD_ROWS stays 0).
mkdir -p "$HIMMEL_PROVENANCE_DIR/provenance-backups"
ORPHAN57="$HIMMEL_PROVENANCE_DIR/provenance-backups/orphan-red57.pre.backup"
printf 'orphan-backup-content-red57\n' > "$ORPHAN57"
BACKUPS57_BEFORE=$(find "$HIMMEL_PROVENANCE_DIR/provenance-backups" -type f ! -name '*.ours' 2>/dev/null | wc -l | tr -d ' ')
check "RED57: setup actually created two backups, one orphan (control is not vacuous)" "$BACKUPS57_BEFORE" "2"
out57=$(run_uninstall --yes --purge-state --skip-tasks --skip-plugins --skip-hooks --skip-settings)
rc57=$?
BACKUPS57_AFTER=$(find "$HIMMEL_PROVENANCE_DIR/provenance-backups" -type f ! -name '*.ours' 2>/dev/null | wc -l | tr -d ' ')
REFUSED57=$([ "$rc57" -ne 0 ] && echo yes || echo no)
warn57=$(printf '%s\n' "$out57" | grep -c -F "refused to purge")
check "RED57: --purge-state refuses (non-zero) when an orphan backup has no ledger row at all" "$REFUSED57" "yes"
check "RED57: a refusal warning is printed" "$([ "$warn57" -ge 1 ] && echo yes || echo no)" "yes"
check "RED57: refusing means deleting nothing -- both backups survive, including the orphan" "$BACKUPS57_AFTER" "$BACKUPS57_BEFORE"
check "RED57: the orphan backup file itself still exists" "$([ -f "$ORPHAN57" ] && echo yes || echo no)" "yes"
AFTER_GOOD57_BYTES=$(cat "$DEST_GOOD57")
check "RED57: the good row's unit still restores normally despite the orphan backup" \
  "$AFTER_GOOD57_BYTES" "$ORIG_GOOD57_BYTES"

echo "==== RED58 (HIMMEL-3787 S2a, spec case a): a kept user-modified unit's backup is HELD by --purge-state, not silently purged (J1390A Finding 4) ===="
new_case red58
mkdir -p "$CASE_DIR/cwd/scripts"
DEST58="$CASE_DIR/cwd/scripts/red58.sh"
printf '#!/bin/sh\necho original-user-script\n' > "$DEST58"
SNAP58=$(mktemp "$SUITE_TMP/SNAP58.XXXXXX") || exit 1; cp -p "$DEST58" "$SNAP58"
printf '#!/bin/sh\necho himmel-installed-script\n' > "$DEST58"
( prov_begin --writer adopt.sh -- seed-red58 >/dev/null
  prov_record replace file "$DEST58" --scope project --class code --row adopter-scripts \
    --writer adopt.sh --pre-file "$SNAP58" --backup --post-file "$DEST58" >/dev/null
  prov_end ok >/dev/null )
rm -f "$SNAP58"
# the operator edits the file again after install recorded it -- verdict
# "keep user-modified": held, not resolved (§5.1). --purge-state (WITHOUT
# --keep-backups) must refuse rather than silently deleting this backup.
printf '#!/bin/sh\necho operator-edited-after-install\n' > "$DEST58"
BACKUP58=$(find "$(prov_dir)/provenance-backups" -type f | head -n1)
[ -n "$BACKUP58" ] || { echo "FAIL - RED58 setup: backup for DEST58 not found"; fails=$((fails+1)); }
out58=$(run_uninstall --yes --purge-state --skip-tasks --skip-plugins --skip-hooks)
rc58=$?
refused58=$([ "$rc58" -ne 0 ] && echo yes || echo no)
backup_kept58=$([ -f "$BACKUP58" ] && echo yes || echo no)
check "RED58 (S2a case a): --purge-state refuses on a held keep-user-modified backup, not silently purged" \
  "$refused58|$backup_kept58" "yes|yes"
warn58=$(printf '%s\n' "$out58" | grep -c -F -- "--keep-backups")
check "RED58: the refusal text names --keep-backups as the escape hatch" \
  "$([ "$warn58" -ge 1 ] && echo yes || echo no)" "yes"

echo "==== RED59 (HIMMEL-3787 S2a, spec case b): --purge-state --keep-backups retains, then a reinstall+purge is not a permanent orphan refusal (J1393A P11) ===="
new_case red59
mkdir -p "$CASE_DIR/cwd/scripts"
DEST59="$CASE_DIR/cwd/scripts/red59.sh"
printf '#!/bin/sh\necho original-user-script\n' > "$DEST59"
SNAP59=$(mktemp "$SUITE_TMP/SNAP59.XXXXXX") || exit 1; cp -p "$DEST59" "$SNAP59"
printf '#!/bin/sh\necho himmel-installed-script\n' > "$DEST59"
( prov_begin --writer adopt.sh -- seed-red59 >/dev/null
  prov_record replace file "$DEST59" --scope project --class code --row adopter-scripts \
    --writer adopt.sh --pre-file "$SNAP59" --backup --post-file "$DEST59" >/dev/null
  prov_end ok >/dev/null )
rm -f "$SNAP59"
printf '#!/bin/sh\necho operator-edited-after-install\n' > "$DEST59"
run_uninstall --yes --purge-state --keep-backups --skip-tasks --skip-plugins --skip-hooks >/dev/null
RETAINED59=$(find "$(prov_dir)" -maxdepth 1 -type d -name 'retained-*' | head -n1)
[ -n "$RETAINED59" ] || { echo "FAIL - RED59 setup: no retained-* dir after the first purge"; fails=$((fails+1)); }
# A reinstall records a fresh, clean session (nothing held) at the standard
# live ledger path. The earlier retained-* dir is a sibling the orphan-backup
# scan never looks inside, so it must not poison this second purge -- on
# main, --keep-backups left provenance-backups/ behind at its OLD path as a
# permanent orphan, so EVERY later purge refused forever (P11).
DEST59B="$CASE_DIR/cwd/scripts/red59b.sh"
printf '#!/bin/sh\necho reinstalled\n' > "$DEST59B"
( prov_begin --writer adopt.sh -- seed-red59-reinstall >/dev/null
  prov_record create file "$DEST59B" --scope project --class code --row adopter-scripts \
    --writer adopt.sh --pre-absent --post-file "$DEST59B" >/dev/null
  prov_end ok >/dev/null )
run_uninstall --yes --purge-state --skip-tasks --skip-plugins --skip-hooks >/dev/null
rc59=$?
check "RED59 (S2a case b): a purge after a reinstall is not permanently blocked by an earlier retained-* purge" \
  "$rc59" "0"
check "RED59: the earlier retained-* dir is left untouched (never auto-deleted)" \
  "$([ -d "$RETAINED59" ] && echo yes || echo no)" "yes"

echo "==== RED60 (HIMMEL-3787 S2a, spec case c; HIMMEL-3787 codex-1 panel round 1): a container whose governed children were NEVER reverted (--skip-settings) must not release its backup ===="
# Same fixture as the old CASE60, but --skip-settings means the settings
# unwire step (which would physically revert the children) never runs -- the
# live file stays exactly at post-install. _provread_container_child_clean
# used to accept a bare "remove"/"restore" VERDICT as clean (a recommendation
# prov_read_verdict computes from CURRENT live state, not a record that the
# action ran), so the container's own backup was released here while a
# governed child (HANDOVER_DIR) was still live and installed, with no backup
# left to restore it from -- confirmed on this exact fixture before the fix
# (backup released, HANDOVER_DIR still present). The fix in
# provenance-read.sh drops that blanket accept; only a verdict that already
# reflects a REVERTED live state (keep already-base / keep already-absent
# with no backup) counts as clean now, so --skip-settings + a live governed
# child must refuse or hold, never release.
new_case red60
# /env was explicitly null before this install (the only real shape that
# gives the /env container itself a backup -- wire-himmel-repo.sh only
# records a container row when .env was absent or null beforehand).
printf '{"env": null}\n' > "$CASE_SETTINGS"
( prov_begin --writer wire-himmel-repo.sh -- seed-red60 >/dev/null
  prov_record replace json-key "$CASE_SETTINGS" --unit /env --scope user --class code \
    --writer wire-himmel-repo.sh --row user-settings \
    --pre-json null --backup \
    --post-json '{"HANDOVER_DIR":"/opt/red60-handover","LUNA_VAULT_PATH":"/opt/red60-vault"}' >/dev/null
  prov_record create json-key "$CASE_SETTINGS" --unit /env/HANDOVER_DIR --scope user --class code \
    --writer wire-himmel-repo.sh --row user-settings \
    --pre-absent --post-json '"/opt/red60-handover"' >/dev/null
  prov_record create json-key "$CASE_SETTINGS" --unit /env/LUNA_VAULT_PATH --scope user --class code \
    --writer wire-himmel-repo.sh --row user-settings \
    --pre-absent --post-json '"/opt/red60-vault"' >/dev/null
  prov_end ok >/dev/null )
BACKUP60=$(find "$(prov_dir)/provenance-backups" -type f | head -n1)
[ -n "$BACKUP60" ] || { echo "FAIL - RED60 setup: backup for the /env container not found"; fails=$((fails+1)); }
# The live file: both governed children are untouched since install (clean,
# verdict "remove ours" -- a recommendation, never executed under
# --skip-settings), plus a bystander key the operator added by hand that
# himmel never recorded a unit for -- so the CONTAINER's own live value
# differs from what it recorded (L != O).
cat > "$CASE_SETTINGS" <<JSON
{
  "env": {
    "HANDOVER_DIR": "/opt/red60-handover",
    "LUNA_VAULT_PATH": "/opt/red60-vault",
    "MY_USER_KEY": "operator-bystander-value"
  }
}
JSON
run_uninstall --yes --purge-state --skip-tasks --skip-plugins --skip-hooks --skip-settings >/dev/null
rc60=$?
check "RED60 (S2a case c, codex-1 gap): --purge-state refuses/holds while a governed child is still live under --skip-settings" \
  "$([ "$rc60" -ne 0 ] && echo yes || echo no)" "yes"
check "RED60: the bystander key the operator added by hand is never touched" \
  "$(jq -r '.env.MY_USER_KEY // "ABSENT"' "$CASE_SETTINGS")" "operator-bystander-value"
check "RED60: the still-live governed child is untouched (never reverted by --skip-settings)" \
  "$(jq -r '.env.HANDOVER_DIR // "ABSENT"' "$CASE_SETTINGS")" "/opt/red60-handover"
check "RED60: the container's own backup is HELD, not released while a child is still live" \
  "$([ -f "$BACKUP60" ] && echo held || echo released)" "held"

echo "==== GREEN60 (HIMMEL-3787 S2a, spec case c): once the settings unwire step ACTUALLY reverts the children (no --skip-settings), the container resolves via its clean children and its backup releases ===="
# Identical ledger + live-file fixture to RED60, but this run does NOT pass
# --skip-settings: the real settings-unwire step ([6/8]) reverts the two
# governed children for real before the [8/8] purge scan runs, so by the
# time _provread_container_child_clean looks at them their verdict has
# already re-derived to "keep already-base"/"keep already-absent" from their
# OWN live state -- the same acceptance path RED60 shows must not be
# shortcut to when the revert never actually happened.
new_case green60
printf '{"env": null}\n' > "$CASE_SETTINGS"
( prov_begin --writer wire-himmel-repo.sh -- seed-green60 >/dev/null
  prov_record replace json-key "$CASE_SETTINGS" --unit /env --scope user --class code \
    --writer wire-himmel-repo.sh --row user-settings \
    --pre-json null --backup \
    --post-json '{"HANDOVER_DIR":"/opt/green60-handover","LUNA_VAULT_PATH":"/opt/green60-vault"}' >/dev/null
  prov_record create json-key "$CASE_SETTINGS" --unit /env/HANDOVER_DIR --scope user --class code \
    --writer wire-himmel-repo.sh --row user-settings \
    --pre-absent --post-json '"/opt/green60-handover"' >/dev/null
  prov_record create json-key "$CASE_SETTINGS" --unit /env/LUNA_VAULT_PATH --scope user --class code \
    --writer wire-himmel-repo.sh --row user-settings \
    --pre-absent --post-json '"/opt/green60-vault"' >/dev/null
  prov_end ok >/dev/null )
BACKUPG60=$(find "$(prov_dir)/provenance-backups" -type f | head -n1)
[ -n "$BACKUPG60" ] || { echo "FAIL - GREEN60 setup: backup for the /env container not found"; fails=$((fails+1)); }
cat > "$CASE_SETTINGS" <<JSON
{
  "env": {
    "HANDOVER_DIR": "/opt/green60-handover",
    "LUNA_VAULT_PATH": "/opt/green60-vault",
    "MY_USER_KEY": "operator-bystander-value"
  }
}
JSON
run_uninstall --yes --purge-state --skip-tasks --skip-plugins --skip-hooks >/dev/null
rcg60=$?
check "GREEN60 (S2a case c): --purge-state succeeds once settings-unwire has actually reverted the children" \
  "$rcg60" "0"
check "GREEN60: the bystander key the operator added by hand is never touched" \
  "$(jq -r '.env.MY_USER_KEY // "ABSENT"' "$CASE_SETTINGS")" "operator-bystander-value"
check "GREEN60: the governed children were actually removed by the real settings-unwire step" \
  "$(jq -r '.env.HANDOVER_DIR // "ABSENT"' "$CASE_SETTINGS")" "ABSENT"
check "GREEN60: the container's own backup is released, not held forever" \
  "$([ -f "$BACKUPG60" ] && echo held || echo released)" "released"



uninstall_prov_finish
