#!/usr/bin/env bash
# test-pins.sh -- B1 of the RAG pilot: consistent snapshot, export copies, prune, master
# finalization/seal, the canonical corpus digest and tools.lock. Unbilled: the real-qmd rows
# run the pinned qmd against the local stub endpoint inside a network namespace
# (fixtures/pins/netns-run.sh); no model, no network, no key. Hosts without qmd or bwrap
# SKIP those rows loudly and still run the rest.
#
# Platform guard: Linux bash (bwrap network namespaces).
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
FX="$HERE/fixtures/pins"
PINS="$HERE/pins.py"
PRUNE="$HERE/prune-index.py"
LOCK="$HERE/tools-lock.py"
EXPORT="$HERE/export-copies.sh"
W="$(mktemp -d "${TMPDIR:-/tmp}/pilot-pins.XXXXXX")" || exit 1
trap 'chmod -R u+w "$W" 2>/dev/null; rm -rf "$W"' EXIT
fails=0
pass() { printf 'ok - %s\n' "$1"; }
fail() { printf 'FAIL - %s\n' "$1"; fails=$((fails + 1)); }
eq() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (expected '$2', got '$3')"; fi; }
ne() { if [ "$2" != "$3" ]; then pass "$1"; else fail "$1 (both '$2')"; fi; }
rc_of() { "$@" >/dev/null 2>&1; echo $?; }
gitc() { git -C "$1" -c user.email=t@t -c user.name=t "${@:2}"; }

python3 -I - "$PINS" "$W" <<'EOF'
import os, shutil, sqlite3, subprocess, sys
pins, w = sys.argv[1], sys.argv[2]
live = os.path.join(w, "wal-live.sqlite")
c = sqlite3.connect(live)
c.execute("PRAGMA journal_mode=WAL"); c.execute("PRAGMA wal_autocheckpoint=0")
c.execute("CREATE TABLE t(x)"); c.commit()
c.execute("INSERT INTO t VALUES ('in-wal-only')"); c.commit()   # connection stays open: no checkpoint
assert os.path.getsize(live + "-wal") > 0
rc = subprocess.run([sys.executable, "-I", pins, "snapshot", live, os.path.join(w, "wal-snap.sqlite")]).returncode
shutil.copyfile(live, os.path.join(w, "wal-half.sqlite"))
def rows(p):
    try:
        return [r[0] for r in sqlite3.connect(p).execute("SELECT x FROM t")]
    except sqlite3.Error:
        return []
open(os.path.join(w, "wal.out"), "w").write("%d %s %s\n" % (rc, rows(os.path.join(w, "wal-snap.sqlite")), rows(os.path.join(w, "wal-half.sqlite"))))
EOF
eq "snapshot: the backup holds the WAL-only commit; a bare main-file copy does not" "0 ['in-wal-only'] []" "$(cat "$W/wal.out")"

printf '{"built_at_commit": "%s", "nodes": [], "links": []}\n' aaaaaaa > "$W/graph.json"
eq "h0: graph built at another commit refuses" 3 "$(rc_of python3 -I "$PINS" h0 --graph "$W/graph.json" --h0 bbbbbbb)"
eq "h0: graph built at H0 passes" 0 "$(rc_of python3 -I "$PINS" h0 --graph "$W/graph.json" --h0 aaaaaaa)"

