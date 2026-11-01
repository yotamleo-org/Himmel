#!/usr/bin/env bash
# test-dedupe-plugin-installs.sh — a stub claude holds a plugin list
# and records every uninstall (args + cwd). Dry-run lists and removes nothing;
# --apply removes only the target plugin's local/project entries, from each
# entry's projectPath, and leaves the user-scope entry and other plugins alone.
# An entry whose projectPath no longer exists is reported STALE and skipped:
# the script never creates a directory and never calls uninstall for it.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEDUPE="$SCRIPT_DIR/dedupe-plugin-installs.sh"
ATL='atlassian@claude-plugins-official'

PASS=0
FAIL=0
_pass() { printf 'PASS  %s\n' "$1"; PASS=$(( PASS + 1 )); }
_fail() { printf 'FAIL  %s\n  -> %s\n' "$1" "$2"; FAIL=$(( FAIL + 1 )); }

T="${TMPDIR:-/tmp}"; T="${T%/}/test-dpi-$$"   # no '//' (macOS TMPDIR ends in /): the stub logs a normalised $PWD
mkdir -p "$T/wt-a" "$T/wt-b"
# shellcheck disable=SC2064
trap "rm -rf '$T'" EXIT

cat > "$T/list.json" <<EOF
[
 {"id":"$ATL","scope":"user","enabled":false},
 {"id":"$ATL","scope":"local","enabled":true,"projectPath":"$T/wt-a"},
 {"id":"$ATL","scope":"local","enabled":true,"projectPath":"$T/wt-b"},
 {"id":"$ATL","scope":"project","enabled":true,"projectPath":"$T/gone/a/b"},
 {"id":"other@himmel","scope":"local","enabled":true,"projectPath":"$T/wt-a"}
]
EOF
cat > "$T/claude" <<'EOF'
#!/usr/bin/env bash
case "$1 $2" in
    "plugin list") [ "$3" = "--json" ] || exit 2; cat "$STUB_LIST" ;;
    "plugin uninstall") printf '%s|%s\n' "$PWD" "$*" >> "$STUB_LOG" ;;
esac
EOF
chmod +x "$T/claude"
export HIMMEL_CLAUDE_BIN="$T/claude" STUB_LIST="$T/list.json" STUB_LOG="$T/log"
: > "$T/log"

out="$(bash "$DEDUPE" 2>&1)"
NAME="dry-run counts the 3 local/project installs of 4 total and removes nothing"
if [[ "$out" == *"dry-run: 3 local/project install(s) of $ATL of 4 total"* ]] && [ ! -s "$T/log" ]; then _pass "$NAME"; else _fail "$NAME" "out=[$out] log=[$(cat "$T/log")]"; fi

NAME="dry-run lists every install path"
if [[ "$out" == *"$T/wt-a"* && "$out" == *"$T/wt-b"* && "$out" == *"$T/gone/a/b"* ]]; then _pass "$NAME"; else _fail "$NAME" "out=[$out]"; fi

NAME="dry-run marks the vanished projectPath as would-skip (stale), the others as would-remove"
if [[ "$out" == *"would skip (stale)  project $T/gone/a/b"* && "$out" == *"would remove  local   $T/wt-a"* ]]; then _pass "$NAME"; else _fail "$NAME" "out=[$out]"; fi

NAME="dry-run creates no directory for the vanished projectPath"
if [ ! -e "$T/gone" ]; then _pass "$NAME"; else _fail "$NAME" "$T/gone exists"; fi

out="$(bash "$DEDUPE" --apply 2>&1)"; rc=$?
NAME="--apply uninstalls only the 2 existing entries, each from its own projectPath and scope"
log="$(cat "$T/log")"
if [ "$(wc -l < "$T/log" | tr -d ' ')" = 2 ] \
   && [[ "$log" == *"$T/wt-a|plugin uninstall $ATL --scope local"* ]] \
   && [[ "$log" == *"$T/wt-b|plugin uninstall $ATL --scope local"* ]] \
   && [[ "$log" != *"$T/gone"* ]]; then _pass "$NAME"; else _fail "$NAME" "log=[$log] out=[$out]"; fi

NAME="--apply reports the vanished projectPath as STALE with the manual remedy, and counts it"
if [[ "$out" == *"STALE  project $T/gone/a/b"* && "$out" == *"installed_plugins.json"* \
   && "$out" == *"applied: removed 2, failed 0, stale 1 of 3 local/project install(s)"* ]]; then _pass "$NAME"; else _fail "$NAME" "out=[$out]"; fi

NAME="--apply exits 0 when the only problem is a stale entry"
if [ "$rc" -eq 0 ]; then _pass "$NAME"; else _fail "$NAME" "rc=$rc out=[$out]"; fi

NAME="--apply passes --keep-data on every uninstall, so the plugin's data directory survives"
if [ "$(grep -c -- ' --keep-data' "$T/log")" = 2 ]; then _pass "$NAME"; else _fail "$NAME" "log=[$log]"; fi

NAME="--apply never uninstalls the user-scope entry or another plugin"
if [[ "$log" != *"--scope user"* && "$log" != *other@himmel* ]]; then _pass "$NAME"; else _fail "$NAME" "log=[$log]"; fi

NAME="--apply never creates a directory for a vanished projectPath (no leftover parents)"
if [ ! -e "$T/gone" ]; then _pass "$NAME"; else _fail "$NAME" "$T/gone still exists"; fi

# A real uninstall failure still exits 1.
cat > "$T/claude-fail" <<'EOF2'
#!/usr/bin/env bash
case "$1 $2" in
    "plugin list") [ "$3" = "--json" ] || exit 2; cat "$STUB_LIST" ;;
    "plugin uninstall") exit 1 ;;
esac
EOF2
chmod +x "$T/claude-fail"
out="$(HIMMEL_CLAUDE_BIN="$T/claude-fail" bash "$DEDUPE" --apply 2>&1)"; rc=$?
NAME="--apply exits 1 when an uninstall on an existing projectPath fails"
if [ "$rc" -eq 1 ] && [[ "$out" == *"FAIL  local"* && "$out" == *"failed 2, stale 1"* ]]; then _pass "$NAME"; else _fail "$NAME" "rc=$rc out=[$out]"; fi

NAME="an unknown argument is refused"
if ! bash "$DEDUPE" --nope >/dev/null 2>&1; then _pass "$NAME"; else _fail "$NAME" "rc=0"; fi

echo ""
printf 'Results: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
