#!/usr/bin/env bash
# test-silent-go-merge.sh — Exercises silent-go-merge.sh: a GO'd
# READY PR whose worker went silent past CHIEF_WAIT_WORKER_SILENT_MIN merges
# through merge-on-green.sh --go, once, with one operator alert and one chief-doc
# bullet; every negative path merges nothing.
#
# Sandboxed fleet: a temp HANDOVER_DIR, a fake READY worker doc whose session
# takes no turns (an old mtime, no process carrying its stem), a GO file for its
# PR, and a temp git checkout whose scripts/handover/merge-on-green.sh is a stub
# recording its argv. ready-check, the process table and the page sender are
# seams. bash 3.2-safe; Linux-only kit (touch -d).
#
# SILENT_GO_MERGE overrides the script under test.
# Run: bash scripts/handover/chief-kit/test-silent-go-merge.sh
# shellcheck disable=SC2016  # the stubs' bodies are single-quoted on purpose: they expand when the stub runs
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
SGM="${SILENT_GO_MERGE:-$HERE/silent-go-merge.sh}"

fails=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; fails=$((fails + 1)); }
check() { # <name> <expected> <actual>
    if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (want '$2' got '$3')"; fi
}

WORK="$(mktemp -d "${TMPDIR:-/tmp}/silent-go-merge-test.XXXXXX")" || { echo "mktemp -d failed" >&2; exit 1; }
trap 'rm -rf "$WORK"' EXIT

STUB="$WORK/stub"
mkdir -p "$STUB"
export STUB
# The page sender seam (the waiter's): one line per page.
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$1" >> "$STUB/pages"\n' > "$STUB/page.sh"
# ready-check seam: rc and output from files.
cat > "$STUB/ready-check.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB/rc-calls"
cat "$STUB/rc.out" 2>/dev/null
exit "$(cat "$STUB/rc.rc" 2>/dev/null || echo 0)"
EOF
# process-table seam: prints $STUB/ps (pid args lines).
cat > "$STUB/ps.sh" <<'EOF'
#!/usr/bin/env bash
[ -f "$STUB/ps.fail" ] && exit 1
cat "$STUB/ps" 2>/dev/null || printf '1 /sbin/init\n'
EOF
# timeout seam: logs the bound a ready-check call runs under, then runs the real timeout.
REAL_TIMEOUT="$(command -v timeout)"; export REAL_TIMEOUT  # gnu-ok: Linux-only kit
mkdir -p "$STUB/bin"
cat > "$STUB/bin/timeout" <<'EOF'
#!/usr/bin/env bash
case " $* " in *ready-check.sh*) printf '%s\n' "$3" >> "$STUB/timeout-bounds" ;; esac
exec "$REAL_TIMEOUT" "$@"
EOF
chmod +x "$STUB/page.sh" "$STUB/ready-check.sh" "$STUB/ps.sh" "$STUB/bin/timeout"
export PATH="$STUB/bin:$PATH"
export CHIEF_WAIT_PAGE_CMD="$STUB/page.sh" CHIEF_SILENT_GO_READY_CHECK="$STUB/ready-check.sh" CHIEF_SILENT_GO_PS="$STUB/ps.sh"

# The himmel checkout the chief runs from: a git repo whose merge gate is a stub.
CO="$WORK/checkout"
mkdir -p "$CO/scripts/handover"
git -C "$CO" init -q
cat > "$CO/scripts/handover/merge-on-green.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s %s\n' "$0" "$*" >> "$STUB/merges"
exit "$(cat "$STUB/merge.rc" 2>/dev/null || echo 0)"
EOF

export HANDOVER_DIR="$WORK/root"
mkdir -p "$HANDOVER_DIR/.locks/go" "$HANDOVER_DIR/u/b"
SHA=1111111111111111111111111111111111111111
OTHER=2222222222222222222222222222222222222222
WD="$HANDOVER_DIR/u/b/HIMMEL-1-N9-thing-2026-11-05.md"
CD="$HANDOVER_DIR/u/b/HIMMEL-nextleg-chief.md"
WM="$WORK/workers.json"
STATE="$WORK/state"
printf '{"workers":[{"label":"N9","doc":"%s"}]}\n' "$WD" > "$WM"

