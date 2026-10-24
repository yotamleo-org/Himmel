#!/usr/bin/env bash
# librarian.sh — archive finished handover docs, old session notes and one-shot
# auto-arm-status notes. Dry run by default, --apply to move. Moves only
# (git mv), never deletes, never overwrites.
#
# Bucket-root *.md docs (not console docs) are FINISHED, and move, when ALL hold:
#   - no queue lock is held on the doc or on any member of its group;
#   - its newest marker bullet is WRAPPED or HALTED (scripts/lib/leg-tail-status.sh,
#     the same parser the tick uses), OR its ticket is Done in the Jira mirror;
#   - the doc and its whole group were last modified more than --days ago (30).
# A doc's group is itself plus <stem>-RESUME*, <stem>-HANDOFF*, <stem>-judge-* and
# <stem>.* side files; the group moves together into <bucket>/archive/YYYY-MM/
# (month of the doc's mtime) and each moved file gets one line in that month's
# _index.md. Relative markdown links in a moved doc, and in the bucket-root docs
# that point at it, are rewritten in the same pass (a locked referrer is left).
# Never touched: a held lock, console docs, the specs/ tree and every other
# subtree, arms.jsonl and the other ledgers (only bucket-root *.md is read).
# Also moved: <sessions-dir>/*.md older than --sessions-days (30) to
# sessions/_archive/YYYY-MM/, and <root>/auto-arm-status-*.md older than
# --auto-arm-days (7) to <root>/archive/auto-arm-status/YYYY-MM/.
# An untracked file or an existing destination is skipped, with a SKIP line.
# With --require-cited DIR (off by default) a bucket doc also needs its ticket key cited
# in a compounded note: some *.md under DIR (the weekly notes and themes that
# compound-distill.sh writes) must hold the key as a whole token, else the doc stays with
# a `SKIP uncited` line. Sessions and auto-arm-status notes carry no key and are not gated.
#
# Usage: librarian.sh [--dry-run|--apply] [--root DIR] [--bucket DIR]
#          [--sessions-dir DIR] [--mirror DIR] [--days N] [--sessions-days N]
#          [--auto-arm-days N] [--require-cited DIR]
# Defaults: root = handover_root; bucket = <root>/<user_slug>/himmel; sessions-dir
# = <root>/../sessions; mirror = $HIMMEL_JIRA_MIRROR, else
# ~/.himmel/state/jira-mirror/${JIRA_PROJECT_KEY:-HIMMEL}.
# ponytail: the 30 day default is the narrower safe floor until S3's compounding
# coverage gate ships (the plan's 14); console docs always stay, an
# ended-console rule is a later slice; backlinks outside bucket-root *.md are
# not rewritten.
# Exit: 0 ok, 1 a move failed, 2 usage.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/handover-path.sh
. "$HERE/../lib/handover-path.sh"
# shellcheck source=../lib/leg-tail-status.sh
. "$HERE/../lib/leg-tail-status.sh"

ROOT=""; BUCKET=""; SESSIONS=""; MIRROR=""; APPLY=0; DAYS=30; SDAYS=30; ADAYS=7; CITED=""
while [ $# -gt 0 ]; do
  case "$1" in
    --root|--bucket|--sessions-dir|--mirror|--days|--sessions-days|--auto-arm-days|--require-cited)
      [ $# -ge 2 ] || { echo "librarian: $1 needs a value" >&2; exit 2; } ;;
  esac
  case "$1" in
    --root) ROOT="$2"; shift 2 ;;
    --bucket) BUCKET="$2"; shift 2 ;;
    --sessions-dir) SESSIONS="$2"; shift 2 ;;
    --mirror) MIRROR="$2"; shift 2 ;;
    --days) DAYS="$2"; shift 2 ;;
    --sessions-days) SDAYS="$2"; shift 2 ;;
    --auto-arm-days) ADAYS="$2"; shift 2 ;;
    --require-cited) CITED="$2"; shift 2 ;;
    --apply) APPLY=1; shift ;;
    --dry-run) APPLY=0; shift ;;
    *) echo "librarian: unknown argument '$1'" >&2; exit 2 ;;
  esac
done
for n in "$DAYS" "$SDAYS" "$ADAYS"; do
  case "$n" in ''|*[!0-9]*) echo "librarian: day counts must be whole numbers" >&2; exit 2 ;; esac
done

