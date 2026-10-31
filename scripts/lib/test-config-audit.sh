#!/usr/bin/env bash
# scripts/lib/test-config-audit.sh — fixture test for scripts/lib/config-audit.sh
# and its writers.
#
# Pins: a deleted or key-losing config file alerts once and names the newest
# good backup; every audited write leaves a row (key NAMES, never values) and a
# backup of the full set, pruned to KEEP; list and restore round-trip; the
# writers migrate-env.sh, luna-config save and behaviour-config (through
# secret-store) leave rows; a write outside the station set backs up nothing,
# and a fixture-HOME run never touches the real backups.
#
# RED control: the watcher row first runs against an unchanged set and must see
# NO alert, so the alert assertion cannot pass on a watcher that always alerts.
#
# Platform: bash 3.2+, needs node.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
CA="$HERE/config-audit.sh"
PASS=0; FAIL=0
pass() { PASS=$((PASS + 1)); echo "PASS $1"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL $1"; }
has()  { case "$3" in *"$2"*) pass "$1" ;; *) fail "$1 — missing '$2'" ;; esac; }
lacks() { case "$3" in *"$2"*) fail "$1 — found '$2'" ;; *) pass "$1" ;; esac; }
eq()   { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (want '$2', got '$3')"; fi; }

command -v node >/dev/null 2>&1 || { echo "SKIP: node not installed"; exit 0; }

REAL_STATE="${HOME:-/nonexistent}/.himmel/state/config-audit"
real_before=$(ls -la "$REAL_STATE" "$REAL_STATE/backups" 2>&1; cat "$REAL_STATE/audit.jsonl" 2>/dev/null | wc -l)

TMP=$(mktemp -d "${TMPDIR:-/tmp}/test-config-audit.XXXXXX") || exit 1
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home"
export HIMMEL_CONFIG_DIR="$HOME/.himmel"
export HIMMEL_CONFIG_AUDIT_ENV_FILE="$TMP/clone/.env"
export HIMMEL_POLICY_FOLLOWS_HOME=1
export HIMMELCTL_CACHE_DIR="$TMP/no-cache"
export HIMMEL_TEST_FIXTURE=1
unset HIMMEL_CONFIG_AUDIT_DIR BRIDGE_ROOT HIMMEL_CONFIG_BACKUPS_KEEP CLAUDECODE
STATE="$HIMMEL_CONFIG_DIR/state/config-audit"
mkdir -p "$HIMMEL_CONFIG_DIR" "$TMP/clone" "$HOME/.claude"

# Alert sink stub: one line per alert.
ALERTS="$TMP/alerts.log"; : > "$ALERTS"
# shellcheck disable=SC2016 # $1 belongs to the generated stub
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$1" >> "%s"\n' "$ALERTS" > "$TMP/alert-cmd"
chmod +x "$TMP/alert-cmd"
export HIMMEL_CONFIG_ALERT_CMD="$TMP/alert-cmd"

CANARY="CANARY-$(od -An -N4 -tx1 /dev/urandom | tr -d ' \n')"
printf '{"version":1,"policy":{"HIMMEL_FLEET_CAP":"40","CR_REQUIRE_CROSS_MODEL":"%s"}}\n' "$CANARY" > "$HIMMEL_CONFIG_DIR/config.json"
printf 'HANDOVER_DIR=%s\nHIMMEL_INITIATIVE=execute\n' "$TMP/handovers-$CANARY" > "$HIMMEL_CONFIG_DIR/himmel.conf"
printf 'JIRA_API_TOKEN=%s\n' "$CANARY" > "$TMP/clone/.env"

# --- 1. audited write: a row with key names, a backup of the whole set ---
id=$(bash "$CA" pre "$HIMMEL_CONFIG_DIR/config.json" --script test)
case "$id" in [0-9]*T[0-9]*Z-*) pass "1 pre prints a backup id" ;; *) fail "1 pre printed '$id'" ;; esac
for f in .env himmel.conf config.json manifest.json; do
    if [ -f "$STATE/backups/$id/$f" ]; then pass "1 the backup holds $f"; else fail "1 the backup lacks $f"; fi
