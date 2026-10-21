#!/usr/bin/env bash
# test-tracker.sh — Hermetic tests for tracker.py's outside-the-plan
# sections and the ledger's unplanned count: no "Closed by roadmap" section, park-ns
# closures render in "Parked / unplaced", and only OPEN unplanned tickets are counted.
# row fields, legend, ledger wording, plan-sourced caps, Done off-plan
# work counting in its version, and distinct load / layer palettes.
# the redesign — rows lead with user impact, numbers drill down, a
# remaining-only switch, live legs; tracker-model-check.js runs the page's model.
# Synthetic plan dir + mirror under a mktemp dir; no real plan data, no network.
#
# PLATFORM GUARD: no .ps1 twin, by design. The console kit is Linux-only
# (see test-tick.sh); this suite renders one static page with python3.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
W="$(mktemp -d "${TMPDIR:-/tmp}/tracker-test.XXXXXX")" || exit 1
trap 'rm -rf "$W"' EXIT
fails=0
# the parity check's Jira CLI: every render here reads a CLI that fails, unless a row names another.
printf '#!/bin/sh\nexit 1\n' > "$W/nojira"
chmod +x "$W/nojira"
export TRACKER_JIRA="$W/nojira"

pass() { printf 'ok - %s\n' "$1"; }
fail() { printf 'FAIL - %s\n' "$1"; fails=$((fails + 1)); }
contains() {
    case "$2" in *"$3"*) pass "$1" ;; *) fail "$1 (missing '$3')" ;; esac
}
not_contains() {
    case "$2" in *"$3"*) fail "$1 (found '$3')" ;; *) pass "$1" ;; esac
}

if ! command -v python3 >/dev/null 2>&1; then
    printf 'skip - python3 not available\n'
    exit 0
fi

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
# HIMMEL-2 is parked by the roadmap, HIMMEL-3 is closed-by-roadmap (likely-fixed).
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
# A `## Impact` inside a code fence is not a heading: HIMMEL-1 keeps its explain-sidecar impact line.
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
        pass "$(basename "$f") ends in exactly one newline (HIMMEL-4468)"
    else
        fail "$(basename "$f") does not end in exactly one newline (HIMMEL-4468)"
    fi
done
not_contains 'no Closed-by-roadmap section (HIMMEL-3954)' "$html" 'Closed by roadmap'
contains 'the park-ns key renders in the page data (HIMMEL-3954)' "$html" '"parked ticket"'
contains 'the park-ns evidence is the parked reason (HIMMEL-3954)' "$html" 'parked evidence text'
contains 'the unplaced row still renders' "$html" 'unplaced reason text'
contains 'a ticket the plan pins to its version is listed as pinned (HIMMEL-3990)' "$html" '"PIN":[1]'
not_contains 'a non-park closure is not rendered' "$html" 'fixed evidence text'
contains 'summary counts 2 unplaced (1 unplaced + 1 parked)' "$stdout" '2 unplaced'
# Done HIMMEL-5 is unplanned but not counted; open HIMMEL-6 and in-progress HIMMEL-7 are.
contains 'summary counts only open unplanned tickets (HIMMEL-3954)' "$stdout" ', 2 unplanned,'
contains 'the Done unplanned ticket still renders in its version tab data' "$html" '"done unplanned"'
# unplanned is a flag (row field 7 = 2), never a theme; a ticket with no theme is counted and flagged.
not_contains 'no "(unplanned)" theme in the page data (HIMMEL-4930)' "$html" '(unplanned)'
contains 'summary counts the open tickets that have no sector (HIMMEL-6483)' "$stdout" ', 1 unthemed,'
contains 'the ledger flags open tickets with no sector (HIMMEL-6483)' "$stdout" '1 open ticket has no sector'

# --- design pass.
# Ask 1: a row carries user impact, the effort range, readiness, impact, issue_plain and its load (P columns).
contains 'a row carries user impact, effort range, readiness, impact, plain issue, load (HIMMEL-3990)' "$html" \
    '"operators lose the synthetic widget on restart","M–L",3,4,"","plain text",0.009]'
contains 'a ticket with a plain Impact block shows it as the impact line (HIMMEL-5226)' "$html" \
    '"Operators see a blank page after the nightly restart. It happens once a day."'
contains 'a decorated Impact heading is read as the impact line (HIMMEL-5226)' "$html" \
    '"Decorated heading impact line."'
not_contains 'the impact line stops at the next heading (HIMMEL-5226)' "$html" 'We reload the page data on start.'
not_contains 'the impact line stops at any other heading (HIMMEL-5226)' "$html" 'Background text must not leak.'
not_contains 'a fenced Impact heading is not read (HIMMEL-5226)' "$html" 'Fenced fake impact.'
not_contains 'a hash run with no space is not an Impact heading (HIMMEL-5226)' "$html" 'Nospace impact must not show.'
contains 'the row leads with the user impact (HIMMEL-3990)' "$html" 'add(tx,impactText(p,el("span","ui")),sub)'
contains 'readiness reads in words (HIMMEL-3990)' "$html" '"fix named, not yet checked"'
contains 'impact is a secondary 5-dot tag (HIMMEL-3990)' "$html" '"impact "+n+" of 5"'
contains 'the notes list is labelled vault notes (HIMMEL-3990)' "$html" 'Vault notes that mention it:'
# Ask 2: the terms name every scale.
for s in 'Status' 'Leg chip' 'Size' 'Impact' 'Ready to build' 'Budget' 'No cap' 'Hide done work'; do
    contains "the terms name $s (HIMMEL-3990)" "$html" "[\"$s\","
done
contains 'the size scale comes from the plan (HIMMEL-3957)' "$html" 'XS 0.44 · S 1 · M 2.2 · L 5 · XL 11.1'
# Ask 3: the ledger wording, built in Python (Done unplanned HIMMEL-5 counts in v1.0.1: ask 5).
contains 'the ledger names the running version with its progress; Done unplanned counts (HIMMEL-3957)' "$stdout" \
    'Plan rows placed in v1.0.1 (not Jira progress): 1 of 4 done (25 %), 1 in progress, 2 to do.'
contains 'the ledger gives whole-train progress (HIMMEL-3957)' "$stdout" \
    'Plan rows placed in the whole v1.0.x train (not Jira progress): 1 of 4 done (25 %), 1 in progress, 2 to do.'
contains 'the ledger names open unplanned work when non-zero (HIMMEL-3957)' "$stdout" \
    'Needs attention: 2 open tickets sit in a version but not in the plan; 1 open ticket has no sector.'
not_contains 'the ledger omits drift when it is zero (HIMMEL-3957)' "$stdout" 'drifted'
not_contains 'the page data carries no plan ledger: it is not Jira progress (HIMMEL-6401)' "$html" '"LG":'
# Ask 5: a Done off-plan ticket still counts in its version; off-plan work adds no budget.
contains 'off-plan tickets add no budget (HIMMEL-3990)' "$html" 'function ld(p){return p[7]==2?0:(p[15]||0)}'
contains 'off-plan tickets are named in words (HIMMEL-3990)' "$html" '"Not in the plan: Jira puts it in "'
# Ask 4: the capacity text comes from the plan, never a constant.
contains 'cap text: ticket cap from the plan (HIMMEL-3957)' "$html" 'at most 20 tickets'
contains 'cap text: total cap from the plan (HIMMEL-3957)' "$html" 'at most 0.6 bank of load'
contains 'cap text: layer caps from the plan (HIMMEL-3957)' "$html" 'bugs 0.30'
contains 'cap text: load derivation from the plan (HIMMEL-3957)' "$html" '× 0.009 bank'
not_contains 'the JS no longer hardcodes the cap (HIMMEL-3957)' "$html" 'CAP=0.6'
write_meta 15 0.45
write_caps 0.25
render >/dev/null
html2="$(cat "$out" 2>/dev/null)"
contains 'a changed ticket cap changes the text (HIMMEL-3957)' "$html2" 'at most 15 tickets'
contains 'a changed total cap changes the text (HIMMEL-3957)' "$html2" 'at most 0.45 bank of load'
contains 'a changed layer cap changes the text (HIMMEL-3957)' "$html2" 'bugs 0.25'
rm -f "$plan/tools/stage3/place.py"
printf '%s\n' '{"main_sha_at_build":"abcdef123456"}' > "$plan/stage3/meta.json"
render >/dev/null
html3="$(cat "$out" 2>/dev/null)"
contains 'a cap the plan does not record says so (HIMMEL-3957)' "$html3" 'not recorded in the plan'
write_meta 20 0.6
write_caps 0.30
# the page contract — tokens for both themes, phone layout, keyboard-reachable drill-downs.
contains 'light tokens follow the system (HIMMEL-3990)' "$html" '@media (prefers-color-scheme:light){:root:not([data-theme="dark"])'
contains 'light tokens follow the toggle (HIMMEL-3990)' "$html" ':root[data-theme="light"]{'
contains 'the phone layout has its own rules (HIMMEL-3990)' "$html" '@media (max-width:560px)'
contains 'every number is a button (HIMMEL-3990)' "$html" 'var b=el("button","n",label);b.type="button";'
contains 'the drill-down is a modal dialog (HIMMEL-3990)' "$html" 'role="dialog" aria-modal="true"'
contains 'Escape closes the drill-down (HIMMEL-3990)' "$html" 'if(e.key=="Escape"){e.preventDefault();closeDrill();return}'
contains 'closing returns focus to the number (HIMMEL-3990)' "$html" 'opener.focus()'
contains 'the pulse respects reduced motion (HIMMEL-3990)' "$html" '@media (prefers-reduced-motion:no-preference)'
contains 'caps are tested by null, never truthiness: a cap of 0 is a cap (HIMMEL-3957)' "$html" 'cap==null?null:r4(cap-u)'
not_contains 'the page has no column chart (HIMMEL-3990)' "$html" 'renderChart'
contains 'the status legend names the five Jira statuses (HIMMEL-3990)' "$html" '["todo","To Do"],["prog","In Progress"],["rev","In Review"],["ci","IN CI"],["done","Done"]'
not_contains 'the steer panel waits for the UI phase (HIMMEL-3990)' "$html" 'renderSteer'
contains 'the estimate-vs-actual fold shows each size against what finished work took (HIMMEL-3990)' "$html" 'fmtMin(x.med)+" · "+pl(x.legs,"leg","legs")'
not_contains 'no Plan decisions section (HIMMEL-6483)' "$html" 'Plan decisions that need your input'
not_contains 'no What users gained section (HIMMEL-6483)' "$html" 'What users gained'
not_contains 'no Plan vs Jira section (HIMMEL-6483)' "$html" 'Plan vs Jira'
contains 'the themes fold is Sectors (HIMMEL-6483)' "$html" 'Sectors in the running version'
contains 'a sector in the mirror frontmatter groups the ticket (HIMMEL-6483)' "$html" '"Visibility"'
contains 'a ticket with no sector groups under (no sector) (HIMMEL-6483)' "$html" '"(no sector)"'
contains 'a nested drill keeps the first opener (HIMMEL-3990)' "$html" '"drawer").hidden)opener=from;'
# The new plan inputs move the freshness fingerprint; each render must itself succeed.
# fp_ok <label> <var> [render args] -- render --emit-fp into <var>, failing the test when the render exits non-zero.
fp_ok() {
    local o rc
    o="$(render --emit-fp "${@:3}")"
    rc=$?
    if [ "$rc" -eq 0 ]; then pass "$1: --emit-fp exits 0 (HIMMEL-3979)"; else fail "$1: --emit-fp exited $rc"; fi
    printf -v "$2" '%s' "$o"
}
fp1='' fp2='' fp3='' fp4='' fp5='' fp6='' fp7=''  # each set by fp_ok through printf -v
fp_ok 'base' fp1
printf '%s\t%s\t%s\t%s\n' key readiness effort_low effort_high HIMMEL-1 4 M L > "$plan/stage2/C01.tsv"
fp_ok 'stage2 edit' fp2
if [ -n "$fp1" ] && [ "$fp1" != "$fp2" ]; then pass 'a stage2 change moves the fingerprint (HIMMEL-3957)'; else fail "a stage2 change left the fingerprint at '$fp1'"; fi
printf '%s\t%s\t%s\n' key user_impact issue_plain HIMMEL-1 'changed impact' 'plain' > "$plan/stage1/C01.explain.tsv"
fp_ok 'explain edit' fp3
if [ "$fp2" != "$fp3" ]; then pass 'an explain change moves the fingerprint (HIMMEL-3957)'; else fail "an explain change left the fingerprint at '$fp2'"; fi

