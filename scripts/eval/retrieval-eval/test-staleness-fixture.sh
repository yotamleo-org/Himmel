#!/usr/bin/env bash
# shellcheck disable=SC2015  # `A && pass || fail` is the assert idiom: pass always returns 0
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(git -C "$HERE" rev-parse --show-toplevel)"
FX="$HERE/staleness-fixture.sh"
BANK="$HERE/staleness-questions.jsonl"
GBANK="$HERE/staleness-graph-questions.jsonl"
HELPER="$REPO_ROOT/scripts/lib/qmd-collection-files.py"

BANK_SHA256="95227657c03ef328ccafa858426b69e7eec4893f366a380c47a017e8116dfd1e"
GBANK_SHA256="577afc8a4c68e976c649a9110e7043a4535d04d5ea5c4dc9224cc5b23a073c33"

W="$(mktemp -d "${TMPDIR:-/tmp}/staleness-fixture-test.XXXXXX")" || exit 1
trap 'for p in "$W"/*/serve.pid; do [ -f "$p" ] && kill "$(cat "$p")" 2>/dev/null; done; rm -rf "$W"' EXIT
fails=0
pass() { printf 'ok - %s\n' "$1"; }
fail() { printf 'FAIL - %s\n' "$1"; fails=$((fails + 1)); }
eq() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (expected '$2', got '$3')"; fi; }
py() { python3 -I "$@"; }
sha() { py -c 'import hashlib, sys; print(hashlib.sha256(open(sys.argv[1], "rb").read()).hexdigest())' "$1"; }

LOGDIR="$W/logs"
mkdir -p "$LOGDIR" "$W/home/.cache/qmd" "$W/tmp" "$W/bin" "$W/gbin" "$W/primary/graphify-out"
printf 'LIVE\n' > "$W/home/.cache/qmd/index.sqlite"
printf 'PRIMARY\n' > "$W/primary/graphify-out/graph.json"

