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
bash_case "rg --pre program -> block" block "rg --pre 'cp $T/x $CFG' salus $CFG"
bash_case "rg --pre= program -> block" block "rg --pre=/bin/true salus $CFG"

echo "== benign reads and unrelated calls =="
bash_case "cat the config -> allow" allow "cat $CFG"
bash_case "jq read of the config -> allow" allow "jq .graphify $CFG"
bash_case "grep | head of the config -> allow" allow "grep -n salus $CFG | head -5"
bash_case "grep -i case-insensitive read -> allow" allow "grep -i salus $CFG"
bash_case "rg -i case-insensitive read -> allow" allow "rg -i salus $CFG"
bash_case "ls ~/.himmel -> allow" allow "ls -la $HOME/.himmel"
bash_case "a command naming neither -> allow" allow "git status"
bash_case "config.json outside ~/.himmel -> allow" allow "cat $T/other/config.json"
run "non-matcher tool (Read) -> allow" allow "$(jq -nc --arg p "$CFG" '{tool_name:"Read",tool_input:{file_path:$p}}')"

echo "== malformed payloads =="
run "malformed JSON naming the config -> block" block "{not json $CFG"
run "malformed JSON naming nothing -> allow" allow "{not json"

echo
if [ "$fail" -eq 0 ]; then echo "OK: $pass cases passed"; exit 0; fi
echo "FAIL: $fail of $((pass+fail)) cases failed"; exit 1
