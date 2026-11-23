# shellcheck shell=bash
# sourced-lib: only ever sourced by the test-ready-check parts; the parts run in the environment their caller gives them
# shellcheck disable=SC2015,SC2034,SC2153,SC2154

HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/ready-check.sh"

tmp="$(mktemp -d "${TMPDIR:-/tmp}/ready-check-test.XXXXXX")" || { echo "FAIL: mktemp -d failed" >&2; exit 1; }  # prim-ok: the suite scratch dir, removed by its EXIT trap
trap 'rm -rf "$tmp"' EXIT
tmp="$(cd "$tmp" && pwd)"
fails=0
grepq() { local _t="$1"; shift; grep -q "$@" <<< "$_t"; }
check()    { [ "$2" = "$3" ] && echo "ok - $1" || { echo "FAIL - $1: [$2]!=[$3]"; fails=$((fails+1)); }; }
contains() { grepq "$2" -F -e "$3" && echo "ok - $1" || { echo "FAIL - $1: output does not contain [$3]"; fails=$((fails+1)); }; }
notcontains() { grepq "$2" -F -e "$3" && { echo "FAIL - $1: output contains [$3]"; fails=$((fails+1)); } || echo "ok - $1"; }

PR=77
NWO=acme/repo

# ── a throwaway git repo, since check 4 resolves the ledger via
# `git rev-parse --git-common-dir` from the caller's cwd ──────────────────
REPO="$tmp/repo"
mkdir -p "$REPO"
git -C "$REPO" init -q
git -C "$REPO" config user.email t@example.com
git -C "$REPO" config user.name tester
git -C "$REPO" commit -q --allow-empty -m "chore: init"
LEDGER="$REPO/.git/cr-critic-scores.jsonl"
# check 19 fetches origin/main and reads the range from it to a real head commit
git init -q --bare "$tmp/repo-origin.git"
git -C "$REPO" remote add origin "$tmp/repo-origin.git"
git -C "$REPO" push -q origin HEAD:refs/heads/main
git -C "$REPO" commit -q --allow-empty -m "feat(x): [HIMMEL-1] the PR head"
SHA=$(git -C "$REPO" rev-parse HEAD)

# ── gh PATH stub ─────────────────────────────────────────────────────────
mkdir -p "$tmp/bin"
GH_LOG="$tmp/gh.log"
gh_log() { cat "$GH_LOG"; }
ledger_cksum() { cksum < "$LEDGER"; }
ledger_lines() { wc -l < "$LEDGER"; }
export GH_PR_SNAPSHOT_CACHE_DIR="$tmp/snapshot-cache"
export STUB_OR_DIR="$tmp/or" GH_READ_ENV_ROOT="$tmp/envroot"
mkdir -p "$STUB_OR_DIR" "$GH_READ_ENV_ROOT"
cat > "$tmp/bin/gh" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$GH_LOG"
[ -z "${STUB_GH_STALL:-}" ] || sleep "$STUB_GH_STALL"
args="$*"
case "${STUB_GH_RL:-}" in
    1) echo "GraphQL: API rate limit already exceeded for user ID 1. (RATE_LIMIT)" >&2; exit 1 ;;
    late) case "$args" in "repo view"*) ;; *) echo "GraphQL: API rate limit already exceeded for user ID 1. (RATE_LIMIT)" >&2; exit 1 ;; esac ;;
