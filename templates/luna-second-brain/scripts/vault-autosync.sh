#!/usr/bin/env bash
# vault-autosync.sh — OPT-IN auto-commit + push for a luna-brain vault.
#
# OFF by default. A vault's content IS the product, so when enabled this stages
# everything (`git add -A`) and commits THROUGH pre-commit — NEVER `--no-verify`
# — so the vault's gitleaks + secret hooks BLOCK any commit containing an API
# key BEFORE it can be committed or pushed. `.gitignore` (.env, .single-writer,
# …) is the second layer. Push targets the configured remote only.
#
# Enable explicitly (the operator sets the flag; it is never defaulted on):
#   LUNA_VAULT_AUTOSYNC=1 bash scripts/vault-autosync.sh
#
# Behaviour:
#   OFF                  → no commit, no push, no network.
#   ON  + no remote      → logged no-op (autosync = push; nothing to push to).
#   ON  + remote         → git add -A; commit (through pre-commit); push.
#
# Stall alert: a pre-commit hook that keeps refusing the pending
# changes stops the vault committing without a word. Once the refusals have
# gone on for LUNA_VAULT_STALL_THRESHOLD_MIN minutes (default 30) the operator
# is alerted ONCE per stall episode, naming the failing hook and file. An
# episode starts at the first refused run and ends at the next commit or clean
# tree. Delivery is pluggable: LUNA_VAULT_ALERT_CMD names an executable that is
# called with one argument, the message. Unset → the stall is only logged. A
# sink that exits non-zero leaves the episode un-alerted, so the next run retries.
#
# Stall reason + tool-state self-heal: every refused run records
# `<hook id>:<first file>` in <git-dir>/vault-autosync-reason (cleared with the
# episode) so vault-status.sh can print STALL:<age>,<n>,<reason>. When EVERY file
# the hooks refused is browser-profile / tool state that is new to the vault
# (a Chrome Default/Preferences holds tokens), those files and any other staged
# tool state are unstaged, moved to LUNA_VAULT_QUARANTINE_DIR (default
# ~/.himmel/state/vault-quarantine)/<utc-stamp>/, and the commit is retried
# once. Anything else stays a STALL for the operator.
set -uo pipefail

log() { echo "[vault-autosync] $*"; }

_stall_file=""
_reason_file=""
_stall_clear() {
  [ -z "$_stall_file" ] || rm -f "$_stall_file"
  [ -z "$_reason_file" ] || rm -f "$_reason_file"
}

# pre-commit prints `- hook id: <id>` per failing hook; a hook that reports the
# file says `In <file> line N:` (shellcheck) or `File: <file>` (gitleaks).
_refused_files() { # <captured output>: every file the hooks named, one per line
  printf '%s\n' "$1" | sed -n -e 's/^In \(.*\) line [0-9]*:$/\1/p' -e 's/^File:[[:space:]]*//p'
}
_stall_reason() { # <captured output>: record `<hook>:<first file>` for vault-status.sh
  local hook file
  hook="$(printf '%s\n' "$1" | sed -n 's/^- hook id: //p' | head -n1)"
  file="$(_refused_files "$1" | head -n1)"
  [ -n "$_reason_file" ] || return 0
  printf '%s:%s\n' "${hook:-none}" "${file:-none}" | tr -c 'A-Za-z0-9._/:+\n-' '_' >"$_reason_file"
}

