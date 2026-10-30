#!/usr/bin/env bash
# scripts/eval/routing/test-score.sh - suite for the routing eval: the listing renderer, the
# case lint, the scorer's known scores, the seeded-broken control and run.sh, driven by a stub
# claude (a lexical router: it picks the entry whose description shares the most words with
# the request, the first listed on a tie, none on no overlap) and a stub bank-preflight over a
# fixture listing. No model call.
set -uo pipefail
export HIMMEL_BILLED_OK=1   # stub claude only; run.sh refuses a bare run

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../../.." && pwd)"
RUN="$HERE/run.sh"
SCORE="$HERE/score.py"
LISTING="$HERE/listing.mjs"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/routing-test.XXXXXX")" || { echo "test-score: mktemp -d failed" >&2; exit 1; }
trap 'rm -rf "$TMP"' EXIT
export HIMMEL_EVAL_RUNS_LEDGER="$TMP/eval-runs.jsonl"

PASS=0; FAIL=0
pass() { PASS=$((PASS + 1)); echo "PASS $1"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL $1"; }
eq() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1: expected '$3', got '$2'"; fi; }
has() { case "$2" in *"$3"*) pass "$1";; *) fail "$1: '$3' not in '$2'";; esac; }
hasnt() { case "$2" in *"$3"*) fail "$1: '$3' found";; *) pass "$1";; esac; }

for t in python3 node; do
    command -v "$t" >/dev/null 2>&1 || { echo "SKIP test-score: $t not on PATH"; exit 0; }
done

# --- the live listing and cases ---
node "$LISTING" --json >"$TMP/live.json" 2>"$TMP/live.err"
eq "listing: the live inventory renders" "$?" "0"
eq "listing: owned skill, plugin skill, agent and MCP tool are listed" "$(python3 -c 'import json,sys
n={e["name"] for e in json.load(open(sys.argv[1]))["entries"]}
print(all(x in n for x in ("test-audit","himmel-ops:pr-check","judge","mcp__himmel-bus__send","mcp__qmd__query")))' "$TMP/live.json")" "True"
eq "lint: the live cases lint against the live listing" "$(python3 "$SCORE" lint --listing "$TMP/live.json" 2>&1 >/dev/null; echo $?)" "0"
live_before="$(cd "$REPO" && git status --porcelain -- .claude marketplace/plugins)"
node "$LISTING" --seed-broken test-audit,unslop >"$TMP/seeded-live.txt"
eq "seed-broken: B carries A's description in the output" \
    "$(grep -c -F "$(grep '^- test-audit: ' "$TMP/seeded-live.txt" | sed 's/^- test-audit: //')" "$TMP/seeded-live.txt")" "2"
eq "seed-broken: no live description file changes" "$(cd "$REPO" && git status --porcelain -- .claude marketplace/plugins)" "$live_before"
eq "seed-broken: an unlisted name is refused" "$(node "$LISTING" --seed-broken test-audit,nope >/dev/null 2>&1; echo $?)" "2"

