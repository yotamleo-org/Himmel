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
NF="$WORK/nopat"; mkdir -p "$NF/scripts/handover/chief-kit"
cp "$SUT" "$NF/scripts/handover/chief-kit/next-dispatchable.sh"
NEXT_DISPATCH_MIRROR="$M6" NEXT_DISPATCH_GH_CMD="$WORK/gh" bash "$NF/scripts/handover/chief-kit/next-dispatchable.sh" --no-classify >/dev/null 2>&1; nf_rc=$?
[ "$nf_rc" = 2 ] && pass "a missing pattern file exits 2" || fail "missing pattern file rc=$nf_rc"

# Operator priority pool. One ticket per tier, keys shuffled against the tiers (a
# tier-1 ticket has the HIGHEST key), so only the tier order can put them right.
M7="$WORK/jira-mirror7/HIMMEL"; mkdir -p "$M7"
M_SAVE="$M"; M="$M7"
mk HIMMEL-140 "To Do" Medium '[]' '["v1.0.1"]' '[]' "tier4 early version" "Edit scripts/lib/q1.sh only."
mk HIMMEL-141 "To Do" Highest '[]' '["v1.0.2"]' '[]' "tier4 later version" "Edit scripts/lib/q2.sh only."
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
[ "$o7b" = "HIMMEL-112,HIMMEL-111,HIMMEL-110,HIMMEL-120,HIMMEL-131,HIMMEL-130" ] && pass "--priority-pool-only lists tiers 1-3 only" || fail "pool-only is '$o7b'"
lacks "--priority-pool-only prints no RESUME row" "$(run7 --doc "$CDOC" --priority-pool-only)" "RESUME"
printf '# chief\n\n## Live state\n\n**priority:** K1 | 112 SCORECARD | 111 113 (CLOUD) | [PR 170] since 10.171\nqueue: none\n' > "$WORK/chief-doc-bold.md"
o7d="$(run7 --doc "$WORK/chief-doc-bold.md" --priority-pool-only | grep -v '^#' | cut -f2 | paste -sd, -)"
[ "$o7d" = "HIMMEL-112,HIMMEL-111,HIMMEL-110,HIMMEL-120,HIMMEL-131,HIMMEL-130" ] && pass "a bold **priority:** line with '113 (CLOUD)' and bracketed or dotted numbers ranks as written" || fail "bold-line pool is '$o7d'"
o7c="$(run7 --priority-pool-only |grep -v '^#' | cut -f2 | paste -sd, -)"
[ "$o7c" = "HIMMEL-110,HIMMEL-120,HIMMEL-131,HIMMEL-130" ] && pass "without --doc the pool is the labels and tiers 2-3" || fail "no-doc pool is '$o7c'"
M8="$WORK/jira-mirror8/HIMMEL"; mkdir -p "$M8"
M_SAVE="$M"; M="$M8"
mk HIMMEL-160 "To Do" Highest '[]' '["v1.0.1"]' '[]' "only tier4" "Edit scripts/lib/w1.sh only."
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
mk HIMMEL-405 "In Progress" Low '[]' '[]' '[]' "resume tier 4 is not pool" "Edit scripts/lib/s5.sh only."
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
lacks "pool-only: a tier-4 In Progress ticket is not a pool row" "$o11" "HIMMEL-405"
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
# an empty pool names the next-tier candidates (tier 4, rank order unchanged)
# on NEXT-TIER rows a dispatcher reading ticket rows never picks up.
has "a pool shorter than the free slots prints pool=<n>/<slots>,LOW" "$(run7 --doc "$CDOC" --priority-pool-only --top 8)" "pool=6/8,LOW"
p10="$(run7 --doc "$CDOC" --priority-pool-only --top 4)"
has "a pool that fills the slots prints pool=<n>/<slots>" "$p10" "pool=4/4"
lacks "a pool that fills the slots is not LOW" "$p10" "LOW"
e10="$(NEXT_DISPATCH_MIRROR="$M8" NEXT_DISPATCH_GH_CMD="$WORK/gh" NEXT_DISPATCH_CLASSIFY_CMD="$WORK/classify2" bash "$SUT" --priority-pool-only --top 8 2>/dev/null)"
has "an empty pool prints pool=0/<slots>,LOW" "$e10" "pool=0/8,LOW"
has "an empty pool lists the next-tier candidate on a NEXT-TIER row" "$e10" "NEXT-TIER	HIMMEL-160"

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

# --- chain_soft_edges: both flag states on a local git fixture -----------------
# OFF is today's collision drop; ON keeps a ticket whose files overlap an open PR when the
# trial merge of that PR against main is clean, the overlap is at most 2 files and no trust
# path is involved, and says so with a `# SOFT` row.
export HIMMEL_CONFIG_DIR="$WORK/no-conf"   # no real ~/.himmel layer reaches the flag
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
soft_dflt="$(run31)"
# shellcheck disable=SC2030,SC2031  # each flag state is set in its own command-substitution subshell on purpose
soft_off="$( export HIMMEL_FLAG_CHAIN_SOFT_EDGES=0; run31 )"
# shellcheck disable=SC2030,SC2031  # each flag state is set in its own command-substitution subshell on purpose
soft_on="$( export HIMMEL_FLAG_CHAIN_SOFT_EDGES=1; run31 )"
# shellcheck disable=SC2030,SC2031  # each flag state is set in its own command-substitution subshell on purpose
soft_why="$( export HIMMEL_FLAG_CHAIN_SOFT_EDGES=1; run31 --why )"

