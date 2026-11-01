#!/usr/bin/env bash
# shellcheck disable=SC2015 # cond && pass || fail: pass and fail always return 0
# Tests for scripts/telegram/config-restore.py, the TOTP-gated station config
# restore the Telegram bridge runs.
# Usage: bash scripts/telegram/test-config-restore.sh
# Hermetic: a fixture HOME, a fixture .env, a fixed clock through
# CONFIG_RESTORE_NOW (honoured only under HIMMEL_TEST_FIXTURE=1). Values are
# planted dummies and must never appear in any output.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CR="$REPO_ROOT/scripts/telegram/config-restore.py"
CA="$REPO_ROOT/scripts/lib/config-audit.sh"
OP=4242
T0=1800000000

PASS=0 FAIL=0
pass() { printf '  PASS  %s\n' "$1"; PASS=$((PASS+1)); }
fail() { printf '  FAIL  %s\n' "$1"; [ -n "${2:-}" ] && printf '        got: %s\n' "$2"; FAIL=$((FAIL+1)); }
has() { case "$3" in *"$2"*) pass "$1" ;; *) fail "$1" "$3" ;; esac; }
lacks() { case "$3" in *"$2"*) fail "$1" "$3" ;; *) pass "$1" ;; esac; }

command -v python3 >/dev/null 2>&1 && command -v node >/dev/null 2>&1 || { echo "SKIP: python3 and node are needed"; exit 0; }
umask 022
T="$(mktemp -d "${TMPDIR:-/tmp}/config-restore-test.XXXXXX")" || exit 1
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/home/.himmel" "$T/tg"
printf '{"allowFrom":["%s"]}\n' "$OP" > "$T/tg/access.json"
: > "$T/env"
export HOME="$T/home" HIMMEL_CONFIG_DIR="" HIMMEL_CONFIG_AUDIT_ENV_FILE="$T/env" TELEGRAM_ACCESS_PATH="$T/tg/access.json" HIMMEL_TEST_FIXTURE=1
unset HIMMEL_CONFIG_AUDIT_DIR BRIDGE_ROOT HIMMEL_CONFIG_BACKUPS_KEEP HIMMEL_CONFIG_ALERT_CMD
CFG="$HOME/.himmel/config.json"