# --- neutral swatch for no-cap load, per-version caps from the plan's overrides.
contains 'no-cap load has its own neutral token (HIMMEL-3979)' "$html" '--ldn:'
contains 'the legend names the no-cap swatch (HIMMEL-3979)' "$html" '"no cap — deferred bucket"'
printf '%s\n' "VERSION_CAP_OVERRIDES = {'v1.0.1': {'tickets': 30, 'bugs': 0.45}}" > "$plan/tools/stage3/common.py"
render >/dev/null
html4="$(cat "$out" 2>/dev/null)"
contains 'a version cap override sets that version ticket cap (HIMMEL-3979)' "$html4" '"VC":[{"t":30,'
contains 'a version cap override sets that version layer cap (HIMMEL-3979)' "$html4" '"l":[0.45,'
contains 'the cap text names the override (HIMMEL-3979)' "$html4" 'v1.0.1 holds at most 30 tickets'
contains 'the deferred bucket has no caps (HIMMEL-3979)' "$html4" '},null]'
fp_ok 'override edit' fp4
if [ "$fp3" != "$fp4" ]; then pass 'a cap override change moves the fingerprint (HIMMEL-3979)'; else fail 'a cap override change left the fingerprint'; fi
# Multi-line dict literals parse too, as the old [^}]* pattern allowed for CAPS.
printf '%s\n' '# synthetic placer' 'CAPS = {' "    'features': 0.10, 'bugs': 0.33," "    'enhancements': 0.12, 'audit': 0.03, 'misc': 0.05," '}' \
    > "$plan/tools/stage3/place.py"
printf '%s\n' 'VERSION_CAP_OVERRIDES = {' "    'v1.0.1': {'tickets': 31}," '}' > "$plan/tools/stage3/common.py"
render >/dev/null
html5="$(cat "$out" 2>/dev/null)"
contains 'a multi-line CAPS literal still sets the layer caps (HIMMEL-3990)' "$html5" '"l":[0.33,'
contains 'a multi-line override literal still sets the ticket cap (HIMMEL-3990)' "$html5" '"VC":[{"t":31,'
write_caps 0.30
printf '%s\n' "VERSION_CAP_OVERRIDES = {'v1.0.1': {'tickets': 30, 'bugs': 0.45}}" > "$plan/tools/stage3/common.py"

# --- ask 5: a live leg marks its ticket in progress, with its label and phase.
hb="$W/luna/handovers"
bk="$hb/tester/himmel"
mkdir -p "$bk" "$hb/.locks/queue/live.lock" "$hb/.locks/queue/gone.lock" "$hb/.locks/queue/brief.lock"
now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
printf '%s\n' '# leg' '- brief: follows PR 1999' '## Results' '- 10:00 LIVE — started' '- 10:20 LIVE — PR 1525 open, watching CI' '- a later note naming PR 1998' >"$bk/HIMMEL-1-N55-synthetic-leg-2026-10-01.md"
printf '%s\n' '# leg' '## Results' '- 09:00 READY 1600 abc GREEN' '- 09:30 WRAPPED — merged' > "$bk/HIMMEL-6-N56-wrapped-leg-2026-10-01.md"
printf '%s\n' '# leg' '## Results' '- 08:00 LIVE — started' > "$bk/HIMMEL-7-N57-released-leg-2026-10-01.md"
printf '%s\n' '# leg' '## Results' '- 08:00 LIVE — started' '- 12:00 LIVE — back after a night' '- 12:10 WRAPPED — merged' > "$bk/HIMMEL-6-N60-second-leg-2026-10-01.md"
printf '%s\n' '# leg' '- 08:00 brief note, not a Results bullet' '## Results' '- 09:00 LIVE — started' '- 09:10 WRAPPED — merged' > "$bk/HIMMEL-8-N61-brief-stamp-leg-2026-10-01.md"
printf '%s\n' '# leg' '- READY 1997 abc GREEN is the shape to send' '## Results' '- a note, no marker' > "$bk/HIMMEL-9-N59-brief-leg-2026-10-01.md"
printf '{"session":"s3","handover":"%s","heartbeat":"%s"}\n' "$bk/HIMMEL-9-N59-brief-leg-2026-10-01.md" "$now" > "$hb/.locks/queue/brief.lock/owner.json"
printf '{"session":"s1","handover":"%s","heartbeat":"%s"}\n' "$bk/HIMMEL-1-N55-synthetic-leg-2026-10-01.md" "$now" > "$hb/.locks/queue/live.lock/owner.json"
printf '{"session":"s2","handover":"%s","heartbeat":"%s"}\n' "$bk/HIMMEL-6-N56-wrapped-leg-2026-10-01.md" "$now" > "$hb/.locks/queue/gone.lock/owner.json"
fp_ok 'legs added' fp5
stdout6="$(render)"
html6="$(cat "$out" 2>/dev/null)"
cp "$out" "$W/legs.html"
contains 'a held-lock leg doc marks its ticket live with label, phase and PR (HIMMEL-3990)' "$html6" '"LEG":{"1":["N55","LIVE",1525]'
not_contains 'a WRAPPED leg is not live even while its lock lingers (HIMMEL-3990)' "$html6" '"6":["N56"'
not_contains 'a leg doc with no held lock is not live (HIMMEL-3990)' "$html6" '"7":["N57"'
contains 'a marker-shaped brief bullet above Results sets neither phase nor PR (HIMMEL-3990)' "$html6" '"9":["N59","LIVE",null]'
printf '%s\n' '# leg' '## Results' '- 08:00 LIVE — started' '- 08:30 PARKED-USAGE — committed, waiting for RESUME' > "$W/parked-usage-leg.md"
contains 'a PARKED-USAGE tail is the leg phase, not the earlier LIVE' "$(python3 -c 'import sys; sys.path.insert(0, sys.argv[1]); import tracker; print(tracker.leg_marker(sys.argv[2])[0])' "$HERE" "$W/parked-usage-leg.md")" 'PARKED-USAGE'
contains 'a wrapped leg counts toward what its ticket took: [legs, wall, active, dated]; a gap over 3 h is idle, not active (HIMMEL-5453)' "$html6" '"ACT":{"6":[2,280,40,2]'
contains 'a timestamped line above ## Results is not counted as work (HIMMEL-4441)' "$html6" '"8":[1,10,10,1]'
contains 'the actuals carry the newest wrapped-leg doc stamp (HIMMEL-4930)' "$html6" '"ATS":"20'
contains 'the live leg counts its ticket in progress in the ledger (HIMMEL-3990)' "$stdout6" '1 of 4 done (25 %), 2 in progress, 1 to do.'
if [ "$fp4" != "$fp5" ]; then pass 'a leg starting moves the fingerprint (HIMMEL-3990)'; else fail 'a leg starting left the fingerprint'; fi
printf '%s\n' '- 10:40 READY 1525 abc GREEN' >> "$bk/HIMMEL-1-N55-synthetic-leg-2026-10-01.md"
fp_ok 'leg phase moved' fp6
if [ "$fp5" != "$fp6" ]; then pass 'a leg phase change moves the fingerprint (HIMMEL-3990)'; else fail 'a leg phase change left the fingerprint'; fi
fp_ok 'leg phase unchanged' fp7
if [ "$fp6" = "$fp7" ]; then pass 'the fingerprint is stable when nothing moved (HIMMEL-3990)'; else fail 'the fingerprint moved with no input change'; fi
rm -rf "$hb/.locks/queue/live.lock"
render >/dev/null
not_contains 'a released lock clears the live leg (HIMMEL-3990)' "$(cat "$out")" '"1":["N55"'

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
contains 'trail versions sort after their parent, numerically (HIMMEL-3990)' "$html7" '"V":["v1.0.1","v1.0.1b","v1.0.2","v1.0.10","v2/v3"]'
contains 'a trail inherits its parent override (HIMMEL-3990)' "$html7" \
    '"VC":[{"t":30,"tot":0.6,"l":[0.45,0.12,0.1,0.05,0.03],"p9":0.8},{"t":30,"tot":0.6,"l":[0.45,0.12,0.1,0.05,0.03],"p9":0.8},{"t":20,'
