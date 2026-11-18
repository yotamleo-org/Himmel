#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2153,SC2154  # HBIN, U_BIN, calls and STUB_FAIL_IDS are set by the sourced testlib
# Smoke test for scripts/uninstall.sh, part 2 of 2: the U4f cases through the last case.
# State-touching invocations point TELEGRAM_CHANNEL_DIR + BRIDGE_ROOT at temp
# dirs and pass --skip-tasks --skip-plugins --skip-hooks where destructive, so
# the operator's real bridge, scheduled tasks, plugins, and git hooks are
# never touched. Two deliberate exceptions: test 2 sets no env overrides (the
# unknown flag must abort during arg parsing, before any state is read or
# removed), and test 6 points TELEGRAM_CHANNEL_DIR at $HOME on purpose to
# prove the suspicious-path guard refuses it (nothing is removed). The
# bridge-stop step runs only against a stubbed `bun` + supervisor.pid seeded
# in a temp BRIDGE_ROOT; scheduled-job discovery runs only against
# PATH-stubbed atq/at/crontab under --dry-run — except 9e/9f, which
# exercise the WET crontab rewrite against a stdin-capturing crontab stub
# (PATH puts the stub first, so the real crontab is never invoked).
# Partial-delete residue detection is not asserted here: bash has no portable
# way to hold an open handle that blocks rm.
# Usage: bash scripts/test-uninstall-b.sh
# selector: names uninstall-plugins.sh install-plugins.sh unwire-himmel-repo.sh unwire-luna-vault.sh unwire-handover-dir.sh
set -uo pipefail

CLI="$(cd "$(dirname "$0")" && pwd)/uninstall.sh"

# physical path (macOS $TMPDIR is /var -> /private/var); uninstall.sh compares $HOME/.himmel lexically against the resolved ledger dir.
TMPDIR=$(cd -P -- "${TMPDIR:-/tmp}" && pwd) || exit 1; export TMPDIR
TMP=$(mktemp -d "${TMPDIR:-/tmp}/uninstall-suite.XXXXXX") || { echo "FAIL could not create temp dir"; exit 1; }
# shellcheck source=tests/testlib-uninstall.sh
. "$(dirname "$CLI")/tests/testlib-uninstall.sh"

# The real-home caller scan traces every HOME below to a mktemp in this file; u_fixture replaces it per case.
U_HOME=$(mktemp -d "$TMP/u-home.XXXXXX") || exit 1
# Same fixture repo and claude stub the first part builds before its U cases.
u_suite_setup

# U4f..U4l: the adopter's own hook that install displaced
# to <hook>.himmel-backup. Foreign hook text deliberately names `pre-commit` (the
# shape from a VM round trip): under the old code the
# backup file tripped repo_has_framework_hooks, [5/8] halted rc=2 with steps 6-8
# skipped, and a re-run halted identically.
ADOPTER_HOOK_TEXT=$'#!/bin/sh\n# my own gate; runs pre-commit run --all-files when it is installed\nexit 0\n'
NATIVE_GATE_TEXT=$'#!/usr/bin/env bash\n# HIMMEL-2771: native invariant gate; lint hooks require pre-commit.\nexit 0\n'
u_hooks_reset() { find "$U_REPO/.git/hooks" -mindepth 1 ! -name '*.sample' -delete; }
# u_backup_fixture <name> — native gates at all three names, the adopter's own
# pre-commit displaced to pre-commit.himmel-backup (executable, as install leaves it).
u_backup_fixture() {
    u_fixture "$1"
    u_hooks_reset
    for hook in commit-msg pre-commit pre-push; do
        printf '%s' "$NATIVE_GATE_TEXT" > "$U_REPO/.git/hooks/$hook"
        chmod 755 "$U_REPO/.git/hooks/$hook"
    done
    printf '%s' "$ADOPTER_HOOK_TEXT" > "$U_REPO/.git/hooks/pre-commit.himmel-backup"
    chmod 755 "$U_REPO/.git/hooks/pre-commit.himmel-backup"
}
u_hook_is_adopters() {   # <label> — pre-commit is byte-identical to the pre-install hook, executable, backup gone
    local got
    got=$(cat "$U_REPO/.git/hooks/pre-commit" 2>/dev/null; echo x)
    if [ "$got" = "${ADOPTER_HOOK_TEXT}x" ] && [ -x "$U_REPO/.git/hooks/pre-commit" ] &&
        [ ! -e "$U_REPO/.git/hooks/pre-commit.himmel-backup" ]; then
        echo "PASS $1 adopter hook restored byte-identical, backup consumed"
    else
        echo "FAIL $1 adopter hook not restored (or backup left behind)"; FAILED=$((FAILED + 1))
    fi
}

# U4f — RED 3248: marker-free backup naming pre-commit, pre-commit absent: 8/8.
u_backup_fixture u4f
u_run
assert_rc 'U4f backup naming pre-commit completes' 0 "$rc"
assert_has 'U4f completion reported' 'Uninstall complete.' "$out"
assert_not_has 'U4f no halted steps' 'skipped — halted' "$out"
assert_not_has 'U4f no pre-commit-not-found halt' 'not found — this step did NOT run' "$out"
# RED 3249: the adopter's hook ends restored, not lost.
assert_has 'U4f restore row reported' "restored: $U_REPO/.git/hooks/pre-commit (from pre-commit.himmel-backup)" "$out"
u_hook_is_adopters 'U4f'
for hook in commit-msg pre-push; do
    if [ ! -e "$U_REPO/.git/hooks/$hook" ]; then echo "PASS U4f native $hook removed"
    else echo "FAIL U4f native $hook survived"; FAILED=$((FAILED + 1)); fi
done

# U4g — --dry-run lists the restore, mutates nothing, and the wet run above
# reported the same row (row-for-row parity on the restore).
u_backup_fixture u4g
U4G_BEFORE="$TMP/u4g-hooks-before.txt"
(cd "$U_REPO/.git/hooks" && cksum -- * | sort) > "$U4G_BEFORE"
u_run --dry-run
assert_rc 'U4g dry-run completes' 0 "$rc"
assert_not_has 'U4g no halted steps' 'skipped — halted' "$out"
assert_has 'U4g dry-run plans the restore' "DRY: would restore: $U_REPO/.git/hooks/pre-commit (from pre-commit.himmel-backup)" "$out"
assert_has 'U4g plan lists the restore' 'restore any of your own hooks' "$out"
U4G_AFTER="$TMP/u4g-hooks-after.txt"
(cd "$U_REPO/.git/hooks" && cksum -- * | sort) > "$U4G_AFTER"
cmp -s "$U4G_BEFORE" "$U4G_AFTER"; same=$?
assert_rc 'U4g hooks byte-identical across dry-run' 0 "$same"

# U4h — RED 3248 re-run: the state the OLD code left after its halt (gates and
# payload already removed, backup still there, steps 6-8 never ran) must
# complete on a re-run instead of halting identically.
u_backup_fixture u4h
rm -f "$U_REPO/.git/hooks/commit-msg" "$U_REPO/.git/hooks/pre-commit" "$U_REPO/.git/hooks/pre-push"
u_run
assert_rc 'U4h re-run after the old halt completes' 0 "$rc"
assert_not_has 'U4h no halted steps' 'skipped — halted' "$out"
u_hook_is_adopters 'U4h'
if [ ! -e "$U_CACHE" ]; then echo 'PASS U4h step 8 ran on the re-run'
else echo 'FAIL U4h step 8 left cache'; FAILED=$((FAILED + 1)); fi