dry="$(env -u HIMMEL_BILLED_OK bash "$RUN" --model haiku --dry-run 2>&1)"
eq "dry run: exits 0 with no billed opt-in" "$?" "0"
has "dry run: lists an open case's request" "$dry" "o01 open   btw as we used more of code rabbit"
first_sealed="$(python3 -c 'import json,sys; print(json.loads(open(sys.argv[1]).readline())["id"])' "$HERE/cases/sealed.jsonl")"
# ids of the sealed cases whose request appears on stdin; --plant appends the first one first
leaks() { python3 -c 'import json,sys
cases = [json.loads(l) for l in open(sys.argv[1], encoding="utf-8") if l.strip()]
text = sys.stdin.read() + (cases[0]["request"] if sys.argv[2:] == ["--plant"] else "")
print(" ".join(c["id"] for c in cases if c["request"] in text))' "$HERE/cases/sealed.jsonl" "$@"; }
has "dry run: lists a sealed case by id" "$dry" "$first_sealed sealed (sealed)"
eq "dry run: never prints a sealed request" "$(leaks <<<"$dry")" ""
has "dry run: the leak check catches a planted sealed request" "$(leaks --plant <<<"$dry")" "$first_sealed"
eq "dry run: one line per case, each case once" "$(grep -oE '^[os][0-9]+ ' <<<"$dry" | tr -d ' ' | sort)" \
    "$(python3 -c 'import json,sys; [print(json.loads(l)["id"]) for f in sys.argv[1:] for l in open(f, encoding="utf-8") if l.strip()]' "$HERE/cases/open.jsonl" "$HERE/cases/sealed.jsonl" | sort)"
eq "billed run: refused without HIMMEL_BILLED_OK" "$(env -u HIMMEL_BILLED_OK bash "$RUN" --model haiku --out "$TMP/x" >/dev/null 2>&1; echo $?)" "2"

# --- fixture listing, cases, stub claude and stub preflight ---
FIX="$TMP/fix"
mkdir -p "$FIX/repo/.claude/agents" "$FIX/cases"
skill() { mkdir -p "$FIX/repo/.claude/skills/$1"; printf -- '---\nname: %s\ndescription: %s\n---\nbody\n' "$1" "$2" >"$FIX/repo/.claude/skills/$1/SKILL.md"; }
skill brew-coffee "Brew espresso coffee from beans"
skill water-plants "Water garden plants with the hose"
skill file-taxes "File the annual income tax return"
skill tune-guitar "Tune guitar strings to pitch"
printf -- '---\nname: fix-bike\ndescription: Repair a bicycle chain or a punctured tyre\n---\n' >"$FIX/repo/.claude/agents/fix-bike.md"
printf '{"plugins": [], "mcp": {}, "external": "external.json"}\n' >"$FIX/inventory.json"
printf '{"skills": [], "agents": [], "mcp": [{"name": "mcp__wx__forecast", "description": "Weather forecast for rain"}]}\n' >"$FIX/external.json"
# Known scores. open: 16 exact, 2 near, 2 miss. sealed: 18 exact, 2 false.
python3 -c 'import json,sys
d = sys.argv[1]
want = {
 "open": [("brew espresso coffee", "brew-coffee", [])] * 4 + [("water the garden plants", "water-plants", [])] * 4
       + [("annual income tax return", "file-taxes", [])] * 4 + [("bicycle chain repair", "fix-bike", [])] * 2
       + [("weather forecast rain", "mcp__wx__forecast", [])] * 1 + [("hello there friend", "none", [])] * 1
       + [("water the garden plants", "file-taxes", ["water-plants"])] * 2 + [("hello there friend", "brew-coffee", [])] * 2,
 "sealed": [("brew espresso coffee", "brew-coffee", [])] * 5 + [("water the garden plants", "water-plants", [])] * 5
       + [("annual income tax return", "file-taxes", [])] * 4 + [("bicycle chain repair", "fix-bike", [])] * 2
       + [("hello there friend", "none", [])] * 2 + [("brew espresso coffee", "tune-guitar", [])] * 2,
}
for half, rows in want.items():
    with open("%s/%s.jsonl" % (d, half), "w") as fh:
        for i, (req, exp, near) in enumerate(rows, 1):
            fh.write(json.dumps({"id": "%s%02d" % (half[0], i), "split": half, "request": req, "context": "",
                                 "expect": exp, "near": near, "source": "fixture"}) + "\n")' "$FIX/cases"
cat >"$TMP/claude" <<'EOF'
#!/usr/bin/env python3
import json, os, re, sys
a = sys.argv[1:]
sysp, prompt = a[a.index("--system-prompt") + 1], a[a.index("-p") + 1]
with open(os.environ["STUB_LOG"], "a") as fh:
    fh.write(" ".join(x for x in a if x.startswith("--")) + " budget=" + a[a.index("--max-budget-usd") + 1] + "\n")
words = lambda s: {w for w in re.findall(r"[a-z]+", s.lower()) if len(w) > 3}
req = words(prompt.split("Request:", 1)[1])
best, pick = 0, "none"
for m in re.finditer(r"^- ([^:\s]+): (.*)$", sysp, re.M):
    n = len(req & words(m.group(2)))
    if n > best:
        best, pick = n, m.group(1)
err = os.environ.get("STUB_ERROR") == "1"
env = {"type": "result", "subtype": "error_max_budget_usd" if err else "success", "is_error": err,
       "result": json.dumps({"pick": pick}), "total_cost_usd": 0.001}
if os.environ.get("STUB_NOCOST") == "1":
    del env["total_cost_usd"]
print(json.dumps(env))
EOF
chmod +x "$TMP/claude"
# shellcheck disable=SC2016  # the stub expands STUB_BANK when it runs
printf '#!/usr/bin/env bash\n[ "${STUB_BANK:-}" = 1 ] && echo SKIPPED-BANK || echo PROCEED\n' >"$TMP/preflight"
unset STUB_ERROR STUB_NOCOST STUB_BANK
export RT_CLAUDE="$TMP/claude" RT_PREFLIGHT="$TMP/preflight" STUB_LOG="$TMP/calls.log"
export RT_REPO="$FIX/repo" RT_INVENTORY="$FIX/inventory.json" RT_CASES="$FIX/cases"
fix_sha() { cat "$FIX"/repo/.claude/skills/*/SKILL.md "$FIX"/repo/.claude/agents/*.md | python3 -c 'import hashlib,sys; print(hashlib.sha256(sys.stdin.buffer.read()).hexdigest())'; }
fix_before="$(fix_sha)"
metric() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["metrics"][sys.argv[2]])' "$1" "$2"; }

# --- the fake model's known scores ---
bash "$RUN" --model haiku --out "$TMP/base" >"$TMP/base.log" 2>&1
eq "run: the fixture sweep exits 0" "$?" "0"
eq "run: one call per case" "$(wc -l <"$TMP/calls.log" | tr -d ' ')" "40"
call="$(head -1 "$TMP/calls.log")"
has "run: the call declares an explicit permission mode" "$call" "--permission-mode"
has "run: the call caps its spend at --max-usd" "$call" "budget=0.10"
has "run: the call parses json output" "$call" "--output-format"
hasnt "run: the call never bypasses permissions" "$(grep -F -- --permission-mode "$RUN")" "bypassPermissions"
eq "score: accuracy 34 of 40" "$(metric "$TMP/base/results.json" accuracy)" "0.85"
eq "score: open accuracy 16 of 20" "$(metric "$TMP/base/results.json" open.accuracy)" "0.8"
eq "score: open near rate 2 of 20" "$(metric "$TMP/base/results.json" open.near_rate)" "0.1"
eq "score: open miss rate 2 of 20" "$(metric "$TMP/base/results.json" open.miss_rate)" "0.1"
eq "score: sealed accuracy 18 of 20" "$(metric "$TMP/base/results.json" sealed.accuracy)" "0.9"
eq "score: sealed false-pick rate 2 of 20" "$(metric "$TMP/base/results.json" sealed.false_pick_rate)" "0.1"
eq "score: the spend is summed" "$(metric "$TMP/base/results.json" cost_usd)" "0.04"
eq "results: no sealed case gets a per-case row" "$(python3 -c 'import json,sys
print(sorted({r["split"] for r in json.load(open(sys.argv[1]))["cases"]}))' "$TMP/base/results.json")" "['open']"
has "table: an open row shows its expected pick" "$(cat "$TMP/base/table.md")" "| o01 | open | brew-coffee | brew-coffee | exact |"
hasnt "table: no sealed case gets a row" "$(cat "$TMP/base/table.md")" "| s19 |"
has "table: the sealed half is one aggregate line" "$(cat "$TMP/base/table.md")" "sealed: 18 of 20 exact"
eq "run: a sealed progress line says only that the case is done" "$(grep -F ' s19 ' "$TMP/base.log")" "run.sh: s19 sealed done"
eq "committed: no results file names a sealed case" "$(grep -lE '\| s[0-9]+ \||"id": "s[0-9]+"' "$HERE"/results/* 2>/dev/null)" ""
eq "ledger: one routing row with per-case exact and false_pick" "$(python3 -c 'import json,sys
r=[json.loads(l) for l in open(sys.argv[1])]
print(len(r), r[0]["eval"], r[0]["model"], r[0]["cases"]["s19"], r[0]["ci_method"])' "$HIMMEL_EVAL_RUNS_LEDGER")" \
    "1 routing haiku {'exact': 0, 'false_pick': 1} wilson"

# --- resume, config pinning, ceiling, bank refusal, errored calls ---
: >"$TMP/calls.log"
bash "$RUN" --model haiku --out "$TMP/base" --no-ledger >/dev/null 2>&1
eq "resume: a finished run exits 0" "$?" "0"
eq "resume: a finished run makes no call" "$(wc -l <"$TMP/calls.log" | tr -d ' ')" "0"
eq "resume: another model on the same out is refused" "$(bash "$RUN" --model sonnet --out "$TMP/base" >/dev/null 2>&1; echo $?)" "2"
cp -R "$FIX/cases" "$TMP/cases-edited"
sed -i.bak 's/"request": "/"request": "Please /' "$TMP/cases-edited/open.jsonl"
eq "resume: an edited case set on the same out is refused" "$(RT_CASES="$TMP/cases-edited" bash "$RUN" --model haiku --out "$TMP/base" >/dev/null 2>&1; echo $?)" "2"
eq "limits: an infinite ceiling is refused" "$(bash "$RUN" --model haiku --ceiling-usd inf --dry-run >/dev/null 2>&1; echo $?)" "2"
eq "limits: a NaN per-call cap is refused" "$(bash "$RUN" --model haiku --max-usd nan --dry-run >/dev/null 2>&1; echo $?)" "2"
eq "cases: a selection that matches nothing is refused" "$(bash "$RUN" --model haiku --split open --cases s01 --dry-run >/dev/null 2>&1; echo $?)" "2"
mkdir -p "$TMP/two"
printf '%s\n' '{"subtype": "success", "result": "{\"pick\": \"brew-coffee\"}\n{\"pick\": \"none\"}", "total_cost_usd": 0.001}' >"$TMP/two/o01.json"
python3 "$HERE/score.py" score --cases "$FIX/cases" --listing "$TMP/base/listing.json" --outputs "$TMP/two" --only o01 \
    --json "$TMP/two/results.json" --no-ledger >/dev/null
eq "score: the first of two picks is the one scored" "$(metric "$TMP/two/results.json" accuracy)" "1.0"
eq "score: part of the sealed half is refused" "$(python3 "$HERE/score.py" score --cases "$FIX/cases" --listing "$TMP/base/listing.json" --outputs "$TMP/base" --only o01,s19 --no-ledger >/dev/null 2>&1; echo $?)" "2"
eq "ceiling: stops before the call whose cap would cross it" "$(bash "$RUN" --model haiku --out "$TMP/ceil" --max-usd 0.001 --ceiling-usd 0.0025 --no-ledger >/dev/null 2>&1; echo $?)" "3"
eq "ceiling: two calls made before the stop" "$(find "$TMP/ceil" -name '[os][0-9]*.json' | wc -l | tr -d ' ')" "2"
: >"$TMP/calls.log"
eq "preflight: a bank refusal stops the run" "$(STUB_BANK=1 bash "$RUN" --model haiku --out "$TMP/bank" --no-ledger >/dev/null 2>&1; echo $?)" "3"
eq "preflight: no call after a bank refusal" "$(wc -l <"$TMP/calls.log" | tr -d ' ')" "0"
eq "errored calls: exit 4" "$(STUB_ERROR=1 bash "$RUN" --model haiku --out "$TMP/err" --split open --no-ledger >/dev/null 2>&1; echo $?)" "4"
eq "errored calls: every case unscored, none kept" "$(metric "$TMP/err/results.json" unscored)" "20"
eq "errored calls: their spend is in the cost" "$(metric "$TMP/err/results.json" cost_usd)" "0.02"
STUB_ERROR=1 bash "$RUN" --model haiku --out "$TMP/errs" --split sealed --no-ledger >"$TMP/errs.log" 2>&1
eq "errored calls: a sealed unscored case is counted, never named" "$(python3 -c 'import json,sys
d = json.load(open(sys.argv[1])); print(d["metrics"]["unscored"], len(d["unscored"]))' "$TMP/errs/results.json") $(grep -c 'UNSCORED s' "$TMP/errs.log")" "20 0 0"
eq "no cost: a call with no cost stops the run" "$(STUB_NOCOST=1 bash "$RUN" --model haiku --out "$TMP/nocost" --no-ledger >/dev/null 2>&1; echo $?)" "3"
eq "no cost: the call is charged at the per-call cap" "$(cat "$TMP/nocost/errored-spend.log" 2>/dev/null)" "0.10"
mkdir -p "$TMP/held/.lock"
: >"$TMP/calls.log"
eq "lock: an out another run holds is refused" "$(bash "$RUN" --model haiku --out "$TMP/held" --no-ledger >/dev/null 2>&1; echo $?)" "3"
eq "lock: no call on a held out" "$(wc -l <"$TMP/calls.log" | tr -d ' ')" "0"
eq "lock: a finished run releases its out" "$(find "$TMP/base" -maxdepth 1 -name .lock | wc -l | tr -d ' ')" "0"

# --- the seeded-broken control: water-plants given brew-coffee's trigger text ---
bash "$RUN" --model haiku --out "$TMP/seeded" --seed-broken brew-coffee,water-plants --no-ledger >/dev/null 2>&1
eq "control: the seeded sweep exits 0" "$?" "0"
drop="$(python3 -c 'import json,sys
b, s = (json.load(open(p))["metrics"]["sealed.accuracy"] for p in sys.argv[1:])
print(round((b - s) * 100))' "$TMP/base/results.json" "$TMP/seeded/results.json")"
eq "control: sealed accuracy drops 25 points" "$drop" "25"
eq "control: the drop is at least 15 points" "$([ "$drop" -ge 15 ] && echo yes)" "yes"
eq "control: the fixture description files are unchanged" "$(fix_sha)" "$fix_before"

echo "test-score: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
