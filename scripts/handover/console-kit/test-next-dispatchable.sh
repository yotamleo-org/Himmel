#!/usr/bin/env bash
# shellcheck disable=SC2015  # A && B || C is intentional in the pass/fail reporting lines, as in test-brief-lint.sh
# test-next-dispatchable.sh — Exercises next-dispatchable.sh on a
# fixture Jira mirror, a fixture manifest + leg doc, and stubbed gh / cloud-route
# (NEXT_DISPATCH_GH_CMD / NEXT_DISPATCH_CLASSIFY_CMD): no real mirror, Jira, gh
# or worktree is touched. NEXT_DISPATCH overrides the script under test (the RED
# control: a missing script fails every row). bash 3.2-safe.
#
# Run: bash scripts/handover/console-kit/test-next-dispatchable.sh
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
M="$WORK/jira-mirror/HIMMEL"; mkdir -p "$M"

mk() { # <key> <status> <prio> <labels json> <fixVersions json> <blocked_by json> <title> <body>
    printf -- '---\nkey: "%s"\ntype: "Task"\nstatus: "%s"\nstatusCategory: "x"\npriority: "%s"\nlabels: %s\nfixVersions: %s\nparent: null\nlinks:\n  blocks: []\n  blocked_by: %s\n  relates: []\n---\n\n# %s: %s\n\n## Description\n\n%s\n' \
        "$1" "$2" "$3" "$4" "$5" "$6" "$1" "$7" "$8" > "$M/$1.md"
}
mk HIMMEL-1 "To Do" Medium '[]' '["v1.0.2"]' '[]' "free later version" "Edit scripts/lib/alpha.sh only."
mk HIMMEL-2 "To Do" Medium '[]' '["v1.0.1"]' '[]' "free earlier version" "Edit scripts/lib/beta.sh only."
mk HIMMEL-3 "To Do" High '[]' '["v1.0.1"]' '[]' "collides with an open PR" "Edit scripts/lib/pr-held.sh please."
mk HIMMEL-4 "To Do" High '[]' '["v1.0.1"]' '[]' "collides with a live leg" "Edit scripts/handover/console-kit/live-file.sh please."
mk HIMMEL-5 "To Do" High '["operator-decision"]' '["v1.0.1"]' '[]' "decision pending" "Edit scripts/lib/gamma.sh."
mk HIMMEL-6 "To Do" High '["blocked"]' '["v1.0.1"]' '[]' "blocked label" "Edit scripts/lib/delta.sh."
mk HIMMEL-7 "In Progress" High '[]' '["v1.0.1"]' '[]' "already started" "Edit scripts/lib/eps.sh."
mk HIMMEL-8 "To Do" High '[]' '["v1.0.1"]' '["blocked by HIMMEL-1"]' "blocked by an open ticket" "Edit scripts/lib/zeta.sh."
mk HIMMEL-9 "To Do" Highest '[]' '["v1.0.1"]' '[]' "a hook ticket" "Edit scripts/hooks/some-hook.sh."
mk HIMMEL-10 "To Do" High '[]' '["v1.0.1"]' '[]' "refused by the classifier" "Edit scripts/lib/eta.sh."
printf 'v1.0.1\tfalse\t\nv1.0.2\tfalse\t\nv1.0.0\ttrue\t2026-01-01\n' > "$WORK/jira-mirror/HIMMEL.versions.tsv"

cat > "$WORK/gh" <<'EOF'
#!/usr/bin/env bash
[ -f "$GH_FAIL" ] && exit 1
if [ "$2" = list ]; then
    case "$*" in *headRefName*) cat "$PRS_TSV" ;; *) echo 4242 ;; esac
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
export PRS_TSV="$WORK/prs.tsv"
printf '4243\tfix(x): [HIMMEL-7] already started\tfix/himmel-7-started\n4244\tfix(x): [HIMMEL-52] in review\tfix/himmel-52-y\n' > "$PRS_TSV"

