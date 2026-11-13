#!/usr/bin/env bash
# rulings-in-force.sh — the ledger of operator rulings in force, and the index
# `chief.sh next` renders from it into the successor's `## Current direction`.
#
#   rulings-in-force.sh record --bucket <dir> --id <N> --status <in-force|superseded-by <M>|done>
#                              [--date <YYYY-MM-DD>] [--line <one line>] [--path <file>]
#   rulings-in-force.sh render --bucket <dir>                     (a Current direction block on stdin)
#   rulings-in-force.sh check --bucket <dir> [--before <file>]    (a rendered block on stdin)
#   rulings-in-force.sh find --bucket <dir> <id or word>
#
# <dir> is the bucket directory holding specs/ (the chief doc's directory). The ledger is
# <dir>/specs/decisions/rulings-in-force.jsonl, append-only, one JSON row per record:
# id, date, line, status, path (the verbatim file, relative to <dir>). The newest row of an
# id is its state, so superseding or finishing a ruling is one more `record`.
#
# record: the first row of an id needs --date, --line and --path; a later row carries any
# of the three it omits from the id's newest row. The path must be a readable, non-empty
# file under <dir>/specs/decisions/. Refused (exit 1): a bad id, date or status, a line
# that is empty or more than one line, a missing verbatim file. Superseding by a decision
# with no ledger row yet is recorded with a warning.
#
# render: prints the block with the rulings in force as one index paragraph right after its
# `Full original text` pointer line:
#   Rulings in force (<N>; left out: <D> done, <S> superseded; year <YYYY> unless a head shows one):
#   <MM-DD> <SHIFT>[ copied]:          one head per verbatim shift, newest date first, then
#   <id> <reading>                     shift letters descending, plain before copied; rows by id
#   Other verbatim paths:              descending. A ruling whose path is not
#   <id> <YYYY-MM-DD> <reading> (verbatim <short id>)   verbatim-decision-<id>-operator-<MM-DD>-<SHIFT>[-copied].txt
# for its own id and date is an Other row, its short id the part of the path between
# verbatim-decision- and .txt (the whole path when it has another shape). A head shows the
# full date when its year is not the year the index head names (the newest ruling in force).
# A reading is the start of the ruling's ledger line, with no ellipsis: the whole line when it
# is at most the cap, else its first cap bytes, backed off to the last space only when the
# byte at the cap is not a space and the back-off keeps at least half, then stripped of
# trailing `,;: `. The cap is one for every group row: the largest value, searched upward
# from 16 and bounded by the longest line in force and by 100 bytes a line, at which the index
# paragraph fits CHIEF_DIRECTION_BUDGET_BYTES (default 12000) less a fixed 6000-byte reserve
# for everything outside it, never below 16. It depends only on the ledger, the budget and the
# two constants, so blocks that differ outside the index render the same paragraph. When the
# outside part passes the reserve the cap is not recomputed against those bytes: that would
# move every reading with each line written outside the index. Over the budget the render
# still prints every reading and warns on stderr. Headroom: today's outside part leaves room
# for 4 to 5 more unledgered ruling lines, and each new companion part adds about 51 bytes to
# the pointer line. Other rows are cut to keep every index line at most 100 bytes.
#
# The rest of the block is kept, less each ruling line whose OWN decision numbers all have a
# ledger row, with the lines directly under it (superseded and done rulings leave the block;
# their files and the companion files stay), and less the earlier index; blank runs after
# the index collapse to one. A ruling's own numbers are the ones in the head of its full
# text in the companion files (before and inside its parenthesis, or a `, decision N` list
# right after a parenthesis with none), never the numbers its reading cites. An OPERATOR line
# with no full text in the companions owns its one head number only when it names that
# number's ledgered verbatim path and that file is named for the line's own date and shift
# (OPERATOR 11-07 UJ and ...-11-07-UJ.txt); a CHIEF line never does. A line matches its full
# text by its who-and-date, its listed numbers and the start of its reading, and a line that
# matches none, or more than one with different numbers, has no own number. Never drops what
# it cannot find: with no ledger, or no pointer line, the block is printed unchanged; a ruling
# line with no own number (an unnumbered ruling, one citing others, a range over 50 numbers
# or a reversed one), or with one the ledger lacks, is kept as it is.
# An earlier index paragraph starts at a line beginning `Rulings in force (` and ends at the
# next blank line. Inside it only the index lines are dropped: the heads, and a row whose
# reading (less a trailing ellipsis) starts some ledger line of its id. A row whose id has no
# ledger row is kept after the new index as `<its head without the colon> <row>`; every other
# line is kept. An earlier `IN FORCE <id>, ` row is dropped wherever it sits once its id is
# ledgered. Exit 3, printing nothing, on a ledger row that is not JSON or lacks a field.
#
# Before printing, render checks its own output as `check --before <its input>` does, with no
# NOFILE and no budget problem, plus CHANGED <line no> where the output outside the pointer
# line and the index differs from the input less what the render drops. On any problem it
# prints nothing, writes the problems to stderr and exits 4; `chief.sh next` then carries the
# block as it was. A verbatim file that is gone is a stderr NOFILE warning only.
# RULINGS_IN_FORCE_FAULT (drop-row:<id> or lose-line:<line prefix>), read only when set, is a
# test seam: it removes that row or line just before the self-check, and render then exits 4
# printing nothing whether or not anything was removed, so the seam can only fail closed.
#
# check: parses every index paragraph of the block on stdin, so a ruling named in two of
# them is TWICE (a leading `## Current direction` line is
# skipped, in the --before file too) and prints one line per problem: MISSING <id>, EXTRA
# <id>, TWICE <id>, DATE <id> <shown> <ledger>, PATH <id> <derived> <ledger>, READING <id>
# (not a prefix of the ledger line), NOFILE <id> <path>, COUNT <status> <shown> <ledger>,
# GRAMMAR <line no>, and with --before, LOST <first 60 bytes> for each line of an OPERATOR or
# CHIEF line's unit (the line and the lines directly under it) whose own numbers are not all
# in the ledger and that the block no longer holds. Then
# `check: <ok|FAIL> in-force=<n> named=<m> bytes=<b> budget=<B>`. Exit 0 clean, 1 on a
# problem, 5 clean but over budget, 3 on an unreadable ledger row, 2 on usage or no ledger.
#
# find: prints each ruling whose id is <id or word> or whose ledger line holds the word (any
# case), newest row per id, newest id first, as `<id> <date> <status> <line> (verbatim
# <path>)`. Exit 0 with a match, 1 with none, 2 on usage or no ledger.
#
# Platform guard: bash 3.2+ and python3; same scope as chief.sh.
set -uo pipefail

