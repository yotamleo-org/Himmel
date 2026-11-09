#!/usr/bin/env python3
"""pins.py -- the RAG pilot's consistent snapshot, master finalization/seal and corpus digest.

  pins.py snapshot SRC DEST         SQLite backup API copy of a live (WAL) index, never a byte copy
  pins.py digest DB                 the schema-versioned canonical logical corpus digest
  pins.py finalize DB --qmd Q --config-dir D [--expect-collection name=path]... --seal OUT
                                    open DB once with the pinned qmd and the locked eval config
                                    (network namespace, explicit --index eval, INDEX_PATH), check
                                    the synced config hash and scope, clear llm_cache, checkpoint,
                                    validate, then seal (read-only file + seal JSON)
  pins.py verify DB --seal SEAL     the digest still equals the seal
  pins.py disposable MASTER DEST --seal SEAL
                                    a fresh writable copy (reflink, else backup API) whose digest
                                    equals the seal; never a query target on the master itself
  pins.py h0 --graph G --h0 SHA     the frozen graph must be built at H0

Exit 0 ok, 2 usage, 3 refusal (with a one-line reason on stderr).
"""
import argparse, hashlib, json, os, re, shutil, sqlite3, subprocess, sys, tempfile, time

DIGEST_SCHEMA = "qmd-corpus-digest/1"
# Every table the pinned qmd layout may hold, by class. llm_cache is the one application-cache
# exclusion: its rows never enter the digest. Virtual tables are covered by their shadow tables
# and their schema SQL. Anything else is unknown and refuses.
CACHE_TABLES = {"llm_cache"}
CORPUS_TABLES = {
    "content", "content_vectors", "documents", "document_metadata", "document_metadata_values",
    "store_collections", "store_config", "file_sync_state", "sqlite_sequence",
    "vector_rows", "vector_collection_ids",
    "documents_fts_config", "documents_fts_content", "documents_fts_data", "documents_fts_docsize", "documents_fts_idx",
    "vectors_by_collection_chunks", "vectors_by_collection_info", "vectors_by_collection_rowids",
}
VIRTUAL_TABLES = {"documents_fts", "vectors_by_collection"}
VEC_CHUNK_RE = re.compile(r"^vectors_by_collection_vector_chunks\d\d$")
CONFIG_TOP = {"collections", "global_context", "models"}
CONFIG_MODELS = {"embed", "generate", "rerank", "openai_base_url"}
CONFIG_COLLECTION = {"path", "pattern", "ignore", "context", "includeByDefault"}
CRED_RE = re.compile(r"(api_?key|token|secret|password|bearer)", re.I)


class Refuse(Exception):
    pass


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for b in iter(lambda: f.read(1 << 20), b""):
            h.update(b)
    return h.hexdigest()


def canon(v):
    if isinstance(v, bytes):
        return "b:" + v.hex()
    if isinstance(v, float):
        return "f:" + repr(v)
    if isinstance(v, int):
        return "i:%d" % v
    if v is None:
        return "n:"
    return "s:" + v


def connect_ro(path):
    return sqlite3.connect("file:%s?mode=ro" % path, uri=True)


def digest(path):
    """Canonical logical digest: schema SQL, user_version and every corpus table's rows."""
    if not os.path.isfile(path):
        raise Refuse("no such index: %s" % path)
    c = connect_ro(path)
    try:
        objs = c.execute("SELECT type, name, tbl_name, sql FROM sqlite_master").fetchall()
        tables = set()
        for typ, name, _tbl, _sql in objs:
            if typ != "table":
                continue
            if name in CACHE_TABLES or name in CORPUS_TABLES or name in VIRTUAL_TABLES or VEC_CHUNK_RE.match(name):
                tables.add(name)
            elif name.startswith("sqlite_stat"):
                continue  # SQLite planner statistics, not qmd data
            else:
                raise Refuse("unrecognized schema: table %s is not in %s" % (name, DIGEST_SCHEMA))
        h = hashlib.sha256()
        h.update((DIGEST_SCHEMA + "\n").encode())
        h.update(("user_version=%d\n" % c.execute("PRAGMA user_version").fetchone()[0]).encode())
        for typ, name, tbl, sql in sorted(objs, key=lambda o: (o[0], o[1])):
            if sql is None:
                continue
            h.update(("schema %s %s %s %s\n" % (typ, name, tbl, " ".join(sql.split()))).encode())
        for name in sorted(tables):
            if name in CACHE_TABLES or name in VIRTUAL_TABLES:
                continue
            cur = c.execute('SELECT * FROM "%s"' % name)
            cols = [d[0] for d in cur.description]
            rows = sorted("\x1f".join(canon(v) for v in r) for r in cur)
            th = hashlib.sha256()
            for r in rows:
                th.update(r.encode("utf-8", "surrogatepass") + b"\x1e")
            h.update(("table %s %s %d %s\n" % (name, ",".join(cols), len(rows), th.hexdigest())).encode())
        return h.hexdigest()
    finally:
        c.close()


