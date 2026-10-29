#!/usr/bin/env bash
# Smoke test for scripts/hooks/guard-memory-capture.sh.
# Usage: bash scripts/hooks/test-guard-memory-capture.sh
# Exit: 0 all passed, 1 at least one failure.
#
# Rev2 note: the hook's adopter story is UNCONDITIONAL — no vault/qmd predicate,
# so these cases need neither LUNA_VAULT_PATH nor a lookup seam. HOME is still
# redirected into the sandbox for hermeticity (no real registry / capture log).
set -uo pipefail

HOOK="$(cd "$(dirname "$0")" && pwd)/guard-memory-capture.sh"
[ -x "$HOOK" ] || chmod +x "$HOOK"
FAILED=0
SB="$(mktemp -d)"; trap 'rm -rf "$SB"' EXIT
export HOME="$SB"                      # hermetic: no real registry / capture log
MEM="$SB/.claude/projects/proj/memory"; mkdir -p "$MEM"
export MEMORY_CAPTURE_LOG="$SB/capture.jsonl"

assert_rc() {
    if [ "$3" = "$2" ]; then echo "PASS $1 (rc=$3)"
    else echo "FAIL $1 (expected rc=$2, got $3)"; FAILED=1; fi
}

payload() { # $1=tool $2=file_path $3=content
    jq -nc --arg t "$1" --arg f "$2" --arg c "$3" \
      '{tool_name:$t,hook_event_name:"PreToolUse",tool_input:{file_path:$f,content:$c}}'
}

# bash-3.2-safe repeat helper (no `seq`, not guaranteed present on all
# supported macOS shells). $1=string to repeat, $2=repeat count.
repeat_char() {
    local s="$1" n="$2" i=0 out=""
    while [ "$i" -lt "$n" ]; do
        out="$out$s"
        i=$((i + 1))
    done
    printf '%s' "$out"
}

long="- $(repeat_char x 250) -> luna [[n]]"
ok="- rtk masks gitleaks blocks -> luna [[himmel-harness-gotchas]]"
big="$(repeat_char y 900)"
# 199 CHARACTERS with 20 em-dashes mixed in (each is 3 bytes, so the line is
# 239 BYTES): must be counted as chars, not bytes, or this trips the 200-char
# rule early. Kept well under the 400B growth cap so only the
# line-length rule is in play.
emdash_199="- $(repeat_char '—' 20)$(repeat_char x 177)"
# 201 ASCII chars (== 201 bytes either way): must still be denied.
ascii_201="- $(repeat_char x 199)"

# 1: >200-char line in MEMORY.md is DENIED.
printf -- '- short\n' > "$MEM/MEMORY.md"
payload Write "$MEM/MEMORY.md" "$long" | bash "$HOOK" >/dev/null 2>&1
assert_rc "over-length line denied" 2 "$?"

# 2: a compliant line is ALLOWED.
payload Write "$MEM/MEMORY.md" "$ok" | bash "$HOOK" >/dev/null 2>&1
assert_rc "compliant line allowed" 0 "$?"

# 2b: a 199-CHAR line with multibyte em-dashes (>200 bytes) is
# ALLOWED — the rule is char-based, and this env has no LANG/LC_ALL by default.
payload Write "$MEM/MEMORY.md" "$emdash_199" | bash "$HOOK" >/dev/null 2>&1
assert_rc "199-char em-dash line allowed (chars, not bytes)" 0 "$?"

# 2c: a 201-char ASCII line is still DENIED.
payload Write "$MEM/MEMORY.md" "$ascii_201" | bash "$HOOK" >/dev/null 2>&1
assert_rc "201-char ASCII line still denied" 2 "$?"

# 3 (Rev2): a large topic-file body is ALLOWED — theme files are tier-2, unrestricted.
payload Write "$MEM/some-fact.md" "$big" | bash "$HOOK" >/dev/null 2>&1
assert_rc "large topic body allowed (tier-2, no body cap)" 0 "$?"

# 4 (Rev2): an Edit to a TOPIC file is ALLOWED — blanket Edit denial dropped for topic files.
jq -nc --arg f "$MEM/some-fact.md" '{tool_name:"Edit",hook_event_name:"PreToolUse",tool_input:{file_path:$f,old_string:"a",new_string:"b"}}' \
  | bash "$HOOK" >/dev/null 2>&1
assert_rc "topic-file Edit allowed" 0 "$?"

# 5: *.bak EXEMPT.
payload Write "$MEM/MEMORY.md.bak" "$long" | bash "$HOOK" >/dev/null 2>&1
assert_rc "bak exempt" 0 "$?"

# 6: Edit to MEMORY.md is DECIDABLE — simulated against the
# on-disk file and validated with the same checks as Write.
printf -- '- alpha route -> luna [[a]]\n' > "$MEM/MEMORY.md"
jq -nc --arg f "$MEM/MEMORY.md" '{tool_name:"Edit",hook_event_name:"PreToolUse",tool_input:{file_path:$f,old_string:"alpha",new_string:"beta"}}' \
  | bash "$HOOK" >/dev/null 2>&1
assert_rc "valid Edit to MEMORY.md allowed" 0 "$?"

# 6b: an Edit whose simulated RESULT violates a rule is denied with the same
# reason a Write would get (one code path — checks run on the simulated $content).
printf -- '- alpha route -> luna [[a]]\n' > "$MEM/MEMORY.md"
: > "$MEMORY_CAPTURE_LOG"
longfill="$(repeat_char z 210)"
jq -nc --arg f "$MEM/MEMORY.md" --arg ns "$longfill" \
  '{tool_name:"Edit",hook_event_name:"PreToolUse",tool_input:{file_path:$f,old_string:"route",new_string:$ns}}' \
  | bash "$HOOK" >/dev/null 2>&1
assert_rc "Edit whose simulated result is over-length is denied" 2 "$?"
grep -q '"rule":"line-too-long"' "$MEMORY_CAPTURE_LOG"
assert_rc "denied Edit logs the same rule id as Write (line-too-long)" 0 "$?"

