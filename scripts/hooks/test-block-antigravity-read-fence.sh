#!/usr/bin/env bash
set -uo pipefail

HOOKS="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HOOKS/../.." && pwd)"
FENCE="$REPO/scripts/hooks/block-antigravity-read-fence.sh"
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not on PATH"; exit 0; }

# shellcheck source=../lib/override-env.sh
# shellcheck disable=SC1091
. "$HOOKS/../lib/override-env.sh"
scrub_override_env

TMP="$(mktemp -d "${TMPDIR:-/tmp}/block-agy-read-fence.XXXXXX")" || exit 1
trap 'rm -rf "$TMP"' EXIT

export HOME="$TMP/home"
export T3CODE_HOME="$TMP/t3home"
export TMPDIR="$T3CODE_HOME/userdata/antigravity-tmp/run1"
export CLAUDE_GLM_CONFIG_DIR="$TMP/glm-cfg"
export LUNA_VAULT="$TMP/luna"
export LUNA_VAULT_PATH="$TMP/luna"
export HANDOVER_DIR="$TMP/handovers"
export GRAPHIFY_HIMMEL_ROOT="$TMP/himmel-code"

ARTIFACT_DIR="$T3CODE_HOME/userdata/providers/antigravity/hash1/antigravity-acp/brain/conv-1"
OTHER_ART="$T3CODE_HOME/userdata/providers/antigravity/hash1/antigravity-acp/brain/conv-other"
SALUS_DIR="$TMP/salus-vault"

mkdir -p "$HOME/.gemini/config" \
    "$HOME/.t3/userdata/providers/antigravity/hash0/config" \
    "$T3CODE_HOME/userdata/providers/antigravity/hash1/config" \
    "$ARTIFACT_DIR/scratch" "$OTHER_ART" \
    "$TMPDIR" "$CLAUDE_GLM_CONFIG_DIR" \
    "$LUNA_VAULT/Clippings" "$HANDOVER_DIR" "$GRAPHIFY_HIMMEL_ROOT" "$SALUS_DIR"

touch "$SALUS_DIR/.salus"
printf 'token\n' > "$T3CODE_HOME/userdata/providers/antigravity/hash1/antigravity-oauth-token"
printf '{}\n' > "$T3CODE_HOME/userdata/providers/antigravity/hash1/config/hooks.json"
printf '{}\n' > "$HOME/.t3/userdata/providers/antigravity/hash0/config/hooks.json"
printf '{}\n' > "$HOME/.gemini/config/hooks.json"
printf '{}\n' > "$HOME/.gemini/settings.json"
printf 'art\n' > "$ARTIFACT_DIR/plan.md"
printf 'scratch\n' > "$ARTIFACT_DIR/scratch/note.txt"
printf 'other\n' > "$OTHER_ART/secret.md"
printf 'tmp\n' > "$TMPDIR/out.log"
printf 'code\n' > "$GRAPHIFY_HIMMEL_ROOT/README.md"
printf 'ho\n' > "$HANDOVER_DIR/note.md"
printf 'luna\n' > "$LUNA_VAULT/journal.md"
printf 'clip\n' > "$LUNA_VAULT/Clippings/clip.md"
printf 'phi\n' > "$SALUS_DIR/patient.md"

PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; }

run_fence() {
    local json="$1"
    shift
    [ -f "$FENCE" ] || { printf 'missing fence\n' >&2; return 127; }
    printf '%s' "$json" | env HIMMEL_ANTIGRAVITY_ARTIFACT_DIR="$ARTIFACT_DIR" "$@" bash "$FENCE" 2>&1
}

assert_allow() {
    local label="$1" json="$2"
    shift 2
    local out rc
    out="$(run_fence "$json" "$@")"; rc=$?
    if [ "$rc" -eq 0 ]; then ok "$label"; else bad "$label (expected rc=0; got rc=$rc out=$out)"; fi
}

