#!/usr/bin/env bash
# selector: tree-scan
# shellcheck disable=SC2015  # `A && pass || fail` is the assert idiom: pass always returns 0
set -uo pipefail
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(git -C "$HERE" rev-parse --show-toplevel)"
FX="$HERE/staleness-fixture.sh"
BANK="$HERE/staleness-questions.jsonl"
GBANK="$HERE/staleness-graph-questions.jsonl"
HELPER="$REPO_ROOT/scripts/lib/qmd-collection-files.py"

BANK_SHA256="41a69b7fea3edf5b44a441119ee2f36bd77eb124d6a9fe7afc074c322053678d"
GBANK_SHA256="99def8acd8dda6f40716a23eeb9c92790af02bd141227fdb9d31fdbd157e0fb9"

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
    exec python3 -I -c 'import os, socket, sys, time
port = int(sys.argv[1])
try:
    s = socket.socket(socket.AF_INET6); s.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 1)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1); s.bind(("::1", port)); fam = "v6"
except OSError:
    s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1); s.bind(("127.0.0.1", port)); fam = "v4"
open(os.environ["LOGDIR"] + "/bind-family", "w").write(fam)
s.listen(5); time.sleep(300)' "$port" mcp --http --port "$port" ;;
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
ln -s a.md "$R/docs/alias.md" || exit 1
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
    env -u INDEX_PATH -u QMD_CONFIG_DIR -u GRAPHIFY_OUT -u HIMMEL_BILLED_OK -u QMD_OPENAI_API_KEY -u XDG_CACHE_HOME -u XDG_CONFIG_HOME -u LUNA_VAULT_PATH \
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
R3="$W/repo3"; git init -q -b main "$R3" || exit 1
gc3() { git -C "$R3" -c user.name=t -c user.email=t@t -c commit.gpgsign=false commit -q --no-verify -m "$1"; }
printf '# X\n' > "$R3/x.md"; ln -s x.md "$R3/alias.md" || exit 1
git -C "$R3" add -A && gc3 one; D1="$(git -C "$R3" rev-parse HEAD)"
rm "$R3/alias.md" && printf '# Alias is a real file now\n' > "$R3/alias.md"
git -C "$R3" add -A && gc3 two; D2="$(git -C "$R3" rev-parse HEAD)"
FX_EXTRA=(HIMMEL_BILLED_OK=1 "SF_REPO=$R3")
reset_logs
fx build --first "$D1" --second "$D2" --state c --out "$W/paid-t1" --embed-ok 1 > /dev/null 2>&1; rc=$?
eq "::embed_cap_covers_type_change (a symlink replaced by a regular file counts: 2 documents against a cap of 1, exit 2, no embed)" "2|0" "$rc|$(qlog | grep -c '^embed')"
fx build --first "$D1" --second "$D2" --state c --out "$W/paid-t2" --embed-ok 2 > /dev/null 2>&1; rc=$?
eq "::embed_cap_covers_type_change (control: a cap of 2 runs)" "0" "$rc"
FX_EXTRA=(HIMMEL_BILLED_OK=1)
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
case "$url" in http://localhost:*/mcp) pass "::free_serve_has_no_key (the URL is a free local port)" ;; *) fail "::free_serve_has_no_key (the URL is a free local port): '$url'" ;; esac
fam="$(cat "$LOGDIR/bind-family" 2> /dev/null)"
if [ "$fam" = v6 ]; then pass "::serve_reaches_an_ipv6_only_server (the stub listens on ::1 only, as the real qmd does, and serve came up)"
else pass "SKIP ::serve_reaches_an_ipv6_only_server (this host has no IPv6 loopback, so the stub fell back to 127.0.0.1)"; fi
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
    git -C "$R" ls-tree -r "$1" | awk -F'\t' '$1 !~ /^120000/ {print $2}' | tr '\n' '\0' | xargs -0 python3 -I "$HELPER" --config "$2" himmel | wc -l | tr -d ' '
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