done
if cmp -s "$TMP/clone/.env" "$STATE/backups/$id/.env"; then pass "1 the backup .env matches the live .env"; else fail "1 the backup .env differs from the live .env"; fi
if cmp -s "$HIMMEL_CONFIG_DIR/config.json" "$STATE/backups/$id/config.json"; then pass "1 the backup config.json matches the live file"; else fail "1 the backup config.json differs from the live file"; fi
eq "1 a backup file is mode 600" 600 "$(stat -c %a "$STATE/backups/$id/.env" 2>/dev/null || stat -f %Lp "$STATE/backups/$id/.env")"
printf '{"version":1,"policy":{"HIMMEL_FLEET_CAP":"40","ARMAUTOMERGE":"%s"}}\n' "$CANARY" > "$HIMMEL_CONFIG_DIR/config.json"
bash "$CA" post "$id" "$HIMMEL_CONFIG_DIR/config.json" write --script test >/dev/null
row=$(tail -n 1 "$STATE/audit.jsonl" 2>/dev/null)
has "1 the row names the added key" '"keys_added":["policy.ARMAUTOMERGE"]' "$row"
has "1 the row names the removed key" '"keys_removed":["policy.CR_REQUIRE_CROSS_MODEL"]' "$row"
has "1 the row names its script" '"script":"test"' "$row"
has "1 the row names its backup" "\"backup\":\"$id\"" "$row"
lacks "1 no value reaches the audit log" "$CANARY" "$(cat "$STATE/audit.jsonl" 2>/dev/null)"
id2=$(bash "$CA" pre "$HIMMEL_CONFIG_DIR/config.json" --script test)
id3=$(bash "$CA" pre "$HIMMEL_CONFIG_DIR/config.json" --script test)
eq "1 an unchanged set reuses its newest backup" "$id2" "$id3"

# --- 2. KEEP prunes per file ---
for i in 1 2 3 4 5; do
    b=$(HIMMEL_CONFIG_BACKUPS_KEEP=3 bash "$CA" pre "$HIMMEL_CONFIG_DIR/config.json" --script test)
    printf '{"version":1,"policy":{"HIMMEL_FLEET_CAP":"%s"}}\n' "$i" > "$HIMMEL_CONFIG_DIR/config.json"
    HIMMEL_CONFIG_BACKUPS_KEEP=3 bash "$CA" post "$b" "$HIMMEL_CONFIG_DIR/config.json" write --script test >/dev/null
done
eq "2 KEEP=3 keeps three backups" 3 "$(find "$STATE/backups" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')"

# --- 3. the watcher: quiet on a healthy set, one alert on a loss ---
bash "$CA" watch 2>/dev/null
bash "$CA" watch 2>/dev/null
eq "3 RED control: an unchanged set raises no alert" 0 "$(wc -l < "$ALERTS" | tr -d ' ')"
rm -f "$HIMMEL_CONFIG_DIR/config.json"
bash "$CA" watch 2>/dev/null
alert=$(cat "$ALERTS")
has "3 a deleted config.json alerts" "config.json deleted" "$alert"
has "3 the alert names a lost key" "policy.HIMMEL_FLEET_CAP" "$alert"
has "3 the alert names the newest good backup" "newest good backup 2" "$alert"
lacks "3 no value reaches the alert" "$CANARY" "$alert"
bash "$CA" watch 2>/dev/null
eq "3 the same loss alerts once" 1 "$(wc -l < "$ALERTS" | tr -d ' ')"
out=$(bash "$CA" check); rc=$?
eq "3 check exits 3 on a loss" 3 "$rc"
has "3 check names the file" "LOSS	config.json	deleted" "$out"
sed -i.bak '/^HIMMEL_INITIATIVE=/d' "$HIMMEL_CONFIG_DIR/himmel.conf" && rm -f "$HIMMEL_CONFIG_DIR/himmel.conf.bak"
bash "$CA" watch 2>/dev/null
has "3 a lost himmel.conf key alerts" "lost keys: HIMMEL_INITIATIVE" "$(tail -n 1 "$ALERTS")"

