#!/usr/bin/env bash
# Weekly, read-only inventory of existing security findings.
# OFF until armed. No scanner/LLM is run and no vendor subscription is changed.
# run [--repo owner/name|path]; arm [--day 0-6] [--time HH:MM] [--force] [--dry-run]; status; disarm [--dry-run]
# Configuration (non-secret): SECURITY_AUDIT_{EXPORT_DIR,SNYK_DIR,STATE_DIR},
# SECURITY_AUDIT_GITHUB=off, SECURITY_AUDIT_CODERABBIT=off, SECURITY_AUDIT_CODERABBIT_REPO_ID.
# CodeRabbit's optional read API uses himmel-secrets get --no-dotenv CODERABBIT_API_KEY.
# Export fallback: <EXPORT_DIR>/{arnica,coderabbit}.csv. See docs/cadences.md.
# Seams: SECURITY_AUDIT_CRONTAB, SECURITY_AUDIT_RUNNER_DIR; CADENCE_ALERT_*.
# Exit: 0 successful report (including skipped sources), 2 local IO/config failure,
# 3 already armed, 4 scheduler write failure, 64 usage. Cron: Linux/macOS.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TASK_NAME=HIMMEL-SecurityAudit
CRONTAB_BIN="${SECURITY_AUDIT_CRONTAB:-crontab}"
RUNNER_DIR="${SECURITY_AUDIT_RUNNER_DIR:-$HOME/.claude/security-audit-cadence}"

resolve_primary() {
    local common
    common="$(git -C "$SCRIPT_DIR" rev-parse --path-format=absolute --git-common-dir)" || return 1
    dirname "$common"
}