usage() { sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }

[ "$#" -ge 1 ] || usage
verb="$1"; shift
bucket="" id="" status="" date="" line="" path="" before="" word=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        --bucket|--id|--status|--date|--line|--path|--before)
            [ "$#" -ge 2 ] || usage
            case "$1" in
                --bucket) bucket="$2" ;;
                --id) id="$2" ;;
                --status) status="$2" ;;
                --date) date="$2" ;;
                --line) line="$2" ;;
                --path) path="$2" ;;
                --before) before="$2" ;;
            esac
            shift 2 ;;
        -*) usage ;;
        *) { [ "$verb" = find ] && [ -z "$word" ]; } || usage; word="$1"; shift ;;
    esac
done
[ -n "$bucket" ] && [ -d "$bucket" ] || { echo "rulings-in-force: --bucket <dir> must name an existing directory" >&2; exit 2; }
case "$verb" in record|render|check) ;; find) [ -n "$word" ] || usage ;; *) usage ;; esac
[ -z "$before" ] || { [ "$verb" = check ] && [ -r "$before" ]; } || { echo "rulings-in-force: --before <file> needs check and a readable file" >&2; exit 2; }

exec python3 -I -c '
import json, os, re, sys, time
verb, bucket, rid, status, date, line, path, budget, before, word = sys.argv[1:11]
budget = int(budget)
RESERVE, FLOOR, WIDTH = 6000, 16, 100
LEDGER = "specs/decisions/rulings-in-force.jsonl"
ledger = os.path.join(bucket, LEDGER)

