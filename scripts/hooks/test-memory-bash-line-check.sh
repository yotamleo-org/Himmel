#!/usr/bin/env bash
# Test for scripts/hooks/memory-bash-line-check.sh: a Bash write
# to the auto-memory MEMORY.md (heredoc, sed -i, tee, printf >>) bypasses
# guard-memory-capture.sh, so the PostToolUse hook re-checks the file.
# Usage: bash scripts/hooks/test-memory-bash-line-check.sh
set -uo pipefail

HOOK="$(cd "$(dirname "$0")" && pwd)/memory-bash-line-check.sh"
FAILED=0
SB="$(mktemp -d "${TMPDIR:-/tmp}/memory-bash-line-check.XXXXXX")" || exit 1; trap 'rm -rf "$SB"' EXIT
export HOME="$SB"   # hermetic: never touches the real auto-memory
MEM="$SB/.claude/projects/proj/memory"; mkdir -p "$MEM"
IDX="$MEM/MEMORY.md"

assert_rc() {
    if [ "$3" = "$2" ]; then echo "PASS $1 (rc=$3)"
    else echo "FAIL $1 (expected rc=$2, got $3)"; FAILED=1; fi
}

repeat_char() {
    local s="$1" n="$2" i=0 out=""
    while [ "$i" -lt "$n" ]; do out="$out$s"; i=$((i + 1)); done
    printf '%s' "$out"
}

run() { # $1=tool $2=command
    jq -nc --arg t "$1" --arg c "$2" \
      '{tool_name:$t,hook_event_name:"PostToolUse",tool_input:{command:$c}}' | bash "$HOOK" 2>"$SB/err" >/dev/null
}

cmd="cat >> $IDX <<'EOF'"
ok200="- $(repeat_char x 198)"
long250="- $(repeat_char x 248)"

# 1: heredoc append of a 250-char line is flagged, naming the line.
printf -- '- short\n%s\n' "$long250" > "$IDX"
run Bash "$cmd"; assert_rc "250-char heredoc line flagged" 2 "$?"
if grep -q 'line 2' "$SB/err"; then echo "PASS names line 2"; else echo "FAIL stderr does not name line 2"; FAILED=1; fi

# 2: exactly-200-char line passes.
printf -- '- short\n%s\n' "$ok200" > "$IDX"
run Bash "$cmd"; assert_rc "200-char line passes" 0 "$?"

# 3: command that does not name MEMORY.md is ignored even with a bad index.
printf -- '%s\n' "$long250" > "$IDX"
run Bash "echo hi"; assert_rc "unrelated command ignored" 0 "$?"

# 4: a MEMORY.md outside the auto-memory store is ignored.
mkdir -p "$SB/other"; printf -- '%s\n' "$long250" > "$SB/other/MEMORY.md"
run Bash "cat >> $SB/other/MEMORY.md <<'EOF'"; assert_rc "non-auto-memory MEMORY.md ignored" 0 "$?"

# 5: non-Bash tool ignored.
run Edit "$cmd"; assert_rc "non-Bash tool ignored" 0 "$?"

# 6: MEMORY_LINE_MAX knob is honoured (shared with the guard).
printf -- '%s\n' "$ok200" > "$IDX"
MEMORY_LINE_MAX=100 run Bash "$cmd"; assert_rc "MEMORY_LINE_MAX=100 flags a 200-char line" 2 "$?"

# 7: MEMORY_CAPTURE_OK=1 bypass.
printf -- '%s\n' "$long250" > "$IDX"
MEMORY_CAPTURE_OK=1 run Bash "$cmd"; assert_rc "MEMORY_CAPTURE_OK=1 bypass" 0 "$?"

# 8: missing index file is a silent allow.
rm -f "$IDX"
run Bash "$cmd"; assert_rc "missing index allowed" 0 "$?"

# 9: a star in the command text must not glob : bounded run.
printf -- '- short\n' > "$IDX"
jq -nc --arg c "echo '/*/*/*/*/*/*/*/.claude/projects/*/memory/MEMORY.md'" \
  '{tool_name:"Bash",tool_input:{command:$c}}' > "$SB/star.json"
timeout 20 bash "$HOOK" < "$SB/star.json" >/dev/null 2>&1
assert_rc "star path does not glob (finishes under 20s)" 0 "$?"

# 10: the same path named repeatedly is reported once.
printf -- '- short\n%s\n' "$long250" > "$IDX"
run Bash "cat $IDX; cat $IDX; cat $IDX"; assert_rc "repeated path flagged" 2 "$?"
n="$(grep -c 'line 2' "$SB/err")"
if [ "$n" = 1 ]; then echo "PASS repeated path reported once"; else echo "FAIL repeated path reported $n times"; FAILED=1; fi

# 11: a Bash write naming a topic file over MEMORY_TOPIC_MAX prints a
# topic-cap warning; 8192 bytes is clean; a topic file outside the store is ignored.
TOP="$MEM/theme.md"
head -c 8193 /dev/zero | tr '\0' 'a' > "$TOP"
run Bash "cat >> $TOP <<'EOF'"; assert_rc "8193-byte topic file named by a Bash write is flagged" 2 "$?"
if grep -q 'topic-cap' "$SB/err" && grep -q 'theme.md' "$SB/err"; then echo "PASS topic-cap warning names the file"; else echo "FAIL no topic-cap warning naming the file"; FAILED=1; fi
head -c 8192 /dev/zero | tr '\0' 'a' > "$TOP"
run Bash "cat >> $TOP <<'EOF'"; assert_rc "8192-byte topic file is clean" 0 "$?"
head -c 8193 /dev/zero | tr '\0' 'a' > "$SB/other/theme.md"
run Bash "cat >> $SB/other/theme.md <<'EOF'"; assert_rc "topic file outside the auto-memory store ignored" 0 "$?"
head -c 8193 /dev/zero | tr '\0' 'a' > "$TOP"
MEMORY_CAPTURE_OK=1 run Bash "cat >> $TOP <<'EOF'"; assert_rc "MEMORY_CAPTURE_OK=1 bypasses the topic-cap warning" 0 "$?"
MEMORY_TOPIC_MAX=9000 run Bash "cat >> $TOP <<'EOF'"; assert_rc "MEMORY_TOPIC_MAX=9000 knob honoured" 0 "$?"

# 12: with CLAUDE_CONFIG_DIR set, its projects/*/memory store is checked too;
# the same path is ignored when that variable is unset.
CFG="$SB/cfg"; mkdir -p "$CFG/projects/p/memory"
head -c 8193 /dev/zero | tr '\0' 'a' > "$CFG/projects/p/memory/theme.md"
CLAUDE_CONFIG_DIR="$CFG" run Bash "cat >> $CFG/projects/p/memory/theme.md <<'EOF'"; assert_rc "topic file under CLAUDE_CONFIG_DIR flagged" 2 "$?"
run Bash "cat >> $CFG/projects/p/memory/theme.md <<'EOF'"; assert_rc "same path ignored when CLAUDE_CONFIG_DIR is unset" 0 "$?"

exit "$FAILED"
