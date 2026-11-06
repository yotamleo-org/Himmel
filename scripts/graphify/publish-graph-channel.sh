#!/usr/bin/env bash
# publish-graph-channel.sh — publish one himmel graph to the graph-data branch.
# Adopters fetch that branch in himmel-update.sh
# (sync_graph) and skip their own paid semantic pass.
#
# graph-cadence.sh runs this after a semantic pass promoted cleanly. It:
#   1. refuses unless <src> holds graph.json, GRAPH_REPORT.md and manifest.json,
#      graph.json carries a literal built_at_commit, and the graph carries the
#      semantic layer (semantic-manifest.json with at least one stamped file);
#   2. copies exactly graph.json, GRAPH_REPORT.md and manifest.json into a
#      staging dir and writes a one-line built_at_commit file beside them.
#      graph.html, the cache, semantic-runs.jsonl and semantic-manifest.json are
#      never published;
#   3. scans those exact staged bytes: gitleaks (the repo's .gitleaks.toml) and
#      a host-path regex (home dirs, user-profile dirs, scratch dirs). Any hit
#      blocks the publish. No gitleaks, or a gitleaks error, blocks it too;
#   4. builds ONE orphan commit (no parent) of those four files and pushes it to
#      refs/heads/graph-data with --force-with-lease on the tip it just read.
# Every failure raises a cadence alert (scripts/luna/cadence-alert.sh, worker
# graph-channel-publish) naming the file and the rule, never the matched text;
# a clean publish clears it. No model call, no semantic pass.
#
# Usage:
#   publish-graph-channel.sh --src <graphify-out dir> --repo <git checkout>
#                            [--remote <name or url>] [--log <path>]
#   --remote defaults to $GRAPH_CHANNEL_REMOTE, else origin. The suite points it
#   at a local bare repo.
# Seams: GRAPH_CHANNEL_REMOTE, GRAPH_CHANNEL_GITLEAKS (default gitleaks),
#   GRAPH_CHANNEL_ALERT (default scripts/luna/cadence-alert.sh).
#
# Exit: 0 published; 1 usage; 2 not publishable (missing file, no semantic
#   layer, bad built_at_commit); 3 the scan found a hit; 4 the scan could not
#   run; 5 git or the push failed.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
# shellcheck source=../lib/prim.sh
. "$REPO_ROOT/scripts/lib/prim.sh" || { echo "publish-graph-channel: cannot load scripts/lib/prim.sh" >&2; exit 5; }
BRANCH_REF="refs/heads/graph-data"
WORKER="graph-channel-publish"
ALERT="${GRAPH_CHANNEL_ALERT:-$REPO_ROOT/scripts/luna/cadence-alert.sh}"
GITLEAKS="${GRAPH_CHANNEL_GITLEAKS:-gitleaks}"
FILES="graph.json GRAPH_REPORT.md manifest.json"
# Host paths that must never leave the station. A bare /tmp/ is not here: the
# graph quotes doc text such as /tmp/inv-<label>; the session scratch shape is.
HOST_PATH_RE='(/Users/|[A-Za-z]:\\Users\\|[A-Za-z]:/Users/|\\Users\\|/home/[^/]+/|(^|[/\\])AppData([/\\]|$)|/tmp/claude-[0-9]+/|/var/folders/)'

SRC="" REPO="" REMOTE="${GRAPH_CHANNEL_REMOTE:-origin}" LOG="-"
usage() { echo "usage: publish-graph-channel.sh --src <graphify-out dir> --repo <git checkout> [--remote <name or url>] [--log <path>]" >&2; exit 1; }
while [ $# -gt 0 ]; do
    case "$1" in
        --src) [ $# -ge 2 ] || usage; SRC="$2"; shift 2 ;;
        --repo) [ $# -ge 2 ] || usage; REPO="$2"; shift 2 ;;
        --remote) [ $# -ge 2 ] || usage; REMOTE="$2"; shift 2 ;;
        --log) [ $# -ge 2 ] || usage; LOG="$2"; shift 2 ;;
        -h|--help) usage ;;
        *) echo "publish-graph-channel: unknown argument '$1'" >&2; usage ;;
    esac
done
[ -n "$SRC" ] && [ -n "$REPO" ] && [ -n "$REMOTE" ] || usage

STAGE=""
# shellcheck disable=SC2329  # run by the EXIT trap below
cleanup() { [ -z "$STAGE" ] || rm -rf "$STAGE"; }
trap cleanup EXIT

