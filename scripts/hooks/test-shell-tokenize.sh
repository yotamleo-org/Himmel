#!/usr/bin/env bash
# Tests for scripts/hooks/lib/shell-tokenize.sh and the drift
# check that keeps its two inlined copies honest.
#
# The lib is NOT sourced by the hooks at runtime: its BEGIN…END block is
# copied byte-for-byte into block-edit-live-settings.sh and
# guard-pr-check-literal.sh (hook-integrity pins launched hooks, not the libs
# they source). This suite fails when either copy drifts from the canonical
# file, and proves that check can fail (RED control on a mutated copy).
#
# Usage:
#   bash scripts/quiet-run.sh suite -- bash scripts/hooks/test-shell-tokenize.sh
#       run the suite; add --sync to rewrite both inlined copies from the lib
#
# Exit codes:
#   0 - all cases passed (or --sync rewrote both copies)
#   1 - at least one case failed
# shellcheck disable=SC2016 # the unit cases feed literal command text
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
LIB="$HERE/lib/shell-tokenize.sh"
HOOKS=("$HERE/block-edit-live-settings.sh" "$HERE/guard-pr-check-literal.sh")
BEGIN_LINE='# >>> BEGIN shell-tokenize (canonical: scripts/hooks/lib/shell-tokenize.sh) >>>'
END_LINE='# <<< END shell-tokenize <<<'

# block FILE — the marker block of FILE, markers included.
block() {
    awk -v b="$BEGIN_LINE" -v e="$END_LINE" '$0 == b {p = 1} p {print} $0 == e {p = 0}' "$1"
}

# markers_ok FILE — exactly one BEGIN and one END line, BEGIN first.
markers_ok() {
    awk -v b="$BEGIN_LINE" -v e="$END_LINE" '
        $0 == b {nb++; if (ne) bad = 1}
        $0 == e {ne++}
        END {exit !(nb == 1 && ne == 1 && !bad)}' "$1"
}

# in_sync FILE — FILE's marker block is byte-identical to the lib's.
in_sync() {
    markers_ok "$1" && [ "$(block "$1"; echo x)" = "$(block "$LIB"; echo x)" ]
}

# sync_into FILE — replace FILE's marker block with the lib's.
sync_into() {
    local tmp blk
    markers_ok "$1" || { echo "sync: $1 lacks exactly one BEGIN/END pair" >&2; return 1; }
    blk=$(mktemp "${TMPDIR:-/tmp}/st-blk.XXXXXX") && tmp=$(mktemp "${TMPDIR:-/tmp}/st-hook.XXXXXX") || return 1
    block "$LIB" > "$blk"
    awk -v b="$BEGIN_LINE" -v e="$END_LINE" -v f="$blk" '
        $0 == b {while ((getline l < f) > 0) print l; skip = 1; next}
        $0 == e {skip = 0; next}
        !skip {print}' "$1" > "$tmp" && cat "$tmp" > "$1"
    rm -f "$tmp" "$blk"
}

if [ "${1:-}" = --sync ]; then
    for h in "${HOOKS[@]}"; do sync_into "$h" || exit 1; done
    echo "synced shell-tokenize into: ${HOOKS[*]##*/}"
    exit 0
fi

FAILED=0
pass() { echo "PASS $1"; }
fail() { echo "FAIL $1"; FAILED=$((FAILED + 1)); }
check() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 - expected [$3], got [$2]"; fi; }

# ---- drift: both inlined copies equal the canonical block
if [ -n "$(block "$LIB")" ]; then pass "lib carries a marker block"; else fail "lib carries a marker block"; fi
for h in "${HOOKS[@]}"; do
    if in_sync "$h"; then pass "${h##*/} inlined block matches the lib"
    else fail "${h##*/} inlined block differs from the lib (edit the lib, then run --sync)"; fi
done
# Neither hook sources the lib at runtime.
for h in "${HOOKS[@]}"; do
    if grep -nE '^[^#]*(\.|source)[[:space:]].*shell-tokenize' "$h" >/dev/null; then
        fail "${h##*/} sources shell-tokenize at runtime"
    else pass "${h##*/} does not source shell-tokenize"; fi
done