esac
# owner-review reads (ready-check --owner-review): rows steer them with exported STUB_OR_* vars; STUB_OR_DIR holds the call counters
or_hang() { [ -z "${STUB_OR_HANG:-}" ] || exec sleep 600; }
case "$args" in
    "api repos/"*"/pulls/"*" --jq [.base.ref,.base.sha,.head.sha]|@tsv")
        or_hang
        [ -z "${STUB_OR_BASE_FAIL:-}" ] || { echo "gh: boom (HTTP 500)" >&2; exit 1; }
        n="${args#api repos/*/pulls/}"; n="${n%% *}"
        c="$STUB_OR_DIR/base.$n.count"; k=$(( $(cat "$c" 2>/dev/null || echo 0) + 1 )); echo "$k" > "$c"  # swallow-ok: an absent counter starts at zero
        h="${STUB_HEAD:-}"; b="${STUB_OR_BASE_SHA:-0123456789abcdef0123456789abcdef01234567}"
        if [ "$k" -ge 2 ]; then
            [ -z "${STUB_OR_MOVE_HEAD:-}" ] || h="$STUB_OR_MOVE_HEAD"
            [ -z "${STUB_OR_MOVE_BASE:-}" ] || b="$STUB_OR_MOVE_BASE"
        fi
        printf '%s\t%s\t%s\n' "${STUB_OR_BASE:-main}" "$b" "$h"; exit 0 ;;
    "api repos/{owner}/{repo}/rules/branches/"*)
        or_hang
        [ -z "${STUB_OR_RATELIMIT:-}" ] || { echo "gh: API rate limit exceeded for user ID 1. (HTTP 403)" >&2; exit 1; }
        [ -z "${STUB_OR_RULES_FAIL:-}" ] || { echo "gh: boom (HTTP 500)" >&2; exit 1; }
        if [ -n "${STUB_OR_NOGATE:-}" ]; then printf '[]'
        else printf '%s' '[{"type":"required_status_checks","parameters":{"required_status_checks":[{"context":"codeowner-review-gate","integration_id":15368}]}}]'; fi
        exit 0 ;;
    "api repos/{owner}/{repo}/branches/"*"/protection/required_status_checks")
        or_hang
        echo "gh: Branch not protected (HTTP 404)" >&2; exit 1 ;;
    "api -H Accept: application/vnd.github.raw repos/"*"/contents/scripts/ci/codeowner-review-gate.mjs?ref="*)
        or_hang
        echo "$args" >> "$STUB_OR_DIR/gate-fetch.log"
        [ -z "${STUB_OR_GATE_FAIL:-}" ] || { echo "gh: Not Found (HTTP 404)" >&2; exit 1; }
        cat "${STUB_OR_GATE_FILE:-/nonexistent}"; exit $? ;;  # read-sink-ok: a test stub serving the fixture gate script a row names
    "api -H Accept: application/vnd.github.raw repos/"*"/contents/.github/CODEOWNERS?ref="*)
        printf '%b' "${STUB_OR_CODEOWNERS:-* @alice\n}"; exit 0 ;;
    "api repos/"*"/collaborators/"*"/permission")
        echo "GH_TOKEN=${GH_TOKEN:-} $args" >> "$STUB_OR_DIR/gate-calls.log"
        p="${STUB_OR_PERM:-admin}"
        [ "$p" != none ] || { echo "gh: Not Found (HTTP 404)" >&2; exit 1; }
        printf '{"permission":"%s","role_name":"%s"}' "$p" "$p"; exit 0 ;;
    "api --paginate repos/"*"/reviews?per_page=100 --jq .[]")
        echo "GH_TOKEN=${GH_TOKEN:-} $args" >> "$STUB_OR_DIR/gate-calls.log"
        printf '%b' "${STUB_OR_REVIEWS:-}"; exit 0 ;;
    "api --paginate repos/"*"/files?per_page=100 --jq "*"@json")
        echo "GH_TOKEN=${GH_TOKEN:-} $args" >> "$STUB_OR_DIR/gate-calls.log"
        printf '%s\n' "${STUB_OR_FILES:-scripts/x.sh}" | while IFS= read -r f; do [ -z "$f" ] || jq -n --arg f "$f" '$f'; done; exit 0 ;;
    "api repos/"*"/pulls/"*)
        n="${args##*/pulls/}"
        case "$n" in
            ''|*[!0-9]*) ;;
            *)
                echo "GH_TOKEN=${GH_TOKEN:-} $args" >> "$STUB_OR_DIR/gate-calls.log"
                jq -n --arg a "${STUB_OR_AUTHOR:-yotamleo}" --arg t "${STUB_OR_AUTHOR_TYPE:-User}" --arg h "${STUB_HEAD:-}" \
                    '{user:{login:$a,type:$t},head:{sha:$h},changed_files:1}'; exit 0 ;;
        esac ;;
esac
# several PRs in one GraphQL call (STUB_OR_GQL=1): one snapshot row per alias; STUB_OR_BAD_PR makes that PR's head read fail
if [ -n "${STUB_OR_GQL:-}" ]; then
    case "$args" in
        "api repos/"*"/pulls/"*" --jq .head.sha")
            [ "${args#*/pulls/}" != "${STUB_OR_BAD_PR:-0} --jq .head.sha" ] || exit 1
            printf '%s\n' "${STUB_HEAD:-}"; exit 0 ;;
        *':pullRequest(number:'*)
            echo x >> "$STUB_OR_DIR/gql.count"
            [ -z "${STUB_OR_GQL_RATE:-}" ] || { echo "gh: API rate limit exceeded for user ID 1. (HTTP 403)" >&2; exit 1; }
            printf '%s' "$args" | grep -o 'p[0-9]*:pullRequest' | sed 's/^p//; s/:pullRequest$//' | jq -R -s --arg h "${STUB_HEAD:-}" '
                split("\n") | map(select(length > 0)) | map({key:("p"+.), value:{number:(.|tonumber),headRefOid:$h,headRefName:"b",title:"t",mergeStateStatus:"CLEAN",reviewDecision:null,isCrossRepository:false,
                author:{__typename:"User",login:"yotamleo",id:"U_stub"},body:"",
                commits:{nodes:[{commit:{oid:$h,messageHeadline:"feat(x): [HIMMEL-1] t",messageBody:"",parents:{totalCount:1}}}],pageInfo:{hasNextPage:false,endCursor:null}},
                reviewThreads:{nodes:[],pageInfo:{hasNextPage:false,endCursor:null}},
                statusCheckRollup:{contexts:{nodes:[{__typename:"CheckRun",name:"codeowner-review-gate",status:"COMPLETED",conclusion:"SKIPPED"}],pageInfo:{hasNextPage:false,endCursor:null}}}}}) | from_entries | {data:{repository:.}}'
            exit 0 ;;
    esac
