#!/usr/bin/env python3
"""Record a proof handoff through owe.sh; never validate/transition a ticket.

The producer contract permits free-form Markdown tables and prose. Observations
below are deliberately conservative: raw artifact hashes and rows, never coverage
inferred from MET counts. All chief decisions remain pending.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys

HERE = Path(__file__).resolve().parent
KEY = r'[A-Z][A-Z0-9]+-\d+'
SECTIONS = {'Impact', 'What', 'Why', 'Plan', 'DoD', 'Proof', 'Agent detail'}


def digest(value):
    return hashlib.sha256(json.dumps(value, ensure_ascii=False, separators=(',', ':')).encode()).hexdigest()


def read_text(path):
    # Only line endings are canonicalized for requirements; no whitespace folding.
    return Path(path).read_bytes().decode('utf-8').replace('\r\n', '\n')


def requirements(path):
    text = read_text(path)
    match = re.search(r'^## Description\n', text, re.M)
    if not match:
        raise ValueError('no description')
    found = {}
    current = None
    fence = ''
    for line in text[match.end():].splitlines(keepends=True):
        fm = re.match(r'^ {0,3}(`{3,}|~{3,})(.*)', line)
        if fence:
            if current:
                found[current].append(line)
            if fm and fm[1][0] == fence[0] and len(fm[1]) >= len(fence) and not fm[2].strip():
                fence = ''
            continue
        if fm:
            fence = fm[1]
        if not fence and re.match(r'^## (?:Comments|History)\b', line):
            break
        name = re.sub(r'^ {0,3}#{1,6}\s+', '', line.rstrip('\n'))
        name = name.strip().strip('*_').rstrip(':').strip()
        if not fence and name in SECTIONS:
            current = name if name in ('DoD', 'Proof') else None
            if current:
                if current in found:
                    raise ValueError('duplicate requirement section')
                found[current] = []
        elif current:
            found[current].append(line)
    if fence or any(not ''.join(found.get(n, [])).strip() for n in ('DoD', 'Proof')):
        raise ValueError('missing/malformed requirement sections')
    return digest([[n, ''.join(found[n])] for n in ('DoD', 'Proof')])


def owe(args):
    command = ['bash', os.environ.get('PROOF_OWE_BIN', str(HERE / 'owe.sh')), *args]
    result = subprocess.run(command, text=True, capture_output=True)
    if result.returncode:
        raise RuntimeError('owed writer/read failed: ' + result.stderr.strip())
    return result.stdout.strip()


def shas(text):
    return [{'basis': basis, 'sha': sha} for basis, sha in sorted(set(
        re.findall(r'\b(main|station)=([0-9a-f]{7,40})(?![0-9a-f])', text)))]


def record(opt):
    message = sys.stdin.read() if opt.message_stdin else ''
    doc = opt.doc
    source = ''
    if doc:
        source = read_text(doc)
    # After manifest retirement, recover the exact original doc from existing owed
    # metadata. The label is routing data, never closure authority.
    if not doc and opt.label:
        rows = json.loads(owe(['list', '--bucket', opt.bucket, '--all', '--json']))
        docs = {r.get('source_doc') for r in rows if r.get('action') == 'validate-proof' and r.get('source_label') == opt.label and r.get('source_doc')}
        if len(docs) > 1:
            raise ValueError('ambiguous proof replay source')
        if docs:
            doc = docs.pop()
            try:
                source = read_text(doc)
            except (OSError, UnicodeError):
                pass
    result_lines = []
    in_results = False
    for line in source.splitlines():
        if line.startswith('## '):
            in_results = bool(re.match(r'^## (?:Results|Chief Rulings|Console Rulings)\b', line))
        elif in_results:
            result_lines.append(line)
    wrapped = re.findall(r'^- .*\bWRAPPED\b.*', '\n'.join(result_lines), re.M)
    tail = wrapped[-1] if wrapped else ''
    header = re.findall(r'^> \*\*Proof leg:\*\* (.+)$', source, re.M)
    proof = bool(re.search(r'\bWRAPPED\b[^\n]*\bproof\s+' + KEY, tail + '\n' + message, re.I)
                 or header or re.search(r'proof leg|Leg kind:\*\* proof', source))
    if not proof:
        return
    origin = opt.label
    if not origin and doc:
        m = re.search(r'-(?:leg)?(N\d+[a-z]*)(?:-|\.)', Path(doc).name)
        origin = m[1] if m else str(Path(doc).resolve())
    declaration = tail + '\n' + message
    groups = re.findall(r'\bproof\s+((?:' + KEY + r'[ ,]*)+)', declaration, re.I)
    keys = sorted(set(re.findall(KEY, ' '.join(groups + header))))
    if not keys:
        keys = sorted(set(re.findall(KEY, Path(doc).name if doc else '')))
    if not keys:
        raise ValueError('recognized proof has no ticket identity')
    paths = []
    for m in re.finditer(r'\bevidence=(?:`([^`]+)`|"([^"]+)"|([^\s]+))', declaration):
        path = next(x for x in m.groups() if x is not None).rstrip('.,;')
        if path not in paths:
            paths.append(path)
    if not paths:
        # Generated proof briefs bind Writes to bucket specs/audits files.
        paths = re.findall(r'[^\s`<>]*specs/audits/[^\s`<>]+\.md', source)
        paths = list(dict.fromkeys(paths))
    for key in keys:
        unbound = [p for p in paths if not any(k in Path(p).name for k in keys)]
        candidates = [p for p in paths if key in Path(p).name] or unbound or ['']
        observations = []
        for path in candidates:
            issues = ['positive-controls-unvalidated', 'candidate-ancestry-unvalidated', 'coverage-unvalidated']
            meta = {'actor': 'chief', 'action': 'validate-proof', 'validation': 'pending',
                    'source_doc': str(Path(doc).resolve()) if doc else '', 'source_label': origin,
                    'evidence_path': path, 'binding': 'unknown', 'issues': issues}
            artifact = ''
            try:
                raw = Path(path).read_bytes() if path else None
                if raw is None:
                    raise ValueError('missing evidence path')
                meta['evidence_hash'] = hashlib.sha256(raw).hexdigest()
                artifact = raw.decode('utf-8')
            except (OSError, UnicodeError, ValueError):
                issues.append('evidence-unreadable')
            mirror = Path(opt.mirror or os.environ.get('PROOF_MIRROR_DIR') or
                          Path.home() / '.himmel/state/jira-mirror' / key.split('-')[0])
            try:
                meta['requirements_digest'] = requirements(mirror / (key + '.md'))
            except (OSError, UnicodeError, ValueError):
                issues.append('requirements-unreadable')
            stamps = re.findall(r'^requirements-sha256 ' + re.escape(key) + r'=([0-9a-f]{64})\s*$', artifact + '\n' + source, re.M)
            if stamps and len(set(stamps)) == 1:
                meta['original_requirements_digest'] = stamps[0]
                if meta.get('requirements_digest'):
                    meta['binding'] = 'matched' if stamps[0] == meta['requirements_digest'] else 'mismatch'
            if meta['binding'] != 'matched':
                issues.append('requirements-unbound' if meta['binding'] == 'unknown' else 'requirements-changed')
            verdicts = re.findall(r'^VERDICT (CLOSE|KEEP)\b', artifact, re.M)
            declared = re.findall(r'\bverdict=(CLOSE|KEEP)\b', declaration)
            meta['recommendation'] = verdicts[-1] if verdicts else declared[-1] if declared else 'unknown'
            if verdicts and declared and verdicts[-1] != declared[-1]:
                issues.append('recommendation-disagrees-with-tail')
            if not verdicts:
                issues.append('recommendation-unreadable')
            meta['proof_rows'] = [line for line in artifact.splitlines() if
                                  re.search(r'\b(?:MET|OWED|NOT MET|SKIP\w*|ERRORS?)\b', line, re.I)]
            if not meta['proof_rows']:
                issues.append('proof-rows-unreadable')
            for line in artifact.splitlines():
                if line.startswith('|') and line.count('|') < 4:
                    issues.append('malformed-row: ' + line)
            meta['executed_shas'] = shas('\n'.join(line for line in artifact.splitlines() if not line.startswith('required-sha ')))
            meta['required_shas'] = shas('\n'.join(re.findall(r'^required-sha (.*)$', artifact + '\n' + source, re.M)))
            if not meta['executed_shas']:
                issues.append('sha-unbound')
            elif any(len(s['sha']) != 40 for s in meta['executed_shas']):
                issues.append('sha-abbreviated')
            for field in ('next_action', 'wake'):
                values = re.findall(r'^' + field.replace('_', '-') + r': (.+)$', artifact + '\n' + tail, re.M)
                if values:
                    meta[field] = values[-1]
            identity = digest(['validate-proof', key, meta.get('evidence_hash') or
                               ['unreadable', meta['source_doc'] or origin, path, meta['recommendation']], meta.get('requirements_digest'),
                               meta.get('original_requirements_digest')])
            observations.append((identity, meta))
        identity, meta = observations[0]
        if len(observations) > 1:
            identity = digest(['validate-proof', key, sorted(i for i, _ in observations)])
            records = []
            for _, observed in observations:
                records.append({'path': observed['evidence_path'], **(
                    {'sha256': observed['evidence_hash']} if 'evidence_hash' in observed else {})})
            meta = dict(meta, evidence_records=records)
            meta.pop('evidence_hash', None)
            meta['issues'] = sorted(set(i for _, m in observations for i in m['issues']))
            meta['proof_rows'] = [m['evidence_path'] + ': ' + row for _, m in observations for row in m['proof_rows']]
            for field in ('executed_shas', 'required_shas'):
                meta[field] = [{'basis': b, 'sha': s} for b, s in sorted(set(
                    (r['basis'], r['sha']) for _, m in observations for r in m[field]))]
            for field in ('recommendation', 'binding'):
                if len({m[field] for _, m in observations}) > 1:
                    meta[field] = 'unknown'
                    meta['issues'].append(field + '-conflict')
                    meta['issues'].extend(field + ': ' + m['evidence_path'] + ' ' + m[field] for _, m in observations)
            for field in ('next_action', 'wake'):
                values = list(dict.fromkeys(m[field] for _, m in observations if field in m))
                if values:
                    meta[field] = '\n'.join(values)
        if not opt.dry_run:
            action = owe(['add', '--bucket', opt.bucket, '--chief', 'chief', '--kind', 'proof',
                          '--key', key, '--text', 'Validate proof ' + key + ': recommendation=' + meta['recommendation'] + '; pending chief validation/reconciliation',
                          '--identity', identity, '--metadata', json.dumps(meta)])
            print('PROOF-RECORDED ' + key + ' ' + action)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--bucket', required=True)
    parser.add_argument('--doc')
    parser.add_argument('--label', default='')
    parser.add_argument('--message-stdin', action='store_true')
    parser.add_argument('--mirror')
    parser.add_argument('--dry-run', action='store_true')
    opt = parser.parse_args()
    try:
        record(opt)
    except (OSError, ValueError, RuntimeError) as exc:
        print('proof-handoff: ' + str(exc), file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