cat > "$W/bin/qmd" <<'STUB'
#!/usr/bin/env bash
key=unset; [ -n "${QMD_OPENAI_API_KEY:-}" ] && key=set
printf '%s | INDEX_PATH=%s QMD_CONFIG_DIR=%s KEY=%s\n' "$*" "${INDEX_PATH:-}" "${QMD_CONFIG_DIR:-}" "$key" >> "$LOGDIR/qmd.log"
case "$1" in
update) mkdir -p "$(dirname "$INDEX_PATH")"; date +%s%N >> "$INDEX_PATH" ;;
mcp)
    port=""; while [ $# -gt 0 ]; do [ "$1" = "--port" ] && port="$2"; shift; done
    exec python3 -I -c 'import socket, sys, time
s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", int(sys.argv[1]))); s.listen(5); time.sleep(300)' "$port" mcp --http --port "$port" ;;
esac
exit 0
STUB
chmod +x "$W/bin/qmd"

cat > "$W/gbin/graphify" <<'STUB'
#!/usr/bin/env bash
printf '%s | GRAPHIFY_OUT=%s\n' "$*" "${GRAPHIFY_OUT-unset}" >> "$LOGDIR/graphify.log"
mkdir -p "$2/graphify-out" && : > "$2/graphify-out/.graphify_root"
exit 0
STUB
chmod +x "$W/gbin/graphify"

R="$W/repo"
git init -q -b main "$R"
gc() { git -C "$R" -c user.name=t -c user.email=t@t -c commit.gpgsign=false commit -q --no-verify -m "$1"; }
mkdir -p "$R/docs" "$R/fixtures" "$R/node_modules" "$R/tools"
printf '# Readme\nalpha stays\n' > "$R/README.md"
printf '# A doc\nold line\n' > "$R/docs/a.md"
printf '# B doc\nkept line\n' > "$R/docs/b.md"
printf '# X\n' > "$R/fixtures/x.md"
printf '# M\n' > "$R/node_modules/m.md"
printf 'print(1)\n' > "$R/tools/a.py"
git -C "$R" add -A && gc one
C1="$(git -C "$R" rev-parse HEAD)"
printf '# A doc\nold line\nfresh added line\n' > "$R/docs/a.md"
printf '# B doc\nkept line\nextra tail\n' > "$R/docs/b.md"
printf '# New doc\nbrand new text\n' > "$R/docs/new.md"
printf 'print(2)\n' > "$R/tools/a.py"
printf 'print(3)\n' > "$R/tools/b.py"
git -C "$R" add -A && gc two
C2="$(git -C "$R" rev-parse HEAD)"

FX_EXTRA=()
fx() {
    env -u INDEX_PATH -u QMD_CONFIG_DIR -u GRAPHIFY_OUT -u HIMMEL_BILLED_OK -u QMD_OPENAI_API_KEY -u XDG_CACHE_HOME -u XDG_CONFIG_HOME \
        HOME="$W/home" PATH="$W/gbin:$W/bin:$PATH" TMPDIR="$W/tmp" LOGDIR="$LOGDIR" \
        SF_QMD="$W/bin/qmd" SF_REPO="$R" SF_PRIMARY_GRAPH_OUT="$W/primary/graphify-out" ${FX_EXTRA[@]+"${FX_EXTRA[@]}"} \
        bash "$FX" "$@"
}
qlog() { cat "$LOGDIR/qmd.log" 2>/dev/null; }
reset_logs() { rm -f "$LOGDIR"/*.log; }
manifest() {
    local root="$1" skip a=()
    shift
    for skip in "$@"; do a+=(-path "$skip" -prune -o); done
    find "$root" ${a[@]+"${a[@]}"} -print 2>/dev/null | sort | while IFS= read -r p; do
        if [ -f "$p" ]; then printf '%s %s\n' "$p" "$(cksum < "$p")"; else printf '%s\n' "$p"; fi
    done
}
pj() { py -c 'import json, os, sys
v = json.load(open(sys.argv[1])) if os.path.exists(sys.argv[1]) else None
for k in sys.argv[2].split("."): v = v.get(k) if isinstance(v, dict) else None
print("" if v is None else v)' "$1/pair.json" "$2"; }


reset_logs
out="$(fx build --first "$C1" --second "$C2" --state s --out "$W/home/.cache/qmd" 2>&1)"; rc=$?
eq "::refuses_live_index (exit 2)" "2" "$rc"
eq "::refuses_live_index (the live index keeps its bytes)" "LIVE" "$(cat "$W/home/.cache/qmd/index.sqlite")"
eq "::refuses_live_index (no qmd call)" "" "$(qlog)"

reset_logs
ln -s "$W/home/.cache/qmd" "$W/link-to-live"
fx build --first "$C1" --second "$C2" --state s --out "$W/link-to-live" > /dev/null 2>&1; rc=$?
eq "::refuses_live_index_by_symlink (out is a link to the live dir: exit 2)" "2" "$rc"
mkdir -p "$W/o-sym"; : > "$W/o-sym/.staleness-fixture"
ln -s "$W/home/.cache/qmd/index.sqlite" "$W/o-sym/index.sqlite"
fx build --first "$C1" --second "$C2" --state s --out "$W/o-sym" > /dev/null 2>&1; rc=$?
eq "::refuses_live_index_by_symlink (the index file is a link to the live file: exit 2)" "2" "$rc"
fx serve --index "$W/o-sym/index.sqlite" > /dev/null 2>&1; rc=$?
eq "::refuses_live_index_by_symlink (serve on that link: exit 2)" "2" "$rc"
eq "::refuses_live_index_by_symlink (the live index keeps its bytes, no qmd call)" "LIVE|" "$(cat "$W/home/.cache/qmd/index.sqlite")|$(qlog)"


reset_logs
OUT="$W/scratch-l"
before="$(manifest "$W" "$OUT" "$LOGDIR")"
fx build --first "$C1" --second "$C2" --state l --out "$OUT" > /dev/null 2>&1; rc=$?
after="$(manifest "$W" "$OUT" "$LOGDIR")"
eq "::writes_only_under_scratch (build exits 0)" "0" "$rc"
eq "::writes_only_under_scratch (nothing outside the scratch path changed: live index, repo, HOME, TMPDIR)" "$before" "$after"
[ -f "$OUT/index.sqlite" ] && [ -f "$OUT/pair.json" ] && pass "::writes_only_under_scratch (the index and pair.json are in the scratch path)" \
    || fail "::writes_only_under_scratch (the index and pair.json are in the scratch path)"
eq "::writes_only_under_scratch (every qmd call used the scratch index and config)" "0" \
    "$(qlog | grep -c -v "INDEX_PATH=$OUT/index.sqlite QMD_CONFIG_DIR=$OUT/config ")"
mkdir -p "$W/not-empty"; : > "$W/not-empty/keep.txt"
fx build --first "$C1" --second "$C2" --state s --out "$W/not-empty" > /dev/null 2>&1; rc=$?
eq "::writes_only_under_scratch (a non-empty directory this script did not make is refused)" "2" "$rc"


reset_logs
FX_EXTRA=()
fx build --first "$C1" --second "$C2" --state s --out "$W/free-s" > /dev/null 2>&1; rc=$?
eq "::no_embed_without_opt_in (a free build exits 0)" "0" "$rc"
eq "::no_embed_without_opt_in (the stub saw update and never embed)" "1|0" "$(qlog | grep -c '^update ')|$(qlog | grep -c '^embed')"

reset_logs
FX_EXTRA=(HIMMEL_BILLED_OK=1)
fx build --first "$C1" --second "$C2" --state s --out "$W/free-s2" > /dev/null 2>&1
fx build --first "$C1" --second "$C2" --state l --out "$W/free-l2" > /dev/null 2>&1
eq "::free_arm_never_embeds (states s and l, with the opt-in set but no --embed-ok)" "0" "$(qlog | grep -c '^embed')"
fx build --first "$C1" --second "$C2" --state c --out "$W/free-c" > /dev/null 2>&1; rc=$?
eq "::free_arm_never_embeds (state c without --embed-ok is refused: exit 2)" "2" "$rc"
FX_EXTRA=()

reset_logs
out="$(fx build --first "$C1" --second "$C2" --state s --out "$W/paid-no" --embed-ok 100 2>&1)"; rc=$?
eq "::embed_ok_refuses_without_billed_ok (exit 2)" "2" "$rc"
case "$out" in *HIMMEL_BILLED_OK*) pass "::embed_ok_refuses_without_billed_ok (the refusal names HIMMEL_BILLED_OK)" ;; *) fail "::embed_ok_refuses_without_billed_ok (the refusal names HIMMEL_BILLED_OK): $out" ;; esac
eq "::embed_ok_refuses_without_billed_ok (no qmd call at all: no embed, no key load)" "" "$(qlog)"
FX_EXTRA=(HIMMEL_BILLED_OK=0)
fx build --first "$C1" --second "$C2" --state s --out "$W/paid-zero" --embed-ok 100 > /dev/null 2>&1; rc=$?
eq "::embed_ok_refuses_without_billed_ok (HIMMEL_BILLED_OK=0 is not the opt-in)" "2" "$rc"
FX_EXTRA=(HIMMEL_BILLED_OK=1)
fx build --first "$C1" --second "$C2" --state s --out "$W/paid-yes" --embed-ok 100 > /dev/null 2>&1; rc=$?
eq "::embed_ok_refuses_without_billed_ok (control: with the opt-in the stub sees one embed)" "0|1" "$rc|$(qlog | grep -c '^embed')"
fx build --first "$C1" --second "$C2" --state s --out "$W/paid-cap" --embed-ok 2 > /dev/null 2>&1; rc=$?
eq "::embed_ok_refuses_without_billed_ok (control: more documents than the cap is refused: exit 2)" "2" "$rc"
reset_logs
fx build --first "$C1" --second "$C2" --state c --out "$W/paid-c5" --embed-ok 5 > /dev/null 2>&1; rc=$?
eq "::embed_cap_covers_second_tree (6 documents to embed against a cap of 5: exit 2, no embed)" "2|0" "$rc|$(qlog | grep -c '^embed')"
reset_logs
fx build --first "$C1" --second "$C2" --state c --out "$W/paid-c6" --embed-ok 6 > /dev/null 2>&1; rc=$?
eq "::embed_cap_covers_second_tree (control: a cap of 6 runs both embeds)" "0|2" "$rc|$(qlog | grep -c '^embed')"
FX_EXTRA=()

reset_logs
fx serve --index "$W/free-s/index.sqlite" --with-key > /dev/null 2>&1; rc=$?
eq "::keyed_serve_refuses_without_billed_ok (exit 2)" "2" "$rc"
eq "::keyed_serve_refuses_without_billed_ok (no daemon, no key load)" "0" "$(qlog | grep -c '^mcp')"
KEYF="$W/daemon.env"; printf 'QMD_OPENAI_API_KEY=sentinel-key\n' > "$KEYF"; chmod 600 "$KEYF"
FX_EXTRA=(HIMMEL_BILLED_OK=1 "QMD_DAEMON_ENV_FILE=$KEYF")
fx serve --index "$W/free-s/index.sqlite" --with-key > /dev/null 2>&1; rc=$?
eq "::keyed_serve_refuses_without_billed_ok (control: with the opt-in the daemon gets the key)" "0|1" "$rc|$(qlog | grep -c '^mcp.*KEY=set')"
FX_EXTRA=()
fx stop --index "$W/free-s/index.sqlite" > /dev/null 2>&1


reset_logs
FX_EXTRA=(QMD_OPENAI_API_KEY=sentinel-key OPENAI_API_KEY=sentinel-key)
url="$(fx serve --index "$W/free-l2/index.sqlite" 2>/dev/null)"; rc=$?
FX_EXTRA=()
eq "::free_serve_has_no_key (exit 0)" "0" "$rc"
eq "::free_serve_has_no_key (the daemon saw no key and the scratch index and config)" "1" \
    "$(qlog | grep -c "^mcp --http --port [0-9]* | INDEX_PATH=$W/free-l2/index.sqlite QMD_CONFIG_DIR=$W/free-l2/config KEY=unset")"
eq "::free_serve_has_no_key (pair.json holds the served URL)" "$url" "$(pj "$W/free-l2" served_url)"
case "$url" in http://127.0.0.1:*/mcp) pass "::free_serve_has_no_key (the URL is a free local port)" ;; *) fail "::free_serve_has_no_key (the URL is a free local port): '$url'" ;; esac
spid="$(cat "$W/free-l2/serve.pid")"
fx stop --index "$W/free-l2/index.sqlite" > /dev/null 2>&1
eq "::free_serve_has_no_key (stop clears the URL and the pid file)" "|gone" "$(pj "$W/free-l2" served_url)|$([ -e "$W/free-l2/serve.pid" ] && echo left || echo gone)"
if kill -0 "$spid" 2> /dev/null; then sleft=running; else sleft=exited; fi
eq "::free_serve_has_no_key (stop ends the daemon process)" "exited" "$sleft"