# 6c: MultiEdit applies edits.[] SEQUENTIALLY (second old_string only exists
# after the first edit lands) and is allowed when the result is compliant.
printf -- '- alpha route -> luna [[a]]\n' > "$MEM/MEMORY.md"
jq -nc --arg f "$MEM/MEMORY.md" \
  '{tool_name:"MultiEdit",hook_event_name:"PreToolUse",tool_input:{file_path:$f,edits:[{old_string:"alpha",new_string:"beta"},{old_string:"beta route",new_string:"beta path"}]}}' \
  | bash "$HOOK" >/dev/null 2>&1
assert_rc "MultiEdit applies edits sequentially and is allowed" 0 "$?"

# 6d: old_string not found -> ALLOW (the Edit tool itself errors on this, not
# this guard).
printf -- '- alpha route -> luna [[a]]\n' > "$MEM/MEMORY.md"
jq -nc --arg f "$MEM/MEMORY.md" '{tool_name:"Edit",hook_event_name:"PreToolUse",tool_input:{file_path:$f,old_string:"NOPE-NOT-PRESENT",new_string:"x"}}' \
  | bash "$HOOK" >/dev/null 2>&1
assert_rc "Edit old_string not found is allowed" 0 "$?"

# 6e: the simulation must splice new_string LITERALLY.
#     `String.replace(str, str)` would expand the `$&` below into the 30-char
#     match, pushing the line from 184 to 214 chars -> a phantom line-too-long
#     deny on an edit that is actually compliant.
tok30="$(repeat_char T 30)"
printf -- '- %s\n' "$tok30" > "$MEM/MEMORY.md"
jq -nc --arg f "$MEM/MEMORY.md" --arg o "$tok30" --arg n "$(repeat_char x 180)\$&" \
  '{tool_name:"Edit",hook_event_name:"PreToolUse",tool_input:{file_path:$f,old_string:$o,new_string:$n}}' \
  | bash "$HOOK" >/dev/null 2>&1
assert_rc "Edit new_string with \$& is spliced literally (no pattern expansion)" 0 "$?"

# 6f: trailing newlines must survive the simulation.
#     `$( )` strips them, so without the EOT sentinel this +500B edit measures
#     as -1B and slips past the 400B growth cap.
printf -- '- a\n' > "$MEM/MEMORY.md"
jq -nc --arg f "$MEM/MEMORY.md" \
  '{tool_name:"Edit",hook_event_name:"PreToolUse",tool_input:{file_path:$f,old_string:"a",new_string:("a" + ("\n" * 500))}}' \
  | bash "$HOOK" >/dev/null 2>&1
assert_rc "Edit appending 500 trailing newlines hits the growth cap" 2 "$?"

# 6g: a NON-ENOENT read error is undecidable, not an
#     empty new file — fail closed. A directory at the index path gives EISDIR.
rm -f "$MEM/MEMORY.md"; mkdir -p "$MEM/MEMORY.md"
jq -nc --arg f "$MEM/MEMORY.md" '{tool_name:"Edit",hook_event_name:"PreToolUse",tool_input:{file_path:$f,old_string:"a",new_string:"b"}}' \
  | bash "$HOOK" >/dev/null 2>&1
assert_rc "unreadable MEMORY.md denies as undecidable (fail-closed)" 2 "$?"
rmdir "$MEM/MEMORY.md"

# 7: paths OUTSIDE the memory dir untouched.
payload Write "$SB/unrelated.md" "$long" | bash "$HOOK" >/dev/null 2>&1
assert_rc "non-memory path ignored" 0 "$?"

# 8: net growth >400B DENIED.
printf -- '- a\n' > "$MEM/MEMORY.md"
grow="$(repeat_char $'- b -> luna [[n]]\n' 40)"
payload Write "$MEM/MEMORY.md" "$grow" | bash "$HOOK" >/dev/null 2>&1
assert_rc "net growth cap denied" 2 "$?"

# 9: >60-line MEMORY.md write DENIED (the structural ceiling, Rev2 D4).
#    Old file already at 62 lines and new content at 65 lines, each 4B: growth is
#    ~11B (< cap) so ONLY the ceiling can fire. Assert the deny rule to prove it.
: > "$MEMORY_CAPTURE_LOG"
repeat_char $'- x\n' 62 > "$MEM/MEMORY.md"
ceil="$(repeat_char $'- x\n' 65)"
payload Write "$MEM/MEMORY.md" "$ceil" | bash "$HOOK" >/dev/null 2>&1
assert_rc "over-ceiling line count denied" 2 "$?"
grep -q '"rule":"line-ceiling"' "$MEMORY_CAPTURE_LOG"
assert_rc "ceiling deny logged with its own rule id" 0 "$?"

# 10: bypass wins over every deny branch (checked FIRST).
printf -- '- short\n' > "$MEM/MEMORY.md"
payload Write "$MEM/MEMORY.md" "$long" | MEMORY_CAPTURE_OK=1 bash "$HOOK" >/dev/null 2>&1
assert_rc "bypass allows a would-be deny" 0 "$?"

# 11: deny log carries a hash+excerpt record.
grep -q '"event":"deny"' "$MEMORY_CAPTURE_LOG" && grep -q '"hash"' "$MEMORY_CAPTURE_LOG"
assert_rc "deny logged with hash" 0 "$?"

# 12 (Edit is decidable now, so this regression case moved to
#     NotebookEdit — the one tool_name still forced through the undecidable-
#     payload deny): a deny logs the .new_string excerpt (spike-confirmed
#     INDEX_APPEND_TOOL=Edit shape). Without the .new_string fallback every
#     such deny would log empty.
: > "$MEMORY_CAPTURE_LOG"
jq -nc --arg f "$MEM/MEMORY.md" '{tool_name:"NotebookEdit",hook_event_name:"PreToolUse",tool_input:{file_path:$f,old_string:"a",new_string:"UNIQUE-NEWSTR-9931"}}' \
  | bash "$HOOK" >/dev/null 2>&1
grep -q 'UNIQUE-NEWSTR-9931' "$MEMORY_CAPTURE_LOG"
assert_rc "NotebookEdit deny logs the new_string excerpt (not empty)" 0 "$?"

# --- Regression cases for the two FAIL-OPEN bugs found in review. Both shipped
# --- green against a naive suite. Do not remove.