contains 'a Jira fixVersion naming a trail counts in that trail (HIMMEL-3990)' "$html7" '[11,"trail unplanned",0,1,'
contains 'the cap text says a trail keeps its parent caps (HIMMEL-3990)' "$html7" 'takes the overflow of v1.0.1 and keeps its caps'
contains 'the page carries each version P90 (HIMMEL-3990)' "$html7" '"VP":[0.7,0.05,null,null,null]'
contains 'the cap text names the cautious-load cap (HIMMEL-3990)' "$html7" 'cautious load'
contains 'the drawer words P90 as cautious load (HIMMEL-3990)' "$html7" '"Cautious load "'
printf '%s\n' "VERSION_CAP_OVERRIDES = {'v1.0.1': {'tickets': 30, 'bugs': 0.45}, 'v1.0.1b': {'tickets': 5}}" > "$plan/tools/stage3/common.py"
render >/dev/null
contains 'a trail named in the overrides takes only its own (HIMMEL-3990)' "$(cat "$out")" '},{"t":5,"tot":0.6,"l":[0.3,'
printf '%s\n' "VERSION_CAP_OVERRIDES = {'v1.0.1': {'tickets': 30, 'bugs': 0.45}}" > "$plan/tools/stage3/common.py"
# Effort model B words its rules differently and carries the bank rate in effort_model.
printf '%s\n' '{"main_sha_at_build":"abcdef123456","effort_model":{"p90_cap":0.8,"bank_per_seq":0.009},"notes":["effort S-eq: XS .44 S 1 M 2.2 L 5 XL 11.1; synthetic","load (bank) = median x exp(sigma^2/2) x 0.009 bank per S-eq (the log-normal MEAN)","a version holds < 18 tickets, layer load within cap, total mean load within 0.55 and P90 within the model cap"]}' \
    > "$plan/stage3/meta.json"
# Under model B a plan-first row's effort_mid already holds its slice mean (XS 0.44 plus overrun = 0.49).
printf '%s\t%s\t%s\t%s\t%s\t%s\n' key version layer effort_mid commit slice_effort HIMMEL-1 v1.0.1 bugs 1 committed '' \
    HIMMEL-8 v1.0.1b bugs 0.49 plan-first XS > "$plan/stage3/placement.tsv"
render >/dev/null
html8="$(cat "$out" 2>/dev/null)"
contains 'model B: a plan-first row loads the placer slice mean, as the placer sums it (HIMMEL-3990)' "$html8" '"XS","",0.0044]'
contains 'model B wording: the ticket cap (HIMMEL-3990)' "$html8" 'at most 18 tickets'
contains 'model B wording: the mean load cap (HIMMEL-3990)' "$html8" 'at most 0.55 bank of load'
contains 'model B wording: the bank rate, overruns included (HIMMEL-3990)' "$html8" 'overruns included, × 0.009 bank'
contains 'model B wording: a row loads its mean effort (HIMMEL-3990)' "$html8" '"changed impact","M–L",4,4,"","plain",0.009]'
write_meta 20 0.6

# --- the page's model — drill-downs, budget by kind and ticket, summaries, remaining-only.
if command -v node >/dev/null 2>&1; then
    mo="$(node "$HERE/tracker-model-check.js" "$W/legs.html" 2>&1)"
    printf '%s\n' "$mo" | grep -v 'failure(s)$'
    if grep -qx '0 failure(s)' <<< "$mo"; then pass 'the model checks pass (HIMMEL-3990)'; else fail 'the model checks pass (HIMMEL-3990)'; fi
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
contains 'a v1.0.1a ticket renders (HIMMEL-4026)' "$thtml" '"trail a ticket"'
contains 'a v1.0.2b ticket renders (HIMMEL-4026)' "$thtml" '"trail b ticket"'
contains 'trail versions sit in train order (HIMMEL-4026)' "$thtml" '"v1.0.1","v1.0.1a","v1.0.1b","v1.0.2","v1.0.2b"'
contains 'the whole-train ledger counts trail tickets (HIMMEL-4026)' "$tstdout" 'Plan rows placed in the whole v1.0.x train (not Jira progress): 1 of 8 done'
contains 'the JS train test accepts a trail suffix (HIMMEL-4026)' "$thtml" '\d+[a-z]?$/.test(V[i])'

# --- the v1.1.x line (ex v1.0.2b..h) is train, sorted right after v1.0.2 and before v1.0.3.
cp "$plan/stage3/versions.tsv" "$W/versions.tsv.keep"
printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' version load_bugs load_enhancements load_features load_misc load_audit load_total est_legs \
    v1.0.1 0.1 0 0 0 0 0.1 1 v1.0.1a 0 0 0 0 0 0 0 v1.0.1b 0.01 0 0 0 0 0.01 1 v1.0.2 0 0 0 0 0 0 0 v1.0.3 0 0 0 0 0 0 0 v1.1.0 0 0 0 0 0 0 0 v2/v3 0 0 0 0 0 0 0 > "$plan/stage3/versions.tsv"
mk 14 'To Do' '["v1.1.0"]' 'minor line ticket'
tstdout="$(render)"
thtml="$(cat "$out" 2>/dev/null)"
contains 'a v1.1.0 ticket renders (HIMMEL-4872)' "$thtml" '"minor line ticket"'
contains 'v1.1.x sits between v1.0.2 and v1.0.3 (HIMMEL-4872)' "$thtml" '"v1.0.2","v1.1.0","v1.0.3"'
contains 'the whole-train ledger counts v1.1.x (HIMMEL-4872)' "$tstdout" 'Plan rows placed in the whole v1.0.x train (not Jira progress): 1 of 8 done'
cp "$W/versions.tsv.keep" "$plan/stage3/versions.tsv"; rm -f "$mdir/HIMMEL-14.md"

# --- the milestone minors v1.2.0..v1.7.0 are train too, in numeric order after the v1.1.x line.
printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' version load_bugs load_enhancements load_features load_misc load_audit load_total est_legs \
    v1.0.1 0.1 0 0 0 0 0.1 1 v1.0.1a 0 0 0 0 0 0 0 v1.0.1b 0.01 0 0 0 0 0.01 1 v1.0.2b 0 0 0 0 0 0 0 v1.1.0 0 0 0 0 0 0 0 v1.7.0 0 0 0 0 0 0 0 v1.2.0 0 0 0 0 0 0 0 v1.2.0a 0 0 0 0 0 0 0 v1.2.1000000 0 0 0 0 0 0 0 v1.2.999999 0 0 0 0 0 0 0 v1.10.0 0 0 0 0 0 0 0 v2/v3 0 0 0 0 0 0 0 > "$plan/stage3/versions.tsv"
mk 15 'To Do' '["v1.2.0"]' 'milestone minor ticket'
tstdout="$(render)"
thtml="$(cat "$out" 2>/dev/null)"
contains 'a v1.2.0 ticket renders (HIMMEL-4873)' "$thtml" '"milestone minor ticket"'
contains 'minors sort numerically after the v1.1.x line (HIMMEL-4873)' "$thtml" '"v1.1.0","v1.2.0","v1.2.0a","v1.2.999999","v1.2.1000000","v1.7.0","v1.10.0"'
contains 'the whole-train ledger counts a minor (HIMMEL-4873)' "$tstdout" 'Plan rows placed in the whole v1.0.x train (not Jira progress): 1 of 9 done'
contains 'the JS train test accepts every v1.N.x (HIMMEL-4873)' "$thtml" '/^v1\.\d+\.\d+[a-z]?$/'
cp "$W/versions.tsv.keep" "$plan/stage3/versions.tsv"; rm -f "$mdir/HIMMEL-15.md"

# --- version-first page. Versions and release state come from Jira (mirror fixVersions + a `jira versions`
# snapshot in <mirror-dir>.versions.tsv); the main view answers "which version are we working on".
# No versions file yet: no version counts as released and the page says so.
contains 'a missing versions file means release state unknown (HIMMEL-3990)' "$html" '"RU":true'
contains 'the hero says release state unknown (HIMMEL-3990)' "$html" '"release state unknown"'
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
mdir="$mir"
printf 'v1.0.0\ttrue\t2026-09-30\nv1.0.1\ttrue\t2026-10-04\nv1.0.2\tfalse\t\nv1.0.3\tfalse\t\nv1.0.4\tfalse\t\n' > "$W/jm.versions.tsv"
render --mirror-dir "$jm" >/dev/null
jhtml="$(cat "$out" 2>/dev/null)"
contains 'the default versions file is <mirror-dir>.versions.tsv (HIMMEL-3990)' "$jhtml" \
    '"JV":[{"n":"v1.0.1","rel":true,"date":"2026-10-04"},{"n":"v1.0.2","rel":false,"date":""},{"n":"v1.0.3","rel":false,"date":""},{"n":"v1.0.4","rel":false,"date":""}]'
contains 'a versions file means release state is known (HIMMEL-3990)' "$jhtml" '"RU":false'
contains 'a released version has no caps: its tickets already shipped (HIMMEL-4930)' "$jhtml" '"VC":[null,'
not_contains 'a ticket with only v1.0.0 is in no version (HIMMEL-3990)' "$jhtml" '"t":"zero version one"'
contains 'working on is the earliest unreleased version with open work, not a released one (HIMMEL-3990)' "$jhtml" '"JC":1,'
contains 'up next is the next unreleased version holding a ticket (HIMMEL-3990)' "$jhtml" '"JN":2,'
contains 'a released version holding an open ticket is alerted, naming the ticket (HIMMEL-3990)' "$jhtml" '"JA":[[0,[31]]]'
contains 'the alert text names the release date and the open tickets (HIMMEL-3990)' "$jhtml" ' but still holds '
contains 'the released-but-open alert still renders when no unreleased version is open (HIMMEL-3990)' "$jhtml" \
    's.textContent="Every unreleased version is done.";jalerts(-1);return}'
contains 'In Review is counted from the status name (HIMMEL-3990)' "$jhtml" '"k":32,"t":"review one","s":"In Review","b":"rev","v":1,'
contains 'IN CI is counted from the status name (HIMMEL-3990)' "$jhtml" '"k":33,"t":"ci one","s":"IN CI","b":"ci","v":1,'
not_contains 'a wont-do ticket is in no count, bar or column (HIMMEL-6241)' "$jhtml" '"t":"wont one"'
not_contains 'a Closed ticket is in no count, bar or column (HIMMEL-6241)' "$jhtml" '"t":"closed one"'
not_contains 'a Done ticket with a Duplicate resolution is in no count (HIMMEL-6241)' "$jhtml" '"t":"duplicate one"'
not_contains 'a closed-without-shipping ticket is in no plan row either (HIMMEL-6241)' "$jhtml" '"closed one"'
contains 'closed without shipping is one count per version, not a Done count (HIMMEL-6241)' "$jhtml" '"JW":[[1,2],[2,1],[3,1]]'
contains 'a Done ticket in a future version is counted in the current one (HIMMEL-6241)' "$jhtml" \
    '"k":40,"t":"done in future one","s":"Done","b":"done","v":1,'
