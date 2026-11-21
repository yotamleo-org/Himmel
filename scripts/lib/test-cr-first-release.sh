#!/usr/bin/env bash
# shellcheck disable=SC2015
# Tests for scripts/lib/cr-first-release.sh and scripts/cr/cr-trigger-ledger.sh
# Hermetic: gh is a stub driven by files in $S, so a
# label write is recorded and the next call reads it back from the stubbed
# timeline, exactly as GitHub would answer. CodeRabbit status rows are the real
# captures in scripts/ci/fixtures/cr-first-measure-bundle.jsonl (cr-first-measure
# --dump), re-wearing the bot identity the statuses API carries; the rate-limit
# comment is the real PR 3215 reply.
set -uo pipefail

unset GH_TOKEN GITHUB_TOKEN ARMAUTOMERGE CR_MERGE_GATE_OK HIMMEL_CONSOLE_DOC CR_FIRST_NOW CR_FIRST_CHEAP_RE \
      CR_FIRST_HEAVY_RE CRITICS_JSON CR_PROFILE

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUNDLE="$SCRIPT_DIR/../ci/fixtures/cr-first-measure-bundle.jsonl"
RL_COMMENTS="$SCRIPT_DIR/fixtures/cr-ratelimit/pr-3215-comments.json"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/crfirst.XXXXXX")" || exit 1
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home"; mkdir -p "$HOME"
S="$TMP/state"; mkdir -p "$S"
export GH_STUB_STATE="$S"
export CR_FIRST_LEDGER="$TMP/release-ledger.jsonl" CR_FIRST_ALERTS="$TMP/release-alerts"

# ── stub gh ───────────────────────────────────────────────────────────
mkdir -p "$TMP/bin"
cat > "$TMP/bin/gh" <<'EOF'
#!/usr/bin/env bash
S="${GH_STUB_STATE:?}"
echo "$*" >> "$S/calls.log"
printf '%s\t%s\n' "${GH_TOKEN:+read}${GH_TOKEN:-main}" "$*" | sed -E 's/^read[A-Za-z0-9_]*/read/' >> "$S/tok.log"
J="$*"; A="${J//--paginate /}"
f() { [ -f "$S/$1" ] && cat "$S/$1" || echo "${2:-[]}"; }
case "$A" in
  "variable get CI_GO_GATE"*) [ -f "$S/var" ] || { echo "could not find variable" >&2; exit 1; }; cat "$S/var"; exit 0 ;;
  *graphql*) f threads.json '{"data":{"repository":{"pullRequest":{"reviewThreads":{"pageInfo":{"hasNextPage":false},"nodes":[]}}}}}'; exit 0 ;;
  *"-X DELETE "*"/labels/ci:go"*)
    [ -f "$S/delete-fail" ] && exit 1
    if [ -f "$S/delete-real" ]; then
      # GitHub: removing a label that is not on the PR is a 404 and leaves no timeline event
      jq -e 'any(.[]; .name == "ci:go")' "$S/labels.json" >/dev/null 2>&1 || { echo '{"message":"Label does not exist"}' >&2; exit 1; }
      jq -c --arg t "${GH_STUB_NOW:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}" '. + [{event:"unlabeled",label:{name:"ci:go"},created_at:$t}]' "$S/events.json" > "$S/events.tmp" && mv "$S/events.tmp" "$S/events.json"
    fi
    exit 0 ;;
  *"-X POST "*"/issues/"*"/labels"*)
    [ -f "$S/add-fail" ] && { echo "HTTP 502" >&2; exit 1; }
    [ -f "$S/add-fail-once" ] && { rm -f "$S/add-fail-once"; echo "HTTP 502" >&2; exit 1; }
    jq -c --arg t "${GH_STUB_NOW:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}" '. + [{event:"labeled",label:{name:"ci:go"},created_at:$t}]' "$S/events.json" > "$S/events.tmp" && mv "$S/events.tmp" "$S/events.json"
    echo '[{"name":"ci:go"}]'; exit 0 ;;
  "api repos/o/r/labels/ci:go"*) [ -f "$S/label-missing" ] && { echo '{"message":"Not Found"}' >&2; exit 1; }; echo '{"name":"ci:go"}'; exit 0 ;;
  "api repos/o/r/pulls/"*"/reviews"*) f reviews.json; exit 0 ;;
  "api repos/o/r/pulls/"*) [ -f "$S/pull-after.json" ] && [ -f "$S/gate-began" ] && { cat "$S/pull-after.json"; exit 0; }; f pull.json '{}'; exit 0 ;;
  "api repos/o/r/issues/"*"/events"*) f events.json; exit 0 ;;
  "api repos/o/r/issues/"*"/labels"*) f labels.json; exit 0 ;;
  "api repos/o/r/issues/"*"/comments"*) f comments.json; exit 0 ;;
  "api repos/o/r/actions/runs"*) [ -f "$S/runs-fail" ] && exit 1; f runs.json '{"workflow_runs":[]}'; exit 0 ;;
  "api repos/o/r/commits/"*"/check-runs"*) f checks.json '{"check_runs":[]}'; exit 0 ;;
  "api repos/o/r/commits/"*"/statuses"*) : > "$S/gate-began"; f statuses.json; exit 0 ;;
  "api repos/o/r/commits/"*) f commit.json '{}'; exit 0 ;;
  "pr view --"*) echo "argument required when using the --repo flag" >&2; exit 1 ;;
  "pr view "*) echo "42 0000000000000000000000000000000000000000"; exit 0 ;;
  "pr list --head "*)
    # the open PRs of $S/prlist.json whose head branch is --head, through the caller's -q expression
    b="${A#pr list --head }"; b="${b%% *}"; q=""
    while [ "$#" -gt 0 ]; do [ "$1" = -q ] && q="$2"; shift; done
    [ -f "$S/prlist.json" ] && jq -r --arg b "$b" "[.[] | select(.headRefName == \$b)] | $q" "$S/prlist.json"
    exit 0 ;;
esac
echo '{}'
EOF
chmod +x "$TMP/bin/gh"
export PATH="$TMP/bin:$PATH"
mkdir -p "$TMP/envroot"
printf 'himmel_github_token_vm2=ghp_CRFREAD0123456789\n' > "$TMP/envroot/.env"
export GH_READ_ENV_ROOT="$TMP/envroot" GH_READ_QUIET=1
export CR_FIRST_SWITCH_TTL=0

# ── the repo the gate runs IN, and the reviewer set ──────────────────────────
mkdir -p "$TMP/repo"
git -C "$TMP/repo" init --quiet >/dev/null 2>&1
git -C "$TMP/repo" remote add origin https://github.com/o/r.git
git -C "$TMP/repo" config --local himmel.coderabbit true
cd "$TMP/repo" || { echo "FATAL: cannot cd to the test repo"; exit 1; }
cat > "$TMP/critics.json" <<'JSON'
{"panel":[
 {"slug":"codex","model":"m","provider":"openai-codex","mode":"hard","required":true},
 {"slug":"claude","model":"m","provider":"claude-api","mode":"hard","required":false},
 {"slug":"coderabbit","provider":"github-app","mode":"best-effort"}]}
JSON
export CRITICS_BASE_JSON="$TMP/critics.json" CRITICS_LOCAL_JSON="$TMP/no-overlay.json"
LEDGER="$TMP/repo/.git/cr-critic-scores.jsonl"

# shellcheck disable=SC1091
. "$SCRIPT_DIR/cr-first-release.sh"

