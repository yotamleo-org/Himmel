#!/usr/bin/env bash
# test-gh-read.sh — scripts/lib/gh-read.sh routes READ-ONLY gh calls to the read-only
# token (himmel_github_token_vm2) and nothing else.
#   A  write-shaped calls never use the read token; the row fails on a broken router
#   B  each named read path (helper, ready-check, check-ci, go.sh, tick) uses it
#   C  token missing/invalid/refused -> main token + ONE warning; go.sh still passes
#   D  the rate-budget lines show both tokens and flag LOW under 10 %
# Hermetic: a stub gh on PATH logs the token and argv of every call; a fixture .env
# root (GH_READ_ENV_ROOT) and a scratch HOME stand in for the real ones.
#
# PLATFORM GUARD: The chief kit is Linux-only.
# selector: tree-scan
# shellcheck disable=SC2015,SC2016  # `[ cond ] && pass || fail`: pass() cannot fail; single-quoted stub bodies expand at run time
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../../.." && pwd)"
HELPER="$REPO/scripts/lib/gh-read.sh"
W="$(mktemp -d "${TMPDIR:-/tmp}/gh-read-test.XXXXXX")" || exit 1
trap 'rm -rf "$W"' EXIT
fails=0
pass() { printf 'ok - %s\n' "$1"; }
fail() { printf 'FAIL - %s\n' "$1"; fails=$((fails + 1)); }
redact() { # a failure line never carries a token: any token-shaped run becomes <first 3>…(<len>), short enough to never spell a token prefix
    local s="$1" tok
    while [[ "$s" =~ (github_pat_|gh[pousr]_)[A-Za-z0-9_]+ ]]; do
        tok="${BASH_REMATCH[0]}"
        s="${s//"$tok"/<${tok:0:3}…(${#tok})>}"
    done
    printf '%s' "$s"
}
check() { # <name> <want> <got>
    if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (want '$(redact "$2")' got '$(redact "$3")')"; fi
}
has() { # <name> <needle> <haystack>
    case "$3" in *"$2"*) pass "$1" ;; *) fail "$1 (no '$(redact "$2")' in '$(redact "$3")')" ;; esac
}
lacks() { # <name> <needle> <haystack>
    case "$3" in *"$2"*) fail "$1 (found '$(redact "$2")' in '$(redact "$3")')" ;; *) pass "$1" ;; esac
}

READTOK=ghp_READTOKEN0123456789
mkdir -p "$W/bin" "$W/home" "$W/root" "$W/emptyroot"
printf 'himmel_github_token_vm2=%s\n' "$READTOK" > "$W/root/.env"
: > "$W/emptyroot/.env"
cat > "$W/bin/gh" <<'STUB'
#!/usr/bin/env bash
# logs "tok=<GH_TOKEN or main> argv=<args>"; GH_STUB_READFAIL makes the read token's calls fail
printf 'tok=%s argv=%s\n' "${GH_TOKEN:-main}" "$*" >> "$GHLOG"
[ -z "${GH_STUB_HANG:-}" ] || exec sleep "$GH_STUB_HANG"
if [ -z "${GH_TOKEN:-}" ] && [ -n "${GH_STUB_MAINFAIL:-}" ]; then
    case "$GH_STUB_MAINFAIL" in
        auth) echo "gh: HTTP 401: Bad credentials" >&2 ;;
        *) echo "GraphQL: API rate limit already exceeded for user ID 1." >&2 ;;
    esac
    exit 1
fi
if [ "${GH_TOKEN:-}" = "ghp_READTOKEN0123456789" ] && [ -n "${GH_STUB_READFAIL:-}" ]; then
    echo "partial-page"
    case "$GH_STUB_READFAIL" in
        scope) echo "gh: Resource not accessible by personal access token" >&2 ;;
        auth) echo "gh: HTTP 401: Bad credentials" >&2 ;;
        notfound) echo "gh: HTTP 404: Not Found" >&2 ;;
        resolve) echo "GraphQL: Could not resolve to a Repository with the name 'o/r'. (repository)" >&2 ;;
        *) echo "gh: HTTP 403: API rate limit exceeded for user" >&2 ;;
    esac
    exit 1
fi
case "$*" in
    "api rate_limit"*) if [ "${GH_TOKEN:-}" = "ghp_READTOKEN0123456789" ]; then echo "${RATE_READ:-4990 5000 1790000000}"; else echo "${RATE_MAIN:-4200 5000 1790000000}"; fi ;;
    "repo view"*) echo "yotamleo-org/Himmel main" ;;
esac
exit 0
STUB
chmod +x "$W/bin/gh"
mkdir -p "$W/ghcfg" "$W/xdg/config" "$W/xdg/data" "$W/xdg/cache" "$W/himmelcfg" || exit 1
export GHLOG="$W/gh.log" HOME="$W/home" PATH="$W/bin:$PATH" GH_CONFIG_DIR="$W/ghcfg" HIMMEL_SECRETS_KEYRING=off \
    XDG_CONFIG_HOME="$W/xdg/config" XDG_DATA_HOME="$W/xdg/data" XDG_CACHE_HOME="$W/xdg/cache" HIMMEL_CONFIG_DIR="$W/himmelcfg"
# only fixture tokens may be visible: the ambient token, the keyring and a systemd credential dir are all closed
unset GH_TOKEN GITHUB_TOKEN himmel_github_token_vm2 CREDENTIALS_DIRECTORY
# control: a forced mismatch must print the token shortened, never whole (a passing run never reaches redact otherwise)
redaction_probe="$( (check "redaction probe" "$READTOK" "not-the-token") 2>&1)"
has "A0 a failing assertion prints a token shortened" "<ghp…(" "$redaction_probe"
lacks "A0b a failing assertion never prints the token whole" "$READTOK" "$redaction_probe"

run_gh_read() { # <env-root> <gh args...> — executed form, fresh process
    local root="$1"; shift
    : > "$GHLOG"
    GH_READ_ENV_ROOT="$root" bash "$HELPER" "$@" 2>"$W/err" >/dev/null
    return 0
}
last_tok() { sed -n '$p' "$GHLOG" | sed 's/^tok=\([^ ]*\) .*/\1/'; }

