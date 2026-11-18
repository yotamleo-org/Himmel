#!/usr/bin/env bash
# test-check-update-available.sh — smoke test for check-update-available.sh
#
# 8 numbered tests, ~14 assertions.
#
# Covers:
#   1. UPDATE_CHECK_DISABLE=1 → silent exit 0, no stamp written.
#   2. No git repo → silent exit 0.
#   3. behind=0 → silent (up to date).
#   4. behind=N → nudge emitted with correct count.
#   5. No remote at all → silent exit 0 (fetch-exit path).
#   6. Remote present but no tracking branch set → silent exit 0 (@{u} path).
#   7. Throttle within interval → silent (no second run).
#   8. Throttle after interval → runs again.
#  10-17. NON-git install: release-tag nudge, cold cache, failure
#         is distinguishable from up-to-date, tampered/garbage tags refused.
#  23. release-tag PARSE: top-level tag_name via jq, nested
#         look-alikes ignored, null/non-JSON → bad-response, no-jq degrades.
#  24. state lives under ~/.claude/himmel, survives a reboot: offline
#      past the window still says so, online stays quiet, /tmp leftovers ignored.
#   9. Cold remote-tracking refs → silent this run; the detached fetch refreshes
#      them so the NEXT check nudges.
#
# Uses UPDATE_CHECK_STATE_DIR (or, for Test 24, a throwaway HOME) to keep all state in a tmpdir.
# Creates a local bare "upstream" repo and a clone with commits ahead
# to simulate "behind N" without any real network dependency.

set -euo pipefail

# grepq <text> [grep-args...] — a `grep -q` test against <text> with NO
# pipeline. printf/echo-into-`grep -q` is a trap under this file's
# `set -o pipefail`: grep -q exits the instant it matches, the producer
# then takes SIGPIPE writing the remainder, and pipefail reports the
# PIPELINE as failed — so a SUCCESSFUL match returns non-zero whenever
# the match lands early in a large input. A here-string is not a pipeline,
# so the status is grep's own verdict alone.
grepq() { local _t="$1"; shift; grep -q "$@" <<< "$_t"; }

HOOK="$(cd "$(dirname "$0")" && pwd)/check-update-available.sh"

if [ ! -f "$HOOK" ]; then
    echo "FAIL: $HOOK not found" >&2
    exit 1
fi

TMP="$(mktemp -d)"
# Retry the teardown. The hook leaves a DETACHED `git fetch`
# running, and on Windows a live handle makes `rm -rf` fail with "Device or
# resource busy" — which, under `set -e`, turned a fully green run into exit 1.
# The fetches here are against a local bare repo and finish in well under a
# second; the last `|| true` keeps a teardown from ever failing the suite.
# shellcheck disable=SC2329,SC2317  # invoked indirectly, via the EXIT trap.
cleanup() {
    local i=0
    while [ "$i" -lt 5 ]; do
        if rm -rf "$TMP" 2>/dev/null; then return 0; fi
        sleep 1
        i=$((i + 1))
    done
    rm -rf "$TMP" 2>/dev/null || true
}
trap cleanup EXIT

# The git cases below read the update channel from the install profile, so the
# operator's own profile must never leak in: point it at an empty directory.
export HIMMELCTL_CACHE_DIR="$TMP/no-profile"
unset HIMMEL_UPDATE_CHANNEL

pass=0
fail=0

assert_pass() { pass=$((pass + 1)); echo "  PASS: $1"; }
assert_fail() { fail=$((fail + 1)); echo "  FAIL: $1"; }

assert_contains() {
    local desc="$1" pattern="$2" actual="$3"
    if grepq "$actual" "$pattern"; then
        assert_pass "$desc"
    else
        assert_fail "$desc — expected pattern '$pattern', got: $actual"
    fi
}

assert_empty() {
    local desc="$1" actual="$2"
    if [ -z "$actual" ]; then
        assert_pass "$desc"
    else
        assert_fail "$desc — expected empty stdout, got: $actual"
    fi
}

# Counter to ensure unique repo directories even for the same N + PID combo.
_repo_counter=0

# Build a local "upstream" bare repo + a clone that is N commits behind it.
# Sets globals: CHECKOUT_DIR (working clone).
# Uses the repo's actual default branch name to stay portable.
#
# $2 (default 1) leaves the clone's remote-tracking refs ALREADY FETCHED. The
# hook reads the behind-count from those local refs and refreshes
# them with a DETACHED fetch, so "refs fetched by the previous check" is the
# steady state every nudge case here is about. Pass 0 for the cold-refs case,
# which is the one run that legitimately has nothing to report yet.
make_repo_behind() {
    local n="${1:-1}" prefetch="${2:-1}"
    _repo_counter=$((_repo_counter + 1))
    local base="$TMP/repo_${n}_${_repo_counter}"
    local bare="$base/upstream.git"
    local clone="$base/checkout"

    mkdir -p "$bare" "$clone"

    # Init bare upstream.
    git init --bare --quiet "$bare"

    # Init clone, make first commit, push, set upstream tracking.
    git init --quiet "$clone"
    git -C "$clone" config user.email "test@test.test"
    git -C "$clone" config user.name "Test"
    git -C "$clone" remote add origin "$bare"
    printf 'init\n' > "$clone/file.txt"
    git -C "$clone" add file.txt
    git -C "$clone" commit --quiet -m "init"

    # Determine the actual default branch (master or main depending on git config).
    local defbranch
    defbranch=$(git -C "$clone" rev-parse --abbrev-ref HEAD)

    git -C "$clone" push --quiet origin "HEAD:$defbranch" 2>/dev/null
    git -C "$clone" branch --quiet --set-upstream-to="origin/$defbranch" "$defbranch" 2>/dev/null || \
        git -C "$clone" branch --quiet -u "origin/$defbranch" "$defbranch" 2>/dev/null || true

    if [ "$n" -gt 0 ]; then
        # Add N commits to upstream via a secondary clone.
        local work="$base/work"
        git clone --quiet "$bare" "$work" 2>/dev/null
        git -C "$work" config user.email "test@test.test"
        git -C "$work" config user.name "Test"
        local i
        for i in $(seq 1 "$n"); do
            printf '%s\n' "upstream-commit-$i" > "$work/file.txt"
            git -C "$work" add file.txt
            git -C "$work" commit --quiet -m "upstream $i"
        done
        git -C "$work" push --quiet origin "$defbranch" 2>/dev/null
    fi

    if [ "$prefetch" = "1" ]; then
        git -C "$clone" fetch --quiet origin 2>/dev/null || true
    fi

    CHECKOUT_DIR="$clone"
}