other_port="$(py -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')"
LOGDIR="$LOGDIR" "$W/bin/qmd" mcp --http --port "$other_port" > /dev/null 2>&1 &
other_d=$!
sleep 1
printf '%s\n' "$other_d" > "$W/free-s/serve.pid"
printf '%s\n' "$((other_port + 1))" > "$W/free-s/serve.port"
fx stop --index "$W/free-s/index.sqlite" > /dev/null 2>&1
if kill -0 "$other_d" 2> /dev/null; then alive=alive; else alive=dead; fi
kill "$other_d" 2> /dev/null
eq "::stop_ignores_other_daemon (a daemon on another port keeps running, the pid and port files go)" "alive|gone" \
    "$alive|$([ -e "$W/free-s/serve.pid" ] || [ -e "$W/free-s/serve.port" ] && echo left || echo gone)"

sleep 60 &
other=$!
printf '%s\n' "$other" > "$W/free-s/serve.pid"
fx stop --index "$W/free-s/index.sqlite" > /dev/null 2>&1
if kill -0 "$other" 2> /dev/null; then alive=alive; else alive=dead; fi
kill "$other" 2> /dev/null
eq "::stop_ignores_reused_pid (an unrelated process keeps running, the pid file goes)" "alive|gone" "$alive|$([ -e "$W/free-s/serve.pid" ] && echo left || echo gone)"

