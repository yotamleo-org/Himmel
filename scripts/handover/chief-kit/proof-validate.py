#!/usr/bin/env python3
"""Record/check a proof handoff through owe.sh; never transition a ticket.

The producer contract permits free-form Markdown tables and prose. Observations
below are deliberately conservative: raw artifact hashes and rows, never coverage
inferred from MET counts. The existing Jira CLI supplies explicit chief outcomes.
"""
import argparse
import datetime
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import sys
import time

HERE =Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent.parent / 'lib'))
from status_marker import parse as status_marker_parse

KEY = r'[A-Z][A-Z0-9]+-\d+'
# The tokens an artifact uses for a proof row that did not pass. The recorder lists any line carrying one; CLOSE additionally
# refuses a table cell or a list item that STARTS with one (qualified forms included: `NOT MET — no RED`, `SKIPPED (no vm)`,
# `ERRORS`, `FAIL`, `- NOT MET: ...`). A list item's word may sit in emphasis or inline code (`- *NOT MET*`, `- _OWED_`). An item that starts with `MET`
# (through the same marks, in any letter case) is read by that word alone, whatever its detail says (`- MET main=aaaa: failures 0`). Any other item is also
# unmet when an unmet word is the first thing after any of its colons, past spaces and emphasis or inline-code marks (`- control two: NOT MET`,
# `- **Result:** NOT MET`, `- Result: *FAIL*`, `- Result: NOT MET: no RED`), and after a colon the word is read whole: `FAIL`, `FAILS`, `FAILED`, `FAILURE`,
# `FAILING`, `SKIP`, `SKIPS`, `SKIPPED`, `ERROR`, `ERRORS`, `OWED` and `NOT MET` are unmet, while `failures`, `skipping`, a word continued by a letter or a digit,
# or by one underscore and then a letter or a digit (`SKIP_CR`; an underscore that ends the word is a closing emphasis mark, so `FAIL_ x` and
# `SKIP__CR` still count), and a FAIL joined to a continuation by a hyphen (`failed-over`) are other words. At the start of an item and in a table cell the word
# is read by its beginning (`FAIL...`, `SKIP...`). Prose that merely mentions a word is not a row; whether the evidence covers every
# obligation stays the chief's explicit judgement. A declared Expected column in a supported Markdown table is test input,
# not an actual requirement status; other cells and unmet list items retain the same refusal rule.
# A row is MET only when its status is exactly the producer's word for it (`MET`, in any letter case, through emphasis and
# whitespace): in a table the status is the column its header calls Result, Status, Verdict, Outcome or State (an `Expected` column is
# test input), and when that column uses the proof vocabulary (PROOF_WORD) anything else in it is unmet, `MET (pending review)`,
# `PASS (pending)`, `Awaiting 24h`, `NOT RUN`, `BLOCKED`, a ticket status and an empty cell included. A list item starts with its status: a result that is not yet met or due (`PENDING`, `NOT YET DUE`, `WAITING`,
# `TBD`, `AWAITING`, `NOT RUN`, `BLOCKED`, in any case, through emphasis, however it goes on) is unmet there. A row with no status
# column to read (a header without one, no header, a ragged row) has no status position distinct from its evidence text, so every
# cell of it is read for those words: an unsure row is unmet, and `pending count was 0` there reads as not yet due. In a table with no
# status column at all (no header, or a header that names none) a cell that starts with an unmet word in emphasis or inline code
# (`**NOT MET**`, `_OWED_`) is unmet, as the bare word is in every table; a table that has a status column is read by it, so an emphasised word in its other cells is not read. A table written
# without leading pipes is a table when a separator row follows its header.
UNMET = r'(?:NOT\s+MET|OWED|SKIP\w*|ERRORS?|FAIL\w*)'
NOT_DUE = r'(?:PENDING|WAITING|TBD|AWAITING|BLOCKED|NOT[\s-]+YET[\s-]+DUE|NOT[\s-]+RUN)(?![A-Za-z0-9])'
UNMET_CELL = re.compile(r'\|\s*' + UNMET + r'\b[^|]*\|', re.I)
UNMET_MARKED_CELL = re.compile(r'\s*[*_`]+' + UNMET + r'(?:\b|_+(?![A-Za-z0-9]))', re.I)
UNMET_ITEM = re.compile(r'^\s*(?:[-*+]|\d+[.)])\s+[*_`]*' + UNMET + r'(?:\b|_+(?![A-Za-z0-9]))', re.I)
ITEM_TEXT = re.compile(r'^\s*(?:[-*+]|\d+[.)])\s+(.*)$')
# A word read whole ends where the text does not continue it with a letter, a digit or an underscore (an emphasis mark that closes the word is not one);
# JOINED is the end of a word that a hyphen does not join to a continuation (`failed-over`).
WHOLE = r'(?:\b|_+(?![A-Za-z0-9]))'
JOINED = r'(?!-[A-Za-z0-9])'
MET_ITEM = re.compile(r'^\s*(?:[-*+]|\d+[.)])\s+[*_`]*MET' + WHOLE + JOINED, re.I)
UNMET_STATUS = re.compile(r':[\s*_`]*(?:NOT\s+MET|OWED|SKIP(?:PED|S)?|ERRORS?|FAIL(?:ED|S|URE|ING)?' + JOINED + r')' + WHOLE, re.I)
NOT_DUE_CELL = re.compile(r'^[\s*_`]*' + NOT_DUE, re.I)
NOT_DUE_ITEM = re.compile(r'^\s*(?:[-*+]|\d+[.)])\s+[*_`]*' + NOT_DUE, re.I)
MET_STATUS = re.compile(r'[\s*_`]*MET[\s*_`]*', re.I)
# The proof vocabulary, ONE list built from the words above plus the producer's own (`MET`, `PASS`): a status column that has at least one
# cell starting with one of them is a proof-row column and is read strictly; a column with none (a ticket-status column: To Do, In Progress,
# Done, context) is not a proof-row column and nothing in it refuses. One MET among ticket statuses makes the column strict.
PROOF_WORD = re.compile(r'^[\s*_`]*(?:MET|PASS(?:ED)?|' + UNMET + r'|' + NOT_DUE + r')(?![A-Za-z0-9])', re.I)
STATUS_HEADER = re.compile(r'\b(?:result|status|verdict|outcome|state)\b', re.I)
SECTIONS = {'Impact', 'What', 'Why', 'Plan', 'DoD', 'Proof', 'Agent detail'}
MAX_FILE_BYTES = 8 * 1024 * 1024
OWE_METADATA_MAX_BYTES = 1024 * 1024


