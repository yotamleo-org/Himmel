#!/usr/bin/env bash
# test-rtk-hook-guard.sh — smoke test for scripts/hooks/rtk-hook-guard.sh.
#
# Uses a STUB rtk on PATH (deterministic — no dependency on an installed
# rtk or its version). The stub mirrors the observed rtk 0.40.0 hook
# contract: bare `find …` / `git …` / `ls …` / `sort …` commands are
# rewritten to `rtk <cmd>` with permissionDecision allow; compound shell
# commands (pipes etc.) get NO output. The stub parses + emits via jq
# (the old }}-anchored sed silently emitted nothing when a
# trailing field followed tool_input.command, false-passing the suite).
# The rejected-predicate set the guard screens for was verified against
# the real rtk 0.40.0:
#   rejected: -not -exec -o -a -delete ! \( \)
#   silently ignored (semantics change): -prune
#   accepted: -type -maxdepth -name -path -mtime
#
# Covers:
#   1.  Simple find → rtk rewrite forwarded verbatim.
#   2.  Compound finds (-not/-exec/-o/-delete/-prune/!/\() → suppressed
#       (empty output, exit 0) — the LUNA runbook scan among them.
#   3.  Non-find rewrites forwarded, even when the command contains
#       tokens like `-o` (sort -o) — the guard only screens `rtk find`.
#   4.  rtk emits nothing (compound shell command) → empty, exit 0.
#   5.  rtk missing from PATH → empty, exit 0 (fail-open).
#   6.  rtk crashes → empty, exit 0 (fail-open).
#   7.  Empty stdin → empty, exit 0.
#   8.  permissionDecisionReason containing "-not" must NOT suppress a
#       safe rewrite (guard scans only the command value).
#   9.  jq broken → grep+sed fallback still suppresses compound finds
#       and forwards simple ones (no-jq fail-open contract).
#   10. Payload with a trailing field after command → stub still parses,
#       rewrite forwarded (jq-stub regression for the old sed anchor).
#   11. Output-shape drift (command field renamed) → extraction-failure
#       contract: output containing `rtk find ` is SUPPRESSED (an
#       unscanned rewrite is never forwarded), non-find output is
#       forwarded verbatim.
#   12. No jq + drifted output whose FIRST "command" pair is the
#       ORIGINAL command → the anchored fallback still finds the
#       rtk-find rewrite and suppresses its compound predicate.
#   3e/3f/3g. A Windows payload cwd is backslash-separated,
#       so the slash-only `.claude/worktrees/` match above misses it and
#       forwards a git rewrite the worktree-isolation screen then refuses.
#       3e: a backslash worktree cwd drops the rewrite on BOTH extraction
#       forms — jq decodes JSON escapes to a single backslash; the no-jq
#       grep+sed fallback keeps the JSON-escaped double backslash verbatim.
#       3f: backslash lookalikes (no dot, wrong segment name, no worktree
#       segment at all) keep the rewrite. 3g: a mixed forward/backslash cwd
#       whose worktree segment itself uses backslashes still drops (see the
#       inline justification).

set -euo pipefail

# The native controls must not inherit the lane running this suite.
unset CLAUDE_CONFIG_DIR
unset HIMMEL_CONSOLE_LEG

# grepq <text> [grep-args...] — a `grep -q` test against <text> with NO
# pipeline. printf/echo-into-`grep -q` is a trap under this file's
# `set -o pipefail`: grep -q exits the instant it matches, the producer
# then takes SIGPIPE writing the remainder, and pipefail reports the
# PIPELINE as failed — so a SUCCESSFUL match returns non-zero whenever
# the match lands early in a large input. A here-string is not a pipeline,
# so the status is grep's own verdict alone.
grepq() { local _t="$1"; shift; grep -q "$@" <<< "$_t"; }

# The stub (and the guard's primary extraction path) needs jq.
if ! command -v jq >/dev/null 2>&1; then
    echo "FAIL: jq not on PATH — required by the test stub" >&2
    exit 1
fi

repo_root=$(git rev-parse --show-toplevel)
hook="$repo_root/scripts/hooks/rtk-hook-guard.sh"

if [ ! -f "$hook" ]; then
    echo "FAIL: $hook not found" >&2
    exit 1
fi

pass=0
fail=0

assert_pass() {
    pass=$((pass + 1))
    echo "  PASS: $1"
}

assert_fail() {
    fail=$((fail + 1))
    echo "  FAIL: $1"
}

# ---------- stub rtk ----------
stub_dir=$(mktemp -d)
trap 'rm -rf "$stub_dir"' EXIT

