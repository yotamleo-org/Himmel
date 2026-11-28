#!/usr/bin/env bash
# shellcheck disable=SC2016,SC2329
set -uo pipefail

LIBDIR="$(cd "$(dirname "$0")" && pwd)"
LIB="$LIBDIR/lane-grants.sh"
[ -f "$LIB" ] || { echo "lib not found: $LIB" >&2; exit 1; }
command -v git >/dev/null 2>&1 || { echo "SKIP: git not on PATH"; exit 0; }
command -v jq  >/dev/null 2>&1 || { echo "SKIP: jq not on PATH"; exit 0; }

T="$(mktemp -d "${TMPDIR:-/tmp}/lane-grants.XXXXXX")" || exit 1
T="$(cd "$T" && pwd -P)" || exit 1
trap 'rm -rf "$T"' EXIT
export HOME="$T/home" XDG_CONFIG_HOME="$T/home/.config" GIT_CONFIG_NOSYSTEM=1
export HIMMEL_POLICY_FOLLOWS_HOME=1
unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_CONFIG GIT_CONFIG_GLOBAL GIT_CONFIG_SYSTEM \
    GIT_CONFIG_COUNT GIT_CONFIG_PARAMETERS
mkdir -p "$HOME/.himmel"
chmod 700 "$HOME/.himmel"
CFG="$HOME/.himmel/config.json"
PIN='github.com/acme/fixture'

mkclone() {
    git init -q -b main "$1" &&
    git -C "$1" -c user.name=t -c user.email=t@example.invalid commit -q --allow-empty -m init &&
    git -C "$1" remote add origin "$2" &&
    git -C "$1" worktree add -q -b feat/x "$3"
}
PRIMARY="$T/primary"; WT="$T/wt"
mkclone "$PRIMARY" 'https://github.com/acme/fixture.git' "$WT" || exit 1
PRIMARY2="$T/primary2"; WT2="$T/wt2"
mkclone "$PRIMARY2" 'https://github.com/acme/other.git' "$WT2" || exit 1
mkdir -p "$T/nonrepo"
export CLAUDE_PROJECT_DIR="$PRIMARY"

# shellcheck source=load-dotenv.sh
. "$LIBDIR/load-dotenv.sh"
# shellcheck source=nwo.sh
. "$LIBDIR/nwo.sh"
# shellcheck source=../guardrails/lib.sh
. "$LIBDIR/../guardrails/lib.sh"
# shellcheck source=lane-grants.sh
. "$LIB"

pass=0; fail=0
ok()  { pass=$((pass+1)); }
bad() { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }
expect_rc() {
    if [ "$2" = "$3" ]; then ok; else bad "$1 (want rc $2 got $3)"; fi
}

ALL='["git-push-branch","gh-pr-create","net-read","manage-task-own"]'
write_cfg() {
    rm -f "$CFG"
    printf '%s\n' "$1" > "$CFG"
    chmod 600 "$CFG"
}
all_on() {
    write_cfg "{\"lane_grants\":{\"codex\":$ALL,\"antigravity\":$ALL},\"lane_grants_origin\":\"$PIN\"}"
}
payload() {
    jq -cn --arg c "$1" --arg d "${2:-$WT}" --arg l "${3:-codex}" \
        '{tool_name:"Bash",tool_input:{command:$c},cwd:$d,himmel_lane:$l}'
}
accept() {
    local got
    got=$(lane_grant_shape "$(payload "$3")") || got=
    if [ "$got" = "$2" ]; then ok; else bad "accept $1 (want $2 got '$got')"; fi
}
refuse_payload() {
    local got rc=0
    got=$(lane_grant_shape "$2") || rc=$?
    if [ "$rc" != 0 ] && [ -z "$got" ]; then ok; else bad "refuse $1 (rc $rc got '$got')"; fi
}
refuse() { refuse_payload "$1" "$(payload "$2")"; }