# refuse <rc> <reason> — alert, say why, exit. <reason> never holds matched text.
refuse() {
    bash "$ALERT" fail "$WORKER" "graph-data publish blocked: $2" "$LOG" \
        "the published graph must be complete and clean" "fix the named file, the next cadence fire retries" >/dev/null 2>&1 || true
    echo "publish-graph-channel: BLOCKED $2" >&2
    exit "$1"
}

for f in $FILES; do
    [ -f "$SRC/$f" ] || refuse 2 "$f missing from $SRC"
done
python3 -c 'import json,sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
sys.exit(0 if isinstance(d, dict) and isinstance(d.get("files"), dict) and d["files"] else 1)' \
    "$SRC/semantic-manifest.json" 2>/dev/null \
    || refuse 2 "the graph carries no semantic layer (semantic-manifest.json missing or empty)"

STAGE="$(tmpdir)" || refuse 5 "could not create a staging dir"
for f in $FILES; do
    cp "$SRC/$f" "$STAGE/$f" || refuse 5 "could not stage $f"
done
# Read from the staged copy, so the marker always names the bytes published.
BAC="$(bash "$HERE/check-graph-freshness.sh" --out "$STAGE" --print-built-at 2>/dev/null)" \
    || refuse 2 "graph.json has no literal built_at_commit"
printf '%s\n' "$BAC" > "$STAGE/built_at_commit" || refuse 5 "could not write built_at_commit"

# --- the scan: exact staged bytes ------------------------------------------
for f in $FILES built_at_commit; do
    if grep -Eq -- "$HOST_PATH_RE" "$STAGE/$f"; then
        refuse 3 "file=$f rule=host-path"
    fi
done
command -v "$GITLEAKS" >/dev/null 2>&1 || refuse 4 "file=all rule=gitleaks-missing (no gitleaks on PATH, the scan cannot run)"
REPORT="$STAGE.gitleaks.json"
gl_rc=0
"$GITLEAKS" detect --no-git --no-banner --redact --log-level error -f json -r "$REPORT" \
    --config "$REPO_ROOT/.gitleaks.toml" --source "$STAGE" >/dev/null 2>&1 || gl_rc=$?
case "$gl_rc" in
    0) rm -f "$REPORT" ;;
    1)
        hits="$(python3 -c 'import json,os,sys
seen = []
for f in json.load(open(sys.argv[1], encoding="utf-8")):
    k = "file=%s rule=%s" % (os.path.basename(f.get("File", "?")), f.get("RuleID", "?"))
    if k not in seen:
        seen.append(k)
print("; ".join(seen) or "file=? rule=?")' "$REPORT" 2>/dev/null || echo "file=? rule=unreadable-report")"
        rm -f "$REPORT"
        refuse 3 "$hits"
        ;;
    *) rm -f "$REPORT"; refuse 4 "file=all rule=gitleaks-error (gitleaks exited $gl_rc)" ;;
esac

# --- the orphan commit and the push ----------------------------------------
G=(git -C "$REPO")
tree_in=""
for f in GRAPH_REPORT.md built_at_commit graph.json manifest.json; do
    blob="$("${G[@]}" hash-object -w -- "$STAGE/$f")" || refuse 5 "git hash-object failed for $f"
    tree_in="$tree_in$(printf '100644 blob %s\t%s' "$blob" "$f")
"
done
tree="$(printf '%s' "$tree_in" | "${G[@]}" mktree)" || refuse 5 "git mktree failed"
commit="$(GIT_AUTHOR_NAME="${GIT_AUTHOR_NAME:-himmel graph publisher}" GIT_AUTHOR_EMAIL="${GIT_AUTHOR_EMAIL:-graph-publisher@himmel.invalid}" \
    GIT_COMMITTER_NAME="${GIT_COMMITTER_NAME:-himmel graph publisher}" GIT_COMMITTER_EMAIL="${GIT_COMMITTER_EMAIL:-graph-publisher@himmel.invalid}" \
    "${G[@]}" commit-tree "$tree" -m "chore(graphify): graph-data built at $BAC")" || refuse 5 "git commit-tree failed"
ls_out="$("${G[@]}" ls-remote "$REMOTE" "$BRANCH_REF" 2>/dev/null)" || refuse 5 "git ls-remote $REMOTE failed"
old="${ls_out%%[[:space:]]*}"
"${G[@]}" push --quiet "--force-with-lease=$BRANCH_REF:$old" "$REMOTE" "$commit:$BRANCH_REF" >&2 \
    || refuse 5 "git push to $BRANCH_REF failed (the tip moved, or the remote refused)"

bash "$ALERT" clear "$WORKER" >/dev/null 2>&1 || true
echo "publish-graph-channel: published graph-data $commit (built at $BAC)"
exit 0
