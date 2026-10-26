#!/usr/bin/env bash
# scripts/eval/fold-vs-keep/test-fold-vs-keep.sh - suite for the fold-vs-keep eval: the
# frozen task sets and key, fvk.py's run parser, leak scan, publisher rows and decision
# rule, and run.sh driven by a stub claude and a stub bank-preflight on a throwaway git
# repo. No model call, no VM, no live transcript.
set -u
export HIMMEL_BILLED_OK=1   # stub claude only; run.sh refuses a bare run

HERE="$(cd "$(dirname "$0")" && pwd)"
FVK="$HERE/fvk.py"
RUN="$HERE/run.sh"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/fold-vs-keep-test.XXXXXX")" || { echo "test-fold-vs-keep: mktemp -d failed" >&2; exit 1; }
trap 'rm -rf "$TMP"' EXIT

PASS=0; FAIL=0
pass() { PASS=$((PASS + 1)); echo "PASS $1"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL $1"; }
eq() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1: expected '$3', got '$2'"; fi; }
has() { case "$2" in *"$3"*) pass "$1";; *) fail "$1: '$3' not in '$2'";; esac; }
hasnt() { case "$2" in *"$3"*) fail "$1: '$3' found";; *) pass "$1";; esac; }

command -v python3 >/dev/null 2>&1 || { echo "SKIP test-fold-vs-keep: python3 not on PATH"; exit 0; }
command -v git >/dev/null 2>&1 || { echo "SKIP test-fold-vs-keep: git not on PATH"; exit 0; }

