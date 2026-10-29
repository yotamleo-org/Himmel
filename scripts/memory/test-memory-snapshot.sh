#!/usr/bin/env bash
# Tests for scripts/memory/memory-snapshot.sh (take | verify | restore --expect).
#
# Synthetic fixtures only, in a sandbox store; nothing here reads or writes a
# real memory dir. Every run of the script under test sees a PATH WITHOUT
# sha256sum plus a `shasum -a 256` shim (the stock-macOS shape), so the suite
# also proves the hashing goes through scripts/lib/sha256-bin.sh.
#
# Roles in restore: B = the before-snapshot, C = the checkpoint (--expect),
# L = the live store.
set -uo pipefail

SNAPSHOT="$(cd "$(dirname "$0")" && pwd)/memory-snapshot.sh"

FAILED=0; SB="$(mktemp -d "${TMPDIR:-/tmp}/memsnap.XXXXXX")"; trap 'rm -rf "$SB"' EXIT
MEM="$SB/mem"; SNAPS="$SB/snaps"; BIN="$SB/bin"
mkdir -p "$BIN"

ok() { if "${@:2}"; then echo "PASS $1"; else echo "FAIL $1"; FAILED=1; fi; }
assert_rc() { if [ "$3" = "$2" ]; then echo "PASS $1 (rc=$3)"; else echo "FAIL $1 (want $2, got $3)"; FAILED=1; fi; }
has() { printf '%s\n' "$1" | grep -qF -- "$2"; }
lacks() { ! printf '%s\n' "$1" | grep -qF -- "$2"; }
body() { [ "$(cat "$MEM/$1" 2>/dev/null; echo x)" = "$2"$'\n'x ]; }

