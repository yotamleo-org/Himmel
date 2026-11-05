#!/usr/bin/env bash
# test-himmel-update-graph-fetch.sh — the graph-data channel end to end:
# scripts/graphify/publish-graph-channel.sh builds the orphan
# graph-data commit, and himmel-update.sh's sync_graph fetches and installs it.
#
# Hermetic: a local bare "origin", a publisher clone and adopter clones in a temp
# dir, HOME pointed at a temp dir, the cadence alert file, dedupe dir and sender
# pinned to temp paths. No real remote, no model call, no semantic pass: the only
# graph tooling that runs is the model-free --seed-manifest stamp and the
# semantic-merge.py plan read.
#
# Rows:
#   publish: the orphan branch carries exactly the four files, no parent
#   publish: a second publish replaces the branch (lease on the old tip)
#   publish: refuses a graph with no semantic layer
#   publish: the scan blocks a planted host path, alerts, names file and rule only
#   publish: the scan blocks a planted secret-shaped string (gitleaks)
#   publish: no gitleaks = blocked, fail closed
#   fetch:   fresh and an ancestor installs; the semantic pass is then skipped
#   fetch:   150 behind installs, 151 behind falls back
#   fetch:   a non-ancestor build commit falls back
#   fetch:   a missing graph-data branch falls back
#   fetch:   a host path in the fetched bytes falls back (tamper)
#   fetch:   a built_at_commit file that disagrees with graph.json falls back
#   fetch:   the publisher station (graphify.semantic_api_ok) never installs
#   fetch:   --check reports what it would fetch and writes nothing

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
PUBLISH="$HERE/graphify/publish-graph-channel.sh"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/test-graph-fetch.XXXXXX")" || exit 1
TMP="$(cd "$TMP" && pwd -P)"
trap 'rm -rf "$TMP"' EXIT

export USERPROFILE=''
export HOME="$TMP/home"
export CLAUDE_CONFIG_DIR="$TMP/no-claude-config"
export HERMES_HOME="$TMP/no-hermes"
export HIMMELCTL_CACHE_DIR="$TMP/himmelctl-cache"
export CADENCE_ALERT_FILE="$TMP/alerts.log"
export CADENCE_ALERT_DEDUPE_DIR="$TMP/alert-dedupe"
export CADENCE_ALERT_SEND_FAILED_MARK="$TMP/alert-send-failed"
export CADENCE_ALERT_SEND_CMD="$TMP/alert-send.sh"
export GIT_CONFIG_NOSYSTEM=1
unset HIMMEL_UPDATE_CHANNEL HIMMEL_UPDATE_GRAPH_MAX_BEHIND HIMMEL_UPDATE_GRAPH_REMOTE GRAPH_CHANNEL_REMOTE GRAPH_CHANNEL_GITLEAKS
mkdir -p "$HOME" "$HIMMELCTL_CACHE_DIR" || exit 1
# shellcheck disable=SC2016  # the fake expands $1 when it runs
printf '#!/bin/sh\nprintf "%%s\\n" "$1" >> "%s/alert-sent.log"\n' "$TMP" > "$CADENCE_ALERT_SEND_CMD"
chmod +x "$CADENCE_ALERT_SEND_CMD"

