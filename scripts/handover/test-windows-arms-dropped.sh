#!/usr/bin/env bash
# test-windows-arms-dropped.sh -- the handover scheduling scripts and uninstall
# carry no Windows arm (schtasks, tasklist, USERPROFILE, cygpath, a `windows)`
# case arm or PLATFORM=windows seam, MSYS path coercion).
# Windows is dropped. Pins the Windows-leftover audit grep over those files:
# only arm-resume.sh's historical `claude.exe` comment (a true comment) may
# still match. Not pinned: prose mentions of Windows or Git Bash in comments
# and the drive-letter case arms of the uninstall drive-root guard.
set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
cd "$REPO_ROOT" || exit 1

FILES="scripts/handover/arm-resume.sh scripts/handover/auto-commit.sh scripts/handover/breadcrumb.sh scripts/handover/hop.sh scripts/handover/probe-arm-resume.sh scripts/handover/queue-lock.sh scripts/handover/reconcile-workers.sh scripts/handover/schedule-resume.sh scripts/handover/worker-timeline.sh scripts/lib/handover-path.sh scripts/lib/scheduler-backend.sh scripts/uninstall.sh"
# shellcheck disable=SC2086  # FILES is a word list on purpose
FILES_ARGS=$FILES
AUDIT_RE='\.exe\b|win32|powershell|pwsh|\.ps1\b|cygwin|msys|mingw'
TOOLS_RE='schtasks|tasklist|USERPROFILE|cygpath|PLATFORM=windows|:[0-9]+:[[:space:]]*windows\)|win\(\)'

FAILED=0
pass() { echo "PASS $1"; }
fail() { echo "FAIL $1"; FAILED=$((FAILED + 1)); }

# scan <regex> <file...> -- sets SCAN_OUT to the matching lines. A grep that
# errors (rc 2, e.g. an unreadable file) fails the run: it must not read as
# "no match".
scan() {
    local re="$1" rc
    shift
    SCAN_OUT=$(grep -n -i -E "$re" "$@")
    rc=$?
    if [ "$rc" -ge 2 ]; then
        fail "grep errored (rc=$rc) on: $*"
        SCAN_OUT=""
    fi
}

# 0. Every audited file exists and both matchers see a known hit: a rename or
# a broken matcher must not turn the greps below vacuous.
for f in $FILES; do
    if [ ! -f "$f" ]; then fail "W0 audited file missing: $f"; fi
done
ctl=$(printf 'run powershell\nschtasks /create\nf.sh:12:    windows) x ;;\nf.sh:13: on Windows)\nplain\n' | grep -c -i -E "$AUDIT_RE|$TOOLS_RE")
if [ "$ctl" = 3 ]; then
    pass "W0 the matchers hit known Windows lines and skip plain and prose ones"
else
    fail "W0 matcher control saw $ctl hit(s), want 3"
fi

# 1. The audit grep: nothing but arm-resume.sh's true comment.
# shellcheck disable=SC2086
scan "$AUDIT_RE" $FILES_ARGS
hits=$(printf '%s\n' "$SCAN_OUT" | grep -v -E '^scripts/handover/arm-resume\.sh:[0-9]+:# .claude\.exe \.\.\. OVERNITE MODE. session mid-chain\. It was found still armed$' | grep . || true)
if [ -z "$hits" ]; then
    pass "W1 the audit grep returns no Windows line (arm-resume.sh's claude.exe comment aside)"
else
    fail "W1 the audit grep still hits: $(printf '%s\n' "$hits" | grep -c .) line(s)"
    printf '%s\n' "$hits" | sed 's/^/    /'
fi

# 2. No schtasks / tasklist / USERPROFILE / cygpath / windows-arm shape in the
# files (arm-resume.sh keeps one historical comment; handover-path.sh keeps one
# line that still reaps the legacy `cygpath-avail` cache file name).
# shellcheck disable=SC2086
scan "$TOOLS_RE" $FILES_ARGS
more=$(printf '%s\n' "$SCAN_OUT" | grep -v -E -e '^scripts/handover/arm-resume\.sh:[0-9]+:# A hand-run repro created a real schtasks entry pointing at a$' -e '^scripts/lib/handover-path\.sh:[0-9]+:[[:space:]]+identity\|cygpath-avail\) ;;[[:space:]]+# cygpath-avail: legacy cache file, still reaped$' | grep . || true)
if [ -z "$more" ]; then
    pass "W2 no schtasks, tasklist, USERPROFILE or cygpath remains"
else
    fail "W2 Windows tool names remain: $(printf '%s\n' "$more" | grep -c .) line(s)"
    printf '%s\n' "$more" | sed 's/^/    /'
fi

# 3. The scheduler backend no longer maps a Windows OSTYPE to a backend.
got=$(env -u SCHEDULER_BACKEND_OS bash -c 'source scripts/lib/scheduler-backend.sh; OSTYPE=msys; scheduler_backend_os')
if [ "$got" = unknown ]; then
    pass "W3 OSTYPE=msys is an unknown scheduler OS"
else
    fail "W3 OSTYPE=msys mapped to '$got', want unknown"
fi

if [ "$FAILED" -gt 0 ]; then
    echo "---"
    echo "FAIL $FAILED case(s)"
    exit 1
fi
echo "---"
echo "ALL PASS"