def die(msg, rc=1):
    sys.stderr.write("rulings-in-force: %s\n" % msg)
    sys.exit(rc)

def load():
    rows, hist = {}, {}
    if not os.path.exists(ledger):
        return None, None
    with open(ledger, encoding="utf-8") as f:
        for k, raw in enumerate(f, 1):
            if not raw.strip():
                continue
            try:
                r = json.loads(raw)
                ok = (type(r["id"]) is int and r["id"] >= 0 and re.fullmatch(r"[0-9]{4}-[0-9]{2}-[0-9]{2}", r["date"])
                      and r["line"].strip() and "\n" not in r["line"] and r["path"].strip()
                      and re.fullmatch(r"in-force|done|superseded-by [0-9]+", r["status"]))
            except (ValueError, KeyError, TypeError, AttributeError):
                ok = False
            if not ok:
                die("%s line %d is not a whole ledger row (id, date, line, status, path); repair it" % (LEDGER, k), 3)
            rows[r["id"]] = r
            hist.setdefault(r["id"], set()).add(r["line"])
    return rows, hist

if verb == "record":
    if not re.fullmatch(r"[0-9]+", rid):
        die("--id must be a decision number")
    m = re.fullmatch(r"in-force|done|superseded-by ([0-9]+)", status)
    if not m or (m.group(1) and int(m.group(1)) == int(rid)):
        die("--status must be in-force, done or superseded-by <another decision number>")
    known = load()[0] or {}
    prev = known.get(int(rid), {})
    if m.group(1) and int(m.group(1)) not in known:
        sys.stderr.write("rulings-in-force: warning: decision %s has no ledger row yet; record it too\n" % m.group(1))
    date = date or prev.get("date", "")
    line = line or prev.get("line", "")
    path = path or prev.get("path", "")
    if not re.fullmatch(r"[0-9]{4}-[0-9]{2}-[0-9]{2}", date):
        die("--date must be YYYY-MM-DD (needed on the first row of a ruling)")
    if not line.strip() or "\n" in line or "\r" in line:
        die("--line must be one non-empty line (needed on the first row of a ruling)")
    full = os.path.realpath(os.path.join(bucket, path)) if path else ""
    top = os.path.realpath(os.path.join(bucket, "specs", "decisions")) + os.sep
    if not path or os.path.isabs(path) or not full.startswith(top) or not os.path.isfile(full) or os.path.getsize(full) == 0:
        die("--path must name the ruling verbatim file, non-empty, under specs/decisions/ in the bucket (got %r)" % path)
    row = {"id": int(rid), "date": date, "line": line.strip(), "status": status, "path": path}
    os.makedirs(os.path.dirname(ledger), exist_ok=True)
    fd = os.open(ledger, os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o644)
    try:
        os.write(fd, (json.dumps(row, ensure_ascii=False) + "\n").encode())
    finally:
        os.close(fd)
    print("recorded: %d %s" % (row["id"], status))
    sys.exit(0)

rows, hist = load()
if verb == "find":
    if rows is None:
        die("no ledger at %s under %s" % (LEDGER, bucket), 2)
    hits = [n for n in sorted(rows, reverse=True) if str(n) == word or word.lower() in rows[n]["line"].lower()]
    for n in hits:
        r = rows[n]
        print("%d %s %s %s (verbatim %s)" % (n, r["date"], r["status"], r["line"], r["path"]))
    sys.exit(0 if hits else 1)

