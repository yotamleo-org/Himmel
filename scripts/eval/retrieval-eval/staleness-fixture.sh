#!/usr/bin/env bash
# billed-opt-in: HIMMEL_BILLED_OK
# staleness-fixture.sh -- the scratch index and graph the staleness eval reads, and the daemon that serves them.
#
#   staleness-fixture.sh build --first <sha> --second <sha> --state s|l|c --out <scratch> [--embed-ok <max-chunks>]
#       A himmel-only qmd index from `git archive`, and <scratch>/pair.json (both commits, the helper's document
#       count, the served URL once served). s = the first commit's tree, l = that index updated to the second
#       commit's tree (keyword only), c = l plus an embed. With no --embed-ok it never calls `qmd embed`.
#       --embed-ok is a paid path: it refuses (exit 2) unless HIMMEL_BILLED_OK=1, and so does state c.
#       <max-chunks> refuses a base tree holding more documents than that (a document is at least one chunk).
#   staleness-fixture.sh serve --index <path> [--with-key]
#       `qmd mcp --http` on a free local port with INDEX_PATH and QMD_CONFIG_DIR on the scratch path. It starts
#       with no provider key; --with-key loads the key through qmd_daemon_key_load and refuses (exit 2) unless
#       HIMMEL_BILLED_OK=1. Prints the URL.
#   staleness-fixture.sh stop --index <path>
#   staleness-fixture.sh graph --commit <sha> --out <scratch> [--seed-cache <dir>]
#       Archives the commit into <scratch>/graph-<sha12>, copies the AST cache to <archive>/graphify-out/cache,
#       and runs ast-update.sh on the archive with GRAPHIFY_OUT unset, so the out dir is the archive's own
#       graphify-out (an overridden out dir holding only cache/ is refused by ast-update.sh with exit 3).
#   --corpus luna (build and graph): the same verbs on the luna vault, from `git archive` of the vault repo
#       (--vault <path>, default $LUNA_VAULT_PATH, else $HOME/Documents/luna); never the vault's working tree and
#       never the live qmd index. The qmd collection is luna, with the live luna ignore rules. build --state defaults to
#       l (keyword only); state c and --embed-ok refuse as they do for himmel. build --bank <jsonl> reads a luna
#       question bank for its gold lists only and prints how many questions have a gold note that changed between the
#       two commits, and says so when that is below the floor of 15. A luna --out or --bank inside any checkout of
#       himmel or of the vault is refused (exit 2): luna content stays outside every checkout.
#
# Writes only under <scratch>: never the live qmd index, its config dir or a graphify-out of a checkout. A
# <scratch> that exists must be empty or carry the marker this script leaves.
# Exit: 0 done; 1 a step failed (git archive, qmd, ast-update.sh, the collection helper, the daemon not
# listening); 2 a refusal (a live or primary path, a non-scratch directory, a missing HIMMEL_BILLED_OK, a
# paid state without --embed-ok, more documents than --embed-ok allows, a key that could not load); 64 usage
# or a commit that does not resolve.
# Seams (tests): SF_QMD, SF_REPO, SF_AST, SF_LIVE_INDEX, SF_PRIMARY_GRAPH_OUT.
# shellcheck disable=SC2015
set -uo pipefail
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE

HERE="$(cd "$(dirname "$0")" && pwd)"
LIB="$HERE/../../lib"
QMD="${SF_QMD:-qmd}"
REPO="${SF_REPO:-$(git -C "$HERE" rev-parse --show-toplevel)}"
AST="${SF_AST:-$HERE/../../graphify/ast-update.sh}"
LIVE_INDEX="${SF_LIVE_INDEX:-${INDEX_PATH:-${XDG_CACHE_HOME:-$HOME/.cache}/qmd/index.sqlite}}"
LIVE_CONFIG="${QMD_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/qmd}"
MARKER=".staleness-fixture"
SRC="$REPO"
COLL=himmel
CORPUS=himmel
FLOOR=15

