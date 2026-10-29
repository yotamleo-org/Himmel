#!/usr/bin/env bash
# scripts/eval/routing/run.sh - the billed arm of the routing eval. Each case is
# one subscription `claude -p` call: the system prompt is the rendered listing (listing.mjs) and
# a forced-choice instruction, the user prompt the case's context and request; the reply is
# {"pick": "<name>" | "none"}. The envelope lands in <out>/<id>.json; a case whose envelope
# exists is skipped, so a stopped run resumes (an errored call leaves none and is retried).
# score.py then writes <out>/results.json, <out>/table.md and one eval-runs ledger row.
#
# usage: run.sh --model M [--out DIR] [--split open|sealed|all] [--cases a,b] [--seed-broken A,B]
#               [--effort E] [--max-usd X] [--ceiling-usd X] [--timeout S] [--no-ledger] [--dry-run]
#   --dry-run       list the cases (a sealed case by id only), the listing size and the call; no call
#   --seed-broken   render the listing with B carrying A's description (listing.mjs): the control
#   --max-usd       per-call budget, passed as --max-budget-usd (default 0.10)
#   --ceiling-usd   stop before the next call once <out> has spent this much (default 5; three
#                   models stay under $15)
# The child runs from an empty scratch cwd with --setting-sources project, --tools "",
# --strict-mcp-config and --disable-slash-commands, so it sees only the listing text: no
# CLAUDE.md, hooks, memory, skills or MCP servers. Before each call usage-preflight must print
# PROCEED, else the run stops (exit 3).
# Env: RT_CLAUDE (default claude), RT_PREFLIGHT (default scripts/lib/usage-preflight.sh),
#      RT_REPO, RT_INVENTORY and RT_CASES (default this repo, inventory.json, cases/) - the test
#      seams.
# Exit: 0 done; 2 usage, an <out> run under another config, unreadable cases or listing, or
#       score.py refused its input; 3 stopped before a call (bank refusal, ceiling, the spend so
#       far unreadable) or after one (a call with no cost to sum); 4 run, but some calls errored
#       (re-run to retry).
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../../.." && pwd)"
CLAUDE_BIN="${RT_CLAUDE:-claude}"
PREFLIGHT="${RT_PREFLIGHT:-$REPO/scripts/lib/usage-preflight.sh}"
CASES="${RT_CASES:-$HERE/cases}"
SOURCES=(--repo "${RT_REPO:-$REPO}" --inventory "${RT_INVENTORY:-$HERE/inventory.json}")
model=""; out=""; split=all; only=""; seed=""; effort=""; max_usd=0.10; ceiling=5; tmo=180
ledger=1; dry=0

die() { echo "run.sh: $1" >&2; exit 2; }
while [ $# -gt 0 ]; do
    case "$1" in
        --model|--out|--split|--cases|--seed-broken|--effort|--max-usd|--ceiling-usd|--timeout)
            [ $# -ge 2 ] || die "$1 needs a value" ;;
    esac
    case "$1" in
        --model) model="$2"; shift 2 ;;
        --out) out="$2"; shift 2 ;;
        --split) split="$2"; shift 2 ;;
        --cases) only="$2"; shift 2 ;;
        --seed-broken) seed="$2"; shift 2 ;;
        --effort) effort="$2"; shift 2 ;;
        --max-usd) max_usd="$2"; shift 2 ;;
        --ceiling-usd) ceiling="$2"; shift 2 ;;
        --timeout) tmo="$2"; shift 2 ;;
        --no-ledger) ledger=0; shift ;;
        --dry-run) dry=1; shift ;;
        *) die "unknown argument: $1" ;;
    esac
done
[ -n "$model" ] || die "--model is required"
case "$split" in open|sealed|all) ;; *) die "--split open|sealed|all, not '$split'" ;; esac
case "$tmo" in ''|*[!0-9]*|0|00*) die "--timeout needs a positive integer of seconds, not '$tmo'" ;; esac
for v in "$max_usd" "$ceiling"; do
    python3 -c 'import sys; sys.exit(0 if float(sys.argv[1]) > 0 else 1)' "$v" 2>/dev/null || die "a usd limit needs a positive number, not '$v'"
done

