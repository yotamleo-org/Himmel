#!/usr/bin/env bash
# scripts/lib/test-outside-contributors.sh — suite for scripts/lib/outside-contributors.sh
# (T1.56): the allowlist reader and the security-audit row verifier.
# Fixture: a temp anchor holding a copy of the lib and a fixture perspective, a
# temp HOME and a synthetic git repo whose common dir holds the ledger.
# Platform guard: bash 3.2+, jq, git.
# shellcheck disable=SC2030,SC2031  # HOME is set per subshell on purpose
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

# outside_pr_authorize: the gh stub serves the author, the head branch and the head.
# The lib reads them itself; the caller names only the PR, the head and the rounds used.
mkdir -p "$W/bin"
cp "$HERE/timeout-bin.sh" "$ANCHOR/scripts/lib/" 2>/dev/null
cat > "$W/bin/gh" <<'STUB'
#!/usr/bin/env bash
[ "${STUB_MODE:-}" = sleep ] && sleep 30   # then answers like a healthy forge: only the bound refuses it
case "${STUB_MODE:-ok}" in
  fail) exit 1 ;;
  junk) echo 'not json at all' ;;
  noid) printf '{"author":{"login":"%s"},"headRefName":"%s","headRefOid":"%s"}\n' "$STUB_LOGIN" "$STUB_BRANCH" "$STUB_OID" ;;
  *) printf '{"author":{"login":"%s","id":"%s"},"headRefName":"%s","headRefOid":"%s"}\n' "$STUB_LOGIN" "$STUB_ID" "$STUB_BRANCH" "$STUB_OID" ;;
esac
STUB
chmod +x "$W/bin/gh"
# A timeout shim that scales the 20 s bound down to 1 s, so the sleep row does not take 20 s.
REAL_TIMEOUT=$(command -v timeout || command -v gtimeout)
mkdir -p "$W/fast"
cat > "$W/fast/timeout" <<STUB
#!/usr/bin/env bash
[ "\${1:-}" = "--version" ] && exec "$REAL_TIMEOUT" --version
exec "$REAL_TIMEOUT" -k 1 1 "\${@:4}"
STUB
chmod +x "$W/fast/timeout"
APPR="$W/home/.himmel/outside-pr-approvals.jsonl"
SL=Goomal SI="$ID" SB="$B" SO="$H" SM=ok
# authz <pr> <head> <used>: prints "rc:stdout"
authz() {
  local out rc
  out=$(cd "$REPO" && HOME="$W/home" PATH="${AZPATH:-$W/bin}:$PATH" STUB_MODE="$SM" STUB_LOGIN="$SL" STUB_ID="$SI" STUB_BRANCH="$SB" STUB_OID="$SO" \
    bash -c '. "$1/scripts/lib/outside-contributors.sh" && shift && outside_pr_authorize "$@"' _ "$ANCHOR" "$@" 2>/dev/null); rc=$?
  printf '%s:%s' "$rc" "$out"
}
approve() { # pr head stage message_id
  jq -nc --argjson pr "$1" --arg h "$2" --arg s "$3" --argjson m "${4:-41}" \
    '{pr:$pr,head:$h,stage:$s,from:1,chat:1,message_id:$m,ts:"2026-11-06T10:00:00Z"} | if $s == "" then del(.stage) else . end' >> "$APPR"
}
list() { printf '[{"login":"Goomal","id":"%s"}]\n' "$ID" > "$LIST"; }
fresh; rm -f "$APPR"; list
check 'authz: a listed login and id, under the cap' "$(authz 7 "$H" 0)" '0:allowlist'
check 'authz: a head that differs from the forge head' "$(authz 7 "$P" 0)" '1:'
check 'authz: a short head argument' "$(authz 7 1111 0)" '1:'
check 'authz: a non-numeric PR' "$(authz 7x "$H" 0)" '1:'
check 'authz: a non-numeric rounds count' "$(authz 7 "$H" x)" '1:'
check 'authz: three rounds used, listed, no approval' "$(authz 7 "$H" 3)" '1:'
printf '[{"login":"Goomal"}]\n' > "$LIST"
check 'authz: a login-only list entry' "$(authz 7 "$H" 0)" '1:'
printf '[{"id":"%s"}]\n' "$ID" > "$LIST"
check 'authz: an id-only list entry' "$(authz 7 "$H" 0)" '1:'
rm -f "$LIST"
check 'authz: a missing list' "$(authz 7 "$H" 0)" '1:'
printf '[{"login":"Goomal",' > "$LIST"
check 'authz: a malformed list' "$(authz 7 "$H" 0)" '1:'
: > "$LIST"
check 'authz: an empty list' "$(authz 7 "$H" 0)" '1:'
list
approve 7 "$H" review 41
check 'authz: three rounds used, an exact review approval, listed author, no audit' "$(authz 7 "$H" 3)" '0:approval:41'
rm -f "$APPR"; approve 7 "${H:0:7}" review 42
check 'authz: an approval with a 7-hex head' "$(authz 7 "$H" 3)" '1:'
rm -f "$APPR"; approve 7 "$P" review 43
check 'authz: an approval for another head' "$(authz 7 "$H" 3)" '1:'
rm -f "$APPR"; approve 8 "$H" review 44
check 'authz: an approval for another PR' "$(authz 7 "$H" 3)" '1:'
rm -f "$APPR"; printf '{"pr":"7","head":"%s","stage":"review","message_id":1}\nnot json\n' "$H" > "$APPR"
check 'authz: a string pr and a junk line never approve' "$(authz 7 "$H" 3)" '1:'
rm -f "$APPR"; printf '{"pr":7,"head":"%s","stage":"review"}\n' "$H" > "$APPR"
check 'authz: an approval row with no message_id never approves' "$(authz 7 "$H" 3)" '1:'
rm -f "$APPR"; approve 7 "$H" ci 45
check 'authz: T2.46 an approval with stage ci' "$(authz 7 "$H" 3)" '1:'
rm -f "$APPR"; approve 7 "$H" "" 46
check 'authz: T2.46 an approval with no stage' "$(authz 7 "$H" 3)" '1:'
# unlisted author: needs a review approval AND an audit pass at the head
SL=Stranger SI=U_stranger
rm -f "$APPR"; fresh
check 'authz: unlisted, nothing recorded' "$(authz 7 "$H" 0)" '1:'
approve 7 "$H" review 47
check 'authz: T2.44 unlisted, review approval, no audit row' "$(authz 7 "$H" 0)" '1:'
rm -f "$APPR"; row pass "$H" "$B" 7
check 'authz: T2.45 unlisted, audit pass, no approval' "$(authz 7 "$H" 0)" '1:'
approve 7 "$H" ci 48
check 'authz: T2.46 unlisted, audit pass, stage ci approval' "$(authz 7 "$H" 0)" '1:'
rm -f "$APPR"; approve 7 "$H" "" 49
check 'authz: T2.46 unlisted, audit pass, approval with no stage' "$(authz 7 "$H" 0)" '1:'
rm -f "$APPR"; approve 7 "$H" review 50
check 'authz: T2.47 unlisted, review approval and audit pass' "$(authz 7 "$H" 0)" '0:approval:50'
fresh
check 'authz: unlisted, review approval, audit rows gone' "$(authz 7 "$H" 0)" '1:'
# the caller cannot name the author (I7): the environment says listed, the forge says unlisted
rm -f "$APPR"; list
check 'authz: T2.51 caller environment names a listed author, the forge serves another' \
  "$(OUTSIDE_PR_AUTHOR=Goomal OUTSIDE_PR_AUTHOR_ID="$ID" GH_CMD=true authz 7 "$H" 0)" '1:'
