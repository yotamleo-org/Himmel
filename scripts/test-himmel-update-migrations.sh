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
cp "$SOURCE_ROOT/marketplace/plugins/handover/scripts/migrate-v1-to-v2.sh" "$ROOT/marketplace/plugins/handover/scripts/"
cp "$SOURCE_ROOT/marketplace/plugins/obsidian-triage/tools/migrate-clip-lifecycle.mjs" "$ROOT/marketplace/plugins/obsidian-triage/tools/"
cp "$SOURCE_ROOT/marketplace/plugins/obsidian-triage/tools/lib/evidence-kind.mjs" "$ROOT/marketplace/plugins/obsidian-triage/tools/lib/"
printf 'marketplace/\n' >> "$ROOT/.git/info/exclude"
export HANDOVER_DIR="$TMP/state repo/handovers" LUNA_VAULT_PATH="$TMP/vault sample"
mkdir -p "$HANDOVER_DIR/tester/standalones/#7-legacy" "$LUNA_VAULT_PATH/Clippings"
printf '%s\n' '---' 'template_version: 1' 'jira: TEST-7' '---' > "$HANDOVER_DIR/tester/standalones/#7-legacy/brief.md"
printf '%s\n' '---' 'processed: true' '---' 'legacy clip' > "$LUNA_VAULT_PATH/Clippings/legacy.md"
case "${1:-}" in
    --real-clip) cp "$2" "$LUNA_VAULT_PATH/Clippings/legacy.md" ;;
    --real-vault) cp -R "$2/." "$LUNA_VAULT_PATH/" ;;
esac

snapshot() {
    python3 -I - "$HANDOVER_DIR" "$LUNA_VAULT_PATH" <<'PY'
import hashlib, os, sys
for root in sys.argv[1:]:
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
assert_unchanged 'check: both fixture trees byte-identical' "$before"

# The printed commands must actually target these installs, even with spaces.
if [ "$fail" -eq 0 ]; then
    while IFS= read -r line; do
        command="${line#*preview: }"
        rc=0
        preview="$(bash -c "$command" 2>&1)" || rc=$?
        assert_eq 'printed preview command: rc 0' 0 "$rc"
        if grep -Eq 'rename:|PLAN ' <<< "$preview"; then
            assert_pass 'printed preview command: finds legacy data'
        else
            assert_fail "printed preview command: no plan ($preview)"
        fi
    done < <(grep -E '(handover|clip-lifecycle) migration needed' <<< "$out")
    assert_unchanged 'printed previews: fixture trees byte-identical' "$before"
fi

# Apply mode may update its mock checkout, but must never migrate user data.
rc=0
out="$(bash "$ROOT/scripts/himmel-update.sh" 2>&1)" || rc=$?
assert_eq 'apply: updater succeeds' 0 "$rc"
assert_warning handover "$HANDOVER_DIR" 'migrate-v1-to-v2.sh'
assert_warning clip-lifecycle "$LUNA_VAULT_PATH" 'migrate-clip-lifecycle.mjs'
assert_unchanged 'apply: both fixture trees byte-identical' "$before"
printf '%s\n' "$out" | grep -E '(handover|clip-lifecycle) migration needed' || true

mv "$HANDOVER_DIR/tester/standalones/#7-legacy" "$HANDOVER_DIR/tester/standalones/TEST-7-legacy"
mkdir -p "$LUNA_VAULT_PATH/Clippings/_evidence"
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

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
