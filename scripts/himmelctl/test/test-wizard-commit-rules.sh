#!/usr/bin/env bash
# test-wizard-commit-rules.sh — hermetic tests: the frame-11
# install wording and the Commit rules step (journey J7 of the docs-site plan).
#
# Covers:
#   1. J7 jira+required  -> TRACKER=jira and TICKET_ID_REQUIRED=1 land in the
#      temp ~/.himmel/himmel.conf (and nothing else changes in it).
#   2. J7 none           -> TRACKER=none lands; "ticket ID required" is never asked.
#   3. --dry-run         -> prints the would-write line, writes no file.
#   4. declining consent -> writes no file.
#   5. frame-11 wording  -> starter help text, operator hidden without
#      --contribute, pluginSet not asked, starter offers only the doctor
#      cadence, summary ends with "commit these files on a branch".
#   6. J7 gate row       -> pending on the commit-msg gate work (stated, not run).
#
# Every run uses a temp HOME; the operator's real ~/.himmel is never touched.

set -uo pipefail

repo_root=$(git rev-parse --show-toplevel)
. "$repo_root/scripts/himmelctl/test/_hermetic-home.sh"
wizard="$repo_root/scripts/himmelctl/bin.js"
[ -f "$wizard" ] || { echo "FAIL: $wizard not found" >&2; exit 1; }
command -v node >/dev/null 2>&1 || { echo "FAIL: node required" >&2; exit 1; }

fail() { echo "FAIL: $1" >&2; exit 1; }
grepq() { local _t="$1"; shift; grep -q "$@" <<< "$_t"; }

node_bin=$(command -v node)
export HIMMELCTL_BASH=bash
# shellcheck source=../../lib/hermetic-path.sh
# shellcheck disable=SC1091
. "$repo_root/scripts/lib/hermetic-path.sh"

work=$(mktemp -d "${TMPDIR:-/tmp}/wizard-commit-rules.XXXXXX") || fail "mktemp -d failed"
trap 'rm -rf "$work"' EXIT
cwd="$work/cwd"; mkdir -p "$cwd"; cd "$cwd" || exit 1
HIMMELCTL_BIN_DIR="$(winpath "$work/isolated-bin")"
export HIMMELCTL_BIN_DIR

stub="$work/stub"; mkdir -p "$stub"
link_hermetic_tool bash "$stub"; link_hermetic_tool jq "$stub"; link_hermetic_tool python3 "$stub"; link_hermetic_tool npm "$stub"
tpath="$stub:$PATH"

fixture="$work/fixture"; mkdir -p "$fixture/scripts"
printf '#!/usr/bin/env bash\nexit 0\n' > "$fixture/scripts/adopt.sh"
cp "$fixture/scripts/adopt.sh" "$fixture/scripts/setup.sh"
chmod +x "$fixture/scripts/adopt.sh" "$fixture/scripts/setup.sh"

# run_wizard <home-dir> <args...>  (stdin = the answers)
run_wizard() {
  local _h="$1"; shift
  PATH="$tpath" HOME="$_h" USERPROFILE="$(winpath "$_h")" HIMMELCTL_CACHE_DIR="$(winpath "$_h.cache")" \
    HIMMEL_LUNA_CONFIG_PATH="$(winpath "$_h.cache/luna-config.json")" HIMMELCTL_INTERACTIVE=1 \
    HIMMELCTL_REPO_ROOT="$(winpath "$fixture")" \
    "$node_bin" "$wizard" install "$@" 2>&1
}

# run_apply <home-dir> <commitRules-json|''>  (non-interactive --from-profile install;
# the interactive Proceed confirm reads EOF as 'n', so apply cases replay a profile)
run_apply() {
  local _h="$1" _cr="$2" _p _extra=""
  _p="$work/profile-$(basename "$1").json"
  [ -n "$_cr" ] && _extra=",\"commitRules\":$_cr"
  printf '{"schemaVersion":2,"profile":"starter","devOverlay":false,"scope":"project","vault":{"mode":"none","path":""},"handover":{"mode":"inline","path":""},"pluginSet":"lean","lanes":[],"lanesMeaningful":true,"alwaysOn":false,"channel":"stable"%s}\n' "$_extra" > "$_p"
  PATH="$tpath" HOME="$_h" USERPROFILE="$(winpath "$_h")" HIMMELCTL_CACHE_DIR="$(winpath "$_h.cache")" \
    HIMMEL_LUNA_CONFIG_PATH="$(winpath "$_h.cache/luna-config.json")" HIMMELCTL_INTERACTIVE=0 \
    HIMMELCTL_REPO_ROOT="$(winpath "$fixture")" \
    "$node_bin" "$wizard" install --from-profile "$(winpath "$_p")" </dev/null 2>&1
}