not_contains 'a Done ticket naming a released and a later unreleased version is not counted again in the current one (HIMMEL-6246)' "$jhtml" \
    '"k":43,"t":"released and future one","s":"Done","b":"done","v":1,'
contains 'a Done ticket naming a released and a later unreleased version stays in the released one (HIMMEL-6246)' "$jhtml" \
    '"k":43,"t":"released and future one","s":"Done","b":"done","v":0,'
contains 'a version holding only closed-without-shipping work gets a kanban row (HIMMEL-6246)' "$jhtml" \
    'data-v="v1.0.4"><summary><span class="vn">v1.0.4</span> <span class="kmeta">0 open of 0 · 1 closed without shipping</span>'
contains 'the client version table renders a row for a closed-only version (HIMMEL-6246)' "$jhtml" \
    '[1];if(!t.n&&!wn)return;if(HIDE&&!t.open&&t.n){hid++;return}'
contains 'the footnote says closed without shipping (HIMMEL-6241)' "$jhtml" 'closed without shipping'
not_contains 'the legend no longer calls Closed or wont do work done (HIMMEL-6241)' "$jhtml" 'Hides Done, Closed, In Public, wont do'
contains 'an unknown status falls back to the status category (HIMMEL-3990)' "$jhtml" '"t":"category fallback one","s":"In Progress","b":"prog"'
contains 'a released-only ticket keeps its released version (HIMMEL-3990)' "$jhtml" '"k":30,"t":"released done one","s":"Done","b":"done","v":0,'
contains 'hide done work is ON by default (HIMMEL-3990)' "$jhtml" 'var HIDE=true;try{var hs=localStorage.getItem("hide3990")'
contains 'the hide switch starts checked (HIMMEL-3990)' "$jhtml" 'role="switch" aria-checked="true"'
contains 'the switch is labelled Hide done work (HIMMEL-3990)' "$jhtml" 'Hide done work</button>'
contains 'the board caps a column at 6 cards (HIMMEL-3990)' "$jhtml" 'slice(0,6)'
contains 'a drill says where the plan places a ticket that Jira puts elsewhere (HIMMEL-3990)' "$jhtml" '"the plan places it in "'
contains 'every version is a keyboard-pickable row (HIMMEL-3990)' "$jhtml" 'e.key=="Enter"||e.key==" "'
contains 'the version table is titled Every version (HIMMEL-3990)' "$jhtml" '<h2 id="vh">Every version</h2>'
not_contains 'no tiles section (HIMMEL-3990)' "$jhtml" 'id="tiles"'
# an explicit --versions-file wins over the default path
printf 'v1.0.1\tfalse\t\nv1.0.2\ttrue\t2026-10-05\n' > "$W/alt.versions.tsv"
render --mirror-dir "$jm" --versions-file "$W/alt.versions.tsv" >/dev/null
althtml="$(cat "$out" 2>/dev/null)"
contains '--versions-file names the snapshot (HIMMEL-3990)' "$althtml" '"JV":[{"n":"v1.0.1","rel":false,"date":""},{"n":"v1.0.2","rel":true,"date":"2026-10-05"}]'
# an empty (truncated) versions file is no snapshot: it falls back like a missing one
: > "$W/empty.versions.tsv"
render --mirror-dir "$jm" --versions-file "$W/empty.versions.tsv" >/dev/null
emhtml="$(cat "$out" 2>/dev/null)"
contains 'an empty versions file means release state unknown (HIMMEL-4441)' "$emhtml" '"RU":true'
contains 'an empty versions file still lists the mirror fixVersions (HIMMEL-4441)' "$emhtml" '"JV":[{"n":"v1.0.1","rel":false,"date":""},'
contains 'an empty versions file still shows the tickets (HIMMEL-4441)' "$emhtml" '"t":"released but open"'
# the versions file is a fingerprint input: a release moves tracker=
fpa='' fpb='' fpc='' fpd='' fpe=''
fp_ok 'versions base' fpa --mirror-dir "$jm"
printf 'v1.0.1\ttrue\t2026-10-04\nv1.0.2\ttrue\t2026-10-05\nv1.0.3\tfalse\t\n' > "$W/jm.versions.tsv"
fp_ok 'versions released' fpb --mirror-dir "$jm"
if [ -n "$fpa" ] && [ "$fpa" != "$fpb" ]; then pass 'a versions-file change moves the fingerprint (HIMMEL-3990)'; else fail "a versions-file change left the fingerprint at '$fpa'"; fi
fp_ok 'versions explicit' fpc --mirror-dir "$jm" --versions-file "$W/alt.versions.tsv"
if [ "$fpb" != "$fpc" ]; then pass '--emit-fp reads --versions-file (HIMMEL-3990)'; else fail '--emit-fp ignored --versions-file'; fi
rm -f "$W/jm.versions.tsv"
fp_ok 'versions missing' fpd --mirror-dir "$jm"
if [ "$fpb" != "$fpd" ]; then pass 'a missing versions file differs from a present one (HIMMEL-3990)'; else fail 'a missing versions file left the fingerprint'; fi
fp_ok 'versions missing again' fpe --mirror-dir "$jm"
if [ "$fpd" = "$fpe" ]; then pass 'the fingerprint is stable with the versions file missing (HIMMEL-3990)'; else fail 'the fingerprint moved with no input change'; fi

# --- drift log + trend.
dl="$W/drift.tsv"
unthemed_of() { printf '%s' "$1" | sed -n 's/.*drift, \([0-9]*\) unthemed,.*/\1/p'; }
base_unthemed="$(unthemed_of "$(render --drift-log "$dl")")"
sect7_on() { cp "$mir/HIMMEL-7.md" "$W/h7.bak"; { sed -n 1p "$W/h7.bak"; printf 'sector: "Tooling"\n'; sed 1d "$W/h7.bak"; } > "$mir/HIMMEL-7.md"; }
sect7_off() { cp "$W/h7.bak" "$mir/HIMMEL-7.md"; }
sect7_on
ostdout="$(render --drift-log "$dl")"
sect7_off
if [ -n "$base_unthemed" ] && [ "$(unthemed_of "$ostdout")" = "$((base_unthemed - 1))" ]; then pass "a mirror sector lowers the unthemed count by one (HIMMEL-6483)"; else fail "unthemed went from '$base_unthemed' to '$(unthemed_of "$ostdout")'"; fi
rows_n() { grep -c . "$dl" 2>/dev/null || printf 0; }
rm -f "$dl"
render --drift-log "$dl" >/dev/null
if grep -Eq '^20[0-9-]+T[0-9:]+Z	[0-9]+	[0-9]+	[0-9]+$' "$dl" 2>/dev/null && [ "$(head -1 "$dl")" = "$(printf 'utc\tdrift\tunplanned\tunthemed')" ]; then pass 'a render appends one drift row: stamp, drift, unplanned, unthemed (HIMMEL-4930)'; else fail 'no well-formed drift row'; fi
n1="$(rows_n)"
render --drift-log "$dl" >/dev/null
if [ "$n1" = "$(rows_n)" ] && [ "$n1" -ge 2 ]; then pass 'an unchanged render within the hour adds no drift row (HIMMEL-4930)'; else fail "unchanged render grew the drift log from $n1 to $(rows_n)"; fi
sect7_on
render --drift-log "$dl" >/dev/null
sect7_off
if [ "$(rows_n)" -gt "$n1" ]; then pass 'a changed count adds a drift row (HIMMEL-4930)'; else fail 'a changed count left the drift log alone'; fi
trend="$(render --drift-log "$dl")"
contains 'stdout prints the drift trend (HIMMEL-4930)' "$trend" 'drift trend:'
contains 'the page carries the drift trend (HIMMEL-4930)' "$(cat "$out" 2>/dev/null)" '"DT":[['

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
contains 'a release panel holds a drill-down for v1.0.9 (HIMMEL-5381)' "$khtml" 'data-v="v1.0.9"'
kt="$(kcol "$khtml" todo)"; kp="$(kcol "$khtml" prog)"; kr="$(kcol "$khtml" rev)"; kd="$(kcol "$khtml" "done")"
contains 'To Do column holds the To Do ticket (HIMMEL-5381)' "$kt" 'HIMMEL-31'
contains 'In Progress column holds the In Progress ticket (HIMMEL-5381)' "$kp" 'HIMMEL-32'
contains 'In Review column holds the In Review ticket (HIMMEL-5381)' "$kr" 'HIMMEL-33'
kc="$(kcol "$khtml" ci)"
contains 'IN CI column holds the IN CI ticket (HIMMEL-6430)' "$kc" 'HIMMEL-34'
not_contains 'In Review column no longer holds the IN CI ticket (HIMMEL-6430)' "$kr" 'HIMMEL-34'
contains 'Done column holds the Done ticket (HIMMEL-5381)' "$kd" 'HIMMEL-35'
not_contains 'a ticket sits in one column only (HIMMEL-5381)' "$kt$kp$kd" 'HIMMEL-33'
contains 'a card links to the Jira browse URL from the configured base (HIMMEL-5381)' "$kt" 'href="https://jira.example.test/browse/HIMMEL-31"'
contains 'a card shows the ticket summary (HIMMEL-5381)' "$kt" 'kanban todo ticket'
contains 'a card shows the first sentence of the Impact block (HIMMEL-5381)' "$kt" 'Operators can now see the kanban of a release.'
not_contains 'a card stops after the first Impact sentence (HIMMEL-5381)' "$kt" 'A second sentence must not show'
contains 'a card line is HTML-escaped (HIMMEL-5381)' "$kd" 'user &amp; more'
contains 'a ticket without Impact falls back to its summary as the line (HIMMEL-5381)' "$kp" '<div class="kline">kanban prog ticket</div>'
krender --jira-base-url "" >/dev/null
contains 'with no base URL the key is plain text, never a made-up host (HIMMEL-5381)' "$(cat "$kout")" '<span class="kkey">HIMMEL-31</span>'
not_contains 'with no base URL there is no browse link (HIMMEL-5381)' "$(cat "$kout")" '/browse/HIMMEL-31'
kfp1="$(krender --emit-fp --jira-base-url "")"
krender --jira-base-url 'https://jira.example.test/' >/dev/null
kfp2="$(krender --emit-fp --jira-base-url "https://jira.example.test/")"
if [[ "$kfp1" =~ ^[0-9a-f]{16}$ ]] && [ "$kfp1" = "$kfp2" ]; then pass 'the kanban leaves the fingerprint semantics alone (HIMMEL-5381)'; else fail "fingerprint moved with the base URL or failed: '$kfp1' vs '$kfp2'"; fi

