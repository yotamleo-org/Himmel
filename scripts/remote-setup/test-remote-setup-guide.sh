#!/usr/bin/env bash
# shellcheck disable=SC2016  # the fixtures and sed programs hold literal $ and backticks on purpose
# test-remote-setup-guide.sh: the command lint for docs/setup/remote-setup.md, and its self-tests.
#
#   bash scripts/remote-setup/test-remote-setup-guide.sh              lint the page, then run the self-tests
#   bash scripts/remote-setup/test-remote-setup-guide.sh --lint FILE  lint one page: exit 0 clean, 1 findings
#
# The rule: every fenced block on the page (any section, Before you start, Undo and Check
# everything included) is a command the reader pastes, unless it is tagged `text` (an output sample,
# such as a DONE line). A command block holds no placeholder-style construct (an angle bracket, a
# command substitution, && or ||, a backtick) and parses in bash, zsh and fish, because the reader's
# shell is not ours to choose. With CI=true a missing zsh or fish fails the lint, so the check is
# never vacuous.
#
# bash 3.2-safe.

HERE=$(cd "$(dirname "$0")" && pwd -P)
REPO=$(cd "$HERE/../.." && pwd -P)
PAGE=$REPO/docs/setup/remote-setup.md
WORK=$(mktemp -d "${TMPDIR:-/tmp}/guide-lint.XXXXXX") || exit 1
trap 'rm -rf "$WORK"' EXIT

# extract_blocks <page> <dir>: writes <dir>/block-NNN (the block text), <dir>/block-NNN.meta
# ("<line the block starts on><TAB><language tag>") and <dir>/error when a fence is never closed.
extract_blocks() {
    awk -v out="$2" '
        /^[[:space:]]*```/ {
            if (!infence) {
                infence = 1
                lang = $0
                sub(/^[[:space:]]*```/, "", lang)
                sub(/[[:space:]].*$/, "", lang)
                n++
                file = sprintf("%s/block-%03d", out, n)
                printf "%d\t%s\n", NR, lang > (file ".meta")
                close(file ".meta")
                printf "" > file
            } else {
                infence = 0
                close(file)
            }
            next
        }
        infence { print $0 >> file }
        END { if (infence) { print "unterminated" > (out "/error") } }
    ' "$1"
}

# lint_page <page>: prints one line per finding; returns 1 when there is any.
lint_page() {
    local page=$1 dir findings=0 meta file start lang sh hits ln rest s
    dir=$(mktemp -d "$WORK/lint.XXXXXX") || return 2
    extract_blocks "$page" "$dir"
    if [ -f "$dir/error" ]; then
        echo "$page: a code fence is never closed"
        findings=1
    fi
    for s in zsh fish; do
        if ! command -v "$s" > /dev/null 2>&1; then
            if [ "${CI:-}" = true ]; then
                echo "FAIL: $s is not installed and CI=true: the lint would check nothing for $s (install it in the CI job)"
                findings=1
            else
                echo "warning: $s is not installed here, so commands are not checked in $s" >&2
            fi
        fi
    done
    for meta in "$dir"/block-*.meta; do
        [ -e "$meta" ] || break
        file=${meta%.meta}
        IFS=$'\t' read -r start lang < "$meta"
        [ "$lang" = text ] && continue
        if [ "$lang" = console ]; then
            sed 's/^\$ //' "$file" > "$file.clean" && mv "$file.clean" "$file"
        fi
        hits=$file.hits
        grep -nE '<|[$][(]|&&|[|][|]|`' "$file" > "$hits" 2> /dev/null
        while IFS=: read -r ln rest; do
            [ -n "$ln" ] || continue
            echo "$page:$((start + ln)): a command block holds a placeholder-style construct (<, \$(, &&, || or a backtick): $rest"
            findings=1
        done < "$hits"
        for sh in bash zsh fish; do
            command -v "$sh" > /dev/null 2>&1 || continue
            if ! "$sh" -n "$file" > "$file.err" 2>&1; then
                echo "$page:$start: a command block does not parse in $sh: $(head -n 1 "$file.err")"
                findings=1
            fi
        done
    done
    [ "$findings" -eq 0 ]
}

# done_lines <page>: the DONE lines inside text blocks.
done_lines() {
    local dir meta file lang
    dir=$(mktemp -d "$WORK/done.XXXXXX") || return 2
    extract_blocks "$1" "$dir"
    for meta in "$dir"/block-*.meta; do
        [ -e "$meta" ] || break
        file=${meta%.meta}
        lang=$(cut -f2 "$meta")
        [ "$lang" = text ] || continue
        grep '^DONE: ' "$file"
    done
}