LEG="$WORK/HIMMEL-99-N1-live.md"
# shellcheck disable=SC2016  # the backticks are literal doc text, not a command substitution
printf '# live\n> **Scope / do not:** writes confined to `scripts/handover/console-kit/live-file.sh` and its test.\n' > "$LEG"
printf '{"schema":1,"legs":[{"doc":"%s","label":"N1"}]}\n' "$LEG" > "$WORK/fleet.json"

run() { NEXT_DISPATCH_MIRROR="$M" NEXT_DISPATCH_GH_CMD="$WORK/gh" NEXT_DISPATCH_CLASSIFY_CMD="$WORK/classify" bash "$SUT" "$@" 2>/dev/null; }

out="$(run --legs-from "$WORK/fleet.json")"
has "a free To Do ticket is listed" "$out" "HIMMEL-1	"
has "a CLOUD-OK ticket is listed as CLOUD" "$out" "CLOUD	HIMMEL-2"
has "a hook ticket is LOCAL and tagged hook" "$out" "HIMMEL-9	Highest"
has "the hook ticket carries the hook tag" "$(printf '%s\n' "$out" | grep 'HIMMEL-9	')" "	hook"
has "the listed line names the touched files" "$out" "files=scripts/lib/beta.sh"
lacks "a ticket colliding with an open PR is excluded" "$out" "HIMMEL-3	"
lacks "a ticket colliding with a live leg's scope is excluded" "$out" "HIMMEL-4	"
lacks "an operator-decision ticket is excluded" "$out" "HIMMEL-5	"
lacks "a blocked-label ticket is excluded" "$out" "HIMMEL-6	"
lacks "a ticket not in To Do is excluded" "$out" "HIMMEL-7	"
lacks "a ticket blocked by an open ticket is excluded" "$out" "HIMMEL-8	"
lacks "a BLOCKED classification is dropped" "$out" "HIMMEL-10	"
first="$(printf '%s\n' "$out" | grep -v '^#' | head -n 1 | cut -f2)"
[ "$first" = HIMMEL-9 ] && pass "ranked: earliest version, then priority first" || fail "ranked first is '$first' (want HIMMEL-9)"
order="$(printf '%s\n' "$out" | grep -v '^#' | cut -f2 | paste -sd, -)"
[ "$order" = "HIMMEL-9,HIMMEL-2,HIMMEL-1" ] && pass "ranked: v1.0.1 before v1.0.2" || fail "order is '$order'"

top1="$(run --top 1 --legs-from "$WORK/fleet.json" | grep -vc '^#')"
[ "$top1" = 1 ] && pass "--top caps the list" || fail "--top 1 printed $top1 lines"

: > "$GH_FAIL"
unk="$(run --legs-from "$WORK/fleet.json")"
has "a failing gh is reported, not treated as no PRs" "$unk" "open PRs unknown"
rm -f "$GH_FAIL"

nc="$(run --no-classify --legs-from "$WORK/fleet.json")"
has "--no-classify lists survivors as LOCAL?" "$nc" "LOCAL?	HIMMEL-1"

printf 'scripts/lib/alpha.sh\n' > "$WORK/held.txt"
hl="$(run --held "$WORK/held.txt" --legs-from "$WORK/fleet.json")"
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