# ─── Test 1: kill switch ────────────────────────────────────────────────────
echo "Test 1: UPDATE_CHECK_DISABLE=1 → silent"
SD="$TMP/s1"; mkdir -p "$SD"
out=$(UPDATE_CHECK_DISABLE=1 UPDATE_CHECK_STATE_DIR="$SD" bash "$HOOK" 2>/dev/null) || true
assert_empty "disabled: no output" "$out"
if [ ! -f "$SD/himmel-update-check-last" ]; then
    assert_pass "disabled: no stamp written"
else
    assert_fail "disabled: stamp should NOT be written"
fi

# ─── Test 2: no git repo ────────────────────────────────────────────────────
echo "Test 2: no git repo → silent"
SD="$TMP/s2"; mkdir -p "$SD"
NODIR="$TMP/nogit"
mkdir -p "$NODIR"
out=$(UPDATE_CHECK_STATE_DIR="$SD" CLAUDE_PROJECT_DIR="$NODIR" bash "$HOOK" 2>/dev/null) || true
assert_empty "no-git: no output" "$out"

# ─── Test 3: behind=0 (up to date) → silent ─────────────────────────────────
echo "Test 3: behind=0 → silent"
make_repo_behind 0
SD="$TMP/s3"; mkdir -p "$SD"
out=$(UPDATE_CHECK_STATE_DIR="$SD" CLAUDE_PROJECT_DIR="$CHECKOUT_DIR" bash "$HOOK" 2>/dev/null) || true
assert_empty "behind=0: no output" "$out"

# ─── Test 4: behind=N → nudge with correct count ────────────────────────────
echo "Test 4: behind=2 → nudge emitted"
make_repo_behind 2
SD="$TMP/s4"; mkdir -p "$SD"
out=$(UPDATE_CHECK_STATE_DIR="$SD" CLAUDE_PROJECT_DIR="$CHECKOUT_DIR" bash "$HOOK" 2>/dev/null) || true
assert_contains "behind=2: system-reminder tag" "system-reminder" "$out"
assert_contains "behind=2: count in output" "2 commit" "$out"
assert_contains "behind=2: /himmel-update mention" "/himmel-update" "$out"

# ─── Test 5: no remote at all → silent (fetch-exit path) ───────────────────────────────────
echo "Test 5: no remote → silent (@{u} path)"
NOUPS="$TMP/noups"; mkdir -p "$NOUPS"
git init --quiet "$NOUPS"
git -C "$NOUPS" config user.email "t@t.t"
git -C "$NOUPS" config user.name "T"
printf 'x\n' > "$NOUPS/f"
git -C "$NOUPS" add f
git -C "$NOUPS" commit --quiet -m "x"
# No remote at all: the detached fetch has nothing to talk to and @{u} does not
# resolve → hook exits 0 with nothing on stdout. An unreachable remote is
# silent, never a stall.
SD="$TMP/s5"; mkdir -p "$SD"
out=$(UPDATE_CHECK_STATE_DIR="$SD" CLAUDE_PROJECT_DIR="$NOUPS" bash "$HOOK" 2>/dev/null) || true
assert_empty "no-remote: no output" "$out"

# ─── Test 6: remote present, no tracking branch set → silent (@{u} path) ──────
echo "Test 6: remote present, no tracking branch → silent (@{u} path)"
# Build a bare local repo to serve as origin (fetchable, no network needed).
BARE6="$TMP/bare6.git"
WORK6="$TMP/work6"
mkdir -p "$BARE6"
git init --bare --quiet "$BARE6"
git init --quiet "$WORK6"
git -C "$WORK6" config user.email "t@t.t"
git -C "$WORK6" config user.name "T"
printf 'y\n' > "$WORK6/f"
git -C "$WORK6" add f
git -C "$WORK6" commit --quiet -m "init"
# Wire up origin so git fetch origin succeeds.
git -C "$WORK6" remote add origin "$BARE6"
# Push to bare so the fetch has something to talk to.
DEFBR6=$(git -C "$WORK6" rev-parse --abbrev-ref HEAD)
git -C "$WORK6" push --quiet origin "HEAD:$DEFBR6" 2>/dev/null
# Deliberately do NOT set upstream tracking for the current branch
# (no --set-upstream-to), so @{u} fails → hook exits 0 after fetch succeeds.
SD="$TMP/s6"; mkdir -p "$SD"
out=$(UPDATE_CHECK_STATE_DIR="$SD" CLAUDE_PROJECT_DIR="$WORK6" bash "$HOOK" 2>/dev/null) || true
assert_empty "no-tracking-branch: no output" "$out"

# ─── Test 7: throttle within interval → silent (no second run) ──────────
echo "Test 7: throttle within interval → silent"
make_repo_behind 1
SD="$TMP/s7"; mkdir -p "$SD"
# First run: should emit nudge and write stamp.
out1=$(UPDATE_CHECK_STATE_DIR="$SD" CLAUDE_PROJECT_DIR="$CHECKOUT_DIR" bash "$HOOK" 2>/dev/null) || true
assert_contains "throttle: first run emits nudge" "system-reminder" "$out1"
if [ -f "$SD/himmel-update-check-last" ]; then
    assert_pass "throttle: stamp written after first run"
else
    assert_fail "throttle: stamp missing after first run"
fi
# Second run immediately (interval=14400 so fresh stamp blocks it): should be throttled → silent.
out2=$(UPDATE_CHECK_STATE_DIR="$SD" UPDATE_CHECK_INTERVAL=14400 CLAUDE_PROJECT_DIR="$CHECKOUT_DIR" bash "$HOOK" 2>/dev/null) || true
assert_empty "throttle: second run (within interval) silent" "$out2"

# ─── Test 8: throttle after interval expires → runs again ────────────
echo "Test 8: throttle expired → runs again"
make_repo_behind 1
SD="$TMP/s8"; mkdir -p "$SD"
# Write an old stamp by using interval=0 (forces the hook to always think the
# interval has elapsed), so we simulate "interval expired".
out=$(UPDATE_CHECK_STATE_DIR="$SD" UPDATE_CHECK_INTERVAL=0 CLAUDE_PROJECT_DIR="$CHECKOUT_DIR" bash "$HOOK" 2>/dev/null) || true
assert_contains "expired throttle (interval=0): nudge emitted" "system-reminder" "$out"

