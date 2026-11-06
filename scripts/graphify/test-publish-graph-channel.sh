#!/usr/bin/env bash
# test-publish-graph-channel.sh — publish-graph-channel.sh against a publisher
# clone that carries the real pre-push branch-name hook (check-push-target.sh).
#
# The sibling suite scripts/test-himmel-update-graph-fetch.sh pushes from a repo
# with no hooks, so it never meets the hook that refuses 'graph-data' as a new
# branch name. Here the publisher clone's .git/hooks/pre-push runs the real hook.
#
# Hermetic: a local bare "origin" and a publisher clone in a temp dir, gitleaks
# and the alert sender stubbed through the script's own seams. No model call.
#
# Rows:
#   the first publish creates graph-data past the branch-name hook
#   a second publish (the branch now exists) still lands
#   a push the remote hook refuses names the hook's reason, in the output and the alert

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
PUBLISH="$HERE/publish-graph-channel.sh"
HOOK="$REPO_ROOT/scripts/hooks/check-push-target.sh"

# A bypass in the launching shell would hide the defect under test.
unset BRANCH_NAME_OK PRE_COMMIT PRE_COMMIT_REMOTE_BRANCH

TMP="$(mktemp -d "${TMPDIR:-/tmp}/test-publish-channel.XXXXXX")" || exit 1
trap 'rm -rf "$TMP"' EXIT

pass=0 fail=0
ok()  { pass=$((pass + 1)); echo "  PASS: $1"; }
bad() { fail=$((fail + 1)); echo "  FAIL: $1"; }
has() { grep -qF -- "$1" <<< "$2"; }
check_has() { if has "$2" "$3"; then ok "$1"; else bad "$1 — expected '$2', got: $3"; fi; }
check_eq()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 — expected '$2', got '$3'"; fi; }
gitq() { git -c user.email=t@test.test -c user.name=Test "$@"; }

BARE="$TMP/origin.git"
PUB="$TMP/pub"
git init --quiet --bare "$BARE"
git init --quiet --initial-branch=main "$PUB" 2>/dev/null || git init --quiet "$PUB"
printf '# alpha\n' > "$PUB/alpha.md"
gitq -C "$PUB" add -A
gitq -C "$PUB" commit --quiet -m "chore: seed"
gitq -C "$PUB" remote add origin "$BARE"
gitq -C "$PUB" push --quiet origin HEAD:refs/heads/main
SEED_SHA="$(git -C "$PUB" rev-parse HEAD)"

# The publisher's pre-push hook is the real branch-name hook.
mkdir -p "$PUB/.git/hooks"
printf '#!/usr/bin/env bash\nexec bash "%s" "$@"\n' "$HOOK" > "$PUB/.git/hooks/pre-push"
chmod +x "$PUB/.git/hooks/pre-push"

# Seams: gitleaks always clean, the alert records its arguments.
printf '#!/usr/bin/env bash\nexit 0\n' > "$TMP/gitleaks"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "%s/alerts.log"\n' "$TMP" > "$TMP/alert"
chmod +x "$TMP/gitleaks" "$TMP/alert"
export GRAPH_CHANNEL_GITLEAKS="$TMP/gitleaks" GRAPH_CHANNEL_ALERT="$TMP/alert"

SRC="$TMP/src"
mkdir -p "$SRC"
printf '{"nodes":[],"edges":[],"built_at_commit":"%s"}\n' "$SEED_SHA" > "$SRC/graph.json"
printf '# GRAPH_REPORT\n' > "$SRC/GRAPH_REPORT.md"
printf '{"alpha.md":{"mtime":0}}\n' > "$SRC/manifest.json"
printf '{"version":1,"files":{"alpha.md":"x"}}\n' > "$SRC/semantic-manifest.json"

run_publish() { PUB_RC=0; PUB_OUT="$(bash "$PUBLISH" --src "$SRC" --repo "$PUB" --remote "$BARE" 2>&1)" || PUB_RC=$?; }
tip() { git -C "$BARE" rev-parse --verify --quiet refs/heads/graph-data 2>/dev/null || echo none; }

echo "first publish: graph-data does not exist on the remote yet"
run_publish
check_eq "first publish rc 0" 0 "$PUB_RC"
if [ "$(tip)" != none ]; then ok "graph-data now exists on the remote"; else bad "graph-data absent after the first publish: $PUB_OUT"; fi

echo "second publish: the branch exists, the lease is on the old tip"
FIRST_TIP="$(tip)"
printf '{"nodes":[],"edges":[],"built_at_commit":"%s","rev":2}\n' "$SEED_SHA" > "$SRC/graph.json"
run_publish
check_eq "second publish rc 0" 0 "$PUB_RC"
if [ "$FIRST_TIP" != none ] && [ "$(tip)" != "$FIRST_TIP" ]; then ok "the second publish moved the tip"; else bad "tip did not move"; fi

echo "a hook refusal is named"
: > "$TMP/alerts.log"
printf '#!/usr/bin/env bash\necho "ERROR: remote policy says no (marker-9437)" >&2\nexit 1\n' > "$PUB/.git/hooks/pre-push"
git -C "$BARE" update-ref -d refs/heads/graph-data
run_publish
check_eq "a refused push exits 5" 5 "$PUB_RC"
check_has "the output names the hook's reason" "marker-9437" "$PUB_OUT"
check_has "the alert names the hook's reason" "marker-9437" "$(cat "$TMP/alerts.log")"
check_eq "the alert names it exactly once" 1 "$(grep -o 'marker-9437' "$TMP/alerts.log" | wc -l | tr -d ' ')"

echo
echo "passed: $pass, failed: $fail"
[ "$fail" -eq 0 ]
