#!/usr/bin/env bash
# Platform guard: POSIX bash 3.2+; git and python3.
# A new executable default must be refused, even in a file with kept detectors.
# Fixture expressions are literal source, not substitutions in this test shell.
# shellcheck disable=SC2016
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
GATE="$HERE/check-platform-dropped.sh"
T=$(mktemp -d "${TMPDIR:-/tmp}/platform-dropped.XXXXXX") || exit 1
trap 'rm -rf "$T"' EXIT

# Run the real fixture suite under hostile, throwaway caller settings.
if [ "${1:-}" != --fixture-child ]; then
    mkdir -p "$T/foreign-worktree"
    printf '[commit]\n\tgpgSign = true\n[gpg]\n\tprogram = /nonexistent-fixture-signer\n' > "$T/global"
    GIT_DIR="$T/foreign.git" GIT_WORK_TREE="$T/foreign-worktree" GIT_INDEX_FILE="$T/foreign-index" \
        GIT_CONFIG_GLOBAL="$T/global" bash "$0" --fixture-child
    exit $?
fi

# The fixture git processes must never target the caller's repository or config.
# shellcheck source=scripts/lib/git-clean.sh
. "$HERE/../lib/git-clean.sh"
git_env_scrub
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null

pass=0; fail=0
ok() { pass=$((pass + 1)); printf 'ok - %s\n' "$*"; }
bad() { fail=$((fail + 1)); printf 'not ok - %s\n' "$*"; }

if [ ! -f "$GATE" ]; then
    bad 'new .exe default is not checked: lint does not exist yet (RED)'
    exit 1
fi

mkdiff() {
    local path="$1"; shift
    {
        printf 'diff --git a/%s b/%s\n--- a/%s\n+++ b/%s\n@@ -0,0 +1,%s @@\n' "$path" "$path" "$path" "$path" "$#"
        printf '+%s\n' "$@"
    } > "$T/input.diff"
}
run() { OUT=$(bash "$GATE" --diff "$T/input.diff" 2>&1); RC=$?; }
expect() {
    local want="$1" label="$2"
    if [ "$RC" -eq "$want" ]; then ok "$label"; else bad "$label: rc=$RC $OUT"; fi
}

mkdiff scripts/new-default.sh 'WHISPER_CLI="${WHISPER_DIR}/whisper-cli.exe"'
run
expect 1 'new .exe default refused'
case "$OUT" in *scripts/new-default.sh:1:*) ok 'diagnostic names file:line' ;; *) bad "missing location: $OUT" ;; esac
mkdiff scripts/new-default.sh 'WHISPER_CLI="${WHISPER_DIR}/whisper-cli"'
run
expect 0 'same diff with POSIX default passes'
mkdiff scripts/new-command.ps1 'Get-Content input.txt'
run
expect 1 'new dropped-platform filename refused without a keyword in its content'
for text in \
    'case "$host" in CYGWIN*) exit 0 ;; esac' \
    'MSYS_NO_PATHCONV=1 run' \
    "if (process.platform === 'win32') run();" \
    'pwsh'' -Command run' \
    'case "$host" in CYGWIN_NT-*) exit 0 ;; esac' \
    'MSYS2_ARG_CONV_EXCL=* run'; do
    mkdiff scripts/new-code.sh "$text"
    run
    expect 1 "dropped shape refused: $text"
done

# This exact audited detector remains allowed, but never its entire file.
mkdiff marketplace/plugins/himmel-ops/hooks/hooks.json '        "matcher": "Bash|PowerShell",'
run
expect 0 'audited detector passes'
mkdiff marketplace/plugins/himmel-ops/hooks/hooks.json 'WHISPER_CLI="${WHISPER_DIR}/whisper-cli.exe"'
run
expect 1 'default in an allowlisted file is still refused'

for path in scripts/bitbucket/package-lock.json scripts/pnpm.lock marketplace/plugins/himmel-ops/package-lock.json marketplace/plugins/himmel-ops/yarn.lock; do
    mkdiff "$path" '"binding-win32-x64-msvc": "9.9.9"'
    run
    expect 0 "generated lockfile platform metadata ignored: $path"