# ---- A: a write-shaped call never takes the read token --------------------------
write_uses_main() { # <helper path> -> prints "ok" when EVERY write shape used the main token
    local helper="$1" bad=0 shape
    for shape in "pr merge 12 --squash" "pr comment 12 --body x" "pr review 12 --approve" \
                 "api -X POST repos/o/r/issues/1/comments -f body=x" "api graphql -f query=mutation{x}" \
                 "api --method=PUT repos/o/r/pulls/1/merge" "pr create --title t --body b" \
                 "api graphql --input q.json" "api graphql -F query=@q.graphql" "api graphql --field query=@q.graphql"; do
        : > "$GHLOG"
        # shellcheck disable=SC2086  # the shape is a word list on purpose
        GH_READ_ENV_ROOT="$W/root" bash "$helper" $shape >/dev/null 2>&1
        case "$(cat "$GHLOG")" in "tok=main "*) ;; *) bad=1 ;; esac
    done
    [ "$bad" -eq 0 ] && echo ok
}
check "A1 every write shape stays on the main token" ok "$(write_uses_main "$HELPER" 2>/dev/null)"
# control: a router that sends everything to the read token must make A1 fail
if [ -f "$HELPER" ]; then
    sed 's/^_ghr_is_read() {$/_ghr_is_read() { return 0/' "$HELPER" > "$W/broken-gh-read.sh"
    ln -sf "$REPO/scripts/lib/load-dotenv.sh" "$W/load-dotenv.sh"
    check "A2 control: a broken router is caught by A1" "" "$(write_uses_main "$W/broken-gh-read.sh" 2>/dev/null)"
else
    fail "A2 control needs the helper"
fi
callers="$(cd "$REPO" && git grep -l 'gh-read.sh' -- scripts | tr '\n' ' ')"
for w in scripts/lib/go-gate.sh scripts/handover/chief-kit/write-verdict.sh scripts/cr/write-verdicts.sh; do
    lacks "A3 write path $w does not source the read helper" "$w " "$callers"
done
join_continuations() {
    awk '{ buf = (buf == "" ? $0 : buf " " $0); if ($0 ~ /\\$/) next; print buf; buf = "" } END { if (buf != "") print buf }' "$1"
}
a3b_ok() {
    local f="$1" stm bad="" n v pat
    stm="$(join_continuations "$f")"
    n="$(printf '%s\n' "$stm" | grep -cE '"\$[A-Za-z_]+"[[:space:]]+(pr merge|workflow run)|GH_CMD="\$[A-Za-z_]+"[[:space:]]+cr_trigger_post_review')"
    [ "$n" -eq 3 ] || bad="$bad [$n write calls found, want 3]"
    v="$(printf '%s\n' "$stm" | grep -E '"\$[A-Za-z_]+"[[:space:]]+(pr merge|workflow run)|GH_CMD="\$[A-Za-z_]+"[[:space:]]+cr_trigger_post_review' | grep -vE '"\$GH"[[:space:]]+(pr merge|workflow run)|GH_CMD="\$GH"[[:space:]]+cr_trigger_post_review')" || true
    [ -z "$v" ] || bad="$bad [a write call not on \"\$GH\"]"
    [ "$(grep -cE '^GH=' "$f")" -eq 1 ] && [ "$(grep -cE '^GH="gh"$' "$f")" -eq 1 ] || bad="$bad [GH is not assigned exactly once, to the literal gh]"
    v="$(printf '%s\n' "$stm" | grep -E 'GH_READ_BIN' | grep -E '(pr merge|workflow run|cr_trigger_post_review)')" || true
    [ -z "$v" ] || bad="$bad [a line names the read variable beside a write verb]"
    for pat in '"\$GH" api "repos/\$nwo/branches/\$branch/protection"' '"\$GH" api "repos/\$nwo/rules/branches/\$branch"' \
               '"\$GH" api "repos/\$nwo/rulesets/\$id"' '"\$GH" pr view "\$pr_num" --repo "\$nwo" --json mergeStateStatus,reviewDecision'; do
        n="$(printf '%s\n' "$stm" | grep -cE "$pat.*gh-main-ok: permission-dependent answer")"
        [ "$n" -eq 1 ] || bad="$bad [the caller-dependent read $pat is not on \"\$GH\" with its marker ($n)]"
    done
    [ -n "$bad" ] && printf '%s\n' "$bad" || echo ok
}
MOG_REAL="$REPO/scripts/handover/merge-on-green.sh"
check "A3b merge-on-green.sh keeps its writes and its caller-dependent reads on the literal gh" ok "$(a3b_ok "$MOG_REAL")"
sed 's|"\$GH" pr merge|"$GH_READ_BIN" pr merge|' "$MOG_REAL" > "$W/mog-merge-on-read.sh"
cmp -s "$MOG_REAL" "$W/mog-merge-on-read.sh" && fail "A3b control: the pr merge copy equals the original (nothing moved)"
check "A3b control: pr merge moved to the read variable is caught" "caught" "$([ "$(a3b_ok "$W/mog-merge-on-read.sh")" = ok ] && echo missed || echo caught)"
sed 's|rs=\$("\$GH" api "repos/\$nwo/rulesets/\$id"|rs=$("$GH_READ_BIN" api "repos/$nwo/rulesets/$id"|' "$MOG_REAL" > "$W/mog-ruleset-on-read.sh"
cmp -s "$MOG_REAL" "$W/mog-ruleset-on-read.sh" && fail "A3b control: the ruleset copy equals the original (nothing moved)"
check "A3b control: the ruleset read moved to the read variable is caught" "caught" "$([ "$(a3b_ok "$W/mog-ruleset-on-read.sh")" = ok ] && echo missed || echo caught)"

# ---- B: read paths use the read token ---------------------------------------------
for shape in "pr view 12 --json state" "pr list --limit 5" "pr checks 12" "repo view --json name" \
             "api repos/o/r/pulls/1/files --paginate" "api graphql -f query={viewer{login}}" "run list --workflow w"; do
    # shellcheck disable=SC2086
    run_gh_read "$W/root" $shape
    check "B1 '$shape' used the read token" "$READTOK" "$(last_tok)"
