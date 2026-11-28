#!/usr/bin/env bash
# selector: tree-scan
# test-judge-desk.sh - the judge desk kit (plan task B4): wait, next, claim, record, draft-go and
# the automatic stop, on fixture buckets, fixture transcripts and a fixture git repo. It runs the
# real gen-judge-brief.py --no-persist and the real delta-class.sh; usage-preflight.sh, the clock
# and live-subagents.sh are stubbed through fixture-only seams. No go.sh call; no .locks/go file.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HERE/../../.." && pwd)"
SUT="$HERE/judge-desk.sh"
FX="$HERE/fixtures/judge-desk"
MK="$FX/mk-transcript.py"

fails=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; fails=$((fails + 1)); }
has() { case "$2" in *"$3"*) pass "$1" ;; *) fail "$1 (missing '$3' in '$2')" ;; esac; }
lacks() { case "$2" in *"$3"*) fail "$1 (found '$3')" ;; *) pass "$1" ;; esac; }
eq() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (got '$2', want '$3')"; fi; }
stopped() { if [ -e "$B/judge-desk/STOP" ]; then pass "$1"; else fail "$1 (no STOP file)"; fi; }
notstopped() { if [ -e "$B/judge-desk/STOP" ]; then fail "$1 (STOP written)"; else pass "$1"; fi; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/judge-desk-test.XXXXXX")" || exit 1
trap 'rm -rf "$WORK"' EXIT
export TZ=UTC HIMMEL_TEST_FIXTURE=1
unset JUDGE_DESK_GEN JUDGE_DESK_LIVE JUDGE_DESK_NOW JUDGE_DESK_PREFLIGHT DNOW DSESS
NOW="$(python3 -I -c 'from datetime import datetime, timezone; print(int(datetime(2026, 11, 28, 12, 0, 0, tzinfo=timezone.utc).timestamp()))')"
SINCE=2026-11-28T00:00:00+00:00
S0=11111111-1111-4111-8111-111111111111
S1=22222222-2222-4222-8222-222222222222
SX=33333333-3333-4333-8333-333333333333
AGENT=a1b2c3d4e5f6a7b8
UID_N="$(id -u)"

R="$WORK/repo"; mkdir -p "$R"
(
    cd "$R" && git -c init.defaultBranch=main init -q && git config user.email t@t && git config user.name t \
        && git config commit.gpgsign false && mkdir -p scripts/ci \
        && printf '%s\n' '^scripts/ci/trust\.sh$' > scripts/ci/ci-trust-paths.txt \
        && printf 'l1\nl2\nl3\nl4\nl5\n' > src.txt && echo o > other.txt && echo t > scripts/ci/trust.sh \
        && git add -A && git commit -qm base && git update-ref refs/remotes/origin/main HEAD && : > .git/cr-critic-scores.jsonl \
        && A="$(git rev-parse HEAD)" \
        && git checkout -q -b p1 "$A" && echo j >> other.txt && git commit -qam j1 && git rev-parse HEAD > "$WORK/J1" \
        && echo n >> other.txt && git commit -qam n1 && git rev-parse HEAD > "$WORK/N1" \
        && git checkout -q -b p2 "$A" && echo j >> other.txt && git commit -qam j2 && git rev-parse HEAD > "$WORK/J2" \
        && printf 'L1\nl2\nl3\nl4\nl5\n' > src.txt && git commit -qam n2 && git rev-parse HEAD > "$WORK/N2" \
        && git checkout -q -b p3 "$A" && echo j >> other.txt && git commit -qam j3 && git rev-parse HEAD > "$WORK/J3" \
        && echo n >> scripts/ci/trust.sh && git commit -qam n3 && git rev-parse HEAD > "$WORK/N3"
) >/dev/null 2>&1 || fail "fixture repo"
J1="$(cat "$WORK/J1")"; N1="$(cat "$WORK/N1")"; J2="$(cat "$WORK/J2")"; N2="$(cat "$WORK/N2")"; J3="$(cat "$WORK/J3")"; N3="$(cat "$WORK/N3")"
H="$J1"
HX=9999999999999999999999999999999999999999

CASES=0
C="" B="" PROJ="" DW="" PD=""
newcase() {
    CASES=$((CASES + 1)); C="$WORK/c$CASES"
    B="$C/root/yotamleo/himmel"; PROJ="$C/projects"; DW="$C/deskwt"
    mkdir -p "$B/judge-desk/requests" "$DW" "$C/root/.locks/go"
    PD="$PROJ/$(printf '%s' "$(cd "$DW" && pwd -P)" | sed 's/[^A-Za-z0-9]/-/g')"
    mkdir -p "$PD/$S1/subagents" "$PD/$S0/subagents"
    printf '%s\n%s\n' "$S0" "$S1" > "$B/judge-desk/sessions"
}
D() { ( cd "$R" && JUDGE_DESK_NOW="${DNOW:-$NOW}" bash "$SUT" "$@" --bucket "$B" --projects "$PROJ" --desk-worktree "$DW" --desk-session "${DSESS:-$S1}" --chief chief-fx --since "$SINCE" ); }
stubs() {
    printf '#!/usr/bin/env bash\necho %s\n' "$1" > "$WORK/preflight.sh"
    export JUDGE_DESK_PREFLIGHT="$WORK/preflight.sh"
}
stubs PROCEED
req() {
    python3 -I -c '
import json, sys, os
b, pr, head, lane, doc = sys.argv[1:6]
d = os.path.join(b, "judge-desk")
snap = os.path.join(d, "requests", "%s-%s.md" % (pr, head[:7]))
open(snap, "w").write("snapshot\n")
row = {"schema": 1, "kind": "request", "pr": int(pr), "head": head, "lane": lane, "worker_doc": doc or None, "snapshot": snap,
       "bullet_hhmm": "14:02", "requested_at": "2026-11-28T11:00:00+00:00", "seen_at": "2026-11-28T11:01:00+00:00", "base": None}
open(os.path.join(d, "judge-requests.jsonl"), "a").write(json.dumps(row) + "\n")' "$B" "$1" "$2" "${3:-native}" "${4:-}"
}
spec() {
    python3 -I -c '
import json, sys
f, qid, pr, head, dc = sys.argv[1:6]
s = {"qid": qid, "ticket": "HIMMEL-11268", "question": "Does the change hold?", "reason": "shadow", "prior": "no prior desk judge on this PR",
     "tier": {"category": "design", "reason": "fixture"}, "pr": int(pr), "head": head, "evidence": [{"item": "diff", "for": "the change"}]}
if dc:
    s["delta_class"] = dc
json.dump(s, open(f, "w"))' "$1" "$2" "$3" "$4" "${5:-}"
}
rowf() {
    python3 -I -c '
import json, sys
f, kind, run, key, which = sys.argv[1:6]
rows = []
for l in open(f):
    try:
        r = json.loads(l)
    except ValueError:
        continue
    if r.get("kind") == kind and (run == "-" or r.get("run") == run):
        rows.append(r)
if not rows:
    print("norow"); sys.exit()
v = rows[-1 if which == "last" else 0].get(key, "nokey")
print(v if isinstance(v, str) else json.dumps(v))' "$1" "$2" "$3" "$4" "${5:-last}" 2>/dev/null
}
nrows() { python3 -I -c '
import json, sys, os
f, kind = sys.argv[1:3]
n = 0
if os.path.isfile(f):
    for l in open(f):
        try:
            n += json.loads(l).get("kind") == kind
        except ValueError:
            pass
print(n)' "$1" "$2"; }
RUNS() { printf '%s' "$B/judge-desk/desk-runs.jsonl"; }
RUN="" DJ=""
newrun() {
    local pr="$1" head="$2" l="${3:-a}" dc="${4:-}"
    req "$pr" "$head"
    spec "$C/spec-$pr.json" "dsk$pr$l" "$pr" "$head" "$dc"
    out="$(D claim "$C/spec-$pr.json" 2>"$C/claim.err")"; local rc=$?
    RUN="$(rowf "$(RUNS)" claim - run last)"
    DJ="$B/judge-desk/runs/$RUN/dispatch.json"
    return $rc
}
jtr() {
    python3 -I "$MK" "$PD/${3:-$S1}/subagents/agent-$1.jsonl" "[[\"user_dispatch\",\"$DJ\"]$2]"
}
mt() { python3 -I -c 'import os, sys; os.utime(sys.argv[1], (int(sys.argv[2]), int(sys.argv[2])))' "$1" "$2"; }
GOODREPLY='**GO** for head `'"$H"'`.\n\nChecked the diff; no defect.'

newcase
python3 -I "$MK" "$PD/$SX.jsonl" '[["user","hi"],["text","hello"]]'
out="$(D wait --max-wait 0 2>&1)"; rc=$?
eq "row 1: a transcript whose id is not in the registry exits 3" "$rc" 3
eq "row 1: it prints BLOCKED <path> and nothing else" "$out" "BLOCKED $PD/$SX.jsonl"
stopped "row 1: it writes STOP"
newcase
python3 -I "$MK" "$PD/$S1.jsonl" '[["user","hi"],["text","hello"]]'
out="$(D wait --max-wait 0 2>&1)"; rc=$?
eq "row 1 control: a listed transcript is no stop (rc 0)" "$rc" 0
notstopped "row 1 control: no STOP for a listed id"
newcase
: > "$B/judge-desk/sessions"
python3 -I "$MK" "$PD/$S1.jsonl" '[["user","hi"],["text","hello"]]'
out="$(D wait --max-wait 0 2>&1)"; rc=$?
eq "row 1: a blanked registry is a stop too" "$rc" 3

newcase
req 6139 "$H"
out="$(D wait --max-wait 0 2>&1)"; rc=$?
eq "wait: a request with no desk run returns REQUEST" "$out" REQUEST
newcase
newrun 6139 "$H" a || fail "wait fixture claim: $(cat "$C/claim.err")"
printf '#!/usr/bin/env bash\necho live-subagents=0\nexit 0\n' > "$WORK/live0.sh"
printf '#!/usr/bin/env bash\necho LIVE-SUBAGENT a1 judge-ro x\necho live-subagents=1\nexit 1\n' > "$WORK/live1.sh"
out="$(JUDGE_DESK_LIVE="$WORK/live0.sh" D wait --max-wait 0 2>&1)"
eq "wait: an open claim with no live judge returns ENDED" "$out" ENDED
out="$(JUDGE_DESK_LIVE="$WORK/live1.sh" D wait --max-wait 0 2>&1)"
eq "wait: an open claim with its judge still live waits (TIMEOUT)" "$out" TIMEOUT

newcase
req 6139 "$H"; req 6140 "$J2"
out="$(D next 2>&1)"; rc=$?
eq "row 2: next prints the oldest unclaimed request" "$out" "REQUEST 6139 $H first $B/judge-desk/requests/6139-${H:0:7}.md"
touch "$B/judge-desk/STOP"
out="$(D next 2>&1)"
eq "row 2: STOP present prints STOP" "$out" STOP
newcase
req 6139 "$H"
stubs SKIPPED-BANK
out="$(D next 2>&1)"
has "row 2: a preflight that is not PROCEED holds" "$out" "HOLD"
has "row 2: the hold names the preflight token" "$out" "SKIPPED-BANK"
stubs PROCEED
for n in 1 2 3; do
    printf '{"schema":1,"kind":"claim","run":"7%s-aaaaaaa-1","pr":7%s,"head":"%s","qid":"dsk7%sa","class":"first","model":"claude-opus-5-5","route":"agent","desk_session":"%s","spec_sha256":"x","dispatch_sha256":"x","dispatched_at":"2026-11-28T11:59:00+00:00","lease_until":"2026-11-28T12:19:00+00:00"}\n' "$n" "$n" "$HX" "$n" "$S1" >> "$(RUNS)"
done
out="$(D next 2>&1)"
has "row 2: 3 open claims hold" "$out" "HOLD"
has "row 2: the hold says why" "$out" "3 claims"
newcase
req 6139 "$H"
python3 -I "$MK" "$PD/$S1.jsonl" '[["usage",125000],["text","x"]]'
out="$(D next 2>&1)"
eq "row 2: past the 120K fill prints HOLD hand-off" "$out" "HOLD hand-off"
python3 -I "$MK" "$PD/$S1.jsonl" '[["usage",50000],["text","x"]]'
out="$(D next 2>&1)"
has "row 2 control: under the fill the request is printed" "$out" "REQUEST 6139"

newcase
newrun 6139 "$H" a || fail "row 4: claim failed: $(cat "$C/claim.err")"
disp="$out"
has "row 4: claim prints the Agent input (judge-ro)" "$disp" '"subagent_type": "judge-ro"'
has "row 4: the brief is the no-persist one" "$disp" "Do not run judge-dir.sh or write-verdict.sh"
eq "row 4: run id is <pr>-<head7>-<n>" "$RUN" "6139-${H:0:7}-1"
if [ -f "$B/judge-desk/runs/$RUN/spec.json" ] && [ -f "$DJ" ]; then pass "row 4: spec and dispatch copied into runs/<run>/"; else fail "row 4: runs/<run> files"; fi
eq "row 4: the claim row's qid" "$(rowf "$(RUNS)" claim "$RUN" qid)" "dsk6139a"
eq "row 4: the claim row's class" "$(rowf "$(RUNS)" claim "$RUN" class)" "first"
eq "row 4: the claim row's model" "$(rowf "$(RUNS)" claim "$RUN" model)" "claude-opus-5-5"
eq "row 4: the claim row's route" "$(rowf "$(RUNS)" claim "$RUN" route)" "agent"
eq "row 4: the claim row's desk session" "$(rowf "$(RUNS)" claim "$RUN" desk_session)" "$S1"
eq "row 4: spec sha256" "$(rowf "$(RUNS)" claim "$RUN" spec_sha256)" "$(sha256sum "$B/judge-desk/runs/$RUN/spec.json" | cut -d' ' -f1)"
eq "row 4: dispatch sha256" "$(rowf "$(RUNS)" claim "$RUN" dispatch_sha256)" "$(sha256sum "$DJ" | cut -d' ' -f1)"
lease="$(python3 -I -c '
import json, sys
from datetime import datetime
r = [json.loads(l) for l in open(sys.argv[1])][0]
print(int((datetime.fromisoformat(r["lease_until"]) - datetime.fromisoformat(r["dispatched_at"])).total_seconds()))' "$(RUNS)")"
eq "row 4: a 20-minute lease" "$lease" 1200
out="$(D claim "$C/spec-6139.json" 2>&1)"; rc=$?
eq "row 4: a request already claimed is refused (rc 1)" "$rc" 1
newcase
req 6139 "$H"
spec "$C/spec.json" dsk6139a 6139 "$H" finding
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "{\\"description\\":\\"d\\",\\"subagent_type\\":\\"judge-ro\\",\\"model\\":\\"opus\\",\\"prompt\\":\\"p\\",\\"run_in_background\\":false}"\n' > "$WORK/gen-opus.sh"
out="$(JUDGE_DESK_GEN="$WORK/gen-opus.sh" D claim "$C/spec.json" 2>&1)"; rc=$?
eq "row 4: a printed model the class does not call for is refused (rc 1)" "$rc" 1
eq "row 4: no claim row for the refused model" "$(nrows "$(RUNS)" claim)" 0
spec "$C/spec.json" j6139a 6139 "$H"
out="$(D claim "$C/spec.json" 2>&1)"; rc=$?
eq "row 4: a qid without the dsk prefix is refused (rc 1)" "$rc" 1
spec "$C/spec.json" dsk6139a 6139 "$H"
touch "$B/judge-desk/STOP"
out="$(D claim "$C/spec.json" 2>&1)"; rc=$?
eq "row 4: claim with STOP present is refused (rc 1)" "$rc" 1

newcase
newrun 6139 "$H" a
jtr "$AGENT" ",[\"text\",\"$GOODREPLY\"]"
out="$(D record "$RUN" --agent "$AGENT" 2>&1)"; rc=$?
eq "row 5: a GO reply is RECORDED GO" "$out" "RECORDED $RUN GO"
eq "row 5: rc 0" "$rc" 0
eq "row 5: end outcome" "$(rowf "$(RUNS)" end "$RUN" outcome)" GO
eq "row 5: end agent" "$(rowf "$(RUNS)" end "$RUN" agent)" "$AGENT"
eq "row 5: write_attempted false" "$(rowf "$(RUNS)" end "$RUN" write_attempted)" false
eq "row 5: write_refused null" "$(rowf "$(RUNS)" end "$RUN" write_refused)" null
eq "row 5: prompt_matches true" "$(rowf "$(RUNS)" end "$RUN" prompt_matches)" true
eq "row 5: late false" "$(rowf "$(RUNS)" end "$RUN" late)" false
eq "row 5: cost_eq is a number" "$(rowf "$(RUNS)" end "$RUN" cost_eq | grep -Ec '^[0-9]+$')" 1
eq "row 5: verdict_at is the judge's last message" "$(rowf "$(RUNS)" end "$RUN" verdict_at)" "2026-11-28T10:00:20+00:00"
REPLY="$B/judge-desk/runs/$RUN/reply.md"
eq "row 5: end reply path" "$(rowf "$(RUNS)" end "$RUN" reply)" "$REPLY"
eq "row 5: end reply sha256" "$(rowf "$(RUNS)" end "$RUN" reply_sha256)" "$(sha256sum "$REPLY" | cut -d' ' -f1)"
# shellcheck disable=SC2016  # the backticks are literal verdict-line text
eq "row 5: reply.md is in the verdict-record shape" "$(sed -n '1,5p' "$REPLY")" "$(printf '## Verdict\n\n**GO** for head `%s`.\n\npr: 6139\n' "$H")"
has "row 5: the judge's evidence follows" "$(cat "$REPLY")" "Checked the diff; no defect."

newcase
newrun 6140 "$J2" a
jtr "$AGENT" ",[\"text\",\"**NO-GO** for head \`$J2\`.\\n\\nclass: other\\nfinding: src.txt:1-2\\nfinding: other.txt\\nthe reason\"]"
out="$(D record "$RUN" --agent "$AGENT" 2>&1)"
eq "row 5: a NO-GO reply is RECORDED NO-GO" "$out" "RECORDED $RUN NO-GO"
REPLY="$B/judge-desk/runs/$RUN/reply.md"
has "row 5: the NO-GO reply.md keeps the class line" "$(cat "$REPLY")" "class: other"
has "row 5: the NO-GO reply.md keeps the first finding line" "$(cat "$REPLY")" "finding: src.txt:1-2"
has "row 5: the NO-GO reply.md keeps the second finding line" "$(cat "$REPLY")" "finding: other.txt"
eq "row 5: the NO-GO verdict line" "$(sed -n '3p' "$REPLY")" "**NO-GO** for head \`$J2\`."

newcase
newrun 6139 "$H" a
jtr "$AGENT" ",[\"text\",\"**GO** for head \`$HX\`.\\n\\nwrong head\"]"
out="$(D record "$RUN" --agent "$AGENT" 2>&1)"
eq "row 5: a reply naming another head is unparsed" "$out" "RECORDED $RUN unparsed"
newcase
newrun 6139 "$H" a
jtr "$AGENT" ",[\"text\",\"I could not decide.\"]"
out="$(D record "$RUN" --agent "$AGENT" 2>&1)"
eq "row 5: a reply with no verdict line is unparsed" "$out" "RECORDED $RUN unparsed"

newcase
newrun 6139 "$H" a
python3 -I "$MK" "$PD/$S1/subagents/agent-$AGENT.jsonl" "[[\"user\",\"a different prompt\"],[\"text\",\"$GOODREPLY\"]]"
out="$(D record "$RUN" --agent "$AGENT" 2>&1)"
eq "row 6: a first prompt that differs sets prompt_matches false" "$(rowf "$(RUNS)" end "$RUN" prompt_matches)" false
newcase
newrun 6139 "$H" a
python3 -I -c '
import json, sys
p = sys.argv[1]
d = json.load(open(p)); d["run_in_background"] = True; json.dump(d, open(p, "w"))' "$DJ"
jtr "$AGENT" ",[\"text\",\"$GOODREPLY\"]"
out="$(D record "$RUN" --agent "$AGENT" 2>&1)"
eq "row 6: run_in_background alone differing keeps prompt_matches true" "$(rowf "$(RUNS)" end "$RUN" prompt_matches)" true

newcase
DSESS="$S0" newrun 6139 "$H" a
jtr "$AGENT" ",[\"text\",\"$GOODREPLY\"]" "$S0"
out="$(DSESS="$S1" D record "$RUN" --agent "$AGENT" 2>&1)"
eq "row 7: a successor records a predecessor's run by agent id" "$out" "RECORDED $RUN GO"
eq "row 7: the claim keeps the predecessor's session" "$(rowf "$(RUNS)" claim "$RUN" desk_session)" "$S0"

newcase
newrun 6139 "$H" a
DNOW=$((NOW + 1300)) D next >"$C/next.out" 2>&1
eq "row 8: a claim past its lease is ended lost" "$(rowf "$(RUNS)" end "$RUN" outcome)" lost
has "row 8: the request is claimable again" "$(cat "$C/next.out")" "REQUEST 6139"
jtr "$AGENT" ",[\"text\",\"$GOODREPLY\"]"
out="$(DNOW=$((NOW + 1400)) D record "$RUN" --agent "$AGENT" 2>&1)"
eq "row 8: a later real end is recorded" "$out" "RECORDED $RUN GO"
eq "row 8: it carries late true" "$(rowf "$(RUNS)" end "$RUN" late)" true
eq "row 8: the lost end stays in the ledger" "$(rowf "$(RUNS)" end "$RUN" outcome first)" lost

WV='bash /home/x/scripts/handover/chief-kit/write-verdict.sh dsk6139a GO '"$H"' --pr 6139 --evidence-file /tmp/e.md'
MARK='Exit code 3\nwrite-verdict: refusing - HIMMEL_CONSOLE_JUDGE_NOVERDICT is set (a judge desk writes no verdict); nothing written'
judge_case() {
    newcase; newrun 6139 "$H" a
    jtr "$AGENT" "$1,[\"text\",\"$GOODREPLY\"]"
    out="$(D record "$RUN" --agent "$AGENT" 2>&1)"; rc=$?
}
judge_case ",[\"tool\",\"Bash\",{\"command\":\"$WV\"},\"$MARK\",1]"
eq "row 9: a marker-refused write-verdict.sh is no stop (RECORDED)" "$out" "RECORDED $RUN GO"
eq "row 9: write_attempted true" "$(rowf "$(RUNS)" end "$RUN" write_attempted)" true
eq "row 9: write_refused true" "$(rowf "$(RUNS)" end "$RUN" write_refused)" true
notstopped "row 9: no STOP for a refused write"

judge_case ",[\"tool\",\"Bash\",{\"command\":\"$WV\"},\"Exit code 2\\nusage: something else\",1]"
eq "row 10: a write-verdict.sh that failed without the marker's text is a stop (rc 3)" "$rc" 3
has "row 10: it prints BLOCKED" "$out" "BLOCKED"
stopped "row 10: STOP written"

judge_case ",[\"tool\",\"Bash\",{\"command\":\"$WV\"},\"/home/x/verdicts/dsk6139a/judge.md\",0]"
eq "row 11: a write-verdict.sh that exited 0 is a stop (rc 3)" "$rc" 3
has "row 11: BLOCKED printed" "$out" "BLOCKED"
stopped "row 11: STOP written (NC4)"
judge_case ",[\"tool\",\"Bash\",{\"command\":\"bash /home/x/scripts/api-lane/judge-call.sh --qid dsk6139a --max-budget-usd 2.00\"},\"done\",0]"
eq "row 11: a judge-call.sh that exited 0 is a stop (rc 3)" "$rc" 3
judge_case ",[\"tool\",\"Bash\",{\"command\":\"git diff origin/main -- scripts/handover/chief-kit/write-verdict.sh\"},\"diff text\",0]"
eq "row 11 control: a command that only names write-verdict.sh is no write attempt" "$out" "RECORDED $RUN GO"

judge_case ",[\"tool\",\"Write\",{\"file_path\":\"/tmp/claude-$UID_N/j6139a/evidence.md\",\"content\":\"x\"},\"File created\",0]"
eq "row 12: a judge Write under /tmp/claude-<uid>/j* is a stop (rc 3)" "$rc" 3
stopped "row 12: STOP written (judge Write)"
judge_case ",[\"tool\",\"Bash\",{\"command\":\"bash /home/x/scripts/judge-dir.sh 6139\"},\"/tmp/claude-$UID_N/j6139a\",0]"
eq "row 12: a judge judge-dir.sh call is a stop (rc 3)" "$rc" 3
judge_case ",[\"tool\",\"Write\",{\"file_path\":\"/home/x/other.md\",\"content\":\"x\"},\"hook denied the write\",1]"
eq "row 12: a judge Write elsewhere that a guard denied is no stop" "$out" "RECORDED $RUN GO"
eq "row 12: it is recorded in the end row" "$(rowf "$(RUNS)" end "$RUN" other_writes)" '["/home/x/other.md"]'
newcase
python3 -I "$MK" "$PD/$S1.jsonl" "[[\"user\",\"go\"],[\"tool\",\"Write\",{\"file_path\":\"/tmp/claude-$UID_N/j6139a/x.md\",\"content\":\"x\"},\"ok\",0]]"
out="$(D wait --max-wait 0 2>&1)"; rc=$?
eq "row 12: the desk's own Write under j* is a stop on a wait tick" "$rc" 3
has "row 12: BLOCKED names the desk transcript" "$out" "BLOCKED $PD/$S1.jsonl"
newcase
python3 -I "$MK" "$PD/$S1.jsonl" "[[\"user\",\"go\"],[\"tool\",\"Bash\",{\"command\":\"bash /home/x/scripts/judge-dir.sh 6139\"},\"ok\",0]]"
out="$(D wait --max-wait 0 2>&1)"; rc=$?
eq "row 12: the desk's own judge-dir.sh call is a stop on a wait tick" "$rc" 3

judge_case ",[\"tool\",\"SendMessage\",{\"to\":\"chief-fx\",\"message\":\"done\"},\"sent\",0]"
eq "row 13: a judge SendMessage (even to the chief) is a stop (rc 3)" "$rc" 3
judge_case ",[\"tool\",\"Bash\",{\"command\":\"bash scripts/t3/t3-send.sh thread-1 hello\"},\"sent\",0]"
eq "row 13: a judge t3-send.sh call is a stop (rc 3)" "$rc" 3
newcase
python3 -I "$MK" "$PD/$S1.jsonl" '[["user","go"],["tool","SendMessage",{"to":"some-worker","message":"hi"},"sent",0]]'
out="$(D wait --max-wait 0 2>&1)"; rc=$?
eq "row 13: a desk SendMessage to another recipient is a stop on a wait tick" "$rc" 3
newcase
python3 -I "$MK" "$PD/$S1.jsonl" '[["user","go"],["tool","SendMessage",{"to":"chief-fx","message":"BLOCKED x"},"sent",0]]'
out="$(D wait --max-wait 0 2>&1)"; rc=$?
eq "row 13: a desk SendMessage to the chief is no stop" "$rc" 0
out="$(cd "$R" && bash "$SUT" wait --bucket "$B" --max-wait 0 2>&1)"; rc=$?
eq "row 13: wait without --chief is a usage error (rc 2)" "$rc" 2
newcase; newrun 6139 "$H" a
jtr "$AGENT" ",[\"text\",\"$GOODREPLY\"]"
python3 -I "$MK" "$PD/$S1.jsonl" '[["user","go"],["tool","SendMessage",{"to":"chief-fx","message":"BLOCKED x"},"sent",0]]'
out="$(cd "$R" && JUDGE_DESK_NOW="$NOW" bash "$SUT" record "$RUN" --agent "$AGENT" --bucket "$B" --projects "$PROJ" --desk-worktree "$DW" --desk-session "$S1" --since "$SINCE" 2>&1)"
eq "row 13: record, which names no --chief, does not stop on the desk's own message to its chief" "$out" "RECORDED $RUN GO"

HEXG=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
rec() {
    mkdir -p "$(dirname "$1")"
    # shellcheck disable=SC2016  # the backticks are literal verdict-line text
    printf '# VERDICT x - judge\n\nwriter-session: %s\nwritten-at: 2026-11-28T11:00:00Z\n\n## Verdict\n\n**%s** for head `%s`.\n\npr: 6139\n\nSECRET-EVIDENCE-LINE\nmac: 00\n' "$2" "$3" "$HEXG" > "$1"
    mt "$1" $((NOW - 100))
}
goff() { printf 'pr=6139\nhead=%s\nby=chief\nat=x\n' "$HEXG" > "$1"; mt "$1" "$2"; }
stopcase() {
    out="$(D wait --max-wait 0 2>"$C/err")"; rc=$?
    eq "row 14: $1: rc 3" "$rc" 3
    has "row 14: $1: BLOCKED printed" "$out" "BLOCKED $2"
    stopped "row 14: $1: STOP written"
}
nostop() {
    out="$(D wait --max-wait 0 2>&1)"; rc=$?
    if [ "$rc" = 0 ] && [ ! -e "$B/judge-desk/STOP" ]; then pass "row 14: $1: no stop"; else fail "row 14: $1: stopped (rc $rc: $out)"; fi
}
newcase; mkdir -p "$B/verdicts/dsk1a"
STOPARG="$B/verdicts/dsk1a"; stopcase "a forged verdicts/dsk1a dir" "$STOPARG"
newcase; rec "$B/verdicts/j6139a/judge.md" unknown NO-GO
stopcase "a record with writer-session unknown" "$B/verdicts/j6139a/judge.md"
lacks "row 14: the output contract: no verdict line" "$out" "NO-GO"
lacks "row 14: the output contract: no evidence" "$out" "SECRET-EVIDENCE"
lacks "row 14: the output contract: no pr line" "$out" "pr:"
eq "row 14: the output contract: stdout is exactly the BLOCKED line" "$out" "BLOCKED $B/verdicts/j6139a/judge.md"
newcase; rec "$B/verdicts/j6139a/judge.md" "$S0" GO
stopcase "a record stamped with a listed desk session" "$B/verdicts/j6139a/judge.md"
newcase; goff "$C/root/.locks/go/6139.$HEXG" $((NOW - 300))
stopcase "an unrecorded GO past the grace" "$C/root/.locks/go/6139.$HEXG"
newcase; goff "$C/root/.locks/go/6139.$HEXG" $((NOW - 300)); rec "$B/verdicts/go-pr-6139/chief-go-$HEXG.md" chief-sess GO
nostop "a GO file with its chief-go record under B"
newcase; goff "$C/root/.locks/go/6139.$HEXG" $((NOW - 300)); rec "$C/root/yotamleo/adopted/verdicts/go-pr-6139/chief-go-$HEXG.md" chief-sess GO
nostop "a GO file whose record sits in another bucket of the user"
newcase; goff "$C/root/.locks/go/fix-main-red.6139.$HEXG.123" $((NOW - 300))
nostop "a fix-main-red GO file"
newcase; goff "$C/root/.locks/go/6139.$HEXG" $((NOW - 60))
nostop "a GO file younger than 120 seconds"
newcase; goff "$C/root/.locks/go/6139.$HEXG" $((NOW - 90000))
nostop "a GO file older than the desk start"
newcase; rec "$B/verdicts/j6139a/judge.md" chief-sess GO
nostop "a chief verdict record in the window"
newcase; rec "$B/verdicts/j6139a/judge.md" unknown NO-GO; mt "$B/verdicts/j6139a/judge.md" $((NOW - 90000))
nostop "a record older than the desk start"

DOCD="$WORK/docs"; mkdir -p "$DOCD"
printf '## Results\n\n- 14:00 LIVE — started\n- 14:30 READY 6139 %s GREEN\n- 14:40 LIVE — waiting for the GO\n' "$H" > "$DOCD/ready-later-live.md"
printf '## Results\n\n- 14:30 READY 6139 %s GREEN\n' "$HX" > "$DOCD/ready-other.md"
ends() {
    printf '{"schema":1,"kind":"end","run":"%s","outcome":"%s","agent":"%s","reply":"/x","reply_sha256":"x","verdict_at":"2026-11-28T11:30:00+00:00","write_attempted":false,"write_refused":null,"prompt_matches":true,"cost_eq":1,"late":false}\n' "$1" "$2" "$AGENT" >> "$(RUNS)"
}
GOCOUNT0="$(find "$WORK" -path '*/.locks/go/*' -type f | wc -l | tr -d ' ')"
dg_case() {
    newcase
    req 6139 "$H" native "$1"
    spec "$C/spec.json" dsk6139a 6139 "$H"
    D claim "$C/spec.json" >/dev/null 2>&1
    RUN="$(rowf "$(RUNS)" claim - run last)"
    ends "$RUN" "$2"
    out="$(D draft-go "$RUN" 2>&1)"; rc=$?
}
dg_case "$DOCD/ready-later-live.md" GO
has "row 15: GO plus the newest READY head is GO-DRAFT" "$out" "GO-DRAFT"
has "row 15: the draft carries the go.sh --trust-reviewed line as text" "$out" "go.sh --trust-reviewed dsk6139a 6139 $H"
eq "row 15: the same READY followed by a later LIVE bullet still gives GO-DRAFT (draft row)" "$(rowf "$(RUNS)" draft "$RUN" draft)" GO-DRAFT
eq "row 15: the draft row's go_line" "$(rowf "$(RUNS)" draft "$RUN" go_line | grep -c 'go.sh --trust-reviewed dsk6139a 6139')" 1
dg_case "$DOCD/ready-other.md" GO
eq "row 15: a READY for another head is WAIT-DRAFT" "$out" "WAIT-DRAFT"
eq "row 15: WAIT-DRAFT has no go_line" "$(rowf "$(RUNS)" draft "$RUN" go_line)" null
dg_case "$DOCD/ready-later-live.md" NO-GO
eq "row 15: NO-GO is HOLD-DRAFT" "$out" "HOLD-DRAFT"
eq "row 15: no go.sh call: no file under any fixture .locks/go/" "$(find "$WORK" -path '*/.locks/go/*' -type f | wc -l | tr -d ' ')" "$GOCOUNT0"

delta_case() {
    newcase
    newrun "$1" "$2" a || fail "row 3 claim: $(cat "$C/claim.err")"
    jtr "$AGENT" ",[\"text\",\"$4\"]"
    D record "$RUN" --agent "$AGENT" >/dev/null 2>&1
    req "$1" "$3"
    out="$(D next 2>&1)"; rc=$?
}
delta_case 6150 "$J1" "$N1" "**GO** for head \`$J1\`.\\n\\nfine"
has "row 3: a delta touching nothing a judge named prints none" "$out" "none"
eq "row 3: ... and appends a noop row" "$(rowf "$(RUNS)" noop - delta)" none
eq "row 3: the noop row's judged head" "$(rowf "$(RUNS)" noop - judged_head)" "$J1"
eq "row 3: the noop row's head" "$(rowf "$(RUNS)" noop - head)" "$N1"
lacks "row 3: a noop request is not printed as a request" "$out" "REQUEST 6150 $N1"
out="$(D next 2>&1)"
eq "row 3: a second next adds no second noop row" "$(nrows "$(RUNS)" noop)" 1
delta_case 6151 "$J2" "$N2" "**NO-GO** for head \`$J2\`.\\n\\nclass: other\\nfinding: src.txt:1-2\\nbad"
has "row 3: a delta touching a finding: line prints finding" "$out" "REQUEST 6151 $N2 finding"
eq "row 3: no noop row for a finding delta" "$(nrows "$(RUNS)" noop)" 0
delta_case 6152 "$J3" "$N3" "**GO** for head \`$J3\`.\\n\\nfine"
has "row 3: a trust-list path prints trust" "$out" "REQUEST 6152 $N3 trust"

scan() {
    python3 -I -c '
import re, sys
mode, pat = sys.argv[1], re.compile(sys.argv[2])
write = re.compile(r"(?<![0-9&])>>?(?!&)|\btee\b|open\([^)]*[\x27\x22][aw]b?\+?[\x27\x22]|\bmv\b")
for f in sys.argv[3:]:
    try:
        lines = open(f, encoding="utf-8", errors="replace").read().splitlines()
    except OSError:
        continue
    if any(pat.search(l) and (mode == "names" or write.search(l)) for l in lines):
        print(f)' "$@"
}
tracked=()
while IFS= read -r f; do
    case "$f" in */test-*|*/fixtures/*) continue ;; esac
    tracked+=("$REPO_ROOT/$f")
done < <(git -C "$REPO_ROOT" ls-files scripts)
onlyin() {
    local o="$1" f b ok; shift
    [ -z "$o" ] && return 0
    while IFS= read -r f; do
        b="$(basename "$f")"; ok=0
        for a in "$@"; do [ "$b" = "$a" ] && ok=1; done
        [ "$ok" = 1 ] || return 1
    done <<< "$o"
    return 0
}
RUNPAT='judge-desk/(desk-runs|runs/)'
w="$(scan writers "$RUNPAT" "${tracked[@]}")"
if onlyin "$w" judge-desk.sh; then pass "row 16: only judge-desk.sh writes judge-desk/desk-runs or judge-desk/runs/"; else fail "row 16: other writers of desk-runs or runs/: $w"; fi
cp "$SUT" "$WORK/planted-runs.sh"
# shellcheck disable=SC2016  # planted literal text
printf '%s\n' 'printf x >> "$B/judge-desk/desk-runs.jsonl"' >> "$WORK/planted-runs.sh"
if onlyin "$(scan writers "$RUNPAT" "$WORK/planted-runs.sh")" judge-desk.sh; then fail "row 16: red control, a planted desk-runs append was not flagged"; else pass "row 16: red control, a planted desk-runs append is flagged"; fi
w="$(scan writers 'judge-desk/sessions' "${tracked[@]}")"
if onlyin "$w" headed-arm-worker.sh; then pass "row 16: only headed-arm-worker.sh writes judge-desk/sessions"; else fail "row 16: other writers of sessions: $w"; fi
cp "$SUT" "$WORK/planted-sessions.sh"
# shellcheck disable=SC2016  # planted literal text
printf '%s\n' 'printf x >> "$B/judge-desk/sessions"' >> "$WORK/planted-sessions.sh"
if onlyin "$(scan writers 'judge-desk/sessions' "$WORK/planted-sessions.sh")" headed-arm-worker.sh; then fail "row 16: red control, a planted sessions append was not flagged"; else pass "row 16: red control, a planted sessions append is flagged"; fi
ALLP='judge-desk/(judge-requests|desk-runs|runs/|sessions|STOP)'
names="$(scan names "$ALLP" "${tracked[@]}")"
if onlyin "$names" judge-queue.sh judge-desk.sh judge-desk-compare.py write-verdict.sh headed-arm-worker.sh; then pass "row 16: no script outside the owners names a judge-desk record path"; else fail "row 16: other readers or writers: $names"; fi
cp "$SUT" "$WORK/planted-names.sh"
# shellcheck disable=SC2016  # planted literal text
printf '%s\n' 'cat "$B/judge-desk/STOP"' >> "$WORK/planted-names.sh"
if onlyin "$(scan names "$ALLP" "$WORK/planted-names.sh")" judge-queue.sh judge-desk.sh; then fail "row 16: red control, a planted STOP reader was not flagged"; else pass "row 16: red control, a planted STOP reader is flagged"; fi
other="$(scan names 'judge-desk/(judge-requests|desk-runs|runs/|STOP)' "$REPO_ROOT/scripts/handover/chief-kit/write-verdict.sh" "$REPO_ROOT/scripts/handover/chief-kit/headed-arm-worker.sh")"
eq "row 16: write-verdict.sh and headed-arm-worker.sh name only judge-desk/sessions" "$other" ""
cp "$REPO_ROOT/scripts/handover/chief-kit/write-verdict.sh" "$WORK/write-verdict.sh"
# shellcheck disable=SC2016  # planted literal text
printf '%s\n' 'cat "$B/judge-desk/judge-requests.jsonl"' >> "$WORK/write-verdict.sh"
if [ -z "$(scan names 'judge-desk/(judge-requests|desk-runs|runs/|STOP)' "$WORK/write-verdict.sh")" ]; then fail "row 16: red control, a planted queue read in write-verdict.sh was not flagged"; else pass "row 16: red control, a planted queue read in write-verdict.sh is flagged"; fi

if [ "${#tracked[@]}" -gt 0 ]; then pass "row 16: the tracked script list is not empty"; else fail "row 16: git ls-files listed no script, so every grep above was vacuous"; fi
q="$(scan names 'judge-desk/(desk-runs|runs/)' "$REPO_ROOT/scripts/handover/chief-kit/judge-queue.sh")"
eq "row 16: judge-queue.sh names neither desk-runs nor runs/" "$q" ""
cp "$REPO_ROOT/scripts/handover/chief-kit/judge-queue.sh" "$WORK/judge-queue.sh" || fail "row 16: judge-queue.sh could not be copied for the planted control"
# shellcheck disable=SC2016  # planted literal text
printf '%s\n' 'cat "$B/judge-desk/desk-runs.jsonl"' >> "$WORK/judge-queue.sh"
if [ -z "$(scan names 'judge-desk/(desk-runs|runs/)' "$WORK/judge-queue.sh")" ]; then fail "row 16: red control, a planted desk-runs read in judge-queue.sh was not flagged"; else pass "row 16: red control, a planted desk-runs read in judge-queue.sh is flagged"; fi

newcase
HA=abcdef0000000000000000000000000000000001; HB=abcdef0000000000000000000000000000000002
newrun 6139 "$HA" a || fail "review: the first claim failed"
RA="$RUN"
req 6139 "$HB"; spec "$C/spec-b.json" dsk6139b 6139 "$HB"
D claim "$C/spec-b.json" >/dev/null 2>&1 || fail "review: the second claim failed"
RB="$(rowf "$(RUNS)" claim - run last)"
if [ "$RA" != "$RB" ] && [ "$RA" != norow ] && [ "$RB" != norow ]; then pass "review: two heads of one PR sharing seven hex characters get distinct run ids ($RA, $RB)"; else fail "review: run id collision ($RA, $RB)"; fi

dg_case "$DOCD/ready-later-live.md" GO
touch "$B/judge-desk/STOP"
out="$(D draft-go "$RUN" 2>&1)"; rc=$?
eq "review: draft-go with STOP present is refused (rc 1)" "$rc" 1

judge_case ",[\"tool\",\"Bash\",{\"command\":\"if true; then $WV; fi\"},\"done\",0]"
eq "review: a write-verdict.sh call inside an if is a stop (rc 3)" "$rc" 3
judge_case ",[\"tool\",\"Bash\",{\"command\":\"echo 'see; bash judge-dir.sh 1'\"},\"see; bash judge-dir.sh 1\",0]"
eq "review: a quoted mention of judge-dir.sh is no call" "$out" "RECORDED $RUN GO"
judge_case ",[\"tool\",\"Bash\",{\"command\":\"$WV\"},\"HIMMEL_CONSOLE_JUDGE_NOVERDICT is set (a judge desk writes no verdict) quoted\",0]"
eq "review: the marker text in a successful result is no refusal (rc 3)" "$rc" 3

newcase
out="$(cd "$R" && bash "$SUT" wait --bucket "$B" --chief chief-fx --max-wait 0 2>&1)"; rc=$?
eq "review: wait without --since is a usage error (rc 2)" "$rc" 2

newcase; goff "$C/root/.locks/go/6139.$HEXG" $((NOW - 300)); mkdir -p "$B/verdicts/go-pr-6139/chief-go-$HEXG.md"
stopcase "a chief-go path that is a directory is no record" "$C/root/.locks/go/6139.$HEXG"

if [ "$(id -u)" != 0 ]; then
    newcase; mkdir -p "$B/verdicts"; chmod 000 "$B/verdicts"
    out="$(D wait --max-wait 0 2>&1)"; rc=$?
    chmod 755 "$B/verdicts"
    eq "review: an unreadable verdicts dir is a stop, not an empty one (rc 3)" "$rc" 3
fi

judge_case ",[\"tool\",\"Bash\",{\"command\":\"printf '%s\\\\n' '(' judge-dir.sh ')'\"},\"(\\\\njudge-dir.sh\\\\n)\",0]"
eq "review: a quoted parenthesis token is not a command separator" "$out" "RECORDED $RUN GO"
judge_case ",[\"tool\",\"Bash\",{\"command\":\"$WV; $WV\"},\"$MARK\",1]"
eq "review: one marker refusal does not clear two write-verdict.sh calls (rc 3)" "$rc" 3
judge_case ",[\"tool\",\"Bash\",{\"command\":\"$WV; $WV\"},\"$MARK\\\\n$MARK\",1]"
eq "review: a marker refusal per call is no stop" "$out" "RECORDED $RUN GO"
judge_case ",[\"tool\",\"Bash\",{\"command\":\"$WV\"},\"Exit code 3\\\\nHIMMEL_CONSOLE_JUDGE_NOVERDICT is set (a judge desk writes no verdict) text\",0]"
eq "review: an exit-0 result that only reads like a refusal is a stop (rc 3)" "$rc" 3

newcase
DSESS="$S0" newrun 6139 "$H" a || fail "review: the predecessor claim failed"
out="$(JUDGE_DESK_LIVE="$WORK/live0.sh" D wait --max-wait 0 2>&1)"
eq "review: wait returns ENDED for a predecessor session's finished judge" "$out" ENDED

printf '\n%d failure(s)\n' "$fails"
[ "$fails" -eq 0 ]
