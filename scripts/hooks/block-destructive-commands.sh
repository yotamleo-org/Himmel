#!/usr/bin/env bash
# PreToolUse hook for Bash/PowerShell.
#
# Deterministic destructive-command floor shared by Claude and Codex lanes.
# Ports the TERMINAL_DESTRUCTIVE command classes from
# scripts/hermes/assets/parity_guard.py: catastrophic/shared-machine/
# irreversible terminal shapes only. Routine git/gh/mv/cp, non-recursive rm,
# curl without remote-exec pipe, and normal git status/commit/push are allowed.
#
# Hook input arrives on stdin as JSON. Exit codes:
#   0 - allow
#   2 - block; stderr is shown to the model/user
#
# Bypass: set DESTRUCTIVE_OK=1 in the shell that launched the agent. Session-
# sticky; restart without it to re-enable the guard.
set -euo pipefail

# Security hook: any unexpected top-level failure must deny, not fail open as a
# plain rc=1 hook error.
# shellcheck disable=SC2154 # rc is assigned inside the trap string.
trap 'rc=$?; if [ "$rc" != 0 ] && [ "$rc" != 2 ]; then exit 2; fi' EXIT

if [ "${DESTRUCTIVE_OK:-0}" = "1" ]; then
    exit 0
fi

if ! command -v jq >/dev/null 2>&1; then
    echo "block-destructive-commands: jq not on PATH - refusing to evaluate; install jq" >&2
    exit 2
fi

# Bash builtin `read` instead of `$(cat)` drops one spawn per
# call. The three separate `printf '%s' "$input" | jq ...` pipelines below
# (validate, extract tool_name, extract command — six forks: printf+jq
# each) are collapsed into ONE jq call via `<<<` (no printf fork) that
# validates AND extracts both fields together: a malformed/non-parseable
# payload makes the whole call fail exactly like the old standalone
# `jq -e .` did, so the fail-closed branch is unchanged. Windows jq.exe
# writes CRLF, so the embedded "\n" field separator can arrive as "\r\n" —
# strip the stray CR off $tool (same shape as require-quiet-run.sh and
# block-tail-pipe-on-gates.sh).
input=""
IFS= read -r -d '' input 2>/dev/null || true
# Empty/whitespace-only stdin must fail CLOSED,
# same as the old `printf | jq -e .` did on it (jq -e on "" is a parse
# error -> exit 2). `read -d ''` on EOF leaves $input empty with no error
# to catch (`|| true` swallows its own rc), and `jq <<<""` on blank input
# emits zero values with zero errors, so the `if ! result=$(...)` guard
# below never fires -> silent fail-OPEN on a security fence. Catch it here,
# before jq ever runs (no spawn).
case "$input" in
    *[![:space:]]*) ;;
    *) echo "block-destructive-commands: empty/blank stdin - failing closed" >&2; exit 2 ;;
esac
# `if ! result=$(...); then` (not a bare assignment) so a failing jq does not
# trip `set -e` before the fail-closed branch below can run.
#
# The filter reproduces the old two-step semantics in one jq call:
#   * top-level null/false, or genuinely unparsable JSON, both make jq exit
#     non-zero (via `error(...)` for the former, a parse failure for the
#     latter) -- same "malformed/truncated" fail-closed as the old
#     standalone `jq -e .` validation.
#   * anything else (object/array/string/number/true) proceeds to field
#     access; `try ... catch empty` swallows the "cannot index" runtime
#     error a non-object top-level value throws there, same as the old
#     per-field `|| true` fallbacks -- both land on empty tool/cmd, which
#     falls through to allow below exactly as before.
#   * A NON-STRING but
#     present `command`/`cmd` (e.g. `"command":["rm -rf /"]`) made jq's `+`
#     a type error ("string and array cannot be added") -- a DIFFERENT
#     failure than "cannot index", still swallowed by the same
#     `catch empty`, silently blanking tool AND cmd and falling through to
#     ALLOW. First fix attempt used `|tostring` on both operands, but that
#     renders arrays/objects as COMPACT json ("["x"]"), while old's
#     `jq -r` rendered them PRETTY-PRINTED across multiple lines -- and
#     those embedded newlines, folded to `;` by cmd_lc below, accidentally
#     created a command-position separator right before the quoted command
#     text that let the destructive-command match still fire. `tostring`
#     does not reproduce that accidental multi-line shape, so it is NOT a
#     reliable substitute (verified: an array command stayed allowed with
#     `tostring`, still blocked on old). Chasing byte-parity with jq's
#     pretty-printer is not worth it for a shape no real harness payload
#     produces (`tool_input.command` is always a string): explicitly ERROR
#     -- and thus fail CLOSED via the same branch below -- when `command`/
#     `cmd` IS present and its type is not "string" or "null". This is
#     MORE conservative than old's incidental behavior, not merely
#     equivalent to it, which is the correct direction for a security
#     fence on an input shape that should never occur.
if ! result=$(jq -r 'if (. == null or . == false) then error("bad-shape") else ((try (.tool_input | if has("command") and .command != null then .command else .cmd end) catch null) as $c | if ($c != null and ($c|type) != "string") then error("non-string-command") else (((try (.tool_name) catch null) // "" | tostring) + "\n" + ($c // "")) end) end' <<<"$input" 2>/dev/null); then
    echo "block-destructive-commands: malformed/truncated JSON on stdin - failing closed" >&2
    exit 2
fi
tool="${result%%$'\n'*}"
tool="${tool%$'\r'}"
cmd="${result#*$'\n'}"
case "$tool" in
    Bash|PowerShell|"") ;;
    *) exit 0 ;;
esac

[ -z "$cmd" ] && exit 0

