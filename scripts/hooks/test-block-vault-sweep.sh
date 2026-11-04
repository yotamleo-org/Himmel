#!/usr/bin/env bash
# Suite for marketplace/plugins/himmel-ops/hooks/block-vault-sweep.sh.
#
# Usage: bash scripts/hooks/test-block-vault-sweep.sh
set -uo pipefail

TMP=$(mktemp -d "${TMPDIR:-/tmp}/block-vault-sweep.XXXXXX") || exit 1
trap 'rm -rf "$TMP"' EXIT

FAILED=0
pass() { echo "PASS $1"; }
fail() { echo "FAIL $1"; FAILED=$((FAILED + 1)); }

# ---------------------------------------------------------------------------
# Vault sweep POC: marketplace/plugins/himmel-ops/hooks/block-vault-sweep.sh,
# the opt-in PreToolUse deny that refuses the first hand sweep of the notes
# once and names the qmd search. Hermetic: the vault paths below are strings
# the hook never opens, its state dir and log live under $TMP, and the cwd is a
# plain temp dir (no git, no salus). Unlike the rows above, a deny here is the
# expected result (exit 2).
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
VHOOK="${VSWEEP_HOOK_UNDER_TEST:-$ROOT/marketplace/plugins/himmel-ops/hooks/block-vault-sweep.sh}"
VLOG="$TMP/vlog.jsonl"
VAULT=/home/u/Documents/luna
mkdir -p "$TMP/work" "$TMP/vhome/.config/claude-glm"

# vcall SID TOOL COMMAND-OR-PATTERN [PATH] [CWD] -> rc in $rc, stderr in $TMP/err
# Overridable per call: VON, VBYP, VDIR, VREPO.
vcall() {
    local sid="$1" tool="$2" cmd="${3:-}" path="${4:-}" cwd="${5:-$TMP/work}" ti
    if [ "$tool" = Grep ]; then
        ti="$(jq -cn --arg p "$cmd" --arg d "$path" '{pattern: $p} + (if $d == "" then {} else {path: $d} end)')"
    elif [ -n "$cmd" ]; then
        ti="$(jq -cn --arg c "$cmd" '{command: $c}')"
    else
        ti='{}'
    fi
    local payload
    payload="$(jq -cn --arg s "$sid" --arg t "$tool" --arg d "$cwd" --argjson i "$ti" \
        '{session_id: $s, cwd: $d, hook_event_name: "PreToolUse", tool_name: $t, tool_input: $i}')"
    env HIMMEL_VAULT_SWEEP_DENY="${VON-1}" HIMMEL_VAULT_SWEEP_BYPASS="${VBYP-}" \
        HIMMEL_VAULT_SWEEP_DIR="${VDIR-$TMP/vstate}" HIMMEL_VAULT_SWEEP_LOG="$VLOG" \
        CLAUDE_PROJECT_DIR="${VPROJ-}" \
        HIMMEL_REPO="${VREPO-$ROOT}" HOME="${VHOME-$TMP/vhome}" bash "${VHOOK_ALT:-$VHOOK}" <<<"$payload" >"$TMP/out" 2>"$TMP/err"
    rc=$?
}
# vrows DESC-PREFIX WANT-RC SID-PREFIX CMD...: one fresh session per command
vrows() {
    local want="$1" label="$2" c n=0
    shift 2
    for c in "$@"; do
        n=$((n + 1))
        vcall "vr-$label-$n" Bash "$c"
        [ "$rc" = "$want" ] || fail "$label: want rc=$want got rc=$rc for: $c"
    done
}

# 10. A vault sweep is denied once, naming the absolute qmd command, then allowed.
S="grep -rl \"meeting notes\" $VAULT"
vcall v1 Bash "$S"
if [ "$rc" = 2 ] && grep -q "$ROOT/scripts/lib/qmd-bounded.sh query -c luna" "$TMP/err" \
    && grep -q 'one retry' "$TMP/err" && grep -q 'no chief message' "$TMP/err" \
    && grep -q 'HIMMEL_VAULT_SWEEP_BYPASS=1' "$TMP/err"; then pass "first vault sweep is denied with the absolute qmd command, one retry and the bypass named"; else fail "first vault sweep denied (rc=$rc)"; fi
