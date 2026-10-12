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

echo "== apply_patch (Codex's only edit tool, j2409d) =="
patch_case() { run "$1" "$2" "$(jq -nc --arg c "$3" '{tool_name:"apply_patch",tool_input:{command:$c}}')"; }
NL=$'\n'
patch_case "apply_patch Add File on the config -> block" block "*** Begin Patch${NL}*** Add File: $CFG${NL}+{}${NL}*** End Patch"
patch_case "apply_patch Update File on the config -> block" block "*** Begin Patch${NL}*** Update File: $CFG${NL}@@${NL}-a${NL}+b${NL}*** End Patch"
patch_case "apply_patch Delete File on the config -> block" block "*** Begin Patch${NL}*** Delete File: $CFG${NL}*** End Patch"
patch_case "apply_patch Move to the config -> block" block "*** Begin Patch${NL}*** Update File: $T/x.json${NL}*** Move to: $CFG${NL}@@${NL}*** End Patch"
patch_case "apply_patch symlink alias of the config -> block" block "*** Begin Patch${NL}*** Update File: $T/alias.json${NL}@@${NL}*** End Patch"
patch_case "apply_patch .. segment resolving to the config -> block" block "*** Begin Patch${NL}*** Add File: $HOME/.himmel/x/../config.json${NL}+{}${NL}*** End Patch"
patch_case "apply_patch CRLF header on the config -> block" block "$(printf '*** Begin Patch\r\n*** Add File: %s\r\n+{}\r\n*** End Patch' "$CFG")"
patch_case "apply_patch benign file -> allow" allow "*** Begin Patch${NL}*** Add File: $T/notes.txt${NL}+hi${NL}*** End Patch"
patch_case "apply_patch benign file mentioning the config in its body -> allow" allow "*** Begin Patch${NL}*** Add File: $T/notes.txt${NL}+see $CFG${NL}*** End Patch"
patch_case "apply_patch no parseable header naming the config -> block (fail closed)" block "bogus patch for $CFG"
patch_case "apply_patch no header, unrelated text -> allow" allow "bogus patch for $T/notes.txt"
run "apply_patch command as an array naming the config -> block" block "$(jq -nc --arg p "$CFG" '{tool_name:"apply_patch",tool_input:{command:["apply_patch", ("*** Begin Patch\n*** Add File: " + $p + "\n+{}\n*** End Patch")]}}')"
# j2409e: codex trims every header line; so must the hook.
patch_case "apply_patch trailing-space header on the config -> block" block "*** Begin Patch${NL}*** Add File: $CFG   ${NL}+{}${NL}*** End Patch"
patch_case "apply_patch leading-space header after a benign one -> block" block "*** Begin Patch${NL}*** Add File: $T/notes.txt${NL}+hi${NL}   *** Add File: $CFG${NL}+{}${NL}*** End Patch"
patch_case "apply_patch tab-led and tab-trailed header -> block" block "$(printf '*** Begin Patch\n\t*** Update File: %s\t\n@@\n*** End Patch' "$CFG")"
patch_case "apply_patch trailing-space benign header -> allow" allow "*** Begin Patch${NL}*** Add File: $T/notes.txt   ${NL}+hi${NL}*** End Patch"
run "apply_patch relative config.json with payload cwd in .himmel -> block" block "$(jq -nc --arg d "$HOME/.himmel" '{tool_name:"apply_patch",cwd:$d,tool_input:{command:"*** Begin Patch\n*** Add File: config.json\n+{}\n*** End Patch"}}')"
run "apply_patch relative config.json with payload cwd elsewhere -> allow" allow "$(jq -nc --arg d "$T" '{tool_name:"apply_patch",cwd:$d,tool_input:{command:"*** Begin Patch\n*** Add File: config.json\n+{}\n*** End Patch"}}')"

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
bash_case "CRLF-terminated plain read -> block (CR is outside the allow-list)" block "$(printf 'cat %s\r\nls\r\n' "$CFG")"
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

echo "== benign reads (structural allow-list, HIMMEL-5290 j2409c) =="
# A command naming the config is allowed only when every char is in
# [A-Za-z0-9 _./~:=,@+-], its first word is a listed reader, and no option
# puts a file in an output position. Everything quoted/redirected/chained denies.
bash_case "cat the config -> allow" allow "cat $CFG"
bash_case "jq . read of the config -> allow" allow "jq . $CFG"
bash_case "jq .graphify read -> allow" allow "jq .graphify $CFG"
bash_case "grep -i case-insensitive read -> allow" allow "grep -i salus $CFG"
bash_case "wc -c -> allow" allow "wc -c $CFG"
bash_case "head -5 -> allow" allow "head -5 $CFG"
bash_case "tail -n 3 -> allow" allow "tail -n 3 $CFG"
bash_case "stat -> allow" allow "stat $CFG"
bash_case "ls -la of the config -> allow" allow "ls -la $CFG"
bash_case "sha256sum -> allow" allow "sha256sum $CFG"
bash_case "diff of two files -> allow" allow "diff $CFG $T/other.json"
bash_case "less plain read -> block (not a listed reader: +v opens an editor)" block "less $CFG"
bash_case "less +v editor launch -> block" block "less +v $CFG"
bash_case "tail +command argument -> block" block "tail +v $CFG"
bash_case "tilde spelling plain cat -> allow" allow "cat ~/.himmel/config.json"
bash_case "ls ~/.himmel -> allow" allow "ls -la $HOME/.himmel"