NOTE = re.compile(r"^Full original text")
PARA = "Rulings in force ("
OLD_ROW = re.compile(r"^IN FORCE ([0-9]+), ")
G_HEAD = re.compile(r"^Rulings in force \(([0-9]+); left out: ([0-9]+) done, ([0-9]+) superseded; year ([0-9]{4}) unless a head shows one\):$")
G_GROUP = re.compile(r"^([0-9]{2}-[0-9]{2}|[0-9]{4}-[0-9]{2}-[0-9]{2}) ([A-Z]{2})( copied)?:$")
G_ROW = re.compile(r"^([0-9]+) (\S.*)$")
OTHERS = "Other verbatim paths:"
G_OTHER = re.compile(r"^([0-9]+) ([0-9]{4}-[0-9]{2}-[0-9]{2}) (.+) \(verbatim ([^ ()]+)\)$")
SHIFT = re.compile(r"specs/decisions/verbatim-decision-([0-9]+)-operator-([0-9]{2}-[0-9]{2})-([A-Z]{2})(-copied)?\.txt")
VID = re.compile(r"specs/decisions/verbatim-decision-(.+)\.txt")
HEAD = re.compile(r"^(?:OPERATOR|CHIEF)(?:[^:(]|(?<=\d):(?=\d))*(?:, decisions? \d[\d, ]*)?(?: \((?:carry|standing|not marked binding)\))?: ")
LISTP = re.compile(r"\bdecisions?\s+(\d+(?:\s*(?:,|and|to|-|–)\s*\d+)*)", re.I)
RAW = re.compile(r"^((?:OPERATOR|CHIEF)[^(]*?) \(([^()]*(?:\{[^{}]*\}[^()]*)*)\)[.:]?\s*(.*)$")
AFTER = re.compile(r"^, (decisions? [0-9][0-9, andto–-]*?) \(")

def numbers(head):
    out = []
    for m in LISTP.finditer(head):
        toks, i = re.findall(r"\d+|to|-|–", m.group(1)), 0
        while i < len(toks):
            if toks[i].isdigit():
                if i + 2 < len(toks) and toks[i + 1] in ("to", "-", "–") and toks[i + 2].isdigit():
                    if not 0 <= int(toks[i + 2]) - int(toks[i]) <= 50:
                        return None
                    out += range(int(toks[i]), int(toks[i + 2]) + 1); i += 3; continue
                out.append(int(toks[i]))
            i += 1
    return out

def companions(note_line):
    paths = re.findall(r"specs/decisions/chief-direction-[A-Za-z0-9._-]+\.md", note_line)
    units = []
    for rel in paths:
        try:
            text = open(os.path.join(bucket, rel), encoding="utf-8").read()
        except OSError:
            continue
        for blk in text.split("\n\n"):
            us = [b.strip() for b in blk.split("\n") if b.strip() and not b.startswith("# Current direction, full text")]
            m = RAW.match(us[0]) if us else None
            a, b = (numbers(m.group(1)), numbers(m.group(2))) if m else (None, None)
            after = AFTER.match(m.group(3)) if m else None
            c = numbers(after.group(1)) if after else []
            if a is not None and b is not None and c is not None:
                units.append((m.group(1), a + b + c, " / ".join(us)))
    return paths, units

def own_numbers(l, h, units):
    probe = l[h.end():].rstrip()
    probe = (probe[:-2] if probe.endswith(" …") else probe)[:24].rstrip()
    cited = set(numbers(h.group(0)) or [])
    own = {tuple(n) for who, n, text in units
           if l.startswith(who) and l[len(who):len(who) + 1] in (",", ":", " ") and set(n) <= cited and probe and probe in text}
    shift = re.match(r"OPERATOR ([0-9]{2}-[0-9]{2}) ([A-Z]{2})[ ,:]", l)
    if not own and shift and len(cited) == 1:
        n = next(iter(cited))
        p = rows[n]["path"] if n in rows else ""
        return [n] if p in l and p.endswith("-%s-%s.txt" % shift.groups()) else []
    return list(own.pop()) if len(own) == 1 else []

