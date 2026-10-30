#!/usr/bin/env bash
# test-windows-arms-dropped.sh -- the handover scheduling scripts and uninstall
# carry no Windows arm (schtasks, tasklist, USERPROFILE, MSYS path coercion).
# Windows is dropped. Pins the Windows-leftover audit grep over those files:
# only arm-resume.sh's historical `claude.exe` comment (a true comment) may
# still match.
set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
cd "$REPO_ROOT" || exit 1

FILES="scripts/handover/arm-resume.sh scripts/handover/auto-commit.sh scripts/handover/breadcrumb.sh scripts/handover/hop.sh scripts/handover/probe-arm-resume.sh scripts/handover/queue-lock.sh scripts/handover/reconcile-workers.sh scripts/handover/schedule-resume.sh scripts/handover/worker-timeline.sh scripts/lib/handover-path.sh scripts/lib/scheduler-backend.sh scripts/uninstall.sh"
# shellcheck disable=SC2086  # FILES is a word list on purpose
FILES_ARGS=$FILES

FAILED=0
pass() { echo "PASS $1"; }
fail() { echo "FAIL $1"; FAILED=$((FAILED + 1)); }

# 1. The audit grep: nothing but arm-resume.sh's true comment.
# shellcheck disable=SC2086
hits=$(grep -n -i -E '\.exe\b|win32|powershell|pwsh|\.ps1\b|cygwin|msys|mingw' $FILES_ARGS | grep -v -F 'scripts/handover/arm-resume.sh:' || true)
arm_hits=$(grep -n -i -E '\.exe\b|win32|powershell|pwsh|\.ps1\b|cygwin|msys|mingw' scripts/handover/arm-resume.sh | grep -v -F 'claude.exe ... OVERNITE MODE' || true)
if [ -z "$hits" ] && [ -z "$arm_hits" ]; then
    pass "W1 the audit grep returns no Windows line (arm-resume.sh's claude.exe comment aside)"
else
    fail "W1 the audit grep still hits: $(printf '%s\n%s' "$hits" "$arm_hits" | grep -c .) line(s)"
    printf '%s\n%s\n' "$hits" "$arm_hits" | grep . | sed 's/^/    /'
fi

# 2. No schtasks / tasklist / USERPROFILE / cygpath in the files (arm-resume.sh
# keeps one historical schtasks comment; handover-path.sh keeps one line that
# still reaps the legacy `cygpath-avail` cache file name).
# shellcheck disable=SC2086
more=$(grep -n -i -E 'schtasks|tasklist|USERPROFILE|cygpath' $FILES_ARGS | grep -v -F 'scripts/handover/arm-resume.sh:' | grep -v -F 'legacy cache file, still reaped' || true)
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
