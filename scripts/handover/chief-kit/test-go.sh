#!/usr/bin/env bash
# shellcheck disable=SC2015  # A && B || C is intentional in check()/contains(), as in test-headed-arm-worker.sh
# scripts/handover/chief-kit/test-go.sh - suite for go.sh, the
# chief's GO-evidence writer that merge-on-green.sh's chief-GO gate reads.
# test-merge-on-green.sh drives the reader end to end with GO files written by
# THIS script; this suite pins the writer's own contract:
#   1. usage: arg count, non-digit / leading-zero PR, sha not 40 lowercase hex -> exit 2.
#   2. write: path printed, file fields pr= / head= / by= / at= (ISO-8601 UTC).
#   3. by= falls back to <user>@<host> without CHIEF_SESSION_NAME.
#   4. idempotent: a re-run overwrites in place, no temp file left behind.
#   5. HIMMEL_CONSOLE_LEG set -> exit 3, nothing written (a worker never writes its own GO;
#      this covers a --judge worker too - same marker, no separate one).
#   6. HIMMEL_CONSOLE_RELAY set -> exit 3, and its message names the chief, never
#      a judge, as the writer.
#   7. unresolvable handover root -> exit 1.
#   13. --trust-reviewed <id>: id validated, signed into the mac.
#   20. --fix-main-red <run-id>: the signed fix-GO for the red-main gate.
#
# Platform guard: POSIX bash 3.2+.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/go.sh"
unset HIMMEL_CONSOLE_LEG CHIEF_SESSION_NAME 2>/dev/null || true

tmp="$(mktemp -d "${TMPDIR:-/tmp}/go-test.XXXXXX")" || { echo "FAIL: mktemp -d failed" >&2; exit 1; }
trap 'rm -rf "$tmp"' EXIT
tmp="$(cd "$tmp" && pwd)"
# Sections 14-15 run after section 13 sources go-gate.sh, which assigns its
# own `tmp`; name their dirs here so nothing below reads `$tmp` past that point.
ROOT14="$tmp/root14"; ROOT15="$tmp/root15"; ROOT16="$tmp/root16"; ROOT18="$tmp/root18"
NOWHERE32="$tmp/nowhere32"; DECOY32="$tmp/decoy32"; ROOT32="$tmp/root32"
# go.sh mints its GO key under $HOME/.config/himmel — keep it off
# the operator's real key.
export HOME="$tmp/home"; mkdir -p "$HOME"

# go.sh now resolves this repo's nwo via `gh repo view` to bind
# the GO mac. A gh stub on PATH keeps every call below hermetic (no real
# gh/network dependency); STUB_NWO controls what it returns.
mkdir -p "$tmp/bin"
cat > "$tmp/bin/gh" <<'STUB'
#!/usr/bin/env bash
case "$1 $2" in
    "repo view")
        json=""
        while [ $# -gt 0 ]; do
            case "$1" in --json) json="$2" ;; esac
            shift
        done
        case "$json" in
            nameWithOwner)
                [ "${STUB_GH_RL:-0}" = "1" ] && { echo "GraphQL: API rate limit already exceeded for user ID 1." >&2; exit 1; }
                [ "${STUB_GH_REPO_VIEW_FAIL:-0}" = "1" ] && exit 1
                printf '%s' "${STUB_NWO:-o/r}" ;;
            *) exit 90 ;;
        esac ;;
    *) exit 91 ;;
esac
STUB
chmod +x "$tmp/bin/gh"
export PATH="$tmp/bin:$PATH"
export STUB_NWO="o/r"

# go.sh runs ready-check.sh itself, so every write below runs from
# a repo whose CR ledger has an ok row for the head, with a gh that answers
# ready-check's queries green (testlib-ready-pass.sh). Section 14 breaks each.
# shellcheck source=scripts/handover/chief-kit/testlib-ready-pass.sh
# shellcheck disable=SC1091
. "$HERE/testlib-ready-pass.sh"
ready_pass_bin "$tmp/ready-bin"
export PATH="$tmp/ready-bin:$PATH"
READY_REPO="$tmp/ready-repo"
git init -q "$READY_REPO"
# go.sh gates HIMMEL_REPO (else its own checkout), never the cwd: the fixture is the gated repo.
export HIMMEL_REPO="$READY_REPO"
cd "$READY_REPO" || { echo "FAIL: cd $READY_REPO" >&2; exit 1; }

fails=0
grepq() { local _t="$1"; shift; grep -q "$@" <<< "$_t"; }
check()    { [ "$2" = "$3" ] && echo "ok - $1" || { echo "FAIL - $1: [$2]!=[$3]"; fails=$((fails+1)); }; }
contains() { grepq "$2" -F -e "$3" && echo "ok - $1" || { echo "FAIL - $1: output does not contain [$3]"; fails=$((fails+1)); }; }

# verdict <root> <qid> <verdict line> [<file name>] - a judge's verdict file,
# as docs/handover/verdict-template.md lays it out.
verdict() {
  local vf="$1/$VSCOPE/verdicts/$2/${4:-HIMMEL-1-judge-$2}.md" vmac
  mkdir -p "$1/$VSCOPE/verdicts/$2"
  printf '# VERDICT %s - judge\n\n%s## Reason (scope asked)\n\nq\n\n## Verdict\n\n%s\n\npr: %s\n\nreason\n\n## Evidence checked\n\ne\n%s' \
    "$2" "${VWRITTEN:+written-at: $VWRITTEN$'\n\n'}" "$3" "${VPR:-83}" "${VEXTRA:-}" > "$vf"
  # a record counts only with write-verdict.sh's mac (VSIGN=0 models a hand-written one).
  [ "${VSIGN:-1}" = 1 ] || return 0
  vsign "$2" "$vf"
}
# vsign <qid> <file> - append write-verdict.sh's mac line to a hand-built record.
vsign() {
  local vmac
  mkdir -p "$HOME/.config/himmel"
  [ -s "$HOME/.config/himmel/go-hmac.key" ] || printf '%s\n' 0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef > "$HOME/.config/himmel/go-hmac.key"
  vmac="$(cat "$2" | bash -c '. "$1"; go_verdict_mac "$2" "$3" "$4"' _ "$HERE/../../lib/go-gate.sh" "$VSCOPE" "$1" "$(basename "$2" .md)")" || { echo "FAIL: cannot sign $2" >&2; return 1; }
  printf 'mac: %s\n' "$vmac" >> "$2"
}

# a trust verdict counts only under <user>/<bucket>, the user slug
# and the primary checkout's slugified basename (never a hardcoded bucket).
export USER_SLUG=u
VBUCKET="$(basename "$(dirname "$(git -C "$HERE" rev-parse --path-format=absolute --git-common-dir)")" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//')"
VSCOPE="u/$VBUCKET"

SHA=$(ready_pass_repo "$READY_REPO") || { echo "FAIL: ready_pass_repo" >&2; exit 1; }
export READY_STUB_HEAD="$SHA"
ready_pass_ledger "$READY_REPO" "$SHA"
ROOT="$tmp/root"; mkdir -p "$ROOT"
GO="$ROOT/.locks/go/77.$SHA"

# --- 1. usage --------------------------------------------------------------
for args in "" "77" "77 $SHA extra" "x1 $SHA" "077 $SHA" "77 ${SHA%?}" "77 ${SHA}0" \
            "77 0123456789ABCDEF0123456789abcdef01234567" "77 g123456789abcdef0123456789abcdef01234567"; do
  rc=0
  # shellcheck disable=SC2086  # word-splitting the args string IS the point
  HANDOVER_DIR="$ROOT" bash "$SCRIPT" $args >/dev/null 2>&1 || rc=$?
  check "usage: [$args] -> exit 2" "$rc" "2"
done
check "usage: nothing written" "$(ls -A "$ROOT")" ""

# --- 2. write ----------------------------------------------------------------
rc=0; out="$(HANDOVER_DIR="$ROOT" CHIEF_SESSION_NAME=chief-x bash "$SCRIPT" 77 "$SHA" 2>&1)" || rc=$?
check "write: exit 0" "$rc" "0"
check "write: prints the GO path" "$out" "$GO"
body="$(cat "$GO" 2>/dev/null || true)"
contains "write: pr= field" "$body" "pr=77"
contains "write: head= field" "$body" "head=$SHA"
contains "write: by= is the chief session name" "$body" "by=chief-x"
grepq "$body" -Ex 'at=[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z' \
  && echo "ok - write: at= is ISO-8601 UTC" || { echo "FAIL - write: at= not ISO-8601 UTC: [$body]"; fails=$((fails+1)); }

# --- 2a. CHIEF_SESSION_NAME is the by= name; the retired console session-name variable is ignored
ROOT2A="$tmp/root2a"; mkdir -p "$ROOT2A"
rc=0; HANDOVER_DIR="$ROOT2A" CHIEF_SESSION_NAME=chief-x CONSOLE_SESSION_NAME=console-y bash "$SCRIPT" 77 "$SHA" >/dev/null 2>&1 || rc=$? # old-term-ok
check "write: CHIEF_SESSION_NAME set -> exit 0" "$rc" "0"
contains "write: by= is CHIEF_SESSION_NAME beside the retired name" "$(cat "$ROOT2A/.locks/go/77.$SHA" 2>/dev/null)" "by=chief-x"
ROOT2A2="$tmp/root2a2"; mkdir -p "$ROOT2A2"
rc=0; HANDOVER_DIR="$ROOT2A2" CONSOLE_SESSION_NAME=console-y bash "$SCRIPT" 77 "$SHA" >/dev/null 2>&1 || rc=$? # old-term-ok
check "write: the retired CONSOLE_SESSION_NAME alone -> exit 0" "$rc" "0" # old-term-ok
check "write: the retired CONSOLE_SESSION_NAME is not the by= name" "$(grep -c 'console-y' "$ROOT2A2/.locks/go/77.$SHA" 2>/dev/null)" "0" # old-term-ok

# --- 2b. the read token is optional ------------------------------
# go.sh reads through gh-read.sh; with no read token anywhere (an empty .env root)
# the reads fall back to the main token and a GO is still written, never refused.
mkdir -p "$tmp/no-read-token"; : > "$tmp/no-read-token/.env"
ROOT2B="$tmp/root2b"; mkdir -p "$ROOT2B"
rc=0; out="$(GH_READ_ENV_ROOT="$tmp/no-read-token" HANDOVER_DIR="$ROOT2B" CHIEF_SESSION_NAME=chief-x bash "$SCRIPT" 77 "$SHA" 2>&1)" || rc=$?
check "6837: read token unset -> go.sh still exits 0" "$rc" "0"
check "6837: read token unset -> the GO is written" "$(test -f "$ROOT2B/.locks/go/77.$SHA" && echo yes)" "yes"

# --- 3. by= fallback ---------------------------------------------------------
rc=0; HANDOVER_DIR="$ROOT" bash "$SCRIPT" 78 "$SHA" >/dev/null 2>&1 || rc=$?
check "fallback: exit 0" "$rc" "0"
grepq "$(cat "$ROOT/.locks/go/78.$SHA" 2>/dev/null)" -Ex 'by=[^@]+@.+' \
  && echo "ok - fallback: by=<user>@<host>" || { echo "FAIL - fallback: by= not <user>@<host>"; fails=$((fails+1)); }

# --- 4. idempotent rewrite ---------------------------------------------------
rc=0; HANDOVER_DIR="$ROOT" CHIEF_SESSION_NAME=chief-y bash "$SCRIPT" 77 "$SHA" >/dev/null 2>&1 || rc=$?
check "rewrite: exit 0" "$rc" "0"
contains "rewrite: overwritten in place" "$(cat "$GO" 2>/dev/null)" "by=chief-y"
check "rewrite: one head= line, not appended" "$(grep -c '^head=' "$GO" 2>/dev/null)" "1"
leftover=0
for f in "$ROOT/.locks/go"/.go.*; do [ -e "$f" ] && leftover=$((leftover+1)); done
check "rewrite: no temp file left behind" "$leftover" "0"

# --- 5. a chief-spawned worker cannot write its own GO ------------------------
LEGROOT="$tmp/legroot"; mkdir -p "$LEGROOT"
# HIMMEL_CONSOLE_LEG is a Claude Code marker (any value): from an anchor checkout
# with no claude ancestor (CI) and HANDOVER_DIR set, go.sh refuses 96
# A worker always runs under its claude session, so these rows
# run under a fake one.
_as_claude() { (exec -a claude bash -c '"$@"; exit $?' _ "$@"); }
rc=0; out="$(HANDOVER_DIR="$LEGROOT" HIMMEL_CONSOLE_LEG=1 _as_claude bash "$SCRIPT" 77 "$SHA" 2>&1)" || rc=$?
check "worker marker: exit 3" "$rc" "3"
contains "worker marker: names the reason" "$out" "chief-spawned worker"
check "worker marker: nothing written" "$(ls -A "$LEGROOT")" ""
# a worker must not mint (or even create) the GO key either.
LEGHOME="$tmp/leghome"; mkdir -p "$LEGHOME"
rc=0; HOME="$LEGHOME" HANDOVER_DIR="$LEGROOT" HIMMEL_CONSOLE_LEG=1 _as_claude bash "$SCRIPT" 77 "$SHA" >/dev/null 2>&1 || rc=$?
check "worker marker: exit 3 with a fresh HOME" "$rc" "3"
check "worker marker: no GO key minted" "$(find "$LEGHOME" -type f | wc -l | tr -d ' ')" "0"
rc=0; HANDOVER_DIR="$LEGROOT" HIMMEL_CONSOLE_LEG=0 _as_claude bash "$SCRIPT" 77 "$SHA" >/dev/null 2>&1 || rc=$?
check "worker marker: a falsy marker is no marker" "$rc" "0"

# --- 6. HIMMEL_CONSOLE_RELAY refuses on its own, nothing written.
ROOT6="$(mktemp -d)" || { echo "FAIL: mktemp -d failed" >&2; exit 1; }
rc=0; out="$(env -u HIMMEL_CONSOLE_LEG HANDOVER_DIR="$ROOT6" HIMMEL_CONSOLE_RELAY=1 bash "$SCRIPT" 77 "$SHA" 2>&1)" || rc=$?
check    "relay: exit 3" "$rc" "3"
contains "relay: names the relay" "$out" "chief relay"
check    "relay: no GO file written" "$(find "$ROOT6" -type f | wc -l | tr -d ' ')" "0"
rm -rf "$ROOT6"

