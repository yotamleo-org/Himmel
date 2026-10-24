#!/usr/bin/env bash
# Project adoption of the merge gate, its trust policy and provenance.
# --merge-gate-only omits hook execution; default also checks merge behavior.
set -uo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" || exit 1
adopt="$repo_root/scripts/adopt.sh"
command -v jq >/dev/null 2>&1 || { echo 'FAIL: jq required' >&2; exit 1; }
fail() { echo "FAIL: $1" >&2; exit 1; }
grepq() { local _t="$1"; shift; grep -q "$@" <<< "$_t"; }

work=$(mktemp -d "${TMPDIR:-/tmp}/himmel-adopt-merge.XXXXXX") || exit 1
trap 'rm -rf "$work"' EXIT
export HIMMEL_PROVENANCE_DIR="$work/prov"
export CLAUDE_CONFIG_DIR="$work/claude-config"
saved_path="$PATH"
mkdir -p "$work/bin" || exit 1
cat > "$work/bin/claude" <<STUB || exit 1
#!/usr/bin/env bash
if [ "\$1" = "plugin" ] && [ "\$2" = "list" ]; then
  jq -r '.enabledPlugins | keys[]' "$repo_root/docs/setup/settings-template.json"
fi
exit 0
STUB
chmod +x "$work/bin/claude" || exit 1

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
qmd_free_path=$(scrub_path "$PATH" qmd bun npm node uv pipx) || exit 1
export PATH="$work/bin:$qmd_free_path"