# --- re-measured actuals, spawned bundles under their planned origin, the operator bundle, zone labels.
# Own plan, mirror and handover tree. HIMMEL-100 is planned; 101 says it was deferred from 100, 102 is a follow-up of 101
# (A to B to C), a leg of 101 filed 103, 108 relates to 100 by a Jira link. 104 carries the operator-directed label,
# a console OPERATOR bullet filed 105, 106 follows up 105. 107 and 109 reach no anchor (109 is named only by a RULING).
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
bmk 103 'Done' '[]' 'filed by a leg' '[]' '[]'
bmk 104 'To Do' '[]' 'operator label' '["operator-directed"]' '[]'
bmk 105 'Done' '[]' 'operator ask' '[]' '[]'
bmk 106 'To Do' '[]' 'operator follow-up' '[]' '[]' 'A follow-up from HIMMEL-105.'
bmk 107 'To Do' '["v1.0.1"]' 'nobody claims me' '[]' '[]'
bmk 108 'To Do' '[]' 'linked follow-up' '[]' '["HIMMEL-100"]'
bmk 109 'To Do' '["v1.0.1"]' 'named by a ruling' '[]' '[]' 'Mentions HIMMEL-200 which is newer, never an origin.'
# A multi-day leg: 22:00 on 2026-10-01 to 23:00 on 2026-10-02 is 25 h of wall time; only 180 min of it is active.
printf '%s\n' '# leg' '## Results' '- 22:00 LIVE — started' '- 23:30 LIVE — PR 1 open' '- 01:00 READY 1 abc GREEN' \
    '- 23:00 WRAPPED — merged' > "$bh/HIMMEL-100-N90-planned-origin-2026-10-01.md"
# A note after WRAPPED and a later section's bullet are past the measured span; a later section's filing is not the leg's.
printf '%s\n' '# leg' '## Results' '- 10:00 LIVE — filed HIMMEL-103 for the second gap' '- 10:45 WRAPPED — merged' \
    '- 11:30 note after the wrap' '## Notes' '- 12:00 a later note: filed HIMMEL-107 elsewhere' > "$bh/HIMMEL-101-N91-lint-gap-2026-10-02.md"
printf '%s\n' '# leg' '## Results' '- 09:00 LIVE — started' '- 09:30 WRAPPED — merged' > "$bh/HIMMEL-102-N94-no-date.md"
printf '%s\n' '# leg' '## Results' '- 09:00 LIVE — started' '- 09:20 WRAPPED — merged' > "$bh/HIMMEL-105-N93-operator-ask-2026-10-03.md"
printf '%s\n' '# console' '## Results' '- 22:57 OPERATOR: do the thing. Filed HIMMEL-105; DISPATCH N93' \
    '- 23:10 OPERATOR RULING: Filed HIMMEL-109 is not an ask' '- 23:15 **OPERATOR** RULING: Filed HIMMEL-109 again' > "$bh/HIMMEL-nextleg-2026-10-03A-roadmap-console.md"
bout="$W/bench.html"
brender() {
    TZ=Europe/Berlin python3 "$HERE/tracker.py" --plan-dir "$bplan" --out "$bout" --luna-map "$W/luna-map-b.json" \
        --mirror-dir "$bmir" --luna-root "$W/bluna" --handovers "$bh" "$@" 2>&1
}
bstdout="$(brender)"
bhtml="$(cat "$bout" 2>/dev/null)"
btsv="$bout.bench.tsv"
contains 'the Jira stamp is converted to UTC and labelled (HIMMEL-5453)' "$bhtml" '"mir":"2026-09-30 08:00 UTC"'
contains 'a multi-day leg counts its dated wall span and its active minutes apart (HIMMEL-5453)' "$bhtml" '"100":[1,1500,180,1]'
contains 'a leg doc with no date in its name counts active minutes but no dated wall (HIMMEL-5453)' "$bhtml" '"102":[1,0,30,0]'
contains 'the page names the source of each number (HIMMEL-5453)' "$bhtml" 'wall = first Results bullet to WRAPPED'
contains 'the cost column is a named ponytail (HIMMEL-5453)' "$bhtml" 'cost: not measured'
if [ -f "$btsv" ]; then pass 'the benchmark TSV is written beside the page (HIMMEL-5453)'; else fail 'no benchmark TSV beside the page'; fi
bcol() { awk -F'\t' -v k="$1" -v c="$2" 'NR==1{for(i=1;i<=NF;i++)h[$i]=i;next}$1==k{print $(h[c])}' "$btsv" 2>/dev/null; }
contains 'A to B to C rolls up to the first planned ancestor; a leg-filed and a linked ticket join it (HIMMEL-5453)' \
    "$(bcol HIMMEL-100 members)" 'HIMMEL-101,HIMMEL-102,HIMMEL-103,HIMMEL-108'
contains 'the bundle counts open and done (HIMMEL-5453)' "$(bcol HIMMEL-100 bundle_n) $(bcol HIMMEL-100 bundle_open) $(bcol HIMMEL-100 bundle_done)" '4 2 2'
contains 'the bundle folds into the item total (HIMMEL-5453)' "$(bcol HIMMEL-100 own_wall_min) $(bcol HIMMEL-100 bundle_wall_min) $(bcol HIMMEL-100 total_wall_min)" '1500 45 1545'
contains 'the bundle coverage counts its dated legs (HIMMEL-5453)' "$(bcol HIMMEL-100 bundle_legs) $(bcol HIMMEL-100 bundle_dated)" '2 1'
contains 'a ratio over partly undated legs is left blank (HIMMEL-5453)' "$(bcol HIMMEL-100 est_seq) [$(bcol HIMMEL-100 min_per_seq)] [$(bcol HIMMEL-100 ratio)]" '2.2 [] []'
contains 'the dated span is printed in UTC (HIMMEL-5453)' "$(bcol HIMMEL-100 first_utc) $(bcol HIMMEL-100 end_utc)" '2026-10-01T20:00Z 2026-10-02T21:00Z'
contains 'the operator bundle holds labelled, backfilled and their spawned tickets (HIMMEL-5453)' \
    "$(bcol operator-directed members)" 'HIMMEL-104,HIMMEL-105,HIMMEL-106'
contains 'the operator bundle carries its actuals (HIMMEL-5453)' "$(bcol operator-directed bundle_wall_min) $(bcol operator-directed bundle_open)" '20 2'
contains 'unattributed unplanned train tickets are their own visible bundle; a RULING bullet is no ask (HIMMEL-5453)' \
    "$(bcol unattributed members)" 'HIMMEL-107,HIMMEL-109'
contains 'the page carries the bundles (HIMMEL-5453)' "$bhtml" '"BN":['
contains 'stdout names the TSV (HIMMEL-5453)' "$bstdout" 'bench.tsv'
bfp1="$(brender --emit-fp)"
printf '%s\n' '- 23:20 OPERATOR: one more. Filed HIMMEL-107' >> "$bh/HIMMEL-nextleg-2026-10-03A-roadmap-console.md"
bfp2="$(brender --emit-fp)"
if [ -n "$bfp1" ] && [ "$bfp1" != "$bfp2" ]; then pass 'a new OPERATOR filing moves the fingerprint (HIMMEL-5453)'; else fail 'a new OPERATOR filing left the fingerprint'; fi
mv "$bh/HIMMEL-102-N94-no-date.md" "$bh/HIMMEL-102-N94-now-dated-2026-10-02.md"
brender >/dev/null
contains 'the ratio sits beside its raw inputs once every leg is dated (HIMMEL-5453)' \
    "$(bcol HIMMEL-100 bundle_legs) $(bcol HIMMEL-100 bundle_dated) $(bcol HIMMEL-100 est_seq) $(bcol HIMMEL-100 min_per_seq) $(bcol HIMMEL-100 ratio)" '2 2 2.2 715.9 1.00'

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
not_contains 'a theme label is not a group (HIMMEL-6483)' "$thtml" '"fresh-label"'
not_contains 'the stage1 theme is not a group either (HIMMEL-6483)' "$thtml" '"legacy"'

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
contains 'the summary counts Done-in-future-version tickets (HIMMEL-5801)' "$dfout" ', 1 done-in-future;'
printf 'v1.0.1\ttrue\t2026-10-04\nv1.0.2\tfalse\t2026-10-20\n' > "$dfm.versions.tsv"
dfout="$(render --mirror-dir "$dfm")"
contains 'no Done ticket past the current version counts zero (HIMMEL-5801)' "$dfout" ', 0 done-in-future;'

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
contains 'a Done ticket in a future v1.1.x counts as done-in-future (HIMMEL-5826)' "$dfout" ', 1 done-in-future;'

# A Done ticket in a later major version (v2.0.0) counts too: the count is not limited to the v1 train.
dfm="$W/dfm3"
mkdir -p "$dfm"
mdir="$dfm"
mk 85 'Done' '["v1.1.3"]' 'done in current' 'Done'
mk 86 'Done' '["v2.0.0"]' 'done in a later major' 'Done'
mdir="$mir"
printf 'v1.1.3\tfalse\t2026-10-20\nv2.0.0\tfalse\t\n' > "$dfm.versions.tsv"
dfout="$(render --mirror-dir "$dfm")"
contains 'a Done ticket in a later major version counts as done-in-future (HIMMEL-5826)' "$dfout" ', 1 done-in-future;'

# --- per-version page defects: multi-version tickets, in-flight lane, current version, fleet-manifest legs.
# Item 2: a ticket with two fixVersions is counted in each (ticket 32 holds v1.0.3 and v1.0.2).
contains 'a ticket with two fixVersions is counted in its second version too (HIMMEL-5217)' "$jhtml" \
    '"k":32,"t":"review one","s":"In Review","b":"rev","v":2,'