# an unreadable manifest is reported, not treated as no live legs
lu="$(run --legs-from "$WORK/no-such-fleet.json")"
has "an unreadable manifest is reported in the header" "$lu" "live legs unknown"
printf '{"schema":1,"legs":[{"doc":"%s/gone.md","label":"N2"}]}\n' "$WORK" > "$WORK/fleet-gone.json"
lg="$(run --legs-from "$WORK/fleet-gone.json")"
has "an unreadable leg doc is reported in the header" "$lg" "live legs unknown"
lacks "a readable manifest is not reported unknown" "$out" "live legs unknown"

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
mk HIMMEL-53 "In Progress" High '[]' '[]' '[]' "has a live leg" "Edit scripts/lib/r4.sh."
mk HIMMEL-54 "In Progress" High '[]' '[]' '[]' "an epic" "Edit scripts/lib/r5.sh."
sed -i 's/^type: "Task"/type: "Epic"/' "$M5/HIMMEL-54.md"  # gnu-ok: Linux-only kit
mk HIMMEL-55 "In Progress" High '["parked"]' '[]' '[]' "parked" "Edit scripts/lib/r6.sh."
mk HIMMEL-56 "To Do" Highest '[]' '[]' '[]' "plain to do" "Edit scripts/lib/r7.sh."
mk HIMMEL-57 "In Progress" High '["blocked"]' '[]' '[]' "blocked label" "Edit scripts/lib/r8.sh."
mk HIMMEL-58 "In Progress" High '[]' '[]' '["blocked by HIMMEL-56"]' "unresolved blocker" "Edit scripts/lib/r9.sh."
M="$M_SAVE"
LEG5="$WORK/HIMMEL-53-N9-live.md"; printf '# live\n' > "$LEG5"
printf '{"schema":1,"legs":[{"doc":"%s","label":"N9"}]}\n' "$LEG5" > "$WORK/fleet5.json"
rs="$(NEXT_DISPATCH_MIRROR="$M5" NEXT_DISPATCH_GH_CMD="$WORK/gh" NEXT_DISPATCH_CLASSIFY_CMD="$WORK/classify2" bash "$SUT" --legs-from "$WORK/fleet5.json" 2>/dev/null)"
has "an In Progress ticket with no leg and no PR is listed as RESUME" "$rs" "RESUME	HIMMEL-50"
has "an In Review orphan is listed as RESUME" "$rs" "RESUME	HIMMEL-51"
has "a RESUME row carries the last stays-open comment line" "$rs" "last=Ticket stays open: slice 3 still owed."
lacks "an In Progress ticket with an open PR is not listed" "$rs" "HIMMEL-52	"
lacks "an In Progress ticket with a live leg is not listed" "$rs" "HIMMEL-53	"
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
rl="$(NEXT_DISPATCH_MIRROR="$M5" NEXT_DISPATCH_GH_CMD="$WORK/gh" bash "$SUT" --resume-only --legs-from "$WORK/no-such-fleet.json" 2>/dev/null)"
has "an unreadable manifest is reported on the RESUME read" "$rl" "live legs unknown"
lacks "an unreadable manifest lists no RESUME row" "$rl" "RESUME	"
: > "$GH_FAIL"
rf="$(NEXT_DISPATCH_MIRROR="$M5" NEXT_DISPATCH_GH_CMD="$WORK/gh" bash "$SUT" --resume-only 2>/dev/null)"
rm -f "$GH_FAIL"
has "a failed open-PR read is reported on the RESUME read" "$rf" "open PRs unknown"
lacks "a failed open-PR read lists no RESUME row" "$rf" "RESUME	"

# Windows and WSL are dropped: a To Do candidate whose summary names them is skipped (one counted
# line) unless it carries the windows-removal label; 'context window' style titles are untouched.
M6="$WORK/jira-mirror6/HIMMEL"; mkdir -p "$M6"
M_SAVE="$M"; M="$M6"
mk HIMMEL-70 "To Do" High '[]' '[]' '[]' "WSL station triage" "Edit scripts/lib/p70.sh only."
mk HIMMEL-71 "To Do" High '["windows-removal"]' '[]' '[]' "WSL station triage removal" "Edit scripts/lib/p71.sh only."
mk HIMMEL-72 "To Do" High '[]' '[]' '[]' "Handle Windows cwd separators" "Edit scripts/lib/p72.sh only."
mk HIMMEL-73 "To Do" High '[]' '[]' '[]' "cap the context window" "Edit scripts/lib/p73.sh only."
mk HIMMEL-74 "To Do" High '[]' '[]' '[]' "Windowed rate limit" "Edit scripts/lib/p74.sh only."
mk HIMMEL-75 "To Do" High '[]' '[]' '[]' "Close WRAPPED console windows and leg windows" "Edit scripts/lib/p75.sh only."
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
has "a 'console windows' title is kept" "$pw" "HIMMEL-75	"
has "a '5-hour windows' title is kept" "$pw" "HIMMEL-76	"
has "a 'context-windows' title is kept" "$pw" "HIMMEL-77	"
has "the skipped line counts and names the skipped keys" "$pw" "# skipped 2 windows/wsl ticket(s): HIMMEL-70 HIMMEL-72"
pw0="$(run --legs-from "$WORK/fleet.json")"; pw0_rc=$?
[ "$pw0_rc" = 0 ] && pass "the unrelated run exits 0" || fail "unrelated run rc=$pw0_rc"
lacks "no skipped line when nothing matched" "$pw0" "# skipped"