jget() { python3 -c 'import json,sys
v=json.load(open(sys.argv[1]))
for k in sys.argv[2].split("/"): v=v[int(k)] if isinstance(v,list) else v.get(k)
print(json.dumps(v) if isinstance(v,(dict,list,bool)) or v is None else v)' "$1" "$2"; }

# --- the frozen task sets: >= 10 golden tasks per class, every scored task keyed ---
for cls in judge vm publisher; do
    n="$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))["tasks"]))' "$HERE/fixtures/tasks/$cls.json" 2>/dev/null || echo 0)"
    if [ "$n" -ge 10 ]; then pass "fixtures: $cls has $n golden tasks"; else fail "fixtures: $cls has $n golden tasks, needs 10"; fi
done
for cls in judge vm; do
    eq "fixtures: every $cls task has a truth in the key" "$(python3 -c 'import json,sys
t=json.load(open(sys.argv[1]))["tasks"]; k=json.load(open(sys.argv[2])).get(sys.argv[3], {})
print(",".join(x["id"] for x in t if k.get(x["id"], {}).get("truth") is None) or "ok")' "$HERE/fixtures/tasks/$cls.json" "$HERE/fixtures/key/truth.json" "$cls" 2>&1)" "ok"
done
eq "fixtures: every vm task has its proof script" "$(python3 -c 'import json,os,sys
t=json.load(open(sys.argv[1]))["tasks"]
print(",".join(x["id"] for x in t if not os.path.isfile(os.path.join(sys.argv[2], x["id"] + ".sh"))) or "ok")' "$HERE/fixtures/tasks/vm.json" "$HERE/fixtures/tasks/vm-scripts" 2>&1)" "ok"
eq "fixtures: every judge task's substitution hits its brief" "$(python3 -c 'import json,sys
t=json.load(open(sys.argv[1]))["tasks"]
print(",".join(x["id"] for x in t for o, _ in x.get("subs", []) if o not in x["brief"]) or "ok")' "$HERE/fixtures/tasks/judge.json" 2>&1)" "ok"

# --- a throwaway repo: main A, PR head B, a later main commit C, a later PR commit D ---
R="$TMP/repo"
git init -q -b main "$R"
git -C "$R" config user.email t@example.invalid; git -C "$R" config user.name t
echo base >"$R/f.txt"; git -C "$R" add f.txt; git -C "$R" commit -qm A
A="$(git -C "$R" rev-parse HEAD)"
git -C "$R" checkout -qb feat
echo pr-change >>"$R/f.txt"; git -C "$R" commit -qam B
B="$(git -C "$R" rev-parse HEAD)"
echo later-fix >>"$R/f.txt"; git -C "$R" commit -qam D
D="$(git -C "$R" rev-parse HEAD)"
git -C "$R" checkout -q main
echo main-later >"$R/g.txt"; git -C "$R" add g.txt; git -C "$R" commit -qm C
git -C "$R" update-ref refs/remotes/origin/main HEAD

FX="$TMP/fixtures"; mkdir -p "$FX/tasks/vm-scripts" "$FX/key"
python3 -c 'import json,sys
r, a, b, fx = sys.argv[1:5]
brief = "Judge it. Repo %s at head %s. Delta at /gone/scratch/delta.diff. Prior verdict in /gone/verdicts/X/." % (r, b)
tasks = [dict(id=t, pr=1, head=b, repo=r, brief=brief,
              subs=[["/gone/scratch/delta.diff", "{w}/delta.diff"], ["/gone/verdicts/", "{w}/prior/"]],
              evidence={"prior/X/judge.md": "prior NO-GO"}, diffs=[[a, b, "delta.diff"]]) for t in ("t1", "t2")]
json.dump(dict(cls="judge", arms=dict(keep="opus judge-ro", fold="sonnet judge-ro"), tasks=tasks), open(fx + "/tasks/judge.json", "w"))
json.dump(dict(judge=dict(t1=dict(truth="GO"), t2=dict(truth="NO-GO")), vm=dict(v1=dict(truth="PASS"))), open(fx + "/key/truth.json", "w"))' \
    "$R" "$A" "$B" "$FX"
mkdir -p "$TMP/agents/.claude/agents"
printf -- '---\nname: judge-ro\ndescription: read-only judge\ntools: Read, Grep, Glob, Bash\nmodel: opus\n---\nYou judge.\n' \
    >"$TMP/agents/.claude/agents/judge-ro.md"
# run.sh reads judge-ro.md from --repo; the fixture repo carries a copy.
mkdir -p "$R/.claude/agents"; cp "$TMP/agents/.claude/agents/judge-ro.md" "$R/.claude/agents/"

# stub claude: logs argv, cwd and a tree probe; replies per model from STUB_<model>.
cat >"$TMP/stub-claude.sh" <<'SH'
#!/usr/bin/env bash
model=""; prev=""; agents=""
for a in "$@"; do
    [ "$prev" = --model ] && model="$a"
    [ "$prev" = --agents ] && agents="$a"
    prev="$a"
done
n=$(( $(cat "$STUB_LOG/count" 2>/dev/null || echo 0) + 1 )); echo "$n" >"$STUB_LOG/count"
printf '%s\n' "$@" >"$STUB_LOG/argv.$n"
printf '%s\n' "$agents" >"$STUB_LOG/agents.$n"
pwd >"$STUB_LOG/cwd.$n"
ls "${HIMMEL_VM_LOCK_DIR:-/nonexistent}" >"$STUB_LOG/locks.$n" 2>&1
git rev-parse HEAD >"$STUB_LOG/head.$n" 2>&1
git rev-parse refs/remotes/origin/main >"$STUB_LOG/base.$n" 2>&1
git cat-file -t "$STUB_LATER" >"$STUB_LOG/later.$n" 2>&1
bundle="$(printf '%s\n' "$@" | sed -n 's/.*bundled the PR head on this host for you: \([^ ]*\) .*/\1/p')"
[ -z "$bundle" ] || git bundle list-heads "$bundle" | tr '\n' '|' >"$STUB_LOG/bundle.$n"
reply_var="STUB_$model"; reply="${!reply_var:-**GO**}"
python3 -c 'import json,sys
reply, leak = sys.argv[1], sys.argv[2]
if leak:
    print(json.dumps({"type":"assistant","message":{"id":"m1","content":[{"type":"tool_use","id":"t1","name":"Read","input":{"file_path":leak}}]}}))
    print(json.dumps({"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t1","is_error":False,"content":"x"}]}}))
print(json.dumps({"type":"assistant","message":{"id":"m2","content":[{"type":"tool_use","id":"t2","name":"Bash","input":{"command":"gh pr diff 1"}}]}}))
print(json.dumps({"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t2","is_error":True,"content":"Permission to use Bash with command gh pr diff 1 has been denied."}]}}))
print(json.dumps({"type":"result","subtype":"success","is_error":False,"duration_ms":1500,"num_turns":2,"total_cost_usd":0.1,
  "usage":{"input_tokens":100,"cache_creation_input_tokens":1000,"cache_read_input_tokens":10000,"output_tokens":200},"result":reply}))' \
    "$reply" "${STUB_LEAK:-}"
