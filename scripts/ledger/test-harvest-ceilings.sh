#!/usr/bin/env bash
# test-harvest-ceilings.sh - tests for scripts/one-shot/harvest-ceilings.py
# (harvest, strip, verify) on throwaway git repos. The marker token is built at
# runtime ($TOK), so this file carries none. Bash 3.2-safe.
#
#   harvest  one row per form (#, //, JSDoc, docstring, JSON string, Markdown);
#            a block stops before a directive line; a file-header block and a
#            Markdown line get an anchor import --check accepts; a code or data
#            hit is pre-set dropped; a bare back-reference is listed
#   --carry  a triaged row keeps its state, a changed block resets to open, a
#            new block is added open
#   strip    deletes comment blocks and trailing comments, leaves a token in a
#            quoted string or a heredoc body and lists it
#   verify   passes on comment-only cuts; fails on a deleted code line, a deleted
#            heredoc data line and a deleted directive line
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
PY="$HERE/../one-shot/harvest-ceilings.py"
ADD="$HERE/ceiling-add.sh"
PASS=0; FAIL=0
pass() { PASS=$((PASS + 1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL: $1"; }

[ -f "$PY" ] || { echo "FAIL: $PY does not exist yet (RED)"; exit 1; }

W="$(mktemp -d "${TMPDIR:-/tmp}/harvest-ceilings.XXXXXX")" || { echo "mktemp failed" >&2; exit 1; }
trap 'rm -rf "$W"' EXIT
export HIMMEL_CEILINGS_LEDGER="$W/ledger.tsv"
case "$HIMMEL_CEILINGS_LEDGER" in "$W"/*) pass "the ledger override points inside the work dir" ;; *) fail "ledger override outside the work dir" ;; esac

TOK="pony""tail:"; BARE="pony""tail"
newrepo() { rm -rf "$1"; mkdir -p "$1"; git -C "$1" init -q; git -C "$1" config user.email t@t; git -C "$1" config user.name t; git -C "$1" config commit.gpgsign false; }
commit() { git -C "$1" add -A; git -C "$1" commit -q --no-verify -m "$2"; }
hv() { (cd "$R" && python3 -I "$PY" "$@" 2>"$W/err"); }
row() { # row <file> -> the draft row of that file (first)
    awk -F '\t' -v f="$1" '$1 == f { print; exit }' "$W/draft.tsv"
}
col() { printf '%s' "$1" | awk -F '\t' -v n="$2" '{ print $n }'; }

echo "== harvest: one row per form =="
R="$W/repo"; newrepo "$R"
printf '#!/usr/bin/env bash\nfn_a() {\n    # %s first part of the ceiling,\n    # upgrade when the second thing matters\n    # shellcheck disable=SC2086\n    echo x\n}\n' "$TOK" > "$R/a.sh"
printf 'function fnB() {\n  // %s ascii only, revisit if users ask\n  return 1;\n}\n' "$TOK" > "$R/b.js"
printf '/**\n * Parses c.\n * %s no streaming, upgrade if files exceed a gigabyte\n */\nexport function parseC() {}\n' "$TOK" > "$R/c.ts"
printf 'def fn_d():\n    """Do d.\n\n    %s no retries, upgrade when it gets flaky\n    """\n    return 1\n' "$TOK" > "$R/d.py"
printf '{\n  "rules": {\n    "note": "%s a fixed list, upgrade when it grows"\n  }\n}\n' "$TOK" > "$R/e.json"
printf '# Title\n\n## Limits\n\n- %s one host only, upgrade later\n  wrapped tail of the line\n\nnext para\n' "$TOK" > "$R/f.md"
printf '#!/usr/bin/env bash\n# %s header ceiling, none planned\nset -u\necho g\n' "$TOK" > "$R/g.sh"
printf '#!/usr/bin/env bash\ngrep -q "%s" x\n' "$TOK" > "$R/h.sh"
printf '#!/usr/bin/env bash\ncat <<EOF\n# %s in a heredoc body\nEOF\n' "$TOK" > "$R/i.sh"
printf '#!/usr/bin/env bash\n# the %s convention is retired\necho j\n' "$BARE" > "$R/j.sh"
commit "$R" base
hv harvest a.sh b.js c.ts d.py e.json f.md g.sh h.sh i.sh j.sh > "$W/draft.tsv"; RC=$?
if [ "$RC" -eq 0 ]; then pass "harvest exits 0"; else fail "harvest rc=$RC: $(cat "$W/err")"; fi
if [ "$(head -1 "$W/draft.tsv")" = "$(printf 'file\tanchor\tceiling\ttrigger\tticket\tstate\tnote')" ]; then pass "draft header"; else fail "draft header: $(head -1 "$W/draft.tsv")"; fi
n="$(awk 'NR > 1 && $0 != ""' "$W/draft.tsv" | wc -l | tr -d ' ')"
if [ "$n" = 9 ]; then pass "nine rows, one per token"; else fail "rows=$n: $(cat "$W/draft.tsv")"; fi
for f in a.sh b.js c.ts d.py e.json f.md g.sh; do
    r="$(row "$f")"
    if [ -n "$r" ] && [ "$(col "$r" 6)" = open ] && [ -n "$(col "$r" 2)" ] && case "$(col "$r" 7)" in "migration: "*) true ;; *) false ;; esac; then
        pass "$f: an open row with an anchor and a migration note"
    else fail "$f: $r"; fi
done
r="$(row a.sh)"
if [ "$(col "$r" 2)" = fn_a ]; then pass "a.sh: anchor is the enclosing function"; else fail "a.sh anchor: $r"; fi
if [ "$(col "$r" 3)" = "first part of the ceiling, upgrade when the second thing matters" ]; then pass "a.sh: block joined, stops before the directive line"; else fail "a.sh ceiling: $r"; fi
if [ "$(col "$r" 4)" = "upgrade when the second thing matters" ]; then pass "a.sh: trigger is the upgrade clause"; else fail "a.sh trigger: $r"; fi
r="$(row b.js)"; if [ "$(col "$r" 2)" = fnB ]; then pass "b.js: // form, function anchor"; else fail "b.js: $r"; fi
r="$(row c.ts)"; if [ "$(col "$r" 3)" = "no streaming, upgrade if files exceed a gigabyte" ]; then pass "c.ts: JSDoc form"; else fail "c.ts: $r"; fi
r="$(row d.py)"; if [ "$(col "$r" 2)" = fn_d ] && [ "$(col "$r" 3)" = "no retries, upgrade when it gets flaky" ]; then pass "d.py: docstring form"; else fail "d.py: $r"; fi
r="$(row e.json)"; if [ "$(col "$r" 2)" = note ] && [ "$(col "$r" 3)" = "a fixed list, upgrade when it grows" ]; then pass "e.json: JSON string form, key anchor"; else fail "e.json: $r"; fi
r="$(row f.md)"; if [ "$(col "$r" 2)" = Limits ] && [ "$(col "$r" 3)" = "one host only, upgrade later wrapped tail of the line" ]; then pass "f.md: Markdown form, heading anchor"; else fail "f.md: $r"; fi
r="$(row g.sh)"; if [ "$(col "$r" 2)" = "set -u" ]; then pass "g.sh: a file-header block anchors on the next code line"; else fail "g.sh: $r"; fi
for f in h.sh i.sh; do
    r="$(row "$f")"
    if [ "$(col "$r" 6)" = dropped ] && case "$(col "$r" 7)" in "migration: not a marker"*) true ;; *) false ;; esac; then pass "$f: a code or data hit is pre-set dropped"; else fail "$f: $r"; fi
    if grep -q "^not-a-marker	$f:" "$W/err"; then pass "$f: listed as not a marker"; else fail "$f not listed: $(cat "$W/err")"; fi
