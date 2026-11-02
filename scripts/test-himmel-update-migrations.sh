#!/usr/bin/env bash
# Read-only migration advisories against real engines and isolated install state.
# --real-clip <path> or --real-vault <path> replays private station samples.
# shellcheck disable=SC2154 # Shared fixture initializes the assertion counters.
set -uo pipefail

SCRIPT="$(cd "$(dirname "$0")" && pwd)/himmel-update.sh"
SOURCE_ROOT="$(cd "$(dirname "$SCRIPT")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/himmel-update-migrations.XXXXXX")" || exit 1
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home" CLAUDE_CONFIG_DIR="$TMP/claude" HERMES_HOME="$TMP/hermes"
export HIMMELCTL_CACHE_DIR="$TMP/cache" USERPROFILE=''
export CODEX_BIN="$TMP/not-installed" CLAUDE_BIN="$TMP/not-installed"
export HIMMEL_UPDATE_CLAUDE_BIN="$TMP/not-installed"
unset HIMMEL_UPDATE_CHANNEL
mkdir -p "$HOME" "$CLAUDE_CONFIG_DIR" "$HIMMELCTL_CACHE_DIR"
# shellcheck source=scripts/lib/himmel-update-fixtures.sh
. "$SOURCE_ROOT/scripts/lib/himmel-update-fixtures.sh"
make_repo_channel
ROOT="$CHECKOUT_DIR"
mkdir -p "$ROOT/marketplace/plugins/handover/scripts" "$ROOT/marketplace/plugins/obsidian-triage/tools/lib"
cp "$SOURCE_ROOT/scripts/lib/handover-path.sh" "$ROOT/scripts/lib/"
cp "$SOURCE_ROOT/scripts/lib/timeout-bin.sh" "$ROOT/scripts/lib/"
mkdir -p "$ROOT/scripts/handover"
cp "$SOURCE_ROOT/scripts/lib/git-clean.sh" "$SOURCE_ROOT/scripts/lib/rename-aliases.tsv" "$ROOT/scripts/lib/"
cp "$SOURCE_ROOT/scripts/handover/move-renamed-dirs.sh" "$ROOT/scripts/handover/"
mkdir -p "$ROOT/scripts/setup" "$HOME/.claude"
cp "$SOURCE_ROOT/scripts/setup/migrate-renamed-names.py" "$ROOT/scripts/setup/"
cp "$SOURCE_ROOT/marketplace/plugins/handover/scripts/migrate-v1-to-v2.sh" "$ROOT/marketplace/plugins/handover/scripts/"
cp "$SOURCE_ROOT/marketplace/plugins/obsidian-triage/tools/migrate-clip-lifecycle.mjs" "$ROOT/marketplace/plugins/obsidian-triage/tools/"
cp "$SOURCE_ROOT/marketplace/plugins/obsidian-triage/tools/lib/evidence-kind.mjs" "$ROOT/marketplace/plugins/obsidian-triage/tools/lib/"
printf 'marketplace/\n.env\n' >> "$ROOT/.git/info/exclude"
export HANDOVER_DIR="$TMP/state repo/handovers" LUNA_VAULT_PATH="$TMP/vault sample"
mkdir -p "$HANDOVER_DIR/tester/standalones/#7-legacy" "$LUNA_VAULT_PATH/Clippings"
printf '%s\n' '---' 'template_version: 1' 'jira: TEST-7' '---' > "$HANDOVER_DIR/tester/standalones/#7-legacy/brief.md"
printf '%s\n' '---' 'processed: true' '---' 'legacy clip' > "$LUNA_VAULT_PATH/Clippings/legacy.md"
printf '%s\n' 'run scripts/handover/console-kit/go.sh' > "$HANDOVER_DIR/tester/moved-dir.md"
printf '%s\n' 'open it with bash scripts/lanes/leg-pr-open.sh t b' > "$HANDOVER_DIR/tester/moved-path.md"
printf '%s\n' 'CONSOLE_CONTEXT=1m' > "$ROOT/.env" # old-term-ok
SETTINGS="$HOME/.claude/settings.json"
printf '%s\n' '{"hooks": {"PreToolUse": [{"hooks": [{"type": "command", "command": "bash scripts/hooks/guard-console-foreground.sh"}]}]}, "permissions": {"allow": ["Bash(bash scripts/cr/clear-cr-marker.sh:*)"]}}' > "$SETTINGS" # old-term-ok
case "${1:-}" in
    --real-clip) cp "$2" "$LUNA_VAULT_PATH/Clippings/legacy.md" ;;
    --real-vault) cp -R "$2/." "$LUNA_VAULT_PATH/" ;;
