#!/usr/bin/env bash
# scripts/handover/chief-kit/readiness.sh - the per-version readiness record: one ruling per ticket
# (a ready, b close with proof, c blocked on one named blocker, d chief-only act), kept in
# <release root>/<version>/readiness.jsonl so a ruling outlives the chief who wrote it.
#
# Usage:
#   readiness.sh append <version> <KEY> a|b|c|d --evidence <text> [--blocker <KEY|n>] [--by <name>] [--mirror <dir>]
#   readiness.sh read   <version> [--mirror <dir>]
#
# The record is append-only, one JSON object per line {ts, key, decision, blocker, evidence, stamp, by}, written
# only through `append` (which computes the stamp, the hash of the ticket content as ruled on: spec section 5).
# `read` prints one JSON object per key, sorted by key: the latest row in file order plus state (live|stale),
# why (null|no-ticket|stamp|blocker-done), cat (the mirror's statusCategory), since and age_s. A key whose ticket
# is Done or no longer in the version is left out. Staleness is computed on every read and stored nowhere.
# READINESS_NOW_EPOCH replaces the clock (tests).
#
# The release root is HIMMEL_RELEASE_STATE_DIR, else <handover root>/<USER_SLUG>/<primary checkout name>/release.
# The mirror is --mirror, else ${NEXT_DISPATCH_MIRROR:-$HOME/.himmel/state/jira-mirror/HIMMEL}.
#
# Exit codes: 0 done, 2 usage or a refused value, 3 no release root, no version directory on read, no mirror or
# no ticket file, 4 the record is unreadable, invalid or cannot be locked.
#
# Platform guard: bash and python3; the chief kit is Linux-only.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

[ "$(uname -s)" = Linux ] || { echo "readiness: the chief kit is Linux-only" >&2; exit 2; }

# shellcheck source=../../lib/handover-path.sh
# shellcheck disable=SC1091
. "$HERE/../../lib/handover-path.sh"
# shellcheck source=../../lib/load-dotenv.sh
# shellcheck disable=SC1091
. "$HERE/../../lib/load-dotenv.sh"
# shellcheck source=../../lib/session-name.sh
# shellcheck disable=SC1091
. "$HERE/../../lib/session-name.sh"
# shellcheck source=../../lib/git-clean.sh
# shellcheck disable=SC1091
. "$HERE/../../lib/git-clean.sh"

RD_ROOT="" RD_ROOT_ERR=""
if [ -n "${HIMMEL_RELEASE_STATE_DIR:-}" ]; then
    RD_ROOT="$HIMMEL_RELEASE_STATE_DIR"
else
    # the primary checkout is the dirname of the git common dir, as tick.sh and status-drift.sh resolve it
    RD_COMMON="$(git_clean -C "$HERE" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || RD_COMMON="" # swallow-ok: no git leaves the checkout two levels above this kit as the primary
    if [ -n "$RD_COMMON" ]; then RD_PRIMARY="$(dirname "$RD_COMMON")"; else RD_PRIMARY="$(cd "$HERE/../../.." && pwd)"; fi
    load_dotenv --root "$(_load_dotenv_primary_for "$HERE/../../.." 2>/dev/null)" HANDOVER_DIR USER_SLUG 2>/dev/null || true # swallow-ok: an unreadable .env leaves USER_SLUG unset, which exits 3 below
    if [ -z "${USER_SLUG:-}" ]; then
        RD_ROOT_ERR="USER_SLUG is set in no layer (environment, ~/.himmel/himmel.conf, the primary checkout's .env) and HIMMEL_RELEASE_STATE_DIR is unset: no release root"
    elif RD_HR="$(cd "$RD_PRIMARY" && handover_root 2>/dev/null)"; then # swallow-ok: a failed resolve takes the else branch below, which exits 3 with its own message
        RD_ROOT="$RD_HR/$USER_SLUG/$(basename "$RD_PRIMARY")/release"
    else
        RD_ROOT_ERR="the handover root cannot be resolved from $RD_PRIMARY: no release root"
    fi
fi
RD_BY_DEFAULT="$(current_session_name 2>/dev/null)" || RD_BY_DEFAULT="" # swallow-ok: an unnamed session leaves by empty, and append then exits 2 unless --by is given
RD_MIRROR_DEFAULT="${NEXT_DISPATCH_MIRROR:-${HOME:-/tmp}/.himmel/state/jira-mirror/HIMMEL}" # env-literal-ok: the mirror default tick.sh uses
export RD_ROOT RD_ROOT_ERR RD_BY_DEFAULT RD_MIRROR_DEFAULT

