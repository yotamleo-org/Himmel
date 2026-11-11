#!/usr/bin/env bash
# scripts/cr/outside-security-audit.sh --pr <n> --head <40-hex sha>
#
# Stage 2 of the staged path for an unlisted outside author's PR (the outside-PR spec, section 6.3):
# reads the PR's diff as text, runs five hard checks on it and one codex critic call under the
# outside-security perspective, and writes one `security-audit` row for that exact head. Nothing
# from the PR's tree is run, sourced or checked out: the diff and the blobs are read with git
# diff --no-ext-diff --no-textconv and git cat-file, and only jq and grep parse them.
#
# Exit: 0 a row was written, whatever its verdict; prints `outside-audit: <verdict> <report>`.
#       2 a usage error, or the PR is not OPEN, not outside, or not at <head> (the fetch included).
#       6 stage 1 is incomplete at <head> (CodeRabbit, CI, or a lint-surface path).
#       7 no verdict: the size cap, an empty diff, a critic exit other than 0 or 4, no registry row,
#         no new score row, a trust_path_check refusal, or a record that could not be written.
#       8 the head is already audited (a fail row, or an ok row under the current perspective).
# Every non-zero exit writes no row. There is no verdict argument and no override flag. The anchor
# is the repo two directories above this file; no environment variable moves it, the cap or the
# ledger. Run it from the primary checkout, whose CR ledger outside_audit_passed reads.
set -uo pipefail
usage() { echo "usage: outside-security-audit.sh --pr <pr-number> --head <40-hex sha>" >&2; exit 2; }
[ "$#" -eq 4 ] && [ "$1" = --pr ] && [ "$3" = --head ] || usage
PR=$2 H=$4
[[ "$PR" =~ ^[1-9][0-9]{0,8}$ ]] && [[ "$H" =~ ^[0-9a-f]{40}$ ]] || usage
CAP=196608
LIFECYCLE='["preinstall","install","postinstall","prepare","prepack","postpack"]'
die() { local c=$1; shift; echo "outside-security-audit: $* - no audit row was written" >&2; exit "$c"; }
anchor=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd) || exit 2
lib="$anchor/scripts/lib"
command -v jq >/dev/null 2>&1 || die 2 "jq not found on PATH"
# shellcheck source=../lib/timeout-bin.sh
# shellcheck disable=SC1091
. "$lib/timeout-bin.sh" 2>/dev/null || _TIMEOUT_BIN=""
[ -n "${_TIMEOUT_BIN:-}" ] || die 2 "no GNU timeout on PATH, so the forge reads cannot be bounded"
# shellcheck source=../lib/git-clean.sh
# shellcheck disable=SC1091
. "$lib/git-clean.sh" 2>/dev/null || die 2 "cannot load scripts/lib/git-clean.sh"
git_env_scrub
# shellcheck source=../lib/outside-contributors.sh
. "$lib/outside-contributors.sh" 2>/dev/null || die 2 "cannot load scripts/lib/outside-contributors.sh"
# shellcheck source=../lib/prim.sh
. "$lib/prim.sh" 2>/dev/null || die 2 "cannot load scripts/lib/prim.sh"
gcd=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || die 2 "not inside a git repository" # swallow-ok: a failed read refuses on this line (exit 2)
ledger="$gcd/cr-critic-scores.jsonl"
persp="$anchor/scripts/cr/perspectives/outside-security.md"
[ -f "$persp" ] && [ -r "$persp" ] || die 7 "cannot read the perspective $persp"
psha=$(_oc_sha256 "$persp")
[[ "$psha" =~ ^[0-9a-f]{64}$ ]] || die 7 "cannot hash the perspective $persp"
gh_cmd=gh
[ ! -x "$lib/gh-read.sh" ] || gh_cmd="$lib/gh-read.sh"
work=$(tmpdir) || die 2 "cannot make a temp dir"
trap 'rm -rf "$work"' EXIT

