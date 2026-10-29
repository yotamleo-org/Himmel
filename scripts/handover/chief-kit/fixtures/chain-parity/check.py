"""Shared, hand-checked registry/readiness fixtures, invoked by both reader suites."""
import copy
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

HERE = Path(__file__).resolve().parent
KIT = HERE.parent.parent
READER = sys.argv[1]
NOW = '2026-11-05T00:00:00Z'
STAMP = 1793836800  # 2026-11-05T00:00:00Z
ENV = dict(os.environ, HIMMEL_FLAG_CHAIN_RENDER='1')
failures = 0


def check(name, actual, expected):
    global failures
    if actual == expected:
        print('ok - registry/%s: %s' % (READER, name))
    else:
        failures += 1
        print('FAIL - registry/%s: %s: got %r, want %r' % (READER, name, actual, expected))


def keys(numbers):
    return sorted('HIMMEL-%s' % n for n in numbers)


def invoke(root, registry=True, mirror=None):
    common = ['--mirror', str(mirror or root / 'mirror'), '--state', str(root / 'state'),
              '--now', NOW, '--version', 'v1.1.3']
    if registry:
        common += ['--registry', str(root / 'registry.json')]
    if READER == 'state':
        cmd = ['node', str(KIT / 'chain-state.mjs'), '--json'] + common
    else:
        cmd = [sys.executable, '-I', str(KIT / 'chain-render.py'), '--graph', str(root / 'graph.json'),
               '--out', str(root / 'out.json')] + common
    result = subprocess.run(cmd, capture_output=True, text=True, env=ENV, timeout=20)
    data = None
    if result.returncode == 0:
        try:
            data = json.loads(result.stdout if READER == 'state' else (root / 'out.json').read_text())
        except (ValueError, OSError):
            pass
    return result, data


def prepare(root, case):
    (root / 'mirror').mkdir()
    (root / 'state').mkdir()
    registry = {'schema': 'himmel.chain-registry/1', 'chains': [
        {'id': 'chain-%s' % i, 'goal': 'Every memory change is safe %s' % i, 'members': keys(members)}
        for i, members in enumerate(case['members'])]}
    (root / 'registry.json').write_text(json.dumps(registry))
    nodes, edges = [], []
    for number, fields in case['issues'].items():
        key = 'HIMMEL-' + number
        issue = dict(key=key, type='Task', status='To Do', statusCategory='To Do',
                     fixVersions=['v1.1.3'], labels=[], blocked_by=[], resolved=None)
        issue.update(fields)
        if issue['statusCategory'] == 'Done':
            issue['status'] = 'Done'
        (root / 'mirror' / (key + '.md')).write_text('---\n' + '\n'.join(
            '%s: %s' % (k, json.dumps(v)) for k, v in issue.items()) + '\n---\n\n# %s: fixture\n' % key)
        os.utime(root / 'mirror' / (key + '.md'), (STAMP - 600, STAMP - 600))
        nodes.append({'id': key, 'key': key})
        for blocker in issue['blocked_by']:
            edges.append({'from': blocker, 'to': key, 'kind': 'H1'})
    # Include unmirrored blockers in the graph so neither reader can quietly ignore them.
    for key in {e['from'] for e in edges} - {n['key'] for n in nodes}:
        nodes.append({'id': key, 'key': key})
    (root / 'graph.json').write_text(json.dumps({'nodes': nodes, 'edges': edges}))
    for field, filename in [('holds', 'chain-log.jsonl'), ('events', 'status-events.jsonl')]:
        (root / 'state' / filename).write_text(''.join(json.dumps(r) + '\n' for r in case.get(field, [])))
    return registry


