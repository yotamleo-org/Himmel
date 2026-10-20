#!/usr/bin/env bash
# test-doc-reader-agreement.sh - the console-kit readers parse the same handover
# docs independently (tick.sh, board.mjs, fleet.mjs, close-wrapped-leg.sh, the
# shared leg-tail-status.sh), and test-console-kit-e2e.sh feeds them only
# hand-written canonical bullets. This suite generates docs from a grammar
# (fixtures/doc-reader-agreement/gen.py, fixed seed): the real console.sh
# template with generated `legs:` blocks, and leg docs of canonical bullets plus
# adversarial prose (a backticked leg token, a .md:line cite, a wrapped legs: line,
# a long FINDING tail, `WRAPPED:` with a colon, a mid-doc WRAPPED, a leg-describing
# WRAPPED in a console doc). It runs every reader over every doc and compares what
# each reads with ONE reference parser (gen.py, written from the documented
# grammar; the generator checks it against each doc's built-in intent):
#   console doc  leg set   tick.sh legset=unarmed (--legs "")  | board.mjs | fleet.mjs
#   console doc  malformed tick.sh livestate=MALFORMED
#   leg doc      tail      tick.sh tails= | close-wrapped-leg.sh --check (rc 4 = not WRAPPED)
#   leg doc      PR        board.mjs
# A disagreement prints the doc, the reader and both values.
#
# DRA_READERS=<repo root> points the readers at another tree (a RED replay on a
# parent commit: git archive <parent> scripts | tar -x -C <dir>); the generator,
# reference parser and this suite always come from the checkout.
# Not exercised: a leg doc whose stem carries a non-N<k> prefix (tick keys the raw
# stem, board and fleet derive N<k>); leg-relaunch.sh does not exist; the stability
# scorecard (scripts/eval/stability-scorecard.sh) reads no handover doc.
#
# PLATFORM GUARD: Linux-only like the kit (tick.sh reads pgrep, atq, /proc).
set -uo pipefail

if [ "$(uname -s)" != Linux ]; then
    echo "skip - doc-reader agreement is Linux-only (the kit reads /proc and pgrep)"
    exit 0
fi

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../../.." && pwd)"
GEN="$HERE/fixtures/doc-reader-agreement/gen.py"
REPLAY="${DRA_READERS:-}"
READERS="${DRA_READERS:-$REPO}"
CK="$READERS/scripts/handover/console-kit"
SEED="${DRA_SEED:-20261020}"
N_CONSOLE=24
N_LEG=176
JOBS="${DRA_JOBS:-8}"
# A parent-commit replay predates some readers; a reader the tree lacks is skipped
# there, never counted as a disagreement (that would fail on every doc, proving nothing).
ABSENT=""
for r in board.mjs fleet.mjs close-wrapped-leg.sh; do [ -f "$CK/$r" ] || ABSENT="$ABSENT $r"; done

