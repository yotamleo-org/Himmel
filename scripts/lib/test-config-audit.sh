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
# Only the backup id list and the audit row count: a live bridge rewrites watch.json, so mtimes would flake.
real_marks() { ls "$REAL_STATE/backups" 2>&1; wc -l < "$REAL_STATE/audit.jsonl" 2>/dev/null; }
real_before=$(real_marks)

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
good=$(bash "$CA" check | awk -F'\t' '$1 == "LOSS" && $2 == "config.json" { print $5 }')
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
: > "$HIMMEL_CONFIG_DIR/himmel.conf.local"
bash "$CA" accept >/dev/null
rm -f "$HIMMEL_CONFIG_DIR/himmel.conf.local"
out=$(bash "$CA" check)
eq "4 an empty lost-key list prints -" "-" "$(printf '%s\n' "$out" | awk -F'\t' '$1 == "LOSS" && $2 == "himmel.conf.local" { print $4 }')"
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
# An unreadable config.json is reported as such: load_policy fails closed on it.
printf '{"policy":\n' > "$HIMMEL_CONFIG_DIR/config.json"
printf '%s\nCR_REQUIRE_CROSS_MODEL=0\n' "$saved_env" > "$TMP/clone/.env"
badid=$(bash "$CA" pre "$HIMMEL_CONFIG_DIR/config.json" --script test)
printf '%s\n' "$saved_env" > "$TMP/clone/.env"
out=$(bash "$CA" restore "$badid" --script test-restore 2>&1)
has "4 an unreadable config.json is named" "config.json cannot be read" "$out"
lacks "4 a policy key beside an unreadable config.json is not said to still work" "they still work" "$out"
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
cp "$HERE/himmel-secrets" "$FX/scripts/lib/"
cp "$REPO/scripts/himmelctl/lib/config-keys.json" "$REPO/scripts/himmelctl/lib/secrets-manifest.json" "$FX/scripts/himmelctl/lib/"
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
# --- 9. scrub: secret lines leave every backup's .env, and the manifest stays true ---
printf 'JIRA_API_TOKEN=%s\nexport OTHER_TOKEN=%s\nKEEP_A=1\nONLY_COPY=%s\n' "$CANARY-j" "$CANARY-o" "$CANARY-c" > "$TMP/clone/.env"
sid=$(bash "$CA" pre "$HIMMEL_CONFIG_DIR/config.json" --script test)
out=$(bash "$CA" scrub --dry-run " JIRA_API_TOKEN OTHER_TOKEN " " JIRA_API_TOKEN OTHER_TOKEN ONLY_COPY ")
has "9 a dry run names the backup it would scrub" "would-scrub $sid" "$out"
has "9 a dry run changes nothing" "JIRA_API_TOKEN=" "$(cat "$STATE/backups/$sid/.env")"
out=$(bash "$CA" scrub " JIRA_API_TOKEN OTHER_TOKEN " " JIRA_API_TOKEN OTHER_TOKEN ONLY_COPY ")
has "9 the scrub names the backup it changed" "scrubbed $sid" "$out"
has "9 the scrub names a line with no other copy" "kept $sid ONLY_COPY" "$out"
lacks "9 the scrub prints no value" "$CANARY" "$out"
bk=$(cat "$STATE/backups/$sid/.env")
lacks "9 the plain secret line left the backup" "JIRA_API_TOKEN" "$bk"
lacks "9 the exported secret line left the backup" "OTHER_TOKEN" "$bk"
has "9 a line outside the set stays" "KEEP_A=1" "$bk"
has "9 a line with no other copy stays" "ONLY_COPY=" "$bk"
eq "9 the scrubbed backup is mode 600" 600 "$(stat -c %a "$STATE/backups/$sid/.env" 2>/dev/null || stat -f %Lp "$STATE/backups/$sid/.env")"
mfok=$(node -e 'const fs=require("fs"),c=require("crypto"),d=process.argv[1];
    const m=JSON.parse(fs.readFileSync(d+"/manifest.json","utf8")), h=(b)=>c.createHash("sha256").update(b).digest("hex");
    const ok=m.files[".env"].sha256===h(fs.readFileSync(d+"/.env")) && m.digest===h(Buffer.from(JSON.stringify(Object.keys(m.files).map((n)=>[n,m.files[n].sha256]))));
    process.stdout.write(ok?"true":"false")' "$STATE/backups/$sid")
eq "9 the manifest sha256 and digest match the scrubbed file" true "$mfok"
out=$(bash "$CA" restore "$sid" --script test-restore)
has "9 a scrubbed backup still restores" "result=restored id=$sid" "$out"
out=$(bash "$CA" scrub " JIRA_API_TOKEN OTHER_TOKEN " " JIRA_API_TOKEN OTHER_TOKEN ONLY_COPY ")
lacks "9 a second scrub changes nothing" "scrubbed $sid" "$out"

# --- 10. a healthy watch keeps a value backup, so an unaudited delete restores ---
# Each row builds its own temp station (S10) through the seams; nothing here
# reaches the real home. Values are fixture canaries, compared and never printed.
S10="$TMP/s10"
S10_STATE="$S10/.himmel/state/config-audit"
st() { HIMMEL_CONFIG_DIR="$S10/.himmel" HIMMEL_CONFIG_AUDIT_ENV_FILE="$S10/clone/.env" bash "$CA" "$@"; }
new_station() { rm -rf "$S10"; mkdir -p "$S10/.himmel" "$S10/clone"; : > "$ALERTS"; }
nbk() { local d n=0; for d in "$S10_STATE"/backups/*/; do [ -d "$d" ] && n=$((n + 1)); done; echo "$n"; }
mode_of() { stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"; } # gnu-ok: the BSD form follows on the same line
holds() { grep -q -- "$2" "$1" 2>/dev/null; }
V1="$CANARY-v1"; V2="$CANARY-v2"
put_station() {
    printf '{"version":1,"policy":{"HIMMEL_FLEET_CAP":"%s"}}\n' "$1" > "$S10/.himmel/config.json"
    printf 'HANDOVER_DIR=%s\nHIMMEL_INITIATIVE=execute\n' "$1" > "$S10/.himmel/himmel.conf"
    printf 'JIRA_PROJECT_KEY=HIMMEL\n' > "$S10/clone/.env"
}

# 10a. config.json deleted with no audited write: the backup holds the values, mode 600.
new_station; put_station "$V1"
eq "10a control: no watch snapshot yet" absent "$([ -f "$S10_STATE/watch.json" ] && echo present || echo absent)"
st watch 2>/dev/null
n_before=$(nbk)
rm -f "$S10/.himmel/config.json"
st watch 2>/dev/null
bid=$(st check | awk -F'\t' '$1 == "LOSS" && $2 == "config.json" { print $5 }')
case "$bid" in [0-9]*T[0-9]*Z-*) pass "10a the alert path names a backup id" ;; *) fail "10a no backup id named (got '$bid')" ;; esac
if holds "$S10_STATE/backups/$bid/config.json" "$V1"; then pass "10a the named backup holds the config.json value"; else fail "10a the named backup lacks the config.json value"; fi
eq "10a the backup config.json is mode 600" 600 "$(mode_of "$S10_STATE/backups/$bid/config.json")"
has "10a the alert names the backup" "newest good backup $bid" "$(cat "$ALERTS")"
lacks "10a alerts.jsonl does not say backup null" '"backup":null' "$(cat "$S10_STATE/alerts.jsonl" 2>/dev/null)"
has "10a alerts.jsonl carries the backup id" "\"backup\":\"$bid\"" "$(cat "$S10_STATE/alerts.jsonl" 2>/dev/null)"
st watch 2>/dev/null; st watch 2>/dev/null
eq "10a a watch over a deleted file writes no backup" "$n_before" "$(nbk)"
lacks "10a no value reaches the alert" "$V1" "$(cat "$ALERTS")"

# 10f. restore of that backup brings the values back.
out=$(st restore "$bid" --script test-restore)
has "10f restore reports the id" "result=restored id=$bid" "$out"
if holds "$S10/.himmel/config.json" "$V1"; then pass "10f the restored config.json holds the value"; else fail "10f the restored config.json lacks the value"; fi

# 10b. the same with himmel.conf.
new_station; put_station "$V1"
st watch 2>/dev/null
rm -f "$S10/.himmel/himmel.conf"
st watch 2>/dev/null
bid=$(st check | awk -F'\t' '$1 == "LOSS" && $2 == "himmel.conf" { print $5 }')
case "$bid" in [0-9]*T[0-9]*Z-*) pass "10b the alert path names a backup id" ;; *) fail "10b no backup id named (got '$bid')" ;; esac
if holds "$S10_STATE/backups/$bid/himmel.conf" "$V1"; then pass "10b the named backup holds the himmel.conf value"; else fail "10b the named backup lacks the himmel.conf value"; fi
eq "10b the backup himmel.conf is mode 600" 600 "$(mode_of "$S10_STATE/backups/$bid/himmel.conf")"
has "10b the alert names the backup" "newest good backup $bid" "$(cat "$ALERTS")"

# 10c. a changed value, then a deletion: both generations stay.
new_station; put_station "$V1"
st watch 2>/dev/null
put_station "$V2"
st watch 2>/dev/null
rm -f "$S10/.himmel/config.json"
st watch 2>/dev/null
g1=0; g2=0
for d in "$S10_STATE"/backups/*/; do
    holds "$d/config.json" "$V1" && g1=$((g1 + 1))
    holds "$d/config.json" "$V2" && g2=$((g2 + 1))
done
eq "10c the first value's backup is still there" 1 "$g1"
eq "10c the changed value has its own backup" 1 "$g2"

# 10d. an unchanged set writes one backup, however often watch runs; a change writes a second.
new_station; put_station "$V1"
st watch 2>/dev/null; st watch 2>/dev/null; st watch 2>/dev/null
eq "10d three healthy watches of an unchanged set write one backup" 1 "$(nbk)"
put_station "$V2"
st watch 2>/dev/null
eq "10d a changed value writes a second backup" 2 "$(nbk)"

# 10e. the first watch, with no snapshot yet, backs up (a fresh station stays covered).
new_station; put_station "$V1"
st watch 2>/dev/null
eq "10e the first watch backs the set up" 1 "$(nbk)"

# 10g. check names the newest backup and its age, and warns on a present file with none.
new_station; put_station "$V1"
out=$(st check); rc=$?
has "10g a present file with no backup is named" "NOBACKUP	config.json" "$out"
eq "10g a missing backup is not a loss" 0 "$rc"
st watch 2>/dev/null
out=$(st check); rc=$?
lacks "10g no warning once every file has a backup" "NOBACKUP" "$out"
has "10g check names the newest backup" "BACKUP	$(ls "$S10_STATE/backups")	" "$out"
case "$(printf '%s\n' "$out" | awk -F'\t' '$1 == "BACKUP" { print $3 }')" in [0-9]*[smhd]) pass "10g check prints the age" ;; *) fail "10g check prints no age" ;; esac
eq "10g a healthy set still exits 0" 0 "$rc"

