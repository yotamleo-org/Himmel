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

HERE="$(cd "$(dirname "$0")" && pwd)"
LIB="$HERE/../../lib"
QMD="${SF_QMD:-qmd}"
REPO="${SF_REPO:-$(git -C "$HERE" rev-parse --show-toplevel)}"
AST="${SF_AST:-$HERE/../../graphify/ast-update.sh}"
LIVE_INDEX="${SF_LIVE_INDEX:-${INDEX_PATH:-${XDG_CACHE_HOME:-$HOME/.cache}/qmd/index.sqlite}}"
LIVE_CONFIG="${QMD_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/qmd}"
MARKER=".staleness-fixture"

die() { printf 'staleness-fixture: %s\n' "$1" >&2; exit "${2:-2}"; }
usage() {
    printf 'usage: staleness-fixture.sh build --first <sha> --second <sha> --state s|l|c --out <scratch> [--embed-ok <max-chunks>]\n' >&2
    printf '       staleness-fixture.sh serve --index <path> [--with-key]\n' >&2
    printf '       staleness-fixture.sh stop --index <path>\n' >&2
    printf '       staleness-fixture.sh graph --commit <sha> --out <scratch> [--seed-cache <dir>]\n' >&2
    exit 64
}
rp() { python3 -I -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' "$1"; }
path_within() { case "$1/" in "$2"/*) return 0 ;; esac; return 1; }

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

need_commit() { git -C "$REPO" rev-parse --verify --quiet "$1^{commit}" || die "not a commit in $REPO: $1" 64; }
need_value() { [ -n "${2:-}" ] || usage; }

write_config_mirroring_live_himmel_rules() {
    mkdir -p "$1/config"
    {
        printf 'collections:\n  himmel:\n    path: %s\n    pattern: "**/*.md"\n    ignore:\n' "$2"
        printf '      - "graphify-out/**"\n      - "**/fixtures/**"\n      - "marketplace/plugins/*/README*.md"\n'
    } > "$1/config/index.yml"
}
count_paths() {
    xargs -0 -n 500 python3 -I "$LIB/qmd-collection-files.py" --config "$1" himmel | wc -l | tr -d ' '
}
doc_count() {
    git -C "$REPO" ls-tree -r --name-only -z "$1" | count_paths "$2"
}
delta_count() {
    git -C "$REPO" diff --name-only -z --no-renames --diff-filter=AM "$1" "$2" | count_paths "$3"
}
unpack() {
    rm -rf "$2" && mkdir -p "$2" && git -C "$REPO" archive --format=tar "$1" -- '*.md' | tar -x -C "$2" || die "git archive of $1 failed" 1
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
    INDEX_PATH="$OUTR/index.sqlite" QMD_CONFIG_DIR="$OUTR/config" "$QMD" embed -c himmel > "$OUTR/qmd-embed.log" 2>&1 \
        || die "qmd embed failed (see $OUTR/qmd-embed.log)" 1
}

cmd_build() {
    local first="" second="" state="" out="" cap="" n1 n2 nd need
    while [ $# -gt 0 ]; do
        case "$1" in
        --first) need_value "$@"; first="$2"; shift 2 ;;
        --second) need_value "$@"; second="$2"; shift 2 ;;
        --state) need_value "$@"; state="$2"; shift 2 ;;
        --out) need_value "$@"; out="$2"; shift 2 ;;
        --embed-ok) need_value "$@"; cap="$2"; shift 2 ;;
        *) usage ;;
        esac
    done
    [ -n "$first" ] && [ -n "$second" ] && [ -n "$out" ] || usage
    case "$state" in s | l | c) ;; *) usage ;; esac
    if [ -n "$cap" ]; then
        case "$cap" in '' | *[!0-9]* | 0) usage ;; esac
    fi
    if [ "$state" = c ] && [ -z "$cap" ]; then die "state c is the paid arm: it needs --embed-ok <max-chunks>"; fi
    if [ -n "$cap" ] && [ "${HIMMEL_BILLED_OK:-}" != 1 ]; then
        die "--embed-ok is a paid path (qmd embed): it refuses unless HIMMEL_BILLED_OK=1"
    fi
    first="$(need_commit "$first")" || exit $?
    second="$(need_commit "$second")" || exit $?
    guard_scratch "$out"
    if [ -e "$OUTR/index.sqlite" ]; then die "refusing $out: it already holds an index; a rebuild needs a fresh scratch path"; fi
    make_scratch
    write_config_mirroring_live_himmel_rules "$OUTR" "$OUTR/tree"
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
    qrun update -c himmel
    [ -z "$cap" ] || embed
    if [ "$state" != s ]; then
        unpack "$second" "$OUTR/tree"
        qrun update -c himmel
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
    while ! (exec 3<> "/dev/tcp/127.0.0.1/$port") 2> /dev/null; do
        kill -0 "$pid" 2> /dev/null || { rm -f "$OUTR/serve.pid"; die "the server exited (see $OUTR/serve.log)" 1; }
        i=$((i + 1))
        [ "$i" -lt 120 ] || { kill "$pid" 2> /dev/null; rm -f "$OUTR/serve.pid"; die "the server did not listen in 60 s" 1; }
        sleep 0.5
    done
    pj_set "$OUTR" served_url "\"http://127.0.0.1:$port/mcp\""
    printf 'http://127.0.0.1:%s/mcp\n' "$port"
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
    local commit="" out="" seed="" arc
    while [ $# -gt 0 ]; do
        case "$1" in
        --commit) need_value "$@"; commit="$2"; shift 2 ;;
        --out) need_value "$@"; out="$2"; shift 2 ;;
        --seed-cache) need_value "$@"; seed="$2"; shift 2 ;;
        *) usage ;;
        esac
    done
    [ -n "$commit" ] && [ -n "$out" ] || usage
    commit="$(need_commit "$commit")" || exit $?
    if [ -n "$seed" ] && [ ! -d "$seed" ]; then die "--seed-cache is not a directory: $seed"; fi
    guard_scratch "$out"
    arc="$OUTR/graph-$(printf '%s' "$commit" | cut -c1-12)"
    if [ -L "$arc" ]; then die "refusing $arc: it is a symlink"; fi
    if [ -e "$arc" ]; then die "refusing $arc: already built"; fi
    make_scratch
    mkdir -p "$arc" && git -C "$REPO" archive --format=tar "$commit" | tar -x -C "$arc" || die "git archive of $commit failed" 1
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
