#!/usr/bin/env bash
# scripts/cr/test-pr-check-outside.sh - suite for the no-checkout route of pr-check-outside.sh
# (--pr <n> --head <40hex>) and the --pr boundary of the one-argument classifier.
# Fixtures are synthetic: a bare "origin" whose refs/pull/7/head holds a tree that plants a canary in
# every file shape a checkout could run (a script, a test, a filter driver, a submodule file, a hook);
# a copy of the scripts under a temp anchor; a temp HOME; a gh stub on PATH. Nothing from the PR is
# executed, and neither ~/.himmel/outside-contributors.json nor ~/.himmel/outside-pr-approvals.jsonl
# is read or written. Bash 3.2-safe; no network.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../lib/fixture-tempdir.sh
# shellcheck disable=SC1091
. "$HERE/../lib/fixture-tempdir.sh"
tmp="$(fixture_mktemp_dir)" || exit 1
trap 'rm -rf "$tmp"' EXIT
fails=0
pass() { printf 'ok - %s\n' "$1"; }
fail() { printf 'FAIL - %s\n' "$1" >&2; fails=$((fails + 1)); }
eq() { if [ "$1" = "$2" ]; then pass "$3"; else fail "$3 (got '$1', want '$2')"; fi; }
has() { case "$1" in *"$2"*) pass "$3" ;; *) fail "$3 (missing '$2'; got: $1)" ;; esac; }
lacks() { case "$1" in *"$2"*) fail "$3 (unexpected '$2'; got: $1)" ;; *) pass "$3" ;; esac; }

# --- the anchor tree: copies of the scripts the route runs ---------------------------------------
A="$tmp/anchor"
mkdir -p "$A/scripts/cr/perspectives" "$A/scripts/lib" "$A/scripts/guardrails" "$A/scripts/handover/chief-kit"
for f in pr-check-outside.sh review-round.sh anchor-handoff.sh base-resolver.sh ledger-append.sh ledger-amend-auth.js \
         known-findings.sh known-findings.json critic-pre-existing-tag.py panel-first-pass.sh; do
    cp "$HERE/$f" "$A/scripts/cr/$f"
done
for f in chokepoint-seam-guard.sh load-dotenv.sh shared-branch-lock.sh go-gate.sh outside-contributors.sh timeout-bin.sh git-clean.sh; do
    cp "$HERE/../lib/$f" "$A/scripts/lib/$f"
done
cp "$HERE/../guardrails/lib.sh" "$A/scripts/guardrails/lib.sh"
printf '# fixture outside-security perspective\n' > "$A/scripts/cr/perspectives/outside-security.md"
psha="$(sha256sum < "$A/scripts/cr/perspectives/outside-security.md" | cut -d' ' -f1)"
# ready-check.sh --outside is the predicate's one owner; here a stub answers yes or no.
cat > "$A/scripts/handover/chief-kit/ready-check.sh" <<'STUB'
#!/usr/bin/env bash
touch "$(dirname "$0")/ran"
[ "${1:-}" = "--outside" ] || exit 2
[ "${RC_FAIL:-0}" = 0 ] || exit 2
printf 'outside-pr: %s\n' "${RC_ANSWER:-yes}"
STUB
# A panel stub that reads the diff from stdin and accepts --pin-ref) like the real one will.
cat > "$A/scripts/cr/critic-panel.sh" <<'STUB'
#!/usr/bin/env bash
# accepts: --pin-ref) pins the review to a ref instead of the live checkout
case " $* " in *" refs/himmel/outside/0..0 "*) echo "critic-panel: REFUSING --pin-ref" >&2; exit 7 ;; esac
case " $* " in *" --head $STUB_OID --branch feat/outside-thing --pin-ref refs/himmel/outside/7 "*) ;; *) echo "critic-panel stub: unexpected args: $*" >&2; exit 9 ;; esac
cat > "${STDIN_LOG:-/dev/null}"
exit 0
STUB
chmod +x "$A/scripts/handover/chief-kit/ready-check.sh" "$A/scripts/cr/critic-panel.sh"