esac

snapshot() {
    python3 -I - "$HANDOVER_DIR" "$LUNA_VAULT_PATH" "$ROOT/.env" "$SETTINGS" <<'PY'
import hashlib, os, sys
for root in sys.argv[1:]:
    if os.path.isfile(root):
        with open(root, 'rb') as f:
            print(root, hashlib.sha256(f.read()).hexdigest())
        continue
    for base, dirs, files in os.walk(root):
        dirs.sort()
        print(os.path.relpath(base, root), 'directory')
        for name in sorted(files):
            p = os.path.join(base, name)
            with open(p, 'rb') as f:
                print(os.path.relpath(p, root), hashlib.sha256(f.read()).hexdigest())
PY
}
run_check() {
    rc=0
    out="$(bash "$ROOT/scripts/himmel-update.sh" --check 2>&1)" || rc=$?
}
assert_warning() {
    local kind="$1" install="$2" command="$3"
    local line
    line="$(grep -F "$kind migration needed" <<< "$out" || true)"
    if [ -n "$line" ] && grep -Fq "$install" <<< "$line" && grep -Fq "$command" <<< "$line"; then
        assert_pass "$kind: names install and exact preview command"
    else
        assert_fail "$kind: missing advisory with install and command (output: $out)"
    fi
}

assert_unchanged() {
    local after
    if after="$(snapshot)"; then
        assert_eq "$1" "$2" "$after"
    else
        assert_fail "$1: snapshot failed"
    fi
}

before="$(snapshot)" || exit 1
run_check
assert_eq 'check: exits successfully' 0 "$rc"
assert_warning handover "$HANDOVER_DIR" 'migrate-v1-to-v2.sh'
assert_warning clip-lifecycle "$LUNA_VAULT_PATH" 'migrate-clip-lifecycle.mjs'
assert_warning 'handover directory-rename' "$HANDOVER_DIR" 'move-renamed-dirs.sh --slice M'
assert_warning 'handover directory-rename' "$HANDOVER_DIR" 'move-renamed-dirs.sh --slice W'
assert_warning 'renamed-names' "$ROOT/.env" 'migrate-renamed-names.py --dry-run'
assert_warning 'renamed-names' "$SETTINGS" 'migrate-renamed-names.py --dry-run'
assert_unchanged 'check: fixture trees and files byte-identical' "$before"

# A retired script name whose forwarder is gone is renamed in the install's allow rules too.
migrator="$ROOT/scripts/setup/migrate-renamed-names.py"
preview="$(python3 -I "$migrator" --dry-run "$SETTINGS" 2>&1)"
if grep -Eq '^[+].*clear-review-marker[.]sh' <<< "$preview"; then
    assert_pass 'renamed-names: the preview adds the renamed allow rule for a retired script name'
else
    assert_fail "renamed-names: no renamed allow rule in the preview ($preview)"
fi
settings_copy="$TMP/settings-apply.json"
cp "$SETTINGS" "$settings_copy"
python3 -I "$migrator" --apply "$settings_copy" > /dev/null 2>&1
check_rc=0
python3 -I "$migrator" --check "$settings_copy" > /dev/null 2>&1 || check_rc=$?
if grep -Fq '"Bash(bash scripts/cr/clear-review-marker.sh:*)"' "$settings_copy" && [ "$check_rc" = 0 ]; then
    assert_pass 'renamed-names: --apply adds the renamed allow rule and a second --check finds nothing'
else
    assert_fail "renamed-names: --apply left the allow list unrenamed or still pending (check rc $check_rc)"
fi

# A retired script name matches only as a scripts/ path: another project's script sharing the bare name is left alone.
other_settings="$TMP/settings-other-project.json"
own_root="$(cd "$ROOT" && pwd -P)"
printf '{"hooks": {"PreToolUse": [{"hooks": [{"type": "command", "command": "/some/other/project/console.sh"}]}]}, "permissions": {"allow": ["Bash(/some/other/project/console.sh:*)", "Bash(/some/other/project/scripts/console.sh:*)", "Bash(/backup%s/scripts/console.sh:*)", "Bash(/backup+%s/scripts/console.sh:*)", "Bash(%s/scripts/../../other/scripts/console.sh:*)"]}}\n' "$own_root" "$own_root" "$own_root" > "$other_settings" # old-term-ok
other_before="$(cat "$other_settings")"
other_rc=0
python3 -I "$migrator" --apply "$other_settings" > /dev/null 2>&1 || other_rc=$?
if [ "$other_rc" = 0 ] && [ "$(cat "$other_settings")" = "$other_before" ] && [ ! -e "$other_settings.bak-renamed-names" ]; then
    assert_pass 'renamed-names: --apply leaves another project script sharing a retired bare name unchanged'