V="$W/vault"
git init -q -b main "$V" || exit 1
gv() { git -C "$V" -c user.name=t -c user.email=t@t -c commit.gpgsign=false commit -q --no-verify -m "$1"; }
mkdir -p "$V/notes" "$V/60-Maps/graph" "$V/graphify-out" "$V/handovers/h/verdicts/q/scratch" "$W/state"
printf '# Note A\nalpha\n' > "$V/notes/a.md"
printf '# Note B\nbravo\n' > "$V/notes/b.md"
printf '# Map\n' > "$V/60-Maps/graph/g.md"
printf '# Out\n' > "$V/graphify-out/o.md"
printf '# Scratch\n' > "$V/handovers/h/verdicts/q/scratch/s.md"
printf 'png\n' > "$V/pic.png"
git -C "$V" add -A && gv one; V1="$(git -C "$V" rev-parse HEAD)"
printf '# Note A\nalpha\nzulu added\n' > "$V/notes/a.md"
printf '# New\nnovel\n' > "$V/notes/new.md"
git -C "$V" add -A && gv two; V2="$(git -C "$V" rev-parse HEAD)"
printf 'WORKTREE ONLY\n' > "$V/notes/a.md"
printf '# Untracked\n' > "$V/notes/untracked.md"
SV12="$(printf '%s' "$V2" | cut -c1-12)"
mkbank() { py -c 'import json, sys
n = int(sys.argv[1])
open(sys.argv[2], "w").write("".join(json.dumps({"id": "l%d" % i, "q": "zzq-secret-question-text", "gold": ["notes/a.md"], "source": "qmd"}) + "\n" for i in range(n)))' "$1" "$2"; }
LUNA=(--corpus luna --vault "$V" --first "$V1" --second "$V2")

reset_logs
LOUT="$W/luna-l"
before="$(manifest "$W" "$LOUT" "$LOGDIR")"
fx build "${LUNA[@]}" --out "$LOUT" > /dev/null 2>&1; rc=$?
after="$(manifest "$W" "$LOUT" "$LOGDIR")"
eq "::luna_pair_stays_in_scratch (a keyword build with no --state exits 0)" "0" "$rc"
eq "::luna_pair_stays_in_scratch (nothing outside the scratch path changed: live index, himmel repo, vault, HOME, TMPDIR)" "$before" "$after"
eq "::luna_pair_stays_in_scratch (every qmd call is an update of the luna collection on the scratch index and config)" "2|0" \
    "$(qlog | grep -c "^update -c luna | INDEX_PATH=$LOUT/index.sqlite QMD_CONFIG_DIR=$LOUT/config ")|$(qlog | grep -c -v "^update -c luna | INDEX_PATH=$LOUT/index.sqlite QMD_CONFIG_DIR=$LOUT/config ")"
eq "::luna_pair_stays_in_scratch (the tree is the second commit, never the vault's working copy)" "1|0|1|absent" \
    "$(grep -c 'zulu added' "$LOUT/tree/notes/a.md")|$(grep -c 'WORKTREE ONLY' "$LOUT/tree/notes/a.md")|$(grep -c novel "$LOUT/tree/notes/new.md")|$([ -e "$LOUT/tree/notes/untracked.md" ] && echo present || echo absent)"
eq "::luna_pair_stays_in_scratch (pair.json: corpus, both commits, the document counts under the luna rules)" "luna $V1 $V2 2|3" \
    "$(pj "$LOUT" corpus) $(pj "$LOUT" first) $(pj "$LOUT" second) $(pj "$LOUT" doc_counts.first)|$(pj "$LOUT" doc_counts.second)"
eq "::luna_pair_stays_in_scratch (the config mirrors the luna collection and its ignore rules, and indexes the scratch tree)" "1|1|1" \
    "$(grep -c '^  luna:' "$LOUT/config/index.yml")|$(grep -c '60-Maps/graph' "$LOUT/config/index.yml")|$(grep -c -F "path: $LOUT/tree" "$LOUT/config/index.yml")"

reset_logs
FX_EXTRA=("GIT_DIR=$R/.git" "GIT_WORK_TREE=$R")
fx build "${LUNA[@]}" --out "$W/luna-gd" > /dev/null 2>&1; rc=$?
FX_EXTRA=()
eq "::luna_ignores_inherited_git_dir (a GIT_DIR and GIT_WORK_TREE naming another repo do not select it: exit 0, the vault's second tree)" "0|1" \
    "$rc|$(grep -c 'zulu added' "$W/luna-gd/tree/notes/a.md" 2>/dev/null)"

reset_logs
mkdir -p "$R/inside"
ln -s "$R/inside" "$W/link-into-repo"
for o in "$R/luna-out" "$W/link-into-repo/luna-out" "$V/luna-out" "$W/home/.cache/qmd"; do
    fx build "${LUNA[@]}" --out "$o" > /dev/null 2>&1; rc=$?
    eq "::luna_pair_stays_in_scratch (out inside a checkout or the live index dir is refused: exit 2) ${o#"$W"/}" "2" "$rc"
done
eq "::luna_pair_stays_in_scratch (a refusal creates nothing and calls no qmd; the live index keeps its bytes)" "absent|absent|LIVE|" \
    "$([ -e "$R/luna-out" ] && echo present || echo absent)|$([ -e "$V/luna-out" ] && echo present || echo absent)|$(cat "$W/home/.cache/qmd/index.sqlite")|$(qlog)"
fx build --corpus luna --vault "$W/no-such-vault" --first "$V1" --second "$V2" --out "$W/luna-nv" > /dev/null 2>&1; rc=$?
eq "::luna_pair_stays_in_scratch (a vault that is not a repo is refused with a usage exit)" "64" "$rc"

reset_logs
fx build "${LUNA[@]}" --state c --out "$W/luna-c" > /dev/null 2>&1; rc=$?
eq "::luna_paid_refuses_without_billed_ok (state c without --embed-ok: exit 2)" "2" "$rc"
out="$(fx build "${LUNA[@]}" --state s --embed-ok 100 --out "$W/luna-paid" 2>&1)"; rc=$?
eq "::luna_paid_refuses_without_billed_ok (--embed-ok without the opt-in: exit 2, no qmd call)" "2|" "$rc|$(qlog)"
case "$out" in *HIMMEL_BILLED_OK*) pass "::luna_paid_refuses_without_billed_ok (the refusal names HIMMEL_BILLED_OK)" ;; *) fail "::luna_paid_refuses_without_billed_ok (the refusal names HIMMEL_BILLED_OK): $out" ;; esac
FX_EXTRA=(HIMMEL_BILLED_OK=1)
fx build "${LUNA[@]}" --state s --embed-ok 100 --out "$W/luna-paid2" > /dev/null 2>&1; rc=$?
FX_EXTRA=()
eq "::luna_paid_refuses_without_billed_ok (control: with the opt-in the stub sees one luna embed)" "0|1" "$rc|$(qlog | grep -c '^embed -c luna ')"