# 13: ZERO '- ' lines must not crash the hook (grep -c prints 0 AND exits 1 ->
#     "0\n0" -> arithmetic error -> exit 1 -> PreToolUse fails OPEN, ungated).
printf 'no bullets at all\n' > "$MEM/MEMORY.md"
payload Write "$MEM/MEMORY.md" "still no bullets" | bash "$HOOK" >/dev/null 2>&1
assert_rc "zero-pointer-line content does not crash the hook" 0 "$?"

# 14: a WINDOWS backslash path must still be scoped (the POSIX glob never matches
#     C:\...\memory\MEMORY.md -> hook silently no-ops across its scope).
printf -- '- short\n' > "$MEM/MEMORY.md"
# tr with an octal backslash (\134) avoids sed's `\|`-as-escaped-delimiter trap
# in this Git-Bash sed AND tr's "unescaped backslash at end of string" warning.
winfp="$(printf '%s' "$MEM/MEMORY.md" | tr '/' '\134')"
payload Write "$winfp" "$long" | bash "$HOOK" >/dev/null 2>&1
assert_rc "backslash path still gated (not a silent no-op)" 2 "$?"

# --- line-too-long must be DIFF-SCOPED (added/changed lines
# --- only), not a whole-file re-scan of every PRE-EXISTING line. A legacy
# --- over-length line already committed to MEMORY.md (grandfathered before
# --- this rule existed, or before the cap was lowered) used to freeze the
# --- index — deny EVERY future write, even one that only appends an
# --- unrelated, fully-compliant new line.

legacy_bad="- $(repeat_char x 250) -> luna [[legacy]]"
# An em-dash-heavy legacy line genuinely over 200 CHARS (not just bytes) —
# the real shape reported (a 227-char routing line with
# several em dashes already committed to the live MEMORY.md).
legacy_emdash="- $(repeat_char '—' 30)$(repeat_char x 190) -> luna [[legacy-emdash]]"

# 15: a pre-existing over-length line does not block a NEW compliant append.
printf -- '%s\n' "$legacy_bad" > "$MEM/MEMORY.md"
newcontent="$legacy_bad
- new short line -> luna [[n]]"
payload Write "$MEM/MEMORY.md" "$newcontent" | bash "$HOOK" >/dev/null 2>&1
assert_rc "pre-existing over-length line does not block a new compliant append" 0 "$?"

# 15b: a NEWLY added over-length line is still denied even alongside an
#      untouched pre-existing over-length line.
newcontent_bad="$legacy_bad
$long"
payload Write "$MEM/MEMORY.md" "$newcontent_bad" | bash "$HOOK" >/dev/null 2>&1
assert_rc "a newly added over-length line is still denied" 2 "$?"

# 15c: an Edit whose simulated result still carries an untouched pre-existing
#      over-length line ELSEWHERE in the file is ALLOWED — only what this
#      edit actually touched is checked.
printf -- '%s\n- alpha route -> luna [[a]]\n' "$legacy_bad" > "$MEM/MEMORY.md"
jq -nc --arg f "$MEM/MEMORY.md" '{tool_name:"Edit",hook_event_name:"PreToolUse",tool_input:{file_path:$f,old_string:"alpha",new_string:"beta"}}' \
  | bash "$HOOK" >/dev/null 2>&1
assert_rc "Edit unrelated to a pre-existing over-length line is allowed" 0 "$?"

# 15d: editing the legacy over-length line ITSELF into something still
#      over-length is still denied (the edit target IS the changed line).
printf -- '%s\n' "$legacy_bad" > "$MEM/MEMORY.md"
jq -nc --arg f "$MEM/MEMORY.md" --arg ns "$(repeat_char y 250)" \
  '{tool_name:"Edit",hook_event_name:"PreToolUse",tool_input:{file_path:$f,old_string:"legacy",new_string:$ns}}' \
  | bash "$HOOK" >/dev/null 2>&1
assert_rc "editing the legacy line itself into another over-length line is still denied" 2 "$?"

# 15f: a NEW occurrence of text that happens to be
#     BYTE-IDENTICAL to an already-grandfathered over-length line must still
#     be checked (and denied) — a plain set-difference ("does this new line's
#     text appear anywhere in old?") would wrongly treat the second, genuinely
#     new copy as "already existed" and skip it entirely. Multiset (bag)
#     difference closes this: the duplicate is a fresh occurrence beyond what
#     old already had.
printf -- '%s\n' "$legacy_bad" > "$MEM/MEMORY.md"
dup_content="$legacy_bad
$legacy_bad"
payload Write "$MEM/MEMORY.md" "$dup_content" | bash "$HOOK" >/dev/null 2>&1
assert_rc "a duplicated copy of a grandfathered over-length line is still denied" 2 "$?"

# 15g: an on-disk MEMORY.md with CRLF line endings must
#     not make every untouched line look "added" (a trailing \r on the OLD
#     line vs an LF-only new payload) and resurrect the pre-existing-line
#     re-validation bug this whole fix exists to close.
printf -- '%s\r\n' "$legacy_bad" > "$MEM/MEMORY.md"
newcontent_crlf="$legacy_bad
- new short line -> luna [[n]]"
payload Write "$MEM/MEMORY.md" "$newcontent_crlf" | bash "$HOOK" >/dev/null 2>&1
assert_rc "a CRLF-terminated pre-existing over-length line does not block a new compliant append" 0 "$?"

# 15e: same as 15, but the legacy over-length line is an EM-DASH-HEAVY line
#      (the exact repro shape from a live MEMORY.md) — a new
#      compliant append still lands.
printf -- '%s\n' "$legacy_emdash" > "$MEM/MEMORY.md"
newcontent_emdash="$legacy_emdash
- new short line -> luna [[n]]"
payload Write "$MEM/MEMORY.md" "$newcontent_emdash" | bash "$HOOK" >/dev/null 2>&1
assert_rc "an em-dash-heavy pre-existing over-length line does not block a new compliant append" 0 "$?"

# ---------------------------------------------------------------------------
# the ceiling / line-length rules as a STATE check.
#
# The PreToolUse guard above only ever sees a Write/Edit payload. MEMORY.md grew
# 74 -> 134 pointer lines against a ceiling of 60 because the default way of
# working in auto-mode is a heredoc / `cat >>` / `sed -i` / a script, and Bash
# is (deliberately) not in the guard's matcher. memory-index-state-notice.sh
# reads the FILE at SessionStart instead, so it cannot care how it was written.
STATE_HOOK="$(cd "$(dirname "$0")" && pwd)/memory-index-state-notice.sh"
[ -x "$STATE_HOOK" ] || chmod +x "$STATE_HOOK"