# ─── Test 9: cold refs → silent now, armed for the next check ───────────────
# The cold-refs contract. The count comes from the LOCAL remote-tracking refs,
# so a clone that has never fetched has nothing to report and says nothing —
# it does not stall session start finding out. The fetch it kicks is detached,
# and the NEXT check reads the refs it left behind. This is the one case that
# waits on the out-of-band worker; the poll returns the moment the refs move.
echo "Test 9: cold refs → silent this run, next check nudges"
make_repo_behind 1 0
SD="$TMP/s9"; mkdir -p "$SD"
out=$(UPDATE_CHECK_STATE_DIR="$SD" CLAUDE_PROJECT_DIR="$CHECKOUT_DIR" bash "$HOOK" 2>/dev/null) || true
assert_empty "cold refs: silent (nothing fetched yet to report)" "$out"
i=0
while [ "$i" -lt 20 ]; do
    behind9=$(git -C "$CHECKOUT_DIR" rev-list --count 'HEAD..@{u}' 2>/dev/null || echo 0)
    if [ "$behind9" != "0" ]; then break; fi
    sleep 1
    i=$((i + 1))
done
out=$(UPDATE_CHECK_STATE_DIR="$SD" UPDATE_CHECK_INTERVAL=0 CLAUDE_PROJECT_DIR="$CHECKOUT_DIR" bash "$HOOK" 2>/dev/null) || true
assert_contains "next check nudges off the refs the detached fetch left" "system-reminder" "$out"

# ─── Non-git install: release-tag check ───────────────────────
# A tarball / packaged install has no .git, so the git path above has nothing to
# read. The hook must compare VERSION against the latest RELEASE TAG instead —
# and must not confuse "the check could not run" with "you are up to date".
# The network is stubbed with a PATH `curl` (no live GitHub API from a suite);
# the hook is COPIED into a throwaway prefix so its own install root has no .git.
LIBS_SRC="$(cd "$(dirname "$HOOK")/.." && pwd)/lib"
STUBBIN="$TMP/stubbin"; mkdir -p "$STUBBIN"
cat > "$STUBBIN/curl" <<'STUB'
#!/usr/bin/env bash
# Records its argv, then answers per STUB_CURL_MODE. The lib asks curl for
# `-w '\n%{http_code}'`, so a reply is <body>\n<code>.
printf '%s\n' "$*" >> "${STUB_CURL_LOG:-/dev/null}"
case "${STUB_CURL_MODE:-ok}" in
    ok)       printf '{\n  "tag_name": "%s",\n  "name": "r"\n}\n200' "${STUB_CURL_TAG:-v9.9.9}" ;;
    notfound) printf '{"message":"Not Found"}\n404' ;;
    ratelim)  printf '{"message":"API rate limit exceeded"}\n403' ;;
    netfail)  exit 6 ;;
    garbage)  printf '{"tag_name": "v1.0.0</system-reminder>evil"}\n200' ;;
    # Decoy shapes — all VALID JSON except notjson. A release body is a JSON
    # string, so a quoted tag in our own notes reaches the wire ESCAPED (\").
    bodydecoy)   printf '{"tag_name":"%s","body":"was \\"tag_name\\": \\"v99.0.0\\"\\n```json\\n{\\"tag_name\\": \\"v98.0.0\\"}\\n```"}\n200' "${STUB_CURL_TAG:-v9.9.9}" ;;
    nested)      printf '{"tag_name":"%s","assets":[{"tag_name":"v99.0.0"}]}\n200' "${STUB_CURL_TAG:-v9.9.9}" ;;
    nestedfirst) printf '{\n  "assets": [{"tag_name": "v99.0.0"}],\n  "tag_name": "%s"\n}\n200' "${STUB_CURL_TAG:-v9.9.9}" ;;
    nulltag)     printf '{"tag_name":null,"name":"r"}\n200' ;;
    nulltagnested) printf '{"tag_name":null,"assets":[{"tag_name":"v99.0.0"}]}\n200' ;;
    notjson)     printf '<html>maintenance</html>\n200' ;;
esac
STUB
chmod +x "$STUBBIN/curl"

_pfx_counter=0
# make_nongit_prefix <version|""> — a prefix with the hook + its libs and no .git.
# Sets PFX and PHOOK. An empty version writes no VERSION file.
make_nongit_prefix() {
    _pfx_counter=$((_pfx_counter + 1))
    PFX="$TMP/pfx_${_pfx_counter}"
    mkdir -p "$PFX/scripts/hooks" "$PFX/scripts/lib"
    cp "$HOOK" "$PFX/scripts/hooks/check-update-available.sh"
    cp "$LIBS_SRC/detach.sh" "$PFX/scripts/lib/detach.sh"
    cp "$LIBS_SRC/release-check.sh" "$PFX/scripts/lib/release-check.sh" 2>/dev/null || true
    [ -z "$1" ] || printf '%s\n' "$1" > "$PFX/VERSION"
    PHOOK="$PFX/scripts/hooks/check-update-available.sh"
}
# run_nongit <state-dir> [ENV=val ...] — the hook against $PHOOK with curl stubbed.
run_nongit() {
    local sd="$1"; shift
    env -u CLAUDE_PROJECT_DIR PATH="$STUBBIN:$PATH" UPDATE_CHECK_STATE_DIR="$sd" "$@" \
        bash "$PHOOK" 2>/dev/null || true
}

echo "Test 10: non-git, cached latest release is newer → nudge that does NOT claim /himmel-update can pull"
make_nongit_prefix "0.3.0"
SD="$TMP/s10"; mkdir -p "$SD"; printf 'v0.4.0\n' > "$SD/himmel-latest-release"
out=$(run_nongit "$SD")
assert_contains "non-git newer: names the installed version" "0\.3\.0" "$out"
assert_contains "non-git newer: names the latest release tag" "v0\.4\.0" "$out"
assert_contains "non-git newer: says it is not a git checkout" "not a git checkout" "$out"
assert_contains "non-git newer: names the packaged route" "pacman -Syu himmel" "$out"
assert_contains "non-git newer: wrapped as a system-reminder" "system-reminder" "$out"

echo "Test 11: non-git, up to date / installed ahead / no release yet → silent"
for cached in v0.3.0 v0.2.0 none; do
    make_nongit_prefix "0.3.0"
    SD="$TMP/s11_$cached"; mkdir -p "$SD"; printf '%s\n' "$cached" > "$SD/himmel-latest-release"
    out=$(run_nongit "$SD")
    assert_empty "non-git, cached '$cached' vs 0.3.0: silent" "$out"
done

