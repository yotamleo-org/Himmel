#!/usr/bin/env bash
# Test for scripts/statusline/hud-custom-lines.sh — the spawn-free hud composer
# Hermetic: seeded transcript + seeded economics caches +
# seeded rollup/handover; no git/jira/network beyond the local worktree branch.
# Exit: 0 = all pass, 1 = at least one failed.
set -uo pipefail

# grepq <text> [grep-args...] — a `grep -q` test against <text> with NO
# pipeline. printf/echo-into-`grep -q` is a trap under this file's
# `set -o pipefail`: grep -q exits the instant it matches, the producer
# then takes SIGPIPE writing the remainder, and pipefail reports the
# PIPELINE as failed — so a SUCCESSFUL match returns non-zero whenever
# the match lands early in a large input. A here-string is not a pipeline,
# so the status is grep's own verdict alone.
grepq() { local _t="$1"; shift; grep -q "$@" <<< "$_t"; }

DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$DIR/.." && pwd)"
COMPOSER="$DIR/hud-custom-lines.sh"
SEGMENT="$ROOT/where-are-we/statusline-segment.sh"

FAILED=0; PASSED=0
pass() { echo "PASS $1"; PASSED=$((PASSED + 1)); }
fail() { echo "FAIL $1"; FAILED=$((FAILED + 1)); }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
# the doctor segment reads the operator's real counts file (now
# fresh after every doctor run), so pin an empty state dir for hermeticity.
export HIMMEL_DOCTOR_STATE_DIR="$TMP/doctor-state"

# ── Case 1: static no-spawn — no detached fork in the composer OR the segment ─
# The whole leak class is the detached rebuild/refresh; the render-path files
# must contain no `& disown`, no `( … & )` subshell-background, and no bare
# line-final `&` (the most common backgrounding form — the pattern excludes
# `&&`, `>&`, `|&` so logical-and and redirects don't false-positive).
spawn_hits=0
# Strip real comments before matching (a `#` at line-start or after whitespace),
# WITHOUT touching `${x#…}` parameter expansions (# preceded by a non-space).
strip_comments() { sed -E 's/^[[:space:]]*#.*//; s/([[:space:]])#.*/\1/' "$1"; }
for f in "$COMPOSER" "$SEGMENT"; do
    hit="$(strip_comments "$f" | grep -nE '&[[:space:]]*disown|\([^)]*&[[:space:]]*\)|[^&>|]&[[:space:]]*$' || true)"
    if [ -n "$hit" ]; then
        echo "  detached-spawn pattern in $f:"
        printf '%s\n' "$hit" | sed 's/^/    /'
        spawn_hits=$((spawn_hits + 1))
    fi
done
if [ "$spawn_hits" -eq 0 ]; then
    pass "static no-spawn: composer + segment carry no detached-fork pattern"
else
    fail "static no-spawn: $spawn_hits file(s) carry a detached-fork pattern"
fi

# ── Fixtures for economics parity ───────────────────────────────────────────
# A transcript whose assistant messages sum to KNOWN reads/writes/inputs.
#   reads = 2,000,000  writes = 100,000  inputs = 50,000
TRANSCRIPT="$TMP/transcript.jsonl"
{
  printf '%s\n' '{"type":"assistant","message":{"usage":{"cache_read_input_tokens":1500000,"cache_creation_input_tokens":60000,"input_tokens":30000}}}'
  printf '%s\n' '{"type":"assistant","message":{"usage":{"cache_read_input_tokens":500000,"cache_creation_input_tokens":40000,"input_tokens":20000}}}'
  printf '%s\n' '{"type":"user","message":{"content":"ignored"}}'
} > "$TRANSCRIPT"

# All-sessions cache (period=all → window_id all-stats).
ECON_DIR="$TMP/econ"; mkdir -p "$ECON_DIR"
printf '%s\n' '{"reads":45000000,"writes":12000000,"inputs":3000000}' > "$ECON_DIR/cache-all-stats.json"

# Rollup + handover for the WAW line, keyed to THIS worktree's branch.
branch="$(git -C "$ROOT/.." symbolic-ref --short HEAD 2>/dev/null || true)"
key=""
case "$branch" in
    */*) key="$(printf '%s' "${branch#*/}" | sed -n 's/^\([A-Za-z][A-Za-z]*-[0-9][0-9]*\).*/\1/p' | tr '[:lower:]' '[:upper:]')" ;;
esac
ROLLDIR="$TMP/roll"; mkdir -p "$ROLLDIR"
HROOT="$TMP/handover"; mkdir -p "$HROOT/breadcrumbs"
if [ -n "$key" ]; then
    printf '%s\n' "{\"epic\":\"HIMMEL-654\",\"done\":7,\"total\":20,\"refreshed_at\":\"2026-07-06T00:00:00Z\"}" > "$ROLLDIR/where-are-we-rollup-$key.json"
    printf '%s\n' "{\"version\":1,\"ticket\":\"$key\"}" > "$HROOT/breadcrumbs/$key.json"