if [ -z "$ROOT" ]; then ROOT="$(handover_root)" || exit 2; fi
[ -d "$ROOT" ] || { echo "librarian: --root '$ROOT' is not a directory" >&2; exit 2; }
ROOT="$(cd "$ROOT" && pwd -P)"
if [ -z "$BUCKET" ]; then
  # shellcheck source=../lib/user-slug.sh
  . "$HERE/../lib/user-slug.sh"
  slug="$(user_slug)" || { echo "librarian: no --bucket and no user slug" >&2; exit 2; }
  BUCKET="$ROOT/$slug/himmel"
fi
[ -d "$BUCKET" ] || { echo "librarian: --bucket '$BUCKET' is not a directory" >&2; exit 2; }
BUCKET="$(cd "$BUCKET" && pwd -P)"
if [ -n "$CITED" ]; then
  [ -d "$CITED" ] || { echo "librarian: --require-cited '$CITED' is not a directory" >&2; exit 2; }
  CITED="$(cd "$CITED" && pwd -P)"
fi
[ -n "$SESSIONS" ] || SESSIONS="$ROOT/../sessions"
[ -d "$SESSIONS" ] && SESSIONS="$(cd "$SESSIONS" && pwd -P)" || SESSIONS=""
[ -n "$MIRROR" ] || MIRROR="${HIMMEL_JIRA_MIRROR:-$HOME/.himmel/state/jira-mirror/${JIRA_PROJECT_KEY:-HIMMEL}}"

# The marker parser is the shared bash one; ask it once for every bucket-root doc.
TAILS="$(mktemp -t librarian-tails.XXXXXX)" || exit 1
trap 'rm -f "$TAILS"' EXIT
for f in "$BUCKET"/*.md; do
  [ -f "$f" ] || continue
  printf '%s\t%s\n' "${f##*/}" "$(leg_tail_status "$f")"
done > "$TAILS"

python3 -I - "$ROOT" "$BUCKET" "$SESSIONS" "$MIRROR" "$APPLY" "$DAYS" "$SDAYS" "$ADAYS" "$TAILS" "$CITED" <<'PY'
import os, re, subprocess, sys, time
from urllib.parse import quote, unquote

root, bucket, sessions, mirror, apply, days, sdays, adays, tails_file, cited_dir = sys.argv[1:11]
apply = apply == "1"
now = time.time()
tails = {}
for line in open(tails_file, encoding="utf-8", errors="replace"):
    name, _, tail = line.rstrip("\n").partition("\t")
    tails[name] = tail

counts = {"locked": 0, "young": 0, "unfinished": 0, "untracked": 0, "clash": 0, "uncited": 0}
moved_map = {}      # old abs path -> new abs path
index_rows = {}     # index file -> [lines]
failed = 0


def age_days(p):
    return (now - os.stat(p).st_mtime) / 86400.0


def month(p):
    return time.strftime("%Y-%m", time.localtime(os.stat(p).st_mtime))


def date(p):
    return time.strftime("%Y-%m-%d", time.localtime(os.stat(p).st_mtime))


def lock_slug(p):
    rel = os.path.relpath(p, root)
    if rel.endswith(".md"):
        rel = rel[:-3]
    return re.sub(r"[^A-Za-z0-9_-]", "-", rel.replace(os.sep, "__"))


def locked(p):
    return os.path.isdir(os.path.join(root, ".locks", "queue", lock_slug(p) + ".lock"))


def tracked_set(d):
    r = subprocess.run(["git", "-C", d, "ls-files", "-z"], capture_output=True)
    if r.returncode != 0:
        return set()
    return set(x.decode("utf-8", "replace") for x in r.stdout.split(b"\0") if x)


def ticket_done(name):
    m = re.match(r"([A-Z][A-Z0-9]*-[0-9]+)", name)
    if not m:
        return None
    try:
        for l in open(os.path.join(mirror, m.group(1) + ".md"), encoding="utf-8", errors="replace"):
            if l.startswith("statusCategory:"):
                return m.group(1), "Done" in l
            if l.startswith("# "):
                break
    except OSError:
        pass
    return m.group(1), False


cited_keys = set()
if cited_dir:
    key_re = re.compile(r"(?<![A-Za-z0-9_-])[A-Z][A-Z0-9]*-[0-9]+(?![A-Za-z0-9_])")
    for dp, _, fns in os.walk(cited_dir):
        for fn in fns:
            if fn.endswith(".md"):
                with open(os.path.join(dp, fn), encoding="utf-8", errors="replace") as fh:
                    cited_keys.update(key_re.findall(fh.read()))

bucket_tracked = tracked_set(bucket)
bucket_files = sorted(e.name for e in os.scandir(bucket) if e.is_file(follow_symlinks=False))

moves = []  # (src, dst_dir, reason, ticket)