# --- the gh stub: one PR, served as real JSON ------------------------------------------------------
mkdir -p "$tmp/bin"
cat > "$tmp/bin/gh" <<'STUB'
#!/usr/bin/env bash
if [ "${1:-}" = pr ] && [ "${2:-}" = view ]; then
    printf '{"author":{"login":"%s","id":"%s"},"headRefName":"%s","headRefOid":"%s","baseRefName":"%s","state":"%s"}' \
        "${STUB_LOGIN:-Goomal}" "${STUB_ID:-U_goomal}" "${STUB_BRANCH:-feat/outside-thing}" "$STUB_OID" "${STUB_BASE-main}" "${STUB_STATE:-OPEN}" | { _q=""; for _a in "$@"; do [ "${_prev:-}" = "--jq" ] && _q="$_a"; _prev="$_a"; done; if [ -n "$_q" ]; then jq -r "$_q"; else cat; fi; }
    exit 0
fi
printf 'unexpected gh invocation\n' >&2
exit 1
STUB
chmod +x "$tmp/bin/gh"

# --- origin with the PR, and the "primary" checkout the route runs in ---------------------------------
CANARY="$tmp/canary"
O="$tmp/origin.git"; W="$tmp/work"; P="$tmp/primary"
git init -q --bare -b main "$O"
mkdir -p "$W"
(
    fixture_enter_git_init_dir "$W" || exit 1
    git -c init.defaultBranch=main init -q
    git config user.email t@t.test
    git config user.name tester
    git config commit.gpgsign false
    echo base > f.txt
    git add f.txt
    git commit -q -m base
    git remote add origin "$O"
    git push -q origin main
    git checkout -q -b prside
    echo change >> f.txt
    mkdir -p scripts/cr .githooks
    printf 'touch "%s"\n' "$CANARY" | tee scripts/cr/pr-check-context.sh test-evil.sh .githooks/pre-commit > /dev/null
    printf '*.txt filter=evil\n' > .gitattributes
    printf '[submodule "x"]\n\tpath = x\n\turl = https://example.invalid/x.git\n' > .gitmodules
    git add -A
    git commit -q -m pr-one
    git push -q origin HEAD:refs/pull/7/head
) || { echo "FAIL: fixture setup" >&2; exit 1; }
H1="$(git -C "$W" rev-parse HEAD)"
(
    cd "$W" || exit 1
    echo more >> f.txt
    git commit -q -am pr-two
) || { echo "FAIL: fixture second head" >&2; exit 1; }
H2="$(git -C "$W" rev-parse HEAD)"
git clone -q "$O" "$P"
git -C "$P" config user.email t@t.test
git -C "$P" config user.name tester
git -C "$P" config commit.gpgsign false

HOMEDIR="$tmp/home"; mkdir -p "$HOMEDIR/.himmel"
LIST="$HOMEDIR/.himmel/outside-contributors.json"
APPR="$HOMEDIR/.himmel/outside-pr-approvals.jsonl"
GCD="$P/.git"
ROUTE="$A/scripts/cr/pr-check-outside.sh"
listed() { printf '[{"login":"Goomal","id":"U_goomal"}]\n' > "$LIST"; }
approve() { # pr head stage
    jq -nc --argjson pr "$1" --arg h "$2" --arg s "$3" \
        '{pr:$pr,head:$h,stage:$s,from:1,chat:1,message_id:77,ts:"2026-11-06T10:00:00Z"} | if $s == "" then del(.stage) else . end' >> "$APPR"
}
audit_row() { # head
    local rpt="$tmp/audit-report.md"
    printf 'report\n' > "$rpt"
    jq -nc --arg h "$1" --arg ps "$psha" --arg r "$rpt" --arg rs "$(sha256sum < "$rpt" | cut -d' ' -f1)" \
        '{kind:"security-audit",ts:"2026-11-06T10:00:00Z",pr:7,branch:"feat/outside-thing",head:$h,verdict:"pass",perspective_sha256:$ps,report:$r,report_sha256:$rs,status:"ok"}' >> "$GCD/cr-critic-scores.jsonl"
}
reset() { # clear everything a row may have set
    rm -f "$APPR" "$LIST" "$GCD/cr-critic-scores.jsonl" "$CANARY"
    rm -rf "$GCD/cr-review-rounds"
    git -C "$P" update-ref -d refs/himmel/outside/7 2>/dev/null
    git -C "$P" branch -q -D feat/outside-thing 2>/dev/null
    git -C "$O" update-ref refs/pull/7/head "$H1" 2>/dev/null || git -C "$O" fetch -q "$W" "+$H1:refs/pull/7/head" 2>/dev/null
}
# route <head> [login id]: sets out, err, rc. The head the forge serves is the argument, unless STUB_OID is set.
route() {
    local h="$1"
    out="$(cd "$P" && HIMMEL_REPO="$A" HOME="$HOMEDIR" PATH="$tmp/bin:$PATH" STUB_OID="${STUB_OID:-$h}" STUB_LOGIN="${2:-Goomal}" STUB_ID="${3:-U_goomal}" \
        bash "$ROUTE" --pr 7 --head "$h" 2>"$tmp/err")"; rc=$?
    err="$(cat "$tmp/err")"
}
# Make the origin's PR ref reachable: the work repo holds both heads.
git -C "$O" fetch -q "$W" "+$H1:refs/pull/7/head" "+$H2:refs/himmel-test/h2"
canary_absent() { if [ -e "$CANARY" ]; then fail "$1: a file from the PR ran"; else pass "$1: no file from the PR ran"; fi; }