fi

WT="$(cd "$ROOT/.." && pwd)"
stdin_json="$(printf '{"model":{"id":"claude-opus-4-8"},"transcript_path":"%s","cwd":"%s"}' "$TRANSCRIPT" "$WT")"

run_composer() {
    # $@ = extra env assignments already exported by caller.
    #
    # The segment timeout is pinned WELL above the 3s production default on
    # purpose. The composer runs the WAW segment under `timeout` and fails open
    # to an empty line when it overruns — correct on the render path, but it
    # turns the two WAW cases below into a measurement of machine speed: on a
    # loaded box (e.g. immediately after test/test_cache.sh, which spawns jq
    # several hundred times) the ~1s segment crosses 3s and both cases fail with
    # no WAW line at all. Verified by forcing the mechanism directly:
    # HIMMEL_WHERE_ARE_WE_SEG_TIMEOUT=1 reproduces exactly that 2-failure
    # signature. These cases assert composer/segment PARITY, so the segment must
    # be allowed to finish; the timeout's own fail-open behaviour is not what is
    # under test here.
    #
    # Pinned UNCONDITIONALLY, not `${VAR:-30}`: honouring an inherited value let
    # an ambient 1 or 3 in the caller's environment silently reintroduce the very
    # missing-segment flake this pin exists to remove, turning a parity assertion
    # back into a machine-speed one. A hermetic test sets its own preconditions.
    printf '%s' "$stdin_json" | \
        HIMMEL_WHERE_ARE_WE_ROLLUP_DIR="$ROLLDIR" HANDOVER_DIR="$HROOT" \
        CLAUDE_ALL_SESSIONS_CACHE_DIR="$ECON_DIR" \
        HIMMEL_WHERE_ARE_WE_SEG_TIMEOUT=30 \
        bash "$COMPOSER" 2>/dev/null
}

# ── Case 1b: the HUD prints NO economics rows ─────────────────────────────────
# The transcript and the all-sessions cache above are seeded with real figures, so
# a regression that renders them again shows up as a row. No env knob is set: the
# HUD is the same on every machine.
econ_row_re='^(session|session~|all|all~|week|month|total) |r:.*w:.*hit:|used:'
# Positive control: the matcher must flag known economics rows, so a matcher that
# errors or never matches cannot turn the absence check below into a vacuous pass.
sample_rows="$(printf 'session  r:2.0M  w:100k  hit:97%%\nall      r:45.0M  w:12.0M  hit:93%%\ntotal    used:60.0M\n')"
if [ "$(grep -cE "$econ_row_re" <<< "$sample_rows")" = 3 ]; then
    pass "positive control -> the matcher flags all three economics rows"
else
    fail "positive control -> the matcher missed a known economics row"
fi
out="$(run_composer)"
econ_hits="$(grep -E "$econ_row_re" <<< "$out")"; econ_rc=$?
if [ "$econ_rc" -eq 1 ]; then
    pass "no session / all-sessions / total-used row in the render"
else
    fail "grep rc=$econ_rc (0 = a row printed, 2 = matcher error): $econ_hits"
fi

# ── Case 3c: whole-render negative — no money figure, no `cache:` field ──────
# The composer no longer prices anything: there is no hand-
# maintained per-model rate card whose figures drifted from live pricing. Case 1b
# pins the absence of the economics rows; this pins the ABSENCE across the WHOLE
# render, so a savings figure or a `cache:` field reintroduced on some OTHER row
# still fails. Kept as two separate assertions so a failure names which one
# came back.
if grepq "$out" -E 'net +[+-]?\$'; then
    fail "no-money -> a '\$' net figure is back: $(printf '%s\n' "$out" | grep -E 'net +[+-]?\$')"
else
    pass "no-money -> no net \$ figure anywhere in the render"
fi
if grepq "$out" -F 'cache:'; then
    fail "no-cache-field -> 'cache:' is back: $(printf '%s\n' "$out" | grep -F 'cache:')"
else
    pass "no-cache-field -> no 'cache:' field anywhere in the render"
fi

# ── Case 4: WAW parity — composer's WAW line == the segment's own output ─────
if [ -n "$key" ]; then
    seg_line="$(printf '%s' "$stdin_json" | HIMMEL_WHERE_ARE_WE_ROLLUP_DIR="$ROLLDIR" HANDOVER_DIR="$HROOT" \
                bash "$SEGMENT" --cwd "$WT" 2>/dev/null)"
    # LC_ALL=C is load-bearing, not decoration. The segment line carries 📋
    # (U+1F4CB), a 4-byte astral-plane character, and GNU grep 3.0 — what
    # Git-Bash/MSYS ships — fails to match an astral character through `-F` when
    # the locale is UTF-8 (en_GB.UTF-8 here): the identical byte sequence is
    # reported as absent. Verified in isolation: the same needle matches under
    # LC_ALL=C and does not under LC_ALL=en_GB.UTF-8, while `⎇` (3-byte) and the
    # ASCII parts match under both. This test compares BYTES for a byte-identity
    # claim, so the C locale is also the semantically correct choice.
    if [ -n "$seg_line" ] && LC_ALL=C grepq "$out" -F "$seg_line"; then
        pass "WAW parity -> composer emits the segment line verbatim ('$seg_line')"
    else
        fail "WAW parity -> seg='$seg_line' not found in composer out"
    fi
    # And it must carry the seeded epic rollup.
    if grepq "$out" -F 'HIMMEL-654 7/20'; then
        pass "WAW rollup -> 'HIMMEL-654 7/20' present"
    else
        fail "WAW rollup -> epic part missing"
    fi
