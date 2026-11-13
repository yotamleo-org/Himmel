#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../lib/fixture-tempdir.sh
# shellcheck disable=SC1091
. "$HERE/../lib/fixture-tempdir.sh"
tmp="$(fixture_mktemp_dir)" || exit 1
trap 'rm -rf "$tmp"' EXIT
unset CR_PROFILE CRITIC_PANEL_TIERS CRITIC_LEDGER_APPEND CR_LEDGER CRITIC_FIRST_PASS CRITICS_JSON \
    CR_TRIVIALITY_OVERRIDE CR_BASE_BRANCH HIMMEL_SESSION_LANE 2>/dev/null || true
fails=0
pass() { printf 'ok - %s\n' "$1"; }
fail() { printf 'FAIL - %s\n' "$1" >&2; fails=$((fails + 1)); }
eq() { if [ "$1" = "$2" ]; then pass "$3"; else fail "$3 (got '$1', want '$2')"; fi; }
has() { case "$1" in *"$2"*) pass "$3" ;; *) fail "$3 (missing '$2'; got: $1)" ;; esac; }
lacks() { case "$1" in *"$2"*) fail "$3 (unexpected '$2'; got: $1)" ;; *) pass "$3" ;; esac; }

A="$tmp/anchor"
mkdir -p "$A/scripts"
for d in cr lib guardrails ledger; do cp -R "$HERE/../$d" "$A/scripts/$d"; done
rm -f "$A/scripts/lib/gh-read.sh"
mv "$A/scripts/cr/critic-panel.sh" "$A/scripts/cr/critic-panel.real.sh"
cat > "$A/scripts/cr/critic-panel.sh" <<'WRAP'
#!/usr/bin/env bash
here="$(cd "$(dirname "$0")" && pwd)"
case " $* " in *" refs/himmel/outside/0..0 "*) exec bash "$here/critic-panel.real.sh" "$@" ;; esac
case "${PANEL_FORCE:-}" in
    7) cat >/dev/null; echo "critic-panel.sh: REFUSING (forced abort of the fixture)" >&2; exit 7 ;;
    record7)
        cat >/dev/null
        printf '{"kind":"avail","branch":"%s","head":"%s","model":"stub-model","status":"ok"}\n' \
            "$PANEL_ROW_BRANCH" "$PANEL_ROW_HEAD" >> "$PANEL_ROW_LEDGER"
        echo "critic-panel.sh: REFUSING (forced abort after a recorded row)" >&2; exit 7 ;;
esac
exec bash "$here/critic-panel.real.sh" "$@"
WRAP
chmod +x "$A/scripts/cr/critic-panel.sh"

CRIT="$tmp/stub-critic.sh"
cat > "$CRIT" <<'EOS'
#!/usr/bin/env bash
if [ -n "${PIN_DIFF_DUMP:-}" ]; then cat > "$PIN_DIFF_DUMP"; else cat > /dev/null; fi
printf '# pin First-Pass Review\n\n## Critical Issues (0 found)\n\n## Important Issues (0 found)\n\n## Suggestions (0 found)\n'
EOS
chmod +x "$CRIT"
printf '{"panel":[{"slug":"pin","model":"pin-model","provider":"nvidia","tier":"free"}]}\n' > "$tmp/critics.json"

mkdir -p "$tmp/bin"
cat > "$tmp/bin/gh" <<'STUB'
#!/usr/bin/env bash
if [ "${1:-}" = pr ] && [ "${2:-}" = view ]; then
    printf '{"author":{"login":"Goomal","id":"U_goomal"},"headRefName":"feat/outside-thing","headRefOid":"%s","baseRefName":"main","state":"OPEN"}' "$STUB_OID" \
        | { _q=""; for _a in "$@"; do [ "${_prev:-}" = "--jq" ] && _q="$_a"; _prev="$_a"; done; if [ -n "$_q" ]; then jq -r "$_q"; else cat; fi; }
    exit 0
