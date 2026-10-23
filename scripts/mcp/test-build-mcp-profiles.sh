#!/usr/bin/env bash
# test-build-mcp-profiles.sh — the generated MCP profiles must not
# carry secret env values; they live in 0600 files the launcher shim reads.
# Platforms tested: linux
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
T="$(mktemp -d "${TMPDIR:-/tmp}/build-mcp-profiles.XXXXXX")" || exit 1; trap 'rm -rf "$T"' EXIT
FAKE="fake-key-$$-not-real"
pass=0; fail=0
ok()  { pass=$((pass+1)); echo "ok   $1"; }
bad() { fail=$((fail+1)); echo "FAIL $1"; }
# lacks <needle> <file>...: true only when grep exits 1 (no match); an error (2) is not "clean".
lacks() { grep -q -- "$@"; [ $? -eq 1 ]; }

mkdir -p "$T/home" "$T/out"
cat >"$T/home/.claude.json" <<EOF
{"mcpServers":{"obsidian-vault":{"type":"stdio","command":"node","args":["-e","process.stdout.write(process.env.OBSIDIAN_API_KEY+'|'+process.env.OBSIDIAN_HOST)"],"env":{"OBSIDIAN_API_KEY":"$FAKE","OBSIDIAN_HOST":"127.0.0.1"}}}}
EOF
unset HIMMEL_MCP_SECRETS_DIR # an inherited override could point at the real secret store
export HOME="$T/home" USERPROFILE="$T/home" HIMMEL_MCP_PROFILES_OUT="$T/out"

node "$HERE/build-mcp-profiles.mjs" >"$T/gen.log" 2>&1
P="$T/out/local.vault.json"

if [ -f "$P" ] && lacks "$FAKE" "$P" "$T/gen.log"; then ok "profile and log carry no secret value"; else bad "secret value leaked into profile or log"; fi
S="$T/home/.config/himmel/mcp-secrets/obsidian-vault/OBSIDIAN_API_KEY"
mode="$(stat -c %a "$S" 2>/dev/null || stat -f %Lp "$S")" # gnu-ok: BSD stat -f fallback
if [ -f "$S" ] && [ "$mode" = "600" ] && [ "$(cat "$S")" = "$FAKE" ]; then ok "secret stored 0600 under ~/.config"; else bad "secret file missing or not 0600"; fi
if [ -f "$P" ] && grep -q '"OBSIDIAN_HOST": "127.0.0.1"' "$P"; then ok "non-secret env stays in the profile"; else bad "non-secret env dropped"; fi

# The launcher still hands the secret to the server process.
out="$(node -e '
const p=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).mcpServers["obsidian-vault"];
const {spawnSync}=require("child_process");
const r=spawnSync(p.command,p.args,{env:{...process.env,...(p.env||{})},encoding:"utf8"});
process.stdout.write(r.stdout||"")' "$P")"
if [ "$out" = "$FAKE|127.0.0.1" ]; then ok "launcher injects the secret into the server env"; else bad "launcher did not inject secret (got '${out:0:20}')"; fi

# A loosened secret file is refused.
chmod 644 "$S"
out="$(node -e '
const p=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).mcpServers["obsidian-vault"];
const {spawnSync}=require("child_process");
const r=spawnSync(p.command,p.args,{env:{...process.env,...(p.env||{})},encoding:"utf8"});
process.stdout.write(String(r.status))' "$P")"
if [ "$out" = "1" ]; then ok "launcher refuses a 0644 secret file"; else bad "launcher accepted a 0644 secret file (status $out)"; fi

# Removing the last secret from the source config removes its file on regeneration.
cat >"$T/home/.claude.json" <<EOF
{"mcpServers":{"obsidian-vault":{"type":"stdio","command":"node","args":["-e","0"],"env":{"OBSIDIAN_HOST":"127.0.0.1"}}}}
EOF
node "$HERE/build-mcp-profiles.mjs" >"$T/gen2.log" 2>&1
if [ ! -e "$S" ]; then ok "stale secret file removed when the last secret is dropped"; else bad "stale secret file survived"; fi

# On-demand servers: a server registered ONLY in the on-demand registry (never in
# ~/.claude.json, so no default session loads it) still resolves into its profile.
# Fixture shape copied from `claude mcp get graphify` on the station.
VAULT='"obsidian-vault":{"type":"stdio","command":"node","args":["-e","0"],"env":{"OBSIDIAN_HOST":"127.0.0.1"}}'
OP='"onepassword":{"type":"stdio","command":"node","args":["-e","0"],"env":{}}'
cat >"$T/home/.claude.json" <<EOF
{"mcpServers":{$VAULT,$OP}}
EOF
OD="$T/home/.config/himmel/mcp-on-demand.json"
mkdir -p "$(dirname "$OD")"
cat >"$OD" <<EOF
{"mcpServers":{"graphify":{"type":"stdio","command":"/opt/uv/bin/graphify-mcp","args":[],"env":{}}}}
EOF
node "$HERE/build-mcp-profiles.mjs" >"$T/gen3.log" 2>&1; rc3=$?
G="$T/out/local.graph.json"
if [ "$rc3" -eq 0 ] && [ -f "$G" ] && grep -q '"graphify"' "$G" && grep -q 'graphify-mcp' "$G"; then ok "graph profile resolves graphify from the on-demand registry"; else bad "generator rc=$rc3 or graph profile missing or graphify unresolved ($(tr '\n' ' ' <"$T/gen3.log"))"; fi
if lacks '"graphify"' "$T/home/.claude.json"; then ok "on-demand server stays out of ~/.claude.json"; else bad "on-demand server leaked into ~/.claude.json"; fi

# With no ~/.claude.json at all, the registry alone is enough.
rm -f "$T/home/.claude.json" "$G"
cat >"$OD" <<EOF
{"mcpServers":{"graphify":{"type":"stdio","command":"/opt/uv/bin/graphify-mcp","args":[],"env":{}},$VAULT,$OP}}
EOF
node "$HERE/build-mcp-profiles.mjs" >"$T/gen4.log" 2>&1; rc4=$?
if [ "$rc4" -eq 0 ] && [ -f "$G" ]; then ok "registry resolves without a ~/.claude.json"; else bad "generator rc=$rc4 needs ~/.claude.json even with a registry ($(tr '\n' ' ' <"$T/gen4.log"))"; fi

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