# 1. read: outside, OPEN at exactly <head>, and not already audited.
# swallow-ok: any answer but yes is refused on the same line (exit 2)
rc_out=$(bash "$anchor/scripts/handover/chief-kit/ready-check.sh" --outside "$PR" 2>/dev/null </dev/null) || rc_out="${rc_out:-nothing}"
[ "$rc_out" = "outside-pr: yes" ] || die 2 "PR #$PR is not confirmed outside (ready-check.sh --outside said '$rc_out')"
# swallow-ok: a failed or malformed read refuses in this branch (exit 2)
if ! view=$("$_TIMEOUT_BIN" -k 5 20 "$gh_cmd" pr view "$PR" --json headRefOid,headRefName,baseRefName,state 2>/dev/null </dev/null) \
    || ! f=$(printf '%s' "$view" | jq -er '[.headRefName, .baseRefName, .headRefOid, .state]
        | select(all(.[]; type == "string" and length > 0 and (test("[\t\n]") | not))) | @tsv' 2>/dev/null); then
    die 2 "cannot read PR #$PR from the forge"
fi
IFS=$'\t' read -r branch base oid state <<< "$f"
[ "$state" = OPEN ] && [ "$oid" = "$H" ] || die 2 "PR #$PR is $state at $oid, not OPEN at $H"
if [[ "$branch" =~ [^A-Za-z0-9._/+-] ]] || [[ "$base" =~ [^A-Za-z0-9._/+-] ]]; then
    die 2 "PR #$PR's branch or base name is outside the safe alphabet [A-Za-z0-9._/+-]"
fi
# swallow-ok: a failed or malformed read refuses in this branch (exit 2)
if ! repo=$("$_TIMEOUT_BIN" -k 5 20 "$gh_cmd" repo view --json owner,name,defaultBranchRef 2>/dev/null </dev/null) \
    || ! r=$(printf '%s' "$repo" | jq -er '[.owner.login, .name, (.defaultBranchRef.name // "")]
        | select(all(.[]; type == "string" and length > 0 and (test("[\t\n /]") | not))) | @tsv' 2>/dev/null); then
    die 2 "cannot resolve the repository and its default branch"
fi
IFS=$'\t' read -r owner name defbranch <<< "$r"
if [ -e "$ledger" ]; then
    prior=$(jq -nRr --argjson pr "$PR" --arg h "$H" --arg ps "$psha" '
        [inputs | fromjson? | select(type == "object" and .kind == "security-audit" and .pr == $pr and .head == $h)] as $r
        | (([$r[] | select(.verdict == "fail")] | last) // ([$r[] | select(.status == "ok" and .perspective_sha256 == $ps)] | last))
        | select(. != null) | "\(.verdict) (report \(.report // "?"))"' "$ledger" 2>/dev/null) \
        || die 7 "cannot read the CR ledger $ledger"
    [ -z "$prior" ] || die 8 "PR #$PR at ${H:0:7} is already audited: $prior; a fail stays at this head and no verdict is re-rolled, so the way on is a new head"
fi

# 2. stage 1 at <head> (spec section 6.2). The CodeRabbit lib binds its pattern overrides when it
# is sourced, so it is sourced in a fresh child with all four unset.
# shellcheck disable=SC2016  # the body expands in the child shell
crs=$(env -u CR_OK_DESC_RE -u CR_SKIP_DESC_RE -u CR_BOT_USER_ID -u CR_STATUS_CONTEXT GH_CMD="$gh_cmd" \
    "$_TIMEOUT_BIN" -k 5 20 bash -c '. "$1" 2>/dev/null || exit 3; cr_signal_state "$2" "$3" "$4"' \
    _ "$lib/coderabbit-signal.sh" "$owner" "$name" "$H" 2>/dev/null </dev/null) || crs=unreadable
[ "$crs" = success ] || die 6 "stage 1 is incomplete: CodeRabbit at ${H:0:7} is ${crs:-unreadable}, want success (comment \`@coderabbitai review\` on the PR and wait for its status)"
ci_rc=0
env -u CR_APP -u CR_PROFILE -u CR_BOT_USER_ID -u CHECK_CI_DISTINCT_DEADLINE "$_TIMEOUT_BIN" -k 5 300 \
    bash "$anchor/scripts/check-ci.sh" "$PR" --max-wait 120 --except-context codeowner-review-gate >&2 </dev/null || ci_rc=$?
[ "$ci_rc" -eq 0 ] || die 6 "stage 1 is incomplete: check-ci.sh $PR --max-wait 120 --except-context codeowner-review-gate exited $ci_rc (every required context but the code-owner gate must be green at ${H:0:7})"

# 3. fetch: objects plus refs/himmel/outside/<n>, with no approval and no review round spent.
pco=$(HIMMEL_REPO="$anchor" bash "$anchor/scripts/cr/pr-check-outside.sh" --pr "$PR" --head "$H" --fetch-only </dev/null) \
    || die 2 "pr-check-outside.sh --pr $PR --head $H --fetch-only refused (see above)"
case "$pco" in "outside-pr: yes $PR $H "*) ;; *) die 2 "pr-check-outside.sh --fetch-only printed '$pco'" ;; esac
ref="refs/himmel/outside/$PR"
[ "$(git rev-parse --verify --quiet "$ref^{commit}" 2>/dev/null)" = "$H" ] || die 2 "$ref is not at $H" # swallow-ok: an unresolved ref differs from H and refuses here (exit 2)

# 4. the diff as text, always the full diff from the merge base.
M=$(outside_pr_merge_base "$PR" "$base") || die 7 "cannot compute the merge base of $ref with origin/$base"
gdiff() { git --no-pager -c core.quotePath=true diff --no-renames --no-ext-diff --no-textconv --no-color "$@"; }
gdiff --raw -z --no-abbrev "$M" "$ref" > "$work/raw" 2>/dev/null || die 7 "cannot list the files of $M..$ref"
gdiff "$M" "$ref" > "$work/diff" 2>/dev/null || die 7 "cannot read the diff $M..$ref"
lint_list="$anchor/scripts/ci/outside-lint-surface.txt"
[ -r "$lint_list" ] || die 6 "stage 1 cannot be shown complete: $lint_list is unreadable"
lint_pfx=$(sed -e 's/[[:space:]]*#.*$//' -e '/^[[:space:]]*$/d' "$lint_list")
zero=0000000000000000000000000000000000000000
: > "$work/files"
while IFS= read -r -d '' meta && IFS= read -r -d '' path; do
    read -r omode nmode osha nsha st <<< "${meta#:}"
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$omode" "$nmode" "$osha" "$nsha" "$st" "$path" >> "$work/files"
    while IFS= read -r pfx; do
        case "$path" in "$pfx"*) die 6 "stage 1 is incomplete: the PR touches $path, on scripts/ci/outside-lint-surface.txt, so CI's lint verdict is its own and 16d refuses it; the way on is a new head" ;; esac
    done <<< "$lint_pfx"
done < "$work/raw"
size=$(wc -c < "$work/diff" | tr -d ' ')
[ "$size" -gt 0 ] || die 7 "the diff $M..$ref is empty"
[ "$size" -le "$CAP" ] || die 7 "the diff is $size bytes, over the fixed $CAP-byte (192 KiB) cap; the way on is a smaller head (split the PR)"

# 5. hard checks: the script's own matching on the diff text and on blobs, never executed.
# Added lines, as "<+++ path>\t<line>", from hunks only (a header is never an added line).
awk '/^diff --git /{h=0; f=""; next} !h && /^\+\+\+ /{f=substr($0,5); next} /^@@ /{h=1; next} h && /^\+/{print f "\t" $0}' "$work/diff" > "$work/added"
hard=""; : > "$work/hits"
hit() { case ",$hard," in *",$1,"*) ;; *) hard="${hard:+$hard,}$1" ;; esac; printf -- '- %s: %s\n' "$1" "$2" >> "$work/hits"; }
bidi=$'\xe2\x80[\x8b-\x8f\xaa-\xae]|\xe2\x81[\xa6-\xa9]|\xef\xbb\xbf'
while IFS= read -r l; do hit H1 "a bidi or invisible character on an added line: $(printf '%s' "$l" | cat -v)"; done \
    < <(LC_ALL=C grep -E -- "$bidi" "$work/added")