# --- the macOS-shaped toolbox: real tools, no sha256sum, a shasum shim ---
for t in awk sed grep sort comm find cp mv mkdir rmdir date cat rm ls dirname basename \
         cmp chmod git tr head tail wc uniq env mktemp touch diff cut readlink stat uname sleep; do
    p="$(command -v "$t" 2>/dev/null || true)"
    case "$p" in /*) ln -s "$p" "$BIN/$t" ;; esac
done
REAL_SHA="$(command -v sha256sum)"
# shellcheck disable=SC2016  # the shim body is literal text, expanded when the shim runs
printf '#!/bin/sh\necho "$*" >> "%s/shasum.log"\n[ "$1" = "-a" ] && shift 2\nexec "%s" "$@"\n' "$SB" "$REAL_SHA" > "$BIN/shasum"
chmod +x "$BIN/shasum"

snap() { PATH="$BIN" MEMDIR="$MEM" "$BASH" "$SNAPSHOT" "$@"; }
w() { printf '%s\n' "$2" > "$MEM/$1"; }

# A fresh live store (and an empty snapshot area) with a capture log.
fresh() {
    rm -rf "$MEM" "$SNAPS"; mkdir -p "$MEM" "$SNAPS"
    w MEMORY.md '- [hub](hub.md) — h'
    w hub.md hub
    w a.md alpha
    w b.md bravo
    w c.md charlie
    printf '{"n":1}\n' > "$MEM/.capture-log.jsonl"
}
# take A, then a "pass": change a.md and MEMORY.md, delete b.md, add sub.md; take B.
pass() {
    snap take "$SNAPS/A" >/dev/null
    w a.md alpha-pass; w MEMORY.md '- [hub](hub.md) — h2'; rm -f "$MEM/b.md"; w sub.md sub
    snap take "$SNAPS/B" >/dev/null
}
removed_dir() { find "$SNAPS" -maxdepth 1 -type d -name 'A.removed-*' | head -1; }

# S1: full round trip. The pass changed, deleted and added files; restore A
# --expect B puts the store back byte-equal to A and MOVES the added file.
fresh; pass
out="$(snap restore "$SNAPS/A" --expect "$SNAPS/B" 2>&1)"; rc=$?
assert_rc "S1 restore round trip" 0 "$rc"
snap verify "$SNAPS/A" >/dev/null 2>&1; assert_rc "S1 verify A after restore" 0 "$?"
RD="$(removed_dir)"
ok "S1 added file moved to .removed- dir" test -n "$RD" -a -f "$RD/sub.md"
ok "S1 added file gone from the store" test ! -e "$MEM/sub.md"
ok "S1 restore lists the moved file" has "$out" "sub.md"

# S2: one changed byte makes verify exit 1 and name the file; equal exits 0.
fresh; snap take "$SNAPS/A" >/dev/null
snap verify "$SNAPS/A" >/dev/null 2>&1; assert_rc "S2 verify equal" 0 "$?"
printf '%s\n' alphA > "$MEM/a.md"
out="$(snap verify "$SNAPS/A" 2>&1)"; rc=$?
assert_rc "S2 verify one changed byte" 1 "$rc"
ok "S2 verify names the changed file" has "$out" "a.md"
ok "S2 verify names only that file" lacks "$out" "b.md"
w a.md alpha; w new.md n; rm -f "$MEM/c.md"
out="$(snap verify "$SNAPS/A" 2>&1)"; rc=$?
assert_rc "S2 verify added and deleted" 1 "$rc"
ok "S2 verify lists the added file" has "$out" "new.md"
ok "S2 verify lists the deleted file" has "$out" "c.md"

# S3: a file the pass changed that another writer changed again after B is a
# conflict: the other writer's bytes stay, restore exits 1, clean files restore.
fresh; pass
w a.md other-writer
out="$(snap restore "$SNAPS/A" --expect "$SNAPS/B" 2>&1)"; rc=$?
assert_rc "S3 conflict exits 1" 1 "$rc"
ok "S3 other writer's bytes kept" body a.md other-writer
ok "S3 conflict names the file" has "$out" "a.md"
ok "S3 clean file still restored" body MEMORY.md '- [hub](hub.md) — h'

# S4: a file another writer added after B survives and is listed.
fresh; pass
w late.md late
out="$(snap restore "$SNAPS/A" --expect "$SNAPS/B" 2>&1)"; rc=$?
assert_rc "S4 added since checkpoint exits 0" 0 "$rc"
ok "S4 the file survives" body late.md late
ok "S4 listed as added since the checkpoint" has "$out" "added since the checkpoint"
ok "S4 listing names the file" has "$out" "late.md"

# S5: a file the pass changed that another writer deleted after B is a
# conflict, never recreated.
fresh; pass
rm -f "$MEM/a.md"
out="$(snap restore "$SNAPS/A" --expect "$SNAPS/B" 2>&1)"; rc=$?
assert_rc "S5 conflict exits 1" 1 "$rc"
ok "S5 not recreated" test ! -e "$MEM/a.md"
ok "S5 conflict names the file" has "$out" "a.md"

# S6: a file the pass deleted is recreated byte-equal.
fresh; pass
snap restore "$SNAPS/A" --expect "$SNAPS/B" >/dev/null 2>&1; assert_rc "S6 restore" 0 "$?"
ok "S6 deleted file recreated" body b.md bravo

# S7: the capture log grows between take and restore and is never touched.
fresh; pass
printf '{"n":2}\n{"n":3}\n' >> "$MEM/.capture-log.jsonl"
before="$(cat "$MEM/.capture-log.jsonl")"
snap restore "$SNAPS/A" --expect "$SNAPS/B" >/dev/null 2>&1; assert_rc "S7 restore" 0 "$?"
ok "S7 capture log byte-identical" test "$(cat "$MEM/.capture-log.jsonl")" = "$before"
ok "S7 capture log not in the snapshot" test ! -e "$SNAPS/A/.capture-log.jsonl"
snap verify "$SNAPS/A" >/dev/null 2>&1; assert_rc "S7 verify ignores the capture log" 0 "$?"

# S8: restore without --expect exits 2 and changes nothing.
fresh; pass
out="$(snap restore "$SNAPS/A" 2>&1)"; rc=$?
assert_rc "S8 no --expect" 2 "$rc"
ok "S8 store untouched" body a.md alpha-pass

# S9: a pass-added file that another writer changed after B is a conflict and
# stays in the store.
fresh; pass
w sub.md sub-other
out="$(snap restore "$SNAPS/A" --expect "$SNAPS/B" 2>&1)"; rc=$?
assert_rc "S9 conflict exits 1" 1 "$rc"
ok "S9 file stays in the store" body sub.md sub-other
ok "S9 nothing moved" test -z "$(removed_dir)"
ok "S9 conflict names the file" has "$out" "sub.md"

# S10: a file the pass did not change (A == B) is skipped whatever it is now.
fresh; pass
w c.md c-other-writer
out="$(snap restore "$SNAPS/A" --expect "$SNAPS/B" 2>&1)"; rc=$?
assert_rc "S10 skip exits 0" 0 "$rc"
ok "S10 other writer's bytes stay" body c.md c-other-writer

# Hashing went through shasum, never sha256sum; no cp names the memory path.
ok "P1 sha256sum hidden from the script's PATH" test -z "$(PATH="$BIN"; command -v sha256sum)"
ok "P1 the shasum shim was used" test -s "$SB/shasum.log"
cpw=c; cpw="${cpw}p"
ok "P2 no command line here names $cpw on the memory path" \
    test -z "$(grep -nE "(^|[;&|[:space:]])${cpw}[[:space:]][^#]*MEM" "$0")"

if [ "$FAILED" -eq 0 ]; then echo "ALL PASS"; else echo "SOME FAILED"; exit 1; fi
