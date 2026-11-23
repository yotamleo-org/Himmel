# shellcheck shell=bash
# sourced-lib: only ever sourced by the test-uninstall parts; the parts run in the environment their caller gives them
# shellcheck disable=SC2034

assert_rc() {
    local label="$1" expected="$2" actual="$3"
    if [ "$actual" = "$expected" ]; then
        echo "PASS $label (rc=$actual)"
    else
        echo "FAIL $label — expected rc=$expected, got rc=$actual"
        # name why the run stopped, so a red on a platform we
        # cannot attach to is diagnosable from the log alone.
        printf '%s\n' "${out:-}" | grep -E 'ERROR|Halted at|WARN' | head -n 8 | sed 's/^/    | /'
        FAILED=$((FAILED + 1))
    fi
}

assert_has() {
    local label="$1" needle="$2" haystack="$3"
    case "$haystack" in
        *"$needle"*) echo "PASS $label" ;;
        *)
            echo "FAIL $label — output missing: $needle"
            FAILED=$((FAILED + 1))
            ;;
    esac
}

assert_not_has() {
    local label="$1" needle="$2" haystack="$3"
    case "$haystack" in
        *"$needle"*)
            echo "FAIL $label — output unexpectedly contains: $needle"
            FAILED=$((FAILED + 1))
            ;;
        *) echo "PASS $label" ;;
    esac
}

FAILED=0
# an empty /tmp/.git kept appearing on this host. Record which of these
# already exist so the end-of-suite guard fails if THIS suite creates one.
GIT_LEAK_PRE=""; for _p in /tmp/.git "${TMPDIR:-/tmp}/.git"; do [ -e "$_p" ] && GIT_LEAK_PRE="$GIT_LEAK_PRE $_p"; done
# git discovery for every non-git fixture (SC6K/SC6M/SC6R) stops at $TMP,
# so an ambient .git above it (an empty /tmp/.git) cannot change the verdict.
export GIT_CEILING_DIRECTORIES="$TMP"
[ -n "$TMP" ] && [ -d "$TMP" ] || exit 1
trap 'rm -rf "$TMP"' EXIT