fi
printf 'unexpected gh invocation\n' >&2
exit 1
STUB
chmod +x "$tmp/bin/gh"

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
    git commit -q -am pr-change
    git push -q origin HEAD:refs/pull/7/head
    git checkout -q main
    echo ahead > ahead.txt
    git add ahead.txt
    git commit -q -m main-moves-on
    git push -q origin main
) || { echo "FAIL: fixture setup" >&2; exit 1; }
MB="$(git -C "$W" rev-parse prside~1)"
H="$(git -C "$W" rev-parse prside)"
TIP="$(git -C "$W" rev-parse main)"
git clone -q "$O" "$P"
git -C "$P" config user.email t@t.test
git -C "$P" config user.name tester
git -C "$P" config commit.gpgsign false
git -C "$P" fetch -q origin "+refs/pull/7/head:refs/himmel/outside/7"
eq "$(git -C "$P" rev-parse origin/main)" "$TIP" "fixture: origin/main is one commit ahead of the PR's merge base"
eq "$(git -C "$P" merge-base origin/main refs/himmel/outside/7)" "$MB" "fixture: the PR's merge base is the older commit"

HOMEDIR="$tmp/home"; mkdir -p "$HOMEDIR/.himmel"
printf '[{"login":"Goomal","id":"U_goomal"}]\n' > "$HOMEDIR/.himmel/outside-contributors.json"
GCD="$P/.git"
ROUNDS="$GCD/cr-review-rounds"
LEDGER="$GCD/cr-critic-scores.jsonl"
reset() { rm -rf "$ROUNDS" "$LEDGER" "$tmp/diff-dump"; }
preflight() {
    (cd "$P" && CR_LEDGER="$LEDGER" bash "$A/scripts/cr/ledger-append.sh" preflight --branch feat/outside-thing --head "$H" --duration-secs 1 >/dev/null) \
        || fail "fixture: could not record the preflight row"
}
pfp() {
    out="$(cd "$P" && HIMMEL_REPO="$A" HOME="$HOMEDIR" PATH="$tmp/bin:$PATH" STUB_OID="$H" CR_PROFILE=free \
        CRITICS_JSON="$tmp/critics.json" CRITIC_FIRST_PASS="$CRIT" PIN_DIFF_DUMP="$tmp/diff-dump" \
        PANEL_ROW_BRANCH=feat/outside-thing PANEL_ROW_HEAD="$H" PANEL_ROW_LEDGER="$LEDGER" \
        bash "$A/scripts/cr/panel-first-pass.sh" --pr 7 --head "$H" --branch feat/outside-thing 2>"$tmp/err")"; rc=$?
    err="$(cat "$tmp/err")"
}
round_of() { cat "$ROUNDS/outside-7.round" 2>/dev/null || echo none; }
rr() {
    rerr="$(cd "$P" && HIMMEL_REPO="$A" HOME="$HOMEDIR" PATH="$tmp/bin:$PATH" STUB_OID="$H" CR_LEDGER="$LEDGER" \
        bash "$A/scripts/cr/review-round.sh" "$@" 2>&1 >"$tmp/rr-out")"; rrc=$?
    rout="$(cat "$tmp/rr-out")"
}

reset; preflight
pfp
eq "$rc" "0" "a: panel-first-pass --pr over a PR cut before origin/main's tip exits 0, not 7"
lacks "$err" "the base branch moved" "a: no moved-base refusal"
has "$out" "captured diff base: main ($MB)" "a: the diff base is the PR's merge base"
eq "$(cat "$tmp/diff-dump" 2>/dev/null)" "$(git -C "$P" diff "$MB...$H")" "a: the critic read the diff merge-base...head"
eq "$(round_of)" "1" "a: a reviewed run spends round 1"

reset
PIN_ERR="$(cd "$P" && CRITICS_JSON="$tmp/critics.json" CRITIC_FIRST_PASS="$CRIT" CR_LEDGER="$LEDGER" CRITIC_LEDGER_APPEND="$A/scripts/cr/ledger-append.sh" \
    bash -c 'git diff "$1...$2" | bash "$3" --head "$2" --branch feat/outside-thing --pin-ref refs/himmel/outside/7 --base main --base-sha "$4"' _ "$MB" "$H" "$A/scripts/cr/critic-panel.real.sh" "$TIP" 2>&1 >/dev/null)"; pin_rc=$?
eq "$pin_rc" "7" "a: a --pin-ref run pinned to a base that is not the merge base is refused (exit 7)"
has "$PIN_ERR" "the base branch moved" "a: and the refusal is the moved-base one"

BR="$tmp/branch-route"
git clone -q "$O" "$BR"
git -C "$BR" config user.email t@t.test
git -C "$BR" config user.name tester
git -C "$BR" config commit.gpgsign false
git -C "$BR" checkout -q -b feature "$H"
BR_ERR="$(cd "$BR" && CRITICS_JSON="$tmp/critics.json" CRITIC_FIRST_PASS="$CRIT" CR_LEDGER="$tmp/br-ledger.jsonl" CRITIC_LEDGER_APPEND="$A/scripts/cr/ledger-append.sh" \
    bash -c 'git diff "$1...HEAD" | bash "$2" --head "$3" --branch feature --base main --base-sha "$1"' _ "$MB" "$A/scripts/cr/critic-panel.real.sh" "$H" 2>&1 >/dev/null)"; br_rc=$?
