#!/usr/bin/env bash
# Real runs against exports; only external gh/cron/notification IO is stubbed.
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
python3 -I - "$here/security-audit-cadence.sh" <<'PY'
import csv
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

SCRIPT = Path(sys.argv.pop())

class Audit(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.exports = self.root / 'exports'
        self.exports.mkdir()
        self.bin = self.root / 'bin'
        self.bin.mkdir()
        self.env = dict(os.environ, HOME=str(self.root),
                        SECURITY_AUDIT_STATE_DIR=str(self.root / 'state'),
                        SECURITY_AUDIT_EXPORT_DIR=str(self.exports),
                        SECURITY_AUDIT_SNYK_DIR=str(self.root / 'snyk'),
                        SECURITY_AUDIT_GITHUB='off', SECURITY_AUDIT_CODERABBIT='off',
                        SECURITY_AUDIT_CRONTAB=str(self.bin / 'crontab'),
                        SECURITY_AUDIT_RUNNER_DIR=str(self.root / 'runner'),
                        CADENCE_ALERT_FILE=str(self.root / 'alerts'),
                        CADENCE_ALERT_DEDUPE_DIR=str(self.root / 'sent'),
                        CADENCE_ALERT_SEND_FAILED_MARK=str(self.root / 'send-failed'),
                        CADENCE_ALERT_SEND_CMD=str(self.bin / 'notify'),
                        PATH=str(self.bin) + os.pathsep + os.environ['PATH'])
        self.executable('notify', '#!/bin/sh\nprintf "%s\\n" "$*" >> "$HOME/notified"\n')
        self.executable('crontab', '#!/bin/sh\nif [ "$1" = -l ]; then\n  if [ -f "$HOME/cron" ]; then cat "$HOME/cron"; else echo "no crontab" >&2; exit 1; fi\nelse cat > "$HOME/cron"; fi\n')

    def executable(self, name, text):
        p = self.bin / name
        p.write_text(text)
        p.chmod(0o700)

    def run_audit(self, *args):
        proc = subprocess.run(['bash', str(SCRIPT), *args], env=self.env,
                              text=True, capture_output=True, timeout=20)
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        return proc.stdout

    def run_once(self):
        return self.run_audit('run', '--repo', 'example/project')

    def report(self):
        reports = sorted((self.root / 'state' / 'reports').glob('*.md'))
        self.assertTrue(reports, 'run must write a dated report')
        return reports[-1].read_text()

    def export(self, name='coderabbit', rows=None):
        if rows is None:
            rows = [('project', 'src/a.py', '9', 'CWE-79', 'high', 'open')]
        with (self.exports / (name + '.csv')).open('w', newline='') as f:
            w = csv.writer(f)
            w.writerow(['repository', 'file', 'start_line', 'cwe', 'severity', 'state'])
            w.writerows(rows)

    # A source's missing/unknown state is not evidence that an old finding closed.
    def test_unknown_csv_state_retains_baseline(self):
        self.export()
        self.run_once()
        self.export(rows=[('project', 'src/a.py', '9', 'CWE-79', 'high', '')])
        self.assertIn('SKIP coderabbit', self.run_once())
        self.assertIn('New: 0; Closed: 0', self.report())

    # Repository override must not inherit a different checkout's Snyk inventory.
    def test_snyk_report_repository_binding(self):
        d = self.root / 'snyk'
        d.mkdir()
        data = {'repo': 'other/project', 'code_status': 'quota', 'code': None,
                'open_source': [{'displayTargetFile': 'package-lock.json',
                                 'vulnerabilities': [{'id': 'GHSA-123', 'severity': 'critical'}]}]}
        (d / '2026-10-30.json').write_text(json.dumps(data))
        self.assertIn('SKIP snyk:', self.run_once())
        self.assertIn('New: 0; Closed: 0', self.report())

    # Promotions between alerting severities still need a fresh notification.
    def test_high_to_critical_promotion(self):
        self.export()
        self.run_once()
        self.export(rows=[('project', 'src/a.py', '9', 'CWE-79', 'critical', 'open')])
        self.run_once()
        self.assertEqual(len((self.root / 'notified').read_text().splitlines()), 2)
        self.assertIn('<code>critical</code>', self.report().split('## Severity escalations')[1])

    # The shell's documented IO failure code must not depend on a Python traceback.
    def test_local_io_error_exit_code(self):
        target = self.root / 'not-a-directory'
        target.write_text('occupied')
        self.env['SECURITY_AUDIT_STATE_DIR'] = str(target)
        proc = subprocess.run(['bash', str(SCRIPT), 'run', '--repo', 'example/project'],
                              env=self.env, text=True, capture_output=True, timeout=20)
        self.assertEqual(proc.returncode, 2, proc.stdout + proc.stderr)

    # Missing adapters must not turn an optional cadence into a failing job.
    def test_no_scanner(self):
        out = self.run_once()
        for source in ('github-code', 'github-dependabot', 'github-secret',
                       'snyk', 'arnica', 'coderabbit'):
            self.assertIn('SKIP ' + source, out)
        self.assertIn('New: 0; Closed: 0', self.report())

    # Losing stable identity would make the second run re-alert on the same finding.
    def test_repeat_run(self):
        self.export()
        self.run_once()
        self.assertIn('New: 1; Closed: 0', self.report())
        self.run_once()
        self.assertIn('New: 0; Closed: 0', self.report())
        self.assertEqual(len((self.root / 'notified').read_text().splitlines()), 1)

    # A new High row must be reported/notified, and its later closure reported once.
    def test_new_and_closed(self):
        self.export(rows=[])
        self.run_once()
        self.export()
        self.run_once()
        self.assertIn('New: 1; Closed: 0', self.report())
        self.assertTrue((self.root / 'notified').exists())
        self.export(rows=[])
        self.run_once()
        self.assertIn('New: 0; Closed: 1', self.report())
        self.run_once()
        self.assertIn('New: 0; Closed: 0', self.report())

    # Disabling, deleting or corrupting a source is not evidence of closure.
    def test_skip_preserves_baseline(self):
        self.export()
        self.run_once()
        (self.exports / 'coderabbit.csv').write_text('wrong,headers\n1,2\n')
        self.assertIn('SKIP coderabbit', self.run_once())
        self.assertIn('New: 0; Closed: 0', self.report())
        self.export()
        self.run_once()
        self.assertIn('New: 0; Closed: 0', self.report())

    # Duplicate reports from different sources must merge, not double-count or close early.
    def test_cross_source_dedup(self):
        self.export()
        self.export('arnica')
        self.run_once()
        self.assertIn('New: 1; Closed: 0', self.report())
        self.assertIn('arnica, coderabbit', self.report())
        self.export(rows=[])
        self.run_once()
        self.assertIn('New: 0; Closed: 0', self.report())

    # Real export URL locations normalize; CSV text is never executed or interpolated.
    def test_arnica_url_and_untrusted_csv(self):
        with (self.exports / 'arnica.csv').open('w', newline='') as f:
            w = csv.writer(f)
            w.writerow(['Severity', 'Status', 'Asset', 'File', 'Type', 'Description'])
            w.writerow(['High', 'Open', 'github://example/project#main',
                        'https://github.com/example/project/blob/abc/src/a.py#L9',
                        'License', '$(touch PWNED)\n"untrusted"'])
        self.run_once()
        report = self.report()
        self.assertIn('src/a.py', report)
        self.assertIn('New: 1; Closed: 0', report)
        self.assertNotIn('touch PWNED', report)
        self.assertFalse((self.root / 'PWNED').exists())

    # Multi-repository exports must not attribute unrelated findings to this repo.
    def test_repository_filter(self):
        self.export(rows=[('other', 'src/a.py', '9', 'CWE-79', 'high', 'open')])
        self.run_once()
        self.assertIn('New: 0; Closed: 0', self.report())

    # Reading Snyk's existing report must spend zero new tests, including quota skips.
    def test_snyk_report(self):
        d = self.root / 'snyk'
        d.mkdir()
        data = {'repo': 'example/project', 'code_status': 'quota', 'code': None,
                'open_source': [{'displayTargetFile': 'package-lock.json',
                                 'vulnerabilities': [{'id': 'GHSA-123', 'severity': 'critical'}]}]}
        (d / '2026-10-30.json').write_text(json.dumps(data))
        self.executable('snyk', '#!/bin/sh\ntouch "$HOME/SCAN-CALLED"; exit 99\n')
        out = self.run_once()
        self.assertIn('SKIP snyk-code', out)
        self.assertIn('New: 1; Closed: 0', self.report())
        self.assertFalse((self.root / 'SCAN-CALLED').exists())

    # A GitHub API failure or incomplete pagination must not fabricate closures.
    def test_github_reads_and_failure(self):
        self.env['SECURITY_AUDIT_GITHUB'] = 'on'
        self.executable('gh', '''#!/bin/sh
case "$*" in
  *code-scanning/alerts*)
    [ ! -f "$HOME/api-off" ] || exit 1
    printf '%s\\n' '[[{"state":"open","rule":{"id":"CWE-79","security_severity_level":"high"},"most_recent_instance":{"location":{"path":"src/a.py","start_line":9}}}]]' ;;
  *dependabot/alerts*) printf '%s\\n' '[[{"state":"open","dependency":{"manifest_path":"package-lock.json"},"security_advisory":{"ghsa_id":"GHSA-123","severity":"critical"}}]]' ;;
  *secret-scanning/alerts*) printf '%s\\n' '[[{"state":"open","secret_type":"token","secret":"DO-NOT-PERSIST","locations_url":"https://api.github.com/repos/example/project/secret-scanning/alerts/1/locations"}]]' ;;
  *alerts/1/locations*) printf '%s\\n' '[[{"type":"commit","details":{"path":"src/secret.py","start_line":4}}]]' ;;
  *) exit 90 ;;
esac
''')
        self.run_once()
        self.assertIn('New: 3; Closed: 0', self.report())
        self.assertNotIn('DO-NOT-PERSIST', (self.root / 'state' / 'state.json').read_text())
        (self.root / 'api-off').touch()
        self.assertIn('SKIP github-code', self.run_once())
        self.assertIn('New: 0; Closed: 0', self.report())

    # Malformed external rows are unavailable, not a failed job or clean snapshot.
    def test_malformed_github_row(self):
        self.env['SECURITY_AUDIT_GITHUB'] = 'on'
        self.executable('gh', '#!/bin/sh\nprintf \'%s\\n\' \'[[null]]\'\n')
        out = self.run_once()
        self.assertIn('SKIP github-code', out)
        self.assertIn('New: 0; Closed: 0', self.report())

    # Run the embedded production engine; replace only HTTP and keyring IO.
    def test_coderabbit_api_pagination(self):
        self.env['SECURITY_AUDIT_CODERABBIT'] = 'on'
        self.env['SECURITY_AUDIT_CODERABBIT_REPO_ID'] = '42'
        calls = []
        pages = [
            {'data': [{'repository_id': '42', 'state': 'open', 'file_path': 'src/a.py',
                       'start_line': 9, 'cwe': 'CWE-79', 'severity': 'high'}], 'next_cursor': 'next'},
            {'data': [], 'next_cursor': None},
        ]
        def http_open(opener, request, **kwargs):
            calls.append(request)
            return io.BytesIO(json.dumps(pages.pop(0)).encode())
        def read_key(argv, **kwargs):
            self.assertEqual(argv[-3:], ['get', '--no-dotenv', 'CODERABBIT_API_KEY'])
            self.assertNotIn('fixture-key', ' '.join(argv))
            return 'CODERABBIT_API_KEY=fixture-key\n'
        code = SCRIPT.read_text().split("<<'PY'\n", 1)[1].split('\nPY\n', 1)[0]
        with patch.dict(os.environ, self.env, clear=True), \
             patch.object(sys, 'argv', ['audit', 'example/project', str(SCRIPT.parent), '']), \
             patch('subprocess.check_output', side_effect=read_key), \
             patch('urllib.request.OpenerDirector.open', new=http_open), \
             patch('sys.stdout', new=io.StringIO()):
            exec(compile(code, str(SCRIPT), 'exec'), {})
        self.assertEqual(len(calls), 2)
        self.assertIn('repo_id=42', calls[0].full_url)
        self.assertIn('cursor=next', calls[1].full_url)
        self.assertIn('New: 1; Closed: 0', self.report())
        self.assertNotIn('fixture-key', (self.root / 'state' / 'state.json').read_text())

    # A path containing shell syntax must stay a path in the generated cron command.
    def test_schedule_quotes_runner_path(self):
        self.env['SECURITY_AUDIT_RUNNER_DIR'] = str(self.root / 'runner-$(touch INJECTED)')
        self.run_audit('arm')
        entry = (self.root / 'cron').read_text().strip().split(maxsplit=5)[5]
        subprocess.run(['bash', '-c', entry], cwd=self.root, env=self.env,
                       capture_output=True, timeout=20)
        self.assertFalse((self.root / 'INJECTED').exists())

    # Schedule management must preserve unrelated cron entries and start unarmed.
    def test_schedule(self):
        self.assertIn('not armed', self.run_audit('status'))
        (self.root / 'cron').write_text('0 0 * * * /keep-this\n')
        self.run_audit('arm', '--dry-run')
        self.assertNotIn('HIMMEL-SecurityAudit', (self.root / 'cron').read_text())
        self.run_audit('arm')
        self.assertIn('ARMED', self.run_audit('status'))
        self.assertIn('/keep-this', (self.root / 'cron').read_text())
        self.run_audit('disarm')
        self.assertEqual((self.root / 'cron').read_text(), '0 0 * * * /keep-this\n')

unittest.main(verbosity=2)
PY
