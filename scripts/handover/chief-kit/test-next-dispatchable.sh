#!/usr/bin/env bash
# shellcheck disable=SC2015  # A && B || C is intentional in the pass/fail reporting lines, as in test-brief-lint.sh
# test-next-dispatchable.sh — Exercises next-dispatchable.sh on a
# fixture Jira mirror, a fixture manifest + worker doc, and stubbed gh / cloud-route
# (NEXT_DISPATCH_GH_CMD / NEXT_DISPATCH_CLASSIFY_CMD): no real mirror, Jira, gh
# or worktree is touched. NEXT_DISPATCH overrides the script under test (the RED
# control: a missing script fails every row). bash 3.2-safe.
#
# Run: bash scripts/handover/chief-kit/test-next-dispatchable.sh
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="${NEXT_DISPATCH:-$HERE/next-dispatchable.sh}"

fails=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; fails=$((fails + 1)); }
has() { # <name> <haystack> <needle>
    case "$2" in *"$3"*) pass "$1" ;; *) fail "$1 (missing '$3' in: $2)" ;; esac
}
lacks() { # <name> <haystack> <needle>
    case "$2" in *"$3"*) fail "$1 (found '$3' in: $2)" ;; *) pass "$1" ;; esac
}

WORK="$(mktemp -d "${TMPDIR:-/tmp}/next-dispatch-test.XXXXXX")" || exit 1
trap 'rm -rf "$WORK"' EXIT
# the default worker records live under the status state dir: keep it in the fixture
export TICKET_STATUS_STATE_DIR="$WORK/ts-none"
# and the admissions ledger: the real one must never admit a fixture key
export HIMMEL_ADMISSIONS_LEDGER="$WORK/ledger-none.jsonl"
M="$WORK/jira-mirror/HIMMEL"; mkdir -p "$M"

mk() { # <key> <status> <prio> <labels json> <fixVersions json> <blocked_by json> <title> <body>; MK_BARE=1 leaves the body without a DoD and Proof tail
    local tail='\n\nDoD\n- the row is green\n\nProof\n- a RED row that fails before the change\n'
    [ "${MK_BARE:-0}" = 1 ] && tail=''
    printf -- '---\nkey: "%s"\ntype: "Task"\nstatus: "%s"\nstatusCategory: "x"\npriority: "%s"\nlabels: %s\nfixVersions: %s\nparent: null\nlinks:\n  blocks: []\n  blocked_by: %s\n  relates: []\n---\n\n# %s: %s\n\n## Description\n\n%s'"$tail"'\n' \
        "$1" "$2" "$3" "$4" "$5" "$6" "$1" "$7" "$8" > "$M/$1.md"
}
retype() { # <fixture file> <type>: portable in-place edit (no sed -i: BSD and GNU differ)
    sed "s/^type: \"Task\"/type: \"$2\"/" "$1" > "$1.tmp" && mv "$1.tmp" "$1"
}
ago() { # <file> <hours>: set the file's mtime that far into the past (no touch -d: BSD and GNU differ)
    python3 -I -c 'import os, sys, time
t = time.time() - float(sys.argv[2]) * 3600
os.utime(sys.argv[1], (t, t))' "$1" "$2" || fail "could not backdate $1"
}
mk HIMMEL-1 "To Do" Medium '[]' '["v1.0.2"]' '[]' "free later version" "Edit scripts/lib/alpha.sh only."
mk HIMMEL-2 "To Do" Medium '[]' '["v1.0.1"]' '[]' "free earlier version" "Edit scripts/lib/beta.sh only."
mk HIMMEL-3 "To Do" High '[]' '["v1.0.1"]' '[]' "collides with an open PR" "Edit scripts/lib/pr-held.sh please."
mk HIMMEL-4 "To Do" High '[]' '["v1.0.1"]' '[]' "collides with a live worker" "Edit scripts/handover/chief-kit/live-file.sh please."
mk HIMMEL-5 "To Do" High '["operator-decision"]' '["v1.0.1"]' '[]' "decision pending" "Edit scripts/lib/gamma.sh."
mk HIMMEL-6 "To Do" High '["blocked"]' '["v1.0.1"]' '[]' "blocked label" "Edit scripts/lib/delta.sh."
mk HIMMEL-7 "In Progress" High '[]' '["v1.0.1"]' '[]' "already started" "Edit scripts/lib/eps.sh."
mk HIMMEL-8 "To Do" High '[]' '["v1.0.1"]' '["blocked by HIMMEL-1"]' "blocked by an open ticket" "Edit scripts/lib/zeta.sh."
mk HIMMEL-9 "To Do" Highest '[]' '["v1.0.1"]' '[]' "a hook ticket" "Edit scripts/hooks/some-hook.sh."
mk HIMMEL-10 "To Do" High '[]' '["v1.0.1"]' '[]' "refused by the classifier" "Edit scripts/lib/eta.sh."
printf 'v1.0.1\tfalse\t\nv1.0.2\tfalse\t\nv1.0.0\ttrue\t2026-01-01\n' > "$WORK/jira-mirror/HIMMEL.versions.tsv"

cat > "$WORK/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_ARGS"
[ -f "$GH_FAIL" ] && exit 1
if [ "$2" = view ]; then cat "$PR_BODY_DIR/$3" 2>/dev/null || exit 1; exit 0; fi
if [ "$2" = list ]; then
    case "$*" in *merged*) [ -f "$MERGED_FAIL" ] && exit 1; cat "$MERGED_TSV" ;; *headRefName*) cat "$PRS_TSV" ;; *) echo 4242 ;; esac
else echo scripts/lib/pr-held.sh; fi
EOF
cat > "$WORK/classify" <<'EOF'
#!/usr/bin/env bash
for k in "$@"; do
    case "$k" in
        HIMMEL-2) printf '%s\tCLOUD-OK\tstub\n' "$k" ;;
        HIMMEL-9) printf '%s\tHOOK-BYPASS\tstub\n' "$k" ;;
        HIMMEL-10) printf '%s\tBLOCKED\tstub\n' "$k" ;;
        *) printf '%s\tLOCAL-NATIVE\tstub\n' "$k" ;;
    esac
done
EOF
chmod +x "$WORK/gh" "$WORK/classify"
export GH_FAIL="$WORK/gh.fail"
export GH_ARGS="$WORK/gh.args"
: > "$GH_ARGS"
export PRS_TSV="$WORK/prs.tsv"
export MERGED_TSV="$WORK/merged.tsv" MERGED_FAIL="$WORK/merged.fail"
: > "$MERGED_TSV"
printf '4243\tfix(x): [HIMMEL-7] already started\tfix/himmel-7-started\n4244\tfix(x): [HIMMEL-52] in review\tfix/himmel-52-y\n' > "$PRS_TSV"

WORKER="$WORK/HIMMEL-99-N1-live.md"
# shellcheck disable=SC2016  # the backticks are literal doc text, not a command substitution
printf '# live\n> **Scope / do not:** writes confined to `scripts/handover/chief-kit/live-file.sh` and its test.\n' > "$WORKER"
printf '{"schema":1,"legs":[{"doc":"%s","label":"N1"}]}\n' "$WORKER" > "$WORK/fleet.json"

run() { NEXT_DISPATCH_MIRROR="$M" NEXT_DISPATCH_GH_CMD="$WORK/gh" NEXT_DISPATCH_CLASSIFY_CMD="$WORK/classify" bash "$SUT" "$@" 2>/dev/null; }

out="$(run --workers-from "$WORK/fleet.json")"
has "a free To Do ticket is listed" "$out" "HIMMEL-1	"
has "a CLOUD-OK ticket is listed as CLOUD" "$out" "CLOUD	HIMMEL-2"
has "a hook ticket is LOCAL and tagged hook" "$out" "HIMMEL-9	Highest"
has "the hook ticket carries the hook tag" "$(printf '%s\n' "$out" | grep 'HIMMEL-9	')" "	hook"
has "the listed line names the touched files" "$out" "files=scripts/lib/beta.sh"
lacks "a ticket colliding with an open PR is excluded" "$out" "HIMMEL-3	"
lacks "a ticket colliding with a live worker's scope is excluded" "$out" "HIMMEL-4	"
lacks "an operator-decision ticket is excluded" "$out" "HIMMEL-5	"
lacks "a blocked-label ticket is excluded" "$out" "HIMMEL-6	"
lacks "a ticket not in To Do is excluded" "$out" "HIMMEL-7	"
lacks "a ticket blocked by an open ticket is excluded" "$out" "HIMMEL-8	"
lacks "a BLOCKED classification is dropped" "$out" "HIMMEL-10	"
first="$(printf '%s\n' "$out" | grep -v '^#' | head -n 1 | cut -f2)"
[ "$first" = HIMMEL-9 ] && pass "ranked: earliest version, then priority first" || fail "ranked first is '$first' (want HIMMEL-9)"
order="$(printf '%s\n' "$out" | grep -v '^#' | cut -f2 | paste -sd, -)"
[ "$order" = "HIMMEL-9,HIMMEL-2,HIMMEL-1" ] && pass "ranked: v1.0.1 before v1.0.2" || fail "order is '$order'"

top1="$(run --top 1 --workers-from "$WORK/fleet.json" | grep -vc '^#')"
[ "$top1" = 1 ] && pass "--top caps the list" || fail "--top 1 printed $top1 lines"

: > "$GH_FAIL"
unk="$(run --workers-from "$WORK/fleet.json")"
has "a failing gh is reported, not treated as no PRs" "$unk" "open PRs unknown"
unk_rows="$(printf '%s\n' "$unk" | grep -vc '^#')"
[ "$unk_rows" = 0 ] && pass "a failing gh lists no row: an unread PR list could hold any ticket's files" || fail "a failing gh still listed $unk_rows row(s)"
rm -f "$GH_FAIL"

nc="$(run --no-classify --workers-from "$WORK/fleet.json")"
has "--no-classify lists survivors as LOCAL?" "$nc" "LOCAL?	HIMMEL-1"

printf 'scripts/lib/alpha.sh\n' > "$WORK/held.txt"
hl="$(run --held "$WORK/held.txt" --workers-from "$WORK/fleet.json")"
lacks "--held excludes a colliding ticket" "$hl" "HIMMEL-1	"

bash "$SUT" --bogus >/dev/null 2>&1; rc=$?
[ "$rc" = 2 ] && pass "an unknown flag is a usage error (rc 2)" || fail "unknown flag rc=$rc"

bash "$SUT" --top 0 >/dev/null 2>&1; rc=$?
[ "$rc" = 2 ] && pass "--top 0 is a usage error (rc 2)" || fail "--top 0 rc=$rc"
bash "$SUT" --top x >/dev/null 2>&1; rc=$?
[ "$rc" = 2 ] && pass "--top non-numeric is a usage error (rc 2)" || fail "--top x rc=$rc"

# unknown blocker fails closed; later survivors still surface past an all-BLOCKED first chunk
M2="$WORK/m2/HIMMEL"; mkdir -p "$M2"
M_SAVE="$M"; M="$M2"
mk HIMMEL-20 "To Do" Highest '[]' '[]' '[]' "blocked by classifier a" "Edit scripts/lib/a1.sh."
mk HIMMEL-21 "To Do" Highest '[]' '[]' '[]' "blocked by classifier b" "Edit scripts/lib/a2.sh."
mk HIMMEL-22 "To Do" Highest '[]' '[]' '[]' "blocked by classifier c" "Edit scripts/lib/a3.sh."
mk HIMMEL-23 "To Do" High '[]' '[]' '[]' "survivor" "Edit scripts/lib/a4.sh."
mk HIMMEL-24 "To Do" Medium '[]' '[]' '["blocked by HIMMEL-9999"]' "unknown blocker" "Edit scripts/lib/a5.sh."
M="$M_SAVE"
cat > "$WORK/classify2" <<'EOF'
#!/usr/bin/env bash
for k in "$@"; do
    case "$k" in
        HIMMEL-20|HIMMEL-21|HIMMEL-22) printf '%s\tBLOCKED\tstub\n' "$k" ;;
        *) printf '%s\tLOCAL-NATIVE\tstub\n' "$k" ;;
    esac
done
EOF
chmod +x "$WORK/classify2"
ch="$(NEXT_DISPATCH_MIRROR="$M2" NEXT_DISPATCH_GH_CMD="$WORK/gh" NEXT_DISPATCH_CLASSIFY_CMD="$WORK/classify2" bash "$SUT" --top 1 2>/dev/null)"
has "a BLOCKED first chunk does not hide a later survivor" "$ch" "LOCAL	HIMMEL-23"
lacks "a ticket with an unknown blocker is excluded" "$ch" "HIMMEL-24	"

# two tickets naming the same file are never listed together
M3="$WORK/m3/HIMMEL"; mkdir -p "$M3"
M_SAVE="$M"; M="$M3"
mk HIMMEL-30 "To Do" Highest '[]' '[]' '[]' "first on shared file" "Edit scripts/lib/shared.sh."
mk HIMMEL-31 "To Do" High '[]' '[]' '[]' "second on shared file" "Edit scripts/lib/shared.sh too."
mk HIMMEL-32 "To Do" Medium '[]' '[]' '[]' "independent" "Edit scripts/lib/other.sh."
M="$M_SAVE"
sh3="$(NEXT_DISPATCH_MIRROR="$M3" NEXT_DISPATCH_GH_CMD="$WORK/gh" NEXT_DISPATCH_CLASSIFY_CMD="$WORK/classify2" bash "$SUT" 2>/dev/null)"
has "the top ticket on a shared file is listed" "$sh3" "HIMMEL-30	"
lacks "a second ticket on the same file is not listed with it" "$sh3" "HIMMEL-31	"
has "an independent ticket is still listed" "$sh3" "HIMMEL-32	"

# an unreadable manifest is reported, not treated as no live workers
lu="$(run --workers-from "$WORK/no-such-fleet.json")"
has "an unreadable manifest is reported in the header" "$lu" "live workers unknown"
printf '{"schema":1,"legs":[{"doc":"%s/gone.md","label":"N2"}]}\n' "$WORK" > "$WORK/fleet-gone.json"
lg="$(run --workers-from "$WORK/fleet-gone.json")"
has "an unreadable worker doc is reported in the header" "$lg" "live workers unknown"
lacks "a readable manifest is not reported unknown" "$out" "live workers unknown"

# a workers-array manifest reads like the pre-rename legs one; workers wins when both exist; the switch drops the old name
printf '{"schema":1,"workers":[{"doc":"%s","label":"N1"}]}\n' "$WORKER" > "$WORK/fleet-w.json"
ow="$(run --workers-from "$WORK/fleet-w.json")"
has "a workers manifest still lists a free ticket" "$ow" "HIMMEL-1	"
lacks "a workers manifest excludes a ticket colliding with a live worker's scope" "$ow" "HIMMEL-4	"
lacks "a workers manifest is not reported unknown" "$ow" "live workers unknown"
printf '{"schema":1,"legs":[{"doc":"%s/gone.md","label":"N2"}],"workers":[{"doc":"%s","label":"N1"}]}\n' "$WORK" "$WORKER" > "$WORK/fleet-both.json"
ob="$(run --workers-from "$WORK/fleet-both.json")"
lacks "a manifest with both arrays reads the workers one (HIMMEL-4 excluded)" "$ob" "HIMMEL-4	"
lacks "a manifest with both arrays is not reported unknown" "$ob" "live workers unknown"
off="$(HIMMEL_LEGACY_NAMES=0 run --workers-from "$WORK/fleet.json")"
has "with HIMMEL_LEGACY_NAMES=0 a legs-only manifest is reported unknown" "$off" "live workers unknown"
offw="$(HIMMEL_LEGACY_NAMES=0 run --workers-from "$WORK/fleet-w.json")"
lacks "with HIMMEL_LEGACY_NAMES=0 a workers manifest still excludes HIMMEL-4" "$offw" "HIMMEL-4	"
lacks "with HIMMEL_LEGACY_NAMES=0 a workers manifest is not reported unknown" "$offw" "live workers unknown"

# root files and plugins/ take part in the collision check
M4="$WORK/m4/HIMMEL"; mkdir -p "$M4"
M_SAVE="$M"; M="$M4"
mk HIMMEL-40 "To Do" High '[]' '[]' '[]' "touches package.json" "Bump a dep in package.json."
mk HIMMEL-41 "To Do" High '[]' '[]' '[]' "touches a plugin" "Edit plugins/foo/run.sh."
M="$M_SAVE"
printf 'package.json\nplugins/foo\n' > "$WORK/held4.txt"
rh="$(NEXT_DISPATCH_MIRROR="$M4" NEXT_DISPATCH_GH_CMD="$WORK/gh" NEXT_DISPATCH_CLASSIFY_CMD="$WORK/classify2" bash "$SUT" --held "$WORK/held4.txt" 2>/dev/null)"
lacks "a held root file excludes a ticket naming it" "$rh" "HIMMEL-40	"
lacks "a held plugins/ path excludes a ticket naming it" "$rh" "HIMMEL-41	"

# In Progress / In Review tickets nobody is working re-enter dispatch as RESUME, ranked first
M5="$WORK/m5/HIMMEL"; mkdir -p "$M5"
M_SAVE="$M"; M="$M5"
mk HIMMEL-50 "In Progress" Medium '[]' '[]' '[]' "orphan in progress" "Edit scripts/lib/r1.sh.

## Comments

### Op - 2026-10-15

Slice 2 merged.
Ticket stays open: slice 3 still owed.
Unrelated closing remark."
mk HIMMEL-51 "In Review" Low '[]' '[]' '[]' "orphan in review" "Edit scripts/lib/r2.sh."
mk HIMMEL-52 "In Progress" High '[]' '[]' '[]' "has an open PR" "Edit scripts/lib/r3.sh."
mk HIMMEL-53 "In Progress" High '[]' '[]' '[]' "has a live worker" "Edit scripts/lib/r4.sh."
mk HIMMEL-54 "In Progress" High '[]' '[]' '[]' "an epic" "Edit scripts/lib/r5.sh."
retype "$M5/HIMMEL-54.md" Epic
mk HIMMEL-55 "In Progress" High '["parked"]' '[]' '[]' "parked" "Edit scripts/lib/r6.sh."
mk HIMMEL-56 "To Do" Highest '[]' '[]' '[]' "plain to do" "Edit scripts/lib/r7.sh."
mk HIMMEL-57 "In Progress" High '["blocked"]' '[]' '[]' "blocked label" "Edit scripts/lib/r8.sh."
mk HIMMEL-58 "In Progress" High '[]' '[]' '["blocked by HIMMEL-56"]' "unresolved blocker" "Edit scripts/lib/r9.sh."
M="$M_SAVE"
LEG5="$WORK/HIMMEL-53-N9-live.md"; printf '> **Writes:** none named\n# live\n' > "$LEG5"
printf '{"schema":1,"legs":[{"doc":"%s","label":"N9"}]}\n' "$LEG5" > "$WORK/fleet5.json"
rs="$(NEXT_DISPATCH_MIRROR="$M5" NEXT_DISPATCH_GH_CMD="$WORK/gh" NEXT_DISPATCH_CLASSIFY_CMD="$WORK/classify2" bash "$SUT" --workers-from "$WORK/fleet5.json" 2>/dev/null)"
has "an In Progress ticket with no worker and no PR is listed as RESUME" "$rs" "RESUME	HIMMEL-50"
has "an In Review orphan is listed as RESUME" "$rs" "RESUME	HIMMEL-51"
has "a RESUME row carries the last stays-open comment line" "$rs" "last=Ticket stays open: slice 3 still owed."
lacks "an In Progress ticket with an open PR is not listed" "$rs" "HIMMEL-52	"
lacks "an In Progress ticket with a live worker is not listed" "$rs" "HIMMEL-53	"
lacks "an Epic is never a RESUME row" "$rs" "HIMMEL-54	"
lacks "a parked ticket is not listed" "$rs" "HIMMEL-55	"
lacks "a blocked-label In Progress ticket is not listed" "$rs" "HIMMEL-57	"
order5="$(printf '%s\n' "$rs" | grep -v '^#' | cut -f2 | paste -sd, -)"
[ "$order5" = "HIMMEL-50,HIMMEL-51,HIMMEL-56" ] && pass "RESUME rows rank before To Do" || fail "order5 is '$order5'"

# --resume-only lists only the orphans (the tick's cheap read); --owners names tickets held outside the manifest
ro="$(NEXT_DISPATCH_MIRROR="$M5" NEXT_DISPATCH_GH_CMD="$WORK/gh" bash "$SUT" --resume-only --owners "HIMMEL-51" 2>/dev/null)"
has "--resume-only lists a RESUME row" "$ro" "RESUME	HIMMEL-50"
lacks "--resume-only drops a ticket named by --owners" "$ro" "HIMMEL-51	"
lacks "--resume-only lists no To Do row" "$ro" "HIMMEL-56	"
lacks "an In Progress ticket with an unresolved blocker is not listed" "$ro" "HIMMEL-58	"
rl="$(NEXT_DISPATCH_MIRROR="$M5" NEXT_DISPATCH_GH_CMD="$WORK/gh" bash "$SUT" --resume-only --workers-from "$WORK/no-such-fleet.json" 2>/dev/null)"
has "an unreadable manifest is reported on the RESUME read" "$rl" "live workers unknown"
lacks "an unreadable manifest lists no RESUME row" "$rl" "RESUME	"
: > "$GH_FAIL"
rf="$(NEXT_DISPATCH_MIRROR="$M5" NEXT_DISPATCH_GH_CMD="$WORK/gh" bash "$SUT" --resume-only 2>/dev/null)"
rm -f "$GH_FAIL"
has "a failed open-PR read is reported on the RESUME read" "$rf" "open PRs unknown"
lacks "a failed open-PR read lists no RESUME row" "$rf" "RESUME	"

# IN CI tickets: a merged PR and no worker is a MERGED-NOT-CLOSED row, an open PR hides the ticket,
# no PR at all is a RESUME row; an unreadable merged-PR read lists no IN CI row.
M6="$WORK/m6/HIMMEL"; mkdir -p "$M6"
M_SAVE="$M"; M="$M6"
mk HIMMEL-70 "IN CI" Medium '[]' '[]' '[]' "in ci merged pr" "Edit scripts/lib/c1.sh."
mk HIMMEL-71 "IN CI" Medium '[]' '[]' '[]' "in ci open pr" "Edit scripts/lib/c2.sh."
mk HIMMEL-72 "IN CI" Medium '[]' '[]' '[]' "in ci no pr" "Edit scripts/lib/c3.sh."
mk HIMMEL-73 "IN CI" Medium '[]' '[]' '[]' "in ci merged pr live worker" "Edit scripts/lib/c4.sh."
mk HIMMEL-74 "IN CI" Medium '[]' '[]' '[]' "in ci lookalike merged key only" "Edit scripts/lib/c5.sh."
mk HIMMEL-75 "IN CI" Medium '[]' '[]' '[]' "in ci story with a merged pr" "Edit scripts/lib/c6.sh."
retype "$M6/HIMMEL-75.md" Story
M="$M_SAVE"
LEG6="$WORK/HIMMEL-73-N9-live.md"; printf '> **Writes:** none named\n# live\n' > "$LEG6"
printf '{"schema":1,"legs":[{"doc":"%s","label":"N9"}]}\n' "$LEG6" > "$WORK/fleet6.json"
printf '4300\tfix(x): [HIMMEL-70] merged\tfix/himmel-70-m\n4301\tfix(x): [HIMMEL-73] merged\tfix/himmel-73-m\n4302\tfix(x): [HIMMEL-71] earlier\tfix/himmel-71-e\n4303\tfix(x): [HIMMEL-740] lookalike\tfix/himmel-740-l\n4304\tfix(x): [HIMMEL-75] story merged\tfix/himmel-75-m\n' > "$MERGED_TSV"
printf '4310\tfix(x): [HIMMEL-71] open\tfix/himmel-71-o\n' > "$PRS_TSV"
rc6() { NEXT_DISPATCH_MIRROR="$M6" NEXT_DISPATCH_GH_CMD="$WORK/gh" bash "$SUT" --resume-only --workers-from "$WORK/fleet6.json" 2>/dev/null; }
: > "$GH_ARGS"
r6="$(rc6)"
# --search does not follow a repo rename, so every gh read must name the canonical slug
gh_repos="$(grep -o -e '--repo [^ ]*' "$GH_ARGS" | sort -u)"
merged_repos="$(grep -e '--state merged' "$GH_ARGS" | grep -o -e '--repo [^ ]*' | sort -u)"
if [ "$gh_repos" = "--repo yotamleo-org/Himmel" ] && [ "$merged_repos" = "--repo yotamleo-org/Himmel" ]; then pass "every gh read, the merged search included, names the canonical repo slug"
else fail "every gh read, the merged search included, names the canonical repo slug (got: ${gh_repos//$'\n'/ } / merged: ${merged_repos//$'\n'/ })"; fi
has "an IN CI ticket with a merged PR and no worker is a MERGED-NOT-CLOSED row" "$r6" "MERGED-NOT-CLOSED	HIMMEL-70"
lacks "an IN CI ticket with an open PR is not listed (even with an earlier merged one)" "$r6" "HIMMEL-71	"
has "an IN CI ticket with no PR is a RESUME row" "$r6" "RESUME	HIMMEL-72"
lacks "an IN CI ticket with a live worker is not listed" "$r6" "HIMMEL-73	"
has "a merged PR citing a lookalike key does not close the ticket" "$r6" "RESUME	HIMMEL-74"
has "an IN CI Story with a merged PR is a MERGED-NOT-CLOSED row" "$r6" "MERGED-NOT-CLOSED	HIMMEL-75"
lacks "an IN CI Story with a merged PR is not a RESUME row" "$r6" "RESUME	HIMMEL-75"
: > "$MERGED_FAIL"
r6f="$(rc6)"
rm -f "$MERGED_FAIL"
has "a failed merged-PR read is reported" "$r6f" "merged PRs unknown"
lacks "a failed merged-PR read lists no IN CI row" "$r6f" "HIMMEL-7"
: > "$MERGED_TSV"
printf '4243\tfix(x): [HIMMEL-7] already started\tfix/himmel-7-started\n4244\tfix(x): [HIMMEL-52] in review\tfix/himmel-52-y\n' > "$PRS_TSV"

