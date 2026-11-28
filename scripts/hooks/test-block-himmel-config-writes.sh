#!/usr/bin/env bash
# Smoke suite for scripts/hooks/block-himmel-config-writes.sh: the
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
export HOME="$T/HoMe"
mkdir -p "$HOME/.himmel"
printf '{}\n' > "$HOME/.himmel/config.json"
ln -s "$HOME/.himmel/config.json" "$T/alias.json"

pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }

# run <label> <block|allow> <json>; a guard that hangs fails its row (rc 124)
TO=""; command -v timeout >/dev/null 2>&1 && TO="timeout 10"
run() {
    local label="$1" expect="$2" json="$3" rc got
    printf '%s' "$json" | $TO bash "$HOOK" >/dev/null 2>&1
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

echo "== HIMMEL-7888: lexical .. form and Darwin case-folding =="
{ mkdir -p "$T/elsewhere" && ln -s "$T/elsewhere" "$HOME/.himmel/L"; } || { echo "FAIL: cannot build the 7888 fixtures" >&2; exit 1; }
file_case "7888 .himmel/L/../config.json (L symlinked elsewhere) -> block" block Write "$HOME/.himmel/L/../config.json"
file_case "7888 the same through Edit -> block" block Edit "$HOME/.himmel/L/../config.json"
file_case "7888 relative .himmel/L/../config.json -> block" block Write ".himmel/L/../config.json"
file_case "7888 .himmel/L/../project.conf -> block" block Write "$HOME/.himmel/L/../project.conf"
file_case "7888 .himmel/L/../outside-contributors.json -> block" block Write "$HOME/.himmel/L/../outside-contributors.json"
file_case "7888 dot and double-slash spellings of the lexical form -> block" block Write "$HOME/.himmel/L/..//./config.json"
file_case "7888 relative path that climbs out and back in -> block" block Write "x/../../.himmel/L/../config.json"
file_case "7888 control: .himmel/L/../../notes.txt -> allow" allow Write "$HOME/.himmel/L/../../notes.txt"
file_case "7888 control: .himmel/L/../notes.txt -> allow" allow Write "$HOME/.himmel/L/../notes.txt"
file_case "7888 control: a lexical path that ends outside the config dir -> allow" allow Write "$HOME/.himmel/x/../../other/config.json"
file_case "7888 control: .himmel/notes.txt -> allow" allow Write "$HOME/.himmel/notes.txt"
case "${OSTYPE:-}" in darwin*) ;; *) [ -e /System/Library/CoreServices/SystemVersion.plist ] || file_case "7888 control (case-sensitive host): ~/.HIMMEL/config.json is a different file -> allow" allow Write "$HOME/.HIMMEL/config.json" ;; esac
export HIMMEL_GUARD_FORCE_DARWIN=1
file_case "7888 Darwin: ~/.HIMMEL/config.json -> block" block Write "$HOME/.HIMMEL/config.json"
file_case "7888 Darwin: ~/.himmel/Config.JSON -> block" block Write "$HOME/.himmel/Config.JSON"
file_case "7888 Darwin: .HIMMEL/PROJECT.CONF -> block" block Write ".HIMMEL/PROJECT.CONF"
file_case "7888 Darwin: ~/.HIMMEL/himmel.conf (station config) -> block" block Write "$HOME/.HIMMEL/himmel.conf"
file_case "7888 Darwin: ~/.HIMMEL/L/../config.json (both gaps) -> block" block Write "$HOME/.HIMMEL/L/../config.json"
file_case "7888 Darwin control: ~/.HIMMEL/notes.txt -> allow" allow Write "$HOME/.HIMMEL/notes.txt"
file_case "7888 Darwin control: a config.json elsewhere -> allow" allow Write "$T/other/Config.json"
unset HIMMEL_GUARD_FORCE_DARWIN

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
# A canonical Add File report whose + BODY merely names a guarded
# file cannot mutate that file (every body line is prefixed with +, and only the
# target headers name a path), so it is allowed; every other shape keeps the
# whole-patch rule. The target is a fresh physical scratch path - checked here,
# not assumed - and the paired denials below use real protected targets.
REPORT_DIR="$(cd "$T" && pwd -P)"
REPORT="$REPORT_DIR/report.txt"
mkdir -p "$REPORT_DIR/sub"
ln -s "$HOME/.himmel" "$T/rptlink"
if [ ! -e "$REPORT" ] && [ ! -L "$REPORT" ] && [ ! -e "$REPORT_DIR/sub/rel.txt" ] \
    && [ "$REPORT_DIR" != "$(cd "$HOME/.himmel" && pwd -P)" ] && [ ! -L "$REPORT_DIR" ]; then
    ok "report targets are fresh physical scratch paths outside the config directory"
else
    bad "report target ground truth failed"
    exit 1
