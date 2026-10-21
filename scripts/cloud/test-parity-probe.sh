#!/usr/bin/env bash
# test-parity-probe.sh — scripts/cloud/parity-probe.sh. Hermetic:
# --no-net, so no request leaves the machine. The fixture for the guard rows is
# the repo's own .claude/settings.json and scripts/hooks/, the real environment.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PROBE="$ROOT/scripts/cloud/parity-probe.sh"
fails=0
ok() { echo "PASS - $1"; }
bad() { echo "FAIL - $1"; fails=$((fails + 1)); }

[ -f "$PROBE" ] || { echo "FAIL - $PROBE missing (every case below would pass or fail vacuously)"; exit 1; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/parity-probe-test.XXXXXX")" || { echo "mktemp -d failed" >&2; exit 1; }
trap 'rm -rf "$TMP"' EXIT
# The probe reports `at -V`; a stub answers it so no run calls the real scheduler.
mkdir -p "$TMP/bin"; printf '#!/bin/sh\n[ "$*" = "-V" ] || { echo "unexpected at arguments: $*" >&2; exit 2; }\necho "at version 0.0-stub"\n' > "$TMP/bin/at"; chmod +x "$TMP/bin/at"
export PATH="$TMP/bin:$PATH"

# 1. a clean run exits 0 and every row is `item<TAB>value` under a ## section.
OUT="$(bash "$PROBE" --no-net 2>&1)"; RC=$?
if [ "$RC" -eq 0 ]; then ok "probe exits 0"; else bad "probe rc=$RC: $OUT"; fi
malformed="$(printf '%s\n' "$OUT" | awk -F'\t' 'NF == 0 || /^## / { next } NF < 2 || $1 == "" { print }')"
if [ -z "$malformed" ]; then ok "every row is item<TAB>value"; else bad "malformed rows: $malformed"; fi
for sec in environment settings plugins guards gates tools jira egress; do
  case "$OUT" in *"## $sec"*) ok "section $sec present" ;; *) bad "section $sec missing" ;; esac
done

# 2. each PreToolUse deny probe is refused in this tree (a gap shows as ALLOW).
guards="$(printf '%s\n' "$OUT" | grep '^guard:')"
n="$(printf '%s\n' "$guards" | grep -c .)"
if [ "$n" -ge 9 ]; then ok "$n guard rows"; else bad "only $n guard rows: $guards"; fi
notdeny="$(printf '%s\n' "$guards" | grep -v $'\tDENY$' || true)"
if [ -z "$notdeny" ]; then ok "every guard probe is refused"; else bad "guard not refusing: $notdeny"; fi

# 3. a session bypass variable is reported on its own row and does not mask the
# guard probe (the probe unsets it, so the row still proves the script denies).
OUT2="$(GIT_STASH_OK=1 bash "$PROBE" --no-net 2>&1)"
case "$OUT2" in *$'guard:block-git-stash\tDENY'*) ok "bypass variable does not mask the guard probe" ;; *) bad "stash guard row not DENY under GIT_STASH_OK: $OUT2" ;; esac
case "$OUT2" in *$'bypass-env-set\t GIT_STASH_OK'*) ok "bypass variable is listed" ;; *) bad "bypass variable not listed" ;; esac
# control that can fail: a guard that exits 0 on its input reads ALLOW.
mkdir -p "$TMP/lax/scripts/hooks"
printf '#!/bin/sh\nexit 0\n' > "$TMP/lax/scripts/hooks/block-git-stash.sh"
OUT4="$(HIMMEL_CLOUD_ROOT="$TMP/lax" bash "$PROBE" --no-net 2>&1)"
case "$OUT4" in *$'guard:block-git-stash\tALLOW'*) ok "a guard that does not refuse reads ALLOW" ;; *) bad "lax guard not ALLOW: $OUT4" ;; esac

