#!/usr/bin/env bash
# test-chain-graph.sh — Hermetic tests for chain-graph.py. Local git fixtures in a temp repo;
# gh and the jira CLI are stubs reading a fixture dir (CHAIN_GRAPH_GH / CHAIN_GRAPH_JIRA), so the suite
# never touches the network, Jira or GitHub.
#
# PLATFORM GUARD: no .ps1 twin, by design. The chief kit is Linux-only; this suite exercises a kit script.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="${CHAIN_GRAPH_SUT:-$HERE/chain-graph.py}"
if ! command -v python3 >/dev/null 2>&1 || ! command -v git >/dev/null 2>&1; then
    printf 'SKIP - test-chain-graph.sh (python3 or git not installed)\n'
    exit 0
fi
W="$(mktemp -d "${TMPDIR:-/tmp}/chain-graph-test.XXXXXX")" || exit 1
trap 'rm -rf "$W"' EXIT
fails=0
pass() { printf 'ok - %s\n' "$1"; }
fail() { printf 'FAIL - %s\n' "$1"; fails=$((fails + 1)); }
same() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (got '$2', want '$3')"; fi; }
contains() { case "$2" in *"$3"*) pass "$1" ;; *) fail "$1 (missing '$3')" ;; esac; }

R="$W/repo" F="$W/fix"
mkdir -p "$R" "$F" "$W/bin" "$W/cache"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null

# gh stub: pr view N / pr list / api .../pulls/N/files / run list, all from $CG_FIX.
cat > "$W/bin/gh" <<'STUB'
#!/usr/bin/env bash
case "$1 $2" in
    "pr view") cat "$CG_FIX/pr-$3.json" ;;
    "pr list") cat "$CG_FIX/pr-list.json" ;;
    "api repos/"*) n="${2#repos/*/pulls/}"; n="${n%%/*}"; cat "$CG_FIX/files-$n.tsv" ;;
    "run list") cat "$CG_FIX/main-run.txt" ;;
    *) exit 2 ;;
esac
STUB
cat > "$W/bin/jira" <<'STUB'
#!/usr/bin/env bash
f="$CG_FIX/links-$1.txt"
[ -f "$f" ] && cat "$f"
exit 0
STUB
chmod +x "$W/bin/gh" "$W/bin/jira"
export CG_FIX="$F" CHAIN_GRAPH_GH="$W/bin/gh" CHAIN_GRAPH_JIRA="$W/bin/jira"
printf 'success\n' > "$F/main-run.txt"

g() { git -C "$R" "$@"; }
g init -q -b main
mkdir -p "$R/scripts/ci"
printf '^scripts/ci/\n' > "$R/scripts/ci/ci-trust-paths.txt"
seq 1 30 | sed 's/^/line /' > "$R/shared.txt"
seq 1 30 | sed 's/^/reg /' > "$R/scripts/ci/reg.txt"
echo i1 > "$R/i1.txt"; echo i2 > "$R/i2.txt"
g add -A; g commit -q -m base

# branch <name> <number>: a PR from the commands on stdin, run in the repo on a branch cut from main.
N=0
branch() {
    N=$((N + 1)); local name="$1"
    g checkout -q -b "$name" main
    ( cd "$R" && . /dev/stdin )
    g add -A; g commit -q -m "$name"
    local head; head="$(g rev-parse HEAD)"
    printf '{"number":%d,"title":"[HIMMEL-%d] %s","headRefOid":"%s","headRefName":"%s"}\n' "$N" "$((900 + N))" "$name" "$head" "$name" > "$F/pr-$N.json"
    g diff --name-status --no-renames main "$name" | awk -F'\t' '{s=($1=="A")?"added":($1=="D")?"removed":"modified"; printf "%s\t%s\t\n", $2, s}' > "$F/files-$N.tsv"
    g checkout -q main
}
branch s1a <<'EOF'
sed -i '2s/.*/A two/' shared.txt # gnu-ok: linux-only fixture
EOF
branch s1b <<'EOF'
sed -i '28s/.*/B twenty-eight/' shared.txt # gnu-ok: linux-only fixture
EOF
branch h2a <<'EOF'
sed -i '15s/.*/A fifteen/' shared.txt # gnu-ok: linux-only fixture
EOF
branch h2b <<'EOF'
sed -i '15s/.*/B fifteen/' shared.txt # gnu-ok: linux-only fixture
EOF
branch tra <<'EOF'
sed -i '1s/.*/A reg/' scripts/ci/reg.txt # gnu-ok: linux-only fixture
EOF
branch trb <<'EOF'
sed -i '30s/.*/B reg/' scripts/ci/reg.txt # gnu-ok: linux-only fixture
EOF
branch h1a <<'EOF'
mkdir -p newlib; printf 'echo hi\n' > newlib/helper.sh
EOF
branch h1b <<'EOF'
printf 'run newlib/helper.sh first\n' > notes.txt
EOF
branch ina <<'EOF'
echo a >> i1.txt
EOF
branch inb <<'EOF'
echo b >> i2.txt
EOF
# pr numbers: s1a=1 s1b=2 h2a=3 h2b=4 tra=5 trb=6 h1a=7 h1b=8 ina=9 inb=10