done

for path in scripts/readme.md scripts/test-probe.sh scripts/tests/probe.js scripts/test/probe.js scripts/__tests__/probe.js scripts/fixtures/probe.sh scripts/node_modules/probe.js scripts/probe.test.ts marketplace/plugins/claude-hud/probe.js other/probe.sh; do
    mkdiff "$path" 'tool.exe'
    run
    expect 0 "out-of-scope $path"
done

# Context and removals must not make a cleanup PR red.
printf '%s\n' 'diff --git a/scripts/a.sh b/scripts/a.sh' '--- a/scripts/a.sh' '+++ b/scripts/a.sh' '@@ -1,2 +1,2 @@' ' old.exe' '-remove.exe' '+echo clean' > "$T/input.diff"
run
expect 0 'unchanged and removed leftovers ignored'
mkdiff scripts/a.sh 'echo "five usage Windows"' 'echo "a runtime Windows branch"'
run
expect 1 'shared lookbehind keeps the runtime Windows match'
case "$OUT" in *scripts/a.sh:1:*) bad 'shared lookbehind flagged usage Windows' ;; *) ok 'shared lookbehind ignores usage Windows' ;; esac

# Non-platform dispatch titles must retain the shared pattern's existing exclusions.
for title in 'Refresh usage windows' 'Fix runtime Linux branch' 'Fix util.execute()' 'Keep context Windows' 'Keep time Windows' 'Keep token Windows' 'Keep rate Windows' 'Keep sliding Windows' 'Keep usage Windows' 'Refresh Windowed UI' 'Update Linux and macOS support'; do
    mkdiff scripts/title.sh "$title"
    run
    expect 0 "non-platform title unchanged: $title"
done

# Real commits prove --range, attributes and unusual filenames cannot hide hits.
R="$T/repo"
mkdir -p "$R/scripts/tests"
printf 'legacy.exe\n' > "$R/scripts/tests/legacy.sh"
git -C "$R" init -q
git -C "$R" config user.name fixture
git -C "$R" config user.email fixture@example.invalid
printf 'old.exe\necho clean\n' > "$R/scripts/a.sh"
git -C "$R" add .
git -C "$R" commit -qm base
base=$(git -C "$R" rev-parse HEAD)
printf 'old.exe\necho changed\n' > "$R/scripts/a.sh"
git -C "$R" add .
git -C "$R" commit -qm clean
OUT=$(cd "$R" && bash "$GATE" --range "$base" 2>&1); RC=$?
expect 0 'range ignores existing default'
printf 'new.exe\n' > "$R/scripts/space name.sh"
printf 'scripts/* -diff\n' > "$R/.gitattributes"
git -C "$R" add .
git -C "$R" commit -qm addition
OUT=$(cd "$R" && bash "$GATE" --range "$base" 2>&1); RC=$?
expect 1 'range checks additions despite -diff attribute'
case "$OUT" in *'scripts/space name.sh:1:'*) ok 'range handles spaced path' ;; *) bad "spaced path diagnostic: $OUT" ;; esac
rename_base=$(git -C "$R" rev-parse HEAD)
mv "$R/scripts/tests/legacy.sh" "$R/scripts/renamed.sh"
git -C "$R" add .
git -C "$R" commit -qm rename
OUT=$(cd "$R" && bash "$GATE" --range "$rename_base" 2>&1); RC=$?
expect 1 'rename from excluded tests into production is checked'
case "$OUT" in *scripts/renamed.sh:1:*) ok 'rename names newly in-scope default' ;; *) bad "rename diagnostic: $OUT" ;; esac
OUT=$(cd "$R" && bash "$GATE" --range does-not-exist 2>&1); RC=$?
expect 2 'unreadable range fails closed'
printf 'not a diff\n' > "$T/input.diff"
run
expect 2 'malformed diff fails closed'
: > "$T/input.diff"
run
expect 0 'empty diff passes'

