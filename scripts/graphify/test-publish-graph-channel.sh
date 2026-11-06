#!/usr/bin/env bash
# test-publish-graph-channel.sh — publish-graph-channel.sh pushing through the REAL
# installed pre-push chain: pre-commit's own .git/hooks/pre-push shim, which runs
# pre-push.legacy (written by install-cr-pre-push-legacy.sh: check-push-target.sh, then
# check-cr-before-push.sh) and then the pre-push hooks of a .pre-commit-config.yaml
# that carries the repo's real pre-push entries (the npm and gh ones left out: they
# need the network).
#
# The fixture is a primary checkout with copies of the real hook scripts, a linked
# worktree on its own branch (its HEAD differs from the commit the publisher pushes) and
# a local bare origin. gitleaks and the alert sender are stubbed through the script's own
# seams. No model call.
#
# Rows:
#   the first publish and a second publish land on graph-data through the whole chain
#   the controls: another branch name, a ref that is not the worktree HEAD, a parentless
#     commit on another ref, and a mixed push naming graph-data are all still refused
#   a refusal from the chain is named in the output and in the alert, once, and the
#     alert claims no cause the publisher does not know (the tip moved, the remote refused)
#   an unrecognised refusal gets a neutral reason

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
PUBLISH="$HERE/publish-graph-channel.sh"

command -v pre-commit >/dev/null 2>&1 || { echo "SKIP: pre-commit not installed"; exit 0; }

# A bypass or a pre-commit env in the launching shell would change what the chain does.
unset BRANCH_NAME_OK PUSH_FOREIGN_REF_OK SKIP_CR PRE_COMMIT PRE_COMMIT_REMOTE_BRANCH PRE_COMMIT_TO_REF PRE_COMMIT_FROM_REF
unset GIT_DIR GIT_INDEX_FILE GIT_WORK_TREE GIT_PREFIX GIT_COMMON_DIR

TMP="$(mktemp -d "${TMPDIR:-/tmp}/test-publish-channel.XXXXXX")" || exit 1
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home"
mkdir -p "$HOME"