# ── Case 1: J7 jira + required ───────────────────────────────────────────────
h1="$work/h1"; mkdir -p "$h1"
out=$(run_apply "$h1" '{"tracker":"jira","ticketIdRequired":true}')
rc=$?
[ "$rc" -eq 0 ] || fail "case1: install should succeed (rc=$rc): $out"
conf1="$h1/.himmel/himmel.conf"
[ -f "$conf1" ] || fail "case1: $conf1 must exist after choosing jira + required: $out"
grepq "$(cat "$conf1")" '^TRACKER=jira$' || fail "case1: TRACKER=jira missing: $(cat "$conf1")"
grepq "$(cat "$conf1")" '^TICKET_ID_REQUIRED=1$' || fail "case1: TICKET_ID_REQUIRED=1 missing: $(cat "$conf1")"
grepq "$(cat "$conf1")" '^TICKET_ID_PATTERN=' && fail "case1: a blank pattern must not be written: $(cat "$conf1")"
echo "ok: case1 J7 jira + required writes TRACKER=jira and TICKET_ID_REQUIRED=1"

# ── Case 1b: an existing himmel.conf keeps its other keys, no duplicates ─────
h1b="$work/h1b"; mkdir -p "$h1b/.himmel"
printf 'CR_PROFILE=keep-me\nTRACKER=local\n' > "$h1b/.himmel/himmel.conf"
out=$(run_apply "$h1b" '{"tracker":"jira","ticketIdRequired":true,"ticketIdPattern":"ABC-[0-9]+"}')
rc=$?
[ "$rc" -eq 0 ] || fail "case1b: install should succeed (rc=$rc): $out"
body=$(cat "$h1b/.himmel/himmel.conf")
grepq "$body" '^CR_PROFILE=keep-me$' || fail "case1b: unrelated key lost: $body"
[ "$(grep -c '^TRACKER=' <<< "$body")" -eq 1 ] || fail "case1b: TRACKER must appear once: $body"
grepq "$body" '^TRACKER=jira$' || fail "case1b: TRACKER not updated: $body"
grepq "$body" '^TICKET_ID_PATTERN=ABC-\[0-9\]+$' || fail "case1b: TICKET_ID_PATTERN missing: $body"
echo "ok: case1b existing himmel.conf keys are kept, TRACKER replaced in place"

# ── Case 2: J7 none ──────────────────────────────────────────────────────────
h2="$work/h2"; mkdir -p "$h2"
out=$(run_apply "$h2" '{"tracker":"none"}')
rc=$?
[ "$rc" -eq 0 ] || fail "case2: install should succeed (rc=$rc): $out"
body=$(cat "$h2/.himmel/himmel.conf" 2>/dev/null) || fail "case2: himmel.conf must exist: $out"
grepq "$body" '^TRACKER=none$' || fail "case2: TRACKER=none missing: $body"
grepq "$body" '^TICKET_ID_REQUIRED=' && fail "case2: tracker none must not write TICKET_ID_REQUIRED: $body"
grepq "$out" '? ticket ID required' && fail "case2: tracker none must not ask for a required ticket ID"
echo "ok: case2 J7 none writes TRACKER=none and never asks for a ticket ID"