done
run_gh_read "$W/root" pr view 12
lacks "B2 the token is not in argv" "$READTOK" "$(sed 's/^tok=[^ ]* //' "$GHLOG")"
lacks "B2b the token is not in the stderr" "$READTOK" "$(cat "$W/err")"
for f in scripts/check-ci.sh scripts/handover/chief-kit/go.sh scripts/handover/chief-kit/ready-check.sh scripts/handover/chief-kit/tick.sh \
        scripts/handover/arm-resume.sh scripts/handover/generate-morning-briefing.sh scripts/handover/merge-fork-pr.sh \
        scripts/handover/merge-forward-check.sh scripts/handover/merge-on-green.sh scripts/handover/pr-merge.sh \
        scripts/handover/chief-kit/auto-go.sh scripts/handover/chief-kit/board.mjs scripts/handover/chief-kit/cancel-runs.sh \
        scripts/handover/chief-kit/chain-graph.py scripts/handover/chief-kit/chain-plan-core.sh scripts/handover/chief-kit/chief-wait.sh \
        scripts/handover/chief-kit/cloud-liveness.mjs scripts/handover/chief-kit/cr-disposition.sh scripts/handover/chief-kit/cut-tag.sh \
        scripts/handover/chief-kit/fleet.mjs scripts/handover/chief-kit/focus-refresh.sh scripts/handover/chief-kit/gen-briefs.py \
        scripts/handover/chief-kit/grant-round.sh scripts/handover/chief-kit/handoff-facts.sh scripts/handover/chief-kit/holds.py \
        scripts/handover/chief-kit/model-check-report.sh scripts/handover/chief-kit/orphan-pr-check.sh scripts/handover/chief-kit/pr-stall.sh \
        scripts/handover/chief-kit/ready-go.sh scripts/handover/chief-kit/series-next.sh scripts/handover/chief-kit/series-publish.sh \
        scripts/handover/chief-kit/shepherd.sh scripts/handover/chief-kit/station-sync.sh scripts/handover/chief-kit/status-drift.sh \
        scripts/handover/chief-kit/status-sweep.sh scripts/handover/chief-kit/stuck-scan.sh scripts/handover/chief-kit/tracker.py \
        scripts/handover/chief-kit/verdict-retention.sh scripts/handover/chief-kit/wrap-merged.sh; do
    if grep -q 'gh_read\|gh-read.sh\|GH_READ' "$REPO/$f"; then pass "B3 $f routes its reads through the helper"; else fail "B3 $f does not use the helper"; fi
done
# ready-check: its first read (repo view) rides the read token end to end
: > "$GHLOG"
GH_READ_ENV_ROOT="$W/root" bash "$REPO/scripts/handover/chief-kit/ready-check.sh" --only 7 99 >/dev/null 2>&1
check "B4 ready-check's first read used the read token" "$READTOK" "$(sed -n '1p' "$GHLOG" | sed 's/^tok=\([^ ]*\) .*/\1/')"
# check-ci: the first PR read rides the read token, and no merge/comment shape ever shows up
: > "$GHLOG"
GH_READ_ENV_ROOT="$W/root" CHECK_CI_CACHE_DIR="$W/ci-cache" CR_APP=0 CHECK_CI_SLEEP_CMD=: GH_BUDGET_PREFLIGHT=0 bash "$REPO/scripts/check-ci.sh" 99 --max-wait 5 --settle 0 >"$W/ci.out" 2>&1
ci_rc=$?
# the stub answers no PR url, so check-ci stops at its first read with exit 2; any other
# status means it died elsewhere and the read count below proves nothing
check "B5a check-ci stopped at its first read (exit 2, cannot resolve the PR)" "2 yes" "$ci_rc $(grep -q 'cannot resolve the PR' "$W/ci.out" && echo yes)"
check "B5 check-ci's reads used the read token" "" "$(grep -v "^tok=$READTOK " "$GHLOG")"
check "B5b check-ci made at least one read (B5 is not vacuous)" "yes" "$([ "$(grep -c . "$GHLOG")" -gt 0 ] && echo yes || head -c 500 "$W/ci.out")"
# the watcher stays an exec'd gh so check-ci's recorded pid is the real gh, never a wrapper
check "B5c check-ci's two --watch calls exec gh directly" "2" "$(grep -c 'exec gh pr checks .*--watch' "$REPO/scripts/check-ci.sh")"
# go.sh: both of its reads (fork PR view, repo name) go through the helper variable
check "B6 go.sh reads via the helper" "2" "$(grep -c '"\$GH_READ" \(pr\|repo\) view' "$REPO/scripts/handover/chief-kit/go.sh")"
check "B6b go.sh keeps a caller's GH override for the fork readiness read" "1" "$(grep -c 'GH="\${GH:-\$GH_READ}" go_fork_ready' "$REPO/scripts/handover/chief-kit/go.sh")"

# check-ci merges stderr into the data at three captures (required-check rules, classic
# protection, the first PR snapshot); the fallback warning must stay off all three
check "B7 check-ci mutes the fallback warning on its three 2>&1 captures" "3" "$(grep -c 'GH_READ_QUIET=1 \(gh_read api\|pr_view\)' "$REPO/scripts/check-ci.sh")"
GH_STUB_READFAIL=1 GH_READ_ENV_ROOT="$W/root" GH_READ_QUIET=1 bash "$HELPER" api repos/o/r/rules >"$W/out" 2>&1
lacks "B7b a muted refused read leaves no warning in a 2>&1 capture" "gh-read:" "$(cat "$W/out")"

# ---- C: fallback -----------------------------------------------------------------
run_gh_read "$W/emptyroot" pr view 12
check "C1 read token unset -> main token" "main" "$(last_tok)"
has "C1b one warning line on stderr" "gh-read:" "$(cat "$W/err")"
check "C1c exactly one warning line" "1" "$(grep -c 'gh-read:' "$W/err")"
printf 'himmel_github_token_vm2=bad token\n' > "$W/emptyroot/.env"
run_gh_read "$W/emptyroot" pr view 12
check "C2 invalid read token -> main token" "main" "$(last_tok)"
: > "$W/emptyroot/.env"
: > "$GHLOG"
GH_STUB_READFAIL=1 GH_READ_ENV_ROOT="$W/root" bash "$HELPER" pr view 12 >/dev/null 2>"$W/err"
check "C3 exhausted read token -> retried once on the main token" "tok=$READTOK argv=pr view 12|tok=main argv=pr view 12" "$(tr '\n' '|' < "$GHLOG" | sed 's/|$//')"
check "C3b one warning line" "1" "$(grep -c 'gh-read:' "$W/err")"
lacks "C3c the warning never carries the token" "$READTOK" "$(cat "$W/err")"
# a paginated read refused after it printed a page: the retry must not double the output
: > "$GHLOG"
GH_STUB_READFAIL=1 GH_READ_ENV_ROOT="$W/root" bash "$HELPER" api repos/o/r/pulls --paginate >"$W/out" 2>/dev/null
rc=$?
lacks "C3d a refused paginated attempt leaves no partial page behind" "partial-page" "$(cat "$W/out")"
check "C3d2 the paginated read exits 0 after the retry" "0" "$rc"
check "C3d3 the paginated read retried on the main token" "tok=$READTOK argv=api repos/o/r/pulls --paginate|tok=main argv=api repos/o/r/pulls --paginate" "$(tr '\n' '|' < "$GHLOG" | sed 's/|$//')"
# an error body printed on stdout by a refused non-paginated call is discarded too
: > "$GHLOG"
GH_STUB_READFAIL=1 GH_READ_ENV_ROOT="$W/root" bash "$HELPER" api repos/o/r >"$W/out" 2>/dev/null
rc=$?
lacks "C3f a refused plain api call leaves no error body behind" "partial-page" "$(cat "$W/out")"
check "C3f2 the plain api read exits 0 after the retry" "0" "$rc"
check "C3f3 the plain api read retried on the main token" "tok=$READTOK argv=api repos/o/r|tok=main argv=api repos/o/r" "$(tr '\n' '|' < "$GHLOG" | sed 's/|$//')"
# a permission refusal that is not a rate limit also falls back
: > "$GHLOG"
GH_STUB_READFAIL=scope GH_READ_ENV_ROOT="$W/root" bash "$HELPER" api graphql -f 'query={viewer{login}}' >/dev/null 2>"$W/err"
check "C3g a token-permission refusal retries on the main token" "tok=$READTOK argv=api graphql -f query={viewer{login}}|tok=main argv=api graphql -f query={viewer{login}}" "$(tr '\n' '|' < "$GHLOG" | sed 's/|$//')"
# init with a good token must not silence a later refusal
( GH_STUB_READFAIL=1 GH_READ_ENV_ROOT="$W/root" bash -c '. "$1"; gh_read_init; gh_read pr view 1' _ "$HELPER" ) >/dev/null 2>"$W/err"
check "C3e a refusal after a successful init still warns once" "1" "$(grep -c 'gh-read: read token refused' "$W/err")"
# sourced form: two calls, one warning
: > "$GHLOG"
( GH_READ_ENV_ROOT="$W/emptyroot" bash -c '. "$1"; gh_read pr view 1; gh_read pr view 2' _ "$HELPER" ) >/dev/null 2>"$W/err"
check "C4 sourced: warned once across two calls" "1" "$(grep -c 'gh-read:' "$W/err")"
check "C4b sourced: both calls ran on the main token" "2" "$(grep -c '^tok=main ' "$GHLOG")"
( GH_READ_ENV_ROOT="$W/root" bash -c '. "$1"; gh_read pr view 1; printf "%s" "${GH_TOKEN:-unset}"' _ "$HELPER" ) > "$W/out" 2>/dev/null
check "C5 sourcing never exports GH_TOKEN into the caller" "unset" "$(cat "$W/out")"
# (go.sh with the read token unset is pinned in test-go.sh, section 2b)