# reset <completes> <tail bullet...>: a fresh fleet, the worker READY at $SHA and silent for 2 h.
reset() {
    rm -f "$STUB/timeout-bounds" "$STUB/merges" "$STUB/pages" "$STUB/rc-calls""$STUB/rc.out" "$STUB/rc.rc" "$STUB/ps" "$STUB/ps.fail" "$STUB/merge.rc" "$STATE" "$HANDOVER_DIR/.locks/go/"*
    printf '# chief\n\n## Results (newest at the bottom)\n- 01:00 LIVE — chief\n' > "$CD"
    {
        printf '# worker N9\n\n> **completes-ticket: %s**\n\n## Results (newest at the bottom)\n' "$1"
        printf -- '- 00:10 LIVE — started\n- 00:40 READY 77 %s GREEN\n' "$SHA"
        shift
        for b in "$@"; do printf -- '%s\n' "$b"; done
    } > "$WD"
    printf 'TRUST-PATH: no\n' > "$STUB/rc.out"
    touch -d '2 hours ago' "$WD"
}
go_file() { # <head> [trust id]: a GO file written 90 minutes ago
    { printf 'pr=77\nhead=%s\n' "$1"; [ -z "${2:-}" ] || printf 'trust-reviewed=%s\n' "$2"; printf 'mac=x\n'; } > "$HANDOVER_DIR/.locks/go/77.$1"
    touch -d '90 minutes ago' "$HANDOVER_DIR/.locks/go/77.$1"
}
run() { (cd "$CO" && CHIEF_WAIT_WORKER_SILENT_MIN=45 bash "$SGM" --doc "$CD" --workers-from "$WM" --state "$STATE" > "$WORK/out" 2>"$WORK/err"); rc=$?; }
n() { [ -f "$1" ] || { echo 0; return; }; grep -c -- "${2:-.}" "$1" || true; }
GOF="$HANDOVER_DIR/.locks/go/77.$SHA"

# --- (g1) a GO'd READY PR of a silent, dead worker merges once ---
reset yes; go_file "$SHA"; run
check "(g1) exactly one merge call" "1" "$(n "$STUB/merges")"
check "(g1) the merge is the bare relative form with --jira-transition and the GO file" \
    "scripts/handover/merge-on-green.sh 77 --jira-transition --worker-doc $WD --go $GOF" "$(cat "$STUB/merges" 2>/dev/null)"
check "(g1) ready-check ran at the GO head first, as a warn-only read (--observe)" "--observe 77 $SHA" "$(cat "$STUB/rc-calls" 2>/dev/null)"
check "(g1) ready-check runs under a bound past item 19's 105 s" "above" "$(awk '{ print ($1 > 105) ? "above" : "at-or-below" }' "$STUB/timeout-bounds" 2>/dev/null | head -n 1)"
check "(g1) one operator alert" "1" "$(n "$STUB/pages")"
check "(g1) the alert names the worker, the PR and the head" "1" "$(n "$STUB/pages" "^SILENT-WORKER-MERGE N9 pr=77 head=$SHA ")"
check "(g1) one chief-doc bullet naming the silent worker" "1" "$(n "$CD" "^- [0-9:]* SILENT-WORKER-MERGE N9 pr=77 head=$SHA ")"
check "(g1) the helper prints the act" "1" "$(n "$WORK/out" "^SILENT-WORKER-MERGE N9 pr=77 head=$SHA ")"
check "(g1) exit 0 when it acted" "0" "$rc"

# --- (g2) a re-arm neither re-merges nor re-alerts ---
run
check "(g2) still one merge call" "1" "$(n "$STUB/merges")"
check "(g2) still one alert" "1" "$(n "$STUB/pages")"
check "(g2) still one chief-doc bullet" "1" "$(n "$CD" "SILENT-WORKER-MERGE")"
check "(g2) exit 1 when nothing new" "1" "$rc"

# --- (g3) completes-ticket: no merges without --jira-transition ---
reset no; go_file "$SHA"; run
check "(g3) completes-ticket no: no --jira-transition" \
    "scripts/handover/merge-on-green.sh 77 --worker-doc $WD --go $GOF" "$(cat "$STUB/merges" 2>/dev/null)"

