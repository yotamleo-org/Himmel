#!/usr/bin/env bash
# compound-extract.sh — the deterministic extract step of the weekly compounding pass.
# No LLM, no network, read-only.
#
# Prints one JSON object per ticket key (JSON lines, sorted by key) for the bucket-root
# *.md docs that are FINISHED and were modified within --since-days. Finished is the
# librarian's test: no queue lock, and the newest marker bullet is WRAPPED or HALTED
# (scripts/lib/leg-tail-status.sh) or the ticket is Done in the Jira mirror. Console
# docs and everything under specs/ are never read. A record holds only:
#   key       the ticket key (the doc name's leading KEY-N)
#   docs      the doc names of that key, oldest first
#   bullets   the FINDING / BLOCKED / HALTED / WRAPPED / RESOLVED / READY bullets, each
#             capped at 600 chars (never the doc body)
#   pr, sha   the newest PR number and 40-hex head/merge sha seen in those bullets, or ""
#   comments  the last two comments of the key's Jira mirror file, each capped at 1000
#             chars, or []
#
# Usage: compound-extract.sh [--root DIR] [--bucket DIR] [--mirror DIR] [--since-days N]
# Defaults: root = handover_root; bucket = <root>/<user_slug>/himmel; mirror =
# $HIMMEL_JIRA_MIRROR, else ~/.himmel/state/jira-mirror/${JIRA_PROJECT_KEY:-HIMMEL};
# --since-days 7 (0 = no window).
# ponytail: PR and sha are regex reads of the bullet text, not a ledger lookup; a
# bullet that names neither leaves them empty, upgrade path = read the leg-burn line.
# Exit: 0 ok, 2 usage.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/handover-path.sh
. "$HERE/../lib/handover-path.sh"
# shellcheck source=../lib/leg-tail-status.sh
. "$HERE/../lib/leg-tail-status.sh"

ROOT=""; BUCKET=""; MIRROR=""; SINCE=7
while [ $# -gt 0 ]; do
  case "$1" in
    --root|--bucket|--mirror|--since-days)
      [ $# -ge 2 ] || { echo "compound-extract: $1 needs a value" >&2; exit 2; } ;;
  esac
  case "$1" in
    --root) ROOT="$2"; shift 2 ;;
    --bucket) BUCKET="$2"; shift 2 ;;
    --mirror) MIRROR="$2"; shift 2 ;;
    --since-days) SINCE="$2"; shift 2 ;;
    *) echo "compound-extract: unknown argument '$1'" >&2; exit 2 ;;
  esac
done
case "$SINCE" in ''|*[!0-9]*) echo "compound-extract: --since-days must be a whole number" >&2; exit 2 ;; esac

if [ -z "$ROOT" ]; then ROOT="$(handover_root)" || exit 2; fi
[ -d "$ROOT" ] || { echo "compound-extract: --root '$ROOT' is not a directory" >&2; exit 2; }
ROOT="$(cd "$ROOT" && pwd -P)"
if [ -z "$BUCKET" ]; then
  # shellcheck source=../lib/user-slug.sh
  . "$HERE/../lib/user-slug.sh"
  slug="$(user_slug)" || { echo "compound-extract: no --bucket and no user slug" >&2; exit 2; }
  BUCKET="$ROOT/$slug/himmel"
fi
[ -d "$BUCKET" ] || { echo "compound-extract: --bucket '$BUCKET' is not a directory" >&2; exit 2; }
BUCKET="$(cd "$BUCKET" && pwd -P)"
[ -n "$MIRROR" ] || MIRROR="${HIMMEL_JIRA_MIRROR:-$HOME/.himmel/state/jira-mirror/${JIRA_PROJECT_KEY:-HIMMEL}}"

TAILS="$(mktemp -t compound-tails.XXXXXX)" || exit 1
trap 'rm -f "$TAILS"' EXIT
for f in "$BUCKET"/*.md; do
  [ -f "$f" ] || continue
  printf '%s\t%s\n' "${f##*/}" "$(leg_tail_status "$f")"
