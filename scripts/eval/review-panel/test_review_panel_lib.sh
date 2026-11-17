# shellcheck shell=bash
# shellcheck disable=SC2034,SC2153,SC2154  # state and helpers are shared through the sourced lib
export HIMMEL_BILLED_OK=1   # stub panel only; run.sh refuses a bare run

HERE="$(cd "$(dirname "$0")" && pwd)"
SCORE="$HERE/score.py"
RUN="$HERE/run.sh"
FIX="$HERE/fixtures"
KEY="$HERE/key/seeds.json"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/review-panel-test.XXXXXX")" || { echo "test-review-panel: mktemp -d failed" >&2; exit 1; }  # prim-ok: the suite scratch dir, removed by its EXIT trap
trap 'rm -rf "$TMP"' EXIT
# Never the live ledger, whatever a case forgets to pass.
export HIMMEL_EVAL_RUNS_LEDGER="$TMP/never.jsonl"

PASS=0; FAIL=0
# The integrity, split and sweep rows below drive the 24 synthetic case-* cases through a temp copy of the
# fixtures and the key; the shipped real-* corpus (RL3) has its own rows at the end, since each real case's lint
# applies its diff to its base commit.
FIX_ALL="$FIX"; KEY_ALL="$KEY"
pass() { PASS=$((PASS + 1)); echo "PASS $1"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL $1"; }
eq() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1: expected '$3', got '$2'"; fi; }
has() { case "$2" in *"$3"*) pass "$1";; *) fail "$1: '$3' not in '$2'";; esac; }

command -v python3 >/dev/null 2>&1 || { echo "SKIP test-review-panel: python3 not on PATH"; exit 0; }
mkdir -p "$TMP/syn/fixtures"; cp "$FIX_ALL"/case-*.patch "$TMP/syn/fixtures/"
python3 -c 'import json,sys; k=json.load(open(sys.argv[1])); k["cases"]={c: v for c, v in k["cases"].items() if c.startswith("case-")}; json.dump(k, open(sys.argv[2], "w"))' "$KEY_ALL" "$TMP/syn/seeds.json"
FIX="$TMP/syn/fixtures"; KEY="$TMP/syn/seeds.json"

# metric <scores.json> <name> - one metric from score.py --json output.
metric() { python3 -c 'import json,sys; v=json.load(open(sys.argv[1]))["metrics"].get(sys.argv[2]); print("null" if v is None else (round(v,4) if isinstance(v,float) else v))' "$1" "$2"; }
jget() { python3 -c 'import json,sys
v=json.load(open(sys.argv[1]))
for k in sys.argv[2].split("/"): v=v.get(k) if isinstance(v,dict) else None
print(json.dumps(v) if isinstance(v,(dict,list,bool)) or v is None else v)' "$1" "$2"; }
# case_of <pair> <kind> - the opaque case id the key gives that twin.
case_of() { python3 -c 'import json,sys; k=json.load(open(sys.argv[1]))["cases"]; print([c for c,v in sorted(k.items()) if v["pair"]==sys.argv[2] and v["kind"]==sys.argv[3]][0])' "$KEY" "$1" "$2"; }
seed_line() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["cases"][sys.argv[2]]["defects"][0]["line"])' "$KEY" "$1"; }
seed_file() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["cases"][sys.argv[2]]["defects"][0]["file"])' "$KEY" "$1"; }

# review <out-file> <critic> <severity:file:line:text>... - a canned merged panel block.
review() {
  local out="$1" critic="$2"; shift 2
  python3 - "$out" "$critic" "$@" <<'PY'
import sys
out, critic, items = sys.argv[1], sys.argv[2], sys.argv[3:]
secs = {"crit": [], "imp": [], "sug": []}
for n, it in enumerate(items, 1):
    sev, f, line, text = it.split(":", 3)
    secs[sev].append("- [%s-%d]: %s [%s:%s]" % (critic, n, text, f, line))
with open(out, "w") as fh:
    fh.write("# Critic Panel Review (1/1 critics responded)\n\n")
    for head, k in (("Critical Issues", "crit"), ("Important Issues", "imp"), ("Suggestions", "sug")):
        fh.write("## %s (%d found)\n" % (head, len(secs[k])))
        fh.write("".join(l + "\n" for l in secs[k]))
        fh.write("\n")
PY
}
