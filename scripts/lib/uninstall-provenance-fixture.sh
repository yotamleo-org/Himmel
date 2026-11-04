# shellcheck shell=bash
# shellcheck disable=SC2015,SC2154,SC2034 # sourced: the part sets repo_root and reads the BACKUP_SM, S3_BACKUP and BLK_* values the helpers set
# uninstall-provenance-fixture.sh -- the shared fixture of the test-uninstall-provenance*.sh family:
# scratch HOME + provenance dir per case, the fake claude, run_uninstall and the
# seed_* helpers, then the real-ledger tripwire in uninstall_prov_finish. Sourced, never run;
# the caller sets here, repo_root and lib first.
command -v jq >/dev/null 2>&1 || { echo "test-uninstall-provenance: jq required" >&2; exit 2; }
# shellcheck source=scripts/lib/provenance.sh
. "$lib/provenance.sh"
# shellcheck source=scripts/lib/provenance-identity.sh
. "$lib/provenance-identity.sh"

# S6 safety: the real-ledger tripwire. REAL_HOME is captured
# before ANY case below exports its own scratch HOME, so a bug that let a
# case's HOME leak back to the operator's real one is caught by an
# existence/sha mismatch at the end of the run instead of silently touching
# the operator's ~/.himmel/provenance.jsonl.
REAL_HOME="$HOME"
REAL_LEDGER="$REAL_HOME/.himmel/provenance.jsonl"
real_ledger_state() {
  if [ -f "$REAL_LEDGER" ]; then prov_sha_file "$REAL_LEDGER" 2>/dev/null || echo "ERROR-UNREADABLE"
  else echo "ABSENT"; fi
}
REAL_LEDGER_BEFORE=$(real_ledger_state)

TMPDIR="$(cd -P -- "${TMPDIR:-/tmp}" && pwd)" || exit 1; export TMPDIR
# an empty /tmp/.git kept appearing on this host. Record which of these
# already exist so the end-of-suite guard fails if THIS suite creates one.
GIT_LEAK_PRE=""; for _p in /tmp/.git "${TMPDIR:-/tmp}/.git"; do [ -e "$_p" ] && GIT_LEAK_PRE="$GIT_LEAK_PRE $_p"; done
SUITE_TMP="$(mktemp -d "${TMPDIR:-/tmp}/uninstall-prov.XXXXXX")" || { echo "FAIL: mktemp" >&2; exit 1; } # prim-ok: moved verbatim from test-uninstall-provenance.sh; the suite never sources prim.sh
trap 'rm -rf "$SUITE_TMP"' EXIT

fails=0
failed_labels=""
check(){ [ "$2" = "$3" ] && echo "ok - $1" || { echo "FAIL - $1: [$2]!=[$3]"; failed_labels="$failed_labels
  $1"; fails=$((fails+1)); }; }

# ---- fake claude stub (adapted from scripts/test-uninstall-plugins.sh) -----
# One binary shared by every case; CLAUDE_CALL_LOG/STUB_PLUGINS_JSON/
# STUB_MARKETPLACES_JSON (set per run_uninstall call) point it at that case's
# own state, so cases never share plugin/marketplace state.
mkdir -p "$SUITE_TMP/bin"
FAKE_CLAUDE="$SUITE_TMP/bin/claude"
cat > "$FAKE_CLAUDE" <<'STUB_EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$CLAUDE_CALL_LOG"
json_list() {
    if [ ! -s "$1" ]; then echo '[]'
    else cat "$1"
    fi
}
case "$*" in
    'plugin list --json') json_list "$STUB_PLUGINS_JSON" ;;
    'plugin marketplace list --json') json_list "$STUB_MARKETPLACES_JSON" ;;
    'plugin uninstall '* )
        [ "$#" -eq 5 ] && [ "$4" = '--scope' ] || exit 2
        jq --arg id "$3" --arg scope "$5" '[.[] | select(.id != $id or .scope != $scope)]' \
            "$STUB_PLUGINS_JSON" > "$STUB_PLUGINS_JSON.next"
        mv "$STUB_PLUGINS_JSON.next" "$STUB_PLUGINS_JSON"
        ;;
    'plugin marketplace remove '* )
        [ "$#" -eq 6 ] && [ "$5" = '--scope' ] || exit 2
        jq --arg name "$4" '[.[] | select(.name != $name)]' \
            "$STUB_MARKETPLACES_JSON" > "$STUB_MARKETPLACES_JSON.next"
        mv "$STUB_MARKETPLACES_JSON.next" "$STUB_MARKETPLACES_JSON"
        ;;
    'plugin marketplace add '* )
        [ "$#" -eq 6 ] && [ "$5" = '--scope' ] || exit 2
        jq --arg name "himmel" '. + [{name: $name}]' \
            "$STUB_MARKETPLACES_JSON" > "$STUB_MARKETPLACES_JSON.next"
        mv "$STUB_MARKETPLACES_JSON.next" "$STUB_MARKETPLACES_JSON"
        ;;
    *) exit 2 ;;