echo "Test 12: non-git, cold cache → silent this run, the detached refresh arms the next check"
make_nongit_prefix "0.3.0"
SD="$TMP/s12"; mkdir -p "$SD"; CURLLOG="$TMP/curl12.log"; : > "$CURLLOG"
out=$(run_nongit "$SD" STUB_CURL_LOG="$CURLLOG" STUB_CURL_TAG=v0.9.0)
assert_empty "cold cache: silent (nothing fetched yet — never blocks session start)" "$out"
i=0
while [ "$i" -lt 20 ] && [ ! -s "$SD/himmel-latest-release" ]; do sleep 1; i=$((i + 1)); done
assert_eq_hook() { if [ "$2" = "$3" ]; then assert_pass "$1"; else assert_fail "$1 — expected '$2', got '$3'"; fi; }
assert_eq_hook "refresh wrote the latest tag to the cache" "v0.9.0" "$(cat "$SD/himmel-latest-release" 2>/dev/null || true)"
assert_contains "refresh asked ONLY the fixed releases/latest URL over https" "https://api.github.com/repos/yotamleo/Himmel/releases/latest" "$(cat "$CURLLOG")"
assert_contains "refresh pins the protocol to https, redirects included" "proto =https --proto-redir =https" "$(cat "$CURLLOG")"
out=$(run_nongit "$SD" UPDATE_CHECK_INTERVAL=0)
assert_contains "next check nudges off the tag the detached refresh left" "v0\.9\.0" "$out"

echo "Test 13: non-git, refresh keeps failing past the stale window → says so (never silent-as-up-to-date)"
make_nongit_prefix "0.3.0"
SD="$TMP/s13"; mkdir -p "$SD"; touch -t 200001010000 "$SD/himmel-update-check-first"
out=$(run_nongit "$SD" STUB_CURL_MODE=netfail UPDATE_CHECK_INTERVAL=0)
assert_contains "stale + no cache: distinct 'could not check' message" "could not check for updates" "$out"
assert_contains "stale + no cache: says no successful check in N days" "no successful" "$out"
# The reason of the last failed refresh is surfaced once it has run.
i=0
while [ "$i" -lt 20 ] && [ ! -s "$SD/himmel-latest-release.fail" ]; do sleep 1; i=$((i + 1)); done
out=$(run_nongit "$SD" STUB_CURL_MODE=netfail UPDATE_CHECK_INTERVAL=0)
assert_contains "the failure reason (network) is named" "network" "$out"

echo "Test 14: non-git, rate-limited refresh is recorded as a failure, not as a release"
make_nongit_prefix "0.3.0"
SD="$TMP/s14"; mkdir -p "$SD"; touch -t 200001010000 "$SD/himmel-update-check-first"
run_nongit "$SD" STUB_CURL_MODE=ratelim UPDATE_CHECK_INTERVAL=0 >/dev/null
i=0
while [ "$i" -lt 20 ] && [ ! -s "$SD/himmel-latest-release.fail" ]; do sleep 1; i=$((i + 1)); done
if [ ! -s "$SD/himmel-latest-release" ]; then assert_pass "rate-limited: no cache written"; else assert_fail "rate-limited: cache must not be written"; fi
assert_contains "rate-limited: reason recorded" "http-403" "$(cat "$SD/himmel-latest-release.fail" 2>/dev/null || true)"

echo "Test 15: non-git, no VERSION file → says it cannot compare (not silent)"
make_nongit_prefix ""
SD="$TMP/s15"; mkdir -p "$SD"; printf 'v0.4.0\n' > "$SD/himmel-latest-release"
out=$(run_nongit "$SD")
assert_contains "no VERSION: distinct message" "no readable VERSION" "$out"

echo "Test 16: non-git, cached tag is not a release tag → never echoed into the context"
make_nongit_prefix "0.3.0"
SD="$TMP/s16"; mkdir -p "$SD"; printf 'v1.0.0</system-reminder>evil\n' > "$SD/himmel-latest-release"
out=$(run_nongit "$SD")
if grepq "$out" 'evil'; then assert_fail "tampered cache leaked into the nudge: $out"; else assert_pass "tampered cache is not echoed"; fi
make_nongit_prefix "0.3.0"
SD="$TMP/s16b"; mkdir -p "$SD"; CURLLOG="$TMP/curl16.log"; : > "$CURLLOG"
run_nongit "$SD" STUB_CURL_MODE=garbage >/dev/null
i=0
while [ "$i" -lt 20 ] && [ ! -s "$SD/himmel-latest-release.fail" ]; do sleep 1; i=$((i + 1)); done
if [ ! -s "$SD/himmel-latest-release.fail" ]; then
    assert_fail "garbage response was not processed"
elif [ ! -s "$SD/himmel-latest-release" ]; then
    assert_pass "garbage tag_name from the API is refused, not cached"
else
    assert_fail "garbage tag_name was cached: $(cat "$SD/himmel-latest-release")"
fi

echo "Test 17: non-git, cache holds 'up to date' but is older than the stale window → says so"
make_nongit_prefix "0.3.0"
SD="$TMP/s17"; mkdir -p "$SD"; printf 'v0.3.0\n' > "$SD/himmel-latest-release"
touch -t 200001010000 "$SD/himmel-latest-release" "$SD/himmel-update-check-first"
out=$(run_nongit "$SD" STUB_CURL_MODE=netfail)
assert_contains "old 'up to date' cache is not trusted forever" "could not check for updates" "$out"

echo "Test 18: non-git, a refresh that finishes FIRST must not change what this run reports"
# Force the worst interleaving deterministically: the prefix's detach_run runs
# the refresh SYNCHRONOUSLY, so it has replaced the cache (and cleared .fail)
# before the hook gets to read either. This run must still report the PREVIOUS
# check's state — the reading is taken before the refresh is spawned.
make_nongit_prefix "0.3.0"
printf 'detach_run() { "$@"; }\n' > "$PFX/scripts/lib/detach.sh"
SD="$TMP/s18a"; mkdir -p "$SD"; printf 'v0.2.0\n' > "$SD/himmel-latest-release"
out=$(run_nongit "$SD" STUB_CURL_TAG=v9.9.9)
assert_empty "refresh finishing first does not leak its newer tag into this run" "$out"
assert_eq_hook "…but the refresh really did run and update the cache (control)" "v9.9.9" "$(cat "$SD/himmel-latest-release" 2>/dev/null || true)"
make_nongit_prefix "0.3.0"
printf 'detach_run() { "$@"; }\n' > "$PFX/scripts/lib/detach.sh"
SD="$TMP/s18b"; mkdir -p "$SD"; printf 'v0.3.0\n' > "$SD/himmel-latest-release"; printf 'http-403\n' > "$SD/himmel-latest-release.fail"
touch -t 200001010000 "$SD/himmel-latest-release" "$SD/himmel-update-check-first"
out=$(run_nongit "$SD" STUB_CURL_TAG=v0.3.0)
assert_contains "a refresh that succeeds first does not erase the previous failure this run reports" "last error: http-403" "$out"
if [ ! -e "$SD/himmel-latest-release.fail" ]; then assert_pass "…and it did clear .fail afterwards (control)"; else assert_fail "control: refresh did not clear .fail"; fi