echo "== T8 fail closed =="
all_on
lane_grant_has codex net-read; expect_rc "T8p well-formed 600 file in a 700 dir" 0 $?
lane_grant_has antigravity manage-task-own; expect_rc "T8p manage-task-own antigravity" 0 $?
lane_grant_has codex manage-task-own; expect_rc "manage-task-own is never held by codex" 1 $?
lane_grant_has claude net-read; expect_rc "unknown lane" 1 $?
lane_grant_has codex push-anything; expect_rc "unknown capability" 1 $?
has_none() { local rc=0; lane_grant_has codex net-read || rc=$?; expect_rc "T8 $1" 1 "$rc"; }
write_cfg '{"lane_grants":{"codex":["net-read"]'; has_none "malformed JSON"
write_cfg '{"lane_grants":{"codex":["net-read"]}} {"lane_grants":{"codex":["net-read"]}}'; has_none "two documents"
write_cfg '{"lane_grants":"net-read"}'; has_none "lane_grants a string"
write_cfg '{"lane_grants":{"codex":{"net-read":true}}}'; has_none "lane value an object"
write_cfg '{"lane_grants":{"codex":["net-read",1]}}'; has_none "lane value holds a non-string"
no_mode() { local rc=0; ( lane_config_find() { return 0; }; lane_grant_has codex net-read ) || rc=$?; expect_rc "T8 $1" 1 "$rc"; }
all_on; mv "$CFG" "$T/real.json"; ln -s "$T/real.json" "$CFG"; has_none "symlinked file"; no_mode "symlinked file alone"
rm -f "$CFG"; all_on
mv "$HOME/.himmel" "$HOME/.himmel-real"; ln -s "$HOME/.himmel-real" "$HOME/.himmel"; has_none "symlinked .himmel"; no_mode "symlinked .himmel alone"
rm -f "$HOME/.himmel"; mv "$HOME/.himmel-real" "$HOME/.himmel"
all_on; chmod 664 "$CFG"; has_none "file mode 664"
all_on; chmod 602 "$CFG"; has_none "file mode 602"
all_on; chmod 775 "$HOME/.himmel"; has_none "dir mode 775"
chmod 700 "$HOME/.himmel"
( lane_config_owner_ok() { return 1; }; lane_grant_has codex net-read ); expect_rc "T8 owner seam failing" 1 $?
( lane_config_find() { return 1; }; lane_grant_has codex net-read ); expect_rc "T8 find seam failing" 1 $?
mkdir -p "$T/elsewhere/.himmel"; chmod 700 "$T/elsewhere/.himmel"; cp "$CFG" "$T/elsewhere/.himmel/config.json"
( _himmel_policy_dir() { printf '%s' "$T/elsewhere/.himmel"; }; lane_grant_has codex net-read ); expect_rc "T8 the two config paths differ" 1 $?
( unset -f _cmg_canon_nwo; lane_grant_has codex net-read ); expect_rc "T8 a required helper undefined" 1 $?
write_cfg "{\"lane_grants\":{\"codex\":$ALL}}"
lane_grant_has codex git-push-branch; expect_rc "push without a pin is not held" 1 $?
lane_grant_has codex gh-pr-create; expect_rc "pr without a pin is not held" 1 $?
lane_grant_has codex net-read; expect_rc "net-read needs no pin" 0 $?
write_cfg "{\"lane_grants\":{\"codex\":$ALL},\"lane_grants_origin\":\"fixture\"}"
lane_grant_has codex git-push-branch; expect_rc "a pin that is not a repo is not held" 1 $?