pass=0; fail=0
ok()  { pass=$((pass+1)); echo "ok   $1"; }
bad() { fail=$((fail+1)); echo "FAIL $1"; }
has() { if grep -qE -- "$2" "$1" 2>/dev/null; then ok "$3"; else bad "$3 (no /$2/ in $(basename "$1"))"; fi; }
hasnt() { # grep rc 1 = no match (pass); rc 0 = matched, rc 2 = unreadable file or bad regex (both fail)
  local rc=0; grep -qE -- "$2" "$1" 2>/dev/null || rc=$?
  case "$rc" in 1) ok "$3" ;; 0) bad "$3 (/$2/ in $(basename "$1"))" ;; *) bad "$3 (grep rc=$rc on $(basename "$1"))" ;; esac
}
eq() { if [ "$1" = "$2" ]; then ok "$3"; else bad "$3 (got [$1] want [$2])"; fi; }
posts() { grep -c -- '-X POST' "$S/calls.log" 2>/dev/null || true; }
deletes() { grep -c -- '-X DELETE' "$S/calls.log" 2>/dev/null || true; }
ledger_lines() { [ -f "$CR_FIRST_LEDGER" ] && wc -l < "$CR_FIRST_LEDGER" | tr -d ' ' || echo 0; }

HEAD1=a1b2c3d4e5f6a7b8c9d0a1b2c3d4e5f6a7b8c9d0
T0=2026-10-23T10:00:00Z
iso_to_epoch() { jq -rn --arg t "$1" '$t | fromdateiso8601'; }
epoch_to_iso() { jq -rn --argjson e "$1" '$e | todate'; }
NOW0=$(iso_to_epoch "$T0")
CR_STATUS_HEAD=5e6893ec097a8e67872f9d1670e26c108c9778e0   # PR 3222's real head in the bundle

# real_statuses <skip-newest-n> — the real CodeRabbit statuses of one bundle
# head, newest first, minus the newest <n>; the bot identity is re-attached.
real_statuses() {
  jq -c --argjson pr 3222 --arg h "$CR_STATUS_HEAD" --argjson n "$1" \
    'select(.pr == $pr) | .statuses[$h][$n:]
     | map(. + {context: "CodeRabbit", creator: {id: 136622811, login: "coderabbitai[bot]", type: "Bot"}})' "$BUNDLE"
}
av() { printf '{"kind":"avail","head":"%s","model":"%s","status":"%s","reason":"%s","detail":"%s"}\n' "$1" "$2" "$3" "${4:-}" "${5:-}"; }
led() { printf '%s\n' "$@" > "$LEDGER"; }
checks() { # checks <ci-quick conclusion|pending|none> [extra check-runs json array]
  local cq="$1" extra="${2:-[]}"
  case "$cq" in
    none)    echo '{"check_runs":[]}' ;;
    pending) jq -nc --argjson x "$extra" '{check_runs: ([{name:"ci-quick",status:"in_progress",conclusion:null,completed_at:null}] + $x)}' ;;
    *)       jq -nc --arg c "$cq" --argjson x "$extra" '{check_runs: ([{name:"ci-quick",status:"completed",conclusion:$c,completed_at:"2026-10-23T10:09:00Z"}] + $x)}' ;;
  esac > "$S/checks.json"
}
thread() { printf '{"isResolved":%s,"path":"%s","line":%s,"comments":{"nodes":[{"author":{"login":"coderabbitai"}}]}}' "$1" "$2" "$3"; }
threads() { printf '{"data":{"repository":{"pullRequest":{"reviewThreads":{"pageInfo":{"hasNextPage":false},"nodes":[%s]}}}}}\n' "$(IFS=,; echo "$*")" > "$S/threads.json"; }
runs() { jq -nc --arg e "$1" --argjson id "$2" '{workflow_runs: [{id: 1, event: $e, check_suite_id: $id}]}' > "$S/runs.json"; }

# reset — the clean default: switch on, open non-fork PR at HEAD1, cheap green,
# no heavy job, no release event, CodeRabbit completed, no threads, both critics ok.
reset() {
  rm -rf "$S"; mkdir -p "$S"; : > "$S/calls.log"; rm -f "$CR_FIRST_LEDGER" "$CR_FIRST_ALERTS"
  _CRF_SW_REPO=""
  rm -f "$TMP/repo/.git"/cr-first-release.*.lock
  echo on > "$S/var"
  jq -nc --arg h "$HEAD1" '{state:"open",head:{sha:$h,repo:{fork:false}},labels:[]}' > "$S/pull.json"
  jq -nc --arg h "$HEAD1" --arg d "$T0" '{sha:$h,commit:{committer:{date:$d}}}' > "$S/commit.json"
  echo '[]' > "$S/events.json"
  checks success
  real_statuses 0 > "$S/statuses.json"
  led "$(av "$HEAD1" codex ok)" "$(av "$HEAD1" claude ok)"
  export CR_FIRST_NOW=$((NOW0 + 600))
  unset HIMMEL_CONSOLE_DOC
}
# run <name> — cr_first_release 42 HEAD1 o/r; out/err files, rc in $RC
run() {
  RC=0; : > "$S/calls.log.pre"
  cr_first_release 42 "${HEAD:-$HEAD1}" o/r >"$TMP/out-$1" 2>"$TMP/err-$1" || RC=$?
}
# p1 <name> — P1: a release GO implies the merge-mode gate GO at the same head
p1() {
  local rc=0
  cr_reviewer_gate 42 "${HEAD:-$HEAD1}" o/r >/dev/null 2>&1 || rc=$?
  eq "$rc" 0 "P1 $1: release GO implies merge-mode GO"
}

# ── RED control: with the switch off or a fork there is nothing to do, so a
# no-op implementation passes those rows; every row below needs real behavior.

# RL9 / R9 — switch off (variable "off", and unset): no label call, no HOLD.
reset; echo off > "$S/var"; run RL9-off
eq "$(posts)$(deletes)" 00 "RL9 switch off: no label write"
hasnt "$TMP/out-RL9-off" 'CR-FIRST' "RL9 switch off: no HOLD line"
reset; rm -f "$S/var"; run RL9-unset
eq "$(posts)$(deletes)" 00 "RL9 variable unset: no label write"
hasnt "$TMP/out-RL9-unset" 'CR-FIRST' "RL9 variable unset: no HOLD line"
hasnt "$S/calls.log" 'check-runs|statuses|graphql' "RL9 switch off: nothing read beyond the switch"
# R10 — fork PR: no label call.
reset; jq -c '.head.repo.fork = true' "$S/pull.json" > "$S/p.tmp" && mv "$S/p.tmp" "$S/pull.json"; run R10-fork
eq "$(posts)$(deletes)" 00 "R10 fork PR: no label write"
hasnt "$TMP/out-R10-fork" 'CR-FIRST HOLD' "R10 fork PR: no HOLD line"
# head moved: the PR head is not the head asked about.
reset; HEAD=deadbeef$HEAD1 run head-moved; unset HEAD
eq "$(posts)$(deletes)" 00 "head moved: no label write"