# --- 7. "the judge is a worker" - go.sh's own gate is the worker
# marker (HIMMEL_CONSOLE_JUDGE, only feeds guard-judge-writes.sh),
# so nothing anywhere in go.sh's output should still claim
# "only the judge writes a GO" (stale pre-3133 wording: only the CHIEF does,
# whether the caller is a plain worker, a --judge worker, or a relay).
if grepq "$out" -F -e "the judge writes"; then
  echo "FAIL - relay refusal still claims a judge writes the GO (pre-3133 wording)"
  fails=$((fails+1))
else
  echo "ok - relay refusal does not claim a judge writes the GO"
fi
contains "relay: correctly names the chief as the GO writer" "$out" "only the chief writes a GO"

# --- 8. unresolvable handover root -------------------------------------------
rc=0; HANDOVER_DIR="$tmp/absent" bash "$SCRIPT" 77 "$SHA" >/dev/null 2>&1 || rc=$?
check "no root: exit 1" "$rc" "1"

# --- 9. relative entry hands off to the $HIMMEL_REPO anchor -----
# The same mechanism scripts/cr/anchor-handoff.sh gives the scripts/cr/
# writers, generalized to reach this depth-3 entry too
# Fixture trees carry the REAL generalized anchor-handoff.sh
# and must be real git repos (its root resolution is `git rev-parse
# --show-toplevel`). A marker go.sh keeps everything up to and including the
# real hand-off sourcing line verbatim, then `echo "RAN:<label>"` — a passing
# case proves the ACTUAL shipped sourcing line triggers the hand-off, not a
# hand-rolled substitute (all cases above invoke go.sh by ABSOLUTE path, so
# none of them exercises the relative door — this is the first).
# shellcheck disable=SC2016  # the literal line go.sh carries, not an expansion
GO_ENTRY_SOURCE_LINE='. "$_ah_d/../../cr/anchor-handoff.sh" || exit 2'
mk_go_entry_tree() {  # <root> <label>
  mkdir -p "$1/scripts/handover/chief-kit" "$1/scripts/cr"
  git init -q "$1"
  cp "$HERE/../../cr/anchor-handoff.sh" "$1/scripts/cr/anchor-handoff.sh"
  awk -v src="$GO_ENTRY_SOURCE_LINE" '{ print } $0 == src { exit }' "$SCRIPT" > "$1/head.tmp"
  if ! grep -qxF "$GO_ENTRY_SOURCE_LINE" "$1/head.tmp"; then
    echo "FAIL - 3437 setup: go.sh no longer carries the expected hand-off sourcing line verbatim, control proves nothing" >&2
    fails=$((fails+1))
  fi
  printf '%s\necho "RAN:%s"\n' "$(cat "$1/head.tmp")" "$2" > "$1/scripts/handover/chief-kit/go.sh"
  rm -f "$1/head.tmp"
}
G3437_WT="$tmp/g3437-wt"; G3437_ANCHOR="$tmp/g3437-anchor"
mk_go_entry_tree "$G3437_WT" branch
mk_go_entry_tree "$G3437_ANCHOR" anchor

out=$(cd "$G3437_WT" && env -u CR_ANCHOR_HANDED_OFF HIMMEL_REPO="$G3437_ANCHOR" bash scripts/handover/chief-kit/go.sh 2>/dev/null)
check "3437: relative entry hands off" "$out" "RAN:anchor"

out=$(cd "$G3437_WT" && env -u CR_ANCHOR_HANDED_OFF HIMMEL_REPO="$G3437_ANCHOR" bash "$G3437_WT/scripts/handover/chief-kit/go.sh" 2>/dev/null)
check "3437: absolute entry runs local" "$out" "RAN:branch"

rc=0; (cd "$G3437_WT" && env -u CR_ANCHOR_HANDED_OFF -u HIMMEL_REPO bash scripts/handover/chief-kit/go.sh >/dev/null 2>&1) || rc=$?
check "3437: unset HIMMEL_REPO exits 2" "$rc" "2"

# --- 10. go.sh writes where merge-on-green reads ---------
# A chief whose env has no HANDOVER_DIR (or has the harness repo's own
# handovers/ stub) used to get rc=0 and a GO under <repo>/handovers, while the
# gate reads the root the repo's .env configures. Fixture: a git tree carrying
# go.sh + scripts/lib + anchor-handoff.sh, a handovers/ stub, and a .env
# naming a real root outside it. go.sh runs by ABSOLUTE path (no hand-off).
S10="$tmp/s10"; S10_REAL="$tmp/s10-real"
mkdir -p "$S10/scripts/handover/chief-kit" "$S10/scripts/cr" "$S10/scripts/ci" "$S10/handovers" "$S10_REAL"
git init -q "$S10"
cp "$SCRIPT" "$S10/scripts/handover/chief-kit/go.sh"
cp "$HERE/ready-check.sh" "$S10/scripts/handover/chief-kit/ready-check.sh"
cp "$HERE/cr-disposition.sh" "$S10/scripts/handover/chief-kit/cr-disposition.sh"
ready_pass_ledger "$S10" "$SHA"
cp -R "$HERE/../../lib" "$S10/scripts/lib"
cp "$HERE/../../ci/ticket-id-internal-authors.txt" "$S10/scripts/ci/ticket-id-internal-authors.txt"
cp "$HERE/../../cr/anchor-handoff.sh" "$S10/scripts/cr/anchor-handoff.sh"
# check 19: the copy reads READY_REPO's head through an alternate, from its own origin
cp "$HERE/../../cr/impacted-suites.sh" "$S10/scripts/cr/impacted-suites.sh"
printf '%s\n' "$READY_REPO/.git/objects" > "$S10/.git/objects/info/alternates"
ready_pass_origin "$S10" "$(git -C "$READY_REPO" rev-parse refs/remotes/origin/main)"
cp "$HERE/../../cr/ledger-amend-auth.js" "$S10/scripts/cr/ledger-amend-auth.js"
cp "$HERE/../../cr/clear-review-marker.sh" "$S10/scripts/cr/clear-review-marker.sh"
# item 18's marker check promotes through review-round.sh now that the head is a real commit
cp "$HERE/../../cr/review-round.sh" "$S10/scripts/cr/review-round.sh"
printf 'HANDOVER_DIR=%s\n' "$S10_REAL" > "$S10/.env"
S10_GO=".locks/go/77.$SHA"

# 10a. HANDOVER_DIR unset: the GO lands in the configured root, not the stub.
rc=0; out=$(cd "$S10" && env -u HANDOVER_DIR -u HIMMEL_REPO bash "$S10/scripts/handover/chief-kit/go.sh" 77 "$SHA" 2>&1) || rc=$?
check "3572: unset HANDOVER_DIR -> exit 0" "$rc" "0"
check "3572: unset HANDOVER_DIR -> nothing under the repo stub" "$(find "$S10/handovers" -type f | wc -l | tr -d ' ')" "0"
check "3572: unset HANDOVER_DIR -> GO in the .env-configured root" "$([ -f "$S10_REAL/$S10_GO" ] && echo yes)" "yes"
rm -f "$S10_REAL/$S10_GO"

# 10b. HANDOVER_DIR = the repo stub itself: same answer, the stub is skipped.
rc=0; (cd "$S10" && env -u HIMMEL_REPO HANDOVER_DIR="$S10/handovers" bash "$S10/scripts/handover/chief-kit/go.sh" 77 "$SHA" >/dev/null 2>&1) || rc=$?
check "3572: HANDOVER_DIR=stub -> exit 0" "$rc" "0"
check "3572: HANDOVER_DIR=stub -> nothing under the repo stub" "$(find "$S10/handovers" -type f | wc -l | tr -d ' ')" "0"
check "3572: HANDOVER_DIR=stub -> GO in the .env-configured root" "$([ -f "$S10_REAL/$S10_GO" ] && echo yes)" "yes"

# 10c. The configured root is gone: refuse non-zero rather than fall back to
# the stub the gate never reads.
printf 'HANDOVER_DIR=%s\n' "$tmp/s10-missing" > "$S10/.env"
rc=0; out=$(cd "$S10" && env -u HANDOVER_DIR -u HIMMEL_REPO bash "$S10/scripts/handover/chief-kit/go.sh" 77 "$SHA" 2>&1) || rc=$?
[ "$rc" -ne 0 ] && echo "ok - 3572: configured root missing -> non-zero ($rc)" || { echo "FAIL - 3572: configured root missing -> rc=0 (GO written where the gate cannot see it)"; fails=$((fails+1)); }
check "3572: configured root missing -> nothing under the repo stub" "$(find "$S10/handovers" -type f | wc -l | tr -d ' ')" "0"

# --- 11. nwo unresolvable -> refuse, no GO written -------------
# The mac binds the repo; a `gh repo view` failure must never fall back to
# writing an unbound GO.
ROOT11="$tmp/root11"; mkdir -p "$ROOT11"
rc=0; out="$(STUB_GH_REPO_VIEW_FAIL=1 HANDOVER_DIR="$ROOT11" bash "$SCRIPT" 79 "$SHA" 2>&1)" || rc=$?
check "3578: gh repo view fails -> exit 1" "$rc" "1"
contains "3578: names the cause" "$out" "gh repo view"
check "3578: nothing written" "$(find "$ROOT11" -type f | wc -l | tr -d ' ')" "0"

# --- 12. the mac binds the resolved nwo ------------------------
ROOT12="$tmp/root12"; mkdir -p "$ROOT12"
rc=0; STUB_NWO="a/b" HANDOVER_DIR="$ROOT12" bash "$SCRIPT" 80 "$SHA" >/dev/null 2>&1 || rc=$?
check "3578: write with nwo=a/b -> exit 0" "$rc" "0"
GO12="$ROOT12/.locks/go/80.$SHA"
MAC_AB=$(sed -n 's/^mac=//p' "$GO12" 2>/dev/null)
ROOT12B="$tmp/root12b"; mkdir -p "$ROOT12B"
rc=0; STUB_NWO="c/d" HANDOVER_DIR="$ROOT12B" bash "$SCRIPT" 80 "$SHA" >/dev/null 2>&1 || rc=$?
check "3578: write with nwo=c/d -> exit 0" "$rc" "0"
MAC_CD=$(sed -n 's/^mac=//p' "$ROOT12B/.locks/go/80.$SHA" 2>/dev/null)
[ -n "$MAC_AB" ] && [ -n "$MAC_CD" ] && [ "$MAC_AB" != "$MAC_CD" ] \
  && echo "ok - 3578: different nwo -> different mac for the same pr/sha" \
  || { echo "FAIL - 3578: mac [$MAC_AB] does not vary with nwo (got [$MAC_CD] for c/d)"; fails=$((fails+1)); }

# --- 13. --trust-reviewed signs the reviewer id -----------------
ROOT13="$tmp/root13"; mkdir -p "$ROOT13"
GO13="$ROOT13/.locks/go/81.$SHA"
for bad in "" "a b" "x;y" "id|z" "$(printf '%0129d' 0)"; do
  rc=0; HANDOVER_DIR="$ROOT13" bash "$SCRIPT" --trust-reviewed "$bad" 81 "$SHA" >/dev/null 2>&1 || rc=$?
  check "3895: --trust-reviewed [$bad] -> exit 2" "$rc" "2"
done
rc=0; HANDOVER_DIR="$ROOT13" bash "$SCRIPT" --trust-reviewed judge-N9 >/dev/null 2>&1 || rc=$?
check "3895: --trust-reviewed with no pr/sha -> exit 2" "$rc" "2"
check "3895: nothing written on usage errors" "$(find "$ROOT13" -type f | wc -l | tr -d ' ')" "0"
rc=0; HANDOVER_DIR="$ROOT13" bash "$SCRIPT" 81 "$SHA" >/dev/null 2>&1 || rc=$?
MAC_PLAIN=$(sed -n 's/^mac=//p' "$GO13" 2>/dev/null)
check "3895: an ordinary GO has no trust line" "$(grep -c '^trust-reviewed=' "$GO13" 2>/dev/null)" "0"
# a trust-reviewed GO needs the judge's GO verdict for this head.
VPR=81
verdict "$ROOT13" judge-N9 "**GO** for head \`$SHA\`."
verdict "$ROOT13" judge-N8 "**GO** for head \`$SHA\`."
rc=0; HANDOVER_DIR="$ROOT13" bash "$SCRIPT" --trust-reviewed judge-N9 81 "$SHA" >/dev/null 2>&1 || rc=$?
check "3895: --trust-reviewed judge-N9 -> exit 0" "$rc" "0"
contains "3895: trust-reviewed= line written" "$(cat "$GO13" 2>/dev/null)" "trust-reviewed=judge-N9"
MAC_T9=$(sed -n 's/^mac=//p' "$GO13" 2>/dev/null)
HANDOVER_DIR="$ROOT13" bash "$SCRIPT" --trust-reviewed judge-N8 81 "$SHA" >/dev/null 2>&1
MAC_T8=$(sed -n 's/^mac=//p' "$GO13" 2>/dev/null)
[ -n "$MAC_T9" ] && [ "$MAC_T9" != "$MAC_PLAIN" ] && [ "$MAC_T9" != "$MAC_T8" ] \
  && echo "ok - 3895: the mac covers the trust id (differs from the ordinary mac and per id)" \
  || { echo "FAIL - 3895: trust mac [$MAC_T9] vs plain [$MAC_PLAIN] vs N8 [$MAC_T8]"; fails=$((fails+1)); }
