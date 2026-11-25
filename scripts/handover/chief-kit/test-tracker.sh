#!/usr/bin/env bash
# test-tracker.sh — Hermetic tests for tracker.py's outside-the-plan
# sections and the ledger's unplanned count: no "Closed by roadmap" section, park-ns
# closures render in "Parked / unplaced", and only OPEN unplanned tickets are counted.
# row fields, legend, ledger wording, plan-sourced caps, Done off-plan
# work counting in its version, and distinct load / layer palettes.
# the redesign — rows lead with user impact, numbers drill down, a
# remaining-only switch, live workers; tracker-model-check.js runs the page's model.
# Synthetic plan dir + mirror under a mktemp dir; no real plan data, no network.
#
# PLATFORM GUARD: The chief kit is Linux-only
# (see test-tick.sh); this suite renders one static page with python3.
set -uo pipefail
KP=HIMMEL

HERE="$(cd "$(dirname "$0")" && pwd)"
W="$(mktemp -d "${TMPDIR:-/tmp}/tracker-test.XXXXXX")" || exit 1
trap 'rm -rf "$W"' EXIT
export TICK_STATE_DIR="$W/tick-state"
fails=0
# the parity check's Jira CLI: every render here reads a CLI that fails, unless a row names another.
printf '#!/bin/sh\nexit 1\n' > "$W/nojira"
chmod +x "$W/nojira"
export TRACKER_JIRA="$W/nojira"

touch_ago() { local s="$1"; shift; touch "$@" && python3 -c 'import os,sys,time; t=time.time()-int(sys.argv[1]); [os.utime(f,(t,t)) for f in sys.argv[2:]]' "$s" "$@"; }
pass() { printf 'ok - %s\n' "$1"; }
fail() { printf 'FAIL - %s\n' "$1"; fails=$((fails + 1)); }
contains() {
    case "$2" in *"$3"*) pass "$1" ;; *) fail "$1 (missing '$3')" ;; esac
}
not_contains() {
    case "$2" in *"$3"*) fail "$1 (found '$3')" ;; *) pass "$1" ;; esac
}
equals() {
    if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (got '$2', want '$3')"; fi
}

if ! command -v python3 >/dev/null 2>&1; then
    printf 'skip - python3 not available\n'
    exit 0
fi
ROUTE="$HERE/../../telegram/chief-route.ts"
command -v bun >/dev/null 2>&1 || { printf 'FAIL - bun is needed to seed the round ledger\n'; exit 1; }
seed() { bun "$ROUTE" round-seed --all "$1/specs" >/dev/null 2>&1 || fail "round-seed failed in $1"; }

plan="$W/plan"
mir="$W/mirror"
mkdir -p "$plan/stage1" "$plan/stage2" "$plan/stage3" "$plan/tools/stage3" "$mir"
# write_meta <ticket cap> <total cap> [extra json members] — synthetic placement-rule notes in the plan's shapes.
write_meta() {
    printf '{"main_sha_at_build":"abcdef123456","notes":["effort S-eq: XS .44 S 1 M 2.2 L 5 XL 11.1; synthetic","load (bank) = committed: effort_mid x 0.009; plan-first: slice S-eq x 0.009","v2/v3 is deferred","first fit: earliest version whose ticket count < %s, layer load within cap and total load within %s"]%s}\n' \
        "$1" "$2" "${3:-}" > "$plan/stage3/meta.json"
}
write_caps() {  # write_caps <bugs cap>
    printf '%s\n' '# synthetic placer' "CAPS = {'features': 0.10, 'bugs': $1, 'enhancements': 0.12, 'audit': 0.03, 'misc': 0.05}" \
        > "$plan/tools/stage3/place.py"
}
write_meta 20 0.6
write_caps 0.30
printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' version load_bugs load_enhancements load_features load_misc load_audit load_total est_legs \
    v1.0.1 0.1 0 0 0 0 0.1 1 v2/v3 0 0 0 0 0 0 0 > "$plan/stage3/versions.tsv"
printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' key version layer effort_mid commit slice_effort reason \
    HIMMEL-1 v1.0.1 bugs 1 committed '' 'P1; pinned to v1.0.1 (ruling)' > "$plan/stage3/placement.tsv"
printf '%s\t%s\t%s\n' key user_impact issue_plain HIMMEL-1 'operators lose the synthetic widget on restart' 'plain text' \
    > "$plan/stage1/C01.explain.tsv"
printf '%s\t%s\t%s\t%s\n' key readiness effort_low effort_high HIMMEL-1 3 M L > "$plan/stage2/C01.tsv"
printf '%s\t%s\t%s\n' key close_flag close_evidence \
    HIMMEL-2 park-ns 'parked evidence text' \
    HIMMEL-3 likely-fixed 'fixed evidence text' > "$plan/stage3/closures.tsv"
printf '%s\t%s\n' key reason HIMMEL-4 'unplaced reason text' > "$plan/stage3/unplaced.tsv"
printf '%s\t%s\t%s\n' key theme impact HIMMEL-1 tooling 4 > "$plan/stage1/C01.tsv"

# mk <n> <statusCategory> <fixVersions json> <title> [status name] [resolution]; writes into $mdir. A status name is the Jira status
# without one the frontmatter has no `status:` line and the page falls back to the category.
mdir="$mir"
mk() {
    {
        printf '%s\n' '---' "key: \"HIMMEL-$1\"" 'updated: "2026-09-30T10:00:00.000+0000"' "statusCategory: \"$2\""
        [ -n "${5:-}" ] && printf 'status: "%s"\n' "$5"
        [ -n "${7:-}" ] && printf 'sector: "%s"\n' "$7"
        [ -n "${6:-}" ] && printf 'resolution: "%s"\n' "$6"
        printf '%s\n' "fixVersions: $3" 'type: "Bug"' '---' "# HIMMEL-$1: $4"
    } > "$mdir/HIMMEL-$1.md"
}
mk 1 'To Do' '["v1.0.1"]' 'planned bug' '' '' Tooling
mk 2 'To Do' '[]' 'parked ticket'
mk 3 'To Do' '[]' 'likely fixed ticket'
mk 4 'To Do' '[]' 'unplaced ticket'
mk 5 'Done' '["v1.0.1"]' 'done unplanned'
mk 6 'To Do' '["v1.0.1"]' 'open unplanned' '' '' Visibility
mk 7 'In Progress' '["v1.0.1"]' 'active unplanned'
# Ticket 6 carries the plain block as the mirror renders ADF headings (bare lines); ticket 1 keeps only its explain sidecar.
printf '%s\n' '' '## Description' '' 'Impact' 'Operators see a blank page after the nightly restart.' 'It happens once a day.' \
    'What' 'We reload the page data on start.' 'Why' 'Blank pages read as an outage.' 'Agent detail' 'files: x.py' \
    '' '## Comments' '' '_(none)_' >> "$mir/HIMMEL-6.md"
# A markdown body with decorated headings (`## **Impact**`) is read too: the create lint accepts them.
printf '%s\n' '' '## Description' '' '## **Impact**' 'Decorated heading impact line.' '## Background' 'Background text must not leak.' \
    '## **What**' 'x' '' '## Comments' '' '_(none)_' >> "$mir/HIMMEL-7.md"
# `##Impact` (no space) is ordinary text in Markdown, not a heading.
printf '%s\n' '' '## Description' '' '##Impact' 'Nospace impact must not show.' '' '## Comments' '' '_(none)_' >> "$mir/HIMMEL-4.md"
printf '%s\n' '' '## Description' '' '```' '## Impact' 'Fenced fake impact.' '```' \
    '' '## Comments' '' '_(none)_' >> "$mir/HIMMEL-1.md"

out="$W/out.html"
render() {
    python3 "$HERE/tracker.py" --plan-dir "$plan" --out "$out" --luna-map "$W/luna-map.json" \
        --mirror-dir "$mir" --luna-root "$W/luna" --handovers "$W/luna/handovers/tester/himmel" "$@" 2>&1
}
stdout="$(render)"
render_rc=$?
html="$(cat "$out" 2>/dev/null)"
if [ "$render_rc" -eq 0 ]; then pass 'tracker.py exits 0'; else fail "tracker.py exited $render_rc"; fi

# every file tracker.py writes ends in exactly one newline (luna's end-of-file-fixer rewrites it otherwise).
for f in "$W/luna-map.json" "$out" "$out.fp"; do
    if [ -s "$f" ] && [ "$(tail -c 1 "$f" | od -An -tx1 | tr -d ' ')" = '0a' ] \
        && [ "$(tail -c 2 "$f" | od -An -tx1 | tr -d ' ')" != '0a0a' ]; then
        pass "$(basename "$f") ends in exactly one newline"
    else
        fail "$(basename "$f") does not end in exactly one newline"
    fi
done
not_contains 'no Closed-by-roadmap section' "$html" 'Closed by roadmap'
contains 'the park-ns key renders in the page data' "$html" '"parked ticket"'
contains 'the park-ns evidence is the parked reason' "$html" 'parked evidence text'
contains 'the unplaced row still renders' "$html" 'unplaced reason text'
contains 'a ticket the plan pins to its version is listed as pinned' "$html" '"PIN":[1]'
not_contains 'a non-park closure is not rendered' "$html" 'fixed evidence text'
contains 'summary counts 2 unplaced (1 unplaced + 1 parked)' "$stdout" '2 unplaced'
contains 'summary counts only open unplanned tickets' "$stdout" ', 2 unplanned,'
contains 'the Done unplanned ticket still renders in its version tab data' "$html" '"done unplanned"'
# unplanned is a flag (row field 7 = 2), never a theme; a ticket with no theme is counted and flagged.
not_contains 'no "(unplanned)" theme in the page data' "$html" '(unplanned)'
contains 'summary counts the open tickets that have no sector' "$stdout" ', 1 unthemed,'
contains 'the ledger flags open tickets with no sector' "$stdout" '1 open ticket has no sector'

# --- design pass.
# Ask 1: a row carries user impact, the effort range, readiness, impact, issue_plain and its load (P columns).
contains 'a row carries user impact, effort range, readiness, impact, plain issue, load' "$html" \
    '"operators lose the synthetic widget on restart","M–L",3,4,"","plain text",0.009]'
contains 'a ticket with a plain Impact block shows it as the impact line' "$html" \
    '"Operators see a blank page after the nightly restart. It happens once a day."'
contains 'a decorated Impact heading is read as the impact line' "$html" \
    '"Decorated heading impact line."'
not_contains 'the impact line stops at the next heading' "$html" 'We reload the page data on start.'
not_contains 'the impact line stops at any other heading' "$html" 'Background text must not leak.'
not_contains 'a fenced Impact heading is not read' "$html" 'Fenced fake impact.'
not_contains 'a hash run with no space is not an Impact heading' "$html" 'Nospace impact must not show.'
contains 'the row leads with the user impact' "$html" 'add(tx,impactText(p,el("span","ui")),sub)'
contains 'readiness reads in words' "$html" '"fix named, not yet checked"'
contains 'a stage-2 readiness is labelled declared with its source' "$html" 'Declared readiness (source stage2, not verified by an audit): '
contains 'a ticket with no stage-2 plan row reads readiness unknown, never 0' "$html" 'Declared readiness: unknown (no stage-2 plan row for this ticket).'
not_contains 'the ready line no longer states the score as an unqualified fact' "$html" '"Ready to build: "+M.READY'
contains 'the terms call the ready score declared, not audited' "$html" 'A declared score from the roadmap plan, not verified evidence.'
contains 'impact is a secondary 5-dot tag' "$html" '"impact "+n+" of 5"'
contains 'the notes list is labelled vault notes' "$html" 'Vault notes that mention it:'
# Ask 2: the terms name every scale.
for s in 'Status' 'Worker chip' 'Size' 'Impact' 'Ready to build' 'Budget' 'No cap' 'Hide done work'; do
    contains "the terms name $s" "$html" "[\"$s\","
done
contains 'the size scale comes from the plan' "$html" 'XS 0.44 · S 1 · M 2.2 · L 5 · XL 11.1'
contains 'the ledger names the running version with its progress; Done unplanned counts' "$stdout" \
    'Plan rows placed in v1.0.1 (not Jira progress): 1 of 4 done (25 %), 1 in progress, 2 to do.'
contains 'the ledger gives whole-train progress' "$stdout" \
    'Plan rows placed in the whole v1.0.x train (not Jira progress): 1 of 4 done (25 %), 1 in progress, 2 to do.'
contains 'the ledger names open unplanned work when non-zero' "$stdout" \
    'Needs attention: 2 open tickets sit in a version but not in the plan; 1 open ticket has no sector.'
not_contains 'the ledger omits drift when it is zero' "$stdout" 'drifted'
not_contains 'the page data carries no plan ledger: it is not Jira progress' "$html" '"LG":'
# Ask 5: a Done off-plan ticket still counts in its version; off-plan work adds no budget.
contains 'off-plan tickets add no budget' "$html" 'function ld(p){return p[7]==2?0:(p[15]||0)}'
contains 'off-plan tickets are named in words' "$html" '"Not in the plan: Jira puts it in "'
# Ask 4: the capacity text comes from the plan, never a constant.
contains 'cap text: ticket cap from the plan' "$html" 'at most 20 tickets'
contains 'cap text: total cap from the plan' "$html" 'at most 0.6 bank of load'
contains 'cap text: layer caps from the plan' "$html" 'bugs 0.30'
contains 'cap text: load derivation from the plan' "$html" '× 0.009 bank'
not_contains 'the JS no longer hardcodes the cap' "$html" 'CAP=0.6'
write_meta 15 0.45
write_caps 0.25
render >/dev/null
html2="$(cat "$out" 2>/dev/null)"
contains 'a changed ticket cap changes the text' "$html2" 'at most 15 tickets'
contains 'a changed total cap changes the text' "$html2" 'at most 0.45 bank of load'
contains 'a changed layer cap changes the text' "$html2" 'bugs 0.25'
rm -f "$plan/tools/stage3/place.py"
printf '%s\n' '{"main_sha_at_build":"abcdef123456"}' > "$plan/stage3/meta.json"
render >/dev/null
html3="$(cat "$out" 2>/dev/null)"
contains 'a cap the plan does not record says so' "$html3" 'not recorded in the plan'
write_meta 20 0.6
write_caps 0.30
# the page contract — tokens for both themes, phone layout, keyboard-reachable drill-downs.
not_contains 'a light system preference no longer flips the tracker page' "$html" 'prefers-color-scheme:light'
contains 'light tokens follow the toggle' "$html" ':root[data-theme="light"]{'
contains 'the phone layout has its own rules' "$html" '@media (max-width:560px)'
contains 'every number is a button' "$html" 'var b=el("button","n",label);b.type="button";'
contains 'the drill-down is a modal dialog' "$html" 'role="dialog" aria-modal="true"'
contains 'Escape closes the drill-down' "$html" 'if(e.key=="Escape"){e.preventDefault();closeDrill();return}'
contains 'closing returns focus to the number' "$html" 'opener.focus()'
contains 'the pulse respects reduced motion' "$html" '@media (prefers-reduced-motion:no-preference)'
contains 'caps are tested by null, never truthiness: a cap of 0 is a cap' "$html" 'cap==null?null:r4(cap-u)'
not_contains 'the page has no column chart' "$html" 'renderChart'
contains 'the status legend names the five Jira statuses' "$html" '["todo","To Do"],["prog","In Progress"],["rev","In Review"],["ci","IN CI"],["done","Done"]'
not_contains 'the steer panel waits for the UI phase' "$html" 'renderSteer'
contains 'the estimate-vs-actual fold shows each size against what finished work took' "$html" 'fmtMin(x.med)+" · "+pl(x.workers,"worker","workers")'
not_contains 'no Plan decisions section' "$html" 'Plan decisions that need your input'
not_contains 'no What users gained section' "$html" 'What users gained'
not_contains 'no Plan vs Jira section' "$html" 'Plan vs Jira'
contains 'the themes fold is Sectors' "$html" 'Sectors in the running version'
contains 'a sector in the mirror frontmatter groups the ticket' "$html" '"Visibility"'
contains 'a ticket with no sector groups under (no sector)' "$html" '"(no sector)"'
contains 'a nested drill keeps the first opener' "$html" '"drawer").hidden)opener=from;'
# The new plan inputs move the freshness fingerprint; each render must itself succeed.
# fp_ok <label> <var> [render args] -- render --emit-fp into <var>, failing the test when the render exits non-zero.
fp_ok() {
    local o rc
    o="$(render --emit-fp "${@:3}")"
    rc=$?
    if [ "$rc" -eq 0 ]; then pass "$1: --emit-fp exits 0"; else fail "$1: --emit-fp exited $rc"; fi
    printf -v "$2" '%s' "$o"
}
fp1='' fp2='' fp3='' fp4='' fp5='' fp6='' fp7=''  # each set by fp_ok through printf -v
fp_ok 'base' fp1
printf '%s\t%s\t%s\t%s\n' key readiness effort_low effort_high HIMMEL-1 4 M L > "$plan/stage2/C01.tsv"
fp_ok 'stage2 edit' fp2
if [ -n "$fp1" ] && [ "$fp1" != "$fp2" ]; then pass 'a stage2 change moves the fingerprint'; else fail "a stage2 change left the fingerprint at '$fp1'"; fi
printf '%s\t%s\t%s\n' key user_impact issue_plain HIMMEL-1 'changed impact' 'plain' > "$plan/stage1/C01.explain.tsv"
fp_ok 'explain edit' fp3
if [ "$fp2" != "$fp3" ]; then pass 'an explain change moves the fingerprint'; else fail "an explain change left the fingerprint at '$fp2'"; fi

# --- neutral swatch for no-cap load, per-version caps from the plan's overrides.
contains 'no-cap load has its own neutral token' "$html" '--ldn:'
contains 'the legend names the no-cap swatch' "$html" '"no cap — deferred bucket"'
printf '%s\n' "VERSION_CAP_OVERRIDES = {'v1.0.1': {'tickets': 30, 'bugs': 0.45}}" > "$plan/tools/stage3/common.py"
render >/dev/null
html4="$(cat "$out" 2>/dev/null)"
contains 'a version cap override sets that version ticket cap' "$html4" '"VC":[{"t":30,'
contains 'a version cap override sets that version layer cap' "$html4" '"l":[0.45,'
contains 'the cap text names the override' "$html4" 'v1.0.1 holds at most 30 tickets'
contains 'the deferred bucket has no caps' "$html4" '},null]'
fp_ok 'override edit' fp4
if [ "$fp3" != "$fp4" ]; then pass 'a cap override change moves the fingerprint'; else fail 'a cap override change left the fingerprint'; fi
# Multi-line dict literals parse too, as the old [^}]* pattern allowed for CAPS.
printf '%s\n' '# synthetic placer' 'CAPS = {' "    'features': 0.10, 'bugs': 0.33," "    'enhancements': 0.12, 'audit': 0.03, 'misc': 0.05," '}' \
    > "$plan/tools/stage3/place.py"
printf '%s\n' 'VERSION_CAP_OVERRIDES = {' "    'v1.0.1': {'tickets': 31}," '}' > "$plan/tools/stage3/common.py"
render >/dev/null
html5="$(cat "$out" 2>/dev/null)"
contains 'a multi-line CAPS literal still sets the layer caps' "$html5" '"l":[0.33,'
contains 'a multi-line override literal still sets the ticket cap' "$html5" '"VC":[{"t":31,'
write_caps 0.30
printf '%s\n' "VERSION_CAP_OVERRIDES = {'v1.0.1': {'tickets': 30, 'bugs': 0.45}}" > "$plan/tools/stage3/common.py"

# --- ask 5: a live worker marks its ticket in progress, with its label and phase.
hb="$W/luna/handovers"
bk="$hb/tester/himmel"
mkdir -p "$bk" "$hb/.locks/queue/live.lock" "$hb/.locks/queue/gone.lock" "$hb/.locks/queue/brief.lock"
now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
printf '%s\n' '# worker' '- brief: follows PR 1999' '## Results' '- 10:00 LIVE — started' '- 10:20 LIVE — PR 1525 open, watching CI' '- a later note naming PR 1998' >"$bk/HIMMEL-1-N55-synthetic-worker-2026-10-01.md"
printf '%s\n' '# worker' '## Results' '- 09:00 READY 1600 abc GREEN' '- 09:30 WRAPPED — merged' > "$bk/HIMMEL-6-N56-wrapped-worker-2026-10-01.md"
printf '%s\n' '# worker' '## Results' '- 08:00 LIVE — started' > "$bk/HIMMEL-7-N57-released-worker-2026-10-01.md"
printf '%s\n' '# worker' '## Results' '- 08:00 LIVE — started' '- 12:00 LIVE — back after a night' '- 12:10 WRAPPED — merged' > "$bk/HIMMEL-6-N60-second-worker-2026-10-01.md"
printf '%s\n' '# worker' '- 08:00 brief note, not a Results bullet' '## Results' '- 09:00 LIVE — started' '- 09:10 WRAPPED — merged' > "$bk/HIMMEL-8-N61-brief-stamp-worker-2026-10-01.md"
printf '%s\n' '# worker' '- READY 1997 abc GREEN is the shape to send' '## Results' '- a note, no marker' > "$bk/HIMMEL-9-N59-brief-worker-2026-10-01.md"
printf '{"session":"s3","handover":"%s","heartbeat":"%s"}\n' "$bk/HIMMEL-9-N59-brief-worker-2026-10-01.md" "$now" > "$hb/.locks/queue/brief.lock/owner.json"
printf '{"session":"s1","handover":"%s","heartbeat":"%s"}\n' "$bk/HIMMEL-1-N55-synthetic-worker-2026-10-01.md" "$now" > "$hb/.locks/queue/live.lock/owner.json"
printf '{"session":"s2","handover":"%s","heartbeat":"%s"}\n' "$bk/HIMMEL-6-N56-wrapped-worker-2026-10-01.md" "$now" > "$hb/.locks/queue/gone.lock/owner.json"
fp_ok 'workers added' fp5
stdout6="$(render)"
html6="$(cat "$out" 2>/dev/null)"
cp "$out" "$W/workers.html"
contains 'a held-lock worker doc marks its ticket live with label, phase and PR' "$html6" '"WORKER":{"1":["N55","LIVE",1525]'
contains 'a Jira row carries its live worker under the worker key the page reads' "$html6" '"worker":["N55","LIVE",1525]'
not_contains 'a WRAPPED worker is not live even while its lock lingers' "$html6" '"6":["N56"'
not_contains 'a worker doc with no held lock is not live' "$html6" '"7":["N57"'
contains 'a marker-shaped brief bullet above Results sets neither phase nor PR' "$html6" '"9":["N59","LIVE",null]'
printf '%s\n' '# worker' '## Results' '- 08:00 LIVE — started' '- 08:30 PARKED-USAGE — committed, waiting for RESUME' > "$W/parked-usage-worker.md"
contains 'a PARKED-USAGE tail is the worker phase, not the earlier LIVE' "$(python3 -c 'import sys; sys.path.insert(0, sys.argv[1]); import tracker; print(tracker.leg_marker(sys.argv[2])[0])' "$HERE" "$W/parked-usage-worker.md")" 'PARKED-USAGE'
contains 'a wrapped worker counts toward what its ticket took: [workers, wall, active, dated]; a gap over 3 h is idle, not active' "$html6" '"ACT":{"6":[2,280,40,2]'
contains 'a timestamped line above ## Results is not counted as work' "$html6" '"8":[1,10,10,1]'
contains 'the actuals carry the newest wrapped-worker doc stamp' "$html6" '"ATS":"20'
contains 'the live worker counts its ticket in progress in the ledger' "$stdout6" '1 of 4 done (25 %), 2 in progress, 1 to do.'
if [ "$fp4" != "$fp5" ]; then pass 'a worker starting moves the fingerprint'; else fail 'a worker starting left the fingerprint'; fi
printf '%s\n' '- 10:40 READY 1525 abc GREEN' >> "$bk/HIMMEL-1-N55-synthetic-worker-2026-10-01.md"
fp_ok 'worker phase moved' fp6
if [ "$fp5" != "$fp6" ]; then pass 'a worker phase change moves the fingerprint'; else fail 'a worker phase change left the fingerprint'; fi
fp_ok 'worker phase unchanged' fp7
if [ "$fp6" = "$fp7" ]; then pass 'the fingerprint is stable when nothing moved'; else fail 'the fingerprint moved with no input change'; fi
# one --emit-fp run reads each worker doc's marker once (live_legs and actuals both ask for it)
leg_reads="$(python3 -I -c '
import collections, contextlib, io, sys
sys.path.insert(0, sys.argv[1])
import tracker
reads = collections.Counter()
real_open = open
def counting_open(p, *a, **k):
    if sys._getframe(1).f_code.co_name in ("leg_marker", "_leg_marker"):
        reads[p] += 1
    return real_open(p, *a, **k)
tracker.open = counting_open
sys.argv = ["tracker.py"] + sys.argv[2:]
with contextlib.redirect_stdout(io.StringIO()):
    tracker.main()
print(max(reads.values()) if reads else 0)
' "$HERE" --plan-dir "$plan" --out "$out" --luna-map "$W/luna-map.json" --mirror-dir "$mir" --luna-root "$W/luna" --handovers "$W/luna/handovers/tester/himmel" --emit-fp)"
equals 'one --emit-fp run reads each worker doc marker once' "$leg_reads" 1
rm -rf "$hb/.locks/queue/live.lock"
render >/dev/null
not_contains 'a released lock clears the live worker' "$(cat "$out")" '"1":["N55"'