with tempfile.TemporaryDirectory(prefix='chain-parity-') as temp:
    temp = Path(temp)
    for index, case in enumerate(json.loads((HERE / 'cases.json').read_text())):
        root = temp / str(index)
        root.mkdir()
        prepare(root, case)
        result, data = invoke(root)
        check(case['name'] + ' exits 0', result.returncode, 0)
        check(case['name'] + ' output parses as JSON', data is not None, True)
        if result.returncode or data is None:
            print(result.stderr)
            continue
        chains = data['chains'] if READER == 'state' else data
        check(case['name'] + ' chain count (no epic or label sources)', len(chains), len(case['members']))
        for i, c in enumerate(chains):
            actual_next = (c['next']['keys'] if c['next'] else []) if READER == 'state' else c['next']
            actual_done = [k for k in c['members'] if data['tickets'][k]['done']] if READER == 'state' else c['done']
            check(case['name'] + ' next chain-%s' % i, sorted(actual_next), keys(case['next'][i]))
            check(case['name'] + ' done chain-%s' % i, sorted(actual_done), keys(case['done'][i]))
            check(case['name'] + ' goal replaces bare label', c['name'], 'Every memory change is safe %s' % i)
            header = data if READER == 'state' else c
            check(case['name'] + ' registry path', header['registry']['path'], str(root / 'registry.json'))
            check(case['name'] + ' registry sha256', header['registry']['sha256'],
                  hashlib.sha256((root / 'registry.json').read_bytes()).hexdigest())
            check(case['name'] + ' source_age_min', header['source_age_min'], 10)
        for n in case.get('unknown', []):
            key = 'HIMMEL-%s' % n
            actual = data['tickets'].get(key, {'state': 'missing'})['state'] if READER == 'state' else (
                'unknown' if any(key in c['unknown'] for c in chains) else 'not unknown')
            check(case['name'] + ' unknown ' + key, actual, 'unknown')
        if 'cycle' in case:
            check(case['name'] + ' named cycle diagnostic', 'cycle ' + ' '.join(keys(case['cycle'])) in result.stderr, True)
        if 'unchained' in case and READER == 'state':
            check(case['name'] + ' unchained warning', 'unchained=1 HIMMEL-2' in result.stderr, True)
        if 'out_of_order' in case and READER == 'state':
            check(case['name'] + ' historical order uses new Done epoch',
                  data['tickets']['HIMMEL-%s' % case['out_of_order']]['check']['result'], 'out-of-order')
        for n, pr in case.get('audit_merge', {}).items():
            if READER == 'state':
                check(case['name'] + ' retains merge identity for order audit',
                      (data['tickets']['HIMMEL-' + n]['check'].get('merge') or {}).get('pr'), pr)
        if 'order_held' in case and READER == 'state':
            check(case['name'] + ' preserves historical completion before reopen',
                  data['tickets']['HIMMEL-%s' % case['order_held']]['check']['result'], 'order-held')
        if case['name'] == 'partial mirror member':
            check('unknown member warns', 'WARN unknown-member HIMMEL-1' in result.stderr, True)

    root = temp / 'validation'
    root.mkdir()
    valid = prepare(root, {'members': [[1]], 'issues': {'1': {}}})
    bad_rows = [('blank goal', 'goal', ' '), ('goal equals id', 'goal', 'chain-0'),
                ('goal equals spaced id', 'goal', 'chain 0'), ('too few goal words', 'goal', 'Safe changes'),
                ('too long goal', 'goal', 'Every change ' + 'x' * 80),
                ('bad id', 'id', 'UPPER'), ('duplicate member', 'members', ['HIMMEL-1', 'HIMMEL-1']),
                ('empty members', 'members', []), ('bad member', 'members', ['OTHER-1'])]
    for name, field, value in bad_rows:
        bad = copy.deepcopy(valid)
        bad['chains'][0][field] = value
        (root / 'registry.json').write_text(json.dumps(bad))
        (root / 'out.json').write_text('precious\n')
        result, _ = invoke(root)
        check(name + ' exits 2', result.returncode, 2)
        if READER == 'render':
            check(name + ' writes nothing', (root / 'out.json').read_text(), 'precious\n')
    for name, bad in [('duplicate id', dict(valid, chains=valid['chains'] * 2)),
                      ('bad schema', dict(valid, schema='other/1')), ('bad shape', [])]:
        (root / 'registry.json').write_text(json.dumps(bad))
        check(name + ' exits 2', invoke(root)[0].returncode, 2)
    (root / 'registry.json').write_text('{broken')
    check('invalid JSON exits 2', invoke(root)[0].returncode, 2)
    (root / 'registry.json').unlink()
    check('missing registry exits 2', invoke(root)[0].returncode, 2)
    check('no --registry exits 2', invoke(root, registry=False)[0].returncode, 2)
    (root / 'registry.json').write_text(json.dumps(valid))
    result, _ = invoke(root, mirror=root / 'missing-mirror')
    check('missing mirror exits 2', result.returncode, 2)
    check('missing mirror diagnostic', 'mirror missing' in result.stderr, True)

    if READER == 'render':
        # A PR-only H2 edge can subtract readiness, including across chains, but never add it.
        root = temp / 'pr-edge'
        root.mkdir()
        prepare(root, {'members': [[1], [2]], 'issues': {'1': {}, '2': {}}})
        (root / 'graph.json').write_text(json.dumps({'nodes': [{'id': '#1', 'key': 'HIMMEL-1'},
            {'id': '#2', 'key': 'HIMMEL-2'}], 'edges': [{'from': '#2', 'to': '#1', 'kind': 'H2'}]}))
        result, data = invoke(root)
        check('PR edge exits 0', result.returncode, 0)
        if data:
            check('external PR blocker removes next', data[0]['next'], [])
            check('independent PR still next', data[1]['next'], ['HIMMEL-2'])

print('%d registry/%s failure(s)' % (failures, READER))
sys.exit(bool(failures))