esac
STUB_EOF
chmod 755 "$FAKE_CLAUDE"

# fake qmd stub -- qmd_cmd (scripts/lib/qmd-bin.sh) falls back to `qmd` on
# PATH whenever its bun-direct qmd.js path (BUN_INSTALL, pointed at a fresh
# scratch dir by run_uninstall) does not exist, so this is always what
# handles `qmd collection remove` in these tests, real bun on PATH or not.
# RED26: `collection remove` refuses (exit 127, matching a real qmd_cmd
# "not found" when the bun-global link/fork are already gone) if
# QMD_ORDER_CHECK_FORK_DIR/QMD_ORDER_CHECK_SYMLINK are set and either has
# already been removed -- this is how a real qmd_cmd resolution would fail if
# uninstall.sh unwired the fork checkout or global symlink before removing
# the collection, since prod's `qmd collection remove` is served through
# exactly one of those two paths.
# S16: `collection show <name>` answers the uninstall verdict's
# live-identity read with QMD_STUB_SHOW_PATH as the Path; unset, it answers
# qmd's own "Collection not found" (exit 1).
FAKE_QMD="$SUITE_TMP/bin/qmd"
cat > "$FAKE_QMD" <<'QMD_STUB_EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "${QMD_CALL_LOG:-/dev/null}"
case "$*" in
    'collection show '*)
        if [ -z "${QMD_STUB_SHOW_PATH:-}" ]; then
            echo "Collection not found: $3" >&2
            exit 1
        fi
        printf 'Collection: %s\n  Path:     %s\n  Pattern:  **/*.md\n' "$3" "$QMD_STUB_SHOW_PATH"
        exit 0 ;;
    'collection remove '*)
        if [ -n "${QMD_ORDER_CHECK_FORK_DIR:-}" ] && [ ! -d "$QMD_ORDER_CHECK_FORK_DIR" ]; then
            echo "fake qmd: collection remove called after the fork checkout was already removed" >&2
            exit 127
        fi
        if [ -n "${QMD_ORDER_CHECK_SYMLINK:-}" ] && [ ! -L "$QMD_ORDER_CHECK_SYMLINK" ]; then
            echo "fake qmd: collection remove called after the global symlink was already removed" >&2
            exit 127
        fi
        exit 0 ;;
    *) exit 2 ;;
esac
QMD_STUB_EOF
chmod 755 "$FAKE_QMD"

# fake crontab stub: `-l` prints CRONTAB_STATE_FILE (a
# per-case scratch table; missing/empty means "no crontab for tester", the
# same message real crontab gives an unset table -- both _provid_job and
# uninstall.sh's [3/8] cron rewrite classify that string as ABSENT/no-op, never
# a read failure). `-` reads a replacement table from stdin and overwrites the
# same file, so the [3/8] `crontab -` rewrite is observable afterwards without
# ever touching the operator's real crontab.
FAKE_CRONTAB="$SUITE_TMP/bin/crontab"
cat > "$FAKE_CRONTAB" <<'CRONTAB_STUB_EOF'
#!/usr/bin/env bash
set -u
case "${1:-}" in
    -l)
        if [ -z "${CRONTAB_STATE_FILE:-}" ] || [ ! -f "$CRONTAB_STATE_FILE" ]; then
            echo "no crontab for tester" >&2
            exit 1
        fi
        cat "$CRONTAB_STATE_FILE" ;;
    -)
        [ -n "${CRONTAB_STATE_FILE:-}" ] || exit 1
        cat > "$CRONTAB_STATE_FILE" ;;
    *) exit 2 ;;
