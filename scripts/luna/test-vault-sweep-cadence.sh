#!/usr/bin/env bash
# scripts/luna/vault-sweep-cadence.sh arms a cron'd sweeper that commits and pushes the
# luna vault with Obsidian closed, and tells the live chief (Telegram only when no chief
# is live) when a pre-commit hook refuses the commit: one line naming hook, file and reason.
#
# Hermetic: a scratch vault with a local bare remote and a plain .git/hooks/pre-commit that
# runs the REAL shellcheck on staged *.sh files, a stub crontab, stub chief sweep, stub
# inbox sender and stub Telegram sender. Never the live vault, crontab, queue, inbox or
# Telegram. SKIPs loud (never false-greens) without git, flock or shellcheck.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SUT="$ROOT/scripts/luna/vault-sweep-cadence.sh"
FAILED=0
pass() { echo "PASS $1"; }
fail() { echo "FAIL $1 — $2"; FAILED=$((FAILED + 1)); }
assert_eq() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "expected '$2', got '$3'"; fi; }
assert_has() { case "$3" in *"$2"*) pass "$1" ;; *) fail "$1" "missing '$2' in: $3" ;; esac; }

for t in git flock shellcheck; do
    command -v "$t" >/dev/null 2>&1 || { echo "SKIP all — $t not on PATH"; exit 0; }
done

TMP="$(mktemp -d "${TMPDIR:-/tmp}/vault-sweep-cadence.XXXXXX")" || exit 1
trap 'rm -rf "$TMP"' EXIT

export GIT_AUTHOR_NAME=luna-test GIT_AUTHOR_EMAIL=luna-test@example.com
export GIT_COMMITTER_NAME=luna-test GIT_COMMITTER_EMAIL=luna-test@example.com
export GIT_CONFIG_GLOBAL="$TMP/gitconfig-isolated"
: >"$GIT_CONFIG_GLOBAL"

mkdir -p "$TMP/home"
export HOME="$TMP/home"
unset LUNA_VAULT_ALERT_CMD LUNA_VAULT_AUTOSYNC HIMMEL_ALERT_KIND
export HIMMEL_OBSERVABILITY_CONFIG="$TMP/obs.json"
export VAULT_SWEEP_CRONTAB="$TMP/crontab"
export VAULT_SWEEP_RUNNER_DIR="$TMP/runner"
export VAULT_SWEEP_ROOT="$ROOT"
export VAULT_STALL_ALERT_STATE="$TMP/alert-last"
export LUNA_VAULT_QUARANTINE_DIR="$TMP/quarantine"
export TELEGRAM_ACCESS_PATH="$TMP/access.json"
export MERGE_BLOCK_ALERT_CMD="$TMP/telegram.sh"
export FAILURE_ROUTE_SWEEP_CMD="$TMP/sweep.sh"
export FAILURE_ROUTE_INBOX_SEND="$TMP/inbox-send.sh"
TG="$TMP/telegram.log"
INBOX="$TMP/inbox.log"
CHIEF_LINE='slug=u__himmel__X-chief session=s host=h age=5s status=OK'

printf '{"allowFrom":["4242"]}\n' >"$TMP/access.json"
cat >"$TMP/crontab" <<EOF
#!/usr/bin/env bash
if [ "\${1:-}" = "-l" ]; then cat "$TMP/cron.tab" 2>/dev/null || { echo "no crontab for u" >&2; exit 1; }; else cat >"$TMP/cron.tab"; fi
EOF
cat >"$TMP/telegram.sh" <<EOF
#!/usr/bin/env bash
printf '%s|%s\n' "\$1" "\$2" >>"$TG"
EOF
cat >"$TMP/inbox-send.sh" <<EOF
#!/usr/bin/env bash
printf '%s|%s\n' "\$1" "\$2" >>"$INBOX"
EOF
cat >"$TMP/sweep.sh" <<EOF
#!/usr/bin/env bash
cat "$TMP/sweep.txt" 2>/dev/null
EOF
chmod +x "$TMP/crontab" "$TMP/telegram.sh" "$TMP/inbox-send.sh" "$TMP/sweep.sh"