else
    assert_fail "renamed-names: --apply rewrote another project's script ($(cat "$other_settings"))"
fi
# The install's own absolute scripts/ path still migrates (negative control for the anchor above).
own_settings="$TMP/settings-own-root.json"
# shellcheck disable=SC2016 # the literal $HIMMEL_REPO belongs in the settings file
printf '{"permissions": {"allow": ["Bash(%s/scripts/console.sh:*)", "Bash($HIMMEL_REPO/scripts/console.sh:*)"]}}\n' "$own_root" > "$own_settings" # old-term-ok
own_rc=0
python3 -I "$migrator" --apply "$own_settings" > /dev/null 2>&1 || own_rc=$?
# shellcheck disable=SC2016 # matching the literal $HIMMEL_REPO
if [ "$own_rc" = 0 ] && grep -Fq "Bash($own_root/scripts/console.sh:*)" "$own_settings" && grep -Fq "Bash($own_root/scripts/chief.sh:*)" "$own_settings" \
    && grep -Fq 'Bash($HIMMEL_REPO/scripts/console.sh:*)' "$own_settings" && grep -Fq 'Bash($HIMMEL_REPO/scripts/chief.sh:*)' "$own_settings"; then # old-term-ok
    assert_pass 'renamed-names: --apply still renames a retired script under this install'"'"'s own scripts/ path'
else
    assert_fail "renamed-names: --apply left this install's own script unrenamed ($(cat "$own_settings"))"
fi

# The printed commands must actually target these installs, even with spaces.
if [ "$fail" -eq 0 ]; then
    while IFS= read -r line; do
        command="${line#*preview: }"
        rc=0
        preview="$(bash -c "$command" 2>&1)" || rc=$?
        assert_eq 'printed preview command: rc 0' 0 "$rc"
        if grep -Eq 'rename:|PLAN |^total: |^[+].*(CHIEF_CONTEXT|guard-chief-foreground)' <<< "$preview"; then
            assert_pass 'printed preview command: finds legacy data'
        else
            assert_fail "printed preview command: no plan ($preview)"
        fi
    done < <(grep -E '(handover|handover directory-rename|clip-lifecycle|renamed-names) migration needed' <<< "$out")
    assert_unchanged 'printed previews: fixture trees byte-identical' "$before"
fi

# Apply mode may update its mock checkout, but must never migrate user data.
rc=0
out="$(bash "$ROOT/scripts/himmel-update.sh" 2>&1)" || rc=$?
assert_eq 'apply: updater succeeds' 0 "$rc"
assert_warning handover "$HANDOVER_DIR" 'migrate-v1-to-v2.sh'
assert_warning clip-lifecycle "$LUNA_VAULT_PATH" 'migrate-clip-lifecycle.mjs'
assert_warning 'handover directory-rename' "$HANDOVER_DIR" 'move-renamed-dirs.sh --slice M'
assert_warning 'handover directory-rename' "$HANDOVER_DIR" 'move-renamed-dirs.sh --slice W'
assert_warning 'renamed-names' "$SETTINGS" 'migrate-renamed-names.py --dry-run'
assert_unchanged 'apply: fixture trees and files byte-identical' "$before"
printf '%s\n' "$out" | grep -E '(handover|clip-lifecycle) migration needed' || true

mv "$HANDOVER_DIR/tester/standalones/#7-legacy" "$HANDOVER_DIR/tester/standalones/TEST-7-legacy"
mkdir -p "$LUNA_VAULT_PATH/Clippings/_evidence"
printf '%s\n' 'run scripts/handover/chief-kit/go.sh' > "$HANDOVER_DIR/tester/moved-dir.md"
printf '%s\n' 'open it with bash scripts/lanes/worker-pr-open.sh t b' > "$HANDOVER_DIR/tester/moved-path.md"
printf '%s\n' 'CHIEF_CONTEXT=1m' > "$ROOT/.env"
printf '%s\n' '{"hooks": {"PreToolUse": [{"hooks": [{"type": "command", "command": "bash scripts/hooks/guard-chief-foreground.sh"}]}]}}' > "$SETTINGS"
mv "$LUNA_VAULT_PATH/Clippings/legacy.md" "$LUNA_VAULT_PATH/Clippings/_evidence/legacy.md"
mkdir -p "$LUNA_VAULT_PATH/Clippings/month/deep"
printf '%s\n' '---' 'processed: true' 'ig_media_pending: true' '---' > "$LUNA_VAULT_PATH/Clippings/pending.md"
printf '%s\n' '---' 'processed: true' '---' > "$LUNA_VAULT_PATH/Clippings/_deferred.md"
printf '%s\n' 'body only: processed: true' > "$LUNA_VAULT_PATH/Clippings/body.md"
printf '%s\n' '---' 'processed: true' '---' > "$LUNA_VAULT_PATH/Clippings/month/deep/nested.md"
run_check
assert_eq 'already migrated: updater succeeds' 0 "$rc"
if grep -q 'migration needed' <<< "$out"; then assert_fail 'already migrated: silent'; else assert_pass 'already migrated: silent'; fi