def plan(src):
    note_at = next((i for i, l in enumerate(src) if NOTE.match(l)), None)
    paths, units = companions(src[note_at]) if note_at is not None else ([], [])
    inpara, label, i = set(), {}, 0
    while i < len(src):
        if not src[i].startswith(PARA):
            i += 1; continue
        cur = None
        while i < len(src) and src[i].strip():
            inpara.add(i)
            g = G_GROUP.match(src[i])
            cur = src[i][:-1] if g or src[i] == OTHERS else cur
            label[i] = cur
            i += 1
    def headed(j):
        l = src[j]
        return (l.startswith(("OPERATOR ", "CHIEF ", "IN FORCE ", ">", PARA)) or bool(NOTE.match(l)) or bool(G_GROUP.match(l))
                or l == OTHERS or (j in inpara and bool(G_ROW.match(l))))
    drop, rewrite, keep_units, i = set(), {}, [], 0
    while i < len(src):
        l = src[i]
        if i == note_at:
            i += 1; continue
        if i in inpara and (l.startswith(PARA) or G_GROUP.match(l) or l == OTHERS):
            drop.add(i); i += 1; continue
        m = G_ROW.match(l) if i in inpara else None
        if m:
            n, o = int(m.group(1)), G_OTHER.match(l)
            t = (o.group(3) if o else m.group(2)).rstrip()
            t = t[:-1].rstrip() if t.endswith("…") else t
            if n in hist:
                if t and any(x.startswith(t) for x in hist[n]):
                    drop.add(i)
            elif label.get(i):
                rewrite[i] = label[i] + " " + l
            i += 1; continue
        m = OLD_ROW.match(l)
        if m:
            if int(m.group(1)) in rows: drop.add(i)
            i += 1; continue
        if not l.startswith(("OPERATOR ", "CHIEF ")):
            i += 1; continue
        j = i + 1
        while j < len(src) and src[j].strip() and not headed(j):
            j += 1
        h = HEAD.match(l)
        nums = own_numbers(l, h, units) if h else []
        if nums and all(n in rows for n in nums):
            drop.update(range(i, j))
        else:
            keep_units.append(range(i, j))
        i = j
    return note_at, paths, drop, rewrite, keep_units

def collapse(ls):
    out = []
    for l in ls:
        if l.strip() or (out and out[-1].strip()):
            out.append(l)
    return out

live = sorted(n for n, r in (rows or {}).items() if r["status"] == "in-force")
year = max((rows[n]["date"] for n in live), default=max((r["date"] for r in (rows or {}).values()), default=time.strftime("%Y")))[:4]

def counts():
    st = [r["status"] for r in rows.values()]
    return len(live), st.count("done"), sum(1 for s in st if s.startswith("superseded-by"))

def cut(t, cap):
    b = t.encode()
    if len(b) <= cap:
        return t
    c = b[:cap].decode("utf-8", "ignore")
    if b[cap:cap + 1] != b" " and " " in c:
        s = c.rsplit(" ", 1)[0]
        if len(s.encode()) >= cap // 2:
            c = s
    return c.rstrip(",;: ")

