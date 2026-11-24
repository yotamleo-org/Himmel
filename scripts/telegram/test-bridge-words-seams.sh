#!/usr/bin/env bash
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
FIX="$HERE/fixtures/operator-words"
VERIFIER="$HERE/operator-words.ts"
GITLEAKS_CHECK="$REPO/scripts/handover/chief-kit/bucket-gitleaks.sh"

PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); printf 'ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf 'FAIL %s\n' "$1"; [ -n "${2:-}" ] && printf '     %s\n' "$2"; }
eq()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "want [$3] got [$2]"; fi; }

command -v bun >/dev/null 2>&1 || { echo "SKIP: bun not installed"; exit 0; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/bridge-words-seams.XXXXXX")" || exit 2
trap 'rm -rf "$TMP"' EXIT
BUN_BIN="$(command -v bun)"

HOME_S="$TMP/home"
mkdir -p "$HOME_S/.claude/handover/bridge" "$HOME_S/.claude/channels/telegram"
cp "$FIX/inbound.jsonl" "$HOME_S/.claude/handover/bridge/inbound.jsonl"
cp "$FIX/access.json" "$HOME_S/.claude/channels/telegram/access.json"

pinned() { (cd "$REPO" && env -i PATH="$PATH" HOME="$HOME_S" LANG="${LANG:-C}" TZ="${TZ:-UTC}" "$BUN_BIN" "$VERIFIER" "$@"); }

WANT='{"update_id":900000001,"from":111,"chat_id":111,"ts":1762817400,"message_id":71,"text":"File it and give it to the chief for 1.1.3 as well, it is the lost-line bug"}'
OUT="$(pinned --update 900000001 2>"$TMP/err")"; RC=$?
eq "T6 the real verifier under the pinned env prints the operator's line byte-equal" "$OUT" "$WANT"
eq "T6 ... and exits 0 with nothing on stderr" "$RC:$(cat "$TMP/err")" "0:"

OUT="$(pinned --update 900000002 2>"$TMP/err")"; RC=$?
eq "T6b a forwarded line prints nothing on stdout and exits 1" "$RC:$OUT" "1:"
eq "T6b ... with one reason line on stderr" "$(cat "$TMP/err")" "update 900000002 is forwarded"

OUT="$(pinned --update 900000001 --root /nowhere 2>/dev/null)"; RC=$?
eq "T6b the CLI exposes no --root: an extra argument refuses and prints nothing" "$RC:$OUT" "1:"
OUT="$(pinned --update 12x 2>/dev/null)"; RC=$?
eq "T6b a non-digit update id refuses and prints nothing" "$RC:$OUT" "1:"
OUT="$(pinned 2>/dev/null)"; RC=$?
eq "T6b no --update refuses and prints nothing" "$RC:$OUT" "1:"

printf 'await Bun.write(process.env.PRELOAD_MARK ?? "/dev/null", "ran");\n' > "$TMP/preload.ts"
MARK="$TMP/mark-control"
( cd "$REPO" && PRELOAD_MARK="$MARK" BUN_OPTIONS="--preload $TMP/preload.ts" HOME="$HOME_S" "$BUN_BIN" "$VERIFIER" --update 900000001 >/dev/null 2>&1 )
if [ -f "$MARK" ]; then ok "T6b control: a BUN_OPTIONS preload reaches an unpinned spawn"; else bad "T6b control: the BUN_OPTIONS preload did not land, so the next row proves nothing"; fi
MARK="$TMP/mark-pinned"
OUT="$(PRELOAD_MARK="$MARK" BUN_OPTIONS="--preload $TMP/preload.ts" pinned --update 900000001 2>/dev/null)"
eq "T6b a BUN_OPTIONS preload in the outer env does not reach the pinned spawn" "$([ -f "$MARK" ] && echo reached || echo absent):$OUT" "absent:$WANT"

SECRET="gh""p_$(printf 'aB3dE5fG7hJ9kL1mN3pQ5rS7tU9vW1xY3zA5')"
printf 'Decision 900000007, operator.\n\nput it in 1.1.3, and the key is %s\n' "$SECRET" > "$TMP/dirty.txt"
printf 'Decision 900000001, operator.\n\nFile it into 1.1.3 please.\n' > "$TMP/clean.txt"
bash "$GITLEAKS_CHECK" "$TMP/dirty.txt" >/dev/null 2>&1; RC=$?
if [ "$RC" -ne 0 ]; then ok "a draft holding a secret exits non-zero (rc=$RC)"; else bad "a draft holding a secret exits 0"; fi
bash "$GITLEAKS_CHECK" "$TMP/clean.txt" >/dev/null 2>&1; RC=$?
eq "a clean draft exits 0" "$RC" "0"
mkdir -p "$TMP/nogl"
ln -s "$(command -v dirname)" "$TMP/nogl/dirname"
PATH="$TMP/nogl" /bin/bash "$GITLEAKS_CHECK" "$TMP/clean.txt" >/dev/null 2>&1; RC=$?
eq "with gitleaks off PATH it exits 2" "$RC" "2"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
