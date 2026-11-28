#!/usr/bin/env bash
# test-skill-lint.sh — Tests for scripts/lint/skill-lint.sh.
#
# Usage: bash scripts/lint/test-skill-lint.sh
#
# Cases (RED-first: each fixture is built to violate exactly one rule and
# asserted to fail with that rule's tag before any fix would be applied):
#   1. no-frontmatter  : a SKILL.md with no --- block → [no-frontmatter], exit 1
#   2. no-name         : frontmatter with description but no name: → [no-name]
#   3. no-description  : frontmatter with name but no description: → [no-description]
#   4. name-mismatch   : name: differs from the parent directory name
#   5. dup-name        : two files under different dirs share the same name:
#   6. clean fixture   : a well-formed SKILL.md → exit 0
#   7. --staged mode   : lints only staged in-scope SKILL.md paths
#   8. --help          : exits 0 and prints usage
#   9. real tree       : the repo's actual in-scope SKILL.md corpus is clean
#  10. --staged/index  : --staged lints the INDEX content, not the working tree
#      (a) bad staged frontmatter + a clean unstaged edit on disk -> flagged
#      (b) clean staged frontmatter + a bad unstaged edit on disk -> not flagged
#  11. no-description  : a comment-only description (`# TODO`) counts as empty
#  12. description cut : real text followed by a trailing `# comment` is not
#                        [no-description] but is [desc-truncated]
#  13. name-mismatch   : a quoted name: with trailing whitespace still matches
#  14. description ok  : a quoted value holding ` # ` (`" # TODO"`) is not a comment
#      (b) an empty quoted value plus a trailing comment is still empty
#  15. tab in path     : a path containing a TAB is linted by its real path
#  Y1-Y10 description parse check ([desc-truncated], [desc-yaml-error],
#      [desc-yaml-unchecked]); every row runs with CI unset except Y6.
#
# Exit: 0 all passed, 1 any failed. bash 3.2-safe.

set -uo pipefail

unset CI SKILL_LINT_PYTHON