# forge failures refuse (mutation check: drop the timeout and the sleep row goes RED)
SL=Goomal SI="$ID"
check 'authz: T2.52 the forge answers' "$(authz 7 "$H" 0)" '0:allowlist'
SM='sleep'; AZPATH="$W/fast:$W/bin"
check 'authz: T2.52 the forge call outlives the bound' "$(authz 7 "$H" 0)" '1:'
unset AZPATH
SM=fail; check 'authz: T2.52 gh exits non-zero' "$(authz 7 "$H" 0)" '1:'
SM=junk; check 'authz: T2.52 gh prints junk' "$(authz 7 "$H" 0)" '1:'
SM=noid; check 'authz: T2.52 the answer omits the author id' "$(authz 7 "$H" 0)" '1:'
SM=ok

# outside_pr_merge_base <pr> <baseRefName>: fetch the base, print its merge base with the PR ref
ORIGIN="$W/origin.git"; MB="$W/mb"
git init -q --bare -b main "$ORIGIN"
git init -q -b main "$MB"
mbgit() { git -C "$MB" -c user.email=t@t.test -c user.name=t -c commit.gpgsign=false "$@"; }
printf 'a\n' > "$MB/f"; mbgit add f; mbgit commit -q -m c0
BASE0=$(mbgit rev-parse HEAD)
mbgit remote add origin "$ORIGIN"; mbgit push -q origin main
printf 'p\n' >> "$MB/f"; mbgit commit -q -am p1
mbgit update-ref refs/himmel/outside/7 HEAD
mbgit reset -q --hard "$BASE0"
printf 'b\n' >> "$MB/f"; mbgit commit -q -am c1; mbgit push -q origin main
mbgit update-ref -d refs/remotes/origin/main
mbase() { local o r; o=$(cd "$MB" && . "$ANCHOR/scripts/lib/outside-contributors.sh" && outside_pr_merge_base "$@" 2>/dev/null); r=$?; printf '%s:%s' "$o" "$r"; }
check 'merge-base: prints the fixture merge base after fetching the base' "$(mbase 7 main)" "$BASE0:0"
check 'merge-base: a missing base ref prints nothing and returns 1' "$(mbase 7 nope)" ':1'
check 'merge-base: a missing PR ref prints nothing and returns 1' "$(mbase 9 main)" ':1'
check 'merge-base: a junk base name' "$(mbase 7 '../x')" ':1'
[ "$fails" -eq 0 ] || { printf '%s FAILED\n' "$fails"; exit 1; }
printf 'ALL PASS\n'