fi
case "$args" in
    "repo view --json owner,name"*)
        if [ -n "${STUB_NWO_BY_CWD:-}" ]; then
            pwd -P >> "${STUB_CWD_LOG:-/dev/null}"
            n=$(git config --get ghstub.nwo 2>/dev/null) && [ -n "$n" ] || { echo "fatal: not a git repository (or no ghstub.nwo)" >&2; exit 1; }  # swallow-ok: a failed read prints its own error and exits 1 on this line
            printf '%s main\n' "$n"; exit 0
        fi
        [ -z "${STUB_DEFAULT_BRANCH_FAIL:-}" ] || { printf '%s\n' "${STUB_NWO:-acme/repo}"; exit 0; }
        printf '%s main\n' "${STUB_NWO:-acme/repo}" ;;
    *"--json headRefOid,mergeStateStatus"*)
        printf '%s %s\n' "${STUB_HEAD:-}" "${STUB_MSS:-CLEAN}" ;;
    *"--json headRefOid --jq"*)
        printf '%s\n' "${STUB_HEAD:-}" ;;
    *"--json statusCheckRollup"*)
        printf '%s' "${STUB_ROLLUP:-[]}" ;;
    *"--json commits"*)
        printf '%s' "${STUB_COMMITS:-[]}" ;;
    *"--json body"*)
        [ -n "${STUB_BODY_NULL:-}" ] || printf '%b' "${STUB_BODY:-}${STUB_RED:-}" ;;
    *"--json title"*)
        [ -z "${STUB_GH_TITLE_SLEEP:-}" ] || sleep 40
        printf '%s' "${STUB_PR_TITLE:-feat(x): [HIMMEL-100] thing}" ;;
    *"--json headRefName"*)
        printf '%s' "${STUB_PR_BRANCH-feat/himmel-100-thing}" ;;
    *"--json author"*)
        if [ -n "${STUB_AUTHOR_EMPTY:-}" ]; then echo; else printf '%s\n' "${STUB_AUTHOR:-yotamleo}"; fi ;;
    *"contents/scripts/ci/ci-trust-paths.txt"*)
        [ -z "${STUB_TRUST_LIST_FAIL:-}" ] || { echo "boom" >&2; exit 1; }
        cat "$STUB_TRUST_LIST_FILE" ;;
    "api repos/"*"/actions/runs/"*)
        # check 19: the run's head_sha (STUB_RUN_HEAD_SHA, default the PR head), through the script's own --jq
        [ -z "${STUB_RUN_SLEEP:-}" ] || sleep "$STUB_RUN_SLEEP"
        id="${args#*/actions/runs/}"; id="${id%% *}"
        conc=success
        for kv in ${STUB_RUN_CONC:-}; do [ "${kv%%=*}" = "$id" ] && conc="${kv#*=}"; done
        jq -n --argjson id "$id" --arg h "${STUB_RUN_HEAD_SHA:-$STUB_HEAD}" --arg c "$conc" '{id:$id,head_sha:$h,status:"completed",conclusion:$c}' | jq -r "${args#*--jq }" ;;
    "run download "*)
        [ -z "${STUB_DL_STARTED:-}" ] || : > "$STUB_DL_STARTED"
        [ -z "${STUB_DL_SLEEP:-}" ] || sleep "$STUB_DL_SLEEP"
        d="${args#* -D }"; d="${d%% *}"
        case "$args" in
            *" -p js-suite-manifest-"*)
                [ -z "${STUB_JS_DL_FAIL:-}" ] || { echo "HTTP 502" >&2; exit 1; }
                id="${args#run download }"; id="${id%% *}"
                [ -d "${STUB_JS_MANIFEST_DIR:-/nonexistent}/$id" ] || { echo "no valid artifacts found to download" >&2; exit 1; }
                cp -R "$STUB_JS_MANIFEST_DIR/$id"/. "$d"/ ;;
            *)
                [ -z "${STUB_DL_FAIL:-}" ] || { echo "HTTP 500" >&2; exit 1; }
                [ -d "${STUB_MANIFEST_DIR:-/nonexistent}" ] || { echo "no valid artifacts found to download" >&2; exit 1; }
                cp -R "$STUB_MANIFEST_DIR"/. "$d"/ ;;
        esac ;;
    "api --paginate repos/"*"/actions/runs/"*"/jobs"*)
        [ -z "${STUB_JOBS_FAIL:-}" ] || { echo "HTTP 502" >&2; exit 1; }
        printf '%s\n' "${STUB_JOBS:-success|lanes-and-trust-suites