cat > "$stub_dir/rtk" <<'STUB'
#!/usr/bin/env bash
# Stub of `rtk hook claude` (contract observed on rtk 0.40.0).
# jq-based parse + emit: robust to trailing payload fields
# and always emits valid JSON regardless of quoting in the command.
[ "${1:-}" = "hook" ] && [ "${2:-}" = "claude" ] || exit 1
payload=$(cat)
cmd=$(printf '%s' "$payload" | jq -r '.tool_input.command // empty')
case "$cmd" in
    *\|*) ;; # real rtk leaves piped/compound shell commands alone
    cd\ *\ \&\&\ git\ *) # real rtk rewrites the git worker of an && chain in place
        jq -nc --arg cmd "${cmd/ git / rtk git }" \
            '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecisionReason:"RTK auto-rewrite",updatedInput:{command:$cmd},permissionDecision:"allow"}}'
        ;;
    find\ *|git\ *|ls\ *|sort\ *|gh\ *)
        jq -nc --arg cmd "rtk $cmd" \
            '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecisionReason:"RTK auto-rewrite",updatedInput:{command:$cmd},permissionDecision:"allow"}}'
        ;;
    *) ;; # compound shell command etc. — rtk stays silent
esac
STUB
chmod +x "$stub_dir/rtk"

run_hook() { # $1 = command string (JSON-escaped); stdout = hook output
    printf '{"tool_name":"Bash","tool_input":{"command":"%s"}}' "$1" \
        | PATH="$stub_dir:$PATH" bash "$hook"
}

# ---------- 1. Simple find → rewrite forwarded ----------
echo "Test 1: simple find keeps the rtk rewrite"
for cmd in 'find . -name \"*.md\" -type f' 'find /tmp -maxdepth 1 -name x'; do
    out=$(run_hook "$cmd")
    if grepq "$out" '"rtk find '; then
        assert_pass "rewrite forwarded: $cmd"
    else
        assert_fail "expected rtk rewrite for '$cmd', got: $out"
    fi
done

# ---------- 2. Compound finds → suppressed ----------
echo "Test 2: compound finds pass through unrewritten (empty output)"
compound_cmds=(
    'find Clippings -name \"*.md\" -not -path \"*/_synthesis/*\" -not -path \"*/_done/*\" -not -name _deferred.md'
    'find . -name \"*.tmp\" -exec rm {} ;'
    'find . -name a -o -name b'
    'find . -name a -a -type f'
    'find . -name \"*.bak\" -delete'
    'find . -path ./skip -prune'
    'find . ! -name keep.md'
    'find . \\\\( -name a -o -name b \\\\)'
    'find . -name \"*.tmp\" -execdir rm {} ;'
)
for cmd in "${compound_cmds[@]}"; do
    set +e
    out=$(run_hook "$cmd")
    rc=$?
    set -e
    if [ "$rc" -eq 0 ] && [ -z "$out" ]; then
        assert_pass "suppressed: $cmd"
    else
        assert_fail "expected empty output rc=0 for '$cmd', got rc=$rc: $out"
    fi
done

# ---------- 3. Non-find rewrites forwarded even with -o-like tokens ----------
echo "Test 3: non-find rewrites untouched"
for cmd in 'git status' 'sort -o out.txt in.txt' 'ls -a /tmp'; do
    out=$(run_hook "$cmd")
    if grepq "$out" '"rtk '; then
        assert_pass "rewrite forwarded: $cmd"
    else
        assert_fail "expected rtk rewrite for '$cmd', got: $out"
    fi
done

# A git rewrite hides the executable from the claudex
# classifier. Suppression must not grant permission or affect native savings.
echo "Test 3b: claudex git stays in the original permission flow"
for config in '/tmp/.claude-codex' '/tmp/.claude-codex/' '/tmp/.claude-codex//'; do
    out=$(CLAUDE_CONFIG_DIR="$config" run_hook 'git fetch origin')
    if [ -z "$out" ]; then
        assert_pass "claudex git rewrite suppressed: $config"
    else
        assert_fail "expected empty claudex git output, got: $out"
    fi
done
for config in '' '/tmp/.claude' '/tmp/.claude-codex-other'; do
    out=$(CLAUDE_CONFIG_DIR="$config" run_hook 'git fetch origin')
    if grepq "$out" '"rtk git fetch origin"'; then
        assert_pass "native git rewrite preserved: $config"
    else
        assert_fail "expected native git rewrite, got: $out"
    fi
done
out=$(CLAUDE_CONFIG_DIR='/tmp/.claude-codex' run_hook 'ls -a /tmp')
if grepq "$out" '"rtk ls -a /tmp"'; then
    assert_pass "claudex non-git rewrite preserved"
else
    assert_fail "expected claudex non-git rewrite, got: $out"
fi