# Re-read the forms the shell actually runs (quotes removed,
# wrappers stripped, `bash -c`/`eval` bodies) through this same hook. The lib
# is a must-run dependency: if it cannot be sourced, deny. It is
# loaded for PowerShell too, because the git argv parser below reads every
# command through its tokenizer; only the unwrap re-scan stays Bash-only.
case "${BASH_SOURCE[0]}" in
    */*) _gu_lib=${BASH_SOURCE[0]%/*}/lib/guard-unwrap.sh ;;
    *) _gu_lib=lib/guard-unwrap.sh ;;
esac
# shellcheck source=lib/guard-unwrap.sh
if ! { [ -r "$_gu_lib" ] && . "$_gu_lib"; } 2>/dev/null; then
    echo "block-destructive-commands: cannot load $_gu_lib - failing closed" >&2
    exit 2
fi
if [ "$tool" != PowerShell ]; then
    guard_unwrap "${BASH_SOURCE[0]}" "$cmd" || exit 2
fi

# parity_guard.norm() lower-cases before applying TERMINAL_DESTRUCTIVE. Newlines
# separate shell commands, so preserve them as semicolon boundaries.
# One `tr` call (a single SET1/SET2 char-class mapping covers both the case fold
# and the newline/CR fold) instead of two chained `tr` invocations — same output,
# one fewer fork. `printf` (not `<<<`) is kept deliberately: many patterns below
# anchor on `$` (end-of-string), and a herestring's synthetic trailing newline
# would fold to an extra trailing ';' that a `$`-anchored pattern does not expect.
cmd_lc=$(printf '%s' "$cmd" | LC_ALL=C tr '[:upper:]\n\r' '[:lower:];;')
# The shell drops a backslash-newline pair before it splits words,
# but the fold above turns that newline into `;`, so `git reset \<NL>--hard`
# reads as two commands. cmd_lc_join drops each pair (`\` + LF, or `\` + CRLF
# for Windows jq text mode) BEFORE the fold. It is a SECOND scan source, never
# a replacement: a backslash inside a comment or single quotes is not a
# continuation (`ls # x \<NL>rm -rf d` still runs the rm), so cmd_lc keeps
# every match it had and the join only ever adds denies. A typed `\;` (find's
# `-exec rm {} \;`) is not a line break and stays put.
_bsnl=$'\\\n'
_bscrlf=$'\\\r\n'
cmd_lc_join="$cmd_lc"
if [[ $cmd == *"$_bsnl"* || $cmd == *"$_bscrlf"* ]]; then
    cmd_lc_join=$(printf '%s' "$cmd" | LC_ALL=C tr '[:upper:]' '[:lower:]')
    cmd_lc_join="${cmd_lc_join//"$_bscrlf"/}"
    cmd_lc_join="${cmd_lc_join//"$_bsnl"/}"
    cmd_lc_join="${cmd_lc_join//[$'\r\n']/;}"
fi
# An expansion that is empty at run time can stand before the
# command word (`${V:-}rm`, `$V rm`, zsh's `$V:t rm`, `$V[1,-3]rm`,
# `${(P)V}rm`), so the shell runs `rm` while the text shows `${V:-}rm`.
# cmd_lc_noexp drops every run of expansions at command position (start of
# text or after ; & | ( or a backtick). A THIRD scan source: it only adds
# denies. Built only when the text carries a `$`. Each pass rescans the text,
# so past 256 runs the loop stops and the command is refused (below, once
# deny exists) rather than paying a quadratic scan.
# The rm scans below read their own scrubbed text and run the same strip.
# shellcheck disable=SC2016 # a literal `$` in the ERE, not an expansion
_noexp_re='(^[[:space:]]*|[;&|(`][[:space:]]*)(\$(\{[^}]*\}|[a-z_][a-z0-9_]*(:[a-z]|\[[^]]*\])*|[0-9#?*@!$-]))+[[:space:]]*'
_noexp_over=0
# _noexp_strip TEXT — REPLY is TEXT with command-position expansions dropped.
_noexp_strip() {
    local s=$1 n=0
    while [[ $s =~ $_noexp_re ]]; do
        if [ "$n" -ge 256 ]; then _noexp_over=1; break; fi
        s=${s/"${BASH_REMATCH[0]}"/"${BASH_REMATCH[1]}"}
        n=$((n + 1))
    done
    REPLY=$s
}
cmd_lc_noexp=''
_noexp=0
if [[ $cmd_lc_join == *'$'* ]]; then
    _noexp_strip "$cmd_lc_join"; cmd_lc_noexp=$REPLY
    [ "$cmd_lc_noexp" = "$cmd_lc_join" ] || _noexp=1
fi

# contains ERE -> true iff $cmd_lc (or its joined twin cmd_lc_join) matches ERE.
#
# This was `printf '%s' "$cmd_lc" | grep -Eq "$1"` — a fork PAIR
# (subshell + grep) per call, and the deny floor below calls it 18 times, so
# every Bash/PowerShell tool call paid 36 process spawns. On Windows with
# Defender real-time scanning a spawn costs ~667 ms (~10x a normal Git-Bash
# spawn), which made this single function ~24 s of the ~66 s PreToolUse chain
# and shrank a 45-minute worker budget to ~20 tool calls.
#
# `[[ =~ ]]` is the same POSIX ERE, evaluated in-process with zero spawns, and
# every pattern below is passed through UNCHANGED. Two invariants make the
# substitution exact:
#   * the pattern MUST be held in a variable and left UNQUOTED on the right of
#     `=~` — a quoted pattern is matched as a literal string in bash >= 3.2;
#   * `cmd_lc` is a single line by construction (the `tr` above folds newlines
#     and CRs to ';'), so grep's line-oriented `^`/`$` and bash's
#     whole-string `^`/`$` mean the same thing here.
# Both forms return 0 match / 1 no-match / 2 bad-pattern, so callers are
# unchanged. Equivalence is pinned per-rule in the paired test suite.
contains() {
    local re="$1"
    [[ $cmd_lc =~ $re ]] || [[ $cmd_lc_join =~ $re ]] \
        || { [ "$_noexp" = 1 ] && [[ $cmd_lc_noexp =~ $re ]]; }
}

# Bracket-class substitutions over ASCII-only classes, run in the C locale: in a
# UTF-8 locale `${s//[class]/x}` is quadratic on multibyte text.
# Multibyte UTF-8 sequences contain no ASCII byte, so byte semantics give the
# same string. Result in REPLY.
_c_strip_quotes() { local LC_ALL=C; REPLY=${1//[\"\'\\]/}; }
_c_keep_char() { local LC_ALL=C; REPLY=${1//[^$2]/}; }

deny() {
    echo "block-destructive-commands: destructive command refused ($1); bypass: DESTRUCTIVE_OK=1 in the launching shell (per run)" >&2
    exit 2
}
[ "$_noexp_over" = 0 ] || deny "more than 256 expansions at command position"

# Sanctioned CLIProxyAPI proxy lifecycle: bouncing the proxy
# needs process termination (taskkill / Stop-Process / schtasks /end), all of
# which the deny floor below refuses at command position. The SAFE path is the
# cli-proxy-lane.ps1 -Restart/-Stop verb, which does that termination INTERNALLY
# -- this hook only ever sees the command the agent hands the shell, never a
# script's internals. Permit EXACTLY these literal invocation shapes: a `case`
# on the WHOLE lowercased command with QUOTED (non-glob) alternatives, so the
# match is anchored end-to-end with no wildcards -- a near-miss (a different
# script path, an appended destructive command, or a direct taskkill) does NOT
# inherit a free pass and still hits the deny floor below. powershell and pwsh
# both carry the script (dual-shell convention). The combined -Install -Restart
# [-Force] one-shot pin-roll (.EXAMPLE) is carved out here so the sanctioned forms
# enumerated below match the documented lifecycle.
#
# Why this carve-out carries NO cwd/repo-root anchor. The
# sanctioned path is RELATIVE, so a roamed shell CWD could in principle resolve
# it to an impostor `scripts/setup/cli-proxy-lane.ps1`. But anchoring THIS
# carve-out cannot close that vector, because the deny floor below INDEPENDENTLY
# allows `powershell/pwsh -NoProfile -File <any relative script>`: no deny rule
# matches (the CMDPOS grammar only arms `-c` as a launcher wrapper, not `-File`,
# and -restart/-stop/-install/-force are not destructive primitives at command
# position). An escaped/impostor relative invocation that does NOT match this
# exact case therefore still passes the floor (rc=0 -- verified empirically: a
# `./`-prefixed path, a `../` escape, and a `cd x; ...` prefix all return rc=0).
# The relative-resolution vector is a FLOOR-LEVEL residual (script-internals
# unseen -- the documented no-general-parser gap), not a hole
# this carve-out opens or can close; narrowing the carve-out's text would only
# hide the blessing while the floor keeps allowing the impostor. The carve-out's
# real job is forward-compat stability + explicit blessing of the sanctioned
# shapes (so a future floor rule that DOES match -File/-restart cannot silently
# break the documented lifecycle) -- not gatekeeping the relative path. Closing
# the residual belongs to a floor follow-up, out of scope here.
case "$cmd_lc" in
    'powershell -noprofile -file scripts/setup/cli-proxy-lane.ps1 -restart'|\
    'powershell -noprofile -file scripts/setup/cli-proxy-lane.ps1 -restart -force'|\
    'powershell -noprofile -file scripts/setup/cli-proxy-lane.ps1 -stop'|\
    'powershell -noprofile -file scripts/setup/cli-proxy-lane.ps1 -stop -force'|\
    'powershell -noprofile -file scripts/setup/cli-proxy-lane.ps1 -install -restart'|\
    'powershell -noprofile -file scripts/setup/cli-proxy-lane.ps1 -install -restart -force'|\
    'pwsh -noprofile -file scripts/setup/cli-proxy-lane.ps1 -restart'|\
    'pwsh -noprofile -file scripts/setup/cli-proxy-lane.ps1 -restart -force'|\
    'pwsh -noprofile -file scripts/setup/cli-proxy-lane.ps1 -stop'|\
    'pwsh -noprofile -file scripts/setup/cli-proxy-lane.ps1 -stop -force'|\
    'pwsh -noprofile -file scripts/setup/cli-proxy-lane.ps1 -install -restart'|\
    'pwsh -noprofile -file scripts/setup/cli-proxy-lane.ps1 -install -restart -force')
        exit 0
        ;;
esac

# Binary boundary helpers are inlined in the patterns below. Every binary atom
# that parity_guard names tolerates an optional .exe suffix for the Windows lane.
# Bare-name atoms (format/schtasks/taskkill/shutdown/icacls classes) anchor to
# COMMAND POSITION - start of command or right after a separator, tolerating
# whitespace, env-var assignment prefixes, and a BOUNDED set
# of launcher wrappers - sudo, env, cmd [/switches] /c, powershell/pwsh
# [-flags] -c/-command - plus
# one optional quote before the atom (a quoted word in command position still
# executes) and (CR r2) a bounded EXECUTABLE-PATH prefix - optional Windows
# drive + path segments ending in "/" or "\" - so /sbin/<name>, ./<name>, and
# drive-qualified <name>.exe forms (quoted or not) are refused like the bare
# name. The exe-path prefix also applies before each WRAPPER token (CR r4),
# so /usr/bin/env <name>, /usr/bin/sudo <name>, and a path-qualified
# cmd.exe /c are refused like the bare-wrapper forms. sudo/env tolerate their
# own flag runs (CR r6: sudo -n, env -i), each flag may optionally consume one
# following non-dash value token (CR r7: sudo -u root, env -u PATH - generic,
# no per-option table; over-consumes at worst one benign token, never a
# bypass), and env also tolerates assignment arguments (env -i foo=bar
# shutdown). The bare word inside an argument
# (git log --pretty=format:, grep -rn format src/, echo shutdown) still does
# not match, and the atoms' trailing boundary keeps format-table-style
# basenames allowed. Deliberately NOT a general shell parser - the RESIDUAL
# documented gap is QUOTED-PAYLOAD wrappers (bash -c "<verb> ...", sh -c,
# xargs / nohup chains), out of scope per the ticket's no-general-parser rule.
# This bounded grammar is intentionally NOT an arms race: further wrapper
# permutations belong to the shared-tokenizer follow-up, and this
# CC-hook + the auto-mode classifier remain the outer defense layers. Mirrors
# parity_guard.py's _cmdpos_destructive (shared contract).
# Assignment VALUE is quote-aware (CR r5): FOO='a b' / FOO="a b" would
# otherwise break prefix consumption at the space and drop the verb out of
# command position. Factored into ASSIGN so the env-prefix (CR r6) reuses it.
#
# EXEPFX/ASSIGN/CMDPOS themselves now live in
# scripts/guardrails/lib.sh's guard_cmdpos_grammar() — shared with
# block-graphify-egress.sh, which anchors its own atom to command position
# with this same wrapper/assignment tolerance instead of a second hand-rolled
# copy. See that function's docstring for the grammar description; this
# file's history above (CR r1-r7) is the derivation record for it.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../guardrails/lib.sh
# shellcheck disable=SC1091
if ! { [ -r "$SCRIPT_DIR/../guardrails/lib.sh" ] && . "$SCRIPT_DIR/../guardrails/lib.sh"; } 2>/dev/null; then
    echo "block-destructive-commands: cannot source guardrails/lib.sh — refusing to evaluate" >&2
    exit 2
fi
guard_cmdpos_grammar
# An rm that find (-exec/-execdir/-ok/-okdir) or fd (-x/-X/
# --exec/--exec-batch) runs is at command position too.
# The flag is matched wherever it sits, with no check that find or fd launched
# it: it is also the only catch for an rm that a wrapper CMDPOS does not model
# runs (`watch -x rm`, `stdbuf -o0 -ok rm`, `strace -x rm`). Over-deny only.
# An ALLOWLIST is the one exception. A command that is a single
# echo, printf or : with plain words only (no separator, redirect, quote,
# backslash, expansion, glob or brace) runs nothing, so `echo x -exec rm -rf y`
# is text. Add a command word only with a reason it can never execute one.
# ponytail: the bracket classes, `=~` patterns and the HIMMEL-3983/3984/4146/4134
# additions are run on Linux bash 5 only (no macOS bash 3.2 here, Git Bash
# parked), upgrade path: run this suite on a
# macOS station under /bin/bash.
_rmpos_flag='[[:space:]]-(exec|execdir|ok|okdir|x|-exec|-exec-batch)[[:space:]]+'"${CMDPOS_PFX_X}"
_rmpos_text='^[[:space:]]*(echo|printf|:)([[:space:]][^];&|<>(){}`$\"*?[!#~'"'"']*)?$'
if [[ $cmd_lc =~ $_rmpos_text ]]; then
    RMPOS="(${CMDPOS})"
else
    RMPOS="(${CMDPOS}|${_rmpos_flag})"
fi
# `find -delete` is a recursive delete of its own. The gap is
# unbounded, like RM_RECURSIVE_PAT's, so a quoted `;` cannot hide the flag.
# The mass-delete family (find -delete, find/fd running rm,
# xargs running rm) also sees through the launchers CMDPOS leaves out:
# busybox, command [-p|--|-v ...], eval, and a shell's -c (bash/sh/dash/zsh/
# ksh/mksh/ash/fish, own flags first: `bash -o pipefail -c`). The quoted
# payload is read as text, so `bash -c 'find d -delete'` matches like the bare
# form. Over-deny only: `command -v find; ls -delete` denies.
# parity_guard.py's _X_WRAPS is the twin.
# ponytail: (HIMMEL-912) this widening covers the mass-delete family only, not the
# CMDPOS atoms (`bash -c 'rm -rf d'` still passes this hook, the Python twin
# denies it), upgrade path a word-level tokenizer.
# Every head here takes an optional .exe, and xargs.exe joins lib.sh's xargs
# (which has no .exe), with the same flags.
_xwrap='(busybox(\.exe)?|command(\.exe)?([[:space:]]+-[-[:alnum:]]*)*|eval(\.exe)?|xargs\.exe([[:space:]]+(-[adeilnps]'"${CMDVAL}"'|--[admp][a-z-]*'"${CMDVAL}"'|'"${CMDFLG}"'))*|((ba|da|k|mk|z|a)?sh|fish)(\.exe)?([[:space:]]+'"${CMDFLG}"'('"${CMDVAL}"')?)*[[:space:]]+-[[:alnum:]]*c[[:alnum:]]*)[[:space:]]+'
# No `(` or `){` anchor follows these prefixes (the -exec/-x flag,
# a launcher word), so they keep lib.sh's CMDPOS_PFX_X, whose path run crosses
# `(` and `){`; the stop-at-paren EXEPFX is sound only behind a CMDPOS anchor.
MASS_PFX="${CMDPOS_PFX_X}(${_xwrap}${CMDPOS_PFX_X})*"
MASS_CMDPOS="${CMDPOS}(${_xwrap}${CMDPOS_PFX_X})*"
# The old single pattern (CMDPOS find .* -delete) was quadratic,
# about 22s on a 100 KB command of `; find x` words. _find_delete cuts the
# text at its LAST -delete flag with a glob (linear) and looks for a
# command-position find in what is before it, which is the same set: any find
# before any -delete is before the last one.
FIND_VERB_PAT="${MASS_CMDPOS}"'find(\.exe)?[[:space:]]'
_find_delete() {
    local s=$1 pre
    if [[ $s == *[[:space:]]-delete ]]; then
        pre=${s%-delete}
    else
        pre=${s%[[:space:]]-delete[![:alnum:]_-]*}
        [ "${#pre}" -lt "${#s}" ] || return 1
        pre="$pre "
    fi
    [[ $pre =~ $FIND_VERB_PAT ]]
}
# An rm that find (-exec/-execdir/-ok/-okdir) or fd (-x/-X/
# --exec/--exec-batch) runs deletes every match, so it denies with or without
# -r. Like _rmpos_flag, the flag is not tied to find or fd: over-deny only
# (`grep -x rm f` denies), and the echo/printf allowlist skips it.
FIND_RM_PAT='[[:space:]]-(exec|execdir|ok|okdir|x|-exec|-exec-batch)[[:space:]]+'"${MASS_PFX}"'rm(\.exe)?([^[:alnum:]_.-]|$)'
# So does an rm that xargs runs (`ls | xargs -0 rm`), with
# xargs's own options and any launcher between them.
XARGS_RM_PAT="${MASS_CMDPOS}"'xargs(\.exe)?([[:space:]]+(-[adeilnps]'"${CMDVAL}"'|--[admp][a-z-]*'"${CMDVAL}"'|'"${CMDFLG}"'))*[[:space:]]+'"${MASS_PFX}"'rm(\.exe)?([^[:alnum:]_.-]|$)'
# The three rm checks below run against rm_scrub, not cmd_lc.
# The old anchor was a bare word boundary `(^|[^[:alnum:]_.-])`, which matches
# the literal ANYWHERE in the command string, not just where a command is
# actually invoked - reproduced by a grep/sed PATTERN argument that happens to
# contain the literal (03B console, 2026-09-08) and by a heredoc BODY being
# WRITTEN, not executed (N84, same day). Swapping to ${CMDPOS} (the same
# command-position grammar every other atom in this file already uses) closes
# the pattern-argument case for free: a bare pattern/string argument has no
# `|;&(` (or backtick) char sitting in front of the literal, so ${CMDPOS}
# simply never matches inside one - no scrubbing needed there.
# A heredoc body needs one more step: cmd_lc's own newline-fold (line ~110,
# real newlines -> ';') turns an ordinary line break INSIDE the body into what
# looks exactly like a real command separator right in front of the literal
# (e.g. a body of "note:\nrm -rf x" folds to ";note:;rm -rf x", and the ';'
# before "rm" now satisfies ${CMDPOS} even though nothing was ever run). So
# rm_scrub additionally has heredoc bodies (`<<[-]?['"]?WORD['"]?` up to a
# standalone `;WORD(;|$)` terminator) removed on a COPY before the ${CMDPOS}
# checks run - in-process string ops only, no forks, gated
# behind a cheap `*<<*` substring test so the zero-heredoc common case pays
# nothing extra. FAIL-CLOSED: an unterminated heredoc (no matching `;WORD`
# found) stops stripping and rm_scrub falls back to the UNSTRIPPED cmd_lc for
# that command - a determined bypass gets a false DENY here, never a false
# ALLOW. Budget-capped (8 heredocs) for the same reason.
# RESIDUAL (measured, not chased - same no-general-parser rule as
# the rest of this file): a heredoc fed to an INTERPRETER whose body is
# actually executed (`bash <<'EOF'` / `python3 <<'EOF'` containing a real
# `rm -rf` line) is now allowed exactly like a `cat <<'EOF' > file` body is -
# this rule cannot tell "body becomes a file" from "body becomes a script"
# without knowing the target command, and the ticket asks for heredoc bodies
# excluded unconditionally. A quoted STRING containing a literal separator
# char (`;`/`&`/`|`/`(`/backtick) immediately before the literal, e.g.
# `echo "a; rm -rf x"`, is likewise not scrubbed - out of the ticket's
# reproduced cases, and the earlier attempt to strip quoted spans generically
# broke the `rm "-rf" file` quoted-flag DENY case below, which must
# keep denying (quoting a flag doesn't change what runs).
# Only a QUOTED delimiter (`<<'EOF'`/`<<"EOF"`) guarantees the shell performs
# no expansion while building the body - an UNQUOTED delimiter's body still
# undergoes command substitution, so `cat <<EOF` containing `$(rm -rf x)`
# stays unstripped and falls through to the ${CMDPOS} match below.
# This scrub also works off
# `cmd` (real newlines intact), not `cmd_lc` (newlines already folded to `;`,
# indistinguishable from a real semicolon) - stripping must start only after
# the true newline that begins the body, never right after the opener token,
# or a real command on the OPENER's own line (`cat <<EOF; rm -rf x`) gets
# swallowed into the discarded span (same panel round).
#
# The header above already documented this as gated behind a
# cheap `*<<*` test, but only the STRIPPING LOOP was actually gated - the
# `printf | tr | tr` pipeline that builds rm_scrub_raw ran unconditionally,
# paying 3 forks on every zero-heredoc call (the common case). `<<` survives
# both the case fold and the CR/LF fold, so testing for it on cmd_lc (already
# computed, zero extra cost) is equivalent to testing cmd. When absent, skip
# the pipeline entirely: cmd_lc already IS what rm_scrub_raw's newline-fold
# would produce here - cmd_lc's single `tr` maps upper->lower and `\n`/`\r`
# each independently to `;` in one pass, while rm_scrub_raw's two `tr` calls
# map `\r`->`\n` then upper->lower before rm_scrub folds the (now all-`\n`)
# newlines to `;` - lowering and separator-folding commute, so both paths
# produce the same byte string when there is no heredoc to strip.
#
# The per-line check below misses a quote opened on an EARLIER
# line - the opener is then quoted text and the "body" lines run. Before
# stripping, _hd_carried_clean walks everything before the opener and returns
# 0 only when it ends outside any quote or comment. It models ', ", \, and a
# word-initial # well enough to be exact on plain text, and returns 1 (do not
# strip, scan everything) on whatever it does not model: a backtick, $'...',
# ${ or $( inside "...", a # after < > or ), an earlier heredoc whose body is
# data (any <<, or an @@ mask other than a here-string's <@@), and a lone CR
# in $cmd (bash reads it as a character; here it is already a newline). It
# only ever disqualifies, so it can never strip more than before.
# An unquoted ${, $(( or $[ is skipped to its closer only when
# it closes before any quote, backslash, $, backtick, # or newline (every
# character the N state acts on, so the skip never walks past one: zsh reads
# `$((true)#)` as a subshell plus a comment); one left open (or holding any of
# those) returns 1, as does a $[ inside "...".
_hd_carried_clean() {
    local s=$1 i=0 n st=N c p=$'\n' o cl d
    s="${s//<<</}"
    s="${s//<@@/}"
    case $s in *'<<'*|*'@@'*|*'`'*) return 1 ;; esac
    [[ $s == *[\'\"\$]* ]] || return 0
    [ -z "$_hd_lone_cr" ] || return 1
    n=${#s}
    while [ "$i" -lt "$n" ]; do
        c=${s:i:1}
        case $st in
            N)
                case $c in
                    # A \-newline is removed, so what came before it still
                    # decides whether a following # starts a comment.
                    \\) [ "${s:i+1:1}" = $'\n' ] && c=$p; i=$((i + 1)) ;;
                    \') [ "$p" = '$' ] && return 1; st=S ;;
                    \") st=D ;;
                    '$')
                        o=${s:i+1:1}
                        case $o in
                            '{'*) cl='}' ;;
                            '['*) cl=']' ;;
                            '('*) [ "${s:i+2:1}" = '(' ] && cl=')' || o= ;;
                            *) o= ;;
                        esac
                        if [ -n "$o" ]; then
                            d=0
                            i=$((i + 1))
                            while [ "$i" -lt "$n" ]; do
                                c=${s:i:1}
                                case $c in
                                    "$o") d=$((d + 1)) ;;
                                    "$cl") d=$((d - 1)); [ "$d" -eq 0 ] && break ;;
                                    [\'\"\\\$\`\#]|$'\n') return 1 ;;
                                esac
                                i=$((i + 1))
                            done
                            [ "$d" -eq 0 ] || return 1
                        fi
                        ;;
                    \#)
                        case $p in
                            [[:space:]]|';'|'&'|'|'|'(') st=C ;;
                            '<'|'>'|')') return 1 ;;
                        esac
                        ;;
                esac
                ;;
            S) [ "$c" = "'" ] && st=N ;;
            D)
                case $c in
                    \\) i=$((i + 1)) ;;
                    \") st=N ;;
                    '$') case ${s:i+1:1} in '('|'{'|'[') return 1 ;; esac ;;
                esac
                ;;
            C) [ "$c" = $'\n' ] && st=N ;;
        esac
        p=$c
        i=$((i + 1))
    done
    [ "$st" = N ]
}
if [[ $cmd_lc != *'<<'* ]]; then
    rm_scrub="$cmd_lc"
else
rm_scrub_raw=$(printf '%s' "$cmd" | LC_ALL=C tr '\r' '\n' | LC_ALL=C tr '[:upper:]' '[:lower:]')
if [[ $rm_scrub_raw == *'<<'* ]]; then
    _hd_lone_cr=
    _hd_nocrlf="${cmd//$'\r\n'/}"
    [[ $_hd_nocrlf == *$'\r'* ]] && _hd_lone_cr=1
    # _hd_find_term: 0 when _hd_body holds the terminator _hd_termpat names,
    # with _hd_after = the text after it. The terminator is a
    # literal (\n, tabs and the delimiter word), so a byte-wise match under a
    # function-local LC_ALL=C finds exactly what the UTF-8 one did; in a UTF-8
    # locale the regex took 0.6 s on a 45 KB body, and `#*MATCH` is quadratic
    # in the text before it, so the rest is taken by offset instead.
    _hd_find_term() {
        local LC_ALL=C _hd_m _hd_pre
        [[ $_hd_body =~ $_hd_termpat ]] || return 1
        _hd_m="${BASH_REMATCH[0]}"
        _hd_pre="${_hd_body%%"$_hd_m"*}"
        _hd_after="${_hd_body:${#_hd_pre}+${#_hd_m}}"
    }
    # Strips rm_scrub_raw in place. With _hd_check_carried set it also applies
    # the carried-quote disqualifier and sets _hd_carried_hit when that fires.
    _hd_strip() {
    _hd_budget=8
    while [ "$_hd_budget" -gt 0 ] && [[ $rm_scrub_raw == *'<<'* ]]; do
        _hd_budget=$((_hd_budget - 1))
        _hd_qpat="<<(-)?[[:space:]]*'([[:alnum:]_]+)'"
        _hd_dpat='<<(-)?[[:space:]]*"([[:alnum:]_]+)"'
        if [[ $rm_scrub_raw =~ $_hd_qpat ]] || [[ $rm_scrub_raw =~ $_hd_dpat ]]; then
            _hd_dash="${BASH_REMATCH[1]}"
            _hd_word="${BASH_REMATCH[2]}"
            _hd_opener="${BASH_REMATCH[0]}"
        else
            break
        fi
        _hd_prefix="${rm_scrub_raw%%"$_hd_opener"*}"
        # rm_scrub_raw is exactly prefix + opener + rest, so the rest is taken
        # by offset: `${rm_scrub_raw#"$_hd_prefix"...}` matched the prefix as a
        # pattern, quadratic in its length (seconds at 90 KB; J1664 note 2).
        # A third `<` right before this match means the "<<" matched here is
        # actually the tail of a `<<<` here-string operator, not a heredoc
        # redirect. Bash never reads a body for `<<<` - its whole "value" is
        # the word/string on the SAME line - so treating what follows as a
        # scannable heredoc body can splice a real, sequentially-executed
        # command out of the string entirely whenever a later line happens to
        # equal the here-string's word. Disqualify with the same
        # mask-and-continue mechanism as the mid-quote/comment cases below.
        if [[ $_hd_prefix == *'<' ]]; then
            rm_scrub_raw="${_hd_prefix}@@${_hd_opener:2}${rm_scrub_raw:${#_hd_prefix}+${#_hd_opener}}"
            continue
        fi
        # An opener sitting inside an OPEN quote on its own physical line is
        # DATA inside a quoted argument (`echo "text <<'EOF'"`), not a
        # redirect operator - a real heredoc redirect is never written
        # mid-quote. Checking only the character immediately before `<<`
        # would miss a quote opened earlier on the same line, with text
        # between it and the `<<`, and a real `rm -rf` on the next line would
        # hide the same way. So count quote chars on the CURRENT line (since
        # the last real newline) before the opener - an odd count of either
        # quote char means we are still inside that quote, so the opener is
        # data.
        # Same direction for a `#` earlier on the line: once a shell comment starts, the rest
        # of the physical line - opener syntax included - is comment text, not
        # a real redirect, and every line after it runs as ORDINARY commands,
        # not heredoc body, so stripping them would hide whatever real command
        # is actually there. Not attempting to tell whether the `#` is itself
        # quoted (that is the general-tokenizer line this file refuses to
        # cross) - any `#` on the opener's line is treated as disqualifying,
        # which only ever makes this MORE conservative (leaves more text
        # unstripped, never less).
        # Either way, mask just this occurrence's `<<` so it cannot match
        # again, leaving the rest of the string - including any real command
        # on the following lines - completely UNSTRIPPED, so it still falls
        # through to the ${CMDPOS} match below (fail-closed, same direction as
        # the unterminated-heredoc case above).
        _hd_line_prefix="${_hd_prefix##*$'\n'}"
        _c_keep_char "$_hd_line_prefix" "'"; _hd_sq=$REPLY
        _c_keep_char "$_hd_line_prefix" '"'; _hd_dq=$REPLY
        _c_keep_char "$_hd_line_prefix" '#'; _hd_hash=$REPLY
        if (( ${#_hd_sq} % 2 == 1 || ${#_hd_dq} % 2 == 1 )) || [[ -n $_hd_hash ]] ||
            { [ -n "$_hd_check_carried" ] && ! _hd_carried_clean "$_hd_prefix" && _hd_carried_hit=1; }; then
            rm_scrub_raw="${_hd_prefix}@@${_hd_opener:2}${rm_scrub_raw:${#_hd_prefix}+${#_hd_opener}}"
            continue
        fi
        _hd_tail="${rm_scrub_raw:${#_hd_prefix}+${#_hd_opener}}"
        # Bash joins a backslash-newline on the
        # opener line before it reads the body, so `cat <<'EOF' \<NL>/dev/null`
        # starts its body a line later. Join first, or the strip below takes
        # `/dev/null` as the body and ends on the wrong line, hiding what
        # follows. Only an odd trailing backslash run continues the line; `\\`
        # is an escaped one. Bash reads `\`+CR as an escaped CR, not a
        # continuation, and `\r` is already `\n` here, so with any `\`+CR in
        # the command a join is unsafe: fail closed.
        while [[ $_hd_tail == *$'\n'* ]]; do
            _hd_l="${_hd_tail%%$'\n'*}"
            _hd_bs="${_hd_l##*[!\\]}"
            (( ${#_hd_bs} % 2 == 1 )) || break
            # Inside a comment or quote a trailing backslash may be no
            # continuation; rather than model that, strip nothing more and
            # scan the rest as-is (fail closed).
            [[ $_hd_l == *[\#\'\"\`]* ]] && break 2
            [[ $cmd == *$'\\\r'* ]] && break 2
            _hd_rest="${_hd_tail#*$'\n'}"
            _hd_tail="${_hd_l%\\}${_hd_rest}"
        done
        if [[ $_hd_tail != *$'\n'* ]]; then
            break
        fi
        _hd_openerline_rest="${_hd_tail%%$'\n'*}"
        _hd_body="${_hd_tail#*$'\n'}"
        # `<<-` also lets bash accept a terminator line indented with leading
        # TAB characters (stripped before the delimiter-word comparison, per
        # `<<-` semantics) - without this, a legitimately tab-indented
        # terminator on a `<<-` heredoc is never found, and a benign body gets
        # a false DENY via the fail-closed unstripped-string fallback below.
        # A plain `<<` delimiter gets no such tolerance: bash
        # itself requires the terminator flush-left there, so a tab-indented
        # terminator leaves the heredoc genuinely unterminated and the
        # fail-closed path is correct.
        if [[ -n $_hd_dash ]]; then
            _hd_termpat=$'(^|\n)\t*'"$_hd_word"$'($|\n)'
        else
            _hd_termpat=$'(^|\n)'"$_hd_word"$'($|\n)'
        fi
        if _hd_find_term; then
            rm_scrub_raw="${_hd_prefix} ${_hd_openerline_rest}"$'\n'"${_hd_after}"
        else
            break
        fi
    done
    }
    # J1664: the disqualifier masks an opener main stripped, and a later
    # heredoc can then take lines main scanned. When it fired, also scan
    # main's strip of the same text, so the head never allows what main
    # refused. The `;` line keeps the two copies apart through the join.
    _hd_in="$rm_scrub_raw" _hd_check_carried=1 _hd_carried_hit=
    _hd_strip
    if [ -n "$_hd_carried_hit" ]; then
        _hd_head="$rm_scrub_raw" rm_scrub_raw="$_hd_in" _hd_check_carried=
        _hd_strip
        rm_scrub_raw="${_hd_head}"$'\n;\n'"${rm_scrub_raw}"
    fi
fi
rm_scrub="${rm_scrub_raw//$'\n'/;}"
fi
# Separator before the flag tolerates a real space OR a lowercased ${IFS}
# token (a common word-split bypass), and the flag itself tolerates one
# leading quote char - both `-rf` and `"-rf"`/`'-rf'` trip it.
RM_R_PAT="${RMPOS}"'rm(\.exe)?([^[:alnum:]_.-][^|;&]*)?([[:space:]]|\$\{ifs\})['\''"]?-[[:alnum:]_]*r'
if [[ $rm_scrub =~ $RM_R_PAT ]]; then
    deny "recursive rm"
fi
# `--recursive` is the only GNU rm long option starting with
# `r` (force/interactive/one-file-system/no-preserve-root/preserve-root/dir/
# verbose/help/version all start elsewhere), so getopt_long accepts any
# unambiguous prefix from `--r` up - `--rec`, `--recu`, etc. all spell
# --recursive and must trip this the same as the full word.
RM_RECURSIVE_PAT="${RMPOS}"'rm(\.exe)?([^[:alnum:]_.-]|$).*--r[a-z-]*([^[:alnum:]_-]|$)'
# Trigger only: a long `--r...` word anywhere after `rm`. The unbounded gap
# may span a quoted `;`, a substitution or a later command, so on its own it
# is not a verdict. The verdict is the argv walk (_rm_inv, after the git walk):
# the word must be an option of an rm invocation, before `--`. Text the
# tokenizer cannot read keeps the deny.
_rm_long_hit=0
if [[ $rm_scrub =~ $RM_RECURSIVE_PAT ]]; then
    _rm_long_hit=1
fi
# The literal `-r`/`--r` scans above never see a flag the shell
# only assembles at parse time (`rm -"r" d`, `rm -f"r" d`, `rm "--"recursive d`,
# `rm -\r d`, `rm -$'r' d`, `command rm -r d`). Normalise instead of adding
# spellings: strip every quote and backslash (the shell would drop them) and a
# `command` wrapper, then run the same two flag scans on the result. A `$`
# glued to a quote (`$'-r'`, `$"-r"`) is dropped with it, so a word the quoting
# starts (`rm $'-r' d`) normalises to `-r`; a `$` the shell cannot resolve
# (`rm -$x`) stays in an option word and denies. An ANSI-C string holding a
# backslash (`$'\x2dr'`, `$'\055r'`) is unresolvable and denies outright.
# Over-deny only: `rm -- -r` (a file literally named -r) and
# `rm "my -r file"` deny - the fix needs a word-level tokenizer.
# rm_scrub has the continuation newline folded to `;`, so
# `rm \<NL>-"r" d` ends the rm segment before the quoted flag. Run the scans
# below on a joined copy too (see cmd_lc_join). With a heredoc, the copy is
# joined after the body strip, where `\r` is already `\n`, so a CRLF
# continuation arrives there as `\`+LF+LF and is dropped as that pair.
rm_join="$rm_scrub"
if [[ $cmd_lc_join != "$cmd_lc" ]]; then
    if [[ $cmd_lc != *'<<'* ]]; then
        rm_join="$cmd_lc_join"
    else
        rm_join="$rm_scrub_raw"
        [[ $cmd == *"$_bscrlf"* ]] && rm_join="${rm_join//"$_bsnl"$'\n'/}"
        rm_join="${rm_join//"$_bsnl"/}"
        rm_join="${rm_join//$'\n'/;}"
    fi
fi
_rm_srcs=("$rm_scrub")
[[ $rm_join != "$rm_scrub" ]] && _rm_srcs+=("$rm_join")
# An empty expansion before the rm word (see cmd_lc_noexp).
if [[ $rm_join == *'$'* ]]; then
    _noexp_strip "$rm_join"
    [ "$_noexp_over" = 0 ] || deny "more than 256 expansions at command position"
    [[ $REPLY == "$rm_join" ]] || _rm_srcs+=("$REPLY")
fi
_sq="'"
RM_ANSIC_ESC_PAT="(^|[^[:alnum:]_.-])rm(\\.exe)?([^|;&]*)\\\$${_sq}[^${_sq}]*\\\\"
RM_OPT_DOLLAR_PAT="${RMPOS}"'rm(\.exe)?([^[:alnum:]_.-][^|;&]*)?([[:space:]]|\$\{ifs\})-[^[:space:]|;&]*\$'
for _rm_src in "${_rm_srcs[@]}"; do
if [[ $_rm_src =~ $RM_ANSIC_ESC_PAT ]]; then
    deny "recursive rm (ANSI-C escape in rm argument)"
fi
rm_norm="${_rm_src//\$[\"\']/}"
_c_strip_quotes "$rm_norm"; rm_norm=$REPLY
rm_norm="${rm_norm//$'\t'/ }"
while [[ $rm_norm == *'  '* ]]; do rm_norm="${rm_norm//  / }"; done
# `command` plus any option run (`-p`, `--`, `-p --`) before rm: drop the wrapper.
_cmd_pat='command( -[-[:alnum:]]*)* rm'
_cmd_n=8
while (( _cmd_n-- > 0 )) && [[ $rm_norm =~ $_cmd_pat ]]; do
    rm_norm="${rm_norm/"${BASH_REMATCH[0]}"/rm}"
done
if [[ $rm_norm =~ $RM_R_PAT ]] || [[ $rm_norm =~ $RM_OPT_DOLLAR_PAT ]]; then
    deny "recursive rm (quote/escape-normalised)"
fi
if [[ $rm_norm =~ $RM_RECURSIVE_PAT ]]; then _rm_long_hit=1; fi
# rm_norm splits a quoted wrapper value (`nice -n '1 0' find`)
# into two words, so also read the text with its quotes kept.
if _find_delete "$rm_norm" || _find_delete "$_rm_src"; then
    deny "recursive delete (find -delete)"
fi
if [[ ! $cmd_lc =~ $_rmpos_text ]] && { [[ $rm_norm =~ $FIND_RM_PAT ]] || [[ $_rm_src =~ $FIND_RM_PAT ]]; }; then
    deny "mass delete (find/fd running rm)"
fi
# The glob is a cheap pre-check (the pattern needs both words in this order,
# and rm_norm only drops characters, so it holds every word _rm_src does):
# CMDPOS is slow on long `((` runs.
if [[ $rm_norm == *xargs*rm* ]] && { [[ $rm_norm =~ $XARGS_RM_PAT ]] || [[ $_rm_src =~ $XARGS_RM_PAT ]]; }; then
    deny "mass delete (xargs rm)"
fi
done
# Backslash-newline continuation: newlines are already folded to ';' above, so
# `rm \<newline>-rf` becomes `rm \;-rf` here - the literal backslash before the
# folded separator is the tell. `;+` (not a single `;`): on
# Windows, jq's text-mode stdout turns the JSON-decoded `\n` into `\r\n`, so
# ONE real newline folds to TWO semicolons here - tolerate either.
RM_CONT_PAT="${RMPOS}"'rm(\.exe)?[[:space:]]*\\[[:space:]]*;+[[:space:]]*-[[:alnum:]_]*r'
for _rm_src in "${_rm_srcs[@]}"; do
if [[ $_rm_src =~ $RM_CONT_PAT ]]; then
    deny "recursive rm (line continuation)"
fi
done
# /s is bound to the switch (space/another switch/end), not a path prefix -
# `rd /scripts` must not false-trip on the "/s" substring.
if contains '(^|[^[:alnum:]_.-])(del|erase|rd|rmdir)(\.exe)?([^[:alnum:]_.-]|$)[^|;&]*/s([^[:alnum:]_.-]|$)'; then
    deny "recursive Windows delete"