# --- expansion: trail versions (<version>b, c, ...) and the effort model's P90 (cautious load).
# versions.tsv lists them out of order on purpose; the plan's order is v1.0.1 < v1.0.1b < v1.0.2 < v1.0.10.
printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' version load_bugs load_enhancements load_features load_misc load_audit load_total est_legs \
    v1.0.2 0 0 0 0 0 0 0 v1.0.1b 0.01 0 0 0 0 0.01 1 v1.0.10 0 0 0 0 0 0 0 v1.0.1 0.1 0 0 0 0 0.1 1 v2/v3 0 0 0 0 0 0 0 \
    > "$plan/stage3/versions.tsv"
printf '%s\t%s\t%s\t%s\t%s\t%s\n' key version layer effort_mid commit slice_effort HIMMEL-1 v1.0.1 bugs 1 committed '' \
    HIMMEL-8 v1.0.1b bugs 1 committed '' > "$plan/stage3/placement.tsv"
mk 8 'To Do' '["v1.0.1b"]' 'planned trail bug'
mk 11 'To Do' '["v1.0.1b"]' 'trail unplanned'
write_meta 20 0.6 ',"effort_model":{"p90_cap":0.8},"version_p90_fw":{"v1.0.1":0.7,"v1.0.1b":0.05}'
render >/dev/null
html7="$(cat "$out" 2>/dev/null)"
contains 'trail versions sort after their parent, numerically' "$html7" '"V":["v1.0.1","v1.0.1b","v1.0.2","v1.0.10","v2/v3"]'
contains 'a trail inherits its parent override' "$html7" \
    '"VC":[{"t":30,"tot":0.6,"l":[0.45,0.12,0.1,0.05,0.03],"p9":0.8},{"t":30,"tot":0.6,"l":[0.45,0.12,0.1,0.05,0.03],"p9":0.8},{"t":20,'
contains 'a Jira fixVersion naming a trail counts in that trail' "$html7" '[11,"trail unplanned",0,1,'
contains 'the cap text says a trail keeps its parent caps' "$html7" 'takes the overflow of v1.0.1 and keeps its caps'
contains 'the page carries each version P90' "$html7" '"VP":[0.7,0.05,null,null,null]'
contains 'the cap text names the cautious-load cap' "$html7" 'cautious load'
contains 'the drawer words P90 as cautious load' "$html7" '"Cautious load "'
printf '%s\n' "VERSION_CAP_OVERRIDES = {'v1.0.1': {'tickets': 30, 'bugs': 0.45}, 'v1.0.1b': {'tickets': 5}}" > "$plan/tools/stage3/common.py"
render >/dev/null
contains 'a trail named in the overrides takes only its own' "$(cat "$out")" '},{"t":5,"tot":0.6,"l":[0.3,'
printf '%s\n' "VERSION_CAP_OVERRIDES = {'v1.0.1': {'tickets': 30, 'bugs': 0.45}}" > "$plan/tools/stage3/common.py"
# Effort model B words its rules differently and carries the bank rate in effort_model.
printf '%s\n' '{"main_sha_at_build":"abcdef123456","effort_model":{"p90_cap":0.8,"bank_per_seq":0.009},"notes":["effort S-eq: XS .44 S 1 M 2.2 L 5 XL 11.1; synthetic","load (bank) = median x exp(sigma^2/2) x 0.009 bank per S-eq (the log-normal MEAN)","a version holds < 18 tickets, layer load within cap, total mean load within 0.55 and P90 within the model cap"]}' \
    > "$plan/stage3/meta.json"
# Under model B a plan-first row's effort_mid already holds its slice mean (XS 0.44 plus overrun = 0.49).
printf '%s\t%s\t%s\t%s\t%s\t%s\n' key version layer effort_mid commit slice_effort HIMMEL-1 v1.0.1 bugs 1 committed '' \
    HIMMEL-8 v1.0.1b bugs 0.49 plan-first XS > "$plan/stage3/placement.tsv"
render >/dev/null
html8="$(cat "$out" 2>/dev/null)"
contains 'model B: a plan-first row loads the placer slice mean, as the placer sums it' "$html8" '"XS","",0.0044]'
contains 'model B wording: the ticket cap' "$html8" 'at most 18 tickets'
contains 'model B wording: the mean load cap' "$html8" 'at most 0.55 bank of load'
contains 'model B wording: the bank rate, overruns included' "$html8" 'overruns included, × 0.009 bank'
contains 'model B wording: a row loads its mean effort' "$html8" '"changed impact","M–L",4,4,"","plain",0.009]'
write_meta 20 0.6

# --- the page's model — drill-downs, budget by kind and ticket, summaries, remaining-only.
if command -v node >/dev/null 2>&1; then
    mo="$(node "$HERE/tracker-model-check.js" "$W/workers.html" 2>&1)"
    printf '%s\n' "$mo" | grep -v 'failure(s)$'
    if grep -qx '0 failure(s)' <<< "$mo"; then pass 'the model checks pass'; else fail 'the model checks pass'; fi
else
    printf 'skip - node not available: model checks\n'
fi
# --- trail versions (v1.0.1a, v1.0.2b) stay in the train, in train order.
printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' version load_bugs load_enhancements load_features load_misc load_audit load_total est_legs \
    v1.0.1 0.1 0 0 0 0 0.1 1 v1.0.1a 0 0 0 0 0 0 0 v1.0.1b 0.01 0 0 0 0 0.01 1 v1.0.2 0 0 0 0 0 0 0 v1.0.2b 0 0 0 0 0 0 0 v2/v3 0 0 0 0 0 0 0 > "$plan/stage3/versions.tsv"
mk 12 'To Do' '["v1.0.1a"]' 'trail a ticket'
mk 13 'To Do' '["v1.0.2b"]' 'trail b ticket'
tstdout="$(render)"
thtml="$(cat "$out" 2>/dev/null)"
contains 'a v1.0.1a ticket renders' "$thtml" '"trail a ticket"'
contains 'a v1.0.2b ticket renders' "$thtml" '"trail b ticket"'
contains 'trail versions sit in train order' "$thtml" '"v1.0.1","v1.0.1a","v1.0.1b","v1.0.2","v1.0.2b"'
contains 'the whole-train ledger counts trail tickets' "$tstdout" 'Plan rows placed in the whole v1.0.x train (not Jira progress): 1 of 8 done'
contains 'the JS train test accepts a trail suffix' "$thtml" '\d+[a-z]?$/.test(V[i])'

# --- the v1.1.x line (ex v1.0.2b..h) is train, sorted between v1.0.2 and v1.0.3.
cp "$plan/stage3/versions.tsv" "$W/versions.tsv.keep"
printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' version load_bugs load_enhancements load_features load_misc load_audit load_total est_legs \
    v1.0.1 0.1 0 0 0 0 0.1 1 v1.0.1a 0 0 0 0 0 0 0 v1.0.1b 0.01 0 0 0 0 0.01 1 v1.0.2 0 0 0 0 0 0 0 v1.0.3 0 0 0 0 0 0 0 v1.1.0 0 0 0 0 0 0 0 v2/v3 0 0 0 0 0 0 0 > "$plan/stage3/versions.tsv"
mk 14 'To Do' '["v1.1.0"]' 'minor line ticket'
tstdout="$(render)"
thtml="$(cat "$out" 2>/dev/null)"
contains 'a v1.1.0 ticket renders' "$thtml" '"minor line ticket"'
contains 'v1.1.x sits between v1.0.2 and v1.0.3' "$thtml" '"v1.0.2","v1.1.0","v1.0.3"'
contains 'the whole-train ledger counts v1.1.x' "$tstdout" 'Plan rows placed in the whole v1.0.x train (not Jira progress): 1 of 8 done'
cp "$W/versions.tsv.keep" "$plan/stage3/versions.tsv"; rm -f "$mdir/HIMMEL-14.md"

# --- the milestone minors v1.2.0..v1.7.0 are train too, in numeric order, past the v1.1.x line.
printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' version load_bugs load_enhancements load_features load_misc load_audit load_total est_legs \
    v1.0.1 0.1 0 0 0 0 0.1 1 v1.0.1a 0 0 0 0 0 0 0 v1.0.1b 0.01 0 0 0 0 0.01 1 v1.0.2b 0 0 0 0 0 0 0 v1.1.0 0 0 0 0 0 0 0 v1.7.0 0 0 0 0 0 0 0 v1.2.0 0 0 0 0 0 0 0 v1.2.0a 0 0 0 0 0 0 0 v1.2.1000000 0 0 0 0 0 0 0 v1.2.999999 0 0 0 0 0 0 0 v1.10.0 0 0 0 0 0 0 0 v2/v3 0 0 0 0 0 0 0 > "$plan/stage3/versions.tsv"
mk 15 'To Do' '["v1.2.0"]' 'milestone minor ticket'
tstdout="$(render)"
thtml="$(cat "$out" 2>/dev/null)"
contains 'a v1.2.0 ticket renders' "$thtml" '"milestone minor ticket"'
contains 'minors sort numerically, past the v1.1.x line' "$thtml" '"v1.1.0","v1.2.0","v1.2.0a","v1.2.999999","v1.2.1000000","v1.7.0","v1.10.0"'
contains 'the whole-train ledger counts a minor' "$tstdout" 'Plan rows placed in the whole v1.0.x train (not Jira progress): 1 of 9 done'
contains 'the JS train test accepts every v1.N.x' "$thtml" '/^v1\.\d+\.\d+[a-z]?$/'
cp "$W/versions.tsv.keep" "$plan/stage3/versions.tsv"; rm -f "$mdir/HIMMEL-15.md"

# --- version-first page. Versions and release state come from Jira (mirror fixVersions + a `jira versions`
# snapshot in <mirror-dir>.versions.tsv); the main view answers "which version are we working on".
# No versions file yet: no version counts as released and the page says so.
contains 'a missing versions file means release state unknown' "$html" '"RU":true'
contains 'the hero says release state unknown' "$html" '"release state unknown"'
jm="$W/jm"
mkdir -p "$jm"
mdir="$jm"
mk 30 'Done' '["v1.0.1"]' 'released done one' 'Done'
mk 31 'To Do' '["v1.0.1"]' 'released but open' 'To Do'
mk 32 'In Progress' '["v1.0.3","v1.0.2"]' 'review one' 'In Review'
mk 33 'In Progress' '["v1.0.2"]' 'ci one' 'IN CI'
mk 34 'To Do' '["v1.0.3"]' 'next one' 'To Do'
mk 35 'Done' '["v1.0.2"]' 'wont one' 'wont do'
mk 36 'In Progress' '["v1.0.2"]' 'category fallback one'
mk 37 'To Do' '["v1.0.0"]' 'zero version one' 'To Do'
mk 38 'Done' '["v1.0.2"]' 'closed one' 'Closed'
mk 39 'Done' '["v1.0.3"]' 'duplicate one' 'Done' 'Duplicate'
mk 40 'Done' '["v1.0.3"]' 'done in future one' 'Done' 'Done'
mk 43 'Done' '["v1.0.1","v1.0.3"]' 'released and future one' 'Done' 'Done'
mk 44 'Done' '["v1.0.4"]' 'only closed one' 'Closed'
mk 41 'In Progress' '[]' 'flight one' 'In Progress'
mk 42 'To Do' '[]' 'idle unversioned one' 'To Do'
for n in 33 36 40; do sed -i 's/^type: "Bug"$/labels: ["residual"]\n&/' "$jm/HIMMEL-$n.md"; done  # gnu-ok: console kit is Linux-only
mdir="$mir"
printf 'v1.0.0\ttrue\t2026-09-30\nv1.0.1\ttrue\t2026-10-04\nv1.0.2\tfalse\t\nv1.0.3\tfalse\t\nv1.0.4\tfalse\t\n' > "$W/jm.versions.tsv"
render --mirror-dir "$jm" >/dev/null
jhtml="$(cat "$out" 2>/dev/null)"
contains 'the default versions file is <mirror-dir>.versions.tsv' "$jhtml" \
    '"JV":[{"n":"v1.0.1","rel":true,"date":"2026-10-04"},{"n":"v1.0.2","rel":false,"date":""},{"n":"v1.0.3","rel":false,"date":""},{"n":"v1.0.4","rel":false,"date":""}]'
contains 'a versions file means release state is known' "$jhtml" '"RU":false'
contains 'a released version has no caps: its tickets already shipped' "$jhtml" '"VC":[null,'
not_contains 'a ticket with only v1.0.0 is in no version' "$jhtml" '"t":"zero version one"'
contains 'working on is the earliest unreleased version with open work, not a released one' "$jhtml" '"JC":1,'
contains 'up next is the next unreleased version holding a ticket' "$jhtml" '"JN":2,'
contains 'a released version holding an open ticket is alerted, naming the ticket' "$jhtml" '"JA":[[0,[31]]]'
contains 'the alert text names the release date and the open tickets' "$jhtml" ' but still holds '
contains 'the released-but-open alert still renders when no unreleased version is open' "$jhtml" \
    's.textContent="Every unreleased version is done.";jalerts(-1);return}'
contains 'In Review is counted from the status name' "$jhtml" '"k":32,"t":"review one","s":"In Review","b":"rev","v":1,'
contains 'IN CI is counted from the status name' "$jhtml" '"k":33,"t":"ci one","s":"IN CI","b":"ci","v":1,'
not_contains 'a wont-do ticket is in no count, bar or column' "$jhtml" '"t":"wont one"'
not_contains 'a Closed ticket is in no count, bar or column' "$jhtml" '"t":"closed one"'
not_contains 'a Done ticket with a Duplicate resolution is in no count' "$jhtml" '"t":"duplicate one"'
not_contains 'a closed-without-shipping ticket is in no plan row either' "$jhtml" '"closed one"'
contains 'closed without shipping is one count per version, not a Done count' "$jhtml" '"JW":[[1,2],[2,1],[3,1]]'
contains 'a Done ticket in a future version is counted in the current one' "$jhtml" \
    '"k":40,"t":"done in future one","s":"Done","b":"done","v":1,'
not_contains 'a Done ticket naming a released and a later unreleased version is not counted again in the current one' "$jhtml" \
    '"k":43,"t":"released and future one","s":"Done","b":"done","v":1,'
contains 'a Done ticket naming a released and a later unreleased version stays in the released one' "$jhtml" \
    '"k":43,"t":"released and future one","s":"Done","b":"done","v":0,'
contains 'a version holding only closed-without-shipping work gets a kanban row' "$jhtml" \
    'data-v="v1.0.4" data-open="0" data-residual="0"><summary><span class="vn">v1.0.4</span> <span class="kmeta">0 open · 0 residual · 1 closed without shipping</span>'
contains 'a version row shows its open count as the size and its residual count by name (the tick open= and residual for v1.0.2)' "$jhtml" \
    'data-v="v1.0.2" data-open="3" data-residual="2">'
contains 'the version row text says open N and residual M' "$jhtml" '3 open · 2 residual'
contains 'the client version table renders a row for a closed-only version' "$jhtml" \
    '[1];if(!t.n&&!wn)return;if(HIDE&&!t.open&&t.n){hid++;return}'
contains 'the footnote says closed without shipping' "$jhtml" 'closed without shipping'
not_contains 'the legend no longer calls Closed or wont do work done' "$jhtml" 'Hides Done, Closed, In Public, wont do'
contains 'an unknown status falls back to the status category' "$jhtml" '"t":"category fallback one","s":"In Progress","b":"prog"'
contains 'a released-only ticket keeps its released version' "$jhtml" '"k":30,"t":"released done one","s":"Done","b":"done","v":0,'
contains 'hide done work is ON by default' "$jhtml" 'var HIDE=true;try{var hs=localStorage.getItem("hide3990")'
contains 'the hide switch starts checked' "$jhtml" 'role="switch" aria-checked="true"'
contains 'the switch is labelled Hide done work' "$jhtml" 'Hide done work</button>'
contains 'the board caps a column at 6 cards' "$jhtml" 'slice(0,6)'
contains 'a drill says where the plan places a ticket that Jira puts elsewhere' "$jhtml" '"the plan places it in "'
contains 'every version is a keyboard-pickable row' "$jhtml" 'e.key=="Enter"||e.key==" "'
contains 'the version table is titled Every version' "$jhtml" '<h2 id="vh">Every version</h2>'
not_contains 'no tiles section' "$jhtml" 'id="tiles"'
# an explicit --versions-file wins over the default path
printf 'v1.0.1\tfalse\t\nv1.0.2\ttrue\t2026-10-05\n' > "$W/alt.versions.tsv"
render --mirror-dir "$jm" --versions-file "$W/alt.versions.tsv" >/dev/null
althtml="$(cat "$out" 2>/dev/null)"
contains '--versions-file names the snapshot' "$althtml" '"JV":[{"n":"v1.0.1","rel":false,"date":""},{"n":"v1.0.2","rel":true,"date":"2026-10-05"}]'
# an empty (truncated) versions file is no snapshot: it falls back like a missing one
: > "$W/empty.versions.tsv"
render --mirror-dir "$jm" --versions-file "$W/empty.versions.tsv" >/dev/null
emhtml="$(cat "$out" 2>/dev/null)"
contains 'an empty versions file means release state unknown' "$emhtml" '"RU":true'
contains 'an empty versions file still lists the mirror fixVersions' "$emhtml" '"JV":[{"n":"v1.0.1","rel":false,"date":""},'
contains 'an empty versions file still shows the tickets' "$emhtml" '"t":"released but open"'
# the versions file is a fingerprint input: a release moves tracker=
fpa='' fpb='' fpc='' fpd='' fpe=''
fp_ok 'versions base' fpa --mirror-dir "$jm"
printf 'v1.0.1\ttrue\t2026-10-04\nv1.0.2\ttrue\t2026-10-05\nv1.0.3\tfalse\t\n' > "$W/jm.versions.tsv"
fp_ok 'versions released' fpb --mirror-dir "$jm"
if [ -n "$fpa" ] && [ "$fpa" != "$fpb" ]; then pass 'a versions-file change moves the fingerprint'; else fail "a versions-file change left the fingerprint at '$fpa'"; fi
fp_ok 'versions explicit' fpc --mirror-dir "$jm" --versions-file "$W/alt.versions.tsv"
if [ "$fpb" != "$fpc" ]; then pass '--emit-fp reads --versions-file'; else fail '--emit-fp ignored --versions-file'; fi
rm -f "$W/jm.versions.tsv"
fp_ok 'versions missing' fpd --mirror-dir "$jm"
if [ "$fpb" != "$fpd" ]; then pass 'a missing versions file differs from a present one'; else fail 'a missing versions file left the fingerprint'; fi
fp_ok 'versions missing again' fpe --mirror-dir "$jm"
if [ "$fpd" = "$fpe" ]; then pass 'the fingerprint is stable with the versions file missing'; else fail 'the fingerprint moved with no input change'; fi

# --- drift log + trend.
dl="$W/drift.tsv"
unthemed_of() { printf '%s' "$1" | sed -n 's/.*drift, \([0-9]*\) unthemed,.*/\1/p'; }
base_unthemed="$(unthemed_of "$(render --drift-log "$dl")")"
sect7_on() { cp "$mir/HIMMEL-7.md" "$W/h7.bak"; { sed -n 1p "$W/h7.bak"; printf 'sector: "Tooling"\n'; sed 1d "$W/h7.bak"; } > "$mir/HIMMEL-7.md"; }
sect7_off() { cp "$W/h7.bak" "$mir/HIMMEL-7.md"; }
sect7_on
ostdout="$(render --drift-log "$dl")"
sect7_off
if [ -n "$base_unthemed" ] && [ "$(unthemed_of "$ostdout")" = "$((base_unthemed - 1))" ]; then pass "a mirror sector lowers the unthemed count by one"; else fail "unthemed went from '$base_unthemed' to '$(unthemed_of "$ostdout")'"; fi
rows_n() { grep -c . "$dl" 2>/dev/null || printf 0; }
rm -f "$dl"
render --drift-log "$dl" >/dev/null
if grep -Eq '^20[0-9-]+T[0-9:]+Z	[0-9]+	[0-9]+	[0-9]+$' "$dl" 2>/dev/null && [ "$(head -1 "$dl")" = "$(printf 'utc\tdrift\tunplanned\tunthemed')" ]; then pass 'a render appends one drift row: stamp, drift, unplanned, unthemed'; else fail 'no well-formed drift row'; fi
n1="$(rows_n)"
render --drift-log "$dl" >/dev/null
if [ "$n1" = "$(rows_n)" ] && [ "$n1" -ge 2 ]; then pass 'an unchanged render within the hour adds no drift row'; else fail "unchanged render grew the drift log from $n1 to $(rows_n)"; fi
sect7_on
render --drift-log "$dl" >/dev/null
sect7_off
if [ "$(rows_n)" -gt "$n1" ]; then pass 'a changed count adds a drift row'; else fail 'a changed count left the drift log alone'; fi
trend="$(render --drift-log "$dl")"
contains 'stdout prints the drift trend' "$trend" 'drift trend:'
contains 'the page carries the drift trend' "$(cat "$out" 2>/dev/null)" '"DT":[['