def snapshot(src, dest):
    if os.path.exists(dest):
        raise Refuse("snapshot target exists: %s" % dest)
    s = sqlite3.connect("file:%s?mode=ro" % src, uri=True)
    d = sqlite3.connect(dest)
    try:
        s.backup(d)
        ok = d.execute("PRAGMA integrity_check").fetchone()[0]
        if ok != "ok":
            raise Refuse("snapshot integrity_check: %s" % ok)
    finally:
        d.close()
        s.close()
    os.chmod(dest, 0o600)


def qmd_paths(qmd):
    real = os.path.realpath(qmd)
    dist = os.path.normpath(os.path.join(os.path.dirname(real), "..", "dist"))
    if not os.path.isfile(os.path.join(dist, "collections.js")):
        raise Refuse("pinned qmd has no dist/collections.js next to %s" % real)
    return real, dist


LOADER_JS = r"""
import { createHash } from "node:crypto";
const c = await import(process.argv[1] + "/collections.js");
c.setConfigIndexName(process.argv[2]); c.setConfigSource();
const cfg = c.loadConfig();
process.stdout.write(JSON.stringify({ hash: createHash("sha256").update(JSON.stringify(cfg)).digest("hex"), config: cfg }));
"""


def load_config(dist, config_dir, index="eval"):
    """The pinned qmd loader's view of the config and sha256(JSON.stringify(loadConfig()))."""
    path = os.path.join(config_dir, index + ".yml")
    if not os.path.isfile(path) or os.path.islink(path):
        raise Refuse("eval config is not a regular file: %s" % path)
    env = {"PATH": os.environ.get("PATH", "/usr/bin:/bin"), "HOME": tempfile.gettempdir(), "QMD_CONFIG_DIR": config_dir}
    p = subprocess.run(["node", "--input-type=module", "-e", LOADER_JS, dist, index], env=env, capture_output=True, text=True)
    if p.returncode != 0:
        raise Refuse("pinned qmd config loader failed: %s" % p.stderr.strip()[-300:])
    out = json.loads(p.stdout)
    return out["hash"], out["config"], sha256_file(path)


def check_config_schema(cfg):
    """Credential-free allowlisted schema: no key field even when empty, no unknown field."""
    def walk(v, where):
        if isinstance(v, dict):
            for k, x in v.items():
                if CRED_RE.search(str(k)):
                    raise Refuse("credential field %s.%s in the eval config" % (where, k))
                walk(x, "%s.%s" % (where, k))
        elif isinstance(v, list):
            for x in v:
                walk(x, where)
    walk(cfg, "config")
    extra = set(cfg) - CONFIG_TOP
    if extra:
        raise Refuse("unknown config field(s): %s" % sorted(extra))
    models = cfg.get("models") or {}
    if set(models) - CONFIG_MODELS:
        raise Refuse("unknown models field(s): %s" % sorted(set(models) - CONFIG_MODELS))
    for role in ("embed", "generate", "rerank"):
        if not models.get(role):
            raise Refuse("models.%s is missing: qmd would fall back to a default model" % role)
    for name, coll in (cfg.get("collections") or {}).items():
        if set(coll or {}) - CONFIG_COLLECTION:
            raise Refuse("unknown field(s) in collection %s" % name)


def open_once(qmd, db, config_dir, index="eval"):
    """One unbilled, network-disabled open of the copy with the pinned qmd (migrations + syncConfigToDb)."""
    if not shutil.which("bwrap"):
        raise Refuse("bwrap is required for the network-disabled finalize open")
    with tempfile.TemporaryDirectory() as tmp:
        env = {"HOME": tmp, "PATH": "/usr/bin:/bin:" + os.path.dirname(qmd), "QMD_CONFIG_DIR": config_dir,
               "INDEX_PATH": db, "XDG_CACHE_HOME": os.path.join(tmp, "cache")}
        p = subprocess.run(["bwrap", "--bind", "/", "/", "--dev", "/dev", "--proc", "/proc", "--unshare-net",
                            "--die-with-parent", "--chdir", tmp, qmd, "--index", index, "status"],
                           env=env, capture_output=True, text=True, timeout=600)
        if p.returncode != 0:
            raise Refuse("pinned qmd open failed rc=%d: %s" % (p.returncode, p.stderr.strip()[-300:]))