# U4i — never overwrite: a hook now at the name that is NOT a himmel gate keeps
# its place and the backup stays put (both preserved), reported per row.
u_backup_fixture u4i
printf '#!/bin/sh\necho later hook\n' > "$U_REPO/.git/hooks/pre-commit"
chmod 755 "$U_REPO/.git/hooks/pre-commit"
u_run
assert_rc 'U4i foreign hook at the name completes' 0 "$rc"
assert_has 'U4i keep row reported' "kept (not restored): $U_REPO/.git/hooks/pre-commit exists and is not a himmel gate" "$out"
if [ "$(cat "$U_REPO/.git/hooks/pre-commit")" = '#!/bin/sh
echo later hook' ] && [ "$(cat "$U_REPO/.git/hooks/pre-commit.himmel-backup"; echo x)" = "${ADOPTER_HOOK_TEXT}x" ]; then
    echo 'PASS U4i both hooks preserved'
else
    echo 'FAIL U4i a hook was overwritten or lost'; FAILED=$((FAILED + 1))
fi

# U4j — the manifest decides: git-hook-backups class keep leaves the backup where
# it is (native gates still go) and says so per row.
sed -e $'s/^git-hook-backups\tcode/git-hook-backups\tkeep/' \
    "$(dirname "$CLI")/install/uninstall-manifest.tsv" > "$TMP/u4j-manifest.tsv"
u_backup_fixture u4j
HIMMEL_UNINSTALL_MANIFEST="$TMP/u4j-manifest.tsv" u_run
assert_rc 'U4j class keep completes' 0 "$rc"
assert_has 'U4j keep row reported' 'keep displaced hook backups (manifest class keep)' "$out"
if [ ! -e "$U_REPO/.git/hooks/pre-commit" ] && [ "$(cat "$U_REPO/.git/hooks/pre-commit.himmel-backup"; echo x)" = "${ADOPTER_HOOK_TEXT}x" ]; then
    echo 'PASS U4j backup kept in place, gate removed'
else
    echo 'FAIL U4j class keep did not leave the backup alone'; FAILED=$((FAILED + 1))
fi

# U4k — RED 3250: a genuine halt names the file that tripped the check and
# prints a command that WORKS. The printed line is extracted and run AS PRINTED:
# u_run passed --purge-state --skip-tasks, so the command must carry both — a
# rerun that dropped the operator's own --skip-* would remove what they chose
# to keep (and here would reach the scheduler).
u_backup_fixture u4k
u_hooks_reset
framework_hook_text > "$U_REPO/.git/hooks/commit-msg"
u_run
assert_rc 'U4k framework-looking hook halts' 2 "$rc"
assert_has 'U4k halt names the file that tripped' "$U_REPO/.git/hooks/commit-msg" "$out"
assert_not_has 'U4k no login-shell advice' 'login shell' "$out"
assert_not_has 'U4k no bash -l advice' 'bash -l' "$out"
u4k_cmd=$(printf '%s\n' "$out" | grep -m1 '^    HIMMEL_UNINSTALL_REAL_HOME=1 bash ' | sed 's/^    //')
assert_has 'U4k printed command skips hooks' '--skip-hooks' "$u4k_cmd"
assert_has 'U4k printed command keeps the operator --skip-tasks' '--skip-tasks' "$u4k_cmd"
assert_has 'U4k printed command keeps --purge-state' '--purge-state' "$u4k_cmd"
assert_has 'U4k printed command uses the absolute script path' "$CLI" "$u4k_cmd"
rm -f "$U_REPO/.git/hooks/commit-msg"
if [ -n "$u4k_cmd" ]; then
    u4k_out=$(HOME="$U_HOME" PATH="$U_BIN:$HBIN" HIMMEL_UNINSTALL_REPO_ROOT="$U_REPO" \
        TELEGRAM_CHANNEL_DIR="$CHANNEL" BRIDGE_ROOT="$BRIDGE" HIMMELCTL_CACHE_DIR="$U_CACHE" \
        bash -c "$u4k_cmd" </dev/null 2>&1); u4k_rc=$?
else
    u4k_out=''; u4k_rc=99
fi
assert_rc 'U4k the printed command runs to completion' 0 "$u4k_rc"
assert_has 'U4k printed command kept the hooks step' 'kept (--skip-hooks).' "$u4k_out"
assert_has 'U4k printed command finished the teardown' 'Uninstall complete.' "$u4k_out"

# U4m — the printed command mirrors EVERY mode flag the run was given, not just
# --purge-state/--skip-*: a dry run's advice stays a dry run (it must never turn
# a preview into a wet teardown), and --keep-telegram-state survives the rerun.
u_backup_fixture u4m
u_hooks_reset
framework_hook_text > "$U_REPO/.git/hooks/commit-msg"
u_run --dry-run
assert_rc 'U4m dry-run halt' 2 "$rc"
u4m_cmd=$(printf '%s\n' "$out" | grep -m1 '^    HIMMEL_UNINSTALL_REAL_HOME=1 bash ' | sed 's/^    //')
assert_has 'U4m dry-run advice stays a dry run' '--dry-run' "$u4m_cmd"
u4m_out=$(HOME="$U_HOME" PATH="$U_BIN:$HBIN" HIMMEL_UNINSTALL_REPO_ROOT="$U_REPO" \
    TELEGRAM_CHANNEL_DIR="$CHANNEL" BRIDGE_ROOT="$BRIDGE" HIMMELCTL_CACHE_DIR="$U_CACHE" \
    bash "$CLI" --keep-telegram-state --yes --skip-tasks </dev/null 2>&1); u4m_rc=$?
assert_rc 'U4m keep-telegram-state halt' 2 "$u4m_rc"
u4m_kcmd=$(printf '%s\n' "$u4m_out" | grep -m1 '^    HIMMEL_UNINSTALL_REAL_HOME=1 bash ' | sed 's/^    //')
assert_has 'U4m advice keeps --keep-telegram-state' '--keep-telegram-state' "$u4m_kcmd"
assert_not_has 'U4m keep-telegram-state advice is not a dry run' '--dry-run' "$u4m_kcmd"
rm -f "$U_REPO/.git/hooks/commit-msg"

# U4l — RED: an adopter hook that merely MENTIONS pre-commit but
# carries none of the framework's six hashes is not a framework hook — `pre-commit
# uninstall` could never remove it — so with pre-commit absent it must NOT halt
# [5/8]. Pre-fix this halted rc=2 with steps 6-8 skipped (the bare-substring test).
u_backup_fixture u4l
u_hooks_reset
printf '%s' "$ADOPTER_HOOK_TEXT" > "$U_REPO/.git/hooks/pre-commit"
u_run
assert_rc 'U4l mention-only hook completes' 0 "$rc"
assert_has 'U4l completion reported' 'Uninstall complete.' "$out"
assert_has 'U4l absent pre-commit is a note' "note: \`pre-commit\` not found and this repo carries no framework hooks — nothing to uninstall" "$out"
assert_not_has 'U4l no halted steps' 'skipped — halted' "$out"
assert_not_has 'U4l no pre-commit-not-found halt' 'not found — this step did NOT run' "$out"
# "did not halt" is not "finished the job": steps 6-8 must have actually RUN.
assert_has 'U4l settings unwire ran' '[6/8] Unwiring' "$out"
assert_has 'U4l marketplaces ran' 'plugin marketplace remove himmel' "$calls"
if [ ! -e "$U_CACHE" ]; then echo 'PASS U4l step 8 removed cache'
else echo 'FAIL U4l step 8 left cache'; FAILED=$((FAILED + 1)); fi
if [ "$(cat "$U_REPO/.git/hooks/pre-commit"; echo x)" = "${ADOPTER_HOOK_TEXT}x" ]; then
    echo 'PASS U4l adopter hook untouched'
else
    echo 'FAIL U4l adopter hook changed'; FAILED=$((FAILED + 1))
fi
u_hooks_reset

# U4n — the positive control that keeps U4l honest (a fix that merely stops
# detecting hooks is a vacuous pass): a marker-free hook carrying CURRENT_HASH or
# ANY of the five PRIOR_HASHES is a real framework hook and still halts [5/8] with
# pre-commit absent, naming the file. An older pre-commit is exactly who this is for.
u4n_i=0
for u4n_hash in "${FRAMEWORK_HASHES[@]}"; do
    u4n_i=$((u4n_i + 1))
    u_fixture "u4n$u4n_i"
    u_hooks_reset
    framework_hook_text "$u4n_hash" > "$U_REPO/.git/hooks/commit-msg"
    u_run
    assert_rc "U4n hash $u4n_i (${u4n_hash:0:8}) still halts" 2 "$rc"
    assert_has "U4n hash $u4n_i first failure is hooks" 'Halted at: [5/8]' "$out"
    assert_has "U4n hash $u4n_i halt names the file" "$U_REPO/.git/hooks/commit-msg" "$out"
    u_hooks_reset
done
# U4n-miss — a one-character-short CURRENT_HASH is not the framework's hash: the
# match is the whole 32-hex string, not a prefix or a shape.
u_fixture u4nmiss
u_hooks_reset
framework_hook_text "${FRAMEWORK_HASHES[0]%?}" > "$U_REPO/.git/hooks/commit-msg"
u_run
assert_rc 'U4n-miss truncated hash is not a framework hook' 0 "$rc"
assert_not_has 'U4n-miss no halted steps' 'skipped — halted' "$out"
u_hooks_reset

# WHY: settings and marketplace failures must preserve the
# retry profile too — the same halt rule applies past the plugin/hook steps.
u_fixture u5
printf 'invalid JSON\n' > "$HIMMEL_USER_SETTINGS"
out=$(HOME="$U_HOME" PATH="$U_BIN:$HBIN" HIMMEL_UNINSTALL_REPO_ROOT="$U_REPO" \
    TELEGRAM_CHANNEL_DIR="$CHANNEL" BRIDGE_ROOT="$BRIDGE" HIMMELCTL_CACHE_DIR="$U_CACHE" \
    bash "$CLI" --purge-state --yes --skip-tasks --skip-hooks </dev/null 2>&1); rc=$?
assert_rc 'U5 invalid settings halt teardown' 2 "$rc"
assert_has 'U5 first failure is settings' 'Halted at: [6/8]' "$out"
assert_not_has 'U5 marketplaces untouched' 'plugin marketplace remove' "$(cat "$CLAUDE_CALL_LOG")"
if [ -f "$U_CACHE/install-profile.json" ]; then echo 'PASS U5 retry profile survives'
else echo 'FAIL U5 retry profile removed'; FAILED=$((FAILED + 1)); fi

u_fixture u6
STUB_FAIL_IDS='himmel'
out=$(HOME="$U_HOME" PATH="$U_BIN:$HBIN" HIMMEL_UNINSTALL_REPO_ROOT="$U_REPO" \
    TELEGRAM_CHANNEL_DIR="$CHANNEL" BRIDGE_ROOT="$BRIDGE" HIMMELCTL_CACHE_DIR="$U_CACHE" \
    bash "$CLI" --purge-state --yes --skip-tasks --skip-hooks </dev/null 2>&1); rc=$?
assert_rc 'U6 failed marketplace halts teardown' 2 "$rc"
assert_has 'U6 first failure is marketplaces' 'Halted at: [7/8]' "$out"
if [ -f "$U_CACHE/install-profile.json" ]; then echo 'PASS U6 retry profile survives'
else echo 'FAIL U6 retry profile removed'; FAILED=$((FAILED + 1)); fi

# WHY: both dry-run children retain installed plugins physically.
u_fixture u7
out=$(HOME="$U_HOME" PATH="$U_BIN:$HBIN" HIMMEL_UNINSTALL_REPO_ROOT="$U_REPO" \
    TELEGRAM_CHANNEL_DIR="$CHANNEL" BRIDGE_ROOT="$BRIDGE" HIMMELCTL_CACHE_DIR="$U_CACHE" \
    bash "$CLI" --purge-state --dry-run --yes --skip-tasks --skip-hooks </dev/null 2>&1); rc=$?
if [ "$rc" -eq 0 ] && ! grep -qF '[7/8] Claude marketplaces:' <<< "$out" &&
    grep -qF 'DRY: claude plugin marketplace remove himmel' <<< "$out"; then
    echo 'ok - U7 healthy dry-run completes marketplace step'
else
    echo 'FAIL - U7: healthy dry-run reported a failed marketplace step'; FAILED=$((FAILED + 1))
fi

# WHY: installed scope must survive the split child processes.
u_fixture u8 project
jq -n --arg here "$PWD" '[{id:"handover@himmel",scope:"project",projectPath:$here}]' > "$STUB_PLUGINS_JSON"
out=$(HOME="$U_HOME" PATH="$U_BIN:$HBIN" HIMMEL_UNINSTALL_REPO_ROOT="$U_REPO" \
    TELEGRAM_CHANNEL_DIR="$CHANNEL" BRIDGE_ROOT="$BRIDGE" HIMMELCTL_CACHE_DIR="$U_CACHE" \
    bash "$CLI" --purge-state --yes --skip-tasks --skip-hooks </dev/null 2>&1); rc=$?
calls=$(cat "$CLAUDE_CALL_LOG")
# WHY: the ledger records the marketplace at project scope, so
# only that registration is removed; the install-profile scope (user) is not
# tried in ledger mode — a same-named user-scope registration is not himmel's.
if [ "$rc" -eq 0 ] && grep -qxF 'plugin marketplace remove himmel --scope project' <<< "$calls" &&
    ! grep -qxF 'plugin marketplace remove himmel --scope user' <<< "$calls"; then
    echo 'ok - U8 marketplace removal retains project scope across children'
else
    echo 'FAIL - U8: marketplace removal lost project scope between children'; FAILED=$((FAILED + 1))
fi


# U9 — a halt after project plugin removal must preserve scopes for a retry.
u_fixture u9 project
jq -n --arg here "$PWD" '[{id:"handover@himmel",scope:"project",projectPath:$here}]' > "$STUB_PLUGINS_JSON"
framework_hook_text > "$U_REPO/.git/hooks/commit-msg"
u_run
assert_rc 'U9 first run halts after removing project plugin' 2 "$rc"
assert_has 'U9 first failure is hooks' 'Halted at: [5/8]' "$out"
assert_has 'U9 first run removes plugin at project scope' 'plugin uninstall handover@himmel --scope project' "$calls"
if [ -f "$U_CACHE/uninstall-scope-map" ]; then
    echo 'PASS U9 halted run retains scope handoff'
else
    echo 'FAIL U9 halted run lost scope handoff'; FAILED=$((FAILED + 1))
fi
rm "$U_REPO/.git/hooks/commit-msg"
: > "$CLAUDE_CALL_LOG"
u_run
assert_rc 'U9 retry completes teardown' 0 "$rc"
assert_has 'U9 retry removes marketplace at preserved project scope' 'plugin marketplace remove himmel --scope project' "$calls"
# WHY: ledger mode never adds the install-profile scope (user).
assert_not_has 'U9 retry never tries install-profile user scope for himmel' 'plugin marketplace remove himmel --scope user' "$calls"
if [ ! -e "$U_CACHE" ]; then
    echo 'PASS U9 successful retry removes cache and handoff'
else
    echo 'FAIL U9 successful retry left cache or handoff'; FAILED=$((FAILED + 1))
fi

# U10 — an unused handoff cannot halt --skip-plugins when TMPDIR is unavailable.
u_fixture u10
TMPDIR="$TMP/missing-handoff-dir" u_run --skip-plugins
assert_rc 'U10 skip-plugins completes without a usable temporary directory' 0 "$rc"
assert_has 'U10 skip-plugins reports completion' 'Uninstall complete.' "$out"
if [ ! -e "$U_CACHE/uninstall-scope-map" ]; then
    echo 'PASS U10 skip-plugins creates no scope handoff'
else
    echo 'FAIL U10 skip-plugins created a scope handoff'; FAILED=$((FAILED + 1))
fi

# U11 — a completed retry must keep the first marketplace's real scope.
u_fixture u11
cat > "$U_REPO/docs/setup/settings-template.json" <<'JSON'
{
  "enabledPlugins": {"a@m1": true, "b@m2": true},
  "extraKnownMarketplaces": {
    "m1": {"source": {"source":"github", "repo":"example/m1"}},
    "m2": {"source": {"source":"github", "repo":"example/m2"}}
  }
}
JSON
jq -n --arg here "$PWD" '[{id:"a@m1",scope:"project",projectPath:$here}]' > "$STUB_PLUGINS_JSON"
printf '[{"name":"m1"},{"name":"m2"}]\n' > "$STUB_MARKETPLACES_JSON"
framework_hook_text > "$U_REPO/.git/hooks/commit-msg"
# S6: u_fixture's default seed only records handover@himmel/himmel
# as ledger-owned -- this test exercises a@m1/b@m2/m1/m2 instead, so those
# need their own ledger-owned rows or [4/8]/[7/8] treat them as untracked
# (kept, never call `claude plugin uninstall`/`marketplace remove` on them).
SEED_HOME="$U_HOME" seed_plugin_ledger "a@m1:project,b@m2" "m1:project,m2"
u_run
assert_rc 'U11 first run halts after project plugin removal' 2 "$rc"
assert_has 'U11 first failure is hooks' 'Halted at: [5/8]' "$out"
assert_has 'U11 first run removes m1 at project scope' 'plugin uninstall a@m1 --scope project' "$calls"
jq -n '[{id:"b@m2",scope:"user"}]' > "$STUB_PLUGINS_JSON"
rm "$U_REPO/.git/hooks/commit-msg"
: > "$CLAUDE_CALL_LOG"
u_run
assert_rc 'U11 retry completes teardown' 0 "$rc"
assert_has 'U11 retry removes m1 marketplace at project scope' 'plugin marketplace remove m1 --scope project' "$calls"
# WHY: ledger mode never adds the install-profile scope (user)
# for m1; the ledger recorded it at project only.
assert_not_has 'U11 retry never tries m1 at install-profile user scope' 'plugin marketplace remove m1 --scope user' "$calls"
assert_has 'U11 retry removes m2 marketplace at user scope' 'plugin marketplace remove m2 --scope user' "$calls"

# U12 — a symlinked cache gets an ephemeral handoff and leaves its target alone.
u_fixture u12
cat > "$U_REPO/docs/setup/settings-template.json" <<'JSON'
{
  "enabledPlugins": {"a@m1": true},
  "extraKnownMarketplaces": {
    "m1": {"source": {"source":"github", "repo":"example/m1"}}
  }
}
JSON
printf '[{"id":"a@m1","scope":"user"}]\n' > "$STUB_PLUGINS_JSON"
printf '[{"name":"m1"}]\n' > "$STUB_MARKETPLACES_JSON"
U12_TARGET="$TMP/u12-cache-target"
mkdir -p "$U12_TARGET"
printf 'preserve me\n' > "$U12_TARGET/pre-existing"
cp "$U12_TARGET/pre-existing" "$TMP/u12-target-before"
rm -rf "$U_CACHE"
ln -s "$U12_TARGET" "$U_CACHE"
u_run
assert_rc 'U12 symlinked cache completes teardown' 0 "$rc"
assert_has 'U12 reports ephemeral scope-map fallback' 'WARN: using ephemeral scope-map handoff' "$out"
if [ -z "$(find "$U12_TARGET" -name uninstall-scope-map -print -quit)" ]; then
    echo 'PASS U12 symlink target has no scope handoff'
else
    echo 'FAIL U12 symlink target received scope handoff'; FAILED=$((FAILED + 1))
fi
cmp -s "$TMP/u12-target-before" "$U12_TARGET/pre-existing"; u12_target_rc=$?
if [ "$u12_target_rc" -eq 0 ]; then
    echo 'PASS U12 symlink target content survives'
else
    echo 'FAIL U12 symlink target content changed'; FAILED=$((FAILED + 1))
fi

# U13 — an unresolved worktree hook location must halt before cache removal.
u_fixture u13
# The preceding rows already removed the fixture pre-commit stub.
mv "$U_REPO/.git" "$TMP/u13-hooks-dir"
printf 'gitdir: /unresolved/fixture\n' > "$U_REPO/.git"
u_run --skip-plugins
assert_rc 'U13 unresolved hooks halt' 2 "$rc"
assert_has 'U13 names unresolved hooks' 'cannot determine whether this repo carries framework hooks' "$out"
assert_has 'U13 halts at hooks step' 'Halted at: [5/8]' "$out"
if [ -d "$U_CACHE" ]; then
    echo 'PASS U13 cache survives unresolved hooks'
else
    echo 'FAIL U13 cache removed despite unresolved hooks'; FAILED=$((FAILED + 1))
fi
rm "$U_REPO/.git"
mv "$TMP/u13-hooks-dir" "$U_REPO/.git"

# U14 — WHY: a regular cache file is removable residue.
u_fixture u14
printf '[{"id":"a@m1","scope":"user"}]\n' > "$STUB_PLUGINS_JSON"
printf '[{"name":"m1"}]\n' > "$STUB_MARKETPLACES_JSON"
rm -rf "$U_CACHE"
printf 'cache residue\n' > "$U_CACHE"
u_run
assert_rc 'U14 regular cache file completes teardown' 0 "$rc"
assert_has 'U14 reports ephemeral scope-map fallback' 'WARN: using ephemeral scope-map handoff' "$out"
assert_not_has 'U14 does not halt at scope handoff' 'Halted at: [4/8]' "$out"
if [ ! -e "$U_CACHE" ]; then
    echo 'PASS U14 step 8 removes regular cache file'
else
    echo 'FAIL U14 regular cache file survived'; FAILED=$((FAILED + 1))
fi

# U15 — a dry retry must preview persisted scopes without changing the map.
u_fixture u15
cat > "$U_REPO/docs/setup/settings-template.json" <<'JSON'
{
  "enabledPlugins": {"a@m1": true, "b@m2": true},
  "extraKnownMarketplaces": {
    "m1": {"source": {"source":"github", "repo":"example/m1"}},
    "m2": {"source": {"source":"github", "repo":"example/m2"}}
  }
}
JSON
jq -n --arg here "$PWD" '[{id:"a@m1",scope:"project",projectPath:$here}]' > "$STUB_PLUGINS_JSON"
printf '[{"name":"m1"},{"name":"m2"}]\n' > "$STUB_MARKETPLACES_JSON"
framework_hook_text > "$U_REPO/.git/hooks/commit-msg"
# S6: same reseed as U11 -- this test exercises a@m1/b@m2/m1/m2,
# not u_fixture's default handover@himmel/himmel, so they need their own
# ledger-owned rows or [4/8]/[7/8] treat them as untracked (kept).
SEED_HOME="$U_HOME" seed_plugin_ledger "a@m1:project,b@m2" "m1:project,m2"
u_run
assert_rc 'U15 first run halts after project plugin removal' 2 "$rc"
assert_has 'U15 first failure is hooks' 'Halted at: [5/8]' "$out"
assert_has 'U15 first run removes m1 at project scope' 'plugin uninstall a@m1 --scope project' "$calls"
cp "$U_CACHE/uninstall-scope-map" "$TMP/u15-scope-map-before"
jq -n '[{id:"b@m2",scope:"user"}]' > "$STUB_PLUGINS_JSON"
rm "$U_REPO/.git/hooks/commit-msg"
: > "$CLAUDE_CALL_LOG"
u_run --dry-run
assert_rc 'U15 dry retry completes preview' 0 "$rc"
assert_has 'U15 dry retry previews m1 marketplace at project scope' 'DRY: claude plugin marketplace remove m1 --scope project' "$out"
# WHY: ledger mode never previews the install-profile scope (user)
# for m1; the ledger recorded it at project only.
assert_not_has 'U15 dry retry never previews m1 at install-profile user scope' 'DRY: claude plugin marketplace remove m1 --scope user' "$out"
if [ -f "$U_CACHE/uninstall-scope-map" ] && cmp -s "$TMP/u15-scope-map-before" "$U_CACHE/uninstall-scope-map"; then
    echo 'PASS U15 persisted scope map survives byte-identical'
else
    echo 'FAIL U15 persisted scope map missing or changed'; FAILED=$((FAILED + 1))
fi

# U16 — RED 12: a failed map read must warn about fallback scopes.
u_fixture u16
printf '[]\n' > "$STUB_PLUGINS_JSON"
printf '[{"name":"m1"}]\n' > "$STUB_MARKETPLACES_JSON"
# S6: u_fixture's default seed only records the himmel marketplace
# as ledger-owned -- this test exercises m1, so it needs its own ledger-owned
# row or [7/8] treats it as untracked (kept, never previews its removal).
SEED_HOME="$U_HOME" seed_plugin_ledger "" "m1"
printf 'm1\tproject\t%s\n' "$PWD" > "$U_CACHE/uninstall-scope-map"
U16_CAT=$(command -v cat)
mkdir -p "$TMP/u16-bin"
cat > "$TMP/u16-bin/cat" <<'STUB'
#!/usr/bin/env bash
if [ "$#" -eq 1 ] && [ "$1" = "$HIMMELCTL_CACHE_DIR/uninstall-scope-map" ]; then
    printf 'm1\tproject\t%s\n' "$PWD"
    exit 1
fi
exec "$U16_CAT" "$@"
STUB
chmod +x "$TMP/u16-bin/cat"
out=$(HOME="$U_HOME" PATH="$TMP/u16-bin:$U_BIN:$HBIN" U16_CAT="$U16_CAT" \
    HIMMEL_UNINSTALL_REPO_ROOT="$U_REPO" TELEGRAM_CHANNEL_DIR="$CHANNEL" \
    BRIDGE_ROOT="$BRIDGE" HIMMELCTL_CACHE_DIR="$U_CACHE" \
    bash "$CLI" --purge-state --yes --dry-run --skip-tasks --skip-hooks --skip-settings </dev/null 2>&1); rc=$?
assert_rc 'RED 12: failed preview map read keeps exit 0' 0 "$rc"
assert_has 'RED 12: failed preview map read warns with map path' \
    "WARN: could not read $U_CACHE/uninstall-scope-map" "$out"
assert_has 'RED 12: warning explains fallback scope' \
    'preview will show marketplace removals at the fallback scope rather than the recorded scopes' "$out"
assert_has 'RED 12: partial read is truncated before fallback preview' \
    'DRY: claude plugin marketplace remove m1 --scope user' "$out"
assert_not_has 'RED 12: partial read never previews recorded scope' \
    'DRY: claude plugin marketplace remove m1 --scope project' "$out"


# ── U17+: install-written residue is manifested, classified, shown
# in --dry-run and removed (code) or named as kept (keep). The fixtures are made
# by the REAL installers (wire_user_claude_md + the hud config template), so the
# tests remove what install actually writes.
U17_SCRIPTS="$(cd "$(dirname "$CLI")" && pwd)"
U17_TEMPLATE="$U17_SCRIPTS/../docs/setup/user-scope-claude-md-template.md"
U17_HUD_TEMPLATE="$U17_SCRIPTS/../marketplace/plugins/claude-hud/config/himmel-config.json"
# shellcheck source=lib/user-claude-md.sh
. "$U17_SCRIPTS/lib/user-claude-md.sh"
U17_BEGIN='<!-- BEGIN HIMMEL:working-principles -->'
# u_residue_fixture <name> — the operator's CLAUDE.md gets the block appended to
# their own text; ~/.codex/AGENTS.md is created by install (block only); the hud
# config is the rendered template; trust + adopter scripts are seeded as installed.
u_residue_fixture() {
    u_fixture "$1"
    mkdir -p "$U_HOME/.claude/plugins/claude-hud" "$U_HOME/.codex"
    printf 'my own rules\n' > "$U_HOME/.claude/CLAUDE.md"
    printf 'my own rules\n' > "$TMP/u-$1-claude-md-before"
    wire_user_claude_md "$U17_TEMPLATE" "$U_HOME/.claude/CLAUDE.md" >/dev/null
    wire_user_claude_md "$U17_TEMPLATE" "$U_HOME/.codex/AGENTS.md" >/dev/null
    sed 's#<himmel-path>#/fixture/himmel#g' "$U17_HUD_TEMPLATE" > "$U_HOME/.claude/claude-hud.json"
    printf '{"projects":{"/x":{"hasTrustDialogAccepted":true}}}\n' > "$U_HOME/.claude.json"
    cp "$U_HOME/.claude.json" "$TMP/u-$1-trust-before"
}
u_same() {   # <label> <fileA> <fileB> — byte-identical
    if cmp -s "$2" "$3"; then echo "PASS $1"; else echo "FAIL $1 — $2 differs from $3"; FAILED=$((FAILED + 1)); fi
}
u_absent() {   # <label> <path>
    if [ ! -e "$2" ] && [ ! -L "$2" ]; then echo "PASS $1"; else echo "FAIL $1 — still present: $2"; FAILED=$((FAILED + 1)); fi
}

# The fixtures put ~/.claude.json and ~/.codex under the fixture $HOME, which the
# wet-run fence reads as a live operator profile. The $HOME is a
# temp dir, so lift the fence the way case 23b does — for these calls only.
u_run_fx() { export HIMMEL_UNINSTALL_REAL_HOME=1; u_run "$@"; unset HIMMEL_UNINSTALL_REAL_HOME; }

# U17 — --dry-run names every residue artifact in the footprint and step 6, and
# changes nothing.
u_residue_fixture u17
cp "$U_HOME/.claude/CLAUDE.md" "$TMP/u17-claude-md-full"
cp "$U_HOME/.codex/AGENTS.md" "$TMP/u17-agents-md-full"
cp "$U_HOME/.claude/claude-hud.json" "$TMP/u17-hud-full"
u_run --dry-run
assert_rc 'U17 dry-run completes' 0 "$rc"
assert_has 'U17 footprint lists ~/.claude/CLAUDE.md block' "$U_HOME/.claude/CLAUDE.md — " "$out"
assert_has 'U17 footprint lists ~/.codex/AGENTS.md block' "$U_HOME/.codex/AGENTS.md — " "$out"
assert_has 'U17 footprint lists the hud config' "$U_HOME/.claude/claude-hud.json — " "$out"
assert_has 'U17 footprint lists the trust entry' "$U_HOME/.claude.json — " "$out"
assert_has 'U17 footprint names the adopter scripts/ as NEVER' "scripts — himmel scripts copied into" "$out"
assert_has 'U17 dry-run previews the CLAUDE.md strip' "DRY: would strip himmel working-principles block from $U_HOME/.claude/CLAUDE.md" "$out"
assert_has 'U17 dry-run previews the AGENTS.md strip' "DRY: would strip himmel working-principles block from $U_HOME/.codex/AGENTS.md" "$out"
# U_fixture's ledger only records the plugin/
# marketplace units (seed_plugin_ledger) -- it never records a `file` unit for
# this hud-config path, so a loaded-but-silent ledger keeps it with a hand
# command, the same as the no-ledger branch, instead of the round-1
# pattern-matched strip this case used to hit.
assert_has 'U17 dry-run shows the hud config kept (not in ledger)' "kept (not in ledger): $U_HOME/.claude/claude-hud.json — remove by hand: bash $U17_SCRIPTS/lib/unwire-hud-config.sh $U_HOME/.claude/claude-hud.json" "$out"
# S6 slice2: workspace-trust is ledger-decided too now; u_fixture's
# ledger never records a unit for it, so it lands in the same "not in ledger"
# fallback as the hud config above.
assert_has 'U17 dry-run shows the trust entry kept (not in ledger)' "kept (not in ledger): $U_HOME/.claude.json — revoke it in Claude Code if you want it gone" "$out"
u_same 'U17 dry-run left CLAUDE.md alone' "$U_HOME/.claude/CLAUDE.md" "$TMP/u17-claude-md-full"
u_same 'U17 dry-run left AGENTS.md alone' "$U_HOME/.codex/AGENTS.md" "$TMP/u17-agents-md-full"
u_same 'U17 dry-run left the hud config alone' "$U_HOME/.claude/claude-hud.json" "$TMP/u17-hud-full"
u_same 'U17 dry-run left the trust entry alone' "$U_HOME/.claude.json" "$TMP/u-u17-trust-before"

# U18 — wet run: the block goes and the operator's own text is byte-identical;
# an install-created file that held only the block is removed; the hud config,
# lacking a ledger unit, is kept with a hand command;
# the keep rows stay and the footer names them.
u_residue_fixture u18
cp "$U_HOME/.claude/claude-hud.json" "$TMP/u-u18-hud-before"
u_run_fx
assert_rc 'U18 wet run completes' 0 "$rc"
u_same 'U18 CLAUDE.md is the operator text again, byte-identical' "$U_HOME/.claude/CLAUDE.md" "$TMP/u-u18-claude-md-before"
u_absent 'U18 install-created AGENTS.md removed' "$U_HOME/.codex/AGENTS.md"
u_same 'U18 hud config kept (not in ledger), byte-identical' "$U_HOME/.claude/claude-hud.json" "$TMP/u-u18-hud-before"
assert_has 'U18 footer names the hud config kept (not in ledger)' "kept (not in ledger): $U_HOME/.claude/claude-hud.json" "$out"
u_same 'U18 workspace-trust entry untouched (not in ledger)' "$U_HOME/.claude.json" "$TMP/u-u18-trust-before"
assert_has 'U18 footer names the trust entry kept (not in ledger)' "kept (not in ledger): $U_HOME/.claude.json — revoke it in Claude Code if you want it gone" "$out"
assert_has 'U18 footer names the adopter scripts as not touched' "scripts — himmel scripts copied into" "$out"
case "$(cat "$U_HOME/.claude/CLAUDE.md")" in
    *HIMMEL:working-principles*) echo 'FAIL U18 marker still in CLAUDE.md'; FAILED=$((FAILED + 1)) ;;
    *) echo 'PASS U18 no marker left in CLAUDE.md' ;;
