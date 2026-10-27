#!/usr/bin/env python3
"""Hold a docs-reviewer answer to its 3,072-byte contract, by measurement.

usage: fit_answer.py <answer-file>

Prints the answer, cut to fit, on stdout and one `fit:` line on stderr. The cut
follows the contract's order: appendix lines from the bottom, then the
appendix block, then SHOULD lines of `## Must fix` from the bottom. A page
verdict or a BLOCKING line is never cut. Exit 0 when the result fits; 1 when it
is still over with only page verdicts and BLOCKING must-fix lines left, so the
caller sends it back once with "cut to 3 KB"; 2 on usage.
"""
import sys

LIMIT = 3072


def size(lines):
    return len("".join(lines).encode("utf-8"))


def appendix_span(lines):
    start = next((i for i, l in enumerate(lines) if l.lstrip().startswith("<details>")), None)
    if start is None:
        return None
    end = next((i for i in range(start + 1, len(lines)) if lines[i].strip() == "</details>"), len(lines) - 1)
    return start, end


def cut_appendix_line(lines):
    span = appendix_span(lines)
    if span is None:
        return False
    start, end = span
    body = [i for i in range(start + 1, end) if lines[i].strip()]
    if body:
        del lines[body[-1]]
        return True
    while start > 0 and not lines[start - 1].strip():
        start -= 1
    del lines[start:end + 1]
    return True


def cut_should_line(lines):
    try:
        start = next(i for i, l in enumerate(lines) if l.strip() == "## Must fix")
    except StopIteration:
        return False
    end = next((i for i in range(start + 1, len(lines)) if lines[i].startswith("## ")), len(lines))
    should = [i for i in range(start + 1, end) if lines[i].startswith("- [SHOULD]")]
    if not should:
        return False
    del lines[should[-1]]
    return True


def main(argv):
    if len(argv) != 2:
        print(__doc__.strip().splitlines()[2], file=sys.stderr)
        return 2
    with open(argv[1], encoding="utf-8") as f:
        lines = f.read().splitlines(keepends=True)
    before = size(lines)
    cut_a = cut_m = 0
    while size(lines) > LIMIT and cut_appendix_line(lines):
        cut_a += 1
    while size(lines) > LIMIT and cut_should_line(lines):
        cut_m += 1
    sys.stdout.write("".join(lines))
    after = size(lines)
    note = f"fit: {before} B to {after} B (limit {LIMIT}); cut {cut_a} appendix line(s), {cut_m} SHOULD line(s)"
    if after > LIMIT:
        print(f"{note}; still over with only BLOCKING left: send it back once with \"cut to 3 KB\"", file=sys.stderr)
        return 1
    print(note, file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