# ---- RED control: a one-line change in an inlined copy is caught, and
# --sync's rewrite repairs it.
SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/st-test.XXXXXX") || exit 1
trap 'rm -rf "$SCRATCH"' EXIT
awk -v b="$BEGIN_LINE" '{print} $0 == b {print "# drift"}' "${HOOKS[1]}" > "$SCRATCH/hook.sh"
if in_sync "$SCRATCH/hook.sh"; then fail "control: a mutated copy is reported in sync"
else pass "control: a mutated copy is reported as drift"; fi
sync_into "$SCRATCH/hook.sh"
if in_sync "$SCRATCH/hook.sh" && cmp -s "$SCRATCH/hook.sh" "${HOOKS[1]}"; then
    pass "control: sync restores the mutated copy byte-for-byte"
else fail "control: sync did not restore the mutated copy"; fi
awk -v b="$BEGIN_LINE" '$0 != b {print}' "${HOOKS[1]}" > "$SCRATCH/nobegin.sh"
if in_sync "$SCRATCH/nobegin.sh"; then fail "control: a copy with no BEGIN marker is reported in sync"
else pass "control: a copy with no BEGIN marker is reported as drift"; fi

# ---- unit cases for the tokenizer itself (command text is literal)
# shellcheck source=lib/shell-tokenize.sh
. "$LIB"
# tok CMD — tokenize in THIS shell (a $(…) would lose ST_*); R is the rc.
tok() { if st_tokenize "$1"; then R=0; else R=1; fi; }

tok "echo 'a|b' \"c;d\""; check "quoted | and ; stay inside their words" "$R:$ST_NSEG:$ST_N:${ST_W[1]}:${ST_Q[1]}:${ST_W[2]}" "0:1:3:a|b:1:c;d"
tok 'cat x 2>&1 | grep y'; check "2>&1 is a redirect, not a separator" "$R:$ST_NSEG:${ST_SEP[0]}:${ST_W[2]}:${ST_RO[2]}" "0:2:|:1:2>&"
tok 'a && b; c'; check "&& and ; split segments" "$R:$ST_NSEG:${ST_SEP[0]}:${ST_SEP[1]}" "0:3:&&:;"
tok $'a\nb'; check "a newline splits segments" "$R:$ST_NSEG:${ST_SEP[0]}" "0:2:nl"
tok 'x=$(tar -xf a)'; check "\$(…) sets SUBST" "$R:$ST_SUBST" "0:1"
tok 'echo "a $(b) c"'; check "\$(…) inside double quotes sets SUBST" "$R:$ST_SUBST" "0:1"
tok 'echo `b`'; check "a backtick sets SUBST" "$R:$ST_SUBST" "0:1"
tok "echo '\$(b)'"; check "a single-quoted \$(…) is inert" "$R:$ST_SUBST:${ST_X[1]}" "0:0:0"
tok 'echo "$X"'; check "a double-quoted \$X is live" "$R:${ST_X[1]}" "0:1"
tok 'ls *.sh'; check "an unquoted glob sets G" "$R:${ST_G[1]}" "0:1"
tok "ls '*.sh'"; check "a quoted glob does not" "$R:${ST_G[1]}" "0:0"
tok 'ls ~/x'; check "a tilde is not a glob" "$R:${ST_G[1]}" "0:0"
tok 'FOO=bar cmd'; check "NAME=value is assignment-shaped" "$R:${ST_A[0]}:${ST_A[1]}" "0:1:0"
tok "'FOO=bar' cmd"; check "a quoted NAME=value is not" "$R:${ST_A[0]}" "0:0"
tok "echo \$'a'"; check "\$'…' sets ANSIC" "$R:$ST_ANSIC" "0:1"
tok "rm \$'\\x2dr' d"; check "\$'…' is decoded the way bash runs it" "$R:${ST_W[1]}:${ST_Q[1]}" "0:-r:1"
tok "cat \$'\\'' .e*"; check "\$'\\'' decodes to a quote" "$R:${ST_W[1]}" "0:'"
# shellcheck disable=SC1003 # the bodies hold backslashes, not escaped quotes
ansic_parity() {
    local LC_ALL=C body want bs='\'
    for body in 'plain' '\a\b\e\E\f\n\r\t\v' '\\' "\\'" '\"' '\?' '\101' '\18' '\0101' '\777' '\x41' '\x4g' '\x' \
        "${bs}u0041" "${bs}u007f" "${bs}u0000" '\U00000041' '\U0001F600' "${bs}u" '\cA' '\c?' '\c' '\c\x' '\q' 'a\x00b' 'a\' '\x2dr' '\056env'; do
        _st_ansic_walk "$body"
        eval 'want=${body@E}'
        check "by-hand decode of [$body] equals \${…@E}" "$_ST_DEC" "$want"
    done
}
if [ "${BASH_VERSINFO[0]}" -gt 4 ] || { [ "${BASH_VERSINFO[0]}" = 4 ] && [ "${BASH_VERSINFO[1]}" -ge 4 ]; }; then
    ansic_parity