echo "== I1 under set -euo pipefail =="
all_on
strict() {
    local out rc=0
    out=$(bash -c 'set -euo pipefail
        . "$1/load-dotenv.sh"; . "$1/nwo.sh"; . "$1/../guardrails/lib.sh"; . "$1/lane-grants.sh"
        eval "$2"
        x=$(lane_grant_shape "$3") || x=
        h=held; lane_grant_has codex git-push-branch || h=none
        printf "shape=%s %s" "$x" "$h"' _ "$LIBDIR" "$2" "$(payload 'git push origin feat/x')" 2>/dev/null) || rc=$?
    if [ "$rc" = 0 ] && [ "${out%% *}" = "shape=" ]; then ok; else bad "I1 $1 (rc $rc out '$out')"; fi
}
strict "git read failure" 'git() { return 128; }'
strict "jq failure" 'jq() { return 5; }'
strict "missing helper" 'unset -f primary_checkout_root'

echo "== T9 lexer =="
sweep() {
    local n c want got
    n=1
    while [ "$n" -le 127 ]; do
        printf -v c '%b' "\\x$(printf '%02x' "$n")"
        want=1
        case $n in 9|32) want=0 ;; esac
        if [ "$n" -ge 48 ] && [ "$n" -le 57 ]; then want=0; fi
        if [ "$n" -ge 65 ] && [ "$n" -le 90 ]; then want=0; fi
        if [ "$n" -ge 97 ] && [ "$n" -le 122 ]; then want=0; fi
        case $n in 95|46|47|58|61|64|44|43|45) want=0 ;; esac
        got=0; LC_ALL="$1" lane_grant_argv "echo a${c}b" >/dev/null 2>&1 || got=1
        if [ "$got" = "$want" ]; then ok; else bad "T9 sweep byte $n under $1 (want $want got $got)"; fi
        n=$((n+1))
    done
    for c in $'\x80' $'\xc2\xa0' $'\xe2\x80\xa8'; do
        got=0; LC_ALL="$1" lane_grant_argv "echo a${c}b" >/dev/null 2>&1 || got=1
        expect_rc "T9 non-ASCII under $1" 1 "$got"
    done
}
sweep C
UTF=$(locale -a 2>/dev/null | grep -iE '^(C|en_US)\.utf-?8$' | head -n 1)
[ -z "$UTF" ] || sweep "$UTF" 2>/dev/null
lexno() { local rc=0; lane_grant_argv "$2" >/dev/null 2>&1 || rc=1; expect_rc "T9 refuses $1" 1 "$rc"; }
lexno 'command substitution' 'echo $(x)'
lexno 'brace expansion' 'echo {a,b}'
lexno 'jobspec' 'kill %1'
lexno 'and-list' 'a && b'
lexno 'double-quoted dollar' 'echo "$HOME"'
lexno 'double-quoted backtick' 'echo "`x`"'
lexno 'double-quoted backslash' 'echo "a\b"'
lexno 'double-quoted bang' 'echo "a!"'
lexno 'open single quote' "echo 'a"
lexno 'open double quote' 'echo "a'
lexno 'word starting with =' 'echo =ls'
lexno 'newline inside quotes' $'echo \'a\nb\''
lexno 'CR inside quotes' $'echo "a\rb"'
out=$(lane_grant_argv $'gh pr\tcreate -t \'a b\'c -b \'$x `y` !\' ""'; printf .) || out=
want=$'gh\npr\ncreate\n-t\na bc\n-b\n$x `y` !\n\n.'
if [ "$out" = "$want" ]; then ok; else bad "T9p words ($out)"; fi

echo "== T17 accept forms =="
all_on
accept 'push plain' git-push-branch 'git push origin feat/x'
accept 'push -u' git-push-branch 'git push -u origin feat/x'
accept 'push --set-upstream' git-push-branch 'git push --set-upstream origin feat/x'
accept 'tab between words' git-push-branch $'git\tpush origin feat/x'
accept 'pr -H -t -b -B -d -f' gh-pr-create 'gh pr create -H feat/x -t a -b b -B main -d -f'
accept 'pr long flags' gh-pr-create 'gh pr create --head feat/x --title a --body b --base main --draft --fill'
accept 'pr joined pieces' gh-pr-create "gh pr create -H feat/x -t 'a b'c"
accept 'pr single-quoted dollar and backtick' gh-pr-create "gh pr create -H feat/x -t 'x: y' -b 'a \` and \$HOME !'"
accept 'pr empty body' gh-pr-create "gh pr create -H feat/x -t a -b ''"
for f in -g --globoff; do
    accept "curl $f" net-read "curl -q $f https://example.com/a"
done
for f in -s --silent -S --show-error -f --fail --compressed '-m 10' '--max-time 10' -sSfg; do
    accept "curl $f" net-read "curl -q -g $f https://example.com/a"
done
for f in '-O -' -O- -qO- '-qO -' --output-document=-; do
    accept "wget $f" net-read "wget --no-config --max-redirect=0 $f https://example.com/a"
done
for f in -q --quiet; do
    accept "wget $f" net-read "wget --no-config --max-redirect=0 $f -O- https://example.com/a"
done
accept 'net open default: arbitrary host, no host key' net-read "curl -q -g 'https://some-other.host.example:8443/p?q=1#f'"