cmd_run() {
    local repo="" primary snyk_dir="${SECURITY_AUDIT_SNYK_DIR:-}" root scope rc
    if [ "${1:-}" = --repo ] && [ $# -eq 2 ]; then repo="$2"
    elif [ $# -ne 0 ]; then echo 'Usage: security-audit-cadence.sh run [--repo owner/name|path]' >&2; return 64; fi
    primary="$(resolve_primary)" || return 2
    [ -n "$repo" ] || repo="$primary"
    if [ -z "$snyk_dir" ]; then
        # Same bucket as snyk-scan.sh; read the existing report, never invoke the scanner.
        # shellcheck source=../lib/handover-path.sh
        . "$SCRIPT_DIR/../lib/handover-path.sh" || return 2
        # shellcheck source=../lib/go-gate.sh
        . "$SCRIPT_DIR/../lib/go-gate.sh" || return 2
        root="$(handover_root 2>/dev/null)" && scope="$(go_verdict_scope "$primary" 2>/dev/null)" && snyk_dir="$root/$scope/specs/security/snyk"
    fi
    python3 -I - "$repo" "$SCRIPT_DIR" "$snyk_dir" <<'PY'
import csv
from datetime import datetime, timezone
import fcntl
import hashlib
import html
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import urllib.parse
import urllib.request

repo, script_dir, snyk_dir = sys.argv[1:]

def command(argv):
    return subprocess.check_output(argv, stderr=subprocess.DEVNULL, text=True, timeout=90)

def repository(value):
    if Path(value).is_dir():
        value = command(['git', '-C', value, 'remote', 'get-url', 'origin']).strip()
    match = re.fullmatch(r'(?:https://github\.com/|git@github\.com:)([^/]+/[^/]+?)(?:\.git)?/?', value)
    if match:
        value = match[1]
    if not re.fullmatch(r'[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+', value):
        raise ValueError('expected a GitHub origin or owner/name')
    return value.lower()

repo = repository(repo)
state_dir = Path(os.environ.get('SECURITY_AUDIT_STATE_DIR', str(Path.home() / '.himmel/state/security-audit' / repo)))
state_dir.mkdir(parents=True, exist_ok=True, mode=0o700)
lock = (state_dir / 'run.lock').open('a')
try:
    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
except BlockingIOError:
    print('SKIP security-audit: another run owns this state')
    sys.exit(0)
state_file = state_dir / 'state.json'
previous = json.loads(state_file.read_text()) if state_file.exists() else {'repo': repo, 'sources': {}}
if previous['repo'] != repo:
    sys.exit('ERR security-audit: state belongs to a different repository; use a separate STATE_DIR')
sources = dict(previous['sources'])
messages = []

class Skip(Exception):
    pass

def text(value):
    return ''.join(c for c in str(value or '') if c.isprintable())[:500]

def row(file, line, category, severity):
    file = text(file).replace('\\', '/')
    if '/blob/' in file:
        tail = file.split('/blob/', 1)[1]
        file = tail.split('/', 1)[1] if '/' in tail else tail
    fragment = re.search(r'#L(\d+)', file)
    if fragment:
        line = fragment[1]
    file = file.split('#', 1)[0]
    while file.startswith('./'):
        file = file[2:]
    severity = text(severity).lower()
    severity = {'moderate': 'medium', 'error': 'high', 'warning': 'medium'}.get(severity, severity)
    if severity not in ('critical', 'high', 'medium', 'low', 'unknown'):
        severity = 'unknown'
    try:
        line = max(0, int(line or 0))
    except (ValueError, TypeError):
        raise Skip('invalid location') from None
    if not file or not category:
        raise Skip('incomplete findings')
    return {'file': file, 'line': line, 'category': text(category).lower(), 'severity': severity}

def collect(name, adapter):
    try:
        findings = adapter()
        sources[name] = findings
        messages.append(f'OK {name}: {len(findings)} open rows')
    except (Skip, OSError, ValueError, TypeError, KeyError, AttributeError, IndexError, csv.Error, subprocess.SubprocessError):
        # Never print API bodies, exception text or CSV descriptions (may hold secrets).
        messages.append(f'SKIP {name}: off, unavailable, quota-limited or invalid input; baseline retained')

def pages(endpoint):
    data = json.loads(command(['gh', 'api', '--method', 'GET', '--paginate', '--slurp', endpoint]))
    if not isinstance(data, list) or not all(isinstance(p, list) for p in data):
        raise Skip('incomplete pagination')
    return [item for page in data for item in page]

def github(kind):
    if os.environ.get('SECURITY_AUDIT_GITHUB') == 'off':
        raise Skip('off')
    result = []
    for item in pages(f'repos/{repo}/{kind}/alerts?state=open&per_page=100'):
        if item['state'] not in ('open', 'fixed', 'resolved', 'dismissed', 'auto_dismissed'):
            raise Skip('unknown alert state')
        if item['state'] != 'open':
            continue
        if kind == 'code-scanning':
            loc = item['most_recent_instance']['location']
            rule = item['rule']
            result.append(row(loc['path'], loc.get('start_line'), rule['id'],
                              rule.get('security_severity_level') or rule.get('severity')))
        elif kind == 'dependabot':
            advisory = item['security_advisory']
            result.append(row(item['dependency']['manifest_path'], 0,
                              advisory['ghsa_id'], advisory['severity']))
        else:
            # Ignore .secret and all messages. Only GET locations within this repo.
            url = item['locations_url']
            prefix = f'https://api.github.com/repos/{repo}/secret-scanning/alerts/'
            if not url.lower().startswith(prefix) or not re.fullmatch(r'\d+/locations', url[len(prefix):]):
                raise Skip('unexpected location URL')
            for loc in pages(url.removeprefix('https://api.github.com/') + '?per_page=100'):
                details = loc.get('details', {})
                result.append(row(details.get('path', '(non-file secret)'), details.get('start_line'),
                                  item['secret_type'], 'high'))
    return result

def matches_repo(value):
    value = text(value).lower().removeprefix('github://').split('#', 1)[0]
    return value in (repo, repo.split('/')[1])

export_dir = Path(os.environ.get('SECURITY_AUDIT_EXPORT_DIR', str(Path.home() / '.himmel/security-exports')))

def exported(name):
    with (export_dir / f'{name}.csv').open(newline='', encoding='utf-8-sig') as f:
        reader = csv.DictReader(f)
        fields = {s.lower() for s in (reader.fieldnames or [])}
        if not {'severity', 'file'} <= fields or not ({'state', 'status'} & fields) or not ({'category', 'type', 'cwe'} & fields):
            raise Skip('unknown export headers')
        result = []
        for raw in reader:
            item = {k.lower(): v for k, v in raw.items() if k is not None}
            state = (item.get('state') or item.get('status') or '').lower()
            if state not in ('open', 'closed', 'fixed', 'resolved', 'dismissed', 'ignored', 'suppressed'):
                raise Skip('missing or unknown finding state')
            if state != 'open':
                continue
            target = item.get('repository') or item.get('asset')
            if not target:
                raise Skip('missing repository')
            if not matches_repo(target):
                continue
            result.append(row(item['file'], item.get('start_line'),
                              item.get('cwe') or item.get('category') or item.get('type'), item['severity']))
        return result

def coderabbit():
    if (export_dir / 'coderabbit.csv').exists():
        return exported('coderabbit')
    if os.environ.get('SECURITY_AUDIT_CODERABBIT') == 'off':
        raise Skip('off')
    # Require an exact provider repo ID: never read the entire key's workspace.
    repo_id = os.environ.get('SECURITY_AUDIT_CODERABBIT_REPO_ID', '')
    if not re.fullmatch(r'[0-9]+', repo_id):
        raise Skip('no repo id')
    secret = command(['bash', str(Path(script_dir).parent / 'lib/himmel-secrets'),
                      'get', '--no-dotenv', 'CODERABBIT_API_KEY']).strip()
    if not secret.startswith('CODERABBIT_API_KEY='):
        raise Skip('no key')
    key = secret.split('=', 1)[1]
    result, cursor, seen = [], '', set()
    # Fixed HTTPS origin, no redirected credential-bearing requests.
    class NoRedirect(urllib.request.HTTPRedirectHandler):
        def redirect_request(self, req, fp, code, msg, headers, newurl):
            return None
    opener = urllib.request.build_opener(NoRedirect)
    while True:
        query = urllib.parse.urlencode({'repo_id': repo_id, 'state': 'open', 'limit': 1000, 'cursor': cursor})
        request = urllib.request.Request('https://api.coderabbit.ai/v1/security/scans/code?' + query,
                                         headers={'x-coderabbitai-api-key': key})
        with opener.open(request, timeout=30) as response:
            data = json.load(response)
        if not isinstance(data['data'], list) or 'next_cursor' not in data:
            raise Skip('incomplete page')
        for item in data['data']:
            if str(item['repository_id']) != repo_id:
                raise Skip('wrong repository')
            if item['state'] not in ('open', 'fixed', 'dismissed'):
                raise Skip('unknown finding state')
            if item['state'] == 'open':
                result.append(row(item['file_path'], item.get('start_line'), item.get('cwe') or 'code', item['severity']))
        cursor = data['next_cursor']
        if cursor is None:
            return result
        if not isinstance(cursor, str) or not cursor or cursor in seen or len(seen) >= 1000:
            raise Skip('invalid pagination')
        seen.add(cursor)

for name, kind in [('github-code', 'code-scanning'), ('github-dependabot', 'dependabot'), ('github-secret', 'secret-scanning')]:
    collect(name, lambda kind=kind: github(kind))

# A failed/disabled Code component is retained independently of a successful OS report.
def snyk():
    files = sorted(Path(snyk_dir).glob('????-??-??.json')) if snyk_dir else []
    if not files:
        raise Skip('no existing report')
    data = json.loads(files[-1].read_text())
    if repository(data['repo']) != repo:
        raise Skip('report belongs to a different repository')
    projects = data['open_source']
    if not isinstance(projects, list):
        raise Skip('invalid report')
    result = []
    for project in projects:
        for item in project['vulnerabilities']:
            result.append(row(project.get('displayTargetFile') or project.get('path'), 0, item['id'], item['severity']))
    if data['code_status'] == 'ok':
        code_rows = []
        for run in data['code']['runs']:
            for item in run.get('results', []):
                loc = item['locations'][0]['physicalLocation']
                code_rows.append(row(loc['artifactLocation']['uri'], loc.get('region', {}).get('startLine'),
                                     item['ruleId'], item.get('level', 'warning')))
        sources['snyk-code'] = code_rows
    else:
        messages.append('SKIP snyk-code: existing report marks Code off, failed or over quota; baseline retained')
    return result

collect('snyk', snyk)
collect('arnica', lambda: exported('arnica'))
collect('coderabbit', coderabbit)

RANK = {'unknown': 0, 'low': 1, 'medium': 2, 'high': 3, 'critical': 4}

def inventory(by_source):
    result = {}
    for source, findings in by_source.items():
        for finding in findings:
            identity = (finding['file'], finding['line'], finding['category'])
            if identity not in result:
                result[identity] = dict(finding, sources=[])
            merged = result[identity]
            merged['sources'].append(source)
            if RANK[finding['severity']] > RANK[merged['severity']]:
                merged['severity'] = finding['severity']
    for finding in result.values():
        finding['sources'] = sorted(set(finding['sources']))
    return result

old, current = inventory(previous['sources']), inventory(sources)
new = sorted(current.keys() - old.keys())
closed = sorted(old.keys() - current.keys())
# An existing row promoted to High/Critical also deserves an alert.
escalated = [k for k in current.keys() & old.keys() if RANK[current[k]['severity']] >= 3 and RANK[old[k]['severity']] < RANK[current[k]['severity']]]
high = [k for k in new + escalated if RANK[current[k]['severity']] >= 3]
now = datetime.now(timezone.utc).strftime('%Y-%m-%dT%H%M%S.%fZ')
reports = state_dir / 'reports'
reports.mkdir(exist_ok=True, mode=0o700)
report = reports / (now + '.md')
lines = [f'# Security audit {now}', '', f'Repository: {repo}', '', f'New: {len(new)}; Closed: {len(closed)}', '', *messages, '']
for title, identities, table in [('New', new, current), ('Newly closed', closed, old), ('Severity escalations', sorted(escalated), current)]:
    lines.extend(['## ' + title, ''])
    for identity in identities:
        f = table[identity]
        # Render untrusted locations as HTML-escaped plain code, never links/markup.
        fields = [f['severity'], f['file'], str(f['line']), f['category'], ', '.join(f['sources'])]
        lines.append('- ' + ' | '.join('<code>' + html.escape(v) + '</code>' for v in fields))
    if not identities:
        lines.append('None.')
    lines.append('')
report.write_text('\n'.join(lines))
print('\n'.join(messages))
print(f'security-audit: New: {len(new)}; Closed: {len(closed)}; report: {report}')
alert = str(Path(script_dir).parent / 'luna/cadence-alert.sh')
if high:
    fingerprint = hashlib.sha256(json.dumps([(k, current[k]['severity']) for k in sorted(high)]).encode()).hexdigest()[:16]
    env = dict(os.environ, CADENCE_ALERT_EXIT_ON_SEND_FAIL='1')
    subprocess.run(['bash', alert, 'fail', 'security-audit', f'{len(high)} new-high-critical-{fingerprint}',
                    str(report), 'new or escalated security findings', 'review the dated report'], env=env, check=True)
else:
    subprocess.run(['bash', alert, 'clear', 'security-audit'], check=True)
# Commit the baseline only after report and notification IO have succeeded.
staged = state_dir / 'state.json.tmp'
with staged.open('w') as f:
    os.chmod(staged, 0o600)
    json.dump({'repo': repo, 'sources': sources}, f, sort_keys=True)
os.replace(staged, state_file)
PY
    rc=$?
    [ "$rc" -eq 0 ] || return 2
}

cron_read() {
    CRON_TAB=""
    command -v "$CRONTAB_BIN" >/dev/null 2>&1 || return 0
    if CRON_TAB="$(LC_ALL=C "$CRONTAB_BIN" -l 2>&1)"; then return 0; fi
    case "$CRON_TAB" in *'no crontab'*) CRON_TAB="" ;; *) echo 'ERR security-audit: cannot read crontab' >&2; return 1 ;; esac
}
cron_entry() { printf '%s\n' "$CRON_TAB" | grep -F "# $TASK_NAME" || true; }