die() { printf 'staleness-fixture: %s\n' "$1" >&2; exit "${2:-2}"; }
usage() {
    printf 'usage: staleness-fixture.sh build --first <sha> --second <sha> --state s|l|c --out <scratch> [--embed-ok <max-chunks>]\n' >&2
    printf '       staleness-fixture.sh serve --index <path> [--with-key]\n' >&2
    printf '       staleness-fixture.sh stop --index <path>\n' >&2
    printf '       staleness-fixture.sh graph --commit <sha> --out <scratch> [--seed-cache <dir>]\n' >&2
    printf '       staleness-fixture.sh build --corpus luna [--vault <path>] --first <sha> --second <sha> [--state s|l|c] --out <scratch> [--bank <jsonl>] [--embed-ok <max-chunks>]\n' >&2
    printf '       staleness-fixture.sh graph --corpus luna [--vault <path>] --commit <sha> --out <scratch> [--seed-cache <dir>]\n' >&2
    exit 64
}
rp() { python3 -I -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' "$1"; }
path_within() { case "$1/" in "$2"/*) return 0 ;; esac; return 1; }
checkout_roots() {
    local c l
    rp "$(git -C "$1" rev-parse --show-toplevel)"
    c="$(git -C "$1" rev-parse --path-format=absolute --git-common-dir)"
    rp "$(dirname "$c")"
    git -C "$1" worktree list --porcelain | while IFS= read -r l; do
        case "$l" in "worktree "*) rp "${l#worktree }" ;; esac
    done
}
refuse_in_checkouts() {
    local r
    while IFS= read -r r; do
        if path_within "$1" "$r"; then die "refusing $2: it is inside the checkout $r, and luna content stays outside every checkout"; fi
    done < <(checkout_roots "$REPO"; checkout_roots "$SRC")
}
luna_corpus() {
    local v="${1:-${LUNA_VAULT_PATH:-$HOME/Documents/luna}}"
    SRC="$(git -C "$v" rev-parse --show-toplevel 2> /dev/null)" || die "not a git repository (the luna vault): $v" 64
    CORPUS=luna
    COLL=luna
}

guard_scratch() {
    local out="$1" real live d g
    real="$(rp "$out")"
    live="$(rp "$LIVE_INDEX")"
    for d in "$(dirname "$live")" "$(rp "$LIVE_CONFIG")"; do
        if path_within "$real" "$d"; then die "refusing $out: it is the live qmd index or config directory, or inside it"; fi
    done
    for g in "${SF_PRIMARY_GRAPH_OUT:-$(dirname "$(git -C "$REPO" rev-parse --path-format=absolute --git-common-dir)")/graphify-out}" "$REPO/graphify-out"; do
        if path_within "$real" "$(rp "$g")"; then die "refusing $out: it is, or is inside, a checkout's graphify-out"; fi
    done
    if [ "$CORPUS" = luna ]; then refuse_in_checkouts "$real" "$out"; fi
    if [ -e "$real" ]; then
        [ -d "$real" ] || die "refusing $out: not a directory"
        if [ ! -f "$real/$MARKER" ] && [ -n "$(ls -A "$real")" ]; then
            die "refusing $out: a non-empty directory this script did not make"
        fi
    fi
    refuse_links "$real"
    OUTR="$real"
}
refuse_links() {
    local n
    for n in config tree index.sqlite pair.json pair.json.tmp serve.pid serve.port serve.log qmd-update.log qmd-embed.log "$MARKER"; do
        if [ -L "$1/$n" ]; then die "refusing $1: $n is a symlink"; fi
    done
}
make_scratch() { mkdir -p "$OUTR" && : > "$OUTR/$MARKER" || die "cannot create $OUTR" 1; }

PJ_PY='import json, os, sys
f = os.path.join(sys.argv[1], "pair.json")
d = json.load(open(f)) if os.path.exists(f) else {}
if sys.argv[2] == "set":
    d[sys.argv[3]] = json.loads(sys.argv[4])
else:
    d.setdefault(sys.argv[3], {})[sys.argv[4]] = sys.argv[5]
t = f + ".tmp"
with open(t, "w") as fh:
    json.dump(d, fh, indent=2, sort_keys=True)
    fh.write("\n")
os.replace(t, f)'
pj_set() { python3 -I -c "$PJ_PY" "$1" set "$2" "$3"; }
pj_map() { python3 -I -c "$PJ_PY" "$1" map "$2" "$3" "$4"; }

need_commit() { git -C "$SRC" rev-parse --verify --quiet "$1^{commit}" || die "not a commit in $SRC: $1" 64; }
need_value() { [ -n "${2:-}" ] || usage; }

write_config_mirroring_live_rules() {
    mkdir -p "$1/config"
    {
        printf 'collections:\n  %s:\n    path: %s\n    pattern: "**/*.md"\n    ignore:\n' "$COLL" "$2"
        if [ "$COLL" = luna ]; then
            printf '      - "graphify-out/**"\n      - "60-Maps/graph/**"\n      - "handovers/**/verdicts/*/scratch/**"\n'
        else
            printf '      - "graphify-out/**"\n      - "**/fixtures/**"\n      - "marketplace/plugins/*/README*.md"\n'
        fi
    } > "$1/config/index.yml"
}
count_paths() {
    xargs -0 -n 500 python3 -I "$LIB/qmd-collection-files.py" --config "$1" "$COLL" | wc -l | tr -d ' '
}
doc_count() {
    git -C "$SRC" ls-tree -r -z "$1" | python3 -I -c 'import sys
for e in sys.stdin.buffer.read().split(b"\0"):
    if e and not e.startswith((b"120000", b"160000")):
        sys.stdout.buffer.write(e.split(b"\t", 1)[1] + b"\0")' | count_paths "$2"
}
delta_count() {
    git -C "$SRC" diff --raw -z --no-renames --diff-filter=AMT "$1" "$2" | python3 -I -c 'import sys
t = sys.stdin.buffer.read().split(b"\0")
for meta, path in zip(t[0::2], t[1::2]):
    if meta.split()[1] not in (b"120000", b"160000"):
        sys.stdout.buffer.write(path + b"\0")' | count_paths "$3"
}
unpack() {
    rm -rf "$2" && mkdir -p "$2" && git -C "$SRC" archive --format=tar "$1" -- '*.md' | tar -x -C "$2" || die "git archive of $1 failed" 1
}
qrun() {
    env -u QMD_OPENAI_API_KEY -u OPENAI_API_KEY -u OPENROUTER_API_KEY \
        INDEX_PATH="$OUTR/index.sqlite" QMD_CONFIG_DIR="$OUTR/config" "$QMD" "$@" > "$OUTR/qmd-$1.log" 2>&1 \
        || die "qmd $1 failed (see $OUTR/qmd-$1.log)" 1
}
embed() {
    # shellcheck source=../../lib/qmd-daemon-env.sh
    . "$LIB/qmd-daemon-env.sh"  # t13b-ok: names the existing qmd key loader, starts nothing
    qmd_daemon_key_load "$OUTR/config/index.yml" || die "the provider key could not be loaded for the embed" 2  # t13b-ok: names the existing qmd key loader, starts nothing
    INDEX_PATH="$OUTR/index.sqlite" QMD_CONFIG_DIR="$OUTR/config" "$QMD" embed -c "$COLL" > "$OUTR/qmd-embed.log" 2>&1 \
        || die "qmd embed failed (see $OUTR/qmd-embed.log)" 1
}