echo "== fetch host lists (HIMMEL-11410) =="
hosts_cfg() { write_cfg "{\"lane_grants\":{\"codex\":[\"net-read\"]},\"lane_grants_hosts\":{\"codex\":$1}}"; }
h_refuse() { refuse "$1 $2" "curl -q -g 'https://$2/a'"; }
h_accept() { accept "$1 $2" net-read "curl -q -g 'https://$2/a'"; }
reps() { printf '%*s' "$1" '' | tr ' ' a; }
L63=$(reps 63)
HOST254="$L63.$L63.$L63.$(reps 62)"
HOST253="$L63.$L63.$L63.$(reps 61)"

hosts_cfg '{"deny":["example.com"]}'
for u in EXAMPLE.com example.com. example.com:8443; do h_refuse H6 "$u"; done
hosts_cfg '{"deny":["EXAMPLE.com."]}'
h_refuse H6 example.com
hosts_cfg '{"deny":["*.Example.COM"]}'
h_refuse H6 a.example.com
hosts_cfg '{"deny":["127.0.0.1"]}'
for u in 127.1 0x7f.0.0.1 0177.0.0.1 2130706433; do h_refuse H6 "$u"; done

for l in none '{"deny":[]}'; do
    if [ "$l" = none ]; then write_cfg '{"lane_grants":{"codex":["net-read"]}}'; else hosts_cfg "$l"; fi
    for u in EXAMPLE.com example.com. example.com:8443 127.1 0x7f.0.0.1 0177.0.0.1 2130706433 \
        'ex%61mple.com' example.com:x.y; do
        h_accept "H7 $l" "$u"
    done
done

hosts_cfg '{"deny":["other.example"]}'
for u in 'ex%61mple.com' a_b.example.com example..com example.com.. "$HOST254" "$(reps 64).example" \
    example.com:x.evil.example; do
    h_refuse H8 "$u"
done
refuse 'H8 a UTF-8 host' $'curl -q -g \'https://\xc3\xa9xample.com/\''
h_accept 'H8 253 characters' "$HOST253"
hosts_cfg '{"allow":["*.example.com"]}'
h_refuse H8 a_b.example.com

for u in a.example.com a.b.example.com A.Example.COM.; do h_accept 'H9 wildcard allow' "$u"; done
for u in example.com badexample.com; do h_refuse 'H9 wildcard allow' "$u"; done
hosts_cfg '{"allow":["example.com"]}'
h_refuse 'H9 a bare allow entry' a.example.com
for u in EXAMPLE.com example.com. example.com:8443; do h_accept 'H9 canonical host' "$u"; done
hosts_cfg '{"deny":["example.com"]}'
h_accept 'H9 a bare deny entry' a.example.com
hosts_cfg '{"allow":["example.com","*.example.com"]}'
h_accept 'H9 both entries' example.com
h_accept 'H9 both entries' a.example.com
hosts_cfg '{"allow":["example.com"],"deny":["example.com"]}'
h_refuse 'H9 deny wins' example.com
hosts_cfg '{"allow":["Example.COM."]}'
h_accept 'H9 canonical entry' example.com
all_on

echo "== shape refusals (every grant on) =="
refuse 'push another branch' 'git push origin feat/y'
refuse 'push another remote' 'git push upstream feat/x'
refuse 'env prefix (R3-F37)' 'SKIP_CR=1 git push origin feat/x'
refuse 'push -f' 'git push -f origin feat/x'
refuse 'pr other head' 'gh pr create -H feat/y -t a'
refuse 'pr repeated flag' 'gh pr create -H feat/x -t a -t b'
refuse 'pr repeated head' 'gh pr create -H feat/x --head feat/x'
refuse 'pr -t=x' 'gh pr create -H feat/x -t=x'
refuse 'pr --title=x' 'gh pr create -H feat/x --title=x'
refuse 'pr --base=main' 'gh pr create -H feat/x --base=main'
refuse 'pr bad base' "gh pr create -H feat/x --base 'a b'"
refuse 'pr flag without value' 'gh pr create -H feat/x -t'
refuse 'url with userinfo' 'curl -q -g https://u@h/a'
refuse 'two urls' 'curl -q -g https://e/a https://e/b'
refuse 'curl -K' 'curl -q -g -K f https://e/a'
refuse 'curl -T' 'curl -q -g -T f https://e/a'
refuse 'curl -L (1434)' 'curl -q -g -L https://e/a'
refuse 'curl --location (1434)' 'curl -q -g --location https://e/a'
refuse 'curl cluster with L (1434)' 'curl -q -g -sSL https://e/a'
refuse 'curl -m non-digit' 'curl -q -g -m x https://e/a'
refuse 'curl file url' 'curl -q -g file:///etc/hostname'
refuse 'curl empty authority' 'curl -q -g https:///a'
refuse 'wget without --max-redirect=0 (1434)' 'wget --no-config -qO- https://e/a'
refuse 'wget --max-redirect=1' 'wget --no-config --max-redirect=1 -qO- https://e/a'
refuse 'wget to a file' 'wget --no-config --max-redirect=0 -O f https://e/a'
refuse 'wget two outputs' 'wget --no-config --max-redirect=0 -O- -qO- https://e/a'
refuse 'wget no output' 'wget --no-config --max-redirect=0 https://e/a'
refuse_payload 'tool_input.cwd differs' \
    "$(payload 'git push origin feat/x' | jq -c '.tool_input.cwd="/tmp"')"