# The shared verifier accepts what the writer signed, and refuses an edited id.
# shellcheck source=scripts/lib/go-gate.sh
# shellcheck disable=SC1091
. "$HERE/../../lib/go-gate.sh"
rc=0; out=$(go_trust_gate 81 "$SHA" "$ROOT13" o/r) || rc=$?
check "3895: go_trust_gate accepts go.sh's trust GO" "$rc:$out" "0:judge-N8"
VPR=
# shellcheck disable=SC2218  # the read-race test below defines a sed() hook; this is the binary
sed -i.bak 's/^trust-reviewed=.*/trust-reviewed=judge-N7/' "$GO13"
rc=0; go_trust_gate 81 "$SHA" "$ROOT13" o/r >/dev/null || rc=$?
check "3895: go_trust_gate refuses an edited trust id" "$rc" "2"
HANDOVER_DIR="$ROOT13" bash "$SCRIPT" 81 "$SHA" >/dev/null 2>&1
rc=0; out=$(go_trust_gate 81 "$SHA" "$ROOT13" o/r) || rc=$?
check "3895: go_trust_gate refuses an ordinary GO" "$rc" "2"
contains "3895: and says how to grant one" "$out" "--trust-reviewed"
rc=0; go_gate 81 "$SHA" "$ROOT13" o/r >/dev/null || rc=$?
check "3895: go_gate still accepts the ordinary GO" "$rc" "0"
# Read race (judge NO-GO on PR 1479): a copy of the ordinary GO with a forged
# trust line keeps the ordinary mac. Swapped in after the verifier's first read
# of the file, a verifier that re-reads it checks the mac against the genuine
# copy and takes the trust id from the forged one. The sed hook swaps on its
# first call, deterministically; the verifier must read the file once.
cp "$GO13" "$GO13.forged"
printf 'trust-reviewed=forged\n' >> "$GO13.forged"
# shellcheck disable=SC2317,SC2329  # invoked indirectly, by the verifier under test
sed() { command sed "$@"; local r=$?; [ -f "$GO13.forged" ] && mv -f "$GO13.forged" "$GO13"; return "$r"; }
rc=0; out=$(go_trust_gate 81 "$SHA" "$ROOT13" o/r) || rc=$?
unset -f sed
check "3895: a GO swapped between reads never yields a trust id" "$rc" "2"
rm -f "$GO13.forged"

# --- 14. no GO for a head ready-check does not pass ------------
# The chief ran ready-check by convention only; go.sh signed any head. It
# now runs ready-check itself (check 4 is the CR-ledger ok row at the head)
# and refuses, exit 4 and nothing written, on anything but PASS.
mkdir -p "$ROOT14"
SHA14=$(ready_pass_repo "$READY_REPO" 14) || { echo "FAIL: ready_pass_repo" >&2; exit 1; }
rc=0; out="$(READY_STUB_HEAD="$SHA14" HANDOVER_DIR="$ROOT14" bash "$SCRIPT" 82 "$SHA14" 2>&1)" || rc=$?
check    "4565: unreviewed head (no ledger ok row) -> exit 4" "$rc" "4"
contains "4565: names the failed check" "$out" "4. CR ledger"
check    "4565: unreviewed head -> nothing written" "$(find "$ROOT14" -type f | wc -l | tr -d ' ')" "0"
ready_pass_ledger "$READY_REPO" "$SHA14"
rc=0; out="$(READY_STUB_HEAD="$SHA" HANDOVER_DIR="$ROOT14" bash "$SCRIPT" 82 "$SHA14" 2>&1)" || rc=$?
check    "4565: PR head moved past the sha -> exit 4" "$rc" "4"
check    "4565: moved head -> nothing written" "$(find "$ROOT14" -type f | wc -l | tr -d ' ')" "0"
rc=0; out="$(cd "$ROOT14" && HIMMEL_REPO="$ROOT14" READY_STUB_HEAD="$SHA14" HANDOVER_DIR="$ROOT14" bash "$SCRIPT" 82 "$SHA14" 2>&1)" || rc=$?
check    "4565: run outside any repo (no ledger to read) -> exit 4" "$rc" "4"
rc=0; out="$(cd "$ROOT14" && HIMMEL_REPO=rel HANDOVER_DIR="$ROOT14" bash "$SCRIPT" 82 "$SHA14" 2>&1)" || rc=$?
check    "9841: a relative HIMMEL_REPO -> exit 1 and the exact refusal" "$rc|$out" "1|go: HIMMEL_REPO (rel) is not an absolute path - refusing to let it pick the gated checkout; no GO written"
rc=0; out="$(cd "$ROOT14" && HIMMEL_REPO="$ROOT14/gone" HANDOVER_DIR="$ROOT14" bash "$SCRIPT" 82 "$SHA14" 2>&1)" || rc=$?
check    "9841: a HIMMEL_REPO that is not a directory -> exit 1 and the exact refusal" "$rc|$out" "1|go: the gated checkout HIMMEL_REPO ($ROOT14/gone) is not a directory - no GO written"
rc=0; out="$(READY_STUB_HEAD="$SHA14" HANDOVER_DIR="$ROOT14" bash "$SCRIPT" 82 "$SHA14" 2>/dev/null)" || rc=$?
check    "4565: reviewed head -> exit 0" "$rc" "0"
check    "4565: reviewed head -> the GO path" "$out" "$ROOT14/.locks/go/82.$SHA14"

# --- 15. --trust-reviewed <qid> needs that judge's GO verdict ---
# The verdict file is <root>/<user>/<bucket>/verdicts/<qid>/*.md; the first
# non-blank line under `## Verdict` parses only as **GO**/**NO-GO** for head
# `<sha>` (a trailing full stop allowed). An unparsed file, a NO-GO on this head,
# or no GO on this head refuses, exit 5, nothing written; another head's verdict
# (an earlier round) is ignored.
mkdir -p "$ROOT15"
t15() {  # <label> <qid> - expect a refusal, nothing written
  local rc=0
  out="$(HANDOVER_DIR="$ROOT15" bash "$SCRIPT" --trust-reviewed "$2" 83 "$SHA" 2>&1)" || rc=$?
  check "3832: $1 -> exit 5" "$rc" "5"
  check "3832: $1 -> nothing written" "$(find "$ROOT15/.locks" -type f 2>/dev/null | wc -l | tr -d ' ')" "0"
}
t15 "no verdict dir" J1
verdict "$ROOT15" J2 "**NO-GO** for head \`$SHA\`."
t15 "NO-GO verdict" J2
verdict "$ROOT15" J3 "**GO** for head \`$SHA14\`."
t15 "GO for another head" J3
verdict "$ROOT15" J4 "**GO.**"
t15 "GO bound to no head (unparsed)" J4
verdict "$ROOT15" J5 "**GO** for head \`$SHA\`. Ship it."
t15 "trailing text after the head (unparsed)" J5
verdict "$ROOT15" J6 "**GO** for head \`$SHA\`."
verdict "$ROOT15" J6 "**NO-GO** for head \`$SHA\`." second
t15 "a second judge file says NO-GO" J6
verdict "$ROOT15" J7 "**GO** for head \`$SHA\`."
verdict "$ROOT15" J7 "**GO.**" second
t15 "a second judge file is unparsed" J7
mkdir -p "$ROOT15/$VSCOPE/verdicts/J8"
t15 "an empty verdict dir" J8
verdict "$ROOT15" "judge:J9" "**GO** for head \`$SHA\`."
t15 "an id that is not a qid path segment" "judge:J9"
# any judge's NO-GO for this PR at the head vetoes every trust GO
# (section 29), and an unparsed record for this PR refuses it (it may be a drifted
# NO-GO), so the NO-GO records of J2 and J6 and the unparsed ones of J4, J5 and J7
# leave before the GO rows below.
rm -f "$ROOT15/$VSCOPE/verdicts/J2/HIMMEL-1-judge-J2.md" "$ROOT15/$VSCOPE/verdicts/J6/second.md" \
  "$ROOT15/$VSCOPE/verdicts/J4/HIMMEL-1-judge-J4.md" "$ROOT15/$VSCOPE/verdicts/J5/HIMMEL-1-judge-J5.md" \
  "$ROOT15/$VSCOPE/verdicts/J7/second.md"
verdict "$ROOT15" J10 "**GO** for head \`$SHA\`."
rc=0; out="$(HANDOVER_DIR="$ROOT15" bash "$SCRIPT" --trust-reviewed J10 83 "$SHA" 2>/dev/null)" || rc=$?
check    "3832: GO verdict for this head -> exit 0" "$rc" "0"
contains "3832: trust id signed in" "$(cat "$ROOT15/.locks/go/83.$SHA" 2>/dev/null)" "trust-reviewed=J10"
verdict "$ROOT15" J11 "**GO** for head \`$SHA\`"
rc=0; HANDOVER_DIR="$ROOT15" bash "$SCRIPT" --trust-reviewed J11 83 "$SHA" >/dev/null 2>&1 || rc=$?
check    "3832: no trailing full stop -> exit 0" "$rc" "0"
# the earlier round's head is a real commit the head descends from: a NO-GO at a
# commit go.sh cannot place in the caller's checkout refuses
git -C "$READY_REPO" -c user.email=t@t -c user.name=t -c commit.gpgsign=false commit -q --allow-empty -m round1
R1_15=$(git -C "$READY_REPO" rev-parse HEAD)
git -C "$READY_REPO" -c user.email=t@t -c user.name=t -c commit.gpgsign=false commit -q --allow-empty -m round2
R2_15=$(git -C "$READY_REPO" rev-parse HEAD)
ready_pass_ledger "$READY_REPO" "$R2_15"
verdict "$ROOT15" J12 "**NO-GO** for head \`$R1_15\`." round1
verdict "$ROOT15" J12 "**GO** for head \`$R2_15\`." round2
rc=0; READY_STUB_HEAD="$R2_15" HANDOVER_DIR="$ROOT15" bash "$SCRIPT" --trust-reviewed J12 83 "$R2_15" >/dev/null 2>&1 || rc=$?
check    "3832: an earlier round's NO-GO on another head is ignored -> exit 0" "$rc" "0"
rm -f "$ROOT15/$VSCOPE/verdicts/J12/round1.md"  # a NO-GO at R1 cannot be placed against the fake $SHA below
mkdir -p "$ROOT15/$VSCOPE/verdicts/J13"
# shellcheck disable=SC2016  # the backticks are the verdict line's literal text
printf '# VERDICT J13 - judge\r\n\r\n## Verdict\r\n\r\n**GO** for head `%s`.\r\n\r\npr: 83\r\n\r\nreason\r\n' "$SHA" \
  > "$ROOT15/$VSCOPE/verdicts/J13/HIMMEL-1-judge-J13.md"
vsign J13 "$ROOT15/$VSCOPE/verdicts/J13/HIMMEL-1-judge-J13.md"
rc=0; HANDOVER_DIR="$ROOT15" bash "$SCRIPT" --trust-reviewed J13 83 "$SHA" >/dev/null 2>&1 || rc=$?
check    "3832: a CRLF verdict file -> exit 0" "$rc" "0"

# --- 16. only this repo's own <user>/<bucket> verdicts count -----
# A judge can write verdicts/<qid>/ in any bucket; the lookup must not read them.
t16() {  # <label> <qid> - expect a refusal, nothing written
  local rc=0
  out="$(HANDOVER_DIR="$ROOT16" bash "$SCRIPT" --trust-reviewed "$2" 84 "$SHA" 2>&1)" || rc=$?
  check "4589: $1 -> exit 5" "$rc" "5"
  check "4589: $1 -> nothing written" "$(find "$ROOT16/.locks" -type f 2>/dev/null | wc -l | tr -d ' ')" "0"
}
mkdir -p "$ROOT16"
VPR=84
other_verdict() {  # <scope> <qid> - a GO for $SHA written under another scope
  mkdir -p "$ROOT16/$1/verdicts/$2"
  # shellcheck disable=SC2016  # the backticks are the verdict line's literal text
  printf '# VERDICT %s - judge\n\n## Verdict\n\n**GO** for head `%s`.\n\npr: 84\n' "$2" "$SHA" > "$ROOT16/$1/verdicts/$2/HIMMEL-1-judge-$2.md"
}
other_verdict "u/not-this-repo" K1
t16 "a GO in another repo bucket" K1
other_verdict "someone-else/$VBUCKET" K2
t16 "a GO under another user" K2
other_verdict "u/not-this-repo" K3
verdict "$ROOT16" K3 "**NO-GO** for head \`$SHA\`."
t16 "own-bucket NO-GO beats another bucket's GO" K3
rm -f "$ROOT16/$VSCOPE/verdicts/K3/HIMMEL-1-judge-K3.md"  # its NO-GO would veto K4's GO (section 29)
verdict "$ROOT16" K4 "**GO** for head \`$SHA\`."
other_verdict "u/not-this-repo" K4
rc=0; HANDOVER_DIR="$ROOT16" bash "$SCRIPT" --trust-reviewed K4 84 "$SHA" >/dev/null 2>&1 || rc=$?
check "4589: own-bucket GO still satisfies it -> exit 0" "$rc" "0"
rm -rf "$ROOT16/.locks"
other_verdict "u/$VBUCKET" K5
rc=0; out="$(USER_SLUG='../x' HANDOVER_DIR="$ROOT16" bash "$SCRIPT" --trust-reviewed K5 84 "$SHA" 2>&1)" || rc=$?
check "4589: an unresolvable user slug fails closed -> exit 5" "$rc" "5"
contains "4589: and says the scope cannot resolve" "$out" "cannot resolve this repo's <user>/<bucket> verdict scope"

# --- 17. a trust verdict counts only for the PR it names -------
# Two PRs can point at one head; the verdict's pr: line (two lines after the
# verdict line) must equal go.sh's PR. A verdict with no pr: line fails closed:
# it was written before the field existed and the judge rewrites it with
# write-verdict.sh --pr.
# shellcheck disable=SC2031  # tmp is assigned at the top; the subshell reads are not writes
ROOT17="$tmp/root17"; mkdir -p "$ROOT17"
t17() {  # <label> <qid> <pr> <stable text> - expect a refusal, nothing written
  local rc=0
  out="$(HANDOVER_DIR="$ROOT17" bash "$SCRIPT" --trust-reviewed "$2" "$3" "$SHA" 2>&1)" || rc=$?
  check "4928: $1 -> exit 5" "$rc" "5"
  contains "4928: $1 -> says why" "$out" "$4"
  check "4928: $1 -> nothing written" "$(find "$ROOT17/.locks" -type f 2>/dev/null | wc -l | tr -d ' ')" "0"
}
VPR=90; verdict "$ROOT17" L1 "**GO** for head \`$SHA\`."
t17 "a GO naming another PR on the same head" L1 91 "names PR #90, not PR #91"
rc=0; HANDOVER_DIR="$ROOT17" bash "$SCRIPT" --trust-reviewed L1 90 "$SHA" >/dev/null 2>&1 || rc=$?
check "4928: the same verdict satisfies its own PR -> exit 0" "$rc" "0"
rm -rf "$ROOT17/.locks"
mkdir -p "$ROOT17/$VSCOPE/verdicts/L2"
# shellcheck disable=SC2016  # the backticks are the verdict line literal text
printf '# VERDICT L2 - judge\n\n## Verdict\n\n**GO** for head `%s`.\n\nreason\n' "$SHA" > "$ROOT17/$VSCOPE/verdicts/L2/HIMMEL-1-judge-L2.md"
vsign L2 "$ROOT17/$VSCOPE/verdicts/L2/HIMMEL-1-judge-L2.md"
t17 "a legacy GO with no pr: line" L2 90 "names no PR"
mkdir -p "$ROOT17/$VSCOPE/verdicts/L3"
# shellcheck disable=SC2016  # the backticks are the verdict line literal text
printf '# VERDICT L3 - judge\n\n## Verdict\n\n**GO** for head `%s`.\n\nreason\npr: 90\n' "$SHA" > "$ROOT17/$VSCOPE/verdicts/L3/HIMMEL-1-judge-L3.md"
vsign L3 "$ROOT17/$VSCOPE/verdicts/L3/HIMMEL-1-judge-L3.md"
t17 "a pr: line in the body is not the field" L3 90 "names no PR"
VPR=90; verdict "$ROOT17" L4 "**NO-GO** for head \`$SHA\`."
t17 "a NO-GO naming another PR still vetoes" L4 91 "NO-GO for head"
VPR=