# --- 4. list and restore ---
good=$(bash "$CA" check | awk -F'\t' '$2 == "config.json" { print $5 }')
lst=$(bash "$CA" list)
has "4 list names the good backup" "$good" "$lst"
has "4 list says config.json comes back" "config.json back" "$lst"
lacks "4 list prints no value" "$CANARY" "$lst"
out=$(bash "$CA" restore "$good" --script test-restore)
has "4 restore reports the id" "result=restored id=$good" "$out"
has "4 config.json is back with its key" '"HIMMEL_FLEET_CAP"' "$(cat "$HIMMEL_CONFIG_DIR/config.json" 2>/dev/null)"
has "4 the restore leaves an audit row" '"action":"restore"' "$(tail -n 2 "$STATE/audit.jsonl")"
out=$(bash "$CA" restore 19990101T000000Z-dead); rc=$?
eq "4 an unknown id is refused" 1 "$rc"
bash "$CA" accept >/dev/null
out=$(bash "$CA" check); rc=$?
eq "4 accept clears the loss" 0 "$rc"
# A corrupt member is found before any file is written, not after the first.
cid=$(bash "$CA" pre "$HIMMEL_CONFIG_DIR/config.json" --script test)
conf_before=$(cat "$HIMMEL_CONFIG_DIR/himmel.conf")
printf 'HIMMEL_INITIATIVE=changed\n' >> "$HIMMEL_CONFIG_DIR/himmel.conf"
conf_live=$(cat "$HIMMEL_CONFIG_DIR/himmel.conf")
printf '{"tampered":1}\n' > "$STATE/backups/$cid/config.json"
printf '{"version":1,"changed":1}\n' > "$HIMMEL_CONFIG_DIR/config.json"
out=$(bash "$CA" restore "$cid"); rc=$?
eq "4 a corrupt backup is refused" 1 "$rc"
has "4 the refusal names the corrupt file" "result=corrupt id=$cid file=config.json" "$out"
eq "4 a refused restore writes no file" "$conf_live" "$(cat "$HIMMEL_CONFIG_DIR/himmel.conf")"
[ "$conf_before" != "$conf_live" ] || fail "4 RED control: himmel.conf differs from its backup"
# A restore whose undo backup cannot be written writes nothing (root ignores the mode).
if [ "$(id -u)" != 0 ]; then
    printf 'HIMMEL_INITIATIVE=changed-again\n' >> "$HIMMEL_CONFIG_DIR/himmel.conf"
    cfg_live=$(cat "$HIMMEL_CONFIG_DIR/config.json")
    chmod 555 "$STATE/backups"
    out=$(bash "$CA" restore "$good" 2>&1); rc=$?
    chmod 755 "$STATE/backups"
    eq "4 a restore with no undo backup is refused" 1 "$rc"
    has "4 the refusal says why" "result=no-undo-backup" "$out"
    eq "4 a restore with no undo backup writes no file" "$cfg_live" "$(cat "$HIMMEL_CONFIG_DIR/config.json")"
fi
# Two backups in one second: the later one is newest, whatever its suffix.
for sfx in ffff 0000; do
    mkdir -p "$STATE/backups/20991231T000000Z-$sfx"
    printf '{"ts":"2099-12-31T00:00:00Z","script":"order-%s","ms":%s,"target":"%s","files":{}}\n' \
        "$sfx" "$([ "$sfx" = ffff ] && echo 4102444800000 || echo 4102444800001)" "$TMP/order" > "$STATE/backups/20991231T000000Z-$sfx/manifest.json"