SH
chmod +x "$TMP/stub-claude.sh"
# shellcheck disable=SC2016 # the stub expands it, not this shell
printf '#!/usr/bin/env bash\necho "${STUB_PREFLIGHT:-PROCEED}"\n' >"$TMP/stub-preflight.sh"

export FVK_CLAUDE="$TMP/stub-claude.sh" FVK_PREFLIGHT="$TMP/stub-preflight.sh" STUB_LATER="$D"
newlog() { rm -rf "$TMP/stublog"; mkdir -p "$TMP/stublog"; export STUB_LOG="$TMP/stublog"; }
run() { FVK_SCRATCH="$TMP/scratch-$1" bash "$RUN" --repo "$R" --fixtures "$FX" "${@:2}"; }

# --- run.sh: refusals ---
newlog
HIMMEL_BILLED_OK='' bash "$RUN" --class judge --out "$TMP/o0" --fixtures "$FX" --repo "$R" >/dev/null 2>&1; rc=$?
eq "run: refuses without HIMMEL_BILLED_OK" "$rc" "2"
run x --class publisher --out "$TMP/o0" >/dev/null 2>&1; rc=$?
eq "run: refuses a class it cannot run" "$rc" "2"
run x --class judge --out "$TMP/o0" --tasks t1,nope >/dev/null 2>&1; rc=$?
eq "run: refuses an unknown --tasks id" "$rc" "2"
STUB_PREFLIGHT=SKIPPED-BANK run a --class judge --out "$TMP/o1" >/dev/null 2>&1; rc=$?
eq "run: a bank-preflight hold stops the sweep (exit 3)" "$rc" "3"
eq "run: no claude call after a bank hold" "$(cat "$STUB_LOG/count" 2>/dev/null || echo 0)" "0"