edge() { # edge <prA> <prB> [extra args]: prints "kind det" of the single edge
    local a="$1" b="$2"; shift 2
    python3 "$SUT" --prs "$a,$b" --base main --repo-dir "$R" --cache-dir "$W/cache" --json "$@" 2>"$W/err" |
        python3 -c 'import json,sys; e=json.load(sys.stdin)["edges"][0]; print(e["kind"], e["det"], e["from"], e["to"])'
}

same 'S1: disjoint lines in one shared file' "$(edge 1 2)" 'S1 D4 #1 #2'
same 'H2: same lines conflict in merge-tree' "$(edge 3 4)" 'H2 D4 #3 #4'
same 'H2: shared trust-path file, clean merge' "$(edge 5 6)" 'H2 D3 #5 #6'
same 'H1: B names a file A adds (D7), A is the source' "$(edge 8 7)" 'H1 D7 #7 #8'
same 'independent: no shared file' "$(edge 9 10)" 'independent  #9 #10'

printf '1\tBlocks\tinward=HIMMEL-909\toutward=HIMMEL-910\tHIMMEL-909 blocks HIMMEL-910\n' > "$F/links-HIMMEL-909.txt"
same 'H1: Jira Blocks link (D1) beats independent' "$(edge 9 10)" 'H1 D1 #9 #10'
rm -f "$F/links-HIMMEL-909.txt"

# a second call reads the (headA, headB) cache, so a missing head object cannot change the verdict
same 'cache: same verdict on a repeat call' "$(edge 1 2)" 'S1 D4 #1 #2'

out="$(python3 "$SUT" --prs 1,2,3,4 --base main --repo-dir "$R" --cache-dir "$W/cache" 2>&1)"
contains 'table: summary count line' "$out" 'edges: H1=0 H2=1 S1=5 S2=0 independent=0 (pairs=6)'
contains 'table: node line with gates' "$out" 'trust-judge=no main-red=no'
contains 'table: edge row names the conflict' "$out" 'merge-tree conflict'

out="$(python3 "$SUT" --prs 5,6 --base main --repo-dir "$R" --cache-dir "$W/cache" 2>&1)"
contains 'gates: trust-path node needs a judge' "$out" 'trust-judge=yes (scripts/ci/reg.txt)'

printf 'failure\n' > "$F/main-run.txt"
out="$(python3 "$SUT" --prs 1,2 --base main --repo-dir "$R" --cache-dir "$W/cache" 2>&1)"
contains 'gates: main-red shows on every node' "$out" 'main-red=yes'
printf 'success\n' > "$F/main-run.txt"

# read-only: no new ref, and a failed files read exits 2 with nothing guessed
before="$(g for-each-ref | md5sum)"
python3 "$SUT" --prs 1,2 --base main --repo-dir "$R" --cache-dir "$W/cache" >/dev/null 2>&1
same 'read-only: refs unchanged' "$(g for-each-ref | md5sum)" "$before"
mv "$F/files-2.tsv" "$F/files-2.tsv.gone"
rm -rf "$W/cache"; mkdir "$W/cache"
if python3 "$SUT" --prs 1,2 --base main --repo-dir "$R" --cache-dir "$W/cache" >/dev/null 2>&1; then
    fail 'a files read that fails must exit non-zero'
else
    pass 'a files read that fails exits non-zero'
fi

[ "$fails" -eq 0 ] && printf 'PASS - test-chain-graph.sh\n' || printf 'FAIL - test-chain-graph.sh (%d)\n' "$fails"
[ "$fails" -eq 0 ]