refuse_payload 'tool_input.workdir (T10)' \
    "$(payload 'git push origin feat/x' | jq -c --arg d "$WT" '.tool_input.workdir=$d')"
refuse_payload 'a NUL in the command string' \
    "$(payload 'curl -q -g https://e/a' | jq -c '.tool_input.command += "\u0000"')"
refuse_payload 'a cwd ending in a newline' "$(payload 'curl -q -g https://e/a' "$WT"$'\n')"
refuse_payload 'tool_name PowerShell' "$(payload 'git push origin feat/x' | jq -c '.tool_name="PowerShell"')"
refuse_payload 'no himmel_lane' "$(payload 'git push origin feat/x' | jq -c 'del(.himmel_lane)')"
git -C "$WT" checkout -q --detach
refuse 'detached HEAD' 'git push origin feat/x'
git -C "$WT" checkout -q feat/x
git -C "$WT" checkout -q -b trunk
git -C "$PRIMARY" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/trunk
refuse 'a push of the default branch when it is not main or master' 'git push origin trunk'
refuse 'a pr whose head is that default branch' 'gh pr create -H trunk -t a'
git -C "$PRIMARY" symbolic-ref --delete refs/remotes/origin/HEAD
accept 'the same branch once it is not the default' git-push-branch 'git push origin trunk'
git -C "$WT" checkout -q feat/x
git -C "$WT" tag feat/x
refuse 'a tag with the branch name' 'git push origin feat/x'
git -C "$WT" update-ref -d refs/tags/feat/x
git -C "$PRIMARY" config --add remote.origin.url 'https://github.com/acme/fixture.git'
refuse 'two origin URLs, both the pin' 'git push origin feat/x'
git -C "$PRIMARY" config --unset-all remote.origin.url
git -C "$PRIMARY" config remote.origin.url 'https://github.com/acme/fixture.git'
accept 'push again after the fixture is restored' git-push-branch 'git push origin feat/x'

echo "== origin pin =="
git -C "$PRIMARY" remote set-url origin 'transport::https://github.com/acme/fixture.git'
refuse 'a remote-helper URL' 'git push origin feat/x'
git -C "$PRIMARY" remote set-url origin 'https://evil.example/@github.com/acme/fixture.git'
refuse 'an @ in the URL path' 'git push origin feat/x'
git -C "$PRIMARY" remote set-url origin 'ssh://git@github.com/acme/fixture.git'
accept 'ssh scheme userinfo' git-push-branch 'git push origin feat/x'
git -C "$PRIMARY" remote set-url origin 'https://github.com/acme/fixture.git'

echo "== T10 scope =="
refuse_payload 'cwd in another repo' "$(payload 'git push origin feat/x' "$WT2")"
refuse_payload 'cwd not a repo' "$(payload 'curl -q -g https://e/a' "$T/nonrepo")"
( CLAUDE_PROJECT_DIR="$T/nonrepo"; got=$(lane_grant_shape "$(payload 'curl -q -g https://e/a')") || got=; [ -z "$got" ] )
expect_rc "T10 project dir not a repo" 0 $?
( cd "$WT" && CLAUDE_PROJECT_DIR="$PRIMARY2" && got=$(lane_grant_shape "$(payload 'git push origin feat/x' "$WT2")") ; [ -z "${got:-}" ] )
expect_rc "T10 payload cwd origin wins over a pinned process cwd" 0 $?
got=$( cd "$WT2" && lane_grant_shape "$(payload 'git push origin feat/x')" ) || got=
if [ "$got" = git-push-branch ]; then ok; else bad "T10 pinned payload cwd grants from an unpinned process cwd ($got)"; fi
got=$( GIT_DIR="$PRIMARY2/.git" lane_grant_shape "$(payload 'git push origin feat/x')" ) || got=
if [ "$got" = git-push-branch ]; then ok; else bad "T10 an inherited GIT_DIR does not steer the reads ($got)"; fi

