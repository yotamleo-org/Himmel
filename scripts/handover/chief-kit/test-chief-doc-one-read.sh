#!/usr/bin/env bash
# shellcheck disable=SC2015
# scripts/handover/chief-kit/test-chief-doc-one-read.sh — a chief doc written
# by `chief.sh next` reads in one Read (under the 25,000-token limit), and no binding
# ruling is dropped on the way.
#
# Two synthetic fixtures reproduce the section sizes and every decision-number shape of two
# live chief docs (one 120 KB, one 174 KB; the live docs are private operator text and are
# never committed or copied): a Live state whose queue line carries many earlier chiefs'
# segments and whose tracker and last GO lines carry history tails, and a Current direction
# of one long line per ruling. `next` runs for real against a temp handover root and a
# throwaway fixture repo (same shape as test-chief-handoff-roundtrip.sh).
#
# RED control: RED_CHIEF_SH=<an older chief.sh> copies that file over the fixture's chief.sh,
# so the size and history rows can be shown failing on the pre-change output.
#
# Size bound: the Read limit counts tokens, and a chief doc has no fixed bytes per token (the
# live TQ doc reads 2.25, a path-heavy successor doc about 1.8). The stated conservative bound
# is 48,000 bytes: a `chief.sh next` successor of the live TQ doc, 48,372 bytes, was read whole
# in one Read with no truncation, so a doc at or under 48,000 bytes reads in one Read too.
#
# Platform guard: POSIX bash 3.2+; same scope as chief.sh.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_REAL="$(cd "$HERE/../../.." && pwd)"
BOUND_BYTES=48000

tmp="$(mktemp -d "${TMPDIR:-/tmp}/chief-one-read.XXXXXX")" || { echo "test-chief-doc-one-read: mktemp -d failed" >&2; exit 1; }
tmp="$(cd "$tmp" && pwd -P)"
trap 'rm -rf "$tmp"' EXIT

export HIMMELCTL_CACHE_DIR="$tmp/himmelctl-cache"
export HANDOVER_REGISTRY="$tmp/no-registry-for-this-suite.json"
export BRIDGE_ROOT="$tmp/bridge"
export HIMMEL_CONFIG_DIR="$tmp/config" HIMMEL_RELEASE_STATE_DIR="$tmp/releases"
export UNGUARDED_LAUNCH_OK=1
unset HIMMEL_BUS_NAME HEADED_ARM_REPO
printf '#!/usr/bin/env bash\necho "bank-preflight: worker=unknown five_hour=9.0 seven_day=91.0 extra_usage=n/a"\necho PROCEED\n' > "$tmp/facts-bank.sh"
printf '#!/usr/bin/env bash\necho "#5 [DEMO-1] stub pr (feat/x)"\n' > "$tmp/facts-prs.sh"
export HANDOFF_FACTS_BANK="$tmp/facts-bank.sh" HANDOFF_FACTS_PRS="$tmp/facts-prs.sh"
printf '[]\n' > "$tmp/orphan-prs-none.json"
export ORPHAN_PR_CHECK_PRS="$tmp/orphan-prs-none.json" TICKET_STATUS_STATE_DIR="$tmp/ticket-status-state"
printf '#!/usr/bin/env bash\necho "== STUB action-zero"\n' > "$tmp/az-stub.sh"
export ACTION_ZERO_SCRIPT="$tmp/az-stub.sh"

fails=0
check() { [ "$2" = "$3" ] && echo "ok - $1" || { echo "FAIL - $1: [$2]!=[$3]"; fails=$((fails+1)); }; }

fixture_repo="$tmp/repo"
mkdir -p "$fixture_repo/scripts" "$fixture_repo/docs" "$tmp/releases"
git init -q "$fixture_repo"
for _e in "$REPO_REAL"/scripts/* "$REPO_REAL"/docs/*; do
    case "$_e" in
        "$REPO_REAL/scripts/handover"|"$REPO_REAL/scripts/lib") cp -R "$_e" "$fixture_repo/scripts/" ;;
        "$REPO_REAL/docs/handover") cp -R "$_e" "$fixture_repo/docs/" ;;
        "$REPO_REAL"/scripts/*) ln -s "$_e" "$fixture_repo/scripts/${_e##*/}" ;;
        *) ln -s "$_e" "$fixture_repo/docs/${_e##*/}" ;;
    esac
done
C="$fixture_repo/scripts/handover/chief/chief.sh"
[ -z "${RED_CHIEF_SH:-}" ] || cp "$RED_CHIEF_SH" "$C"
mkdir -p "$fixture_repo/marketplace/plugins/himmel-bus/bin"
printf '#!/usr/bin/env bash\nexit 0\n' > "$fixture_repo/marketplace/plugins/himmel-bus/bin/bus"
chmod +x "$fixture_repo/marketplace/plugins/himmel-bus/bin/bus"

root="$tmp/handovers"
mkdir -p "$root"
today="$(date +%F)"
datepin="$tmp/datepin"; mkdir -p "$datepin"
printf '#!/bin/sh\nif [ "$*" = "+%%F" ]; then echo %s; else exec %s "$@"; fi\n' "$today" "$(command -v date)" > "$datepin/date"; chmod +x "$datepin/date"
PATH="$datepin:$PATH"; export PATH
chief() { ( cd "$fixture_repo" && HANDOVER_DIR="$root" USER_SLUG=tester JIRA_PROJECT_KEY=DEMO CHIEF_WORK_DIR="$tmp/work" bash "$C" "$@" ); }

