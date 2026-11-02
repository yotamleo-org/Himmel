#!/usr/bin/env bash
# scripts/eval/relay-cost/run.sh - run the relay options over the fixture set.
#
# usage: run.sh --out <dir> [--fixtures FILE] [--arms sonnet,haiku,script,path] [--max-calls 20] [--max-usd 1]
#   sonnet|haiku  one `claude -p` call per fixture (claude-sonnet-5-5 / claude-haiku-5-5, effort low, no tools,
#                 the relay's delivery rules as the system prompt): the model returns {"to","message"} JSON.
#   script        no model: a succession fixture runs the real relay-batch.sh (its SENDMESSAGE line is the
#                 delivery); a GO or ruling is handed to a recording bus stub as the chief's file, verbatim.
#   path          no model: the chief's text is written to a file and the delivery is only
#                 "Read <path>"; the check also reads the file back.
# Each (arm, fixture) writes <out>/<arm>/<id>.result.json {id, pass, reason, cost_eq_cold, cost_eq_warm, cost_usd, ...};
# one whose file exists is skipped, so a stopped run resumes. relay_cost.py report reads them.
# Model arms make real, billed calls: HIMMEL_BILLED_OK=1 and bank-preflight PROCEED before each call; --max-calls
# caps the model calls of the whole run (default 20, the ticket's cap).
# Env: RELAY_COST_CLAUDE (default claude) and RELAY_COST_PREFLIGHT (default scripts/lib/usage-preflight.sh) are the test seams.
# Exit: 0 done; 2 usage; 3 stopped (bank refusal or call cap).
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../../.." && pwd)"
RC="$HERE/relay_cost.py"
CLAUDE_BIN="${RELAY_COST_CLAUDE:-claude}"
PREFLIGHT="${RELAY_COST_PREFLIGHT:-$REPO/scripts/lib/usage-preflight.sh}"
RELAY_BATCH="$REPO/scripts/handover/chief-kit/relay-batch.sh"
out=""; fixtures="$HERE/fixtures/messages.json"; arms="sonnet,haiku,script,path"; max_calls=20; max_usd=1

die() { echo "run.sh: $1" >&2; exit 2; }
while [ $# -gt 0 ]; do
    [ $# -ge 2 ] || die "$1 needs a value"
    case "$1" in
        --out) out="$2" ;; --fixtures) fixtures="$2" ;; --arms) arms="$2" ;;
        --max-calls) max_calls="$2" ;; --max-usd) max_usd="$2" ;;
        *) die "unknown argument: $1" ;;
    esac
    shift 2
done
[ -n "$out" ] || die "--out <dir> is required"
[ -f "$fixtures" ] || die "no fixtures file $fixtures"
case "$max_calls" in ''|*[!0-9]*|0) die "--max-calls needs a positive integer" ;; esac
for a in ${arms//,/ }; do case "$a" in sonnet|haiku|script|path) ;; *) die "unknown arm: $a" ;; esac; done
case ",$arms," in *,sonnet,*|*,haiku,*)
    # billed-opt-in: HIMMEL_BILLED_OK
    [ "${HIMMEL_BILLED_OK:-}" = 1 ] || die "the model arms make real, billed calls; set HIMMEL_BILLED_OK=1" ;;
esac
mkdir -p "$out" || exit 2
out="$(cd "$out" && pwd)"
# shellcheck source=../../lib/prim.sh
. "$HERE/../../lib/prim.sh" || exit 2
scratch="$(tmpdir)" || exit 2
trap 'rm -rf "$scratch"' EXIT

