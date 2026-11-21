#!/usr/bin/env bash
# shellcheck disable=SC2015  # A && B || C is intentional in the pass/fail reporting lines, as in test-next-dispatchable.sh
# test-next-dispatchable-owed.sh — slice S4a of the in-progress drift fixes: what next-dispatchable.sh does with a merged contract=no PR whose
# remainder the reader answers `owed` (a coverage line `owed -> chief|operator by YYYY-MM-DD`). Fixture only: a Jira mirror,
# a status log of contract=no merge rows, a stub reader (NEXT_DISPATCH_READER: it prints the PR body as its answer, so a
# body file IS the answer line) and a gh stub that logs each call. No real mirror, Jira, gh or worktree is touched.
# NEXT_DISPATCH overrides the script under test. bash 3.2-safe.
#
# Run: bash scripts/handover/chief-kit/test-next-dispatchable-owed.sh
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="${NEXT_DISPATCH:-$HERE/next-dispatchable.sh}"

fails=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; fails=$((fails + 1)); }
has() { case "$2" in *"$3"*) pass "$1" ;; *) fail "$1 (missing '$3' in: $2)" ;; esac; }
lacks() { case "$2" in *"$3"*) fail "$1 (found '$3' in: $2)" ;; *) pass "$1" ;; esac; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/next-dispatch-owed.XXXXXX")" || exit 1
trap 'rm -rf "$WORK"' EXIT
export HOME="$WORK/home" HANDOVER_DIR="$WORK/h"
mkdir -p "$HOME" "$HANDOVER_DIR"
export TICKET_STATUS_STATE_DIR="$WORK/ts-none" HIMMEL_ADMISSIONS_LEDGER="$WORK/ledger-none.jsonl"
GN="$WORK/git-none"; mkdir -p "$GN"
git -C "$GN" init -q -b main && git -C "$GN" -c user.name=t -c user.email=t@example.com -c commit.gpgsign=false -c core.hooksPath=/dev/null commit -q --allow-empty -m "init" \
    || { echo "FAIL: could not build the fixture main"; exit 1; }
export NEXT_DISPATCH_GIT_DIR="$GN" NEXT_DISPATCH_MAIN_REF=main
M="$WORK/jira-mirror/HIMMEL"; mkdir -p "$M"
mkdir -p "$WORK/notcore-stub"
cat > "$WORK/notcore-stub/index.js" <<'NCEOF'
const a = process.argv.slice(2);
if (a[0] === 'release' && a[1] === 'core-check') for (const k of a.slice(a.indexOf('--key') + 1)) console.log('NOT-CORE ' + k);
else { console.error('stub jira: unknown command ' + a.join(' ')); process.exit(2); }
NCEOF
export NEXT_DISPATCH_JIRA_CLI="$WORK/notcore-stub/index.js"
printf 'v1.0.1\tfalse\t\n' > "$WORK/jira-mirror/HIMMEL.versions.tsv"

mk() { # <key> <status> <title> <body>
    printf -- '---\nkey: "%s"\ntype: "Task"\nstatus: "%s"\nstatusCategory: "x"\npriority: "Medium"\nlabels: []\nfixVersions: []\nparent: null\nlinks:\n  blocks: []\n  blocked_by: []\n  relates: []\n---\n\n# %s: %s\n\n## Description\n\n%s\n\nDoD\n- the row is green\n\nProof\n- a RED row that fails before the change\n' \
        "$1" "$2" "$1" "$3" "$4" > "$M/$1.md"
}

# the gh stub logs every call; `pr view <n>` prints that PR's body file, every list is empty
export GH_ARGS="$WORK/gh.args" PR_BODY_DIR="$WORK/prbody"
mkdir -p "$PR_BODY_DIR"; : > "$GH_ARGS"
cat > "$WORK/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_ARGS"
case "$1 $2" in
    "pr view")
        [ "$4" = --repo ] && [ -n "${5:-}" ] && [ "${6:-}" = --json ] && [ "${7:-}" = body ] || { echo "gh stub: unexpected pr view: $*" >&2; exit 64; }
        cat "$PR_BODY_DIR/$3" 2>/dev/null || exit 1; exit 0 ;;
    "pr list") exit 0 ;;