HANDOVER_DIR="$TMP/missing-state" LUNA_VAULT_PATH="$TMP/missing-vault" run_check
assert_eq 'unresolvable inputs: updater succeeds' 0 "$rc"
if grep -q 'migration needed' <<< "$out"; then assert_fail 'unresolvable inputs: silent'; else assert_pass 'unresolvable inputs: silent'; fi

rc=0
out="$(unset HANDOVER_DIR LUNA_VAULT_PATH; bash "$ROOT/scripts/himmel-update.sh" --check 2>&1)" || rc=$?
assert_eq 'unset inputs: updater succeeds' 0 "$rc"
if grep -q 'migration needed' <<< "$out"; then assert_fail 'unset inputs: silent'; else assert_pass 'unset inputs: silent'; fi

# Both engines failing must remain an advisory-only no-op, not an update failure.
printf '#!/usr/bin/env bash\nexit 2\n' > "$ROOT/marketplace/plugins/handover/scripts/migrate-v1-to-v2.sh"
printf 'process.exit(2);\n' > "$ROOT/marketplace/plugins/obsidian-triage/tools/migrate-clip-lifecycle.mjs"
run_check
assert_eq 'probe errors: updater succeeds' 0 "$rc"
if grep -q 'migration needed' <<< "$out"; then assert_fail 'probe errors: silent'; else assert_pass 'probe errors: silent'; fi

printf 'console.log("PLAN partial"); process.exit(2);\n' > "$ROOT/marketplace/plugins/obsidian-triage/tools/migrate-clip-lifecycle.mjs"
run_check
assert_eq 'partial probe errors: updater succeeds' 0 "$rc"
if grep -q 'migration needed' <<< "$out"; then assert_fail 'partial probe errors: silent'; else assert_pass 'partial probe errors: silent'; fi

# A wedged engine is killed within the per-migration budget (plus kill grace).
printf '#!/usr/bin/env bash\nexec sleep 30\n' > "$ROOT/marketplace/plugins/handover/scripts/migrate-v1-to-v2.sh"
printf 'setInterval(() => {}, 1000);\n' > "$ROOT/marketplace/plugins/obsidian-triage/tools/migrate-clip-lifecycle.mjs"
start=$SECONDS
run_check
elapsed=$((SECONDS - start))
assert_eq 'hung probes: updater succeeds' 0 "$rc"
if [ "$elapsed" -lt 12 ]; then assert_pass 'hung probes: bounded'; else assert_fail "hung probes: took ${elapsed}s"; fi
if grep -q 'migration needed' <<< "$out"; then assert_fail 'hung probes: silent'; else assert_pass 'hung probes: silent'; fi

# Without a GNU timer, never fall back to an unbounded scan.
printf '_TIMEOUT_BIN=""\n' > "$ROOT/scripts/lib/timeout-bin.sh"
start=$SECONDS
run_check
assert_eq 'timer unavailable: updater succeeds' 0 "$rc"
if [ "$((SECONDS - start))" -lt 3 ]; then assert_pass 'timer unavailable: skips probes'; else assert_fail 'timer unavailable: unbounded fallback'; fi