reset_logs
before="$(cksum < "$W/free-s/index.sqlite")"
fx build --first "$C1" --second "$C2" --state s --out "$W/free-s" > /dev/null 2>&1; rc=$?
eq "::build_refuses_existing_index (exit 2, the index keeps its bytes, no qmd call)" "2|$before|" "$rc|$(cksum < "$W/free-s/index.sqlite")|$(qlog)"

mkdir -p "$W/o-cfg" "$W/outside-cfg"
: > "$W/o-cfg/.staleness-fixture"
ln -s "$W/outside-cfg" "$W/o-cfg/config"
fx build --first "$C1" --second "$C2" --state s --out "$W/o-cfg" > /dev/null 2>&1; rc=$?
eq "::refuses_linked_config (exit 2, nothing written through the link)" "2|0" "$rc|$(find "$W/outside-cfg" -mindepth 1 | wc -l | tr -d ' ')"

eq "::pair_records_commits (first, second, state)" "$C1 $C2 l" "$(pj "$OUT" first) $(pj "$OUT" second) $(pj "$OUT" state)"
helper_doc_count() {
    git -C "$R" ls-tree -r --name-only "$1" | tr '\n' '\0' | xargs -0 python3 -I "$HELPER" --config "$2" himmel | wc -l | tr -d ' '
}
eq "::doc_count_matches_helper (state l: the second tree, 4 files)" "4|4" "$(pj "$OUT" doc_count)|$(helper_doc_count "$C2" "$OUT/config/index.yml")"
eq "::doc_count_matches_helper (state s: the first tree, 3 files)" "3|3" "$(pj "$W/free-s" doc_count)|$(helper_doc_count "$C1" "$W/free-s/config/index.yml")"


