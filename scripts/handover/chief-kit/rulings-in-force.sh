#!/usr/bin/env bash
# rulings-in-force.sh — the ledger of operator rulings in force, and the index
# `chief.sh next` renders from it into the successor's `## Current direction`.
#
#   rulings-in-force.sh record --bucket <dir> --id <N> --status <in-force|superseded-by <M>|done>
#                              [--date <YYYY-MM-DD>] [--line <one line>] [--path <file>]
#   rulings-in-force.sh render --bucket <dir>      (a Current direction block on stdin)
#
# <dir> is the bucket directory holding specs/ (the chief doc's directory). The ledger is
# <dir>/specs/decisions/rulings-in-force.jsonl, append-only, one JSON row per record:
# id, date, line, status, path (the verbatim file, relative to <dir>). The newest row of an
# id is its state, so superseding or finishing a ruling is one more `record`.
#
# record: the first row of an id needs --date, --line and --path; a later row carries any
# of the three it omits from the id's newest row. The path must be a readable, non-empty
# file under <dir>/specs/decisions/. Refused (exit 1): a bad id, date or status, a line
# that is empty or more than one line, a missing verbatim file.
#
# render: prints the block with the in-force rows as an index right after its
# `Full original text` pointer line (one line each: id, date, line, verbatim path), and
# without each ruling line whose decision numbers all have a ledger row (superseded and
# done rulings leave the block; their files and the companion files stay). Never drops
# what it cannot find: with no ledger, or no pointer line (the companions then may not hold
# the block's full text), the block is printed unchanged; a ruling line naming a number
# the ledger lacks, or naming none, is kept as it is. The rendered index is re-rendered
# from the ledger on every run. Its lines are cut to fit CHIEF_DIRECTION_BUDGET_BYTES
# (default 12000), never below 40 bytes of the one line. Exit 3, printing nothing, on an
# unreadable ledger row.
#
# Platform guard: bash 3.2+ and python3; same scope as chief.sh.
set -uo pipefail

usage() { sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }

[ "$#" -ge 1 ] || usage
verb="$1"; shift
bucket="" id="" status="" date="" line="" path=""
while [ "$#" -gt 0 ]; do
    [ "$#" -ge 2 ] || usage
    case "$1" in
        --bucket) bucket="$2" ;;
        --id) id="$2" ;;
        --status) status="$2" ;;
        --date) date="$2" ;;
        --line) line="$2" ;;
        --path) path="$2" ;;
        *) usage ;;
    esac
    shift 2
done
[ -n "$bucket" ] && [ -d "$bucket" ] || { echo "rulings-in-force: --bucket <dir> must name an existing directory" >&2; exit 2; }
case "$verb" in record|render) ;; *) usage ;; esac

exec python3 -I -c '
import json, os, re, sys
verb, bucket, rid, status, date, line, path, budget = sys.argv[1:9]
budget = int(budget)
LEDGER = "specs/decisions/rulings-in-force.jsonl"
ledger = os.path.join(bucket, LEDGER)

def die(msg, rc=1):
    sys.stderr.write("rulings-in-force: %s\n" % msg)
    sys.exit(rc)

def load():
    rows = {}
    if not os.path.exists(ledger):
        return None
    with open(ledger, encoding="utf-8") as f:
        for k, raw in enumerate(f, 1):
            if not raw.strip():
                continue
            try:
                r = json.loads(raw)
                rows[int(r["id"])] = r
            except (ValueError, KeyError, TypeError):
                die("%s line %d is not a ledger row; repair it" % (LEDGER, k), 3)
    return rows

if verb == "record":
    if not re.fullmatch(r"[0-9]+", rid):
        die("--id must be a decision number")
    m = re.fullmatch(r"in-force|done|superseded-by ([0-9]+)", status)
    if not m or (m.group(1) and int(m.group(1)) == int(rid)):
        die("--status must be in-force, done or superseded-by <another decision number>")
    prev = (load() or {}).get(int(rid), {})
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

block = sys.stdin.read()
rows = load()
src = block.split("\n")
NOTE = re.compile(r"^Full original text")
note_at = next((i for i, l in enumerate(src) if NOTE.match(l)), None)
if rows is None or note_at is None:
    sys.stdout.write(block)
    sys.exit(0)