# The harness's worktree-isolation screen refuses a command that
# runs `rtk` with git among its operands (it cannot read what rtk runs), and
# the rtk rewrite hands it exactly that. No hook-visible signal says a session
# is worktree-pinned, so the guard keys on the payload cwd sitting inside a
# `.claude/worktrees/` tree: git in a worktree keeps its original, unwrapped
# form. A false positive only loses token savings.
run_hook_cwd() { # $1 = payload cwd, $2 = command (JSON-escaped)
    printf '{"session_id":"s","cwd":"%s","tool_name":"Bash","tool_input":{"command":"%s"}}' "$1" "$2" \
        | PATH="$stub_dir:$PATH" bash "$hook"
}
wt_cwd='/home/u/himmel/.claude/worktrees/fix+x'
echo "Test 3c: git in a worktree cwd is not rewritten to rtk"
for cwd in "$wt_cwd" "$wt_cwd/scripts/hooks"; do
    for cmd in 'git fetch origin' 'git push -u origin fix/x' 'cd /tmp && git status' \
        'gh pr create --body \"git push\"'; do
        out=$(run_hook_cwd "$cwd" "$cmd")
        if [ -z "$out" ]; then
            assert_pass "worktree cwd, rewrite suppressed: $cmd ($cwd)"
        else
            assert_fail "expected empty output for '$cmd' in $cwd, got: $out"
        fi
    done
done
echo "Test 3d: outside a worktree, or with no git operand, the rewrite is kept"
for cwd in '/home/u/himmel' '/home/u/himmel/.claude/worktrees' \
    '/home/u/himmel/.claude/worktrees-old/x' '/home/u/.claude-worktrees/x'; do
    out=$(run_hook_cwd "$cwd" 'git fetch origin')
    if grepq "$out" '"rtk git fetch origin"'; then
        assert_pass "git rewrite preserved: $cwd"
    else
        assert_fail "expected rtk git rewrite in $cwd, got: $out"
    fi
done
for cmd in 'ls -a /home/u/github/himmel' 'gh pr view 12'; do
    out=$(run_hook_cwd "$wt_cwd" "$cmd")
    if grepq "$out" '"rtk '; then
        assert_pass "worktree cwd, no git operand, rewrite preserved: $cmd"
    else
        assert_fail "expected rtk rewrite for '$cmd' in a worktree, got: $out"
    fi
done
out=$(run_hook 'git fetch origin')
if grepq "$out" '"rtk git fetch origin"'; then
    assert_pass "payload without cwd: git rewrite preserved"
else
    assert_fail "expected rtk git rewrite without a payload cwd, got: $out"
fi
# The no-jq fallback must reach the same verdict (cwd extracted by grep+sed).
gitwt_dir=$(mktemp -d "${TMPDIR:-/tmp}/rtk-guard-gitwt.XXXXXX")
printf '#!/usr/bin/env bash\nexit 1\n' > "$gitwt_dir/jq"
cat > "$gitwt_dir/rtk" <<'STUB'
#!/usr/bin/env bash
[ "${1:-}" = "hook" ] && [ "${2:-}" = "claude" ] || exit 1
cat >/dev/null
printf '%s' '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecisionReason":"RTK auto-rewrite","updatedInput":{"command":"rtk git status"},"permissionDecision":"allow"}}'
STUB
chmod +x "$gitwt_dir/jq" "$gitwt_dir/rtk"
out=$(printf '{"session_id":"s","cwd":"%s","tool_name":"Bash","tool_input":{"command":"git status"}}' "$wt_cwd" \
    | PATH="$gitwt_dir:$PATH" bash "$hook")
if [ -z "$out" ]; then
    assert_pass "no-jq fallback: worktree git rewrite suppressed"
else
    assert_fail "expected empty output via the no-jq fallback in a worktree, got: $out"
fi
out=$(printf '{"session_id":"s","cwd":"/home/u/himmel","tool_name":"Bash","tool_input":{"command":"git status"}}' \
    | PATH="$gitwt_dir:$PATH" bash "$hook")
if grepq "$out" '"rtk git status"'; then
    assert_pass "no-jq fallback: primary-checkout git rewrite preserved"
else
    assert_fail "expected rtk git rewrite via the no-jq fallback outside a worktree, got: $out"
fi
rm -rf "$gitwt_dir"

# ---------- 3e. Windows backslash worktree cwd ----------
# The `.claude/worktrees/` match above is slash-only, so a Windows payload
# cwd (backslash-separated) fails to match and the git rewrite is forwarded
# even inside a worktree. Cover both extraction forms: jq decodes JSON
# escapes to a single backslash; the no-jq grep+sed fallback keeps the
# JSON-escaped double backslash verbatim (see the extraction comment in the
# guard).
echo "Test 3e: Windows backslash worktree cwd drops the git rewrite"
win_wt_cwd='C:\\Users\\u\\repo\\.claude\\worktrees\\fix+x'
for cmd in 'git fetch origin' 'git push -u origin fix/x'; do
    out=$(run_hook_cwd "$win_wt_cwd" "$cmd")
    if [ -z "$out" ]; then
        assert_pass "Windows backslash worktree cwd (jq path), rewrite suppressed: $cmd"
    else
        assert_fail "expected empty output for '$cmd' in $win_wt_cwd (jq path), got: $out"
    fi
