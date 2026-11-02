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
#
# The field is the `> **Prior art:**` line plus any directly following `> `
# continuation lines (up to the next `> **Field:**`, a non-blockquote line, or
# an empty or whitespace-only `>` line).
#
# The core rule (last section) runs on every brief that names a ticket key in its
# title; --core-only runs it alone, for a launch that skips the prior-art check.
# --judge skips it: a judge brief writes nothing, so no spec stands behind it.
#
# Exit 0 pass, 1 fail (reason on stderr), 2 usage, 3 core-gate refusal.
set -u

core_only=0
judge=0
while [ "${1:-}" = "--core-only" ] || [ "${1:-}" = "--judge" ]; do
    if [ "$1" = "--core-only" ]; then core_only=1; else judge=1; fi
    shift
done
if [ "$#" -ne 1 ]; then
    echo "usage: brief-lint.sh [--core-only] [--judge] <brief>" >&2
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
core_rule() {
    local cli common core_err core_rc=0
    [ "$judge" -eq 0 ] || return 0
    cli="${BRIEF_LINT_JIRA_CLI:-}"
    if [ -z "$cli" ]; then
        # shellcheck source=../../lib/git-clean.sh
        . "$(dirname "$0")/../../lib/git-clean.sh"
        common="$(git_clean -C "$(dirname "$0")" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || common=""  # swallow-ok: no repository means the python stage below reports the CLI as absent, which refuses
        if [ -z "$common" ]; then common="$(dirname "$0")/../../../.git"; fi
        cli="$(dirname "$common")/scripts/jira/dist/index.js"
    fi
    core_err="$(python3 -I - "$doc" "$cli" <<'PY'
import json, os, re, subprocess, sys
from datetime import datetime

doc, cli = sys.argv[1], sys.argv[2]
lines = open(doc, encoding='utf-8', errors='replace').read().splitlines()
title = next((l for l in lines if l.startswith('# ')), '')
keys = list(dict.fromkeys(re.findall(r'\b[A-Z][A-Z0-9]*-[0-9]+\b', title)))
if not keys:
    sys.exit(0)
ROOT_FILES = {'CLAUDE.md', 'AGENTS.md', 'README.md', 'package.json', 'package-lock.json', 'bun.lock', 'uv.lock', 'pyproject.toml', '.gitignore', '.pre-commit-config.yaml'}
paths = []
for i, line in enumerate(lines):
    if line.startswith('> **Writes:**'):
        text = line[len('> **Writes:**'):]
        for nxt in lines[i + 1:]:
            if not nxt.startswith('> ') or nxt.startswith('> **'):
                break
            text += ' ' + nxt[2:]
        for p in re.split(r'[\s,`]+', text.strip()):
            # a token that is not a path (prose, a version, a dot segment) names nothing: a path has a slash or is a named root file
            if p and re.fullmatch(r'[\w.+@/-]+', p) and ('/' in p or p in ROOT_FILES) \
                    and not any(part in ('.', '..') for part in p.split('/')) and p not in paths:
                paths.append(p)

# The ticket's own file mentions, read the way next-dispatchable.sh reads them: the paths a brief with no usable Writes line classifies by.
FILE_RE = re.compile(r"(?<![\w./-])((?:scripts|docs|marketplace|plugins|templates|tools|\.claude|\.github|\.codex)/[\w.+@-]+(?:/[\w.+@-]+)*/?|CLAUDE\.md|AGENTS\.md|README\.md|package\.json|package-lock\.json|bun\.lock|uv\.lock|pyproject\.toml|\.gitignore|\.pre-commit-config\.yaml)")

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
        # cwd inside the CLI's own checkout: it runs `git rev-parse` from its cwd
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
    groups.setdefault((mirror, tuple(paths or ticket_paths(mirror, k))), []).append(k)
verdict, spec = {}, {}
for (mirror, kpaths), ks in groups.items():
    docs_only = bool(kpaths) and all(p.startswith('docs/') or p.endswith('.md') for p in kpaths)
    r = run(['release', 'core-check', '--paths', ','.join(kpaths)] + (['--docs-only'] if docs_only else []) + ['--mirror', mirror, '--key'] + ks)
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
            print('brief-lint: WARN core-gate.jsonl not written (%s)' % e, file=sys.stderr)  # the bypass still stands: it came from core-check
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

if [ "$core_only" -eq 1 ]; then
    core_rule
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
# shellcheck source=../../lib/worker-identity.sh
. "$(dirname "$0")/../../lib/worker-identity.sh"
if [ -z "$(worker_description_field "$doc")" ] && ! worker_doc_has_run "$doc"; then
    fail "no front-matter 'description:' line (required: one plain-language line saying what this worker is doing and why, e.g. 'description: Add a description line to every worker brief'; put it between the leading '---' lines, the first of which must be the file's first line with no blank line or BOM before it; see docs/handover/worker-brief-template.md)"
fi

core_rule
exit 0
