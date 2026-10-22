#!/usr/bin/env bash
# over-install-guest.sh -- GUEST side of the VM e2e over-install stage.
#
# Runs ON the VM (scripts/vm/over-install-e2e.sh stages the two trees and calls this).
# It proves a candidate himmel install converges over an existing release install:
#   1. base: extract the BASE tree (the previous release tag), `himmelctl install
#      --scope project` from a throwaway project with that tree's own installer,
#      then configure one project, one secret (JIRA_API_TOKEN) and one commit rule
#      (TICKET_ID_PATTERN) through the base tree's own config writer
#   2. over-install: overlay the CANDIDATE tree on the base tree (files the candidate
#      dropped are removed, as an update does) and run `himmelctl install` again
#   3. assert: status has no red row; the secret is still set and its file is 0600;
#      the commit rule and project scope are kept; every settings hook command
#      appears once and matches the hook set a fresh candidate install writes; a
#      second install with nothing changed is a no-op
#
# A bug the stage finds in the base release or in the candidate is REPORTED, never
# fixed here: a migration step belongs to the migration work, not to this test.
#
# Inputs (env): OVERINSTALL_BASE_TGZ and OVERINSTALL_CAND_TGZ (git-archive tarballs).
#   OVERINSTALL_RED=dup-hook   RED control: duplicate one settings hook entry after the
#                              over-install, so the stage must FAIL on "hooks appear once".
#
# Usage: bash scripts/vm/over-install-guest.sh [work-dir]
# Exit: 0 every assertion passed; 1 an assertion failed; 2 bad/missing inputs.
# The final line is `RESULT: N failure(s)`.
#
# Sourced (BASH_SOURCE != $0) it defines only the pure helpers, for the hermetic test.

# --- pure helpers (unit-tested) ----------------------------------------------

# settings_hook_commands <settings.json> -- every hook command, one per line.
settings_hook_commands() {
  jq -r '[.hooks // {} | .[]? | .[]? | .hooks[]? | .command // empty] | .[]' "$1"
}

# settings_dup_hooks <settings.json> -- each hook command that appears more than once,
# as "<count> <command>"; empty output means every hook appears once.
settings_dup_hooks() {
  settings_hook_commands "$1" | sort | uniq -c | awk '$1 > 1 { c = $1; $1 = ""; sub(/^ /, ""); print c, $0 }'
}

# settings_hook_set_diff <expected-settings.json> <actual-settings.json> -- hook commands
# missing from or extra in the actual file, as diff lines ("< " expected only, "> " actual
# only); empty output means both files carry the same hook commands the same number of times.
settings_hook_set_diff() {
  diff <(settings_hook_commands "$1" | sort) <(settings_hook_commands "$2" | sort) | grep -E '^[<>]' || true
}

# status_red_count <himmelctl-status-output> -- the red count from the summary line
# ("N red, N degraded, N green, N n/a"); empty when the line is absent, so a truncated
# capture can never read as "no errors".
status_red_count() {
  sed -n 's/.*[^0-9]\([0-9][0-9]*\) red, .*/\1/p;s/^\([0-9][0-9]*\) red, .*/\1/p' <<<"$1" | head -1
}

# status_red_rows <himmelctl-status-output> -- the rows that are red, for the failure text.
status_red_rows() {
  grep -E '^(red|RED)\b|\bred\b.*:' <<<"$1" | grep -Ev '[0-9]+ red,' || true
}

# file_mode <path> -- octal permission bits.
file_mode() { stat -c '%a' "$1"; }  # gnu-ok: the guest is Linux

# --- stage -------------------------------------------------------------------

[ "${BASH_SOURCE[0]}" = "$0" ] || return 0

set -uo pipefail

fails=0
pass() { echo "PASS $1"; }
fail() { echo "FAIL $1"; fails=$((fails + 1)); }
note() { echo "NOTE $1"; }
verdict() { echo "RESULT: $fails failure(s)"; [ "$fails" -eq 0 ]; exit $?; }

WORK="${1:-$HOME/over-install}"
BASE_TGZ="${OVERINSTALL_BASE_TGZ:-}"
CAND_TGZ="${OVERINSTALL_CAND_TGZ:-}"
RED="${OVERINSTALL_RED:-}"
for f in "$BASE_TGZ" "$CAND_TGZ"; do
  if [ -z "$f" ] || [ ! -s "$f" ]; then
    echo "over-install-guest: OVERINSTALL_BASE_TGZ / OVERINSTALL_CAND_TGZ must name tarballs (got '$f')" >&2
    echo "RESULT: 1 failure(s)"; exit 2
  fi
