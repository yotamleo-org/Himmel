#!/usr/bin/env bash
# test-install-ui-handoff.sh — `himmelctl install` hands off to the UI's Setup page.
#
# After a real install the one setup path is the UI: install reuses a running UI or starts a
# token-bound one, and prints http://127.0.0.1:<port>/#t=<token>&page=setup. A machine with no
# reachable browser (no DISPLAY / WAYLAND_DISPLAY, or an SSH session) types secrets in the terminal.
#
# Hermetic: sandbox HOME, a fixture repo root with no-op adopt/setup stubs, a fake `bun` that runs a
# loopback server printing the same `<url>` line the real config-ui server prints, and a fake
# `systemctl` for the always-on unit. HIMMELCTL_UI_HANDOFF=1 forces the handoff on, because the
# suite's stdout is not a TTY.
#   A. no UI running      -> one server started, the Setup link printed
#   B. second install     -> the same link, no second server
#   C. always-on unit up  -> its link on port 47391, no server started
#   C2. always-on unit up, no browser -> no link, the terminal secret prompt instead
#   D. no browser         -> no server, no link; a secret typed in the terminal is stored
#   E. --dry-run          -> nothing started, no link
#   G. a handoff that throws -> a warning, the install rc stays 0
#   F. page and server copy never name #page=configure, port 37931, a link without #t=, or
#      send a secret to `himmelctl install`
set -uo pipefail

fail() { echo "FAIL: $1" >&2; exit 1; }

repo_root=$(git rev-parse --show-toplevel)
. "$repo_root/scripts/himmelctl/test/_hermetic-home.sh"
# shellcheck source=scripts/lib/timeout-bin.sh
. "$repo_root/scripts/lib/timeout-bin.sh"
wizard="$repo_root/scripts/himmelctl/bin.js"
command -v node >/dev/null 2>&1 || { echo "FAIL: node required" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "FAIL: jq required" >&2; exit 1; }
node_bin=$(command -v node)