# A missing portable gate or helper must not silently drop the merge refusal.
test_adopt_merge_gate() (
  unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE
  unset GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_NAMESPACE GIT_PREFIX
  local target="$work/merge-gate-project" home="$work/merge-gate-home" settings hook_cmd f rc out trust
  trust="$target/scripts/ci/ci-trust-paths.txt"
  mkdir -p "$target/.claude" "$home" "$work/merge-gate-bin"
  printf '{"permissions":{"allow":["Read"]},"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"echo adopter-hook","timeout":17}]}]}}\n' \
    > "$target/.claude/settings.json"
  HOME="$home" bash "$adopt" --profile core --scope project --target "$target" >/dev/null || exit 1
  for f in scripts/hooks/block-unresolved-cr-merge.sh \
      scripts/lib/review-merge-gate.sh scripts/lib/ci-green-gate.sh scripts/lib/go-gate.sh \
      scripts/lib/coderabbit-signal.sh scripts/lib/coderabbit-body-findings.sh \
      scripts/lib/coderabbit-available.sh scripts/lib/review-ledger-evidence.sh \
      scripts/lib/nwo.sh scripts/lib/critics-config.sh scripts/lib/resolve-node.sh \
      scripts/lib/timeout-bin.sh scripts/lib/handover-path.sh scripts/lib/load-dotenv.sh \
      scripts/lib/user-slug.sh scripts/lib/forge.sh scripts/lib/forge-github.sh \
      scripts/lib/forge-bitbucket.sh scripts/lib/forge-localgit.sh scripts/lib/forge-none.sh \
      scripts/lib/coderabbit-trigger-ledger.sh scripts/lib/project-mode.sh scripts/cr/critics.json; do
    [ -f "$target/$f" ] || fail "HIMMEL-7000: core/project did not copy $f"
    cmp -s "$repo_root/$f" "$target/$f" || fail "HIMMEL-7000: adopted trust dependency differs: $f"
  done
  [ -s "$trust" ] || fail "HIMMEL-7000: a fresh adopter has no trust list"
  settings="$target/.claude/settings.json"
  hook_cmd=$(jq -r '[.hooks.PreToolUse[] | select(.matcher == "Bash") | .hooks[] | select(.command | contains("block-unresolved-cr-merge.sh")) | .command] | if length == 1 then .[0] else empty end' "$settings")
  [ -n "$hook_cmd" ] || fail "HIMMEL-7000: core/project must wire exactly one Bash merge gate"
  jq -e '.permissions.allow == ["Read"] and any(.hooks.PreToolUse[].hooks[]; .command == "echo adopter-hook" and .timeout == 17)' "$settings" >/dev/null \
    || fail "HIMMEL-7000: merge gate wiring changed adopter settings"
  cp "$settings" "$work/merge-gate-before.json"
  HOME="$home" bash "$adopt" --profile core --scope project --target "$target" >/dev/null || exit 1
  cmp -s "$settings" "$work/merge-gate-before.json" || fail "HIMMEL-7000: merge gate wiring not idempotent"
  [ -s "$trust" ] || fail "HIMMEL-7000: a fresh adopter has no trust list"
  for f in scripts/hooks/block-unresolved-cr-merge.sh scripts/lib/review-merge-gate.sh \
      scripts/lib/go-gate.sh scripts/lib/ci-green-gate.sh scripts/lib/critics-config.sh \
      scripts/lib/user-slug.sh scripts/lib/resolve-node.sh .claude/settings.json; do
    grep -Eq -f "$trust" <<< "$f" || fail "HIMMEL-7000: seeded trust list does not cover $f"
  done
  HOME="$home" git -C "$target" init -q -b main || exit 1
  [ -d "$target/.git" ] || fail "HIMMEL-7000: inherited Git variables redirected fixture init outside the target"
  HOME="$home" git -C "$target" config user.name fixture || exit 1
  HOME="$home" git -C "$target" config user.email fixture@example.invalid || exit 1
  HOME="$home" git -C "$target" config --local himmel.coderabbit true || exit 1
  HOME="$home" git -C "$target" remote add origin https://github.com/adopter/project.git || exit 1
  HOME="$home" git -C "$target" add scripts/ci/ci-trust-paths.txt || exit 1
  HOME="$home" git -C "$target" -c commit.gpgsign=false commit -q -m 'chore: install merge trust policy' || exit 1
  printf '%s\n' \
    '{"kind":"avail","head":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","model":"codex","status":"ok"}' \
    '{"kind":"avail","head":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","model":"claude","status":"ok"}' \
    > "$target/.git/cr-critic-scores.jsonl"
  cat > "$work/merge-gate-bin/gh" <<'STUB' || exit 1
#!/usr/bin/env bash
case "$1 $2" in
  'pr view') printf '%s\n' '{"number":42,"headRefOid":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","url":"https://github.com/adopter/project/pull/42"}' ;;
  'repo view')
    case "$*" in
      *defaultBranchRef*) echo main ;;
      *'json url'*) echo https://github.com/adopter/project ;;
      *) echo adopter/project ;;
    esac ;;
  'api graphql')
    case "$*" in
      *reviewThreads*)
        jq -n --argjson resolved "$(cat .git/fixture-resolved)" '{data:{repository:{pullRequest:{reviewThreads:{pageInfo:{hasNextPage:false},nodes:[{isResolved:$resolved,path:"README.md",line:1,comments:{nodes:[{author:{login:"coderabbitai"}}]}}]}}}}}' ;;
      *reviews*) echo '{"data":{"repository":{"pullRequest":{"reviews":{"totalCount":0,"nodes":[]}}}}}' ;;
      *) exit 1 ;;
    esac ;;
  'api repos/adopter/project/contents/scripts/ci/ci-trust-paths.txt?ref=main')
    git show refs/heads/main:scripts/ci/ci-trust-paths.txt 2>/dev/null || { echo 'HTTP 404' >&2; exit 1; } ;;
  'api repos/adopter/project/pulls/42') echo 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa|1' ;;
  'api repos/adopter/project/pulls/42/files'*) printf 'README.md\t\n' ;;
  'api repos/adopter/project/commits/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/check-runs'*) echo '{"total_count":1,"check_runs":[{"name":"tests","status":"completed","conclusion":"success"}]}' ;;
  'api repos/adopter/project/commits/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/statuses'*) echo '[{"context":"ci","state":"success","creator":{"id":1}}]' ;;
  *) printf 'unexpected gh fixture request: %s\n' "$*" >&2; exit 1 ;;