pass=0
fail=0
ok()  { pass=$((pass + 1)); echo "  PASS: $1"; }
bad() { fail=$((fail + 1)); echo "  FAIL: $1"; }
has() { grep -qF -- "$1" <<< "$2"; }
check_has()   { if has "$2" "$3"; then ok "$1"; else bad "$1 — expected '$2', got: $3"; fi; }
check_lacks() { if has "$2" "$3"; then bad "$1 — must not contain '$2'"; else ok "$1"; fi; }
check_eq()    { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 — expected '$2', got '$3'"; fi; }

gitq() { git -c user.email=t@test.test -c user.name=Test "$@"; }

# --- publisher side --------------------------------------------------------
BARE="$TMP/origin.git"
PUB="$TMP/pub"
git init --quiet --bare "$BARE"
git init --quiet --initial-branch=main "$PUB" 2>/dev/null || git init --quiet "$PUB"
printf '# alpha\n' > "$PUB/alpha.md"
printf '# beta\n' > "$PUB/beta.md"
gitq -C "$PUB" add -A
gitq -C "$PUB" commit --quiet -m "chore: seed"
gitq -C "$PUB" remote add origin "$BARE"
gitq -C "$PUB" push --quiet origin HEAD:refs/heads/main
git -C "$BARE" symbolic-ref HEAD refs/heads/main
SEED_SHA="$(git -C "$PUB" rev-parse HEAD)"

# make_src <dir> <built_at_commit> — a publishable graphify-out with decoys
# that must never be published.
make_src() {
    local d="$1" bac="$2"
    rm -rf "$d"; mkdir -p "$d/cache"
    printf '{"nodes":[{"id":"alpha","label":"see /tmp/inv-label"}],"edges":[],"built_at_commit":"%s"}\n' "$bac" > "$d/graph.json"
    printf '# GRAPH_REPORT\n' > "$d/GRAPH_REPORT.md"
    printf '{"alpha.md":{"mtime":0}}\n' > "$d/manifest.json"
    printf '{"version":1,"files":{"alpha.md":"x"}}\n' > "$d/semantic-manifest.json"
    printf '<html></html>\n' > "$d/graph.html"
    printf '{}\n' > "$d/semantic-runs.jsonl"
    printf 'x\n' > "$d/cache/entry.json"
}

run_publish() {  # <src> [extra env assignments via env]
    PUB_RC=0
    PUB_OUT="$(bash "$PUBLISH" --src "$1" --repo "$PUB" --remote "$BARE" 2>&1)" || PUB_RC=$?
}
branch_tip() { git -C "$BARE" rev-parse --verify --quiet refs/heads/graph-data 2>/dev/null || echo none; }

SRC="$TMP/src"
echo "publish: the orphan branch carries exactly the four files"
make_src "$SRC" "$SEED_SHA"
run_publish "$SRC"
check_eq "publish rc 0" 0 "$PUB_RC"
check_eq "graph-data holds exactly the four files" \
    "$(printf 'GRAPH_REPORT.md\nbuilt_at_commit\ngraph.json\nmanifest.json')" \
    "$(git -C "$BARE" ls-tree --name-only graph-data 2>&1)"
check_eq "graph-data is one orphan commit" 1 "$(git -C "$BARE" rev-list --count graph-data 2>/dev/null || echo 0)"
check_eq "built_at_commit is the graph's build commit" "$SEED_SHA" "$(git -C "$BARE" show graph-data:built_at_commit 2>/dev/null)"
check_eq "graph.json bytes are the source bytes" "$(cat "$SRC/graph.json")" "$(git -C "$BARE" show graph-data:graph.json 2>/dev/null)"
FIRST_TIP="$(branch_tip)"

echo "publish: a second publish replaces the branch, still one orphan commit"
printf '# GRAPH_REPORT v2\n' > "$SRC/GRAPH_REPORT.md"
run_publish "$SRC"
check_eq "republish rc 0" 0 "$PUB_RC"
if [ "$(branch_tip)" != "$FIRST_TIP" ]; then ok "the tip moved"; else bad "the tip did not move"; fi
check_eq "still one orphan commit" 1 "$(git -C "$BARE" rev-list --count graph-data 2>/dev/null || echo 0)"
GOOD_TIP="$(branch_tip)"

echo "publish: refuses a graph with no semantic layer"
make_src "$SRC" "$SEED_SHA"
rm -f "$SRC/semantic-manifest.json"
run_publish "$SRC"
if [ "$PUB_RC" -ne 0 ]; then ok "no semantic layer exits non-zero"; else bad "no semantic layer published"; fi
check_eq "branch untouched" "$GOOD_TIP" "$(branch_tip)"
make_src "$SRC" "$SEED_SHA"
printf '{"version":1,"files":{}}\n' > "$SRC/semantic-manifest.json"
run_publish "$SRC"
if [ "$PUB_RC" -ne 0 ]; then ok "an empty semantic manifest exits non-zero"; else bad "an empty semantic manifest published"; fi
make_src "$SRC" "$SEED_SHA"
rm -f "$SRC/manifest.json"
run_publish "$SRC"
if [ "$PUB_RC" -ne 0 ]; then ok "no manifest.json exits non-zero"; else bad "no manifest.json published"; fi
check_eq "branch untouched" "$GOOD_TIP" "$(branch_tip)"

echo "publish: the scan blocks a planted host path"
make_src "$SRC" "$SEED_SHA"
# The planted paths are split in the source so the repo's own leak gate does not match this file.
printf '{"nodes":[{"id":"x","source_file":"%s/alice/private/notes.md"}],"built_at_commit":"%s"}\n' "/ho""me" "$SEED_SHA" > "$SRC/graph.json"
: > "$CADENCE_ALERT_FILE"
run_publish "$SRC"
check_eq "host path blocks with rc 3" 3 "$PUB_RC"
check_eq "branch untouched" "$GOOD_TIP" "$(branch_tip)"
ALERTS="$(cat "$CADENCE_ALERT_FILE" 2>/dev/null)"
check_has "an alert was raised for the publish worker" "graph-channel-publish" "$ALERTS"
check_has "the alert names the file" "graph.json" "$ALERTS"
check_has "the alert names the rule" "host-path" "$ALERTS"
check_lacks "the alert carries no matched text" "alice" "$ALERTS"
check_lacks "the output carries no matched text" "alice" "$PUB_OUT"
make_src "$SRC" "$SEED_SHA"
printf '# report\nbuilt in %s/bob/dev\n' "/Us""ers" > "$SRC/GRAPH_REPORT.md"
run_publish "$SRC"
check_eq "a macOS home path blocks too" 3 "$PUB_RC"
make_src "$SRC" "$SEED_SHA"
printf '# report\nscratch /tmp/claude-1000/x/scratchpad\n' > "$SRC/GRAPH_REPORT.md"
run_publish "$SRC"
check_eq "a scratch path blocks too" 3 "$PUB_RC"

echo "publish: the scan blocks a planted secret-shaped string"
if command -v gitleaks >/dev/null 2>&1; then
    make_src "$SRC" "$SEED_SHA"
    TOKEN="$(printf '%s%s' 'gh''p_' 'R4nd0mStr1ngW1thEntr0pyXq9Lk2Mn8Pz5T')"
    printf '# report\ntoken %s here\n' "$TOKEN" > "$SRC/GRAPH_REPORT.md"
    : > "$CADENCE_ALERT_FILE"
    run_publish "$SRC"
    check_eq "a secret blocks with rc 3" 3 "$PUB_RC"
    check_eq "branch untouched" "$GOOD_TIP" "$(branch_tip)"
    ALERTS="$(cat "$CADENCE_ALERT_FILE" 2>/dev/null)"
    check_has "the alert names the file" "GRAPH_REPORT.md" "$ALERTS"
    check_has "the alert names the gitleaks rule" "github-pat" "$ALERTS"
    check_lacks "the alert carries no secret text" "R4nd0m" "$ALERTS"
    check_lacks "the output carries no secret text" "R4nd0m" "$PUB_OUT"
else
    echo "  SKIP: gitleaks not on PATH (the CI image carries it)"
fi

echo "publish: no gitleaks is a block, never a pass"
make_src "$SRC" "$SEED_SHA"
PUB_RC=0
PUB_OUT="$(GRAPH_CHANNEL_GITLEAKS="$TMP/no-such-gitleaks" bash "$PUBLISH" --src "$SRC" --repo "$PUB" --remote "$BARE" 2>&1)" || PUB_RC=$?
if [ "$PUB_RC" -ne 0 ]; then ok "missing gitleaks exits non-zero"; else bad "missing gitleaks published"; fi
check_eq "branch untouched" "$GOOD_TIP" "$(branch_tip)"

# --- adopter side ----------------------------------------------------------
# make_adopter <dir> <bare> — a clone of <bare> carrying the scripts sync_graph
# runs (untracked copies, the way test-himmel-update-tools.sh builds its clone).
make_adopter() {
    local d="$1" b="$2" f
    rm -rf "$d"
    # --no-local: a local clone hardlinks every object, graph-data's included.
    git clone --quiet --no-local --single-branch --branch main "$b" "$d" || return 1
    mkdir -p "$d/scripts/guardrails" "$d/scripts/lib" "$d/scripts/graphify"
    for f in himmel-update.sh guardrails/lib.sh lib/cadence-format.sh lib/resolve-hermes-py.sh lib/load-dotenv.sh \
             lib/resolve-bun.sh lib/claude-version.sh graphify/check-graph-freshness.sh \
             graphify/semantic-update.sh graphify/semantic-merge.py; do
        cp "$HERE/$f" "$d/scripts/$f" || return 1
    done
    mkdir -p "$d/graphify-out"
    printf 'sentinel-graph\n' > "$d/graphify-out/graph.json"
}
run_update() {  # <adopter> <args...>
    local d="$1"; shift
    UP_RC=0
    UP_OUT="$(cd "$d" && bash scripts/himmel-update.sh "$@" 2>&1)" || UP_RC=$?
}
untouched() {  # <label> <adopter>
    check_eq "$1: graphify-out/graph.json untouched" "sentinel-graph" "$(cat "$2/graphify-out/graph.json" 2>/dev/null)"
    if [ -e "$2/graphify-out/.graphify_published" ]; then bad "$1: install marker written"; else ok "$1: no install marker"; fi
}
plan_batch() {  # <adopter> — files a semantic pass would extract now
    python3 "$1/scripts/graphify/semantic-merge.py" plan --root "$1" --out "$1/graphify-out" \
        --max-files 150 --plan "$TMP/plan.json" >/dev/null 2>&1 || { echo err; return; }
    python3 -c 'import json,sys;print(len(json.load(open(sys.argv[1]))["batch"]))' "$TMP/plan.json"
}

# Publish the good graph again for the fetch rows.
make_src "$SRC" "$SEED_SHA"
run_publish "$SRC"
check_eq "fetch fixture published" 0 "$PUB_RC"
DATA_TIP="$(branch_tip)"

ADO="$TMP/ado"
echo "fetch: fresh and an ancestor installs, then the semantic pass is skipped"
make_adopter "$ADO" "$BARE" || { echo "FAIL: adopter setup"; exit 1; }
BEFORE_BATCH="$(rm -f "$ADO/graphify-out/semantic-manifest.json"; plan_batch "$ADO")"
check_eq "control: before install a semantic pass would extract both docs" 2 "$BEFORE_BATCH"
run_update "$ADO" --only graph
check_eq "--only graph rc 0" 0 "$UP_RC"
check_eq "graph.json installed byte for byte" "$(cat "$SRC/graph.json")" "$(cat "$ADO/graphify-out/graph.json" 2>/dev/null)"
check_eq "GRAPH_REPORT.md installed" "$(cat "$SRC/GRAPH_REPORT.md")" "$(cat "$ADO/graphify-out/GRAPH_REPORT.md" 2>/dev/null)"
check_eq "manifest.json installed" "$(cat "$SRC/manifest.json")" "$(cat "$ADO/graphify-out/manifest.json" 2>/dev/null)"
check_eq "install marker holds the build commit" "$SEED_SHA" "$(cat "$ADO/graphify-out/.graphify_published" 2>/dev/null)"
check_has "status row says installed" "installed" "$(grep -E '^    graph ' <<< "$UP_OUT")"
check_eq "after install a semantic pass has nothing to extract" 0 "$(plan_batch "$ADO")"
if ls "$ADO/graphify-out"/.graph-fetch.* >/dev/null 2>&1; then bad "staging dir left behind"; else ok "no staging dir left behind"; fi
if [ -d "$ADO/graphify-out/.promote.lock" ]; then bad "promote lock left held"; else ok "promote lock released"; fi

echo "fetch: 150 commits behind installs, 151 falls back"
make_adopter "$ADO" "$BARE" || exit 1
for _i in $(seq 1 150); do gitq -C "$ADO" commit --quiet --allow-empty -m "chore: filler $_i"; done
run_update "$ADO" --only graph
check_eq "150 behind installs" "$SEED_SHA" "$(cat "$ADO/graphify-out/.graphify_published" 2>/dev/null)"
make_adopter "$ADO" "$BARE" || exit 1
for _i in $(seq 1 151); do gitq -C "$ADO" commit --quiet --allow-empty -m "chore: filler $_i"; done
run_update "$ADO" --only graph
check_eq "151 behind rc 0 (never aborts)" 0 "$UP_RC"
untouched "151 behind" "$ADO"
check_has "151 behind says AST-only" "AST-only" "$UP_OUT"
make_adopter "$ADO" "$BARE" || exit 1
gitq -C "$ADO" commit --quiet --allow-empty -m "chore: one ahead"
UP_RC=0
UP_OUT="$(cd "$ADO" && HIMMEL_UPDATE_GRAPH_MAX_BEHIND=0 bash scripts/himmel-update.sh --only graph 2>&1)" || UP_RC=$?
untouched "HIMMEL_UPDATE_GRAPH_MAX_BEHIND=0 with one commit ahead" "$ADO"

echo "fetch: a non-ancestor build commit falls back"
SIDE_SHA="$(gitq -C "$PUB" commit-tree "$(git -C "$PUB" rev-parse 'HEAD^{tree}')" -m "chore: side")"
make_src "$SRC" "$SIDE_SHA"
run_publish "$SRC"
check_eq "side fixture published" 0 "$PUB_RC"
make_adopter "$ADO" "$BARE" || exit 1
run_update "$ADO" --only graph
check_eq "non-ancestor rc 0" 0 "$UP_RC"
untouched "non-ancestor" "$ADO"
check_has "non-ancestor says AST-only" "AST-only" "$UP_OUT"

echo "fetch: a missing graph-data branch falls back"
BARE2="$TMP/origin2.git"
git clone --quiet --bare "$BARE" "$BARE2"
git -C "$BARE2" update-ref -d refs/heads/graph-data
make_adopter "$ADO" "$BARE2" || exit 1
run_update "$ADO" --only graph
check_eq "missing branch rc 0" 0 "$UP_RC"
untouched "missing branch" "$ADO"
check_has "missing branch says AST-only" "AST-only" "$UP_OUT"

# plant_branch <graph.json content> <built_at_commit content> — a hand-built
# graph-data tip that skipped the publisher's scan.
plant_branch() {
    local gj gr mf ba tree c
    gj="$(printf '%s\n' "$1" | git -C "$BARE" hash-object -w --stdin)"
    gr="$(printf '# r\n' | git -C "$BARE" hash-object -w --stdin)"
    mf="$(printf '{}\n' | git -C "$BARE" hash-object -w --stdin)"
    ba="$(printf '%s\n' "$2" | git -C "$BARE" hash-object -w --stdin)"
    tree="$(printf '100644 blob %s\tGRAPH_REPORT.md\n100644 blob %s\tbuilt_at_commit\n100644 blob %s\tgraph.json\n100644 blob %s\tmanifest.json\n' \
        "$gr" "$ba" "$gj" "$mf" | git -C "$BARE" mktree)"
    c="$(gitq -C "$BARE" commit-tree "$tree" -m "chore: planted")"
    git -C "$BARE" update-ref refs/heads/graph-data "$c"
}

echo "fetch: a host path in the fetched bytes falls back"
plant_branch "{\"nodes\":[{\"source_file\":\"/ho""me/mallory/x.md\"}],\"built_at_commit\":\"$SEED_SHA\"}" "$SEED_SHA"
make_adopter "$ADO" "$BARE" || exit 1
run_update "$ADO" --only graph
check_eq "tampered rc 0" 0 "$UP_RC"
untouched "host path in fetched bytes" "$ADO"
check_lacks "the fallback message carries no matched text" "mallory" "$UP_OUT"

echo "fetch: a built_at_commit file that disagrees with graph.json falls back"
plant_branch "{\"nodes\":[],\"built_at_commit\":\"$SIDE_SHA\"}" "$SEED_SHA"
make_adopter "$ADO" "$BARE" || exit 1
run_update "$ADO" --only graph
untouched "disagreeing built_at_commit" "$ADO"

# Restore the good branch for the last rows.
git -C "$BARE" update-ref refs/heads/graph-data "$DATA_TIP"

echo "fetch: the publisher station never installs"
make_adopter "$ADO" "$BARE" || exit 1
mkdir -p "$HOME/.himmel"
printf '{"graphify":{"semantic_api_ok":true}}\n' > "$HOME/.himmel/config.json"
run_update "$ADO" --only graph
check_eq "publisher rc 0" 0 "$UP_RC"
untouched "publisher station" "$ADO"
rm -f "$HOME/.himmel/config.json"

echo "fetch: --check reports what it would fetch and writes nothing"
make_adopter "$ADO" "$BARE" || exit 1
run_update "$ADO" --check
check_has "--check names the graph-data tip it would fetch" "$DATA_TIP" "$UP_OUT"
untouched "--check" "$ADO"
if git -C "$ADO" cat-file -e "$DATA_TIP" 2>/dev/null; then bad "--check fetched the graph-data commit"; else ok "--check fetched nothing from graph-data"; fi

echo ""
echo "test-himmel-update-graph-fetch: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