done

winwt_dir=$(mktemp -d "${TMPDIR:-/tmp}/rtk-guard-winwt.XXXXXX")
printf '#!/usr/bin/env bash\nexit 1\n' > "$winwt_dir/jq"
cat > "$winwt_dir/rtk" <<'STUB'
#!/usr/bin/env bash
[ "${1:-}" = "hook" ] && [ "${2:-}" = "claude" ] || exit 1
cat >/dev/null
printf '%s' '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecisionReason":"RTK auto-rewrite","updatedInput":{"command":"rtk git status"},"permissionDecision":"allow"}}'
STUB
chmod +x "$winwt_dir/jq" "$winwt_dir/rtk"
out=$(printf '{"session_id":"s","cwd":"%s","tool_name":"Bash","tool_input":{"command":"git status"}}' "$win_wt_cwd" \
    | PATH="$winwt_dir:$PATH" bash "$hook")
if [ -z "$out" ]; then
    assert_pass "Windows backslash worktree cwd (no-jq fallback), rewrite suppressed"
else
    assert_fail "expected empty output for Windows backslash worktree cwd via the no-jq fallback, got: $out"
fi
rm -rf "$winwt_dir"

echo "Test 3f: backslash lookalikes keep the rewrite"
for cwd in \
    'C:\\Users\\u\\repo\\.claude\\worktreesX\\fix+x' \
    'C:\\Users\\u\\repo\\claude\\worktrees\\fix+x' \
    'C:\\Users\\u\\otherdir'; do
    out=$(run_hook_cwd "$cwd" 'git fetch origin')
    if grepq "$out" '"rtk git fetch origin"'; then
        assert_pass "git rewrite preserved: $cwd"
    else
        assert_fail "expected rtk git rewrite in $cwd, got: $out"
    fi
done

# ---------- 3g. Mixed forward/backslash worktree cwd ----------
# Decision (PR body): the backslash arm matches the literal
# \.claude\worktrees\ segment regardless of what precedes it, mirroring the
# forward-slash arm's own "don't care what precedes /.claude/worktrees/"
# behaviour. A payload whose leading components use forward slashes but
# whose worktree segment itself uses backslashes still names a
# backslash-separated (Windows) worktree, so it drops the rewrite too.
echo "Test 3g: mixed-separator worktree cwd drops the git rewrite"
mixed_wt_cwd='C:/Users/u/repo\\.claude\\worktrees\\x'
out=$(run_hook_cwd "$mixed_wt_cwd" 'git fetch origin')
if [ -z "$out" ]; then
    assert_pass "mixed-separator worktree cwd, rewrite suppressed"
else
    assert_fail "expected empty output for mixed-separator worktree cwd, got: $out"
fi

run_hook_leg() {
    printf '{"session_id":"s","cwd":"%s","tool_name":"Bash","tool_input":{"command":"%s"}}' "$1" "$2" \
        | HIMMEL_CONSOLE_LEG=1 PATH="$stub_dir:$PATH" bash "$hook"
}
echo "Test 3h: a worker's simple git commit in a worktree keeps the rtk rewrite"
for cmd in 'git commit -F /tmp/msg' 'git commit -q -m \"fix(x): y\"' 'git commit'; do
    out=$(run_hook_leg "$wt_cwd" "$cmd")
    if grepq "$out" '"rtk git commit'; then
        assert_pass "worker worktree commit rewritten: $cmd"
    else
        assert_fail "expected rtk git commit rewrite for '$cmd', got: $out"
    fi
done
# shellcheck disable=SC2016
for cmd in 'git commit -F /tmp/msg && git push' 'git commit -F /tmp/msg; git log -1' \
    'git push -u origin fix/x' 'git diff origin/main' 'git show HEAD' 'git commit -m \"git push\"' \
    'cd /tmp && git commit -F /tmp/msg' 'git commit -m \"$(id)\"' 'git commit -m `id`' \
    'git commit -F /tmp/msg > /tmp/out' 'git commit -F <(id)'; do
    out=$(run_hook_leg "$wt_cwd" "$cmd")
    if [ -z "$out" ]; then
        assert_pass "worker worktree rewrite still suppressed: $cmd"
    else
        assert_fail "expected empty output for '$cmd' in a worker worktree, got: $out"
    fi
done
out=$(run_hook_cwd "$wt_cwd" 'git commit -F /tmp/msg')
if [ -z "$out" ]; then
    assert_pass "non-worker worktree commit still suppressed"