V="$TMP/vault"
BARE="$TMP/bare.git"
git init -q -b main "$V"
git init -q --bare -b main "$BARE"
git -C "$V" remote add origin "$BARE"
mkdir -p "$V/.git/hooks"
cat >"$V/.git/hooks/pre-commit" <<'HOOK'
#!/usr/bin/env bash
rc=0
first=1
while IFS= read -r f; do
    case "$f" in *.sh) ;; *) continue ;; esac
    if ! o="$(shellcheck "$f" 2>&1)"; then
        if [ "$first" = 1 ]; then printf 'shellcheck...Failed\n- hook id: shellcheck\n- exit code: 1\n\n'; first=0; fi
        printf '%s\n' "$o"
        rc=1
    fi
done < <(git diff --cached --name-only --diff-filter=ACM)
exit "$rc"
HOOK
chmod +x "$V/.git/hooks/pre-commit"
printf '.single-writer\n' >"$V/.gitignore"
printf 'seed\n' >"$V/seed.md"
git -C "$V" add -A
git -C "$V" commit -q -m seed --no-verify
git -C "$V" push -q origin main

sweep() { bash "$SUT" "$@" 2>&1; }
lines() { if [ -s "$1" ]; then grep -c . "$1"; else echo 0; fi; }
head_sha() { git -C "$V" rev-parse HEAD; }
bare_sha() { git -C "$BARE" rev-parse main; }
LOG="$TMP/runner/vault-sweep-cadence.log"

mkdir -p "$V/.obsidian"
printf '["github-sync","dataview"]\n' >"$V/.obsidian/community-plugins.json"
out="$(sweep arm --vault "$V")"; rc=$?
assert_eq "S1 arm refuses (rc 5) while github-sync is enabled" "5" "$rc"
assert_has "S1b it says why" "github-sync" "$out"
assert_eq "S1c the crontab is untouched" "no" "$([ -e "$TMP/cron.tab" ] && echo yes || echo no)"
printf '["dataview"]\n' >"$V/.obsidian/community-plugins.json"

out="$(sweep arm --vault "$V")"; rc=$?
assert_eq "S2 arm exits 0" "0" "$rc"
assert_has "S2b the cron row runs the runner every 10 min, tagged" "*/10 * * * * '$TMP/runner/vault-sweep-cadence.sh' # HIMMEL-VaultSweep" "$(cat "$TMP/cron.tab" 2>/dev/null)"
assert_eq "S2c the runner is executable" "yes" "$([ -x "$TMP/runner/vault-sweep-cadence.sh" ] && echo yes || echo no)"
assert_has "S2d the runner bakes this checkout's sweeper" "$ROOT/templates/luna-second-brain/scripts/vault-autosync.sh" "$(cat "$TMP/runner/vault-sweep-cadence.sh")"

sweep arm --vault "$V" >/dev/null; rc=$?
assert_eq "S3 a second arm without --force exits 3" "3" "$rc"
sweep arm --vault "$V" --force >/dev/null; rc=$?
assert_eq "S3b with --force it exits 0" "0" "$rc"
assert_eq "S3c still exactly one cron row" "1" "$(grep -c 'HIMMEL-VaultSweep' "$TMP/cron.tab")"

printf 'a note\n' >"$V/note.md"
sweep run >/dev/null; rc=$?
assert_eq "S4 run exits 0" "0" "$rc"
assert_eq "S4b the sweep committed" "chore: vault autosync" "$(git -C "$V" log -1 --format=%s)"
assert_eq "S4c and pushed: the remote main is the vault HEAD" "$(head_sha)" "$(bare_sha)"
assert_eq "S4d the vault is clean" "" "$(git -C "$V" status --porcelain)"

printf 'another note\n' >"$V/note2.md"
before="$(head_sha)"
exec 8>"$V/.git/vault-writer.lock"
flock 8
sweep run >/dev/null; rc=$?
exec 8>&-
assert_eq "S5 run exits 0 while the lock is held" "0" "$rc"
assert_has "S5b the log says busy" "busy" "$(cat "$LOG" 2>/dev/null)"
assert_eq "S5c no new commit" "$before" "$(head_sha)"
if [ "$(id -u)" -eq 0 ]; then
    pass "S5d skipped: running as root, a read-only .git does not stop the writer lock"
