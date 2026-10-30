#!/usr/bin/env bash
# selector: tree-scan
# Smoke test for scripts/hooks/check-npm-licenses.sh.
#
# Scope: package discovery and scanner identity. Network-facing npm/npx calls
# are stubbed; the real gate runs against isolated repositories and a trusted
# scanner double, independently of each inspected tree. Discovery cases assert:
#   1. the NEW source `git ls-files '*package.json' :(exclude)*/node_modules/*`
#      finds ALL committed packages (incl. the 4 formerly-missed ones), and
#   2. the OLD `find scripts -maxdepth 3` pattern would have MISSED them
#      (regression guard), and
#   3. the node_modules exclude keeps tracked-but-nested deps out (defensive).
#
# Usage: bash scripts/hooks/test-check-npm-licenses.sh
set -uo pipefail

# grepq <text> [grep-args...] — a `grep -q` test against <text> with NO
# pipeline. printf/echo-into-`grep -q` is a trap under this file's
# `set -o pipefail`: grep -q exits the instant it matches, the producer
# then takes SIGPIPE writing the remainder, and pipefail reports the
# PIPELINE as failed — so a SUCCESSFUL match returns non-zero whenever
# the match lands early in a large input. A here-string is not a pipeline,
# so the status is grep's own verdict alone.
grepq() { local _t="$1"; shift; grep -q "$@" <<< "$_t"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$SCRIPT_DIR/check-npm-licenses.sh"
# shellcheck source=../lib/fixture-tempdir.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/../lib/fixture-tempdir.sh"

FAILED=0

assert_eq() {
    local label="$1" expected="$2" actual="$3"
    if [ "$actual" = "$expected" ]; then
        echo "PASS $label"
    else
        echo "FAIL $label"
        echo "     expected: $expected"
        echo "     actual:   $actual"
        FAILED=$((FAILED + 1))
    fi
}

# Build a temp git repo whose tracked package.json layout mirrors himmel's:
# 2 under scripts/ + 4 elsewhere, plus an UNTRACKED node_modules package.json
# and a TRACKED-but-nested node_modules package.json (defensive-exclude case).
make_repo() {
    local dir
    dir=$(fixture_mktemp_dir) || return 1
    (
        fixture_enter_git_init_dir "$dir" || exit 1
        git init -q -b main
        git config user.email t@t
        git config user.name t
        local pkgs=(
            scripts/himmel-run/package.json
            scripts/jira/package.json
            marketplace/plugins/obsidian-triage/tools/package.json
            marketplace/plugins/telegram-himmel/package.json
            plugins/himmel-gh/package.json
            plugins/himmel-jira/package.json
        )
        local p
        for p in "${pkgs[@]}"; do
            mkdir -p "$(dirname "$p")"
            echo '{"name":"x","license":"MIT"}' > "$p"
        done
        git add -A
        git -c commit.gpgsign=false commit -q -m "init packages"
        # Untracked node_modules package.json — git ls-files must ignore it.
        mkdir -p scripts/jira/node_modules/dep
        echo '{"name":"dep"}' > scripts/jira/node_modules/dep/package.json
        # Tracked-but-nested node_modules package.json — the defensive
        # :(exclude)*/node_modules/* pathspec must keep it out.
        mkdir -p vendor/node_modules/forced
        echo '{"name":"forced"}' > vendor/node_modules/forced/package.json
        git add -f vendor/node_modules/forced/package.json
        git -c commit.gpgsign=false commit -q -m "add nested node_modules pkg"
    ) || { rm -rf "$dir"; return 1; }
    echo "$dir"
}

REPO=$(make_repo) || exit 1
trap 'rm -rf "$REPO"' EXIT

EXPECTED_ALL=$(printf '%s\n' \
    marketplace/plugins/obsidian-triage/tools/package.json \
    marketplace/plugins/telegram-himmel/package.json \
    plugins/himmel-gh/package.json \
    plugins/himmel-jira/package.json \
    scripts/himmel-run/package.json \
    scripts/jira/package.json | sort)

# Case 1: NEW enumeration (the `git ls-files` enumeration line in
# check-npm-licenses.sh) finds all 6 committed packages and excludes both
# node_modules entries.
new_out=$( cd "$REPO" && git ls-files '*package.json' ':(exclude)*/node_modules/*' ':(exclude)scripts/lanes/bench/fixtures/*' | sort )
assert_eq "new git-ls-files enumeration finds all 6 committed packages" "$EXPECTED_ALL" "$new_out"

# Case 2: the 4 formerly-missed packages ARE in the new output (explicit).
missed=$(printf '%s\n' \
    marketplace/plugins/obsidian-triage/tools/package.json \
    marketplace/plugins/telegram-himmel/package.json \
    plugins/himmel-gh/package.json \
    plugins/himmel-jira/package.json)
present=$( printf '%s\n' "$missed" | while IFS= read -r m; do
    grepq "$new_out" -xF "$m" && echo "$m"
done | sort )
assert_eq "all 4 formerly-missed packages are covered now" "$(printf '%s' "$missed" | sort)" "$present"

# Case 3: regression guard — the OLD `find scripts -maxdepth 3` pattern finds
# only the 2 scripts/ packages and MISSES the 4 others.
old_out=$( cd "$REPO" && find scripts -maxdepth 3 -name package.json -not -path '*/node_modules/*' | sort )
EXPECTED_OLD=$(printf '%s\n' scripts/himmel-run/package.json scripts/jira/package.json | sort)
assert_eq "old find-scripts pattern catches only the 2 scripts/ packages" "$EXPECTED_OLD" "$old_out"

# Case 4: node_modules exclusion holds — neither the untracked nor the
# force-tracked nested package.json appears in the new enumeration.
if grepq "$new_out" 'node_modules'; then
    echo "FAIL node_modules package.json excluded from enumeration"
    FAILED=$((FAILED + 1))
else
    echo "PASS node_modules package.json excluded from enumeration"
fi

# Case 5: a bun-managed package (bun.lock, no package-lock.json) is
# SKIPPED by the gate, so a repo whose only package is bun-managed passes (rc 0)
# instead of erroring "No packages found in this path". Runs the REAL script
# against a throwaway repo; the skip happens before any npm/npx call (no network).
BUN_REPO=$(fixture_mktemp_dir) || exit 1
(
    fixture_enter_git_init_dir "$BUN_REPO" || exit 1
    git init -q -b main
    git config user.email t@t
    git config user.name t
    mkdir -p scripts/luna-vitals
    echo '{"name":"luna-vitals","devDependencies":{"@types/bun":"latest"}}' > scripts/luna-vitals/package.json
    : > scripts/luna-vitals/bun.lock   # bun lockfile, no package-lock.json
    git add -A
    git -c commit.gpgsign=false commit -q -m "bun-only package"
) || exit 1
bun_out=$( cd "$BUN_REPO" && bash "$SCRIPT" 2>&1 ); bun_rc=$?
if [ "$bun_rc" -eq 0 ] && grepq "$bun_out" -i "bun-managed"; then
    echo "PASS bun-managed package skipped — gate passes (rc 0), no 'No packages found'"
else
    echo "FAIL bun-managed skip: rc=$bun_rc"
    echo "     out: $bun_out"
    FAILED=$((FAILED + 1))
fi
rm -rf "$BUN_REPO"

# Case 6: the allowlist admits PSF-2.0 (argparse 3.x relabels the same PSF text
# Python-2.0 -> PSF-2.0 in SPDX) and still rejects a copyleft license.
allowed=$(sed -n 's/^ALLOWED="\(.*\)"$/\1/p' "$SCRIPT")
if grepq ";$allowed;" -F ";PSF-2.0;"; then
    echo "PASS allowlist admits PSF-2.0"
else
    echo "FAIL allowlist admits PSF-2.0 (ALLOWED=$allowed)"
    FAILED=$((FAILED + 1))
fi
if grepq ";$allowed;" -F ";GPL-3.0;"; then
    echo "FAIL allowlist rejects GPL-3.0"
    FAILED=$((FAILED + 1))
else
    echo "PASS allowlist rejects GPL-3.0"
fi

# Case 7: the integrity-pinned claude-code CI tool lockfile is not license-checked
# (a proprietary binary that ships nowhere): a repo whose only package is
# .github/claude-cli has nothing to check, so the real script passes (rc 0).
CLI_REPO=$(fixture_mktemp_dir) || exit 1
(
    fixture_enter_git_init_dir "$CLI_REPO" || exit 1
    git init -q -b main
    git config user.email t@t
    git config user.name t
    mkdir -p .github/claude-cli
    echo '{"name":"claude-cli-ci","private":true}' > .github/claude-cli/package.json
    git add -A
    git -c commit.gpgsign=false commit -q -m "claude-cli only"
) || exit 1
cli_out=$( cd "$CLI_REPO" && bash "$SCRIPT" 2>&1 ); cli_rc=$?
if [ "$cli_rc" -eq 0 ] && grepq "$cli_out" "nothing to check"; then
    echo "PASS .github/claude-cli excluded from the license check"
else
    echo "FAIL .github/claude-cli excluded: rc=$cli_rc"
    echo "     out: $cli_out"
    FAILED=$((FAILED + 1))
fi
rm -rf "$CLI_REPO"

# Case 8: returning to inspected-tree npx resolution must run the harmless
# local sentinel and fail these checks. The npm double only supplies the
# independently installed scanner; it never performs a network operation.
SCAN_FIXTURE=$(fixture_mktemp_dir) || exit 1
trap 'rm -rf "$REPO" "$SCAN_FIXTURE"' EXIT
mkdir -p "$SCAN_FIXTURE/bin" "$SCAN_FIXTURE/repo"
SCAN_REPO="$SCAN_FIXTURE/repo"
SCAN_PKG="$SCAN_REPO/package with spaces"
(
    fixture_enter_git_init_dir "$SCAN_REPO" || exit 1
    mkdir -p "$SCAN_PKG"
    git init -q -b main
    git config user.email t@t
    git config user.name t
    echo '{"name":"inspected","license":"MIT"}' > "$SCAN_PKG/package.json"
    git add -A
    git -c commit.gpgsign=false commit -q -m "scanner identity fixture"
) || exit 1
cat > "$SCAN_FIXTURE/local-scanner" <<'STUB'
#!/usr/bin/env bash
: > "$SCAN_FIXTURE/local-ran"
exit 0
STUB
cat > "$SCAN_FIXTURE/trusted-scanner" <<'STUB'
#!/usr/bin/env bash
set -eu
start= production= private= allowed=
while [ "$#" -gt 0 ]; do
    case "$1" in
        --start) start="$2"; shift ;;
        --production) production=yes ;;
        --excludePrivatePackages) private=yes ;;
        --onlyAllow=*) allowed="${1#--onlyAllow=}" ;;
        *) exit 91 ;;
    esac
    shift
