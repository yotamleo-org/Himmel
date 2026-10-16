#!/usr/bin/env bash
# env-append.sh — newline-safe append of one line to a .env file.
# Sourced; not run directly. A blind `>>` onto a file whose last line has no
# trailing newline glues the new key onto that line and corrupts both.
#
# env_append_line <file> <line> — adds the missing newline first, then <line>.

env_append_line() {
    local file="$1" line="$2"
    if [ -s "$file" ] && [ -n "$(tail -c1 "$file")" ]; then
        printf '\n' >> "$file"
    fi
    printf '%s\n' "$line" >> "$file"
}