esac

# U19 — operator text on BOTH sides of the block survives byte-identical.
u_residue_fixture u19
printf 'top\n' > "$U_HOME/.claude/CLAUDE.md"
wire_user_claude_md "$U17_TEMPLATE" "$U_HOME/.claude/CLAUDE.md" >/dev/null
printf 'bottom\n' >> "$U_HOME/.claude/CLAUDE.md"
printf 'top\nbottom\n' > "$TMP/u19-expect"
u_run_fx
assert_rc 'U19 wet run completes' 0 "$rc"
u_same 'U19 text above and below the block is untouched' "$U_HOME/.claude/CLAUDE.md" "$TMP/u19-expect"

# U20 — an ambiguous file (two BEGIN markers, no install record) is refused,
# never guessed at: byte-identical, named, kept (block-malformed), rc 0 (S2d
# Q6: units that are kept and reported do not halt the run, so the files after
# it are still processed). A file with no block at all is a clean no-op.
u_residue_fixture u20
{ cat "$U_HOME/.claude/CLAUDE.md"; printf '%s\n' "$U17_BEGIN"; } > "$TMP/u20-doubled"
cp "$TMP/u20-doubled" "$U_HOME/.claude/CLAUDE.md"
cp "$U_HOME/.codex/AGENTS.md" "$TMP/u20-agents"
cp "$U_HOME/.claude/claude-hud.json" "$TMP/u20-hud"
u_run_fx
assert_rc 'U20 doubled marker is kept, run completes' 0 "$rc"
u_same 'U20 doubled-marker file left byte-identical' "$U_HOME/.claude/CLAUDE.md" "$TMP/u20-doubled"
assert_has 'U20 refusal names the file' "$U_HOME/.claude/CLAUDE.md" "$out"
assert_has 'U20 refusal says block-malformed' 'kept (block-malformed)' "$out"
# the kept file does not halt the step: the wired AGENTS.md after it is still stripped
u_absent 'U20 AGENTS.md after it is still stripped' "$U_HOME/.codex/AGENTS.md"
u_residue_fixture u20b
printf 'notes mention HIMMEL:working-principles in prose only\n' > "$U_HOME/.claude/CLAUDE.md"
cp "$U_HOME/.claude/CLAUDE.md" "$TMP/u20b-prose"
u_run_fx
assert_rc 'U20b file with no block completes' 0 "$rc"
u_same 'U20b no-block file untouched' "$U_HOME/.claude/CLAUDE.md" "$TMP/u20b-prose"

