"""The files minerva writes beside a spec, named for a design leg's Writes line.

A design brief's Writes names a spec `.md`; minerva also writes the spec's estimate json, its page, its plan and the
critic returns beside it. `siblings` names them, `sibling_set` finds which tokens of a Writes text are such siblings,
and `fold` blanks those tokens so the docs-only test of gen-briefs.py and brief-lint.sh does not read them as build
files. Standard library only; it imports nothing from gen-briefs (a hyphenated script whose module body runs).
The test-gen-briefs.sh row R6 holds ROUNDS at the critic round cap of scripts/telegram/chief-route.ts plus one or more.
"""
import os
import re

ROUNDS = 6

LEAD_KEY_RE = re.compile(r'^([A-Z][A-Z0-9]+-[0-9]+)(?=[-.])')
_TOKEN_RE = re.compile(r'[\w.+@/-]+')
_SPEC_DIRS = ('design', 'designs', 'spec')


def _under_root(p, hroot):
    if not hroot or os.path.normpath(p) != p.rstrip('/'):
        return False
    root = os.path.realpath(hroot)
    try:
        return os.path.commonpath((root, os.path.realpath(p))) == root
    except ValueError:
        return False


def siblings(spec, hroot):
    """The 15 minerva files of an absolute spec `.md` under hroot, in order; [] when spec is not such a spec."""
    if not os.path.isabs(spec) or not spec.endswith('.md') or not _under_root(spec, hroot):
        return []
    d, name = os.path.split(spec)
    specs = os.path.dirname(d)
    if os.path.basename(d) not in _SPEC_DIRS or os.path.basename(specs) != 'specs':
        return []
    if not LEAD_KEY_RE.match(name) or '.critic-' in name:
        return []
    stem = name[:-len('.md')]
    out = [os.path.join(d, stem + '.estimate.json'), os.path.join(d, stem + '.html'), os.path.join(specs, 'plans', name)]
    for n in range(1, ROUNDS + 1):
        out.append(os.path.join(d, '%s.critic-spec-r%d.md' % (name, n)))
        out.append(os.path.join(d, '%s.critic-plan-r%d.md' % (name, n)))
    return out


def _tokens(text):
    return [t.rstrip('.,;:)]') for t in _TOKEN_RE.findall(text)]


def sibling_set(text, hroot):
    """The sibling paths of every spec token in text that themselves pass the under-root realpath test."""
    out = set()
    for tok in _tokens(text):
        for s in siblings(tok, hroot):
            if _under_root(s, hroot):
                out.add(s)
    return out


def fold(scope, hroot):
    """scope with every token that is a sibling of a spec token of scope replaced by a space."""
    drop = sibling_set(scope, hroot)
    if not drop:
        return scope
    return _TOKEN_RE.sub(lambda m: ' ' if m.group(0).rstrip('.,;:)]') in drop else m.group(0), scope)