# A failure-review runner armed before the rename calls scripts/eval/leg-digest/, which is gone.
# check advises; apply re-arms at the same time and in the same mode. Scratch crontab and runner dir only.
mkdir -p "$ROOT/scripts/eval/worker-digest" "$ROOT/scripts/lib"
cp "$SOURCE_ROOT/scripts/eval/worker-digest/failure-review-cadence.sh" "$ROOT/scripts/eval/worker-digest/"
cp "$SOURCE_ROOT/scripts/lib/resolve-user-home.sh" "$ROOT/scripts/lib/"
export FAKECRON_FILE="$TMP/fakecron.txt" FAILREV_CRONTAB="$TMP/fakecron" FAILREV_RUNNER_DIR="$TMP/frrunner"
# shellcheck disable=SC2016 # the stub's own $1 and $FAKECRON_FILE stay literal
printf '%s\n' '#!/bin/sh' 'case "$1" in' '    -l) if [ -f "$FAKECRON_FILE" ]; then cat "$FAKECRON_FILE"; else echo "no crontab for t" >&2; exit 1; fi ;;' '    -) cat > "$FAKECRON_FILE" ;;' 'esac' > "$FAILREV_CRONTAB"
chmod +x "$FAILREV_CRONTAB"
RUNNER="$FAILREV_RUNNER_DIR/failure-review-cadence.sh"
CADENCE="$ROOT/scripts/eval/worker-digest/failure-review-cadence.sh"
# arm_old_layout <time> [--live]: arm with the real script, then point the runner back at the retired directory.
arm_old_layout() {
    JIRA_PROJECT_KEY=TESTPROJ bash "$CADENCE" arm --force --time "$1" --vault "$LUNA_VAULT_PATH" ${2:+"$2"} > /dev/null 2>&1
    sed -i.bak 's#/scripts/eval/worker-digest/#/scripts/eval/leg-digest/#' "$RUNNER" && rm -f "$RUNNER.bak" # old-term-ok
}
arm_old_layout 07:40 --live
runner_before="$(cat "$RUNNER")"; cron_before="$(cat "$FAKECRON_FILE")"
run_check
assert_eq 'cron runner: check exits successfully' 0 "$rc"
line="$(grep -F 'cron runner migration needed' <<< "$out" || true)"
if [ -n "$line" ] && grep -Fq '07:40' <<< "$line" && grep -Fq 'live' <<< "$line"; then
    assert_pass 'cron runner: check names the time and mode'
else
    assert_fail "cron runner: check advisory missing or wrong (output: $out)"
fi
if grep -Fq 'TESTPROJ' <<< "$out"; then assert_fail 'cron runner: check printed the project key'; else assert_pass 'cron runner: check prints no project key'; fi
assert_eq 'cron runner: check leaves the runner unchanged' "$runner_before" "$(cat "$RUNNER")"
assert_eq 'cron runner: check leaves the crontab unchanged' "$cron_before" "$(cat "$FAKECRON_FILE")"

rc=0
out="$(bash "$ROOT/scripts/himmel-update.sh" 2>&1)" || rc=$?
assert_eq 'cron runner: apply succeeds' 0 "$rc"
if grep -Fq 'TESTPROJ' <<< "$out"; then assert_fail 'cron runner: apply printed the project key'; else assert_pass 'cron runner: apply prints no project key'; fi
if grep -Fq "$ROOT/scripts/eval/worker-digest/failure-review-cadence.sh run --vault" "$RUNNER" && ! grep -Fq 'leg-digest' "$RUNNER"; then # old-term-ok
    assert_pass 'cron runner: apply points the runner at worker-digest'
else
    assert_fail "cron runner: runner still on the old path ($(grep -F 'run --vault' "$RUNNER"))"
fi
if grep -Fq ' --live' "$RUNNER" && grep -Fq 'JIRA_PROJECT_KEY=TESTPROJ' "$RUNNER"; then
    assert_pass 'cron runner: apply keeps live mode and its project key'
else
    assert_fail 'cron runner: apply dropped live mode or the key'
fi
if grep -Eq '^40 07 \* \* \* .* # HIMMEL-FailureReview$' "$FAKECRON_FILE"; then
    assert_pass 'cron runner: apply keeps the cron time 07:40'
else
    assert_fail "cron runner: cron time changed ($(cat "$FAKECRON_FILE"))"
fi
run_check
if grep -Fq 'cron runner migration needed' <<< "$out"; then assert_fail 'cron runner: re-armed runner is silent'; else assert_pass 'cron runner: re-armed runner is silent'; fi

arm_old_layout 03:20
rc=0
out="$(bash "$ROOT/scripts/himmel-update.sh" 2>&1)" || rc=$?
assert_eq 'cron runner: dry-run apply succeeds' 0 "$rc"
if grep -Fq 'worker-digest/failure-review-cadence.sh run --vault' "$RUNNER" && ! grep -Fq -- '--live' "$RUNNER" && ! grep -Fq 'JIRA_PROJECT_KEY' "$RUNNER" \
    && grep -Eq '^20 03 \* \* \* .* # HIMMEL-FailureReview$' "$FAKECRON_FILE"; then
    assert_pass 'cron runner: a dry-run runner stays dry-run at 03:20'
else
    assert_fail "cron runner: dry-run runner changed mode or time ($(cat "$RUNNER"))"
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