S12="$(printf '%s' "$C2" | cut -c1-12)"
reset_logs
fx graph --commit "$C2" --out "$W/primary/graphify-out" > /dev/null 2>&1; rc=$?
eq "::graph_build_refuses_primary_out (out is the primary graph dir: exit 2)" "2" "$rc"
ln -s "$W/primary/graphify-out" "$W/link-to-primary"
fx graph --commit "$C2" --out "$W/link-to-primary" > /dev/null 2>&1; rc=$?
eq "::graph_build_refuses_primary_out (out is a link to it: exit 2)" "2" "$rc"
mkdir -p "$W/o-g"; : > "$W/o-g/.staleness-fixture"; ln -s "$W/primary/graphify-out" "$W/o-g/graph-$S12"
fx graph --commit "$C2" --out "$W/o-g" > /dev/null 2>&1; rc=$?
eq "::graph_build_refuses_primary_out (the archive path is a link to it: exit 2)" "2" "$rc"
eq "::graph_build_refuses_primary_out (the primary keeps its bytes, graphify never ran)" "PRIMARY|0" "$(cat "$W/primary/graphify-out/graph.json")|$(cat "$LOGDIR/graphify.log" 2>/dev/null | wc -l | tr -d ' ')"

reset_logs
mkdir -p "$W/seed/sub"; printf 'a\n' > "$W/seed/a.json"; printf 'b\n' > "$W/seed/sub/b.json"
GOUT="$W/scratch-g"
before="$(manifest "$W" "$GOUT" "$LOGDIR" "$W/seed")"
seed_before="$(manifest "$W/seed")"
FX_EXTRA=("GRAPHIFY_OUT=$W/cache-only-override")
fx graph --commit "$C2" --out "$GOUT" --seed-cache "$W/seed" > /dev/null 2>&1; rc=$?
FX_EXTRA=()
after="$(manifest "$W" "$GOUT" "$LOGDIR" "$W/seed")"
eq "::graph_build_writes_only_under_scratch (exit 0)" "0" "$rc"
eq "::graph_build_writes_only_under_scratch (nothing outside the scratch path changed)" "$before" "$after"
ARC="$GOUT/graph-$S12"
eq "::graph_build_seeds_cache_copy (the cache is a copy in the archive's own graphify-out)" "a|b|0" \
    "$(cat "$ARC/graphify-out/cache/a.json" 2>/dev/null | tr -d '\n')|$(cat "$ARC/graphify-out/cache/sub/b.json" 2>/dev/null | tr -d '\n')|$([ -L "$ARC/graphify-out/cache" ] && echo 1 || echo 0)"
eq "::graph_build_seeds_cache_copy (the seed is untouched)" "$seed_before" "$(manifest "$W/seed")"
eq "::graph_build_seeds_cache_copy (the archive is the commit's tree)" "print(3)" "$(tr -d '\n' < "$ARC/tools/b.py")"
eq "::pair_records_graph_built_at (the commit and its archive)" "$ARC" "$(pj "$GOUT" "graph_built_at.$C2")"

