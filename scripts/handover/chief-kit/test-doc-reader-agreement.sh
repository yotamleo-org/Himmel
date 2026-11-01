#!/usr/bin/env bash
# test-doc-reader-agreement.sh - the chief-kit readers parse the same handover
# docs independently (tick.sh, board.mjs, fleet.mjs, close-wrapped-worker.sh, the
# shared worker-tail-status.sh), and test-chief-kit-e2e.sh feeds them only
# hand-written canonical bullets. This suite generates docs from a grammar
# (fixtures/doc-reader-agreement/gen.py, fixed seed): the real chief.sh
# template with generated `legs:` blocks, and worker docs of canonical bullets plus
# adversarial prose (a backticked worker token, a .md:line cite, a wrapped legs: line,
# a long FINDING tail, `WRAPPED:` with a colon, a mid-doc WRAPPED, a worker-describing
# WRAPPED in a chief doc). It runs every reader over every doc and compares what
# each reads with ONE reference parser (gen.py, written from the documented
# grammar; the generator checks it against each doc's built-in intent):
#   chief doc  worker set   tick.sh legset=unarmed (--workers "")  | board.mjs | fleet.mjs
#   chief doc  malformed tick.sh livestate=MALFORMED
#   worker doc      tail      tick.sh tails= | close-wrapped-worker.sh --check (rc 4 = not WRAPPED)
#   worker doc      PR        board.mjs
# A disagreement prints the doc, the reader and both values.
#
# DRA_READERS=<repo root> points the readers at another tree (a RED replay on a
# parent commit: git archive <parent> scripts | tar -x -C <dir>); the generator,
# reference parser and this suite always come from the checkout.
# Stem labels are deliberately reader-specific: tick's chief entry set keeps
# raw stems; board and fleet normalize ticket-prefixed stems to N<k>. Generated
# entries and canonical/legacy worker filenames pin both sides of this distinction.
# Deliberately not covered (different document contracts, with dedicated suites):
#   relay-batch.sh, succession-tracker.sh: succession delivery/acknowledgement,
#     malformed-input refusal and manifest joins, not just an entry/tail set.
#   live-state.sh, action-zero.sh, worker-event.sh: mutate live state / route events;
#     running them on the corpus would change the documents being compared.
#   append-results.sh, worker-doc-lock.sh: append/lock/frontmatter write contracts.
#   headed-arm-worker.sh: real relaunch reader (brief/frontmatter/run-history gates);
#     launching sessions is outside this offline parser corpus. No worker-relaunch.sh exists.
#   brief-lint.sh: validates prior-art brief fields, absent from this grammar.
#   compacted-check.sh: COMPACTED snapshot contract, not the final marker.
#   consult-relay.sh: ANSWER/WRAPPED consult protocol, not a worker status parser.
#   handoff-facts.sh: full handoff facts/priority/queue/decision sections.
#   next-dispatchable.sh, priority-prune.sh: priority fields and Jira scheduling.
#   tracker.py: ticket/manifest/lock joins and its own PR/empty-tail semantics.
#   version-status-audit.sh: ticket status joined with frontmatter resume paths.
#   parked-on-prompt.sh: session_ids joined with denial events, not status tails.
#   chief-wait.sh: predecessor header and lifecycle/PR routing, invokes tick.
#   wrap-merged.sh: merge/close/append workflow and tracker metadata fields.
#   worker-digest-step.sh: frontmatter/session/timing/PR ledger extraction.
#   pr-stall.sh: broad PR/ticket attribution, not canonical PR extraction.
#   inbox-send.sh: inserts Chief Rulings; never a fleet/tail verdict.
#   residual-lines.sh: residual-ticket sections, not entry/tail/PR grammar.
#   gen-briefs.py, gen-judge-brief.py, smoke-consult-sandbox.sh write fixtures/briefs;
#     stability-scorecard.sh reads no handover doc, so none is a missing reader.
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
CK="$READERS/scripts/handover/chief-kit"
export TICK_DOCTOR_TTL_MIN=0  # the real himmel-doctor.sh is never run from a suite
SEED="${DRA_SEED:-20261020}"
N_CHIEF=24
N_WORKER=176
JOBS="${DRA_JOBS:-8}"
# A parent-commit replay predates some readers; a reader the tree lacks is skipped
# there, never counted as a disagreement (that would fail on every doc, proving nothing).
ABSENT=""
for r in board.mjs fleet.mjs close-wrapped-worker.sh; do [ -f "$CK/$r" ] || ABSENT="$ABSENT $r"; done