# --- a per-release kanban, rendered as static HTML. A fixture release holds one ticket per status.
kmir="$W/mirror-kanban"
mkdir -p "$kmir"
mdir="$kmir"
mk 31 'To Do' '["v1.0.9"]' 'kanban todo ticket' 'To Do'
mk 32 'In Progress' '["v1.0.9"]' 'kanban prog ticket' 'In Progress'
mk 33 'In Progress' '["v1.0.9"]' 'kanban review ticket' 'In Review'
mk 34 'In Progress' '["v1.0.9"]' 'kanban ci ticket' 'IN CI'
mk 35 'Done' '["v1.0.9"]' 'kanban done ticket' 'Done'
printf '%s\n' '' '## Description' '' 'Impact' 'Operators can now see the kanban of a release. A second sentence must not show.' 'What' 'x' '' '## Comments' '' '_(none)_' >> "$kmir/HIMMEL-31.md"
printf '%s\n' '' '## Description' '' 'Impact' 'Cards say what a ticket means for a user & more.' 'What' 'x' '' '## Comments' '' '_(none)_' >> "$kmir/HIMMEL-35.md"
kout="$W/kanban.html"
krender() {
    python3 "$HERE/tracker.py" --plan-dir "$plan" --out "$kout" --luna-map "$W/luna-map-k.json" \
        --mirror-dir "$kmir" --luna-root "$W/luna" --handovers "$W/luna/handovers/tester/himmel" "$@" 2>&1
}
krender --jira-base-url 'https://jira.example.test/' >/dev/null
khtml="$(cat "$kout" 2>/dev/null)"
# kcol <html> <column title> -- the markup of one kanban column of the v1.0.9 release panel.
kcol() { printf '%s' "$1" | python3 -c '
import re, sys
h = sys.stdin.read()
p = re.search(r"<details class=\"krel\"[^>]*data-v=\"v1\.0\.9\".*?</details>", h, re.S)
c = re.search(r"<div class=\"kcol\" data-col=\"" + sys.argv[1] + r"\">.*?(?=<div class=\"kcol\"|</div></details>)", p.group(0), re.S) if p else None
print(c.group(0) if c else "")' "$2"; }
contains 'a release panel holds a drill-down for v1.0.9' "$khtml" 'data-v="v1.0.9"'
kt="$(kcol "$khtml" todo)"; kp="$(kcol "$khtml" prog)"; kr="$(kcol "$khtml" rev)"; kd="$(kcol "$khtml" "done")"
contains 'To Do column holds the To Do ticket' "$kt" 'HIMMEL-31'
contains 'In Progress column holds the In Progress ticket' "$kp" 'HIMMEL-32'
contains 'In Review column holds the In Review ticket' "$kr" 'HIMMEL-33'
kc="$(kcol "$khtml" ci)"
contains 'IN CI column holds the IN CI ticket' "$kc" 'HIMMEL-34'
not_contains 'In Review column no longer holds the IN CI ticket' "$kr" 'HIMMEL-34'
contains 'Done column holds the Done ticket' "$kd" 'HIMMEL-35'
not_contains 'a ticket sits in one column only' "$kt$kp$kd" 'HIMMEL-33'
contains 'a card links to the Jira browse URL from the configured base' "$kt" 'href="https://jira.example.test/browse/HIMMEL-31"'
contains 'a card shows the ticket summary' "$kt" 'kanban todo ticket'
contains 'a card shows the first sentence of the Impact block' "$kt" 'Operators can now see the kanban of a release.'
not_contains 'a card stops after the first Impact sentence' "$kt" 'A second sentence must not show'
contains 'a card line is HTML-escaped' "$kd" 'user &amp; more'
contains 'a ticket without Impact falls back to its summary as the line' "$kp" '<div class="kline">kanban prog ticket</div>'
krender --jira-base-url "" >/dev/null
contains 'with no base URL the key is plain text, never a made-up host' "$(cat "$kout")" '<span class="kkey">HIMMEL-31</span>'
not_contains 'with no base URL there is no browse link' "$(cat "$kout")" '/browse/HIMMEL-31'
kfp1="$(krender --emit-fp --jira-base-url "")"
krender --jira-base-url 'https://jira.example.test/' >/dev/null
kfp2="$(krender --emit-fp --jira-base-url "https://jira.example.test/")"
if [[ "$kfp1" =~ ^[0-9a-f]{16}$ ]] && [ "$kfp1" = "$kfp2" ]; then pass 'the kanban leaves the fingerprint semantics alone'; else fail "fingerprint moved with the base URL or failed: '$kfp1' vs '$kfp2'"; fi

# --- re-measured actuals, spawned bundles under their planned origin, the operator bundle, zone labels.
# Own plan, mirror and handover tree. 100 is planned; 101 says it was deferred from 100, 102 is a follow-up of 101
# (A to B to C), a worker of 101 filed 103, 108 relates to 100 by a Jira link. 104 carries the operator-directed label,
# a chief OPERATOR bullet filed 105, 106 follows up 105. 107 and 109 reach no anchor (109 is named only by a RULING).
bplan="$W/bplan" bmir="$W/bmirror" bh="$W/bluna/handovers/tester/himmel"
cp -r "$plan" "$bplan"
mkdir -p "$bmir" "$bh"
printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' version load_bugs load_enhancements load_features load_misc load_audit load_total est_legs \
    v1.0.1 0.1 0 0 0 0 0.1 1 v2/v3 0 0 0 0 0 0 0 > "$bplan/stage3/versions.tsv"
printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' key version layer effort_mid commit slice_effort reason HIMMEL-100 v1.0.1 features 2.2 committed '' '' \
    > "$bplan/stage3/placement.tsv"
printf '%s\t%s\t%s\t%s\n' key readiness effort_low effort_high HIMMEL-100 3 M M > "$bplan/stage2/C01.tsv"
# bmk <n> <statusCategory> <fixVersions json> <title> <labels json> <links relates json> [description line]
bmk() {
    {
        printf '%s\n' '---' "key: \"HIMMEL-$1\"" 'updated: "2026-09-30T10:00:00.000+0200"' "statusCategory: \"$2\"" \
            "labels: $5" 'parent: null' "fixVersions: $3" 'type: "Task"' 'links:' '  blocks: []' '  blocked_by: []' \
            "  relates: $6" '---' "# HIMMEL-$1: $4" '' '## Description' '' "${7:-}" '' '## Comments' '' '_(none)_'
    } > "$bmir/HIMMEL-$1.md"
}
bmk 100 'Done' '["v1.0.1"]' 'planned origin' '[]' '[]'
bmk 101 'Done' '[]' 'lint gap' '[]' '[]' 'Deferred from the /pr-check of HIMMEL-100.'
bmk 102 'To Do' '[]' '[HIMMEL-101 follow-up] tighten the lint' '[]' '[]'
bmk 103 'Done' '[]' 'filed by a worker' '[]' '[]'
bmk 104 'To Do' '[]' 'operator label' '["operator-directed"]' '[]'
bmk 105 'Done' '[]' 'operator ask' '[]' '[]'
bmk 106 'To Do' '[]' 'operator follow-up' '[]' '[]' 'A follow-up from HIMMEL-105.'
bmk 107 'To Do' '["v1.0.1"]' 'nobody claims me' '[]' '[]'
bmk 108 'To Do' '[]' 'linked follow-up' '[]' '["HIMMEL-100"]'
bmk 109 'To Do' '["v1.0.1"]' 'named by a ruling' '[]' '[]' 'Mentions HIMMEL-200 which is newer, never an origin.'
# A multi-day worker: 22:00 on 2026-10-01 to 23:00 on 2026-10-02 is 25 h of wall time; only 180 min of it is active.
printf '%s\n' '# worker' '## Results' '- 22:00 LIVE — started' '- 23:30 LIVE — PR 1 open' '- 01:00 READY 1 abc GREEN' \
    '- 23:00 WRAPPED — merged' > "$bh/HIMMEL-100-N90-planned-origin-2026-10-01.md"
# A note after WRAPPED and a later section's bullet are past the measured span; a later section's filing is not the worker's.
printf '%s\n' '# worker' '## Results' '- 10:00 LIVE — filed HIMMEL-103 for the second gap' '- 10:45 WRAPPED — merged' \
    '- 11:30 note after the wrap' '## Notes' '- 12:00 a later note: filed HIMMEL-107 elsewhere' > "$bh/HIMMEL-101-N91-lint-gap-2026-10-02.md"
printf '%s\n' '# worker' '## Results' '- 09:00 LIVE — started' '- 09:30 WRAPPED — merged' > "$bh/HIMMEL-102-N94-no-date.md"
printf '%s\n' '# worker' '## Results' '- 09:00 LIVE — started' '- 09:20 WRAPPED — merged' > "$bh/HIMMEL-105-N93-operator-ask-2026-10-03.md"
printf '%s\n' '# chief' '## Results' '- 22:57 OPERATOR: do the thing. Filed HIMMEL-105; DISPATCH N93' \
    '- 23:10 OPERATOR RULING: Filed HIMMEL-109 is not an ask' '- 23:15 **OPERATOR** RULING: Filed HIMMEL-109 again' > "$bh/HIMMEL-nextleg-2026-10-03A-roadmap-chief.md"
bout="$W/bench.html"
brender() {
    TZ=Europe/Berlin python3 "$HERE/tracker.py" --plan-dir "$bplan" --out "$bout" --luna-map "$W/luna-map-b.json" \
        --mirror-dir "$bmir" --luna-root "$W/bluna" --handovers "$bh" "$@" 2>&1
}
bstdout="$(brender)"
bhtml="$(cat "$bout" 2>/dev/null)"
btsv="$bout.bench.tsv"
contains 'the Jira stamp is converted to UTC and labelled' "$bhtml" '"mir":"2026-09-30 08:00 UTC"'
contains 'a multi-day worker counts its dated wall span and its active minutes apart' "$bhtml" '"100":[1,1500,180,1]'
contains 'a worker doc with no date in its name counts active minutes but no dated wall' "$bhtml" '"102":[1,0,30,0]'
contains 'the page names the source of each number' "$bhtml" 'wall = first Results bullet to WRAPPED'
contains 'the cost column says it is not measured' "$bhtml" 'cost: not measured'
if [ -f "$btsv" ]; then pass 'the benchmark TSV is written beside the page'; else fail 'no benchmark TSV beside the page'; fi
bcol() { awk -F'\t' -v k="$1" -v c="$2" 'NR==1{for(i=1;i<=NF;i++)h[$i]=i;next}$1==k{print $(h[c])}' "$btsv" 2>/dev/null; }
contains 'A to B to C rolls up to the first planned ancestor; a worker-filed and a linked ticket join it' \
    "$(bcol $KP-100 members)" "$KP-101,$KP-102,$KP-103,$KP-108"
contains 'the bundle counts open and done' "$(bcol $KP-100 bundle_n) $(bcol $KP-100 bundle_open) $(bcol $KP-100 bundle_done)" '4 2 2'
contains 'the bundle folds into the item total' "$(bcol $KP-100 own_wall_min) $(bcol $KP-100 bundle_wall_min) $(bcol $KP-100 total_wall_min)" '1500 45 1545'
contains 'the bundle coverage counts its dated workers' "$(bcol $KP-100 bundle_legs) $(bcol $KP-100 bundle_dated)" '2 1'
contains 'a ratio over partly undated workers is left blank' "$(bcol HIMMEL-100 est_seq) [$(bcol HIMMEL-100 min_per_seq)] [$(bcol HIMMEL-100 ratio)]" '2.2 [] []'
contains 'the dated span is printed in UTC' "$(bcol $KP-100 first_utc) $(bcol $KP-100 end_utc)" '2026-10-01T20:00Z 2026-10-02T21:00Z'
contains 'the operator bundle holds labelled, backfilled and their spawned tickets' \
    "$(bcol operator-directed members)" 'HIMMEL-104,HIMMEL-105,HIMMEL-106'
contains 'the operator bundle carries its actuals' "$(bcol operator-directed bundle_wall_min) $(bcol operator-directed bundle_open)" '20 2'
contains 'unattributed unplanned train tickets are their own visible bundle; a RULING bullet is no ask' \
    "$(bcol unattributed members)" 'HIMMEL-107,HIMMEL-109'
contains 'the page carries the bundles' "$bhtml" '"BN":['
contains 'stdout names the TSV' "$bstdout" 'bench.tsv'
bfp1="$(brender --emit-fp)"
printf '%s\n' '- 23:20 OPERATOR: one more. Filed HIMMEL-107' >> "$bh/HIMMEL-nextleg-2026-10-03A-roadmap-chief.md"
bfp2="$(brender --emit-fp)"
if [ -n "$bfp1" ] && [ "$bfp1" != "$bfp2" ]; then pass 'a new OPERATOR filing moves the fingerprint'; else fail 'a new OPERATOR filing left the fingerprint'; fi
mv "$bh/HIMMEL-102-N94-no-date.md" "$bh/HIMMEL-102-N94-now-dated-2026-10-02.md"
brender >/dev/null
contains 'the ratio sits beside its raw inputs once every worker is dated' \
    "$(bcol $KP-100 bundle_legs) $(bcol $KP-100 bundle_dated) $(bcol $KP-100 est_seq) $(bcol $KP-100 min_per_seq) $(bcol $KP-100 ratio)" '2 2 2.2 715.9 1.00'

# a Jira `theme-<slug>` label is no longer a theme: the page groups by the Jira Sector field.
printf '%s\t%s\t%s\n' key theme impact HIMMEL-10 legacy 2 HIMMEL-11 'Build Tools' 2 > "$plan/stage1/C02.tsv"
tl() {  # tl <n> <labels json>
    printf '%s\n' '---' "key: \"HIMMEL-$1\"" 'updated: "2026-09-30T10:00:00.000+0000"' 'statusCategory: "To Do"' \
        'fixVersions: []' 'type: "Bug"' "labels: $2" '---' "# HIMMEL-$1: label theme ticket $1" > "$mir/HIMMEL-$1.md"
}
tl 8 '["theme-tooling"]'
tl 9 '["other", "theme-fresh-label"]'
tl 10 '["theme-fresh-label"]'
tl 11 '["theme-build-tools"]'
tout="$W/theme.html"
python3 "$HERE/tracker.py" --plan-dir "$plan" --out "$tout" --luna-map "$W/luna-map.json" \
    --mirror-dir "$mir" --luna-root "$W/luna" --handovers "$W/luna/handovers/tester/himmel" >/dev/null 2>&1
thtml="$(cat "$tout" 2>/dev/null)"
not_contains 'a theme label is not a group' "$thtml" '"fresh-label"'
not_contains 'the stage1 theme is not a group either' "$thtml" '"legacy"'

# --- done-in-future drift: a Done ticket in an unreleased version other than the current one
# (earliest unreleased by release date) is counted; Done in the current or a released version is not.
dfm="$W/dfm"
mkdir -p "$dfm"
mdir="$dfm"
mk 60 'Done' '["v1.0.1"]' 'done in released' 'Done'
mk 61 'Done' '["v1.0.2"]' 'done in current' 'Done'
mk 62 'Done' '["v1.0.4"]' 'done in future' 'Done'
mk 63 'To Do' '["v1.0.4"]' 'open in future' 'To Do'
mdir="$mir"
printf 'v1.0.1\ttrue\t2026-10-04\nv1.0.2\tfalse\t2026-10-20\nv1.0.4\tfalse\t\n' > "$dfm.versions.tsv"
dfout="$(render --mirror-dir "$dfm")"
contains 'the summary counts Done-in-future-version tickets' "$dfout" ', 1 done-in-future;'
printf 'v1.0.1\ttrue\t2026-10-04\nv1.0.2\tfalse\t2026-10-20\n' > "$dfm.versions.tsv"
dfout="$(render --mirror-dir "$dfm")"
contains 'no Done ticket past the current version counts zero' "$dfout" ', 0 done-in-future;'

# --- remaining-only board (--remaining): open tickets of one version, grouped by the plan's priority line.
rb="$W/rb"
mkdir -p "$rb"
mdir="$rb"
mk 70 'Done' '["v1.1.3"]' 'done in version' 'Done'
mk 71 'To Do' '["v1.1.3"]' 'first group open' 'To Do'
mk 72 'In Progress' '["v1.1.3"]' 'second group open' 'In Progress'
mk 73 'To Do' '["v1.1.3"]' 'on no group line' 'To Do'
mk 74 'To Do' '["v1.1.4"]' 'other version' 'To Do'
mk 75 'Done' '["v1.1.3"]' 'wont do in version' 'Wont Do'
mdir="$mir"
pf="$W/rb-plan.md"
# shellcheck disable=SC2016  # the backticks are literal plan text
printf '%s\n' '`priority:` line for the console:' '' '71 K1 | 72 (5000 71) | rest of v1.1.3 | 6100' > "$pf"
rbout="$(python3 "$HERE/tracker.py" --remaining v1.1.3 --mirror-dir "$rb" --priority-file "$pf" 2>&1)"
contains 'the remaining board lists an open ticket of the version' "$rbout" 'HIMMEL-71 [To Do] first group open'
not_contains 'the remaining board drops a Done ticket' "$rbout" 'HIMMEL-70'
not_contains 'the remaining board drops a wont-do ticket' "$rbout" 'HIMMEL-75'
not_contains 'the remaining board drops another version' "$rbout" 'HIMMEL-74'
contains 'the first priority segment is group 0' "$rbout" '## 0 critical (1)'
contains 'the second priority segment is group 1K' "$rbout" '## 1K knowledge retrieval (1)'
contains 'the first group holds ticket 71' "$rbout" "## 0 critical (1)"$'\n- HIMMEL-71 '
contains 'the second group holds ticket 72' "$rbout" "## 1K knowledge retrieval (1)"$'\n- HIMMEL-72 '
contains 'the rest group holds ticket 73' "$rbout" "## rest of version (1)"$'\n- HIMMEL-73 '
if python3 "$HERE/tracker.py" --remaining v1.1.3 --mirror-dir "$rb" --priority-file "$W/no-such-plan.md" >/dev/null 2>&1; then
    fail 'an explicit priority file that cannot be read fails the render'
else
    pass 'an explicit priority file that cannot be read fails the render'
fi
contains 'a ticket on no group line goes to the rest group' "$rbout" '## rest of version (1)'
contains 'the heading counts the open tickets' "$rbout" '# v1.1.3 remaining board: 3 open'
rbfile="$W/rb-out.md"
python3 "$HERE/tracker.py" --remaining v1.1.3 --mirror-dir "$rb" --priority-file "$pf" --out "$rbfile" >/dev/null 2>&1
contains '--out writes the board to a file' "$(cat "$rbfile" 2>/dev/null)" 'HIMMEL-72 [In Progress] second group open'

s2h="$W/s2home"; s2c="$W/s2cfg"; s2v="$W/s2vault"
mkdir -p "$s2h/.himmel/state/jira-mirror" "$s2c" "$s2v/handovers/s2user/himmel"
printf 'JIRA_PROJECT_KEY=ACME\n' > "$s2c/himmel.conf"
cp -R "$rb" "$s2h/.himmel/state/jira-mirror/ACME"
s2want="$(python3 "$HERE/tracker.py" --remaining v1.1.3 --mirror-dir "$rb" --priority-file "$pf" 2>&1)"
s2got="$(env -u HIMMEL_JIRA_MIRROR HOME="$s2h" HIMMEL_CONFIG_DIR="$s2c" JIRA_PROJECT_KEY= python3 "$HERE/tracker.py" --remaining v1.1.3 --priority-file "$pf" 2>&1)"
equals 'the default mirror dir follows the key only himmel.conf names' "$s2got" "$s2want"
s2got="$(env -u HIMMEL_JIRA_MIRROR HOME="$s2h" HIMMEL_CONFIG_DIR="$s2c" JIRA_PROJECT_KEY= python3 "$HERE/tracker.py" --remaining v1.1.3 --mirror-dir "$rb" --priority-file "$pf" 2>&1)"
equals '--mirror-dir still wins over the resolver default' "$s2got" "$s2want"
printf '%s\n' '# worker' '## Results' '- 10:00 LIVE — up' > "$s2v/handovers/s2user/himmel/HIMMEL-7-N57-s2-worker-2026-11-15.md"
printf '{"schema":1,"workers":[{"doc":"%s","label":"N57"}]}\n' "$s2v/handovers/s2user/himmel/HIMMEL-7-N57-s2-worker-2026-11-15.md" > "$s2v/handovers/s2user/himmel/test-console.fleet.json"
env -u TRACKER_HANDOVERS_DIR HOME="$s2h" HIMMEL_CONFIG_DIR="$s2c" JIRA_PROJECT_KEY= USER_SLUG=s2user LUNA_VAULT_PATH="$s2v" \
    python3 "$HERE/tracker.py" --plan-dir "$plan" --out "$W/s2-live.html" --luna-map "$W/s2-luna-map.json" --mirror-dir "$mir" >/dev/null 2>&1
contains 'the default luna and handover dirs come from LUNA_VAULT_PATH and USER_SLUG' "$(cat "$W/s2-live.html" 2>/dev/null)" '"7":["N57","LIVE"'

# --- remaining board blockers: a parseable ` {blocked-by: HIMMEL-n open|done, ...}` suffix on the card line.
bb="$W/bb"
mkdir -p "$bb"
mdir="$bb"
mk 90 'To Do' '["v1.1.3"]' 'blocked by link' 'To Do'
mk 91 'To Do' '["v1.1.4"]' 'open link blocker' 'To Do'
mk 92 'To Do' '["v1.1.3"]' 'blocked by body line' 'To Do'
mk 93 'Done' '["v1.1.3"]' 'closed body blocker' 'Done' 'Done'
mk 94 'To Do' '["v1.1.3"]' 'unblocked card' 'To Do'
mdir="$mir"
printf '%s\n' '---' 'key: "HIMMEL-90"' 'statusCategory: "To Do"' 'status: "To Do"' 'fixVersions: ["v1.1.3"]' 'type: "Bug"' 'links:' '  blocks: []' \
    '  blocked_by: ["HIMMEL-91"]' '  relates: ["relates to HIMMEL-94"]' '---' '# HIMMEL-90: blocked by link' > "$bb/HIMMEL-90.md"
printf '%s\n' '' '## Description' '' 'Agent detail' 'Depends on HIMMEL-93 and HIMMEL-91 (the seam).' '' '## Comments' '' 'BLOCKED-BY HIMMEL-94' >> "$bb/HIMMEL-92.md"
bbrc=0
bbout="$(python3 "$HERE/tracker.py" --remaining v1.1.3 --mirror-dir "$bb" --priority-file "$pf" 2>&1)" || bbrc=$?
if [ "$bbrc" -eq 0 ]; then pass '--remaining with blockers exits 0'; else fail "--remaining with blockers exited $bbrc"; fi
contains 'a blocked_by link lands in the suffix as open' "$bbout" 'HIMMEL-90 [To Do] blocked by link {blocked-by: HIMMEL-91 open}'
contains 'a Depends-on body line lands in the suffix, closed and open' "$bbout" 'HIMMEL-92 [To Do] blocked by body line {blocked-by: HIMMEL-93 done, HIMMEL-91 open}'
contains 'a card with no blocker keeps the bare line' "$bbout" 'HIMMEL-94 [To Do] unblocked card'
not_contains 'a relates link is no blocker' "$bbout" 'HIMMEL-94 [To Do] unblocked card {'
not_contains 'a relates link is no blocker (the linking card names only its blocked_by key)' "$bbout" 'HIMMEL-90 [To Do] blocked by link {blocked-by: HIMMEL-91 open, HIMMEL-94'
mdir="$bb"
mk 95 'To Do' '["v1.1.3"]' 'colon form' 'To Do'
mdir="$mir"
printf '%s\n' '' '## Description' '' 'BLOCKED-BY: HIMMEL-91. Now unblocked by HIMMEL-93.' 'Depends on HIMMEL-96, HIMMEL-97, and HIMMEL-98.' >> "$bb/HIMMEL-95.md"
bbrc=0
bbout="$(python3 "$HERE/tracker.py" --remaining v1.1.3 --mirror-dir "$bb" --priority-file "$pf" 2>&1)" || bbrc=$?
if [ "$bbrc" -eq 0 ]; then pass '--remaining with a colon-form blocker exits 0'; else fail "--remaining with a colon-form blocker exited $bbrc"; fi
contains 'an upper-case BLOCKED-BY: form lands in the suffix; "unblocked by" is no blocker' "$bbout" 'HIMMEL-95 [To Do] colon form {blocked-by: HIMMEL-91 open, HIMMEL-96 open, HIMMEL-97 open, HIMMEL-98 open}'

# --- done-in-future counts every unreleased version, not only v1.0.x.
dfm="$W/dfm2"
mkdir -p "$dfm"
mdir="$dfm"
mk 80 'Done' '["v1.1.3"]' 'done in current' 'Done'
mk 81 'Done' '["v1.1.4"]' 'done in future v1.1.4' 'Done'
mdir="$mir"
printf 'v1.1.3\tfalse\t2026-10-20\nv1.1.4\tfalse\t\n' > "$dfm.versions.tsv"
dfout="$(render --mirror-dir "$dfm")"
contains 'a Done ticket in a future v1.1.x counts as done-in-future' "$dfout" ', 1 done-in-future;'

# A Done ticket in a later major version (v2.0.0) counts too: the count is not limited to the v1 train.
dfm="$W/dfm3"
mkdir -p "$dfm"
mdir="$dfm"
mk 85 'Done' '["v1.1.3"]' 'done in current' 'Done'
mk 86 'Done' '["v2.0.0"]' 'done in a later major' 'Done'
mdir="$mir"
printf 'v1.1.3\tfalse\t2026-10-20\nv2.0.0\tfalse\t\n' > "$dfm.versions.tsv"
dfout="$(render --mirror-dir "$dfm")"
contains 'a Done ticket in a later major version counts as done-in-future' "$dfout" ', 1 done-in-future;'

# --- per-version page defects: multi-version tickets, in-flight lane, current version, fleet-manifest workers.
# Item 2: a ticket with two fixVersions is counted in each (ticket 32 holds v1.0.3 and v1.0.2).
contains 'a ticket with two fixVersions is counted in its second version too' "$jhtml" \
    '"k":32,"t":"review one","s":"In Review","b":"rev","v":2,'
# Item 5: open In Progress / In Review work with no fixVersion is visible in its own lane.
contains 'unversioned in-flight work has its own lane' "$jhtml" 'In flight, no version'
contains 'the lane lists the in-flight ticket' "$jhtml" 'flight one'
not_contains 'the lane leaves out an unversioned To Do ticket' "$jhtml" 'idle unversioned one'
# Item 4: the plan blocks follow the hero's rule: a released version is never current.
cu="$W/cu"
mkdir -p "$cu"
cp -r "$plan" "$W/plan4"
printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' version load_bugs load_enhancements load_features load_misc load_audit load_total est_legs \
    v1.0.1 0.1 0 0 0 0 0.1 1 v1.0.2 0.1 0 0 0 0 0.1 1 > "$W/plan4/stage3/versions.tsv"
printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' key version layer effort_mid commit slice_effort reason \
    HIMMEL-1 v1.0.1 bugs 1 committed '' 'P1; pinned to v1.0.1 (ruling)' \
    HIMMEL-90 v1.0.2 bugs 1 committed '' 'P1; pinned to v1.0.2 (ruling)' > "$W/plan4/stage3/placement.tsv"
mdir="$cu"
mk 1 'To Do' '["v1.0.1"]' 'planned bug' 'To Do'
mk 90 'To Do' '["v1.0.2"]' 'next version bug' 'To Do'
mdir="$mir"
printf 'v1.0.1\ttrue\t2026-10-04\nv1.0.2\tfalse\t\n' > "$cu.versions.tsv"
render --plan-dir "$W/plan4" --mirror-dir "$cu" >/dev/null
cuhtml="$(cat "$out" 2>/dev/null)"
contains 'a released version is not the plan blocks current version' "$cuhtml" '"CUR":1,'
# Item 1: a worker listed in a chief's fleet manifest is live without a held queue lock.
printf '{"schema":1,"legs":[{"doc":"%s","label":"N57"}]}\n' "$bk/HIMMEL-7-N57-released-worker-2026-10-01.md" > "$bk/test-console.fleet.json"
render >/dev/null
fmhtml="$(cat "$out" 2>/dev/null)"
rm -f "$bk/test-console.fleet.json"
contains 'a worker in the fleet manifest is live with its label and phase' "$fmhtml" '"7":["N57","LIVE"'
# the same manifest under the workers key reads; with HIMMEL_LEGACY_NAMES=0 the old legs key is skipped and workers still reads
printf '{"schema":1,"workers":[{"doc":"%s","label":"N57"}]}\n' "$bk/HIMMEL-7-N57-released-worker-2026-10-01.md" > "$bk/test-console.fleet.json"
rm -f "$out"; render >/dev/null
contains 'a workers-key fleet manifest lists its worker as live' "$(cat "$out" 2>/dev/null)" '"7":["N57","LIVE"'
rm -f "$out"; HIMMEL_LEGACY_NAMES=0 render >/dev/null; wrc=$?
equals 'a workers-key fleet manifest renders with HIMMEL_LEGACY_NAMES=0 (exit status)' "$wrc" 0
contains 'a workers-key fleet manifest still lists its worker with HIMMEL_LEGACY_NAMES=0' "$(cat "$out" 2>/dev/null)" '"7":["N57","LIVE"'
printf '{"schema":1,"legs":[{"doc":"%s","label":"N57"}]}\n' "$bk/HIMMEL-7-N57-released-worker-2026-10-01.md" > "$bk/test-console.fleet.json"
rm -f "$out"; HIMMEL_LEGACY_NAMES=0 render >/dev/null; lrc=$?
equals 'a legs-key fleet manifest renders with HIMMEL_LEGACY_NAMES=0 (exit status)' "$lrc" 0
not_contains 'a legs-key fleet manifest is skipped with HIMMEL_LEGACY_NAMES=0' "$(cat "$out" 2>/dev/null)" '"7":["N57","LIVE"'
rm -f "$bk/test-console.fleet.json"

# --- parity: the hero's per-bucket counts for the version worked on equal a live JQL count.
# The fixture is copied from the real environment on 2026-10-18: four mirror frontmatters, the `jira list` rows for
# fixVersion = "v1.1.3" and the versions snapshot. One ticket is Done in v1.1.4 (moved into v1.1.3 by the page), one
# carries v1.1.0 and v1.1.3, one moved to In Review after the mirror sync, and one is Closed.
pf="$HERE/fixtures/tracker-parity"
printf '#!/bin/sh\nprintf "%%s\\n" "$*" > "%s"\ncat "%s"\n' "$W/jira-args" "$pf/jira-list-v1.1.3.tsv" > "$W/fakejira"
chmod +x "$W/fakejira"
pstdout="$(TRACKER_JIRA="$W/fakejira" render --mirror-dir "$pf/mirror" --versions-file "$pf/mirror.versions.tsv")"
prc=$?
phtml="$(cat "$out" 2>/dev/null)"
contains 'the parity check asks Jira for the version worked on' "$(cat "$W/jira-args" 2>/dev/null)" \
    'list --jql project = HIMMEL AND fixVersion = "v1.1.3"'
pstdout="$(TRACKER_JIRA="$W/fakejira" HOME="$W/s2home" HIMMEL_CONFIG_DIR="$W/s2cfg" JIRA_PROJECT_KEY='' render --mirror-dir "$pf/mirror" --versions-file "$pf/mirror.versions.tsv")"
contains 'the parity JQL names the project a himmel.conf-only key sets' "$(cat "$W/jira-args" 2>/dev/null)" \
    'list --jql project = ACME AND fixVersion = "v1.1.3"'
pstdout="$(TRACKER_JIRA="$W/fakejira" render --mirror-dir "$pf/mirror" --versions-file "$pf/mirror.versions.tsv")"
contains 'a page count that differs from Jira is a parity DRIFT' "$pstdout" \
    'parity: v1.1.3 DRIFT page 2/1/0/0 jira 1/0/1/0 (done/in progress/in review/to do)'
contains 'the hero note carries the parity line' "$phtml" '"PAR":"parity: v1.1.3 DRIFT page 2/1/0/0'
# the same mirror against a Jira that agrees with it: ok.
printf 'HIMMEL-4185\tTask\tDone\tx\nHIMMEL-5860\tTask\tDone\tx\nHIMMEL-6143\tTask\tIn Progress\tx\nHIMMEL-5574\tTask\tClosed\tx\n' > "$W/agree.tsv"
printf '#!/bin/sh\ncat "%s"\n' "$W/agree.tsv" > "$W/agreejira"
chmod +x "$W/agreejira"
pstdout="$(TRACKER_JIRA="$W/agreejira" render --mirror-dir "$pf/mirror" --versions-file "$pf/mirror.versions.tsv")"
contains 'equal counts are parity ok' "$pstdout" 'parity: v1.1.3 ok 2/1/0/0 (done/in progress/in review/to do)'
# a mirror one status behind live is lag, naming the key; a mismatch that is no lag is DRIFT naming both statuses.
printf 'HIMMEL-4185\tTask\tDone\tx\nHIMMEL-5860\tTask\tDone\tx\nHIMMEL-6143\tTask\tIn Review\tx\nHIMMEL-5574\tTask\tClosed\tx\n' > "$W/lag.tsv"
printf '#!/bin/sh\ncat "%s"\n' "$W/lag.tsv" > "$W/lagjira"
chmod +x "$W/lagjira"
pstdout="$(TRACKER_JIRA="$W/lagjira" render --mirror-dir "$pf/mirror" --versions-file "$pf/mirror.versions.tsv")"
contains 'a mirror behind live reads lag and names the key' "$pstdout" 'parity: v1.1.3 lag page 2/1/0/0 jira 2/0/1/0'
contains 'the lag line gives both statuses' "$pstdout" 'HIMMEL-6143 page In Progress jira In Review'
not_contains 'a mirror behind live is not DRIFT' "$pstdout" 'parity: v1.1.3 DRIFT'
printf 'HIMMEL-4185\tTask\tDone\tx\nHIMMEL-5860\tTask\tDone\tx\nHIMMEL-6143\tTask\tTo Do\tx\nHIMMEL-5574\tTask\tClosed\tx\n' > "$W/real.tsv"
printf '#!/bin/sh\ncat "%s"\n' "$W/real.tsv" > "$W/realjira"
chmod +x "$W/realjira"
pstdout="$(TRACKER_JIRA="$W/realjira" render --mirror-dir "$pf/mirror" --versions-file "$pf/mirror.versions.tsv")"
contains 'a page ahead of Jira is DRIFT naming the key and both statuses' "$pstdout" \
    'parity: v1.1.3 DRIFT page 2/1/0/0 jira 2/0/0/1 (done/in progress/in review/to do): HIMMEL-6143 page In Progress jira To Do'
pstdout="$(TRACKER_JIRA="$W/fakejira" render --mirror-dir "$pf/mirror" --versions-file "$pf/mirror.versions.tsv")"
contains 'a key only on the page is DRIFT, a lagging key beside it is listed too' "$pstdout" \
    'HIMMEL-5860 page Done jira (absent), HIMMEL-6143 page In Progress jira In Review'
printf 'HIMMEL-4185\tTask\tDone\tx\nHIMMEL-5860\tTask\tDone\tx\nHIMMEL-6143\tTask\tIn Progress\tx\nHIMMEL-5574\tTask\tClosed\tx\nHIMMEL-9001\tTask\tTo Do\tx\n' > "$W/new.tsv"
printf '#!/bin/sh\ncat "%s"\n' "$W/new.tsv" > "$W/newjira"
chmod +x "$W/newjira"
pstdout="$(TRACKER_JIRA="$W/newjira" render --mirror-dir "$pf/mirror" --versions-file "$pf/mirror.versions.tsv")"
contains 'a ticket live Jira has and the mirror lacks is lag, not DRIFT' "$pstdout" 'HIMMEL-9001 page (absent) jira To Do'
not_contains 'a ticket only in Jira is not DRIFT' "$pstdout" 'parity: v1.1.3 DRIFT'
contains 'the Jira side drops Done tickets resolved as something other than Done or Fixed' \
    "$(cat "$W/jira-args" 2>/dev/null)" 'resolution not in'
# a status the tracker has no bucket for is a garbled answer, never a guessed To Do.
printf 'HIMMEL-4185\tTask\tDone\tx\nHIMMEL-6143\tTask\tSomething New\tx\n' > "$W/odd.tsv"
printf '#!/bin/sh\ncat "%s"\n' "$W/odd.tsv" > "$W/oddjira"
chmod +x "$W/oddjira"
pstdout="$(TRACKER_JIRA="$W/oddjira" render --mirror-dir "$pf/mirror" --versions-file "$pf/mirror.versions.tsv")"
contains 'an unknown Jira status reads parity unavailable' "$pstdout" 'parity: v1.1.3 unavailable'
# a failing CLI never fails the render.
pstdout="$(render --mirror-dir "$pf/mirror" --versions-file "$pf/mirror.versions.tsv")"
prc=$?
if [ "$prc" -eq 0 ]; then pass 'a failing Jira CLI does not fail the render'; else fail "a failing Jira CLI failed the render: rc $prc"; fi
contains 'a failing Jira CLI reads parity unavailable' "$pstdout" 'parity: v1.1.3 unavailable'
# the hero counts the Jira status (t.b), not the live-worker display; the boards keep the display (jb).
contains 'the hero tallies by Jira status, not the live-worker display' "$phtml" 't=jtally(jin(JCUR),1)'
contains 'the up-next line tallies by Jira status' "$phtml" 'var u=jtally(jin(JNXT),1)'
contains 'a board tally keeps the live-worker display' "$phtml" 'r[raw?t.b:jb(t)].push(t)'

# --- the render splits into a focus page (open tickets of the target version), a Done page and a future page.
# v1.1.1 is released, v1.1.3 is the earliest unreleased version, v1.1.4 is later. Tickets 801..805 carry one title each.
splan="$W/splan"
smir="$W/smirror"
cp -R "$plan" "$splan"
mkdir -p "$smir"
printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' version load_bugs load_enhancements load_features load_misc load_audit load_total est_legs \
    v1.1.1 0.1 0 0 0 0 0.1 1 v1.1.3 0.1 0 0 0 0 0.1 1 v1.1.4 0.1 0 0 0 0 0.1 1 > "$splan/stage3/versions.tsv"
printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' key version layer effort_mid commit slice_effort reason \
    HIMMEL-801 v1.1.3 bugs 1 committed '' 'P1' HIMMEL-802 v1.1.3 bugs 1 committed '' 'P1' \
    HIMMEL-803 v1.1.3 bugs 1 committed '' 'P1' HIMMEL-804 v1.1.4 bugs 1 committed '' 'P1' \
    HIMMEL-805 v1.1.1 bugs 1 committed '' 'P1' > "$splan/stage3/placement.tsv"
printf '%s\t%s\t%s\n' key close_flag close_evidence > "$splan/stage3/closures.tsv"
printf '%s\t%s\n' key reason > "$splan/stage3/unplaced.tsv"
mdir="$smir"
mk 801 Done '["v1.1.3"]' 'splitmark done in target' Done Done Tooling
mk 802 'To Do' '["v1.1.3"]' 'splitmark open in target' 'To Do' '' Tooling
mk 803 'In Progress' '["v1.1.3"]' 'splitmark progress in target' 'In Progress' '' Tooling
mk 804 'To Do' '["v1.1.4"]' 'splitmark open in future' 'To Do' '' Tooling
mk 805 Done '["v1.1.1"]' 'splitmark done in released' Done Done Tooling
printf 'v1.1.1\ttrue\t2026-10-01\nv1.1.3\tfalse\t2026-10-22\nv1.1.4\tfalse\t\n' > "$W/split.versions.tsv"
sout="$W/split-focus.html"
sdone="$W/split-done.html"
sfuture="$W/split-future.html"
srender() {
    python3 "$HERE/tracker.py" --plan-dir "$splan" --out "$sout" --out-done "$sdone" --out-future "$sfuture" \
        --luna-map "$W/luna-map.json" --mirror-dir "$smir" --versions-file "$W/split.versions.tsv" --luna-root "$W/luna" \
        --handovers "$W/luna/handovers/tester/himmel" "$@" 2>&1
}
srender --done-url https://example.test/done --future-url https://example.test/future > "$W/split.stdout"
src=$?
if [ "$src" -eq 0 ]; then pass 'a split render exits 0'; else fail "a split render exited $src: $(cat "$W/split.stdout")"; fi
fhtml="$(cat "$sout" 2>/dev/null)"
dhtml="$(cat "$sdone" 2>/dev/null)"
uhtml="$(cat "$sfuture" 2>/dev/null)"
contains 'the focus page holds the open target tickets' "$fhtml" 'splitmark open in target'
contains 'the focus page holds the in-progress target ticket' "$fhtml" 'splitmark progress in target'
not_contains 'the focus page holds no Done ticket of the target' "$fhtml" 'splitmark done in target'
not_contains 'the focus page holds no Done ticket of a released version' "$fhtml" 'splitmark done in released'
not_contains 'the focus page holds no ticket of a later version' "$fhtml" 'splitmark open in future'
contains 'the Done page holds the Done target ticket' "$dhtml" 'splitmark done in target'
contains 'the Done page holds the Done released ticket' "$dhtml" 'splitmark done in released'
not_contains 'the Done page holds no open ticket' "$dhtml" 'splitmark open in target'
not_contains 'the Done page holds no future ticket' "$dhtml" 'splitmark open in future'
contains 'the future page holds the later version ticket' "$uhtml" 'splitmark open in future'
not_contains 'the future page holds no target ticket' "$uhtml" 'splitmark open in target'
not_contains 'the future page holds no Done ticket' "$uhtml" 'splitmark done in target'
# the target defaults to the earliest unreleased version of the versions file; --target-version overrides it.
contains 'the focus page names the target version' "$fhtml" '"PG":"focus"'
srender --target-version v1.1.4 > /dev/null
contains 'an explicit --target-version moves the focus' "$(cat "$sout" 2>/dev/null)" 'splitmark open in future'
not_contains 'an explicit --target-version drops the old focus' "$(cat "$sout" 2>/dev/null)" 'splitmark open in target'
srender --target-version v9.9.9 > "$W/split-badtarget.stdout"
brc=$?
if [ "$brc" -eq 2 ]; then pass 'an unknown --target-version exits 2'; else fail "an unknown --target-version exited $brc"; fi
contains 'an unknown --target-version names the versions file' "$(cat "$W/split-badtarget.stdout")" 'is not in the versions file'
srender > /dev/null
# the focus page links to the other two, and each of those links back to it.
contains 'the focus page links to the Done page' "$fhtml" 'https://example.test/done'
contains 'the focus page links to the future page' "$fhtml" 'https://example.test/future'
# tick reads the freshness of the focus page: its .fp is the --emit-fp value, and no other page carries one.
sfp="$(python3 "$HERE/tracker.py" --emit-fp --plan-dir "$splan" --out "$sout" --luna-map "$W/luna-map.json" --mirror-dir "$smir" \
    --versions-file "$W/split.versions.tsv" --luna-root "$W/luna" --handovers "$W/luna/handovers/tester/himmel" 2>&1)"
if [ -n "$sfp" ] && [ "$(cat "$sout.fp" 2>/dev/null)" = "$sfp" ]; then pass 'the focus page .fp equals --emit-fp'; else fail "focus .fp '$(cat "$sout.fp" 2>/dev/null)' differs from --emit-fp '$sfp'"; fi
if [ ! -e "$sdone.fp" ] && [ ! -e "$sfuture.fp" ]; then pass 'the Done and future pages write no .fp'; else fail 'a Done or future page wrote a .fp'; fi
# without --out-done / --out-future the one page keeps every ticket.
python3 "$HERE/tracker.py" --plan-dir "$splan" --out "$W/split-all.html" --luna-map "$W/luna-map.json" --mirror-dir "$smir" \
    --versions-file "$W/split.versions.tsv" --luna-root "$W/luna" --handovers "$W/luna/handovers/tester/himmel" > "$W/split-all.stdout" 2>&1
arc=$?
[ "$arc" -eq 0 ] || fail "the unsplit render exited $arc: $(cat "$W/split-all.stdout")"
ahtml="$(cat "$W/split-all.html" 2>/dev/null)"
contains 'a render with no split outputs keeps the Done tickets' "$ahtml" 'splitmark done in target'
contains 'a render with no split outputs keeps the future tickets' "$ahtml" 'splitmark open in future'

# --- blocker scan: only a ticket's own dependency line counts, from the description alone.
# bsfile <n> <statusCategory> <status> <title> <blocked_by json> <description lines...>
bs="$W/bs"
mkdir -p "$bs"
bsfile() {
    local n="$1" cat="$2" st="$3" title="$4" blk="$5"
    shift 5
    printf '%s\n' '---' "key: \"HIMMEL-$n\"" "statusCategory: \"$cat\"" "status: \"$st\"" 'fixVersions: ["v1.1.3"]' 'type: "Task"' \
        'links:' '  blocks: []' "  blocked_by: $blk" '---' "# HIMMEL-$n: $title" '' '## Description' '' "$@" '' '## Comments' '' '_(none)_' \
        > "$bs/HIMMEL-$n.md"
}
# 1481 and 6577: the real description sentences that produced false blockers.
bsfile 1481 'To Do' 'To Do' 'real 1481 prose' '[]' \
    'The /cr-tune feed (D3b-3) is HIMMEL-6553, blocked by HIMMEL-6378. The D19 kill-criterion (repair share flat after four weeks) stays an operator judgement and is recorded here, not built.'
bsfile 6577 'To Do' 'To Do' 'real 6577 quoted command' '[]' \
    'Two of our readers disagree on one Blocks link. Link 19697 was created by jira link HIMMEL-6494 --blocked-by HIMMEL-5556. jira links HIMMEL-6494 prints "HIMMEL-6494 is blocked by HIMMEL-5556".'
bsfile 202 'To Do' 'To Do' 'negated mentions' '[]' 'Not blocked by HIMMEL-300.' 'No longer blocked by HIMMEL-301.' 'It was blocked by HIMMEL-302.'
bsfile 203 'To Do' 'To Do' 'odd spacing' '[]' 'Depends  on HIMMEL-303' 'BLOCKED-BY:HIMMEL-304'
bsfile 204 'To Do' 'To Do' 'blocked by HIMMEL-305 in the title' '[]' 'Nothing here.'
bsfile 205 'To Do' 'To Do' 'wont blocker' '[]' 'Blocked by: HIMMEL-306'
bsfile 306 'Done' 'Wont Do' 'closed as wont' '[]' 'x'
bsfile 207 'To Do' 'To Do' 'links line' '[]' 'Links: relates to HIMMEL-310, blocked by HIMMEL-311'
bsfile 209 'To Do' 'To Do' 'bold label' '[]' '**Blocked by:** HIMMEL-314'
bsfile 208 'To Do' 'To Do' 'yaml list' '' 'x'
awk '$0 == "  blocked_by: " { print "  blocked_by:"; print "    - \"HIMMEL-312\""; print "    - \"HIMMEL-313\""; next } { print }' \
    "$bs/HIMMEL-208.md" > "$bs/yaml.tmp" && mv "$bs/yaml.tmp" "$bs/HIMMEL-208.md"
# 6535 and 6538: the link says 6538 blocks 6535, 6538's own text says it starts after 6535.
bsfile 6535 'To Do' 'To Do' 'real 6535 link' '["HIMMEL-6538"]' 'Make stuck work structural.'
bsfile 6538 'To Do' 'To Do' 'real 6538 text' '[]' \
    '- Depends on (merge order, plan §10(b)): for chief-wait.sh the order is PR 3219 (HIMMEL-6478) → HIMMEL-6535 phase B → this → HIMMEL-6461 → slice 3. For waiter.md it is this → HIMMEL-6499 → slice 3. Start after HIMMEL-6478 and HIMMEL-6535 merge.'
bsout="$(python3 "$HERE/tracker.py" --remaining v1.1.3 --mirror-dir "$bs" 2>&1)"$'\n'
contains 'prose about another ticket is no blocker' "$bsout" 'HIMMEL-1481 [To Do] real 1481 prose'$'\n'
contains 'a quoted command is no blocker' "$bsout" 'HIMMEL-6577 [To Do] real 6577 quoted command'$'\n'
contains 'a negated or past-tense mention is no blocker' "$bsout" 'HIMMEL-202 [To Do] negated mentions'$'\n'
contains 'odd spacing and BLOCKED-BY:KEY are read' "$bsout" 'HIMMEL-203 [To Do] odd spacing {blocked-by: HIMMEL-303 open, HIMMEL-304 open}'
contains 'the title is not scanned' "$bsout" 'HIMMEL-204 [To Do] blocked by HIMMEL-305 in the title'$'\n'
contains 'a blocker closed as wont reads wont' "$bsout" 'HIMMEL-205 [To Do] wont blocker {blocked-by: HIMMEL-306 wont}'
contains 'a Links: line names its blocked-by key only' "$bsout" 'HIMMEL-207 [To Do] links line {blocked-by: HIMMEL-311 open}'
contains 'a bold Markdown label with the colon inside is read' "$bsout" 'HIMMEL-209 [To Do] bold label {blocked-by: HIMMEL-314 open}'
contains 'a multi-line blocked_by YAML list is read' "$bsout" 'HIMMEL-208 [To Do] yaml list {blocked-by: HIMMEL-312 open, HIMMEL-313 open}'
contains 'a link the blocker text contradicts reads direction?' "$bsout" 'HIMMEL-6535 [To Do] real 6535 link {blocked-by: HIMMEL-6538 direction?}'

# --- one tracker page per version (--version): the FOCUS design from the Jira mirror.
vp="$W/vp"
mkdir -p "$vp"
mdir="$vp"
mk 400 'To Do' '["v1.1.3"]' 'vp todo in group' 'To Do' '' 'Ship loop'
mk 401 'In Progress' '["v1.1.3"]' 'vp progress with pr' 'In Progress' '' Visibility
mk 402 'In Progress' '["v1.1.3"]' 'vp review no pr' 'In Review'
mk 404 'To Do' '["v1.1.4"]' 'vp next version' 'To Do'
mk 405 Done '["v1.1.3"]' 'vpdone ticket' Done Done
mk 406 Done '["v1.1.3"]' 'vp closed' Closed
mk 407 'To Do' '["v1.1.3"]' 'vp rest' 'To Do'
mk 410 'To Do' '["v1.1.3"]' 'vp direction blocker' 'To Do'
mdir="$mir"
printf '%s\n' '---' 'key: "HIMMEL-403"' 'statusCategory: "In Progress"' 'status: "IN CI"' 'fixVersions: ["v1.1.3"]' 'type: "Task"' \
    'links:' '  blocked_by: ["HIMMEL-404"]' '---' '# HIMMEL-403: vp ci blocked' > "$vp/HIMMEL-403.md"
printf '%s\n' '---' 'key: "HIMMEL-409"' 'statusCategory: "To Do"' 'status: "To Do"' 'fixVersions: ["v1.1.3"]' 'type: "Task"' \
    'links:' '  blocked_by: ["HIMMEL-410"]' '---' '# HIMMEL-409: vp direction card' > "$vp/HIMMEL-409.md"
printf '%s\n' '' '## Description' '' 'Start after HIMMEL-409 merges.' >> "$vp/HIMMEL-410.md"
printf '%s\n' 'priority: 400 | rest of v1.1.3 | 9999' > "$W/vp-plan.md"
cat > "$W/vp-prs.json" <<'EOF'
[{"number":500,"title":"feat: [HIMMEL-401] x","headRefName":"feat/himmel-401-x","headRefOid":"abc1234def5678","isDraft":false,"statusCheckRollup":[{"status":"COMPLETED","conclusion":"SUCCESS"}]},
 {"number":501,"title":"fix: y","headRefName":"fix/himmel-403-y","isDraft":true,"statusCheckRollup":[{"status":"COMPLETED","conclusion":"FAILURE"}]},
 {"number":503,"title":"feat: [HIMMEL-400] z","headRefName":"feat/z","isDraft":false,"statusCheckRollup":[{"status":"COMPLETED","conclusion":"SUCCESS"},{"status":"COMPLETED","conclusion":"ACTION_REQUIRED"}]},
 {"number":504,"title":"feat: [HIMMEL-410] w","headRefName":"feat/w","isDraft":false,"statusCheckRollup":[{"status":"COMPLETED","conclusion":"STARTUP_FAILURE"}]}]
EOF
cat > "$W/vp-chains.json" <<'EOF'
[{"name":"0 — wave one","note":"land first","steps":[{"key":"HIMMEL-405","label":"chain step one","state":"work"},
 {"key":"HIMMEL-400","pr":502,"label":"chain step two","state":"next","owner":"N9"}]}]
EOF
printf 'HIMMEL-400\tTask\tTo Do\tx\nHIMMEL-401\tTask\tIn Progress\tx\nHIMMEL-402\tTask\tIn Review\tx\nHIMMEL-403\tTask\tIN CI\tx\nHIMMEL-407\tTask\tTo Do\tx\nHIMMEL-409\tTask\tTo Do\tx\nHIMMEL-410\tTask\tTo Do\tx\n' > "$W/vp-jira.tsv"
printf '#!/bin/sh\nprintf "%%s\\n" "$*" > "%s"\ncat "%s"\n' "$W/vp-jira-args" "$W/vp-jira.tsv" > "$W/vpjira"
chmod +x "$W/vpjira"
vout="$W/vp-v113.html"
vrender() {
    TRACKER_JIRA="$W/vpjira" python3 "$HERE/tracker.py" --version v1.1.3 --repo example-org/example-repo --mirror-dir "$vp" --priority-file "$W/vp-plan.md" \
        --prs-file "$W/vp-prs.json" --chains-file "$W/vp-chains.json" --jira-base-url https://jira.example.test --out "$vout" 2>&1
}
vstdout="$(vrender)"
vrc=$?
vhtml="$(cat "$vout" 2>/dev/null)"
card() { grep -F "data-key=\"HIMMEL-$1\"" "$vout" 2>/dev/null; }
if [ "$vrc" -eq 0 ]; then pass '--version renders and exits 0'; else fail "--version exited $vrc: $vstdout"; fi
contains 'the page is titled by its version' "$vhtml" '<title>v1.1.3 Tracker</title>'
contains 'the page carries its version and focus fingerprint' "$vhtml" "<meta name=\"himmel-focus\" content=\"v1.1.3 $(cat "$vout.vfp" 2>/dev/null)\">"
contains 'an open ticket of the version is a card' "$vhtml" 'vp todo in group'
not_contains 'a ticket of another version is no card' "$vhtml" 'vp next version'
not_contains 'a Done ticket is no card' "$vhtml" 'vpdone ticket'
not_contains 'a Closed ticket is no card' "$vhtml" 'vp closed'
contains 'a column per status with its count' "$vhtml" 'data-col="To Do"><h2>To Do <span class="n">2</span></h2>'
contains 'the IN CI column counts its card' "$vhtml" 'data-col="IN CI"><h2>IN CI <span class="n">1</span></h2>'
contains 'the header counts the Done tickets of the version' "$vhtml" '1 Done'
contains 'a column that matches Jira carries an ok parity line' "$vhtml" '<div class="parity ok">Jira 1 · ok</div>'
contains 'stdout prints the per-column parity of each card under its Jira column' "$vstdout" 'parity v1.1.3: To Do 4/4 ok, In Progress 1/1 ok, In Review 1/1 ok, IN CI 1/1 ok'
not_contains 'a card its PR CI moved off its Jira column is no parity DRIFT' "$vhtml" 'parity drift'
contains 'a CI-moved card keeps its CI column and its Jira note' "$(card 401)" 'Jira In Progress, PR CI says IN CI'
contains 'parity asks Jira for the open tickets of the version' "$(cat "$W/vp-jira-args" 2>/dev/null)" \
    'project = HIMMEL AND fixVersion = "v1.1.3" AND statusCategory != Done'
HOME="$W/s2home" HIMMEL_CONFIG_DIR="$W/s2cfg" JIRA_PROJECT_KEY='' vrender >/dev/null
contains 'the column parity JQL names the project a himmel.conf-only key sets' "$(cat "$W/vp-jira-args" 2>/dev/null)" \
    'project = ACME AND fixVersion = "v1.1.3" AND statusCategory != Done'
contains 'a card sits in its plan priority block' "$(card 400)" 'data-block="0 critical"'
contains 'a card on no priority line sits in rest of version' "$(card 407)" 'data-block="rest of version"'
contains 'a sector chip renders in the sector colour' "$(card 400)" '<span class="sec" style="--s:#16a34a">Ship loop</span>'
contains 'a card with no sector says so' "$(card 402)" 'no sector'
contains 'an open PR badge carries its CI state' "$(card 401)" 'href="https://github.com/example-org/example-repo/pull/500">#500 · CI green</a>'
contains 'a PR found by its branch name, red and draft' "$(card 403)" '#501 · CI red · draft'
contains 'a check that needs action is not green' "$(card 400)" '#503 · CI red'
contains 'a check that failed to start is not green' "$(card 410)" '#504 · CI red'
contains 'a started card with no open PR is flagged' "$(card 402)" 'no open PR'
not_contains 'a To Do card with no PR is not flagged' "$(card 407)" 'no open PR'
contains 'a card with an open blocker is flagged' "$(card 403)" 'BLOCKED by open HIMMEL-404'
contains 'a contradicted link reads direction?, not BLOCKED' "$(card 409)" 'direction? HIMMEL-410'
not_contains 'a contradicted link does not hold the card' "$(card 409)" 'BLOCKED'
contains 'the card key links to Jira' "$(card 400)" 'href="https://jira.example.test/browse/HIMMEL-400"'
contains 'a chain step renders its ticket title' "$vhtml" '<li class="st-next"><b>next</b> <a href="https://jira.example.test/browse/HIMMEL-400">HIMMEL-400</a> vp todo in group'
not_contains 'a chain step whose ticket is Done is not listed' "$vhtml" 'browse/HIMMEL-405'
contains 'a chain card carries its FAST-TRACK badge' "$(card 400)" 'FAST-TRACK · 0 — wave one · step 1'
not_contains 'a page with no drain row has no drain line' "$vhtml" 'class="drain"'
# the drain row is the last element of focus-chains.json; the chain rows around it render as before
python3 -I -c 'import json, sys
rows = json.load(open(sys.argv[1]))
rows.append({"drain": "v1.1.3 drain: open 7 · in-chain 3 · standalone 1 · unchained 3 HIMMEL-1 HIMMEL-2 HIMMEL-3"})
json.dump(rows, open(sys.argv[2], "w"))' "$W/vp-chains.json" "$W/vp-chains-drain.json"
vdrain="$W/vp-drain.html"
TRACKER_JIRA="$W/vpjira" python3 "$HERE/tracker.py" --version v1.1.3 --repo example-org/example-repo --mirror-dir "$vp" --priority-file "$W/vp-plan.md" \
    --prs-file "$W/vp-prs.json" --chains-file "$W/vp-chains-drain.json" --jira-base-url https://jira.example.test --out "$vdrain" >/dev/null 2>&1
vdhtml="$(cat "$vdrain" 2>/dev/null)"
contains 'the drain line prints under the title' "$vdhtml" '<h1>v1.1.3 tracker</h1>
<div class="drain">v1.1.3 drain: open 7 · in-chain 3 · standalone 1 · unchained 3 HIMMEL-1 HIMMEL-2 HIMMEL-3</div>'
contains 'a drain row leaves the chain steps as they were' "$vdhtml" 'FAST-TRACK · 0 — wave one · step 1'
if [ "$(cat "$vdrain.vfp")" != "$(cat "$vout.vfp")" ]; then pass 'the drain line moves the focus fingerprint'; else fail 'the drain line left the focus fingerprint unchanged'; fi
if [ ! -e "$vout.fp" ]; then pass 'a --version page without --plan-dir writes no .fp'; else fail 'a --version page without --plan-dir wrote a .fp'; fi
# a column that differs from Jira reads DRIFT and names the key.
printf 'HIMMEL-400\tTask\tTo Do\tx\nHIMMEL-401\tTask\tIn Progress\tx\nHIMMEL-402\tTask\tIn Progress\tx\nHIMMEL-403\tTask\tIN CI\tx\nHIMMEL-407\tTask\tTo Do\tx\nHIMMEL-409\tTask\tTo Do\tx\nHIMMEL-410\tTask\tTo Do\tx\nHIMMEL-411\tTask\tBlocked\tx\n' > "$W/vp-jira.tsv"
vstdout="$(vrender)"
contains 'a column Jira counts differently reads DRIFT' "$vstdout" 'In Progress 1/2 DRIFT, In Review 1/0 DRIFT'
contains 'the DRIFT line names the key and its Jira status' "$(cat "$vout")" 'HIMMEL-402 Jira In Progress'
contains 'a status only Jira holds gets a DRIFT column on the page' "$(cat "$vout")" \
    'data-col="Blocked"><h2>Blocked <span class="n">0</span></h2><div class="parity drift">Jira 1 · DRIFT: HIMMEL-411 page (absent)'
contains 'stdout counts the Jira-only status as DRIFT' "$vstdout" 'Blocked 0/1 DRIFT'
# a failing Jira CLI or gh reads unavailable, never a failed render or a false flag.
printf '#!/bin/sh\nexit 1\n' > "$W/vpnogh"
chmod +x "$W/vpnogh"
vstdout="$(TRACKER_GH="$W/vpnogh" TRACKER_JIRA="$W/nojira" python3 "$HERE/tracker.py" --version v1.1.3 --repo example-org/example-repo --mirror-dir "$vp" --out "$vout" 2>&1)"
vrc=$?
if [ "$vrc" -eq 0 ]; then pass 'no Jira and no gh still render'; else fail "no Jira and no gh exited $vrc: $vstdout"; fi
contains 'a failed parity read says unavailable' "$vstdout" 'parity v1.1.3: unavailable'
contains 'a failed gh read says PR state unavailable' "$(cat "$vout")" 'PR state unavailable'
not_contains 'a failed gh read flags no card as PR-less' "$(cat "$vout")" 'no open PR'
# a later version gets its own page.
TRACKER_GH="$W/vpnogh" python3 "$HERE/tracker.py" --version v1.1.4 --repo example-org/example-repo --mirror-dir "$vp" --chains-file "$W/vp-chains.json" --out "$W/vp-v114.html" >/dev/null 2>&1
contains 'the v1.1.4 page holds its own ticket' "$(cat "$W/vp-v114.html" 2>/dev/null)" 'vp next version'
not_contains 'the v1.1.4 page holds no v1.1.3 ticket' "$(cat "$W/vp-v114.html" 2>/dev/null)" 'vp todo in group'
not_contains 'the v1.1.4 page holds no chain of another version' "$(cat "$W/vp-v114.html" 2>/dev/null)" 'chain step two'
# a missing mirror fails instead of writing an empty page.
if TRACKER_GH="$W/vpnogh" python3 "$HERE/tracker.py" --version v1.1.3 --repo example-org/example-repo --mirror-dir "$W/no-such-mirror" --out "$W/vp-missing.html" >/dev/null 2>&1; then
    fail 'a missing mirror fails the --version render'
else
    pass 'a missing mirror fails the --version render'
fi
# with --plan-dir the page carries the tick fingerprint, so tick reads tracker=ok from it.
vfout="$W/vfp/roadmap-tracker.html"
TRACKER_GH="$W/vpnogh" python3 "$HERE/tracker.py" --version v1.1.3 --repo example-org/example-repo --mirror-dir "$vp" --out "$vfout" --plan-dir "$plan" \
    --luna-root "$W/luna" --handovers "$W/luna/handovers/tester/himmel" >/dev/null 2>&1
vfp="$(python3 "$HERE/tracker.py" --emit-fp --plan-dir "$plan" --out "$vfout" --luna-map "$W/luna-map.json" --mirror-dir "$vp" \
    --luna-root "$W/luna" --handovers "$W/luna/handovers/tester/himmel" 2>&1)"
if [ -n "$vfp" ] && [ "$(cat "$vfout.fp" 2>/dev/null)" = "$vfp" ]; then pass 'the --version page .fp equals --emit-fp'; else fail "--version .fp '$(cat "$vfout.fp" 2>/dev/null)' differs from --emit-fp '$vfp'"; fi

S8_READTOK=ghp_READTOKEN0123456789
mkdir -p "$W/s8root" "$W/s8emptyroot" "$W/s8tt" "$W/s8bin"
printf 'himmel_github_token_vm2=%s\n' "$S8_READTOK" > "$W/s8root/.env"
: > "$W/s8emptyroot/.env"
ln -s "$HERE/fixtures/gh-two-token-stub.sh" "$W/s8tt/gh"
S8LOG="$W/s8.log"
# shellcheck disable=SC2016  # the stub body is written literally; its variables expand when the stub runs
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "${GH_READ_QUIET:-unset}" > "%s"\ncat "%s"\n' "$W/s8quiet" "$W/vp-prs.json" > "$W/s8bin/gh-prs"
chmod +x "$W/s8bin/gh-prs"
S8ENV=(env -u TRACKER_GH -u GH_TOKEN -u GITHUB_TOKEN -u himmel_github_token_vm2 -u CREDENTIALS_DIRECTORY -u GH_READ_NO_MAIN_FALLBACK
    GH_READ_ENV_ROOT="$W/s8root" PATH="$W/s8tt:$PATH" GH_STUB_READ_TOKEN="$S8_READTOK" GHLOG="$S8LOG" HIMMEL_SECRETS_KEYRING=off
    GH_STUB_DELEGATE="$W/s8bin/gh-prs" TRACKER_JIRA="$W/vpjira")
s8render() {
    local o="$1"; shift
    "${S8ENV[@]}" GH_STUB_MAINFAIL=rate "$@" python3 "$HERE/tracker.py" --version v1.1.3 --repo example-org/example-repo --mirror-dir "$vp" \
        --priority-file "$W/vp-plan.md" --chains-file "$W/vp-chains.json" --jira-base-url https://jira.example.test --out "$o" 2>&1
}
: > "$S8LOG"
s8render "$W/s8-a.html" >/dev/null
contains 'S8b the fallback list fills the cards under a spent main token' "$(cat "$W/s8-a.html" 2>/dev/null)" 'href="https://github.com/example-org/example-repo/pull/500">#500 · CI green</a>'
not_contains 'S8b the fallback list is not reported unavailable' "$(cat "$W/s8-a.html" 2>/dev/null)" 'PR state unavailable'
equals 'S8b the fallback list read rides the read token' "$(grep -c -E '^tok=read argv=pr list ' "$S8LOG" || true)" 1
equals 'S8b the fallback list read never rides the main token' "$(grep -c -E '^tok=main' "$S8LOG" || true)" 0
equals 'S8b the gh child runs with GH_READ_QUIET=1' "$(cat "$W/s8quiet" 2>/dev/null)" 1
: > "$S8LOG"
s8render "$W/s8-c.html" TRACKER_GH="$W/vpnogh" >/dev/null
contains 'S8b control: TRACKER_GH set still wins over the helper' "$(cat "$W/s8-c.html" 2>/dev/null)" 'PR state unavailable'
equals 'S8b control: TRACKER_GH set leaves the two-token stub uncalled' "$(wc -l < "$S8LOG" | tr -d ' ')" 0
rm -f "$W/s8quiet"
s8render "$W/s8-q.html" TRACKER_GH="$W/s8bin/gh-prs" >/dev/null
equals 'S8b control: TRACKER_GH set runs its gh child with GH_READ_QUIET=1' "$(cat "$W/s8quiet" 2>/dev/null)" 1
contains 'S8b control: TRACKER_GH set still fills the cards' "$(cat "$W/s8-q.html" 2>/dev/null)" '#500 · CI green'
mkdir -p "$W/s8 sp/scripts/handover/chief-kit" "$W/s8 sp/scripts/lib"
cp "$HERE/tracker.py" "$W/s8 sp/scripts/handover/chief-kit/tracker.py"
cp "$HERE/../../lib/gh-read.sh" "$HERE/../../lib/timeout-bin.sh" "$HERE/../../lib/env_alias.py" "$HERE/../../lib/load-dotenv.sh" "$HERE/../../lib/jira-project.sh" "$W/s8 sp/scripts/lib/"
: > "$S8LOG"
"${S8ENV[@]}" GH_STUB_MAINFAIL=rate python3 "$W/s8 sp/scripts/handover/chief-kit/tracker.py" --version v1.1.3 --repo example-org/example-repo --mirror-dir "$vp" \
    --priority-file "$W/vp-plan.md" --chains-file "$W/vp-chains.json" --jira-base-url https://jira.example.test --out "$W/s8-sp.html" >/dev/null 2>&1
contains 'S8b a checkout path with a space still runs the default helper' "$(cat "$W/s8-sp.html" 2>/dev/null)" '#500 · CI green'
equals 'S8b the spaced-path run rides the read token' "$(grep -c -E '^tok=read argv=pr list ' "$S8LOG" || true)" 1
: > "$S8LOG"
s8render "$W/s8-e.html" GH_READ_ENV_ROOT="$W/s8emptyroot" GH_STUB_MAINFAIL= >/dev/null
contains 'S8b control, no read token: the cards still fill' "$(cat "$W/s8-e.html" 2>/dev/null)" '#500 · CI green'
equals 'S8b control, no read token: the fallback list read logs tok=main' "$(grep -c -E '^tok=main argv=pr list ' "$S8LOG" || true)" 1
equals 'S8b control, no read token: no read rides the read token' "$(grep -c -E '^tok=read' "$S8LOG" || true)" 0
# --- the held chain step, the worker card and the focus fingerprint.
printf '%s\n' '---' 'key: "HIMMEL-420"' 'statusCategory: "To Do"' 'status: "To Do"' 'fixVersions: ["v1.1.3"]' 'labels: ["held"]' 'type: "Task"' \
    '---' '# HIMMEL-420: vp held ticket' > "$vp/HIMMEL-420.md"
cat > "$W/vp-chains2.json" <<'EOF'
[{"name":"w2","steps":[{"key":"HIMMEL-420","label":"held step","state":"work"},
 {"key":"HIMMEL-401","label":"prog step","state":"next"},
 {"key":"HIMMEL-400","label":"todo step","state":"work"},
 {"key":"HIMMEL-3","label":"missing step","state":"work"},
 {"key":"HIMMEL-405","label":"done step","state":"next"},
 {"label":"keyless step","state":"work"}]}]
EOF
wk="$W/wk"
mkdir -p "$wk"
ago="$(python3 -c 'import datetime as d; print((d.datetime.now(d.timezone.utc) - d.timedelta(minutes=5)).strftime("%Y-%m-%dT%H:%M:%SZ"))')"
printf '{"key":"HIMMEL-401","leg":"N3096","state":"live","last_event_ts":"%s","prs":{"500":{"head":"abc1234def5678","ci":"red","red_latch":true,"open":true},"499":{"head":"old","ci":"green","open":false}}}\n' "$ago" > "$wk/HIMMEL-401.json"
printf '{"key":"HIMMEL-400","leg":"N2","state":"wrapped","prs":{}}\n' > "$wk/HIMMEL-400.json"
printf '{bad json\n' > "$wk/HIMMEL-402.json"
v2out="$W/vp-v2.html"
v2render() {
    TRACKER_JIRA="$W/vpjira" python3 "$HERE/tracker.py" --version v1.1.3 --repo example-org/example-repo --mirror-dir "$vp" \
        --priority-file "${V2PLAN:-$W/vp-plan.md}" --prs-file "${V2PRS:-$W/vp-prs.json}" --chains-file "${V2CH:-$W/vp-chains2.json}" \
        --workers-dir "$wk" --jira-base-url https://jira.example.test --out "$v2out" 2>&1
}
v2stdout="$(v2render)"
v2rc=$?
if [ "$v2rc" -eq 0 ]; then pass '--workers-dir renders and exits 0'; else fail "--workers-dir exited $v2rc: $v2stdout"; fi
step() { grep -F "$1" "$v2out" 2>/dev/null | grep -F '<li'; }
wcard() { grep -F "data-key=\"HIMMEL-$1\"" "$v2out" 2>/dev/null; }
contains 'a held keyed step reads held, not its hand-written state' "$(step 'vp held ticket')" '<li class="st-held"><b>held</b>'
contains 'an In Progress keyed step reads work, not its hand-written next' "$(step 'vp progress with pr')" '<li class="st-work"><b>work</b>'
contains 'a To Do keyed step reads next, not its hand-written work' "$(step 'vp todo in group')" '<li class="st-next"><b>next</b>'
contains 'a keyed step missing from the mirror reads unknown' "$(step 'not in the Jira mirror')" '<li class="st-unknown"><b>unknown</b>'
not_contains 'a Done keyed step is not listed' "$(cat "$v2out")" 'HIMMEL-405'
contains 'a keyless step keeps its hand-written state' "$(step 'keyless step')" '<li class="st-work"><b>work</b>'
contains 'a worker line shows the worker, state, open PR, head, CI and age' "$(wcard 401)" 'worker N3096 · live · #500 @abc1234 · CI red · 5 min'
not_contains 'a closed PR of the record is not on the worker line' "$(wcard 401)" '#499'
contains 'a wrapped worker with no PR shows its state only' "$(wcard 400)" 'worker N2 · wrapped'
not_contains 'a card with no record has no worker line' "$(wcard 407)" 'worker'
not_contains 'an unreadable record adds no worker line' "$(wcard 402)" 'worker'
# the fingerprint baseline: a record with no CI, so the gh rollup places the card.
printf '{"key":"HIMMEL-401","leg":"N3096","state":"live","prs":{"500":{"head":"abc1234def5678","open":true}}}\n' > "$wk/HIMMEL-401.json"
v2render >/dev/null
vfp1="$(cat "$v2out.vfp" 2>/dev/null)"
case "$vfp1" in
    [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]) pass 'a --version page writes a 16-hex focus fingerprint' ;;
    *) fail "the focus fingerprint is '$vfp1'" ;;