pass=0 fail=0
ok()  { pass=$((pass + 1)); echo "  PASS: $1"; }
bad() { fail=$((fail + 1)); echo "  FAIL: $1"; }
has() { grep -qF -- "$1" <<< "$2"; }
check_has()   { if has "$2" "$3"; then ok "$1"; else bad "$1 — expected '$2', got: $3"; fi; }
check_lacks() { if has "$2" "$3"; then bad "$1 — must not contain '$2', got: $3"; else ok "$1"; fi; }
check_eq()    { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 — expected '$2', got '$3'"; fi; }
gitq() { git -c user.email=t@test.test -c user.name=Test "$@"; }

BARE="$TMP/origin.git"
PRIMARY="$TMP/primary"
WT="$TMP/wt"
git init --quiet --bare "$BARE"
git init --quiet --initial-branch=main "$PRIMARY"
mkdir -p "$PRIMARY/scripts"
cp -R "$REPO_ROOT/scripts/hooks" "$REPO_ROOT/scripts/lib" "$REPO_ROOT/scripts/guardrails" "$REPO_ROOT/scripts/cr" \
      "$REPO_ROOT/scripts/ci" "$REPO_ROOT/scripts/testing" "$PRIMARY/scripts/"
cat > "$PRIMARY/.pre-commit-config.yaml" <<'YAML'
repos:
  - repo: local
    hooks:
      - {id: no-push-to-main, name: no-push-to-main, language: system, entry: bash scripts/hooks/check-push-target.sh, pass_filenames: false, always_run: true, stages: [pre-push]}
      - {id: no-new-hardcoded-env-values, name: no-new-hardcoded-env-values, language: system, entry: bash scripts/ci/check-hardcoded-env-values.sh, pass_filenames: false, always_run: true, stages: [pre-push]}
      - {id: added-unwired-check, name: added-unwired-check, language: system, entry: bash scripts/testing/check-added-unwired.sh --branch-diff, pass_filenames: false, always_run: true, stages: [pre-push]}
      - {id: code-review-before-push, name: code-review-before-push, language: system, entry: bash scripts/hooks/check-cr-before-push.sh, pass_filenames: false, always_run: true, stages: [pre-push]}
      - {id: no-force-push, name: no-force-push, language: system, entry: bash scripts/hooks/check-no-force-push.sh, pass_filenames: false, always_run: true, stages: [pre-push]}
      - {id: platforms-tested, name: platforms-tested, language: system, entry: bash scripts/hooks/check-platforms-tested.sh, pass_filenames: false, always_run: true, stages: [pre-push]}
      - {id: doc-guard-push, name: doc-guard-push, language: system, entry: bash scripts/hooks/check-doc-guard.sh --pre-push, pass_filenames: false, always_run: true, stages: [pre-push]}
      - {id: template-version-push, name: template-version-push, language: system, entry: bash scripts/hooks/check-template-version.sh --pre-push, pass_filenames: false, always_run: true, stages: [pre-push]}
      - {id: security-reviewed, name: security-reviewed, language: system, entry: bash scripts/hooks/check-security-reviewed.sh, pass_filenames: false, always_run: true, stages: [pre-push]}
YAML
printf '# alpha\n' > "$PRIMARY/alpha.md"
gitq -C "$PRIMARY" add -A
gitq -C "$PRIMARY" commit --quiet -m "chore: seed"
gitq -C "$PRIMARY" remote add origin "$BARE"
gitq -C "$PRIMARY" push --quiet origin HEAD:refs/heads/main 2>/dev/null
SEED_SHA="$(git -C "$PRIMARY" rev-parse HEAD)"

# The publisher runs from a linked worktree whose HEAD is not the pushed commit.
gitq -C "$PRIMARY" worktree add -q -b feat/work "$WT"
printf 'x\n' > "$WT/work.txt"
gitq -C "$WT" add -A
gitq -C "$WT" commit --quiet -m "feat: work"

# The real installer writes pre-push.legacy, then pre-commit writes its own shim, which runs it.
(cd "$PRIMARY" && bash scripts/hooks/install-cr-pre-push-legacy.sh >/dev/null && pre-commit install --hook-type pre-push >/dev/null 2>&1)
SHIM="$PRIMARY/.git/hooks/pre-push"
cp "$SHIM" "$TMP/shim.saved"

# Seams: gitleaks always clean, the alert records its arguments.
printf '#!/usr/bin/env bash\nexit 0\n' > "$TMP/gitleaks"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "%s/alerts.log"\n' "$TMP" > "$TMP/alert"
chmod +x "$TMP/gitleaks" "$TMP/alert"
export GRAPH_CHANNEL_GITLEAKS="$TMP/gitleaks" GRAPH_CHANNEL_ALERT="$TMP/alert"

# A git on PATH that logs the publisher's own push (the one carrying a lease on graph-data),
# so a row can pin what that push names.
REAL_GIT="$(command -v git)"
mkdir -p "$TMP/bin"
printf '#!/usr/bin/env bash\ncase "$*" in *" push "*force-with-lease=refs/heads/graph-data*) printf "%%s\\n" "$*" >> "%s/pushes.log";; esac\nexec "%s" "$@"\n' "$TMP" "$REAL_GIT" > "$TMP/bin/git"
chmod +x "$TMP/bin/git"
export PATH="$TMP/bin:$PATH"

SRC="$TMP/src"
mkdir -p "$SRC"
printf '{"nodes":[],"edges":[],"built_at_commit":"%s"}\n' "$SEED_SHA" > "$SRC/graph.json"
printf '# GRAPH_REPORT\n' > "$SRC/GRAPH_REPORT.md"
printf '{"alpha.md":{"mtime":0}}\n' > "$SRC/manifest.json"
printf '{"version":1,"files":{"alpha.md":"x"}}\n' > "$SRC/semantic-manifest.json"

run_publish() { PUB_RC=0; PUB_OUT="$(bash "$PUBLISH" --src "$SRC" --repo "$WT" --remote "$BARE" 2>&1)" || PUB_RC=$?; }
tip() { git -C "$BARE" rev-parse --verify --quiet refs/heads/graph-data 2>/dev/null || echo none; }
alerts() { cat "$TMP/alerts.log" 2>/dev/null; }
count_in() { grep -o -- "$1" <<< "$2" | wc -l | tr -d ' '; }
# A parentless commit, shaped like a publish commit, for the control pushes.
orphan() { GIT_AUTHOR_NAME=p GIT_AUTHOR_EMAIL=p@x.invalid GIT_COMMITTER_NAME=p GIT_COMMITTER_EMAIL=p@x.invalid \
    git -C "$WT" commit-tree "$(git -C "$WT" rev-parse "$SEED_SHA^{tree}")" -m "$1"; }

echo "first and second publish through the whole chain"
: > "$TMP/alerts.log"
run_publish
check_eq "first publish rc 0" 0 "$PUB_RC"
FIRST_TIP="$(tip)"
if [ "$FIRST_TIP" != none ]; then ok "graph-data now exists on the remote"; else bad "graph-data absent after the first publish: $PUB_OUT"; fi
printf '{"nodes":[],"edges":[],"built_at_commit":"%s","rev":2}\n' "$SEED_SHA" > "$SRC/graph.json"
run_publish
check_eq "second publish rc 0" 0 "$PUB_RC"
if [ "$FIRST_TIP" != none ] && [ "$(tip)" != "$FIRST_TIP" ]; then ok "the second publish moved the tip"; else bad "tip did not move: $PUB_OUT"; fi
# The flags reach every ref of a push, so the publisher's push must name exactly one:
# [-C <repo>] push --quiet --force-with-lease=<ref>:<old> <remote> <sha>:refs/heads/graph-data
check_eq "the publisher pushed twice" 2 "$(wc -l < "$TMP/pushes.log" | tr -d ' ')"
BAD_PUSHES="$(awk '{ for (i = 1; i <= NF; i++) if ($i == "push") break; n = NF - i
    if (n != 4 || $NF !~ /^[0-9a-f]{40}:refs\/heads\/graph-data$/) print }' "$TMP/pushes.log")"