# --- 18. a record counts as merge trust only with its mac --------
mkdir -p "$ROOT18"
t18() {  # <label> <qid> - expect a refusal, nothing written
  local rc=0
  out="$(HANDOVER_DIR="$ROOT18" bash "$SCRIPT" --trust-reviewed "$2" 95 "$SHA" 2>&1)" || rc=$?
  check "4984: $1 -> exit 5" "$rc" "5"
  check "4984: $1 -> nothing written" "$(find "$ROOT18/.locks" -type f 2>/dev/null | wc -l | tr -d ' ')" "0"
}
VPR=95
VSIGN=0 verdict "$ROOT18" M1 "**GO** for head \`$SHA\`."
t18 "a hand-written exact-format GO (no mac)" M1
verdict "$ROOT18" M2 "**GO** for head \`$SHA\`."
sed -i.bak 's/^reason$/reasoN/' "$ROOT18/$VSCOPE/verdicts/M2/HIMMEL-1-judge-M2.md"
rm -f "$ROOT18/$VSCOPE/verdicts/M2/"*.bak
t18 "an edited evidence byte invalidates the mac" M2
VEXTRA=$'\ndelta-scope: test-only\ndelta-from: 0123456789abcdef0123456789abcdef01234566\n' verdict "$ROOT18" M3 "**GO** for head \`$SHA\`."
t18 "a signed scope-round record is not merge trust" M3
verdict "$ROOT18" M4 "**GO** for head \`$SHA\`."
rc=0; HANDOVER_DIR="$ROOT18" bash "$SCRIPT" --trust-reviewed M4 95 "$SHA" >/dev/null 2>&1 || rc=$?
check "4984: a signed GO still satisfies --trust-reviewed -> exit 0" "$rc" "0"
VPR=

# --- 19. a sibling record that cannot be read whole vetoes -------
# A signed GO beside a sibling that is NUL-bearing, empty or mode 000 must not be
# admitted: the sibling may be a NO-GO that main would honour (fail closed).
ROOT19="$tmp/root19"; mkdir -p "$ROOT19"
t19() {  # <label> <qid> - expect a refusal naming the unreadable record
  local rc=0
  out="$(HANDOVER_DIR="$ROOT19" bash "$SCRIPT" --trust-reviewed "$2" 96 "$SHA" 2>&1)" || rc=$?
  check "4984: $1 -> exit 5" "$rc" "5"
  contains "4984: $1 -> says why" "$out" "cannot be read whole"
  check "4984: $1 -> nothing written" "$(find "$ROOT19/.locks" -type f 2>/dev/null | wc -l | tr -d ' ')" "0"
}
VPR=96
verdict "$ROOT19" N1 "**GO** for head \`$SHA\`."
verdict "$ROOT19" N1 "**NO-GO** for head \`$SHA\`." zz-nogo
printf 'x\0y\n' >> "$ROOT19/$VSCOPE/verdicts/N1/zz-nogo.md"
t19 "a NUL-bearing sibling beside a signed GO" N1
verdict "$ROOT19" N2 "**GO** for head \`$SHA\`."
: > "$ROOT19/$VSCOPE/verdicts/N2/zz-empty.md"
t19 "an empty sibling beside a signed GO" N2
verdict "$ROOT19" N3 "**GO** for head \`$SHA\`."
verdict "$ROOT19" N3 "**NO-GO** for head \`$SHA\`." zz-locked
chmod 000 "$ROOT19/$VSCOPE/verdicts/N3/zz-locked.md"
if [ "$(id -u)" != 0 ]; then
  t19 "a mode-000 sibling beside a signed GO" N3
fi
chmod 600 "$ROOT19/$VSCOPE/verdicts/N3/zz-locked.md"
VPR=

# --- 20. --fix-main-red <run-id> writes the fix-GO ----------------
# A separate, signed file naming one red run; never an ordinary GO.
ROOT20="$tmp/root20"; mkdir -p "$ROOT20"
rc=0; out="$(HANDOVER_DIR="$ROOT20" bash "$SCRIPT" --fix-main-red 37964772913 97 "$SHA" 2>&1)" || rc=$?
check "5134: --fix-main-red writes -> exit 0" "$rc" "0"
check "5134: prints the fix-GO path" "$out" "$ROOT20/.locks/go/fix-main-red.97.$SHA.37964772913"
F20="$ROOT20/.locks/go/fix-main-red.97.$SHA.37964772913"
contains "5134: names the red run" "$(cat "$F20" 2>/dev/null)" "fix-main-red-run=37964772913"
contains "5134: carries head=" "$(cat "$F20" 2>/dev/null)" "head=$SHA"
check "5134: no ordinary GO is written beside it" "$(compgen -G "$ROOT20/.locks/go/97.*" | wc -l | tr -d ' ')" "0"
# the written file verifies under the shared gate for the SAME run only
fx_rc() { bash -c '. "$1"; go_fixred_gate 97 "$2" "$3" o/r "$4"' _ "$HERE/../../lib/go-gate.sh" "$SHA" "$ROOT20" "$1" >/dev/null 2>&1; echo $?; }
check "5134: the gate accepts it for the red run" "$(fx_rc 37964772913)" "0"
check "5134: the gate refuses it for another run" "$(fx_rc 37964772914)" "2"
for bad in "abc" "0123" "-1" "" "1 2"; do
  rc=0; HANDOVER_DIR="$ROOT20" bash "$SCRIPT" --fix-main-red "$bad" 97 "$SHA" >/dev/null 2>&1 || rc=$?
  check "5134: run id '$bad' -> exit 2" "$rc" "2"
done
rc=0; HANDOVER_DIR="$ROOT20" bash "$SCRIPT" --fix-main-red 37964772913 --trust-reviewed J1 97 "$SHA" >/dev/null 2>&1 || rc=$?
check "5134: --fix-main-red with --trust-reviewed -> exit 2" "$rc" "2"
ROOT20B="$tmp/root20b"; mkdir -p "$ROOT20B"
rc=0; HIMMEL_CONSOLE_LEG=1 HANDOVER_DIR="$ROOT20B" _as_claude bash "$SCRIPT" --fix-main-red 37964772913 97 "$SHA" >/dev/null 2>&1 || rc=$?
check "5134: a chief-spawned worker cannot write a fix-GO -> exit 3" "$rc" "3"
check "5134: nothing written by the refused worker" "$(find "$ROOT20B" -type f 2>/dev/null | wc -l | tr -d ' ')" "0"

# --- 21. a plain GO on a computed trust path is refused ------------
# ready-check prints TRUST-PATH: yes from the PR diff and the default branch's list;
# the worker's READY prose is never read. A plain GO then exits 8 with nothing written;
# --trust-reviewed with the judge's GO verdict still writes it. A fixture anchor with
# a local origin keeps trust_path_check's anchor-is-current test offline.
# not $tmp: section 13 sourced go-gate.sh, which reassigns it
ROOT21="${ROOT%/*}/root21"; mkdir -p "$ROOT21"
TP21_ORIGIN="${ROOT%/*}/tp21-origin.git"; TP21_ANCHOR="${ROOT%/*}/tp21-anchor"
git init -q --bare "$TP21_ORIGIN"
git init -q "$TP21_ANCHOR"
mkdir -p "$TP21_ANCHOR/scripts/lib"
cp "$HERE/../../lib/go-gate.sh" "$TP21_ANCHOR/scripts/lib/go-gate.sh"
# check 19 runs the anchor's impacted-suites.sh
mkdir -p "$TP21_ANCHOR/scripts/cr"
cp "$HERE/../../cr/impacted-suites.sh" "$HERE/../../cr/anchor-handoff.sh" "$TP21_ANCHOR/scripts/cr/"
cp "$HERE/../../lib/review-default-base.sh" "$TP21_ANCHOR/scripts/lib/"
git -C "$TP21_ANCHOR" add -A
git -C "$TP21_ANCHOR" -c user.name=t -c user.email=t@t commit -q -m init
git -C "$TP21_ANCHOR" remote add origin "$TP21_ORIGIN"
git -C "$TP21_ANCHOR" push -q origin HEAD:refs/heads/main 2>/dev/null
git -C "$TP21_ORIGIN" symbolic-ref HEAD refs/heads/main
export READY_CHECK_ANCHOR="$TP21_ANCHOR"
for shape in scripts/lib/fixtures/anything.txt scripts/lib/env-alias.sh; do
  rc=0; out="$(READY_STUB_TRUST_FILE="$shape" HANDOVER_DIR="$ROOT21" bash "$SCRIPT" 85 "$SHA" 2>&1)" || rc=$?
  check    "6033: plain GO on $shape -> exit 8" "$rc" "8"
  contains "6033: $shape refusal names the judge route" "$out" "go.sh --trust-reviewed <judge qid>"
  check    "6033: $shape refusal -> nothing written" "$(find "$ROOT21" -type f | wc -l | tr -d ' ')" "0"
done
VPR=85 verdict "$ROOT21" T1 "**GO** for head \`$SHA\`."
rc=0; READY_STUB_TRUST_FILE=scripts/lib/env-alias.sh HANDOVER_DIR="$ROOT21" bash "$SCRIPT" --trust-reviewed T1 85 "$SHA" >/dev/null 2>&1 || rc=$?
check    "6033: --trust-reviewed GO on a trust path -> exit 0" "$rc" "0"
contains "6033: --trust-reviewed GO is written and signed" "$(cat "$ROOT21/.locks/go/85.$SHA" 2>/dev/null)" "trust-reviewed=T1"
rc=0; READY_STUB_TRUST_FILE=docs/a.md HANDOVER_DIR="$ROOT21" bash "$SCRIPT" 86 "$SHA" >/dev/null 2>&1 || rc=$?
check    "6033: plain GO on a non-trust diff -> exit 0" "$rc" "0"
rc=0; out="$(READY_STUB_TRUST_LIST_FAIL=1 HANDOVER_DIR="$ROOT21" bash "$SCRIPT" 87 "$SHA" 2>&1)" || rc=$?
check    "6033: unreadable trust list -> ready-check refuses, exit 4" "$rc" "4"
check    "6033: unreadable trust list -> nothing written for 87" "$(compgen -G "$ROOT21/.locks/go/87.*" | wc -l | tr -d ' ')" "0"
unset READY_CHECK_ANCHOR

