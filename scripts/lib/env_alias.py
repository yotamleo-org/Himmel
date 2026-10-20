#!/usr/bin/env python3
"""Python twin of the direction-aware half of scripts/lib/env-alias.sh.

Same rows, same answers: both are pinned to fixtures/env-alias-rows.tsv by
test-env_alias.py and test-env-alias.sh.

  env_alias_restrict(NEW, OLD, env)  True when either name is truthy (markers
                                     that switch a guard ON)
  env_alias_permit(NEW, OLD, env)    True only when at least one name is truthy
                                     and no set name is falsy (*_OK overrides,
                                     widening switches)

"Set" is non-empty; "truthy" is set and not 0, false, no or off (any case). A
name outside [A-Z_][A-Z0-9_]* raises InvalidName, the shell's rc 2. env
defaults to os.environ.

CLI: python3 env_alias.py restrict|permit NEW OLD -> exit 0 true, 1 false,
2 invalid name or usage (message on stderr).
"""
import os
import re
import sys

_NAME = re.compile(r"[A-Z_][A-Z0-9_]*")
_FALSY = ("0", "false", "no", "off")


class InvalidName(ValueError):
    pass


def _set_values(new, old, env):
    for n in (new, old):
        if not isinstance(n, str) or not _NAME.fullmatch(n):
            raise InvalidName(f"env_alias: invalid name {n!r}")
    env = os.environ if env is None else env
    return [v for v in (env.get(new), env.get(old)) if v]


def _falsy(v):
    return v.lower() in _FALSY


def env_alias_restrict(new, old, env=None):
    return any(not _falsy(v) for v in _set_values(new, old, env))


def env_alias_permit(new, old, env=None):
    values = _set_values(new, old, env)
    return bool(values) and not any(_falsy(v) for v in values)


def main(argv):
    fns = {"restrict": env_alias_restrict, "permit": env_alias_permit}
    if len(argv) != 3 or argv[0] not in fns:
        sys.stderr.write("usage: env_alias.py restrict|permit NEW OLD\n")
        return 2
    try:
        return 0 if fns[argv[0]](argv[1], argv[2]) else 1
    except InvalidName as e:
        sys.stderr.write(f"{e}\n")
        return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