# ── the release: RL7 / R-3595d shape, ledger line, one remove + add pair ─────
reset; run release-clean
has "$TMP/out-release-clean" '^CR-FIRST RELEASE ' "release: prints CR-FIRST RELEASE"
eq "$(deletes)/$(posts)" 1/1 "release: exactly one remove + one add"
eq "$(ledger_lines)" 1 "release: one ledger line"
jq -e --arg h "$HEAD1" '.pr == 42 and .head == $h and (.ts | type == "string") and (.cheap_settled_at | type == "string")
   and (.reviewers | map(.slug) | sort == ["claude","coderabbit","codex"])
   and (.reviewers | all(.[]; length == 7 and has("slug") and has("mode") and has("state") and has("verdict")
        and has("findings") and has("latency_s") and has("cost_usd")))' "$CR_FIRST_LEDGER" >/dev/null 2>&1 \
  && ok "release: ledger line carries pr, head, ts, cheap_settled_at, reviewers[slug,mode,state,verdict,findings,latency_s,cost_usd]" \
  || { bad "release: ledger line shape"; sed 's/^/  ledger: /' "$CR_FIRST_LEDGER" 2>/dev/null; }
# flock is util-linux: without it the release runs unlocked (no lock file by design), so the row has nothing to assert.
if command -v flock >/dev/null 2>&1; then
ls "$TMP/repo/.git"/cr-first-release.42.lock >/dev/null 2>&1 && ok "release: per-PR lock file in the git common dir" || bad "release: per-PR lock file in the git common dir"
else echo "SKIP release: per-PR lock file in the git common dir (no flock on this host)"; fi
p1 release-clean
# RL7 — a second call at the same head: no second pair (the timeline now shows the event).
run RL7-second
eq "$(deletes)/$(posts)" 1/1 "RL7 two calls at one head: still one pair"
eq "$(ledger_lines)" 1 "RL7 two calls at one head: still one ledger line"
# RL4 — a late CodeRabbit finding after the release does not undo it or fire a second pair.
threads "$(thread false portable-timeout.sh 24)"; run RL4-late-finding
eq "$(deletes)/$(posts)" 1/1 "RL4 late finding: release unchanged, no second pair"

# RL8 — a manual ci:go at the head, then a worker event: no second pair.
reset; jq -c '. + [{event:"labeled",label:{name:"ci:go"},created_at:"2026-10-23T10:05:00Z"}]' "$S/events.json" > "$S/e.tmp" && mv "$S/e.tmp" "$S/events.json"; run RL8-manual
eq "$(deletes)/$(posts)" 0/0 "RL8 manual ci:go at the head: no pair"
eq "$(ledger_lines)" 0 "RL8 manual ci:go: no ledger line (it is a manual release)"
# already released by a heavy job at the head (a ci.yml pull_request run started one).
reset; checks success '[{"name":"bun-suites","status":"completed","conclusion":"success","completed_at":"2026-10-23T10:20:00Z","check_suite":{"id":7}}]'; runs pull_request 7; run released-by-heavy-job
eq "$(deletes)/$(posts)" 0/0 "heavy job already ran at the head: no pair"
# ...a SKIPPED heavy job is not a release.
reset; checks success '[{"name":"bun-suites","status":"completed","conclusion":"skipped","completed_at":"2026-10-23T10:01:00Z","check_suite":{"id":7}}]'; runs pull_request 7; run heavy-skipped-not-released
eq "$(deletes)/$(posts)" 1/1 "skipped heavy job is not a release: one pair"
# ...a QUEUED heavy job (no conclusion yet) is not proof the head ran.
reset; checks success '[{"name":"bun-suites","status":"queued","conclusion":null,"completed_at":null,"check_suite":{"id":7}}]'; runs pull_request 7; run heavy-queued-not-released
eq "$(deletes)/$(posts)" 1/1 "queued heavy job is not a release: one pair"
# ...an in-progress one is.
reset; checks success '[{"name":"bun-suites","status":"in_progress","conclusion":null,"completed_at":null,"check_suite":{"id":7}}]'; runs pull_request 7; run heavy-running-released
eq "$(deletes)/$(posts)" 0/0 "in-progress heavy job already ran at the head: no pair"
reset; checks success '[{"name":"shell-unit-shard (ubuntu-latest, 1)","status":"completed","conclusion":"success","completed_at":"2026-10-23T10:20:00Z","check_suite":{"id":9}}]'; runs workflow_dispatch 9; run heavy-dispatch-not-released
eq "$(deletes)/$(posts)" 1/1 "heavy jobs of a workflow_dispatch run at the head are not a release: one pair"
has "$S/calls.log" 'actions/runs\?head_sha=a1b2c3d4e5f6a7b8c9d0a1b2c3d4e5f6a7b8c9d0&event=pull_request' "heavy job at the head: the head's pull_request runs are read"
reset; checks success '[{"name":"shell-unit-shard (ubuntu-latest, 1)","status":"completed","conclusion":"success","completed_at":"2026-10-23T10:20:00Z","check_suite":{"id":9}},{"name":"shell-unit (ubuntu-latest)","status":"completed","conclusion":"success","completed_at":"2026-10-23T10:30:00Z","check_suite":{"id":7}}]'
jq -nc '{workflow_runs: [{id: 1, event: "workflow_dispatch", check_suite_id: 9}, {id: 2, event: "pull_request", check_suite_id: 7}]}' > "$S/runs.json"; run heavy-pr-beside-dispatch
eq "$(deletes)/$(posts)" 0/0 "a pull_request heavy job beside a dispatch one is a release: no pair"
reset; checks success '[{"name":"bun-suites","status":"completed","conclusion":"success","completed_at":"2026-10-23T10:20:00Z","check_suite":{"id":7}}]'; : > "$S/runs-fail"; run heavy-runs-unreadable
eq "$RC/$(deletes)/$(posts)" 3/0/0 "unreadable workflow runs with a heavy job: rc 3, no pair"
has "$TMP/out-heavy-runs-unreadable" '^CR-FIRST HOLD degraded \(cannot read workflow runs at ' "unreadable workflow runs: degraded HOLD line"
reset; checks success '[{"name":"bun-suites","status":"completed","conclusion":"success","completed_at":"2026-10-23T10:20:00Z","check_suite":{"id":7}}]'; echo '{"message":"oops"}' > "$S/runs.json"; run heavy-runs-malformed
eq "$RC/$(deletes)/$(posts)" 3/0/0 "malformed workflow runs with a heavy job: rc 3, no pair"
has "$TMP/out-heavy-runs-malformed" '^CR-FIRST HOLD degraded \(cannot parse workflow runs at ' "malformed workflow runs: degraded HOLD line"
reset; checks success '[{"name":"bun-suites","status":"completed","conclusion":"success","completed_at":"2026-10-23T10:20:00Z","check_suite":{"id":7}}]'; : > "$S/runs.json"; run heavy-runs-empty
eq "$RC/$(deletes)/$(posts)" 3/0/0 "an empty workflow-run reply with a heavy job: rc 3, no pair"
reset; run no-heavy-no-runs-read
hasnt "$S/calls.log" 'actions/runs' "no heavy job at the head: no workflow-run read"
# a label event older than the head's own checks belongs to an earlier life of the commit.
reset; jq -c '. + [{event:"labeled",label:{name:"ci:go"},created_at:"2026-10-23T10:05:00Z"}]' "$S/events.json" > "$S/e.tmp" && mv "$S/e.tmp" "$S/events.json"
checks success '[{"name":"lint","status":"completed","conclusion":"success","started_at":"2026-10-23T10:08:00Z","completed_at":"2026-10-23T10:08:30Z"}]'; run old-label-before-head-checks
eq "$(deletes)/$(posts)" 1/1 "a ci:go event before the head's first check started does not release the head"
# a push after a go run, with scratch PR 3841's real timestamps: head 1's ci:go (01:31:55) is older than
# head 2's commit (01:34:25) and first check (01:35:44), so head 2 gets its own pair, once.
reset; jq -nc --arg h "$HEAD1" --arg d 2026-10-25T01:34:25Z '{sha:$h,commit:{committer:{date:$d}}}' > "$S/commit.json"
echo '[{"event":"labeled","label":{"name":"ci:go"},"created_at":"2026-10-25T01:31:55Z"}]' > "$S/events.json"
checks success '[{"name":"bun-suites","status":"completed","conclusion":"skipped","started_at":"2026-10-25T01:35:44Z","completed_at":"2026-10-25T01:35:44Z","check_suite":{"id":7}},{"name":"lint","status":"completed","conclusion":"success","started_at":"2026-10-25T01:35:46Z","completed_at":"2026-10-25T01:49:46Z"}]'; runs pull_request 7
CR_FIRST_NOW=$(iso_to_epoch 2026-10-25T01:50:00Z) run push-after-go-run
has "$TMP/out-push-after-go-run" '^CR-FIRST RELEASE ' "push after a go run: head 2 is released although head 1 had a ci:go"
eq "$(deletes)/$(posts)" 1/1 "push after a go run: exactly one remove + add pair at the new head"
CR_FIRST_NOW=$(iso_to_epoch 2026-10-25T01:50:30Z) run push-after-go-run-again
eq "$(deletes)/$(posts)/$(jq -r '[.[] | select(.event == "labeled")] | length' "$S/events.json")" 1/1/2 "push after a go run: a second call writes no second pair (two labeled events in all: head 1's and head 2's)"
# the head moves between the first PR read and the label write: nothing is written.
reset; jq -c '.head.sha = "feedface00000000000000000000000000000000"' "$S/pull.json" > "$S/pull-after.json"; run head-moves-mid-release
eq "$(deletes)/$(posts)/$(ledger_lines)" 0/0/0 "head moved during evaluation: no label write, no ledger line"
# a failed-to-start cheap job is red.
reset; checks startup_failure; run cheap-startup-failure
has "$TMP/out-cheap-startup-failure" 'CR-FIRST HOLD cheap-red' "ci-quick startup_failure holds as cheap-red"
eq "$(deletes)/$(posts)" 0/0 "ci-quick startup_failure: no label write"
# RL2 — H1's release does not carry over to H2.
reset; jq -c '. + [{event:"labeled",label:{name:"ci:go"},created_at:"2026-10-23T09:00:00Z"}]' "$S/events.json" > "$S/e.tmp" && mv "$S/e.tmp" "$S/events.json"
led; run RL2-old-release
has "$TMP/out-RL2-old-release" 'CR-FIRST HOLD codex not-yet-run' "RL2 an older head's release does not carry: codex not-yet-run holds"
eq "$(deletes)/$(posts)" 0/0 "RL2 no pair at the new head"