# ---- one reader over one doc (re-entered through xargs -P) ------------------
# --one '<kind>TAB<doc>': prints `<kind>\t<doc basename>\t<value>` from that reader only
if [ "${1:-}" = --one ]; then
    kind="${2%%$'\t'*}"; doc="${2#*$'\t'}"; base="$(basename "$doc")"
    stub="${DRA_TICK_STUB:-}"
    case "$kind" in
    tick-chief)
        out="$(bash "$CK/tick.sh" --doc "$doc" --token tok --workers "" --repo "$READERS" 2>/dev/null | tr ' ' '\n')"
        ls_="$(printf '%s\n' "$out" | sed -n -E 's/^(workerset|legset)=//p' | head -1)"
        lv="$(printf '%s\n' "$out" | sed -n 's/^livestate=//p' | head -1)"
        # the entry set: workerset=unarmed (legset= in an older tick) where tick has that field, else the DRIFT labels
        # (a tick that predates the field names every entry without a live lock there)
        unarmed=""; mal=""; drift=""
        case "$ls_" in STALE:*) unarmed="${ls_#STALE:}"; unarmed="${unarmed#unarmed=}"; unarmed="${unarmed%%;*}" ;; esac
        case "$lv" in *MALFORMED:*) mal="${lv#*MALFORMED:}"; mal="${mal%%;*}" ;; esac
        case "$lv" in *DRIFT:*) drift="${lv#*DRIFT:}"; drift="${drift%%;*}" ;; esac
        printf 'tick-workers\t%s\t%s\n' "$base" "$(printf '%s+%s' "$unarmed" "$drift" | tr ',+' '\n' | grep . | sort -u | paste -sd, -)"
        printf 'tick-malformed\t%s\t%s\n' "$base" "$(printf '%s' "$mal" | tr ',+' '\n' | grep . | sort -u | paste -sd, -)"
        ;;
    board-chief)
        j="$(mktemp "${DRA_TMP:-/tmp}/b.XXXXXX")" || exit 1
        BOARD_TICK="$stub" node "$CK/board.mjs" --doc "$doc" --workers "" --out "$j.html" --json "$j.json" --repo "$READERS" >/dev/null 2>&1
        printf 'board-workers\t%s\t%s\n' "$base" "$(jq -r '[.legs[].leg] | unique | join(",")' "$j.json" 2>/dev/null || echo '?')"
        rm -f "$j" "$j.html" "$j.json"
        ;;
    fleet-chief)
        printf 'fleet-workers\t%s\t%s\n' "$base" "$(node "$CK/fleet.mjs" --doc "$doc" --json 2>/dev/null | jq -r '[.workers[].label] | unique | join(",")' 2>/dev/null || echo '?')"
        ;;
    tail-worker)
        # Exercise the shared parser directly as well as its tick/close consumers.
        . "$READERS/scripts/lib/worker-tail-status.sh"
        v="$(worker_tail_status "$doc")"
        printf 'shared-tail\t%s\t%s\n' "$base" "${v:-?}"
        ;;
    close-worker)
        bash "$CK/close-wrapped-worker.sh" --check "$doc" >/dev/null 2>&1
        rc=$?
        # rc 4 = tail is not WRAPPED; rc 0 = tail WRAPPED, then no live session matched
        # (CLOSED-ALREADY; the stubbed census has none); any other rc is a failure, never a tail verdict
        case "$rc" in 4) v=notwrapped ;; 0) v=WRAPPED ;; *) v="rc$rc" ;; esac
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
mkdir -p "$W/home" || exit 1
export HOME="$W/home" XDG_CACHE_HOME="$W/home/.cache" XDG_CONFIG_HOME="$W/home/.config" XDG_STATE_HOME="$W/home/.local/state"
export CLAUDE_CONFIG_DIR="$W/home/.claude"

fails=0
pass() { printf 'ok - %s\n' "$1"; }
fail() { printf 'FAIL - %s\n' "$1"; fails=$((fails + 1)); }

if ! python3 -I - "$W/home" <<'PY'
import os, sys
home = sys.argv[1]
assert os.environ['HOME'] == home
assert os.environ['CLAUDE_CONFIG_DIR'] == home + '/.claude'
for key, suffix in [('XDG_CACHE_HOME', '/.cache'), ('XDG_CONFIG_HOME', '/.config'), ('XDG_STATE_HOME', '/.local/state')]:
    assert os.environ[key] == home + suffix