fi
# mkfs keeps no trailing boundary (parity: \bmkfs) so mkfs.ext4 still matches.
if contains "${CMDPOS}"'((format|diskpart|bcdedit)(\.exe)?([^[:alnum:]_.-]|$)|mkfs)'; then
    deny "disk/boot mutation"
fi
if contains '(^|[^[:alnum:]_.-])cipher(\.exe)?[[:space:]]+/w'; then
    deny "disk wipe"
fi
# Verb split: schtasks /query is read-only (the diagnostic the
# clip-pipe cadence investigation was blocked from running), so only the
# mutating verbs are refused — /query and help/no-verb forms stay allowed.
# Mirrors parity_guard.py's schtasks line (lockstep).
if contains "${CMDPOS}"'schtasks(\.exe)?[[:space:]]+(/create|/change|/delete|/end|/run|/config)([^[:alnum:]_.-]|$)'; then
    deny "scheduled-task mutation"
fi
# The same CAPABILITY is reachable without schtasks.exe - the
# PowerShell ScheduledTasks module drives the Task Scheduler COM API directly,
# so guarding one spelling guards nothing. Recognise the invoked-program token.
# The read/write split is preserved by
# omission: get-scheduledtask / get-scheduledtaskinfo / export-scheduledtask
# are NOT in the verb list and stay allowed as diagnostics. The trailing
# boundary keeps the object-BUILDER cmdlets allowed - new-scheduledtask and
# new-scheduledtasktrigger/-action/-principal/-settingsset only construct an
# in-memory definition; the register/set that consumes it is what mutates, and
# that is refused here. `pwsh -Command "Register-ScheduledTask ..."` is covered
# by CMDPOS's powershell/pwsh -c wrapper + optional-quote tolerance, and the
# module-qualified form (`ScheduledTasks\Register-ScheduledTask`) by CMDPOS's
# executable-path prefix - both pinned in the suite (CR r1). The second
# `contains` adds a script-block anchor `{` on top of CMDPOS, so
# `ForEach-Object { Register-ScheduledTask ... }` is refused (CR r8). It is a
# LOCAL widening on purpose: `{` cannot go into the SHARED CMDPOS without
# refusing `jq '{format: .x}'`, but no jq/JSON key is spelled
# `<verb>-scheduledtask`, so here it costs nothing.
# Mirrors parity_guard.py's ScheduledTasks line (lockstep).
SCHEDVERBS='(register|unregister|set|start|stop|disable|enable)-scheduledtask([^[:alnum:]_.-]|$)'
if contains "${CMDPOS}${SCHEDVERBS}" \
    || contains '(^|[{])[[:space:]]*["'\'']?'"${SCHEDVERBS}"; then
    deny "scheduled-task mutation"
