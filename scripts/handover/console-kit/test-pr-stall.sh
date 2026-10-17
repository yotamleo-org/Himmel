#!/usr/bin/env bash
# test-pr-stall.sh — Exercises pr-stall.sh against a PATH-injected stub gh that
# serves fixtures/pr-stall/. pr-2887.json and pr-2869.json are captured from the
# live repo on 2026-10-17 (gh pr view --json number,headRefName,headRefOid,
# mergeable,mergeStateStatus,statusCheckRollup,updatedAt,createdAt); pr-9001 (clean),
# pr-9002 (unknown), pr-9003 (no-ci), pr-9004 (idle) are jq-derived from those two (no live PR held
# those states at capture time). Clock pinned by PR_STALL_NOW. bash 3.2-safe.
#
# Run: bash scripts/handover/console-kit/test-pr-stall.sh
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
PS="${PR_STALL:-$HERE/pr-stall.sh}"
FIX="$HERE/fixtures/pr-stall"

fails=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; fails=$((fails + 1)); }
check() { # <name> <expected> <actual>
    if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (want '$2' got '$3')"; fi
}
has() { # <name> <pattern> <text>
    if printf '%s\n' "$3" | grep -Eq -- "$2"; then pass "$1"; else fail "$1 (no match for '$2' in: $3)"; fi
}
hasnt() { # <name> <pattern> <text>
    if printf '%s\n' "$3" | grep -Eq -- "$2"; then fail "$1 (unexpected '$2' in: $3)"; else pass "$1"; fi
}

WORK="$(mktemp -d "${TMPDIR:-/tmp}/pr-stall-test.XXXXXX")" || { echo "mktemp -d failed" >&2; exit 1; }
trap 'rm -rf "$WORK"' EXIT

mkdir -p "$WORK/bin"
cat > "$WORK/bin/gh" <<'STUB'
#!/usr/bin/env bash
# stub gh: serves the pr-stall fixtures; STUB_GH_FAIL=1 makes every call fail.
[ "${STUB_GH_FAIL:-}" = 1 ] && { echo "gh: simulated failure" >&2; exit 1; }
case "$1 $2" in
    "pr list") cat "$STUB_FIX/pr-list.json" ;;
    "pr view") cat "$STUB_FIX/pr-$3.json" ;;
    "run list") cat "$STUB_FIX/run-list.json" ;;
    *) echo "stub gh: unhandled: $*" >&2; exit 1 ;;
esac
STUB
chmod +x "$WORK/bin/gh"

# Recording inbox-send stand-in: one log line per call.
cat > "$WORK/inbox-send" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB_SENT_LOG"
STUB
chmod +x "$WORK/inbox-send"

# Fleet manifest: leg N2362 owns the 2887 branch (its doc names the branch).
mkdir -p "$WORK/docs"
DOC="$WORK/docs/HIMMEL-5969-N2362-succession-wake-once-2026-10-16.md"
printf '# leg\n- PR: feat/himmel-5969-succession-wake-once-b\n' > "$DOC"
MAN="$WORK/fleet.json"
printf '{"schema":1,"legs":[{"doc":"%s","label":"N2362"}]}\n' "$DOC" > "$MAN"

export PATH="$WORK/bin:$PATH"
export STUB_FIX="$FIX" STUB_SENT_LOG="$WORK/sent.log"
export PR_STALL_NOW="2026-10-17T01:10:00Z"
export PR_STALL_INBOX_SEND="$WORK/inbox-send"
export XDG_RUNTIME_DIR="$WORK/run"
mkdir -p "$XDG_RUNTIME_DIR"

run() { bash "$PS" --repo o/r --manifest "$MAN" "$@" 2>&1; }

out="$(run)"; rc=$?
check "exit 0 when gh works" "0" "$rc"
has "2887 (CONFLICTING, no checks) is conflict, mapped to its leg" '^STALL 2887 conflict N2362 ' "$out"
hasnt "2887 conflicting is not also reported as no-ci" '^STALL 2887 no-ci' "$out"
has "no-checks non-conflicting PR is no-ci, unmapped leg is -" '^STALL 9003 no-ci - ' "$out"
has "2869 IN_PROGRESS shard is ci-slow with queue depth" '^STALL 2869 ci-slow .*queue=5' "$out"
has "idle PR is idle" '^STALL 9004 idle - ' "$out"
hasnt "UNKNOWN mergeable is not conflict" '^STALL 9002' "$out"
hasnt "clean PR prints nothing" '^STALL 9001' "$out"
has "summary counts stuck PRs and queue depth" '^STALL-SUMMARY stuck=4 queue=5$' "$out"

out="$(run --noci-min 60)"
hasnt "no-ci not flagged before its threshold" '^STALL 9003' "$out"
out="$(run --slow-min 60)"
hasnt "ci-slow not flagged before its threshold" '^STALL 2869' "$out"
out="$(run --idle-h 24)"
hasnt "idle not flagged before its threshold" '^STALL 9004' "$out"

out="$(STUB_GH_FAIL=1 run)"; rc=$?
check "gh failure exits 3" "3" "$rc"
has "gh failure prints STALL-UNKNOWN" '^STALL-UNKNOWN gh failed' "$out"

: > "$WORK/sent.log"
run --notify > /dev/null
run --notify > /dev/null
check "--notify twice sends once (2887 only; 9003 has no leg)" "1" "$(wc -l < "$WORK/sent.log" | tr -d ' ')"
has "notify targets the leg session and names the action" '^HIMMEL-5969-N2362-succession-wake-once-2026-10-16 .*merge' "$(cat "$WORK/sent.log")"

[ "$fails" -eq 0 ] && { echo "ALL PASS"; exit 0; }
echo "$fails FAILED"; exit 1