# ── the cheap side (R2 / RL11 / R3) ──────────────────────────────────────────
reset; checks pending; run RL11-cheap-pending
has "$TMP/out-RL11-cheap-pending" '^CR-FIRST RELEASE ' "RL11 ci-quick pending, reviewers passed: RELEASE"
eq "$(deletes)/$(posts)" 1/1 "RL11 ci-quick pending: one pair"
eq "$(ledger_lines)" 1 "RL11 ci-quick pending: one ledger line"
jq -e '.cheap_settled_at == null' "$CR_FIRST_LEDGER" >/dev/null 2>&1 \
  && ok "RL11 ci-quick pending: the ledger line carries cheap_settled_at null (the cheap run had not settled)" \
  || { bad "RL11 ci-quick pending: cheap_settled_at null"; sed 's/^/  ledger: /' "$CR_FIRST_LEDGER" 2>/dev/null; }
p1 RL11-pending
reset; checks pending; led; run RL11-pending-reviewer-hold
has "$TMP/out-RL11-pending-reviewer-hold" '^CR-FIRST HOLD codex not-yet-run ' "RL11 ci-quick pending + codex not-yet-run: the reviewer hold stands"
eq "$(deletes)/$(posts)" 0/0 "RL11 ci-quick pending + reviewer hold: no label"
reset; checks pending; threads "$(thread false a/one.sh 10)"; run RL11-pending-thread
has "$TMP/out-RL11-pending-thread" '^CR-FIRST HOLD 1 unresolved CodeRabbit thread' "RL11 ci-quick pending + unresolved thread: the thread hold stands"
eq "$(deletes)/$(posts)" 0/0 "RL11 ci-quick pending + unresolved thread: no label"
reset; checks pending '[{"name":"lint","status":"completed","conclusion":"failure","completed_at":"2026-10-23T10:03:00Z"}]'; run RL11-pending-red
has "$TMP/out-RL11-pending-red" '^CR-FIRST HOLD cheap-red ' "RL11 ci-quick pending + a failed cheap job: HOLD cheap-red"
eq "$(deletes)/$(posts)" 0/0 "RL11 ci-quick pending + a failed cheap job: no label"
reset; checks success; run RL11-cheap-green
has "$TMP/out-RL11-cheap-green" '^CR-FIRST RELEASE ' "RL11 ci-quick green: release"
eq "$(deletes)/$(posts)" 1/1 "RL11 ci-quick green: one pair"
jq -e '.cheap_settled_at == "2026-10-23T10:09:00Z"' "$CR_FIRST_LEDGER" >/dev/null 2>&1 \
  && ok "RL11 ci-quick green: cheap_settled_at is the last cheap completion" || bad "RL11 ci-quick green: cheap_settled_at"
reset; checks none; run R2-cheap-not-reported
has "$TMP/out-R2-cheap-not-reported" '^CR-FIRST RELEASE ' "R2 ci-quick not reported yet, reviewers passed: RELEASE"
eq "$(deletes)/$(posts)" 1/1 "R2 ci-quick not reported yet: one pair"
reset; checks skipped; run R2-cheap-skipped
has "$TMP/out-R2-cheap-skipped" '^CR-FIRST RELEASE ' "R2 ci-quick skipped, reviewers passed: RELEASE"
eq "$(deletes)/$(posts)" 1/1 "R2 ci-quick skipped: one pair"
reset; checks failure; run R3-cheap-red
has "$TMP/out-R3-cheap-red" '^CR-FIRST HOLD cheap-red ' "R3 cheap side red: HOLD cheap-red"
eq "$(deletes)/$(posts)" 0/0 "R3 cheap side red: no label"
eq "$(grep -c '^CR-FIRST HOLD' "$TMP/out-R3-cheap-red")" 1 "R3 cheap side red: no hold line beyond cheap-red"

