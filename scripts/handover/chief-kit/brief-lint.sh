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
exit 0