h2_re='(^|/)(\.gitattributes|\.gitmodules|\.npmrc|bunfig\.toml|\.mcp\.json|\.coderabbit\.ya?ml)$|(^|/)(\.githooks|\.husky)/|(^|/)hooks/hooks\.json$|(^|/)\.claude/settings\.json$'
lifecycle() { # <blob sha>: the sorted lifecycle-key object of a package.json, or rc 1 when unparsable
    [ "$1" != "$zero" ] || { echo '{}'; return 0; }
    git cat-file blob "$1" 2>/dev/null | jq -cSse --argjson l "$LIFECYCLE" '
        if length == 1 and (.[0] | type) == "object" and ((.[0].scripts // {}) | type) == "object"
        then (.[0].scripts // {}) | with_entries(.key as $k | select(any($l[]; . == $k)))
        else error("not a package.json") end' 2>/dev/null
}
resolved() { # <blob sha>: every package-lock "resolved" off the default registry, or rc 1 when unparsable
    [ "$1" != "$zero" ] || return 0
    git cat-file blob "$1" 2>/dev/null | jq -rs '
        if length == 1 and (.[0] | type) == "object" then .[0] else error("not a lockfile") end
        | [.. | objects | select(has("resolved")) | .resolved
           | select(type != "string" or (startswith("https://registry.npmjs.org/") | not)) | tostring] | .[]' 2>/dev/null
}
while IFS=$'\t' read -r omode nmode osha nsha st path; do
    [[ "$path" =~ $h2_re ]] && hit H2 "$st $path"
    case "$nmode" in 120000|160000) hit H5 "$path gains mode $nmode" ;; esac
    case "$omode" in 120000|160000) [ "$st" = D ] || hit H5 "$path changes from mode $omode" ;; esac
    case "${path##*/}:$nmode:$omode" in
        package.json:120000:*|package.json:160000:*|package.json:*:120000|package.json:*:160000|package-lock.json:120000:*|package-lock.json:160000:*) continue ;;
    esac
    case "${path##*/}" in
        package.json)
            if ! lo=$(lifecycle "$osha") || ! ln=$(lifecycle "$nsha"); then hit H3 "$path is not a parsable package.json at one side"
            elif [ "$lo" != "$ln" ]; then hit H3 "$path lifecycle scripts $lo to $ln"; fi ;;
        package-lock.json)
            [ "$nsha" != "$zero" ] || continue
            if ! rn=$(resolved "$nsha"); then hit H4 "$path is not a parsable lockfile"; continue; fi
            ro=$(resolved "$osha") || ro=""
            while IFS= read -r s; do [ -z "$s" ] || hit H4 "$path resolves $s"; done \
                < <(grep -vxF -f <(printf '%s\n' "$ro") <<< "$rn")
            ;;
    esac