def problems(blk, before_src, nofile):
    L, off = blk, 0
    if L and L[0] == "## Current direction":
        L, off = L[1:], 1
    out, named = [], {}
    def row(n, shown_date, derived, reading):
        named[n] = named.get(n, 0) + 1
        if named[n] > 1:
            return
        if n not in live:
            out.append("EXTRA %d" % n); return
        r = rows[n]
        if shown_date != r["date"]:
            out.append("DATE %d %s %s" % (n, shown_date, r["date"]))
        if derived != r["path"]:
            out.append("PATH %d %s %s" % (n, derived, r["path"]))
        if not reading or not r["line"].startswith(reading):
            out.append("READING %d" % n)
    for start in [i for i, l in enumerate(L) if G_HEAD.match(l)]:
        hm = G_HEAD.match(L[start])
        for name, shown, want in zip(("in-force", "done", "superseded"), hm.groups()[:3], counts()):
            if int(shown) != want:
                out.append("COUNT %s %s %d" % (name, shown, want))
        hyear, mode, i = hm.group(4), None, start + 1
        while i < len(L) and L[i].strip():
            l = L[i]
            g, r, o = G_GROUP.match(l), G_ROW.match(l), G_OTHER.match(l)
            if g:
                mode = g
            elif l == OTHERS:
                mode = "other"
            elif mode == "other" and o:
                s = o.group(4)
                row(int(o.group(1)), o.group(2), s if "/" in s else "specs/decisions/verbatim-decision-%s.txt" % s, o.group(3))
            elif mode not in (None, "other") and r:
                d = mode.group(1) if len(mode.group(1)) == 10 else hyear + "-" + mode.group(1)
                row(int(r.group(1)), d, "specs/decisions/verbatim-decision-%s-operator-%s-%s%s.txt" % (r.group(1), d[5:], mode.group(2), "-copied" if mode.group(3) else ""), r.group(2))
            else:
                out.append("GRAMMAR %d" % (i + 1 + off))
            i += 1
    out += ["MISSING %d" % n for n in sorted(live, reverse=True) if n not in named]
    out += ["TWICE %d" % n for n in sorted(named, reverse=True) if named[n] > 1]
    if nofile:
        out += ["NOFILE %d %s" % (n, rows[n]["path"]) for n in sorted(live, reverse=True) if not os.path.isfile(os.path.join(bucket, rows[n]["path"]))]
    if before_src is not None:
        if before_src and before_src[0] == "## Current direction":
            before_src = before_src[1:]
        have = set(L)
        for u in plan(before_src)[4]:
            out += ["LOST %s" % before_src[k].encode()[:60].decode("utf-8", "ignore") for k in u if before_src[k] not in have]
    return out, len(named)

if verb == "check":
    if rows is None:
        die("no ledger at %s under %s" % (LEDGER, bucket), 2)
    text = sys.stdin.read()
    blk = text.split("\n")
    if blk[0] == "## Current direction":
        text = text.split("\n", 1)[1] if "\n" in text else ""
    bsrc = open(before, encoding="utf-8").read().split("\n") if before else None
    probs, named = problems(blk, bsrc, True)
    size = len(text.encode())
    for p in probs:
        print(p)
    print("check: %s in-force=%d named=%d bytes=%d budget=%d" % ("FAIL" if probs else "ok", len(live), named, size, budget))
    sys.exit(1 if probs else 5 if size > budget else 0)

fault = os.environ.get("RULINGS_IN_FORCE_FAULT")
block = sys.stdin.read()
src = block.split("\n")
if rows is None or not any(NOTE.match(l) for l in src):
    if fault is not None:
        die("RULINGS_IN_FORCE_FAULT is set: the render fails closed", 4)
    sys.stdout.write(block)
    sys.exit(0)
note_at, paths, drop, rewrite, keep_units = plan(src)

lead = [rewrite.get(i, l) for i, l in enumerate(src[:note_at]) if i not in drop]
after = [rewrite.get(i, l) for i, l in enumerate(src) if i > note_at and i not in drop]
while after and not after[0].strip(): after.pop(0)
rest = collapse(after)

groups, others = {}, []
for n in live:
    r = rows[n]
    m = SHIFT.fullmatch(r["path"])
    if m and int(m.group(1)) == n and m.group(2) == r["date"][5:]:
        groups.setdefault((r["date"], m.group(3), bool(m.group(4))), []).append(n)
    else:
        others.append(n)
order = sorted(groups, key=lambda k: (k[0], k[1], not k[2]), reverse=True)
others.sort(key=lambda n: (rows[n]["date"], n), reverse=True)
def short(n):
    v = VID.fullmatch(rows[n]["path"])
    return v.group(1) if v else rows[n]["path"]
