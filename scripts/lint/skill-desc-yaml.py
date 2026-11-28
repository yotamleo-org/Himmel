#!/usr/bin/env python3
"""skill-desc-yaml.py — does each description read whole when parsed as YAML?

Called by scripts/lint/skill-lint.sh as `python3 -I skill-desc-yaml.py PATH...`.
For each PATH it takes the frontmatter's `description:` line plus the lines
after it that are indented or blank, parses that block alone as a one-key
YAML document, and reports a description that:

  - does not parse                      -> [desc-yaml-error]
  - parses as a non-string or empty     -> [desc-yaml-error]
  - is a plain scalar read shorter than
    it is written (` #` starts a comment) -> [desc-truncated]

Output: one finding per line, `<argv index>\\t<tag>\\t<message>` (the index, not
the path, names the file: a path may hold a TAB). Messages hold no TAB or
newline. Exit 0 (with or without findings), 3 when `import yaml` fails, 2 on a
usage error. Any other failure is an uncaught exception, so a non-zero exit.
"""
import sys

try:
    import yaml
except ImportError:
    sys.stderr.write("skill-desc-yaml: cannot import yaml\n")
    sys.exit(3)


def description_block(lines):
    if not lines or lines[0].rstrip() != "---":
        return None
    for i in range(1, len(lines)):
        if lines[i].rstrip() == "---":
            end = i
            break
    else:
        return None
    for i in range(1, end):
        if lines[i].startswith("description:"):
            block = [lines[i]]
            for line in lines[i + 1:end]:
                if line.strip() == "" or line[0] in " \t":
                    block.append(line)
                else:
                    break
            return lines[i][len("description:"):].strip(), block[1:], "\n".join(block) + "\n"
    return None


def one_line(text):
    return " ".join(str(text).split())


def check(path):
    with open(path, encoding="utf-8", errors="replace") as fh:
        lines = fh.read().splitlines()
    found = description_block(lines)
    if found is None:
        return []
    key_value, continuation, block = found
    try:
        doc = yaml.safe_load(block)
    except yaml.YAMLError as exc:
        first = str(exc).strip().splitlines()[0] if str(exc).strip() else type(exc).__name__
        return [("[desc-yaml-error]",
                 "description does not parse as YAML (%s) — quote it" % one_line(first))]
    value = doc.get("description") if isinstance(doc, dict) else None
    if value is None or value == "":
        return [("[desc-yaml-error]", "description parses as empty, not text — quote it")]
    if not isinstance(value, str):
        return [("[desc-yaml-error]",
                 "description parses as %s, not text — quote it" % type(value).__name__)]
    if key_value[:1] in ('"', "'", "|", ">"):
        return []
    parts = [key_value] + [c.strip() for c in continuation if not c.lstrip().startswith("#")]
    written = " ".join(" ".join(parts).split())
    read = " ".join(value.split())
    if len(read) < len(written):
        return [("[desc-truncated]",
                 "description reads %d chars as YAML but %d are written — quote it"
                 % (len(read), len(written)))]
    return []


def main(argv):
    if len(argv) < 2 or argv[1] in ("-h", "--help"):
        sys.stderr.write("usage: skill-desc-yaml.py PATH...\n")
        return 2
    for index, path in enumerate(argv[1:]):
        for tag, message in check(path):
            sys.stdout.write("%d\t%s\t%s\n" % (index, tag, one_line(message)))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