done > "$TAILS"

python3 -I - "$ROOT" "$BUCKET" "$MIRROR" "$SINCE" "$TAILS" <<'PY'
import json, os, re, sys, time

root, bucket, mirror, since, tails_file = sys.argv[1:6]
since = int(since)
now = time.time()
tails = {}
for line in open(tails_file, encoding="utf-8", errors="replace"):
    name, _, tail = line.rstrip("\n").partition("\t")
    tails[name] = tail

KEY = re.compile(r"([A-Z][A-Z0-9]*-[0-9]+)")
MARK = re.compile(r"^- (?:\d{1,2}:\d{2}\s+)?(?:\*\*)?(FINDING|BLOCKED|HALTED|WRAPPED|RESOLVED|READY)(?![A-Za-z0-9_])")
PR = re.compile(r"(?:\bPR\s*#?|pull/|#|\bREADY\s+(?:[—-]+\s*)?)(\d{2,6})\b")
SHA = re.compile(r"\b[0-9a-f]{40}\b")


def lock_slug(p):
    rel = os.path.relpath(p, root)
    if rel.endswith(".md"):
        rel = rel[:-3]
    return re.sub(r"[^A-Za-z0-9_-]", "-", rel.replace(os.sep, "__"))


def locked(p):
    return os.path.isdir(os.path.join(root, ".locks", "queue", lock_slug(p) + ".lock"))


def mirror_text(key):
    try:
        return open(os.path.join(mirror, key + ".md"), encoding="utf-8", errors="replace").read()
    except OSError:
        return ""


def ticket_done(text):
    for l in text.splitlines():
        if l.startswith("statusCategory:"):
            return "Done" in l
        if l.startswith("# "):
            break
    return False


def comments(text):
    if "\n## Comments" not in text:
        return []
    body = text.split("\n## Comments", 1)[1]
    blocks = [b.strip() for b in re.split(r"(?m)^### ", body)[1:]]
    out = []
    for b in blocks[-2:]:
        head, _, rest = b.partition("\n")
        out.append(("%s: %s" % (head.strip(), " ".join(rest.split())))[:1000])
    return out


def group_locked(name):
    m = re.match(r"(.+?)-(?:RESUME|HANDOFF|judge-)", name)
    stem = m.group(1) if m else name.split(".", 1)[0]
    for f in os.listdir(bucket):
        if f.endswith(".md") and (f.startswith((stem + "-RESUME", stem + "-HANDOFF", stem + "-judge-", stem + "."))):
            if locked(os.path.join(bucket, f)):
                return True
    return False


recs = {}
cands = []
for e in os.scandir(bucket):
    n = e.name
    if not e.is_file(follow_symlinks=False) or not n.endswith(".md") or "console" in n.lower():
        continue
    m = KEY.match(n)
    if not m:
        continue
    age = (now - e.stat().st_mtime) / 86400.0
    if since and age > since:
        continue
    if locked(e.path) or group_locked(n):
        continue
    key = m.group(1)
    if tails.get(n, "") not in ("WRAPPED", "HALTED") and not ticket_done(mirror_text(key)):
        continue
    cands.append((e.stat().st_mtime, n, key))

for _, n, key in sorted(cands):
    r = recs.setdefault(key, {"key": key, "docs": [], "bullets": [], "pr": "", "sha": ""})
    r["docs"].append(n)
    for line in open(os.path.join(bucket, n), encoding="utf-8", errors="replace"):
        line = line.rstrip("\n")
        if not MARK.match(line):
            continue
        r["bullets"].append(line[:600])
        pr = PR.findall(line)
        if pr:
            r["pr"] = pr[-1]
        sha = SHA.findall(line)
        if sha:
            r["sha"] = sha[-1]

for key in sorted(recs):
    recs[key]["comments"] = comments(mirror_text(key))
    print(json.dumps(recs[key], ensure_ascii=False))
PY
