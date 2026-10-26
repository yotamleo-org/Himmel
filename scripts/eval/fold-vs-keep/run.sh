#!/usr/bin/env bash
# scripts/eval/fold-vs-keep/run.sh - one sweep of the fold-vs-keep eval for one class.
# Every (task, arm, rep) writes <out>/<class>/<task>/<arm>/<rep>.stream.jsonl
# (or .log) and its <rep>.summary.json; a rep whose summary exists is skipped, so a
# stopped sweep resumes. fvk.py score reads the summaries. `{HOME}` in a task field
# is the invoking user's home.
#
# usage: run.sh --class judge|vm --out <dir> [--tasks a,b] [--arms keep,fold] [--reps N]
#               [--ceiling <cost-eq>] [--max-usd <x>] [--timeout <s>] [--repo <dir>] [--fixtures <dir>]
#   judge  keep = opus judge-ro, fold = sonnet judge-ro, both at effort high on the same
#          evidence: a scratch git checkout holding only the judged head's ancestry (no
#          later commit, so no outcome), its diff vs the merge-base, and the task's frozen
#          evidence files and delta diffs. gh, fetch and the network are denied, user
#          settings only; fvk.py marks a run that touched a leak path.
#   vm     keep = a fresh sonnet child on the task's brief, from the repo root, handed a
#          host bundle of the task's head (and tags), as the fold arm's `stage` builds; fold =
#          the task's proof script (tasks/vm-scripts/<id>.sh), whose run costs its
#          authoring cost-eq (tasks/vm.json author_cost_eq). The historic child run is
#          written as keep rep `historic` with the recorded verdict (no model call).
#          Each call of either arm holds the vm-lock for $FVK_VM (default himmel-ar-2).
#   --ceiling  stop before the next call once the class's summed cost-eq reaches it.
# Before each task's calls bank-preflight must print PROCEED, else the sweep stops (exit 3).
# Env: FVK_CLAUDE (default claude), FVK_PREFLIGHT (default scripts/lib/bank-preflight.sh),
#      FVK_SCRATCH (default a fresh mktemp -d) - the test seams.
# Exit: 0 done; 2 usage; 3 stopped (bank refusal or ceiling).
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
FVK="$HERE/fvk.py"
REPO_DEFAULT="$(cd "$HERE/../../.." && pwd)"
CLAUDE_BIN="${FVK_CLAUDE:-claude}"
PREFLIGHT="${FVK_PREFLIGHT:-$REPO_DEFAULT/scripts/lib/bank-preflight.sh}"
cls=""; out=""; only=""; arms="keep,fold"; reps=2; ceiling=""; max_usd=10; tmo=1800; repo="$REPO_DEFAULT"; fixtures="$HERE/fixtures"

die() { echo "run.sh: $1" >&2; exit 2; }
while [ $# -gt 0 ]; do
    case "$1" in
        --class|--out|--tasks|--arms|--reps|--ceiling|--max-usd|--timeout|--repo|--fixtures)
            [ $# -ge 2 ] || die "$1 needs a value" ;;
    esac
    case "$1" in
        --class) cls="$2"; shift 2 ;;
        --out) out="$2"; shift 2 ;;
        --tasks) only="$2"; shift 2 ;;
        --arms) arms="$2"; shift 2 ;;
        --reps) reps="$2"; shift 2 ;;
        --ceiling) ceiling="$2"; shift 2 ;;
        --max-usd) max_usd="$2"; shift 2 ;;
        --timeout) tmo="$2"; shift 2 ;;
        --repo) repo="$2"; shift 2 ;;
        --fixtures) fixtures="$2"; shift 2 ;;
        *) die "unknown argument: $1" ;;
    esac