def is_separator(line):
    stripped = line.strip()
    return '|' in stripped and re.fullmatch(r'\|?\s*:?-{3,}:?\s*(?:\|\s*:?-{3,}:?\s*)*\|?', stripped) is not None


def row_cells(line):
    stripped = line.strip()
    if stripped.startswith('|'):
        stripped = stripped[1:]
    if stripped.endswith('|') and not stripped.endswith('\\|'):
        stripped = stripped[:-1]
    return re.split(r'(?<!\\)\|', stripped)


def has_unmet_rows(text):
    lines = text.splitlines()
    expected, status, proof, width = set(), set(), set(), 0
    for index, line in enumerate(lines):
        item = ITEM_TEXT.match(line)
        if UNMET_ITEM.search(line) or NOT_DUE_ITEM.search(line) or (item and not MET_ITEM.match(line) and UNMET_STATUS.search(item[1])):
            return True
        header = index + 1 < len(lines) and re.search(r'(?<!\\)\|', line) and is_separator(lines[index + 1]) and not is_separator(line)
        if not (line.strip().startswith('|') or header or (width and re.search(r'(?<!\\)\|', line))):
            expected, status, proof, width = set(), set(), set(), 0
            continue
        cells = row_cells(line)
        if header:
            expected = {i for i, cell in enumerate(cells) if cell.strip().lower() == 'expected'}
            status = {i for i, cell in enumerate(cells) if i not in expected and STATUS_HEADER.search(cell)}
            width = len(cells)
            body = []
            for later in lines[index + 2:]:
                if not re.search(r'(?<!\\)\|', later):
                    break
                if len(row_cells(later)) == width and not is_separator(later):
                    body.append(row_cells(later))
            proof = {i for i in status if any(PROOF_WORD.match(cells_of[i]) for cells_of in body)}
            continue
        if is_separator(line):
            continue
        if expected and len(cells) == width:
            if any(re.match(r'\s*' + UNMET + r'\b', cell, re.I)
                   for i, cell in enumerate(cells) if i not in expected):
                return True
        elif UNMET_CELL.search('|' + '|'.join(cells) + '|'):
            return True
        if not status and any(UNMET_MARKED_CELL.match(cell) for i, cell in enumerate(cells) if i not in expected or len(cells) != width):
            return True
        if status and len(cells) == width:
            if any(not MET_STATUS.fullmatch(cells[i]) for i in proof):
                return True
        elif any(NOT_DUE_CELL.match(cell) for i, cell in enumerate(cells) if i not in expected):
            return True
    return False


PR_REPO = 'yotamleo-org/Himmel'  # env-literal-ok: the canonical slug, read the way next-dispatchable.sh reads it