cmd_arm() {
    local day=1 time=07:00 dry=0 force=0 root runner entry name value
    while [ $# -gt 0 ]; do
        case "$1" in
            --day|--time)
                [ $# -ge 2 ] || return 64
                case "$1" in --day) day="$2" ;; --time) time="$2" ;; esac; shift 2 ;;
            --force) force=1; shift ;;
            --dry-run) dry=1; shift ;;
            *) return 64 ;;
        esac
    done
    [[ "$day" =~ ^[0-6]$ ]] && [[ "$time" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]] || return 64
    case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) echo 'ERR security-audit: cron only' >&2; return 2 ;; esac
    command -v "$CRONTAB_BIN" >/dev/null 2>&1 || return 2
    root="$(resolve_primary)" || return 2
    cron_read || return 4
    [ -z "$(cron_entry)" ] || [ "$force" -eq 1 ] || return 3
    runner="$RUNNER_DIR/security-audit-cadence.sh"
    printf -v entry '%q' "$runner"
    entry="${time#*:} ${time%:*} * * $day ${entry//%/\\%} # $TASK_NAME"
    if [ "$dry" -eq 1 ]; then printf 'DRY security-audit: %s\n' "$entry"; return 0; fi
    mkdir -p "$RUNNER_DIR" || return 4
    {
        printf '#!/usr/bin/env bash\n'
        printf 'export PATH=%q\n' "$PATH"
        for name in HANDOVER_DIR SECURITY_AUDIT_EXPORT_DIR SECURITY_AUDIT_SNYK_DIR SECURITY_AUDIT_STATE_DIR SECURITY_AUDIT_GITHUB SECURITY_AUDIT_CODERABBIT SECURITY_AUDIT_CODERABBIT_REPO_ID; do
            value="${!name:-}"
            [ -z "$value" ] || printf 'export %s=%q\n' "$name" "$value"
        done
        printf 'cd %q || exit 2\n' "$root"
        printf '%q %q run >> %q 2>&1\n' "$(command -v bash)" "$root/scripts/security/security-audit-cadence.sh" "$RUNNER_DIR/last-run.log"
    } > "$runner" || return 4
    chmod 700 "$runner" || return 4
    { printf '%s\n' "$CRON_TAB" | { grep -vF "# $TASK_NAME" || true; } | sed '/^$/d'; printf '%s\n' "$entry"; } | "$CRONTAB_BIN" - || return 4
    echo "security-audit ARMED: weekly day $day $time"
}