esac
CRONTAB_STUB_EOF
chmod 755 "$FAKE_CRONTAB"

# fake jq shim: a real jq passthrough for every
# call EXCEPT prov_read_units' own fold query, which it forces to fail
# (exit 1) when RED53_FORCE_JQ_FAIL=1 is exported -- prov_read_units' filter
# is the only jq invocation in this codebase carrying `--argjson havepath`
# (provenance-read.sh), so this is a targeted failure injection of "the fold
# read itself errors", not a corrupted row (which prov_read_load's own
# fold-validation already catches upstream, before LEDGER_OK is even set).
REAL_JQ="$(command -v jq)"
FAKE_JQ="$SUITE_TMP/bin/jq"
cat > "$FAKE_JQ" <<JQ_STUB_EOF
#!/usr/bin/env bash
set -u
if [ "\${RED53_FORCE_JQ_FAIL:-}" = "1" ]; then
    prev=""
    for a in "\$@"; do
        [ "\$prev" = "--argjson" ] && [ "\$a" = "havepath" ] && exit 1
        prev="\$a"
    done
fi
if [ "\${RED54_FORCE_JQ_FAIL:-}" = "1" ]; then
    for a in "\$@"; do
        case "\$a" in *HIMMEL-3637-pu-json*) exit 5 ;; esac
    done
fi
exec "$REAL_JQ" "\$@"
JQ_STUB_EOF
chmod 755 "$FAKE_JQ"

# new_case <name> -- fresh scratch HOME/cwd/provenance dir + fresh plugin and
# marketplace stub state for one case. Sets the CASE_* globals the rest of
# the case (and run_uninstall) uses.
new_case() {
  # CASE_DIR is grounded in a literal mktemp template (not "$1")
  # so the real-home-callers static scan can verify HOME stays scratch.
  CASE_DIR="$(mktemp -d "$SUITE_TMP/case.XXXXXX")" || { echo "FAIL: mktemp CASE_DIR ($1)" >&2; exit 1; } # prim-ok: moved verbatim from test-uninstall-provenance.sh
  mkdir -p "$CASE_DIR/home/.claude" "$CASE_DIR/cwd" "$CASE_DIR/prov"
  export HOME="$CASE_DIR/home"
  export HIMMEL_PROVENANCE_DIR="$CASE_DIR/prov"
  unset CLAUDE_CONFIG_DIR
  CASE_SETTINGS="$HOME/.claude/settings.json"
  printf '{}\n' > "$CASE_SETTINGS"
  CASE_CLAUDE_LOG="$CASE_DIR/claude.log"; : > "$CASE_CLAUDE_LOG"
  CASE_PLUGINS_JSON="$CASE_DIR/plugins.json"; printf '[]\n' > "$CASE_PLUGINS_JSON"
  CASE_MARKETPLACES_JSON="$CASE_DIR/marketplaces.json"; printf '[]\n' > "$CASE_MARKETPLACES_JSON"
  # A case that wants a real qmd fixture sets these itself, right after
  # calling new_case -- unset here so a case that does NOT set them never
  # inherits a stale dir from an earlier case in the same suite run.
  unset CASE_QMD_FORK_DIR CASE_BUN_INSTALL CASE_QMD_ORDER_CHECK_FORK_DIR CASE_QMD_ORDER_CHECK_SYMLINK
  unset CASE_QMD_COLLECTION_PATH
  # A case that wants a fake crontab table sets this itself, right after
  # calling new_case -- unset here so a case that does NOT set it never
  # inherits a stale file from an earlier case (default: no crontab).
  unset CASE_CRONTAB_FILE
}

