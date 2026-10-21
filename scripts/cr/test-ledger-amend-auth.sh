#!/usr/bin/env bash
# scripts/cr/test-ledger-amend-auth.sh - suite for ledger-amend-auth.js, the
# rule every CR gate reader applies before it merges amend rows:
#   1. no signed row yet: every amend is honoured (the cutover is unset).
#   2. a signed row sets the cutover: rows above it are honoured unsigned,
#      a lowering amend below it counts only with a valid mac.
#   3. a tampered set, a mac moved to another finding or branch, a forged mac.
#   4. a non-lowering amend (verdict agreed, severity crit, reason) is kept.
#   5. no GO key: nothing to verify against, every row is honoured.
#   6. ledger-append.sh writes amends the reader verifies.
#
# Platform guard (gitbash-only): POSIX bash 3.2+.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
AUTH="$HERE/ledger-amend-auth.js"
LA="$HERE/ledger-append.sh"

tmp="$(mktemp -d "${TMPDIR:-/tmp}/amend-auth-test.XXXXXX")" || { echo "FAIL: mktemp -d failed" >&2; exit 1; }
trap 'rm -rf "$tmp"' EXIT
export HOME="$tmp/home"; mkdir -p "$HOME/.config/himmel"
KEYF="$HOME/.config/himmel/go-hmac.key"
printf '%s\n' 0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef > "$KEYF"

fails=0
check() { if [ "$2" = "$3" ]; then echo "ok - $1"; else echo "FAIL - $1: [$2]!=[$3]"; fails=$((fails+1)); fi; }

# kept <ledger> - the finding_id:reason of every amend row the filter keeps.
kept() {
  AUTH="$AUTH" LEDGER="$1" node -e '
const fs = require("fs"), e = process.env;
const lines = fs.readFileSync(e.LEDGER, "utf8").split("\n").filter(Boolean);
const out = [];
for (const l of require(e.AUTH).filterLines(lines)) {
  const o = JSON.parse(l);
  if (o.kind === "amend") out.push(o.finding_id + ":" + o.reason);
}
process.stdout.write(out.join(" "));
'
}
# signed <json> - the row signed as ledger-append.sh signs it.
signed() { AUTH="$AUTH" ROW="$1" node -e 'process.stdout.write(JSON.stringify(require(process.env.AUTH).sign(JSON.parse(process.env.ROW))))'; }
amend() { printf '{"kind":"amend","branch":"%s","target_head":"aaaaaaa","finding_id":"%s","artifact":"diff","perspective":"off","set":%s,"reason":"%s"}' "$1" "$2" "$3" "$4"; }

L="$tmp/ledger.jsonl"
# --- 1. no signed row: every amend counts ---------------------------------
{ amend b f1 '{"verdict":"disproved"}' old1; echo; amend b f2 '{"severity":"sug"}' old2; echo; } > "$L"
check "1: no signed row honours every amend" "$(kept "$L")" "f1:old1 f2:old2"

# --- 2. the first signed row is the cutover -------------------------------
{ signed "$(amend b f3 '{"reason":"x"}' cut)"; echo
  amend b f4 '{"verdict":"disproved"}' late-v; echo
  amend b f5 '{"severity":"imp"}' late-s; echo
  amend b f6 '{"deferred_to":"HIMMEL-1"}' late-d; echo
  amend b f7 '{"head":"bbbbbbb"}' late-h; echo
  amend b f8 '{"verdict":" Fixed "}' late-f; echo
  signed "$(amend b f9 '{"verdict":"disproved"}' good)"; echo; } >> "$L"
check "2: rows above the cutover stay, unsigned lowering below it drop" "$(kept "$L")" "f1:old1 f2:old2 f3:cut f9:good"

# --- 3. a mac only vouches for its own row --------------------------------
good="$(signed "$(amend b f9 '{"verdict":"disproved"}' good)")"
{ printf '%s\n' "${good/\"disproved\"/\"fixed\"}"
  printf '%s\n' "${good/\"f9\"/\"f10\"}"
  printf '%s\n' "${good/\"branch\":\"b\"/\"branch\":\"c\"}"
  amend b f11 '{"verdict":"disproved"}' forged | sed 's/}$/,"src":"ledger-append","amend_mac":"00"}/'; echo; } >> "$L"
check "3: a tampered, moved or forged mac is dropped" "$(kept "$L")" "f1:old1 f2:old2 f3:cut f9:good"

# --- 4. an amend that cannot lower a finding needs no mac -----------------
{ amend b f12 '{"verdict":"agreed"}' agree; echo; amend b f13 '{"severity":"crit"}' raise; echo
  amend b f14 '{"reason":"note"}' note; echo; } >> "$L"
check "4: non-lowering amends are kept unsigned" "$(kept "$L")" "f1:old1 f2:old2 f3:cut f9:good f12:agree f13:raise f14:note"

# --- 5. no GO key: every row is honoured ----------------------------------
mv "$KEYF" "$KEYF.off"
check "5: no key honours every amend" "$(kept "$L" | wc -w | tr -d ' ')" "$(grep -c '"kind":"amend"' "$L")"
mv "$KEYF.off" "$KEYF"

# --- 6. ledger-append.sh signs what it writes -----------------------------
REPO="$tmp/repo"; git init -q "$REPO"
LA_LEDGER="$tmp/la.jsonl"
(cd "$REPO" && CR_LEDGER="$LA_LEDGER" bash "$LA" finding --branch b --head 1111111111111111111111111111111111111111 --model codex --id la-1 \
  --severity imp --file a.sh --line 1 --verdict agreed --text "a finding" >/dev/null 2>&1) || echo "FAIL: fixture finding not written"
{ signed "$(amend b first '{"reason":"x"}' first)"; echo; } >> "$LA_LEDGER"
(cd "$REPO" && CR_LEDGER="$LA_LEDGER" bash "$LA" amend --branch b --head 1111111111111111111111111111111111111111 --id la-1 --set verdict=disproved \
  --reason "signed by the writer" >/dev/null 2>&1) || echo "FAIL: fixture amend not written"
check "6: a ledger-append.sh amend verifies" "$(kept "$LA_LEDGER")" "first:first la-1:signed by the writer"

echo "---"
if [ "$fails" -eq 0 ]; then
  echo "PASS - test-ledger-amend-auth.sh"
  exit 0
else
  echo "FAIL - test-ledger-amend-auth.sh ($fails failure(s))"
  exit 1
fi