exec python3 -I - "$@" <<'PY'
import calendar, fcntl, hashlib, json, os, re, sys, time, unicodedata

USAGE = """usage: readiness.sh append <version> <KEY> a|b|c|d --evidence <text> [--blocker <KEY|n>] [--by <name>] [--mirror <dir>]
       readiness.sh read   <version> [--mirror <dir>]
--blocker is a ticket KEY or a bare number. A bare number is always an operator decision number.
A ruling blocked on a PR names the PR's ticket KEY as its c blocker, never the PR number.
"""
BLOCKER_MSG = ("--blocker must be a ticket KEY or a bare operator decision number; a bare number is always an "
               "operator decision number, and a ruling blocked on a PR names the PR's ticket KEY, never the PR number")
FIELDS = ["ts", "key", "decision", "blocker", "evidence", "stamp", "by"]
KEY_RE = r"[A-Z]+-[0-9]+"
VER_RE = r"[A-Za-z0-9][A-Za-z0-9._-]*"
BY_RE = r"[A-Za-z0-9._@-]{1,128}"
TS_RE = r"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z"
STAMP_RE = r"s[0-9]+:[0-9a-f]{16}"
LIFECYCLE = {"worker-blocked", "leg-blocked"}
OWN_ENV = os.environ


def die(code, msg):
    sys.stderr.write("readiness: " + msg + "\n")
    sys.exit(code)


def usage():
    sys.stderr.write(USAGE)
    sys.exit(2)


def parse_args(args, npos, allowed):
    pos, opts, i = [], {}, 0
    while i < len(args):
        a = args[i]
        if a.startswith("--"):
            if a not in allowed or i + 1 >= len(args):
                usage()
            if a in opts:
                die(2, a + " given twice")
            opts[a] = args[i + 1]
            i += 2
        else:
            pos.append(a)
            i += 1
    if len(pos) != npos:
        usage()
    for s in pos + list(opts.values()):
        try:
            s.encode("utf-8")
        except UnicodeEncodeError:
            die(2, "an argument is not valid UTF-8")
    return pos, opts


def now_epoch():
    e = OWN_ENV.get("READINESS_NOW_EPOCH", "")
    return int(e) if re.fullmatch(r"[0-9]+", e) else int(time.time())


def iso(e):
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(e))


def evidence_ok(ev):
    if not 1 <= len(ev) <= 1024:
        return False
    return not any(unicodedata.category(c) in ("Cc", "Zl", "Zp") for c in ev)


def blocker_ok(b, key, decision):
    if b is None:
        return decision not in "c"
    if decision in "ab" or b == key:
        return False
    return bool(re.fullmatch(KEY_RE, b) or re.fullmatch(r"[0-9]+", b))


def valid_row(r):
    if not isinstance(r, dict) or list(r.keys()) != FIELDS:
        return False
    s = lambda v: isinstance(v, str)
    if not (s(r["ts"]) and re.fullmatch(TS_RE, r["ts"])):
        return False
    if not (s(r["key"]) and re.fullmatch(KEY_RE, r["key"])):
        return False
    if r["decision"] not in ("a", "b", "c", "d"):
        return False
    if r["blocker"] is not None and not s(r["blocker"]):
        return False
    if not blocker_ok(r["blocker"], r["key"], r["decision"]):
        return False
    if not (s(r["evidence"]) and evidence_ok(r["evidence"])):
        return False
    if not (s(r["stamp"]) and re.fullmatch(STAMP_RE, r["stamp"])):
        return False
    return s(r["by"]) and bool(re.fullmatch(BY_RE, r["by"]))


def parse_row(raw):
    try:
        r = json.loads(raw.decode("utf-8"))
    except (ValueError, UnicodeDecodeError):
        return None
    return r if valid_row(r) else None


def split_record(data, path):
    """-> (rows as (lineno, row), unterminated final segment as bytes); exit 4 on any other bad line"""
    segs = data.split(b"\n")
    final = segs.pop()
    rows = []
    for n, raw in enumerate(segs, 1):
        r = parse_row(raw)
        if r is None:
            die(4, "%s line %d is not a valid row; the chief deletes that line (the one hand edit allowed) and appends again" % (path, n))
        rows.append((n, r))
    return rows, final


