#!/usr/bin/env bash
# An adopter with no Codex is not wedged at the merge gate after
# its first recorded review. Project adoption seeds a Claude-only reviewer
# overlay when no codex CLI is on PATH, and never when codex is present or the
# adopter already owns a critics.local.json.
set -uo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" || exit 1
adopt="$repo_root/scripts/adopt.sh"
command -v jq >/dev/null 2>&1 || { echo 'FAIL: jq required' >&2; exit 1; }
fail() { echo "FAIL: $1" >&2; exit 1; }
grepq() { local _t="$1"; shift; grep -q "$@" <<< "$_t"; }

work=$(mktemp -d "${TMPDIR:-/tmp}/himmel-adopt-claude-only.XXXXXX") || exit 1
trap 'rm -rf "$work"' EXIT
export HIMMEL_PROVENANCE_DIR="$work/prov"
export CLAUDE_CONFIG_DIR="$work/claude-config"
saved_path="$PATH"
mkdir -p "$work/bin" "$work/codex-bin" || exit 1
cat > "$work/bin/claude" <<STUB || exit 1
#!/usr/bin/env bash
if [ "\$1" = "plugin" ] && [ "\$2" = "list" ]; then
  jq -r '.enabledPlugins | keys[]' "$repo_root/docs/setup/settings-template.json"
fi
exit 0
STUB
chmod +x "$work/bin/claude" || exit 1
printf '#!/usr/bin/env bash\nexit 0\n' > "$work/codex-bin/codex" || exit 1
chmod +x "$work/codex-bin/codex" || exit 1

# shellcheck source=lib/hermetic-path.sh
# shellcheck disable=SC1091
. "$repo_root/scripts/lib/hermetic-path.sh" || exit 1
for _tool in bash git jq python3 grep sed cat cp mv rm ln mkdir chmod diff wc tr head tail basename dirname mktemp dd sort cut xargs date stat uname id awk cmp find; do
  link_hermetic_tool "$_tool" || exit 1
done
if command -v sha256sum >/dev/null 2>&1; then
  link_hermetic_tool sha256sum || exit 1
else
  link_hermetic_tool shasum || exit 1
fi
real_python3=$(command -v python3) || exit 1
rm -f "$work/bin/python3" || exit 1
cat > "$work/bin/python3" <<STUB || exit 1
#!/usr/bin/env bash
if [ "\$1" = "-m" ] && [ "\$2" = "pip" ]; then
  echo 'pip unavailable in offline test fixture' >&2
  exit 1
fi
exec "$real_python3" "\$@"
STUB
chmod +x "$work/bin/python3" || exit 1
qmd_free_path=$(scrub_path "$PATH" qmd bun npm node uv pipx codex) || exit 1
hermetic_path="$work/bin:$qmd_free_path"

HEAD40=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
cat > "$work/gh" <<STUB || exit 1
#!/usr/bin/env bash
case "\$1 \$2" in
  'pr view') printf '%s\n' '{"number":42,"headRefOid":"$HEAD40","url":"https://github.com/adopter/project/pull/42"}' ;;
  'repo view')
    case "\$*" in
      *defaultBranchRef*) echo main ;;
      *'json url'*) echo https://github.com/adopter/project ;;
      *) echo adopter/project ;;
    esac ;;
  'api graphql')
    case "\$*" in
      *reviewThreads*) echo '{"data":{"repository":{"pullRequest":{"reviewThreads":{"pageInfo":{"hasNextPage":false},"nodes":[]}}}}}' ;;
      *reviews*) echo '{"data":{"repository":{"pullRequest":{"reviews":{"totalCount":0,"nodes":[]}}}}}' ;;
      *) exit 1 ;;
    esac ;;
  'api repos/adopter/project/contents/scripts/ci/ci-trust-paths.txt?ref=main')
    git show refs/heads/main:scripts/ci/ci-trust-paths.txt 2>/dev/null || { echo 'HTTP 404' >&2; exit 1; } ;;
  'api repos/adopter/project/pulls/42') echo '$HEAD40|1' ;;
  'api repos/adopter/project/pulls/42/files'*) printf 'README.md\t\n' ;;
  'api repos/adopter/project/commits/$HEAD40/check-runs'*) echo '{"total_count":1,"check_runs":[{"name":"tests","status":"completed","conclusion":"success"}]}' ;;
  'api repos/adopter/project/commits/$HEAD40/statuses'*) echo '[{"context":"ci","state":"success","creator":{"id":1}}]' ;;
  *) printf 'unexpected gh fixture request: %s\n' "\$*" >&2; exit 1 ;;