esac
echo "gh stub: unsupported request: $*" >&2; exit 64
EOF
cat > "$WORK/reader.py" <<'EOF'
import json, sys
line = sys.stdin.read().rstrip("\n")
if "--full-units" in sys.argv:
    p = line.split("\t")
    a = {"kind": p[0], "handed": [], "text": "", "nowrite": False, "chief_owed": [], "chief_invalid": [], "owed_lines": []}
    if p[0] == "owed":
        a["handed"], a["text"] = p[1:3], p[3]
        a["owed_lines"] = [{"who": p[1], "due": p[2], "text": p[3], "ask": p[3]}]
    elif p[0] == "handed-off":
        a["handed"], a["text"] = p[1].split(", "), p[2]
    elif p[0] == "remaining":
        a["text"] = p[1]
    sys.stdout.write(json.dumps({"schema": 1, "answer": a}) + "\n")
else:
    sys.stdout.write(line + ("\tnowrite=0\tchief-owed=" if "--units" in sys.argv else "") + "\n")
EOF
cat > "$WORK/classify" <<'EOF'
#!/usr/bin/env bash
for k in "$@"; do printf '%s\tLOCAL-NATIVE\tstub\n' "$k"; done
EOF
chmod +x "$WORK/gh" "$WORK/classify"
LEG="$WORK/HIMMEL-399-N1-live.md"; printf '> **Writes:** none named\n# live\n' > "$LEG"
printf '{"schema":1,"legs":[{"doc":"%s","label":"N1"}]}\n' "$LEG" > "$WORK/fleet.json"
STATE="$WORK/state"; mkdir -p "$STATE/workers"
CACHE="$WORK/cache.json"
DUE="2026-11-20"
K_C="HIMMEL-$((300 + 3))"  # the key whose older PR is owed and whose newer PR is a remainder (built so no literal key sits in a citation)

mk HIMMEL-301 "In Progress" "one owed PR" "Edit scripts/lib/o1.sh."
mk HIMMEL-302 "In Progress" "older remaining, newer owed" "Edit scripts/lib/o2.sh."
mk HIMMEL-303 "In Progress" "older owed, newer remaining" "Edit scripts/lib/o3.sh."
mk HIMMEL-304 "In Progress" "older handed-off, newer owed" "Edit scripts/lib/o4.sh."
mk HIMMEL-305 "In Progress" "owed, then a newer PR that records none" "Edit scripts/lib/o5.sh."
printf 'owed\toperator\t%s\tlive proof\n' "$DUE" > "$PR_BODY_DIR/6001"
printf 'remaining\tEdit scripts/lib/older.sh\n' > "$PR_BODY_DIR/6002"
printf 'owed\tchief\t%s\tthe chief reruns the check\n' "$DUE" > "$PR_BODY_DIR/6003"
printf 'owed\toperator\t%s\tlive proof\n' "$DUE" > "$PR_BODY_DIR/6004"
printf 'remaining\tEdit scripts/lib/newer-scope.sh\n' > "$PR_BODY_DIR/6005"
printf 'handed-off\tHIMMEL-9\trest: deferred to HIMMEL-9\n' > "$PR_BODY_DIR/6006"
printf 'owed\toperator\t%s\tlive proof\n' "$DUE" > "$PR_BODY_DIR/6007"
printf 'owed\toperator\t%s\tlive proof\n' "$DUE" > "$PR_BODY_DIR/6008"
printf 'none\n' > "$PR_BODY_DIR/6009"
printf 'owed\tchief\t%s\tthe chief reruns the check\n' "$DUE" > "$PR_BODY_DIR/6010"
printf 'handed-off\tHIMMEL-9\trest: deferred to HIMMEL-9\n' > "$PR_BODY_DIR/6011"
mk HIMMEL-306 "In Progress" "older owed, newer handed-off" "Edit scripts/lib/o6.sh."
mk HIMMEL-307 "In Progress" "two owed PRs, the newer is due first" "Edit scripts/lib/o7.sh."
mk HIMMEL-308 "In Progress" "two owed PRs, the older is due first" "Edit scripts/lib/o8.sh."
printf 'owed\tchief\t2026-11-25\tlater check\n' > "$PR_BODY_DIR/6012"
printf 'owed\toperator\t2026-11-19\tearlier check\n' > "$PR_BODY_DIR/6013"
printf 'owed\tchief\t2026-11-18\tearlier check\n' > "$PR_BODY_DIR/6014"
printf 'owed\toperator\t2026-11-22\tlater check\n' > "$PR_BODY_DIR/6015"
{
    for pair in 301:6001 302:6002 302:6003 303:6004 303:6005 304:6006 304:6007 305:6008 305:6009 306:6010 306:6011 307:6012 307:6013 308:6014 308:6015; do
        printf '{"ts":"t","event":"merge","key":"HIMMEL-%s","pr":"%s","contract":"no","result":"noop"}\n' "${pair%%:*}" "${pair##*:}"
    done
} > "$STATE/status-events.jsonl"