# --- 22. every merge GO is persisted as a verdict record ----------
# a plain GO writes verdicts/go-pr-<n>/chief-go-<head>.md through write-verdict.sh,
# beside no judge's file; the GO is never blocked by logging
ROOT22="$tmp/root22"; mkdir -p "$ROOT22"
REC22="$ROOT22/$VSCOPE/verdicts/go-pr-77/chief-go-$SHA.md"
rc=0; out="$(HANDOVER_DIR="$ROOT22" CHIEF_SESSION_NAME=chief-x bash "$SCRIPT" --model claude-opus-5-5 --effort high 77 "$SHA" 2>&1)" || rc=$?
check "22: a plain GO exits 0" "$rc" "0"
check "22: the GO file is still written" "$(test -f "$ROOT22/.locks/go/77.$SHA" && echo yes)" "yes"
check "22: the GO leaves a persisted record" "$(test -f "$REC22" && echo yes)" "yes"
rec22="$(cat "$REC22" 2>/dev/null || true)"
contains "22: the record rules GO on the head" "$rec22" "**GO** for head \`$SHA\`."
contains "22: the record carries the model" "$rec22" "model: claude-opus-5-5"
contains "22: the record carries the effort" "$rec22" "effort: high"
contains "22: the record names the PR" "$rec22" "pr: 77"
rc=0
# shellcheck disable=SC2031  # the export is scoped to this subshell; the earlier uses are env prefixes
( export HANDOVER_DIR="$ROOT22"; . "$HERE/../../lib/go-gate.sh"; go_trust_verdict "$ROOT22" go-pr-77 "$SHA" "$HERE/../../.." 77 >/dev/null ) || rc=$?
check "22: the record is signed so go_trust_verdict accepts it" "$rc" "0"
check "22: the printed path is still the GO file" "$(printf '%s\n' "$out" | tail -n 1)" "$ROOT22/.locks/go/77.$SHA"
# model and effort fall back to the env, then to unknown: a GO is never refused for them
ROOT22B="$tmp/root22b"; mkdir -p "$ROOT22B"
rc=0; HANDOVER_DIR="$ROOT22B" HIMMEL_VERDICT_MODEL=env-model HIMMEL_VERDICT_EFFORT=low bash "$SCRIPT" 77 "$SHA" >/dev/null 2>&1 || rc=$?
check "22: a GO with the env model exits 0" "$rc" "0"
contains "22: the env model is recorded" "$(cat "$ROOT22B/$VSCOPE/verdicts/go-pr-77/chief-go-$SHA.md" 2>/dev/null)" "model: env-model"
ROOT22C="$tmp/root22c"; mkdir -p "$ROOT22C"
rc=0; env -u HIMMEL_VERDICT_MODEL -u HIMMEL_VERDICT_EFFORT -u CLAUDE_CODE_EFFORT_LEVEL HANDOVER_DIR="$ROOT22C" bash "$SCRIPT" 77 "$SHA" >/dev/null 2>&1 || rc=$?
check "22: a GO with no model or effort anywhere still exits 0" "$rc" "0"
check "22: that GO file is written" "$(test -f "$ROOT22C/.locks/go/77.$SHA" && echo yes)" "yes"
rec22c="$(cat "$ROOT22C/$VSCOPE/verdicts/go-pr-77/chief-go-$SHA.md" 2>/dev/null || true)"
contains "22: model falls back to unknown" "$rec22c" "model: unknown"
contains "22: effort falls back to unknown" "$rec22c" "effort: unknown"
# a record that cannot be written warns and the GO still goes through
ROOT22D="$tmp/root22d"; mkdir -p "$ROOT22D/$VSCOPE/verdicts" "$tmp/elsewhere22"
ln -s "$tmp/elsewhere22" "$ROOT22D/$VSCOPE/verdicts/go-pr-77"
rc=0; out="$(HANDOVER_DIR="$ROOT22D" bash "$SCRIPT" --model m --effort e 77 "$SHA" 2>&1)" || rc=$?
check "22: an unwritable record does not block the GO" "$rc" "0"
check "22: the GO file is written despite it" "$(test -f "$ROOT22D/.locks/go/77.$SHA" && echo yes)" "yes"
contains "22: the failure is a warning" "$out" "verdict record was not persisted"
# a fix-main-red GO is not a merge GO and persists no record
ROOT22E="$tmp/root22e"; mkdir -p "$ROOT22E"
rc=0; HANDOVER_DIR="$ROOT22E" bash "$SCRIPT" --fix-main-red 4242 77 "$SHA" >/dev/null 2>&1 || rc=$?
check "22: a fix-main-red GO exits 0" "$rc" "0"
check "22: a fix-main-red GO persists no verdict record" "$(test -e "$ROOT22E/$VSCOPE/verdicts/go-pr-77" && echo yes || echo no)" "no"
# a repeated --model or --effort is a usage error, like every other option
ROOT22F="$tmp/root22f"; mkdir -p "$ROOT22F"
rc=0; HANDOVER_DIR="$ROOT22F" bash "$SCRIPT" --model m1 --model m2 78 "$SHA" >/dev/null 2>&1 || rc=$?
check "22: a repeated --model -> exit 2" "$rc" "2"
rc=0; HANDOVER_DIR="$ROOT22F" bash "$SCRIPT" --effort high --effort low 78 "$SHA" >/dev/null 2>&1 || rc=$?
check "22: a repeated --effort -> exit 2" "$rc" "2"
check "22: a repeated option writes no GO" "$(test -e "$ROOT22F/.locks/go/78.$SHA" && echo yes || echo no)" "no"
# a persisted chief GO (qid go-pr-<n>) is not a judge: --trust-reviewed refuses that namespace
rc=0; out="$(HANDOVER_DIR="$ROOT22F" bash "$SCRIPT" --trust-reviewed go-pr-78 78 "$SHA" 2>&1)" || rc=$?
check "22: --trust-reviewed go-pr-78 -> exit 2" "$rc" "2"
contains "22: the refusal names the reserved namespace" "$out" "go-pr-"
check "22: the reserved qid writes no GO" "$(test -e "$ROOT22F/.locks/go/78.$SHA" && echo yes || echo no)" "no"

# --- 23. an adopted repo gets a trust-reviewed GO for its own PRs ----------
# R3: an operator-adopted repo (scripts/guardrails/himmel-adopted.json on the
# harness's default branch, merge_allowed true) whose PR touches its declared
# trust path ^deploy/ gets `go.sh --repo acme/widget --trust-reviewed <q>`: the
# GO signs acme/widget, and go_trust_gate - merge-on-green's predicate on a
# trust-path hit - accepts it. The judge record lives in acme/widget's own
# bucket (u/acme--widget) and names the repo in a signed repo: line. R4: a plain GO
# for that PR stays refused. The allowlist fails closed on every bad shape.
ROOT23="$tmp/root23"; mkdir -p "$ROOT23"
A23_BIN="$tmp/a23-bin"; mkdir -p "$A23_BIN"
A23_ORIGIN=$(git -C "$HERE" remote get-url origin | sed -E 's#^(https?://[^/]+/|git@[^:]+:|ssh://git@[^/]+/)##; s#\.git$##')
export A23_ORIGIN A23_ADOPTED="$tmp/a23-adopted.json" A23_ADAPTERS="$tmp/a23-adapters.json" A23_HEAD="$SHA"
cat > "$A23_BIN/gh" <<'STUB'
#!/usr/bin/env bash
case "$1 $2" in
    "repo view")
        case "$*" in
            *defaultBranchRef*) printf 'main' ;;
            *) printf '%s' "${STUB_NWO:-o/r}" ;;
        esac ;;
    "api repos/"*)
        case "$2" in
            "repos/$A23_ORIGIN/contents/scripts/guardrails/himmel-adopted.json?ref=main") cat "$A23_ADOPTED" 2>/dev/null || exit 1 ;;
            "repos/$A23_ORIGIN/contents/scripts/guardrails/himmel-adapters.json?ref=main") cat "$A23_ADAPTERS" 2>/dev/null || exit 1 ;;
            *) exit 1 ;;
        esac ;;
    "pr view")
        printf '{"state":"OPEN","headRefOid":"%s","mergeable":"MERGEABLE","baseRefName":"%s","mergeStateStatus":"CLEAN","statusCheckRollup":[{"name":"ci","status":"COMPLETED","conclusion":"SUCCESS"}]}\n' "$A23_HEAD" "${A23_BASE:-main}" ;;
    "api graphql")
        printf '{"data":{"repository":{"pullRequest":{"reviewThreads":{"pageInfo":{"hasNextPage":false},"nodes":[]}}}}}\n' ;;
    *) exit 91 ;;
esac
STUB
chmod +x "$A23_BIN/gh"
a23() { PATH="$A23_BIN:$PATH" HANDOVER_DIR="$ROOT23" bash "$SCRIPT" "$@"; }
# averdict <scope> <qid> <repo line or empty> - a signed GO record for PR 88 at $SHA.
averdict() {
  local vf="$ROOT23/$1/verdicts/$2/judge.md" vmac
  mkdir -p "$ROOT23/$1/verdicts/$2"
  # shellcheck disable=SC2016  # the backticks are the verdict line's literal text
  printf '# VERDICT %s - judge\n\n## Verdict\n\n**GO** for head `%s`.\n\npr: 88\n%smodel: m\neffort: e\n\nreason\n' "$2" "$SHA" "${3:+$3
}" > "$vf"
  vmac="$(bash -c '. "$1"; go_verdict_mac "$2" "$3" judge' _ "$HERE/../../lib/go-gate.sh" "$1" "$2" < "$vf")" || { echo "FAIL - cannot sign $vf"; fails=$((fails+1)); return 1; }
  printf 'mac: %s\n' "$vmac" >> "$vf"
}
printf '[{"nwo":"acme/widget","merge_allowed":true},{"nwo":"acme/off","merge_allowed":false}]\n' > "$A23_ADOPTED"
averdict u/acme--widget W1 "repo: acme/widget"
rc=0; out="$(a23 --repo acme/widget --trust-reviewed W1 88 "$SHA" 2>&1)" || rc=$?
check    "7392 R3: adopted repo trust-reviewed GO -> exit 0" "$rc" "0"
GO23="$ROOT23/.locks/go/88.$SHA"
contains "7392 R3: the GO carries the judge's qid" "$(cat "$GO23" 2>/dev/null)" "trust-reviewed=W1"
rc=0; out=$(go_trust_gate 88 "$SHA" "$ROOT23" acme/widget) || rc=$?
check    "7392 R3: go_trust_gate accepts it for acme/widget" "$rc:$out" "0:W1"
rc=0; go_trust_gate 88 "$SHA" "$ROOT23" o/r >/dev/null || rc=$?
check    "7392 R3: the GO signs acme/widget, not the harness repo" "$rc" "2"
REC23="$ROOT23/u/acme--widget/verdicts/go-pr-88/chief-go-$SHA.md"
contains "7392 R3: the persisted GO record names the repo" "$(cat "$REC23" 2>/dev/null)" "repo: acme/widget"
# R4: the same PR on a plain GO stays refused - go.sh will not write one, and
# a plain GO signed for acme/widget fails the trust gate.
rm -f "$GO23"
rc=0; a23 --repo acme/widget 88 "$SHA" >/dev/null 2>&1 || rc=$?
check    "7392 R4: --repo without --trust-reviewed -> exit 2" "$rc" "2"
mkdir -p "$ROOT23/.locks/go"
{ printf 'pr=88\nhead=%s\nby=t\nat=t\n' "$SHA"; printf 'mac=%s\n' "$(go_mac 88 "$SHA" acme/widget "")"; } > "$GO23"
rc=0; out=$(go_trust_gate 88 "$SHA" "$ROOT23" acme/widget) || rc=$?
check    "7392 R4: a plain GO for the adopted PR fails the trust gate" "$rc" "2"
rm -f "$GO23"
# t23 <label> <want rc> <args...> - a refusal that writes no GO
t23() {
  local label="$1" want="$2" rc=0; shift 2
  a23 "$@" >/dev/null 2>&1 || rc=$?
  check "7392: $label -> exit $want" "$rc" "$want"
  check "7392: $label -> no GO written" "$(test -e "$GO23" && echo yes || echo no)" "no"
}
t23 "merge_allowed false" 6 --repo acme/off --trust-reviewed W1 88 "$SHA"
t23 "a repo not on the list" 6 --repo acme/other --trust-reviewed W1 88 "$SHA"
printf '[{"nwo":"acme/widget","merge_allowed":"true"}]\n' > "$A23_ADOPTED"
t23 "merge_allowed a string" 6 --repo acme/widget --trust-reviewed W1 88 "$SHA"
printf '[{"nwo":"acme/widget","merge_allowed":true},{"nwo":"acme/widget","merge_allowed":true}]\n' > "$A23_ADOPTED"
t23 "a duplicate nwo" 6 --repo acme/widget --trust-reviewed W1 88 "$SHA"
printf 'not json\n' > "$A23_ADOPTED"
t23 "invalid JSON" 6 --repo acme/widget --trust-reviewed W1 88 "$SHA"
printf '{"nwo":"acme/widget","merge_allowed":true}\n' > "$A23_ADOPTED"
t23 "an object, not an array" 6 --repo acme/widget --trust-reviewed W1 88 "$SHA"
rm -f "$A23_ADOPTED"
t23 "a missing allowlist" 6 --repo acme/widget --trust-reviewed W1 88 "$SHA"
printf '[{"nwo":"%s","merge_allowed":true}]\n' "$A23_ORIGIN" > "$A23_ADOPTED"
t23 "the harness repo itself" 6 --repo "$A23_ORIGIN" --trust-reviewed W1 88 "$SHA"
printf '[{"nwo":"acme/widget","merge_allowed":true}]\n' > "$A23_ADOPTED"
A23_BASE=dev t23 "a PR not based on the default branch" 7 --repo acme/widget --trust-reviewed W1 88 "$SHA"
# only acme/widget's own bucket counts, and its record must name acme/widget
averdict "$VSCOPE" W2 ""
t23 "a judge GO in the harness bucket" 5 --repo acme/widget --trust-reviewed W2 88 "$SHA"
averdict u/acme--widget W3 ""
t23 "a record naming no repo" 5 --repo acme/widget --trust-reviewed W3 88 "$SHA"
averdict u/acme--widget W4 "repo: other/widget"
t23 "a record naming another repo" 5 --repo acme/widget --trust-reviewed W4 88 "$SHA"
averdict u/widget W5 "repo: acme/widget"
t23 "a record in a bucket another owner's widget shares" 5 --repo acme/widget --trust-reviewed W5 88 "$SHA"
# the harness path refuses a record written for an adopted repo
averdict "$VSCOPE" W5 "repo: acme/$VBUCKET"
rc=0; go_trust_verdict "$ROOT23" W5 "$SHA" "$HERE/../../.." 88 >/dev/null || rc=$?
check    "7392: the harness lookup refuses an adopted repo's record" "$rc" "2"

# --- 23b. an adapter repo's trust GO reads the adapter's own bucket ---
# write-verdict.sh --repo writes an adapter's verdict under u/<owner>--<name> with a
# repo: header; go.sh must read that bucket for an adapter too, and a verdict in
# the harness bucket must not count.
printf '[{"nwo":"acme/gadget","merge_allowed":true,"himmel_branch":"main"}]\n' > "$A23_ADAPTERS"
averdict u/acme--gadget G1 "repo: acme/gadget"
rc=0; out="$(a23 --repo acme/gadget --trust-reviewed G1 88 "$SHA" 2>&1)" || rc=$?
check    "7885: adapter trust GO from the adapter's bucket -> exit 0" "$rc" "0"
rc=0; out=$(go_trust_gate 88 "$SHA" "$ROOT23" acme/gadget) || rc=$?
check    "7885: go_trust_gate accepts the adapter GO for acme/gadget" "$rc:$out" "0:G1"
rm -f "$GO23"
averdict "$VSCOPE" G2 "repo: acme/gadget"
t23 "an adapter verdict in the harness bucket" 5 --repo acme/gadget --trust-reviewed G2 88 "$SHA"
averdict u/acme--gadget G3 ""
t23 "an adapter record naming no repo" 5 --repo acme/gadget --trust-reviewed G3 88 "$SHA"