check_eq "each publisher push names one remote and one refspec, the literal graph-data ref" "" "$BAD_PUSHES"

echo "controls: the flags the publisher sets reach nothing else"
BAD_RC=0
BAD_OUT="$(git -C "$WT" push origin HEAD:refs/heads/Bad_Name 2>&1)" || BAD_RC=$?
if [ "$BAD_RC" -ne 0 ]; then ok "a badly named new branch is refused"; else bad "a badly named new branch was pushed"; fi
check_has "it is refused by the branch-name gate" "branch name 'Bad_Name' is not allowed for a new branch" "$BAD_OUT"

FOREIGN_RC=0
FOREIGN_OUT="$(git -C "$WT" push origin "$SEED_SHA:refs/heads/feat/foreign" 2>&1)" || FOREIGN_RC=$?
if [ "$FOREIGN_RC" -ne 0 ]; then ok "a ref that is not the worktree HEAD is refused"; else bad "a foreign ref was pushed"; fi
check_has "it is refused by the foreign-ref gate" "check-cr-before-push: refusing" "$FOREIGN_OUT"

# An existing ref updated with a parentless commit: pre-commit then names the old and the
# new tip, and the base diff has no merge base. Only graph-data may skip that gate.
PUSH_FOREIGN_REF_OK=1 SKIP_CR=1 git -C "$WT" push -q origin HEAD:refs/heads/feat/exists >/dev/null 2>&1
EXISTS_TIP="$(git -C "$BARE" rev-parse --verify --quiet refs/heads/feat/exists || echo none)"
if [ "$EXISTS_TIP" != none ]; then ok "feat/exists is on the remote for the update control"; else bad "could not seed feat/exists"; fi
ORPH1="$(orphan one)"
ORPH_RC=0
ORPH_OUT="$(BRANCH_NAME_OK=1 PUSH_FOREIGN_REF_OK=1 SKIP_CR=1 git -C "$WT" push --force origin "$ORPH1:refs/heads/feat/exists" 2>&1)" || ORPH_RC=$?
if [ "$ORPH_RC" -ne 0 ]; then ok "a parentless commit on an existing other ref is refused even with all three flags"; else bad "a parentless commit updated feat/exists: $ORPH_OUT"; fi
check_eq "feat/exists did not move" "$EXISTS_TIP" "$(git -C "$BARE" rev-parse --verify --quiet refs/heads/feat/exists || echo none)"
printf '%s\n' "$ORPH_OUT" | sed 's/^/    | /'