# 3b. a commit-msg gate that never decided (timeout rc 124) is ERR, not DENY.
printf '#!/bin/sh\nexit 124\n' > "$TMP/lax/scripts/hooks/check-commit-msg.sh"
OUT6="$(HIMMEL_CLOUD_ROOT="$TMP/lax" bash "$PROBE" --no-net 2>&1)"
case "$OUT6" in *$'attest:commit-msg-refuses-no-ticket\tERR rc=124'*) ok "a gate that timed out reads ERR, not DENY" ;; *) bad "timeout read as: $(printf '%s\n' "$OUT6" | grep 'commit-msg-refuses')" ;; esac
printf '#!/bin/sh\nexit 1\n' > "$TMP/lax/scripts/hooks/check-commit-msg.sh"
OUT7="$(HIMMEL_CLOUD_ROOT="$TMP/lax" bash "$PROBE" --no-net 2>&1)"
case "$OUT7" in *$'attest:commit-msg-refuses-no-ticket\tDENY rc=1'*) ok "a refusing gate reads DENY" ;; *) bad "refusal read as: $(printf '%s\n' "$OUT7" | grep 'commit-msg-refuses')" ;; esac
printf '#!/bin/sh\nexit 139\n' > "$TMP/lax/scripts/hooks/check-commit-msg.sh"
OUT8="$(HIMMEL_CLOUD_ROOT="$TMP/lax" bash "$PROBE" --no-net 2>&1)"
case "$OUT8" in *$'attest:commit-msg-refuses-no-ticket\tERR rc=139'*) ok "a crashed gate reads ERR, not DENY" ;; *) bad "crash read as: $(printf '%s\n' "$OUT8" | grep 'commit-msg-refuses')" ;; esac

# 3c. a base URL alone is not a Jira credential.
OUT9="$(env -u JIRA_API_TOKEN -u JIRA_TOKEN JIRA_BASE_URL=https://example.invalid bash "$PROBE" --no-net 2>&1)"
case "$OUT9" in *$'jira-token-set\tno'*) ok "JIRA_BASE_URL alone leaves jira-token-set no" ;; *) bad "url-only read as: $(printf '%s\n' "$OUT9" | grep 'jira-token-set')" ;; esac

# 4. an empty tree: missing guards read MISSING, not DENY, and the run survives.
mkdir -p "$TMP/empty"
OUT3="$(HIMMEL_CLOUD_ROOT="$TMP/empty" bash "$PROBE" --no-net 2>&1)"; RC=$?
if [ "$RC" -eq 0 ]; then ok "empty tree exits 0"; else bad "empty tree rc=$RC"; fi
case "$OUT3" in *$'guard:block-git-stash\tMISSING'*) ok "absent guard reads MISSING" ;; *) bad "absent guard not MISSING: $OUT3" ;; esac

# 4b. A cloud run: qmd was installed but had no shim on PATH, and
# graphify sat at 0.9.77 against a 0.9.80 pin. The qmd row resolves through
# qmd-bounded.sh; graphify-at-pin names the drift.
QB="$TMP/qbin"; mkdir -p "$QB" "$TMP/qfix/scripts/lib"
for t in bash env sh grep sed tr cut head tail awk sort wc cat rm mktemp date uname id sha256sum dirname basename find timeout; do
  p="$(command -v "$t" 2>/dev/null)" && [ -n "$p" ] && ln -sf "$p" "$QB/$t"
