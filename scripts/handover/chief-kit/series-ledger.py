#!/usr/bin/env python3
"""series-ledger.py: the one reader and writer of a stacked series' ledger <sid>.json.

Invariant: every ledger write goes through this script, under its lock; exactly one worker writes a series, and
only `pass` moves it.

USAGE
    series-ledger.py read     --ledger P
    series-ledger.py create   --ledger P --sid S --completes-ticket yes|no --writer DOC [--grant TEXT]
    series-ledger.py add-item --ledger P --key K [--branch B] [--worktree W] [--cut-from SHA] [--wip SHA]
                              [--writes a,b] [--state planned|authoring|committed|published|abandoned]
                              [--publish-branch B] [--published-head SHA]
                              [--scope TEXT] [--do-not TEXT]... [--commit-text TEXT]
    series-ledger.py set     --ledger P [--key K] field=value ...     (item fields with --key, else top-level)
    series-ledger.py pass     --ledger P --from DOC --to DOC
    series-ledger.py find     --bucket B --doc DOC --manifest M      (reads <B>/series/*.json; takes no lock)

Ledger fields: sid, completes_ticket, writer, grant, passes[{from,to,at}], items[{key, branch, worktree,
cut_from, wip, writes[], state, publish_branch, published_head, and when given scope, do_not[], commit_text}].
`add-item` alone records scope, do_not and commit_text (the item's own instructions, which series-next.sh start prints);
`set` refuses them, sid, writer, passes and items (only `pass` moves the writer), the item key, any unknown field,
and any state outside the five known ones.

Every write takes flock on <P>.lock, reads the ledger, changes it and replaces it by write-temp-then-rename, so
a reader never sees a half-written file and two writers never lose an update. `read` takes no lock.

`find` prints one line, `<sid> <ledger realpath> <writer|from> <label|->`, or nothing: the series DOC belongs to,
as the ledger's writer or as the `from` of a pass, and the label of the one fleet-manifest entry whose doc is the
ledger's current writer (`-` for no entry or several). Paths are compared by realpath. An unreadable ledger is exit 1.

Exit: 0 ok, 1 ledger missing or not valid JSON or not writable (a read-only directory), 2 usage or a refused field/state, 3 lock timeout
(SERIES_LEDGER_LOCK_TIMEOUT seconds, default 10), 4 conflict (ledger exists, duplicate or unknown key, `pass`
from a doc that is not the writer).
"""
import argparse
import datetime
import fcntl
import json
import os
import sys
import tempfile
import time

STATES = ("planned", "authoring", "committed", "published", "abandoned")
ITEM_FIELDS = ("branch", "worktree", "cut_from", "wip", "writes", "state", "publish_branch", "published_head")
TOP_SETTABLE = ("completes_ticket", "grant")
YES_NO = ("yes", "no")


class Refused(Exception):
    def __init__(self, code, msg):
        super().__init__(msg)
        self.code = code


def load(path):
    try:
        with open(path, encoding="utf-8") as f:
            data = json.load(f)
    except FileNotFoundError:
        raise Refused(1, "ledger not found: %s" % path)
    except (ValueError, OSError) as e:
        raise Refused(1, "ledger unreadable (%s): %s" % (e, path))
    if (not isinstance(data, dict) or not isinstance(data.get("writer"), str)
            or not isinstance(data.get("passes"), list) or not isinstance(data.get("items"), list)
            or not all(isinstance(i, dict) and isinstance(i.get("key"), str) for i in data["items"])):
        raise Refused(1, "ledger is not a series ledger: %s" % path)
    return data


def store(path, data):
    d = os.path.dirname(os.path.abspath(path))
    fd, tmp = tempfile.mkstemp(prefix=os.path.basename(path) + ".", suffix=".tmp", dir=d)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            json.dump(data, f, indent=2)
            f.write("\n")
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp, path)
    except BaseException:
        if os.path.exists(tmp):
            os.unlink(tmp)
        raise