fi
BODY="+see $CFG"
cwd_case() { run "$1" "$2" "$(jq -nc --arg c "$4" --argjson d "$3" '{tool_name:"apply_patch",cwd:$d,tool_input:{command:$c}}')"; }
echo "-- 8139 allow: canonical Add File report, protected name only in the + body --"
patch_case "8139 canonical scratch report mentioning the config in its body -> allow" allow "*** Begin Patch${NL}*** Add File: $REPORT${NL}$BODY${NL}*** End Patch"
patch_case "8139 + prefixed header text is report content -> allow" allow "*** Begin Patch${NL}*** Add File: $REPORT${NL}+*** Update File: $CFG${NL}*** End Patch"
patch_case "8139 two canonical scratch reports, one body mention -> allow" allow "*** Begin Patch${NL}*** Add File: $REPORT${NL}$BODY${NL}*** Add File: $REPORT_DIR/second.txt${NL}+data${NL}*** End Patch"
patch_case "8139 uppercase protected name in the body only -> allow" allow "*** Begin Patch${NL}*** Add File: $REPORT${NL}+see $HOME/.HIMMEL/CONFIG.JSON and PROJECT.CONF${NL}*** End Patch"
cwd_case "8139 absolute scratch target with a string cwd -> allow" allow "$(jq -nc --arg d "$REPORT_DIR" '$d')" "*** Begin Patch${NL}*** Add File: $REPORT${NL}$BODY${NL}*** End Patch"
cwd_case "8139 relative scratch target with an absolute string cwd -> allow" allow "$(jq -nc --arg d "$REPORT_DIR/sub" '$d')" "*** Begin Patch${NL}*** Add File: rel.txt${NL}$BODY${NL}*** End Patch"
cwd_case "8139 null cwd with an absolute scratch target -> allow" allow null "*** Begin Patch${NL}*** Add File: $REPORT${NL}$BODY${NL}*** End Patch"
echo "-- 8139 deny controls: the exception never reaches a protected or unsupported shape --"
patch_case "8139 config target after a scratch report -> block" block "*** Begin Patch${NL}*** Add File: $REPORT${NL}$BODY${NL}*** Add File: $CFG${NL}+{}${NL}*** End Patch"
patch_case "8139 symlink alias target after a scratch report -> block" block "*** Begin Patch${NL}*** Add File: $REPORT${NL}$BODY${NL}*** Add File: $T/alias.json${NL}+{}${NL}*** End Patch"
patch_case "8139 symlinked directory target (no .himmel in the header) with a body mention -> block" block "*** Begin Patch${NL}*** Add File: $T/rptlink/config.json${NL}$BODY${NL}*** End Patch"
patch_case "8139 .. segment target with a body mention -> block" block "*** Begin Patch${NL}*** Add File: $HOME/x/../.himmel/config.json${NL}$BODY${NL}*** End Patch"
patch_case "8139 move destination after a scratch report -> block" block "*** Begin Patch${NL}*** Add File: $REPORT${NL}$BODY${NL}*** Update File: $T/x.json${NL}*** Move to: $CFG${NL}@@${NL}-a${NL}+b${NL}*** End Patch"
patch_case "8139 protected move source -> block" block "*** Begin Patch${NL}*** Update File: $CFG${NL}*** Move to: $REPORT${NL}@@${NL}-a${NL}+b${NL}*** End Patch"
patch_case "8139 Update File report with a body mention (unsupported form) -> block" block "*** Begin Patch${NL}*** Update File: $REPORT${NL}@@${NL}-old${NL}+see $CFG${NL}*** End Patch"
patch_case "8139 Delete File report with a body mention (unsupported form) -> block" block "*** Begin Patch${NL}*** Delete File: $REPORT${NL}$BODY${NL}*** End Patch"
patch_case "8139 unprefixed body mention -> block" block "*** Begin Patch${NL}*** Add File: $REPORT${NL}see $CFG${NL}*** End Patch"
patch_case "8139 missing End Patch -> block" block "*** Begin Patch${NL}*** Add File: $REPORT${NL}$BODY"
patch_case "8139 missing Begin Patch -> block" block "*** Add File: $REPORT${NL}$BODY${NL}*** End Patch"
patch_case "8139 payload after End Patch -> block" block "*** Begin Patch${NL}*** Add File: $REPORT${NL}$BODY${NL}*** End Patch${NL}*** Add File: $CFG${NL}+{}"
patch_case "8139 padded deceptive header after a report -> block" block "*** Begin Patch${NL}*** Add File: $REPORT${NL}$BODY${NL}   *** Add File: $CFG${NL}+{}${NL}*** End Patch"
patch_case "8139 trailing-space report header with a body mention -> block" block "*** Begin Patch${NL}*** Add File: $REPORT   ${NL}$BODY${NL}*** End Patch"
patch_case "8139 NBSP-trailing report header with a body mention -> block" block "$(printf '*** Begin Patch\n*** Add File: %s\xc2\xa0\n+see %s\n*** End Patch' "$REPORT" "$CFG")"
patch_case "8139 CRLF report with a body mention -> block" block "$(printf '*** Begin Patch\r\n*** Add File: %s\r\n+see %s\r\n*** End Patch' "$REPORT" "$CFG")"
patch_case "8139 empty Add File path with a body mention -> block" block "*** Begin Patch${NL}*** Add File: ${NL}$BODY${NL}*** End Patch"
patch_case "8139 empty patch followed by a stray body mention -> block" block "*** Begin Patch${NL}*** End Patch${NL}$BODY"
run "8139 array payload with a harmless target and a body mention -> block" block "$(jq -nc --arg c "*** Begin Patch${NL}*** Add File: $REPORT${NL}$BODY${NL}*** End Patch" '{tool_name:"apply_patch",tool_input:{command:["apply_patch",$c]}}')"
run "8139 competing payload field naming the config -> block" block "$(jq -nc --arg c "*** Begin Patch${NL}*** Add File: $REPORT${NL}$BODY${NL}*** End Patch" --arg p "$CFG" '{tool_name:"apply_patch",tool_input:{command:$c,patch:$p}}')"
run "8139 non-string command with a body mention -> block" block "$(jq -nc --arg p "$CFG" '{tool_name:"apply_patch",tool_input:{command:{x:$p}}}')"
run "8139 guarded name in payload metadata -> block" block "$(jq -nc --arg c "*** Begin Patch${NL}*** Add File: $REPORT${NL}+hi${NL}*** End Patch" --arg s "$CFG" '{tool_name:"apply_patch",session_id:$s,tool_input:{command:$c}}')"
echo "-- 8139 boundary: case-folded guarded spellings keep the textual refusal --"
patch_case "8139 uppercase config name in the report header -> block" block "*** Begin Patch${NL}*** Add File: $HOME/.himmel/CONFIG.JSON${NL}$BODY${NL}*** End Patch"
patch_case "8139 uppercase directory and project name in the header -> block" block "*** Begin Patch${NL}*** Add File: $HOME/.HIMMEL/Project.Conf${NL}$BODY${NL}*** End Patch"
patch_case "8139 uppercase station config name in the header -> block" block "*** Begin Patch${NL}*** Add File: $HOME/.himmel/Himmel.Conf${NL}$BODY${NL}*** End Patch"
patch_case "8139 uppercase outside-review store name in the header -> block" block "*** Begin Patch${NL}*** Add File: $HOME/.himmel/Outside-Contributors.JSON${NL}$BODY${NL}*** End Patch"
cwd_case "8139 relative uppercase target resolved through a .himmel cwd -> block" block "$(jq -nc --arg d "$HOME/.himmel" '$d')" "*** Begin Patch${NL}*** Add File: CONFIG.JSON${NL}$BODY${NL}*** End Patch"
echo "-- 8139 boundary: unknown or non-string cwd is never trusted --"
patch_case "8139 relative target with no cwd -> block" block "*** Begin Patch${NL}*** Add File: rel.txt${NL}$BODY${NL}*** End Patch"
cwd_case "8139 relative target with an empty cwd -> block" block '""' "*** Begin Patch${NL}*** Add File: rel.txt${NL}$BODY${NL}*** End Patch"
cwd_case "8139 relative target with a relative cwd -> block" block '"sub"' "*** Begin Patch${NL}*** Add File: rel.txt${NL}$BODY${NL}*** End Patch"
cwd_case "8139 absolute target with a numeric cwd -> block" block 5 "*** Begin Patch${NL}*** Add File: $REPORT${NL}$BODY${NL}*** End Patch"
cwd_case "8139 absolute target with an array cwd -> block" block "$(jq -nc --arg d "$REPORT_DIR" '[$d]')" "*** Begin Patch${NL}*** Add File: $REPORT${NL}$BODY${NL}*** End Patch"
cwd_case "8139 absolute target with an object cwd -> block" block "$(jq -nc --arg d "$REPORT_DIR" '{d:$d}')" "*** Begin Patch${NL}*** Add File: $REPORT${NL}$BODY${NL}*** End Patch"
cwd_case "8139 absolute target with a boolean cwd -> block" block true "*** Begin Patch${NL}*** Add File: $REPORT${NL}$BODY${NL}*** End Patch"
cwd_case "8139 relative target with a newline-bearing cwd -> block" block "$(jq -nc --arg d "$REPORT_DIR/sub
x" '$d')" "*** Begin Patch${NL}*** Add File: rel.txt${NL}$BODY${NL}*** End Patch"
echo "-- 8139 bounds: the existing caps still deny the exception path --"
many="*** Begin Patch"
i=0
while [ "$i" -lt 1001 ]; do many="$many${NL}*** Add File: $REPORT_DIR/m$i.txt${NL}+x"; i=$((i + 1)); done
patch_case "8139 1001 report headers with a body mention -> block (header cap)" block "$many${NL}$BODY${NL}*** End Patch"
longname="$(printf 'a%.0s' $(seq 1 4100))"
patch_case "8139 over-long report header with a body mention -> block (line cap)" block "*** Begin Patch${NL}*** Add File: $REPORT_DIR/$longname${NL}$BODY${NL}*** End Patch"
big="$(printf 'b%.0s' $(seq 1 1000))"
bigpatch="*** Begin Patch${NL}*** Add File: $REPORT${NL}$BODY"
i=0
while [ "$i" -lt 540 ]; do bigpatch="$bigpatch${NL}+$big"; i=$((i + 1)); done
bigjson="$(printf '%s' "$bigpatch${NL}*** End Patch" | jq -Rsc '{tool_name:"apply_patch",tool_input:{command:.}}')"
if [ "${#bigjson}" -gt 524288 ]; then
    run "8139 patch over the byte cap with a body mention -> block (size cap)" block "$bigjson"
else
    bad "8139 over-cap payload was not built (${#bigjson} bytes)"
fi
pad="$(printf 'c%.0s' $(seq 1 380))"
near="*** Begin Patch"
i=0
while [ "$i" -lt 999 ]; do near="$near${NL}*** Add File: $REPORT_DIR/n$i.txt${NL}+$pad"; i=$((i + 1)); done
neardoc="$(printf '%s' "$near${NL}$BODY${NL}*** End Patch" | jq -Rsc '{tool_name:"apply_patch",tool_input:{command:.}}')"
if [ "${#neardoc}" -gt 400000 ] && [ "${#neardoc}" -lt 524288 ]; then
    nearstart=$SECONDS
    run "8139 near-cap canonical patch (999 reports + body mention) -> allow inside the hook budget" allow "$neardoc"
    printf '  note near-cap canonical row took ~%ss (budget 10s row timeout)\n' "$((SECONDS - nearstart))"
else
    bad "8139 near-cap payload was not built (${#neardoc} bytes)"