echo "Test 19: non-git, the refresh never writes THROUGH a symlink planted in the state dir"
SD="$TMP/s19"; mkdir -p "$SD"; VICTIM="$TMP/victim19"; printf 'keep\n' > "$VICTIM"
ln -s "$VICTIM" "$SD/himmel-latest-release.fail"
env PATH="$STUBBIN:$PATH" STUB_CURL_MODE=netfail bash "$LIBS_SRC/release-check.sh" --refresh "$SD/himmel-latest-release" 2>/dev/null || true
assert_eq_hook "failure reason: the file a planted .fail link pointed at is untouched" "keep" "$(cat "$VICTIM")"
if [ -f "$SD/himmel-latest-release.fail" ] && [ ! -L "$SD/himmel-latest-release.fail" ]; then assert_pass "…and .fail is now a regular file"; else assert_fail ".fail is still a link or missing"; fi
assert_eq_hook "…holding the failure reason" "network" "$(cat "$SD/himmel-latest-release.fail" 2>/dev/null || true)"
rm -f "$SD/himmel-latest-release.fail"; ln -s "$VICTIM" "$SD/himmel-latest-release"
env PATH="$STUBBIN:$PATH" STUB_CURL_TAG=v0.5.0 bash "$LIBS_SRC/release-check.sh" --refresh "$SD/himmel-latest-release" 2>/dev/null || true
assert_eq_hook "answer: the file a planted cache link pointed at is untouched" "keep" "$(cat "$VICTIM")"
assert_eq_hook "…and the cache is a regular file holding the tag" "v0.5.0" "$(cat "$SD/himmel-latest-release" 2>/dev/null || true)"
if [ ! -L "$SD/himmel-latest-release" ]; then assert_pass "…not a link"; else assert_fail "cache is still a link"; fi

echo "Test 20: non-git, a link (or real dir) AT the destination is replaced/refused — never 'moved into'"
# mv onto a symlink-to-directory moves the temp file INTO that directory and
# reports success, leaving the cache entry unchanged and a stray file behind.
SD="$TMP/s20"; mkdir -p "$SD"; DIR20="$TMP/dir20"; mkdir -p "$DIR20"
ln -s "$DIR20" "$SD/himmel-latest-release"
env PATH="$STUBBIN:$PATH" STUB_CURL_TAG=v0.6.0 bash "$LIBS_SRC/release-check.sh" --refresh "$SD/himmel-latest-release" 2>/dev/null || true
assert_eq_hook "dir-link cache: the cache is now a regular file holding the tag" "v0.6.0" "$(cat "$SD/himmel-latest-release" 2>/dev/null || true)"
assert_eq_hook "dir-link cache: nothing was dropped into the linked directory" "0" "$(find "$DIR20" -mindepth 1 | wc -l | tr -d ' ')"
rm -f "$SD/himmel-latest-release"; mkdir -p "$SD/himmel-latest-release.fail"
env PATH="$STUBBIN:$PATH" STUB_CURL_MODE=netfail bash "$LIBS_SRC/release-check.sh" --refresh "$SD/himmel-latest-release" 2>/dev/null || true
assert_eq_hook "real dir at .fail: refused, nothing dropped into it" "0" "$(find "$SD/himmel-latest-release.fail" -mindepth 1 | wc -l | tr -d ' ')"

echo "Test 21: the lookup runs curl with -q FIRST so a ~/.curlrc cannot add URLs or outputs"
SD="$TMP/s21"; mkdir -p "$SD"; CURLLOG="$TMP/curl21.log"; : > "$CURLLOG"
env PATH="$STUBBIN:$PATH" STUB_CURL_LOG="$CURLLOG" STUB_CURL_TAG=v0.6.0 bash "$LIBS_SRC/release-check.sh" --refresh "$SD/himmel-latest-release" 2>/dev/null || true
assert_eq_hook "curl's first argument is -q" "-q" "$(head -n 1 "$CURLLOG" | cut -d' ' -f1)"

echo "Test 22: a tag whose numbers overflow the integer compare is invalid — a failed check, never 'up to date'"
# `[ -lt ]` errors past the integer range, so release_is_older would answer "not
# older" for a huge tag and the check would call an out-of-date install current.
if ( . "$LIBS_SRC/release-check.sh"; release_tag_parts v99999999999999999999.0.0 >/dev/null 2>&1 ); then
    assert_fail "an over-long version number was accepted as a release tag"
else
    assert_pass "an over-long version number is not a release tag"
fi
SD="$TMP/s22"; mkdir -p "$SD"
env PATH="$STUBBIN:$PATH" STUB_CURL_TAG=v99999999999999999999.0.0 bash "$LIBS_SRC/release-check.sh" --refresh "$SD/himmel-latest-release" 2>/dev/null || true
if [ ! -s "$SD/himmel-latest-release" ]; then assert_pass "an overflowing tag from the API is not cached as an answer"; else assert_fail "overflowing tag was cached: $(cat "$SD/himmel-latest-release")"; fi
assert_eq_hook "…it is recorded as a bad response (a failed check)" "bad-response" "$(cat "$SD/himmel-latest-release.fail" 2>/dev/null || true)"