# --- the synthetic fixture generator --------------------------------------------------------
# gen.py <doc> <bucket dir> <queue segments> <ruling groups>: rewrites the queue, tracker and
# last GO lines and the Current direction of a doc `chief new` wrote, makes the verbatim files
# the numbered rulings name, and writes <doc>.numbers (every decision number of the direction,
# one per line) and <doc>.pinned (the tracker's pinned sentence, no trailing newline).
cat > "$tmp/gen.py" <<'PY'
import os, sys
doc, bucket, nseg, ngroups = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4])
W = "alpha bravo charlie delta echo foxtrot golf hotel india juliet kilo lima mike november oscar papa quebec romeo sierra tango".split()
def words(seed, n):
    return " ".join(W[(seed * 7 + i * 3) % len(W)] for i in range(n))
LET = [a + b for a in "ABCDEFGHIJ" for b in "ABCDEFGHIJKLMNOPQRSTUVWXYZ"]
os.makedirs(os.path.join(bucket, "specs", "decisions"), exist_ok=True)
queue = " || ".join("(%s) %s %d %s" % (LET[i], "MERGED" if i % 2 else "READY", 4000 + i, words(i, 140)) for i in range(nseg))
pinned = "PINNED (operator decision 286, GA 10-25): file:///fixture/roadmap-tracker.html is THE v1.1.3 board; keep it on this line verbatim through every succession, change it only when the chief bugs are fixed."
tracker = pinned + " — older: none (" + words(3, 120) + "; history follows) — was: DK 10-23 account B CURRENT: " + words(5, 200)
lastgo = "; ".join("`%d:%08x` (ordinary, %s, merged)" % (4500 + i, 0x7d0ca856 + i * 977, words(i, 6)) for i in range(12))
lines, numbers = [], []
n = 740
def verb(num, tag):
    with open(os.path.join(bucket, "specs", "decisions", "verbatim-decision-%d-operator-11-05-%s.txt" % (num, tag)), "w") as f:
        f.write("operator words for %d\n" % num)