# ---- D: the rate budget lines ----------------------------------------------------
# shellcheck disable=SC1090
. "$HELPER"
out="$(RATE_MAIN='4200 5000 1790000000' RATE_READ='450 5000 1790000000' GH_READ_ENV_ROOT="$W/root" gh_read_rates 2>/dev/null)"
check "D1 two lines, one per token" "2" "$(printf '%s\n' "$out" | grep -c .)"
has "D2 main line shows remaining/limit" "main: 4200/5000" "$out"
has "D3 read line shows remaining/limit" "read: 450/5000" "$out"
has "D4 the 9 % read token is flagged LOW" "read: 450/5000 reset" "$out"
has "D4b LOW on the read line" "LOW" "$(printf '%s\n' "$out" | grep '^read:')"
lacks "D5 the healthy main line carries no LOW" "LOW" "$(printf '%s\n' "$out" | grep '^main:')"
out="$(RATE_MAIN='4200 5000 1790000000' RATE_READ='500 5000 1790000000' GH_READ_ENV_ROOT="$W/root" gh_read_rates 2>/dev/null)"
lacks "D6 exactly 10 % is not LOW" "LOW" "$out"
out="$(GH_READ_ENV_ROOT="$W/emptyroot" gh_read_rates 2>/dev/null)"
has "D7 no read token is reported, not hidden" "read: n/a" "$out"
check "D8 gh_read_rates never exports a token" "0" "$(env | grep -c 'ghp_READ')"

# shellcheck source=scripts/lib/timeout-bin.sh
. "$REPO/scripts/lib/timeout-bin.sh"
if [ -z "$_TIMEOUT_BIN" ]; then
    echo "SKIP E1-E3: no GNU timeout binary to bound the hung rows"
else
    : > "$GHLOG"
    t0=$SECONDS
    GH_STUB_HANG=20 GH_READ_TIMEOUT=2 GH_READ_ENV_ROOT="$W/root" "$_TIMEOUT_BIN" -k 2 12 bash "$HELPER" pr view 12 >/dev/null 2>&1
    rc=$?
    check "E1 a hung read returns under GH_READ_TIMEOUT (rc 124, at most 5 s)" "124 yes" "$rc $([ $((SECONDS - t0)) -le 5 ] && echo yes || echo "no:$((SECONDS - t0))s")"
    t0=$SECONDS
    out=$(GH_STUB_HANG=20 GH_READ_ENV_ROOT="$W/emptyroot" "$_TIMEOUT_BIN" 3 bash "$HELPER" pr view 12 2>/dev/null)
    check "E2 no read token: a hung read under an outer 3 s kill returns within 4 s" "yes" "$([ $((SECONDS - t0)) -le 4 ] && echo yes || echo "no:$((SECONDS - t0))s")"
    : > "$W/refused"
    GH_STUB_HANG=20 GH_READ_TIMEOUT=1 GH_READ_REFUSED_FILE="$W/refused" GH_READ_ENV_ROOT="$W/root" "$_TIMEOUT_BIN" -k 2 12 bash "$HELPER" pr view 12 >/dev/null 2>&1
    check "E3 a timed-out read writes one stall row" "read graphql stall" "$(cat "$W/refused")"
fi
: > "$W/refused"
GH_STUB_READFAIL=1 GH_STUB_MAINFAIL=rate GH_READ_REFUSED_FILE="$W/refused" GH_READ_ENV_ROOT="$W/root" bash "$HELPER" pr view 12 >/dev/null 2>&1
check "E4 a read refused on both tokens writes one rate-limit row" "main graphql rate-limit" "$(cat "$W/refused")"
: > "$W/refused"
GH_STUB_MAINFAIL=rate GH_READ_REFUSED_FILE="$W/refused" GH_READ_ENV_ROOT="$W/emptyroot" bash "$HELPER" run view 5 >/dev/null 2>"$W/err"
check "E4b no read token: a rate-limited core read writes its row" "main core rate-limit" "$(cat "$W/refused")"
has "E4c the refusal still reaches the caller's stderr" "rate limit" "$(cat "$W/err")"
: > "$W/refused"
GH_STUB_MAINFAIL=auth GH_READ_REFUSED_FILE="$W/refused" GH_READ_ENV_ROOT="$W/emptyroot" bash "$HELPER" pr view 12 >/dev/null 2>&1
check "E4d control: a 401 writes no refused row" "" "$(cat "$W/refused")"
: > "$GHLOG"
GH_STUB_READFAIL=1 GH_READ_NO_MAIN_FALLBACK=1 GH_READ_ENV_ROOT="$W/root" bash "$HELPER" pr view 12 >/dev/null 2>&1
rc=$?
check "E5 no-fallback: a rate-limited read is not retried on main" "tok=$READTOK argv=pr view 12" "$(tr '\n' '|' < "$GHLOG" | sed 's/|$//')"
check "E5a no-fallback: the refused read keeps its non-zero exit" "1" "$rc"
for why in auth notfound scope; do
    : > "$GHLOG"
    GH_STUB_READFAIL=$why GH_READ_NO_MAIN_FALLBACK=1 GH_READ_ENV_ROOT="$W/root" bash "$HELPER" pr view 12 >/dev/null 2>&1
    check "E5b no-fallback: a '$why' refusal still falls back to main" "tok=$READTOK argv=pr view 12|tok=main argv=pr view 12" "$(tr '\n' '|' < "$GHLOG" | sed 's/|$//')"