done < "$work/files"
while IFS=$'\t' read -r f l; do
    case "${f#b/}" in
        bun.lock|*/bun.lock)
            if printf '%s\n' "$l" | grep -qE '"(@[^"/]+/)?[^"@/]*@(git\+|git:|github:|gitlab:|bitbucket:|file:|link:|https?://)' \
                && ! printf '%s\n' "$l" | grep -qE '"(@[^"/]+/)?[^"@/]*@https://registry\.npmjs\.org/'; then
                hit H4 "${f#b/}: $(printf '%s' "$l" | cat -v)"
            fi ;;
        uv.lock|*/uv.lock)
            if printf '%s\n' "$l" | grep -qE 'source = \{[^}]*(git|url|path|directory) = |editable = "([^.]|\.[^"])' \
                || { printf '%s\n' "$l" | grep -qE 'registry = "' && ! printf '%s\n' "$l" | grep -qF 'registry = "https://pypi.org/simple"'; }; then
                hit H4 "${f#b/}: $(printf '%s' "$l" | cat -v)"
            fi ;;
    esac
done < "$work/added"

# 6. flags for the report and the request, never a verdict on their own.
unset -f trust_path_check 2>/dev/null || true
# shellcheck source=../lib/go-gate.sh
# shellcheck disable=SC1091
if ! . "$lib/go-gate.sh" 2>/dev/null || ! declare -F trust_path_check >/dev/null 2>&1; then
    die 7 "cannot load trust_path_check from $lib/go-gate.sh"
fi
tp_rc=0
tp=$(GH="$gh_cmd" trust_path_check "$owner/$name" "$PR" "$H" "$defbranch" "$anchor" </dev/null) || tp_rc=$?
[ "$tp_rc" -eq 0 ] || die 7 "trust_path_check refused (rc $tp_rc): ${tp:-no reason}"
binaries=$(sed -n 's/^Binary files \(.*\) differ$/\1/p' "$work/diff")

