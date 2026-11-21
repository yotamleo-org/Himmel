#!/usr/bin/env bash
set -u
HERE="$(cd "$(dirname "$0")" && pwd -P)"
python3 -I - "$HERE" <<'PY' || exit 1
import sys
W = sys.argv[1] + '/'
s = open(W + 'test-arm-resume.sh').read()
start = s.index('HOME="$POLICY_EMPTY_HOME" bash "$(dirname "$ARM")/chief-kit/fleet-manifest.sh" control init')
endmark = 't32p_cl "T32 pause (crontab): that runner does not launch claude" no\nassert_contains "T32 pause (crontab): that runner\'s refusal names the pause" "pause" "$T32P_CLOG"\n'
end = s.index(endmark) + len(endmark)
new = ('if ! command -v flock >/dev/null 2>&1; then\n'
       '    echo "SKIP T32 pause (crontab): joining a paused family needs fleet-manifest.sh, a Linux-only kit (util-linux flock)"\n'
       'else\n' + s[start:end] + 'fi\n')
s = s[:start] + new + s[end:]
s = s.replace('printf \'%s\\n\' "$T32P_BODY" | sed -n', 'printf \'%s\\n\' "${T32P_BODY:-}" | sed -n')
open(W + 'test-arm-resume-dpatched.sh', 'w').write(s)
f = open(W + 'test-arm-resume-fast.sh').read()
open(W + 'test-arm-resume-fast-dpatched.sh', 'w').write(f.replace('bash test-arm-resume.sh', 'bash test-arm-resume-dpatched.sh'))
PY
bash "$HERE/test-arm-resume-fast-dpatched.sh"