# ---- one reader over one doc (re-entered through xargs -P) ------------------
# --one '<kind>TAB<doc>': prints `<kind>\t<doc basename>\t<value>` from that reader only
if [ "${1:-}" = --one ]; then
    kind="${2%%$'\t'*}"; doc="${2#*$'\t'}"; base="$(basename "$doc")"
    stub="${DRA_TICK_STUB:-}"
    case "$kind" in
    tick-console)
        out="$(bash "$CK/tick.sh" --doc "$doc" --token tok --legs "" --repo "$READERS" 2>/dev/null | tr ' ' '\n')"
        ls_="$(printf '%s\n' "$out" | sed -n 's/^legset=//p' | head -1)"
        lv="$(printf '%s\n' "$out" | sed -n 's/^livestate=//p' | head -1)"
        # the entry set: legset=unarmed where tick has that field, else the DRIFT labels
        # (a tick that predates legset= names every entry without a live lock there)
        unarmed=""; mal=""; drift=""
        case "$ls_" in STALE:*) unarmed="${ls_#STALE:}"; unarmed="${unarmed#unarmed=}"; unarmed="${unarmed%%;*}" ;; esac
        case "$lv" in *MALFORMED:*) mal="${lv#*MALFORMED:}"; mal="${mal%%;*}" ;; esac
        case "$lv" in *DRIFT:*) drift="${lv#*DRIFT:}"; drift="${drift%%;*}" ;; esac
        printf 'tick-legs\t%s\t%s\n' "$base" "$(printf '%s+%s' "$unarmed" "$drift" | tr ',+' '\n' | grep . | sort -u | paste -sd, -)"
        printf 'tick-malformed\t%s\t%s\n' "$base" "$(printf '%s' "$mal" | tr ',+' '\n' | grep . | sort -u | paste -sd, -)"
        ;;
    board-console)
        j="$(mktemp "${DRA_TMP:-/tmp}/b.XXXXXX")" || exit 1
        BOARD_TICK="$stub" node "$CK/board.mjs" --doc "$doc" --legs "" --out "$j.html" --json "$j.json" --repo "$READERS" >/dev/null 2>&1
        printf 'board-legs\t%s\t%s\n' "$base" "$(jq -r '[.legs[].leg] | unique | join(",")' "$j.json" 2>/dev/null || echo '?')"
        rm -f "$j" "$j.html" "$j.json"
        ;;
    fleet-console)
        printf 'fleet-legs\t%s\t%s\n' "$base" "$(node "$CK/fleet.mjs" --doc "$doc" --json 2>/dev/null | jq -r '[.legs[].label] | unique | join(",")' 2>/dev/null || echo '?')"
        ;;
    close-leg)
        bash "$CK/close-wrapped-leg.sh" --check "$doc" >/dev/null 2>&1
        rc=$?
        # rc 4 = tail is not WRAPPED; rc 5 = tail WRAPPED, then no live session matched
        # (the stubbed census has none); any other rc is a failure, never a tail verdict
        case "$rc" in 4) v=notwrapped ;; 5) v=WRAPPED ;; *) v="rc$rc" ;; esac
        printf 'close-tail\t%s\t%s\n' "$base" "$v"
        ;;
    esac
    exit 0
fi

for t in python3 jq node; do
    command -v "$t" >/dev/null 2>&1 || { echo "skip - python3, jq and node are required"; exit 0; }
done

W="$(mktemp -d "${TMPDIR:-/tmp}/dra.XXXXXX")" || { echo "FAIL: mktemp -d" >&2; exit 1; }
trap 'rm -rf "$W"' EXIT

fails=0
pass() { printf 'ok - %s\n' "$1"; }
fail() { printf 'FAIL - %s\n' "$1"; fails=$((fails + 1)); }