def live_remainder(key):
    """What the ticket's merged partial pull requests still leave undone, as their bodies on GitHub say.

    The partial PRs come from the status log (TICKET_STATUS_STATE_DIR, else ~/.himmel/state) through merge-rows-effective.py, a
    completing merge row clearing the earlier ones; each body is read with `gh pr view` through NEXT_DISPATCH_GH_CMD, else ND_GH_READ, else
    scripts/lib/gh-read.sh when that file beside the kit is an executable file, else plain `gh`. The helper reads on the read token and retries a
    refused read on the main token; next-dispatchable.sh exports GH_READ_NO_MAIN_FALLBACK=1 for its own reads through the helper, which stops that
    retry on a rate limit, and this function does not set it. A helper that is present and fails leaves the body unreadable; there is no retry on plain `gh`.
    The grammar and the newest-PR-wins rule are pr_remainder.py's own, and so is the path pattern a unit naming a file
    is code by (holds.py's FILE_RE, the copy of the dispatcher's own). The whole read has one budget (PROOF_REMAINDER_BUDGET_SECS,
    default 90 s), under the 100 s the Jira CLI waits for the validator; what it cannot finish is unreadable, never nothing.
    Returns (blocking, unreadable): what stops a CLOSE (open code work, an owed chief or operator line, a body that records no
    remainder) and what could not be read."""
    state = os.environ.get('TICKET_STATUS_STATE_DIR') or os.path.join(os.environ.get('HOME') or '/tmp', '.himmel', 'state')
    log = os.path.join(state, 'status-events.jsonl')
    budget = float(os.environ.get('PROOF_REMAINDER_BUDGET_SECS') or '90')
    deadline = time.monotonic() + budget
    try:
        from pr_remainder import live_answers, pr_remainder_units
        spec = importlib.util.spec_from_file_location('holds', HERE / 'holds.py')
        holds = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(holds)
    except Exception as exc:  # a reader that does not load is a remainder that cannot be read
        return [], ['pr_remainder.py or holds.py (%s)' % exc]
    prs = []
    try:
        open(log).close()
        eff = subprocess.run([sys.executable, '-I', str(HERE.parent.parent / 'lib' / 'merge-rows-effective.py'), log], capture_output=True, text=True,
                             timeout=max(1, min(120, deadline - time.monotonic())))
        if eff.returncode:
            raise OSError(eff.stderr.strip() or 'merge-rows-effective failed')
        warned = [line.strip() for line in eff.stderr.splitlines() if 'warn:' in line]
        if warned:  # a pre-merge row the helper could not confirm is dropped with a warning: a partial merge it could not establish
            raise OSError('the log helper warned: ' + '; '.join(warned))
        for line in eff.stdout.splitlines():
            try:
                r = json.loads(line)
            except ValueError:
                if line.strip() and key.upper() in line.upper():  # a torn or corrupt line that names the ticket may be its partial merge
                    raise OSError('a line that names %s is not JSON' % key)
                continue
            if not isinstance(r, dict) or r.get('event') != 'merge' or r.get('contract') not in ('yes', 'no') or str(r.get('key', '')).upper() != key.upper():
                continue
            if r['contract'] == 'yes':
                prs = []
            elif not str(r.get('pr', '')).isdigit():
                raise OSError('merge row for %s has no PR number' % key)
            elif str(r['pr']) not in prs:
                prs.append(str(r['pr']))
    except FileNotFoundError:
        return [], []  # no log is no partial merge, as for the dispatcher
    except subprocess.TimeoutExpired:
        return [], ['status log %s unreadable (the log helper ran past the read budget)' % log]
    except (OSError, subprocess.SubprocessError) as exc:
        return [], ['status log %s unreadable (%s)' % (log, getattr(exc, 'strerror', None) or exc)]
    read_helper = HERE.parent.parent / 'lib' / 'gh-read.sh'
    gh = os.environ.get('NEXT_DISPATCH_GH_CMD') or os.environ.get('ND_GH_READ') or (str(read_helper) if read_helper.is_file() and os.access(read_helper, os.X_OK) else 'gh')
    answers, unreadable = [], []
    for pr in prs:
        left = deadline - time.monotonic()
        if left < 1:
            unreadable.append('PR #%s body unreadable (the %g s read budget is spent)' % (pr, budget))
            continue
        try:
            body = subprocess.run([gh, 'pr', 'view', pr, '--repo', PR_REPO, '--json', 'body', '--jq', '.body'],
                                  capture_output=True, timeout=min(60, left), check=True).stdout.decode('utf-8', 'replace')
            answers.append(dict(pr_remainder_units(body, [key]), pr=pr))
        except subprocess.TimeoutExpired:
            unreadable.append('PR #%s body unreadable (gh ran past the read budget)' % pr)
        except (OSError, subprocess.SubprocessError, ValueError, TypeError) as exc:
            unreadable.append('PR #%s body unreadable (%s)' % (pr, 'gh exit %s' % exc.returncode if isinstance(exc, subprocess.CalledProcessError) else exc))
    if unreadable:
        return [], unreadable
    blocking = []
    for answer in live_answers(answers):
        if answer['kind'] == 'none':
            blocking.append('PR #%s records no remainder' % answer['pr'])
        elif answer['kind'] == 'remaining' and (not answer['nowrite'] or holds.FILE_RE.search(answer['text'])):
            blocking.append('PR #%s Remaining: %s' % (answer['pr'], answer['text'][:300]))
        blocking.extend('PR #%s %s' % (answer['pr'], line['text'][:300]) for line in answer['owed_lines'] if line['who'] in ('chief', 'operator'))
    return blocking, []