# run_uninstall <uninstall.sh args...> -- the real uninstall.sh, confined to
# this case's scratch HOME/cwd, with the fake claude first on PATH. Telegram/
# bridge/himmelctl-cache all point at fresh nonexistent dirs so steps 1-2-8
# no-op no matter what the case is testing. QMD_FORK_DIR/BUN_INSTALL default
# the same way (a case that wants a real qmd fixture sets CASE_QMD_FORK_DIR /
# CASE_BUN_INSTALL before calling).
run_uninstall() {
  ( cd "$CASE_DIR/cwd" && \
    HIMMEL_USER_SETTINGS="$CASE_SETTINGS" \
    TELEGRAM_CHANNEL_DIR="$CASE_DIR/no-telegram" BRIDGE_ROOT="$CASE_DIR/no-bridge" \
    HIMMELCTL_CACHE_DIR="$CASE_DIR/no-cache" \
    QMD_FORK_DIR="${CASE_QMD_FORK_DIR:-$CASE_DIR/no-qmd-fork}" \
    BUN_INSTALL="${CASE_BUN_INSTALL:-$CASE_DIR/no-bun}" \
    QMD_CALL_LOG="$CASE_DIR/qmd.log" \
    QMD_STUB_SHOW_PATH="${CASE_QMD_COLLECTION_PATH:-}" \
    QMD_ORDER_CHECK_FORK_DIR="${CASE_QMD_ORDER_CHECK_FORK_DIR:-}" \
    QMD_ORDER_CHECK_SYMLINK="${CASE_QMD_ORDER_CHECK_SYMLINK:-}" \
    CRONTAB_STATE_FILE="${CASE_CRONTAB_FILE:-$CASE_DIR/no-crontab}" \
    HIMMEL_PROVENANCE_DIR="$HIMMEL_PROVENANCE_DIR" \
    CLAUDE_CALL_LOG="$CASE_CLAUDE_LOG" STUB_PLUGINS_JSON="$CASE_PLUGINS_JSON" \
    STUB_MARKETPLACES_JSON="$CASE_MARKETPLACES_JSON" \
    PATH="$SUITE_TMP/bin:$PATH" \
    _run_uninstall_inner "$@" )
}

# S2b: with RUN_TTY_ANSWER set, uninstall.sh runs on a real pty
# (util-linux `script`) with that answer typed at its first prompt, so the
# [ -t 0 ] && [ -t 1 ] TTY offers are reachable; otherwise stdin is /dev/null.
_run_uninstall_inner() {
  if [ -n "${RUN_TTY_ANSWER:-}" ]; then
    # util-linux script(1) takes the command as a string (-c); BSD/macOS has
    # no -c/-e and takes the argv after the file. Probed by --version (BSD
    # rejects it), not keyed off uname.
    if script --version >/dev/null 2>&1; then
      printf '%s\n' "$RUN_TTY_ANSWER" \
        | script -qec "$(printf '%q ' bash "$repo_root/scripts/uninstall.sh" "$@")" /dev/null 2>&1
    else
      # ponytail: fixed 3s start delay + 1s per key, not prompt-synchronised;
      # BSD script drops input written before the child reads, so the keys are
      # fed paced. Upgrade to an expect-style prompt wait if a slow runner flakes.
      { sleep 3
        printf '%s\n' "$RUN_TTY_ANSWER" | while IFS= read -r _k || [ -n "$_k" ]; do printf '%s\n' "$_k"; sleep 1; done
        sleep 2
      } | script -q /dev/null bash "$repo_root/scripts/uninstall.sh" "$@" 2>&1
    fi
  else
    bash "$repo_root/scripts/uninstall.sh" "$@" </dev/null 2>&1
  fi
}

run_uninstall_fx() { export HIMMEL_UNINSTALL_REAL_HOME=1; run_uninstall "$@"; local rc=$?; unset HIMMEL_UNINSTALL_REAL_HOME; return "$rc"; }