count_qualifying() {
    git -C "$SRC" diff --raw -z --no-renames --diff-filter=AMT "$1" "$2" | python3 -I -c 'import json, sys
t = sys.stdin.buffer.read().split(b"\0")
changed = {p.decode("utf-8", "surrogateescape") for p in t[1::2]}
n = q = 0
try:
    for line in open(sys.argv[1], encoding="utf-8"):
        if line.strip():
            n += 1
            gold = json.loads(line)["gold"]
            if not isinstance(gold, list) or not all(isinstance(g, str) for g in gold):
                raise TypeError
            q += any(g in changed for g in gold)
except (OSError, ValueError, KeyError, TypeError):
    sys.exit(1)
print(q, n)' "$3"
}

cmd_build() {
    local first="" second="" state="" out="" cap="" corpus=himmel vault="" bank="" n1 n2 nd need nq="" nt=""
    while [ $# -gt 0 ]; do
        case "$1" in
        --first) need_value "$@"; first="$2"; shift 2 ;;
        --second) need_value "$@"; second="$2"; shift 2 ;;
        --state) need_value "$@"; state="$2"; shift 2 ;;
        --out) need_value "$@"; out="$2"; shift 2 ;;
        --embed-ok) need_value "$@"; cap="$2"; shift 2 ;;
        --corpus) need_value "$@"; corpus="$2"; shift 2 ;;
        --vault) need_value "$@"; vault="$2"; shift 2 ;;
        --bank) need_value "$@"; bank="$2"; shift 2 ;;
        *) usage ;;
        esac
    done
    [ -n "$first" ] && [ -n "$second" ] && [ -n "$out" ] || usage
    case "$corpus" in
    himmel) [ -z "$vault$bank" ] || usage ;;
    luna) [ -n "$state" ] || state=l ;;
    *) usage ;;
    esac
    case "$state" in s | l | c) ;; *) usage ;; esac
    if [ -n "$cap" ]; then
        case "$cap" in '' | *[!0-9]* | 0) usage ;; esac
    fi
    if [ "$state" = c ] && [ -z "$cap" ]; then die "state c is the paid arm: it needs --embed-ok <max-chunks>"; fi
    if [ -n "$cap" ] && [ "${HIMMEL_BILLED_OK:-}" != 1 ]; then
        die "--embed-ok is a paid path (qmd embed): it refuses unless HIMMEL_BILLED_OK=1"
    fi
    if [ "$corpus" = luna ]; then luna_corpus "$vault"; fi
    first="$(need_commit "$first")" || exit $?
    second="$(need_commit "$second")" || exit $?
    if [ -n "$bank" ]; then
        refuse_in_checkouts "$(rp "$bank")" "--bank $bank"
        [ -f "$bank" ] || die "--bank is not a file: $bank" 64
        read -r nq nt < <(count_qualifying "$first" "$second" "$bank") || die "--bank is not a JSON-lines file of rows with a gold list: $bank" 64
    fi
    guard_scratch "$out"
    if [ -e "$OUTR/index.sqlite" ]; then die "refusing $out: it already holds an index; a rebuild needs a fresh scratch path"; fi
    make_scratch
    write_config_mirroring_live_rules "$OUTR" "$OUTR/tree"
    n1="$(doc_count "$first" "$OUTR/config/index.yml")" || die "the collection helper refused the first tree" 1
    n2="$(doc_count "$second" "$OUTR/config/index.yml")" || die "the collection helper refused the second tree" 1
    if [ -n "$cap" ]; then
        need="$n1"
        if [ "$state" = c ]; then
            nd="$(delta_count "$first" "$second" "$OUTR/config/index.yml")" || die "the collection helper refused the changed files" 1
            need=$((n1 + nd))
        fi
        if [ "$need" -gt "$cap" ]; then
            die "$need documents to embed, more than --embed-ok $cap chunks: a document is at least one chunk"
        fi
    fi
    unpack "$first" "$OUTR/tree"
    qrun update -c "$COLL"
    [ -z "$cap" ] || embed
    if [ "$state" != s ]; then
        unpack "$second" "$OUTR/tree"
        qrun update -c "$COLL"
        if [ "$state" = c ]; then embed; fi
    fi
    pj_set "$OUTR" first "\"$first\""
    pj_set "$OUTR" second "\"$second\""
    pj_set "$OUTR" state "\"$state\""
    pj_set "$OUTR" doc_counts "{\"first\": $n1, \"second\": $n2}"
    if [ "$state" = s ]; then pj_set "$OUTR" doc_count "$n1"; else pj_set "$OUTR" doc_count "$n2"; fi
    pj_set "$OUTR" index "\"$OUTR/index.sqlite\""
    pj_set "$OUTR" embed_cap "${cap:-null}"
    pj_set "$OUTR" served_url null
    if [ "$corpus" = luna ]; then pj_set "$OUTR" corpus '"luna"'; fi
    if [ -n "$nq" ]; then
        pj_set "$OUTR" qualifying "$nq"
        printf 'luna: %s of %s questions qualify (a gold note changed between the two commits)\n' "$nq" "$nt"
        if [ "$nq" -lt "$FLOOR" ]; then printf 'luna: %s is below the floor of %s questions; this is a count, not a pass\n' "$nq" "$FLOOR"; fi
    fi
}