# --- run.sh: the judge sweep on frozen evidence ---
newlog
STUB_opus='**NO-GO**' STUB_sonnet='VERDICT: GO' run b --class judge --out "$TMP/o2" --tasks t1 >"$TMP/o2.log" 2>&1; rc=$?
eq "judge: sweep exits 0" "$rc" "0"
eq "judge: 2 arms x 2 reps = 4 calls" "$(cat "$STUB_LOG/count")" "4"
argv1="$(cat "$STUB_LOG/argv.1")"; argv3="$(cat "$STUB_LOG/argv.3")"
has "judge: keep arm runs opus" "$argv1" $'--model\nopus'
has "judge: fold arm runs sonnet" "$argv3" $'--model\nsonnet'
has "judge: runs as the judge-ro agent" "$argv1" $'--agent\njudge-ro'
has "judge: effort high" "$argv1" $'--effort\nhigh'
has "judge: explicit dontAsk permission mode" "$argv1" $'--permission-mode\ndontAsk'
hasnt "judge: never bypassPermissions" "$argv1" "bypassPermissions"
has "judge: stream-json output" "$argv1" $'--output-format\nstream-json'
has "judge: gh denied" "$argv1" "Bash(gh:*)"
has "judge: fetch denied" "$argv1" "Bash(git fetch:*)"
hasnt "judge: --agents carries no model (the arm decides)" "$(cat "$STUB_LOG/agents.1")" '"model"'
has "judge: --agents carries judge-ro's prompt" "$(cat "$STUB_LOG/agents.1")" "You judge."
eq "judge: cwd is the scratch tree" "$(cat "$STUB_LOG/cwd.1")" "$TMP/scratch-b/t1/tree"
eq "judge: the tree is at the judged head" "$(cat "$STUB_LOG/head.1")" "$B"
eq "judge: origin/main is the merge-base" "$(cat "$STUB_LOG/base.1")" "$A"
has "judge: a later PR commit is absent from the tree" "$(cat "$STUB_LOG/later.1")" "fatal"
has "judge: pr.diff holds the PR change" "$(cat "$TMP/scratch-b/t1/pr.diff" 2>&1)" "+pr-change"
hasnt "judge: pr.diff omits the later main commit" "$(cat "$TMP/scratch-b/t1/pr.diff" 2>&1)" "main-later"
has "judge: the task's delta diff is generated" "$(cat "$TMP/scratch-b/t1/delta.diff" 2>&1)" "+pr-change"
eq "judge: frozen evidence is written" "$(cat "$TMP/scratch-b/t1/prior/X/judge.md" 2>&1)" "prior NO-GO"
prompt="$(sed -n '/^-p$/{n;p;}' "$STUB_LOG/argv.1")"
has "judge: prompt carries the replay preamble" "$prompt" "EVAL REPLAY (fold-vs-keep)"
hasnt "judge: prompt no longer names the real repo" "$(cat "$STUB_LOG/argv.1")" "Repo $R "
has "judge: repo path rewritten to the tree" "$(cat "$STUB_LOG/argv.1")" "Repo $TMP/scratch-b/t1/tree at head"
has "judge: substitution rewrites a gone scratch path" "$(cat "$STUB_LOG/argv.1")" "Delta at $TMP/scratch-b/t1/delta.diff"
has "judge: substitution rewrites the verdicts path" "$(cat "$STUB_LOG/argv.1")" "verdict in $TMP/scratch-b/t1/prior/X/"
S1="$TMP/o2/judge/t1/keep/1.summary.json"
eq "judge: keep outcome parsed" "$(jget "$S1" outcome)" "NO-GO"
eq "judge: fold outcome parsed from VERDICT: GO" "$(jget "$TMP/o2/judge/t1/fold/2.summary.json" outcome)" "GO"
eq "judge: cost-eq = in + 1.25 cw + 0.1 cr + 5 out" "$(jget "$S1" cost_eq)" "3350"
eq "judge: wall from duration_ms" "$(jget "$S1" wall_s)" "2"
eq "judge: a denied gh call is not a leak" "$(jget "$S1" leaks)" "[]"
run b --class judge --out "$TMP/o2" --tasks t1 >/dev/null 2>&1
eq "judge: a rerun resumes, no new call" "$(cat "$STUB_LOG/count")" "4"
newlog
run c --class judge --out "$TMP/o3" --tasks t1,t2 --ceiling 5000 >/dev/null 2>&1; rc=$?
eq "judge: the ceiling stops the sweep (exit 3)" "$rc" "3"
eq "judge: the ceiling stops after the call that crossed it" "$(cat "$STUB_LOG/count")" "2"
newlog
STUB_LEAK="/x/Documents/luna/handovers/verdicts/q/judge.md" run d --class judge --out "$TMP/o4" --tasks t2 --arms keep --reps 1 >/dev/null 2>&1
has "judge: a read of the verdicts tree is a leak" "$(jget "$TMP/o4/judge/t2/keep/1.summary.json" leaks)" "verdicts/"
newlog
mkdir -p "$TMP/scratch-h/t1/tree/.git"
run h --class judge --out "$TMP/o8" --tasks t1 --arms keep --reps 1 >/dev/null 2>&1
eq "judge: a tree left part-built is rebuilt at the head" "$(cat "$STUB_LOG/head.1" 2>&1)" "$B"
python3 -c 'import json,sys; p=sys.argv[1]; d=json.load(open(p)); t=dict(d["tasks"][0], id="t3", head=sys.argv[2]); d["tasks"].append(t); json.dump(d, open(p, "w"))' "$FX/tasks/judge.json" "$A"
newlog
run i --class judge --out "$TMP/o9" --tasks t3 --arms keep --reps 1 >/dev/null 2>&1
eq "judge: a head already on origin/main gets no call" "$(cat "$STUB_LOG/count" 2>/dev/null || echo 0)" "0"
if [ -e "$TMP/o9/judge/t3/keep/1.summary.json" ]; then s=1; else s=0; fi
eq "judge: a head already on origin/main gets no summary" "$s" "0"

# --- run.sh: the vm class ---
python3 -c 'import json,sys
fx = sys.argv[1]
h = fx + "/hist.jsonl"
with open(h, "w") as f:
    f.write(json.dumps({"type":"user","timestamp":"2026-10-20T10:00:00Z","message":{"content":"run the proof"}}) + "\n")
    f.write(json.dumps({"type":"assistant","timestamp":"2026-10-20T10:05:00Z","message":{"id":"a","usage":{"input_tokens":1000,"output_tokens":100},
        "content":[{"type":"text","text":"Overall PASS."}]}}) + "\n")
json.dump(dict(cls="vm", arms=dict(keep="sonnet child", fold="chief-run script"),
               tasks=[dict(id="v1", brief="Prove it on the VM. Notes in {HOME}/notes.", historic=h, author_cost_eq=7000,
                           head=sys.argv[2], tags=["v0"])]), open(fx + "/tasks/vm.json", "w"))' "$FX" "$B"