# ── a go run that cancels the cheap run (same concurrency group, same check names) ──
CHEAP_CANCELLED='{"id":101,"name":"lint","status":"completed","conclusion":"cancelled","started_at":"2026-10-23T10:01:00Z","completed_at":"2026-10-23T10:05:00Z"},{"id":102,"name":"secret-scan","status":"completed","conclusion":"cancelled","started_at":"2026-10-23T10:01:00Z","completed_at":"2026-10-23T10:05:00Z"}'
GO_GREEN='{"id":201,"name":"lint","status":"completed","conclusion":"success","started_at":"2026-10-23T10:06:00Z","completed_at":"2026-10-23T10:08:00Z"},{"id":202,"name":"secret-scan","status":"completed","conclusion":"success","started_at":"2026-10-23T10:06:00Z","completed_at":"2026-10-23T10:07:00Z"}'
reset; checks success "[$CHEAP_CANCELLED,$GO_GREEN]"; run cancelled-then-green
has "$TMP/out-cancelled-then-green" '^CR-FIRST RELEASE ' "cancelled cheap check-runs then the go run's green ones of the same names: reads green, RELEASE"
hasnt "$TMP/out-cancelled-then-green" 'cheap-red' "cancelled then green: no cheap-red line"
eq "$(deletes)/$(posts)" 1/1 "cancelled then green: one pair"
reset; checks success "[$GO_GREEN,$CHEAP_CANCELLED]"; run green-listed-before-cancelled
has "$TMP/out-green-listed-before-cancelled" '^CR-FIRST RELEASE ' "the green run listed before the older cancelled one still reads green (id decides, not position)"
eq "$(deletes)/$(posts)" 1/1 "green listed before cancelled: one pair"
reset; checks success '[{"id":301,"name":"lint","status":"completed","conclusion":"success","completed_at":"2026-10-23T10:03:00Z"},{"id":302,"name":"lint","status":"completed","conclusion":"cancelled","completed_at":"2026-10-23T10:05:00Z"}]'; run green-then-cancelled
has "$TMP/out-green-then-cancelled" '^CR-FIRST HOLD cheap-red ' "control: a green run then a cancelled one of the same name is cheap-red"
eq "$(deletes)/$(posts)" 0/0 "control: green then cancelled: no label"
reset; checks success '[{"id":401,"name":"lint","status":"completed","conclusion":"cancelled","completed_at":"2026-10-23T10:05:00Z"},{"id":402,"name":"secret-scan","status":"completed","conclusion":"success","completed_at":"2026-10-23T10:06:00Z"}]'; run cancelled-alone
has "$TMP/out-cancelled-alone" '^CR-FIRST HOLD cheap-red ' "control: a cancelled cheap check with no later run of its name is cheap-red"
eq "$(deletes)/$(posts)" 0/0 "control: cancelled alone: no label"
reset; jq -c '. + [{event:"labeled",label:{name:"ci:go"},created_at:"2026-10-23T10:05:00Z"}]' "$S/events.json" > "$S/e.tmp" && mv "$S/e.tmp" "$S/events.json"
printf '{"pr":42,"head":"%s","reviewers":[]}\n' "$HEAD1" | bash "$SCRIPT_DIR/../cr/cr-trigger-ledger.sh" append
checks cancelled "[$CHEAP_CANCELLED]"; run released-then-cheap-cancelled
eq "$(wc -c < "$TMP/out-released-then-cheap-cancelled" | tr -d ' ')/$(deletes)/$(posts)" 0/0/0 "released head whose cheap run the go run cancelled: quiet, no hold, no second pair"

# ── the reviewer gate at release (R-3595a-e, R4-R8, RL1, RL3, RL6) ───────
# The real PR 3222 "Review in progress" status is the newest once the two later
# statuses are dropped; the clock sits two minutes after it: the review is running now.
PEND_AT=$(iso_to_epoch "$(real_statuses 2 | jq -r '.[0].created_at')")
pending_reset() { reset; real_statuses 2 >"$S/statuses.json"; jq -nc --arg h "$HEAD1" '{sha:$h,commit:{committer:{date:"2026-10-19T18:00:00Z"}}}' > "$S/commit.json"; export CR_FIRST_NOW=$((PEND_AT + 120)); }
# R-3595a — CodeRabbit pending, hard reviewers pass: RELEASE at once (decision 1066: CodeRabbit is best effort).
pending_reset; run R-3595a-pending-releases
has "$TMP/out-R-3595a-pending-releases" '^CR-FIRST RELEASE ' "CodeRabbit pending, hard reviewers pass: RELEASE"
hasnt "$TMP/out-R-3595a-pending-releases" '^CR-FIRST HOLD .*[Cc]ode[Rr]abbit' "CodeRabbit pending: no HOLD line names CodeRabbit"
eq "$(deletes)/$(posts)" 1/1 "CodeRabbit pending: one pair"
p1 R-3595a
# R-3595e — CodeRabbit pending beside a posted, unresolved CodeRabbit thread: still HOLD naming it.
pending_reset; threads "$(thread false x.sh 1)"; run R-3595e-pending-thread
has "$TMP/out-R-3595e-pending-thread" '^CR-FIRST HOLD 1 unresolved CodeRabbit thread' "CodeRabbit pending + open thread: HOLD names the thread"
eq "$(deletes)/$(posts)" 0/0 "CodeRabbit pending + open thread: no label"
# R-3595b — a completed review and one unresolved Major thread: HOLD naming it.
reset; threads "$(thread false scripts/lib/portable-timeout.sh 24)"; run R-3595b-one-thread
has "$TMP/out-R-3595b-one-thread" '^CR-FIRST HOLD 1 unresolved CodeRabbit thread' "R-3595b one unresolved thread holds"
has "$TMP/out-R-3595b-one-thread" 'portable-timeout\.sh:24' "R-3595b names the location"
# R-3595c — three unresolved threads: HOLD naming all three locations.
reset; threads "$(thread false a/one.sh 10)" "$(thread false b/two.sh 20)" "$(thread false c/three.sh 30)"; run R-3595c-three-threads
has "$TMP/out-R-3595c-three-threads" '^CR-FIRST HOLD 3 unresolved CodeRabbit thread' "R-3595c three unresolved threads hold"
has "$TMP/out-R-3595c-three-threads" 'a/one\.sh:10.*b/two\.sh:20.*c/three\.sh:30' "R-3595c names all three locations"
# R-3595d — the threads resolved by reply, no push: GO at the same head, one pair.
threads "$(thread true a/one.sh 10)" "$(thread true b/two.sh 20)" "$(thread true c/three.sh 30)"; run R-3595d-resolved
has "$TMP/out-R-3595d-resolved" '^CR-FIRST RELEASE ' "R-3595d resolved by reply: GO at the unchanged head"
eq "$(deletes)/$(posts)" 1/1 "R-3595d exactly one remove + add pair"
p1 R-3595d
# R4 / RL6 — no CodeRabbit status at all, cheap settled: absent is relaxed, GO.
reset; echo '[]' > "$S/statuses.json"; run R4-absent
has "$TMP/out-R4-absent" '^CR-FIRST RELEASE ' "R4/RL6 absent CodeRabbit: GO"
p1 R4
# RL1 / R5 — the real PR 3215 rate-limit reply after this head's trigger: relaxed, GO at once.
reset; echo '[]' > "$S/statuses.json"; cp "$RL_COMMENTS" "$S/comments.json"
jq -nc --arg h "$HEAD1" '{sha:$h,commit:{committer:{date:"2026-10-19T19:30:00Z"}}}' > "$S/commit.json"; run RL1-rate-limited
has "$TMP/out-RL1-rate-limited" '^CR-FIRST RELEASE ' "RL1/R5 rate-limited comment: relaxed, GO at once"
p1 RL1
# RL3 — each PR is judged on its own head.
reset; run RL3-first; jq -c '.head.sha = "bbbb'"${HEAD1:4}"'"' "$S/pull.json" > "$S/p.tmp" && mv "$S/p.tmp" "$S/pull.json"
HEADB=bbbb${HEAD1:4}; led "$(av "$HEAD1" codex ok)" "$(av "$HEAD1" claude ok)" "$(av "$HEADB" codex ok)" "$(av "$HEADB" claude ok)"
echo '[]' > "$S/statuses.json"; echo '[]' > "$S/events.json"; cp "$RL_COMMENTS" "$S/comments.json"
jq -nc --arg h "$HEADB" '{sha:$h,commit:{committer:{date:"2026-10-19T19:30:00Z"}}}' > "$S/commit.json"
RC=0; cr_first_release 43 "$HEADB" o/r >"$TMP/out-RL3-second" 2>&1 || RC=$?
has "$TMP/out-RL3-first" '^CR-FIRST RELEASE ' "RL3 PR A released on its own head"
has "$TMP/out-RL3-second" '^CR-FIRST RELEASE ' "RL3 PR B released on its own head"
jq -es --arg h "$HEADB" 'any(.[]; .pr == 43 and .head == $h)' "$CR_FIRST_LEDGER" >/dev/null 2>&1 \
  && ok "RL3 the release ledger records PR B at its own head" || bad "RL3 no ledger line for PR 43 at $HEADB"