scratch_of_index() {
    local idx="$1" real
    if [ -L "$idx" ]; then die "refusing $idx: it is a symlink"; fi
    real="$(rp "$idx")"
    if [ "$real" = "$(rp "$LIVE_INDEX")" ] || path_within "$real" "$(dirname "$(rp "$LIVE_INDEX")")"; then
        die "refusing $idx: it is the live qmd index"
    fi
    OUTR="$(dirname "$real")"
    [ -f "$OUTR/$MARKER" ] || die "refusing $idx: not in a scratch directory this script made"
    refuse_links "$OUTR"
}

cmd_serve() {
    local index="" withkey=0 port pid i
    while [ $# -gt 0 ]; do
        case "$1" in
        --index) need_value "$@"; index="$2"; shift 2 ;;
        --with-key) withkey=1; shift ;;
        *) usage ;;
        esac
    done
    [ -n "$index" ] || usage
    if [ "$withkey" -eq 1 ] && [ "${HIMMEL_BILLED_OK:-}" != 1 ]; then
        die "--with-key loads the provider key and can bill: it refuses unless HIMMEL_BILLED_OK=1"
    fi
    scratch_of_index "$index"
    [ -f "$OUTR/index.sqlite" ] && [ -d "$OUTR/config" ] || die "no index and config in $OUTR: run build first"
    if [ -f "$OUTR/serve.pid" ] && kill -0 "$(cat "$OUTR/serve.pid")" 2>/dev/null; then die "already serving from $OUTR"; fi
    port="$(python3 -I -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')"
    if [ "$withkey" -eq 1 ]; then
        # shellcheck source=../../lib/qmd-daemon-env.sh
        . "$LIB/qmd-daemon-env.sh"  # t13b-ok: names the existing qmd key loader, starts nothing
        qmd_daemon_key_load "$OUTR/config/index.yml" || die "the provider key could not be loaded" 2  # t13b-ok: names the existing qmd key loader, starts nothing
        INDEX_PATH="$OUTR/index.sqlite" QMD_CONFIG_DIR="$OUTR/config" nohup "$QMD" mcp --http --port "$port" > "$OUTR/serve.log" 2>&1 < /dev/null &  # t13b-ok: starts the scratch-index qmd server for one eval run, ended by the stop verb
    else
        env -u QMD_OPENAI_API_KEY -u OPENAI_API_KEY -u OPENROUTER_API_KEY \
            INDEX_PATH="$OUTR/index.sqlite" QMD_CONFIG_DIR="$OUTR/config" nohup "$QMD" mcp --http --port "$port" > "$OUTR/serve.log" 2>&1 < /dev/null &  # t13b-ok: starts the scratch-index qmd server for one eval run, ended by the stop verb
    fi
    pid=$!
    printf '%s\n' "$pid" > "$OUTR/serve.pid"
    printf '%s\n' "$port" > "$OUTR/serve.port"
    i=0
    while ! (exec 3<> "/dev/tcp/localhost/$port") 2> /dev/null; do
        kill -0 "$pid" 2> /dev/null || { rm -f "$OUTR/serve.pid"; die "the server exited (see $OUTR/serve.log)" 1; }
        i=$((i + 1))
        [ "$i" -lt 120 ] || { kill "$pid" 2> /dev/null; rm -f "$OUTR/serve.pid"; die "the server did not listen in 60 s" 1; }
        sleep 0.5
    done
    pj_set "$OUTR" served_url "\"http://localhost:$port/mcp\""
    printf 'http://localhost:%s/mcp\n' "$port"
}