# shellcheck source=../../lib/prim.sh
. "$REPO/scripts/lib/prim.sh" || exit 2
scratch="$(tmpdir)" || exit 2
trap 'rm -rf "$scratch"' EXIT
listing_args=(--json)
[ -z "$seed" ] || listing_args+=(--seed-broken "$seed")
node "$HERE/listing.mjs" "${SOURCES[@]}" "${listing_args[@]}" >"$scratch/listing.json" || die "listing.mjs failed"
python3 "$HERE/score.py" lint --cases "$CASES" --listing "$scratch/listing.json" >/dev/null || die "the cases do not lint; run score.py lint"

# One line per selected case: id <TAB> split <TAB> request <TAB> context (tabs and newlines folded).
python3 -c 'import json,os,sys
d, split, only = sys.argv[1], sys.argv[2], [x for x in sys.argv[3].split(",") if x]
seen = []
for half in ("open", "sealed"):
    for line in open(os.path.join(d, half + ".jsonl"), encoding="utf-8"):
        if not line.strip():
            continue
        c = json.loads(line)
        seen.append(c["id"])
        if split in ("all", half) and (not only or c["id"] in only):
            f = lambda s: " ".join(s.split())
            print("\t".join((c["id"], half, f(c["request"]), f(c["context"]))))
bad = [x for x in only if x not in seen]
if bad:
    sys.exit("unknown case: " + ",".join(bad))' "$CASES" "$split" "$only" >"$scratch/cases.tsv" || die "cannot read the cases"

cat >"$scratch/system.txt" <<'EOF'
You route a request made in a Claude Code session. The session can invoke the entries listed
below: skills and commands through the Skill tool, agents through the Agent tool, and MCP tools.
Name the ONE entry you would invoke first to handle the request, or none if you would handle it
with ordinary tools (Bash, Read, Edit, web search) and no listed entry.
Reply with exactly one JSON line and nothing else: {"pick": "<exact listed name>"} or {"pick": "none"}.

EOF
node "$HERE/listing.mjs" "${SOURCES[@]}" ${seed:+--seed-broken "$seed"} >>"$scratch/system.txt" || die "listing.mjs failed"
lsha="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["sha"])' "$scratch/listing.json")"
psha="$(sha256sum "$scratch/system.txt" | cut -c1-16)"

if [ "$dry" = 1 ]; then
    python3 -c 'import json,sys
t = json.load(open(sys.argv[1]))["tokens"]
print("routing dry run: model %s, listing %s (%d tokens: skill %d, agent %d, mcp %d; owned %d)" % (
    sys.argv[2], sys.argv[3], t["total"], t["skill"], t["agent"], t["mcp"], t["owned"]))
for line in open(sys.argv[4], encoding="utf-8"):
    cid, half, req, ctx = line.rstrip("\n").split("\t")
    print("%s %-6s %s" % (cid, half, req if half == "open" else "(sealed)"))' \
        "$scratch/listing.json" "$model" "$lsha" "$scratch/cases.tsv"
    echo "per case: one $model call, system prompt $psha, no tools, permission mode dontAsk, budget \$$max_usd (run ceiling \$$ceiling)"
    exit 0
fi

# billed-opt-in: HIMMEL_BILLED_OK
[ "${HIMMEL_BILLED_OK:-}" = 1 ] || die "makes real, billed model calls; set HIMMEL_BILLED_OK=1 (on-demand only)"
[ -n "$out" ] || die "--out <dir> is required"
mkdir -p "$out" || exit 2
out="$(cd "$out" && pwd)"
# A resume must ask the same question: same model, effort, listing and prompt.
python3 -c 'import json,os,sys
path = sys.argv[1]
new = {"model": sys.argv[2], "effort": sys.argv[3], "listing_sha": sys.argv[4], "prompt_sha": sys.argv[5], "seed_broken": sys.argv[6]}
if os.path.exists(path) and json.load(open(path)) != new:
    sys.exit(3)
json.dump(new, open(path, "w"))' "$out/run-config.json" "$model" "$effort" "$lsha" "$psha" "$seed"
case $? in
    0) ;;
    3) die "$out was run with another model, effort, listing or prompt (run-config.json); use a fresh --out" ;;
    *) exit 2 ;;
esac
cp "$scratch/listing.json" "$out/listing.json"