# U21 — the hud config is kept, with a hand command,
# whenever the ledger has no unit for it -- content pattern-matching alone
# (an operator's own vs. himmel's own customLineCommand) is no longer trusted
# to authorise a strip without ledger evidence, so all three variants below
# (operator's own, a mention-only command, and himmel's own ECON-prefixed
# command) are kept identically.
u_residue_fixture u21
printf '{"display":{"customLineCommand":"echo mine"}}\n' > "$U_HOME/.claude/claude-hud.json"
cp "$U_HOME/.claude/claude-hud.json" "$TMP/u21-hud"
u_run_fx
assert_rc 'U21 wet run completes' 0 "$rc"
u_same 'U21 operator hud config kept byte-identical' "$U_HOME/.claude/claude-hud.json" "$TMP/u21-hud"
assert_has 'U21 kept hud config is explained' "kept (not in ledger)" "$out"
# A command that merely MENTIONS himmel's script is kept the same way.
u_residue_fixture u21b
printf '{"display":{"customLineCommand":"echo scripts/statusline/hud-custom-lines.sh"}}\n' > "$U_HOME/.claude/claude-hud.json"
cp "$U_HOME/.claude/claude-hud.json" "$TMP/u21b-hud"
u_run_fx
assert_rc 'U21b wet run completes' 0 "$rc"
u_same 'U21b mention-only hud config kept byte-identical' "$U_HOME/.claude/claude-hud.json" "$TMP/u21b-hud"
# ...and so is himmel's own command behind an older install's env prefix, absent a ledger
# unit for it: no more content-based removal without ledger evidence.
u_residue_fixture u21c
printf '{"display":{"customLineCommand":"HIMMEL_RETIRED_KNOB=off bash \\"/x/scripts/statusline/hud-custom-lines.sh\\""}}\n' > "$U_HOME/.claude/claude-hud.json"
cp "$U_HOME/.claude/claude-hud.json" "$TMP/u21c-hud"
u_run_fx
assert_rc 'U21c wet run completes' 0 "$rc"
u_same 'U21c env-prefixed himmel hud config kept (not in ledger), byte-identical' "$U_HOME/.claude/claude-hud.json" "$TMP/u21c-hud"