def regular_bytes(path):
    fd = os.open(path, os.O_RDONLY | os.O_NONBLOCK | os.O_NOFOLLOW | os.O_CLOEXEC)
    try:
        before = os.fstat(fd)
        if not stat.S_ISREG(before.st_mode) or before.st_size > MAX_FILE_BYTES:
            raise ValueError('nonregular or oversize proof input')
        chunks = []
        size = 0
        while size <= MAX_FILE_BYTES:
            chunk = os.read(fd, min(65536, MAX_FILE_BYTES + 1 - size))
            if not chunk:
                break
            chunks.append(chunk)
            size += len(chunk)
        after = os.fstat(fd)
        named = os.stat(path, follow_symlinks=False)
        def fingerprint(value):
            return (value.st_dev, value.st_ino, value.st_mode, value.st_size, value.st_mtime_ns, value.st_ctime_ns)
        if size != before.st_size or size > MAX_FILE_BYTES or fingerprint(before) != fingerprint(after) or fingerprint(after) != fingerprint(named):
            raise ValueError('proof input changed during read')
        return b''.join(chunks)
    finally:
        os.close(fd)


def digest(value):
    return hashlib.sha256(json.dumps(value, ensure_ascii=False, separators=(',', ':')).encode()).hexdigest()


def read_text(path):
    # Only line endings are canonicalized for requirements; no whitespace folding.
    return regular_bytes(path).decode('utf-8').replace('\r\n', '\n')


def requirements(path):
    return requirement_text(read_text(path))


def requirement_text(text):
    found = requirement_sections(text)
    return digest([[n, ''.join(found[n])] for n in ('DoD', 'Proof')])


def requirement_body(text):
    """The DoD and Proof text the digest covers, for checking that a citation names a real requirement."""
    found = requirement_sections(text)
    return ''.join(''.join(found[n]) for n in ('DoD', 'Proof'))


def requirement_sections(text):
    text = text.replace('\r\n', '\n')
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
    return found