done
[ "$start" = "$SCAN_PKG" ] && [ "$production" = yes ] && [ "$private" = yes ] || exit 92
case "$PWD/" in "$SCAN_REPO/"*) exit 93 ;; esac
printf '%s\n' trusted >> "$SCAN_FIXTURE/scanner-log"
IFS= read -r license < "$start/node_modules/production-license"
case ";$allowed;" in *";$license;"*) exit 0 ;; *) exit 1 ;; esac
STUB
cat > "$SCAN_FIXTURE/bin/npm" <<'STUB'
#!/usr/bin/env bash
set -eu
printf '%s\n' "$PWD $*" >> "$SCAN_FIXTURE/npm-log"
case " $* " in *" --ignore-scripts "*) ;; *) exit 94 ;; esac
case " $* " in
    *" license-checker "*)
        case "$PWD/" in "$SCAN_REPO/"*) exit 95 ;; esac
        prefix=
        while [ "$#" -gt 0 ]; do
            if [ "$1" = --prefix ]; then prefix="$2"; shift; fi
            shift
        done
        [ -n "$prefix" ] || exit 96
        case "$prefix/" in "$SCAN_REPO/"*) exit 95 ;; esac
        printf '%s\n' "$prefix" > "$SCAN_FIXTURE/tool-dir"
        [ "${BOOTSTRAP_FAIL:-0}" = 0 ] || exit 1
        mkdir -p "$prefix/node_modules/.bin"
        cp "$SCAN_FIXTURE/trusted-scanner" "$prefix/node_modules/.bin/license-checker"
        ;;
    *)
        mkdir -p node_modules/.bin
        cp "$SCAN_FIXTURE/local-scanner" node_modules/.bin/license-checker
        echo MIT > node_modules/production-license
        ;;
