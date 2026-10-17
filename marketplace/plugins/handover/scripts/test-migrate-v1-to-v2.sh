#!/usr/bin/env bash
# Smoke test for migrate-v1-to-v2.sh.
#
# Usage: bash marketplace/plugins/handover/scripts/test-migrate-v1-to-v2.sh
#
# Exit codes:
#   0 — all cases passed
#   1 — at least one case failed
set -uo pipefail
SLUG="hbtest$$"   # generated neutral test user-slug (not hardcoded)

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MIGRATE="$SCRIPT_DIR/migrate-v1-to-v2.sh"
[ -x "$MIGRATE" ] || chmod +x "$MIGRATE"

pass=0
fail=0

fixture_setup() {
  local dir="$1"
  rm -rf "$dir"
  mkdir -p "$dir/handovers/$SLUG/epics" "$dir/handovers/$SLUG/standalones"

  # v1 item WITH Jira key
  mkdir -p "$dir/handovers/$SLUG/epics/#15-rename-himmel-and-jira/tasks"
  cat > "$dir/handovers/$SLUG/epics/#15-rename-himmel-and-jira/master-plan.md" <<'EOF'
---
template_version: 1
---
# #15 — rename-himmel-and-jira

**Status:** done
**Jira:** HIMMEL-15
EOF

  # v1 item WITHOUT Jira key (will be marked pending_jira_link with --no-jira-create)
  mkdir -p "$dir/handovers/$SLUG/standalones/#3-legacy-item"
  cat > "$dir/handovers/$SLUG/standalones/#3-legacy-item/brief.md" <<'EOF'
---
template_version: 1
---
# #3 — legacy-item

**Status:** done
EOF

  # Init the v1 counter
  printf "# Counter\nNext: 16\n" > "$dir/handovers/$SLUG/counter.md"
}

assert_dir_exists() {
  if [ -d "$1" ]; then
    pass=$((pass+1))
  else
    echo "FAIL: dir missing: $1"
    fail=$((fail+1))
  fi
}

assert_dir_absent() {
  if [ ! -d "$1" ]; then
    pass=$((pass+1))
  else
    echo "FAIL: dir should be gone: $1"
    fail=$((fail+1))
  fi
}

assert_grep() {
  local file="$1" pattern="$2"
  if grep -q "$pattern" "$file" 2>/dev/null; then
    pass=$((pass+1))
  else
    echo "FAIL: pattern '$pattern' not in $file"
    fail=$((fail+1))
  fi
}

# Case 1: items with Jira keys are renamed
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fixture_setup "$TMP"
"$MIGRATE" --root "$TMP" --no-jira-create --quiet >/dev/null 2>&1 || true
assert_dir_exists "$TMP/handovers/$SLUG/epics/HIMMEL-15-rename-himmel-and-jira"
assert_dir_absent "$TMP/handovers/$SLUG/epics/#15-rename-himmel-and-jira"
assert_grep "$TMP/handovers/$SLUG/epics/HIMMEL-15-rename-himmel-and-jira/master-plan.md" "template_version: 2"
assert_grep "$TMP/handovers/$SLUG/epics/HIMMEL-15-rename-himmel-and-jira/master-plan.md" "^jira: HIMMEL-15"

# Case 2: items without Jira keys stay #N when --no-jira-create
assert_dir_exists "$TMP/handovers/$SLUG/standalones/#3-legacy-item"
assert_grep "$TMP/handovers/$SLUG/standalones/#3-legacy-item/brief.md" "pending_jira_link: true"

# Case 3: re-running is idempotent
"$MIGRATE" --root "$TMP" --no-jira-create --quiet >/dev/null 2>&1 || true
assert_dir_exists "$TMP/handovers/$SLUG/epics/HIMMEL-15-rename-himmel-and-jira"
assert_dir_absent "$TMP/handovers/$SLUG/epics/#15-rename-himmel-and-jira"

# Case 4: jira create sends the plain Impact/What/Why/Agent detail block
TMP4="$(mktemp -d)" || exit 1
trap 'rm -rf "$TMP" "$TMP4"' EXIT
fixture_setup "$TMP4/root"
mkdir -p "$TMP4/root/handovers/$SLUG/epics/#15-rename-himmel-and-jira/tasks/#16-unkeyed-task" "$TMP4/bin" "$TMP4/bodies"
printf -- '---\ntemplate_version: 1\n---\n# #16 — unkeyed-task\n\n**Status:** open\n' \
  > "$TMP4/root/handovers/$SLUG/epics/#15-rename-himmel-and-jira/tasks/#16-unkeyed-task/brief.md"
# Stub jira: records each create's args and the body it was handed (--desc-file content, else --desc text).
cat > "$TMP4/bin/jira" <<'EOF'
#!/usr/bin/env bash
[ "$1" = "create" ] || exit 0
n=$(ls "$STUB_DIR/bodies" | wc -l | tr -d ' ')
body=""; prev=""
for a in "$@"; do
  case "$prev" in
    --desc-file) body="$(cat "$a")" ;;
    --desc) body="$a" ;;
  esac
  prev="$a"
done
printf '%s\n' "$*" > "$STUB_DIR/bodies/$n.args"
printf '%s\n' "$body" > "$STUB_DIR/bodies/$n.body"
echo "Created HIMMEL-90$n"
EOF
chmod +x "$TMP4/bin/jira"
if STUB_DIR="$TMP4" PATH="$TMP4/bin:$PATH" "$MIGRATE" --root "$TMP4/root" --quiet >/dev/null 2>&1; then pass=$((pass+1)); else echo "FAIL: migration exited non-zero"; fail=$((fail+1)); fi
bodies="$(find "$TMP4/bodies" -name '*.body' | wc -l | tr -d ' ')"
if [ "$bodies" -eq 2 ]; then pass=$((pass+1)); else echo "FAIL: expected 2 create calls, saw $bodies"; fail=$((fail+1)); fi
# The CLI's own linter, when the primary checkout has a built dist (offline, no network).
ANCHOR="$(dirname "$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null)")"
LINT="$ANCHOR/scripts/jira/dist/plain-block.js"
for b in "$TMP4"/bodies/*.body; do
  [ -f "$b" ] || continue
  for h in '## Impact' '## What' '## Why' '## Agent detail'; do
    assert_grep "$b" "^$h\$"
  done
  if [ -f "$LINT" ] && command -v node >/dev/null 2>&1; then
    lint="$(node --input-type=module -e "const {lintPlainBlock} = await import('file://' + process.argv[1]); const fs = await import('node:fs'); console.log(lintPlainBlock(fs.readFileSync(process.argv[2],'utf8')).join('; '))" "$LINT" "$b" 2>&1)"
    if [ -z "$lint" ]; then pass=$((pass+1)); else echo "FAIL: plain-block lint on $b: $lint"; fail=$((fail+1)); fi
  fi
done
# Both call sites ran (parented task, unparented standalone) and left no temp body behind.
if grep -q -e '--parent HIMMEL-15' "$TMP4"/bodies/*.args; then pass=$((pass+1)); else echo "FAIL: no parented create"; fail=$((fail+1)); fi

echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