# U21d — a leftover config at the
# OLD, swept plugin-manager path with NO ledger unit recorded for it is kept,
# not removed: the same customLineCommand shape check that used to authorise
# an unconditional rm can't tell "himmel wrote this" from "an operator's own
# config happens to match the template", so ledger evidence is now required
# before this path is ever touched, exactly like the NEW-path policy above.
u_residue_fixture u21d
printf '{"display":{"customLineCommand":"HIMMEL_RETIRED_KNOB=off bash \\"/x/scripts/statusline/hud-custom-lines.sh\\""}}\n' > "$U_HOME/.claude/plugins/claude-hud/config.json"
cp "$U_HOME/.claude/plugins/claude-hud/config.json" "$TMP/u21d-legacy"
cp "$U_HOME/.claude/claude-hud.json" "$TMP/u21d-hud"
u_run_fx
assert_rc 'U21d wet run completes' 0 "$rc"
u_same 'U21d legacy swept-path hud config kept (no ledger unit), byte-identical' "$U_HOME/.claude/plugins/claude-hud/config.json" "$TMP/u21d-legacy"
assert_has 'U21d output names the kept legacy hud config' "kept (no ledger unit): $U_HOME/.claude/plugins/claude-hud/config.json" "$out"
u_same 'U21d new-path hud config still kept (not in ledger), byte-identical' "$U_HOME/.claude/claude-hud.json" "$TMP/u21d-hud"
# A legacy file that is NOT himmel's own (an operator's own customLineCommand) is
# left alone, same as unwire-hud-config.sh's existing safety check.
u_residue_fixture u21e
printf '{"display":{"customLineCommand":"echo mine"}}\n' > "$U_HOME/.claude/plugins/claude-hud/config.json"
cp "$U_HOME/.claude/plugins/claude-hud/config.json" "$TMP/u21e-legacy"
u_run_fx
assert_rc 'U21e wet run completes' 0 "$rc"
u_same 'U21e operator legacy hud config left alone' "$U_HOME/.claude/plugins/claude-hud/config.json" "$TMP/u21e-legacy"