# Fail closed: with the pattern file gone the script exits 2 rather than dispatching unfiltered.
NF="$WORK/nopat"; mkdir -p "$NF/scripts/handover/console-kit"
cp "$SUT" "$NF/scripts/handover/console-kit/next-dispatchable.sh"
NEXT_DISPATCH_MIRROR="$M6" NEXT_DISPATCH_GH_CMD="$WORK/gh" bash "$NF/scripts/handover/console-kit/next-dispatchable.sh" --no-classify >/dev/null 2>&1; nf_rc=$?
[ "$nf_rc" = 2 ] && pass "a missing pattern file exits 2" || fail "missing pattern file rc=$nf_rc"

# Operator priority pool. One ticket per tier, keys shuffled against the tiers (a
# tier-1 ticket has the HIGHEST key), so only the tier order can put them right.
M7="$WORK/jira-mirror7/HIMMEL"; mkdir -p "$M7"
M_SAVE="$M"; M="$M7"
mk HIMMEL-140 "To Do" Medium '[]' '["v1.0.1"]' '[]' "tier4 early version" "Edit scripts/lib/q1.sh only."
mk HIMMEL-141 "To Do" Highest '[]' '["v1.0.2"]' '[]' "tier4 later version" "Edit scripts/lib/q2.sh only."
mk HIMMEL-130 "To Do" Medium '["security"]' '[]' '[]' "tier3 security label" "Edit scripts/lib/q3.sh only."
mk HIMMEL-131 "To Do" High '[]' '[]' '[]' "tier3 high bug" "Edit scripts/lib/q4.sh only."
sed -i 's/^type: "Task"/type: "Bug"/' "$M7/HIMMEL-131.md"  # gnu-ok: Linux-only kit
mk HIMMEL-132 "To Do" Medium '[]' '[]' '[]' "medium bug is not tier3" "Edit scripts/lib/q5.sh only."
sed -i 's/^type: "Task"/type: "Bug"/' "$M7/HIMMEL-132.md"  # gnu-ok: Linux-only kit
mk HIMMEL-120 "To Do" Low '["operator-directed"]' '[]' '[]' "tier2 operator directed" "Edit scripts/lib/q6.sh only."
mk HIMMEL-110 "To Do" Low '["must-v1.1.3"]' '[]' '[]' "tier1 by label" "Edit scripts/lib/q7.sh only."
mk HIMMEL-111 "To Do" Low '[]' '[]' '[]' "tier1 second on the line" "Edit scripts/lib/q8.sh only."
mk HIMMEL-112 "To Do" Low '[]' '[]' '[]' "tier1 first on the line" "Edit scripts/lib/q9.sh only."
mk HIMMEL-113 "To Do" Low '[]' '[]' '[]' "listed but cloud only" "Edit scripts/lib/q10.sh only."
mk HIMMEL-150 "In Progress" Low '[]' '[]' '[]' "orphan in progress" "Edit scripts/lib/q11.sh only."
M="$M_SAVE"
printf 'v1.0.1\tfalse\t\nv1.0.2\tfalse\t\n' > "$WORK/jira-mirror7/HIMMEL.versions.tsv"
CDOC="$WORK/console-doc.md"
printf '# console\n\n## Live state\n\nlegs: none\npriority: K1 | 112 SCORECARD | 111 113(CLOUD) | 9999\nqueue: none\n\n## Later\n\npriority: 140\n' > "$CDOC"
run7() { NEXT_DISPATCH_MIRROR="$M7" NEXT_DISPATCH_GH_CMD="$WORK/gh" NEXT_DISPATCH_CLASSIFY_CMD="$WORK/classify2" bash "$SUT" "$@" 2>/dev/null; }
o7="$(run7 --top 20 --doc "$CDOC" | grep -v '^#' | grep -v '^RESUME' | cut -f2 | paste -sd, -)"
[ "$o7" = "HIMMEL-112,HIMMEL-111,HIMMEL-110,HIMMEL-120,HIMMEL-131,HIMMEL-130,HIMMEL-140,HIMMEL-141,HIMMEL-132" ] && pass "one ticket per tier on shuffled input comes out in tier order" || fail "tier order is '$o7'"
lacks "a (CLOUD) entry on the priority line is excluded from local output" "$o7" "HIMMEL-113"
o7b="$(run7 --doc "$CDOC" --priority-pool-only | grep -v '^#' | cut -f2 | paste -sd, -)"
[ "$o7b" = "HIMMEL-112,HIMMEL-111,HIMMEL-110,HIMMEL-120,HIMMEL-131,HIMMEL-130" ] && pass "--priority-pool-only lists tiers 1-3 only" || fail "pool-only is '$o7b'"
lacks "--priority-pool-only prints no RESUME row" "$(run7 --doc "$CDOC" --priority-pool-only)" "RESUME"
o7c="$(run7 --priority-pool-only | grep -v '^#' | cut -f2 | paste -sd, -)"
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