H="$W/himmel-src"; mkdir -p "$H/docs" "$H/scripts/eval/retrieval-eval/pilot" "$H/bin"
printf '# Lock\nThe queue lock keeps one session per handover doc.\n' > "$H/docs/lock.md"
printf '# Zeta\nThe zeta rule is settled.\n' > "$H/docs/zeta.md"
printf '# Changed\nversion one\n' > "$H/docs/changed.md"
printf 'pilot secret task\n' > "$H/scripts/eval/retrieval-eval/pilot/tasks.md"
printf '#!/bin/sh\nrelay_batch() { :; }\n' > "$H/bin/run.sh"
ln -s lock.md "$H/docs/lock-link.md"
git -C "$H" init -q && gitc "$H" add -A && gitc "$H" commit -q -m h0
H0=$(git -C "$H" rev-parse HEAD)
L="$W/luna-src"; mkdir -p "$L/notes" "$L/handovers"
printf '# Note\nThe garden note says water on Tuesdays.\n' > "$L/notes/garden.md"
printf '# Handover\nprivate handover text\n' > "$L/handovers/h.md"
git -C "$L" init -q && gitc "$L" add -A && gitc "$L" commit -q -m l0
L0=$(git -C "$L" rev-parse HEAD)
eq "export: himmel export succeeds" 0 "$(rc_of bash "$EXPORT" "$H" "$H0" "$W/work/himmel" "$W/himmel.manifest.json" scripts/eval/retrieval-eval/pilot)"
eq "export: luna export succeeds" 0 "$(rc_of bash "$EXPORT" "$L" "$L0" "$W/work/luna" "$W/luna.manifest.json" handovers)"
eq "export: the pilot dir is absent from the himmel copy" "no" "$([ -e "$W/work/himmel/scripts/eval/retrieval-eval/pilot" ] && echo yes || echo no)"
eq "export: handovers are absent from the luna copy" "no" "$([ -e "$W/work/luna/handovers" ] && echo yes || echo no)"
want=$(git -C "$H" ls-tree -r --name-only "$H0" | grep -c -v '^scripts/eval/retrieval-eval/pilot/')
eq "export: manifest count = git tree minus exclusions" "$want" "$(python3 -I -c 'import json,sys; m=json.load(open(sys.argv[1])); print(m["count"])' "$W/himmel.manifest.json")"
eq "export: the in-export symlink is recorded with its target" "lock.md" "$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["symlinks"].get("docs/lock-link.md"))' "$W/himmel.manifest.json")"
B="$W/bad-src"; mkdir -p "$B"; printf 'x\n' > "$B/a.md"; ln -s /etc/hostname "$B/out.md"
git -C "$B" init -q && gitc "$B" add -A && gitc "$B" commit -q -m b
eq "export: a symlink to a target outside the export refuses" 3 "$(rc_of bash "$EXPORT" "$B" "$(git -C "$B" rev-parse HEAD)" "$W/work-bad" "$W/bad.manifest.json")"

mkdir -p "$W/bin"; printf 'binary v1\n' > "$W/bin/claude"; printf 'wrapper v1\n' > "$W/bin/s-qmd"
lockargs=(--h0 "$H0" --l0 "$L0" --file claude="$W/bin/claude" --file s-qmd="$W/bin/s-qmd" --file himmel-manifest="$W/himmel.manifest.json" --tree himmel-export="$W/work/himmel" --const protocol=rag-pilot-r18)
eq "lock: build succeeds" 0 "$(rc_of python3 -I "$LOCK" build --out "$W/tools.lock" "${lockargs[@]}")"
eq "lock: an unchanged setup checks clean" 0 "$(rc_of python3 -I "$LOCK" check "$W/tools.lock")"
printf 'binary v2\n' > "$W/bin/claude"
eq "lock: a changed binary refuses" 3 "$(rc_of python3 -I "$LOCK" check "$W/tools.lock")"
printf 'binary v1\n' > "$W/bin/claude"; printf 'wrapper v2\n' > "$W/bin/s-qmd"
eq "lock: a changed wrapper refuses" 3 "$(rc_of python3 -I "$LOCK" check "$W/tools.lock")"
printf 'wrapper v1\n' > "$W/bin/s-qmd"; chmod u+w "$W/work/himmel/docs/zeta.md"; printf 'edited\n' >> "$W/work/himmel/docs/zeta.md"
eq "lock: a changed export file refuses" 3 "$(rc_of python3 -I "$LOCK" check "$W/tools.lock")"
eq "lock: a credential-named entry refuses at build" 3 "$(rc_of python3 -I "$LOCK" build --out "$W/bad.lock" --h0 "$H0" --l0 "$L0" --const openrouter_key=abc)"
git -C "$H" archive "$H0" docs/zeta.md | tar -x -O > "$W/work/himmel/docs/zeta.md"

