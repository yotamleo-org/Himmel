#!/usr/bin/env bash
# scripts/handover/chief-kit/brief-lint.sh <brief> - arming-time
# check that a worker or judge brief carries a filled `> **Prior art:**` line.
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
# Exit 0 pass, 1 fail (reason on stderr), 2 usage.
set -u

if [ "$#" -ne 1 ]; then
    echo "usage: brief-lint.sh <brief>" >&2
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

# The core gate: a fresh template-shaped build brief (a `> **Contract:**` line) whose title
# names a ticket key that `release core-check` answers CORE for, given the brief's Writes, must carry a
# `> **Spec:** <KEY> ...` or a `> **Core gate:** <KEY> bypass=...` line, so a hand-written brief cannot skip the
# gate gen-briefs enforces. It reads no flag and asks the built jira CLI only; a doc that has run, a judge brief
# (no Contract line) and a title with no key are not gated. It checks that the line is present, not that the
# record behind it is valid. BRIEF_LINT_JIRA_CLI and BRIEF_LINT_MIRROR are the test seams (as in gen-briefs.py).
# ponytail: brief-lint checks the line is present, not that the record behind it is valid; upgrade = a spec-check call per Spec: line.
if ! worker_doc_has_run "$doc"; then
    cli="${BRIEF_LINT_JIRA_CLI:-}"
    if [ -z "$cli" ]; then
        # shellcheck source=../../lib/git-clean.sh
        . "$(dirname "$0")/../../lib/git-clean.sh"
        common="$(git_clean -C "$(dirname "$0")" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || common=""  # swallow-ok: no repository means the python stage below reports the CLI as absent, which refuses
        cli="$(dirname "${common:-$(dirname "$0")/../../../.git}")/scripts/jira/dist/index.js"
    fi
    core_err="$(python3 -I - "$doc" "$cli" <<'PY'
import os, re, subprocess, sys

doc, cli = sys.argv[1], sys.argv[2]
lines = open(doc, encoding='utf-8', errors='replace').read().splitlines()
if not any(l.startswith('> **Contract:**') for l in lines):
    sys.exit(0)
title = next((l for l in lines if l.startswith('# ')), '')
m = re.match(r'# ([A-Z][A-Z0-9]*-[0-9]+)\b', title)
if not m:
    sys.exit(0)
key = m.group(1)
paths = []
for i, line in enumerate(lines):
    if line.startswith('> **Writes:**'):
        text = line[len('> **Writes:**'):]
        for nxt in lines[i + 1:]:
            if not nxt.startswith('> ') or nxt.startswith('> **'):
                break
            text += ' ' + nxt[2:]
        paths = [p for p in re.split(r'[\s,`]+', text.strip()) if p and p != 'none' and p != 'named']
        break
docs_only = bool(paths) and all(p.startswith('docs/') or p.endswith('.md') for p in paths)
mirror = os.environ.get('BRIEF_LINT_MIRROR') or os.path.expanduser('~/.himmel/state/jira-mirror/' + key.split('-')[0])
primary = os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(cli))))

def failed(why):
    print('CORE-CHECK-FAILED: build the jira CLI (npm --prefix %s/scripts/jira run build) -- %s' % (primary, why))
    sys.exit(1)

if not os.path.isfile(cli):
    failed('no built jira CLI at %s' % cli)
try:
    # cwd inside the CLI's own checkout: it runs `git rev-parse` from its cwd
    r = subprocess.run(['node', cli, 'release', 'core-check', '--paths', ','.join(paths)] + (['--docs-only'] if docs_only else []) +
                       ['--mirror', os.path.abspath(mirror), '--key', key],
                       capture_output=True, text=True, timeout=120, cwd=os.path.dirname(os.path.abspath(cli)))
except (OSError, subprocess.SubprocessError) as e:
    failed('node could not run %s (%s)' % (cli, e))
if r.returncode != 0:
    failed('core-check exited %d: %s' % (r.returncode, (r.stderr or r.stdout).strip()[:200]))
verdict = None
for line in r.stdout.splitlines():
    t = line.split()
    # a line shorter than its verb needs is no answer: a truncated BYPASS must never read as a bypass
    if len(t) >= {'CORE': 3, 'BYPASS': 4}.get(t[0] if t else '', 2) and t[0] in ('CORE', 'NOT-CORE', 'BYPASS', 'UNKNOWN') and t[1] == key:
        verdict = t
        break
if verdict is None:
    failed('core-check printed no parseable line for %s' % key)
if verdict[0] == 'UNKNOWN':
    print('core brief %s is not in the Jira mirror (%s), so neither core nor a bypass can be proven; refresh the mirror, then re-run' % (key, mirror))
    sys.exit(1)
if verdict[0] != 'CORE':
    sys.exit(0)
k = re.escape(key)
if any(re.match(r'> \*\*Spec:\*\* %s\s' % k, l) or re.match(r'> \*\*Core gate:\*\* %s bypass=' % k, l) for l in lines):
    sys.exit(0)
print('core brief %s carries neither a Spec: nor a Core gate: bypass= line (core by %s); gen-briefs writes the line, or run minerva and jira release operator spec' % (key, verdict[2]))
sys.exit(1)
PY
)" || fail "$core_err"
fi
exit 0