work=$(mktemp -d "${TMPDIR:-/tmp}/install-ui-handoff.XXXXXX") || exit 1
cleanup() {
  local f
  for f in "$work"/*/home/.himmel/state/ui-adhoc.json; do
    [ -f "$f" ] && kill "$(jq -r '.pid' "$f")" 2>/dev/null || true
  done
  rm -rf "$work"
}
trap cleanup EXIT
derive_cwd="$work/suite-cwd"; mkdir -p "$derive_cwd"; cd "$derive_cwd" || exit 1

scrub=(-u CLAUDECODE -u DISPLAY -u WAYLAND_DISPLAY -u SSH_CONNECTION -u SSH_TTY)
for v in $(compgen -e | grep -E "^(CLAUDE_CODE_|JIRA_|TELEGRAM_)" || true); do scrub+=(-u "$v"); done

# the fake server the fake `bun` runs: listens on a free loopback port, prints the real server's one-line launch URL
cat > "$work/fake-server.js" <<'JS'
const net = require('net');
const token = require('crypto').randomBytes(32).toString('hex');
const srv = net.createServer((s) => s.end());
srv.listen(0, '127.0.0.1', () => { console.log(`http://127.0.0.1:${srv.address().port}/#t=${token}`); });
setInterval(() => {}, 1000);
JS

# new_case <name> — fixture repo root, sandbox HOME, fake bun + systemctl; sets $c
new_case() {
  c="$work/$1"
  mkdir -p "$c/home" "$c/fx/scripts/config-ui" "$c/stub" "$c/units"; : > "$c/fx/scripts/config-ui/server.ts"
  git init -q "$c/fx"; printf '.env\n' > "$c/fx/.gitignore"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$c/fx/scripts/adopt.sh"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$c/fx/scripts/setup.sh"
  printf 'exit 0\n' > "$c/fx/scripts/setup.ps1"
  chmod +x "$c/fx"/scripts/*.sh
  printf '#!/bin/sh\necho x >> "%s"\nexec "%s" "%s"\n' "$c/launches" "$node_bin" "$work/fake-server.js" > "$c/stub/bun"
  # shellcheck disable=SC2016
  printf '#!/bin/sh\ncase "$2" in is-active) echo %s;; is-enabled) echo enabled;; esac\nexit 0\n' "${2:-inactive}" > "$c/stub/systemctl"
  chmod +x "$c/stub/bun" "$c/stub/systemctl"
  : > "$c/launches"
  printf '{"schemaVersion":2,"profile":"starter","devOverlay":false,"scope":"project","vault":{"mode":"none","path":""},"handover":{"mode":"inline","path":""},"pluginSet":"lean","lanes":[],"lanesMeaningful":true,"alwaysOn":false}\n' > "$c/profile.json"
}

# run_install <stdin-file> [env KEY=VAL...] -- [install args...]; sets $out, $rc
run_install() {
  local in="$1"; shift
  local envs=()
  while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do envs+=("$1"); shift; done
  [ "$#" -eq 0 ] || shift
  rc=0
  out=$(env "${scrub[@]}" PATH="$c/stub:$PATH" HOME="$c/home" USERPROFILE="$(winpath "$c/home")" \
    HIMMELCTL_CACHE_DIR="$(winpath "$c/cache")" HIMMEL_LUNA_CONFIG_PATH="$(winpath "$c/cache/luna-config.json")" \
    HIMMELCTL_REPO_ROOT="$(winpath "$c/fx")" HIMMELCTL_SYSTEMD_USER_UNIT_DIR="$c/units" \
    HIMMELCTL_INTERACTIVE=0 HIMMELCTL_UI_HANDOFF=1 ${envs[@]+"${envs[@]}"} \
    ${_TIMEOUT_BIN:+"$_TIMEOUT_BIN" 120} "$node_bin" "$wizard" install --from-profile "$(winpath "$c/profile.json")" "$@" < "$in" 2>&1) || rc=$?  # read-sink-ok: $in is a fixed /dev/null or a fixture path this suite writes
}

setup_link_re='http://127\.0\.0\.1:[0-9]+/#t=[0-9a-f]{64}&page=setup'

# ── A: no UI running -> start one, print the Setup link ────────────────────
new_case A
run_install /dev/null DISPLAY=:0 --
[ "$rc" -eq 0 ] || fail "A: install rc=$rc: $out"
linkA=$(printf '%s\n' "$out" | grep -oE "$setup_link_re" | head -1)
[ -n "$linkA" ] || fail "A: no Setup link in the output: $out"
[ "$(wc -l < "$c/launches")" -eq 1 ] || fail "A: expected exactly one UI server started, got $(wc -l < "$c/launches")"
echo "ok: A no UI running -> one server started, Setup link printed"

# ── B: a second install reuses the running UI ──────────────────────────────
run_install /dev/null DISPLAY=:0 --
[ "$rc" -eq 0 ] || fail "B: install rc=$rc: $out"
linkB=$(printf '%s\n' "$out" | grep -oE "$setup_link_re" | head -1)
[ "$linkB" = "$linkA" ] || fail "B: second install printed '$linkB', want the running UI's '$linkA'"
[ "$(wc -l < "$c/launches")" -eq 1 ] || fail "B: second install started another server"
echo "ok: B second install reuses the running UI and prints its link"

# ── C: the always-on unit is up -> its link, nothing started ───────────────
new_case C active
printf 'ExecStart="/usr/bin/bun" "/x/scripts/config-ui/server.ts" --service --port 47391\n' > "$c/units/himmel-ui.service"
mkdir -p "$c/home/.himmel/state"; tokC=$(printf 'c%.0s' $(seq 1 64)); printf '%s\n' "$tokC" > "$c/home/.himmel/state/ui-token"; chmod 600 "$c/home/.himmel/state/ui-token"
run_install /dev/null DISPLAY=:0 --
[ "$rc" -eq 0 ] || fail "C: install rc=$rc: $out"
grep -qF "http://127.0.0.1:47391/#t=$tokC&page=setup" <<< "$out" || fail "C: the always-on UI's Setup link is missing: $out"
[ "$(wc -l < "$c/launches")" -eq 0 ] || fail "C: a server was started next to the always-on unit"
echo "ok: C always-on unit running -> its Setup link, no second server"

# ── C2: the always-on unit is up but no browser is reachable -> terminal prompt, no link ──
new_case C2 active
printf 'ExecStart="/usr/bin/bun" "/x/scripts/config-ui/server.ts" --service --port 47391\n' > "$c/units/himmel-ui.service"
mkdir -p "$c/home/.himmel/state"; printf '%s\n' "$tokC" > "$c/home/.himmel/state/ui-token"; chmod 600 "$c/home/.himmel/state/ui-token"
printf 'skip\n' > "$c/in-skip"
run_install "$c/in-skip" SSH_CONNECTION=1 --
[ "$rc" -eq 0 ] || fail "C2: install rc=$rc: $out"
grep -qF "47391" <<< "$out" && fail "C2: a link to the always-on UI was printed with no browser reachable: $out"
grep -qE '^\? [A-Z0-9_]+ \[' <<< "$out" || fail "C2: no terminal secret prompt in the output: $out"
echo "ok: C2 always-on unit up but no browser -> terminal prompt, no link"

# ── D: no browser -> terminal secret prompt, no server ─────────────────────
new_case D
printf 'skip\n' > "$c/in-probe"
run_install "$c/in-probe" SSH_CONNECTION=1 --
[ "$rc" -eq 0 ] || fail "D: install rc=$rc: $out"
grep -qE "$setup_link_re" <<< "$out" && fail "D: a Setup link was printed with no browser reachable"
[ "$(wc -l < "$c/launches")" -eq 0 ] || fail "D: a server was started with no browser reachable"
first=$(printf '%s\n' "$out" | sed -n 's/^? \([A-Z0-9_]*\) \[.*/\1/p' | head -1)
[ -n "$first" ] || fail "D: no terminal secret prompt in the output: $out"
canary="canary$(head -c 12 /dev/urandom | od -An -tx1 | tr -d ' \n')"
new_case D2
printf 'set\n%s\n' "$canary" > "$c/in-set"
run_install "$c/in-set" SSH_CONNECTION=1 --
[ "$rc" -eq 0 ] || fail "D2: install rc=$rc: $out"
grep -qxF "$first=$canary" "$c/fx/.env" || fail "D2: the secret typed in the terminal was not stored for $first"
grep -qF "$canary" <<< "$out" && fail "D2: the typed secret was echoed"
echo "ok: D no browser -> no server, secret typed in the terminal is stored"

# ── E: --dry-run starts nothing and prints no link ─────────────────────────
new_case E
run_install /dev/null DISPLAY=:0 -- --dry-run
[ "$rc" -eq 0 ] || fail "E: dry-run rc=$rc: $out"
grep -qE "$setup_link_re" <<< "$out" && fail "E: dry-run printed a Setup link"
[ "$(wc -l < "$c/launches")" -eq 0 ] || fail "E: dry-run started a server"
echo "ok: E --dry-run starts nothing"

# ── G: a handoff that throws never fails a successful install ──────────────
new_case G
mkdir -p "$c/home/.himmel/state"; printf '{"pid":1,"port":99999,"token":"x"}\n' > "$c/home/.himmel/state/ui-adhoc.json"
run_install /dev/null DISPLAY=:0 --
[ "$rc" -eq 0 ] || fail "G: a failing handoff turned a good install into rc=$rc: $out"
grep -qF 'UI handoff failed' <<< "$out" || fail "G: no warning that the handoff failed: $out"
echo "ok: G a throwing handoff warns and leaves the install rc untouched"

# ── F: copy never names the retired link forms ─────────────────────────────
files=(docs/ui.md docs/setup/install.md scripts/config-ui/public scripts/config-ui/setup.ts)
( cd "$repo_root" && git grep -n -E 'page=configure|37931' -- "${files[@]}" ) && fail "F: a doc or page names #page=configure or port 37931"
bad=$( cd "$repo_root" && git grep -n -E 'http://127\.0\.0\.1:[0-9]+/?' -- docs/ui.md docs/setup/install.md | grep -v '#t=' | grep -vE 'port 47391|--port N' || true )
[ -z "$bad" ] || fail "F: a doc names a loopback URL without #t=: $bad"
( cd "$repo_root" && git grep -n -F 'set the secret in the terminal (himmelctl install)' -- scripts/config-ui ) && fail "F: the service-mode refusal still sends a secret to himmelctl install"
( cd "$repo_root" && git grep -n -F 'is the safest path' -- scripts/config-ui/public ) && fail "F: setup.js still calls the terminal the safest path"
echo "ok: F no retired link forms or circular secret copy"

echo "PASS: install UI handoff"