# ── Case 2b: keys the answers omit are removed from an existing himmel.conf ──
h2b="$work/h2b"; mkdir -p "$h2b/.himmel"
printf 'CR_PROFILE=keep-me\nTRACKER=jira\nTICKET_ID_REQUIRED=1\nTICKET_ID_PATTERN=OLD-[0-9]+\n' > "$h2b/.himmel/himmel.conf"
out=$(run_apply "$h2b" '{"tracker":"none"}')
rc=$?
[ "$rc" -eq 0 ] || fail "case2b: install should succeed (rc=$rc): $out"
body=$(cat "$h2b/.himmel/himmel.conf")
grepq "$body" '^TRACKER=none$' || fail "case2b: TRACKER=none missing: $body"
grepq "$body" '^TICKET_ID_REQUIRED=' && fail "case2b: stale TICKET_ID_REQUIRED kept under tracker none: $body"
grepq "$body" '^TICKET_ID_PATTERN=' && fail "case2b: stale TICKET_ID_PATTERN kept under tracker none: $body"
grepq "$body" '^CR_PROFILE=keep-me$' || fail "case2b: unrelated key lost: $body"
printf 'TICKET_ID_PATTERN=OLD-[0-9]+\n' > "$h2b/.himmel/himmel.conf"
out=$(run_apply "$h2b" '{"tracker":"jira","ticketIdRequired":false}')
body=$(cat "$h2b/.himmel/himmel.conf")
grepq "$body" '^TICKET_ID_PATTERN=' && fail "case2b: blank pattern must drop the old TICKET_ID_PATTERN: $body"
echo "ok: case2b omitted commit-rule keys are removed, not left stale"

# ── Case 3: --dry-run prints the line, writes nothing ────────────────────────
h3="$work/h3"; mkdir -p "$h3"
out=$(run_wizard "$h3" --dry-run <<INPUT
starter
project
none
inline

no
none
no

jira
yes

yes
INPUT
)
rc=$?
[ "$rc" -eq 0 ] || fail "case3: dry-run should succeed (rc=$rc): $out"
grepq "$out" 'would write TRACKER=jira, TICKET_ID_REQUIRED=1 to .*/\.himmel/himmel\.conf' \
  || fail "case3: dry-run must print the would-write line: $out"
[ ! -e "$h3/.himmel/himmel.conf" ] || fail "case3: dry-run must not write himmel.conf"
echo "ok: case3 --dry-run prints the would-write line and writes nothing"

# ── Case 4: declining consent writes nothing ─────────────────────────────────
h4="$work/h4"; mkdir -p "$h4"
out=$(run_apply "$h4" '')
rc=$?
[ "$rc" -eq 0 ] || fail "case4: install should succeed (rc=$rc): $out"
[ ! -e "$h4/.himmel/himmel.conf" ] || fail "case4: declined consent must not write himmel.conf"
echo "ok: case4 declining consent writes nothing"

# ── Case 5: frame-11 wording ─────────────────────────────────────────────────
h5="$work/h5"; mkdir -p "$h5"
out=$(run_wizard "$h5" --dry-run </dev/null)
rc=$?
[ "$rc" -eq 0 ] || fail "case5: dry-run should succeed (rc=$rc): $out"
grepq "$out" 'starter.*guardrails, git gates and worktrees for this project' \
  || fail "case5: starter help must read the frame-11 wording: $out"
grepq "$out" '^  [0-9])* operator' && fail "case5: operator must be hidden without --contribute"
grepq "$out" '? pluginSet' && fail "case5: pluginSet must not be asked"
grepq "$out" '? cadences' || fail "case5: cadences question missing: $out"
cad=$(grep -A12 '? cadences' <<< "$out")
grepq "$cad" ' doctor ' || fail "case5: starter must offer doctor: $cad"
grepq "$cad" 'drift-fix' && fail "case5: starter must not offer drift-fix: $cad"
grepq "$cad" 'upstream-watch' && fail "case5: starter must not offer upstream-watch: $cad"
grepq "$out" 'commit these files on a branch' || fail "case5: summary must end with the branch line: $out"
outc=$(run_wizard "$h5" --dry-run --contribute </dev/null)
grepq "$outc" '^  [0-9])* operator' || fail "case5: operator must be offered with --contribute: $outc"
echo "ok: case5 frame-11 wording (starter help, operator hidden, no pluginSet, doctor only, branch line)"

# ── Case 6: J7 gate row ──────────────────────────────────────────────────────
echo "pending: J7 commit-msg gate row (gate honours the written keys in an adopter project) needs HIMMEL-6327"

echo "PASS: test-wizard-commit-rules.sh"