eq "::graph_build_real_ast_update_accepts_seeded_out (the stub graphify ran update <archive> --force)" "update $ARC --force | GRAPHIFY_OUT=unset" \
    "$(cat "$LOGDIR/graphify.log" 2>/dev/null | head -1)"
mkdir -p "$W/cache-only/graphify-out-x/cache"; printf 'a\n' > "$W/cache-only/graphify-out-x/cache/a.json"
GRAPHIFY_OUT="$W/cache-only/graphify-out-x" PATH="$W/gbin:$PATH" LOGDIR="$LOGDIR" bash "$REPO_ROOT/scripts/graphify/ast-update.sh" "$W/cache-only" > /dev/null 2>&1; rc=$?
eq "::graph_build_real_ast_update_accepts_seeded_out (control: a cache-only GRAPHIFY_OUT override exits 3)" "3" "$rc"


cat > "$W/check-banks.py" <<'PY'
import json, subprocess, sys

repo = sys.argv[1]


def git(*a):
    r = subprocess.run(["git", "-C", repo] + list(a), capture_output=True)
    return r.returncode, r.stdout


def have(sha):
    return git("cat-file", "-e", sha + "^{commit}")[0] == 0


def blob(sha, path):
    rc, out = git("cat-file", "blob", sha + ":" + path)
    return out.decode("utf-8", "replace") if rc == 0 else None


bad, skipped = [], 0
for bank in sys.argv[2:]:
    for line in open(bank):
        if not line.strip():
            continue
        r = json.loads(line)
        p = r["pair"]
        if not (have(p["first"]) and have(p["second"])):
            skipped += 1
            continue
        ev = r.get("evidence")
        st = r["stale_stratum"]
        for g in r["gold"]:
            t1, t2 = blob(p["first"], g), blob(p["second"], g)
            tag = "%s %s %s" % (r["id"], st, g)
            if st == "new":
                if t1 is not None or t2 is None:
                    bad.append(tag + ": a new file must be absent at the first sha and present at the second")
            elif st in ("added", "kept", "changed"):
                if t1 is None or t2 is None or t1 == t2:
                    bad.append(tag + ": must exist at both commits and differ")
                elif st != "changed" and not ev:
                    bad.append(tag + ": no evidence phrase")
                elif st == "added" and (ev not in t2 or ev in t1):
                    bad.append(tag + ": the evidence must be new text in the second version")
                elif st == "kept" and (ev not in t1 or ev not in t2):
                    bad.append(tag + ": the evidence must be in both versions")
            elif st == "control":
                if t1 is None or t1 != t2:
                    bad.append(tag + ": must be untouched between the commits")
            else:
                bad.append(tag + ": unknown stratum")
for b in bad:
    print(b)
print("skipped-rows=%d" % skipped, file=sys.stderr)
sys.exit(1 if bad else 0)
PY

bank_ok() { [ -f "$1" ]; }

if bank_ok "$BANK"; then eq "::bank_hash_frozen" "$BANK_SHA256" "$(sha "$BANK")"; else fail "::bank_hash_frozen (staleness-questions.jsonl is missing)"; fi
if bank_ok "$GBANK"; then eq "::graph_bank_hash_frozen" "$GBANK_SHA256" "$(sha "$GBANK")"; else fail "::graph_bank_hash_frozen (staleness-graph-questions.jsonl is missing)"; fi