success|bun-suites (ubuntu-latest)
success|node-suites (jira)
success|node-suites (himmel-gh, plugins/himmel-gh)
success|node-suites (himmel-bus, marketplace/plugins/himmel-bus, 26.13.0)
success|shell-unit (ubuntu-latest)}" \
            | jq -R -n '{total_count: 0, jobs: [inputs | select(length > 0) | index("|") as $i | {conclusion: .[:$i], name: .[$i + 1:]}]}' \
            | jq -r "${args#*--jq }" ;;
    "api repos/"*"/pulls/"*"/files --paginate"*)
        printf '%s\n' "${STUB_FILES:-README.md}" | while IFS= read -r f; do printf '%s\t\n' "$f"; done ;;
    "api repos/"*"/pulls/"*"changed_files"*)
        printf '%s|%s\n' "${STUB_HEAD:-}" "$(printf '%s\n' "${STUB_FILES:-README.md}" | wc -l | tr -d ' ')" ;;
    'api repos/'*'/pulls/'*) printf '%s\n' "${STUB_HEAD:-}" ;;
    *'p77:pullRequest'*)
        [ -z "${STUB_SNAPSHOT_FAIL:-}" ] || exit 1
        if [ -n "${STUB_HOLD_MARK:-}" ] && [ ! -e "$STUB_HOLD_MARK" ]; then
            ( STUB_HOLD_MARK='' STUB_GH_STALL=600 "$STUB_HOLD_TIMEOUT" -k 2 "${STUB_HOLD_LIFE:-40}" bash "$STUB_HOLD_LIB" "${STUB_NWO:-acme/repo}" 0 77 < /dev/null > /dev/null 2>&1 &
              echo "$!" > "$STUB_HOLD_MARK" )
        fi
        jq -n --arg h "$STUB_HEAD" --arg m "${STUB_MSS:-CLEAN}" \
            --argjson rollup "${STUB_ROLLUP:-[]}" --argjson commits "${STUB_COMMITS:-[]}" \
            --arg merges "${STUB_MERGE_OIDS:-}" --argjson u "${STUB_UNRESOLVED:-0}" \
            --arg body "$(printf '%b' "${STUB_BODY:-}${STUB_RED:-}")" --arg title "${STUB_PR_TITLE:-feat(x): [HIMMEL-100] thing}" \
            --argjson fork "${STUB_FORK_JSON:-false}" --arg resolved "${STUB_RESOLVED_BY:-}" '
            # author: STUB_AUTHOR (default yotamleo; app/<x> is a Bot), STUB_AUTHOR_TYPE, STUB_AUTHOR_ID; STUB_AUTHOR_EMPTY = a deleted account
            ((env.STUB_AUTHOR // "") | if . == "" then "yotamleo" else . end) as $a
            | (if (env.STUB_AUTHOR_EMPTY // "") != "" then null
               elif ($a | startswith("app/")) then {__typename:"Bot",login:($a | ltrimstr("app/")),id:"BOT_kgDOstub"}
               else {__typename:((env.STUB_AUTHOR_TYPE // "") | if . == "" then "User" else . end),login:$a}
                    + (if (env.STUB_AUTHOR_ID // "") != "" then {id:env.STUB_AUTHOR_ID} else {} end) end) as $author
            # STUB_RESOLVED_BY: comma list, one resolved thread per entry, `null` = no resolver
            | ($resolved | split(",") | map(select(length > 0)) | map({isResolved:true,resolvedBy:(if . == "null" then null else {login:.} end)})) as $res
            | {data:{repository:{p77:{number:77,headRefOid:$h,headRefName:env.STUB_PR_BRANCH,title:$title,mergeStateStatus:$m,reviewDecision:(if (env.STUB_OR_RD // "") == "" then null else env.STUB_OR_RD end),body:(if (env.STUB_BODY_NULL // "") != "" then null else $body end),
                author:$author,isCrossRepository:$fork,
                commits:{nodes:[$commits[] | . as $commit | {commit:(. + {oid:(.oid // $h),parents:{totalCount:(if (($merges|split("\n")) | index($commit.oid // "")) != null then 2 else 1 end)}})}],pageInfo:{hasNextPage:false,endCursor:null}},
                reviewThreads:{nodes:([range($u)|{isResolved:false,resolvedBy:null}] + $res),pageInfo:{hasNextPage:false,endCursor:null}},
                statusCheckRollup:(if (env.STUB_ROLLUP_NULL // "") != "" then null else {contexts:{nodes:[$rollup[] | . + {__typename:(if has("conclusion") then "CheckRun" else "StatusContext" end)} | if has("workflowName") then . + {checkSuite:{workflowRun:{workflow:{name:.workflowName}}}} else . end],pageInfo:{hasNextPage:false,endCursor:null}}} end)
            }}}}' ;;
    *"commits(first:100)"*)
        printf '%s\n' "${STUB_MERGE_OIDS:-}" ;;
    *"api graphql"*)
        printf '%s %s %s\n' "${STUB_UNRESOLVED:-0}" "false" "null" ;;
    *"api --paginate"*"/files"*'select(.status'*)
        # run the script's own --jq filter over a files array, so the status filter is really exercised
        printf '%s\n' "${STUB_FILE_STATUS:-}" | jq -R -n '[inputs | select(length > 0) | split(" ") | {status: .[0], filename: .[1]}]' \
            | jq -r "${args#*--jq }" ;;
    "api -H Accept: application/vnd.github.raw repos/"*"/contents/"*)
        f="${args#*/contents/}"; f="${f%%\?ref=*}"
        [ -f "${STUB_WF_DIR:-/nonexistent}/${f##*/}" ] || exit 1
        cat "$STUB_WF_DIR/${f##*/}" ;;
    "run list"*)
        [ -z "${STUB_RUNS_FAIL:-}" ] || exit 1
        w="${args#*--workflow }"; w="${w%% *}"
        case "$args" in *"--branch main "*) w="$w.main" ;; *"--branch ${STUB_PR_BRANCH:-@}"*) w="$w.pr-branch" ;; *"--branch "*) w="$w.other-branch" ;; esac
        f="${args#*--json }"; f="${f%% *}"
        if [ -f "${STUB_RUNS_DIR:-/nonexistent}/$w.json" ]; then jq -c --arg f "$f" '($f | split(",")) as $k | map(with_entries(select(.key as $n | $k | index($n))))' "$STUB_RUNS_DIR/$w.json"; else printf '[]'; fi ;;
    "run view "*)
        [ -z "${STUB_RUNS_FAIL:-}" ] || exit 1
        id="${args#run view }"; id="${id%% *}"
        case "$args" in *" --log"*)
            if [ -f "${STUB_RUNS_DIR:-/nonexistent}/log-$id.txt" ]; then cat "$STUB_RUNS_DIR/log-$id.txt"; exit 0; else exit 1; fi ;;
        esac
        if [ -f "${STUB_RUNS_DIR:-/nonexistent}/jobs-$id.json" ]; then cat "$STUB_RUNS_DIR/jobs-$id.json"; else exit 1; fi ;;
    *"api --paginate"*"/files"*'.filename, (.previous_filename'*)
        # item 16: every new path, then the old path of each STUB_RENAMES "new old" line
        [ -z "${STUB_FILES16_FAIL:-}" ] || exit 1
        [ -n "${STUB_FILES16_EMPTY:-}" ] || printf '%s\n' "${STUB_FILES:-README.md}"
        printf '%s\n' "${STUB_RENAMES:-}" | awk 'NF == 2 { print $2 }' ;;
    *"api --paginate"*"/files"*"previous_filename"*)
        [ -z "${STUB_RENAMES_FAIL:-}" ] || exit 1
        # STUB_RENAMES lines "new old": run the script's own --jq filter over a files array
        printf '%s\n' "${STUB_RENAMES:-}" | jq -R -n '[inputs | select(length > 0) | split(" ") | {filename: .[0], previous_filename: .[1]}]' \
            | jq -r "${args#*--jq }" ;;
    *"api --paginate"*"/files"*".patch"*)
        # the diff of one file: STUB_WF_PATCH_FILE is its `patch` field, absent = unavailable
        [ -f "${STUB_WF_PATCH_FILE:-/nonexistent}" ] || exit 1
        cat "$STUB_WF_PATCH_FILE" ;;
    *"api --paginate"*"/files"*"filename"*)
        [ -n "${STUB_FILES_FAIL:-}" ] && exit 1
        printf '%s\n' "${STUB_FILES:-README.md}"
        [ -z "${STUB_FILES_PARTIAL:-}" ] || exit 1  # a --paginate that died after its first page
        ;;
    "api repos/${STUB_NWO:-acme/repo}/commits/${STUB_HEAD:-no-head}/statuses"*)
        # check 15: the CodeRabbit commit status of THIS repo and head only; STUB_CR_DESC unset = unreadable
        [ -z "${STUB_CR_SLEEP:-}" ] || sleep 40
        [ -z "${STUB_CR_STATUSES:-}" ] || { printf '%s\n' "$STUB_CR_STATUSES"; exit 0; }
        [ -n "${STUB_CR_DESC+x}" ] || exit 1
        jq -n --arg d "$STUB_CR_DESC" --arg st "${STUB_CR_STATE:-success}" '[{context:"CodeRabbit",state:$st,description:$d,created_at:"2026-11-02T18:44:07Z",creator:{id:136622811,login:"coderabbitai[bot]",type:"Bot"}}]' ;;
    *)
        echo "gh-stub: unhandled args: $args" >&2
        exit 1 ;;
esac
STUB
chmod +x "$tmp/bin/gh"

# ── jira stub (JIRA_CMD): `get KEY [--json]` reads STUB_JIRA_DB lines
# "KEY<TAB>Status<TAB>Labels<TAB>Description<TAB>Type"; an absent key is the real CLI's HTTP 404, STUB_JIRA_DOWN=1 is an outage ────
cat > "$tmp/bin/jira-stub" <<'STUB'
#!/usr/bin/env bash
if [ "$1" = "links" ]; then
    [ -n "${STUB_LINKS_FAIL:-}" ] && { echo "jira: links $2 failed: connect ECONNREFUSED" >&2; exit 1; }
    # STUB_LINKS_DB lines "KEY<TAB>KEY": one issue link; prints the real CLI's `links` row shape for each one touching $2
    awk -F'\t' -v k="$2" '$1 == k || $2 == k { printf "%d\tRelates\tinward=%s\toutward=%s\t%s relates to %s\n", NR, $1, $2, $1, $2 }' "${STUB_LINKS_DB:-/dev/null}"
    exit 0
fi
[ "$1" = "get" ] || { echo "jira-stub: unhandled: $*" >&2; exit 1; }
[ -n "${STUB_JIRA_DOWN:-}" ] && { echo "jira: get $2 failed: connect ECONNREFUSED" >&2; exit 1; }
[ "$2" != "${STUB_JIRA_SLEEP_KEY:-}" ] || sleep 40
kc=$(printf '%s' "$2" | sed -E 's/-0+([0-9])/-\1/')
st=$(awk -F'\t' -v k="$kc" '$1 == k { print $2 }' "${STUB_JIRA_DB:-/dev/null}")
lb=$(awk -F'\t' -v k="$kc" '$1 == k { print $3 }' "${STUB_JIRA_DB:-/dev/null}")
desc=$(awk -F'\t' -v k="$kc" '$1 == k { print $4 }' "${STUB_JIRA_DB:-/dev/null}")
ty=$(awk -F'\t' -v k="$kc" '$1 == k { print $5 }' "${STUB_JIRA_DB:-/dev/null}")
if [ -z "$st" ]; then
    echo "jira: get $2 failed: HTTP 404: Issue does not exist or you do not have permission to see it." >&2
    exit 1
fi
[ "$st" = "MALFORMED" ] && { printf 'garbage with no tabs\n'; exit 0; }
[ "$st" = "BLANK" ] && st=""
if [ "${3:-}" = "--json" ]; then
    jq -n --arg k "$kc" --arg st "$st" --arg lb "$lb" --arg d "$desc" --arg ty "$ty" \
        '{key:$k,fields:{status:{name:$st},issuetype:{name:$ty},labels:($lb | split(", ") | map(select(length > 0))),description:$d}}'
    exit 0
fi
printf '%s\tTask\t%s\tsummary\n' "$2" "$st"
[ -z "$desc" ] || printf '%s\n' "$desc"
[ -z "$lb" ] || printf 'Labels: %s\n' "$lb"
STUB
chmod +x "$tmp/bin/jira-stub"
# a `timeout` and `gtimeout` that refuse --version: scripts/lib/timeout-bin.sh then resolves none
mkdir -p "$tmp/no-timeout"
printf '#!/bin/sh\nexit 1\n' > "$tmp/no-timeout/timeout"
cp "$tmp/no-timeout/timeout" "$tmp/no-timeout/gtimeout"
chmod +x "$tmp/no-timeout/timeout" "$tmp/no-timeout/gtimeout"
# shellcheck source=scripts/lib/timeout-bin.sh
. "$HERE/../../lib/timeout-bin.sh"
# shellcheck disable=SC2153  # set by the lib sourced above
BO_TIMEOUT_BIN="$_TIMEOUT_BIN"
# ── trust-path fixtures: the REAL trust list, served as the default branch's; an
# anchor repo (carrying the real go-gate.sh) whose origin is at the same commit,
# so a trust-path hit passes trust_path_check's anchor-is-current test offline ──
TRUST_LIST_FILE="$HERE/../../ci/ci-trust-paths.txt"
TP_ANCHOR="$tmp/tp-anchor"
git init -q --bare "$tmp/tp-origin.git"
git init -q "$TP_ANCHOR"
mkdir -p "$TP_ANCHOR/scripts/lib"
cp "$HERE/../../lib/go-gate.sh" "$TP_ANCHOR/scripts/lib/go-gate.sh"
# item 17 runs the merge's remainder reader from the anchor, never from the checkout under review
cp "$HERE/../../lib/pr_remainder.py" "$TP_ANCHOR/scripts/lib/pr_remainder.py"
cp "$HERE/../../lib/ticket-status.sh" "$HERE/../../lib/required-checks.sh" "$HERE/../../lib/prim.sh" "$HERE/../../lib/status-marker.sh" "$TP_ANCHOR/scripts/lib/"
mkdir -p "$TP_ANCHOR/scripts/eval/conflicts" "$TP_ANCHOR/scripts/eval/judge-accuracy" "$TP_ANCHOR/scripts/eval/lib"
cp "$HERE/../../eval/conflicts/conflicts.py" "$TP_ANCHOR/scripts/eval/conflicts/"
cp "$HERE/../../eval/judge-accuracy/judge_accuracy.py" "$TP_ANCHOR/scripts/eval/judge-accuracy/"
cp "$HERE/../../eval/lib/eval_runs.py" "$HERE/../../eval/lib/wilson.py" "$TP_ANCHOR/scripts/eval/lib/"
# check 19 runs the anchor's impacted-suites.sh: here a stub printing STUB_IMPACTED
# (default none); the check-19 rows bring an anchor with the real one
mkdir -p "$TP_ANCHOR/scripts/cr"
# shellcheck disable=SC2016  # the stub's own $vars stay literal
printf '%s\n' '#!/usr/bin/env bash' \
    '[ -z "${STUB_IMPACTED_REAL:-}" ] || exec bash "$STUB_IMPACTED_REAL" "$@"' \
    '[ -z "${STUB_IMPACTED_SLEEP:-}" ] || sleep "$STUB_IMPACTED_SLEEP"' \
    'printf "%b" "${STUB_IMPACTED:-}"' \
    'exit "${STUB_IMPACTED_RC:-0}"' > "$TP_ANCHOR/scripts/cr/impacted-suites.sh"
git -C "$TP_ANCHOR" add -A
git -C "$TP_ANCHOR" -c user.name=t -c user.email=t@t commit -q -m init
git -C "$TP_ANCHOR" remote add origin "$tmp/tp-origin.git"
git -C "$TP_ANCHOR" push -q origin HEAD:refs/heads/main 2>/dev/null
git -C "$tmp/tp-origin.git" symbolic-ref HEAD refs/heads/main
export GH_LOG
PATH="$tmp/bin:$PATH"
export PATH

# ── shared green defaults ───────────────────────────────────────────────
GREEN_ROLLUP='[{"name":"build","status":"COMPLETED","conclusion":"SUCCESS"},{"context":"legacy-ci","state":"SUCCESS"}]'
GREEN_COMMITS='[{"messageHeadline":"feat(x): [HIMMEL-1] add thing","messageBody":"Platforms tested: linux\nSecurity reviewed: manual"},{"messageHeadline":"fix(x): [HIMMEL-2] tweak","messageBody":""}]'
GREEN_FILES="scripts/x/run.sh"
GREEN_BODY='## Summary\nthing\n\n## Ticket coverage\n- ask one: done\n- ask two: done\n\n## Test plan\nx\n'
# (check 13) every stubbed body ends with a RED-then-GREEN line unless a row sets STUB_RED to blank
GREEN_RED='\nRED then GREEN: the new row failed before the change and passes after it\n'
JIRA_DB="$tmp/jira.db"
printf 'HIMMEL-50\tTo Do\nHIMMEL-51\tDone\nHIMMEL-52\tClosed\nHIMMEL-53\tWon'"'"'t Do\nHIMMEL-54\tBLANK\nHIMMEL-55\tMALFORMED\nHIMMEL-100\tTo Do\tresidual\nHIMMEL-200\tTo Do\nHIMMEL-201\tTo Do\tresidual, class-x\nHIMMEL-202\tTo Do\tresidual-depth-1\nHIMMEL-203\tTo Do\t\tLabels: residual\n' > "$JIRA_DB"

seed_ledger_ok() {
    printf '{"kind":"avail","ts":"2026-01-01T00:00:00Z","branch":"b","head":"%s","model":"codex","status":"ok"}\n' "$SHA" > "$LEDGER"
}
seed_ledger_missing() {
    printf '{"kind":"avail","ts":"2026-01-01T00:00:00Z","branch":"b","head":"deadbeefdeadbeefdeadbeefdeadbeefdeadbeef","model":"codex","status":"ok"}\n' > "$LEDGER"
}

# seed_deferral <KEY> [head]: a CR finding at head (default $SHA) deferred to KEY, the row check 7 matches against the body
seed_deferral() {
    printf '{"kind":"finding","ts":"2026-01-01T00:00:01Z","branch":"%s","head":"%s","model":"codex","finding_id":"codex-%s","severity":"sug","verdict":"deferred","deferred_to":"%s","fu_class":"polish","reason":"out of scope","artifact":"diff","perspective":"off"}\n' "${SEED_BRANCH:-b}" "${2:-$SHA}" "$1" "$1" >> "$LEDGER"
}

RUN_FLAGS="--observe"
run() {
    local cache="${RUN_CACHE:-}"
    [ -n "$cache" ] || cache=$(mktemp -d "$tmp/cache.XXXXXX") || return 1  # prim-ok: the suite scratch dir, removed by its EXIT trap
    # RUN_MODE=outside runs `--outside <pr>`, RUN_MODE=only7 runs `--only 7 <pr>`
    # shellcheck disable=SC2086  # RUN_FLAGS is a fixed word list the suite sets
    case "${RUN_MODE:-}" in
        outside) set -- --outside "$PR" ;;
        owner) set -- --owner-review ${OR_ARGS:-$PR} ;;
        only7) set -- --only 7 "$PR" ;;
        wrapper) set -- "$PR" ;;
        none) set -- ;;
        *) set -- ${RUN_FLAGS:-} "$PR" "$SHA" ;;
    esac
    (cd "${RUN_CWD:-$REPO}" && env -u TICKET_ID_PATTERN \
        JIRA_PROJECT_KEY=HIMMEL HOME="${RUN_HOME:-$HOME}" \
        HIMMEL_REPO="${RUN_HIMMEL_REPO-$REPO}" STUB_NWO_BY_CWD="${STUB_NWO_BY_CWD:-}" \
        STUB_NWO="$NWO" \
        STUB_HEAD="${STUB_HEAD:-$SHA}" STUB_MSS="${STUB_MSS:-CLEAN}" \
        STUB_ROLLUP="${STUB_ROLLUP:-$GREEN_ROLLUP}" \
        STUB_UNRESOLVED="${STUB_UNRESOLVED:-0}" \
        STUB_COMMITS="${STUB_COMMITS:-$GREEN_COMMITS}" \
        STUB_MERGE_OIDS="${STUB_MERGE_OIDS:-}" \
        STUB_FILES="${STUB_FILES:-$GREEN_FILES}" \
        STUB_FILES_FAIL="${STUB_FILES_FAIL:-}" STUB_FILES_PARTIAL="${STUB_FILES_PARTIAL:-}" \
        STUB_RENAMES="${STUB_RENAMES:-}" STUB_RENAMES_FAIL="${STUB_RENAMES_FAIL:-}" \
        STUB_FILE_STATUS="${STUB_FILE_STATUS:-}" STUB_WF_DIR="${STUB_WF_DIR:-}" \
        STUB_RUNS_DIR="${STUB_RUNS_DIR:-}" STUB_RUNS_FAIL="${STUB_RUNS_FAIL:-}" STUB_WF_PATCH_FILE="${STUB_WF_PATCH_FILE:-}" \
        STUB_AUTHOR="${STUB_AUTHOR:-}" STUB_BODY="${STUB_BODY-$GREEN_BODY}" STUB_RED="${STUB_RED-$GREEN_RED}" STUB_PR_TITLE="${STUB_PR_TITLE:-}" STUB_PR_BRANCH="${STUB_PR_BRANCH-feat/himmel-100-thing}" \
        JIRA_CMD="${RUN_JIRA_CMD-$tmp/bin/jira-stub}" STUB_JIRA_DB="$JIRA_DB" STUB_JIRA_DOWN="${STUB_JIRA_DOWN:-}" STUB_LINKS_DB="${STUB_LINKS_DB:-}" STUB_LINKS_FAIL="${STUB_LINKS_FAIL:-}" \
        PATH="$PATH" GH_LOG="$GH_LOG" GH_PR_SNAPSHOT_CACHE_DIR="$cache" \
        STUB_SNAPSHOT_FAIL="${STUB_SNAPSHOT_FAIL:-}" \
        STUB_TRUST_LIST_FILE="$TRUST_LIST_FILE" STUB_TRUST_LIST_FAIL="${STUB_TRUST_LIST_FAIL:-}" \
        STUB_DEFAULT_BRANCH_FAIL="${STUB_DEFAULT_BRANCH_FAIL:-}" \
        STUB_GH_RL="${STUB_GH_RL:-}" HIMMEL_QUOTA_DIR="${RUN_QUOTA_DIR:-$tmp/quota}" \
        STUB_MANIFEST_DIR="${STUB_MANIFEST_DIR:-}" STUB_DL_FAIL="${STUB_DL_FAIL:-}" STUB_DL_SLEEP="${STUB_DL_SLEEP:-}" STUB_DL_STARTED="${STUB_DL_STARTED:-}" \
        STUB_JS_MANIFEST_DIR="${STUB_JS_MANIFEST_DIR:-}" STUB_JS_DL_FAIL="${STUB_JS_DL_FAIL:-}" STUB_JOBS="${STUB_JOBS:-}" STUB_JOBS_FAIL="${STUB_JOBS_FAIL:-}" \
        STUB_RUN_SLEEP="${STUB_RUN_SLEEP:-}" STUB_RUN_HEAD_SHA="${STUB_RUN_HEAD_SHA:-}" STUB_RUN_CONC="${STUB_RUN_CONC:-}" \
        READY_CHECK_ITEM19_BOUND="${READY_CHECK_ITEM19_BOUND:-}" \
        READY_CHECK_FAIL_LEDGER="${READY_CHECK_FAIL_LEDGER:-$tmp/ci-failures.jsonl}" \
        READY_CHECK_ANCHOR="${READY_CHECK_ANCHOR-$TP_ANCHOR}" \
        STUB_FORK_JSON="${STUB_FORK_JSON:-${STUB_FORK:-false}}" STUB_AUTHOR_ID="${STUB_AUTHOR_ID:-}" STUB_AUTHOR_TYPE="${STUB_AUTHOR_TYPE:-}" \
        STUB_RESOLVED_BY="${STUB_RESOLVED_BY:-}" STUB_ROLLUP_NULL="${STUB_ROLLUP_NULL:-}" \
        STUB_FILES16_FAIL="${STUB_FILES16_FAIL:-}" STUB_FILES16_EMPTY="${STUB_FILES16_EMPTY:-}" \
        bash "${RUN_SCRIPT:-$SCRIPT}" "$@")
}