vcall v1 Bash "$S"
if [ "$rc" = 0 ]; then pass "the retry of the same sweep is allowed"; else fail "retry allowed (rc=$rc)"; fi
vcall v1 Bash "rg -n other $VAULT/handovers"
if [ "$rc" = 0 ]; then pass "later sweeps in the same session stay allowed"; else fail "later sweep allowed (rc=$rc)"; fi
vcall v1b Bash "rg -n notes $VAULT/handovers"
if [ "$rc" = 2 ]; then pass "a second session is denied on its own"; else fail "second session denied (rc=$rc)"; fi

# 11. The other closed-list shapes: the Grep tool, rg, a recursive flag in any option token, a Clippings root.
vcall v2 Grep "meeting notes" "$VAULT/handovers"
if [ "$rc" = 2 ]; then pass "Grep tool over a vault path is denied"; else fail "Grep tool denied (rc=$rc)"; fi
vcall v2g Grep "meeting notes" "" "$VAULT"
if [ "$rc" = 2 ]; then pass "Grep tool with no path, cwd in the vault, is denied"; else fail "Grep tool cwd vault denied (rc=$rc)"; fi
vrows 2 shape \
    "rg -n notes $VAULT" \
    "grep -n -r notes $VAULT" \
    "grep -Rli notes /home/u/Clippings" \
    "cd /x && grep -rn \"plain words\" $VAULT/specs" \
    "grep --recursive notes $VAULT"

# 12. Never denied: a repo grep, a named file, find -name, a listing, a quoted mention.
vrows 0 allow \
    "grep -rn notes /home/u/Documents/github/himmel/scripts" \
    "grep -rn notes src" \
    "grep -n notes $VAULT/handovers/one.md" \
    "grep -rn notes" \
    "find $VAULT -name \"*.md\"" \
    "ls $VAULT" \
    "git status" \
    "echo \"grep -r notes $VAULT\"" \
    "git commit -m \"grep -r notes $VAULT\"" \
    "git grep -n notes" \
    "grep -e notes -r $VAULT" \
    "grep -rn matrix $VAULT/handovers/one.md" \
    "grep -rn matrix $VAULT/handovers/one.md $VAULT/handovers/two.md" \
    "cd $VAULT/handovers; grep -rl notes specs" \
    "cd /home/u/Documents/github/himmel && rg -n notes scripts" \
    "R=$VAULT; grep -rn notes \$R/specs" \
    "grep -rn notes \$(pwd)/specs"
vrows 2 shape2 \
    "grep -rli notes $VAULT/handovers/*.md" \
    "grep -rl notes \$HOME/Documents/luna"
vcall v18 Bash "grep -rl notes 2>/dev/null" "" "$VAULT"
a=$rc
vcall v18b Bash "grep -rn ssh \$(find $VAULT/specs -name x.md)" "" "$VAULT"
if [ "$a" = 0 ] && [ "$rc" = 0 ]; then pass "a redirection or a command substitution is never read as a vault root"; else fail "redirection/substitution roots (redir=$a subst=$rc)"; fi
vcall v17 Bash "grep -rl notes specs" "" "$VAULT"
a=$rc
vcall v17b Bash "cd /home/u/Documents/github/himmel; grep -rl notes specs" "" "$VAULT"
if [ "$a" = 2 ] && [ "$rc" = 0 ]; then pass "a relative root in a vault cwd is denied, but not after a cd in the command"; else fail "relative root vs cd (plain=$a cd=$rc)"; fi
vcall v17c Bash "pushd /home/u/Documents/github/himmel; grep -rl notes specs" "" "$VAULT"
if [ "$rc" = 0 ]; then pass "a relative root is not read after a pushd in the command"; else fail "relative root vs pushd (rc=$rc)"; fi
vcall v3 Grep "meeting notes" "/home/u/Documents/github/himmel/scripts"
if [ "$rc" = 0 ]; then pass "Grep tool over a repo path is allowed"; else fail "Grep repo path allowed (rc=$rc)"; fi

# 13. A ticket key, a number, a session name or a marker in the pattern is never denied.
vrows 0 id \
    "grep -rl HIMMEL-8748 $VAULT" \
    "grep -rl \"HIMMEL 8748\" $VAULT" \
    "grep -rl 3972 $VAULT" \
    "grep -rl 2112300408550867318 $VAULT" \
    "grep -rl '\\b344\\b' $VAULT" \
    "grep -rl harvest-clips $VAULT" \
    "grep -rl KN-j4295-1 $VAULT" \
    "grep -rl '#3972' $VAULT" \
    "rg -l 'a|b' $VAULT"