counts() { py -c 'import collections, json, sys
c = collections.Counter(json.loads(l)["stale_stratum"] for l in open(sys.argv[1]) if l.strip())
print(" ".join("%s=%d" % (k, c[k]) for k in sys.argv[2:]), "total=%d" % sum(c.values()))' "$@"; }
if bank_ok "$BANK"; then eq "::strata_counts (20, 20, 15, 5)" "added=20 kept=20 new=15 control=5 total=60" "$(counts "$BANK" added kept new control)"; else fail "::strata_counts (bank missing)"; fi
if bank_ok "$GBANK"; then eq "::graph_strata_counts (15, 15)" "changed=15 new=15 total=30" "$(counts "$GBANK" changed new)"; else fail "::graph_strata_counts (bank missing)"; fi

if bank_ok "$BANK" && bank_ok "$GBANK"; then
    py - "$BANK" "$GBANK" <<'PY'
import json, re, sys
bad = []
for bank in sys.argv[1:]:
    for line in open(bank):
        if not line.strip():
            continue
        r = json.loads(line)
        if not r.get("gold"):
            bad.append("%s: no gold" % r.get("id"))
        for g in r.get("gold", []):
            if g.startswith(("/", "~", "handovers/", "60-Maps/")) or ".." in g.split("/"):
                bad.append("%s: %s is not a repo path" % (r["id"], g))
for b in bad:
    print(b)
sys.exit(1 if bad else 0)
PY
    rc=$?
    eq "::no_luna_paths (every gold is a relative repo path)" "0" "$rc"
    gold_unresolved="$(py - "$R" "$REPO_ROOT" "$BANK" "$GBANK" <<'PY'
import json, subprocess, sys
repo, banks = sys.argv[2], sys.argv[3:]
n = missing = 0
for bank in banks:
    for line in open(bank):
        if not line.strip():
            continue
        r = json.loads(line)
        sha = r["pair"]["second"]
        if subprocess.run(["git", "-C", repo, "cat-file", "-e", sha + "^{commit}"], capture_output=True).returncode:
            continue
        tree = set(subprocess.run(["git", "-C", repo, "ls-tree", "-r", "--name-only", sha], capture_output=True, text=True).stdout.split("\n"))
        for g in r["gold"]:
            n += 1
            if g not in tree:
                missing += 1
print(missing)
PY
)"
    eq "::no_luna_paths (every gold resolves in git ls-tree of a himmel commit, where this checkout holds the commit)" "0" "$gold_unresolved"
else
    fail "::no_luna_paths (a bank is missing)"
fi

if bank_ok "$BANK" && bank_ok "$GBANK"; then
    out="$(py "$W/check-banks.py" "$REPO_ROOT" "$BANK" "$GBANK" 2>"$W/skip.txt")"; rc=$?
    eq "::strata_hold_on_git (the real banks on this repo's history $(cat "$W/skip.txt"))" "0" "$rc"
    [ -z "$out" ] || printf '%s\n' "$out"
else
    fail "::strata_hold_on_git (a bank is missing)"
fi
py -c 'import json, sys
c1, c2 = sys.argv[1:3]
p = {"first": c1, "second": c2}
rows = [
    {"id": "f1", "stale_stratum": "added", "gold": ["docs/a.md"], "evidence": "fresh added line", "pair": p},
    {"id": "f2", "stale_stratum": "kept", "gold": ["docs/b.md"], "evidence": "kept line", "pair": p},
    {"id": "f3", "stale_stratum": "new", "gold": ["docs/new.md"], "pair": p},
    {"id": "f4", "stale_stratum": "control", "gold": ["README.md"], "pair": p},
    {"id": "f5", "stale_stratum": "changed", "gold": ["tools/a.py"], "pair": p},
]
open(sys.argv[3], "w").write("\n".join(json.dumps(r) for r in rows) + "\n")
bad = [dict(r) for r in rows]
bad[0]["evidence"] = "old line"
bad[1]["evidence"] = "no such text"
bad[2]["gold"] = ["README.md"]
bad[3]["gold"] = ["docs/a.md"]
bad[4]["gold"] = ["tools/b.py"]
open(sys.argv[4], "w").write("\n".join(json.dumps(r) for r in bad) + "\n")' "$C1" "$C2" "$W/planted-good.jsonl" "$W/planted-bad.jsonl"
py "$W/check-banks.py" "$R" "$W/planted-good.jsonl" > /dev/null 2>&1; rc=$?
eq "::strata_hold_on_git (a planted bank that follows the rules passes on a fixture repo)" "0" "$rc"
bad_n="$(py "$W/check-banks.py" "$R" "$W/planted-bad.jsonl" 2>/dev/null | wc -l | tr -d ' ')"
eq "::strata_hold_on_git (a planted bank that breaks each rule gets one violation a row)" "5" "$bad_n"

if [ "$fails" -eq 0 ]; then printf 'all staleness-fixture rows passed\n'; else printf '%s row(s) failed\n' "$fails"; exit 1; fi