def index(cap):
    out = ["Rulings in force (%d; left out: %d done, %d superseded; year %s unless a head shows one):" % (counts() + (year,))]
    for k in order:
        out.append("%s %s%s:" % (k[0][5:] if k[0][:4] == year else k[0], k[1], " copied" if k[2] else ""))
        out += ["%d %s" % (n, cut(rows[n]["line"], cap)) for n in sorted(groups[k], reverse=True)]
    if others:
        out.append(OTHERS)
    for n in others:
        head, tail = "%d %s " % (n, rows[n]["date"]), " (verbatim %s)" % short(n)
        room = WIDTH - len(head.encode()) - len(tail.encode())
        out.append(head + cut(rows[n]["line"], min(cap, max(room, FLOOR))) + tail)
    return out
def size(ls):
    return sum(len(l.encode()) + 1 for l in ls)
gframe = max((len(str(n)) + 1 for k in order for n in groups[k]), default=0)
top = min(max((len(rows[n]["line"].encode()) for n in live), default=FLOOR), WIDTH - gframe)
cap = FLOOR
while cap < top and size(index(cap + 1)) <= budget - RESERVE:
    cap += 1

left = any(l.startswith(("OPERATOR ", "CHIEF ")) for l in lead + rest)
note = ("Full original text of every ruling, byte for byte, is in %d file%s under the bucket (%s). Rulings in force come first, one line each from the ledger %s under a <MM-DD> <shift> head: before you act on one, read its verbatim file, specs/decisions/verbatim-decision-<id>-operator-<MM-DD>-<shift>.txt (-copied.txt under a head marked copied; under Other verbatim paths, verbatim-decision-<short id>.txt). Each reading is the start of its ledger line, possibly all of it; the whole line: rulings-in-force.sh find --bucket <bucket> <id or word>, or jq -c \x27select(.id == <id>)\x27 %s | tail -n 1." % (len(paths), "" if len(paths) == 1 else "s", " ".join(paths), LEDGER, LEDGER)
    + (" The OPERATOR and CHIEF lines outside that index are rulings the ledger does not hold yet, as one-line readings: READ ALL OF those files in your first turn, in the same batch as this document. Each such line, with the lines directly under it, is BINDING unless it says otherwise; any other line is context, not a ruling." if left else " Every ruling the block held is in that index; any other line is context, not a ruling."))
out = lead + [note, ""] + index(cap) + [""] + rest

if fault is not None:
    kind, _, arg = fault.partition(":")
    if kind == "drop-row":
        out = [l for l in out if not l.startswith(arg + " ")]
    elif kind == "lose-line":
        hit = next((i for i, l in enumerate(out) if l.startswith(arg)), None)
        if hit is not None:
            del out[hit]
probs = problems(out, src, False)[0]
at = next((i for i, l in enumerate(out) if NOTE.match(l)), None)
end = next((i for i in range((at or 0) + 2, len(out)) if not out[i].strip()), len(out)) if at is not None else None
if at is None or out[:at] != lead:
    probs.append("CHANGED %d" % (next((i for i, (a, b) in enumerate(zip(out, lead)) if a != b), min(len(out), len(lead))) + 1))
elif out[end + 1:] != rest:
    got = out[end + 1:]
    probs.append("CHANGED %d" % (end + 2 + next((i for i, (a, b) in enumerate(zip(got, rest)) if a != b), min(len(got), len(rest)))))
if probs or fault is not None:
    for p in probs:
        sys.stderr.write(p + "\n")
    die("the rendered block failed its self-check%s; printed nothing" % (" (RULINGS_IN_FORCE_FAULT is set)" if fault is not None else ""), 4)
for n in live:
    if not os.path.isfile(os.path.join(bucket, rows[n]["path"])):
        sys.stderr.write("NOFILE %d %s\n" % (n, rows[n]["path"]))
text = "\n".join(out)
if len(text.encode()) > budget:
    sys.stderr.write("rulings-in-force: the block is %d bytes, over its %d-byte budget (reserve %d, reading cap %d)\n" % (len(text.encode()), budget, RESERVE, cap))
sys.stdout.write(text)
' "$verb" "$bucket" "$id" "$status" "$date" "$line" "$path" "${CHIEF_DIRECTION_BUDGET_BYTES:-12000}" "$before" "$word"
