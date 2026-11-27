#!/usr/bin/env bash
# scripts/handover/chief-kit/brief-lint.sh [--core-only] <brief> - arming-time
# check that a worker or judge brief carries a filled `> **Prior art:**` line,
# and that a brief naming a core ticket has a signed minerva spec behind it.
#
# The chief fills the field at dispatch from one qmd query (jira-himmel +
# luna) and, when code structure matters, one graphify query, so the retrieval
# runs once and every worker inherits it. This is the structural half: a brief
# whose field is missing, empty, an unfilled `<placeholder>`, or a bare `none`
# fails. `none found (<query>)` passes - it names the query that came up empty.
# A worker brief (a `> **Contract:**` line; not --judge, not a doc that has run) must also carry the
# search directive in that field: the qmd-bounded.sh query over jira-himmel and luna, the worker-graph.sh
# lookup, both named, and the `graph-qmd:` Results bullet ("no Jira mirror" and "no graph lookup" stand in for
# the first and the second where the repo or the leg has none). A ticket key or #PR does not replace it.
#
# The field is the `> **Prior art:**` line plus any directly following `> `
# continuation lines (up to the next `> **Field:**`, a non-blockquote line, or
# an empty or whitespace-only `>` line).
#
# The core rule (last section) runs on every brief that names a ticket key in its
# title; --core-only runs it alone, for a launch that skips the prior-art check.
# --judge skips it: a judge brief writes nothing, so no spec stands behind it.
#
# The guard-lib rule also runs on every brief but a judge's, --core-only included. A worker that saves an edit to a file a
# guard runs or sources is locked out by the hook-integrity pin, so Writes naming one needs
# HIMMEL_HOOK_INTEGRITY_BYPASS_OK=1 in the lint's own environment. The files are the project members of each
# run-hook-with-bash.js command on an event where a failed check stops the next action, plus all they source, walked with
# this checkout's hook-integrity.js; nothing from the brief's resume_cwd runs.
#
# Exit 0 pass, 1 fail (reason on stderr), 2 usage, 3 refusal no flag clears: the core gate, the bucket rule, the guard-lib
# rule, a salus-marked brief that names a search, a resume_cwd the classifier cannot answer for, front matter that does not parse as YAML, or a
# worker brief whose resume_cwd is in a primary checkout.
set -u

core_only=0
judge=0
skip_bucket=0
while [ "${1:-}" = "--core-only" ] || [ "${1:-}" = "--judge" ] || [ "${1:-}" = "--skip-bucket" ]; do
    case "$1" in --core-only) core_only=1 ;; --judge) judge=1 ;; *) skip_bucket=1 ;; esac
    shift
done
if [ "$#" -ne 1 ]; then
    echo "usage: brief-lint.sh [--core-only] [--judge] [--skip-bucket] <brief>" >&2
    exit 2
fi
doc="$1"
if [ ! -f "$doc" ] || [ ! -r "$doc" ]; then
    echo "brief-lint: cannot read $doc" >&2
    exit 2
fi

field="$(awk '
    found == 0 && /^> \*\*Prior art( \([^)]*\))?:\*\*/ { found = 1; sub(/^> \*\*Prior art( \([^)]*\))?:\*\*/, ""); print; next }
    found == 1 {
        if ($0 !~ /^> / || $0 ~ /^>[[:space:]]*$/ || $0 ~ /^> \*\*[^*]+:\*\*/) exit
        sub(/^> /, ""); print
    }
' "$doc")"

# Collapse whitespace so a wrapped or padded field compares as one string.
flat="$(printf '%s' "$field" | tr '\n' ' ' | sed -E 's/[[:space:]]+/ /g; s/^ //; s/ $//')"

fail() { echo "brief-lint: $doc: $1" >&2; exit 1; }

# The core gate: every brief whose title names ticket keys is checked, whatever its shape and
# whether or not it has run. `release core-check` answers per key from the CLI and the operator records
# alone: NOT-CORE and BYPASS pass, UNKNOWN refuses, CORE needs `release spec-check` to answer SPEC ok.
# No line the brief writes itself can pass a key. BRIEF_LINT_JIRA_CLI and BRIEF_LINT_MIRROR are test seams.
resolve_cli() {
    local cli common
    cli="${BRIEF_LINT_JIRA_CLI:-}"
    if [ -z "$cli" ]; then
        # shellcheck source=../../lib/git-clean.sh
        . "$(dirname "$0")/../../lib/git-clean.sh"
        common="$(git_clean -C "$(dirname "$0")" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || common=""  # swallow-ok: no repository means the python stage reports the CLI as absent, which refuses
        if [ -z "$common" ]; then common="$(dirname "$0")/../../../.git"; fi
        cli="$(dirname "$common")/scripts/jira/dist/index.js"
    fi
    printf '%s' "$cli"
}

mirror_heal() {
    [ "$judge" -eq 0 ] || return 0
    [ "$skip_bucket" -eq 0 ] || return 0
    python3 -I "$(dirname "$0")/mirror_heal.py" "$doc" "$(resolve_cli)" >&2 || true  # swallow-ok: the heal is advisory, the rules that follow still refuse an unhealed mirror
}

core_rule() {
    local cli core_err core_rc=0 core_state_root=""
    [ "$judge" -eq 0 ] || return 0
    # The handover root turns an absolute Writes path under it into a non-core stand-in; without a resolvable root no absolute path counts.
    # shellcheck source=../../lib/load-dotenv.sh
    . "$(dirname "$0")/../../lib/load-dotenv.sh"
    # shellcheck source=../../lib/handover-path.sh
    . "$(dirname "$0")/../../lib/handover-path.sh"
    if load_dotenv HANDOVER_DIR 2>/dev/null; then
        core_state_root="$(handover_root 2>/dev/null)" || core_state_root=""  # swallow-ok: no root means no absolute Writes path counts, which can only refuse more
    fi
    cli="$(resolve_cli)"
    core_err="$(python3 -I - "$doc" "$cli" "$core_state_root" "$(cd "$(dirname "$0")" && pwd)" <<'PY'
import json, os, re, subprocess, sys
from datetime import datetime

sys.path.insert(0, sys.argv[4])
from mirror_heal import mirror_root

doc, cli = sys.argv[1], sys.argv[2]
lines = open(doc, encoding='utf-8', errors='replace').read().splitlines()
title = next((l for l in lines if l.startswith('# ')), '')
keys = list(dict.fromkeys(re.findall(r'\b[A-Z][A-Z0-9]*-[0-9]+\b', title)))
if not keys:
    sys.exit(0)
doc_state_root = os.path.realpath(sys.argv[3]) if sys.argv[3] else ''
# The file mentions of the ticket itself, read the way next-dispatchable.sh reads them: a relative Writes token is a path only when it reads as one of these.
FILE_RE = re.compile(r"(?<![\w./-])((?:scripts|docs|marketplace|plugins|templates|tools|\.claude|\.github|\.codex)/[\w.+@-]+(?:/[\w.+@-]+)*/?|CLAUDE\.md|AGENTS\.md|README\.md|package\.json|package-lock\.json|bun\.lock|uv\.lock|pyproject\.toml|\.gitignore|\.pre-commit-config\.yaml)")
DOCS_FILLER = {'writes', 'write', 'and', 'or', 'plus', 'also', 'the', 'a', 'an', 'only', 'new', 'edit', 'update', 'add', 'in', 'under', 'of', 'to', 'doc', 'docs', 'file', 'files', 'section', 'sections'}

def allowed_absolute(p):
    # the test of the Writes validation below: normalized, and under the resolved handover root
    return (bool(doc_state_root) and os.path.normpath(p) == p.rstrip('/') and
            os.path.commonpath((doc_state_root, os.path.realpath(p))) == doc_state_root)

text = ''
for i, line in enumerate(lines):
    if line.startswith('> **Writes:**'):
        text += ' ' + line[len('> **Writes:**'):]
        for nxt in lines[i + 1:]:
            if not nxt.startswith('> ') or nxt.startswith('> **'):
                break
            text += ' ' + nxt[2:]
# The path list comes from the one parser in holds.py, so the single-writer barrier and this core check read a Writes line the same
# way; `text` above stays raw, because raw_docs_only needs the prose tokens.
sys.path.insert(0, sys.argv[4])
import minerva_siblings  # noqa: E402
try:
    import holds  # noqa: E402
    tokens = [p for _kind, p in holds.parse_text('\n'.join(lines), os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(cli)))))]
    basis = ' '.join(tokens)