# A ticket the status funnel returned to To Do when its worker WRAPPED (a worker record in state
# wrapped, with a resume brief) is a RESUME row carrying the brief, never an ordinary To Do row;
# a held one is not offered, and a ticket whose Done write is pending is never a RESUME row.
W="$WORK/ts/workers"; mkdir -p "$W"
MW="$WORK/mw/HIMMEL"; mkdir -p "$MW"
M_SAVE="$M"; M="$MW"
mk HIMMEL-60 "To Do" Medium '[]' '[]' '[]' "wrapped with a brief" "Edit scripts/lib/w1.sh."
mk HIMMEL-61 "To Do" Highest '[]' '[]' '[]' "plain to do" "Edit scripts/lib/w2.sh."
mk HIMMEL-62 "To Do" High '["held"]' '[]' '[]' "wrapped and held" "Edit scripts/lib/w3.sh."
mk HIMMEL-63 "In Review" High '[]' '[]' '[]' "done write pending" "Edit scripts/lib/w4.sh."
mk HIMMEL-64 "To Do" High '[]' '[]' '[]' "wrapped without a brief" "Edit scripts/lib/w5.sh."
mk HIMMEL-65 "To Do" High '[]' '[]' '[]' "merged, mirror still To Do" "Edit scripts/lib/w6.sh."
M="$M_SAVE"
printf '{"key":"HIMMEL-60","state":"wrapped","resume_brief":"/x/HIMMEL-60-RESUME.md"}\n' > "$W/HIMMEL-60.json"
printf '{"key":"HIMMEL-62","state":"wrapped","resume_brief":"/x/HIMMEL-62-RESUME.md"}\n' > "$W/HIMMEL-62.json"
printf '{"key":"HIMMEL-64","state":"wrapped"}\n' > "$W/HIMMEL-64.json"
printf '{"ts":"t","event":"merge","key":"HIMMEL-63","contract":"yes","result":"miss","stage":"transition"}\n{"ts":"t","event":"merge","key":"HIMMEL-65","contract":"yes","result":"ok"}\n' > "$WORK/ts/status-events.jsonl"
rw="$(NEXT_DISPATCH_MIRROR="$MW" NEXT_DISPATCH_GH_CMD="$WORK/gh" NEXT_DISPATCH_CLASSIFY_CMD="$WORK/classify2" bash "$SUT" --workers-dir "$W" --workers-from "$WORK/fleet5.json" 2>/dev/null)"
has "a wrapped To Do with a resume brief is a RESUME row" "$rw" "RESUME	HIMMEL-60"
has "the RESUME row carries the resume brief" "$(printf '%s\n' "$rw" | grep 'HIMMEL-60	')" "brief=/x/HIMMEL-60-RESUME.md"
lacks "a wrapped To Do is never also an ordinary To Do row" "$rw" "LOCAL	HIMMEL-60"
lacks "a held wrapped To Do is not offered" "$rw" "HIMMEL-62	"
lacks "a ticket whose Done write is pending is never a RESUME row" "$rw" "HIMMEL-63	"
has "a wrapped To Do without a brief stays an ordinary To Do row" "$rw" "LOCAL	HIMMEL-64"
lacks "a To Do ticket whose contract=yes merge is recorded is never dispatched (HIMMEL-7434)" "$rw" "HIMMEL-65	"
orderw="$(printf '%s\n' "$rw" | grep -v '^#' | cut -f2 | paste -sd, -)"
[ "$orderw" = "HIMMEL-60,HIMMEL-61,HIMMEL-64" ] && pass "a wrapped RESUME row ranks before To Do" || fail "orderw is '$orderw'"
rd="$(TICKET_STATUS_STATE_DIR="$WORK/ts" NEXT_DISPATCH_MIRROR="$MW" NEXT_DISPATCH_GH_CMD="$WORK/gh" bash "$SUT" --resume-only --workers-from "$WORK/fleet5.json" 2>/dev/null)"
has "the workers dir defaults to the status state dir's" "$rd" "RESUME	HIMMEL-60"

# Windows and WSL are dropped: a To Do candidate whose summary names them is skipped (one counted
# line) unless it carries the windows-removal label; 'context window' style titles are untouched.
M6="$WORK/jira-mirror6/HIMMEL"; mkdir -p "$M6"
M_SAVE="$M"; M="$M6"
mk HIMMEL-70 "To Do" High '[]' '[]' '[]' "WSL station triage" "Edit scripts/lib/p70.sh only."
mk HIMMEL-71 "To Do" High '["windows-removal"]' '[]' '[]' "WSL station triage removal" "Edit scripts/lib/p71.sh only."
mk HIMMEL-72 "To Do" High '[]' '[]' '[]' "Handle Windows cwd separators" "Edit scripts/lib/p72.sh only."
mk HIMMEL-73 "To Do" High '[]' '[]' '[]' "cap the context window" "Edit scripts/lib/p73.sh only."
mk HIMMEL-74 "To Do" High '[]' '[]' '[]' "Windowed rate limit" "Edit scripts/lib/p74.sh only."
mk HIMMEL-75 "To Do" High '[]' '[]' '[]' "Close WRAPPED chief windows and worker windows" "Edit scripts/lib/p75.sh only."
mk HIMMEL-76 "To Do" High '[]' '[]' '[]' "Spread work over 5-hour windows" "Edit scripts/lib/p76.sh only."
mk HIMMEL-77 "To Do" High '[]' '[]' '[]' "Trim the context-windows report" "Edit scripts/lib/p77.sh only."
M="$M_SAVE"
pw="$(NEXT_DISPATCH_MIRROR="$M6" NEXT_DISPATCH_GH_CMD="$WORK/gh" bash "$SUT" --no-classify 2>/dev/null)"; pw_rc=$?
[ "$pw_rc" = 0 ] && pass "the platform-filter run exits 0" || fail "platform-filter run rc=$pw_rc"
lacks "a WSL candidate is omitted" "$pw" "HIMMEL-70	"
lacks "a Windows candidate is omitted" "$pw" "HIMMEL-72	"
has "a windows-removal labelled candidate is kept" "$pw" "HIMMEL-71	"
has "a 'context window' title is kept" "$pw" "HIMMEL-73	"
has "a 'Windowed' title is kept" "$pw" "HIMMEL-74	"
has "a 'chief windows' title is kept" "$pw" "HIMMEL-75	"
has "a '5-hour windows' title is kept" "$pw" "HIMMEL-76	"
has "a 'context-windows' title is kept" "$pw" "HIMMEL-77	"
has "the skipped line counts and names the skipped keys" "$pw" "# skipped 2 windows/wsl ticket(s): HIMMEL-70 HIMMEL-72"
pw0="$(run --workers-from "$WORK/fleet.json")"; pw0_rc=$?
[ "$pw0_rc" = 0 ] && pass "the unrelated run exits 0" || fail "unrelated run rc=$pw0_rc"
lacks "no skipped line when nothing matched" "$pw0" "# skipped"

# Fail closed: with the pattern file gone the script exits 2 rather than dispatching unfiltered.
NF="$WORK/nopat"; mkdir -p "$NF/scripts/handover/chief-kit" "$NF/scripts/lib"
cp "$(dirname "$SUT")/../../lib/env_alias.py" "$NF/scripts/lib/env_alias.py"
cp "$SUT" "$NF/scripts/handover/chief-kit/next-dispatchable.sh"
NEXT_DISPATCH_MIRROR="$M6" NEXT_DISPATCH_GH_CMD="$WORK/gh" bash "$NF/scripts/handover/chief-kit/next-dispatchable.sh" --no-classify >/dev/null 2>&1; nf_rc=$?
[ "$nf_rc" = 2 ] && pass "a missing pattern file exits 2" || fail "missing pattern file rc=$nf_rc"

# Operator priority pool. One ticket per tier, keys shuffled against the tiers (a
# tier-1 ticket has the HIGHEST key), so only the tier order can put them right.
M7="$WORK/jira-mirror7/HIMMEL"; mkdir -p "$M7"
M_SAVE="$M"; M="$M7"
mk HIMMEL-140 "To Do" Medium '[]' '["v1.0.1"]' '[]' "tier4 early version" "Edit scripts/lib/q1.sh only."
mk HIMMEL-141 "To Do" Highest '[]' '["v1.0.2"]' '[]' "tier5 later version" "Edit scripts/lib/q2.sh only."
mk HIMMEL-130 "To Do" Medium '["security"]' '["v1.0.1"]' '[]' "tier3 security label" "Edit scripts/lib/q3.sh only."
mk HIMMEL-131 "To Do" High '[]' '["v1.0.1"]' '[]' "tier3 high bug" "Edit scripts/lib/q4.sh only."
retype "$M7/HIMMEL-131.md" Bug
mk HIMMEL-132 "To Do" Medium '[]' '[]' '[]' "medium bug is not tier3" "Edit scripts/lib/q5.sh only."
retype "$M7/HIMMEL-132.md" Bug
mk HIMMEL-120 "To Do" Low '["operator-directed"]' '["v1.0.1"]' '[]' "tier2 operator directed" "Edit scripts/lib/q6.sh only."
mk HIMMEL-110 "To Do" Low '["must-v1.1.3"]' '[]' '[]' "tier1 by label" "Edit scripts/lib/q7.sh only."
mk HIMMEL-111 "To Do" Low '[]' '[]' '[]' "tier1 second on the line" "Edit scripts/lib/q8.sh only."
mk HIMMEL-112 "To Do" Low '[]' '[]' '[]' "tier1 first on the line" "Edit scripts/lib/q9.sh only."
mk HIMMEL-113 "To Do" Low '[]' '[]' '[]' "listed but cloud only" "Edit scripts/lib/q10.sh only."
mk HIMMEL-150 "In Progress" Low '[]' '[]' '[]' "orphan in progress" "Edit scripts/lib/q11.sh only."
mk HIMMEL-170 "To Do" Low '[]' '[]' '[]' "named only in a bracket" "Edit scripts/lib/q12.sh only."
mk HIMMEL-171 "To Do" Low '[]' '[]' '[]' "part of a dotted number" "Edit scripts/lib/q13.sh only."
M="$M_SAVE"
printf 'v1.0.1\tfalse\t\nv1.0.2\tfalse\t\n' > "$WORK/jira-mirror7/HIMMEL.versions.tsv"
CDOC="$WORK/chief-doc.md"
printf '# chief\n\n## Live state\n\nlegs: none\npriority: K1 | 112 SCORECARD | 111 113(CLOUD) | 9999\nqueue: none\n\n## Later\n\npriority: 140\n' > "$CDOC"
run7() { NEXT_DISPATCH_MIRROR="$M7" NEXT_DISPATCH_GH_CMD="$WORK/gh" NEXT_DISPATCH_CLASSIFY_CMD="$WORK/classify2" bash "$SUT" "$@" 2>/dev/null; }
o7="$(run7 --top 20 --doc "$CDOC" | grep -v '^#' | grep -v '^RESUME' | cut -f2 | paste -sd, -)"
[ "$o7" = "HIMMEL-112,HIMMEL-111,HIMMEL-110,HIMMEL-120,HIMMEL-131,HIMMEL-130,HIMMEL-140,HIMMEL-141,HIMMEL-132,HIMMEL-170,HIMMEL-171" ] && pass "one ticket per tier on shuffled input comes out in tier order" || fail "tier order is '$o7'"
lacks "a (CLOUD) entry on the priority line is excluded from local output" "$o7" "HIMMEL-113"
o7b="$(run7 --doc "$CDOC" --priority-pool-only | grep -v '^#' | cut -f2 | paste -sd, -)"
[ "$o7b" = "HIMMEL-112,HIMMEL-111,HIMMEL-110,HIMMEL-120,HIMMEL-131,HIMMEL-130,HIMMEL-140" ] && pass "--priority-pool-only lists tiers 1-4 only: the rest of the earliest version follows tier 3, a later version stays out" || fail "pool-only is '$o7b'"
lacks "--priority-pool-only prints no RESUME row" "$(run7 --doc "$CDOC" --priority-pool-only)" "RESUME"
printf '# chief\n\n## Live state\n\n**priority:** K1 | 112 SCORECARD | 111 113 (CLOUD) | [PR 170] since 10.171\nqueue: none\n' > "$WORK/chief-doc-bold.md"
o7d="$(run7 --doc "$WORK/chief-doc-bold.md" --priority-pool-only | grep -v '^#' | cut -f2 | paste -sd, -)"
[ "$o7d" = "HIMMEL-112,HIMMEL-111,HIMMEL-110,HIMMEL-120,HIMMEL-131,HIMMEL-130,HIMMEL-140" ] && pass "a bold **priority:** line with '113 (CLOUD)' and bracketed or dotted numbers ranks as written" || fail "bold-line pool is '$o7d'"
o7c="$(run7 --priority-pool-only |grep -v '^#' | cut -f2 | paste -sd, -)"
[ "$o7c" = "HIMMEL-110,HIMMEL-120,HIMMEL-131,HIMMEL-130,HIMMEL-140" ] && pass "without --doc the pool is the labels, tiers 2-3 and the rest of the earliest version" || fail "no-doc pool is '$o7c'"
M8="$WORK/jira-mirror8/HIMMEL"; mkdir -p "$M8"
M_SAVE="$M"; M="$M8"
mk HIMMEL-160 "To Do" Highest '[]' '["v1.0.1"]' '[]' "only tier5" "Edit scripts/lib/w1.sh only."
M="$M_SAVE"
e8="$(NEXT_DISPATCH_MIRROR="$M8" NEXT_DISPATCH_GH_CMD="$WORK/gh" NEXT_DISPATCH_CLASSIFY_CMD="$WORK/classify2" bash "$SUT" --priority-pool-only 2>/dev/null)"; e8_rc=$?
[ "$e8_rc" = 0 ] && pass "an empty pool exits 0" || fail "empty pool rc=$e8_rc"
has "an empty pool prints POOL-EMPTY" "$e8" "POOL-EMPTY"
lacks "an empty pool prints no dispatchable ticket row" "$(printf '%s\n' "$e8" | grep -v '^NEXT-TIER')" "HIMMEL-160"
M9="$WORK/jira-mirror9/HIMMEL"; mkdir -p "$M9"
M_SAVE="$M"; M="$M9"
mk HIMMEL-20 "To Do" Low '["operator-directed"]' '[]' '[]' "pool ticket the classifier blocks" "Edit scripts/lib/w2.sh only."
M="$M_SAVE"
e9="$(NEXT_DISPATCH_MIRROR="$M9" NEXT_DISPATCH_GH_CMD="$WORK/gh" NEXT_DISPATCH_CLASSIFY_CMD="$WORK/classify2" bash "$SUT" --priority-pool-only 2>/dev/null)"
has "a pool whose tickets are all classified BLOCKED prints POOL-EMPTY" "$e9" "POOL-EMPTY"

# --- the pool offers worker-less In Progress tickets and reads the priority: line as written ---
M11="$WORK/jira-mirror11/HIMMEL"; mkdir -p "$M11"
M_SAVE="$M"; M="$M11"
mk HIMMEL-401 "In Progress" Low '[]' '[]' '[]' "resume keyed first on the line" "Edit scripts/lib/s1.sh only."
mk HIMMEL-402 "To Do" Low '[]' '[]' '[]' "todo keyed second on the line" "Edit scripts/lib/s2.sh only."
mk HIMMEL-403 "In Progress" Low '["operator-directed"]' '[]' '[]' "resume tier 2" "Edit scripts/lib/s3.sh only."
mk HIMMEL-404 "To Do" Low '["operator-directed"]' '[]' '[]' "todo tier 2" "Edit scripts/lib/s4.sh only."
mk HIMMEL-405 "In Progress" Low '[]' '[]' '[]' "resume tier 5 is not pool" "Edit scripts/lib/s5.sh only."
mk HIMMEL-406 "In Progress" Low '[]' '[]' '[]' "resume keyed cloud with a space" "Edit scripts/lib/s6.sh only."
mk HIMMEL-407 "To Do" Low '[]' '[]' '[]' "todo keyed cloud with a space" "Edit scripts/lib/s7.sh only."
mk HIMMEL-408 "To Do" Low '[]' '[]' '[]' "keyed on a bold priority line" "Edit scripts/lib/s8.sh only."
mk HIMMEL-409 "To Do" Low '[]' '[]' '[]' "keyed only under a later heading" "Edit scripts/lib/s9.sh only."
mk HIMMEL-410 "In Progress" Low '[]' '[]' '[]' "resume keyed with a worker" "Edit scripts/lib/s10.sh only."
mk HIMMEL-411 "To Do" Low '[]' '[]' '[]' "named only in a plus annotation" "Edit scripts/lib/s11.sh only."
mk HIMMEL-412 "To Do" Low '[]' '[]' '[]' "named only in a bare annotation" "Edit scripts/lib/s12.sh only."
mk HIMMEL-413 "To Do" Low '[]' '[]' '[]' "keyed head of an annotated entry" "Edit scripts/lib/s13.sh only."
mk HIMMEL-414 "To Do" Low '[]' '[]' '[]' "second number of a plus run" "Edit scripts/lib/s14.sh only."
mk HIMMEL-415 "To Do" Low '[]' '[]' '[]' "bare number in a paren with no plus" "Edit scripts/lib/s15.sh only."
mk HIMMEL-416 "To Do" Low '[]' '[]' '[]' "prefixed key inside a paren" "Edit scripts/lib/s16.sh only."
M="$M_SAVE"
LEG11="$WORK/HIMMEL-410-N11-live.md"; printf '> **Writes:** none named\n# live\n' > "$LEG11"
printf '{"schema":1,"legs":[{"doc":"%s","label":"N11"}]}\n' "$LEG11" > "$WORK/fleet11.json"
run11() { NEXT_DISPATCH_MIRROR="$M11" NEXT_DISPATCH_GH_CMD="$WORK/gh" NEXT_DISPATCH_CLASSIFY_CMD="$WORK/classify2" bash "$SUT" "$@" 2>/dev/null; }
D11="$WORK/chief-doc11.md"
printf '# chief\n\n## Live state\n\npriority: 401 402 406 407(CLOUD) | 410 413(NOTE +411 and 2026 plan)\n' > "$D11"
rows11() { grep -v '^#' | cut -f1,2 | tr '\t' ':' | paste -sd, -; }
o11="$(run11 --doc "$D11" --workers-from "$WORK/fleet11.json" --priority-pool-only | rows11)"
[ "$o11" = "RESUME:HIMMEL-401,RESUME:HIMMEL-406,LOCAL:HIMMEL-402,LOCAL:HIMMEL-413,LOCAL:HIMMEL-411,RESUME:HIMMEL-403,LOCAL:HIMMEL-404" ] && pass "pool-only: tier 1-3 RESUME rows lead their tier's To Do rows" || fail "pool-only with RESUME is '$o11'"
lacks "pool-only: a tier-5 In Progress ticket is not a pool row" "$o11" "HIMMEL-405"
lacks "pool-only: a worker-less pool key with a live worker is not a RESUME row" "$o11" "HIMMEL-410"
lacks "pool-only: a 'NNN (CLOUD)' To Do ticket is excluded" "$o11" "HIMMEL-407"
printf '# chief\n\n## Live state\n\n**priority:** 408 | 407 (CLOUD) 406 (CLOUD)\n\n## Later\n\npriority: 409\n' > "$D11"
b11="$(run11 --doc "$D11" --workers-from "$WORK/fleet11.json" --priority-pool-only | rows11)"
[ "$b11" = "LOCAL:HIMMEL-408,RESUME:HIMMEL-403,LOCAL:HIMMEL-404" ] && pass "a bold **priority:** line is read, a 'NNN (CLOUD)' token is excluded, a priority: under a later heading is not" || fail "bold-line pool is '$b11'"
printf '# chief\n\n## Live state\n\npriority: 413(NOTE +411 414) 400(verify 415 HIMMEL-416) 412x\n' > "$D11"
p11="$(run11 --doc "$D11" --workers-from "$WORK/fleet11.json" --priority-pool-only | rows11)"
has "a number right after a plus inside parens is a key" "$p11" "HIMMEL-411"
has "every number from a plus to the closing paren is a key" "$p11" "HIMMEL-414"
lacks "a bare number inside parens with no plus is not a key" "$p11" "HIMMEL-415"
has "a HIMMEL-NNNN inside parens is a key" "$p11" "HIMMEL-416"
lacks "a key glued to letters is not a key" "$p11" "HIMMEL-412"
printf '# chief\n\n## Live state\n\npriority: 402\n' > "$D11"
e11="$(NEXT_DISPATCH_MIRROR="$M11" NEXT_DISPATCH_GH_CMD="$WORK/gh" NEXT_DISPATCH_CLASSIFY_CMD="$WORK/classify2" bash "$SUT" --doc "$D11" --top 1 --workers-from "$WORK/fleet11.json" --priority-pool-only 2>/dev/null | rows11)"
[ "$e11" = "LOCAL:HIMMEL-402" ] && pass "pool-only: --top caps RESUME and To Do rows together" || fail "top-capped pool is '$e11'"
r11="$(NEXT_DISPATCH_MIRROR="$M11" NEXT_DISPATCH_GH_CMD="$WORK/gh" NEXT_DISPATCH_CLASSIFY_CMD="$WORK/classify2" bash "$SUT" --doc "$D11" --workers-from "$WORK/fleet11.json" --priority-pool-only --resume-only 2>/dev/null | rows11)"
[ "$r11" = "RESUME:HIMMEL-403" ] && pass "pool-only with --resume-only prints only RESUME rows and no POOL-EMPTY" || fail "pool-only resume-only is '$r11'"
M12="$WORK/jira-mirror12/HIMMEL"; mkdir -p "$M12"
M_SAVE="$M"; M="$M12"
mk HIMMEL-420 "In Progress" Low '["must-v1.1.3"]' '[]' '[]' "only a worker-less pool ticket" "Edit scripts/lib/t1.sh only."
M="$M_SAVE"
x12="$(NEXT_DISPATCH_MIRROR="$M12" NEXT_DISPATCH_GH_CMD="$WORK/gh" NEXT_DISPATCH_CLASSIFY_CMD="$WORK/classify2" bash "$SUT" --priority-pool-only --owners "HIMMEL-999" 2>/dev/null)"
has "pool-only: a worker-less pool ticket alone is a RESUME row" "$x12" "RESUME	HIMMEL-420"
lacks "pool-only: a pool with only a RESUME row is not POOL-EMPTY" "$x12" "POOL-EMPTY"
n12="$(NEXT_DISPATCH_MIRROR="$M12" NEXT_DISPATCH_GH_CMD="$WORK/gh" NEXT_DISPATCH_CLASSIFY_CMD="$WORK/classify2" bash "$SUT" --priority-pool-only 2>"$WORK/n12.err")"
lacks "pool-only: no worker source (no --owners, no --workers-from) offers no RESUME row" "$n12" "RESUME"
has "pool-only: no worker source says why on stderr" "$(cat "$WORK/n12.err")" "no worker source"
# a doc whose only priority: line sits under a later heading names no tier-1 key
printf '# chief\n\n## Live state\n\nnothing here\n\n## Later\n\npriority: 408\n' > "$D11"
l11="$(run11 --doc "$D11" --workers-from "$WORK/fleet11.json" --priority-pool-only | rows11)"
lacks "a priority: line only under a later heading keys nothing" "$l11" "HIMMEL-408"
# a cloud session in cloud-sessions.tsv next to the doc owns its ticket
mkdir -p "$WORK/cl11"; printf '# chief\n\n## Live state\n\npriority: 401 402\n' > "$WORK/cl11/doc.md"
printf '%s\tHIMMEL-401\tsess\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$WORK/cl11/cloud-sessions.tsv"
c11="$(run11 --doc "$WORK/cl11/doc.md" --workers-from "$WORK/fleet11.json" --priority-pool-only | rows11)"
lacks "pool-only: a cloud-owned In Progress ticket is not offered" "$c11" "HIMMEL-401"
printf '%s\tHIMMEL-401\tsess\n' "2020-01-01T00:00:00Z" > "$WORK/cl11/cloud-sessions.tsv"
c11b="$(run11 --doc "$WORK/cl11/doc.md" --workers-from "$WORK/fleet11.json" --priority-pool-only | rows11)"
has "pool-only: a cloud session past the liveness window owns nothing" "$c11b" "RESUME:HIMMEL-401"
# dropped-platform and residual-depth rules apply to RESUME rows as they do to To Do rows
M13="$WORK/jira-mirror13/HIMMEL"; mkdir -p "$M13"
M_SAVE="$M"; M="$M13"
mk HIMMEL-421 "In Progress" Low '["must-v1.1.3"]' '[]' '[]' "port the hook to powershell" "Edit scripts/lib/u1.sh only."
mk HIMMEL-422 "In Progress" Low '["must-v1.1.3","residual-depth-1"]' '[]' '[]' "a residual one" "Edit scripts/lib/u2.sh only."
mk HIMMEL-423 "In Progress" Low '["must-v1.1.3"]' '[]' '[]' "an ordinary pool ticket" "Edit scripts/lib/u3.sh only."
M="$M_SAVE"
f13="$(NEXT_DISPATCH_MIRROR="$M13" NEXT_DISPATCH_GH_CMD="$WORK/gh" NEXT_DISPATCH_CLASSIFY_CMD="$WORK/classify2" bash "$SUT" --priority-pool-only --owners "HIMMEL-999" 2>/dev/null)"
lacks "pool-only: a dropped-platform In Progress ticket is not a RESUME row" "$f13" "HIMMEL-421"
lacks "pool-only: a residual-depth In Progress ticket is not a RESUME row" "$f13" "HIMMEL-422"
has "pool-only: an ordinary worker-less pool ticket is still a RESUME row" "$f13" "RESUME	HIMMEL-423"