# --- (g4) a live worker whose last bullet is a hand-off merges ---
reset yes "- 01:00 LIVE — handoff: context full, RESUME written, stopping"; go_file "$SHA"
printf '4242 claude --name HIMMEL-1-N9-thing-2026-11-05\n' > "$STUB/ps"; run
check "(g4) a hand-off worker still alive merges" "1" "$(n "$STUB/merges")"

# --- (g5) a trust-path PR with a trust-reviewed GO merges ---
reset yes; go_file "$SHA" J1; printf 'TRUST-PATH: yes\n' > "$STUB/rc.out"; run
check "(g5) trust-path PR on a trust-reviewed GO merges" "1" "$(n "$STUB/merges")"

# --- negative rows: nothing merges ---
reset yes; run
check "(n1) no GO file: no merge" "0" "$(n "$STUB/merges")"
check "(n1) no GO file: no alert" "0" "$(n "$STUB/pages")"
check "(n1) no GO file: no chief-doc bullet" "0" "$(n "$CD" "SILENT-WORKER")"

reset yes; go_file "$OTHER"; run
check "(n2) a GO file for a different head: no merge" "0" "$(n "$STUB/merges")"
check "(n2) and no alert" "0" "$(n "$STUB/pages")"

reset yes; go_file "$SHA"; printf 'TRUST-PATH: yes\n' > "$STUB/rc.out"; run
check "(n3) trust-path diff with an ordinary GO: no merge" "0" "$(n "$STUB/merges")"
check "(n3) the operator is alerted instead" "1" "$(n "$STUB/pages" "^SILENT-WORKER-HELD N9 pr=77 head=$SHA reason=trust-path")"
run
check "(n3) a re-arm does not re-alert" "1" "$(n "$STUB/pages")"

reset yes; go_file "$SHA"; printf '4242 claude --name HIMMEL-1-N9-thing-2026-11-05\n' > "$STUB/ps"; run
check "(n4) a silent worker still alive: no merge" "0" "$(n "$STUB/merges")"
check "(n4) one alert says it is alive" "1" "$(n "$STUB/pages" "reason=alive")"

reset yes; go_file "$SHA"; echo 1 > "$STUB/rc.rc"; run
check "(n5) ready-check FAIL at the GO head: no merge" "0" "$(n "$STUB/merges")"
check "(n5) the operator is alerted" "1" "$(n "$STUB/pages" "reason=ready-check")"

reset yes; go_file "$SHA"; touch "$WD"; run
check "(n6) a doc written inside the bound: no merge" "0" "$(n "$STUB/merges")"
check "(n6) and no alert" "0" "$(n "$STUB/pages")"

reset yes; go_file "$SHA"; touch "$GOF"; run
check "(n7) a GO written inside the bound: no merge" "0" "$(n "$STUB/merges")"

reset yes "- 01:00 LIVE — merging now"; go_file "$SHA"; run
check "(n8) a later marker bullet than READY: no merge" "0" "$(n "$STUB/merges")"

reset yes; go_file "$SHA"
(cd "$WORK" && CHIEF_WAIT_WORKER_SILENT_MIN=45 bash "$SGM" --doc "$CD" --workers-from "$WM" --state "$STATE" > "$WORK/out" 2>"$WORK/err")
check "(n9) not run from a checkout root carrying the merge gate: no merge" "0" "$(n "$STUB/merges")"
check "(n9) the operator is alerted" "1" "$(n "$STUB/pages" "reason=not-checkout-root")"

reset yes; go_file "$SHA"; echo 17 > "$STUB/merge.rc"; run
check "(n10) a refused merge alerts with its rc" "1" "$(n "$STUB/pages" "^SILENT-WORKER-MERGE-FAILED N9 pr=77 head=$SHA rc=17")"
check "(n10) and the chief doc says so" "1" "$(n "$CD" "SILENT-WORKER-MERGE-FAILED N9")"

# --- (n11) an unreadable process table is unknown liveness: no merge ---
reset yes; go_file "$SHA"; touch "$STUB/ps.fail"; run
check "(n11) a failing process table: no merge" "0" "$(n "$STUB/merges")"
check "(n11) it is held as alive" "1" "$(n "$STUB/pages" "reason=alive")"