fi
# Raw COM route: New-Object -ComObject Schedule.Service. Anchored to the
# -ComObject ARGUMENT rather than command position, because the idiomatic form
# is an assignment (`$svc = New-Object -ComObject Schedule.Service`) that no
# command-position anchor sees. PowerShell resolves unambiguous parameter
# PREFIXES, and New-Object has no other -c* parameter, so `-c` / `-com` /
# `-comobj` all bind to -ComObject: the flag is matched as `-c<word>` rather
# than the full spelling (CR r1). That prefix alone is far too loose, so it is
# scoped to a preceding `new-object` on the SAME command (the separator class
# stops the run at |;&) - otherwise `grep -c Schedule.Service docs/` would be
# denied (CR r2). `new-object` itself takes the usual command-position anchor
# WIDENED by `=`, because the idiomatic PowerShell form is an assignment
# (`$svc = New-Object ...`) that the shared CMDPOS assignment prefix does not
# recognise; that keeps `grep -n "New-Object -ComObject Schedule.Service" f`
# allowed, which someone editing THIS file will type (CR r3). CR r7 tuned both
# ends of that anchor: a quote may NOT sit between the anchor and `new-object`
# (`$s = "New-Object -ComObject Schedule.Service"` is a string assignment, not
# an invocation), while the progid tolerates leading `(`/quotes so the
# parenthesised expression form `-ComObject ('Schedule.Service')` is refused.
#
# RESIDUAL - these defeat the scheduled-task rules
# exactly as they already defeat every other atom in this file, measured, not
# assumed: `ForEach-Object { schtasks /create ... }`, `ForEach-Object
# { shutdown ... }` and `x=schtasks; $x /create` are all rc=0 today. They are
# the shared no-general-parser limit, NOT something these rules introduced:
#   * brace script blocks, for the SHARED atoms only - the two scheduled-task
#     rules above now carry a local `{` anchor (CR r8), but `{` cannot go into
#     the shared CMDPOS without refusing `jq '{format: .x}'` and
#     `jq '{shutdown: 1}'`, so `ForEach-Object { schtasks /create }` and
#     `{ shutdown }` stay allowed exactly as they were before this change.
#   * string indirection - `$p = "Schedule.Service"; New-Object -ComObject $p`.
#   * backtick line continuation inside a single command.
#   * the reflective progid route - `[Activator]::CreateInstance(
#     [Type]::GetTypeFromProgID("Schedule.Service"))`. A literal-spelling match
#     for it was tried and REMOVED (CR r5): one variable assignment defeats it,
#     so it only ever caught the naive form, while denying a plain
#     `grep 'GetTypeFromProgID("Schedule.Service")' docs/` - a false positive
#     bought nothing.
# A tokenizer closes these, a wider regex does not. The auto-mode
# classifier and parity_guard remain the outer layers.
if contains '(^|[|;&(={`])[[:space:]]*new-object[^|;&]*-c[[:alnum:]]*[[:space:]]*[:=]?[[:space:]]*[("'\'']*schedule\.service([^[:alnum:]_.-]|$)'; then
    deny "scheduled-task mutation (com)"