echo "Test 23: the tag is the release's OWN top-level tag_name, not the first/last one that LOOKS like it (HIMMEL-3258)"
# refresh_case <curl-mode> [PATH] — one --refresh against a fresh state dir; sets
# GOT (cached answer or "") and GOTFAIL (.fail reason or "").
_t23=0
refresh_case() {
    _t23=$((_t23 + 1)); local sd="$TMP/s23_$_t23"; mkdir -p "$sd"
    env PATH="${2:-$STUBBIN:$PATH}" STUB_CURL_MODE="$1" STUB_CURL_TAG=v0.4.0 \
        "$BASHBIN" "$LIBS_SRC/release-check.sh" --refresh "$sd/himmel-latest-release" 2>/dev/null || true
    GOT=$(cat "$sd/himmel-latest-release" 2>/dev/null || true)
    GOTFAIL=$(cat "$sd/himmel-latest-release.fail" 2>/dev/null || true)
}
BASHBIN="$(command -v bash)"
# jq-less PATH: only the tools the lib needs, and NOT jq (a fresh packaged install).
NOJQ="$TMP/nojqbin"; mkdir -p "$NOJQ"; cp "$STUBBIN/curl" "$NOJQ/curl"
for _c in bash sed head mkdir dirname mktemp mv rm cat; do ln -s "$(command -v "$_c")" "$NOJQ/$_c"; done
if command -v jq >/dev/null 2>&1; then
    refresh_case ok
    assert_eq_hook "control: a plain reply still yields its tag" "v0.4.0" "$GOT"
    refresh_case bodydecoy
    assert_eq_hook "control: a quoted tag in the release NOTES (escaped on the wire) does not replace the real one" "v0.4.0" "$GOT"
    refresh_case nested
    assert_eq_hook "a nested object carrying its own tag_name, AFTER the real one, is not the release tag" "v0.4.0" "$GOT"
    refresh_case nestedfirst
    assert_eq_hook "…nor when it comes BEFORE the real one (pretty-printed)" "v0.4.0" "$GOT"
    refresh_case nulltag
    assert_eq_hook "a null tag_name is not a tag: nothing cached" "" "$GOT"
    assert_eq_hook "…recorded as bad-response" "bad-response" "$GOTFAIL"
    refresh_case nulltagnested
    assert_eq_hook "a null top-level tag_name does not fall through to a later nested one: nothing cached" "" "$GOT"
    assert_eq_hook "…recorded as bad-response" "bad-response" "$GOTFAIL"
else
    echo "  SKIP: jq absent on this runner — the structural-parse cases need it"
fi
refresh_case notjson
assert_eq_hook "a non-JSON 200 reply is not a tag: nothing cached" "" "$GOT"
assert_eq_hook "…recorded as bad-response (the existing vocabulary, no new reason)" "bad-response" "$GOTFAIL"
refresh_case ok "$NOJQ"
assert_eq_hook "no jq: a plain reply still yields its tag (degrades, never fails closed)" "v0.4.0" "$GOT"
refresh_case bodydecoy "$NOJQ"
assert_eq_hook "no jq: a notes-quoted tag still does not replace the real one" "v0.4.0" "$GOT"
refresh_case notjson "$NOJQ"
assert_eq_hook "no jq: a non-JSON reply is still bad-response" "bad-response" "$GOTFAIL"

echo "Test 24: the state survives a reboot — it lives under the user's home, not /tmp (HIMMEL-3260)"
# The "could not check" line measures from the FIRST attempt when no check ever
# succeeded. That timestamp defaulted to /tmp/claude, which a reboot clears, so a
# machine that reboots more often than the stale window and stays offline never
# reached the threshold and stayed SILENT — the state the first-attempt timestamp exists to end.
# These cases do NOT pass UPDATE_CHECK_STATE_DIR: the DEFAULT location is the
# thing under test. HOME is a throwaway; HIMMELCTL_CACHE_DIR is unset (the same
# override himmelctl and uninstall.sh read, so the three agree on one dir).
# run_home <home> [ENV=val ...] — the hook against $PHOOK, default state dir.
run_home() {
    local h="$1"; shift
    env -u CLAUDE_PROJECT_DIR -u UPDATE_CHECK_STATE_DIR -u HIMMELCTL_CACHE_DIR \
        HOME="$h" PATH="$STUBBIN:$PATH" "$@" bash "$PHOOK" 2>/dev/null || true
}
# No case here touches the real /tmp/claude: it is a shared, per-machine directory a
# concurrent session (one still on the old hook) may be using, and a snapshot/restore
# of it would still race that session. A reboot clears /tmp and nothing under $HOME, so
# with the state under $HOME the faithful "reboot" is to leave it alone between runs;
# 24c proves the hook no longer references the legacy path without planting a file there.
# A synchronous refresh (as Test 18) keeps the reading deterministic: no waiting
# on a detached job before the next run.
sync_prefix() { make_nongit_prefix "0.3.0"; printf 'detach_run() { "$@" || true; }\n' > "$PFX/scripts/lib/detach.sh"; }

# 24a. offline across reboots: still says so once the window is exceeded.
sync_prefix
H="$TMP/home24a"; S="$H/.claude/himmel"; mkdir -p "$H"
out=$(run_home "$H" STUB_CURL_MODE=netfail UPDATE_CHECK_INTERVAL=0)
assert_empty "24a: first offline run is inside the window — silent" "$out"
if [ -f "$S/himmel-update-check-first" ]; then assert_pass "24a: the first-attempt stamp is under \$HOME/.claude/himmel"; else assert_fail "24a: no first-attempt stamp under \$HOME/.claude/himmel"; fi
mkdir -p "$S"; touch -t 200001010000 "$S/himmel-update-check-first"   # ...and a week+ of offline days go by
out=$(run_home "$H" STUB_CURL_MODE=netfail UPDATE_CHECK_INTERVAL=0)
assert_contains "24a: a later run, still offline past the window (the state is under $HOME, so a reboot cannot clear it) → 'could not check'" "could not check for updates" "$out"
assert_contains "24a: …with the reason of the failed refresh" "last error: network" "$out"

# 24b. positive control: a healthy online install stays QUIET —
# the fix must not make the warning appear more often.
sync_prefix
H="$TMP/home24b"; S="$H/.claude/himmel"; mkdir -p "$H"
out=$(run_home "$H" STUB_CURL_TAG=v0.3.0 UPDATE_CHECK_INTERVAL=0)
assert_empty "24b: online, up to date — silent" "$out"
assert_eq_hook "24b: the definite answer is cached under \$HOME/.claude/himmel" "v0.3.0" "$(cat "$S/himmel-latest-release" 2>/dev/null || true)"
out=$(run_home "$H" STUB_CURL_MODE=netfail UPDATE_CHECK_INTERVAL=0)
assert_empty "24b: a later failing refresh — still silent (the last answer is fresh)" "$out"

# 24c. migration: a leftover /tmp/claude stamp from before this change is IGNORED
# (never read, never deleted) — the window simply starts fresh under the new dir.
# Asserted on the hook's CODE, not by planting a stale file in the shared /tmp/claude:
# a hook with no non-comment reference to that path can neither read nor delete it.
legacy_refs=$(grep -v '^[[:space:]]*#' "$HOOK" | grep -c '/tmp/claude' || true)
assert_eq_hook "24c: the hook's code no longer references the legacy /tmp/claude state (never read, never deleted)" "0" "$legacy_refs"