# (the 2026-09-03 real-HOME wipe): no case in this suite may fall
# through to the operator's REAL $HOME. Capture it for the assertion below,
# then override HOME for the WHOLE suite with an empty fixture that carries
# none of uninstall.sh's wet-run fence markers — a case that forgets its own
# per-invocation HOME override lands here, not on the operator's profile.
REAL_HOME="$HOME"
unset HIMMEL_UNINSTALL_REAL_HOME HIMMEL_PROVENANCE_DIR
SUITE_HOME="$TMP/suitehome"
mkdir -p "$SUITE_HOME"
export HOME="$SUITE_HOME"
# run from a scratch cwd too. uninstall.sh refuses a wet run whose
# repo-rooted targets ({PWD}, the hooks dir) resolve into the real home, which
# a checkout under it (a worktree, CI's /home/runner/work) always does.
mkdir -p "$TMP/cwd"
cd "$TMP/cwd" || exit 1
case "$REAL_HOME" in
    "$TMP"|"$TMP"/*)
        echo "FAIL the operator's real \$HOME resolved under this suite's \$TMP — refusing to proceed"
        FAILED=$((FAILED + 1))
        ;;
    *) echo "PASS the operator's real \$HOME is not under this suite's \$TMP" ;;
esac
if [ -e "$SUITE_HOME/.claude/.credentials.json" ]; then
    echo "FAIL the suite HOME fixture already carries a live-operator marker"
    FAILED=$((FAILED + 1))
else
    echo "PASS the suite HOME fixture carries no live-operator marker"
fi

# the two checks above are this suite's OWN protection,
# independent of uninstall.sh's guard — a soft FAIL here must not fall
# through to the wet rows below. Abort now, before any uninstall.sh
# invocation, rather than merely counting the failure.
if [ "$FAILED" -gt 0 ]; then
    echo "FAIL aborting: HOME-isolation preflight failed — refusing to run any uninstall.sh row"
    exit 1
fi

# Build a hermetic PATH ONCE, before the first case,
# and thread it through EVERY invocation below (moved up from its old home
# near the SC7 section, which now just adds FAKE_HOME/EMPTY_HOME on top of
# it). A suite that reaches a real claude/pre-commit/bun/crontab/schtasks/
# systemctl is exactly the accident class this ticket exists to close off.
HBIN="$TMP/hbin"
mkdir -p "$HBIN"
# shellcheck disable=SC2317,SC2329  # invoked indirectly by link_hermetic_tool (0.10 reports SC2317, 0.11 SC2329)
fail() { echo "FAIL $*"; FAILED=$((FAILED + 1)); }   # link_hermetic_tool's diagnostic hook
# shellcheck source=../lib/hermetic-path.sh
# shellcheck disable=SC1091
. "$(dirname "$CLI")/lib/hermetic-path.sh"
for _t in bash env sed grep awk tr sort head tail cut wc cat ls rm cp mv ln mkdir chmod \
          basename dirname readlink mktemp uname date id find xargs jq node; do
    link_hermetic_tool "$_t" "$HBIN"
done
for _excluded in claude pre-commit bun crontab schtasks systemctl; do
    if PATH="$HBIN" command -v "$_excluded" >/dev/null 2>&1; then
        echo "FAIL hermetic \$HBIN unexpectedly resolves $_excluded"
        FAILED=$((FAILED + 1))
    else
        echo "PASS hermetic \$HBIN never resolves $_excluded"
    fi
done

# every case below runs `PATH=...:$HBIN bash "$CLI"`, and $HBIN's
# bash is a COPY where `ln -s` is refused (MSYS without the symlink privilege);
# a copied bash.exe cannot load msys-2.0.dll from $HBIN, so each of those runs
# is rc 127 and every case fails for that reason, not for the one it names.
# Probed (not keyed off uname), so a Linux host runs the whole suite.
# shellcheck source=../lib/host-caps.sh
. "$(dirname "$CLI")/lib/host-caps.sh"
if ! host_isolated_bash_boots; then
    host_skip "uninstall.sh cases need a bash that starts under the hermetic PATH; a copied bash cannot boot on this host"
    exit "$((FAILED > 0 ? 1 : 0))"
fi

# Redirect the [6/8] settings-unwire target away from the operator's REAL
# ~/.claude/settings.json for the whole suite. The dedicated SC6
# cases re-seed this file per-test; the others simply never touch the real one.
export HIMMEL_USER_SETTINGS="$TMP/user-settings.json"
printf '{}\n' > "$HIMMEL_USER_SETTINGS"

# S6: seeds a completed provenance ledger session at a fixture's
# OWN $HOME, recording plugin/marketplace units as himmel-installed
# (preexisted=false -> ours=true), via the same prov_record primitive
# install-plugins.sh's real writer uses (pattern shared with RED3 in
# scripts/test-uninstall-provenance.sh). This is what turns [4/8]/[7/8]'s
# active ledger-owned removal branch back on for a fixture that needs to
# exercise real plugin/marketplace removal, instead of the no-ledger "kept"
# default this suite otherwise exercises everywhere else.
# an item may carry `:<cli_scope>` (default user) -- the ledger's
# own recorded scope, which ledger-mode removal now honours.
# shellcheck source=../lib/provenance.sh
. "$(dirname "$CLI")/lib/provenance.sh"
seed_plugin_ledger() {
    # The seeded HOME comes in as SEED_HOME (a command prefix), not an argument: the
    # real-home caller scan traces it to a scratch dir, and it cannot trace an argument.
    local plugins="$1" markets="$2" _id _m _sc
    (
        # shellcheck disable=SC2030 # confined to this subshell; never leaks
        # to the parent script (shellcheck's SC2031 hits below, at unrelated
        # $HOME reads elsewhere in this file, are false positives from that).
        export HOME="$SEED_HOME"
        unset HIMMEL_PROVENANCE_DIR CLAUDE_CONFIG_DIR
        prov_begin --writer install-plugins.sh -- seed >/dev/null
        IFS=','
        for _id in $plugins; do
            [ -n "$_id" ] || continue
            _sc=user; case "$_id" in *:*) _sc="${_id#*:}"; _id="${_id%%:*}" ;; esac
            prov_record register plugin - --unit "$_id" --scope machine --class code \
                --writer install-plugins.sh --row plugins --field "cli_scope=\"$_sc\"" --field preexisted=false >/dev/null
        done
        for _m in $markets; do
            [ -n "$_m" ] || continue
            _sc=user; case "$_m" in *:*) _sc="${_m#*:}"; _m="${_m%%:*}" ;; esac
            prov_record register marketplace - --unit "$_m" --scope machine --class code \
                --writer install-plugins.sh --row marketplaces --field "cli_scope=\"$_sc\"" --field preexisted=false >/dev/null
        done
        unset IFS
        prov_end ok >/dev/null
    )
}

mk_state() {
    CHANNEL="$TMP/channels/telegram"
    BRIDGE="$TMP/bridge"
    rm -rf "$CHANNEL" "$BRIDGE"
    mkdir -p "$CHANNEL" "$BRIDGE/sessions/S1"
    printf 'TELEGRAM_BOT_TOKEN=123:abc\n' > "$CHANNEL/.env"
    printf '{"allowFrom":["42"]}\n' > "$CHANNEL/access.json"
    printf 'x\n' > "$BRIDGE/sessions/S1/inbox.jsonl"
}

u_suite_setup() {
U_REPO="$TMP/u-repo"
mkdir -p "$U_REPO/.git/hooks" "$U_REPO/scripts/machine-setup" "$U_REPO/scripts/lib" "$U_REPO/docs/setup"
cp "$(dirname "$CLI")/machine-setup/uninstall-plugins.sh" "$U_REPO/scripts/machine-setup/"
for helper in unwire-statusline unwire-himmel-repo unwire-luna-vault unwire-handover-dir unwire-pretooluse-hooks wire-pretooluse-hooks provenance canon-path claude-config-dir; do
    cp "$(dirname "$CLI")/lib/$helper.sh" "$U_REPO/scripts/lib/"
done
cp "$(dirname "$CLI")/../docs/setup/settings-template.json" "$U_REPO/docs/setup/"
# S2d: the unrecorded-block fallback compares against this template,
# which uninstall.sh reads from $REPO_ROOT (the override), so the fixture ships it.
cp "$(dirname "$CLI")/../docs/setup/user-scope-claude-md-template.md" "$U_REPO/docs/setup/"
printf '# pre-commit sample only\n' > "$U_REPO/.git/hooks/pre-commit.sample"
export CLAUDE_CALL_LOG="$TMP/u-claude.log"
export STUB_PLUGINS_JSON="$TMP/u-plugins.json"
export STUB_MARKETPLACES_JSON="$TMP/u-marketplaces.json"
export STUB_FAIL_IDS="" STUB_ADD_NAME="himmel"
U_BIN="$TMP/u-bin"
mkdir -p "$U_BIN"
cat > "$U_BIN/claude" <<'STUB_EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$CLAUDE_CALL_LOG"
json_list() {
    if [ ! -s "$1" ]; then echo '[]'
    elif [ "$(cat "$1")" = "DEGRADED" ]; then exit 1 # read-sink-ok: a fixture status file the suite wrote
    else cat "$1"
    fi
}
case "$*" in
    'plugin list --json') json_list "$STUB_PLUGINS_JSON" ;;
    'plugin marketplace list --json') json_list "$STUB_MARKETPLACES_JSON" ;;
    'plugin uninstall '* )
        [ "$#" -eq 5 ] && [ "$4" = '--scope' ] || exit 2
        if grep -qxF -- "$3" <<< "${STUB_FAIL_IDS:-}"; then exit 1; fi
        if [ "$(cat "$STUB_PLUGINS_JSON")" != DEGRADED ]; then
            jq --arg id "$3" --arg scope "$5" '[.[] | select(.id != $id or .scope != $scope)]' \
                "$STUB_PLUGINS_JSON" > "$STUB_PLUGINS_JSON.next"
            mv "$STUB_PLUGINS_JSON.next" "$STUB_PLUGINS_JSON"
        fi
        ;;
    'plugin marketplace remove '* )
        [ "$#" -eq 6 ] && [ "$5" = '--scope' ] || exit 2
        if grep -qxF -- "$4" <<< "${STUB_FAIL_IDS:-}"; then exit 1; fi
        jq --arg name "$4" '[.[] | select(.name != $name)]' \
            "$STUB_MARKETPLACES_JSON" > "$STUB_MARKETPLACES_JSON.next"
        mv "$STUB_MARKETPLACES_JSON.next" "$STUB_MARKETPLACES_JSON"
        ;;
    'plugin marketplace add '* )
        [ "$#" -eq 4 ] || exit 2
        jq --arg name "${STUB_ADD_NAME:-himmel}" '. + [{name: $name}]' \
            "$STUB_MARKETPLACES_JSON" > "$STUB_MARKETPLACES_JSON.next"
        mv "$STUB_MARKETPLACES_JSON.next" "$STUB_MARKETPLACES_JSON"
        ;;
    *) exit 2 ;;
esac
STUB_EOF
chmod 755 "$U_BIN/claude"
}
u_fixture() {
    mk_state
    U_HOME=$(mktemp -d "$TMP/u-home.XXXXXX") || exit 1
    U_CACHE="$TMP/u-$1-cache"
    mkdir -p "$U_HOME" "$U_CACHE"
    printf '{"scope":"user"}\n' > "$U_CACHE/install-profile.json"
    printf '{"env":{"HIMMEL_REPO":"/fixture/himmel","KEEP":"yes"}}\n' > "$HIMMEL_USER_SETTINGS"
    cp "$HIMMEL_USER_SETTINGS" "$TMP/u-settings-before"
    : > "$CLAUDE_CALL_LOG"
    printf '[{"id":"handover@himmel","scope":"user"}]\n' > "$STUB_PLUGINS_JSON"
    printf '[{"name":"himmel"},{"name":"obsidian-skills"},{"name":"claude-plugins-official"}]\n' > "$STUB_MARKETPLACES_JSON"
    STUB_FAIL_IDS=""
    # S6: without a ledger row for handover@himmel/himmel, [4/8]
    # and [7/8] now take the no-ledger "kept" no-op instead of ever calling
    # `claude plugin uninstall`/`marketplace remove` -- seed exactly the
    # plugin/marketplace this fixture's stub already carries as himmel's own.
    SEED_HOME="$U_HOME" seed_plugin_ledger "handover@himmel:${2:-user}" "himmel:${2:-user}"
}
u_run() {
    out=$(HOME="$U_HOME" PATH="$U_BIN:$HBIN" HIMMEL_UNINSTALL_REPO_ROOT="$U_REPO" \
        TELEGRAM_CHANNEL_DIR="$CHANNEL" BRIDGE_ROOT="$BRIDGE" HIMMELCTL_CACHE_DIR="$U_CACHE" \
        bash "$CLI" --purge-state --yes --skip-tasks "$@" </dev/null 2>&1); rc=$?
    calls=$(cat "$CLAUDE_CALL_LOG")
}
# the pre-commit framework's own identity set (is_our_script() in
# pre_commit/commands/install_uninstall.py): CURRENT_HASH first, then the five
# PRIOR_HASHES. A hook the framework installed carries exactly one of these.
FRAMEWORK_HASHES=(138fd403232d2ddd5efb44317e38bf03 4d9958c90bc262f47553e2c073f14cfe
    d8ee923c46731b42cd95cc869add4062 49fd668cb42069aa1b6048464be5d395
    79f09a650522a87b0da915d0d983b2de e358c9dae00eac5d06b38dfdb1e33a8c)
# framework_hook_text [hash] — what `pre-commit install` writes (default: CURRENT_HASH).
framework_hook_text() {
    printf '#!/usr/bin/env bash\n# File generated by pre-commit: https://pre-commit.com\n# ID: %s\n' "${1:-${FRAMEWORK_HASHES[0]}}"
}