esac
STUB
mkdir -p "$work/gh-bin" && mv "$work/gh" "$work/gh-bin/gh" && chmod +x "$work/gh-bin/gh" || exit 1
jq -n --arg h "$HEAD40" '{tool_name:"Bash",cwd:"",tool_input:{command:("gh pr merge 42 --squash --match-head-commit " + $h)}}' > "$work/payload.json" || exit 1

adopt_project() {
  local name="$1" pathv="$2" target="$work/$1" home="$work/$1-home"
  mkdir -p "$target/.claude" "$home"
  printf '{"permissions":{"allow":["Read"]}}\n' > "$target/.claude/settings.json"
  ( unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE
    HOME="$home" PATH="$pathv" bash "$adopt" --profile core --scope project --target "$target" >/dev/null ) || return 1
  ( unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE
    HOME="$home" git -C "$target" init -q -b main \
      && HOME="$home" git -C "$target" config user.name fixture \
      && HOME="$home" git -C "$target" config user.email fixture@example.invalid \
      && HOME="$home" git -C "$target" config --local himmel.coderabbit true \
      && HOME="$home" git -C "$target" remote add origin https://github.com/adopter/project.git \
      && HOME="$home" git -C "$target" add scripts/ci/ci-trust-paths.txt \
      && HOME="$home" git -C "$target" -c commit.gpgsign=false commit -q -m 'chore: install merge trust policy' ) || return 1
}

gate_run() {
  local name="$1" target="$work/$1" home="$work/$1-home" hook_cmd
  shift
  hook_cmd=$(jq -r '[.hooks.PreToolUse[] | select(.matcher == "Bash") | .hooks[] | select(.command | contains("block-unresolved-cr-merge.sh")) | .command] | if length == 1 then .[0] else empty end' "$target/.claude/settings.json")
  [ -n "$hook_cmd" ] || fail "$name: no merge gate wired"
  printf '%s\n' "$@" > "$target/.git/cr-critic-scores.jsonl"
  jq --arg cwd "$target" '.cwd = $cwd' "$work/payload.json" > "$work/payload-$name.json"
  (
    cd "$target" || exit 1
    unset GH GH_CMD CR_PROFILE CRITICS_JSON CRITICS_BASE_JSON CRITICS_LOCAL_JSON
    unset CR_MERGE_GATE_OK CI_MERGE_GATE_OK HIMMEL_CONSOLE_LEG HIMMELCTL_CACHE_DIR
    PATH="$work/gh-bin:$saved_path" HOME="$home" CLAUDE_PROJECT_DIR="$target" \
      bash -c "$hook_cmd" < "$work/payload-$name.json"
  )
}

claude_ok="{\"kind\":\"avail\",\"head\":\"$HEAD40\",\"model\":\"claude\",\"status\":\"ok\"}"
codex_ok="{\"kind\":\"avail\",\"head\":\"$HEAD40\",\"model\":\"codex\",\"status\":\"ok\"}"

adopt_project claude-only "$hermetic_path" || fail "C1: adopting the Claude-only project failed"
rc=0; out=$(gate_run claude-only "$claude_ok" 2>&1) || rc=$?
[ "$rc" -eq 0 ] || fail "C1: a Claude-only adopter with a Claude review at the head is held (rc=$rc): $out"
echo "ok: C1 a Claude-only adopter merges after its Claude review"

rc=0; out=$(gate_run claude-only 2>&1) || rc=$?
[ "$rc" -eq 2 ] || fail "C2: a Claude-only adopter with no review at the head must hold (rc=$rc): $out"
echo "ok: C2 a Claude-only adopter with no review at the head still holds"