fi
if [ ! -e "$REPORT" ] && [ ! -e "$REPORT_DIR/sub/rel.txt" ]; then ok "8139 no row created a report target (the hook only classifies)"; else bad "8139 a report target exists after the rows"; fi
patch_case "apply_patch no parseable header naming the config -> block (fail closed)" block "bogus patch for $CFG"
patch_case "apply_patch no header, unrelated text -> allow" allow "bogus patch for $T/notes.txt"
run "apply_patch command as an array naming the config -> block" block "$(jq -nc --arg p "$CFG" '{tool_name:"apply_patch",tool_input:{command:["apply_patch", ("*** Begin Patch\n*** Add File: " + $p + "\n+{}\n*** End Patch")]}}')"
# codex trims every header line; so must the hook.
patch_case "apply_patch trailing-space header on the config -> block" block "*** Begin Patch${NL}*** Add File: $CFG   ${NL}+{}${NL}*** End Patch"
patch_case "apply_patch leading-space header after a benign one -> block" block "*** Begin Patch${NL}*** Add File: $T/notes.txt${NL}+hi${NL}   *** Add File: $CFG${NL}+{}${NL}*** End Patch"
patch_case "apply_patch tab-led and tab-trailed header -> block" block "$(printf '*** Begin Patch\n\t*** Update File: %s\t\n@@\n*** End Patch' "$CFG")"
# codex trims Unicode White_Space (str::trim), bash [[:space:]] does not.
patch_case "apply_patch NBSP-trailing header on the config -> block" block "$(printf '*** Begin Patch\n*** Add File: %s\xc2\xa0\n+{}\n*** End Patch' "$CFG")"
patch_case "apply_patch U+2003-leading header after a benign one -> block" block "$(printf '*** Begin Patch\n*** Add File: %s/notes.txt\n+hi\n\xe2\x80\x83*** Add File: %s\n+{}\n*** End Patch' "$T" "$CFG")"
patch_case "apply_patch U+3000 inside the patch near the config header -> block" block "$(printf '*** Begin Patch\n\xe3\x80\x80*** Update File: %s\xe3\x80\x80\n@@\n*** End Patch' "$CFG")"
ln -s "$HOME/.himmel" "$T/linkdir"
run "apply_patch relative path through a symlinked dir, cwd elsewhere (header check only) -> block" block "$(jq -nc --arg d "$T" '{tool_name:"apply_patch",cwd:$d,tool_input:{command:"*** Begin Patch\n*** Add File: linkdir/config.json\n+{}\n*** End Patch"}}')"
run "apply_patch benign patch with non-ASCII space, no config name -> allow" allow "$(jq -nc --arg c "$(printf '*** Begin Patch\n*** Add File: %s/notes.txt\xc2\xa0\n+hi\n*** End Patch' "$T")" '{tool_name:"apply_patch",tool_input:{command:$c}}')"
patch_case "apply_patch NBSP-trailing symlink alias header (no .himmel literal) -> block" block "$(printf '*** Begin Patch\n*** Update File: %s/alias.json\xc2\xa0\n@@\n*** End Patch' "$T")"
patch_case "apply_patch U+3000-led symlink alias header (no .himmel literal) -> block" block "$(printf '*** Begin Patch\n\xe3\x80\x80*** Update File: %s/alias.json\n@@\n*** End Patch' "$T")"
patch_case "apply_patch trailing-space benign header -> allow" allow "*** Begin Patch${NL}*** Add File: $T/notes.txt   ${NL}+hi${NL}*** End Patch"
run "apply_patch relative config.json with payload cwd in .himmel -> block" block "$(jq -nc --arg d "$HOME/.himmel" '{tool_name:"apply_patch",cwd:$d,tool_input:{command:"*** Begin Patch\n*** Add File: config.json\n+{}\n*** End Patch"}}')"
run "apply_patch relative config.json with payload cwd elsewhere -> allow" allow "$(jq -nc --arg d "$T" '{tool_name:"apply_patch",cwd:$d,tool_input:{command:"*** Begin Patch\n*** Add File: config.json\n+{}\n*** End Patch"}}')"
# BSD readlink (macOS) has no -m: the shim refuses -m and runs the
# real readlink for everything else. The guard must still resolve a symlink or
# `..` alias of the config through the portable resolver, never skip it.
REAL_READLINK="$(command -v readlink)"
# shellcheck disable=SC2016 # $1 and "$@" belong to the generated shim
{ mkdir -p "$T/bsd-bin" &&
  printf '#!/bin/sh\ncase "$1" in -m) echo called >>"%s"; echo "readlink: illegal option -- m" >&2; exit 1 ;; esac\nexec %s "$@"\n' "$T/bsd-bin/calls" "$REAL_READLINK" >"$T/bsd-bin/readlink" &&
  chmod +x "$T/bsd-bin/readlink"; } || { echo "FAIL: cannot create the fake readlink" >&2; exit 1; }
bsd_case() {
    local rc got
    printf '%s' "$3" | HOME="${BSD_HOME:-$HOME}" PATH="$T/bsd-bin:$PATH" bash "$HOOK" >/dev/null 2>&1
    rc=$?
    case "$rc" in 0) got=allow ;; 2) got=block ;; *) got="?(rc=$rc)" ;; esac
    if [ "$got" = "$2" ]; then ok "$1"; else bad "$1 - expected $2 got $got"; fi
}
bsd_patch_case() { bsd_case "$1" "$2" "$(jq -nc --arg c "$3" '{tool_name:"apply_patch",tool_input:{command:$c}}')"; }
bsd_file_case() { bsd_case "$1" "$2" "$(jq -nc --arg p "$3" '{tool_name:"Write",tool_input:{file_path:$p}}')"; }
bsd_patch_case "apply_patch benign file without readlink -m -> allow" allow "*** Begin Patch${NL}*** Add File: $T/notes.txt${NL}+hi${NL}*** End Patch"
if [ -s "$T/bsd-bin/calls" ]; then ok "the fake readlink ran"; else bad "the fake readlink ran - GNU readlink answered instead"; fi
bsd_patch_case "apply_patch project file without readlink -m -> block" block "*** Begin Patch${NL}*** Update File: $T/r/.himmel/project.conf${NL}@@${NL}*** End Patch"
# The portable walk answers like GNU readlink -m (symlink, dangling link, .., missing tail).
{ mkdir -p "$T/w/a" && ln -s "$T/w/a" "$T/w/abs" && ln -s ../a "$T/w/a/rel" && ln -s "$T/w/none/deep" "$T/w/dangle"; } || { echo "FAIL: cannot build the walk fixtures" >&2; exit 1; }
# shellcheck source=lib/resolve-path.sh
. "$HOOKS/lib/resolve-path.sh"
# The comparison needs a GNU readlink -m to compare against; a BSD host proves the walk through the rows below.
if [ "$(readlink -m -- / 2>/dev/null)" = "/" ]; then # swallow-ok: a readlink without -m reads empty and skips the GNU comparison
    for wp in "$T/w/abs/x" "$T/w/a/rel/f/../g" "$T/w/dangle/z" "$T/w/missing/../a/q" "$T//w///a/./"; do
        if [ "$(_hrp_walk "$wp")" = "$(readlink -m -- "$wp")" ]; then ok "7120 walk equals readlink -m: $wp"; else bad "7120 walk differs from readlink -m: $wp"; fi
    done
fi
bsd_file_case "7120 no readlink -m: symlink alias of the config -> block" block "$T/alias.json"
bsd_file_case "7120 no readlink -m: .. segment to the config -> block" block "$HOME/.himmel/x/../config.json"
bsd_file_case "7120 no readlink -m: unrelated file -> allow" allow "$T/other/config.json"
bsd_patch_case "7120 no readlink -m: apply_patch symlink alias of the config -> block" block "*** Begin Patch${NL}*** Update File: $T/alias.json${NL}@@${NL}*** End Patch"
bsd_patch_case "7120 no readlink -m: apply_patch .. segment to the config -> block" block "*** Begin Patch${NL}*** Add File: $HOME/.himmel/x/../config.json${NL}+{}${NL}*** End Patch"
# A path the resolver cannot resolve (a symlink loop) or an unresolvable config path denies; it never reads as "resolves nowhere".
{ mkdir -p "$T/loop" "$T/loophome" && ln -s l2 "$T/loop/l1" && ln -s l1 "$T/loop/l2" && ln -s "$T/loop/l1" "$T/loophome/.himmel"; } || { echo "FAIL: cannot build the symlink-loop fixtures" >&2; exit 1; }
bsd_file_case "7120 symlink loop in the target path -> block (fail-closed)" block "$T/loop/l1/x"
bsd_patch_case "7120 symlink loop in an apply_patch path -> block (fail-closed)" block "*** Begin Patch${NL}*** Add File: $T/loop/l1/x${NL}+{}${NL}*** End Patch"
bsd_bash_case() { bsd_case "$1" "$2" "$(jq -nc --arg c "$3" '{tool_name:"Bash",tool_input:{command:$c}}')"; }
bsd_bash_case "10332 no readlink -m: a copy onto a destination that cannot be resolved -> block (fail-closed)" block "cp -r x $T/loop/l1/"
bsd_bash_case "10322 no readlink -m: a path operand that cannot be resolved -> block (fail-closed)" block "ls $T/loop/l1/x"
bsd_bash_case "10322 no readlink -m: control, resolvable operands -> allow" allow "ls $T/other/notes.txt"
bsd_bash_case "10332 no readlink -m: control, a copy into an unrelated directory -> allow" allow "cp -r x $T/backup/"
BSD_HOME="$T/loophome"
bsd_file_case "7120 unresolvable config path (loop under HOME) -> block (fail-closed)" block "$T/other.txt"
bsd_patch_case "7120 unresolvable config path, apply_patch -> block (fail-closed)" block "*** Begin Patch${NL}*** Add File: $T/notes.txt${NL}+hi${NL}*** End Patch"
BSD_HOME=""
# The resolver lib missing beside the hook denies (a copy of the hook with no lib/).
{ mkdir -p "$T/nolib" && cp "$HOOK" "$T/nolib/"; } || { echo "FAIL: cannot copy the hook" >&2; exit 1; }
nolib_out="$(jq -nc --arg p "$T/other.txt" '{tool_name:"Write",tool_input:{file_path:$p}}' | bash "$T/nolib/block-himmel-config-writes.sh" 2>&1)"; nolib_rc=$?
case "$nolib_rc:$nolib_out" in 2:*resolve-path*) ok "7120 resolver lib missing -> block (fail-closed)" ;; *) bad "7120 resolver lib missing - expected block naming resolve-path, got rc=$nolib_rc" ;; esac

