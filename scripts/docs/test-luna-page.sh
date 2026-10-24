#!/usr/bin/env bash
# Suite for the luna "Second brain" page, docs/luna/README.md.
#
# The page teaches commands a user types. A renamed skill flag or qmd verb
# would ship a page that teaches a command nothing runs, so every command on
# the user part of the page (above "## For maintainers") is read back from its
# source: the named skill's frontmatter, or `qmd --help`.
#
#   1. HEADINGS — the page has a "## For maintainers" H2, the first H2 comes
#                 before it, and the path-titled heading and the file-placement
#                 table sit below it.
#   2. SKILLS   — every slash command names a skill with a SKILL.md, and every
#                 --flag beside it is in that skill's frontmatter (its SKILL.md
#                 or its .claude/commands/<name>.md wrapper).
#   3. QMD      — every `qmd <verb>` and each of its flags is in `qmd --help`
#                 (SKIP, not pass, when qmd is not installed).
#   4. OTHER    — no other command appears in a code block of the user part.
#   5. IMAGE    — the star map is embedded with alt text, the SVG has a title
#                 and a description, a text caption follows it, and neither
#                 the page nor the SVG names a home or vault path.
#   6. CONTROL  — fixture pages with a made-up skill flag, an unchecked
#                 command and a vault path fail cases 2, 4 and 5, so none of
#                 them can pass vacuously; a made-up qmd flag fails case 3
#                 when qmd is installed.
#
# Platform guard (gitbash-only): POSIX bash 3.2+ plus python3, so it runs
# unchanged under Git Bash on Windows. No .ps1 twin needed.
#
# Usage: bash scripts/docs/test-luna-page.sh [page.md]
# Exit:  0 = every case passed, 1 = at least one failed (all are reported).
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
PAGE="${1:-$ROOT/docs/luna/README.md}"