reset_logs
mkbank 3 "$W/state/bank-ok.jsonl"
cp "$W/state/bank-ok.jsonl" "$R/bank.jsonl"
cp "$W/state/bank-ok.jsonl" "$V/bank.jsonl"
ln -s "$R/bank.jsonl" "$W/link-bank.jsonl"
for b in "$R/bank.jsonl" "$W/link-bank.jsonl" "$V/bank.jsonl"; do
    fx build "${LUNA[@]}" --bank "$b" --out "$W/luna-bk" > /dev/null 2>&1; rc=$?
    eq "::luna_bank_path_outside_repo (a bank inside a checkout, by link too, is refused: exit 2) ${b#"$W"/}" "2" "$rc"
done
eq "::luna_bank_path_outside_repo (a refusal creates no scratch and calls no qmd)" "absent|" "$([ -e "$W/luna-bk" ] && echo present || echo absent)|$(qlog)"
fx build "${LUNA[@]}" --bank "$W/state/bank-ok.jsonl" --out "$W/luna-bk2" > /dev/null 2>&1; rc=$?
eq "::luna_bank_path_outside_repo (control: a bank in a directory outside every checkout is read: exit 0)" "0" "$rc"
fx build --first "$C1" --second "$C2" --state s --bank "$W/state/bank-ok.jsonl" --out "$W/luna-hb" > /dev/null 2>&1; rc=$?
eq "::luna_bank_path_outside_repo (--bank belongs to the luna corpus: a himmel build is a usage exit)" "64" "$rc"