run() { NEXT_DISPATCH_BODY_CACHE="${CACHE_PATH:-off}" NEXT_DISPATCH_READER="${READER_OVERRIDE:-$WORK/reader.py}" NEXT_DISPATCH_MIRROR="$M" NEXT_DISPATCH_GH_CMD="$WORK/gh" NEXT_DISPATCH_CLASSIFY_CMD="$WORK/classify" \
    bash "$SUT" --workers-dir "$STATE/workers" --workers-from "$WORK/fleet.json" 2>/dev/null; }
row() { printf '%s\n' "$1" | grep -E "(^|	)$2(	|:|$)" || true; }

out="$(run)"
# (a) one owed PR
has "(a) an owed PR prints OWED with the PR, who and the date" "$out" "OWED HIMMEL-301: merged PR #6001 owes operator by $DUE"
lacks "(a) an owed ticket is no RESUME row" "$out" "RESUME	HIMMEL-301"
lacks "(a) an owed ticket needs no chief note" "$out" "NEEDS-CHIEF-NOTE HIMMEL-301"
# a second run on one cache path reads each owed PR once
out_first="$(CACHE_PATH="$CACHE" run)" || fail "(a) the cache-populating run exited non-zero"
has "(a) the cache-populating run printed the OWED row" "$out_first" "OWED HIMMEL-301: merged PR #6001 owes operator by $DUE"
: > "$GH_ARGS"
out_second="$(CACHE_PATH="$CACHE" run)" || fail "(a) the cache-hit run exited non-zero"
has "(a) the cache-hit run printed the same OWED row" "$out_second" "OWED HIMMEL-301: merged PR #6001 owes operator by $DUE"
has "(a) the cache-hit run reached gh (it listed the open PRs), so it ran to the end" "$(cat "$GH_ARGS")" "pr list"
if grep -q 'pr view 6001' "$GH_ARGS"; then fail "(a) a second run on the same cache path makes no gh pr view call for the owed PR (gh log: $(cat "$GH_ARGS"))"; else pass "(a) a second run on the same cache path makes no gh pr view call for the owed PR"; fi
# (b) older remaining, newer owed
has "(b) an older remaining PR and a newer owed one: OWED" "$out" "OWED HIMMEL-302: merged PR #6003 owes chief by $DUE"
lacks "(b) the newer owed PR drops the older remainder: no RESUME row" "$out" "RESUME	HIMMEL-302"
# (c) older owed, newer remaining
r303="$(printf '%s\n' "$out" | grep -E '^RESUME	' || true)"
has "(c) an older owed PR and a newer remaining one: a RESUME row" "$out" "RESUME	"
[ "$(printf '%s\n' "$r303" | grep -c .)" = 1 ] && pass "(c) exactly one RESUME row in the run" || fail "(c) exactly one RESUME row in the run (out: $out)"
has "(c) its scope is the newer PR's remainder" "$r303" "scripts/lib/newer-scope.sh"
has "(c) it is the ticket whose older PR is owed" "$r303" "older owed, newer remaining"
lacks "(c) no OWED row beside it" "$out" "OWED $K_C"
# (d) older handed-off, newer owed
has "(d) an older handed-off PR and a newer owed one: OWED" "$out" "OWED HIMMEL-304: merged PR #6007 owes operator by $DUE"
lacks "(d) no HANDED-OFF row" "$out" "HANDED-OFF HIMMEL-304"
# (e) a newer PR that records none still asks
has "(e) a newer PR recording none after an owed one: NEEDS-CHIEF-NOTE" "$out" "NEEDS-CHIEF-NOTE HIMMEL-305: merged PR #6009"
lacks "(e) and no OWED row for it" "$out" "OWED HIMMEL-305"