# 10h. watch backups and audited backups prune apart: watch churn never evicts an audited one.
new_station; put_station "$V1"
aid=$(st pre "$S10/.himmel/config.json" --script test)
for i in 1 2 3 4; do
    put_station "$V1-$i"
    HIMMEL_CONFIG_BACKUPS_KEEP=2 st watch 2>/dev/null
done
if [ -d "$S10_STATE/backups/$aid" ]; then pass "10h watch churn leaves the audited backup"; else fail "10h watch churn evicted the audited backup"; fi
eq "10h watch backups are kept to KEEP" 3 "$(nbk)"

# 10i. the watcher leaves .env out, so a scrubbed secret is not copied back within a pass.
new_station; put_station "$V1"
printf 'JIRA_API_TOKEN=%s\nKEEP_A=1\n' "$V1" > "$S10/clone/.env"
sid=$(st pre "$S10/.himmel/config.json" --script test)
if holds "$S10_STATE/backups/$sid/.env" "$V1"; then pass "10i control: the audited backup holds the secret line"; else fail "10i control: the audited backup lacks the secret line"; fi
st scrub " JIRA_API_TOKEN " " JIRA_API_TOKEN " >/dev/null
st watch 2>/dev/null; st watch 2>/dev/null
leaks=0; envs=0
for d in "$S10_STATE"/backups/*/; do
    holds "$d/.env" "$V1" && leaks=$((leaks + 1))
    case "$d" in *"/$sid/") ;; *) [ -f "$d/.env" ] && envs=$((envs + 1)) ;; esac
done
eq "10i the scrubbed secret is in no backup after two watch passes" 0 "$leaks"
eq "10i a watch pass copies no .env" 0 "$envs"
eq "10i the watch pass still backed the config files up" 2 "$(nbk)"

# 10j. an audited pre after a watch pass writes its own backup, and watch churn never evicts it.
new_station; put_station "$V1"
st watch 2>/dev/null
wid=$(ls "$S10_STATE/backups")
aid=$(st pre "$S10/.himmel/config.json" --script test)
if [ -n "$aid" ] && [ "$aid" != "$wid" ]; then pass "10j an audited pre after a watch writes its own backup"; else fail "10j the audited pre returned the watcher backup (aid '$aid', wid '$wid')"; fi
for i in 1 2 3 4; do
    put_station "$V1-$i"
    HIMMEL_CONFIG_BACKUPS_KEEP=2 st watch 2>/dev/null
done
if [ -d "$S10_STATE/backups/$aid" ]; then pass "10j the audited backup survives watch churn"; else fail "10j watch churn evicted the audited backup"; fi

# 10j2. a value that flips back reuses its earlier backup: a flapping value writes nothing.
new_station; put_station "$V1"
st watch 2>/dev/null
put_station "$V2"
st watch 2>/dev/null
put_station "$V1"
st watch 2>/dev/null
put_station "$V2"
st watch 2>/dev/null
eq "10j a flapping value writes two backups, not four" 2 "$(nbk)"
newest=$(st check | awk -F'\t' '$1 == "BACKUP" { print $2 }')
if holds "$S10_STATE/backups/$newest/config.json" "$V2"; then pass "10j the newest backup is the current value's"; else fail "10j the newest backup is not the current value's"; fi

# 10j3. move to front. Each row fails with the move deleted: the reused backup stays where it was.
newest_id() { st check | awk -F'\t' '$1 == "BACKUP" { print $2 }'; }
# (a) A, B, A: the newest backup is A's.
new_station; put_station "$V1-A"; st watch 2>/dev/null
id_a=$(newest_id)
if [ -n "$id_a" ]; then pass "10j3 the first watch keeps a backup"; else fail "10j3 the first watch kept no backup"; fi
put_station "$V1-B"; st watch 2>/dev/null
put_station "$V1-A"; st watch 2>/dev/null
eq "10j3 A, B, A: the newest backup is A's" "$id_a" "$(newest_id)"
# (b) A, B, C, A, D at KEEP=3 keeps A and evicts B.
new_station; put_station "$V1-A"; HIMMEL_CONFIG_BACKUPS_KEEP=3 st watch 2>/dev/null
id_a=$(newest_id)
put_station "$V1-B"; HIMMEL_CONFIG_BACKUPS_KEEP=3 st watch 2>/dev/null
id_b=$(newest_id)
put_station "$V1-C"; HIMMEL_CONFIG_BACKUPS_KEEP=3 st watch 2>/dev/null
put_station "$V1-A"; HIMMEL_CONFIG_BACKUPS_KEEP=3 st watch 2>/dev/null
put_station "$V1-D"; HIMMEL_CONFIG_BACKUPS_KEEP=3 st watch 2>/dev/null
if [ -d "$S10_STATE/backups/$id_a" ]; then pass "10j3 A, B, C, A, D at KEEP=3: A's backup is kept"; else fail "10j3 A, B, C, A, D at KEEP=3: A's backup was evicted"; fi
if [ ! -d "$S10_STATE/backups/$id_b" ]; then pass "10j3 A, B, C, A, D at KEEP=3: B's backup is evicted"; else fail "10j3 A, B, C, A, D at KEEP=3: B's backup stayed"; fi
# (c) A, B, A, then a delete: the alert names A's backup.
new_station; put_station "$V1-A"; st watch 2>/dev/null
id_a=$(newest_id)
put_station "$V1-B"; st watch 2>/dev/null
put_station "$V1-A"; st watch 2>/dev/null
rm -f "$S10/.himmel/config.json"
st watch 2>/dev/null
has "10j3 A, B, A, delete: the alert names A's backup" "newest good backup $id_a" "$(cat "$ALERTS")"

# 10k. a dir whose manifest is missing or not JSON (a killed or failed write) is removed after the grace
# period, not before; a manifest that cannot be read for another reason says nothing, so that dir stays.
new_station; put_station "$V1"
st watch 2>/dev/null
mkdir -p "$S10_STATE/backups/20200101T000000Z-aaaa" "$S10_STATE/backups/20200101T000000Z-bbbb" "$S10_STATE/backups/20200101T000000Z-cccc"
printf 'partial\n' > "$S10_STATE/backups/20200101T000000Z-aaaa/.env"
printf 'not json\n' > "$S10_STATE/backups/20200101T000000Z-cccc/manifest.json"
touch -t 202001010000 "$S10_STATE/backups/20200101T000000Z-aaaa" "$S10_STATE/backups/20200101T000000Z-cccc"
if [ "$(id -u)" != 0 ]; then
    mkdir -p "$S10_STATE/backups/20200101T000000Z-dddd"
    printf '{"ts":"2020-01-01T00:00:00Z","files":{}}\n' > "$S10_STATE/backups/20200101T000000Z-dddd/manifest.json"
    chmod 000 "$S10_STATE/backups/20200101T000000Z-dddd/manifest.json"
    touch -t 202001010000 "$S10_STATE/backups/20200101T000000Z-dddd"
fi
put_station "$V2"
st watch 2>/dev/null
if [ ! -d "$S10_STATE/backups/20200101T000000Z-aaaa" ]; then pass "10k an old dir with no manifest is removed"; else fail "10k an old dir with no manifest stayed"; fi
if [ ! -d "$S10_STATE/backups/20200101T000000Z-cccc" ]; then pass "10k an old dir with a manifest that is not JSON is removed"; else fail "10k an old dir with a manifest that is not JSON stayed"; fi
if [ -d "$S10_STATE/backups/20200101T000000Z-bbbb" ]; then pass "10k a fresh dir with no manifest stays (it may be mid-write)"; else fail "10k a fresh dir with no manifest was removed"; fi
if [ "$(id -u)" != 0 ]; then
    if [ -d "$S10_STATE/backups/20200101T000000Z-dddd" ]; then pass "10k an old dir whose manifest cannot be read stays"; else fail "10k an old dir whose manifest cannot be read was removed"; fi
fi

# 10l. a backup that cannot be written is reported, not silent.
if [ "$(id -u)" != 0 ]; then
    new_station; put_station "$V1"
    st watch 2>/dev/null
    put_station "$V2"
    chmod 555 "$S10_STATE/backups"
    err=$(st watch 2>&1 >/dev/null); rc=$?
    chmod 755 "$S10_STATE/backups"
    eq "10l a failed backup exits 4" 4 "$rc"
    has "10l a failed backup says so on stderr" "WARN: no healthy backup was kept" "$err"
    eq "10l a failed backup leaves no orphan dir" 1 "$(nbk)"
    st watch 2>/dev/null; rc=$?
    eq "10l control: the next pass, with the dir writable, exits 0" 0 "$rc"
    eq "10l control: and keeps the backup" 2 "$(nbk)"
fi

# 10l2. the id dir is made and the copy then fails (a file-size limit, EFBIG): exit 4, a WARN, no dir left.
# The limit also cuts the first write short, so a copy is never kept truncated: that is the short-write loop.
if [ "$(id -u)" != 0 ] && ( ulimit -f 4 ) 2>/dev/null; then
    new_station; put_station "$V1"
    st watch 2>/dev/null
    big=$(head -c 20000 /dev/zero | tr '\0' x)
    printf '{"version":1,"policy":{"HIMMEL_FLEET_CAP":"%s"}}\n' "$big" > "$S10/.himmel/config.json"
    err=$( ( trap '' XFSZ; ulimit -f 4; st watch ) 2>&1 >/dev/null ); rc=$?
    eq "10l2 a copy that fails after the dir is made exits 4" 4 "$rc"
    has "10l2 and says so on stderr" "WARN: no healthy backup was kept" "$err"
    eq "10l2 and leaves no dir behind" 1 "$(nbk)"
    st watch 2>/dev/null; rc=$?
    eq "10l2 control: without the limit the next pass exits 0" 0 "$rc"
    newest=$(newest_id)
    if cmp -s "$S10/.himmel/config.json" "$S10_STATE/backups/$newest/config.json"; then pass "10l2 control: and the kept copy is whole"; else fail "10l2 control: the kept copy differs from the file"; fi
fi

# 10m. no set member present: no backup, and check names none.
new_station
printf 'JIRA_PROJECT_KEY=HIMMEL\n' > "$S10/clone/.env"
st watch 2>/dev/null
eq "10m a set with only .env present writes no backup" 0 "$(nbk)"
lacks "10m check prints no BACKUP row for an empty store" "BACKUP	" "$(st check)"
new_station; put_station "$V1"
st watch 2>/dev/null
real_id=$(ls "$S10_STATE/backups")
mkdir -p "$S10_STATE/backups/20991231T000000Z-0000"
printf '{"ts":"2099-12-31T00:00:00Z","script":"x","ms":4102444800000,"target":"%s","files":{}}\n' "$TMP/order" > "$S10_STATE/backups/20991231T000000Z-0000/manifest.json"
eq "10m BACKUP names a backup that holds a file, not an empty manifest" "$real_id" "$(st check | awk -F'\t' '$1 == "BACKUP" { print $2 }')"

# 10n. accept takes a backup; a truncated, partial or key-losing file takes none.
new_station; put_station "$V1"
st watch 2>/dev/null
put_station "$V2"
st accept >/dev/null
eq "10n accept backs the accepted set up" 2 "$(nbk)"
# One station per case, each starting from one healthy backup: a case that took a backup reads 2.
new_station; put_station "$V1"
st watch 2>/dev/null
printf '{"version":1}\n' > "$S10/.himmel/config.json"
st watch 2>/dev/null
eq "10n a key-losing config.json takes no backup" 1 "$(nbk)"
has "10n and alerts" "lost keys" "$(cat "$ALERTS")"
new_station; put_station "$V1"
st watch 2>/dev/null
printf '{"policy":' > "$S10/.himmel/config.json"
st watch 2>/dev/null
eq "10n a partial config.json takes no backup" 1 "$(nbk)"
has "10n and alerts" "config.json truncated" "$(cat "$ALERTS")"
new_station; put_station "$V1"
st watch 2>/dev/null
: > "$S10/.himmel/himmel.conf"
st watch 2>/dev/null
eq "10n a truncated himmel.conf takes no backup" 1 "$(nbk)"
has "10n and alerts" "himmel.conf truncated" "$(cat "$ALERTS")"
rm -rf "$S10"

put_env11() { printf 'JIRA_PROJECT_KEY=HIMMEL\n%s\n' "$1" > "$S10/clone/.env"; }
RA="$CANARY-ra"; RB="$CANARY-rb"
new_station; put_station "$V1"
put_env11 "$(printf 'TELEGRAMTESTBOTA=%s\nTELEGRAMTESTBOTB=%s' "$RA" "$RB")"
st watch 2>/dev/null
put_env11 "$(printf 'TELEGRAMTESTABOT=%s\nTELEGRAMTESTBOTB=%s' "$RA" "$RB")"
out=$(st check); rc=$?
eq "11a a renamed key exits 0 from check" 0 "$rc"
has "11a check names the old and the new name" "RENAME	.env	TELEGRAMTESTBOTA	TELEGRAMTESTABOT" "$out"
lacks "11a no LOSS row for a rename" "LOSS" "$out"
lacks "11a no value reaches the check rows" "$CANARY" "$out"
put_env11 "$(printf 'TELEGRAMTESTBOTB=%s' "$RB")"
out=$(st check); rc=$?
eq "11b control: a deleted key exits 3" 3 "$rc"
has "11b control: a deleted key is a LOSS row" "LOSS	.env	lost keys	TELEGRAMTESTBOTA" "$out"
lacks "11b control: a deleted key is not a rename" "RENAME" "$out"
put_env11 "$(printf 'TELEGRAMTESTABOT=%s-changed\nTELEGRAMTESTBOTB=%s' "$RA" "$RB")"
out=$(st check); rc=$?
eq "11c control: a rename with a new value exits 3" 3 "$rc"
has "11c control: and names the lost key" "TELEGRAMTESTBOTA" "$out"
new_station; put_station "$V1"
put_env11 "$(printf 'TELEGRAMTESTBOTA=%s\nTELEGRAMTESTBOTB=%s' "$RA" "$RB")"
st watch 2>/dev/null
put_env11 "$(printf 'TELEGRAMTESTABOT=%s\nTELEGRAMTESTBBOT=%s' "$RA" "$RB")"
err=$(st watch 2>&1 >/dev/null); rc=$?
eq "11d a rename sends no alert" 0 "$(wc -l < "$ALERTS" | tr -d ' ')"
eq "11d a rename exits 0 from watch" 0 "$rc"
has "11d the watch text names a rename" "renamed" "$err"
has "11d the watch text names both renames" "TELEGRAMTESTBOTB to TELEGRAMTESTBBOT" "$err"
lacks "11d the rename text is not the alert wording" "⚠️" "$err"
lacks "11d no value reaches the rename text" "$CANARY" "$err"
out=$(st check); rc=$?
eq "11d the rename is the new baseline: check stays quiet" 0 "$rc"
lacks "11d and prints no RENAME row again" "RENAME" "$out"
err=$(st watch 2>&1 >/dev/null)
lacks "11d and the next watch says nothing" "renamed" "$err"
put_env11 "$(printf 'TELEGRAMTESTABOT=%s' "$RA")"
st watch 2>/dev/null
has "11d control: a real loss keeps the alert wording" "⚠️ himmel station config" "$(cat "$ALERTS")"
has "11d control: and names the lost key" "TELEGRAMTESTBBOT" "$(cat "$ALERTS")"
new_station; put_station "$V1"
put_env11 "$(printf 'TELEGRAMTESTBOTA=%s' "$RA")"
st watch 2>/dev/null
node -e 'const f=process.argv[1],fs=require("fs"),w=JSON.parse(fs.readFileSync(f,"utf8"));for(const n of Object.keys(w))delete w[n].digests;fs.writeFileSync(f,JSON.stringify(w));' "$S10_STATE/watch.json"
put_env11 "$(printf 'TELEGRAMTESTABOT=%s' "$RA")"
out=$(st check); rc=$?
eq "11e control: an older watch.json without digests reads a rename as a loss" 3 "$rc"
rm -rf "$S10"

# --- 12. the set's .env comes from the himmel checkout, never the caller's directory ---
# The layout the ticket saw: the script runs from a linked worktree under
# <primary>/.claude/worktrees/, the .env lives only in the primary checkout, and
# the chief's shell sits in the luna handover bucket, inside a git repo of its own
# with no .env.
S12="$TMP/s12"; PRIM="$S12/github/himmel"; WT="$PRIM/.claude/worktrees/fix+w"
BUCKET="$S12/luna/handovers/yotamleo/himmel"
S12_STATE="$S12/.himmel/state/config-audit"
mkdir -p "$S12/.himmel" "$BUCKET"
git -C "$PRIM" init -q 2>/dev/null || git init -q "$PRIM"
git -C "$PRIM" -c user.name=t -c user.email=t@example.invalid commit -q --allow-empty -m init
git -C "$PRIM" worktree add -q "$WT" 2>/dev/null
git -C "$S12/luna" init -q 2>/dev/null || git init -q "$S12/luna"
mkdir -p "$WT/scripts/lib" "$WT/scripts/himmelctl/lib"
cp "$HERE/load-dotenv.sh" "$HERE/prim.sh" "$HERE/canon-path.sh" "$HERE/chokepoint-seam-guard.sh" "$HERE/himmel-secrets" "$CA" "$WT/scripts/lib/"
cp "$REPO/scripts/himmelctl/lib/config-keys.json" "$REPO/scripts/himmelctl/lib/secrets-manifest.json" "$WT/scripts/himmelctl/lib/"
printf '{"version":1,"policy":{"HIMMEL_FLEET_CAP":"40"}}\n' > "$S12/.himmel/config.json"
printf 'JIRA_PROJECT_KEY=HIMMEL\nJIRA_API_TOKEN=%s\nALIBABA_QUOTA_AK=%s\n' "$CANARY" "$CANARY" > "$PRIM/.env"
# The script copy in the fixture worktree, run from the bucket with no seam: its own checkout decides.
s12() { ( cd "$BUCKET" && env -u HIMMEL_CONFIG_AUDIT_ENV_FILE -u HIMMEL_REPO HIMMEL_CONFIG_DIR="$S12/.himmel" bash "$WT/scripts/lib/config-audit.sh" "$@" ); }
# The station's own script, pointed at the fixture checkout by HIMMEL_REPO.
s12r() { ( cd "$BUCKET" && env -u HIMMEL_CONFIG_AUDIT_ENV_FILE HIMMEL_REPO="$WT" HIMMEL_CONFIG_DIR="$S12/.himmel" bash "$CA" "$@" ); }
HIMMEL_CONFIG_DIR="$S12/.himmel" HIMMEL_CONFIG_AUDIT_ENV_FILE="$PRIM/.env" bash "$CA" watch 2>/dev/null
has "12 control: the baseline holds the checkout's .env keys" "ALIBABA_QUOTA_AK" "$(cat "$S12_STATE/watch.json" 2>/dev/null)"
: > "$ALERTS"

# 12a. check and watch from the bucket read the checkout's .env.
out=$(s12 check); rc=$?
eq "12a check from another repo's directory exits 0" 0 "$rc"
lacks "12a and reports no deleted .env" "deleted" "$out"
out=$(s12r check); rc=$?
eq "12a HIMMEL_REPO names the checkout: check exits 0" 0 "$rc"
s12 watch 2>/dev/null
eq "12a watch from another repo's directory sends no alert" 0 "$(wc -l < "$ALERTS" | tr -d ' ')"
has "12a and keeps the .env keys in the baseline" "ALIBABA_QUOTA_AK" "$(cat "$S12_STATE/watch.json" 2>/dev/null)"

# 12b. with no .env found, accept refuses and leaves watch.json byte for byte.
mv "$PRIM/.env" "$S12/env.away"
cp "$S12_STATE/watch.json" "$S12/watch.before"
out=$(s12 accept 2>&1); rc=$?
eq "12b accept with no .env found exits 1" 1 "$rc"
if cmp -s "$S12/watch.before" "$S12_STATE/watch.json"; then pass "12b and leaves watch.json unchanged"; else fail "12b accept rewrote watch.json"; fi
has "12b the refusal says no .env was found" "no .env" "$out"

# 12c. with no .env found, check reports unknown, never deleted; watch alerts nothing and keeps the keys.
out=$(s12 check); rc=$?
eq "12c check with no .env found exits 0" 0 "$rc"
has "12c and reports the .env unknown" "UNKNOWN	.env	no file found" "$out"
lacks "12c and never deleted" "deleted" "$out"
s12 watch 2>/dev/null
eq "12c watch with no .env found sends no alert" 0 "$(wc -l < "$ALERTS" | tr -d ' ')"
has "12c and keeps the .env keys in the baseline" "ALIBABA_QUOTA_AK" "$(cat "$S12_STATE/watch.json" 2>/dev/null)"

# 12d. control: a key really deleted from the checkout's .env is still a loss, from the bucket.
grep -v '^ALIBABA_QUOTA_AK=' "$S12/env.away" > "$PRIM/.env"
out=$(s12 check); rc=$?
eq "12d control: a lost key exits 3" 3 "$rc"
has "12d control: and names it" "LOSS	.env	lost keys	ALIBABA_QUOTA_AK" "$out"
lacks "12d no value reaches the output" "$CANARY" "$out"
git -C "$PRIM" worktree remove --force "$WT" 2>/dev/null
rm -rf "$S12"

real_after=$(real_marks)
eq "8 a fixture-HOME run never touches the real backups" "$real_before" "$real_after"

echo "config-audit: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
