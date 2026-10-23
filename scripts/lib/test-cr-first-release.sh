#!/usr/bin/env bash
# shellcheck disable=SC2015
# Tests for scripts/lib/cr-first-release.sh and scripts/cr/cr-trigger-ledger.sh
# Hermetic: gh and curl are stubs driven by files in $S, so a
# label write is recorded and the next call reads it back from the stubbed
# timeline, exactly as GitHub would answer. CodeRabbit status rows are the real
# captures in scripts/ci/fixtures/cr-first-measure-bundle.jsonl (cr-first-measure
# --dump), re-wearing the bot identity the statuses API carries; the rate-limit
# comment is the real PR 3215 reply.
set -uo pipefail

unset ARMAUTOMERGE CR_MERGE_GATE_OK HIMMEL_CONSOLE_DOC CR_FIRST_NOW CR_FIRST_STUCK_AFTER_S \
      CR_FIRST_PROGRESS_S CR_FIRST_STATUS_URL CR_FIRST_CHEAP_RE CR_FIRST_HEAVY_RE \
      CRITICS_JSON CR_PROFILE

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUNDLE="$SCRIPT_DIR/../ci/fixtures/cr-first-measure-bundle.jsonl"
RL_COMMENTS="$SCRIPT_DIR/fixtures/cr-ratelimit/pr-3215-comments.json"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/crfirst.XXXXXX")" || exit 1
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home"; mkdir -p "$HOME"
S="$TMP/state"; mkdir -p "$S"
export GH_STUB_STATE="$S"
export CR_FIRST_LEDGER="$TMP/release-ledger.jsonl" CR_FIRST_ALERTS="$TMP/release-alerts"

# ── stub gh / curl ───────────────────────────────────────────────────────────
mkdir -p "$TMP/bin"
cat > "$TMP/bin/gh" <<'EOF'
#!/usr/bin/env bash
S="${GH_STUB_STATE:?}"
echo "$*" >> "$S/calls.log"
J="$*"; A="${J//--paginate /}"
f() { [ -f "$S/$1" ] && cat "$S/$1" || echo "${2:-[]}"; }
case "$A" in
  "variable get CI_GO_GATE"*) [ -f "$S/var" ] || { echo "could not find variable" >&2; exit 1; }; cat "$S/var"; exit 0 ;;
  *graphql*) f threads.json '{"data":{"repository":{"pullRequest":{"reviewThreads":{"pageInfo":{"hasNextPage":false},"nodes":[]}}}}}'; exit 0 ;;
  *"-X DELETE "*"/labels/ci:go"*) [ -f "$S/delete-fail" ] && exit 1; exit 0 ;;
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
  "api repos/o/r/issues/"*"/comments"*) [ -f "$S/comments-fail" ] && exit 1; f comments.json; exit 0 ;;
  "api repos/o/r/commits/"*"/check-runs"*) f checks.json '{"check_runs":[]}'; exit 0 ;;
  "api repos/o/r/commits/"*"/statuses"*) : > "$S/gate-began"; f statuses.json; exit 0 ;;
  "api repos/o/r/commits/"*) f commit.json '{}'; exit 0 ;;
  "pr view"*) echo "42 0000000000000000000000000000000000000000"; exit 0 ;;
esac
echo '{}'
EOF
cat > "$TMP/bin/curl" <<'EOF'
#!/usr/bin/env bash
S="${GH_STUB_STATE:?}"
echo "curl $*" >> "$S/calls.log"
[ -f "$S/statuspage-fail" ] && exit 22
cat "$S/statuspage.json" 2>/dev/null || echo '{"status":{"indicator":"none"}}'
EOF
chmod +x "$TMP/bin/gh" "$TMP/bin/curl"
export PATH="$TMP/bin:$PATH"

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