# --- the pool offers leg-less In Progress tickets and reads the priority: line as written ---
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
mk HIMMEL-410 "In Progress" Low '[]' '[]' '[]' "resume keyed with a leg" "Edit scripts/lib/s10.sh only."
mk HIMMEL-411 "To Do" Low '[]' '[]' '[]' "named only in a plus annotation" "Edit scripts/lib/s11.sh only."
mk HIMMEL-412 "To Do" Low '[]' '[]' '[]' "named only in a bare annotation" "Edit scripts/lib/s12.sh only."
mk HIMMEL-413 "To Do" Low '[]' '[]' '[]' "keyed head of an annotated entry" "Edit scripts/lib/s13.sh only."
mk HIMMEL-414 "To Do" Low '[]' '[]' '[]' "second number of a plus run" "Edit scripts/lib/s14.sh only."
mk HIMMEL-415 "To Do" Low '[]' '[]' '[]' "bare number in a paren with no plus" "Edit scripts/lib/s15.sh only."
mk HIMMEL-416 "To Do" Low '[]' '[]' '[]' "prefixed key inside a paren" "Edit scripts/lib/s16.sh only."
M="$M_SAVE"
LEG11="$WORK/HIMMEL-410-N11-live.md"; printf '# live\n' > "$LEG11"
printf '{"schema":1,"legs":[{"doc":"%s","label":"N11"}]}\n' "$LEG11" > "$WORK/fleet11.json"
run11() { NEXT_DISPATCH_MIRROR="$M11" NEXT_DISPATCH_GH_CMD="$WORK/gh" NEXT_DISPATCH_CLASSIFY_CMD="$WORK/classify2" bash "$SUT" "$@" 2>/dev/null; }
D11="$WORK/console-doc11.md"
printf '# console\n\n## Live state\n\npriority: 401 402 406 407(CLOUD) | 410 413(NOTE +411 and 2026 plan)\n' > "$D11"
rows11() { grep -v '^#' | cut -f1,2 | tr '\t' ':' | paste -sd, -; }
o11="$(run11 --doc "$D11" --legs-from "$WORK/fleet11.json" --priority-pool-only | rows11)"
[ "$o11" = "RESUME:HIMMEL-401,RESUME:HIMMEL-406,LOCAL:HIMMEL-402,LOCAL:HIMMEL-413,LOCAL:HIMMEL-411,RESUME:HIMMEL-403,LOCAL:HIMMEL-404" ] && pass "pool-only: tier 1-3 RESUME rows lead their tier's To Do rows" || fail "pool-only with RESUME is '$o11'"
lacks "pool-only: a tier-4 In Progress ticket is not a pool row" "$o11" "HIMMEL-405"
lacks "pool-only: a leg-less pool key with a live leg is not a RESUME row" "$o11" "HIMMEL-410"
lacks "pool-only: a 'NNN (CLOUD)' To Do ticket is excluded" "$o11" "HIMMEL-407"
printf '# console\n\n## Live state\n\n**priority:** 408 | 407 (CLOUD) 406 (CLOUD)\n\n## Later\n\npriority: 409\n' > "$D11"
b11="$(run11 --doc "$D11" --legs-from "$WORK/fleet11.json" --priority-pool-only | rows11)"
[ "$b11" = "LOCAL:HIMMEL-408,RESUME:HIMMEL-403,LOCAL:HIMMEL-404" ] && pass "a bold **priority:** line is read, a 'NNN (CLOUD)' token is excluded, a priority: under a later heading is not" || fail "bold-line pool is '$b11'"
printf '# console\n\n## Live state\n\npriority: 413(NOTE +411 414) 400(verify 415 HIMMEL-416) 412x\n' > "$D11"
p11="$(run11 --doc "$D11" --legs-from "$WORK/fleet11.json" --priority-pool-only | rows11)"
has "a number right after a plus inside parens is a key" "$p11" "HIMMEL-411"
has "every number from a plus to the closing paren is a key" "$p11" "HIMMEL-414"
lacks "a bare number inside parens with no plus is not a key" "$p11" "HIMMEL-415"
has "a HIMMEL-NNNN inside parens is a key" "$p11" "HIMMEL-416"
lacks "a key glued to letters is not a key" "$p11" "HIMMEL-412"
printf '# console\n\n## Live state\n\npriority: 402\n' > "$D11"
e11="$(NEXT_DISPATCH_MIRROR="$M11" NEXT_DISPATCH_GH_CMD="$WORK/gh" NEXT_DISPATCH_CLASSIFY_CMD="$WORK/classify2" bash "$SUT" --doc "$D11" --top 1 --legs-from "$WORK/fleet11.json" --priority-pool-only 2>/dev/null | rows11)"
[ "$e11" = "LOCAL:HIMMEL-402" ] && pass "pool-only: --top caps RESUME and To Do rows together" || fail "top-capped pool is '$e11'"
r11="$(NEXT_DISPATCH_MIRROR="$M11" NEXT_DISPATCH_GH_CMD="$WORK/gh" NEXT_DISPATCH_CLASSIFY_CMD="$WORK/classify2" bash "$SUT" --doc "$D11" --legs-from "$WORK/fleet11.json" --priority-pool-only --resume-only 2>/dev/null | rows11)"
[ "$r11" = "RESUME:HIMMEL-403" ] && pass "pool-only with --resume-only prints only RESUME rows and no POOL-EMPTY" || fail "pool-only resume-only is '$r11'"
M12="$WORK/jira-mirror12/HIMMEL"; mkdir -p "$M12"
M_SAVE="$M"; M="$M12"
mk HIMMEL-420 "In Progress" Low '["must-v1.1.3"]' '[]' '[]' "only a leg-less pool ticket" "Edit scripts/lib/t1.sh only."
M="$M_SAVE"
x12="$(NEXT_DISPATCH_MIRROR="$M12" NEXT_DISPATCH_GH_CMD="$WORK/gh" NEXT_DISPATCH_CLASSIFY_CMD="$WORK/classify2" bash "$SUT" --priority-pool-only --owners "HIMMEL-999" 2>/dev/null)"
has "pool-only: a leg-less pool ticket alone is a RESUME row" "$x12" "RESUME	HIMMEL-420"
lacks "pool-only: a pool with only a RESUME row is not POOL-EMPTY" "$x12" "POOL-EMPTY"
n12="$(NEXT_DISPATCH_MIRROR="$M12" NEXT_DISPATCH_GH_CMD="$WORK/gh" NEXT_DISPATCH_CLASSIFY_CMD="$WORK/classify2" bash "$SUT" --priority-pool-only 2>"$WORK/n12.err")"
lacks "pool-only: no leg source (no --owners, no --legs-from) offers no RESUME row" "$n12" "RESUME"
has "pool-only: no leg source says why on stderr" "$(cat "$WORK/n12.err")" "no leg source"
# a doc whose only priority: line sits under a later heading names no tier-1 key
printf '# console\n\n## Live state\n\nnothing here\n\n## Later\n\npriority: 408\n' > "$D11"
l11="$(run11 --doc "$D11" --legs-from "$WORK/fleet11.json" --priority-pool-only | rows11)"
lacks "a priority: line only under a later heading keys nothing" "$l11" "HIMMEL-408"
# a cloud session in cloud-sessions.tsv next to the doc owns its ticket
mkdir -p "$WORK/cl11"; printf '# console\n\n## Live state\n\npriority: 401 402\n' > "$WORK/cl11/doc.md"
printf '%s\tHIMMEL-401\tsess\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$WORK/cl11/cloud-sessions.tsv"
c11="$(run11 --doc "$WORK/cl11/doc.md" --legs-from "$WORK/fleet11.json" --priority-pool-only | rows11)"
lacks "pool-only: a cloud-owned In Progress ticket is not offered" "$c11" "HIMMEL-401"
printf '%s\tHIMMEL-401\tsess\n' "2020-01-01T00:00:00Z" > "$WORK/cl11/cloud-sessions.tsv"
c11b="$(run11 --doc "$WORK/cl11/doc.md" --legs-from "$WORK/fleet11.json" --priority-pool-only | rows11)"
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
has "pool-only: an ordinary leg-less pool ticket is still a RESUME row" "$f13" "RESUME	HIMMEL-423"

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
RDOC="$WORK/console-rd.md"
printf '# console\n\n## Live state\n\n- residual-must HIMMEL-302 (security)\n' > "$RDOC"
RDOC_NONE="$WORK/console-rd-none.md"
printf '# console\n\n## Live state\n\n- priority: 300\n' > "$RDOC_NONE"
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
printf '# console\n\n- residual-must HIMMEL-303 (data loss)\n' > "$RDOC"
r4="$(rdrun --doc "$RDOC")"
has "residual-depth: a residual-must ruling releases a depth-2 ticket too" "$r4" "HIMMEL-303"