else
    rm -f "$V/.git/vault-writer.lock"
    before="$(head_sha)"
    chmod a-w "$V/.git"
    sweep run >/dev/null; rc=$?
    chmod u+w "$V/.git"
    assert_eq "S5d a runner whose writer lock cannot be opened exits 2" "2" "$rc"
    assert_has "S5e and its log says cannot open the writer lock" "cannot open the writer lock" "$(cat "$LOG" 2>/dev/null)"
    assert_eq "S5f no new commit" "$before" "$(head_sha)"
fi

mkdir -p "$V/notes"
# shellcheck disable=SC2016  # the planted script's own $1 stays literal
printf '#!/usr/bin/env bash\necho $1\n' >"$V/notes/bad.sh"
printf '%s\n' "$CHIEF_LINE" >"$TMP/sweep.txt"
rm -f "$TG" "$INBOX" "$VAULT_STALL_ALERT_STATE" "$V/.git/vault-autosync-stall"
LUNA_VAULT_STALL_THRESHOLD_MIN=0 sweep run >/dev/null; rc=$?
assert_eq "S6 the sweep exits non-zero on a refused commit" "1" "$rc"
assert_eq "S6b exactly one line reached the chief's inbox" "1" "$(lines "$INBOX")"
line="$(cat "$INBOX" 2>/dev/null)"
assert_has "S6c it goes to the live chief" "X-chief|" "$line"
assert_has "S6d it names the hook" "hook: shellcheck" "$line"
assert_has "S6e it names the file" "file: notes/bad.sh" "$line"
assert_has "S6f it names the reason" "reason: SC" "$line"
assert_eq "S6g Telegram was not used" "0" "$(lines "$TG")"
assert_eq "S6h nothing was pushed" "$before" "$(bare_sha)"

: >"$TMP/sweep.txt"
rm -f "$TG" "$INBOX" "$VAULT_STALL_ALERT_STATE" "$V/.git/vault-autosync-stall"
LUNA_VAULT_STALL_THRESHOLD_MIN=0 sweep run >/dev/null
assert_eq "S7 Telegram got exactly one line" "1" "$(lines "$TG")"
line="$(cat "$TG" 2>/dev/null)"
assert_has "S7b it goes to the operator chat" "4242|" "$line"
assert_has "S7c it names the hook" "hook: shellcheck" "$line"
assert_has "S7d it names the file" "file: notes/bad.sh" "$line"
assert_has "S7e it names the reason" "reason: SC" "$line"
assert_eq "S7f the chief's inbox got nothing" "0" "$(lines "$INBOX")"
RO="$TMP/ro'ot\$x"
ln -s "$ROOT" "$RO"
out="$(VAULT_SWEEP_ROOT="$RO" sweep arm --vault "$V" --force)"; rc=$?
assert_eq "S7g arm with a checkout path holding a quote and a dollar exits 0" "0" "$rc"
bash -n "$TMP/runner/vault-sweep-cadence.sh" >/dev/null 2>&1; rc=$?
assert_eq "S7h the generated runner parses" "0" "$rc"
assert_eq "S7i the runner carries its _alert line" "1" "$(grep -c '^_alert=' "$TMP/runner/vault-sweep-cadence.sh")"
sweep arm --vault "$V" --force >/dev/null; rc=$?
assert_eq "S7j re-arm with the normal checkout exits 0" "0" "$rc"

assert_has "S8 status prints ARMED" "ARMED" "$(sweep status)"
out="$(sweep disarm)"; rc=$?
assert_eq "S8b disarm exits 0" "0" "$rc"
assert_eq "S8c the cron row is gone" "0" "$(grep -c 'HIMMEL-VaultSweep' "$TMP/cron.tab")"
assert_eq "S8d the runner is gone" "no" "$([ -e "$TMP/runner/vault-sweep-cadence.sh" ] && echo yes || echo no)"
assert_has "S8e status now says not armed" "not armed" "$(sweep status)"

echo "----"
if [ "$FAILED" -eq 0 ]; then echo "PASS: vault-sweep-cadence ($0)"; else echo "FAIL: vault-sweep-cadence — $FAILED failed ($0)" >&2; exit 1; fi