done
case "$RED" in ''|dup-hook) ;; *) echo "over-install-guest: unknown OVERINSTALL_RED '$RED'" >&2; exit 2 ;; esac
command -v jq >/dev/null 2>&1 || { echo "over-install-guest: jq is required" >&2; exit 2; }

TREE="$WORK/hm"
PROJ="$WORK/proj"
CACHE="$HOME/.claude/himmel"
SECRET="over-install-throwaway-secret"
RULE='OVR-[0-9]+'

# Everything the stage writes lives under $WORK plus the himmelctl state dirs, which a
# restored himmel-ar clone discards; clean the state a previous run left.
rm -rf "$WORK" "$HOME/.himmel" "$CACHE"
mkdir -p "$TREE" "$PROJ"
tar -xzf "$BASE_TGZ" -C "$TREE" || { echo "over-install-guest: cannot extract the base tree" >&2; exit 2; }
git -C "$PROJ" init -q -b main
git -C "$PROJ" -c user.email=ovr@example.invalid -c user.name=ovr commit -q --allow-empty -m init

ctl() { # run the tree's himmelctl from the project, in a clean environment
  ( cd "$PROJ" && env -i HOME="$HOME" PATH="$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin" \
      HIMMELCTL_CACHE_DIR="$CACHE" node "$TREE/scripts/himmelctl/bin.js" "$@" )
}

echo "==> 1. base install (the previous release's own installer)"
ctl install --scope project > "$WORK/install-base.log" 2>&1; rc=$?
if [ "$rc" -eq 0 ]; then pass "base install exits 0"; else fail "base install exits 0 (rc=$rc)"; tail -20 "$WORK/install-base.log"; verdict; fi

# Configure: one secret and one commit rule via the base tree's own writer; the four
# JIRA_* keys so the core feature is fully configured and `status` has nothing red to
# blame on a half-filled fixture. The env file is created 0600, the mode the secret
# contract requires (the base writer leaves a fresh file group-readable -- reported
# below, not fixed here).
ENVF="$TREE/.env"
: > "$ENVF"
setv() { bash "$TREE/scripts/lib/set-env-var.sh" "$1" "$2" --env-file "$ENVF" >/dev/null; }
setv JIRA_API_TOKEN "$SECRET"
setv JIRA_BASE_URL https://over-install.invalid
setv JIRA_EMAIL ovr@example.invalid
setv JIRA_PROJECT_KEY OVR
setv TICKET_ID_PATTERN "$RULE"
note "base writer left $ENVF at mode $(file_mode "$ENVF") (installed fresh, no chmod)"
chmod 600 "$ENVF"

scope_before="$(ctl scope get 2>&1 | head -1)"
status_before="$(ctl status 2>&1)"
red_before="$(status_red_count "$status_before")"
note "base status: red=${red_before:-?} ; scope=$scope_before"

echo "==> 2. over-install (candidate tree over the base tree)"
tar -tzf "$BASE_TGZ" | sort > "$WORK/base.lst"
tar -tzf "$CAND_TGZ" | sort > "$WORK/cand.lst"
comm -23 "$WORK/base.lst" "$WORK/cand.lst" | grep -v '/$' | while IFS= read -r f; do rm -f "$TREE/$f"; done
tar -xzf "$CAND_TGZ" -C "$TREE" || { echo "over-install-guest: cannot extract the candidate tree" >&2; exit 2; }
ctl install --scope project > "$WORK/install-over.log" 2>&1; rc=$?
if [ "$rc" -eq 0 ]; then pass "over-install exits 0"; else fail "over-install exits 0 (rc=$rc)"; tail -20 "$WORK/install-over.log"; fi

SETTINGS="$PROJ/.claude/settings.json"

# The hook set a fresh candidate install writes, for the "same hooks" assertion below.
PROJ2="$WORK/proj-fresh"
mkdir -p "$PROJ2"
git -C "$PROJ2" init -q -b main
git -C "$PROJ2" -c user.email=ovr@example.invalid -c user.name=ovr commit -q --allow-empty -m init
( cd "$PROJ2" && env -i HOME="$HOME" PATH="$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin" \
    HIMMELCTL_CACHE_DIR="$CACHE" node "$TREE/scripts/himmelctl/bin.js" install --scope project ) > "$WORK/install-fresh.log" 2>&1; rc=$?
if [ "$rc" -eq 0 ]; then pass "fresh candidate install exits 0"; else fail "fresh candidate install exits 0 (rc=$rc)"; tail -20 "$WORK/install-fresh.log"; fi
FRESH_SETTINGS="$PROJ2/.claude/settings.json"