cr() { CONFIG_RESTORE_NOW="${NOW:-$T0}" python3 -I "$CR" "$@" 2>&1; }
code_at() { python3 -I -c 'import sys; sys.path.insert(0, sys.argv[1]); import approval_broker as ab
print(ab.totp(open(sys.argv[2]).read().strip(), int(sys.argv[3]) // 30))' "$REPO_ROOT/scripts/lib/afk-sudo" "$HOME/.himmel/secrets/config-restore.seed" "$1"; }
wrong_at() { local c; c="$(code_at "$1")"; printf '%06d' $(( (10#$c + 1) % 1000000 )); }
mode() { stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"; }

echo "== enroll =="
out="$(cr enroll)"
has "enroll prints the otpauth URI" "otpauth://totp/" "$out"
has "enroll records the operator id from allowFrom" "result=enrolled operator=$OP" "$out"
[ "$(mode "$HOME/.himmel/secrets/config-restore.seed")" = 600 ] && pass "seed is mode 600" || fail "seed mode" "$(mode "$HOME/.himmel/secrets/config-restore.seed")"
[ "$(mode "$HOME/.himmel/secrets")" = 700 ] && pass "secrets dir is mode 700" || fail "secrets dir mode"
out="$(cr enroll)"; rc=$?
[ "$rc" -ne 0 ] && has "a second enroll refuses without --force" "already-enrolled" "$out" || fail "second enroll rc=$rc" "$out"

echo "== enroll QR =="
# A stub qrencode records its argv; a pipe would encode a trailing newline that an
# authenticator app rejects, so the URI must arrive as ONE argument with none.
mkdir -p "$T/qrbin" "$T/pyonly"
# shellcheck disable=SC2016 # the stub's $ expansions are meant to be literal here
printf '#!/bin/sh\nprintf "%%s" "$#" > "$QR_ARGC"\nprintf "%%s" "$*" > "$QR_ARGV"\nfor a in "$@"; do uri="$a"; done\nprintf "%%s" "$uri" > "$QR_URI"\necho QR-DRAWN\n' > "$T/qrbin/qrencode"
chmod +x "$T/qrbin/qrencode"
ln -s "$(command -v python3)" "$T/pyonly/python3"
export QR_ARGC="$T/qr.argc" QR_ARGV="$T/qr.argv" QR_URI="$T/qr.uri"
out="$(PATH="$T/qrbin:$PATH" HIMMEL_CONFIG_DIR="$T/qr1" cr enroll)"
[ -e "$QR_URI" ] && pass "enroll calls qrencode" || fail "qrencode was never called" "$out"
has "enroll shows what qrencode drew" "QR-DRAWN" "$out"
uri_got="$(cat "$QR_URI" 2>/dev/null; printf x)" # the sentinel keeps a trailing newline from being stripped
case "$uri_got" in otpauth://totp/*"&issuer=himmel"x) pass "qrencode gets the URI with no trailing newline" ;; *) fail "qrencode URI" "$(od -c "$QR_URI" 2>/dev/null | tail -3)" ;; esac
[ "$(cat "$QR_ARGC" 2>/dev/null)" = 3 ] && has "qrencode is called as -t ansiutf8 URI" "-t ansiutf8 otpauth://" "$(cat "$QR_ARGV")" || fail "qrencode argc" "$(cat "$QR_ARGC" 2>/dev/null)"
out="$(PATH="$T/pyonly" HIMMEL_CONFIG_DIR="$T/qr2" cr enroll)"
has "without qrencode enroll still prints the URI" "otpauth://totp/" "$out"
has "without qrencode enroll hints how to get one" "qrencode" "$out"

echo "== a backup to restore =="
printf '{"policy":{"CR_FLOOR_FALLBACK":"planted-value-8401"},"fleet":{"cap":"planted-cap-8401"}}\n' > "$CFG"
bid="$(bash "$CA" pre "$CFG" --script test)"
bash "$CA" post "$bid" "$CFG" write --script test >/dev/null 2>&1
rm -f "$CFG"
out="$(cr list)"
has "list names the backup" "$bid" "$out"
has "list shows the key-name diff against the live set" "config.json back" "$out"
lacks "list prints no value" "planted-" "$out"

echo "== restore =="
out="$(printf '%s\n' "$(wrong_at "$T0")" | cr restore "$bid" --from "$OP" --chat "$OP")"; rc=$?
[ "$rc" -ne 0 ] && has "a wrong code is refused" "reason=wrong-code" "$out" || fail "wrong code rc=$rc" "$out"
[ ! -e "$CFG" ] && pass "a wrong code restores nothing" || fail "config.json came back on a wrong code"
NOW=$((T0+60))
out="$(printf '%s\n' "$(code_at "$NOW")" | cr restore "$bid" --from 999 --chat 999)"
has "a sender that is not the operator is refused" "reason=not-operator" "$out"
out="$(printf '%s\n' "$(code_at "$NOW")" | cr restore "$bid" --from "$OP" --chat "$OP")"; rc=$?
[ "$rc" -eq 0 ] && has "the right code restores" "result=restored id=$bid" "$out" || fail "right code rc=$rc" "$out"
lacks "the restore reply carries no value" "planted-" "$out"
grep -q 'planted-value-8401' "$CFG" 2>/dev/null && pass "config.json is back with its keys" || fail "config.json not restored"
row="$(grep '"action":"restore"' "$HOME/.himmel/state/config-audit/audit.jsonl" 2>/dev/null | tail -1)"
has "the restore wrote an audit row from config-restore.py" '"script":"config-restore.py"' "$row"
lacks "the audit row carries no value" "planted-" "$(cat "$HOME/.himmel/state/config-audit/audit.jsonl")"
lacks "the broker ledger carries no code" "$(code_at "$NOW")" "$(cat "$HOME/.himmel/state/config-restore-mfa/ledger.jsonl")"
out="$(printf '%s\n' "$(code_at "$NOW")" | cr restore "$bid" --from "$OP" --chat "$OP")"
has "a used code is refused as a replay" "reason=replay" "$out"

echo "== lockout =="
NOW=$((T0+300))
for _ in 1 2 3; do printf '%s\n' "$(wrong_at "$NOW")" | cr restore "$bid" --from "$OP" --chat "$OP" >/dev/null; done
out="$(printf '%s\n' "$(code_at "$NOW")" | cr restore "$bid" --from "$OP" --chat "$OP")"
has "three wrong codes lock the restore" "reason=locked" "$out"
NOW=$((T0+300+901))
out="$(printf '%s\n' "$(code_at "$NOW")" | cr restore "$bid" --from "$OP" --chat "$OP")"
has "past the lock, six requests in the hour hit the hourly cap" "reason=rate-limited" "$out"
NOW=$((T0+3700))
out="$(printf '%s\n' "$(code_at "$NOW")" | cr restore "$bid" --from "$OP" --chat "$OP")"
has "past the lock and the hour, a fresh code restores" "result=restored" "$out"

echo
if [ "$FAIL" -eq 0 ]; then echo "OK: $PASS cases passed"; exit 0; fi
echo "FAIL: $FAIL of $((PASS+FAIL)) cases failed"; exit 1