# R6/R7 — no codex row at the head (3595's real ledger state, or a merge of main with no carry row): HOLD.
reset; led; run R6-codex-not-yet-run
has "$TMP/out-R6-codex-not-yet-run" '^CR-FIRST HOLD codex not-yet-run ' "R6/R7 no codex row at the head: HOLD codex not-yet-run"
eq "$(deletes)/$(posts)" 0/0 "R6/R7 no label"
# R8 — claude absent because the API lane is off (decision 108): codex alone decides.
reset; led "$(av "$HEAD1" codex ok)" "$(av "$HEAD1" claude unavailable critic-skipped 'critic-first-pass.sh: claude critic SKIPPED (api lane is OFF (set HIMMEL_API_LANE=on)) - clean no-op')"; run R8-claude-absent
has "$TMP/out-R8-claude-absent" '^CR-FIRST RELEASE ' "R8 claude absent (lane off): codex alone decides, GO"
# degraded read never releases: the reviewThreads read fails and nothing holds.
reset; cat > "$TMP/bin/gh-degraded" <<'EOF'
EOF
rm -f "$TMP/bin/gh-degraded"; echo 'not json' > "$S/threads.json"; run degraded-read
eq "$(deletes)/$(posts)" 0/0 "degraded read: never releases"
has "$TMP/out-degraded-read" '^CR-FIRST HOLD degraded' "degraded read: HOLD degraded"
# config error is loud and never releases.
reset; printf '{"panel":[{"slug":"codex","provider":"openai-codex","mode":"best-effort"},{"slug":"coderabbit","provider":"github-app","mode":"best-effort"}]}\n' > "$TMP/m6.json"
CRITICS_JSON="$TMP/m6.json" run config-error
has "$TMP/out-config-error" '^CR-FIRST ERROR .*no hard reviewer' "config error: loud CR-FIRST ERROR, no release"
eq "$(deletes)/$(posts)" 0/0 "config error: no label"
# no_code_review: releases on CI alone and logs it.
reset; printf '{"review":"no_code_review","panel":[{"slug":"codex","provider":"openai-codex","mode":"hard"}]}\n' > "$TMP/nocr.json"
CRITICS_JSON="$TMP/nocr.json" run no-code-review
has "$TMP/out-no-code-review" '^CR-FIRST RELEASE .*no_code_review' "no_code_review: release on CI alone, logged"
eq "$(deletes)/$(posts)" 1/1 "no_code_review: one pair"

# ── RL10 / RL12: label missing, add failure ──────────────────────────────────
reset; touch "$S/label-missing"; run RL10-label-missing
eq "$(grep -c '^CR-FIRST ERROR' "$TMP/out-RL10-label-missing")" 1 "RL10 label missing: exactly one loud error"
has "$TMP/out-RL10-label-missing" 'CR-FIRST ERROR label ci:go' "RL10 the error names the label"
eq "$(deletes)/$(posts)" 0/0 "RL10 label missing: no write"
reset; touch "$S/add-fail"; run RL12-add-fails
eq "$(ledger_lines)" 0 "RL12 add fails: no ledger line"
eq "$RC" 2 "RL12 add fails: loud failure rc"
rm -f "$S/add-fail"; run RL12-retry
eq "$(deletes)/$(posts)" 2/3 "RL12 next call redoes the pair (head was left unreleased; the failed add was tried twice)"
eq "$(ledger_lines)" 1 "RL12 ledger line only after the add returned 2xx"
# One transient add failure after the remove succeeded is retried once in the same call.
reset; touch "$S/add-fail-once"; run RL12-add-fails-once
eq "$(posts)/$(ledger_lines)/$RC" 2/1/0 "RL12 one transient add failure: the add is retried once, the release is recorded"

# A DELETE that fails while ci:go is still on the PR would let the add pass with no
# fresh `labeled` event: nothing written, nothing recorded, loud error.
reset; touch "$S/delete-fail"; echo '[{"name":"ci:go"}]' > "$S/labels.json"; run RL12-delete-fails-label-stays
eq "$(posts)/$(ledger_lines)/$RC" 0/0/2 "RL12 delete fails, label still on: no add, no ledger line, rc 2"
has "$TMP/out-RL12-delete-fails-label-stays" '^CR-FIRST ERROR could not remove label ci:go' "RL12 delete fails: the error says the remove failed"
# ...but a DELETE that fails because the label was never on the PR is fine.
reset; touch "$S/delete-fail"; echo '[]' > "$S/labels.json"; run RL12-delete-fails-label-absent
eq "$(posts)/$(ledger_lines)" 1/1 "RL12 delete fails, label already absent: the pair completes"

# An unexpected reviewer-gate status (not 0, 1, 2, 3) is a hold, never a release.
reset
# shellcheck disable=SC2329 # invoked by cr_first_release through its name
cr_reviewer_gate() { echo "cr-reviewer-gate: boom"; return 4; }
run gate-rc4
unset -f cr_reviewer_gate; . "$SCRIPT_DIR/cr-first-release.sh"
eq "$(posts)/$(ledger_lines)/$RC" 0/0/3 "gate rc 4: no label, no ledger line, a degraded hold (rc 3)"
has "$TMP/out-gate-rc4" '^CR-FIRST HOLD degraded \(reviewer gate rc=4\)' "gate rc 4: HOLD degraded names the status"

# ── RL13 / M3': a hard reviewer down ─────────────────────────────────────────
CHIEF="$TMP/x-chief.md"; printf '# chief\n\n## Results (newest at the bottom)\n' > "$CHIEF"
reset; led "$(av "$HEAD1" codex unavailable critic-skipped 'refused: no ANTHROPIC_API_KEY and no key file')" "$(av "$HEAD1" claude ok)"
export HIMMEL_CONSOLE_DOC="$CHIEF"
for pr in 42 43 44; do
  RC=0; cr_first_release "$pr" "$HEAD1" o/r >"$TMP/out-RL13-$pr" 2>&1 || RC=$?
  jq -c --argjson n "$pr" '.number = $n' "$S/pull.json" > /dev/null