# --- the classifier's boundary: one numeric argument stays the classifier --------------------------------
bad_rc=0; (cd "$P" && bash "$ROUTE" abc >/dev/null 2>&1) || bad_rc=$?
eq "$bad_rc" "2" "a non-numeric argument other than --pr still refuses"
bad_rc=0; (cd "$P" && bash "$ROUTE" --bogus 7 >/dev/null 2>&1) || bad_rc=$?
eq "$bad_rc" "2" "an unknown flag still refuses"
bad_rc=0; (cd "$P" && bash "$ROUTE" --pr 7 >/dev/null 2>&1) || bad_rc=$?
eq "$bad_rc" "2" "--pr without --head refuses"
bad_rc=0; (cd "$P" && bash "$ROUTE" --pr 7 --head "${H1:0:7}" >/dev/null 2>&1) || bad_rc=$?
eq "$bad_rc" "2" "--pr with a short head refuses"
bad_rc=0; (cd "$P" && bash "$ROUTE" --pr 7 --head "$H1" extra >/dev/null 2>&1) || bad_rc=$?
eq "$bad_rc" "2" "--pr with a trailing argument refuses"

# --- authorization (I7) --------------------------------------------------------------------------------
reset; listed
route "$H1"
eq "$rc" "0" "T2.5 a listed login and id proceeds"
has "$out" "outside-pr: yes 7 $H1 feat/outside-thing base=main authorized=allowlist" "T2.5 the route prints who authorized it"
eq "$(git -C "$P" rev-parse refs/himmel/outside/7)" "$H1" "T2.5 refs/himmel/outside/7 holds the head"
canary_absent "T2.5"

# the route runs only as the anchor's own copy: a branch copy, or no HIMMEL_REPO at all, runs nothing
reset; listed
cp -R "$A" "$tmp/branchcopy"
rm -f "$tmp/branchcopy/scripts/handover/chief-kit/ran"
out="$(cd "$P" && HIMMEL_REPO="$A" HOME="$HOMEDIR" PATH="$tmp/bin:$PATH" STUB_OID="$H1" bash "$tmp/branchcopy/scripts/cr/pr-check-outside.sh" --pr 7 --head "$H1" 2>"$tmp/err")"; rc=$?
err="$(cat "$tmp/err")"
eq "$rc" "2" "a branch copy of the route exits 2"
has "$err" "anchor's copy" "a branch copy: the refusal names the anchor's copy"
if [ -e "$tmp/branchcopy/scripts/handover/chief-kit/ran" ]; then fail "a branch copy ran its own ready-check.sh"; else pass "a branch copy never ran its ready-check.sh"; fi
if git -C "$P" rev-parse --verify --quiet refs/himmel/outside/7 >/dev/null; then fail "a branch copy fetched the PR head"; else pass "a branch copy fetched nothing"; fi
out="$(cd "$P" && HIMMEL_REPO="" HOME="$HOMEDIR" PATH="$tmp/bin:$PATH" STUB_OID="$H1" bash "$ROUTE" --pr 7 --head "$H1" 2>"$tmp/err")"; rc=$?
eq "$rc" "2" "the route with no HIMMEL_REPO exits 2"
if git -C "$P" rev-parse --verify --quiet refs/himmel/outside/7 >/dev/null; then fail "no HIMMEL_REPO: the PR head was fetched"; else pass "no HIMMEL_REPO: nothing fetched"; fi