# OFF: today's output, exactly
[ "$soft_off" = "$soft_dflt" ] && pass "soft OFF: the registry default is off, identical to the explicit 0" || fail "soft OFF: default and =0 differ"
soft_off_rows="$(printf '%s\n' "$soft_off" | grep -v '^#' | cut -f1,2)"
[ "$soft_off_rows" = "LOCAL	HIMMEL-3107" ] && pass "soft OFF: only the ticket that overlaps nothing is listed" || fail "soft OFF: rows are '$soft_off_rows'"
lacks "soft OFF: no SOFT row" "$soft_off" "SOFT"
has "soft OFF: the clean-PR overlap is dropped as a collision" "$soft_off" "# next-dispatchable: 7 To Do candidate(s), 1 collision-free"

# ON: the clean small overlaps stay dispatchable and are named
has "soft ON: a ticket overlapping a clean PR is listed" "$soft_on" "HIMMEL-3101	"
has "soft ON: it says SOFT, naming the holder and the file" "$soft_on" "# SOFT open PR 7001 scripts/lanes/soft-one.sh for HIMMEL-3101"
has "soft ON: a two-file overlap of one clean PR is listed" "$soft_on" "HIMMEL-3106	"
has "soft ON: the two-file SOFT row names both files" "$soft_on" "# SOFT open PR 7001 scripts/lanes/soft-a.sh,scripts/lanes/soft-two.sh for HIMMEL-3106"
has "soft ON: a ticket that overlaps nothing is still listed" "$soft_on" "HIMMEL-3107	"
lacks "soft ON: a ticket that overlaps nothing has no SOFT row" "$soft_on" "for HIMMEL-3107"
lacks "soft ON: a PR whose trial merge conflicts still holds its file" "$soft_on" "HIMMEL-3102	"
lacks "soft ON: a trust path is never soft" "$soft_on" "HIMMEL-3103	"
lacks "soft ON: more than 2 overlapping files is never soft" "$soft_on" "HIMMEL-3104	"
lacks "soft ON: a live worker's file holds even beside a soft overlap" "$soft_on" "HIMMEL-3105	"
has "soft ON --why: a conflicting trial merge is still a collision drop" "$soft_why" "# drop HIMMEL-3102 collision scripts/lanes/soft-conf.sh held by open PR 7002"
has "soft ON --why: a trust path is still a collision drop" "$soft_why" "# drop HIMMEL-3103 collision scripts/lib/soft-trust.sh held by open PR 7003"
has "soft ON --why: a wide overlap is still a collision drop" "$soft_why" "# drop HIMMEL-3104 collision "
has "soft ON --why: the live-worker overlap names the first holder it finds" "$soft_why" "# drop HIMMEL-3105 collision "

# ON fails closed to today's drop when the trial cannot run
# shellcheck disable=SC2030,SC2031  # each flag state is set in its own command-substitution subshell on purpose
soft_nohead="$( export HIMMEL_FLAG_CHAIN_SOFT_EDGES=1 SOFT_MAIN_REF=no-such-ref; run31 )"
lacks "soft ON: an unresolvable main ref falls back to the collision drop" "$soft_nohead" "HIMMEL-3101	"
lacks "soft ON: and prints no SOFT row" "$soft_nohead" "SOFT"
# a conf-file value turns the flag on the same way as the environment
mkdir -p "$WORK/conf-on"; printf 'HIMMEL_FLAG_CHAIN_SOFT_EDGES=1\n' > "$WORK/conf-on/himmel.conf"
soft_conf="$( export HIMMEL_CONFIG_DIR="$WORK/conf-on"; run31 )"
has "soft: himmel.conf turns it on" "$soft_conf" "# SOFT open PR 7001 scripts/lanes/soft-one.sh for HIMMEL-3101"

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
has "Done category: a blocker in a Done-category status (wont do) is resolved" "$dc_out" "HIMMEL-9302"
# a Done-category mirror row whose live Jira status was reopened still blocks; a live wont do still counts as done
printf -- '---\nkey: "HIMMEL-9303"\ntype: "Task"\nstatus: "wont do"\nstatusCategory: "Done"\npriority: "High"\nlabels: []\nfixVersions: ["v1.0.1"]\nparent: null\nlinks:\n  blocks: []\n  blocked_by: []\n  relates: []\n---\n\n# HIMMEL-9303: stale wont do\n\n## Description\n\nEdit scripts/lib/stale.sh.\n' > "$M/HIMMEL-9303.md"
mk HIMMEL-9304 "To Do" High '[]' '["v1.0.1"]' '["HIMMEL-9303"]' "blocked by a reopened ticket" "Edit scripts/lib/after-reopen.sh."
# shellcheck disable=SC2016  # the $ names are literal text of the fake Jira CLI, expanded when it runs
printf '#!/usr/bin/env bash\nprintf "%%s\\tTask\\t%%s\\tt\\n" "$2" "$LIVE_STATUS"\n' > "$WORK/jira-live"; chmod +x "$WORK/jira-live"
reopen_out="$(NEXT_DISPATCH_JIRA_CMD="$WORK/jira-live" LIVE_STATUS="In Progress" run --no-classify)"
lacks "Done category: a mirror wont do blocker reopened live still blocks" "$reopen_out" "HIMMEL-9304"
closed_out="$(NEXT_DISPATCH_JIRA_CMD="$WORK/jira-live" LIVE_STATUS="wont do" run --no-classify)"
has "Done category: a mirror wont do blocker still wont do live is resolved" "$closed_out" "HIMMEL-9304"
archived_out="$(NEXT_DISPATCH_JIRA_CMD="$WORK/jira-live" LIVE_STATUS="Archived" run --no-classify)"
has "Done category: a custom Done-category live status (Archived) is resolved" "$archived_out" "HIMMEL-9304"
M="$WORK/jira-mirror/HIMMEL"

printf '\n%d failure(s)\n' "$fails"
[ "$fails" -eq 0 ]
