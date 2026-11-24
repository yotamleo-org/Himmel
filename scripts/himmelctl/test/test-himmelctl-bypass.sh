#!/usr/bin/env bash
# Tests for `himmelctl bypass on|off|restart|status [--bucket <dir>]`: the argument grammar and the hand-over to
# scripts/station-ops/bypass-service.sh, which a stub records. The service script itself is covered by station-ops/test-bypass-service.sh.
# Usage: bash scripts/himmelctl/test/test-himmelctl-bypass.sh
set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
BIN="$REPO_ROOT/scripts/himmelctl/bin.js"
PASS=0
FAIL=0
pass() { printf '  PASS  %s\n' "$1"; PASS=$((PASS+1)); }
fail() { printf '  FAIL  %s\n' "$1"; [ -n "${2:-}" ] && printf '        got: %s\n' "$2"; FAIL=$((FAIL+1)); }
assert_eq() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "$3"; fi; }
assert_contains() { case "$3" in *"$2"*) pass "$1" ;; *) fail "$1" "$3" ;; esac; }

command -v node >/dev/null 2>&1 || { echo "SKIP: node not on PATH"; exit 0; }
tmp="$(mktemp -d "${TMPDIR:-/tmp}/himmelctl-bypass-test.XXXXXX")" || { echo "FAIL: mktemp"; exit 1; }
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/fake/scripts/station-ops"
cat > "$tmp/fake/scripts/station-ops/bypass-service.sh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB_CALLS"
exit "${STUB_RC:-0}"
STUB
chmod +x "$tmp/fake/scripts/station-ops/bypass-service.sh"
run() {
    : > "$tmp/calls"
    out=$(HIMMELCTL_REPO_ROOT="$tmp/fake" STUB_CALLS="$tmp/calls" node "$BIN" "$@" 2>&1); rc=$?
}

run bypass on --bucket /srv/b
assert_eq "bypass on --bucket passes both to the service script" "on --bucket /srv/b" "$(cat "$tmp/calls")"
assert_eq "bypass on exits 0" 0 "$rc"
run bypass on
assert_eq "bypass on without --bucket passes only the verb" "on" "$(cat "$tmp/calls")"
for v in off restart status; do
    run bypass "$v"
    assert_eq "bypass $v passes the verb" "$v" "$(cat "$tmp/calls")"
done
run --bucket /srv/b bypass on
assert_eq "the flag may come before the subcommand" "on --bucket /srv/b" "$(cat "$tmp/calls")"
STUB_RC=1 run bypass status
assert_eq "the service script's exit code is the CLI's" 1 "$rc"

run bypass
assert_eq "bypass with no verb exits 2" 2 "$rc"
assert_contains "and names the verbs" "on|off|restart|status" "$out"
run bypass frobnicate
assert_eq "an unknown verb exits 2" 2 "$rc"
run bypass on off
assert_eq "two verbs exit 2" 2 "$rc"
assert_eq "and call nothing" "" "$(cat "$tmp/calls")"
run bypass status --bucket /srv/b
assert_eq "--bucket with status exits 2" 2 "$rc"
assert_contains "and says it belongs to on" "bypass on" "$out"
run status --bucket /srv/b
assert_eq "--bucket on another subcommand exits 2" 2 "$rc"
run restart
assert_eq "restart outside bypass is an unknown argument (exit 2)" 2 "$rc"
run bypass on --bucket
assert_eq "--bucket without a value exits 2" 2 "$rc"
assert_eq "and calls nothing" "" "$(cat "$tmp/calls")"
run --help
assert_contains "--help documents bypass" "bypass on|off|restart|status" "$out"

echo
echo "himmelctl-bypass: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