esac
STUB
cat > "$SCAN_FIXTURE/bin/npx" <<'STUB'
#!/usr/bin/env bash
# Model npx's local-bin preference without ever downloading a package.
exec "$PWD/node_modules/.bin/license-checker" "$@"
STUB
chmod +x "$SCAN_FIXTURE/local-scanner" "$SCAN_FIXTURE/trusted-scanner" "$SCAN_FIXTURE/bin/npm" "$SCAN_FIXTURE/bin/npx"

for scan_case in existing-allowed existing-disallowed lock-install no-lock-install bootstrap-failure; do
    rm -rf "$SCAN_PKG/node_modules"
    rm -f "$SCAN_PKG/package-lock.json" "$SCAN_FIXTURE/local-ran" "$SCAN_FIXTURE/tool-dir"
    : > "$SCAN_FIXTURE/scanner-log"
    : > "$SCAN_FIXTURE/npm-log"
    bootstrap_fail=0
    expected_rc=0
    case "$scan_case" in
        lock-install) echo '{"lockfileVersion":3}' > "$SCAN_PKG/package-lock.json" ;;
        no-lock-install) ;;
        *)
            mkdir -p "$SCAN_PKG/node_modules/.bin"
            cp "$SCAN_FIXTURE/local-scanner" "$SCAN_PKG/node_modules/.bin/license-checker"
            echo MIT > "$SCAN_PKG/node_modules/production-license"
            ;;
    esac
    if [ "$scan_case" = existing-disallowed ]; then
        echo GPL-3.0 > "$SCAN_PKG/node_modules/production-license"
        expected_rc=1
    elif [ "$scan_case" = bootstrap-failure ]; then
        bootstrap_fail=1
        expected_rc=1
    fi
    scan_rc=0
    scan_out=$(cd "$SCAN_REPO" && env PATH="$SCAN_FIXTURE/bin:$PATH" SCAN_FIXTURE="$SCAN_FIXTURE" SCAN_REPO="$SCAN_REPO" SCAN_PKG="$SCAN_PKG" BOOTSTRAP_FAIL="$bootstrap_fail" bash "$SCRIPT" 2>&1) || scan_rc=$?
    assert_eq "$scan_case: gate verdict" "$expected_rc" "$scan_rc"
    local_ran=no
    [ ! -f "$SCAN_FIXTURE/local-ran" ] || local_ran=yes
    assert_eq "$scan_case: inspected scanner never launched" no "$local_ran"
    scanner_log=$(< "$SCAN_FIXTURE/scanner-log")
    expected_log=trusted
    [ "$scan_case" != bootstrap-failure ] || expected_log=
    assert_eq "$scan_case: trusted scanner with production/license arguments" "$expected_log" "$scanner_log"
    if [ -f "$SCAN_FIXTURE/tool-dir" ]; then
        IFS= read -r tool_dir < "$SCAN_FIXTURE/tool-dir"
        tool_remains=no
        [ ! -e "$tool_dir" ] || tool_remains=yes
        assert_eq "$scan_case: temporary scanner cleaned up" no "$tool_remains"
    fi
    npm_log=$(< "$SCAN_FIXTURE/npm-log")
    case "$scan_case" in
        lock-install) install_arg='ci --omit=dev --ignore-scripts' ;;
        no-lock-install) install_arg='install --omit=dev --ignore-scripts' ;;
        *) install_arg= ;;
    esac
    if [ -n "$install_arg" ]; then
        if grepq "$npm_log" -F "$SCAN_PKG $install_arg"; then
            echo "PASS $scan_case: production install suppresses lifecycle scripts"
        else
            echo "FAIL $scan_case: production install suppresses lifecycle scripts ($scan_out)"
            FAILED=$((FAILED + 1))
        fi
    fi
done

echo ""
if [ "$FAILED" -eq 0 ]; then
    echo "ALL PASS"
    exit 0
fi
echo "$FAILED case(s) FAILED"
exit 1