fi
if contains "${CMDPOS}"'(taskkill|stop-process|pskill)(\.exe)?([^[:alnum:]_.-]|$)'; then
    deny "process termination"
fi
if contains '(^|[^[:alnum:]_.-])kill(\.exe)?[[:space:]]+-9'; then
    deny "process termination"
fi
if contains "${CMDPOS}"'(shutdown|reboot|logoff)(\.exe)?([^[:alnum:]_.-]|$)'; then
    deny "system shutdown"
fi
if contains '(^|[^[:alnum:]_.-])reg(\.exe)?[[:space:]]+(add|delete)([[:space:]]|$)'; then
    deny "registry mutation"
fi
if contains "${CMDPOS}"'(icacls|takeown)(\.exe)?([^[:alnum:]_.-]|$)'; then
    deny "permission mutation"
fi
# Resolve the repo's default branch (main/master, occasionally
# something else) so the lease carve-out below can tell an explicit non-default
# branch from a protected one. Empty output on any failure (no origin,
# detached, not a repo) -- the caller always keeps main/master as a floor.
git_default_branch() {
    local ref
    ref=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null) || return 1
    # Strip the fixed prefix, not
    # everything up to the LAST slash -- a default branch containing its own
    # slash (e.g. `release/stable`) was reduced to just `stable`, so the
    # actual default never matched $protected.
    printf '%s' "${ref#refs/remotes/origin/}" | LC_ALL=C tr '[:upper:]' '[:lower:]'
}

# Every git invocation is judged on its argv as the shared
# tokenizer reads it (guard-unwrap.sh sourced shell-tokenize.sh above), never
# by regexes over flattened text, which kept missing a spelling: a quoted `$(…)` as -C's value,
# an apostrophe in a comment pairing with one on a later line.
#
# The walk: each segment's words join the logical command they belong to; a
# `$(…)`, backtick or process substitution is a placeholder word in its parent
# and a command of its own. Every word whose basename is git starts an
# invocation. Its global options are skipped by git's own grammar, then the
# subcommand's argv meets the deny rules. A word the hook cannot know (a
# substitution, a $-expansion, a glob, an empty word, an unknown option, an
# alias from -c) in a global-option or subcommand position leaves the
# invocation UNRESOLVED: its remaining words are read as text and any
# destructive marker denies. A command word that is only an expansion
# (`$(which git)`, "$GIT") is unresolved the same way. A --config-env alias
# is refused outright: its body sits in an env var.
#
# Text the tokenizer does not model is retried with `${…}` flattened, then
# with heredoc bodies dropped; past that, each line is tokenized alone or read
# as text after its first git word. A word holding whitespace and "git" (an
# ssh or bash -c payload, a message, an assignment's value that a later `$X`
# runs) is walked as a command too, two levels deep, and so is each raw line
# of a heredoc: the text rules this replaces read both, and the walk keeps
# every deny they gave. A `#` comment is the one thing it no longer reads.
_gp_w='[^a-z0-9_-]'
_gp_re_fb="${_gp_w}filter-branch${_gp_w}"
_gp_re_reset="${_gp_w}reset${_gp_w}"
_gp_re_hard='[[:space:]=]--h'
_gp_re_clean="${_gp_w}clean${_gp_w}"
_gp_re_cforce='[[:space:]]-[a-z0-9]*f|[[:space:]]--f|requireforce'
_gp_re_push="${_gp_w}push${_gp_w}"
_gp_re_pforce='--force|[[:space:]]-[a-z0-9]*f|[[:space:]:=]\+'
_gp_re_text='(^|[^a-z0-9_.-])(git|gh)(\.exe)?([^a-z0-9_-]|$)'
# shellcheck disable=SC2016 # a literal `$` in the ERE, not an expansion
_gp_re_exp='\$(\{[^}]*\}|[a-z_][a-z0-9_]*|[0-9#?*@!$-])'
_gp_prot=' main master '
_gp_prot_done=0

# _gp_protected_set — add the resolved default branch to _gp_prot, once.
_gp_protected_set() {
    local db
    [ "$_gp_prot_done" = 0 ] || return 0
    _gp_prot_done=1
    if db=$(git_default_branch) && [ -n "$db" ]; then _gp_prot="$_gp_prot$db "; fi
    return 0
}

# _gp_unres TEXT — the markers an unresolved invocation is held to.
_gp_unres() {
    local r=" $1 "
    if [[ $r =~ $_gp_re_fb ]]; then deny "git filter-branch"; fi
    if [[ $r =~ $_gp_re_reset ]] && [[ $r =~ $_gp_re_hard ]]; then deny "git reset --hard"; fi
    if [[ $r =~ $_gp_re_clean ]] && [[ $r =~ $_gp_re_cforce ]]; then deny "git clean -f"; fi
    if [[ $r =~ $_gp_re_push ]] && [[ $r =~ $_gp_re_pforce ]]; then deny "force push"; fi
    _gh_unres "$1"
    return 0
}

# _gp_text LINE — a line the tokenizer cannot read: everything after its
# first git word is unresolved.
_gp_text() {
    local t
    _c_strip_quotes "$1"; t=$REPLY
    [[ $t =~ $_gp_re_text ]] || return 0
    _gp_unres "${t#*"${BASH_REMATCH[0]}"}"
}

# _gp_noexp_word WORD — REPLY is WORD with its $-expansions removed; over
# 256 of them denies, like _noexp_strip.
_gp_noexp_word() {
    local s=$1 n=0
    while [[ $s =~ $_gp_re_exp ]]; do
        [ "$n" -lt 256 ] || deny "more than 256 expansions at command position"
        s=${s/"${BASH_REMATCH[0]}"/}
        n=$((n + 1))
    done
    REPLY=$s
}

# _gp_join J — REPLY is words J.. of the current command, space-joined.
_gp_join() {
    local j=$1 r=''
    while [ "$j" -lt "${#_gc_w[@]}" ]; do r="$r ${_gc_w[j]}"; j=$((j + 1)); done
    REPLY=$r
}

_gp_reset() { # J — reset's argv from word J
    local j=$1 w
    while [ "$j" -lt "${#_gc_w[@]}" ]; do
        w=${_gc_w[j]}
        case "$w" in
            --) return 0 ;;
            --h|--ha|--har|--hard) deny "git reset --hard" ;;
        esac
        case "${_gc_k[j]}:$w" in X:*--h*|G:*--h*) deny "git reset --hard" ;; esac
        j=$((j + 1))
    done
    return 0
}

