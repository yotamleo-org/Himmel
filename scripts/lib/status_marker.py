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
import re
import sys

_MARKER = re.compile(
    r"- (?:[0-9]{1,2}:[0-9]{2}[ \t\n\v\f\r]+)?(?:\*\*)?"
    r"(WRAPPED|READY|RESOLVED|BLOCKED|HALTED|FINDING|LIVE|PARKED-BANK|PARKED-USAGE|RESUMED)"
    r"(?:[^A-Za-z0-9_].*)?"
)


def parse(line):
    m = _MARKER.fullmatch(line)
    if not m:
        return None
    return "PARKED-USAGE" if m.group(1) == "PARKED-BANK" else m.group(1)


def is_parked(word):
    return word in ("PARKED-BANK", "PARKED-USAGE")


def main(argv):
    if len(argv) != 2 or argv[0] not in ("parse", "is-parked"):
        sys.stderr.write("usage: status_marker.py parse LINE | is-parked WORD\n")
        return 2
    if argv[0] == "is-parked":
        return 0 if is_parked(argv[1]) else 1
    marker = parse(argv[1])
    if marker is None:
        return 1
    print(marker)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
