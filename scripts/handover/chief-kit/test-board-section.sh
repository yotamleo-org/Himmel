#!/usr/bin/env bash
# test-board-section.sh — Hermetic tests for board-section.mjs, the chief's one-command
# writer of board sections. Every doc lives in a temp bucket; nothing reads
# the operator's handover root.
#
# PLATFORM GUARD: node only; no OS-specific behaviour beyond symlinks.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="$HERE/board-section.mjs"
REPO="$(cd "$HERE/../../.." && pwd)"
if ! command -v node >/dev/null 2>&1; then
    printf 'SKIP - test-board-section.sh (node not installed)\n'
    exit 0
fi
W="$(mktemp -d "${TMPDIR:-/tmp}/board-section-test.XXXXXX")" || exit 1
trap 'rm -rf "$W"' EXIT
fails=0

pass() { printf 'ok - %s\n' "$1"; }
fail() { printf 'FAIL - %s\n' "$1"; fails=$((fails + 1)); }
same() {
    if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (got '$2', want '$3')"; fi
}
# jq-free JSON probe: node prints the value of an expression over the parsed file.
jget() { node -e 'const j=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));console.log(eval(process.argv[2]))' "$1" "$2" 2>/dev/null; }

B="$W/bucket"
mkdir -p "$B"
DOC="$B/X-nextleg-2026-01-01A-chief.md"
SC="$B/X-nextleg-2026-01-01A-chief.sections.json"
printf '# chief\n' > "$DOC"

run() { node "$SUT" --doc "$DOC" "$@" 2>"$W/err"; }

# RED row: the first set creates the sidecar with rev 1 and a sorted sections array.
out="$(run set next-up --title Next --body hi)"; rc=$?
same 'set exits 0' "$rc" 0
same 'set creates the sidecar with rev 1' "$(jget "$SC" 'j.rev')" 1
same 'sidecar schema' "$(jget "$SC" 'j.schema')" 'himmel.board-sections/1'
run set a-first --title First --body one --order 5 >/dev/null
same 'sections are sorted by order then id' "$(jget "$SC" 'j.sections.map(s=>s.id).join(",")')" 'a-first,next-up'
same 'set prints redacted: 0 for a plain body' "$(run set plain --title P --body ok | grep redacted)" 'redacted: 0'

# replace
rev_before="$(jget "$SC" 'j.rev')"
run set next-up --title Next2 --body two >/dev/null
same 'a second set of the same id replaces it with the next rev' "$(jget "$SC" 'j.rev')" "$((rev_before + 1))"
same 'the replaced title is stored' "$(jget "$SC" 'j.sections.find(s=>s.id==="next-up").title')" 'Next2'
same 'replace keeps one row for the id' "$(jget "$SC" 'j.sections.filter(s=>s.id==="next-up").length')" 1

# rm
run rm plain >/dev/null; rc=$?
same 'rm exits 0' "$rc" 0
same 'rm removes the section' "$(jget "$SC" 'j.sections.some(s=>s.id==="plain")')" false
run rm plain >/dev/null; same 'rm of a missing id exits 2' "$?" 2

# list
same 'list prints one line per section' "$(run list | wc -l | tr -d ' ')" 2

# bad ids and fields (I8)
for bad in 'Bad' 'has space' '-lead' ''; do
    run set "$bad" --title T --body b >/dev/null
    same "bad id '$bad' exits 2" "$?" 2
done
run set ok-id --title T --body b --tone loud >/dev/null; same 'bad tone exits 2' "$?" 2
run set ok-id --body b >/dev/null; same 'missing title exits 2' "$?" 2
run set ok-id --title T >/dev/null; same 'missing body exits 2' "$?" 2
run set ok-id --title "$(printf 'x%.0s' $(seq 81))" --body b >/dev/null; same 'title over 80 exits 2' "$?" 2
run set ok-id --title T --body "$(head -c 4001 /dev/zero | tr '\0' x)" >/dev/null; same 'body over 4000 exits 2' "$?" 2
same 'rejected writes leave no ok-id section' "$(jget "$SC" 'j.sections.some(s=>s.id==="ok-id")')" false