vcall v4 Grep "HIMMEL-8748" "$VAULT"
if [ "$rc" = 0 ]; then pass "Grep tool with a ticket key is allowed"; else fail "Grep ticket key allowed (rc=$rc)"; fi

# 14. A qmd call clears the deny, whether it comes before or after the refusal.
vcall v5 Bash "bash $ROOT/scripts/lib/qmd-bounded.sh query -c luna \"meeting notes\""
vcall v5 Bash "$S"
if [ "$rc" = 0 ]; then pass "a qmd-bounded.sh call before the sweep clears the deny"; else fail "qmd-bounded clears (rc=$rc)"; fi
vcall v6 mcp__qmd__query
vcall v6 Bash "$S"
if [ "$rc" = 0 ]; then pass "a qmd MCP call before the sweep clears the deny"; else fail "qmd mcp clears (rc=$rc)"; fi
vcall v6p mcp__plugin_qmd_qmd__query
vcall v6p Bash "$S"
if [ "$rc" = 0 ]; then pass "a plugin-named qmd MCP call clears the deny"; else fail "plugin qmd clears (rc=$rc)"; fi
vcall v7 Bash "$S"
vcall v7 Bash 'qmd query -c luna "meeting notes"'
vcall v7 Bash "$S"
if [ "$rc" = 0 ]; then pass "a qmd call after the refusal keeps later sweeps allowed"; else fail "qmd after refusal (rc=$rc)"; fi
vcall v7 Bash 'qmd query -c luna "again"'
if [ "$(jq -s '[.[] | select(.session_id == "v7" and .event == "qmd_clear")] | length' "$VLOG")" = 1 ]; then pass "only the first qmd call of a session is logged"; else fail "a second qmd call logged again"; fi

# 15. Off by default, the launching-shell bypass, and silence in a salus session.
VON='' vcall v8 Bash "$S"
if [ "$rc" = 0 ]; then pass "switch unset: the hook is a no-op"; else fail "switch unset (rc=$rc)"; fi
VBYP=1 vcall v9 Bash "$S"
if [ "$rc" = 0 ]; then pass "HIMMEL_VAULT_SWEEP_BYPASS=1 allows"; else fail "bypass allows (rc=$rc)"; fi
mkdir -p "$TMP/salus-app" "$TMP/marked/sub"
: >"$TMP/marked/.salus"
vcall v10 Bash "$S" "" "$TMP/salus-app"
a=$rc
vcall v10b Bash "$S" "" "$TMP/marked/sub"
if [ "$a" = 0 ] && [ "$rc" = 0 ]; then pass "salus cwd path and .salus marker: silent"; else fail "salus silent (path=$a marker=$rc)"; fi
vcall v10c Bash "grep -rl notes /home/u/salus-app/docs $VAULT"
if [ "$rc" = 0 ]; then pass "a command naming salus: silent"; else fail "salus in command silent (rc=$rc)"; fi

# 16. Fail open on its own problems.
printf 'not json' | HIMMEL_VAULT_SWEEP_DENY=1 bash "$VHOOK" >"$TMP/out" 2>"$TMP/err"; rc=$?
if [ "$rc" = 0 ] && [ ! -s "$TMP/out" ] && [ ! -s "$TMP/err" ]; then pass "vault hook: malformed JSON exits 0 silently"; else fail "vault hook malformed JSON (rc=$rc)"; fi
HIMMEL_VAULT_SWEEP_DENY=1 bash "$VHOOK" </dev/null >"$TMP/out" 2>"$TMP/err"; rc=$?
if [ "$rc" = 0 ] && [ ! -s "$TMP/err" ]; then pass "vault hook: empty stdin exits 0"; else fail "vault hook empty stdin (rc=$rc)"; fi
: >"$TMP/afile"
VDIR="$TMP/afile/state" vcall v11 Bash "$S"
if [ "$rc" = 0 ]; then pass "unwritable state dir allows"; else fail "unwritable state dir (rc=$rc)"; fi
VREPO="$TMP/no-such-checkout" vcall v12 Bash "$S"
if [ "$rc" = 0 ]; then pass "no resolvable checkout (cannot name the absolute path) allows"; else fail "no checkout allows (rc=$rc)"; fi
vcall v13 Bash "grep -rl notes $VAULT \"unterminated"
if [ "$rc" = 0 ]; then pass "unbalanced quote (unparseable) allows"; else fail "unbalanced quote allows (rc=$rc)"; fi