# --- classify only up to --top: a batch never classifies more keys than the slots left ---
M14="$WORK/jira-mirror14/HIMMEL"; mkdir -p "$M14"
M_SAVE="$M"; M="$M14"
for n in 1 2 3 4 5 6; do mk "HIMMEL-40$n" "To Do" Medium '[]' '["v1.0.1"]' '[]' "pool work $n" "Edit scripts/lib/cls$n.sh only."; done
M="$M_SAVE"
DOC14="$WORK/console14.md"
printf '# console\n\n## Live state\n\n- priority: 401 402 403 404 405 406\n' > "$DOC14"
cat > "$WORK/classify14" <<'EOF'
#!/usr/bin/env bash
printf 'S\n' >> "$CLASSIFY_LOG"; sleep 1
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
[ "$keys14" -le 4 ] && pass "classify sees at most 2*--top keys ($keys14)" || fail "classify saw $keys14 keys for --top 2"
[ "$calls14" -eq 2 ] && [ "$peak14" -eq 2 ] && pass "classify makes at most 2 calls, at most 2 in flight (calls=$calls14 peak=$peak14)" || fail "classify calls=$calls14 peak=$peak14"
[ "$o14" = "HIMMEL-401 HIMMEL-402 " ] && pass "parallel classify keeps rank order" || fail "rank order wrong: $o14"
: > "$REFUSE_401"; : > "$CLASSIFY_LOG"
o14="$(run14)"
[ "$o14" = "HIMMEL-402 HIMMEL-403 " ] && pass "a refused row is skipped and rank order holds" || fail "refusal order wrong: $o14"

printf '\n%d failure(s)\n' "$fails"
[ "$fails" -eq 0 ]