is_our_server() {
    local args
    [ -n "$2" ] || return 1
    args="$(ps -p "$1" -o args= 2> /dev/null)"
    case "$args" in
    *"mcp --http --port $2" | *"mcp --http --port $2 "*) return 0 ;;
    esac
    return 1
}

cmd_stop() {
    local index="" pid i
    while [ $# -gt 0 ]; do
        case "$1" in
        --index) need_value "$@"; index="$2"; shift 2 ;;
        *) usage ;;
        esac
    done
    [ -n "$index" ] || usage
    scratch_of_index "$index"
    if [ -f "$OUTR/serve.pid" ]; then
        pid="$(cat "$OUTR/serve.pid")"
        if is_our_server "$pid" "$(cat "$OUTR/serve.port" 2> /dev/null)"; then
            kill "$pid" 2> /dev/null
            i=0
            while kill -0 "$pid" 2> /dev/null && [ "$i" -lt 20 ]; do sleep 0.25; i=$((i + 1)); done
        fi
        rm -f "$OUTR/serve.pid" "$OUTR/serve.port"
    fi
    if [ -f "$OUTR/pair.json" ]; then pj_set "$OUTR" served_url null; fi
}

cmd_graph() {
    local commit="" out="" seed="" corpus=himmel vault="" arc
    while [ $# -gt 0 ]; do
        case "$1" in
        --commit) need_value "$@"; commit="$2"; shift 2 ;;
        --out) need_value "$@"; out="$2"; shift 2 ;;
        --seed-cache) need_value "$@"; seed="$2"; shift 2 ;;
        --corpus) need_value "$@"; corpus="$2"; shift 2 ;;
        --vault) need_value "$@"; vault="$2"; shift 2 ;;
        *) usage ;;
        esac
    done
    [ -n "$commit" ] && [ -n "$out" ] || usage
    case "$corpus" in
    himmel) [ -z "$vault" ] || usage ;;
    luna) luna_corpus "$vault" ;;
    *) usage ;;
    esac
    commit="$(need_commit "$commit")" || exit $?
    if [ -n "$seed" ] && [ ! -d "$seed" ]; then die "--seed-cache is not a directory: $seed"; fi
    guard_scratch "$out"
    arc="$OUTR/graph-$(printf '%s' "$commit" | cut -c1-12)"
    if [ -L "$arc" ]; then die "refusing $arc: it is a symlink"; fi
    if [ -e "$arc" ]; then die "refusing $arc: already built"; fi
    make_scratch
    mkdir -p "$arc" && git -C "$SRC" archive --format=tar "$commit" | tar -x -C "$arc" || die "git archive of $commit failed" 1
    if [ -L "$arc/graphify-out" ]; then die "refusing $arc/graphify-out: it is a symlink in $commit"; fi
    if [ -n "$seed" ]; then
        rm -rf "$arc/graphify-out/cache"
        mkdir -p "$arc/graphify-out/cache" && cp -R "$seed/." "$arc/graphify-out/cache/" || die "the cache seed failed" 1
    fi
    env -u GRAPHIFY_OUT bash "$AST" "$arc" || die "ast-update.sh failed on $arc" 1
    pj_map "$OUTR" graph_built_at "$commit" "$arc"
}

verb="${1:-}"
[ $# -eq 0 ] || shift
case "$verb" in
build) cmd_build "$@" ;;
serve) cmd_serve "$@" ;;
stop) cmd_stop "$@" ;;
graph) cmd_graph "$@" ;;
*) usage ;;
esac