done
# shellcheck disable=SC2016  # $1 belongs to the stub script
printf '#!/bin/sh\n[ "$1" = "--version" ] && echo "qmd 9.9.9"\nexit 0\n' > "$TMP/qfix/scripts/lib/qmd-bounded.sh"
printf '#!/bin/sh\necho "graphify 0.9.77"\n' > "$QB/graphify"; chmod +x "$QB/graphify"
# shellcheck disable=SC2016  # literal fixture text
printf '%s\n' '_graphify_version() { echo "${GRAPHIFY_VERSION:-0.9.80}"; }' > "$TMP/qfix/scripts/lib/graphify-bin.sh"
OUT5="$(env -i PATH="$QB" HIMMEL_CLOUD_ROOT="$TMP/qfix" "$QB/bash" "$PROBE" --no-net 2>&1)"
case "$OUT5" in *$'tool:qmd\tqmd 9.9.9 (not on PATH, via qmd-bounded.sh)'*) ok "qmd off PATH resolves through qmd-bounded.sh" ;; *) bad "qmd off PATH read absent: $(printf '%s\n' "$OUT5" | grep 'tool:qmd')" ;; esac
case "$OUT5" in *$'graphify-at-pin\tNO installed=0.9.77 pin=0.9.80'*) ok "graphify off the pin is named" ;; *) bad "graphify drift not named: $(printf '%s\n' "$OUT5" | grep 'graphify')" ;; esac
# the fork stamp is part of the pin: the base alone is off it, the stamped build is on it.
# shellcheck disable=SC2016  # literal fixture text
printf '%s\n' '_graphify_version() { echo "${GRAPHIFY_VERSION:-0.9.93+himmel.1}"; }' > "$TMP/qfix/scripts/lib/graphify-bin.sh"
printf '#!/bin/sh\necho "graphify 0.9.93"\n' > "$QB/graphify"
OUT6="$(env -i PATH="$QB" HIMMEL_CLOUD_ROOT="$TMP/qfix" "$QB/bash" "$PROBE" --no-net 2>&1)"
case "$OUT6" in *$'graphify-at-pin\tNO installed=0.9.93 pin=0.9.93+himmel.1'*) ok "upstream base is off the fork-stamped pin" ;; *) bad "fork stamp not in the pin: $(printf '%s\n' "$OUT6" | grep 'graphify')" ;; esac
printf '#!/bin/sh\necho "graphify 0.9.93+himmel.1"\n' > "$QB/graphify"
OUT7="$(env -i PATH="$QB" HIMMEL_CLOUD_ROOT="$TMP/qfix" "$QB/bash" "$PROBE" --no-net 2>&1)"
case "$OUT7" in *$'graphify-at-pin\tyes'*) ok "the stamped fork build is at the pin" ;; *) bad "stamped build not at the pin: $(printf '%s\n' "$OUT7" | grep 'graphify')" ;; esac

# 5. read-only: the tree and the scratch dir are unchanged by a run.
before="$(git -C "$ROOT" status --porcelain 2>/dev/null | { sha256sum 2>/dev/null || shasum -a 256; })"
TMPDIR="$TMP" bash "$PROBE" --no-net >/dev/null 2>&1
after="$(git -C "$ROOT" status --porcelain 2>/dev/null | { sha256sum 2>/dev/null || shasum -a 256; })"
if [ "$before" = "$after" ]; then ok "run leaves the work tree untouched"; else bad "probe changed the work tree"; fi
leftover="$(find "$TMP" -mindepth 1 -maxdepth 1 -name 'parity-msg.*' | wc -l | tr -d ' ')"  # gnu-ok: BSD find has -maxdepth/-mindepth
if [ "$leftover" = "0" ]; then ok "run leaves no scratch file"; else bad "$leftover scratch file(s) left"; fi

# 6. an unknown flag is refused (rc 2).
bash "$PROBE" --nope >/dev/null 2>&1; rc=$?
if [ "$rc" -eq 2 ]; then ok "unknown flag exits 2"; else bad "unknown flag rc=$rc"; fi

# 7. syntax + lint.
if bash -n "$PROBE"; then ok "bash -n clean"; else bad "bash -n failed"; fi
if command -v shellcheck >/dev/null 2>&1; then
  if shellcheck "$PROBE" >/dev/null 2>&1; then ok "shellcheck clean"; else bad "shellcheck findings"; fi
else
  echo "SKIP - shellcheck not installed here"
fi

if [ "$fails" -ne 0 ]; then echo "$fails check(s) failed."; exit 1; fi
echo "all checks passed."