# $1 = number of ` - ` pointer lines; header + trailing prose are NOT pointers.
mk_index() {
    local n="$1" i=1
    printf '# Memory index\n\nThis index routes.\n\n' > "$MEM/MEMORY.md"
    while [ "$i" -le "$n" ]; do
        printf -- '- theme %s -> luna [[theme-%s]]\n' "$i" "$i" >> "$MEM/MEMORY.md"
        i=$((i + 1))
    done
    printf '\nprose tail, not a pointer line\n' >> "$MEM/MEMORY.md"
}
run_state() { # sets $out / $rc; MEMDIR points the hook at the fixture
    out="$(MEMDIR="$MEM" bash "$STATE_HOOK" </dev/null 2>&1)"; rc=$?
}
assert_contains() { # $1=name $2=needle
    case "$out" in *"$2"*) echo "PASS $1" ;; *) echo "FAIL $1 (missing '$2' in: $out)"; FAILED=1 ;; esac
}
assert_silent() { # $1=name
    if [ -z "$out" ] && [ "$rc" = 0 ]; then echo "PASS $1 (silent, rc=0)"
    else echo "FAIL $1 (rc=$rc out: $out)"; FAILED=1; fi
}
deny_rows() { grep -c '"event":"deny"' "$MEMORY_CAPTURE_LOG" 2>/dev/null || true; }

# S1 (control — the fixture is sound and the watched path IS gated): a Write
#    payload that would take a 60-pointer index to 61 is denied line-ceiling.
mk_index 60
over61="$(cat "$MEM/MEMORY.md")
- one more -> luna [[n]]"
payload Write "$MEM/MEMORY.md" "$over61" | bash "$HOOK" >/dev/null 2>&1
assert_rc "S1 control: Write past the ceiling is denied by the PreToolUse guard" 2 "$?"

# S2 (the reproduced defect): the SAME append through the ungated path lands,
#    and the guard logs no deny — it was never invoked.
mk_index 60
before_deny="$(deny_rows)"
cat >> "$MEM/MEMORY.md" <<'EOF'
- one more, via a heredoc append -> luna [[n]]
EOF
n_ptr="$(awk '/^- /{n++} END{print n+0}' "$MEM/MEMORY.md")"
if [ "$n_ptr" = 61 ] && [ "$(deny_rows)" = "$before_deny" ]; then
    echo "PASS S2 repro: heredoc append reached 61 pointer lines with no deny row logged"
else echo "FAIL S2 repro (pointers=$n_ptr deny_rows before=$before_deny after=$(deny_rows))"; FAILED=1; fi

# S3 (the fix): the state check names the ceiling on the file S2 produced.
run_state
assert_contains "S3 state check flags the ungated append (line-ceiling)" "line-ceiling"
assert_contains "S3 names the pointer-line count" "61 pointer lines"
assert_contains "S3 names the ceiling" "ceiling 60"
assert_rc "S3 advisory never fails the session" 0 "$rc"

# S4 (false-positive control): an index AT the ceiling, with a header and a
#    prose tail that must not count as pointers, is silent.
mk_index 60
run_state
assert_silent "S4 60 pointer lines (at the ceiling) is not flagged"

# S5: env override is honoured (same knob the guard reads).
mk_index 6
out="$(MEMDIR="$MEM" MEMORY_LINE_CEIL=5 bash "$STATE_HOOK" </dev/null 2>&1)"; rc=$?
assert_contains "S5 MEMORY_LINE_CEIL=5 flags 6 pointer lines" "line-ceiling"

# S6: line-too-long is evaded identically — an over-length line appended via
#    the ungated path is named, with its line number.
mk_index 10
printf -- '- %s -> luna [[n]]\n' "$(repeat_char x 250)" >> "$MEM/MEMORY.md"
run_state
assert_contains "S6 over-length line appended via cat is flagged" "line-too-long"
assert_contains "S6 names the offending line number (4 header + 10 pointers + blank + prose tail = line 17)" "line 17"

# S7: the 200-char boundary is chars, not bytes — exactly 200 is fine, 201 is not.
mk_index 3
printf -- '- %s\n' "$(repeat_char x 198)" >> "$MEM/MEMORY.md"
run_state
assert_silent "S7 a 200-char pointer line is not flagged"
printf -- '- %s\n' "$(repeat_char x 199)" >> "$MEM/MEMORY.md"
run_state
assert_contains "S7 a 201-char pointer line IS flagged" "line-too-long"

# S8: 20 em-dashes (3 bytes each) in a 199-CHAR line: bytes > 200, chars < 200.
mk_index 3
printf -- '%s\n' "$emdash_199" >> "$MEM/MEMORY.md"
run_state
assert_silent "S8 199-char em-dash line is not flagged (chars, not bytes)"

# S9: a CRLF index must not push a 200-char line to 201.
mk_index 3
printf -- '- %s\r\n' "$(repeat_char x 198)" >> "$MEM/MEMORY.md"
run_state
assert_silent "S9 a 200-char CRLF line is not flagged"

# S10: no MEMORY.md at all (adopter with no auto-memory) -> silent, rc=0.
rm -f "$MEM/MEMORY.md"
run_state
assert_silent "S10 missing MEMORY.md is silent"

# S11: both rules at once are both reported in one block.
mk_index 62
printf -- '- %s\n' "$(repeat_char x 250)" >> "$MEM/MEMORY.md"
run_state
assert_contains "S11 reports the ceiling" "line-ceiling"
assert_contains "S11 reports line-too-long alongside it" "line-too-long"

# S12: the state check and the guard must not drift — they read the same knobs
#    with the same defaults.
for knob in MEMORY_LINE_CEIL MEMORY_LINE_MAX; do
    g="$(grep -o "\${$knob:-[0-9]*}" "$HOOK" | head -1)"
    s="$(grep -o "\${$knob:-[0-9]*}" "$STATE_HOOK" | head -1)"
    if [ -n "$g" ] && [ "$g" = "$s" ]; then echo "PASS S12 $knob default agrees ($g)"
    else echo "FAIL S12 $knob default drifted (guard='$g' state='$s')"; FAILED=1; fi