done
eq "$(cat "$TMP"/out-RL13-4[234] | grep -c '^CR-FIRST HOLD hard-unavailable codex')" 3 "RL13 hard lane down on 3 PRs: 3 hold lines"
eq "$(cat "$TMP"/out-RL13-4[234] | grep -c '^CR-FIRST ALERT')" 1 "RL13 one fleet alert on stdout"
eq "$(grep -c 'CR-FIRST ALERT' "$CHIEF")" 1 "RL13 one chief bullet"
has "$CHIEF" 'restore.*critics\.local\.json.*"mode":"best-effort".*"drop":true.*manual ci:go' "RL13 alert names the levers in order"
has "$CHIEF" 'if the operator approves, a critics\.local\.json overlay' "RL13 the overlay lever says it needs the operator's approval"
hasnt "$CHIEF" '>' "RL13 the chief bullet carries no >"
eq "$(posts)" 0 "RL13 no label while the hard lane is down"
# the outage ends (codex passes again): the dedup entry clears, a later outage alerts again.
led "$(av "$HEAD1" codex ok)" "$(av "$HEAD1" claude ok)"; run RL13-recovered
led "$(av "$HEAD1" codex unavailable critic-skipped 'refused: no ANTHROPIC_API_KEY and no key file')" "$(av "$HEAD1" claude ok)"; : > "$S/events.json"; echo '[]' > "$S/events.json"
run RL13-again
eq "$(grep -c 'CR-FIRST ALERT' "$CHIEF")" 2 "RL13 a new outage after recovery alerts again"
# M3' — no chief doc: the hold line is still printed and nothing fails.
reset; led "$(av "$HEAD1" codex unavailable critic-skipped 'refused: no ANTHROPIC_API_KEY and no key file')" "$(av "$HEAD1" claude ok)"
unset HIMMEL_CONSOLE_DOC; run M3p-no-chief
has "$TMP/out-M3p-no-chief" '^CR-FIRST HOLD hard-unavailable codex ' "M3' no console: hold line printed"
hasnt "$TMP/out-M3p-no-chief" 'CR-FIRST ERROR' "M3' no console: nothing errors"
eq "$RC" 1 "M3' no console: a hold, not a failure"

# ── read-only mode (ready-check.sh) ──────────────────────────────────────────
reset; CR_FIRST_READONLY=1 run readonly-pass
has "$TMP/out-readonly-pass" '^CR-FIRST PENDING-RELEASE ' "read-only: a passing gate says it would release"
eq "$(deletes)/$(posts)/$(ledger_lines)" 0/0/0 "read-only: no label write, no ledger line"
reset; checks failure; CR_FIRST_READONLY=1 run readonly-hold
has "$TMP/out-readonly-hold" '^CR-FIRST HOLD cheap-red ' "read-only: a hold still prints"
# a hard lane that is down raises no alert in read-only mode: the once-per-outage
# key stays for the tick sweep and the chief doc is not written.
RO_CHIEF="$TMP/ro-chief.md"; printf '# chief\n\n## Results (newest at the bottom)\n' > "$RO_CHIEF"
reset; led "$(av "$HEAD1" codex unavailable critic-skipped 'refused: no ANTHROPIC_API_KEY and no key file')" "$(av "$HEAD1" claude ok)"
HIMMEL_CONSOLE_DOC="$RO_CHIEF" CR_FIRST_READONLY=1 run readonly-hard-down
has "$TMP/out-readonly-hard-down" '^CR-FIRST HOLD hard-unavailable codex ' "read-only hard lane down: the hold still prints"
eq "$(grep -c 'CR-FIRST ALERT' "$RO_CHIEF")/$([ -s "$CR_FIRST_ALERTS" ] && echo alerts || echo none)" 0/none "read-only hard lane down: no chief bullet, no alert key consumed"

# ── the chief tick's sweep (event point 5) ─────────────────────────────────
sweep() { printf '%b' "$1" | cr_first_sweep o/r >"$TMP/out-sweep" 2>/dev/null; }
reset; echo off > "$S/var"; sweep "42\t$HEAD1\t\n"
eq "$(wc -c < "$TMP/out-sweep" | tr -d ' ')/$(grep -c 'pulls\|check-runs' "$S/calls.log")" 0/0 "sweep switch off: no output and no PR read"
reset; checks failure; sweep "42\t$HEAD1\t\n"
has "$TMP/out-sweep" '^crfirst=#42:cheap-red:[0-9]+[smhd]$' "sweep: a held head is listed with reason and age"
reset; printf '{"pr":42,"head":"%s","reviewers":[]}\n' "$HEAD1" | bash "$SCRIPT_DIR/../cr/cr-trigger-ledger.sh" append; sweep "42\t$HEAD1\tci:go,bug\n"
eq "$(grep -c 'pulls\|check-runs' "$S/calls.log")" 0 "sweep: a head this station released (ci:go + ledger line) is not read"
# a label that survived a push belongs to an older head: the new head still needs its own pair.
reset; echo '[{"event":"labeled","label":{"name":"ci:go"},"created_at":"2026-10-23T09:00:00Z"}]' > "$S/events.json"; sweep "42\t$HEAD1\tci:go\n"
eq "$(deletes)/$(posts)" 1/1 "sweep: a ci:go left over from an older head does not skip the new head"
reset; sweep "42\t$HEAD1\tbug\n"
eq "$(deletes)/$(posts)/$(wc -c < "$TMP/out-sweep" | tr -d ' ')" 1/1/0 "sweep: an unreleased head with a passing gate is released, nothing listed"
reset; echo '[{"event":"labeled","label":{"name":"ci:go"},"created_at":"2026-10-23T10:05:00Z"}]' > "$S/events.json"; sweep "42\t$HEAD1\t\n"
has "$TMP/out-sweep" '^crfirst=#42:manual-release$' "sweep: a manual release is listed"

# ── the CLI arguments ────────────────────────────────────────────────────────
# a trailing --pr / --head with no value must end, not spin; --repo names the repository.
# shellcheck disable=SC1091
. "$SCRIPT_DIR/timeout-bin.sh" 2>/dev/null
if [ -n "${_TIMEOUT_BIN:-}" ]; then
  for flag in --pr --head --repo; do
    reset; RC=0; "$_TIMEOUT_BIN" 5 bash "$SCRIPT_DIR/cr-first-release.sh" "$flag" >"$TMP/out-arg" 2>&1 || RC=$?
    eq "$RC" 2 "CLI: a trailing $flag with no value is a usage error, not a hang"
  done
else
  echo "skip CLI trailing-flag rows: no timeout binary"
fi
reset; RC=0; bash "$SCRIPT_DIR/cr-first-release.sh" --repo o/r --pr 42 --head "$HEAD1" >"$TMP/out-arg" 2>&1 || RC=$?
has "$TMP/out-arg" '^CR-FIRST RELEASE ' "CLI: --repo o/r --pr --head runs against the named repository"
# a named PR with no head reads that PR's head, not the current branch's PR.
reset; echo on > "$S/var"; RC=0; bash "$SCRIPT_DIR/cr-first-release.sh" --repo o/r --pr 42 >"$TMP/out-arg" 2>&1 || RC=$?
has "$S/calls.log" '^pr view 42 --repo o/r ' "CLI: --pr N with no head reads the head of PR N"