done
eq "4 the later backup of one second lists first" "20991231T000000Z-0000" "$(bash "$CA" list | head -n 1 | cut -d' ' -f1)" # tail-pipe-ok: list output, not a gate
rm -rf "$STATE/backups/20991231T000000Z-ffff" "$STATE/backups/20991231T000000Z-0000"
# A file that was empty and stays empty is healthy, not truncated.
saved_env=$(cat "$TMP/clone/.env")
: > "$TMP/clone/.env"
bash "$CA" accept >/dev/null
out=$(bash "$CA" check); rc=$?
eq "4 an unchanged empty .env is healthy" 0 "$rc"
# A deleted empty file has no lost key: its row prints - so a tab read keeps the fields.
rm -f "$TMP/clone/.env"
out=$(bash "$CA" check)
eq "4 an empty lost-key list prints -" "-" "$(printf '%s\n' "$out" | awk -F'\t' '$2 == ".env" { print $4 }')"
printf '%s\n' "$saved_env" > "$TMP/clone/.env"
bash "$CA" accept >/dev/null
# A restored legacy .env key that the live himmel.conf also sets is named as a conflict.
conf_saved=$(cat "$HIMMEL_CONFIG_DIR/himmel.conf")
printf 'HANDOVER_DIR=%s\nHIMMEL_INITIATIVE=execute\n' "$TMP/h" > "$HIMMEL_CONFIG_DIR/himmel.conf"
printf '%s\nHIMMEL_INITIATIVE=off\n' "$saved_env" > "$TMP/clone/.env"
lid=$(bash "$CA" pre "$HIMMEL_CONFIG_DIR/config.json" --script test)
printf '%s\n' "$saved_env" > "$TMP/clone/.env"
out=$(bash "$CA" restore "$lid" --script test-restore 2>&1)
has "4 a legacy key the live himmel.conf sets is named as a conflict" "himmel.conf still sets HIMMEL_INITIATIVE" "$out"
lacks "4 a conflicting key is not said to still work" "they still work" "$out"
printf '%s\n' "$conf_saved" > "$HIMMEL_CONFIG_DIR/himmel.conf"
printf '%s\n' "$saved_env" > "$TMP/clone/.env"
bash "$CA" accept >/dev/null
# A restored legacy .env policy key that the live config.json .policy sets is named as a conflict.
pol_saved=$(cat "$HIMMEL_CONFIG_DIR/config.json")
printf '{"policy":{"CR_REQUIRE_CROSS_MODEL":"1"}}\n' > "$HIMMEL_CONFIG_DIR/config.json"
printf '%s\nCR_REQUIRE_CROSS_MODEL=0\n' "$saved_env" > "$TMP/clone/.env"
polid=$(bash "$CA" pre "$HIMMEL_CONFIG_DIR/config.json" --script test)
printf '%s\n' "$saved_env" > "$TMP/clone/.env"
out=$(bash "$CA" restore "$polid" --script test-restore 2>&1)
has "4 a legacy policy key the live config.json sets is named as a conflict" "config.json still sets CR_REQUIRE_CROSS_MODEL" "$out"
lacks "4 a policy key config.json sets is not said to still work" "they still work" "$out"
printf '%s\n' "$pol_saved" > "$HIMMEL_CONFIG_DIR/config.json"
printf '%s\n' "$saved_env" > "$TMP/clone/.env"
bash "$CA" accept >/dev/null

# --- 5. luna-config save leaves a row and a backup ---
before=$(wc -l < "$STATE/audit.jsonl")
HIMMEL_LUNA_CONFIG_PATH="$HIMMEL_CONFIG_DIR/config.json" node -e '
    const lc = require(process.argv[1]);
    const d = lc.load(); d.luna.cadence.enabled = true; lc.save(d);' "$REPO/scripts/himmelctl/lib/luna-config.js" 2>"$TMP/lc.err"
row=$(tail -n 1 "$STATE/audit.jsonl")
eq "5 luna-config save adds one row" $((before + 1)) "$(wc -l < "$STATE/audit.jsonl" | tr -d ' ')"
has "5 the row names luna-config" '"script":"himmelctl luna-config"' "$row"
has "5 the row names the changed key" 'luna.cadence.enabled' "$row"