reset_stubs() {
    unset STUB_TRUST_LIST_FAIL STUB_DEFAULT_BRANCH_FAIL
    unset STUB_HEAD STUB_MSS STUB_ROLLUP STUB_UNRESOLVED STUB_COMMITS STUB_MERGE_OIDS STUB_FILES STUB_FILES_FAIL STUB_FILES_PARTIAL STUB_RENAMES STUB_RENAMES_FAIL STUB_BODY STUB_RED STUB_JIRA_DOWN STUB_LINKS_DB STUB_LINKS_FAIL STUB_SNAPSHOT_FAIL STUB_FILE_STATUS STUB_WF_DIR STUB_WF_PATCH_FILE STUB_RUNS_DIR STUB_RUNS_FAIL STUB_PR_TITLE STUB_PR_BRANCH STUB_AUTHOR
    unset STUB_FORK STUB_FORK_JSON STUB_AUTHOR_ID STUB_AUTHOR_TYPE STUB_RESOLVED_BY STUB_ROLLUP_NULL STUB_FILES16_FAIL STUB_FILES16_EMPTY
    unset STUB_JS_MANIFEST_DIR STUB_JS_DL_FAIL STUB_JOBS STUB_JOBS_FAIL
    seed_ledger_ok
}

test_primary="$(git -C "$HERE" rev-parse --path-format=absolute --git-common-dir)"
test_primary="${test_primary%/.git}"
# --- 7b. `--only 7 <pr>` runs just the coverage check, so a worker
# lints its own PR body before READY with item 7's exact logic (no second copy).
run7() {
    (cd "$REPO" && env -u TICKET_ID_PATTERN \
        JIRA_PROJECT_KEY=HIMMEL HIMMEL_REPO="$REPO" STUB_NWO="$NWO" \
        STUB_BODY="${STUB_BODY-$GREEN_BODY}" STUB_HEAD="${STUB_HEAD:-$SHA}" \
        STUB_PR_BRANCH="${STUB_PR_BRANCH-feat/himmel-100-thing}" \
        JIRA_CMD="$tmp/bin/jira-stub" STUB_JIRA_DB="$JIRA_DB" STUB_LINKS_DB="${STUB_LINKS_DB:-}" \
        PATH="$PATH" GH_LOG="$GH_LOG" \
        bash "$SCRIPT" --only 7 "$PR")
}