except Exception:  # swallow-ok: a broken holds.py must not fail the core check; it falls back to the raw split of the Writes text
    tokens = [t.rstrip('.,;:)]') for t in re.findall(r'[\w.+@/-]+', text)]
    basis = ''
sibling_paths = minerva_siblings.sibling_set(basis, doc_state_root)
text = minerva_siblings.fold(text, doc_state_root, basis)
tokens = [p for p in tokens if p not in sibling_paths]
paths, stray_absolute = [], False
for p in tokens:
    if p.startswith('/'):
        # core-check refuses an absolute path: a token under the handover root is sent as a relative non-core stand-in (a .md reads as docs)
        if not allowed_absolute(p):
            stray_absolute = True
            continue
        q = 'state/' + os.path.basename(p.rstrip('/'))
    elif FILE_RE.fullmatch(p) and not any(part in ('.', '..') for part in p.split('/')):
        q = p
    else:
        continue  # prose, a version, n/a, and/or: names no path
    if q not in paths:
        paths.append(q)

def raw_docs_only(scope):
    # gen-briefs.py docs_only: true only when every token of the Writes text is positively docs or a connector word
    toks = [t.rstrip('.,;:)]') for t in re.findall(r'[\w.+@/-]+', scope)]
    toks = [t for t in toks if t.strip('.-')]
    if not toks or not any(t.startswith('docs/') or t.endswith('.md') for t in toks):
        return False
    return all(t.startswith('docs/') or t.endswith('.md') or t.lower() in DOCS_FILLER for t in toks)

# a design leg is read from the brief's own Writes tokens only: never from a filtered list or the ticket's paths
docs_only = bool(paths) and not stray_absolute and raw_docs_only(text) and all(q.startswith('docs/') or q.endswith('.md') for q in paths)

def state_spec(t):
    # a state-repo specs/ .md file: relative to the bucket, or absolute under the handover root, never a repo path
    if not t.endswith('.md'):
        return False
    if t.startswith('/'):
        return allowed_absolute(t) and 'specs' in os.path.relpath(os.path.realpath(t), doc_state_root).split('/')[:-1]
    parts = t.split('/')
    return len(parts) > 1 and parts[0] == 'specs' and not any(p in ('', '.', '..') for p in parts)

# A minerva design leg: the exact `> **Design leg:** minerva` line, and every raw Writes token a state-repo specs/
# file. It reaches core-check as non-core state stand-ins with --docs-only, so a key core by its label alone answers BYPASS
# design; a single other token refuses the brief, because a design leg writes no repo file.
if any(l.rstrip() == '> **Design leg:** minerva' for l in lines):
    raw = [t.rstrip('.,;:)]') for t in re.findall(r'[\w.+@/-]+', text)]
    raw = [t for t in raw if t.strip('.-')]
    bad = [t for t in raw if not state_spec(t)]
    if not raw or bad:
        print('design leg: a `> **Design leg:** minerva` brief writes only state-repo specs/ .md files, and its Writes name %s; '
              'a build brief drops the marker and needs a signed minerva spec' % (', '.join(bad) if bad else 'nothing'))
        sys.exit(1)
    paths = list(dict.fromkeys('state/' + os.path.basename(t) for t in raw))
    docs_only = True

def ticket_paths(mirror, key):
    try:
        text = open(os.path.join(mirror, key + '.md'), encoding='utf-8', errors='replace').read()
    except OSError:
        return []
    if text.startswith('---'):
        text = text.split('---', 2)[-1]
    out = []
    for m in FILE_RE.finditer(text):
        f = re.sub(r'[.,;:)\]-]+$', '', m.group(1))
        if f and f not in out:
            out.append(f)
    return out

primary = os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(cli))))

def failed(why):
    print('CORE-CHECK-FAILED: build the jira CLI (npm --prefix %s/scripts/jira run build) -- %s' % (primary, why))
    sys.exit(1)

def run(args):
    # a missing CLI, node or a timeout is never an answer
    if not os.path.isfile(cli):
        failed('no built jira CLI at %s' % cli)
    try:
        # cwd inside the checkout that holds the CLI: it runs `git rev-parse` from its cwd
        return subprocess.run(['node', cli] + args, capture_output=True, text=True, timeout=120, cwd=os.path.dirname(os.path.abspath(cli)))
    except (OSError, subprocess.SubprocessError) as e:
        failed('node could not run %s (%s)' % (cli, e))

def per_key(out, ks, spec=False):
    got = {}
    for line in out.splitlines():
        t = line.split()
        if spec and t[:2] == ['SPEC', 'ok'] and len(t) >= 4:
            got[t[2]] = line
        elif t and (t[0] in ('SPEC-STALE', 'NO-SPEC', 'SPEC-NEEDS-OPERATOR', 'SPEC-SIGNER-UNKNOWN') if spec else t[0] in ('CORE', 'NOT-CORE', 'BYPASS', 'BYPASS-NEEDS-SPEC', 'UNKNOWN')) \
                and len(t) >= {'CORE': 3, 'BYPASS': 4, 'BYPASS-NEEDS-SPEC': 4, 'SPEC-NEEDS-OPERATOR': 5, 'SPEC-SIGNER-UNKNOWN': 4}.get(t[0], 2):
            got[t[1]] = line  # a line shorter than its verb needs is no answer: a truncated BYPASS must never read as a bypass
    return {k: got[k] for k in ks if k in got}