# --- pool depth: --top is the free-slot count; a pool short of it says LOW, and
# an empty pool names the next-tier candidates (tier 5, rank order unchanged)
# on NEXT-TIER rows a dispatcher reading ticket rows never picks up.
has "a pool shorter than the free slots prints pool=<n>/<slots>,LOW" "$(run7 --doc "$CDOC" --priority-pool-only --top 8)" "pool=7/8,LOW"
p10="$(run7 --doc "$CDOC" --priority-pool-only --top 4)"
has "a pool that fills the slots prints pool=<n>/<slots>" "$p10" "pool=4/4"
lacks "a pool that fills the slots is not LOW" "$p10" "LOW"
e10="$(NEXT_DISPATCH_MIRROR="$M8" NEXT_DISPATCH_GH_CMD="$WORK/gh" NEXT_DISPATCH_CLASSIFY_CMD="$WORK/classify2" bash "$SUT" --priority-pool-only --top 8 2>/dev/null)"
has "an empty pool prints pool=0/<slots>,LOW" "$e10" "pool=0/8,LOW"
has "an empty pool lists the next-tier candidate on a NEXT-TIER row" "$e10" "NEXT-TIER	HIMMEL-160"

# --- (8134) every unblocked To Do ticket of the earliest unreleased version is in the pool,
# with an empty priority line and no labels; later-version and versionless ones are not ---
M30="$WORK/jira-mirror30/HIMMEL"; mkdir -p "$M30"
M_SAVE="$M"; M="$M30"
mk HIMMEL-801 "To Do" Low '[]' '["v1.0.1"]' '[]' "unlabelled current version" "Edit scripts/lib/cv1.sh only."
mk HIMMEL-802 "To Do" Highest '[]' '["v1.0.2"]' '[]' "later version" "Edit scripts/lib/cv2.sh only."
mk HIMMEL-803 "To Do" Low '["ps3-blocker"]' '["v1.0.1"]' '[]' "labelled current version" "Edit scripts/lib/cv3.sh only."
mk HIMMEL-804 "To Do" Medium '[]' '[]' '[]' "versionless" "Edit scripts/lib/cv4.sh only."
mk HIMMEL-805 "To Do" Low '[]' '["v1.0.1"]' '["blocked by HIMMEL-806"]' "current version, blocked by an open ticket" "Edit scripts/lib/cv5.sh only."
mk HIMMEL-806 "In Progress" Low '[]' '["v1.0.1"]' '[]' "the open blocker" "Edit scripts/lib/cv6.sh only."
M="$M_SAVE"
printf 'v1.0.1\tfalse\t\nv1.0.2\tfalse\t\n' > "$WORK/jira-mirror30/HIMMEL.versions.tsv"
printf '# chief\n\n## Live state\n\npriority: \n' > "$WORK/chief-doc30.md"
run30() { NEXT_DISPATCH_MIRROR="$M30" NEXT_DISPATCH_GH_CMD="$WORK/gh" NEXT_DISPATCH_CLASSIFY_CMD="$WORK/classify2" bash "$SUT" "$@" 2>/dev/null; }
o30="$(run30 --doc "$WORK/chief-doc30.md" --priority-pool-only --top 7 --dispositions)"
r30="$(printf '%s\n' "$o30" | grep -v '^#' | grep -v '^POOL-EMPTY' | cut -f1,2 | tr '\t' ':' | paste -sd, -)"
[ "$r30" = "LOCAL:HIMMEL-803,LOCAL:HIMMEL-801" ] && pass "(8134) an unlabelled current-version To Do ticket is a pool row after the labelled one, with an empty priority line" || fail "(8134) pool is '$r30'"
lacks "(8134) the current-version ticket is not dropped as outside the priority pool" "$(printf '%s\n' "$o30" | grep '^# disposition HIMMEL-801 ')" "outside the priority pool"
lacks "(8134) a later-version ticket is not offered while the current version has work" "$r30" "HIMMEL-802"
lacks "(8134) a versionless ticket is not offered while the current version has work" "$r30" "HIMMEL-804"
lacks "(8134) a current-version ticket blocked by an open ticket is not offered" "$r30" "HIMMEL-805"
has "(8134) the pool count reads the current-version row" "$o30" "pool=2/7,LOW"

# --- residual-depth: depth >= 1 needs a `residual-must <KEY>` ruling in --doc ---
M10="$WORK/jira-mirror10/HIMMEL"; mkdir -p "$M10"
M_SAVE="$M"; M="$M10"
mk HIMMEL-300 "To Do" Medium '[]' '["v1.0.1"]' '[]' "operator work" "Edit scripts/lib/rd0.sh only."
mk HIMMEL-301 "To Do" Medium '["residual-depth-0"]' '["v1.0.1"]' '[]' "explicit depth 0" "Edit scripts/lib/rd0b.sh only."
mk HIMMEL-302 "To Do" Medium '["residual-depth-1"]' '["v1.0.1"]' '[]' "depth one residual" "Edit scripts/lib/rd1.sh only."
mk HIMMEL-303 "To Do" Medium '["residual-depth-2"]' '["v1.0.1"]' '[]' "depth two residual" "Edit scripts/lib/rd2.sh only."
M="$M_SAVE"
RDOC="$WORK/chief-rd.md"
printf '# chief\n\n## Live state\n\n- residual-must HIMMEL-302 (security)\n' > "$RDOC"
RDOC_NONE="$WORK/chief-rd-none.md"
printf '# chief\n\n## Live state\n\n- priority: 300\n' > "$RDOC_NONE"
rdrun() { NEXT_DISPATCH_MIRROR="$M10" NEXT_DISPATCH_GH_CMD="$WORK/gh" NEXT_DISPATCH_CLASSIFY_CMD="$WORK/classify" bash "$SUT" "$@" 2>/dev/null; }
r1="$(rdrun --doc "$RDOC_NONE")"
has "residual-depth: a ticket with no depth label is listed" "$r1" "HIMMEL-300"
has "residual-depth: depth 0 is listed" "$r1" "HIMMEL-301"
lacks "residual-depth: depth 1 without a residual-must ruling is excluded" "$r1" "HIMMEL-302"
lacks "residual-depth: depth 2 without a ruling is excluded" "$r1" "HIMMEL-303"
r2="$(rdrun --doc "$RDOC")"
has "residual-depth: depth 1 with a residual-must ruling is listed" "$r2" "HIMMEL-302"
lacks "residual-depth: a residual-must for depth 1 does not release depth 2" "$r2" "HIMMEL-303"
r3="$(rdrun)"
lacks "residual-depth: with no --doc, depth 1 is excluded" "$r3" "HIMMEL-302"
printf '# chief\n\n- residual-must HIMMEL-303 (data loss)\n' > "$RDOC"
r4="$(rdrun --doc "$RDOC")"
has "residual-depth: a residual-must ruling releases a depth-2 ticket too" "$r4" "HIMMEL-303"
printf '# chief\n\n## Results\n\n- 07:12 residual-must HIMMEL-302 (security)\n' > "$RDOC"
r5="$(rdrun --doc "$RDOC")"
has "residual-depth: an append-results timestamped residual-must bullet admits its ticket" "$r5" "HIMMEL-302"
lacks "residual-depth: a timestamped residual-must bullet does not release another ticket" "$r5" "HIMMEL-303"

# --- classify only up to --top: a batch never classifies more keys than the slots left ---
M14="$WORK/jira-mirror14/HIMMEL"; mkdir -p "$M14"
M_SAVE="$M"; M="$M14"
for n in 1 2 3 4 5 6; do mk "HIMMEL-40$n" "To Do" Medium '[]' '["v1.0.1"]' '[]' "pool work $n" "Edit scripts/lib/cls$n.sh only."; done
M="$M_SAVE"
DOC14="$WORK/console14.md"
printf '# chief\n\n## Live state\n\n- priority: 401 402 403 404 405 406\n' > "$DOC14"
cat > "$WORK/classify14" <<'EOF'
#!/usr/bin/env bash
printf 'S\n' >> "$CLASSIFY_LOG"
for _ in $(seq 100); do [ "$(grep -c '^S$' "$CLASSIFY_LOG")" -ge 2 ] && break; sleep 0.1; done
for k in "$@"; do
    printf 'K\n' >> "$CLASSIFY_LOG"
    if [ "$k" = HIMMEL-401 ] && [ -f "$REFUSE_401" ]; then printf '%s\tBLOCKED\tstub\n' "$k"; else printf '%s\tLOCAL-NATIVE\tstub\n' "$k"; fi
done
printf 'E\n' >> "$CLASSIFY_LOG"
EOF
chmod +x "$WORK/classify14"
export CLASSIFY_LOG="$WORK/classify14.log" REFUSE_401="$WORK/refuse401"; : > "$CLASSIFY_LOG"
run14() { NEXT_DISPATCH_MIRROR="$M14" NEXT_DISPATCH_GH_CMD="$WORK/gh" NEXT_DISPATCH_CLASSIFY_CMD="$WORK/classify14" bash "$SUT" --doc "$DOC14" --priority-pool-only --owners "HIMMEL-999" --top 2 2>/dev/null | cut -f2 | grep '^HIMMEL' | tr '\n' ' '; }
o14="$(run14)"
keys14="$(grep -c '^K$' "$CLASSIFY_LOG")"; calls14="$(grep -c '^S$' "$CLASSIFY_LOG")"
# in-flight peak: S raises, E lowers
peak14="$(awk '/^S$/{c++; if(c>m)m=c} /^E$/{c--} END{print m+0}' "$CLASSIFY_LOG")"
[ "$keys14" -ge 2 ] && [ "$keys14" -le 4 ] && pass "classify sees 2..2*--top keys ($keys14)" || fail "classify saw $keys14 keys for --top 2"
[ "$calls14" -eq 2 ] && [ "$peak14" -eq 2 ] && pass "classify makes at most 2 calls, at most 2 in flight (calls=$calls14 peak=$peak14)" || fail "classify calls=$calls14 peak=$peak14"
[ "$o14" = "HIMMEL-401 HIMMEL-402 " ] && pass "parallel classify keeps rank order" || fail "rank order wrong: $o14"
: > "$REFUSE_401"; : > "$CLASSIFY_LOG"
o14="$(run14)"
[ "$o14" = "HIMMEL-402 HIMMEL-403 " ] && pass "a refused row is skipped and rank order holds" || fail "refusal order wrong: $o14"

# --- fix 1: a WRAPPED worker holds nothing; only the worker's own write scope holds files ---
M20="$WORK/jira-mirror20/HIMMEL"; mkdir -p "$M20"
M_SAVE="$M"; M="$M20"
mk HIMMEL-701 "To Do" Medium '[]' '["v1.0.1"]' '[]' "named by a wrapped worker" "Edit scripts/lib/wrapped-held.sh only."
mk HIMMEL-702 "To Do" Medium '[]' '["v1.0.1"]' '[]' "named only in boilerplate" "Edit scripts/lib/readonly-boiler.sh only."
mk HIMMEL-703 "To Do" Medium '[]' '["v1.0.1"]' '[]' "inside a live write scope" "Edit scripts/lib/own-scope.sh only."
mk HIMMEL-704 "To Do" Medium '[]' '["v1.0.1"]' '[]' "named after Other live workers" "Edit scripts/lib/other-workers.sh only."
mk HIMMEL-705 "To Do" Medium '[]' '["v1.0.1"]' '[]' "under a dir a worker describes in prose" "Edit scripts/lib/prose-dir/other.sh only."
M="$M_SAVE"
cp "$WORK/jira-mirror/HIMMEL.versions.tsv" "$WORK/jira-mirror20/HIMMEL.versions.tsv"
LEGW="$WORK/HIMMEL-98-N8-wrapped.md"
LEGB="$WORK/HIMMEL-97-N9-live.md"
# shellcheck disable=SC2016  # the backticks are literal doc text
printf '# wrapped\n> **Scope / do not:** writes confined to `scripts/lib/wrapped-held.sh`.\n\n## Results\n- 10:00 LIVE - go\n- 11:00 READY 1 abc GREEN\n- 12:00 WRAPPED - merged\n' > "$LEGW"
# shellcheck disable=SC2016
printf '# live\n> **Scope / do not:** writes confined to `scripts/lib/own-scope.sh` and its test. completes-ticket: yes. Other live legs: `scripts/lib/other-workers.sh`. No settings; READ ONLY `scripts/lib/readonly-boiler.sh`.\n\n## Results\n- 10:00 LIVE - go\n- 12:30 SUCCESSION accepted: x\n' > "$LEGB"
LEGP="$WORK/HIMMEL-96-N7-prose.md"
# shellcheck disable=SC2016
printf '# prose\n> **Scope / do not:** writes confined to `scripts/lib/prose-dir/ (the new command + tests)`.\n\n## Results\n- 10:00 LIVE - go\n' > "$LEGP"
printf '{"schema":1,"legs":[{"doc":"%s","label":"N8"},{"doc":"%s","label":"N9"},{"doc":"%s","label":"N7"}]}\n' "$LEGW" "$LEGB" "$LEGP" > "$WORK/fleet20.json"
run20() { NEXT_DISPATCH_MIRROR="$M20" NEXT_DISPATCH_GH_CMD="$WORK/gh" NEXT_DISPATCH_CLASSIFY_CMD="$WORK/classify" bash "$SUT" --no-classify --workers-from "$WORK/fleet20.json" 2>/dev/null; }
f1="$(run20)"
has "fix1: a ticket on a WRAPPED worker's file is listed" "$f1" "HIMMEL-701	"
has "fix1: a ticket on a file named only in READ ONLY prose is listed" "$f1" "HIMMEL-702	"
lacks "fix1: a ticket on a live worker's write scope is held" "$f1" "HIMMEL-703	"
has "fix1: a ticket on a file after Other live workers is listed" "$f1" "HIMMEL-704	"
lacks "fix1: a directory scope with prose in parentheses still holds the directory" "$f1" "HIMMEL-705	"
# shellcheck disable=SC2016
printf '# parked\n> **Scope / do not:** writes confined to `scripts/lib/wrapped-held.sh`.\n\n## Results\n- 10:00 LIVE - go\n- 12:00 WRAPPED - merged\n- 13:00 PARKED-USAGE - relaunched, waiting for RESUME\n' > "$LEGW"
lacks "a PARKED-USAGE tail after an old WRAPPED still holds the worker's files" "$(run20)" "HIMMEL-701	"

# --- fix 2: a ticket a live worker or an open PR already owns is not offered ---
M21="$WORK/jira-mirror21/HIMMEL"; mkdir -p "$M21"
M_SAVE="$M"; M="$M21"
mk HIMMEL-97 "To Do" Medium '[]' '["v1.0.1"]' '[]' "owned by the live worker" "Edit scripts/lib/fresh-a.sh only."
mk HIMMEL-52 "To Do" Medium '[]' '["v1.0.1"]' '[]' "owned by an open PR" "Edit scripts/lib/fresh-b.sh only."
mk HIMMEL-710 "To Do" Medium '[]' '["v1.0.1"]' '[]' "unowned" "Edit scripts/lib/fresh-c.sh only."
M="$M_SAVE"
cp "$WORK/jira-mirror/HIMMEL.versions.tsv" "$WORK/jira-mirror21/HIMMEL.versions.tsv"
f2="$(NEXT_DISPATCH_MIRROR="$M21" NEXT_DISPATCH_GH_CMD="$WORK/gh" bash "$SUT" --no-classify --workers-from "$WORK/fleet20.json" 2>/dev/null)"
lacks "fix2: a ticket whose key is a live worker's is not offered" "$f2" "HIMMEL-97	"
lacks "fix2: a ticket whose key is in an open PR title is not offered" "$f2" "HIMMEL-52	"
has "fix2: an unowned ticket is offered" "$f2" "HIMMEL-710	"

# --- fix 3: tiers 2-3 only for the earliest unreleased version; operator-gated and Parked: are out ---
M22="$WORK/jira-mirror22/HIMMEL"; mkdir -p "$M22"
M_SAVE="$M"; M="$M22"
mk HIMMEL-720 "To Do" Medium '["operator-directed"]' '["v1.0.1"]' '[]' "directed in the earliest version" "Edit scripts/lib/t3a.sh only."
mk HIMMEL-721 "To Do" Medium '["operator-directed"]' '["v1.0.2"]' '[]' "directed in a later version" "Edit scripts/lib/t3b.sh only."
mk HIMMEL-722 "To Do" Medium '["operator-directed"]' '[]' '[]' "directed with no version" "Edit scripts/lib/t3c.sh only."
mk HIMMEL-723 "To Do" High '["security"]' '["v1.0.2"]' '[]' "security in a later version" "Edit scripts/lib/t3d.sh only."
mk HIMMEL-724 "To Do" Medium '["operator-gated"]' '["v1.0.1"]' '[]' "gated on the operator" "Edit scripts/lib/t3e.sh only."
mk HIMMEL-725 "To Do" Medium '[]' '["v1.0.1"]' '[]' "Parked: revisit later" "Edit scripts/lib/t3f.sh only."
mk HIMMEL-726 "To Do" Medium '[]' '["v1.0.1"]' '[]' "plain earliest-version work" "Edit scripts/lib/t3g.sh only."
M="$M_SAVE"
cp "$WORK/jira-mirror/HIMMEL.versions.tsv" "$WORK/jira-mirror22/HIMMEL.versions.tsv"
run22() { NEXT_DISPATCH_MIRROR="$M22" NEXT_DISPATCH_GH_CMD="$WORK/gh" bash "$SUT" --no-classify "$@" 2>/dev/null; }
f3="$(run22 --priority-pool-only --owners HIMMEL-999)"
has "fix3: operator-directed in the earliest unreleased version is in the pool" "$f3" "HIMMEL-720	"
lacks "fix3: operator-directed in a later version is not in the pool" "$f3" "HIMMEL-721	"
lacks "fix3: operator-directed with no version is not in the pool" "$f3" "HIMMEL-722	"
lacks "fix3: a later-version security ticket is not in the pool" "$f3" "HIMMEL-723	"
f3b="$(run22)"
has "fix3: a later-version operator-directed ticket still lists as backlog" "$f3b" "HIMMEL-721	"
lacks "fix3: operator-gated is excluded" "$f3b" "HIMMEL-724	"
lacks "fix3: a Parked: title is excluded" "$f3b" "HIMMEL-725	"
has "fix3: plain earliest-version work is listed" "$f3b" "HIMMEL-726	"

# --- fix 5: a named file that is not in the repo is warned about ---
M23="$WORK/jira-mirror23/HIMMEL"; mkdir -p "$M23"
M_SAVE="$M"; M="$M23"
mk HIMMEL-730 "To Do" Medium '[]' '["v1.0.1"]' '[]' "names a ghost file" "Edit scripts/handover/tick-ghost-6478.sh only."
mk HIMMEL-731 "To Do" Medium '[]' '["v1.0.1"]' '[]' "names a real file" "Edit scripts/handover/chief-kit/next-dispatchable.sh only."
M="$M_SAVE"
cp "$WORK/jira-mirror/HIMMEL.versions.tsv" "$WORK/jira-mirror23/HIMMEL.versions.tsv"
f5="$(NEXT_DISPATCH_MIRROR="$M23" NEXT_DISPATCH_GH_CMD="$WORK/gh" bash "$SUT" --no-classify 2>/dev/null)"
has "fix5: a ticket naming a missing file draws a warn line" "$f5" "# warn: HIMMEL-730 names scripts/handover/tick-ghost-6478.sh"
lacks "fix5: a ticket naming an existing file draws none" "$f5" "# warn: HIMMEL-731"

# --- the whole active version: Stories, RM-admitted residuals, a directory on the candidate side, a reason per drop ---
M30="$WORK/jira-mirror30/HIMMEL"; mkdir -p "$M30"
M_SAVE="$M"; M="$M30"
mk HIMMEL-801 "To Do" Medium '[]' '["v1.0.1"]' '[]' "a story with no blocker" "Edit scripts/lib/story.sh only."
retype "$M30/HIMMEL-801.md" Story
mk HIMMEL-802 "To Do" Medium '["residual-depth-1"]' '["v1.0.1"]' '[]' "residual the RM kept" "Edit scripts/lib/kept.sh only."
mk HIMMEL-803 "To Do" Medium '["residual-depth-1"]' '["v1.0.1"]' '[]' "residual the RM deferred" "Edit scripts/lib/deferred.sh only."
mk HIMMEL-808 "To Do" Medium '["residual-depth-1"]' '["v1.0.1"]' '[]' "residual with an unknown ledger kind" "Edit scripts/lib/typo.sh only."
mk HIMMEL-809 "To Do" Medium '["residual-depth-1"]' '["v1.0.1"]' '[]' "residual with a plain admission row" "Edit scripts/lib/plain.sh only."
mk HIMMEL-810 "To Do" Medium '[]' '["v1.0.1"]' '[]' "names a new extensionless file a worker holds" "Add scripts/lib/Brewfile only."
mk HIMMEL-804 "To Do" Medium '[]' '["v1.0.1"]' '[]' "mentions trees a worker and a PR write in" "Read scripts/handover/chief-kit/ and scripts/lib/ for context; edit scripts/lib/new-thing.sh."
mk HIMMEL-805 "To Do" Medium '[]' '["v1.0.1"]' '[]' "first of two naming a tree" "See docs/guide/ then edit scripts/lib/d1.sh."
mk HIMMEL-806 "To Do" Medium '[]' '["v1.0.1"]' '[]' "second of two naming a tree" "See docs/guide/ then edit scripts/lib/d2.sh."
mk HIMMEL-807 "To Do" Medium '[]' '["v1.0.1"]' '[]' "an epic" "Edit scripts/lib/epic.sh."
retype "$M30/HIMMEL-807.md" Epic
mk HIMMEL-3 "To Do" High '[]' '["v1.0.1"]' '[]' "collides with an open PR" "Edit scripts/lib/pr-held.sh please."
mk HIMMEL-4 "To Do" High '[]' '["v1.0.1"]' '[]' "collides with a live worker" "Edit scripts/handover/chief-kit/live-file.sh please."
mk HIMMEL-5 "To Do" High '["operator-decision"]' '["v1.0.1"]' '[]' "decision pending" "Edit scripts/lib/gamma.sh."
mk HIMMEL-8 "To Do" High '[]' '["v1.0.1"]' '["blocked by HIMMEL-801"]' "blocked by an open ticket" "Edit scripts/lib/zeta.sh."
mk HIMMEL-10 "To Do" High '[]' '["v1.0.1"]' '[]' "refused by the classifier" "Edit scripts/lib/eta.sh."
mk HIMMEL-52 "To Do" Medium '[]' '["v1.0.1"]' '[]' "owned by an open PR" "Edit scripts/lib/fresh-b.sh only."
mk HIMMEL-99 "To Do" Medium '[]' '["v1.0.1"]' '[]' "owned by the live worker" "Edit scripts/lib/fresh-a.sh only."
M="$M_SAVE"
cp "$WORK/jira-mirror/HIMMEL.versions.tsv" "$WORK/jira-mirror30/HIMMEL.versions.tsv"
printf '{"ts":"t","version":"v1.0.1","key":"HIMMEL-802","kind":"rm-admit","actor":"rm","by":"rm-session"}\n{"ts":"t","version":"v1.0.1","key":"HIMMEL-803","kind":"rm-admit","actor":"rm"}\n{"ts":"t2","version":"v1.0.1","key":"HIMMEL-803","kind":"deferral","actor":"rm"}\n{"ts":"t","version":"v1.0.2","key":"HIMMEL-804","kind":"rm-admit","actor":"rm"}\n{"ts":"t","version":"v1.0.1","key":"HIMMEL-808","kind":"rm-admitt","actor":"rm"}\n{"ts":"t","version":"v1.0.1","key":"HIMMEL-809","gate":"intake","actor":"rm"}\n' > "$WORK/ledger30.jsonl"
run30() { HIMMEL_ADMISSIONS_LEDGER="$WORK/ledger30.jsonl" NEXT_DISPATCH_MIRROR="$M30" NEXT_DISPATCH_GH_CMD="$WORK/gh" NEXT_DISPATCH_CLASSIFY_CMD="$WORK/classify" bash "$SUT" --top 20 --workers-from "$WORK/fleet.json" "$@" 2>/dev/null; }
v1="$(run30)"
has "version: a Story with no blocker is offered" "$v1" "HIMMEL-801	"
has "version: a residual the RM admitted (ledger row) is offered without residual-must" "$v1" "HIMMEL-802	"
lacks "version: a residual whose latest ledger row is a deferral is not offered" "$v1" "HIMMEL-803	"
lacks "version: a residual whose ledger row has an unknown kind is not offered" "$v1" "HIMMEL-808	"
lacks "version: a residual with a kindless intake row is not offered (only an rm-admit or override row admits)" "$v1" "HIMMEL-809	"
has "collision: a directory named on the candidate side collides with nothing" "$v1" "HIMMEL-804	"
has "collision: two candidates naming the same directory are both offered" "$v1" "HIMMEL-805	"
has "collision: and the second is offered too" "$v1" "HIMMEL-806	"
lacks "collision: a concrete file in a live worker's write scope is still held" "$v1" "HIMMEL-4	"
lacks "collision: a concrete file equal to an open PR's file is still held" "$v1" "HIMMEL-3	"
has "drops: a per-reason summary of the active version is printed" "$v1" "# dropped from v1.0.1:"
w1="$(run30 --why)"
has "why: a collision names the file and its holder" "$w1" "# drop HIMMEL-3 collision scripts/lib/pr-held.sh held by open PR 4242"
has "why: a worker collision names the worker" "$w1" "# drop HIMMEL-4 collision scripts/handover/chief-kit/live-file.sh held by live worker N1"
has "why: an open blocker is named" "$w1" "# drop HIMMEL-8 blocker HIMMEL-801"
has "why: an exclusion label is named" "$w1" "# drop HIMMEL-5 label operator-decision"
has "why: a type is named" "$w1" "# drop HIMMEL-807 type Epic"
has "why: a residual depth is named" "$w1" "# drop HIMMEL-803 residual-depth 1"
has "why: a classification refusal is named" "$w1" "# drop HIMMEL-10 classification BLOCKED"
has "why: an open-PR owner is named" "$w1" "# drop HIMMEL-52 owned by open PR"
has "why: a live-worker owner is named" "$w1" "# drop HIMMEL-99 owned by live worker"
lacks "why: without --why no per-ticket line is printed" "$v1" "# drop HIMMEL-"
printf 'scripts/lib/Brewfile\n' > "$WORK/held30.txt"
lacks "collision: a new extensionless file equal to a held path is held" "$(run30 --held "$WORK/held30.txt")" "HIMMEL-810	"