_red_seed_git_fork() {
  # <dir> -- init a one-commit git repo at $1, matching the real fork
  # checkout's shape (a build stamp file that is byte-identical to a fresh
  # clone). Returns with the tree clean and HEAD pushed to a bare "origin".
  # qmd_unwire_fork_checkout now checks live git state before
  # removing, so every fixture standing in for a real (always-git) fork
  # checkout needs an actual repo, not a plain directory -- a plain directory
  # is itself the "unknown state" the fix is required to keep, not remove.
  local dir="$1" bare
  mkdir -p "$dir"
  git -C "$dir" init -q
  git -C "$dir" config user.email test@example.invalid
  git -C "$dir" config user.name "Test"
  # match the real fork's .gitignore shape (node_modules/,
  # dist/ are the build's own output; notes/ stands in for the fork's many
  # OTHER ignored patterns -- archive/, *.sqlite, etc -- that are NOT build
  # output and so stay off the allowlist).
  printf 'node_modules/\ndist/\nnotes/\n' > "$dir/.gitignore"
  printf 'fork file\n' > "$dir/tracked.txt"
  git -C "$dir" add -A
  git -C "$dir" commit -q -m seed
  # The build stamp is written AFTER the seed commit, same as a real build:
  # untracked, never gitignored -- present in every
  # fixture from here on so RED27/RED28's clean-tree cases match a real
  # built fork, not one caught mid-build.
  printf 'ok\n' > "$dir/.himmel-build-ok"
  bare="$dir.git-origin"
  git init -q --bare "$bare"
  git -C "$dir" remote add origin "$bare"
  git -C "$dir" push -q origin HEAD:refs/heads/main
}

# seed_modified_unit <dest> -- one adopter-scripts file whose ledger says
# himmel replaced it (original -> installed, backup taken), then the operator
# edits it again: verdict "keep user-modified", backup readable. Sets BACKUP_SM.
seed_modified_unit() {
  local dest="$1" snap
  mkdir -p "$(dirname "$dest")"
  printf '#!/bin/sh\necho original-user-script\n' > "$dest"
  snap=$(mktemp "$SUITE_TMP/SNAPSM.XXXXXX") || exit 1; cp -p "$dest" "$snap"
  printf '#!/bin/sh\necho himmel-installed-script\n' > "$dest"
  ( prov_begin --writer adopt.sh -- seed-sm >/dev/null
    prov_record replace file "$dest" --scope project --class code --row adopter-scripts \
      --writer adopt.sh --pre-file "$snap" --backup --post-file "$dest" >/dev/null
    prov_end ok >/dev/null )
  rm -f "$snap"
  printf '#!/bin/sh\necho operator-edited-after-install\n' > "$dest"
  BACKUP_SM=$(find "$(prov_dir)/provenance-backups" -type f | head -n1)
}

# seed_created_unit <dest> -- one file himmel CREATED (pre-absent, so no backup),
# then the operator edits it: verdict "keep user-modified", no readable backup,
# which is the shape that offers [k]eep / [d]elete.
seed_created_unit() {
  local dest="$1"
  mkdir -p "$(dirname "$dest")"
  printf '#!/bin/sh\necho himmel-created-script\n' > "$dest"
  ( prov_begin --writer adopt.sh -- seed-created >/dev/null
    prov_record create file "$dest" --scope project --class code --row adopter-scripts \
      --writer adopt.sh --pre-absent --post-file "$dest" >/dev/null
    prov_end ok >/dev/null )
  printf '#!/bin/sh\necho operator-edited-created-file\n' > "$dest"
}