echo "== outside-review store (HIMMEL-9429) =="
STORE_A="$HOME/.himmel/outside-pr-approvals.jsonl"
STORE_C="$HOME/.himmel/outside-contributors.json"
file_case "Write to outside-PR approvals -> block" block Write "$STORE_A"
file_case "Edit of outside-PR approvals -> block" block Edit "$STORE_A"
file_case "MultiEdit of outside-contributors -> block" block MultiEdit "$STORE_C"
file_case "relative .himmel/outside-contributors.json -> block" block Write ".himmel/outside-contributors.json"
ln -s "$STORE_C" "$T/alias-contributors.json"
file_case "symlink resolving to outside-contributors -> block" block Write "$T/alias-contributors.json"
file_case "outside-contributors.json elsewhere -> allow" allow Write "$T/other/outside-contributors.json"
patch_case "apply_patch Add File on outside-PR approvals -> block" block "*** Begin Patch${NL}*** Add File: $STORE_A${NL}+{}${NL}*** End Patch"
patch_case "apply_patch Update File on outside-contributors -> block" block "*** Begin Patch${NL}*** Update File: $STORE_C${NL}@@${NL}-a${NL}+b${NL}*** End Patch"
patch_case "apply_patch symlinked header to outside-contributors -> block" block "*** Begin Patch${NL}*** Update File: $T/alias-contributors.json${NL}@@${NL}*** End Patch"
bash_case "redirect into outside-contributors -> block" block "echo '[]' > $STORE_C"
bash_case "tee into outside-PR approvals -> block" block "echo x | tee $STORE_A"
bash_case "starred outside-review store name -> block" block "cat $HOME/.himmel/outside-*"
bash_case "cat outside-PR approvals -> allow" allow "cat $STORE_A"
bash_case "jq read of outside-contributors -> allow" allow "jq . $STORE_C"

echo "== API role map (HIMMEL-9201) =="
ROLES="$HOME/.himmel/state/api-credit/roles.json"
mkdir -p "$HOME/.himmel/state/api-credit"
ln -s "$ROLES" "$T/alias-roles.json"
file_case "Write to the API role map -> block" block Write "$ROLES"
file_case "Edit of the API role map -> block" block Edit "$ROLES"
file_case "relative .himmel/state/api-credit/roles.json -> block" block Write ".himmel/state/api-credit/roles.json"
file_case "symlink resolving to the API role map -> block" block Write "$T/alias-roles.json"
file_case "a roles.json elsewhere -> allow" allow Write "$T/other/roles.json"
patch_case "apply_patch Add File on the API role map -> block" block "*** Begin Patch${NL}*** Add File: $ROLES${NL}+{}${NL}*** End Patch"
patch_case "apply_patch symlinked header to the API role map -> block" block "*** Begin Patch${NL}*** Update File: $T/alias-roles.json${NL}@@${NL}*** End Patch"
bash_case "redirect into the API role map -> block" block "echo '{}' > $ROLES"
bash_case "tee into the API role map -> block" block "echo x | tee $ROLES"
bash_case "cp onto the API role map -> block" block "cp $T/x $ROLES"
bash_case "cat the API role map -> allow" allow "cat $ROLES"
bash_case "jq read of the API role map -> allow" allow "jq . $ROLES"
export HIMMEL_API_CREDIT_CONFIG="$T/credit/config.json"
mkdir -p "$T/credit"
file_case "Write to the role map beside HIMMEL_API_CREDIT_CONFIG -> block" block Write "$T/credit/roles.json"
bash_case "redirect into the role map beside HIMMEL_API_CREDIT_CONFIG -> block" block "echo '{}' > $T/credit/roles.json"
bash_case "cat the role map beside HIMMEL_API_CREDIT_CONFIG -> allow" allow "cat $T/credit/roles.json"
unset HIMMEL_API_CREDIT_CONFIG
bash_case "api-roles.mjs write -> block" block "node scripts/lib/api-roles.mjs write"
bash_case "api-roles.mjs write with a path prefix -> block" block "node /x/scripts/lib/api-roles.mjs write --stdin"
bash_case "api-roles.mjs check -> allow" allow "node scripts/lib/api-roles.mjs check"
bash_case "api-roles.mjs accounts -> allow" allow "node scripts/lib/api-roles.mjs accounts judge"
bash_case "a grep for write in api-roles.mjs -> allow" allow "git grep -n write -- scripts/lib/api-roles.mjs"

echo "== Bash writes =="
bash_case "redirect into the config -> block" block "echo '{\"graphify\":{\"salus_ollama_cloud_ok\":true}}' > $CFG"
# shellcheck disable=SC2016 # the literal $HOME spelling is the point
bash_case "\$HOME spelling redirect -> block" block 'echo x > $HOME/.himmel/config.json'
bash_case "tilde spelling append -> block" block 'echo x >> ~/.himmel/config.json'
bash_case "sed -i -> block" block "sed -i 's/false/true/' $CFG"  # gnu-ok: a payload string fed to the hook, never run
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
# The quote-aware clause split must not open a hole.
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

echo "== apply_patch cost bound (HIMMEL-5351) =="
# Codex's behaviour on a PreToolUse hook timeout is undocumented, so a padded
# patch must be denied by an explicit cap and a patch at the cap must finish
# well inside the shared 60 s budget (the old per-header readlink forks cost
# ~5 ms each, ~5.4 s at 1000 headers on the dev box).
big_patch() { # big_patch <headers> [<extra header line>]
    local n="$1" i=0
    printf '*** Begin Patch\n'
    while [ "$i" -lt "$n" ]; do
        printf '*** Update File: src/dir/file%s.txt\n@@\n-a\n+b\n' "$i"
        i=$((i + 1))
    done
    [ -n "${2:-}" ] && printf '%s\n' "$2"
    printf '*** End Patch\n'
}
now_ms() { local t; t=$(date +%s%N 2>/dev/null); case "$t" in *N|"") echo $(( $(date +%s) * 1000 )) ;; *) echo $((t / 1000000)) ;; esac; }
bigjson() { jq -nc --rawfile c "$1" --arg cwd "$T/cwd" '{tool_name:"apply_patch",cwd:$cwd,tool_input:{command:$c}}'; }
big_case() { # big_case <label> <block|allow> <patch-file> [<max ms>]
    local label="$1" expect="$2" f="$3" max="${4:-}" s e got
    bigjson "$f" > "$T/big.json"
    s=$(now_ms)
    # A regressed hook must fail this row, not stall the suite: 60 s is the Codex hook budget.
    if command -v timeout >/dev/null 2>&1; then
        timeout 60 bash "$HOOK" < "$T/big.json" >/dev/null 2>&1; rc=$?
    else
        bash "$HOOK" < "$T/big.json" >/dev/null 2>&1; rc=$?
    fi
    e=$(now_ms)
    case "$rc" in 0) got=allow ;; 2) got=block ;; *) got="?(rc=$rc)" ;; esac
    if [ "$got" != "$expect" ]; then bad "$label - expected $expect got $got"; return; fi
    if [ -n "$max" ] && [ $((e - s)) -gt "$max" ]; then bad "$label - took $((e - s)) ms, bound $max ms"; return; fi
    ok "$label ($((e - s)) ms)"
}
mkdir -p "$T/cwd"
big_patch 1000 > "$T/p1000.txt"
# bash 3.2 on the macOS runner took 7.3 s here (macos-cadence run 40745067827); the 60 s hook budget is what matters.
CAP_BOUND_MS=3000; [ "$(uname -s)" = Darwin ] && CAP_BOUND_MS=20000 # prim-ok: Darwin timing budget
big_case "1000 benign headers (at the cap) -> allow inside the time bound" allow "$T/p1000.txt" "$CAP_BOUND_MS"
sed 's|src/dir/file|Src/DiR/FiLe|' "$T/p1000.txt" > "$T/p1000m.txt"
FOLD_BOUND_MS=12000; [ "$(uname -s)" = Darwin ] && FOLD_BOUND_MS=24000
HIMMEL_GUARD_FORCE_DARWIN=1 big_case "7888 Darwin seam: 1000 benign mixed-case headers (at the cap) -> allow inside the time bound" allow "$T/p1000m.txt" "$FOLD_BOUND_MS"
big_patch 1001 > "$T/p1001.txt"
big_case "1001 benign headers (over the cap) -> block" block "$T/p1001.txt"
big_patch 999 "*** Update File: $CFG" > "$T/pcfg.txt"
big_case "config header after 999 benign ones -> block" block "$T/pcfg.txt"
mkdir -p "$T/cwd/linkdir"
ln -s "$HOME/.himmel" "$T/cwd/alias"
big_patch 998 "*** Update File: alias/config.json" > "$T/palias.txt"
big_case "symlinked-dir alias header after 998 benign ones -> block" block "$T/palias.txt"
{ printf '*** Begin Patch\n*** Add File: big.txt\n'; head -c 600000 /dev/zero | tr '\0' 'x' | sed 's/^/+/'; printf '\n*** End Patch\n'; } > "$T/pbytes.txt"
big_case "over-size patch body (no config named) -> block" block "$T/pbytes.txt"
# One long header line is quadratic in uni_trim (200 KB took 40 s, 400 KB 186 s
# on the previous head), so a header line over the cap is denied before any
# per-line work; the symlinked config alias after it must not be reachable by
# running the budget out.
{ printf '*** Begin Patch\n*** Update File: '; head -c 200000 /dev/zero | tr '\0' 'a'; printf '\n*** Update File: alias/config.json\n*** End Patch\n'; } > "$T/plong.txt"
big_case "200 KB header line + symlinked config alias -> block inside the time bound" block "$T/plong.txt" 5000
{ printf '*** Begin Patch\n*** Update File: '; head -c 400000 /dev/zero | tr '\0' 'a'; printf '\n*** Update File: alias/config.json\n*** End Patch\n'; } > "$T/plong4.txt"
big_case "400 KB header line + symlinked config alias -> block inside the time bound" block "$T/plong4.txt" 5000
{ printf '*** Begin Patch\n*** Update File: '; head -c 4100 /dev/zero | tr '\0' 'a'; printf '\n*** End Patch\n'; } > "$T/pcap1.txt"
big_case "header line just over the 4096-byte cap -> block" block "$T/pcap1.txt" 5000
{ printf '*** Begin Patch\n*** Update File: '; head -c 4000 /dev/zero | tr '\0' 'a'; printf '\n*** End Patch\n'; } > "$T/pcap2.txt"
big_case "header line just under the cap -> allow" allow "$T/pcap2.txt" 5000
# The cap counts bytes: 2100 two-byte characters is 4200 bytes under a UTF-8 locale.
{ printf '*** Begin Patch\n*** Update File: '; head -c 2100 /dev/zero | tr '\0' 'x' | sed 's/x/é/g'; printf '\n*** End Patch\n'; } > "$T/pcapmb.txt"
saved_lc2="${LC_ALL-}"; LC_ALL=en_US.utf8; export LC_ALL
big_case "multibyte header line over the byte cap (locale en_US.utf8) -> block" block "$T/pcapmb.txt" 5000
LC_ALL="$saved_lc2"; export LC_ALL
# The byte cap counts bytes, not characters: 300000 two-byte characters is 600000 bytes.
{ printf '*** Begin Patch\n*** Add File: big.txt\n'; i=0; while [ "$i" -lt 3 ]; do head -c 100000 /dev/zero | tr '\0' 'x' | sed 's/x/é/g; s/^/+/'; printf '\n'; i=$((i + 1)); done; printf '*** End Patch\n'; } > "$T/pmb.txt"
saved_lc="${LC_ALL-}"; LC_ALL=en_US.utf8; export LC_ALL
big_case "multibyte body over the byte cap (locale en_US.utf8) -> block" block "$T/pmb.txt"
LC_ALL="$saved_lc"; export LC_ALL
# A header padded with alternating space/NBSP needs one trim pass per pair and
# each pass is O(length): 7.5 KB took 17 s and 15 KB 98 s on the base hook. A
# padded header must be refused outright and quickly.
{ printf '*** Begin Patch\n*** Add File: src/x.txt'; i=0; while [ "$i" -lt 2500 ]; do printf '\302\240 '; i=$((i + 1)); done; printf '\n*** End Patch\n'; } > "$T/ppad.txt"
big_case "7.5 KB alternating space/NBSP padded header -> block inside the time bound" block "$T/ppad.txt" 3000
{ printf '*** Begin Patch\n*** Add File: src/x.txt'; i=0; while [ "$i" -lt 40 ]; do printf '\302\240 '; i=$((i + 1)); done; printf '\n*** End Patch\n'; } > "$T/ppad-small.txt"
big_case "short alternating-padded header (80 chars, base allows) -> block" block "$T/ppad-small.txt"
{ printf '*** Begin Patch\n*** Add File: \302\240 src/x.txt \302\240\n*** End Patch\n'; } > "$T/ppad-ok.txt"
big_case "ordinary NBSP-padded benign header -> allow" allow "$T/ppad-ok.txt"