done
: > "$GHLOG"; : > "$W/refused"
t0=$SECONDS
GH_READ_OFF=1 GH_READ_REFUSED_FILE="$W/refused" GH_READ_ENV_ROOT="$W/root" bash "$HELPER" pr view 12 >/dev/null 2>&1
rc=$?
check "E6 GH_READ_OFF: non-zero, no gh call, one stall row" "nz||read graphql stall" "$([ "$rc" -ne 0 ] && echo nz)|$(cat "$GHLOG")|$(cat "$W/refused")"
: > "$GHLOG"
GH_READ_OFF=1 GH_READ_ENV_ROOT="$W/root" bash "$HELPER" pr comment 12 --body x >/dev/null 2>&1
check "E6b GH_READ_OFF does not stop a write" "tok=main argv=pr comment 12 --body x" "$(cat "$GHLOG")"

: > "$W/used"
GH_READ_USED_FILE="$W/used" GH_READ_ENV_ROOT="$W/root" bash "$HELPER" pr view 12 >/dev/null 2>&1
check "G1 a stubbed read appends one main or read row to GH_READ_USED_FILE" "read graphql" "$(cat "$W/used")"
: > "$W/used"
GH_READ_USED_FILE="$W/used" GH_READ_ENV_ROOT="$W/emptyroot" bash "$HELPER" run view 5 >/dev/null 2>&1
check "G1b no read token: the read is counted on main in its REST bucket" "main core" "$(cat "$W/used")"
: > "$W/used"
GH_STUB_READFAIL=1 GH_READ_USED_FILE="$W/used" GH_READ_ENV_ROOT="$W/root" bash "$HELPER" pr view 12 >/dev/null 2>&1
check "G2 a read retried on main counts both attempts" "read graphql|main graphql rl pr view 12" "$(tr '\n' '|' < "$W/used" | sed 's/|$//')"
for g6 in "auth|auth" "notfound|http404" "resolve|notfound" "scope|auth"; do
    : > "$W/used"
    GH_STUB_READFAIL="${g6%%|*}" GH_READ_USED_FILE="$W/used" GH_READ_ENV_ROOT="$W/root" bash "$HELPER" pr view 5765 -R yotamleo-org/Himmel --json headRefOid --jq .headRefOid >/dev/null 2>&1
    check "G6 a read refused on the read token (${g6%%|*}) is retried on main with its reason and what it read" \
        "read graphql|main graphql ${g6#*|} pr view 5765 -R yotamleo-org/Himmel" "$(tr '\n' '|' < "$W/used" | sed 's/|$//')"
done
: > "$W/used"
GH_STUB_READFAIL=notfound GH_READ_USED_FILE="$W/used" GH_READ_ENV_ROOT="$W/root" bash "$HELPER" api "repos/o/r/actions/runs?access_token=0123456789abcdef0123456789abcdef01234567&per_page=100" --jq '.x' >/dev/null 2>&1
check "G6b an api read names its path without its query string" \
    "main core http404 api repos/o/r/actions/runs" "$(sed -n 2p "$W/used")"
lacks "G6c no row carries a 40-hex token from the query" "0123456789abcdef0123456789abcdef01234567" "$(cat "$W/used")"
: > "$W/used"
GH_STUB_READFAIL=notfound GH_READ_USED_FILE="$W/used" GH_READ_ENV_ROOT="$W/root" bash "$HELPER" api "search/issues?q=private terms" --jq '.x' >/dev/null 2>&1
check "G6h a query value with a space is dropped whole" "main core http404 api search/issues" "$(sed -n 2p "$W/used")"
: > "$W/used"
GH_STUB_READFAIL=notfound GH_READ_USED_FILE="$W/used" GH_READ_ENV_ROOT="$W/root" bash "$HELPER" api "repos/o/r/contents/ghp_SECRETDUMMY0123456789" >/dev/null 2>&1
check "G6g a prefixed token in the path is masked" "main core http404 api repos/o/r/contents/<redacted>" "$(sed -n 2p "$W/used")"
: > "$W/used"
GH_STUB_READFAIL=notfound GH_READ_USED_FILE="$W/used" GH_READ_ENV_ROOT="$W/root" bash "$HELPER" api "repos/o/r/contents/$(printf 'a%.0s' $(seq 1 200))" >/dev/null 2>&1
check "G6d the summary is cut at 120 characters" "120" "$(sed -n 2p "$W/used" | cut -d' ' -f4- | tr -d '\n' | wc -c | tr -d ' ')"
: > "$W/used"
GH_STUB_READFAIL=notfound GH_READ_USED_FILE="$W/used" GH_READ_ENV_ROOT="$W/root" bash "$HELPER" api graphql -f query='query { viewer { login } }' >/dev/null 2>&1
check "G6e a graphql read names only api graphql, never its query" "main graphql http404 api graphql" "$(sed -n 2p "$W/used")"
check "G6f the read token's own row stays two columns" "read graphql" "$(sed -n 1p "$W/used")"
: > "$W/used"
GH_READ_USED_FILE="$W/used" GH_READ_ENV_ROOT="$W/root" bash "$HELPER" pr comment 12 --body x >/dev/null 2>&1
GH_READ_OFF=1 GH_READ_USED_FILE="$W/used" GH_READ_ENV_ROOT="$W/root" bash "$HELPER" pr view 12 >/dev/null 2>&1
check "G3 a write and a read that never ran append no row" "" "$(cat "$W/used")"
lacks "G3b no row carries the token" "$READTOK" "$(cat "$W/used")"
GH_READ_USED_FILE="$W/no-such-dir/used" GH_READ_ENV_ROOT="$W/root" bash "$HELPER" pr view 12 >/dev/null 2>"$W/err"
rc=$?
check "G4 an unwritable count file never fails the read and never prints" "0|" "$rc|$(cat "$W/err")"
rm -f "$W/gone"
GH_READ_USED_FILE="$W/gone" GH_READ_ENV_ROOT="$W/root" bash "$HELPER" pr view 12 >/dev/null 2>&1
check "G4b a removed count file is not recreated by a late read" "no" "$([ -e "$W/gone" ] && echo yes || echo no)"
if [ -n "$_TIMEOUT_BIN" ]; then
    : > "$W/used"
    GH_STUB_HANG=20 GH_READ_TIMEOUT=10 GH_READ_USED_FILE="$W/used" GH_READ_ENV_ROOT="$W/root" "$_TIMEOUT_BIN" -k 1 2 bash "$HELPER" pr view 12 >/dev/null 2>&1
    check "G5 a read killed by the caller's outer timeout still leaves its row" "read graphql" "$(cat "$W/used")"
