#!/usr/bin/env python3
"""Python twin of scripts/lib/status-marker.sh.

Same rows, same answers: both are pinned to fixtures/status-marker-rows.tsv by
test-status_marker.py and test-status-marker.sh.

  parse(line)      the marker a results bullet leads with, in its canonical
                   spelling (PARKED-BANK is returned as PARKED-USAGE), or None
  is_parked(word)  True for PARKED-BANK and PARKED-USAGE

CLI: python3 status_marker.py parse LINE -> marker on stdout, exit 0, or exit 1
when there is none; is-parked WORD -> exit 0 or 1; bad usage exits 2.
"""
import errno
import os
import re
import sys

_MARKER = re.compile(
    r"- (?:[0-9]{1,2}:[0-9]{2}[ \t\n\v\f\r]+)?(?:\*\*)?"
    r"(WRAPPED|READY|RESOLVED|BLOCKED|HALTED|FINDING|LIVE|PARKED-BANK|PARKED-USAGE|RESUMED)"
    r"(?:[^A-Za-z0-9_].*)?",
    re.DOTALL,
)


def parse(line):
    m = _MARKER.fullmatch(line)
    if not m:
        return None
    return "PARKED-USAGE" if m.group(1) == "PARKED-BANK" else m.group(1)


def is_parked(word):
    return word in ("PARKED-BANK", "PARKED-USAGE")


_FENCE = re.compile(r" {0,3}(`{3,}|~{3,})(.*)", re.DOTALL)
_RESULTS = re.compile(r"## Results(?:[ \t]|\Z)")
_RULINGS = re.compile(r"## (?:Chief|Console) Rulings(?:[ \t]|\Z)")  # old-term-ok
_ACTIONABLE = re.compile(
    r"- (?:[0-9]{1,2}:[0-9]{2}[ \t\n\v\f\r]+)?(?:\*\*)?"
    r"(READY|BLOCKED|FINDING|MERGED)"
    r"(?:[^A-Za-z0-9_].*)?",
    re.DOTALL,
)


def _scope_lines(path):
    if not os.path.isfile(path):
        raise OSError(errno.EINVAL, "not a regular file", path)
    with open(path, "rb") as f:
        text = f.read().decode("latin-1")
    out, scope, seen, fence = [], False, False, ""
    for raw in text.split("\n"):
        m = _FENCE.match(raw)
        if m:
            if not fence:
                fence = m.group(1)
            elif (m.group(1)[0] == fence[0] and len(m.group(1)) >= len(fence)
                  and m.group(2).strip(" \t\r") == ""):
                fence = ""
            continue
        if fence:
            continue
        head = raw[:-1] if raw.endswith("\r") else raw
        if head.startswith("## "):
            is_results = _RESULTS.match(head) is not None
            scope = is_results or (seen and _RULINGS.match(head) is not None)
            seen = seen or is_results
            continue
        if scope:
            out.append(raw)
    return out


def newest(path):
    last = None
    for line in _scope_lines(path):
        if line.startswith("- "):
            marker = parse(line)
            if marker is not None:
                last = marker
    return last


def actionable(path):
    word, count = None, 0
    for line in _scope_lines(path):
        m = _ACTIONABLE.fullmatch(line)
        if m:
            word, count = m.group(1), count + 1
    return None if word is None else f"{word}#{count}"


def main(argv):
    if len(argv) != 2 or argv[0] not in ("parse", "is-parked"):
        sys.stderr.write("usage: status_marker.py parse LINE | is-parked WORD\n")
        return 2
    if argv[0] == "is-parked":
        return 0 if is_parked(argv[1]) else 1
    marker = parse(argv[1])
    if marker is None:
        return 1
    sys.stdout.flush()
    sys.stdout.buffer.write(f"{marker}\n".encode("ascii"))
    sys.stdout.buffer.flush()
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