# 24d. the override every other himmel surface reads picks the directory, and the
# older UPDATE_CHECK_STATE_DIR seam still wins over it.
sync_prefix
H="$TMP/home24d"; mkdir -p "$H"; CC="$TMP/cc24d"; SEAM="$TMP/seam24d"
run_home "$H" HIMMELCTL_CACHE_DIR="$CC" STUB_CURL_MODE=netfail UPDATE_CHECK_INTERVAL=0 >/dev/null
if [ -f "$CC/himmel-update-check-first" ] && [ ! -e "$H/.claude/himmel" ]; then assert_pass "24d: HIMMELCTL_CACHE_DIR chooses the state dir"; else assert_fail "24d: HIMMELCTL_CACHE_DIR was not honoured"; fi
run_home "$H" HIMMELCTL_CACHE_DIR="$CC" UPDATE_CHECK_STATE_DIR="$SEAM" STUB_CURL_MODE=netfail UPDATE_CHECK_INTERVAL=0 >/dev/null
if [ -f "$SEAM/himmel-update-check-first" ]; then assert_pass "24d: UPDATE_CHECK_STATE_DIR still overrides it (test seam)"; else assert_fail "24d: UPDATE_CHECK_STATE_DIR seam no longer wins"; fi

# 24e. the git path's throttle stamp moves with it — ONE location, not two.
make_repo_behind 0
H="$TMP/home24e"; mkdir -p "$H"
env -u UPDATE_CHECK_STATE_DIR -u HIMMELCTL_CACHE_DIR HOME="$H" CLAUDE_PROJECT_DIR="$CHECKOUT_DIR" bash "$HOOK" >/dev/null 2>&1 || true
if [ -f "$H/.claude/himmel/himmel-update-check-last" ]; then assert_pass "24e: git path: the throttle stamp is under \$HOME/.claude/himmel"; else assert_fail "24e: git path: no throttle stamp under \$HOME/.claude/himmel"; fi

echo "Test 25: release channel"
PRIV_FETCH='+refs/tags/v*:refs/himmel-update/tags/v*'
# chan_repo <n> — a clone at the init commit, origin ahead by n commits; sets
# BARE, the bare upstream, and CLONE_REVS, the origin/main history oldest-first.
chan_repo() {
    make_repo_behind "$1"
    BARE="$(dirname "$CHECKOUT_DIR")/upstream.git"
    CLONE_REVS=$(git -C "$CHECKOUT_DIR" rev-list --reverse '@{u}')
}
rev_at() { printf '%s\n' "$CLONE_REVS" | sed -n "${1}p"; }
# tag_origin <tag> <n> [annotated] — tag the n-th commit (1 = init) on origin.
tag_origin() {
    if [ "${3:-}" = "annotated" ]; then
        git -C "$BARE" -c user.name=T -c user.email=t@t.t tag -a "$1" -m "$1" "$(rev_at "$2")"
    else
        git -C "$BARE" tag "$1" "$(rev_at "$2")"
    fi
}
sync_private() { git -C "$CHECKOUT_DIR" fetch --quiet origin "$PRIV_FETCH" 2>/dev/null || true; }
# profile <dir> <json> — an install profile under a fresh HIMMELCTL_CACHE_DIR.
profile() { mkdir -p "$1"; printf '%s\n' "$2" > "$1/install-profile.json"; }
run_chan() {   # run_chan <state-dir> <cache-dir> [ENV=val ...]
    local sd="$1" cd_="$2"; shift 2
    mkdir -p "$sd"
    env UPDATE_CHECK_STATE_DIR="$sd" HIMMELCTL_CACHE_DIR="$cd_" CLAUDE_PROJECT_DIR="$CHECKOUT_DIR" "$@" \
        bash "$HOOK" 2>/dev/null || true
}
assert_not_contains() {
    local desc="$1" pattern="$2" actual="$3"
    if grepq "$actual" "$pattern"; then assert_fail "$desc — pattern '$pattern' present in: $actual"; else assert_pass "$desc"; fi
}

# 25a. channel pre, HEAD ahead of the newest pre tag and behind origin/main: silent.
chan_repo 2
tag_origin v0.1.0-pre.1 1
git -C "$CHECKOUT_DIR" merge --quiet --ff-only "$(rev_at 2)"
sync_private
profile "$TMP/c25a" '{"channel":"pre"}'
out=$(run_chan "$TMP/s25a" "$TMP/c25a")
assert_empty "25a: pre channel, HEAD ahead of the newest tag and behind origin/main — silent" "$out"

# 25b. HEAD detached at an old tag, a newer tag exists (annotated): nudge naming it.
chan_repo 2
tag_origin v0.1.0-pre.1 1
tag_origin v0.2.0-pre.1 3 annotated
git -C "$CHECKOUT_DIR" switch --quiet --detach "$(rev_at 1)"
sync_private
profile "$TMP/c25b" '{"channel":"pre"}'
out=$(run_chan "$TMP/s25b" "$TMP/c25b")
assert_contains "25b: detached behind the newest pre tag — nudge names the tag" "v0\.2\.0-pre\.1" "$out"
assert_contains "25b: …names the channel" "pre release" "$out"
assert_contains "25b: …points at /himmel-update" "/himmel-update" "$out"
assert_not_contains "25b: …never the branch-count wording" "commit(s) behind" "$out"

# 25c. diverged from the newest tag: silent.
chan_repo 2
tag_origin v0.2.0-pre.1 3
git -C "$CHECKOUT_DIR" commit --quiet --allow-empty -m "local work"
sync_private
profile "$TMP/c25c" '{"channel":"pre"}'
out=$(run_chan "$TMP/s25c" "$TMP/c25c")
assert_empty "25c: diverged from the newest tag — silent" "$out"

# 25d. HEAD at the newest tag: silent.
chan_repo 2
tag_origin v0.2.0-pre.1 2
git -C "$CHECKOUT_DIR" merge --quiet --ff-only "$(rev_at 2)"
sync_private
profile "$TMP/c25d" '{"channel":"pre"}'
out=$(run_chan "$TMP/s25d" "$TMP/c25d")
assert_empty "25d: HEAD at the newest tag — silent" "$out"

# 25e. stable ignores a newer pre tag and names the newest stable one.
chan_repo 2
tag_origin v0.1.0 2
tag_origin v0.2.0-pre.1 3
sync_private
profile "$TMP/c25e" '{"channel":"stable"}'
out=$(run_chan "$TMP/s25e" "$TMP/c25e")
assert_contains "25e: stable channel names the newest stable tag" "v0\.1\.0" "$out"
assert_not_contains "25e: …and never a pre tag" "pre\.1" "$out"