# 7. one codex critic call, routed by the anchor's tracked registry.
provider=$(jq -r '[.panel[]? | select(type == "object" and .model == "gpt-6.1-sol" and .drop != true and (.provider | type) == "string")]
    | first | .provider // empty' "$anchor/scripts/cr/critics.json" 2>/dev/null)
[ -n "$provider" ] || die 7 "the anchor's scripts/cr/critics.json has no row whose model is gpt-6.1-sol"
n0=0
[ ! -e "$ledger" ] || n0=$(wc -l < "$ledger" | tr -d ' ')
crit_rc=0
env -u CRITICS_BASE_JSON -u CR_LEDGER CR_TARGET_PR="$PR" CR_TARGET_HEAD="$H" CR_TARGET_BRANCH="$branch" \
    CRITIC_KNOWN_FINDINGS=0 CRITIC_PERSPECTIVES=1 CRITIC_FIRST_PASS_CAP_BYTES=$((CAP * 2)) \
    "$_TIMEOUT_BIN" -k 10 1200 bash "$anchor/scripts/cr/critic-first-pass.sh" --model gpt-6.1-sol --provider "$provider" \
    --slug outside-security --perspective-file "$persp" < "$work/diff" > "$work/critic.out" || crit_rc=$?
case "$crit_rc" in 0|4) ;; *) die 7 "the critic gave no verdict (critic-first-pass.sh exit $crit_rc); stage 2 stays unpassed and may be re-run" ;; esac

# 8. the counts, from the score row this call wrote (past the line count taken before it).
counts=$(tail -n +"$((n0 + 1))" "$ledger" 2>/dev/null | jq -nRr --arg h "$H" '
    [inputs | fromjson? | select(type == "object" and .kind == "score" and .head == $h and .model == "outside-security")] | last
    | select(. != null) | [(.critical // 0), (.important // 0), (.dropped // 0)] | map(tostring) | join(" ")' 2>/dev/null)
read -r crit_n imp_n drop_n <<< "$counts"
for v in "${crit_n:-}" "${imp_n:-}" "${drop_n:-}"; do
    [[ "$v" =~ ^[0-9]+$ ]] || die 7 "the critic wrote no outside-security score row at ${H:0:7} (exit $crit_rc)"
done

# 9. verdict and record (spec section 6.4).
if [ -n "$hard" ] || [ "$crit_n" -gt 0 ]; then verdict=fail
elif [ "$imp_n" -gt 0 ] || [ "$drop_n" -gt 0 ] || [ "$crit_rc" -eq 4 ]; then verdict=flagged
else verdict=pass; fi
(umask 077; mkdir -p "$gcd/outside-audits") || die 7 "cannot create $gcd/outside-audits"
report=""
for _ in 1 2 3; do
    report="$gcd/outside-audits/$PR-$H-$(date -u +%Y%m%dT%H%M%SZ).md"
    [ -e "$report" ] || break
    sleep 1; report=""
done
[ -n "$report" ] || die 7 "no free report name under $gcd/outside-audits"
{
    printf '# Outside security audit: PR #%s at %s\n\n' "$PR" "$H"
    printf -- '- verdict: %s\n- branch: %s, base %s, merge base %s\n' "$verdict" "$branch" "$base" "$M"
    printf -- '- hard: [%s]; critical %s, important %s, dropped %s; critic exit %s\n' "$hard" "$crit_n" "$imp_n" "$drop_n" "$crit_rc"
    printf -- '- auditor codex, model gpt-6.1-sol via %s; perspective sha256 %s; diff %s bytes\n\n' "$provider" "$psha" "$size"
    printf '## Hard hits\n\n'
    if [ -s "$work/hits" ]; then cat "$work/hits"; else echo "none"; fi
    printf '\n## Flags (never a verdict)\n\n- trust path: %s\n' "$tp"
    if [ -n "$binaries" ]; then printf '%s\n' "$binaries" | sed 's/^/- binary: /'; else echo "- binary: none"; fi
    printf '\n## Critic output (verbatim)\n\n'
    cat "$work/critic.out"
} | (umask 077; set -C; cat > "$report") || die 7 "cannot write the report $report"
rsha=$(_oc_sha256 "$report")
env -u CR_LEDGER bash "$anchor/scripts/cr/ledger-append.sh" security-audit --pr "$PR" --branch "$branch" --head "$H" \
    --base-sha "$M" --verdict "$verdict" --hard "$hard" --critical-n "$crit_n" --important-n "$imp_n" --dropped-n "$drop_n" \
    --critic-exit "$crit_rc" --model gpt-6.1-sol --perspective-sha256 "$psha" --report "$report" --report-sha256 "$rsha" >/dev/null \
    || die 7 "ledger-append.sh security-audit refused the row (the report $report stays)"
printf 'outside-audit: %s %s\n' "$verdict" "$report"
exit 0