# --- 27. a trust GO never rests on a no-op verdict for a delta that needs a judge ---
# write-verdict.sh --delta-noop signs `delta: no-op` / `delta-judged: <sha>` into a
# record; go.sh --trust-reviewed re-runs delta-class.sh over judged..head and
# refuses (exit 10) unless it prints none. The no-op records here are signed by
# the verdict() helper, i.e. as a writer that skipped the classifier would sign them.
ROOT27="$tmp/root27"; mkdir -p "$ROOT27"
fx27="$tmp/fx27"
git init -q "$fx27"
fx27_git() { git -C "$fx27" -c user.email=t@t -c user.name=t -c commit.gpgsign=false "$@"; }
mkdir -p "$fx27/scripts/ci" "$fx27/src" "$fx27/docs"
printf '^scripts/ci/\n' > "$fx27/scripts/ci/ci-trust-paths.txt"
printf 'x\n' > "$fx27/scripts/ci/x.sh"
seq 1 10 > "$fx27/src/a.txt"
printf 'c\n' > "$fx27/docs/c.md"
fx27_git add -A && fx27_git commit -qm base
J27=$(fx27_git rev-parse HEAD)
fx27_git update-ref refs/remotes/origin/main "$J27"
ready_pass_origin "$fx27" "$J27"
fx27_git checkout -q -b docs27 "$J27"
printf 'more\n' >> "$fx27/docs/c.md"; fx27_git add -A && fx27_git commit -qm docs
N27d=$(fx27_git rev-parse HEAD)
fx27_git checkout -q -b trust27 "$J27"
printf 'y\n' >> "$fx27/scripts/ci/x.sh"; fx27_git add -A && fx27_git commit -qm trust
N27t=$(fx27_git rev-parse HEAD)
ready_pass_ledger "$fx27" "$N27d" "$N27t"
VPR=91
VEXTRA=$'finding: src/a.txt:3-4\n' verdict "$ROOT27" q27 "**GO** for head \`$J27\`." HIMMEL-1-judge-q27
go27() {  # <head> - go.sh --trust-reviewed q27 for PR 91 from the fixture repo
  ( cd "$fx27" && HIMMEL_REPO="$fx27" READY_STUB_HEAD="$1" HANDOVER_DIR="$ROOT27" bash "$SCRIPT" --trust-reviewed q27 91 "$1" >/dev/null 2>&1 )
}
VEXTRA=$'delta: no-op\ndelta-judged: '"$J27"$'\ndelta-class: none\n' verdict "$ROOT27" q27 "**GO** for head \`$N27t\`." "delta-noop-$N27t"
rc=0; go27 "$N27t" || rc=$?
check "7637: a no-op verdict for a trust-path delta is refused (exit 10)" "$rc" "10"
check "7637: ...and no GO file is written" "$([ -e "$ROOT27/.locks/go/91.$N27t" ] && echo yes || echo no)" "no"
VEXTRA=$'delta: no-op\ndelta-judged: '"$J27"$'\ndelta-class: none\n' verdict "$ROOT27" q27 "**GO** for head \`$N27d\`." "delta-noop-$N27d"
rc=0; go27 "$N27d" || rc=$?
check "7637: a no-op verdict for a none delta is accepted" "$rc" "0"
verdict "$ROOT27" q27 "**GO** for head \`$N27t\`." HIMMEL-1-judge-q27-trust
rc=0; go27 "$N27t" || rc=$?
check "7637: a real judge GO beside the no-op carries the trust delta" "$rc" "0"
rm -f "$ROOT27/.locks/go/91.$N27t" "$ROOT27/$VSCOPE/verdicts/q27/HIMMEL-1-judge-q27-trust.md"
VEXTRA=$'delta: no-op\ndelta-judged: nothex\n' verdict "$ROOT27" q27 "**GO** for head \`$N27t\`." "delta-noop-$N27t"
rc=0; go27 "$N27t" || rc=$?
check "7637: a no-op naming no judged head is refused" "$rc" "10"
# shellcheck disable=SC2016  # the backticks are literal verdict-line text
printf '# VERDICT q27 - forged\n\n## Verdict\n\n**GO** for head `%s`.\n\npr: 91\n' "$N27t" > "$ROOT27/$VSCOPE/verdicts/q27/forged-unsigned.md"
VEXTRA=$'delta: no-op\ndelta-judged: '"$J27"$'\ndelta-class: none\n' verdict "$ROOT27" q27 "**GO** for head \`$N27t\`." "delta-noop-$N27t"
rc=0; go27 "$N27t" || rc=$?
check "7637: an unsigned GO sibling beside a no-op over a trust delta is refused (exit 5)" "$rc" "5"
VPR=

# --- 28. an adopted repo's delta no-op is classified in the adopted bucket -----
# Same fixture repo as section 27, but the real judge GO (head J27) and the no-op
# record (head N27d) sit in acme/widget's own bucket and name acme/widget. The
# classifier must read that bucket too, or it finds no prior verdict and refuses.
a28rec() {  # <name> <head> <extra header lines> - a signed acme/widget GO record for PR 88
  local vf="$ROOT23/u/acme--widget/verdicts/W6/$1.md" vmac
  mkdir -p "$ROOT23/u/acme--widget/verdicts/W6"
  # shellcheck disable=SC2016  # the backticks are the verdict line's literal text
  printf '# VERDICT W6 - judge\n\n## Verdict\n\n**GO** for head `%s`.\n\npr: 88\nrepo: acme/widget\n%smodel: m\neffort: e\n\nreason\n' "$2" "$3" > "$vf"
  # read-sink-ok: test fixture; $vf is a record this helper just wrote under the suite's own temp root
  vmac="$(bash -c '. "$1"; go_verdict_mac "$2" "$3" "$4"' _ "$HERE/../../lib/go-gate.sh" u/acme--widget W6 "$1" < "$vf")" || { echo "FAIL - cannot sign $vf"; fails=$((fails+1)); return 1; }
  printf 'mac: %s\n' "$vmac" >> "$vf"
}
a28rec judge "$J27" ""
a28rec "delta-noop-$N27d" "$N27d" $'delta: no-op\ndelta-judged: '"$J27"$'\ndelta-class: none\n'
rc=0; (cd "$fx27" && A23_HEAD="$N27d" PATH="$A23_BIN:$PATH" HANDOVER_DIR="$ROOT23" bash "$SCRIPT" --repo acme/widget --trust-reviewed W6 88 "$N27d" >/dev/null 2>&1) || rc=$?
check "adopter delta no-op over a none delta is accepted (exit 0)" "$rc" "0"
check "...and its GO file is written" "$([ -e "$ROOT23/.locks/go/88.$N27d" ] && echo yes || echo no)" "yes"

# --- 28b. --repo reads the NO-GO order in the repo's own checkout, not the cwd (9272) ---
# Section 28's run starts in the fork fixture. The chief runs from the himmel
# checkout (here an empty repo that holds none of the fork's commits): go.sh must
# find the fork checkout itself (HIMMEL_FORK_ROOTS lists the dirs to search, default
# the parent of the harness checkout; a checkout whose origin names the repo) or take
# --checkout <dir>, and fail closed (exit 10, no GO) when neither yields a readable one.
him28b="$tmp/him28b"; git init -q "$him28b"
roots28b="$tmp/roots28b"; mkdir -p "$roots28b"
git clone -q "$fx27" "$roots28b/widget-clone"
git -C "$roots28b/widget-clone" remote set-url origin https://github.com/acme/widget.git
git -C "$roots28b/widget-clone" update-ref refs/remotes/origin/main "$J27"
cp "$fx27/.git/cr-critic-scores.jsonl" "$roots28b/widget-clone/.git/cr-critic-scores.jsonl"  # delta-class.sh reads the CR ledger from the checkout's git dir
run28b() {  # <HIMMEL_FORK_ROOTS value> <go.sh args...> - from the himmel checkout, no GO left behind
  local roots=$1; shift
  rm -f "$ROOT23/.locks/go/88.$N27d"
  ( cd "$him28b" && env HIMMEL_FORK_ROOTS="$roots" A23_HEAD="$N27d" PATH="$A23_BIN:$PATH" HANDOVER_DIR="$ROOT23" bash "$SCRIPT" --repo acme/widget --trust-reviewed W6 "$@" 88 "$N27d" >/dev/null 2>&1 )
}
rc=0; run28b "$roots28b" || rc=$?
check "9272: from the himmel checkout the fork checkout is found by its origin (exit 0)" "$rc" "0"
check "9272: ...and its GO file is written" "$([ -e "$ROOT23/.locks/go/88.$N27d" ] && echo yes || echo no)" "yes"
rc=0; run28b "$tmp/no-such-root" || rc=$?
check "9272: no fork checkout found -> exit 10" "$rc" "10"
check "9272: ...and no GO file is written" "$([ -e "$ROOT23/.locks/go/88.$N27d" ] && echo yes || echo no)" "no"
rc=0; run28b "$tmp/no-such-root" --checkout "$fx27" || rc=$?
check "9272: --checkout names the fork checkout (exit 0)" "$rc" "0"
rc=0; run28b "$roots28b" --checkout "$tmp/not-a-checkout" || rc=$?
check "9272: --checkout that is not a git checkout -> exit 10" "$rc" "10"
check "9272: ...and no GO file is written" "$([ -e "$ROOT23/.locks/go/88.$N27d" ] && echo yes || echo no)" "no"
rc=0; ( cd "$him28b" && A23_HEAD="$N27d" PATH="$A23_BIN:$PATH" HANDOVER_DIR="$ROOT23" bash "$SCRIPT" --checkout "$fx27" --trust-reviewed W6 88 "$N27d" >/dev/null 2>&1 ) || rc=$?
check "9272: --checkout without --repo -> exit 2" "$rc" "2"

# --- 29. a judge's NO-GO vetoes a trust GO, from any qid -----------
# P - A - B on one branch, S a sibling of A off P. Judge J ruled GO at A (a
# finding on src/a.txt:3-4); B only touches docs, so delta-class.sh says none.
ROOT29="$tmp/root29"; mkdir -p "$ROOT29"
fx29="$tmp/fx29"
git init -q "$fx29"
fx29_git() { git -C "$fx29" -c user.email=t@t -c user.name=t -c commit.gpgsign=false "$@"; }
mkdir -p "$fx29/scripts/ci" "$fx29/src" "$fx29/docs"
printf '^scripts/ci/\n' > "$fx29/scripts/ci/ci-trust-paths.txt"
seq 1 10 > "$fx29/src/a.txt"
printf 'c\n' > "$fx29/docs/c.md"
fx29_git add -A && fx29_git commit -qm base
P29=$(fx29_git rev-parse HEAD)
fx29_git update-ref refs/remotes/origin/main "$P29"
ready_pass_origin "$fx29" "$P29"
fx29_git checkout -q -b a29 "$P29"
printf 'a\n' >> "$fx29/docs/c.md"; fx29_git add -A && fx29_git commit -qm a
A29=$(fx29_git rev-parse HEAD)
printf 'b\n' >> "$fx29/docs/c.md"; fx29_git add -A && fx29_git commit -qm b
B29=$(fx29_git rev-parse HEAD)
fx29_git checkout -q -b s29 "$P29"
printf 's\n' >> "$fx29/docs/c.md"; fx29_git add -A && fx29_git commit -qm s
S29=$(fx29_git rev-parse HEAD)
C29=0123456789abcdef0123456789abcdef0123cccc
ready_pass_ledger "$fx29" "$A29" "$B29"
VPR=93
go29() {  # <head> - go.sh --trust-reviewed J for PR 93 from the fixture repo; rc and whether a GO file stands
  local r=0
  ( cd "$fx29" && HIMMEL_REPO="$fx29" READY_STUB_HEAD="$1" HANDOVER_DIR="$ROOT29" bash "$SCRIPT" --trust-reviewed J 93 "$1" >/dev/null 2>&1 ) || r=$?
  printf '%s:%s' "$r" "$([ -e "$ROOT29/.locks/go/93.$1" ] && echo go || echo none)"
  rm -f "$ROOT29/.locks/go/93.$1"
}
V29="$ROOT29/$VSCOPE/verdicts"
VEXTRA=$'finding: src/a.txt:3-4\n' verdict "$ROOT29" J "**GO** for head \`$A29\`." HIMMEL-1-judge-J
VEXTRA=$'delta: no-op\ndelta-judged: '"$A29"$'\ndelta-class: none\n' verdict "$ROOT29" J "**GO** for head \`$B29\`." "delta-noop-$B29"
check "8732-b0: the no-op GO at B with no NO-GO anywhere is written" "$(go29 "$B29")" "0:go"
VEXTRA=$'finding: src/a.txt:3-4\n' verdict "$ROOT29" K "**NO-GO** for head \`$A29\`." HIMMEL-1-judge-K
check "8732-a: a no-op GO at B after K's NO-GO at A is refused (exit 10, no GO)" "$(go29 "$B29")" "10:none"
rm -f "$V29/K/HIMMEL-1-judge-K.md"
VEXTRA=$'finding: src/a.txt:3-4\n' verdict "$ROOT29" K "**NO-GO** for head \`$S29\`." HIMMEL-1-judge-K
check "8732-b: a NO-GO at a sibling of A does not veto the no-op GO" "$(go29 "$B29")" "0:go"
chmod 000 "$V29/K/HIMMEL-1-judge-K.md"
if [ -r "$V29/K/HIMMEL-1-judge-K.md" ]; then
  echo "  skip 8732-c: chmod 000 leaves the record readable here"
else
  check "8732-c: an unreadable record (a sibling NO-GO that would not veto) refuses the no-op GO (exit 10)" "$(go29 "$B29")" "10:none"