reset
route "$H1" Stranger U_stranger
eq "$rc" "5" "T2.6 an unlisted author with no approval exits 5"
has "$err" "approve 7 ${H1:0:7}" "T2.6 the refusal names the approve command"
has "$err" "outside-approve-request 7 $H1" "T2.6 the refusal names the request line"
has "$err" "Nothing was fetched or reviewed" "T2.6 the refusal says nothing was fetched"
if git -C "$P" rev-parse --verify --quiet refs/himmel/outside/7 >/dev/null; then fail "T2.6 the ref was fetched anyway"; else pass "T2.6 nothing was fetched"; fi

# --fetch-only: the stage-2 audit reads the diff before any approval exists, so it fetches without asking
# review-round.sh and starts no review round
reset
out="$(cd "$P" && HIMMEL_REPO="$A" HOME="$HOMEDIR" PATH="$tmp/bin:$PATH" STUB_OID="$H1" STUB_LOGIN=Stranger STUB_ID=U_stranger \
    bash "$ROUTE" --pr 7 --head "$H1" --fetch-only 2>"$tmp/err")"; rc=$?
err="$(cat "$tmp/err")"
eq "$rc" "0" "T3.5 --fetch-only fetches for an unlisted author with no approval"
eq "$(git -C "$P" rev-parse refs/himmel/outside/7 2>/dev/null)" "$H1" "T3.5 refs/himmel/outside/7 holds the head"
has "$out" "outside-pr: yes 7 $H1 feat/outside-thing base=main authorized=fetch-only" "T3.5 the line says fetch-only, not an authorizer"
if [ -e "$GCD/cr-review-rounds" ] || [ -e "$GCD/cr-critic-scores.jsonl" ] || [ -e "$APPR" ]; then fail "T3.5 --fetch-only wrote review-round, ledger or approval state"; else pass "T3.5 --fetch-only wrote no review-round state"; fi
canary_absent "T3.5"
reset
route "$H1" Stranger U_stranger
eq "$rc" "5" "T3.5 without the flag the T2.6 refusal is unchanged"
reset; listed
bad_rc=0; (cd "$P" && HIMMEL_REPO="$A" HOME="$HOMEDIR" PATH="$tmp/bin:$PATH" STUB_OID="$H1" STUB_STATE=CLOSED bash "$ROUTE" --pr 7 --head "$H1" --fetch-only >/dev/null 2>&1) || bad_rc=$?
eq "$bad_rc" "2" "T3.5 --fetch-only still refuses a PR that is not OPEN"
bad_rc=0; (cd "$P" && HIMMEL_REPO="$A" bash "$ROUTE" --pr 7 --fetch-only --head "$H1" >/dev/null 2>&1) || bad_rc=$?
eq "$bad_rc" "2" "T3.5 --fetch-only before --head still refuses"

reset; printf '[{"login":"Goomal"}]\n' > "$LIST"
route "$H1"
eq "$rc" "5" "T2.7 a login-only list entry exits 5"

reset
approve 7 "$H1" review; audit_row "$H1"
route "$H1" Stranger U_stranger
eq "$rc" "0" "T2.8 an exact review approval and an audit pass proceeds"
has "$out" "authorized=approval:77" "T2.8 the route prints the approval"

reset
approve 7 "$H1" review; audit_row "$H1"
route "$H2" Stranger U_stranger
eq "$rc" "5" "T2.9 an approval for H1 with the live head H2 exits 5"

reset
approve 8 "$H1" review; audit_row "$H1"
route "$H1" Stranger U_stranger
eq "$rc" "5" "T2.10 an approval for another PR exits 5"

reset; audit_row "$H1"
printf 'not json\n{"pr":"7","head":"%s","stage":"review"}\n{"pr":7,"head":"%s","stage":"review"}\n' "$H1" "${H1:0:7}" > "$APPR"
route "$H1" Stranger U_stranger
eq "$rc" "5" "T2.11 a malformed file, a string pr and a non-40-hex head exit 5"

reset
route "$H1"
eq "$rc" "5" "T2.12 a missing allowlist with no approval exits 5"

reset; listed
mkdir -p "$GCD/cr-review-rounds"; printf '3\n' > "$GCD/cr-review-rounds/outside-7.round"; printf '%s\n' "$H2" > "$GCD/cr-review-rounds/outside-7.head"
route "$H1"
eq "$rc" "5" "T2.13 a listed author past 3 full rounds exits 5"
approve 7 "$H1" review
route "$H1"
eq "$rc" "0" "T2.13 and proceeds once an approval names the head"
has "$out" "authorized=approval:77" "T2.13 the approval authorized it"