git -C "$R" tag v0 "$A"
printf '#!/usr/bin/env bash\necho step 1 ok\necho "PROOF: PASS"\n' >"$FX/tasks/vm-scripts/v1.sh"
newlog
mkdir -p "$TMP/locks"
HIMMEL_VM_LOCK_DIR="$TMP/locks" STUB_sonnet=$'all good\nPROOF: FAIL' run e --class vm --out "$TMP/o5" --reps 1 >/dev/null 2>&1; rc=$?
eq "vm: sweep exits 0" "$rc" "0"
eq "vm: one claude call (the keep arm only)" "$(cat "$STUB_LOG/count")" "1"
has "vm: the child is sonnet" "$(cat "$STUB_LOG/argv.1")" $'--model\nsonnet'
has "vm: the child brief asks for a PROOF line" "$(cat "$STUB_LOG/argv.1")" "PROOF: PASS or PROOF: FAIL"
has "vm: the child cannot post to GitHub" "$(cat "$STUB_LOG/argv.1")" "Bash(gh:*)"
has "vm: the child cannot push" "$(cat "$STUB_LOG/argv.1")" "Bash(git push:*)"
has "vm: {HOME} in a task field is the user's home" "$(cat "$STUB_LOG/argv.1")" "Notes in $HOME/notes."
has "vm: the child is handed a bundle of the head and its tags" "$(cat "$STUB_LOG/argv.1")" "branch \`eval\` at $B, tags v0"
eq "vm: the handed bundle holds the head and the tag" "$(cat "$STUB_LOG/bundle.1")" "$B refs/heads/eval|$A refs/tags/v0|"
if [ -e "$TMP/scratch-e/v1.bundle" ]; then left=1; else left=0; fi
eq "vm: the bundle is removed after the call" "$left" "0"
eq "vm: keep outcome parsed" "$(jget "$TMP/o5/vm/v1/keep/1.summary.json" outcome)" "FAIL"
eq "vm: historic run recorded with the key's verdict" "$(jget "$TMP/o5/vm/v1/keep/historic.summary.json" outcome)" "PASS"
eq "vm: historic cost-eq from the transcript" "$(jget "$TMP/o5/vm/v1/keep/historic.summary.json" cost_eq)" "1500"
eq "vm: historic wall from timestamps" "$(jget "$TMP/o5/vm/v1/keep/historic.summary.json" wall_s)" "300"
eq "vm: fold outcome from the script's PROOF line" "$(jget "$TMP/o5/vm/v1/fold/1.summary.json" outcome)" "PASS"
eq "vm: fold cost-eq is the authoring cost" "$(jget "$TMP/o5/vm/v1/fold/1.summary.json" cost_eq)" "7000"
has "vm: the keep call runs under the VM's lock" "$(cat "$STUB_LOG/locks.1")" "himmel-vm-lock-himmel-ar-2"
if [ -e "$TMP/locks/himmel-vm-lock-himmel-ar-2" ]; then held=1; else held=0; fi
eq "vm: the lock is released after the sweep" "$held" "0"
python3 -c 'import json,sys; p=sys.argv[1]; d=json.load(open(p)); del d["tasks"][0]["tags"]; json.dump(d, open(p, "w"))' "$FX/tasks/vm.json"
newlog
HIMMEL_VM_LOCK_DIR="$TMP/locks" STUB_sonnet='PROOF: PASS' run f --class vm --out "$TMP/o6" --reps 1 --arms keep >/dev/null 2>"$TMP/o6.err"
has "vm: a head without tags is bundled alone" "$(cat "$STUB_LOG/argv.1")" "branch \`eval\` at $B)"
hasnt "vm: a task without tags errors nowhere" "$(cat "$TMP/o6.err")" "Traceback"
newlog
FVK_VM=himmel-ar-9 run g --class vm --out "$TMP/o7" --reps 1 --arms keep >/dev/null 2>&1; rc=$?
eq "vm: the keep arm refuses a VM its briefs do not name" "$rc" "2"
eq "vm: no claude call on another VM" "$(cat "$STUB_LOG/count" 2>/dev/null || echo 0)" "0"