# --- 6. a non-bin behaviour-config caller: secret-store's Jira URL write ---
before=$(wc -l < "$STATE/audit.jsonl")
URL="https://$(printf '%s' "$CANARY" | tr '[:upper:]' '[:lower:]').atlassian.net"
SS_URL="$URL" node -e '
    const ss = require(process.argv[1]);
    const ctx = { home: process.env.HOME, himmelRoot: process.argv[2], projectRoot: process.argv[2], env: { HIMMEL_CONFIG_DIR: process.env.HIMMEL_CONFIG_DIR } };
    ss.write("JIRA_BASE_URL", process.env.SS_URL, ctx);' "$REPO/scripts/himmelctl/lib/secret-store.js" "$TMP/clone" 2>"$TMP/ss.err"
row=$(tail -n 1 "$STATE/audit.jsonl")
eq "6 the secret-store write adds one row" $((before + 1)) "$(wc -l < "$STATE/audit.jsonl" | tr -d ' ')"
has "6 the row names JIRA_BASE_URL" '"keys_added":["JIRA_BASE_URL"]' "$row"
lacks "6 the row holds no value" "$(printf '%s' "$CANARY" | tr '[:upper:]' '[:lower:]')" "$row"

# --- 7. migrate-env.sh leaves a row for the himmel.conf it writes ---
# The consent covers only the checkout's own .env, so the run is from a fixture
# checkout whose .env is the set's. Its readers are absent, so verify stops the
# move after the himmel.conf copy: that write is the one under test.
FX="$TMP/fx"
mkdir -p "$FX/scripts/setup" "$FX/scripts/lib" "$FX/scripts/himmelctl/lib" "$FX/docs/setup"
cp "$REPO/scripts/setup/migrate-env.sh" "$REPO/scripts/setup/migrate-env-config.sh" "$FX/scripts/setup/"
cp "$HERE/load-dotenv.sh" "$HERE/prim.sh" "$HERE/chokepoint-seam-guard.sh" "$CA" "$FX/scripts/lib/"
cp "$REPO/scripts/himmelctl/lib/config-keys.json" "$FX/scripts/himmelctl/lib/"
cp "$REPO/docs/setup/himmel-config.example.json" "$FX/docs/setup/"
printf 'JIRA_PROJECT_KEY=\n' > "$FX/.env.example"
printf '{"version":1,"policy":{"ENV_MIGRATION_CONSENT":"1"}}\n' > "$HIMMEL_CONFIG_DIR/config.json"
printf 'JIRA_PROJECT_KEY=ZQX-%s\n' "$CANARY" > "$FX/.env"
before=$(wc -l < "$STATE/audit.jsonl")
HIMMEL_CONFIG_AUDIT_ENV_FILE="$FX/.env" bash "$FX/scripts/setup/migrate-env.sh" --env "$FX/.env" </dev/null >"$TMP/me.out" 2>&1
rows=$(tail -n +$((before + 1)) "$STATE/audit.jsonl")
has "7 migrate-env leaves a row" '"script":"migrate-env.sh"' "$rows"
has "7 the row names the moved key" 'JIRA_PROJECT_KEY' "$rows"
lacks "7 no value reaches the rows" "$CANARY" "$rows"

# --- 8. scope: a write outside the station set backs up nothing ---
nb=$(find "$STATE/backups" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')
mkdir -p "$TMP/elsewhere"; printf 'A=1\n' > "$TMP/elsewhere/himmel.conf"
out=$(bash "$CA" pre "$TMP/elsewhere/himmel.conf" --script test)
eq "8 an out-of-scope pre prints no id" "" "$out"
eq "8 an out-of-scope pre takes no backup" "$nb" "$(find "$STATE/backups" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')"
printf '{}\n' > "$HOME/.claude/settings.json"
out=$(bash "$CA" pre "$HOME/.claude/settings.json" --script test)
has "8 a ~/.claude settings file is in scope" "$STATE/backups/$out/extra/settings.json" "$(ls "$STATE/backups/$out/extra/settings.json" 2>&1)"
real_after=$(ls -la "$REAL_STATE" "$REAL_STATE/backups" 2>&1; cat "$REAL_STATE/audit.jsonl" 2>/dev/null | wc -l)
eq "8 a fixture-HOME run never touches the real backups" "$real_before" "$real_after"

echo "config-audit: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
