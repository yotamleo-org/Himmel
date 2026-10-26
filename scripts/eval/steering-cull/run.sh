#!/usr/bin/env bash
# scripts/eval/steering-cull/run.sh - the billed behaviour arm of the steering-cull eval.
# Each (probe, arm, rep) writes <out>/<probe>/<arm>/<rep>.raw.json and <rep>.summary.json; a rep
# whose summary exists is skipped, so a stopped sweep resumes (an errored run leaves no summary
# and is retried).
#
# usage: run.sh --phase red|cut --out <dir> [--probes a,b] [--reps N] [--model M] [--effort E]
#               [--ceiling <cost-eq>] [--max-usd <x>] [--timeout <s>]
#   red  arms baseline and red-<row> for every probe: the RED-first gate (cull.py valid)
#   cut  arm cut for the probes the red phase found valid; refused until every named probe has
#        its baseline and red runs
# The child sees only the arm's steering text: cwd <arm>/repo holds the repo CLAUDE.md, its
# parent holds the user CLAUDE.md and RTK.md, --setting-sources project keeps the real
# ~/.claude/CLAUDE.md out, and --tools "" leaves it no tools, so hooks and memory play no part.
# Before each probe's calls usage-preflight must print PROCEED, else the sweep stops (exit 3).
#   --ceiling  stop before the next call once the summed cost-eq of <out> reaches it.
# Env: SC_CLAUDE (default claude), SC_PREFLIGHT (default scripts/lib/usage-preflight.sh) - the
#      test seams.
# Exit: 0 done; 2 usage, an <out> run under another config, or an arm that cannot be built;
#       3 stopped (bank refusal, ceiling, an unsummable spend, or under a ceiling a call with no
#       usage to bill); 4 swept, but some runs errored and lack a summary (re-run to retry).
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
CULL="$HERE/cull.py"
REPO="$(cd "$HERE/../../.." && pwd)"
CLAUDE_BIN="${SC_CLAUDE:-claude}"
PREFLIGHT="${SC_PREFLIGHT:-$REPO/scripts/lib/usage-preflight.sh}"
phase=""; out=""; only=""; reps=3; model=sonnet; effort=medium; ceiling=""; max_usd=1; tmo=600

die() { echo "run.sh: $1" >&2; exit 2; }
while [ $# -gt 0 ]; do
    case "$1" in
        --phase|--out|--probes|--reps|--model|--effort|--ceiling|--max-usd|--timeout)
            [ $# -ge 2 ] || die "$1 needs a value" ;;
    esac
    case "$1" in
        --phase) phase="$2"; shift 2 ;;
        --out) out="$2"; shift 2 ;;
        --probes) only="$2"; shift 2 ;;
        --reps) reps="$2"; shift 2 ;;
        --model) model="$2"; shift 2 ;;
        --effort) effort="$2"; shift 2 ;;
        --ceiling) ceiling="$2"; shift 2 ;;
        --max-usd) max_usd="$2"; shift 2 ;;
        --timeout) tmo="$2"; shift 2 ;;
        *) die "unknown argument: $1" ;;
    esac
done
case "$phase" in red|cut) ;; *) die "--phase red|cut is required" ;; esac
[ -n "$out" ] || die "--out <dir> is required"
case "$reps" in ''|*[!0-9]*|0|00*) die "--reps needs a positive integer, not '$reps'" ;; esac
case "$tmo" in ''|*[!0-9]*|0|00*) die "--timeout needs a positive integer of seconds, not '$tmo'" ;; esac
case "$ceiling" in *[!0-9]*) die "--ceiling needs an integer cost-eq, not '$ceiling'" ;; esac
python3 -c 'import sys; sys.exit(0 if float(sys.argv[1]) > 0 else 1)' "$max_usd" 2>/dev/null || die "--max-usd needs a positive number, not '$max_usd'"
# billed-opt-in: HIMMEL_BILLED_OK
[ "${HIMMEL_BILLED_OK:-}" = 1 ] || die "makes real, billed model calls; set HIMMEL_BILLED_OK=1 (on-demand only)"
python3 "$CULL" check >/dev/null || die "rows.json no longer matches its baseline fixtures (cull.py check)"

ids="$(python3 -c 'import json,sys; print(" ".join(p["id"] for p in json.load(open(sys.argv[1]))["probes"]))' "$HERE/probes.json")"
if [ -n "$only" ]; then
    for p in ${only//,/ }; do case " $ids " in *" $p "*) ;; *) die "--probes names an unknown probe: $p" ;; esac; done
    ids="${only//,/ }"
fi
row_of() { python3 -c 'import json,sys; print([p["row"] for p in json.load(open(sys.argv[1]))["probes"] if p["id"]==sys.argv[2]][0])' "$HERE/probes.json" "$1"; }
prompt_of() { python3 -c 'import json,sys; d=json.load(open(sys.argv[1]))
print(d["preamble"] + [p["prompt"] for p in d["probes"] if p["id"]==sys.argv[2]][0])' "$HERE/probes.json" "$1"; }

mkdir -p "$out" || exit 2
out="$(cd "$out" && pwd)"
if [ "$phase" = cut ]; then
    for p in $ids; do
        for arm in baseline "red-$(row_of "$p")"; do for r in $(seq 1 "$reps"); do
            [ -f "$out/$p/$arm/$r.summary.json" ] || die "$p has no $arm run $r; run --phase red first"
        done; done
    done
    valid=" $(python3 "$CULL" valid --runs "$out" | tr '\n' ' ') "
    keep=""
    for p in $ids; do case "$valid" in *" $p "*) keep="$keep $p" ;; esac; done
    ids="$keep"
fi
# A resume must ask the same question: same model, effort and reps, and the same text the child
# reads (cull.py inputs-sha). Checks may change; rescore.
isha="$(python3 "$CULL" inputs-sha)" || exit 2
python3 -c 'import json,os,sys
path = sys.argv[1]
new = {"model": sys.argv[2], "effort": sys.argv[3], "reps": int(sys.argv[4]), "inputs_sha": sys.argv[5]}
if os.path.exists(path) and json.load(open(path)) != new:
    sys.exit(3)
json.dump(new, open(path, "w"))' "$out/run-config.json" "$model" "$effort" "$reps" "$isha"
case $? in
    0) ;;
    3) die "$out was run with another model, effort, reps or probe text (run-config.json); use a fresh --out" ;;
    *) exit 2 ;;