_gp_clean() { # J FORCED — clean's argv from word J; FORCED=1 when -c turned requireForce off
    local j=$1 w
    [ "$2" = 0 ] || deny "git clean -f"
    while [ "$j" -lt "${#_gc_w[@]}" ]; do
        w=${_gc_w[j]}
        case "$w" in
            --) return 0 ;;
            --f|--fo|--for|--forc|--force) deny "git clean -f" ;;
            --*) ;;
            -*f*) deny "git clean -f" ;;
        esac
        j=$((j + 1))
    done
    return 0
}

# _gp_lease_protected — true unless the lease push names origin and only
# explicit branches outside main, master and the default branch. Reads the
# caller's pw (positional words) and pk (their kinds).
_gp_lease_protected() {
    local i=1 b o
    [ "$np" -ge 2 ] || return 0
    [ "${pw[0]}:${pk[0]}" = origin:W ] || return 0
    _gp_protected_set
    while [ "$i" -lt "$np" ]; do
        case "${pk[i]}" in P|X|G) return 0 ;; esac
        # o keeps the name as typed (refs/heads/ only) because a default
        # branch literally named heads/x sits in _gp_prot under that name;
        # b is the git refs/%s shorthand-stripped form. Deny on either.
        o=${pw[i]##*:}; o=${o#+}; o=${o#refs/heads/}
        b=${pw[i]##*:}; b=${b#+}; b=${b#refs/}; b=${b#heads/}
        case "$b" in ''|head|@*|*'*'*|*'$'*|*'`'*) return 0 ;; esac
        case "$_gp_prot" in *" $b "*|*" $o "*) return 0 ;; esac
        i=$((i + 1))
    done
    return 1
}

# _gp_push J OFF — push's argv from word J. OFF=1 when the invocation chose
# its repository (-C, --git-dir, ...) or an assignment preceded it, which the
# lease carve-out cannot follow.
_gp_push() {
    local j=$1 off=$2 w k c f=0 l=0 dd=0 i=1 np=0
    local -a pw=() pk=()
    while [ "$j" -lt "${#_gc_w[@]}" ]; do
        w=${_gc_w[j]} k=${_gc_k[j]}
        if [ "$dd" = 1 ]; then
            pw[np]=$w; pk[np]=$k; np=$((np + 1))
        else
            case "$w" in
                --) dd=1 ;;
                --force|--f|--fo|--for|--forc) f=1 ;;
                --force-w*) l=1 ;;
                # --repo (or its abbreviation --rep) names the remote: every
                # positional word is a refspec.
                --rep|--repo) off=1; i=0; j=$((j + 1)) ;;
                --rep=*|--repo=*) off=1; i=0 ;;
                -o|--push-option|--receive-pack|--exec|--recurse-submodules) j=$((j + 1)) ;;
                --*) ;;
                -*) c=${w#-}; c=${c%%o*}; case "$c" in *f*) f=1 ;; esac ;;
                *) pw[np]=$w; pk[np]=$k; np=$((np + 1)) ;;
            esac
            case "$k:$w" in X:*force*|G:*force*) f=1 ;; esac
        fi
        j=$((j + 1))
    done
    while [ "$i" -lt "$np" ]; do
        # An unresolved refspec may expand to a leading + ("${P:-}+main").
        case "${pk[i]}:${pw[i]}" in *:+*|[PXG]:*+*) f=1 ;; esac
        i=$((i + 1))
    done
    [ "$f" = 0 ] || deny "force push"
    [ "$l" = 1 ] || return 0
    if [ "$off" = 1 ] || [ "$_gp_cd" = 1 ] || [ "${GU_CWD_UNKNOWN:-0}" = 1 ]; then
        deny "force push"
    fi
    if _gp_lease_protected; then deny "force push"; fi
    return 0
}

# _gp_inv J ASSIGNED UNRESOLVED — one git invocation whose first argument is
# word J of the current command.
_gp_inv() {
    local j=$1 off=$2 un=$3 cf=0 w v
    while [ "$un" = 0 ] && [ "$j" -lt "${#_gc_w[@]}" ]; do
        w=${_gc_w[j]}
        case "${_gc_k[j]}" in P|X|G) un=1; break ;; esac
        case "$w" in
            -c|-C|--git-dir|--work-tree|--namespace|--super-prefix|--config-env|--attr-source|--shallow-file)
                # A -c key the push target does not depend on (core.pager,
                # user.name, ...) leaves the lease carve-out on. The text is
                # lowercased, so -C reads as -c: only a `section.key=value`
                # word is taken as config; any other value may be a directory,
                # and so may any word at all once the raw text has a -C.
                [ "$w" = -c ] || off=1
                case "$cmd" in *-C*) off=1 ;; esac
                [ $((j + 1)) -lt "${#_gc_w[@]}" ] || return 0
                v=${_gc_w[j + 1]}
                case "${_gc_k[j + 1]}" in P|X|G) un=1; break ;; esac
                case "$w:$v" in
                    *:) un=1; break ;;
                    -c:alias.*) un=1; break ;;
                    # The alias body sits in an env var the hook cannot read.
                    --config-env:alias.*) deny "git --config-env alias" ;;
                    -c:clean.requireforce|-c:clean.requireforce=true|-c:clean.requireforce=1|-c:clean.requireforce=yes|-c:clean.requireforce=on) ;;
                    -c:clean.requireforce*|--config-env:clean.requireforce*) cf=1 ;;
                    -c:remote.*|-c:url.*|-c:push.*|-c:branch.*|-c:include*|-c:core.worktree*|-c:core.bare*) off=1 ;;
                esac
                [[ $v =~ ^[a-z0-9-]+\.[^=/]+= ]] || off=1
                j=$((j + 2)) ;;
            --config-env=alias.*) deny "git --config-env alias" ;;
            --config-env=clean.requireforce*) off=1; cf=1; j=$((j + 1)) ;;
            --git-dir=*|--work-tree=*|--namespace=*|--super-prefix=*|--config-env=*|--attr-source=*|--shallow-file=*|--bare)
                off=1; j=$((j + 1)) ;;
            -p|-P|--paginate|--no-pager|--no-replace-objects|--literal-pathspecs|--glob-pathspecs|--noglob-pathspecs|--icase-pathspecs|--no-optional-locks|--no-advice|--no-lazy-fetch|--exec-path|--exec-path=*|--list-cmds=*|--html-path|--man-path|--info-path|-h|--help|-v|--version)
                j=$((j + 1)) ;;
            ''|-*) un=1; break ;;
            *) break ;;
        esac
    done
    if [ "$un" = 1 ]; then
        _gp_join "$j"; _gp_unres "$REPLY"; return 0
    fi
    [ "$j" -lt "${#_gc_w[@]}" ] || return 0
    case "${_gc_w[j]}" in
        reset) _gp_reset $((j + 1)) ;;
        clean) _gp_clean $((j + 1)) "$cf" ;;
        filter-branch) deny "git filter-branch" ;;
        push) _gp_push $((j + 1)) "$off" ;;
    esac
    return 0
}

# Destructive gh verbs. gh changes or deletes repository settings
# (branch protection, rulesets, secrets, variables, workflows, the repo itself)
# with the station's admin token, and Bash(gh *) auto-approves every one. The
# walk below reads gh's argv from _gp_cmd, the same place git's is read, so a
# path-qualified gh, `command gh`, an env prefix and global flags (-R/--repo)
# before the verb all reach it. Reads and the merge paths other gates own
# (block-unresolved-cr-merge, the himmel-gh wrapper) stay allowed.
# ponytail: (HIMMEL-5264) a graphql mutation (deleteBranchProtectionRule) and a gh whose
# command word is computed ("$G" repo delete) are not modelled past the
# unresolved text markers, upgrade path the audit's G-series.
_gh_re_unres='[^a-z0-9_-](secret|variable)[[:space:]]+(set|delete|remove)[^a-z0-9_-]|[^a-z0-9_-]workflow[[:space:]]+(disable|enable)[^a-z0-9_-]|[^a-z0-9_-]repo[[:space:]]+(delete|archive|unarchive|rename|transfer|edit)[^a-z0-9_-]|[^a-z0-9_-]release[[:space:]]+(delete|delete-asset)[^a-z0-9_-]|[^a-z0-9_-](ssh|gpg)-key[[:space:]]+(add|delete)[^a-z0-9_-]|[^a-z0-9_-]auth[[:space:]]+(logout|token)[^a-z0-9_-]|[^a-z0-9_-]pr[[:space:]]+merge[[:space:]].*--admin'
_gh_re_unres_api_m='[^a-z0-9_-]api[[:space:]].*(-x[[:space:]]*|--method[[:space:]=]+)(delete|put|patch|post)'
_gh_re_unres_api_p='protection|rulesets|secrets|variables|/disable|/enable|/hooks|/keys|/transfer|/environments|repos/[^[:space:]/]+/[^[:space:]/]+([[:space:]]|/?$)'

# _gh_unres TEXT — the markers an unresolved gh invocation is held to.
_gh_unres() {
    local r=" $1 "
    if [[ $r =~ $_gh_re_unres ]]; then deny "gh destructive verb"; fi
    if [[ $r =~ $_gh_re_unres_api_m ]] && [[ $r =~ $_gh_re_unres_api_p ]]; then
        deny "gh api write on a settings path"
    fi
    return 0
}