for g in range(ngroups):
    tag = LET[g % len(LET)]
    # a numbered ruling with its verbatim file
    verb(n, tag)
    lines.append("OPERATOR 11-05 %s (BINDING, carry to every successor; decision %d, verbatim specs/decisions/verbatim-decision-%d-operator-11-05-%s.txt). Verbatim: \"%s\". Read, unconfirmed: %s." % (tag, n, n, tag, words(g, 8), words(g + 1, 60)))
    numbers.append(n); n -= 1
    if g % 9 == 0:   # a range, brace-expanded file names
        for k in range(n - 4, n + 1): verb(k, tag)
        lines.append("OPERATOR 11-05 %s (BINDING, carry to every successor; decisions %d to %d, verbatim specs/decisions/verbatim-decision-%d-operator-11-05-%s.txt). %s." % (tag, n - 4, n, n - 4, tag, words(g + 2, 70)))
        numbers += list(range(n - 4, n + 1)); n -= 5
    if g % 11 == 0:  # a list
        for k in (n - 2, n - 1, n): verb(k, tag)
        lines.append("OPERATOR 11-05 %s (BINDING, carry to every successor; decisions %d, %d, %d, verbatim specs/decisions/verbatim-decision-%d-operator-11-05-%s.txt). Verbatim: \"%s\". %s." % (tag, n - 2, n - 1, n, n - 2, tag, words(g, 5), words(g + 3, 50)))
        numbers += [n - 2, n - 1, n]; n -= 3
    if g % 13 == 0:  # an older numbered ruling with no verbatim file, a chief-duties line, a line with no number
        lines.append("OPERATOR 10-23 %s (decision %d): %s." % (tag, 100 + g, words(g + 4, 90)))
        numbers.append(100 + g)
        lines.append("CHIEF DUTIES %s (carry to every successor; chief rulings, not operator text): (1) %s. (2) %s." % (tag, words(g, 40), words(g + 5, 40)))
        lines.append("OPERATOR 11-03 %s (BINDING, carry to every successor; verbatim, not numbered): \"%s\" %s." % (tag, words(g, 6), words(g + 6, 30)))
    if g % 7 == 0:   # two decision clauses in one header, with ids that are not decision numbers
        verb(n, tag); verb(n - 1, tag)
        lines.append("OPERATOR 11-03 %s (BINDING, carry to every successor; decision %d, O-v1.1.3-0199, verbatim specs/decisions/verbatim-decision-%d-operator-11-03-%s.txt; decision %d, O-v1.1.3-0198). Verbatim: \"%s\". Read: %s. (1) %s. (2) %s." % (tag, n, n, tag, n - 1, words(g, 5), words(g + 7, 40), words(g + 1, 30), words(g + 2, 30)))
        numbers += [n, n - 1]; n -= 2
    if g % 8 == 0:   # a second clause after a verbatim file name, joined by ", and"
        verb(n, tag); verb(n - 1, tag)
        lines.append("OPERATOR 11-02 %s (BINDING, carry to every successor; decision %d, verbatim specs/decisions/verbatim-decision-%d-operator-11-02-%s.txt, and decision %d, O-v1.1.3-0172). Verbatim: \"%s\". %s." % (tag, n, n, tag, n - 1, words(g, 6), words(g + 3, 60)))
        numbers += [n, n - 1]; n -= 2
    if g % 10 == 0:  # a dash range in a header whose body says STANDING, and a (STANDING) header
        lines.append("OPERATOR 10-25 %s (decisions %d-%d): %s (STANDING). %s." % (tag, n - 2, n, words(g, 6), words(g + 4, 50)))
        numbers += [n - 2, n - 1, n]; n -= 3
        lines.append("OPERATOR 10-27 %s (STANDING): %s. (1) %s. (2) %s." % (tag, words(g + 1, 50), words(g + 2, 30), words(g + 3, 30)))
    if g % 35 == 0:  # decision numbers in the body (the live TU doc's shapes), and lines of another shape
        b = 780 + 13 * (g // 35)
        verb(b, tag); verb(b + 1, tag)
        # a header that names two numbers, then bare "NNN:" items and "NNN, verbatim in specs" in the body
        lines.append("OPERATOR 11-06 %s (BINDING, carry to every successor; decisions %d, %d, verbatim specs/decisions/verbatim-decision-%d-operator-11-06-%s.txt). Verbatim: \"%s\". %d: \"%s\" Done: %s. %d: \"%s\", closed. %d, verbatim in specs/decisions: %s. %d: \"%s\". %s." % (tag, b, b + 1, b, tag, words(g, 5), b + 2, words(g + 1, 6), words(g + 2, 40), b + 3, words(g + 3, 6), b + 4, words(g + 4, 40), b + 5, words(g + 5, 6), words(g + 6, 40)))
        # a header with no number, "decision N" forms in parentheses in the body
        lines.append("OPERATOR 10-30 %s (BINDING, carry to every successor): %s (decision %d, A+B, 19 keys; admitted R-1127..1145), %s (decision %d: 123 audited keys; list in specs). Ticket 8935: approved, posted 11-06 18:17, 9423 ok. %s." % (tag, words(g, 40), b + 6, words(g + 1, 30), b + 7, words(g + 2, 40)))
        # a ruling with lines directly under it (no blank line): the live MM shape, and the capital "Decision N" forms
        lines.append("OPERATOR 11-01 %s (BINDING, carry VERBATIM to every successor; operator: \"%s\"). The chain plan, run in parallel:\n(1) Safety: %s.\nRules that come with it: before every dispatch %s; at every handover, map each open PR to a lane. (4) Decision %d, O-v1.1.3-0144: %s. (5) Decision %d O-v1.1.3-0125: %s.\n(d) Reply to the operator once the dispatch is done, with what runs now; it follows decision %d order." % (tag, words(g, 6), words(g + 1, 40), words(g + 2, 30), b + 8, words(g + 3, 30), b + 9, words(g + 4, 30), b + 10))
        # a time head: "12:46" holds a colon, so the shortened line must still be recognised as shortened on the next succession
        lines.append("OPERATOR 11-06 %s 12:46 (BINDING, carry to every successor; decision %d, Telegram update 240463255, verbatim): (1) %s. (2) %s." % (tag, b + 11, words(g + 5, 30), words(g + 6, 30)))
        numbers += list(range(b, b + 12))
        # lines of another shape: a dash item and an unheaded row, long enough to be cut, with a ticket number and a time that are not decisions
        lines.append("- Owed by hand %s: 6598 soak, runs 40023386609 green at 18:17 and 40028092118 running; at 3 greens re-dispatch from its doc. %s." % (tag, words(g + 7, 90)))
        lines.append("Filed %s: 7296 (PR 3691), 7297 (3689 residual: single-guard RED rows), 7299 (issue 3596). %s." % (tag, words(g + 8, 90)))
direction = "\n\n".join(lines)
out, sec = [], None
for ln in open(doc, encoding="utf-8").read().split("\n"):
    if ln.startswith("## "):
        if sec == "Current direction":
            out.append("")
        sec = ln[3:]
        out.append(ln)
        if sec == "Current direction":
            out.append("")
            out.append(direction)
        continue
    if sec == "Current direction" and not ln.startswith(">"):
        continue
    for key, val in (("queue", queue), ("tracker", tracker), ("last GO", lastgo)):
        if sec == "Live state" and ln.startswith(key + ":"):
            ln = key + ": " + val
    out.append(ln)
open(doc, "w", encoding="utf-8").write("\n".join(out))
open(doc + ".numbers", "w").write("\n".join(str(x) for x in numbers) + "\n")
open(doc + ".pinned", "w", encoding="utf-8").write(pinned)
PY

# --- the dropped-ruling checker ---------------------------------------------------------------
# check.py <successor doc> <bucket dir> <expected lines file> <numbers file>: exit 0 when the
# successor's Current direction names its companion files and the first-turn read, each companion
# is under the Read bound, the companions hold every expected ruling line byte for byte, every
# decision number the expected lines name (taken here by a parse of its own, and also the
# generator's list) is listed in an index line, every shortened index line has a real reading
# taken from its source line, and a STANDING ruling is not labelled "not marked binding".
cat > "$tmp/check.py" <<'PY'
import os, re, sys
doc, bucket, exp, numfile = sys.argv[1:5]
BOUND = 48000
def block(p):
    on, out = False, []
    for ln in open(p, encoding="utf-8").read().split("\n"):
        if ln == "## Current direction": on = True; continue
        if on and ln.startswith("## "): break
        if on and ln.strip() and not ln.startswith(">"): out.append(ln)
    return out
new = block(doc)
raw = open(exp, encoding="utf-8").read().split("\n")
expected = [l for l in raw if l.strip() and not l.startswith(">")]
# the source rulings as units: an OPERATOR or CHIEF line with the lines directly under it (no blank line between)
units, cur = [], None
for l in raw:
    if not l.strip() or l.startswith(">"): cur = None; continue
    if re.match(r"^(?:OPERATOR|CHIEF) ", l): cur = [l]; units.append(cur)
    elif cur is not None and not l.startswith("Full original text"): cur.append(l)
    else: cur = None; units.append([l])
cont_lines = set(l for u in units for l in u[1:])
note =[l for l in new if l.startswith("Full original text")]
if len(note) != 1: print("no single companion pointer line"); sys.exit(1)
m = re.search(r"is in (\d+) files? under the bucket \(([^)]*)\)\. READ ALL OF THEM in your first turn, in the same batch as this document", note[0])
if not m: print("the pointer line lacks the required first-turn read"); sys.exit(1)
files = m.group(2).split()
if len(files) != int(m.group(1)): print("the pointer count differs from the files it names"); sys.exit(1)
held, alltext = set(), ""
for rel in files:
    p = os.path.join(bucket, rel)
    if not os.path.isfile(p): print("companion missing: " + rel); sys.exit(1)
    if os.path.getsize(p) > BOUND: print("companion over the Read bound: " + rel); sys.exit(1)
    txt = open(p, encoding="utf-8").read()
    held.update(txt.split("\n")); alltext += txt + "\n\n"
for ln in expected:
    if ln not in held: print("companion lacks a ruling line: " + ln[:70]); sys.exit(1)
for u in units:
    if len(u) > 1 and "\n".join(u) not in alltext: print("a ruling and the lines directly under it are not adjacent in the companions: " + u[0][:60]); sys.exit(1)
def header_numbers(line):
    mm = re.match(r"^(?:OPERATOR|CHIEF)[^(]*\(([^)]*)\)", line)
    if not mm: return []
    h, out = mm.group(1), []
    for d in re.finditer(r"decisions?\b", h, re.I):
        sp = re.match(r"\s*((?:\d+|,|and|to|-|–|\s)+)", h[d.end():])
        nums, join = [], False
        for t in re.findall(r"\d+|to|-|–", sp.group(1) if sp else ""):
            if t.isdigit():
                v = int(t)
                if join and nums: nums += list(range(nums[-1] + 1, v + 1)); join = False
                else: nums.append(v)
            else: join = True
        out += nums
    return out
listed = set()
for l in new:
    hd = l.split(": ", 1)[0]
    lm = re.search(r"decisions?\s+([\d, ]+)", hd)
    if lm: listed.update(int(x) for x in re.findall(r"\d+", lm.group(1)))
want = set(int(x) for x in open(numfile).read().split())
def body_numbers(u):
    mm = re.match(r"^(?:OPERATOR|CHIEF)[^(]*\([^)]*\)(.*)$", u[0])
    if not mm: return []
    rest = " ".join([mm.group(1)] + u[1:])
    out = [int(d.group(1)) for d in re.finditer(r"decisions?\s+(\d+)", rest, re.I)]
    out += [int(d.group(1)) for d in re.finditer(r"(?<![\w/.:#-])(\d{3})(?::\s|, verbatim in specs/)", rest)]
    return out
for u in units:
    want.update(header_numbers(u[0]))
    want.update(body_numbers(u))
missing = sorted(n for n in want if n not in listed)
if missing: print("decision numbers with no index line: %s" % missing[:10]); sys.exit(1)
flat = [" ".join(l.split()) for l in expected]
for l in new:
    if l in expected or l.startswith("Full original text"): continue
    mm = re.match(r"^((?:OPERATOR|CHIEF)(?:[^:]|(?<=\d):(?=\d))*): (.*)$", l)
    if l in cont_lines: print("a line directly under a ruling is its own index line: " + l[:60]); sys.exit(1)
    if not mm:
        core = l[:-2].rstrip() if l.endswith(" …") else l
        if any(c.startswith(core) for c in cont_lines): print("a line directly under a ruling is its own index line: " + l[:60]); sys.exit(1)
        if len(core.encode()) < 75 or not any(f.startswith(core) for f in expected): print("a line of another shape that is not the start of its source line: " + l[:60]); sys.exit(1)
        continue
    reading = " ".join(mm.group(2).replace("…", "").split())
    if len(reading) < 12: print("no reading on an index line: " + l[:80]); sys.exit(1)
    who = " ".join(mm.group(1).split(", decision")[0].split(" (")[0].split())
    srcs = [f for f in flat if f.startswith(who + " ") and reading[:30] in f]
    if not srcs: print("a reading that is not in its source: " + l[:80]); sys.exit(1)
    standing = any("STANDING" in f and "BINDING" not in f.split(")", 1)[0] for f in srcs)
    if standing and "(standing)" not in mm.group(1): print("a STANDING ruling is not labelled standing: " + l[:80]); sys.exit(1)
    if "(not marked binding)" in mm.group(1) and any("BINDING" in f.split(")", 1)[0] for f in srcs): print("a BINDING ruling is labelled not marked binding: " + l[:80]); sys.exit(1)
    if "(not marked binding)" in mm.group(1) and any("STANDING" in f for f in srcs): print("a STANDING ruling is labelled not marked binding: " + l[:80]); sys.exit(1)
sys.exit(0)
PY

# mutate.py <kind> <in doc> <out doc>: a successor doc with one defect the checker must catch.
cat > "$tmp/mutate.py" <<'PY'
import re, sys
kind, src, dst = sys.argv[1:4]
lines = open(src, encoding="utf-8").read().split("\n")
on, done = False, False
for i, l in enumerate(lines):
    if l == "## Current direction": on = True; continue
    if on and l.startswith("## "): break
    if not on or done: continue
    if kind == "dropnum":
        mm = re.match(r"^((?:OPERATOR|CHIEF)[^:]*decisions \d+(?:, \d+)*), (\d+)((?: \([a-z ]+\))?: .*)$", l)
        if mm: lines[i] = mm.group(1) + mm.group(3); done = True
    elif kind == "shortread":
        mm = re.match(r"^((?:OPERATOR|CHIEF)[^:]*: )(.{60,})$", l)
        if mm: lines[i] = mm.group(1) + "x"; done = True
    elif kind == "relabel":
        if "(standing): " in l: lines[i] = l.replace("(standing): ", "(not marked binding): ", 1); done = True
    elif kind == "dropbody":
        mm = re.match(r"^(OPERATOR 11-06 [^:]*decisions \d+(?:, \d+){4,}), (\d+)((?: \([a-z ]+\))?: .*)$", l)
        if mm: lines[i] = mm.group(1) + mm.group(3); done = True
    elif kind == "noread":
        if l.startswith("Full original text"): lines[i] = l.replace("READ ALL OF THEM in your first turn, in the same batch as this document", "see them if you like"); done = True
if not done: print("mutation %s found nothing to change" % kind); sys.exit(2)
open(dst, "w", encoding="utf-8").write("\n".join(lines))
PY

make_pair() { # <bucket> <queue segments> <ruling groups> -> docA (source) path in $made_doc
    chief new --bucket "$1" >/dev/null 2>&1
    made_doc="$root/tester/$1/DEMO-nextleg-${today}A-chief.md"
    python3 -I "$tmp/gen.py" "$made_doc" "$root/tester/$1" "$2" "$3" || check "$1: the fixture generator ran" failed ok
    cp "$made_doc" "$made_doc.src"
}
companion_files() { sed -n 's/.*under the bucket (\([^)]*\)).*/\1/p' "$1" | tr ' ' '\n'; }
# shellcheck disable=SC2016
READ_LINE='every direction companion file that the line of `## Current direction`'
# shellcheck disable=SC2016
COMPACT_LINE='each direction companion file that the line of `## Current direction` beginning `Full original text`'
live_line() { awk -v k="$2:" '$0 == "## Live state" { f = 1; next } f && /^## / { exit } f && index($0, k) == 1 { print; exit }' "$1"; }
dir_lines() { awk '$0 == "## Current direction" { f = 1; next } f && /^## / { exit } f && NF && substr($0, 1, 1) != ">"' "$1"; }
dir_block() { awk '$0 == "## Current direction" { f = 1; next } f && /^## / { exit } f && substr($0, 1, 1) != ">"' "$1"; }

run_fixture() { # <name> <queue segments> <ruling groups>
    local b="$1" src out docB hist
    make_pair "$b" "$2" "$3"
    src="$made_doc"
    printf 'fixture %s: source doc %s bytes\n' "$b" "$(wc -c < "$src" | tr -d ' ')"
    out="$(chief next --bucket "$b" --doc "$src" 2>&1)"; rc=$?
    check "$b: next succeeds" "$rc" "0"
    [ "$rc" -eq 0 ] || printf '%s\n' "$out" | tail -n 5 | sed 's/^/    next said: /'
    docB="$(printf '%s\n' "$out" | sed -n 's/^doc: //p')"
    [ -f "$docB" ] || { check "$b: next wrote the successor doc" no yes; return; }
    last_docB="$docB"
    local bytes; bytes="$(wc -c < "$docB" | tr -d ' ')"
    printf 'fixture %s: successor doc %s bytes (bound %s)\n' "$b" "$bytes" "$BOUND_BYTES"
    check "$b: (a) the successor doc is under the Read bound ($bound_note)" "$([ "$bytes" -le "$BOUND_BYTES" ] && echo under || echo "over:$bytes")" under

    # (b) no ruling dropped: the companions hold every source line, the index every number
    dir_block "$src.src" > "$src.expected"
    python3 -I "$tmp/check.py" "$docB" "$root/tester/$b" "$src.expected" "$src.numbers" >"$tmp/check.out" 2>&1; rc=$?
    check "$b: (b) the companions hold every ruling byte for byte and the index lists every decision number with a reading" "$rc" "0"
    [ "$rc" -eq 0 ] || sed 's/^/    check said: /' "$tmp/check.out"
    # the mutations: each defect must make the checker fail
    local kind
    for kind in dropnum dropbody shortread relabel noread; do
        python3 -I "$tmp/mutate.py" "$kind" "$docB" "$tmp/mut.md" >/dev/null 2>&1; rc=$?
        if [ "$rc" -ne 0 ]; then check "$b: (b) the $kind mutation found a line to change" no yes; continue; fi
        python3 -I "$tmp/check.py" "$tmp/mut.md" "$root/tester/$b" "$src.expected" "$src.numbers" >"$tmp/mut.out" 2>&1; rc=$?
        check "$b: (b) the checker fails under the $kind mutation" "$([ "$rc" -ne 0 ] && echo failed)" "failed"
    done
    victim="$(awk 'NR==1' "$src.numbers")"
    grep -v "decision $victim\b" "$docB" > "$tmp/mut.md"
    python3 -I "$tmp/check.py" "$tmp/mut.md" "$root/tester/$b" "$src.expected" "$src.numbers" >"$tmp/mut.out" 2>&1; rc=$?
    check "$b: (b) the checker fails when one ruling line is removed (mutation, decision $victim)" "$([ "$rc" -ne 0 ] && echo failed)" "failed"
    # a line gone from a companion file is caught too
    rm -rf "$tmp/bk"; mkdir -p "$tmp/bk/specs"; cp -R "$root/tester/$b/specs/decisions" "$tmp/bk/specs/decisions"
    first_part="$(sed -n 's/.*under the bucket (\([^ )]*\).*/\1/p' "$docB")"
    grep -v "decision $victim\b" "$root/tester/$b/$first_part" > "$tmp/bk/$first_part"
    python3 -I "$tmp/check.py" "$docB" "$tmp/bk" "$src.expected" "$src.numbers" >"$tmp/mut.out" 2>&1; rc=$?
    check "$b: (b) the checker fails when a ruling line is missing from the companions" "$([ "$rc" -ne 0 ] && echo failed)" "failed"

    # the judge's shapes: every number of a multi-clause header, a range, a STANDING label
    check "$b: a header with two decision clauses lists both numbers (478-shape)" "$(dir_lines "$docB" | grep -cE '^OPERATOR 11-03 [A-Z]+, decisions [0-9]+, [0-9]+( \(carry\))?: ')" "$(dir_lines "$src.src" | grep -cE '^OPERATOR 11-03 [A-Z]+ \(BINDING, carry to every successor; decision [0-9]+, O-v')"
    check "$b: a dash range in a header is listed as its numbers (274-276 shape)" "$(dir_lines "$docB" | grep -cE '^OPERATOR 10-25 [A-Z]+, decisions [0-9]+, [0-9]+, [0-9]+')" "$(dir_lines "$src.src" | grep -cE '^OPERATOR 10-25 [A-Z]+ \(decisions [0-9]+-[0-9]+\)')"
    check "$b: a (STANDING) ruling is labelled standing, never not marked binding" "$(dir_lines "$docB" | grep -cE '^OPERATOR 10-27 [A-Z]+ \(standing\): ')" "$(dir_lines "$src.src" | grep -cE '^OPERATOR 10-27 [A-Z]+ \(STANDING\): ')"

    # the live TU doc's shapes: bare "NNN:" items and "decision N" in the body are listed (726-735 and 360-361 shapes)
    check "$b: a header with two numbers and four bare NNN items lists all six (726-735 shape)" "$(dir_lines "$docB" | grep -cE '^OPERATOR 11-06 [A-Z]+, decisions ([0-9]+, ){5}[0-9]+( \(carry\))?: ')" "$(dir_lines "$src.src" | grep -cE '^OPERATOR 11-06 [A-Z]+ \(BINDING, carry to every successor; decisions [0-9]+, [0-9]+, verbatim')"
    check "$b: a header with no number lists the 'decision N' forms of its body (360-361 shape)" "$(dir_lines "$docB" | grep -cE '^OPERATOR 10-30 [A-Z]+, decisions [0-9]+, [0-9]+( \(carry\))?: ')" "$(dir_lines "$src.src" | grep -cE '^OPERATOR 10-30 [A-Z]+ \(BINDING, carry to every successor\): .*\(decision [0-9]+, A\+B')"
    check "$b: a ticket number and a time are not listed as decisions" "$(dir_lines "$docB" | grep -cE '^OPERATOR 1[01]-[0-9]+ [A-Z]+, decisions .*\b(8935|9423|935|18|17)\b')" "0"
    check "$b: the note scopes BINDING to lines headed OPERATOR or CHIEF" "$(dir_lines "$docB" | grep -c '^Full original text.*Every line headed OPERATOR or CHIEF, with the lines directly under it, is BINDING')" "1"
    check "$b: lines of another shape (a dash row, an unheaded row) stay in the direction as the start of their source" "$(dir_lines "$docB" | grep -cE '^(- Owed by hand|Filed) ')" "$(dir_lines "$src.src" | grep -cE '^(- Owed by hand|Filed) ')"

    # lines directly under a ruling belong to it (the live MM shape): joined into its index line, its numbers listed,
    # and kept directly under it in the companions; the capital "Decision N" forms are numbers too
    check "$b: no line directly under a ruling is an index line of its own" "$(dir_lines "$docB" | grep -cE '^(\(1\) Safety:|Rules that come with it|\(d\) Reply to the operator)')" "0"
    check "$b: a ruling with lines directly under it lists all three Decision numbers of those lines" "$(dir_lines "$docB" | grep -cE '^OPERATOR 11-01 [A-Z]+, decisions [0-9]+, [0-9]+, [0-9]+: ')" "$(dir_lines "$src.src" | grep -cE '^OPERATOR 11-01 [A-Z]+ \(BINDING, carry VERBATIM')"
    check "$b: the companions keep the first line under the ruling directly under it" "$(companion_files "$docB" | while read -r f; do cat "$root/tester/$b/$f"; done | grep -A1 '^OPERATOR 11-01 [A-Z]* (BINDING, carry VERBATIM' | grep -c '^(1) Safety:')" "$(dir_lines "$src.src" | grep -cE '^OPERATOR 11-01 [A-Z]+ \(BINDING, carry VERBATIM')"
    check "$b: a time head keeps its colon and its number" "$(dir_lines "$docB" | grep -cE '^OPERATOR 11-06 [A-Z]+ 12:46, decision [0-9]+: ')" "$(dir_lines "$src.src" | grep -cE '^OPERATOR 11-06 [A-Z]+ 12:46 \(BINDING')"
    # the HANDOFF names the companions by their line, never by position (the rc-2 carry leaves rulings above the pointer)
    handoff="${src%.md}-HANDOFF.md"
    # shellcheck disable=SC2016
    check "$b: the HANDOFF names the companions by the line beginning 'Full original text'" "$([ -f "$handoff" ] && grep -cF 'beginning `Full original text`' "$handoff" || echo missing)" "1"
    check "$b: the HANDOFF no longer says the block's first line names them" "$([ -f "$handoff" ] && { grep -c "first line names" "$handoff" || true; } || echo missing)" "0"

    # the companions: each under the Read bound; the ACTION ZERO batch reads them
    local over=0 f
    while read -r f; do
        [ "$(wc -c < "$root/tester/$b/$f" | tr -d ' ')" -le "$BOUND_BYTES" ] || over=$((over + 1))
    done < <(companion_files "$docB")
    check "$b: every direction companion file is under the Read bound" "$over" "0"
    check "$b: the ACTION ZERO batch reads the direction companion files, required, in the same batch" "$(awk '/^1\. \*\*One batch/ { f = 1 } /^   Steps 2/ { f = 0 } f' "$docB" | tr '\n' ' ' | grep -cF "$READ_LINE")" 1
    check "$b: compaction recovery reads the companions named by the 'Full original text' line, not by position" "$(tr '\n' ' ' < "$docB" | grep -cF "$COMPACT_LINE")" 1
    # shellcheck disable=SC2016
    check "$b: no instruction anchors the companions on the first line of Current direction" "$(tr '\n' ' ' < "$docB" | grep -cF 'the first line of `## Current direction`')" 0

    # (c) the tracker's pinned operator sentence is byte-identical (decision 286)
    live_line "$docB" tracker > "$tmp/tracker.line"
    pinned="$(cat "$src.pinned")"
    check "$b: (c) the tracker line starts with the pinned sentence byte for byte" "$(head -c "$((${#pinned} + 9))" "$tmp/tracker.line" | cmp -s - <(printf 'tracker: %s' "$pinned") && echo same || echo differs)" same

    # queue: the newest segment only, the older ones kept byte for byte in the dated file
    q="$(live_line "$docB" queue)"
    check "$b: the queue line holds the newest segment only (no earlier chief's marker left)" "$(printf '%s' "$q" | grep -c ' || ([A-Z][A-Z]) ')" "0"
    hist="$(printf '%s' "$q" | sed -n 's/.*older segments of this line: //p')"
    check "$b: the queue line names a history file that exists" "$([ -n "$hist" ] && [ -f "$root/tester/$b/$hist" ] && echo yes || echo no)" yes
    oldq="$(live_line "$src.src" queue | sed 's/^queue: //')"
    check "$b: the history file holds the older queue segments byte for byte" "$(grep -cF -- "${oldq#*|| }" "$root/tester/$b/$hist" 2>/dev/null)" 1
    check "$b: the last GO line is the last GO only" "$(live_line "$docB" 'last GO' | grep -o '; `' | wc -l | tr -d ' ')" "0"
}

bound_note="$BOUND_BYTES bytes"

# RED/GREEN rows on the two fixtures
run_fixture sjlike 14 110
run_fixture tqlike 40 140

# (d) a second succession: 20 long rulings added on top of the already shortened direction are
# shortened too, so the direction does not grow by their full text each time
cat > "$tmp/gen2.py" <<'PY'
import os, sys
doc, bucket, n = sys.argv[1], sys.argv[2], int(sys.argv[3])
first, tagz = (int(sys.argv[4]), sys.argv[5]) if len(sys.argv) > 5 else (900, "ZZ")
W = "alpha bravo charlie delta echo foxtrot golf hotel india juliet kilo lima mike november oscar papa".split()
new = []
for i in range(n):
    num = first + i
    open(os.path.join(bucket, "specs", "decisions", "verbatim-decision-%d-operator-11-07-%s.txt" % (num, tagz)), "w").write("operator words\n")
    new.append("OPERATOR 11-07 %s (BINDING, carry to every successor; decision %d, verbatim specs/decisions/verbatim-decision-%d-operator-11-07-%s.txt). Read, unconfirmed: %s." % (tagz, num, num, tagz, " ".join(W[(i + j) % len(W)] for j in range(70))))
lines = open(doc, encoding="utf-8").read().split("\n")
cur = lines.index("## Current direction")
nxt = next(i for i in range(cur + 1, len(lines)) if lines[i].startswith("## "))
if len(sys.argv) > 6:   # newest first: the new rulings go above everything, so the pointer line is no longer the first
    lines[cur + 2:cur + 2] = ["\n\n".join(new), ""]
else:
    lines[nxt:nxt] = ["\n\n".join(new), ""]
open(doc, "w", encoding="utf-8").write("\n".join(lines))
PY
dir_bytes() { awk '$0 == "## Current direction" { f = 1; next } f && /^## / { exit } f' "$1" | wc -c | tr -d ' '; }
gen2_doc="$last_docB"
before_dir="$(dir_bytes "$gen2_doc")"
rc=0; python3 -I "$tmp/gen2.py" "$gen2_doc" "$root/tester/tqlike" 20 || rc=$?
with_new="$(dir_bytes "$gen2_doc")"
check "tqlike second succession: the 20 new rulings were added to the source direction" "$([ "$rc" -eq 0 ] && [ "$with_new" -gt "$before_dir" ] && echo yes || echo no)" yes
out2="$(chief next --bucket tqlike --doc "$gen2_doc" 2>&1)"; rc=$?
check "tqlike second succession: next succeeds" "$rc" "0"
doc2="$(printf '%s\n' "$out2" | sed -n 's/^doc: //p')"
after_dir="$([ -f "$doc2" ] && dir_bytes "$doc2" || echo 0)"
printf 'second succession: direction %s bytes, with 20 new rulings %s, successor %s\n' "$before_dir" "$with_new" "$after_dir"
check "tqlike second succession: the 20 new rulings add under 4400 bytes (not their 12000 of full text)" "$([ "$after_dir" -gt 0 ] && [ "$((after_dir - before_dir))" -lt 4400 ] && echo under || echo "over:$((after_dir - before_dir))")" under
tq_src="$root/tester/tqlike/DEMO-nextleg-${today}A-chief.md"
{ cat "$tq_src.expected"; echo; dir_lines "$gen2_doc" | grep '^OPERATOR 11-07 ZZ '; } > "$tmp/gen2.expected"
{ cat "$tq_src.numbers"; seq 900 919; } > "$tmp/gen2.numbers"
python3 -I "$tmp/check.py" "$doc2" "$root/tester/tqlike" "$tmp/gen2.expected" "$tmp/gen2.numbers" >"$tmp/check.out" 2>&1; rc=$?
check "tqlike second succession: the companions hold the first generation and the 20 new rulings byte for byte, the index lists every number" "$rc" "0"
[ "$rc" -eq 0 ] || sed 's/^/    check said: /' "$tmp/check.out"
# a time head ("12:46") is still recognised as shortened on the second succession: not re-parsed, not relabelled
check "tqlike second succession: the time-head index lines are unchanged and still labelled as the source (none not marked binding)" "$(dir_lines "$doc2" | grep -E '^OPERATOR 11-06 [A-Z]+ 12:46' | cmp -s - <(dir_lines "$gen2_doc" | grep -E '^OPERATOR 11-06 [A-Z]+ 12:46') && dir_lines "$doc2" | grep -cE '^OPERATOR 11-06 [A-Z]+ 12:46, decision [0-9]+: ')" "$(dir_lines "$tq_src.src" | grep -cE '^OPERATOR 11-06 [A-Z]+ 12:46 \(BINDING')"
# shellcheck disable=SC2016
check "tqlike second succession: the HANDOFF names the companions by their line" "$(grep -cF 'beginning `Full original text`' "${gen2_doc%.md}-HANDOFF.md")" "1"
check "tqlike second succession: the 20 new rulings are in a companion file" "$(companion_files "$doc2" | while read -r f; do cat "$root/tester/tqlike/$f"; done | grep -c '^OPERATOR 11-07 ZZ ')" "20"

rc=0; python3 -I "$tmp/gen2.py" "$doc2" "$root/tester/tqlike" 3 950 YY || rc=$?
lost="$(companion_files "$doc2" | tail -n 1)"
mv "$root/tester/tqlike/$lost" "$tmp/lost-companion"
out3="$(chief next --bucket tqlike --doc "$doc2" 2>&1)"; rc3=$?
check "tqlike third succession (a companion file gone): next refuses (exit 7)" "$rc3" "7"
check "tqlike third succession (a companion file gone): next prints a repair line naming the file" "$(printf '%s\n' "$out3" | grep -c "repair:.*$lost")" "1"
check "tqlike third succession (a companion file gone): no successor doc was written" "$(printf '%s\n' "$out3" | grep -c '^doc: ')" "0"
mv "$tmp/lost-companion" "$root/tester/tqlike/$lost"
out3="$(chief next --bucket tqlike --doc "$doc2" 2>&1)"; rc3=$?
check "tqlike third succession (the companion file restored): next succeeds" "$rc3" "0"
doc3="$(printf '%s\n' "$out3" | sed -n 's/^doc: //p')"
check "tqlike third succession (the companion file restored): the 3 new rulings are in a companion file" "$([ -f "$doc3" ] && companion_files "$doc3" | while read -r f; do cat "$root/tester/tqlike/$f"; done | grep -c '^OPERATOR 11-07 YY ')" "3"

# (f) a fourth succession when the chief added its rulings ABOVE the pointer (newest first): the
# pointer is no longer the first line, and next still finds it, carries the earlier text forward
# and lists the new numbers
rc=0; python3 -I "$tmp/gen2.py" "$doc3" "$root/tester/tqlike" 3 970 XX top || rc=$?
check "tqlike fourth succession: the 3 new rulings were put above the pointer line" "$([ "$rc" -eq 0 ] && dir_lines "$doc3" | awk 'NR == 1 { print substr($0, 1, 14) } NR == 2 { print substr($0, 1, 14) } NR == 3 { print substr($0, 1, 14) } NR == 4 { print substr($0, 1, 18) }' | tr '\n' '|')" "OPERATOR 11-07|OPERATOR 11-07|OPERATOR 11-07|Full original text|"
out4="$(chief next --bucket tqlike --doc "$doc3" 2>&1)"; rc4=$?
check "tqlike fourth succession (pointer not first): next succeeds" "$rc4" "0"
doc4="$(printf '%s\n' "$out4" | sed -n 's/^doc: //p')"
check "tqlike fourth succession (pointer not first): the 3 new rulings are in a companion file" "$([ -f "$doc4" ] && companion_files "$doc4" | while read -r f; do cat "$root/tester/tqlike/$f"; done | grep -c '^OPERATOR 11-07 XX ')" "3"
check "tqlike fourth succession (pointer not first): the earlier 20 rulings are still in a companion file" "$([ -f "$doc4" ] && companion_files "$doc4" | while read -r f; do cat "$root/tester/tqlike/$f"; done | grep -c '^OPERATOR 11-07 ZZ ')" "20"
check "tqlike fourth succession (pointer not first): the index lists the 3 new numbers and has one pointer line" "$([ -f "$doc4" ] && dir_lines "$doc4" | grep -cE '^OPERATOR 11-07 XX, decision 97[0-2]') $([ -f "$doc4" ] && dir_lines "$doc4" | grep -c '^Full original text')" "3 1"

# the refusals on an absent or empty Current direction stay
chief new --bucket empty >/dev/null 2>&1
emptydoc="$root/tester/empty/DEMO-nextleg-${today}A-chief.md"
awk '$0 == "## Current direction" { print; print ""; print "none"; skip = 1; next } skip && /^## / { skip = 0 } skip { next } { print }' "$emptydoc" > "$emptydoc.new" && mv "$emptydoc.new" "$emptydoc"
rc=0; chief next --bucket empty --doc "$emptydoc" >/dev/null 2>&1 || rc=$?
check "next still refuses an empty Current direction block (exit 7)" "$rc" "7"

[ "$fails" -eq 0 ] && { echo "all rows passed"; exit 0; } || { echo "$fails row(s) failed"; exit 1; }