# U21f — a box upgraded but not yet re-wired: the
# statusLine is still wired to the hud renderer, the ledger has no unit for it
# (so unwire_settings keeps it, "no ledger"), and the legacy-path hud config is
# what that still-live statusLine actually reads. Deleting the legacy config
# here would break a HUD uninstall just reported as left working, so it must
# be kept too -- unlike U21d, where no statusLine is wired at all.
u_residue_fixture u21f
printf '{"statusLine":{"type":"command","command":"bash \\"%s/scripts/statusline/bin/statusline.sh\\""}}\n' "$U17_SCRIPTS/.." > "$HIMMEL_USER_SETTINGS"
printf '{"display":{"customLineCommand":"HIMMEL_RETIRED_KNOB=off bash \\"/x/scripts/statusline/hud-custom-lines.sh\\""}}\n' > "$U_HOME/.claude/plugins/claude-hud/config.json"
cp "$U_HOME/.claude/plugins/claude-hud/config.json" "$TMP/u21f-legacy"
u_run_fx
assert_rc 'U21f wet run completes' 0 "$rc"
u_same 'U21f legacy hud config kept (statusLine still wired), byte-identical' "$U_HOME/.claude/plugins/claude-hud/config.json" "$TMP/u21f-legacy"
assert_has 'U21f output names the kept legacy hud config' "kept (statusLine still wired): $U_HOME/.claude/plugins/claude-hud/config.json — remove by hand: bash $U17_SCRIPTS/lib/unwire-hud-config.sh $U_HOME/.claude/plugins/claude-hud/config.json" "$out"