done
if grep -q "^backref	j.sh:2" "$W/err"; then pass "a bare back-reference is listed"; else fail "backref: $(cat "$W/err")"; fi
OUT="$(cd "$R" && bash "$ADD" import --check "$W/draft.tsv" 2>&1)"; RC=$?
if [ "$RC" -eq 0 ]; then pass "import --check accepts the draft"; else fail "import --check rc=$RC: $OUT"; fi

echo "== harvest --carry =="
awk -F '\t' -v OFS='\t' '$1 == "a.sh" { $6 = "lifted"; $7 = "migration: fixed by the rewrite" } { print }' "$W/draft.tsv" > "$W/old.tsv"
printf 'function fnB() {\n  // %s ascii and latin-1 only, revisit if users ask\n  return 1;\n}\n' "$TOK" > "$R/b.js"
printf '#!/usr/bin/env bash\nfn_k() {\n    # %s a new block, upgrade later\n    :\n}\n' "$TOK" > "$R/k.sh"
commit "$R" carry
hv harvest a.sh b.js k.sh --carry "$W/old.tsv" > "$W/draft.tsv"; RC=$?
r="$(row a.sh)"; if [ "$RC" -eq 0 ] && [ "$(col "$r" 6)" = lifted ] && [ "$(col "$r" 7)" = "migration: fixed by the rewrite" ]; then pass "--carry keeps a triaged row"; else fail "carry a.sh rc=$RC: $r"; fi
r="$(row b.js)"; if [ "$(col "$r" 6)" = open ]; then pass "--carry resets a changed block to open"; else fail "carry b.js: $r"; fi
r="$(row k.sh)"; if [ "$(col "$r" 6)" = open ]; then pass "--carry adds a new block as open"; else fail "carry k.sh: $r"; fi