if [ "$RED" = "dup-hook" ]; then
  # RED control: duplicate the first hook entry of the first event, as a broken
  # merge would; the "hooks appear once each" assertion below must catch it.
  jq '(.hooks | to_entries[0]) as $e | .hooks[$e.key] += [$e.value[0]]' "$SETTINGS" > "$WORK/settings.dup" \
    && cp "$WORK/settings.dup" "$SETTINGS"
  note "RED control: duplicated one hook entry in $SETTINGS"
fi

if [ "${OVERINSTALL_DUMP_SETTINGS:-0}" = 1 ] && [ -s "$SETTINGS" ]; then
  echo "--- settings.json (project) ---"; jq . "$SETTINGS"; echo "--- end settings.json ---"
fi

echo "==> 3. assertions"
status_after="$(ctl status 2>&1)"
red_after="$(status_red_count "$status_after")"
if [ -z "$red_after" ]; then
  fail "status printed no summary line (cannot show 'no errors')"
elif [ "$red_after" -eq 0 ]; then
  pass "status has no red row (red=0)"
else
  fail "status has no red row (red=$red_after)"; status_red_rows "$status_after" | head -10
fi

if [ "$(grep -c "^JIRA_API_TOKEN=$SECRET\$" "$ENVF")" = 1 ]; then pass "secret still set"; else fail "secret still set"; fi
if [ "$(file_mode "$ENVF")" = 600 ]; then pass "secret file is mode 0600"; else fail "secret file is mode 0600 (is $(file_mode "$ENVF"))"; fi

# shellcheck disable=SC2016  # the bash -c body is single-quoted on purpose
rule_now="$( ( cd "$TREE" && env -i HOME="$HOME" PATH="$PATH" bash -c '. scripts/lib/load-dotenv.sh; load_dotenv TICKET_ID_PATTERN 2>/dev/null; printf %s "${TICKET_ID_PATTERN:-}"' ) )"
if [ "$rule_now" = "$RULE" ]; then pass "commit rule kept (TICKET_ID_PATTERN=$rule_now)"; else fail "commit rule kept (got '$rule_now', want '$RULE')"; fi

scope_after="$(ctl scope get 2>&1 | head -1)"
case "$scope_after" in *project*) scope_is_project=1 ;; *) scope_is_project=0 ;; esac
if [ "$scope_is_project" = 1 ] && [ "$scope_after" = "$scope_before" ]; then pass "project scope kept ($scope_after)"; else fail "project scope kept (before '$scope_before', after '$scope_after')"; fi

if [ ! -s "$SETTINGS" ]; then
  fail "settings hooks appear once each (no $SETTINGS)"
else
  n_hooks="$(settings_hook_commands "$SETTINGS" | wc -l)"
  dups="$(settings_dup_hooks "$SETTINGS")"
  if [ "$n_hooks" -gt 0 ] && [ -z "$dups" ]; then pass "settings hooks appear once each ($n_hooks hook commands)"
  else fail "settings hooks appear once each ($n_hooks hook commands; duplicated: ${dups:-none, but no hooks found})"; fi
  hook_diff="$(settings_hook_set_diff "$FRESH_SETTINGS" "$SETTINGS")"
  if [ -s "$FRESH_SETTINGS" ] && [ -z "$hook_diff" ]; then pass "settings hooks match a fresh candidate install"
  else fail "settings hooks match a fresh candidate install (diff vs fresh: ${hook_diff:-no fresh settings})"; fi
fi

# no-op: snapshot the user-visible state, install again, compare. The provenance ledger
# and its per-run backup/uninstall bookkeeping change on every install by design.
snap() { ( cd "$WORK" && find proj/.claude proj/scripts hm/.env "$HOME/.claude.json" "$HOME/.claude/settings.json" "$HOME/.himmel/himmel.conf" \
    -type f 2>/dev/null | sort | xargs -r sha256sum ); }
snap > "$WORK/snap-a.txt"
ctl install --scope project > "$WORK/install-again.log" 2>&1; rc=$?
snap > "$WORK/snap-b.txt"
if [ "$rc" -ne 0 ]; then fail "second install exits 0 (rc=$rc)"
elif diff "$WORK/snap-a.txt" "$WORK/snap-b.txt" > "$WORK/snap.diff"; then pass "second install is a no-op ($(wc -l < "$WORK/snap-a.txt") files unchanged)"
else fail "second install is a no-op"; head -10 "$WORK/snap.diff"; fi

verdict