# 16b. The checkout falls back to the canonical install, a path with a space is quoted in the
# command the deny prints, and concurrent sweeps on one key give exactly one refusal.
mkdir -p "$TMP/fakehome/Documents/github/himmel/scripts/lib" "$TMP/my repo/scripts/lib"
: >"$TMP/fakehome/Documents/github/himmel/scripts/lib/qmd-bounded.sh"
: >"$TMP/my repo/scripts/lib/qmd-bounded.sh"
VREPO='' VHOME="$TMP/fakehome" vcall v19 Bash "$S"
if [ "$rc" = 2 ] && grep -qF "$TMP/fakehome/Documents/github/himmel/scripts/lib/qmd-bounded.sh query" "$TMP/err"; then pass "no HIMMEL_REPO and no checkout in the cwd: the canonical install names the command"; else fail "canonical fallback (rc=$rc)"; fi
VREPO="$TMP/my repo" vcall v20 Bash "$S"
if [ "$rc" = 2 ] && grep -qF "bash '$TMP/my repo/scripts/lib/qmd-bounded.sh' query" "$TMP/err"; then pass "a checkout path with a space is quoted in the printed command"; else fail "space path quoted (rc=$rc)"; fi
for i in 1 2 3 4 5 6; do
    ( vcall v21 Bash "$S"; echo "$rc" >"$TMP/par.$i" ) &
done
wait
if [ "$(cat "$TMP"/par.* | grep -c '^2$')" = 1 ] && [ "$(cat "$TMP"/par.* | grep -c '^0$')" = 5 ] \
    && [ "$(jq -s '[.[] | select(.session_id == "v21" and .event == "deny")] | length' "$VLOG")" = 1 ] \
    && [ "$(jq -s '[.[] | select(.session_id == "v21" and .event == "retry_allowed")] | length' "$VLOG")" = 5 ]; then pass "six concurrent sweeps on one key: exactly one refusal, and the other five are logged as the retry"; else fail "concurrent sweeps: $(cat "$TMP"/par.* | tr '\n' ' ')"; fi

# 16c. A qmd call in a salus session is never logged (its query text is PHI-path content); a quoted
# qmd helper path with a space still counts as a qmd call; an option value and a separated
# redirection target are not a pattern or a root.
vcall v22 Bash 'qmd query -c salus "Alice Smith diagnosis"'
vcall v22b Bash 'qmd query -c luna "Alice Smith diagnosis"' "" "$TMP/salus-app"
vcall v22c Bash 'qmd query -c luna "Alice Smith diagnosis"' "" "$TMP/marked/sub"
if ! grep -q 'Alice' "$VLOG" && ! grep -q '"session_id":"v22' "$VLOG"; then pass "salus session (command, cwd path, .salus marker): a qmd call writes no log row"; else fail "salus qmd call logged"; fi
vcall v23 Bash "bash '$TMP/my repo/scripts/lib/qmd-bounded.sh' query -c luna \"notes\""
vcall v23 Bash "$S"
a=$rc
vcall v23b Bash "bash \"$TMP/my repo/scripts/lib/qmd-bounded.sh\" query -c luna \"notes\""
vcall v23b Bash "$S"
if [ "$a" = 0 ] && [ "$rc" = 0 ]; then pass "a quoted qmd helper path with a space clears the deny"; else fail "quoted spaced qmd path (single=$a double=$rc)"; fi
vrows 0 operand \
    "rg --sort path HIMMEL-8847 $VAULT" \
    "rg --sortr modified HIMMEL-8847 $VAULT" \
    "rg notes . > $VAULT/output" \
    "grep -rl notes . 2> $VAULT/err"