# Item 5: open In Progress / In Review work with no fixVersion is visible in its own lane.
contains 'unversioned in-flight work has its own lane (HIMMEL-5217)' "$jhtml" 'In flight, no version'
contains 'the lane lists the in-flight ticket (HIMMEL-5217)' "$jhtml" 'flight one'
not_contains 'the lane leaves out an unversioned To Do ticket (HIMMEL-5217)' "$jhtml" 'idle unversioned one'
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
contains 'a released version is not the plan blocks current version (HIMMEL-5217)' "$cuhtml" '"CUR":1,'
# Item 1: a leg listed in a console's fleet manifest is live without a held queue lock.
printf '{"schema":1,"legs":[{"doc":"%s","label":"N57"}]}\n' "$bk/HIMMEL-7-N57-released-leg-2026-10-01.md" > "$bk/test-console.fleet.json"
render >/dev/null
fmhtml="$(cat "$out" 2>/dev/null)"
rm -f "$bk/test-console.fleet.json"
contains 'a leg in the fleet manifest is live with its label and phase (HIMMEL-5217)' "$fmhtml" '"7":["N57","LIVE"'

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
contains 'the parity check asks Jira for the version worked on (HIMMEL-6401)' "$(cat "$W/jira-args" 2>/dev/null)" \
    'list --jql project = HIMMEL AND fixVersion = "v1.1.3"'
contains 'a page count that differs from Jira is a parity DRIFT (HIMMEL-6401)' "$pstdout" \
    'parity: v1.1.3 DRIFT page 2/1/0/0 jira 1/0/1/0 (done/in progress/in review/to do)'
contains 'the hero note carries the parity line (HIMMEL-6401)' "$phtml" '"PAR":"parity: v1.1.3 DRIFT page 2/1/0/0'
# the same mirror against a Jira that agrees with it: ok.
printf 'HIMMEL-4185\tTask\tDone\tx\nHIMMEL-5860\tTask\tDone\tx\nHIMMEL-6143\tTask\tIn Progress\tx\nHIMMEL-5574\tTask\tClosed\tx\n' > "$W/agree.tsv"
printf '#!/bin/sh\ncat "%s"\n' "$W/agree.tsv" > "$W/agreejira"
chmod +x "$W/agreejira"
pstdout="$(TRACKER_JIRA="$W/agreejira" render --mirror-dir "$pf/mirror" --versions-file "$pf/mirror.versions.tsv")"
contains 'equal counts are parity ok (HIMMEL-6401)' "$pstdout" 'parity: v1.1.3 ok 2/1/0/0 (done/in progress/in review/to do)'
# a mirror one status behind live is lag, naming the key; a mismatch that is no lag is DRIFT naming both statuses.
printf 'HIMMEL-4185\tTask\tDone\tx\nHIMMEL-5860\tTask\tDone\tx\nHIMMEL-6143\tTask\tIn Review\tx\nHIMMEL-5574\tTask\tClosed\tx\n' > "$W/lag.tsv"
printf '#!/bin/sh\ncat "%s"\n' "$W/lag.tsv" > "$W/lagjira"
chmod +x "$W/lagjira"
pstdout="$(TRACKER_JIRA="$W/lagjira" render --mirror-dir "$pf/mirror" --versions-file "$pf/mirror.versions.tsv")"
contains 'a mirror behind live reads lag and names the key (HIMMEL-6483)' "$pstdout" 'parity: v1.1.3 lag page 2/1/0/0 jira 2/0/1/0'
contains 'the lag line gives both statuses (HIMMEL-6483)' "$pstdout" 'HIMMEL-6143 page In Progress jira In Review'
not_contains 'a mirror behind live is not DRIFT (HIMMEL-6483)' "$pstdout" 'parity: v1.1.3 DRIFT'
printf 'HIMMEL-4185\tTask\tDone\tx\nHIMMEL-5860\tTask\tDone\tx\nHIMMEL-6143\tTask\tTo Do\tx\nHIMMEL-5574\tTask\tClosed\tx\n' > "$W/real.tsv"
printf '#!/bin/sh\ncat "%s"\n' "$W/real.tsv" > "$W/realjira"
chmod +x "$W/realjira"
pstdout="$(TRACKER_JIRA="$W/realjira" render --mirror-dir "$pf/mirror" --versions-file "$pf/mirror.versions.tsv")"
contains 'a page ahead of Jira is DRIFT naming the key and both statuses (HIMMEL-6483)' "$pstdout" \
    'parity: v1.1.3 DRIFT page 2/1/0/0 jira 2/0/0/1 (done/in progress/in review/to do): HIMMEL-6143 page In Progress jira To Do'
pstdout="$(TRACKER_JIRA="$W/fakejira" render --mirror-dir "$pf/mirror" --versions-file "$pf/mirror.versions.tsv")"
contains 'a key only on the page is DRIFT, a lagging key beside it is listed too (HIMMEL-6483)' "$pstdout" \
    'HIMMEL-5860 page Done jira (absent), HIMMEL-6143 page In Progress jira In Review'
printf 'HIMMEL-4185\tTask\tDone\tx\nHIMMEL-5860\tTask\tDone\tx\nHIMMEL-6143\tTask\tIn Progress\tx\nHIMMEL-5574\tTask\tClosed\tx\nHIMMEL-9001\tTask\tTo Do\tx\n' > "$W/new.tsv"
printf '#!/bin/sh\ncat "%s"\n' "$W/new.tsv" > "$W/newjira"
chmod +x "$W/newjira"
pstdout="$(TRACKER_JIRA="$W/newjira" render --mirror-dir "$pf/mirror" --versions-file "$pf/mirror.versions.tsv")"
contains 'a ticket live Jira has and the mirror lacks is lag, not DRIFT' "$pstdout" 'HIMMEL-9001 page (absent) jira To Do'
not_contains 'a ticket only in Jira is not DRIFT' "$pstdout" 'parity: v1.1.3 DRIFT'
contains 'the Jira side drops Done tickets resolved as something other than Done or Fixed (HIMMEL-6483)' \
    "$(cat "$W/jira-args" 2>/dev/null)" 'resolution not in'
# a status the tracker has no bucket for is a garbled answer, never a guessed To Do.
printf 'HIMMEL-4185\tTask\tDone\tx\nHIMMEL-6143\tTask\tSomething New\tx\n' > "$W/odd.tsv"
printf '#!/bin/sh\ncat "%s"\n' "$W/odd.tsv" > "$W/oddjira"
chmod +x "$W/oddjira"
pstdout="$(TRACKER_JIRA="$W/oddjira" render --mirror-dir "$pf/mirror" --versions-file "$pf/mirror.versions.tsv")"
contains 'an unknown Jira status reads parity unavailable (HIMMEL-6401)' "$pstdout" 'parity: v1.1.3 unavailable'
# a failing CLI never fails the render.
pstdout="$(render --mirror-dir "$pf/mirror" --versions-file "$pf/mirror.versions.tsv")"
prc=$?
if [ "$prc" -eq 0 ]; then pass 'a failing Jira CLI does not fail the render (HIMMEL-6401)'; else fail "a failing Jira CLI failed the render: rc $prc"; fi
contains 'a failing Jira CLI reads parity unavailable (HIMMEL-6401)' "$pstdout" 'parity: v1.1.3 unavailable'
# the hero counts the Jira status (t.b), not the live-leg display; the boards keep the display (jb).
contains 'the hero tallies by Jira status, not the live-leg display (HIMMEL-6401)' "$phtml" 't=jtally(jin(JCUR),1)'
contains 'the up-next line tallies by Jira status (HIMMEL-6401)' "$phtml" 'var u=jtally(jin(JNXT),1)'
contains 'a board tally keeps the live-leg display (HIMMEL-6401)' "$phtml" 'r[raw?t.b:jb(t)].push(t)'

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
if [ "$src" -eq 0 ]; then pass 'a split render exits 0 (HIMMEL-6514)'; else fail "a split render exited $src: $(cat "$W/split.stdout")"; fi
fhtml="$(cat "$sout" 2>/dev/null)"
dhtml="$(cat "$sdone" 2>/dev/null)"
uhtml="$(cat "$sfuture" 2>/dev/null)"
contains 'the focus page holds the open target tickets (HIMMEL-6514)' "$fhtml" 'splitmark open in target'
contains 'the focus page holds the in-progress target ticket (HIMMEL-6514)' "$fhtml" 'splitmark progress in target'
not_contains 'the focus page holds no Done ticket of the target (HIMMEL-6514)' "$fhtml" 'splitmark done in target'
not_contains 'the focus page holds no Done ticket of a released version (HIMMEL-6514)' "$fhtml" 'splitmark done in released'
not_contains 'the focus page holds no ticket of a later version (HIMMEL-6514)' "$fhtml" 'splitmark open in future'
contains 'the Done page holds the Done target ticket (HIMMEL-6514)' "$dhtml" 'splitmark done in target'
contains 'the Done page holds the Done released ticket (HIMMEL-6514)' "$dhtml" 'splitmark done in released'
not_contains 'the Done page holds no open ticket (HIMMEL-6514)' "$dhtml" 'splitmark open in target'
not_contains 'the Done page holds no future ticket (HIMMEL-6514)' "$dhtml" 'splitmark open in future'
contains 'the future page holds the later version ticket (HIMMEL-6514)' "$uhtml" 'splitmark open in future'
not_contains 'the future page holds no target ticket (HIMMEL-6514)' "$uhtml" 'splitmark open in target'
not_contains 'the future page holds no Done ticket (HIMMEL-6514)' "$uhtml" 'splitmark done in target'
# the target defaults to the earliest unreleased version of the versions file; --target-version overrides it.
contains 'the focus page names the target version (HIMMEL-6514)' "$fhtml" '"PG":"focus"'
srender --target-version v1.1.4 > /dev/null
contains 'an explicit --target-version moves the focus (HIMMEL-6514)' "$(cat "$sout" 2>/dev/null)" 'splitmark open in future'
not_contains 'an explicit --target-version drops the old focus (HIMMEL-6514)' "$(cat "$sout" 2>/dev/null)" 'splitmark open in target'
srender --target-version v9.9.9 > "$W/split-badtarget.stdout"
brc=$?
if [ "$brc" -eq 2 ]; then pass 'an unknown --target-version exits 2 (HIMMEL-6514)'; else fail "an unknown --target-version exited $brc"; fi
contains 'an unknown --target-version names the versions file (HIMMEL-6514)' "$(cat "$W/split-badtarget.stdout")" 'is not in the versions file'
srender > /dev/null
# the focus page links to the other two, and each of those links back to it.
contains 'the focus page links to the Done page (HIMMEL-6514)' "$fhtml" 'https://example.test/done'
contains 'the focus page links to the future page (HIMMEL-6514)' "$fhtml" 'https://example.test/future'
# tick reads the freshness of the focus page: its .fp is the --emit-fp value, and no other page carries one.
sfp="$(python3 "$HERE/tracker.py" --emit-fp --plan-dir "$splan" --out "$sout" --luna-map "$W/luna-map.json" --mirror-dir "$smir" \
    --versions-file "$W/split.versions.tsv" --luna-root "$W/luna" --handovers "$W/luna/handovers/tester/himmel" 2>&1)"