# seed_block <target> [<preexisting-text>] -- install the block with the REAL
# writer (wire_user_claude_md) inside a provenance session, so the ledger holds
# exactly what an S2d install records. <preexisting-text> is written first, so
# the block is APPENDED to a user file (file_created=false); omitted, the target
# is absent and the writer creates it (file_created=true).
BLK_TEMPLATE="$repo_root/docs/setup/user-scope-claude-md-template.md"
BLK_BEGIN='<!-- BEGIN HIMMEL:working-principles -->'
BLK_END='<!-- END HIMMEL:working-principles -->'
seed_block() {
  local target="$1"
  mkdir -p "$(dirname "$target")"
  [ $# -ge 2 ] && printf '%s' "$2" > "$target"
  ( . "$lib/user-claude-md.sh"
    prov_begin --writer adopt.sh -- seed-block >/dev/null
    wire_user_claude_md "$BLK_TEMPLATE" "$target" >/dev/null
    prov_end ok >/dev/null )
}
block_text() { sed -n "/$BLK_BEGIN/,/$BLK_END/p" "$BLK_TEMPLATE"; }
# block_outcomes -- the uninstall outcome rows for block units, "op:reason ..."
block_outcomes() {
  jq -r 'select(.kind=="block" and (.op=="removed" or .op=="kept" or .op=="failed")) | .op + ":" + .reason' \
    "$HIMMEL_PROVENANCE_DIR/provenance.jsonl" 2>/dev/null | tr '\n' ' ' | sed 's/ $//'
}
BLK_UNINSTALL_ARGS=(--yes --keep-telegram-state --skip-tasks --skip-plugins --skip-hooks)

# seed_block_unrecorded <target> [<pre-text>] -- a block with NO ledger row (a
# pre-S2d install): the real writer with prov_record unset in a subshell.
seed_block_unrecorded() {
  local target="$1"
  mkdir -p "$(dirname "$target")"
  [ $# -ge 2 ] && printf '%s' "$2" > "$target"
  ( . "$lib/user-claude-md.sh"
    unset -f prov_record
    wire_user_claude_md "$BLK_TEMPLATE" "$target" >/dev/null )
}

# seed_kept_file <name> -- RED5's fixture: an adopter-script replace whose live
# bytes the operator edited after install (verdict keep user-modified). Sets
# S3_DEST and S3_BACKUP.
seed_kept_file() {
  mkdir -p "$CASE_DIR/cwd/scripts"
  S3_DEST="$CASE_DIR/cwd/scripts/$1.sh"
  printf '#!/bin/sh\necho original-user-script\n' > "$S3_DEST"
  local snap; snap=$(mktemp "$SUITE_TMP/SNAP-$1.XXXXXX") || exit 1
  cp -p "$S3_DEST" "$snap"
  printf '#!/bin/sh\necho himmel-installed-script\n' > "$S3_DEST"
  ( prov_begin --writer adopt.sh -- "seed-$1" >/dev/null
    prov_record replace file "$S3_DEST" --scope project --class code --row adopter-scripts \
      --writer adopt.sh --pre-file "$snap" --backup --post-file "$S3_DEST" >/dev/null
    prov_end ok >/dev/null )
  rm -f "$snap"
  printf '#!/bin/sh\necho operator-edited-after-install\n' > "$S3_DEST"
  S3_BACKUP=$(find "$(prov_dir)/provenance-backups" -type f ! -name '*.ours' 2>/dev/null | head -n1)
}


uninstall_prov_finish() {
  echo "==== REAL-LEDGER TRIPWIRE ===="
  REAL_LEDGER_AFTER=$(real_ledger_state)
  check "tripwire: operator's real ~/.himmel/provenance.jsonl untouched by this suite" \
    "$REAL_LEDGER_AFTER" "$REAL_LEDGER_BEFORE"

  # this suite must not leave a .git in /tmp or $TMPDIR.
  for _p in /tmp/.git "${TMPDIR:-/tmp}/.git"; do
    case " $GIT_LEAK_PRE " in *" $_p "*) continue ;; esac
    [ -e "$_p" ] && check "suite created $_p" present absent
  done

  [ "$fails" -eq 0 ] && echo "UNINSTALL-PROVENANCE ALL PASS" || { echo "failed checks:$failed_labels"; echo "$fails UNINSTALL-PROVENANCE FAILED"; exit 1; }
}