def finalize(db, qmd, config_dir, expect, seal_path):
    qmd, dist = qmd_paths(qmd)
    cfg_hash, cfg, cfg_bytes = load_config(dist, config_dir)
    check_config_schema(cfg)
    open_once(qmd, db, config_dir)
    c = sqlite3.connect(db)
    try:
        row = c.execute("SELECT value FROM store_config WHERE key='config_hash'").fetchone()
        if not row or row[0] != cfg_hash:
            raise Refuse("store_config.config_hash %s != loader hash %s: the config did not sync" % (row and row[0], cfg_hash))
        got = {n: (p, ctx) for n, p, ctx in c.execute("SELECT name, path, context FROM store_collections")}
        want = {n: (v.get("path"), json.dumps(v["context"], separators=(",", ":"), ensure_ascii=False) if v.get("context") else None)
                for n, v in cfg["collections"].items()}
        if got != want:
            raise Refuse("store_collections %s != config %s" % (got, want))
        for name, path in expect.items():
            if got.get(name, (None,))[0] != path:
                raise Refuse("collection %s path %s != expected %s" % (name, got.get(name, (None,))[0], path))
        gc = c.execute("SELECT value FROM store_config WHERE key='global_context'").fetchone()
        if (gc[0] if gc else None) != cfg.get("global_context"):
            raise Refuse("global_context did not sync")
        c.execute("DELETE FROM llm_cache")
        c.commit()
        c.execute("PRAGMA wal_checkpoint(TRUNCATE)")
        c.execute("PRAGMA journal_mode=DELETE")
        ok = c.execute("PRAGMA integrity_check").fetchone()[0]
        if ok != "ok":
            raise Refuse("integrity_check: %s" % ok)
        user_version = c.execute("PRAGMA user_version").fetchone()[0]
    finally:
        c.close()
    d = digest(db)
    os.chmod(db, 0o444)
    seal = {"digest_schema": DIGEST_SCHEMA, "digest": d, "config_hash": cfg_hash, "config_sha256": cfg_bytes,
            "user_version": user_version, "collections": sorted(want), "file_sha256": sha256_file(db),
            "qmd": qmd, "sealed_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())}
    with open(seal_path, "w") as f:
        json.dump(seal, f, indent=1, sort_keys=True)
    os.chmod(seal_path, 0o600)
    return seal


def load_seal(path):
    with open(path) as f:
        s = json.load(f)
    if s.get("digest_schema") != DIGEST_SCHEMA:
        raise Refuse("seal digest schema %s != %s" % (s.get("digest_schema"), DIGEST_SCHEMA))
    return s


def verify(db, seal_path):
    s = load_seal(seal_path)
    d = digest(db)
    if d != s["digest"]:
        raise Refuse("corpus digest %s != sealed %s" % (d, s["digest"]))
    return d


def disposable(master, dest, seal_path):
    t0 = time.monotonic()
    verify(master, seal_path)
    if os.path.exists(dest):
        raise Refuse("disposable target exists: %s" % dest)
    method = "reflink"
    if subprocess.run(["cp", "--reflink=always", master, dest], capture_output=True).returncode != 0:
        method = "backup"
        if os.path.exists(dest):
            os.unlink(dest)
        snapshot(master, dest)
    os.chmod(dest, 0o600)
    verify(dest, seal_path)
    return {"dest": dest, "method": method, "setup_ms": int((time.monotonic() - t0) * 1000)}


def h0(graph, want):
    with open(graph) as f:
        built = json.load(f).get("built_at_commit")
    if not built or not want or not (built.startswith(want) or want.startswith(built)):
        raise Refuse("graph built at %s, not H0 %s" % (built, want))
    return built


def main(argv):
    p = argparse.ArgumentParser(prog="pins.py")
    sub = p.add_subparsers(dest="cmd", required=True)
    a = sub.add_parser("snapshot"); a.add_argument("src"); a.add_argument("dest")
    a = sub.add_parser("digest"); a.add_argument("db")
    a = sub.add_parser("finalize"); a.add_argument("db"); a.add_argument("--qmd", required=True)
    a.add_argument("--config-dir", required=True); a.add_argument("--expect-collection", action="append", default=[])
    a.add_argument("--seal", required=True)
    a = sub.add_parser("verify"); a.add_argument("db"); a.add_argument("--seal", required=True)
    a = sub.add_parser("disposable"); a.add_argument("master"); a.add_argument("dest"); a.add_argument("--seal", required=True)
    a = sub.add_parser("h0"); a.add_argument("--graph", required=True); a.add_argument("--h0", required=True)
    args = p.parse_args(argv)
    try:
        if args.cmd == "snapshot":
            snapshot(args.src, args.dest)
        elif args.cmd == "digest":
            print(digest(args.db))
        elif args.cmd == "finalize":
            expect = dict(e.split("=", 1) for e in args.expect_collection)
            print(json.dumps(finalize(args.db, args.qmd, os.path.abspath(args.config_dir), expect, args.seal), sort_keys=True))
        elif args.cmd == "verify":
            print(verify(args.db, args.seal))
        elif args.cmd == "disposable":
            print(json.dumps(disposable(args.master, args.dest, args.seal)))
        elif args.cmd == "h0":
            print(h0(args.graph, args.h0))
    except Refuse as e:
        print("pins: refused: %s" % e, file=sys.stderr)
        return 3
    except (sqlite3.Error, OSError, ValueError, subprocess.SubprocessError) as e:
        print("pins: refused: %s: %s" % (type(e).__name__, e), file=sys.stderr)
        return 3
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