# an override row admits a residual too
printf '{"ts":"t","version":"v1.0.1","key":"HIMMEL-811","kind":"override","actor":"operator"}\n' >> "$WORK/ledger30.jsonl"
M_SAVE="$M"; M="$M30"; mk HIMMEL-811 "To Do" Medium '["residual-depth-1"]' '["v1.0.1"]' '[]' "residual the operator overrode" "Edit scripts/lib/override.sh only."; M="$M_SAVE"
has "version: a residual with an override row is offered" "$(run30)" "HIMMEL-811	"

# HANDOVER_DIR only in .env (the cache-dir .env load_dotenv reads first): the ledger under it is read
HD7064="$WORK/hd7064"; CD7064="$WORK/cache7064"; mkdir -p "$HD7064" "$CD7064" "$WORK/home7064"
printf 'HANDOVER_DIR=%s\n' "$HD7064" > "$CD7064/.env"
printf '{"ts":"t","version":"v1.0.1","key":"HIMMEL-802","kind":"rm-admit","actor":"rm"}\n' > "$HD7064/admissions-ledger.jsonl"
denv="$(env -u HANDOVER_DIR -u HIMMEL_ADMISSIONS_LEDGER HOME="$WORK/home7064" HIMMELCTL_CACHE_DIR="$CD7064" NEXT_DISPATCH_MIRROR="$M30" NEXT_DISPATCH_GH_CMD="$WORK/gh" NEXT_DISPATCH_CLASSIFY_CMD="$WORK/classify" bash "$SUT" --top 20 --workers-from "$WORK/fleet.json" 2>/dev/null)"
has "env: a ledger under a HANDOVER_DIR set only in .env admits its residual" "$denv" "HIMMEL-802	"

# a wrapped To Do Story with a resume brief is a RESUME row; an Epic still is not
WS="$WORK/ts-story/workers"; mkdir -p "$WS"
MS="$WORK/mstory/HIMMEL"; mkdir -p "$MS"
M_SAVE="$M"; M="$MS"
mk HIMMEL-66 "To Do" Medium '[]' '[]' '[]' "wrapped story with a brief" "Edit scripts/lib/w6.sh."
retype "$MS/HIMMEL-66.md" Story
mk HIMMEL-67 "To Do" Medium '[]' '[]' '[]' "wrapped epic with a brief" "Edit scripts/lib/w7.sh."
retype "$MS/HIMMEL-67.md" Epic
M="$M_SAVE"
printf '{"key":"HIMMEL-66","state":"wrapped","resume_brief":"/x/HIMMEL-66-RESUME.md"}\n' > "$WS/HIMMEL-66.json"
printf '{"key":"HIMMEL-67","state":"wrapped","resume_brief":"/x/HIMMEL-67-RESUME.md"}\n' > "$WS/HIMMEL-67.json"
rs7="$(NEXT_DISPATCH_MIRROR="$MS" NEXT_DISPATCH_GH_CMD="$WORK/gh" NEXT_DISPATCH_CLASSIFY_CMD="$WORK/classify2" bash "$SUT" --workers-dir "$WS" --workers-from "$WORK/fleet5.json" 2>/dev/null)"
has "story: a wrapped To Do Story with a resume brief is a RESUME row" "$rs7" "RESUME	HIMMEL-66"
lacks "story: a wrapped Epic is still never a RESUME row" "$rs7" "HIMMEL-67	"

# --- replay: the 10-19T chief state (doc priority line, 28-worker manifest, open PRs, v1.1.3 Jira slice) frozen under fixtures/ ---
RP="$HERE/fixtures/dispatcher-replay"
# Corpus inputs must not contain the evaluation queries verbatim.
eval_corpus_clean() {
    local root="$HERE/../../.." rc
    jq -er '.q' "$root/scripts/eval/retrieval-eval/questions.jsonl" > "$WORK/eval-questions.txt" || return 2
    grep -i -n -F -f "$WORK/eval-questions.txt" \
        "$root/scripts/himmel-doctor.sh" "$RP/mirror/HIMMEL/HIMMEL-6140.md"
    rc=$?
    [ "$rc" -eq 1 ]
}
if eval_corpus_clean; then
    pass "replay: corpus inputs do not contain retrieval-eval question text"
else
    fail "replay: corpus inputs contain retrieval-eval question text or could not be checked"
fi
sed "s#@@FIXTURE@@#$RP#" "$RP/fleet.json" > "$WORK/replay-fleet.json"
cat > "$WORK/replay-gh" <<EOF
#!/usr/bin/env bash
if [ "\$2" = list ]; then
    case "\$*" in *headRefName*) cat "$RP/prs.tsv" ;; *) cut -f1 "$RP/prs.tsv" ;; esac
else awk -F'\t' -v n="\$3" '\$1 == n {print \$2}' "$RP/pr-files.tsv"; fi
EOF
chmod +x "$WORK/replay-gh"
# the frozen tickets predate the proof gate: give each a DoD and Proof tail on a copy, so the replay still tests the fences
cp -r "$RP/mirror" "$WORK/replay-mirror"
for f in "$WORK"/replay-mirror/HIMMEL/*.md; do printf '\n\nDoD\n- the row is green\n\nProof\n- a RED row that fails before the change\n' >> "$f"; done
rp="$(NEXT_DISPATCH_MIRROR="$WORK/replay-mirror/HIMMEL" NEXT_DISPATCH_GH_CMD="$WORK/replay-gh" bash "$SUT" --no-classify --top 80 --doc "$RP/chief.md" --workers-from "$WORK/replay-fleet.json" 2>/dev/null)"
has "replay: a ticket the 'Do not touch' fence of a live worker hid is offered (HIMMEL-6034)" "$rp" "HIMMEL-6034	"
lacks "replay: a directory-wide scope described in parentheses still holds its directory (HIMMEL-6485)" "$rp" "HIMMEL-6485	"
lacks "replay: a ticket whose key is a live worker's is not offered (HIMMEL-4999)" "$rp" "HIMMEL-4999	"
lacks "replay: a ticket really held by a live worker stays held (HIMMEL-6484)" "$rp" "HIMMEL-6484	"
n113="$(printf '%s\n' "$rp" | grep -c "	v1.1.3	")"
[ "$n113" -ge 5 ] && pass "replay: at least 5 v1.1.3 rows ($n113)" || fail "replay: at least 5 v1.1.3 rows (got $n113)"

# --- the real version list: archived unreleased versions (v1.0.3b ...) sort before v1.1.3 but are not the first version ---
M24="$WORK/jira-mirror24/HIMMEL"; mkdir -p "$M24"
M_SAVE="$M"; M="$M24"
mk HIMMEL-740 "To Do" Medium '["operator-directed"]' '["v1.1.3"]' '[]' "directed in the first live version" "Edit scripts/lib/t6a.sh only."
mk HIMMEL-741 "To Do" Medium '["operator-directed"]' '["v1.1.4"]' '[]' "directed in a later live version" "Edit scripts/lib/t6b.sh only."
M="$M_SAVE"
cp "$RP/mirror/HIMMEL.versions.tsv" "$WORK/jira-mirror24/HIMMEL.versions.tsv"
f6="$(NEXT_DISPATCH_MIRROR="$M24" NEXT_DISPATCH_GH_CMD="$WORK/gh" bash "$SUT" --no-classify --priority-pool-only --owners HIMMEL-999 2>/dev/null)"
lacks "archived: the pool is not empty" "$f6" "POOL-EMPTY"
has "archived: the pool holds exactly the operator-directed ticket of the first live version (tier 2)" "$f6" "# pool=1/"
has "archived: the pool row is the v1.1.3 operator-directed ticket" "$f6" "HIMMEL-740	Medium	v1.1.3"
lacks "archived: the first live version's ticket is not parked as NEXT-TIER" "$f6" "NEXT-TIER	HIMMEL-740"
lacks "archived: a later live version's operator-directed ticket is not in the pool" "$f6" "HIMMEL-741	"

# --- a 'Never edit' / 'Do NOT touch' fence and a 'Touches <dir>, a trust-path pattern' note are not write scope ---
M25="$WORK/jira-mirror25/HIMMEL"; mkdir -p "$M25"
M_SAVE="$M"; M="$M25"
mk HIMMEL-750 "To Do" Medium '[]' '["v1.0.1"]' '[]' "inside a Never edit tree" "Edit scripts/ci/nd-never-a.sh only."
mk HIMMEL-751 "To Do" Medium '[]' '["v1.0.1"]' '[]' "inside a Do NOT touch tree" "Edit scripts/hooks/nd-never-b.sh only."
mk HIMMEL-752 "To Do" Medium '[]' '["v1.0.1"]' '[]' "a tree named only in a Touches note" "Edit scripts/ci/nd-touch-c.sh only."
mk HIMMEL-753 "To Do" Medium '[]' '["v1.0.1"]' '[]' "the worker's own file" "Edit scripts/handover/nd-own.sh only."
mk HIMMEL-754 "To Do" Medium '[]' '["v1.0.1"]' '[]' "a file a Touches sentence really writes" "Edit scripts/ci/nd-touch-d.sh only."
M="$M_SAVE"
cp "$WORK/jira-mirror/HIMMEL.versions.tsv" "$WORK/jira-mirror25/HIMMEL.versions.tsv"
LEGN="$WORK/HIMMEL-95-N5-never.md"
LEGT="$WORK/HIMMEL-94-N4-touches.md"
# shellcheck disable=SC2016  # the backticks are literal doc text
printf '# never\n> **Scope / do not:** writes confined to Writes confined to the suite files `scripts/handover/nd-own.sh`. Never edit: .github/workflows/*, scripts/ci/*, scripts/lib/*. Do NOT TOUCH scripts/hooks/*. Fix shape: stat. completes-ticket: yes. Stay off those.\n\n## Results\n- 10:00 LIVE - go\n' > "$LEGN"
printf '# touches\n> **Scope / do not:** writes confined to Writes confined to scripts/handover/nd-own.sh, and two rows each in scripts/ci/suite-tiers.tsv and scripts/ci/suite-durations.tsv. Never edit scripts/hooks/, scripts/lib/, .github/. Impacted suites: scripts/ci/test-suite-tiers.sh. Touches scripts/ci/, a ci-trust-paths pattern: say so in READY (trust-reviewed GO). completes-ticket: no. Stay off those.\n\n## Results\n- 10:00 LIVE - go\n' > "$LEGT"
LEGU="$WORK/HIMMEL-93-N3-touches-real.md"
printf '# touches-real\n> **Scope / do not:** writes confined to scripts/handover/nd-own.sh. Touches scripts/ci/nd-touch-d.sh to update a ci-trust-paths pattern. completes-ticket: no.\n\n## Results\n- 10:00 LIVE - go\n' > "$LEGU"
printf '{"schema":1,"legs":[{"doc":"%s","label":"N5"},{"doc":"%s","label":"N4"},{"doc":"%s","label":"N3"}]}\n' "$LEGN" "$LEGT" "$LEGU" > "$WORK/fleet25.json"
f25="$(NEXT_DISPATCH_MIRROR="$M25" NEXT_DISPATCH_GH_CMD="$WORK/gh" bash "$SUT" --no-classify --workers-from "$WORK/fleet25.json" 2>/dev/null)"
has "never-edit: a ticket inside a 'Never edit' tree is offered (HIMMEL-7358)" "$f25" "HIMMEL-750	"
has "never-edit: a ticket inside a 'Do NOT TOUCH' tree (verb in capitals too) is offered" "$f25" "HIMMEL-751	"
has "never-edit: a ticket inside a tree named only in a 'Touches <dir>, a trust-path pattern' note is offered" "$f25" "HIMMEL-752	"
lacks "never-edit: a ticket on the worker's own named file stays held" "$f25" "HIMMEL-753	"
lacks "never-edit: a file a 'Touches <file> ... pattern' sentence really writes stays held" "$f25" "HIMMEL-754	"

# --- a worker holds only the files it writes, not paths in a quoted grep or boilerplate ---
FX="$HERE/fixtures/held-paths"
M26="$WORK/jira-mirror26/HIMMEL"; mkdir -p "$M26"
M_SAVE="$M"; M="$M26"
mk HIMMEL-860 "To Do" Medium '[]' '["v1.0.1"]' '[]' "n3558 real file" "Edit docs/adoption-trail.html only."
mk HIMMEL-861 "To Do" Medium '[]' '["v1.0.1"]' '[]' "under the scripts/ a grep searched" "Edit scripts/check-ci.sh only."
mk HIMMEL-862 "To Do" Medium '[]' '["v1.0.1"]' '[]' "under the scripts/lib/ trust note" "Edit scripts/lib/nd-trust-free.sh only."
mk HIMMEL-863 "To Do" Medium '[]' '["v1.0.1"]' '[]' "n3543 single-writer file" "Edit scripts/config-ui/nd-other.ts only."
mk HIMMEL-864 "To Do" Medium '[]' '["v1.0.1"]' '[]' "n3557 real command dir" "Edit marketplace/plugins/himmel-ops/commands/nd-report.md only."
mk HIMMEL-865 "To Do" Medium '[]' '["v1.0.1"]' '[]' "n3557 real script dir" "Edit scripts/report/nd-run.sh only."
mk HIMMEL-866 "To Do" Medium '[]' '["v1.0.1"]' '[]' "n3557 impacted-suites file" "Edit scripts/eval/friction/test-friction.sh only."
mk HIMMEL-867 "To Do" Medium '[]' '["v1.0.1"]' '[]' "n3557 gitleaks-gate read" "Edit scripts/lib/nd-redact-free.sh only."
mk HIMMEL-868 "To Do" Medium '[]' '["v1.0.1"]' '[]' "negative control file in a written dir" "Edit scripts/ci/nd-neg-other.sh only."
mk HIMMEL-869 "To Do" Medium '[]' '["v1.0.1"]' '[]' "a path the neg control only greps" "Edit scripts/handover/nd-neg-grepped.sh only."
mk HIMMEL-870 "To Do" Medium '[]' '["v1.0.1"]' '[]' "writes-line file" "Edit docs/nd-writes-line.html only."
mk HIMMEL-871 "To Do" Medium '[]' '["v1.0.1"]' '[]' "a path only the scope line prose names" "Edit scripts/lib/nd-wl-reader.sh only."
mk HIMMEL-872 "To Do" Medium '[]' '["v1.0.1"]' '[]' "under a dir the front-matter description quotes" "Edit scripts/lib/nd-fm-free.sh only."
mk HIMMEL-873 "To Do" Medium '[]' '["v1.0.1"]' '[]' "the front-matter worker's real file" "Edit docs/nd-frontmatter.html only."
mk HIMMEL-875 "To Do" Medium '[]' '["v1.0.1"]' '[]' "the file listed after a command-word name" "Edit docs/nd-find.html only."
mk HIMMEL-876 "To Do" Medium '[]' '["v1.0.1"]' '[]' "a sibling the command-word name must not hold" "Edit scripts/handover/nd-sibling.sh only."
mk HIMMEL-877 "To Do" Medium '[]' '["v1.0.1"]' '[]' "a path after a prose find on a scope line" "Edit scripts/nd-b.sh only."
mk HIMMEL-878 "To Do" Medium '[]' '["v1.0.1"]' '[]' "a path after prose on a Writes line" "Edit scripts/nd-e.sh only."
mk HIMMEL-879 "To Do" Medium '[]' '["v1.0.1"]' '[]' "the file this worker's own SINGLE-WRITER note names" "Edit scripts/nd-d.sh only."
mk HIMMEL-880 "To Do" Medium '[]' '["v1.0.1"]' '[]' "a dir a flagged bare grep reads" "Edit scripts/nd-read/nd-x.sh only."
mk HIMMEL-881 "To Do" Medium '[]' '["v1.0.1"]' '[]' "a path on the continuation of a wrapped Writes block" "Edit scripts/nd-i.sh only."
mk HIMMEL-882 "To Do" Medium '[]' '["v1.0.1"]' '[]' "a path after a path segment named find" "Edit scripts/nd-y.sh only."
mk HIMMEL-883 "To Do" Medium '[]' '["v1.0.1"]' '[]' "under a dir the description names without a command word" "Edit scripts/nd-fm-desc/nd-z.sh only."
mk HIMMEL-884 "To Do" Medium '[]' '["v1.0.1"]' '[]' "under a dir a find -delete writes" "Edit scripts/nd-del/nd-q.sh only."
mk HIMMEL-885 "To Do" Medium '[]' '["v1.0.1"]' '[]' "a file after a flag and the word in" "Edit scripts/nd-p.sh only."
M="$M_SAVE"
cp "$WORK/jira-mirror/HIMMEL.versions.tsv" "$WORK/jira-mirror26/HIMMEL.versions.tsv"
printf '{"schema":1,"legs":[{"doc":"%s","label":"N3558"},{"doc":"%s","label":"N3543"},{"doc":"%s","label":"N3557"},{"doc":"%s","label":"N3578"},{"doc":"%s","label":"N3579"},{"doc":"%s","label":"N3580"},{"doc":"%s","label":"N3581"},{"doc":"%s","label":"N3582"},{"doc":"%s","label":"N3583"},{"doc":"%s","label":"N3584"},{"doc":"%s","label":"N3585"},{"doc":"%s","label":"N3586"}]}\n' \
    "$FX/HIMMEL-7377-N3558-adoption-trail-narrow-panel.md" "$FX/HIMMEL-3111-N3543-config-secrets-journey.md" "$FX/HIMMEL-7131-N3557-himmel-report-command.md" \
    "$FX/HIMMEL-7469-N3578-neg-control.md" "$FX/HIMMEL-7469-N3579-writes-line.md" "$FX/HIMMEL-7469-N3580-frontmatter-description.md" "$FX/HIMMEL-7469-N3581-command-word-in-path.md" \
    "$FX/HIMMEL-7469-N3582-prose-before-path.md" "$FX/HIMMEL-7469-N3583-writes-line-prose.md" "$FX/HIMMEL-7469-N3584-writes-wrapped.md" "$FX/HIMMEL-7469-N3585-no-scope.md" "$FX/HIMMEL-7469-N3586-command-segment.md" > "$WORK/fleet26.json"
f26="$(NEXT_DISPATCH_MIRROR="$M26" NEXT_DISPATCH_GH_CMD="$WORK/gh" bash "$SUT" --no-classify --top 50 --workers-from "$WORK/fleet26.json" 2>"$WORK/f26.err")"
lacks "held-paths: N3558 still holds its one real file docs/adoption-trail.html" "$f26" "HIMMEL-860	"
has "held-paths: N3558's quoted 'grep -rl adoption-trail scripts/' does not hold scripts/check-ci.sh" "$f26" "HIMMEL-861	"
has "held-paths: N3543's 'Trust path (scripts/lib/)' note does not hold scripts/lib/" "$f26" "HIMMEL-862	"
has "held-paths: N3543's SINGLE-WRITER note holds nothing (the open PR holds that file)" "$f26" "HIMMEL-863	"
lacks "held-paths: N3557 still holds its command dir" "$f26" "HIMMEL-864	"
lacks "held-paths: N3557 still holds its script dir" "$f26" "HIMMEL-865	"
has "held-paths: N3557's 'Impacted suites:' file is run, not written" "$f26" "HIMMEL-866	"
has "held-paths: N3557's 'find what the gitleaks gate or scripts/lib uses' read does not hold scripts/lib/" "$f26" "HIMMEL-867	"
lacks "held-paths: negative control: a worker whose write list names scripts/ci/ still holds scripts/ci/" "$f26" "HIMMEL-868	"
has "held-paths: negative control: the path that worker only greps is free" "$f26" "HIMMEL-869	"
lacks "held-paths: a worker with a Writes line holds the files on it" "$f26" "HIMMEL-870	"
has "held-paths: a worker with a Writes line holds nothing the scope line prose names" "$f26" "HIMMEL-871	"
has "held-paths: a front-matter description quoting 'writes confined to' holds nothing" "$f26" "HIMMEL-872	"
lacks "held-paths: that worker still holds the file on its real scope line" "$f26" "HIMMEL-873	"
lacks "held-paths: the file listed after a command-word name is still held" "$f26" "HIMMEL-875	"
has "held-paths: a command-word name does not hold its whole directory" "$f26" "HIMMEL-876	"
lacks "held-paths: a path after 'find and fix the caller in' prose on a scope line is held" "$f26" "HIMMEL-877	"
lacks "held-paths: a Writes line is never cleaned: a path after prose on it is held" "$f26" "HIMMEL-878	"
lacks "held-paths: this worker's own SINGLE-WRITER note holds the file it names" "$f26" "HIMMEL-879	"
has "held-paths: a bare 'grep -rl needle scripts/nd-read/' read holds nothing" "$f26" "HIMMEL-880	"
lacks "held-paths: a path on the continuation line of a wrapped Writes block is held" "$f26" "HIMMEL-881	"
lacks "held-paths: a path after a path segment named find is held" "$f26" "HIMMEL-882	"
has "held-paths: a path the front-matter description names (no command word before it) holds nothing" "$f26" "HIMMEL-883	"
lacks "held-paths: a find -delete is a write, not a read: its dir is held" "$f26" "HIMMEL-884	"
has "held-paths: a live worker that yields no held paths is named on stderr" "$(cat "$WORK/f26.err")" "live worker N3585 yields no held paths"
has "held-paths: a live worker that yields no held paths makes the live workers unknown on the stdout header" "$f26" "live workers unknown"
printf '{"schema":1,"legs":[{"doc":"%s","label":"N3587"}]}\n' "$FX/HIMMEL-7469-N3587-none-named.md" > "$WORK/fleet27.json"
f27="$(NEXT_DISPATCH_MIRROR="$M26" NEXT_DISPATCH_GH_CMD="$WORK/gh" bash "$SUT" --no-classify --top 50 --workers-from "$WORK/fleet27.json" 2>/dev/null)"
lacks "held-paths: an explicit 'Writes: none named' worker is a real empty scope, not unknown" "$f27" "live workers unknown"
lacks "held-paths: a path after 'replace grep -P in' is a write, not a read" "$f26" "HIMMEL-885	"


# --- a disposition per open ticket, live blocker re-check, rename registry, per-PR file reads, narrow write scope ---
DD="$HERE/fixtures/dispatch-disposition"
export DD_DIR="$WORK/dd"; mkdir -p "$DD_DIR"
MD="$WORK/jira-mirror-dd/HIMMEL"; mkdir -p "$MD"
M_SAVE="$M"; M="$MD"
mk HIMMEL-901 "To Do" Medium '[]' '["v1.0.1"]' '[]' "pre-rename path, the new spelling is held" "Edit scripts/handover/console-kit/dd-old.sh only."
mk HIMMEL-902 "To Do" Medium '[]' '["v1.0.1"]' '[]' "stale pre-rename path nobody holds" "Edit scripts/handover/console-kit/dd-stale.sh only."
mk HIMMEL-903 "To Do" Medium '[]' '["v1.0.1"]' '[]' "new path, the old spelling is held" "Edit scripts/handover/chief-kit/dd-newn.sh only."
mk HIMMEL-904 "To Do" Medium '[]' '["v1.0.1"]' '["blocked by HIMMEL-910"]' "blocker is Done live, In Progress in the mirror" "Edit scripts/lib/dd-904.sh only."
mk HIMMEL-905 "To Do" Medium '[]' '["v1.0.1"]' '["blocked by HIMMEL-911"]' "blocker is live" "Edit scripts/lib/dd-905.sh only."
mk HIMMEL-906 "To Do" Medium '[]' '["v1.0.1"]' '[]' "classifier BLOCKED, blocker Done live" "Edit scripts/lib/dd-906.sh only."
mk HIMMEL-907 "To Do" Medium '[]' '["v1.0.1"]' '[]' "classifier BLOCKED, blocker live" "Edit scripts/lib/dd-907.sh only."
mk HIMMEL-910 "In Progress" Medium '["parked"]' '[]' '[]' "blocker, Done live" "Edit scripts/lib/dd-910.sh only."
mk HIMMEL-911 "In Progress" Medium '["parked"]' '[]' '[]' "blocker, live" "Edit scripts/lib/dd-911.sh only."
mk HIMMEL-920 "To Do" Medium '[]' '["v1.0.1"]' '[]' "dir mentioned: .github/workflows" "Edit .github/workflows/dd-a.yml only."
mk HIMMEL-921 "To Do" Medium '[]' '["v1.0.1"]' '[]' "dir mentioned: scripts/ci" "Edit scripts/ci/dd-b.sh only."
mk HIMMEL-922 "To Do" Medium '[]' '["v1.0.1"]' '[]' "dir mentioned: claude-hud" "Edit marketplace/plugins/claude-hud/dd-c.sh only."
mk HIMMEL-923 "To Do" Medium '[]' '["v1.0.1"]' '[]' "dir mentioned: scripts/config-ui" "Edit scripts/config-ui/dd-d.sh only."
mk HIMMEL-924 "To Do" Medium '[]' '["v1.0.1"]' '[]' "inside the writes-confined-to list" "Edit scripts/dd-in/dd-e.sh only."
mk HIMMEL-925 "To Do" Medium '[]' '["v1.0.1"]' '[]' "a file on the writes-confined-to list" "Edit scripts/dd-own.sh only."
mk HIMMEL-930 "To Do" Medium '[]' '["v1.0.1"]' '[]' "file of the PR before the unreadable one" "Edit scripts/lib/dd-pr1.sh only."
mk HIMMEL-931 "To Do" Medium '[]' '["v1.0.1"]' '[]' "file of the PR after the unreadable one" "Edit scripts/lib/dd-pr3.sh only."
mk HIMMEL-932 "To Do" Medium '[]' '["v1.0.1"]' '[]' "the old name of a file a PR renames" "Edit scripts/lib/dd-old-name.sh only."
mk HIMMEL-940 "In Progress" Medium '[]' '["v1.0.1"]' '[]' "orphan in progress" "Edit scripts/lib/dd-940.sh only."
mk HIMMEL-951 "To Do" Medium '["operator-decision"]' '["v1.0.1"]' '[]' "waits on an operator question" "Edit scripts/lib/dd-951.sh only."
mk HIMMEL-960 "To Do" Medium '[]' '["v1.0.1"]' '[]' "names a directory with a held file in it" "Tidy the helpers under scripts/lib/dd-ov/."
mk HIMMEL-961 "To Do" Medium '[]' '["v1.0.1"]' '[]' "a hook ticket naming a directory with a held file in it" "Edit scripts/hooks/dd-hk.sh and tidy scripts/lib/dd-ov2/."
mk HIMMEL-962 "To Do" Medium '[]' '["v1.0.1"]' '[]' "names a directory without its slash" "Tidy the helpers in scripts/lib."
M="$M_SAVE"
cp "$WORK/jira-mirror/HIMMEL.versions.tsv" "$WORK/jira-mirror-dd/HIMMEL.versions.tsv"
cat > "$WORK/gh-dd" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$DD_DIR/gh.args"
if [ "$1" = api ]; then
    for a in "$@"; do case "$a" in */pulls/*/files) p="$a" ;; esac; done
    n="${p#*/pulls/}"; n="${n%/files}"
    if [ -f "$DD_DIR/fail-$n" ]; then echo 'gh: HTTP 406: diff exceeded the maximum number of files (300)' >&2; exit 1; fi
    cat "$DD_DIR/files-$n"; exit 0