esac

# shellcheck source=../../lib/prim.sh
. "$HERE/../../lib/prim.sh" || exit 2
scratch="$(tmpdir)" || exit 2
trap 'rm -rf "$scratch"' EXIT
arm_dir() { # $1 arm -> its built tree, built once per sweep
    [ -d "$scratch/$1/repo" ] || python3 "$CULL" build --arm "$1" --dest "$scratch/$1" >/dev/null || return 1
    printf '%s\n' "$scratch/$1"
}
# Spent = the scored runs plus every errored call that reported usage (errored-spend.log). Under a
# ceiling, a call that reports no usage (a reply without it, killed by --timeout, unparseable) stops the sweep.
spent() { python3 -c 'import json,sys,glob,os
s = sum(json.load(open(p)).get("cost_eq") or 0 for p in glob.glob(sys.argv[1]+"/*/*/*.summary.json"))
e = os.path.join(sys.argv[1], "errored-spend.log")
s += sum(float(x) for x in open(e) if x.strip()) if os.path.exists(e) else 0
print(int(s))' "$out"; }

for p in $ids; do
    if [ "$phase" = red ]; then arms="baseline red-$(row_of "$p")"; else arms="cut"; fi
    todo=0
    for arm in $arms; do for r in $(seq 1 "$reps"); do
        [ -f "$out/$p/$arm/$r.summary.json" ] || todo=1
    done; done
    [ "$todo" = 1 ] || continue
    if ! pf="$(bash "$PREFLIGHT" 2>&1)" || ! grep -qx PROCEED <<<"$pf"; then
        echo "run.sh: usage-preflight did not PROCEED before $p - stopped" >&2
        printf '%s\n' "$pf" >&2
        exit 3
    fi
    prompt="$(prompt_of "$p")"
    for arm in $arms; do
        d="$(arm_dir "$arm")" || { echo "run.sh: cannot build arm $arm" >&2; exit 2; }
        mkdir -p "$out/$p/$arm"
        for r in $(seq 1 "$reps"); do
            stem="$out/$p/$arm/$r"
            [ -f "$stem.summary.json" ] && continue
            if [ -n "$ceiling" ]; then
                s="$(spent)" && [ -n "$s" ] || { echo "run.sh: cannot sum the spent cost-eq before $p/$arm/$r - stopped" >&2; exit 3; }
                if [ "$s" -ge "$ceiling" ]; then
                    echo "run.sh: spent $s cost-eq, ceiling $ceiling reached before $p/$arm/$r - stopped" >&2
                    exit 3
                fi
            fi
            # steering-cull probe, bank-preflighted per probe, explicit permission mode, budget-capped
            # launch-profile-ok: the eval measures the bare steering text, so the child gets no profile and no tools
            (cd "$d/repo" && timeout "$tmo" "$CLAUDE_BIN" -p "$prompt" --model "$model" --tools "" \
                --setting-sources project --effort "$effort" --permission-mode dontAsk --strict-mcp-config \
                --no-session-persistence --output-format json --max-budget-usd "$max_usd") \
                </dev/null >"$stem.raw.json" 2>"$stem.stderr"
            python3 "$CULL" summarize "$stem.raw.json" --probe "$p" >"$stem.summary.json.tmp"
            ce="$(python3 -c 'import json,sys; c=json.load(open(sys.argv[1])).get("cost_eq"); print("" if c is None else c)' \
                "$stem.summary.json.tmp" 2>/dev/null)"
            if python3 -c 'import json,sys; sys.exit(1 if json.load(open(sys.argv[1]))["error"] else 0)' "$stem.summary.json.tmp"; then
                mv "$stem.summary.json.tmp" "$stem.summary.json"
            elif [ -n "$ce" ]; then
                printf '%s\n' "$ce" >>"$out/errored-spend.log"
            fi
            rm -f "$stem.summary.json.tmp"
            if [ -z "$ce" ] && [ -n "$ceiling" ]; then
                echo "run.sh: $p $arm $r reported no usage to bill against the ceiling - stopped" >&2
                exit 3
            fi
            echo "run.sh: $p $arm $r -> $(python3 -c 'import json,sys
try: s=json.load(open(sys.argv[1])); print("pass" if s["pass"] else "fail", s["cost_eq"])
except Exception: print("error, retried on the next run")' "$stem.summary.json")"
        done
    done
done
missing=0
for p in $ids; do
    if [ "$phase" = red ]; then arms="baseline red-$(row_of "$p")"; else arms="cut"; fi
    for arm in $arms; do for r in $(seq 1 "$reps"); do
        [ -f "$out/$p/$arm/$r.summary.json" ] || missing=$((missing + 1))
    done; done
done
if [ "$missing" -gt 0 ]; then
    echo "run.sh: $phase phase incomplete, $missing runs errored (re-run to retry), spent $(spent) cost-eq" >&2
    exit 4
fi
echo "run.sh: $phase phase done, spent $(spent) cost-eq"