# helper_done_regexes: one anchored regex per rs_done template in remote-setup.sh.
helper_done_regexes() {
    local tpl
    grep -o 'rs_done "[^"]*"' "$HERE/remote-setup.sh" | sed 's/^rs_done "//; s/"$//' | while IFS= read -r tpl; do
        printf '^DONE: %s$\n' "$(printf '%s' "$tpl" | sed -e 's#[][\.*^$()+?{}|/]#\\&#g' -e 's#\\\$RS_BOT_USER#[A-Za-z0-9_]+#g' -e 's#\\\$RS_BOT_ID#[0-9]+#g' -e 's#\\\$names#[a-z0-9][a-z0-9, -]*#g' -e 's#\\\$name#[a-z0-9][a-z0-9-]*#g')"
    done
}

# line_matches_helper <regexes> <line>: 0 when the line matches any regex.
line_matches_helper() {
    local re
    while IFS= read -r re; do
        [ -n "$re" ] || continue
        if grep -Eq "$re" <<< "$2"; then return 0; fi
    done <<EOF
$1
EOF
    return 1
}

# ── the self-tests ──────────────────────────────────────────────────────

PASS=0
FAILN=0
ok() { PASS=$((PASS + 1)); printf 'ok: %s\n' "$1"; }
bad() { FAILN=$((FAILN + 1)); printf 'FAIL: %s\n' "$1" >&2; }

# lint_fails <name> <page> <text the findings must hold>
lint_fails() {
    if (unset CI; lint_page "$2") > "$WORK/f.out" 2>&1; then
        bad "$1: the lint passed"
    elif grep -q "$3" "$WORK/f.out"; then
        ok "$1"
    else
        bad "$1: failed for another reason: $(cat "$WORK/f.out")"
    fi
}

lint_passes() { # lint_passes <name> <page>
    if (unset CI; lint_page "$2") > "$WORK/f.out" 2>&1; then ok "$1"; else bad "$1: the lint failed: $(cat "$WORK/f.out")"; fi
}

# A PATH holding everything on the current PATH except one tool.
path_without() { # path_without <tool> <dir>
    local d f n
    mkdir -p "$2"
    for d in $(printf '%s' "$PATH" | tr ':' ' '); do
        for f in "$d"/*; do
            [ -x "$f" ] || continue
            n=${f##*/}
            [ "$n" = "$1" ] && continue
            [ -e "$2/$n" ] || ln -s "$f" "$2/$n"
        done
    done
}

fixture() { # fixture <name> <lines...>: a page under $WORK
    local f=$WORK/$1.md
    shift
    printf '%s\n' "$@" > "$f"
    printf '%s' "$f"
}

t_guide_commands_have_no_placeholders() {
    local out
    out=$(lint_page "$PAGE" 2>&1 | grep 'placeholder-style')
    if [ -z "$out" ]; then ok guide_commands_have_no_placeholders; else bad "guide_commands_have_no_placeholders: $out"; fi
}

t_guide_commands_parse_in_bash_zsh_fish() {
    local out p s missing=""
    out=$(lint_page "$PAGE" 2>&1 | grep 'does not parse')
    if [ "${CI:-}" = true ]; then
        for s in zsh fish; do command -v "$s" > /dev/null 2>&1 || missing="$missing $s"; done
    fi
    if [ -n "$missing" ]; then
        bad "guide_commands_parse_in_bash_zsh_fish: CI=true and not installed:$missing, so the page was not parsed in it"
    elif [ -z "$out" ]; then ok guide_commands_parse_in_bash_zsh_fish; else bad "guide_commands_parse_in_bash_zsh_fish: $out"; fi
    # the lint really runs each shell: a command only fish rejects is caught
    if command -v fish > /dev/null 2>&1; then
        p=$(fixture fish-only '```bash' 'echo ${HOME}' '```')
        lint_fails guide_parse_catches_a_fish_only_syntax_error "$p" "does not parse in fish"
    fi
}