grepq() { local _t="$1"; shift; grep -q "$@" <<< "$_t"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LINT="$SCRIPT_DIR/skill-lint.sh"

[ -f "$LINT" ] || { printf 'FAIL: skill-lint.sh not found at %s\n' "$LINT"; exit 1; }

PASS=0
FAIL=0
TMP_ROOT=""
cleanup() {
    if [ -n "$TMP_ROOT" ] && [ -d "$TMP_ROOT" ]; then
        rm -rf "$TMP_ROOT" 2>/dev/null || true
    fi
}
trap cleanup EXIT

pass() { printf '  PASS: %s\n' "$1"; PASS=$((PASS + 1)); }
fail() {
    printf '  FAIL: %s\n' "$1"
    [ $# -ge 2 ] && printf '        %s\n' "$2"
    FAIL=$((FAIL + 1))
}
assert_contains() {
    if grepq "$3" -F -- "$2"; then pass "$1"; else fail "$1" "missing: $2"; fi
}
assert_not_contains() {
    if grepq "$3" -F -- "$2"; then fail "$1" "unexpected: $2"; else pass "$1"; fi
}

TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/skill-lint.XXXXXX")" || { echo "FATAL: mktemp -d failed" >&2; exit 1; }
[ -n "$TMP_ROOT" ] || { echo "FATAL: mktemp -d returned empty" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Case 1: no frontmatter block
# ---------------------------------------------------------------------------
printf '\nCase 1: [no-frontmatter]\n'

mkdir -p "$TMP_ROOT/no-fm-skill"
NOFM="$TMP_ROOT/no-fm-skill/SKILL.md"
cat > "$NOFM" <<'EOF'
# no-fm-skill

Just prose, no frontmatter block at all.
EOF

OUT1="$(bash "$LINT" "$NOFM" 2>&1)"; EC1=$?
if [ "$EC1" -eq 1 ]; then pass "exit 1 on missing frontmatter"; else fail "expected exit 1, got $EC1" "$OUT1"; fi
assert_contains "[no-frontmatter] tag present" "no-frontmatter" "$OUT1"

# ---------------------------------------------------------------------------
# Case 2: frontmatter present but no name:
# ---------------------------------------------------------------------------
printf '\nCase 2: [no-name]\n'

mkdir -p "$TMP_ROOT/no-name-skill"
NONAME="$TMP_ROOT/no-name-skill/SKILL.md"
cat > "$NONAME" <<'EOF'
---
description: does something useful
---

# no-name-skill
EOF

OUT2="$(bash "$LINT" "$NONAME" 2>&1)"; EC2=$?
if [ "$EC2" -eq 1 ]; then pass "exit 1 on missing name:"; else fail "expected exit 1, got $EC2" "$OUT2"; fi
assert_contains "[no-name] tag present" "no-name" "$OUT2"

# ---------------------------------------------------------------------------
# Case 3: frontmatter present but no description:
# ---------------------------------------------------------------------------
printf '\nCase 3: [no-description]\n'

mkdir -p "$TMP_ROOT/no-desc-skill"
NODESC="$TMP_ROOT/no-desc-skill/SKILL.md"
cat > "$NODESC" <<'EOF'
---
name: no-desc-skill
---

# no-desc-skill
EOF

OUT3="$(bash "$LINT" "$NODESC" 2>&1)"; EC3=$?
if [ "$EC3" -eq 1 ]; then pass "exit 1 on missing description:"; else fail "expected exit 1, got $EC3" "$OUT3"; fi
assert_contains "[no-description] tag present" "no-description" "$OUT3"

# ---------------------------------------------------------------------------
# Case 4: name: != parent directory name
# ---------------------------------------------------------------------------
printf '\nCase 4: [name-mismatch]\n'

mkdir -p "$TMP_ROOT/actual-dir-name"
MISMATCH="$TMP_ROOT/actual-dir-name/SKILL.md"
cat > "$MISMATCH" <<'EOF'
---
name: some-other-name
description: does something useful
---

# actual-dir-name
EOF

OUT4="$(bash "$LINT" "$MISMATCH" 2>&1)"; EC4=$?
if [ "$EC4" -eq 1 ]; then pass "exit 1 on name/dirname mismatch"; else fail "expected exit 1, got $EC4" "$OUT4"; fi
assert_contains "[name-mismatch] tag present" "name-mismatch" "$OUT4"

# ---------------------------------------------------------------------------
# Case 5: duplicate name: across two files
# ---------------------------------------------------------------------------
printf '\nCase 5: [dup-name]\n'

mkdir -p "$TMP_ROOT/dup-a" "$TMP_ROOT/dup-b"
cat > "$TMP_ROOT/dup-a/SKILL.md" <<'EOF'
---
name: shared-name
description: first copy
---

# dup-a
EOF
cat > "$TMP_ROOT/dup-b/SKILL.md" <<'EOF'
---
name: shared-name
description: second copy
---

# dup-b
EOF

OUT5="$(bash "$LINT" "$TMP_ROOT/dup-a/SKILL.md" "$TMP_ROOT/dup-b/SKILL.md" 2>&1)"; EC5=$?
if [ "$EC5" -eq 1 ]; then pass "exit 1 on duplicate name:"; else fail "expected exit 1, got $EC5" "$OUT5"; fi
assert_contains "[dup-name] tag present" "dup-name" "$OUT5"
assert_contains "dup-name names the shared value" "shared-name" "$OUT5"

# ---------------------------------------------------------------------------
# Case 6: a well-formed SKILL.md is clean
# ---------------------------------------------------------------------------
printf '\nCase 6: clean fixture exits 0\n'

mkdir -p "$TMP_ROOT/clean-skill"
CLEAN="$TMP_ROOT/clean-skill/SKILL.md"
cat > "$CLEAN" <<'EOF'
---
name: clean-skill
description: a well-formed skill for the clean-fixture test case
---

# clean-skill
EOF

OUT6="$(bash "$LINT" "$CLEAN" 2>&1)"; EC6=$?
if [ "$EC6" -eq 0 ]; then pass "clean fixture exits 0"; else fail "expected exit 0, got $EC6" "$OUT6"; fi

# ---------------------------------------------------------------------------
# Case 7: --staged mode scopes to staged in-scope SKILL.md paths
# ---------------------------------------------------------------------------
printf '\nCase 7: --staged mode\n'

REPO="$TMP_ROOT/repo"
mkdir -p "$REPO/.claude/skills/staged-bad" "$REPO/.claude/skills/unstaged-bad"
(
    cd "$REPO" || exit 1
    git init -q
    git config user.email t@t.t
    git config user.name t
    cat > .claude/skills/staged-bad/SKILL.md <<'EOF'
---
description: missing a name field
---
EOF
    cat > .claude/skills/unstaged-bad/SKILL.md <<'EOF'
---
description: also missing a name field
---
EOF
    git add .claude/skills/staged-bad/SKILL.md
)
OUT7="$(cd "$REPO" && bash "$LINT" --staged 2>&1)"; EC7=$?
if [ "$EC7" -eq 1 ]; then pass "--staged exits 1 on a staged issue"; else fail "expected exit 1, got $EC7" "$OUT7"; fi
assert_contains "--staged reports the staged file" "staged-bad" "$OUT7"
assert_not_contains "--staged ignores the unstaged file" "unstaged-bad" "$OUT7"

# ---------------------------------------------------------------------------
# Case 8: --help
# ---------------------------------------------------------------------------
printf '\nCase 8: --help\n'

OUT8="$(bash "$LINT" --help 2>&1)"; EC8=$?
if [ "$EC8" -eq 0 ]; then pass "--help exits 0"; else fail "expected exit 0, got $EC8" "$OUT8"; fi
assert_contains "--help prints usage" "Usage:" "$OUT8"

# ---------------------------------------------------------------------------
# Case 9: the real repo's in-scope SKILL.md corpus is clean
# ---------------------------------------------------------------------------
printf '\nCase 9: real in-scope tree is clean\n'

REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && git rev-parse --show-toplevel)"
OUT9="$(cd "$REPO_ROOT" && bash "$LINT" 2>&1)"; EC9=$?
if [ "$EC9" -eq 0 ]; then pass "real tree exits 0 (regression guard, not a cleanup)"; else fail "expected exit 0, got $EC9" "$OUT9"; fi

# ---------------------------------------------------------------------------
# Case 10: --staged lints the INDEX, not the working tree
# ---------------------------------------------------------------------------
printf '\nCase 10a: --staged flags bad STAGED content despite a clean unstaged edit\n'

REPO2="$TMP_ROOT/repo2"
mkdir -p "$REPO2/.claude/skills/divergent-skill"
(
    cd "$REPO2" || exit 1
    git init -q
    git config user.email t@t.t
    git config user.name t
    cat > .claude/skills/divergent-skill/SKILL.md <<'EOF'
---
description: missing a name field, staged
---
EOF
    git add .claude/skills/divergent-skill/SKILL.md
    cat > .claude/skills/divergent-skill/SKILL.md <<'EOF2'
---
name: divergent-skill
description: fixed on disk but not staged
---
EOF2
)
OUT10A="$(cd "$REPO2" && bash "$LINT" --staged 2>&1)"; EC10A=$?
if [ "$EC10A" -eq 1 ]; then pass "--staged flags bad staged content even when the working tree is clean"; else fail "expected exit 1, got $EC10A" "$OUT10A"; fi
assert_contains "--staged [no-name] on the staged (not working-tree) content" "no-name" "$OUT10A"

printf '\nCase 10b: --staged stays clean when only the working tree is broken\n'

REPO3="$TMP_ROOT/repo3"
mkdir -p "$REPO3/.claude/skills/divergent-skill2"
(
    cd "$REPO3" || exit 1
    git init -q
    git config user.email t@t.t
    git config user.name t
    cat > .claude/skills/divergent-skill2/SKILL.md <<'EOF'
---
name: divergent-skill2
description: clean and staged
---
EOF
    git add .claude/skills/divergent-skill2/SKILL.md
    if [ -z "$(git diff --cached --name-only)" ]; then
        echo "FATAL: git add did not stage divergent-skill2/SKILL.md" >&2
        exit 1
    fi
    cat > .claude/skills/divergent-skill2/SKILL.md <<'EOF2'
---
description: broken on disk, missing name, not staged
---
EOF2
) || fail "Case 10b setup failed to stage the fixture" ""
OUT10B="$(cd "$REPO3" && bash "$LINT" --staged 2>&1)"; EC10B=$?
if [ "$EC10B" -eq 0 ]; then pass "--staged stays clean when only the working tree (not the index) is broken"; else fail "expected exit 0, got $EC10B" "$OUT10B"; fi

# ---------------------------------------------------------------------------
# Case 11: a comment-only description counts as empty
# ---------------------------------------------------------------------------
printf '\nCase 11: [no-description] on a comment-only value\n'

mkdir -p "$TMP_ROOT/comment-desc-skill"
COMMENTDESC="$TMP_ROOT/comment-desc-skill/SKILL.md"
cat > "$COMMENTDESC" <<'EOF'
---
name: comment-desc-skill
description: # TODO
---

# comment-desc-skill
EOF

OUT11="$(bash "$LINT" "$COMMENTDESC" 2>&1)"; EC11=$?
if [ "$EC11" -eq 1 ]; then pass "exit 1 on comment-only description"; else fail "expected exit 1, got $EC11" "$OUT11"; fi
assert_contains "[no-description] tag present for comment-only value" "no-description" "$OUT11"

printf '\nCase 12: description with real text and a trailing comment is not empty, but is cut\n'

mkdir -p "$TMP_ROOT/trailing-comment-skill"
TRAILDESC="$TMP_ROOT/trailing-comment-skill/SKILL.md"
cat > "$TRAILDESC" <<'EOF'
---
name: trailing-comment-skill
description: real text # note
---

# trailing-comment-skill
EOF

OUT12="$(bash "$LINT" "$TRAILDESC" 2>&1)"; EC12=$?
if [ "$EC12" -eq 1 ]; then pass "description with real text plus a trailing comment exits 1 (cut by the parse check)"; else fail "expected exit 1, got $EC12" "$OUT12"; fi
assert_not_contains "a trailing comment is not [no-description]" "no-description" "$OUT12"
assert_contains "a trailing comment is [desc-truncated]" "[desc-truncated]" "$OUT12"

# ---------------------------------------------------------------------------
# Case 13: a quoted name: with trailing whitespace still matches the parent dir
# ---------------------------------------------------------------------------
printf '\nCase 13: quoted name: with trailing whitespace avoids a false name-mismatch\n'

mkdir -p "$TMP_ROOT/quoted-name-skill"
QUOTEDNAME="$TMP_ROOT/quoted-name-skill/SKILL.md"
printf -- '---\nname: "quoted-name-skill"  \ndescription: quoted name with trailing spaces\n---\n\n# quoted-name-skill\n' > "$QUOTEDNAME"

OUT13="$(bash "$LINT" "$QUOTEDNAME" 2>&1)"; EC13=$?
if [ "$EC13" -eq 0 ]; then pass "quoted name: with trailing whitespace still matches the parent dir"; else fail "expected exit 0, got $EC13" "$OUT13"; fi

# ---------------------------------------------------------------------------
# Case 14: a ` #` inside a quoted description is content, not a comment
# ---------------------------------------------------------------------------
printf '\nCase 14: quoted description containing " # " is not reported empty\n'

mkdir -p "$TMP_ROOT/quoted-hash-skill"
QUOTEDHASH="$TMP_ROOT/quoted-hash-skill/SKILL.md"
cat > "$QUOTEDHASH" <<'EOF'
---
name: quoted-hash-skill
description: " # TODO"
---

# quoted-hash-skill
EOF

OUT14="$(bash "$LINT" "$QUOTEDHASH" 2>&1)"; EC14=$?
if [ "$EC14" -eq 0 ]; then pass "quoted description with an inner ' # ' exits 0"; else fail "expected exit 0, got $EC14" "$OUT14"; fi
assert_not_contains "no [no-description] for a quoted ' # ' value" "no-description" "$OUT14"

printf '\nCase 14b: an empty quoted description followed by a comment is still empty\n'

mkdir -p "$TMP_ROOT/empty-quoted-skill"
EMPTYQUOTED="$TMP_ROOT/empty-quoted-skill/SKILL.md"
cat > "$EMPTYQUOTED" <<'EOF'
---
name: empty-quoted-skill
description: "" # TODO
---
EOF

OUT14B="$(bash "$LINT" "$EMPTYQUOTED" 2>&1)"; EC14B=$?
if [ "$EC14B" -eq 1 ]; then pass "empty quoted description exits 1"; else fail "expected exit 1, got $EC14B" "$OUT14B"; fi
assert_contains "[no-description] for an empty quoted value" "no-description" "$OUT14B"

# ---------------------------------------------------------------------------
# Case 15: a path containing a TAB is linted by its real path
# ---------------------------------------------------------------------------
printf '\nCase 15: a path containing a TAB is linted by its real path\n'

TABDIR="$TMP_ROOT/tab$(printf '\t')parent"
mkdir -p "$TABDIR/tab-path-skill" "$TABDIR/tab-bad-skill"
cat > "$TABDIR/tab-path-skill/SKILL.md" <<'EOF'
---
name: tab-path-skill
description: lives under a directory whose name holds a tab
---
EOF
cat > "$TABDIR/tab-bad-skill/SKILL.md" <<'EOF'
---
description: missing a name field, under a tab path
---
EOF

OUT15A="$(bash "$LINT" "$TABDIR/tab-path-skill/SKILL.md" 2>&1)"; EC15A=$?
if [ "$EC15A" -eq 0 ]; then pass "clean file under a tab path exits 0"; else fail "expected exit 0, got $EC15A" "$OUT15A"; fi
assert_contains "clean tab-path file is actually checked" "clean (1 file(s) checked)" "$OUT15A"

OUT15B="$(bash "$LINT" "$TABDIR/tab-bad-skill/SKILL.md" 2>&1)"; EC15B=$?
if [ "$EC15B" -eq 1 ]; then pass "bad file under a tab path exits 1"; else fail "expected exit 1, got $EC15B" "$OUT15B"; fi
assert_contains "finding names the real tab-holding path" "$TABDIR/tab-bad-skill/SKILL.md:" "$OUT15B"
assert_contains "[no-name] reported for the tab-path file" "no-name" "$OUT15B"

# ---------------------------------------------------------------------------
# Case 16: body size cap
# ---------------------------------------------------------------------------
printf '\nCase 16: [size-warn] / [size-fail] / allowlist / command bodies\n'

SZDIR="$TMP_ROOT/size"
mkdir -p "$SZDIR/big-skill" "$SZDIR/commands"
{
    printf -- '---\nname: big-skill\ndescription: a long body\n---\n'
    head -c 300 /dev/zero | tr '\0' 'x'; printf '\n'
} > "$SZDIR/big-skill/SKILL.md"
{ printf '# cmd without frontmatter\n'; head -c 300 /dev/zero | tr '\0' 'x'; printf '\n'; } > "$SZDIR/commands/big-cmd.md"

OUT16A="$(SKILL_LINT_WARN_BYTES=100 SKILL_LINT_FAIL_BYTES=200 bash "$LINT" "$SZDIR/big-skill/SKILL.md" 2>&1)"; EC16A=$?
if [ "$EC16A" -eq 1 ]; then pass "body over fail threshold exits 1"; else fail "expected exit 1, got $EC16A" "$OUT16A"; fi
assert_contains "[size-fail] tag present" "[size-fail]" "$OUT16A"

OUT16B="$(SKILL_LINT_WARN_BYTES=100 SKILL_LINT_FAIL_BYTES=400 bash "$LINT" "$SZDIR/big-skill/SKILL.md" 2>&1)"; EC16B=$?
if [ "$EC16B" -eq 0 ]; then pass "body between warn and fail exits 0"; else fail "expected exit 0, got $EC16B" "$OUT16B"; fi
assert_contains "[size-warn] tag present" "[size-warn]" "$OUT16B"

OUT16C="$(SKILL_LINT_WARN_BYTES=1000 SKILL_LINT_FAIL_BYTES=2000 bash "$LINT" "$SZDIR/big-skill/SKILL.md" 2>&1)"; EC16C=$?
if [ "$EC16C" -eq 0 ]; then pass "body under warn exits 0"; else fail "expected exit 0, got $EC16C" "$OUT16C"; fi
assert_not_contains "no size tag under warn" "[size-" "$OUT16C"

OUT16D="$(SKILL_LINT_WARN_BYTES=100 SKILL_LINT_FAIL_BYTES=200 bash "$LINT" "$SZDIR/commands/big-cmd.md" 2>&1)"; EC16D=$?
if [ "$EC16D" -eq 1 ]; then pass "command body over fail threshold exits 1"; else fail "expected exit 1, got $EC16D" "$OUT16D"; fi
assert_contains "command body gets [size-fail]" "[size-fail]" "$OUT16D"
assert_not_contains "command body skips frontmatter checks" "no-frontmatter" "$OUT16D"

# Allowlist: keyed on the repo-relative path, so build a repo-shaped fixture.
AL_REPO="$TMP_ROOT/alrepo"
mkdir -p "$AL_REPO/.claude/commands"
cp "$SZDIR/commands/big-cmd.md" "$AL_REPO/.claude/commands/big-cmd.md"
printf '# reasons\n.claude/commands/big-cmd.md\tupstream-owned fork\n' > "$AL_REPO/allow.txt"
(cd "$AL_REPO" && git init -q)
OUT16E="$(cd "$AL_REPO" && SKILL_LINT_SIZE_ALLOWLIST="$AL_REPO/allow.txt" SKILL_LINT_WARN_BYTES=100 SKILL_LINT_FAIL_BYTES=200 bash "$LINT" 2>&1)"; EC16E=$?
if [ "$EC16E" -eq 0 ]; then pass "allowlisted body is exempt"; else fail "expected exit 0, got $EC16E" "$OUT16E"; fi
OUT16F="$(cd "$AL_REPO" && SKILL_LINT_SIZE_ALLOWLIST="$AL_REPO/none.txt" SKILL_LINT_WARN_BYTES=100 SKILL_LINT_FAIL_BYTES=200 bash "$LINT" 2>&1)"; EC16F=$?
if [ "$EC16F" -eq 1 ]; then pass "same body without allowlist entry fails"; else fail "expected exit 1, got $EC16F" "$OUT16F"; fi

OUT16G="$(SKILL_LINT_FAIL_BYTES=abc bash "$LINT" "$SZDIR/big-skill/SKILL.md" 2>&1)"; EC16G=$?
if [ "$EC16G" -eq 2 ]; then pass "non-integer threshold is a usage error"; else fail "expected exit 2, got $EC16G" "$OUT16G"; fi

# ---------------------------------------------------------------------------
# Case 17: default thresholds (warn 16000, hard fail above 20000)
# ---------------------------------------------------------------------------
printf '\nCase 17: default thresholds warn at 16000 and hard-fail above 20000\n'

TL="$TMP_ROOT/twolevel"
mkdir -p "$TL/mid-skill" "$TL/at-skill" "$TL/over-skill"
_mkbody() {
    local _hdr; _hdr="$(printf -- '---\nname: %s\ndescription: d\n---\n' "$(basename "$1")")"
    { printf '%s\n' "$_hdr"; head -c $(( $2 - ${#_hdr} - 1 )) /dev/zero | tr '\0' 'x'; } > "$1/SKILL.md"
}
_mkbody "$TL/mid-skill" 18000
_mkbody "$TL/at-skill" 20000
_mkbody "$TL/over-skill" 20001

OUT17A="$(env -u SKILL_LINT_WARN_BYTES -u SKILL_LINT_FAIL_BYTES bash "$LINT" "$TL/mid-skill/SKILL.md" 2>&1)"; EC17A=$?
if [ "$EC17A" -eq 0 ]; then pass "18000-byte body warns but exits 0 by default"; else fail "expected exit 0, got $EC17A" "$OUT17A"; fi
assert_contains "18000-byte body carries [size-warn]" "[size-warn]" "$OUT17A"
assert_not_contains "18000-byte body has no [size-fail]" "[size-fail]" "$OUT17A"

OUT17B="$(env -u SKILL_LINT_WARN_BYTES -u SKILL_LINT_FAIL_BYTES bash "$LINT" "$TL/over-skill/SKILL.md" 2>&1)"; EC17B=$?
if [ "$EC17B" -eq 1 ]; then pass "20001-byte body exits 1 by default"; else fail "expected exit 1, got $EC17B" "$OUT17B"; fi
assert_contains "20001-byte body carries [size-fail]" "[size-fail]" "$OUT17B"

OUT17C="$(env -u SKILL_LINT_WARN_BYTES -u SKILL_LINT_FAIL_BYTES bash "$LINT" "$TL/at-skill/SKILL.md" 2>&1)"; EC17C=$?
if [ "$EC17C" -eq 0 ]; then pass "20000-byte body exits 0 by default"; else fail "expected exit 0, got $EC17C" "$OUT17C"; fi
assert_not_contains "20000-byte body has no [size-fail]" "[size-fail]" "$OUT17C"

AL17="$TMP_ROOT/al17"
mkdir -p "$AL17/.claude/skills/over-skill"
cp "$TL/over-skill/SKILL.md" "$AL17/.claude/skills/over-skill/SKILL.md"
printf '.claude/skills/over-skill/SKILL.md\tsplit tracked elsewhere\n' > "$AL17/allow.txt"
(cd "$AL17" && git init -q)
OUT17D="$(cd "$AL17" && env -u SKILL_LINT_WARN_BYTES -u SKILL_LINT_FAIL_BYTES SKILL_LINT_SIZE_ALLOWLIST="$AL17/allow.txt" bash "$LINT" 2>&1)"; EC17D=$?
if [ "$EC17D" -eq 0 ]; then pass "allowlisted 20001-byte body exits 0"; else fail "expected exit 0, got $EC17D" "$OUT17D"; fi

# ---------------------------------------------------------------------------
# Case 18: --changed <range> lints only the in-scope files that range touched
# ---------------------------------------------------------------------------
printf '\nCase 18: --changed <range>\n'

CH="$TMP_ROOT/chrepo"
mkdir -p "$CH/.claude/commands"
(cd "$CH" && git init -q && git config commit.gpgsign false)
head -c 300 /dev/zero | tr '\0' 'x' > "$CH/.claude/commands/old-big.md"
(cd "$CH" && git add -A && git -c user.name=t -c user.email=t@t commit -q -m base)
head -c 300 /dev/zero | tr '\0' 'x' > "$CH/.claude/commands/new-big.md"
printf 'notes\n' > "$CH/NOTES.md"
(cd "$CH" && git add -A && git -c user.name=t -c user.email=t@t commit -q -m change)
printf 'more notes\n' >> "$CH/NOTES.md"
(cd "$CH" && git add -A && git -c user.name=t -c user.email=t@t commit -q -m notes-only)

OUT18A="$(cd "$CH" && SKILL_LINT_WARN_BYTES=100 SKILL_LINT_FAIL_BYTES=200 bash "$LINT" --changed HEAD~2..HEAD~1 2>&1)"; EC18A=$?
if [ "$EC18A" -eq 1 ]; then pass "--changed fails on an oversize body the range added"; else fail "expected exit 1, got $EC18A" "$OUT18A"; fi
assert_contains "--changed reports the changed file" "new-big.md" "$OUT18A"
assert_not_contains "--changed skips an untouched oversize file" "old-big.md" "$OUT18A"

OUT18B="$(cd "$CH" && SKILL_LINT_WARN_BYTES=100 SKILL_LINT_FAIL_BYTES=200 bash "$LINT" --changed HEAD~1..HEAD 2>&1)"; EC18B=$?
if [ "$EC18B" -eq 0 ]; then pass "--changed over a range with no in-scope files exits 0"; else fail "expected exit 0, got $EC18B" "$OUT18B"; fi

OUT18C="$(cd "$CH" && bash "$LINT" --changed not-a-range 2>&1)"; EC18C=$?
if [ "$EC18C" -eq 2 ]; then pass "--changed with an unresolvable range is a usage error"; else fail "expected exit 2, got $EC18C" "$OUT18C"; fi
assert_contains "unresolvable range names the failed git diff" "git diff failed" "$OUT18C"

OUT18D="$(cd "$CH" && bash "$LINT" --changed HEAD~1..HEAD --staged 2>&1)"; EC18D=$?
if [ "$EC18D" -eq 2 ]; then pass "--changed with --staged is a usage error"; else fail "expected exit 2, got $EC18D" "$OUT18D"; fi
assert_contains "--changed with --staged says mutually exclusive" "mutually exclusive" "$OUT18D"

OUT18E="$(cd "$CH" && bash "$LINT" --changed 2>&1)"; EC18E=$?
if [ "$EC18E" -eq 2 ]; then pass "--changed without a range is a usage error"; else fail "expected exit 2, got $EC18E" "$OUT18E"; fi
assert_contains "--changed without a range says it needs one" "needs a git range" "$OUT18E"

OUT18G="$(cd "$CH" && bash "$LINT" --changed HEAD~1..HEAD .claude/commands/old-big.md 2>&1)"; EC18G=$?
if [ "$EC18G" -eq 2 ]; then pass "--changed with file args is a usage error"; else fail "expected exit 2, got $EC18G" "$OUT18G"; fi
assert_contains "--changed with file args says mutually exclusive" "mutually exclusive" "$OUT18G"

(cd "$CH" && git mv .claude/commands/new-big.md .claude/commands/ren-big.md && git -c user.name=t -c user.email=t@t commit -q -m rename)
OUT18F="$(cd "$CH" && SKILL_LINT_WARN_BYTES=100 SKILL_LINT_FAIL_BYTES=200 bash "$LINT" --changed HEAD~1..HEAD 2>&1)"; EC18F=$?
if [ "$EC18F" -eq 1 ]; then pass "--changed lints a renamed in-scope body"; else fail "expected exit 1, got $EC18F" "$OUT18F"; fi
assert_contains "--changed reports the renamed file" "ren-big.md" "$OUT18F"

# A rename INTO a command dir of an over-limit body (git reports status R): both modes.
mkdir -p "$CH/docs"
head -c 300 /dev/zero | tr '\0' 'y' > "$CH/docs/over.md"
head -c 301 /dev/zero | tr '\0' 'z' > "$CH/docs/over2.md"
(cd "$CH" && git add -A && git -c user.name=t -c user.email=t@t commit -q -m docover)
(cd "$CH" && git mv docs/over.md .claude/commands/moved-in.md && git -c user.name=t -c user.email=t@t commit -q -m movein)
OUT18H="$(cd "$CH" && SKILL_LINT_WARN_BYTES=100 SKILL_LINT_FAIL_BYTES=200 bash "$LINT" --changed HEAD~1..HEAD 2>&1)"; EC18H=$?
if [ "$EC18H" -eq 1 ]; then pass "--changed lints a body renamed into a command dir"; else fail "expected exit 1, got $EC18H" "$OUT18H"; fi
assert_contains "--changed reports the moved-in body" "moved-in.md" "$OUT18H"

(cd "$CH" && git mv docs/over2.md .claude/commands/moved-staged.md)
OUT18I="$(cd "$CH" && SKILL_LINT_WARN_BYTES=100 SKILL_LINT_FAIL_BYTES=200 bash "$LINT" --staged 2>&1)"; EC18I=$?
if [ "$EC18I" -eq 1 ]; then pass "--staged lints a body renamed into a command dir"; else fail "expected exit 1, got $EC18I" "$OUT18I"; fi
assert_contains "--staged reports the moved-in body" "moved-staged.md" "$OUT18I"
(cd "$CH" && git -c user.name=t -c user.email=t@t commit -q -m movestaged)

# A path with a space survives the newline-delimited file list.
head -c 300 /dev/zero | tr '\0' 'w' > "$CH/.claude/commands/spaced name.md"
(cd "$CH" && git add -A && git -c user.name=t -c user.email=t@t commit -q -m spaced)
OUT18J="$(cd "$CH" && SKILL_LINT_WARN_BYTES=100 SKILL_LINT_FAIL_BYTES=200 bash "$LINT" --changed HEAD~1..HEAD 2>&1)"; EC18J=$?
if [ "$EC18J" -eq 1 ]; then pass "--changed lints a path with a space"; else fail "expected exit 1, got $EC18J" "$OUT18J"; fi
assert_contains "--changed reports the spaced path" "spaced name.md" "$OUT18J"

# A deleted body has no content to lint: exit 0.
(cd "$CH" && git rm -q ".claude/commands/spaced name.md" && git -c user.name=t -c user.email=t@t commit -q -m deleted)
OUT18K="$(cd "$CH" && SKILL_LINT_WARN_BYTES=100 SKILL_LINT_FAIL_BYTES=200 bash "$LINT" --changed HEAD~1..HEAD 2>&1)"; EC18K=$?
if [ "$EC18K" -eq 0 ]; then pass "--changed over a deletion exits 0"; else fail "expected exit 0, got $EC18K" "$OUT18K"; fi

printf '\nRows Y1-Y10: [desc-truncated] / [desc-yaml-error]\n'

YD="$TMP_ROOT/yaml"
mkdir -p "$YD/bus" "$YD/gh-pr-checks" "$YD/plain" "$YD/quoted" "$YD/block" "$YD/hint" "$YD/cmds" "$YD/bad" "$YD/bool" "$YD/empty"

cat > "$YD/bus/SKILL.md" <<'EOF'
---
name: bus
description: Use when you hold or send himmel-bus messages (bus #n from <name>, send/read tools, bus wait) — the protocol in short.
---

body
EOF
cat > "$YD/gh-pr-checks/SKILL.md" <<'EOF'
---
name: gh-pr-checks
description: CI/check status for a specific PR ("is PR N passing", "CI status for #97"). Needs a PR number. Not Jira or local checks.
---

body
EOF
cat > "$YD/cmds/clip-relevance-weekly.md" <<'EOF'
---
description: Weekly clip-relevance pass: propose at most five himmel changes from clips and failure records. Files nothing.
argument-hint: (none)
---

body
EOF
cat > "$YD/plain/SKILL.md" <<'EOF'
---
name: plain
description: Use when you want a plain description with no hash in it at all.
---

body
EOF
cat > "$YD/quoted/SKILL.md" <<'EOF'
---
name: quoted
description: "Use when you hold messages (bus #n from <name>) — quoted, so the hash stays."
---

body
EOF
cat > "$YD/block/SKILL.md" <<'EOF'
---
name: block
description: >
  First line of a block scalar.

  Second paragraph with a # x inside it.
---

body
EOF
cat > "$YD/hint/SKILL.md" <<'EOF'
---
name: hint
description: Use when you want a good description beside a broken neighbour.
argument-hint: [--a] [--b]
---

body
EOF
cat > "$YD/bad/SKILL.md" <<'EOF'
---
name: bad
description: a: b
---

body
EOF
cat > "$YD/bool/SKILL.md" <<'EOF'
---
name: bool
description: true
---

body
EOF
cat > "$YD/empty/SKILL.md" <<'EOF'
---
name: empty
description:
---

body
EOF

ylint() { env -u CI bash "$LINT" "$@" 2>&1; }

OUTY1="$(ylint "$YD/bus/SKILL.md")"; ECY1=$?
if [ "$ECY1" -eq 1 ]; then pass "Y1: an unquoted ' #' description exits 1"; else fail "Y1: expected exit 1, got $ECY1" "$OUTY1"; fi
assert_contains "Y1: [desc-truncated] reports the cut" "[desc-truncated]" "$OUTY1"

OUTY2A="$(ylint "$YD/bus/SKILL.md")"
OUTY2B="$(ylint "$YD/gh-pr-checks/SKILL.md")"
OUTY2C="$(ylint "$YD/cmds/clip-relevance-weekly.md")"
assert_contains "Y2: base himmel-bus bus file is [desc-truncated]" "[desc-truncated]" "$OUTY2A"
assert_contains "Y2: base gh-pr-checks file is [desc-truncated]" "[desc-truncated]" "$OUTY2B"
assert_contains "Y2: base clip-relevance-weekly command is [desc-yaml-error]" "[desc-yaml-error]" "$OUTY2C"

OUTY3="$(ylint "$YD/plain/SKILL.md")"; ECY3=$?
if [ "$ECY3" -eq 0 ]; then pass "Y3 control: a description with no # passes"; else fail "Y3 control: expected exit 0, got $ECY3" "$OUTY3"; fi

OUTY4A="$(ylint "$YD/quoted/SKILL.md")"; ECY4A=$?
if [ "$ECY4A" -eq 0 ]; then pass "Y4 control: a quoted description holding ' #' passes"; else fail "Y4 control: expected exit 0, got $ECY4A" "$OUTY4A"; fi
OUTY4B="$(ylint "$YD/block/SKILL.md")"; ECY4B=$?
if [ "$ECY4B" -eq 0 ]; then pass "Y4 control: a block scalar holding ' # x' over a blank line passes"; else fail "Y4 control: expected exit 0, got $ECY4B" "$OUTY4B"; fi

OUTY5A="$(ylint "$YD/bad/SKILL.md")"; ECY5A=$?
if [ "$ECY5A" -eq 1 ]; then pass "Y5: 'description: a: b' exits 1"; else fail "Y5: expected exit 1, got $ECY5A" "$OUTY5A"; fi
assert_contains "Y5: 'a: b' is [desc-yaml-error]" "[desc-yaml-error]" "$OUTY5A"
OUTY5B="$(ylint "$YD/bool/SKILL.md")"
assert_contains "Y5: 'description: true' is [desc-yaml-error] not text" "[desc-yaml-error]" "$OUTY5B"
assert_contains "Y5: 'description: true' says it is not text" "not text" "$OUTY5B"
OUTY5C="$(ylint "$YD/empty/SKILL.md")"
assert_contains "Y5: an empty 'description:' is [desc-yaml-error]" "[desc-yaml-error]" "$OUTY5C"

cat > "$YD/stub-noyaml.sh" <<'EOF'
#!/usr/bin/env bash
echo "stub: No module named yaml" >&2
exit 3
EOF
cat > "$YD/stub-crash.sh" <<'EOF'
#!/usr/bin/env bash
echo "stub: Traceback boom" >&2
exit 1
EOF
chmod +x "$YD/stub-noyaml.sh" "$YD/stub-crash.sh"

OUTY6A="$(env CI=true SKILL_LINT_PYTHON="$YD/stub-noyaml.sh" bash "$LINT" "$YD/plain/SKILL.md" 2>&1)"; ECY6A=$?
if [ "$ECY6A" -eq 2 ]; then pass "Y6: no PyYAML under CI=true exits 2"; else fail "Y6: expected exit 2, got $ECY6A" "$OUTY6A"; fi
assert_contains "Y6: no PyYAML prints [desc-yaml-unchecked]" "[desc-yaml-unchecked]" "$OUTY6A"
OUTY6B="$(env -u CI SKILL_LINT_PYTHON="$YD/stub-noyaml.sh" bash "$LINT" "$YD/plain/SKILL.md" 2>&1)"; ECY6B=$?
if [ "$ECY6B" -eq 0 ]; then pass "Y6: no PyYAML with CI unset keeps the status (0)"; else fail "Y6: expected exit 0, got $ECY6B" "$OUTY6B"; fi
assert_contains "Y6: no PyYAML with CI unset still prints [desc-yaml-unchecked]" "[desc-yaml-unchecked]" "$OUTY6B"
OUTY6C="$(env -u CI SKILL_LINT_PYTHON="$YD/stub-crash.sh" bash "$LINT" "$YD/plain/SKILL.md" 2>&1)"; ECY6C=$?
if [ "$ECY6C" -eq 2 ]; then pass "Y6: a helper that exits 1 makes the run exit 2"; else fail "Y6: expected exit 2, got $ECY6C" "$OUTY6C"; fi
assert_contains "Y6: the helper's stderr is printed" "Traceback boom" "$OUTY6C"

OUTY7="$(ylint "$YD/hint/SKILL.md")"; ECY7=$?
if [ "$ECY7" -eq 0 ]; then pass "Y7 control: a broken argument-hint beside a good description passes"; else fail "Y7 control: expected exit 0, got $ECY7" "$OUTY7"; fi

OUTY8="$(ylint "$YD/plain/SKILL.md" "$YD/bus/SKILL.md" "$YD/bad/SKILL.md")"; ECY8=$?
if [ "$ECY8" -eq 1 ]; then pass "Y8: several files, the second and third are checked (exit 1)"; else fail "Y8: expected exit 1, got $ECY8" "$OUTY8"; fi
assert_contains "Y8: the second file's block names its own path" "$YD/bus/SKILL.md:" "$OUTY8"
assert_contains "Y8: the third file's block names its own path" "$YD/bad/SKILL.md:" "$OUTY8"
assert_not_contains "Y8: the clean first file gets no block" "$YD/plain/SKILL.md:" "$OUTY8"
assert_contains "Y8: two files with findings count as 2 issues" "2 issue(s)" "$OUTY8"

mkdir -p "$YD/cline" "$YD/blanks"
cat > "$YD/cline/SKILL.md" <<'EOF'
---
name: cline
description: Use when you want a description followed by a comment line.
  # an indented comment line is not description text
---

body
EOF
printf -- '---\nname: blanks\ndescription: aa\n\n\n\n\n\n\n  cc #x\n---\n\nbody\n' > "$YD/blanks/SKILL.md"

OUTY9="$(ylint "$YD/cline/SKILL.md")"; ECY9=$?
if [ "$ECY9" -eq 0 ]; then pass "Y9: an indented comment line after a plain description is not a cut"; else fail "Y9: expected exit 0, got $ECY9" "$OUTY9"; fi
OUTY10="$(ylint "$YD/blanks/SKILL.md")"; ECY10=$?
if [ "$ECY10" -eq 1 ]; then pass "Y10: blank lines in a plain scalar do not hide a trailing ' #' cut"; else fail "Y10: expected exit 1, got $ECY10" "$OUTY10"; fi
assert_contains "Y10: the cut is [desc-truncated]" "[desc-truncated]" "$OUTY10"

# ---------------------------------------------------------------------------
printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