else
    assert_fail "expected empty output for a non-worker worktree commit, got: $out"
fi
silent_dir=$(mktemp -d "${TMPDIR:-/tmp}/rtk-guard-silent.XXXXXX") || { echo "FAIL: cannot make a stub dir" >&2; exit 1; }
printf '#!/usr/bin/env bash\ncat >/dev/null\nexit 0\n' > "$silent_dir/rtk"
chmod +x "$silent_dir/rtk"
run_silent() {
    printf '{"session_id":"s","cwd":"%s","tool_name":"Bash","tool_input":{"command":"%s","description":"d"}}' "$wt_cwd" "$2" \
        | HIMMEL_CONSOLE_LEG="$1" CLAUDE_CONFIG_DIR="$3" PATH="$silent_dir:$PATH" bash "$hook"
}
out=$(run_silent 1 'git commit -F /tmp/msg' '')
if [ "$(printf '%s' "$out" | jq -r '.hookSpecificOutput.updatedInput.command + "|" + .hookSpecificOutput.updatedInput.description')" = 'rtk git commit -F /tmp/msg|d' ]; then
    assert_pass "silent rtk: the guard writes a worker's commit rewrite, other input fields kept"
else
    assert_fail "silent rtk: expected the guard's rtk git commit rewrite, got: $out"
fi
# shellcheck disable=SC2016
for row in '|git commit -F /tmp/msg|' '1|git commit -F /tmp/msg && git push|' '1|git push|' \
    '1|git commit -m \"$(id)\"|' '1|git commit -m `id`|' \
    '1|git commit -F /tmp/msg|/home/u/.claude-codex'; do
    leg=${row%%|*}; rest=${row#*|}; cmd=${rest%%|*}; cfg=${rest#*|}
    out=$(run_silent "$leg" "$cmd" "$cfg")
    if [ -z "$out" ]; then
        assert_pass "silent rtk: no rewrite for leg='$leg' cfg='$cfg': $cmd"
    else
        assert_fail "silent rtk: expected no rewrite for leg='$leg' cfg='$cfg' '$cmd', got: $out"
    fi
done
rm -rf "$silent_dir"

# ---------- 4. rtk silent (compound shell command) ----------
echo "Test 4: rtk emits nothing → guard emits nothing"
set +e
out=$(run_hook 'find . -name \"*.md\" | head -5')
rc=$?
set -e
if [ "$rc" -eq 0 ] && [ -z "$out" ]; then
    assert_pass "silent rtk handled"
else
    assert_fail "expected empty rc=0, got rc=$rc: $out"
fi

# ---------- 5. rtk missing → fail-open ----------
echo "Test 5: rtk missing from PATH → fail-open"
empty_dir=$(mktemp -d)
set +e
out=$(printf '{"tool_name":"Bash","tool_input":{"command":"find . -name x"}}' \
    | PATH="$empty_dir:/usr/bin:/bin" bash "$hook" 2>/dev/null)
rc=$?
set -e
rm -rf "$empty_dir"
if [ "$rc" -eq 0 ] && [ -z "$out" ]; then
    assert_pass "missing rtk → empty, exit 0"
else
    assert_fail "expected empty rc=0 without rtk, got rc=$rc: $out"
fi

# ---------- 6. rtk crashes → fail-open ----------
echo "Test 6: rtk crash → fail-open"
crash_dir=$(mktemp -d)
printf '#!/usr/bin/env bash\nexit 1\n' > "$crash_dir/rtk"
chmod +x "$crash_dir/rtk"
set +e
out=$(printf '{"tool_name":"Bash","tool_input":{"command":"find . -name x"}}' \
    | PATH="$crash_dir:$PATH" bash "$hook")
rc=$?
set -e
rm -rf "$crash_dir"
if [ "$rc" -eq 0 ] && [ -z "$out" ]; then
    assert_pass "crashing rtk → empty, exit 0"
else
    assert_fail "expected empty rc=0 on rtk crash, got rc=$rc: $out"
fi

# ---------- 7. Empty stdin ----------
echo "Test 7: empty stdin tolerated"
set +e
out=$(PATH="$stub_dir:$PATH" bash "$hook" </dev/null)
rc=$?
set -e
if [ "$rc" -eq 0 ] && [ -z "$out" ]; then
    assert_pass "empty stdin → empty, exit 0"
else
    assert_fail "expected empty rc=0 on empty stdin, got rc=$rc: $out"
fi

# ---------- 8. reason text containing "-not" must not suppress ----------
# The guard scans only the rewritten command VALUE. A
# permissionDecisionReason mentioning a rejected token (output-shape
# drift) must not cost the safe rewrite.
echo "Test 8: '-not' in permissionDecisionReason does not suppress a safe rewrite"
reason_dir=$(mktemp -d)
cat > "$reason_dir/rtk" <<'STUB'
#!/usr/bin/env bash
[ "${1:-}" = "hook" ] && [ "${2:-}" = "claude" ] || exit 1
cat >/dev/null
printf '%s' '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecisionReason":"rewrote find; rtk find rejects -not and -exec","updatedInput":{"command":"rtk find . -name x"},"permissionDecision":"allow"}}'
STUB
chmod +x "$reason_dir/rtk"
out=$(printf '{"tool_name":"Bash","tool_input":{"command":"find . -name x"}}' \
    | PATH="$reason_dir:$PATH" bash "$hook")
rm -rf "$reason_dir"
if grepq "$out" '"rtk find '; then
    assert_pass "reason-only token did not suppress the rewrite"
else
    assert_fail "expected forwarded rewrite despite '-not' in reason, got: $out"
fi

# ---------- 9. jq broken → grep+sed fallback ----------
# The guard's no-jq contract: extraction falls back to grep+sed on the
# JSON-escaped command value and the verdict must not change.
echo "Test 9: broken jq → fallback still suppresses compound, forwards simple"
nojq_dir=$(mktemp -d)
printf '#!/usr/bin/env bash\nexit 1\n' > "$nojq_dir/jq"
chmod +x "$nojq_dir/jq"
cat > "$nojq_dir/rtk" <<'STUB'
#!/usr/bin/env bash
[ "${1:-}" = "hook" ] && [ "${2:-}" = "claude" ] || exit 1
payload=$(cat)
case "$payload" in
    *_done*)
        printf '%s' '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecisionReason":"RTK auto-rewrite","updatedInput":{"command":"rtk find Clippings -name \"*.md\" -not -path \"*/_done/*\""},"permissionDecision":"allow"}}'
        ;;
    *)
        printf '%s' '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecisionReason":"RTK auto-rewrite","updatedInput":{"command":"rtk find . -name \"*.md\" -type f"},"permissionDecision":"allow"}}'
        ;;