assert_deny() {
    local label="$1" needle="$2" json="$3"
    shift 3
    local out rc
    out="$(run_fence "$json" "$@")"; rc=$?
    if [ "$rc" -eq 2 ]; then
        if [ -z "$needle" ] || grep -qiF -- "$needle" <<<"$out"; then
            ok "$label"
        else
            bad "$label (missing '$needle' in: $out)"
        fi
    else
        bad "$label (expected rc=2; got rc=$rc out=$out)"
    fi
}

mk_read() { jq -cn --arg p "$1" --arg c "${2:-$GRAPHIFY_HIMMEL_ROOT}" '{hook_event_name:"PreToolUse",tool_name:"Read",tool_input:{file_path:$p},cwd:$c}'; }
mk_bash() { jq -cn --arg cmd "$1" --arg c "${2:-$GRAPHIFY_HIMMEL_ROOT}" '{hook_event_name:"PreToolUse",tool_name:"Bash",tool_input:{command:$cmd},cwd:$c}'; }
mk_res()  { jq -cn --arg t "$1" --arg u "$2" --arg c "${3:-$GRAPHIFY_HIMMEL_ROOT}" '{hook_event_name:"PreToolUse",tool_name:$t,tool_input:{Uri:$u},cwd:$c}'; }

echo "== 1. Provider home and ~/.gemini/config hard denies =="
assert_deny "read_file denies antigravity-oauth-token" "oauth-token" \
    "$(mk_read "$T3CODE_HOME/userdata/providers/antigravity/hash1/antigravity-oauth-token")"
assert_deny "read_file denies T3 provider config/hooks.json" "provider home" \
    "$(mk_read "$T3CODE_HOME/userdata/providers/antigravity/hash1/config/hooks.json")"
assert_deny "read_file denies HOME ~/.t3 provider config/hooks.json" "provider home" \
    "$(mk_read "$HOME/.t3/userdata/providers/antigravity/hash0/config/hooks.json")"
assert_deny "read_file denies another conversation artifact dir" "provider home" \
    "$(mk_read "$OTHER_ART/secret.md")"
assert_deny "read_file denies ~/.gemini/config/hooks.json" ".gemini/config" \
    "$(mk_read "$HOME/.gemini/config/hooks.json")"
assert_deny "read_file denies ~/.gemini/settings.json" ".gemini" \
    "$(mk_read "$HOME/.gemini/settings.json")"
TILDE="~"
assert_deny "read_file denies tilde ~/.gemini/config/hooks.json" ".gemini/config" \
    "$(mk_read "${TILDE}/.gemini/config/hooks.json")"
assert_deny "read_file denies spoofed artifactDirectoryPath at provider root" "provider home" \
    "$(mk_read "$T3CODE_HOME/userdata/providers/antigravity/hash1/config/hooks.json")" \
    HIMMEL_ANTIGRAVITY_ARTIFACT_DIR="$T3CODE_HOME/userdata/providers/antigravity/hash1"

echo "== 2. run_command and MCP resource read denies =="
assert_deny "run_command denies reading antigravity-oauth-token" "oauth-token" \
    "$(mk_bash "cat $T3CODE_HOME/userdata/providers/antigravity/hash1/antigravity-oauth-token")"
assert_deny "run_command denies reading ~/.gemini/config/hooks.json" ".gemini" \
    "$(mk_bash "cat ~/.gemini/config/hooks.json")"
assert_deny "run_command denies ~/.gemini/./config/hooks.json" ".gemini" \
    "$(mk_bash "cat ~/.gemini/./config/hooks.json")"
assert_deny "run_command denies ~/.gemini/x/../config/hooks.json" ".gemini" \
    "$(mk_bash "cat ~/.gemini/x/../config/hooks.json")"
assert_deny "run_command denies \$HOME/.gemini//config/hooks.json" ".gemini" \
    "$(mk_bash "cat \$HOME/.gemini//config/hooks.json")"
assert_deny "run_command denies cd ~/.gemini && cat config/hooks.json" ".gemini" \
    "$(mk_bash "cd ~/.gemini && cat config/hooks.json")"
