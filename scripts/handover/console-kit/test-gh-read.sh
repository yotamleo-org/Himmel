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
# PLATFORM GUARD: no .ps1 twin, by design. The console kit is Linux-only.
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
check() { # <name> <want> <got>
    if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (want '$2' got '$3')"; fi
}
has() { # <name> <needle> <haystack>
    case "$3" in *"$2"*) pass "$1" ;; *) fail "$1 (no '$2' in '$3')" ;; esac
}
lacks() { # <name> <needle> <haystack>
    case "$3" in *"$2"*) fail "$1 (found '$2' in '$3')" ;; *) pass "$1" ;; esac
}

READTOK=ghp_READTOKEN0123456789
mkdir -p "$W/bin" "$W/home" "$W/root" "$W/emptyroot"
printf 'himmel_github_token_vm2=%s\n' "$READTOK" > "$W/root/.env"
: > "$W/emptyroot/.env"
cat > "$W/bin/gh" <<'STUB'
#!/usr/bin/env bash
# logs "tok=<GH_TOKEN or main> argv=<args>"; GH_STUB_READFAIL makes the read token's calls fail
printf 'tok=%s argv=%s\n' "${GH_TOKEN:-main}" "$*" >> "$GHLOG"
if [ "${GH_TOKEN:-}" = "ghp_READTOKEN0123456789" ] && [ -n "${GH_STUB_READFAIL:-}" ]; then
    echo "partial-page"
    case "$GH_STUB_READFAIL" in
        scope) echo "gh: Resource not accessible by personal access token" >&2 ;;
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
export GHLOG="$W/gh.log" HOME="$W/home" PATH="$W/bin:$PATH"
unset GH_TOKEN GITHUB_TOKEN himmel_github_token_vm2

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
for w in scripts/handover/merge-on-green.sh scripts/lib/go-gate.sh scripts/handover/console-kit/write-verdict.sh scripts/cr/write-verdicts.sh; do
    lacks "A3 write path $w does not source the read helper" "$w " "$callers"
done

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
for f in scripts/check-ci.sh scripts/handover/console-kit/go.sh scripts/handover/console-kit/ready-check.sh scripts/handover/console-kit/tick.sh; do
    if grep -q 'gh_read\|gh-read.sh\|GH_READ' "$REPO/$f"; then pass "B3 $f routes its reads through the helper"; else fail "B3 $f does not use the helper"; fi
done
# ready-check: its first read (repo view) rides the read token end to end
: > "$GHLOG"
GH_READ_ENV_ROOT="$W/root" bash "$REPO/scripts/handover/console-kit/ready-check.sh" --only 7 99 >/dev/null 2>&1
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
check "B6 go.sh reads via the helper" "2" "$(grep -c '"\$GH_READ" \(pr\|repo\) view' "$REPO/scripts/handover/console-kit/go.sh")"
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

printf '%s fail\n' "$fails"
[ "$fails" -eq 0 ]