echo "== the per-project override, <repo>/.himmel/project.conf (HIMMEL-7424) =="
PROJ="$T/repo/.himmel/project.conf"
mkdir -p "$T/repo/.himmel"
printf 'CR_REQUIRE_CROSS_MODEL=1\n' > "$PROJ"
ln -s "$T/repo/.himmel" "$T/projlink"
file_case "Write to a project file -> block" block Write "$PROJ"
file_case "Edit of a project file -> block" block Edit "$PROJ"
file_case "relative .himmel/project.conf -> block" block Edit ".himmel/project.conf"
file_case "symlinked dir resolving to a project file -> block" block Write "$T/projlink/project.conf"
file_case "a project.conf outside .himmel -> allow" allow Write "$T/repo/project.conf"
patch_case "apply_patch Update File on a project file -> block" block "*** Begin Patch${NL}*** Update File: $PROJ${NL}@@${NL}-a${NL}+b${NL}*** End Patch"
patch_case "apply_patch symlinked dir to a project file -> block" block "*** Begin Patch${NL}*** Update File: $T/projlink/project.conf${NL}@@${NL}*** End Patch"
bash_case "redirect into a project file -> block" block "echo CR_FLOOR_FALLBACK=claude-only >> $PROJ"
bash_case "sed -i on a relative project file -> block" block "sed -i s/1/0/ .himmel/project.conf"  # gnu-ok: a payload string fed to the hook, never run
bash_case "cat a project file -> allow" allow "cat $PROJ"
bash_case "grep a project file -> allow" allow "grep -n CR_ .himmel/project.conf"

echo "== station config destinations (HIMMEL-8244 / HIMMEL-7550) =="
# These files now choose where authenticated Jira requests go. Removing any
# station-path check must fail a direct write, patch, or Bash mutation row.
unset HIMMEL_CONFIG_DIR
mkdir -p "$T/station/profiles"
printf 'JIRA_BASE_URL=https://fixture.example.invalid\n' > "$T/station/himmel.conf"
ln -s "$T/station/himmel.conf" "$HOME/.himmel/himmel.conf"
ln -s "$T/station" "$T/station-alias"
for station in "$HOME/.himmel/himmel.conf" "$HOME/.himmel/himmel.conf.local" "$T/station/himmel.conf" "$T/station/profiles/lab.conf" "$T/station-alias/profiles/lab.conf"; do
    for ft in Write Edit MultiEdit NotebookEdit; do
        file_case "$ft station $station -> block" block "$ft" "$station"
    done
    for verb in 'Add File' 'Update File' 'Delete File' 'Move to'; do
        patch_case "apply_patch $verb station $station -> block" block "*** Begin Patch${NL}*** $verb: $station${NL}*** End Patch"
    done
    # Bash's existing text-matching ceiling does not resolve symlink aliases;
    # file tools and patch headers above do resolve them.
    if [ "$station" != "$T/station-alias/profiles/lab.conf" ]; then
        bash_case "station redirect $station -> block" block "echo x > $station"
        bash_case "station tee $station -> block" block "tee $station"
        bash_case "station sed $station -> block" block "sed -i s/a/b/ $station" # gnu-ok: fixture payload, never executed
        bash_case "station cp $station -> block" block "cp $T/x $station"
        run "malformed station $station -> block" block "{not json $station"
    fi
    bash_case "station cat $station -> allow" allow "cat $station"
    file_case "Read station $station -> allow" allow Read "$station"
done
file_case "relative station local -> block" block Write .himmel/himmel.conf.local
file_case "relative station profile -> block" block Write .himmel/profiles/lab.conf
file_case "unrelated himmel.conf -> allow" allow Write "$T/unrelated/himmel.conf"
bash_case "unrelated himmel.conf -> allow" allow "cp x $T/unrelated/himmel.conf"
HIMMEL_CONFIG_DIR="$T/custom-conf"; export HIMMEL_CONFIG_DIR
mkdir -p "$HIMMEL_CONFIG_DIR/profiles"
file_case "custom config directory local -> block" block Write "$HIMMEL_CONFIG_DIR/himmel.conf.local"
file_case "custom config directory profile -> block" block Edit "$HIMMEL_CONFIG_DIR/profiles/lab.conf"
bash_case "custom config directory redirect -> block" block "echo x > $HIMMEL_CONFIG_DIR/himmel.conf"
unset HIMMEL_CONFIG_DIR
# The sanctioned writer remains callable, but is not a shell-text bypass.
bash_case "himmelctl config set remains allowed" allow "himmelctl config set tracker.teamMode on"
bash_case "himmelctl with an appended station write -> block" block "himmelctl config set tracker.teamMode on; echo x > $HOME/.himmel/himmel.conf"
repo_root="${HOOKS%/scripts/hooks}"
if HOME="$T/config-set-home" HIMMELCTL_REPO_ROOT="$T/repo" node "$repo_root/scripts/himmelctl/bin.js" config set tracker.teamMode on >"$T/config-set.out" 2>&1 \
    && grep -q '^HIMMEL_TRACKER_TEAM_MODE=on$' "$T/config-set-home/.himmel/himmel.conf"; then
    ok "himmelctl config set writes station config"
else
    bad "himmelctl config set did not write station config"
fi