def load_ticket(mirror, key):
    """-> {cat, fix, stamp} from the mirror file, or None when it is missing or unparsable"""
    try:
        with open(os.path.join(mirror, key + ".md"), "rb") as f:
            t = f.read().decode("utf-8")
        m = re.match(r"^---\n(.*?)\n---\n(.*)$", t, re.S)
        if not m:
            return None
        fm, b = m.groups()

        def fv(name, indent=""):
            mm = re.search(r"^" + indent + re.escape(name) + r": (.*)$", fm, re.M)
            return json.loads(mm.group(1)) if mm else None

        lists = {}
        for name, indent in (("labels", ""), ("fixVersions", ""), ("blocks", "  "), ("blocked_by", "  "), ("relates", "  ")):
            v = fv(name, indent)
            if not isinstance(v, list) or not all(isinstance(x, str) for x in v):
                return None
            lists[name] = v
        cat = fv("statusCategory")
        if cat is not None and not isinstance(cat, str):
            return None
        marker = "\n## Description\n"
        i = b.find(marker)
        if i < 0:
            return None
        rest = b[i + len(marker):]
        j = rest.find("\n## Comments")
        desc = (rest if j < 0 else rest[:j]).strip()
    except (OSError, ValueError, UnicodeDecodeError):
        return None
    labels = [x for x in lists["labels"] if not x.startswith("phase:") and x not in LIFECYCLE]
    canon = json.dumps({"labels": sorted(labels), "fixVersions": sorted(lists["fixVersions"]),
                        "blocks": sorted(lists["blocks"]), "blocked_by": sorted(lists["blocked_by"]),
                        "relates": sorted(lists["relates"]), "description": desc},
                       sort_keys=True, separators=(",", ":"), ensure_ascii=False)
    return {"cat": cat, "fix": lists["fixVersions"],
            "stamp": "s1:" + hashlib.sha256(canon.encode("utf-8")).hexdigest()[:16]}


def last_sync(mirror):
    try:
        with open(os.path.join(mirror, ".cursor.json"), "rb") as f:
            v = json.loads(f.read().decode("utf-8"))["lastSync"]
        return v if isinstance(v, str) else "unknown"
    except (OSError, ValueError, KeyError, TypeError):
        return "unknown"


def release_dir(version):
    if OWN_ENV.get("RD_ROOT_ERR"):
        die(3, OWN_ENV["RD_ROOT_ERR"])
    return os.path.join(OWN_ENV["RD_ROOT"], version)