else
    pass "WAW parity -> SKIPPED (branch '$branch' yields no ticket key)"
fi

# ── Case 4b: EMPTY transcript_path must not shift cwd ──────────
# The stdin fields are read through ONE `read` with a single-char IFS. Tab is
# IFS *whitespace*, so a leading EMPTY field collapses and every later field
# shifts left — and `.transcript_path` is legitimately empty on a session with
# no transcript yet. Under a tab separator that silently handed the WAW segment
# an empty --cwd (it fell back to $PWD), which is invisible in the econ rows and
# only shows up as a wrong/missing where-are-we line. The composer uses the US
# (\037) separator for exactly this reason; this case is what keeps it there.
#
# Asserted through a STUB segment that echoes the --cwd it was handed, because
# the real segment's output does not reveal which cwd it received. The stub
# lives beside a COPY of the composer so $ROOT/where-are-we resolves to it.
# (the composer invokes it as `bash "$seg" --cwd "$cwd"`, so the value is $2.)
SHIFT_TMP="$TMP/cwdshift"
mkdir -p "$SHIFT_TMP/where-are-we"
printf '%s\n' '#!/usr/bin/env bash' 'cat >/dev/null 2>&1 || true' 'echo "SEG-CWD=$2"' \
    > "$SHIFT_TMP/where-are-we/statusline-segment.sh"
cp -r "$DIR" "$SHIFT_TMP/statusline"
out_shift="$(printf '{"transcript_path":"","cwd":"/expected/cwd"}' | \
    CLAUDE_ALL_SESSIONS_CACHE_DIR="$ECON_DIR" bash "$SHIFT_TMP/statusline/hud-custom-lines.sh" 2>/dev/null)"
if grepq "$out_shift" -F 'SEG-CWD=/expected/cwd'; then
    pass "empty transcript_path -> cwd survives (no leading-empty-field shift)"
else
    fail "empty transcript_path -> cwd shifted: $(printf '%s\n' "$out_shift" | grep -F 'SEG-CWD=' || echo '(no SEG-CWD line)')"
fi
# ── Case 5: env-knob — HIMMEL_WHERE_ARE_WE off suppresses the WAW line ───────
out_off="$(printf '%s' "$stdin_json" | HIMMEL_WHERE_ARE_WE=0 \
    HIMMEL_WHERE_ARE_WE_ROLLUP_DIR="$ROLLDIR" HANDOVER_DIR="$HROOT" \
    CLAUDE_ALL_SESSIONS_CACHE_DIR="$ECON_DIR" bash "$COMPOSER" 2>/dev/null)"
first_line="$(printf '%s\n' "$out_off" | head -n1)"
if ! grepq "$out_off" -F '⎇'; then
    pass "env-knob HIMMEL_WHERE_ARE_WE=0 -> WAW suppressed (first line: '$first_line')"
else
    fail "env-knob HIMMEL_WHERE_ARE_WE=0 -> WAW still present"
fi

# ── Case 7: fail-open — missing transcript + missing caches → exits 0, no rows ─
# HIMMEL_WHERE_ARE_WE_ROLLUP_DIR/HANDOVER_DIR are pinned to the SAME hermetic
# fixture as case 4, not left ambient: without them the WAW segment reads the
# REAL operator's handover state, leaking a live WAW line into this case.
out_empty="$(printf '{"model":{"id":"claude-opus-4-8"},"transcript_path":"/nonexistent","cwd":"%s"}' "$WT" | \
    HIMMEL_WHERE_ARE_WE_ROLLUP_DIR="$ROLLDIR" HANDOVER_DIR="$HROOT" \
    HIMMEL_WHERE_ARE_WE_SEG_TIMEOUT=30 \
    CLAUDE_ALL_SESSIONS_CACHE_DIR="$TMP/empty" bash "$COMPOSER" 2>/dev/null)"; rc=$?
grep -qE "$econ_row_re" <<< "$out_empty"; empty_grep_rc=$?
if [ "$rc" -eq 0 ] && [ "$empty_grep_rc" -eq 1 ]; then
    pass "fail-open -> missing transcript and caches: exit 0, no economics row"
else
    fail "fail-open -> rc=$rc grep-rc=$empty_grep_rc out='$out_empty'"
fi

echo "---"
echo "composer: $PASSED passed, $FAILED failed"
[ "$FAILED" -eq 0 ]