esac
STUB
chmod +x "$nojq_dir/rtk"
set +e
out=$(printf '{"tool_name":"Bash","tool_input":{"command":"find Clippings -name \\"*.md\\" -not -path \\"*/_done/*\\""}}' \
    | PATH="$nojq_dir:$PATH" bash "$hook")
rc=$?
set -e
if [ "$rc" -eq 0 ] && [ -z "$out" ]; then
    assert_pass "fallback suppressed compound find"
else
    assert_fail "expected empty rc=0 via fallback, got rc=$rc: $out"
fi
out=$(printf '{"tool_name":"Bash","tool_input":{"command":"find . -name \\"*.md\\" -type f"}}' \
    | PATH="$nojq_dir:$PATH" bash "$hook")
if grepq "$out" '"rtk find '; then
    assert_pass "fallback forwarded simple find"
else
    assert_fail "expected forwarded rewrite via fallback, got: $out"
fi
rm -rf "$nojq_dir"

# ---------- 10. Trailing payload field after command ----------
# Regression for the old }}-anchored sed stub, which emitted nothing
# (and so false-passed every forwarding test) once the harness appended
# a field after tool_input.command.
echo "Test 10: payload with trailing field still parsed by the stub"
out=$(printf '{"tool_name":"Bash","tool_input":{"command":"find . -name x","description":"trailing field"}}' \
    | PATH="$stub_dir:$PATH" bash "$hook")
if grepq "$out" '"rtk find '; then
    assert_pass "trailing field tolerated, rewrite forwarded"
else
    assert_fail "expected forwarded rewrite with trailing field, got: $out"
fi

# ---------- 11. Output-shape drift: command field renamed ----------
# Extraction-failure contract: when neither jq nor the
# grep fallback can extract the command (field renamed/absent), output
# that still contains an `rtk find ` rewrite must be SUPPRESSED — the
# guard could not scan it, and forwarding an unscanned rewrite is the
# original bug. Drifted output with no rtk-find rewrite is forwarded
# verbatim (nothing the guard screens).
echo "Test 11: renamed command field → suppress rtk-find output, forward non-find"
drift_dir=$(mktemp -d)
cat > "$drift_dir/rtk" <<'STUB'
#!/usr/bin/env bash
[ "${1:-}" = "hook" ] && [ "${2:-}" = "claude" ] || exit 1
payload=$(cat)
case "$payload" in
    *find*)
        printf '%s' '{"hookSpecificOutput":{"hookEventName":"PreToolUse","updatedInput":{"cmd":"rtk find . -name x"},"permissionDecision":"allow"}}'
        ;;
    *)
        printf '%s' '{"hookSpecificOutput":{"hookEventName":"PreToolUse","updatedInput":{"cmd":"rtk git status"},"permissionDecision":"allow"}}'
        ;;