# --- the proof scripts' helpers, the VM stubbed out ---
LIB="$HERE/fixtures/tasks/vm-scripts/_lib.sh"
# shellcheck disable=SC2016 # the inner shell expands it
has "lib: a failed VM restore is no PASS" "$(TMPDIR="$TMP" bash -c '. "$1"; sdk() { return 1; }; vm_fresh' _ "$LIB")" "PROOF: FAIL"
# shellcheck disable=SC2016 # the inner shell expands it
no_stage='. "$1"; cd "$2" || exit 1; sdk() { :; }; g() { :; }; z=0123456789abcdef0123456789abcdef01234567; out="$(stage $z /x)"; expect head "$out" $z; final'
has "lib: a head that cannot be staged is no PASS" "$(TMPDIR="$TMP" bash -c "$no_stage" _ "$LIB" "$R" 2>/dev/null)" "PROOF: FAIL"
# shellcheck disable=SC2016 # the inner shell expands it
cut_off='. "$1"; sdk() { :; }; g() { echo "CHECK a PASS"; return 124; }; echo x >"$WORK/p.sh"; tally "$(guest_script p.sh)"; final'
has "lib: a guest script cut off after a passing check is no PASS" "$(TMPDIR="$TMP" bash -c "$cut_off" _ "$LIB")" "PROOF: FAIL"
# shellcheck disable=SC2016 # the inner shell expands it
finished='. "$1"; sdk() { :; }; g() { echo "CHECK a PASS"; case "$2" in *FVK-GUEST-END*) bash -c "exit ${RC:-1}"; echo "FVK-GUEST-END rc=$?" ;; esac; }; echo x >"$WORK/p.sh"; tally "$(guest_script p.sh)"; final'
has "lib: a guest script that finishes is scored on its checks" "$(TMPDIR="$TMP" bash -c "$finished" _ "$LIB")" "PROOF: PASS"
has "lib: a guest script killed by a signal after a passing check is no PASS" "$(RC=137 TMPDIR="$TMP" bash -c "$finished" _ "$LIB")" "PROOF: FAIL"
# shellcheck disable=SC2016 # python reads it, not this shell
python3 -c 'import re,sys
bad = []
for f in sys.argv[1:]:
    body = open(f).read().split("<<'"'"'EOF'"'"'", 1)[-1]
    seen = False
    for n, l in enumerate(body.splitlines(), 1):
        if re.search(r"\bck [a-z]", l): seen = True
        if seen and re.search(r"\|\| exit\b", l): bad.append(f.rsplit("/", 1)[1])
    bad += [f.rsplit("/", 1)[1] for l in body.splitlines() if l.startswith("[ -n \"$s\" ]")]
print(",".join(bad) or "ok")' "$HERE"/fixtures/tasks/vm-scripts/vm-*.sh >"$TMP/early.txt"
eq "lib: no proof script exits after a check without a failing check, nor passes the scan on any output" "$(cat "$TMP/early.txt")" "ok"

# --- fvk.py: historic subagent transcripts ---
python3 -c 'import json,sys
with open(sys.argv[1], "w") as f:
    for i, (u, c) in enumerate([({"input_tokens":10,"output_tokens":1}, [{"type":"text","text":"Looking."}]),
                                ({"input_tokens":10,"output_tokens":1}, [{"type":"text","text":"Looking."}]),
                                ({"input_tokens":20,"output_tokens":2}, [{"type":"tool_use","id":"h","name":"SubagentHandback","input":{"message":"VERDICT: NO-GO\nbad"}}])]):
        f.write(json.dumps({"type":"assistant","timestamp":"2026-10-20T10:0%d:00Z" % i,"message":{"id":"m%d" % min(i, 1),"usage":u,"content":c}}) + "\n")' "$TMP/h.jsonl"
python3 "$FVK" summarize "$TMP/h.jsonl" --class judge >"$TMP/h.json"
eq "fvk: the handback message is the reply" "$(jget "$TMP/h.json" outcome)" "NO-GO"
eq "fvk: usage deduped by message id" "$(jget "$TMP/h.json" cost_eq)" "45"
python3 -c 'import json,sys
with open(sys.argv[1], "w") as f:
    f.write(json.dumps({"type":"system","subtype":"init","session_id":"s"}) + "\n")
    f.write(json.dumps({"type":"assistant","message":{"id":"m1","usage":{"input_tokens":10,"output_tokens":1},"content":[{"type":"text","text":"**GO**"}]}}) + "\n")' "$TMP/cut.jsonl"
