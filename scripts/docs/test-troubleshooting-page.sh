#!/usr/bin/env bash
# Suite for the Troubleshooting page, docs/troubleshooting.md.
#
# Each table row on the page is keyed on the exact message a user sees, in a
# code span in the row's first cell, so a search for the message finds it. A
# key may carry a <placeholder> where the code interpolates a value; the parts
# between placeholders are then searched for separately, in one file.
#
#   1. ROWS     — the page exists, has keyed rows, and has no table row whose
#                 first cell lacks a key.
#   2. DRIFT    — every key still exists in the code (scripts/ or marketplace/,
#                 tests, fixtures and Markdown left out), so a reworded message
#                 fails here instead of leaving a row nobody can find.
#   3. NOREPEAT — no key appears on the page the sidebar labels "When a
#                 guardrail stops you": a refusal it covers is linked, not
#                 repeated.
#   4. CONTROL  — a copy of the page with a made-up message fails case 2, a
#                 copy with an unkeyed row fails case 1, and a copy with a row
#                 keyed on a guardrail-page message fails case 3, so no check
#                 can pass vacuously.
#
# Platform guard (posix-bash): POSIX bash 3.2+ plus git and grep/sed.
#
# Usage: bash scripts/docs/test-troubleshooting-page.sh
# Exit:  0 = every case passed, 1 = at least one failed (all are reported).
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
PAGE="$ROOT/docs/troubleshooting.md"

pass=0
fail=0
ok() { pass=$((pass + 1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf 'FAIL %s\n' "$1"; [ -n "${2:-}" ] && printf '       %s\n' "$2"; }

# Prints each row key of a page, one per line: the first code span of every
# table row whose first cell starts with one.
row_keys() {
  # shellcheck disable=SC2016  # the backticks are Markdown, not a substitution
  sed -n 's/^| `\([^`]*\)`.*/\1/p' "$1"
}

# Prints each table body row of a page whose first cell does not start with a
# code span, so a row nobody keyed cannot slip past cases 2 and 3.
unkeyed_rows() {
  # shellcheck disable=SC2016  # the backticks are Markdown, not a substitution
  grep '^|' "$1" | grep -v '^| What you see |' | grep -vE '^\|[ |:-]+$' | grep -v '^| `'
}

# Prints the parts of a key between its <placeholders>, one per line; a part
# with no letter or digit (the quote after '<branch>') matches anything, so it
# is left out.
key_parts() {
  printf '%s\n' "$1" | awk '{ gsub(/<[A-Za-z_-]+>/, "\n"); print }' | grep '[[:alnum:]]'
}

# Exit 0 when one code file holds every part of the key.
key_in_code() {
  local first part file
  first=$(key_parts "$1" | head -n 1)
  while IFS= read -r file; do
    while IFS= read -r part; do
      grep -qF -- "$part" "$ROOT/$file" || continue 2
    done < <(key_parts "$1")
    return 0
  done < <(git -C "$ROOT" grep -lF -e "$first" -- scripts marketplace \
             ':!*.md' ':(exclude,glob)**/test-*' ':(exclude,glob)**/tests/**' ':(exclude,glob)**/fixtures/**')
  return 1
}

# The docs/ page the sidebar labels "When a guardrail stops you".
guardrail_page() {
  local slug
  slug=$(sed -n "s/.*label: 'When a guardrail stops you', slug: '\([^']*\)'.*/\1/p" "$ROOT/site/astro.config.mjs")
  [ -n "$slug" ] && printf '%s/docs/%s.md\n' "$ROOT" "$slug"
}

# Prints each key of the page that no code file holds.
missing_keys() {
  local key
  while IFS= read -r key; do
    key_in_code "$key" || printf '%s\n' "$key"
  done < <(row_keys "$1")
}

# Prints each key of the page with a part that appears on the guardrail page.
repeated_keys() {
  local key part
  while IFS= read -r key; do
    while IFS= read -r part; do
      if grep -qF -- "$part" "$2"; then printf '%s\n' "$key"; break; fi
    done < <(key_parts "$key")
  done < <(row_keys "$1")
}

# 1. ROWS
if [ -f "$PAGE" ] && [ -n "$(row_keys "$PAGE")" ]; then
  ok "ROWS: docs/troubleshooting.md has keyed rows ($(row_keys "$PAGE" | wc -l | tr -d ' '))"
else
  bad "ROWS: docs/troubleshooting.md has keyed rows" "no page, or no row whose first cell starts with a code span"
fi
if [ -f "$PAGE" ]; then
  loose=$(unkeyed_rows "$PAGE")
  if [ -z "$loose" ]; then ok "ROWS: every table row is keyed on its message"
  else bad "ROWS: every table row is keyed on its message" "unkeyed: $(printf '%s' "$loose" | cut -c1-80 | tr '\n' ';')"; fi
fi

# 2. DRIFT
if [ -f "$PAGE" ]; then
  gone=$(missing_keys "$PAGE")
  if [ -z "$gone" ]; then ok "DRIFT: every row's message exists in the code"
  else bad "DRIFT: every row's message exists in the code" "not found: $(printf '%s' "$gone" | tr '\n' ';')"; fi
fi

# 3. NOREPEAT
GPAGE=$(guardrail_page)
if [ -z "$GPAGE" ] || [ ! -f "$GPAGE" ]; then
  bad "NOREPEAT: the guardrail page resolves from site/astro.config.mjs" "got: '${GPAGE}'"
elif [ -f "$PAGE" ]; then
  dup=$(repeated_keys "$PAGE" "$GPAGE")
  if [ -z "$dup" ]; then ok "NOREPEAT: no row repeats a message from ${GPAGE#"$ROOT"/}"
  else bad "NOREPEAT: no row repeats a message from ${GPAGE#"$ROOT"/}" "repeated: $(printf '%s' "$dup" | tr '\n' ';')"; fi
fi

# 4. CONTROL
tmp=$(mktemp -d "${TMPDIR:-/tmp}/troubleshooting.XXXXXX") || exit 1
trap 'rm -rf "$tmp"' EXIT
# shellcheck disable=SC2016  # the backticks are Markdown, not a substitution
printf '| `troubleshooting-control: a message no code prints` | x | y |\n' > "$tmp/drift.md"
if [ -n "$(missing_keys "$tmp/drift.md")" ]; then ok "CONTROL: a made-up message fails DRIFT"
else bad "CONTROL: a made-up message fails DRIFT"; fi
printf '| an unkeyed message | x | y |\n' > "$tmp/unkeyed.md"
if [ -n "$(unkeyed_rows "$tmp/unkeyed.md")" ]; then ok "CONTROL: an unkeyed row fails ROWS"
else bad "CONTROL: an unkeyed row fails ROWS"; fi
if [ -n "$GPAGE" ] && [ -f "$GPAGE" ]; then
  # shellcheck disable=SC2016  # the backticks are Markdown, not a substitution
  printf '| `check-main-ref-transaction: refusing to update <ref>` | x | y |\n' > "$tmp/repeat.md"
  if [ -n "$(repeated_keys "$tmp/repeat.md" "$GPAGE")" ]; then ok "CONTROL: a guardrail-page message fails NOREPEAT"
  else bad "CONTROL: a guardrail-page message fails NOREPEAT"; fi
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