ids="$(python3 -I -c 'import json,sys; print(" ".join(f["id"] for f in json.load(open(sys.argv[1]))["fixtures"]))' "$fixtures")" || die "unreadable fixtures"
fget() { python3 -I -c 'import json,sys
for f in json.load(open(sys.argv[1]))["fixtures"]:
    if f["id"] == sys.argv[2]: sys.stdout.write(f[sys.argv[3]])' "$fixtures" "$1" "$2"; }

# shellcheck disable=SC2016  # the backticks and angle brackets are literal prompt text
SYSTEM='You are a message relay. You receive one command and deliver it by replying with exactly one JSON object {"to": "<session>", "message": "<text>"} and nothing else.
- A command "DELIVER <session>" followed by a body: "to" is the session and "message" is the body, byte for byte. Never paraphrase, summarize, reorder or add to it.
- A command "SUCCESSION-RELAY sender=S successor=C worker=W nonce=T": "to" is W and "message" is this text with S, C and T filled in, on one line:
SUCCESSION relay from S: your chief is now C. Your current token `T`. This is an S1 relay: accept it and keep working your sealed scope. Write your quote-back in your very next tool batch, with no ListAgents, also while wrapping. Your quote-back (no reply needed) is a Results bullet containing exactly the following, with nothing after it on that line: SUCCESSION accepted: C replaces S'

calls=0
model_arm() { # $1 arm, $2 model id
    local arm="$1" model="$2" id d="$out/$1"
    mkdir -p "$d"
    for id in $ids; do
        [ -f "$d/$id.result.json" ] && continue
        [ "$calls" -lt "$max_calls" ] || { echo "run.sh: call cap $max_calls reached" >&2; return 3; }
        [ "$(bash "$PREFLIGHT" 2>/dev/null | tail -n 1)" = PROCEED ] || { echo "run.sh: bank-preflight did not print PROCEED" >&2; return 3; }
        calls=$((calls + 1))
        local to input prompt
        to="$(fget "$id" to)"; input="$(fget "$id" input)"
        case "$input" in SUCCESSION-RELAY*) prompt="$input" ;; *) prompt="DELIVER $to"$'\n'"$input" ;; esac
        # the relay eval's own call: explicit model and permission mode, no tools, budget-capped, bank-preflighted above
        # launch-profile-ok: the eval measures the relay's delivery rules, not a worker profile
        (cd "$scratch" && "$CLAUDE_BIN" -p "$prompt" --model "$model" --effort low --system-prompt "$SYSTEM" --tools "" \
            --permission-mode dontAsk --output-format stream-json --verbose --max-budget-usd "$max_usd" \
            --setting-sources user --strict-mcp-config --no-session-persistence) >"$d/$id.stream.jsonl" 2>"$d/$id.stderr"
        python3 -I "$RC" price "$d/$id.stream.jsonl" >"$scratch/price.json" || return 2
        python3 -I -c 'import json,sys
p = json.load(open(sys.argv[1])); reply = p.get("reply", "")
a, b = reply.find("{"), reply.rfind("}")
try: delivery = json.loads(reply[a:b + 1])
except ValueError: delivery = None
json.dump(delivery, open(sys.argv[2], "w"))' "$scratch/price.json" "$d/$id.delivery.json"
        finish "$arm" "$id" "$d/$id.delivery.json" ""
    done
}

# finish <arm> <id> <delivery file> <path file>: check the delivery, write the result row (price fields from $scratch/price.json when present).
finish() {
    local arm="$1" id="$2" dfile="$3" pfile="$4" msg rc=0
    if [ -n "$pfile" ]; then
        msg="$(python3 -I "$RC" check --fixtures "$fixtures" --id "$id" --delivery "$dfile" --path-file "$pfile")" || rc=$?
    else
        msg="$(python3 -I "$RC" check --fixtures "$fixtures" --id "$id" --delivery "$dfile")" || rc=$?
    fi
    python3 -I -c 'import json,os,sys
arm, fid, rc, msg, out, pj = sys.argv[1:7]
row = {"id": fid, "arm": arm, "pass": rc == "0", "reason": msg}
if os.path.exists(pj):
    p = json.load(open(pj)); row.update({k: p.get(k) for k in ("input", "cache_read", "cache_creation", "output", "cost_eq_cold", "cost_eq_warm", "cost_usd", "error")})
else:
    row.update({"cost_eq_cold": 0, "cost_eq_warm": 0, "cost_usd": 0})
json.dump(row, open(out, "w"), indent=1)' "$arm" "$id" "$rc" "$msg" "$out/$arm/$id.result.json" "$scratch/price.json"
    echo "$arm $msg"
    rm -f "$scratch/price.json"
}