done

# --- FAIL-OPEN: the state check runs on EVERY session start (chiefs and workers
#     included). Whatever is wrong with the memory dir, the hook exits 0 and
#     stays silent — a memory advisory must never stop a session from starting.
#     Each fixture below is OVER the ceiling where it can be, so silence is the
#     failure path working, not a healthy file.
mk_index 70

# F1: MEMORY.md is a directory (unreadable as a file).
rm -f "$MEM/MEMORY.md"; mkdir "$MEM/MEMORY.md"
run_state
assert_silent "F1 fail-open: MEMORY.md is a directory"
rmdir "$MEM/MEMORY.md"

# F2: MEMORY.md is a dangling symlink.
ln -s "$SB/does-not-exist" "$MEM/MEMORY.md"
run_state
assert_silent "F2 fail-open: MEMORY.md is a dangling symlink"
rm -f "$MEM/MEMORY.md"

# F3: no read permission (skipped as root, where chmod cannot deny the read).
mk_index 70
chmod 000 "$MEM/MEMORY.md"
if [ -r "$MEM/MEMORY.md" ]; then echo "SKIP F3 (this uid can read a mode-000 file)"
else run_state; assert_silent "F3 fail-open: MEMORY.md is not readable"; fi
chmod 644 "$MEM/MEMORY.md"

# F4: a garbage env knob must not crash or block the session.
out="$(MEMDIR="$MEM" MEMORY_LINE_CEIL=abc bash "$STATE_HOOK" </dev/null 2>&1)"; rc=$?
assert_silent "F4 fail-open: non-numeric MEMORY_LINE_CEIL"

# F4b (CR): a NUMERIC but oversized ceiling passes the digit check
#     and then reaches `[ "$n" -gt "$LINE_CEIL" ]`, where bash prints "integer
#     expected" to stderr. rc stays 0 (fail-open) but the healthy path is no
#     longer silent. 70 pointers vs an effectively infinite ceiling = healthy.
#     run_state merges stderr into $out, so assert_silent covers both.
for big in 999999999999999999999999 9223372036854775808; do
    out="$(MEMDIR="$MEM" MEMORY_LINE_CEIL=$big bash "$STATE_HOOK" </dev/null 2>&1)"; rc=$?
    assert_silent "F4b fail-open: oversized numeric MEMORY_LINE_CEIL=$big (stdout AND stderr silent)"
done
# ...and it must still report line-too-long, i.e. clamping the ceiling must not
# silence the other rule.
printf -- '- %s -> luna [[n]]\n' "$(repeat_char x 250)" >> "$MEM/MEMORY.md"
out="$(MEMDIR="$MEM" MEMORY_LINE_CEIL=999999999999999999999999 bash "$STATE_HOOK" </dev/null 2>&1)"; rc=$?
assert_contains "F4b an oversized ceiling still reports line-too-long" "line-too-long"
assert_rc "F4b oversized ceiling exits 0" 0 "$rc"
mk_index 70

# F5: awk itself fails (a stub that exits 3 ahead of the real one on PATH).
mkdir -p "$SB/badbin"; printf '#!/bin/sh\nexit 3\n' > "$SB/badbin/awk"; chmod +x "$SB/badbin/awk"
out="$(PATH="$SB/badbin:$PATH" MEMDIR="$MEM" bash "$STATE_HOOK" </dev/null 2>&1)"; rc=$?
assert_silent "F5 fail-open: awk exits non-zero"

# F6: no MEMDIR and no git repo at all -> cannot derive a memory dir -> silent.
mkdir -p "$SB/not-a-repo"
out="$(env -u MEMDIR CLAUDE_PROJECT_DIR="$SB/not-a-repo" GIT_CEILING_DIRECTORIES="$SB" bash "$STATE_HOOK" </dev/null 2>&1)"; rc=$?
assert_silent "F6 fail-open: MEMDIR unset and not inside a git repo"

# --- MEMDIR derivation: memory lives under the PRIMARY checkout's slug, also
#     when the session starts in a linked worktree.
mk_index 61
mkdir -p "$SB/repo"
# The hook slugs git's own (physical) common-dir, so derive the expected slug
# from the physical path too: under a symlinked TMPDIR (macOS /var ->
# /private/var) the spelling $SB/repo would slug to a different directory.
REPO="$(cd -P "$SB/repo" && pwd -P)"
git -C "$REPO" init -q 2>/dev/null
git -C "$REPO" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init 2>/dev/null
git -C "$REPO" worktree add -q "$SB/wt" -b wt 2>/dev/null
slug="$(printf '%s' "$REPO" | sed 's/[^A-Za-z0-9]/-/g')"
mkdir -p "$SB/.claude/projects/$slug/memory"; cp "$MEM/MEMORY.md" "$SB/.claude/projects/$slug/memory/MEMORY.md"
out="$(env -u MEMDIR CLAUDE_PROJECT_DIR="$REPO" bash "$STATE_HOOK" </dev/null 2>&1)"; rc=$?
assert_contains "D1 derives the memory dir from the primary checkout" "line-ceiling"
out="$(env -u MEMDIR CLAUDE_PROJECT_DIR="$SB/wt" bash "$STATE_HOOK" </dev/null 2>&1)"; rc=$?
assert_contains "D2 a session started in a worktree still finds the primary's memory" "line-ceiling"

# --- Wired shape: through the SAME --chain --lifecycle runner settings.json
#     uses, the advisory reaches stdout and the runner exits 0.
if command -v node >/dev/null 2>&1; then
    RUNNER="$(cd "$(dirname "$0")" && pwd)/run-hook-with-bash.js"
    mk_index 61
    out="$(MEMDIR="$MEM" node "$RUNNER" --chain --lifecycle "$STATE_HOOK" </dev/null 2>&1)"; rc=$?
    assert_contains "W1 advisory is delivered through the lifecycle chain runner" "line-ceiling"
    assert_rc "W1 chain runner exits 0" 0 "$rc"
    mk_index 60
    out="$(MEMDIR="$MEM" node "$RUNNER" --chain --lifecycle "$STATE_HOOK" </dev/null 2>&1)"; rc=$?
    assert_silent "W2 a healthy index is silent through the chain runner"
    # W3: does the runner forward a member's stderr?
    #    Establishes whether a stray stderr line from the advisory is visible at
    #    all, so the "silent when healthy" claim is stated as measured.
    printf '#!/bin/sh\necho stderr-marker-from-member >&2\nexit 0\n' > "$SB/stderr-member.sh"; chmod +x "$SB/stderr-member.sh"
    out="$(node "$RUNNER" --chain --lifecycle "$SB/stderr-member.sh" </dev/null 2>&1 >/dev/null)"; rc=$?
    assert_contains "W3 the lifecycle chain runner forwards a member's stderr" "stderr-marker-from-member"