# (f) older owed, newer handed-off: the owed step is still pending, so OWED, and neither a RESUME row nor a HANDED-OFF row
has "(f) an older owed PR and a newer handed-off one: OWED" "$out" "OWED HIMMEL-306: merged PR #6010 owes chief by $DUE"
lacks "(f) no HANDED-OFF row while a step is owed" "$out" "HANDED-OFF HIMMEL-306"
lacks "(f) no RESUME row for it" "$out" "RESUME	HIMMEL-306"

# (g) several owed PRs: the row names the earliest due date, whichever PR carries it
has "(g) two owed PRs, the newer due first: the row names the newer PR and its date" "$out" "OWED HIMMEL-307: merged PR #6013 owes operator by 2026-11-19"
has "(g) two owed PRs, the older due first: the row names the older PR and its date" "$out" "OWED HIMMEL-308: merged PR #6014 owes chief by 2026-11-18"

# (h) the real reader: a lone CR joins two items for the merge and for ready-check, so the dispatcher must not read them as two
mk HIMMEL-309 "In Progress" "a lone CR joins the owed line to the next" "Edit scripts/lib/o9.sh."
mk HIMMEL-310 "In Progress" "the same body with a newline, the control" "Edit scripts/lib/o10.sh."
printf '## Ticket coverage\n- a: owed -> operator by %s\r- c: done\n' "$DUE" > "$PR_BODY_DIR/6016"
printf '## Ticket coverage\n- a: owed -> operator by %s\n- c: done\n' "$DUE" > "$PR_BODY_DIR/6017"
printf '{"ts":"t","event":"merge","key":"HIMMEL-309","pr":"6016","contract":"no","result":"noop"}\n{"ts":"t","event":"merge","key":"HIMMEL-310","pr":"6017","contract":"no","result":"noop"}\n' >> "$STATE/status-events.jsonl"
out_h="$(READER_OVERRIDE="$(cd "$(dirname "$SUT")/../../lib" && pwd)/pr_remainder.py" run)"
has "(h) the control body with a newline reads as owed through the real reader" "$out_h" "OWED HIMMEL-310: merged PR #6017 owes operator by $DUE"
lacks "(h) a lone CR is stripped, so the joined line is not owed" "$out_h" "OWED HIMMEL-309"

UK="HIMMEL-$((300 + 99))"
REAL_READER="$(cd "$(dirname "$SUT")/../../lib" && pwd)/pr_remainder.py"
U8="$WORK/u8"; mkdir -p "$U8"
git -C "$(dirname "$REAL_READER")" show 4a9dc2e4f:scripts/lib/pr_remainder.py > "$U8/base_reader.py" || fail "U8: the base reader copy (git show 4a9dc2e4f) could not be read"
cat > "$U8/5341" <<'EOF'
## Ticket coverage

- The adopter-profile.js wording (lines 1216 to 1224) states what the install writes and does not write, now that the template carries the allowed shapes: done
- The same stale wording in probes.js (lines 997 to 1005) and its pinning row in test-wizard-probes.sh: done
- The tooling-line check pin, already landed in PR 5010 as the exact-text row in test-settings-template-allow.sh: done
- VM row 1, a worker merges a throwaway trust-path PR on a valid go.sh GO file with no classifier refusal: owed → chief by 2026-11-20
- VM row 2, a kept-refused shape (go.sh --trust-reviewed) still refuses: owed → chief by 2026-11-20
- The enforcement.md observed-result line for the grouping table, which waits on those two rows: owed → chief by 2026-11-20
EOF
cat > "$U8/5398" <<'EOF'
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
- Template section in worker-brief-template.md: done
- The proof class in gen-briefs.py: done
- The listing change in next-dispatchable.sh (S1, sibling PR): owed → chief by 2026-11-21
- DoD: the pool listing shows the open tickets as PROOF rows (S3): owed → chief by 2026-11-28
- DoD: one wave of proof workers closes at least half (S3, operator closes): owed → operator by 2026-11-28