groups = {}
for k in keys:
    mirror = mirror_root(k)
    # no usable Writes path: classify by the paths the ticket itself names
    groups.setdefault((mirror, tuple(paths or ticket_paths(mirror, k)), docs_only and bool(paths)), []).append(k)
verdict, spec = {}, {}
for (mirror, kpaths, design), ks in groups.items():
    r = run(['release', 'core-check', '--paths', ','.join(kpaths)] + (['--docs-only'] if design else []) + ['--mirror', mirror, '--key'] + ks)
    if r.returncode != 0:
        failed('core-check exited %d: %s' % (r.returncode, (r.stderr or r.stdout).strip()[:200]))
    got = per_key(r.stdout, ks)
    if len(got) != len(ks):
        failed('core-check printed no parseable line for %s' % ', '.join(k for k in ks if k not in got))
    verdict.update(got)
    core = [k for k in ks if got[k].split()[0] == 'CORE']
    if core:
        r = run(['release', 'spec-check', '--mirror', mirror] + core)
        if r.returncode not in (0, 1):
            failed('spec-check exited %d: %s' % (r.returncode, (r.stderr or r.stdout).strip()[:200]))
        sgot = per_key(r.stdout, core, spec=True)
        if len(sgot) != len(core):
            failed('spec-check printed no parseable line for %s' % ', '.join(k for k in core if k not in sgot))
        spec.update(sgot)
refusals = []
log = os.path.join(os.path.dirname(os.path.abspath(doc)), 'core-gate.jsonl')
for k in keys:
    t = verdict[k].split()
    if t[0] == 'BYPASS':
        # a bypass is shown and logged, as gen-briefs does; the row lands beside the brief
        print('brief-lint: %s bypass=%s %s' % (k, t[2], ' '.join(t[3:])), file=sys.stderr)
        brief = os.path.abspath(doc)
        try:
            old = open(log, encoding='utf-8').read() if os.path.exists(log) else ''
            if not any('"key": "%s"' % k in l and json.dumps(brief) in l and '"outcome": "bypass"' in l for l in old.splitlines()):
                with open(log, 'a', encoding='utf-8') as f:
                    f.write(json.dumps(dict(ts=datetime.now().astimezone().isoformat(timespec='seconds'), key=k,
                        worker=os.path.basename(brief)[:-3], brief=brief, matched=None, outcome='bypass',
                        bypass=t[2], spec_check=verdict[k], chief='')) + '\n')
        except OSError as e:
            # a bypass with no record is refused, as gen-briefs core_log refuses it (spec I3: a bypass is logged)
            refusals.append('core brief %s bypass=%s was not recorded: core-gate.jsonl not written (%s); fix the bucket directory, then re-run' % (k, t[2], e))
    if t[0] == 'BYPASS-NEEDS-SPEC':
        refusals.append('core brief %s is core and its %s bypass waives the signature, never the spec: %s; run minerva to one critic round (a docs-only design leg may write it), then jira release operator spec-review' % (k, t[2], ' '.join(t[3:])))
    if t[0] == 'UNKNOWN':
        refusals.append('core brief %s is not in the Jira mirror, so neither core nor a bypass can be proven; refresh the mirror, then re-run' % k)
    elif t[0] == 'CORE' and spec[k].split()[0] == 'SPEC-NEEDS-OPERATOR':
        s = spec[k].split()
        refusals.append("core brief %s is core (%s) and needs the operator's own signature (%s): the chief's signature %s does not count; "
                        'see jira release signer-check %s, then the operator signs it (jira release operator spec <release> ... --signer operator --supersedes %s)'
                        % (k, ' '.join(t[2:]), s[-1], s[-2], k, s[-2]))
    elif t[0] == 'CORE' and spec[k].split()[0] == 'SPEC-SIGNER-UNKNOWN':
        s = spec[k].split(None, 3)
        refusals.append('core brief %s is core (%s) and its chief signature %s cannot be checked: signer records unreadable: %s; repair the release named, then re-run'
                        % (k, ' '.join(t[2:]), s[2], s[3]))
    elif t[0] == 'CORE' and not spec[k].startswith('SPEC ok'):
        refusals.append('core brief %s is core (%s) and has no signed minerva spec: %s; run minerva, then jira release operator spec' % (k, ' '.join(t[2:]), spec[k]))
if refusals:
    print('; '.join(refusals))
    sys.exit(1)
PY
)" || core_rc=$?
    if [ "$core_rc" -ne 0 ]; then
        echo "brief-lint: $doc: $core_err" >&2
        exit 3
    fi
}

bucket_rule() {
    local cli ran=0 bucket_err bucket_rc=0
    [ "$judge" -eq 0 ] || return 0
    [ "$skip_bucket" -eq 0 ] || return 0
    cli="$(resolve_cli)"
    worker_doc_has_run "$doc" && ran=1
    bucket_err="$(python3 -I - "$doc" "$cli" "$ran" "$(cd "$(dirname "$0")" && pwd)" <<'PY'
import os, re, subprocess, sys

sys.path.insert(0, sys.argv[4])
from mirror_heal import brief_keys, mirror_root

doc, cli, ran = sys.argv[1], sys.argv[2], sys.argv[3] == '1'
keys = brief_keys(doc)
if not keys:
    sys.exit(0)

raw = os.environ.get('BRIEF_LINT_VERDICT_TIMEOUT', '')
timeout = 120
if raw != '':
    if not re.fullmatch(r'[0-9]+', raw) or int(raw) < 1:
        print('BRIEF_LINT_VERDICT_TIMEOUT must be a whole number of seconds from 1 up (it is capped at 120), and it is %r' % raw)
        sys.exit(1)
    timeout = min(int(raw), 120)

primary = os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(cli))))

def failed(why):
    print('BUCKET-CHECK-FAILED: build the jira CLI (npm --prefix %s/scripts/jira run build) -- %s' % (primary, why))
    sys.exit(1)

groups = {}
for k in keys:
    groups.setdefault(mirror_root(k), []).append(k)

VERDICTS = ('IN', 'NONE', 'APPROVED', 'DONE', 'OUTSIDE', 'FAILED')
got = {}
for mirror, ks in groups.items():
    if not os.path.isfile(cli):
        failed('no built jira CLI at %s' % cli)
    try:
        r = subprocess.run(['node', cli, 'release', 'bucket-check', '--mirror', mirror] + ks, capture_output=True, text=True,
                           timeout=timeout, cwd=os.path.dirname(os.path.abspath(cli)))
    except subprocess.TimeoutExpired:
        failed('release bucket-check timed out after %d seconds' % timeout)
    except (OSError, subprocess.SubprocessError) as e:
        failed('node could not run %s (%s)' % (cli, e))
    if r.returncode != 0:
        failed('release bucket-check exited %d: %s' % (r.returncode, (r.stderr or r.stdout).strip()[:200]))
    for line in r.stdout.splitlines():
        t = line.split()
        if len(t) >= 2 and t[0] in VERDICTS and t[1] in ks:
            got[t[1]] = line
    missing = [k for k in ks if k not in got]
    if missing:
        failed('release bucket-check printed no parseable line for %s' % ', '.join(missing))