# no --pr/--head: the PR is the caller's branch's. `gh pr view --repo` with no selector is an error
# whatever the directory, so the entry names the branch it was run from.
git -C "$TMP/repo" checkout -q -b feat-x 2>/dev/null
mkdir -p "$TMP/other"; git -C "$TMP/other" init --quiet -b main >/dev/null 2>&1
git -C "$TMP/other" remote add origin https://github.com/o/r.git
# prlist <branch> <number> <cross-repo true|false>... — the open PRs `gh pr list --head` can return, one per triple
prlist() {
  local out='[]'
  while [ "$#" -ge 3 ]; do
    out=$(printf '%s' "$out" | jq -c --arg b "$1" --argjson n "$2" --argjson x "$3" --arg h "$HEAD1" \
      '. + [{number:$n, headRefOid:$h, headRefName:$b, isCrossRepository:$x}]')
    shift 3
  done
  printf '%s\n' "$out" > "$S/prlist.json"
}
reset; prlist feat-x 42 false
RC=0; (cd "$TMP/repo"&& bash "$SCRIPT_DIR/cr-first-release.sh") >"$TMP/out-arg" 2>&1 || RC=$?
eq "$RC" 0 "CLI: the caller's branch release exits 0"
has "$TMP/out-arg" '^CR-FIRST RELEASE ' "CLI: no --pr/--head resolves the PR from the caller's branch and releases"
has "$S/calls.log" '^pr list --head feat-x --state open --repo o/r ' "CLI: the lookup names the caller's branch"
eq "$(deletes)/$(posts)" 1/1 "CLI: the caller's branch release writes the label pair"
reset; prlist feat-x 42 false
RC=0; (cd "$TMP/other" && bash "$SCRIPT_DIR/cr-first-release.sh") >"$TMP/out-arg" 2>&1 || RC=$?
eq "$RC" 2 "CLI: a directory on another branch exits 2"
has "$TMP/out-arg" '^CR-FIRST ERROR no pull request for the current branch' "CLI: a directory on another branch finds no PR"
eq "$(posts)$(deletes)" 00 "CLI: a directory on another branch writes no label"
# a fork's PR that shares the branch name is not the caller's PR, whichever comes first.
reset; prlist feat-x 99 true feat-x 42 false
RC=0; (cd "$TMP/repo" && bash "$SCRIPT_DIR/cr-first-release.sh") >"$TMP/out-arg" 2>&1 || RC=$?
eq "$RC" 0 "CLI: a fork PR sharing the branch name is skipped (exit 0)"
has "$S/calls.log" '^api -X POST repos/o/r/issues/42/labels' "CLI: the label goes to the same-repo PR"
hasnt "$S/calls.log" 'issues/99' "CLI: nothing is written to the fork PR"
reset; prlist feat-x 99 true
RC=0; (cd "$TMP/repo" && bash "$SCRIPT_DIR/cr-first-release.sh") >"$TMP/out-arg" 2>&1 || RC=$?
eq "$RC" 2 "CLI: only a fork PR on the branch name is no PR for the caller (exit 2)"
eq "$(posts)$(deletes)" 00 "CLI: only a fork PR on the branch name writes no label"
# a branch named like a PR number is a branch, not PR #42.
git -C "$TMP/other" checkout -q -b 42 2>/dev/null
reset; prlist feat-x 42 false
RC=0; (cd "$TMP/other" && bash "$SCRIPT_DIR/cr-first-release.sh") >"$TMP/out-arg" 2>&1 || RC=$?
eq "$RC" 2 "CLI: a numeric branch name is not read as a PR number (exit 2)"
hasnt "$S/calls.log" '^pr view' "CLI: a numeric branch name makes no pr view call"
eq "$(posts)$(deletes)" 00 "CLI: a numeric branch name writes no label"

# ── a first release: label add only, no unlabel event ────────────────────────
# the remove is attempted every time; it leaves an `unlabeled` event only when ci:go was on the PR.
reset; touch "$S/delete-real"; run first-release
has "$TMP/out-first-release" '^CR-FIRST RELEASE ' "first release: releases with ci:go absent"
eq "$(jq -r '[.[] | .event] | join(",")' "$S/events.json")" labeled "first release: timeline shows labeled only, no unlabeled"
reset; touch "$S/delete-real"; echo '[{"name":"ci:go"}]' > "$S/labels.json"
jq -nc --arg t "2026-10-23T09:00:00Z" '[{event:"labeled",label:{name:"ci:go"},created_at:$t}]' > "$S/events.json"; run re-release
eq "$(jq -r '[.[] | .event] | join(",")' "$S/events.json")" labeled,unlabeled,labeled "re-release over a stale label: unlabeled then labeled"
# a different label whose name merely contains ci:go is not the label: no unlabeled event.
reset; touch "$S/delete-real"; echo '[{"name":"not-ci:go"}]' > "$S/labels.json"; run other-label
eq "$(jq -r '[.[] | .event] | join(",")' "$S/events.json")" labeled "a label named not-ci:go is not ci:go: labeled only"

# ── the ledger CLI ───────────────────────────────────────────────────────────
LCLI="$SCRIPT_DIR/../cr/cr-trigger-ledger.sh"
rm -f "$CR_FIRST_LEDGER" "$CR_FIRST_ALERTS"
printf '{"pr":7,"head":"h7","ts":"2026-10-23T10:00:00Z","reviewers":[],"cheap_settled_at":"2026-10-23T09:59:00Z"}\n' | bash "$LCLI" append >/dev/null 2>&1
bash "$LCLI" has 7 h7 >/dev/null 2>&1 && ok "ledger: has finds an appended line" || bad "ledger: has finds an appended line"
bash "$LCLI" has 7 h8 >/dev/null 2>&1 && bad "ledger: has is per head" || ok "ledger: has is per head"
printf 'not json\n' | bash "$LCLI" append >/dev/null 2>&1 && bad "ledger: append refuses non-JSON" || ok "ledger: append refuses non-JSON"
eq "$(bash "$LCLI" alert-once 'codex|down' 2>/dev/null; echo rc=$?)" "rc=0" "ledger: alert-once first time is new"
eq "$(bash "$LCLI" alert-once 'codex|down' >/dev/null 2>&1; echo rc=$?)" "rc=1" "ledger: alert-once second time is a repeat"
bash "$LCLI" alert-clear codex >/dev/null 2>&1
eq "$(bash "$LCLI" alert-once 'codex|down' >/dev/null 2>&1; echo rc=$?)" "rc=0" "ledger: alert-clear <slug> reopens the slug's alerts"

reset; : > "$S/tok.log"; run T10580-token
writes=$(grep -c -E -- '-X (POST|DELETE)' "$S/tok.log" 2>/dev/null || true)
main_reads=$(grep -E '^main' "$S/tok.log" | grep -v -E -- '-X (POST|DELETE)|variable get|graphql' | cut -c1-90 | tr '\n' '|')
reads_on_read=$(grep -c '^read' "$S/tok.log" 2>/dev/null || true)
eq "$main_reads" "" "T10580 every GET api read this file issues rides the read token (none left on main)"
[ "${reads_on_read:-0}" -ge 4 ] && ok "T10580 the release reads ($reads_on_read) carried the read token" || bad "T10580 only ${reads_on_read:-0} reads carried the read token"
[ "$(grep -E -- '-X (POST|DELETE)' "$S/tok.log" | grep -c '^read' || true)" = 0 ] && ok "T10580 the label writes ($writes) stay on the main token" || bad "T10580 a label write rode the read token"
reset; CR_FIRST_SWITCH_TTL=0 run T10580-sw0a; CR_FIRST_SWITCH_TTL=0 run T10580-sw0b
eq "$(grep -c '^variable get' "$S/calls.log")" 2 "T10580 TTL 0: the switch variable is read on every call"
reset; CR_FIRST_SWITCH_TTL=600 run T10580-sw1a; CR_FIRST_SWITCH_TTL=600 run T10580-sw1b
eq "$(grep -c '^variable get' "$S/calls.log")" 1 "T10580 TTL 600: the second call in the same process reads the cached switch"
reset; rm -f "$S/var"; CR_FIRST_SWITCH_TTL=600 run T10580-sw2a; echo on > "$S/var"; CR_FIRST_SWITCH_TTL=600 run T10580-sw2b
eq "$(grep -c '^variable get' "$S/calls.log")" 2 "T10580 an unreadable switch is never cached: the next call reads it again"
reset; echo off > "$S/var"; CR_FIRST_SWITCH_TTL=600 run T10580-sw3
CR_FIRST_SWITCH_TTL=600 HEAD=deadbeef$HEAD1 run T10580-sw3b; unset HEAD
eq "$(grep -c '^variable get' "$S/calls.log")" 1 "T10580 a readable off switch is cached for the TTL too"

echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