# reset — the clean default: switch on, open non-fork PR at HEAD1, cheap green,
# no heavy job, no release event, CodeRabbit completed, no threads, both critics ok.
reset() {
  rm -rf "$S"; mkdir -p "$S"; : > "$S/calls.log"; rm -f "$CR_FIRST_LEDGER" "$CR_FIRST_ALERTS"
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
ls "$TMP/repo/.git"/cr-first-release.42.lock >/dev/null 2>&1 && ok "release: per-PR lock file in the git common dir" || bad "release: per-PR lock file in the git common dir"
p1 release-clean
# RL7 — a second call at the same head: no second pair (the timeline now shows the event).
run RL7-second
eq "$(deletes)/$(posts)" 1/1 "RL7 two calls at one head: still one pair"
eq "$(ledger_lines)" 1 "RL7 two calls at one head: still one ledger line"
# RL4 — a late CodeRabbit finding after the release does not undo it or fire a second pair.
threads "$(thread false portable-timeout.sh 24)"; run RL4-late-finding
eq "$(deletes)/$(posts)" 1/1 "RL4 late finding: release unchanged, no second pair"

# RL8 — a manual ci:go at the head, then a leg event: no second pair.
reset; jq -c '. + [{event:"labeled",label:{name:"ci:go"},created_at:"2026-10-23T10:05:00Z"}]' "$S/events.json" > "$S/e.tmp" && mv "$S/e.tmp" "$S/events.json"; run RL8-manual
eq "$(deletes)/$(posts)" 0/0 "RL8 manual ci:go at the head: no pair"
eq "$(ledger_lines)" 0 "RL8 manual ci:go: no ledger line (it is a manual release)"
# already released by a heavy job at the head (a ci.yml pull_request run started one).
reset; checks success '[{"name":"bun-suites","status":"completed","conclusion":"success","completed_at":"2026-10-23T10:20:00Z"}]'; run released-by-heavy-job
eq "$(deletes)/$(posts)" 0/0 "heavy job already ran at the head: no pair"
# ...a SKIPPED heavy job is not a release.
reset; checks success '[{"name":"bun-suites","status":"completed","conclusion":"skipped","completed_at":"2026-10-23T10:01:00Z"}]'; run heavy-skipped-not-released
eq "$(deletes)/$(posts)" 1/1 "skipped heavy job is not a release: one pair"
# ...a QUEUED heavy job (no conclusion yet) is not proof the head ran.
reset; checks success '[{"name":"bun-suites","status":"queued","conclusion":null,"completed_at":null}]'; run heavy-queued-not-released
eq "$(deletes)/$(posts)" 1/1 "queued heavy job is not a release: one pair"
# ...an in-progress one is.
reset; checks success '[{"name":"bun-suites","status":"in_progress","conclusion":null,"completed_at":null}]'; run heavy-running-released
eq "$(deletes)/$(posts)" 0/0 "in-progress heavy job already ran at the head: no pair"
# a label event older than the head's own checks belongs to an earlier life of the commit.
reset; jq -c '. + [{event:"labeled",label:{name:"ci:go"},created_at:"2026-10-23T10:05:00Z"}]' "$S/events.json" > "$S/e.tmp" && mv "$S/e.tmp" "$S/events.json"
checks success '[{"name":"lint","status":"completed","conclusion":"success","started_at":"2026-10-23T10:08:00Z","completed_at":"2026-10-23T10:08:30Z"}]'; run old-label-before-head-checks
eq "$(deletes)/$(posts)" 1/1 "a ci:go event before the head's first check started does not release the head"
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
has "$TMP/out-RL11-cheap-pending" '^CR-FIRST HOLD cheap-pending ' "RL11 ci-quick pending: HOLD cheap-pending"
eq "$(deletes)/$(posts)" 0/0 "RL11 ci-quick pending: no label"
hasnt "$S/calls.log" 'statuses|graphql' "RL11 ci-quick pending: the reviewer gate is not read yet"
checks success; run RL11-cheap-green
has "$TMP/out-RL11-cheap-green" '^CR-FIRST RELEASE ' "RL11 ci-quick green: release"
eq "$(deletes)/$(posts)" 1/1 "RL11 ci-quick green: one pair"
reset; checks none; run R2-cheap-not-reported
has "$TMP/out-R2-cheap-not-reported" '^CR-FIRST HOLD cheap-pending ' "R2 ci-quick not reported yet: HOLD cheap-pending"
reset; checks skipped; run R2-cheap-skipped
has "$TMP/out-R2-cheap-skipped" '^CR-FIRST HOLD cheap-pending ' "R2 ci-quick skipped is not a pass: HOLD cheap-pending"
eq "$(deletes)/$(posts)" 0/0 "R2 ci-quick skipped: no label"
reset; checks failure; run R3-cheap-red
has "$TMP/out-R3-cheap-red" '^CR-FIRST HOLD cheap-red ' "R3 cheap side red: HOLD cheap-red"
eq "$(deletes)/$(posts)" 0/0 "R3 cheap side red: no label"
eq "$(grep -c '^CR-FIRST HOLD' "$TMP/out-R3-cheap-red")" 1 "R3 cheap side red: no hold line beyond cheap-red"

# ── the reviewer gate at release (R-3595a-d, R1, R4-R8, RL1, RL3, RL6) ───────
# The real PR 3222 "Review in progress" status is the newest once the two later
# statuses are dropped; the clock sits two minutes after it, inside the stuck bound.
PEND_AT=$(iso_to_epoch "$(real_statuses 2 | jq -r '.[0].created_at')")
stuck_reset() { reset; real_statuses 2 >"$S/statuses.json"; jq -nc --arg h "$HEAD1" '{sha:$h,commit:{committer:{date:"2026-10-19T18:00:00Z"}}}' > "$S/commit.json"; echo '[]' > "$S/comments.json"; }
# R-3595a — the real "Review in progress" capture, codex pass, cheap green: HOLD (rev 6 gave GO).
stuck_reset; export CR_FIRST_NOW=$((PEND_AT + 120)); run R-3595a-in-progress
has "$TMP/out-R-3595a-in-progress" '^CR-FIRST HOLD coderabbit in-progress ' "R-3595a real pending capture: HOLD coderabbit in-progress"
eq "$(deletes)/$(posts)" 0/0 "R-3595a real pending capture: no label"
# R1 — pending, then the real completed status, 0 threads: hold, then GO on the status change.
real_statuses 0 > "$S/statuses.json"; run R1-completed
has "$TMP/out-R1-completed" '^CR-FIRST RELEASE ' "R1 pending then completed: GO on the status change"
eq "$(deletes)/$(posts)" 1/1 "R1 one pair"
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
CONSOLE="$TMP/x-console.md"; printf '# console\n\n## Results (newest at the bottom)\n' > "$CONSOLE"
reset; led "$(av "$HEAD1" codex unavailable critic-skipped 'refused: no ANTHROPIC_API_KEY and no key file')" "$(av "$HEAD1" claude ok)"
export HIMMEL_CONSOLE_DOC="$CONSOLE"
for pr in 42 43 44; do
  RC=0; cr_first_release "$pr" "$HEAD1" o/r >"$TMP/out-RL13-$pr" 2>&1 || RC=$?
  jq -c --argjson n "$pr" '.number = $n' "$S/pull.json" > /dev/null
done
eq "$(cat "$TMP"/out-RL13-4[234] | grep -c '^CR-FIRST HOLD hard-unavailable codex')" 3 "RL13 hard lane down on 3 PRs: 3 hold lines"
eq "$(cat "$TMP"/out-RL13-4[234] | grep -c '^CR-FIRST ALERT')" 1 "RL13 one fleet alert on stdout"
eq "$(grep -c 'CR-FIRST ALERT' "$CONSOLE")" 1 "RL13 one console bullet"
has "$CONSOLE" 'restore.*critics\.local\.json.*"mode":"best-effort".*"drop":true.*manual ci:go' "RL13 alert names the levers in order"
hasnt "$CONSOLE" '>' "RL13 the console bullet carries no >"
eq "$(posts)" 0 "RL13 no label while the hard lane is down"
# the outage ends (codex passes again): the dedup entry clears, a later outage alerts again.
led "$(av "$HEAD1" codex ok)" "$(av "$HEAD1" claude ok)"; run RL13-recovered
led "$(av "$HEAD1" codex unavailable critic-skipped 'refused: no ANTHROPIC_API_KEY and no key file')" "$(av "$HEAD1" claude ok)"; : > "$S/events.json"; echo '[]' > "$S/events.json"
run RL13-again
eq "$(grep -c 'CR-FIRST ALERT' "$CONSOLE")" 2 "RL13 a new outage after recovery alerts again"
# M3' — no console doc: the hold line is still printed and nothing fails.
reset; led "$(av "$HEAD1" codex unavailable critic-skipped 'refused: no ANTHROPIC_API_KEY and no key file')" "$(av "$HEAD1" claude ok)"
unset HIMMEL_CONSOLE_DOC; run M3p-no-console
has "$TMP/out-M3p-no-console" '^CR-FIRST HOLD hard-unavailable codex ' "M3' no console: hold line printed"
hasnt "$TMP/out-M3p-no-console" 'CR-FIRST ERROR' "M3' no console: nothing errors"
eq "$RC" 1 "M3' no console: a hold, not a failure"

# ── the stuck-CodeRabbit probe (OQ2, decision 209) ───────────────────────────
# S1 — pending under the bound: hold, and no probe reads at all.
stuck_reset; export CR_FIRST_NOW=$((PEND_AT + 300)); run S1-under-bound
has "$TMP/out-S1-under-bound" '^CR-FIRST HOLD coderabbit in-progress ' "S1 under the bound: HOLD"
hasnt "$S/calls.log" 'issues/42/comments|^curl' "S1 under the bound: the probe does not run"
# S2 — past the bound, a rate-limit comment: release loudly as best-effort.
stuck_reset; cp "$RL_COMMENTS" "$S/comments.json"; jq -nc --arg h "$HEAD1" '{sha:$h,commit:{committer:{date:"2026-10-19T18:00:00Z"}}}' > "$S/commit.json"
export CR_FIRST_NOW=$((PEND_AT + 2000)); run S2-rate-limit
has "$TMP/out-S2-rate-limit" '^CR-FIRST RELEASE coderabbit-stuck .*rate.?limit' "S2 past the bound + rate-limit comment: loud release"
eq "$(deletes)/$(posts)" 1/1 "S2 one pair"
# S3 — past the bound, CodeRabbit is still active (a comment edited a minute ago), service ok: keep holding.
stuck_reset; jq -nc --arg t "$(epoch_to_iso $((PEND_AT + 1950)))" '[{user:{id:136622811,login:"coderabbitai[bot]",type:"Bot"},created_at:"2026-10-19T18:16:00Z",updated_at:$t,body:"Walkthrough in progress"}]' > "$S/comments.json"
export CR_FIRST_NOW=$((PEND_AT + 2000)); run S3-progressing
has "$TMP/out-S3-progressing" '^CR-FIRST HOLD coderabbit in-progress ' "S3 still progressing: keep holding"
eq "$(deletes)/$(posts)" 0/0 "S3 still progressing: no label"
# S4 — past the bound, quiet, and the status page reports an incident: release.
stuck_reset; echo '{"status":{"indicator":"major","description":"Partial System Outage"}}' > "$S/statuspage.json"
jq -nc '[{user:{id:136622811,login:"coderabbitai[bot]",type:"Bot"},created_at:"2026-10-19T18:16:00Z",updated_at:"2026-10-19T18:16:00Z",body:"Walkthrough"}]' > "$S/comments.json"
export CR_FIRST_NOW=$((PEND_AT + 2000)); run S4-status-page
has "$TMP/out-S4-status-page" '^CR-FIRST RELEASE coderabbit-stuck .*status' "S4 status page not ok: loud release"
# S5 — past the bound and quiet for longer than the progress window: release (no recent activity).
stuck_reset; jq -nc '[{user:{id:136622811,login:"coderabbitai[bot]",type:"Bot"},created_at:"2026-10-19T18:16:00Z",updated_at:"2026-10-19T18:16:00Z",body:"Walkthrough"}]' > "$S/comments.json"
export CR_FIRST_NOW=$((PEND_AT + 2000)); run S5-no-activity
has "$TMP/out-S5-no-activity" '^CR-FIRST RELEASE coderabbit-stuck .*no activity' "S5 no CodeRabbit activity inside the window: loud release"
# S6 — the probe cannot read: hold, never release.
stuck_reset; touch "$S/comments-fail"; export CR_FIRST_NOW=$((PEND_AT + 2000)); run S6-probe-read-fails
has "$TMP/out-S6-probe-read-fails" '^CR-FIRST HOLD ' "S6 probe read failure: HOLD"
eq "$(deletes)/$(posts)" 0/0 "S6 probe read failure: no label"
# S7 — the status page is unreachable but the comments say rate limit: the status page is one signal, not a gate.
stuck_reset; cp "$RL_COMMENTS" "$S/comments.json"; touch "$S/statuspage-fail"; export CR_FIRST_NOW=$((PEND_AT + 2000)); run S7-status-page-down
has "$TMP/out-S7-status-page-down" '^CR-FIRST RELEASE coderabbit-stuck ' "S7 status page unreachable: other signals still release"
# S8 — a thread is open as well: the in-progress hold is not the sole hold, the probe does not release.
stuck_reset; cp "$RL_COMMENTS" "$S/comments.json"; threads "$(thread false x.sh 1)"; export CR_FIRST_NOW=$((PEND_AT + 2000)); run S8-other-hold
has "$TMP/out-S8-other-hold" '^CR-FIRST HOLD .*unresolved CodeRabbit thread' "S8 another hold present: still holds"
eq "$(deletes)/$(posts)" 0/0 "S8 another hold present: the probe never releases"
# S9 — the bound is configurable.
stuck_reset; cp "$RL_COMMENTS" "$S/comments.json"; export CR_FIRST_NOW=$((PEND_AT + 400)) CR_FIRST_STUCK_AFTER_S=300; run S9-bound-env
has "$TMP/out-S9-bound-env" '^CR-FIRST RELEASE coderabbit-stuck ' "S9 CR_FIRST_STUCK_AFTER_S moves the bound"
unset CR_FIRST_STUCK_AFTER_S

# ── read-only mode (ready-check.sh) ──────────────────────────────────────────
reset; CR_FIRST_READONLY=1 run readonly-pass
has "$TMP/out-readonly-pass" '^CR-FIRST PENDING-RELEASE ' "read-only: a passing gate says it would release"
eq "$(deletes)/$(posts)/$(ledger_lines)" 0/0/0 "read-only: no label write, no ledger line"
reset; checks pending; CR_FIRST_READONLY=1 run readonly-hold
has "$TMP/out-readonly-hold" '^CR-FIRST HOLD cheap-pending ' "read-only: a hold still prints"
# a hard lane that is down raises no alert in read-only mode: the once-per-outage
# key stays for the tick sweep and the console doc is not written.
RO_CONSOLE="$TMP/ro-console.md"; printf '# console\n\n## Results (newest at the bottom)\n' > "$RO_CONSOLE"
reset; led "$(av "$HEAD1" codex unavailable critic-skipped 'refused: no ANTHROPIC_API_KEY and no key file')" "$(av "$HEAD1" claude ok)"
HIMMEL_CONSOLE_DOC="$RO_CONSOLE" CR_FIRST_READONLY=1 run readonly-hard-down
has "$TMP/out-readonly-hard-down" '^CR-FIRST HOLD hard-unavailable codex ' "read-only hard lane down: the hold still prints"
eq "$(grep -c 'CR-FIRST ALERT' "$RO_CONSOLE")/$([ -s "$CR_FIRST_ALERTS" ] && echo alerts || echo none)" 0/none "read-only hard lane down: no console bullet, no alert key consumed"

# ── the console tick's sweep (event point 5) ─────────────────────────────────
sweep() { printf '%b' "$1" | cr_first_sweep o/r >"$TMP/out-sweep" 2>/dev/null; }
reset; echo off > "$S/var"; sweep "42\t$HEAD1\t\n"
eq "$(wc -c < "$TMP/out-sweep" | tr -d ' ')/$(grep -c 'pulls\|check-runs' "$S/calls.log")" 0/0 "sweep switch off: no output and no PR read"
reset; checks pending; sweep "42\t$HEAD1\t\n"
has "$TMP/out-sweep" '^crfirst=#42:cheap-pending:[0-9]+[smhd]$' "sweep: a held head is listed with reason and age"
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

echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