esac
STUB
chmod +x "$drift_dir/rtk"
set +e
out=$(printf '{"tool_name":"Bash","tool_input":{"command":"find . -name x"}}' \
    | PATH="$drift_dir:$PATH" bash "$hook")
rc=$?
set -e
if [ "$rc" -eq 0 ] && [ -z "$out" ]; then
    assert_pass "drifted rtk-find output suppressed"
else
    assert_fail "expected empty rc=0 for drifted rtk-find output, got rc=$rc: $out"
fi
out=$(printf '{"tool_name":"Bash","tool_input":{"command":"git status"}}' \
    | PATH="$drift_dir:$PATH" bash "$hook")
if grepq "$out" '"rtk git status"'; then
    assert_pass "drifted non-find output forwarded verbatim"
else
    assert_fail "expected forwarded drifted non-find output, got: $out"
fi
rm -rf "$drift_dir"

# ---------- 12. No jq + original command as FIRST "command" pair ----------
# An unanchored first-match fallback would extract the
# ORIGINAL command from a drifted shape that echoes tool_input before
# the rewrite — the compound rtk-find rewrite would then be forwarded
# unscanned. The fallback anchors on `"command":"rtk find ` so it finds
# the rewrite regardless of position and suppresses it.
echo "Test 12: anchored fallback skips a leading original-command pair"
firstpair_dir=$(mktemp -d)
printf '#!/usr/bin/env bash\nexit 1\n' > "$firstpair_dir/jq"
chmod +x "$firstpair_dir/jq"
cat > "$firstpair_dir/rtk" <<'STUB'
#!/usr/bin/env bash
[ "${1:-}" = "hook" ] && [ "${2:-}" = "claude" ] || exit 1
cat >/dev/null
printf '%s' '{"toolInput":{"command":"find . -not -name x"},"hookSpecificOutput":{"hookEventName":"PreToolUse","updatedInput":{"command":"rtk find . -not -name x"},"permissionDecision":"allow"}}'
STUB
chmod +x "$firstpair_dir/rtk"
set +e
out=$(printf '{"tool_name":"Bash","tool_input":{"command":"find . -not -name x"}}' \
    | PATH="$firstpair_dir:$PATH" bash "$hook")
rc=$?
set -e
rm -rf "$firstpair_dir"
if [ "$rc" -eq 0 ] && [ -z "$out" ]; then
    assert_pass "compound rewrite behind a leading original-command pair suppressed"
else
    assert_fail "expected empty rc=0 (anchored fallback), got rc=$rc: $out"
fi

# ---------- 13. Live installed rtk ----------
# The rejected/accepted token set in the header comment above was verified
# against rtk 0.40.0; every test above runs the STUB, so a station whose
# real rtk changed behaviour would never surface it. This row re-checks the
# one fact the guard's suppression depends on -- that the actually-installed
# rtk still emits an unsuppressed `rtk find` rewrite for a compound
# predicate, and a plain rewrite for a simple one -- against whatever rtk is
# really on PATH. SKIPs cleanly when no rtk is installed; the stub rows above
# still give hermetic coverage either way.
echo "Test 13: live installed rtk (if present) still needs suppression, and gets it"
if real_rtk=$(command -v rtk 2>/dev/null); then
    real_ver=$("$real_rtk" -V 2>/dev/null || echo "unknown")
    real_dir=$(dirname "$real_rtk")
    echo "  (installed: $real_ver at $real_rtk)"
    set +e
    out=$(printf '{"tool_name":"Bash","tool_input":{"command":"find . -name \\"*.md\\" -not -path \\"*/_done/*\\""}}' \
        | PATH="$real_dir:$PATH" bash "$hook")
    rc=$?
    set -e
    if [ "$rc" -eq 0 ] && [ -z "$out" ]; then
        assert_pass "installed rtk ($real_ver): compound find suppressed"
    else
        assert_fail "installed rtk ($real_ver): expected empty rc=0 for compound find, got rc=$rc: $out"
    fi
    out=$(printf '{"tool_name":"Bash","tool_input":{"command":"find . -name \\"*.md\\" -type f"}}' \
        | PATH="$real_dir:$PATH" bash "$hook")
    if grepq "$out" '"rtk find '; then
        assert_pass "installed rtk ($real_ver): simple find rewrite forwarded"
    else
        assert_fail "installed rtk ($real_ver): expected forwarded rewrite for simple find, got: $out"
    fi
else
    echo "  SKIP: no rtk installed on PATH -- stub-only coverage stands"
fi