py -c 'import json, sys
rows = [("l1", ["notes/a.md"]), ("l2", ["notes/new.md"]), ("l3", ["notes/b.md"]), ("l4", ["notes/b.md", "notes/a.md"]), ("l5", ["notes/gone.md"])]
open(sys.argv[1], "w").write("".join(json.dumps({"id": i, "q": "zzq-secret-question-text", "gold": g, "source": "qmd"}) + "\n" for i, g in rows))' "$W/state/bank-below.jsonl"
out="$(fx build "${LUNA[@]}" --bank "$W/state/bank-below.jsonl" --out "$W/luna-fl" 2>&1)"; rc=$?
eq "::below_floor_prints_count (a bank below the floor still builds: exit 0)" "0" "$rc"
case "$out" in *"3 of 5 questions qualify"*"below the floor of 15"*) pass "::below_floor_prints_count (the output says the count and that it is below the floor)" ;; *) fail "::below_floor_prints_count (the output says the count and that it is below the floor): $out" ;; esac
case "$out" in *zzq-secret*|*notes/a.md*|*notes/new.md*) fail "::below_floor_prints_count (the output carries counts only, no question or gold text): $out" ;; *) pass "::below_floor_prints_count (the output carries counts only, no question or gold text)" ;; esac
eq "::below_floor_prints_count (pair.json records the count)" "3" "$(pj "$W/luna-fl" qualifying)"
mkbank 14 "$W/state/bank-14.jsonl"
out="$(fx build "${LUNA[@]}" --bank "$W/state/bank-14.jsonl" --out "$W/luna-14" 2>&1)"; rc=$?
eq "::below_floor_prints_count (14 qualifying: exit 0)" "0" "$rc"
case "$out" in *"14 of 14 questions qualify"*"below the floor of 15"*) pass "::below_floor_prints_count (14 qualifying is below the floor)" ;; *) fail "::below_floor_prints_count (14 qualifying is below the floor): $out" ;; esac
mkbank 15 "$W/state/bank-15.jsonl"
out="$(fx build "${LUNA[@]}" --bank "$W/state/bank-15.jsonl" --out "$W/luna-15" 2>&1)"; rc=$?
eq "::below_floor_prints_count (15 qualifying: exit 0)" "0" "$rc"
for bad in '"notes/a.md"' '{"notes/a.md": 1}' '[1]'; do
    printf '{"id": "x", "gold": %s}\n' "$bad" > "$W/state/bank-bad.jsonl"
    fx build "${LUNA[@]}" --bank "$W/state/bank-bad.jsonl" --out "$W/luna-bad" > /dev/null 2>&1; rc=$?
    eq "::luna_bank_gold_must_be_a_list (gold $bad is refused as a bad bank: exit 64, no scratch)" "64|absent" "$rc|$([ -e "$W/luna-bad" ] && echo present || echo absent)"
done
case "$out" in *"below the floor"*) fail "::below_floor_prints_count (control: 15 qualifying is not below the floor): $out" ;; *"15 of 15 questions qualify"*) pass "::below_floor_prints_count (control: 15 qualifying prints the count and no floor line)" ;; *) fail "::below_floor_prints_count (control: 15 qualifying prints the count): $out" ;; esac