echo "== a refused rm/mv leaves an audit row (HIMMEL-8401) =="
AUDIT="$HOME/.himmel/state/config-audit/audit.jsonl"
rm -f "$AUDIT"
run "rm of the config -> block" block "$(jq -nc --arg c "rm $CFG" '{tool_name:"Bash",session_id:"s-8401",tool_input:{command:$c}}')"
cfg_real=$(cd "$HOME/.himmel" && pwd -P)/config.json
if [ -f "$AUDIT" ] && jq -e --arg f "$cfg_real" 'select(.action=="denied-rm" and .file==$f and .denied==true and .session=="s-8401" and .script=="block-himmel-config-writes.sh")' "$AUDIT" >/dev/null 2>&1; then
    ok "rm refusal wrote a denied-rm row for the config"
else
    bad "rm refusal wrote no denied-rm row ($(cat "$AUDIT" 2>/dev/null))"
fi
if grep -q 'rm /' "$AUDIT" 2>/dev/null; then bad "audit row carries the command text"; else ok "audit row carries no command text"; fi
if [ -f "$CFG" ]; then ok "config still present after the refused rm"; else bad "config gone after the refused rm"; fi
rm -f "$AUDIT"
bash_case "rm of the config with a chained command -> block" block "rm $CFG; echo done"
if jq -e --arg f "$cfg_real" 'select(.action=="denied-rm" and .file==$f)' "$AUDIT" >/dev/null 2>&1; then
    ok "a chained rm records the config path without the separator"
else
    bad "a chained rm recorded the wrong path ($(cat "$AUDIT" 2>/dev/null))"
fi
# himmel.conf is a symlink here (set up above); the row names its realpath.
bash_case "mv of himmel.conf -> block" block "mv $HOME/.himmel/himmel.conf $T/x"
conf_real=$(cd "$HOME/.himmel" && readlink himmel.conf 2>/dev/null || echo "$HOME/.himmel/himmel.conf")
if jq -e --arg f "$(cd "$(dirname "$conf_real")" && pwd -P)/himmel.conf" 'select(.action=="denied-mv" and .file==$f)' "$AUDIT" >/dev/null 2>&1; then
    ok "mv refusal wrote a denied-mv row for himmel.conf"
else
    bad "mv refusal wrote no denied-mv row ($(cat "$AUDIT" 2>/dev/null))"
fi
n_before=$(wc -l 2>/dev/null < "$AUDIT" || echo 0)
bash_case "cat of the config -> allow (no row)" allow "cat $CFG"
bash_case "redirect over the config -> block (no rm row)" block "echo x > $CFG"
n_after=$(wc -l 2>/dev/null < "$AUDIT" || echo 0)
if [ "$n_before" = "$n_after" ]; then ok "a read or a non-rm write adds no audit row"; else bad "audit rows grew from $n_before to $n_after"; fi

echo "== the restore verbs are the operator's (HIMMEL-8401) =="
bash_case "session config-audit restore -> block" block "bash scripts/lib/config-audit.sh restore 20261031T120000Z-ab12"
bash_case "session config-audit accept -> block" block "bash scripts/lib/config-audit.sh --script x accept"
bash_case "session config-restore restore -> block" block "python3 scripts/telegram/config-restore.py restore 20261031T120000Z-ab12 --from 1 --chat 1"
bash_case "session config-restore enroll -> block" block "python3 scripts/telegram/config-restore.py enroll --force"
bash_case "a quoted restore verb -> block" block "bash scripts/lib/config-audit.sh 'restore' 20261031T120000Z-ab12"
bash_case "a backslash-split accept verb -> block" block "bash scripts/lib/config-audit.sh acc\\ept"
bash_case "an accept verb right before a ; -> block" block "bash scripts/lib/config-audit.sh accept; echo done"
bash_case "an accept verb inside a subshell -> block" block "(bash scripts/lib/config-audit.sh accept)"
bash_case "a sourced config_audit_main restore -> block" block ". scripts/lib/config-audit.sh; config_audit_main restore 20261031T120000Z-ab12"
bash_case "a sourced _ca_restore -> block" block "source scripts/lib/config-audit.sh && _ca_restore 20261031T120000Z-ab12 x"
bash_case "a sourced _ca_node accept -> block" block ". scripts/lib/config-audit.sh; _ca_node accept"
bash_case "an ANSI-C hex restore verb -> block" block "bash scripts/lib/config-audit.sh \$'\\x72estore' 20261031T120000Z-ab12"
bash_case "an ANSI-C octal accept verb -> block" block "bash scripts/lib/config-audit.sh \$'\\141ccept'"
bash_case "an ANSI-C upper-case hex enroll verb -> block" block "python3 scripts/telegram/config-restore.py \$'\\x45nroll'"
bash_case "a sourced config_audit_main list -> allow" allow ". scripts/lib/config-audit.sh; config_audit_main list"
bash_case "config-audit list -> allow" allow "bash scripts/lib/config-audit.sh list"
bash_case "config-audit check -> allow" allow "bash scripts/lib/config-audit.sh check"
bash_case "a grep for the restore verb in the source -> allow" allow "git grep -n restore -- scripts/lib/config-audit.sh"
echo "== the helper is spelled plainly (HIMMEL-8401 shell-parsing round) =="
bash_case "an encoded & (\\x26) does not hang the guard -> allow" allow "printf '\\x26\\n'"
bash_case "an encoded & (\\46) does not hang the guard -> allow" allow "printf '\\46\\n'"
bash_case "an encoded & (\\046) does not hang the guard -> allow" allow "printf '\\046\\n'"
bash_case "an ANSI-C & beside the helper -> block" block "bash scripts/lib/config-audit.sh \$'\\x26' list"
bash_case "a \\u-spelled restore verb -> block" block "bash scripts/lib/config-audit.sh \$'\\u0072estore' 20261031T120000Z-ab12"
bash_case "a \\U-spelled restore verb -> block" block "bash scripts/lib/config-audit.sh \$'\\U00000072estore' 20261031T120000Z-ab12"
bash_case "a \${..} default as the verb -> block" block "bash scripts/lib/config-audit.sh \${v:-restore} 20261031T120000Z-ab12"
bash_case "a \$(..) building the verb -> block" block "bash scripts/lib/config-audit.sh \$(printf rest)ore 20261031T120000Z-ab12"
bash_case "a \$VAR holding the verb -> block" block "v=restore; bash scripts/lib/config-audit.sh \$v 20261031T120000Z-ab12"
bash_case "a backtick building the verb -> block" block "bash scripts/lib/config-audit.sh \`printf rest\`ore 20261031T120000Z-ab12"
bash_case "a brace expansion building the verb -> block" block "bash scripts/lib/config-audit.sh {restore,x} 20261031T120000Z-ab12"
bash_case "node -e on the helper's JS -> block" block "node -e \"\$_CA_JS\" restore 20261031T120000Z-ab12"
bash_case "a \$NAME/ path prefix to the helper -> allow" allow "bash \"\$HIMMEL_REPO/scripts/lib/config-audit.sh\" list"

echo "== the station .env: a file-tool write is refused, the audited route is named =="
mkdir -p "$T/clone" "$T/other"
: > "$T/clone/.env"; : > "$T/other/.env"
ln -s "$T/clone/.env" "$T/clone-alias.env"
export HIMMEL_CONFIG_AUDIT_ENV_FILE="$T/clone/.env"
file_case "Write to the station .env -> block" block Write "$T/clone/.env"
file_case "Edit of the station .env -> block" block Edit "$T/clone/.env"
file_case "symlink resolving to the station .env -> block" block Write "$T/clone-alias.env"
file_case "another project's .env -> allow" allow Write "$T/other/.env"
patch_case "apply_patch Update File on the station .env -> block" block "*** Begin Patch${NL}*** Update File: $T/clone/.env${NL}@@${NL}-a${NL}+b${NL}*** End Patch"
patch_case "apply_patch on another project's .env -> allow" allow "*** Begin Patch${NL}*** Update File: $T/other/.env${NL}@@${NL}-a${NL}+b${NL}*** End Patch"
env_msg=$(printf '%s' "$(jq -nc --arg p "$T/clone/.env" '{tool_name:"Write",tool_input:{file_path:$p}}')" | bash "$HOOK" 2>&1 >/dev/null)
case "$env_msg" in *"config-audit.sh pre"*"config-audit.sh post"*) ok "the refusal names the audited route (pre and post)" ;; *) bad "the refusal does not name the audited route" ;; esac
export HIMMEL_CONFIG_AUDIT_ENV_FILE="$T/loop/l1/x"
bsd_file_case "a .env write when the station .env cannot be resolved -> block (fail-closed)" block "$T/other/.env"
bsd_file_case "a non-.env write when the station .env cannot be resolved -> allow" allow "$T/other/notes.txt"
unset HIMMEL_CONFIG_AUDIT_ENV_FILE