# Spent = every kept envelope plus every errored call that reported a cost (errored-spend.log).
spent() { python3 -c 'import json,sys,glob,os
s = 0.0
for p in glob.glob(os.path.join(sys.argv[1], "*.json")):
    if os.path.basename(p) not in ("run-config.json", "listing.json", "results.json"):
        s += float(json.load(open(p)).get("total_cost_usd") or 0)
e = os.path.join(sys.argv[1], "errored-spend.log")
s += sum(float(x) for x in open(e) if x.strip()) if os.path.exists(e) else 0
print("%.4f" % s)' "$out"; }

mkdir -p "$scratch/cwd"
sys_prompt="$(cat "$scratch/system.txt")"
effort_args=()
[ -z "$effort" ] || effort_args=(--effort "$effort")
errored=0
while IFS=$'\t' read -r cid half req ctx; do
    [ -f "$out/$cid.json" ] && continue
    s="$(spent)" || { echo "run.sh: cannot sum the spend before $cid - stopped" >&2; exit 3; }
    if python3 -c 'import sys; sys.exit(0 if float(sys.argv[1]) >= float(sys.argv[2]) else 1)' "$s" "$ceiling"; then
        echo "run.sh: spent \$$s, ceiling \$$ceiling reached before $cid - stopped" >&2
        exit 3
    fi
    if ! pf="$(bash "$PREFLIGHT" 2>&1)" || ! grep -qx PROCEED <<<"$pf"; then
        echo "run.sh: usage-preflight did not PROCEED before $cid - stopped" >&2
        printf '%s\n' "$pf" >&2
        exit 3
    fi
    prompt="Context: ${ctx:-(none)}"$'\n\n'"Request: $req"
    # routing case, bank-preflighted per case, explicit permission mode, budget-capped
    # launch-profile-ok: the eval measures the bare listing text, so the child gets no profile and no tools
    (cd "$scratch/cwd" && timeout "$tmo" "$CLAUDE_BIN" -p "$prompt" --model "$model" "${effort_args[@]}" \
        --system-prompt "$sys_prompt" --tools "" --setting-sources project --strict-mcp-config \
        --disable-slash-commands --permission-mode dontAsk --no-session-persistence \
        --output-format json --max-budget-usd "$max_usd") </dev/null >"$out/$cid.tmp" 2>"$out/$cid.stderr"
    verdict="$(python3 -c 'import json,sys
try:
    env = json.load(open(sys.argv[1]))
except Exception:
    print("nocost"); sys.exit()
cost = env.get("total_cost_usd")
ok = not env.get("is_error") and env.get("subtype") in (None, "success")
print(("ok " if ok else "err ") + ("" if cost is None else str(cost)))' "$out/$cid.tmp")"
    case "$verdict" in
        "ok "?*) mv "$out/$cid.tmp" "$out/$cid.json"; rm -f "$out/$cid.stderr"
                 echo "run.sh: $cid $half -> $(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("result","").strip()[:80])' "$out/$cid.json")" ;;
        "err "?*) printf '%s\n' "${verdict#err }" >>"$out/errored-spend.log"; rm -f "$out/$cid.tmp"
                  errored=$((errored + 1)); echo "run.sh: $cid errored, retried on the next run" >&2 ;;
        *) rm -f "$out/$cid.tmp"
           echo "run.sh: $cid reported no cost to sum against the ceiling - stopped (see $out/$cid.stderr)" >&2
           exit 3 ;;
    esac
done <"$scratch/cases.tsv"

score_args=(score --cases "$CASES" --listing "$out/listing.json" --outputs "$out" --model "$model"
    --only "$(cut -f1 "$scratch/cases.tsv" | paste -sd, -)"
    --json "$out/results.json" --table "$out/table.md"
    --meta-json "{\"seed_broken\": \"$seed\", \"prompt_sha\": \"$psha\"}")
[ "$ledger" = 1 ] || score_args+=(--no-ledger)
python3 "$HERE/score.py" "${score_args[@]}" || exit 2
if [ "$errored" -gt 0 ]; then
    echo "run.sh: $errored call(s) errored (re-run to retry), spent \$$(spent)" >&2
    exit 4
fi
echo "run.sh: done, spent \$$(spent)"