# _gh_ep_settings EP — true when a gh api endpoint (lowercased) is a settings
# path whose DELETE, PUT, PATCH or POST changes the repository's protections.
_gh_ep_settings() {
    local ep=$1 r rest sub
    ep=${ep#https://api.github.com}
    ep=${ep#/}; ep=${ep%%\?*}; ep=${ep%/}
    case "$ep" in
        user/keys|user/keys/*|user/gpg_keys|user/gpg_keys/*|user/ssh_signing_keys|user/ssh_signing_keys/*) return 0 ;;
        orgs/*/rulesets|orgs/*/rulesets/*|orgs/*/actions/secrets|orgs/*/actions/secrets/*) return 0 ;;
        orgs/*/actions/variables|orgs/*/actions/variables/*|orgs/*/hooks|orgs/*/hooks/*) return 0 ;;
        repos/*/*) ;;
        *) return 1 ;;
    esac
    r=${ep#repos/}
    rest=${r#*/}
    case "$rest" in
        */*) sub=${rest#*/} ;;
        *) sub='' ;;
    esac
    case "$sub" in
        ''|rulesets|rulesets/*|hooks|hooks/*|keys|keys/*|collaborators|collaborators/*) return 0 ;;
        branches/*/protection|branches/*/protection/*) return 0 ;;
        actions/secrets|actions/secrets/*|actions/variables|actions/variables/*) return 0 ;;
        actions/workflows/*/disable|actions/workflows/*/enable|actions/permissions|actions/permissions/*) return 0 ;;
        dependabot/secrets|dependabot/secrets/*|codespaces/secrets|codespaces/secrets/*) return 0 ;;
        environments|environments/*|transfer|pages|pages/*|vulnerability-alerts|automated-security-fixes) return 0 ;;
    esac
    return 1
}

# _gh_api J — `gh api`'s argv from word J. The method is -X/--method, else POST
# when a field or --input is given, else GET; a GET (or an explicit GET with
# fields) is a read and passes.
_gh_api() {
    local j=$1 n=${#_gc_w[@]} m='' body=0 ep='' epk='' w k s o c=0
    while [ "$j" -lt "$n" ]; do
        w=${_gc_w[j]} k=${_gc_k[j]}
        case "$w" in
            -x|--method)
                j=$((j + 1))
                m=unres
                if [ "$j" -lt "$n" ] && [ "${_gc_k[j]}" = W ]; then m=${_gc_w[j]}; fi ;;
            --method=*) m=${w#--method=}; [ "$k" = W ] || m=unres ;;
            -x?*) m=${w#-x}; [ "$k" = W ] || m=unres ;;
            -f|--field|--raw-field|--input) body=1; j=$((j + 1)) ;;
            --field=*|--raw-field=*|--input=*|-f?*) body=1 ;;
            -h|--header|-q|--jq|-t|--template|--cache|--hostname|-p|--preview) j=$((j + 1)) ;;
            -[a-z]?*)
                # grouped short flags (-iXDELETE, -ifname=x): the first
                # value-taking letter ends the group
                s=${w#-}
                while [ -n "$s" ]; do
                    case "${s:0:1}" in
                        x)
                            o=${s:1}
                            if [ -n "$o" ]; then
                                m=$o; [ "$k" = W ] || m=unres
                            else
                                j=$((j + 1)); m=unres
                                if [ "$j" -lt "$n" ] && [ "${_gc_k[j]}" = W ]; then m=${_gc_w[j]}; fi
                            fi
                            break ;;
                        f) body=1; [ -n "${s:1}" ] || j=$((j + 1)); break ;;
                        h|q|t|p) [ -n "${s:1}" ] || j=$((j + 1)); break ;;
                    esac
                    s=${s:1}
                done ;;
            -*) ;;
            *) if [ -z "$ep" ]; then ep=$w; epk=$k; fi ;;
        esac
        j=$((j + 1))
    done
    if [ -z "$m" ]; then
        if [ "$body" = 1 ]; then m=post; else m='get'; fi
    fi
    case "$m" in delete|put|patch|post|unres) ;; *) return 0 ;; esac
    [ -n "$ep" ] || return 0
    # a full URL endpoint (scheme://host/path) is checked on its path
    s=${ep%%://*}
    case "$s" in
        "$ep"|*/*|'') ;;
        *) ep=${ep#*://}; case "$ep" in */*) ep=/${ep#*/} ;; esac ;;
    esac
    ep=${ep#/api/v3}
    if [ "$epk" != W ]; then
        case "$ep" in
            '$'*) deny "gh api $m on a computed endpoint" ;;
        esac
        [ "$epk" = G ] && deny "gh api $m on a globbed endpoint"
        s=$ep
        while [[ $s =~ $_gp_re_exp ]]; do
            [ "$c" -lt 256 ] || deny "more than 256 expansions at command position"
            s=${s/"${BASH_REMATCH[0]}"/x}
            c=$((c + 1))
        done
        # an expansion past owner/repo can carry a whole settings suffix
        # (repos/o/r/$T with T=rulesets/1), which the x substitution hides
        if [ "$c" -gt 0 ]; then
            o=${ep#/}; o=${o#repos/}
            case "$o" in
                */*/*)
                    o=${o#*/}; o=${o#*/}
                    case "${o%%/*}" in
                        *'$'*|*'`'*) deny "gh api $m on a computed repository subpath" ;;
                        actions|dependabot|codespaces|environments|branches|rulesets|hooks|keys)
                            case "$o" in *'$'*|*'`'*) deny "gh api $m on a computed repository subpath" ;; esac ;;
                    esac ;;
            esac
        fi
        ep=$s
    fi
    if _gh_ep_settings "$ep"; then deny "gh api $m on a repository settings path"; fi
    return 0
}

# _gh_cigcp J — true only for the CI_GCP kill switch: a bare gh (no env prefix,
# wrapper or computed word) running `variable set CI_GCP` with one --body of
# on|off and exactly one -R/--repo naming this repository (an omitted repo
# would follow GH_REPO or the checkout), nothing else.
_gh_cigcp() {
    local j=$1 n=${#_gc_w[@]} w pos='' body='' repo=''
    [ "$j" = 1 ] || return 1
    while [ "$j" -lt "$n" ]; do
        [ "${_gc_k[j]}" = W ] || return 1
        w=${_gc_w[j]}
        case "$w" in
            -r|--repo) [ -z "$repo" ] || return 1; j=$((j + 1)); [ "$j" -lt "$n" ] || return 1; [ "${_gc_k[j]}" = W ] || return 1; repo=${_gc_w[j]} ;;
            --repo=*) [ -z "$repo" ] || return 1; repo=${w#--repo=} ;;
            -b|--body) [ -z "$body" ] || return 1; j=$((j + 1)); [ "$j" -lt "$n" ] || return 1; [ "${_gc_k[j]}" = W ] || return 1; body=${_gc_w[j]} ;;
            --body=*) [ -z "$body" ] || return 1; body=${w#--body=} ;;
            -*) return 1 ;;
            *) pos="$pos $w" ;;
        esac
        j=$((j + 1))
    done
    [ "$pos" = " variable set ci_gcp" ] || return 1
    case "$body" in on|off) ;; *) return 1 ;; esac
    [ "$repo" = yotamleo/himmel ] || return 1
    return 0
}

# _gh_inv J — one gh invocation whose first argument is word J.
_gh_inv() {
    local j=$1 n=${#_gc_w[@]} w p1='' p2='' np=0 ai=0 e
    while [ "$j" -lt "$n" ]; do
        w=${_gc_w[j]}
        case "${_gc_k[j]}" in
            P|X|G)
                # a computed argument after `api` still reaches _gh_api, which
                # holds a computed endpoint and a computed method
                if [ "$p1" = api ]; then break; fi
                _gp_join "$1"; _gh_unres "$REPLY"; return 0 ;;
        esac
        case "$w" in
            -r|--repo|--hostname) j=$((j + 2)); continue ;;
            -*) ;;
            *)
                if [ "$np" = 0 ]; then p1=$w; np=1; ai=$((j + 1))
                else p2=$w; break; fi ;;
        esac
        j=$((j + 1))
    done
    case "$p1" in
        api) _gh_api "$ai" ;;
        secret|variable)
            case "$p2" in
                set|delete|remove)
                    [ "$p1" = variable ] && [ "$p2" = set ] && _gh_cigcp "$1" && return 0
                    deny "gh $p1 $p2" ;;
            esac ;;
        workflow) case "$p2" in disable|enable) deny "gh workflow $p2" ;; esac ;;
        repo) case "$p2" in delete|archive|unarchive|rename|transfer|edit) deny "gh repo $p2" ;; esac ;;
        release) case "$p2" in delete|delete-asset) deny "gh release $p2" ;; esac ;;
        ssh-key|gpg-key) case "$p2" in add|delete) deny "gh $p1 $p2" ;; esac ;;
        auth) case "$p2" in logout|token) deny "gh auth $p2" ;; esac ;;
        # an alias body is data the hook cannot see, and a later `gh <alias>`
        # (or a --shell body) runs it past every verb denied above
        alias) case "$p2" in set|import) deny "gh alias $p2" ;; esac ;;
        pr)
            [ "$p2" = merge ] || return 0
            e=$ai
            while [ "$e" -lt "$n" ]; do
                case "${_gc_w[e]}" in
                    --admin|--admin=*) deny "gh pr merge --admin" ;;
                esac
                case "${_gc_k[e]}:${_gc_w[e]}" in [PXG]:*admin*) deny "gh pr merge --admin" ;; esac
                e=$((e + 1))
            done ;;
    esac
    return 0
}

# _rm_inv J — one rm invocation whose first argument is word J: a `--r…` option
# word before the `--` terminator is rm's own recursive flag.
_rm_inv() {
    local j=$1
    while [ "$j" -lt "${#_gc_w[@]}" ]; do
        case "${_gc_k[j]}:${_gc_w[j]}" in
            W:--) return 0 ;;
            ?:--r*) _rm_flag=1; return 0 ;;
        esac
        j=$((j + 1))
    done
    return 0
}

# _gp_cmd ENTRIES — one logical command: ST_W indices, P for a substitution.
# Word kinds: A assignment, X live $, G glob, P substitution, W plain.
_gp_cmd() {
    local e i=0 n w b cp=-1 sa=0
    _gc_w=() _gc_k=()
    for e in $1; do
        if [ "$e" = P ]; then
            _gc_w[i]='$'; _gc_k[i]=P
        else
            _gc_w[i]=${ST_W[e]}
            if [ "${ST_A[e]}" = 1 ]; then _gc_k[i]=A
            elif [ "${ST_X[e]}" = 1 ]; then _gc_k[i]=X
            elif [ "${ST_G[e]}" = 1 ]; then _gc_k[i]=G
            else _gc_k[i]=W
            fi
        fi
        i=$((i + 1))
    done
    n=$i
    i=0
    while [ "$i" -lt "$n" ]; do
        w=${_gc_w[i]}
        case "$w" in *[[:space:]]*rm*|*rm*[[:space:]]*) _rm_blind=1 ;; esac
        if [ "${_gc_k[i]}" = A ]; then sa=1; i=$((i + 1)); continue; fi
        if [ "$cp" -lt 0 ]; then
            cp=$i
            b=''
            case "${_gc_k[i]}" in
                P|G) b=- ;;
                X) _gp_noexp_word "$w"; b=${REPLY##*/}; b=${b##*\\}; [ -n "$b" ] || b=- ;;
            esac
            case "$b" in
                -) _gp_inv $((i + 1)) "$sa" 1 ;;
                git|git.exe) _gp_inv $((i + 1)) "$sa" 0 ;;
                gh|gh.exe) _gh_inv $((i + 1)) ;;
                rm|rm.exe) _rm_inv $((i + 1)) ;;
            esac
            if [ -n "$b" ]; then i=$((i + 1)); continue; fi
        fi
        if [ "${_gc_k[i]}" != P ]; then
            b=${w##*/}; b=${b##*\\}
            case "$b" in
                git|git.exe) _gp_inv $((i + 1)) "$sa" 0 ;;
                gh|gh.exe) _gh_inv $((i + 1)) ;;
                rm|rm.exe) _rm_inv $((i + 1)) ;;
            esac
        fi
        i=$((i + 1))
    done
    return 0
}

# _gp_rec_word TEXT — add TEXT, leading blanks and one ! dropped, to the
# caller's rec when it may hold a git command to walk.
_gp_rec_word() {
    local v=$1
    v=${v#"${v%%[![:space:]]*}"}; v=${v#!}
    case "$v" in *git*[[:space:]]*|*[[:space:]]*git*) rec+=("$v") ;; esac
    return 0
}

# _gp_pass DEPTH LINES — walk the ST_* arrays st_tokenize just set. LINES is
# the raw text to re-read line by line when it carries a heredoc, else empty.
_gp_pass() {
    local d=$1 hd=$ST_HEREDOC k s top=0 e
    local -a segw=() ft=(T) fc=('') rec=()
    k=0
    while [ "$k" -lt "$ST_N" ]; do
        if [ -z "${ST_RO[k]}" ]; then
            s=${ST_S[k]}
            segw[s]="${segw[s]:-} $k"
        fi
        if [ "$d" -lt 2 ]; then
            # The word, and the text after its first `=` (a config value: an
            # alias body, a !helper, core.sshCommand), each with a leading !
            # dropped, since git runs `!cmd` through the shell.
            e=${ST_W[k]}
            [ "${ST_A[k]}" != 1 ] || e=${e#*=}
            _gp_rec_word "$e"
            case "$e" in *=*) _gp_rec_word "${e#*=}" ;; esac
        fi
        k=$((k + 1))
    done
    s=0
    while [ "$s" -lt "$ST_NSEG" ]; do
        fc[top]="${fc[top]}${segw[s]:-}"
        # shellcheck disable=SC2016 # separator tokens, not expansions
        case "${ST_SEP[s]}" in
            '$('|'<('|'>(')
                fc[top]="${fc[top]} P"; top=$((top + 1)); ft[top]=P; fc[top]='' ;;
            '`')
                if [ "${ft[top]}" = B ]; then
                    _gp_cmd "${fc[top]}"; top=$((top - 1))
                else
                    fc[top]="${fc[top]} P"; top=$((top + 1)); ft[top]=B; fc[top]=''
                fi ;;
            '(') top=$((top + 1)); ft[top]=S; fc[top]='' ;;
            ')')
                _gp_cmd "${fc[top]}"
                if [ "$top" -gt 0 ]; then top=$((top - 1)); else fc[0]=''; fi ;;
            *) _gp_cmd "${fc[top]}"; fc[top]='' ;;
        esac
        s=$((s + 1))
    done
    while [ "$top" -ge 0 ]; do _gp_cmd "${fc[top]}"; top=$((top - 1)); done
    for e in ${rec[@]+"${rec[@]}"}; do _gp_scan "$e" $((d + 1)); done
    if [ "$hd" = 1 ] && [ -n "$2" ]; then _gp_lines "$2" "$d"; fi
    return 0
}