fi
chmod 600 "$V29/K/HIMMEL-1-judge-K.md"
VEXTRA=$'reason quotes **NO-GO** for head `'"$A29"$'`\n' verdict "$ROOT29" K "**GO** for head \`$S29\`." HIMMEL-1-judge-K
check "8732-g: a NO-GO quoted in a GO record's evidence does not veto" "$(go29 "$B29")" "0:go"
rm -f "$V29/K/HIMMEL-1-judge-K.md"
VEXTRA=$'delta: no-op\ndelta-judged: '"$C29"$'\ndelta-class: none\n' verdict "$ROOT29" J "**GO** for head \`$B29\`." "delta-noop-$B29"
VEXTRA=$'delta: no-op\ndelta-judged: '"$B29"$'\ndelta-class: none\n' verdict "$ROOT29" J "**GO** for head \`$C29\`." "delta-noop-$C29"
check "8732-d: a no-op chain cycle (B on C, C on B) is refused (exit 10)" "$(go29 "$B29")" "10:none"
rm -f "$V29/J/delta-noop-$B29.md" "$V29/J/delta-noop-$C29.md"
verdict "$ROOT29" J "**GO** for head \`$B29\`." HIMMEL-1-judge-J-b
check "8732-e0: a real GO of J at B is written" "$(go29 "$B29")" "0:go"
verdict "$ROOT29" K "**NO-GO** for head \`$B29\`." HIMMEL-1-judge-K
check "8732-e: a real GO of J at B with K's NO-GO at B is refused (exit 10, no GO)" "$(go29 "$B29")" "10:none"
rm -f "$V29/J/HIMMEL-1-judge-J-b.md" "$V29/K/HIMMEL-1-judge-K.md"
VEXTRA=$'delta: no-op\ndelta-judged: '"$A29"$'\ndelta-class: none\n' verdict "$ROOT29" J "**GO** for head \`$B29\`." "delta-noop-$B29"
VEXTRA=$'finding: src/a.txt:3-4\n' verdict "$ROOT29" K "**NO-GO** for head \`$A29\`." HIMMEL-1-judge-K
# shellcheck disable=SC2016  # the backticks are literal verdict-line text
VEXTRA=$'**GO** for head `'"$B29"$'`.\n' verdict "$ROOT29" J "**GO** for head \`$S29\`." HIMMEL-1-judge-J-s
check "8732-h: a J record at another head whose body quotes the GO line for B leaves B a no-op, and K's NO-GO at A vetoes it (exit 10, no GO)" "$(go29 "$B29")" "10:none"
rm -f "$V29/J/HIMMEL-1-judge-J-s.md" "$V29/K/HIMMEL-1-judge-K.md" "$V29/J/delta-noop-$B29.md"
# 9845: at the chain's root the newest verdict wins. K's NO-GO at A older than J's newest real GO at A
# no longer vetoes the no-op GO at B; a newer one, a tie, a NO-GO at a hop below the root still do.
T1_29=2026-11-01T00:00:00Z T2_29=2026-11-02T00:00:00Z T3_29=2026-11-03T00:00:00Z
VEXTRA=$'delta: no-op\ndelta-judged: '"$A29"$'\ndelta-class: none\n' verdict "$ROOT29" J "**GO** for head \`$B29\`." "delta-noop-$B29"
VWRITTEN=$T2_29 verdict "$ROOT29" J "**GO** for head \`$A29\`." HIMMEL-1-judge-J-t2
VWRITTEN=$T1_29 VEXTRA=$'finding: src/a.txt:3-4\n' verdict "$ROOT29" K "**NO-GO** for head \`$A29\`." HIMMEL-1-judge-K
check "9845-a: a NO-GO at the root older than the newest real GO at it no longer vetoes the no-op GO" "$(go29 "$B29")" "0:go"
VWRITTEN=$T3_29 VEXTRA=$'finding: src/a.txt:3-4\n' verdict "$ROOT29" K "**NO-GO** for head \`$A29\`." HIMMEL-1-judge-K
check "9845-b: a NO-GO at the root newer than the real GO still vetoes (exit 10, no GO)" "$(go29 "$B29")" "10:none"
VWRITTEN=$T2_29 VEXTRA=$'finding: src/a.txt:3-4\n' verdict "$ROOT29" K "**NO-GO** for head \`$A29\`." HIMMEL-1-judge-K
check "9845-c: a NO-GO written at the same second as the real GO still vetoes (exit 10, no GO)" "$(go29 "$B29")" "10:none"
VEXTRA=$'finding: src/a.txt:3-4\n' verdict "$ROOT29" K "**NO-GO** for head \`$A29\`." HIMMEL-1-judge-K
check "9845-d: a NO-GO with no written-at stamp still vetoes (exit 10, no GO)" "$(go29 "$B29")" "10:none"
rm -f "$V29/K/HIMMEL-1-judge-K.md" "$V29/J/HIMMEL-1-judge-J-t2.md"
# a bind carries no new judgement: its own (newer) stamp never outranks a NO-GO written after the branch GO it binds
# shellcheck disable=SC2016  # the backticks are literal verdict-line text
printf '# VERDICT J - judge\n\nwriter-session: s\nwritten-at: %s\n\n## Verdict\n\n**GO** for head `%s`.\n\nbranch: fix/x\nmodel: claude-opus-5-5\neffort: high\n\nbody\n' "$T1_29" "$A29" > "$V29/J/branch-go.md"
vsign J "$V29/J/branch-go.md"
# shellcheck disable=SC2016  # the backticks are literal verdict-line text
printf '# VERDICT J - bind-pr93-%s\n\nwriter-session: s\nwritten-at: %s\n\n## Verdict\n\n**GO** for head `%s`.\n\npr: 93\nbranch: fix/x\nmodel: claude-opus-5-5\neffort: high\nbound-from: branch-go.md\n\nbody\n' "$A29" "$T3_29" "$A29" > "$V29/J/bind-pr93-$A29.md"
vsign J "$V29/J/bind-pr93-$A29.md"
VWRITTEN=$T2_29 VEXTRA=$'finding: src/a.txt:3-4\n' verdict "$ROOT29" K "**NO-GO** for head \`$A29\`." HIMMEL-1-judge-K
check "9845-h: a bound record stamped after K's NO-GO does not outrank it (exit 10, no GO)" "$(go29 "$B29")" "10:none"
rm -f "$V29/K/HIMMEL-1-judge-K.md" "$V29/J/branch-go.md" "$V29/J/bind-pr93-$A29.md"
# the root is P: J's newest real GO there is stamped T2, K's NO-GO at the hop A (T1) is not at the root
VEXTRA=$'delta: no-op\ndelta-judged: '"$P29"$'\ndelta-class: none\n' verdict "$ROOT29" J "**GO** for head \`$A29\`." "delta-noop-$A29"
VWRITTEN=$T2_29 verdict "$ROOT29" J "**GO** for head \`$P29\`." HIMMEL-1-judge-J-p
VWRITTEN=$T1_29 VEXTRA=$'finding: src/a.txt:3-4\n' verdict "$ROOT29" K "**NO-GO** for head \`$A29\`." HIMMEL-1-judge-K
VEXTRA=$'delta: no-op\ndelta-judged: '"$A29"$'\ndelta-class: none\n' verdict "$ROOT29" J "**GO** for head \`$B29\`." "delta-noop-$B29"
check "9845-e: a NO-GO at a hop below the root is never outranked by the root's GO (exit 10, no GO)" "$(go29 "$B29")" "10:none"
rm -f "$V29/K/HIMMEL-1-judge-K.md" "$V29/J/HIMMEL-1-judge-J-p.md" "$V29/J/delta-noop-$A29.md" "$V29/J/delta-noop-$B29.md"
# 9845: a branch GO (branch: and no pr:) is no trust for a PR; write-verdict.sh --bind's record beside it
# (pr: 93, same head) is, with no second judge. Both records are shaped as the writer emits them.
mkdir -p "$V29/Q"
go29q() {  # <head> - go.sh --trust-reviewed Q for PR 93, as go29 does for J
  local r=0
  ( cd "$fx29" && HIMMEL_REPO="$fx29" READY_STUB_HEAD="$1" HANDOVER_DIR="$ROOT29" bash "$SCRIPT" --trust-reviewed Q 93 "$1" >/dev/null 2>&1 ) || r=$?
  printf '%s:%s' "$r" "$([ -e "$ROOT29/.locks/go/93.$1" ] && echo go || echo none)"
  rm -f "$ROOT29/.locks/go/93.$1"
}
# shellcheck disable=SC2016  # the backticks are literal verdict-line text
printf '# VERDICT Q - judge\n\nwriter-session: s\nwritten-at: %s\n\n## Verdict\n\n**GO** for head `%s`.\n\nbranch: fix/x\nmodel: claude-opus-5-5\neffort: high\n\nbody\n' "$T1_29" "$A29" > "$V29/Q/judge.md"
vsign Q "$V29/Q/judge.md"
check "9845-f: a branch GO alone (no pr: line) is no trust for PR 93 (exit 5, no GO)" "$(go29q "$A29")" "5:none"
# shellcheck disable=SC2016  # the backticks are literal verdict-line text
printf '# VERDICT Q - bind-pr93-%s\n\nwriter-session: s\nwritten-at: %s\n\n## Verdict\n\n**GO** for head `%s`.\n\npr: 93\nbranch: fix/x\nmodel: claude-opus-5-5\neffort: high\nbound-from: judge.md\n\nbody\n' "$A29" "$T2_29" "$A29" > "$V29/Q/bind-pr93-$A29.md"
vsign Q "$V29/Q/bind-pr93-$A29.md"
check "9845-g: the bound record beside it makes go.sh accept PR 93 at that head with no second judge (exit 0, GO)" "$(go29q "$A29")" "0:go"
rm -f "$V29/Q/judge.md" "$V29/Q/bind-pr93-$A29.md"
# B - T adds a trust path, D removes it: the net A..D delta is none, A..T is trust.
fx29_git checkout -q a29
printf 't\n' > "$fx29/scripts/ci/t.sh"; fx29_git add -A && fx29_git commit -qm t
T29=$(fx29_git rev-parse HEAD)
fx29_git rm -q scripts/ci/t.sh && fx29_git commit -qm d
D29=$(fx29_git rev-parse HEAD)
ready_pass_ledger "$fx29" "$D29"
VEXTRA=$'delta: no-op\ndelta-judged: '"$A29"$'\ndelta-class: none\n' verdict "$ROOT29" J "**GO** for head \`$T29\`." "delta-noop-$T29"
VEXTRA=$'delta: no-op\ndelta-judged: '"$T29"$'\ndelta-class: none\n' verdict "$ROOT29" J "**GO** for head \`$D29\`." "delta-noop-$D29"
check "8732-i: a two-hop no-op chain whose second hop (A to T) is a trust delta is refused (exit 10, no GO)" "$(go29 "$D29")" "10:none"
VPR=

# --- 30. no GO for a PR the merge will refuse (partial-merge remainder, ready-check item 17) ---
# merge-on-green.sh refuses a contract-no merge whose PR body records no remainder (exit 26). go.sh takes
# --contract yes|no and passes ready-check --require-contract, so a keyed PR with no contract named is refused too.
# The READY_STUB_* stubs serve the PR title and body: the default title is unkeyed, the default body lists only `done`.
cd "$READY_REPO" || { echo "FAIL: cd $READY_REPO" >&2; exit 1; }
ROOT30="$tmp/root30"; mkdir -p "$ROOT30"
KEYED30='fix(x): [HIMMEL-1] a partial change'
go30() { # <stub title> <stub body or "-" for the default> <go.sh args...>
    local title="$1" body="$2"; shift 2
    if [ "$body" = "-" ]; then
        READY_STUB_HEAD="$SHA" READY_STUB_TITLE="$title" HANDOVER_DIR="$ROOT30" bash "$SCRIPT" "$@" 2>&1
    else
        READY_STUB_HEAD="$SHA" READY_STUB_TITLE="$title" READY_STUB_BODY="$body" HANDOVER_DIR="$ROOT30" bash "$SCRIPT" "$@" 2>&1
    fi
}
rc=0; out="$(go30 "$KEYED30" - --contract no 77 "$SHA")" || rc=$?
check    "8918 b-go: contract no and no remainder in the body -> exit 4" "$rc" "4"
contains "8918 b-go: names item 17" "$out" "[FAIL] 17."
check    "8918 b-go: nothing written" "$(find "$ROOT30" -type f | wc -l | tr -d ' ')" "0"
rc=0; out="$(go30 "$KEYED30" $'## Ticket coverage\n- ask: done\n\nRemaining: the docs follow\n\nRED then GREEN: the new row failed before the change\n' --contract no 77 "$SHA" 2>/dev/null)" || rc=$?
check    "8918 b2: contract no with a Remaining line -> exit 0" "$rc" "0"
check    "8918 b2: the GO path" "$out" "$ROOT30/.locks/go/77.$SHA"
rm -rf "$ROOT30"; mkdir -p "$ROOT30"
rc=0; out="$(go30 "$KEYED30" - --contract yes 77 "$SHA" 2>/dev/null)" || rc=$?
check    "8918 b3: contract yes with no remainder -> exit 0" "$rc" "0"
rm -rf "$ROOT30"; mkdir -p "$ROOT30"
rc=0; out="$(go30 'fix(x): no ticket key in this title' - --contract no 77 "$SHA" 2>/dev/null)" || rc=$?
check    "8918 b5: an unkeyed title is not a partial merge -> exit 0" "$rc" "0"
rm -rf "$ROOT30"; mkdir -p "$ROOT30"
rc=0; out="$(go30 "$KEYED30" - 77 "$SHA")" || rc=$?
check    "8918 b6: a keyed title and no --contract -> exit 4" "$rc" "4"
contains "8918 b6: says to name the contract" "$out" "--contract yes|no"
check    "8918 b6: nothing written" "$(find "$ROOT30" -type f | wc -l | tr -d ' ')" "0"
rm -rf "$ROOT30"; mkdir -p "$ROOT30"
rc=0; out="$(go30 "$KEYED30" - --fix-main-red 4242 77 "$SHA")" || rc=$?
check    "9613: --fix-main-red on a keyed title and no --contract -> exit 0" "$rc" "0"
check    "9613: the fix-GO is written" "$(find "$ROOT30" -type f -name "fix-main-red.77.$SHA.4242" | wc -l | tr -d ' ')" "1"
rc=0; out="$(go30 "$KEYED30" - --contract maybe 77 "$SHA")" || rc=$?
check    "8918: --contract maybe -> exit 2" "$rc" "2"
rc=0; out="$(go30 "$KEYED30" - --contract yes --contract no 77 "$SHA")" || rc=$?
check    "8918: --contract twice -> exit 2" "$rc" "2"
rc=0; out="$(go30 "$KEYED30" - --contract no --repo o/f --trust-reviewed J1 77 "$SHA")" || rc=$?
check    "8918: --contract with --repo -> exit 2" "$rc" "2"

