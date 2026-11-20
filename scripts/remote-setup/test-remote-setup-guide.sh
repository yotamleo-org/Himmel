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
        printf '^DONE: %s$\n' "$(printf '%s' "$tpl" | sed -e 's#[][\.*^$()+?{}|/]#\\&#g' -e 's#\\\$RS_BOT_USER#[A-Za-z0-9_]+#g' -e 's#\\\$RS_BOT_ID#[0-9]+#g')"
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
    if lint_page "$2" > "$WORK/f.out" 2>&1; then
        bad "$1: the lint passed"
    elif grep -q "$3" "$WORK/f.out"; then
        ok "$1"
    else
        bad "$1: failed for another reason: $(cat "$WORK/f.out")"
    fi
}

lint_passes() { # lint_passes <name> <page>
    if lint_page "$2" > "$WORK/f.out" 2>&1; then ok "$1"; else bad "$1: the lint failed: $(cat "$WORK/f.out")"; fi
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
    local out p
    out=$(lint_page "$PAGE" 2>&1 | grep 'does not parse')
    if [ -z "$out" ]; then ok guide_commands_parse_in_bash_zsh_fish; else bad "guide_commands_parse_in_bash_zsh_fish: $out"; fi
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
printf '%s passed, %s failed\n' "$PASS" "$FAILN"
[ "$FAILN" -eq 0 ]