O_NOW=$(python3 -I -c 'import time; print(int(time.time()))')
o_day() { python3 -I -c 'import sys, time; print(time.strftime("%Y-%m-%d", time.gmtime(int(sys.argv[1]) + int(sys.argv[2]) * 86400)))' "${2:-$O_NOW}" "$1"; }

# seed_descendant <reviewed head> [branch]: the avail row clear-review-marker writes for a tip it cleared as a trivial descendant of a reviewed head
seed_descendant() {
    printf '{"kind":"avail","ts":"2026-01-01T00:00:02Z","branch":"%s","head":"%s","model":"claude","status":"ok","detail":"trivial-descendant of reviewed head %s (carried by clear-cr-marker)"}\n' "${2:-${SEED_BRANCH:-b}}" "$SHA" "$1" >> "$LEDGER"
}

BO_COV='## Ticket coverage\n- ask one: done\n\n'
BO_GOOD="${BO_COV}bug-origin: #12 test-gap — two scripts each correct alone\n"
jira_db_bug_rows() {
printf 'HIMMEL-900\tTo Do\t\t\tBug\nHIMMEL-901\tTo Do\t\t\tTask\nHIMMEL-902\tTo Do\t\tREADY-CHECK FAIL COVERAGE-LINT FAIL\tBug\n' >> "$JIRA_DB"
}

REPO_ROOT="$(cd "$HERE/../../.." && pwd)"