fi
# shellcheck disable=SC1003 # a lone backslash
bs='\'
# shellcheck disable=SC1003 # the bodies hold backslashes, not escaped quotes
for body in '\c\\n' '\c\\x3b' '\c\\073' '\c\\;'; do
    _st_ansic_e "$body"; check "a control-backslash pair in [$body] is refused" "$?" "1"
    tok "cat \$'$body'"; check "a word holding [$body] fails the tokenizer" "$R" "1"
    st_expand text "cat \$'$body'"; check "st_expand text refuses [$body], ST_EXP empty" "$?:${#ST_EXP}" "1:0"
    st_expand empty "cat \$'$body'"; check "st_expand empty refuses [$body], ST_EXP empty" "$?:${#ST_EXP}" "1:0"
    st_expand text "echo \$(cat \$'$body')"; check "st_expand refuses [$body] inside a substitution" "$?:${#ST_EXP}" "1:0"
    st_expand text "cat <<\$'$body'"; check "st_expand refuses [$body] as a heredoc delimiter" "$?:${#ST_EXP}" "1:0"
    st_expand text "echo \${(pj:$body:)V}"; check "st_expand refuses [$body] in a zsh (pj::) argument" "$?:${#ST_EXP}" "1:0"
    st_expand text "echo \${V:-x} \$'$body'"; check "st_expand refuses [$body] beside a parameter expansion" "$?:${#ST_EXP}" "1:0"
done
st_expand text "cat \$'${bs}x41'"; check "st_expand still rewrites a plain dollar-quote word" "$?:$ST_EXP" "0:cat 'A'"
_st_ansic_e '\\c\x41'; check "an escaped backslash before c is not the pair" "$?" "0"
# Escapes that bash and zsh read differently: zsh's \C-x and \M-x, its \cx (a c, not
# a control), its unknown escape (the backslash drops) and a \x \u \U with no hex
# digit (a NUL). No decoding is safe for both shells, so each word is refused.
# shellcheck disable=SC1003 # the bodies hold backslashes, not escaped quotes
zsh_only=('\C-a' '\C-A' '\C-z' '\C-@' '\C-?' '\C- ' '\C-1' '\C-\\' '\C-\\\\' '\Ca' '\C-' '\C'
    '\M-a' '\M-\C-a' '\M-\\' '\Ma' '\M-' '\M'
    '\ca' '\cA' '\c@' '\c[' '\c?' '\cA\\' '\c'
    '\q' '\z' '\-' '\ ' '\8' '\9' '\!' '\.' '\/' '\$' '\`' '\C-\x41' $'\\\n' $'\\\xc3\xa9'
    '\x' '\xg' '\u' '\ug' '\U' '\Ug'
    'a\qb' '\x41\q' '\\\q' '\101\z' 'ab\C-c')
for body in "${zsh_only[@]}"; do
    _st_ansic_e "$body"; check "a zsh-only escape in [$body] is refused" "$?" "1"
    tok "cat \$'$body'"; check "a word holding the zsh-only [$body] fails the tokenizer" "$R" "1"
    st_expand text "cat \$'$body'"; check "st_expand text refuses the zsh-only [$body], ST_EXP empty" "$?:${#ST_EXP}" "1:0"
    st_expand empty "cat \$'$body'"; check "st_expand empty refuses the zsh-only [$body], ST_EXP empty" "$?:${#ST_EXP}" "1:0"
done
for body in '\C-a' '\q' '\M-a' '\ca' '\x'; do
    st_expand text "echo \$(cat \$'$body')"; check "st_expand refuses the zsh-only [$body] inside a substitution" "$?:${#ST_EXP}" "1:0"
    st_expand text "cat <<\$'$body'"; check "st_expand refuses the zsh-only [$body] as a heredoc delimiter" "$?:${#ST_EXP}" "1:0"
    st_expand text "echo \${(pj:$body:)V}"; check "st_expand refuses the zsh-only [$body] in a zsh (pj::) argument" "$?:${#ST_EXP}" "1:0"
    st_expand text "echo \${V:-x} \$'$body'"; check "st_expand refuses the zsh-only [$body] beside a parameter expansion" "$?:${#ST_EXP}" "1:0"
