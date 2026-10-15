#!/usr/bin/env bash
# test-wizard-ensure-no-network.sh — `himmelctl ensure --no-network` runs only
# the manifest-declared local path and refuses everything else
# A17). Deny by default: an item with no `noNetwork` declaration
# refuses, with a reason, and none of bun, npm, git, qmd or adopt.sh is called.
#
# Sandboxed HOME, cache dir, repo root and target only; PATH stubs for bun, npm,
# git, qmd and apt-get log to STUB_LOG, which must stay empty.
#
# Covers:
#   a. fixture: a declared item converges, undeclared adopt/build/qmd/dep items
#      refuse by id with a reason, exit 1, no stub is called.
#   b. --items on an undeclared item: refused, nothing run, state byte-identical.
#   c. --no-network --prune is rejected (exit 2).
#   d. --dry-run previews the declared item only.
#   e. the shipped manifest: dry-run under --no-network calls no stub and prints
#      no network-capable command line; qmd-index and the build items refuse.
#   f. the shipped manifest's declarations are exactly the traced set.

set -euo pipefail

grepq() { local _t="$1"; shift; grep -q "$@" <<< "$_t"; }

repo_root=$(git rev-parse --show-toplevel)
# shellcheck disable=SC1091
. "$repo_root/scripts/himmelctl/test/_hermetic-home.sh"
wizard="$repo_root/scripts/himmelctl/bin.js"
command -v node >/dev/null 2>&1 || { echo "FAIL: node required" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "FAIL: jq required" >&2; exit 1; }
fail() { echo "FAIL: $1" >&2; exit 1; }
node_bin=$(command -v node)

work=$(mktemp -d "${TMPDIR:-/tmp}/ensure-nonet.XXXXXX") || exit 1
trap 'rm -rf "$work"' EXIT

# PATH stubs: every network-capable tool logs its argv and exits 0.
stubs="$work/stubs"; mkdir -p "$stubs"
for tool in bun npm git qmd apt-get sudo brew winget curl; do
  cat > "$stubs/$tool" <<SH
#!/usr/bin/env bash
echo "$tool \$*" >> "\$STUB_LOG"
exit 0
SH
  chmod +x "$stubs/$tool"
done
STUB_LOG="$work/stub.log"; : > "$STUB_LOG"
real_path="$PATH"
# stub_calls: the stub log minus the status probes the CLI itself runs (qmd
# list/status reads, the localhost MCP health check) — converge work only.
stub_calls() { grep -v -e '^qmd collection list' -e '^qmd status' -e '^curl .*localhost' -e '^curl .*127\.0\.0\.1' "$STUB_LOG" || true; }
# git is read-only for the CLI's own provenance (rev-parse, status): the stub
# logs and swallows only the network verbs and passes the rest to real git.
real_git=$(command -v git)
cat > "$stubs/git" <<SH
#!/usr/bin/env bash
for a in "\$@"; do
  case "\$a" in
    fetch|pull|clone|ls-remote|push|submodule) echo "git \$*" >> "\$STUB_LOG"; exit 0 ;;
  esac
done
exec "$real_git" "\$@"
SH
chmod +x "$stubs/git"