eq "$br_rc" "7" "b: a branch-route run whose base moved past the captured sha is still refused (exit 7)"
has "$BR_ERR" "the base branch moved since the caller captured its inputs" "b: with the moved-base refusal"
has "$BR_ERR" "$MB" "b: naming the captured base"
has "$BR_ERR" "$TIP" "b: and the live base"
eq "$(test -s "$tmp/br-ledger.jsonl" && echo rows || echo none)" "none" "b: nothing stamped on the refused run"

reset; preflight
PANEL_FORCE=7 pfp
eq "$rc" "7" "c: a --pr run whose panel aborts exits 7"
has "$err" "the aborted round was given back" "c: and says the round was given back"
eq "$(round_of)" "0" "c: the aborted round leaves the round count unchanged (0)"

reset; preflight
PANEL_FORCE=7 pfp
PANEL_FORCE='' pfp
eq "$rc" "0" "c: the retry after a given-back abort reviews as round 1"
eq "$(round_of)" "1" "c: and the count is 1, not 2"

reset; preflight
PANEL_FORCE=record7 pfp
eq "$rc" "7" "c: a --pr run that recorded a row then aborts exits 7"
eq "$(round_of)" "1" "c: a round that recorded a review is not refunded"
has "$err" "NOT given back" "c: and says so"

reset
rr abort --pr 7 --head "$H"
eq "$rrc" "1" "abort --pr on a round that was never started refuses (exit 1)"
has "$rerr" "nothing to give back" "abort --pr never started: says nothing to give back"
eq "$(round_of)" "none" "abort --pr never started: writes no state"

rr abort --branch outside-7 --head "$H"
eq "$rrc" "2" "abort --branch outside-7 is still refused by the current-branch guard"
has "$rerr" "is not the branch checked out" "abort --branch outside-7: the guard's reason"

rr abort --pr 7 --head "$H" --branch feat/outside-thing
eq "$rrc" "2" "abort --pr takes no --branch (a caller-named branch cannot steer the reviewed-row check)"

reset; preflight
rr start --pr 7 --head "$H"
eq "$rrc" "0" "start --pr still starts round 1"
eq "$rout" "1" "start --pr still prints the round"
rr abort --pr 7 --head "$MB"
eq "$rrc" "1" "abort --pr at a head that is not the started one refuses"
eq "$(round_of)" "1" "abort --pr at the wrong head leaves the count"
rr abort --pr 7 --head "$H"
eq "$rrc" "0" "abort --pr at the started head gives the round back"
eq "$rout" "0 none" "abort --pr prints the round and the head left"
eq "$(round_of)" "0" "abort --pr: the count is 0"
eq "$(test -e "$ROUNDS/outside-7.head" && echo kept || echo removed)" "removed" "abort --pr: the recorded head is removed"

reset; preflight
rr start --pr 7 --head "$H"
printf '{"kind":"avail","branch":"feat/outside-thing","head":"%s","model":"stub-model","status":"ok"}\n' "$H" >> "$LEDGER"
rr abort --pr 7 --head "$H"
eq "$rrc" "8" "abort --pr over a head with a panel row refuses (exit 8)"
eq "$(round_of)" "1" "abort --pr over a reviewed head keeps the count"

reset; preflight
rr start --pr 7 --head "$H"
printf '{"kind":"avail","branch":"some/other-name","head":"%s","model":"stub-model","status":"ok"}\n' "$H" >> "$LEDGER"
rr abort --pr 7 --head "$H"
eq "$rrc" "8" "abort --pr over a head with a panel row under another branch name refuses (exit 8)"
eq "$(round_of)" "1" "abort --pr: a row under another branch name keeps the count"

reset; preflight
rr start --pr 7 --head "$H"
rm -f "$ROUNDS/outside-7.delta.run"
rr abort --pr 7 --head "$H"
eq "$rrc" "8" "abort --pr with no start caller recorded refuses (exit 8)"
has "$rerr" "no start caller is recorded" "abort --pr: says no caller is recorded"
eq "$(round_of)" "1" "abort --pr with no caller recorded keeps the count"