# U21g — the ledger
# OWNS /statusLine (a real "remove" verdict, same registration shape as RED18
# in test-uninstall-provenance.sh: noop json-key, no preexisted field ->
# defaults false -> removed), and a legacy-path hud config is still present,
# but with NO ledger unit recorded for the legacy path itself. Since
# unwire_settings would remove the ledger-owned statusLine, the "still wired"
# kept-branch must not fire either -- but with no ledger evidence for the
# legacy config path, it now previews as kept (no ledger unit), not removed;
# a DRY-RUN preview must match what the WET run would actually do.
u_residue_fixture u21g
printf '{"statusLine":{"type":"command","command":"bash \\"%s/scripts/statusline/bin/statusline.sh\\""}}\n' "$U17_SCRIPTS/.." > "$HIMMEL_USER_SETTINGS"
printf '{"display":{"customLineCommand":"HIMMEL_RETIRED_KNOB=off bash \\"/x/scripts/statusline/hud-custom-lines.sh\\""}}\n' > "$U_HOME/.claude/plugins/claude-hud/config.json"
cp "$U_HOME/.claude/plugins/claude-hud/config.json" "$TMP/u21g-legacy"
(
    # shellcheck disable=SC2030,SC2031 # confined to this subshell, same as
    # seed_plugin_ledger above; never leaks to the parent script.
    export HOME="$U_HOME"
    unset HIMMEL_PROVENANCE_DIR CLAUDE_CONFIG_DIR
    prov_begin --writer install.sh -- seed-u21g >/dev/null
    prov_record noop json-key "$HIMMEL_USER_SETTINGS" --unit /statusLine --scope user --class code --row user-settings \
        --writer wire-statusline.sh --pre-json "$(jq -c .statusLine "$HIMMEL_USER_SETTINGS")" \
        --post-json "$(jq -c .statusLine "$HIMMEL_USER_SETTINGS")" >/dev/null
    prov_end ok >/dev/null
)
u_run --dry-run
assert_rc 'U21g dry-run completes' 0 "$rc"
assert_has 'U21g dry-run previews the legacy hud config as kept (no ledger unit), matching the wet-run verdict' "kept (no ledger unit): $U_HOME/.claude/plugins/claude-hud/config.json" "$out"
assert_not_has 'U21g dry-run does NOT show the legacy config as kept (statusLine still wired)' "kept (statusLine still wired): $U_HOME/.claude/plugins/claude-hud/config.json" "$out"
u_same 'U21g dry-run left the legacy hud config alone (preview only)' "$U_HOME/.claude/plugins/claude-hud/config.json" "$TMP/u21g-legacy"

# U22 — dry and wet print the SAME number of user-settings unwire rows: one per
# helper (statusLine, HIMMEL_REPO, LUNA_VAULT_PATH, HANDOVER_DIR, hooks, session end hook).
u_residue_fixture u22
u_run --dry-run
u22_dry=$(printf '%s\n' "$out" | grep -c "^DRY: .* from $HIMMEL_USER_SETTINGS\$")
u_residue_fixture u22w
u_run_fx
u22_wet=$(printf '%s\n' "$out" | grep -c -- "-> $HIMMEL_USER_SETTINGS\$")
assert_rc 'U22 wet run prints 6 user-settings unwire rows' 6 "$u22_wet"
assert_rc 'U22 dry-run prints the same 6 rows' 6 "$u22_dry"

# U23 — --skip-settings leaves the rule-file blocks and hud config alone (step 6).
u_residue_fixture u23
cp "$U_HOME/.claude/CLAUDE.md" "$TMP/u23-claude-md-full"
u_run_fx --skip-settings
assert_rc 'U23 --skip-settings completes' 0 "$rc"
u_same 'U23 --skip-settings keeps CLAUDE.md' "$U_HOME/.claude/CLAUDE.md" "$TMP/u23-claude-md-full"
if [ -f "$U_HOME/.claude/claude-hud.json" ]; then echo 'PASS U23 --skip-settings keeps the hud config'
else echo 'FAIL U23 hud config removed under --skip-settings'; FAILED=$((FAILED + 1)); fi

# U24 — a failed write-through never destroys the only copy of the operator's
# text: the stripped content is kept in a temp file the error names.
# chmod 444 stops nobody who is root (a privileged CI or VM run): probe first and
# skip loudly rather than fail a case whose premise cannot be built there.
: > "$TMP/u24-probe"; chmod 444 "$TMP/u24-probe"
if [ -w "$TMP/u24-probe" ]; then
  echo 'SKIP U24 a chmod 444 file is still writable here (running as root) -- unwritable-target case not exercised'
