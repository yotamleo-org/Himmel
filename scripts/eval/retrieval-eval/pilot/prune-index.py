#!/usr/bin/env python3
"""prune-index.py -- prune a snapshot copy of a qmd index to the pinned export copies.

  prune-index.py DB --vec0 PATH --export collection=MANIFEST [--export ...]

A document row survives only when its path is in that collection's export manifest and its
stored content hash equals the exported file's sha256 (a symlink entry uses its in-export
target's bytes). Every other row goes from documents (the FTS triggers follow), the FTS
table, file_sync_state, document metadata, content, content_vectors, vector_rows and the vec0
partition table. A collection with no export refuses. Prints the per-table removal counts.
Run on a snapshot copy only: never on a live index.
Exit 0 ok, 3 refusal.
"""
import argparse, json, os, posixpath, sqlite3, sys


def load_manifest(path):
    with open(path) as f:
        m = json.load(f)
    files = {p: e["sha256"] for p, e in m["files"].items()}
    for link, target in m.get("symlinks", {}).items():
        resolved = posixpath.normpath(posixpath.join(posixpath.dirname(link), target))
        if resolved in files:
            files[link] = files[resolved]
    return files


def prune(db, vec0, exports):
    c = sqlite3.connect(db)
    c.enable_load_extension(True)
    c.load_extension(vec0[:-3] if vec0.endswith(".so") else vec0)
    removed = {}
    try:
        docs = c.execute("SELECT id, collection, path, hash FROM documents").fetchall()
        unknown = sorted({coll for _, coll, _, _ in docs} - set(exports))
        if unknown:
            raise SystemExit("prune: refused: collection(s) with no export manifest: %s" % unknown)
        drop = [(i, coll, path) for i, coll, path, h in docs if exports[coll].get(path) != h]
        ids = [i for i, _, _ in drop]
        c.execute("BEGIN")
        for i, coll, path in drop:
            c.execute("DELETE FROM document_metadata_values WHERE document_id=?", (i,))
            c.execute("DELETE FROM document_metadata WHERE document_id=?", (i,))
            c.execute("DELETE FROM documents WHERE id=?", (i,))
            c.execute("DELETE FROM documents_fts WHERE rowid=?", (i,))
        removed["documents"] = len(ids)
        kept_ids = {r[0] for r in c.execute("SELECT id FROM documents")}
        fts_orphans = [r[0] for r in c.execute("SELECT rowid FROM documents_fts") if r[0] not in kept_ids]
        for r in fts_orphans:
            c.execute("DELETE FROM documents_fts WHERE rowid=?", (r,))
        removed["documents_fts_orphans"] = len(fts_orphans)
        kept = {(coll, path) for coll, path in c.execute("SELECT collection, path FROM documents")}
        sync = [(coll, p) for coll, p in c.execute("SELECT collection, relative_path FROM file_sync_state") if (coll, p) not in kept]
        for coll, p in sync:
            c.execute("DELETE FROM file_sync_state WHERE collection=? AND relative_path=?", (coll, p))
        removed["file_sync_state"] = len(sync)
        live_hashes = {r[0] for r in c.execute("SELECT hash FROM documents")}
        gone_rows = [(rid, h) for rid, h in c.execute("SELECT id, hash FROM vector_rows") if h not in live_hashes]
        for rid, _ in gone_rows:
            c.execute("DELETE FROM vectors_by_collection WHERE rowid=?", (rid,))
            c.execute("DELETE FROM vector_rows WHERE id=?", (rid,))
        removed["vector_rows"] = len(gone_rows)
        cv = [r for r in c.execute("SELECT hash, seq FROM content_vectors") if r[0] not in live_hashes]
        for h, seq in cv:
            c.execute("DELETE FROM content_vectors WHERE hash=? AND seq=?", (h, seq))
        removed["content_vectors"] = len(cv)
        content = [r[0] for r in c.execute("SELECT hash FROM content") if r[0] not in live_hashes]
        for h in content:
            c.execute("DELETE FROM content WHERE hash=?", (h,))
        removed["content"] = len(content)
        c.execute("COMMIT")
        ok = c.execute("PRAGMA integrity_check").fetchone()[0]
        if ok != "ok":
            raise SystemExit("prune: refused: integrity_check %s" % ok)
    finally:
        c.close()
    return removed


def main(argv):
    p = argparse.ArgumentParser(prog="prune-index.py")
    p.add_argument("db")
    p.add_argument("--vec0", required=True)
    p.add_argument("--export", action="append", default=[], required=True)
    a = p.parse_args(argv)
    exports = {}
    for e in a.export:
        name, path = e.split("=", 1)
        exports[name] = load_manifest(path)
    try:
        print(json.dumps(prune(a.db, a.vec0, exports), sort_keys=True))
    except SystemExit as e:
        print(e, file=sys.stderr)
        return 3
    except (sqlite3.Error, OSError, KeyError, ValueError) as e:
        print("prune: refused: %s: %s" % (type(e).__name__, e), file=sys.stderr)
        return 3
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