# 16d. The salus test asks the sibling egress fence: each signal below, planted in a fixture
# HOME or tree, keeps a session silent AND writes no log row, no state and no stderr text, for
# both a qmd call and a closed-list sweep. A failing or absent oracle is "cannot tell", also silent.
logged() { grep -q "\"session_id\":\"$1\"" "$VLOG"; }
QMDQ='qmd query -c luna "Alice Smith"'
CG="$TMP/vhome/.config/claude-glm"
salus_row() { # DESC SID [CWD] [QMD-COMMAND] [SWEEP-COMMAND]
    local desc="$1" sid="$2" cwd="${3:-$TMP/work}" qc="${4:-$QMDQ}" sc="${5:-$S}" a b
    vcall "$sid" Bash "$qc" "" "$cwd"; a=$rc
    vcall "${sid}s" Bash "$sc" "" "$cwd"; b=$rc
    if [ "$a" = 0 ] && [ "$b" = 0 ] && [ ! -s "$TMP/err" ] && ! logged "$sid" && ! logged "${sid}s" \
        && ! grep -q 'Alice' "$VLOG" && [ ! -e "$TMP/vstate/$sid.clear" ] && [ ! -e "$TMP/vstate/${sid}s.denied" ]; then
        pass "$desc"
    else
        fail "$desc (qmd=$a sweep=$b)"
    fi
}
mkdir -p "$TMP/phi/app" "$TMP/prof/sub"
printf '%s\n' "$TMP/phi" >"$CG/phi-roots"
salus_row "cwd under a phi-roots root: silent, nothing logged" v30 "$TMP/phi/app"
rm -f "$CG/phi-roots"
printf '# list\n%s/\n' "$TMP/phi" >"$CG/egress-denylist"
salus_row "cwd under an egress-denylist root: silent, nothing logged" v31 "$TMP/phi/app"
rm -f "$CG/egress-denylist"
: >"$TMP/prof/.salus-profile"
salus_row "a .salus-profile marker on an ancestor: silent, nothing logged" v32 "$TMP/prof/sub"
ln -s "$TMP/marked/sub" "$TMP/linkcwd"
salus_row "a cwd that is a symlink into a .salus tree: silent, nothing logged" v33 "$TMP/linkcwd"
mkdir -p "$TMP/g1"
git -C "$TMP/g1" init -q 2>/dev/null
git -C "$TMP/g1" remote add origin https://example.test/org/salus-app.git
salus_row "a git remote naming salus: silent, nothing logged" v34 "$TMP/g1"
mkdir -p "$TMP/mainsalus"
git -C "$TMP/mainsalus" init -q 2>/dev/null
git -C "$TMP/mainsalus" -c user.name=t -c user.email=t@t.test -c commit.gpgsign=false commit -q --allow-empty -m x 2>/dev/null
git -C "$TMP/mainsalus" worktree add -q "$TMP/wtree" 2>/dev/null
salus_row "a worktree whose git common dir names salus: silent, nothing logged" v35 "$TMP/wtree"
VPROJ="$TMP/marked/sub" salus_row "CLAUDE_PROJECT_DIR in a salus tree while the cwd is elsewhere: silent, nothing logged" v36
mkdir -p "$TMP/stub1" "$TMP/stub2" "$TMP/stub3"
for d in stub1 stub2 stub3; do cp "$VHOOK" "$TMP/$d/block-vault-sweep.sh"; done
printf '#!/bin/sh\nexit 0\n' >"$TMP/stub1/block-agent-native-egress.sh"
printf '#!/bin/sh\nexit 1\n' >"$TMP/stub3/block-agent-native-egress.sh"
VHOOK_ALT="$TMP/stub1/block-vault-sweep.sh" salus_row "an oracle that always allows fails the canary: silent, nothing logged" v37
VHOOK_ALT="$TMP/stub2/block-vault-sweep.sh" salus_row "an absent oracle is cannot-tell: silent, nothing logged" v38
VHOOK_ALT="$TMP/stub3/block-vault-sweep.sh" salus_row "a crashing oracle is cannot-tell: silent, nothing logged" v39
# the fence also sees the command: a listed root, or a symlink alias into one or into a salus-named tree,
# named from an outside cwd keeps the session silent, with no query text in the log
mkdir -p "$TMP/salus-tree/app"
ln -s "$TMP/phi/app" "$TMP/alias-phi"
ln -s "$TMP/salus-tree/app" "$TMP/alias-st"
printf '%s\n' "$TMP/phi" >"$CG/phi-roots"
salus_row "a listed root named in the command from an outside cwd: silent, nothing logged" v50 "$TMP/work" \
    "cd $TMP/phi/app && $QMDQ" "grep -rl \"meeting notes\" $TMP/phi/app $VAULT"