fi

AMBTOK=ghp_AMBIENTDUMMY0123456789
KEYTOK=ghp_KEYRINGDUMMY0123456789
DOTTOK=ghp_DOTENVDUMMY0123456789
: > "$W/seen"
seen() { cat "$GHLOG" "$W/err" >> "$W/seen" 2>/dev/null; }
stub_keyring() { # <dir>
    TMP="$1"; mkdir -p "$TMP"
    # shellcheck source=scripts/lib/fixtures/keyring-stub.sh
    . "$REPO/scripts/lib/fixtures/keyring-stub.sh"
    kreset
    printf 'service=himmel key=himmel_github_token_vm2 scope=user\t%s\n' "$KEYTOK" > "$KSTUB_STORE"
}
# shellcheck disable=SC2030  # the exported token is meant to stay inside the row's subshell
( export himmel_github_token_vm2="$AMBTOK"; run_gh_read "$W/root" pr view 12 )
check "F1 an exported token never beats the fixture root's" "$READTOK" "$(last_tok)"; seen
( stub_keyring "$W/k1"; run_gh_read "$W/root" pr view 12 )
check "F2 a keyring token never beats the fixture root's" "$READTOK" "$(last_tok)"; seen
mkdir -p "$W/creds" && printf '%s' "$KEYTOK" > "$W/creds/himmel_github_token_vm2"
( export CREDENTIALS_DIRECTORY="$W/creds"; run_gh_read "$W/root" pr view 12 )
check "F3 a credentials-dir token never beats the fixture root's" "$READTOK" "$(last_tok)"; seen

# a symlinked scripts/lib whose default root holds a fixture .env: no row reads the checkout's real .env
mkdir -p "$W/tree/scripts/lib"
for f in "$REPO"/scripts/lib/*; do ln -s "$f" "$W/tree/scripts/lib/${f##*/}"; done
printf 'himmel_github_token_vm2=%s\n' "$DOTTOK" > "$W/tree/.env"
run_default() { : > "$GHLOG"; ( unset GH_READ_ENV_ROOT; bash "$W/tree/scripts/lib/gh-read.sh" "$@" 2>"$W/err" >/dev/null ); return 0; }
run_default pr view 12
check "N1 no fixture root: the default root's .env serves the token" "$DOTTOK" "$(last_tok)"; seen
( stub_keyring "$W/k2"; run_default pr view 12 )
if [ "$(uname -s)" = Darwin ]; then
    check "N2 no fixture root: the keyring is unsupported on Darwin, so .env serves the token" "$DOTTOK" "$(last_tok)"; seen
else
    check "N2 no fixture root: the keyring still beats .env" "$KEYTOK" "$(last_tok)"; seen
fi
# shellcheck disable=SC2031  # a second row-local export, not the F1 one
( stub_keyring "$W/k3"; export himmel_github_token_vm2="$AMBTOK"; run_default pr view 12 )
check "N3 no fixture root: the environment still beats the keyring" "$AMBTOK" "$(last_tok)"; seen

leaked() { # <file>
    local t
    grep -oE '(github_pat_|gh[pousr]_)[A-Za-z0-9_]+' "$1" | sort -u | while read -r t; do
        case " $READTOK $AMBTOK $KEYTOK $DOTTOK " in *" $t "*) ;; *) printf '%s ' "$t" ;; esac
    done
}
check "F4 every token the F and N rows handed gh or printed is a fixture" "" "$(leaked "$W/seen")"
printf 'tok=ghp_NOTAFIXTURE0123456789\n' > "$W/leak-probe"
check "F4b control: a non-fixture token is reported" "ghp_NOTAFIXTURE0123456789 " "$(leaked "$W/leak-probe")"

cat > "$W/f0.py" <<'F0PY'
import re, sys, os

ROOT = sys.argv[1]
MARK = 'gh-main-ok:'
VERBS = r'(?:pr\s+(?:view|list|checks|status|diff)|repo\s+view|run\s+(?:list|view)|issue\s+(?:view|list)|api)\b'
ARG = r'(?:-\S+|\d+[smhd]?|\$\{\w+:?[-+][^}]*\}|\$\{?\w+\}?|Q)'
WRAP = r'(?:timeout|bounded|env|command|nice|nohup|exec|time|in_reviewed|\$_TIMEOUT_BIN|\$\{_TIMEOUT_BIN[^}]*\})'
PREFIX = r'(?:(?:\w+=\S*|' + WRAP + r'(?:\s+' + ARG + r')*)\s+)*'
START = r'(?:^|\$\(|\|\||\||&&|;|!|\(|\{|\b(?:then|do|else|if|elif|while|until)\b)\s*'
GH_HIT = re.compile(START + PREFIX + r'gh\s+(' + VERBS + r')')


def wanted(path):
    base = os.path.basename(path)
    if not path.endswith(('.sh', '.py', '.mjs')):
        return False
    if '/fixtures/' in path or '/testdata/' in path or base.startswith('test-') or '-test-' in base:
        return False
    return True


def blank_heredocs(lines):
    out, end = [], None
    for ln in lines:
        if end is not None:
            if ln.strip() == end:
                end = None
            out.append('')
            continue
        out.append(ln)
        m = re.search(r'<<-?\s*([\'"]?)([A-Za-z_]\w*)\1', ln)
        if m and '<<<' not in ln:
            end = m.group(2)
    return out