assert_deny "run_command denies .gemini/config/.. pre-normalization collapse" ".gemini" \
    "$(mk_bash "p=\$HOME/.gemini/config/..; cat \"\$p/config/hooks.json\"")"
assert_deny "run_command denies reading T3 provider home outside artifact dir" "provider home" \
    "$(mk_bash "ls $T3CODE_HOME/userdata/providers/antigravity/hash1/config")"
assert_deny "run_command denies userdata/./providers/antigravity traversal" "provider home" \
    "$(mk_bash "cat $T3CODE_HOME/userdata/./providers/antigravity/hash1/config/hooks.json")"
assert_deny "run_command denies userdata/x/../providers/antigravity traversal" "provider home" \
    "$(mk_bash "cat $T3CODE_HOME/userdata/x/../providers/antigravity/hash1/config/hooks.json")"
assert_deny "run_command denies artifact dir ../ escape to provider config" "provider home" \
    "$(mk_bash "cat $ARTIFACT_DIR/../../../config/hooks.json")"
assert_deny "run_command denies sibling artifact dir prefix collision" "provider home" \
    "$(mk_bash "cat ${ARTIFACT_DIR}0/secret.md")"
assert_deny "run_command from forbidden ~/.gemini/config cwd denied" ".gemini" \
    "$(mk_bash "cat hooks.json" "$HOME/.gemini/config")"
assert_deny "read_resource denies file:// to antigravity-oauth-token" "oauth-token" \
    "$(mk_res read_resource "file://$T3CODE_HOME/userdata/providers/antigravity/hash1/antigravity-oauth-token")"
assert_deny "read_resource denies file:// to ~/.gemini/config/hooks.json" ".gemini" \
    "$(mk_res read_resource "file://$HOME/.gemini/config/hooks.json")"
assert_deny "list_resources denies payload naming ~/.gemini/config" ".gemini" \
    "$(mk_res list_resources "$HOME/.gemini/config")"

echo "== 3. Allowed corpora and explicit allow set =="
assert_allow "allows himmel-code" "$(mk_read "$GRAPHIFY_HIMMEL_ROOT/README.md")"
assert_allow "allows handover-state" "$(mk_read "$HANDOVER_DIR/note.md")"
assert_allow "allows luna-personal" "$(mk_read "$LUNA_VAULT/journal.md")"
assert_allow "allows luna-clippings" "$(mk_read "$LUNA_VAULT/Clippings/clip.md")"
assert_allow "allows salus (Decision 1259)" "$(mk_read "$SALUS_DIR/patient.md")"
assert_allow "allows /tmp" "$(mk_read "/tmp/himmel-read-fence-ok.txt")"
assert_allow "allows TMPDIR under antigravity-tmp" "$(mk_read "$TMPDIR/out.log")"
assert_allow "allows session artifactDirectoryPath" "$(mk_read "$ARTIFACT_DIR/plan.md")"
assert_allow "allows session artifactDirectoryPath scratch" "$(mk_read "$ARTIFACT_DIR/scratch/note.txt")"
assert_allow "run_command referencing own artifactDirectoryPath allowed" \
    "$(mk_bash "cat $ARTIFACT_DIR/plan.md")"
assert_allow "benign read_resource allowed" "$(mk_res read_resource "himmel://docs/readme")"

echo "== 4. Fail-closed on malformed input and unreadable PHI list =="
assert_deny "malformed JSON stdin denied" "malformed" "{bad-json"
assert_deny "empty Read file_path denied" "empty" "$(mk_read "")"
touch "$CLAUDE_GLM_CONFIG_DIR/phi-roots"
chmod 000 "$CLAUDE_GLM_CONFIG_DIR/phi-roots"
assert_deny "unreadable phi-roots fails closed" "classify" "$(mk_read "$GRAPHIFY_HIMMEL_ROOT/README.md")"
chmod 600 "$CLAUDE_GLM_CONFIG_DIR/phi-roots"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