salus_row "a symlink alias into a listed root named in the command: silent, nothing logged" v51 "$TMP/work" \
    "cd $TMP/alias-phi && $QMDQ" "grep -rl \"meeting notes\" $TMP/alias-phi $VAULT"
rm -f "$CG/phi-roots"
salus_row "a symlink alias into a salus-named tree named in the command: silent, nothing logged" v52 "$TMP/work" \
    "cd $TMP/alias-st && $QMDQ" "grep -rl \"meeting notes\" $TMP/alias-st $VAULT"
ln -s "$TMP/prof/sub" "$TMP/proflink"
salus_row "a cwd that is a symlink into a .salus-profile-only tree: silent, nothing logged" v53 "$TMP/proflink"
# the Grep tool: salus named in the pattern or the path is silent, with nothing logged
vcall v54 Grep "salus notes" "" "$VAULT"
a=$rc
vcall v54b Grep "meeting notes" "$VAULT/salus-docs"
if [ "$a" = 0 ] && [ "$rc" = 0 ] && ! logged v54 && ! logged v54b && [ ! -e "$TMP/vstate/v54.denied" ] && [ ! -e "$TMP/vstate/v54b.denied" ]; then pass "Grep naming salus in the pattern or the path: silent, nothing logged"; else fail "Grep naming salus (pattern=$a path=$rc)"; fi
# the Grep tool: a plain pattern and a path in the vault shape that is a symlink into a listed root, no
# "salus" anywhere in the text: the fence must see the path, so the call is silent and logs nothing
mkdir -p "$TMP/home2/Documents"
ln -s "$TMP/phi/app" "$TMP/home2/Documents/luna"
printf '%s\n' "$TMP/phi" >"$CG/phi-roots"
vcall v56 Grep "Alice Smith" "$TMP/home2/Documents/luna"
if [ "$rc" = 0 ] && ! logged v56 && [ ! -e "$TMP/vstate/v56.denied" ] && ! grep -q 'Alice' "$VLOG"; then pass "Grep with a plain pattern and a symlink path into a listed root: silent, nothing logged"; else fail "Grep symlink path into a listed root (rc=$rc)"; fi
# whatever the fence catches, no row carries the text: a listed root named as $HOME/<root> (the fence reads the
# literal $HOME, so it misses and the sweep is refused and logged), a relative root after a cd, and a
# .salus-marked tree the fence cannot see all leave no "Alice" in the log
printf '%s\n' "$TMP/vhome/phiroot" >"$CG/phi-roots"
mkdir -p "$TMP/vhome/phiroot/app"
vcall v57 Bash "grep -rl \"Alice Smith\" \$HOME/phiroot/app $VAULT"
a=$rc
printf '%s\n' "$TMP/phi" >"$CG/phi-roots"
vcall v58 Bash "cd $TMP && grep -rl \"Alice Smith\" phi/app $VAULT"
b=$rc
vcall v59 Bash "grep -rl \"Alice Smith\" $TMP/marked/sub $VAULT"
c=$rc
if [ "$a" = 2 ] && [ "$b" = 2 ] && [ "$c" = 2 ] && ! grep -q 'Alice' "$VLOG" && logged v57 && logged v58 && logged v59; then pass "sweeps naming a listed root, a root after a cd and a .salus-marked tree: no query text in the log, whichever the fence caught"; else fail "sweeps leave no text (listed=$a cd=$b marked=$c)"; fi
rm -f "$CG/phi-roots"
# a name above the vault folder never reaches the log: the root is a fixed label, not a path prefix
vcall v60 Bash "grep -rl notes \"\$HOME/phi/Alice Smith/Clippings\""
a=$rc
vcall v61 Bash "grep -rl notes \"/x/Alice Smith/Documents/luna\""
b=$rc
vcall v62 Bash "grep -rl notes /home/u/Clippings/Alice"
c=$rc
if [ "$a" = 2 ] && [ "$b" = 2 ] && [ "$c" = 2 ] && ! grep -q 'Alice' "$VLOG" && logged v60 && logged v61 && logged v62 \
    && [ "$(jq -r 'select(.session_id == "v60" or .session_id == "v62") | .root' "$VLOG" | sort -u | tr '\n' ' ')" = "clippings " ] \
    && [ "$(jq -r 'select(.session_id == "v61") | .root' "$VLOG")" = luna ]; then pass "a name above a vault folder: logged with a fixed label (luna or clippings) and no name"; else fail "name above the vault folder (a=$a b=$b c=$c)"; fi
