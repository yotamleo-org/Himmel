#!/usr/bin/env bash
# Smoke suite for scripts/hooks/block-himmel-config-writes.sh (HIMMEL-4696): the
# speed bump over ~/.himmel/config.json, the file carrying the persisted
# graphify.salus_ollama_cloud_ok opt-in. Covers direct file-tool writes,
# redirect / in-place / cp / ln writes through Bash, a symlinked file-tool
# path, and the benign reads that must stay allowed.
#
# Hermetic: temp HOME, payloads built with jq, never the real config.
# bash 3.2-safe.
set -uo pipefail

HOOKS="$(cd "$(dirname "$0")" && pwd)"
HOOK="$HOOKS/block-himmel-config-writes.sh"
[ -f "$HOOK" ] || { echo "hook not found: $HOOK" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not on PATH"; exit 0; }

T="$(mktemp -d "${TMPDIR:-/tmp}/himmel-config-hook.XXXXXX")" || exit 1
trap 'rm -rf "$T"' EXIT
export HOME="$T/home"
mkdir -p "$HOME/.himmel"
printf '{}\n' > "$HOME/.himmel/config.json"
ln -s "$HOME/.himmel/config.json" "$T/alias.json"

pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }

# run <label> <block|allow> <json>
run() {
    local label="$1" expect="$2" json="$3" rc got
    printf '%s' "$json" | bash "$HOOK" >/dev/null 2>&1
    rc=$?
    case "$rc" in 0) got=allow ;; 2) got=block ;; *) got="?(rc=$rc)" ;; esac
    if [ "$got" = "$expect" ]; then ok "$label"; else bad "$label - expected $expect got $got"; fi
}
bash_case() { run "$1" "$2" "$(jq -nc --arg c "$3" '{tool_name:"Bash",tool_input:{command:$c}}')"; }
file_case() { run "$1" "$2" "$(jq -nc --arg t "$3" --arg p "$4" '{tool_name:$t,tool_input:{file_path:$p}}')"; }

CFG="$HOME/.himmel/config.json"

echo "== file tools =="
file_case "Write to the config -> block" block Write "$CFG"
file_case "Edit of the config -> block" block Edit "$CFG"
file_case "MultiEdit of the config -> block" block MultiEdit "$CFG"
file_case "relative .himmel/config.json -> block" block Write ".himmel/config.json"
file_case "symlink resolving to the config -> block" block Write "$T/alias.json"
file_case ".. segment resolving to the config -> block" block Write "$HOME/.himmel/x/../config.json"
file_case "another file in ~/.himmel -> allow" allow Write "$HOME/.himmel/notes.txt"
file_case "a config.json elsewhere -> allow" allow Write "$T/other/config.json"

echo "== Bash writes =="
bash_case "redirect into the config -> block" block "echo '{\"graphify\":{\"salus_ollama_cloud_ok\":true}}' > $CFG"
# shellcheck disable=SC2016 # the literal $HOME spelling is the point
bash_case "\$HOME spelling redirect -> block" block 'echo x > $HOME/.himmel/config.json'
bash_case "tilde spelling append -> block" block 'echo x >> ~/.himmel/config.json'
bash_case "sed -i -> block" block "sed -i 's/false/true/' $CFG"
bash_case "jq redirect over the config -> block" block "jq '.graphify.salus_ollama_cloud_ok=true' $CFG > $T/x"
bash_case "cp onto the config -> block" block "cp $T/x $CFG"
bash_case "ln -s onto the config -> block" block "ln -s $T/x $CFG"
bash_case "tee into the config -> block" block "echo x | tee $CFG"
bash_case "command substitution -> block" block "cat \$(echo $CFG)"
bash_case "less -O logging write -> block" block "echo x | less -O $CFG"
bash_case "path-named reader program -> block" block "/tmp/cat $CFG"
bash_case "relative-path reader program -> block" block "./jq . $CFG"
bash_case "reader name plus CR is not the reader -> block" block "$(printf 'cat\r %s' "$CFG")"
bash_case "CRLF-terminated plain read still allowed" allow "$(printf 'cat %s\r\nls\r\n' "$CFG")"
bash_case "python write -> block" block "python3 -c \"open('$CFG','w').write('{}')\""
bash_case "node write -> block" block "node -e \"require('fs').writeFileSync('$CFG','{}')\""
bash_case "process substitution -> block" block "cat <(cp $T/x $CFG)"
bash_case "rg --pre program -> block" block "rg --pre 'cp $T/x $CFG' salus $CFG"
bash_case "rg single-quoted --pre= -> block" block "rg '--pre=/tmp/writer' salus $CFG"
bash_case "rg double-quoted --pre -> block" block "rg \"--pre\" /tmp/writer salus $CFG"
bash_case "rg backslash-split --pre= -> block" block "rg --p\\re=/tmp/writer salus $CFG"
bash_case "rg --pre= program -> block" block "rg --pre=/bin/true salus $CFG"
bash_case "rg plain read -> block (rg is not a reader)" block "rg -i salus $CFG"
bash_case "rg ANSI-C quoted --pre -> block" block "rg \$'--pre=/tmp/writer' salus $CFG"
# shellcheck disable=SC2016 # the literal ${x:-...} spelling is the point
bash_case "rg default-value expanded --pre -> block" block "rg \${x:---pre=/tmp/writer} salus $CFG"
bash_case "rg brace-expanded --pre -> block" block "rg --{pre,x}=/tmp/writer salus $CFG"
# HIMMEL-5290: the quote-aware clause split must not open a hole.
bash_case "read plus redirect to a real file -> block" block "cat $CFG 2>/dev/null > $T/x"
bash_case "redirect to a path under /dev/null -> block" block "cat $CFG >/dev/null/x"
bash_case "append redirect after /dev/null -> block" block "cat $CFG >/dev/null>$T/x"
bash_case "append to /dev/null-prefixed name -> block" block "cat $CFG > /dev/nullx"
bash_case "append redirect >> -> block" block "cat $CFG >> $T/x"
bash_case "quoted pipe then a real writer clause -> block" block "jq '.a | b' $CFG; cp $T/x $CFG"
bash_case "unquoted redirect after a quoted one -> block" block "cat '$CFG' '>' > $T/x"
bash_case "process substitution out -> block" block "cat $CFG >(cp /dev/stdin $T/x)"
# shellcheck disable=SC2016 # the literal $'..' spelling is the point
bash_case "ANSI-C quote hiding a redirect -> block" block "cat \$'\\'' > $CFG"
bash_case "unterminated quote -> block" block "cat $CFG 'x"

