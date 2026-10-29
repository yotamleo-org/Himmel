#!/usr/bin/env bash
# shellcheck disable=SC2015  # A && B || C intentional in check() and the final assert
# Tests for scripts/cr/cr-thread-recorder.sh — every GitHub call is a gh shim
# (GH_CMD), never live. Fixture PRs carry CodeRabbit review threads; the
# recorder must turn each into one ledger row, once.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="$HERE/cr-thread-recorder.sh"
FIXB="$HERE/../lib/fixtures/cr-body"
tmp="$(mktemp -d -t cr-rec-test.XXXXXX)" || exit 1
trap 'rm -rf "$tmp"' EXIT
FIX="$tmp/fix"; mkdir -p "$FIX"
LEDGER="$tmp/ledger.jsonl"; : > "$LEDGER"
SHIM_LOG="$tmp/shim.log"; : > "$SHIM_LOG"
fails=0
check() { [ "$2" = "$3" ] && echo "ok - $1" || { echo "FAIL - $1: [$2]!=[$3]"; fails=$((fails+1)); }; }

cat > "$tmp/gh" <<'SHIM'
#!/usr/bin/env bash
echo "$* tok=${GH_TOKEN:-ambient}" >> "$SHIM_LOG"
num=""
for a in "$@"; do case "$a" in num=*) num="${a#num=}";; esac; done
case "$1 $2" in
  "repo view") echo "o/r"; exit 0 ;;
  "pr list") cat "$FIX/prs.txt"; exit 0 ;;