echo "== check order =="
REC="$T/record"; : > "$REC"
(
    lane_config_path() { echo path >> "$REC"; return 1; }
    lane_config_find() { echo find >> "$REC"; return 1; }
    for c in 'git status' 'curl https://x' 'git push -f origin feat/x'; do
        lane_grant_shape "$(payload "$c")" >/dev/null || true
    done
    lane_grant_shape "$(payload 'git push origin feat/x' | jq -c 'del(.himmel_lane)')" >/dev/null || true
)
if [ ! -s "$REC" ]; then ok; else bad "check order: the config was read ($(cat "$REC"))"; fi
write_cfg '{"lane_grants":{"codex":[]},"lane_grants_hosts":{"codex":{"deny":["e"]}}}'
REC2="$T/record-host"; : > "$REC2"
(
    lane_net_host_ok() { echo host >> "$REC2"; }
    lane_grant_shape "$(payload 'curl -q -g https://e/a')" >/dev/null || true
)
if [ ! -s "$REC2" ]; then ok; else bad "H-order: the host check ran before the grant"; fi
all_on

echo "== report: no read of the account home when HOME is redirected =="
SENT="$T/sentinel/.himmel"; mkdir -p "$SENT"; printf '{}' > "$SENT/config.json"; chmod 000 "$SENT/config.json"
report_redirected() {
    (
        LOG="$1"
        _himmel_policy_dir() { printf '%s' "$SENT"; }
        lane_config_find() { echo "find $*" >> "$LOG"; command find "$@"; }
        jq() { echo "jq $*" >> "$LOG"; command jq "$@"; }
        lane_grants_report "$PRIMARY"
    )
}
write_cfg '{}'; : > "$T/log"; got=$(report_redirected "$T/log")
case "$got" in *'info: lane grants not checked (HOME is not the account home)'*) ok ;; *) bad "redirected HOME, no key ($got)" ;; esac
all_on; got=$(report_redirected "$T/log")
case "$got" in *'problem: the two config paths are not the same file; no grant applies'*) ok ;; *) bad "redirected HOME with the key ($got)" ;; esac
if grep -qF "$SENT" "$T/log"; then bad "redirected HOME: the sentinel path was named"; else ok; fi

echo "== report: a config that is not a regular file is never opened =="
if command -v timeout >/dev/null 2>&1; then
    rm -f "$CFG"; mkfifo "$CFG"
    got=$(timeout 10 bash -c '. "$1/load-dotenv.sh"; . "$1/nwo.sh"; . "$1/../guardrails/lib.sh"; . "$1/lane-grants.sh"
        lane_grants_report "$2"' _ "$LIBDIR" "$PRIMARY"); rc=$?
    case "$rc:$got" in 0:*'problem: config.json is not a regular file'*) ok ;; *) bad "report on a FIFO (rc $rc '$got')" ;; esac
    got=$(HOME="$T/fifo-home" timeout 10 bash -c 'mkdir -p "$HOME/.himmel" && mkfifo "$HOME/.himmel/config.json" &&
        . "$1/load-dotenv.sh" && . "$1/nwo.sh" && . "$1/../guardrails/lib.sh" && . "$1/lane-grants.sh" &&
        HIMMEL_POLICY_FOLLOWS_HOME="" && _himmel_policy_dir() { printf /nonexistent/.himmel; } && lane_grants_report' _ "$LIBDIR"); rc=$?
    case "$rc:$got" in 0:*'info: lane grants not checked'*) ok ;; *) bad "redirected report on a FIFO (rc $rc '$got')" ;; esac
    rm -f "$CFG"
else
    echo "  SKIP both FIFO rows: no timeout on this host"
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