t_guide_lint_fails_without_fish_in_ci() {
    local p
    path_without fish "$WORK/nofish"
    p=$(fixture clean '```bash' 'cd ~/himmel' '```')
    if CI=true PATH="$WORK/nofish" bash "$HERE/test-remote-setup-guide.sh" --lint "$p" > "$WORK/ci.out" 2>&1; then
        bad "guide_lint_fails_without_fish_in_ci: exit 0 with fish missing and CI=true"
    elif grep -q 'fish is not installed and CI=true' "$WORK/ci.out"; then
        ok guide_lint_fails_without_fish_in_ci
    else
        bad "guide_lint_fails_without_fish_in_ci: failed, but not for the missing fish: $(cat "$WORK/ci.out")"
    fi
    # outside CI a missing fish only warns (CI is unset for the child: GitHub Actions sets it for this very run)
    if env -u CI PATH="$WORK/nofish" bash "$HERE/test-remote-setup-guide.sh" --lint "$p" > /dev/null 2>&1; then
        ok guide_lint_only_warns_without_fish_outside_ci
    else
        bad "guide_lint_only_warns_without_fish_outside_ci: it failed outside CI"
    fi
}

t_guide_done_lines_match_helper() {
    local regexes line n=0 unmatched="" p
    regexes=$(helper_done_regexes)
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        n=$((n + 1))
        line_matches_helper "$regexes" "$line" || unmatched="$unmatched [$line]"
    done <<EOF
$(done_lines "$PAGE")
EOF
    if [ "$n" -gt 0 ] && [ -z "$unmatched" ]; then
        ok guide_done_lines_match_helper
    else
        bad "guide_done_lines_match_helper: $n DONE lines on the page, not matching the helper:$unmatched"
    fi
    # control: a DONE line the helper does not print is caught
    p=$(fixture wrong-done '```text' 'DONE: bot - reachable' '```')
    if line_matches_helper "$regexes" "$(done_lines "$p")"; then
        bad "guide_done_lines_control: a wrong DONE line matched"
    else
        ok guide_done_lines_control_catches_a_wrong_line
    fi
}

t_guide_lint_catches_placeholder_outside_terminal_sections() {
    local p
    p=$(fixture undo '## Undo' '```bash' 'rm -f <the-file>' '```')
    lint_fails guide_lint_catches_placeholder_in_undo "$p" "placeholder-style"
    p=$(fixture untagged '## Notes' '```' 'echo <name>' '```')
    lint_fails guide_lint_catches_placeholder_in_untagged_block "$p" "placeholder-style"
    p=$(fixture check '## Check everything' '```bash' 'echo $(date)' '```')
    lint_fails guide_lint_catches_substitution_in_check_everything "$p" "placeholder-style"
    p=$(fixture chain '## Part 1' '```sh' 'cd ~/himmel && ls' '```')
    lint_fails guide_lint_catches_and_and "$p" "placeholder-style"
    p=$(fixture ticks '## Part 1' '```shell' 'echo `date`' '```')
    lint_fails guide_lint_catches_backtick "$p" "placeholder-style"
    p=$(fixture textok '## Part 1' '```text' 'FIX: run <this> and $(that) && more' '```' '```bash' 'cd ~/himmel' '```')
    lint_passes guide_lint_exempts_text_blocks "$p"
    p=$(fixture open '## Part 1' '```bash' 'cd ~/himmel')
    lint_fails guide_lint_catches_an_unclosed_fence "$p" "never closed"
}

# fix_phrases <page>: the first-column phrase of each row of a FIX table, cut where a placeholder starts.
fix_phrases() {
    sed -n 's/^| `\([^`]*\)` |.*/\1/p' "$1" | sed -e 's/ *\.\.\..*$//' -e 's/ N .*$//' | grep -v '^$'
}