Remaining: S1 (N6265, held after N6235), S3 (chief-run)
EOF
cat > "$U8/5451" <<'EOF'
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
printf 'Remaining: only a clean live shift, no code.\n' > "$U8/9625"
cp "$PR_BODY_DIR/6016" "$U8/6016"; cp "$PR_BODY_DIR/6017" "$U8/6017"
for b in 5341 5398 5451 9625 6016 6017; do
    python3 -I "$U8/base_reader.py" "$UK" < "$U8/$b" > "$U8/$b.base"
    python3 -I "$REAL_READER" "$UK" < "$U8/$b" > "$U8/$b.head"
    python3 -I "$REAL_READER" --units "$UK" < "$U8/$b" | awk -F'\t' -v OFS='\t' '{NF -= 2; print}' > "$U8/$b.lead"
    [ -s "$U8/$b.base" ] && cmp -s "$U8/$b.base" "$U8/$b.head" && pass "U8 ($b): the reader's default output equals the base reader's" || fail "U8 ($b): the default output moved: base '$(cat "$U8/$b.base")' head '$(cat "$U8/$b.head")'"
    cmp -s "$U8/$b.base" "$U8/$b.lead" && pass "U8 ($b): the --units output's leading fields equal it too" || fail "U8 ($b): --units leading fields '$(cat "$U8/$b.lead")' vs base '$(cat "$U8/$b.base")'"
