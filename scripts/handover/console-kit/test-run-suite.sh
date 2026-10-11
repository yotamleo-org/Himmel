#!/usr/bin/env bash
# test-run-suite.sh — HIMMEL-3084. Exercises run-suite.sh: one scan root per
# call, so a leg's turn boundary between calls is an inbox checkpoint for a
# console halt. The scan runner is stubbed (--runner); no real suite runs.
# bash 3.2-safe.
#
# RUN_SUITE overrides the script under test (the RED control).
#
# Run: bash scripts/handover/console-kit/test-run-suite.sh
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
RS="${RUN_SUITE:-$HERE/run-suite.sh}"

fails=0
check() { # <name> <expected> <actual>
    if [ "$2" = "$3" ]; then echo "PASS: $1"; else echo "FAIL: $1 (want '$2' got '$3')"; fails=$((fails + 1)); fi
}

WORK="$(mktemp -d "${TMPDIR:-/tmp}/run-suite-test.XXXXXX")" || { echo "mktemp -d failed" >&2; exit 1; }
trap 'rm -rf "$WORK"' EXIT

# Fake repo: three scan roots plus one top-level suite.
REPO="$WORK/repo"
mkdir -p "$REPO/scripts/alpha" "$REPO/scripts/beta/deep" "$REPO/scripts/gamma"
for f in scripts/alpha/test-a.sh scripts/beta/deep/test-b.sh scripts/gamma/test-c.sh; do
    printf '#!/usr/bin/env bash\nexit 0\n' > "$REPO/$f"
done
CALLS="$WORK/calls.log"
printf '#!/usr/bin/env bash\necho scripts/test-top.sh >> "%s"\n' "$CALLS" > "$REPO/scripts/test-top.sh"
printf 'x\n' > "$REPO/scripts/alpha/helper.sh"
git -C "$REPO" init -q
git -C "$REPO" add -A

cat > "$WORK/runner.sh" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$CALLS"
[ -n "\${FAKE_RC:-}" ] && exit "\$FAKE_RC"
exit 0
EOF

run() { (cd "$REPO" && bash "$RS" --runner "$WORK/runner.sh" "$@" 2>&1); }

out="$(run --plan)"; rc=$?
check "--plan rc 0" "0" "$rc"
check "--plan lists the roots in order" "scripts/alpha scripts/beta scripts/gamma top" "$(printf '%s\n' "$out" | tr '\n' ' ' | sed 's/ $//')"

: > "$CALLS"
out="$(run scripts/alpha)"; rc=$?
check "one root: rc 0" "0" "$rc"
check "one root: the runner is called exactly once" "1" "$(wc -l < "$CALLS" | tr -d ' ')"
check "one root: the runner got that scan root" "scripts/alpha" "$(head -1 "$CALLS")"
check "one root: CHECKPOINT names position and the next root" "1" "$(printf '%s\n' "$out" | grep -c '^CHECKPOINT 1/4 scripts/alpha rc=0 next=scripts/beta$')"

: > "$CALLS"
out="$(run)"
check "no argument runs the FIRST root only" "scripts/alpha" "$(cat "$CALLS")"

: > "$CALLS"
out="$(run top)"
check "top: CHECKPOINT closes the plan" "1" "$(printf '%s\n' "$out" | grep -c '^CHECKPOINT 4/4 top rc=0 next=none$')"
check "top: the top-level suite ran" "1" "$(grep -c 'scripts/test-top.sh' "$CALLS")"

: > "$CALLS"
out="$(FAKE_RC=1 run scripts/gamma)"; rc=$?
check "a failing root returns its rc" "1" "$rc"
check "a failing root still prints the CHECKPOINT" "1" "$(printf '%s\n' "$out" | grep -c '^CHECKPOINT 3/4 scripts/gamma rc=1 next=top$')"

: > "$CALLS"
out="$(run scripts/nosuch)"; rc=$?
check "an unknown root is refused rc 2" "2" "$rc"
check "an unknown root runs nothing" "0" "$(wc -l < "$CALLS" | tr -d ' ')"

out="$(run scripts/alpha scripts/beta)"; rc=$?
check "two roots in one call are refused rc 2" "2" "$rc"

[ "$fails" -eq 0 ] && echo "ALL PASS" || echo "$fails FAILED"
exit "$fails"