def plan_group(primary, reason, ticket):
    stem = primary[:-3]
    members = [n for n in bucket_files
               if n == primary
               or n.startswith(stem + "-RESUME") or n.startswith(stem + "-HANDOFF")
               or n.startswith(stem + "-judge-") or n.startswith(stem + ".")]
    ym = month(os.path.join(bucket, primary))
    dst = os.path.join(bucket, "archive", ym)
    for n in members:
        p = os.path.join(bucket, n)
        if n.endswith(".md") and locked(p):
            print("SKIP locked %s" % p)
            counts["locked"] += 1
            return
    for n in members:
        p = os.path.join(bucket, n)
        if age_days(p) <= int(days):
            counts["young"] += 1
            return
        if n not in bucket_tracked:
            print("SKIP untracked %s" % p)
            counts["untracked"] += 1
            return
        if os.path.lexists(os.path.join(dst, n)):
            print("SKIP clash %s" % p)
            counts["clash"] += 1
            return
    for n in members:
        moves.append((os.path.join(bucket, n), dst, reason, ticket, primary))


seen = set()
for n in bucket_files:
    if not n.endswith(".md") or "console" in n.lower() or n in seen:
        continue
    sub_m = re.match(r"(.+?)-(?:RESUME|HANDOFF|judge-)", n)
    if sub_m and sub_m.group(1) + ".md" in bucket_files:
        continue  # the parent doc decides for its whole group
    dot_stem = n.split(".", 1)[0]
    if dot_stem + ".md" in bucket_files and dot_stem + ".md" != n:
        continue  # a <stem>.<ext>.md sibling follows its <stem>.md the same way
    p = os.path.join(bucket, n)
    if locked(p):
        print("SKIP locked %s" % p)
        counts["locked"] += 1
        continue
    if age_days(p) <= int(days):
        counts["young"] += 1
        continue
    tail = tails.get(n, "")
    tk = ticket_done(n)
    if tail in ("WRAPPED", "HALTED"):
        reason = tail.lower()
    elif tk and tk[1]:
        reason = "ticket-done"
    else:
        counts["unfinished"] += 1
        continue
    if cited_dir and (not tk or tk[0] not in cited_keys):
        print("SKIP uncited %s" % p)
        counts["uncited"] += 1
        continue
    plan_group(n, reason, tk[0] if tk else "-")

# a file can sit in two groups (a RESUME that is its own primary): keep the first plan
uniq, seen_src = [], set()
for m in moves:
    if m[0] not in seen_src:
        seen_src.add(m[0])
        uniq.append(m)
moves = uniq


def plan_flat(d, days_n, dst_root, reason, pat):
    if not d:
        return
    tr = tracked_set(d)
    for e in sorted(os.scandir(d), key=lambda e: e.name):
        if not e.is_file(follow_symlinks=False) or not pat(e.name):
            continue
        if locked(e.path):
            print("SKIP locked %s" % e.path)
            counts["locked"] += 1
            continue
        if age_days(e.path) <= int(days_n):
            counts["young"] += 1
            continue
        dst = os.path.join(dst_root, month(e.path))
        if e.name not in tr:
            print("SKIP untracked %s" % e.path)
            counts["untracked"] += 1
        elif os.path.lexists(os.path.join(dst, e.name)):
            print("SKIP clash %s" % e.path)
            counts["clash"] += 1
        else:
            moves.append((e.path, dst, reason, "-", e.path))


plan_flat(sessions, sdays, os.path.join(sessions, "_archive") if sessions else "", "session-aged",
          lambda n: n.endswith(".md") and not n.startswith("_"))
plan_flat(root, adays, os.path.join(root, "archive", "auto-arm-status"), "auto-arm-aged",
          lambda n: n.startswith("auto-arm-status-") and n.endswith(".md"))

for src, dst, reason, ticket, _ in moves:
    moved_map[src] = os.path.join(dst, os.path.basename(src))
    print("MOVE %s -> %s" % (src, dst + "/"))

LINK = re.compile(r"(\]\()([^)\s]+)(\))")


def rewrite(text, old_dir, new_dir, target_new):
    """Re-point relative links; target_new maps an abs target to where it ends up."""
    def sub(m):
        t = m.group(2)
        if t[0] in "#/[" or "://" in t or t.startswith("mailto:"):
            return m.group(0)
        path, sep, frag = t.partition("#")
        path, qsep, query = path.partition("?")
        if not path:
            return m.group(0)
        encoded = "%" in path
        tgt = os.path.normpath(os.path.join(old_dir, unquote(path)))
        if not (os.path.lexists(tgt) or target_new(tgt) != tgt):
            return m.group(0)
        new = os.path.relpath(target_new(tgt), new_dir)
        old_rel = os.path.relpath(tgt, old_dir)
        if new == old_rel:
            return m.group(0)
        if encoded:
            new = quote(new, safe="/")
        return m.group(1) + new + (qsep + query if qsep else "") + (sep + frag if sep else "") + m.group(3)
    return LINK.sub(sub, text)


