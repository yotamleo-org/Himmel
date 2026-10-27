#!/usr/bin/env python3
"""scripts/lib/flags.py — the Python reader of scripts/lib/flags.tsv.

    from flags import himmel_flag      # himmel_flag("chain_soft_edges") -> bool
    python3 -I scripts/lib/flags.py chain_soft_edges    # exit 0 on, 1 off, 2 unknown or invalid

Same rules as flags.sh: HIMMEL_FLAG_<NAME> in the environment, then himmel.conf.local, then
himmel.conf under HIMMEL_CONFIG_DIR (default ~/.himmel), then the registry default; never .env.
HIMMEL_FLAGS_TSV points at another registry. An unknown name raises FlagError.
"""
import os
import re
import sys


class FlagError(Exception):
    pass


def _conf_value(key):
    d = os.environ.get('HIMMEL_CONFIG_DIR') or os.path.join(os.path.expanduser('~'), '.himmel')
    for fn in ('himmel.conf.local', 'himmel.conf'):
        try:
            lines = open(os.path.join(d, fn), encoding='utf-8', errors='replace').read().splitlines()
        except OSError:
            continue  # swallow-ok: a missing layer falls through to the next one
        for line in lines:
            line = line.rstrip('\r')
            if not line.strip() or line.lstrip().startswith('#') or '=' not in line:
                continue
            k, v = line.split('=', 1)
            if k.strip() != key:
                continue
            v = v.strip()
            if v[:1] in ('"', "'") and v.find(v[0], 1) > 0:
                v = v[1:v.find(v[0], 1)]
            else:
                v = re.split(r'\s#', v, 1)[0].strip()
            if v:
                return v
    return ''


def himmel_flag(name):
    if not re.fullmatch(r'[a-z][a-z0-9_]*', name or ''):
        raise FlagError("'%s' is not a flag name (lower_snake_case)" % name)
    reg = os.environ.get('HIMMEL_FLAGS_TSV') or os.path.join(os.path.dirname(os.path.abspath(__file__)), 'flags.tsv')
    try:
        rows = open(reg, encoding='utf-8').read().splitlines()
    except OSError as e:
        raise FlagError('cannot read the registry %s (%s)' % (reg, e))
    default = None
    for line in rows:
        if line and not line.startswith('#'):
            cols = line.split('\t')
            if cols[0] == name:
                default = cols[1] if len(cols) > 1 else ''
                break
    if default is None:
        raise FlagError("unknown flag '%s' (not registered in %s)" % (name, reg))
    key = 'HIMMEL_FLAG_' + name.upper()
    val = os.environ.get(key) or _conf_value(key) or default
    if val in ('1', 'on', 'true'):
        return True
    if val in ('0', 'off', 'false'):
        return False
    raise FlagError("%s has the value '%s' (want 1, 0, on or off)" % (name, val))


if __name__ == '__main__':
    try:
        sys.exit(0 if himmel_flag(sys.argv[1] if len(sys.argv) > 1 else '') else 1)
    except FlagError as e:
        print('himmel_flag: %s' % e, file=sys.stderr)
        sys.exit(2)
