#!/usr/bin/env bash
# test-cancel-runs.sh — Exercises cancel-runs.sh against a PATH-injected stub gh.
# Fixture: 6 runs; 5 non-completed (2 on the kept head KEEP, 3 elsewhere) and 1
# completed run on another head that must never be cancelled. bash 3.2-safe.
#
# Run: bash scripts/handover/console-kit/test-cancel-runs.sh
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
CR="${CANCEL_RUNS:-$HERE/cancel-runs.sh}"

fails=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; fails=$((fails + 1)); }
check() { # <name> <expected> <actual>
    if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (want '$2' got '$3')"; fi
}
has() { # <name> <pattern> <text>
    if printf '%s\n' "$3" | grep -Eq -- "$2"; then pass "$1"; else fail "$1 (no match for '$2' in: $3)"; fi
}

WORK="$(mktemp -d "${TMPDIR:-/tmp}/cancel-runs-test.XXXXXX")" || { echo "mktemp -d failed" >&2; exit 1; }
trap 'rm -rf "$WORK"' EXIT

KEEP=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
KEEP2=cccccccccccccccccccccccccccccccccccccccc
OTHER=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb

cat > "$WORK/runs.json" <<EOF
[
 {"databaseId":101,"status":"in_progress","headSha":"$KEEP"},
 {"databaseId":102,"status":"queued","headSha":"$KEEP"},
 {"databaseId":103,"status":"queued","headSha":"$OTHER"},
 {"databaseId":104,"status":"in_progress","headSha":"$OTHER"},
 {"databaseId":105,"status":"waiting","headSha":"$OTHER"},
 {"databaseId":106,"status":"completed","headSha":"$OTHER"}
]
EOF

mkdir -p "$WORK/bin"
cat > "$WORK/bin/gh" <<'STUB'
#!/usr/bin/env bash
# stub gh: serves runs.json (per --status), resolves PR heads, logs cancels.
# STUB_GH_FAIL=1 fails every call; STUB_FAIL_ID=<id> fails that cancel only.
[ "${STUB_GH_FAIL:-}" = 1 ] && { echo "gh: simulated failure" >&2; exit 1; }
case "$1 $2" in
    "run list")
        # An unfiltered listing is crowded out by newer completed runs (the --limit
        # cap); only a --status listing reaches the active ones.
        st=""
        while [ "$#" -gt 0 ]; do [ "$1" = "--status" ] && st="$2"; shift; done
        jq --arg st "$st" '[.[] | select(if $st == "" then .status == "completed" else .status == $st end)]' "$STUB_RUNS" ;;
    "run cancel")
        [ "$3" = "${STUB_FAIL_ID:-}" ] && { echo "gh: cannot cancel $3" >&2; exit 1; }
        printf '%s\n' "$3" >> "$STUB_CANCEL_LOG" ;;
    "pr view")
        case "$3" in
            3221) echo "$STUB_KEEP_SHA" ;;
            3222) echo "$STUB_KEEP2_SHA" ;;
            *) echo "gh: no such pr $3" >&2; exit 1 ;;
        esac ;;
    *) echo "stub gh: unhandled: $*" >&2; exit 1 ;;
esac
STUB
chmod +x "$WORK/bin/gh"

export PATH="$WORK/bin:$PATH"
export STUB_RUNS="$WORK/runs.json" STUB_CANCEL_LOG="$WORK/cancel.log"
export STUB_KEEP_SHA="$KEEP" STUB_KEEP2_SHA="$KEEP2"

run() { : > "$STUB_CANCEL_LOG"; bash "$CR" --repo o/r "$@" 2>&1; }
cancelled() { sort "$STUB_CANCEL_LOG" | tr '\n' ' '; }

out="$(run --keep-pr 3221)"; rc=$?
check "keep-pr exits 0" "0" "$rc"
check "keep-pr cancels exactly the 3 non-completed runs off the kept head" "103 104 105 " "$(cancelled)"
has "summary counts 3 cancelled, 0 failed, names the kept head" "^cancelled=3 failed=0 kept=$KEEP\$" "$out"

out="$(run --keep-pr 3221 --dry-run)"; rc=$?
check "dry-run exits 0" "0" "$rc"
check "dry-run cancels nothing" "" "$(cancelled)"
has "dry-run reports what it would cancel" "^cancelled=0 failed=0 kept=$KEEP would-cancel=3\$" "$out"

out="$(run --keep-sha "$KEEP")"; rc=$?
check "keep-sha cancels the same 3 runs" "103 104 105 " "$(cancelled)"

out="$(run --keep-pr 3221 --keep-sha "$KEEP2")"; rc=$?
check "repeated keeps union (a second head with no runs changes nothing)" "103 104 105 " "$(cancelled)"
has "summary lists both kept heads" "^cancelled=3 failed=0 kept=$KEEP,$KEEP2\$" "$out"

out="$(run)"; rc=$?
check "no keep and no --all refuses with usage exit 2" "2" "$rc"
check "refusal cancels nothing" "" "$(cancelled)"

out="$(run --all)"; rc=$?
check "--all exits 0" "0" "$rc"
check "--all cancels every non-completed run, never the completed one" "101 102 103 104 105 " "$(cancelled)"
has "--all summary shows no kept list" '^cancelled=5 failed=0 kept=-$' "$out"

out="$(run --keep-pr 3221 --all)"; rc=$?
check "--keep-pr with --all is contradictory, exit 2" "2" "$rc"
check "contradiction cancels nothing" "" "$(cancelled)"

out="$(run --keep-pr 9999)"; rc=$?
check "an unresolvable keep PR refuses (fail closed), exit 1" "1" "$rc"
check "unresolvable keep cancels nothing" "" "$(cancelled)"

out="$(run --keep-sha not-a-sha)"; rc=$?
check "a malformed --keep-sha is a usage error" "2" "$rc"

out="$(STUB_FAIL_ID=104 run --keep-pr 3221)"; rc=$?
check "a failed cancel exits 1" "1" "$rc"
check "the other runs still cancel" "103 105 " "$(cancelled)"
has "summary counts the failure" "^cancelled=2 failed=1 kept=$KEEP\$" "$out"

out="$(STUB_GH_FAIL=1 run --keep-pr 3221)"; rc=$?
check "gh down refuses, exit 1" "1" "$rc"
check "gh down cancels nothing" "" "$(cancelled)"

out="$(bash "$CR" --repo not-a-slug --keep-pr 3221 2>&1)"; rc=$?
check "a malformed --repo is a usage error" "2" "$rc"

if [ "$fails" -eq 0 ]; then printf 'ALL PASS\n'; exit 0; fi
printf '%d FAILED\n' "$fails"
exit 1