esac
vfp_is() {
    local now=differ
    [ "$(cat "$v2out.vfp" 2>/dev/null)" != "$vfp1" ] || now=same
    if [ "$1" = "$now" ]; then pass "$2"; else fail "$2"; fi
}
sed 's/"conclusion":"SUCCESS"/"conclusion":"FAILURE"/' "$W/vp-prs.json" > "$W/vp-prs-red.json"
V2PRS="$W/vp-prs-red.json" v2render >/dev/null
vfp_is differ 'a CI change that moves a card to another column moves the focus fingerprint'
printf '{"key":"HIMMEL-401","leg":"N3096","state":"live","last_event_ts":"2026-01-01T00:00:00Z","prs":{"500":{"head":"abc1234def5678","ci":"green","red_latch":false,"open":true}}}\n' > "$wk/HIMMEL-401.json"
v2render >/dev/null
vfp_is same 'a worker CI or age change leaves the focus fingerprint alone'
printf '{"key":"HIMMEL-401","leg":"N3096","state":"idle","last_event_ts":"2026-01-01T00:00:00Z","prs":{"500":{"head":"abc1234def5678","ci":"green","open":true}}}\n' > "$wk/HIMMEL-401.json"
v2render >/dev/null
vfp_is differ 'a worker state change moves the focus fingerprint'
printf '{"key":"HIMMEL-401","leg":"N3096","state":"live","prs":{"500":{"head":"fff9999aaa","open":true}}}\n' > "$wk/HIMMEL-401.json"
v2render >/dev/null
vfp_is differ 'a worker PR head change moves the focus fingerprint'
printf '{"key":"HIMMEL-401","leg":"N7","state":"live","prs":{"500":{"head":"abc1234def5678","open":true}}}\n' > "$wk/HIMMEL-401.json"
v2render >/dev/null
vfp_is differ 'a worker owner change moves the focus fingerprint'
printf '{"key":"HIMMEL-401","leg":"N3096","state":"live","prs":{"500":{"head":"abc1234def5678","open":true}}}\n' > "$wk/HIMMEL-401.json"
v2render >/dev/null
vfp_is same 'the original worker record restores the focus fingerprint'
sed 's/keyless step/keyless step two/' "$W/vp-chains2.json" > "$W/vp-chains3.json"
V2CH="$W/vp-chains3.json" v2render >/dev/null
vfp_is differ 'a chain change moves the focus fingerprint'
cp "$vp/HIMMEL-420.md" "$W/h420-keep.md"
sed 's/^type: "Task"/sector: "Elsewhere"\n&/' "$W/h420-keep.md" > "$vp/HIMMEL-420.md"
v2render >/dev/null
vfp_is differ 'a sector change moves the focus fingerprint'
cp "$W/h420-keep.md" "$vp/HIMMEL-420.md"
printf '%s\n' '---' 'key: "HIMMEL-421"' 'statusCategory: "Done"' 'status: "Done"' 'fixVersions: ["v1.1.3"]' 'type: "Task"' '---' '# HIMMEL-421: vp finished ticket' > "$vp/HIMMEL-421.md"
v2render >/dev/null
vfp_is differ 'a new Done ticket of the version moves the focus fingerprint'
rm -f "$vp/HIMMEL-421.md"
v2render >/dev/null
vfp_is same 'restoring the mirror restores the focus fingerprint'
jq '. + [{"number":505,"title":"feat: [HIMMEL-401] more","headRefName":"feat/more","isDraft":false,"statusCheckRollup":[]}]' "$W/vp-prs.json" > "$W/vp-prs-more.json"
V2PRS="$W/vp-prs-more.json" v2render >/dev/null
vfp_is differ 'a new open PR moves the focus fingerprint'
jq '.[0].isDraft = true' "$W/vp-prs.json" > "$W/vp-prs-draft.json"
V2PRS="$W/vp-prs-draft.json" v2render >/dev/null
vfp_is differ 'a draft flip moves the focus fingerprint'
v2render >/dev/null
vfp_is same 'the original PR snapshot restores the focus fingerprint'
printf '%s\n' 'priority: 407 | rest of v1.1.3 | 9999' > "$W/vp-plan2.md"
V2PLAN="$W/vp-plan2.md" v2render >/dev/null
vfp_is differ 'a priority change moves the focus fingerprint'
sed 's/labels: \["held"\]/labels: []/' "$vp/HIMMEL-420.md" > "$W/h420.md" && cp "$W/h420.md" "$vp/HIMMEL-420.md"
v2render >/dev/null
vfp_is differ 'releasing a hold moves the focus fingerprint'