REASON = {'NONE': 'no-versions', 'APPROVED': 'out-of-version', 'DONE': 'done-relaunch'}
refusals = []
for k in keys:
    t = got[k].split()
    verdict, rest = t[0], ' '.join(t[2:])
    if verdict == 'IN':
        continue
    if verdict in ('NONE', 'APPROVED') or (verdict == 'DONE' and ran):
        print(('brief-lint: %s bypass=%s %s' % (k, REASON[verdict], rest)).rstrip(), file=sys.stderr)
    elif verdict == 'DONE':
        refusals.append('%s is Done. Why launch it? File a new ticket with `--follow-up-of`, or reopen it.' % k)
    elif verdict == 'FAILED':
        refusals.append('%s: bucket-check FAILED, so the launch is refused rather than passed unread: %s' % (k, rest))
    else:
        m = re.fullmatch(r'(\S+) current=(\S+) open=(\S+)', rest)
        if not m:
            refusals.append('%s: bucket-check printed an OUTSIDE line this lint cannot read: %s' % (k, got[k]))
            continue
        version, current, opened = m.groups()
        refusals.append(
            '%s is in %s, current is %s, %s open. A ticket in a later version is there on purpose: the door places it by priority. Why this ticket and not the bucket? If the operator approved it as out of version: '
            '`jira release operator out-of-version`. To place it in the bucket: `jira release request`, and the release manager rules it. '
            'Do not use an approval to run parallel work outside the bucket. At 0 open the version is done: run READY, and the operator '
            'releases it in Jira.' % (k, 'no version' if version == 'none' else version, current, opened))
if refusals:
    print('\n'.join(refusals))
    sys.exit(1)
PY
)" || bucket_rc=$?
    if [ "$bucket_rc" -ne 0 ]; then
        echo "brief-lint: $doc: $bucket_err" >&2
        exit 3
    fi
}

IFS= read -r -d '' GL_TOKENS_PY <<'PY' || true  # swallow-ok: read -d '' returns 1 at the end of the text, by design
import os, re, sys

doc, root, kit = sys.argv[1], sys.argv[2], sys.argv[3]
text = open(doc, encoding='utf-8', errors='replace').read()
roots = [root.rstrip('/'), os.path.realpath(root)]
sys.path.insert(0, kit)

def under_root(p):
    for r in roots:
        if p == r:
            return ''
        if p.startswith(r + '/'):
            return p[len(r) + 1:]
    return None

out = []
try:
    import holds
    for kind, p in holds.parse_text(text, root):
        if kind == 'file':
            for r in roots:
                got = holds.normalize(r, p)
                if got and got[0] != '_abs':
                    out.append(('file', got[1]))
                    break
        else:
            rel = under_root(os.path.normpath(p)) if os.path.isabs(p) else os.path.normpath(p)
            if rel is not None:
                out.append(('tree', '' if rel in ('', '.') else holds.canon(rel, root).rstrip('/') + '/'))
except Exception as ex:
    print('brief-lint: holds.py could not read the Writes line (%s: %s); reading it by the raw split' % (type(ex).__name__, ex), file=sys.stderr)
    out = []
    lines = text.splitlines()
    scope = ''
    for i, line in enumerate(lines):
        if line.startswith('> **Writes:**'):
            scope += ' ' + line[len('> **Writes:**'):]
            for nxt in lines[i + 1:]:
                if not nxt.startswith('> ') or nxt.startswith('> **'):
                    break
                scope += ' ' + nxt[2:]
    for tok in (t.rstrip('.,;:)]') for t in re.findall(r'[\w.+@/-]+', scope)):
        if not tok.strip('./-'):
            continue
        n = os.path.normpath(tok)
        rel = under_root(n) if os.path.isabs(n) else n
        if rel is None:
            continue
        if tok.endswith('/') or rel == '' or os.path.isdir(os.path.join(root, rel)):
            out.append(('tree', '' if rel == '' else rel + '/'))
        else:
            out.append(('file', rel))
could_name_a_closure_file = any(k == 'tree' or p.endswith('.sh') for k, p in out)
if not could_name_a_closure_file:
    sys.exit(10)
for k, p in out:
    print('%s\t%s' % (k, p))
PY