esac
case "$1:$2" in
  api:graphql) case " $* " in
      *" after=c1 "*) cat "$FIX/pr-$num-p2.json" ;;
      *" after="*) echo "shim: unexpected cursor in gh $*" >&2; exit 1 ;;
      *) cat "$FIX/pr-$num.json" ;;
    esac; exit 0 ;;
  api:repos/o/r/pulls/*/reviews) n="${2#repos/o/r/pulls/}"; n="${n%/reviews}"
    if [ -f "$FIX/reviews-$n.json" ]; then cat "$FIX/reviews-$n.json"; else echo '[]'; fi; exit 0 ;;
esac
echo "shim: unexpected gh $*" >&2; exit 1
SHIM
chmod +x "$tmp/gh"
cat > "$tmp/fakesleep" <<'SLP'
#!/usr/bin/env bash
echo "slept $1" >> "$SLEEPS"
SLP
chmod +x "$tmp/fakesleep"
SLEEPS="$tmp/sleeps"; : > "$SLEEPS"
unset GH_TOKEN GITHUB_TOKEN CR_RECORDER_GH_TOKENS CR_RECORDER_FLOOR CR_RECORDER_MAX_WAIT CR_RECORDER_LIST_CAP
export GH_CMD="$tmp/gh" FIX SHIM_LOG SLEEPS CR_LEDGER="$LEDGER" CR_RECORDER_REPO="o/r" \
  CR_RECORDER_SLEEP_CMD="$tmp/fakesleep"

# thread <id> <resolved> <created> <sha> <line> <author> <title> — one reviewThreads node
thread() {
  jq -n --arg id "$1" --argjson res "$2" --arg at "$3" --arg sha "$4" --argjson line "$5" \
        --arg who "$6" --arg title "$7" --arg body "${8:-}" \
    '{id:$id,isResolved:$res,isOutdated:false,path:"a.sh",line:$line,originalLine:$line,
      resolvedBy:(if $res then {login:"dev"} else null end),
      comments:{nodes:[{author:{login:$who},createdAt:$at,originalCommit:{oid:$sha},
        body:(if $body != "" then $body else "_⚠️ Potential issue_ | _🟠 Major_\n\n**"+$title+"**\n\nbecause reasons." end)}]}}'
}
# mkpr <num> <branch> <state> <remaining> <resetAt> <thread-json>... — the GraphQL answer for one PR
mkpr() {
  local num="$1" br="$2" st="$3" rem="$4" rst="$5"; shift 5
  printf '%s\n' "$@" | jq -s --arg n "$num" 'map(.id = $n + ":" + .id)' > "$FIX/nodes.tmp"
  jq -n --argjson num "$num" --arg br "$br" --arg st "$st" --argjson rem "$rem" --arg rst "$rst" --slurpfile nodes "$FIX/nodes.tmp" \
    '$nodes[0] as $nodes | {data:{rateLimit:{cost:1,remaining:$rem,resetAt:$rst},
       repository:{pullRequest:{number:$num,state:$st,mergedAt:"2026-10-20T10:00:00Z",headRefName:$br,headRefOid:"1111111111111111111111111111111111111111",
         commits:{nodes:[{commit:{committedDate:"2026-10-20T09:00:00Z"}}]},
         reviewThreads:{pageInfo:{hasNextPage:false,endCursor:null},nodes:$nodes}}}}}' > "$FIX/pr-$num.json"
}
FAR="2030-01-01T00:00:00Z"
count_rows() { grep -c "\"pr\":$1," "$LEDGER" | tr -d ' '; }
verdict_of() { grep "\"thread_id\":\"$1:$2\"" "$LEDGER" | jq -r --argjson p "$1" 'select(.pr==$p)|.verdict'; }

T_FIXED="$(thread T1 true  2026-10-20T08:00:00Z 2222222222222222222222222222222222222222 10 coderabbitai 'Fix the thing')"
T_DISPR="$(thread T2 true  2026-10-20T09:30:00Z 2222222222222222222222222222222222222222 20 coderabbitai 'Rename the other thing')"
T_OPEN="$(thread T3 false 2026-10-20T08:30:00Z 2222222222222222222222222222222222222222 30 coderabbitai 'Handle the empty case')"
T_HUMAN="$(thread T4 false 2026-10-20T08:30:00Z 2222222222222222222222222222222222222222 40 someone 'A human remark')"

# ── PR 12: three CodeRabbit threads (fixed, disproved, open) + one human thread
# + one outside-diff finding in the review body at the head ──────────────────
mkpr 12 feat/x12 MERGED 4000 "$FAR" "$T_FIXED" "$T_DISPR" "$T_OPEN" "$T_HUMAN"
jq -n --rawfile body "$FIXB/pr-777-outside-diff-blockquote.body.txt" \
  '[{id:1,user:{id:136622811,login:"coderabbitai[bot]"},commit_id:"1111111111111111111111111111111111111111",submitted_at:"2026-10-20T09:50:00Z",body:$body}]' > "$FIX/reviews-12.json"
out="$(bash "$SUT" 12 2>&1)"; rc=$?
check "12: recorder exits 0" "$rc" "0"
check "12: three threads + one outside finding = 4 rows" "$(count_rows 12)" "4"
check "12: resolved after a later commit is fixed" "$(verdict_of 12 T1)" "fixed"
check "12: resolved with no later commit is disproved" "$(verdict_of 12 T2)" "disproved"
check "12: open at merge is unaddressed" "$(verdict_of 12 T3)" "unaddressed"
check "12: the human thread gets no row" "$(grep -c '"thread_id":"12:T4"' "$LEDGER" | tr -d ' ')" "0"
check "12: the outside-diff finding is a coderabbit-outside row" \
  "$(grep '"pr":12,' "$LEDGER" | jq -r 'select(.model=="coderabbit-outside")|.finding_id' )" "cr-od-39c3193c8945"
check "12: inline rows carry branch, head, model" \
  "$(grep '"thread_id":"12:T1"' "$LEDGER" | jq -r '[.branch,.head,.model,.kind]|join(" ")')" "feat/x12 2222222222222222222222222222222222222222 coderabbit finding"

# ── a re-run adds nothing ───────────────────────────────────────────────────
before="$(wc -l < "$LEDGER" | tr -d ' ')"
out="$(bash "$SUT" 12 2>&1)"; rc=$?
check "12: the re-run exits 0" "$rc" "0"
check "12: the re-run reads the PR" "$(grep -c '^cr-thread-recorder: 1 PR(s) read' <<< "$out" | tr -d ' ')" "1"
check "12: a re-run adds no rows" "$(wc -l < "$LEDGER" | tr -d ' ')" "$before"

# ── an existing hand-written row is neither duplicated nor rewritten ────────
mkpr 13 feat/x13 MERGED 4000 "$FAR" "$T_FIXED" "$T_DISPR"
HAND='{"kind":"finding","ts":"2026-10-20T08:10:00Z","branch":"feat/x13","head":"2222222222222222222222222222222222222222","model":"coderabbit","finding_id":"cr-a-10","severity":"imp","file":"a.sh","line":10,"verdict":"fixed","artifact":"diff","perspective":"off","text":"Fix the thing"}'
echo "$HAND" >> "$LEDGER"
bash "$SUT" 13 >/dev/null 2>&1
check "13: the hand-written finding is matched, only the other thread is added" "$(count_rows 13)" "1"
check "13: the hand-written row is byte-identical" "$(grep -c -F "$HAND" "$LEDGER" | tr -d ' ')" "1"

# ── a PR that is not merged records nothing ────────────────────────────────
mkpr 14 feat/x14 OPEN 4000 "$FAR" "$T_OPEN"
bash "$SUT" 14 >/dev/null 2>&1
check "14: an unmerged PR gets no rows" "$(count_rows 14)" "0"

# ── --since walks the merged PR list ────────────────────────────────────────
printf '15\n' > "$FIX/prs.txt"
mkpr 15 feat/x15 MERGED 4000 "$FAR" "$T_OPEN"
bash "$SUT" --since 2026-09-04 >/dev/null 2>&1
check "15: --since records the listed merged PR" "$(count_rows 15)" "1"
: > "$SHIM_LOG"
bash "$SUT" --since 2026-09-04 --until 2026-10-01 >/dev/null 2>&1
check "15: --until bounds the search to a date range" "$(grep -c 'merged:2026-09-04\.\.2026-10-01' "$SHIM_LOG" | tr -d ' ')" "1"
printf '15\n16\n' > "$FIX/prs.txt"
out="$(CR_RECORDER_LIST_CAP=2 bash "$SUT" --since 2026-09-04 --until 2026-10-01 2>&1 >/dev/null)"
check "15: a list at the cap warns" "$(grep -c 'WARNING the search returned 2 PRs' <<< "$out" | tr -d ' ')" "1"
printf '15\n' > "$FIX/prs.txt"

# ── tokens: a low budget rotates to the next token; no token is printed ─────
mkpr 16 feat/x16 MERGED 5 "$FAR" "$T_OPEN"
mkpr 17 feat/x17 MERGED 4000 "$FAR" "$T_OPEN"
: > "$SHIM_LOG"
out="$(CR_RECORDER_GH_TOKENS="tokB-secret" bash "$SUT" 16 17 2>&1)"
check "16-17: both PRs recorded" "$(( $(count_rows 16) + $(count_rows 17) ))" "2"
check "17: the second PR was read with the rotated token" "$(grep -c 'num=17 .*tok=tokB-secret' "$SHIM_LOG" | tr -d ' ')" "1"
check "16: the first PR was read with the ambient auth" "$(grep -c 'num=16 .*tok=ambient' "$SHIM_LOG" | tr -d ' ')" "1"
check "no token value reaches the output" "$(grep -c 'tokB-secret' <<< "$out" | tr -d ' ')" "0"

# ── with no token left the run waits for the reset before the next PR ───────
soon="$(date -u -d '+30 seconds' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v+30S +%Y-%m-%dT%H:%M:%SZ)"
mkpr 18 feat/x18 MERGED 5 "$soon" "$T_OPEN"
mkpr 19 feat/x19 MERGED 4000 "$FAR" "$T_OPEN"
: > "$SLEEPS"
bash "$SUT" 18 19 >/dev/null 2>&1
check "18-19: the run slept for the reset" "$(grep -c '^slept' "$SLEEPS" | tr -d ' ')" "1"
check "19: recorded after the wait" "$(count_rows 19)" "1"

# ── only the CodeRabbit bot's own threads count, not a lookalike login ──────────
mkpr 20 feat/x20 MERGED 4000 "$FAR" "$(thread T9 false 2026-10-20T08:30:00Z 2222222222222222222222222222222222222222 90 coderabbitai-example 'A lookalike remark')"
bash "$SUT" 20 >/dev/null 2>&1
check "20: a lookalike bot login gets no row" "$(count_rows 20)" "0"

# ── an outside-diff list that no longer parses is a partial run, not a clean one ──
mkpr 21 feat/x21 MERGED 4000 "$FAR" "$T_OPEN"
jq -n '[{id:1,user:{id:136622811,login:"coderabbitai[bot]"},commit_id:"1111111111111111111111111111111111111111",submitted_at:"2026-10-20T09:50:00Z",
  body:"> **⚠️ Outside diff range comments (2)**\n\nnothing parseable here\n"}]' > "$FIX/reviews-21.json"
bash "$SUT" 21 >/dev/null 2>&1; rc=$?
check "21: an unparseable outside-diff list exits 3" "$rc" "3"

# ── CodeRabbit's real comment format: a bold severity header line, then the bold title ──
REAL_BODY="$(printf '_⚠️ Potential issue_ | _🟡 Minor_\n\n**<picture><img alt="Minor" src="x"/></picture> Minor** · **Stability & Availability** · **Quick win**\n\n**Select the finding title, not the header.**\n\nbecause reasons.')"
mkpr 22 feat/x22 MERGED 4000 "$FAR" "$(thread T22 false 2026-10-20T08:30:00Z 2222222222222222222222222222222222222222 50 coderabbitai 'unused' "$REAL_BODY")"
bash "$SUT" 22 >/dev/null 2>&1; rc=$?
check "22: recorder exits 0" "$rc" "0"
check "22: the stored text is the finding title, not the severity header" \
  "$(grep '"thread_id":"22:T22"' "$LEDGER" | jq -r '.text')" "Select the finding title, not the header."
# shellcheck disable=SC2016  # literal backticks in the comment body
STAR_BODY="$(printf '_⚠️ Potential issue_ | _🟡 Minor_\n\n**<picture><img alt="Minor" src="x"/></picture> Minor** · **Stability & Availability** · **Quick win**\n\n**Handle `*.sh` files**\n\n**Proposed fix:**\n\nbecause reasons.')"
mkpr 23 feat/x23 MERGED 4000 "$FAR" "$(thread T23 false 2026-10-20T08:30:00Z 2222222222222222222222222222222222222222 50 coderabbitai 'unused' "$STAR_BODY")"
bash "$SUT" 23 >/dev/null 2>&1; rc=$?
check "23: recorder exits 0" "$rc" "0"
# shellcheck disable=SC2016  # literal backticks in the expected title
check "23: a title with an asterisk inside is kept whole" \
  "$(grep '"thread_id":"23:T23"' "$LEDGER" | jq -r '.text')" 'Handle `*.sh` files'

# ── a later page of threads larger than one exec argument is still combined ──
BODY5K="$(head -c 5000 /dev/zero | tr '\0' 'x')"
pg2=(); for i in $(seq 1 40); do
  pg2+=("$(thread "B$i" false 2026-10-20T08:30:00Z 2222222222222222222222222222222222222222 $((100 + i)) coderabbitai t "$BODY5K")"); done
mkpr 25 feat/x24 MERGED 4000 "$FAR" "${pg2[@]}"
jq -c '.data.repository.pullRequest.number = 24' "$FIX/pr-25.json" > "$FIX/pr-24-p2.json"
mkpr 24 feat/x24 MERGED 4000 "$FAR" "$T_OPEN"
jq -c '.data.repository.pullRequest.reviewThreads.pageInfo = {hasNextPage:true,endCursor:"c1"}' "$FIX/pr-24.json" > "$FIX/pr-24.n" && mv "$FIX/pr-24.n" "$FIX/pr-24.json"
bash "$SUT" 24 >/dev/null 2>&1; rc=$?
check "24: a 200 KB second page of threads is recorded, the run exits 0" "$rc" "0"
check "24: both pages are recorded (1 + 40 rows)" "$(count_rows 24)" "41"

# ── a ledger that cannot be read or appended fails the run, not a silent exit 0 ──
mkdir "$tmp/ro"; : > "$tmp/ro/ledger.jsonl"; mkdir "$tmp/ro/ledger.jsonl.lock"
out="$(CR_LEDGER="$tmp/ro/ledger.jsonl" bash "$SUT" 12 2>&1)"; rc=$?
check "ledger append blocked by a held lock path: the run exits 3" "$rc" "3"
check "ledger append blocked by a held lock path: the PR is not counted as read" "$(grep -c '^cr-thread-recorder: 1 PR(s) read' <<< "$out" | tr -d ' ')" "0"

[ "$fails" -eq 0 ] && echo "ALL PASS" || { echo "$fails FAILED"; exit 1; }