cmd_status() {
    cron_read || return 1
    if [ -n "$(cron_entry)" ]; then printf 'ARMED %s\n' "$(cron_entry)"
    else printf 'not armed %s\n' "$TASK_NAME"; fi
    [ ! -f "$RUNNER_DIR/last-run.log" ] || printf 'last run: %s\n' "$RUNNER_DIR/last-run.log"
    return 0
}

cmd_disarm() {
    [ $# -eq 0 ] || { [ $# -eq 1 ] && [ "$1" = --dry-run ]; } || return 64
    cron_read || return 4
    [ -n "$(cron_entry)" ] || { echo 'security-audit: nothing armed'; return 0; }
    if [ "${1:-}" = --dry-run ]; then echo 'DRY security-audit: would disarm'; return 0; fi
    { printf '%s\n' "$CRON_TAB" | grep -vF "# $TASK_NAME" || true; } | "$CRONTAB_BIN" - || return 4
    rm -f "$RUNNER_DIR/security-audit-cadence.sh"
    echo 'security-audit: disarmed'
}

sub="${1:-}"; [ $# -eq 0 ] || shift
case "$sub" in
    run) cmd_run "$@" ;;
    arm) cmd_arm "$@" ;;
    status) [ $# -eq 0 ] && cmd_status ;;
    disarm) cmd_disarm "$@" ;;
    *) echo 'Usage: security-audit-cadence.sh <run|arm|status|disarm>' >&2; exit 64 ;;
esac
