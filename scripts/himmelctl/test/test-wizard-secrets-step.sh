#!/usr/bin/env bash
# test-wizard-secrets-step.sh — the install wizard collects secrets with a
# masked prompt, keep/set/skip per key, and records STATUS ONLY in the answers.
#
# Each case runs the real `himmelctl install` on a PTY (pty-drive.py), so the
# kernel echoes typed bytes exactly like a terminal, and declines the final
# `Proceed?` so nothing is installed: the answers cache is written before it.
#   J4  canary typed at the masked prompt: not in the transcript, store holds it
#       at 0600, answers say set, a re-run keeps the store byte-identical.
#   J6  an existing .env is reused (placeholder shown, set key kept untouched);
#       a work-tree .env that git does not ignore is refused, nothing written.
#   CLAUDECODE=1 refuses the step.
#   loadProfile refuses a value (anything but a status) under `secrets`.
# Every fake value is generated at runtime.
set -uo pipefail

repo_root=$(git rev-parse --show-toplevel)
wizard="$repo_root/scripts/himmelctl/bin.js"
driver="$repo_root/scripts/himmelctl/test/pty-drive.py"
. "$repo_root/scripts/himmelctl/test/_hermetic-home.sh"
command -v node >/dev/null 2>&1 || { echo "FAIL: node required" >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "FAIL: python3 required" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "FAIL: jq required" >&2; exit 1; }
fail() {
  echo "FAIL: $1 (driver rc=${rc:-?})" >&2
  [ -z "${c:-}" ] || [ ! -f "$c/transcript" ] || { echo "--- transcript tail ---" >&2; tail -c 800 "$c/transcript" | cat -v >&2; }
  exit 1
}
node_bin=$(command -v node)

t=$(mktemp -d "${TMPDIR:-/tmp}/wizard-secrets-step.XXXXXX") || exit 1
trap 'rm -rf "$t"' EXIT