S31="$tmp/s31"; ROOT31="$tmp/root31"; Q31="$tmp/quota31"
rm -rf "$S31"; mkdir -p "$S31/scripts/handover/chief-kit" "$S31/scripts/cr"
git init -q "$S31"
cp "$SCRIPT" "$S31/scripts/handover/chief-kit/go.sh"
cp -R "$HERE/../../lib" "$S31/scripts/lib"
cp "$HERE/../../cr/anchor-handoff.sh" "$S31/scripts/cr/anchor-handoff.sh"
# shellcheck disable=SC2016  # the stub bodies must expand at run time, not here
{
printf '%s\n' '#!/usr/bin/env bash' 'sleep "${STUB_RC_SLEEP:-0}"' 'echo "stub ready-check output"' 'exit "${STUB_RC_READY:-0}"' > "$S31/scripts/handover/chief-kit/ready-check.sh"
printf '%s\n' '#!/usr/bin/env bash' 'echo "stub cr-disposition output"' 'exit "${STUB_RC_DISP:-0}"' > "$S31/scripts/handover/chief-kit/cr-disposition.sh"
printf '%s\n' '#!/usr/bin/env bash' 'sleep "${STUB_WV_SLEEP:-0}"' 'exit 0' > "$S31/scripts/handover/chief-kit/write-verdict.sh"
}
mkdir -p "$S31/bin"
# shellcheck disable=SC2016  # the stub body must expand at run time, not here
printf '%s\n' '#!/usr/bin/env bash' 'case "$*" in *"/.locks/go/.go."*) [ -z "${STUB_MKTEMP_MARK:-}" ] || echo hit > "$STUB_MKTEMP_MARK"; [ -z "${STUB_MKTEMP_SLEEP:-}" ] || sleep "$STUB_MKTEMP_SLEEP" ;; esac' 'exec /usr/bin/mktemp "$@"' > "$S31/bin/mktemp"
chmod +x "$S31/bin/mktemp"
go31() {
    (cd "$S31" && PATH="$S31/bin:$PATH" HANDOVER_DIR="$ROOT31" HIMMEL_QUOTA_DIR="${Q31_DIR:-$Q31}" bash "$S31/scripts/handover/chief-kit/go.sh" "$@" 2>&1)
}
fresh31() { rm -rf "$ROOT31" "$Q31"; mkdir -p "$ROOT31"; }
gofiles31() { find "$ROOT31/.locks/go" -type f ! -name '.go.*' 2>/dev/null | wc -l | tr -d ' '; }

fresh31
rc=0; out=$(STUB_RC_DISP=2 go31 77 "$SHA") || rc=$?
check    "9479 T3 RED: cr-disposition check rc 2 -> exit 11 (a false finding was exit 9)" "$rc" "11"
check    "9479 T3: cr-disposition rc 2 writes no GO" "$(gofiles31)" "0"

for rc31 in 2 3 96 124 127 137; do
    fresh31
    rc=0; out=$(STUB_RC_READY=$rc31 go31 77 "$SHA") || rc=$?
    check    "9479 I3: ready-check rc $rc31 -> exit 11" "$rc" "11"
    check    "9479 I3: ready-check rc $rc31 writes no GO" "$(gofiles31)" "0"
    contains "9479 I3: ready-check rc $rc31 prints the callee text" "$out" "stub ready-check output"
    check    "9479 I8: ready-check rc $rc31 prints no false verdict" "$(printf '%s\n' "$out" | grep -c 'did not PASS\|no valid disposition')" "0"
    fresh31
    rc=0; out=$(STUB_RC_DISP=$rc31 go31 77 "$SHA") || rc=$?
    check    "9479 I3: cr-disposition rc $rc31 -> exit 11" "$rc" "11"
    check    "9479 I3: cr-disposition rc $rc31 writes no GO" "$(gofiles31)" "0"
    contains "9479 I3: cr-disposition rc $rc31 prints the callee text" "$out" "stub cr-disposition output"
    check    "9479 I8: cr-disposition rc $rc31 prints no false finding" "$(printf '%s\n' "$out" | grep -c 'did not PASS\|no valid disposition')" "0"
done

fresh31
rc=0; out=$(STUB_RC_READY=1 go31 77 "$SHA") || rc=$?
check    "9479: a real ready-check fail (rc 1) is still exit 4" "$rc" "4"
check    "9479: exit 4 writes no GO" "$(gofiles31)" "0"
fresh31
rc=0; out=$(STUB_RC_DISP=1 go31 77 "$SHA") || rc=$?
check    "9479: a real finding (cr-disposition rc 1) is still exit 9" "$rc" "9"
contains "9479: exit 9 keeps the finding text" "$out" "no valid disposition"
check    "9479: exit 9 writes no GO" "$(gofiles31)" "0"
fresh31
rc=0; out=$(go31 77 "$SHA") || rc=$?
check    "9479: both callees rc 0 -> exit 0" "$rc" "0"
check    "9479: both callees rc 0 -> a GO" "$(gofiles31)" "1"

fresh31
rc=0; out=$(STUB_GH_RL=1 go31 77 "$SHA") || rc=$?
check    "9479 I4: a refused repo view -> exit 11" "$rc" "11"
check    "9479 I4: a refused repo view writes no GO" "$(gofiles31)" "0"
contains "9479 I4: a refused repo view names the rate limit" "$out" "QUOTA-PAUSE"
check    "9479 I8: a refused repo view prints no false cause" "$(printf '%s\n' "$out" | grep -c 'cannot resolve this repo')" "0"
check    "9479 I4: a refused repo view leaves one marker keyed <pr>.<head>" "$(find "$Q31/blocked" -type f -name "77.$SHA" 2>/dev/null | wc -l | tr -d ' ')" "1"
contains "9479 I4: the marker names the reason" "$(cat "$Q31/blocked/77.$SHA" 2>/dev/null)" "reason=rate-limit"
fresh31
rc=0; out=$(STUB_GH_REPO_VIEW_FAIL=1 go31 77 "$SHA") || rc=$?
check    "9479: an empty repo view with no refusal stays exit 1" "$rc" "1"
check    "9479 I4: a usage-like empty repo view leaves no marker" "$(find "$Q31/blocked" -type f 2>/dev/null | wc -l | tr -d ' ')" "0"
fresh31
rc=0; out=$(STUB_GH_RL=1 Q31_DIR=/proc/nonexistent/quota go31 77 "$SHA") || rc=$?
check    "9479 I4: an unwritable quota dir leaves the exit unchanged (11)" "$rc" "11"

fresh31
rc=0; out=$(STUB_RC_SLEEP=20 GO_DEADLINE=2 go31 77 "$SHA") || rc=$?
check    "9479: GO_DEADLINE cut before the mv -> exit 11" "$rc" "11"
check    "9479: a cut before the mv writes no GO" "$(gofiles31)" "0"
check    "9479 I4: a cut leaves a marker keyed <pr>.<head>" "$(find "$Q31/blocked" -type f -name "77.$SHA" 2>/dev/null | wc -l | tr -d ' ')" "1"
contains "9479: a cut names GO_DEADLINE" "$out" "GO_DEADLINE"
fresh31
rc=0; out=$(STUB_WV_SLEEP=60 GO_DEADLINE=8 go31 77 "$SHA") || rc=$?
check    "9479: GO_DEADLINE cut after the mv -> exit 0" "$rc" "0"
check    "9479: a cut after the mv leaves the GO standing" "$(gofiles31)" "1"
contains "9479: a cut after the mv still prints the GO path" "$out" "$ROOT31/.locks/go/77.$SHA"
check    "9479: a cut after the mv leaves no marker" "$(find "$Q31/blocked" -type f 2>/dev/null | wc -l | tr -d ' ')" "0"

fresh31
kc_t0=$SECONDS
kc_rc=0
(cd "$S31" && PATH="$S31/bin:$PATH" HANDOVER_DIR="$ROOT31" HIMMEL_QUOTA_DIR="$Q31" STUB_RC_SLEEP=10 GO_DEADLINE=30 timeout -k 5 3 bash "$S31/scripts/handover/chief-kit/go.sh" 77 "$SHA" > /dev/null 2>&1) || kc_rc=$?  # gnu-ok: Linux-only kit
kc_took=$((SECONDS - kc_t0))
sleep 9
check    "9479: an outer timeout ends go.sh (exit 124)" "$kc_rc" "124"
check    "9479: an outer timeout returns within the bound (took ${kc_took}s)" "$([ "$kc_took" -le 8 ] && echo yes || echo no)" "yes"
check    "9479: a cancelled go.sh writes no GO after its callee would have finished" "$(gofiles31)" "0"
check    "9479: a cancelled go.sh leaves no orphan" "$(pgrep -f "$S31/scripts/handover/chief-kit/go.sh" | wc -l | tr -d ' ')" "0"

fresh31
rm -f "$tmp/mk31"
rc=0; out=$(STUB_MKTEMP_MARK="$tmp/mk31" STUB_MKTEMP_SLEEP=20 GO_DEADLINE=8 go31 77 "$SHA") || rc=$?
check    "9479: the run reached the GO write before the cut" "$([ -f "$tmp/mk31" ] && echo yes || echo no)" "yes"
check    "9479: a cut between the sentinel and the mv -> exit 11" "$rc" "11"
check    "9479: a cut between the sentinel and the mv writes no GO" "$(gofiles31)" "0"
fresh31
mkdir -p "$ROOT31/.locks/go"
printf 'pr=77\nhead=%s\nat=2000-01-01T00:00:00Z\n' "$SHA" > "$ROOT31/.locks/go/77.$SHA"
cp "$ROOT31/.locks/go/77.$SHA" "$tmp/old-go31"
rm -f "$tmp/mk31"
rc=0; out=$(STUB_MKTEMP_MARK="$tmp/mk31" STUB_MKTEMP_SLEEP=20 GO_DEADLINE=8 go31 77 "$SHA") || rc=$?
check    "9479: the run reached the GO write before the cut" "$([ -f "$tmp/mk31" ] && echo yes || echo no)" "yes"
check    "9479: an older GO at the same path does not stand in for a cut run (exit 11)" "$rc" "11"
check    "9479: the older GO is left as it was" "$(cmp -s "$ROOT31/.locks/go/77.$SHA" "$tmp/old-go31" && echo same || echo changed)" "same"

victim31="$tmp/victim31"
fresh31
printf 'keep\n' > "$victim31"
rc=0; out=$(_GO_SENTINEL="$victim31" GO_DEADLINE=0 go31 77 "$SHA") || rc=$?
check    "9479: an unarmed run ignores an inherited _GO_SENTINEL (exit 0)" "$rc" "0"
check    "9479: the inherited _GO_SENTINEL file is untouched" "$(cat "$victim31")" "keep"
fresh31
rc=0; out=$(_GO_ARMED=1 _GO_SENTINEL="$victim31" go31 77 "$SHA") || rc=$?
check    "9479: an armed child refuses a sentinel outside go-sentinel.* in TMPDIR (exit 0)" "$rc" "0"
check    "9479: the foreign sentinel file is untouched" "$(cat "$victim31")" "keep"
fresh31
sd31="$tmp/sd31"; mkdir -p "$sd31"
ln -s "$victim31" "$sd31/go-sentinel.link"
rc=0; out=$(_GO_ARMED=1 _GO_SENTINEL="$sd31/go-sentinel.link" TMPDIR="$sd31" go31 77 "$SHA") || rc=$?
check    "9479: an armed child refuses a symlinked sentinel (exit 0)" "$rc" "0"
check    "9479: the symlink target is untouched" "$(cat "$victim31")" "keep"

fresh31
ki_t0=$SECONDS
ki_rc=0
(cd "$S31" && PATH="$S31/bin:$PATH" HANDOVER_DIR="$ROOT31" HIMMEL_QUOTA_DIR="$Q31" STUB_RC_SLEEP=10 GO_DEADLINE=30 timeout -s INT -k 5 3 bash "$S31/scripts/handover/chief-kit/go.sh" 77 "$SHA" > /dev/null 2>&1) || ki_rc=$?  # gnu-ok: Linux-only kit
ki_took=$((SECONDS - ki_t0))
sleep 9
check    "9479: an outer INT ends go.sh (exit 124)" "$ki_rc" "124"
check    "9479: an outer INT returns within the bound (took ${ki_took}s)" "$([ "$ki_took" -le 8 ] && echo yes || echo no)" "yes"
check    "9479: an interrupted go.sh writes no GO after its callee would have finished" "$(gofiles31)" "0"

fresh31
gs_rc=0
gs_out=$(cd "$S31" && PATH="$S31/bin:$PATH" HANDOVER_DIR="$ROOT31" HIMMEL_QUOTA_DIR="$Q31" STUB_WV_SLEEP=20 GO_DEADLINE=60 timeout -k 5 3 bash "$S31/scripts/handover/chief-kit/go.sh" 77 "$SHA" 2>/dev/null) || gs_rc=$?  # gnu-ok: Linux-only kit
check    "9479: a cancel after the GO is written is still what the outer timeout reports (exit 124)" "$gs_rc" "124"
check    "9479: a cancel after the GO is written still prints the GO path" "$gs_out" "$ROOT31/.locks/go/77.$SHA"
check    "9479: a cancel after the GO is written leaves the GO standing" "$(gofiles31)" "1"

fresh31
(cd "$S31" && exec env PATH="$S31/bin:$PATH" HANDOVER_DIR="$ROOT31" HIMMEL_QUOTA_DIR="$Q31" STUB_RC_SLEEP=8 GO_DEADLINE=60 bash "$S31/scripts/handover/chief-kit/go.sh" 77 "$SHA" > /dev/null 2>&1) &
sk_pid=$!
sleep 3
kill -9 "$sk_pid" 2>/dev/null
wait "$sk_pid" 2>/dev/null
sleep 11
check    "9479: a SIGKILLed go.sh leaves no GO written by its orphaned child" "$(gofiles31)" "0"

# --- 32. the caller's cwd never decides the gated repo ---
# The same GO from a directory outside any repo and from another repo's checkout
# (origin other/luna) as from the checkout: ready-check.sh and the NO-GO reads run in
# HIMMEL_REPO. RED control (go.sh before this change): ready-check runs in the
# cwd, finds no ledger there and go.sh writes no GO.
mkdir -p "$NOWHERE32" || { echo "FAIL: nowhere32 setup" >&2; exit 1; }
git init -q "$DECOY32" && git -C "$DECOY32" remote add origin https://github.com/other/luna.git \
  || { echo "FAIL: decoy32 setup" >&2; exit 1; }
for cwd32 in "$NOWHERE32" "$DECOY32" "$READY_REPO"; do
  rm -rf "$ROOT32"; mkdir -p "$ROOT32" || { echo "FAIL: root32 setup" >&2; exit 1; }
  rc=0; out=$(cd "$cwd32" && HANDOVER_DIR="$ROOT32" CHIEF_SESSION_NAME=chief-x bash "$SCRIPT" 77 "$SHA" 2>&1) || rc=$?
  check "cwd ${cwd32##*/}: go.sh exits 0, as from the checkout" "$rc" "0"
  check "cwd ${cwd32##*/}: the GO is written" "$(test -f "$ROOT32/.locks/go/77.$SHA" && echo yes)" "yes"
done

echo "---"
if [ "$fails" -eq 0 ]; then
  echo "PASS - test-go.sh"
  exit 0
else
  echo "FAIL - test-go.sh ($fails failure(s))"
  exit 1
fi