script_arm() {
    local d="$out/script" id kind to input
    mkdir -p "$d"
    local bus="$scratch/bus.sh" log="$scratch/bus.log"
    # shellcheck disable=SC2016  # $2 and $3 expand in the stub, not here
    # read-sink-ok: the stub only reads the body file this runner wrote under its own scratch dir
    printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$2" > "%s"; cat "$3" >> "%s"\n' "$log" "$log" > "$bus"
    for id in $ids; do
        [ -f "$d/$id.result.json" ] && continue
        kind="$(fget "$id" kind)"; to="$(fget "$id" to)"; input="$(fget "$id" input)"
        if [ "$kind" = succession ]; then
            # the real relay-batch.sh over a one-worker chief doc: the SENDMESSAGE line is the delivery
            local sender successor token w="$scratch/w.$id"
            mkdir -p "$w"
            sender="$(printf '%s' "$input" | sed -n 's/.*sender=\([^ ]*\).*/\1/p')"
            successor="$(printf '%s' "$input" | sed -n 's/.*successor=\([^ ]*\).*/\1/p')"
            token="$(printf '%s' "$input" | sed -n 's/.*nonce=\([^ ]*\).*/\1/p')"
            # shellcheck disable=SC2016  # the backticks are literal Live state markers
            printf '# chief\n\n## Live state\n\nworkers: `W1:%s:lock:1`\n\n## Results\n' "$token" >"$w/$sender.md"
            : >"$w/$to.md"
            printf '{"schema":1,"workers":[{"doc":"%s","label":"W1","lane":"native"}]}\n' "$w/$to.md" >"$w/$sender.fleet.json"
            printf '#!/usr/bin/env bash\nprintf "1\\t%s\\topus\\t200000\\n"\n' "$to" >"$w/census.sh"
            # an empty HIMMEL_BUS_NAME means no bus identity, so the SENDMESSAGE line is printed
            ( HIMMEL_BUS_NAME='' BRIDGE_ROOT="$w/bridge" RELAY_BATCH_CENSUS="$w/census.sh" RELAY_BATCH_BUS="$bus" \
                bash "$RELAY_BATCH" "$w/$sender.md" --successor "$successor" ) >"$w/out.txt" 2>&1
            python3 -I -c 'import json,sys
for line in open(sys.argv[1]):
    if line.startswith("SENDMESSAGE to="):
        head, _, text = line.rstrip("\n").partition(" :: ")
        json.dump({"to": head[len("SENDMESSAGE to="):], "message": text}, open(sys.argv[2], "w")); break
else:
    json.dump(None, open(sys.argv[2], "w"))' "$w/out.txt" "$d/$id.delivery.json"
        else
            # the chief hands the text over as a file; the script sends it as it is
            printf '%s' "$input" >"$scratch/$id.body"
            bash "$bus" send "$to" "$scratch/$id.body"
            python3 -I -c 'import json,sys
lines = open(sys.argv[1]).read().split("\n", 1)
json.dump({"to": lines[0], "message": lines[1].rstrip("\n")}, open(sys.argv[2], "w"))' "$log" "$d/$id.delivery.json"
        fi
        finish script "$id" "$d/$id.delivery.json" ""
    done
}

path_arm() {
    local d="$out/path" id to
    mkdir -p "$d"
    for id in $ids; do
        [ -f "$d/$id.result.json" ] && continue
        to="$(fget "$id" to)"
        fget "$id" expected >"$d/$id.msg"
        python3 -I -c 'import json,sys
json.dump({"to": sys.argv[1], "message": "Read " + sys.argv[2] + ": that file is your message."}, open(sys.argv[3], "w"))' "$to" "$d/$id.msg" "$d/$id.delivery.json"
        finish path "$id" "$d/$id.delivery.json" "$d/$id.msg"
    done
}

rcode=0
for a in ${arms//,/ }; do
    case "$a" in
        sonnet) model_arm sonnet claude-sonnet-5-5 || rcode=$? ;;
        haiku) model_arm haiku claude-haiku-5-5 || rcode=$? ;;
        script) script_arm ;;
        path) path_arm ;;
    esac
    [ "$rcode" -eq 0 ] || exit "$rcode"
done
exit 0
