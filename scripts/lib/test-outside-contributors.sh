#!/usr/bin/env bash
# scripts/lib/test-outside-contributors.sh — suite for scripts/lib/outside-contributors.sh
# (T1.56): the allowlist reader and the security-audit row verifier.
# Fixture: a temp anchor holding a copy of the lib and a fixture perspective, a
# temp HOME and a synthetic git repo whose common dir holds the ledger.
# Platform guard: bash 3.2+, jq, git.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
W=$(mktemp -d "${TMPDIR:-/tmp}/outside-contributors-test.XXXXXX") || exit 1
trap 'rm -rf "$W"' EXIT
fails=0
check() { if [ "$2" = "$3" ]; then printf 'ok - %s\n' "$1"; else printf 'FAIL - %s: [%s] != [%s]\n' "$1" "$2" "$3"; fails=$((fails+1)); fi; }
sha() { if command -v sha256sum >/dev/null 2>&1; then sha256sum < "$1"; else shasum -a 256 < "$1"; fi | cut -d' ' -f1; } # read-sink-ok: hashes only the suite's own fixture files under $W

ANCHOR="$W/anchor"; mkdir -p "$ANCHOR/scripts/lib" "$ANCHOR/scripts/cr/perspectives" "$W/home/.himmel"
cp "$HERE/outside-contributors.sh" "$ANCHOR/scripts/lib/" 2>/dev/null
PERSP="$ANCHOR/scripts/cr/perspectives/outside-security.md"
printf '# fixture outside-security perspective\n' > "$PERSP"
PSHA=$(sha "$PERSP")
REPO="$W/repo"; git init -q "$REPO"
GCD=$(git -C "$REPO" rev-parse --path-format=absolute --git-common-dir)
LEDGER="$GCD/cr-critic-scores.jsonl"
mkdir -p "$GCD/outside-audits"
LIST="$W/home/.himmel/outside-contributors.json"
H=1111111111111111111111111111111111111111; P=2222222222222222222222222222222222222222
B=feat/himmel-1-thing; ID=U_kgDOBieNbw