reset; listed
RC_ANSWER=no route "$H1"
eq "$rc" "2" "T2.19 ready-check --outside printing no exits 2"
reset; listed
RC_FAIL=1 route "$H1"
eq "$rc" "2" "T2.19 ready-check --outside failing exits 2"

reset
approve 7 "$H1" review
route "$H1" Stranger U_stranger
eq "$rc" "5" "T2.48 an unlisted author with a review approval and no audit row exits 5"
has "$err" "no security-audit pass (stage 2)" "T2.48 the stage-2 line is printed"
has "$err" "outside-security-audit.sh --pr 7 --head $H1" "T2.48 the stage-2 line names the audit command"
lacks "$err" "outside-approve-request" "T2.48 and not the approval request line"

reset; audit_row "$H1"
route "$H1" Stranger U_stranger
eq "$rc" "5" "T2.53 an unlisted author with an audit pass and no approval exits 5"
approve 7 "$H1" ci
route "$H1" Stranger U_stranger
eq "$rc" "5" "T2.53 a stage ci approval exits 5"
rm -f "$APPR"; approve 7 "$H1" ""
route "$H1" Stranger U_stranger
eq "$rc" "5" "T2.53 an approval with no stage exits 5"

# --- state ---------------------------------------------------------------------------------------------
reset; listed
STUB_OID="$H2" route "$H1"
eq "$rc" "2" "T2.14 a forge head that differs from --head exits 2"

reset; listed
git -C "$P" branch -q feat/outside-thing main
route "$H1"
eq "$rc" "2" "T2.15 a local branch named headRefName exits 2"
has "$err" "maintainer takeover" "T2.15 the line names the takeover"

reset; listed
route "$H1"
git -C "$O" update-ref refs/pull/7/head "$H2"
route "$H2"
eq "$rc" "0" "T2.16 a force-pushed head proceeds"
eq "$(git -C "$P" rev-parse refs/himmel/outside/7)" "$H2" "T2.16 the ref follows the new head"
git -C "$O" update-ref refs/pull/7/head "$H1"
route "$H1"
eq "$(git -C "$P" rev-parse refs/himmel/outside/7)" "$H1" "T2.16 and a push back to the old head moves it back (the + refspec)"

reset; listed
STUB_STATE=CLOSED route "$H1"
eq "$rc" "2" "T2.18 a state other than OPEN exits 2"
reset; listed
STUB_STATE=MERGED route "$H1"
eq "$rc" "2" "T2.18 a merged PR exits 2"

# a branch or base name outside the safe alphabet is refused before anything is fetched
# shellcheck disable=SC2016
for bad_name in 'feat/x;touch-evil' 'feat/$(id)' 'feat/a..b'; do
    reset; listed
    STUB_BRANCH="$bad_name" route "$H1"
    eq "$rc" "2" "a hostile branch name '$bad_name' exits 2"
    has "$err" "safe alphabet" "a hostile branch name '$bad_name' is refused for its alphabet"
    if git -C "$P" rev-parse --verify --quiet refs/himmel/outside/7 >/dev/null; then fail "a hostile branch name '$bad_name': the ref was fetched anyway"; else pass "a hostile branch name '$bad_name': nothing was fetched"; fi
done
reset; listed
# shellcheck disable=SC2016
STUB_BASE='ma$in' route "$H1"
eq "$rc" "2" "a hostile base name exits 2"

# a fetch that fails, or lands a ref that is not at the head, is refused and never prints outside-pr: yes
reset; listed
git -C "$O" update-ref -d refs/pull/7/head
route "$H1"
eq "$rc" "2" "a PR ref the origin does not hold exits 2"
lacks "$out" "outside-pr: yes" "a missing PR ref prints no outside-pr: yes line"
reset; listed
git -C "$O" update-ref refs/pull/7/head "$H2"
route "$H1"
eq "$rc" "2" "an origin ref that is not at the forge head exits 2"
lacks "$out" "outside-pr: yes" "a ref not at the head prints no outside-pr: yes line"
has "$err" "could not fetch refs/pull/7/head" "a ref not at the head names the fetch"