pass=0
fail=0
skip=0
ok() { pass=$((pass + 1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf 'FAIL %s\n' "$1"; [ -n "${2:-}" ] && printf '       %s\n' "$2"; }
skp() { skip=$((skip + 1)); printf 'SKIP %s\n' "$1"; }

command -v python3 >/dev/null 2>&1 || { echo "FAIL: python3 required" >&2; exit 1; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/luna-page.XXXXXX")" || exit 1
trap 'rm -rf "$TMP"' EXIT

QMD_HELP="$TMP/qmd-help.txt"
: >"$QMD_HELP"
if command -v qmd >/dev/null 2>&1; then
  qmd --help >"$QMD_HELP" 2>&1 || { echo "FAIL: qmd is installed but qmd --help failed" >&2; exit 1; }
  [ -s "$QMD_HELP" ] || { echo "FAIL: qmd is installed but qmd --help printed nothing" >&2; exit 1; }
fi

# check <case> <page>: prints one violation per line; empty output = clean.
check() {
  python3 -I - "$1" "$2" "$ROOT" "$QMD_HELP" <<'PY'
import os, re, sys

case, page, root, qmd_help_path = sys.argv[1:5]
text = open(page, encoding="utf-8").read()
lines = text.split("\n")
qmd_help = open(qmd_help_path, encoding="utf-8").read()

def frontmatter(path):
    if not os.path.isfile(path):
        return None
    body = open(path, encoding="utf-8").read()
    m = re.match(r"---\n(.*?)\n---\n", body, re.S)
    return m.group(1) if m else ""

h2 = [(i, l[3:].strip()) for i, l in enumerate(lines) if l.startswith("## ")]
maint = next((i for i, t in h2 if t == "For maintainers"), None)
user = lines[:maint] if maint is not None else lines

def commands():
    """(kind, text) for every command a user is shown above the maintainers part."""
    out, fence, last = [], False, None
    for l in user:
        if l.lstrip().startswith("```"):
            fence = not fence
            continue
        if fence:
            s = l.split(" #", 1)[0].strip()
            if s:
                out.append(("block", s))
        else:
            if not l.strip() or re.match(r"\s*(\d+\.|[-*])\s", l):
                last = None
            for span in re.findall(r"`([^`]+)`", l):
                if re.match(r"(/[a-z][\w-]*|qmd)(\s|$)", span):
                    out.append(("span", span))
                    last = span.split()[0]
                elif re.match(r"--?[A-Za-z][\w-]*$", span):
                    # A lone flag belongs to the last command of its paragraph.
                    out.append(("span", f"{last} {span}" if last else span))
    return out

def flags(cmd):
    return re.findall(r"(?<!\S)(--?[A-Za-z][\w-]*)", cmd)

bad = []
if case == "headings":
    if maint is None:
        bad.append('no "## For maintainers" heading')
    else:
        if h2[0][0] == maint:
            bad.append("the first H2 is the maintainers heading, not a user task")
        found = {"path heading": False, "placement table": False}
        for i, l in enumerate(lines):
            if (l.startswith("#") and "himmel/docs/luna/" in l) or l.startswith("| Artifact |"):
                found["placement table" if l.startswith("|") else "path heading"] = True
                if i < maint:
                    bad.append(f"line {i + 1} belongs under For maintainers: {l.strip()}")
        bad += [f"the {k} is missing" for k, v in found.items() if not v]
elif case == "skills":
    for _, c in commands():
        m = re.match(r"/([a-z][\w-]*)", c)
        if not m:
            continue
        name = m.group(1)
        skills = [os.path.join(root, p) for p in (
            f".agents/skills/{name}/SKILL.md",
            f"marketplace/plugins/obsidian-triage/skills/{name}/SKILL.md")]
        fms = [f for f in (frontmatter(p) for p in skills) if f is not None]
        if not fms:
            bad.append(f"/{name}: no SKILL.md names this skill")
            continue
        wrapper = frontmatter(os.path.join(root, f".claude/commands/{name}.md"))
        fm = "\n".join(fms + [wrapper or ""])
        for f in flags(c):
            if not re.search(r"(?<![\w-])" + re.escape(f) + r"(?![\w-])", fm):
                bad.append(f"/{name} {f}: flag not in the skill's frontmatter")
elif case == "qmd":
    for _, c in commands():
        if not re.match(r"qmd(\s|$)", c):
            continue
        verb = c.split()[1] if len(c.split()) > 1 else ""
        if not re.search(r"^\s+qmd " + re.escape(verb) + r"\b", qmd_help, re.M):
            bad.append(f"qmd {verb}: verb not in qmd --help")
        for f in flags(c):
            if not re.search(r"(?<![\w-])" + re.escape(f) + r"(?![\w-])", qmd_help):
                bad.append(f"qmd {verb} {f}: flag not in qmd --help")
elif case == "other":
    for kind, c in commands():
        if kind == "block" and not re.match(r"(/[a-z][\w-]*|qmd)(\s|$)", c):
            bad.append(f"unchecked command in a code block: {c}")
elif case == "image":
    m = re.search(r'<img src="([^"]+\.svg)" alt="([^"]*)"', text)
    if not m:
        bad.append("no <img> of an .svg star map")
    else:
        if not m.group(2).strip():
            bad.append("the star map has no alt text")
        # The site serves site/public/luna/ beside the built page.
        svg_paths = [p for p in (os.path.join(os.path.dirname(page), m.group(1)),
                                 os.path.join(root, "site/public/luna", m.group(1))) if os.path.isfile(p)]
        svg = open(svg_paths[0], encoding="utf-8").read() if svg_paths else ""
        if not svg:
            bad.append(f"{m.group(1)} is missing")
        elif not (re.search(r"<title[^>]*>[^<]+</title>", svg) and re.search(r"<desc[^>]*>[^<]+</desc>", svg)):
            bad.append(f"{m.group(1)} has no <title> and <desc>")
        after = text[m.end():].split("\n", 1)[1] if "\n" in text[m.end():] else ""
        caption = after.strip().split("\n\n", 1)[0]
        if len(caption) < 80 or caption.startswith("#"):
            bad.append("no text caption follows the star map")
        for where, body in (("page", text), (m.group(1), svg)):
            for pat in (r"/home/", r"/Users/", r"~/Documents/luna", r"Documents/luna", r"\$HOME"):
                if re.search(pat, body):
                    bad.append(f"{where} names a home or vault path ({pat})")
print("\n".join(bad))
PY
}

run_case() { # run_case <label> <case> <page>
  local out
  if ! out="$(check "$2" "$3")"; then bad "$1" "the checker itself failed"; return; fi
  if [ -z "$out" ]; then ok "$1"; else bad "$1" "$out"; fi
}

[ -f "$PAGE" ] || { echo "FAIL: page not found: $PAGE" >&2; exit 1; }

run_case "HEADINGS: the first H2 is a user task; maintainer notes sit under For maintainers" headings "$PAGE"
run_case "SKILLS: every slash command and flag is in the named skill's frontmatter" skills "$PAGE"
if [ -s "$QMD_HELP" ]; then
  run_case "QMD: every qmd verb and flag is in qmd --help" qmd "$PAGE"
else
  skp "QMD: qmd is not installed, so the qmd commands were not checked"
fi
run_case "OTHER: no unchecked command in a code block" other "$PAGE"
run_case "IMAGE: star map with alt text, title, description and caption; no vault path" image "$PAGE"

# --- controls: each fixture carries one defect its case must catch
cp "$PAGE" "$TMP/README.md"
control() { # control <label> <case> <line to append above For maintainers>
  local out
  rm -f "$TMP/control-page.md"
  if ! python3 -I -c 'import sys; t=open(sys.argv[1]).read(); open(sys.argv[2],"w").write(t.replace("\n## For maintainers", "\n" + sys.argv[3] + "\n\n## For maintainers", 1))' \
    "$TMP/README.md" "$TMP/control-page.md" "$3"; then
    bad "$1" "could not write the fixture page"; return
  fi
  if ! out="$(check "$2" "$TMP/control-page.md")"; then bad "$1" "the checker itself failed"; return; fi
  if [ -n "$out" ]; then ok "$1"; else bad "$1" "the defect was not caught"; fi
}
python3 -I -c 'import sys; t=open(sys.argv[1]).read(); open(sys.argv[2],"w").write(t.replace("| Artifact |", "| Thing |"))' \
  "$TMP/README.md" "$TMP/no-table.md" || { echo "FAIL: could not write the no-table fixture" >&2; exit 1; }
label="CONTROL: a missing placement table fails HEADINGS"
if ! out="$(check headings "$TMP/no-table.md")"; then bad "$label" "the checker itself failed"
elif [ -n "$out" ]; then ok "$label"; else bad "$label" "the defect was not caught"; fi
control "CONTROL: a made-up /luna-ingest flag fails SKILLS" skills "Run \`/luna-ingest <url> --no-such-flag\`."
control "CONTROL: a lone made-up flag after /luna-ingest fails SKILLS" skills "Run \`/luna-ingest <url>\`; add \`--no-such-flag\` to see more."
control "CONTROL: a made-up skill fails SKILLS" skills "Run \`/luna-no-such-skill\`."
control "CONTROL: an unchecked command fails OTHER" other $'```bash\nrm -rf notes\n```'
control "CONTROL: a vault path fails IMAGE" image 'Your notes live in ~/Documents/luna.'
if [ -s "$QMD_HELP" ]; then
  control "CONTROL: a made-up qmd flag fails QMD" qmd "Run \`qmd query 'x' --no-such-flag\`."
fi

printf '\n%d passed, %d failed, %d skipped\n' "$pass" "$fail" "$skip"
[ "$fail" -eq 0 ]