# Missing or invalid policy must never silently disable the gate.
P="$T/policy"
mkdir -p "$P/scripts/lint" "$P/scripts/handover/chief-kit"
cp "$GATE" "$HERE/platform-dropped-allow.json" "$P/scripts/lint/"
cp "$HERE/../handover/chief-kit/platform-dropped.re" "$P/scripts/handover/chief-kit/"
printf '{broken\n' > "$P/scripts/lint/platform-dropped-allow.json"
OUT=$(bash "$P/scripts/lint/check-platform-dropped.sh" --diff "$T/input.diff" 2>&1); RC=$?
expect 2 'invalid allowlist fails closed even with an empty diff'
cp "$HERE/platform-dropped-allow.json" "$P/scripts/lint/"
: > "$P/scripts/handover/chief-kit/platform-dropped.re"
OUT=$(bash "$P/scripts/lint/check-platform-dropped.sh" --diff "$T/input.diff" 2>&1); RC=$?
expect 2 'empty shared pattern fails closed'
printf '[\n' > "$P/scripts/handover/chief-kit/platform-dropped.re"
OUT=$(bash "$P/scripts/lint/check-platform-dropped.sh" --diff "$T/input.diff" 2>&1); RC=$?
expect 2 'invalid shared pattern fails closed'

# Execute the real CI step, including bootstrap and trusted-base policy loading.
awk '
    /^  [a-z][a-z0-9-]*:/ { injob = ($1 == "lint:") }
    injob && /^      - name: platform-dropped lint/ { instep = 1; next }
    instep && /^        run: \|/ { inrun = 1; next }
    inrun && /^          / { sub(/^          /, ""); print; next }
    inrun { exit }
' "$HERE/../../.github/workflows/ci.yml" > "$T/step.sh"
S="$T/ci"
mkdir -p "$S/scripts/lint" "$S/scripts/handover/chief-kit" "$T/runner"
git -C "$S" init -q
git -C "$S" config user.name fixture
git -C "$S" config user.email fixture@example.invalid
printf 'echo clean\n' > "$S/scripts/a.sh"
cp "$HERE/../handover/chief-kit/platform-dropped.re" "$S/scripts/handover/chief-kit/"
git -C "$S" add .
git -C "$S" commit -qm base
bootstrap_base=$(git -C "$S" rev-parse HEAD)
cp "$GATE" "$HERE/platform-dropped-allow.json" "$S/scripts/lint/"
cp "$HERE/../handover/chief-kit/platform-dropped.re" "$S/scripts/handover/chief-kit/"
git -C "$S" add .
git -C "$S" commit -qm policy
ci_base=$(git -C "$S" rev-parse HEAD)
OUT=$(cd "$S" && BASE_SHA="$bootstrap_base" GITHUB_WORKSPACE="$S" RUNNER_TEMP="$T/runner" bash -e "$T/step.sh" 2>&1); RC=$?
expect 0 'CI bootstrap checks its own clean diff'
printf 'new.exe\n' >> "$S/scripts/a.sh"
printf 'exit 0\n' > "$S/scripts/lint/check-platform-dropped.sh"
printf '{}\n' > "$S/scripts/lint/platform-dropped-allow.json"
printf 'never-match-this\n' > "$S/scripts/handover/chief-kit/platform-dropped.re"
git -C "$S" add .
git -C "$S" commit -qm tamper
OUT=$(cd "$S" && BASE_SHA="$ci_base" GITHUB_WORKSPACE="$S" RUNNER_TEMP="$T/runner" bash -e "$T/step.sh" 2>&1); RC=$?
expect 1 'CI uses base script, allowlist and pattern despite head tampering'
case "$OUT" in *scripts/a.sh:2:*) ok 'CI reports the new runtime default' ;; *) bad "CI default location: $OUT" ;; esac
OUT=$(cd "$S" && BASE_SHA='' GITHUB_WORKSPACE="$S" RUNNER_TEMP="$T/runner" bash -e "$T/step.sh" 2>&1); RC=$?
expect 2 'CI missing base fails closed'

printf '# pass=%s fail=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