IFS= read -r -d '' GL_WALK_JS <<'JS' || true  # swallow-ok: read -d '' returns 1 at the end of the text, by design
const fs = require('fs');
const path = require('path');
const [resolver, rootArg, pluginsDir, tokenText, eventText] = process.argv.slice(1);
function Unreadable(m) { this.message = m; }
try {
  const kit = require(path.resolve(resolver));
  const root = fs.realpathSync(rootArg);
  const tokens = tokenText.split('\n').filter(Boolean).map((l) => l.split('\t'));
  const pinned = tokens.some(([k, p]) => kit.PIN_DIRS.some((d) => (k === 'file'
    ? p.startsWith(`${d}/`) : `${d}/`.startsWith(p) || p.startsWith(`${d}/`))));
  if (!pinned) process.exit(0);
  const files = [];
  const settings = path.join(root, '.claude', 'settings.json');
  if (fs.existsSync(settings)) files.push([settings, '.claude/settings.json']);
  if (fs.existsSync(pluginsDir)) {
    for (const name of fs.readdirSync(pluginsDir).sort()) {
      const f = path.join(pluginsDir, name, 'hooks', 'hooks.json');
      if (fs.existsSync(f)) files.push([f, `marketplace/plugins/${name}/hooks/hooks.json`]);
    }
  }
  const skip = new Set(eventText.split(' '));
  const members = new Set();
  const PROJECT = [/^"\$CLAUDE_PROJECT_DIR\/([A-Za-z0-9._/-]+\.sh)"$/, /^"\$\{CLAUDE_PROJECT_DIR\}\/([A-Za-z0-9._/-]+\.sh)"$/,
    /^\$CLAUDE_PROJECT_DIR\/([A-Za-z0-9._/-]+\.sh)$/, /^\$\{CLAUDE_PROJECT_DIR\}\/([A-Za-z0-9._/-]+\.sh)$/];
  const bare = (w) => w.replace(/["']/g, '');
  const readSegmentAsParseHookArgs = (segment, where) => {
    const bad = (word) => { throw new Unreadable(`cannot read hook command ${where} as members (${word}): refusing rather than reading it as none`); };
    const words = segment.match(/(?:"[^"]*"|'[^']*'|[^\s"'])+|["']/g) || [];
    let chain = false;
    let lifecycle = false;
    let optional = false;
    let failClosed = false;
    let i = 0;
    while (i < words.length && bare(words[i]).startsWith('--')) {
      const flag = bare(words[i]);
      if (flag === '--chain') chain = true;
      else if (flag === '--lifecycle') lifecycle = true;
      else if (flag === '--optional') optional = true;
      else if (flag === '--fail-closed-when') {
        if (!/^[A-Za-z_][A-Za-z0-9_]*=/.test(bare(words[i + 1] || ''))) bad(words[i + 1] || flag);
        failClosed = true;
        i += 1;
      } else bad(flag);
      i += 1;
    }
    const rest = words.slice(i);
    if (!rest.length) bad('(no member)');
    if (failClosed && !optional) bad('--fail-closed-when');
    if (chain && (optional || failClosed)) bad('--chain');
    if (lifecycle && !chain) bad('--lifecycle');
    for (const word of chain ? rest : [rest[0]]) {
      if (word.startsWith('${CLAUDE_PLUGIN_ROOT}') || word.startsWith('"${CLAUDE_PLUGIN_ROOT}')) continue;
      const hit = PROJECT.map((re) => word.match(re)).find(Boolean);
      if (!hit || hit[1].split('/').includes('..')) bad(word);
      if (!chain) {
        process.env.CLAUDE_PROJECT_DIR = root;
        if (kit.isWatchdogMember(path.join(root, hit[1]))) continue;
      }
      members.add(hit[1]);
    }
  };
  for (const [file, shown] of files) {
    const hooks = JSON.parse(fs.readFileSync(file, 'utf8')).hooks || {};
    for (const event of Object.keys(hooks)) {
      if (skip.has(event)) continue;
      let n = 0;
      for (const group of hooks[event]) {
        for (const hook of group.hooks || []) {
          n += 1;
          const command = String(hook.command || '');
          const found = /run-hook-with-bash\.js["']?/g;
          while (found.exec(command)) {
            readSegmentAsParseHookArgs(command.slice(found.lastIndex).split(/;|&&|\|\|/)[0], `${shown} ${event} #${n}`);
          }
        }
      }
    }
  }
  const libsOf = new Map();
  const closure = new Map();
  const isFile = (f) => {
    try { return fs.statSync(f).isFile(); } catch (e) { if (e.code === 'ENOENT' || e.code === 'ENOTDIR') return false; throw e; }
  };
  for (const member of members) {
    const start = path.join(root, member);
    if (!isFile(start)) continue;
    const seen = new Set([start]);
    const queue = [start];
    while (queue.length) {
      const file = queue.shift();
      const rel = path.relative(root, file);
      if (!closure.has(rel)) closure.set(rel, new Set());
      closure.get(rel).add(member);
      if (!libsOf.has(file)) libsOf.set(file, kit.sourcedClosure(file, root).libs);
      for (const lib of libsOf.get(file)) {
        const inside = path.relative(root, lib);
        if (seen.has(lib) || inside.startsWith('..') || path.isAbsolute(inside) || !isFile(lib)) continue;
        seen.add(lib);
        queue.push(lib);
      }
    }
  }
  for (const rel of [...closure.keys()].sort()) process.stdout.write(`${[rel, ...[...closure.get(rel)].sort()].join('\t')}\n`);
} catch (e) {
  process.stdout.write(`${String((e && e.message) || e).split('\n')[0]}\n`);
  process.exitCode = e instanceof Unreadable ? 4 : 5;
}
JS

IFS= read -r -d '' GL_VERDICT_PY <<'PY' || true  # swallow-ok: read -d '' returns 1 at the end of the text, by design
import os, sys

doc, tokens, closure = sys.argv[1], sys.argv[2], sys.argv[3]
rows = [l.split('\t') for l in closure.splitlines() if l]
toks = [l.split('\t') for l in tokens.splitlines() if l]
hits = sorted((r for r in rows if any(r[0] == p if k == 'file' else r[0].startswith(p) for k, p in toks)), key=lambda r: r[0])
if not hits:
    sys.exit(0)
more = ', and %d more' % (len(hits) - 5) if len(hits) > 5 else ''
if os.environ.get('HIMMEL_HOOK_INTEGRITY_BYPASS_OK') == '1':
    print('brief-lint: guard-lib bypass=hook-integrity %s%s' % (', '.join(r[0] for r in hits[:5]), more), file=sys.stderr)
    sys.exit(0)
named = ', '.join('%s (run by %s%s)' % (r[0], r[1], ' +%d' % (len(r) - 2) if len(r) > 2 else '') for r in hits[:5])
print('brief-lint: %s: launch with HIMMEL_HOOK_INTEGRITY_BYPASS_OK=1 ("hook": true in workers.json) only if the ticket edits these files the pinned guards run, else drop them from Writes: %s%s' % (doc, named, more), file=sys.stderr)
print('fix: gen-briefs.py exports the bypass in the launcher of a "hook": true worker; for a hand launch, export HIMMEL_HOOK_INTEGRITY_BYPASS_OK=1 in the shell that runs headed-arm-worker.sh. The bypass switches off the integrity pin and the worker write fence\'s pin-dir and anchor fences for the whole session', file=sys.stderr)
sys.exit(3)
PY

guard_lib_rule() {
    local NON_LOCKOUT_EVENTS kit resolver tokens closure rc=0
    NON_LOCKOUT_EVENTS="Stop SubagentStop TeammateIdle TaskCompleted PreCompact PostToolUse PostToolUseFailure SessionStart SessionEnd Notification PermissionDenied"
    [ "$judge" -eq 0 ] || return 0
    { [ "${cwd#/}" != "$cwd" ] && [ -d "$cwd" ]; } || return 0
    kit="$(cd "$(dirname "$0")" && pwd)"
    tokens="$(python3 -I -c "$GL_TOKENS_PY" "$doc" "$cwd" "$kit")" || rc=$?
    [ "$rc" -ne 10 ] || return 0
    if [ "$rc" -ne 0 ]; then
        echo "brief-lint: $doc: cannot work out which files the pinned guards run under $cwd (the Writes line could not be read, exit $rc): refusing rather than reading it as none" >&2
        exit 3
    fi
    resolver="$kit/../../hooks/hook-integrity.js"
    if [ ! -f "$resolver" ]; then
        echo "brief-lint: guard-lib skipped=no-resolver $resolver" >&2
        return 0
    fi
    closure="$(node -e "$GL_WALK_JS" "$resolver" "$cwd" "$kit/../../../marketplace/plugins" "$tokens" "$NON_LOCKOUT_EVENTS")" || rc=$?
    if [ "$rc" -eq 4 ]; then
        echo "brief-lint: $doc: $closure" >&2
        exit 3
    elif [ "$rc" -ne 0 ]; then
        echo "brief-lint: $doc: cannot work out which files the pinned guards run under $cwd (${closure:-node exited $rc}): refusing rather than reading it as none" >&2
        exit 3
    fi
    rc=0; python3 -I -c "$GL_VERDICT_PY" "$doc" "$tokens" "$closure" || rc=$?
    [ "$rc" -eq 0 ] || exit 3
}

# The directory the worker starts in, read the way headed-arm-worker.sh reads it: the front-matter line, trimmed, quotes
# stripped, a leading ~ expanded. This block is the launcher's, line for line (test-brief-lint.sh compares them).
cwd="$(awk '
    /^---[[:space:]]*$/ { fm++; if (fm == 2) exit; next }
    fm == 1 && /^resume_cwd:[[:space:]]*/ { sub(/^resume_cwd:[[:space:]]*/, ""); print; exit }
' "$doc" 2>/dev/null)"
cwd="${cwd%"${cwd##*[![:space:]]}"}"
cwd="${cwd#\'}"; cwd="${cwd%\'}"
cwd="${cwd#\"}"; cwd="${cwd%\"}"
case "$cwd" in \~|\~/*) cwd="${HOME:-}${cwd#\~}" ;; esac

# Classify a directory: salus-marked or an adopted repo. salus_marked.py answers 0 (yes) or 10 (no); a missing or crashing
# classifier answers neither, and the brief is refused (exit 3, which no flag clears) rather than read as not marked.
classify() { # salus|adapter dir; returns 0 yes, 10 no
    local rc=0
    python3 -I "$(dirname "$0")/salus_marked.py" "$1" "$2" >/dev/null 2>&1 || rc=$?
    case "$rc" in
        0|10) return "$rc" ;;
        *) echo "brief-lint: $doc: cannot classify resume_cwd '$2' (salus_marked.py exited $rc): refusing rather than reading it as not salus-marked" >&2; exit 3 ;;
    esac
}

# A salus-marked directory searches nothing, because a query would send text off this machine: its brief names no search
# command anywhere (judge and resumed docs included, --core-only too), and a worker brief says so in words below. This runs
# before the --core-only exit, so --no-prior-art-check cannot clear it, and it exits 3 so the launcher's refusal offers no
# flag. A relative resume_cwd is classified as written (the launcher resolves it against its own directory); the Contract
# check below still refuses it for a fresh worker brief.
is_salus=0
if [ -n "$cwd" ]; then
    rc=0; classify salus "$cwd" || rc=$?
    [ "$rc" -eq 0 ] && is_salus=1
fi
if [ "$is_salus" -eq 1 ] && grep -Eq -- 'qmd-bounded|worker-graph|graphify|-c[[:space:]]+(luna|jira-himmel)' "$doc"; then
    echo "brief-lint: $doc: resume_cwd '$cwd' is salus-marked: this brief must search nothing (a query would send text off this machine). Remove every notes-search and graph-lookup command and say 'no notes search and no graph lookup' instead" >&2
    exit 3
fi

# The front matter must parse as YAML, the way qmd reads it: a fresh brief whose block does not parse, repeats a key or
# wraps a quoted value over lines is invisible to metadata-filtered search. Like the refusal above it runs before the
# --core-only exit, so --no-prior-art-check cannot clear it, and it exits 3 so the launcher offers no flag. A doc that
# has run is exempt, and so is one with no description (its own message below); the session_ids: line is blanked
# because the lock writer owns it and heals it at launch. The refusal is exactly two lines, the problem and the fix,
# because a generated launcher prints only the last two. Each refusal appends a row to front-matter-refusals.jsonl
# beside the brief. No PyYAML passes and says so, on a line the launcher shows.
# shellcheck source=../../lib/worker-identity.sh
. "$(dirname "$0")/../../lib/worker-identity.sh"
IFS= read -r -d '' FM_PY <<'PY' || true  # swallow-ok: read -d '' returns 1 at the end of the text, by design
import json, os, re, sys
from datetime import datetime

doc = sys.argv[1]
raw = open(doc, encoding='utf-8', errors='replace').read()
if raw.startswith('﻿'):
    raw = raw[1:]
lines = raw.split('\n')

def cmp(s):
    return s.rstrip(' \t\r')

# the block as qmd slices it: opens on ---, closes on the first --- or ...; no complete block, nothing to parse
if cmp(lines[0]) != '---':
    sys.exit(0)
close = next((i for i in range(1, len(lines)) if cmp(lines[i]) in ('---', '...')), None)
if close is None:
    sys.exit(0)
blk = [l.rstrip('\r') for l in lines[1:close]]
blk = ['' if l.startswith('session_ids:') else l for l in blk]
text = '\n'.join(blk)
try:
    import yaml
except ImportError:
    print('brief-lint: bypass=no-pyyaml %s' % doc, file=sys.stderr)
    sys.exit(0)

def fm_scalar(s):
    return json.dumps(' '.join(s.split()), ensure_ascii=False)

d = next((i for i, l in enumerate(blk) if l.startswith('description:')), None)
e = None
if d is not None:
    e = next((i for i in range(d + 1, len(blk)) if re.match(r'[\w.-]+:(\s|$)', blk[i])), len(blk))
    while e - 1 > d and not blk[e - 1].strip():
        e -= 1

def walk(node, seen):
    # a repeated scalar key, or a quoted scalar that spans lines; seen ends a recursive alias
    if id(node) in seen:
        return None
    seen.add(id(node))
    if isinstance(node, yaml.ScalarNode):
        if node.style in ('"', "'") and node.start_mark.line != node.end_mark.line:
            return ('wrap', node)
    elif isinstance(node, yaml.MappingNode):
        keys = set()
        for k, v in node.value:
            if isinstance(k, yaml.ScalarNode) and k.tag != 'tag:yaml.org,2002:merge':
                ident = (k.tag, k.value)
                if ident in keys:
                    return ('dup', k)
                keys.add(ident)
            for child in (k, v):
                found = walk(child, seen)
                if found:
                    return found
    elif isinstance(node, yaml.SequenceNode):
        for child in node.value:
            found = walk(child, seen)
            if found:
                return found
    return None

problem = fix = None
line = 2
generic = 'double-quote a value holding a colon and keep it on one line; remove a repeated key'
try:
    yaml.safe_load(text)
    root = yaml.compose(text, Loader=yaml.SafeLoader)
    found = walk(root, set()) if root is not None else None
    if found is None:
        sys.exit(0)
    kind, node = found
    line = node.start_mark.line + 2
    if kind == 'dup':
        problem = 'repeated key %s' % node.value
    else:
        problem = 'a quoted value wraps over lines'
        if d is not None:
            top = root.value if isinstance(root, yaml.MappingNode) else []
            for k, v in top:
                if v is node and k.value == 'description':
                    fix = 'replace lines %d-%d with: description: %s' % (k.start_mark.line + 2, node.end_mark.line + 2, fm_scalar(node.value))
except Exception as ex:
    marks = [m for m in (getattr(ex, 'problem_mark', None), getattr(ex, 'context_mark', None)) if m is not None]
    msg = getattr(ex, 'problem', None) or (str(ex).splitlines() or [type(ex).__name__])[0]
    problem = ' '.join(str(msg).split())
    if marks:
        line = marks[0].line + 2
        if d is not None and any(d <= m.line < e for m in marks):
            first = blk[d][len('description:'):]
            body = ' '.join([first] + blk[d + 1:e])
            fix = 'replace lines %d-%d with: description: %s' % (d + 2, e + 1, fm_scalar(body))
print('%s:%d: %s' % (doc, line, problem))
print(fix or generic)
try:
    with open(os.path.join(os.path.dirname(os.path.abspath(doc)), 'front-matter-refusals.jsonl'), 'a', encoding='utf-8') as f:
        f.write(json.dumps(dict(ts=datetime.now().astimezone().isoformat(timespec='seconds'), brief=os.path.abspath(doc), line=line)) + '\n')
except OSError:
    pass
sys.exit(1)
PY
if [ -n "$(worker_description_field "$doc")" ] && ! worker_doc_has_run "$doc"; then
    fm_rc=0
    fm_out="$(python3 -I -c "$FM_PY" "$doc")" || fm_rc=$?
    if [ "$fm_rc" -ne 0 ]; then
        printf '%s\n' "$fm_out" >&2
        exit 3
    fi
fi

# A worker brief (a `> **Contract:**` line, not --judge, fresh or resumed) names a worktree as its resume_cwd, never a
# primary checkout, where the single-writer guard refuses the worker's writes. salus_marked.py primary answers by stat
# alone, with the guard's own test (the nearest .git is a directory and there is no .single-writer file), and prints the
# root. Like the two refusals above it runs before the --core-only exit and exits 3, so no flag clears it; a classifier
# that answers neither yes nor no refuses too. The refusal is two lines, the problem and the fix, for the launcher's tail.
if [ "$judge" -eq 0 ] && [ -n "$cwd" ] && grep -Eq '^> \*\*Contract:\*\*' "$doc"; then
    rc=0; prim_root="$(python3 -I "$(dirname "$0")/salus_marked.py" primary "$cwd" 2>/dev/null)" || rc=$?  # swallow-ok: rc is kept and any answer but 0 or 10 refuses below
    case "$rc" in
        0)
            new_wt="$(cd "$(dirname "$0")/../.." && pwd)/_new-worktree.sh"
            printf '%s\n' "brief-lint: $doc: resume_cwd '$cwd' is inside the primary checkout $prim_root (its .git is a directory and it has no .single-writer file): a worker brief's resume_cwd names a worktree, never a primary checkout" >&2
            printf '%s\n' "fix: give every worker a worktree, a leg that writes no repo file included: from $prim_root run bash scripts/worktree.sh new <type>/<slug> --no-prune (in a repo without that script: bash $new_wt <type>/<slug> --no-install), then set resume_cwd to the worktree's absolute path" >&2
            exit 3
            ;;
        10) ;;
        *)
            echo "brief-lint: $doc: cannot classify resume_cwd '$cwd' (salus_marked.py primary exited $rc): refusing rather than reading it as not a primary checkout" >&2
            exit 3
            ;;
    esac
fi

if [ "$core_only" -eq 1 ]; then
    guard_lib_rule
    mirror_heal
    core_rule
    bucket_rule
    exit 0
fi

grep -Eq '^> \*\*Prior art( \([^)]*\))?:\*\*' "$doc" || fail "no '> **Prior art:**' line (required: related tickets, prior fixes, graph neighbours with their source, or 'none found (<query>)')"
[ -n "$flat" ] || fail "'> **Prior art:**' is empty"

lower="$(printf '%s' "$flat" | tr '[:upper:]' '[:lower:]')"
case "$lower" in
    "<"*">") fail "'> **Prior art:**' is still the template placeholder" ;;
esac
bare="$(printf '%s' "$lower" | sed -E 's/[[:punct:][:space:]]+$//')"
[ "$bare" != "none" ] || fail "'> **Prior art:**' is a bare 'none': name the query that found nothing, as 'none found (<query>)'"
case "$bare" in
    "none found"*)
        printf '%s' "$lower" | grep -Eq '^none found \([^)[:space:]][^)]*\)' \
            || fail "'none found' needs the query that found nothing: 'none found (<query>)'"
        ! printf '%s' "$lower" | grep -Eq '^none found \(<[^>]*>\)' \
            || fail "'none found' still carries the '<query>' placeholder: name the query that found nothing"
        ;;
esac

# shellcheck source=../../lib/load-dotenv.sh
. "$(dirname "$0")/../../lib/load-dotenv.sh"
load_dotenv HANDOVER_DIR || fail "cannot load configured handover root"
# shellcheck source=../../lib/handover-path.sh
. "$(dirname "$0")/../../lib/handover-path.sh"
# Without a resolved state root, only relative Writes can pass.
state_root=""
if resolved_root="$(handover_root)"; then
    state_root="$resolved_root"
fi
if ! python3 -I - "$doc" "$(dirname "$0")/../../.." "$state_root" <<'PY'
import os, re, sys

lines = open(sys.argv[1], encoding='utf-8', errors='replace').read().splitlines()
repo = sys.argv[2]
state_root = os.path.realpath(sys.argv[3]) if sys.argv[3] else ''

def allowed_absolute(p):
    return (bool(state_root) and os.path.normpath(p) == p.rstrip('/') and
            os.path.commonpath((state_root, os.path.realpath(p))) == state_root)

for i, line in enumerate(lines):
    if not line.startswith('> **Writes:**'):
        continue
    text = line[len('> **Writes:**'):]
    for nxt in lines[i + 1:]:
        if not nxt.startswith('> ') or nxt.startswith('> **'):
            break
        text += ' ' + nxt[2:]
    if text.strip() == 'none named':
        continue
    paths = [p for p in re.split(r'[\s,`]+', text.strip()) if p]
    if not paths or any(not re.fullmatch(r'[\w.+@/-]+', p) or
                        (os.path.isabs(p) and not allowed_absolute(p)) or
                        any(part in ('.', '..') for part in p.split('/')) or
                        not ('/' in p or '.' in p or os.path.exists(os.path.join(repo, p))) for p in paths):
        sys.exit(1)
PY
then
    fail "'> **Writes:**' must contain repo-relative paths or normalized absolute paths under the configured handover root, without . or .. segments (or 'none named'); the chief fills an empty line from the ticket's Writes text; move parentheses and prose to '> **Writes note:**'"
fi

# a fresh brief carries a front-matter `description:` line, the
# plain-language line every surface shows next to the worker's label. A doc whose
# Results section already holds a bullet has run, and was briefed before the
# field existed, so it passes without one.
if [ -z "$(worker_description_field "$doc")" ] && ! worker_doc_has_run "$doc"; then
    fail "no front-matter 'description:' line (required: one plain-language line saying what this worker is doing and why, e.g. 'description: \"Add a description line to every worker brief\"'; put it between the leading '---' lines, the first of which must be the file's first line with no blank line or BOM before it; see docs/handover/worker-brief-template.md)"
fi

if [ "$judge" -eq 0 ] && grep -Eq '^> \*\*Contract:\*\*' "$doc" && ! worker_doc_has_run "$doc"; then
    ship_line="$(grep -E '^> 4\. Ship:' "$doc")"
    ct_hdr="$(grep -Eio '^> \*\*Completes ticket:\*\* *(yes|no)\b' "$doc" | grep -Eio '(yes|no)$' | tr '[:upper:]' '[:lower:]')"
    ct_ship="$(grep -Eio 'completes-ticket: *(yes|no)\b' <<< "$ship_line" | grep -Eio '(yes|no)$' | tr '[:upper:]' '[:lower:]')"
    ct_desc="$(worker_description_field "$doc" | grep -Eio 'completes[- ]ticket: *(yes|no)\b' | grep -Eio '(yes|no)$' | tr '[:upper:]' '[:lower:]')"
    ct_vals="$(printf '%s\n%s\n%s\n' "$ct_hdr" "$ct_ship" "$ct_desc" | grep -E '^(yes|no)$' | sort -u | tr '\n' ' ')"
    case "$ct_vals" in
        "no yes "*) fail "the brief states two completes-ticket answers (header: ${ct_hdr:-none}; Ship step: ${ct_ship:-none}; description: ${ct_desc:-none}): one value, in every place the brief states it" ;;
    esac
    if [ "$ct_vals" = "no " ] && [[ "$ship_line" == *--jira-transition* ]]; then
        fail "the brief says completes-ticket: no but its Ship step names --jira-transition, which closes the ticket: a no brief merges bare"
    fi
fi

# A worker brief (one with a `> **Contract:**` line) tells its worker to search the notes (both collections) and the
# graph before it designs, with the query and symbol named, and to report what each returned. A cited ticket key or
# #PR does not stand in for it: naming the query is what moved use in the audit, a bare mention moved little. A judge
# brief writes nothing and is not held to it, and a doc whose Results already holds a bullet has run (a resume that
# only ships) and is not made to fail.
# Each of the words "no notes search", "no Jira mirror" and "no graph lookup" stands in for its command only when it is true,
# judged from the brief's own resume_cwd: a salus-marked directory searches nothing, an adopted repo has no Jira mirror and
# no himmel graph, and a leg whose Writes line says none named has no symbol to look up.
if [ "$judge" -eq 0 ] && grep -Eq '^> \*\*Contract:\*\*' "$doc" && ! worker_doc_has_run "$doc"; then
    [ "${cwd#/}" != "$cwd" ] || fail "no absolute front-matter 'resume_cwd:' line (got '${cwd:-nothing}'): a fresh worker brief names the directory its worker starts in, which decides whether it searches the notes and the graph"
    is_adapter=0; none_named=0
    rc=0; classify adapter "$cwd" || rc=$?
    [ "$rc" -eq 0 ] && is_adapter=1
    grep -Eiq '^> \*\*Writes:\*\*.*none named' "$doc" && none_named=1
    has_directive=1
    if [ "$is_salus" -eq 1 ]; then
        [[ "$flat" == *"no notes search"* ]] || fail "resume_cwd '$cwd' is salus-marked: this brief must search nothing, because a query would send text off this machine. Say 'no notes search and no graph lookup' in the '> **Prior art:**' field and report 'graph-qmd: n/a, salus-marked repo' in Results"
    else
        [[ "$flat" == *"no notes search"* ]] && fail "'> **Prior art:**' says 'no notes search' but resume_cwd is not a salus-marked directory: a brief searches the notes unless the repo is salus-marked"
        for token in qmd-bounded.sh 'graph-qmd:' '-c luna'; do
            case "$flat" in *"$token"*) ;; *) has_directive=0 ;; esac
        done
        jira_ok=0; graph_ok=0
        { [ "$is_adapter" -eq 1 ] && [[ "$flat" == *"no Jira mirror"* ]]; } && jira_ok=1
        { { [ "$is_adapter" -eq 1 ] || [ "$none_named" -eq 1 ]; } && [[ "$flat" == *"no graph lookup"* ]]; } && graph_ok=1
        case "$flat" in *"-c jira-himmel"*) ;; *) [ "$jira_ok" -eq 1 ] || has_directive=0 ;; esac
        case "$flat" in *worker-graph.sh*) ;; *) [ "$graph_ok" -eq 1 ] || has_directive=0 ;; esac
        if [ "$has_directive" -eq 0 ]; then
            fail "'> **Prior art:**' lacks the search directive (a ticket key or #PR does not replace it): add it as a continuation line naming the query and symbol: run 'bash <primary checkout>/scripts/lib/qmd-bounded.sh query -c jira-himmel \"<topic>\"' and the same with '-c luna', and 'bash scripts/graphify/worker-graph.sh explain \"<symbol>\"' before designing, and report 'graph-qmd: <what each returned and whether used>' (or 'graph-qmd: n/a, shipping' on a resume that only ships) in Results; a salus-marked repo says 'no notes search and no graph lookup' instead, an adopted repo 'no Jira mirror' and 'no graph lookup', and the words count only where true; see docs/handover/worker-brief-template.md"
        fi
        # No angle-bracket placeholder anywhere in the directive (the graph-qmd bullet's own <what ...> excepted), and no
        # shell expansion character inside a quoted argument.
        chk="$(sed -E 's/graph-qmd: <[^>]*>//g' <<< "$flat")"
        case "$chk" in *"Before you design"*) chk="${chk#*Before you design}" ;; esac
        if [[ "$chk" =~ \<[^\>]*\> ]]; then
            fail "'> **Prior art:**' directive still carries an angle-bracket placeholder (${BASH_REMATCH[0]}): name the query and the graph symbol this worker should search, and write the primary checkout path out"
        fi
        # shellcheck disable=SC2016
        if grep -Eo -- '(-c (luna|jira-himmel)|explain) "[^"]*"' <<< "$flat" | grep -Eq '[`$\\!]'; then
            fail "'> **Prior art:**' directive has a quoted query or symbol with a shell expansion character (backtick, dollar sign, backslash or exclamation mark): use plain words and paths"
        fi
        # Each command that stands carries a quoted argument that names something: not empty, not blank.
        arg='"[^"[:space:]][^"]*"'
        bad_arg=0
        grep -Eq -- "-c luna $arg" <<< "$flat" || bad_arg=1
        case "$flat" in *"-c jira-himmel"*) grep -Eq -- "-c jira-himmel $arg" <<< "$flat" || bad_arg=1 ;; esac
        case "$flat" in *worker-graph.sh*) grep -Eq -- "worker-graph\.sh explain $arg" <<< "$flat" || bad_arg=1 ;; esac
        [ "$bad_arg" -eq 0 ] || fail "'> **Prior art:**' directive has an empty or blank quoted query or symbol: name the query and the graph symbol this worker should search"
    fi
fi

guard_lib_rule
mirror_heal
core_rule
bucket_rule
exit 0