def mask_text(text):
    out, cuts = [], {}
    st, i, n, line = ['c'], 0, len(text), 0
    while i < n:
        ch, top = text[i], st[-1]
        if ch == '\n':
            out.append('\n'); line += 1; i += 1
            continue
        if top == 'd':
            if ch == '\\':
                i += 2 if text[i + 1:i + 2] != '\n' else 1
                continue
            if ch == '"':
                st.pop(); i += 1; continue
            if text.startswith('$(', i):
                st.append('p'); out.append('$('); i += 2; continue
            i += 1
            continue
        if ch == '#' and (i == 0 or text[i - 1] in ' \t;&|(\n'):
            j = text.find('\n', i)
            j = n if j < 0 else j
            cuts[line] = i - (text.rfind('\n', 0, i) + 1)
            i = j
            continue
        if ch == '\\':
            out.append(text[i:i + 2]); line += text[i:i + 2].count('\n'); i += 2
            continue
        if ch == "'":
            j = text.find("'", i + 1)
            j = n - 1 if j < 0 else j
            out.append('Q' + '\n' * text[i:j].count('\n')); line += text[i:j].count('\n'); i = j + 1
            continue
        if ch == '`':
            j = text.find('`', i + 1)
            j = n - 1 if j < 0 else j
            out.append('Q' + '\n' * text[i:j].count('\n')); line += text[i:j].count('\n'); i = j + 1
            continue
        if ch == '"':
            m = re.match(r'"(\$\{?\w+\}?)"', text[i:])
            if m:
                out.append(m.group(1).replace('{', '').replace('}', '')); i += m.end(); continue
            st.append('d'); out.append('Q'); i += 1
            continue
        if text.startswith('$(', i):
            st.append('p'); out.append('$('); i += 2; continue
        if ch == ')' and top == 'p':
            st.pop(); out.append(')'); i += 1; continue
        out.append(ch); i += 1
    return ''.join(out), cuts


def normalise(text):
    text = re.sub(r'"\$\{\w+:-gh\}"', 'gh', text)
    text = re.sub(r'\$\{\w+:-gh\}', 'gh', text)
    return re.sub(r'(?<![\\`])`([^`\n]*)`', r'$(\1)', text)


def api_is_read(tokens):
    graphql = field = 0
    prev = ''
    for a in tokens:
        if prev in ('-X', '--method') and a != 'GET':
            return False
        if a in ('--input',) or a.startswith('--input=') or '=@' in a:
            return False
        if a == 'graphql':
            graphql = 1
        elif a in ('-f', '-F', '--field', '--raw-field') or re.match(r'^(-f|-F).', a) or a.startswith(('--field=', '--raw-field=')):
            field = 1
        elif a in ('-XGET', '--method=GET'):
            pass
        elif re.match(r'^-X.', a) or a.startswith('--method='):
            return False
        elif 'mutation' in a:
            return False
        prev = a
    return field == 0 or graphql == 1


def tokens_after(plain, pos):
    toks, cur, q, depth = [], '', None, 0
    i, s = pos, plain
    while i < len(s):
        c = s[i]
        if q:
            if c == q:
                q = None
            else:
                cur += c
        elif c in '\'"':
            q = c
        elif c == '$' and s[i + 1:i + 2] == '(':
            depth += 1; cur += '$('; i += 1
        elif c == ')':
            if depth == 0:
                break
            depth -= 1; cur += c
        elif c in ';|&<>' and depth == 0:
            break
        elif c in ' \t':
            if cur:
                toks.append(cur); cur = ''
        else:
            cur += c
        i += 1
    if cur:
        toks.append(cur)
    return toks


def verb_is_read(plain_line, verb_start):
    toks = tokens_after(plain_line, verb_start)
    if toks and toks[0] == 'api':
        return api_is_read(toks[1:])
    return True


def logical_lines(masked_lines, raw_lines):
    out, i = [], 0
    while i < len(masked_lines):
        j, m, r = i, masked_lines[i], raw_lines[i]
        while m.rstrip().endswith('\\') and j + 1 < len(masked_lines):
            j += 1
            m = m.rstrip()[:-1] + ' ' + masked_lines[j]
            r = r + '\n' + raw_lines[j]
        out.append((i, m, r))
        i = j + 1
    return out


def scan_shell(path, text):
    hits = []
    raw_lines = text.split('\n')
    text = '\n'.join(blank_heredocs(raw_lines))
    norm = normalise(text)
    masked, cuts = mask_text(norm)
    mlines, nlines = masked.split('\n'), norm.split('\n')
    plain = [(l[:cuts[k]] if k in cuts else l) for k, l in enumerate(nlines)]
    plain_vars, helper_vars = set(), set()
    for k, l in enumerate(plain):
        for m in re.finditer(r'(?:^|[\s;(])(\w+)=(["\']?)gh\2(?=\s|;|\)|$)', l):
            if not re.search(r'\|\|\s*$', l[:m.start(1)]):
                plain_vars.add(m.group(1))
        for m in re.finditer(r'(?:^|[\s;(])(\w+)=("?)[^\s;]*(?:gh-read\.sh|\$\{?GH_READ_\w+)', l):
            helper_vars.add(m.group(1))
    plain_vars -= helper_vars
    var_hit = None
    if plain_vars:
        names = '|'.join(re.escape(v) for v in sorted(plain_vars))
        var_hit = re.compile(START + PREFIX + r'\$\{?(?:' + names + r')\}?\s+(' + VERBS + r')')
    for k, m, r in logical_lines(mlines, raw_lines):
        if MARK in r:
            continue
        joined = ' '.join(plain[k:k + r.count('\n') + 1])
        apis = [x.start(1) for x in re.finditer(r'(?:\bgh|"?\$\{?\w+\}?"?)\s+(api)\b', joined)]
        ms = []
        for rx in (GH_HIT, var_hit):
            if rx is not None:
                ms += list(rx.finditer(m))
        ms.sort(key=lambda x: x.start())
        n_api = 0
        for mm in ms:
            if mm.group(1) == 'api':
                pos = apis[n_api] if n_api < len(apis) else None
                n_api += 1
                if pos is not None and not verb_is_read(joined, pos):
                    continue
            hits.append((path, k + 1, raw_lines[k].strip()))
            break
    return hits


def scan_script(path, text):
    hits = []
    cmt = '#' if path.endswith('.py') else '//'
    for k, ln in enumerate(text.split('\n')):
        if MARK in ln:
            continue
        code, q, i = '', None, 0
        while i < len(ln):
            c = ln[i]
            if q:
                code += c
                if c == '\\':
                    code += ln[i + 1:i + 2]; i += 1
                elif c == q:
                    q = None
            elif c in '\'"`':
                q = c; code += c
            elif ln.startswith(cmt, i) and not (cmt == '//' and ln[i - 1:i] == ':'):
                break
            else:
                code += c
            i += 1
        if re.search(r'''(?<![\w.-])(['"])gh\1(?![\w.-])''', code) and not re.search(r'existsSync|isfile|\.exists\(|is_file', code):
            hits.append((path, k + 1, ln.strip()))
    return hits


def main():
    hits = []
    for path in sys.stdin.read().split('\n'):
        path = path.strip()
        if not path or not wanted(path):
            continue
        with open(os.path.join(ROOT, path), encoding='utf-8', errors='replace') as fh:
            text = fh.read()
        hits += scan_shell(path, text) if path.endswith('.sh') else scan_script(path, text)
    for path, k, ln in hits:
        print('%s:%d: %s' % (path, k, ln[:160]))