class Locked:
    """flock on <ledger>.lock, polled until SERIES_LEDGER_LOCK_TIMEOUT."""

    def __init__(self, path):
        self.lock_path = path + ".lock"
        self.f = None

    def __enter__(self):
        timeout = float(os.environ.get("SERIES_LEDGER_LOCK_TIMEOUT", "10"))
        os.makedirs(os.path.dirname(os.path.abspath(self.lock_path)), exist_ok=True)
        self.f = open(self.lock_path, "a")
        deadline = time.monotonic() + timeout
        while not self._try_lock():
            if time.monotonic() >= deadline:
                self.f.close()
                raise Refused(3, "lock timeout after %gs: %s" % (timeout, self.lock_path))
            time.sleep(0.02)
        return self

    def _try_lock(self):
        try:
            fcntl.flock(self.f, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            return False
        return True

    def __exit__(self, *exc):
        self.f.close()  # closing drops the flock


def check_state(state):
    if state not in STATES:
        raise Refused(2, "unknown state %r (one of: %s)" % (state, ", ".join(STATES)))


def item_value(field, raw):
    if field == "writes":
        return [w for w in raw.split(",") if w]
    if field == "state":
        check_state(raw)
    return raw


def find_item(data, key):
    for it in data["items"]:
        if it["key"] == key:
            return it
    return None


def cmd_read(a):
    json.dump(load(a.ledger), sys.stdout, indent=2)
    sys.stdout.write("\n")


def cmd_create(a):
    if a.completes_ticket not in YES_NO:
        raise Refused(2, "completes-ticket must be yes or no, not %r" % a.completes_ticket)
    if not a.sid or not a.writer:
        raise Refused(2, "sid and writer must not be empty")
    with Locked(a.ledger):
        if os.path.exists(a.ledger):
            raise Refused(4, "ledger already exists: %s" % a.ledger)
        store(a.ledger, {"sid": a.sid, "completes_ticket": a.completes_ticket, "writer": a.writer,
                         "grant": a.grant, "passes": [], "items": []})


def cmd_add_item(a):
    if not a.key:
        raise Refused(2, "item key must not be empty")
    state = a.state
    check_state(state)
    row = {"key": a.key, "branch": a.branch, "worktree": a.worktree, "cut_from": a.cut_from, "wip": a.wip,
           "writes": [w for w in a.writes.split(",") if w], "state": state,
           "publish_branch": a.publish_branch, "published_head": a.published_head}
    # the item's own instructions are recorded only when given, so a row without them is as it was
    if a.scope:
        row["scope"] = a.scope
    if a.do_not:
        row["do_not"] = a.do_not
    if a.commit_text:
        row["commit_text"] = a.commit_text
    with Locked(a.ledger):
        data = load(a.ledger)
        if find_item(data, a.key):
            raise Refused(4, "item already in the ledger: %s" % a.key)
        data["items"].append(row)
        store(a.ledger, data)


def cmd_set(a):
    pairs = []
    for p in a.assignments:
        if "=" not in p:
            raise Refused(2, "expected field=value, got %r" % p)
        pairs.append(p.split("=", 1))
    keyed = a.key is not None
    allowed = ITEM_FIELDS if keyed else TOP_SETTABLE
    for field, raw in pairs:
        if field not in allowed:
            raise Refused(2, "field %r is not settable%s (settable: %s)" % (
                field, " on an item" if keyed else " at the top level", ", ".join(allowed)))
        if field == "completes_ticket" and raw not in YES_NO:
            raise Refused(2, "completes_ticket must be yes or no, not %r" % raw)
    values = [(f, item_value(f, r) if keyed else r) for f, r in pairs]
    with Locked(a.ledger):
        data = load(a.ledger)
        target = data
        if keyed:
            target = find_item(data, a.key)
            if target is None:
                raise Refused(4, "no such item: %s" % a.key)
        for f, v in values:
            target[f] = v
        store(a.ledger, data)


def cmd_pass(a):
    if not a.to_doc:
        raise Refused(2, "the new writer must not be empty")
    with Locked(a.ledger):
        data = load(a.ledger)
        if data["writer"] != a.from_doc:
            raise Refused(4, "%s is not the writer; the writer is %s" % (a.from_doc, data["writer"]))
        data["writer"] = a.to_doc
        data["passes"].append({"from": a.from_doc, "to": a.to_doc,
                               "at": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")})
        store(a.ledger, data)


def manifest_label(manifest, doc):
    """The manifest `label` of the one entry whose doc is DOC (by realpath), else "-" for no entry or several."""
    try:
        with open(manifest, encoding="utf-8") as f:
            data = json.load(f)
    except (ValueError, OSError) as e:
        raise Refused(1, "manifest unreadable (%s): %s" % (e, manifest))
    rows = data.get("workers") if isinstance(data, dict) else None
    if rows is None and isinstance(data, dict):
        rows = data.get("legs")  # a manifest not yet rewritten since the legs-to-workers rename
    if not isinstance(rows, list):
        raise Refused(1, "manifest is not a fleet manifest: %s" % manifest)
    labels = [r.get("label") for r in rows
              if isinstance(r, dict) and isinstance(r.get("doc"), str) and os.path.realpath(r["doc"]) == doc]
    if len(labels) == 1 and isinstance(labels[0], str) and labels[0].split() == [labels[0]]:
        return labels[0]
    return "-"


def cmd_find(a):
    """<sid> <ledger> <writer|from> <label|->: the series DOC belongs to, as the ledger's writer or as a doc that
    passed it on, and the manifest label of the ledger's current writer. A writer role wins over a from role."""
    series = os.path.join(a.bucket, "series")
    try:
        names = sorted(n for n in os.listdir(series) if n.endswith(".json"))
    except FileNotFoundError:
        return
    except OSError as e:
        raise Refused(1, "series directory unreadable (%s): %s" % (e, series))
    doc = os.path.realpath(a.doc)
    hits = {"writer": [], "from": []}
    for n in names:
        path = os.path.join(series, n)
        led = load(path)  # an unreadable ledger could hide the match: refuse, never skip
        if os.path.realpath(led["writer"]) == doc:
            hits["writer"].append((led, path))
        elif any(isinstance(p, dict) and isinstance(p.get("from"), str) and os.path.realpath(p["from"]) == doc
                 for p in led["passes"]):
            hits["from"].append((led, path))
    for role in ("writer", "from"):
        if len(hits[role]) > 1:  # which series' writer to address is unknowable: refuse, never take the first file
            raise Refused(1, "%s is the %s of %d ledgers: %s" % (
                a.doc, role, len(hits[role]), ", ".join(p for _, p in hits[role])))
        if hits[role]:
            led, path = hits[role][0]
            break
    else:
        return
    print("%s %s %s %s" % (led.get("sid"), os.path.realpath(path), role,
                           manifest_label(a.manifest, os.path.realpath(led["writer"]))))


class Parser(argparse.ArgumentParser):
    def error(self, message):
        raise Refused(2, message)


def build():
    p = Parser(prog="series-ledger.py")
    sub = p.add_subparsers(dest="verb", required=True, parser_class=Parser)

    def verb(name, fn):
        s = sub.add_parser(name)
        s.add_argument("--ledger", required=True)
        s.set_defaults(fn=fn)
        return s

    verb("read", cmd_read)
    s = verb("create", cmd_create)
    s.add_argument("--sid", required=True)
    s.add_argument("--completes-ticket", required=True)
    s.add_argument("--writer", required=True)
    s.add_argument("--grant", default="")
    s = verb("add-item", cmd_add_item)
    s.add_argument("--key", required=True)
    s.add_argument("--branch", default="")
    s.add_argument("--worktree", default="")
    s.add_argument("--cut-from", default="")
    s.add_argument("--wip", default="")
    s.add_argument("--writes", default="")
    s.add_argument("--state", default="planned")
    s.add_argument("--publish-branch", default="")
    s.add_argument("--published-head", default="")
    s.add_argument("--scope", default="")
    s.add_argument("--do-not", dest="do_not", action="append")
    s.add_argument("--commit-text", default="")
    s = verb("set", cmd_set)
    s.add_argument("--key")
    s.add_argument("assignments", nargs="+")
    s = verb("pass", cmd_pass)
    s.add_argument("--from", dest="from_doc", required=True)
    s.add_argument("--to", dest="to_doc", required=True)
    s = sub.add_parser("find")
    s.add_argument("--bucket", required=True)
    s.add_argument("--doc", required=True)
    s.add_argument("--manifest", required=True)
    s.set_defaults(fn=cmd_find)
    return p


def main():
    try:
        a = build().parse_args()
        a.fn(a)
    except Refused as e:
        print("series-ledger: %s" % e, file=sys.stderr)
        return e.code
    except OSError as e:  # a read-only directory or a full disk: a refusal, never a traceback
        print("series-ledger: cannot write the ledger (%s)" % e, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