# --- open work only, columns follow the PR's CI.
cat > "$W/vp-chains4.json" <<'EOF'
[{"name":"w4","steps":[{"key":"HIMMEL-405","label":"merged step"},{"key":"HIMMEL-401","label":"open step"}]},
 {"name":"w4done","steps":[{"key":"HIMMEL-405","label":"all merged step"}]}]
EOF
v4out="$W/vp-v4.html"
v2out="$v4out" V2CH="$W/vp-chains4.json" v2render >/dev/null
v4="$(cat "$v4out" 2>/dev/null)"
colof() {
    python3 -I -c 'import re,sys; t=open(sys.argv[1]).read(); i=t.find("data-key=\"HIMMEL-%s\"" % sys.argv[2]); m=re.findall(r"data-col=\"([^\"]*)\"", t[:i]); print(m[-1] if m and i >= 0 else "")' "$v4out" "$1"
}
not_contains 'a merged chain step is not listed' "$v4" 'browse/HIMMEL-405'
not_contains 'a chain whose steps all merged is not listed' "$v4" 'w4done'
contains 'an unmerged chain step is still listed' "$v4" 'browse/HIMMEL-401">HIMMEL-401</a> vp progress with pr'
contains 'the header counts the hidden merged chain steps' "$v4" '2 merged chain steps hidden'
equals 'a To Do card whose PR CI is red sits in In Progress' "$(colof 400)" 'In Progress'
equals 'an In Progress card whose PR CI is green sits in IN CI' "$(colof 401)" 'IN CI'
equals 'an In Review card with no PR stays in In Review' "$(colof 402)" 'In Review'
equals 'an IN CI card whose PR CI is red sits in In Progress' "$(colof 403)" 'In Progress'
equals 'a To Do card with no PR stays in To Do' "$(colof 407)" 'To Do'
contains 'a card whose column differs from Jira names its Jira status' "$(grep -F 'data-key="'"$KP"'-400"' "$v4out")" 'Jira To Do'
not_contains 'a card whose column matches Jira has no Jira note' "$(grep -F 'data-key="'"$KP"'-402"' "$v4out")" 'Jira In Review'
jq '. + [{"number":506,"title":"feat: [HIMMEL-407] mixed","headRefName":"feat/mixed","isDraft":false,"statusCheckRollup":[{"status":"COMPLETED","conclusion":"FAILURE"},{"status":"IN_PROGRESS","conclusion":""}]}]' "$W/vp-prs.json" > "$W/vp-prs-mixed.json"
V2PRS="$W/vp-prs-mixed.json" v2out="$v4out" V2CH="$W/vp-chains4.json" v2render >/dev/null
equals 'a PR with a failed and a running check puts its card in In Progress' "$(colof 407)" 'In Progress'
# the worker record's required-check CI places a card, as its Jira status does: a red latch over a running rollup is red.
jq '.[0].statusCheckRollup = [{"status":"IN_PROGRESS","conclusion":""}]' "$W/vp-prs.json" > "$W/vp-prs-run.json"
printf '{"key":"HIMMEL-401","leg":"N3096","state":"live","prs":{"500":{"head":"abc1234def5678","ci":"pending","red_latch":true,"open":true}}}\n' > "$wk/HIMMEL-401.json"
V2PRS="$W/vp-prs-run.json" v2out="$v4out" V2CH="$W/vp-chains4.json" v2render >/dev/null
equals 'a red-latched worker PR puts its card in In Progress over a running rollup' "$(colof 401)" 'In Progress'
contains 'the card badge reads the worker record CI' "$(grep -F 'data-key="'"$KP"'-401"' "$v4out")" '#500 · CI red'
printf '{"key":"HIMMEL-401","leg":"N3096","state":"live","prs":{"500":{"head":"abc1234def5678","ci":"pending","red_latch":false,"open":true}}}\n' > "$wk/HIMMEL-401.json"
v2out="$v4out" V2CH="$W/vp-chains4.json" v2render >/dev/null
contains 'a pending worker PR reads running over a green rollup' "$(grep -F 'data-key="'"$KP"'-401"' "$v4out")" '#500 · CI running'
printf '{"key":"HIMMEL-401","leg":"N3096","state":"live","prs":{"500":{"head":"0ld0ld0ld","ci":"pending","red_latch":true,"open":true}}}\n' > "$wk/HIMMEL-401.json"
V2PRS="$W/vp-prs-run.json" v2out="$v4out" V2CH="$W/vp-chains4.json" v2render >/dev/null
contains 'a worker record at an older head keeps the rollup CI' "$(grep -F 'data-key="'"$KP"'-401"' "$v4out")" '#500 · CI running'