# redaction (I2): a real lock-token pattern is replaced, exit 0, count printed
out="$(run set locky --title T --body 'held by cachyos-x8664-pid909468 now')"; rc=$?
same 'a lock token in the body exits 0' "$rc" 0
same 'redacted: 1 is printed' "$(printf '%s\n' "$out" | grep redacted)" 'redacted: 1'
same 'the stored body has no token' "$(jget "$SC" 'j.sections.find(s=>s.id==="locky").body.includes("pid909468")')" false
run rm locky >/dev/null

# --body-file
printf 'from file\n' > "$W/body.txt"
run set filed --title F --body-file "$W/body.txt" >/dev/null
same '--body-file stores the file text' "$(jget "$SC" 'j.sections.find(s=>s.id==="filed").body.trim()')" 'from file'
run rm filed >/dev/null

# --expect-rev
rev="$(jget "$SC" 'j.rev')"
snap="$(cat "$SC")"
run set stale --title S --body b --expect-rev $((rev - 1)) >/dev/null; same '--expect-rev against a moved rev exits 3' "$?" 3
same '--expect-rev failure writes nothing' "$(cat "$SC")" "$snap"
run set fresh --title S --body b --expect-rev "$rev" >/dev/null; same '--expect-rev at the current rev exits 0' "$?" 0
run rm fresh >/dev/null

# symlinked sidecar (I8): exit 2, target unchanged
B2="$W/b2"; mkdir -p "$B2"
D2="$B2/Y-chief.md"; printf '# c\n' > "$D2"
printf 'precious\n' > "$W/target.txt"
ln -s "$W/target.txt" "$B2/Y-chief.sections.json"
node "$SUT" --doc "$D2" set a --title T --body b >/dev/null 2>&1
same 'a symlinked sidecar exits 2' "$?" 2
same 'the symlink target is unchanged' "$(cat "$W/target.txt")" 'precious'

# symlinked --doc: the sidecar lands beside the real doc
B3="$W/b3"; mkdir -p "$B3/real" "$B3/links"
printf '# c\n' > "$B3/real/Z-chief.md"
ln -s "$B3/real/Z-chief.md" "$B3/links/Z-chief.md"
node "$SUT" --doc "$B3/links/Z-chief.md" set a --title T --body b >/dev/null 2>&1
same 'a symlinked --doc writes beside the real doc' "$([ -f "$B3/real/Z-chief.sections.json" ] && echo yes)" yes
same 'a symlinked --doc writes nothing beside the link' "$([ -e "$B3/links/Z-chief.sections.json" ] && echo yes || echo no)" no

# interleaved sets: the second with --expect-rev; the file stays consistent
B4="$W/b4"; mkdir -p "$B4"
D4="$B4/Q-chief.md"; printf '# c\n' > "$D4"
node "$SUT" --doc "$D4" set base --title B --body b >/dev/null 2>&1
node "$SUT" --doc "$D4" set one --title One --body b >/dev/null 2>&1 &
p1=$!
node "$SUT" --doc "$D4" set two --title Two --body b --expect-rev 1 >/dev/null 2>&1
rc2=$?
wait "$p1"
case "$rc2" in 0|3) pass "the --expect-rev call exits 0 or 3 ($rc2)" ;; *) fail "the --expect-rev call exited $rc2" ;; esac
case "$rc2" in
    3) same 'a refused --expect-rev set is not stored' "$(jget "$B4/Q-chief.sections.json" 'j.sections.some(s=>s.id==="two")')" false ;;
esac
same 'the interleaved file parses with base kept' "$(jget "$B4/Q-chief.sections.json" 'j.sections.some(s=>s.id==="base")')" true
same 'no tmp file is left behind' "$(find "$B4" -name '*tmp*' | wc -l | tr -d ' ')" 0