vcall v63 Bash "grep -rl notes Clippings" "" /x/proj
if [ "$rc" = 2 ] && [ "$(jq -r 'select(.session_id == "v63") | .root' "$VLOG")" = clippings ]; then pass "a bare relative Clippings root gets the clippings label"; else fail "bare relative Clippings (rc=$rc)"; fi
# a payload with no cwd cannot be placed, so it reads as salus: silent, nothing logged
vraw() { # SID COMMAND
    local payload
    payload="$(jq -cn --arg s "$1" --arg c "$2" '{session_id: $s, hook_event_name: "PreToolUse", tool_name: "Bash", tool_input: {command: $c}}')"
    env HIMMEL_VAULT_SWEEP_DENY=1 HIMMEL_VAULT_SWEEP_DIR="$TMP/vstate" HIMMEL_VAULT_SWEEP_LOG="$VLOG" \
        CLAUDE_PROJECT_DIR= HIMMEL_REPO="$ROOT" HOME="$TMP/vhome" bash "$VHOOK" <<<"$payload" >"$TMP/out" 2>"$TMP/err"
    rc=$?
}
vraw v65 "$S"
if [ "$rc" = 0 ] && ! logged v65 && [ ! -e "$TMP/vstate/v65.denied" ]; then pass "a payload with no cwd: silent, nothing logged"; else fail "no cwd (rc=$rc)"; fi
# a cwd that does not exist under a .salus-profile tree is still found by walking the path as given
salus_row "a missing cwd under a .salus-profile tree: silent, nothing logged" v66 "$TMP/prof/sub/missing"
# CLAUDE_PROJECT_DIR is asked of the fence too: under a listed root while the cwd is elsewhere
printf '%s\n' "$TMP/phi" >"$CG/phi-roots"
VPROJ="$TMP/phi/app" salus_row "CLAUDE_PROJECT_DIR under a listed root while the cwd is elsewhere: silent, nothing logged" v67
rm -f "$CG/phi-roots"
# the session id is a file name: it is sanitised, and an empty one allows
vcall "../vesc" Bash "$S"
if [ "$rc" = 2 ] && [ ! -e "$TMP/vesc.denied" ] && [ -e "$TMP/vstate/___vesc.denied" ]; then pass "a session id with path characters is sanitised into the state dir"; else fail "session id sanitiser (rc=$rc)"; fi
vcall "" Bash "$S"
if [ "$rc" = 0 ] && ! logged ""; then pass "an empty session id allows and logs nothing"; else fail "empty session id (rc=$rc)"; fi
# an oracle that passes the canary but crashes on the real question is cannot-tell
mkdir -p "$TMP/stub4"
cp "$VHOOK" "$TMP/stub4/block-vault-sweep.sh"
# shellcheck disable=SC2016  # the stub's own $(cat) and $in, written literally
printf '#!/bin/sh\nin=$(cat)\ncase "$in" in *"\\"command\\":\\"higgsfield salus\\""*) exit 2 ;; esac\nexit 1\n' >"$TMP/stub4/block-agent-native-egress.sh"
VHOOK_ALT="$TMP/stub4/block-vault-sweep.sh" salus_row "an oracle that passes the canary and crashes on the real question: silent, nothing logged" v55
# the hook is not inert: a clean session with lists planted elsewhere still logs and is refused
printf '%s\n' "$TMP/elsewhere" >"$CG/phi-roots"
printf '%s\n' "$TMP/elsewhere2" >"$CG/egress-denylist"
vcall v40 Bash "$S"
a=$rc
vcall v40q Bash 'qmd query -c luna "meeting notes"'
if [ "$a" = 2 ] && jq -e -s 'any(.[]; .session_id == "v40" and .event == "deny") and any(.[]; .session_id == "v40q" and .event == "qmd_clear")' "$VLOG" >/dev/null 2>&1; then pass "a non-salus session with PHI lists planted elsewhere is still refused and logged"; else fail "non-salus still refused/logged (sweep=$a)"; fi
rm -f "$CG/phi-roots" "$CG/egress-denylist"