echo "Test 14: worker commit through the guard: capped when it passes, failing line kept with rtk on and off"
if real_rtk=$(command -v rtk 2>/dev/null); then
    real_dir=$(dirname "$real_rtk")
    if ! { [ -r "$repo_root/scripts/lib/git-clean.sh" ] && . "$repo_root/scripts/lib/git-clean.sh"; }; then
        echo "FAIL: cannot load scripts/lib/git-clean.sh" >&2
        exit 1
    fi
    git_env_scrub
    cap=5
    repo14=$(mktemp -d "${TMPDIR:-/tmp}/rtk-guard-commit.XXXXXX") || { echo "FAIL: cannot make a scratch repo" >&2; exit 1; }
    commit_n=0
    msg14="$repo14.msg"
    printf 'test commit\n' > "$msg14"
    git -C "$repo14" init -q
    git -C "$repo14" config user.name t
    git -C "$repo14" config user.email t@example.invalid
    cat > "$repo14/.git/hooks/pre-commit" <<'HOOK'
#!/bin/sh
i=1
while [ "$i" -le 60 ]; do
    echo "hook number $i....................................................Passed"
    i=$((i + 1))
done
[ "${PROBE_RC:-0}" = "0" ] && exit 0
echo "Detect hardcoded secrets.............................................Failed"
echo "- hook id: gitleaks"
echo "- exit code: 1"
echo "FAILING-LINE-14"
exit 1
HOOK
    chmod +x "$repo14/.git/hooks/pre-commit"
    commit_payload=$(printf '{"session_id":"s","cwd":"%s","tool_name":"Bash","tool_input":{"command":"git commit -F %s"}}' "$wt_cwd" "$msg14")
    on_out=$(printf '%s' "$commit_payload" | HIMMEL_CONSOLE_LEG=1 PATH="$real_dir:$PATH" bash "$hook")
    on_cmd=$(printf '%s' "$on_out" | jq -r '.hookSpecificOutput.updatedInput.command // empty')
    off_out=$(printf '%s' "$commit_payload" | PATH="$real_dir:$PATH" bash "$hook")
    off_cmd="git commit -F $msg14"
    if [ -z "$off_out" ]; then
        assert_pass "rtk off: a non-worker worktree commit runs unwrapped"
    else
        assert_fail "rtk off: expected no rewrite for a non-worker worktree commit, got: $off_out"
    fi
    if [ "${on_cmd#rtk git commit }" != "$on_cmd" ]; then
        assert_pass "rtk on: the guard forwards a worker's commit as rtk git commit"
    else
        assert_fail "rtk on: expected an rtk git commit rewrite, got: $on_out"
        on_cmd="$off_cmd"
    fi
    run_commit() {
        local rc=0 o
        commit_n=$((commit_n + 1))
        echo "$commit_n" >> "$repo14/f"
        git -C "$repo14" add f
        o=$(cd "$repo14" && PROBE_RC="$2" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 PATH="$real_dir:$PATH" bash -c "$1" 2>&1) || rc=$?
        printf '%s\nrc=%s\n' "$o" "$rc"
    }
    res=$(run_commit "$off_cmd" 0)
    n=$(grep -c '' <<< "$res")
    if [ "$n" -gt "$cap" ] && grepq "$res" -x 'rc=0'; then
        assert_pass "RED: a passing unwrapped commit prints $n lines, over the cap of $cap"
    else
        assert_fail "RED: expected over $cap lines and rc=0 from the unwrapped commit, got $n: $res"
    fi
    res=$(run_commit "$on_cmd" 0)
    n=$(grep -c '' <<< "$res")
    if [ "$n" -le "$cap" ] && grepq "$res" -x 'rc=0'; then
        assert_pass "GREEN: a passing rtk commit prints $n lines, within the cap"
    else
        assert_fail "GREEN: expected at most $cap lines and rc=0 from the rtk commit, got $n: $res"
    fi
    for mode in on off; do
        if [ "$mode" = on ]; then c="$on_cmd"; else c="$off_cmd"; fi
        res=$(run_commit "$c" 1)
        failed_at=$(awk '/Failed$/ { print NR; exit }' <<< "$res")
        line_at=$(awk '/^FAILING-LINE-14$/ { print NR; exit }' <<< "$res")
        if [ "$(awk '/^FAILING-LINE-14$/ { n++ } END { print n + 0 }' <<< "$res")" -eq 1 ] && [ -n "$failed_at" ] \
            && [ "$failed_at" -lt "$line_at" ] && grepq "$res" -x 'rc=1'; then
            assert_pass "rtk $mode: a failing commit prints its failing line once, after the Failed line, rc=1"
        else
            assert_fail "rtk $mode: expected the failing line once after the Failed line and rc=1, got: $res"
        fi
    done
    rm -rf "$repo14" "$msg14"
else
    echo "  SKIP: no rtk installed on PATH -- stub rows in 3h stand"
fi

# ---------- summary ----------
echo ""
echo "rtk-hook-guard: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