reset; preflight
HOME="$HOMEDIR" PATH="$tmp/bin:$PATH" STUB_OID="$H" HIMMEL_REPO="$A" CR_LEDGER="$LEDGER" \
    bash -c 'cd "$3" && bash "$1" start --pr 7 --head "$2" >/dev/null; sleep 60' _ "$A/scripts/cr/review-round.sh" "$H" "$P" &
holder=$!
n=0
while [ ! -s "$ROUNDS/outside-7.delta.run" ] && [ "$n" -lt 100 ]; do sleep 0.1; n=$((n + 1)); done
eq "$(cat "$ROUNDS/outside-7.delta.run" 2>/dev/null)" "$holder" "start --pr records its caller pid"
rr abort --pr 7 --head "$H"
eq "$rrc" "8" "abort --pr while the start caller is alive refuses (exit 8)"
has "$rerr" "still running" "abort --pr while the caller is alive: says it is still running"
eq "$(round_of)" "1" "abort --pr while the caller is alive keeps the count"
rr start --pr 7 --head "$H"
eq "$rout" "1" "a second start --pr at the same head reuses the round"
rr abort --pr 7 --head "$H"
eq "$rrc" "8" "abort --pr from a second run cannot refund the first run's round while it is in flight"
eq "$(round_of)" "1" "abort --pr from a second run keeps the count"
kill "$holder" 2>/dev/null
wait "$holder" 2>/dev/null
rr abort --pr 7 --head "$H"
eq "$rrc" "0" "abort --pr gives the round back once the start caller has ended"
eq "$(round_of)" "0" "abort --pr after the caller ended: the count is 0"

hold_start() {
    HOME="$HOMEDIR" PATH="$tmp/bin:$PATH" STUB_OID="$H" HIMMEL_REPO="$A" CR_LEDGER="$LEDGER" \
        bash -c 'cd "$3" && bash "$1" start --pr 7 --head "$2" >/dev/null; sleep 60' _ "$A/scripts/cr/review-round.sh" "$H" "$P" &
    held=$!
}
recorded() { grep -qx "$1" "$ROUNDS/outside-7.delta.run" 2>/dev/null; }
wait_for() { local n=0; while ! "$@" && [ "$n" -lt 100 ]; do sleep 0.1; n=$((n + 1)); done; }

reset; preflight
rr start --pr 7 --head "$H"
hold_start; holderB=$held
wait_for recorded "$holderB"
if recorded "$holderB"; then pass "a same-head reuse start records its caller too"; else fail "a same-head reuse start records its caller too"; fi
rr abort --pr 7 --head "$H"
eq "$rrc" "8" "abort --pr refuses while a reuse run is in flight after the first caller ended (exit 8)"
has "$rerr" "still running" "abort --pr: names the live reuse caller"
eq "$(round_of)" "1" "abort --pr keeps the round while a reuse run is in flight"
kill "$holderB" 2>/dev/null
wait "$holderB" 2>/dev/null
rr abort --pr 7 --head "$H"
eq "$rrc" "0" "abort --pr gives the round back once every recorded caller has ended"

reset; preflight
GO="$tmp/go-abort"; ARC="$tmp/abort-rc"; rm -f "$GO" "$ARC"
HOME="$HOMEDIR" PATH="$tmp/bin:$PATH" STUB_OID="$H" HIMMEL_REPO="$A" CR_LEDGER="$LEDGER" \
    bash -c 'cd "$3" && bash "$1" start --pr 7 --head "$2" >/dev/null; until [ -e "$4" ]; do sleep 0.1; done; bash "$1" abort --pr 7 --head "$2" >/dev/null 2>&1; echo $? > "$5"; sleep 60' _ "$A/scripts/cr/review-round.sh" "$H" "$P" "$GO" "$ARC" &
holderA=$!
wait_for recorded "$holderA"
hold_start; holderB=$held
wait_for recorded "$holderB"
touch "$GO"
wait_for test -s "$ARC"
eq "$(cat "$ARC" 2>/dev/null)" "8" "the first caller's own early give_back is refused while a reuse run is in flight (exit 8)"
eq "$(round_of)" "1" "the first caller's early give_back keeps the round while a reuse run is in flight"
kill "$holderA" "$holderB" 2>/dev/null
wait "$holderA" "$holderB" 2>/dev/null

if [ "$fails" -gt 0 ]; then
    printf 'FAIL test-panel-first-pass-pr-base (%s failures)\n' "$fails" >&2
    exit 1
fi
printf 'PASS test-panel-first-pass-pr-base\n'