# the reader: absent, oversize and unparseable files (the readSections seam)
rd() { RD_SUT="$SUT" RD_DOC="$1" node --input-type=module -e 'const {readSections}=await import("node:url").then(u=>import(u.pathToFileURL(process.env.RD_SUT).href)); console.log(JSON.stringify(await readSections(process.env.RD_DOC)))' 2>&1; }
B5="$W/b5"; mkdir -p "$B5"; printf '# c\n' > "$B5/N-chief.md"
same 'readSections of an absent sidecar is []' "$(rd "$B5/N-chief.md")" '{"sections":[]}'
B6="$W/b6"; mkdir -p "$B6"; D6="$B6/R-chief.md"; printf '# c\n' > "$D6"
printf '{not json' > "$B6/R-chief.sections.json"
case "$(rd "$D6")" in *'does not parse'*) pass 'an unparseable sidecar gives an error and []' ;; *) fail 'an unparseable sidecar gives an error' ;; esac
head -c 70000 /dev/zero | tr '\0' x > "$B6/R-chief.sections.json"
case "$(rd "$D6")" in *'over 65536'*) pass 'an oversize sidecar gives an error and []' ;; *) fail 'an oversize sidecar gives an error' ;; esac

# list refuses a symlinked sidecar and a foreign schema blocks a write
B8="$W/b8"; mkdir -p "$B8"; printf '# c\n' > "$B8/L-chief.md"
printf '{"schema":"himmel.board-sections/1","rev":1,"sections":[]}\n' > "$W/real-sidecar.json"
ln -s "$W/real-sidecar.json" "$B8/L-chief.sections.json"
node "$SUT" --doc "$B8/L-chief.md" list >/dev/null 2>&1; same 'list of a symlinked sidecar exits 2' "$?" 2
B9="$W/b9"; mkdir -p "$B9"; printf '# c\n' > "$B9/M-chief.md"
printf '{"schema":"himmel.board-sections/2","rev":4,"sections":[]}\n' > "$B9/M-chief.sections.json"
node "$SUT" --doc "$B9/M-chief.md" set a --title T --body b >/dev/null 2>&1; same 'a foreign schema blocks a write (exit 2)' "$?" 2
same 'the foreign-schema file is untouched' "$(jget "$B9/M-chief.sections.json" 'j.rev')" 4
run set tabbed --title "$(printf 'a\tb\nc')" --body b --order 99 >/dev/null
same 'list prints a tab and newline title as exact one-line fields' "$(run list | grep '^tabbed')" "$(printf 'tabbed\t99\tinfo\ta b c')"
run rm tabbed >/dev/null

# a checkout path holding a space still runs the CLI; a mistyped --doc exits 2 on list too
B7="$W/dir with space"; mkdir -p "$B7"; printf '# c\n' > "$B7/S-chief.md"
cp "$SUT" "$B7/board-section.mjs"; cp "$HERE/redact.mjs" "$B7/redact.mjs"
node "$B7/board-section.mjs" --doc "$B7/S-chief.md" set a --title T --body b >/dev/null 2>&1
same 'the CLI runs from a path holding a space' "$?" 0
run list >/dev/null; same 'list of a real doc exits 0' "$?" 0
node "$SUT" --doc "$W/no-such-doc.md" list >/dev/null 2>&1; same 'list of a mistyped --doc exits 2' "$?" 2

# I9: no file under scripts/ or marketplace/ names a sections sidecar except board-section.mjs and its tests.
# ponytail: a path built from parts passes this; upgrade path: after the state-database flip the record's I6 lint covers it.
hits="$(cd "$REPO" && git grep -l -e 'sections\.json' -- scripts marketplace 2>/dev/null \
    | grep -v -e '^scripts/handover/chief-kit/board-section\.mjs$' -e '^scripts/handover/chief-kit/test-board-section\.sh$' -e '^scripts/handover/chief-kit/test-board\.sh$' || true)"
same 'no file names a sections sidecar except board-section.mjs and its tests' "$hits" ''

if [ "$fails" -eq 0 ]; then
    printf '%s\n' 'PASS - test-board-section.sh'
    exit 0
fi
printf 'FAIL - test-board-section.sh (%s failure(s))\n' "$fails"
exit 1