# _gp_lines TEXT DEPTH — backslash-newlines joined, each line tokenized alone
# or, when it cannot be, read as text.
_gp_lines() {
    local t=$1 line
    t=${t//"$_bsnl"/}
    while IFS= read -r line; do
        if st_tokenize "$line"; then _gp_pass "$2" ''; else _gp_text "$line"; fi
    done <<<"$t"
    return 0
}

# _gp_body_line LINE — main's destructive-git text markers, for heredoc body
# text, which the argv walk does not read as commands.
_gp_body_line() {
    local l=$1 g='(^|[^[:alnum:]_.-])git(\.exe)?[[:space:]]+'
    if [[ $l =~ ${g}reset[[:space:]]+--hard([^[:alnum:]_-]|$) ]]; then deny "git reset --hard"; fi
    if [[ $l =~ ${g}clean[[:space:]]+-[[:alnum:]_]*f ]]; then deny "git clean -f"; fi
    if [[ $l =~ ${g}filter-branch([^[:alnum:]_-]|$) ]]; then deny "git filter-branch"; fi
    if [[ $l =~ ${g}push([^[:alnum:]_.-].*)?$ ]]; then
        l=${BASH_REMATCH[3]}
        if [[ $l =~ $_gp_re_pforce ]] || [[ $l =~ [[:space:]]\+[^[:space:]] ]]; then deny "force push"; fi
    fi
    return 0
}

# _gp_body TEXT — each heredoc body line, backslash-newlines joined, held to
# _gp_body_line. A body is data, yet a later command can run it (an alias
# written into .git/config), so the parser's relief never reaches it.
_gp_body() {
    # The delimiter is any shell word (`'1'`, `\eof`, `e"o"f`) with its quotes
    # removed; one that never matches leaves the rest of the text as body.
    local line t d rest re='(^|[^<])<<(-?)[[:space:]]*([^[:space:]<>|&;()]+)'
    local -a pend=()
    t=${1//"$_bsnl"/}
    while IFS= read -r line || [ -n "$line" ]; do
        if [ "${#pend[@]}" -gt 0 ]; then
            d=$line
            case "${pend[0]}" in -*) d=${d#"${d%%[!$'\t']*}"} ;; esac
            if [ "$d" = "${pend[0]#-}" ]; then pend=("${pend[@]:1}"); else _gp_body_line "$line"; fi
            continue
        fi
        rest=$line
        while [[ $rest =~ $re ]]; do
            _c_strip_quotes "${BASH_REMATCH[3]}"; d=$REPLY
            [ -z "${BASH_REMATCH[2]}" ] || d=-$d
            pend[${#pend[@]}]=$d
            rest=${rest#*"${BASH_REMATCH[0]}"}
        done
    done <<<"$t"
    return 0
}

# _gp_scan TEXT DEPTH — one command text, lowercased.
_gp_scan() {
    local t=$1
    case "$t" in *'<<'*) _gp_body "$t" ;; esac
    if st_tokenize "$t"; then
        if [ "$ST_HEREDOC" = 1 ] || [ "$ST_ANSIC" = 1 ]; then _rm_blind=1; fi
        _gp_pass "$2" "$t"; return 0
    fi
    _rm_blind=1
    _gu_flatten_params "$t"
    if [ "$GU_FLAT" != "$t" ] && st_tokenize "$GU_FLAT"; then _gp_pass "$2" "$t"; return 0; fi
    _gu_strip_heredocs "$GU_FLAT"
    if [ "$GU_NOHD" != "$GU_FLAT" ] && st_tokenize "$GU_NOHD"; then
        _gp_pass "$2" ''
    fi
    _gp_lines "$t" "$2"
}

# Only text that names git or one of its destructive subcommands pays for the
# walk. A `cd` anywhere still turns the lease carve-out off: the
# default branch is read from the hook's cwd, not the one the push runs in.
_rm_flag=0 _rm_blind=0
case "$_rm_long_hit:$cmd_lc" in
    1:*|*git*|*gh*|*reset*|*clean*|*push*|*filter-branch*)
        _gp_cd=0
        if contains '(^|[^[:alnum:]_.-])cd([^[:alnum:]_.-]|$)'; then _gp_cd=1; fi
        _gp_lc=$(printf '%s' "$cmd" | LC_ALL=C tr '[:upper:]' '[:lower:]')
        _gp_lc=${_gp_lc//"$_bscrlf"/"$_bsnl"}
        _gp_lc=${_gp_lc//$'\r'/$'\n'}
        _gp_scan "$_gp_lc" 0
        ;;
esac
# A long `--r…` word is rm's recursive flag only when it is one of rm's own
# arguments; the tokenizer's walk decides that, a blind walk fails closed.
# PowerShell text is always blind: the bash tokenizer drops the backslashes of
# a drive-qualified rm.exe, so the word never basenames to rm.
if [ "$tool" = PowerShell ] && [ "$_rm_long_hit" = 1 ]; then _rm_blind=1; fi
if [ "$_rm_long_hit" = 1 ] && { [ "$_rm_flag" = 1 ] || [ "$_rm_blind" = 1 ]; }; then
    deny "recursive rm"
fi
# Shared-.git history verbs and hook-defeat shapes, literal spellings only:
# `git <verb>` as typed, no evasion chasing.
_gg='git(\.exe)?[[:space:]]+([^;&|]*[[:space:]])?'
if contains "${CMDPOS}${_gg}"'tag[[:space:]]+([^;&|]*[[:space:]])?(-[a-z]*d[a-z]*|--delete)([^[:alnum:]_.-]|$)'; then
    deny "git tag -d"
fi
if contains "${CMDPOS}${_gg}"'branch[[:space:]]+([^;&|]*[[:space:]])?-[a-z]*d' \
   && [[ $cmd =~ [[:space:]]-[A-Za-z]*D ]]; then
    deny "git branch -D"
fi
if contains "${CMDPOS}${_gg}"'update-ref[[:space:]]+([^;&|]*[[:space:]])?-d([^[:alnum:]_.-]|$)'; then
    deny "git update-ref -d"
fi
if contains "${CMDPOS}${_gg}"'reflog[[:space:]]+expire([^[:alnum:]_.-]|$)'; then
    deny "git reflog expire"
fi
if contains "${CMDPOS}${_gg}"'gc[[:space:]]+([^;&|]*[[:space:]])?--prune=now'; then
    deny "git gc --prune=now"
fi
if contains "${CMDPOS}${_gg}"'filter-repo([^[:alnum:]_.-]|$)'; then
    deny "git filter-repo"
fi
if contains "${CMDPOS}${_gg}"'[^;&|]*--no-verify([^[:alnum:]_.-]|$)'; then
    deny "git --no-verify"
fi
if contains "${CMDPOS}${_gg}"'-c[[:space:]]*core\.hookspath='; then
    deny "git core.hooksPath override"
fi
if contains "${CMDPOS}"'chmod[[:space:]]+([^;&|]*[[:space:]])?[augo]*-x[^;&|]*\.git/hooks'; then
    deny "chmod -x on .git/hooks"
fi
if contains "${CMDPOS}"'pre-commit[[:space:]]+uninstall([^[:alnum:]_.-]|$)'; then
    deny "pre-commit uninstall"
fi
if contains "${CMDPOS}"'export[[:space:]]+destructive_ok='; then
    deny "export DESTRUCTIVE_OK"
fi
# Remote exec: a download piped, substituted or saved-then-run
# into an interpreter. The bare interpreters (python, node, perl, ...) are a
# sink only when they read the script from stdin (no arg, or a lone `-`), so
# `curl x | python3 -m json.tool` and `| node -p ...` stay allowed.
_re_asg='[a-z_][a-z0-9_]*=[^[:space:]]*[[:space:]]+'
_re_pre='\|[[:space:]]*((sudo|env)[[:space:]]+((-[^[:space:]]+|'"$_re_asg"')[[:space:]]*)*)*('"$_re_asg"')*'
_re_shell='(ba|z|da|k|c|tc)?sh(\.exe)?([^[:alnum:]_.-]|$)'
_re_bare='(python[0-9.]*|nodejs|node|perl|ruby|php|deno|bun)(\.exe)?([[:space:]]+-[a-z]?)*[[:space:]]*($|[;&|)<>]|[0-9]+>)'
_re_sink="($_re_shell|$_re_bare)"
_re_dl='(^|[^[:alnum:]_.-])(curl|wget)(\.exe)?'
if contains "$_re_dl"'[^|;&]*'"$_re_pre$_re_sink" \
   || contains "$_re_dl"'[^|;&]*\|[[:space:]]*tee[^|;&]*'"$_re_pre$_re_sink"; then
    deny "remote exec pipe"
fi
# Process / command substitution of a download into an interpreter or source/eval.
if contains '(^|[^[:alnum:]_.-])(source|\.|eval|(ba|z|da|k)?sh|python[0-9.]*|nodejs|node|perl|ruby)(\.exe)?[[:space:]][^;&|]*(<\(|\$\(|`)[[:space:]]*(curl|wget)(\.exe)?([^[:alnum:]_.-]|$)'; then
    deny "remote exec substitution"
fi
# PowerShell download-and-evaluate.
if contains '(^|[^[:alnum:]_.-])(iwr|irm|invoke-webrequest|invoke-restmethod|curl|wget)(\.exe)?[^|;&]*\|[[:space:]]*(iex|invoke-expression)([^[:alnum:]_.-]|$)' \
   || contains '(^|[^[:alnum:]_.-])(iex|invoke-expression)[^;&|]*(iwr|irm|invoke-webrequest|invoke-restmethod)([^[:alnum:]_.-]|$)'; then
    deny "remote exec iex"
fi
# Download-then-run in one command: `curl -o x URL; sh x`, `wget -O x URL && ./x`.
_remote_dl_run() {
    local s re run1 run2 x xr rest t i c q='["'"'"']?'
    re="$_re_dl"'[[:space:]]([^;&|]*[[:space:]])?(-[a-z]*o|--output|--output-document)[[:space:]=]*(["'"'"']([^"'"'"']+)["'"'"']|([[:alnum:]_./~-]+))'
    for s in "$cmd_lc" "$cmd_lc_join"; do
        # Every download in the command, not just the first: each saved file is
        # checked against what runs after its own download.
        while [[ $s =~ $re ]]; do
            x=${BASH_REMATCH[7]:-${BASH_REMATCH[8]}}
            # `-opayload`: the flag cluster and the name run together, so the
            # regex may end the cluster at a later `o`; the name starts after the first.
            t=${BASH_REMATCH[5]}
            if [[ $t != --* && ${BASH_REMATCH[0]} == *"$t$x" ]]; then x=${t#*o}$x; fi
            rest=${s#*"${BASH_REMATCH[0]}"}
            # The saved name goes into a regex: bracket every metacharacter.
            xr=
            for ((i = 0; i < ${#x}; i++)); do
                c=${x:i:1}
                case $c in
                [[:alnum:]_/~-]) xr+=$c ;;
                ' ') xr+='[[:space:]]' ;;
                '^') xr+='\^' ;;
                \\) xr+=\\\\ ;;
                *) xr+="[$c]" ;;
                esac
            done
            run1='(^|[^[:alnum:]_.-])(source|\.|(ba|z|da|k)?sh|python[0-9.]*|nodejs|node|perl|ruby)(\.exe)?[[:space:]]+(-[^[:space:]]+[[:space:]]+)*'"$q"'(\./)?'"$xr"'([^[:alnum:]_./~-]|$)'
            run2='(^|[;&|])[[:space:]]*'"$q"'(\./)?'"$xr"'([^[:alnum:]_./~-]|$)'
            if [[ $rest =~ $run1 ]] || [[ $rest =~ $run2 ]]; then return 0; fi
            s=$rest
        done
    done
    return 1
}
if _remote_dl_run; then
    deny "remote exec download-then-run"
fi

exit 0