QMD="${PILOT_QMD:-$(command -v qmd || true)}"
if [ -z "$QMD" ] || ! command -v bwrap >/dev/null 2>&1 || ! bwrap --bind / / --unshare-net true 2>/dev/null; then
  printf 'SKIP - real-qmd rows: qmd or an unprivileged bwrap network namespace is absent on this host\n'
else
  NETNS="$FX/netns-run.sh"
  QPKG="$(cd "$(dirname "$(readlink -f "$QMD")")/.." && pwd)"  # gnu-ok: Linux-only suite (bwrap namespaces)
  VEC0="$QPKG/node_modules/sqlite-vec-linux-x64/vec0.so"
  printf '# Changed\nversion two\n' > "$H/docs/changed.md"
  printf '# Postpin\nwritten after the pin\n' > "$H/docs/postpin.md"
  mkdir -p "$W/station-cfg" "$W/eval-cfg" "$W/cache"
  cat > "$W/station-cfg/eval.yml" <<EOF
global_context: station context
collections:
  himmel:
    path: $H
    pattern: "**/*.md"
    context:
      /: station himmel
  luna:
    path: $L
    pattern: "**/*.md"
models:
  embed: openai:stub-embed
  generate: openai:stub-gen
  rerank: openai:stub-rerank
  openai_base_url: http://127.0.0.1:18080/v1
EOF
  sed -e "s#@HIMMEL@#$W/work/himmel#" -e "s#@LUNA@#$W/work/luna#" "$FX/eval.yml.in" > "$W/eval-cfg/eval.yml"
  qrun() { # <config-dir> <index> <cache> <qmd args...> -- the pinned qmd in the stub namespace
    ( cd "$W" && bash "$NETNS" "$W" env -i HOME="$W" PATH="/usr/bin:/bin:$(dirname "$QMD")" QMD_CONFIG_DIR="$1" INDEX_PATH="$2" XDG_CACHE_HOME="$3" "$QMD" --index eval "${@:4}" )
  }
  qrun "$W/station-cfg" "$W/live.sqlite" "$W/cache" update >"$W/live.log" 2>&1
  qrun "$W/station-cfg" "$W/live.sqlite" "$W/cache" embed >>"$W/live.log" 2>&1
  eq "live: the station-config index built (himmel 5 incl. the pilot task file, luna 2)" 7 "$(sqlite3 "$W/live.sqlite" 'select count(*) from documents where active=1' 2>/dev/null)"

  eq "snapshot: backup of the live index" 0 "$(rc_of python3 -I "$PINS" snapshot "$W/live.sqlite" "$W/master.sqlite")"
  eq "prune: succeeds against both manifests" 0 "$(rc_of python3 -I "$PRUNE" "$W/master.sqlite" --vec0 "$VEC0" --export himmel="$W/himmel.manifest.json" --export luna="$W/luna.manifest.json")"
  python3 -I - "$W/master.sqlite" "$VEC0" > "$W/prune.out" <<'EOF'