# Browser-profile / tool state that never belongs in a vault.
_tool_state() { # <repo-relative path>
  case "/$1" in
    */Default/Preferences | */Default/Secure\ Preferences | */Local\ State | \
      */Default/Cache/* | */Default/Code\ Cache/* | */Default/GPUCache/* | */Default/*-journal) return 0 ;;
  esac
  return 1
}

# Heal a refusal caused only by new tool-state files: unstage them and move them
# out of the vault. Returns 0 when something was quarantined, 1 otherwise.
_heal_tool_state() { # <captured output of the refused commit>
  local refused f stamp dest n=0
  local -a move=()
  refused="$(_refused_files "$1")"
  [ -n "$refused" ] || return 1
  while IFS= read -r f; do
    _tool_state "$f" || return 1
    ! git cat-file -e "HEAD:$f" 2>/dev/null || return 1 # a tracked file is not ours to move
  done <<EOF
$refused
EOF
  while IFS= read -r -d '' f; do
    if _tool_state "$f" && ! git cat-file -e "HEAD:$f" 2>/dev/null; then move+=("$f"); fi
  done < <(git diff --cached --name-only -z)
  [ "${#move[@]}" -gt 0 ] || return 1
  stamp="$(date -u +%Y%m%dT%H%M%SZ)"
  dest="${LUNA_VAULT_QUARANTINE_DIR:-${HOME:-/tmp}/.himmel/state/vault-quarantine}/$stamp"
  for f in "${move[@]}"; do
    mkdir -p "$dest/$(dirname "$f")" || return 1
    git rm -q --cached -- "$f" || return 1
    mv -- "$f" "$dest/$f" || return 1
    n=$((n + 1))
  done
  log "quarantined $n tool-state file(s) to $dest (a browser profile or tool state must not enter the vault)." >&2
  return 0
}

# Called with the refused commit's captured output. Records the episode's start,
# and once it is older than the threshold alerts through LUNA_VAULT_ALERT_CMD.
_stall_note() {
  local out="$1" now first="" alerted="" thr hook file msg
  now="$(date +%s)"
  if [ -f "$_stall_file" ]; then
    { IFS= read -r first; IFS= read -r alerted; } <"$_stall_file"
  fi
  case "$first" in '' | *[!0-9]*)
    first="$now"
    alerted=""
    ;;
  esac
  printf '%s\n%s\n' "$first" "$alerted" >"$_stall_file"
  [ "$alerted" = "alerted" ] && return 0

  thr="${LUNA_VAULT_STALL_THRESHOLD_MIN:-30}"
  case "$thr" in '' | *[!0-9]*) thr=30 ;; esac
  thr=$((10#$thr)) # a zero-padded value (08) is decimal, not an invalid octal
  [ $((now - first)) -ge $((thr * 60)) ] || return 0

  hook="$(printf '%s\n' "$out" | sed -n 's/^- hook id: //p' | head -n1)"
  file="$(_refused_files "$out" | head -n1)"
  msg="vault-autosync STALL: commit refused (hook: ${hook:-none reported}, file: ${file:-none reported}) for $(((now - first) / 60)) min in $REPO_ROOT - pending changes are not being committed."
  log "$msg" >&2
  if [ -z "${LUNA_VAULT_ALERT_CMD:-}" ]; then
    log "LUNA_VAULT_ALERT_CMD is not set - no operator alert sent." >&2
  elif "$LUNA_VAULT_ALERT_CMD" "$msg"; then
    printf '%s\nalerted\n' "$first" >"$_stall_file"
  else
    log "alert sink failed - will retry next run." >&2
  fi
  return 0
}

# --- flag gate (default OFF) -------------------------------------------------
_flag="$(printf '%s' "${LUNA_VAULT_AUTOSYNC:-}" | tr '[:upper:]' '[:lower:]')"
case "$_flag" in
  1 | true | on | yes) ;;
  *)
    log "LUNA_VAULT_AUTOSYNC is off — no commit, no push, no network. (set LUNA_VAULT_AUTOSYNC=1 to enable)"
    exit 0
    ;;
esac

# Resolve repo root (works from anywhere in the vault).
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || {
  log "not inside a git repo — nothing to sync."
  exit 0
}
cd "$REPO_ROOT" || exit 1
_stall_file="$(git rev-parse --git-dir 2>/dev/null)/vault-autosync-stall"
_reason_file="$(git rev-parse --git-dir 2>/dev/null)/vault-autosync-reason"

# github-sync races this script's own commits — both stage,
# commit and push the same vault on their own schedules. Mutually exclusive;
# refuse to run rather than let two writers fight over the same tree.
if [ -f "$REPO_ROOT/.obsidian/community-plugins.json" ] && grep -q '"github-sync"' "$REPO_ROOT/.obsidian/community-plugins.json"; then
  log "github-sync is enabled in this vault — refusing to run (mutually exclusive, HIMMEL-3066). Disable one of the two sync mechanisms."
  exit 0
fi

# ON requires a remote — autosync's whole job is to push. No remote → no-op.
if [ -z "$(git remote)" ]; then
  log "enabled but no remote is configured — nothing to push (no-op)."
  exit 0
fi

# Nothing staged/unstaged/untracked → nothing to do.
if [ -z "$(git status --porcelain)" ]; then
  _stall_clear
  log "working tree clean — nothing to commit."
  exit 0
fi

# The commit lands on `main` (a vault is single-writer by design); the
# worktree-isolation guard requires the `.single-writer` marker for that.
# Enabling LUNA_VAULT_AUTOSYNC is the operator's explicit opt-in to autosync,
# so ensure the marker exists — a clone WITH a remote won't have one (setup
# leaves clones as-is), and without it this commit would be hard-blocked.
if [ ! -f "$REPO_ROOT/.single-writer" ]; then
  touch "$REPO_ROOT/.single-writer"
  log "created .single-writer (autosync commits to main; the flag is your opt-in)."
fi

# Stage the whole vault — its content is the product.
if ! git add -A; then
  log "git add -A failed — NOT committing or pushing." >&2
  exit 1
fi

# Commit THROUGH pre-commit (NEVER --no-verify): the gitleaks/secret hooks are
# the egress guard. A blocked commit (e.g. an API key slipped in) exits non-zero
# here, and because the push below is gated on this success, nothing leaves.
#
# A pre-commit AUTO-FIXER (e.g. end-of-file-fixer on a staged code/config file) may
# modify a staged file, which aborts the commit and leaves the tree dirty — at a
# glance indistinguishable from a real block. So retry ONCE: re-stage the fixer's
# changes and commit again. A genuine gitleaks/secret rejection survives both
# passes (gitleaks never auto-fixes, so the second commit fails too) and still
# aborts the push — the egress guard is fully preserved.
# The output is captured so a stall alert can name the hook and file, then shown.
_commit_out=""
_commit() {
  local rc
  _commit_out="$(git commit -q -m "chore: vault autosync" 2>&1)"
  rc=$?
  [ -z "$_commit_out" ] || printf '%s\n' "$_commit_out" >&2
  return "$rc"
}
if ! _commit; then
  if [ -z "$(git status --porcelain)" ]; then
    _stall_clear
    log "nothing to commit after hooks ran — no-op."
    exit 0
  fi
  # A hook auto-fixed files — re-stage and retry once.
  git add -A
  if ! _commit; then
    if [ -z "$(git status --porcelain)" ]; then
      _stall_clear
      log "nothing to commit after retry — no-op."
      exit 0
    fi
    # Tool state only (a browser profile)? Quarantine it and commit the rest, once.
    _blocked=1
    if _heal_tool_state "$_commit_out"; then
      if [ -z "$(git status --porcelain)" ]; then
        _stall_clear
        log "nothing left to commit after the quarantine — no-op."
        exit 0
      fi
      ! _commit || _blocked=0
    fi
    if [ "$_blocked" = 1 ]; then
      log "commit BLOCKED by pre-commit (secret detected, or a hook keeps modifying files) — NOT pushing." >&2
      _stall_reason "$_commit_out"
      _stall_note "$_commit_out"
      exit 1
    fi
  fi
fi
_stall_clear
log "committed."

_remote="$(git remote | head -n1)"
_branch="$(git rev-parse --abbrev-ref HEAD)"
if git push "$_remote" "$_branch"; then
  log "pushed to $_remote/$_branch."
else
  log "push to $_remote/$_branch failed." >&2
  exit 1
fi