def read(p):
    with open(p, encoding="utf-8", errors="surrogateescape", newline="") as fh:
        return fh.read()


def write(p, s):
    with open(p, "w", encoding="utf-8", errors="surrogateescape", newline="") as fh:
        fh.write(s)


done_map = {}
tgt_new = lambda t: done_map.get(t, t)
refs = 0
if apply:
    # 1. move a group whole: one failed git mv puts the group's earlier members back
    bad_groups, group_done = set(), {}
    # ponytail: a queue lock taken between planning and this recheck is caught, one taken mid-move is not; upgrade path = hold queue-lock.sh around each group move
    for src, dst, reason, ticket, grp in moves:
        if grp in bad_groups:
            continue
        if grp not in group_done and any(g == grp and s.endswith(".md") and locked(s) for s, _, _, _, g in moves):
            print("SKIP locked %s" % src)
            counts["locked"] += 1
            bad_groups.add(grp)
            continue
        try:
            os.makedirs(dst, exist_ok=True)
            err = ""
        except OSError as exc:
            err = "mkdir %s: %s" % (dst, exc)
        if not err:
            r = subprocess.run(["git", "-C", os.path.dirname(src), "mv", "--", os.path.basename(src), os.path.join(dst, os.path.basename(src))],
                               capture_output=True, text=True)
            if r.returncode == 0:
                done_map[src] = moved_map[src]
                group_done.setdefault(grp, []).append(src)
                continue
            err = "git mv %s: %s" % (src, r.stderr.strip())
        print("FAIL " + err, file=sys.stderr)
        failed += 1
        bad_groups.add(grp)
        for prev in group_done.get(grp, []):
            b = subprocess.run(["git", "-C", os.path.dirname(prev), "mv", "--", os.path.relpath(done_map[prev], os.path.dirname(prev)),
                                os.path.basename(prev)], capture_output=True, text=True)
            if b.returncode == 0:
                del done_map[prev]
            else:
                print("FAIL git mv back %s: %s" % (prev, b.stderr.strip()), file=sys.stderr)
                failed += 1
    for src, dst, reason, ticket, _ in moves:
        if src in done_map:
            index_rows.setdefault(os.path.join(dst, "_index.md"), []).append(
                "- %s | %s | %s | %s | from %s" % (os.path.basename(src), ticket, date(moved_map[src]), reason,
                                                     os.path.relpath(os.path.dirname(src), root)))
    # 2. rewrite links in the moved docs, now at their new place
    for src, dst, _, _, _ in moves:
        if src in done_map and src.endswith(".md"):
            s = read(done_map[src])
            n = rewrite(s, os.path.dirname(src), dst, tgt_new)
            if n != s:
                write(done_map[src], n)
    # 3. rewrite links in the bucket-root docs that point at a moved doc
    for n in bucket_files:
        p = os.path.join(bucket, n)
        if not n.endswith(".md") or p in done_map or "console" in n.lower():
            continue
        s = read(p)
        if "](" not in s:
            continue
        r = rewrite(s, bucket, bucket, tgt_new)
        if r != s:
            if locked(p):
                print("SKIP referrer-locked %s" % p)
            else:
                write(p, r)
                refs += 1
    # 4. index
    for idx, rows in index_rows.items():
        new = not os.path.exists(idx)
        with open(idx, "a", encoding="utf-8") as fh:
            if new:
                fh.write("# Archive %s\n\n" % os.path.basename(os.path.dirname(idx)))
            fh.write("\n".join(rows) + "\n")
        r = subprocess.run(["git", "-C", os.path.dirname(idx), "add", "--", idx], capture_output=True, text=True)
        if r.returncode != 0:
            print("FAIL git add %s: %s" % (idx, r.stderr.strip()), file=sys.stderr)
            failed += 1

mode = "apply" if apply else "dry-run"
verb = "moved" if apply else "would-move"
n_moved = len(done_map) if apply else len(moves)
print("librarian: %s %s=%d skipped(locked=%d young=%d unfinished=%d untracked=%d clash=%d%s) referrers-rewritten=%d failed=%d"
      % (mode, verb, n_moved, counts["locked"], counts["young"], counts["unfinished"], counts["untracked"],
         counts["clash"], " uncited=%d" % counts["uncited"] if cited_dir else "", refs, failed))
sys.exit(1 if failed else 0)
PY