reset_logs
for o in "$R/lg-out" "$W/link-into-repo/lg-out" "$V/lg-out" "$W/primary/graphify-out" "$W/link-to-primary"; do
    fx graph --corpus luna --vault "$V" --commit "$V2" --out "$o" > /dev/null 2>&1; rc=$?
    eq "::luna_graph_refuses_repo_out (out inside a checkout or a graphify-out, by link too: exit 2) ${o#"$W"/}" "2" "$rc"
done
mkdir -p "$W/o-lg"; : > "$W/o-lg/.staleness-fixture"; ln -s "$W/primary/graphify-out" "$W/o-lg/graph-$SV12"
fx graph --corpus luna --vault "$V" --commit "$V2" --out "$W/o-lg" > /dev/null 2>&1; rc=$?
eq "::luna_graph_refuses_repo_out (the archive path is a link to the primary graph dir: exit 2)" "2" "$rc"
eq "::luna_graph_refuses_repo_out (nothing created in a checkout, the primary keeps its bytes, graphify never ran)" "absent|absent|PRIMARY|0" \
    "$([ -e "$R/lg-out" ] && echo present || echo absent)|$([ -e "$V/lg-out" ] && echo present || echo absent)|$(cat "$W/primary/graphify-out/graph.json")|$(cat "$LOGDIR/graphify.log" 2>/dev/null | wc -l | tr -d ' ')"

reset_logs
LG="$W/scratch-lg"
before="$(manifest "$W" "$LG" "$LOGDIR")"
fx graph --corpus luna --vault "$V" --commit "$V2" --out "$LG" > /dev/null 2>&1; rc=$?
after="$(manifest "$W" "$LG" "$LOGDIR")"
LARC="$LG/graph-$SV12"
eq "::luna_graph_writes_only_under_scratch (exit 0, nothing outside the scratch path changed)" "0|$before" "$rc|$after"
eq "::luna_graph_archives_the_commit_not_the_worktree (the archive holds the commit's notes, not the working copy)" "1|0|absent" \
    "$(grep -c 'zulu added' "$LARC/notes/a.md")|$(grep -c 'WORKTREE ONLY' "$LARC/notes/a.md")|$([ -e "$LARC/notes/untracked.md" ] && echo present || echo absent)"
eq "::luna_graph_archives_the_commit_not_the_worktree (the stub graphify ran update on the archive)" "update $LARC --force | GRAPHIFY_OUT=unset" "$(head -1 "$LOGDIR/graphify.log" 2>/dev/null)"
eq "::luna_graph_archives_the_commit_not_the_worktree (pair.json records the archive)" "$LARC" "$(pj "$LG" "graph_built_at.$V2")"

V3="$W/vault-link"
git init -q -b main "$V3" || exit 1
mkdir -p "$W/outside-g/cache"; printf 'keep\n' > "$W/outside-g/cache/keep.txt"
ln -s "$W/outside-g" "$V3/graphify-out"; printf '# N\n' > "$V3/n.md"
git -C "$V3" add -A && git -C "$V3" -c user.name=t -c user.email=t@t -c commit.gpgsign=false commit -q --no-verify -m link
V3C="$(git -C "$V3" rev-parse HEAD)"
reset_logs
fx graph --corpus luna --vault "$V3" --commit "$V3C" --out "$W/scratch-sl" --seed-cache "$W/seed" > /dev/null 2>&1; rc=$?
eq "::graph_build_refuses_archived_graphify_out_link (a commit tracking graphify-out as a link: exit 2, the link target keeps its cache, graphify never ran)" "2|keep|0" \
    "$rc|$(cat "$W/outside-g/cache/keep.txt" 2>/dev/null | tr -d '\n')|$(cat "$LOGDIR/graphify.log" 2>/dev/null | wc -l | tr -d ' ')"


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