def cmd_append(args):
    pos, o = parse_args(args, 3, ("--evidence", "--blocker", "--by", "--mirror"))
    version, key, decision = pos
    if not re.fullmatch(VER_RE, version):
        die(2, "version '%s' does not match %s" % (version, VER_RE))
    if not re.fullmatch(KEY_RE, key):
        die(2, "key '%s' does not match %s" % (key, KEY_RE))
    if decision not in ("a", "b", "c", "d"):
        die(2, "decision must be a, b, c or d")
    if "--evidence" not in o:
        die(2, "append needs --evidence")
    ev = o["--evidence"]
    if not evidence_ok(ev):
        die(2, "--evidence must be 1 to 1024 characters with no control character or line or paragraph separator")
    blocker = o.get("--blocker")
    if decision == "c" and blocker is None:
        die(2, "a c row needs --blocker (a ticket KEY or an operator decision number)")
    if decision in ("a", "b") and blocker is not None:
        die(2, "an %s row takes no --blocker" % decision)
    if blocker is not None:
        if blocker == key:
            die(2, "--blocker must not be the ticket itself")
        if not (re.fullmatch(KEY_RE, blocker) or re.fullmatch(r"[0-9]+", blocker)):
            die(2, BLOCKER_MSG)
    by = o.get("--by")
    if by is not None and not re.fullmatch(BY_RE, by):
        die(2, "--by must match " + BY_RE)
    mirror = o.get("--mirror") or OWN_ENV["RD_MIRROR_DEFAULT"]

    t = load_ticket(mirror, key)
    if t is None:
        die(3, "no ticket: %s has no readable mirror file in %s" % (key, mirror))
    if version not in t["fix"]:
        die(2, "%s's mirrored fixVersions %s lack %s (mirror lastSync %s); sync the mirror and append again"
            % (key, json.dumps(t["fix"]), version, last_sync(mirror)))
    if by is None:
        by = OWN_ENV.get("RD_BY_DEFAULT", "")
        if not re.fullmatch(BY_RE, by):
            die(2, "by unresolvable: pass --by")

    vdir = release_dir(version)
    path = os.path.join(vdir, "readiness.jsonl")
    try:
        os.makedirs(vdir, exist_ok=True)
        fd = os.open(path, os.O_RDWR | os.O_APPEND | os.O_CREAT, 0o644)
    except OSError as e:
        die(4, "cannot open %s for append (%s)" % (path, e))
    try:
        fcntl.flock(fd, fcntl.LOCK_EX)
    except OSError as e:
        die(4, "cannot lock %s (%s)" % (path, e))
    size = os.fstat(fd).st_size
    data = b""
    while len(data) < size:
        chunk = os.pread(fd, size - len(data), len(data))
        if not chunk:
            break
        data += chunk
    _, final = split_record(data, path)
    lead = b""
    if final:
        if parse_row(final) is not None:
            lead = b"\n"
            sys.stderr.write("readiness: completed an unterminated final row\n")
        else:
            os.ftruncate(fd, len(data) - len(final))
            sys.stderr.write("readiness: dropped a torn final line (%d bytes)\n" % len(final))
    row = {"ts": iso(now_epoch()), "key": key, "decision": decision, "blocker": blocker,
           "evidence": ev, "stamp": t["stamp"], "by": by}
    line = json.dumps(row, ensure_ascii=True, separators=(",", ":"))
    payload = (lead + line.encode("ascii") + b"\n")
    if os.write(fd, payload) != len(payload):
        die(4, "short write to " + path)
    os.close(fd)
    sys.stdout.write(line + "\n")


def cmd_read(args):
    pos, o = parse_args(args, 1, ("--mirror",))
    version = pos[0]
    if not re.fullmatch(VER_RE, version):
        die(2, "version '%s' does not match %s" % (version, VER_RE))
    mirror = o.get("--mirror") or OWN_ENV["RD_MIRROR_DEFAULT"]
    vdir = release_dir(version)
    if not os.path.isdir(vdir):
        die(3, "no release directory " + vdir)
    if not os.path.isdir(mirror):
        die(3, "no mirror directory " + mirror)
    path = os.path.join(vdir, "readiness.jsonl")
    try:
        with open(path, "rb") as f:
            data = f.read()
    except FileNotFoundError:
        return
    except OSError as e:
        die(4, "cannot read %s (%s)" % (path, e))
    rows, _ = split_record(data, path)
    by_key = {}
    for _, r in rows:
        by_key.setdefault(r["key"], []).append(r)
    now = now_epoch()
    for key in sorted(by_key):
        rs = by_key[key]
        last = rs[-1]
        since, prev = None, None
        for r in rs:
            sig = (r["decision"], r["blocker"], r["stamp"])
            if sig != prev:
                since, prev = r["ts"], sig
        t = load_ticket(mirror, key)
        if t is None:
            state, why, cat = "stale", "no-ticket", None
        else:
            cat = t["cat"]
            if cat == "Done" or version not in t["fix"]:
                continue
            state, why = "live", None
            if not last["stamp"].startswith("s1:") or last["stamp"] != t["stamp"]:
                state, why = "stale", "stamp"
            elif last["blocker"] and re.fullmatch(KEY_RE, last["blocker"]):
                bt = load_ticket(mirror, last["blocker"])
                if bt is not None and bt["cat"] == "Done":
                    state, why = "stale", "blocker-done"
        out = dict(last)
        out.update({"state": state, "why": why, "cat": cat, "since": since,
                    "age_s": now - calendar.timegm(time.strptime(since, "%Y-%m-%dT%H:%M:%SZ"))})
        sys.stdout.write(json.dumps(out, ensure_ascii=True, separators=(",", ":")) + "\n")


argv = sys.argv[1:]
if not argv:
    usage()
if argv[0] == "append":
    cmd_append(argv[1:])
elif argv[0] == "read":
    cmd_read(argv[1:])
else:
    usage()
PY