import sqlite3, sys
c = sqlite3.connect(sys.argv[1]); c.enable_load_extension(True); c.load_extension(sys.argv[2][:-3])
paths = sorted(r[0] + "/" + r[1] for r in c.execute("select collection, path from documents"))
gone = ("himmel/docs/changed.md", "himmel/docs/postpin.md", "luna/handovers/h.md", "himmel/scripts/eval/retrieval-eval/pilot/tasks.md")
fts = sorted(r[0] for r in c.execute("select filepath from documents_fts"))
sync = sorted(r[0] + "/" + r[1] for r in c.execute("select collection, relative_path from file_sync_state"))
hashes = {r[0] for r in c.execute("select hash from documents")}
orphans = sum(1 for r in c.execute("select hash from content") if r[0] not in hashes)
cv = sum(1 for r in c.execute("select hash from content_vectors") if r[0] not in hashes)
vr = sum(1 for r in c.execute("select hash from vector_rows") if r[0] not in hashes)
ids = {r[0] for r in c.execute("select id from vector_rows")}
vec = sum(1 for r in c.execute("select rowid from vectors_by_collection") if r[0] not in ids)
bad = [g for g in gone if g in paths or g in fts or g in sync]
print("kept=%d bad=%s orphans=%d cv=%d vr=%d vec=%d" % (len(paths), bad, orphans, cv, vr, vec))
EOF
  eq "prune: changed, post-pin, pilot and handovers rows are gone from every table" "kept=3 bad=[] orphans=0 cv=0 vr=0 vec=0" "$(cat "$W/prune.out")"

  python3 -I -c 'import sqlite3,sys; c=sqlite3.connect(sys.argv[1]); [c.execute("DROP TRIGGER "+t) for t in ("documents_ai","documents_ad","documents_au")]; c.execute("PRAGMA user_version=0"); c.commit()' "$W/master.sqlite"
  cp "$W/master.sqlite" "$W/unfinal.sqlite"
  d_old=$(python3 -I "$PINS" digest "$W/unfinal.sqlite")
  qrun "$W/eval-cfg" "$W/unfinal.sqlite" "$W/cache" status >/dev/null 2>&1
  ne "finalize: an unfinalized eval open of the older-schema station index changes its digest" "$d_old" "$(python3 -I "$PINS" digest "$W/unfinal.sqlite")"

  printf 'collections: {}\nmodels:\n  embed: openai:a\n  generate: openai:b\n  rerank: openai:c\n  openai_api_key: ""\n' > "$W/keycfg.yml"
  mkdir -p "$W/key-cfg"; cp "$W/keycfg.yml" "$W/key-cfg/eval.yml"; cp "$W/master.sqlite" "$W/keyed.sqlite"
  eq "seal: an openai_api_key field refuses even when empty" 3 "$(rc_of python3 -I "$PINS" finalize "$W/keyed.sqlite" --qmd "$QMD" --config-dir "$W/key-cfg" --seal "$W/keyed.seal.json")"

  fin=(finalize "$W/master.sqlite" --qmd "$QMD" --config-dir "$W/eval-cfg" --expect-collection himmel="$W/work/himmel" --expect-collection luna="$W/work/luna" --seal "$W/master.seal.json")
  eq "finalize: opens, verifies the sync hash and scope, clears the cache and seals" 0 "$(rc_of python3 -I "$PINS" "${fin[@]}")"
  D=$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["digest"])' "$W/master.seal.json")
  eq "finalize: the triggers and schema version are migrated back" "3 2" "$(sqlite3 "$W/master.sqlite" "select count(*) from sqlite_master where type='trigger'; pragma user_version" | tr '\n' ' ' | sed 's/ $//')"
  eq "finalize: llm_cache is empty in the sealed master" 0 "$(sqlite3 "$W/master.sqlite" 'select count(*) from llm_cache')"
  eq "seal: the master file is read-only" "no" "$([ -w "$W/master.sqlite" ] && echo yes || echo no)"
  eq "seal: digest, config hash and file checksum are retained" "ok" "$(python3 -I -c 'import json,sys; s=json.load(open(sys.argv[1])); print("ok" if all(s.get(k) for k in ("digest","config_hash","file_sha256","digest_schema")) else s)' "$W/master.seal.json")"

  for i in 1 2; do
    python3 -I "$PINS" disposable "$W/master.sqlite" "$W/open$i.sqlite" --seal "$W/master.seal.json" >/dev/null 2>&1
    qrun "$W/eval-cfg" "$W/open$i.sqlite" "$W/cache" status >/dev/null 2>&1
  done
  eq "finalize: repeated opens of finalized copies keep the digest" "$D $D" "$(python3 -I "$PINS" digest "$W/open1.sqlite") $(python3 -I "$PINS" digest "$W/open2.sqlite")"
  python3 -I "$PINS" disposable "$W/master.sqlite" "$W/q1.sqlite" --seal "$W/master.seal.json" >/dev/null 2>&1
  python3 -I "$PINS" disposable "$W/master.sqlite" "$W/q2.sqlite" --seal "$W/master.seal.json" >/dev/null 2>&1
  for i in 1 2; do
    mkdir -p "$W/qcache$i"
    ( cd "$W" && bash "$NETNS" "$W" env -i HOME="$W" PATH="/usr/bin:/bin:$(dirname "$QMD")" QMD_CONFIG_DIR="$W/eval-cfg" INDEX_PATH="$W/q$i.sqlite" XDG_CACHE_HOME="$W/qcache$i" QMD_OPENAI_API_KEY="dummy-key-$i" "$QMD" --index eval query --json -n 5 "queue lock session" >"$W/q$i.json" 2>"$W/q$i.err" )
  done
  eq "hybrid: the real local-stub hybrid query returns the lock note" "qmd://himmel/docs/lock.md" "$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))[0]["file"].split("?")[0])' "$W/q1.json" 2>/dev/null)"
  ne "hybrid: the query wrote expansion/rerank cache rows" 0 "$(sqlite3 "$W/q1.sqlite" 'select count(*) from llm_cache')"
  eq "hybrid: the corpus digest survives the cache writes" "$D" "$(python3 -I "$PINS" digest "$W/q1.sqlite")"
  eq "keys: two different dummy keys leave corpus and config identity equal" "$D $D same" "$(python3 -I "$PINS" digest "$W/q1.sqlite") $(python3 -I "$PINS" digest "$W/q2.sqlite") $([ "$(sqlite3 "$W/q1.sqlite" "select value from store_config where key='config_hash'")" = "$(sqlite3 "$W/q2.sqlite" "select value from store_config where key='config_hash'")" ] && echo same || echo differ)"
  eq "hybrid: the sealed master itself is untouched" 0 "$(rc_of python3 -I "$PINS" verify "$W/master.sqlite" --seal "$W/master.seal.json")"

  mut() { # <label> <expect: same|differ> <sql>
    python3 -I "$PINS" disposable "$W/master.sqlite" "$W/m.sqlite" --seal "$W/master.seal.json" >/dev/null 2>&1
    python3 -I - "$W/m.sqlite" "$VEC0" "$3" <<'EOF'
import sqlite3, sys
c = sqlite3.connect(sys.argv[1]); c.enable_load_extension(True); c.load_extension(sys.argv[2][:-3])
c.execute("PRAGMA journal_mode=WAL"); c.execute("PRAGMA wal_autocheckpoint=0")
c.executescript(sys.argv[3]); c.commit()
EOF
    local d; d=$(python3 -I "$PINS" digest "$W/m.sqlite")
    if [ "$2" = same ]; then eq "digest: $1 keeps it" "$D" "$d"; else ne "digest: $1 changes it" "$D" "$d"; fi
    rm -f "$W/m.sqlite" "$W/m.sqlite-wal" "$W/m.sqlite-shm"
  }
  mut "a cache-only insert left in the WAL" same "insert into llm_cache values ('h','r','2026-01-01')"
  mut "a documents row edit" differ "update documents set title='Other' where path='docs/lock.md'"
  mut "a content edit" differ "update content set doc=doc||'x' where hash=(select hash from documents where path='docs/lock.md')"
  mut "a vector chunk edit" differ "update vectors_by_collection_vector_chunks00 set vectors=zeroblob(length(vectors))"
  mut "an FTS row insert" differ "insert into documents_fts(rowid, filepath, title, body) values (999, 'x/y.md', 'y', 'planted words')"
  python3 -I "$PINS" disposable "$W/master.sqlite" "$W/u.sqlite" --seal "$W/master.seal.json" >/dev/null 2>&1
  sqlite3 "$W/u.sqlite" 'create table surprise(x)'
  eq "digest: an unrecognized table refuses" 3 "$(rc_of python3 -I "$PINS" digest "$W/u.sqlite")"

  printf '# Late\na note added to the live tree later\n' > "$H/docs/late.md"
  qrun "$W/station-cfg" "$W/live.sqlite" "$W/cache" update >/dev/null 2>&1
  eq "drift: the live index grew" 8 "$(sqlite3 "$W/live.sqlite" 'select count(*) from documents where active=1')"
  eq "drift: live-index count drift does not touch the sealed master" 0 "$(rc_of python3 -I "$PINS" verify "$W/master.sqlite" --seal "$W/master.seal.json")"
fi

if [ "$fails" -gt 0 ]; then printf '%d failure(s)\n' "$fails"; exit 1; fi
printf 'all pins rows passed\n'
