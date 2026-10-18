#!/usr/bin/env bash
# scripts/release/test-gen-release-notes.sh - suite for gen-release-notes.sh
# The release-notes shape: four user sections plus one folded Internal line.
# Platform guard: Linux/macOS bash 3.2+ (jq only).
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/gen-release-notes.sh"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/gen-release-notes-test.XXXXXX")" || { echo "FAIL: mktemp -d failed" >&2; exit 1; }
trap 'rm -rf "$tmp"' EXIT
fails=0
check()    { if [ "$2" = "$3" ]; then echo "ok - $1"; else echo "FAIL - $1: [$2]!=[$3]"; fails=$((fails+1)); fi; }
contains() { if grep -q -F -e "$3" <<< "$2"; then echo "ok - $1"; else echo "FAIL - $1: output does not contain [$3]"; fails=$((fails+1)); fi; }
lacks()    { if grep -q -F -e "$3" <<< "$2"; then echo "FAIL - $1: output contains [$3]"; fails=$((fails+1)); else echo "ok - $1"; fi; }

cat > "$tmp/prs.json" <<'EOF'
[
  {"number": 101, "title": "feat(ui): [HIMMEL-1] board", "body": "## Summary\nx\n\n## Release note\n- new: The run page shows a live board.\n- update: Run `himmelctl ui --service install` once.\n\n## Test plan\n- ok"},
  {"number": 102, "title": "fix(jira): [HIMMEL-2] sector", "body": "## Release note\n- changed: `jira create` no longer requires a Sector unless you configure one.\n- known: Sector options are cached for five minutes."},
  {"number": 103, "title": "fix(hooks): [HIMMEL-3] guard-internals-zeta tightened", "body": "## Summary\nonly internals"},
  {"number": 104, "title": "chore(ci): [HIMMEL-4] shard-manifest-omega", "body": null}
]
EOF

rc=0; out=$(bash "$SCRIPT" --prs "$tmp/prs.json" --version v9.9.9 2>&1) || rc=$?
check "generate: rc 0" "$rc" "0"
contains "generate: title" "$out" "# v9.9.9 release notes"
contains "generate: new section" "$out" "## What you can now do"
contains "generate: new line" "$out" "- The run page shows a live board."
contains "generate: changed line" "$out" "- \`jira create\` no longer requires a Sector unless you configure one."
contains "generate: update line" "$out" "- Run \`himmel"
contains "generate: known line" "$out" "- Sector options are cached for five minutes."
contains "generate: internals folded to one line" "$out" "Internal: 2 further changes"
# the defect this suite guards: an internal-only PR leaking into the user sections
lacks "no leak: internal PR title" "$out" "guard-internals-zeta"
lacks "no leak: internal PR title 2" "$out" "shard-manifest-omega"
lacks "no leak: ticket key" "$out" "HIMMEL-"
printf '%s\n' "$out" > "$tmp/gen.md"
rc=0; bash "$SCRIPT" --check "$tmp/gen.md" >/dev/null 2>&1 || rc=$?
check "generated output passes --check" "$rc" "0"

# an empty user section reads "Nothing."
printf '%s\n' '[{"number": 7, "title": "x", "body": "## Release note\n- new: Only a feature."}]' > "$tmp/one.json"
out=$(bash "$SCRIPT" --prs "$tmp/one.json" --version v9.9.9 2>&1)
contains "empty section says Nothing." "$out" "Nothing."

# a release-note item naming a ticket or PR is refused at generation
printf '%s\n' '[{"number": 8, "title": "x", "body": "## Release note\n- new: Fixed per HIMMEL-123."}]' > "$tmp/key.json"
rc=0; out=$(bash "$SCRIPT" --prs "$tmp/key.json" --version v9.9.9 2>&1) || rc=$?
check "ticket key in an item: rc 1" "$rc" "1"
contains "ticket key in an item: named" "$out" "HIMMEL-123"

# --check: a leaked internal line in a user section fails
sed 's/^- The run page shows a live board\./- [HIMMEL-1] board internals (#101)/' "$tmp/gen.md" > "$tmp/leak.md"
rc=0; out=$(bash "$SCRIPT" --check "$tmp/leak.md" 2>&1) || rc=$?
check "--check: leaked ticket key rc 1" "$rc" "1"
contains "--check: names the section" "$out" "What you can now do"

# --check: Internal must be exactly one line
{ cat "$tmp/gen.md"; echo; echo "A second internal line."; } > "$tmp/two.md"
rc=0; out=$(bash "$SCRIPT" --check "$tmp/two.md" 2>&1) || rc=$?
check "--check: two Internal lines rc 1" "$rc" "1"

# --check: a second Internal line with no trailing newline is still counted
{ cat "$tmp/gen.md"; echo; printf 'A second internal line, no newline.'; } > "$tmp/nonl.md"
rc=0; out=$(bash "$SCRIPT" --check "$tmp/nonl.md" 2>&1) || rc=$?
check "--check: unterminated final Internal line rc 1" "$rc" "1"

# --check: a missing section fails
grep -v 'Known issues' "$tmp/gen.md" > "$tmp/miss.md"
rc=0; out=$(bash "$SCRIPT" --check "$tmp/miss.md" 2>&1) || rc=$?
check "--check: missing section rc 1" "$rc" "1"

# the committed notes for every release in the new shape stay in shape
rc=0; out=$(bash "$SCRIPT" --check "$HERE/../../docs/release/v1.1.3-notes.md" 2>&1) || rc=$?
check "committed v1.1.3-notes.md is in shape ($out)" "$rc" "0"

[ "$fails" -eq 0 ] && echo "ALL PASS" && exit 0
echo "$fails FAILED"; exit 1