fi
if [ "$1 $2" = "pr diff" ]; then  # the old read: a PR over 300 files fails
    if [ -f "$DD_DIR/fail-$3" ]; then echo 'gh: HTTP 406: diff exceeded the maximum number of files (300)' >&2; exit 1; fi
    cat "$DD_DIR/files-$3"; exit 0
fi
if [ "$2" = list ]; then
    case "$*" in *merged*) ;; *headRefName*) cat "$DD_DIR/prs.tsv" ;; *) cut -f1 "$DD_DIR/prs.tsv" ;; esac
fi
EOF
cat > "$WORK/classify-dd" <<'EOF'
#!/usr/bin/env bash
for k in "$@"; do
    case "$k" in
        HIMMEL-906) printf '%s\tBLOCKED\tscripts/lib/dd-906.sh is held (routed HIMMEL-912 in an earlier run)\n' "$k" ;;
        HIMMEL-907) printf '%s\tBLOCKED\tscripts/lib/dd-907.sh is held (routed HIMMEL-913 in an earlier run)\n' "$k" ;;
        HIMMEL-961) printf '%s\tBLOCKED\tscripts/lib/dd-ov2/ contains held scripts/lib/dd-ov2/y.sh (open PR 5001) — one writer per file\n' "$k" ;;
        HIMMEL-960) printf '%s\tBLOCKED\tscripts/lib/dd-ov/ contains held scripts/lib/dd-ov/x.sh (open PR 5001) — one writer per file\n' "$k" ;;
        *) printf '%s\tLOCAL-NATIVE\tstub\n' "$k" ;;
    esac
done
EOF
cat > "$WORK/jira-dd" <<'EOF'
#!/usr/bin/env bash
[ "$1" = get ] || exit 2
st="$(awk -v k="$2" '$1 == k {sub(/^[^ ]+ /, ""); print}' "$DD_DIR/live.txt")"
[ -n "$st" ] || exit 1
printf '%s\tTask\t%s\tlive\n' "$2" "$st"
EOF
chmod +x "$WORK/gh-dd" "$WORK/classify-dd" "$WORK/jira-dd"
printf 'HIMMEL-910 Done\nHIMMEL-911 In Progress\nHIMMEL-912 Done\nHIMMEL-913 In Progress\n' > "$DD_DIR/live.txt"
printf '5001\tfix(x): [HIMMEL-9101] one\tfix/himmel-9101-one\n5002\tfix(x): [HIMMEL-9102] huge\tfix/himmel-9102-huge\n5003\tfix(x): [HIMMEL-9103] three\tfix/himmel-9103-three\n' > "$DD_DIR/prs.tsv"
printf 'scripts/lib/dd-pr1.sh\nscripts/lib/dd-ov/x.sh\nscripts/lib/dd-ov2/y.sh\n' > "$DD_DIR/files-5001"
printf 'scripts/lib/dd-huge.sh\n' > "$DD_DIR/files-5002"
printf 'scripts/lib/dd-pr3.sh\nscripts/lib/dd-new-name.sh\nscripts/lib/dd-old-name.sh\n' > "$DD_DIR/files-5003"
sed "s#@@FIXTURE@@#$DD#" "$DD/fleet.json" > "$WORK/dd-fleet.json"
printf 'scripts/handover/chief-kit/dd-old.sh\nscripts/handover/chief-kit/dd-newn.sh\n' > "$WORK/dd-held.txt"
rundd() { NEXT_DISPATCH_MIRROR="$MD" NEXT_DISPATCH_GH_CMD="$WORK/gh-dd" NEXT_DISPATCH_CLASSIFY_CMD="$WORK/classify-dd" NEXT_DISPATCH_JIRA_CMD="$WORK/jira-dd" bash "$SUT" --top 50 --held "$WORK/dd-held.txt" --workers-from "$WORK/dd-fleet.json" "$@" 2>"$WORK/dd.err"; }
dd_out="$(rundd --dispositions)"
# (c) the rename registry
has "dispositions: a pre-rename path collides with its new spelling, naming the holder" "$dd_out" "# disposition HIMMEL-901 collision scripts/handover/console-kit/dd-old.sh held by held list"
has "dispositions: a new path collides with the old spelling held" "$dd_out" "# disposition HIMMEL-903 collision scripts/handover/chief-kit/dd-newn.sh held by held list"
has "dispositions: a stale pre-rename path nobody holds is listed" "$dd_out" "LOCAL	HIMMEL-902"
# (b) the live blocker re-check
has "dispositions: a blocker Done in the live read does not drop the ticket" "$dd_out" "LOCAL	HIMMEL-904"
has "dispositions: a live blocker stays dropped and is named" "$dd_out" "# disposition HIMMEL-905 blocker HIMMEL-911 (In Progress"
lacks "dispositions: a classifier BLOCKED is never lifted, even when a key in its held path is Done live" "$dd_out" "LOCAL	HIMMEL-906"
has "dispositions: a classifier BLOCKED on a held path keeps its reason" "$dd_out" "# disposition HIMMEL-906 classification BLOCKED: scripts/lib/dd-906.sh is held (routed HIMMEL-912"
lacks "dispositions: a classifier BLOCKED whose key in the held path is live is not listed" "$dd_out" "LOCAL	HIMMEL-907"
has "dispositions: a classifier BLOCKED names its blocker" "$dd_out" "# disposition HIMMEL-907 classification BLOCKED: scripts/lib/dd-907.sh is held (routed HIMMEL-913"
# (f) the write scope is the list after 'writes confined to'
has "scope: a directory a live brief mentions outside its list holds nothing (.github/workflows)" "$dd_out" "LOCAL	HIMMEL-920"
has "scope: a mentioned scripts/ci holds nothing" "$dd_out" "LOCAL	HIMMEL-921"
has "scope: a mentioned vendored plugin dir holds nothing" "$dd_out" "LOCAL	HIMMEL-922"
has "scope: a mentioned single-writer dir holds nothing" "$dd_out" "LOCAL	HIMMEL-923"
has "scope: a directory inside the list still holds its files" "$dd_out" "# disposition HIMMEL-924 collision "
has "scope: a file on the list still holds" "$dd_out" "# disposition HIMMEL-925 collision "
# (e) one unreadable PR marks only itself unknown
has "prs: the PRs are read through the paginated files API" "$(cat "$DD_DIR/gh.args")" "api --paginate repos/yotamleo-org/Himmel/pulls/5001/files"
has "prs: the files of the PR before the unreadable one are held" "$dd_out" "# disposition HIMMEL-930 collision scripts/lib/dd-pr1.sh held by open PR 5001"
has "prs: the files of the PR after the unreadable one are held" "$dd_out" "# disposition HIMMEL-931 collision scripts/lib/dd-pr3.sh held by open PR 5003"
has "prs: a renamed file's previous name is held" "$dd_out" "# disposition HIMMEL-932 collision scripts/lib/dd-old-name.sh held by open PR 5003"
has "prs: the files read asks for previous_filename" "$(cat "$DD_DIR/gh.args")" "previous_filename"
lacks "prs: no PR is unknown when every files read succeeds" "$dd_out" "open PR files unknown"
has "dispositions: a directory ticket with a held file under it is dropped, naming the file and its holder" "$dd_out" "# disposition HIMMEL-960 classification BLOCKED: scripts/lib/dd-ov/ contains held scripts/lib/dd-ov/x.sh (open PR 5001)"
lacks "dispositions: a directory ticket with a held file under it is never listed" "$dd_out" "LOCAL	HIMMEL-960"
has "dispositions: a hook ticket naming a directory with a held file under it is dropped, naming the holder" "$dd_out" "# disposition HIMMEL-961 classification BLOCKED: scripts/lib/dd-ov2/ contains held scripts/lib/dd-ov2/y.sh (open PR 5001)"
lacks "dispositions: a hook ticket naming a directory with a held file under it is never listed" "$dd_out" "LOCAL	HIMMEL-961"
printf '%s\n' "$dd_out" | grep -Eq '^LOCAL.HIMMEL-962.*files=scripts/lib/$' && pass "files: a directory named without its slash keeps the slash" || fail "files: a directory named without its slash lost the slash"
# one unreadable PR marks only itself unknown, and holds every To Do row meanwhile
export DDU="$WORK/ddu"; mkdir -p "$DDU"
cp "$DD_DIR/live.txt" "$DD_DIR/prs.tsv" "$DD_DIR/files-5001" "$DD_DIR/files-5003" "$DDU/"
: > "$DDU/fail-5002"
ddu_out="$(DD_DIR="$DDU" rundd --dispositions)" && pass "prs: the run with an unreadable PR exits 0" || fail "prs: the run with an unreadable PR failed"
has "prs: the unreadable PR is named in the header" "$ddu_out" "open PR files unknown for PR 5002"
lacks "prs: one unreadable PR does not mark every open PR unknown" "$ddu_out" "open PRs unknown"
has "prs: the files of the PR before the unreadable one are still held" "$ddu_out" "# disposition HIMMEL-930 collision scripts/lib/dd-pr1.sh held by open PR 5001"
has "prs: the files of the PR after the unreadable one are still held" "$ddu_out" "# disposition HIMMEL-931 collision scripts/lib/dd-pr3.sh held by open PR 5003"
lacks "prs: RESUME rows are suppressed while a PR's files are unreadable" "$ddu_out" "RESUME	HIMMEL-940"
lacks "prs: no To Do row is listed while a PR's files are unreadable" "$ddu_out" "LOCAL	HIMMEL-902"
has "prs: a To Do row held for an unreadable PR says why" "$ddu_out" "# disposition HIMMEL-902 open PR files unknown (PR 5002)"
# a PR the API cuts short at 3000 files is unknown, not a silent truncation
export DD3K="$WORK/dd3k"; mkdir -p "$DD3K"
cp "$DD_DIR/live.txt" "$DD3K/live.txt"
printf '5101\tfix(x): [HIMMEL-9104] vast\tfix/himmel-9104-vast\n' > "$DD3K/prs.tsv"
seq 1 3000 | sed 's#^#scripts/lib/dd-vast-#' > "$DD3K/files-5101"
dd3k_out="$(DD_DIR="$DD3K" rundd --dispositions)" && pass "prs: the 3000-file run exits 0" || fail "prs: the 3000-file run failed"
has "prs: a PR listing 3000 files is named unknown in the header" "$dd3k_out" "5101"
lacks "prs: a PR listing 3000 files suppresses RESUME rows" "$dd3k_out" "RESUME	HIMMEL-940"
# (d) a disposition for every open ticket of the version
has "dispositions: a listed ticket says so" "$dd_out" "# disposition HIMMEL-902 listed LOCAL"
has "dispositions: a worker-less In Progress ticket is a RESUME row while every PR is readable" "$dd_out" "RESUME	HIMMEL-940"
has "dispositions: an in-progress ticket whose RESUME row is suppressed is still accounted for" "$ddu_out" "# disposition HIMMEL-940 unowned In Progress"
has "dispositions: a label drop names the label" "$dd_out" "# disposition HIMMEL-951 label operator-decision"
dd_n="$(printf '%s\n' "$dd_out" | grep -c '^# disposition ')"
[ "$dd_n" = 21 ] && pass "dispositions: one line per open v1.0.1 ticket (21)" || fail "dispositions: $dd_n lines for 21 open v1.0.1 tickets"
ddu_n="$(printf '%s\n' "$ddu_out" | grep -c '^# disposition ')"
[ "$ddu_n" = 21 ] && pass "dispositions: an unreadable PR still leaves one line per ticket (21)" || fail "dispositions: $ddu_n lines with an unreadable PR, expected 21"
dd_plain="$(rundd)"
lacks "dispositions: a plain run prints none" "$dd_plain" "# disposition "

# --- soft edges on a local git fixture (no flag) ---------------------------------
# A ticket whose files overlap an open PR is kept when the trial merge of that PR against main
# is clean, the overlap is at most 2 files and no trust path is involved, and says so with a
# `# SOFT` row.
G="$WORK/soft-git"; mkdir -p "$G"
g() { git -C "$G" -c user.name=t -c user.email=t@example.com -c commit.gpgsign=false -c core.hooksPath=/dev/null "$@"; }
g init -q -b main
for f in soft-a soft-b soft-c soft-d soft-conf; do seq 1 20 | sed "s/^/$f /" > "$G/$f.txt"; done
g add -A; g commit -q -m base
g checkout -q -b pr-clean; sed '1s/.*/changed by the PR/' "$G/soft-a.txt" > "$G/soft-a.txt.n" && mv "$G/soft-a.txt.n" "$G/soft-a.txt"; g commit -q -am pr-clean
SHA_CLEAN="$(g rev-parse HEAD)"
g checkout -q main; g checkout -q -b pr-conflict; sed '1s/.*/PR side/' "$G/soft-conf.txt" > "$G/soft-conf.txt.n" && mv "$G/soft-conf.txt.n" "$G/soft-conf.txt"; g commit -q -am pr-conflict
SHA_CONFLICT="$(g rev-parse HEAD)"
g checkout -q main; sed '1s/.*/main side/' "$G/soft-conf.txt" > "$G/soft-conf.txt.n" && mv "$G/soft-conf.txt.n" "$G/soft-conf.txt"; g commit -q -am main-moves

