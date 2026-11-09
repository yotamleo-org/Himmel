#!/usr/bin/env bash
# test-marker-scan.sh - tests for scripts/one-shot/no-markers.sh on a throwaway
# repo. The marker token is built at runtime ($TOK), so this file carries none.
#   the scan passes when only a fixture path carries a marker, fails naming each
#   other file, and skips a path listed in scripts/ledger/held-paths.txt;
#   --removed passes when the net count equals the draft rows and fails otherwise.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
TOOL="$HERE/../one-shot/no-markers.sh"
PASS=0; FAIL=0
pass() { PASS=$((PASS + 1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL: $1"; }
[ -f "$TOOL" ] || { echo "FAIL: $TOOL does not exist yet (RED)"; exit 1; }

TOK="pony""tail:"
W="$(mktemp -d "${TMPDIR:-/tmp}/marker-scan.XXXXXX")" || { echo "mktemp failed" >&2; exit 1; }
trap 'rm -rf "$W"' EXIT
R="$W/repo"
mkdir -p "$R/scripts/lint" "$R/scripts/one-shot" "$R/scripts/ledger" "$R/scripts/fixtures"
git -C "$R" init -q; git -C "$R" config user.email t@t; git -C "$R" config user.name t; git -C "$R" config commit.gpgsign false
cp "$HERE/../lint/ticket-refs.awk" "$HERE/../lint/ticket-ref-allow.tsv" "$R/scripts/lint/"
cp "$TOOL" "$R/scripts/one-shot/"
printf 'echo a\n' > "$R/scripts/a.sh"
printf '# %s fixture input\n' "$TOK" > "$R/scripts/fixtures/x.sh"
git -C "$R" add -A; git -C "$R" commit -q --no-verify -m base
run() { OUT="$(cd "$R" && bash scripts/one-shot/no-markers.sh "$@" 2>&1)"; RC=$?; }
has() { case "$OUT" in *"$1"*) return 0 ;; *) return 1 ;; esac; }

run
if [ "$RC" -eq 0 ]; then pass "the scan passes when only a fixture carries a marker"; else fail "clean -> rc=$RC: $OUT"; fi
printf 'echo a\n# %s a ceiling, upgrade later\n# %s another, upgrade later\n' "$TOK" "$(printf '%s' "$TOK" | tr '[:lower:]' '[:upper:]')" > "$R/scripts/a.sh"
printf 'echo b # %s held\n' "$TOK" > "$R/scripts/b.sh"
git -C "$R" add -A; git -C "$R" commit -q --no-verify -m markers
base="$(git -C "$R" rev-parse HEAD)"
run
if [ "$RC" -eq 1 ] && has "MARKER scripts/a.sh" && has "MARKER scripts/b.sh"; then pass "the scan fails naming each file with a marker"; else fail "markers -> rc=$RC: $OUT"; fi
printf 'scripts/b.sh  # PR 1\n' > "$R/scripts/ledger/held-paths.txt"
run
if [ "$RC" -eq 1 ] && has "MARKER scripts/a.sh" && ! has "scripts/b.sh"; then pass "the scan skips a path in held-paths.txt"; else fail "held -> rc=$RC: $OUT"; fi
rm -f "$R/scripts/ledger/held-paths.txt"
printf 'echo a\n' > "$R/scripts/a.sh"
printf '# %s new fixture line\n' "$TOK" >> "$R/scripts/fixtures/x.sh"
git -C "$R" add -A; git -C "$R" commit -q --no-verify -m strip
printf 'file\tanchor\tceiling\ttrigger\tticket\tstate\tnote\na\tb\tc\td\t\topen\tmigration: x\na\tb\tc2\td\t\topen\tmigration: x\n' > "$W/draft2.tsv"
printf 'file\tanchor\tceiling\ttrigger\tticket\tstate\tnote\na\tb\tc\td\t\topen\tmigration: x\n' > "$W/draft1.tsv"
run --removed "$base~1" --draft "$W/draft2.tsv"
if [ "$RC" -eq 1 ]; then pass "--removed fails when nothing net was removed since that base"; else fail "--removed base~1 -> rc=$RC: $OUT"; fi
run --removed "$base" --draft "$W/draft2.tsv"
if [ "$RC" -eq 0 ] && has "removed: 2 markers" && has PASS; then pass "--removed passes when the count equals the draft rows"; else fail "--removed equal -> rc=$RC: $OUT"; fi
run --removed "$base" --draft "$W/draft1.tsv"
if [ "$RC" -eq 1 ] && has FAIL; then pass "--removed fails on a count mismatch"; else fail "--removed mismatch -> rc=$RC: $OUT"; fi
run --bogus
if [ "$RC" -eq 2 ]; then pass "an unknown argument exits 2"; else fail "usage -> rc=$RC: $OUT"; fi
mkdir -p "$W/bin"
REAL_GIT="$(command -v git)"
printf '#!/usr/bin/env bash\nfor a in "\044@"; do [ "\044a" = grep ] && { echo "fatal: grep broke" >&2; exit 128; }; done\nexec "%s" "\044@"\n' "$REAL_GIT" > "$W/bin/git"
chmod +x "$W/bin/git"
OUT="$(cd "$R" && PATH="$W/bin:$PATH" bash scripts/one-shot/no-markers.sh 2>&1)"; RC=$?
if [ "$RC" -eq 2 ] && has "cannot evaluate"; then pass "a git grep failure exits 2, never PASS"; else fail "git grep failure -> rc=$RC: $OUT"; fi

echo "== $PASS passed, $FAIL failed =="
[ "$FAIL" -eq 0 ]