if [ -n "$sfp" ] && [ "$(cat "$sout.fp" 2>/dev/null)" = "$sfp" ]; then pass 'the focus page .fp equals --emit-fp (HIMMEL-6514)'; else fail "focus .fp '$(cat "$sout.fp" 2>/dev/null)' differs from --emit-fp '$sfp'"; fi
if [ ! -e "$sdone.fp" ] && [ ! -e "$sfuture.fp" ]; then pass 'the Done and future pages write no .fp (HIMMEL-6514)'; else fail 'a Done or future page wrote a .fp (HIMMEL-6514)'; fi
# without --out-done / --out-future the one page keeps every ticket.
python3 "$HERE/tracker.py" --plan-dir "$splan" --out "$W/split-all.html" --luna-map "$W/luna-map.json" --mirror-dir "$smir" \
    --versions-file "$W/split.versions.tsv" --luna-root "$W/luna" --handovers "$W/luna/handovers/tester/himmel" > "$W/split-all.stdout" 2>&1
arc=$?
[ "$arc" -eq 0 ] || fail "the unsplit render exited $arc: $(cat "$W/split-all.stdout")"
ahtml="$(cat "$W/split-all.html" 2>/dev/null)"
contains 'a render with no split outputs keeps the Done tickets (HIMMEL-6514)' "$ahtml" 'splitmark done in target'
contains 'a render with no split outputs keeps the future tickets (HIMMEL-6514)' "$ahtml" 'splitmark open in future'

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
    '- Depends on (merge order, plan §10(b)): for console-wait.sh the order is PR 3219 (HIMMEL-6478) → HIMMEL-6535 phase B → this → HIMMEL-6461 → slice 3. For waiter.md it is this → HIMMEL-6499 → slice 3. Start after HIMMEL-6478 and HIMMEL-6535 merge.'
bsout="$(python3 "$HERE/tracker.py" --remaining v1.1.3 --mirror-dir "$bs" 2>&1)"$'\n'
contains 'prose about another ticket is no blocker (HIMMEL-6749, 1481)' "$bsout" 'HIMMEL-1481 [To Do] real 1481 prose'$'\n'
contains 'a quoted command is no blocker (HIMMEL-6749, 6577)' "$bsout" 'HIMMEL-6577 [To Do] real 6577 quoted command'$'\n'
contains 'a negated or past-tense mention is no blocker (HIMMEL-6561)' "$bsout" 'HIMMEL-202 [To Do] negated mentions'$'\n'
contains 'odd spacing and BLOCKED-BY:KEY are read (HIMMEL-6561)' "$bsout" 'HIMMEL-203 [To Do] odd spacing {blocked-by: HIMMEL-303 open, HIMMEL-304 open}'
contains 'the title is not scanned (HIMMEL-6561)' "$bsout" 'HIMMEL-204 [To Do] blocked by HIMMEL-305 in the title'$'\n'
contains 'a blocker closed as wont reads wont (HIMMEL-6561)' "$bsout" 'HIMMEL-205 [To Do] wont blocker {blocked-by: HIMMEL-306 wont}'
contains 'a Links: line names its blocked-by key only (HIMMEL-6749)' "$bsout" 'HIMMEL-207 [To Do] links line {blocked-by: HIMMEL-311 open}'
contains 'a bold Markdown label with the colon inside is read (HIMMEL-6769)' "$bsout" 'HIMMEL-209 [To Do] bold label {blocked-by: HIMMEL-314 open}'
contains 'a multi-line blocked_by YAML list is read (HIMMEL-6561)' "$bsout" 'HIMMEL-208 [To Do] yaml list {blocked-by: HIMMEL-312 open, HIMMEL-313 open}'
contains 'a link the blocker text contradicts reads direction? (HIMMEL-6749)' "$bsout" 'HIMMEL-6535 [To Do] real 6535 link {blocked-by: HIMMEL-6538 direction?}'

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
[{"number":500,"title":"feat: [HIMMEL-401] x","headRefName":"feat/himmel-401-x","isDraft":false,"statusCheckRollup":[{"status":"COMPLETED","conclusion":"SUCCESS"}]},
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
if [ "$vrc" -eq 0 ]; then pass '--version renders and exits 0 (HIMMEL-6769)'; else fail "--version exited $vrc: $vstdout"; fi
contains 'the page is titled by its version (HIMMEL-6769)' "$vhtml" '<title>v1.1.3 Tracker</title>'
contains 'an open ticket of the version is a card (HIMMEL-6769)' "$vhtml" 'vp todo in group'
not_contains 'a ticket of another version is no card (HIMMEL-6769)' "$vhtml" 'vp next version'
not_contains 'a Done ticket is no card (HIMMEL-6769)' "$vhtml" 'vpdone ticket'
not_contains 'a Closed ticket is no card (HIMMEL-6769)' "$vhtml" 'vp closed'
contains 'a column per status with its count (HIMMEL-6769)' "$vhtml" 'data-col="To Do"><h2>To Do <span class="n">4</span></h2>'
contains 'the IN CI column counts its card (HIMMEL-6769)' "$vhtml" 'data-col="IN CI"><h2>IN CI <span class="n">1</span></h2>'
contains 'the header counts the Done tickets of the version (HIMMEL-6769)' "$vhtml" '1 Done'
contains 'each column carries a Jira parity line (HIMMEL-6769)' "$vhtml" '<div class="parity ok">Jira 4 · ok</div>'
contains 'stdout prints the per-column parity (HIMMEL-6769)' "$vstdout" 'parity v1.1.3: To Do 4/4 ok, In Progress 1/1 ok, In Review 1/1 ok, IN CI 1/1 ok'
contains 'parity asks Jira for the open tickets of the version (HIMMEL-6769)' "$(cat "$W/vp-jira-args" 2>/dev/null)" \
    'project = HIMMEL AND fixVersion = "v1.1.3" AND statusCategory != Done'
contains 'a card sits in its plan priority block (HIMMEL-6769, 6735)' "$(card 400)" 'data-block="0 critical"'
contains 'a card on no priority line sits in rest of version (HIMMEL-6769, 6735)' "$(card 407)" 'data-block="rest of version"'
contains 'a sector chip renders in the sector colour (HIMMEL-6769)' "$(card 400)" '<span class="sec" style="--s:#16a34a">Ship loop</span>'
contains 'a card with no sector says so (HIMMEL-6769)' "$(card 402)" 'no sector'
contains 'an open PR badge carries its CI state (HIMMEL-6769)' "$(card 401)" 'href="https://github.com/example-org/example-repo/pull/500">#500 · CI green</a>'
contains 'a PR found by its branch name, red and draft (HIMMEL-6769)' "$(card 403)" '#501 · CI red · draft'
contains 'a check that needs action is not green (HIMMEL-6769)' "$(card 400)" '#503 · CI red'
contains 'a check that failed to start is not green (HIMMEL-6769)' "$(card 410)" '#504 · CI red'
contains 'a started card with no open PR is flagged (HIMMEL-6769)' "$(card 402)" 'no open PR'
not_contains 'a To Do card with no PR is not flagged (HIMMEL-6769)' "$(card 407)" 'no open PR'
contains 'a card with an open blocker is flagged (HIMMEL-6769)' "$(card 403)" 'BLOCKED by open HIMMEL-404'
contains 'a contradicted link reads direction?, not BLOCKED (HIMMEL-6769, 6749)' "$(card 409)" 'direction? HIMMEL-410'
not_contains 'a contradicted link does not hold the card (HIMMEL-6769, 6749)' "$(card 409)" 'BLOCKED'
contains 'the card key links to Jira (HIMMEL-6769)' "$(card 400)" 'href="https://jira.example.test/browse/HIMMEL-400"'
contains 'a chain step renders (HIMMEL-6769)' "$vhtml" 'chain step two'
contains 'a chain step whose ticket is Done reads merged (HIMMEL-6769)' "$(grep -F 'chain step one' "$vout")" '<b>merged</b>'
contains 'a chain card carries its FAST-TRACK badge (HIMMEL-6769)' "$(card 400)" 'FAST-TRACK · 0 — wave one · step 2 · N9'
if [ ! -e "$vout.fp" ]; then pass 'a --version page without --plan-dir writes no .fp (HIMMEL-6769)'; else fail 'a --version page without --plan-dir wrote a .fp'; fi
# a column that differs from Jira reads DRIFT and names the key.
printf 'HIMMEL-400\tTask\tTo Do\tx\nHIMMEL-401\tTask\tIn Progress\tx\nHIMMEL-402\tTask\tIn Progress\tx\nHIMMEL-403\tTask\tIN CI\tx\nHIMMEL-407\tTask\tTo Do\tx\nHIMMEL-409\tTask\tTo Do\tx\nHIMMEL-410\tTask\tTo Do\tx\nHIMMEL-411\tTask\tBlocked\tx\n' > "$W/vp-jira.tsv"
vstdout="$(vrender)"
contains 'a column Jira counts differently reads DRIFT (HIMMEL-6769)' "$vstdout" 'In Progress 1/2 DRIFT, In Review 1/0 DRIFT'
contains 'the DRIFT line names the key and its Jira status (HIMMEL-6769)' "$(cat "$vout")" 'HIMMEL-402 Jira In Progress'
contains 'a status only Jira holds gets a DRIFT column on the page (HIMMEL-6769)' "$(cat "$vout")" \
    'data-col="Blocked"><h2>Blocked <span class="n">0</span></h2><div class="parity drift">Jira 1 · DRIFT: HIMMEL-411 page (absent)'
contains 'stdout counts the Jira-only status as DRIFT (HIMMEL-6769)' "$vstdout" 'Blocked 0/1 DRIFT'
# a failing Jira CLI or gh reads unavailable, never a failed render or a false flag.
printf '#!/bin/sh\nexit 1\n' > "$W/vpnogh"
chmod +x "$W/vpnogh"
vstdout="$(TRACKER_GH="$W/vpnogh" TRACKER_JIRA="$W/nojira" python3 "$HERE/tracker.py" --version v1.1.3 --repo example-org/example-repo --mirror-dir "$vp" --out "$vout" 2>&1)"
vrc=$?
if [ "$vrc" -eq 0 ]; then pass 'no Jira and no gh still render (HIMMEL-6769)'; else fail "no Jira and no gh exited $vrc: $vstdout"; fi
contains 'a failed parity read says unavailable (HIMMEL-6769)' "$vstdout" 'parity v1.1.3: unavailable'
contains 'a failed gh read says PR state unavailable (HIMMEL-6769)' "$(cat "$vout")" 'PR state unavailable'
not_contains 'a failed gh read flags no card as PR-less (HIMMEL-6769)' "$(cat "$vout")" 'no open PR'
# a later version gets its own page.
TRACKER_GH="$W/vpnogh" python3 "$HERE/tracker.py" --version v1.1.4 --repo example-org/example-repo --mirror-dir "$vp" --chains-file "$W/vp-chains.json" --out "$W/vp-v114.html" >/dev/null 2>&1
contains 'the v1.1.4 page holds its own ticket (HIMMEL-6769)' "$(cat "$W/vp-v114.html" 2>/dev/null)" 'vp next version'
not_contains 'the v1.1.4 page holds no v1.1.3 ticket (HIMMEL-6769)' "$(cat "$W/vp-v114.html" 2>/dev/null)" 'vp todo in group'
not_contains 'the v1.1.4 page holds no chain of another version (HIMMEL-6769)' "$(cat "$W/vp-v114.html" 2>/dev/null)" 'chain step two'
# a missing mirror fails instead of writing an empty page.
if TRACKER_GH="$W/vpnogh" python3 "$HERE/tracker.py" --version v1.1.3 --repo example-org/example-repo --mirror-dir "$W/no-such-mirror" --out "$W/vp-missing.html" >/dev/null 2>&1; then
    fail 'a missing mirror fails the --version render (HIMMEL-6769)'
else
    pass 'a missing mirror fails the --version render (HIMMEL-6769)'
fi
# with --plan-dir the page carries the tick fingerprint, so tick reads tracker=ok from it.
vfout="$W/vfp/roadmap-tracker.html"
TRACKER_GH="$W/vpnogh" python3 "$HERE/tracker.py" --version v1.1.3 --repo example-org/example-repo --mirror-dir "$vp" --out "$vfout" --plan-dir "$plan" \
    --luna-root "$W/luna" --handovers "$W/luna/handovers/tester/himmel" >/dev/null 2>&1
vfp="$(python3 "$HERE/tracker.py" --emit-fp --plan-dir "$plan" --out "$vfout" --luna-map "$W/luna-map.json" --mirror-dir "$vp" \
    --luna-root "$W/luna" --handovers "$W/luna/handovers/tester/himmel" 2>&1)"
if [ -n "$vfp" ] && [ "$(cat "$vfout.fp" 2>/dev/null)" = "$vfp" ]; then pass 'the --version page .fp equals --emit-fp (HIMMEL-6769)'; else fail "--version .fp '$(cat "$vfout.fp" 2>/dev/null)' differs from --emit-fp '$vfp'"; fi

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
ago="$(date -u -d '5 minutes ago' +%Y-%m-%dT%H:%M:%SZ)"
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
if [ "$v2rc" -eq 0 ]; then pass '--workers-dir renders and exits 0 (HIMMEL-6829)'; else fail "--workers-dir exited $v2rc: $v2stdout"; fi
step() { grep -F "$1" "$v2out" 2>/dev/null; }
wcard() { grep -F "data-key=\"HIMMEL-$1\"" "$v2out" 2>/dev/null; }
contains 'a held keyed step reads held, not its hand-written state (HIMMEL-6829)' "$(step 'held step')" '<li class="st-held"><b>held</b>'
contains 'an In Progress keyed step reads work, not its hand-written next (HIMMEL-6829)' "$(step 'prog step')" '<li class="st-work"><b>work</b>'
contains 'a To Do keyed step reads next, not its hand-written work (HIMMEL-6829)' "$(step 'todo step')" '<li class="st-next"><b>next</b>'
contains 'a keyed step missing from the mirror reads unknown (HIMMEL-6829)' "$(step 'missing step')" '<li class="st-unknown"><b>unknown</b>'
contains 'a Done keyed step reads merged, not its hand-written next (HIMMEL-6829)' "$(step 'done step')" '<li class="st-merged"><b>merged</b>'
contains 'a keyless step keeps its hand-written state (HIMMEL-6829)' "$(step 'keyless step')" '<li class="st-work"><b>work</b>'
contains 'a worker line shows the leg, state, open PR, head, CI and age (HIMMEL-6829)' "$(wcard 401)" 'worker N3096 · live · #500 @abc1234 · CI red · 5 min'
not_contains 'a closed PR of the record is not on the worker line (HIMMEL-6829)' "$(wcard 401)" '#499'
contains 'a wrapped worker with no PR shows its state only (HIMMEL-6829)' "$(wcard 400)" 'worker N2 · wrapped'
not_contains 'a card with no record has no worker line (HIMMEL-6829)' "$(wcard 407)" 'worker'
not_contains 'an unreadable record adds no worker line (HIMMEL-6829)' "$(wcard 402)" 'worker'
vfp1="$(cat "$v2out.vfp" 2>/dev/null)"
case "$vfp1" in
    [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]) pass 'a --version page writes a 16-hex focus fingerprint (HIMMEL-6829)' ;;
    *) fail "the focus fingerprint is '$vfp1'" ;;