done
# Escapes both shells read alike keep their decoded word.
# shellcheck disable=SC1003 # the bodies hold backslashes, not escaped quotes
same_in_both=('\n' $'\n' '\x41' A '\x41\x42' AB '\x4g' $'\004g' '\101' A '\u0041' A '\U00000041' A
    '\a\b\e\E\f\n\r\t\v' $'\a\b\e\E\f\n\r\t\v' '\\' '\' "\\'" "'" '\"' '"' '\?' '?' 'abc' abc 'a\\qb' 'a\qb' '\\C-a' '\C-a' '\\cA' '\cA')
n=0
while [ "$n" -lt "${#same_in_both[@]}" ]; do
    body=${same_in_both[n]}; want=${same_in_both[n + 1]}; n=$((n + 2))
    _st_ansic_e "$body"; check "an escape both shells read alike in [$body] is accepted" "$?" "0"
    tok "echo \$'$body'"; check "a word holding [$body] tokenizes to the shared reading" "$R:${ST_W[1]}" "0:$want"
done
# ST_AMBIG tells a caller that the refusal came from such a word, not from another construct.
tok "cat \$'${bs}q'"; check "a refused zsh-only escape sets ST_AMBIG" "$R:${ST_AMBIG-}" "1:1"
tok "cat \$'${bs}x41'"; check "an escape both shells read alike leaves ST_AMBIG clear" "$R:${ST_AMBIG-}" "0:0"
tok "echo 'a"; check "a refusal for another reason leaves ST_AMBIG clear" "$R:${ST_AMBIG-}" "1:0"
# An escape that builds a NUL: zsh cuts the whole word at it, so text after the escape is lost to
# the command; bash drops the NUL and keeps that text. Each spelling is refused, alone, inside a
# longer word and between words.
# shellcheck disable=SC1003 # the bodies hold backslashes, not escaped quotes
nul_esc=('\0' '\00' '\000' '\0000' '\0001' '\400' '\08' '\0a' '\0g' '\x0' '\x00' '\x000' '\x0g' '\u0' '\u00' '\u000' '\u0000' '\u00000'
    '\U0' '\U0000000' '\U00000000' '\U000000000' 'a\0b' 'a\x00b' 'a\u0000b' '\\\0' 'ab\400cd')
for body in "${nul_esc[@]}"; do
    _st_ansic_e "$body"; check "a NUL escape in [$body] is refused" "$?:${ST_AMBIG-}" "1:1"
    tok "cat \$'$body'"; check "a word holding the NUL escape [$body] fails the tokenizer" "$R:${ST_AMBIG-}" "1:1"
    tok "cat x\$'$body'y z"; check "the NUL escape [$body] inside a longer word fails the tokenizer" "$R:${ST_AMBIG-}" "1:1"
    st_expand text "cat x\$'$body'y"; check "st_expand text refuses the NUL escape [$body], ST_EXP empty" "$?:${#ST_EXP}" "1:0"
    st_expand empty "cat \$'$body'"; check "st_expand empty refuses the NUL escape [$body], ST_EXP empty" "$?:${#ST_EXP}" "1:0"
done
# Escapes next to them that build a byte, and the text of an escaped backslash, keep their reading.
# shellcheck disable=SC1003 # the bodies hold backslashes, not escaped quotes
non_nul=('\x02' $'\002' '\002' $'\002' '\u0002' $'\002' '\x0a' $'\n' '\u000a' $'\n' '\377' $'\377' '\2' $'\002' '\10' $'\010' '\x10' $'\020'
    '\u0010' $'\020' '\0020' $'\0020' '\\0' '\0' '\\x00' '\x00' 'a\\0b' 'a\0b')
n=0
while [ "$n" -lt "${#non_nul[@]}" ]; do
    body=${non_nul[n]}; want=${non_nul[n + 1]}; n=$((n + 2))
    _st_ansic_e "$body"; check "an escape that is not a NUL in [$body] is accepted" "$?" "0"
    tok "echo x\$'$body'y"; check "a word holding [$body] keeps its reading" "$R:${ST_AMBIG-}:${ST_W[1]}" "0:0:x${want}y"
done
# A text that ends in an odd run of backslashes: zsh and bash 3.2 drop the last one and bash 5 keeps
# it, so the guard cannot know the last word. An even run, a backslash before a space or a newline,
# and a line continuation inside quotes read alike in all three.
# shellcheck disable=SC1003 # the texts hold backslashes, not escaped quotes
trail_bs=('terraform destroy\' 'echo x | terraform destroy\' 'echo x; terraform destroy\' 'echo x && terraform destroy\'
    $'echo x\nterraform destroy\' 'terraform destroy\\\' 'terraform destroy\\\\\' '\' 'terraform plan\')
for t in "${trail_bs[@]}"; do
    _st_endbs "$t"; check "[$t] ends in an odd run of backslashes" "$?" "0"
    tok "$t"; check "the text [$t] ends in a backslash and fails the tokenizer" "$R:${ST_AMBIG-}" "1:1"
    st_expand text "$t"; check "st_expand text refuses the text [$t], ST_EXP empty" "$?:${#ST_EXP}" "1:0"
    st_expand empty "$t"; check "st_expand empty refuses the text [$t], ST_EXP empty" "$?:${#ST_EXP}" "1:0"
done
# shellcheck disable=SC1003 # the texts hold backslashes, not escaped quotes
trail_ok=('terraform destroy\\' 'destroy\' 'terraform destroy\\\\' 'destroy\\' 'terraform destroy\ ' 'destroy ' 'terraform destroy\  ' 'destroy '
    $'terraform destroy\\\n' destroy $'terraform destroy\\\n\n' destroy 'echo "a\
b"' ab "echo 'a\\'" 'a\' $'echo a \\\n  b' b 'echo a\\\\ b' 'b')
n=0
while [ "$n" -lt "${#trail_ok[@]}" ]; do
    t=${trail_ok[n]}; want=${trail_ok[n + 1]}; n=$((n + 2))
    _st_endbs "$t"; check "[$t] does not end in an odd run of backslashes" "$?" "1"
    tok "$t"; check "the text [$t] is still read, last word [$want]" "$R:${ST_AMBIG-}:${ST_W[ST_N-1]}" "0:0:$want"
done
tok 'echo a # c; d'; check "a comment sets COMMENT and ends the command" "$R:$ST_COMMENT:$ST_NSEG:$ST_N" "0:1:1:2"
tok $'cat <<EOF\nbody $(x)\nEOF\necho after'; check "an unquoted heredoc body with \$(…) sets SUBST" "$R:$ST_HEREDOC:$ST_SUBST" "0:1:1"
tok $'cat <<\'EOF\'\nbody $(x)\nEOF'; check "a quoted heredoc body is inert" "$R:$ST_HEREDOC:$ST_SUBST" "0:1:0"
tok 'case x in a) ;; esac'; check "case…esac is not modelled" "$R" "1"
tok "echo 'a"; check "an unterminated quote is not modelled" "$R" "1"
tok 'echo >'; check "a redirect with no target is not modelled" "$R" "1"

sed_inert() { if st_sed_inert "$1"; then echo inert; else echo not; fi; }
check "sed s///g is inert" "$(sed_inert 's/a/b/g')" inert
check "sed p is inert" "$(sed_inert 'p')" inert
check "sed s with | delimiter is inert" "$(sed_inert 's|a|b|')" inert
check "sed w flag is not inert" "$(sed_inert 's/a/b/w /tmp/x')" not
check "sed e flag is not inert" "$(sed_inert 's/.*/x/e')" not
check "sed e command is not inert" "$(sed_inert '1e touch x')" not
check "a second sed command is not inert" "$(sed_inert 's/a/b/;w x')" not
check "an unescaped / in the replacement is not inert" "$(sed_inert 's/x/y a/b z/')" not

sed_args() { st_tokenize "$1" >/dev/null; if st_sed_args 0 "$2"; then echo "ok[$ST_SED_SCRIPTS]"; else echo no; fi; }
check "sed -n script file: script is word 2" "$(sed_args "sed -n 's/a/b/' f" 0)" "ok[ 2]"
check "sed -e script: script is word 2" "$(sed_args "sed -e 's/a/b/' f" 0)" "ok[ 2]"
check "sed -i refused when in-place is not allowed" "$(sed_args "sed -i 's/a/b/' f" 0)" no  # gnu-ok: literal tokenizer input, never run
check "sed -i accepted when in-place is allowed" "$(sed_args "sed -i 's/a/b/' f" 1)" "ok[ 2]"  # gnu-ok: literal tokenizer input, never run
check "sed -f is refused" "$(sed_args 'sed -f s.sed f' 0)" no
check "a glob-built sed script is refused" "$(sed_args 'sed s/a/*/ f' 0)" no

echo
if [ "$FAILED" -ne 0 ]; then
    echo "$FAILED shell-tokenize case(s) failed"
    exit 1
fi
echo "all shell-tokenize cases passed"