# --- a chain row is its ticket's live state, never the hand-kept label.
printf '%s\n' '---' 'key: "HIMMEL-430"' 'updated: "2026-09-30T10:00:00.000+0000"' 'statusCategory: "In Progress"' 'status: "In Progress"' 'fixVersions: ["v1.1.3"]' 'type: "Task"' \
    '---' '# HIMMEL-430: rowlive stale pr' > "$vp/HIMMEL-430.md"
printf '%s\n' '---' 'key: "HIMMEL-431"' 'updated: "2026-09-30T10:00:00.000+0000"' 'statusCategory: "To Do"' 'status: "To Do"' 'fixVersions: ["v1.1.3"]' 'labels: ["operator-decision"]' 'type: "Task"' \
    '---' '# HIMMEL-431: rowlive operator ask' > "$vp/HIMMEL-431.md"
printf '%s\n' '---' 'key: "HIMMEL-432"' 'updated: "2026-09-30T10:00:00.000+0000"' 'statusCategory: "In Progress"' 'status: "In Progress"' 'fixVersions: ["v1.1.3"]' 'type: "Task"' \
    '---' '# HIMMEL-432: rowlive open pr' > "$vp/HIMMEL-432.md"
cat > "$W/vp-chains7.json" <<'EOF'
[{"name":"c7621","note":"hand note PR #1 in CI","steps":[{"key":"HIMMEL-430","label":"docs mockup: PR #777 in CI (decision 160)","state":"work","pr":777,"owner":"N3509"},
 {"key":"HIMMEL-432","label":"hand label two","owner":"N1"}]},
 {"name":"1 — Waiting on you (operator)","note":"Nothing else is blocked on the operator.","steps":[{"key":"HIMMEL-431","label":"nobody waits"}]}]
EOF
cat > "$W/vp-prs7.json" <<'EOF'
[{"number":600,"title":"feat: [HIMMEL-432] live","headRefName":"feat/l","headRefOid":"fed1234beef","isDraft":false,"statusCheckRollup":[{"status":"COMPLETED","conclusion":"SUCCESS"}]}]
EOF
mkdir -p "$W/wk7"
printf '{"key":"HIMMEL-432","leg":"N77","state":"live","prs":{"600":{"head":"fed1234beef","open":true}}}\n' > "$W/wk7/HIMMEL-432.json"
v7out="$W/vp-v7.html"
v7render() {
    local o
    o="$(TRACKER_JIRA="$W/vpjira" python3 "$HERE/tracker.py" --version v1.1.3 --repo example-org/example-repo --mirror-dir "$vp" \
        --prs-file "${V7PRS:-$W/vp-prs7.json}" --chains-file "$W/vp-chains7.json" --workers-dir "$W/wk7" --jira-base-url https://jira.example.test --out "$v7out" 2>&1)" \
        || fail "a chain-row render failed, so the rows after it read a stale page: $o" >&2
}
TZ=UTC touch -t 202609010000 "$W/vp-chains7.json"  # -t, not GNU -d: BSD touch (macOS) cannot read '… UTC'
v7render >/dev/null
v7="$(cat "$v7out" 2>/dev/null)"
li() { grep -F "$1" "$v7out" 2>/dev/null | grep -F '<li' ; }
not_contains 'a chain row does not print the hand label' "$v7" 'in CI (decision 160)'
not_contains 'a chain row whose PR is merged does not render in CI' "$(li 'rowlive stale pr')" 'in CI'
contains 'a chain row with no open PR says so and names the Jira status' "$(li 'rowlive stale pr')" 'Jira In Progress · no open PR'
contains 'a chain row shows its ticket title' "$(li 'rowlive open pr')" 'rowlive open pr'
contains 'a chain row shows its open PR and CI' "$(li 'rowlive open pr')" '#600 · CI green'
contains 'a chain row shows the owning worker from the fleet record' "$(li 'rowlive open pr')" 'worker N77 · live'
not_contains 'a chain row does not print the hand owner' "$v7" 'N3509'
not_contains 'a chain note is not printed' "$v7" 'hand note PR #1'
contains 'Waiting on you lists a ticket carrying an operator label' "$(grep -F 'data-section="waiting"' "$v7out")" 'rowlive operator ask'
not_contains 'the hand-kept Waiting on you chain is not printed' "$v7" 'Nothing else is blocked on the operator'
contains 'the header names the age of an out-of-date focus-chains.json' "$v7" 'focus-chains.json last written 2026-09-01 00:00 UTC, older than the newest Jira update'
touch "$W/vp-chains7.json"
v7render >/dev/null
not_contains 'a focus-chains.json newer than the Jira mirror adds no age note' "$(cat "$v7out")" 'focus-chains.json last written'
# --- a hand-kept chain step closed without shipping is wont, never next
mdir="$vp"
mk 433 Done '["v1.1.3"]' 'wontstep resolved wont do' Done "Won't Do"
mdir="$mir"
cat > "$W/vp-chains8.json" <<'EOF'
[{"name":"c7744","steps":[{"key":"HIMMEL-406","label":"closed step"},{"key":"HIMMEL-433","label":"done as wont do"},{"key":"HIMMEL-432","label":"open step"}]}]
EOF
TRACKER_JIRA="$W/vpjira" python3 "$HERE/tracker.py" --version v1.1.3 --repo example-org/example-repo --mirror-dir "$vp" \
    --prs-file "$W/vp-prs7.json" --chains-file "$W/vp-chains8.json" --workers-dir "$W/wk7" --jira-base-url https://jira.example.test --out "$W/vp-v8.html" >/dev/null 2>&1
li8() { grep -F "$1" "$W/vp-v8.html" 2>/dev/null | grep -F '<li' ; }
contains 'a Closed chain step is wont' "$(li8 "$KP-406")" 'class="st-wont"'
not_contains 'a Closed chain step is never next' "$(li8 "$KP-406")" 'st-next'
contains 'a Done chain step resolved Wont Do is wont' "$(li8 "$KP-433")" 'class="st-wont"'
not_contains 'a Done chain step resolved Wont Do is never next' "$(li8 "$KP-433")" 'st-next'
contains 'an open chain step beside them is still shown, as work' "$(li8 "$KP-432")" 'class="st-work"'
printf '{"key":"HIMMEL-432","leg":"N77","state":"live","prs":{"600":{"head":"fed1234beef","open":true},"650":{"head":"dead650beef","ci":"green","open":true}}}\n' > "$W/wk7/HIMMEL-432.json"
v7render >/dev/null
not_contains 'a worker-record PR the open-PR snapshot does not list is not shown on a chain row' "$(li 'rowlive open pr')" '#650'
contains 'a worker-record PR the open-PR snapshot lists stays on the chain row' "$(li 'rowlive open pr')" 'worker N77 · live · #600 @fed1234'
printf '{"key":"HIMMEL-432","leg":"N77","state":"live","prs":{"600":{"head":"fed1234beef","open":true}}}\n' > "$W/wk7/HIMMEL-432.json"
contains 'the documented render command passes the worker records dir' "$(grep -F 'tracker.py" --version' "$HERE/../../../docs/handover/chief-sections/board-tracker.md")" '--workers-dir'
printf '%s\n' '---' 'key: "HIMMEL-433"' 'updated: "2026-09-30T10:00:00.000+0000"' 'statusCategory: "To Do"' 'status: "To Do"' 'fixVersions: ["v1.1.4"]' 'type: "Task"' \
    '---' '# HIMMEL-433: rowlive other version' > "$vp/HIMMEL-433.md"
cat > "$W/vp-chains7.json" <<'EOF'
[{"name":"c7621","steps":[{"key":"HIMMEL-432"},{"key":"HIMMEL-433"}]}]
EOF
v7render >/dev/null
vfp7a="$(cat "$v7out.vfp" 2>/dev/null)"
printf '%s\n' '---' 'key: "HIMMEL-433"' 'updated: "2026-09-30T10:00:00.000+0000"' 'statusCategory: "To Do"' 'status: "To Do"' 'fixVersions: ["v1.1.4"]' 'type: "Task"' \
    '---' '# HIMMEL-433: rowlive other version renamed' > "$vp/HIMMEL-433.md"
v7render >/dev/null
if [ "$(cat "$v7out.vfp" 2>/dev/null)" != "$vfp7a" ]; then pass 'a retitled chain step of another version moves the focus fingerprint'; else fail 'a retitled chain step of another version left the focus fingerprint unchanged'; fi
jq '. + [{"number":601,"title":"feat: [HIMMEL-433] other","headRefName":"feat/o","isDraft":false,"statusCheckRollup":[{"status":"COMPLETED","conclusion":"SUCCESS"}]}]' "$W/vp-prs7.json" > "$W/vp-prs7-green.json"
jq '.[1].statusCheckRollup = [{"status":"COMPLETED","conclusion":"FAILURE"}]' "$W/vp-prs7-green.json" > "$W/vp-prs7-red.json"
V7PRS="$W/vp-prs7-green.json" v7render >/dev/null
vfp7a="$(cat "$v7out.vfp" 2>/dev/null)"
V7PRS="$W/vp-prs7-red.json" v7render >/dev/null
if [ "$(cat "$v7out.vfp" 2>/dev/null)" != "$vfp7a" ]; then pass 'a CI change on the open PR of a chain step of another version moves the focus fingerprint'; else fail 'a CI change on the open PR of a chain step of another version left the focus fingerprint unchanged'; fi
cat > "$W/vp-chains7.json" <<'EOF'
[{"name":"c7621","steps":[{"key":"HIMMEL-432"},{"key":"HIMMEL-433"},{"key":"HIMMEL-999"}]}]
EOF
printf '{"key":"HIMMEL-999","leg":"N88","state":"live"}\n' > "$W/wk7/HIMMEL-999.json"
v7render >/dev/null
vfp7a="$(cat "$v7out.vfp" 2>/dev/null)"
printf '{"key":"HIMMEL-999","leg":"N88","state":"parked"}\n' > "$W/wk7/HIMMEL-999.json"
v7render >/dev/null
if [ "$(cat "$v7out.vfp" 2>/dev/null)" != "$vfp7a" ]; then pass 'a worker change on a chain step missing from the mirror moves the focus fingerprint'; else fail 'a worker change on a chain step missing from the mirror left the focus fingerprint unchanged'; fi
vfp7a="$(cat "$v7out.vfp" 2>/dev/null)"
printf '%s\n' '---' 'key: "HIMMEL-431"' 'updated: "2026-09-30T10:00:00.000+0000"' 'statusCategory: "To Do"' 'status: "To Do"' 'fixVersions: ["v1.1.3"]' 'labels: ["operator-present"]' 'type: "Task"' \
    '---' '# HIMMEL-431: rowlive operator ask' > "$vp/HIMMEL-431.md"
v7render >/dev/null
if [ "$(cat "$v7out.vfp" 2>/dev/null)" != "$vfp7a" ]; then pass 'a changed operator label moves the focus fingerprint'; else fail 'a changed operator label left the focus fingerprint unchanged'; fi
rm -f "$vp/HIMMEL-431.md"
v7render >/dev/null
contains 'Waiting on you says no source was read when none was, never a bare 0' "$(grep -F 'data-section="waiting"' "$v7out")" 'no operator-owed source read'

printf '%s\n' '---' 'key: "HIMMEL-434"' 'updated: "2026-09-30T10:00:00.000+0000"' 'statusCategory: "To Do"' 'status: "To Do"' 'fixVersions: ["v1.1.3"]' 'type: "Task"' \
    '---' '# HIMMEL-434: stalesec old wrapped worker' > "$vp/HIMMEL-434.md"
printf '%s\n' '---' 'key: "HIMMEL-435"' 'updated: "2026-09-30T10:00:00.000+0000"' 'statusCategory: "To Do"' 'status: "To Do"' 'fixVersions: ["v1.1.3"]' 'type: "Task"' \
    '---' '# HIMMEL-435: stalesec fresh wrapped worker' > "$vp/HIMMEL-435.md"
printf '%s' 'registry' > "$W/vp-registry9611.json"
TZ=UTC touch -t 202609010000 "$W/vp-registry9611.json"
cat > "$W/vp-chains9611.json" <<EOF
[{"name":"c9611","registry":{"path":"$W/vp-registry9611.json"},"steps":[{"key":"HIMMEL-434"},{"key":"HIMMEL-435"}]}]
EOF
mkdir -p "$W/wk9611"
old9611="$(python3 -c 'import datetime as d; print((d.datetime.now(d.timezone.utc) - d.timedelta(days=6)).strftime("%Y-%m-%dT%H:%M:%SZ"))')"
new9611="$(python3 -c 'import datetime as d; print((d.datetime.now(d.timezone.utc) - d.timedelta(hours=1)).strftime("%Y-%m-%dT%H:%M:%SZ"))')"
printf '{"key":"HIMMEL-434","leg":"N4412","state":"wrapped","last_event_ts":"%s","prs":{}}\n' "$old9611" > "$W/wk9611/HIMMEL-434.json"
printf '{"key":"HIMMEL-435","leg":"N4413","state":"wrapped","last_event_ts":"%s","prs":{}}\n' "$new9611" > "$W/wk9611/HIMMEL-435.json"
printf '%s\n' '# plan' 'priority: 1 | 2 | 3' > "$W/vp-plan9611.md"
TZ=UTC touch -t 202609010000 "$W/vp-plan9611.md"
v9611out="$W/vp-v9611.html"
v9611render() {
    local o
    o="$(TRACKER_JIRA="$W/vpjira" python3 "$HERE/tracker.py" --version v1.1.3 --repo example-org/example-repo --mirror-dir "$vp" \
        --prs-file "$W/vp-prs7.json" --chains-file "$W/vp-chains9611.json" --workers-dir "$W/wk9611" "$@" \
        --jira-base-url https://jira.example.test --out "$v9611out" 2>&1)" || fail "a stale-section render failed: $o" >&2
}
v9611render
h9611="$(cat "$v9611out" 2>/dev/null)"
not_contains 'a wrapped worker record six days old is not printed on its chain row or card' "$h9611" 'worker N4412'
contains 'a wrapped worker record from the last hour is still printed' "$h9611" 'worker N4413 · wrapped'
contains 'the header names the age of a chain registry the chains were read from' "$h9611" 'chain registry last edited 2026-09-01 00:00 UTC, older than the newest Jira update'
contains 'a page with no priority file says its blocks have no source' "$h9611" 'no priority line is read'
v9611render --priority-file "$W/vp-plan9611.md"
h9611="$(cat "$v9611out" 2>/dev/null)"
contains 'a priority file older than the newest Jira update names its age' "$h9611" 'priority line last edited 2026-09-01 00:00 UTC, older than the newest Jira update'
not_contains 'a priority file read says nothing about having no source' "$h9611" 'no priority line is read'

for t in 436 437 438 439 440 441; do
    printf '%s\n' '---' "key: \"HIMMEL-$t\"" 'updated: "2026-09-30T10:00:00.000+0000"' 'statusCategory: "To Do"' 'status: "To Do"' 'fixVersions: ["v1.1.3"]' 'type: "Task"' \
        '---' "# HIMMEL-$t: owedsec ticket $t" > "$vp/HIMMEL-$t.md"
done
bk="$W/bk9611"
mkdir -p "$bk/release/v1.1.3" "$bk/specs/designs"
printf '%s\n' '{"kind":"spec","keys":["HIMMEL-437"],"spec_path":"'"$bk"'/specs/designs/HIMMEL-437-signed.md"}' '{"kind":"spec","spec_path":"'"$bk"'/specs/designs/HIMMEL-439-nomd.md"}' '{bad row' '{"kind":"declare","decision":"1"}' > "$bk/release/v1.1.3/operator.jsonl"
printf '%s\n' '# critic' 'SPEC CLEAN' > "$bk/specs/designs/HIMMEL-439-nomd.critic-spec-r1.md"
: > "$bk/specs/designs/HIMMEL-440-empty.md.critic-spec-r1.md"
printf '\377\376 not utf-8\n' > "$bk/specs/designs/HIMMEL-441-binary.md.critic-spec-r1.md"
printf '%s\n' '# critic' 'SPEC FINDINGS 2' > "$bk/specs/designs/HIMMEL-434-capped.md.critic-spec-r3.md"
printf '%s\n' '# critic' 'SPEC FINDINGS 9' > "$bk/specs/designs/HIMMEL-434-capped.md.critic-spec-r2.md"
printf '%s\n' '# critic' 'SPEC CLEAN' > "$bk/specs/designs/HIMMEL-435-clean.md.critic-spec-r1.md"
printf '%s\n' '# critic' 'SPEC FINDINGS 3' > "$bk/specs/designs/HIMMEL-436-underway.md.critic-spec-r1.md"
printf '%s\n' '# critic' 'SPEC CLEAN' > "$bk/specs/designs/HIMMEL-437-signed.md.critic-spec-r1.md"
printf '%s\n' '# critic' 'SPEC CLEAN' > "$bk/specs/designs/HIMMEL-999-notopen.md.critic-spec-r1.md"
printf '%s\n' '# critic' 'a closing note that is not a verdict line' > "$bk/specs/designs/HIMMEL-438-noverdict.md.critic-spec-r3.md"
seed "$bk"
printf '%s\n' '# handoff' '## Open operator items' '' 'Answer the paid-step ask' '## Wrapped' 'none' > "$bk/HIMMEL-nextleg-x-chief-HANDOFF.md"
printf '%s\n' '# chief' '## Live state' 'queue: first | HIMMEL-435 waits for operator sign-off of the spend grant | third || prior shift queue: HIMMEL-438 operator sign-off long finished | HIMMEL-434 operator words old ask' \
    'pool-disposition: HIMMEL-434 question operator on Telegram, runs the paid step' 'pool-disposition: HIMMEL-436 slice parked, no ask' \
    '## Other' 'pool-disposition: HIMMEL-437 operator words outside the live state' > "$bk/chief.md"
v9611render --owed-dir "$bk" --chief-doc "$bk/chief.md"
w9611="$(grep -F 'data-section="waiting"' "$v9611out")"
c9611="$(grep -F 'data-section="chief-owes"' "$v9611out")"
a9611="$w9611$c9611"
contains 'Waiting on you counts only the handoff item and the chief lines' "$w9611" 'data-count="3"'
contains 'the Chief owes group counts the three unsigned specs' "$c9611" 'data-count="3"'
contains 'a spec past the round cap with no spec row is chief-owed' "$c9611" 'HIMMEL-434-capped.md: latest critic round 3'
contains 'a spec whose latest critic reads SPEC CLEAN with no spec row is chief-owed' "$c9611" 'HIMMEL-435-clean.md: latest critic round 1 reads SPEC CLEAN'
contains 'a past-cap spec whose last line is no verdict says so, never prints that line' "$c9611" 'HIMMEL-438-noverdict.md: latest critic round 3 reads no verdict line'
not_contains 'an unsigned non-critical spec is not under Waiting on you' "$w9611" 'HIMMEL-435-clean.md'
not_contains 'a spec with a spec row is not owed' "$a9611" 'HIMMEL-437-signed'
not_contains 'a spec under the cap with findings is not owed' "$a9611" 'HIMMEL-436-underway'
not_contains 'a spec of a ticket not open in the version is not owed' "$a9611" 'HIMMEL-999'
not_contains 'a spec signed under its .md path is not owed when the critic file has no .md before .critic-spec' "$a9611" 'HIMMEL-439-nomd'
contains 'an empty critic file and an undecodable one are named as unread and skipped' "$w9611" '2 critic files unread, skipped: HIMMEL-440-empty.md.critic-spec-r1.md, HIMMEL-441-binary.md.critic-spec-r1.md'
contains 'the handoff open operator item is listed with its action' "$w9611" 'Answer the paid-step ask'
contains 'a queue segment naming the operator is listed' "$w9611" 'HIMMEL-435 waits for operator sign-off'
contains 'a pool-disposition line naming the operator is listed' "$w9611" 'operator on Telegram, runs the paid step'
not_contains 'a pool-disposition line that names no operator is not listed' "$w9611" 'slice parked, no ask'
not_contains 'a line outside the Live state is not read' "$w9611" 'outside the live state'
not_contains 'the history after a double bar on the queue line is not live' "$w9611" 'prior shift'
not_contains 'a segment of that history naming the operator is not listed' "$w9611" 'words old ask'
contains 'a missing pool-holds file is named as unread' "$w9611" 'pool holds unread: pool-holds-chief.json'