def decision(opt):
    """Check immutable inputs, not semantic coverage or permission.

    The authorized Jira CLI supplies its fresh description/status read. A chief's
    coverage judgement remains explicit data; this helper has no Jira write path.
    """
    rows = json.loads(owe(['list', '--bucket', opt.bucket, '--all', '--json']))
    row = next((r for r in rows if r['id'] == (opt.check or opt.settle)), None)
    if not row or row.get('action') != 'validate-proof':
        raise ValueError('not a proof-validation action')
    raw = regular_bytes(opt.decision)
    verdict = json.loads(raw)
    if verdict.get('identity') != row.get('identity') or verdict.get('verdict') not in ('CLOSE', 'KEEP'):
        raise ValueError('decision identity/verdict mismatch')
    close = verdict['verdict'] == 'CLOSE'
    decision_hash = hashlib.sha256(raw).hexdigest()
    if opt.decision_hash and opt.decision_hash != decision_hash:
        raise ValueError('decision changed since the check (checked %s, now %s); run the check again' % (opt.decision_hash[:12], decision_hash[:12]))
    # Closed actions are immutable. A retry never reopens them or appends another
    # next action, including after the evidence was subsequently retired.
    if row['closed']:
        owe(['close-confirm', '--bucket', opt.bucket, '--id', row['id']])
        print(json.dumps({'id': row['id'], 'closed': True}))
        return
    if not opt.current_stdin:
        raise ValueError('fresh current description/status input required')
    current = json.loads(sys.stdin.buffer.read(MAX_FILE_BYTES + 1))
    if current.get('key') != row['key']:
        raise ValueError('current ticket identity mismatch')
    if not isinstance(current.get('mirror', current.get('description')), str):
        raise ValueError('current description unreadable')
    if not close and opt.settle and current.get('status') == 'Done' and current.get('category') == 'done':
        raise ValueError('a KEEP never settles on a Done ticket; the ticket is Done now, so run the check again')
    rationale = verdict.get('rationale')
    if isinstance(rationale, str):
        outcome = dict(identity=row['identity'], decision_hash=decision_hash, verdict=verdict['verdict'], status=current.get('status', ''),
                       version_pending=bool(current.get('unstamped')), rationale=rationale, decision_json=raw.decode('utf-8'))
        if len(json.dumps({'outcome': outcome}).encode()) > OWE_METADATA_MAX_BYTES:
            raise ValueError('decision outcome exceeds the 1 MiB ledger limit; shorten the rationale')
    try:
        current_digest = requirement_text(current['mirror'] if 'mirror' in current else '## Description\n' + current['description'])
    except ValueError:
        if close or row.get('requirements_digest'):
            raise
        current_digest = None
    if current_digest != row.get('requirements_digest'):
        actual_done = current.get('status') == 'Done' and current.get('category') == 'done'
        existing = next((r for r in rows if r.get('action') == 'requirements-reconciliation' and r.get('source_id') == row['id'] and not r['closed']), None)
        if close and opt.settle and not opt.dry_run and actual_done and current_digest is not None:
            # The ticket really is Done but its DoD/Proof moved after the evidence was bound. Keep the validation unresolved and
            # leave the chief an owned, idempotent step that names both identities; never reopen, close or mutate Jira here.
            closed_owner = next((r for r in rows if r.get('action') == 'requirements-reconciliation' and r.get('source_id') == row['id'] and r['closed']
                                 and r.get('requirements_digest') == current_digest), None)
            if closed_owner:
                raise ValueError('requirements-reconciliation %s is already closed and the DoD/Proof still differ from the validated text; '
                                 'record a new pending validation' % closed_owner['id'])
            metadata = dict(actor='chief', capability='requirement reconciliation', action='requirements-reconciliation', source_id=row['id'],
                            due=datetime.datetime.now(datetime.timezone.utc).date().isoformat(), wake='requirements reconciled',
                            actual_status=current.get('status', ''), original_requirements_digest=row['requirements_digest'], requirements_digest=current_digest)
            text = ('Reconcile requirements: %s is Done but its DoD/Proof changed after validation %s (validated %s, now %s); decide whether to reopen, '
                    'accept the new text or file a follow-up, then record a new pending validation' % (row['key'], row['id'], row['requirements_digest'][:12], current_digest[:12]))
            owe(['add', '--bucket', opt.bucket, '--chief', row['chief'], '--kind', 'step', '--key', row['key'], '--text', text,
                 '--identity', digest([row['identity'], row['requirements_digest'], current_digest, 'requirements-reconciliation']), '--metadata-stdin'],
                json.dumps(metadata))
            made = next((r for r in json.loads(owe(['list', '--bucket', opt.bucket, '--all', '--json'])) if r.get('action') == 'requirements-reconciliation'
                         and r.get('source_id') == row['id'] and r.get('requirements_digest') == current_digest), None)
            print(json.dumps({'id': row['id'], 'closed': False, 'reconciliation': made['id'] if made else None, 'status': current.get('status')}))
            return
        raise ValueError('requirements changed; record new pending validation' +
                         (' (requirements-reconciliation %s already owns it)' % existing['id'] if existing else ''))
    artifacts = row.get('evidence_records') or [{'path': row['evidence_path'], 'sha256': row.get('evidence_hash')}]
    evidence = []
    for artifact in artifacts:
        try:
            data = regular_bytes(artifact['path'])
        except (OSError, ValueError):
            if close or artifact.get('sha256'):
                raise
            # KEEP may route a known unreadable input to reconciliation. A
            # formerly hashed input that vanished instead requires a new record.
            continue
        if hashlib.sha256(data).hexdigest() != artifact.get('sha256'):
            raise ValueError('evidence changed/unbound; record new pending validation')
        evidence.append(data.decode('utf-8', errors='strict' if close else 'replace'))
    rationale = verdict.get('rationale')
    if not isinstance(rationale, str) or not rationale.strip():
        raise ValueError('explicit chief rationale required')
    if close:
        unresolved = set(row.get('issues', [])) - {'positive-controls-unvalidated', 'candidate-ancestry-unvalidated', 'coverage-unvalidated'}
        if row.get('binding') != 'matched' or row.get('recommendation') != 'CLOSE' or unresolved:
            raise ValueError('unbound/unresolved proof; KEEP/reconciliation required')
        if any(v['omitted'] or v['truncated_chars'] for v in row.get('observation_counts', {}).values()):
            raise ValueError('truncated observations require reconciliation')
        if any(has_unmet_rows(text) for text in evidence):
            raise ValueError('unmet/skipped/error proof row')
        # A CLOSE never settles over what is still open for the ticket, and it names it. Two guards, one outcome: the ticket's merged partial
        # pull requests (open code work, an owed chief or operator line, a body that records no remainder; a list that cannot be read fails
        # closed) and the owed ledger (an open `step` row of this key, in any case, that is not a proof step (this handoff discharges the
        # ones it bound; later ones are not its scope) or a requirements or version reconciliation). The step this validation's own
        # reconciliation wrote is `mine`: it blocks the CLOSE until the chief closes it, but never counts as new news for the next one.
        # `--check` and a settle on a ticket that is not Done refuse and write nothing; a settle on a ticket that is already Done leaves the
        # chief ONE owned, idempotent step that names it and discharges nothing. A KEEP is never asked.
        remainder, unreadable = live_remainder(row['key'])
        rows = json.loads(owe(['list', '--bucket', opt.bucket, '--all', '--json']))
        done_settle = opt.settle and not opt.dry_run and current.get('status') == 'Done' and current.get('category') == 'done'
        if unreadable and not done_settle:
            raise ValueError('live pull-request remainder unreadable: ' + '; '.join(unreadable) + '; the CLOSE is refused until it can be read')
        open_steps = [r for r in rows if not r['closed'] and str(r.get('key', '')).upper() == row['key'].upper() and r['id'] != row['id'] and r['kind'] == 'step'
                      and r.get('actor') != 'proof' and r.get('action') not in ('requirements-reconciliation', 'version-reconciliation')]
        mine = [r for r in open_steps if r.get('capability') == 'remainder reconciliation' and r.get('source_id') == row['id']]
        foreign = [r for r in open_steps if r not in mine]

        def steps_message(steps):
            return ('open code/chief step ' + '; '.join('%s (%s: %s)' % (r['id'], r.get('actor') or 'no actor', r['text'][:160]) for r in steps) +
                    ' remains open; if it is finished, close it with `' + '` or `'.join('bash %s close --bucket %s --id %s --key %s' % (HERE / 'owe.sh', opt.bucket, r['id'], row['key']) for r in steps) +
                    '`; if work really remains, record a KEEP decision instead')

        if remainder or foreign or unreadable:
            names = ['could not read: ' + u for u in unreadable] + remainder + ['open step %s (%s: %s)' % (r['id'], r.get('actor') or 'no actor', r['text'][:160]) for r in foreign]
            if done_settle:
                # The ticket really is Done but something opened, or could not be read, after the check. Keep the validation pending and leave
                # the chief ONE owned step per validation (its identity is the validation and the closed steps before it, not the blockers,
                # which change; the live remainder is the authority); discharge nothing.
                metadata = dict(actor='chief', capability='remainder reconciliation', action='next-step', source_id=row['id'], wake='remainder reconciled',
                                due=datetime.datetime.now(datetime.timezone.utc).date().isoformat(), actual_status=current.get('status', ''))
                # A step the chief closed while this still blocks is not an owner: the next settle writes a new open one that says so, so
                # there is always exactly one open owner and never a success that returns a closed step's id.
                earlier = [r['id'] for r in rows if r['closed'] and r.get('capability') == 'remainder reconciliation' and r.get('source_id') == row['id']]
                text = re.sub(r'[\x00-\x1f]+', ' ', ('Earlier reconciliation step %s %s closed with the blockers still open. ' % (', '.join(earlier), 'was' if len(earlier) == 1 else 'were') if earlier else '') +
                              'Reconcile close: %s is Done but %s still blocks the CLOSE; validation %s stays pending. The live pull-request remainder is the authority: what is named '
                              'here is as it stood when this step was written. Clear it first (build or finish it, close what is finished, '
                              'or edit the pull request to the truth), then close this step, then record the decision again; if it will not be cleared, reopen the ticket '
                              'or record a KEEP' % (row['key'], '; '.join(names), row['id']))
                try:
                    made = owe(['add', '--bucket', opt.bucket, '--chief', row['chief'], '--kind', 'step', '--key', row['key'], '--text', text,
                                '--identity', digest([row['identity'], 'close-reconciliation', earlier]), '--metadata-stdin'], json.dumps(metadata))
                    owned = made in {r['id'] for r in json.loads(owe(['list', '--bucket', opt.bucket, '--json']))}
                except RuntimeError as exc:
                    raise ValueError('could not write the reconciliation step (%s): %s' % (exc, '; '.join(names)))
                if not owned:
                    raise ValueError('the reconciliation step %s is already closed and the CLOSE is still blocked by: %s' % (made, '; '.join(names)))
                print(json.dumps({'id': row['id'], 'closed': False, 'reconciliation': made, 'status': current.get('status'), 'remainder': names}))
                return
            raise ValueError('; '.join(([('live pull-request remainder blocks the CLOSE: ' + '; '.join(remainder) + '; KEEP required')] if remainder else []) +
                                       ([steps_message(foreign)] if foreign else [])))
        if mine:
            raise ValueError(steps_message(mine))
        current_requirements = ' '.join(requirement_body(current['mirror'] if 'mirror' in current else '## Description\n' + current['description']).lower().split())
        for field in ('coverage', 'controls'):
            citations = verdict.get(field)
            if not isinstance(citations, list) or not citations:
                raise ValueError('explicit obligation/control evidence required')
            for citation in citations:
                if (isinstance(citation, dict) and isinstance(citation.get('obligation'), str) and citation['obligation'].strip()
                        and ' '.join(citation['obligation'].lower().split()) not in current_requirements):
                    raise ValueError('decision citation names no current DoD/Proof requirement')
                if not isinstance(citation, dict) or not citation.get('obligation') or not isinstance(citation.get('evidence'), str) or not citation['evidence'].strip() or not any(citation['evidence'] in text for text in evidence):
                    raise ValueError('decision citation is not in recorded evidence')
        if not isinstance(verdict.get('ancestry'), str) or not verdict['ancestry'].strip():
            raise ValueError('explicit main/station/candidate ancestry judgement required')
    else:
        nxt = verdict.get('next', {})
        datetime.date.fromisoformat(nxt.get('due', ''))
        if nxt.get('actor') not in ('proof', 'worker', 'chief', 'operator') or any(not isinstance(nxt.get(f), str) or not nxt[f].strip() or '\n' in nxt[f] for f in ('text', 'capability', 'wake')):
            raise ValueError('KEEP needs exact action, capable actor, due and wake')
    if opt.check:
        print(json.dumps({'id': row['id'], 'identity': row['identity'], 'decision_hash': decision_hash,
                          'requirements_digest': current_digest, 'verdict': verdict['verdict'], 'semantic_coverage': 'chief-owned'}))
        return
    if close and (current.get('status') != 'Done' or current.get('category') != 'done'):
        raise ValueError('Done readback unconfirmed; validation remains pending')
    if not close or current.get('unstamped'):
        nxt = verdict['next'] if not close else dict(actor='chief', capability='version placement',
              text='Reconcile version placement: ' + str(current['unstamped']), due=datetime.datetime.now(datetime.timezone.utc).date().isoformat(), wake='version placement confirmed')
        metadata = {k: nxt[k] for k in ('actor', 'capability', 'due', 'wake')}
        metadata['source_id'] = row['id']
        metadata['action'] = 'next-step' if not close else 'version-reconciliation'
        metadata['decision_hash'] = decision_hash
        owe(['add', '--bucket', opt.bucket, '--chief', row['chief'], '--kind', 'step', '--key', row['key'],
             '--text', nxt['text'], '--identity', digest([row['identity'], decision_hash, metadata['action']]),
             '--metadata-stdin'], json.dumps(metadata))
    # Discharge only proof steps this handoff could cover, never later/new work
    # or a real chief/operator exception. Persist the replacement first on KEEP.
    for old in rows:
        if old['id'] in row.get('owed_refs', []) and not old['closed'] and old.get('key') == row['key'] and old['kind'] == 'step' and old.get('actor') == 'proof':
            owe(['close', '--bucket', opt.bucket, '--id', old['id'], '--key', row['key']])
    owe(['close', '--bucket', opt.bucket, '--id', row['id'], '--key', row['key'], '--metadata-stdin'], json.dumps({'outcome': outcome}))
    print(json.dumps({'id': row['id'], 'closed': True, 'outcome': outcome}))


