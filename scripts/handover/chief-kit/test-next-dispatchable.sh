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
KP=HIMMEL
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; fails=$((fails + 1)); }
has() { # <name> <haystack> <needle>
    case "$2" in *"$3"*) pass "$1" ;; *) fail "$1 (missing '$3' in: $2)" ;; esac
}
lacks() { # <name> <haystack> <needle>
    case "$2" in *"$3"*) fail "$1 (found '$3' in: $2)" ;; *) pass "$1" ;; esac
}
check() { # <name> <expected> <actual>, the helper the other chief-kit suites share
    if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (want '$2' got '$3')"; fi
}

REAL_HOME="$HOME"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/next-dispatch-test.XXXXXX")" || exit 1
trap 'rm -rf "$WORK"' EXIT
# the holds register lives under HOME: pin it (and the handover root holds.py judges liveness in) to the fixture, so
# no row of the real register is read or written; the last row asserts the real one is unchanged
export HOME="$WORK/home" HANDOVER_DIR="$WORK/h"
mkdir -p "$HOME" "$HANDOVER_DIR"
HOLDS_PY="$HERE/holds.py"
SEEDED=0
seed() {
    local d="$3"; shift 3
    case "$d" in "$WORK"/*) printf '> **Writes:** %s\n' "$*" >> "$d" ;; esac
    SEEDED=$((SEEDED + $#))
}
# the default worker records live under the status state dir: keep it in the fixture
export TICKET_STATUS_STATE_DIR="$WORK/ts-none"
# and the admissions ledger: the real one must never admit a fixture key
export HIMMEL_ADMISSIONS_LEDGER="$WORK/ledger-none.jsonl"
# merged-or-not is answered from local git: pin it to a fixture repo that cites no fixture key, so the real
# origin/main never answers for a fixture ticket; the merged PR body cache is off here so rows that reuse a PR number do not share it
GN="$WORK/git-none"; mkdir -p "$GN"
git -C "$GN" init -q -b main && git -C "$GN" -c user.name=t -c user.email=t@example.com -c commit.gpgsign=false -c core.hooksPath=/dev/null commit -q --allow-empty -m "init" \
    || { echo "FAIL: could not build the fixture main"; exit 1; }
export NEXT_DISPATCH_GIT_DIR="$GN" NEXT_DISPATCH_MAIN_REF=main NEXT_DISPATCH_BODY_CACHE=off
M="$WORK/jira-mirror/HIMMEL"; mkdir -p "$M"
# the core gate is permanent and asks the built jira CLI (scripts/jira/dist is untracked, absent in CI), so every
# row below runs with a fixture stand-in that calls every key NOT-CORE; the C3 section at the end swaps in its own stand-in per run
mkdir -p "$WORK/notcore-stub"
cat > "$WORK/notcore-stub/index.js" <<'NCEOF'
const a = process.argv.slice(2);
if (a[0] === 'release' && a[1] === 'core-check') for (const k of a.slice(a.indexOf('--key') + 1)) console.log('NOT-CORE ' + k);
else { console.error('stub jira: unknown command ' + a.join(' ')); process.exit(2); }
NCEOF
export NEXT_DISPATCH_JIRA_CLI="$WORK/notcore-stub/index.js"

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
printf '4242\tfix(x): an outside change to a held file\tcontributor/pr-held\ttrue\t2026-01-01T00:00:00Z\n4243\tfix(x): [HIMMEL-7] already started\tfix/himmel-7-started\n4244\tfix(x): [HIMMEL-52] in review\tfix/himmel-52-y\n' > "$PRS_TSV"

WORKER="$WORK/HIMMEL-99-N1-live.md"
# shellcheck disable=SC2016  # the backticks are literal doc text, not a command substitution
printf '# live\n> **Scope / do not:** writes confined to `scripts/handover/chief-kit/live-file.sh` and its test.\n' > "$WORKER"
printf '{"schema":1,"legs":[{"doc":"%s","label":"N1"}]}\n' "$WORKER" > "$WORK/fleet.json"
seed HIMMEL-99 N1 "$WORKER" scripts/handover/chief-kit/live-file.sh  # the register, not the doc's scope line, says what N1 writes

run() { NEXT_DISPATCH_MIRROR="$M" NEXT_DISPATCH_GH_CMD="$WORK/gh" NEXT_DISPATCH_CLASSIFY_CMD="$WORK/classify" bash "$SUT" "$@" 2>/dev/null; }

out="$(run --workers-from "$WORK/fleet.json")"
has "a free To Do ticket is listed" "$out" "HIMMEL-1	"
has "a CLOUD-OK ticket is listed as CLOUD" "$out" "CLOUD	HIMMEL-2"
has "a hook ticket is LOCAL and tagged hook" "$out" "HIMMEL-9	Highest"
has "the hook ticket carries the hook tag" "$(printf '%s\n' "$out" | grep "$KP-9	")" "	hook"
has "the listed line names the touched files" "$out" "files=scripts/lib/beta.sh"
has "a ticket colliding with an open PR (an outside one) is listed" "$out" "HIMMEL-3	"
has "an open PR's file is printed as an overlap, not a drop" "$out" "# overlap HIMMEL-3 scripts/lib/pr-held.sh with open PR 4242"
has "a ticket colliding with a live worker's scope is listed" "$out" "HIMMEL-4	"
has "a live worker's file is printed as an overlap" "$out" "# overlap HIMMEL-4 scripts/handover/chief-kit/live-file.sh with live worker N1"
lacks "an operator-decision ticket is excluded" "$out" "HIMMEL-5	"
lacks "a blocked-label ticket is excluded" "$out" "HIMMEL-6	"
lacks "a ticket not in To Do is excluded" "$out" "HIMMEL-7	"
lacks "a ticket blocked by an open ticket is excluded" "$out" "HIMMEL-8	"
lacks "a BLOCKED classification is dropped" "$out" "HIMMEL-10	"
first="$(printf '%s\n' "$out" | grep -v '^#' | head -n 1 | cut -f2)"
[ "$first" = "$KP"-9 ] && pass "ranked: earliest version, then priority first" || fail "ranked first is '$first' (want $KP-9)"
order="$(printf '%s\n' "$out" | grep -v '^#' | cut -f2 | paste -sd, -)"
[ "$order" = "HIMMEL-9,HIMMEL-3,HIMMEL-4,HIMMEL-2,HIMMEL-1" ] && pass "ranked: v1.0.1 before v1.0.2" || fail "order is '$order'"

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
has "--held lists a colliding ticket" "$hl" "HIMMEL-1	"
has "--held prints the overlap" "$hl" "# overlap HIMMEL-1 scripts/lib/alpha.sh with held list"

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
has "a second ticket on the same file is not listed with it: listed, its shared file an overlap" "$sh3" "# overlap HIMMEL-31 "
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
has "a workers manifest excludes a ticket colliding with a live worker's scope: listed, its shared file an overlap" "$ow" "# overlap HIMMEL-4 "
lacks "a workers manifest is not reported unknown" "$ow" "live workers unknown"
printf '{"schema":1,"legs":[{"doc":"%s/gone.md","label":"N2"}],"workers":[{"doc":"%s","label":"N1"}]}\n' "$WORK" "$WORKER" > "$WORK/fleet-both.json"
ob="$(run --workers-from "$WORK/fleet-both.json")"
has "a manifest with both arrays reads the workers one (the colliding ticket excluded): listed, its shared file an overlap" "$ob" "# overlap HIMMEL-4 "
lacks "a manifest with both arrays is not reported unknown" "$ob" "live workers unknown"
off="$(HIMMEL_LEGACY_NAMES=0 run --workers-from "$WORK/fleet.json")"
has "with HIMMEL_LEGACY_NAMES=0 a legs-only manifest is reported unknown" "$off" "live workers unknown"
offw="$(HIMMEL_LEGACY_NAMES=0 run --workers-from "$WORK/fleet-w.json")"
has "with HIMMEL_LEGACY_NAMES=0 a workers manifest still excludes the colliding ticket: listed, its shared file an overlap" "$offw" "# overlap HIMMEL-4 "
lacks "with HIMMEL_LEGACY_NAMES=0 a workers manifest is not reported unknown" "$offw" "live workers unknown"

# root files and plugins/ take part in the collision check
M4="$WORK/m4/HIMMEL"; mkdir -p "$M4"
M_SAVE="$M"; M="$M4"
mk HIMMEL-40 "To Do" High '[]' '[]' '[]' "touches package.json" "Bump a dep in package.json."
mk HIMMEL-41 "To Do" High '[]' '[]' '[]' "touches a plugin" "Edit plugins/foo/run.sh."
M="$M_SAVE"
printf 'package.json\nplugins/foo\n' > "$WORK/held4.txt"
rh="$(NEXT_DISPATCH_MIRROR="$M4" NEXT_DISPATCH_GH_CMD="$WORK/gh" NEXT_DISPATCH_CLASSIFY_CMD="$WORK/classify2" bash "$SUT" --held "$WORK/held4.txt" 2>/dev/null)"
has "a held root file excludes a ticket naming it: listed, its shared file an overlap" "$rh" "# overlap HIMMEL-40 "
has "a held plugins/ path excludes a ticket naming it: listed, its shared file an overlap" "$rh" "# overlap HIMMEL-41 "

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
ro="$(NEXT_DISPATCH_MIRROR="$M5" NEXT_DISPATCH_GH_CMD="$WORK/gh" bash "$SUT" --resume-only --owners "$KP-51" 2>/dev/null)"
has "--resume-only lists a RESUME row" "$ro" "RESUME	HIMMEL-50"
lacks "--resume-only drops a ticket named by --owners" "$ro" "HIMMEL-51	"
lacks "--resume-only lists no To Do row" "$ro" "HIMMEL-56	"
lacks "an In Progress ticket with an unresolved blocker is not listed" "$ro" "HIMMEL-58	"
rl="$(NEXT_DISPATCH_MIRROR="$M5" NEXT_DISPATCH_GH_CMD="$WORK/gh" bash "$SUT" --resume-only --workers-from "$WORK/no-such-fleet.json" 2>/dev/null)"
has "an unreadable manifest is reported on the RESUME read" "$rl" "live workers unknown"
lacks "an unreadable manifest lists no RESUME row" "$rl" "RESUME	"

# A live worker whose files are unknown (no Writes line, or a doc that cannot be read) still owns its own key by
# its doc name; only its files are unknown. It never hides the RESUME rows of the tickets nobody owns.
M9="$WORK/m9/HIMMEL"; mkdir -p "$M9"
M_SAVE="$M"; M="$M9"
mk HIMMEL-60 "In Progress" Medium '[]' '[]' '[]' "orphan beside a scope-less worker" "Edit scripts/lib/s1.sh."
mk HIMMEL-61 "In Progress" Medium '[]' '[]' '[]' "owned by a scope-less worker" "Edit scripts/lib/s2.sh."
mk HIMMEL-62 "In Progress" Medium '[]' '[]' '[]' "owned by a worker whose doc is gone" "Edit scripts/lib/s3.sh."
mk HIMMEL-64 "In Progress" Medium '[]' '[]' '[]' "bundle sibling, no PR yet" "Edit scripts/lib/s4.sh."
mk HIMMEL-65 "IN CI" Medium '[]' '[]' '[]' "bundle sibling in CI, no PR" "Edit scripts/lib/s5.sh."
M="$M_SAVE"
BUNDLE9="$WORK/HIMMEL-63-N12-bundle-RESUME.md"; printf '# RESUME — HIMMEL-63 / 64 / 65 — worker N12\n\nno scope named here\n' > "$BUNDLE9"
printf '{"schema":1,"workers":[{"doc":"%s","label":"N12"}]}\n' "$BUNDLE9" > "$WORK/fleet9c.json"
r9c="$(NEXT_DISPATCH_MIRROR="$M9" NEXT_DISPATCH_GH_CMD="$WORK/gh" bash "$SUT" --resume-only --workers-from "$WORK/fleet9c.json" 2>/dev/null)"
has "a scope-less bundle worker still lets an unrelated orphan list as RESUME" "$r9c" "RESUME	HIMMEL-60"
lacks "a scope-less bundle worker owns the sibling its title names (In Progress, no PR)" "$r9c" "HIMMEL-64	"
lacks "a scope-less bundle worker owns a sibling its title lists as a bare number (IN CI, no PR)" "$r9c" "HIMMEL-65	"
NOSCOPE9="$WORK/HIMMEL-61-N10-no-scope.md"; printf '# live\nno scope named here\n' > "$NOSCOPE9"
printf '{"schema":1,"workers":[{"doc":"%s","label":"N10"}]}\n' "$NOSCOPE9" > "$WORK/fleet9.json"
r9="$(NEXT_DISPATCH_MIRROR="$M9" NEXT_DISPATCH_GH_CMD="$WORK/gh" NEXT_DISPATCH_CLASSIFY_CMD="$WORK/classify2" bash "$SUT" --workers-from "$WORK/fleet9.json" 2>/dev/null)"
has "9321: a scope-less live worker still lists the orphan nobody owns as RESUME" "$r9" "RESUME	HIMMEL-60"
lacks "9321: the scope-less live worker owns its own key, so that ticket is no RESUME row" "$r9" "HIMMEL-61	"
has "9321: the scope-less worker still reads as unknown files on the header" "$r9" "live workers unknown"
r9o="$(NEXT_DISPATCH_MIRROR="$M9" NEXT_DISPATCH_GH_CMD="$WORK/gh" bash "$SUT" --resume-only --workers-from "$WORK/fleet9.json" 2>/dev/null)"
has "9321: --resume-only with a scope-less live worker lists the orphan" "$r9o" "RESUME	HIMMEL-60"
lacks "9321: --resume-only with a scope-less live worker drops the ticket it owns" "$r9o" "HIMMEL-61	"
printf '{"schema":1,"workers":[{"doc":"%s","label":"N10"},{"doc":"%s/HIMMEL-62-N11-gone.md","label":"N11"}]}\n' "$NOSCOPE9" "$WORK" > "$WORK/fleet9b.json"
r9b="$(NEXT_DISPATCH_MIRROR="$M9" NEXT_DISPATCH_GH_CMD="$WORK/gh" bash "$SUT" --resume-only --workers-from "$WORK/fleet9b.json" 2>/dev/null)"
lacks "9335 flip311: a worker doc that cannot be read withholds the orphan too (N1 sets owners_unknown)" "$r9b" "RESUME	HIMMEL-60"
lacks "9321: a worker doc that cannot be read still owns the key in its name" "$r9b" "HIMMEL-62	"
# a scope-less worker owns every full key on its Ticket lines and its description, and the title keys of the predecessor doc it names
M_SAVE="$M"; M="$M9"
mk HIMMEL-66 "In Progress" Medium '[]' '[]' '[]' "paren title: the head key" "Edit scripts/lib/p1.sh."
mk HIMMEL-67 "In Progress" Medium '[]' '[]' '[]' "paren title: first plus-key" "Edit scripts/lib/p2.sh."
mk HIMMEL-68 "In Progress" Medium '[]' '[]' '[]' "paren title: second plus-key" "Edit scripts/lib/p3.sh."
mk HIMMEL-69 "In Progress" Medium '[]' '[]' '[]' "predecessor title: kept" "Edit scripts/lib/p4.sh."
mk HIMMEL-70 "In Progress" Medium '[]' '[]' '[]' "predecessor title: dropped by the resume" "Edit scripts/lib/p5.sh."
mk HIMMEL-72 "In Progress" Medium '[]' '[]' '[]' "named on a Ticket line only" "Edit scripts/lib/p6.sh."
mk HIMMEL-73 "IN CI" Medium '[]' '[]' '[]' "named on a Ticket line only, in CI" "Edit scripts/lib/p7.sh."
mk HIMMEL-74 "In Progress" Medium '[]' '[]' '[]' "named on the description line only" "Edit scripts/lib/p8.sh."
mk HIMMEL-75 "In Progress" Medium '[]' '[]' '[]' "named on a Ticket line of a worker that has a Writes line" "Edit scripts/lib/p9.sh."
mk HIMMEL-76 "In Progress" Medium '[]' '[]' '[]' "unrelated orphan beside the widened owners" "Edit scripts/lib/p10.sh."
M="$M_SAVE"
PAREN9="$WORK/HIMMEL-66-N13-paren-RESUME.md"; printf '# RESUME — HIMMEL-66 (+67, +68) — worker N13\n\nno scope named here\n' > "$PAREN9"
PRED9="$WORK/HIMMEL-69-N14-pred-2026-11-05.md"; printf '# bundle — HIMMEL-69 / 70 — worker N14\n' > "$PRED9"
SUCC9="$WORK/HIMMEL-69-N14b-pred-2026-11-05-RESUME.md"; printf '# RESUME — HIMMEL-69 — worker N14b\n\n> **Prior art:** the original doc HIMMEL-69-N14-pred-2026-11-05.md (contract, scope).\n' > "$SUCC9"
TKT9="$WORK/HIMMEL-71-N15-ticket-line-2026-11-05.md"; printf '# N15 resume\n\n## Identity\n\nTicket HIMMEL-71 with HIMMEL-72, HIMMEL-73; HIMMEL-77 stays open for acceptance.\n' > "$TKT9"
DESC9="$WORK/HIMMEL-78-N16-desc-2026-11-05.md"; printf -- '---\ndescription: Resume of N16 (HIMMEL-78), prior art HIMMEL-74.\n---\n\n# N16 resume\n' > "$DESC9"
WR9="$WORK/HIMMEL-79-N17-writes-2026-11-05.md"; printf '# N17\n> **Writes:** scripts/lib/other9.sh\nTicket HIMMEL-79 with HIMMEL-75.\n' > "$WR9"
printf '{"schema":1,"workers":[{"doc":"%s","label":"N13"},{"doc":"%s","label":"N14b"},{"doc":"%s","label":"N15"},{"doc":"%s","label":"N16"},{"doc":"%s","label":"N17"}]}\n' "$PAREN9" "$SUCC9" "$TKT9" "$DESC9" "$WR9" > "$WORK/fleet9d.json"
r9d="$(NEXT_DISPATCH_MIRROR="$M9" NEXT_DISPATCH_GH_CMD="$WORK/gh" bash "$SUT" --resume-only --top 40 --workers-from "$WORK/fleet9d.json" 2>/dev/null)"
has "9321: widened owners still let an unrelated orphan list as RESUME" "$r9d" "RESUME	HIMMEL-76"
lacks "9321: a parenthesised title owns its first +key" "$r9d" "HIMMEL-67	"
lacks "9321: a parenthesised title owns its second +key" "$r9d" "HIMMEL-68	"
lacks "9321: a resume owns the sibling its predecessor doc title named and the resume dropped" "$r9d" "HIMMEL-70	"
lacks "9321: a scope-less worker owns a sibling named on its Ticket line only" "$r9d" "HIMMEL-72	"
lacks "9321: a scope-less worker owns a sibling named on its Ticket line only (IN CI)" "$r9d" "HIMMEL-73	"
lacks "9321: a scope-less worker owns a key named on its description line" "$r9d" "HIMMEL-74	"
has "9321: a worker that has a Writes line does not own the keys on its Ticket line" "$r9d" "RESUME	HIMMEL-75"
SIBM9="$WORK/m9sib"; mkdir -p "$SIBM9"
SIBDOC9="$SIBM9/HIMMEL-71-N15-ticket-line-2026-11-05.md"; cp "$TKT9" "$SIBDOC9"
SIBPRED9="$SIBM9/HIMMEL-69-N14-pred-2026-11-05.md"; cp "$PRED9" "$SIBPRED9"
SIBSUCC9="$SIBM9/HIMMEL-69-N14b-pred-2026-11-05-RESUME.md"; cp "$SUCC9" "$SIBSUCC9"
SIBPAREN9="$SIBM9/HIMMEL-66-N13-paren-RESUME.md"; cp "$PAREN9" "$SIBPAREN9"
printf '{"schema":1,"workers":[{"doc":"%s","label":"N15"},{"doc":"%s","label":"N14b"},{"doc":"%s","label":"N13"}]}\n' "$SIBDOC9" "$SIBSUCC9" "$SIBPAREN9" > "$SIBM9/HIMMEL-nextleg-2026-11-05MA-roadmap-chief.fleet.json"
printf '{"schema":1,"workers":[]}\n' > "$SIBM9/HIMMEL-nextleg-2026-11-05MB-roadmap-chief.fleet.json"
r9s="$(NEXT_DISPATCH_MIRROR="$M9" NEXT_DISPATCH_GH_CMD="$WORK/gh" bash "$SUT" --resume-only --top 40 --workers-from "$SIBM9/HIMMEL-nextleg-2026-11-05MB-roadmap-chief.fleet.json" 2>/dev/null)"
has "9321: a sibling chief's widened owners still let an unrelated orphan list" "$r9s" "RESUME	HIMMEL-76"
lacks "9321: a sibling chief's parenthesised title owns its +key" "$r9s" "HIMMEL-68	"
lacks "9321: a sibling chief's resume owns the key its predecessor title named" "$r9s" "HIMMEL-70	"
lacks "9321: a sibling chief's scope-less worker owns a Ticket-line sibling" "$r9s" "HIMMEL-73	"
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
printf '4242\tfix(x): an outside change to a held file\tcontributor/pr-held\ttrue\t2026-01-01T00:00:00Z\n4243\tfix(x): [HIMMEL-7] already started\tfix/himmel-7-started\n4244\tfix(x): [HIMMEL-52] in review\tfix/himmel-52-y\n' > "$PRS_TSV"

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
has "the RESUME row carries the resume brief" "$(printf '%s\n' "$rw" | grep "$KP-60	")" "brief=/x/HIMMEL-60-RESUME.md"
lacks "a wrapped To Do is never also an ordinary To Do row" "$rw" "LOCAL	HIMMEL-60"
lacks "a held wrapped To Do is not offered" "$rw" "HIMMEL-62	"
lacks "a ticket whose Done write is pending is never a RESUME row" "$rw" "HIMMEL-63	"
has "a wrapped To Do without a brief stays an ordinary To Do row" "$rw" "LOCAL	HIMMEL-64"
lacks "a To Do ticket whose contract=yes merge is recorded is never dispatched" "$rw" "HIMMEL-65	"
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
for nf_lib in env_alias.py fleet_runtime.py gh-quota.sh gh-graphql-budget.sh prim.sh timeout-bin.sh canon-path.sh pr_remainder.py; do
    cp "$(dirname "$SUT")/../../lib/$nf_lib" "$NF/scripts/lib/$nf_lib"
done
cp "$SUT" "$NF/scripts/handover/chief-kit/next-dispatchable.sh"
cp "$HERE/proof_staging.py" "$NF/scripts/handover/chief-kit/proof_staging.py"
env -u HIMMEL_QUOTA_DIR NEXT_DISPATCH_MIRROR="$M6" NEXT_DISPATCH_GH_CMD="$WORK/gh" bash "$NF/scripts/handover/chief-kit/next-dispatchable.sh" --no-classify >/dev/null 2>&1; nf_rc=$?
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
mk HIMMEL-110 "To Do" Low '["must-v1.0.1"]' '[]' '[]' "tier1 by label" "Edit scripts/lib/q7.sh only."
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
o7b="$(run7 --doc "$CDOC" --priority-pool-only --owners "$KP-999" | grep -v '^#' | cut -f2 | paste -sd, -)"
[ "$o7b" = "HIMMEL-112,HIMMEL-111,HIMMEL-110,HIMMEL-120,HIMMEL-131,HIMMEL-130,HIMMEL-140" ] && pass "--priority-pool-only lists tiers 1-4 only: the rest of the earliest version follows tier 3, a later version stays out" || fail "pool-only is '$o7b'"
lacks "--priority-pool-only prints no RESUME row" "$(run7 --doc "$CDOC" --priority-pool-only)" "RESUME"$'\t'
printf '# chief\n\n## Live state\n\n**priority:** K1 | 112 SCORECARD | 111 113 (CLOUD) | [PR 170] since 10.171\nqueue: none\n' > "$WORK/chief-doc-bold.md"
o7d="$(run7 --doc "$WORK/chief-doc-bold.md" --priority-pool-only --owners "$KP-999" | grep -v '^#' | cut -f2 | paste -sd, -)"
[ "$o7d" = "HIMMEL-112,HIMMEL-111,HIMMEL-110,HIMMEL-120,HIMMEL-131,HIMMEL-130,HIMMEL-140" ] && pass "a bold **priority:** line with '113 (CLOUD)' and bracketed or dotted numbers ranks as written" || fail "bold-line pool is '$o7d'"
o7c="$(run7 --priority-pool-only --owners "$KP-999" |grep -v '^#' | cut -f2 | paste -sd, -)"
[ "$o7c" = "HIMMEL-110,HIMMEL-120,HIMMEL-131,HIMMEL-130,HIMMEL-140" ] && pass "without --doc the pool is the labels, tiers 2-3 and the rest of the earliest version" || fail "no-doc pool is '$o7c'"
# the tier-1 must label follows the current version: with v2.0.0 current, must-v2.0.0 is tier 1; must-v1.1.3 and a later version's label are not
M31="$WORK/jira-mirror31/HIMMEL"; mkdir -p "$M31"
M_SAVE="$M"; M="$M31"
mk HIMMEL-310 "To Do" Low '["must-v2.0.0"]' '[]' '[]' "must label of the current version" "Edit scripts/lib/m1.sh only."
mk HIMMEL-311 "To Do" Low '["must-v1.1.3"]' '[]' '[]' "must label of another version" "Edit scripts/lib/m2.sh only."
mk HIMMEL-312 "To Do" Low '["must-v2.0.1"]' '[]' '[]' "must label of a later version" "Edit scripts/lib/m3.sh only."
M="$M_SAVE"
printf 'v2.0.0\tfalse\t\nv2.0.1\tfalse\t\n' > "$WORK/jira-mirror31/HIMMEL.versions.tsv"
o31="$(NEXT_DISPATCH_MIRROR="$M31" NEXT_DISPATCH_GH_CMD="$WORK/gh" NEXT_DISPATCH_CLASSIFY_CMD="$WORK/classify2" bash "$SUT" --priority-pool-only --owners "$KP-999" 2>/dev/null | grep -v '^#' | cut -f2 | paste -sd, -)"
[ "$o31" = "HIMMEL-310" ] && pass "only the must label of the current version is tier 1; another version's must label stays out of the pool" || fail "must-label pool is '$o31'"
M8="$WORK/jira-mirror8/HIMMEL"; mkdir -p "$M8"
M_SAVE="$M"; M="$M8"
mk HIMMEL-160 "To Do" Highest '[]' '["v1.0.1"]' '[]' "only tier5" "Edit scripts/lib/w1.sh only."
M="$M_SAVE"
e8="$(NEXT_DISPATCH_MIRROR="$M8" NEXT_DISPATCH_GH_CMD="$WORK/gh" NEXT_DISPATCH_CLASSIFY_CMD="$WORK/classify2" bash "$SUT" --priority-pool-only --owners "$KP-999" 2>/dev/null)"; e8_rc=$?
[ "$e8_rc" = 0 ] && pass "an empty pool exits 0" || fail "empty pool rc=$e8_rc"
has "an empty pool prints POOL-EMPTY" "$e8" "POOL-EMPTY"
lacks "an empty pool prints no dispatchable ticket row" "$(printf '%s\n' "$e8" | grep -v '^NEXT-TIER')" "HIMMEL-160"
M9="$WORK/jira-mirror9/HIMMEL"; mkdir -p "$M9"
M_SAVE="$M"; M="$M9"
mk HIMMEL-20 "To Do" Low '["operator-directed"]' '[]' '[]' "pool ticket the classifier blocks" "Edit scripts/lib/w2.sh only."
M="$M_SAVE"
e9="$(NEXT_DISPATCH_MIRROR="$M9" NEXT_DISPATCH_GH_CMD="$WORK/gh" NEXT_DISPATCH_CLASSIFY_CMD="$WORK/classify2" bash "$SUT" --priority-pool-only --owners "$KP-999" 2>/dev/null)"
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
mk HIMMEL-420 "In Progress" Low '["must-v1.0.1"]' '[]' '[]' "only a worker-less pool ticket" "Edit scripts/lib/t1.sh only."
M="$M_SAVE"
printf 'v1.0.1\tfalse\t\n' > "$WORK/jira-mirror12/HIMMEL.versions.tsv"  # the must label names the current version, so the mirror needs one
x12="$(NEXT_DISPATCH_MIRROR="$M12" NEXT_DISPATCH_GH_CMD="$WORK/gh" NEXT_DISPATCH_CLASSIFY_CMD="$WORK/classify2" bash "$SUT" --priority-pool-only --owners "$KP-999" 2>/dev/null)"
has "pool-only: a worker-less pool ticket alone is a RESUME row" "$x12" "RESUME	HIMMEL-420"
lacks "pool-only: a pool with only a RESUME row is not POOL-EMPTY" "$x12" "POOL-EMPTY"
n12="$(NEXT_DISPATCH_MIRROR="$M12" NEXT_DISPATCH_GH_CMD="$WORK/gh" NEXT_DISPATCH_CLASSIFY_CMD="$WORK/classify2" bash "$SUT" --priority-pool-only 2>"$WORK/n12.err")"
lacks "pool-only: no worker source (no --owners, no --workers-from) offers no RESUME row" "$n12" "RESUME"$'\t'
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
mk HIMMEL-421 "In Progress" Low '["must-v1.0.1"]' '[]' '[]' "port the hook to powershell" "Edit scripts/lib/u1.sh only."
mk HIMMEL-422 "In Progress" Low '["must-v1.0.1","residual-depth-1"]' '[]' '[]' "a residual one" "Edit scripts/lib/u2.sh only."
mk HIMMEL-423 "In Progress" Low '["must-v1.0.1"]' '[]' '[]' "an ordinary pool ticket" "Edit scripts/lib/u3.sh only."
M="$M_SAVE"
printf 'v1.0.1\tfalse\t\n' > "$WORK/jira-mirror13/HIMMEL.versions.tsv"  # the must label names the current version, so the mirror needs one
f13="$(NEXT_DISPATCH_MIRROR="$M13" NEXT_DISPATCH_GH_CMD="$WORK/gh" NEXT_DISPATCH_CLASSIFY_CMD="$WORK/classify2" bash "$SUT" --priority-pool-only --owners "$KP-999" 2>/dev/null)"
lacks "pool-only: a dropped-platform In Progress ticket is not a RESUME row" "$f13" "HIMMEL-421"
lacks "pool-only: a residual-depth In Progress ticket is not a RESUME row" "$f13" "HIMMEL-422"
has "pool-only: an ordinary worker-less pool ticket is still a RESUME row" "$f13" "RESUME	HIMMEL-423"

# --- pool depth: --top is the free-slot count; a pool short of it says LOW, and
# an empty pool names the next-tier candidates (tier 5, rank order unchanged)
# on NEXT-TIER rows a dispatcher reading ticket rows never picks up.
has "a pool shorter than the free slots prints pool=<n>/<slots>,LOW" "$(run7 --doc "$CDOC" --priority-pool-only --owners "$KP-999" --top 8)" "pool=7/8,LOW"
p10="$(run7 --doc "$CDOC" --priority-pool-only --owners "$KP-999" --top 4)"
has "a pool that fills the slots prints pool=<n>/<slots>" "$p10" "pool=4/4"
lacks "a pool that fills the slots is not LOW" "$p10" "LOW"
e10="$(NEXT_DISPATCH_MIRROR="$M8" NEXT_DISPATCH_GH_CMD="$WORK/gh" NEXT_DISPATCH_CLASSIFY_CMD="$WORK/classify2" bash "$SUT" --priority-pool-only --owners "$KP-999" --top 8 2>/dev/null)"
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
o30="$(run30 --doc "$WORK/chief-doc30.md" --priority-pool-only --owners "$KP-806" --top 7 --dispositions)"
r30="$(printf '%s\n' "$o30" | grep -v '^#' | grep -v '^POOL-EMPTY' | cut -f1,2 | tr '\t' ':' | paste -sd, -)"
[ "$r30" = "LOCAL:HIMMEL-803,LOCAL:HIMMEL-801" ] && pass "(8134) an unlabelled current-version To Do ticket is a pool row after the labelled one, with an empty priority line" || fail "(8134) pool is '$r30'"
lacks "(8134) the current-version ticket is not dropped as outside the priority pool" "$(printf '%s\n' "$o30" | grep "^# disposition $KP-801 ")" "outside the priority pool"
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
seed HIMMEL-97 N9 "$LEGB" scripts/lib/own-scope.sh
f1="$(run20)"
has "fix1: a ticket on a WRAPPED worker's file is listed" "$f1" "HIMMEL-701	"
has "fix1: a ticket on a file named only in READ ONLY prose is listed" "$f1" "HIMMEL-702	"
has "fix1: a ticket on a live worker's write scope is held: listed, its shared file an overlap" "$f1" "# overlap HIMMEL-703 "
has "fix1: a ticket on a file after Other live workers is listed" "$f1" "HIMMEL-704	"
# the register holds files, not trees, so a directory a worker only describes holds nothing (assertion flipped from lacks)
has "fix1: a directory a worker describes in prose is a note, not a held file" "$f1" "HIMMEL-705	"
# shellcheck disable=SC2016
printf '# parked\n> **Scope / do not:** writes confined to `scripts/lib/wrapped-held.sh`.\n\n## Results\n- 10:00 LIVE - go\n- 12:00 WRAPPED - merged\n- 13:00 PARKED-USAGE - relaunched, waiting for RESUME\n' > "$LEGW"
seed HIMMEL-98 N8 "$LEGW" scripts/lib/wrapped-held.sh  # the parked worker's launch row; the wrapped step above held nothing
has "a PARKED-USAGE tail after an old WRAPPED still holds the worker's files: listed, its shared file an overlap" "$(run20)" "# overlap HIMMEL-701 "

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
f3="$(run22 --priority-pool-only --owners "$KP"-999)"
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
has "overlap: a concrete file in a live worker's write scope is listed, not held" "$v1" "HIMMEL-4	"
has "overlap: and the live worker's file is printed" "$v1" "# overlap HIMMEL-4 scripts/handover/chief-kit/live-file.sh with live worker N1"
has "overlap: a concrete file equal to an open PR's file is listed, not held" "$v1" "HIMMEL-3	"
has "overlap: and the open PR's file is printed" "$v1" "# overlap HIMMEL-3 scripts/lib/pr-held.sh with open PR 4242"
has "drops: a per-reason summary of the active version is printed" "$v1" "# dropped from v1.0.1:"
w1="$(run30 --why)"
has "why: an overlap names the file and its holder, and where the scope came from" "$w1" "# overlap HIMMEL-3 scripts/lib/pr-held.sh with open PR 4242 (from description)"
has "why: a worker overlap names the worker" "$w1" "# overlap HIMMEL-4 scripts/handover/chief-kit/live-file.sh with live worker N1 (from description)"
has "why: an open blocker is named" "$w1" "# drop HIMMEL-8 blocker HIMMEL-801"
has "why: an exclusion label is named" "$w1" "# drop HIMMEL-5 label operator-decision"
has "why: a type is named" "$w1" "# drop HIMMEL-807 type Epic"
has "why: a residual depth is named" "$w1" "# drop HIMMEL-803 residual-depth 1"
has "why: a classification refusal is named" "$w1" "# drop HIMMEL-10 classification BLOCKED"
has "why: an open-PR owner is named" "$w1" "# drop HIMMEL-52 owned by open PR"
has "why: a live-worker owner is named" "$w1" "# drop HIMMEL-99 owned by live worker"
lacks "why: without --why no per-ticket line is printed" "$v1" "# drop HIMMEL-"
printf 'scripts/lib/Brewfile\n' > "$WORK/held30.txt"
has "overlap: a new extensionless file equal to a held path is listed with the overlap" "$(run30 --held "$WORK/held30.txt")" "# overlap HIMMEL-810 scripts/lib/Brewfile with held list"

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
has "replay: a ticket the 'Do not touch' fence of a live worker hid is offered" "$rp" "HIMMEL-6034	"
# a directory scope is a note, not a register row (assertion flipped from lacks)
has "replay: a directory-wide scope described in parentheses is a note, not a held file" "$rp" "HIMMEL-6485	"
lacks "replay: a ticket whose key is a live worker's is not offered" "$rp" "HIMMEL-4999	"
has "replay: a ticket really held by a live worker stays held: listed, its shared file an overlap" "$rp" "# overlap HIMMEL-6484 "
n113="$(printf '%s\n' "$rp" | grep -c "	v1.1.3	")"
[ "$n113" -ge 5 ] && pass "replay: at least 5 v1.1.3 rows ($n113)" || fail "replay: at least 5 v1.1.3 rows (got $n113)"

# --- the real version list: archived unreleased versions (v1.0.3b ...) sort before v1.1.3 but are not the first version ---
M24="$WORK/jira-mirror24/HIMMEL"; mkdir -p "$M24"
M_SAVE="$M"; M="$M24"
mk HIMMEL-740 "To Do" Medium '["operator-directed"]' '["v1.1.3"]' '[]' "directed in the first live version" "Edit scripts/lib/t6a.sh only."
mk HIMMEL-741 "To Do" Medium '["operator-directed"]' '["v1.1.4"]' '[]' "directed in a later live version" "Edit scripts/lib/t6b.sh only."
M="$M_SAVE"
cp "$RP/mirror/HIMMEL.versions.tsv" "$WORK/jira-mirror24/HIMMEL.versions.tsv"
f6="$(NEXT_DISPATCH_MIRROR="$M24" NEXT_DISPATCH_GH_CMD="$WORK/gh" bash "$SUT" --no-classify --priority-pool-only --owners "$KP"-999 2>/dev/null)"
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
seed HIMMEL-95 N5 "$LEGN" scripts/handover/nd-own.sh
seed HIMMEL-94 N4 "$LEGT" scripts/ci/suite-tiers.tsv scripts/ci/suite-durations.tsv
seed HIMMEL-93 N3 "$LEGU" scripts/ci/nd-touch-d.sh
f25="$(NEXT_DISPATCH_MIRROR="$M25" NEXT_DISPATCH_GH_CMD="$WORK/gh" bash "$SUT" --no-classify --workers-from "$WORK/fleet25.json" 2>/dev/null)"
has "never-edit: a ticket inside a 'Never edit' tree is offered" "$f25" "HIMMEL-750	"
has "never-edit: a ticket inside a 'Do NOT TOUCH' tree (verb in capitals too) is offered" "$f25" "HIMMEL-751	"
has "never-edit: a ticket inside a tree named only in a 'Touches <dir>, a trust-path pattern' note is offered" "$f25" "HIMMEL-752	"
has "never-edit: a ticket on the worker's own named file stays held: listed, its shared file an overlap" "$f25" "# overlap HIMMEL-753 "
has "never-edit: a file a 'Touches <file> ... pattern' sentence really writes stays held: listed, its shared file an overlap" "$f25" "# overlap HIMMEL-754 "

# --- a worker holds only the files it writes, not paths in a quoted grep or boilerplate ---
FX="$WORK/held-fx"; cp -r "$HERE/fixtures/held-paths" "$FX"
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
# the register, not each doc's scope prose, says what a worker writes: one launch row per file the old reader held (trees are noted, not held)
seed HIMMEL-7377 N3558 "$FX/HIMMEL-7377-N3558-adoption-trail-narrow-panel.md" docs/adoption-trail.html
seed HIMMEL-7469 N3579 "$FX/HIMMEL-7469-N3579-writes-line.md" docs/nd-writes-line.html scripts/handover/nd-writes-line.sh
seed HIMMEL-7469 N3580 "$FX/HIMMEL-7469-N3580-frontmatter-description.md" docs/nd-frontmatter.html
seed HIMMEL-7469 N3581 "$FX/HIMMEL-7469-N3581-command-word-in-path.md" scripts/handover/nd-find-tool.sh docs/nd-find.html
seed HIMMEL-7469 N3582 "$FX/HIMMEL-7469-N3582-prose-before-path.md" scripts/nd-a.sh scripts/nd-b.sh scripts/nd-p.sh scripts/nd-d.sh
seed HIMMEL-7469 N3583 "$FX/HIMMEL-7469-N3583-writes-line-prose.md" scripts/nd-c.sh scripts/nd-e.sh
seed HIMMEL-7469 N3584 "$FX/HIMMEL-7469-N3584-writes-wrapped.md" scripts/nd-h.sh scripts/nd-i.sh
seed HIMMEL-7469 N3586 "$FX/HIMMEL-7469-N3586-command-segment.md" scripts/nd-y.sh
f26="$(NEXT_DISPATCH_MIRROR="$M26" NEXT_DISPATCH_GH_CMD="$WORK/gh" bash "$SUT" --no-classify --top 50 --workers-from "$WORK/fleet26.json" 2>"$WORK/f26.err")"
has "held-paths: N3558 still holds its one real file docs/adoption-trail.html: listed, its shared file an overlap" "$f26" "# overlap HIMMEL-860 "
has "held-paths: N3558's quoted 'grep -rl adoption-trail scripts/' does not hold scripts/check-ci.sh" "$f26" "HIMMEL-861	"
has "held-paths: N3543's 'Trust path (scripts/lib/)' note does not hold scripts/lib/" "$f26" "HIMMEL-862	"
has "held-paths: N3543's SINGLE-WRITER note holds nothing (the open PR holds that file)" "$f26" "HIMMEL-863	"
# a directory a worker writes in is a note, not a register row (assertion flipped from lacks, here and for 868 and 884)
has "held-paths: N3557's command dir is a note, not a held file" "$f26" "HIMMEL-864	"
has "held-paths: N3557's script dir is a note, not a held file" "$f26" "HIMMEL-865	"
has "held-paths: N3557's 'Impacted suites:' file is run, not written" "$f26" "HIMMEL-866	"
has "held-paths: N3557's 'find what the gitleaks gate or scripts/lib uses' read does not hold scripts/lib/" "$f26" "HIMMEL-867	"
has "held-paths: negative control: scripts/ci/ on a write list is a note, not a held file" "$f26" "HIMMEL-868	"
has "held-paths: negative control: the path that worker only greps is free" "$f26" "HIMMEL-869	"
has "held-paths: a worker with a Writes line holds the files on it: listed, its shared file an overlap" "$f26" "# overlap HIMMEL-870 "
has "held-paths: a worker with a Writes line holds nothing the scope line prose names" "$f26" "HIMMEL-871	"
has "held-paths: a front-matter description quoting 'writes confined to' holds nothing" "$f26" "HIMMEL-872	"
has "held-paths: that worker still holds the file on its real scope line: listed, its shared file an overlap" "$f26" "# overlap HIMMEL-873 "
has "held-paths: the file listed after a command-word name is still held: listed, its shared file an overlap" "$f26" "# overlap HIMMEL-875 "
has "held-paths: a command-word name does not hold its whole directory" "$f26" "HIMMEL-876	"
has "held-paths: a path after 'find and fix the caller in' prose on a scope line is held: listed, its shared file an overlap" "$f26" "# overlap HIMMEL-877 "
has "held-paths: a Writes line is never cleaned: a path after prose on it is held: listed, its shared file an overlap" "$f26" "# overlap HIMMEL-878 "
has "held-paths: this worker's own SINGLE-WRITER note holds the file it names: listed, its shared file an overlap" "$f26" "# overlap HIMMEL-879 "
has "held-paths: a bare 'grep -rl needle scripts/nd-read/' read holds nothing" "$f26" "HIMMEL-880	"
has "held-paths: a path on the continuation line of a wrapped Writes block is held: listed, its shared file an overlap" "$f26" "# overlap HIMMEL-881 "
has "held-paths: a path after a path segment named find is held: listed, its shared file an overlap" "$f26" "# overlap HIMMEL-882 "
has "held-paths: a path the front-matter description names (no command word before it) holds nothing" "$f26" "HIMMEL-883	"
has "held-paths: a find -delete dir is a note, not a held file" "$f26" "HIMMEL-884	"
# N3585 names no scope and has no row: its own run on a clean register (a key that has a row is read from the register, and the others above share one)
printf '{"schema":1,"legs":[{"doc":"%s","label":"N3585"}]}\n' "$FX/HIMMEL-7469-N3585-no-scope.md" > "$WORK/fleet26b.json"
f26b="$(NEXT_DISPATCH_MIRROR="$M26" NEXT_DISPATCH_GH_CMD="$WORK/gh" bash "$SUT" --no-classify --top 50 --workers-from "$WORK/fleet26b.json" 2>"$WORK/f26.err")"
has "held-paths: a live worker that yields no held paths is named on stderr" "$(cat "$WORK/f26.err")" "live worker N3585 yields no held paths"
has "held-paths: a live worker that yields no held paths makes the live workers unknown on the stdout header" "$f26b" "live workers unknown"
printf '{"schema":1,"legs":[{"doc":"%s","label":"N3587"}]}\n' "$FX/HIMMEL-7469-N3587-none-named.md" > "$WORK/fleet27.json"
f27="$(NEXT_DISPATCH_MIRROR="$M26" NEXT_DISPATCH_GH_CMD="$WORK/gh" bash "$SUT" --no-classify --top 50 --workers-from "$WORK/fleet27.json" 2>/dev/null)"
lacks "held-paths: an explicit 'Writes: none named' worker is a real empty scope, not unknown" "$f27" "live workers unknown"
has "held-paths: a path after 'replace grep -P in' is a write, not a read: listed, its shared file an overlap" "$f26" "# overlap HIMMEL-885 "


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
cp -r "$DD" "$WORK/dd-fx"
sed "s#@@FIXTURE@@#$WORK/dd-fx#" "$DD/fleet.json" > "$WORK/dd-fleet.json"
printf 'scripts/handover/chief-kit/dd-old.sh\nscripts/handover/chief-kit/dd-newn.sh\n' > "$WORK/dd-held.txt"
seed HIMMEL-7044 N3901 "$WORK/dd-fx/HIMMEL-7044-N3901-mentions.md" scripts/dd-own.sh  # its list also names scripts/dd-in/: a tree, noted and not held
rundd() { NEXT_DISPATCH_MIRROR="$MD" NEXT_DISPATCH_GH_CMD="$WORK/gh-dd" NEXT_DISPATCH_CLASSIFY_CMD="$WORK/classify-dd" NEXT_DISPATCH_JIRA_CMD="$WORK/jira-dd" bash "$SUT" --top 50 --held "$WORK/dd-held.txt" --workers-from "$WORK/dd-fleet.json" "$@" 2>"$WORK/dd.err"; }
dd_out="$(rundd --dispositions)"
# (c) the rename registry
has "dispositions: a pre-rename path overlaps its new spelling, naming the holder" "$dd_out" "# overlap HIMMEL-901 scripts/handover/console-kit/dd-old.sh with held list"
has "dispositions: the overlapping ticket is listed, not a collision class" "$dd_out" "# disposition HIMMEL-901 listed LOCAL"
has "dispositions: a new path overlaps the old spelling held" "$dd_out" "# overlap HIMMEL-903 scripts/handover/chief-kit/dd-newn.sh with held list"
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
# a directory on the list is a note, not a register row (assertion flipped from has collision)
lacks "scope: a directory on the list is a note, not a held file" "$dd_out" "# disposition HIMMEL-924 collision "
has "scope: a file on the list is an overlap, not a drop" "$dd_out" "# overlap HIMMEL-925 scripts/dd-own.sh with live worker"
# (e) one unreadable PR marks only itself unknown
has "prs: the PRs are read through the paginated files API" "$(cat "$DD_DIR/gh.args")" "api --paginate repos/yotamleo-org/Himmel/pulls/5001/files"
has "prs: the files of the PR before the unreadable one overlap" "$dd_out" "# overlap HIMMEL-930 scripts/lib/dd-pr1.sh with open PR 5001"
has "prs: the files of the PR after the unreadable one overlap" "$dd_out" "# overlap HIMMEL-931 scripts/lib/dd-pr3.sh with open PR 5003"
has "prs: a renamed file's previous name overlaps" "$dd_out" "# overlap HIMMEL-932 scripts/lib/dd-old-name.sh with open PR 5003"
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
has "prs: the unreadable PR is named overlap unknown" "$ddu_out" "# overlap unknown for PR 5002"
lacks "prs: one unreadable PR does not mark every open PR unknown" "$ddu_out" "open PRs unknown"
has "prs: the files of the PR before the unreadable one still overlap" "$ddu_out" "# overlap HIMMEL-930 scripts/lib/dd-pr1.sh with open PR 5001"
has "prs: the files of the PR after the unreadable one still overlap" "$ddu_out" "# overlap HIMMEL-931 scripts/lib/dd-pr3.sh with open PR 5003"
has "prs: RESUME rows are still listed while a PR's files are unreadable" "$ddu_out" "RESUME	HIMMEL-940"
has "prs: To Do rows are still listed while a PR's files are unreadable" "$ddu_out" "LOCAL	HIMMEL-902"
has "prs: a To Do row beside an unreadable PR is listed" "$ddu_out" "# disposition HIMMEL-902 listed LOCAL"
# a PR the API cuts short at 3000 files is unknown, not a silent truncation
export DD3K="$WORK/dd3k"; mkdir -p "$DD3K"
cp "$DD_DIR/live.txt" "$DD3K/live.txt"
printf '5101\tfix(x): [HIMMEL-9104] vast\tfix/himmel-9104-vast\n' > "$DD3K/prs.tsv"
seq 1 3000 | sed 's#^#scripts/lib/dd-vast-#' > "$DD3K/files-5101"
dd3k_out="$(DD_DIR="$DD3K" rundd --dispositions)" && pass "prs: the 3000-file run exits 0" || fail "prs: the 3000-file run failed"
has "prs: a PR listing 3000 files is named overlap unknown" "$dd3k_out" "# overlap unknown for PR 5101"
has "prs: a PR listing 3000 files does not suppress RESUME rows" "$dd3k_out" "RESUME	HIMMEL-940"
# (d) a disposition for every open ticket of the version
has "dispositions: a listed ticket says so" "$dd_out" "# disposition HIMMEL-902 listed LOCAL"
has "dispositions: a worker-less In Progress ticket is a RESUME row while every PR is readable" "$dd_out" "RESUME	HIMMEL-940"
has "dispositions: an in-progress ticket beside an unreadable PR is a listed RESUME row" "$ddu_out" "# disposition HIMMEL-940 listed RESUME"
has "dispositions: a label drop names the label" "$dd_out" "# disposition HIMMEL-951 label operator-decision"
dd_n="$(printf '%s\n' "$dd_out" | grep -c '^# disposition ')"
[ "$dd_n" = 21 ] && pass "dispositions: one line per open v1.0.1 ticket (21)" || fail "dispositions: $dd_n lines for 21 open v1.0.1 tickets"
ddu_n="$(printf '%s\n' "$ddu_out" | grep -c '^# disposition ')"
[ "$ddu_n" = 21 ] && pass "dispositions: an unreadable PR still leaves one line per ticket (21)" || fail "dispositions: $ddu_n lines with an unreadable PR, expected 21"
dd_plain="$(rundd)"
lacks "dispositions: a plain run prints none" "$dd_plain" "# disposition "


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
has "Writes note: the real file before the parenthetical still overlaps" "$note_out" "# overlap HIMMEL-9201 docs/nd-note-own.md with live worker N920"
has "Writes note: the real file after the parenthetical still overlaps" "$note_out" "# overlap HIMMEL-9204 docs/nd-note-after.md with live worker N920"
lacks "Writes note: a parenthetical directory produces no wide-hold warning" "$note_out" "# warn: N920 holds directory scripts/lib"
printf '%s\n' '> **Writes:** scripts/lib scripts/lib/' '> **Writes note:** docs/nd-note-own.md' > "$NOTE_WORKER"
note_wide="$(run --no-classify --workers-from "$WORK/fleet-note.json" --why)"
has "Writes note: a bare directory still overlaps its subtree" "$note_wide" "# overlap HIMMEL-9202 scripts/lib/nd-note-free.sh with live worker N920"
[ "$(printf '%s\n' "$note_wide" | grep -c '^# warn: N920 holds directory scripts/lib/$')" = 1 ] && pass "Writes note: --why warns once per held directory" || fail "Writes note: --why must warn once for scripts/lib/: $note_wide"
case "$note_wide" in "# source mirror_age_min="*) pass "Writes note: the age header comes before the directory warning" ;; *) fail "Writes note: the age header is not first (got: ${note_wide%%$'\n'*})" ;; esac
lacks "Writes note: normal output has no directory warning" "$(run --no-classify --workers-from "$WORK/fleet-note.json")" "# warn: N920 holds directory"
printf '%s\n' '> **Writes:** none named' '> **Writes note:** writes confined to scripts/lib/.' > "$NOTE_WORKER"
note_empty="$(run --no-classify --workers-from "$WORK/fleet-note.json" --why)"
has "Writes note: an explicit empty Writes ignores note paths" "$note_empty" "LOCAL?	HIMMEL-9202"
lacks "Writes note: an explicit empty Writes is not unknown" "$note_empty" "live workers unknown"
printf '%s\n' '> **Scope / do not:** writes confined to docs/nd-note-own.md.' '> **Writes note:** writes confined to scripts/lib/.' > "$NOTE_WORKER"
seed HIMMEL-9299 N920 "$NOTE_WORKER" docs/nd-note-own.md  # the scope-line shape is not parsed any more: the register carries what the older brief named
note_legacy="$(run --no-classify --workers-from "$WORK/fleet-note.json" --why)"
has "Writes note: a note is ignored in the older-brief fallback too" "$note_legacy" "LOCAL?	HIMMEL-9202"
has "Writes note: the older-brief fallback still overlaps its own file" "$note_legacy" "# overlap HIMMEL-9201 docs/nd-note-own.md with live worker N920"

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
dispo_out="$(run --no-classify --priority-pool-only --owners "$KP-999" --dispositions)"; dispo_rc=$?
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
check "the full pass exits 0" "0" "$rh_full_rc"
has "a RESUME row a live worker's scope names gets an overlap line" "$rh_full" "# overlap HIMMEL-80 scripts/lib/rh1.sh with live worker N8"
has "a RESUME row another listed RESUME row names gets an overlap line" "$rh_full" "# overlap HIMMEL-82 scripts/lib/rh2.sh with listed HIMMEL-81"
has "a RESUME row a live worker's scope names is still offered as RESUME" "$rh_full" "RESUME	HIMMEL-80"
has "a RESUME row a listed ticket names is still offered as RESUME" "$rh_full" "RESUME	HIMMEL-82"
has "the free RESUME row is still offered" "$rh_full" "RESUME	HIMMEL-81"
rh_only="$(rh --resume-only)"; rh_only_rc=$?
check "--resume-only exits 0" "0" "$rh_only_rc"
has "--resume-only prints the worker overlap on the RESUME row too" "$rh_only" "# overlap HIMMEL-80 scripts/lib/rh1.sh with live worker N8"

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
oi="$(runi --priority-pool-only --owners "$KP-999" --top 7)"; oi_rc=$?
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
on="$(runn --priority-pool-only --owners "$KP-999" --top 7)"
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
pp="$(runs "$UI" 1 --priority-pool-only --owners "$KP-999" --top 5)"
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
has "(8349) flag off prints the second as an overlap with the head" "$off" "# overlap HIMMEL-802 scripts/config-ui/app.js with listed HIMMEL-801"
has "(8349) flag off prints the third as an overlap with the head" "$off" "# overlap HIMMEL-803 scripts/config-ui/app.js with listed HIMMEL-801"

# the cap holds at 4
newmir cap
for n in 811 812 813 814 815; do mk "HIMMEL-$n" "To Do" High '[]' '["v1.0.1"]' '[]' "cap $n" "Edit scripts/lib/cap.sh now."; done
cp_="$(runs "$M" 1 --why)"
has "(8349) a series stops at 4 items" "$cp_" "SERIES${TAB}LOCAL${TAB}HIMMEL-811,HIMMEL-812,HIMMEL-813,HIMMEL-814${TAB}"
has "(8349) the fifth sharing ticket is listed with an overlap line" "$cp_" "# overlap HIMMEL-815 scripts/lib/cap.sh with "

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
has "(8349) a candidate sharing a file with two series prints an overlap" "$tw" "# overlap HIMMEL-825 "
lacks "(8349) a candidate colliding with two series joins neither" "$tw" "HIMMEL-821,HIMMEL-822,HIMMEL-825"

# a later-version ticket never rides an earlier version's series
newmir ver
mk HIMMEL-831 "To Do" High '[]' '["v1.0.1"]' '[]' "now" "Edit scripts/lib/z.sh now."
mk HIMMEL-832 "To Do" High '[]' '["v1.0.2"]' '[]' "later" "Edit scripts/lib/z.sh now."
vr="$(runs "$M" 1 --why)"
lacks "(8349) a later-version ticket does not join" "$vr" "SERIES"
has "(8349) a later-version ticket lists on its own row" "$vr" "HIMMEL-832${TAB}"
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
printf '{"schema":1,"legs":[{"doc":"%s","label":"N5\\u0007"}]}\n' "$WORK/HIMMEL-790-N5-series.md" > "$WORK/fleet-sc.json"
has "10557 R8: a series worker whose label carries a control character is still STACKABLE" "$(runs "$SM" 1 --workers-from "$WORK/fleet-sc.json")" "STACKABLE HIMMEL-851 $WORK/HIMMEL-790-N5-series.md"
has "(8349) a free ticket still lists beside a series worker" "$st" "LOCAL${TAB}HIMMEL-853${TAB}"
has "(8349) a candidate also named by an open PR prints an overlap" "$st" "# overlap HIMMEL-852 "
lacks "(8349) a candidate also held by an open PR is not STACKABLE" "$st" "STACKABLE HIMMEL-852"
stoff="$(runs "$SM" 0 --workers-from "$WORK/fleet-s.json" --why)"
lacks "(8349) flag off prints no STACKABLE row" "$stoff" "STACKABLE"
has "(8349) flag off prints the overlap with the live worker" "$stoff" "# overlap HIMMEL-851 scripts/config-ui/app.js with live worker N5"

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
has "(8349) an unreadable-count series worker still overlaps the file" "$se" "# overlap HIMMEL-851 scripts/config-ui/app.js with live worker N9"
sr="$(runs "$SM" 1 --workers-from "$WORK/fleet-s.json" --priority-pool-only --resume-only)"
lacks "(8349) --priority-pool-only --resume-only lists no STACKABLE row" "$sr" "STACKABLE"

mkdoc "$WORK/HIMMEL-791-N6-plain.md" 0 ""
mkfleet "$WORK/fleet-plain.json" "N6:$WORK/HIMMEL-791-N6-plain.md"
sp="$(runs "$SM" 1 --workers-from "$WORK/fleet-plain.json" --why)"
lacks "(8349) a collision with a non-series live worker is not STACKABLE" "$sp" "STACKABLE"
has "(8349) a non-series live worker prints an overlap" "$sp" "# overlap HIMMEL-851 scripts/config-ui/app.js with live worker N6"

mkdoc "$WORK/HIMMEL-792-N7-full.md" 4 ""
mkfleet "$WORK/fleet-full.json" "N7:$WORK/HIMMEL-792-N7-full.md"
sf="$(runs "$SM" 1 --workers-from "$WORK/fleet-full.json" --why)"
lacks "(8349) a full (4/4) series worker takes no STACKABLE" "$sf" "STACKABLE"
has "(8349) a full series worker still overlaps the file" "$sf" "# overlap HIMMEL-851 scripts/config-ui/app.js with live worker N7"

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
lacks "(8436) inactivity alone cannot clear unknown sibling ownership" "$b8s" "RESUME${TAB}HIMMEL-53${TAB}"
# malformed sibling manifests never break the read: a list, entries that are not objects, a null or numeric doc, a doc-less entry
touch "$W53"
printf '{"schema":1,"workers":["N1",{"doc":null,"label":"N2"},{"doc":5,"label":"N3"},{"label":"N4"}]}\n' > "$C8/HIMMEL-nextleg-2026-10-31MD-roadmap-chief.fleet.json"
b8m="$(run8 "$C8/HIMMEL-nextleg-2026-10-31MB-roadmap-chief.fleet.json" --top 20)"
has "(8436) malformed sibling manifests do not stop the list" "$b8m" "${TAB}HIMMEL-57${TAB}"
lacks "(8436) a good sibling still holds its ticket beside malformed ones" "$b8m" "RESUME${TAB}HIMMEL-53${TAB}"
b8a="$(NEXT_DISPATCH_SIBLING_MAX_AGE_MIN=abc run8 "$C8/HIMMEL-nextleg-2026-10-31MB-roadmap-chief.fleet.json" --top 20)"
has "(8436) a non-integer sibling age window does not stop the list" "$b8a" "${TAB}HIMMEL-57${TAB}"
lacks "(8436) a non-integer sibling age window reads as the default" "$b8a" "RESUME${TAB}HIMMEL-53${TAB}"
# a worker of the other chief owns every ticket its doc title names, not only the one in its file name
M_SAVE="$M"; M="$M8"
mk HIMMEL-58 "In Progress" High '[]' '["v1.0.1"]' '[]' "bundle sibling of a chief A worker" "Edit scripts/lib/r9.sh only."
M="$M_SAVE"
W59="$C8/HIMMEL-59-N12-bundle-2026-10-31.md"
printf '# bundle — HIMMEL-59 / 58\n> **Writes:** scripts/lib/r10.sh\n' > "$W59"
mkfleet "$C8/HIMMEL-nextleg-2026-10-31MF-roadmap-chief.fleet.json" "N12:$W59"
b8t="$(run8 "$C8/HIMMEL-nextleg-2026-10-31MB-roadmap-chief.fleet.json" --top 20 --resume-only)"
lacks "a worker of the other chief owns the sibling its doc title names" "$b8t" "RESUME${TAB}HIMMEL-58${TAB}"

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
has "(8349 S1b) F3: a committed item still overlaps its file after the predecessor WRAPPED" "$lg1" "# overlap HIMMEL-871 scripts/config-ui/app.js with series s1"
has "(8349 S1b) F3: the overlapping candidate still has its dispatch row" "$lg1" "LOCAL${TAB}HIMMEL-871${TAB}"
has "(8349 S1b) a ticket the ledger does not hold still lists" "$lg1" "LOCAL${TAB}HIMMEL-872${TAB}"
has "(8349 S1b) F4 hold-end: a published item whose PR gh reports merged holds nothing" "$lg1" "LOCAL${TAB}HIMMEL-873${TAB}"
has "(8349 S1b) a published item whose PR is open keeps overlapping" "$lg1" "# overlap HIMMEL-874 scripts/lib/open-l.sh with series s1"
has "(8349 S1b) a published item gh knows no PR for keeps overlapping" "$lg1" "# overlap HIMMEL-875 scripts/lib/nopr-l.sh with series s1"
has "(8349 S1b) an abandoned item holds nothing" "$lg1" "LOCAL${TAB}HIMMEL-876${TAB}"
has "(8349 S1b) a published item whose PR gh reports closed holds nothing" "$lg1" "LOCAL${TAB}HIMMEL-877${TAB}"
has "(8349 S1b) a PR beyond gh's default 30 results still overlaps the file" "$lg1" "# overlap HIMMEL-878 scripts/lib/many-l.sh with series s1"
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
has "(8529) a full series still prints the file overlap" "$s85c" "# overlap HIMMEL-851 "
led set --ledger "$SL" --key HIMMEL-9204 state=abandoned
s85d="$(runl 1 "$S85" "$B/fleet.json" --why)"
has "(8529) an abandoned item frees a seat" "$s85d" "STACKABLE HIMMEL-851 $SW"
# a worker whose Series line names its sid reads only that ledger: a stale ledger naming the same doc as writer neither joins it nor sets its count
M="$S85"; mk HIMMEL-855 "To Do" High '[]' '["v1.0.1"]' '[]' "wants a file only the stale ledger holds" "Edit scripts/lib/stale-85.sh."
led create --ledger "$B/series/stale.json" --sid stale --completes-ticket no --writer "$SW"
led add-item --ledger "$B/series/stale.json" --key HIMMEL-9206 --writes scripts/lib/stale-85.sh --state committed
s85g="$(runl 1 "$S85" "$B/fleet.json" --why)"
has "(8529) the named ledger still gives STACKABLE with a stale ledger beside it" "$s85g" "STACKABLE HIMMEL-851 $SW"
lacks "(8529) a file only a stale ledger with the same writer holds is not STACKABLE on the worker" "$s85g" "STACKABLE HIMMEL-855"
led add-item --ledger "$SL" --key HIMMEL-9205 --writes scripts/lib/e85.sh --state planned
s85h="$(runl 1 "$S85" "$B/fleet.json" --why)"
lacks "(8529) a full named ledger stays full with a stale ledger beside it" "$s85h" "STACKABLE HIMMEL-851"
# a numbered block keeps its own item count when the ledger holds fewer items
newbucket cnt85
mkdoc "$B/HIMMEL-9250-N6-count.md" 4 ""
mkfleet "$B/fleet.json" "N6:$B/HIMMEL-9250-N6-count.md"
led create --ledger "$B/series/cnt.json" --sid cnt --completes-ticket no --writer "$B/HIMMEL-9250-N6-count.md" || fail "(8529) setup: the count ledger was not created"
led add-item --ledger "$B/series/cnt.json" --key HIMMEL-9251 --writes scripts/config-ui/app.js --state committed || fail "(8529) setup: the count ledger item was not added"
s85i="$(runl 1 "$S85" "$B/fleet.json" --why)"
lacks "(8529) a numbered block of 4 items takes no STACKABLE when its ledger lists one" "$s85i" "STACKABLE HIMMEL-851"
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
mk HIMMEL-876 "To Do" High '[]' '["v1.0.1"]' '[]' "WSL station triage in docs/handover" "Edit docs/handover/fg-85.md."
mk HIMMEL-877 "To Do" High '[]' '["v1.0.1"]' '[]' "parked: a sub-task in docs/handover" "Edit docs/handover/fh-85.md."
mk HIMMEL-878 "To Do" High '["residual-depth-1"]' '["v1.0.1"]' '[]' "a residual sub-task in docs/handover" "Edit docs/handover/fi-85.md."
mk HIMMEL-879 "To Do" High '[]' '["v1.0.1"]' '["HIMMEL-9390"]' "a sub-task blocked by a ticket reopened live" "Edit docs/handover/fj-85.md."
mk HIMMEL-9390 "Done" High '[]' '["v1.0.1"]' '[]' "a blocker the mirror calls Done" "Edit scripts/lib/fk-85.sh."
mk HIMMEL-881 "To Do" High '[]' '["v1.0.1"]' '[]' "the unblocked sibling of the blocked sub-task" "Edit docs/handover/fl-85.md."
for k in 870 871 872 873 874 875 876 877 878 879 881; do retype "$M/HIMMEL-$k.md" "Sub-task"; done
reparent "$M/HIMMEL-877.md" HIMMEL-860; reparent "$M/HIMMEL-878.md" HIMMEL-860; reparent "$M/HIMMEL-879.md" HIMMEL-863; reparent "$M/HIMMEL-881.md" HIMMEL-863
reparent "$M/HIMMEL-876.md" HIMMEL-860; reparent "$M/HIMMEL-870.md" HIMMEL-860; reparent "$M/HIMMEL-871.md" HIMMEL-860; reparent "$M/HIMMEL-875.md" HIMMEL-860
reparent "$M/HIMMEL-872.md" HIMMEL-861; reparent "$M/HIMMEL-873.md" HIMMEL-862; reparent "$M/HIMMEL-874.md" HIMMEL-860
FAM="$M"
newbucket fam; mkfleet "$B/fleet.json"
fam1="$(NEXT_DISPATCH_JIRA_CMD="$WORK/jira-live" LIVE_STATUS="In Progress" runl 1 "$FAM" "$B/fleet.json")"
lacks "(8529) a parked: sub-task is in no family row" "$fam1" "HIMMEL-877"
lacks "(8529) a residual-depth sub-task with no admission is in no family row" "$fam1" "HIMMEL-878"
lacks "(8529) a sub-task whose Done blocker reopened live is in no family row" "$fam1" "HIMMEL-879"
famd="$(NEXT_DISPATCH_JIRA_CMD="$WORK/jira-live" LIVE_STATUS="Done" runl 1 "$FAM" "$B/fleet.json")"
has "(8529) a sub-task whose blocker is Done live is in its family row" "$famd" "SERIES FAMILY docs/handover HIMMEL-879,HIMMEL-881"
# only a possible family member's blockers are read live: a sub-task outside the earliest version costs no Jira call
mk HIMMEL-882 "To Do" High '[]' '["v1.0.2"]' '["HIMMEL-9391"]' "a later-version sub-task blocked by another ticket" "Edit docs/handover/fm-85.md."
retype "$M/HIMMEL-882.md" "Sub-task"; reparent "$M/HIMMEL-882.md" HIMMEL-863
# shellcheck disable=SC2016  # the $ names are literal text of the fake Jira CLI, expanded when it runs
printf '#!/usr/bin/env bash\n[ "$1" = get ] || exit 2\nprintf "%%s\\n" "$2" >> "$LIVE_LOG"\nprintf "%%s\\tTask\\t%%s\\tt\\n" "$2" "$LIVE_STATUS"\n' > "$WORK/jira-logged"; chmod +x "$WORK/jira-logged"
: > "$WORK/live-reads.log"
NEXT_DISPATCH_JIRA_CMD="$WORK/jira-logged" LIVE_LOG="$WORK/live-reads.log" LIVE_STATUS="Done" runl 1 "$FAM" "$B/fleet.json" > /dev/null
has "(8529) a family member's blocker is read live" "$(cat "$WORK/live-reads.log")" "HIMMEL-9390"
lacks "(8529) a sub-task outside the earliest version has its blocker left unread" "$(cat "$WORK/live-reads.log")" "HIMMEL-9391"
has "(8529) sub-tasks of one parent in one directory family give a SERIES FAMILY row" "$fam1" "SERIES FAMILY docs/handover HIMMEL-870,HIMMEL-871"
lacks "(8529) a sub-task of another parent is not in the family row" "$fam1" "HIMMEL-872"
lacks "(8529) a lone sub-task of its parent gives no family row" "$fam1" "SERIES FAMILY scripts/lib"
lacks "(8529) a sub-task spanning two families is in no family row" "$fam1" "HIMMEL-875"
lacks "(8529) a sub-task the host platform filter drops is in no family row" "$fam1" "HIMMEL-876"
fam0="$(runl 0 "$FAM" "$B/fleet.json")"
lacks "(8529) flag off prints no SERIES FAMILY row" "$fam0" "SERIES FAMILY"
# a sub-task whose file a live worker holds is not offered
printf '# live\n> **Writes:** docs/handover/fa-85.md\n' > "$B/HIMMEL-9240-N5-holder.md"
mkfleet "$B/fleet-h.json" "N5:$B/HIMMEL-9240-N5-holder.md"
fam2="$(NEXT_DISPATCH_JIRA_CMD="$WORK/jira-live" LIVE_STATUS="In Progress" runl 1 "$FAM" "$B/fleet-h.json")"
has "(8529) a sub-task a live worker names still gives its family row (a held file no longer filters it)" "$fam2" "SERIES FAMILY docs/handover HIMMEL-870,HIMMEL-871"

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
has "its RESUME row names the merged PR and the Remaining: text" "$(printf '%s\n' "$pm" | grep "$KP-80	")" "partial=PR #5001 merged, Remaining: slice two and the {brace} reader"
has "a partial merge without a Remaining: line is flagged as needing a chief note" "$pm" "NEEDS-CHIEF-NOTE HIMMEL-81: merged PR #5002 has no Remaining: line and no deferred line under ## Ticket coverage, needs a chief note"
lacks "a partial merge without a Remaining: line is not dispatchable" "$pm" "	HIMMEL-81	"
has "a To Do ticket with a merged partial PR is a RESUME row" "$pm" "RESUME	HIMMEL-82"
has "and its RESUME row carries the PR's Remaining: text" "$(printf '%s\n' "$pm" | grep "$KP-82	")" "Remaining: the other half"
lacks "a To Do ticket with a merged partial PR is never an ordinary row" "$pm" "LOCAL	HIMMEL-82"
has "a plain To Do ticket is still an ordinary row" "$pm" "LOCAL	HIMMEL-83"
mkdir -p "$WORK/pm-bad/workers" "$WORK/pm-bad/status-events.jsonl"
pmb="$(NEXT_DISPATCH_MIRROR="$MPM" NEXT_DISPATCH_GH_CMD="$WORK/gh" NEXT_DISPATCH_CLASSIFY_CMD="$WORK/classify" bash "$SUT" --workers-dir "$WORK/pm-bad/workers" --workers-from "$WORK/fleet5.json" 2>/dev/null)"
has "an unreadable status log is warned about, not silently read as empty" "$pmb" "# warn: $WORK/pm-bad/status-events.jsonl is unreadable"
has "an empty Remaining: line does not borrow the next line's text" "$pm" "NEEDS-CHIEF-NOTE HIMMEL-84"
lacks "an empty Remaining: line is not a RESUME row" "$pm" "RESUME	HIMMEL-84"
has "a PR body gh cannot read is reported as unreadable, not as missing a Remaining: line" "$pm" "NEEDS-CHIEF-NOTE HIMMEL-85: merged PR #5005 body could not be read (gh failed)"

# A partial PR whose body records its remainder only as `deferred → HIMMEL-<n>` lines under `## Ticket coverage`
# (what workers write) is read, not NEEDS-CHIEF-NOTE. A remainder handed wholly to other tickets is HANDED-OFF; one that
# stays on the ticket (a Remaining: line, a deferred line naming the ticket itself or no ticket) is a RESUME row.
PMC_STATE="$WORK/pmc"; mkdir -p "$PMC_STATE/workers"
MPMC="$WORK/mpmc/HIMMEL"; mkdir -p "$MPMC"
printf '## Summary\nslice one\n\n## Ticket coverage\n- slice one: done\n- rest: deferred → HIMMEL-9\n' > "$PR_BODY_DIR/5101"
printf '## Ticket coverage\n- slice one: done\n- rest: deferred -> HIMMEL-121\n' > "$PR_BODY_DIR/5102"
printf 'Remaining: the reader\n\n## Ticket coverage\n- the writer: deferred → HIMMEL-9\n' > "$PR_BODY_DIR/5103"
printf '## Ticket coverage\n- slice one: done\n- slice two: done\n' > "$PR_BODY_DIR/5104"
printf '## Ticket coverage\n- rest: deferred → HIMMEL-9\n- more: deferred → HIMMEL-10\n\n## Notes\n- not a coverage line: deferred → HIMMEL-77\n' > "$PR_BODY_DIR/5105"
printf '## Ticket coverage\n- rest: deferred → HIMMEL-9\n' > "$PR_BODY_DIR/5106"
printf 'Remaining: the half no one took\n' > "$PR_BODY_DIR/5107"
printf '## Ticket coverage\n- slice one: done\n\n### Handed on\n- rest: deferred → HIMMEL-9\n' > "$PR_BODY_DIR/5108"
printf 'Remaining: the reader\tand the writer\n' > "$PR_BODY_DIR/5109"
printf '## Ticket coverage\n- rest: deferred → HIMMEL-9\n##\n- after: deferred → HIMMEL-77\n' > "$PR_BODY_DIR/5110"
M_SAVE="$M"; M="$MPMC"
mk HIMMEL-128 "In Progress" Medium '[]' '[]' '[]' "an empty heading ends the coverage section" "Edit scripts/lib/pc9.sh."
mk HIMMEL-126 "In Progress" Medium '[]' '[]' '[]' "a deferred line under a level-three heading inside the coverage" "Edit scripts/lib/pc7.sh."
mk HIMMEL-127 "In Progress" Medium '[]' '[]' '[]' "a Remaining line holding a tab" "Edit scripts/lib/pc8.sh."
mk HIMMEL-120 "In Progress" Medium '[]' '[]' '[]' "coverage hands the whole remainder to HIMMEL-9" "Edit scripts/lib/pc1.sh."
mk HIMMEL-121 "In Progress" Medium '[]' '[]' '[]' "coverage defers to the ticket itself" "Edit scripts/lib/pc2.sh."
mk HIMMEL-122 "In Progress" Medium '[]' '[]' '[]' "a Remaining line beside a deferred line" "Edit scripts/lib/pc3.sh."
mk HIMMEL-123 "In Progress" Medium '[]' '[]' '[]' "coverage of done lines only" "Edit scripts/lib/pc4.sh."
mk HIMMEL-124 "In Progress" Medium '[]' '[]' '[]' "deferred to two tickets, a later section also defers" "Edit scripts/lib/pc5.sh."
mk HIMMEL-125 "In Progress" Medium '[]' '[]' '[]' "one slice handed off, one slice remaining" "Edit scripts/lib/pc6.sh."
M="$M_SAVE"
cat > "$PMC_STATE/status-events.jsonl" <<'EOF'
{"ts":"t","event":"merge","key":"HIMMEL-120","pr":"5101","contract":"no","result":"noop"}
{"ts":"t","event":"merge","key":"HIMMEL-121","pr":"5102","contract":"no","result":"noop"}
{"ts":"t","event":"merge","key":"HIMMEL-122","pr":"5103","contract":"no","result":"noop"}
{"ts":"t","event":"merge","key":"HIMMEL-123","pr":"5104","contract":"no","result":"noop"}
{"ts":"t","event":"merge","key":"HIMMEL-124","pr":"5105","contract":"no","result":"noop"}
{"ts":"t","event":"merge","key":"HIMMEL-125","pr":"5106","contract":"no","result":"noop"}
{"ts":"t","event":"merge","key":"HIMMEL-125","pr":"5107","contract":"no","result":"noop"}
{"ts":"t","event":"merge","key":"HIMMEL-126","pr":"5108","contract":"no","result":"noop"}
{"ts":"t","event":"merge","key":"HIMMEL-127","pr":"5109","contract":"no","result":"noop"}
{"ts":"t","event":"merge","key":"HIMMEL-128","pr":"5110","contract":"no","result":"noop"}
EOF
pmc="$(NEXT_DISPATCH_MIRROR="$MPMC" NEXT_DISPATCH_GH_CMD="$WORK/gh" NEXT_DISPATCH_CLASSIFY_CMD="$WORK/classify" bash "$SUT" --workers-dir "$PMC_STATE/workers" --workers-from "$WORK/fleet5.json" 2>/dev/null)"
has "a coverage-only partial PR handing its remainder to another ticket is HANDED-OFF" "$pmc" "HANDED-OFF HIMMEL-120: remainder on HIMMEL-9"
lacks "a coverage-only partial PR is not NEEDS-CHIEF-NOTE" "$pmc" "NEEDS-CHIEF-NOTE HIMMEL-120"
lacks "a handed-off ticket is not a RESUME row" "$pmc" "RESUME	HIMMEL-120"
has "a deferred line naming the ticket itself stays a RESUME row" "$pmc" "RESUME	HIMMEL-121"
has "and its RESUME row carries the deferred line as Remaining:" "$(printf '%s\n' "$pmc" | grep "$KP-121	")" "partial=PR #5102 merged, Remaining: rest: deferred -> HIMMEL-121"
lacks "a self-deferred ticket is not HANDED-OFF" "$pmc" "HANDED-OFF HIMMEL-121"
has "a Remaining: line beside a deferred line is a RESUME row" "$pmc" "RESUME	HIMMEL-122"
has "and its RESUME row carries both" "$(printf '%s\n' "$pmc" | grep "$KP-122	")" "Remaining: the reader; the writer: deferred → HIMMEL-9"
lacks "a Remaining: line keeps the ticket out of HANDED-OFF" "$pmc" "HANDED-OFF HIMMEL-122"
has "a coverage of done lines only is NEEDS-CHIEF-NOTE" "$pmc" "NEEDS-CHIEF-NOTE HIMMEL-123: merged PR #5104 has no Remaining: line and no deferred line under ## Ticket coverage"
has "the NEEDS-CHIEF-NOTE row names the one action that clears it" "$pmc" "add one to PR #5104's body"
has "a remainder deferred to several tickets names them all" "$pmc" "HANDED-OFF HIMMEL-124: remainder on HIMMEL-9, HIMMEL-10"
lacks "a deferred line outside ## Ticket coverage is not read" "$pmc" "HIMMEL-77"
has "a ticket with one handed-off and one remaining partial PR is a RESUME row" "$pmc" "RESUME	HIMMEL-125"
has "and its RESUME row carries both PRs" "$(printf '%s\n' "$pmc" | grep "$KP-125	")" "partial=PR #5107 merged, Remaining: the half no one took"
lacks "a ticket with a remaining partial PR is not HANDED-OFF" "$pmc" "HANDED-OFF HIMMEL-125"
has "a deferred line under a ### heading inside the coverage section is still read" "$pmc" "HANDED-OFF HIMMEL-126: remainder on HIMMEL-9"
has "an empty heading ends the coverage section, so a later deferred line is not read" "$pmc" "HANDED-OFF HIMMEL-128: remainder on HIMMEL-9"
has "a tab inside a Remaining: line does not break the reader's answer line" "$(printf '%s\n' "$pmc" | grep "$KP-127	")" "partial=PR #5109 merged, Remaining: the reader and the writer"

# Two partial PRs handing the same ticket on name it once; a PR two tickets share is read once per ticket, because the
# deferred ticket's own key changes the answer.
PMD_STATE="$WORK/pmd"; mkdir -p "$PMD_STATE/workers"
MPMD="$WORK/mpmd/HIMMEL"; mkdir -p "$MPMD"
printf '## Ticket coverage\n- rest: deferred -> HIMMEL-9\n' > "$PR_BODY_DIR/5111"
printf '## Ticket coverage\n- more: deferred -> HIMMEL-9\n' > "$PR_BODY_DIR/5112"
printf '## Ticket coverage\n- rest: deferred -> HIMMEL-131\n' > "$PR_BODY_DIR/5113"
printf '## Ticket coverage\n- rest: deferred -> after HIMMEL-9 merges, stays here\n' > "$PR_BODY_DIR/5114"
printf '## Ticket coverage\n- rest: deferred -> HIMMEL-9, HIMMEL-10\n' > "$PR_BODY_DIR/5115"
M_SAVE="$M"; M="$MPMD"
mk HIMMEL-132 "In Progress" Medium '[]' '[]' '[]' "a deferred line whose key is not last stays remaining" "Edit scripts/lib/pd4.sh."
mk HIMMEL-133 "In Progress" Medium '[]' '[]' '[]' "a deferred line naming two tickets stays remaining" "Edit scripts/lib/pd5.sh."
mk HIMMEL-129 "In Progress" Medium '[]' '[]' '[]' "two partial PRs hand on to one ticket" "Edit scripts/lib/pd1.sh."
mk HIMMEL-130 "In Progress" Medium '[]' '[]' '[]' "the first of two tickets sharing a partial PR" "Edit scripts/lib/pd2.sh."
mk HIMMEL-131 "In Progress" Medium '[]' '[]' '[]' "the second of two tickets sharing a partial PR" "Edit scripts/lib/pd3.sh."
M="$M_SAVE"
cat > "$PMD_STATE/status-events.jsonl" <<'EOF'
{"ts":"t","event":"merge","key":"HIMMEL-129","pr":"5111","contract":"no","result":"noop"}
{"ts":"t","event":"merge","key":"HIMMEL-129","pr":"5112","contract":"no","result":"noop"}
{"ts":"t","event":"merge","key":"HIMMEL-130","pr":"5113","contract":"no","result":"noop"}
{"ts":"t","event":"merge","key":"HIMMEL-131","pr":"5113","contract":"no","result":"noop"}
{"ts":"t","event":"merge","key":"HIMMEL-132","pr":"5114","contract":"no","result":"noop"}
{"ts":"t","event":"merge","key":"HIMMEL-133","pr":"5115","contract":"no","result":"noop"}
EOF
pmd="$(NEXT_DISPATCH_MIRROR="$MPMD" NEXT_DISPATCH_GH_CMD="$WORK/gh" NEXT_DISPATCH_CLASSIFY_CMD="$WORK/classify" bash "$SUT" --workers-dir "$PMD_STATE/workers" --workers-from "$WORK/fleet5.json" 2>/dev/null)"
has "two partial PRs handing on to one ticket name it once" "$pmd" "HANDED-OFF HIMMEL-129: remainder on HIMMEL-9"
lacks "and not twice" "$pmd" "HIMMEL-9, HIMMEL-9"
has "a PR shared by two tickets hands the first one on to the second" "$pmd" "HANDED-OFF HIMMEL-130: remainder on HIMMEL-131"
has "and the second, whose own key it names, keeps the remainder" "$pmd" "RESUME	HIMMEL-131"
lacks "the second is not handed off on the first's answer" "$pmd" "HANDED-OFF HIMMEL-131"
has "a deferred line whose key is not last stays a RESUME row" "$pmd" "RESUME	HIMMEL-132"
lacks "and does not hand off on the key inside its prose" "$pmd" "HANDED-OFF HIMMEL-132"
has "a deferred line naming two tickets stays a RESUME row (ready-check.sh accepts one key, last)" "$pmd" "RESUME	HIMMEL-133"
lacks "and hands nothing off" "$pmd" "HANDED-OFF HIMMEL-133"

# A reader answer the dispatcher does not recognise, or one of the wrong shape, reads as an unreadable body: never dispatched blind.
cat > "$WORK/odd-reader.py" <<'EOF'
import json, sys
answers = {140: "garbage", 141: "remaining", 142: "remaining\ta\tb", 143: "handed-off\tHIMMEL-9", 144: "handed-off\tHIMMEL-9\ttext\textra"}
n = int(sys.argv[-1].rsplit("-", 1)[1])
answer = answers[n]
if "--full-units" in sys.argv:
    a = {"kind": "remaining", "handed": [], "text": "x", "nowrite": False, "chief_owed": [], "chief_invalid": [], "owed_lines": []}
    if n == 140: a["kind"] = "garbage"
    if n == 141: del a["text"]
    if n == 142: a["b"] = "b"
    if n == 143: a.update(kind="handed-off", handed=["HIMMEL-9"]); del a["text"]
    if n == 144: a.update(kind="handed-off", handed=["HIMMEL-9"], extra="extra")
    sys.stdout.write(json.dumps({"schema": 1, "answer": a}) + "\n")
else:
    units = "\tnowrite=0\tchief-owed=" if "--units" in sys.argv else ""
    sys.stdout.write(answer + units + "\n")
EOF
PME_STATE="$WORK/pme"; mkdir -p "$PME_STATE/workers"
MPME="$WORK/mpme/HIMMEL"; mkdir -p "$MPME"
M_SAVE="$M"; M="$MPME"
: > "$PME_STATE/status-events.jsonl"
for n in 140 141 142 143 144; do
    printf 'Remaining: x\n' > "$PR_BODY_DIR/52$n"
    mk "HIMMEL-$n" "In Progress" Medium '[]' '[]' '[]' "a partial PR whose reader answers oddly $n" "Edit scripts/lib/pe$n.sh."
    printf '{"ts":"t","event":"merge","key":"HIMMEL-%s","pr":"52%s","contract":"no","result":"noop"}\n' "$n" "$n" >> "$PME_STATE/status-events.jsonl"
done
M="$M_SAVE"
pme="$(NEXT_DISPATCH_READER="$WORK/odd-reader.py" NEXT_DISPATCH_MIRROR="$MPME" NEXT_DISPATCH_GH_CMD="$WORK/gh" NEXT_DISPATCH_CLASSIFY_CMD="$WORK/classify" bash "$SUT" --workers-dir "$PME_STATE/workers" --workers-from "$WORK/fleet5.json" 2>/dev/null)"
for n in 140 141 142 143 144; do
    has "an odd reader answer ($n) reads as an unreadable body" "$pme" "NEEDS-CHIEF-NOTE HIMMEL-$n: merged PR #52$n body could not be read"
    lacks "and an odd reader answer ($n) is not dispatched" "$pme" "RESUME	HIMMEL-$n"
done

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
has "and its RESUME row names the newer partial PR's Remaining: text" "$(printf '%s\n' "$pm2" | grep "$KP-86	")" "Remaining: the late slice"
lacks "a contract=yes row after a partial merge is done-pending, not a RESUME row" "$pm2" "RESUME	HIMMEL-87"
lacks "and it is not an ordinary row either" "$pm2" "LOCAL	HIMMEL-87"
has "a partial after a completing merge is a RESUME row naming only the new partial" "$(printf '%s\n' "$pm2" | grep "$KP-89	")" "Remaining: the new half"
lacks "and a partial PR a later contract=yes row completed is not named" "$(printf '%s\n' "$pm2" | grep "$KP-89	")" "the old half"

# A merge row written BEFORE the merge call (stage pre-merge) counts only once GitHub reports its PR MERGED
# at that head, or a later row of the same PR does; a row followed by result=not-merged, or whose PR is still open, is ignored.
mkdir -p "$WORK/pm3/workers"
cat > "$WORK/pm3/mrgh" <<'EOF'
#!/usr/bin/env bash
# the merge-rows filter's gh seam: `pr view <n> --json state,headRefOid --jq ...`; PR 5022 answers MERGED, so only its not-merged row keeps it out
case "$3" in
    5020) echo "OPEN h20" ;;
    5021) echo "MERGED h21" ;;
    5022) echo "MERGED h22" ;;
    *) exit 1 ;;
esac
EOF
chmod +x "$WORK/pm3/mrgh"
M="$MPM"
mk HIMMEL-91 "To Do" Medium '[]' '[]' '[]' "pre-merge row, PR still open" "Edit scripts/lib/pm11.sh."
mk HIMMEL-92 "To Do" Medium '[]' '[]' '[]' "pre-merge row, PR merged on GitHub" "Edit scripts/lib/pm12.sh."
mk HIMMEL-93 "To Do" Medium '[]' '[]' '[]' "pre-merge row retired by a not-merged row" "Edit scripts/lib/pm13.sh."
M="$M_SAVE"
cat > "$WORK/pm3/status-events.jsonl" <<'EOF'
{"ts":"t","event":"merge","key":"HIMMEL-91","pr":"5020","head":"h20","contract":"yes","result":"pending","stage":"pre-merge"}
{"ts":"t","event":"merge","key":"HIMMEL-92","pr":"5021","head":"h21","contract":"yes","result":"pending","stage":"pre-merge"}
{"ts":"t","event":"merge","key":"HIMMEL-93","pr":"5022","head":"h22","contract":"yes","result":"pending","stage":"pre-merge"}
{"ts":"t","event":"merge","key":"HIMMEL-93","pr":"5022","head":"h22","result":"not-merged","stage":"merge-failed"}
EOF
pm3="$(MERGE_ROWS_GH="$WORK/pm3/mrgh" NEXT_DISPATCH_MIRROR="$MPM" NEXT_DISPATCH_GH_CMD="$WORK/gh" NEXT_DISPATCH_CLASSIFY_CMD="$WORK/classify" bash "$SUT" --top 50 --workers-dir "$WORK/pm3/workers" --workers-from "$WORK/fleet5.json" 2>/dev/null)"
has "a pre-merge row whose PR is still open is not done-pending" "$pm3" "HIMMEL-91	"
lacks "a pre-merge row whose PR GitHub reports MERGED is done-pending (a kill after the merge keeps the record)" "$pm3" "HIMMEL-92	"
has "a pre-merge row retired by a not-merged row is not done-pending" "$pm3" "HIMMEL-93	"

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
# a ref that cannot show absence is unknown, not "no": a shallow clone (its boundary hides the commit that names the first fixture key) and a ref last updated before the window
PMS="$WORK/pm-shallow"; git clone -q --depth 1 "file://$PMG" "$PMS" || { fail "the shallow fixture clone could not be created"; printf '\n%d failure(s)\n' "$fails"; exit 1; }
pms="$(NEXT_DISPATCH_GIT_DIR="$PMS" NEXT_DISPATCH_MAIN_REF=main NEXT_DISPATCH_MIRROR="$MPM" NEXT_DISPATCH_GH_CMD="$WORK/gh" NEXT_DISPATCH_CLASSIFY_CMD="$WORK/classify" bash "$SUT" --workers-dir "$WORK/pm-bad/workers" --workers-from "$WORK/fleet5.json" 2>/dev/null)"
lacks "a shallow ref with no match withholds a candidate under an unreadable status log (it cannot show absence)" "$pms" "LOCAL	HIMMEL-83"
PMO="$WORK/pm-old"; mkdir -p "$PMO"
{ git -C "$PMO" init -q -b main && GIT_COMMITTER_DATE=2020-01-01T00:00:00Z GIT_AUTHOR_DATE=2020-01-01T00:00:00Z git -C "$PMO" -c user.name=t -c user.email=t@t commit -q --allow-empty -m "fix(x): [HIMMEL-880] an old merge"; } \
    || { fail "the stale fixture repo could not be created"; printf '\n%d failure(s)\n' "$fails"; exit 1; }
pmo="$(NEXT_DISPATCH_GIT_DIR="$PMO" NEXT_DISPATCH_MAIN_REF=main NEXT_DISPATCH_MIRROR="$MPM" NEXT_DISPATCH_GH_CMD="$WORK/gh" NEXT_DISPATCH_CLASSIFY_CMD="$WORK/classify" bash "$SUT" --workers-dir "$WORK/pm-bad/workers" --workers-from "$WORK/fleet5.json" 2>/dev/null)"
lacks "a ref last updated before the 14-day window withholds a candidate with no match (it cannot show absence)" "$pmo" "LOCAL	HIMMEL-82"

# --- (8591, C3 of 8353; permanent since 8592, C5) a core To Do ticket with no signed minerva spec lists as a DESIGN row ---
# The jira CLI is a fixture stand-in (scripts/jira/dist is untracked, absent in CI): it answers from CG/core/<KEY> and
# CG/spec/<KEY> lines and logs every call to CG/calls.log; CG/mode makes it fail (exit3, junk, spec3).
CG="$WORK/cg"; mkdir -p "$CG/core" "$CG/spec"
mkdir -p "$WORK/cg-stub"
cat > "$WORK/cg-stub/index.js" <<'EOF'
const fs = require('fs');
const a = process.argv.slice(2);
const dir = process.env.CG;
fs.appendFileSync(dir + '/calls.log', a.join(' ') + ' (cwd ' + process.cwd() + ')\n');
let mode = '';
try { mode = fs.readFileSync(dir + '/mode', 'utf8').trim(); } catch (e) { /* no mode: answer normally */ }
const opt = (n) => { const i = a.indexOf(n); return i < 0 ? null : a[i + 1]; };
const line = (sub, k) => { try { return fs.readFileSync(dir + '/' + sub + '/' + k, 'utf8').trim(); } catch (e) { return ''; } };
if (a[0] === 'release' && a[1] === 'core-check') {
  if (mode === 'exit3') { console.error('boom'); process.exit(3); }
  if (mode === 'junk') { console.log('this is not a verdict'); process.exit(0); }
  for (const k of a.slice(a.indexOf('--key') + 1)) console.log(line('core', k) || 'NOT-CORE ' + k);
} else if (a[0] === 'release' && a[1] === 'spec-check') {
  if (mode === 'spec3') { console.error('boom'); process.exit(3); }
  let bad = 0;
  for (const k of a.slice(a.indexOf('--mirror') + 2)) { const l = line('spec', k); if (!l.startsWith('SPEC ok')) bad = 1; console.log(l || 'NO-SPEC ' + k); }
  process.exit(bad);
} else { console.error('stub jira: unknown command ' + a.join(' ')); process.exit(2); }
EOF
export CG
runcg() { # <mirror dir> args...: the script under test with no flag set and the stub CLI
    local mir="$1"; shift
    NEXT_DISPATCH_JIRA_CLI="${CG_CLI:-$WORK/cg-stub/index.js}" NEXT_DISPATCH_MIRROR="$mir" NEXT_DISPATCH_GH_CMD="$WORK/gh" NEXT_DISPATCH_CLASSIFY_CMD="$WORK/classify-s" bash "$SUT" "$@" 2>/dev/null
}
newmir cg
for n in 901 902 903 904 905 906; do mk "HIMMEL-$n" "To Do" High '[]' '["v1.0.1"]' '[]' "cg $n" "Edit scripts/lib/cg$n.sh please."; done
printf 'CORE HIMMEL-901 label core\n' > "$CG/core/HIMMEL-901"; printf 'NO-SPEC HIMMEL-901\n' > "$CG/spec/HIMMEL-901"
printf 'CORE HIMMEL-902 label core\n' > "$CG/core/HIMMEL-902"; printf 'SPEC-STALE HIMMEL-902 core paths changed since the spec\n' > "$CG/spec/HIMMEL-902"
printf 'CORE HIMMEL-903 label core\n' > "$CG/core/HIMMEL-903"; printf 'SPEC ok HIMMEL-903 specs/designs/x.md abc123\n' > "$CG/spec/HIMMEL-903"
printf 'BYPASS HIMMEL-904 bug a Bug is not gated\n' > "$CG/core/HIMMEL-904"
printf 'UNKNOWN HIMMEL-906\n' > "$CG/core/HIMMEL-906"
CGM="$M"
cg="$(runcg "$CGM")"
has "(8591) a core To Do ticket with no signed spec prints DESIGN <KEY> NO-SPEC" "$cg" "DESIGN${TAB}HIMMEL-901${TAB}NO-SPEC${TAB}High${TAB}v1.0.1${TAB}cg 901${TAB}files=scripts/lib/cg901.sh"
has "(8591) a SPEC-STALE answer prints DESIGN <KEY> SPEC-STALE" "$cg" "DESIGN${TAB}HIMMEL-902${TAB}SPEC-STALE${TAB}"
lacks "(8591) a core ticket with a signed spec prints no DESIGN row" "$cg" "DESIGN${TAB}HIMMEL-903"
has "(8591) a core ticket with a signed spec lists as a normal row" "$cg" "LOCAL${TAB}HIMMEL-903${TAB}"
lacks "(8591) a BYPASS key prints no DESIGN row" "$cg" "DESIGN${TAB}HIMMEL-904"
has "(8591) a BYPASS key lists as a normal row" "$cg" "LOCAL${TAB}HIMMEL-904${TAB}"
lacks "(8591) a NOT-CORE key prints no DESIGN row" "$cg" "DESIGN${TAB}HIMMEL-905"
has "(8591) a NOT-CORE key lists as a normal row" "$cg" "LOCAL${TAB}HIMMEL-905${TAB}"
lacks "(8591) a ticket with a DESIGN row is not also a dispatch row (no-spec)" "$cg" "LOCAL${TAB}HIMMEL-901"
lacks "(8591) a ticket with a DESIGN row is not also a dispatch row (stale)" "$cg" "LOCAL${TAB}HIMMEL-902"
lacks "(8591) an UNKNOWN key is never listed" "$cg" "HIMMEL-906${TAB}"
cgw="$(runcg "$CGM" --why)"
has "(8591) an UNKNOWN key is withheld with the core-unknown drop" "$cgw" "# drop HIMMEL-906 core-unknown"
[ "$(grep -c 'release core-check' "$CG/calls.log")" -ge 1 ] && pass "(8591) the CLI was asked core-check" || fail "(8591) core-check was never called"
has "(8591) core-check is not told --docs-only" "$(cat "$CG/calls.log")" "release core-check --paths"
lacks "(8591) core-check is not told --docs-only (flag absent)" "$(cat "$CG/calls.log")" "--docs-only"
has "(8591) spec-check asks the core keys only" "$(grep 'release spec-check' "$CG/calls.log")" "HIMMEL-901"
lacks "(8591) spec-check is not asked about a NOT-CORE key" "$(grep 'release spec-check' "$CG/calls.log")" "HIMMEL-905"
has "(8591) the CLI runs from its own checkout" "$(cat "$CG/calls.log")" "(cwd $(cd "$WORK/cg-stub" && pwd -P))"
# a DESIGN row takes a --top slot and holds no files
cgt="$(runcg "$CGM" --top 1)"
[ "$(printf '%s\n' "$cgt" | grep -c "^DESIGN")" = 1 ] && [ "$(printf '%s\n' "$cgt" | grep -c "^LOCAL")" = 0 ] && pass "(8591) a DESIGN row takes a --top slot" || fail "(8591) --top 1 should print exactly the DESIGN row: $cgt"
mk HIMMEL-907 "To Do" Medium '[]' '["v1.0.1"]' '[]' "shares the DESIGN ticket's file" "Edit scripts/lib/cg901.sh please."
cgh="$(runcg "$CGM")"
has "(8591) a DESIGN row holds no files against another candidate" "$cgh" "LOCAL${TAB}HIMMEL-907${TAB}"
rm -f "$CGM/HIMMEL-907.md"

mk HIMMEL-9640 "To Do" High '[]' '["v1.0.1"]' '[]' "cg 9640" "Edit scripts/lib/cg9640.sh please."
cp "$HERE/../../jira/src/release/fixtures/bypass-needs-spec.line" "$CG/core/HIMMEL-9640"
cgn="$(runcg "$CGM")"
has "(9564) a BYPASS-NEEDS-SPEC answer prints a DESIGN row and keeps the list" "$cgn" "DESIGN${TAB}HIMMEL-9640${TAB}BYPASS-NEEDS-SPEC${TAB}"
has "(9564) ... the fixture's other To Do rows still print, HIMMEL-903 among them" "$cgn" "LOCAL${TAB}HIMMEL-903${TAB}"
lacks "(9564) ... the key is not also a dispatch row" "$cgn" "LOCAL${TAB}HIMMEL-9640"
lacks "(9564) ... no CORE-CHECK-FAILED header" "$cgn" "CORE-CHECK-FAILED"
rm -f "$CGM/HIMMEL-9640.md" "$CG/core/HIMMEL-9640"

mk HIMMEL-908 "To Do" High '[]' '["v1.0.1"]' '[]' "cg 908" "Edit scripts/lib/cg908.sh please."
mk HIMMEL-909 "To Do" High '[]' '["v1.0.1"]' '[]' "cg 909" "Edit scripts/lib/cg909.sh please."
printf 'CORE HIMMEL-908 label core\n' > "$CG/core/HIMMEL-908"; printf 'SPEC-NEEDS-OPERATOR HIMMEL-908 /state/specs/HIMMEL-908-spec.md C-R1-908 O-M1-908\n' > "$CG/spec/HIMMEL-908"
printf 'CORE HIMMEL-909 label core\n' > "$CG/core/HIMMEL-909"; printf 'SPEC-SIGNER-UNKNOWN HIMMEL-909 C-R1-909 release v1.1.3 chain unreadable\n' > "$CG/spec/HIMMEL-909"
cgs="$(ND_WHY=1 runcg "$CGM" --why)"
has "a SPEC-NEEDS-OPERATOR key prints the # drop line naming the governing record" "$cgs" "# drop HIMMEL-908 spec-needs-operator O-M1-908"
lacks "a SPEC-NEEDS-OPERATOR key prints no DESIGN, LOCAL, LOCAL?, CLOUD, RESUME or SERIES row" "$cgs" "HIMMEL-908${TAB}"
has "a SPEC-SIGNER-UNKNOWN key prints the # drop line naming the why" "$cgs" "# drop HIMMEL-909 spec-signer-unknown release v1.1.3 chain unreadable"
lacks "a SPEC-SIGNER-UNKNOWN key prints no row of any kind" "$cgs" "HIMMEL-909${TAB}"
lacks "the new spec-check verbs are no CORE-CHECK-FAILED" "$cgs" "CORE-CHECK-FAILED"
has "the other To Do rows still print beside the dropped keys" "$cgs" "LOCAL${TAB}HIMMEL-903${TAB}"
cgst="$(runcg "$CGM" --top 2)"
[ "$(printf '%s\n' "$cgst" | grep -c "^DESIGN")" = 2 ] && pass "a dropped SPEC-NEEDS-OPERATOR or SPEC-SIGNER-UNKNOWN key takes no --top slot" || fail "--top 2 should print the two DESIGN rows: $cgst"
for sk in 908 909; do
    case "$sk" in
        908) what="naming the governing record"; exp="needs the operator's own signature (O-M1-908)" ;;
        *) what="with signer records unreadable and the why"; exp='signer records unreadable: release v1.1.3 chain unreadable' ;;
    esac
    has "--why-ticket on the $sk key prints GATE core-no-spec $what" "$(runcg "$CGM" --why-ticket "HIMMEL-$sk")" "GATE HIMMEL-$sk core-no-spec: $exp"
done
rm -f "$CGM/HIMMEL-908.md" "$CGM/HIMMEL-909.md" "$CG/core/HIMMEL-908" "$CG/core/HIMMEL-909" "$CG/spec/HIMMEL-908" "$CG/spec/HIMMEL-909"

mk HIMMEL-9477 "To Do" High '[]' '["v1.0.1"]' '[]' "cg 9477" "Edit scripts/lib/cg9477.sh please."
printf 'CORE HIMMEL-9477 label core\n' > "$CG/core/HIMMEL-9477"
n=0
while IFS=$'\t' read -r want line; do
    n=$((n + 1)); printf '%s\n' "$line" > "$CG/spec/HIMMEL-9477"
    o="$(ND_WHY=1 runcg "$CGM" --why)"
    case "$want" in
        none) exp='# WARN CORE-CHECK-FAILED spec-check printed no parseable line for HIMMEL-9477' ;;
        'SPEC ok '*) exp="LOCAL${TAB}HIMMEL-9477${TAB}" ;;
        SPEC-STALE\ *|NO-SPEC\ *) exp="DESIGN${TAB}HIMMEL-9477${TAB}${want%% *}${TAB}" ;;
        SPEC-NEEDS-OPERATOR\ *) exp="# drop HIMMEL-9477 spec-needs-operator ${want#* governing=}" ;;
        SPEC-SIGNER-UNKNOWN\ *) exp="# drop HIMMEL-9477 spec-signer-unknown ${want#* why=}" ;;
        *) exp="no such answer: $want" ;;
    esac
    has "fixture line $n parses to its answer: $want" "$o" "$exp"
done < "$HERE/fixtures/spec-check-lines.txt"
[ "$n" -ge 11 ] && pass "every line of fixtures/spec-check-lines.txt parses to its expected answer, the spaced path included; a cut line is no answer ($n lines)" \
    || fail "the fixture held $n lines, want at least 11"
rm -f "$CGM/HIMMEL-9477.md" "$CG/core/HIMMEL-9477" "$CG/spec/HIMMEL-9477"

# fail closed: a CLI that cannot run lists no To Do row and prints one CORE-CHECK-FAILED header
for how in missing exit3 junk spec3; do
    : > "$CG/calls.log"; rm -f "$CG/mode"
    CG_CLI=""
    case "$how" in
        missing) CG_CLI="$WORK/no-such-cli.js" ;;
        *) printf '%s\n' "$how" > "$CG/mode" ;;
    esac
    cgf="$(runcg "$CGM")"
    has "(8591) a CLI that cannot run ($how) prints CORE-CHECK-FAILED" "$cgf" "# WARN CORE-CHECK-FAILED"
    [ "$(printf '%s\n' "$cgf" | grep -c "CORE-CHECK-FAILED")" = 1 ] && pass "(8591) ($how) exactly one CORE-CHECK-FAILED header" || fail "(8591) ($how) CORE-CHECK-FAILED header count is not 1"
    lacks "(8591) a CLI that cannot run ($how) lists no To Do row" "$cgf" "LOCAL${TAB}HIMMEL-905"
    lacks "(8591) a CLI that cannot run ($how) prints no DESIGN row" "$cgf" "DESIGN${TAB}"
    lacks "(8591) a CLI that cannot run ($how) lists no normal row at all" "$cgf" "LOCAL${TAB}"
done
CG_CLI=""; rm -f "$CG/mode"

# --resume-only lists no To Do row: it never calls the CLI
: > "$CG/calls.log"
runcg "$CGM" --resume-only > /dev/null
[ ! -s "$CG/calls.log" ] && pass "(8591) --resume-only never calls the CLI" || fail "(8591) --resume-only called the CLI: $(cat "$CG/calls.log")"

# no flag exists: a core ticket with no signed spec lists as a DESIGN row with nothing set, and an env var named like the old flag changes nothing
: > "$CG/calls.log"
cgnoflag="$(runcg "$CGM")"
cgold="$(HIMMEL_FLAG_CORE_GATE=0 runcg "$CGM")"
has "(8592) no flag set: a core ticket with no signed spec is a DESIGN row" "$cgnoflag" "DESIGN${TAB}HIMMEL-901${TAB}NO-SPEC${TAB}"
[ "$cgnoflag" = "$cgold" ] && pass "(8592) the old flag variable set to 0 changes nothing (the gate is permanent)" || fail "(8592) HIMMEL_FLAG_CORE_GATE=0 changed the output"
[ -s "$CG/calls.log" ] && pass "(8592) the CLI is asked with no flag set" || fail "(8592) the CLI was never asked with no flag set"

# --- the register, not the worker doc, is the held-files source (I13) ---
# a live worker whose doc names no Writes (a RESUME doc) and whose register rows sit on files no candidate names is neither
# "its files are unknown" nor a reason to withhold a RESUME row or an IN CI row
RG_DOC="$WORK/HIMMEL-9500-N9500-resume-RESUME.md"
printf '# resume doc\n\n## Results\n- 10:00 LIVE - go\n' > "$RG_DOC"
printf '{"schema":1,"workers":[{"doc":"%s","label":"N9500"}]}\n' "$RG_DOC" > "$WORK/fleet-rg.json"
seed HIMMEL-9500 N9500 "$RG_DOC" scripts/rg/unrelated-a.sh scripts/rg/unrelated-b.sh
printf '4300\tfix(x): [HIMMEL-70] merged\tfix/himmel-70-m\n' > "$MERGED_TSV"
printf '4243\tfix(x): [HIMMEL-7] already started\tfix/himmel-7-started\n' > "$PRS_TSV"
rg_out="$(NEXT_DISPATCH_MIRROR="$M5" NEXT_DISPATCH_GH_CMD="$WORK/gh" NEXT_DISPATCH_CLASSIFY_CMD="$WORK/classify2" bash "$SUT" --no-classify --workers-from "$WORK/fleet-rg.json" 2>"$WORK/rg.err")"
lacks "I13 a live worker whose rows sit on files no candidate names yields no 'its files are unknown' line" "$(cat "$WORK/rg.err")" "its files are unknown"
lacks "I13 ... and the header does not say the live workers are unknown" "$rg_out" "live workers unknown"
has "I13 ... a RESUME row is not withheld" "$rg_out" "RESUME	HIMMEL-50"
has "I13 ... a To Do row is listed" "$rg_out" "HIMMEL-56	"
rg6="$(NEXT_DISPATCH_MIRROR="$WORK/m6/HIMMEL" NEXT_DISPATCH_GH_CMD="$WORK/gh" bash "$SUT" --resume-only --workers-from "$WORK/fleet-rg.json" 2>/dev/null)"
has "I13 ... an IN CI row (a merged PR, no worker) is not withheld" "$rg6" "MERGED-NOT-CLOSED	HIMMEL-70"
rgf="$(NEXT_DISPATCH_JIRA_CMD="$WORK/jira-live" LIVE_STATUS="In Progress" runl 1 "$FAM" "$WORK/fleet-rg.json")"
has "I13 ... a series-family row is not withheld" "$rgf" "SERIES FAMILY docs/handover HIMMEL-870,HIMMEL-871"
: > "$MERGED_TSV"
printf '4242\tfix(x): an outside change to a held file\tcontributor/pr-held\ttrue\t2026-01-01T00:00:00Z\n4243\tfix(x): [HIMMEL-7] already started\tfix/himmel-7-started\n4244\tfix(x): [HIMMEL-52] in review\tfix/himmel-52-y\n' > "$PRS_TSV"

printf '4242\tfix(x): an outside change to a held file\tcontributor/pr-held\ttrue\t2026-01-01T00:00:00Z\n4243\tfix(x): [HIMMEL-7] already started\tfix/himmel-7-started\n4244\tfix(x): [HIMMEL-52] in review\tfix/himmel-52-y\n' > "$PRS_TSV"

# the waiter counts the pool with --top <slack>; a bare `--doc <doc> --why` kept the default --top 8, which nine
# worker-less In Progress rows fill, so it listed no To Do row while the tick read dispatchable above 0. --why with no --top
# lists the same set and names a reason per listed key.
M9="$WORK/m9181/HIMMEL"; mkdir -p "$M9"; cp "$WORK/jira-mirror/HIMMEL.versions.tsv" "$WORK/m9181/HIMMEL.versions.tsv"
M_SAVE="$M"; M="$M9"
for n in 1 2 3 4 5 6 7 8 9; do mk "HIMMEL-970$n" "In Progress" Medium '[]' '["v1.0.1"]' '[]' "orphan $n" "Edit scripts/lib/o9181-$n.sh."; done
for n in 1 2 3; do mk "HIMMEL-971$n" "To Do" Medium '[]' '["v1.0.1"]' '[]' "startable $n" "Edit scripts/lib/s9181-$n.sh."; done
M="$M_SAVE"
D9181="$WORK/chief-9181.md"; printf '# chief\n\n## Live state\npriority:\n' > "$D9181"
run9181() { NEXT_DISPATCH_MIRROR="$M9" NEXT_DISPATCH_GH_CMD="$WORK/gh" NEXT_DISPATCH_CLASSIFY_CMD="$WORK/classify" bash "$SUT" --workers-from "$WORK/fleet5.json" --doc "$D9181" "$@" 2>/dev/null; }
w9="$(run9181 --why)"
w9keys="$(printf '%s\n' "$w9" | grep -E '^(LOCAL|CLOUD)' | cut -f2 | sort | paste -sd, -)"
[ "$w9keys" = "HIMMEL-9711,HIMMEL-9712,HIMMEL-9713" ] && pass "9181: --doc --why lists the startable To Do rows though nine RESUME rows come first" || fail "9181: --why listed '$w9keys'"
pool9="$(run9181 --priority-pool-only --top 50 | grep -E '^(LOCAL|CLOUD)' | cut -f2 | sort | paste -sd, -)"
[ "$w9keys" = "$pool9" ] && pass "9181: --why lists the keys the waiter's pool pass counts" || fail "9181: --why '$w9keys' vs the pool pass '$pool9'"
for k in HIMMEL-9711 HIMMEL-9712 HIMMEL-9713; do has "9181: --why gives a reason for $k" "$w9" "# why $k listed LOCAL tier 4"; done
w9t="$(run9181 --why --top 2 | grep -E '^(LOCAL|CLOUD)' | grep -c .)"
[ "$w9t" = 0 ] && pass "9181: an explicit --top is still the cap (two slots, both RESUME rows)" || fail "9181: --why --top 2 listed $w9t To Do rows"

# A ticket waits only on the files its next step writes: the latest remainder, else a Writes: or Files: line, else the
# description without its comments. A path it only runs holds nothing, and a ticket with no readable scope is a chief question.
M91="$WORK/m91/HIMMEL"; mkdir -p "$M91" "$WORK/s91/workers"; cp "$WORK/jira-mirror/HIMMEL.versions.tsv" "$WORK/m91/HIMMEL.versions.tsv"
M_SAVE="$M"; M="$M91"
BODY_RUNS='Impact
An adopter on the Mac could be billed for runs they never asked for.
Plan
1. On the Mac, in the checkout on fix/himmel-1-opt-in, run bash scripts/luna/graphmap-cadence.sh arm --ast-only.
2. Run bash scripts/luna/graphmap-cadence.sh arm --rewrite-armed --dry-run.
3. Run bash scripts/himmel-doctor.sh --only C88.
Agent detail
Run by the chief, not the PR worker. Code: scripts/luna/graphmap-cadence.sh, scripts/himmel-doctor.sh (C88).'
mk HIMMEL-9601 "To Do" Medium '[]' '["v1.0.1"]' '[]' "only runs the doctor" "$BODY_RUNS"
mk HIMMEL-9602 "To Do" Medium '[]' '["v1.0.1"]' '[]' "runs a script that crashes" "Run bash scripts/himmel-doctor.sh --only C88 and it crashes on the Mac."
mk HIMMEL-9603 "To Do" Medium '[]' '["v1.0.1"]' '[]' "runs it and edits it" "Run scripts/himmel-doctor.sh, then edit scripts/himmel-doctor.sh to add the check."
mk HIMMEL-9604 "To Do" Medium '[]' '["v1.0.1"]' '[]' "held path only in a comment" "Edit scripts/lib/nd91-own1.sh.

DoD
- the row is green

Proof
- a RED row

## Comments

### a — 2026-11-01

An old slice edited scripts/himmel-doctor.sh."
mk HIMMEL-9605 "To Do" Medium '[]' '["v1.0.1"]' '[]' "a Files line narrows the prose" "The doctor at scripts/himmel-doctor.sh shows this.
Files: scripts/lib/nd91-own2.sh"
mk HIMMEL-9606 "To Do" Medium '[]' '["v1.0.1"]' '[]' "a Writes line names the held file" "Context first.
> **Writes:** scripts/himmel-doctor.sh"
mk HIMMEL-9607 "To Do" Medium '[]' '["v1.0.1"]' '[]' "a plain description names the held file" "The doctor misreads C88 in scripts/himmel-doctor.sh."
mk HIMMEL-9608 "To Do" Medium '[]' '["v1.0.1"]' '[]' "paths only in comments" "Nothing about files here.

## Comments

### a — 2026-11-01

Maybe scripts/lib/nd91-comment.sh."
mk HIMMEL-9609 "To Do" Medium '[]' '["v1.0.1"]' '[]' "no path anywhere" "Make the thing better."
mk HIMMEL-9610 "To Do" Medium '[]' '["v1.0.1"]' '[]' "says it writes no code" "A live proof on the station. No code change is expected."
BODY_SLICE='Plan
1. Teach scripts/handover/merge-on-green.sh the repair.
2. The station first run.'
mk HIMMEL-9611 "In Progress" Medium '[]' '["v1.0.1"]' '[]' "partly merged, the remainder needs no code" "$BODY_SLICE"
mk HIMMEL-9612 "In Progress" Medium '[]' '["v1.0.1"]' '[]' "the remainder really edits a held file" "Plan
1. Edit scripts/lib/nd91-done.sh."
mk HIMMEL-9613 "In Progress" Medium '[]' '["v1.0.1"]' '[]' "the remainder edits a registered file" "Plan
1. Edit scripts/lib/nd91-done2.sh."
mk HIMMEL-9614 "In Progress" Medium '[]' '["v1.0.1"]' '[]' "the remainder is vague" "Plan
1. Edit scripts/handover/merge-on-green.sh."
mk HIMMEL-9615 "In Progress" Medium '[]' '["v1.0.1"]' '[]' "an older missing remainder" "Edit scripts/lib/nd91-h1.sh."
mk HIMMEL-9616 "In Progress" Medium '[]' '["v1.0.1"]' '[]' "a newer missing remainder" "Edit scripts/lib/nd91-h2.sh."
mk HIMMEL-9617 "In Progress" Medium '[]' '["v1.0.1"]' '[]' "an older missing remainder, the newer hands off" "Edit scripts/lib/nd91-h3.sh."
mk HIMMEL-9618 "In Progress" Medium '[]' '["v1.0.1"]' '[]' "in work, no readable scope" "Keep the thing going."
mk HIMMEL-9619 "In Progress" Medium '[]' '["v1.0.1"]' '[]' "an older remainder, the newer hands off" "Edit scripts/lib/nd91-h4.sh."
M="$M_SAVE"
printf 'Remaining: S7 (the chief-run station first run on live state, no code).\n' > "$PR_BODY_DIR/9611"
printf 'Remaining: edit scripts/lib/nd91-rem.sh for the last case.\n' > "$PR_BODY_DIR/9612"
printf 'Remaining: edit scripts/lib/nd91-rem2.sh for the last case.\n' > "$PR_BODY_DIR/9613"
printf 'Remaining: the rest of it.\n' > "$PR_BODY_DIR/9614"
printf 'Merged the first slice.\n' > "$PR_BODY_DIR/9615"
printf 'Remaining: only a clean live shift, no code.\n' > "$PR_BODY_DIR/9625"
printf 'Remaining: an old half, no code.\n' > "$PR_BODY_DIR/9616"
printf 'Merged the last slice.\n' > "$PR_BODY_DIR/9626"
printf 'Merged the first slice.\n' > "$PR_BODY_DIR/9617"
printf 'Remaining: edit scripts/himmel-doctor.sh.\n' > "$PR_BODY_DIR/9619"
printf '## Ticket coverage\n- the rest: deferred → HIMMEL-9998\n' > "$PR_BODY_DIR/9629"
printf '## Ticket coverage\n- the rest: deferred → HIMMEL-9999\n' > "$PR_BODY_DIR/9627"
: > "$WORK/s91/status-events.jsonl"
for row in 9611:9611 9612:9612 9613:9613 9614:9614 9615:9615 9615:9625 9616:9616 9616:9626 9617:9617 9617:9627 9619:9619 9619:9629; do
    printf '{"ts":"t","event":"merge","key":"HIMMEL-%s","pr":"%s","contract":"no","result":"noop"}\n' "${row%%:*}" "${row#*:}" >> "$WORK/s91/status-events.jsonl"
done
printf 'scripts/himmel-doctor.sh\nscripts/handover/merge-on-green.sh\nscripts/lib/nd91-rem.sh\n' > "$WORK/held91.txt"
: > "$WORK/N91-holder.md"
seed HIMMEL-9700 N91 "$WORK/N91-holder.md" scripts/lib/nd91-rem2.sh
run91() { NEXT_DISPATCH_MIRROR="$M91" NEXT_DISPATCH_GH_CMD="$WORK/gh" NEXT_DISPATCH_CLASSIFY_CMD="$WORK/classify" bash "$SUT" --top 60 --held "$WORK/held91.txt" --workers-dir "$WORK/s91/workers" --workers-from "$WORK/fleet5.json" "$@" 2>/dev/null; }
r91="$(run91 --why --dispositions)"
row91() { printf '%s\n' "$r91" | grep -E "^(# )?$1[[:space:]]HIMMEL-$2[[:space:]:]" || true; } # <row kind> <ticket number>
# one ticket, one file, the shape of a ticket that only runs the doctor
has "a ticket that only runs himmel-doctor.sh is not dropped when another worker holds it" "$r91" "LOCAL	HIMMEL-9601	"
has "and its row names no file" "$(row91 LOCAL 9601)" "files=-"
lacks "and no collision is recorded for it" "$r91" "# drop HIMMEL-9601 collision"
has "--why names the paths it only reads" "$(row91 scope 9601)" "reads=scripts/luna/graphmap-cadence.sh,scripts/himmel-doctor.sh"
has "a run path that is reported broken still overlaps" "$r91" "# overlap HIMMEL-9602 scripts/himmel-doctor.sh with "
has "a run path the same ticket edits still overlaps" "$r91" "# overlap HIMMEL-9603 scripts/himmel-doctor.sh with "
has "a path named only in a comment holds nothing" "$r91" "LOCAL	HIMMEL-9604	"
has "and the description's own path is its scope" "$(row91 LOCAL 9604)" "files=scripts/lib/nd91-own1.sh"
has "a Files: line is the scope, not the prose around it" "$(row91 LOCAL 9605)" "files=scripts/lib/nd91-own2.sh"
has "--why names the Files: line as the source" "$(row91 scope 9605)" "Files: line"
has "a Writes: line naming a held file prints an overlap" "$r91" "# overlap HIMMEL-9606 scripts/himmel-doctor.sh with "
has "--why names the Writes: line as the source" "$(row91 overlap 9606)" "(from Writes: line)"
has "a description naming a held file prints an overlap" "$r91" "# overlap HIMMEL-9607 scripts/himmel-doctor.sh with "
has "--why names the description as the source" "$(row91 overlap 9607)" "(from description)"
# no readable scope: never silently free
lacks "a ticket with paths only in comments is not listed" "$r91" "LOCAL	HIMMEL-9608	"
has "and is a chief question" "$r91" "NEEDS-CHIEF-NOTE HIMMEL-9608: no readable scope"
has "and its drop says so" "$r91" "# drop HIMMEL-9608 no-scope"
lacks "a ticket with no path anywhere is not listed" "$r91" "LOCAL	HIMMEL-9609	"
has "and is a chief question" "$r91" "NEEDS-CHIEF-NOTE HIMMEL-9609: no readable scope"
has "a ticket that says it writes no code stays listed" "$(row91 LOCAL 9610)" "files=-"
has "an in-work ticket with no readable scope is a chief question" "$r91" "NEEDS-CHIEF-NOTE HIMMEL-9618: no readable scope"
lacks "and is no RESUME row" "$r91" "RESUME	HIMMEL-9618	"
has "a newer hand-off supersedes an older remainder" "$r91" "HANDED-OFF HIMMEL-9619: remainder on HIMMEL-9998"
lacks "and the older remainder holds no file" "$r91" "RESUME-HELD HIMMEL-9619"
has "--resume-only still counts it as an orphan, dispatching nothing" "$(run91 --resume-only)" "RESUME	HIMMEL-9618	"
r91top="$(run91 --top 1)"
has "the question rows stop at --top and count the rest" "$r91top" "# no readable scope: 2 more ticket(s) not shown, --why names them"
has "and only that many are printed" "$(printf '%s\n' "$r91top" | grep -c 'no readable scope: its description')" "1"
has "--why names every one" "$(run91 --top 1 --why | grep -c 'no readable scope: its description')" "3"
# the remainder is read before the collision check, the shape of a partly merged ticket whose rest needs no code
has "a partly merged ticket whose remainder needs no code is not dropped on a path only its finished slice names" "$r91" "RESUME	HIMMEL-9611	"
lacks "and it is no RESUME-HELD row" "$r91" "RESUME-HELD HIMMEL-9611"
has "and its row names no file" "$(row91 RESUME 9611)" "files=-"
has "a ticket whose remainder really edits a held file is offered as RESUME with an overlap line" "$r91" "# overlap HIMMEL-9612 scripts/lib/nd91-rem.sh with held list"
has "and it is still a RESUME row" "$r91" "RESUME	HIMMEL-9612	"
has "--why names the remainder as the source of the overlapping path" "$(row91 overlap 9612)" "(from remainder of PR #9612)"
has "a remainder naming no path and no no-code signal falls back to the description, never free (overlap line)" "$r91" "# overlap HIMMEL-9614 scripts/handover/merge-on-green.sh with held list"
# the history trap: all contract=no PRs of a ticket accumulate
has "a newer clear remainder is not overridden by an older missing one" "$r91" "RESUME	HIMMEL-9615	"
lacks "and no chief note is asked for" "$r91" "NEEDS-CHIEF-NOTE HIMMEL-9615"
has "and the row names only the newer slice" "$(row91 RESUME 9615)" "partial=PR #9625 merged, Remaining: only a clean live shift, no code."
lacks "and not the older one" "$(row91 RESUME 9615)" "PR #9615"
has "a missing remainder newer than the clear one still asks the chief" "$r91" "NEEDS-CHIEF-NOTE HIMMEL-9616: merged PR #9626 has no Remaining: line"
lacks "and the question names only the newer PR" "$(row91 NEEDS-CHIEF-NOTE 9616)" "#9616"
has "a newer hand-off supersedes an older missing remainder" "$r91" "HANDED-OFF HIMMEL-9617: remainder on HIMMEL-9999"
quiet91="$(run91)"
lacks "without --why no scope line is printed" "$quiet91" "# scope "

MP="$WORK/m9848/HIMMEL"; mkdir -p "$MP" "$WORK/s9848/workers"; cp "$WORK/jira-mirror/HIMMEL.versions.tsv" "$WORK/m9848/HIMMEL.versions.tsv"
M_SAVE="$M"; M="$MP"
NOWRITE='Writes: none (chief-run proof, no code)'
mk HIMMEL-9851 "To Do" Medium '[]' '["v1.0.1"]' '[]' "R1 no-write line, a path in the Why" "Why: the wait in scripts/handover/chief-kit/tick.sh needs a live proof.
$NOWRITE"
mk HIMMEL-9852 "In Progress" Medium '[]' '["v1.0.1"]' '[]' "R2 remainder needs no code" "Edit scripts/lib/p9848-b.sh."
mk HIMMEL-9853 "To Do" Medium '[]' '["v1.0.1"]' '[]' "R3 prose says no code, no path" "A live check on the station, no code is expected."
mk HIMMEL-9854 "To Do" Medium '[]' '["v1.0.1"]' '[]' "R4 a pathed Writes line wins" "$NOWRITE
Writes: scripts/lib/p9848-a.sh"
mk HIMMEL-9855 "To Do" Medium '[]' '["v1.0.1"]' '[]' "R5 hook class, no-write line" "$NOWRITE"
mk HIMMEL-9856 "To Do" Medium '[]' '["v1.0.1"]' '[]' "R6 a pathed Files line does not clear it" "$NOWRITE
Files: scripts/lib/p9848-d.sh"
mk HIMMEL-9857 "In Progress" Medium '[]' '["v1.0.1"]' '[]' "R7 a pathed remainder clears it" "$NOWRITE"
mk HIMMEL-9858 "IN CI" Medium '[]' '[]' '[]' "R5 merged, no-write line" "$NOWRITE"
M="$M_SAVE"
printf 'Remaining: S7 (the chief-run station first run on live state, no code).\n' > "$PR_BODY_DIR/9852"
printf 'Remaining: edit scripts/lib/p9848-c.sh for the last slice.\n' > "$PR_BODY_DIR/9857"
: > "$WORK/s9848/status-events.jsonl"
for n in 9852 9857; do
    printf '{"ts":"t","event":"merge","key":"HIMMEL-%s","pr":"%s","contract":"no","result":"noop"}\n' "$n" "$n" >> "$WORK/s9848/status-events.jsonl"
done
cat > "$WORK/classify-p" <<'EOF'
#!/usr/bin/env bash
for k in "$@"; do
    case "$k" in
        HIMMEL-9855) printf '%s\tHOOK-BYPASS\tstub\n' "$k" ;;
        *) printf '%s\tLOCAL-NATIVE\tstub\n' "$k" ;;
    esac
done
EOF
chmod +x "$WORK/classify-p"
P_PRS="$(cat "$PRS_TSV")"; P_MERGED="$(cat "$MERGED_TSV")"
: > "$PRS_TSV"
printf '4358\tfix(x): [HIMMEL-9858] merged\tfix/himmel-9858-m\n' > "$MERGED_TSV"
runp() { NEXT_DISPATCH_MIRROR="$MP" NEXT_DISPATCH_GH_CMD="$WORK/gh" NEXT_DISPATCH_CLASSIFY_CMD="$WORK/classify-p" bash "$SUT" --top 20 --workers-dir "$WORK/s9848/workers" --workers-from "$WORK/fleet5.json" "$@" 2>/dev/null; }
rp="$(runp --why)"
prow() { local kind="$1" num="$2"; printf '%s\n' "$rp" | grep -E "^(# )?${kind}[[:space:]]HIMMEL-${num}[[:space:]:]" || true; }
lastf() { printf '%s\n' "$1" | awk -F'\t' '{print $NF}'; }
[ "$(lastf "$(prow LOCAL 9851)")" = proof ] && pass "R1: a no-write Writes line lists the ticket with proof as its last field" || fail "R1: last field of '$(prow LOCAL 9851)'"
has "R1: and column 0 is LOCAL with no file" "$(prow LOCAL 9851)" "files=-"
has "R1: --why names the nowrite scope" "$rp" "# scope HIMMEL-9851 Writes: line nowrite: -"
[ "$(lastf "$(prow RESUME 9852)")" = proof ] && pass "R2: a RESUME row whose remainder needs no code ends in proof" || fail "R2: last field of '$(prow RESUME 9852)'"
has "R3: prose saying no code with no path still lists with no file" "$(prow LOCAL 9853)" "files=-"
lacks "R3: and carries no proof field" "$(prow LOCAL 9853)" "proof"
has "R4: a pathed Writes line wins" "$(prow LOCAL 9854)" "files=scripts/lib/p9848-a.sh"
lacks "R4: and carries no proof field" "$(prow LOCAL 9854)" "proof"
[ "$(lastf "$(prow LOCAL 9855)")" = proof ] && pass "R5: a HOOK-BYPASS ticket with a no-write line ends in proof" || fail "R5: last field of '$(prow LOCAL 9855)'"
lacks "R5: and carries no hook field" "$(prow LOCAL 9855)" "	hook"
has "R5: the merged ticket is MERGED-NOT-CLOSED" "$rp" "MERGED-NOT-CLOSED	HIMMEL-9858"
lacks "R5: and carries no proof field" "$(prow MERGED-NOT-CLOSED 9858)" "proof"
has "R6: a pathed Files line does not clear the tag (no file)" "$(prow LOCAL 9856)" "files=-"
[ "$(lastf "$(prow LOCAL 9856)")" = proof ] && pass "R6: and the row ends in proof" || fail "R6: last field of '$(prow LOCAL 9856)'"
has "R7: a pathed remainder names its file" "$(prow RESUME 9857)" "files=scripts/lib/p9848-c.sh"
lacks "R7: and carries no proof field" "$(prow RESUME 9857)" "	proof"
rpp="$(runp --dispositions --priority-pool-only)"
has "R5: pool-only lists the proof ticket as LOCAL in its disposition line" "$rpp" "# disposition HIMMEL-9851 listed LOCAL"
has "R5: and its no-path control the same" "$rpp" "# disposition HIMMEL-9853 listed LOCAL"
rp="$rpp"
has "R5: and column 0 is LOCAL for the proof row" "$(prow LOCAL 9851)" "files=-"

MU="$WORK/m10199/HIMMEL"; mkdir -p "$MU" "$WORK/s10199/workers"; cp "$WORK/jira-mirror/HIMMEL.versions.tsv" "$WORK/m10199/HIMMEL.versions.tsv"
M_SAVE="$M"; M="$MU"
for n in 10301 10302 10303 10304 10305 10306 10307 10311 10313 10314 10315; do
    mk "HIMMEL-$n" "In Progress" Medium '[]' '["v1.0.1"]' '[]' "U row $n" "Edit scripts/lib/p10199-$n.sh."
done
M="$M_SAVE"
printf 'Remaining: S1 (N6265, held after N6235), S3 (chief-run).\n' > "$PR_BODY_DIR/10301"
printf 'Remaining: S1 wires the flag\nRemaining: S3 (chief-run)\n' > "$PR_BODY_DIR/10302"
cat > "$PR_BODY_DIR/10303" <<'EOF'
## Ticket coverage

- spec-r1-U1: done
- spec-r1-U2: done
- spec-r1-U3: done
- spec-r1-U4: done
- spec-r1-U5: done
- plan-r1-U1: done
- plan-r1-U2: done
- plan-r1-U3: done
- plan-r1-U4: done
- The listing change in next-dispatchable.sh (S1): done
- DoD: the pool listing shows the open tickets as PROOF rows (S3): owed → chief by 2026-11-28
- DoD: one wave of proof workers closes at least half (S3, operator closes): owed → operator by 2026-11-28

Remaining: S3 (chief-run, no code)
EOF
printf 'Remaining: only a clean live shift, no code.\n' > "$PR_BODY_DIR/10304"
printf 'Remaining: S3 (chief-run, no code)\n\n## Ticket coverage\n\n- VM row 1, a worker merges a throwaway PR: owed → chief by 2026-11-20\n' > "$PR_BODY_DIR/10305"
printf '## Ticket coverage\n\n- wire the flag: deferred → HIMMEL-10306 later\n\nRemaining: S3 (chief-run)\n' > "$PR_BODY_DIR/10306"
printf 'Remaining: run bash scripts/lib/p10199-c.sh once on the station.\n' > "$PR_BODY_DIR/10307"
printf 'Remaining: S3 (chief-run, no code)\n' > "$PR_BODY_DIR/10311"
printf 'Remaining: edit scripts/lib/p10199-d.sh\n' > "$PR_BODY_DIR/10312"
printf 'Remaining: S3 (chief-run, S4 verify the VM row), S5 (chief-run)\n' > "$PR_BODY_DIR/10313"
printf 'Remaining: S3 (chief-run; S4 verify the VM row); S5 (chief-run)\n' > "$PR_BODY_DIR/10314"
printf 'Remaining: S3 (chief-run); S4 wires the flag\n' > "$PR_BODY_DIR/10315"
: > "$WORK/s10199/status-events.jsonl"
for pair in 10301:10301 10302:10302 10303:10303 10304:10304 10305:10305 10306:10306 10307:10307 10311:10311 10311:10312 10313:10313 10314:10314 10315:10315; do
    printf '{"ts":"t","event":"merge","key":"HIMMEL-%s","pr":"%s","contract":"no","result":"noop"}\n' "${pair%%:*}" "${pair##*:}" >> "$WORK/s10199/status-events.jsonl"
done
runu() { NEXT_DISPATCH_MIRROR="$MU" NEXT_DISPATCH_GH_CMD="$WORK/gh" NEXT_DISPATCH_CLASSIFY_CMD="$WORK/classify-p" bash "${U_SUT:-$SUT}" --top 20 --workers-dir "$WORK/s10199/workers" --workers-from "$WORK/fleet5.json"; }
rp="$(runu 2>/dev/null)"
for n in 10301 10302; do
    has "U1/U2 ($n): a mixed code and chief-run remainder is a RESUME row" "$rp" "RESUME	HIMMEL-$n	"
    has "U1/U2 ($n): and keeps the description's file" "$(prow RESUME "$n")" "files=scripts/lib/p10199-$n.sh"
    [ "$(lastf "$(prow RESUME "$n")")" != proof ] && pass "U1/U2 ($n): and is not tagged proof" || fail "U1/U2 ($n): tagged proof: '$(prow RESUME "$n")'"
done
for n in 10303 10304 10305 10313 10314; do
    case "$(lastf "$(prow RESUME "$n")")" in proof|proof-staging=*) u_proof=1 ;; *) u_proof=0 ;; esac
    [ "$u_proof" = 1 ] && pass "U3/U4/U5/U13/U14 ($n): a remainder whose every slice writes nothing ends in proof" || fail "U3/U4/U5/U13/U14 ($n): last field of '$(prow RESUME "$n")'"
done
[ "$(lastf "$(row91 RESUME 9615)")" = proof ] && pass "U4: the PR 9625 remainder (a clean live shift, no code) ends in proof" || fail "U4: last field of '$(row91 RESUME 9615)'"
for n in 10306 10315; do
    has "U6/U14 ($n): a code slice beside a chief-run one keeps the description's file" "$(prow RESUME "$n")" "files=scripts/lib/p10199-$n.sh"
    [ "$(lastf "$(prow RESUME "$n")")" != proof ] && pass "U6/U14 ($n): and is not tagged proof" || fail "U6/U14 ($n): tagged proof: '$(prow RESUME "$n")'"
done
has "U7: a pathless remainder that only runs a script keeps the description's write file" "$(prow RESUME 10307)" "files=scripts/lib/p10199-10307.sh"
has "U11: a newer code remainder supersedes an older no-write one" "$(prow RESUME 10311)" "files=scripts/lib/p10199-d.sh"
[ "$(lastf "$(prow RESUME 10311)")" != proof ] && pass "U11: and is not tagged proof" || fail "U11: tagged proof: '$(prow RESUME 10311)'"
U12="$WORK/u12"; mkdir -p "$U12/scripts/handover/chief-kit" "$U12/scripts/lib"
for u12_f in "$HERE"/*; do [ ! -f "$u12_f" ] || cp "$u12_f" "$U12/scripts/handover/chief-kit/"; done
for u12_f in "$HERE"/../../lib/*; do [ ! -f "$u12_f" ] || cp "$u12_f" "$U12/scripts/lib/"; done
rm -f "$U12/scripts/lib/pr_remainder.py"
u12_err="$(U_SUT="$U12/scripts/handover/chief-kit/next-dispatchable.sh" runu 2>&1 >/dev/null)"; u12_rc=$?
[ "$u12_rc" = 3 ] && pass "U12: a pr_remainder.py that cannot be loaded exits 3" || fail "U12: a pr_remainder.py that cannot be loaded exits 3 (rc $u12_rc)"
has "U12: and says so on stderr" "$u12_err" "# next-dispatchable: pr_remainder.py unreadable ("

DOD_9556='- A grouping table of the denials, each group marked allowed or kept, with the reason.
- In a VM session, a worker merges a throwaway trust-path PR on a valid go.sh GO file with no classifier refusal.
- In a VM session, a kept-refused shape still refuses.
- docs/setup/settings-template.json carries the change.'
PROOF_9556='RED then GREEN on the DoD rows. A settings-template row in the existing settings suite fails on main at the base and passes at the head once docs/setup/settings-template.json carries the allowed shapes. The grouping table (each group marked allowed or kept, with its reason) is in the PR. The two VM rows are run on a test VM with the exact commands the PR lists: a worker merges a throwaway trust-path PR on a valid go.sh GO file with no classifier refusal, and one kept-refused shape still refuses.'
MSG="$WORK/m10203/HIMMEL"; mkdir -p "$MSG" "$WORK/s10203/workers"; cp "$WORK/jira-mirror/HIMMEL.versions.tsv" "$WORK/m10203/HIMMEL.versions.tsv"
mkps() {
    local m_save="$M"; M="$MSG"
    MK_BARE=1 mk "$1" "$2" Medium '[]' '["v1.0.1"]' '[]' "S row $1" "$(printf '%s\n\nDoD\n%s\n\nProof\n%s\n%s' "$3" "$4" "$5" "${6:-}")"
    M="$m_save"
}
mkps HIMMEL-10401 "To Do" "Writes: none (chief-run proof, no code)" "$DOD_9556" "$PROOF_9556"
mkps HIMMEL-10402 "To Do" "Writes: none (chief-run proof, no code)" "$DOD_9556" "$PROOF_9556" "Staging: gh-token, bypass-launch"
mkps HIMMEL-10403 "In Progress" "Edit scripts/lib/p10203-s10.sh." "$DOD_9556" "$PROOF_9556"
mkps HIMMEL-10404 "In Progress" "Edit scripts/lib/p10203-s4.sh." "$DOD_9556" "$PROOF_9556" "Staging: none"
mkps HIMMEL-10405 "To Do" "Writes: none (chief-run proof, no code)" "- the row is green" "A Go code style row and a note to pat the cache."
mkps HIMMEL-10406 "In Progress" "Edit scripts/lib/p10203-a.sh." "$DOD_9556" "$PROOF_9556"
mkps HIMMEL-10407 "To Do" "Writes: none (chief-run proof, no code)" "- the row is green" "A RED row that fails before the change."
s13=0
for pair in 'a guest gh token on the VM|gh-token' 'a PAT for the bot|gh-token' 'relaunch with READ_SECRETS_OK=1|read-secrets' 'the TOTP from the seed|read-secrets' \
            'a bypass-queue launch|bypass-launch' 'an operator go code|go-code' 'the operator approves the command|operator-step' 'real credentials on the guest|guest-credential'; do
    s13=$((s13 + 1)); mkps "HIMMEL-1042$s13" "To Do" "Writes: none (chief-run proof, no code)" "- the row is green" "Run it with ${pair%%|*}."
done
mkps HIMMEL-10408 "To Do" "Writes: none (chief-run proof, no code)" "- the row is green" "A RED row that fails before the change." "Staging: sudoedit the config, rotate the key"
mkps HIMMEL-10409 "To Do" "Writes: none (chief-run proof, no code)" "- the row is green" "The operator approves the run." "Staging: rotate the key"
mkps HIMMEL-10431 "To Do" "Writes: none (chief-run proof, no code)" "- the row is green" "A pat on the back and Go file names."
mkps HIMMEL-10432 "To Do" "Writes: none (chief-run proof, no code)" "- the row is green" "A Go code review and pat the cache."
printf 'Remaining: S3 (chief-run, no code)\n' > "$PR_BODY_DIR/10403"
printf 'Remaining: S3 (chief-run, no code)\n\n## Ticket coverage\n\n- a throwaway PR run: owed → chief by 2026-11-25\n' > "$PR_BODY_DIR/10404"
printf '## Ticket coverage\n\n- a throwaway PR run: owed → chief by 2026-11-25\n' > "$PR_BODY_DIR/10406"
printf 'Remaining: edit scripts/lib/p10203-a.sh\n' > "$PR_BODY_DIR/10416"
: > "$WORK/s10203/status-events.jsonl"
for pair in 10403:10403 10404:10404 10406:10406 10406:10416; do
    printf '{"ts":"t","event":"merge","key":"HIMMEL-%s","pr":"%s","contract":"no","result":"noop"}\n' "${pair%%:*}" "${pair##*:}" >> "$WORK/s10203/status-events.jsonl"
done
runst() { NEXT_DISPATCH_MIRROR="$MSG" NEXT_DISPATCH_GH_CMD="$WORK/gh" NEXT_DISPATCH_CLASSIFY_CMD="$WORK/classify-p" bash "$SUT" --top 40 --workers-dir "$WORK/s10203/workers" --workers-from "$WORK/fleet5.json" "$@"; }
rp="$(runst --why 2>/dev/null)"
S9556_ALL='proof-staging=guest-credential,throwaway-repo,go-file'
[ "$(lastf "$(prow LOCAL 10401)")" = "$S9556_ALL" ] && pass "S1: a proof row needing staging ends in proof-staging=<needs>" || fail "S1: last field of '$(prow LOCAL 10401)'"
has "S1: --why names the go-file need" "$rp" '# staging HIMMEL-10401 go-file (chief): "GO file"'
[ "$(lastf "$(prow LOCAL 10402)")" = 'proof-staging=guest-credential,gh-token,bypass-launch,throwaway-repo,go-file' ] && pass "S2: a Staging: line adds its needs in table order" || fail "S2: last field of '$(prow LOCAL 10402)'"
[ "$(lastf "$(prow RESUME 10403)")" = "$S9556_ALL" ] && pass "S10: a RESUME row with a no-write remainder carries the field" || fail "S10: last field of '$(prow RESUME 10403)'"
[ "$(lastf "$(prow RESUME 10404)")" = "proof-staging=$(cat "$HERE/fixtures/proof-staging-expected.txt")" ] && pass "S4: Staging: none drops the DoD needs and keeps a chief-owed need (shared expected list)" || fail "S4: last field of '$(prow RESUME 10404)'"
[ "$(lastf "$(prow LOCAL 10405)")" = proof ] && pass "S8: Go code style and pat the cache are no need" || fail "S8: last field of '$(prow LOCAL 10405)'"
lacks "S8: and no staging line is printed" "$rp" "# staging HIMMEL-10405"
has "S9: a code remainder beside a chief-owed text keeps its file" "$(prow RESUME 10406)" "files=scripts/lib/p10203-a.sh"
lacks "S9: and carries neither proof nor proof-staging" "$(prow RESUME 10406)" "proof"
for n in 1 2 3 4 5 6 7 8; do
    want="$(printf 'gh-token\ngh-token\nread-secrets\nread-secrets\nbypass-launch\ngo-code\noperator-step\nguest-credential\n' | sed -n "${n}p")"
    [ "$(lastf "$(prow LOCAL "1042$n")")" = "proof-staging=$want" ] && pass "S13 ($n): the $want pattern matches its text" || fail "S13 ($n): last field of '$(prow LOCAL "1042$n")', want $want"
done
for n in 1 2; do
    [ "$(lastf "$(prow LOCAL "1043$n")")" = proof ] && pass "S14 ($n): a case control yields no need" || fail "S14 ($n): last field of '$(prow LOCAL "1043$n")'"
done
[ "$(lastf "$(prow LOCAL 10408)")" = "proof-staging=operator-step" ] && pass "S15: free-text Staging tokens list as one operator-step need" || fail "S15: last field of '$(prow LOCAL 10408)'"
has "S15: and --why keeps every token" "$rp" '# staging HIMMEL-10408 operator-step (operator): "sudoedit the config; rotate the key"'
has "S15: a free-text token beside a matched operator-step keeps both" "$rp" '# staging HIMMEL-10409 operator-step (operator): "operator approves; rotate the key"'
cat > "$WORK/s6-staging.py" <<'EOF'
def needs(mirror_text, answers=(), unread=(), cli=None):
    return [('x-need', 'operator', 'w')]
EOF
rp="$(ND_STAGING="$WORK/s6-staging.py" runst 2>/dev/null)"
[ "$(lastf "$(prow LOCAL 10407)")" = "proof-staging=x-need" ] && pass "S6: the listing takes its needs from the ND_STAGING module" || fail "S6: last field of '$(prow LOCAL 10407)'"
rp="$(ND_TICKET_POLICY_CLI="$WORK/no-such-cli.mjs" runst 2>/dev/null)"
[ "$(lastf "$(prow LOCAL 10407)")" = "proof-staging=unknown" ] && pass "S11: a failed --sections call lists proof-staging=unknown" || fail "S11: last field of '$(prow LOCAL 10407)'"
s11_err="$(ND_STAGING="$WORK/no-such-staging.py" runst 2>&1 >/dev/null)"; s11_rc=$?
[ "$s11_rc" = 3 ] && pass "S11: a proof_staging.py that cannot be loaded exits 3" || fail "S11: a proof_staging.py that cannot be loaded exits 3 (rc $s11_rc)"
has "S11: and says so on stderr" "$s11_err" "# next-dispatchable: proof_staging.py unreadable ("
cat > "$WORK/s12-staging.py" <<'EOF'
import importlib.util, os
_s = importlib.util.spec_from_file_location('proof_staging_real', os.environ['STAGING_REAL'])
_m = importlib.util.module_from_spec(_s)
_s.loader.exec_module(_m)
def __getattr__(name):
    if name == 'needs':
        if os.path.exists(os.environ['STAGING_DEL']):
            os.remove(os.environ['STAGING_DEL'])
        return _m.needs
    raise AttributeError(name)
EOF
MS12="$WORK/m10203b/HIMMEL"; mkdir -p "$MS12"; cp "$MSG/HIMMEL-10407.md" "$MS12/"; cp "$WORK/jira-mirror/HIMMEL.versions.tsv" "$WORK/m10203b/HIMMEL.versions.tsv"
GONE_FILE="$MS12/HIMMEL-10407.md"
rp="$(STAGING_DEL="$GONE_FILE" STAGING_REAL="$HERE/proof_staging.py" ND_STAGING="$WORK/s12-staging.py" NEXT_DISPATCH_MIRROR="$MS12" NEXT_DISPATCH_GH_CMD="$WORK/gh" NEXT_DISPATCH_CLASSIFY_CMD="$WORK/classify-p" bash "$SUT" --top 40 --workers-dir "$WORK/s10203/workers" --workers-from "$WORK/fleet5.json" 2>/dev/null)"
[ "$(lastf "$(prow LOCAL 10407)")" = "proof-staging=unknown" ] && pass "S12: a mirror file that vanishes before the listing's second read lists proof-staging=unknown" || fail "S12: last field of '$(prow LOCAL 10407)'"
mkps HIMMEL-10407 "To Do" "Writes: none (chief-run proof, no code)" "- the row is green" "A RED row that fails before the change."
printf '%s\n' "$P_PRS" > "$PRS_TSV"; printf '%s\n' "$P_MERGED" > "$MERGED_TSV"

# A chain sibling's worker owns its ticket only while it can be alive: a fresh queue lock, or a doc armed within the hour.
B91="$WORK/h91/yotamleo/himmel"; mkdir -p "$B91" "$WORK/h91/.locks/queue/held.lock" "$WORK/h91/.locks/queue/stale.lock" "$WORK/h91/.locks/queue/named.lock"
M91S="$WORK/m91s/HIMMEL"; mkdir -p "$M91S" "$WORK/s91s/workers"; cp "$WORK/jira-mirror/HIMMEL.versions.tsv" "$WORK/m91s/HIMMEL.versions.tsv"
M_SAVE="$M"; M="$M91S"
for n in 1 2 3 4 5; do mk "HIMMEL-963$n" "In Progress" Medium '[]' '["v1.0.1"]' '[]' "sibling case $n" "Edit scripts/lib/nd91-s$n.sh."; done
M="$M_SAVE"
for n in 1 2 3 4; do printf '# worker\n> **Writes:** scripts/lib/nd91-s%s.sh\n' "$n" > "$B91/HIMMEL-963$n-N96$n-case-2026-11-06.md"; done
printf '# HIMMEL-9635 worker\n> **Writes:** scripts/lib/nd91-s5.sh\n' > "$B91/N965-ops-2026-11-06.md"
ago "$B91/N965-ops-2026-11-06.md" 3
printf '{"handover":"%s","heartbeat":"%s"}\n' "$B91/N965-ops-2026-11-06.md" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$WORK/h91/.locks/queue/named.lock/owner.json"
ago "$B91/HIMMEL-9631-N961-case-2026-11-06.md" 3
ago "$B91/HIMMEL-9632-N962-case-2026-11-06.md" 3
ago "$B91/HIMMEL-9633-N963-case-2026-11-06.md" 3
printf '{"handover":"%s","heartbeat":"%s"}\n' "$B91/HIMMEL-9632-N962-case-2026-11-06.md" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$WORK/h91/.locks/queue/held.lock/owner.json"
printf '{"handover":"%s","heartbeat":"2026-01-01T00:00:00Z"}\n' "$B91/HIMMEL-9633-N963-case-2026-11-06.md" > "$WORK/h91/.locks/queue/stale.lock/owner.json"
mkfleet "$B91/HIMMEL-nextleg-2026-11-06TA-roadmap-chief.fleet.json" "N965:$B91/N965-ops-2026-11-06.md" "N961:$B91/HIMMEL-9631-N961-case-2026-11-06.md" "N962:$B91/HIMMEL-9632-N962-case-2026-11-06.md" "N963:$B91/HIMMEL-9633-N963-case-2026-11-06.md" "N964:$B91/HIMMEL-9634-N964-case-2026-11-06.md"
mkfleet "$B91/HIMMEL-nextleg-2026-11-07TB-roadmap-chief.fleet.json"
s91="$(NEXT_DISPATCH_MIRROR="$M91S" NEXT_DISPATCH_GH_CMD="$WORK/gh" NEXT_DISPATCH_CLASSIFY_CMD="$WORK/classify" bash "$SUT" --top 20 --dispositions --workers-dir "$WORK/s91s/workers" --workers-from "$B91/HIMMEL-nextleg-2026-11-07TB-roadmap-chief.fleet.json" 2>/dev/null)"
lacks "an old sibling with no affirmative terminal evidence stays protected" "$s91" "RESUME	HIMMEL-9631	"
has "the unknown sibling remains a visible owner" "$s91" "live worker N961"
lacks "a sibling worker with a fresh queue lock keeps its ticket" "$s91" "RESUME	HIMMEL-9632	"
has "and is named as the owner" "$s91" "# disposition HIMMEL-9632 in-flight owned by live worker N962 of the chief on HIMMEL-nextleg-2026-11-06TA-roadmap-chief"
lacks "a stale heartbeat cannot retire a sibling worker" "$s91" "RESUME	HIMMEL-9633	"
lacks "a fresh lock on a doc whose name carries no ticket keeps the ticket its title names" "$s91" "RESUME	HIMMEL-9635	"
lacks "a sibling doc armed within the hour, its lock not yet taken, keeps its ticket" "$s91" "RESUME	HIMMEL-9634	"

# --- merged-or-not from local git, each merged PR body read once, a rate limit named and bounded ---
G9="$WORK/g9438"; mkdir -p "$G9"
# the fixture must be its own repository: under a TMPDIR inside another checkout, a failed init would commit into that parent
{ git -C "$G9" init -q -b main && [ "$(git -C "$G9" rev-parse --show-toplevel)" = "$(cd "$G9" && pwd -P)" ]; } \
    || { fail "9438: the fixture main repo could not be created"; printf '\n%d failure(s)\n' "$fails"; exit 1; }
git -C "$G9" -c user.name=t -c user.email=t@example.com -c commit.gpgsign=false -c core.hooksPath=/dev/null commit -q --allow-empty -m "fix(x): [HIMMEL-9601] merged on main (#4300)" || fail "9438: fixture main"
M9="$WORK/m9438/HIMMEL"; mkdir -p "$M9"
git -C "$G9" -c user.name=t -c user.email=t@example.com -c commit.gpgsign=false -c core.hooksPath=/dev/null commit -q --allow-empty -m "fix(x): an unrelated slice (#4301)" -m "Follows up [HIMMEL-9603], which is not merged by this commit." || fail "9438: fixture body mention"
M_SAVE="$M"; M="$M9"
mk HIMMEL-9603 "IN CI" Medium '[]' '[]' '[]' "in ci, named only in another commit's body" "Edit scripts/lib/g5.sh."
mk HIMMEL-9601 "IN CI" Medium '[]' '[]' '[]' "in ci, merged on local main" "Edit scripts/lib/g1.sh."
mk HIMMEL-9602 "IN CI" Medium '[]' '[]' '[]' "in ci, not on local main" "Edit scripts/lib/g2.sh."
M="$M_SAVE"
printf '4300\tfix(x): [HIMMEL-9601] merged\tfix/himmel-9601-m\n' > "$WORK/merged9.tsv"
: > "$PRS_TSV"
searches() { SEARCHED="$(grep -c -e "--search $1 " "$GH_ARGS")"; }  # sets SEARCHED to the merged-PR searches gh was asked for <key>
run9() { # <git dir> <main ref> <merged tsv>: the IN CI rows of the fixture mirror
    NEXT_DISPATCH_MIRROR="$M9" NEXT_DISPATCH_GH_CMD="$WORK/gh" NEXT_DISPATCH_GIT_DIR="$1" NEXT_DISPATCH_MAIN_REF="$2" MERGED_TSV="$3" bash "$SUT" --resume-only --workers-from "$WORK/fleet6.json" 2>/dev/null
}
: > "$GH_ARGS"
loc9="$(run9 "$G9" main "$WORK/merged9.tsv")"
has "9438: an IN CI ticket cited on local main is a MERGED-NOT-CLOSED row" "$loc9" "MERGED-NOT-CLOSED	HIMMEL-9601"
searches HIMMEL-9601; n_s9601="$SEARCHED"
[ "$n_s9601" = 0 ] && pass "9438: the ticket cited on local main costs no merged-PR search" || fail "9438: the ticket cited on local main costs no merged-PR search (got $n_s9601)"
has "9438: an IN CI ticket NOT on local main is still asked of GitHub (the ref may lag) and is a RESUME row" "$loc9" "RESUME	HIMMEL-9602"
searches HIMMEL-9602; n_s9602="$SEARCHED"
[ "$n_s9602" = 1 ] && pass "9438: the ticket not on local main is searched once" || fail "9438: the ticket not on local main is searched once (got $n_s9602)"
has "9438: a ticket named only in another commit's body is not called merged by it" "$loc9" "RESUME	HIMMEL-9603"
# (a) the answer from local git equals the answer from GitHub: same bytes with git unusable (the GitHub-only path); a RED control with one altered line must differ
gh9="$(run9 "$WORK/no-such-git" main "$WORK/merged9.tsv")"
printf '%s\n' "$loc9" > "$WORK/loc9.out"; printf '%s\n' "$gh9" > "$WORK/gh9.out"
cmp -s "$WORK/loc9.out" "$WORK/gh9.out" && pass "9438: output with local git is byte-identical to the GitHub-only output" || fail "9438: output with local git is byte-identical to the GitHub-only output"
printf '4300\tfix(x): [HIMMEL-9602] altered\tfix/himmel-9602-m\n' > "$WORK/merged9-alt.tsv"
alt9="$(run9 "$WORK/no-such-git" main "$WORK/merged9-alt.tsv")"
printf '%s\n' "$alt9" > "$WORK/alt9.out"
cmp -s "$WORK/loc9.out" "$WORK/alt9.out" && fail "9438: RED control: one altered line must make the compare fail" || pass "9438: RED control: one altered line makes the compare fail"
# unknown fails closed: no local ref and GitHub unreadable: the ticket is NOT called merged and nothing is dispatched on a guess
: > "$MERGED_FAIL"
unk9="$(run9 "$G9" no-such-ref "$WORK/merged9.tsv")"
rm -f "$MERGED_FAIL"
has "9438: no local ref and a failed GitHub read is reported as unknown" "$unk9" "merged PRs unknown"
lacks "9438: an unknown merge is not called merged" "$unk9" "MERGED-NOT-CLOSED"
lacks "9438: an unknown merge is not dispatched on a guess" "$unk9" "RESUME	HIMMEL-960"

# each merged PR body is read once per TTL, by PR number and ticket; a body that says nothing or could not be read is never cached
PM9="$WORK/pm9438"; mkdir -p "$PM9/workers"
export PR_BODY_DIR="$WORK/prbody"; mkdir -p "$PR_BODY_DIR"
printf 'Slice.\n\nRemaining: the second half in scripts/lib/g3.sh\n' > "$PR_BODY_DIR/9611"
printf 'Slice, no tail.\n' > "$PR_BODY_DIR/9612"
M9B="$WORK/m9438b/HIMMEL"; mkdir -p "$M9B"
M_SAVE="$M"; M="$M9B"
mk HIMMEL-9611 "In Progress" Medium '[]' '[]' '[]' "partial with a remainder" "Edit scripts/lib/g3.sh."
mk HIMMEL-9612 "In Progress" Medium '[]' '[]' '[]' "partial with no remainder" "Edit scripts/lib/g4.sh."
M="$M_SAVE"
printf '{"ts":"t","event":"merge","key":"HIMMEL-9611","pr":"9611","contract":"no","result":"noop"}\n{"ts":"t","event":"merge","key":"HIMMEL-9612","pr":"9612","contract":"no","result":"noop"}\n' > "$PM9/status-events.jsonl"
: > "$PRS_TSV"
run9b() { # <cache path or off> [extra env...]
    local c="$1"; shift
    env "$@" NEXT_DISPATCH_BODY_CACHE="$c" NEXT_DISPATCH_MIRROR="$M9B" NEXT_DISPATCH_GH_CMD="$WORK/gh" bash "$SUT" --resume-only --workers-dir "$PM9/workers" --workers-from "$WORK/fleet5.json" 2>/dev/null
}
views() { grep -c -e "pr view $1 " "$GH_ARGS"; }
CACHE9="$WORK/body-cache9438.json"; rm -f "$CACHE9"; : > "$GH_ARGS"
b1="$(run9b "$CACHE9" X=1)"; b2="$(run9b "$CACHE9" X=1)"
has "9438: a partial merge with a remainder is a RESUME row" "$b1" "RESUME	HIMMEL-9611"
printf '%s\n' "$b1" > "$WORK/b1.out"; printf '%s\n' "$b2" > "$WORK/b2.out"
cmp -s "$WORK/b1.out" "$WORK/b2.out" && pass "9438: the second run's output is byte-identical to the first" || fail "9438: the second run's output is byte-identical to the first"
[ "$(views 9611)" = 1 ] && pass "9438: a merged PR body with a remainder is read once over two runs" || fail "9438: a merged PR body with a remainder is read once over two runs (got $(views 9611))"
[ "$(views 9612)" = 2 ] && pass "9438: a body with no remainder is never cached (read on both runs)" || fail "9438: a body with no remainder is never cached (got $(views 9612))"
run9b "$CACHE9" NEXT_DISPATCH_BODY_TTL=0 > /dev/null
[ "$(views 9611)" = 2 ] && pass "9438: a cached body older than the TTL is read again" || fail "9438: a cached body older than the TTL is read again (got $(views 9611))"
: > "$GH_ARGS"; rm -f "$CACHE9"
run9b off X=1 > /dev/null; run9b off X=1 > /dev/null
[ "$(views 9611)" = 2 ] && pass "9438: with the cache off each run reads the body" || fail "9438: with the cache off each run reads the body (got $(views 9611))"
rm -f "$CACHE9"; : > "$GH_ARGS"; mv "$PR_BODY_DIR/9611" "$PR_BODY_DIR/9611.away"  # the stub's view of a missing body fails
bf="$(run9b "$CACHE9" X=1)"
mv "$PR_BODY_DIR/9611.away" "$PR_BODY_DIR/9611"
has "9438: a body gh cannot read is flagged unreadable" "$bf" "NEEDS-CHIEF-NOTE HIMMEL-9611: merged PR #9611 body could not be read (gh failed)"
: > "$GH_ARGS"
bg="$(run9b "$CACHE9" X=1)"
has "9438: an unreadable body was not cached: the next run reads it" "$bg" "RESUME	HIMMEL-9611"
printf 'garbage{' > "$CACHE9"
bh="$(run9b "$CACHE9" X=1)"
has "9438: a corrupt cache file is ignored, the body is read again" "$bh" "RESUME	HIMMEL-9611"

# (b) a rate-limit answer from gh: the dispatcher returns within a bound, names the rate limit, and does not hang
cat > "$WORK/gh-rl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_ARGS"
echo 'GraphQL: API rate limit already exceeded for user ID 1. (RATE_LIMIT)' >&2
exit 1
EOF
chmod +x "$WORK/gh-rl"
RL_BOUND=30
: > "$GH_ARGS"
rl_t0="$(date +%s)"
rl9="$(NEXT_DISPATCH_MIRROR="$M9" NEXT_DISPATCH_GH_CMD="$WORK/gh-rl" NEXT_DISPATCH_GIT_DIR="$G9" NEXT_DISPATCH_MAIN_REF=main timeout -k 2 "$RL_BOUND" bash "$SUT" --resume-only --workers-from "$WORK/fleet6.json" 2>/dev/null)"; rl_rc=$?
rl_secs=$(( $(date +%s) - rl_t0 ))
[ "$rl_rc" != 124 ] && [ "$rl_rc" != 137 ] && pass "9438: a rate-limited gh does not hang the dispatcher (rc $rl_rc)" || fail "9438: a rate-limited gh does not hang the dispatcher (rc $rl_rc after ${rl_secs}s, bound ${RL_BOUND}s)"
[ "$rl_secs" -lt "$RL_BOUND" ] && pass "9438: a rate-limited gh returns within ${RL_BOUND}s (took ${rl_secs}s)" || fail "9438: a rate-limited gh returns within ${RL_BOUND}s (took ${rl_secs}s)"
has "9438: the output names the rate limit" "$rl9" "# quota-pause QUOTA-PAUSE"
lacks "9438: a rate-limited read lists no IN CI row" "$rl9" "RESUME	HIMMEL-960"

S1D="$WORK/s1d"; mkdir -p "$S1D"; export DD_DIR="$S1D"
: > "$S1D/prs.tsv"
S1M="$WORK/s1m/HIMMEL"; mkdir -p "$S1M"
M_SAVE="$M"; M="$S1M"
mk HIMMEL-9701 "In Progress" High '[]' '["v1.0.1"]' '[]' "in work, its file is a live worker's" "Edit scripts/s1/own.sh only."
mk HIMMEL-9702 "To Do" High '[]' '["v1.0.1"]' '[]' "first on a shared file" "Edit scripts/s1/shared.sh only."
mk HIMMEL-9703 "To Do" Medium '[]' '["v1.0.1"]' '[]' "second on a shared file" "Edit scripts/s1/shared.sh too."
mk HIMMEL-9704 "To Do" Medium '[]' '["v1.0.1"]' '[]' "free" "Edit scripts/s1/free.sh only."
M="$M_SAVE"
cp "$WORK/jira-mirror/HIMMEL.versions.tsv" "$WORK/s1m/HIMMEL.versions.tsv"
S1W="$WORK/HIMMEL-9700-N97-s1.md"
printf '# live\n> **Writes:** scripts/s1/own.sh\n' > "$S1W"
printf '{"schema":1,"workers":[{"doc":"%s","label":"N97"}]}\n' "$S1W" > "$WORK/fleet-s1.json"
s1run() { NEXT_DISPATCH_MIRROR="$S1M" NEXT_DISPATCH_GH_CMD="$WORK/gh-dd" NEXT_DISPATCH_CLASSIFY_CMD="$WORK/classify2" bash "$SUT" --top 20 --workers-from "$WORK/fleet-s1.json" "$@" 2>/dev/null; }
s1_out="$(s1run)"
s1_ro="$(s1run --resume-only)"
has "S1: an In Progress ticket on a live worker's Writes file is a RESUME row" "$s1_out" "RESUME	HIMMEL-9701"
lacks "S1: no RESUME-HELD line is printed (full pass)" "$s1_out" "RESUME-HELD"
has "S1: --resume-only lists it too" "$s1_ro" "RESUME	HIMMEL-9701"
lacks "S1: no RESUME-HELD line is printed (--resume-only)" "$s1_ro" "RESUME-HELD"
has "S1: the RESUME row prints the live worker overlap" "$s1_out" "# overlap HIMMEL-9701 scripts/s1/own.sh with live worker N97"
has "S1: two To Do tickets on one file are both listed (first)" "$s1_out" "HIMMEL-9702	"
has "S1: two To Do tickets on one file are both listed (second)" "$s1_out" "HIMMEL-9703	"
has "S1: the later one carries the listed overlap" "$s1_out" "# overlap HIMMEL-9703 scripts/s1/shared.sh with listed HIMMEL-9702"
lacks "S1: no collision drop is counted" "$(s1run --why)" "# drop HIMMEL-9703 collision"
S1U="$WORK/s1u"; mkdir -p "$S1U"
printf '5001\tfix(x): one\tfix/one\n5002\tfix(x): huge\tfix/huge\n' > "$S1U/prs.tsv"
printf 'scripts/s1/pr-one.sh\n' > "$S1U/files-5001"
: > "$S1U/fail-5002"
s1u_out="$(DD_DIR="$S1U" s1run)"
has "S1: an unreadable PR files read still lists the To Do rows" "$s1u_out" "HIMMEL-9704	"
has "S1: an unreadable PR files read still lists the RESUME row" "$s1u_out" "RESUME	HIMMEL-9701"
has "S1: an unreadable PR files read prints overlap unknown for that PR" "$s1u_out" "# overlap unknown for PR 5002"
lacks "S1: an unreadable PR files read does not mark every open PR unknown" "$s1u_out" "open PRs unknown"
cat > "$WORK/holds-log.py" <<'EOF'
import os, runpy, sys
with open(os.environ['HOLDS_LOG'], 'a') as f:
    f.write(sys.argv[1] + '\n')
sys.argv = [os.environ['STUB_REAL_HOLDS']] + sys.argv[1:]
runpy.run_path(os.environ['STUB_REAL_HOLDS'], run_name='__main__')
EOF
S1P="$WORK/s1p"; mkdir -p "$S1P"
printf '5301\tfix(x): three\tfix/three\n' > "$S1P/prs.tsv"
printf 'scripts/s1/pr-three.sh\n' > "$S1P/files-5301"
export HOLDS_LOG="$WORK/holds-log.txt"; : > "$HOLDS_LOG"
DD_DIR="$S1P" STUB_REAL_HOLDS="$HOLDS_PY" ND_HOLDS="$WORK/holds-log.py" s1run --why > /dev/null
has "S1: control: the holds.py shim ran (parse of the live worker's doc)" "$(cat "$HOLDS_LOG")" "parse"
lacks "S1: the dispatcher calls no holds.py sync-prs" "$(cat "$HOLDS_LOG")" "sync-prs"
lacks "S1: the dispatcher calls no holds.py gc" "$(cat "$HOLDS_LOG")" "gc"
lacks "S1: the dispatcher calls no holds.py read" "$(cat "$HOLDS_LOG")" "read"
printf '# live\nno scope named here\n' > "$WORK/HIMMEL-795-N10-noscope.md"
mkfleet "$WORK/fleet-s10.json" "N5:$WORK/HIMMEL-790-N5-series.md" "N10:$WORK/HIMMEL-795-N10-noscope.md"
sk="$(runs "$SM" 1 --workers-from "$WORK/fleet-s10.json" --why)"
has "S1: a scope-less live worker no longer removes the STACKABLE note" "$sk" "STACKABLE HIMMEL-851 $WORK/HIMMEL-790-N5-series.md"
has "S1: and the scope-less worker is named overlap unknown" "$sk" "# overlap unknown for live worker N10"
has "S1: the header still says live workers unknown (tick reads it)" "$sk" "live workers unknown"
newmir s1fam
mk HIMMEL-870 "To Do" High '[]' '["v1.0.1"]' '[]' "a sub-task in docs/handover" "Edit docs/handover/fa-85.md."
mk HIMMEL-871 "To Do" High '[]' '["v1.0.1"]' '[]' "another sub-task in docs/handover" "Edit docs/handover/sub/fb-85.md."
for k in 870 871; do retype "$M/HIMMEL-$k.md" "Sub-task"; reparent "$M/HIMMEL-$k.md" HIMMEL-860; done
S1FAM="$M"
sf1="$(runs "$S1FAM" 1 --workers-from "$WORK/fleet-s10.json" --why)"
has "S1: a scope-less live worker no longer removes the SERIES FAMILY row" "$sf1" "SERIES FAMILY docs/handover HIMMEL-870,HIMMEL-871"
has "S1: the family run names the scope-less worker overlap unknown" "$sf1" "# overlap unknown for live worker N10"
mkfleet "$WORK/fleet-s11.json" "N11:$WORK/HIMMEL-851-N11-gone.md"
sf2="$(runs "$S1FAM" 1 --workers-from "$WORK/fleet-s11.json" --why)"
lacks "9335 flip2824: an unreadable worker doc withholds the SERIES FAMILY row (N1 sets owners_unknown)" "$sf2" "SERIES FAMILY docs/handover HIMMEL-870,HIMMEL-871"
has "S1: an unreadable worker doc prints overlap unknown for that worker" "$sf2" "# overlap unknown for live worker N11"
sf3="$(runs "$SM" 1 --workers-from "$WORK/fleet-s11.json" --why)"
has "S1: control: an unreadable worker doc still owns the key in its name" "$sf3" "# drop HIMMEL-851 owned by live worker N11"
sf4="$(runs "$S1FAM" 1 --workers-from "$WORK/no-such-fleet.json" --why)"
lacks "S1: control: a missing manifest (owners unknown) still withholds SERIES FAMILY" "$sf4" "SERIES FAMILY docs/handover"
S1Q="$WORK/s1q"; mkdir -p "$S1Q"
S1NOW=1794000000
q8_at() { python3 -I -c 'import datetime, sys
print(datetime.datetime.fromtimestamp(float(sys.argv[1]) - float(sys.argv[2]) * 86400, datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"))' "$S1NOW" "$1"; }
S1QM="$WORK/s1qm/HIMMEL"; mkdir -p "$S1QM"
M_SAVE="$M"; M="$S1QM"
mk HIMMEL-9710 "To Do" High '[]' '["v1.0.1"]' '[]' "named by a PR from outside" "Edit scripts/s1/q8.sh only."
M="$M_SAVE"
cp "$WORK/jira-mirror/HIMMEL.versions.tsv" "$WORK/s1qm/HIMMEL.versions.tsv"
printf 'scripts/s1/q8-other.sh\n' > "$S1Q/files-5201"
q8run() {
    local cross="$1" days="$2"
    printf '5201\tfix(x): [HIMMEL-9710] a change from outside\tfork/q8\t%s\t%s\n' "$cross" "$(q8_at "$days")" > "$S1Q/prs.tsv"
    NEXT_DISPATCH_NOW="$S1NOW" DD_DIR="$S1Q" NEXT_DISPATCH_MIRROR="$S1QM" NEXT_DISPATCH_GH_CMD="$WORK/gh-dd" NEXT_DISPATCH_CLASSIFY_CMD="$WORK/classify2" bash "$SUT" --top 20 --why 2>/dev/null
}
q8_8="$(q8run true 8)"
has "Q8: an outside PR idle 8 days does not own the key it names: it is listed" "$q8_8" "LOCAL	HIMMEL-9710"
has "Q8: and the overlap names the PR and its idle days" "$q8_8" "# overlap HIMMEL-9710 also named by outside PR 5201 (idle 8d)"
q8_7="$(q8run true 7)"
has "Q8: 7 days is enough (seven or more)" "$q8_7" "# overlap HIMMEL-9710 also named by outside PR 5201 (idle 7d)"
q8_3="$(q8run true 3)"
has "Q8: control: an outside PR idle 3 days still owns the key" "$q8_3" "# drop HIMMEL-9710 owned by open PR 5201"
lacks "Q8: control: and the key is not listed" "$q8_3" "LOCAL	HIMMEL-9710"
q8_in="$(q8run false 30)"
has "Q8: control: an inside PR idle 30 days still owns the key" "$q8_in" "# drop HIMMEL-9710 owned by open PR 5201"

Q6="$WORK/q6"; mkdir -p "$Q6/realbin" "$Q6/envroot"
printf '{"schema":1,"workers":[]}\n' > "$Q6/fleet.json"
printf '#!/usr/bin/env bash\necho reached >> "%s"\nexit 1\n' "$Q6/real-gh-reached" > "$Q6/realbin/gh"
cat > "$WORK/gh-q" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$Q_LOG"
mode="${Q_MODE:-healthy}"
probe=0; case "$*" in *rateLimit* | "api -i user"*) probe=1 ;; esac
bucket=graphql; [ "$1" = api ] && case "$*" in *graphql*) ;; *) bucket=core ;; esac
if [ "$probe" = 1 ]; then
    [ "$mode" = hung ] && exec -a "q6-sleep-${Q_TAG:-none}" sleep 60
    rem=4000
    case "$mode:$bucket" in gql-out:graphql | rest-out:core | secondary:*) rem=0 ;; esac
    printf 'HTTP/2.0 200 OK\r\nX-Ratelimit-Remaining: %s\r\nX-Ratelimit-Reset: %s\r\n' "$rem" "$(($(date +%s) + 1800))"
    [ "$mode" != secondary ] || printf 'Retry-After: 60\r\n'
    printf '\r\n{}\n'
    [ "$rem" != 0 ] || exit 1
    exit 0
fi
calls=$(grep -cv -e rateLimit -e 'api -i user' "$Q_LOG")
case "$mode" in
    gql-out | secondary) [ "$bucket" = graphql ] && { echo 'GraphQL: API rate limit already exceeded for user ID 1.' >&2; exit 1; } ;;
    rest-out) [ "$bucket" = core ] && { echo 'gh: API rate limit exceeded for user ID 1. (HTTP 403)' >&2; exit 1; } ;;
    hung-after-probe) exec -a "q6-sleep-${Q_TAG:-none}" sleep 60 ;;
    files-out) case "$*" in */files*) echo 'gh: API rate limit exceeded for user ID 1. (HTTP 403)' >&2; exit 1 ;; esac ;;
    view-out) [ "$1 $2" = "pr view" ] && { echo 'GraphQL: API rate limit already exceeded for user ID 1.' >&2; exit 1; } ;;
    from-third) [ "$calls" -ge 3 ] && { echo 'GraphQL: API rate limit already exceeded for user ID 1.' >&2; exit 1; } ;;
esac
case "$1 $2" in
    "pr list") case "$*" in *merged*) ;; *headRefName*) printf '4601\tfix(x): an open change\tfix/q6-open\n4602\tfix(x): another open change\tfix/q6-other\n' ;; *) printf '4601\n4602\n' ;; esac ;;
    "api "*) echo scripts/q6/pr-file.sh ;;
esac
exit 0
EOF
cat > "$WORK/classify-q" <<'EOF'
#!/usr/bin/env bash
[ -z "${Q_CLASSIFY_LOG:-}" ] || printf '%s\n' "$*" >> "$Q_CLASSIFY_LOG"
if [ "${Q_CLASSIFY:-ok}" = refuse ]; then echo 'GraphQL: API rate limit already exceeded for user ID 1.' >&2; exit 0; fi
[ "${Q_CLASSIFY:-ok}" != hang ] || exec sleep 60
for k in "$@"; do printf '%s\tLOCAL-NATIVE\tstub\n' "$k"; done
EOF
chmod +x "$WORK/gh-q" "$WORK/classify-q"
Q6M="$WORK/q6m/HIMMEL"; mkdir -p "$Q6M"
M_SAVE="$M"; M="$Q6M"
mk HIMMEL-9801 "To Do" High '[]' '["v1.0.1"]' '[]' "a free pool ticket" "Edit scripts/q6/free-a.sh only."
mk HIMMEL-9802 "In Progress" High '[]' '["v1.0.1"]' '[]' "in work, nobody holds it" "Edit scripts/q6/resume-b.sh only."
M="$M_SAVE"
cp "$WORK/jira-mirror/HIMMEL.versions.tsv" "$WORK/q6m/HIMMEL.versions.tsv"
q6run() { # <mode> [extra env...] -- [dispatcher args...]: sets Q6_OUT, Q6_RC, Q6_SECS; a fresh quota dir per run
    local mode="$1" t0 envs=()
    shift
    while [ "$#" -gt 0 ] && [ "$1" != -- ]; do envs+=("$1"); shift; done
    [ "${1:-}" != -- ] || shift
    Q6Q="$(mktemp -d "$Q6/quota.XXXXXX")" || { fail "T6: mktemp -d failed"; return 1; }; : > "$Q6/log"; : > "$Q6/classify.log"; rm -f "$Q6/real-gh-reached"
    t0=$(date +%s)
    Q6_OUT="$(env -u himmel_github_token_vm2 PATH="$Q6/realbin:$PATH" HIMMEL_QUOTA_DIR="$Q6Q" GH_READ_ENV_ROOT="$Q6/envroot" GHQ_PROBE_TIMEOUT=2 \
        Q_MODE="$mode" Q_LOG="$Q6/log" Q_CLASSIFY_LOG="$Q6/classify.log" NEXT_DISPATCH_MIRROR="$Q6M" NEXT_DISPATCH_GH_CMD="$WORK/gh-q" NEXT_DISPATCH_CLASSIFY_CMD="$WORK/classify-q" \
        ${envs[@]+"${envs[@]}"} timeout -k 2 40 bash "$SUT" --top 4 --workers-from "$Q6/fleet.json" "$@" 2>/dev/null)"; Q6_RC=$?  # gnu-ok: the chief kit is Linux-only
    Q6_SECS=$(( $(date +%s) - t0 ))
}
q6_paused() { # <row name> <want prefix: quota-pause or gh-stall>: the single pause line, rc 0, nothing else
    local nl
    nl="$(printf '%s\n' "$Q6_OUT" | grep -c .)"
    [ "$Q6_RC" = 0 ] && pass "T6 $1: rc 0" || fail "T6 $1: rc 0 (got $Q6_RC after ${Q6_SECS}s)"
    [ "$nl" = 1 ] && pass "T6 $1: stdout is one line" || fail "T6 $1: stdout is one line (got $nl: $Q6_OUT)"
    has "T6 $1: the line is # $2" "$Q6_OUT" "# $2 "
    lacks "T6 $1: no POOL-EMPTY" "$Q6_OUT" "POOL-EMPTY"
    lacks "T6 $1: no row" "$Q6_OUT" "HIMMEL-98"
    [ ! -e "$Q6/real-gh-reached" ] && pass "T6 $1: no real gh on PATH was reached" || fail "T6 $1: a gh on PATH was reached"
}
q6run rest-out -- --priority-pool-only
q6_paused "rest-out (core probe at 0)" quota-pause
has "T6 rest-out: the line names the core bucket" "$Q6_OUT" "QUOTA-PAUSE github core token=main"
lacks "T6 I2 rest-out: a paused run makes no call but the probes" "$(grep -v -e rateLimit -e 'api -i user' "$Q6/log")" "pr "
q6run gql-out -- --priority-pool-only
q6_paused "gql-out (graphql probe at 0)" quota-pause
has "T6 gql-out: the line names the graphql bucket" "$Q6_OUT" "QUOTA-PAUSE github graphql token=main"
[ "$(grep -cv -e rateLimit -e 'api -i user' "$Q6/log")" = 0 ] && pass "T6 I2 gql-out: a paused run makes no call but the probes" || fail "T6 I2 gql-out: a paused run makes no call but the probes ($(grep -v -e rateLimit -e 'api -i user' "$Q6/log" | head -3))"
q6run secondary -- --priority-pool-only
q6_paused "secondary (Retry-After at the probe)" quota-pause
q6run hung -- --priority-pool-only
q6_paused "hung (a probe times out)" gh-stall
[ "$Q6_SECS" -le 15 ] && pass "T6 hung: a timed-out probe pauses at once (${Q6_SECS}s)" || fail "T6 hung: a timed-out probe pauses at once (${Q6_SECS}s)"
q6run hung-after-probe NEXT_DISPATCH_GH_TIMEOUT=2 -- --priority-pool-only
q6_paused "hung-after-probe (a list read times out)" gh-stall
[ "$Q6_SECS" -le 15 ] && pass "T6 hung-after-probe: the stalled run ends inside its bound (${Q6_SECS}s)" || fail "T6 hung-after-probe: the stalled run ends inside its bound (${Q6_SECS}s)"
q6run hung-after-probe NEXT_DISPATCH_DEADLINE=4 -- --priority-pool-only
q6_paused "hung-after-probe cut by NEXT_DISPATCH_DEADLINE" gh-stall
[ "$Q6_SECS" -le 15 ] && pass "T6 deadline: a scaled NEXT_DISPATCH_DEADLINE cuts the run (${Q6_SECS}s)" || fail "T6 deadline: a scaled NEXT_DISPATCH_DEADLINE cuts the run (${Q6_SECS}s)"
q6run from-third -- --priority-pool-only
q6_paused "a gh that refuses from its third call" quota-pause
q6run healthy Q_CLASSIFY=refuse -- --priority-pool-only
q6_paused "a refusal only during classification" quota-pause
q6run healthy Q_CLASSIFY=hang NEXT_DISPATCH_GH_TIMEOUT=2 -- --priority-pool-only
q6_paused "a classification that times out" gh-stall
q6run gql-out -- --resume-only
q6_paused "gql-out --resume-only" quota-pause
q6run files-out -- --priority-pool-only
q6_paused "a refused PR files read with two open PRs" quota-pause
q6_after="$(awk '/\/files/ { seen = 1; next } seen && !/rateLimit|api -i user/' "$Q6/log")"
[ -z "$q6_after" ] && pass "T6 fail-fast: no other gh read follows a refused PR files read" || fail "T6 fail-fast: no other gh read follows a refused PR files read (got: $q6_after)"
mkdir -p "$Q6/state/workers"
printf '{"ts":"t","event":"merge","key":"HIMMEL-9802","pr":"4700","contract":"no","result":"noop"}\n' > "$Q6/state/status-events.jsonl"
q6run view-out -- --priority-pool-only --workers-dir "$Q6/state/workers"
q6_paused "a refused merged-PR body read" quota-pause
[ ! -s "$Q6/classify.log" ] && pass "T6 classification is skipped once a read was refused" || fail "T6 classification is skipped once a read was refused (classifier ran: $(head -2 "$Q6/classify.log"))"
q6run healthy -- --priority-pool-only --workers-dir "$Q6/state/workers"
[ -s "$Q6/classify.log" ] && pass "T6 RED control: with no refusal the classifier runs" || fail "T6 RED control: with no refusal the classifier runs"
q6_tree() { local c; for c in $(pgrep -P "$1" 2> /dev/null); do printf '%s\n' "$c"; q6_tree "$c"; done; }
Q6T="q6term$$"
Q6Q="$(mktemp -d "$Q6/quota.XXXXXX")" || fail "T6: mktemp -d failed"
env -u himmel_github_token_vm2 PATH="$Q6/realbin:$PATH" HIMMEL_QUOTA_DIR="$Q6Q" GH_READ_ENV_ROOT="$Q6/envroot" GHQ_PROBE_TIMEOUT=2 \
    Q_MODE=hung-after-probe Q_TAG="$Q6T" Q_LOG="$Q6/log" NEXT_DISPATCH_MIRROR="$Q6M" NEXT_DISPATCH_GH_CMD="$WORK/gh-q" \
    NEXT_DISPATCH_CLASSIFY_CMD="$WORK/classify-q" NEXT_DISPATCH_DEADLINE=120 bash "$SUT" --top 4 --workers-from "$Q6/fleet.json" > /dev/null 2>&1 &
q6pid=$!
for _ in $(seq 50); do pgrep -f "q6-sleep-$Q6T" > /dev/null && break; sleep 0.2; done
q6_kids="$(q6_tree "$q6pid")"
pgrep -f "q6-sleep-$Q6T" > /dev/null && [ -n "$q6_kids" ] && pass "T6 TERM control: the run reached its hung gh read" || fail "T6 TERM control: the run reached its hung gh read"
kill -TERM "$q6pid" 2> /dev/null; wait "$q6pid" 2> /dev/null
sleep 3
q6_alive=""
for q6k in $q6_kids; do kill -0 "$q6k" 2> /dev/null && q6_alive="$q6_alive $q6k"; done
[ -z "$q6_alive" ] && ! pgrep -f "q6-sleep-$Q6T" > /dev/null && pass "T6 TERM: a killed run leaves no gh read and no python behind" || fail "T6 TERM: a killed run leaves no gh read and no python behind (still alive:$q6_alive)"
for q6k in $q6_alive; do kill "$q6k" 2> /dev/null; done
pkill -f "q6-sleep-$Q6T" 2> /dev/null
Q6H="$WORK/q6home"; mkdir -p "$Q6H"
env -u HIMMEL_QUOTA_DIR -u himmel_github_token_vm2 HOME="$Q6H" GH_READ_ENV_ROOT="$Q6/envroot" Q_LOG="$Q6/log" NEXT_DISPATCH_MIRROR="$Q6M" \
    NEXT_DISPATCH_GH_CMD="$WORK/gh-q" NEXT_DISPATCH_CLASSIFY_CMD="$WORK/classify-q" bash "$SUT" --top 4 --workers-from "$Q6/fleet.json" > /dev/null 2>&1
[ ! -e "$Q6H/.himmel/state/quota" ] && pass "T6 a run on a substitute gh writes no quota state under HOME" || fail "T6 a run on a substitute gh writes no quota state under HOME ($(find "$Q6H/.himmel/state/quota" 2>&1 | head -3))"
q6run healthy NEXT_DISPATCH_GH_TIMEOUT=abc -- --priority-pool-only
has "T6 a non-integer NEXT_DISPATCH_GH_TIMEOUT keeps each read's own bound" "$Q6_OUT" "LOCAL	HIMMEL-9801"
q6run healthy -- --priority-pool-only
lacks "T6 RED control: a healthy stub prints no quota-pause line" "$Q6_OUT" "# quota-pause"
lacks "T6 RED control: a healthy stub prints no gh-stall line" "$Q6_OUT" "# gh-stall"
has "T6 RED control: a healthy stub lists the pool row" "$Q6_OUT" "LOCAL	HIMMEL-9801"
has "T6 RED control: a healthy stub lists the RESUME row" "$Q6_OUT" "RESUME	HIMMEL-9802"
q6_healthy="$Q6_OUT"
q6run healthy -- --priority-pool-only
[ "$Q6_OUT" = "$q6_healthy" ] && pass "T6 RED control: two healthy runs print the same bytes" || fail "T6 RED control: two healthy runs print the same bytes"

T11B="$WORK/t11bin"; mkdir -p "$T11B" "$WORK/t11root"
printf 'himmel_github_token_vm2=ghp_NDREAD0123456789\n' > "$WORK/t11root/.env"
cat > "$T11B/gh" <<'EOF'
#!/usr/bin/env bash
[ "${2:-}" = -i ] || printf '%s %s %s\n' "${GH_TOKEN:-main}" "$1" "$2" >> "$T11_LOG"
if [ -n "${GH_TOKEN:-}" ] && [ -n "${T11_READ401:-}" ]; then echo 'HTTP 401: Bad credentials (https://api.github.com/graphql)' >&2; exit 1; fi
if [ -z "${GH_TOKEN:-}" ] && [ -n "${T11_MAIN_LOW:-}" ] && [ "${2:-}" = -i ]; then
    printf 'HTTP/2.0 200 OK\r\nX-Ratelimit-Remaining: 100\r\nX-Ratelimit-Reset: %s\r\n\r\n{}\n' "$(($(date +%s) + 1800))"
    exit 0
fi
exec "$T11_NEXT" "$@"
EOF
chmod +x "$T11B/gh"
t11run() {
    local root="$1" mode="$2"
    shift 2
    Q6Q="$(mktemp -d "$Q6/quota.XXXXXX")" || { fail "T11: mktemp -d failed"; return 1; }; : > "$Q6/log"; : > "$WORK/t11.log"
    T11_OUT="$(env -u himmel_github_token_vm2 -u NEXT_DISPATCH_GH_CMD PATH="$T11B:$PATH" HIMMEL_QUOTA_DIR="$Q6Q" GH_READ_ENV_ROOT="$root" GHQ_PROBE_TIMEOUT=2 \
        Q_MODE="$mode" Q_LOG="$Q6/log" T11_LOG="$WORK/t11.log" T11_NEXT="$WORK/gh-q" NEXT_DISPATCH_MIRROR="$Q6M" NEXT_DISPATCH_CLASSIFY_CMD="$WORK/classify-q" \
        "$@" timeout -k 2 40 bash "$SUT" --top 4 --workers-from "$Q6/fleet.json" --priority-pool-only 2>/dev/null)"  # gnu-ok: the chief kit is Linux-only
}
t11run "$WORK/t11root" healthy
has "T11: a run with a read token lists the pool row" "$T11_OUT" "LOCAL	HIMMEL-9801"
has "T11: its PR list goes out on the read token" "$(cat "$WORK/t11.log")" "ghp_NDREAD0123456789 pr list"
lacks "T11: and no read rides main" "$(cat "$WORK/t11.log")" "main "
t11run "$WORK/t11root" gql-out
has "T11: the scan gate pauses on the read token's row" "$T11_OUT" "# quota-pause QUOTA-PAUSE github graphql token=read"
[ ! -s "$WORK/t11.log" ] && pass "T11: a paused run makes no read" || fail "T11: a paused run makes no read ($(head -3 "$WORK/t11.log"))"
t11run "$WORK/t11root" from-third
has "T11: a read refused mid-run names the read token" "$T11_OUT" "# quota-pause QUOTA-PAUSE github core token=read"
lacks "T11: and is not retried on main (a scan)" "$(cat "$WORK/t11.log")" "main "
T11T="t11hung$$"
t11run "$WORK/t11root" hung-after-probe Q_TAG="$T11T" NEXT_DISPATCH_GH_TIMEOUT=3
has "T11: a hung read on the read token ends as a gh-stall (the router's bound speaks first)" "$T11_OUT" "# gh-stall GH-STALL github"
sleep 1
! pgrep -f "q6-sleep-$T11T" > /dev/null && pass "T11: and leaves no gh read behind" || fail "T11: and leaves no gh read behind ($(pgrep -af "q6-sleep-$T11T" | head -2))"
pkill -f "q6-sleep-$T11T" 2> /dev/null
t11run "$WORK/t11root" healthy T11_READ401=1 T11_MAIN_LOW=1
has "T11: a read token answering 401 gates on main's row, and main under the floor pauses the run" "$T11_OUT" "# quota-pause QUOTA-PAUSE github graphql token=main remaining=100"
lacks "T11: and no read drains main" "$(cat "$WORK/t11.log")" "main "
t11run "$WORK/t11root" healthy T11_READ401=1
has "T11: with main healthy a 401 read token still lists the pool row" "$T11_OUT" "LOCAL	HIMMEL-9801"
has "T11: its reads go straight out on main" "$(cat "$WORK/t11.log")" "main pr list"
lacks "T11: and no read is first tried on the refused read token" "$(cat "$WORK/t11.log")" "ghp_"
t11run "$Q6/envroot" healthy
has "T11 RED control: with no read token configured the run lists the pool row" "$T11_OUT" "LOCAL	HIMMEL-9801"
has "T11 RED control: its PR list goes out on main, as today" "$(cat "$WORK/t11.log")" "main pr list"
lacks "T11 RED control: no read rides a read token" "$(cat "$WORK/t11.log")" "ghp_"
t11run "$Q6/envroot" gql-out
has "T11 RED control: with no read token the gate pauses on main's row" "$T11_OUT" "# quota-pause QUOTA-PAUSE github graphql token=main"
cat > "$T11B/cr-gh" <<'EOF'
#!/usr/bin/env bash
printf '%s %s %s\n' "${GH_TOKEN:-main}" "$1" "$2" >> "$T11_CR_LOG"
echo '[]'
EOF
chmod +x "$T11B/cr-gh"
: > "$WORK/t11cr.log"
t11run "$WORK/t11root" healthy T11_MAIN_LOW=1 NEXT_DISPATCH_CLASSIFY_CMD= CLOUD_ROUTE_GH_CMD="$T11B/cr-gh" T11_CR_LOG="$WORK/t11cr.log" CLOUD_ROUTE_JIRA_CMD=false
has "T11: with the real classifier on, main under the floor pauses the run although the read rows are ok" "$T11_OUT" "# quota-pause QUOTA-PAUSE github graphql token=main remaining=100"
[ ! -s "$WORK/t11cr.log" ] && pass "T11: and the classifier makes no main read" || fail "T11: and the classifier makes no main read ($(head -3 "$WORK/t11cr.log"))"
: > "$WORK/t11cr.log"
t11run "$WORK/t11root" healthy NEXT_DISPATCH_CLASSIFY_CMD= CLOUD_ROUTE_GH_CMD="$T11B/cr-gh" T11_CR_LOG="$WORK/t11cr.log" CLOUD_ROUTE_JIRA_CMD=false
has "T11 RED control: with main healthy the real classifier runs" "$(cat "$WORK/t11cr.log")" "main pr list"

RK="$WORK/rk"; mkdir -p "$RK/conf" "$RK/cache" "$HOME/.himmel/state/jira-mirror/CONFKEY"
printf 'JIRA_PROJECT_KEY=CONFKEY\n' > "$RK/conf/himmel.conf"
: > "$RK/cache/.env"
rk_save="$M"; M="$HOME/.himmel/state/jira-mirror/CONFKEY"
mk CONFKEY-1 "To Do" Medium '[]' '["v1.0.1"]' '[]' "a ticket of the configured project" "Edit scripts/lib/alpha.sh only."
M="$RK/ovr/OVR"; mkdir -p "$M"
mk OVR-1 "To Do" Medium '[]' '["v1.0.1"]' '[]' "a ticket of the override mirror" "Edit scripts/lib/beta.sh only."
M="$rk_save"
printf 'v1.0.1\tfalse\t\n' > "$HOME/.himmel/state/jira-mirror/CONFKEY.versions.tsv"
printf 'v1.0.1\tfalse\t\n' > "$RK/ovr/OVR.versions.tsv"
rkrun() { env -u NEXT_DISPATCH_MIRROR HIMMEL_JIRA_MIRROR= JIRA_PROJECT_KEY= HIMMEL_CONFIG_DIR="$RK/conf" HIMMELCTL_CACHE_DIR="$RK/cache" \
    NEXT_DISPATCH_GH_CMD="$WORK/gh" NEXT_DISPATCH_CLASSIFY_CMD="$WORK/classify" "$@" bash "$SUT" 2>/dev/null; }
out="$(rkrun)"
has "a himmel.conf key and no override reads jira-mirror/<that key>" "$out" "CONFKEY-1	"
out="$(rkrun NEXT_DISPATCH_MIRROR="$RK/ovr/OVR")"
lacks "NEXT_DISPATCH_MIRROR still wins over the resolver" "$out" "CONFKEY-1	"
has "NEXT_DISPATCH_MIRROR still wins: its own rows list" "$out" "OVR-1	"

# Predicate fixtures are separate from the listing's historical fixtures and header defaults.
P="$WORK/predicate"; mkdir -p "$P/mirror" "$P/state/workers" "$P/bucket" "$P/bin"
P_MAIN_KEY="HIMMEL-$((11000 + 1))"
M="$P/mirror"
printf 'v1.0.1\tfalse\t\nv1.0.2\tfalse\t\nv1.0.0\ttrue\t2026-01-01\n' > "$P/mirror.versions.tsv"
printf '# chief\n\n## Live state\npriority: HIMMEL-11001\n' > "$P/bucket/chief.md"
cat > "$P/bin/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$P_GH_LOG"
case "$1 $2" in
    'pr list') exit 0 ;;
    'pr view') cat "$P_BODIES/$3" 2>/dev/null; exit $? ;;
esac
exit 1
EOF
chmod +x "$P/bin/gh"
export P_GH_LOG="$P/gh.log" P_BODIES="$P/bodies"
mkdir -p "$P_BODIES"; : > "$P_GH_LOG"
P_CLI="$WORK/notcore-stub/index.js"
p_reset() {
    rm -f "$M"/*.md "$P/state/workers"/*.json "$P/bucket/owed.jsonl" "$P/bucket/owed.jsonl.lock" "$P/cache.json"
    : > "$P/state/status-events.jsonl"
    : > "$P_GH_LOG"
    P_CLI="$WORK/notcore-stub/index.js"
    P_SUT="$SUT"; P_JIRA=""; P_LIMIT=400; P_PATH="$PATH"; P_LIVE=0; P_GH="$P/bin/gh"; P_READER=""
}
p_mk() { mk "$1" "${2:-To Do}" Medium '[]' '["v1.0.1"]' '[]' 'predicate fixture' "${3:-Writes: scripts/lib/alpha.sh}"; }
p_part() { # key pr kind actor
    printf '{"event":"merge","result":"moved","key":"%s","pr":"%s","contract":"no","remainder":"%s","owed":"%s","owed_due":"2026-11-30"}\n' "$1" "$2" "$3" "${4:-}" >> "$P/state/status-events.jsonl"
    case "$3" in
        remaining) printf 'Remaining: edit scripts/lib/rem.sh\n' > "$P_BODIES/$2" ;;
        owed) printf '## Ticket coverage\n- check: owed -> %s by 2026-11-30\n' "${4:-chief}" > "$P_BODIES/$2" ;;
    esac
}
p_run() {
    local offline=--no-classify
    [ "$P_LIVE" = 0 ] || offline=""
    P_OUT="$(PATH="$P_PATH" NEXT_DISPATCH_DEADLINE="$P_LIMIT" NEXT_DISPATCH_JIRA_CLI="$P_CLI" NEXT_DISPATCH_MIRROR="$M" NEXT_DISPATCH_BODY_CACHE="${P_CACHE:-$P/cache.json}" NEXT_DISPATCH_READER="$P_READER" NEXT_DISPATCH_GH_CMD="$P_GH" NEXT_DISPATCH_JIRA_CMD="$P_JIRA" \
        bash "$P_SUT" $offline --workers-dir "$P/state/workers" "$@" 2> "$P/stderr")"; P_RC=$?
}
p_list() { p_run --why --dispositions --top 100 --doc "$P/bucket/chief.md"; }
p_owed() { bash "$HERE/owe.sh" "$@" --bucket "$P/bucket"; }
p_validation() { p_owed add --chief fixture --kind proof --key "$1" --text validate --metadata '{"actor":"chief","action":"validate-proof"}'; }
p_step() {
    p_owed add --chief fixture --kind step --key "$1" --text "${4:-Fix scripts/lib/next.sh}" \
        --metadata "{\"actor\":\"$3\",\"action\":\"next-step\",\"source_id\":\"$2\",\"due\":\"2026-11-30\",\"wake\":\"fixture\",\"capability\":\"fixture\"}" >/dev/null
}
p_reset
p_mk HIMMEL-11001
p_mk HIMMEL-11002 'To Do' 'No readable scope'
printf '{"state":"wrapped","resume_brief":"fixture-brief.md"}\n' > "$P/state/workers/HIMMEL-11002.json"
p_mk HIMMEL-11003; p_part HIMMEL-11003 7001 remaining
p_mk HIMMEL-11004 'In Progress'; p_mk HIMMEL-11005 'In Review'
p_mk HIMMEL-11006 'IN CI'; p_mk HIMMEL-11007 Done
p_mk HIMMEL-11008; retype "$M/HIMMEL-11008.md" Epic; p_part HIMMEL-11008 7002 remaining
p_mk HIMMEL-11009; p_part HIMMEL-11009 7003 owed proof
p_mk HIMMEL-11010; p_mk HIMMEL-11011
for pair in HIMMEL-11010:chief HIMMEL-11011:operator; do
    pv="$(p_validation "${pair%%:*}")"; p_step "${pair%%:*}" "$pv" "${pair##*:}"
    p_owed close --id "$pv" --key KEEP >/dev/null
done
p_list
[ "$P_RC" = 0 ] && pass 'P21(a) listing exits successfully' || fail "P21(a) listing rc=$P_RC"
has 'P21(a) ordinary To Do is executable' "$P_OUT" $'LOCAL?\tHIMMEL-11001'
for pk in 11002 11003 11004 11005 11006 11009; do has "P21(a) role $pk is RESUME" "$P_OUT" "$(printf 'RESUME\tHIMMEL-%s' "$pk")"; done
lacks 'P21(a) terminal is absent' "$P_OUT" $'RESUME\tHIMMEL-11007'
has 'P21(a) Epic live partial retains type refusal' "$P_OUT" '# drop HIMMEL-11008 type Epic'
has 'P21(a) proof-only scope writes nothing' "$(printf '%s\n' "$P_OUT" | grep $'^RESUME\tHIMMEL-11009')" 'files=-'
for pk in 11010 11011; do has "P21(a) next-step owner $pk is OWED" "$P_OUT" "OWED HIMMEL-$pk:"; lacks "P21(a) next-step owner $pk is not executable" "$P_OUT" "$(printf 'LOCAL?\tHIMMEL-%s' "$pk")"; done
P_PROOF_KEY="HIMMEL-$((11000 + 9))"
pv="$(p_validation "$P_PROOF_KEY")"
p_list
lacks 'P21(a) pending validation suppresses proof-only executable membership' "$P_OUT" $'RESUME\tHIMMEL-11009'
has 'P21(a) pending proof validation names chief' "$P_OUT" "OWED HIMMEL-11009: owed action $pv owes chief"

p_unknown() {
    [ "$P_RC" = 3 ] && pass "$1 rc3" || fail "$1 rc=$P_RC: $P_OUT"
    [ "$(printf '%s\n' "$P_OUT" | grep -c "^UNKNOWN $P_MAIN_KEY:")" = 1 ] && pass "$1 one UNKNOWN" || fail "$1 UNKNOWN: $P_OUT"
    if printf '%s\n' "$P_OUT" | grep -Eq '^(READY|GATE) '; then fail "$1 partial verdict: $P_OUT"; else pass "$1 no partial verdict"; fi
    lacks "$1 no traceback" "$(cat "$P/stderr")" Traceback
}
p_tree() {
    PT="$P/tree-$1"; mkdir -p "$PT/scripts/handover" "$PT/marketplace/plugins/himmel-ops"
    cp -R "$HERE" "$PT/scripts/handover/chief-kit"
    cp -R "$HERE/../../lib" "$PT/scripts/lib"
    cp -R "$HERE/../../../marketplace/plugins/himmel-ops/scripts" "$PT/marketplace/plugins/himmel-ops/scripts"
    P_SUT="$PT/scripts/handover/chief-kit/next-dispatchable.sh"
}
p_reset; p_mk HIMMEL-11001
p_run --why-ticket HIMMEL-11099
[ "$P_RC" = 3 ] && has 'P8(b) absent key reason' "$P_OUT" 'not in the mirror or the body file' || fail "P8(b) rc=$P_RC: $P_OUT"
p_run --why-ticket HIMMEL-11001 --body-file "$P/missing-body"; p_unknown 'P8(c) unreadable body'
printf -- '---\nkey: HIMMEL-11002\n---\nWrites: scripts/lib/alpha.sh\n' > "$P/body"
p_run --why-ticket HIMMEL-11001 --body-file "$P/body"; p_unknown 'P8(d) body key mismatch'
has 'P8(d) named key mismatch' "$P_OUT" 'body file key HIMMEL-11002 differs'
p_run --why-ticket HIMMEL-11001 --mirror "$P/missing-mirror"; p_unknown 'P8(e) missing mirror'
if [ "$(id -u)" = 0 ]; then pass 'P8(f) unreadable directory SKIP root'; else
    mkdir "$P/unreadable"; chmod 000 "$P/unreadable"
    p_run --why-ticket HIMMEL-11001 --mirror "$P/unreadable"; chmod 700 "$P/unreadable"; p_unknown 'P8(f) unreadable mirror'
fi
printf -- '---\nkey: HIMMEL-11001\n' > "$M/HIMMEL-11001.md"
p_run --why-ticket HIMMEL-11001; p_unknown 'P8(g) malformed mirror'
has 'P8(g) absent key reason' "$P_OUT" 'not in the mirror or the body file'
for missing in platform-dropped.re pr_remainder.py proof_staging.py; do
    p_reset; p_mk HIMMEL-11001; p_tree "$missing"
    case "$missing" in pr_remainder.py) rm "$PT/scripts/lib/$missing" ;; *) rm "$PT/scripts/handover/chief-kit/$missing" ;; esac
    p_run --why-ticket HIMMEL-11001; p_unknown "P8(h/i/m) missing $missing"
done
p_reset; p_mk HIMMEL-11001
P_REAL_PY="$(command -v python3)"; export P_REAL_PY
mkdir -p "$P/python-bin"
cat > "$P/python-bin/python3" <<'EOF'
#!/usr/bin/env bash
if [ "$*" = '-I -' ]; then cat >/dev/null; exit "$P_STUB_RC"; fi
exec "$P_REAL_PY" "$@"
EOF
chmod +x "$P/python-bin/python3"
for P_STUB_RC in 0 1 3 5; do
    export P_STUB_RC; P_PATH="$P/python-bin:$PATH"
    p_run --why-ticket HIMMEL-11001; p_unknown "P8(j/k) empty body exit $P_STUB_RC"
    has "P8(j/k) unexpected exit $P_STUB_RC" "$P_OUT" "unexpected exit $P_STUB_RC"
done
p_reset
mk HIMMEL-11001 'To Do' Medium '[]' '["v1.0.1"]' '["HIMMEL-11002"]' fixture 'Writes: scripts/lib/alpha.sh'
p_mk HIMMEL-11002
cat > "$P/slow-jira" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$P_JIRA_LOG"
sleep 20
EOF
chmod +x "$P/slow-jira"; export P_JIRA_LOG="$P/jira.log"; : > "$P_JIRA_LOG"
P_JIRA="$P/slow-jira"; P_LIMIT=3; P_LIVE=1
p_run --why-ticket HIMMEL-11001; p_unknown 'P8(a) deadline'
has 'P8(a) reached real blocker stub' "$(cat "$P_JIRA_LOG")" 'get HIMMEL-11002'  # read-sink-ok: P_JIRA_LOG is this suite's own stub log under its scratch dir
has 'P8(a) deadline reason' "$P_OUT" 'timed out after 3s'
for flag in top why dispositions priority-pool-only resume-only owners workers-from held; do
    p_reset; p_mk HIMMEL-11001
    case "$flag" in top) set -- --top 3 ;; owners) set -- --owners HIMMEL-11002 ;; workers-from|held) set -- "--$flag" "$P/missing" ;; *) set -- "--$flag" ;; esac
    p_run --why-ticket HIMMEL-11001 "$@"
    [ "$P_RC" = 2 ] && pass "P12 refuses --$flag" || fail "P12 accepts --$flag rc=$P_RC"
done
for key in bad-key AB2-5; do p_run --why-ticket "$key"; [ "$P_RC" = 2 ] && pass "P12 bad key $key" || fail "P12 key $key rc=$P_RC"; done
p_run --body-file "$P/body"; [ "$P_RC" = 2 ] && pass 'P12 body-file requires predicate' || fail "P12 body alone rc=$P_RC"

p_verdict() {
    [ "$P_RC" = "$2" ] && pass "$1 rc$2" || fail "$1 rc=$P_RC expected $2: $P_OUT"
    if [ "$2" = 0 ]; then has "$1 READY" "$P_OUT" 'READY HIMMEL-11001'; else lacks "$1 no READY" "$P_OUT" 'READY '; fi
    lacks "$1 no UNKNOWN" "$P_OUT" 'UNKNOWN '
}
p_reset; MK_BARE=1 p_mk HIMMEL-11001 'To Do' 'Nothing is scoped'
p_run --why-ticket HIMMEL-11001; p_verdict P1 1
has 'P1 all gates no-scope' "$P_OUT" 'GATE HIMMEL-11001 no-scope:'
has 'P1 all gates no-proof' "$P_OUT" 'GATE HIMMEL-11001 no-proof: missing DoD, Proof'
p_reset; p_mk HIMMEL-11001
cat > "$P/fail-gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$P_GH_LOG"
exit 1
EOF
mkdir -p "$P/no-gh"
cat > "$P/no-gh/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$P_PATH_GH_LOG"
exit 1
EOF
chmod +x "$P/fail-gh" "$P/no-gh/gh"
export P_PATH_GH_LOG="$P/path-gh.log"; : > "$P_PATH_GH_LOG"
P_GH="$P/fail-gh"; P_PATH="$P/no-gh:$PATH"
printf '{"event":"merge","stage":"pre-merge","result":"pending","key":"HIMMEL-11002","pr":"7101","head":"other","repo":"other/repo","contract":"no"}\n' > "$P/state/status-events.jsonl"
p_run --why-ticket HIMMEL-11001; p_verdict P2 0
[ ! -s "$P_GH_LOG" ] && [ ! -s "$P_PATH_GH_LOG" ] && pass 'P2 both gh logs empty' || fail 'P2 reached GitHub'
cat >> "$P/state/status-events.jsonl" <<'EOF'
{"event":"merge","stage":"pre-merge","result":"pending","key":"HIMMEL-11001","pr":"7102","head":"dangling","contract":"no"}
{"event":"merge","stage":"pre-merge","result":"pending","key":"HIMMEL-11001","pr":"7101","head":"settled","contract":"no"}
{"event":"merge","result":"not-merged","key":"HIMMEL-11001","pr":"7101","head":"settled"}
EOF
p_run --why-ticket HIMMEL-11001; p_verdict P2b 1
has 'P2b own dangling row refused' "$P_OUT" 'drop: merge of PR #7102 unconfirmed'
lacks 'P2b other-key warning never pairs with settled own PR' "$P_OUT" 'PR #7101'
[ ! -s "$P_GH_LOG" ] && [ ! -s "$P_PATH_GH_LOG" ] && pass 'P2b both gh logs empty' || fail 'P2b reached GitHub'
mkdir -p "$P/core"
cat > "$P/core/index.js" <<'EOF'
const fs = require('fs'), a = process.argv.slice(2);
fs.appendFileSync(process.env.P_CORE_LOG, a.join(' ') + (a[1] === 'core-check-batch' ? ' ' + fs.readFileSync(a[2], 'utf8') : '') + '\n');
if (a[1] === 'core-check-batch') {
  if (process.env.P_CORE_VERB === 'FAIL') { console.error('fixture refused'); process.exit(5); }
  JSON.parse(fs.readFileSync(a[2], 'utf8')).forEach((g, i) => { console.log('== ' + (i + 1)); for (const k of g.keys) console.log((process.env.P_CORE_VERB || 'CORE') + ' ' + k + ' fixture'); });
} else if (a[1] === 'core-check') {
  if (process.env.P_CORE_VERB === 'FAIL') { console.error('fixture refused'); process.exit(5); }
  for (const k of a.slice(a.indexOf('--key') + 1)) console.log((process.env.P_CORE_VERB || 'CORE') + ' ' + k + ' fixture');
} else for (const k of a.filter(x => /^HIMMEL-\d+$/.test(x))) console.log((process.env.P_SPEC_VERB || 'NO-SPEC') + ' ' + k + ' fixture');
EOF
export P_CORE_LOG="$P/core.log" P_CORE_VERB=CORE P_SPEC_VERB=NO-SPEC
for status in 'To Do' 'In Progress'; do
    p_reset; MK_BARE=1 p_mk HIMMEL-11001 "$status"; p_mk HIMMEL-11002
    P_CLI="$P/core/index.js"; : > "$P_CORE_LOG"
    p_run --why-ticket HIMMEL-11001
    if [ "$status" = 'To Do' ]; then
        p_verdict 'P6(a)' 1; has 'P6(a) core spec gate' "$P_OUT" 'core-no-spec: NO-SPEC'; has 'P6(a) proof gate' "$P_OUT" 'no-proof:'
    else p_verdict 'P6(b)' 0; lacks 'P6(b) no To Do gates' "$P_OUT" 'core-no-spec:'; lacks 'P6(b) no proof gate' "$P_OUT" 'no-proof:'; fi
    [ "$(grep -c '^release core-check-batch ' "$P_CORE_LOG")" = 1 ] && [ "$(grep -c '^release core-check ' "$P_CORE_LOG")" = 0 ] && pass "P6 $status one core read" || fail "P6 $status core count"
    lacks "P6 $status no other key" "$(cat "$P_CORE_LOG")" HIMMEL-11002
    has "P6 $status key-only core argv" "$(cat "$P_CORE_LOG")" '"keys": ["HIMMEL-11001"]'
done
for verb in UNKNOWN FAIL BYPASS-NEEDS-SPEC; do
    p_reset; p_mk HIMMEL-11001; P_CLI="$P/core/index.js"; P_CORE_VERB="$verb"
    p_run --why-ticket HIMMEL-11001; p_verdict "Q3 core $verb" 1
    has "Q3 $verb fail closed" "$P_OUT" 'core-no-spec:'
done
P_CORE_VERB=CORE; P_SPEC_VERB=SPEC-STALE
p_run --why-ticket HIMMEL-11001; p_verdict 'Q3 stale spec' 1; has 'Q3 SPEC-STALE' "$P_OUT" 'core-no-spec: SPEC-STALE'
P_SPEC_VERB=NO-SPEC
p_reset; p_mk HIMMEL-11001
printf '\377' >> "$M/HIMMEL-11001.md"
p_run --why-ticket HIMMEL-11001; p_verdict 'P8(l) mirror replacement UTF8' 0
cp "$M/HIMMEL-11001.md" "$P/utf8-body"
p_run --why-ticket HIMMEL-11001 --body-file "$P/utf8-body"; p_verdict 'P8(l) body replacement UTF8' 0
mkdir -p "$P/body-core"
cat > "$P/body-core/index.js" <<'EOF'
const fs = require('fs'), path = require('path'), a = process.argv.slice(2), m = a[a.indexOf('--mirror')+1];
fs.writeFileSync(process.env.P_TEMP_LOG, m);
if (!fs.readFileSync(path.join(m, 'HIMMEL-11001.md'), 'utf8').includes('Writes: scripts/lib/alpha.sh')) process.exit(4);
console.log('NOT-CORE HIMMEL-11001');
EOF
export P_TEMP_LOG="$P/temp.log"
p_reset; p_mk HIMMEL-11001; cp "$M/HIMMEL-11001.md" "$P/body"; rm "$M/HIMMEL-11001.md"
P_CLI="$P/body-core/index.js"
p_run --why-ticket HIMMEL-11001 --body-file "$P/body"; p_verdict 'P15(a) unmirrored body' 0
[ ! -d "$(cat "$P_TEMP_LOG")" ] && pass 'P15(a) temporary mirror removed' || fail 'P15(a) temporary mirror leaked'
printf 'Writes: scripts/lib/alpha.sh\n\nProof\n- check\n' > "$P/body"
P_CLI="$WORK/notcore-stub/index.js"
p_run --why-ticket HIMMEL-11001 --body-file "$P/body"; p_verdict 'P15(b) description-only body' 1
has 'P15(b) actual body proof checker' "$P_OUT" 'no-proof: missing DoD'
for status in 'IN CI' Done; do
    p_reset; p_mk HIMMEL-11001 "$status"; p_run --why-ticket HIMMEL-11001; p_verdict "P16 $status" 1
    case "$status" in 'IN CI') has 'P16 IN CI needs GitHub' "$P_OUT" 'drop: IN CI (whether a merged PR already closes it needs a GitHub read)' ;; *) has 'P16 terminal status' "$P_OUT" 'drop: status Done' ;; esac
done
for role in ordinary wrapped partial progress review epic subtask; do
    p_reset
    case "$role" in progress) status='In Progress' ;; review) status='In Review' ;; *) status='To Do' ;; esac
    p_mk HIMMEL-11001 "$status"
    case "$role" in
        wrapped) MK_BARE=1 p_mk HIMMEL-11001 'To Do' 'No readable scope'; printf '{"state":"wrapped","resume_brief":"fixture.md"}\n' > "$P/state/workers/HIMMEL-11001.json" ;;
        partial|epic)
            p_part HIMMEL-11001 7001 remaining
            printf '\n## Comments\n\n### chief — 2026-11-17T00:00:00Z\nPR #7001 (fixture/repo) merged @ abc as a partial merge; the ticket is not complete. Remaining: edit scripts/lib/rem.sh\n' >> "$M/HIMMEL-11001.md"
            [ "$role" != epic ] || retype "$M/HIMMEL-11001.md" Epic ;;
        subtask) retype "$M/HIMMEL-11001.md" Sub-task ;;
    esac
    p_run --why-ticket HIMMEL-11001
    case "$role" in epic|subtask) p_verdict "P21(b)/P19 $role" 1; has "P19 $role type" "$P_OUT" 'drop: type ' ;; *) p_verdict "P21(b) $role" 0 ;; esac
done
for variant in done-pending parked-title parked-label platform cloud residual; do
    p_reset; p_mk HIMMEL-11001
    case "$variant" in
        done-pending) printf '{"event":"merge","result":"moved","key":"HIMMEL-11001","pr":"7001","contract":"yes"}\n' > "$P/state/status-events.jsonl"; want='drop: done-pending' ;;
        parked-title) mk HIMMEL-11001 'To Do' Medium '[]' '[]' '[]' 'parked: later' 'Writes: scripts/lib/alpha.sh'; want='held-label: title parked:' ;;
        parked-label) mk HIMMEL-11001 'In Progress' Medium '["parked-later"]' '[]' '[]' fixture 'Writes: scripts/lib/alpha.sh'; want='held-label: labels parked-later' ;;
        platform) mk HIMMEL-11001 'To Do' Medium '[]' '[]' '[]' 'fix the wsl path' 'Writes: scripts/lib/alpha.sh'; want='drop: platform (dropped-platform title)' ;;
        cloud) printf '# chief\n\n## Live state\npriority: HIMMEL-11001(CLOUD)\n' > "$P/bucket/cloud.md"; want='drop: cloud-only on the priority line' ;;
        residual) mk HIMMEL-11001 'To Do' Medium '["residual-depth-2"]' '[]' '[]' fixture 'Writes: scripts/lib/alpha.sh'; want='drop: residual-depth 2' ;;
    esac
    if [ "$variant" = cloud ]; then p_run --why-ticket HIMMEL-11001 --doc "$P/bucket/cloud.md"; else p_run --why-ticket HIMMEL-11001; fi
    p_verdict "P19 $variant" 1; has "P19 $variant reason" "$P_OUT" "$want"
done
p_reset
for status in 'To Do' 'In Progress'; do
    mk HIMMEL-11001 "$status" Medium '[]' '[]' '["HIMMEL-11002","HIMMEL-11003"]' fixture 'Writes: scripts/lib/alpha.sh'
    p_mk HIMMEL-11002; p_mk HIMMEL-11003
    cat > "$P/live-jira" <<'EOF'
#!/usr/bin/env bash
[ "$2" != HIMMEL-11003 ] || exit 1
printf '%s\tTask\tTo Do\tfixture\n' "$2"
EOF
    chmod +x "$P/live-jira"; P_JIRA="$P/live-jira"; P_LIVE=1
    p_run --why-ticket HIMMEL-11001; p_verdict "P13d/e $status blocker" 1
    has "P13d/e $status blocker detail" "$P_OUT" 'open-blocker: HIMMEL-11002 (To Do, live), HIMMEL-11003 (unreadable)'
done

p_reset; p_mk HIMMEL-11001
mkdir -p "$P/status-unreadable/workers" "$P/merged-git"
mkdir -p "$P/status-unreadable/status-events.jsonl"
git -C "$P/merged-git" init -q -b main
git -C "$P/merged-git" -c user.name=t -c user.email=t@example.com -c commit.gpgsign=false -c core.hooksPath=/dev/null commit -q --allow-empty -m 'fixture [HIMMEL-11001]'
P_OUT="$(NEXT_DISPATCH_GIT_DIR="$P/merged-git" NEXT_DISPATCH_MAIN_REF=main NEXT_DISPATCH_JIRA_CLI="$P_CLI" NEXT_DISPATCH_MIRROR="$M" NEXT_DISPATCH_GH_CMD="$P/fail-gh" bash "$SUT" --no-classify --why-ticket "$P_MAIN_KEY" --workers-dir "$P/status-unreadable/workers" 2> "$P/stderr")"; P_RC=$?
p_verdict 'P19 status-unreadable merged local key' 1
has 'P19 status-unreadable exact refusal' "$P_OUT" 'drop: status-events.jsonl unreadable and the key has a merge on main'
p_reset
mk HIMMEL-11001 'To Do' Medium '[]' '[]' '["HIMMEL-11002"]' fixture 'Writes: scripts/lib/alpha.sh'
p_mk HIMMEL-11002; cp "$M/HIMMEL-11001.md" "$P/deadline-body"
mkdir -p "$P/temp"
P_JIRA="$P/slow-jira"; P_LIMIT=3; P_LIVE=1
TMPDIR="$P/temp" p_run --why-ticket HIMMEL-11001 --body-file "$P/deadline-body"
p_unknown 'P8/P15 body deadline cleanup'
if find "$P/temp" -name 'prim.*' | grep -q .; then fail 'P8/P15 deadline leaked temp mirror'; else pass 'P8/P15 deadline removes temp mirror'; fi
p_reset
mk HIMMEL-11001 'To Do' Medium '[]' '[]' '["HIMMEL-11002"]' fixture 'Writes: scripts/lib/alpha.sh'
p_mk HIMMEL-11002 Done; P_JIRA="$P/live-jira"
p_run --why-ticket HIMMEL-11001; p_verdict 'P13e no-classify uses mirror despite configured Jira reader' 0

p_comment() { printf '\n## Comments\n\n### chief — 2026-11-17T00:00:00Z\n%s\n' "$1" >> "$M/HIMMEL-11001.md"; }
p_breadcrumb() { p_comment "PR #$1 (yotamleo-org/Himmel) merged @ abc as a partial merge; the ticket is not complete. Remaining: $2"; }
p_reset; p_mk HIMMEL-11001 'To Do' 'Scope needs a ruling'
p_comment $'readiness: scoped by chief\nWrites: scripts/lib/rd.sh'
p_run --why-ticket HIMMEL-11001; p_verdict P3 0; has 'P3 predicate readiness scope' "$P_OUT" 'readiness comment'; has 'P3 predicate path' "$P_OUT" 'scripts/lib/rd.sh'
p_list; has 'P3 listing readiness scope' "$P_OUT" 'files=scripts/lib/rd.sh'
for marker in $'Readiness ruling: scoped\nWrites: scripts/lib/rd.sh' $'ordinary note\nWrites: scripts/lib/rd.sh' 'readiness: scoped Writes: scripts/lib/rd.sh'; do
    p_reset; p_mk HIMMEL-11001 'To Do' 'Scope needs a ruling'; p_comment "$marker"
    p_run --why-ticket HIMMEL-11001; p_verdict "P4(a/b/d) predicate $marker" 1; has 'P4(a/b/d) predicate no scope' "$P_OUT" 'no-scope:'
    p_list; has 'P4(a/b/d) listing guard' "$P_OUT" 'NEEDS-CHIEF-NOTE HIMMEL-11001'
done
p_reset; p_mk HIMMEL-11001 'To Do' 'Scope needs a ruling'
p_comment $'readiness: old\nWrites: scripts/lib/old.sh'
printf '\n### chief — 2026-11-17T01:00:00Z\nreadiness: new\nWrites: scripts/lib/new.sh\n' >> "$M/HIMMEL-11001.md"
p_run --why-ticket HIMMEL-11001; p_verdict 'P4(c) predicate' 0; has 'P4(c) predicate newest' "$P_OUT" 'scripts/lib/new.sh'; lacks 'P4(c) predicate ignores older' "$P_OUT" 'scripts/lib/old.sh'
p_list; has 'P4(c) listing newest' "$P_OUT" 'files=scripts/lib/new.sh'
for mode in breadcrumb cache; do
    p_reset; p_mk HIMMEL-11001 'In Progress' 'Writes: scripts/lib/desc.sh'; p_part HIMMEL-11001 7001 remaining
    p_comment $'readiness: scoped\nWrites: scripts/lib/rd.sh'; p_breadcrumb 7001 'edit scripts/lib/rem.sh'
    if [ "$mode" = cache ]; then p_list; has 'P7c listing remainder wins' "$P_OUT" 'files=scripts/lib/rem.sh'; fi
    p_run --why-ticket HIMMEL-11001; p_verdict "P7/P7c $mode" 0
    has "P7/P7c $mode source" "$P_OUT" '# scope HIMMEL-11001 remainder of PR #7001: scripts/lib/rem.sh'
done
for variant in owed missing not-recorded; do
    p_reset; p_mk HIMMEL-11001 'In Progress'; p_part HIMMEL-11001 7002 remaining
    case "$variant" in
        owed) printf '{"event":"merge","result":"moved","key":"HIMMEL-11001","pr":"7002","contract":"no"}\n' > "$P/state/status-events.jsonl"; p_breadcrumb 7002 'the live check: owed → chief by 2026-11-30'; want='remainder kind of PR #7002 unknown without GitHub' ;;
        missing) want='remainder of PR #7002 not yet in the mirror' ;;
        not-recorded) printf '{"event":"merge","result":"moved","key":"HIMMEL-11001","pr":"7002","contract":"no"}\n' > "$P/state/status-events.jsonl"; p_breadcrumb 7002 'not recorded in the PR body, see PR #7002.'; want='remainder of PR #7002 not recorded (no GitHub read)' ;;
    esac
    p_run --why-ticket HIMMEL-11001; p_verdict "P7b $variant" 1; has "P7b $variant reason" "$P_OUT" "$want"
done
p_reset; p_mk HIMMEL-11001 'In Progress'; p_part HIMMEL-11001 7001 remaining; p_breadcrumb 7001 'edit scripts/lib/rem.sh'
P_GH="$P/fail-gh"; P_PATH="$P/no-gh:$PATH"; : > "$P_PATH_GH_LOG"
p_run --why-ticket HIMMEL-11001; p_verdict 'P17(a) real reader no gh' 0
[ ! -s "$P_GH_LOG" ] && [ ! -s "$P_PATH_GH_LOG" ] && pass 'P17(a) both gh logs empty' || fail 'P17(a) reached GitHub'
P_READER="$P/missing-reader.py"
p_run --why-ticket HIMMEL-11001; p_unknown 'P17(b) missing reader'; has 'P17(b) reader reason' "$P_OUT" 'pr_remainder.py'
P_READER=''; p_tree raising
printf '\ndef live_answers(answers):\n    raise RuntimeError("fixture")\n' >> "$PT/scripts/lib/pr_remainder.py"
p_run --why-ticket HIMMEL-11001; p_unknown 'P17(c) actual internal error'; has 'P17(c) framed RuntimeError' "$P_OUT" 'internal error RuntimeError'
p_reset; p_mk HIMMEL-11001 'In Progress'; p_part HIMMEL-11001 7003 owed chief
p_run --why-ticket HIMMEL-11001; p_verdict 'P19(h) owed chief' 1; has 'P19(h) named debt' "$P_OUT" 'drop: merged PR #7003 owes chief by 2026-11-30'
p_reset; p_mk HIMMEL-11001 'In Progress'; p_part HIMMEL-11001 7004 remaining
printf '## Ticket coverage\n- first: deferred -> HIMMEL-1\n- second: deferred -> HIMMEL-2\n' > "$P_BODIES/7004"
p_list
p_run --why-ticket HIMMEL-11001; p_verdict 'P19(i) handed-off cached' 1; has 'P19(i) hand-off owner' "$P_OUT" 'drop: remainder on HIMMEL-1, HIMMEL-2'
P_KEY="HIMMEL-$((11000 + 1))"
for actor in worker chief operator; do
    p_reset; p_mk HIMMEL-11001 'In Progress' 'Writes: scripts/lib/desc.sh'; p_part HIMMEL-11001 7001 remaining
    p_comment $'readiness: scoped\nWrites: scripts/lib/rd.sh'; p_breadcrumb 7001 'edit scripts/lib/rem.sh'
    pv="$(p_validation "$P_KEY")"; p_owed close --id "$pv" --key KEEP >/dev/null; p_step "$P_KEY" "$pv" "$actor"
    p_list
    if [ "$actor" = worker ]; then has 'P20 listing KEEP worker scope wins' "$P_OUT" 'files=scripts/lib/next.sh'; else has "P20 listing $actor holds" "$P_OUT" "owes $actor by 2026-11-30"; lacks "P20 listing $actor not executable" "$P_OUT" $'RESUME\tHIMMEL-11001'; fi
    p_run --why-ticket HIMMEL-11001 --doc "$P/bucket/chief.md"
    if [ "$actor" = worker ]; then p_verdict 'P20 predicate KEEP worker' 0; has 'P20 predicate KEEP scope wins' "$P_OUT" 'owed next step'; has 'P20 predicate actual worker scope' "$P_OUT" 'scripts/lib/next.sh'; else p_verdict "P20/P21(c) predicate $actor holds" 1; has "P20 predicate $actor refusal" "$P_OUT" "drop: owned next step: $actor"; fi
done
for variant in proof pending discharged code older wrong; do
    p_reset; p_mk HIMMEL-11001 'To Do'; p_part HIMMEL-11001 7001 owed proof
    case "$variant" in
        pending|discharged|code) pv="$(p_validation "$P_KEY")" ;;
        older) pv="$(p_validation "$P_KEY")"; p_owed close --id "$pv" --key KEEP >/dev/null; p_step "$P_KEY" "$pv" worker; p_validation "$P_KEY" >/dev/null ;;
        wrong) other="HIMMEL-$((11000 + 2))"; pv="$(p_validation "$other")"; p_owed close --id "$pv" --key KEEP >/dev/null; p_step "$P_KEY" "$pv" worker ;;
    esac
    case "$variant" in
        discharged) p_owed close --id "$pv" --key MET >/dev/null ;;
        code) p_part HIMMEL-11001 7002 remaining; p_breadcrumb 7002 'edit scripts/lib/rem.sh' ;;
    esac
    p_list
    case "$variant" in pending|older) lacks "P20 listing $variant proof withheld" "$P_OUT" $'RESUME\tHIMMEL-11001'; has "P20 listing $variant names chief" "$P_OUT" 'owes chief' ;; *) has "P20 listing $variant executable" "$P_OUT" $'RESUME\tHIMMEL-11001' ;; esac
    p_run --why-ticket HIMMEL-11001 --doc "$P/bucket/chief.md"
    case "$variant" in
        pending|older) p_verdict "P20/P21(c) predicate $variant" 1; has "P20 predicate $variant named owner" "$P_OUT" 'drop: owned next step: chief' ;;
        *) p_verdict "P20/P21(c) predicate $variant" 0 ;;
    esac
    case "$variant" in code) has 'P20 unrelated code scope preserved' "$P_OUT" 'scripts/lib/rem.sh' ;; wrong|older) lacks "P20 $variant source never supplies scope" "$P_OUT" 'scripts/lib/next.sh' ;; esac
done
p_reset; p_mk HIMMEL-11001
p_run --why-ticket HIMMEL-11001; p_verdict 'P20 no-doc legacy' 0; has 'P20 explicit missing context' "$P_OUT" '# owed-ledger not read (no --doc)'
p_run --why-ticket HIMMEL-11001 --doc "$P/bucket/chief.md"; p_verdict 'P20 resolved missing ledger legacy' 0
printf '{not json}\n' > "$P/bucket/owed.jsonl"
p_run --why-ticket HIMMEL-11001 --doc "$P/bucket/chief.md"; p_unknown 'P20 corrupt existing ledger'

for variant in 'done' open released no-label bad-on unmoved; do
    p_reset
    labels='["held"]'; [ "$variant" != no-label ] || labels='[]'
    mk HIMMEL-11001 'To Do' Medium "$labels" '[]' '[]' fixture 'Writes: scripts/lib/alpha.sh'
    p_mk HIMMEL-11002 Done
    [ "$variant" != open ] || p_mk HIMMEL-11002 'To Do'
    on=HIMMEL-11002; [ "$variant" != bad-on ] || on=bad
    result=moved; [ "$variant" != unmoved ] || result=refused
    printf '{"event":"hold","result":"%s","key":"HIMMEL-11001","on":"%s"}\n' "$result" "$on" > "$P/state/status-events.jsonl"
    [ "$variant" != released ] || printf '{"event":"hold-release","result":"moved","key":"HIMMEL-11001"}\n' >> "$P/state/status-events.jsonl"
    p_run --why-ticket HIMMEL-11001
    if [ "$variant" = 'done' ]; then has 'P5(a) stale hold' "$P_OUT" 'stale-hold: held on HIMMEL-11002 (Done); release:'; has 'P5(a) held label detail' "$P_OUT" 'held-label: labels held'; else lacks "P5 $variant negative" "$P_OUT" 'stale-hold:'; fi
done
for prose in "Depends on P4-02 (HIMMEL-$((8524)))." "- Depends on T-1.2 (HIMMEL-$((8524)))" "Depends on HIMMEL-$((8524)) and HIMMEL-$((1)) (the seam)." "BLOCKED-BY: HIMMEL-$((8524)). Now unblocked by HIMMEL-$((9))." "Depends on HIMMEL-$((8524)), HIMMEL-$((1)), and HIMMEL-$((2))." "Depends  on HIMMEL-$((8524))" "BLOCKED-BY:HIMMEL-$((8524))" "Blocked by: HIMMEL-$((8524))" "Links: relates to HIMMEL-$((9)), blocked by HIMMEL-$((8524))" "**Blocked by:** HIMMEL-$((8524))" "- Depends on P4-02 (HIMMEL-$((8524)), HIMMEL-$((1)))"; do
    p_reset; p_mk HIMMEL-11001 'To Do' "$(printf 'Writes: scripts/lib/alpha.sh\n%s' "$prose")"; p_mk HIMMEL-8524
    p_run --why-ticket HIMMEL-11001; p_verdict "P9/P9b $prose" 1
    has "P9/P9b actual tracker superset $prose" "$P_OUT" 'prose-dependency: HIMMEL-8524'
    lacks 'P9 no plan label as key' "$P_OUT" 'prose-dependency: P4-02'
done
for prose in "This does not depend on HIMMEL-$((8524))." "- after HIMMEL-$((8524))" "run it after HIMMEL-$((8524)) merges" "Blocked by: none (HIMMEL-$((8524)))" "Blocked by: nothing (HIMMEL-$((8524)))" "Blocked by: n/a (HIMMEL-$((8524)))"; do
    p_reset; p_mk HIMMEL-11001 'To Do' "$(printf 'Writes: scripts/lib/alpha.sh\n%s' "$prose")"; p_mk HIMMEL-8524
    p_run --why-ticket HIMMEL-11001; p_verdict "P9 negative $prose" 0; lacks 'P9 negative no advisory' "$P_OUT" 'prose-dependency:'
done
for variant in blocks blocked-by edges wrong-side 'done' self missing relates; do
    p_reset; p_mk HIMMEL-11001 'To Do' $'Writes: scripts/lib/alpha.sh\nDepends on P4-02 (HIMMEL-8524).'; p_mk HIMMEL-8524
    case "$variant" in
        blocks) sed 's/blocks: \[\]/blocks: ["HIMMEL-8524"]/' "$M/HIMMEL-11001.md" > "$P/linked"; mv "$P/linked" "$M/HIMMEL-11001.md" ;;
        blocked-by) sed 's/blocked_by: \[\]/blocked_by: ["HIMMEL-8524"]/' "$M/HIMMEL-11001.md" > "$P/linked"; mv "$P/linked" "$M/HIMMEL-11001.md" ;;
        relates) sed 's/relates: \[\]/relates: ["HIMMEL-8524"]/' "$M/HIMMEL-11001.md" > "$P/linked"; mv "$P/linked" "$M/HIMMEL-11001.md" ;;
        edges) printf 'Edges: HIMMEL-8524 blocks HIMMEL-11001 (soft)\n' >> "$M/HIMMEL-11001.md" ;;
        wrong-side) printf 'Edges: HIMMEL-11001 blocks HIMMEL-8524 (soft)\n' >> "$M/HIMMEL-11001.md" ;;
        done) p_mk HIMMEL-8524 Done ;;
        self) p_mk HIMMEL-11001 'To Do' $'Writes: scripts/lib/alpha.sh\nDepends on HIMMEL-11001' ;;
        missing) rm "$M/HIMMEL-8524.md" ;;
    esac
    p_run --why-ticket HIMMEL-11001
    case "$variant" in missing|relates) has "P9 $variant still diagnosed" "$P_OUT" 'prose-dependency: HIMMEL-8524' ;; *) lacks "P9 $variant declared/done/self suppression (wrong-side A12 ceiling)" "$P_OUT" 'prose-dependency:' ;; esac
    [ "$variant" != missing ] || has 'P9 missing target named' "$P_OUT" '(not in mirror)'
done
for variant in shared type backlog parent-later released later live-done; do
    p_reset
    parent='["v1.0.1"]'; blocker='[]'; labels='[]'
    [ "$variant" != parent-later ] || parent='["v1.0.2"]'
    [ "$variant" != released ] || blocker='["v1.0.0"]'
    [ "$variant" != later ] || blocker='["v1.0.2"]'
    [ "$variant" != backlog ] || labels='["backlog"]'
    mk HIMMEL-11001 'To Do' Medium '[]' "$parent" '["HIMMEL-11002"]' fixture 'Writes: scripts/lib/alpha.sh'
    mk HIMMEL-11002 'To Do' Medium "$labels" "$blocker" '[]' fixture 'Writes: scripts/lib/other.sh'
    [ "$variant" != type ] || retype "$M/HIMMEL-11002.md" Epic
    if [ "$variant" = live-done ]; then
        # shellcheck disable=SC2016  # the generated fixture script expands its own positional argument
        printf '#!/usr/bin/env bash\nprintf "%%s\\tTask\\tDone\\tfixture\\n" "$2"\n' > "$P/live-done"; chmod +x "$P/live-done"
        P_JIRA="$P/live-done"; P_LIVE=1
    fi
    p_run --why-ticket HIMMEL-11001
    case "$variant" in
        live-done) p_verdict 'P13e-v live Done mirror open' 0; lacks 'P13e-v live Done no standalone diagnostic' "$P_OUT" 'blocker-no-version:' ;;
        later) p_verdict 'P13c later unreleased blocker' 1; lacks 'P13c later unreleased no diagnostic' "$P_OUT" 'blocker-no-version:' ;;
        *) p_verdict "P13/P13b/P13e-v $variant" 1; has "P13e-v diagnostic $variant" "$P_OUT" 'blocker-no-version: HIMMEL-11002 (no fixVersion)' ;;
    esac
    if [ "$variant" != live-done ]; then
        printf '{"workers":[]}\n' > "$P/empty-fleet.json"
        va="$(VSA_GH_CMD="$P/bin/gh" bash "$HERE/version-status-audit.sh" --mirror "$M" --workers-from "$P/empty-fleet.json" 2> "$P/audit-stderr")"
        if [ "$variant" = shared ]; then has 'P13e-v shared actual audit positive' "$va" $'BLOCKER-NO-VERSION\tHIMMEL-11002'; else lacks "P13e-v named audit divergence/control $variant" "$va" $'BLOCKER-NO-VERSION\tHIMMEL-11002'; fi
    fi
done
p_reset; p_mk HIMMEL-11001; p_tree tracker; rm "$PT/scripts/handover/chief-kit/tracker.py"
p_run --why-ticket HIMMEL-11001; p_unknown P18; has 'P18 tracker load reason' "$P_OUT" 'tracker.py'
mkdir -p "$P/drift-bin" "$P/drift-docs" "$P/emptyroot" "$P/snapshot"
cat > "$P/drift-bin/gh" <<'EOF'
#!/usr/bin/env bash
case "$1 $2" in
    'api rate_limit') printf '5000\t9999999999\t5000\n' ;;
    'pr list') printf '[]\n' ;;
    *) printf '[]\n' ;;
esac
EOF
cat > "$P/drift-jira" <<'EOF'
#!/usr/bin/env bash
case "$1" in
    list) printf 'HIMMEL-11001\tTask\t%s\tfixture\n' "$P_DRIFT_STATUS" ;;
    get) printf '{"fields":{"status":{"name":"%s"},"issuetype":{"name":"Task"},"labels":["held"]}}\n' "$P_DRIFT_STATUS" ;;
    versions) exit 0 ;;
    comments) printf '[]\n' ;;
    *) exit 1 ;;
esac
EOF
chmod +x "$P/drift-bin/gh" "$P/drift-jira"
printf '[]\n' > "$P/snapshot/prs.json"; : > "$P/snapshot/threads.tsv"
export P_DRIFT_STATUS
for variant in 'done' open todo closed; do
    p_reset; P_DRIFT_STATUS='In Progress'; target=Done
    [ "$variant" != todo ] || P_DRIFT_STATUS='To Do'
    [ "$variant" != open ] || target='To Do'
    [ "$variant" != closed ] || target=Closed
    mk HIMMEL-11001 "$P_DRIFT_STATUS" Medium '["held"]' '[]' '[]' fixture 'Writes: scripts/lib/alpha.sh'; p_mk HIMMEL-11002 "$target"
    python3 -I -c 'import datetime,json,sys; now=datetime.datetime.now(datetime.timezone.utc); row=dict(ts=now.strftime("%Y-%m-%dT%H:%M:%SZ"),event="hold",result="moved",key="HIMMEL-11001",owner="operator",until=(now+datetime.timedelta(days=1)).strftime("%Y-%m-%d"),on="HIMMEL-11002",reason="fixture"); open(sys.argv[1],"w").write(json.dumps(row)+"\n")' "$P/state/status-events.jsonl"
    printf 'HIMMEL-11001\tTask\t%s\tfixture\n' "$P_DRIFT_STATUS" > "$P/snapshot/jira.tsv"
    drift="$(PATH="$P/drift-bin:$PATH" GH_READ_ENV_ROOT="$P/emptyroot" TICKET_STATUS_STATE_DIR="$P/state" TICK_TRACKER_MIRROR_DIR="$M" WORKER_SESSION_JIRA_CLI="$P/drift-jira" HIMMEL_RELEASE_STATE_DIR="$P/release" bash "$HERE/status-drift.sh" --docs-dir "$P/drift-docs" --snapshot "$P/snapshot" 2> "$P/drift-stderr")"
    p_run --why-ticket HIMMEL-11001
    case "$variant" in
        done) has 'P11 actual drift positive nonvacuous' "$drift" 'HOLD-STALE HIMMEL-11001 on HIMMEL-11002 (Done)'; has 'P11 one-way predicate parity' "$P_OUT" 'stale-hold:' ;;
        open) lacks 'P11 actual drift open control' "$drift" 'HOLD-STALE '; lacks 'P11 predicate open control' "$P_OUT" 'stale-hold:' ;;
        todo) lacks 'P11b actual drift ranks To Do zero (known divergence)' "$drift" 'HOLD-STALE '; has 'P11b predicate To Do stale hold' "$P_OUT" 'stale-hold:' ;;
        closed) lacks 'P11c actual drift matches Done only (known divergence)' "$drift" 'HOLD-STALE '; has 'P11c predicate Done-category Closed' "$P_OUT" 'stale-hold:' ;;
    esac
done

p_reset
printf -- '---\nkey: HIMMEL-11001\n---\nWrites: scripts/lib/alpha.sh\n\nDoD\n- ready\n\nProof\n- control\n' > "$P/front-matter-draft"
p_run --why-ticket HIMMEL-11001 --body-file "$P/front-matter-draft"; p_verdict 'P15(c) partial front matter with direct description' 0
p_reset; p_mk HIMMEL-11001
cat > "$P/python-bin/python3" <<'EOF'
#!/usr/bin/env bash
if [ "$*" = '-I -' ]; then cat >/dev/null; cat "$P_STUB_OUTPUT"; exit "$P_STUB_RC"; fi  # read-sink-ok: the stub replays the output file this suite wrote under its scratch dir
exec "$P_REAL_PY" "$@"
EOF
chmod +x "$P/python-bin/python3"; export P_STUB_OUTPUT="$P/stub-output"
for variant in foreign-ready bad-gate mixed empty-unknown; do
    P_PATH="$P/python-bin:$PATH"
    case "$variant" in
        foreign-ready) P_STUB_RC=0; printf 'READY HIMMEL-11002\n' > "$P_STUB_OUTPUT" ;;
        bad-gate) P_STUB_RC=1; printf 'GATE HIMMEL-11001 invented: wrong grammar\n' > "$P_STUB_OUTPUT" ;;
        mixed) P_STUB_RC=0; printf 'READY HIMMEL-11001\nGATE HIMMEL-11001 no-proof: missing\n' > "$P_STUB_OUTPUT" ;;
        empty-unknown) P_STUB_RC=3; printf 'UNKNOWN HIMMEL-11001: \n' > "$P_STUB_OUTPUT" ;;
    esac
    p_run --why-ticket HIMMEL-11001; p_unknown "P8 malformed $variant"; has "P8 malformed $variant wrapper refusal" "$P_OUT" "unexpected exit $P_STUB_RC"
done
p_reset; p_mk HIMMEL-11001 'In Progress'; p_part HIMMEL-11001 7001 remaining; p_breadcrumb 7001 'edit scripts/lib/rem.sh'
printf 'print("malformed reader answer")\n' > "$P/malformed-reader.py"; P_READER="$P/malformed-reader.py"
p_run --why-ticket HIMMEL-11001; p_unknown 'P17 malformed reader'
printf '' > "$P/empty-reader.py"; P_READER="$P/empty-reader.py"
p_run --why-ticket HIMMEL-11001; p_unknown 'P17 empty reader'

# Resource failures retain the public UNKNOWN contract and leave no scratch.
p_reset; p_mk HIMMEL-11001
TMPDIR="$P/missing-temp-root" p_run --why-ticket HIMMEL-11001
p_unknown 'review F1 unavailable TMPDIR'
P_REAL_MKTEMP="$(command -v mktemp)"; export P_REAL_MKTEMP
for P_TMP_PHASE in quota out flags predicate; do
    p_reset; p_mk HIMMEL-11001
    mkdir -p "$P/failing-temp-bin" "$P/temp-$P_TMP_PHASE"
    export P_TMP_PHASE P_TMP_COUNT="$P/temp-count"
    printf '0\n' > "$P_TMP_COUNT"
    cat > "$P/failing-temp-bin/mktemp" <<'EOF'
#!/usr/bin/env bash
case "$*" in
    *next-dispatch-out*) [ "$P_TMP_PHASE" != out ] || exit 1 ;;
    *next-dispatch-flags*) [ "$P_TMP_PHASE" != flags ] || exit 1 ;;
esac
if [ "$1" = -d ]; then
    read -r n < "$P_TMP_COUNT"  # read-sink-ok: the stub's own counter file, created by this suite under its scratch dir
    n=$((n + 1)); printf '%s\n' "$n" > "$P_TMP_COUNT"
    [ "$P_TMP_PHASE" != quota ] || exit 1
    if [ "$P_TMP_PHASE" = predicate ] && [ "$n" -ge 2 ]; then exit 1; fi
fi
exec "$P_REAL_MKTEMP" "$@"
EOF
    chmod +x "$P/failing-temp-bin/mktemp"
    P_PATH="$P/failing-temp-bin:$PATH"
    TMPDIR="$P/temp-$P_TMP_PHASE" HIMMEL_QUOTA_DIR='' p_run --why-ticket HIMMEL-11001
    p_unknown "review F1 $P_TMP_PHASE allocation"
    if find "$P/temp-$P_TMP_PHASE" -mindepth 1 | grep -q .; then
        fail "review F1 $P_TMP_PHASE leaked scratch"
    else pass "review F1 $P_TMP_PHASE removed scratch"; fi
done

p_reset; p_mk HIMMEL-11001
printf '\n{truncated\nnull\n[]\n{"event":"merge","stage":"pre-merge","result":"pending","key":"HIMMEL-11001","pr":"7119","head":"unconfirmed","contract":"no"}\n' > "$P/state/status-events.jsonl"
p_run --why-ticket HIMMEL-11001; p_verdict 'review F2 valid rows survive non-records' 1
has 'review F2 real target event remains a gate' "$P_OUT" 'merge of PR #7119 unconfirmed'

for order in no-code-first path-first; do
    p_reset; p_mk HIMMEL-11001 'To Do' 'No description scope'
    if [ "$order" = no-code-first ]; then
        p_comment $'readiness: scoped\nWrites: no code\nWrites: scripts/lib/alpha.sh'
    else p_comment $'readiness: scoped\nWrites: scripts/lib/alpha.sh\nWrites: no code'; fi
    p_run --why-ticket HIMMEL-11001; p_verdict "review F4 $order" 0
    has "review F4 $order retains the written path" "$P_OUT" 'readiness comment 2026-11-17T00:00:00Z: scripts/lib/alpha.sh'
done

p_reset; p_mk HIMMEL-11001; p_tree proof-scratch
export P_PROOF_DRAFT="$P/proof-draft-seen"
cat > "$PT/marketplace/plugins/himmel-ops/scripts/ticket-standard-check.sh" <<'EOF'
#!/usr/bin/env bash
previous=''
for argument in "$@"; do
    [ "$previous" != --draft ] || printf '%s\n' "$argument" > "$P_PROOF_DRAFT"
    previous="$argument"
done
sleep 20
EOF
mkdir -p "$P/proof-temp"; P_LIMIT=4
TMPDIR="$P/proof-temp" p_run --why-ticket HIMMEL-11001
p_unknown 'review F3 proof-check deadline'
if [ -s "$P_PROOF_DRAFT" ]; then
    read -r draft < "$P_PROOF_DRAFT"
    [ ! -e "${draft%/*}" ] && pass 'review F3 proof draft removed on timeout' || fail 'review F3 leaked proof draft directory'
else fail 'review F3 proof checker never reached'; fi

# The dispatcher's worker-state reads: the same output in every mode, one read of a directory's manifests per run,
# one worker_state evaluation per unique doc. The tree below is a copy of the code under test whose fleet_runtime.py is
# the real module's own source run under a counting wrapper: the answers are the real ones, only the calls are logged.
U8="$WORK/u8"; mkdir -p "$U8"
u8_root="$(cd "$(dirname "$SUT")/../../.." && pwd)"
U8T="$U8/tree"; mkdir -p "$U8T/scripts/handover"
cp -R "$u8_root/scripts/handover/chief-kit" "$U8T/scripts/handover/chief-kit"
cp -R "$u8_root/scripts/lib" "$U8T/scripts/lib"
mkdir -p "$U8T/marketplace/plugins/himmel-ops"
cp -R "$u8_root/marketplace/plugins/himmel-ops/scripts" "$U8T/marketplace/plugins/himmel-ops/scripts"
cat > "$U8T/scripts/lib/fleet_runtime.py" <<'PYEOF'
"""Fixture stand-in for fleet_runtime.py: the real module's source, run as this file, with every worker_state call, every
disposition subprocess and every open of a *.fleet.json file logged to $FR_COUNT_LOG. FR_NO_BATCH=1 turns the batch off."""
import os, sys
_source = open(os.environ['FR_REAL_SOURCE'], encoding='utf-8').read()
_guard = "if __name__ == '__main__':"
assert _source.count(_guard) == 1
exec(compile(_source.replace(_guard, 'if False:'), __file__, 'exec'))
_log = os.environ.get('FR_COUNT_LOG')


def _note(*fields):
    if _log:
        with open(_log, 'a') as stream:
            stream.write('\t'.join(str(f) for f in fields) + '\n')


def _hook(event, args):
    if event == 'open' and isinstance(args[0], (str, bytes, os.PathLike)) and os.fsdecode(args[0]).endswith('.fleet.json'):
        frames, frame = [], sys._getframe(1)
        while frame and len(frames) < 14:
            frames.append(frame.f_code.co_name)
            frame = frame.f_back
        _note('open', os.fsdecode(args[0]), ','.join(frames))


sys.addaudithook(_hook)
_worker_state = worker_state


def worker_state(doc, *args, **kwargs):
    disposition = kwargs.get('disposition', args[1] if len(args) > 1 else None)
    _note('worker_state', doc, 'single' if disposition is None else 'batch')
    return _worker_state(doc, *args, **kwargs)


if os.environ.get('FR_NO_BATCH') and 'WorkerStates' in globals():
    WorkerStates.batched = lambda self, doc: None
if __name__ == '__main__':
    _note('main', *sys.argv[1:])
    sys.exit(main())
PYEOF
cat > "$U8/lock.sh" <<'EOF'
#!/usr/bin/env bash
# queue-lock.sh status, by the doc's name: -live a fresh lock, -stale a held lock whose owner is gone, anything else free
case "$2" in
    *-live.md) printf '{\n  "heartbeat": "%s"\n}\nstatus: FRESH\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"; exit 11 ;;
    *-stale.md) printf 'status: STALE-DEAD (owner pid gone)\n'; exit 12 ;;
    *) echo free; exit 0 ;;
esac
EOF
chmod +x "$U8/lock.sh"
# The first fixture, whose tickets are asserted as offered: every doc a row names exists and opens, the own manifest and every sibling read
# as JSON of the shape the dispatcher accepts. A doc nobody can open is a case of its own, below.
U8B="$U8/bucket"; U8H="$U8/home"; mkdir -p "$U8B" "$U8H/.himmel"
python3 -I - "$U8B" "$U8H" <<'PYEOF'
import json, os, sys
bucket, home = sys.argv[1:3]
anchor = os.path.join(bucket, 'fleet-control.json')


def doc(name, *lines):
    path = os.path.join(bucket, name)
    with open(path, 'w') as stream:
        stream.write('# worker\n' + ''.join(line + '\n' for line in lines))
    return path


D = dict(
    wrapped=doc('HIMMEL-101-N1-wrapped.md', '- 10:00 WRAPPED - done'),
    halted=doc('HIMMEL-102-N1-halted.md', '- 10:00 HALTED - stopped'),
    live=doc('HIMMEL-103-N1-live.md', '- 10:00 LIVE - working'),
    stale=doc('HIMMEL-104-N1-stale.md', '- 10:00 LIVE - working'),
    unknown=doc('HIMMEL-105-N1-unknown.md'),
    pending=doc('HIMMEL-107-N1-pending.md'),
    committed=doc('HIMMEL-108-N1-committed.md'),
    attempt_unknown=doc('HIMMEL-109-N1-attempt-unknown.md'),
    refused=doc('HIMMEL-110-N1-refused.md'),
    resumed=doc('HIMMEL-111-N1-resumed.md', '- 10:00 WRAPPED - done', '- 12:30 RESUMED - by hand'),
    rereg=doc('HIMMEL-112-N1-rereg.md'),
    legs_live=doc('HIMMEL-113-N1-legs-live.md', '- 10:00 LIVE - working'),
    legs_wrapped=doc('HIMMEL-114-N1-legs-wrapped.md', '- 10:00 WRAPPED - done'),
)
control = {'family': 'fam', 'anchor': anchor}


def rows(*names, pending=(), added='2026-11-18T08:00:00Z'):
    out = [dict(doc=D[n], label='N%d' % (i + 1), added=added, lane='native') for i, n in enumerate(names)]
    out += [dict(doc=D[n], label='P%d' % (i + 1), added=added, lane='native', registration='pending') for i, n in enumerate(pending)]
    return out


def manifest(name, workers):
    with open(os.path.join(bucket, name), 'w') as stream:
        json.dump({'schema': 1, 'workers': workers, 'control': control}, stream)


chain = 'HIMMEL-nextleg-2026-11-%s-roadmap-chief.fleet.json'
manifest(chain % '18A', rows('wrapped', 'live', 'unknown'))
manifest(chain % '17B', rows('wrapped', 'halted', 'stale', 'live', pending=('pending', 'committed', 'attempt_unknown', 'refused', 'resumed')))
manifest(chain % '17A', rows('wrapped', 'halted', 'stale', 'unknown', 'live'))
manifest(chain % '16C', rows('wrapped', 'halted', 'live', 'stale', 'unknown'))
manifest(chain % '16A', rows('wrapped', 'halted', 'live', 'stale', 'unknown', pending=('pending',)))
manifest(chain % '15A', rows('wrapped', 'halted', 'live', 'stale', 'unknown', pending=('rereg', 'refused')))
manifest('HIMMEL-nextleg-2026-11-17A-other-chief.fleet.json', rows('wrapped', 'live'))
# a manifest still written with the pre-rename array: the docs only it names are answered the same way
with open(os.path.join(bucket, chain % '15B'), 'w') as stream:
    json.dump({'schema': 1, 'legs': rows('legs_live', 'legs_wrapped'), 'control': control}, stream)
attempts = {}
for key, phase in (('pending', 'pending'), ('committed', 'committed'), ('attempt_unknown', 'unknown')):
    attempts['a-' + key] = dict(attempt_id='a-' + key, phase=phase, doc=D[key], name=os.path.basename(D[key])[:-3])
with open(anchor, 'w') as stream:
    json.dump({'family': 'fam', 'mode': 'active', 'generation': 1, 'target': 4, 'attempts': attempts}, stream)


def receipt(attempt, key, outcome, ts):
    return dict(v=2, kind='launch-attempt', ts=ts, attempt_id=attempt, name=os.path.basename(D[key])[:-3], doc=D[key], family='fam', outcome=outcome)


with open(os.path.join(home, '.himmel', 'launch-refusals.jsonl'), 'w') as stream:
    for row in (receipt('r1', 'refused', 'refused', '2026-11-18T09:00:00Z'), receipt('r2', 'resumed', 'complete', '2026-11-18T09:00:00Z'),
                receipt('r3', 'rereg', 'refused', '2026-11-18T07:00:00Z')):
        stream.write(json.dumps(row) + '\n')
PYEOF
U8M="$U8/mirror/HIMMEL"; mkdir -p "$U8M"
M_SAVE="$M"; M="$U8M"
for n in 101 102 103 104 105 107 108 109 110 111 112 113 114 120; do
    mk "HIMMEL-$n" "To Do" Medium '[]' '["v1.0.1"]' '[]' "u8 fixture $n" "Edit scripts/lib/u8-$n.sh only."
done
M="$M_SAVE"
printf 'v1.0.1\tfalse\t\n' > "$U8/mirror/HIMMEL.versions.tsv"
U8OWN="$U8B/HIMMEL-nextleg-2026-11-18A-roadmap-chief.fleet.json"
u8_nd() { # <label> <env prefix var=value or ""> mode args...: the tree's dispatcher, the counting wrapper on; output in $U8/out.<label>, rc in $U8/rc.<label>
    local label="$1" nobatch="$2"; shift 2
    : > "$U8/count.$label"
    env HOME="$U8H" TICKET_STATUS_QUEUE_LOCK="$U8/lock.sh" TICKET_STATUS_STATE_DIR="$U8/state" FR_REAL_SOURCE="$u8_root/scripts/lib/fleet_runtime.py" \
        FR_COUNT_LOG="$U8/count.$label" ${nobatch:+FR_NO_BATCH=1} NEXT_DISPATCH_MIRROR="$U8M" NEXT_DISPATCH_GH_CMD="$WORK/gh" \
        bash "$U8T/scripts/handover/chief-kit/next-dispatchable.sh" --no-classify --workers-from "$U8OWN" "$@" > "$U8/out.$label" 2> "$U8/err.$label"
    printf '%s\n' "$?" > "$U8/rc.$label"
}
u8_modes=("list|--top 40" "resume|--resume-only --top 40" "why|--why --top 40" "dispositions|--dispositions --top 40")
for mode in "${u8_modes[@]}"; do
    name="${mode%%|*}"; args="${mode#*|}"
    # shellcheck disable=SC2086  # the mode's arguments are word-split on purpose
    u8_nd "$name" "" $args
    # shellcheck disable=SC2086
    u8_nd "$name.single" 1 $args
    [ "$(cat "$U8/rc.$name")" = 0 ] && pass "(U8) $name: the dispatcher exits 0" || fail "(U8) $name: rc $(cat "$U8/rc.$name"): $(head -c 300 "$U8/err.$name")"
    cmp -s "$U8/out.$name" "$U8/out.$name.single" && pass "(U8) $name: the batched read prints the same bytes as one read per doc" \
        || fail "(U8) $name: the batched read differs from one read per doc: $(diff "$U8/out.$name" "$U8/out.$name.single" | head -5)"
    [ -s "$U8/out.$name" ] && pass "(U8) $name: the dispatcher printed something" || fail "(U8) $name: the dispatcher printed nothing"
    [ -z "${ND_U8_EVIDENCE:-}" ] || { mkdir -p "$ND_U8_EVIDENCE"; cp "$U8/out.$name" "$ND_U8_EVIDENCE/out.$name"; }
done
u8_list="$(cat "$U8/out.list")"
for key in 101 102 110 114 120; do has "(U8) a ticket no live worker holds is offered: HIMMEL-$key" "$u8_list" "${TAB}HIMMEL-$key${TAB}"; done
for key in 103 104 105 107 108 109 112 113; do lacks "(U8) a ticket a worker in doubt or alive holds is withheld: HIMMEL-$key" "$u8_list" "${TAB}HIMMEL-$key${TAB}"; done
cl="$U8/count.list"
u8_max_per_doc="$(awk -F'\t' '$1 == "worker_state" { c[$2]++ } END { m = 0; for (d in c) if (c[d] > m) m = c[d]; print m + 0 }' "$cl")"
u8_docs="$(awk -F'\t' '$1 == "worker_state" { c[$2]++ } END { n = 0; for (d in c) n++; print n }' "$cl")"
u8_single="$(awk -F'\t' '$1 == "worker_state" && $3 == "single" { n++ } END { print n + 0 }' "$cl")"
u8_subproc="$(awk -F'\t' '$1 == "main" { n++ } END { print n + 0 }' "$cl")"
u8_scan_max="$(awk -F'\t' '$1 == "open" && $3 ~ /read_directory/ { c[$2]++ } END { m = 0; for (p in c) if (c[p] > m) m = c[p]; print m + 0 }' "$cl")"
u8_scan_paths="$(awk -F'\t' '$1 == "open" && $3 ~ /read_directory/ { c[$2] = 1 } END { n = 0; for (p in c) n++; print n }' "$cl")"
u8_single_reads="$(awk -F'\t' '$1 == "open" && $3 ~ /(disposition|protected)/ { n++ } END { print n + 0 }' "$cl")"
[ "$u8_docs" -ge 10 ] && pass "(U8) the run asked about the fixture's docs ($u8_docs unique)" || fail "(U8) the run asked about $u8_docs docs only"
u8_eq() { [ "$2" = "$3" ] && pass "$1" || fail "$1 (want '$3', got '$2')"; }
u8_eq "(U8) count: worker_state is evaluated once per unique doc, never twice" "$u8_max_per_doc" 1
u8_eq "(U8) count: every evaluation took its disposition from the one batch read" "$u8_single" 0
u8_eq "(U8) count: no disposition subprocess started" "$u8_subproc" 0
u8_eq "(U8) count: no manifest was opened by the one-doc disposition" "$u8_single_reads" 0
u8_eq "(U8) count: each manifest of the directory was read once by the batch" "$u8_scan_max" 1
u8_eq "(U8) count: the batch read every manifest of the directory" "$u8_scan_paths" "$(find "$U8B" -maxdepth 1 -name '*.fleet.json' | grep -c .)"
# fail closed: a manifest the batch cannot read leaves every doc of the directory to the one-doc read, which reports what it reports
printf '{not json' > "$U8B/zz-broken.fleet.json"
u8_nd broken ""  --top 40
u8_nd broken.single 1 --top 40
cmp -s "$U8/out.broken" "$U8/out.broken.single" && pass "(U8) a manifest the batch cannot read: the output is the one-doc output" \
    || fail "(U8) a manifest the batch cannot read changed the output: $(diff "$U8/out.broken" "$U8/out.broken.single" | head -5)"
u8_eq "(U8) a manifest the batch cannot read: no doc is answered from the batch" "$(awk -F'\t' '$1 == "worker_state" && $3 == "batch" { n++ } END { print n + 0 }' "$U8/count.broken")" 0
u8_eq "(U8) a manifest the batch cannot read: each doc is still evaluated once" \
    "$(awk -F'\t' '$1 == "worker_state" { c[$2]++ } END { m = 0; for (d in c) if (c[d] > m) m = c[d]; print m + 0 }' "$U8/count.broken")" 1
rm -f "$U8B/zz-broken.fleet.json"
# the bucket as the stations have it today: no anchor and no receipts
U8B2="$U8/bucket2"; U8H2="$U8/home2"; mkdir -p "$U8H2"; cp -R "$U8B" "$U8B2"; rm -f "$U8B2/fleet-control.json"
for f in "$U8B2"/*.fleet.json; do sed "s#$U8B#$U8B2#g" "$f" > "$f.tmp" && mv "$f.tmp" "$f"; done
U8B_SAVE="$U8B"; U8OWN_SAVE="$U8OWN"; U8H_SAVE="$U8H"
U8B="$U8B2"; U8OWN="$U8B2/HIMMEL-nextleg-2026-11-18A-roadmap-chief.fleet.json"; U8H="$U8H2"
for mode in "${u8_modes[@]}"; do
    name="${mode%%|*}"; args="${mode#*|}"
    # shellcheck disable=SC2086
    u8_nd "plain-$name" "" $args
    # shellcheck disable=SC2086
    u8_nd "plain-$name.single" 1 $args
    cmp -s "$U8/out.plain-$name" "$U8/out.plain-$name.single" && pass "(U8) no anchor, $name: the batched read prints the same bytes as one read per doc" \
        || fail "(U8) no anchor, $name: the batched read differs from one read per doc: $(diff "$U8/out.plain-$name" "$U8/out.plain-$name.single" | head -5)"
    [ -s "$U8/out.plain-$name" ] && pass "(U8) no anchor, $name: the dispatcher printed something" || fail "(U8) no anchor, $name: the dispatcher printed nothing"
    [ -z "${ND_U8_EVIDENCE:-}" ] || cp "$U8/out.plain-$name" "$ND_U8_EVIDENCE/out.plain-$name"
done
cl="$U8/count.plain-list"
u8_eq "(U8) no anchor, count: worker_state is evaluated once per unique doc" "$(awk -F'\t' '$1 == "worker_state" { c[$2]++ } END { m = 0; for (d in c) if (c[d] > m) m = c[d]; print m + 0 }' "$cl")" 1
u8_eq "(U8) no anchor, count: every evaluation took its disposition from the one batch read" "$(awk -F'\t' '$1 == "worker_state" && $3 == "single" { n++ } END { print n + 0 }' "$cl")" 0
u8_eq "(U8) no anchor, count: no disposition subprocess started" "$(awk -F'\t' '$1 == "main" { n++ } END { print n + 0 }' "$cl")" 0
u8_eq "(U8) no anchor, count: each manifest was read once by the batch" "$(awk -F'\t' '$1 == "open" && $3 ~ /read_directory/ { c[$2]++ } END { m = 0; for (p in c) if (c[p] > m) m = c[p]; print m + 0 }' "$cl")" 1
U8B="$U8B_SAVE"; U8OWN="$U8OWN_SAVE"; U8H="$U8H_SAVE"

# A doc that the worker rows name and nobody can open, on a fixture of its own: its own bucket, its own chain and a one-ticket mirror, so
# it shares nothing with the fixtures above, whose docs all exist and whose manifests all read. What is asserted here holds whether or not
# the dispatcher lists other tickets beside an unreadable doc: it exits 0, the doc's own key is not offered, the batched read prints the
# same bytes as one read per doc, and the doc gets one worker-state answer however many rows name it.
U8B4="$U8/bucket4"; mkdir -p "$U8B4"
U8MISS="$U8B4/HIMMEL-106-N1-missing.md"  # never created
for stamp in 18A 17A 16C 16A 15A; do
    printf '{"schema":1,"workers":[{"doc":"%s","label":"N1"}]}\n' "$U8MISS" > "$U8B4/HIMMEL-nextleg-2026-11-$stamp-recovery-chief.fleet.json"
done
U8M4="$U8/mirror4/HIMMEL"; mkdir -p "$U8M4"
M_SAVE="$M"; M="$U8M4"; mk HIMMEL-106 "To Do" Medium '[]' '["v1.0.1"]' '[]' "u8 a doc nobody can open" "Edit scripts/lib/u8-106.sh only."; M="$M_SAVE"
printf 'v1.0.1\tfalse\t\n' > "$U8/mirror4/HIMMEL.versions.tsv"
U8M_SAVE="$U8M"; U8OWN_SAVE="$U8OWN"
U8M="$U8M4"; U8OWN="$U8B4/HIMMEL-nextleg-2026-11-18A-recovery-chief.fleet.json"
for mode in "${u8_modes[@]}"; do
    name="${mode%%|*}"; args="${mode#*|}"
    # shellcheck disable=SC2086
    u8_nd "missing-$name" "" $args
    # shellcheck disable=SC2086
    u8_nd "missing-$name.single" 1 $args
    [ "$(cat "$U8/rc.missing-$name")" = 0 ] && pass "(U8) a doc nobody can open, $name: the dispatcher exits 0" || fail "(U8) a doc nobody can open, $name: rc $(cat "$U8/rc.missing-$name"): $(head -c 300 "$U8/err.missing-$name")"
    cmp -s "$U8/out.missing-$name" "$U8/out.missing-$name.single" && pass "(U8) a doc nobody can open, $name: the batched read prints the same bytes as one read per doc" \
        || fail "(U8) a doc nobody can open, $name: the batched read differs from one read per doc: $(diff "$U8/out.missing-$name" "$U8/out.missing-$name.single" | head -5)"
    [ -z "${ND_U8_EVIDENCE:-}" ] || cp "$U8/out.missing-$name" "$ND_U8_EVIDENCE/out.missing-$name"
done
lacks "(U8) a doc nobody can open: its own ticket is not offered" "$(cat "$U8/out.missing-list")" "${TAB}HIMMEL-106${TAB}"
u8_eq "(U8) a doc nobody can open: it gets one worker-state answer though five manifests name it" "$(awk -F'\t' '$1 == "worker_state" { c[$2]++ } END { m = 0; for (d in c) if (c[d] > m) m = c[d]; print m + 0 }' "$U8/count.missing-list")" 1
u8_eq "(U8) a doc nobody can open: it is the one doc asked about" "$(awk -F'\t' '$1 == "worker_state" { c[$2]++ } END { n = 0; for (d in c) n++; print n }' "$U8/count.missing-list")" 1
U8M="$U8M_SAVE"; U8OWN="$U8OWN_SAVE"

# Follow-ups on the same tree. A worker_state helper that fails reads unknown through the batch path (never wrapped, so no
# ticket of a doc whose state cannot be read is offered), and two docs with one basename in two directories keep their own states.
cp "$U8T/scripts/lib/ticket-status.sh" "$U8/ticket-status.good"
printf 'exit 1\n' > "$U8T/scripts/lib/ticket-status.sh"
u8_nd failing "" --top 40
cp "$U8/ticket-status.good" "$U8T/scripts/lib/ticket-status.sh"
u8_failing="$(cat "$U8/out.failing")"
[ "$(cat "$U8/rc.failing")" = 0 ] && pass "(U8) a helper that fails: the dispatcher still exits 0" || fail "(U8) a helper that fails: rc $(cat "$U8/rc.failing")"
for key in 101 102 114; do lacks "(U8) a helper that fails reads unknown, so a ticket whose doc is not proven wrapped is withheld: HIMMEL-$key" "$u8_failing" "${TAB}HIMMEL-$key${TAB}"; done
for key in 110 120; do has "(U8) a helper that fails does not hide a ticket no worker row names: HIMMEL-$key" "$u8_failing" "${TAB}HIMMEL-$key${TAB}"; done
U8B3="$U8/bucket3"; mkdir -p "$U8B3/sub1" "$U8B3/sub2"
printf '# worker\n- 10:00 WRAPPED - done\n' > "$U8B3/sub1/HIMMEL-115-N1-live.md"
printf '# worker\n- 10:00 LIVE - working\n' > "$U8B3/sub2/HIMMEL-115-N1-live.md"
printf '{"schema":1,"workers":[{"doc":"%s","label":"N1"}]}\n' "$U8B3/sub1/HIMMEL-115-N1-live.md" > "$U8B3/HIMMEL-nextleg-2026-11-18A-roadmap-chief.fleet.json"
printf '{"schema":1,"workers":[{"doc":"%s","label":"N2"}]}\n' "$U8B3/sub2/HIMMEL-115-N1-live.md" > "$U8B3/HIMMEL-nextleg-2026-11-17A-roadmap-chief.fleet.json"
M_SAVE="$M"; M="$U8M"; mk HIMMEL-115 "To Do" Medium '[]' '["v1.0.1"]' '[]' "u8 one basename in two directories" "Edit scripts/lib/u8-115.sh only."; M="$M_SAVE"
U8OWN_SAVE="$U8OWN"; U8OWN="$U8B3/HIMMEL-nextleg-2026-11-18A-roadmap-chief.fleet.json"
u8_nd samebase "" --top 40
U8OWN="$U8OWN_SAVE"
u8_same="$(cat "$U8/out.samebase")"
lacks "(U8) two docs with one basename keep their own states: the live one holds its ticket although the wrapped one was asked first" "$u8_same" "${TAB}HIMMEL-115${TAB}"
has "(U8) two docs with one basename: a ticket no worker holds is still offered" "$u8_same" "${TAB}HIMMEL-120${TAB}"
u8_eq "(U8) two docs with one basename are each evaluated once" "$(awk -F'\t' '$1 == "worker_state" { c[$2]++ } END { n = 0; for (d in c) n++; print n }' "$U8/count.samebase")" 2

# --- 9335: a named worker source that cannot be fully read withholds what it may own ---
# Fixture M (ow_mirror): an In Progress orphan with one scope file, an In Progress bundle sibling with no PR, an IN CI ticket with no merged PR
# and a To Do ticket with one scope file, all in version v1.0.1. The controls below hold whatever the dispatcher does about an unknown owner.
OW="$WORK/ow9335"; mkdir -p "$OW"
ow_mirror() { # <name>: fixture M under $OW/<name>/HIMMEL, sets OW_M
    OW_M="$OW/$1/HIMMEL"; mkdir -p "$OW_M"
    local M="$OW_M"
    mk HIMMEL-60 "In Progress" High '[]' '["v1.0.1"]' '[]' "orphan with a scope" "Edit scripts/lib/s1.sh only."
    mk HIMMEL-63 "In Progress" High '[]' '["v1.0.1"]' '[]' "bundle sibling with no PR" "Edit scripts/lib/s3.sh only."
    mk HIMMEL-65 "IN CI" High '[]' '["v1.0.1"]' '[]' "in CI with no merged PR" "Edit scripts/lib/s5.sh only."
    mk HIMMEL-90 "To Do" High '[]' '["v1.0.1"]' '[]' "free to do" "Edit scripts/lib/x.sh only."
    printf 'v1.0.1\tfalse\t\n' > "$OW/$1/HIMMEL.versions.tsv"
}
ow_mk() { local M="$OW_M"; mk "$@"; }  # add one ticket to the mirror OW_M points at
ow_run() { NEXT_DISPATCH_MIRROR="$OW_M" NEXT_DISPATCH_GH_CMD="$WORK/gh" NEXT_DISPATCH_CLASSIFY_CMD="$WORK/classify2" bash "$SUT" "$@" 2>/dev/null; }
ow_run2() { NEXT_DISPATCH_MIRROR="$OW_M" NEXT_DISPATCH_GH_CMD="$WORK/gh" NEXT_DISPATCH_CLASSIFY_CMD="$WORK/classify2" bash "$SUT" "$@" 2>&1; }
ow_err() { { NEXT_DISPATCH_MIRROR="$OW_M" NEXT_DISPATCH_GH_CMD="$WORK/gh" NEXT_DISPATCH_CLASSIFY_CMD="$WORK/classify2" bash "$SUT" "$@" > /dev/null; } 2>&1; }  # stderr only
ow_oracle() { # <doc> [home]: the answer fleet_runtime.worker_state asks of ticket-status.sh, with HOME set to <home> (default: the fixture HOME)
    HOME="${2:-$HOME}" bash -c '. "$1/ticket-status.sh"; ts_worker_state "$2"' fleet-runtime "$HERE/../../lib" "$1" 2>/dev/null
}
ow_n() { printf '%s\n' "$1" | grep -c -E "$2" || true; }  # <text> <regex>: the count of matching lines
ow_tree_sum() { find "$OW" "$HOME" "$HANDOVER_DIR" "$TICKET_STATUS_STATE_DIR" -type f -exec cksum {} + 2>/dev/null | LC_ALL=C sort | cksum; }
ow_doc() { printf '# worker\n\n## Results\n%s\n' "$2" > "$1"; }  # <path> <one results line>
ow_lockstub() { # <path> <status line or empty> <rc>: a queue-lock stand-in that logs every call to $OW/qlock.log
    { printf '#!/usr/bin/env bash\n'; printf 'printf "%%s\\n" "$*" >> "%s/qlock.log"\n' "$OW"; [ -z "$2" ] || printf 'echo "%s"\n' "$2"; printf 'exit %s\n' "$3"; } > "$1"
    chmod +x "$1"
}

mkdir -p "$OW/x6a/HIMMEL" "$OW/x6b/HIMMEL"
OW_M="$OW/x6a/HIMMEL"; ow_mk HIMMEL-420 "In Progress" Low '["must-v1.0.1"]' '[]' '[]' "only a worker-less pool ticket" "Edit scripts/lib/t1.sh only."
printf 'v1.0.1\tfalse\t\n' > "$OW/x6a/HIMMEL.versions.tsv"
OW_M="$OW/x6b/HIMMEL"; ow_mk HIMMEL-160 "To Do" Highest '[]' '["v1.0.1"]' '[]' "only tier5" "Edit scripts/lib/w1.sh only."
S1_LINE='^# owner unknown: the fleet \(no worker source named\); withheld: RESUME, IN CI, STACKABLE, SERIES FAMILY, To Do, DESIGN, NEXT-TIER; reconcile: pass --workers-from <manifest> or --owners <keys>$'
OW_M="$OW/x6a/HIMMEL"
ow_x6n_out="$(ow_run --priority-pool-only)"; ow_x6n_err="$(ow_err --priority-pool-only)"
has "10557 S1: the n12 shape says on stderr that it has no worker source" "$ow_x6n_err" "no worker source"
lacks "10557 S1: the n12 shape offers no RESUME row" "$ow_x6n_out" "RESUME${TAB}"
check "10557 S1: the n12 shape prints one owner-unknown line for the fleet" "1" "$(ow_n "$ow_x6n_out" "$S1_LINE")"
has "10557 S1: the n12 shape prints POOL-EMPTY" "$ow_x6n_out" "POOL-EMPTY"
OW_M="$OW/x6b/HIMMEL"
ow_x6e_out="$(ow_run --priority-pool-only)"; ow_x6e_err="$(ow_err --priority-pool-only)"
has "10557 S1: the e8 shape says on stderr that it has no worker source" "$ow_x6e_err" "no worker source"
check "10557 S1: the e8 shape prints one owner-unknown line for the fleet" "1" "$(ow_n "$ow_x6e_out" "$S1_LINE")"
has "10557 S1: the e8 shape prints POOL-EMPTY" "$ow_x6e_out" "POOL-EMPTY"
lacks "10557 S1: the e8 shape lists no next-tier candidate" "$ow_x6e_out" "NEXT-TIER${TAB}"
lacks "10557 S1: the e8 shape lists no To Do row" "$ow_x6e_out" "HIMMEL-160${TAB}"
lacks "10557 S1: the e8 shape lists no DESIGN row" "$ow_x6e_out" "DESIGN${TAB}"
has "10557 S1.ctl: a core ticket with no signed spec lists DESIGN when a worker source is named" "$(runcg "$CGM" --priority-pool-only --owners "$KP-999")" "DESIGN${TAB}HIMMEL-901${TAB}NO-SPEC"
lacks "10557 S1: with no worker source the same core ticket lists no DESIGN row" "$(runcg "$CGM" --priority-pool-only)" "DESIGN${TAB}"
ow_x6t_out="$(ow_run --priority-pool-only --top 8)"; ow_x6t_err="$(ow_err --priority-pool-only --top 8)"
has "10557 S1: the e10 shape says on stderr that it has no worker source" "$ow_x6t_err" "no worker source"
check "10557 S1: the e10 shape prints one owner-unknown line for the fleet" "1" "$(ow_n "$ow_x6t_out" "$S1_LINE")"
has "10557 S1: the e10 shape prints pool=0/8,LOW" "$ow_x6t_out" "pool=0/8,LOW"
lacks "10557 S1: the e10 shape lists no next-tier candidate" "$ow_x6t_out" "NEXT-TIER${TAB}"
mkdir -p "$OW/x6c/HIMMEL"; printf 'v1.0.1\tfalse\t\n' > "$OW/x6c/HIMMEL.versions.tsv"
OW_M="$OW/x6c/HIMMEL"; ow_mk HIMMEL-430 "To Do" High '["must-v1.0.1"]' '["v1.0.1"]' '[]' "a pool To Do" "Edit scripts/lib/t2.sh only."
ow_x6d_out="$(ow_run --priority-pool-only --dispositions)"
check "10557 S1: with --dispositions one owner-unknown line for the fleet" "1" "$(ow_n "$ow_x6d_out" "$S1_LINE")"
lacks "10557 S1: with --dispositions the pool To Do is not listed" "$ow_x6d_out" "HIMMEL-430${TAB}"
has "10557 S1: with --dispositions the To Do disposition names no worker source" "$ow_x6d_out" "# disposition HIMMEL-430 owner unknown: no worker source named (see the # owner unknown line)"
OW_M="$OW/x6a/HIMMEL"
has "10557 S1.ctl: with an --owners key the same pool lists the worker-less ticket" "$(ow_run --priority-pool-only --owners "$KP-999")" "RESUME${TAB}HIMMEL-420"

# X2: the WORKERS_FROM environment source is not read by --why-ticket, and --why-ticket refuses --workers-from
ow_mirror x2
mkfleet "$OW/fleet-x2.json" "N1:$WORKER"
ow_x2_set="$( export WORKERS_FROM="$OW/fleet-x2.json"; ow_run --why-ticket "$KP-90" )"
ow_x2_unset="$( unset WORKERS_FROM; ow_run --why-ticket "$KP-90" )"
check "9335 X2: --why-ticket answers the same with and without WORKERS_FROM in the environment" "$ow_x2_unset" "$ow_x2_set"
has "9335 X2.ans: the --why-ticket answer is a verdict for the ticket" "$ow_x2_unset" "HIMMEL-90"
ow_run --why-ticket "$KP-90" --workers-from "$OW/fleet-x2.json" > /dev/null; ow_x2_rc=$?
check "9335 X2.rc: --why-ticket with --workers-from exits 2" "2" "$ow_x2_rc"

# U10: a worker doc that ends WRAPPED frees its ticket and prints no unknown line (over-withholding control)
ow_mirror u10
mkdir -p "$OW/u10"
ow_doc "$OW/u10/HIMMEL-63-N10-done.md" "- 10:30 WRAPPED - done"
mkfleet "$OW/u10/fleet-w.json" "N10:$OW/u10/HIMMEL-63-N10-done.md"
ow_u10w="$(ow_run --resume-only --workers-from "$OW/u10/fleet-w.json")"
has "9335 U10: a WRAPPED own doc frees its ticket: RESUME HIMMEL-63 lists" "$ow_u10w" "RESUME${TAB}HIMMEL-63"
lacks "9335 U10: a WRAPPED own doc prints no owner-unknown line" "$ow_u10w" "# owner unknown"
ow_doc "$OW/u10/HIMMEL-63-N10-live.md" "- 10:00 LIVE - started"
mkfleet "$OW/u10/fleet-l.json" "N10:$OW/u10/HIMMEL-63-N10-live.md"
ow_u10l="$(ow_run --resume-only --workers-from "$OW/u10/fleet-l.json")"
lacks "9335 U10.ctl: the same doc ending LIVE holds the ticket" "$ow_u10l" "RESUME${TAB}HIMMEL-63"

# SB3: a sibling manifest whose readable doc ends WRAPPED frees its ticket and prints no unknown line
ow_mirror sb3
mkdir -p "$OW/sb3"
ow_doc "$OW/sb3/HIMMEL-71-N14-own.md" "- 10:00 LIVE - started"
mkfleet "$OW/sb3/HIMMEL-nextleg-2026-11-18B-ow.fleet.json" "N14:$OW/sb3/HIMMEL-71-N14-own.md"
ow_doc "$OW/sb3/HIMMEL-63-N15-sib.md" "- 10:30 WRAPPED - done"
mkfleet "$OW/sb3/HIMMEL-nextleg-2026-11-17A-ow.fleet.json" "N15:$OW/sb3/HIMMEL-63-N15-sib.md"
ow_sb3="$(ow_run --resume-only --workers-from "$OW/sb3/HIMMEL-nextleg-2026-11-18B-ow.fleet.json")"
has "9335 SB3: a sibling doc that ends WRAPPED frees its ticket: RESUME HIMMEL-63 lists" "$ow_sb3" "RESUME${TAB}HIMMEL-63"
lacks "9335 SB3: a sibling doc that ends WRAPPED prints no owner-unknown line" "$ow_sb3" "# owner unknown"
ow_doc "$OW/sb3/HIMMEL-63-N15-sib.md" "- 10:00 LIVE - started"
ow_sb3l="$(ow_run --resume-only --workers-from "$OW/sb3/HIMMEL-nextleg-2026-11-18B-ow.fleet.json")"
lacks "9335 SB3.ctl: the same sibling doc ending LIVE holds the ticket" "$ow_sb3l" "RESUME${TAB}HIMMEL-63"

# P1: only an end marker frees a doc; the oracle (ts_worker_state, as fleet_runtime.worker_state asks it) is asserted first
ow_mirror p1
mkdir -p "$OW/p1"
for ow_pm in READY:71 LIVE:72 WRAPPED:73 HALTED:74 PARKED-USAGE:75; do
    ow_mark="${ow_pm%%:*}"; ow_key="${ow_pm##*:}"
    ow_ok="$(printf '%s' "$ow_mark" | tr '[:upper:]' '[:lower:]')"
    ow_mk "HIMMEL-$ow_key" "In Progress" High '[]' '["v1.0.1"]' '[]' "marker $ow_mark" "Edit scripts/lib/p$ow_key.sh only."
    ow_pdoc="$OW/p1/HIMMEL-$ow_key-N$ow_key-$ow_ok.md"
    ow_doc "$ow_pdoc" "- 10:00 $ow_mark - marker under test"
    mkfleet "$OW/p1/fleet-$ow_key.json" "N$ow_key:$ow_pdoc"
    ow_orc="$(ow_oracle "$ow_pdoc")"
    case "$ow_mark" in WRAPPED|HALTED) ow_want=wrapped ;; *) ow_want=held ;; esac
    [ "$ow_orc" = wrapped ] || ow_orc=held
    check "9335 P1: the oracle answers $ow_want for a doc whose newest marker is $ow_mark" "$ow_want" "$ow_orc"
    ow_pl="$(ow_run --resume-only --workers-from "$OW/p1/fleet-$ow_key.json")"
    if [ "$ow_want" = wrapped ]; then
        has "9335 P1: a doc ending $ow_mark frees its ticket" "$ow_pl" "RESUME${TAB}HIMMEL-$ow_key"
    else
        lacks "9335 P1: a doc ending $ow_mark holds its ticket" "$ow_pl" "RESUME${TAB}HIMMEL-$ow_key"
    fi
done

# P2: a dead, a stale and a free lock over a LIVE doc never free it; the lock stage is reached (the stub logs its call)
ow_mirror p2
mkdir -p "$OW/p2"
ow_mk HIMMEL-76 "In Progress" High '[]' '["v1.0.1"]' '[]' "live doc under a lock stub" "Edit scripts/lib/p76.sh only."
ow_doc "$OW/p2/HIMMEL-76-N76-live.md" "- 10:00 LIVE - started"
mkfleet "$OW/p2/fleet.json" "N76:$OW/p2/HIMMEL-76-N76-live.md"
for ow_ls in "dead:status: STALE-DEAD:12" "stale:status: STALE (age 9999s >= ttl 1800s):12" "free::0"; do
    ow_lname="${ow_ls%%:*}"; ow_rest="${ow_ls#*:}"; ow_lline="${ow_rest%:*}"; ow_lrc="${ow_rest##*:}"
    ow_lockstub "$OW/p2/lock-$ow_lname.sh" "$ow_lline" "$ow_lrc"
    : > "$OW/qlock.log"
    ow_p2="$(TICKET_STATUS_QUEUE_LOCK="$OW/p2/lock-$ow_lname.sh" ow_run --resume-only --workers-from "$OW/p2/fleet.json")"
    lacks "9335 P2: a $ow_lname lock over a LIVE doc leaves the ticket owned" "$ow_p2" "RESUME${TAB}HIMMEL-76"
    [ -s "$OW/qlock.log" ] && pass "9335 P2: the $ow_lname lock stub was asked (the lock stage was reached)" || fail "9335 P2: the $ow_lname lock stub was never asked"
done

# P3: a doc untouched for 48 hours is owned like a fresh one: age is a label only
ow_mirror p3
mkdir -p "$OW/p3"
ow_mk HIMMEL-77 "In Progress" High '[]' '["v1.0.1"]' '[]' "old live doc under a held lock" "Edit scripts/lib/p77.sh only."
ow_lockstub "$OW/p3/lock-held.sh" "status: FRESH" 11
mkfleet "$OW/p3/fleet.json" "N77:$OW/p3/HIMMEL-77-N77-live.md"
for ow_age in old fresh; do
    ow_doc "$OW/p3/HIMMEL-77-N77-live.md" "- 08:00 LIVE - started"
    [ "$ow_age" = old ] && ago "$OW/p3/HIMMEL-77-N77-live.md" 48
    : > "$OW/qlock.log"
    ow_p3="$(TICKET_STATUS_QUEUE_LOCK="$OW/p3/lock-held.sh" ow_run --resume-only --workers-from "$OW/p3/fleet.json")"
    lacks "9335 P3: the $ow_age LIVE doc under a held lock leaves the ticket owned" "$ow_p3" "RESUME${TAB}HIMMEL-77"
    [ -s "$OW/qlock.log" ] && pass "9335 P3: the $ow_age run asked the lock stub" || fail "9335 P3: the $ow_age run never asked the lock stub"
done


# --- 9335 N1: an own or sibling worker doc that cannot be opened withholds the existing lists and prints one line ---
ow_go() { ow_run "$@" > "$OW/last.out"; OW_RC=$?; OW_OUT="$(cat "$OW/last.out")"; }    # stdout only; sets OW_RC and OW_OUT
ow_go2() { ow_run2 "$@" > "$OW/last.out"; OW_RC=$?; OW_OUT="$(cat "$OW/last.out")"; }  # stdout and stderr merged
ow_forged() { printf '%s\n' "$1" | grep -cE "^LOCAL${TAB}${KP}-9([^0-9]|\$)" || true; }  # output lines that are the forged row for the short key (the real row carries a longer key)
ow_norm() { sed 's/live worker [A-Za-z0-9._-]*/live worker L/; s/chief on [^ ]*/chief on S/; s/mirror_age_min=[0-9]*/mirror_age_min=N/'; }  # the mirror's age in minutes can tick between two runs

ow_mirror m1
M1_LINE_TAIL='withheld: RESUME, IN CI, STACKABLE, SERIES FAMILY, To Do, DESIGN, NEXT-TIER; reconcile: repair the manifest file by hand (fleet-manifest.sh refuses an invalid one) or pass a readable --workers-from manifest'
m1_case() {
    printf '%s\n' "$2" > "$OW/m1/m1$1.fleet.json"
    ow_go2 --resume-only --workers-from "$OW/m1/m1$1.fleet.json"
    check "10557 M1 ($1): exit 0" "0" "$OW_RC"
    lacks "10557 M1 ($1): no Traceback" "$OW_OUT" "Traceback"
    check "10557 M1 ($1): one owner-unknown line names the malformed manifest" "1" "$(printf '%s\n' "$OW_OUT" | grep -cxF "# owner unknown: the fleet (manifest m1$1.fleet.json malformed); $M1_LINE_TAIL" || true)"
}
m1_case a '{"schema":1,"workers":[7]}'
m1_case b '{"schema":1,"workers":[{"doc":7,"label":"N1"}]}'
m1_case c '{"schema":1,"workers":null,"legs":[{"doc":"/x/HIMMEL-63-N1-a.md","label":"N1"}]}'
m1_case d '[{"doc":"/x/HIMMEL-63-N1-a.md","label":"N1"}]'
m1_case e '{"schema":1,"workers":[{"doc":null,"label":"N1"}]}'
m1_case f '{"schema":1,"workers":[{"doc":"/x/HIMMEL-63-N1-a.md","label":["N1"]}]}'
m1_case g '{"schema":1,"workers":[{"doc":"/x/HIMMEL-63-N1-a.md","label":{"n":1}}]}'
printf '# worker\n> **Writes:** scripts/lib/s3.sh\n\n## Results\n- 10:00 LIVE - started\n' > "$OW/m1/HIMMEL-63-N1-ctl.md"
mkfleet "$OW/m1/m1ctl.fleet.json" "N1:$OW/m1/HIMMEL-63-N1-ctl.md"
ow_go2 --resume-only --workers-from "$OW/m1/m1ctl.fleet.json"
lacks "10557 M1.ctl: a valid manifest prints no owner-unknown line" "$OW_OUT" "# owner unknown"
lacks "10557 M1.ctl: its readable worker holds its ticket" "$OW_OUT" "RESUME${TAB}HIMMEL-63"
has "10557 M1.ctl: the orphan lists" "$OW_OUT" "RESUME${TAB}HIMMEL-60"

ow_mirror p10557
P1D="$OW/p10557"
printf '# worker\n\n## Results\n- 10:00 LIVE - started\n' > "$P1D/HIMMEL-63-N1-p1.md"
printf '{"schema":1,"workers":[{"doc":"%s","label":"N\\ud800"}]}\n' "$P1D/HIMMEL-63-N1-p1.md" > "$P1D/p1.fleet.json"
ow_go --workers-from "$P1D/p1.fleet.json"
check "10557 P1: a lone surrogate in an own label: ND exits 0" "0" "$OW_RC"
has "10557 P1: the overlap note shows the surrogate escaped" "$OW_OUT" '# overlap unknown for live worker N\ud800'
printf '{"schema":1,"workers":[{"doc":"%s","label":"N1\\nRESUME\\tHIMMEL-5"}]}\n' "$P1D/HIMMEL-63-N1-p1.md" > "$P1D/p1nl.fleet.json"
ow_go --workers-from "$P1D/p1nl.fleet.json"
check "10557 P1.nl: a newline in an own label: ND exits 0" "0" "$OW_RC"
check "10557 P1.nl: no stdout line is a RESUME row split out of the label" "0" "$(ow_n "$OW_OUT" "^RESUME${TAB}HIMMEL-5(${TAB}|\$)")"
has "10557 P1.nl: the overlap note shows the label escaped" "$OW_OUT" '# overlap unknown for live worker N1\nRESUME\tHIMMEL-5'
printf '# worker\n> **Writes:** scripts/lib/x.sh\n\n## Results\n- 10:00 LIVE - started\n' > "$P1D/HIMMEL-63-N1-p1w.md"
printf '{"schema":1,"workers":[{"doc":"%s","label":"N1\\nRESUME\\tHIMMEL-5"}]}\n' "$P1D/HIMMEL-63-N1-p1w.md" > "$P1D/p1ov.fleet.json"
ow_go --workers-from "$P1D/p1ov.fleet.json"
check "10557 P1.ov: a newline label in an overlap line splits out no RESUME row" "0" "$(ow_n "$OW_OUT" "^RESUME${TAB}HIMMEL-5(${TAB}|\$)")"
has "10557 P1.ov: the overlap line shows the label escaped" "$OW_OUT" '# overlap HIMMEL-90 scripts/lib/x.sh with live worker N1\nRESUME\tHIMMEL-5'
printf '{"schema":1,"workers":[{"doc":"%s","label":7}]}\n' "$P1D/HIMMEL-63-N1-p1w.md" > "$P1D/p1num.fleet.json"
ow_go --workers-from "$P1D/p1num.fleet.json"
check "10557 P1.num: a numeric label on a scoped worker: ND exits 0" "0" "$OW_RC"
has "10557 P1.num: the overlap line shows the number" "$OW_OUT" "# overlap HIMMEL-90 scripts/lib/x.sh with live worker 7"
OW_LINE_TAIL="withheld: RESUME, IN CI, STACKABLE, SERIES FAMILY, To Do, DESIGN, NEXT-TIER; reconcile: restore the doc, record the worker's end, or fleet-manifest.sh remove"

# U1: an own row whose doc cannot be opened holds the keys in its file name and withholds RESUME, with one line
ow_mirror u1
ow_u1m="$OW_M"
mkfleet "$OW/fleet-u1.json" "N11:$OW/HIMMEL-62-N11-gone.md"   # the doc is never created
ow_u1="$(ow_run --resume-only --workers-from "$OW/fleet-u1.json")"
lacks "9335 U1: an own doc that cannot be opened withholds the orphan HIMMEL-60" "$ow_u1" "RESUME${TAB}HIMMEL-60"
lacks "9335 U1: an own doc that cannot be opened withholds the bundle sibling HIMMEL-63" "$ow_u1" "RESUME${TAB}HIMMEL-63"
lacks "9335 U1: an own doc that cannot be opened withholds the IN CI ticket HIMMEL-65" "$ow_u1" "RESUME${TAB}HIMMEL-65"
has "9335 U1: the line names the worker, the doc, the key it still holds, the withheld lists and the remedy" "$ow_u1" "# owner unknown: live worker N11 (doc HIMMEL-62-N11-gone.md unreadable; keys held: HIMMEL-62); $OW_LINE_TAIL"
check "9335 U1: exactly one owner-unknown line prints" "1" "$(ow_n "$ow_u1" '^# owner unknown:')"
has "9335 U1: the header still says live workers unknown" "$ow_u1" "live workers unknown"
printf '# live\nno scope named here\n' > "$OW/HIMMEL-62-N11-readable.md"
mkfleet "$OW/fleet-u1c.json" "N11:$OW/HIMMEL-62-N11-readable.md"
ow_u1c="$(ow_run --resume-only --workers-from "$OW/fleet-u1c.json")"
has "9335 U1.ctl: the same worker with a readable scope-less doc lists the orphan HIMMEL-60" "$ow_u1c" "RESUME${TAB}HIMMEL-60"
lacks "9335 U1.ctl: a readable doc prints no owner-unknown line" "$ow_u1c" "# owner unknown"
mkfleet "$OW/fleet-u1dup.json" "N11:$OW/HIMMEL-62-N11-gone.md" "N11:$OW/HIMMEL-62-N11-gone.md"
ow_u1d="$(ow_run --resume-only --workers-from "$OW/fleet-u1dup.json")"
check "9335 U1: the same own row twice prints its line once" "1" "$(ow_n "$ow_u1d" '^# owner unknown:')"

# U1.h9c: a label that splits the line cannot forge a row (the label is escaped where the line and the owner map are built)
ow_mirror u1h9c
ow_mk HIMMEL-62 "To Do" High '[]' '["v1.0.1"]' '[]' "To Do whose key an absent doc holds" "Edit scripts/lib/s62.sh only."
mkdir -p "$OW/u1h9c"
printf '%s\n' '{"schema":1,"workers":[{"label":"N9\nLOCAL\tHIMMEL-9","doc":"/x/HIMMEL-62-N9-gone.md"}]}' > "$OW/u1h9c/fleet.json"
ow_go2 --why --workers-from "$OW/u1h9c/fleet.json"
check "9335 U1.h9c: ND exits 0" "0" "$OW_RC"
check "9335 U1.h9c: exactly one owner-unknown line prints" "1" "$(ow_n "$OW_OUT" '^# owner unknown:')"
has "9335 U1.h9c: the line shows the label escaped" "$OW_OUT" "# owner unknown: live worker N9\\nLOCAL\\tHIMMEL-9 (doc ${KP}-62-N9-gone.md unreadable; keys held: ${KP}-62)"
has "9335 U1.h9c: the overlap line shows the label escaped" "$OW_OUT" "# overlap unknown for live worker N9\\nLOCAL\\tHIMMEL-9"
has "9335 U1.h9c: the drop line shows the label escaped" "$OW_OUT" "# drop HIMMEL-62 owned by live worker N9\\nLOCAL\\tHIMMEL-9"
check "9335 U1.h9c: no output line is the forged row for the key HIMMEL-9" "0" "$(ow_forged "$OW_OUT")"
printf '%s\n' '{"schema":1,"workers":[{"label":"N9b","doc":"/x/HIMMEL-62-N9b-a\nLOCAL\tHIMMEL-9-gone.md"}]}' > "$OW/u1h9c/fleet-doc.json"
ow_go2 --why --workers-from "$OW/u1h9c/fleet-doc.json"
has "9335 U1.h9c: a doc name holding a line break is escaped in the line" "$OW_OUT" "(doc ${KP}-62-N9b-a\\nLOCAL\\t${KP}-9-gone.md unreadable; keys held: ${KP}-62,${KP}-9)"
check "9335 U1.h9c: that doc name forges no row for the key HIMMEL-9" "0" "$(ow_forged "$OW_OUT")"

# U4: the IN CI probe is not run while the fleet is unknown (a clean fleet's run asks GitHub for the merged PRs of the IN CI ticket)
OW_M="$ow_u1m"
: > "$GH_ARGS"
ow_run --workers-from "$OW/fleet-u1.json" > /dev/null
check "9335 U4: the unknown fleet runs no merged-PR search" "0" "$(grep -c 'pr list.*merged' "$GH_ARGS" || true)"
ow_doc "$OW/HIMMEL-71-N12-clean.md" "- 10:00 LIVE - started"
mkfleet "$OW/fleet-u4c.json" "N12:$OW/HIMMEL-71-N12-clean.md"
: > "$GH_ARGS"
ow_run --workers-from "$OW/fleet-u4c.json" > /dev/null
check "9335 U4.ctl: a clean fleet's run searches the merged PRs for HIMMEL-65" "1" "$(grep -c 'pr list.*merged' "$GH_ARGS" || true)"

# U7: a typed refusal receipt does not free an unreadable own doc: it is never asked (the oracle shows the receipt WOULD free it if it were)
ow_mirror u7
mkdir -p "$OW/u7x" "$OW/u7y" "$OW/u7emptyhome" "$HOME/.himmel"
ow_u7doc="$OW/u7y/HIMMEL-62-N11-gone.md"
printf '{"family":"F9335","attempts":{}}\n' > "$OW/u7y/fleet-control.json"
printf '{"v":2,"kind":"launch-attempt","attempt_id":"u7-r1","doc":"%s","outcome":"refused","name":"u7-none","ts":"2026-01-01T00:00:00Z"}\n' "$ow_u7doc" > "$HOME/.himmel/launch-refusals.jsonl"
check "9335 U7.oracle: with the receipt the oracle answers wrapped for the absent doc" "wrapped" "$(ow_oracle "$ow_u7doc")"
ow_u7e="$(ow_oracle "$ow_u7doc" "$OW/u7emptyhome")"; [ "$ow_u7e" = wrapped ] || ow_u7e=not-wrapped
check "9335 U7.oracle: with an empty home the oracle does not answer wrapped" "not-wrapped" "$ow_u7e"
mkfleet "$OW/u7x/fleet.json" "N11:$ow_u7doc"
ow_u7="$(ow_run --resume-only --workers-from "$OW/u7x/fleet.json")"
lacks "9335 U7: a refusal receipt does not free an unreadable own doc: HIMMEL-60 is withheld" "$ow_u7" "RESUME${TAB}HIMMEL-60"
has "9335 U7: the line holds the key of the doc's file name" "$ow_u7" "keys held: HIMMEL-62"
check "9335 U7.ctl: the run without the receipt prints the same rows" "$(printf '%s\n' "$ow_u1" | ow_norm)" "$(printf '%s\n' "$ow_u7" | ow_norm)"
rm -f "$HOME/.himmel/launch-refusals.jsonl"

# U11: an attempt in the anchor is not read: only the file name holds a key, whatever phase the attempt is in
for ow_ph in pending committed unknown launched; do
    ow_mirror "u11-$ow_ph"
    ow_d="$OW/u11-$ow_ph"; ow_d11="$ow_d/HIMMEL-62-N11-gone.md"
    printf '{"family":"F9335","attempts":{"u11a":{"attempt_id":"u11a","doc":"%s","name":"N11","phase":"%s","family":"HIMMEL-77","owner":"HIMMEL-77","session":"HIMMEL-77","committer":"HIMMEL-77","reservation":"HIMMEL-77","manifest":"%s/HIMMEL-77.fleet.json","cause":"HIMMEL-77"}}}\n' "$ow_d11" "$ow_ph" "$ow_d" > "$ow_d/fleet-control.json"
    printf '{"schema":1,"workers":[{"doc":"%s","label":"N11"}],"control":{"family":"F9335","anchor":"%s/fleet-control.json"}}\n' "$ow_d11" "$ow_d" > "$ow_d/fleet.json"
    ow_u11="$(ow_run --resume-only --workers-from "$ow_d/fleet.json")"
    lacks "9335 U11: an attempt in phase $ow_ph leaves HIMMEL-60 withheld" "$ow_u11" "RESUME${TAB}HIMMEL-60"
    lacks "9335 U11: an attempt in phase $ow_ph leaves HIMMEL-63 withheld" "$ow_u11" "RESUME${TAB}HIMMEL-63"
    has "9335 U11: an attempt in phase $ow_ph: the line holds only the key of the file name" "$ow_u11" "# owner unknown: live worker N11 (doc HIMMEL-62-N11-gone.md unreadable; keys held: HIMMEL-62); withheld:"
    lacks "9335 U11: an attempt in phase $ow_ph: the key written in the attempt is not read" "$ow_u11" "HIMMEL-77"
done

# U12: the In Progress disposition tail is the base's text, byte for byte, and nothing reads listed RESUME
OW_M="$ow_u1m"
ow_u12="$(ow_run --dispositions --workers-from "$OW/fleet-u1.json")"
has "9335 U12: HIMMEL-60 reads the unowned In Progress tail" "$ow_u12" "# disposition HIMMEL-60 unowned In Progress (no worker, no open PR; not listed: held, blocked, parked or unread)"
has "9335 U12: HIMMEL-63 reads the unowned In Progress tail" "$ow_u12" "# disposition HIMMEL-63 unowned In Progress (no worker, no open PR; not listed: held, blocked, parked or unread)"
lacks "9335 U12: no ticket reads listed RESUME" "$ow_u12" "listed RESUME"

# U13: an own row with no doc is an unreadable doc named (none); a numeric label prints as the number
OW_M="$ow_u1m"
mkdir -p "$OW/u13"
printf '{"schema":1,"workers":[{"label":"N9"}]}\n' > "$OW/u13/fleet.json"
ow_u13="$(ow_run --resume-only --workers-from "$OW/u13/fleet.json")"
has "9335 U13: an own row with no doc prints the line, with no keys held" "$ow_u13" "# owner unknown: live worker N9 (doc (none) unreadable); withheld:"
lacks "9335 U13: an own row with no doc withholds HIMMEL-60" "$ow_u13" "RESUME${TAB}HIMMEL-60"
printf '{"schema":1,"workers":[{"label":7,"doc":"/x/HIMMEL-62-N8-gone.md"}]}\n' > "$OW/u13/fleet-num.json"
ow_go2 --resume-only --workers-from "$OW/u13/fleet-num.json"
check "9335 U13: a numeric label does not raise: ND exits 0" "0" "$OW_RC"
has "9335 U13: a numeric label prints as the number" "$OW_OUT" "# owner unknown: live worker 7 (doc HIMMEL-62-N8-gone.md unreadable; keys held: HIMMEL-62); withheld:"
check "9335 U13.ctl: an own row with a readable doc prints no line (the same as U10)" "0" "$(ow_n "$ow_u1c" '^# owner unknown:')"

# SB2: a sibling row whose doc cannot be opened is reported once per row, by the manifest's stem, with no age rule
ow_mirror sb2
d="$OW/sb2"; mkdir -p "$d"
ow_doc "$d/HIMMEL-71-N14-own.md" "- 10:00 LIVE - started"
mkfleet "$d/HIMMEL-nextleg-2026-11-18B-ow.fleet.json" "N14:$d/HIMMEL-71-N14-own.md"
mkfleet "$d/HIMMEL-nextleg-2026-11-18A-ow.fleet.json" "N15:$d/HIMMEL-72-N15-gone.md"
mkfleet "$d/HIMMEL-nextleg-2026-10-10A-ow.fleet.json" "N16:$d/HIMMEL-73-N16-gone.md"
ago "$d/HIMMEL-nextleg-2026-10-10A-ow.fleet.json" 800
ow_sb2="$(ow_run --resume-only --workers-from "$d/HIMMEL-nextleg-2026-11-18B-ow.fleet.json")"
has "9335 SB2: a sibling row with an absent doc prints its line" "$ow_sb2" "# owner unknown: live worker N15 of the chief on HIMMEL-nextleg-2026-11-18A-ow (doc HIMMEL-72-N15-gone.md unreadable; keys held: HIMMEL-72); withheld:"
has "9335 SB2: an older sibling manifest prints its line too (no age rule)" "$ow_sb2" "# owner unknown: live worker N16 of the chief on HIMMEL-nextleg-2026-10-10A-ow (doc HIMMEL-73-N16-gone.md unreadable; keys held: HIMMEL-73); withheld:"
lacks "9335 SB2: the sibling unknown withholds HIMMEL-60" "$ow_sb2" "RESUME${TAB}HIMMEL-60"
rm -f "$d/HIMMEL-nextleg-2026-10-10A-ow.fleet.json"
ow_sb2b="$(ow_run --resume-only --workers-from "$d/HIMMEL-nextleg-2026-11-18B-ow.fleet.json")"
lacks "9335 SB2: with the older manifest gone its line is gone" "$ow_sb2b" "HIMMEL-nextleg-2026-10-10A-ow"
has "9335 SB2: with the older manifest gone the other line stays" "$ow_sb2b" "# owner unknown: live worker N15 of the chief on HIMMEL-nextleg-2026-11-18A-ow"
ow_doc "$d/HIMMEL-72-N15-gone.md" "- 10:00 LIVE - started"
ow_sb2c="$(ow_run --resume-only --workers-from "$d/HIMMEL-nextleg-2026-11-18B-ow.fleet.json")"
lacks "9335 SB2.ctl: with the sibling doc readable the sibling prints no line" "$ow_sb2c" "# owner unknown"
has "9335 SB2.ctl: with the sibling doc readable the orphan lists" "$ow_sb2c" "RESUME${TAB}HIMMEL-60"

# SB2.wr: a sibling row whose unreadable doc a receipt wrapped contributes nothing and prints no line (F3)
ow_mirror sb2wr
ow_mk HIMMEL-62 "In Progress" High '[]' '["v1.0.1"]' '[]' "owned only by a wrapped sibling doc" "Edit scripts/lib/s62.sh only."
d="$OW/sb2wr"; mkdir -p "$d/x" "$d/y"
ow_swdoc="$d/y/HIMMEL-62-N16-gone.md"
printf '{"family":"F9335","attempts":{}}\n' > "$d/y/fleet-control.json"
printf '{"v":2,"kind":"launch-attempt","attempt_id":"sw-r1","doc":"%s","outcome":"refused","name":"sw-none","ts":"2026-01-01T00:00:00Z"}\n' "$ow_swdoc" > "$HOME/.himmel/launch-refusals.jsonl"
check "9335 SB2.wr: the oracle answers wrapped for the sibling's absent doc" "wrapped" "$(ow_oracle "$ow_swdoc")"
ow_doc "$d/x/HIMMEL-71-N14-own.md" "- 10:00 LIVE - started"
mkfleet "$d/x/HIMMEL-nextleg-2026-11-18B-ow.fleet.json" "N14:$d/x/HIMMEL-71-N14-own.md"
mkfleet "$d/x/HIMMEL-nextleg-2026-11-17A-ow.fleet.json" "N16:$ow_swdoc"
ow_sbw="$(ow_run --resume-only --workers-from "$d/x/HIMMEL-nextleg-2026-11-18B-ow.fleet.json")"
lacks "9335 SB2.wr: a wrapped sibling doc prints no owner-unknown line" "$ow_sbw" "# owner unknown"
has "9335 SB2.wr: a wrapped sibling doc frees its ticket" "$ow_sbw" "RESUME${TAB}HIMMEL-62"
rm -f "$HOME/.himmel/launch-refusals.jsonl"

# SB2.h9 and its two companions: a sibling doc path Python cannot open or print is N1 for that doc, never a traceback or a malformed manifest
ow_mirror sb2h9
ow_sibdir() { # <name> <sibling manifest json text>: a readable own manifest (18B) and the given sibling (18A) in one directory
    local sd="$OW/$1"; mkdir -p "$sd"
    ow_doc "$sd/HIMMEL-71-N14-own.md" "- 10:00 LIVE - started"
    mkfleet "$sd/HIMMEL-nextleg-2026-11-18B-ow.fleet.json" "N14:$sd/HIMMEL-71-N14-own.md"
    printf '%s\n' "$2" > "$sd/HIMMEL-nextleg-2026-11-18A-ow.fleet.json"
    OW_OWN="$sd/HIMMEL-nextleg-2026-11-18B-ow.fleet.json"
}
ow_sibdir sb2h9 '{"schema":1,"workers":[{"doc":"/x/HIMMEL-62-N16-\u0000.md","label":"N16"}]}'
ow_go2 --resume-only --workers-from "$OW_OWN"
check "9335 SB2.h9: a NUL in a sibling doc path: ND exits 0" "0" "$OW_RC"
lacks "9335 SB2.h9: a NUL in a sibling doc path: no traceback" "$OW_OUT" "Traceback"
has "9335 SB2.h9: a NUL in a sibling doc path is N1, the NUL shown as \\x00" "$OW_OUT" "# owner unknown: live worker N16 of the chief on HIMMEL-nextleg-2026-11-18A-ow (doc HIMMEL-62-N16-\\x00.md unreadable; keys held: HIMMEL-62); withheld: RESUME"
lacks "9335 SB2.h9: a NUL in a sibling doc path is not a malformed manifest" "$OW_OUT" "malformed"
ow_sibdir sb2h9p '{"schema":1,"workers":[{"doc":"/x/HIMMEL-62-N16-gone.md","label":"N16"}]}'
ow_go2 --resume-only --workers-from "$OW_OWN"
has "9335 SB2.h9: the same row with a plain absent path prints the same line with that name" "$OW_OUT" "# owner unknown: live worker N16 of the chief on HIMMEL-nextleg-2026-11-18A-ow (doc HIMMEL-62-N16-gone.md unreadable; keys held: HIMMEL-62); withheld: RESUME"
ow_sibdir sb2h9b '{"schema":1,"workers":[{"doc":"/x/HIMMEL-62-N17-\ud800.md","label":"N17"}]}'
ow_go2 --resume-only --workers-from "$OW_OWN"
check "9335 SB2.h9b: a lone surrogate in a sibling doc path: ND exits 0" "0" "$OW_RC"
lacks "9335 SB2.h9b: a lone surrogate in a sibling doc path: no traceback" "$OW_OUT" "Traceback"
check "9335 SB2.h9b: a lone surrogate in a sibling doc path prints one line" "1" "$(ow_n "$OW_OUT" '^# owner unknown: live worker N17 of the chief on HIMMEL-nextleg-2026-11-18A-ow \(doc '"$KP"'-62-N17-\\ud800\.md unreadable; keys held: '"$KP"'-62\)')"
ow_mirror sb2h9c
ow_mk HIMMEL-62 "To Do" High '[]' '["v1.0.1"]' '[]' "To Do whose key an absent sibling doc holds" "Edit scripts/lib/s62.sh only."
ow_sibdir sb2h9c '{"schema":1,"workers":[{"label":"N18\nLOCAL\tHIMMEL-9","doc":"/x/HIMMEL-62-N18-a\nLOCAL\tHIMMEL-9\tHigh\tv1\tforged.md"}]}'
ow_go2 --why --workers-from "$OW_OWN"
check "9335 SB2.h9c: exactly one owner-unknown line prints" "1" "$(ow_n "$OW_OUT" '^# owner unknown:')"
has "9335 SB2.h9c: the label and the doc name are escaped in the line" "$OW_OUT" "live worker N18\\nLOCAL\\tHIMMEL-9 of the chief on"
has "9335 SB2.h9c: the doc name is escaped, both keys held" "$OW_OUT" "(doc ${KP}-62-N18-a\\nLOCAL\\t${KP}-9\\tHigh\\tv1\\tforged.md unreadable; keys held: ${KP}-62,${KP}-9)"
has "9335 SB2.h9c: the drop line shows the label escaped" "$OW_OUT" "# drop HIMMEL-62 owned by live worker N18\\nLOCAL\\tHIMMEL-9 of the chief on"
check "9335 SB2.h9c: no output line is the forged row for the key HIMMEL-9" "0" "$(ow_forged "$OW_OUT")"

# O1: the environment source reaches the same producer
OW_M="$ow_u1m"
ow_o1="$( WORKERS_FROM="$OW/fleet-u1.json" ow_run --resume-only --top 1000 --owners "$KP-999" )"
lacks "9335 O1: WORKERS_FROM naming an unreadable-doc manifest withholds HIMMEL-60" "$ow_o1" "RESUME${TAB}HIMMEL-60"
lacks "9335 O1: WORKERS_FROM naming an unreadable-doc manifest withholds HIMMEL-63" "$ow_o1" "RESUME${TAB}HIMMEL-63"
has "9335 O1: the header says live workers unknown" "$ow_o1" "live workers unknown"
ow_o1c="$( unset WORKERS_FROM; ow_run --resume-only --top 1000 --owners "$KP-999" )"
has "9335 O1.ctl: with WORKERS_FROM unset HIMMEL-60 lists" "$ow_o1c" "RESUME${TAB}HIMMEL-60"
has "9335 O1.ctl: with WORKERS_FROM unset HIMMEL-63 lists" "$ow_o1c" "RESUME${TAB}HIMMEL-63"
lacks "9335 O1.ctl: with WORKERS_FROM unset the header does not say live workers unknown" "$ow_o1c" "live workers unknown"

# X3: a run writes nothing: the fixture tree, HOME, the handover root and the status state directory hash the same before and after
OW_M="$ow_u1m"
ow_x3a="$(ow_tree_sum)"
ow_run --workers-from "$OW/fleet-u1.json" > /dev/null
ow_x3b="$(ow_tree_sum)"
check "9335 X3: a run over an unreadable-doc fleet writes nothing" "$ow_x3a" "$ow_x3b"

# X4: the lists and the lines do not depend on the order of rows or on which sibling file holds which row
ow_x4_build() { # <dir> <own rows reversed 0|1> <sibling contents swapped 0|1>
    local xd="$1"; mkdir -p "$xd"
    ow_doc "$xd/HIMMEL-73-N12-live.md" "- 10:00 LIVE - started"
    if [ "$2" = 1 ]; then
        mkfleet "$xd/HIMMEL-nextleg-2026-11-18B-ow.fleet.json" "N12:$xd/HIMMEL-73-N12-live.md" "N11:$xd/HIMMEL-62-N11-gone.md"
    else
        mkfleet "$xd/HIMMEL-nextleg-2026-11-18B-ow.fleet.json" "N11:$xd/HIMMEL-62-N11-gone.md" "N12:$xd/HIMMEL-73-N12-live.md"
    fi
    if [ "$3" = 1 ]; then
        mkfleet "$xd/HIMMEL-nextleg-2026-11-17A-ow.fleet.json" "N16:$xd/HIMMEL-72-N16-sib.md"
        mkfleet "$xd/HIMMEL-nextleg-2026-11-16A-ow.fleet.json" "N15:$xd/HIMMEL-71-N15-sib.md"
    else
        mkfleet "$xd/HIMMEL-nextleg-2026-11-17A-ow.fleet.json" "N15:$xd/HIMMEL-71-N15-sib.md"
        mkfleet "$xd/HIMMEL-nextleg-2026-11-16A-ow.fleet.json" "N16:$xd/HIMMEL-72-N16-sib.md"
    fi
}
ow_mirror x4
ow_x4_ref_rows=""; ow_x4_ref_lines=""; ow_x4_i=0
for ow_x4_arr in "0 0" "1 0" "0 1" "1 1"; do
    ow_x4_i=$((ow_x4_i + 1))
    # shellcheck disable=SC2086  # the two arrangement flags are words
    ow_x4_build "$OW/x4-$ow_x4_i" $ow_x4_arr
    ow_x4_out="$(ow_run --why --dispositions --top 20 --workers-from "$OW/x4-$ow_x4_i/HIMMEL-nextleg-2026-11-18B-ow.fleet.json")"
    ow_x4_rows="$(printf '%s\n' "$ow_x4_out" | grep -v '^# owner unknown:' | ow_norm | LC_ALL=C sort)"
    ow_x4_lines="$(printf '%s\n' "$ow_x4_out" | grep '^# owner unknown:' | ow_norm | LC_ALL=C sort)"
    if [ "$ow_x4_i" = 1 ]; then ow_x4_ref_rows="$ow_x4_rows"; ow_x4_ref_lines="$ow_x4_lines"; fi
    check "9335 X4.rows: arrangement $ow_x4_i lists the same rows as the original" "$ow_x4_ref_rows" "$ow_x4_rows"
    check "9335 X4.lines: arrangement $ow_x4_i prints the same lines as the original, as a sorted set" "$ow_x4_ref_lines" "$ow_x4_lines"
    check "9335 X4.once: arrangement $ow_x4_i prints exactly 3 owner-unknown lines" "3" "$(ow_n "$ow_x4_out" '^# owner unknown:')"
    check "9335 X4.once: arrangement $ow_x4_i prints no owner-unknown line twice" "0" "$(printf '%s\n' "$ow_x4_out" | grep '^# owner unknown:' | LC_ALL=C sort | uniq -d | grep -c . || true)"
done


# --- 9335 the To Do, DESIGN, SERIES and NEXT-TIER withhold: nothing a named unknown may own is listed ---
ow_kindrows() { printf '%s\n' "$1" | grep -cE "^$2${TAB}.*${KP}-(90|91)([^0-9]|\$)" || true; }  # <text> <row kind regex>: rows of that kind naming the free To Do ticket or the core ticket
ow_u3() { CG="$OW/u3cg" NEXT_DISPATCH_JIRA_CLI="$WORK/cg-stub/index.js" ow_run "$@"; }  # ND with the core stand-in: the core ticket has no signed spec

# U3: while the fleet is unknown no To Do or DESIGN row lists; the dispositions say why
ow_mirror u3
ow_mk HIMMEL-91 "To Do" High '["core"]' '["v1.0.1"]' '[]' "core ticket without a signed spec" "Edit scripts/lib/c91.sh only."
mkdir -p "$OW/u3cg/core" "$OW/u3cg/spec"
printf 'CORE HIMMEL-91 label core\n' > "$OW/u3cg/core/HIMMEL-91"
printf 'NO-SPEC HIMMEL-91\n' > "$OW/u3cg/spec/HIMMEL-91"
ow_u3m="$OW_M"
ow_u3out="$(ow_u3 --top 20 --dispositions --workers-from "$OW/fleet-u1.json")"
for ow_kind in 'LOCAL' 'LOCAL\?' 'CLOUD' 'DESIGN' 'SERIES'; do
    check "9335 U3: no $ow_kind row names HIMMEL-90 or HIMMEL-91 while the fleet is unknown" "0" "$(ow_kindrows "$ow_u3out" "$ow_kind")"
done
has "9335 U3: the header counts 0 collision-free" "$ow_u3out" "0 collision-free"
has "9335 U3: the dropped line counts the owner group" "$ow_u3out" "owner 2"
has "9335 U3: the disposition of HIMMEL-90 says owner unknown" "$ow_u3out" "# disposition HIMMEL-90 owner unknown"
ow_u3c="$(ow_u3 --top 20 --dispositions --workers-from "$OW/fleet-u4c.json")"
has "9335 U3.ctl: a clean fleet lists HIMMEL-90" "$ow_u3c" "LOCAL${TAB}HIMMEL-90${TAB}"
has "9335 U3.ctl: a clean fleet lists HIMMEL-91 as a DESIGN row" "$ow_u3c" "DESIGN${TAB}HIMMEL-91${TAB}NO-SPEC"

# U1.d, U13.d, SB2.d: the default listing withholds the To Do row for each N1 case
OW_M="$ow_u1m"
ow_u1d="$(ow_run --why --workers-from "$OW/fleet-u1.json")"
lacks "9335 U1.d: an unreadable own doc withholds the To Do row HIMMEL-90" "$ow_u1d" "HIMMEL-90${TAB}"
has "9335 U1.d: the drop reason is owner unknown" "$ow_u1d" "# drop HIMMEL-90 owner unknown"
ow_u13d="$(ow_run --why --workers-from "$OW/u13/fleet.json")"
lacks "9335 U13.d: an own row with no doc withholds the To Do row HIMMEL-90" "$ow_u13d" "HIMMEL-90${TAB}"
has "9335 U13.d: the drop reason is owner unknown" "$ow_u13d" "# drop HIMMEL-90 owner unknown"
ow_mirror sb2d
d="$OW/sb2d"; mkdir -p "$d"
ow_doc "$d/HIMMEL-71-N14-own.md" "- 10:00 LIVE - started"
mkfleet "$d/HIMMEL-nextleg-2026-11-18B-ow.fleet.json" "N14:$d/HIMMEL-71-N14-own.md"
mkfleet "$d/HIMMEL-nextleg-2026-11-18A-ow.fleet.json" "N15:$d/HIMMEL-72-N15-gone.md"
mkfleet "$d/HIMMEL-nextleg-2026-10-10A-ow.fleet.json" "N16:$d/HIMMEL-73-N16-gone.md"
ow_sb2d="$(ow_run --why --workers-from "$d/HIMMEL-nextleg-2026-11-18B-ow.fleet.json")"
lacks "9335 SB2.d: unreadable sibling docs withhold the To Do row HIMMEL-90" "$ow_sb2d" "HIMMEL-90${TAB}"
has "9335 SB2.d: the drop reason is owner unknown" "$ow_sb2d" "# drop HIMMEL-90 owner unknown"

# U3.h3a to U3.h3d: an existing reason still wins over owner unknown
OW_M="$ow_u1m"
ow_mk HIMMEL-92 "To Do" High '[]' '["v1.0.1"]' '[]' "To Do whose body names no file" "Nothing in this body names a file."
ow_h3a="$(ow_run --why --workers-from "$OW/fleet-u1.json")"
has "9335 U3.h3a: a ticket with no scope keeps the no-scope reason" "$ow_h3a" "# drop HIMMEL-92 no-scope"
lacks "9335 U3.h3a: a ticket with no scope is not dropped as owner unknown" "$ow_h3a" "# drop HIMMEL-92 owner unknown"
ow_mk HIMMEL-62 "To Do" High '[]' '["v1.0.1"]' '[]' "To Do whose key an absent doc holds" "Edit scripts/lib/s62.sh only."
ow_h3b="$(ow_run --why --workers-from "$OW/fleet-u1.json")"
has "9335 U3.h3b: a key held by the doc's file name keeps its owned reason" "$ow_h3b" "# drop HIMMEL-62 owned by live worker N11"
OW_M="$ow_u3m"
: > "$GH_FAIL"
ow_h3c="$(ow_u3 --why --workers-from "$OW/fleet-u1.json")"
rm -f "$GH_FAIL"
OW_M="$ow_u1m"
has "9335 U3.h3c: with gh failing HIMMEL-90 keeps the open-PRs-unknown reason" "$ow_h3c" "# drop HIMMEL-90 open PRs unknown"
lacks "9335 U3.h3c: with gh failing HIMMEL-90 is not dropped as owner unknown" "$ow_h3c" "# drop HIMMEL-90 owner unknown"
has "9335 U3.h3c2: with gh failing the DESIGN ticket HIMMEL-91 keeps the open-PRs-unknown reason" "$ow_h3c" "# drop HIMMEL-91 open PRs unknown"
lacks "9335 U3.h3c2: with gh failing the DESIGN ticket HIMMEL-91 is not dropped as owner unknown" "$ow_h3c" "# drop HIMMEL-91 owner unknown"
mkdir -p "$OW/h3d/bucket"; printf '# chief\n\n## Live state\n\n- priority: \n' > "$OW/h3d/bucket/chief.md"
ow_mk HIMMEL-93 "To Do" High '[]' '["v1.0.1"]' '[]' "To Do with an owed next step" "Edit scripts/lib/s93.sh only."
ow_h3d_pv="$(bash "$HERE/owe.sh" add --chief fixture --kind proof --key "$KP-93" --text validate --metadata '{"actor":"chief","action":"validate-proof"}' --bucket "$OW/h3d/bucket")"
bash "$HERE/owe.sh" add --chief fixture --kind step --key "$KP-93" --text "Fix scripts/lib/next.sh" --bucket "$OW/h3d/bucket" \
    --metadata "{\"actor\":\"chief\",\"action\":\"next-step\",\"source_id\":\"$ow_h3d_pv\",\"due\":\"2026-11-30\",\"wake\":\"fixture\",\"capability\":\"fixture\"}" > /dev/null
bash "$HERE/owe.sh" close --id "$ow_h3d_pv" --key KEEP --bucket "$OW/h3d/bucket" > /dev/null
ow_h3d="$(ow_run --why --doc "$OW/h3d/bucket/chief.md" --workers-from "$OW/fleet-u1.json")"
has "9335 U3.h3d: a ticket with an owed next step keeps the owed reason" "$ow_h3d" "# drop HIMMEL-93 owned next step:"
lacks "9335 U3.h3d: a ticket with an owed next step is not dropped as owner unknown" "$ow_h3d" "# drop HIMMEL-93 owner unknown"

# U5: no STACKABLE row, no SERIES FAMILY row and no plain row for a candidate a live series worker could hold, while another worker's doc is unreadable
ow_m_save="$M"
newmir ows
APP='Edit scripts/config-ui/app.js please.'
mk HIMMEL-851 "To Do" High '[]' '["v1.0.1"]' '[]' "wants app.js" "$APP"
mk HIMMEL-853 "To Do" High '[]' '["v1.0.1"]' '[]' "free ticket" "Edit scripts/lib/free-s.sh."
ow_ows="$M"; M="$ow_m_save"
mkdoc "$OW/HIMMEL-790-N5-series.md" 2 ""
mkfleet "$OW/fleet-u5.json" "N5:$OW/HIMMEL-790-N5-series.md" "N11:$OW/HIMMEL-62-N11-gone.md"
mkfleet "$OW/fleet-u5c.json" "N5:$OW/HIMMEL-790-N5-series.md"
ow_u5="$(runs "$ow_ows" 1 --workers-from "$OW/fleet-u5.json" --why)"
check "9335 U5: no STACKABLE row while a worker doc is unreadable" "0" "$(ow_n "$ow_u5" '^STACKABLE ')"
check "9335 U5: no SERIES FAMILY row while a worker doc is unreadable" "0" "$(ow_n "$ow_u5" '^SERIES FAMILY ')"
lacks "9335 U5: the candidate is not listed plain either" "$ow_u5" "LOCAL${TAB}HIMMEL-851${TAB}"
ow_u5c="$(runs "$ow_ows" 1 --workers-from "$OW/fleet-u5c.json" --why)"
has "9335 U5.ctl: with the series worker alone the candidate is STACKABLE" "$ow_u5c" "STACKABLE HIMMEL-851"
[ "$(ow_n "$ow_u5c" '^STACKABLE ')" -ge 1 ] && pass "9335 U5.ctl: the STACKABLE row form is a line that starts with STACKABLE" || fail "9335 U5.ctl: no line starts with STACKABLE in the control run"
[ "$(ow_n "$sf1" '^SERIES FAMILY ')" -ge 1 ] && pass "9335 U5.ctl: the SERIES FAMILY row form is a line that starts with SERIES FAMILY" || fail "9335 U5.ctl: no line starts with SERIES FAMILY in the family run"

# U6: the next-tier rows are withheld with the pool, POOL-EMPTY still prints
OW_M="$OW/x6b/HIMMEL"
ow_u6="$(ow_run --priority-pool-only --workers-from "$OW/fleet-u1.json")"
has "9335 U6: an unknown fleet still prints POOL-EMPTY" "$ow_u6" "POOL-EMPTY"
check "9335 U6: an unknown fleet prints no NEXT-TIER row" "0" "$(ow_n "$ow_u6" "^NEXT-TIER${TAB}")"
ow_u6c="$(ow_run --priority-pool-only --workers-from "$OW/u10/fleet-w.json")"
has "9335 U6.ctl: a fleet whose doc ends WRAPPED prints the NEXT-TIER row" "$ow_u6c" "NEXT-TIER${TAB}HIMMEL-160"
[ "$(ow_n "$ow_u6c" "^NEXT-TIER${TAB}")" -ge 1 ] && pass "9335 U6.ctl: the NEXT-TIER row form is a line that starts with NEXT-TIER and a tab" || fail "9335 U6.ctl: no line starts with NEXT-TIER and a tab in the control run"


# --- 9335 E1 and E2: a named worker manifest that is missing or cannot be read is an owner unknown ---
OW_FLEET_TAIL="withheld: RESUME, IN CI, STACKABLE, SERIES FAMILY, To Do, DESIGN, NEXT-TIER; reconcile: restore or pass a readable --workers-from manifest"

# X1: a missing --workers-from manifest withholds the whole listing and says so
ow_mirror x1
ow_x1="$(ow_run --why --workers-from "$OW/no-such-fleet.json")"
has "9335 X1: the line names the missing manifest, the withheld lists and the remedy" "$ow_x1" "# owner unknown: the fleet (manifest no-such-fleet.json missing); $OW_FLEET_TAIL"
lacks "9335 X1: a missing manifest withholds the To Do row HIMMEL-90" "$ow_x1" "HIMMEL-90${TAB}"
has "9335 X1: the drop reason is owner unknown" "$ow_x1" "# drop HIMMEL-90 owner unknown"
ow_x1c="$(ow_run --why --workers-from "$OW/fleet-u4c.json")"
has "9335 X1.ctl: with the manifest present HIMMEL-90 lists" "$ow_x1c" "LOCAL${TAB}HIMMEL-90${TAB}"

# X5.i, X5.ii: an own manifest that cannot be read, or whose anchor the runtime refuses, is the same unknown
mkdir -p "$OW/x5i" "$OW/x5ii"
printf 'not json\n' > "$OW/x5i/fleet.json"
ow_x5i="$(ow_run --why --workers-from "$OW/x5i/fleet.json")"
has "9335 X5.i: a manifest that is not JSON prints the unreadable line" "$ow_x5i" "# owner unknown: the fleet (manifest fleet.json unreadable); $OW_FLEET_TAIL"
lacks "9335 X5.i: a manifest that is not JSON withholds the To Do row HIMMEL-90" "$ow_x5i" "HIMMEL-90${TAB}"
ow_doc "$OW/x5ii/HIMMEL-71-N14-own.md" "- 10:00 LIVE - started"
mkfleet "$OW/x5ii/fleet.json" "N14:$OW/x5ii/HIMMEL-71-N14-own.md"
printf '{"family":"F9335","attempts":{}}\n' > "$OW/x5ii/real-control.json"
ln -s "$OW/x5ii/real-control.json" "$OW/x5ii/fleet-control.json"
ow_x5ii="$(ow_run --why --workers-from "$OW/x5ii/fleet.json")"
has "9335 X5.ii: an anchor that is a symlink prints the unreadable line" "$ow_x5ii" "# owner unknown: the fleet (manifest fleet.json unreadable); $OW_FLEET_TAIL"
lacks "9335 X5.ii: an anchor that is a symlink withholds the To Do row HIMMEL-90" "$ow_x5ii" "HIMMEL-90${TAB}"
mkdir -p "$OW/x5c"
ow_doc "$OW/x5c/HIMMEL-71-N14-own.md" "- 10:00 LIVE - started"
mkfleet "$OW/x5c/fleet.json" "N14:$OW/x5c/HIMMEL-71-N14-own.md"
ow_x5c="$(ow_run --why --workers-from "$OW/x5c/fleet.json")"
has "9335 X5.ctl: a readable manifest lists HIMMEL-90" "$ow_x5c" "LOCAL${TAB}HIMMEL-90${TAB}"
lacks "9335 X5.ctl: a readable manifest prints no owner-unknown line" "$ow_x5c" "# owner unknown"

# X5.h9: an own row whose doc path holds a NUL is E2 (the manifest's read raises ValueError), never a traceback
mkdir -p "$OW/x5h9"
printf '%s\n' '{"schema":1,"workers":[{"doc":"/x/HIMMEL-62-N9-\u0000.md","label":"N9"}]}' > "$OW/x5h9/fleet.json"
ow_go2 --why --workers-from "$OW/x5h9/fleet.json"
check "9335 X5.h9: a NUL in an own doc path: ND exits 0" "0" "$OW_RC"
lacks "9335 X5.h9: a NUL in an own doc path: no traceback" "$OW_OUT" "Traceback"
has "9335 X5.h9: a NUL in an own doc path prints the unreadable line for the manifest" "$OW_OUT" "# owner unknown: the fleet (manifest fleet.json unreadable); withheld:"
lacks "9335 X5.h9: a NUL in an own doc path withholds the To Do row HIMMEL-90" "$OW_OUT" "HIMMEL-90${TAB}"

# X1.h9c: a missing manifest whose name holds a line break and a row look-alike cannot forge a row
OW_X1H9="$OW/no-such"$'\n'"LOCAL${TAB}HIMMEL-9"$'\n'"x.json"
ow_go2 --why --workers-from "$OW_X1H9"
check "9335 X1.h9c: exactly one owner-unknown line prints" "1" "$(ow_n "$OW_OUT" '^# owner unknown:')"
has "9335 X1.h9c: the manifest name is escaped in the line" "$OW_OUT" "(manifest no-such\\nLOCAL\\t${KP}-9\\nx.json missing)"
check "9335 X1.h9c: no output line is the forged row for the key HIMMEL-9" "0" "$(ow_forged "$OW_OUT")"


# --- 9335 N2: a sibling manifest that cannot be read, or whose shape the guard refuses, is an owner unknown ---
ow_sbdir() { # <name>: a directory with a readable own manifest (18B) and the sibling path (17A) unset: sets OW_SD, OW_OWN, OW_SIB
    OW_SD="$OW/$1"; mkdir -p "$OW_SD"
    ow_doc "$OW_SD/HIMMEL-71-N14-own.md" "- 10:00 LIVE - started"
    mkfleet "$OW_SD/HIMMEL-nextleg-2026-11-18B-ow.fleet.json" "N14:$OW_SD/HIMMEL-71-N14-own.md"
    OW_OWN="$OW_SD/HIMMEL-nextleg-2026-11-18B-ow.fleet.json"
    OW_SIB="$OW_SD/HIMMEL-nextleg-2026-11-17A-ow.fleet.json"
}
ow_anchor() { printf '{"family":"F9335","attempts":{}}\n' > "$OW_SD/fleet-control.json"; }  # a valid hand-written anchor beside the manifests
ow_sbn2() { # <id> <unreadable|malformed>: one N2 line for the sibling and both lists withheld
    ow_go2 --why --workers-from "$OW_OWN"
    check "9335 $1: ND exits 0" "0" "$OW_RC"
    check "9335 $1: one owner-unknown line names the sibling manifest as $2" "1" "$(ow_n "$OW_OUT" "^# owner unknown: the chief on HIMMEL-nextleg-2026-11-17A-ow \(manifest HIMMEL-nextleg-2026-11-17A-ow\.fleet\.json $2\); withheld: ")"
    lacks "9335 $1: the orphan HIMMEL-60 is withheld" "$OW_OUT" "RESUME${TAB}HIMMEL-60"
    lacks "9335 $1: the To Do row HIMMEL-90 is withheld" "$OW_OUT" "HIMMEL-90${TAB}"
}
ow_sbnone() { # <id>: no line for the sibling and the orphan and the To Do row list
    ow_go2 --why --workers-from "$OW_OWN"
    lacks "9335 $1: no owner-unknown line" "$OW_OUT" "# owner unknown"
    has "9335 $1: the orphan HIMMEL-60 lists" "$OW_OUT" "RESUME${TAB}HIMMEL-60"
    has "9335 $1: the To Do row HIMMEL-90 lists" "$OW_OUT" "LOCAL${TAB}HIMMEL-90${TAB}"
}
ow_mirror sb5

# SB1: a sibling that cannot be read as JSON
ow_sbdir sb1a; printf 'not json\n' > "$OW_SIB"; ow_sbn2 SB1.a unreadable
ow_sbdir sb1b; mkdir "$OW_SIB"; ow_sbn2 SB1.b unreadable
ow_sbdir sb1c; printf '{"schema":1,"workers":[]}\n' > "$OW_SD/real-sibling.json"; ln -s "$OW_SD/real-sibling.json" "$OW_SIB"; ow_sbn2 SB1.c malformed
ow_sbdir sb1d; printf '%100000s' '' | tr ' ' '[' > "$OW_SIB"; ow_sbn2 SB1.d unreadable
ow_sbdir sb1x; printf 'not json\n' > "$OW_SD/HIMMEL-nextleg-2026-11-17A-other.fleet.json"; ow_sbnone SB1.ctl

# SB4: the top level or the workers value is not what a manifest holds; each with the anchor absent and present
for ow_anc in absent present; do
    ow_sbdir "sb4a-$ow_anc"; [ "$ow_anc" = absent ] || ow_anchor; printf '[]\n' > "$OW_SIB"; ow_sbn2 SB4.a malformed
    ow_sbdir "sb4b-$ow_anc"; [ "$ow_anc" = absent ] || ow_anchor
    for ow_top in '"a string"' '7' 'null'; do
        printf '%s\n' "$ow_top" > "$OW_SIB"; ow_sbn2 SB4.b malformed
    done
    ow_sbdir "sb4c-$ow_anc"; [ "$ow_anc" = absent ] || ow_anchor; printf '{"schema":1,"workers":{"doc":"x"}}\n' > "$OW_SIB"; ow_sbn2 SB4.c malformed
done
ow_sbdir sb4x; printf '%s\n' '{"schema":1,"workers":[1,"x",null,{"doc":null},{"doc":7},{"label":"z"}]}' > "$OW_SIB"; ow_sbnone SB4.ctl

# SB5: the runtime's reader raises on the sibling. (a) and (b) run with the anchor beside the manifests; only (a) needs the own manifest missing
ow_sbdir sb5a; printf '{"attempts":{}}\n' > "$OW_SD/fleet-control.json"
mkfleet "$OW_SIB" "N15:$OW_SD/HIMMEL-72-N15-sib.md"; rm -f "$OW_OWN"
ow_go2 --why --workers-from "$OW_OWN"
check "9335 SB5.a: an anchor with no family, own manifest missing: ND exits 0" "0" "$OW_RC"
check "9335 SB5.a: one owner-unknown line names the sibling manifest as malformed" "1" "$(ow_n "$OW_OUT" "^# owner unknown: the chief on HIMMEL-nextleg-2026-11-17A-ow \(manifest HIMMEL-nextleg-2026-11-17A-ow\.fleet\.json malformed\); withheld: ")"
check "9335 SB5.a: the missing own manifest prints its own line beside it" "1" "$(ow_n "$OW_OUT" '^# owner unknown: the fleet \(manifest HIMMEL-nextleg-2026-11-18B-ow\.fleet\.json missing\)')"
ow_sbdir sb5b
printf '{"family":"F9335","attempts":{"a1":{"attempt_id":"a1","doc":"%s/HIMMEL-72-N15-sib.md","name":"N15","phase":"launched"}}}\n' "$OW_SD" > "$OW_SD/fleet-control.json"
printf '{"schema":1,"workers":[{"label":"nodoc"}],"control":{"family":"F9335","anchor":"%s/fleet-control.json"}}\n' "$OW_SD" > "$OW_SIB"
ow_sbn2 SB5.b malformed
ow_sbdir sb5c1
printf '{"family":"F9335","attempts":{"a1":{"attempt_id":"a1","doc":"%s/HIMMEL-72-N15-sib.md","name":"N15","phase":"launched"}}}\n' "$OW_SD" > "$OW_SD/fleet-control.json"
printf '{"schema":1,"workers":[1],"control":{"family":"F9335","anchor":"%s/fleet-control.json"}}\n' "$OW_SD" > "$OW_SIB"
ow_sbn2 SB5.c1 malformed
ow_sbdir sb5c2
printf '{"family":"F9335","attempts":{}}\n' > "$OW_SD/fleet-control.json"
printf '{"schema":1,"workers":[1],"control":{"family":"F9335","anchor":"%s/fleet-control.json"}}\n' "$OW_SD" > "$OW_SIB"
ow_sbn2 SB5.c2 malformed
ow_sbdir sb5d
printf '{"family":"F9335","attempts":{}}\n' > "$OW_SD/fleet-control.json"
printf '{"schema":1,"workers":[{"label":"nodoc"}],"control":{"family":"OTHER","anchor":"%s/fleet-control.json"}}\n' "$OW_SD" > "$OW_SIB"
ow_sbnone SB5.d
ow_sbdir sb5dd; printf '{"attempts":{}}\n' > "$OW_SD/fleet-control.json"
ow_go2 --workers-from "$OW_OWN"
check "9335 SB5.d: an anchor with no family and a readable own manifest exits 0" "0" "$OW_RC"
check "9335 SB5.d: one owner-unknown line names the own manifest as malformed" "1" "$(ow_n "$OW_OUT" "^# owner unknown: .*\(manifest HIMMEL-nextleg-2026-11-18B-ow\.fleet\.json malformed\)")"

# SB6, SB7: workers is null
for ow_anc in absent present; do
    ow_sbdir "sb6-$ow_anc"; [ "$ow_anc" = absent ] || ow_anchor; printf '{"schema":1,"workers":null}\n' > "$OW_SIB"; ow_sbn2 SB6 malformed
    ow_sbdir "sb7-$ow_anc"; [ "$ow_anc" = absent ] || ow_anchor
    printf '{"schema":1,"workers":null,"legs":[{"doc":"%s/HIMMEL-63-N17-legs.md","label":"N17"}]}\n' "$OW_SD" > "$OW_SIB"; ow_sbn2 SB7 malformed
done
ow_sbdir sb6x; printf '{"schema":1,"workers":[]}\n' > "$OW_SIB"; ow_sbnone SB6.ctl
ow_sbdir sb7x; ow_doc "$OW_SD/HIMMEL-63-N17-legs.md" "- 10:00 LIVE - started"
printf '{"schema":1,"legs":[{"doc":"%s/HIMMEL-63-N17-legs.md","label":"N17"}]}\n' "$OW_SD" > "$OW_SIB"
ow_go2 --why --workers-from "$OW_OWN"
lacks "9335 SB7.ctl: a legs-only sibling passes the guard" "$OW_OUT" "malformed"
lacks "9335 SB7.ctl: the reader read the legs row, so its ticket is held" "$OW_OUT" "RESUME${TAB}HIMMEL-63"

# SB8: workers or legs present and not a list
ow_sbdir sb8
for ow_body in '"workers":[],"legs":"x"' '"workers":[],"legs":{}' '"workers":[],"legs":null' '"workers":"x"' '"workers":7'; do
    printf '{"schema":1,%s}\n' "$ow_body" > "$OW_SIB"; ow_sbn2 SB8 malformed
done
ow_sbdir sb8x; printf '{"schema":1,"workers":[],"legs":[]}\n' > "$OW_SIB"; ow_sbnone SB8.ctl

FU_KEY="HIMMEL-$((11000 + 1))"
FU_READER="$HERE/../../lib/pr_remainder.py"
fu_cache() { python3 -I -c 'import json,sys; d=json.load(open(sys.argv[1])); e=d.get(sys.argv[2]); print("absent" if e is None else "%s %s" % (e.get("schema", "legacy"), ",".join(sorted(e["ans"])) if isinstance(e.get("ans"), dict) else "array"))' "$P/cache.json" "7001:$FU_KEY" 2>/dev/null || echo unreadable; }
fu_legacy() {
    python3 -I -c 'import json,sys,time; json.dump({"7001:" + sys.argv[2]: {"at": time.time() - float(sys.argv[4]), "ans": json.loads(sys.argv[3])}}, open(sys.argv[1], "w"))' "$P/cache.json" "$FU_KEY" "$1" "${2:-0}"
}
FU_FIELDS='chief_invalid,chief_owed,handed,kind,nowrite,owed_lines,text'
fu_views() { grep -c -e "pr view $1 " "$P_GH_LOG"; }

test_full_units_cache_and_legacy_refetch() {
    local id=test_full_units_cache_and_legacy_refetch
    p_reset; P_CACHE=""; p_mk "$FU_KEY" 'In Progress'; p_part "$FU_KEY" 7001 remaining
    p_list
    has "$id fresh: the remainder lists" "$P_OUT" 'files=scripts/lib/rem.sh'
    [ "$(fu_views 7001)" = 1 ] && pass "$id fresh: the body is read once" || fail "$id fresh views=$(fu_views 7001)"
    [ "$(fu_cache)" = "1 $FU_FIELDS" ] && pass "$id the listing writes a complete schema-1 entry" || fail "$id cache entry: $(fu_cache)"
    : > "$P_GH_LOG"; p_list
    has "$id complete hit: the remainder lists" "$P_OUT" 'files=scripts/lib/rem.sh'
    [ "$(fu_views 7001)" = 0 ] && pass "$id complete hit: no body read" || fail "$id complete hit views=$(fu_views 7001)"
    fu_legacy '["remaining", [], "edit scripts/lib/rem.sh", false, []]'
    : > "$P_GH_LOG"; p_list
    [ "$(fu_views 7001)" = 1 ] && pass "$id a legacy entry is a listing miss: the body is read again" || fail "$id legacy views=$(fu_views 7001)"
    [ "$(fu_cache)" = "1 $FU_FIELDS" ] && pass "$id and the refetch upgrades it to schema 1" || fail "$id after refetch: $(fu_cache)"
    : > "$P_GH_LOG"; NEXT_DISPATCH_BODY_TTL=0 p_list
    [ "$(fu_views 7001)" = 1 ] && pass "$id TTL=0 reads the body again" || fail "$id TTL=0 views=$(fu_views 7001)"
    : > "$P_GH_LOG"; P_CACHE=off; p_list; p_list; P_CACHE=""
    [ "$(fu_views 7001)" = 2 ] && pass "$id cache off reads each run" || fail "$id off views=$(fu_views 7001)"
    rm -f "$P/cache.json"; P_READER="$P/missing-reader.py"; p_list; P_READER=""
    has "$id a reader that cannot run leaves the PR unread" "$P_OUT" "NEEDS-CHIEF-NOTE $FU_KEY: merged PR #7001 body could not be read"
    [ "$(fu_cache)" != "1 $FU_FIELDS" ] && pass "$id and caches nothing" || fail "$id a failed read was cached"
    : > "$P/not-a-dir"; P_CACHE="$P/not-a-dir/cache.json"; p_list; P_CACHE=""
    has "$id an unwritable cache still lists the fresh answer" "$P_OUT" 'files=scripts/lib/rem.sh'
}

test_incomplete_metadata_not_empty() {
    local id=test_incomplete_metadata_not_empty
    p_reset; P_CACHE=""; p_mk "$FU_KEY" 'In Progress'; p_part "$FU_KEY" 7001 owed proof
    printf 'import json, sys\nsys.stdout.write(json.dumps({"schema": 1, "answer": {"kind": "owed", "handed": ["proof", "2026-11-30"], "text": "check", "nowrite": True, "chief_owed": [], "chief_invalid": []}}) + "\\n")\n' > "$P/no-units-reader.py"
    P_READER="$P/no-units-reader.py"; p_list; P_READER=""
    has "$id an answer without owed_lines leaves the PR unread" "$P_OUT" "NEEDS-CHIEF-NOTE $FU_KEY: merged PR #7001 body could not be read"
    lacks "$id and lists no proof row" "$P_OUT" "$(printf 'RESUME\t%s' "$FU_KEY")"
    rm -f "$P_BODIES/7001"
    fu_legacy '["owed", ["proof", "2026-11-30"], "check: owed -> proof by 2026-11-30", true, []]'
    p_list
    has "$id an old five-value proof entry with an unreadable body withholds" "$P_OUT" "NEEDS-CHIEF-NOTE $FU_KEY: merged PR #7001 body could not be read"
    lacks "$id and never lists a bare proof row from it" "$P_OUT" "$(printf 'RESUME\t%s' "$FU_KEY")"
    python3 -I -c 'import json,sys,time; json.dump({"7001:" + sys.argv[2]: {"schema": 1, "at": time.time(), "ans": {"kind": "owed", "handed": ["proof", "2026-11-30"], "text": "check", "nowrite": True, "chief_owed": [], "chief_invalid": []}}}, open(sys.argv[1], "w"))' "$P/cache.json" "$FU_KEY"
    p_list
    has "$id a schema-1 entry without owed_lines is a miss" "$P_OUT" "NEEDS-CHIEF-NOTE $FU_KEY: merged PR #7001 body could not be read"
    lacks "$id and lists no proof row" "$P_OUT" "$(printf 'RESUME\t%s' "$FU_KEY")"
}

cat > "$WORK/fu-matrix.py" <<'EOF'
import copy, json, subprocess, sys, time
reader, body, key, pr, out = sys.argv[1:6]
base = json.loads(subprocess.run([sys.executable, '-I', reader, '--full-units', key], stdin=open(body, 'rb'), capture_output=True, check=True).stdout)['answer']
now = time.time()
ck = '%s:%s' % (pr, key)

def mut(f):
    a = copy.deepcopy(base)
    f(a)
    return a

def env(a):
    return json.dumps({'schema': 1, 'answer': a}).encode()

def entry(ans_text, schema='1', at=None):
    return ('{"%s": {"schema": %s, "at": %s, "ans": %s}}' % (ck, schema, repr(now) if at is None else at, ans_text)).encode('utf-8')

valid = json.dumps(base)
rows = [
    ('V01-empty', b'', entry('""')),
    ('V02-utf8', b'\xff' + env(base), entry(valid.replace('"owed"', '"o\\u00ff"', 1)).replace(b'\\u00ff', b'\xff')),
    ('V03-duplicate', ('{"schema": 1, "answer": {"kind": "owed", %s' % valid[1:]).encode(), entry('{"kind": "owed", ' + valid[1:])),
    ('V04-nan', env(base).replace(b'"nowrite": false', b'"nowrite": NaN'), entry(valid.replace('"nowrite": false', '"nowrite": NaN'))),
    ('V05-version', json.dumps({'schema': 2, 'answer': base}).encode(), entry(valid, schema='2')),
    ('V06-bool-schema', json.dumps({'schema': True, 'answer': base}).encode(), entry(valid, schema='true')),
    ('V07-missing', env(mut(lambda a: a.pop('owed_lines'))), None),
    ('V07-extra', env(mut(lambda a: a.update(extra=1))), None),
    ('V08-row-type', env(mut(lambda a: a['owed_lines'][0].update(due=7))), None),
    ('V08-list-type', env(mut(lambda a: a.update(chief_owed=[1]))), None),
    ('V09-kind', env(mut(lambda a: a.update(kind='later'))), None),
    ('V09-owner', env(mut(lambda a: a['owed_lines'][0].update(who='nobody'))), None),
    ('V10-shape', env(mut(lambda a: a.update(handed=['chief']))), None),
    ('V11-impossible', env(mut(lambda a: (a.update(handed=['chief', '2026-13-40']), a['owed_lines'][0].update(due='2026-13-40')))), None),
    ('V11-noncanonical', env(mut(lambda a: (a.update(handed=['chief', '20261130']), a['owed_lines'][0].update(due='20261130')))), None),
    ('V12-empty-handoff', env(mut(lambda a: a.update(kind='handed-off', handed=[]))), None),
    ('V13-remaining-handed', env(mut(lambda a: a.update(kind='remaining', handed=['HIMMEL-1']))), None),
    ('V14-owner', env(mut(lambda a: a.update(handed=['operator', a['handed'][1]]))), None),
    ('V15-due', env(mut(lambda a: a.update(handed=['chief', '2026-12-01']))), None),
    ('V16-oversize', env(mut(lambda a: a.update(text='x' * (1 << 20)))), None),
]
for name, fresh, cache in rows:
    if cache is None:
        cache = entry(json.dumps(json.loads(fresh)['answer']))
    open('%s/%s.fresh' % (out, name), 'wb').write(fresh)
    open('%s/%s.cache' % (out, name), 'wb').write(cache)
    print(name, 'both')
for name, at in (('V17-no-at', None), ('V17-text-at', '"x"'), ('V17-nan-at', 'NaN'), ('V17-future', repr(now + 1000)), ('V17-expired', repr(now - 7200)), ('V17-huge-at', '1' + '0' * 400)):
    text = entry(valid, at=at) if at else ('{"%s": {"schema": 1, "ans": %s}}' % (ck, valid)).encode()
    open('%s/%s.cache' % (out, name), 'wb').write(text)
    print(name, 'cache')
EOF

test_full_units_rejection_matrix() {
    local id=test_full_units_rejection_matrix MX="$P/matrix" row kinds
    fu_fixture() { p_reset; P_CACHE=""; p_mk "$FU_KEY" 'In Progress'; p_part "$FU_KEY" 7001 owed chief; }
    fu_fixture; rm -rf "$MX"; mkdir -p "$MX"
    python3 -I "$WORK/fu-matrix.py" "$FU_READER" "$P_BODIES/7001" "$FU_KEY" 7001 "$MX" > "$MX/rows" || fail "$id the matrix fixture could not be built"
    printf 'import sys\nsys.stdout.buffer.write(open(sys.argv[0].rsplit("/", 1)[0] + "/current.fresh", "rb").read())\n' > "$MX/reader.py"
    while read -r row kinds; do
        if [ "$kinds" = both ]; then
            fu_fixture; cp "$MX/$row.fresh" "$MX/current.fresh"; P_READER="$MX/reader.py"; p_list; P_READER=""
            has "$id $row fresh: the PR is unread" "$P_OUT" "NEEDS-CHIEF-NOTE $FU_KEY: merged PR #7001 body could not be read"
            lacks "$id $row fresh: no OWED line from it" "$P_OUT" "OWED $FU_KEY:"
            [ ! -e "$P/cache.json" ] || [ "$(fu_cache)" = absent ] && pass "$id $row fresh: nothing cached" || fail "$id $row fresh cached: $(fu_cache)"
        fi
        fu_fixture; cp "$MX/$row.cache" "$P/cache.json"; p_list
        [ "$(fu_views 7001)" = 1 ] && pass "$id $row cache: a rejected entry is a miss, the body is read" || fail "$id $row cache views=$(fu_views 7001)"
        has "$id $row cache: the real body's answer lists" "$P_OUT" "OWED $FU_KEY: merged PR #7001 owes chief by 2026-11-30"
    done < "$MX/rows"
    [ "$(grep -c . "$MX/rows")" = 26 ] && pass "$id all 26 matrix rows ran" || fail "$id matrix rows: $(cat "$MX/rows")"
    fu_fixture; printf '## Ticket coverage\n- a\tb: owed -> chief by 2026-11-30\n' > "$P_BODIES/7001"
    p_list
    has "POS1 $id fresh: a TAB unit is accepted by owner and date" "$P_OUT" "OWED $FU_KEY: merged PR #7001 owes chief by 2026-11-30"
    [ "$(python3 -I -c 'import json,sys; a=json.load(open(sys.argv[1]))[sys.argv[2]]["ans"]; print("\t" in a["owed_lines"][0]["text"], "\t" in a["text"])' "$P/cache.json" "7001:$FU_KEY")" = "False False" ] \
        && pass "POS1 $id the cached row and the answer text are both TAB-free" || fail "POS1 $id cache: $(cat "$P/cache.json")"
    : > "$P_GH_LOG"; p_list
    has "POS1 $id cache: the TAB entry is a hit" "$P_OUT" "OWED $FU_KEY: merged PR #7001 owes chief by 2026-11-30"
    [ "$(fu_views 7001)" = 0 ] && pass "POS1 $id cache: no body read" || fail "POS1 $id cache views=$(fu_views 7001)"
    p_reset; P_CACHE=""; p_mk "$FU_KEY" 'In Progress'; p_part "$FU_KEY" 7001 remaining; p_list
    has "POS2 $id fresh: an ordinary answer with no owed rows lists" "$P_OUT" 'files=scripts/lib/rem.sh'
    : > "$P_GH_LOG"; p_list
    has "POS2 $id cache: it lists from the cache" "$P_OUT" 'files=scripts/lib/rem.sh'
    [ "$(fu_views 7001)" = 0 ] && pass "POS2 $id cache: no body read" || fail "POS2 $id cache views=$(fu_views 7001)"
}

test_cache_upgrade_preserves_other_legacy_entry() {
    local id=test_cache_upgrade_preserves_other_legacy_entry before after
    p_reset; P_CACHE=""; p_mk "$FU_KEY" 'In Progress'; p_part "$FU_KEY" 7001 remaining
    python3 -I -c 'import json,sys,time; n=time.time(); json.dump({"7001:" + sys.argv[2]: {"at": n, "ans": ["remaining", [], "edit scripts/lib/rem.sh", False, []]}, "7002:HIMMEL-11050": {"at": n - 5, "ans": ["handed-off", ["HIMMEL-9"], "rest", False, ["x"]]}}, open(sys.argv[1], "w"))' "$P/cache.json" "$FU_KEY"
    fu_b() { python3 -I -c 'import json,sys; d=json.load(open(sys.argv[1])); print(len(d), json.dumps(d.get("7002:HIMMEL-11050"), sort_keys=True, separators=(",", ":")))' "$P/cache.json"; }
    before="$(fu_b)"; p_list; after="$(fu_b)"
    [ "$after" = "$before" ] && pass "$id the other live legacy entry is byte-identical after the upgrade" || fail "$id other entry: before '$before' after '$after'"
    [ "$(fu_cache)" = "1 $FU_FIELDS" ] && pass "$id only the fetched entry is upgraded" || fail "$id fetched entry: $(fu_cache)"
}

test_predicate_contract_unchanged_no_network() {
    local id=test_predicate_contract_unchanged_no_network arm
    fu_pred() { p_reset; P_CACHE=""; p_mk "$FU_KEY" 'In Progress' 'Writes: scripts/lib/desc.sh'; p_part "$FU_KEY" 7001 remaining; p_breadcrumb 7001 'edit scripts/lib/rem.sh'; }
    for arm in cold off expired copied; do
        fu_pred
        case "$arm" in
            off) P_CACHE=off ;;
            expired) python3 -I -c 'import json,sys,time; json.dump({"7001:" + sys.argv[2]: {"schema": 1, "at": time.time() - 7200, "ans": {"kind": "remaining", "handed": [], "text": "edit scripts/lib/stale.sh", "nowrite": False, "chief_owed": [], "chief_invalid": [], "owed_lines": []}}}, open(sys.argv[1], "w"))' "$P/cache.json" "$FU_KEY" ;;
            copied) p_tree "fu-copied" ;;
        esac
        p_run --why-ticket "$FU_KEY"; p_verdict "$id $arm" 0
        has "$id $arm source is the breadcrumb remainder" "$P_OUT" "# scope $FU_KEY remainder of PR #7001: scripts/lib/rem.sh"
        lacks "$id $arm an expired entry is not read" "$P_OUT" 'stale.sh'
        [ ! -s "$P_GH_LOG" ] && pass "$id $arm zero GitHub calls" || fail "$id $arm reached GitHub: $(cat "$P_GH_LOG")"
        P_CACHE=""
    done
    p_reset; p_mk "$FU_KEY" 'In Progress'; p_part "$FU_KEY" 7003 owed chief
    p_run --why-ticket "$FU_KEY"; p_verdict "$id owed chief" 1; has "$id owed chief named debt" "$P_OUT" 'drop: merged PR #7003 owes chief by 2026-11-30'
    [ ! -s "$P_GH_LOG" ] && pass "$id owed chief zero GitHub calls" || fail "$id owed chief reached GitHub"
    p_reset; p_mk "$FU_KEY" 'In Progress'; p_part "$FU_KEY" 7004 remaining
    printf '## Ticket coverage\n- first: deferred -> HIMMEL-1\n- second: deferred -> HIMMEL-2\n' > "$P_BODIES/7004"
    p_list; : > "$P_GH_LOG"
    p_run --why-ticket "$FU_KEY"; p_verdict "$id handed-off from a listing-written cache" 1; has "$id hand-off owner" "$P_OUT" 'drop: remainder on HIMMEL-1, HIMMEL-2'
    [ ! -s "$P_GH_LOG" ] && pass "$id handed-off zero GitHub calls" || fail "$id handed-off reached GitHub"
    p_reset; p_mk "$FU_KEY" 'In Progress' 'Writes: scripts/lib/desc.sh'; p_part "$FU_KEY" 7005 none; p_part "$FU_KEY" 7001 remaining; p_breadcrumb 7001 'edit scripts/lib/rem.sh'
    p_run --why-ticket "$FU_KEY"; p_verdict "$id an older none beside a newer answer" 0
    [ ! -s "$P_GH_LOG" ] && pass "$id none arm zero GitHub calls" || fail "$id none arm reached GitHub"
    p_reset; p_mk "$FU_KEY" 'In Progress'; printf '{"event":"merge","result":"moved","key":"%s","pr":"7002","contract":"no"}\n' "$FU_KEY" > "$P/state/status-events.jsonl"
    p_breadcrumb 7002 'not recorded in the PR body, see PR #7002.'
    p_run --why-ticket "$FU_KEY"; p_verdict "$id not recorded" 1; has "$id not recorded reason" "$P_OUT" 'remainder of PR #7002 not recorded (no GitHub read)'
}

test_predicate_reads_new_and_legacy_cache_without_fallback() {
    local id=test_predicate_reads_new_and_legacy_cache_without_fallback
    fu_nr() {
        p_reset; P_CACHE=""; p_mk "$FU_KEY" 'In Progress' 'Writes: scripts/lib/desc.sh'
        printf '{"event":"merge","result":"moved","key":"%s","pr":"7001","contract":"no"}\n' "$FU_KEY" > "$P/state/status-events.jsonl"
        printf 'Remaining: edit scripts/lib/rem.sh\n' > "$P_BODIES/7001"
        p_breadcrumb 7001 'not recorded in the PR body, see PR #7001.'
    }
    fu_nr; p_list
    [ "$(fu_cache)" = "1 $FU_FIELDS" ] && pass "$id the listing wrote a schema-1 entry" || fail "$id listing entry: $(fu_cache)"
    : > "$P_GH_LOG"; p_run --why-ticket "$FU_KEY"; p_verdict "$id listing-written schema-1 hit" 0
    has "$id the schema-1 hit is the source" "$P_OUT" "# scope $FU_KEY remainder of PR #7001: scripts/lib/rem.sh"
    [ ! -s "$P_GH_LOG" ] && pass "$id schema-1 hit zero GitHub calls" || fail "$id schema-1 hit reached GitHub"
    fu_nr; python3 -I -c 'import json,sys,time; json.dump({"7001:" + sys.argv[2]: {"schema": 1, "at": time.time(), "ans": {"kind": "remaining", "handed": [], "text": "edit scripts/lib/rem.sh", "nowrite": False, "chief_owed": [], "chief_invalid": [], "owed_lines": []}}}, open(sys.argv[1], "w"))' "$P/cache.json" "$FU_KEY"
    p_run --why-ticket "$FU_KEY"; p_verdict "$id a schema-1 entry" 0
    has "$id a schema-1 entry is the source" "$P_OUT" "# scope $FU_KEY remainder of PR #7001: scripts/lib/rem.sh"
    fu_nr; fu_legacy '["remaining", [], "edit scripts/lib/rem.sh", false, []]'
    p_run --why-ticket "$FU_KEY"; p_verdict "$id a legacy five-value entry" 0
    has "$id the legacy entry is the source" "$P_OUT" "# scope $FU_KEY remainder of PR #7001: scripts/lib/rem.sh"
    fu_nr; p_run --why-ticket "$FU_KEY"; p_verdict "$id cache miss control" 1
    has "$id the miss takes the breadcrumb gate" "$P_OUT" 'remainder of PR #7001 not recorded (no GitHub read)'
    [ ! -s "$P_GH_LOG" ] && pass "$id predicate arms zero GitHub calls" || fail "$id a predicate arm reached GitHub"
}

test_owed_next_preserves_pr_staging() {
    local id=test_owed_next_preserves_pr_staging pv body tag
    for tag in credential mixed; do
        p_reset; P_CACHE=""; p_mk "$FU_KEY" 'In Progress'; p_part "$FU_KEY" 7001 owed proof
        body='- run proof with a guest credential: owed -> proof by 2026-11-30'
        [ "$tag" = mixed ] && body="- sign the spec: owed -> chief by 2026-11-30
$body"
        printf '## Ticket coverage\n%s\n' "$body" > "$P_BODIES/7001"
        if [ "$tag" = credential ]; then
            p_list
            [ "$(printf '%s\n' "$P_OUT" | grep "^RESUME	$FU_KEY" | awk -F'\t' '{print $NF}')" = proof-staging=guest-credential ] \
                && pass "$id credential without a next step holds" || fail "$id credential without next: $P_OUT"
        fi
        pv="$(p_validation "$FU_KEY")"; p_step "$FU_KEY" "$pv" proof 'rerun the proof'; p_owed close --id "$pv" --key KEEP >/dev/null
        p_list
        [ "$(printf '%s\n' "$P_OUT" | grep "^RESUME	$FU_KEY" | awk -F'\t' '{print $NF}')" = proof-staging=guest-credential ] \
            && pass "$id $tag with a proof next step keeps the PR's staging need" || fail "$id $tag with next: $(printf '%s\n' "$P_OUT" | grep "$FU_KEY")"
    done
}

test_full_units_cache_and_legacy_refetch
test_incomplete_metadata_not_empty
test_full_units_rejection_matrix
test_cache_upgrade_preserves_other_legacy_entry
test_predicate_contract_unchanged_no_network
test_predicate_reads_new_and_legacy_cache_without_fallback
test_owed_next_preserves_pr_staging
P_CACHE=""

ZD="$WORK/nd10557"; mkdir -p "$ZD"
z_mirror() {
    Z_DIR="$ZD/$1/w"; Z_M="$ZD/$1/m/HIMMEL"; mkdir -p "$Z_DIR" "$Z_M"; shift
    local M="$Z_M" p
    mk HIMMEL-80 "In Progress" Medium '[]' '[]' '[]' "unrelated orphan" "Edit scripts/lib/z-80.sh."
    for p in "$@"; do mk "${p%%:*}" "${p#*:}" Medium '[]' '[]' '[]' "10557 fixture ${p%%:*}" "Edit scripts/lib/z-${p%%:*}.sh."; done
}
z_run() { NEXT_DISPATCH_MIRROR="$Z_M" NEXT_DISPATCH_GH_CMD="$WORK/gh" bash "$SUT" --resume-only --top 40 "$@" 2>/dev/null; }
z_orphan() {
    has "10557 $1: the unrelated orphan still lists" "$2" "RESUME${TAB}HIMMEL-80"
    lacks "10557 $1: no owner-unknown line" "$2" "# owner unknown"
}
z_parses() { grep -c '^parse$' "$ZD/q1.log" || true; }
: > "$ZD/q1.log"
cat > "$ZD/holds-fail.py" <<'EOF'
import os, sys
with open(os.environ['HOLDS_LOG'], 'a') as f:
    f.write(sys.argv[1] + '\n')
sys.exit(1)
EOF

z_mirror z1 "$KP-81:In Progress" "$KP-82:In Progress"
Z1D="$Z_DIR/HIMMEL-81-N21-zero-2026-11-22.md"
printf '# N21 — HIMMEL-81\n\n> **Writes:** (none yet)\n\nTicket HIMMEL-81 with HIMMEL-82\n' > "$Z1D"
mkfleet "$Z_DIR/fleet.json" "N21:$Z1D"
z1="$(HOLDS_LOG="$ZD/q1.log" STUB_REAL_HOLDS="$HOLDS_PY" ND_HOLDS="$WORK/holds-log.py" z_run --workers-from "$Z_DIR/fleet.json")"
lacks "10557 Z1: a zero-path worker holds its Ticket-line sibling" "$z1" "RESUME${TAB}HIMMEL-82"
z_orphan Z1 "$z1"
check "10557 Q1: one holds.py parse for the one own live row (Z1)" "1" "$(z_parses)"
printf '# N21 — HIMMEL-81\n\n> **Writes:** none named\n\nTicket HIMMEL-81 with HIMMEL-82\n' > "$Z1D"
has "10557 Z1.ctl: a none named worker does not hold its Ticket-line sibling" "$(z_run --workers-from "$Z_DIR/fleet.json")" "RESUME${TAB}HIMMEL-82"
printf '# N21 — HIMMEL-81\n\n> **Writes:** scripts/lib/z1.sh\n\nTicket HIMMEL-81 with HIMMEL-82\n' > "$Z1D"
has "10557 Z1.ctl: a scoped worker does not hold its Ticket-line sibling" "$(z_run --workers-from "$Z_DIR/fleet.json")" "RESUME${TAB}HIMMEL-82"

z_mirror z4 "$KP-88:In Progress" "$KP-89:In Progress"
Z4D="$Z_DIR/HIMMEL-88-N24-z4-2026-11-22.md"
printf '# N24 — HIMMEL-88\n\n> **Writes:** scripts/lib/z4.sh\n\nTicket HIMMEL-88 with HIMMEL-89\n' > "$Z4D"
mkfleet "$Z_DIR/fleet.json" "N24:$Z4D"
z4="$(HOLDS_LOG="$ZD/q1.log" ND_HOLDS="$ZD/holds-fail.py" z_run --workers-from "$Z_DIR/fleet.json")"
lacks "10557 Z4: a failed parse holds the Ticket-line sibling" "$z4" "RESUME${TAB}HIMMEL-89"
has "10557 Z4: a failed parse is still told overlap unknown" "$z4" "# overlap unknown for live worker N24"
z_orphan Z4 "$z4"
check "10557 Q1: one holds.py parse for the one own live row (Z4's failing stub)" "2" "$(z_parses)"

z_mirror z7 HIMMEL-95:"In Progress"
Z7D="$Z_DIR/N26-z7-2026-11-22.md"
printf '# N26 resume\n\n> **Owns:** HIMMEL-95\n' > "$Z7D"
mkfleet "$Z_DIR/fleet.json" "N26:$Z7D"
z7="$(z_run --workers-from "$Z_DIR/fleet.json")"
lacks "10557 Z7: a scope-less worker holds its Owns key" "$z7" "RESUME${TAB}HIMMEL-95"
z_orphan Z7 "$z7"
printf '# N26 resume\n\n> **Writes:** scripts/lib/z7.sh\n> **Owns:** HIMMEL-95\n' > "$Z7D"
has "10557 Z7.lim: a scoped worker does not hold its Owns key (L5)" "$(z_run --workers-from "$Z_DIR/fleet.json")" "RESUME${TAB}HIMMEL-95"
z_mirror z7h1 "$KP-97:In Progress" "$KP-98:In Progress"
Z7HD="$Z_DIR/HIMMEL-98-N28-h1-2026-11-22.md"
printf '# N28 — HIMMEL-98\n\nnotes\n\n# HIMMEL-97 follow-up\n' > "$Z7HD"
mkfleet "$Z_DIR/fleet.json" "N28:$Z7HD"
z7h="$(z_run --workers-from "$Z_DIR/fleet.json")"
lacks "10557 Z7.h1: a scope-less worker holds the key of its second # title" "$z7h" "RESUME${TAB}HIMMEL-97"
z_orphan Z7.h1 "$z7h"
printf '# N28 — HIMMEL-98\n\nnotes\n\n## Results\n\n# HIMMEL-97 follow-up\n' > "$Z7HD"
has "10557 Z7.h1: a # title under Results is no gate key" "$(z_run --workers-from "$Z_DIR/fleet.json")" "RESUME${TAB}HIMMEL-97"
z_mirror z7enc "$KP-95:In Progress" "$KP-98:In Progress"
Z7ED="$Z_DIR/HIMMEL-98-N27-enc-2026-11-22.md"
printf '# N27 resume \377\n\n> **Owns:** HIMMEL-95\n' > "$Z7ED"
mkfleet "$Z_DIR/fleet.json" "N27:$Z7ED"
z7e="$(NEXT_DISPATCH_MIRROR="$Z_M" NEXT_DISPATCH_GH_CMD="$WORK/gh" bash "$SUT" --resume-only --top 40 --workers-from "$Z_DIR/fleet.json" 2>&1)"
has "10557 Z7.enc: a non-UTF-8 scope-less doc is an owner unknown naming its file-name keys" "$z7e" "# owner unknown: live worker N27 (doc $KP-98-N27-enc-2026-11-22.md unreadable; keys held: $KP-98)"
check "10557 Z7.enc: exactly one owner-unknown line" "1" "$(printf '%s\n' "$z7e" | grep -c '^# owner unknown' || true)"
lacks "10557 Z7.enc: no traceback" "$z7e" "Traceback"
lacks "10557 Z7.enc: no manifest-unreadable line" "$z7e" "manifest fleet.json unreadable"
lacks "10557 Z7.enc: the Owns key does not list" "$z7e" "RESUME${TAB}HIMMEL-95"
lacks "10557 Z7.enc: the withhold is intended: the orphan does not list" "$z7e" "RESUME${TAB}HIMMEL-80"
z_mirror z7sib HIMMEL-94:"In Progress"
Z7SD="$Z_DIR/N29-sib-2026-11-22.md"
printf '# N29 resume\n\n> **Owns:** HIMMEL-94\n' > "$Z7SD"
printf '{"schema":1,"workers":[{"doc":"%s","label":"N29"}]}\n' "$Z7SD" > "$Z_DIR/HIMMEL-nextleg-2026-11-22ZA-z-chief.fleet.json"
printf '{"schema":1,"workers":[]}\n' > "$Z_DIR/HIMMEL-nextleg-2026-11-22ZB-z-chief.fleet.json"
z7s="$(z_run --workers-from "$Z_DIR/HIMMEL-nextleg-2026-11-22ZB-z-chief.fleet.json")"
lacks "10557 Z7.sib: a chain sibling's scope-less doc holds its Owns key" "$z7s" "RESUME${TAB}HIMMEL-94"
z_orphan Z7.sib "$z7s"

z_mirror z2 "$KP-83:In Progress" "$KP-84:In Progress" "$KP-85:In Progress"
Z2D="$Z_DIR/HIMMEL-85-N22b-z2-RESUME-2026-11-22.md"
printf '# RESUME — HIMMEL-85 — worker N22b\n\nContinues from HIMMEL-83-N22-z2-2026-11-21.md.\n' > "$Z2D"
printf '# bundle — HIMMEL-83 / 84\n' > "$Z_DIR/HIMMEL-83-N22-z2-2026-11-21.md"
mkfleet "$Z_DIR/fleet.json" "N22b:$Z2D"
z2="$(HOLDS_LOG="$ZD/q1.log" STUB_REAL_HOLDS="$HOLDS_PY" ND_HOLDS="$WORK/holds-log.py" z_run --workers-from "$Z_DIR/fleet.json")"
lacks "10557 Z2: a scope-less worker holds its named predecessor's title key" "$z2" "RESUME${TAB}HIMMEL-84"
z_orphan Z2 "$z2"
check "10557 Q1: one holds.py parse for the one own live row (Z2)" "3" "$(z_parses)"
mkdir -p "$Z_DIR/old"; mv "$Z_DIR/HIMMEL-83-N22-z2-2026-11-21.md" "$Z_DIR/old/"
has "10557 Z2.lim: a predecessor only in a subfolder is not family" "$(z_run --workers-from "$Z_DIR/fleet.json")" "RESUME${TAB}HIMMEL-84"
mv "$Z_DIR/old/HIMMEL-83-N22-z2-2026-11-21.md" "$Z_DIR/"
printf '# RESUME — HIMMEL-85 — worker N22b\n\n## Results\n\nContinues from HIMMEL-83-N22-z2-2026-11-21.md.\n' > "$Z2D"
has "10557 Z2.lim: a predecessor named only under Results is not family" "$(z_run --workers-from "$Z_DIR/fleet.json")" "RESUME${TAB}HIMMEL-84"
z_mirror z2res "$KP-83:In Progress" "$KP-84:In Progress" "$KP-85:In Progress" "$KP-86:In Progress"
Z2RD="$Z_DIR/HIMMEL-85-N22c-z2res-2026-11-22.md"
printf '# N22c — HIMMEL-85\n\n## Results\n\nTicket HIMMEL-86 picked up\nContinues from HIMMEL-83-N22-z2-2026-11-21.md.\n' > "$Z2RD"
printf '# bundle — HIMMEL-83 / 84\n' > "$Z_DIR/HIMMEL-83-N22-z2-2026-11-21.md"
mkfleet "$Z_DIR/fleet.json" "N22c:$Z2RD"
z2r="$(z_run --workers-from "$Z_DIR/fleet.json")"
lacks "10557 Z2.res: a Ticket line under Results still holds its key" "$z2r" "RESUME${TAB}HIMMEL-86"
has "10557 Z2.res: a doc named only under Results is not family" "$z2r" "RESUME${TAB}HIMMEL-84"

z_mirror z5 "$KP-90:In Progress" "$KP-91:In Progress" "$KP-92:In Progress" "$KP-93:In Progress"
Z5D="$Z_DIR/HIMMEL-90-N25b-z5-2026-11-22.md"
printf '# N25b — HIMMEL-90\n\n> **Writes:** scripts/lib/z5.sh\n\nTicket HIMMEL-90 with HIMMEL-91\nContinues from HIMMEL-93-N25-z5.md.\n' > "$Z5D"
printf '# HIMMEL-93 / 92\n' > "$Z_DIR/HIMMEL-93-N25-z5.md"
printf '{"schema":1,"workers":[{"doc":"%s","label":"N25b"}]}\n' "$Z5D" > "$Z_DIR/HIMMEL-nextleg-2026-11-22ZA-z-chief.fleet.json"
printf '{"schema":1,"workers":[]}\n' > "$Z_DIR/HIMMEL-nextleg-2026-11-22ZB-z-chief.fleet.json"
z5="$(z_run --workers-from "$Z_DIR/HIMMEL-nextleg-2026-11-22ZB-z-chief.fleet.json")"
lacks "10557 Z5: a scoped chain sibling holds its Ticket-line key" "$z5" "RESUME${TAB}HIMMEL-91"
lacks "10557 Z5: a scoped chain sibling holds its named doc's title key" "$z5" "RESUME${TAB}HIMMEL-92"
z_orphan Z5 "$z5"

z_mirror z3 "$KP-86:In Progress" "$KP-87:In Progress" "$KP-97:In Progress" "$KP-99:In Progress"
Z3D="$Z_DIR/HIMMEL-86-N23b-z3-RESUME-2026-11-22.md"
printf '# RESUME — HIMMEL-86 — worker N23b\n\nno doc named here\n' > "$Z3D"
printf '# bundle — HIMMEL-86 / 87\n' > "$Z_DIR/HIMMEL-86-N23-z3-2026-11-21.md"
printf '# HIMMEL-99 / 97\n' > "$Z_DIR/HIMMEL-99-N9-x-RESUME-2026-11-20.md"
mkfleet "$Z_DIR/fleet.json" "N23b:$Z3D"
z3="$(HOLDS_LOG="$ZD/q1.log" STUB_REAL_HOLDS="$HOLDS_PY" ND_HOLDS="$WORK/holds-log.py" z_run --workers-from "$Z_DIR/fleet.json")"
lacks "10557 Z3: a scope-less worker holds the title keys of a folder doc named for its seed" "$z3" "RESUME${TAB}HIMMEL-87"
has "10557 Z3: the RESUME-2026 token seeds no family" "$z3" "RESUME${TAB}HIMMEL-97"
z_orphan Z3 "$z3"
check "10557 Q1: one holds.py parse for the one own live row (Z3)" "4" "$(z_parses)"
mkdir -p "$Z_DIR/old"; mv "$Z_DIR/HIMMEL-86-N23-z3-2026-11-21.md" "$Z_DIR/old/"
has "10557 Z3.lim: a seed doc only in a subfolder is not family" "$(z_run --workers-from "$Z_DIR/fleet.json")" "RESUME${TAB}HIMMEL-87"
mv "$Z_DIR/old/HIMMEL-86-N23-z3-2026-11-21.md" "$Z_DIR/"
rm -f "$Z_M/HIMMEL-86.md"
has "10557 Z3.nomirror: a seed missing from the mirror seeds no family" "$(z_run --workers-from "$Z_DIR/fleet.json")" "RESUME${TAB}HIMMEL-87"
z_mirror z9 "$KP-71:In Progress" "$KP-72:In Progress" "$KP-73:In Progress"
Z9D="$Z_DIR/HIMMEL-71-N29-z9-2026-11-23.md"
printf '# HIMMEL-72 elsewhere\n' > "$Z_DIR/README.md"
printf '# HIMMEL-73 prior\n' > "$Z_DIR/HIMMEL-70-N9-z9.md"
printf '# N29 — HIMMEL-71\n\nSee docs/README.md and %s/HIMMEL-70-N9-z9.md.\n' "$Z_DIR" > "$Z9D"
mkfleet "$Z_DIR/fleet.json" "N29:$Z9D"
z9="$(z_run --workers-from "$Z_DIR/fleet.json")"
has "10557 Z9: a doc named by a path into another folder is not family" "$z9" "RESUME${TAB}HIMMEL-72"
lacks "10557 Z9: a doc named by a path into its own folder is family" "$z9" "RESUME${TAB}HIMMEL-73"
z_orphan Z9 "$z9"
z_mirror z2neg "$KP-84:In Progress" "$KP-85:In Progress" "$KP-99:In Progress"
Z2ND="$Z_DIR/HIMMEL-85-N22b-z2-RESUME-2026-11-22.md"
printf '# RESUME — HIMMEL-85 — worker N22b\n\nno doc named here\n' > "$Z2ND"
printf '# HIMMEL-99 / 84\n' > "$Z_DIR/HIMMEL-99-N9-z2-2026-11-22.md"
printf '# HIMMEL-85 / 84\n' > "$Z_DIR/xHIMMEL-85-N1.md"
mkfleet "$Z_DIR/fleet.json" "N22b:$Z2ND"
has "10557 Z2.neg: a doc named for another key, or for a refused match, is not family" "$(z_run --workers-from "$Z_DIR/fleet.json")" "RESUME${TAB}HIMMEL-84"
z_mirror z2neg85a "$KP-85:In Progress" "$KP-850:In Progress" "$KP-851:In Progress"
printf '# HIMMEL-850\n\nTicket HIMMEL-850 with HIMMEL-851\n' > "$Z_DIR/HIMMEL-850-N1.md"
printf '# HIMMEL-85\n' > "$Z_DIR/HIMMEL-85-N2.md"
mkfleet "$Z_DIR/fleet.json" "N1:$Z_DIR/HIMMEL-850-N1.md"
z85a="$(z_run --workers-from "$Z_DIR/fleet.json")"
has "10557 Z2.neg85: a HIMMEL-850 worker does not hold a HIMMEL-85 doc's key" "$z85a" "RESUME${TAB}HIMMEL-85${TAB}"
lacks "10557 Z2.neg85: control: the HIMMEL-850 worker holds its Ticket-line sibling" "$z85a" "RESUME${TAB}HIMMEL-851"
z_orphan Z2.neg85 "$z85a"
z_mirror z2neg85b "$KP-85:In Progress" "$KP-850:In Progress" "$KP-86:In Progress"
printf '# HIMMEL-85\n\nTicket HIMMEL-85 with HIMMEL-86\n' > "$Z_DIR/HIMMEL-85-N2.md"
printf '# HIMMEL-850\n' > "$Z_DIR/HIMMEL-850-N1.md"
mkfleet "$Z_DIR/fleet.json" "N2:$Z_DIR/HIMMEL-85-N2.md"
z85b="$(z_run --workers-from "$Z_DIR/fleet.json")"
has "10557 Z2.neg85: a HIMMEL-85 worker does not hold a HIMMEL-850 doc's key" "$z85b" "RESUME${TAB}HIMMEL-850"
lacks "10557 Z2.neg85: control: the HIMMEL-85 worker holds its Ticket-line sibling" "$z85b" "RESUME${TAB}HIMMEL-86"
z_orphan Z2.neg85.conv "$z85b"
z_mirror z6 "$KP-86:In Progress" "$KP-87:In Progress"
Z6D="$Z_DIR/HIMMEL-86-N23b-z3-RESUME-2026-11-22.md"
printf '# RESUME — HIMMEL-86 — worker N23b\n\nno doc named here\n' > "$Z6D"
printf '# bundle — HIMMEL-86 / 87\n' > "$Z_DIR/HIMMEL-86-N23-z3-2026-11-21.md"
ln -s "$Z_DIR/no-such-target.md" "$Z_DIR/HIMMEL-86-N23x.md"
mkfleet "$Z_DIR/fleet.json" "N23b:$Z6D"
z6="$(z_run --workers-from "$Z_DIR/fleet.json")"
check "10557 Z6: one owner-unknown line names the unreadable family doc and its file-name key" "1" "$(printf '%s\n' "$z6" | grep -c '^# owner unknown: live worker N23b (family doc HIMMEL-86-N23x.md unreadable; keys held: HIMMEL-86); withheld: ')"
lacks "10557 Z6: no RESUME row at all" "$z6" "RESUME${TAB}"
z_mirror z6dir "$KP-86:In Progress" "$KP-87:In Progress"
Z6R="$Z_DIR/HIMMEL-86-N23b-z3-RESUME-2026-11-22.md"
printf '# RESUME — HIMMEL-86 — worker N23b\n\nno doc named here\n' > "$Z6R"
mkfleet "$ZD/z6dir/fleet.json" "N23b:$Z6R"
if [ "$(id -u)" = 0 ]; then pass '10557 Z6.dir: unlistable family folder skipped as root'; else
    chmod 0111 "$Z_DIR"
    z6d="$(z_run --workers-from "$ZD/z6dir/fleet.json")"
    chmod 0755 "$Z_DIR"
    check "10557 Z6.dir: one owner-unknown line names the unlistable family folder" "1" "$(printf '%s\n' "$z6d" | grep -c "^# owner unknown: live worker N23b (family folder $Z_DIR unreadable; keys held: HIMMEL-86); withheld: ")"
    lacks "10557 Z6.dir: no RESUME row at all" "$z6d" "RESUME${TAB}"
fi
z_mirror z8 "$KP-95:In Progress" "$KP-96:In Progress"
Z8D="$Z_DIR/HIMMEL-95-N28-lim-2026-11-22.md"
printf '# N28 — HIMMEL-95\n\n> **Writes:** (none yet)\n\nTicket HIMMEL-95 with HIMMEL-96\n' > "$Z8D"
mkfleet "$Z_DIR/HIMMEL-nextleg-2026-11-22ZB-other-chief.fleet.json" "N28:$Z8D"
mkfleet "$Z_DIR/HIMMEL-nextleg-2026-11-22ZA-own-chief.fleet.json"
z8="$(z_run --workers-from "$Z_DIR/HIMMEL-nextleg-2026-11-22ZA-own-chief.fleet.json")"
has "10557 Z8.lim: another chain's scope-less worker does not hold its Ticket-line key here" "$z8" "RESUME${TAB}HIMMEL-96"
z_orphan Z8.lim "$z8"

PD="$WORK/nd10257"; PDM="$PD/m/HIMMEL"; PDB="$PD/b"; mkdir -p "$PDM" "$PDB" "$PD/rel"
printf 'v1.0.1\tfalse\t\n' > "$PD/m/HIMMEL.versions.tsv"
(
    M="$PDM"
    mk "$KP-9701" "In Progress" Highest '[]' '["v1.0.1"]' '[]' "owed proof only" "Edit scripts/lib/pd-9701.sh."
    mk "$KP-9702" "In Progress" Highest '[]' '["v1.0.1"]' '[]' "gated on a chief question" "Edit scripts/lib/pd-9702.sh."
    mk "$KP-9703" "In Progress" High '[]' '["v1.0.1"]' '[]' "done on main" "Edit scripts/lib/pd-9703.sh."
    mk "$KP-9704" "In Progress" High '[]' '["v1.0.1"]' '[]' "true remainder" "Edit scripts/lib/pd-9704.sh."
    mk "$KP-9705" "In Progress" Medium '[]' '["v1.0.1"]' '[]' "gated by a readiness c row" "Edit scripts/lib/pd-9705.sh."
    mk "$KP-9706" "To Do" Medium '[]' '["v1.0.1"]' '[]' "the open blocker of 9705" "Edit scripts/lib/pd-9706.sh."
    mk "$KP-9707" "In Progress" Low '[]' '["v1.0.1"]' '[]' "owed proof plus a remainder" "Edit scripts/lib/pd-9707.sh."
)
printf '# chief\n\n## Live state\n\npool-disposition: %s question decision 977\n' "$KP-9702" > "$PDB/chief.md"
mkfleet "$PDB/fleet.json"
bash "$HERE/owe.sh" add --bucket "$PDB" --chief fixture --kind proof --key "$KP-9701" --text 'run the 11-16 replay' >/dev/null \
    || fail "10257: could not seed the owed proof of 9701"
bash "$HERE/owe.sh" add --bucket "$PDB" --chief fixture --kind proof --key "$KP-9707" --text 'run the reader replay' >/dev/null \
    || fail "10257: could not seed the owed proof of 9707"
mkdir -p "$PD/st/workers" "$PD/state"
printf '{"ts":"t","event":"merge","key":"%s","pr":"5707","contract":"no","result":"noop"}\n' "$KP-9707" > "$PD/st/status-events.jsonl"
printf 'Slice one.\n\nRemaining: the reader half\n' > "$PR_BODY_DIR/5707"
HIMMEL_RELEASE_STATE_DIR="$PD/rel" bash "$HERE/readiness.sh" append v1.0.1 "$KP-9705" c --evidence fixture --blocker "$KP-9706" --by fixture --mirror "$PDM" >/dev/null 2>&1 \
    || fail "10257: could not seed the readiness c row"
PDG="$PD/git"; mkdir -p "$PDG"
git -C "$PDG" init -q -b main && git -C "$PDG" -c user.name=t -c user.email=t@example.com -c commit.gpgsign=false -c core.hooksPath=/dev/null commit -q --allow-empty -m "fix(x): [$KP-9703] the last slice" \
    || fail "10257: could not build the fixture main"
cat > "$PD/jira" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$PD_JIRA_LOG"
[ "$1" = get ] && printf '%s\tTask\tTo Do\tstub\n' "$2"
EOF
chmod +x "$PD/jira"; export PD_JIRA_LOG="$PD/jira.log"; : > "$PD_JIRA_LOG"
pd_run() { HIMMEL_RELEASE_STATE_DIR="${PD_REL:-$PD/rel}" TICK_STATE_DIR="$PD/state" NEXT_DISPATCH_GIT_DIR="$PDG" NEXT_DISPATCH_JIRA_CMD="$PD/jira" NEXT_DISPATCH_MIRROR="$PDM" NEXT_DISPATCH_GH_CMD="$WORK/gh" \
    bash "$SUT" --resume-only --top 40 --doc "$PDB/chief.md" --workers-from "$PDB/fleet.json" --workers-dir "$PD/st/workers" 2>/dev/null; }
pd_hash() { python3 -I -c 'import hashlib, sys; print(hashlib.sha256(sys.argv[1].encode()).hexdigest()[:12])' "$1"; }
pd_live() { printf '# chief\n\n## Live state\n\n' > "$PDB/chief.md"; printf 'pool-disposition: %s\n' "$@" >> "$PDB/chief.md"; }
pd0="$(pd_run)"
has "10257: an owed proof on a ticket with nothing on main stays RESUME" "$pd0" "RESUME${TAB}$KP-9701${TAB}"
git -C "$PDG" -c user.name=t -c user.email=t@example.com -c commit.gpgsign=false -c core.hooksPath=/dev/null commit -q --allow-empty -m "fix(x): [$KP-9701] the code slice" \
    || fail "10257: could not land the owed ticket's slice"
pd1="$(pd_run)"
has "10257: the true remainder is RESUME" "$pd1" "RESUME${TAB}$KP-9704${TAB}"
has "10257: an owed proof on a ticket with a recorded remainder stays RESUME" "$pd1" "RESUME${TAB}$KP-9707${TAB}"
lacks "10257: an owed-proof-only ticket fills no RESUME slot" "$pd1" "RESUME${TAB}$KP-9701${TAB}"
lacks "10257: a ticket gated on a chief question fills no RESUME slot" "$pd1" "RESUME${TAB}$KP-9702${TAB}"
lacks "10257: a done-on-main ticket fills no RESUME slot" "$pd1" "RESUME${TAB}$KP-9703${TAB}"
lacks "10257: a ticket a live readiness c row gates fills no RESUME slot" "$pd1" "RESUME${TAB}$KP-9705${TAB}"
check "10257: the owed-proof ticket prints as # pool-owed" "1" "$(printf '%s\n' "$pd1" | grep -c "^# pool-owed $KP-9701 open owed proof o1: run the 11-16 replay\$")"
check "10257: the chief question prints as # pool-gated with its gate named" "1" "$(printf '%s\n' "$pd1" | grep -c "^# pool-gated $KP-9702 pool-disposition question decision 977\$")"
check "10257: the readiness c row prints as # pool-gated with its blocker named" "1" "$(printf '%s\n' "$pd1" | grep -c "^# pool-gated $KP-9705 readiness c blocker=$KP-9706\$")"
check "10257: the done-on-main ticket prints as # pool-done-candidate" "1" "$(printf '%s\n' "$pd1" | grep -c "^# pool-done-candidate $KP-9703 ")"
lacks "10257: the dispatcher writes no Jira status" "$(cat "$PD/jira.log")" "transition"
printf '# chief\n\n## Live state\n\nlegs: none\n' > "$PDB/chief.md"
pd2="$(pd_run)"
lacks "10257: a cleared gate leaves no # pool-gated line" "$pd2" "# pool-gated $KP-9702"
check "10257: a cleared gate returns the ticket to RESUME at its old rank, ahead of the lower-priority remainder" \
    "$KP-9702 $KP-9704 $KP-9707" "$(printf '%s\n' "$pd2" | awk -F'\t' '$1 == "RESUME" {printf "%s%s", s, $2; s=" "}')"
pd_live "$KP-9702 question decision 977" "$KP-9702 slice PR 5800"
has "10257: the newest pool-disposition line of a key replaces its older gate" "$(pd_run)" "RESUME${TAB}$KP-9702${TAB}"
pd_live "$KP-9702 hold until the release settles"
has "10257: a hold line naming no ticket, PR or decision gates nothing" "$(pd_run)" "RESUME${TAB}$KP-9702${TAB}"
printf '{"rows":[{"key":"%s","line":"%s","class":"authority"}]}\n' "$KP-9702" "$(pd_hash "$KP-9702 hold until the release settles")" > "$PD/state/pool-holds-chief.json"
check "10257: a hold line the tick's holds run grants authority gates the ticket" "1" \
    "$(pd_run | grep -c "^# pool-gated $KP-9702 pool-disposition hold until the release settles\$")"
printf '{"rows":[{"key":"%s","line":"%s","class":"no-authority"}]}\n' "$KP-9702" "$(pd_hash "$KP-9702 hold until the release settles")" > "$PD/state/pool-holds-chief.json"
has "10257: a hold line the tick's holds run finds without authority gates nothing" "$(pd_run)" "RESUME${TAB}$KP-9702${TAB}"
printf 'not json\n' > "$PD/state/pool-holds-chief.json"
has "10257: an unreadable holds file grants no authority" "$(pd_run)" "RESUME${TAB}$KP-9702${TAB}"
rm -f "$PD/state/pool-holds-chief.json"
pd_live "$KP-9702 hold waits on PR 5801"
check "10257: a hold on an open PR gates the ticket" "1" "$(pd_run | grep -c "^# pool-gated $KP-9702 pool-disposition hold waits on PR 5801\$")"
printf '{"rows":[{"key":"%s","line":"%s","class":"no-authority"}]}\n' "$KP-9702" "$(pd_hash "$KP-9702 hold waits on PR 5801")" > "$PD/state/pool-holds-chief.json"
has "10257: a hold on an open PR the tick's holds run finds without authority gates nothing" "$(pd_run)" "RESUME${TAB}$KP-9702${TAB}"
rm -f "$PD/state/pool-holds-chief.json"
pd_live "$KP-9702 question decision 977"
printf 'CLOSE-OR-DISPATCH %s fixture drift\n' "$KP-9702" > "$PDB/focus-drift.txt"
has "10257: a sole question decision on a key with a CLOSE-OR-DISPATCH drift row gates nothing" "$(pd_run)" "RESUME${TAB}$KP-9702${TAB}"
rm -f "$PDB/focus-drift.txt"
mkdir -p "$PD/rel-dec"
HIMMEL_RELEASE_STATE_DIR="$PD/rel-dec" bash "$HERE/readiness.sh" append v1.0.1 "$KP-9705" c --evidence fixture --blocker 977 --by fixture --mirror "$PDM" >/dev/null 2>&1 \
    || fail "10257: could not seed the decision-blocker readiness row"
check "10257: a readiness c row naming a bare decision gates the ticket" "1" "$(PD_REL="$PD/rel-dec" pd_run | grep -c "^# pool-gated $KP-9705 readiness c blocker=977\$")"
printf 'CLOSE-OR-DISPATCH %s fixture drift\n' "$KP-9705" > "$PDB/focus-drift.txt"
has "10257: a readiness row naming a bare decision on a key with a CLOSE-OR-DISPATCH drift row gates nothing" "$(PD_REL="$PD/rel-dec" pd_run)" "RESUME${TAB}$KP-9705${TAB}"
rm -f "$PDB/focus-drift.txt"
pd_live "$KP-9702 hold waits on PR 5801"
printf '# mirror=%s\nSTALE-DISPOSITION %s line=%s PR5801=merged\n' "$(cd "$PDM" && pwd -P)" "$KP-9702" "$(pd_hash "$KP-9702 hold waits on PR 5801")" > "$PD/state/tick-pool-stale-1.out"
has "10257: a hold the tick reads stale (its PR merged) gates nothing" "$(pd_run)" "RESUME${TAB}$KP-9702${TAB}"
printf '# mirror=%s/other\nSTALE-DISPOSITION %s line=%s PR5801=merged\n' "$PD" "$KP-9702" "$(pd_hash "$KP-9702 hold waits on PR 5801")" > "$PD/state/tick-pool-stale-1.out"
check "10257: a stale file of another mirror lifts no gate" "1" "$(pd_run | grep -c "^# pool-gated $KP-9702 ")"
pd_own="$PD/state/tick-pool-stale-$(printf '%s\n%s' "$(cd "$PDB" && pwd -P)/chief.md" "$(cd "$PDM" && pwd -P)" | cksum | cut -d' ' -f1).out"
printf '# mirror=%s\n' "$(cd "$PDM" && pwd -P)" > "$pd_own"
printf '# mirror=%s\nSTALE-DISPOSITION %s line=%s PR5801=merged\n' "$(cd "$PDM" && pwd -P)" "$KP-9702" "$(pd_hash "$KP-9702 hold waits on PR 5801")" > "$PD/state/tick-pool-stale-1.out"
check "10257: the doc's own stale file wins over a newer stale file of the same mirror" "1" "$(pd_run | grep -c "^# pool-gated $KP-9702 ")"
rm -f "$PD/state/tick-pool-stale-1.out" "$pd_own"
pd_live "$KP-9702 hold blocked by $KP-9706"
check "10257: a hold blocked by an open ticket gates the ticket" "1" "$(pd_run | grep -c "^# pool-gated $KP-9702 pool-disposition hold blocked by $KP-9706\$")"
has "10257: a failed readiness read gates nothing" "$(PD_REL="$PD/no-release" pd_run)" "RESUME${TAB}$KP-9705${TAB}"
( M="$PDM"; mk "$KP-9706" "Done" Medium '[]' '["v1.0.1"]' '[]' "the closed blocker of 9705" "Edit scripts/lib/pd-9706.sh." )
sed 's/^statusCategory: "x"/statusCategory: "Done"/' "$PDM/$KP-9706.md" > "$PDM/$KP-9706.md.tmp" && mv "$PDM/$KP-9706.md.tmp" "$PDM/$KP-9706.md"
pd3="$(pd_run)"
has "10257: a hold whose blocker is Done gates nothing" "$pd3" "RESUME${TAB}$KP-9702${TAB}"
has "10257: a readiness c row whose blocker is Done is stale and gates nothing" "$pd3" "RESUME${TAB}$KP-9705${TAB}"
bash "$HERE/owe.sh" close --bucket "$PDB" --id o1 --key fixture-closed >/dev/null \
    || fail "10257: could not close the owed proof of 9701"
pd4="$(pd_run)"
lacks "10257: a closed owed proof no longer names the ticket # pool-owed" "$pd4" "# pool-owed $KP-9701 "
check "10257: with its proof closed and its slice on main the ticket is a # pool-done-candidate" "1" "$(printf '%s\n' "$pd4" | grep -c "^# pool-done-candidate $KP-9701 ")"

M107="$WORK/m107/HIMMEL"; mkdir -p "$M107" "$WORK/s107/workers"; cp "$WORK/jira-mirror/HIMMEL.versions.tsv" "$WORK/m107/HIMMEL.versions.tsv"
LONG107="$(printf 'z%.0s' $(seq 1 700))"
(
    M="$M107"
    for n in $(seq 1 26); do mk "$KP-107$(printf '%02d' "$n")" "To Do" Medium '[]' '["v1.0.1"]' '[]' "no scope $n" "Keep the thing going $n."; done
    mk "$KP-10700" "In Progress" High '[]' '["v1.0.1"]' '[]' "in work, no scope" "$LONG107"
)
run107() { NEXT_DISPATCH_MIRROR="$M107" NEXT_DISPATCH_GH_CMD="$WORK/gh" NEXT_DISPATCH_CLASSIFY_CMD="$WORK/classify" bash "$SUT" --top 60 --workers-dir "$WORK/s107/workers" --workers-from "$WORK/fleet5.json" "$@" 2>/dev/null; }
B107="$WORK/b107"; mkdir -p "$B107"
want107="$(run107 --why | grep '^NEEDS-CHIEF-NOTE ' | head -25 | cut -d: -f1 | cut -d' ' -f2)"
b1="$(run107 --scope-batch "$B107/batch.jsonl")"; b1rc=$?
check "10774 B1: --scope-batch exits 0" "0" "$b1rc"
has "10774 B1: prints the written line" "$b1" "# scope-batch 25 written to $B107/batch.jsonl"
check "10774 B1: 25 rows, the keys in the order the listing prints them" "$want107" "$(jq -r .key "$B107/batch.jsonl" 2>/dev/null)"
check "10774 B1: ranks run 1 to 25" "$(seq 1 25)" "$(jq -r .rank "$B107/batch.jsonl" 2>/dev/null)"
check "10774 B1: one batch id on every row, <UTC yyyymmddThhmm>-<first key>" "25 1" "$(jq -r .batch "$B107/batch.jsonl" 2>/dev/null | grep -c -E "^[0-9]{8}T[0-9]{4}-$(printf '%s' "$want107" | head -1)\$" | tr '\n' ' ')$(jq -r .batch "$B107/batch.jsonl" 2>/dev/null | sort -u | grep -c .)"
check "10774 B1: each row carries exactly the five fields" "25" "$(jq -c 'keys' "$B107/batch.jsonl" 2>/dev/null | grep -c '^\["batch","excerpt","key","rank","title"\]$')"
check "10774 B1: the in-work ticket is in the batch by its rank" "1" "$(jq -r .key "$B107/batch.jsonl" 2>/dev/null | grep -c -x "$KP-10700")"
check "10774 B1: its excerpt is the first 600 characters of the description" "$(printf '\n%s' "${LONG107:0:599}")" "$(jq -r --arg k "$KP-10700" 'select(.key == $k) | .excerpt' "$B107/batch.jsonl" 2>/dev/null)"
check "10774 B1: the title is the ticket title" "no scope 1" "$(jq -r --arg k "$KP-10701" 'select(.key == $k) | .title' "$B107/batch.jsonl" 2>/dev/null)"
rm -f "$B107/batch.jsonl"
b1n="$(run107 --scope-batch "$B107/n3.jsonl" --batch-size 3)"
check "10774 B1: --batch-size 3 writes 3 rows" "3" "$(grep -c . "$B107/n3.jsonl" 2>/dev/null)"
has "10774 B1: and says so" "$b1n" "# scope-batch 3 written to $B107/n3.jsonl"
BASE_ND="$HERE/.nd-base-$$.sh"
trap 'rm -rf "$WORK" "$BASE_ND"' EXIT
if git -C "$HERE" show origin/main:scripts/handover/chief-kit/next-dispatchable.sh > "$BASE_ND" 2>/dev/null && [ -s "$BASE_ND" ]; then
    ctl_new="$(run107 --why; echo "rc=$?")"
    ctl_base="$(NEXT_DISPATCH_MIRROR="$M107" NEXT_DISPATCH_GH_CMD="$WORK/gh" NEXT_DISPATCH_CLASSIFY_CMD="$WORK/classify" bash "$BASE_ND" --top 60 --workers-dir "$WORK/s107/workers" --workers-from "$WORK/fleet5.json" --why 2>/dev/null; echo "rc=$?")"
    norm107() { sed -e 's/, or batch it: --scope-batch FILE (docs\/handover\/chief-sections\/scope-helper.md)//' -e 's/^\(# source mirror_age_min=\).*/\1/'; }
    check "10774 B1.ctl: without the flag the listing is the base listing, the remedy suffix aside" "$(printf '%s\n' "$ctl_base" | norm107)" "$(printf '%s\n' "$ctl_new" | norm107)"
else
    echo "SKIP: 10774 B1.ctl: no origin/main ref to read the base script from"
fi
rm -f "$BASE_ND"
find "$M107" "$WORK/s107" "$B107" | LC_ALL=C sort > "$B107.before"
run107 --scope-batch "$B107/b6.jsonl" > /dev/null
find "$M107" "$WORK/s107" "$B107" | LC_ALL=C sort > "$B107.after"
check "10774 B6: the only new path is FILE" "$B107/b6.jsonl" "$(comm -13 "$B107.before" "$B107.after")"
printf 'keep\n' > "$B107/exists.jsonl"
run107 --scope-batch "$B107/exists.jsonl" > "$B107/b2.out"; b2rc=$?
check "10774 B2: an existing FILE exits 2" "2" "$b2rc"
check "10774 B2: and stays unchanged" "keep" "$(cat "$B107/exists.jsonl")"
check "10774 B2: and nothing was listed" "0" "$(grep -c . "$B107/b2.out")"
run107 --why-ticket "$KP-10701" --scope-batch "$B107/b3.jsonl" > /dev/null; b3rc=$?
check "10774 B3: --why-ticket with --scope-batch exits 2" "2" "$b3rc"
check "10774 B3: and writes no file" "no" "$([ -e "$B107/b3.jsonl" ] && echo yes || echo no)"
has "10774 B4: the no-scope row prints the remedy suffix" "$(run107 | grep -m1 '^NEEDS-CHIEF-NOTE ')" "to clear it add a Writes: line to the ticket, or say no code, or batch it: --scope-batch FILE (docs/handover/chief-sections/scope-helper.md)"
for bs in 0 51 abc 007; do
    run107 --scope-batch "$B107/b5-$bs.jsonl" --batch-size "$bs" > /dev/null; b5rc=$?
    check "10774 B5: --batch-size $bs exits 2" "2" "$b5rc"
done
run107 --batch-size 5 > /dev/null; check "10774 B5: --batch-size without --scope-batch exits 2" "2" "$?"
check "10774 B5: and no refused run wrote a file" "0" "$(find "$B107" -name 'b5-*' | grep -c .)"

# a before/after compare of the live register fails when a real worker writes during the run. Every row this
# suite writes names a doc or repo under $WORK, a path unique to this run: none may appear in the real register.
real_hits="$(grep -rlF "$WORK" "$REAL_HOME/.himmel/state/holds" 2>/dev/null | grep -c . || true)"
[ "${real_hits:-0}" = 0 ] && pass "no row of this run reached the real ~/.himmel/state/holds" || fail "$real_hits file(s) of the real ~/.himmel/state/holds name this run's temp path"

printf '\n%d failure(s)\n' "$fails"
[ "$fails" -eq 0 ]