esac
STUB
  chmod +x "$work/merge-gate-bin/gh" || exit 1
  for f in check-runs statuses; do
    rc=0; out=$("$work/merge-gate-bin/gh" api "repos/adopter/project/commits/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb/$f" 2>&1) || rc=$?
    [ "$rc" -ne 0 ] || fail "HIMMEL-7000: wrong-SHA $f query received green fixture data: $out"
  done
  echo "ok: HIMMEL-7000 gh fixture refuses check-runs and statuses for the wrong head"
  if [ "${1:-}" != --merge-gate-only ]; then
    jq -n --arg cwd "$target" '{tool_name:"Bash",cwd:$cwd,tool_input:{command:"gh pr merge 42 --squash --match-head-commit aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}}' > "$work/merge-gate-payload.json"
    merge_gate_run() (
      cd "$target" || exit 1
      unset GH GH_CMD CR_PROFILE CRITICS_JSON CRITICS_BASE_JSON CRITICS_LOCAL_JSON
      unset CR_MERGE_GATE_OK CI_MERGE_GATE_OK HIMMEL_CONSOLE_LEG HIMMELCTL_CACHE_DIR
      PATH="$work/merge-gate-bin:$saved_path" HOME="$home" CLAUDE_PROJECT_DIR="$target" \
        bash -c "$hook_cmd" < "$work/merge-gate-payload.json"
    )
    printf 'false\n' > "$target/.git/fixture-resolved"
    rc=0; out=$(merge_gate_run 2>&1) || rc=$?
    [ "$rc" -eq 2 ] || fail "HIMMEL-7000: unresolved finding must refuse (rc=$rc): $out"
    grepq "$out" 'unresolved CodeRabbit review thread' \
      || fail "HIMMEL-7000: merge refused for something other than the finding: $out"
    printf 'true\n' > "$target/.git/fixture-resolved"
    rc=0; out=$(merge_gate_run 2>&1) || rc=$?
    [ "$rc" -eq 0 ] || fail "HIMMEL-7000: resolved finding must allow a clean adopted merge (rc=$rc): $out"
    echo "ok: HIMMEL-7000 adopted hook refuses unresolved finding and allows resolved finding with green CI"
  fi
  core_lines=$(grep -Ev '^(#|$)' "$repo_root/scripts/ci/ci-trust-paths-core.txt") || fail "HIMMEL-7391: no core trust list"
  while IFS= read -r f; do
    grep -qxF -e "$f" "$trust" || fail "HIMMEL-7391: the seeded trust list lacks the core line $f"
  done <<< "$core_lines"
  echo "ok: HIMMEL-7391 the seeded trust list holds every core line"
  # The adopted repo judged through merge-on-green's anchor: a himmel stand-in
  # carrying the core list (any trust_path_check refusal there is exit 21).
  local anchor="$work/core-anchor" sha
  mkdir -p "$anchor/scripts/ci"
  HOME="$home" git -C "$anchor" init -q || exit 1
  HOME="$home" git -C "$anchor" remote add origin https://github.com/yotamleo-org/Himmel.git || exit 1
  cp "$repo_root/scripts/ci/ci-trust-paths-core.txt" "$anchor/scripts/ci/" || exit 1
  # A local bare origin stands in for GitHub, so a trust-path hit passes the
  # anchor-current check without the network; remote.origin.url stays github.com.
  HOME="$home" git -C "$anchor" add -A && HOME="$home" git -C "$anchor" -c user.name=fixture \
    -c user.email=fixture@example.invalid -c commit.gpgsign=false commit -q -m anchor || exit 1
  HOME="$home" git clone -q --bare "$anchor" "$work/core-anchor-origin.git" || exit 1
  HOME="$home" git -C "$anchor" config "url.$work/core-anchor-origin.git.insteadOf" https://github.com/yotamleo-org/Himmel.git || exit 1
  cat > "$work/core-gh" <<STUB || exit 1
