#!/bin/sh
# Stand-in Jira CLI for a suite whose fixture closes a proof owed row: `comment <KEY> <text>`
# appends the text to $OWE_STUB_DIR/comments.<KEY>, `comments <KEY>` prints that file.
# Point OWE_JIRA_CLI at this script and OWE_STUB_DIR at a scratch directory.
dir="${OWE_STUB_DIR:?OWE_STUB_DIR names the scratch directory}"
case "$1" in
    comment) printf '%s\n' "$3" >> "$dir/comments.$2" ;;
    comments) cat "$dir/comments.$2" 2>/dev/null; exit 0 ;;
    *) exit 2 ;;
esac