done
case "$cls" in judge|vm) ;; *) die "--class judge|vm is required" ;; esac
[ -n "$out" ] || die "--out <dir> is required"
# billed-opt-in: HIMMEL_BILLED_OK
[ "${HIMMEL_BILLED_OK:-}" = 1 ] || die "makes real, billed model calls; set HIMMEL_BILLED_OK=1 (on-demand only)"
tasks_file="$fixtures/tasks/$cls.json"; key="$fixtures/key/truth.json"
[ -f "$tasks_file" ] && [ -f "$key" ] || die "no $tasks_file or $key"
mkdir -p "$out/$cls" || exit 2
out="$(cd "$out" && pwd)"
# shellcheck source=../../lib/prim.sh
. "$HERE/../../lib/prim.sh" || exit 2
scratch="${FVK_SCRATCH:-$(tmpdir)}" && mkdir -p "$scratch" || exit 2
python3 -c 'import os,sys; open(sys.argv[2], "w").write(open(sys.argv[1]).read().replace("{HOME}", os.path.expanduser("~")))' \
    "$tasks_file" "$scratch/$cls.tasks.json" || exit 2
tasks_file="$scratch/$cls.tasks.json"

# jq-free task field reader: field <task-id> <name>
field() { python3 -c 'import json,sys
t=[x for x in json.load(open(sys.argv[1]))["tasks"] if x["id"]==sys.argv[2]][0]
v=t.get(sys.argv[3], "")
print(v if isinstance(v, str) else json.dumps(v))' "$tasks_file" "$1" "$2"; }
truth() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))[sys.argv[2]][sys.argv[3]]["truth"])' "$key" "$cls" "$1"; }
spent() { python3 -c 'import json,sys,glob
print(int(sum(json.load(open(p)).get("cost_eq") or 0 for p in glob.glob(sys.argv[1]+"/*/*/*.summary.json") if not p.endswith("historic.summary.json"))))' "$out/$cls"; }
ids="$(python3 -c 'import json,sys; print(" ".join(t["id"] for t in json.load(open(sys.argv[1]))["tasks"]))' "$tasks_file")"
if [ -n "$only" ]; then
    for t in ${only//,/ }; do case " $ids " in *" $t "*) ;; *) die "--tasks names an unknown task: $t" ;; esac; done
    ids="${only//,/ }"
fi

# judge-ro's definition as an --agents object, without its model so --model decides.
agents_json() { python3 -c 'import json,re,sys
t=open(sys.argv[1]).read(); m=re.match(r"---\n(.*?)\n---\n(.*)", t, re.S)
fm=dict(l.split(": ",1) for l in m.group(1).splitlines() if ": " in l)
print(json.dumps({"judge-ro":{"description":fm["description"],"tools":[x.strip() for x in fm["tools"].split(",")],"prompt":m.group(2)}}))' "$repo/.claude/agents/judge-ro.md"; }

judge_prompt() { # $1 task, $2 work dir -> the replayed brief on stdout
    python3 -c 'import json,sys
t=[x for x in json.load(open(sys.argv[1]))["tasks"] if x["id"]==sys.argv[2]][0]
w=sys.argv[3]; tree=w+"/tree"
pre=("EVAL REPLAY (fold-vs-keep). You are re-judging a past question. Your working directory %s is a git "
     "checkout of the PR at head %s holding only that head and its history (origin/main = its merge-base); "
     "the PR diff against that base is %s/pr.diff. Where the brief names the repo checkout, that is this "
     "checkout. gh, git fetch and the network are unavailable, and a scratch path the brief names may be gone: "
     "rule on this checkout and the files under %s, and read nothing outside them. The first line of your "
     "reply is **GO** or **NO-GO**.\n\n" % (tree, t["head"], w, w))
b=t["brief"].replace(t["repo"], tree)
for old, new in t.get("subs", []):
    b=b.replace(old, new.replace("{w}", w))
print(pre + b)' "$tasks_file" "$1" "$2"
}

prepare_tree() { # $1 task, $2 work dir: the head's ancestry only, so no later commit can leak the outcome
    local head base; head="$(field "$1" head)"
    [ -d "$2/tree/.git" ] && return 0
    mkdir -p "$2/tree" || return 1
    base="$(git -C "$repo" merge-base origin/main "$head")" || return 1
    git -C "$2/tree" init -q && git -C "$2/tree" fetch -q --no-tags "$repo" "$head" &&
        git -C "$2/tree" checkout -q --detach "$head" &&
        git -C "$2/tree" update-ref refs/remotes/origin/main "$base" || return 1
    rm -f "$2/tree/.git/FETCH_HEAD"
    git -C "$repo" diff "$base" "$head" >"$2/pr.diff" || return 1
    python3 -c 'import json,os,sys
t=[x for x in json.load(open(sys.argv[1]))["tasks"] if x["id"]==sys.argv[2]][0]
for rel, body in t.get("evidence", {}).items():
    p=os.path.join(sys.argv[3], rel); os.makedirs(os.path.dirname(p), exist_ok=True); open(p, "w").write(body)' \
        "$tasks_file" "$1" "$2" || return 1
    local a b f
    while read -r a b f; do
        [ -n "$f" ] && git -C "$repo" diff "$a" "$b" >"$2/$f"
    done < <(python3 -c 'import json,sys
t=[x for x in json.load(open(sys.argv[1]))["tasks"] if x["id"]==sys.argv[2]][0]
for a, b, f in t.get("diffs", []): print(a, b, f)' "$tasks_file" "$1")
}

run_judge() { # $1 task, $2 arm, $3 rep, $4 stem
    local w="$scratch/$1" model
    case "$2" in keep) model=opus ;; fold) model=sonnet ;; esac
    prepare_tree "$1" "$w" || { echo "run.sh: tree export failed for $1" >&2; return 1; }
    local prompt; prompt="$(judge_prompt "$1" "$w")"
    # fold-vs-keep judge replay, bank-preflighted per task, explicit permission mode, budget-capped
    # launch-profile-ok: the eval measures the judge-ro definition itself on frozen evidence, not a leg profile
    (cd "$w/tree" && timeout "$tmo" "$CLAUDE_BIN" -p "$prompt" --agents "$(agents_json)" --agent judge-ro \
        --model "$model" --effort high --permission-mode dontAsk --output-format stream-json --verbose \
        --max-budget-usd "$max_usd" --setting-sources user --strict-mcp-config --no-session-persistence \
        --add-dir "$w" --allowedTools Read Grep Glob Bash \
        --disallowedTools 'Bash(gh:*)' 'Bash(git fetch:*)' 'Bash(git pull:*)' 'Bash(git push:*)' 'Bash(curl:*)' \
        'Bash(wget:*)' WebFetch WebSearch) >"$4.stream.jsonl" 2>"$4.stderr"
    python3 "$FVK" summarize "$4.stream.jsonl" --class judge >"$4.summary.json"
}

stage_bundle() { # $1 head, $2 bundle path, $3.. tags: head as branch eval, plus the tags
    local bare="$2.git" refs=(refs/heads/eval) tg head="$1" dest="$2"; shift 2
    rm -rf "$bare"
    git init -q --bare "$bare" && git -C "$bare" fetch -q --no-tags "$repo" "$head:refs/heads/eval" || return 1
    for tg in "$@"; do
        git -C "$bare" fetch -q --no-tags "$repo" "refs/tags/$tg:refs/tags/$tg" && refs+=("refs/tags/$tg")
    done
    git -C "$bare" bundle create -q "$dest" "${refs[@]}"; local rc=$?
    rm -rf "$bare"
    return "$rc"
}

run_vm() { # $1 task, $2 arm, $3 rep, $4 stem
    if [ "$2" = keep ]; then
        local prompt head tags bundle="" rc; prompt="$(field "$1" brief)"; head="$(field "$1" head)"
        if [ -n "$head" ]; then
            tags="$(field "$1" tags | python3 -c 'import json,sys; print(" ".join(json.loads(sys.stdin.read().strip() or "[]")))')"
            bundle="$scratch/$1.bundle"
            # shellcheck disable=SC2086 # tags split into one ref each
            stage_bundle "$head" "$bundle" $tags || { echo "run.sh: cannot bundle $head for $1" >&2; return 1; }
            prompt+=$'\n\n'"The harness has bundled the PR head on this host for you: $bundle (branch \`eval\` at $head${tags:+, tags $tags}). Push that file to the guest with vmsdk push and clone it there; do not build another bundle from the checkout."
        fi
        prompt+=$'\n\nEnd your reply with one line: PROOF: PASS or PROOF: FAIL.'
        # fold-vs-keep VM-runner replay, bank-preflighted per task, explicit permission mode, budget-capped
        # launch-profile-ok: the eval measures the sonnet VM-runner child as the console dispatches it
        (cd "$repo" && timeout "$tmo" "$CLAUDE_BIN" -p "$prompt" --model sonnet --permission-mode auto \
            --output-format stream-json --verbose --max-budget-usd "$max_usd" \
            --disallowedTools 'Bash(gh:*)' 'Bash(git push:*)') >"$4.stream.jsonl" 2>"$4.stderr"
        python3 "$FVK" summarize "$4.stream.jsonl" --class vm >"$4.summary.json"; rc=$?
        [ -z "$bundle" ] || rm -f "$bundle"
        return "$rc"
    fi
    local script="$fixtures/tasks/vm-scripts/$1.sh" t0 t1
    [ -f "$script" ] || { echo "run.sh: no proof script $script" >&2; return 1; }
    t0="$(date +%s)"
    (cd "$repo" && timeout "$tmo" bash "$script") >"$4.log" 2>&1
    t1="$(date +%s)"
    python3 -c 'import json,re,sys
log=open(sys.argv[1], errors="replace").read()
m=re.search(r"^\W*PROOF:\s*(PASS|FAIL)\b", log, re.M)
print(json.dumps({"file":sys.argv[1],"leaks":[],"error":m is None,"outcome":m.group(1) if m else None,
  "cost_eq":int(float(sys.argv[2])),"wall_s":int(sys.argv[3]),"turns":0,"cost_usd":None,"reply":log[-400:]}, indent=1))' \
        "$4.log" "$(field "$1" author_cost_eq)" "$((t1 - t0))" >"$4.summary.json"
}

if [ "$cls" = vm ]; then
    export FVK_VM="${FVK_VM:-himmel-ar-2}"
    HIMMEL_VM_LOCK_WAIT="${HIMMEL_VM_LOCK_WAIT:-3600}"
    # shellcheck source=../../vm/vm-lock.sh
    source "$HERE/../../vm/vm-lock.sh"
    for t in $ids; do
        hist="$(field "$t" historic)"
        d="$out/vm/$t/keep"; mkdir -p "$d"
        [ -n "$hist" ] && [ ! -f "$d/historic.summary.json" ] && \
            python3 "$FVK" summarize "$hist" --class vm --outcome "$(truth "$t")" >"$d/historic.summary.json"
    done
fi

for t in $ids; do
    todo=0
    for arm in ${arms//,/ }; do for r in $(seq 1 "$reps"); do
        [ -f "$out/$cls/$t/$arm/$r.summary.json" ] || todo=1
    done; done
    [ "$todo" = 1 ] || continue
    if ! pf="$(bash "$PREFLIGHT" 2>&1)" || ! printf '%s\n' "$pf" | grep -qx PROCEED; then
        echo "run.sh: bank-preflight did not PROCEED before $t - stopped" >&2
        printf '%s\n' "$pf" >&2
        exit 3
    fi
    for arm in ${arms//,/ }; do
        mkdir -p "$out/$cls/$t/$arm"
        for r in $(seq 1 "$reps"); do
            stem="$out/$cls/$t/$arm/$r"
            [ -f "$stem.summary.json" ] && continue
            if [ -n "$ceiling" ] && [ "$(spent)" -ge "$ceiling" ]; then
                echo "run.sh: spent $(spent) cost-eq, ceiling $ceiling reached before $t/$arm/$r - stopped" >&2
                exit 3
            fi
            if [ "$cls" = vm ]; then
                vm_lock_acquire_waiting "$FVK_VM" || { echo "run.sh: no vm-lock for $FVK_VM before $t/$arm/$r - stopped" >&2; exit 3; }
                run_vm "$t" "$arm" "$r" "$stem" || rm -f "$stem.summary.json"
                vm_lock_release "$FVK_VM"
            else
                run_judge "$t" "$arm" "$r" "$stem" || rm -f "$stem.summary.json"
            fi
            echo "run.sh: $cls $t $arm $r -> $(python3 -c 'import json,sys
try: s=json.load(open(sys.argv[1])); print(s.get("outcome"), s.get("cost_eq"), "leaks=%d" % len(s.get("leaks") or []))
except Exception: print("no summary")' "$stem.summary.json")"
        done
    done
done
echo "run.sh: $cls sweep done, spent $(spent) cost-eq"