echo "== HIMMEL-7888 round 2: Darwin folds on the resolved forms, and the lexical form resolved =="
mkdir -p "$T/StAtIoN-Env" "$T/CoNf" "$T/CrEdIt"
: > "$T/StAtIoN-Env/.env"
ln -s "$HOME/.HIMMEL/config.json" "$T/AlCfg.json"
ln -s "$HOME/.HIMMEL/state/api-credit/roles.json" "$T/AlRoles.json"
ln -s "$HOME/.HIMMEL/outside-contributors.json" "$T/AlStore.json"
ln -s "$HOME/.HIMMEL/project.conf" "$T/AlProj.conf"
ln -s "$HOME/.HIMMEL/notes.txt" "$T/AlNotes.txt"
ln -s "$T/elsewhere/himmel.conf" "$T/CoNf/himmel.conf"
export HIMMEL_GUARD_FORCE_DARWIN=1
export HIMMEL_CONFIG_AUDIT_ENV_FILE="$T/StAtIoN-Env/.env"
file_case "7888 Darwin: Write to the station .ENV -> block" block Write "$T/StAtIoN-Env/.ENV"
patch_case "7888 Darwin: apply_patch on the station .ENV -> block" block "*** Begin Patch${NL}*** Update File: $T/StAtIoN-Env/.ENV${NL}@@${NL}-a${NL}+b${NL}*** End Patch"
file_case "7888 Darwin control: another project's .ENV -> allow" allow Write "$T/other/.ENV"
unset HIMMEL_CONFIG_AUDIT_ENV_FILE
file_case "7888 Darwin: alias to ~/.HIMMEL/config.json -> block" block Write "$T/AlCfg.json"
file_case "7888 Darwin: alias to the role map in another case -> block" block Write "$T/AlRoles.json"
file_case "7888 Darwin: alias to outside-contributors.json in another case -> block" block Write "$T/AlStore.json"
file_case "7888 Darwin control: alias to ~/.HIMMEL/notes.txt -> allow" allow Write "$T/AlNotes.txt"
patch_case "7888 Darwin: apply_patch header through an alias to the config -> block" block "*** Begin Patch${NL}*** Update File: $T/AlCfg.json${NL}@@${NL}*** End Patch"
patch_case "7888 Darwin: apply_patch header through an alias to project.conf -> block" block "*** Begin Patch${NL}*** Update File: $T/AlProj.conf${NL}@@${NL}*** End Patch"
patch_case "7888 Darwin: apply_patch header through an alias to outside-contributors.json -> block" block "*** Begin Patch${NL}*** Update File: $T/AlStore.json${NL}@@${NL}*** End Patch"
patch_case "7888 Darwin control: apply_patch header through an alias to notes.txt -> allow" allow "*** Begin Patch${NL}*** Update File: $T/AlNotes.txt${NL}@@${NL}*** End Patch"
export HIMMEL_CONFIG_DIR="$T/CoNf"
file_case "7888 Darwin: HIMMEL_CONFIG_DIR written to in another case -> block" block Write "$T/CONF/himmel.conf"
file_case "7888 Darwin control: HIMMEL_CONFIG_DIR, another file -> allow" allow Write "$T/CONF/notes.txt"
bash_case "7888 Darwin: a Bash redirect onto HIMMEL_CONFIG_DIR's himmel.conf in another case -> block" block "echo x > $T/CONF/himmel.conf"
bash_case "7888 Darwin: a Bash tee onto a HIMMEL_CONFIG_DIR profile in another case -> block" block "tee $T/CONF/profiles/lab.conf"
bash_case "7888 Darwin control: a Bash redirect onto another file in HIMMEL_CONFIG_DIR in another case -> allow" allow "echo x > $T/CONF/notes.txt"
unset HIMMEL_CONFIG_DIR
export HIMMEL_API_CREDIT_CONFIG="$T/CrEdIt/config.json"
file_case "7888 Darwin: HIMMEL_API_CREDIT_CONFIG role map written to in another case -> block" block Write "$T/CREDIT/roles.json"
file_case "7888 Darwin control: HIMMEL_API_CREDIT_CONFIG, another file -> allow" allow Write "$T/CREDIT/config.json"
bash_case "7888 Darwin: a Bash redirect onto the HIMMEL_API_CREDIT_CONFIG role map in another case -> block" block "echo x > $T/CREDIT/roles.json"
bash_case "7888 Darwin control: a Bash redirect onto another file beside the role map in another case -> allow" allow "echo x > $T/CREDIT/config.json"
unset HIMMEL_API_CREDIT_CONFIG
unset HIMMEL_GUARD_FORCE_DARWIN
ln -s "$HOME/.himmel" "$T/S"
file_case "7888 lexical form resolved: S/L/../config.json (S is ~/.himmel, L is elsewhere) -> block" block Write "$T/S/L/../config.json"
file_case "7888 control: S/L/../notes.txt -> allow" allow Write "$T/S/L/../notes.txt"

echo "== HIMMEL-7888 / HIMMEL-10322: a Bash path operand is judged by its physical location =="
bash_case "10322 redirect through a symlinked directory to himmel.conf -> block" block "echo x > $T/station-alias/himmel.conf"
bash_case "10322 cp through a symlinked directory onto himmel.conf -> block" block "cp $T/x $T/station-alias/himmel.conf"
bash_case "10322 tee through a symlinked directory onto a profile -> block" block "tee $T/station-alias/profiles/lab.conf"
bash_case "10322 sed -i through a symlinked directory on himmel.conf -> block" block "sed -i s/a/b/ $T/station-alias/himmel.conf" # gnu-ok: fixture payload, never executed
run "10322 a relative symlinked path to himmel.conf (payload cwd) -> block" block "$(jq -nc --arg c "cp x station-alias/himmel.conf" --arg d "$T" '{tool_name:"Bash",cwd:$d,tool_input:{command:$c}}')"
bash_case "10322 a symlink to the config file written by redirect -> block" block "echo x > $T/alias.json"
run "10322 a bare file name that is a symlink to the config (payload cwd) -> block" block "$(jq -nc --arg c "cp x alias.json" --arg d "$T" '{tool_name:"Bash",cwd:$d,tool_input:{command:$c}}')"
run "10322 a bare file name that is a symlink to himmel.conf (payload cwd) -> block" block "$(jq -nc --arg c "echo x > himmel.conf" --arg d "$T/station-alias" '{tool_name:"Bash",cwd:$d,tool_input:{command:$c}}')"
run "10322 control: a bare unrelated file name (payload cwd) -> allow" allow "$(jq -nc --arg c "cp x notes.txt" --arg d "$T" '{tool_name:"Bash",cwd:$d,tool_input:{command:$c}}')"
filler=""; for _i in $(seq 1 150); do filler="$filler w$_i"; done
bash_case "10322 plain words before the operand do not use up its budget -> block" block "echo$filler; cp x $T/alias.json"
bash_case "10322 control: many plain words and an unrelated operand -> allow" allow "echo$filler; cp x $T/notes.txt"
run "10322 malformed payload naming himmel.conf through a symlinked directory -> block" block "{not json $T/station-alias/himmel.conf"
run "10322 malformed payload naming a profile through a symlinked directory -> block" block "{not json $T/station-alias/profiles/lab.conf"
run "10322 unparseable JSON with the station path as a string value -> block" block "{\"tool_input\":{\"file_path\":\"$T/station-alias/himmel.conf\""
ln -s "$T/station" "$T/a,b" || { echo "FAIL: cannot build the comma fixture" >&2; exit 1; }
run "10322 malformed payload with a literal comma in a symlinked station path -> block" block "{not json $T/a,b/himmel.conf"
{ mkdir -p "$T/nojq-bin" && for _t in bash cat tr readlink dirname; do ln -sf "$(command -v "$_t")" "$T/nojq-bin/$_t"; done; } || { echo "FAIL: cannot build the jq-less PATH" >&2; exit 1; }
nojq_case() {
    local rc got
    printf '%s' "$3" | PATH="$T/nojq-bin" "$T/nojq-bin/bash" "$HOOK" >/dev/null 2>&1
    rc=$?
    case "$rc" in 0) got=allow ;; 2) got=block ;; *) got="?(rc=$rc)" ;; esac
    if [ "$got" = "$2" ]; then ok "$1"; else bad "$1 - expected $2 got $got"; fi
}
nojq_case "10322 no jq: a JSON payload with a station path through a symlinked directory -> block" block "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$T/station-alias/himmel.conf\"}}"
nojq_case "10322 no jq: control, an unrelated path through a symlinked directory -> allow" allow "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$T/station-alias/notes.txt\"}}"
run "10322 unparseable JSON with a literal comma in the station path string -> block" block "{\"tool_input\":{\"file_path\":\"$T/a,b/himmel.conf\""
run "10322 control: unparseable JSON with an unrelated string value -> allow" allow "{\"tool_input\":{\"file_path\":\"$T/station-alias/notes.txt\""
{ mkdir -p "$T/cfgreal/profiles" && ln -s "$T/cfgreal" "$T/cfglink" && ln -s "$T/elsewhere/himmel.conf" "$T/cfgreal/himmel.conf"; } || { echo "FAIL: cannot build the config-dir fixtures" >&2; exit 1; }
HIMMEL_CONFIG_DIR="$T/cfglink"; export HIMMEL_CONFIG_DIR
bash_case "10322 a profile spelled by the physical config directory when HIMMEL_CONFIG_DIR is a symlink and himmel.conf links elsewhere -> block" block "tee $T/cfgreal/profiles/lab.conf"
bash_case "10322 a local override spelled by the physical config directory when HIMMEL_CONFIG_DIR is a symlink -> block" block "echo x > $T/cfgreal/himmel.conf.local"
bash_case "10322 control: another file in the physical config directory -> allow" allow "echo x > $T/cfgreal/notes.txt"
unset HIMMEL_CONFIG_DIR
run "10322 control: malformed payload naming an unrelated file through a symlinked directory -> allow" allow "{not json $T/station-alias/notes.txt"
bash_case "10322 control: cat through a symlinked directory -> allow" allow "cat $T/station-alias/himmel.conf"
bash_case "10322 control: cp through a symlinked directory onto an unrelated file -> allow" allow "cp $T/x $T/station-alias/notes.txt"
bash_case "10322 control: redirect to a symlink of an unrelated file -> allow" allow "echo x > $T/AlNotes.txt"