allowed() { (cd "$REPO" && HOME="$W/home" && . "$ANCHOR/scripts/lib/outside-contributors.sh" && outside_contributor_allowed "$@") >/dev/null 2>&1; echo $?; }
passed() { (cd "$REPO" && HOME="$W/home" && . "$ANCHOR/scripts/lib/outside-contributors.sh" && outside_audit_passed "$@") >/dev/null 2>&1; echo $?; }
# row <verdict> [head] [branch] [pr] [perspective sha] [report file]
row() {
  local v="$1" h="${2:-$H}" b="${3:-$B}" pr="${4:-7}" ps="${5:-$PSHA}" rpt="${6:-}"
  if [ -z "$rpt" ]; then
    rpt="$GCD/outside-audits/$pr-$h-20261104T10$(printf '%04d' $((RANDOM % 10000)))Z.md"
    printf 'audit report %s %s\n' "$v" "$RANDOM" > "$rpt"
  fi
  jq -nc --arg v "$v" --arg h "$h" --arg b "$b" --argjson pr "$pr" --arg ps "$ps" --arg r "$rpt" --arg rs "$( [ -f "$rpt" ] && sha "$rpt" || echo 0)" \
    '{kind:"security-audit",ts:"2026-11-04T10:00:00Z",pr:$pr,branch:$b,head:$h,base_sha:("3"*40),verdict:$v,hard:[],critical_n:0,important_n:0,dropped_n:0,critic_exit:0,model:"gpt-5-codex",auditor:"codex",perspective_sha256:$ps,report:$r,report_sha256:$rs,status:"ok"}' >> "$LEDGER"
  LAST_REPORT="$rpt"
}
fresh() { : > "$LEDGER"; rm -f "$GCD"/outside-audits/*; }

# outside_contributor_allowed: both login and id must match one entry
printf '[{"login":"Goomal","id":"%s","note":"other keys ignored"}]\n' "$ID" > "$LIST"
check 'allowed: a listed login and id' "$(allowed Goomal "$ID")" 0
check 'allowed: other keys are ignored' "$(allowed Goomal "$ID")" 0
check 'allowed: login matches but id differs' "$(allowed Goomal U_other)" 1
check 'allowed: id matches but login differs' "$(allowed other "$ID")" 1
check 'allowed: an empty id' "$(allowed Goomal '')" 1
printf '[{"login":"Goomal"}]\n' > "$LIST"
check 'allowed: a login-only entry lists no one' "$(allowed Goomal "$ID")" 1
printf '[{"id":"%s"}]\n' "$ID" > "$LIST"
check 'allowed: an id-only entry lists no one' "$(allowed Goomal "$ID")" 1
rm -f "$LIST"
check 'allowed: a missing list' "$(allowed Goomal "$ID")" 1
printf '[{"login":"Goomal",' > "$LIST"
check 'allowed: a malformed list' "$(allowed Goomal "$ID")" 1
: > "$LIST"
check 'allowed: an empty list file' "$(allowed Goomal "$ID")" 1
printf '{"login":"Goomal","id":"%s"}\n' "$ID" > "$LIST"
check 'allowed: an object, not an array' "$(allowed Goomal "$ID")" 1

# outside_audit_passed
fresh; row pass
check 'audit: a pass row at the head' "$(passed 7 "$H" "$B")" 0
fresh; row flagged
check 'audit: a flagged row at the head' "$(passed 7 "$H" "$B")" 0
fresh; row fail
check 'audit: a fail row' "$(passed 7 "$H" "$B")" 1
fresh; row fail; row pass
check 'audit: a pass row after a fail row at the same head' "$(passed 7 "$H" "$B")" 1
fresh; row fail "$H" other-branch; row pass
check 'audit: a fail row on another branch at the same head still blocks' "$(passed 7 "$H" "$B")" 1
fresh; row pass "$P"
check 'audit: a pass row at the parent head' "$(passed 7 "$H" "$B")" 1
fresh; row pass "$H" "$B" 8
check 'audit: a pass row for another PR' "$(passed 7 "$H" "$B")" 1
fresh; row pass "$H" other-branch
check 'audit: a pass row on another branch' "$(passed 7 "$H" "$B")" 1
fresh; row pass "$H" "$B" 7 "$(printf '9%.0s' $(seq 64))"
check 'audit: a pass row under a stale perspective sha' "$(passed 7 "$H" "$B")" 1
fresh; row pass; mv "$PERSP" "$PERSP.gone"
check 'audit: a missing perspective file' "$(passed 7 "$H" "$B")" 1
mv "$PERSP.gone" "$PERSP"
fresh; row pass; rm -f "$LAST_REPORT"
check 'audit: a missing report file' "$(passed 7 "$H" "$B")" 1
fresh; row pass; printf 'edited\n' >> "$LAST_REPORT"
check 'audit: an edited report file' "$(passed 7 "$H" "$B")" 1
fresh; row pass; chmod 000 "$LEDGER"
if [ -r "$LEDGER" ]; then r=1; else r=$(passed 7 "$H" "$B"); fi  # root reads a 000 file
chmod 644 "$LEDGER"
check 'audit: an unreadable ledger' "$r" 1
fresh; row pass; printf 'not json\n' >> "$LEDGER"
check 'audit: a malformed ledger line is skipped, the pass row still counts' "$(passed 7 "$H" "$B")" 0
fresh; printf 'not json\n' >> "$LEDGER"; row fail; row pass
check 'audit: a malformed line does not hide a fail row' "$(passed 7 "$H" "$B")" 1
fresh; rm -f "$LEDGER"
check 'audit: no ledger at all' "$(passed 7 "$H" "$B")" 1
fresh; row pass
check 'audit: a short head argument' "$(passed 7 1111 "$B")" 1
[ "$fails" -eq 0 ] || { printf '%s FAILED\n' "$fails"; exit 1; }
printf 'ALL PASS\n'