echo "== over-denied on purpose =="
bash_case "jq with a quoted filter -> block (quotes are outside the allow-list)" block "jq '.graphify | keys' $CFG"
bash_case "cat with 2>/dev/null -> block (redirect chars are outside the allow-list)" block "cat $CFG 2>/dev/null"
bash_case "cat with >/dev/null -> block" block "cat $CFG >/dev/null"
bash_case "grep | head -> block" block "grep -n salus $CFG | head -5"
bash_case "quoted semicolon -> block" block "grep 'a;b' $CFG"
bash_case "trailing comment -> block" block "cat $CFG # note"
bash_case "CRLF-terminated read -> block" block "$(printf 'cat %s\r\nls\r\n' "$CFG")"
bash_case "backslash-newline continuation -> block" block "$(printf 'cat \\\n%s' "$CFG")"
bash_case "continuation then a real writer clause -> block" block "$(printf 'cat \\\n%s; cp x %s' "$CFG" "$CFG")"
bash_case "reader name glued to a program by a continuation -> block" block "$(printf 'cat\\\nx %s' "$CFG")"
bash_case "comment quote hiding a writer line -> block" block "$(printf "cat x #'\ncp %s/forged %s\n#'" "$T" "$CFG")"
bash_case "comment quote hiding a redirect line -> block" block "$(printf "cat x #'\ncat y > %s\n#'" "$CFG")"
bash_case "mid-word # then quote -> block" block "cat $CFG x#'"
bash_case "unterminated double quote -> block" block "cat $CFG \"x"
bash_case "double-quoted newline then a writer -> block" block "$(printf 'cat "a\nb" %s; cp %s/x %s' "$CFG" "$T" "$CFG")"
bash_case "ANSI-C quote outside quotes -> block" block "cat \$'x' $CFG"
bash_case ">>/dev/null-prefixed name -> block" block "cat $CFG >>/dev/nullx"
bash_case "quoted path under /dev/null -> block" block "cat $CFG >\"/dev/null/x\""
bash_case "quoted /dev/null then a real file -> block" block "cat $CFG >\"/dev/null\">$T/x"
bash_case "escaped space before # opens a quote -> block" block "$(printf 'cat a\\ #\x27\ncat \x27; cp /tmp/forged %s\n#\x27' "$CFG")"
bash_case "heredoc body quote swallowing a writer -> block" block "$(printf 'cat <<E\ncat \x27\nE\ncp /tmp/forged %s\n#\x27' "$CFG")"
bash_case "escaped # -> block" block "$(printf 'cat %s \\#' "$CFG")"
bash_case "escaped ; then # quote hiding a writer -> block" block "$(printf 'cat %s \\;#\x27\ncp /tmp/forged %s\n#\x27' "$CFG" "$CFG")"
bash_case "benign heredoc naming the config -> block" block "$(printf 'cat <<E %s\nx\nE' "$CFG")"
bash_case "here-string -> block" block "cat <<< x $CFG"
bash_case "backslash escape in a path -> block" block "cat $T/a\\ b $CFG"

echo "== structural denials (judge j2409c fixtures and the rest of the class) =="
bash_case "j2409c: quote inside \${..} then writer -> block" block "cat \"\${x#'\"'}\";cp /tmp/f $CFG;#'"
bash_case "j2409c: function definition shadows the reader -> block" block "cat () ( cp /tmp/f $CFG ); cat"
# shellcheck disable=SC2016 # the literal ${ spelling is the point
bash_case "parameter expansion -> block" block 'cat ${x} '"$CFG"
bash_case "empty parens -> block" block "cat () $CFG"
bash_case "brace group -> block" block "cat { cp /tmp/f $CFG ; }"
bash_case "brace expansion -> block" block "cat $HOME/.himmel/config.json{,.bak}"
bash_case "semicolon chain -> block" block "cat $CFG; cp /tmp/f $CFG"
bash_case "&& chain -> block" block "cat $CFG && cp /tmp/f $CFG"
bash_case "pipe to a writer -> block" block "cat $CFG | tee $CFG"
bash_case "glob in the path -> block" block "cat $HOME/.himmel/conf*.json"
bash_case "question-mark glob -> block" block "cat $HOME/.himmel/config.json?"
bash_case "backtick -> block" block "cat \`echo $CFG\`"
bash_case "jq --arg value position -> block" block "jq --arg x y . $CFG"
bash_case "jq --rawfile -> block" block "jq --rawfile x $CFG ."
bash_case "less -O logging write -> block (no quotes, still an output flag)" block "less -O $T/log $CFG"
bash_case "less -o logging write -> block" block "less -o $T/log $CFG"
bash_case "less clustered -eO -> block" block "less -eO $T/log $CFG"
bash_case "less --log-file -> block" block "less --log-file=$T/log $CFG"
bash_case "--output= option -> block" block "cat --output=$T/x $CFG"
bash_case "first word not on the list (file) -> block" block "file $CFG"
bash_case "env prefix -> block" block "env cat $CFG"
bash_case "VAR= prefix -> block" block "X=1 cat $CFG"
bash_case "cp onto config without specials -> block" block "cp $T/x $CFG"
bash_case "tab separated -> block" block "$(printf 'cat\t%s' "$CFG")"
bash_case "a command naming neither -> allow" allow "git status"
bash_case "config.json outside ~/.himmel -> allow" allow "cat $T/other/config.json"
run "non-matcher tool (Read) -> allow" allow "$(jq -nc --arg p "$CFG" '{tool_name:"Read",tool_input:{file_path:$p}}')"

echo "== malformed payloads =="
run "malformed JSON naming the config -> block" block "{not json $CFG"
run "malformed JSON naming nothing -> allow" allow "{not json"

echo
if [ "$fail" -eq 0 ]; then echo "OK: $pass cases passed"; exit 0; fi
echo "FAIL: $fail of $((pass+fail)) cases failed"; exit 1