echo "== benign reads and unrelated calls =="
bash_case "cat the config -> allow" allow "cat $CFG"
bash_case "jq read of the config -> allow" allow "jq .graphify $CFG"
bash_case "grep | head of the config -> allow" allow "grep -n salus $CFG | head -5"
bash_case "grep -i case-insensitive read -> allow" allow "grep -i salus $CFG"
bash_case "ls ~/.himmel -> allow" allow "ls -la $HOME/.himmel"
# HIMMEL-5290: quoted | ; > are not clause separators or redirects, and an fd
# redirect to /dev/null is not a write.
bash_case "jq with a quoted pipe -> allow" allow "jq '.graphify | keys' $CFG"
bash_case "cat with 2>/dev/null -> allow" allow "cat $CFG 2>/dev/null"
bash_case "grep with a quoted semicolon -> allow" allow "grep 'a;b' $CFG"
bash_case "jq with a quoted > -> allow" allow "jq 'select(.n > 1)' $CFG"
bash_case "cat with >/dev/null -> allow" allow "cat $CFG >/dev/null"
bash_case "cat with >>/dev/null -> allow" allow "cat $CFG >>/dev/null"
bash_case "cat with a quoted \"/dev/null\" -> allow" allow "cat $CFG 2>\"/dev/null\""
bash_case "cat with a quoted '/dev/null' -> allow" allow "cat $CFG >'/dev/null'"
bash_case "cat with a backslash-newline continuation -> allow" allow "$(printf 'cat \\\n%s' "$CFG")"
bash_case "continuation then a real writer clause -> block" block "$(printf 'cat \\\n%s; cp x %s' "$CFG" "$CFG")"
bash_case "reader name glued to a program by a continuation (cat\\<nl>x) -> block" block "$(printf 'cat\\\nx %s' "$CFG")"
# Shell-parsing class (three escape-class findings): one row per shape.
bash_case "comment quote hiding a writer line -> block" block "$(printf "cat x #'\ncp %s/forged %s\n#'" "$T" "$CFG")"
bash_case "comment quote hiding a redirect line -> block" block "$(printf "cat x #'\ncat y > %s\n#'" "$CFG")"
bash_case "benign trailing comment -> allow" allow "cat $CFG # note"
bash_case "comment containing a quote -> allow" allow "cat $CFG # it's fine"
bash_case "mid-word # is literal, quote opens -> block" block "cat $CFG x#'"
bash_case "double quote outside quotes, unterminated -> block" block "cat $CFG \"x"
bash_case "double-quoted newline then a writer -> block" block "$(printf 'cat "a\nb" %s; cp %s/x %s' "$CFG" "$T" "$CFG")"
bash_case "ANSI-C quote outside quotes -> block" block "cat \$'x' $CFG"
bash_case ">>/dev/null-prefixed name -> block" block "cat $CFG >>/dev/nullx"
bash_case "quoted path under /dev/null -> block" block "cat $CFG >\"/dev/null/x\""
bash_case "quoted /dev/null then a real file -> block" block "cat $CFG >\"/dev/null\">$T/x"
bash_case "a command naming neither -> allow" allow "git status"
bash_case "config.json outside ~/.himmel -> allow" allow "cat $T/other/config.json"
run "non-matcher tool (Read) -> allow" allow "$(jq -nc --arg p "$CFG" '{tool_name:"Read",tool_input:{file_path:$p}}')"

echo "== malformed payloads =="
run "malformed JSON naming the config -> block" block "{not json $CFG"
run "malformed JSON naming nothing -> allow" allow "{not json"

echo
if [ "$fail" -eq 0 ]; then echo "OK: $pass cases passed"; exit 0; fi
echo "FAIL: $fail of $((pass+fail)) cases failed"; exit 1
