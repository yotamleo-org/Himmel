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
# check.py <successor doc> <numbers file> <bucket dir> <source doc>: exit 0 when every decision number is on
# a line of the successor's Current direction with a reading, a resolvable verbatim file or the
# history file, and that history file holds the source direction byte for byte.
cat > "$tmp/check.py" <<'PY'
import glob, os, re, sys
doc, numfile, bucket, src = sys.argv[1:5]
def block(p):
    on, out = False, []
    for ln in open(p, encoding="utf-8").read().split("\n"):
        if ln == "## Current direction": on = True; continue
        if on and ln.startswith("## "): break
        if on and ln.strip() and not ln.startswith(">"): out.append(ln)
    return out
new, old = block(doc), block(src)
m = re.search(r"Full original text of every ruling shortened below: (\S+) ", "\n".join(new))
if not m: print("no history pointer line"); sys.exit(1)
hist = os.path.join(bucket, m.group(1))
if not os.path.isfile(hist): print("history file missing: " + m.group(1)); sys.exit(1)
held = set(open(hist, encoding="utf-8").read().split("\n"))
for ln in old:
    if ln not in held: print("history file lacks a source line: " + ln[:60]); sys.exit(1)
bad = 0
for n in [int(x) for x in open(numfile).read().split()]:
    rx = re.compile(r"\bdecisions? [\d, ]*\b%d\b[\d, ]*(?: \((?:carry|not marked binding)\))?: (\S.*)$" % n)
    hit = [rx.search(l) for l in new if rx.search(l)]
    if not hit: print("decision %d: no line with a reading" % n); bad = 1; continue
    if not glob.glob(os.path.join(bucket, "specs/decisions/verbatim-decision-%d-*" % n)) and not held:
        print("decision %d: no verbatim file and no history" % n); bad = 1
sys.exit(bad)
PY

make_pair() { # <bucket> <queue segments> <ruling groups> -> docA (source) path in $made_doc
    chief new --bucket "$1" >/dev/null 2>&1
    made_doc="$root/tester/$1/DEMO-nextleg-${today}A-chief.md"
    python3 -I "$tmp/gen.py" "$made_doc" "$root/tester/$1" "$2" "$3"
    cp "$made_doc" "$made_doc.src"
}
live_line() { awk -v k="$2:" '$0 == "## Live state" { f = 1; next } f && /^## / { exit } f && index($0, k) == 1 { print; exit }' "$1"; }

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

    # (b) no ruling dropped
    python3 -I "$tmp/check.py" "$docB" "$src.numbers" "$root/tester/$b" "$src.src" >"$tmp/check.out" 2>&1; rc=$?
    check "$b: (b) every decision number has its reading line and a resolvable verbatim file or history pointer" "$rc" "0"
    # the mutation: one ruling removed from the successor must make the checker fail
    cp "$docB" "$tmp/mut.md"
    victim="$(awk 'NR==1' "$src.numbers")"
    grep -v "decision $victim\b" "$docB" > "$tmp/mut.md"
    python3 -I "$tmp/check.py" "$tmp/mut.md" "$src.numbers" "$root/tester/$b" "$src.src" >"$tmp/mut.out" 2>&1; rc=$?
    check "$b: (b) the checker fails when one ruling is removed (mutation, decision $victim)" "$([ "$rc" -ne 0 ] && echo failed)" "failed"

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
W = "alpha bravo charlie delta echo foxtrot golf hotel india juliet kilo lima mike november oscar papa".split()
new = []
for i in range(n):
    num = 900 + i
    open(os.path.join(bucket, "specs", "decisions", "verbatim-decision-%d-operator-11-07-ZZ.txt" % num), "w").write("operator words\n")
    new.append("OPERATOR 11-07 ZZ (BINDING, carry to every successor; decision %d, verbatim specs/decisions/verbatim-decision-%d-operator-11-07-ZZ.txt). Read, unconfirmed: %s." % (num, num, " ".join(W[(i + j) % len(W)] for j in range(70))))
lines = open(doc, encoding="utf-8").read().split("\n")
cur = lines.index("## Current direction")
nxt = next(i for i in range(cur + 1, len(lines)) if lines[i].startswith("## "))
lines[nxt:nxt] = ["\n\n".join(new), ""]
open(doc, "w", encoding="utf-8").write("\n".join(lines))
PY
dir_bytes() { awk '$0 == "## Current direction" { f = 1; next } f && /^## / { exit } f' "$1" | wc -c | tr -d ' '; }
gen2_doc="$last_docB"
before_dir="$(dir_bytes "$gen2_doc")"
python3 -I "$tmp/gen2.py" "$gen2_doc" "$root/tester/tqlike" 20
with_new="$(dir_bytes "$gen2_doc")"
out2="$(chief next --bucket tqlike --doc "$gen2_doc" 2>&1)"; rc=$?
check "tqlike second succession: next succeeds" "$rc" "0"
doc2="$(printf '%s\n' "$out2" | sed -n 's/^doc: //p')"
after_dir="$([ -f "$doc2" ] && dir_bytes "$doc2" || echo 0)"
printf 'second succession: direction %s bytes, with 20 new rulings %s, successor %s\n' "$before_dir" "$with_new" "$after_dir"
check "tqlike second succession: the 20 new rulings add under 4400 bytes (not their 12000 of full text)" "$([ "$after_dir" -gt 0 ] && [ "$((after_dir - before_dir))" -lt 4400 ] && echo under || echo "over:$((after_dir - before_dir))")" under

# the refusals on an absent or empty Current direction stay
chief new --bucket empty >/dev/null 2>&1
emptydoc="$root/tester/empty/DEMO-nextleg-${today}A-chief.md"
awk '$0 == "## Current direction" { print; print ""; print "none"; skip = 1; next } skip && /^## / { skip = 0 } skip { next } { print }' "$emptydoc" > "$emptydoc.new" && mv "$emptydoc.new" "$emptydoc"
rc=0; chief next --bucket empty --doc "$emptydoc" >/dev/null 2>&1 || rc=$?
check "next still refuses an empty Current direction block (exit 7)" "$rc" "7"

[ "$fails" -eq 0 ] && { echo "all rows passed"; exit 0; } || { echo "$fails row(s) failed"; exit 1; }