python3 "$FVK" summarize "$TMP/cut.jsonl" --class judge >"$TMP/cut.json"
eq "fvk: a claude -p stream cut off before its result is an error" "$(jget "$TMP/cut.json" error)" "true"
python3 -c 'import json,sys
with open(sys.argv[1], "w") as f:
    for i, (cmd, err) in enumerate([("cat /x/verdicts/q/judge.md; false", "Exit code 1\nGO"),
                                    ("gh pr view 1", "PreToolUse:Bash hook error: [guard]: DENIED"),
                                    ("cat /y/.himmel/state/z", "<tool_use_error>InputValidationError</tool_use_error>")]):
        f.write(json.dumps({"type":"assistant","message":{"id":"m%d" % i,"content":[{"type":"tool_use","id":"u%d" % i,"name":"Bash","input":{"command":cmd}}]}}) + "\n")
        f.write(json.dumps({"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"u%d" % i,"is_error":True,"content":err}]}}) + "\n")
    f.write(json.dumps({"type":"result","subtype":"success","is_error":False,"duration_ms":1,"usage":{},"result":"**GO**"}) + "\n")' "$TMP/ran.jsonl"
python3 "$FVK" summarize "$TMP/ran.jsonl" --class judge >"$TMP/ran.json"
eq "fvk: a call that ran and exited nonzero is still a leak; a refused call is not" "$(jget "$TMP/ran.json" leaks)" '["Bash:verdicts/"]'
python3 "$FVK" summarize "$TMP/nope.jsonl" >/dev/null 2>&1; rc=$?
eq "fvk: a missing file is refused" "$rc" "2"

# --- fvk.py: publisher rows ---
P="$TMP/projects"; mkdir -p "$P/s"
python3 -c 'import json,sys
def pub(i, page): return {"type":"assistant","message":{"id":"p%s" % i,"usage":{"input_tokens":100},"content":[{"type":"tool_use","id":"u%s" % i,"name":"Artifact","input":{"action":"publish","file_path":"/x/" + page}}]}}
def res(i, err, text): return {"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"u%s" % i,"is_error":err,"content":text}]}}
w = lambda p, ev: open(p, "w").write("".join(json.dumps(e) + "\n" for e in ev))
w(sys.argv[1] + "/s/child-ok.jsonl", [pub(1, "board.html"), res(1, True, "Error: not viewed"), pub(2, "board.html"), res(2, False, "published")])
w(sys.argv[1] + "/s/child-bad.jsonl", [pub(1, "board.html"), res(1, False, "publish refused by classifier")])
w(sys.argv[1] + "/s/console.jsonl", [pub(1, "board.html"), res(1, False, "published"), pub(2, "focus.html"), res(2, True, "Error")])
json.dump({"tasks":[{"id":"p1","page":"board.html","subagent":["s/child-ok.jsonl","s/child-bad.jsonl","s/missing.jsonl"],
    "inline":[{"file":"s/console.jsonl"}]},{"id":"p2","page":"focus.html","subagent":[],"inline":[{"file":"s/console.jsonl"}]}]},
    open(sys.argv[1] + "/pub-tasks.json", "w"))' "$P"
python3 "$FVK" publisher --tasks "$P/pub-tasks.json" --projects "$P" >"$TMP/pub.json"
eq "publisher: a retried publish that lands is live" "$(jget "$TMP/pub.json" 0/outcome)" "live"
eq "publisher: retries counted" "$(jget "$TMP/pub.json" 0/attempts)" "2"
eq "publisher: a refusal is not live" "$(jget "$TMP/pub.json" 1/outcome)" "not-live"
eq "publisher: a missing transcript is an error row" "$(jget "$TMP/pub.json" 2/error)" "true"
eq "publisher: inline rows read only their page" "$(jget "$TMP/pub.json" 3/outcome) $(jget "$TMP/pub.json" 4/outcome)" "live not-live"
eq "publisher: an inline row carries no child cost" "$(jget "$TMP/pub.json" 3/cost_eq)" "null"

# --- fvk.py score: the decision reads flipped tasks ---
# mk <runs> <n tasks> <fold outcome of task 0> - every keep run correct (GO), fold correct
# except task 0.
mk() { python3 -c 'import json,os,sys
runs, n, f0 = sys.argv[1], int(sys.argv[2]), sys.argv[3]
key = {"judge": {}}
for i in range(n):
    t = "q%02d" % i; key["judge"][t] = {"truth": "GO"}
    for arm, out, ce in (("keep", "GO", 1000), ("fold", f0 if i == 0 else "GO", 400)):
        d = os.path.join(runs, "judge", t, arm); os.makedirs(d, exist_ok=True)
        for r in (1, 2):
            json.dump({"file": "%s/%d.stream.jsonl" % (d, r), "leaks": [], "error": False, "outcome": out,
                       "cost_eq": ce, "wall_s": 60}, open(os.path.join(d, "%d.summary.json" % r), "w"))
json.dump(key, open(runs + "/key.json", "w"))
os.makedirs(runs + "/tasks", exist_ok=True)
json.dump({"arms": {"keep": "opus", "fold": "sonnet"}, "tasks": []}, open(runs + "/tasks/judge.json", "w"))' "$1" "$2" "$3"; }
score() { python3 "$FVK" score --tasks "$1/tasks" --key "$1/key.json" --runs "$1" --json "$1/out.json"; }
mk "$TMP/s1" 10 GO;    out="$(score "$TMP/s1")"
eq "score: no flip over 10 tasks folds" "$(jget "$TMP/s1/out.json" 0/decision)" "fold"
has "score: the class row is rendered" "$out" "| judge | opus | sonnet | 10/10 | 20/20 | none | none | 1000 | 400 |"
has "score: per-task rows are rendered" "$out" "| q00 | GO | GO GO | 2/2 | GO GO | 2/2 | - |"
mk "$TMP/s2" 10 NO-GO; score "$TMP/s2" >/dev/null
eq "score: one task flipping worse keeps" "$(jget "$TMP/s2/out.json" 0/decision)" "keep"
eq "score: the flipped task is named" "$(jget "$TMP/s2/out.json" 0/flips/worse)" '["q00"]'
mk "$TMP/s3" 9 GO;     score "$TMP/s3" >/dev/null
eq "score: fewer than 10 scored tasks is inconclusive" "$(jget "$TMP/s3/out.json" 0/decision)" "inconclusive"
mk "$TMP/s4" 10 GO
python3 -c 'import json,sys; p=sys.argv[1]; s=json.load(open(p)); s["leaks"]=["Read:verdicts/"]; s["outcome"]="NO-GO"; json.dump(s, open(p, "w"))' \
    "$TMP/s4/judge/q00/fold/1.summary.json"
score "$TMP/s4" >/dev/null
eq "score: a leaked run is unscored, not a flip" "$(jget "$TMP/s4/out.json" 0/decision)" "fold"
eq "score: the leaked run is listed unscored" "$(jget "$TMP/s4/out.json" 0/per_task/0/fold/unscored)" '["1.stream.jsonl"]'
python3 -c 'import json,os,sys
runs = sys.argv[1]
for cls, out in (("judge", "GO"), ("vm", "PASS")):
    d = os.path.join(runs, cls, "x1", "keep"); os.makedirs(d, exist_ok=True)
    json.dump({"file": d + "/1.stream.jsonl", "leaks": ["Read:/Documents/github/himmel"], "error": False,
               "outcome": out}, open(d + "/1.summary.json", "w"))
os.makedirs(runs + "/tasks", exist_ok=True)
for cls in ("judge", "vm"):
    json.dump({"arms": {"keep": "k", "fold": "f"}, "tasks": []}, open("%s/tasks/%s.json" % (runs, cls), "w"))
json.dump({"judge": {"x1": {"truth": "GO"}}, "vm": {"x1": {"truth": "PASS"}}}, open(runs + "/key.json", "w"))' "$TMP/s5"
score "$TMP/s5" >/dev/null
eq "score: a judge run that read the live checkout is unscored" "$(jget "$TMP/s5/out.json" 0/per_task/0/keep/scored)" "0"
eq "score: a vm run reading its own repo checkout is scored" "$(jget "$TMP/s5/out.json" 1/per_task/0/keep/scored)" "1"
python3 "$FVK" score --tasks "$TMP/nope" --key "$TMP/s1/key.json" --runs "$TMP/s1" >/dev/null 2>&1; rc=$?
eq "score: a missing tasks dir is refused" "$rc" "2"

echo
echo "test-fold-vs-keep: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