# 16e. Reading the helper is not a qmd call: only a real invocation clears the deny and counts as a conversion.
vcall v24 Bash "$S"
a=$rc
vcall v24 Bash "cat $ROOT/scripts/lib/qmd-bounded.sh"
vcall v24b Bash "echo qmd-bounded.sh; cat $ROOT/scripts/lib/qmd-bounded.sh"
vcall v24b Bash "$S"
if [ "$a" = 2 ] && [ "$rc" = 2 ] && ! jq -e -s 'any(.[]; (.session_id == "v24" or .session_id == "v24b") and .event == "qmd_clear")' "$VLOG" >/dev/null 2>&1; then pass "cat or echo of qmd-bounded.sh is no qmd call: no conversion, the deny stands"; else fail "qmd-bounded.sh named but not run (first=$a later=$rc)"; fi

# 16f. rg --color takes a value; grep --color does not. And the hooks.json matcher covers every tool the hook reads.
vrows 0 color "rg --color never HIMMEL-8847 $VAULT"
vrows 2 color2 "rg --color never notes $VAULT" "grep -rn --color notes $VAULT"
HJ="$ROOT/marketplace/plugins/himmel-ops/hooks/hooks.json"
vm=$(jq -r '[.hooks.PreToolUse[] | select(any(.hooks[]; (.command // "") | contains("block-vault-sweep.sh"))) | .matcher] | if length == 1 then .[0] else "" end' "$HJ" 2>/dev/null)
mok=1
[ -n "$vm" ] || mok=0
mre="^($vm)\$"
for t in Bash Grep mcp__qmd__query mcp__plugin_qmd_qmd__query; do [[ "$t" =~ $mre ]] || mok=0; done
for t in Read Edit WebFetch; do [[ "$t" =~ $mre ]] && mok=0; done
if [ "$mok" = 1 ]; then pass "hooks.json: one block-vault-sweep.sh entry whose matcher covers Bash, Grep and both qmd MCP names and nothing else"; else fail "hooks.json matcher pin (matcher='$vm')"; fi

# 17. Known residual: a heredoc line that is itself a vault sweep is refused (counted as a false refusal), once.
vcall v14 Bash $'cat > note.md <<EOF\ngrep -r notes '"$VAULT"$'\nEOF'
a=$rc
vcall v14 Bash $'cat > note.md <<EOF\ngrep -r notes '"$VAULT"$'\nEOF'
if [ "$a" = 2 ] && [ "$rc" = 0 ]; then pass "heredoc sweep line: refused once, then the retry passes (bounded false refusal)"; else fail "heredoc residual (first=$a retry=$rc)"; fi

# 18. The log carries enough to classify a refusal and to count conversions.
long="grep -rl notes $VAULT$(printf ' word%.0s' $(seq 1 60))"
vcall v15 Bash "$long"
vcall v16 Bash "grep -rl notes $VAULT --include=ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789abcdef"
if jq -e -s '
    ([.[] | select(.event == "deny")] | length) as $d
    | ([.[] | select(.event == "retry_allowed")] | length) as $r
    | ([.[] | select(.event == "qmd_clear" and .had_deny == true)] | length) as $c
    | ([.[] | select(.event == "qmd_clear" and .had_deny == false)] | length) as $n
    | $d >= 5 and $r >= 2 and $c == 1 and $n >= 3
      and all(.[]; has("ts") and has("session_id") and has("event") and has("tool"))
      and all(.[]; keys == ["cwd","event","had_deny","root","session_id","tool","ts"])
      and all(.[]; .root | IN("luna","clippings",""))
      and all(.[] | select(.event == "deny" or .event == "retry_allowed"); .root | IN("luna","clippings"))' "$VLOG" >/dev/null 2>&1; then
    pass "log rows: deny/retry_allowed/qmd_clear with had_deny; exactly the seven keys on every row (no command, no pattern), and the root is a fixed label"
else
    fail "log rows"
fi

if [ "$FAILED" -gt 0 ]; then echo "$FAILED failed"; exit 1; fi
echo "all passed"