echo "== HIMMEL-7888 / HIMMEL-10332: a copy or move onto the config directory =="
mkdir -p "$T/payload" "$T/backup"
bash_case "10332 cp -r onto ~/.himmel/ -> block" block "cp -r $T/payload/. $HOME/.himmel/"
bash_case "10332 cp -r onto ~/.himmel (no slash) -> block" block "cp -r $T/payload/. $HOME/.himmel"
bash_case "10332 cp -r onto the tilde spelling -> block" block "cp -r $T/payload/. ~/.himmel/"
bash_case "10332 cp -r onto the \$HOME spelling -> block" block "cp -r $T/payload/. \$HOME/.himmel/"
bash_case "10332 cp -r onto a quoted destination -> block" block "cp -r $T/payload/. \"$HOME/.himmel/\""
bash_case "10332 cp -t onto the directory -> block" block "cp -r -t $HOME/.himmel/ $T/payload/x"
bash_case "10332 cp --target-directory= onto the directory -> block" block "cp -r --target-directory=$HOME/.himmel $T/payload/x"
bash_case "10332 rsync onto ~/.himmel/ -> block" block "rsync -a $T/payload/ $HOME/.himmel/"
bash_case "10332 mv onto ~/.himmel/ -> block" block "mv $T/payload $HOME/.himmel/"
bash_case "10332 mv of a directory's contents onto the directory glob -> block" block "mv $T/payload/* $HOME/.himmel/*"
bash_case "10332 cp -r onto a relative .himmel/ -> block" block "cp -r $T/payload/. .himmel/"
bash_case "10332 cp -r onto the directory after a chained command -> block" block "echo hi; cp -r $T/payload/. $HOME/.himmel/"
bash_case "10332 cp -r onto a symlinked spelling of the directory -> block" block "cp -r $T/payload/. $T/S/"
bash_case "10332 cp -r onto the directory inside an if block -> block" block "if true; then cp -r $T/payload/. $HOME/.himmel/; fi"
bash_case "10332 cp -r onto the directory inside a for loop -> block" block "for f in a; do cp -r $T/payload/. $HOME/.himmel/; done"
bash_case "10332 cp -r onto the directory inside a brace group -> block" block "{ cp -r $T/payload/. $HOME/.himmel/; }"
bash_case "10332 control: cp -r into an unrelated directory inside an if block -> allow" allow "if true; then cp -r $T/payload/. $T/backup/; fi"
bash_case "10332 control: cp -r into an unrelated directory -> allow" allow "cp -r $T/payload/. $T/backup/"
bash_case "10332 control: rsync into an unrelated directory -> allow" allow "rsync -a $T/payload/ $T/backup/"
bash_case "10332 control: mv into an unrelated directory -> allow" allow "mv $T/payload $T/backup/"
bash_case "10332 control: copying OUT of the config directory -> allow" allow "cp -r $HOME/.himmel/. $T/backup/"
bash_case "10332 control: reading the config file -> allow" allow "cat $HOME/.himmel/config.json"
bash_case "10332 control: ls of the config directory -> allow" allow "ls $HOME/.himmel/"
bash_case "10332 control: cp onto a name that only ends like it -> allow" allow "cp -r $T/payload/. $T/not.himmelx/"
export HIMMEL_GUARD_FORCE_DARWIN=1
bash_case "10332 Darwin: cp -r onto ~/.HIMMEL/ -> block" block "cp -r $T/payload/. $HOME/.HIMMEL/"
bash_case "10332 Darwin control: cp -r into an unrelated directory -> allow" allow "cp -r $T/payload/. $T/backup/"
unset HIMMEL_GUARD_FORCE_DARWIN

echo "== a file path over the CLI's 4096 limit =="
bytes_of() { printf '%s' "$1" | wc -c | tr -d ' '; }
need_bytes() {
    local n
    n="$(bytes_of "$2")"
    case "$n" in '' | *[!0-9]*) echo "FAIL: fixture $1 could not be measured" >&2; exit 1 ;; esac
    if [ "$n" -lt "$3" ] || [ "$n" -gt "$4" ]; then echo "FAIL: fixture $1 is $n bytes, not $3 to $4" >&2; exit 1; fi
}
mkpath() {
    local p="$1/" seg n
    seg="$(printf 'a%.0s' $(seq 1 99))/"
    n="$(bytes_of "$p")"
    while [ $((n + 100)) -lt "$2" ]; do p="$p$seg"; n=$((n + 100)); done
    while [ "$n" -lt "$2" ]; do p="${p}b"; n=$((n + 1)); done
    printf '%s' "$p"
}
SP_PAD="$(printf ' %.0s' $(seq 1 4100))"
NL_PAD="$(printf '\n%.0s' $(seq 1 4100); printf x)"; NL_PAD="${NL_PAD%x}"
P4096="$(mkpath "$T/long" 4096)"
P4097="${P4096}b"
U4="$(printf '\360\237\230\200')"
SEG4=""; for _i in $(seq 1 50); do SEG4="$SEG4$U4"; done
PU="$T/wide"; for _i in $(seq 1 22); do PU="$PU/$SEG4"; done
P_NL="$T/notes.txt$NL_PAD"
need_bytes "the 4096-byte path" "$P4096" 4096 4096
need_bytes "the 4097-byte path" "$P4097" 4097 4097
need_bytes "the non-ASCII path" "$PU" 4097 1000000
P_NL_BYTES=$(($(bytes_of "$T/notes.txt") + 4100))
need_bytes "the newline-padded path" "$P_NL" "$P_NL_BYTES" "$P_NL_BYTES"
P_SP_BYTES=$(($(bytes_of "$CFG") + 4100))
need_bytes "the space-padded config path" "$CFG$SP_PAD" "$P_SP_BYTES" "$P_SP_BYTES"
file_case "Write to the config, padded past the CLI's 4096 limit -> block" block Write "$CFG$SP_PAD"
file_case "symlink resolving to the config, padded past the CLI's 4096 limit -> block" block Write "$T/alias.json$SP_PAD"
file_case "control: a benign path of exactly 4096 bytes -> allow" allow Write "$P4096"
file_case "a benign path of 4097 bytes -> block" block Write "$P4097"
file_case "a benign non-ASCII path over 4096 bytes -> block" block Write "$PU"
file_case "a benign short path followed by 4100 newlines -> block" block Write "$P_NL"
mkshim() {
    mkdir -p "$1" || return 1
    printf '#!/bin/sh\ncase "$*" in *utf8bytelength*) cat >/dev/null; [ %s = junk ] && { echo x; exit 0; }; exit 1 ;; esac\nexec "%s" "$@"\n' "$2" "$(command -v jq)" > "$1/jq" && chmod +x "$1/jq"
}
{ mkshim "$T/shim-fail" fail && mkshim "$T/shim-junk" junk; } || { echo "FAIL: cannot build the jq shims" >&2; exit 1; }
PATH="$T/shim-fail:$PATH" file_case "the path-length read fails -> block" block Write "$T/notes.txt"
PATH="$T/shim-junk:$PATH" file_case "the path-length read prints no integer -> block" block Write "$T/notes.txt"
run "NotebookEdit with a notebook_path of 4097 bytes -> block" block "$(jq -nc --arg p "$P4097" '{tool_name:"NotebookEdit",tool_input:{notebook_path:$p}}')"
LONG_ERR="$(jq -nc --arg p "$P4097" '{tool_name:"Write",tool_input:{file_path:$p}}' | $TO bash "$HOOK" 2>&1 >/dev/null)"
case "$LONG_ERR" in
    *salus*) bad "the over-limit refusal asks for a shorter path, not the config remedy - got the config remedy" ;;
    *"shorter path"*) ok "the over-limit refusal asks for a shorter path, not the config remedy" ;;
    *) bad "the over-limit refusal asks for a shorter path, not the config remedy - got: $LONG_ERR" ;;
esac

echo "== malformed payloads =="
run "malformed JSON naming the config -> block" block "{not json $CFG"
run "malformed JSON naming nothing -> allow" allow "{not json"

echo
if [ "$fail" -eq 0 ]; then echo "OK: $pass cases passed"; exit 0; fi
echo "FAIL: $fail of $((pass+fail)) cases failed"; exit 1