mkdir -p "$TICK_STATE_DIR"
gd_stem=HIMMEL-nextleg-2026-11-15GD-roadmap-chief
cp "$HERE/fixtures/pool-holds-golden.json" "$TICK_STATE_DIR/pool-holds-$gd_stem.json"
gd_key=HIMMEL
gd_doc() {
    printf '%s\n' '# chief' '## Live state' "pool-disposition: $gd_key-1 $1" "pool-disposition: $gd_key-2 park operator words: hold it" \
        "pool-disposition: $gd_key-3 hold on the merge wake=pr:4999" "pool-disposition: $gd_key-4 hold on the other merge wake=pr:4998" \
        "pool-disposition: $gd_key-5 park until then wake=date:2026-11-18" "pool-disposition: $gd_key-6 question operator words: still asked" > "$bk/$gd_stem.md"
}
gd_doc 'question one more round authority=O-v1.1.3-0001'
v9611render --owed-dir "$bk" --chief-doc "$bk/$gd_stem.md"
wgd="$(grep -F 'data-section="waiting"' "$v9611out")"
cgd="$(grep -F 'data-section="chief-owes"' "$v9611out")"
contains 'a no-authority hold is chief-visible with its generation age' "$cgd" 'park since 3 chief generations, with no operator words and no wake'
not_contains 'a no-authority hold is not operator work' "$wgd" 'park since 3 chief generations'
contains 'and its action' "$cgd" 'action: record the operator&#x27;s words (O- record) or a near wake=, or dispatch it'
contains 'an authority row of verb question shows the cited words (I9)' "$wgd" 'question on the operator&#x27;s words: &quot;Approved one more round&quot;'
contains 'a pr: wake held for 7 days asks the chief to re-decide' "$cgd" 'hold on wake=pr:4999 for 7 days'
not_contains 'a pr: wake held for 6 days is not shown' "$wgd" 'wake=pr:4998'
not_contains 'a date: wake is never shown' "$wgd" 'wake=date:'
equals 'the holds row replaces the chief doc line of the same key' "$(grep -F -e 'data-section="waiting"' -e 'data-section="chief-owes"' "$v9611out" | grep -o 'hold it' | wc -l | tr -d ' ')" 0
contains 'a pool-disposition line naming the operator and absent from the file is still an item' "$wgd$(grep -F 'data-section="chief-owes"' "$v9611out")" 'still asked'
not_contains 'a read holds file is not named as unread' "$wgd" 'pool holds unread'
gd_doc 'question one more round, reworded authority=O-v1.1.3-0001'
v9611render --owed-dir "$bk" --chief-doc "$bk/$gd_stem.md"
contains 'a holds row whose doc line changed stays visible for reconciliation' "$(grep -F 'data-section="reconciliation"' "$v9611out")" 'question (unchecked: the line changed since the holds run)'
printf '{"rows":1}\n' > "$TICK_STATE_DIR/pool-holds-$gd_stem.json"
gd_doc 'question one more round authority=O-v1.1.3-0001'
v9611render --owed-dir "$bk" --chief-doc "$bk/$gd_stem.md"
contains 'a holds file with no rows list is named as unread' "$(grep -F 'data-section="waiting"' "$v9611out")" "pool holds unread: pool-holds-$gd_stem.json"
cp "$HERE/fixtures/pool-holds-golden.json" "$TICK_STATE_DIR/pool-holds-$gd_stem.json"
touch_ago 1860 "$TICK_STATE_DIR/pool-holds-$gd_stem.json"
v9611render --owed-dir "$bk" --chief-doc "$bk/$gd_stem.md"
contains 'a holds file over 30 minutes old is named as unread' "$(grep -F 'data-section="waiting"' "$v9611out")" "pool holds unread: pool-holds-$gd_stem.json"
ln -s "$bk" "$W/bk9611-link"
v9611render --owed-dir "$W/bk9611-link" --chief-doc "$bk/chief.md"
not_contains 'a spec signed under the real bucket path is not owed when the bucket is given by a symlink' "$(grep -F -e 'data-section="waiting"' -e 'data-section="chief-owes"' "$v9611out")" 'HIMMEL-437-signed'
printf '{"key":"HIMMEL-436","leg":"N4414","state":"wrapped","last_event_ts":"%s","prs":{"77":{"open":true,"head":"abc1234def5678abc1234def5678abc1234def56"}}}\n' "$old9611" > "$W/wk9611/HIMMEL-436.json"
v9611render --owed-dir "$bk" --chief-doc "$bk/chief.md"
contains 'an old wrapped worker record that still holds an open PR is still printed' "$(cat "$v9611out")" 'worker N4414'
not_contains 'a page that read its sources does not say none was read' "$w9611" 'no operator-owed source read'
mkdir -p "$W/bk9611-nolog/specs/designs"
printf '%s\n' '# critic' 'SPEC CLEAN' > "$W/bk9611-nolog/specs/designs/HIMMEL-435-clean.md.critic-spec-r1.md"
seed "$W/bk9611-nolog"
v9611render --owed-dir "$W/bk9611-nolog"
w9611n="$(grep -F 'data-section="waiting"' "$v9611out")"
contains 'a clean spec is chief-owed when no operator.jsonl exists yet' "$(grep -F 'data-section="chief-owes"' "$v9611out")" 'HIMMEL-435-clean.md: latest critic round 1 reads SPEC CLEAN'
not_contains 'a bucket with a specs dir but no operator.jsonl counts as read' "$w9611n" 'no operator-owed source read'
mkdir -p "$W/bk9611-empty/release/v1.1.3"
: > "$W/bk9611-empty/release/v1.1.3/operator.jsonl"
v9611render --owed-dir "$W/bk9611-empty"
contains 'a readable source with nothing owed says nothing is waiting' "$(grep -F 'data-section="waiting"' "$v9611out")" 'nothing is waiting on you'
not_contains 'a page with nothing chief-owed has no Chief owes group' "$(cat "$v9611out")" 'data-section="chief-owes"'
printf '%s\n' '{"op":"add","id":"o1","kind":"step","text":"sign the v1.1.3 release spec","actor":"operator"}' \
    '{"op":"add","id":"o2","kind":"proof","text":"run the VM upgrade proof","actor":"operator"}' \
    '{"op":"add","id":"o3","kind":"proof","text":"chief validates a proof"}' \
    '{"op":"add","id":"o4","kind":"step","text":"a closed operator step","actor":"operator"}' '{"op":"close","ref":"o4","key":"1290"}' > "$W/bk9611-empty/owed.jsonl"
v9611render --owed-dir "$W/bk9611-empty"
w10764="$(grep -F 'data-section="waiting"' "$v9611out")"
contains '10764: an operator-marked signature in the owed ledger is a numbered Needs you item' "$w10764" '<ol class="needs-you"><li class="owed"><b>Needs you:</b> sign the v1.1.3 release spec'
contains '10764: an operator-marked owed proof is listed' "$w10764" 'run the VM upgrade proof'
not_contains '10764: the empty state is not printed while an operator item is open' "$w10764" 'nothing is waiting on you'
not_contains '10764: a chief-owed or closed ledger row is not the operator item' "$w10764" 'chief validates a proof'
not_contains '10764: a closed operator row is not listed' "$w10764" 'a closed operator step'
mv "$W/bk9611-empty/owed.jsonl" "$W/bk9611-empty/owed.keep"; mkdir "$W/bk9611-empty/owed.jsonl"
v9611render --owed-dir "$W/bk9611-empty"
w10764u="$(grep -F 'data-section="waiting"' "$v9611out")"
contains '10764: an unreadable owed ledger is named as the owed ledger' "$w10764u" 'owed ledger unread'
not_contains '10764: an unreadable owed ledger is not called a critic file' "$w10764u" 'critic file'
rmdir "$W/bk9611-empty/owed.jsonl"; mv "$W/bk9611-empty/owed.keep" "$W/bk9611-empty/owed.jsonl"

for t in 442 443 444 445 446 447 448 449 450; do
    cat='To Do'; st='To Do'; res='Done'
    [ "$t" = 445 ] && { cat='Done'; st='Done'; }
    [ "$t" = 450 ] && { cat='Done'; st='Closed'; res="Won't Do"; }
    printf '%s\n' '---' "key: \"HIMMEL-$t\"" 'updated: "2026-09-30T10:00:00.000+0000"' "statusCategory: \"$cat\"" "status: \"$st\"" "resolution: \"$res\"" 'fixVersions: ["v1.1.3"]' 'type: "Task"' \
        '---' "# HIMMEL-$t: chiefowes ticket $t" > "$vp/HIMMEL-$t.md"
done
bk="$W/bk9673"
mkdir -p "$bk/release/v1.1.3" "$bk/specs/designs"
printf '%s\n' '{"kind":"spec","spec_path":"'"$bk"'/specs/designs/HIMMEL-444-bus-read-no-args.md"}' \
    '{"kind":"spec","keys":["HIMMEL-448"],"spec_path":"'"$bk"'/specs/design/HIMMEL-448/spec.md"}' > "$bk/release/v1.1.3/operator.jsonl"
printf '%s\n' '# critic' 'SPEC CLEAN' > "$bk/specs/designs/HIMMEL-448-old.md.critic-spec-r1.md"
printf '%s\n' '# critic' 'OPERATOR-CRITICAL: account-or-terms' 'SPEC CLEAN' > "$bk/specs/designs/HIMMEL-449-critic-only.md.critic-spec-r1.md"
printf '%s\n' '# critic' 'SPEC CLEAN' > "$bk/specs/designs/HIMMEL-442-plain.md.critic-spec-r1.md"
printf '%s\n' '# spec' 'plain spec, no marker' > "$bk/specs/designs/HIMMEL-442-plain.md"
printf '%s\n' '# critic' 'SPEC CLEAN' > "$bk/specs/designs/HIMMEL-443-crit.md.critic-spec-r1.md"
printf '%s\n' '# spec' 'OPERATOR-CRITICAL: spend-grant' > "$bk/specs/designs/HIMMEL-443-crit.md"
printf '%s\n' '# critic' 'SPEC CLEAN' > "$bk/specs/designs/HIMMEL-444-bus-read.md.critic-spec-r1.md"
printf '%s\n' '# critic' 'SPEC CLEAN' > "$bk/specs/designs/HIMMEL-447-empty.md.critic-spec-r1.md"
printf '%s\n' '# spec' 'OPERATOR-CRITICAL:' 'a reason on the next line is no marker' > "$bk/specs/designs/HIMMEL-447-empty.md"
printf '%s\n' '# chief' '## Live state' 'queue: HIMMEL-445 operator sign-off finished | HIMMEL-446 operator words still open (an account change) | HIMMEL-450 operator words dropped' > "$bk/chief.md"
seed "$bk"
v9611render --owed-dir "$bk" --chief-doc "$bk/chief.md"
w9673="$(grep -F 'data-section="waiting"' "$v9611out")"
c9673="$(grep -F 'data-section="chief-owes"' "$v9611out")"
contains 'an unsigned non-critical spec is under Chief owes' "$c9673" 'HIMMEL-442-plain.md: latest critic round 1'
not_contains 'an unsigned non-critical spec is not under Waiting on you' "$w9673" 'HIMMEL-442-plain.md'
contains 'control: an unsigned spec carrying OPERATOR-CRITICAL still lists under Waiting on you' "$w9673" 'HIMMEL-443-crit.md: latest critic round 1'
not_contains 'an operator-critical spec is not under Chief owes' "$c9673" 'HIMMEL-443-crit'
not_contains 'an older critic family of a ticket with a signed spec row lists nowhere' "$w9673$c9673" 'HIMMEL-444'
not_contains 'a chief-doc line whose ticket is Done does not list' "$w9673" 'HIMMEL-445 operator sign-off finished'
contains 'control: a chief-doc line whose ticket is open still lists under Waiting on you' "$w9673" 'HIMMEL-446 operator words still open'
not_contains 'a signed row filed at a folder-style spec_path signs its keys, so the older critic family lists nowhere' "$w9673$c9673" 'HIMMEL-448'
contains 'a marker only in the latest critic file keeps the spec under Waiting on you' "$w9673" 'HIMMEL-449-critic-only.md: latest critic round 1'
not_contains 'a chief-doc line whose ticket was closed without shipping does not list' "$w9673" 'HIMMEL-450 operator words dropped'
contains 'Waiting on you counts the two critical specs and the open chief-doc line' "$w9673" 'data-count="3"'
contains 'a marker line with no reason on its own line is not a marker' "$c9673" 'HIMMEL-447-empty.md: latest critic round 1'
contains 'Chief owes counts the two non-critical specs' "$c9673" 'data-count="2"'

for t in 451 452 453 454; do
    printf '%s\n' '---' "key: \"HIMMEL-$t\"" 'updated: "2026-09-30T10:00:00.000+0000"' 'statusCategory: "To Do"' 'status: "To Do"' 'fixVersions: ["v1.1.3"]' 'type: "Task"' \
        '---' "# HIMMEL-$t: ledger ticket $t" > "$vp/HIMMEL-$t.md"
done
bk="$W/bk9687"
mkdir -p "$bk/release/v1.1.3" "$bk/specs/designs" "$bk/specs/decisions"
: > "$bk/release/v1.1.3/operator.jsonl"
printf '%s\n' '# spec' 'OPERATOR-CRITICAL: security' > "$bk/specs/designs/HIMMEL-451-sec.md"
printf '%s\n' '# critic' 'SPEC CLEAN' > "$bk/specs/designs/HIMMEL-451-sec.md.critic-spec-r1.md"
printf '%s\n' '# spec' 'OPERATOR-CRITICAL: spend-grant' > "$bk/specs/designs/HIMMEL-452-grant.md"
printf '%s\n' '# critic' 'SPEC CLEAN' > "$bk/specs/designs/HIMMEL-452-grant.md.critic-spec-r1.md"
printf '%s\n' '# critic' '- **o1** (minor; operator-critical: spend-grant) the step buys a paid seat' '' 'SPEC FINDINGS 1' > "$bk/specs/designs/HIMMEL-453-seat.md.critic-spec-r2.md"
printf '%s\n' '# critic' 'SPEC FINDINGS 4' > "$bk/specs/designs/HIMMEL-454-moved.md.critic-spec-r1.md"
printf '%s\n' '# critic' 'SPEC FINDINGS 2' > "$bk/specs/designs/HIMMEL-454-moved.md.critic-spec-r3.md"
seed "$bk"
rm "$bk/specs/designs/HIMMEL-454-moved.md.critic-spec-r3.md"
v9611render --owed-dir "$bk"
w9687="$(grep -F 'data-section="waiting"' "$v9611out")"
c9687="$(grep -F 'data-section="chief-owes"' "$v9611out")"
not_contains 'R7-tracker: a marker naming no operator-critical class is not under Waiting on you' "$w9687" 'HIMMEL-451-sec.md'
contains 'R7-tracker: a marker naming no operator-critical class is chief-owed' "$c9687" 'HIMMEL-451-sec.md: latest critic round 1'
contains 'R7-tracker: control: a marker naming spend-grant is under Waiting on you' "$w9687" 'HIMMEL-452-grant.md: latest critic round 1'
contains 'R19-tracker: an open operator-critical finding under the cap is under Waiting on you, naming its id and class' "$w9687" 'o1 (spend-grant)'
not_contains 'R19-tracker: a spec under the cap with findings is not an unsigned spec' "$w9687$c9687" 'HIMMEL-453-seat.md: latest critic'
contains 'a key at ledger round 3 is owed though no round-3 critic file is on disk' "$c9687" 'HIMMEL-454-moved.md: latest critic round 3 reads SPEC FINDINGS 4'
t=453
printf '%s\n' "Operator, on HIMMEL-$t: sign it as it stands, the paid seat is approved." > "$bk/specs/decisions/verbatim-decision-901-seat.txt"
o="$(HIMMEL_CONSOLE=1 bun "$ROUTE" round-critical "HIMMEL-$t" --finding o1 --decision 901 --quote 'sign it as it stands, the paid seat is approved' --no-round --specs "$bk/specs" 2>&1)" \
    || fail "R19-tracker: the --no-round record was refused: $o"
v9611render --owed-dir "$bk"
not_contains 'R19-tracker: after the --no-round record the finding is not under Waiting on you' "$(grep -F 'data-section="waiting"' "$v9611out")" 'o1 (spend-grant)'
mv "$bk/specs/ledgers" "$bk/specs/ledgers.gone"
v9611render --owed-dir "$bk"
contains 'a bucket whose round status cannot be read names its critic files unread' "$(grep -F 'data-section="waiting"' "$v9611out")" 'HIMMEL-452-grant.md.critic-spec-r1.md'
contains 'a bucket whose round status cannot be read names the round ledger unread' "$(grep -F 'data-section="waiting"' "$v9611out")" 'round ledger'
not_contains 'a bucket whose round status cannot be read lists no unsigned spec' "$(grep -F -e 'data-section="waiting"' -e 'data-section="chief-owes"' "$v9611out")" 'latest critic round'

for t in 455 456; do
    printf '%s\n' '---' "key: \"HIMMEL-$t\"" 'updated: "2026-09-30T10:00:00.000+0000"' 'statusCategory: "To Do"' 'status: "To Do"' 'fixVersions: ["v1.1.3"]' 'type: "Task"' \
        '---' "# HIMMEL-$t: restore ticket $t" > "$vp/HIMMEL-$t.md"
done
SEAL="$HERE/critic-seal.sh"
r10628quote='the park rm keeps its simple placement under the park root'
r10628finding='- **r1** (major; operator-critical: reverses-ruling) the spec moves the park rm. That reverses decision 1096 rule 1.'
r10628tree() {
    mkdir -p "$1/release/v1.1.3" "$1/specs/designs" "$1/specs/decisions"
    : > "$1/release/v1.1.3/operator.jsonl"
    seed "$1"
    printf '%s\n' '---' "tickets: HIMMEL-$2" '---' '# rev' > "$1/specs/designs/HIMMEL-$2-rev.md"
    printf '%s\n' "Operator, on HIMMEL-$2: $r10628quote, rule 1." > "$1/specs/decisions/verbatim-decision-1096-park.txt"
}
r10628seal() {
    local sp="$1/specs/designs/HIMMEL-$2-rev.md" k="$2" n="$3" verdict="$4" sum o
    shift 4
    sum="$(sha256sum "$sp" | cut -d' ' -f1)"
    { printf 'critic return r%s read %s\n' "$n" "$sum"; for l in "$@"; do printf '%s\n' "$l"; done; printf '%s\n' "$verdict"; } > "$sp.critic-spec-r$n.md"
    o="$(bash "$SEAL" "$sp.critic-spec-r$n.md" "$sp" "$sum" 2>&1)" || fail "R10628-tracker: spec round $n of HIMMEL-$k did not seal: $o"
}
r10628waiting() { grep -F 'data-section="waiting"' "$v9611out"; }
kc=456
kr=455
bkc="$W/bk10628c"
r10628tree "$bkc" "$kc"
r10628seal "$bkc" "$kc" 1 'SPEC CLEAN'
r10628seal "$bkc" "$kc" 2 'SPEC FINDINGS 1' "$r10628finding"
r2sha="$(jq -r 'select(.row == "round" and .round == 2) | .return_sha' "$bkc/specs/ledgers/spec-rounds/HIMMEL-$kc.jsonl")"
[ -n "$r2sha" ] || fail "R10628-tracker: control: spec round 2 of HIMMEL-$kc has no sealed return_sha"
printf '{"v":1,"ts":1,"key":"HIMMEL-%s","row":"critical","restore":true,"critic":"spec","epoch":0,"opens":3,"id":"r1","class":"reverses-ruling","decision":"1096","quote":"%s","decision_path":"%s","decision_sha":"%s","return_sha":"%s"}\n' \
    "$kc" "$r10628quote" "$bkc/specs/decisions/verbatim-decision-1096-park.txt" "0000000000000000000000000000000000000000000000000000000000000000" "$r2sha" >> "$bkc/specs/ledgers/spec-rounds/HIMMEL-$kc.jsonl"
v9611render --owed-dir "$bkc"
contains 'R10628-tracker: control: a hand-appended restore row that replays invalid leaves the finding under Waiting on you' "$(r10628waiting)" 'r1 (reverses-ruling)'
bkr="$W/bk10628"
r10628tree "$bkr" "$kr"
r10628seal "$bkr" "$kr" 1 'SPEC CLEAN'
r10628seal "$bkr" "$kr" 2 'SPEC FINDINGS 1' "$r10628finding"
v9611render --owed-dir "$bkr"
contains 'R10628-tracker: control: the open reverses-ruling finding is under Waiting on you' "$(r10628waiting)" 'r1 (reverses-ruling)'
o="$(HIMMEL_CONSOLE=1 bun "$ROUTE" round-critical HIMMEL-$kr --finding r1 --decision 1096 --quote "$r10628quote" --restores --specs "$bkr/specs" 2>&1)" \
    || fail "R10628-tracker: the restore was refused: $o"
v9611render --owed-dir "$bkr"
not_contains 'R10628-tracker: a finding whose restore check is owed is not under Waiting on you' "$(r10628waiting)" 'r1 (reverses-ruling)'
tok="$(bun "$ROUTE" round-status HIMMEL-$kr --specs "$bkr/specs" | sed -n 's/^RESTORE-CHECK .* token \([0-9a-f]*\)$/\1/p')"
r10628seal "$bkr" "$kr" 3 'SPEC CLEAN' "RESTORE-BREAKS r1 decision 1096 $tok"
v9611render --owed-dir "$bkr"
contains 'R10628-tracker: after RESTORE-BREAKS the finding is back under Waiting on you' "$(r10628waiting)" 'r1 (reverses-ruling)'

for t in 457 458 459 460 461 462 463; do
    printf '%s\n' '---' "key: \"HIMMEL-$t\"" 'updated: "2026-09-30T10:00:00.000+0000"' 'statusCategory: "To Do"' 'status: "To Do"' 'fixVersions: ["v1.1.3"]' 'type: "Task"' \
        '---' "# HIMMEL-$t: signer ticket $t" > "$vp/HIMMEL-$t.md"
done
bk="$W/bk10644"
mkdir -p "$bk/release/v1.1.3" "$bk/specs/designs"
for s in 457-marked 458-slice 459-plain 460-unknown; do
    printf '%s\n' '---' "tickets: HIMMEL-${s%%-*}" '---' '# spec' > "$bk/specs/designs/HIMMEL-$s.md"
    printf '%s\n' '# critic' 'SPEC CLEAN' > "$bk/specs/designs/HIMMEL-$s.md.critic-spec-r1.md"
done
printf '%s\n' '---' 'tickets: HIMMEL-458, HIMMEL-457' '---' '# slice spec' > "$bk/specs/designs/HIMMEL-458-slice.md"
for t in 461 462 463; do
    printf '{"kind":"spec","keys":["HIMMEL-%s"],"spec_path":"%s/specs/designs/HIMMEL-%s-signed.md"}\n' "$t" "$bk" "$t"
done > "$bk/release/v1.1.3/operator.jsonl"
seed "$bk"
cat > "$W/s5jira" <<S5JIRA
#!/bin/sh
printf '%s\n' "\$*" >> "$W/s5-args"
mode="\$(cat "$W/s5-mode")"
[ "\$1" = release ] || exit 1
verb="\$2"; shift 2
spec=''; keys=''
while [ \$# -gt 0 ]; do
    case "\$1" in --spec) spec="\$2"; shift 2 ;; --mirror) shift 2 ;; *) keys="\$keys \$1"; shift ;; esac
done
for k in \$keys; do
    [ "\$mode" = noline ] && { [ "\$k" = HIMMEL-457 ] || [ "\$k" = HIMMEL-461 ]; } && continue
    if [ "\$verb" = signer-check ]; then
        case "\$k" in
            HIMMEL-457) echo "SIGNER \$k operator O-v1.1.3-0900" ;;
            HIMMEL-458) case "\$spec" in *HIMMEL-458-slice.md) echo "SIGNER \$k operator O-v1.1.3-0900 via HIMMEL-457" ;; *) echo "SIGNER \$k chief default" ;; esac ;;
            HIMMEL-460) echo "UNKNOWN \$k release v1.1.3 chain unreadable" ;;
            *) echo "SIGNER \$k chief default" ;;
        esac
    else
        case "\$k" in
            HIMMEL-461) echo "SPEC-NEEDS-OPERATOR \$k $bk/specs/designs/HIMMEL-461-signed.md C-v1.1.3-0901 O-v1.1.3-0900" ;;
            HIMMEL-462) echo "SPEC-SIGNER-UNKNOWN \$k C-v1.1.3-0902 release v1.1.3 chain unreadable" ;;
            *) echo "SPEC ok \$k $bk/specs/designs/HIMMEL-\${k#HIMMEL-}-signed.md C-v1.1.3-0903" ;;
        esac
    fi
done
[ "\$mode" = exit2 ] && exit 2
[ "\$verb" = spec-check ] && exit 1
exit 0
S5JIRA
chmod +x "$W/s5jira"
s5render() {
    local o
    : > "$W/s5-args"
    printf '%s\n' "$1" > "$W/s5-mode"
    o="$(TRACKER_JIRA="$W/s5jira" python3 "$HERE/tracker.py" --version v1.1.3 --repo example-org/example-repo --mirror-dir "$vp" \
        --prs-file "$W/vp-prs7.json" --chains-file "$W/vp-chains9611.json" --workers-dir "$W/wk9611" --owed-dir "$bk" \
        --jira-base-url https://jira.example.test --out "$v9611out" 2>&1)" || fail "S5-tracker: the render failed: $o" >&2
    w10644="$(grep -F 'data-section="waiting"' "$v9611out")"
    c10644="$(grep -F 'data-section="chief-owes"' "$v9611out")"
}
s5render ok
contains 'S5-tracker: an unsigned critic-clean spec of a marked key is an operator item, not chief-owed' "$w10644" 'HIMMEL-457-marked.md: latest critic round 1 reads SPEC CLEAN'
not_contains 'S5-tracker: the marked key is not chief-owed' "$c10644" 'HIMMEL-457-marked.md'
contains 'S5-tracker: the marked key names the governing record' "$w10644" 'signer-check: SIGNER HIMMEL-457 operator O-v1.1.3-0900'
contains 'S5-tracker: signer-check is asked with the spec file' "$(cat "$W/s5-args")" "--spec $bk/specs/designs/HIMMEL-458-slice.md"
contains 'S5-tracker: an unsigned slice spec whose header names a marked ticket is an operator item through its via line' "$w10644" 'SIGNER HIMMEL-458 operator O-v1.1.3-0900 via HIMMEL-457'
not_contains 'S5-tracker: the via slice key is not chief-owed' "$c10644" 'HIMMEL-458-slice.md'
contains 'S5-tracker: control: a spec signer-check gives the chief stays chief-owed' "$c10644" 'HIMMEL-459-plain.md: latest critic round 1'
contains 'S5-tracker: an UNKNOWN signer stays with the chief naming why' "$c10644" 'signer unread: release v1.1.3 chain unreadable'
contains 'S5-tracker: a SPEC-NEEDS-OPERATOR line is an operator item naming the chief signature' "$w10644" "needs the operator&#x27;s own signature: chief signature C-v1.1.3-0901 does not count (O-v1.1.3-0900)"
contains 'S5-tracker: a SPEC-SIGNER-UNKNOWN line stays with the chief naming why' "$c10644" 'chief signature C-v1.1.3-0902 cannot be checked: signer records unreadable: release v1.1.3 chain unreadable'
not_contains 'S5-tracker: a chief row from before a station flip (SPEC ok) stays signed' "$w10644$c10644" 'HIMMEL-463'
equals 'S5-tracker: spec-check is asked once, for the keys with a spec row' "$(grep -c '^release spec-check' "$W/s5-args")" 1
not_contains 'S5-tracker: a read release check is not named unread' "$w10644" 'unread, rows unchanged'
for mode in exit2 noline; do
    s5render "$mode"
    contains "S5-tracker: a signer-check that fails ($mode) is listed as unread" "$w10644" 'release signer-check unread, rows unchanged'
    contains "S5-tracker: a spec-check that fails ($mode) is listed as unread" "$w10644" 'release spec-check unread, rows unchanged'
    contains "S5-tracker: an unread signer leaves the marked key where it was ($mode)" "$c10644" 'HIMMEL-457-marked.md: latest critic round 1'
    not_contains "S5-tracker: an unread spec-check lists no signed key ($mode)" "$w10644$c10644" 'C-v1.1.3-090'