else echo "SKIP W1/W2 (node not on PATH)"; fi

# ---------------------------------------------------------------------------
# A write that does not add pointer lines passes over the ceiling;
# topic files over MEMORY_TOPIC_MAX that grow get a warn-only advisory; every
# capture-log row names its session. All rows use a scratch log + scratch store.
M2="$SB/.claude/projects/p2/memory"; mkdir -p "$M2"
fill() { head -c "$1" /dev/zero | tr '\0' 'a'; }   # $1 bytes of 'a' # read-sink-ok: reads /dev/zero, $1 is a byte count
# $1=tool $2=file $3=content $4=session_id -> $SB/p.json
wp() {
    jq -nc --arg t "$1" --arg f "$2" --arg c "$3" --arg s "${4-}" \
      '{tool_name:$t,session_id:$s,tool_input:{file_path:$f,content:$c}}' > "$SB/p.json"
}
# $1=tool(Edit|MultiEdit) $2=file $3=old $4=new $5=session_id -> $SB/p.json
ep() {
    if [ "$1" = Edit ]; then
        jq -nc --arg f "$2" --arg o "$3" --arg n "$4" --arg s "${5-}" \
          '{tool_name:"Edit",session_id:$s,tool_input:{file_path:$f,old_string:$o,new_string:$n}}' > "$SB/p.json"
    else
        jq -nc --arg f "$2" --arg o "$3" --arg n "$4" --arg s "${5-}" \
          '{tool_name:"MultiEdit",session_id:$s,tool_input:{file_path:$f,edits:[{old_string:$o,new_string:($n[0:150])},{old_string:"TAIL",new_string:("TAIL" + $n[150:])}]}}' > "$SB/p.json"
    fi
}
hook_rc() { # runs the fixture payload; sets $out (stdout) and returns the hook rc
    out="$(bash "$HOOK" < "$SB/p.json" 2>"$SB/err")"
}
log_has() { grep -q "$1" "$MEMORY_CAPTURE_LOG"; }
one_undecidable() { [ "$(grep -c '"rule":"topic-cap-undecidable"' "$MEMORY_CAPTURE_LOG")" = 1 ]; }
log_row() { # $1=session $2=old $3=new: a row with exactly these fields
    jq -e --arg s "$1" --argjson o "$2" --argjson n "$3" 'select(.session_id==$s and .old==$o and .new==$n)' "$MEMORY_CAPTURE_LOG" >/dev/null
}
# $1=name $2=1 (must fire) | 0 (must stay clean): both modes
tc() {
    : > "$MEMORY_CAPTURE_LOG"
    hook_rc; rc=$?
    assert_rc "$1 (warn mode allows)" 0 "$rc"
    if [ "$2" = 1 ]; then
        case "$out" in *additionalContext*"sub-file linked from its hub"*) echo "PASS $1 warn advisory names the hub procedure" ;; *) echo "FAIL $1 warn advisory missing (out: $out)"; FAILED=1 ;; esac
        log_has '"event":"warn","rule":"topic-cap"'; assert_rc "$1 logs a topic-cap warn row" 0 "$?"
        : > "$MEMORY_CAPTURE_LOG"
        MEMORY_TOPIC_MODE=deny bash "$HOOK" < "$SB/p.json" >/dev/null 2>"$SB/err"; assert_rc "$1 (deny mode)" 2 "$?"
        grep -q 'MEMORY_CAPTURE_OK=1' "$SB/err"; assert_rc "$1 deny text names the bypass" 0 "$?"
        grep -q 'sub-file linked from its hub' "$SB/err"; assert_rc "$1 deny text names the hub procedure" 0 "$?"
    else
        if [ -z "$out" ] && ! log_has topic-cap; then echo "PASS $1 clean (warn)"; else echo "FAIL $1 fired in warn mode (out: $out)"; FAILED=1; fi
        MEMORY_TOPIC_MODE=deny bash "$HOOK" < "$SB/p.json" >/dev/null 2>"$SB/err"; assert_rc "$1 clean (deny mode)" 0 "$?"
    fi
}

# --- index: a write that does not add pointer lines passes over the ceiling
idx_n() { local n="$1" i=1; : > "$M2/MEMORY.md"; while [ "$i" -le "$n" ]; do printf -- '- l%s\n' "$i" >> "$M2/MEMORY.md"; i=$((i + 1)); done; }
idx_n 62
wp Write "$M2/MEMORY.md" "$(head -n 61 "$M2/MEMORY.md")"
hook_rc; assert_rc "a: Write 62 to 61 pointer lines passes" 0 "$?"
ep Edit "$M2/MEMORY.md" $'- l61\n- l62\n' $'- l61\n'
hook_rc; assert_rc "a2: Edit 62 to 61 pointer lines passes" 0 "$?"
ep Edit "$M2/MEMORY.md" $'- l5\n' $'- m5\n'
hook_rc; assert_rc "a3: Edit 62 to 62 (one line replaced) passes" 0 "$?"
idx_n 60
wp Write "$M2/MEMORY.md" "$(cat "$M2/MEMORY.md")"$'\n- extra'
hook_rc; assert_rc "b: 60 to 61 stays denied" 2 "$?"
idx_n 62
wp Write "$M2/MEMORY.md" "$(cat "$M2/MEMORY.md")"$'\n- extra'
hook_rc; assert_rc "b2: 62 to 63 stays denied" 2 "$?"