# A push naming graph-data and another ref, from a caller that sets only the branch-name flag.
GD_TIP="$(tip)"
ORPH2="$(orphan two)"; ORPH3="$(orphan three)"
MIX_RC=0
MIX_OUT="$(BRANCH_NAME_OK=1 git -C "$WT" push origin "$ORPH2:refs/heads/graph-data" "$ORPH3:refs/heads/feat/mixed" 2>&1)" || MIX_RC=$?
if [ "$MIX_RC" -ne 0 ]; then ok "a mixed push of graph-data and another ref is refused"; else bad "a mixed push got through: $MIX_OUT"; fi
check_eq "graph-data did not move" "$GD_TIP" "$(tip)"
if git -C "$BARE" rev-parse --verify --quiet refs/heads/feat/mixed >/dev/null; then bad "feat/mixed reached the remote"; else ok "feat/mixed is absent from the remote"; fi
MIX2_RC=0
MIX2_OUT="$(BRANCH_NAME_OK=1 git -C "$WT" push origin "$ORPH3:refs/heads/feat/mixed" "$ORPH2:refs/heads/graph-data" 2>&1)" || MIX2_RC=$?
if [ "$MIX2_RC" -ne 0 ]; then ok "the same mixed push with the other ref first is refused"; else bad "a mixed push (other ref first) got through: $MIX2_OUT"; fi
check_eq "graph-data did not move (other ref first)" "$GD_TIP" "$(tip)"
if git -C "$BARE" rev-parse --verify --quiet refs/heads/feat/mixed >/dev/null; then bad "feat/mixed reached the remote (other ref first)"; else ok "feat/mixed is absent from the remote (other ref first)"; fi

echo "a refusal from the chain is named once, with no guessed cause"
: > "$TMP/alerts.log"
printf '#!/usr/bin/env bash\necho "ERROR: remote policy says no (marker-9437)" >&2\nexit 1\n' > "$SHIM"
run_publish
check_eq "a refused push exits 5" 5 "$PUB_RC"
check_has "the output names the hook's reason" "marker-9437" "$PUB_OUT"
check_eq "the alert names it exactly once" 1 "$(count_in 'marker-9437' "$(alerts)")"
check_lacks "the alert claims no cause it does not know" "the tip moved" "$(alerts)"

echo "an unrecognised refusal gets a neutral reason"
: > "$TMP/alerts.log"
printf '#!/usr/bin/env bash\necho "something unrecognisable on stderr" >&2\nexit 1\n' > "$SHIM"
run_publish
check_eq "a refused push exits 5" 5 "$PUB_RC"
check_has "the alert says no refusal line was recognised" "no refusal line recognised" "$(alerts)"
check_lacks "the alert claims no cause" "the tip moved" "$(alerts)"
check_lacks "the alert does not repeat the unrecognised text" "unrecognisable" "$(alerts)"

echo
echo "passed: $pass, failed: $fail"
[ "$fail" -eq 0 ]