else
  mkdir -p "$TMP/u24tmp"
  printf 'mine\n' > "$TMP/u24-rules"
  wire_user_claude_md "$U17_TEMPLATE" "$TMP/u24-rules" >/dev/null
  cp "$TMP/u24-rules" "$TMP/u24-before"
  chmod 444 "$TMP/u24-rules"
  rc=0; out="$(TMPDIR="$TMP/u24tmp" bash "$U17_SCRIPTS/lib/unwire-user-claude-md.sh" "$TMP/u24-rules" 2>&1)" || rc=$?
  chmod 644 "$TMP/u24-rules"
  assert_rc 'U24 unwritable target fails' 1 "$rc"
  u_same 'U24 unwritable target left byte-identical' "$TMP/u24-rules" "$TMP/u24-before"
  u24_kept="$(find "$TMP/u24tmp" -name 'unwire-ucm.*' | head -n 1)"
  if [ -n "$u24_kept" ] && [ "$(cat "$u24_kept")" = "mine" ]; then echo 'PASS U24 stripped content kept in the temp file'
  else echo 'FAIL U24 no recoverable temp file with the operator text'; FAILED=$((FAILED + 1)); fi
  assert_has 'U24 error names the preserved temp file' "unwire-ucm." "$out"
fi

# U26 — an unreadable rule file is a failure, never "no block": grep's read error
# (rc 2) used to be swallowed by `|| true` and read as zero markers. Skipped as
# root, for whom chmod 000 stops nothing.
printf 'mine\n' > "$TMP/u26-rules"
wire_user_claude_md "$U17_TEMPLATE" "$TMP/u26-rules" >/dev/null
cp "$TMP/u26-rules" "$TMP/u26-before"
chmod 000 "$TMP/u26-rules"
if [ -r "$TMP/u26-rules" ]; then
  echo 'SKIP U26 a chmod 000 file is still readable here (running as root) -- unreadable-target case not exercised'
else
  for u26_dry in 1 0; do
    rc=0; out="$(bash "$U17_SCRIPTS/lib/unwire-user-claude-md.sh" "$TMP/u26-rules" "$u26_dry" 2>&1)" || rc=$?
    assert_rc "U26 unreadable target fails (dry_run=$u26_dry)" 1 "$rc"
    assert_has "U26 error says it cannot read the file (dry_run=$u26_dry)" "cannot read" "$out"
  done
  chmod 644 "$TMP/u26-rules"
  u_same 'U26 unreadable target left byte-identical' "$TMP/u26-rules" "$TMP/u26-before"
fi
chmod 644 "$TMP/u26-rules"

# U25 — the temp-file build checks BOTH halves: a failing `head` with a
# succeeding `tail` (no text after END) must not read as a good result and
# delete the target as "empty".
mkdir -p "$TMP/u25-bin"
# Fails only the temp-file build (head -n <start-1>); the `head -n 1` marker-line
# lookups still work, so the run reaches the write it is meant to poison.
# shellcheck disable=SC2016 # the stub's own $2/$@ must stay literal
printf '#!/bin/sh\n[ "$2" = 1 ] && exec %s "$@"\nexit 1\n' "$(command -v head)" > "$TMP/u25-bin/head"
chmod +x "$TMP/u25-bin/head"
printf 'one\ntwo\n' > "$TMP/u25-rules"
wire_user_claude_md "$U17_TEMPLATE" "$TMP/u25-rules" >/dev/null
cp "$TMP/u25-rules" "$TMP/u25-before"
rc=0; PATH="$TMP/u25-bin:$PATH" bash "$U17_SCRIPTS/lib/unwire-user-claude-md.sh" "$TMP/u25-rules" >/dev/null 2>&1 || rc=$?
assert_rc 'U25 failed head halts the strip' 1 "$rc"
u_same 'U25 target left byte-identical when head fails' "$TMP/u25-rules" "$TMP/u25-before"

# U27 — a CLAUDE.md that merely QUOTES the block inside a code
# fence is a file about himmel, not a wired one: the strip leaves it
# byte-identical and the read-back (the helper's own --probe) agrees, so the run
# completes instead of halting on a false STILL WIRED.
u_residue_fixture u27
# shellcheck disable=SC2016 # the fence and $U17_BEGIN are literal fixture text
printf '# my notes\n\nhimmel appends this:\n\n```\n%s\n## Working principles\n<!-- END HIMMEL:working-principles -->\n```\n\nmine.\n' "$U17_BEGIN" > "$U_HOME/.claude/CLAUDE.md"
cp "$U_HOME/.claude/CLAUDE.md" "$TMP/u27-fenced"
u_run_fx
assert_rc 'U27 quoted-block file completes' 0 "$rc"
u_same 'U27 quoted-block file left byte-identical' "$U_HOME/.claude/CLAUDE.md" "$TMP/u27-fenced"
assert_not_has 'U27 no false STILL WIRED on a quoted block' 'STILL WIRED' "$out"
u_absent 'U27 the wired AGENTS.md after it is still stripped' "$U_HOME/.codex/AGENTS.md"

# U28 — CRLF markers (an editor converted the file) are refused,
# not read as "no block": the file is kept byte-identical and reported
# (block-malformed, with the scanner's CRLF reason), the run exits 0, and the
# next file is still processed.
u_residue_fixture u28
# Portable CRLF conversion: `sed 's/$/\r/'` is GNU-only (BSD/macOS sed writes a
# literal r, leaving no CRLF and a fixture that asserts nothing). Each line gets
# CR+LF; an unterminated last line, if any, gets a CR and stays unterminated.
: > "$TMP/u28-crlf"
while IFS= read -r u28_line; do printf '%s\r\n' "$u28_line" >> "$TMP/u28-crlf"; done < "$U_HOME/.claude/CLAUDE.md"
[ -n "$u28_line" ] && printf '%s\r' "$u28_line" >> "$TMP/u28-crlf"
grep -q "$(printf '\r')" "$TMP/u28-crlf" || { echo "U28 fixture carries no CR — the CRLF conversion did not happen"; FAILED=$((FAILED + 1)); }
cp "$TMP/u28-crlf" "$U_HOME/.claude/CLAUDE.md"
cp "$U_HOME/.codex/AGENTS.md" "$TMP/u28-agents"
u_run_fx
assert_rc 'U28 CRLF markers are kept, run completes' 0 "$rc"
u_same 'U28 CRLF file left byte-identical' "$U_HOME/.claude/CLAUDE.md" "$TMP/u28-crlf"
assert_has 'U28 refusal says CRLF' 'CRLF' "$out"
u_absent 'U28 AGENTS.md after it is still stripped' "$U_HOME/.codex/AGENTS.md"

# U29 — the edit path keeps a copy of the file as found beside it;
# the install-created AGENTS.md (nothing of the operator's) leaves no backup.
u_residue_fixture u29
u_run_fx
assert_rc 'U29 wet run completes' 0 "$rc"
u_same 'U29 backup of CLAUDE.md is the file as found' "$U_HOME/.claude/CLAUDE.md.himmel-uninstall-backup" "$TMP/u17-claude-md-full"
u_absent 'U29 no backup for the install-created AGENTS.md' "$U_HOME/.codex/AGENTS.md.himmel-uninstall-backup"
assert_has 'U29 output names the backup' "$U_HOME/.claude/CLAUDE.md.himmel-uninstall-backup" "$out"

# this suite must not leave a .git in /tmp or $TMPDIR.
for _p in /tmp/.git "${TMPDIR:-/tmp}/.git"; do
    case " $GIT_LEAK_PRE " in *" $_p "*) continue ;; esac
    [ -e "$_p" ] && fail "suite created $_p"
done

echo ""
if [ "$FAILED" -eq 0 ]; then
    echo "ALL PASS"
    exit 0
else
    echo "$FAILED FAILURE(S)"
    exit 1
fi