done

s4="$W/s4"
mkdir -p "$s4/mirror" "$s4/wk"
s4mk() {
    printf '%s\n' '---' "key: \"HIMMEL-$1\"" 'updated: "2026-09-30T10:00:00.000+0000"' 'statusCategory: "In Progress"' 'status: "In Progress"' \
        'fixVersions: ["v1.1.3"]' "labels: $2" 'type: "Task"' '---' "# HIMMEL-$1: s4 card $1" > "$s4/mirror/HIMMEL-$1.md"
}
s4mk 11 '["phase:sliced"]'
s4mk 12 '["phase:design"]'
s4mk 13 '[]'
s4mk 14 '["phase:build"]'
for n in 12 13 14; do printf '{"key":"HIMMEL-%s","leg":"N%s","state":"live","prs":{}}\n' "$n" "$n" > "$s4/wk/HIMMEL-$n.json"; done
printf '[]\n' > "$s4/prs.json"
s4out="$s4/page.html"
s4render() {
    rm -f "$s4out" "$s4out.vfp"
    python3 "$HERE/tracker.py" --version v1.1.3 --repo example-org/example-repo --mirror-dir "$s4/mirror" --prs-file "$s4/prs.json" \
        --workers-dir "$s4/wk" --out "$s4out" "$@" 2>&1
}
s4card() { grep -F "data-key=\"HIMMEL-$1\"" "$s4out" 2>/dev/null; }
printf 'state\tcomplete\nHIMMEL-11\nHIMMEL-14\n' > "$s4/stale-complete"
s4o="$(s4render --stale-file "$s4/stale-complete")"
s4rc=$?
if [ "$s4rc" -eq 0 ]; then pass 'S4: --stale-file renders and exits 0'; else fail "S4: --stale-file exited $s4rc: $s4o"; fi
s4page="$(cat "$s4out" 2>/dev/null)"
contains 'S4: a stale key shows its phase label on the card' "$(s4card 11)" 'phase:sliced'
contains 'S4: a stale key shows STALE on the card' "$(s4card 11)" 'STALE · started, no live owner, no open PR, no dated wait'
contains 'S4: a card off the stale file shows its phase label' "$(s4card 12)" 'phase:design'
not_contains 'S4: a card off the stale file has no STALE mark' "$(s4card 12)" 'STALE'
contains 'S4: a started card with no phase label reads phase: none' "$(s4card 13)" '<span class="phase none">phase: none</span>'
not_contains 'S4: a started card off the stale file with no label has no STALE mark' "$(s4card 13)" 'STALE'
contains 'S4: a stale key with a live worker record still shows STALE (the tracker shows what it is handed)' "$(s4card 14)" 'STALE'
contains 'S4: that card also shows its phase label' "$(s4card 14)" 'phase:build'
contains 'S4: the header counts started cards with no phase' "$s4page" 'no phase 1'
contains 'S4: the header counts the stale cards of a complete file' "$s4page" 'stale 2'
not_contains 'S4: a complete file has no partial note' "$s4page" 'stale 2 (partial)'
printf 'state\tpartial\nHIMMEL-11\nHIMMEL-14\n' > "$s4/stale-partial"
s4render --stale-file "$s4/stale-partial" >/dev/null
contains 'S4: a partial file reads stale 2 (partial)' "$(cat "$s4out" 2>/dev/null)" 'stale 2 (partial)'
s4render >/dev/null
s4page="$(cat "$s4out" 2>/dev/null)"
not_contains 'S4: with no --stale-file no card is marked STALE' "$(s4card 11)" 'STALE'
contains 'S4: with no --stale-file the header reads stale: unknown' "$s4page" 'stale: unknown'
printf 'garbage\nHIMMEL-11\n' > "$s4/stale-bad"
s4render --stale-file "$s4/stale-bad" >/dev/null
not_contains 'S4: a malformed first line marks no card' "$(s4card 11)" 'STALE'
contains 'S4: a malformed first line reads stale: unknown' "$(cat "$s4out" 2>/dev/null)" 'stale: unknown'
s4render --stale-file "$s4/no-such-file" >/dev/null
contains 'S4: a missing stale file reads stale: unknown' "$(cat "$s4out" 2>/dev/null)" 'stale: unknown'
s4mk 15 '["phase:design","phase:build"]'
s4render --stale-file "$s4/stale-complete" >/dev/null
contains 'S4: two phase labels show both' "$(s4card 15)" 'phase:build'
contains 'S4: two phase labels show the multi mark' "$(s4card 15)" '<span class="phase multi">phase: 2 labels</span>'
rm -f "$s4/mirror/HIMMEL-15.md"
s4vfp() { s4render "$@" >/dev/null; cat "$s4out.vfp" 2>/dev/null; }
printf 'state\tcomplete\nHIMMEL-11\nHIMMEL-14\nHIMMEL-9999\n' > "$s4/stale-offpage"
printf 'state\tcomplete\nHIMMEL-11\nHIMMEL-14\nHIMMEL-12\n' > "$s4/stale-more"
s4base="$(s4vfp --stale-file "$s4/stale-complete")"
equals 'S4: two stale files that differ only in a key off this page give the same .vfp' "$(s4vfp --stale-file "$s4/stale-offpage")" "$s4base"
if [ "$(s4vfp --stale-file "$s4/stale-more")" != "$s4base" ]; then pass 'S4: adding a card key to the stale file changes the .vfp'; else fail 'S4: adding HIMMEL-12 to the stale file left the .vfp unchanged'; fi
s4mk 11 '["phase:last-step"]'
if [ "$(s4vfp --stale-file "$s4/stale-complete")" != "$s4base" ]; then pass 'S4: moving a card from phase:sliced to phase:last-step changes the .vfp'; else fail 'S4: a moved phase label left the .vfp unchanged'; fi
s4mk 11 '["phase:sliced"]'
fpargs=(--emit-fp --plan-dir "$plan" --out "$s4/fp.html" --luna-map "$W/luna-map.json" --mirror-dir "$s4/mirror" --luna-root "$W/luna" --handovers "$W/luna/handovers/tester/himmel")
s4fp1="$(python3 "$HERE/tracker.py" "${fpargs[@]}" 2>&1)"
s4fp2="$(python3 "$HERE/tracker.py" "${fpargs[@]}" --stale-file "$s4/stale-complete" 2>&1)"
equals 'S4: --emit-fp prints the same value with and without a stale file' "$s4fp2" "$s4fp1"
case "$s4fp1" in *error*|*usage*|'') fail "S4: --emit-fp gave no fingerprint: $s4fp1" ;; *) pass 'S4: --emit-fp prints a fingerprint' ;; esac

# a CLOSE-OR-DISPATCH drift row is the operator's close ask under Waiting on you
cod="$W/cod9561"
mkdir -p "$cod/mirror" "$cod/wk" "$cod/bucket/specs/designs"
codmk() { # <num> <status>
    printf '%s\n' '---' "key: \"HIMMEL-$1\"" 'updated: "2026-09-30T10:00:00.000+0000"' "statusCategory: \"$2\"" "status: \"$2\"" \
        'fixVersions: ["v1.1.3"]' 'labels: []' 'type: "Task"' '---' "# HIMMEL-$1: cod card $1" > "$cod/mirror/HIMMEL-$1.md"
}
codmk 21 "In Progress"; codmk 22 "In Progress"; codmk 23 "Done"; codmk 24 "In Progress"; codmk 25 "In Progress"
printf '[]\n' > "$cod/prs.json"
codout="$cod/page.html"
codrender() {
    rm -f "$codout" "$codout.vfp"
    python3 "$HERE/tracker.py" --version v1.1.3 --repo example-org/example-repo --mirror-dir "$cod/mirror" --prs-file "$cod/prs.json" \
        --workers-dir "$cod/wk" --out "$codout" "$@" 2>&1
}
cat > "$cod/bucket/focus-drift.txt" <<'EOF'
CLOSE-OR-DISPATCH HIMMEL-21 In Progress with no open PR, no live owner and no event since 2026-11-10T18:00:00Z (73 h); last PR #5155, owed: the timing row (DoD 1) | writer=jira | fix=x
CLOSE-OR-DISPATCH HIMMEL-23 In Progress with no open PR, no live owner and no event since 2026-11-10T18:00:00Z (73 h); last PR #5156, owed: done already | writer=jira | fix=x
CLOSE-OR-DISPATCH HIMMEL-99 In Progress with no open PR, no live owner and no event since 2026-11-10T18:00:00Z (73 h); last PR #5157, owed: another version | writer=jira | fix=x
CLOSE-OR-DISPATCH HIMMEL-24 In Progress with no open PR, no live owner and no event since 2026-11-10T18:00:00Z (80 h); no merged PR, owed: the chief's decision on the remainder | writer=jira | fix=x
CLOSE-OR-DISPATCH HIMMEL-25 In Progress with no open PR, no live owner and no event since 2026-11-10T18:00:00Z (75 h); last PR #5158, owed: a root reinstall step on the station | writer=jira | fix=x
UNOWNED HIMMEL-22 In Progress with no open PR and no live owner | writer=a | fix=b
sdrift=6:33333333
EOF
codrender --owed-dir "$cod/bucket" >/dev/null || fail '10189 the drift-row render exited non-zero'
codw="$(grep -F 'data-section="waiting"' "$codout" 2>/dev/null)"
codc="$(grep -F 'data-section="chief-owes"' "$codout" 2>/dev/null)"
contains '10189 a CLOSE-OR-DISPATCH row owing a chief step lists under Chief owes with the close-or-name-a-worker line' "$codc" 'close HIMMEL-21 or name a worker (last PR #5155, owed: the timing row (DoD 1))'
not_contains '10189 a CLOSE-OR-DISPATCH row owing a chief step is not under Waiting on you' "$codw" 'HIMMEL-21'
contains '10189 a no-PR row owing a chief decision lists under Chief owes' "$codc" 'close HIMMEL-24 or name a worker (no merged PR, owed: the chief'
not_contains '10189 a no-PR row owing a chief decision is not under Waiting on you' "$codw" 'HIMMEL-24'
contains '10189 control: a row whose owed text names a root step stays under Waiting on you' "$codw" 'close HIMMEL-25 or name a worker (last PR #5158, owed: a root reinstall step on the station)'
contains '10189 Waiting on you counts only the operator-class row' "$codw" 'data-count="1"'
contains '10189 Chief owes counts the two chief rows' "$codc" 'data-count="2"'
not_contains '9561 a Done ticket carrying the row is not listed' "$codw$codc" 'HIMMEL-23'
not_contains '9561 a ticket outside the version carrying the row is not listed' "$codw$codc" 'HIMMEL-99'
not_contains '9561 an UNOWNED row is not a close ask' "$codw$codc" 'HIMMEL-22'
rm -f "$cod/bucket/focus-drift.txt"
codrender --owed-dir "$cod/bucket" >/dev/null
not_contains '9561 control: with no such row nothing is asked' "$(grep -F -e 'data-section="waiting"' -e 'data-section="chief-owes"' "$codout" 2>/dev/null)" 'or name a worker'

hb="$cod/hbucket"
mkdir -p "$hb/specs/decisions"
hbfx() {
    printf '%s\n' '# handoff' '## Open operator items' '' "$1" '## Wrapped' 'none' > "$hb/HIMMEL-x-chief-HANDOFF.md"
    touch -t 202611151000.00 "$hb/HIMMEL-x-chief-HANDOFF.md"
    rm -f "$hb"/specs/decisions/verbatim-decision-*.txt
    [ -z "$2" ] || { printf '%s\n' "$2" > "$hb/specs/decisions/verbatim-decision-951-operator-11-15-AE.txt"; local d="${3//[-: ]/}"; touch -t "${d:0:12}.${d:12:2}" "$hb/specs/decisions/verbatim-decision-951-operator-11-15-AE.txt"; }
    codrender --owed-dir "$hb" >/dev/null || fail '10189 the HANDOFF render exited non-zero'
    hbw="$(grep -F 'data-section="waiting"' "$codout" 2>/dev/null)"
    hbc="$(grep -F 'data-section="chief-owes"' "$codout" 2>/dev/null)"
}
hbfx 'Asked on Telegram: "bypass 9980" and HIMMEL-8001 yes/no' 'Reading: the operator asks what "bypass 9980" means. HIMMEL-8001 is ruled.' '2026-11-15 10:30:00'
not_contains '10189 a HANDOFF item whose every key and quoted ask a newer decision file repeats is not under Waiting on you' "$hbw" 'bypass 9980'
contains '10189 that answered item moves to Chief owes, never dropped' "$hbc" 'bypass 9980'
hbfx 'Asked on Telegram: "bypass 9980" and HIMMEL-8001 yes/no' 'Reading: the operator asks what "bypass 9980" means.' '2026-11-15 10:30:00'
contains '10189 a HANDOFF item with a quoted ask repeated and a key not named stays under Waiting on you' "$hbw" 'bypass 9980'
hbfx 'Asked on Telegram: "merge the held PR" and HIMMEL-8001 yes/no' 'The operator ruled on HIMMEL-8001.' '2026-11-15 10:40:00'
contains '10189 a HANDOFF item whose key a newer decision names but whose other ask is not repeated stays under Waiting on you' "$hbw" 'merge the held PR'
not_contains '10189 that unanswered item is not under Chief owes' "$hbc" 'merge the held PR'
hbfx 'Asked on Telegram: "bypass 9980" and HIMMEL-8001 yes/no' 'Reading: the operator asks what "bypass 9980" means. HIMMEL-8001 is ruled.' '2026-11-15 09:00:00'
contains '10189 control: a decision file older than the HANDOFF does not answer its item' "$hbw" 'bypass 9980'
hbfx 'Asked on Telegram: "an ask no decision repeats"' '' ''
contains '10189 control: a HANDOFF item no newer decision answers stays under Waiting on you' "$hbw" 'an ask no decision repeats'
hbfx 'move the obsidian key out of the codex config' 'Decision 951. move the obsidian key out of the codex config.' '2026-11-15 10:30:00'
contains '10189 control: a HANDOFF item with no key and no quoted ask is never answered' "$hbw" 'obsidian key'
hbfx 'Waiting on the operator for HIMMEL-8002 sign-off' 'The operator ruled on HIMMEL-8002.' '2026-11-15 10:30:00'
contains '10357 a HANDOFF item with a key and no quoted ask stays under Waiting on you when a newer decision names the key' "$hbw" 'HIMMEL-8002 sign-off'
not_contains '10357 that key-only item is not under Chief owes' "$hbc" 'HIMMEL-8002 sign-off'

printf '%s\n' '# chief' '## Live state' 'queue: HIMMEL-21 operator-owed lines remain | HIMMEL-25 operator words: the sudo root reinstall' 'pool-disposition: HIMMEL-24 close decision 847 operator-owed: proof verdict' > "$cod/chief.md"
codrender --owed-dir "$cod/bucket" --chief-doc "$cod/chief.md" >/dev/null || fail '10189 the Live-state render exited non-zero'
codw="$(grep -F 'data-section="waiting"' "$codout" 2>/dev/null)"
codc="$(grep -F 'data-section="chief-owes"' "$codout" 2>/dev/null)"
contains '10189 a Live-state operator-owed line with no operator class lists under Chief owes' "$codc" 'HIMMEL-21 operator-owed lines remain'
not_contains '10189 a Live-state operator-owed line with no operator class is not under Waiting on you' "$codw" 'operator-owed lines remain'
contains '10189 a pool-disposition operator-owed line with no operator class lists under Chief owes' "$codc" 'proof verdict'
contains '10189 control: a Live-state line naming a root step stays under Waiting on you' "$codw" 'the sudo root reinstall'
printf '%s\n' '# chief' '## Live state' \
    'pool-disposition: HIMMEL-31 operator words: someone must physically swap the drive' \
    'pool-disposition: HIMMEL-32 operator words: create the two accounts' \
    'pool-disposition: HIMMEL-33 operator words: edit the sudoers file' \
    'pool-disposition: HIMMEL-34 operator words: accept the ToS' \
    'pool-disposition: HIMMEL-35 operator words: needs the admin install' \
    'pool-disposition: HIMMEL-36 operator words: the OAuth login' \
    'pool-disposition: HIMMEL-37 operator words: top up the API credit' \
    'pool-disposition: HIMMEL-38 operator words: waiting for the chief' \
    'pool-disposition: HIMMEL-39 operator words: suspend the idle worker' > "$cod/chief.md"
codrender --owed-dir "$cod/bucket" --chief-doc "$cod/chief.md" >/dev/null || fail '10189 the word-form render exited non-zero'
codw="$(grep -F 'data-section="waiting"' "$codout" 2>/dev/null)"
codc="$(grep -F 'data-section="chief-owes"' "$codout" 2>/dev/null)"
contains '10189 operator class: physically stays under Waiting on you' "$codw" 'physically swap the drive'
contains '10189 operator class: accounts stays under Waiting on you' "$codw" 'create the two accounts'
contains '10189 operator class: sudoers stays under Waiting on you' "$codw" 'edit the sudoers file'
contains '10189 operator class: ToS stays under Waiting on you' "$codw" 'accept the ToS'
contains '10189 operator class: admin install stays under Waiting on you' "$codw" 'needs the admin install'
contains '10189 operator class: OAuth login stays under Waiting on you' "$codw" 'the OAuth login'
contains '10189 operator class: API credit stays under Waiting on you' "$codw" 'top up the API credit'
contains '10189 control: a line naming no operator class goes to Chief owes' "$codc" 'waiting for the chief'
not_contains '10189 control: that line is not under Waiting on you' "$codw" 'waiting for the chief'
contains '10189 a line with suspend and no operator class goes to Chief owes' "$codc" 'suspend the idle worker'
not_contains '10189 spend does not match inside suspend: that line is not under Waiting on you' "$codw" 'suspend the idle worker'

# --- both pages open dark with no saved choice, whatever the system preference says
if command -v node >/dev/null 2>&1; then
cat > "$W/dark-check.mjs" <<'JS'
// dark-check.mjs <page.html> <bg var> <text var> <muted var>: DARK-OK when the page's first :root rule (no saved
// choice) is a dark palette with readable text (WCAG contrast 4.5 for text and muted), no prefers-color-scheme: light
// query flips it back, and a saved light choice still has its [data-theme="light"] rule.
import { readFileSync } from 'node:fs';
const [file, bgV, textV, mutedV] = process.argv.slice(2);
const html = readFileSync(file, 'utf8');
const root = /:root\s*\{([^}]*)\}/.exec(html);
const val = (v) => { const m = root && new RegExp(`${v}\\s*:\\s*(#[0-9a-fA-F]{3,6})`).exec(root[1]); return m && m[1]; };
const lum = (h) => { h = h.slice(1); if (h.length === 3) h = [...h].map((c) => c + c).join('');
    const c = [0, 2, 4].map((i) => parseInt(h.slice(i, i + 2), 16) / 255).map((x) => (x <= 0.03928 ? x / 12.92 : ((x + 0.055) / 1.055) ** 2.4));
    return 0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2]; };
const ratio = (a, b) => { const [x, y] = [lum(a), lum(b)].sort((p, q) => q - p); return (x + 0.05) / (y + 0.05); };
const [bg, text, muted] = [bgV, textV, mutedV].map(val);
const why = [];
if (!bg || !text || !muted) why.push(`missing ${[bgV, textV, mutedV].filter((v) => !val(v)).join(',')} in the first :root rule`);
else {
    if (lum(bg) > 0.1) why.push(`background ${bg} is light`);
    if (ratio(text, bg) < 4.5) why.push(`text ${text} on ${bg} is ${ratio(text, bg).toFixed(2)}`);
    if (ratio(muted, bg) < 4.5) why.push(`muted ${muted} on ${bg} is ${ratio(muted, bg).toFixed(2)}`);
}
if (/prefers-color-scheme\s*:\s*light/.test(html)) why.push('a prefers-color-scheme: light query flips the page');
if (!/:root\[data-theme="light"\]/.test(html)) why.push('no :root[data-theme="light"] rule');
console.log(why.length ? `DARK-BAD ${why.join('; ')}` : `DARK-OK bg=${bg} text=${ratio(text, bg).toFixed(1)} muted=${ratio(muted, bg).toFixed(1)}`);
JS
contains 'the tracker page opens dark with readable text and a light choice still works' "$(node "$W/dark-check.mjs" "$W/workers.html" --bg --fg --dim)" 'DARK-OK'
contains 'the version page opens dark with readable text and a light choice still works' "$(node "$W/dark-check.mjs" "$vout" --bg --fg --muted)" 'DARK-OK'
else
    printf 'skip - node not available: dark default contrast rows\n'
fi

# Shared fixtures exercise the actual readers without live sources.
if python3 -B - "$HERE" "$W" <<'PYTEST'
import importlib.util, json, os, pathlib, sys
here, scratch = map(pathlib.Path, sys.argv[1:])
spec = importlib.util.spec_from_file_location('tracker', here / 'tracker.py')
t = importlib.util.module_from_spec(spec); spec.loader.exec_module(t)
f = json.loads((here / 'fixtures/t1-views.json').read_text())
for r in f['statuses']:
    got = t.bucket({'sn': r['status'], 'cat': r['category'], 'res': ''})
    assert got == r['bucket'], (r, got)
assert t.bucket({'sn': 'Done', 'cat': 'Done', 'res': 'Duplicate'}) == 'wont'
b = scratch / 't1-views'; d = b / 'specs/designs'; d.mkdir(parents=True)
for r in f['specs']:
    (d / (r['key'] + '-fixture.md')).write_text('# spec\n' + r['marker'])
    (d / (r['key'] + '-fixture.md.critic-spec-r1.md')).write_text('SPEC CLEAN\n')
t.round_status_all = lambda _: {'cap': 3, 'classes': ['spend-grant', 'account-or-terms', 'public-policy', 'reverses-ruling'], 'keys': {r['key']: {'spec': 1} for r in f['specs']}}
(b / 'chief-HANDOFF.md').write_text('## Open operator items\n- <placeholder>\n')
lines = [r['key'] + ' hold fixture' for r in f['holds']]
doc = b / 'chief.md'
doc.write_text('## Live state\nqueue: ' + ' | '.join(r['key'] + ' ' + r['text'] for r in f['queue']) + '\n' + '\n'.join('pool-disposition: ' + l for l in lines))
state = pathlib.Path(os.environ['TICK_STATE_DIR']); state.mkdir(exist_ok=True)
(state / 'pool-holds-chief.json').write_text(json.dumps({'rows': [dict(r, verb='hold', line=t.hashlib.sha256(l.encode()).hexdigest()[:12]) for r, l in zip(f['holds'], lines)]}))
opn = {int(r['key'][7:]): {'title': r['key']} for r in f['specs']}
items, read, unread, chief, holds_unread = t.operator_owed(str(b), str(doc), 'v1.1.2', opn, {})
for source, rows in [('unsigned spec', f['specs']), ('chief doc', f['queue']), ('pool hold', f['holds'])]:
    got = {('HIMMEL-%d' % row[1]): getattr(row, 'actor', actor) for group, actor in [(items, 'operator'), (chief, 'chief')] for row in group if row[0] == source}
    assert got == {r['key']: r['actor'] for r in rows}, (source, got)
assert not any(r[0] == 'handoff' for r in items + chief), 'untouched placeholder became an obligation'
(d / 'HIMMEL-7-fixture.md').write_bytes(b'\xff')
items, _, unread, chief, _ = t.operator_owed(str(b), str(doc), 'v1.1.2', opn, {})
assert next(r for r in chief if r[0] == 'unsigned spec' and r[1] == 7).actor == 'unknown'
assert 'HIMMEL-7-fixture.md' in unread
from types import SimpleNamespace
t.subprocess.run = lambda *a, **kw: SimpleNamespace(returncode=0, stdout="HIMMEL-1\tTask\tTo Do\tt\nHIMMEL-2\tTask\tWon’t Fix\tt\nHIMMEL-3\tTask\tResolved\tt\n")
parity = t.jira_parity([{'k': 1, 'b': 'todo', 's': 'To Do', 'v': 0}, {'k': 3, 'b': 'done', 's': 'Resolved', 'v': 0}], [{'n': 'v1.1.3'}], 0)
assert ' ok 1/0/0/1' in parity, parity
print('PASS shared T1 ownership and status fixtures')
PYTEST
then pass 'T1 shared responsibility and status parity'; else fail 'T1 shared responsibility and status parity'; fi

printf '%s\n' "$fails failure(s)"
[ "$fails" -eq 0 ]