esac
vfp_is() {
    local now=differ
    [ "$(cat "$v2out.vfp" 2>/dev/null)" != "$vfp1" ] || now=same
    if [ "$1" = "$now" ]; then pass "$2"; else fail "$2"; fi
}
sed 's/"conclusion":"SUCCESS"/"conclusion":"FAILURE"/' "$W/vp-prs.json" > "$W/vp-prs-red.json"
V2PRS="$W/vp-prs-red.json" v2render >/dev/null
vfp_is same 'a CI badge change leaves the focus fingerprint alone (HIMMEL-6829)'
printf '{"key":"HIMMEL-401","leg":"N3096","state":"live","last_event_ts":"2026-01-01T00:00:00Z","prs":{"500":{"head":"abc1234def5678","ci":"green","red_latch":false,"open":true}}}\n' > "$wk/HIMMEL-401.json"
v2render >/dev/null
vfp_is same 'a worker CI or age change leaves the focus fingerprint alone (HIMMEL-6829)'
printf '{"key":"HIMMEL-401","leg":"N3096","state":"idle","last_event_ts":"2026-01-01T00:00:00Z","prs":{"500":{"head":"abc1234def5678","ci":"green","open":true}}}\n' > "$wk/HIMMEL-401.json"
v2render >/dev/null
vfp_is differ 'a worker state change moves the focus fingerprint (HIMMEL-6829)'
printf '{"key":"HIMMEL-401","leg":"N3096","state":"live","prs":{"500":{"head":"fff9999aaa","open":true}}}\n' > "$wk/HIMMEL-401.json"
v2render >/dev/null
vfp_is differ 'a worker PR head change moves the focus fingerprint (HIMMEL-6829)'
printf '{"key":"HIMMEL-401","leg":"N7","state":"live","prs":{"500":{"head":"abc1234def5678","open":true}}}\n' > "$wk/HIMMEL-401.json"
v2render >/dev/null
vfp_is differ 'a worker owner change moves the focus fingerprint (HIMMEL-6829)'
printf '{"key":"HIMMEL-401","leg":"N3096","state":"live","prs":{"500":{"head":"abc1234def5678","open":true}}}\n' > "$wk/HIMMEL-401.json"
v2render >/dev/null
vfp_is same 'the original worker record restores the focus fingerprint (HIMMEL-6829)'
sed 's/prog step/prog step two/' "$W/vp-chains2.json" > "$W/vp-chains3.json"
V2CH="$W/vp-chains3.json" v2render >/dev/null
vfp_is differ 'a chain change moves the focus fingerprint (HIMMEL-6829)'
cp "$vp/HIMMEL-420.md" "$W/h420-keep.md"
sed 's/^type: "Task"/sector: "Elsewhere"\n&/' "$W/h420-keep.md" > "$vp/HIMMEL-420.md"
v2render >/dev/null
vfp_is differ 'a sector change moves the focus fingerprint (HIMMEL-6829)'
cp "$W/h420-keep.md" "$vp/HIMMEL-420.md"
printf '%s\n' '---' 'key: "HIMMEL-421"' 'statusCategory: "Done"' 'status: "Done"' 'fixVersions: ["v1.1.3"]' 'type: "Task"' '---' '# HIMMEL-421: vp finished ticket' > "$vp/HIMMEL-421.md"
v2render >/dev/null
vfp_is differ 'a new Done ticket of the version moves the focus fingerprint (HIMMEL-6829)'
rm -f "$vp/HIMMEL-421.md"
v2render >/dev/null
vfp_is same 'restoring the mirror restores the focus fingerprint (HIMMEL-6829)'
jq '. + [{"number":505,"title":"feat: [HIMMEL-401] more","headRefName":"feat/more","isDraft":false,"statusCheckRollup":[]}]' "$W/vp-prs.json" > "$W/vp-prs-more.json"
V2PRS="$W/vp-prs-more.json" v2render >/dev/null
vfp_is differ 'a new open PR moves the focus fingerprint (HIMMEL-6829)'
jq '.[0].isDraft = true' "$W/vp-prs.json" > "$W/vp-prs-draft.json"
V2PRS="$W/vp-prs-draft.json" v2render >/dev/null
vfp_is differ 'a draft flip moves the focus fingerprint (HIMMEL-6829)'
v2render >/dev/null
vfp_is same 'the original PR snapshot restores the focus fingerprint (HIMMEL-6829)'
printf '%s\n' 'priority: 407 | rest of v1.1.3 | 9999' > "$W/vp-plan2.md"
V2PLAN="$W/vp-plan2.md" v2render >/dev/null
vfp_is differ 'a priority change moves the focus fingerprint (HIMMEL-6829)'
sed 's/labels: \["held"\]/labels: []/' "$vp/HIMMEL-420.md" > "$W/h420.md" && cp "$W/h420.md" "$vp/HIMMEL-420.md"
v2render >/dev/null
vfp_is differ 'releasing a hold moves the focus fingerprint (HIMMEL-6829)'

printf '%s\n' "$fails failure(s)"
[ "$fails" -eq 0 ]
