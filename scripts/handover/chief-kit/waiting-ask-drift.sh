#!/usr/bin/env bash
# scripts/handover/chief-kit/waiting-ask-drift.sh - lists where the operator's "waiting on you" rows and the
# chief's open asks disagree, so the two lists cannot drift unseen.
#
# Usage: waiting-ask-drift.sh --doc <chief doc> [--bucket <dir>]
#
# Definitions (the same ones the Shift page and the chief waiter use):
#   waiting row  an add row of <bucket>/owed.jsonl whose actor is "operator" and that no close row refers
#                to. This is what scripts/config-ui/board.ts ledgerItems puts under Waiting on you;
#                a chief-owned row, a row with no actor and a closed row are never waiting.
#   open ask     a bullet `- [HH:MM ]OWED <key> <text>` in the chief doc (chief-wait.sh owed_wake reads the
#                same shape) that has a receipt bullet `- [HH:MM ]DELIVERED <key> msg=<id> chat=<id>`, so the
#                operator was really asked, and whose key names no closed row. An OWED bullet with no
#                receipt is the chief's own undelivered step (board.ts undeliveredItems), never an open ask.
#   match        an ask matches a row when its <key> is the row's id (o1, o2, ...) or the row's ticket key.
#                A ticket key a closed row also carried is spent: an ask under it belongs to the closed row,
#                so a new open row with that key needs an ask keyed by its own id.
# <bucket> is the chief doc's directory (where tick.sh and readOwed read owed.jsonl) unless --bucket says so.
#
# Output, one TAB-separated line per disagreement and nothing when the two sets agree:
#   waiting-no-ask   <id>   <ticket key or ->   <row text>
#   ask-no-waiting   <key>  <ask text>
# Exit codes: 0 the sets agree, 1 drift, 2 usage or an unreadable input.
# Read-only: neither the ledger nor the doc is written.
set -u

usage() { echo "usage: waiting-ask-drift.sh --doc <chief doc> [--bucket <dir>]" >&2; exit 2; }

DOC=""; BUCKET=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        --doc) [ "$#" -ge 2 ] || usage; DOC="$2"; shift 2 ;;
        --bucket) [ "$#" -ge 2 ] || usage; BUCKET="$2"; shift 2 ;;
        *) usage ;;
    esac
done
[ -n "$DOC" ] || usage
[ -f "$DOC" ] && [ -r "$DOC" ] || { echo "waiting-ask-drift: chief doc '$DOC' is not a readable file" >&2; exit 2; }
[ -n "$BUCKET" ] || BUCKET="$(cd "$(dirname "$DOC")" && pwd)"
LEDGER="$BUCKET/owed.jsonl"
command -v python3 >/dev/null 2>&1 || { echo "waiting-ask-drift: python3 is required" >&2; exit 2; }

python3 -I - "$DOC" "$LEDGER" <<'PY'
import json, re, sys

doc, ledger = sys.argv[1], sys.argv[2]
try:
    doc_lines = open(doc, encoding="utf-8").read().split("\n")
except (OSError, UnicodeDecodeError) as e:
    print(f"waiting-ask-drift: cannot read {doc}: {e}", file=sys.stderr); sys.exit(2)

adds, closed = {}, set()
try:
    raw = open(ledger, encoding="utf-8").read()
except FileNotFoundError:
    raw = ""
except (OSError, UnicodeDecodeError) as e:
    print(f"waiting-ask-drift: cannot read {ledger}: {e}", file=sys.stderr); sys.exit(2)
for n, line in enumerate(raw.split("\n"), 1):
    if not line.strip():
        continue
    try:
        row = json.loads(line)
        if not isinstance(row, dict) or row.get("op") not in ("add", "close"):
            raise ValueError("not an add or close row")
    except ValueError as e:
        print(f"waiting-ask-drift: {ledger} line {n} is unreadable: {e}", file=sys.stderr); sys.exit(2)
    if row["op"] == "add" and isinstance(row.get("id"), str):
        adds[row["id"]] = row
    elif row["op"] == "close" and isinstance(row.get("ref"), str):
        closed.add(row["ref"])

def keys_of(row):
    k = row.get("key")
    return {row["id"]} | ({k} if isinstance(k, str) and k else set())

waiting = [r for i, r in adds.items() if i not in closed and r.get("actor") == "operator"]
spent_keys = set().union(*[keys_of(r) for i, r in adds.items() if i in closed]) if closed else set()

def unspent_keys_of(row):
    return keys_of(row) - spent_keys

ask_re = re.compile(r"^- (?:\d{1,2}:\d{2} )?OWED ([A-Za-z0-9_.-]+)(?: (.*))?$")
got_re = re.compile(r"^- (?:\d{1,2}:\d{2} )?DELIVERED ([A-Za-z0-9_.-]+) msg=\d+ chat=-?\d+(?: .*)?$")
receipts = {m.group(1) for m in map(got_re.match, doc_lines) if m}
asks, seen = [], set()
for l in doc_lines:
    m = ask_re.match(l)
    if m and m.group(1) in receipts and m.group(1) not in seen:
        seen.add(m.group(1)); asks.append((m.group(1), m.group(2) or ""))

flat = lambda s: re.sub(r"[\t\n]", " ", s)
waiting_keys = set().union(*[unspent_keys_of(r) for r in waiting]) if waiting else set()
out = []
for r in waiting:
    if not unspent_keys_of(r) & seen:
        out.append("\t".join(["waiting-no-ask", r["id"], r.get("key") or "-", flat(str(r.get("text", "")))]))
for key, text in asks:
    if key not in waiting_keys and key not in spent_keys:
        out.append("\t".join(["ask-no-waiting", key, flat(text)]))
if out:
    print("\n".join(out))
    sys.exit(1)
PY