# ---- offline stubs and seams (as test-console-kit-e2e.sh) -------------------
export HANDOVER_DIR="$W/root"
mkdir -p "$W/root" "$W/bin" "$W/launch" "$W/state" "$W/digest" "$W/tx" "$W/cache" "$W/work" "$W/out"
printf '#!/usr/bin/env bash\ncase "$*" in *"pr list"*) echo "[]" ;; *) exit 1 ;; esac\n' > "$W/bin/gh"
printf '#!/usr/bin/env bash\nexit 0\n' > "$W/bin/atq"
printf '#!/usr/bin/env bash\nexit 0\n' > "$W/bin/bun"
printf '#!/usr/bin/env bash\nexit 1\n' > "$W/bin/jira"
printf '#!/usr/bin/env bash\necho "TICK legs=none tails=none"\n' > "$W/bin/tickstub"
chmod +x "$W/bin"/*
export PATH="$W/bin:$PATH"
printf '%s\n' '{"five_hour":{"utilization":30},"seven_day":{"utilization":28}}' > "$W/bank.json"
export TICK_BANK_CACHE_FILE="$W/bank.json" CADENCE_BANK_CACHE="$W/bank.json" CADENCE_BANK_SKIP_REFRESH=1
export CADENCE_BANK_LEDGER=/dev/null
export TICK_STATE_DIR="$W/state" TICK_LAUNCH_DIR="$W/launch" TICK_TMPDIR="$W"
export HIMMEL_FAILURE_ROUTES_LOG="$W/routes.jsonl" SUITE_FLAKE_LEDGER="$W/flake.jsonl" SUITE_FLAKE_REPO_ID=dra
export HIMMEL_LEG_FAILURES_LEDGER="$W/leg-failures.jsonl" HIMMEL_EVAL_RUNS_LEDGER="$W/eval-runs.jsonl"
export LEG_DIGEST_STATE_DIR="$W/digest" LEG_DIGEST_SETTLE_MAX=0 LEG_DIGEST_SETTLE_QUIET=0
export BOARD_TRANSCRIPTS="$W/tx" CR_LEDGER="$W/no-cr" BOARD_MIRROR="$W/no-mirror"
export CLOSE_WRAPPED_LEG_PROJECTS_DIR="$W/projects" CLOSE_WRAPPED_LEG_SESSIONS_DIR="$W/sessions"
export LEG_JIRA_STATUS=0
export DRA_TICK_STUB="$W/bin/tickstub" DRA_TMP="$W/out" DRA_READERS="$READERS"

# ---- the console template: one REAL console.sh new --------------------------
printf '#!/usr/bin/env bash\necho "bank-preflight: leg=unknown five_hour=9.0 seven_day=91.0 extra_usage=n/a"\necho PROCEED\n' > "$W/facts-bank.sh"
printf '#!/usr/bin/env bash\necho "#5 [DEMO-1] stub pr (feat/x)"\n' > "$W/facts-prs.sh"
mkdir -p "$W/tpl"
(
    export HIMMELCTL_CACHE_DIR="$W/cache" HANDOVER_REGISTRY="$W/noreg.json" BRIDGE_ROOT="$W/bridge" \
        HANDOFF_FACTS_BANK="$W/facts-bank.sh" HANDOFF_FACTS_PRS="$W/facts-prs.sh" HANDOVER_DIR="$W/tpl" \
        USER_SLUG=u JIRA_PROJECT_KEY=HIMMEL CONSOLE_WORK_DIR="$W/work"
    bash "$REPO/scripts/handover/console/console.sh" new --name tpl-console --bucket himmel >/dev/null 2>&1
)
TPL="$(find "$W/tpl" -name 'HIMMEL-nextleg-*-console.md' | head -1)"
if [ -z "$TPL" ]; then fail "console.sh new produced a console doc"; echo "FAILED: 1"; exit 1; fi
pass "console.sh new produced the template console doc"
if [ -n "$ABSENT" ] && [ -z "$REPLAY" ]; then fail "readers missing from the checkout:$ABSENT"; fi
[ -z "$ABSENT" ] || printf 'note - readers absent in %s, skipped:%s\n' "$READERS" "$ABSENT"

python3 -I "$GEN" gen "$W/gen" "$SEED" "$N_CONSOLE" "$N_LEG" "$TPL" || { fail "generator (reference parser disagrees with the doc intent)"; echo "FAILED: $fails"; exit 1; }
B="$W/gen/u/himmel"
EXPECT="$W/gen/expect.tsv"
rows="$(wc -l < "$EXPECT" | tr -d ' ')"
if [ "$rows" = $((N_CONSOLE + N_LEG)) ]; then pass "generated $rows docs (seed $SEED)"; else fail "generated $rows docs, want $((N_CONSOLE + N_LEG))"; fi

# ---- run every reader (parallel; a serial run blows the time budget) --------
CONS=(); LEGS=()
while IFS=$'\t' read -r kind file _; do
    if [ "$kind" = console ]; then CONS+=("$B/$file"); else LEGS+=("$B/$file"); fi
done < "$EXPECT"

t0=$SECONDS
{
    for d in "${CONS[@]}"; do printf '%s\t%s\n' tick-console "$d"; printf '%s\t%s\n' board-console "$d"; printf '%s\t%s\n' fleet-console "$d"; done
    for d in "${LEGS[@]}"; do printf '%s\t%s\n' close-leg "$d"; done
} | xargs -d '\n' -P "$JOBS" -I{} bash "$0" --one {} 2>/dev/null | sort > "$W/readers.tsv" &
bg=$!

# tick over ALL leg docs at once (its tails= field), with the first console doc as --doc
tickout="$(bash "$CK/tick.sh" --doc "${CONS[0]}" --token tok --legs "${LEGS[*]}" --repo "$READERS" 2>/dev/null | tr ' ' '\n')"
printf '%s\n' "$tickout" | sed -n 's/^tails=//p' | head -1 | tr ',' '\n' > "$W/tails.txt"

# board over ALL leg docs at once (PR extraction), stubbed tick
BOARD_TICK="$W/bin/tickstub" node "$CK/board.mjs" --doc "${CONS[0]}" --legs "${LEGS[*]}" --out "$W/out/all.html" --json "$W/out/all.json" --repo "$READERS" >/dev/null 2>&1
wait "$bg"

# ---- compare with the reference parser --------------------------------------
cmp_out="$(python3 -I - "$EXPECT" "$W/readers.tsv" "$W/tails.txt" "$W/out/all.json" "$ABSENT" <<'PY'
import csv, json, re, sys
expect, readers, tails, board = sys.argv[1:5]
absent = sys.argv[5].split()
read = {}
for ln in open(readers):
    p = ln.rstrip("\n").split("\t")
    if len(p) == 3:
        read[(p[0], p[1])] = p[2]
tick_tail = {}
for ln in open(tails):
    ln = ln.strip()
    m = re.match(r"^(N\d+[a-z]*):(.*)$", ln)
    if m:
        tick_tail[m.group(1)] = re.sub(r"!stale$", "", m.group(2))
try:
    bj = json.load(open(board))
    board_pr = {l["leg"]: l.get("pr") for l in bj.get("legs", [])}
except Exception:
    board_pr = None
n = bad = 0
def disagree(doc, reader, got, want):
    global bad
    bad += 1
    print("DISAGREE %s %s: got [%s] want [%s]" % (doc, reader, got, want))
for row in csv.reader(open(expect), delimiter="\t"):
    if row[0] == "console":
        _, doc, legs, mal = row
        n += 1
        for key in ("tick-legs", "board-legs", "fleet-legs"):
            if {"board-legs": "board.mjs", "fleet-legs": "fleet.mjs"}.get(key) in absent:
                continue
            got = read.get((key, doc), "<no output>")
            if got != legs:
                disagree(doc, key, got, legs)
        got = read.get(("tick-malformed", doc), "<no output>")
        if got != mal:
            disagree(doc, "tick-malformed", got, mal)
    else:
        _, doc, label, tail, pr = row
        n += 1
        got = tick_tail.get(label, "<absent>")
        if got != tail:
            disagree(doc, "tick-tails", got, tail)
        got = read.get(("close-tail", doc), "<no output>")
        want = "WRAPPED" if tail == "WRAPPED" else "notwrapped"
        if "close-wrapped-leg.sh" not in absent and got != want:
            disagree(doc, "close-wrapped-leg", got, want)
        if "board.mjs" in absent:
            pass
        elif board_pr is None:
            disagree(doc, "board-pr", "<no json>", pr)
        elif label not in board_pr and tail in ("WRAPPED", "MERGED"):
            # a finished leg moves to the board's archive, out of legs[]
            pass
        elif label not in board_pr:
            disagree(doc, "board-pr", "<leg absent>", pr)
        else:
            got = board_pr.get(label)
            if isinstance(got, dict):
                got = got.get("number")
            got = "-" if got in (None, "") else str(got)
            if got != pr:
                disagree(doc, "board-pr", got, pr)
print("COMPARED %d docs, %d disagreements" % (n, bad))
PY
)"
printf '%s\n' "$cmp_out" | grep -v '^COMPARED' | head -60
summary="$(printf '%s\n' "$cmp_out" | grep '^COMPARED')"
case "$summary" in
"COMPARED $rows docs, 0 disagreements") pass "every reader agrees with the reference parser on $rows generated docs ($((SECONDS - t0)) s)" ;;
*) fail "readers disagree with the reference parser: ${summary:-no comparison output}" ;;
esac

if [ "$fails" -gt 0 ]; then echo "FAILED: $fails"; exit 1; fi
echo "all ok"