SD="$WORK/soft-gh"; mkdir -p "$SD"
printf '7001\tfeat(x): [HIMMEL-9901] clean\tfeat/himmel-9901-clean\n7002\tfeat(x): [HIMMEL-9902] conflicting\tfeat/himmel-9902-conf\n7003\tfeat(x): [HIMMEL-9903] trust\tfeat/himmel-9903-trust\n7004\tfeat(x): [HIMMEL-9904] wide\tfeat/himmel-9904-wide\n' > "$SD/prs.tsv"
printf '7001\n7002\n7003\n7004\n' > "$SD/nums"
printf 'scripts/lanes/soft-a.sh\nscripts/lanes/soft-one.sh\nscripts/lanes/soft-two.sh\n' > "$SD/files-7001"
printf 'scripts/lanes/soft-conf.sh\n' > "$SD/files-7002"
printf 'scripts/lib/soft-trust.sh\n' > "$SD/files-7003"
printf 'scripts/lanes/wide-a.sh\nscripts/lanes/wide-b.sh\nscripts/lanes/wide-c.sh\n' > "$SD/files-7004"
printf '%s' "$SHA_CLEAN" > "$SD/head-7001"; printf '%s' "$SHA_CONFLICT" > "$SD/head-7002"
printf '%s' "$SHA_CLEAN" > "$SD/head-7003"; printf '%s' "$SHA_CLEAN" > "$SD/head-7004"
cat > "$WORK/gh31" <<'EOF'
#!/usr/bin/env bash
n="$(printf '%s' "$*" | sed -n 's|.*pulls/\([0-9]*\).*|\1|p')"
case "$*" in
    *merged*) ;;
    *"pr list"*headRefName*) cat "$SOFT_DIR/prs.tsv" ;;
    *"pr list"*) cat "$SOFT_DIR/nums" ;;
    *head.sha*) cat "$SOFT_DIR/head-$n" ;;
    *pulls/*/files*) cat "$SOFT_DIR/files-$n" ;;
esac
EOF
chmod +x "$WORK/gh31"
export SOFT_DIR="$SD"
M31="$WORK/m31/HIMMEL"; mkdir -p "$M31"
M_SAVE="$M"; M="$M31"
mk HIMMEL-3101 "To Do" Highest '[]' '["v1.0.1"]' '[]' "overlaps a clean PR" "Edit scripts/lanes/soft-one.sh only."
mk HIMMEL-3102 "To Do" High '[]' '["v1.0.1"]' '[]' "overlaps a PR whose trial merge conflicts" "Edit scripts/lanes/soft-conf.sh only."
mk HIMMEL-3103 "To Do" High '[]' '["v1.0.1"]' '[]' "overlaps a trust path" "Edit scripts/lib/soft-trust.sh only."
mk HIMMEL-3104 "To Do" High '[]' '["v1.0.1"]' '[]' "overlaps three files" "Edit scripts/lanes/wide-a.sh, scripts/lanes/wide-b.sh and scripts/lanes/wide-c.sh."
mk HIMMEL-3105 "To Do" High '[]' '["v1.0.1"]' '[]' "overlaps a PR and a live worker" "Edit scripts/lanes/soft-a.sh and scripts/handover/chief-kit/live-file.sh."
mk HIMMEL-3106 "To Do" Medium '[]' '["v1.0.1"]' '[]' "overlaps two files of a clean PR" "Edit scripts/lanes/soft-a.sh and scripts/lanes/soft-two.sh."
mk HIMMEL-3107 "To Do" Medium '[]' '["v1.0.1"]' '[]' "overlaps nothing" "Edit scripts/lanes/free-one.sh only."
M="$M_SAVE"
cp "$WORK/jira-mirror/HIMMEL.versions.tsv" "$WORK/m31/HIMMEL.versions.tsv"
run31() { NEXT_DISPATCH_MIRROR="$M31" NEXT_DISPATCH_GH_CMD="$WORK/gh31" NEXT_DISPATCH_CLASSIFY_CMD="$WORK/classify2" NEXT_DISPATCH_GIT_DIR="$G" NEXT_DISPATCH_MAIN_REF="${SOFT_MAIN_REF:-main}" bash "$SUT" --top 20 --workers-from "$WORK/fleet.json" "$@" 2>/dev/null; }
soft_on="$(run31)"
soft_why="$(run31 --why)"

# the clean small overlaps stay dispatchable and are named
has "soft: a ticket overlapping a clean PR is listed" "$soft_on" "HIMMEL-3101	"
has "soft: it says SOFT, naming the holder and the file" "$soft_on" "# SOFT open PR 7001 scripts/lanes/soft-one.sh for HIMMEL-3101"
has "soft: a two-file overlap of one clean PR is listed" "$soft_on" "HIMMEL-3106	"
has "soft: the two-file SOFT row names both files" "$soft_on" "# SOFT open PR 7001 scripts/lanes/soft-a.sh,scripts/lanes/soft-two.sh for HIMMEL-3106"
has "soft: a ticket that overlaps nothing is still listed" "$soft_on" "HIMMEL-3107	"
lacks "soft: a ticket that overlaps nothing has no SOFT row" "$soft_on" "for HIMMEL-3107"
lacks "soft: a PR whose trial merge conflicts still holds its file" "$soft_on" "HIMMEL-3102	"
lacks "soft: a trust path is never soft" "$soft_on" "HIMMEL-3103	"
lacks "soft: more than 2 overlapping files is never soft" "$soft_on" "HIMMEL-3104	"
lacks "soft: a live worker's file holds even beside a soft overlap" "$soft_on" "HIMMEL-3105	"
has "soft --why: a conflicting trial merge is still a collision drop" "$soft_why" "# drop HIMMEL-3102 collision scripts/lanes/soft-conf.sh held by open PR 7002"
has "soft --why: a trust path is still a collision drop" "$soft_why" "# drop HIMMEL-3103 collision scripts/lib/soft-trust.sh held by open PR 7003"
has "soft --why: a wide overlap is still a collision drop" "$soft_why" "# drop HIMMEL-3104 collision "
has "soft --why: the live-worker overlap names the first holder it finds" "$soft_why" "# drop HIMMEL-3105 collision "

# an unresolvable main ref fails closed to the collision drop
soft_nohead="$( export SOFT_MAIN_REF=no-such-ref; run31 )"
lacks "soft: an unresolvable main ref falls back to the collision drop" "$soft_nohead" "HIMMEL-3101	"
lacks "soft: and prints no SOFT row" "$soft_nohead" "SOFT"

# --- a ticket with no DoD or no Proof is refused at dispatch. The
# checker is marketplace/plugins/himmel-ops/scripts/ticket-standard-check.sh; the
# refusal prints the ticket for the chief to fix first and parks nothing. -----
M="$WORK/jira-mirror-proof/HIMMEL"; mkdir -p "$M"
MK_BARE=1 mk HIMMEL-9101 "To Do" High '[]' '["v1.0.1"]' '[]' "has a DoD but no Proof" $'Edit scripts/lib/proof-a.sh.\n\nDoD\n- the row is green\n'
MK_BARE=1 mk HIMMEL-9102 "To Do" High '[]' '["v1.0.1"]' '[]' "has neither DoD nor Proof" "Edit scripts/lib/proof-b.sh."
mk HIMMEL-9103 "To Do" High '[]' '["v1.0.1"]' '[]' "has both" "Edit scripts/lib/proof-c.sh."
MK_BARE=1 mk HIMMEL-9104 "To Do" High '[]' '["v1.0.1"]' '[]' "Proof is a placeholder" $'Edit scripts/lib/proof-d.sh.\n\nDoD\n- the row is green\n\nProof\nTBD\n'
printf 'v1.0.1\tfalse\t\n' > "$WORK/jira-mirror-proof/HIMMEL.versions.tsv"
proof_run() { NEXT_DISPATCH_MIRROR="$M" NEXT_DISPATCH_GH_CMD="$WORK/gh" NEXT_DISPATCH_CLASSIFY_CMD="$WORK/classify" HANDOVER_DIR="$WORK/proof-handover" bash "$SUT" --no-classify --top 20 "$@" 2>/dev/null; }
proof_out="$(proof_run)"
has "proof: a ticket with DoD and Proof is listed" "$proof_out" "HIMMEL-9103	"
lacks "proof: a ticket with no Proof section is not listed" "$proof_out" "HIMMEL-9101	"
lacks "proof: a ticket with neither section is not listed" "$proof_out" "HIMMEL-9102	"
lacks "proof: a placeholder Proof is not a Proof" "$proof_out" "HIMMEL-9104	"
has "proof: the refusal names the missing section" "$proof_out" "# NO-PROOF HIMMEL-9101 missing Proof"
has "proof: the refusal names both missing sections" "$proof_out" "# NO-PROOF HIMMEL-9102 missing DoD, Proof"
has "proof: the refusal carries the title for the chief to fix" "$proof_out" "has a DoD but no Proof"
lacks "proof: a ticket that passes gets no refusal line" "$proof_out" "NO-PROOF HIMMEL-9103"
has "proof --why: the drop reason is the missing section" "$(proof_run --why)" "# drop HIMMEL-9101 proof missing: Proof"
[ ! -e "$WORK/proof-handover" ] && pass "proof: the read-only listing parks nothing in the handover intake queue" || fail "proof: the listing wrote to the handover dir"

# A note on Writes is context, never a directory-wide hold.
M="$WORK/jira-mirror-writes-note/HIMMEL"; mkdir -p "$M"
mk HIMMEL-9201 "To Do" High '[]' '["v1.0.1"]' '[]' "the worker's actual file" "Edit docs/nd-note-own.md."
mk HIMMEL-9202 "To Do" High '[]' '["v1.0.1"]' '[]' "a directory only the parenthetical names" "Edit scripts/lib/nd-note-free.sh."
mk HIMMEL-9203 "To Do" High '[]' '["v1.0.1"]' '[]' "a directory only Writes note names" "Edit scripts/config-ui/nd-note-free.ts."
mk HIMMEL-9204 "To Do" High '[]' '["v1.0.1"]' '[]' "a write after the parenthetical" "Edit docs/nd-note-after.md."
printf 'v1.0.1\tfalse\t\n' > "$WORK/jira-mirror-writes-note/HIMMEL.versions.tsv"
NOTE_WORKER="$WORK/HIMMEL-9299-N920-live.md"
printf '%s\n' '> **Writes:** docs/nd-note-own.md (no scripts/lib file until the chief rules) docs/nd-note-after.md' '> **Writes note:** scripts/config-ui/ is held by another worker; writes confined to scripts/config-ui/.' > "$NOTE_WORKER"
printf '{"schema":1,"legs":[{"doc":"%s","label":"N920"}]}\n' "$NOTE_WORKER" > "$WORK/fleet-note.json"
note_out="$(run --no-classify --workers-from "$WORK/fleet-note.json" --why)"
has "Writes note: parenthetical scripts/lib never holds its subtree" "$note_out" "LOCAL?	HIMMEL-9202"
has "Writes note: a separate note holds nothing even with a legacy scope phrase" "$note_out" "LOCAL?	HIMMEL-9203"
has "Writes note: the real file before the parenthetical still holds" "$note_out" "# drop HIMMEL-9201 collision docs/nd-note-own.md held by live worker N920"
has "Writes note: the real file after the parenthetical still holds" "$note_out" "# drop HIMMEL-9204 collision docs/nd-note-after.md held by live worker N920"
lacks "Writes note: a parenthetical directory produces no wide-hold warning" "$note_out" "# warn: N920 holds directory scripts/lib"
printf '%s\n' '> **Writes:** scripts/lib scripts/lib/' '> **Writes note:** docs/nd-note-own.md' > "$NOTE_WORKER"
note_wide="$(run --no-classify --workers-from "$WORK/fleet-note.json" --why)"
has "Writes note: a bare directory still holds its subtree" "$note_wide" "# drop HIMMEL-9202 collision scripts/lib/nd-note-free.sh held by live worker N920"
[ "$(printf '%s\n' "$note_wide" | grep -c '^# warn: N920 holds directory scripts/lib/$')" = 1 ] && pass "Writes note: --why warns once per held directory" || fail "Writes note: --why must warn once for scripts/lib/: $note_wide"
case "$note_wide" in "# source mirror_age_min="*) pass "Writes note: the age header comes before the directory warning" ;; *) fail "Writes note: the age header is not first (got: ${note_wide%%$'\n'*})" ;; esac
lacks "Writes note: normal output has no directory warning" "$(run --no-classify --workers-from "$WORK/fleet-note.json")" "# warn: N920 holds directory"
printf '%s\n' '> **Writes:** none named' '> **Writes note:** writes confined to scripts/lib/.' > "$NOTE_WORKER"
note_empty="$(run --no-classify --workers-from "$WORK/fleet-note.json" --why)"
has "Writes note: an explicit empty Writes ignores note paths" "$note_empty" "LOCAL?	HIMMEL-9202"
lacks "Writes note: an explicit empty Writes is not unknown" "$note_empty" "live workers unknown"
printf '%s\n' '> **Scope / do not:** writes confined to docs/nd-note-own.md.' '> **Writes note:** writes confined to scripts/lib/.' > "$NOTE_WORKER"
note_legacy="$(run --no-classify --workers-from "$WORK/fleet-note.json" --why)"
has "Writes note: a note is ignored in the older-brief fallback too" "$note_legacy" "LOCAL?	HIMMEL-9202"
has "Writes note: the older-brief fallback still holds its own file" "$note_legacy" "# drop HIMMEL-9201 collision docs/nd-note-own.md held by live worker N920"

# a Done-category status the name list does not know ('wont do') is done: its blocked ticket is dispatchable
DC_DIR="$WORK/jira-mirror-done-cat"; M="$DC_DIR/HIMMEL"; mkdir -p "$M"
printf 'v1.0.1\tfalse\t\n' > "$DC_DIR/HIMMEL.versions.tsv"
printf -- '---\nkey: "HIMMEL-9301"\ntype: "Task"\nstatus: "wont do"\nstatusCategory: "Done"\npriority: "High"\nlabels: []\nfixVersions: ["v1.0.1"]\nparent: null\nlinks:\n  blocks: []\n  blocked_by: []\n  relates: []\n---\n\n# HIMMEL-9301: closed as wont do\n\n## Description\n\nEdit scripts/lib/wontdo.sh.\n' > "$M/HIMMEL-9301.md"
mk HIMMEL-9302 "To Do" High '[]' '["v1.0.1"]' '["HIMMEL-9301"]' "blocked only by a wont do ticket" "Edit scripts/lib/after-wontdo.sh."
dc_out="$(run --no-classify)"; dc_rc=$?
[ "$dc_rc" = 0 ] && pass "Done category: the dispatcher exits 0" || fail "Done category: the dispatcher exited $dc_rc"
has "Done category: a blocker in a Done-category status (wont do) is resolved" "$dc_out" "LOCAL?	HIMMEL-9302"
# a Done-category mirror row whose live Jira status was reopened still blocks; a live wont do still counts as done
printf -- '---\nkey: "HIMMEL-9303"\ntype: "Task"\nstatus: "wont do"\nstatusCategory: "Done"\npriority: "High"\nlabels: []\nfixVersions: ["v1.0.1"]\nparent: null\nlinks:\n  blocks: []\n  blocked_by: []\n  relates: []\n---\n\n# HIMMEL-9303: stale wont do\n\n## Description\n\nEdit scripts/lib/stale.sh.\n' > "$M/HIMMEL-9303.md"
mk HIMMEL-9304 "To Do" High '[]' '["v1.0.1"]' '["HIMMEL-9303"]' "blocked by a reopened ticket" "Edit scripts/lib/after-reopen.sh."
# shellcheck disable=SC2016  # the $ names are literal text of the fake Jira CLI, expanded when it runs
printf '#!/usr/bin/env bash\n[ "$1" = get ] || exit 2\nprintf "%%s\\tTask\\t%%s\\tt\\n" "$2" "$LIVE_STATUS"\n' > "$WORK/jira-live"; chmod +x "$WORK/jira-live"
reopen_out="$(NEXT_DISPATCH_JIRA_CMD="$WORK/jira-live" LIVE_STATUS="In Progress" run --no-classify)"; reopen_rc=$?
[ "$reopen_rc" = 0 ] && pass "Done category: reopened live run exits 0" || fail "Done category: reopened live run exited $reopen_rc"
lacks "Done category: a mirror wont do blocker reopened live still blocks" "$reopen_out" "HIMMEL-9304"
closed_out="$(NEXT_DISPATCH_JIRA_CMD="$WORK/jira-live" LIVE_STATUS="wont do" run --no-classify)"; closed_rc=$?
[ "$closed_rc" = 0 ] && pass "Done category: live wont do run exits 0" || fail "Done category: live wont do run exited $closed_rc"
has "Done category: a mirror wont do blocker still wont do live is resolved" "$closed_out" "LOCAL?	HIMMEL-9304"
archived_out="$(NEXT_DISPATCH_JIRA_CMD="$WORK/jira-live" LIVE_STATUS="Archived" run --no-classify)"; archived_rc=$?
[ "$archived_rc" = 0 ] && pass "Done category: live Archived run exits 0" || fail "Done category: live Archived run exited $archived_rc"
lacks "Done category: an unlisted live status (Archived) holds the dependent" "$archived_out" "HIMMEL-9304"
# the disposition list drops a Done-category ticket from the open set and keeps an open one
dispo_out="$(run --no-classify --priority-pool-only --dispositions)"; dispo_rc=$?
[ "$dispo_rc" = 0 ] && pass "Done category: --dispositions exits 0" || fail "Done category: --dispositions exited $dispo_rc"
lacks "Done category: --dispositions does not list a wont do ticket" "$dispo_out" "HIMMEL-9301"
has "Done category: --dispositions lists an open ticket" "$dispo_out" "# disposition HIMMEL-9302 "
M="$WORK/jira-mirror/HIMMEL"

# more than 60 fresh blocker keys: every one is read live (no silent cut), so a ticket whose 70 mirror-open blockers are all Done live is dispatchable
CAP_DIR="$WORK/jira-mirror-cap"; M="$CAP_DIR/HIMMEL"; mkdir -p "$M"
printf 'v1.0.1\tfalse\t\n' > "$CAP_DIR/HIMMEL.versions.tsv"
cap_blockers=""
for n in $(seq 9400 9469); do
    mk "HIMMEL-$n" "In Progress" High '[]' '["v1.0.1"]' '[]' "cap blocker $n" "Edit scripts/lib/cap-$n.sh."
    cap_blockers="${cap_blockers:+$cap_blockers, }\"HIMMEL-$n\""
done
mk HIMMEL-9500 "To Do" High '[]' '["v1.0.1"]' "[$cap_blockers]" "blocked by 70 mirror-open tickets" "Edit scripts/lib/cap-dependent.sh."
CAP_LOG="$WORK/jira-cap.log"; : > "$CAP_LOG"
# shellcheck disable=SC2016  # the $ names are literal text of the fake Jira CLI, expanded when it runs
printf '#!/usr/bin/env bash\n[ "$1" = get ] || exit 2\nprintf "%%s\\n" "$2" >> "$CAP_LOG"\nprintf "%%s\\tTask\\tDone\\tt\\n" "$2"\n' > "$WORK/jira-cap"; chmod +x "$WORK/jira-cap"
cap_out="$(NEXT_DISPATCH_JIRA_CMD="$WORK/jira-cap" CAP_LOG="$CAP_LOG" run --no-classify --why)"; cap_rc=$?
[ "$cap_rc" = 0 ] && pass "live cap: the 70-blocker run exits 0" || fail "live cap: the 70-blocker run exited $cap_rc"
[ "$(sort -u "$CAP_LOG" | grep -c .)" = 70 ] && pass "live cap: all 70 blocker keys are read live" || fail "live cap: expected 70 live reads, got $(sort -u "$CAP_LOG" | grep -c .)"
lacks "live cap: a ticket whose 70 blockers are all Done live is not dropped for a blocker" "$cap_out" "# drop HIMMEL-9500 blocker"
has "live cap: that ticket is a collision-free candidate" "$cap_out" "1 To Do candidate(s), 1 collision-free"
M="$WORK/jira-mirror/HIMMEL"

# the live blocker re-check, both directions: every hard blocker of a candidate is read live, an unreadable one is unknown
LB_DIR="$WORK/jira-mirror-lb"; M="$LB_DIR/HIMMEL"; mkdir -p "$M"
printf 'v1.0.1\tfalse\t\n' > "$LB_DIR/HIMMEL.versions.tsv"
mk HIMMEL-9601 "Done" High '[]' '["v1.0.1"]' '[]' "blocker Done in the mirror, open live" "Edit scripts/lib/lb-9601.sh."
mk HIMMEL-9602 "To Do" High '[]' '["v1.0.1"]' '["HIMMEL-9601"]' "blocked by a reopened ticket" "Edit scripts/lib/lb-9602.sh."
mk HIMMEL-9603 "In Progress" High '[]' '["v1.0.1"]' '[]' "blocker open in the mirror, unreadable live" "Edit scripts/lib/lb-9603.sh."
mk HIMMEL-9604 "To Do" High '[]' '["v1.0.1"]' '["HIMMEL-9603"]' "blocked by an unreadable ticket" "Edit scripts/lib/lb-9604.sh."
mk HIMMEL-9605 "To Do" High '[]' '["v1.0.1"]' '["HIMMEL-9699"]' "blocked by a ticket the mirror lacks" "Edit scripts/lib/lb-9605.sh."
mk HIMMEL-9606 "Done" High '[]' '["v1.0.1"]' '[]' "blocker Done in the mirror and live" "Edit scripts/lib/lb-9606.sh."
mk HIMMEL-9607 "To Do" High '[]' '["v1.0.1"]' '["HIMMEL-9606"]' "blocked by a ticket Done everywhere" "Edit scripts/lib/lb-9607.sh."
mk HIMMEL-9608 "In Progress" High '[]' '["v1.0.1"]' '[]' "blocker open in the mirror, Done live" "Edit scripts/lib/lb-9608.sh."
mk HIMMEL-9609 "To Do" High '[]' '["v1.0.1"]' '["HIMMEL-9608"]' "blocked by a ticket the mirror lags" "Edit scripts/lib/lb-9609.sh."
mk HIMMEL-9611 "Done" High '[]' '["v1.0.1"]' '[]' "blocker Done in the mirror, open live, read only for a RESUME row" "Edit scripts/lib/lb-9611.sh."
mk HIMMEL-9612 "In Progress" High '[]' '["v1.0.1"]' '["HIMMEL-9611"]' "an orphan whose mirror-Done blocker is reopened live" "Edit scripts/lib/lb-9612.sh."
mk HIMMEL-9613 "In Progress" High '[]' '["v1.0.1"]' '["HIMMEL-9606"]' "an orphan whose blocker is Done everywhere" "Edit scripts/lib/lb-9613.sh."
cat > "$WORK/jira-lb" <<'EOF'
#!/usr/bin/env bash
[ "$1" = get ] || exit 2
case "$2" in
    HIMMEL-9601|HIMMEL-9611) st="In Progress" ;;
    HIMMEL-9603|HIMMEL-9699) exit 1 ;;
    *) st="Done" ;;
esac
printf '%s\tTask\t%s\tt\n' "$2" "$st"
EOF
chmod +x "$WORK/jira-lb"
python3 -I -c 'import os, sys, time; t = time.time() - 5400; [os.utime(p, (t, t)) for p in sys.argv[1:]]' "$M"/*.md || fail "live blockers: setting the fixture's age failed"  # a controlled mirror age for the header row below (no touch -d: BSD and GNU differ)
lb_out="$(NEXT_DISPATCH_JIRA_CMD="$WORK/jira-lb" run --no-classify --why)"; lb_rc=$?
[ "$lb_rc" = 0 ] && pass "live blockers: the run exits 0" || fail "live blockers: the run exited $lb_rc"
has "live blockers: a blocker Done in the mirror but open live drops the candidate" "$lb_out" "# drop HIMMEL-9602 blocker HIMMEL-9601 (reopened live)"
has "live blockers: a failed live read is blocker-unknown" "$lb_out" "# drop HIMMEL-9604 blocker-unknown HIMMEL-9603"
has "live blockers: a blocker missing from the mirror and unreadable live is blocker-unknown" "$lb_out" "# drop HIMMEL-9605 blocker-unknown HIMMEL-9699"
lacks "live blockers: an unreadable blocker is never listed" "$lb_out" "LOCAL?	HIMMEL-9604"
has "live blockers: a blocker Done in the mirror and live is cleared" "$lb_out" "LOCAL?	HIMMEL-9607"
has "live blockers: a blocker open in the mirror but Done live is cleared" "$lb_out" "LOCAL?	HIMMEL-9609"
lacks "live blockers: a RESUME row whose mirror-Done blocker is reopened live is not listed" "$lb_out" "RESUME	HIMMEL-9612"
has "live blockers: a RESUME row whose blocker is Done everywhere is listed" "$lb_out" "RESUME	HIMMEL-9613"
has "live blockers: the header shows the mirror's age" "$lb_out" "# source mirror_age_min=90"
has "live blockers: the header counts the live reads of the run" "$lb_out" "# source live_reads=6"
case "$lb_out" in "# source mirror_age_min=90"*) pass "live blockers: the age header is the first line, ahead of every warning" ;; *) fail "live blockers: the age header is not first (got: ${lb_out%%$'\n'*})" ;; esac
# a mirror directory that does not exist is an error, never an empty pool
nomirror_out="$(NEXT_DISPATCH_MIRROR="$WORK/no-such-mirror" NEXT_DISPATCH_GH_CMD="$WORK/gh" NEXT_DISPATCH_CLASSIFY_CMD="$WORK/classify" bash "$SUT" --no-classify 2>&1)"; nomirror_rc=$?
[ "$nomirror_rc" = 3 ] && pass "missing mirror: the dispatcher exits 3" || fail "missing mirror: the dispatcher exited $nomirror_rc"
has "missing mirror: the error says so" "$nomirror_out" "mirror missing"
# a listed mirror file that cannot be read is the same error, not a traceback
M="$WORK/jira-mirror-ur/HIMMEL"; mkdir -p "$M"
mk HIMMEL-9690 "To Do" High '[]' '["v1.0.1"]' '[]' "an unreadable mirror file" "Edit scripts/lib/ur-9690.sh."
chmod 000 "$M/HIMMEL-9690.md"
if [ -r "$M/HIMMEL-9690.md" ]; then
    pass "unreadable mirror file: skipped (this user can read a mode 000 file)"
else
    ur_out="$(NEXT_DISPATCH_MIRROR="$M" NEXT_DISPATCH_GH_CMD="$WORK/gh" NEXT_DISPATCH_CLASSIFY_CMD="$WORK/classify" bash "$SUT" --no-classify 2>&1)"; ur_rc=$?
    [ "$ur_rc" = 3 ] && pass "unreadable mirror file: the dispatcher exits 3" || fail "unreadable mirror file: the dispatcher exited $ur_rc"
    has "unreadable mirror file: the error says so" "$ur_out" "mirror missing or unreadable"
fi
chmod 600 "$M/HIMMEL-9690.md"
M="$WORK/jira-mirror/HIMMEL"

# A RESUME row a collision drops is named `RESUME-HELD <key> by <holder>`, never silent:
# one a live worker's write scope holds, one another listed RESUME row holds (full pass only).
M7="$WORK/m7/HIMMEL"; mkdir -p "$M7"
M_SAVE="$M"; M="$M7"
mk HIMMEL-80 "In Progress" High '[]' '[]' '[]' "held by a live worker scope" "Edit scripts/lib/rh1.sh."
mk HIMMEL-81 "In Progress" High '[]' '[]' '[]' "free in work" "Edit scripts/lib/rh2.sh."
mk HIMMEL-82 "In Progress" Low '[]' '[]' '[]' "held by the listed 81" "Edit scripts/lib/rh2.sh."
M="$M_SAVE"
LEG7="$WORK/HIMMEL-79-N8-live.md"; printf '> **Writes:** scripts/lib/rh1.sh\n# live\n' > "$LEG7"
printf '{"schema":1,"legs":[{"doc":"%s","label":"N8"}]}\n' "$LEG7" > "$WORK/fleet7.json"
rh() { NEXT_DISPATCH_MIRROR="$M7" NEXT_DISPATCH_GH_CMD="$WORK/gh" NEXT_DISPATCH_CLASSIFY_CMD="$WORK/classify2" bash "$SUT" "$@" --workers-from "$WORK/fleet7.json" 2>/dev/null; }
rh_full="$(rh)"; rh_full_rc=$?
check "the full pass exits 0 (HIMMEL-6604)" "0" "$rh_full_rc"
has "a RESUME row a live worker's scope holds is named RESUME-HELD (HIMMEL-6604)" "$rh_full" "RESUME-HELD HIMMEL-80 by live worker N8"
has "a RESUME row another listed RESUME row holds is named RESUME-HELD (HIMMEL-6604)" "$rh_full" "RESUME-HELD HIMMEL-82 by listed HIMMEL-81"
lacks "a held RESUME row is not also offered as RESUME (HIMMEL-6604)" "$rh_full" "RESUME	HIMMEL-80"
lacks "a RESUME row held by a listed ticket is not also offered as RESUME (HIMMEL-6604)" "$rh_full" "RESUME	HIMMEL-82"
has "the free RESUME row is still offered (HIMMEL-6604)" "$rh_full" "RESUME	HIMMEL-81"
rh_only="$(rh --resume-only)"; rh_only_rc=$?
check "--resume-only exits 0 (HIMMEL-6604)" "0" "$rh_only_rc"
has "--resume-only names the worker-held RESUME row too (HIMMEL-6604)" "$rh_only" "RESUME-HELD HIMMEL-80 by live worker N8"

# --- (8170) versionless operator work is INTAKE, never a bare LOW: open tickets with no fixVersion that are
# operator-directed, a Bug of High or above, labelled scope-<current version> or held by a live worker count;
# a residual-depth backlog ticket or a plain versionless one does not ---
MI="$WORK/jira-mirror-intake/HIMMEL"; mkdir -p "$MI"
M_SAVE="$M"; M="$MI"
mk HIMMEL-901 "To Do" Medium '["operator-directed","backlog"]' '[]' '[]' "operator asked for this, no version" "Edit scripts/lib/in1.sh only."
mk HIMMEL-902 "To Do" High '["backlog"]' '[]' '[]' "a high bug, no version" "Edit scripts/lib/in2.sh only."
retype "$MI/HIMMEL-902.md" Bug
mk HIMMEL-903 "To Do" Medium '["backlog","residual-depth-1"]' '[]' '[]' "a residual-depth-1 backlog ticket" "Edit scripts/lib/in3.sh only."
mk HIMMEL-904 "To Do" Medium '["backlog"]' '[]' '[]' "a plain backlog ticket" "Edit scripts/lib/in4.sh only."
mk HIMMEL-905 "To Do" Low '["scope-v1.0.1"]' '[]' '[]' "scoped to the current version, no fixVersion" "Edit scripts/lib/in5.sh only."
mk HIMMEL-906 "To Do" Medium '["operator-directed"]' '["v1.0.1"]' '[]' "operator work already in the version" "Edit scripts/lib/in6.sh only."
mk HIMMEL-907 "Done" Medium '["operator-directed"]' '[]' '[]' "operator work, closed" "Edit scripts/lib/in7.sh only."
mk HIMMEL-8173 "To Do" Medium '[]' '["v1.0.1"]' '[]' "hook comments stop citing Windows jq.exe, MSYS and Defender rationale" "Edit scripts/lib/in8.sh only."
mk HIMMEL-909 "To Do" Medium '[]' '["v1.0.1"]' '[]' "Windows service stops unexpectedly" "Edit scripts/lib/in9.sh only."
mk HIMMEL-910 "To Do" Medium '[]' '["v1.0.1"]' '[]' "Remove the WSL station triage" "Edit scripts/lib/in10.sh only."
mk HIMMEL-911 "To Do" High '["backlog"]' '[]' '[]' "Windows installer crashes on start" "Edit scripts/lib/in11.sh only."
retype "$MI/HIMMEL-911.md" Bug
mk HIMMEL-912 "To Do" Medium '[]' '["v1.0.1"]' '[]' "Windows service crashes after device removal" "Edit scripts/lib/in12.sh only."
mk HIMMEL-913 "To Do" Medium '["backlog","proposed-v1.0.1"]' '[]' '[]' "filed with a proposed version, INTAKE queued" "Edit scripts/lib/in13.sh only."
mk HIMMEL-914 "To Do" Medium '["backlog","proposed-backlog"]' '[]' '[]' "filed to the backlog with INTAKE queued" "Edit scripts/lib/in14.sh only."
mk HIMMEL-915 "To Do" Medium '[]' '["v1.0.1"]' '[]' "Windows installer fails after removal of a device" "Edit scripts/lib/in15.sh only."
mk HIMMEL-916 "To Do" Medium '["backlog","proposed-v1.2.0"]' '[]' '[]' "proposed to a later version, INTAKE queued toward it" "Edit scripts/lib/in16.sh only."
mk HIMMEL-917 "To Do" Medium '["operator-directed","backlog","proposed-v1.2.0"]' '[]' '[]' "operator work already proposed to a later version" "Edit scripts/lib/in17.sh only."
M="$M_SAVE"
printf 'v1.0.1\tfalse\t\n' > "$WORK/jira-mirror-intake/HIMMEL.versions.tsv"
runi() { NEXT_DISPATCH_MIRROR="$MI" NEXT_DISPATCH_GH_CMD="$WORK/gh" NEXT_DISPATCH_CLASSIFY_CMD="$WORK/classify2" bash "$SUT" "$@" 2>/dev/null; }
oi="$(runi --priority-pool-only --top 7)"; oi_rc=$?
check "(8170) the intake dispatch exits 0" "0" "$oi_rc"
has "(8170) a pool short of the slots with versionless operator work reads INTAKE:<m>" "$oi" "# pool=3/7,INTAKE:4"
lacks "(8170) the pool line is not a bare LOW while INTAKE is non-zero" "$(printf '%s\n' "$oi" | grep '^# pool=')" "LOW"
lacks "(8170) a windows title with a removal verb elsewhere in it is still dropped" "$oi" "LOCAL	HIMMEL-909"
lacks "(8170) a windows title that only mentions removal is still dropped" "$oi" "LOCAL	HIMMEL-912"
lacks "(8170) a bug that reports a failure after the removal of a device is still dropped" "$oi" "LOCAL	HIMMEL-915"
lacks "(8170) a versionless High bug on the dropped platform is not an intake candidate" "$(printf '%s\n' "$oi" | grep '^# intake')" "HIMMEL-911"
has "(8170) a title that opens with a removal verb is kept" "$oi" "LOCAL	HIMMEL-910"
has "(8170) the intake line names operator-directed, High+ Bug, scope-label and proposed-version tickets with the version" "$oi" "# intake 4 for v1.0.1: HIMMEL-901 HIMMEL-902 HIMMEL-905 HIMMEL-913"
lacks "(8170) a residual-depth-1 backlog ticket is not an intake candidate" "$(printf '%s\n' "$oi" | grep '^# intake')" "HIMMEL-903"
lacks "(8170) a plain versionless backlog ticket is not an intake candidate" "$(printf '%s\n' "$oi" | grep '^# intake')" "HIMMEL-904"
lacks "(8170) a ticket proposed to the backlog is not an intake candidate" "$(printf '%s\n' "$oi" | grep '^# intake')" "HIMMEL-914"
lacks "(8170) a ticket proposed to a version other than the earliest open one is not an intake candidate" "$(printf '%s\n' "$oi" | grep '^# intake')" "HIMMEL-916"
lacks "(8170) an operator-directed ticket proposed to another version is not an intake candidate either" "$(printf '%s\n' "$oi" | grep '^# intake')" "HIMMEL-917"
lacks "(8170) an operator-directed ticket already in a version is not an intake candidate" "$(printf '%s\n' "$oi" | grep '^# intake')" "HIMMEL-906"
lacks "(8170) a closed versionless ticket is not an intake candidate" "$(printf '%s\n' "$oi" | grep '^# intake')" "HIMMEL-907"
has "(8170) a removal ticket with a windows title (HIMMEL-8173) is not dropped by the platform filter" "$oi" "LOCAL	HIMMEL-8173"
lacks "(8170) a mirror with no intake candidate prints no intake field" "$(run30 --doc "$WORK/chief-doc30.md" --priority-pool-only --top 7)" "INTAKE"

# --- (8336) the tick's --dispositions snapshot carries the intake line too, so the tick can count it ---
od="$(runi --dispositions --top 1000)"
has "(8336) a --dispositions run prints the intake line with the version" "$od" "# intake 4 for v1.0.1: HIMMEL-901 HIMMEL-902 HIMMEL-905 HIMMEL-913"

# --- (8336) with no open version the intake line names no version, so a waiter has no --to value to read ---
MN="$WORK/jira-mirror-nov/HIMMEL"; mkdir -p "$MN"; cp "$MI"/*.md "$MN"/
printf 'v1.0.1\ttrue\t\n' > "$WORK/jira-mirror-nov/HIMMEL.versions.tsv"
runn() { NEXT_DISPATCH_MIRROR="$MN" NEXT_DISPATCH_GH_CMD="$WORK/gh" NEXT_DISPATCH_CLASSIFY_CMD="$WORK/classify2" bash "$SUT" "$@" 2>/dev/null; }
on="$(runn --priority-pool-only --top 7)"
has "(8336) with no open version the intake line names the keys and no version" "$on" "# intake 2: HIMMEL-901 HIMMEL-902"
lacks "(8336) with no open version the intake line never reads 'for no open version'" "$on" "no open version"

# --- (8349 slice 1) stacked_series: tickets that share files list as one SERIES row, behind the flag ---
TAB=$'\t'
export HIMMEL_CONFIG_DIR="$WORK/no-conf"   # the operator's own himmel.conf never decides a fixture's flag
cat > "$WORK/classify-s" <<'EOF'
#!/usr/bin/env bash
for k in "$@"; do
    case "$k" in
        HIMMEL-841) printf '%s\tCLOUD-OK\tstub\n' "$k" ;;
        HIMMEL-842) printf '%s\tHOOK-BYPASS\tstub\n' "$k" ;;
        HIMMEL-845) printf '%s\tBLOCKED\tstub\n' "$k" ;;
        *) printf '%s\tLOCAL-NATIVE\tstub\n' "$k" ;;
    esac
done
EOF
chmod +x "$WORK/classify-s"
newmir() { # <name>: a fresh one-version mirror, M points at it
    M="$WORK/s-$1/HIMMEL"; mkdir -p "$M"
    printf 'v1.0.1\tfalse\t\nv1.0.2\tfalse\t\n' > "$WORK/s-$1/HIMMEL.versions.tsv"
}
runs() { # <mirror dir> <flag value> args...: the script under test with stacked_series set
    local mir="$1" flag="$2"; shift 2
    HIMMEL_FLAG_STACKED_SERIES="$flag" NEXT_DISPATCH_MIRROR="$mir" NEXT_DISPATCH_GH_CMD="$WORK/gh" NEXT_DISPATCH_CLASSIFY_CMD="$WORK/classify-s" bash "$SUT" "$@" 2>/dev/null
}
APP='Edit scripts/config-ui/app.js please.'

# three To Do UI tickets sharing app.js: one SERIES row, not 1 listed and 2 dropped
newmir ui
mk HIMMEL-801 "To Do" High '[]' '["v1.0.1"]' '[]' "ui one" "$APP"
mk HIMMEL-802 "To Do" High '[]' '["v1.0.1"]' '[]' "ui two" "$APP"
mk HIMMEL-803 "To Do" High '[]' '["v1.0.1"]' '[]' "ui three" "$APP"
UI="$M"
on="$(runs "$UI" 1 --dispositions --why)"
has "(8349) three tickets sharing app.js list as one SERIES LOCAL row" "$on" "SERIES${TAB}LOCAL${TAB}HIMMEL-801,HIMMEL-802,HIMMEL-803${TAB}High${TAB}v1.0.1${TAB}files=scripts/config-ui/app.js"
lacks "(8349) a series member has no ordinary row" "$on" "LOCAL${TAB}HIMMEL-802${TAB}"
lacks "(8349) the head has no ordinary row either" "$on" "LOCAL${TAB}HIMMEL-801${TAB}"
lacks "(8349) a series member is not dropped as a collision" "$on" "held by listed"
tp="$(runs "$UI" 1 --top 1)"
has "(8349) a full list still lets the colliding tickets join the series" "$tp" "SERIES${TAB}LOCAL${TAB}HIMMEL-801,HIMMEL-802,HIMMEL-803${TAB}"
pp="$(runs "$UI" 1 --priority-pool-only --top 5)"
has "(8349) --priority-pool-only lists the series row too" "$pp" "SERIES${TAB}LOCAL${TAB}HIMMEL-801,HIMMEL-802,HIMMEL-803${TAB}"
has "(8349) the drop line counts the series members as listed" "$on" "# dropped from v1.0.1: 0 of 3 To Do"
has "(8349) --dispositions says listed SERIES for a member" "$on" "# disposition HIMMEL-803 listed SERIES HIMMEL-801"
[ "$(printf '%s\n' "$on" | grep -c "^SERIES")" = 1 ] && pass "(8349) exactly one SERIES row" || fail "(8349) SERIES row count is not 1"

# flag off: today's output, byte for byte, whether the flag is unset-by-default or set to 0
off="$(runs "$UI" 0 --dispositions --why)"
dflt="$(NEXT_DISPATCH_MIRROR="$UI" NEXT_DISPATCH_GH_CMD="$WORK/gh" NEXT_DISPATCH_CLASSIFY_CMD="$WORK/classify-s" bash "$SUT" --dispositions --why 2>/dev/null)"
[ "$off" = "$dflt" ] && pass "(8349) flag off equals the default output" || fail "(8349) flag 0 differs from the default"
lacks "(8349) flag off prints no SERIES row" "$off" "SERIES"
has "(8349) flag off lists the head alone" "$off" "LOCAL${TAB}HIMMEL-801${TAB}"
has "(8349) flag off still drops the second with the collision reason" "$off" "# drop HIMMEL-802 collision scripts/config-ui/app.js held by listed HIMMEL-801"
has "(8349) flag off still drops the third with the collision reason" "$off" "# drop HIMMEL-803 collision scripts/config-ui/app.js held by listed HIMMEL-801"

# the cap holds at 4
newmir cap
for n in 811 812 813 814 815; do mk "HIMMEL-$n" "To Do" High '[]' '["v1.0.1"]' '[]' "cap $n" "Edit scripts/lib/cap.sh now."; done
cp_="$(runs "$M" 1 --why)"
has "(8349) a series stops at 4 items" "$cp_" "SERIES${TAB}LOCAL${TAB}HIMMEL-811,HIMMEL-812,HIMMEL-813,HIMMEL-814${TAB}"
has "(8349) the fifth colliding ticket drops as today" "$cp_" "# drop HIMMEL-815 collision scripts/lib/cap.sh held by listed HIMMEL-811"

# a candidate that would join two series is dropped
newmir two
mk HIMMEL-821 "To Do" High '[]' '["v1.0.1"]' '[]' "x one" "Edit scripts/lib/x.sh now."
mk HIMMEL-822 "To Do" High '[]' '["v1.0.1"]' '[]' "x two" "Edit scripts/lib/x.sh now."
mk HIMMEL-823 "To Do" High '[]' '["v1.0.1"]' '[]' "y one" "Edit scripts/lib/y.sh now."
mk HIMMEL-824 "To Do" High '[]' '["v1.0.1"]' '[]' "y two" "Edit scripts/lib/y.sh now."
mk HIMMEL-825 "To Do" High '[]' '["v1.0.1"]' '[]' "both" "Edit scripts/lib/x.sh and scripts/lib/y.sh now."
tw="$(runs "$M" 1 --why)"
has "(8349) two independent series each get a row" "$tw" "SERIES${TAB}LOCAL${TAB}HIMMEL-821,HIMMEL-822${TAB}"
has "(8349) the second series row" "$tw" "SERIES${TAB}LOCAL${TAB}HIMMEL-823,HIMMEL-824${TAB}"
has "(8349) a candidate colliding with two series is dropped" "$tw" "# drop HIMMEL-825 collision"
lacks "(8349) a candidate colliding with two series joins neither" "$tw" "HIMMEL-821,HIMMEL-822,HIMMEL-825"

# a later-version ticket never rides an earlier version's series
newmir ver
mk HIMMEL-831 "To Do" High '[]' '["v1.0.1"]' '[]' "now" "Edit scripts/lib/z.sh now."
mk HIMMEL-832 "To Do" High '[]' '["v1.0.2"]' '[]' "later" "Edit scripts/lib/z.sh now."
vr="$(runs "$M" 1 --why)"
lacks "(8349) a later-version ticket does not join" "$vr" "SERIES"
lacks "(8349) a later-version ticket is not listed with it" "$vr" "HIMMEL-832${TAB}"
has "(8349) the earlier-version ticket lists alone" "$vr" "LOCAL${TAB}HIMMEL-831${TAB}"

# lane and hook: a CLOUD member makes the series LOCAL, a hook member makes it hook, a BLOCKED one never joins
newmir lane
mk HIMMEL-841 "To Do" High '[]' '["v1.0.1"]' '[]' "cloud head" "Edit scripts/lib/h.sh now."
mk HIMMEL-842 "To Do" High '[]' '["v1.0.1"]' '[]' "hook member" "Edit scripts/lib/h.sh now."
mk HIMMEL-843 "To Do" High '[]' '["v1.0.1"]' '[]' "local member" "Edit scripts/lib/h.sh now."
mk HIMMEL-845 "To Do" High '[]' '["v1.0.1"]' '[]' "blocked member" "Edit scripts/lib/h.sh now."
ln_="$(runs "$M" 1 --why)"
has "(8349) a CLOUD head with other members is a LOCAL series, hook when a member needs it" "$ln_" "SERIES${TAB}LOCAL${TAB}HIMMEL-841,HIMMEL-842,HIMMEL-843${TAB}High${TAB}v1.0.1${TAB}files=scripts/lib/h.sh${TAB}hook"
lacks "(8349) a BLOCKED ticket is never in a series" "$ln_" "HIMMEL-845,"
lacks "(8349) a BLOCKED ticket is not a member" "$ln_" ",HIMMEL-845"
has "(8349) a BLOCKED ticket drops on its classification" "$ln_" "# drop HIMMEL-845 classification BLOCKED"
nc_="$(runs "$M" 1 --no-classify)"
has "(8349) unclassified members keep the LOCAL? lane" "$nc_" "SERIES${TAB}LOCAL?${TAB}HIMMEL-841,HIMMEL-842,HIMMEL-843,HIMMEL-845${TAB}"

# a join widens the series' files: a ticket that only now collides with the series is offered the join too, with the list full
newmir late
mk HIMMEL-861 "To Do" High '[]' '["v1.0.1"]' '[]' "head on x" "Edit scripts/lib/x.sh now."
mk HIMMEL-862 "To Do" High '[]' '["v1.0.1"]' '[]' "on y only" "Edit scripts/lib/y.sh now."
mk HIMMEL-863 "To Do" High '[]' '["v1.0.1"]' '[]' "bridges x and y" "Edit scripts/lib/x.sh and scripts/lib/y.sh now."
lt="$(runs "$M" 1 --top 1)"
has "(8349) a join that widens the series lets a later ticket join it" "$lt" "SERIES${TAB}LOCAL${TAB}HIMMEL-861,HIMMEL-863,HIMMEL-862${TAB}"

# STACKABLE: a candidate colliding only with one live series worker's Writes
newmir stk
mk HIMMEL-851 "To Do" High '[]' '["v1.0.1"]' '[]' "wants app.js" "$APP"
mk HIMMEL-852 "To Do" High '[]' '["v1.0.1"]' '[]' "wants app.js and an open PR file" "Edit scripts/config-ui/app.js and scripts/lib/pr-held.sh."
mk HIMMEL-853 "To Do" High '[]' '["v1.0.1"]' '[]' "free ticket" "Edit scripts/lib/free-s.sh."
SM="$M"
mkdoc() { # <path> <series items> <extra Writes>: a live worker doc; items 0 = a plain (non-series) worker
    {
        printf '# live\n'
        if [ "$2" -gt 0 ]; then
            printf '> **Series:**\n'
            local k=1
            while [ "$k" -le "$2" ]; do printf '> %d. HIMMEL-79%d branch=feat/x-s%d base=main completes-ticket=no\n' "$k" "$k" "$k"; k=$((k + 1)); done
        fi
        printf '> **Writes:** scripts/config-ui/app.js %s\n' "$3"
    } > "$1"
}
mkfleet() { # <fleet file> <label:doc> ...
    local f="$1" first=1; shift
    printf '{"schema":1,"legs":[' > "$f"
    for p in "$@"; do [ "$first" = 1 ] || printf ',' >> "$f"; first=0; printf '{"doc":"%s","label":"%s"}' "${p#*:}" "${p%%:*}" >> "$f"; done
    printf ']}\n' >> "$f"
}
mkdoc "$WORK/HIMMEL-790-N5-series.md" 2 ""
mkfleet "$WORK/fleet-s.json" "N5:$WORK/HIMMEL-790-N5-series.md"
st="$(runs "$SM" 1 --workers-from "$WORK/fleet-s.json" --why)"
has "(8349) a candidate colliding only with a live series worker is STACKABLE" "$st" "STACKABLE HIMMEL-851 $WORK/HIMMEL-790-N5-series.md"
lacks "(8349) a STACKABLE candidate has no dispatch row" "$st" "LOCAL${TAB}HIMMEL-851${TAB}"
lacks "(8349) a STACKABLE candidate is not told as an ordinary collision" "$st" "# drop HIMMEL-851 collision"
has "(8349) a free ticket still lists beside a series worker" "$st" "LOCAL${TAB}HIMMEL-853${TAB}"
has "(8349) a candidate also held by an open PR still drops" "$st" "# drop HIMMEL-852 collision"
lacks "(8349) a candidate also held by an open PR is not STACKABLE" "$st" "STACKABLE HIMMEL-852"
stoff="$(runs "$SM" 0 --workers-from "$WORK/fleet-s.json" --why)"
lacks "(8349) flag off prints no STACKABLE row" "$stoff" "STACKABLE"
has "(8349) flag off drops it with the collision reason" "$stoff" "# drop HIMMEL-851 collision scripts/config-ui/app.js held by live worker N5"

# a candidate the classifier would call BLOCKED is not offered as STACKABLE
M="$SM"; mk HIMMEL-845 "To Do" High '[]' '["v1.0.1"]' '[]' "blocked wants app.js" "$APP"
sb="$(runs "$SM" 1 --workers-from "$WORK/fleet-s.json" --why)"
lacks "(8349) a BLOCKED candidate is not offered as STACKABLE" "$sb" "STACKABLE HIMMEL-845"
has "(8349) a BLOCKED candidate drops on its classification" "$sb" "# drop HIMMEL-845 classification BLOCKED"
has "(8349) the classifiable candidate is still offered" "$sb" "STACKABLE HIMMEL-851 $WORK/HIMMEL-790-N5-series.md"

# a Series block that names no item has an unknown count: it offers no room, and --resume-only lists no STACKABLE row
printf '# live\n> **Series:**\n> **Writes:** scripts/config-ui/app.js\n' > "$WORK/HIMMEL-794-N9-empty.md"
mkfleet "$WORK/fleet-empty.json" "N9:$WORK/HIMMEL-794-N9-empty.md"
se="$(runs "$SM" 1 --workers-from "$WORK/fleet-empty.json" --why)"
lacks "(8349) a Series block with no parseable item offers no STACKABLE room" "$se" "STACKABLE"
has "(8349) an unreadable-count series worker still holds the file" "$se" "# drop HIMMEL-851 collision scripts/config-ui/app.js held by live worker N9"
sr="$(runs "$SM" 1 --workers-from "$WORK/fleet-s.json" --priority-pool-only --resume-only)"
lacks "(8349) --priority-pool-only --resume-only lists no STACKABLE row" "$sr" "STACKABLE"

mkdoc "$WORK/HIMMEL-791-N6-plain.md" 0 ""
mkfleet "$WORK/fleet-plain.json" "N6:$WORK/HIMMEL-791-N6-plain.md"
sp="$(runs "$SM" 1 --workers-from "$WORK/fleet-plain.json" --why)"
lacks "(8349) a collision with a non-series live worker is not STACKABLE" "$sp" "STACKABLE"
has "(8349) a collision with a non-series live worker still drops" "$sp" "# drop HIMMEL-851 collision scripts/config-ui/app.js held by live worker N6"

mkdoc "$WORK/HIMMEL-792-N7-full.md" 4 ""
mkfleet "$WORK/fleet-full.json" "N7:$WORK/HIMMEL-792-N7-full.md"
sf="$(runs "$SM" 1 --workers-from "$WORK/fleet-full.json" --why)"
lacks "(8349) a full (4/4) series worker takes no STACKABLE" "$sf" "STACKABLE"
has "(8349) a full series worker still holds the file" "$sf" "# drop HIMMEL-851 collision scripts/config-ui/app.js held by live worker N7"

mkdoc "$WORK/HIMMEL-793-N8-two.md" 0 ""
mkfleet "$WORK/fleet-two.json" "N5:$WORK/HIMMEL-790-N5-series.md" "N8:$WORK/HIMMEL-793-N8-two.md"
s2="$(runs "$SM" 1 --workers-from "$WORK/fleet-two.json" --why)"
lacks "(8349) a collision with a series worker and another worker is not STACKABLE" "$s2" "STACKABLE"

# (8436) two chiefs on one chain: B's dispatcher sees the workers chief A armed after `next` copied the manifest
M8="$WORK/m8436/HIMMEL"; mkdir -p "$M8" "$WORK/chain8436" "$WORK/other8436"
M_SAVE="$M"; M="$M8"
mk HIMMEL-53 "In Progress" High '[]' '["v1.0.1"]' '[]' "started by chief A's worker" "Edit scripts/lib/r4.sh only."
mk HIMMEL-56 "To Do" Highest '[]' '["v1.0.1"]' '[]' "armed by chief A, not started" "Edit scripts/lib/r7.sh only."
mk HIMMEL-57 "To Do" High '[]' '["v1.0.1"]' '[]' "free of any worker" "Edit scripts/lib/r8.sh only."
M="$M_SAVE"
C8="$WORK/chain8436"
W53="$C8/HIMMEL-53-N9-started-2026-10-31.md"; W56="$C8/HIMMEL-56-N10-armed-2026-10-31.md"
printf '# live\n> **Writes:** scripts/lib/r4.sh\n- 10:00 LIVE - started\n' > "$W53"
printf '# live\n> **Writes:** scripts/lib/r7.sh\n' > "$W56"
mkfleet "$C8/HIMMEL-nextleg-2026-10-31MA-roadmap-chief.fleet.json" "N9:$W53" "N10:$W56"
mkfleet "$C8/HIMMEL-nextleg-2026-10-31MB-roadmap-chief.fleet.json"
run8() { # <manifest> args...: next-dispatchable on the (8436) mirror, unclassified
    local man="$1"; shift
    NEXT_DISPATCH_MIRROR="$M8" NEXT_DISPATCH_GH_CMD="$WORK/gh" bash "$SUT" --no-classify --workers-from "$man" "$@" 2>/dev/null
}
a8r="$(run8 "$C8/HIMMEL-nextleg-2026-10-31MA-roadmap-chief.fleet.json" --resume-only)"
b8r="$(run8 "$C8/HIMMEL-nextleg-2026-10-31MB-roadmap-chief.fleet.json" --resume-only)"
a8f="$(run8 "$C8/HIMMEL-nextleg-2026-10-31MA-roadmap-chief.fleet.json" --top 20)"
b8f="$(run8 "$C8/HIMMEL-nextleg-2026-10-31MB-roadmap-chief.fleet.json" --top 20)"
lacks "(8436) the arming chief is not offered its own worker's In Progress ticket" "$a8r" "RESUME${TAB}HIMMEL-53${TAB}"
lacks "(8436) the other chief on the chain is not offered RESUME for a ticket a chief-A worker holds" "$b8r" "RESUME${TAB}HIMMEL-53${TAB}"
lacks "(8436) the arming chief is not offered the To Do ticket it armed" "$a8f" "${TAB}HIMMEL-56${TAB}"
lacks "(8436) the other chief on the chain is not offered a To Do ticket a chief-A worker holds" "$b8f" "${TAB}HIMMEL-56${TAB}"
has "(8436) the other chief is still offered a ticket no worker holds" "$b8f" "${TAB}HIMMEL-57${TAB}"
# a wrapped worker of the other chief frees its ticket
printf '# live\n> **Writes:** scripts/lib/r7.sh\n- 10:30 WRAPPED - done\n' > "$W56"
b8w="$(run8 "$C8/HIMMEL-nextleg-2026-10-31MB-roadmap-chief.fleet.json" --top 20)"
has "(8436) a WRAPPED worker of the other chief no longer holds its ticket" "$b8w" "${TAB}HIMMEL-56${TAB}"
lacks "(8436) a still-live worker of the other chief keeps holding its ticket" "$b8w" "${TAB}HIMMEL-53${TAB}"
# a manifest of another chain in the same bucket owns nothing here
mkfleet "$C8/HIMMEL-nextleg-2026-10-31MA-other-chief.fleet.json" "N11:$C8/HIMMEL-57-N11-elsewhere-2026-10-31.md"
printf '# live\n' > "$C8/HIMMEL-57-N11-elsewhere-2026-10-31.md"
b8o="$(run8 "$C8/HIMMEL-nextleg-2026-10-31MB-roadmap-chief.fleet.json" --top 20)"
has "(8436) a worker of a different chain does not hold its ticket here" "$b8o" "${TAB}HIMMEL-57${TAB}"
# a stale worker doc of the other chief (no write for a day) holds nothing
ago "$W53" 48
b8s="$(run8 "$C8/HIMMEL-nextleg-2026-10-31MB-roadmap-chief.fleet.json" --top 20 --resume-only)"
has "(8436) a worker doc untouched for over a day no longer holds its ticket" "$b8s" "RESUME${TAB}HIMMEL-53${TAB}"
# malformed sibling manifests never break the read: a list, entries that are not objects, a null or numeric doc, a doc-less entry
touch "$W53"
printf '[]\n' > "$C8/HIMMEL-nextleg-2026-10-31MC-roadmap-chief.fleet.json"
printf '{"schema":1,"workers":["N1",{"doc":null,"label":"N2"},{"doc":5,"label":"N3"},{"label":"N4"}]}\n' > "$C8/HIMMEL-nextleg-2026-10-31MD-roadmap-chief.fleet.json"
printf '{"schema":1,"workers":{"doc":"x"}}\n' > "$C8/HIMMEL-nextleg-2026-10-31ME-roadmap-chief.fleet.json"
b8m="$(run8 "$C8/HIMMEL-nextleg-2026-10-31MB-roadmap-chief.fleet.json" --top 20)"
has "(8436) malformed sibling manifests do not stop the list" "$b8m" "${TAB}HIMMEL-57${TAB}"
lacks "(8436) a good sibling still holds its ticket beside malformed ones" "$b8m" "RESUME${TAB}HIMMEL-53${TAB}"
b8a="$(NEXT_DISPATCH_SIBLING_MAX_AGE_MIN=abc run8 "$C8/HIMMEL-nextleg-2026-10-31MB-roadmap-chief.fleet.json" --top 20)"
has "(8436) a non-integer sibling age window does not stop the list" "$b8a" "${TAB}HIMMEL-57${TAB}"
lacks "(8436) a non-integer sibling age window reads as the default" "$b8a" "RESUME${TAB}HIMMEL-53${TAB}"

# --- (8349 S1b) the series ledger is a holder, and an abandoned series is flagged SERIES-ORPHAN ---
# ledgers are written by the real series-ledger.py; the bucket is the directory of the --workers-from manifest
export GHL_DIR="$WORK/ghl"; mkdir -p "$GHL_DIR"
cat > "$WORK/gh-l" <<'EOF'
#!/usr/bin/env bash
# no open PRs; `pr list --head <branch> --state all` answers from $GHL_DIR/<branch with / as _>: one PR state per line
prev=""; lim=30; br=""   # gh pr list shows 30 results unless --limit says more
for a in "$@"; do
    [ "$prev" = --limit ] && lim="$a"
    [ "$prev" = --head ] && br="$a"
    prev="$a"
done
if [ -n "$br" ]; then f="$GHL_DIR/${br//\//_}"; [ -f "$f" ] && head -n "$lim" "$f"; fi
exit 0
EOF
chmod +x "$WORK/gh-l"
runl() { # <flag> <mirror> <manifest> args...
    local flag="$1" mir="$2" man="$3"; shift 3
    HIMMEL_FLAG_STACKED_SERIES="$flag" NEXT_DISPATCH_MIRROR="$mir" NEXT_DISPATCH_GH_CMD="$WORK/gh-l" NEXT_DISPATCH_CLASSIFY_CMD="$WORK/classify-s" bash "$SUT" --workers-from "$man" "$@" 2>/dev/null
}
led() { python3 -I "$HERE/series-ledger.py" "$@" > /dev/null; }
backdate() { # <ledger> <hours>: every passes[].at moves that far into the past
    python3 -I -c 'import datetime, json, sys
p = sys.argv[1]
d = json.load(open(p))
t = (datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(hours=float(sys.argv[2]))).strftime("%Y-%m-%dT%H:%M:%SZ")
for x in d["passes"]:
    x["at"] = t
json.dump(d, open(p, "w"))' "$1" "$2"
}
newbucket() { B="$WORK/b-$1"; mkdir -p "$B/series"; }

newmir lg
mk HIMMEL-871 "To Do" High '[]' '["v1.0.1"]' '[]' "wants app.js, held by the ledger" "$APP"
mk HIMMEL-872 "To Do" High '[]' '["v1.0.1"]' '[]' "free ticket" "Edit scripts/lib/free-l.sh."
mk HIMMEL-873 "To Do" High '[]' '["v1.0.1"]' '[]' "wants a file whose PR merged" "Edit scripts/lib/rel-l.sh."
mk HIMMEL-874 "To Do" High '[]' '["v1.0.1"]' '[]' "wants a file whose PR is open" "Edit scripts/lib/open-l.sh."
mk HIMMEL-875 "To Do" High '[]' '["v1.0.1"]' '[]' "wants a file gh knows no PR for" "Edit scripts/lib/nopr-l.sh."
mk HIMMEL-876 "To Do" High '[]' '["v1.0.1"]' '[]' "wants an abandoned item's file" "Edit scripts/lib/aband-l.sh."
mk HIMMEL-877 "To Do" High '[]' '["v1.0.1"]' '[]' "wants a file whose PR closed" "Edit scripts/lib/closed-l.sh."
mk HIMMEL-878 "To Do" High '[]' '["v1.0.1"]' '[]' "wants a file whose branch has 31 PRs, the 31st open" "Edit scripts/lib/many-l.sh."
LM="$M"
newbucket lg
PRED="$B/HIMMEL-9000-N1-pred.md"; SUCC="$B/HIMMEL-9000-N2-succ-RESUME.md"
printf '# pred\n> **Writes:** scripts/config-ui/app.js\n- 09:00 LIVE - started\n- 09:50 WRAPPED - handed off\n' > "$PRED"
printf '# resume\n' > "$SUCC"
mkfleet "$B/fleet.json" "N1:$PRED"
SER="$B/series/s1.json"
led create --ledger "$SER" --sid s1 --completes-ticket no --writer "$PRED"
led add-item --ledger "$SER" --key HIMMEL-9001 --writes scripts/config-ui/app.js --state committed
led add-item --ledger "$SER" --key HIMMEL-9002 --writes scripts/lib/rel-l.sh --state published --publish-branch series/s1/HIMMEL-9002
led add-item --ledger "$SER" --key HIMMEL-9003 --writes scripts/lib/open-l.sh --state published --publish-branch series/s1/HIMMEL-9003
led add-item --ledger "$SER" --key HIMMEL-9004 --writes scripts/lib/nopr-l.sh --state published --publish-branch series/s1/HIMMEL-9004
led add-item --ledger "$SER" --key HIMMEL-9005 --writes scripts/lib/aband-l.sh --state abandoned
led add-item --ledger "$SER" --key HIMMEL-9006 --writes scripts/lib/closed-l.sh --state published --publish-branch series/s1/HIMMEL-9006
led add-item --ledger "$SER" --key HIMMEL-9007 --writes scripts/lib/many-l.sh --state published --publish-branch series/s1/HIMMEL-9007
led pass --ledger "$SER" --from "$PRED" --to "$SUCC"
{ n=0; while [ "$n" -lt 30 ]; do echo MERGED; n=$((n + 1)); done; echo OPEN; } > "$GHL_DIR/series_s1_HIMMEL-9007"
printf 'MERGED\n' > "$GHL_DIR/series_s1_HIMMEL-9002"
printf 'OPEN\n' > "$GHL_DIR/series_s1_HIMMEL-9003"
printf 'CLOSED\n' > "$GHL_DIR/series_s1_HIMMEL-9006"
lg1="$(runl 1 "$LM" "$B/fleet.json" --why)"
has "(8349 S1b) F3: a committed item holds its file after the predecessor WRAPPED" "$lg1" "# drop HIMMEL-871 collision scripts/config-ui/app.js held by series s1"
lacks "(8349 S1b) F3: the held candidate has no dispatch row" "$lg1" "LOCAL${TAB}HIMMEL-871${TAB}"
has "(8349 S1b) a ticket the ledger does not hold still lists" "$lg1" "LOCAL${TAB}HIMMEL-872${TAB}"
has "(8349 S1b) F4 hold-end: a published item whose PR gh reports merged holds nothing" "$lg1" "LOCAL${TAB}HIMMEL-873${TAB}"
has "(8349 S1b) a published item whose PR is open keeps holding" "$lg1" "# drop HIMMEL-874 collision scripts/lib/open-l.sh held by series s1"
has "(8349 S1b) a published item gh knows no PR for keeps holding" "$lg1" "# drop HIMMEL-875 collision scripts/lib/nopr-l.sh held by series s1"
has "(8349 S1b) an abandoned item holds nothing" "$lg1" "LOCAL${TAB}HIMMEL-876${TAB}"
has "(8349 S1b) a published item whose PR gh reports closed holds nothing" "$lg1" "LOCAL${TAB}HIMMEL-877${TAB}"
has "(8349 S1b) a PR beyond gh's default 30 results still holds the file" "$lg1" "# drop HIMMEL-878 collision scripts/lib/many-l.sh held by series s1"
lacks "(8349 S1b) a fresh pass is no orphan" "$lg1" "SERIES-ORPHAN"
# flag off: a ledger present changes nothing (byte-identical to the same run with no ledger directory)
off1="$(runl 0 "$LM" "$B/fleet.json" --why | grep -v '^# source mirror_age_min=')"
mv "$B/series" "$B/series.off"
off2="$(runl 0 "$LM" "$B/fleet.json" --why | grep -v '^# source mirror_age_min=')"
mv "$B/series.off" "$B/series"
[ "$off1" = "$off2" ] && pass "(8349 S1b) flag off: a ledger present gives output byte-identical to no ledger" || fail "(8349 S1b) flag off output differs with a ledger present"
has "(8349 S1b) flag off lists the ledger-held ticket as before" "$off1" "LOCAL${TAB}HIMMEL-871${TAB}"

# SERIES-ORPHAN: the writer doc has no LIVE marker and no manifest entry, 2 h after the newest pass (or the ledger's last write)
mkorph() { # <name> <doc body> <in manifest 0|1> <pass|create> <hours ago>
    newbucket "$1"; WDOC="$B/HIMMEL-9100-N3-$1-RESUME.md"
    printf '# resume\n> **Writes:** none named\n%s' "$2" > "$WDOC"
    if [ "$3" = 1 ]; then mkfleet "$B/fleet.json" "N3:$WDOC"; else mkfleet "$B/fleet.json"; fi
    SER="$B/series/o-$1.json"
    if [ "$4" = pass ]; then
        led create --ledger "$SER" --sid "o-$1" --completes-ticket no --writer "$B/prev.md"
        led pass --ledger "$SER" --from "$B/prev.md" --to "$WDOC"
        backdate "$SER" "$5"
    else
        led create --ledger "$SER" --sid "o-$1" --completes-ticket no --writer "$WDOC"
        ago "$SER" "$5"
    fi
}
mkorph o1 "" 0 pass 3
o1="$(runl 1 "$LM" "$B/fleet.json")"
has "(8349 S1b) F4: a RESUME writer with no marker and no manifest entry 3 h after the pass is an orphan" "$o1" "SERIES-ORPHAN o-o1 $WDOC"
o1off="$(runl 0 "$LM" "$B/fleet.json")"
lacks "(8349 S1b) flag off prints no SERIES-ORPHAN" "$o1off" "SERIES-ORPHAN"
mkorph o2 "- 10:00 LIVE - started
" 0 pass 3
o2="$(runl 1 "$LM" "$B/fleet.json")"
lacks "(8349 S1b) F4: a writer doc with a LIVE marker is no orphan" "$o2" "SERIES-ORPHAN"
mkorph o3 "" 1 pass 3
o3="$(runl 1 "$LM" "$B/fleet.json")"
lacks "(8349 S1b) F4: a writer doc the manifest lists is no orphan" "$o3" "SERIES-ORPHAN"
mkorph o4 "" 0 pass 1
o4="$(runl 1 "$LM" "$B/fleet.json")"
lacks "(8349 S1b) a pass 1 h ago is inside the 2 h window" "$o4" "SERIES-ORPHAN"
mkorph o5 "" 0 create 3
o5="$(runl 1 "$LM" "$B/fleet.json")"
has "(8349 S1b) a series with no pass counts from the ledger's last write" "$o5" "SERIES-ORPHAN o-o5 $WDOC"
mkorph o6 "" 0 create 0
o6="$(runl 1 "$LM" "$B/fleet.json")"
lacks "(8349 S1b) a freshly created ledger is no orphan" "$o6" "SERIES-ORPHAN"
# an unreadable ledger could hide a hold: the fleet reads as unknown, never as clear
newbucket bad; printf 'not json\n' > "$B/series/bad.json"; mkfleet "$B/fleet.json"
bad="$(runl 1 "$LM" "$B/fleet.json")"
has "(8349 S1b) an unreadable ledger marks the live workers unknown" "$bad" "live workers unknown"
# a missing series directory is no series; one that cannot be listed could be hiding every hold
newbucket nodir; rmdir "$B/series"; mkfleet "$B/fleet.json"
nodir="$(runl 1 "$LM" "$B/fleet.json")"
lacks "(8349 S1b) a bucket with no series directory is not unknown" "$nodir" "live workers unknown"
newbucket perm; mkfleet "$B/fleet.json"; chmod 000 "$B/series"
if [ "$(id -u)" -eq 0 ]; then
    pass "(8349 S1b) an unlistable series directory marks the live workers unknown (skipped: root lists it anyway)"
else
    perm="$(runl 1 "$LM" "$B/fleet.json")"
    has "(8349 S1b) an unlistable series directory marks the live workers unknown" "$perm" "live workers unknown"
fi
chmod 755 "$B/series"

# --- (8529) a series worker is read from the `> **Series:** <sid> <ledger path>` line S2a writes, its own ledger is not a second holder,
# the offered row is `STACKABLE <KEY> <writer doc>`, and sub-tasks of one parent in one directory family give a SERIES FAMILY row ---
newmir s85
mk HIMMEL-851 "To Do" High '[]' '["v1.0.1"]' '[]' "wants app.js" "$APP"
mk HIMMEL-854 "To Do" High '[]' '["v1.0.1"]' '[]' "wants a file only the ledger holds" "Edit scripts/lib/led-only-85.sh."
mk HIMMEL-853 "To Do" High '[]' '["v1.0.1"]' '[]' "free ticket" "Edit scripts/lib/free-85.sh."
S85="$M"
newbucket s85
SW="$B/HIMMEL-9200-N1-series.md"
SL="$B/series/s85.json"
printf '# live\n> **Series:** s85 %s — read docs/handover/worker-sections/series.md\n> **Writes:** scripts/config-ui/app.js\n- 09:00 LIVE - started\n' "$SL" > "$SW"
mkfleet "$B/fleet.json" "N1:$SW"
led create --ledger "$SL" --sid s85 --completes-ticket no --writer "$SW"
led add-item --ledger "$SL" --key HIMMEL-9201 --writes scripts/config-ui/app.js --state committed
led add-item --ledger "$SL" --key HIMMEL-9202 --writes scripts/lib/led-only-85.sh --state authoring
s85a="$(runl 1 "$S85" "$B/fleet.json" --why)"
has "(8529) a series worker's Series line plus its ledger gives STACKABLE <KEY> <writer doc>" "$s85a" "STACKABLE HIMMEL-851 $SW"
lacks "(8529) the stackable candidate has no dispatch row" "$s85a" "LOCAL${TAB}HIMMEL-851${TAB}"
lacks "(8529) the stackable candidate is not an ordinary collision" "$s85a" "# drop HIMMEL-851 collision"
has "(8529) a file only the series ledger holds is stackable on its writer" "$s85a" "STACKABLE HIMMEL-854 $SW"
has "(8529) a free ticket still lists beside the series worker" "$s85a" "LOCAL${TAB}HIMMEL-853${TAB}"
s85off="$(runl 0 "$S85" "$B/fleet.json" --why)"
lacks "(8529) flag off prints no STACKABLE for a new-format series worker" "$s85off" "STACKABLE"
# the room comes from the ledger: 4 live items are full, an abandoned item is no seat
led add-item --ledger "$SL" --key HIMMEL-9203 --writes scripts/lib/c85.sh --state planned
led add-item --ledger "$SL" --key HIMMEL-9204 --writes scripts/lib/d85.sh --state planned
s85c="$(runl 1 "$S85" "$B/fleet.json" --why)"
lacks "(8529) a ledger of 4 live items takes no STACKABLE" "$s85c" "STACKABLE"
has "(8529) a full series still holds the file" "$s85c" "# drop HIMMEL-851 collision"
led set --ledger "$SL" --key HIMMEL-9204 state=abandoned
s85d="$(runl 1 "$S85" "$B/fleet.json" --why)"
has "(8529) an abandoned item frees a seat" "$s85d" "STACKABLE HIMMEL-851 $SW"
# a Series line whose ledger is not there has an unknown count: no room
printf '# live\n> **Series:** gone %s/gone.json — read docs/handover/worker-sections/series.md\n> **Writes:** scripts/config-ui/app.js\n' "$B/series" > "$B/HIMMEL-9220-N3-noledger.md"
mkfleet "$B/fleet-nl.json" "N3:$B/HIMMEL-9220-N3-noledger.md"
s85e="$(runl 1 "$S85" "$B/fleet-nl.json" --why)"
lacks "(8529) a Series line with no ledger offers no STACKABLE room" "$s85e" "STACKABLE"
# a second live worker on the same file keeps the drop
mkdoc "$B/HIMMEL-9230-N4-plain.md" 0 ""
mkfleet "$B/fleet-two.json" "N1:$SW" "N4:$B/HIMMEL-9230-N4-plain.md"
s85f="$(runl 1 "$S85" "$B/fleet-two.json" --why)"
lacks "(8529) a series worker plus a second worker on the file is not STACKABLE" "$s85f" "STACKABLE HIMMEL-851"

# the older numbered block names no sid: the ledger whose writer is the worker's doc is still its own
newbucket old85
mkdoc "$B/HIMMEL-9210-N2-old.md" 2 ""
mkfleet "$B/fleet-old.json" "N2:$B/HIMMEL-9210-N2-old.md"
SL2="$B/series/old.json"
led create --ledger "$SL2" --sid old --completes-ticket no --writer "$B/HIMMEL-9210-N2-old.md"
led add-item --ledger "$SL2" --key HIMMEL-9211 --writes scripts/config-ui/app.js --state committed
s85b="$(runl 1 "$S85" "$B/fleet-old.json" --why)"
has "(8529) a numbered-block series worker whose ledger names it as writer is one holder" "$s85b" "STACKABLE HIMMEL-851 $B/HIMMEL-9210-N2-old.md"

# SERIES FAMILY: To Do sub-tasks of one parent whose files all sit in one directory family (first two path components)
newmir fam
reparent() { sed "s/^parent: null/parent: \"$2\"/" "$1" > "$1.tmp" && mv "$1.tmp" "$1"; }
mk HIMMEL-870 "To Do" High '[]' '["v1.0.1"]' '[]' "a sub-task in docs/handover" "Edit docs/handover/fa-85.md."
mk HIMMEL-871 "To Do" High '[]' '["v1.0.1"]' '[]' "another sub-task in docs/handover" "Edit docs/handover/sub/fb-85.md."
mk HIMMEL-872 "To Do" High '[]' '["v1.0.1"]' '[]' "a sub-task of another parent in docs/handover" "Edit docs/handover/fc-85.md."
mk HIMMEL-873 "To Do" High '[]' '["v1.0.1"]' '[]' "a lone sub-task of a third parent" "Edit scripts/lib/fd-85.sh."
mk HIMMEL-874 "To Do" High '[]' '["v1.0.1"]' '[]' "a sub-task of the first parent in another family" "Edit scripts/lib/fe-85.sh."
mk HIMMEL-875 "To Do" High '[]' '["v1.0.1"]' '[]' "a sub-task of the first parent spanning two families" "Edit docs/handover/ff-85.md and scripts/lib/ff-85.sh."
for k in 870 871 872 873 874 875; do retype "$M/HIMMEL-$k.md" "Sub-task"; done
reparent "$M/HIMMEL-870.md" HIMMEL-860; reparent "$M/HIMMEL-871.md" HIMMEL-860; reparent "$M/HIMMEL-875.md" HIMMEL-860
reparent "$M/HIMMEL-872.md" HIMMEL-861; reparent "$M/HIMMEL-873.md" HIMMEL-862; reparent "$M/HIMMEL-874.md" HIMMEL-860
FAM="$M"
newbucket fam; mkfleet "$B/fleet.json"
fam1="$(runl 1 "$FAM" "$B/fleet.json")"
has "(8529) sub-tasks of one parent in one directory family give a SERIES FAMILY row" "$fam1" "SERIES FAMILY docs/handover HIMMEL-870,HIMMEL-871"
lacks "(8529) a sub-task of another parent is not in the family row" "$fam1" "HIMMEL-872"
lacks "(8529) a lone sub-task of its parent gives no family row" "$fam1" "SERIES FAMILY scripts/lib"
lacks "(8529) a sub-task spanning two families is in no family row" "$fam1" "HIMMEL-875"
fam0="$(runl 0 "$FAM" "$B/fleet.json")"
lacks "(8529) flag off prints no SERIES FAMILY row" "$fam0" "SERIES FAMILY"
# a sub-task whose file a live worker holds is not offered
printf '# live\n> **Writes:** docs/handover/fa-85.md\n' > "$B/HIMMEL-9240-N5-holder.md"
mkfleet "$B/fleet-h.json" "N5:$B/HIMMEL-9240-N5-holder.md"
fam2="$(runl 1 "$FAM" "$B/fleet-h.json")"
lacks "(8529) a sub-task held by a live worker gives no family row" "$fam2" "SERIES FAMILY"

# A ticket with a merged contract=no PR is in work, never a fresh To Do row: its RESUME row names the PR and the
# PR body's Remaining: text; a partial PR whose body has none is NEEDS-CHIEF-NOTE and is not dispatched.
PM_STATE="$WORK/pm"; mkdir -p "$PM_STATE/workers"
export PR_BODY_DIR="$WORK/prbody"; mkdir -p "$PR_BODY_DIR"
printf 'Slice one.\n\nRemaining: slice two and the {brace} reader\n' > "$PR_BODY_DIR/5001"
printf 'Slice one, no tail.\n' > "$PR_BODY_DIR/5002"
printf 'Remaining: the other half\n' > "$PR_BODY_DIR/5003"
printf 'Remaining:\n\nAn unrelated section follows.\n' > "$PR_BODY_DIR/5004"
MPM="$WORK/mpm/HIMMEL"; mkdir -p "$MPM"
M_SAVE="$M"; M="$MPM"
mk HIMMEL-80 "In Progress" Medium '[]' '[]' '[]' "partial with a remaining line" "Edit scripts/lib/pm1.sh."
mk HIMMEL-81 "In Progress" Medium '[]' '[]' '[]' "partial without a remaining line" "Edit scripts/lib/pm2.sh."
mk HIMMEL-82 "To Do" Medium '[]' '[]' '[]' "demoted to To Do after a partial merge" "Edit scripts/lib/pm3.sh."
mk HIMMEL-83 "To Do" Medium '[]' '[]' '[]' "plain to do" "Edit scripts/lib/pm4.sh."
mk HIMMEL-84 "In Progress" Medium '[]' '[]' '[]' "partial with an empty remaining line" "Edit scripts/lib/pm5.sh."
mk HIMMEL-85 "In Progress" Medium '[]' '[]' '[]' "partial whose PR body gh cannot read" "Edit scripts/lib/pm6.sh."
M="$M_SAVE"
cat > "$PM_STATE/status-events.jsonl" <<'EOF'
{"ts":"t","event":"merge","key":"HIMMEL-80","pr":"5001","contract":"no","result":"noop"}
{"ts":"t","event":"derive","key":"HIMMEL-80","pr":"5001","result":"moved","rule":"D3"}
{"ts":"t","event":"merge","key":"HIMMEL-81","pr":"5002","contract":"no","result":"noop"}
{"ts":"t","event":"merge","key":"HIMMEL-82","pr":"5003","contract":"no","result":"noop"}
{"ts":"t","event":"merge","key":"HIMMEL-84","pr":"5004","contract":"no","result":"noop"}
{"ts":"t","event":"merge","key":"HIMMEL-85","pr":"5005","contract":"no","result":"noop"}
EOF
pm="$(NEXT_DISPATCH_MIRROR="$MPM" NEXT_DISPATCH_GH_CMD="$WORK/gh" NEXT_DISPATCH_CLASSIFY_CMD="$WORK/classify" bash "$SUT" --workers-dir "$PM_STATE/workers" --workers-from "$WORK/fleet5.json" 2>/dev/null)"
has "a partial merge with a Remaining: line is a RESUME row" "$pm" "RESUME	HIMMEL-80"
has "its RESUME row names the merged PR and the Remaining: text" "$(printf '%s\n' "$pm" | grep 'HIMMEL-80	')" "partial=PR #5001 merged, Remaining: slice two and the {brace} reader"
has "a partial merge without a Remaining: line is flagged as needing a chief note" "$pm" "NEEDS-CHIEF-NOTE HIMMEL-81: merged PR #5002 has no Remaining: line, needs a chief note"
lacks "a partial merge without a Remaining: line is not dispatchable" "$pm" "	HIMMEL-81	"
has "a To Do ticket with a merged partial PR is a RESUME row" "$pm" "RESUME	HIMMEL-82"
has "and its RESUME row carries the PR's Remaining: text" "$(printf '%s\n' "$pm" | grep 'HIMMEL-82	')" "Remaining: the other half"
lacks "a To Do ticket with a merged partial PR is never an ordinary row" "$pm" "LOCAL	HIMMEL-82"
has "a plain To Do ticket is still an ordinary row" "$pm" "LOCAL	HIMMEL-83"
mkdir -p "$WORK/pm-bad/workers" "$WORK/pm-bad/status-events.jsonl"
pmb="$(NEXT_DISPATCH_MIRROR="$MPM" NEXT_DISPATCH_GH_CMD="$WORK/gh" NEXT_DISPATCH_CLASSIFY_CMD="$WORK/classify" bash "$SUT" --workers-dir "$WORK/pm-bad/workers" --workers-from "$WORK/fleet5.json" 2>/dev/null)"
has "an unreadable status log is warned about, not silently read as empty" "$pmb" "# warn: $WORK/pm-bad/status-events.jsonl is unreadable"
has "an empty Remaining: line does not borrow the next line's text" "$pm" "NEEDS-CHIEF-NOTE HIMMEL-84"
lacks "an empty Remaining: line is not a RESUME row" "$pm" "RESUME	HIMMEL-84"
has "a PR body gh cannot read is reported as unreadable, not as missing a Remaining: line" "$pm" "NEEDS-CHIEF-NOTE HIMMEL-85: merged PR #5005 body could not be read (gh failed)"

# The LATEST contract-bearing merge row of a key decides: a contract=yes row followed by a newer contract=no merge is a
# partial again (RESUME), a contract=no row followed by a contract=yes row is done-pending.
mkdir -p "$WORK/pm2/workers"
printf 'Remaining: the late slice\n' > "$PR_BODY_DIR/5007"
M="$MPM"
mk HIMMEL-86 "To Do" Medium '[]' '[]' '[]' "yes then a newer partial merge" "Edit scripts/lib/pm7.sh."
mk HIMMEL-87 "To Do" Medium '[]' '[]' '[]' "partial then a newer completing merge" "Edit scripts/lib/pm8.sh."
mk HIMMEL-89 "To Do" Medium '[]' '[]' '[]' "partial, completed, then a new partial" "Edit scripts/lib/pm10.sh."
M="$M_SAVE"
printf 'Remaining: the old half\n' > "$PR_BODY_DIR/5010"
printf 'Remaining: the new half\n' > "$PR_BODY_DIR/5012"
cat > "$WORK/pm2/status-events.jsonl" <<'EOF'
{"ts":"t","event":"merge","key":"HIMMEL-86","pr":"5006","contract":"yes","result":"ok"}
{"ts":"t","event":"merge","key":"HIMMEL-86","pr":"5007","contract":"no","result":"noop"}
{"ts":"t","event":"merge","key":"HIMMEL-87","pr":"5008","contract":"no","result":"noop"}
{"ts":"t","event":"merge","key":"HIMMEL-87","pr":"5009","contract":"yes","result":"ok"}
{"ts":"t","event":"merge","key":"HIMMEL-89","pr":"5010","contract":"no","result":"noop"}
{"ts":"t","event":"merge","key":"HIMMEL-89","pr":"5011","contract":"yes","result":"ok"}
{"ts":"t","event":"merge","key":"HIMMEL-89","pr":"5012","contract":"no","result":"noop"}
EOF
pm2="$(NEXT_DISPATCH_MIRROR="$MPM" NEXT_DISPATCH_GH_CMD="$WORK/gh" NEXT_DISPATCH_CLASSIFY_CMD="$WORK/classify" bash "$SUT" --workers-dir "$WORK/pm2/workers" --workers-from "$WORK/fleet5.json" 2>/dev/null)"
has "a newer contract=no merge after a contract=yes row is a RESUME row" "$pm2" "RESUME	HIMMEL-86"
has "and its RESUME row names the newer partial PR's Remaining: text" "$(printf '%s\n' "$pm2" | grep 'HIMMEL-86	')" "Remaining: the late slice"
lacks "a contract=yes row after a partial merge is done-pending, not a RESUME row" "$pm2" "RESUME	HIMMEL-87"
lacks "and it is not an ordinary row either" "$pm2" "LOCAL	HIMMEL-87"
has "a partial after a completing merge is a RESUME row naming only the new partial" "$(printf '%s\n' "$pm2" | grep 'HIMMEL-89	')" "Remaining: the new half"
lacks "and a partial PR a later contract=yes row completed is not named" "$(printf '%s\n' "$pm2" | grep 'HIMMEL-89	')" "the old half"

# An unreadable status log withholds only a To Do candidate whose key already has a merge on the main ref (git log grep
# "[KEY]"), prints one WARN naming them, and keeps every other candidate.
PMG="$WORK/pm-git"; mkdir -p "$PMG"
M="$MPM"
mk HIMMEL-88 "To Do" Medium '[]' '[]' '[]' "only a lookalike key on main" "Edit scripts/lib/pm9.sh."
M="$M_SAVE"
{ git -C "$PMG" init -q -b main && git -C "$PMG" -c user.name=t -c user.email=t@t commit -q --allow-empty -m "fix(x): [HIMMEL-83] a merged slice" \
    && git -C "$PMG" -c user.name=t -c user.email=t@t commit -q --allow-empty -m "fix(x): [HIMMEL-880] a lookalike key"; } \
    || { fail "the main-ref fixture repo could not be created"; printf '\n%d failure(s)\n' "$fails"; exit 1; }
pmg="$(NEXT_DISPATCH_GIT_DIR="$PMG" NEXT_DISPATCH_MAIN_REF=main NEXT_DISPATCH_MIRROR="$MPM" NEXT_DISPATCH_GH_CMD="$WORK/gh" NEXT_DISPATCH_CLASSIFY_CMD="$WORK/classify" bash "$SUT" --workers-dir "$WORK/pm-bad/workers" --workers-from "$WORK/fleet5.json" 2>/dev/null)"
lacks "an unreadable status log withholds a candidate whose key has a merge on main" "$pmg" "LOCAL	HIMMEL-83"
has "and names it in one WARN" "$pmg" "# WARN: status-events.jsonl is unreadable: withheld HIMMEL-83 (a merge on main)"
has "while a candidate with no merge on main is still dispatched" "$pmg" "LOCAL	HIMMEL-82"
has "a key whose only main commit cites a lookalike key ([HIMMEL-880]) is not withheld" "$pmg" "LOCAL	HIMMEL-88"
# a git read that fails (no such ref) counts as merged: every candidate is withheld, not dispatched on an unknown
pmn="$(NEXT_DISPATCH_GIT_DIR="$PMG" NEXT_DISPATCH_MAIN_REF=no-such-ref NEXT_DISPATCH_MIRROR="$MPM" NEXT_DISPATCH_GH_CMD="$WORK/gh" NEXT_DISPATCH_CLASSIFY_CMD="$WORK/classify" bash "$SUT" --workers-dir "$WORK/pm-bad/workers" --workers-from "$WORK/fleet5.json" 2>/dev/null)"
lacks "an unreadable status log and a failed git read withholds a candidate (unknown fails closed)" "$pmn" "LOCAL	HIMMEL-82"
has "and the WARN names it" "$(printf '%s\n' "$pmn" | grep '^# WARN')" "HIMMEL-82"

printf '\n%d failure(s)\n' "$fails"
[ "$fails" -eq 0 ]