# --- (n12) a stop marker after the READY voids the hand-off waiver: no merge ---
reset yes "- 03:00 HALTED — chief halt; hand-off RESUME written"; go_file "$SHA"; run
check "(n12) a HALTED last bullet that mentions hand-off: no merge" "0" "$(n "$STUB/merges")"
reset yes "- 03:00 BLOCKED — no hand-off possible"; go_file "$SHA"; run
check "(n12) a BLOCKED last bullet that mentions hand-off: no merge" "0" "$(n "$STUB/merges")"
reset yes "- 02:00 HALTED — chief halt" "- 03:00 LIVE — handoff written"; go_file "$SHA"; run
check "(n12) a HALTED between the READY and a hand-off: no merge" "0" "$(n "$STUB/merges")"
reset yes "- 03:00 LIVE — no handoff possible, still working"; go_file "$SHA"
printf '4242 claude --name HIMMEL-1-N9-thing-2026-11-05\n' > "$STUB/ps"; run
check "(n12) a negated hand-off on a live worker: no merge" "0" "$(n "$STUB/merges")"

# --- (w1) the waiter runs the helper each sample and wakes on its lines ---
# The helper is a seam here (its rows are above); the waiter's tick and bank are stubbed.
WAIT="$HERE/chief-wait.sh"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "$STUB/sgm-args"\necho "SILENT-WORKER-MERGE N9 pr=77 head=1111111111111111111111111111111111111111 silent=90m: merged"\n' > "$STUB/sgm.sh"
printf '#!/usr/bin/env bash\nprintf "TICK 03:00 hb=1m workers=N9:FRESH livestate=ok procs=2 models=x ceiling=ok atq=0 suites=0alive/0dead prs=#77 bank=5h8/wk15/codex=? fill=40 tails=N9:LIVE inbox=none tick=UNKNOWN fleet=3/15 capacity=ok gql=4000/04:00 orphans=none nonces=ok legset=ok board=ok denials=none or=skip fails=none\\n"\n' > "$STUB/tick.sh"
printf '#!/usr/bin/env bash\necho PROCEED\n' > "$STUB/bank.sh"
printf '#!/usr/bin/env bash\nexit 2\n' > "$STUB/budget-off.sh"
printf '#!/usr/bin/env bash\nexit 0\n' > "$STUB/noop.sh"
mkdir -p "$WORK/consoles"
I="$WORK/consoles/chief.md"; : > "$I"
reset yes "- 01:00 LIVE — still going"
( cd "$CO" && CHIEF_WAIT_SILENT_GO="$STUB/sgm.sh" CHIEF_WAIT_TICK="$STUB/tick.sh" CHIEF_WAIT_USAGE="$STUB/bank.sh" \
    CHIEF_WAIT_INTERVAL=1 CHIEF_WAIT_POLL_SEC=0.2 CHIEF_WAIT_DISPATCH="$STUB/noop.sh" CHIEF_WAIT_FAIL_WAKE=1000 \
    CHIEF_WAIT_BUDGET="$STUB/budget-off.sh" WAIT_SWEEP_CMD="$STUB/noop.sh" WAIT_FOCUS_CMD="$STUB/noop.sh" \
    HIMMEL_DENIAL_ACK_DIR="$WORK/acks" timeout 20 bash "$WAIT" "$I" --doc "$CD" --workers-from "$WM" > "$WORK/w1.out" 2>/dev/null )  # gnu-ok: Linux-only kit
check "(w1) the waiter wakes with WAKE silent-go" "WAKE silent-go" "$(head -n 1 "$WORK/w1.out")"
check "(w1) the helper's line follows" "1" "$(n "$WORK/w1.out" "^SILENT-WORKER-MERGE N9 pr=77 head=$SHA ")"
check "(w1) the helper got the chief doc, the manifest and the state file" \
    "--doc $CD --workers-from $WM --state $I.wait.silentgo" "$(head -n 1 "$STUB/sgm-args" 2>/dev/null)"
check "(w1) the exit reason is logged" "1" "$(n "$I.wait" "exit=wake-silent-go")"

echo
if [ "$fails" -eq 0 ]; then echo "test-silent-go-merge: all passed"; exit 0; fi
echo "test-silent-go-merge: $fails failed"; exit 1