main()
F0PY
f0_hits() {
    rm -rf "$W/f0t"; mkdir -p "$W/f0t/scripts/handover"
    printf '%s\n' "$2" > "$W/f0t/scripts/handover/ctl.$1"
    printf 'scripts/handover/ctl.%s\n' "$1" | python3 -I "$W/f0.py" "$W/f0t" 2>/dev/null | grep -c .
}
f0_row() { check "F0 $2" "$1" "$(f0_hits "$3" "$4")"; }
f0_row 1 'control: timeout -k 2 30 gh pr list is a hit' sh 'timeout -k 2 30 gh pr list --state open'  # gnu-ok: scanner input text, never run
f0_row 1 'control: bounded 30 gh api x is a hit' sh 'bounded 30 gh api x'
f0_row 1 'control: x=$(gh repo view) is a hit' sh 'x=$(gh repo view --json name)'
f0_row 1 'control: x=`gh pr list` is a hit' sh 'x=`gh pr list --state open`'
f0_row 1 'control: "${GH_CMD:-gh}" pr view is a hit' sh '"${GH_CMD:-gh}" pr view 1'
f0_row 1 'control: a variable set from ${X:-gh} then used on pr view is a hit' sh $'GH="${X_GH:-gh}"\n"$GH" pr view 1'
f0_row 1 'control: GH="gh" then an api rulesets read is a hit' sh $'GH="gh"\n"$GH" api repos/o/r/rulesets/1'
f0_row 1 'control: execFileSync(gh, [pr, list]) is a hit' mjs "execFileSync('gh', ['pr','list'])"
f0_row 1 "control: os.environ.get('X') or 'gh' is a hit" py "gh = os.environ.get('X') or 'gh'"
f0_row 0 'control: gh named in an echoed message is no hit' sh 'echo "(gh repo view failed)"'
f0_row 0 'control: gh named in backticks inside a quoted printf is no hit' sh $'printf -- \'query via `gh pr list`\\n\''
f0_row 0 'control: gh named in a comment is no hit' sh '# gh pr list'
f0_row 0 'control: "$GH_READ_BIN" pr view is no hit' sh '"$GH_READ_BIN" pr view 1'
f0_row 0 'control: gh pr merge is no hit' sh 'gh pr merge 1 --squash'
f0_row 0 'control: a POST api call is no hit' sh 'gh api -X POST repos/o/r/issues/1/comments -f body=x'
f0_row 0 'control: gh run cancel is no hit' sh 'gh run cancel 5'
f0_row 0 'control: the fallback form [ -f "$G" ] || G=gh then "$G" pr view is no hit' sh $'[ -f "$G" ] || G=gh\n"$G" pr view 1'
f0_row 0 'control: a variable the file also points at the helper is no hit' sh $'GH="${GH_CMD:-gh}"\nGH_READ_LIB=/x/scripts/lib/gh-read.sh\nGH="$GH_READ_LIB"\n"$GH" pr view 1'
f0_row 0 'control: a hit with gh-main-ok on its line is no hit' sh $'GH="gh"\n"$GH" api x  # gh-main-ok: permission-dependent answer'
f0_row 1 'control: in_reviewed gh pr view is a hit' sh 'in_reviewed gh pr view 1'
f0_row 1 'control: in_reviewed ${t:+"$t" -k 5 30} gh pr view is a hit' sh 'x=$(in_reviewed ${t:+"$t" -k 5 30} gh pr view 1 --json headRefOid)'
f0_row 0 'control: in_reviewed gh pr view with gh-main-ok on its line is no hit' sh 'in_reviewed gh pr view 1  # gh-main-ok: verdict-write read'
mkdir -p "$W/f0wv/scripts/handover/chief-kit"
sed 's/; gh-main-ok: [^#]*$//' "$REPO/scripts/handover/chief-kit/write-verdict.sh" > "$W/f0wv/scripts/handover/chief-kit/write-verdict.sh"
cmp -s "$REPO/scripts/handover/chief-kit/write-verdict.sh" "$W/f0wv/scripts/handover/chief-kit/write-verdict.sh" && fail "F0 control: the write-verdict.sh copy equals the original (no marker was stripped)"
f0_wv="$(printf 'scripts/handover/chief-kit/write-verdict.sh\n' | python3 -I "$W/f0.py" "$W/f0wv" 2>/dev/null)"
check "F0 control: write-verdict.sh without its gh-main-ok marker is a hit on the --bind head read" "yes" "$(case "$f0_wv" in (*'in_reviewed'*'gh pr view "$PR"'*) echo yes ;; esac)"
mkdir -p "$W/f0real/scripts/handover/chief-kit"
sed 's|CHIEF_WAIT_GH:-\$GH_READ_BIN|CHIEF_WAIT_GH:-gh|' "$REPO/scripts/handover/chief-kit/chief-wait.sh" > "$W/f0real/scripts/handover/chief-kit/chief-wait.sh"
cmp -s "$REPO/scripts/handover/chief-kit/chief-wait.sh" "$W/f0real/scripts/handover/chief-kit/chief-wait.sh" && fail "F0 control: the chief-wait.sh copy equals the original (nothing moved)"
f0_mut="$(printf 'scripts/handover/chief-kit/chief-wait.sh\n' | python3 -I "$W/f0.py" "$W/f0real" 2>/dev/null)"
check "F0 control: chief-wait.sh with its PR watch seam default back on gh is a hit" "yes" "$(case "$f0_mut" in (*'"$gh_cmd" api'*) echo yes ;; esac)"
f0_tracked="$(git -C "$REPO" ls-files scripts/handover)"
check "F0 reads the tracked files (chief-wait.sh is among them, so the empty result below is not vacuous)" "yes" "$(case "$f0_tracked" in (*chief-kit/chief-wait.sh*) echo yes ;; esac)"
check "F0 no read-shaped gh call under scripts/handover is unjustified" "" "$(printf '%s\n' "$f0_tracked" | python3 -I "$W/f0.py" "$REPO" 2>&1)"

mkdir -p "$W/g0root"
printf 'touch "%s/g0marker"\n' "$W" > "$W/g0evil.sh"
rm -f "$W/g0marker"
_GHR_LOAD_DOTENV="$W/g0evil.sh" run_gh_read "$W/g0root" pr view 12
check "G0 the environment never chooses the file gh-read.sh sources (_GHR_LOAD_DOTENV is ignored)" "" "$(ls "$W/g0marker" 2>/dev/null)"

printf '%s fail\n' "$fails"
[ "$fails" -eq 0 ]