echo "== strip =="
R="$W/strip"; newrepo "$R"
printf '#!/usr/bin/env bash\nfn_a() {\n    # %s first part,\n    # upgrade later\n    # shellcheck disable=SC2086\n    echo x\n}\n' "$TOK" > "$R/a.sh"
printf '#!/usr/bin/env bash\necho hi  # %s trailing, upgrade x\n' "$TOK" > "$R/l.sh"
printf '#!/usr/bin/env bash\ngrep -q "%s" x\n' "$TOK" > "$R/h.sh"
printf '#!/usr/bin/env bash\ncat <<EOF\n# %s in a heredoc body\nEOF\n' "$TOK" > "$R/i.sh"
commit "$R" base
cp "$R/h.sh" "$W/h.before"; cp "$R/i.sh" "$W/i.before"
OUT="$(cd "$R" && python3 -I "$PY" strip a.sh l.sh h.sh i.sh 2>&1)"; RC=$?
if [ "$RC" -eq 0 ]; then pass "strip exits 0"; else fail "strip rc=$RC: $OUT"; fi
if [ "$(cat "$R/a.sh")" = "$(printf '#!/usr/bin/env bash\nfn_a() {\n    # shellcheck disable=SC2086\n    echo x\n}')" ]; then pass "strip deletes the block and keeps the directive"; else fail "a.sh after strip: $(cat "$R/a.sh")"; fi
if [ "$(cat "$R/l.sh")" = "$(printf '#!/usr/bin/env bash\necho hi')" ]; then pass "strip cuts a trailing comment and keeps the code"; else fail "l.sh after strip: $(cat "$R/l.sh")"; fi
if cmp -s "$R/h.sh" "$W/h.before" && cmp -s "$R/i.sh" "$W/i.before"; then pass "strip leaves a quoted-string and a heredoc token"; else fail "h.sh/i.sh changed"; fi
case "$OUT" in *"left	h.sh:2"*"left	i.sh:3"*) pass "strip lists the tokens it left" ;; *) fail "strip list: $OUT" ;; esac

echo "== verify =="
R="$W/verify"; newrepo "$R"
printf '#!/usr/bin/env bash\n# shellcheck disable=SC2034\na=1  # %s trailing, upgrade x\n# %s block, upgrade y\nb=2\ncat <<EOF\ndata line\nEOF\n' "$TOK" "$TOK" > "$R/v.sh"
printf 'x = 1  # %s trailing, upgrade x\n# %s block\ny = 2\n' "$TOK" "$TOK" > "$R/v.py"
printf '# Doc\n\ntext\n' > "$R/README.md"
commit "$R" base
base="$(git -C "$R" rev-parse HEAD)"
vcase() { # vcase <name> <v.sh content>
    git -C "$R" checkout -q -B "$1" "$base"
    printf '%b' "$2" > "$R/v.sh"
    printf 'x = 1\ny = 2\n' > "$R/v.py"
    printf '# Doc\n\ntext, edited\n' > "$R/README.md"
    commit "$R" "$1"
    OUT="$(cd "$R" && python3 -I "$PY" verify "$base" 2>&1)"; RC=$?
}
vcase ok '#!/usr/bin/env bash\n# shellcheck disable=SC2034\na=1\nb=2\ncat <<EOF\ndata line\nEOF\n'
if [ "$RC" -eq 0 ] && case "$OUT" in *"verify: PASS"*) true ;; *) false ;; esac; then pass "verify passes on comment-only cuts"; else fail "verify ok rc=$RC: $OUT"; fi
case "$OUT" in *"named	README.md"*) pass "verify names a file it cannot compare" ;; *) fail "named list: $OUT" ;; esac
vcase code '#!/usr/bin/env bash\n# shellcheck disable=SC2034\na=1\ncat <<EOF\ndata line\nEOF\n'
if [ "$RC" -eq 1 ] && case "$OUT" in *"FAIL v.sh"*) true ;; *) false ;; esac; then pass "verify fails on a deleted code line"; else fail "verify code rc=$RC: $OUT"; fi
printf 'file\tanchor\tceiling\ttrigger\tticket\tstate\tnote\nv.sh\tb=2\tdata line\tnone-planned: x\t\tdropped\tmigration: not a marker: code or test data, token rebuilt at runtime\n' > "$W/stub.tsv"
vcase heredoc '#!/usr/bin/env bash\n# shellcheck disable=SC2034\na=1\nb=2\ncat <<EOF\nEOF\n'
if [ "$RC" -eq 1 ] && case "$OUT" in *"FAIL v.sh"*) true ;; *) false ;; esac; then pass "verify fails on a deleted heredoc data line a harvest record lists"; else fail "verify heredoc rc=$RC: $OUT"; fi
vcase directive '#!/usr/bin/env bash\na=1\nb=2\ncat <<EOF\ndata line\nEOF\n'
if [ "$RC" -eq 1 ] && case "$OUT" in *"FAIL v.sh"*shellcheck*) true ;; *) false ;; esac; then pass "verify fails on a deleted directive line"; else fail "verify directive rc=$RC: $OUT"; fi

echo "== $PASS passed, $FAIL failed =="
[ "$FAIL" -eq 0 ]