reset; listed
GIT_DIR="$tmp/not-a-repo" route "$H1"
eq "$rc" "0" "a caller's poisoned GIT_DIR does not steer the route"
eq "$(git -C "$P" rev-parse refs/himmel/outside/7)" "$H1" "and the ref still lands in the primary repository"

# --- no file from the PR runs, the primary is untouched (I5) -----------------------------------------------
reset; listed
before="$(git -C "$P" status --porcelain; git -C "$P" rev-parse HEAD; git -C "$P" config --list | cksum; find "$P/.git/hooks" | sort | cksum)"
wt_before="$(git -C "$P" worktree list | wc -l | tr -d ' ')"
route "$H1"
eq "$rc" "0" "T2.3 the route over the fixture exits 0"
# the whole route: the panel step on the fetched ref, with a pinned stub panel. The planted canary
# commands trip the known-findings preflight, so its pass is recorded first, as step 2.8 would.
(cd "$P" && CR_LEDGER="$GCD/cr-critic-scores.jsonl" bash "$A/scripts/cr/ledger-append.sh" preflight --branch feat/outside-thing --head "$H1" --duration-secs 1 >/dev/null) \
    || fail "fixture: could not record the preflight row"
(cd "$P" && HOME="$HOMEDIR" PATH="$tmp/bin:$PATH" STUB_OID="$H1" STDIN_LOG="$tmp/stdin-log" \
    bash "$A/scripts/cr/panel-first-pass.sh" --pr 7 --head "$H1" --branch feat/outside-thing >/dev/null 2>"$tmp/pf-err"); pf_rc=$?
eq "$pf_rc" "0" "T2.3 panel-first-pass --pr over the fetched ref exits 0"
has "$(cat "$tmp/stdin-log" 2>/dev/null)" "test-evil.sh" "T2.3 the panel read the diff from stdin"
row="$(grep -F '"kind":"round-scope"' "$GCD/cr-critic-scores.jsonl" 2>/dev/null | tail -n 1)"
has "$row" '"scope":"full"' "T2.2 one round-scope row, scope full"
has "$row" '"source":"pr-diff"' "T2.2 source pr-diff"
has "$row" '"pr":7' "T2.2 pr 7"
has "$row" "\"head\":\"$H1\"" "T2.2 at the PR head"
has "$row" '"branch":"feat/outside-thing"' "T2.2 on headRefName"
after="$(git -C "$P" status --porcelain; git -C "$P" rev-parse HEAD; git -C "$P" config --list | cksum; find "$P/.git/hooks" | sort | cksum)"
eq "$after" "$before" "T2.3 status, HEAD, config and the hooks dir are byte-identical"
eq "$(git -C "$P" worktree list | wc -l | tr -d ' ')" "$wt_before" "T2.3 no new worktree"
canary_absent "T2.3"

# R4: the step 2 to 2.8 runbook names the --pr inputs, so an outside review never reads the station's checkout
RB="$(cat "$HERE/pr-check-ref/20-step2-lanes.md")"
# shellcheck disable=SC2016 # the runbook's literal heading text, backticks included
RBM='**No-checkout route (`--pr`), steps 2 to 2.8.**'
RBP="${RB#*"$RBM"}"
if [ "$RBP" = "$RB" ]; then fail "R4 the runbook has a no-checkout (--pr) paragraph for steps 2 to 2.8"; else
    RBP="${RBP%%$'\n'2.5.*}"
    pass "R4 the runbook has a no-checkout (--pr) paragraph for steps 2 to 2.8"
    has "$RBP" 'refs/himmel/outside/<n>' "R4 the fetched ref is the review head"
    has "$RBP" 'forge base' "R4 the base is the forge base"
    has "$RBP" 'reads nothing from the checkout' "R4 no checkout read"
    has "$RBP" 'lane=full' "R4 step 2 reads the lane as full"
    has "$RBP" 'docs-audit' "R4 step 2.5 is named"
    has "$RBP" '2.7' "R4 step 2.7 is named"
    has "$RBP" 'panel-first-pass.sh --pr' "R4 step 2.8 runs inside panel-first-pass.sh --pr"
    has "$RBP" '--branch <headRefName> --head <40-hex>' "R4 the known-findings call carries the PR's branch and head"
fi

if [ "$fails" -gt 0 ]; then
    printf 'FAIL test-pr-check-outside (%s failures)\n' "$fails" >&2
    exit 1
fi
printf 'PASS test-pr-check-outside\n'