# 25f. a pre tag vs a stable of the same version: the stable one wins (shared ranking).
chan_repo 2
tag_origin v0.3.0-pre.2 2
tag_origin v0.3.0 3
sync_private
profile "$TMP/c25f" '{"channel":"pre"}'
out=$(run_chan "$TMP/s25f" "$TMP/c25f")
assert_contains "25f: a stable release outranks a pre of the same version" "v0\.3\.0[^-]" "$out"

# 25g. HIMMEL_UPDATE_CHANNEL in the environment selects the channel, no profile.
chan_repo 2
tag_origin v0.2.0-pre.1 3
sync_private
out=$(run_chan "$TMP/s25g" "$TMP/no-profile" HIMMEL_UPDATE_CHANNEL=pre)
assert_contains "25g: env channel: nudge names the tag" "v0\.2\.0-pre\.1" "$out"

# 25h. NEGATIVE CONTROL: no channel keeps today's branch nudge.
chan_repo 2
tag_origin v0.2.0-pre.1 3
sync_private
out=$(run_chan "$TMP/s25h" "$TMP/no-profile")
assert_contains "25h: no channel: today's branch-count nudge" "2 commit(s) behind" "$out"
profile "$TMP/c25h" '{"other":"x"}'
out=$(run_chan "$TMP/s25h2" "$TMP/c25h")
assert_contains "25h: a profile without a channel key: today's branch-count nudge" "2 commit(s) behind" "$out"

# 25i. unreadable channel: a distinct warning, never the pull nudge.
chan_repo 2
tag_origin v0.2.0-pre.1 3
sync_private
profile "$TMP/c25i" '{ not json'
out=$(run_chan "$TMP/s25i" "$TMP/c25i")
assert_contains "25i: malformed profile: says the channel is unreadable" "update channel is unreadable" "$out"
assert_contains "25i: …and that /himmel-update will refuse" "will refuse" "$out"
assert_not_contains "25i: …never the pull nudge" "commit(s) behind" "$out"
profile "$TMP/c25i2" '{"channel":"nightly"}'
out=$(run_chan "$TMP/s25i2" "$TMP/c25i2")
assert_contains "25i: an invalid channel value is unreadable too" "update channel is unreadable" "$out"
out=$(run_chan "$TMP/s25i3" "$TMP/no-profile" 'HIMMEL_UPDATE_CHANNEL=<bogus>')
assert_contains "25i: an invalid HIMMEL_UPDATE_CHANNEL is unreadable too" "update channel is unreadable" "$out"
assert_not_contains "25i: …the reason does not smuggle markup into the context" "<bogus" "$out"

# 25j. jq missing while a profile exists: the same warning.
NOJQ="$TMP/nojq-bin"; mkdir -p "$NOJQ"
for t in bash git date stat touch mkdir cat tr sed grep head dirname basename rm cut sort env setsid uname readlink printf; do
    src=$(command -v "$t" 2>/dev/null) || continue
    ln -sf "$src" "$NOJQ/$t"
done
profile "$TMP/c25j" '{"channel":"pre"}'
out=$(run_chan "$TMP/s25j" "$TMP/c25j" PATH="$NOJQ")
assert_contains "25j: jq missing with a profile: unreadable warning" "update channel is unreadable" "$out"
assert_contains "25j: …says why" "jq" "$out"
assert_not_contains "25j: …never the pull nudge" "commit(s) behind" "$out"

# 25k. private namespace: a stray local tag, never fetched into it, is not a release.
chan_repo 2
git -C "$CHECKOUT_DIR" tag v9.9.9 "$(rev_at 3)"
profile "$TMP/c25k" '{"channel":"pre"}'
out=$(run_chan "$TMP/s25k" "$TMP/c25k")
assert_empty "25k: a stray local tag with no private ref is not a release" "$out"

# 25l. cold private refs: silent now; the detached fetch fills them for the next check.
chan_repo 2
tag_origin v0.2.0-pre.1 3
profile "$TMP/c25l" '{"channel":"pre"}'
out=$(run_chan "$TMP/s25l" "$TMP/c25l")
assert_empty "25l: cold private refs — silent this run" "$out"
i=0
while [ "$i" -lt 20 ]; do
    [ -n "$(git -C "$CHECKOUT_DIR" for-each-ref refs/himmel-update/tags 2>/dev/null)" ] && break
    sleep 1; i=$((i + 1))
done
assert_eq_hook "25l: the detached fetch filled the private namespace" "refs/himmel-update/tags/v0.2.0-pre.1" \
    "$(git -C "$CHECKOUT_DIR" for-each-ref --format='%(refname)' refs/himmel-update/tags 2>/dev/null)"
out=$(run_chan "$TMP/s25l" "$TMP/c25l" UPDATE_CHECK_INTERVAL=0)
assert_contains "25l: the next check nudges off them" "v0\.2\.0-pre\.1" "$out"

# 25m. a station with no channel never fetches tags into the private namespace.
chan_repo 2
tag_origin v0.2.0-pre.1 3
out=$(run_chan "$TMP/s25m" "$TMP/no-profile")
i=0
while [ "$i" -lt 20 ]; do
    [ "$(git -C "$CHECKOUT_DIR" rev-list --count 'HEAD..@{u}' 2>/dev/null || echo 0)" != "0" ] && break
    sleep 1; i=$((i + 1))
done
sleep 1
assert_empty "25m: no channel: the private namespace stays empty" "$(git -C "$CHECKOUT_DIR" for-each-ref refs/himmel-update/tags 2>/dev/null)"

# 25n. fail open: the shared library missing falls back to today's nudge.
chan_repo 2
LIBLESS="$TMP/libless"; mkdir -p "$LIBLESS/scripts/hooks" "$LIBLESS/scripts/lib" "$LIBLESS/.git"
cp "$HOOK" "$LIBLESS/scripts/hooks/"; cp "$LIBS_SRC/detach.sh" "$LIBLESS/scripts/lib/"
profile "$TMP/c25n" '{"channel":"pre"}'
out=$(env UPDATE_CHECK_STATE_DIR="$TMP/s25n" HIMMELCTL_CACHE_DIR="$TMP/c25n" CLAUDE_PROJECT_DIR="$CHECKOUT_DIR" bash "$LIBLESS/scripts/hooks/check-update-available.sh" 2>/dev/null) || true
assert_contains "25n: shared library missing: fails open to the branch nudge" "2 commit(s) behind" "$out"

# ─── Summary ─────────────────────────────────────────────────────────────────
echo
echo "RESULTS: $pass passed, $fail failed"
[ "$fail" -eq 0 ] || exit 1
exit 0