fixture_repo="$work/repo"
mkdir -p "$fixture_repo/scripts/install" "$fixture_repo/scripts/lib"
cat > "$fixture_repo/scripts/install/manifest.json" <<'JSON'
{
  "schemaVersion": 2,
  "harness": "claude",
  "items": [
    { "id": "local-wire", "kind": "wiring", "scopes": ["project"], "profiles": ["core", "all"], "deps": [],
      "probe": { "type": "file-exists", "path": "wire.marker" },
      "install": { "type": "wire", "target": "statusline" },
      "noNetwork": { "path": "install" } },
    { "id": "undeclared-adopt", "kind": "hook", "scopes": ["project"], "profiles": ["core", "all"], "deps": [],
      "probe": { "type": "file-exists", "path": "adopt.marker" }, "install": { "type": "adopt" } },
    { "id": "undeclared-build", "kind": "dep", "scopes": ["project"], "profiles": ["core", "all"], "deps": [],
      "probe": { "type": "file-exists", "path": "build.marker" }, "install": { "type": "build", "target": "jira-cli" } },
    { "id": "undeclared-qmd", "kind": "vault", "scopes": ["project"], "profiles": ["core", "all"], "deps": [],
      "probe": { "type": "file-exists", "path": "qmd.marker" }, "install": { "type": "qmd" } },
    { "id": "undeclared-dep", "kind": "dep", "scopes": ["project"], "profiles": ["core", "all"], "deps": [],
      "probe": { "type": "file-exists", "path": "dep.marker" }, "install": { "type": "dep" } }
  ]
}
JSON
# Stub wire script: places the marker (arg 1 is the settings path).
cat > "$fixture_repo/scripts/lib/wire-statusline.sh" <<'SH'
#!/usr/bin/env bash
echo "wire $*" >> "$ENSURE_LOG"
touch "$(dirname "$(dirname "$1")")/wire.marker"
SH
cat > "$fixture_repo/scripts/adopt.sh" <<'SH'
#!/usr/bin/env bash
echo "adopt $*" >> "$ENSURE_LOG"
SH

home="$work/home"; mkdir -p "$home"
cache="$work/cache"; mkdir -p "$cache"
cat > "$cache/install-profile.json" <<JSON
{"role":"adopter","tier":"standard","scope":"project","vault":{"mode":"existing","path":"$work/vault"},"handover":{"mode":"inline","path":""},"pluginSet":"lean","lanes":[],"lanesMeaningful":true,"alwaysOn":false}
JSON
mkdir -p "$work/vault"

ids='"local-wire","undeclared-adopt","undeclared-build","undeclared-qmd","undeclared-dep"'
fresh_target() {
  local t="$work/$1"; mkdir -p "$t"
  jq -n --arg t "$t" --argjson ids "[$ids]" '{schemaVersion:1,harness:"claude",targets:{($t):{profile:"core",scope:"project",lastEnsured:null,items:($ids|map({key:.,value:{enabled:true,overrides:{}}})|from_entries)}}}' > "$cache/state.json"
  echo "$t"
}

run_ensure() { # <target> <repo> args...
  local t="$1" repo="$2"; shift 2
  ( cd "$t" && PATH="$stubs:$real_path" STUB_LOG="$STUB_LOG" ENSURE_LOG="$work/log" \
      HIMMELCTL_REPO_ROOT="$(winpath "$repo")" HIMMELCTL_CACHE_DIR="$(winpath "$cache")" \
      HIMMEL_LUNA_CONFIG_PATH="$(winpath "$cache")-luna-config.json" HOME="$home" USERPROFILE="$(winpath "$home")" \
      "$node_bin" "$wizard" ensure "$@" </dev/null 2>&1 )
}

# ── a: declared converges, undeclared refuse, no stub called ───────────────
t=$(fresh_target ta); : > "$work/log"
rc=0; out=$(run_ensure "$t" "$fixture_repo" --no-network --yes) || rc=$?
[ "$rc" -eq 1 ] || fail "a: expected exit 1 (refusals) (rc=$rc): $out"
[ -e "$t/wire.marker" ] || fail "a: the declared item did not converge: $out"
for id in undeclared-adopt undeclared-build undeclared-qmd undeclared-dep; do
  grepq "$out" -F "refusing $id" || fail "a: no refusal naming $id: $out"
done
grepq "$out" -F 'refusing local-wire' && fail "a: the declared item was refused: $out"
[ -z "$(stub_calls)" ] || fail "a: a network-capable stub was called: $(stub_calls)"
grepq "$(cat "$work/log")" -F 'adopt' && fail "a: adopt.sh ran under --no-network"
echo "ok: a — declared item converged, undeclared items refused, no stub called"