# --- topic-cap rows (default warn, MEMORY_TOPIC_MODE=deny)
rm -rf "$M2"; mkdir -p "$M2"
fill 7168 > "$M2/t.md"; wp Write "$M2/t.md" "$(fill 9216)"; tc "c: Write 7 KB to 9 KB" 1
{ printf 'HEAD'; fill 7996; } > "$M2/t.md"
ep Edit "$M2/t.md" HEAD "HEAD$(fill 300)"; tc "c2: Edit 8000 to 8300 bytes" 1
{ printf 'HEAD'; fill 7992; printf 'TAIL'; } > "$M2/t.md"
ep MultiEdit "$M2/t.md" HEAD "HEAD$(fill 296)"; tc "c3: MultiEdit 8000 to 8300 bytes" 1
rm -f "$M2/t.md"
wp Write "$M2/t.md" "$(fill 8191)"$'\n'; tc "e: Write ending in a newline, 8192 bytes is clean" 0
wp Write "$M2/t.md" "$(fill 8192)"$'\n'; tc "e: Write ending in a newline, 8193 bytes fires" 1
wp Write "$M2/new.md" "$(fill 9216)"; tc "f: new 9 KB file fires" 1
wp Write "$M2/new.md" "$(fill 8192)"; tc "f: new 8192-byte file is clean" 0
mkdir -p "$SB/real-mem" "$SB/.claude/projects/lp"; ln -sfn "$SB/real-mem" "$SB/.claude/projects/lp/memory"
wp Write "$SB/.claude/projects/lp/memory/t.md" "$(fill 9216)"; tc "g: memory dir behind a symlink still fires" 1
fill 20480 > "$M2/unread.md"; chmod 000 "$M2/unread.md"
if [ -r "$M2/unread.md" ]; then echo "SKIP h/j2 (this uid can read a mode-000 file)"
else
    wp Write "$M2/unread.md" "$(fill 19456)"; tc "h: unreadable 20 KB old file, 19 KB Write fires" 1
    ep Edit "$M2/unread.md" HEAD x
    for mode in warn deny; do
        : > "$MEMORY_CAPTURE_LOG"; MEMORY_TOPIC_MODE=$mode bash "$HOOK" < "$SB/p.json" >/dev/null 2>&1; assert_rc "j2: unreadable topic Edit fails open ($mode)" 0 "$?"
        one_undecidable; assert_rc "j2: one topic-cap-undecidable row ($mode)" 0 "$?"
    done
fi
chmod 644 "$M2/unread.md"
mkdir -p "$SB/cc/projects/x/memory"
wp Write "$SB/cc/projects/x/memory/t.md" "$(fill 9216)"
: > "$MEMORY_CAPTURE_LOG"; CLAUDE_CONFIG_DIR="$SB/cc" bash "$HOOK" < "$SB/p.json" >/dev/null 2>&1; assert_rc "i: CLAUDE_CONFIG_DIR store, 9 KB Write warns (rc 0)" 0 "$?"
log_has '"rule":"topic-cap"'; assert_rc "i: CLAUDE_CONFIG_DIR store fires topic-cap" 0 "$?"
CLAUDE_CONFIG_DIR="$SB/cc" MEMORY_TOPIC_MODE=deny bash "$HOOK" < "$SB/p.json" >/dev/null 2>&1; assert_rc "i: CLAUDE_CONFIG_DIR store, deny mode" 2 "$?"
# clean rows
fill 20480 > "$M2/big.md"; wp Write "$M2/big.md" "$(fill 19456)"; tc "d: 20 KB shrinking to 19 KB is clean" 0
wp Write "$M2/MEMORY.md.bak" "$(fill 30720)"; tc "d: 30 KB MEMORY.md.bak is clean" 0
{ printf -- '- p1\n- p2\n'; i=0; while [ "$i" -lt 300 ]; do printf 'prose line %0100d\n' "$i"; i=$((i + 1)); done; } > "$M2/MEMORY.md"
wp Write "$M2/MEMORY.md" "$(cat "$M2/MEMORY.md")"; tc "d: a 30 KB MEMORY.md itself is not a topic-cap target" 0
wp Write "$SB/outside.md" "$(fill 9216)"; tc "d: a path outside the memory dir is clean" 0
wp Write "$M2/notes.txt" "$(fill 9216)"; tc "d: a non-.md file in the memory dir is clean" 0

# --- fail-open on topic files, fail-closed on MEMORY.md (stub node = crashing simulator)
mkdir -p "$SB/badnode"; printf '#!/bin/sh\nexit 1\n' > "$SB/badnode/node"; chmod +x "$SB/badnode/node"
printf 'HEAD\n' > "$M2/t.md"; ep Edit "$M2/t.md" HEAD x
for mode in warn deny; do
    : > "$MEMORY_CAPTURE_LOG"; PATH="$SB/badnode:$PATH" MEMORY_TOPIC_MODE=$mode bash "$HOOK" < "$SB/p.json" >/dev/null 2>&1; assert_rc "j: crashing simulator on a topic Edit fails open ($mode)" 0 "$?"
    one_undecidable; assert_rc "j: one topic-cap-undecidable row ($mode)" 0 "$?"
done
printf -- '- l1\n' > "$M2/MEMORY.md"; ep Edit "$M2/MEMORY.md" l1 l2
: > "$MEMORY_CAPTURE_LOG"; PATH="$SB/badnode:$PATH" bash "$HOOK" < "$SB/p.json" >/dev/null 2>&1; assert_rc "j3: crashing simulator on MEMORY.md still denies" 2 "$?"
log_has '"rule":"undecidable-payload"'; assert_rc "j3: logs undecidable-payload" 0 "$?"

# --- invalid UTF-8 in a topic file: sized without a crash, error leans toward firing
{ printf 'HEAD'; head -c 3000 /dev/zero | tr '\0' '\377'; fill 5000; } > "$M2/t.md"
ep Edit "$M2/t.md" HEAD "HEAD$(fill 300)"; tc "u: invalid-UTF-8 topic Edit is sized and fires" 1