def owe(args, metadata=None):
    command = ['bash', os.environ.get('PROOF_OWE_BIN', str(HERE / 'owe.sh')), *args]
    result = subprocess.run(command, input=metadata, text=True, capture_output=True)
    if result.returncode:
        raise RuntimeError('owed writer/read failed: ' + result.stderr.strip())
    return result.stdout.strip()


def shas(text):
    return [{'basis': basis, 'sha': sha} for basis, sha in sorted(set(
        re.findall(r'\b(main|station)=([0-9a-f]{7,40})(?![0-9a-f])', text)))]


def bounded_observations(meta):
    counts = {}
    for field, limit in [('proof_rows', 64), ('issues', 32), ('executed_shas', 64), ('required_shas', 64)]:
        values = meta.get(field, [])
        if field == 'issues':
            values = sorted(values, key=lambda value: value.startswith('malformed-row:'))
        kept = values[:limit]
        chars = 0
        if field in ('proof_rows', 'issues'):
            chars = sum(max(0, len(value) - 512) for value in kept)
            kept = [value[:512] for value in kept]
        counts[field] = dict(total=len(values), omitted=len(values) - len(kept), truncated_chars=chars)
        meta[field] = kept
    for field in ('next_action', 'wake'):
        if field in meta:
            size = len(meta[field])
            meta[field] = meta[field][:1024]
            counts[field] = dict(total=size, omitted=max(0, size - 1024), truncated_chars=max(0, size - 1024))
    meta['observation_counts'] = counts


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
        stored = [r for r in rows if r.get('action') == 'validate-proof' and r.get('source_label') == opt.label]
        docs = {r.get('source_doc') for r in stored if r.get('source_doc')}
        if len(docs) > 1:
            raise ValueError('ambiguous proof replay source')
        if docs:
            doc = docs.pop()
            try:
                source = read_text(doc)
            except (OSError, UnicodeError):
                pass
        if not source.strip():
            frozen = {}
            for r in stored:
                if r.get('key') and r.get('original_requirements_digest'):
                    frozen.setdefault(r['key'], set()).add(r['original_requirements_digest'])
            source = ''.join('requirements-sha256 %s=%s\n' % (k, next(iter(v))) for k, v in sorted(frozen.items()) if len(v) == 1)
    result_lines = []
    in_results = False
    for line in source.splitlines():
        if line.startswith('## '):
            in_results = bool(re.match(r'^## (?:Results|Chief Rulings|Console Rulings)\b', line))
        elif in_results:
            result_lines.append(line)
    if not any(line.startswith('## Results') for line in source.splitlines()):
        result_lines = source.splitlines()
    markers = [line for line in result_lines if status_marker_parse(line)]
    tail = markers[-1] if markers else ''
    header = re.findall(r'^> \*\*Proof leg:\*\* (.+)$', source, re.M)
    proof = bool(re.search(r'^(?:- (?:\d{1,2}:\d{2}[ \t]+)?)?(?:(?:N\d+[a-z]*|' + KEY + r')[ \t]+)*(?:\*\*)?WRAPPED\b[^\n]*\bproof\s+' + KEY,
                           tail + '\n' + message, re.I | re.M)
                 or header)
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
    prior = json.loads(owe(['list', '--bucket', opt.bucket, '--all', '--json'])) if not opt.dry_run else []
    for key in keys:
        unbound = [p for p in paths if not any(k in Path(p).name for k in keys)]
        attributed = [p for p in paths if key in Path(p).name]
        # No declared artifact is dropped: a ticket reads the artifacts that name it and those that name no ticket. A single ticket's
        # declaration attributes the unnamed ones; beside a named artifact with several tickets declared nothing does, which is an issue.
        candidates = attributed + unbound or paths or ['']
        unvalidated = (bool(paths) and not attributed and not unbound) or (len(keys) > 1 and bool(attributed) and bool(unbound))
        observations = []
        for path in candidates:
            issues = ['positive-controls-unvalidated', 'candidate-ancestry-unvalidated', 'coverage-unvalidated']
            if unvalidated:
                issues.append('artifact-attribution-unvalidated')
            meta = {'actor': 'chief', 'action': 'validate-proof', 'validation': 'pending',
                    'source_doc': str(Path(doc).resolve()) if doc else '', 'source_label': origin,
                    'evidence_path': path, 'binding': 'unknown', 'issues': issues,
                    'owed_refs': [r['id'] for r in prior if not r['closed'] and r.get('key') == key and r['kind'] == 'step' and r.get('actor') == 'proof']}
            artifact = ''
            try:
                raw = regular_bytes(path) if path else None
                if raw is None:
                    raise ValueError('missing evidence path')
                meta['evidence_hash'] = hashlib.sha256(raw).hexdigest()
                artifact = raw.decode('utf-8')
            except (OSError, UnicodeError, ValueError, MemoryError):
                issues.append('evidence-unreadable')
            mirror = Path(opt.mirror or os.environ.get('PROOF_MIRROR_DIR') or
                          Path.home() / '.himmel/state/jira-mirror' / key.split('-')[0])
            try:
                meta['requirements_digest'] = requirements(mirror / (key + '.md'))
            except (OSError, UnicodeError, ValueError, MemoryError):
                issues.append('requirements-unreadable')
            # The original requirement identity is the producer's: the generated brief freezes it above `## Results`. A line in
            # the worker's artifact or under its Results is a claim, never the original, so it can only agree or conflict.
            stamp_re = r'^requirements-sha256 ' + re.escape(key) + r'=([0-9a-f]{64})\s*$'
            brief = re.split(r'^## (?:Results|Chief Rulings|Console Rulings)\b', source, maxsplit=1, flags=re.M)[0]
            frozen = re.findall(stamp_re, brief, re.M)
            claimed = re.findall(stamp_re, artifact + '\n' + source[len(brief):], re.M)
            if len(set(frozen)) == 1 and not set(claimed) - set(frozen):
                meta['original_requirements_digest'] = frozen[0]
                if meta.get('requirements_digest'):
                    meta['binding'] = 'matched' if frozen[0] == meta['requirements_digest'] else 'mismatch'
            elif frozen:
                issues.append('requirements-stamp-conflict')
            elif claimed:
                issues.append('requirements-stamp-untrusted')
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
                                  re.search(r'\b(?:MET|OWED|NOT MET|SKIP\w*|ERRORS?|FAIL\w*)\b', line, re.I)]
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
        bounded_observations(meta)
        if not opt.dry_run:
            action = owe(['add', '--bucket', opt.bucket, '--chief', 'chief', '--kind', 'proof',
                          '--key', key, '--text', 'Validate proof ' + key + ': recommendation=' + meta['recommendation'] + '; pending chief validation/reconciliation',
                          '--identity', identity, '--metadata-stdin'], metadata=json.dumps(meta))
            print('PROOF-RECORDED ' + key + ' ' + action)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--bucket', required=True)
    parser.add_argument('--doc')
    parser.add_argument('--label', default='')
    parser.add_argument('--message-stdin', action='store_true')
    parser.add_argument('--mirror')
    parser.add_argument('--dry-run', action='store_true')
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument('--check', metavar='OWED_ID')
    mode.add_argument('--settle', metavar='OWED_ID')
    parser.add_argument('--decision')
    parser.add_argument('--decision-hash', help='the decision_hash the check returned; a settle refuses when the decision file no longer hashes to it')
    parser.add_argument('--current-stdin', action='store_true')
    opt = parser.parse_args()
    if (opt.check or opt.settle) and (not opt.decision or not opt.current_stdin or opt.dry_run or opt.doc or opt.message_stdin):
        parser.error('decision modes require --decision and --current-stdin; do not combine with recorder/dry-run arguments')
    if opt.decision_hash is not None and (not opt.settle or not re.fullmatch(r'[0-9a-f]{64}', opt.decision_hash)):
        parser.error('--decision-hash is a full sha256 and goes with --settle')
    try:
        if opt.check or opt.settle:
            decision(opt)
        else:
            record(opt)
    except (OSError, ValueError, RuntimeError, MemoryError, UnicodeError) as exc:
        print('proof-handoff: ' + str(exc), file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