#!/usr/bin/env bash
g() { git -C "$target" "\$@"; }
case "\$2" in
  repos/adopter/project/contents/*\?ref=main)
    f=\${2#repos/adopter/project/contents/}; f=\${f%%\?ref=main}
    g show "main:\$f" 2>/dev/null || { echo 'gh: Not Found (HTTP 404)' >&2; exit 1; } ;;
  repos/adopter/project/pulls/7) printf '%s|%s\n' "\$(g rev-parse pr)" "\$(g diff --name-only main...pr | wc -l | tr -d ' ')" ;;
  repos/adopter/project/pulls/7/files) g diff --name-only main...pr | sed 's/\$/\t/' ;;
  *) printf 'unexpected gh fixture request: %s\n' "\$*" >&2; exit 1 ;;
esac
STUB
  chmod +x "$work/core-gh" || exit 1
  core_pr() {  # <file>: branch pr off main touching <file>, print its head
    HOME="$home" git -C "$target" checkout -q -B pr main && printf 'pr\n' >> "$target/$1" \
      && HOME="$home" git -C "$target" add "$1" && HOME="$home" git -C "$target" -c commit.gpgsign=false commit -q -m pr \
      && HOME="$home" git -C "$target" checkout -q main && git -C "$target" rev-parse pr
  }
  core_check() {  # <head>: trust_path_check for PR 7 at <head> through the stand-in anchor
    GH="$work/core-gh" bash -c '. "$1"; shift; trust_path_check "$@"' _ "$repo_root/scripts/lib/go-gate.sh" adopter/project 7 "$1" main "$anchor" 2>&1
  }
  jq -e '.env.HIMMEL_REPO | type == "string" and length > 0' "$settings" >/dev/null \
    || fail "HIMMEL-7391: core/project did not record env.HIMMEL_REPO"
  HOME="$home" git -C "$target" add .claude/settings.json || exit 1
  # R6: the adopter declares its own trust path on the default branch.
  printf '^deploy/\n' >> "$trust" && mkdir -p "$target/deploy" "$target/src" \
    && printf 'deploy\n' > "$target/deploy/prod.sh" && printf 'app\n' > "$target/src/app.sh" \
    && HOME="$home" git -C "$target" add scripts/ci/ci-trust-paths.txt deploy src \
    && HOME="$home" git -C "$target" -c commit.gpgsign=false commit -q -m 'chore: declare deploy/ a trust path' || exit 1
  sha=$(core_pr deploy/prod.sh) || exit 1
  rc=0; out=$(core_check "$sha") || rc=$?
  [ "$rc:$out" = '0:hit deploy/prod.sh' ] \
    || fail "HIMMEL-6995 R6: an adopter-declared path is not a trust-path hit (rc=$rc): $out"
  # R7 (control): an undeclared path stays none.
  sha=$(core_pr src/app.sh) || exit 1
  rc=0; out=$(core_check "$sha") || rc=$?
  [ "$rc:$out" = '0:none' ] || fail "HIMMEL-6995 R7: an undeclared src/app.sh is not none (rc=$rc): $out"
  # R8 (control): the added line does not displace a core path.
  sha=$(core_pr .claude/settings.json) || exit 1
  rc=0; out=$(core_check "$sha") || rc=$?
  [ "$rc:$out" = '0:hit .claude/settings.json' ] \
    || fail "HIMMEL-6995 R8: a core path is not a hit beside an adopter line (rc=$rc): $out"
  echo "ok: HIMMEL-6995 an adopter-declared path is a trust-path hit; an undeclared path stays none; core paths still hit"
  # R2: the list lacks the core line for .claude/settings.json.
  grep -vxF '^[.]claude/settings[.]json$' "$trust" > "$work/core-trimmed" && cp "$work/core-trimmed" "$trust" || exit 1
  HOME="$home" git -C "$target" add scripts/ci/ci-trust-paths.txt || exit 1
  HOME="$home" git -C "$target" -c commit.gpgsign=false commit -q -m 'chore: trim the trust list' || exit 1
  sha=$(core_pr .claude/settings.json) || exit 1
  rc=0; out=$(core_check "$sha") || rc=$?
  [ "$rc:$out" = '2:list core-missing ^[.]claude/settings[.]json$' ] \
    || fail "HIMMEL-7391 R2: a trimmed adopter list let .claude/settings.json through (rc=$rc): $out"
  # R5 (control): the trimmed list and an undeclared README.md.
  printf 'readme\n' > "$target/README.md" && HOME="$home" git -C "$target" add README.md \
    && HOME="$home" git -C "$target" -c commit.gpgsign=false commit -q -m readme || exit 1
  sha=$(core_pr README.md) || exit 1
  rc=0; out=$(core_check "$sha") || rc=$?
  [ "$rc:$out" = '0:none' ] || fail "HIMMEL-7391 R5: an undeclared README.md is not none (rc=$rc): $out"
  # R1: the list is deleted on the default branch.
  HOME="$home" git -C "$target" rm -q scripts/ci/ci-trust-paths.txt \
    && HOME="$home" git -C "$target" -c commit.gpgsign=false commit -q -m 'chore: drop the trust list' || exit 1
  sha=$(core_pr .claude/settings.json) || exit 1
  rc=0; out=$(core_check "$sha") || rc=$?
  case "$rc:$out" in
    '2:list scripts/ci/ci-trust-paths.txt is missing on adopter/project@main'*adopted*) ;;
    *) fail "HIMMEL-7391 R1: an adopted repo with its list deleted was not refused (rc=$rc): $out" ;;
  esac
  echo "ok: HIMMEL-7391 an adopted repo's deleted or trimmed list refuses; an undeclared path stays none"
  printf '# adopter-owned list\n^private-policy/\n' > "$trust"
  HOME="$home" bash "$adopt" --profile core --scope project --target "$target" >/dev/null || exit 1
  [ "$(cat "$trust")" = $'# adopter-owned list\n^private-policy/' ] \
    || fail "HIMMEL-7000: re-adopt overwrote the adopter trust list"
  echo "ok: HIMMEL-7000 adopted merge gate and transitive helpers are byte-identical; wiring preserves settings and is idempotent; trust list is seeded but never overwritten"
  local fresh="$work/merge-gate-fresh-project" ledger="$work/merge-gate-fresh-ledger"
  mkdir -p "$fresh"
  HOME="$home" HIMMEL_PROVENANCE_DIR="$ledger" bash "$adopt" --profile core --scope project --target "$fresh" >/dev/null || exit 1
  jq -se '[.[] | select(.kind == "json-elem" and .unit == "/hooks/PreToolUse" and .op == "insert")] | length == 4 and all(.[]; .container_created == true)' "$ledger/provenance.jsonl" >/dev/null \
    || fail "HIMMEL-7000: every inserted hook must record ownership of the newly created PreToolUse container"
  jq -se '[.[] | select(.kind == "file" and .manifest_row == "adopter-scripts")] | length == 81' "$ledger/provenance.jsonl" >/dev/null \
    || fail "HIMMEL-7000: expected 80 portable file rows plus the trust policy seed"
  echo "ok: HIMMEL-7000 all four hooks record fresh-container ownership for uninstall; all 81 file rows recorded"
)

mkdir -p "$work/merge-gate-foreign-worktree"
GIT_DIR="$work/merge-gate-foreign.git" GIT_WORK_TREE="$work/merge-gate-foreign-worktree" test_adopt_merge_gate "${1:-}" || exit 1
[ ! -e "$work/merge-gate-foreign.git" ] || fail "HIMMEL-7000: fixture setup wrote the inherited Git directory"