# fix_missing <page> [source...]: the FIX-table phrases that no line of the helper can print (the helper's
# own sources unless some are given).
fix_missing() {
    local page=$1 phrase missing="" code
    shift
    [ $# -gt 0 ] || set -- "$HERE/remote-setup.sh" "$HERE/lib.sh"
    # code only: a whole-line comment and a trailing "  # note" are not something the helper prints
    code=$(cat "$@" | sed -e '/^[[:space:]]*#/d' -e 's/[[:space:]]#[[:space:]].*$//') # read-sink-ok: reads only the helper's own sources, which the suite passes in itself
    while IFS= read -r phrase; do
        [ -n "$phrase" ] || continue
        printf '%s\n' "$code" | grep -qF -- "$phrase" || missing="$missing [$phrase]"
    done <<EOF
$(fix_phrases "$page")
EOF
    printf '%s' "$missing"
}

t_guide_fix_rows_exist_in_helper() {
    local missing n p
    n=$(fix_phrases "$PAGE" | grep -c .)
    missing=$(fix_missing "$PAGE")
    if [ "$n" -gt 0 ] && [ -z "$missing" ]; then
        ok "guide_fix_rows_exist_in_helper ($n rows)"
    else
        bad "guide_fix_rows_exist_in_helper: $n rows on the page, not in the helper:$missing"
    fi
    p=$(fixture fix-drift '| The line says | What to do |' '|---|---|' '| `no helper prints this phrase` | Do something. |')
    if [ -n "$(fix_missing "$p")" ]; then ok guide_fix_rows_control_catches_a_drifted_row; else bad "guide_fix_rows_control: a phrase nothing prints passed"; fi
    # a phrase that survives only in a comment is not printed by anything
    printf '%s\n' '# no helper prints this phrase' 'rs_fix "something else"' > "$WORK/src-comment-only.sh"
    printf '%s\n' 'rs_fix "no helper prints this phrase: do it" # a trailing note' > "$WORK/src-code.sh"
    if [ -n "$(fix_missing "$p" "$WORK/src-comment-only.sh")" ]; then ok guide_fix_rows_control_rejects_a_comment_only_phrase; else bad "guide_fix_rows_control: a phrase found only in a comment passed"; fi
    if [ -z "$(fix_missing "$p" "$WORK/src-code.sh")" ]; then ok guide_fix_rows_control_accepts_a_phrase_in_code; else bad "guide_fix_rows_control: a phrase in an rs_fix line was not found"; fi
}

t_guide_part_4_is_written() {
    local sec missing="" w prev=0 ln order_ok=1
    sec=$(awk '/<a id="part-4">/ {on = 1; next} /^## Check everything/ {on = 0} on' "$PAGE")
    for w in 'Bot-to-Bot mode' 'Group Privacy' 'Group type' 'Permissions' 'Add Members' 'Administrators' '`hello`' 'peer --remove' 'peer --replace' 'run the same command once' 'chief-to-chief' 'never post' 'DONE: peer'; do
        case "$sec" in *"$w"*) ;; *) if [ "$w" != 'never post' ]; then missing="$missing [$w]"; fi ;; esac
    done
    case "$sec" in *'arrives in a later update'*) missing="$missing [still a stub]" ;; esac
    for w in 'Group type' 'Permissions' 'Add Members' 'Administrators' 'send the word'; do
        ln=$(printf '%s\n' "$sec" | grep -n -- "$w" | head -n 1 | cut -d: -f1)
        if [ -z "$ln" ] || [ "$ln" -le "$prev" ]; then order_ok=0; fi
        prev=${ln:-0}
    done
    if [ -z "$missing" ] && [ "$order_ok" = 1 ]; then ok guide_part_4_is_written_in_order; else bad "guide_part_4_is_written_in_order: missing:$missing in order: $order_ok"; fi
}

# The pointer in peer-bridge.md names the manual steps as the way to customize the allowlist and caps,
# not as the same procedure: the guided command authorizes the peer bot only.
t_peer_bridge_pointer_does_not_call_the_manual_steps_equivalent() {
    local line
    line=$(grep -F 'Part 4 of the remote setup guide' "$REPO/docs/internals/peer-bridge.md" | head -n 1)
    case "$line" in
        *'same steps by hand'*) bad "peer_bridge_pointer: calls the manual steps the same as the guided command" ;;
        *'alternative'*'customize'*) ok peer_bridge_pointer_names_the_manual_steps_as_the_alternative ;;
        *) bad "peer_bridge_pointer: does not name the manual steps as the alternative to customize the allowlist or caps: $line" ;;
    esac
}

if [ "${1:-}" = --lint ]; then
    if [ -z "${2:-}" ] || [ ! -f "$2" ]; then
        echo "usage: test-remote-setup-guide.sh [--lint FILE]" >&2
        exit 2
    fi
    lint_page "$2"
    exit $?
fi

if [ ! -f "$PAGE" ]; then
    echo "FAIL: $PAGE does not exist" >&2
    exit 1
fi
t_guide_commands_have_no_placeholders
t_guide_commands_parse_in_bash_zsh_fish
t_guide_lint_fails_without_fish_in_ci
t_guide_done_lines_match_helper
t_guide_lint_catches_placeholder_outside_terminal_sections
t_guide_fix_rows_exist_in_helper
t_guide_part_4_is_written
t_peer_bridge_pointer_does_not_call_the_manual_steps_equivalent
printf '%s passed, %s failed\n' "$PASS" "$FAILN"
[ "$FAILN" -eq 0 ]
