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
# The bucket rule (bucket_rule) runs straight after it at both call sites, so --core-only cannot skip it either: a key
# outside the current version is refused. --judge skips it too; --skip-bucket is the generator's flag, for the lint it
# runs at write time (the door belongs at launch).
#
# Exit 0 pass, 1 fail (reason on stderr), 2 usage, 3 refusal no flag clears: the core gate, the bucket rule, a salus-marked
# brief that names a search, a resume_cwd the classifier cannot answer for, or front matter that does not parse as YAML.
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
# The jira CLI both gates call: the seam, else the built dist/ of the checkout this script lives in.
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
try:
    import holds  # noqa: E402
    tokens = [p for _kind, p in holds.parse_text('\n'.join(lines), os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(cli)))))]
except Exception:  # swallow-ok: a broken holds.py must not fail the core check; it falls back to the raw split of the Writes text
    tokens = [t.rstrip('.,;:)]') for t in re.findall(r'[\w.+@/-]+', text)]
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
        elif t and (t[0] in ('SPEC-STALE', 'NO-SPEC') if spec else t[0] in ('CORE', 'NOT-CORE', 'BYPASS', 'UNKNOWN')) and len(t) >= {'CORE': 3, 'BYPASS': 4}.get(t[0], 2):
            got[t[1]] = line  # a line shorter than its verb needs is no answer: a truncated BYPASS must never read as a bypass
    return {k: got[k] for k in ks if k in got}

groups = {}
for k in keys:
    mirror = os.environ.get('BRIEF_LINT_MIRROR') or os.path.expanduser('~/.himmel/state/jira-mirror/' + k.split('-')[0])
    mirror = os.path.abspath(mirror)
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
    if t[0] == 'UNKNOWN':
        refusals.append('core brief %s is not in the Jira mirror, so neither core nor a bypass can be proven; refresh the mirror, then re-run' % k)
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

# The bucket rule: a launch on a ticket outside the current version is refused. `release bucket-check` answers per key and
# every key the brief names is asked: each key of the title, and the first key of the doc name (the launcher reads the doc
# name the same way). IN passes; NONE (a project with no versions file), APPROVED (an out-of-version record) and a Done key on
# a doc that has run pass and print a `brief-lint: <KEY> bypass=<reason> ...` line, which the launcher re-emits; DONE on a new
# doc, OUTSIDE, FAILED, a CLI that is missing, exits non-zero, times out or prints no line for a key all refuse (exit 3, no flag
# clears it). A failed Jira read refuses by name: this is a coordination gate, so it fails shut. --judge skips it, as it skips
# the core rule, and --skip-bucket is the generator's flag: gen-briefs.py lints every brief of a batch at write time, and the
# door belongs at launch. No key in the title or the doc name passes with no call. It runs straight after core_rule at both
# call sites, so --core-only cannot skip it. BRIEF_LINT_VERDICT_TIMEOUT (whole seconds, default 120) can only refuse sooner.
bucket_rule() {
    local cli ran=0 bucket_err bucket_rc=0
    [ "$judge" -eq 0 ] || return 0
    [ "$skip_bucket" -eq 0 ] || return 0
    cli="$(resolve_cli)"
    worker_doc_has_run "$doc" && ran=1
    bucket_err="$(python3 -I - "$doc" "$cli" "$ran" <<'PY'
import os, re, subprocess, sys

doc, cli, ran = sys.argv[1], sys.argv[2], sys.argv[3] == '1'
lines = open(doc, encoding='utf-8', errors='replace').read().splitlines()
title = next((l for l in lines if l.startswith('# ')), '')
keys = list(dict.fromkeys(re.findall(r'\b[A-Z][A-Z0-9]*-[0-9]+\b', title)))
named = re.search(r'[A-Z][A-Z0-9]*-[0-9]+', os.path.basename(doc))
if named and named.group(0) not in keys:
    keys.append(named.group(0))
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
    mirror = os.environ.get('BRIEF_LINT_MIRROR') or os.path.expanduser('~/.himmel/state/jira-mirror/' + k.split('-')[0])
    groups.setdefault(os.path.abspath(mirror), []).append(k)

VERDICTS = ('IN', 'NONE', 'APPROVED', 'DONE', 'OUTSIDE', 'FAILED')
got = {}
for mirror, ks in groups.items():
    if not os.path.isfile(cli):
        failed('no built jira CLI at %s' % cli)
    try:
        # cwd inside the checkout that holds the CLI, as the core rule runs it
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
            '%s is in %s, current is %s, %s open. Why this ticket and not the bucket? If the operator approved it as out of version: '
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

if [ "$core_only" -eq 1 ]; then
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

core_rule
bucket_rule
exit 0