# --- capture-log rows name their session and carry old/new on deny and warn rows
idx_n 60; : > "$MEMORY_CAPTURE_LOG"
wp Write "$M2/MEMORY.md" "$(cat "$M2/MEMORY.md")"$'\n- extra' sess-b; hook_rc
log_row sess-b 60 61; assert_rc "log: b deny row names the session and old/new" 0 "$?"
idx_n 62; : > "$MEMORY_CAPTURE_LOG"
wp Write "$M2/MEMORY.md" "$(cat "$M2/MEMORY.md")"$'\n- extra' sess-b2; hook_rc
log_row sess-b2 62 63; assert_rc "log: b2 deny row names the session and old/new" 0 "$?"
idx_n 5; : > "$MEMORY_CAPTURE_LOG"
wp Write "$M2/MEMORY.md" "$(cat "$M2/MEMORY.md")"$'\n- six' sess-w; hook_rc
jq -e 'select(.event=="write" and .session_id=="sess-w")' "$MEMORY_CAPTURE_LOG" >/dev/null; assert_rc "log: an allowed MEMORY.md write row names the session" 0 "$?"
rm -f "$M2/t.md"; : > "$MEMORY_CAPTURE_LOG"
wp Write "$M2/t.md" "$(fill 9216)" sess-t; hook_rc
log_row sess-t 0 9216; assert_rc "log: topic-cap warn row names the session and old/new bytes" 0 "$?"
: > "$MEMORY_CAPTURE_LOG"
wp Write "$M2/MEMORY.md" "$(cat "$M2/MEMORY.md")"$'\n- seven'; hook_rc; rc=$?
assert_rc "log: a payload with no session_id does not crash" 0 "$rc"
log_has '"session_id":""'; assert_rc "log: a missing session_id logs an empty string" 0 "$?"

# --- advisory/remedy wording
: > "$MEMORY_CAPTURE_LOG"; idx_n 60
wp Write "$M2/MEMORY.md" "$(cat "$M2/MEMORY.md")"$'\n- extra'; hook_rc
grep -q 'sub-file linked from the nearest hub' "$SB/err"; assert_rc "remedy offers a sub-file linked from the nearest hub" 0 "$?"
if grep -q 'new theme' "$SB/err"; then echo "FAIL remedy still offers a new theme note"; FAILED=1; else echo "PASS remedy no longer offers a new theme note"; fi

# --- notice rows (own store so earlier fixtures do not leak)
N2="$SB/.claude/projects/p3/memory"; rm -rf "$N2"; mkdir -p "$N2"
printf -- '- a\n- b\n' > "$N2/MEMORY.md"
out="$(MEMDIR="$N2" bash "$STATE_HOOK" </dev/null 2>&1)"; rc=$?
assert_silent "N1 a clean fixture prints nothing"
fill 8193 > "$N2/big.md"
out="$(MEMDIR="$N2" bash "$STATE_HOOK" </dev/null 2>&1)"; rc=$?
assert_contains "N2 one 8193-byte topic file prints topic-cap" "topic-cap"
assert_contains "N2 names the file" "big.md"
fill 8192 > "$N2/big.md"
out="$(MEMDIR="$N2" bash "$STATE_HOOK" </dev/null 2>&1)"; rc=$?
assert_silent "N2 an 8192-byte topic file is clean"
rm -f "$N2/big.md"
{ i=0; while [ "$i" -lt 201 ]; do printf 'prose %s\n' "$i"; i=$((i + 1)); done; } > "$N2/MEMORY.md"
out="$(MEMDIR="$N2" bash "$STATE_HOOK" </dev/null 2>&1)"; rc=$?
assert_contains "N3 a 201-line index prints load-limit" "load-limit"
{ printf -- '- a\n'; fill 25000; printf '\n'; } > "$N2/MEMORY.md"
out="$(MEMDIR="$N2" bash "$STATE_HOOK" </dev/null 2>&1)"; rc=$?
assert_contains "N3 an index past the byte budget prints load-limit" "load-limit"
mk_index 61
out="$(MEMDIR="$MEM" bash "$STATE_HOOK" </dev/null 2>&1)"; rc=$?
case "$out" in *"cut at"*) echo "FAIL N4 notice still claims the 60-line ceiling truncates the index"; FAILED=1 ;; *) echo "PASS N4 notice no longer claims the 60-line ceiling truncates the index" ;; esac
assert_contains "N4 notice calls the ceiling himmel's routing rule" "routing rule"
{ printf -- '- a\n'; } > "$N2/MEMORY.md"; fill 8193 > "$N2/big.md"
rm -rf "$SB/n5link"; ln -s "$N2" "$SB/n5link"
out="$(MEMDIR="$SB/n5link" bash "$STATE_HOOK" </dev/null 2>&1)"; rc=$?
assert_contains "N5 a symlinked memory dir still reports topic-cap" "topic-cap"
rm -f "$N2/big.md" "$SB/n5link"
{ i=0; while [ "$i" -lt 200 ]; do printf 'prose %s\n' "$i"; i=$((i + 1)); done; printf 'prose last'; } > "$N2/MEMORY.md"
out="$(MEMDIR="$N2" bash "$STATE_HOOK" </dev/null 2>&1)"; rc=$?
assert_contains "N6 a 201st line without a trailing newline prints load-limit" "load-limit"

# --- pin: guard, notice, Bash re-check and audit share the defaults
BASHCHK="$(cd "$(dirname "$0")" && pwd)/memory-bash-line-check.sh"
AUDIT="$(cd "$(dirname "$0")/.." && pwd)/memory/audit-memory-capture.sh"
for kv in MEMORY_LINE_CEIL=60 MEMORY_LINE_MAX=200 MEMORY_TOPIC_MAX=8192; do
    knob="${kv%%=*}"; want="\${$knob:-${kv#*=}}"
    for f in "$HOOK" "$STATE_HOOK"; do
        if grep -qF "$want" "$f"; then echo "PASS pin $knob default ${kv#*=} in $(basename "$f")"; else echo "FAIL pin $knob default ${kv#*=} missing in $(basename "$f")"; FAILED=1; fi
    done
done
grep -qF "\${MEMORY_TOPIC_MAX:-8192}" "$BASHCHK"; assert_rc "pin MEMORY_TOPIC_MAX default 8192 in the Bash re-check" 0 "$?"
for f in "$STATE_HOOK" "$AUDIT"; do grep -qF "\${MEMORY_BUDGET_BYTES:-24400}" "$f"; assert_rc "pin MEMORY_BUDGET_BYTES default 24400 in $(basename "$f")" 0 "$?"; done
grep -qF "\${MEMORY_LOAD_LINES:-200}" "$STATE_HOOK"; assert_rc "pin MEMORY_LOAD_LINES default 200 in the notice" 0 "$?"

exit "$FAILED"