canary="canary$(head -c 12 /dev/urandom | od -An -tx1 | tr -d ' \n')"
scrub=(-u CLAUDECODE); for v in $(compgen -e | grep -E "^(CLAUDE_CODE_|JIRA_|TELEGRAM_)" || true); do scrub+=(-u "$v"); done
mode_of() { stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"; }
sha_of() { sha256sum "$1" | cut -d' ' -f1; }

# run_case <name> <rules-json> [extra env KEY=VAL...] — fresh sandbox per case.
# Leaves $c (case dir), $c/transcript, $c/himmel (HIMMELCTL_REPO_ROOT), $c/proj.
run_case() {
  local name="$1" rules="$2"; shift 2
  c="$t/$name"; mkdir -p "$c/home" "$c/himmel" "$c/proj" "$c/cache"
  git -C "$c/himmel" init -q; printf '.env\n' > "$c/himmel/.gitignore"; git -C "$c/proj" init -q; printf '.env\n' > "$c/proj/.gitignore"
  printf '%s' "$rules" > "$c/rules.json"
  rc=0
  ( cd "$c/proj" && env "${scrub[@]}" \
      HOME="$c/home" USERPROFILE="$c/home" HIMMELCTL_CACHE_DIR="$c/cache" \
      HIMMEL_LUNA_CONFIG_PATH="$c/cache/luna-config.json" HIMMELCTL_REPO_ROOT="$c/himmel" \
      HIMMELCTL_INTERACTIVE=1 "$@" \
      python3 "$driver" "$c/transcript" "$c/rules.json" -- "$node_bin" "$wizard" install ) >/dev/null 2>&1 || rc=$?
}
answers() { jq -r "$1" "$c/cache/install-profile.json"; }

# every case: run 'run' at the secrets gate, set only JIRA_API_TOKEN with the canary
rules_j4='[["JIRA_API_TOKEN value", "'"$canary"'"],["JIRA_API_TOKEN \\[", "set"],["walk through secrets", "run"],["Proceed\\?", "n"]]'

# ── negative control: the transcript scan really does see an echoed canary ──
printf 'typed: %s\n' "$canary" > "$t/echoed.txt"
grep -qF "$canary" "$t/echoed.txt" || fail "control: the canary scan must find a planted echo"
echo "ok: control — canary scan finds a planted echo"

# ── J4: masked entry ────────────────────────────────────────────────────────
run_case j4 "$rules_j4"
[ -f "$c/transcript" ] || fail "j4: no transcript (rc=$rc)"
grep -qF "$canary" "$c/transcript" && fail "j4: the canary appears in the terminal transcript (echoed)"
grep -qF "•" "$c/transcript" || fail "j4: no mask character shown at the value prompt"
[ -f "$c/himmel/.env" ] || fail "j4: store file $c/himmel/.env was not written"
grep -qxF "JIRA_API_TOKEN=$canary" "$c/himmel/.env" || fail "j4: store lacks the canary line"
[ "$(mode_of "$c/himmel/.env")" = "600" ] || fail "j4: store mode is $(mode_of "$c/himmel/.env"), want 600"
[ "$(answers '.secrets.JIRA_API_TOKEN')" = "set" ] || fail "j4: answers.secrets.JIRA_API_TOKEN is not 'set'"
grep -qF "$canary" "$c/cache/install-profile.json" && fail "j4: the canary leaked into the answers file"
sum1=$(sha_of "$c/himmel/.env")
echo "ok: J4 masked entry — no echo, store 0600 holds it, answers say set"

# re-run on the same sandbox: every set key defaults to keep, store untouched
rc=0
( cd "$c/proj" && env "${scrub[@]}" HOME="$c/home" USERPROFILE="$c/home" HIMMELCTL_CACHE_DIR="$c/cache" \
    HIMMEL_LUNA_CONFIG_PATH="$c/cache/luna-config.json" HIMMELCTL_REPO_ROOT="$c/himmel" HIMMELCTL_INTERACTIVE=1 \
    python3 "$driver" "$c/transcript2" <(printf '%s' '[["walk through secrets", "run"],["Proceed\\?", "n"]]') \
    -- "$node_bin" "$wizard" install ) >/dev/null 2>&1 || rc=$?
[ "$(sha_of "$c/himmel/.env")" = "$sum1" ] || fail "j4: re-run changed the store (must stay byte-identical)"
[ "$(answers '.secrets.JIRA_API_TOKEN')" = "kept" ] || fail "j4: re-run answers.secrets.JIRA_API_TOKEN is not 'kept'"
grep -qF "set (from himmel-env)" "$c/transcript2" || fail "j4: re-run did not show 'set (from himmel-env)'"
grep -qF "$canary" "$c/transcript2" && fail "j4: re-run transcript shows the canary"
echo "ok: J4 re-run — kept, store byte-identical"

# ── J6a: reuse an existing .env, show a placeholder ─────────────────────────
mkdir -p "$t/j6a/himmel"
printf 'JIRA_BASE_URL=<your-jira-url>\nJIRA_EMAIL=ops@example.com\n' > "$t/j6a/pre.env"
c="$t/j6a"; mkdir -p "$c/home" "$c/himmel" "$c/proj" "$c/cache"
git -C "$c/himmel" init -q; printf '.env\n' > "$c/himmel/.gitignore"; git -C "$c/proj" init -q; printf '.env\n' > "$c/proj/.gitignore"
cp "$c/pre.env" "$c/himmel/.env"; chmod 600 "$c/himmel/.env"
sum_pre=$(sha_of "$c/himmel/.env")
printf '%s' '[["walk through secrets", "run"],["Proceed\\?", "n"]]' > "$c/rules.json"
rc=0
( cd "$c/proj" && env "${scrub[@]}" HOME="$c/home" USERPROFILE="$c/home" HIMMELCTL_CACHE_DIR="$c/cache" \
    HIMMEL_LUNA_CONFIG_PATH="$c/cache/luna-config.json" HIMMELCTL_REPO_ROOT="$c/himmel" HIMMELCTL_INTERACTIVE=1 \
    python3 "$driver" "$c/transcript" "$c/rules.json" -- "$node_bin" "$wizard" install ) >/dev/null 2>&1 || rc=$?
grep -qF "JIRA_BASE_URL" "$c/transcript" || fail "j6a: JIRA_BASE_URL not listed"
grep -qF "placeholder" "$c/transcript" || fail "j6a: the placeholder value was not reported as 'placeholder'"
grep -qF "ops@example.com" "$c/transcript" && fail "j6a: a stored value was printed"
[ "$(answers '.secrets.JIRA_EMAIL')" = "kept" ] || fail "j6a: JIRA_EMAIL not 'kept'"
[ "$(answers '.secrets.JIRA_BASE_URL')" = "skipped" ] || fail "j6a: placeholder JIRA_BASE_URL not 'skipped' by default"
[ "$(sha_of "$c/himmel/.env")" = "$sum_pre" ] || fail "j6a: accepting the defaults changed the existing .env"
echo "ok: J6 existing .env reused, placeholder reported, defaults leave it byte-identical"

# ── J6b: a work-tree .env that git does not ignore is refused ───────────────
c="$t/j6b"; mkdir -p "$c/home" "$c/himmel" "$c/proj" "$c/cache"
git -C "$c/himmel" init -q; git -C "$c/proj" init -q; printf '.env\n' > "$c/proj/.gitignore"
printf '%s' "$rules_j4" > "$c/rules.json"
rc=0
( cd "$c/proj" && env "${scrub[@]}" HOME="$c/home" USERPROFILE="$c/home" HIMMELCTL_CACHE_DIR="$c/cache" \
    HIMMEL_LUNA_CONFIG_PATH="$c/cache/luna-config.json" HIMMELCTL_REPO_ROOT="$c/himmel" HIMMELCTL_INTERACTIVE=1 \
    python3 "$driver" "$c/transcript" "$c/rules.json" -- "$node_bin" "$wizard" install ) >/dev/null 2>&1 || rc=$?
[ ! -e "$c/himmel/.env" ] || fail "j6b: wrote a .env that git does not ignore"
grep -qF "not ignored" "$c/transcript" || fail "j6b: no 'not ignored' refusal shown"
[ "$(answers '.secrets.JIRA_API_TOKEN')" = "skipped" ] || fail "j6b: refused write not recorded as 'skipped'"
grep -qF "$canary" "$c/transcript" && fail "j6b: transcript shows the canary"
echo "ok: J6 un-ignored work-tree .env refused, nothing written"

# ── CLAUDECODE=1 refuses the step ───────────────────────────────────────────
c="$t/cc"; mkdir -p "$c/home" "$c/himmel" "$c/proj" "$c/cache"
printf '%s' "$rules_j4" > "$c/rules.json"
rc=0
( cd "$c/proj" && HOME="$c/home" USERPROFILE="$c/home" HIMMELCTL_CACHE_DIR="$c/cache" \
    HIMMEL_LUNA_CONFIG_PATH="$c/cache/luna-config.json" HIMMELCTL_REPO_ROOT="$c/himmel" HIMMELCTL_INTERACTIVE=1 CLAUDECODE=1 \
    python3 "$driver" "$c/transcript" "$c/rules.json" -- "$node_bin" "$wizard" install ) >/dev/null 2>&1 || rc=$?
grep -qF "secrets step refused" "$c/transcript" || fail "cc: CLAUDECODE=1 did not refuse the secrets step"
[ ! -e "$c/himmel/.env" ] || fail "cc: wrote a store file despite the refusal"
[ "$(answers '.secretsWalk')" = "skip" ] || fail "cc: refused step must leave secretsWalk=skip"
echo "ok: CLAUDECODE=1 refuses the secrets step"

# ── loadProfile refuses a value under secrets ───────────────────────────────
bad="$t/bad-profile.json"
jq --arg v "$canary" '.secrets = {"JIRA_API_TOKEN": $v}' "$t/j4/cache/install-profile.json" > "$bad"
out=$(cd "$t/j4/proj" && HOME="$t/j4/home" USERPROFILE="$t/j4/home" HIMMEL_LUNA_CONFIG_PATH="$t/j4/cache/luna-config.json" HIMMELCTL_CACHE_DIR="$t/j4/cache" HIMMELCTL_REPO_ROOT="$t/j4/himmel" "$node_bin" "$wizard" install --dry-run --from-profile "$bad" 2>&1) && rcb=0 || rcb=$?
[ "$rcb" -ne 0 ] || fail "loadProfile: a value under secrets was accepted"
printf '%s' "$out" | grep -qF "$canary" && fail "loadProfile: the refusal message echoed the value"
printf '%s' "$out" | grep -qF "secrets" || fail "loadProfile: refusal does not name the secrets field"
echo "ok: loadProfile refuses anything but a status under secrets"
echo "ALL PASS"