done
u10_5398="$(python3 -I "$REAL_READER" --units "$UK" < "$U8/5398")"
has "U10: PR 5398's mixed remainder is not no-write" "$u10_5398" "	nowrite=0	chief-owed="
u10_5451="$(python3 -I "$REAL_READER" --units "$UK" < "$U8/5451")"
has "U10: PR 5451's chief-run remainder is no-write, and names its one chief-owed line" "$u10_5451" "	nowrite=1	chief-owed=DoD: the pool listing shows the open tickets as PROOF rows (S3): owed → chief by 2026-11-28"
[ "${u10_5451##*	}" = "chief-owed=DoD: the pool listing shows the open tickets as PROOF rows (S3): owed → chief by 2026-11-28" ] && pass "U10: and the operator-owed line is not in it" || fail "U10: chief-owed field of '$u10_5451'"
u10_5341="$(python3 -I "$REAL_READER" --units "$UK" < "$U8/5341")"
has "U10: PR 5341's owed answer keeps its fields" "$u10_5341" "owed	chief	2026-11-20	VM row 1, "
has "U10: and ends in nowrite=0 and its chief-owed texts" "$u10_5341" "	nowrite=0	chief-owed=VM row 1, "
[ "$(printf '%s' "${u10_5341##*	}" | grep -o '¦' | wc -l | tr -d ' ')" = 2 ] && pass "U10: the three chief-owed lines are joined by ¦" || fail "U10: chief-owed field of '$u10_5341'"

printf 'import sys\nsys.stdout.write(sys.stdin.read())\n' > "$WORK/reader-nofields.py"
mk HIMMEL-311 "In Progress" "a remaining answer without the units fields" "Edit scripts/lib/o11.sh."
mk HIMMEL-312 "In Progress" "an owed answer without the units fields" "Edit scripts/lib/o12.sh."
printf 'remaining\tS3 (chief-run)\n' > "$PR_BODY_DIR/6018"
printf 'owed\tchief\t2026-11-20\tx\n' > "$PR_BODY_DIR/6019"
printf '{"ts":"t","event":"merge","key":"HIMMEL-311","pr":"6018","contract":"no","result":"noop"}\n{"ts":"t","event":"merge","key":"HIMMEL-312","pr":"6019","contract":"no","result":"noop"}\n' >> "$STATE/status-events.jsonl"
out_u9="$(READER_OVERRIDE="$WORK/reader-nofields.py" run)"
has "U9a: a remaining answer without the fields leaves the PR unread" "$out_u9" "NEEDS-CHIEF-NOTE HIMMEL-311: merged PR #6018 body could not be read"
lacks "U9a: and lists no row from it" "$out_u9" "RESUME	HIMMEL-311"
has "U9b: an owed answer without the fields leaves the PR unread" "$out_u9" "NEEDS-CHIEF-NOTE HIMMEL-312: merged PR #6019 body could not be read"
lacks "U9b: and prints no OWED line from it" "$out_u9" "OWED HIMMEL-312"

mkd() {
    printf -- '---\nkey: "%s"\ntype: "Task"\nstatus: "In Progress"\nstatusCategory: "x"\npriority: "Medium"\nlabels: []\nfixVersions: []\nparent: null\nlinks:\n  blocks: []\n  blocked_by: []\n  relates: []\n---\n\n# %s: %s\n\n## Description\n\n%s\n' "$1" "$1" "$2" "$3" > "$M/$1.md"
}
D9732='Edit scripts/lib/o21.sh.

DoD
- With a stale installed helper, an operator go code from Telegram re-installs it; stale_files then reports nothing.
- With no go code, or a checkout not matching a verified commit, the op refuses and the installed files are unchanged.

Proof
VM e2e: install an old helper, pull a newer checkout, approve over the test bot; before stale_files lists files, after it lists none. Negative controls: no go code; a locally modified checkout.'
D9556='Edit scripts/lib/o22.sh.

DoD
- A grouping table of the denials, each group marked allowed or kept, with the reason.
- In a VM session, a worker merges a throwaway trust-path PR on a valid go.sh GO file with no classifier refusal.
- In a VM session, a kept-refused shape still refuses.
- docs/setup/settings-template.json carries the change.

Proof
RED then GREEN on the DoD rows. The two VM rows are run on a test VM with the exact commands the PR lists: a worker merges a throwaway trust-path PR on a valid go.sh GO file with no classifier refusal, and one kept-refused shape still refuses.'
DPLAIN='Edit scripts/lib/o23.sh.

DoD
- the row is green

Proof
- a RED row that fails before the change'
mkd HIMMEL-321 "owed lines with a read-secrets staging line" "$D9732
Staging: none, read-secrets"
mkd HIMMEL-322 "every owed line is the operator's" "$D9556"
mkd HIMMEL-323 "earliest owed is the operator's, a later one the chief's" "$DPLAIN"
cat > "$PR_BODY_DIR/6101" <<'EOF'
## Ticket coverage

- DoD 1, an operator go code from Telegram re-installs a stale helper and `stale_files` then reports nothing: done
- DoD 2, no go code or a checkout not matching a verified commit refuses and leaves the installed files unchanged: done
- Plan 3, document it next to the installer in the afk-sudo doc: done
- S3 VM e2e proof (negative controls N1 and N2 plus the positive run; it sets `helper_update.repo`, `helper_update.checkout` and `helper_update.enabled` in the VM's `/etc/himmel/afk-sudo.json` before it runs): owed → chief by 2026-11-28
- One-time station step after S3 passes (`sudoedit /etc/himmel/afk-sudo.json`, set `helper_update.repo` to the himmel repo's owner/name, `helper_update.checkout` to the station checkout's absolute path, `helper_update.enabled` to true; the op reaches the station with the next `sudo bash scripts/lib/afk-sudo/install.sh --user <login>`): owed → operator by 2026-11-28
- Operator notice for a superseded verdict (needs `afk_sudo.py`, outside this PR's Writes): owed → chief by 2026-11-28

completes-ticket: no (the ticket stays In Progress for S3).
EOF
printf '## Ticket coverage\n\n- VM row 1, a worker runs the check: owed → operator by 2026-11-20\n' > "$PR_BODY_DIR/6102"
printf '## Ticket coverage\n\n- a plain step: owed → operator by 2026-11-18\n' > "$PR_BODY_DIR/6103"
printf '## Ticket coverage\n\n- a throwaway PR run: owed → chief by 2026-11-25\n' > "$PR_BODY_DIR/6104"
for pair in 321:6101 322:6102 323:6103 323:6104; do
    printf '{"ts":"t","event":"merge","key":"HIMMEL-%s","pr":"%s","contract":"no","result":"noop"}\n' "${pair%%:*}" "${pair##*:}" >> "$STATE/status-events.jsonl"
done
out_st="$(READER_OVERRIDE="$REAL_READER" run)"
orow() { printf '%s\n' "$out_st" | grep "^OWED HIMMEL-$1:" || true; }
[ "$(orow 321 | awk '{print $NF}')" = "proof-staging=read-secrets" ] && pass "S3: an owed line whose ticket has Staging: none, read-secrets ends in proof-staging=read-secrets" || fail "S3: the OWED line is '$(orow 321)'"
has "S3: and it names the chief's owed step" "$(orow 321)" "owes chief by 2026-11-28 proof-staging=read-secrets"
lacks "S5: an owed line with only operator-owed steps carries no staging field" "$(orow 322)" "proof-staging"
has "S5: and is still an OWED line" "$out_st" "OWED HIMMEL-322: merged PR #6102 owes operator by 2026-11-20"
has "S7: a later chief-owed throwaway PR line tags the OWED line whose earliest part is the operator's" "$(orow 323)" "owes operator by 2026-11-18 proof-staging=throwaway-repo"

mk HIMMEL-324 "To Do" "owed proof is executable" "Writes: none. No repo writes."
printf '## Ticket coverage\n- run the positive control: owed → proof by 2026-11-20\n' > "$PR_BODY_DIR/6105"
printf '{"ts":"t","event":"merge","key":"HIMMEL-324","pr":"6105","contract":"no","result":"noop"}\n' >> "$STATE/status-events.jsonl"
out_proof="$(READER_OVERRIDE="$REAL_READER" run)"
has "proof-owned remainder is startable" "$out_proof" $'RESUME\tHIMMEL-324'
has "proof-owned remainder has no repo writes" "$(printf '%s\n' "$out_proof" | grep $'^RESUME\tHIMMEL-324')" 'files=-'
[ "$(printf '%s\n' "$out_proof" | grep $'^RESUME\tHIMMEL-324' | awk -F'\t' '{print $NF}')" = proof ] && pass "proof capability is executable" || fail "missing executable proof capability"
lacks "proof-owned remainder is not parked OWED" "$out_proof" 'OWED HIMMEL-324:'
mk HIMMEL-325 "To Do" "proof still needs operator staging" "Writes: none. No repo writes."
printf '## Ticket coverage\n- run the throwaway PR check: owed → proof by 2026-11-20\n' > "$PR_BODY_DIR/6106"
printf '{"ts":"t","event":"merge","key":"HIMMEL-325","pr":"6106","contract":"no","result":"noop"}\n' >> "$STATE/status-events.jsonl"
out_staged="$(READER_OVERRIDE="$REAL_READER" run)"
has "proof owner retains operator-only staging" "$(printf '%s\n' "$out_staged" | grep $'^RESUME\tHIMMEL-325')" 'proof-staging=throwaway-repo'
# needs() itself: the text of an owed answer handed to proof is a step, so a need named only there is found (the ticket text names none)
cat > "$WORK/ps-direct.py" <<'EOF'
import importlib.util, sys
spec = importlib.util.spec_from_file_location('proof_staging', sys.argv[1])
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
answers = [dict(kind='owed', handed=['proof', '2026-11-20'], text='run the throwaway PR check')]
print(';'.join('%s|%s|%s' % n for n in mod.needs('', answers) if n[0] != 'unknown'))
EOF
[ "$(python3 -I "$WORK/ps-direct.py" "$HERE/proof_staging.py")" = "throwaway-repo|operator|throwaway PR" ] && pass "needs(): an owed answer handed to proof contributes its text as a step" || fail "needs(): an owed answer handed to proof contributes its text as a step"
owe="$HERE/owe.sh"
KEEP_KEY="HIMMEL-$((300 + 24))" OPERATOR_KEY="HIMMEL-$((300 + 25))"
validation="$(bash "$owe" add --bucket "$WORK" --chief old-chief --kind proof --key "$KEEP_KEY" --text validate --metadata '{"actor":"chief","action":"validate-proof"}')"
bash "$owe" add --bucket "$WORK" --chief old-chief --kind step --key "$KEEP_KEY" --text 'Fix scripts/lib/keep-next.py' --metadata "{\"actor\":\"worker\",\"action\":\"next-step\",\"source_id\":\"$validation\",\"capability\":\"code worker\",\"due\":\"2026-11-20\",\"wake\":\"worker free\"}" >/dev/null
mk HIMMEL-326 "To Do" "code remainder beside a pending validation" "Writes: scripts/lib/x-code.py."
printf '## Ticket coverage\n\nRemaining: S1 fix code (scripts/lib/x-code.py)\n' > "$PR_BODY_DIR/6107"
printf '{"ts":"t","event":"merge","key":"HIMMEL-326","pr":"6107","contract":"no","result":"noop"}\n' >> "$STATE/status-events.jsonl"
CODE_KEY="HIMMEL-$((300 + 26))"
bash "$owe" add --bucket "$WORK" --chief old-chief --kind proof --key "$CODE_KEY" --text validate --metadata '{"actor":"chief","action":"validate-proof"}' >/dev/null
out_pending="$(READER_OVERRIDE="$REAL_READER" run)"
lacks "a next step does not bypass pending chief validation" "$(printf '%s\n' "$out_pending" | grep $'^RESUME\tHIMMEL-324')" 'keep-next.py'
lacks "a pending validation hides the original proof row: no duplicate paid proof run" "$out_pending" $'RESUME\tHIMMEL-324'
has "the pending validation names the chief as the owner of that ticket" "$out_pending" "OWED HIMMEL-324: owed action $validation owes chief by 2026-11-20"
has "an unrelated code scope on another ticket stays eligible beside its pending validation" "$out_pending" $'RESUME\tHIMMEL-326'
bash "$owe" close --bucket "$WORK" --id "$validation" --key KEEP >/dev/null
out_keep="$(READER_OVERRIDE="$REAL_READER" run)"
has "settled KEEP routes code to an executable worker" "$(printf '%s\n' "$out_keep" | grep $'^RESUME\tHIMMEL-324')" 'files=scripts/lib/keep-next.py'
[ "$(printf '%s\n' "$out_keep" | grep $'^RESUME\tHIMMEL-324' | awk -F'\t' '{print $NF}')" != proof ] && pass "KEEP code is not sent to a proof worker" || fail "KEEP code misrouted to proof"
bash "$owe" add --bucket "$WORK" --chief successor --kind proof --key "$KEEP_KEY" --text 'requirements changed; validate again' --metadata '{"actor":"chief","action":"validate-proof"}' >/dev/null
out_changed="$(READER_OVERRIDE="$REAL_READER" run)"
lacks "new pending requirements do not inherit a stale KEEP code scope" "$(printf '%s\n' "$out_changed" | grep $'^RESUME\tHIMMEL-324')" 'keep-next.py'
operator_validation="$(bash "$owe" add --bucket "$WORK" --chief chief --kind proof --key "$OPERATOR_KEY" --text validate --metadata '{"actor":"chief","action":"validate-proof"}')"
bash "$owe" add --bucket "$WORK" --chief chief --kind step --key "$OPERATOR_KEY" --text 'Operator stages throwaway repo credentials' --metadata "{\"actor\":\"operator\",\"action\":\"next-step\",\"source_id\":\"$operator_validation\",\"due\":\"2026-11-20\",\"wake\":\"operator stages credentials\",\"capability\":\"operator staging\"}" >/dev/null
bash "$owe" close --bucket "$WORK" --id "$operator_validation" --key KEEP >/dev/null
out_operator="$(READER_OVERRIDE="$REAL_READER" run)"
has "a real operator-only KEEP remains explicitly operator-owned" "$out_operator" 'owes operator by 2026-11-20'
lacks "a proof worker cannot consume an operator-only KEEP action" "$out_operator" $'RESUME\tHIMMEL-325'

if [ "$fails" -eq 0 ]; then echo "next-dispatchable-owed: all rows passed"; else echo "next-dispatchable-owed: $fails row(s) failed"; exit 1; fi