INDEX_HEAD = "Rulings in force (ledger %s):" % LEDGER
OLD_ROW = re.compile(r"^IN FORCE ([0-9]+), ")
HEAD = re.compile(r"^(?:OPERATOR|CHIEF)(?:[^:(]|(?<=\d):(?=\d))*(?:, decisions? \d[\d, ]*)?(?: \((?:carry|standing|not marked binding)\))?: ")
LISTP = re.compile(r"\bdecisions?\s+(\d+(?:\s*(?:,|and|to|-|–)\s*\d+)*)", re.I)
def numbers(head):
    out = []
    for m in LISTP.finditer(head):
        toks, i = re.findall(r"\d+|to|-|–", m.group(1)), 0
        while i < len(toks):
            if toks[i].isdigit():
                if i + 2 < len(toks) and toks[i + 1] in ("to", "-", "–") and toks[i + 2].isdigit() and 0 <= int(toks[i + 2]) - int(toks[i]) <= 50:
                    out += range(int(toks[i]), int(toks[i + 2]) + 1); i += 3; continue
                out.append(int(toks[i]))
            i += 1
    return out
def headed(l):
    return l.startswith(("OPERATOR ", "CHIEF ", "IN FORCE ", ">", INDEX_HEAD)) or bool(NOTE.match(l))
kept, i = [], 0
while i < len(src):
    l = src[i]; i += 1
    if i - 1 == note_at:
        kept.append(None)
        continue
    if l == INDEX_HEAD:
        continue
    m = OLD_ROW.match(l)
    if m:
        if int(m.group(1)) not in rows: kept.append(l)
        continue
    h = HEAD.match(l) if l.startswith(("OPERATOR ", "CHIEF ")) else None
    nums = numbers(h.group(0)) if h else []
    if nums and all(n in rows for n in nums):
        while i < len(src) and src[i].strip() and not headed(src[i]):
            i += 1
        continue
    kept.append(l)
live = sorted((n for n, r in rows.items() if r.get("status") == "in-force"), reverse=True)
paths = re.findall(r"specs/decisions/chief-direction-[A-Za-z0-9._-]+\.md", src[note_at])
left = any(l is not None and l.startswith(("OPERATOR ", "CHIEF ")) for l in kept)
note = ("Full original text of every ruling, byte for byte, is in %d file%s under the bucket (%s). The rulings in force come first, one line each, from the ledger %s (superseded and done rulings are left out; their files stay): before you act on one, read its verbatim file." % (len(paths), "" if len(paths) == 1 else "s", " ".join(paths), LEDGER)
    + (" The OPERATOR and CHIEF lines outside that index are rulings the ledger does not hold yet, as one-line readings: READ ALL OF those files in your first turn, in the same batch as this document. Each such line, with the lines directly under it, is BINDING unless it says otherwise; any other line is context, not a ruling." if left else " Every ruling the block held is in that index; any other line is context, not a ruling."))
def row(n, cap):
    r = rows[n]; t = r.get("line", "")
    if len(t.encode()) > cap:
        c = t.encode()[:cap].decode("utf-8", "ignore")
        t = (c.rsplit(" ", 1)[0] if " " in c[1:] else c).rstrip(",;: ") + " …"
    return "IN FORCE %d, %s: %s (verbatim: %s)" % (n, r.get("date", ""), t, r.get("path", ""))
body = [l for l in kept if l is not None]
fixed = len(note.encode()) + len(INDEX_HEAD) + sum(len(l.encode()) + 1 for l in body) + sum(len(row(n, 0).encode()) + 1 for n in live)
cap = max(40, (budget - fixed) // max(len(live), 1))
index = [note, ""] + ([INDEX_HEAD] + [row(n, cap) for n in live] + [""] if live else [])
at = kept.index(None)
rest = kept[at + 1:]
while rest and not rest[0].strip(): rest.pop(0)
sys.stdout.write("\n".join(kept[:at] + index + rest))
' "$verb" "$bucket" "$id" "$status" "$date" "$line" "$path" "${CHIEF_DIRECTION_BUDGET_BYTES:-12000}"