overlay="$work/claude-only/scripts/cr/critics.local.json"
[ -f "$overlay" ] || fail "C3: no Claude-only overlay seeded"
jq -e '[.panel[] | select(.slug == "codex")][0] | .mode == "best-effort" and .required == false' "$overlay" >/dev/null \
  || fail "C3: the seeded overlay does not relax the codex row"
jq -e '[.panel[] | select(.slug == "claude")][0] | .mode == "hard"' "$overlay" >/dev/null \
  || fail "C3: the seeded overlay has no hard claude row"
echo "ok: C3 the seeded overlay relaxes codex and makes claude the hard reviewer"

adopt_project codex-station "$work/codex-bin:$hermetic_path" || fail "N1: adopting the codex project failed"
[ ! -e "$work/codex-station/scripts/cr/critics.local.json" ] || fail "N1: an overlay was seeded on a station that has codex"
rc=0; out=$(gate_run codex-station "$claude_ok" 2>&1) || rc=$?
[ "$rc" -eq 2 ] || fail "N1: a Codex-enabled adopter with no codex pass at the head must hold (rc=$rc): $out"
grepq "$out" 'codex' || fail "N1: the hold does not name codex: $out"
rc=0; out=$(gate_run codex-station "$codex_ok" 2>&1) || rc=$?
[ "$rc" -eq 0 ] || fail "N1: a Codex-enabled adopter with a codex pass must merge (rc=$rc): $out"
echo "ok: N1 a Codex-enabled adopter keeps codex hard and required"

mkdir -p "$work/owned/scripts/cr"
printf '{"panel":[{"slug":"coderabbit","mode":"hard"}]}\n' > "$work/owned/scripts/cr/critics.local.json"
adopt_project owned "$hermetic_path" || fail "N2: adopting with an existing overlay failed"
[ "$(cat "$work/owned/scripts/cr/critics.local.json")" = '{"panel":[{"slug":"coderabbit","mode":"hard"}]}' ] \
  || fail "N2: the adopter's own overlay was replaced"
echo "ok: N2 an adopter-owned overlay is kept"

cp "$overlay" "$work/overlay-before.json"
HOME="$work/claude-only-home" PATH="$hermetic_path" bash "$adopt" --profile core --scope project --target "$work/claude-only" >/dev/null || fail "N3: re-adopt failed"
cmp -s "$overlay" "$work/overlay-before.json" || fail "N3: re-adopt changed the seeded overlay"
echo "ok: N3 re-adopting leaves the seeded overlay as it was"

mkdir -p "$work/owned-commit/scripts/cr" "$work/owned-commit-home"
echo '{"panel":[]}' > "$work/owned-commit/scripts/cr/critics.local.json"
adopt_committed() {
  local target="$work/$1" home="$work/$1-home"
  mkdir -p "$target" "$home"
  unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE
  HOME="$home" git -C "$target" init -q -b main || return 1
  HOME="$home" git -C "$target" config user.name fixture || return 1
  HOME="$home" git -C "$target" config user.email fixture@example.invalid || return 1
  HOME="$home" git -C "$target" commit -q --allow-empty -m 'chore: initial commit' || return 1
  HOME="$home" PATH="$hermetic_path" bash "$adopt" --profile core --scope project --target "$target" --commit-install >/dev/null
}
adopt_committed owned-commit || fail "N4: adopting with --commit-install failed"
committed=$(git -C "$work/owned-commit" show --name-only --format= HEAD)
grepq "$committed" '^scripts/lib/review-merge-gate.sh$' || fail "N4: the install was not committed"
grepq "$committed" 'critics.local.json' && fail "N4: the install commit swept in the adopter's own overlay"
echo "ok: N4 the install commit leaves an adopter-owned overlay alone"

adopt_committed seeded-commit || fail "C4: adopting with --commit-install failed"
git -C "$work/seeded-commit" show --name-only --format= HEAD | grep -q '^scripts/cr/critics.local.json$' \
  || fail "C4: the install commit left the seeded overlay out"
echo "ok: C4 the install commit carries the seeded overlay"