# ── b: --items on an undeclared item refuses, state untouched ──────────────
t=$(fresh_target tb); : > "$work/log"
before=$(cksum < "$cache/state.json")
rc=0; out=$(run_ensure "$t" "$fixture_repo" --no-network --yes --items undeclared-build) || rc=$?
[ "$rc" -eq 1 ] || fail "b: expected exit 1 (rc=$rc): $out"
grepq "$out" -F 'refusing undeclared-build' || fail "b: no refusal: $out"
[ "$before" = "$(cksum < "$cache/state.json")" ] || fail "b: state.json changed"
[ -z "$(stub_calls)" ] || fail "b: a stub was called: $(stub_calls)"
echo "ok: b — scoped undeclared item refused, nothing run"

# ── c: --prune is rejected ─────────────────────────────────────────────────
t=$(fresh_target tc)
rc=0; out=$(run_ensure "$t" "$fixture_repo" --no-network --prune --yes) || rc=$?
[ "$rc" -eq 2 ] || fail "c: --no-network --prune must exit 2 (rc=$rc): $out"
echo "ok: c — --prune is not valid with --no-network"

# ── d: dry-run previews only the declared item ─────────────────────────────
t=$(fresh_target td); : > "$work/log"
rc=0; out=$(run_ensure "$t" "$fixture_repo" --no-network --dry-run) || rc=$?
[ "$rc" -eq 1 ] || fail "d: dry-run with refusals must exit 1 (rc=$rc): $out"
grepq "$out" -F 'wire-statusline.sh' || fail "d: declared item not previewed: $out"
grepq "$out" -F 'DRY: bash -c' && fail "d: a build/qmd/dep command was previewed: $out"
grepq "$out" -F 'adopt.sh' && fail "d: adopt.sh was previewed: $out"
[ ! -e "$t/wire.marker" ] || fail "d: dry-run mutated the target"
echo "ok: d — dry-run previews the declared item only"

# ── e: the shipped manifest, scratch HOME, dry-run ─────────────────────────
t="$work/te"; mkdir -p "$t"
cat > "$cache/install-profile.json" <<JSON
{"role":"adopter","tier":"standard","scope":"user","vault":{"mode":"existing","path":"$work/vault"},"handover":{"mode":"inline","path":""},"pluginSet":"lean","lanes":[],"lanesMeaningful":true,"alwaysOn":false}
JSON
echo '{"schemaVersion":1,"harness":"claude","targets":{}}' > "$cache/state.json"
: > "$STUB_LOG"
rc=0; out=$(run_ensure "$t" "$repo_root" --no-network --profile all --dry-run) || rc=$?
[ "$rc" -eq 1 ] || fail "e: shipped manifest dry-run with refusals must exit 1 (rc=$rc): $out"
[ -z "$(stub_calls)" ] || fail "e: a network-capable stub was called: $(stub_calls)"
for bad in 'DRY: bash -c' 'adopt.sh' 'setup.sh' 'install-plugins.sh' 'DRY: sudo' 'apt-get' 'bun ' 'npm '; do
  grepq "$out" -F "$bad" && fail "e: network-capable command previewed ($bad): $out"
done
grepq "$out" -F 'refusing qmd-index' || fail "e: qmd-index must refuse (collection add indexes): $out"
grepq "$out" -F 'refusing claude-plugins-pluginSet' || fail "e: the plugins item must refuse: $out"
echo "ok: e — shipped manifest: no stub called, no network-capable command previewed"

# ── f: declarations are exactly the traced set ─────────────────────────────
declared=$(jq -r '.items[] | select(.noNetwork != null) | .id' "$repo_root/scripts/install/manifest.json" | sort | tr '\n' ' ')
[ "$declared" = "wiring-pretooluse wiring-statusline " ] || fail "f: declared set changed (trace the new item's leaf commands, then update this list): $declared"
echo "ok: f — declared set is the traced set"