PY
then
    fail "readers and chief template setup use a temporary HOME"
    echo "FAILED: $fails"
    exit 1
fi
pass "readers and chief template setup use a temporary HOME"

# ---- offline stubs and seams (as test-chief-kit-e2e.sh) -------------------
export HANDOVER_DIR="$W/root"
mkdir -p "$W/root" "$W/bin" "$W/launch" "$W/state" "$W/digest" "$W/tx" "$W/cache" "$W/work" "$W/out"
printf '#!/usr/bin/env bash\ncase "$*" in *"pr list"*) echo "[]" ;; *) exit 1 ;; esac\n' > "$W/bin/gh"
printf '#!/usr/bin/env bash\nexit 0\n' > "$W/bin/atq"
printf '#!/usr/bin/env bash\nexit 0\n' > "$W/bin/bun"
printf '#!/usr/bin/env bash\nexit 1\n' > "$W/bin/jira"
printf '#!/usr/bin/env bash\necho "TICK workers=none tails=none"\n' > "$W/bin/tickstub"
chmod +x "$W/bin"/*
export PATH="$W/bin:$PATH"
printf '%s\n' '{"five_hour":{"utilization":30},"seven_day":{"utilization":28}}' > "$W/bank.json"
export TICK_BANK_CACHE_FILE="$W/bank.json" CADENCE_USAGE_CACHE="$W/bank.json" CADENCE_USAGE_SKIP_REFRESH=1
export CADENCE_USAGE_LEDGER=/dev/null
export TICK_STATE_DIR="$W/state" TICK_LAUNCH_DIR="$W/launch" TICK_TMPDIR="$W"
export HIMMEL_FAILURE_ROUTES_LOG="$W/routes.jsonl" SUITE_FLAKE_LEDGER="$W/flake.jsonl" SUITE_FLAKE_REPO_ID=dra
export HIMMEL_WORKER_SESSION_FAILURES_LEDGER="$W/leg-failures.jsonl" HIMMEL_EVAL_RUNS_LEDGER="$W/eval-runs.jsonl"
export WORKER_SESSION_DIGEST_STATE_DIR="$W/digest" WORKER_SESSION_DIGEST_SETTLE_MAX=0 WORKER_SESSION_DIGEST_SETTLE_QUIET=0
export BOARD_TRANSCRIPTS="$W/tx" CR_LEDGER="$W/no-cr" BOARD_MIRROR="$W/no-mirror"
export CLOSE_WRAPPED_WORKER_PROJECTS_DIR="$W/projects" CLOSE_WRAPPED_WORKER_SESSIONS_DIR="$W/sessions"
export WORKER_SESSION_JIRA_STATUS=0
export DRA_TICK_STUB="$W/bin/tickstub" DRA_TMP="$W/out" DRA_READERS="$READERS"

# ---- the chief template: one REAL chief.sh new --------------------------
printf '#!/usr/bin/env bash\necho "bank-preflight: worker=unknown five_hour=9.0 seven_day=91.0 extra_usage=n/a"\necho PROCEED\n' > "$W/facts-bank.sh"
printf '#!/usr/bin/env bash\necho "#5 [DEMO-1] stub pr (feat/x)"\n' > "$W/facts-prs.sh"
mkdir -p "$W/tpl"
(
    export HIMMELCTL_CACHE_DIR="$W/cache" HANDOVER_REGISTRY="$W/noreg.json" BRIDGE_ROOT="$W/bridge" \
        HANDOFF_FACTS_BANK="$W/facts-bank.sh" HANDOFF_FACTS_PRS="$W/facts-prs.sh" HANDOVER_DIR="$W/tpl" \
        USER_SLUG=u JIRA_PROJECT_KEY=HIMMEL CHIEF_WORK_DIR="$W/work"
    bash "$REPO/scripts/handover/chief/chief.sh" new --name tpl-chief --bucket himmel >/dev/null 2>&1
)
tpl_rc=$?
if [ "$tpl_rc" -ne 0 ]; then fail "chief.sh new exited $tpl_rc"; echo "FAILED: $fails"; exit 1; fi
TPL="$(find "$W/tpl" -name 'HIMMEL-nextleg-*-chief.md' | head -1)"
if [ -z "$TPL" ]; then fail "chief.sh new produced a chief doc"; echo "FAILED: 1"; exit 1; fi
pass "chief.sh new produced the template chief doc"
if [ -n "$ABSENT" ] && [ -z "$REPLAY" ]; then fail "readers missing from the checkout:$ABSENT"; fi
[ -z "$ABSENT" ] || printf 'note - readers absent in %s, skipped:%s\n' "$READERS" "$ABSENT"

python3 -I "$GEN" gen "$W/gen" "$SEED" "$N_CHIEF" "$N_WORKER" "$TPL" || { fail "generator (reference parser disagrees with the doc intent)"; echo "FAILED: $fails"; exit 1; }
B="$W/gen/u/himmel"
EXPECT="$W/gen/expect.tsv"
rows="$(wc -l < "$EXPECT" | tr -d ' ')"
if [ "$rows" = $((N_CHIEF + N_WORKER)) ]; then pass "generated $rows docs (seed $SEED)"; else fail "generated $rows docs, want $((N_CHIEF + N_WORKER))"; fi

# ---- run every reader (parallel; a serial run blows the time budget) --------
CONS=(); WORKERS=()
while IFS=$'\t' read -r kind file _; do
    if [ "$kind" = console ]; then CONS+=("$B/$file"); else WORKERS+=("$B/$file"); fi
done < "$EXPECT"

t0=$SECONDS
{
    for d in "${CONS[@]}"; do printf '%s\t%s\n' tick-chief "$d"; printf '%s\t%s\n' board-chief "$d"; printf '%s\t%s\n' fleet-chief "$d"; done
    for d in "${WORKERS[@]}"; do printf '%s\t%s\n' close-worker "$d"; printf '%s\t%s\n' tail-worker "$d"; done
} | xargs -d '\n' -P "$JOBS" -I{} bash "$0" --one {} 2>/dev/null | sort > "$W/readers.tsv" &
bg=$!

# tick over ALL worker docs at once (its tails= field), with the first chief doc as --doc
tickout="$(bash "$CK/tick.sh" --doc "${CONS[0]}" --token tok --workers "${WORKERS[*]}" --repo "$READERS" 2>/dev/null | tr ' ' '\n')"
printf '%s\n' "$tickout" | sed -n 's/^tails=//p' | head -1 | tr ',' '\n' > "$W/tails.txt"

# board over ALL worker docs at once (PR extraction), stubbed tick
BOARD_TICK="$W/bin/tickstub" node "$CK/board.mjs" --doc "${CONS[0]}" --workers "${WORKERS[*]}" --out "$W/out/all.html" --json "$W/out/all.json" --repo "$READERS" >/dev/null 2>&1
wait "$bg"

# ---- compare with the reference parser --------------------------------------
cmp_out="$(python3 -I - "$EXPECT" "$W/readers.tsv" "$W/tails.txt" "$W/out/all.json" "$ABSENT" <<'PY'
import csv, html, json, re, sys
expect, readers, tails, board = sys.argv[1:5]
try:
    archive = open(board[:-5] + '-archive.html').read()
    archived = {html.unescape(label): html.unescape(re.sub(r'<[^>]+>', '', text))
                for label, text in re.findall(r'<li data-archive-worker="([^"]+)">(.*?)</li>', archive)}
except OSError:
    archived = {}
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
        _, doc, workers, mal = row
        n += 1
        for key in ("tick-workers", "board-workers", "fleet-workers"):
            if {"board-workers": "board.mjs", "fleet-workers": "fleet.mjs"}.get(key) in absent:
                continue
            got = read.get((key, doc), "<no output>")
            want = workers
            if key != "tick-workers":
                want = ",".join(sorted({re.sub(r'^[A-Za-z]+-\d+-(N\d+[a-z]*)(?:-.*)?$', r'\1', lab)
                                        for lab in workers.split(',') if lab}))
            if got != want:
                disagree(doc, key, got, want)
        got = read.get(("tick-malformed", doc), "<no output>")
        if got != mal:
            disagree(doc, "tick-malformed", got, mal)
    else:
        _, doc, label, tail, pr = row
        n += 1
        got = tick_tail.get(label, "<absent>")
        if got != tail:
            disagree(doc, "tick-tails", got, tail)
        got = read.get(("shared-tail", doc), "<no output>")
        if got != tail:
            disagree(doc, "worker-tail-status", got, tail)
        got = read.get(("close-tail", doc), "<no output>")
        want = "WRAPPED" if tail == "WRAPPED" else "notwrapped"
        if "close-wrapped-worker.sh" not in absent and got != want:
            disagree(doc, "close-wrapped-worker", got, want)
        if "board.mjs" in absent:
            pass
        elif board_pr is None:
            disagree(doc, "board-pr", "<no json>", pr)
        elif label not in board_pr and tail in ("WRAPPED", "MERGED"):
            # A finished worker must be present in the archive, with its PR intact.
            if label not in archived:
                disagree(doc, "board-archive", "<worker absent>", label)
            else:
                match = re.search(r'\bPR #(\d+)\b', archived[label])
                got = match.group(1) if match else "-"
                if got != pr:
                    disagree(doc, "board-archive-pr", got, pr)
        elif label not in board_pr:
            disagree(doc, "board-pr", "<worker absent>", pr)
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

# ---- M1a: `workers:` / `.workers` first, the pre-rename `legs:` / `.legs` still read ----
# An old chief doc (a `legs:` line) and an old fleet manifest (a `legs` array) must read exactly as
# their `workers` twin does, and with HIMMEL_LEGACY_NAMES=0 the old spelling is ignored or refused.
# The generated `legs:` docs above are the frozen fixture; the twins are derived from them here.
M1A="$W/m1a"; mkdir -p "$M1A/bin" "$M1A/mirror"
m1a_read() { env HIMMEL_LEGACY_NAMES="$3" bash "$0" --one "$1"$'\t'"$2" 2>/dev/null | cut -f3 | tr '\n' '|'; }
m1a_docs="$(awk -F'\t' '$1 == "console" && $3 != "" { print $2 }' "$EXPECT" | head -4)"
m1a_n=0
for f in $m1a_docs; do
    m1a_n=$((m1a_n + 1))
    cp "$B/$f" "$M1A/l$m1a_n.md"
    sed 's/^legs:/workers:/' "$B/$f" > "$M1A/w$m1a_n.md"
done
if [ "$m1a_n" -ge 1 ]; then pass "m1a: $m1a_n generated chief docs with workers have an old and a workers twin"; else fail "m1a: no generated chief doc carries workers"; fi
for kind in tick-chief board-chief fleet-chief; do
    same=1; nonempty=0; offdiff=1; twinoff=1
    i=1
    while [ "$i" -le "$m1a_n" ]; do
        old="$(m1a_read "$kind" "$M1A/l$i.md" 1)"
        new="$(m1a_read "$kind" "$M1A/w$i.md" 1)"
        off="$(m1a_read "$kind" "$M1A/l$i.md" 0)"
        twin="$(m1a_read "$kind" "$M1A/w$i.md" 0)"
        [ "$old" = "$new" ] || same=0
        [ -n "$(printf '%s' "$new" | tr -d '|')" ] && nonempty=1
        [ "$off" != "$new" ] || offdiff=0
        [ "$twin" = "$new" ] || twinoff=0
        i=$((i + 1))
    done
    # shellcheck disable=SC2015
    [ "$nonempty" -eq 1 ] && [ "$same" -eq 1 ] && pass "m1a: $kind reads an old legs: doc as its workers: twin" || fail "m1a: $kind legs: doc and workers: twin disagree (same=$same nonempty=$nonempty)"
    # shellcheck disable=SC2015
    [ "$offdiff" -eq 1 ] && pass "m1a: $kind ignores the legs: line with HIMMEL_LEGACY_NAMES=0" || fail "m1a: $kind still reads legs: with HIMMEL_LEGACY_NAMES=0"
    # shellcheck disable=SC2015
    [ "$twinoff" -eq 1 ] && pass "m1a: $kind reads the workers: twin with HIMMEL_LEGACY_NAMES=0" || fail "m1a: $kind stops reading workers: with HIMMEL_LEGACY_NAMES=0"
done

# the manifest readers: handoff-facts.sh, close-wrapped-worker.sh, pr-stall.sh, version-status-audit.sh
m1a_w1="$M1A/HIMMEL-901-N901-a-2026-10-31.md"; m1a_w2="$M1A/HIMMEL-902-N902-b-2026-10-31.md"
printf '# w1\n\n## Results\n- 10:00 LIVE — branch feat/m1a-a\n' > "$m1a_w1"
printf '# w2\n\n## Results\n- 10:00 LIVE — x\n- 10:05 WRAPPED — done\n' > "$m1a_w2"
for form in legs workers; do
    printf '# chief\n\n## Live state\n\nworkers: none\n\n## Results\n' > "$M1A/chief-$form.md"
    printf '{"schema":1,"%s":[{"doc":"%s","label":"N901","added":"2026-10-31T00:00:00Z","lane":"native"},{"doc":"%s","label":"N902","added":"2026-10-31T00:00:00Z","lane":"native"}]}\n' "$form" "$m1a_w1" "$m1a_w2" > "$M1A/chief-$form.fleet.json"
done
printf '[{"number":7,"headRefName":"feat/m1a-a","headRefOid":"abc","mergeable":"CONFLICTING","mergeStateStatus":"DIRTY","statusCheckRollup":[],"updatedAt":"2026-10-31T00:00:00Z","createdAt":"2026-10-31T00:00:00Z"}]\n' > "$M1A/prs.json"
printf '#!/usr/bin/env bash\ncase "$*" in *"pr list"*) cat "%s/prs.json" ;; *"run list"*) echo "[]" ;; *) exit 1 ;; esac\n' "$M1A" > "$M1A/bin/gh"
printf '#!/usr/bin/env bash\nexit 0\n' > "$M1A/bin/gh-empty"
chmod +x "$M1A/bin/gh" "$M1A/bin/gh-empty"
printf -- '---\nkey: HIMMEL-901\ntype: Task\nstatus: In Progress\nstatusCategory: In Progress\nfixVersions: ["v9.0.2"]\nlabels: []\n---\n' > "$M1A/mirror/HIMMEL-901.md"
printf 'v9.0.1\tfalse\t-\tfalse\nv9.0.2\tfalse\t-\tfalse\n' > "$M1A/mirror.versions.tsv"

m1a_hf()   { env HIMMEL_LEGACY_NAMES="$2" bash "$CK/handoff-facts.sh" workers "$M1A/chief-$1.md" --repo "$READERS" 2>&1; }
m1a_cw()   { env HIMMEL_LEGACY_NAMES="$2" bash "$CK/close-wrapped-worker.sh" --check --sweep --fleet "$M1A/chief-$1.fleet.json" 2>&1; }
m1a_ps()   { env PATH="$M1A/bin:$PATH" HIMMEL_LEGACY_NAMES="$2" PR_STALL_NOW=2026-10-31T12:00:00Z bash "$CK/pr-stall.sh" --repo x/y --manifest "$M1A/chief-$1.fleet.json" 2>&1; }
m1a_vsa()  { env VSA_GH_CMD="$M1A/bin/gh-empty" HIMMEL_LEGACY_NAMES="$2" bash "$CK/version-status-audit.sh" --mirror "$M1A/mirror" --workers-from "$M1A/chief-$1.fleet.json" 2>&1; }
m1a_row() { # <name> <function> <legs-output-grep> <switch-off legs grep>: old = new, the workers form survives the switch, the old form is refused
    local name="$1" fn="$2" want="$3" refused="$4" old new off twin
    old="$("$fn" legs 1)"; new="$("$fn" workers 1)"; off="$("$fn" legs 0)"; twin="$("$fn" workers 0)"
    if [ "$old" = "$new" ] && grep -Eq -- "$want" <<< "$new"; then pass "m1a: $name reads an old legs manifest as its workers twin"; else fail "m1a: $name old=[$old] new=[$new] want /$want/"; fi
    if [ "$twin" = "$new" ]; then pass "m1a: $name reads the workers manifest with HIMMEL_LEGACY_NAMES=0"; else fail "m1a: $name workers manifest changes with the switch off: [$twin] vs [$new]"; fi
    if grep -Eq -- "$refused" <<< "$off" && [ "$off" != "$new" ]; then pass "m1a: $name refuses the old legs manifest with HIMMEL_LEGACY_NAMES=0"; else fail "m1a: $name still reads legs with the switch off: [$off] want /$refused/"; fi
}
m1a_row handoff-facts m1a_hf '^- N901: LIVE' 'unavailable'
m1a_row close-wrapped-worker m1a_cw '^sweep: closed=1 refused=0 skipped=1$' '^sweep: closed=0 refused=0 skipped=0$'
m1a_row pr-stall m1a_ps '^STALL 7 conflict N901 ' '^STALL 7 conflict - '
m1a_row version-status-audit m1a_vsa 'HIMMEL-901.*OWNED' 'UNKNOWN'

if [ "$fails" -gt 0 ]; then echo "FAILED: $fails"; exit 1; fi
echo "all ok"
