#!/usr/bin/env bash
# test-holds.sh — hermetic tests for holds.py, the single-writer holds register and its CLI.
#
# HOME, HANDOVER_DIR and the queue-lock runtime dirs are pinned to a temp dir at the top, so no row, event or
# lock ever lands in the real ~/.himmel/state/holds or the live release queue; a row at the end asserts no row of this run
# (named by its temp path) is in the real register. Locks are real queue-lock.sh locks under the temp handover root. gh and a
# counting/failing queue-lock are stubs. Races use 2 real processes.
#
# PLATFORM GUARD: the chief kit is Linux-only; GNU touch -d is used to age rows.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="${HOLDS_SUT:-$HERE/holds.py}"
QL="$HERE/../queue-lock.sh"
if ! command -v python3 >/dev/null 2>&1 || ! command -v git >/dev/null 2>&1; then
    printf 'SKIP - test-holds.sh (python3 or git not installed)\n'
    exit 0
fi

REAL_HOME="$HOME"

W="$(mktemp -d "${TMPDIR:-/tmp}/holds-test.XXXXXX")" || exit 1
W="$(cd "$W" && pwd -P)"
trap 'chmod -R u+rwx "$W" 2>/dev/null; rm -rf "$W"' EXIT  # restore modes first: a chmod 000 row would block the cleanup

export HOME="$W/home" HANDOVER_DIR="$W/h" XDG_RUNTIME_DIR="$W/xdg" HIMMELCTL_CACHE_DIR="$W/cache" HIMMEL_CONFIG_DIR="$W/cfg"
mkdir -p "$HOME" "$HANDOVER_DIR/u/r/sub" "$XDG_RUNTIME_DIR" "$HIMMELCTL_CACHE_DIR" "$HIMMEL_CONFIG_DIR" "$W/bin"
chmod 700 "$XDG_RUNTIME_DIR"
: > "$HIMMELCTL_CACHE_DIR/.env"
unset HIMMEL_CONSOLE_LEG HIMMEL_CONSOLE_DOC HIMMEL_HOLD_KEY HIMMEL_HOLD_DOC HIMMEL_HOLD_LABEL WRITE_HOLD_OK HOLDS_QUEUE_LOCK HOLDS_GH QUEUE_LOCK_TTL_SECONDS CLAUDE_CODE_SESSION_ID
export CLAUDE_CONFIG_DIR="$HOME/.claude"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null

fails=0
total=0
pass() { total=$((total + 1)); printf 'ok - %s\n' "$1"; }
fail() { total=$((total + 1)); printf 'FAIL - %s\n' "$1"; fails=$((fails + 1)); }
same() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (got '$2', want '$3')"; fi; }
contains() { case "$2" in *"$3"*) pass "$1" ;; *) fail "$1 (missing '$3' in '$2')" ;; esac; }
# owner_set <lock dir> <field> <value>: rewrite one field of a lock's owner.json (portable, no sed -i)
owner_set() {
    python3 -I -c "
import json, sys
p = sys.argv[1] + '/owner.json'
d = json.load(open(p)); d[sys.argv[2]] = sys.argv[3]
open(p, 'w').write(json.dumps(d, separators=(',', ':')) + '\n')" "$1" "$2" "$3"
}

hp() { python3 -I "$SUT" "$@"; }
RC=0 OUT="" ERR=""
run() { OUT=$("$@" 2>"$W/err"); RC=$?; ERR=$(<"$W/err"); }

R="$W/repo"
mkdir -p "$R"
git -C "$R" init -q -b main
mkdir -p "$R/scripts/lib" "$R/scripts/ci"
: > "$R/scripts/lib/rename-aliases.tsv"
echo seed > "$R/seed.txt"
git -C "$R" add -A
git -C "$R" commit -q -m base

REG="$HOME/.himmel/state/holds"
EVENTS="$REG/events.log"
esc() { local s="${1//%/%25}"; printf '%s' "${s//\//%2F}"; }
slugdir() { printf '%s/%s' "$REG" "$(esc "${1:-$R}")"; }
rowf() { printf '%s/%s' "$(slugdir "${2:-$R}")" "$(esc "$1")"; }
ev_count() { if [ -f "$EVENTS" ]; then wc -l < "$EVENTS" | tr -d ' '; else echo 0; fi; }
# put_row <path> <key> <label> <doc> [source] [pr] [repo]: a row written by hand, aged past the grace
put_row() {
    local f
    f="$(rowf "$1" "${7:-}")"
    mkdir -p "$(dirname "$f")"
    printf '%s\t%s\t%s\t%s\t%s\n' "$2" "$3" "$4" "${5:-brief}" "${6:-}" > "$f"
    touch -d '2 hours ago' "$f"
}
mkdoc() { local f="$HANDOVER_DIR/u/r/$1"; mkdir -p "$(dirname "$f")"; printf '%s\n' "${2:-# doc}" > "$f"; printf '%s' "$f"; }
lock_hold() { bash "$QL" acquire "$1" "${2:-sess-$(basename "$1")}" > /dev/null 2>&1; }
lock_host() { sed -n 's/.*"host":"\([^"]*\)".*/\1/p' "$1/owner.json" | head -n 1; }
lock_dir_of() { printf '%s/.locks/queue/u__r__%s.lock' "$HANDOVER_DIR" "$(basename "$1" .md)"; }

# stubs
cat > "$W/bin/gh-open" <<'STUB'
#!/usr/bin/env bash
echo OPEN
STUB
cat > "$W/bin/gh-merged" <<'STUB'
#!/usr/bin/env bash
echo MERGED
STUB
cat > "$W/bin/gh-hang" <<'STUB'
#!/usr/bin/env bash
exec sleep 30
STUB
cat > "$W/bin/ql-rc1" <<'STUB'
#!/usr/bin/env bash
exit 1
STUB
cat > "$W/bin/ql-free" <<STUB
#!/usr/bin/env bash
echo "\$*" >> "$W/ql-free-calls"
exit 0
STUB
cat > "$W/bin/ql-count" <<STUB
#!/usr/bin/env bash
echo "\$*" >> "$W/ql-calls"
exec bash "$QL" "\$@"
STUB
chmod +x "$W/bin/"*

K1=HIMMEL-9101 K2=HIMMEL-9102

# ---- no module yet: the whole suite is RED until holds.py exists
if [ ! -f "$SUT" ]; then
    fail "holds.py exists ($SUT)"
fi

# ---- I1: a second claim is refused and names the holder; a grant lets it through
D01="$(mkdoc HIMMEL-9101-case.md)"
lock_hold "$D01"
put_row scripts/c01.sh $K1 alpha "$D01"
run hp claim --key $K2 --label beta --doc "$(mkdoc HIMMEL-9102-case.md)" --repo "$R" scripts/c01.sh
same "I1 second claim on a live holder's file exits 1" "$RC" 1
contains "I1 the refusal names the holder" "$ERR" "$K1"
run hp grant --key $K2 --repo "$R" scripts/c01.sh
same "I1 grant exits 0" "$RC" 0
run hp claim --key $K2 --label beta --doc "$(mkdoc HIMMEL-9102-case.md)" --repo "$R" scripts/c01.sh
same "I1 the granted key claims the file" "$RC" 0
same "I1 the holder's row is untouched by the grant" "$(cut -f1 "$(rowf scripts/c01.sh)")" "$K1"

# ---- I4 and I3: liveness goes by key
DB="$(mkdoc HIMMEL-9102-case.md)"
put_row scripts/c02.sh HIMMEL-9112 alpha "$(mkdoc HIMMEL-9112-case.md)"
touch "$(rowf scripts/c02.sh)"
run hp claim --key $K2 --label beta --doc "$DB" --repo "$R" scripts/c02.sh
same "I4 a row inside the arm grace is alive (lock free)" "$RC" 1

put_row scripts/c03.sh HIMMEL-9113 alpha "$(mkdoc HIMMEL-9113-case.md)"
touch -d '1 hour' "$(rowf scripts/c03.sh)"
run hp claim --key $K2 --label beta --doc "$DB" --repo "$R" scripts/c03.sh
same "I4 a future mtime counts as inside the grace" "$RC" 1

D04A="$(mkdoc HIMMEL-9114-case.md)"
D04B="$(mkdoc sub/HIMMEL-9114-second.md)"
lock_hold "$D04B"
put_row scripts/c04.sh HIMMEL-9114 alpha "$D04A"
run hp claim --key $K2 --label beta --doc "$DB" --repo "$R" scripts/c04.sh
same "I4 a second doc of the key, one level down, held keeps the row alive" "$RC" 1

put_row scripts/c05.sh HIMMEL-9115 alpha "$(mkdoc HIMMEL-9115-case.md)" pr 77
run env HOLDS_GH="$W/bin/gh-open" python3 -I "$SUT" claim --key $K2 --label beta --doc "$DB" --repo "$R" scripts/c05.sh
same "I4 an open PR keeps the row alive" "$RC" 1

put_row scripts/c06.sh HIMMEL-9116 alpha "$(mkdoc HIMMEL-9116-case.md)"
before="$(ev_count)"
run hp claim --key $K2 --label beta --doc "$DB" --repo "$R" scripts/c06.sh
same "I4 a dead holder never blocks (no lock, no PR, no RESUME doc)" "$RC" 0
same "I4 the row is now the taker's" "$(cut -f1 "$(rowf scripts/c06.sh)")" "$K2"
contains "I4 the takeover is in events.log" "$(tail -n +$((before + 1)) "$EVENTS")" takeover

D07="$(mkdoc HIMMEL-9117-case.md '- 10:00 WRAPPED — done')"
mkdoc HIMMEL-9117-N1-RESUME.md '# resume doc' > /dev/null
put_row scripts/c07.sh HIMMEL-9117 alpha "$D07"
run hp claim --key $K2 --label beta --doc "$DB" --repo "$R" scripts/c07.sh
same "I3 a wrapped worker with an unwrapped RESUME doc under 24 h keeps its rows" "$RC" 1

# a RESUME doc is consumed only by an explicit mention (a WRAPPED doc names it outside its last bullet), never by a file mtime,
# a shared leg number or a shared stem: a stale hold costs a 24 h wait, a wrong release a double launch.
# The old real shape (the worker wrapped its own doc, same leg, no mention) used to release the rows; it now holds.
D11R="$(mkdoc HIMMEL-9420-N1b-RESUME.md '# resume doc')"
touch -d '1 hour ago' "$D11R"
D11="$(mkdoc HIMMEL-9420-N1-case.md '- 10:00 WRAPPED — PR merged')"
put_row scripts/c11.sh HIMMEL-9420 alpha "$D11"
run hp claim --key $K2 --label beta --doc "$DB" --repo "$R" scripts/c11.sh
same "I3 a RESUME doc with no marks and a newer same-leg WRAPPED doc with no link to it holds (changed: a leg number is no link)" "$RC" 1
D12R="$(mkdoc HIMMEL-9421-N1b-RESUME.md '# resume doc')"
touch -d '1 hour ago' "$D12R"
D12="$(mkdoc HIMMEL-9421-N1-case.md '- 10:00 WRAPPED — resume doc HIMMEL-9421-N1b-RESUME.md')"
put_row scripts/c12.sh HIMMEL-9421 alpha "$D12"
run hp claim --key $K2 --label beta --doc "$DB" --repo "$R" scripts/c12.sh
same "I3 ... unless that WRAPPED bullet hands off to the RESUME doc (the successor lives)" "$RC" 1
# a newer WRAPPED doc proves nothing about a RESUME doc it has no link to (the 24 h residual the chief accepted)
D13R="$(mkdoc HIMMEL-9422-N1b-RESUME.md '# resume doc')"
touch -d '1 hour ago' "$D13R"
D13="$(mkdoc HIMMEL-9422-N2-case.md '- 10:00 WRAPPED — PR merged')"
put_row scripts/c13.sh HIMMEL-9422 alpha "$D13"
run hp claim --key $K2 --label beta --doc "$DB" --repo "$R" scripts/c13.sh
same "I3 a different-leg newer WRAPPED doc with no mention of the RESUME doc holds (unchanged result, now because no link exists, not because of the leg)" "$RC" 1
D14R="$(mkdoc HIMMEL-9423-N1b-RESUME.md '# resume doc')"
touch -d '1 hour ago' "$D14R"
D14="$(mkdoc HIMMEL-9423-N2-case.md $'> **Prior art:** HIMMEL-9423-N1b-RESUME.md\n- 10:00 WRAPPED — PR merged')"
put_row scripts/c14.sh HIMMEL-9423 alpha "$D14"
run hp claim --key $K2 --label beta --doc "$DB" --repo "$R" scripts/c14.sh
same "I3 a different-leg WRAPPED doc naming the RESUME doc outside its last WRAPPED bullet consumes it" "$RC" 0
D15R="$(mkdoc HIMMEL-9424-case-RESUME.md '# resume doc')"
touch -d '1 hour ago' "$D15R"
D15="$(mkdoc HIMMEL-9424-case.md '- 10:00 WRAPPED — PR merged')"
put_row scripts/c15.sh HIMMEL-9424 alpha "$D15"
run hp claim --key $K2 --label beta --doc "$DB" --repo "$R" scripts/c15.sh
same "I3 a WRAPPED doc named as the RESUME doc minus -RESUME, with no mention of it, holds (changed: a shared stem is no link)" "$RC" 1
# a RESUME doc made AFTER its stem doc wrapped is new live work: the stem doc's WRAPPED bullet cannot have released it
D18="$(mkdoc HIMMEL-9427-case.md '- 10:00 WRAPPED — PR merged')"
touch -d '3 hours ago' "$D18"
mkdoc HIMMEL-9427-case-RESUME.md '# resume doc, made after the stem doc wrapped' > /dev/null
put_row scripts/c18.sh HIMMEL-9427 alpha "$D18"
run hp claim --key $K2 --label beta --doc "$DB" --repo "$R" scripts/c18.sh
same "I3 a RESUME doc created after its stem doc wrapped, the last WRAPPED bullet not naming it, holds" "$RC" 1
D16R="$(mkdoc HIMMEL-9425-N7f-RESUME.md '# resume doc')"
touch -d '1 hour ago' "$D16R"
D16="$(mkdoc HIMMEL-9425-N7c-case.md $'- 09:00 LIVE — HIMMEL-9425-N7f-RESUME.md\n- 10:00 WRAPPED — handed to HIMMEL-9425-N7f-RESUME.md')"
put_row scripts/c16.sh HIMMEL-9425 alpha "$D16"
run hp claim --key $K2 --label beta --doc "$DB" --repo "$R" scripts/c16.sh
same "I3 a same-leg WRAPPED doc whose last bullet names the RESUME doc still holds, a mention elsewhere too" "$RC" 1
# touching an old WRAPPED doc of the leg (a later edit bumps its mtime past the RESUME doc) must not release a live RESUME's rows
D17R="$(mkdoc HIMMEL-9426-N3b-RESUME.md '# resume doc')"
touch -d '1 hour ago' "$D17R"
D17="$(mkdoc HIMMEL-9426-N3-case.md '- 10:00 WRAPPED — PR merged')"
touch -d '3 hours ago' "$D17"
touch "$D17"
put_row scripts/c17.sh HIMMEL-9426 alpha "$D17"
run hp claim --key $K2 --label beta --doc "$DB" --repo "$R" scripts/c17.sh
same "I3 touching an old WRAPPED doc of the leg no longer releases a live RESUME doc's rows" "$RC" 1

mkdoc HIMMEL-9118-N1-RESUME.md '# resume doc' > /dev/null
touch -d '25 hours ago' "$HANDOVER_DIR/u/r/HIMMEL-9118-N1-RESUME.md"
put_row scripts/c08.sh HIMMEL-9118 alpha "$(mkdoc HIMMEL-9118-case.md)"
run hp claim --key $K2 --label beta --doc "$DB" --repo "$R" scripts/c08.sh
same "I3 a RESUME doc over 24 h no longer holds the rows (taken over)" "$RC" 0
# and the late launch is refused, naming the new holder
run hp seed --key HIMMEL-9118 --label alpha --doc "$(mkdoc HIMMEL-9118-seed.md '> **Writes:** scripts/c08.sh')" --repo "$R"
same "I3 the late launch is refused" "$RC" 1
contains "I3 the late launch names the new holder" "$ERR" "$K2"

mkdoc HIMMEL-9119-N1-RESUME.md '- 09:00 WRAPPED — done' > /dev/null
put_row scripts/c09.sh HIMMEL-9119 alpha "$(mkdoc HIMMEL-9119-case.md)"
run hp claim --key $K2 --label beta --doc "$DB" --repo "$R" scripts/c09.sh
same "I3 a WRAPPED RESUME doc holds nothing" "$RC" 0

# real queue-lock states: CORRUPT blocks, plain STALE blocks, STALE-DEAD passes, another host's token blocks
D10="$(mkdoc HIMMEL-9120-case.md)"
mkdir -p "$(lock_dir_of "$D10")"
put_row scripts/c10.sh HIMMEL-9120 alpha "$D10"
run hp claim --key $K2 --label beta --doc "$DB" --repo "$R" scripts/c10.sh
same "I4 a CORRUPT lock blocks" "$RC" 1

D11="$(mkdoc HIMMEL-9121-case.md)"
lock_hold "$D11" "sess-live-$$"
host="$(lock_host "$(lock_dir_of "$D11")")"
owner_set "$(lock_dir_of "$D11")" session "${host}-pid1"
put_row scripts/c11.sh HIMMEL-9121 alpha "$D11"
run env QUEUE_LOCK_TTL_SECONDS=0 python3 -I "$SUT" claim --key $K2 --label beta --doc "$DB" --repo "$R" scripts/c11.sh
same "I4 a plain STALE lock (death not proven) blocks" "$RC" 1

D12="$(mkdoc HIMMEL-9122-case.md)"
lock_hold "$D12" "sess-x"
sleep 0 & deadpid=$!
wait "$deadpid"
owner_set "$(lock_dir_of "$D12")" session "${host}-pid${deadpid}"
put_row scripts/c12.sh HIMMEL-9122 alpha "$D12"
run env QUEUE_LOCK_TTL_SECONDS=0 python3 -I "$SUT" claim --key $K2 --label beta --doc "$DB" --repo "$R" scripts/c12.sh
same "I4 a STALE-DEAD lock passes (taken over)" "$RC" 0

D13="$(mkdoc HIMMEL-9123-case.md)"
lock_hold "$D13" "sess-y"
owner_set "$(lock_dir_of "$D13")" host some-other-host
put_row scripts/c13.sh HIMMEL-9123 alpha "$D13"
run env QUEUE_LOCK_TTL_SECONDS=0 python3 -I "$SUT" claim --key $K2 --label beta --doc "$DB" --repo "$R" scripts/c13.sh
same "I4 another host's token (death not proven) blocks" "$RC" 1

# Review Focus 5: a merged PR's row is freed lazily
put_row scripts/c14.sh PR-88 branch:x "" pr 88
run env HOLDS_GH="$W/bin/gh-merged" python3 -I "$SUT" claim --key $K2 --label beta --doc "$DB" --repo "$R" scripts/c14.sh
same "RF5 a merged PR row is dead, claim passes" "$RC" 0

# ---- I11: parallel claims, parallel takers, refused seed
hp claim --key HIMMEL-9131 --label p1 --doc "$(mkdoc HIMMEL-9131-case.md)" --repo "$R" scripts/c20.sh > "$W/o1" 2> "$W/e1" &
p1=$!
hp claim --key HIMMEL-9132 --label p2 --doc "$(mkdoc HIMMEL-9132-case.md)" --repo "$R" scripts/c20.sh > "$W/o2" 2> "$W/e2" &
p2=$!
wait "$p1"; r1=$?
wait "$p2"; r2=$?
same "I11 2 claims on one path: one exit 0, one exit 1" "$(printf '%s%s' "$(( r1 < r2 ? r1 : r2 ))" "$(( r1 > r2 ? r1 : r2 ))")" 01
same "I11 2 claims on one path leave one row" "$(find "$(slugdir)" -name "$(esc scripts/c20.sh)*" | wc -l | tr -d ' ')" 1

put_row scripts/c21.sh HIMMEL-9133 alpha "$(mkdoc HIMMEL-9133-case.md)"
hp claim --key HIMMEL-9134 --label t1 --doc "$(mkdoc HIMMEL-9134-case.md)" --repo "$R" scripts/c21.sh > /dev/null 2>&1 &
p1=$!
hp claim --key HIMMEL-9135 --label t2 --doc "$(mkdoc HIMMEL-9135-case.md)" --repo "$R" scripts/c21.sh > /dev/null 2>&1 &
p2=$!
wait "$p1"; r1=$?
wait "$p2"; r2=$?
same "I11 2 takers of one dead row: one winner" "$(printf '%s%s' "$(( r1 < r2 ? r1 : r2 ))" "$(( r1 > r2 ? r1 : r2 ))")" 01
same "I11 2 takers leave one row, no leftover temp or moved file" "$(find "$(slugdir)" \( -name "*c21.sh*" -o -name '%00*' \) | wc -l | tr -d ' ')" 1

D22="$(mkdoc HIMMEL-9136-case.md)"
lock_hold "$D22"
put_row scripts/c22c.sh HIMMEL-9136 alpha "$D22"
DS="$(mkdoc HIMMEL-9137-case.md '> **Writes:** scripts/c22a.sh scripts/c22b.sh scripts/c22c.sh')"
run hp seed --key HIMMEL-9137 --label seeder --doc "$DS" --repo "$R"
same "I11 a seed refused on its third file exits 1" "$RC" 1
same "I11 a refused seed leaves no row (first file)" "$([ -e "$(rowf scripts/c22a.sh)" ] && echo row || echo none)" none
same "I11 a refused seed leaves no row (second file)" "$([ -e "$(rowf scripts/c22b.sh)" ] && echo row || echo none)" none

# seed with one file granted passes it; an ungranted file in the same seed is refused
D23="$(mkdoc HIMMEL-9138-case.md)"
lock_hold "$D23"
put_row scripts/c23x.sh HIMMEL-9138 alpha "$D23"
put_row scripts/c23z.sh HIMMEL-9138 alpha "$D23"
hp grant --key HIMMEL-9139 --repo "$R" scripts/c23x.sh > /dev/null 2>&1
DS2="$(mkdoc HIMMEL-9139-case.md '> **Writes:** scripts/c23x.sh scripts/c23y.sh')"
run hp seed --key HIMMEL-9139 --label seeder --doc "$DS2" --repo "$R"
same "I11 a seed passes a file granted to its key" "$RC" 0
same "I11 the seed row for the free file is published" "$(cut -f1,4 "$(rowf scripts/c23y.sh)" | tr '\t' ' ')" "HIMMEL-9139 brief"
DS3="$(mkdoc HIMMEL-9140-case.md '> **Writes:** scripts/c23x.sh scripts/c23w.sh scripts/c23z.sh')"
run hp seed --key HIMMEL-9140 --label seeder --doc "$DS3" --repo "$R"
same "I11 an ungranted file in the same seed is refused" "$RC" 1
same "I11 ... and its earlier row is rolled back" "$([ -e "$(rowf scripts/c23w.sh)" ] && echo row || echo none)" none

# ---- I5: every fault passes, one events.log line (stderr when the log itself cannot be written)
fault_case() {  # fault_case <name> <path> <env-prefix...> ; the row at <path> must already exist
    local name="$1" path="$2" before; shift 2
    before="$(ev_count)"
    run env "$@" python3 -I "$SUT" claim --key $K2 --label beta --doc "$DB" --repo "$R" "$path"
    same "I5 $name passes" "$RC" 0
    same "I5 $name leaves one events.log line" "$(( $(ev_count) - before ))" 1
}
put_row scripts/f2.sh HIMMEL-9150 alpha "$(mkdoc HIMMEL-9150-case.md)"
printf 'not a row\n' > "$(rowf scripts/f2.sh)"
touch -d '2 hours ago' "$(rowf scripts/f2.sh)"
fault_case "a corrupt row" scripts/f2.sh X=1
same "I5 the corrupt row is left in place" "$(cat "$(rowf scripts/f2.sh)")" "not a row"
put_row scripts/f3.sh HIMMEL-9151 alpha "$(mkdoc HIMMEL-9151-case.md)"
fault_case "a queue-lock that returns rc 1" scripts/f3.sh HOLDS_QUEUE_LOCK="$W/bin/ql-rc1"
same "I5 ... and the row stays the holder's" "$(cut -f1 "$(rowf scripts/f3.sh)")" HIMMEL-9151
put_row scripts/f4.sh HIMMEL-9152 alpha "$(mkdoc HIMMEL-9152-case.md)"
fault_case "a missing queue-lock.sh" scripts/f4.sh HOLDS_QUEUE_LOCK="$W/bin/no-such-queue-lock"
put_row scripts/f5.sh PR-99 branch:x "$(mkdoc HIMMEL-9153-case.md)" pr 99
t0=$(date +%s)
fault_case "a gh that hangs past 5 s" scripts/f5.sh HOLDS_GH="$W/bin/gh-hang"
t1=$(date +%s)
if [ $((t1 - t0)) -lt 15 ]; then pass "I5 the hung gh is cut off (took $((t1 - t0)) s)"; else fail "I5 the hung gh is cut off (took $((t1 - t0)) s)"; fi
put_row scripts/f6.sh HIMMEL-9154 alpha "$(mkdoc HIMMEL-9154-case.md)"
mkdir -p "$W/long"
long="scripts/$(printf 'a%.0s' $(seq 300)).sh"
before="$(ev_count)"
run hp claim --key $K2 --label beta --doc "$DB" --repo "$R" "$long"
same "RF4 a path of 300 bytes passes" "$RC" 0
same "RF4 ... and holds no row" "$(find "$(slugdir)" -name 'aaaa*' | wc -l | tr -d ' ')" 0
same "RF4 ... leaving one events.log line" "$(( $(ev_count) - before ))" 1

if [ "$(id -u)" != 0 ]; then
    chmod 000 "$REG"
    run hp claim --key $K2 --label beta --doc "$DB" --repo "$R" scripts/f7.sh
    chmod 755 "$REG"
    same "I5 an unreadable register passes" "$RC" 0
    if [ -n "$ERR" ]; then pass "I5 ... and says so on stderr (the log cannot be written)"; else fail "I5 ... and says so on stderr"; fi
    HOME_RO="$W/home-ro"
    mkdir -p "$HOME_RO/.himmel/state/holds"
    chmod 555 "$HOME_RO/.himmel/state/holds"
    run env HOME="$HOME_RO" python3 -I "$SUT" claim --key $K2 --label beta --doc "$DB" --repo "$R" scripts/f8.sh
    same "I5 a read-only register dir (disk full) passes" "$RC" 0
    if [ -n "$ERR" ]; then pass "I5 ... with a stderr line, since events.log cannot be written"; else fail "I5 ... with a stderr line"; fi
    chmod 755 "$HOME_RO/.himmel/state/holds"
else
    pass "I5 (root: unreadable-register rows skipped)"
fi

# off: the sentinel passes a claim of a held path
D30="$(mkdoc HIMMEL-9160-case.md)"
lock_hold "$D30"
put_row scripts/c30.sh HIMMEL-9160 alpha "$D30"
run hp off --reason "test fold"
same "off writes the sentinel" "$RC" 0
run hp claim --key $K2 --label beta --doc "$DB" --repo "$R" scripts/c30.sh
same "I5 with the sentinel on, a claim of a held path passes" "$RC" 0
run hp on
same "on removes the sentinel" "$RC" 0
run hp claim --key $K2 --label beta --doc "$DB" --repo "$R" scripts/c30.sh
same "with the sentinel off again, the held path is refused" "$RC" 1

# ---- I9: a worker (HIMMEL_CONSOLE_LEG=1) can neither grant nor switch the barrier off
run env HIMMEL_CONSOLE_LEG=1 python3 -I "$SUT" grant --key $K2 --repo "$R" scripts/c30.sh
same "I9 grant under HIMMEL_CONSOLE_LEG=1 exits 1" "$RC" 1
run env HIMMEL_CONSOLE_LEG=1 python3 -I "$SUT" off --reason sneaky
same "I9 off under HIMMEL_CONSOLE_LEG=1 exits 1" "$RC" 1
same "I9 ... and wrote no sentinel" "$([ -e "$REG/OFF" ] && echo OFF || echo none)" none
run env HIMMEL_CONSOLE_LEG=1 python3 -I "$SUT" on
same "I9 on under HIMMEL_CONSOLE_LEG=1 exits 1" "$RC" 1
run hp grant --key $K2 --repo "$R" .claude/settings.json
same "I9 a grant on .claude/settings.json exits 1" "$RC" 1
contains "I9 ... and says only the operator can" "$ERR" operator
contains "I9 ... and names waiting as an exit" "$ERR" "wait for its release"
contains "I9 ... and names the operator's bypass launch" "$ERR" "the operator launches with WRITE_HOLD_OK=1"
run hp grant --key $K2 --repo "$R" scripts/ci/suite-tiers.tsv
same "I9 a grant on a trust path exits 1" "$RC" 1
contains "I9 ... and names the chief's stamp" "$ERR" "--chief-doc"
contains "I9 ... and names waiting as an exit" "$ERR" "wait for its release"
contains "I9 ... and names the operator's bypass launch" "$ERR" "the operator launches with WRITE_HOLD_OK=1"
run hp grant --key $K2 --repo "$R" scripts/handover/chief-kit/holds-exempt.txt
same "I9 a grant on the exempt list (itself a trust path) exits 1" "$RC" 1

# ---- I10: an exempt file is never held; a file off the list always can be
D31="$(mkdoc HIMMEL-9161-case.md)"
lock_hold "$D31"
put_row scripts/ci/suite-tiers.tsv HIMMEL-9161 alpha "$D31"
rm -f "$(rowf scripts/ci/suite-tiers.tsv)"
run hp claim --key $K2 --label beta --doc "$DB" --repo "$R" scripts/ci/suite-tiers.tsv
same "I10 a claim on an exempt path exits 0" "$RC" 0
same "I10 ... and makes no row" "$([ -e "$(rowf scripts/ci/suite-tiers.tsv)" ] && echo row || echo none)" none
run hp claim --key HIMMEL-9161 --label alpha --doc "$D31" --repo "$R" scripts/c31.sh
run hp claim --key $K2 --label beta --doc "$DB" --repo "$R" scripts/c31.sh
same "I10 a file off the list can be held" "$RC" 1

# ---- parse
DP="$(mkdoc HIMMEL-9170-parse.md '# t
> **Writes:** scripts/p1.sh scripts/ptree/ (read only: docs/x.md) scripts/p2.py
> scripts/p3.sh
> **Writes note:** scripts/ignored.sh
> **Other:** scripts/not-writes.sh')"
want="$(printf 'file\tscripts/p1.sh\ntree\tscripts/ptree/\nfile\tscripts/p2.py\nfile\tscripts/p3.sh')"
run hp parse "$DP" --repo "$R"
same "parse: files, trees, parentheses removed, continuation line, Writes note ignored" "$OUT" "$want"
DN="$(mkdoc HIMMEL-9171-parse.md '> **Writes:** none named')"
run hp parse "$DN" --repo "$R"
same "parse: none named yields no lines" "$OUT" ""
DW="$(mkdoc HIMMEL-9172-parse.md '> **Writes note:** scripts/ignored.sh')"
run hp parse "$DW" --repo "$R"
same "parse: a Writes note line yields no lines" "$OUT" ""
mkdir -p "$R/scripts/real-dir"
DT="$(mkdoc HIMMEL-9173-parse.md '> **Writes:** scripts/real-dir scripts/newfile.sh')"
run hp parse "$DT" --repo "$R"
same "parse: an existing directory is a tree, an unwritten file a file" "$OUT" "$(printf 'tree\tscripts/real-dir/\nfile\tscripts/newfile.sh')"
run python3 -I -c "
import importlib.util, sys
s = importlib.util.spec_from_file_location('holds', '$SUT'); m = importlib.util.module_from_spec(s); s.loader.exec_module(m)
print(m.parse_text('> **Writes:** scripts/q1.sh', '$R'))"
same "parse_text is importable" "$OUT" "[('file', 'scripts/q1.sh')]"

# ---- read and release
DR="$(mkdoc HIMMEL-9180-case.md)"
put_row scripts/r1.sh HIMMEL-9180 lab "$DR"
put_row scripts/r2.sh HIMMEL-9180 lab "$DR"
put_row scripts/r3.sh HIMMEL-9180 lab "$DR"
put_row scripts/r4.sh HIMMEL-9181 other "$(mkdoc HIMMEL-9181-case.md)"
printf 'scripts/r1.sh\nscripts/r2.sh\nscripts/r3.sh\n' > "$W/paths"
: > "$W/ql-calls"
run env HOLDS_QUEUE_LOCK="$W/bin/ql-count" python3 -I "$SUT" read --repo "$R" --paths-from "$W/paths"
same "read --paths-from keeps only the listed paths" "$(printf '%s\n' "$OUT" | wc -l | tr -d ' ')" 3
same "read prints path key label source pr state" "$(printf '%s\n' "$OUT" | head -n 1)" "$(printf 'scripts/r1.sh\tHIMMEL-9180\tlab\tbrief\t\tdead')"
same "read judges a doc once for 3 of its rows" "$(wc -l < "$W/ql-calls" | tr -d ' ')" 1
run env HOLDS_QUEUE_LOCK="$W/bin/ql-rc1" python3 -I "$SUT" read --repo "$R" --paths-from "$W/paths"
contains "read: a failed proof reads state unknown, never free" "$OUT" "$(printf 'lab\tbrief\t\tunknown')"
run hp read --repo "$R" --keys
contains "read --keys lists every holder key, whatever the paths" "$OUT" HIMMEL-9181
run hp read --repo "$W/no-such-repo-register"
same "read: a repo with no register directory is empty, exit 0" "$RC:$OUT" "0:"
if [ "$(id -u)" != 0 ]; then
    chmod 000 "$(slugdir)"
    run hp read --repo "$R"
    chmod 755 "$(slugdir)"
    same "read: an unreadable register directory exits 3" "$RC" 3
fi

put_row scripts/rel1.sh HIMMEL-9182 lab "$DR"
hp claim --key HIMMEL-9182 --label lab --doc "$(mkdoc HIMMEL-9182-case.md)" --repo "$R" --source brief scripts/rel2.sh > /dev/null 2>&1
hp claim --key HIMMEL-9182 --label lab --doc "$(mkdoc HIMMEL-9182-case.md)" --repo "$R" --source claim scripts/rel3.sh > /dev/null 2>&1
printf 'HIMMEL-9182\tlab\t%s\tbrief\t\n' "$(mkdoc HIMMEL-9182-case.md)" > "$(rowf scripts/rel4.sh)"
run hp release --key HIMMEL-9182 --repo "$R" --doc "$(mkdoc HIMMEL-9182-case.md)"
same "release exits 0" "$RC" 0
same "release removes this doc's brief row" "$([ -e "$(rowf scripts/rel2.sh)" ] && echo row || echo none)" none
same "release removes the other brief row of this doc" "$([ -e "$(rowf scripts/rel4.sh)" ] && echo row || echo none)" none
same "release leaves this doc's claim row" "$([ -e "$(rowf scripts/rel3.sh)" ] && echo row || echo none)" row
same "release leaves another doc's brief row" "$([ -e "$(rowf scripts/rel1.sh)" ] && echo row || echo none)" row

# ---- Review Focus 4: spaces and % round-trip through read
run hp claim --key HIMMEL-9190 --label lab --doc "$(mkdoc HIMMEL-9190-case.md)" --repo "$R" 'scripts/a b%c.sh'
same "RF4 a path with a space and % is claimed" "$RC" 0
run hp read --repo "$R"
contains "RF4 ... and round-trips through read" "$OUT" "$(printf 'scripts/a b%%c.sh\tHIMMEL-9190')"

# ---- repo identity: a linked worktree and its primary share one row
git -C "$R" worktree add -q "$W/wt" -b wt-branch
run hp claim --key HIMMEL-9191 --label lab --doc "$(mkdoc HIMMEL-9191-case.md)" --repo "$W/wt" scripts/w1.sh
same "repo identity: claim from a linked worktree exits 0" "$RC" 0
same "repo identity: the row sits in the primary's directory" "$([ -e "$(rowf scripts/w1.sh)" ] && echo row || echo none)" row
run hp read --repo "$R" --paths-from <(printf 'scripts/w1.sh\n')
contains "repo identity: read from the primary shows the worktree's row" "$OUT" HIMMEL-9191
run hp claim --key HIMMEL-9192 --label lab --doc "$DB" --repo "$R" scripts/w1.sh
same "repo identity: the primary sees the same claim" "$RC" 1

# ---- an absolute path inside a linked worktree is the same row as its repo-relative spelling
run hp claim --key HIMMEL-9210 --label lab --doc "$(mkdoc HIMMEL-9210-case.md)" --repo "$W/wt" "$W/wt/scripts/a1.sh"
same "abs path in a worktree: the claim exits 0" "$RC" 0
same "abs path in a worktree: the row sits under the repo-relative name" "$([ -e "$(rowf scripts/a1.sh)" ] && echo row || echo none)" row
run hp claim --key HIMMEL-9211 --label lab --doc "$DB" --repo "$R" scripts/a1.sh
same "abs path in a worktree: the repo-relative claim by another key is refused" "$RC" 1

# ---- --repo naming a plain subdirectory of the checkout is not a worktree root
run hp claim --key HIMMEL-9215 --label lab --doc "$(mkdoc HIMMEL-9215-case.md)" --repo "$R/scripts" "$R/scripts/sub1.sh"
same "repo subdirectory: the claim exits 0" "$RC" 0
same "repo subdirectory: the row keeps its full repo-relative name" "$([ -e "$(rowf scripts/sub1.sh)" ] && echo row || echo none)" row

# ---- an absolute bucket path outside the repo: seeded, held against a rival, and released with the launch
ABSF="$W/h/u/r/specs/abs-case.md"
DAB1="$(mkdoc HIMMEL-9212-case.md "> **Writes:** $ABSF")"
DAB2="$(mkdoc HIMMEL-9213-case.md "> **Writes:** $ABSF")"
run hp seed --key HIMMEL-9212 --label lab --doc "$DAB1" --repo "$R"
same "abs bucket path: the first seed passes" "$RC" 0
run hp seed --key HIMMEL-9213 --label lab --doc "$DAB2" --repo "$R"
same "abs bucket path: a rival seed is refused" "$RC" 1
run hp release --key HIMMEL-9212 --repo "$R" --doc "$DAB1"
run hp seed --key HIMMEL-9213 --label lab --doc "$DAB2" --repo "$R"
same "abs bucket path: release frees the row, so the rival seed passes" "$RC" 0

# ---- a key that is not a ticket key is a usage error and makes no row
run hp claim --key not-a-key --label lab --doc "$DB" --repo "$R" scripts/k1.sh
same "bad key: claim exits 2" "$RC" 2
same "bad key: claim makes no row" "$([ -e "$(rowf scripts/k1.sh)" ] && echo row || echo none)" none
run hp seed --key not-a-key --label lab --doc "$DAB1" --repo "$R"
same "bad key: seed exits 2" "$RC" 2
run hp claim --key $'HIMMEL-9216\n' --label lab --doc "$DB" --repo "$R" scripts/k2.sh
same "bad key: a trailing newline is refused too" "$RC" 2

# ---- a real file whose name looks like a grant sibling is never held (it would read as a grant)
run hp claim --key HIMMEL-9214 --label lab --doc "$DB" --repo "$R" scripts/x6.sh.grant.HIMMEL-42
same "grant-looking name: the claim passes" "$RC" 0
same "grant-looking name: no row is made" "$([ -e "$(rowf scripts/x6.sh.grant.HIMMEL-42)" ] && echo row || echo none)" none

# ---- an unreadable part of the bucket is a fault (unknown), never read as "no successor doc"
if [ "$(id -u)" != 0 ]; then
    put_row scripts/f9.sh HIMMEL-9220 alpha "$(mkdoc HIMMEL-9220-case.md)"
    mkdir -p "$HANDOVER_DIR/u/r/locked9"
    chmod 000 "$HANDOVER_DIR/u/r/locked9"
    before="$(ev_count)"
    run hp claim --key $K2 --label beta --doc "$DB" --repo "$R" scripts/f9.sh
    chmod 755 "$HANDOVER_DIR/u/r/locked9"
    same "unreadable bucket subdir: the claim passes" "$RC" 0
    same "unreadable bucket subdir: the holder's row is not taken over" "$(cut -f1 "$(rowf scripts/f9.sh)")" HIMMEL-9220
    same "unreadable bucket subdir: one events.log line" "$(( $(ev_count) - before ))" 1
fi

# ---- F1: a crash is a fault (exit 2 and an events.log line), never a refusal (exit 1)
before="$(ev_count)"
run hp claim --key $K2 --label beta --doc "$DB" --repo "$R" $'scripts/\xff-crash.sh'  # a lone surrogate: name.encode('utf-8') raises
same "F1 a crash exits 2, never 1 (1 means refused)" "$RC" 2
same "F1 ... and leaves one events.log line" "$(( $(ev_count) - before ))" 1
contains "F1 ... a fault line" "$(tail -n 1 "$EVENTS")" fault
if [ -n "$ERR" ]; then pass "F1 ... and says so on stderr"; else fail "F1 ... and says so on stderr"; fi

# ---- finding 2: git failing for a linked worktree is a fault, never a second slug
mkdir -p "$W/gitfail"
printf '#!/usr/bin/env bash\nexit 128\n' > "$W/gitfail/git"
chmod +x "$W/gitfail/git"
before="$(ev_count)"
run env PATH="$W/gitfail:$PATH" python3 -I "$SUT" claim --key HIMMEL-9301 --label lab --doc "$DB" --repo "$W/wt" scripts/g1.sh
same "F2 claim, git failing, --repo a linked worktree: fault, exit 2" "$RC" 2
same "F2 ... no row under the worktree's own slug" "$([ -e "$(rowf scripts/g1.sh "$W/wt")" ] && echo row || echo none)" none
same "F2 ... one events.log line" "$(( $(ev_count) - before ))" 1
run env PATH="$W/gitfail:$PATH" python3 -I "$SUT" read --repo "$W/wt"
same "F2 read, git failing, a linked worktree: exit 2, not an empty register" "$RC" 2
run env PATH="$W/gitfail:$PATH" python3 -I "$SUT" alive --repo "$W/wt" scripts/w1.sh
same "F2 alive, git failing, a linked worktree: exit 2, not dead" "$RC:$OUT" "2:"
run env PATH="$W/gitfail:$PATH" python3 -I "$SUT" claim --key HIMMEL-9302 --label lab --doc "$DB" --repo "$R" scripts/g2.sh
same "F2 git failing, --repo the primary checkout: the path as given is its identity, exit 0" "$RC" 0
same "F2 ... the row sits in the primary's directory" "$([ -e "$(rowf scripts/g2.sh)" ] && echo row || echo none)" row

# ---- findings 3 and 4: a rename alias is folded before the trust test, and an empty registry folds nothing
R2="$W/repo2"
mkdir -p "$R2/scripts/lib" "$R2/scripts/ci"
printf 'scripts/oldci\tscripts/ci\tdirectory\tfail\tx\tx\nscripts/oldx\tscripts/newx\tdirectory\tfail\tx\tx\n' > "$R2/scripts/lib/rename-aliases.tsv"
echo seed > "$R2/seed.txt"
git -C "$R2" init -q -b main || exit 1
git -C "$R2" add -A || exit 1
git -C "$R2" commit -q -m base || exit 1
run hp grant --key $K2 --repo "$R2" scripts/oldci/suite-tiers.tsv
same "F3 a grant on a trust path spelt by its old directory name exits 1" "$RC" 1
same "F3 ... and writes no grant" "$(find "$(slugdir "$R2")" -name '*.grant.*' 2>/dev/null | wc -l | tr -d ' ')" 0
run hp grant --key $K2 --repo "$R2" scripts/oldx/a.sh
same "F4 a grant on an aliased non-trust path exits 0" "$RC" 0
same "F4 ... and sits under the new spelling" "$([ -e "$(rowf scripts/newx/a.sh "$R2").grant.$K2" ] && echo grant || echo none)" grant
run hp claim --key HIMMEL-9303 --label lab --doc "$DB" --repo "$R2" scripts/oldx/b.sh
same "F4 a claim by the old spelling exits 0" "$RC" 0
same "F4 ... and the row sits under the new spelling" "$([ -e "$(rowf scripts/newx/b.sh "$R2")" ] && echo row || echo none)" row
run hp claim --key HIMMEL-9304 --label lab --doc "$DB" --repo "$R2" scripts/newx/b.sh
same "F4 the new spelling is the same file: refused" "$RC" 1
run hp claim --key HIMMEL-9303 --label lab --doc "$DB" --repo "$R" scripts/oldx/b.sh
same "F4 an empty registry: the claim exits 0" "$RC" 0
same "F4 ... and the path stays as written" "$([ -e "$(rowf scripts/oldx/b.sh)" ] && echo row || echo none)" row
run hp claim --key HIMMEL-9304 --label lab --doc "$DB" --repo "$R" scripts/newx/b.sh
same "F4 an empty registry: the new spelling is another file" "$RC" 0

# ---- finding 5: a path is normalised before it is matched against the repo
run hp claim --key HIMMEL-9310 --label lab --doc "$DB" --repo "$R" "$R/scripts/../../esc1.sh"
same "F5 a path that climbs out of the repo is not read as inside it" "$([ -e "$(rowf ../esc1.sh)" ] && echo row || echo none)" none
same "F5 ... it is an absolute path, under _abs" "$([ -e "$REG/_abs/$(esc "$W/esc1.sh")" ] && echo row || echo none)" row
run hp claim --key HIMMEL-9311 --label lab --doc "$DB" --repo "$R" "$R/../repo/scripts/esc2.sh"
same "F5 a path that leaves and re-enters the repo is inside it" "$([ -e "$(rowf scripts/esc2.sh)" ] && echo row || echo none)" row

# ---- finding 6: a doc that cannot be found, or a root that cannot be resolved, is put to the lock or reads unknown
run bash -c 'cd "$1" && shift && exec python3 -I "$@"' _ "$HANDOVER_DIR/u/r" "$SUT" claim --key HIMMEL-9320 --label lab --doc HIMMEL-9320-rel.md --repo "$R" scripts/m0.sh
same "F6 --doc is made absolute" "$(cut -f3 "$(rowf scripts/m0.sh)")" "$HANDOVER_DIR/u/r/HIMMEL-9320-rel.md"
GONE="$HANDOVER_DIR/u/r/HIMMEL-9321-gone.md"
put_row scripts/m1.sh HIMMEL-9321 alpha "$GONE"
: > "$W/ql-calls"
run env HOLDS_QUEUE_LOCK="$W/bin/ql-count" python3 -I "$SUT" claim --key $K2 --label beta --doc "$DB" --repo "$R" scripts/m1.sh
same "F6 a doc that is gone is still put to the lock (one sweep serves it)" "$(grep -cxF -- 'status --sweep' "$W/ql-calls")" 1
NOB="$W/nobucket/HIMMEL-9322-case.md"
put_row scripts/m2.sh HIMMEL-9322 alpha "$NOB"
: > "$W/ql-calls"
run env HOLDS_QUEUE_LOCK="$W/bin/ql-count" python3 -I "$SUT" claim --key $K2 --label beta --doc "$DB" --repo "$R" scripts/m2.sh
same "F6 a doc whose bucket is gone is still put to the lock (one sweep serves it)" "$(grep -cxF -- 'status --sweep' "$W/ql-calls")" 1
GL="$(mkdoc HIMMEL-9324-case.md)"
lock_hold "$GL"
rm -f "$GL"
put_row scripts/m4.sh HIMMEL-9324 alpha "$GL"
run hp claim --key $K2 --label beta --doc "$DB" --repo "$R" scripts/m4.sh
same "F6 a doc that is gone, its lock still held: alive, refused" "$RC" 1
GR="$(mkdoc HIMMEL-9323-case.md)"
put_row scripts/m3.sh HIMMEL-9323 alpha "$GR"
mkdir -p "$W/nogit"
: > "$W/ql-free-calls"
before="$(ev_count)"
run bash -c 'cd "$1" && ql="$2" && shift 2 && exec env -u HANDOVER_DIR HOLDS_QUEUE_LOCK="$ql" python3 -I "$@"' _ "$W/nogit" "$W/bin/ql-free" "$SUT" claim --key $K2 --label beta --doc "$DB" --repo "$R" scripts/m3.sh
same "F6 a handover root that cannot be resolved passes (a fault)" "$RC" 0
same "F6 ... the holder's row is not taken over" "$(cut -f1 "$(rowf scripts/m3.sh)")" HIMMEL-9323
same "F6 ... one events.log line" "$(( $(ev_count) - before ))" 1
same "F6 ... and the lock was asked (one sweep)" "$(grep -cxF -- 'status --sweep' "$W/ql-free-calls")" 1

# ---- F6b: a gone RESUME-named doc with a free lock is dead, not unknown
GRS="$HANDOVER_DIR/u/r/HIMMEL-9340-N1-RESUME.md"
put_row scripts/rs1.sh HIMMEL-9340 alpha "$GRS"
before="$(ev_count)"
run hp claim --key $K2 --label beta --doc "$DB" --repo "$R" scripts/rs1.sh
same "F6 a gone RESUME-named doc, lock free: the claim exits 0" "$RC" 0
same "F6 ... the holder is dead, the claim takes over" "$(cut -f1 "$(rowf scripts/rs1.sh)")" "$K2"
same "F6 ... as a takeover, not a fault" "$(tail -n +$((before + 1)) "$EVENTS" | cut -f2 | tr '\n' ' ')" "takeover "
run hp alive --repo "$R" scripts/rs1.sh
same "F6 ... and alive says the row is the taker's, never unknown" "$OUT" alive

# ---- F1b: argument parsing is inside the fault path too
mkdir -p "$W/gonecwd"
before="$(ev_count)"
run bash -c 'mkdir -p "$1" && cd "$1" && rmdir "$1" && shift && exec python3 -I "$@"' _ "$W/gonecwd" "$SUT" claim --key $K2 --label beta --doc rel.md --repo "$R" scripts/gc1.sh
same "F1 a removed cwd with a relative --doc exits 2, never 1" "$RC" 2
same "F1 ... and leaves one events.log line" "$(( $(ev_count) - before ))" 1

# ---- finding 7: read --keys does not drop a row it cannot read
R4="$W/repo4"
mkdir -p "$R4"
git -C "$R4" init -q -b main || exit 1
run hp claim --key HIMMEL-9330 --label lab --doc "$DB" --repo "$R4" scripts/z1.sh
run hp read --repo "$R4" --keys
same "F7 read --keys over readable rows exits 0" "$RC" 0
printf 'not a row\n' > "$(rowf scripts/z2.sh "$R4")"
printf 'HIMMEL-9331\tlab\t%s\tbogus-source\t\n' "$DB" > "$(rowf scripts/z3.sh "$R4")"
printf 'HIMMEL-9332\tlab\t\377\tbrief\t\n' > "$(rowf scripts/z5.sh "$R4")"
touch -d '2 hours ago' "$(rowf scripts/z2.sh "$R4")" "$(rowf scripts/z3.sh "$R4")" "$(rowf scripts/z5.sh "$R4")"
run hp read --repo "$R4" --keys
same "F7 read --keys with unreadable rows still exits 0 (one junk row must not fault the whole read)" "$RC" 0
contains "F7 ... names the rows on stderr" "$ERR" scripts/z2.sh
contains "F7 ... a row with a recoverable key reads that key unknown, never free" "$OUT" "$(printf 'HIMMEL-9331\tunknown\t1')"
contains "F7 ... invalid UTF-8 after the key still reads that key unknown" "$OUT" "$(printf 'HIMMEL-9332\tunknown\t1')"
contains "F7 ... a row with no recoverable key reads ? unknown" "$OUT" "$(printf '?\tunknown\t1')"
contains "F7 ... and still lists the readable holder" "$OUT" HIMMEL-9330
rm -f "$(rowf scripts/z3.sh "$R4")"
printf 'HIMMEL-9330\tlab\t%s\tbogus-source\t\n' "$DB" > "$(rowf scripts/z4.sh "$R4")"
run hp read --repo "$R4" --keys
contains "F7 an unreadable row never frees its key: alive stays alive, the count includes the junk row" "$OUT" "$(printf 'HIMMEL-9330\talive\t2')"

# ---- F6c: a RESUME-named doc that cannot be read is a fault (unknown), never a dead holder
if [ "$(id -u)" != 0 ]; then
    GU="$(mkdoc HIMMEL-9350-N1-RESUME.md '# resume doc')"
    chmod 000 "$GU"
    put_row scripts/rs2.sh HIMMEL-9350 alpha "$GU"
    before="$(ev_count)"
    run hp claim --key $K2 --label beta --doc "$DB" --repo "$R" scripts/rs2.sh
    chmod 644 "$GU"
    same "F6c an unreadable RESUME doc under 24 h, lock free: the claim passes (a fault)" "$RC" 0
    same "F6c ... the holder's row is left in place" "$(cut -f1 "$(rowf scripts/rs2.sh)")" HIMMEL-9350
    same "F6c ... one events.log line, a fault" "$(tail -n +$((before + 1)) "$EVENTS" | cut -f2 | tr '\n' ' ')" "fault "
fi

# ---- F7b: a junk row of a key makes that key unknown even when its readable row is dead
R5="$W/repo5"
mkdir -p "$R5"
git -C "$R5" init -q -b main || exit 1
mkdir -p "$(slugdir "$R5")"
printf 'HIMMEL-9351\tlab\t%s\tbrief\t\n' "$(mkdoc HIMMEL-9351-case.md)" > "$(rowf scripts/a1.sh "$R5")"
printf 'HIMMEL-9351\tlab\t%s\tbogus-source\t\n' "$DB" > "$(rowf scripts/b1.sh "$R5")"
touch -d '2 hours ago' "$(rowf scripts/a1.sh "$R5")" "$(rowf scripts/b1.sh "$R5")"
run hp read --repo "$R5" --keys
same "F7b read --keys: a dead row then a junk row of the same key reads that key unknown, never dead" "$(printf '%s\n' "$OUT" | grep '^HIMMEL-9351')" "$(printf 'HIMMEL-9351\tunknown\t2')"

# ---- Task 2: seed exit 3 on a claim fault, fallback doc, repoint, deadline, backfill
mkdir -p "$(slugdir)"
printf 'not a row\n' > "$(rowf scripts/t2bad.sh)"
DT1="$(mkdoc HIMMEL-9401-case.md '> **Writes:** scripts/t2bad.sh scripts/t2ok.sh')"
run hp seed --key HIMMEL-9401 --label seeder --doc "$DT1" --repo "$R"
same "T2 seed: a claim fault exits 3" "$RC" 3
same "T2 seed: the rows made before and after the fault are kept" "$(cut -f1 "$(rowf scripts/t2ok.sh)")" HIMMEL-9401

DT2P="$(mkdoc HIMMEL-9402-N1-case.md '> **Writes:** scripts/t2fb.sh')"
touch -d '1 hour ago' "$DT2P"
DT2="$(mkdoc HIMMEL-9402-N1b-case-RESUME.md '# resume doc, no Writes line')"
run hp seed --key HIMMEL-9402 --label N1b --doc "$DT2" --repo "$R"
same "T2 seed: a doc with no Writes line falls back to the newest doc of the key that has one (exit 0)" "$RC" 0
same "T2 seed: the fallback row carries the new doc and label" "$(cut -f1,2,3 "$(rowf scripts/t2fb.sh)" | tr '\t' ' ')" "HIMMEL-9402 N1b $DT2"
DT3="$(mkdoc HIMMEL-9403-case-RESUME.md '# resume doc, nothing anywhere')"
run hp seed --key HIMMEL-9403 --label N3 --doc "$DT3" --repo "$R"
same "T2 seed: no Writes anywhere exits 0" "$RC" 0
same "T2 seed: ... and makes no row" "$(grep -rlF "$DT3" "$(slugdir)" 2>/dev/null | wc -l | tr -d ' ')" 0
# the fallback is for a RESUME doc only; a plain brief with no Writes line seeds nothing of its predecessor's
DT4P="$(mkdoc HIMMEL-9406-N1-case.md '> **Writes:** scripts/t2fb2.sh')"
touch -d '1 hour ago' "$DT4P"
DT4="$(mkdoc HIMMEL-9406-N2-case.md '# plain brief, no Writes line')"
run hp seed --key HIMMEL-9406 --label N2 --doc "$DT4" --repo "$R"
same "T2 seed: a non-RESUME doc with no Writes line does not inherit the predecessor's files: exit 0, no row" "$RC|$([ -e "$(rowf scripts/t2fb2.sh)" ] && echo row || echo none)" "0|none"

put_row scripts/t2rp1.sh HIMMEL-9404 oldlabel "$HANDOVER_DIR/u/r/HIMMEL-9404-old.md"
put_row scripts/t2rp2.sh HIMMEL-9404 oldlabel "$HANDOVER_DIR/u/r/HIMMEL-9404-old.md"
put_row scripts/t2rp3.sh HIMMEL-9405 other "$HANDOVER_DIR/u/r/HIMMEL-9405-old.md"
other_before="$(cat "$(rowf scripts/t2rp3.sh)")"
run hp repoint --key HIMMEL-9404 --label newlabel --doc "$HANDOVER_DIR/u/r/HIMMEL-9404-new-RESUME.md" --repo "$R"
same "T2 repoint exits 0" "$RC" 0
same "T2 repoint: the key's first row has the new doc and label" "$(cut -f2,3 "$(rowf scripts/t2rp1.sh)" | tr '\t' ' ')" "newlabel $HANDOVER_DIR/u/r/HIMMEL-9404-new-RESUME.md"
same "T2 repoint: the key's second row too" "$(cut -f2 "$(rowf scripts/t2rp2.sh)")" newlabel
same "T2 repoint: another key's row is left alone" "$(cat "$(rowf scripts/t2rp3.sh)")" "$other_before"

put_row scripts/t2rp4.sh HIMMEL-9409 oldlabel "$HANDOVER_DIR/u/r/HIMMEL-9409-old.md"
rp4="$(rowf scripts/t2rp4.sh)"; rp4_before="$(cat "$rp4")"
run python3 -I -c "
import importlib.util, os
s = importlib.util.spec_from_file_location('holds', '$SUT'); m = importlib.util.module_from_spec(s); s.loader.exec_module(m)
def boom(d, name, text): raise OSError(28, 'No space left on device')
m.publish = boom
print(m.repoint_row(os.path.dirname('$rp4'), os.path.basename('$rp4'), 'HIMMEL-9409', 'newlabel', 'new.md'))
"
same "T2 repoint: a failed write reports a fault" "$OUT" fault
same "T2 repoint: ... and the original row is still there" "$(cat "$rp4" 2>/dev/null)" "$rp4_before"

# the race: a contender claims while repoint has the row renamed aside. It must not take the absent path.
put_row scripts/t2rp5.sh HIMMEL-9410 oldlabel "$HANDOVER_DIR/u/r/HIMMEL-9410-old.md"
rp5="$(rowf scripts/t2rp5.sh)"
run python3 -I -c "
import importlib.util, os
s = importlib.util.spec_from_file_location('holds', '$SUT'); m = importlib.util.module_from_spec(s); s.loader.exec_module(m)
m.LOCK_WAIT = 0.2
real, seen = os.rename, []
def racing(a, b):
    real(a, b)
    seen.append(m.claim_one('$R', None, 'scripts/t2rp5.sh', '$K2', 'beta', 'b.md', 'manual', ''))
os.rename = racing
print(m.repoint_row(os.path.dirname('$rp5'), os.path.basename('$rp5'), 'HIMMEL-9410', 'newlabel', 'new.md'), seen[0])
"
same "T2 repoint: a contender during the rename gets a fault, not the row" "$OUT" "repointed fault"
same "T2 repoint: ... and the key keeps its hold, repointed" "$(cut -f1,2 "$rp5" | tr '\t' ' ')" "HIMMEL-9410 newlabel"
same "T2 repoint: the lock leaves no file in the directory" "$(find "$(dirname "$rp5")" -name '%00*' | wc -l | tr -d ' ')" 0

DT4="$(mkdoc HIMMEL-9406-case.md '> **Writes:** scripts/t2fr.sh scripts/t2h1.sh scripts/t2h2.sh')"
put_row scripts/t2h1.sh HIMMEL-9407 holder1 "$(mkdoc HIMMEL-9407-case.md)"
put_row scripts/t2h2.sh HIMMEL-9408 holder2 "$(mkdoc HIMMEL-9408-case.md)"
printf '#!/usr/bin/env bash\necho call >> "%s/ql-hang-calls"\nexec sleep 30\n' "$W" > "$W/bin/ql-hang-count"; chmod 755 "$W/bin/ql-hang-count"
t0="$(date +%s)"
HOLDS_QUEUE_LOCK="$W/bin/ql-hang-count" run hp seed --key HIMMEL-9406 --label slow --doc "$DT4" --repo "$R" --deadline "$((t0 + 2))"
t1="$(date +%s)"
same "T2 seed: a hanging queue-lock stub passes the deadline, exit 3" "$RC" 3
same "T2 seed: ... inside 20 s (the deadline bounds the stub call)" "$([ "$((t1 - t0))" -lt 20 ] && echo yes || echo no)" yes
contains "T2 seed: ... and it is the between-claims check that stopped it" "$ERR" "deadline passed before"
same "T2 seed: ... after exactly one stub call" "$(wc -l < "$W/ql-hang-calls" | tr -d ' ')" 1
same "T2 seed: ... the row made before the deadline is kept" "$(cut -f1 "$(rowf scripts/t2fr.sh)")" HIMMEL-9406

# a holder with 10 docs and a hung lock script: the deadline is a ceiling for the whole row, not 15 s a doc
for i in 1 2 3 4 5 6 7 8 9 10; do mkdoc "HIMMEL-9430-N$i-case.md" '# doc' > /dev/null; done
touch -d '2 hours ago' "$HANDOVER_DIR"/u/r/HIMMEL-9430-N*-case.md
put_row scripts/t2ten.sh HIMMEL-9430 ten "$HANDOVER_DIR/u/r/HIMMEL-9430-N1-case.md"
touch -d '2 hours ago' "$(rowf scripts/t2ten.sh)"
: > "$W/ql-hang-calls"
DT10="$(mkdoc HIMMEL-9431-case.md '> **Writes:** scripts/t2ten.sh')"
t0="$(date +%s)"
HOLDS_QUEUE_LOCK="$W/bin/ql-hang-count" run hp seed --key HIMMEL-9431 --label ten --doc "$DT10" --repo "$R" --deadline "$((t0 + 1))"
t1="$(date +%s)"
same "T2 seed: a holder with 10 docs and a hung lock script ends inside 20 s" "$([ "$((t1 - t0))" -lt 20 ] && echo yes || echo no)" yes
same "T2 seed: ... with at most one stub call (past the deadline nothing is spawned)" "$([ "$(wc -l < "$W/ql-hang-calls" | tr -d ' ')" -le 1 ] && echo yes || echo no)" yes

# a deadline that passes inside the LAST claim (or the last repointed row) is still a passed deadline: exit 3
R2="$W/repo-last-row"; mkdir -p "$R2"; git -C "$R2" init -q -b main  # its own register: exactly one row, so only the check after the last row can fire
mkdir -p "$(slugdir "$R2")"
printf '%s\t%s\t%s\t%s\t%s\n' HIMMEL-9413 slowrp "$HANDOVER_DIR/u/r/HIMMEL-9413-old.md" brief '' > "$(rowf scripts/t2dl.sh "$R2")"
run python3 -I -c "
import importlib.util, time, argparse
s = importlib.util.spec_from_file_location('holds', '$SUT'); m = importlib.util.module_from_spec(s); s.loader.exec_module(m)
def slow_claim(*a, **k): time.sleep(1.2); return 'ok'
m.claim_one = slow_claim
print(m.seed_rows('$R', m.Judge('$R'), 'HIMMEL-9414', 'N1', 'd.md', '> **Writes:** scripts/t2last.sh', time.time() + 1)[0])
real_rp = m.repoint_row
def slow_rp(*a, **k): time.sleep(1.2); return real_rp(*a, **k)
m.repoint_row = slow_rp
print(m.op_repoint(argparse.Namespace(key='HIMMEL-9413', label='n', doc='d.md', repo='$R2', deadline=time.time() + 1)))
"
same "T2 seed and repoint: a deadline passed inside the last claim or row exits 3" "$OUT" "$(printf '3\n3')"

# repoint on 3 rows with a deadline that passes inside the first: it stops between rows, the later rows keep their old label
R3="$W/repo-three-rows"; mkdir -p "$R3"; git -C "$R3" init -q -b main
mkdir -p "$(slugdir "$R3")"
for f in a b c; do printf '%s\t%s\t%s\t%s\t%s\n' HIMMEL-9415 oldlab "$HANDOVER_DIR/u/r/HIMMEL-9415-old.md" brief '' > "$(rowf scripts/t2m$f.sh "$R3")"; done
run python3 -I -c "
import importlib.util, time, argparse
s = importlib.util.spec_from_file_location('holds', '$SUT'); m = importlib.util.module_from_spec(s); s.loader.exec_module(m)
real_rp = m.repoint_row
def slow_rp(*a, **k): time.sleep(1.2); return real_rp(*a, **k)
m.repoint_row = slow_rp
print(m.op_repoint(argparse.Namespace(key='HIMMEL-9415', label='newlab', doc='d.md', repo='$R3', deadline=time.time() + 1)))
"
same "T2 repoint: a deadline passed between rows exits 3" "$OUT" 3
same "T2 repoint: ... by the between-rows check, not the one after the last row" "$ERR" "holds: the repoint deadline passed"
same "T2 repoint: ... the first row is repointed, the later rows keep their label" "$(cut -f2 "$(rowf scripts/t2ma.sh "$R3")")|$(cut -f2 "$(rowf scripts/t2mb.sh "$R3")")|$(cut -f2 "$(rowf scripts/t2mc.sh "$R3")")" "newlab|oldlab|oldlab"

BM="$W/fleet.json"
BA="$(mkdoc HIMMEL-9410-N1-case.md '> **Writes:** scripts/t2ba.sh')"
BB="$(mkdoc HIMMEL-9411-N2-case.md "$(printf '> **Writes:** scripts/t2bb.sh\n\n## Results\n- 10:00 WRAPPED — done')")"
BC="$(mkdoc HIMMEL-9412-N3-case.md '> **Writes:** scripts/t2ba.sh')"
printf '{"schema":1,"workers":[{"doc":"%s","label":"N1"},{"doc":"%s","label":"N2"},{"doc":"%s","label":"N3"}]}\n' "$BA" "$BB" "$BC" > "$BM"
run hp backfill --manifest "$BM" --repo "$R"
same "T2 backfill: an overlap is reported, not fatal (exit 0)" "$RC" 0
contains "T2 backfill: the overlap is named" "$OUT" "N3 overlap"
same "T2 backfill: a non-WRAPPED worker gets its row with its label" "$(cut -f1,2 "$(rowf scripts/t2ba.sh)" | tr '\t' ' ')" "HIMMEL-9410 N1"
same "T2 backfill: a WRAPPED worker gets none" "$([ -e "$(rowf scripts/t2bb.sh)" ] && echo row || echo none)" none
lock_hold "$BA"
touch -d '2 hours ago' "$(rowf scripts/t2ba.sh)"
run hp alive --repo "$R" scripts/t2ba.sh
same "T2 backfill: a row past the grace with the worker's lock held reads alive" "$OUT" alive

# ---- merged PR first, sidecars, _abs keys, directory lines, sync-prs, gc, one lock sweep
G3M="$(mkdoc HIMMEL-9500-N1-case-RESUME.md '# resume doc, unwrapped, fresh')"
put_row scripts/t3m.sh HIMMEL-9500 alpha "$G3M" pr 4999
run env HOLDS_GH="$W/bin/gh-merged" python3 -I "$SUT" alive --repo "$R" scripts/t3m.sh
same "T3 a row whose own PR reads merged is dead, though a RESUME doc of its key is fresh" "$OUT" dead
put_row scripts/t3o.sh HIMMEL-9500 alpha "$G3M" pr 4999
run env HOLDS_GH="$W/bin/gh-open" python3 -I "$SUT" alive --repo "$R" scripts/t3o.sh
same "T3 ... a row whose PR is open stays alive" "$OUT" alive

mkdoc 'HIMMEL-9501-N1-case-RESUME.md.worker-preface.md' '# sidecar' > /dev/null
mkdoc 'HIMMEL-9501-N1-case-RESUME.md.worker-contract.md' '# sidecar' > /dev/null
put_row scripts/t3s.sh HIMMEL-9501 alpha "$HANDOVER_DIR/u/r/HIMMEL-9501-N1-case.md"
run hp alive --repo "$R" scripts/t3s.sh
same "T3 a .worker-preface.md / .worker-contract.md sidecar is never read as the key's RESUME doc" "$OUT" dead

AB3="$HANDOVER_DIR/u/r/specs/t3abs.md"
DAB3="$(mkdoc HIMMEL-9502-case.md "> **Writes:** $AB3")"
hp seed --key HIMMEL-9502 --label lab --doc "$DAB3" --repo "$R" > /dev/null 2>&1
run hp read --repo "$R" --keys
contains "T3 read --keys also walks _abs: a key holding only a bucket file is listed" "$OUT" "$(printf 'HIMMEL-9502\talive\t1')"
run hp read --repo "$W/no-such-repo-register" --keys
same "T3 read --keys with no repo directory: exit 0, and no repo row listed (_abs is shared by every repo)" "$RC:$(printf '%s\n' "$OUT" | grep -c '^HIMMEL-9351')" "0:0"

put_row scripts/t3tree/a.sh HIMMEL-9503 lab "$(mkdoc HIMMEL-9503-case.md)"
put_row scripts/t3tree/sub/b.sh HIMMEL-9503 lab "$(mkdoc HIMMEL-9503-case.md)"
put_row scripts/t3tree-other/c.sh HIMMEL-9503 lab "$(mkdoc HIMMEL-9503-case.md)"
printf 'scripts/t3tree/\n' > "$W/paths-tree"
run hp read --repo "$R" --paths-from "$W/paths-tree"
same "T3 a --paths-from line ending in / selects the rows under it (and not a sibling dir with the same prefix)" "$(printf '%s\n' "$OUT" | cut -f1 | sort | paste -sd, -)" "scripts/t3tree/a.sh,scripts/t3tree/sub/b.sh"

printf '5050\tfeat/himmel-9504-x\tfeat(x): [HIMMEL-9504] t\tscripts/t3pr.sh\n5050\tfeat/himmel-9504-x\tfeat(x): [HIMMEL-9504] t\tscripts/t3pr-live.sh\n' > "$W/pr-files.tsv"
put_row scripts/t3pr-live.sh HIMMEL-9599 other "$(mkdoc HIMMEL-9599-case.md)"
touch "$(rowf scripts/t3pr-live.sh)"
run env HOLDS_GH="$W/bin/gh-open" python3 -I "$SUT" sync-prs --repo "$R" --files-from "$W/pr-files.tsv"
same "T3 sync-prs exits 0" "$RC" 0
same "T3 sync-prs writes a pr row: key from the title, label branch:<head>, source pr, the PR number" "$(cut -f1,2,4,5 "$(rowf scripts/t3pr.sh)" | tr '\t' ' ')" "HIMMEL-9504 branch:feat/himmel-9504-x pr 5050"
same "T3 sync-prs leaves a file that has a live row alone" "$(cut -f1 "$(rowf scripts/t3pr-live.sh)")" HIMMEL-9599
printf '5051\tfeat/no-key\tno key in the title\tscripts/t3pr2.sh\n' > "$W/pr-files2.tsv"
run env HOLDS_GH="$W/bin/gh-open" python3 -I "$SUT" sync-prs --repo "$R" --files-from "$W/pr-files2.tsv"
same "T3 sync-prs: a title with no key uses PR-<n>" "$(cut -f1 "$(rowf scripts/t3pr2.sh)")" "PR-5051"

DHA="$(mkdoc "$K1-hold-a.md")"
lock_hold "$DHA"
put_row scripts/tdup.sh $K1 alpha "$DHA"
printf '5065\tfeat/no-key\tno key in the title\tscripts/tdup.sh\n' > "$W/pr-files-dup.tsv"
dup_denies() { grep -c "	deny	scripts/tdup.sh	PR-5065	$1\$" "$EVENTS" || true; }
run env HOLDS_GH="$W/bin/gh-open" python3 -I "$SUT" sync-prs --repo "$R" --files-from "$W/pr-files-dup.tsv"
same "sync-prs over a file a live row holds logs the deny" "$(dup_denies $K1)" 1
run env HOLDS_GH="$W/bin/gh-open" python3 -I "$SUT" sync-prs --repo "$R" --files-from "$W/pr-files-dup.tsv"
same "a second sync-prs over the same held file and the same holder logs no second deny" "$(dup_denies $K1)" 1
DHB="$(mkdoc "$K2-hold-b.md")"
lock_hold "$DHB"
put_row scripts/tdup.sh $K2 alpha "$DHB"
run env HOLDS_GH="$W/bin/gh-open" python3 -I "$SUT" sync-prs --repo "$R" --files-from "$W/pr-files-dup.tsv"
same "a changed holder on the same file is logged again" "$(dup_denies $K2)" 1
rm -f "$(rowf scripts/tdup.sh)"
run env HOLDS_GH="$W/bin/gh-open" python3 -I "$SUT" sync-prs --repo "$R" --files-from "$W/pr-files-dup.tsv"
put_row scripts/tdup.sh $K2 alpha "$DHB"
run env HOLDS_GH="$W/bin/gh-open" python3 -I "$SUT" sync-prs --repo "$R" --files-from "$W/pr-files-dup.tsv"
same "a deny that stopped and came back is logged again" "$(dup_denies $K2)" 2

put_row scripts/t3gc1.sh HIMMEL-9505 lab "$(mkdoc HIMMEL-9505-case.md)"
: > "$(rowf scripts/t3gc1.sh).grant.HIMMEL-9598"
put_row scripts/t3gc2.sh HIMMEL-9506 lab "$(mkdoc HIMMEL-9506-case.md)"
touch "$(rowf scripts/t3gc2.sh)"
run hp gc --repo "$R"
same "T3 gc exits 0" "$RC" 0
same "T3 gc removes a dead row" "$([ -e "$(rowf scripts/t3gc1.sh)" ] && echo row || echo none)" none
same "T3 gc removes a dead key's grant sibling" "$([ -e "$(rowf scripts/t3gc1.sh).grant.HIMMEL-9598" ] && echo grant || echo none)" none
same "T3 gc keeps an alive row" "$([ -e "$(rowf scripts/t3gc2.sh)" ] && echo row || echo none)" row

cat > "$W/bin/ql-sweep" <<STUB
#!/usr/bin/env bash
echo "\$*" >> "$W/ql-sweep-calls"
case "\$*" in "status --sweep"*) echo "slug=u__r__HIMMEL-9507-case session=s host=h age=1s status=OK"; exit 0 ;; esac
exit 1
STUB
chmod +x "$W/bin/ql-sweep"
D3A="$(mkdoc HIMMEL-9507-case.md)"; D3B="$(mkdoc HIMMEL-9508-case.md)"
put_row scripts/t3w1.sh HIMMEL-9507 lab "$D3A"
put_row scripts/t3w2.sh HIMMEL-9507 lab "$D3A"
put_row scripts/t3w3.sh HIMMEL-9508 lab "$D3B"
printf 'scripts/t3w1.sh\nscripts/t3w2.sh\nscripts/t3w3.sh\n' > "$W/paths-sweep"
: > "$W/ql-sweep-calls"
run env HOLDS_QUEUE_LOCK="$W/bin/ql-sweep" python3 -I "$SUT" read --repo "$R" --paths-from "$W/paths-sweep"
same "T3 one queue-lock status --sweep serves every doc of the read" "$(wc -l < "$W/ql-sweep-calls" | tr -d ' '):$(head -n 1 "$W/ql-sweep-calls")" "1:status --sweep"
same "T3 a doc whose lock slug the sweep lists reads alive" "$(printf '%s\n' "$OUT" | grep 't3w1.sh' | cut -f6)" alive
same "T3 a doc the sweep lists no lock for reads dead" "$(printf '%s\n' "$OUT" | grep 't3w3.sh' | cut -f6)" dead
printf '#!/usr/bin/env bash\necho "a record in a format this reader does not know"\nexit 0\n' > "$W/bin/ql-garbled"
chmod +x "$W/bin/ql-garbled"
run env HOLDS_QUEUE_LOCK="$W/bin/ql-garbled" python3 -I "$SUT" read --repo "$R" --paths-from "$W/paths-sweep"
same "T3 a sweep line it cannot parse makes the lock unknown, not free" "$(printf '%s\n' "$OUT" | grep 't3w3.sh' | cut -f6)" unknown
printf '#!/usr/bin/env bash\necho "sweep: no held locks"\nexit 0\n' > "$W/bin/ql-none"
chmod +x "$W/bin/ql-none"
run env HOLDS_QUEUE_LOCK="$W/bin/ql-none" python3 -I "$SUT" read --repo "$R" --paths-from "$W/paths-sweep"
same "T3 a sweep that says no held locks leaves every doc free, so its rows read dead" "$(printf '%s\n' "$OUT" | grep 't3w3.sh' | cut -f6)" dead

# a row freshened after it was judged dead is live again: remove_dead keeps it when the mtime it was judged at has moved
put_row scripts/t3gc3.sh HIMMEL-9507 lab "$(mkdoc HIMMEL-9507-case.md)"
run python3 -I -c 'import importlib.util, os, sys
spec = importlib.util.spec_from_file_location("holds", sys.argv[1]); h = importlib.util.module_from_spec(spec); spec.loader.exec_module(h)
d, n = os.path.split(sys.argv[2]); st, f = h.read_row(sys.argv[2])
print(h.remove_dead(d, n, f, os.path.getmtime(sys.argv[2]) - 100))' "$SUT" "$(rowf scripts/t3gc3.sh)"
same "T3 gc keeps a row whose mtime moved since it was judged dead" "$OUT:$([ -e "$(rowf scripts/t3gc3.sh)" ] && echo row || echo none)" "False:row"

# ---- grant routes: the chief grants a trust-path hold from its own locked doc; the operator grants any path at a terminal
# tty_run <typed answer> <cmd...>: run cmd on a pseudo-terminal (stdin and stderr a TTY, CLAUDECODE unset) and type the
# answer when it asks for the path; OUT is what it printed, RC its exit code. The Claude Code markers (CLAUDECODE,
# CLAUDE_CODE_*) are stripped, as in an operator's own terminal
tty_run() {
    OUT=$(env -u CLAUDECODE python3 -I -c '
import os, pty, sys
pid, fd = pty.fork()
if pid == 0:
    os.execvpe(sys.argv[2], sys.argv[2:], {k: v for k, v in os.environ.items() if not (k == "CLAUDECODE" or k.startswith("CLAUDE_CODE_"))})
out, sent = b"", False
while True:
    try:
        b = os.read(fd, 4096)
    except OSError:
        break
    if not b:
        break
    out += b
    if not sent and b"type the path" in out.lower():
        os.write(fd, sys.argv[1].encode() + b"\n")
        sent = True
st = os.waitpid(pid, 0)[1]
sys.stdout.write(out.decode("utf-8", "replace"))
sys.exit(os.waitstatus_to_exitcode(st))' "$@")
    RC=$?
}
grantf() { printf '%s.grant.%s' "$(rowf "$1")" "$2"; }
# chief_lock <doc> <claude session id> [<lock token>]: hold doc's lock from Claude session <id> (its transcript is the
# lock's liveness marker); me_session <id>: make <id> the Claude session of this suite's process, an ancestor of every call
chief_lock() {
    mkdir -p "$CLAUDE_CONFIG_DIR/projects/p"
    : > "$CLAUDE_CONFIG_DIR/projects/p/$2.jsonl"
    CLAUDE_CODE_SESSION_ID="$2" bash "$QL" acquire "$1" "${3:-sess-$(basename "$1")}" > /dev/null 2>&1
}
me_session() { mkdir -p "$CLAUDE_CONFIG_DIR/sessions"; printf '{"pid":%d,"sessionId":"%s"}\n' "$$" "$1" > "$CLAUDE_CONFIG_DIR/sessions/$$.json"; }
# noclaude <cmd...>: run cmd with the Claude Code markers stripped
noclaude() { python3 -I -c 'import os, sys; os.execvpe(sys.argv[1], sys.argv[1:], {k: v for k, v in os.environ.items() if not (k == "CLAUDECODE" or k.startswith("CLAUDE_CODE_"))})' "$@"; }
me_session sid-chief
DCH="$(mkdoc HIMMEL-9218-chief.md)"
chief_lock "$DCH" sid-chief chief-sess-9218
run hp grant --key HIMMEL-9201 --repo "$R" --chief-doc "$DCH" scripts/check-ci.sh
same "C1 a chief holding its own doc's lock grants a trust path" "$RC" 0
same "C1 ... the grant file says grantor=chief and the chief's session" "$(cut -f3,4 "$(grantf scripts/check-ci.sh HIMMEL-9201)" 2>/dev/null)" "$(printf 'chief\tchief-sess-9218')"
contains "C1 ... and events.log records the grantor and session" "$(tail -n 1 "$EVENTS")" "grantor=chief session=chief-sess-9218"
run env HIMMEL_CONSOLE_DOC="$DCH" python3 -I "$SUT" grant --key HIMMEL-9202 --repo "$R" scripts/check-ci.sh
same "C2 the chief doc defaults to HIMMEL_CONSOLE_DOC, the chief session's own doc" "$RC" 0
DCX="$(mkdoc HIMMEL-9218-other-chief.md)"
lock_hold "$DCX" other-chief-sess
run env HIMMEL_CONSOLE_DOC="$DCH" python3 -I "$SUT" grant --key HIMMEL-9213 --repo "$R" --chief-doc "$DCX" scripts/check-ci.sh
same "C2 a chief session naming another chief's locked doc: refused" "$RC" 1
same "C2 ... and writes no grant" "$([ -e "$(grantf scripts/check-ci.sh HIMMEL-9213)" ] && echo grant || echo none)" none
run hp grant --key HIMMEL-9203 --repo "$R" --chief-doc "$(mkdoc HIMMEL-9218-free-chief.md)" scripts/check-ci.sh
same "C3 a chief doc whose lock is not held: refused" "$RC" 1
same "C3 ... and writes no grant" "$([ -e "$(grantf scripts/check-ci.sh HIMMEL-9203)" ] && echo grant || echo none)" none
DCO="$(mkdoc HIMMEL-9218-otherhost-chief.md)"
chief_lock "$DCO" sid-chief
owner_set "$(lock_dir_of "$DCO")" host elsewhere.invalid
run hp grant --key HIMMEL-9204 --repo "$R" --chief-doc "$DCO" scripts/check-ci.sh
same "C3 a chief doc locked on another host: refused" "$RC" 1
DCS="$(mkdoc HIMMEL-9218-stale-chief.md)"
lock_hold "$DCS"
owner_set "$(lock_dir_of "$DCS")" heartbeat 2020-01-01T00:00:00Z
run hp grant --key HIMMEL-9214 --repo "$R" --chief-doc "$DCS" scripts/check-ci.sh
same "C3 a chief doc whose lock is STALE: refused" "$RC" 1
contains "C3 ... because the lock is not held fresh" "$ERR" "status rc 12"
DCU="$(mkdoc HIMMEL-9218-garbled-chief.md)"
chief_lock "$DCU" sid-chief
owner_set "$(lock_dir_of "$DCU")" heartbeat not-a-time
bash "$QL" status "$DCU" > /dev/null 2>&1
same "C3 control: queue-lock reads an unparsable heartbeat as FRESH" "$?" 11
run hp grant --key HIMMEL-9215 --repo "$R" --chief-doc "$DCU" scripts/check-ci.sh
same "C3 a chief lock with an unparsable heartbeat: refused for a grant" "$RC" 1
contains "C3 ... the refusal names the heartbeat" "$ERR" "unparsable heartbeat"
DCW="$(mkdoc HIMMEL-9218-N9-worker-2026-11-05.md)"
chief_lock "$DCW" sid-chief
run hp grant --key HIMMEL-9216 --repo "$R" --chief-doc "$DCW" scripts/check-ci.sh
same "C8 a worker naming its own held worker doc: refused" "$RC" 1
contains "C8 ... because it is not a chief doc" "$ERR" "is not a chief doc"
DCA="$(mkdoc HIMMEL-9218-another-chief.md)"
chief_lock "$DCA" sid-another
run hp grant --key HIMMEL-9217 --repo "$R" --chief-doc "$DCA" scripts/check-ci.sh
same "C8 a caller whose ancestry lacks the lock's holder session: refused" "$RC" 1
contains "C8 ... the refusal says the holder is not this caller" "$ERR" "not this caller"
# a Claude session nested under the chief (a subagent, a nested claude): its own session file is nearer than the chief's
run bash -c 'f="$CLAUDE_CONFIG_DIR/sessions/$$.json"; printf "{\"pid\":%d,\"sessionId\":\"sid-nested\"}\n" "$$" > "$f"; python3 -I "$1" grant --key HIMMEL-9218 --repo "$2" --chief-doc "$3" scripts/check-ci.sh; rc=$?; rm -f "$f"; exit "$rc"' _ "$SUT" "$R" "$DCH"
same "C8 a Claude session nested under the chief, naming the chief's held doc: refused" "$RC" 1
contains "C8 ... the refusal says the holder is not this caller" "$ERR" "not this caller"
DCN="$(mkdoc HIMMEL-9218-nolive-chief.md)"
lock_hold "$DCN"
run hp grant --key HIMMEL-9219 --repo "$R" --chief-doc "$DCN" scripts/check-ci.sh
same "C8 a chief lock with no holder session marker: refused" "$RC" 1
same "C8 ... and none of these writes a grant" "$(find "$(slugdir)" -name '*.grant.HIMMEL-921[4-9]' | wc -l | tr -d ' ')" 0
run hp grant --key HIMMEL-9205 --repo "$R" scripts/check-ci.sh
same "C4 a trust path with no chief doc and no terminal: refused" "$RC" 1
contains "C4 ... the refusal prints the chief's command" "$ERR" "--chief-doc"
run env CLAUDECODE=1 python3 -I "$SUT" grant --key HIMMEL-9205 --repo "$R" scripts/check-ci.sh </dev/null
same "C4 a ! line (no terminal, CLAUDECODE set) is refused on the operator route" "$RC" 1
contains "C4 ... the refusal says a ! line is no operator terminal" "$ERR" "not a ! line in a Claude window"
contains "C4 ... and sends the operator in a Claude window to the chief" "$ERR" "the operator asks the chief, who stamps the grant"
same "C4 ... and writes no grant" "$([ -e "$(grantf scripts/check-ci.sh HIMMEL-9205)" ] && echo grant || echo none)" none
run env HIMMEL_CONSOLE_LEG=1 python3 -I "$SUT" grant --key HIMMEL-9206 --repo "$R" --chief-doc "$DCH" scripts/check-ci.sh
same "C5 a worker session naming a held chief doc is still refused" "$RC" 1
run hp grant --key HIMMEL-9207 --repo "$R" --chief-doc "$DCH" .claude/settings.json
same "C6 the chief cannot grant a settings path" "$RC" 1
contains "C6 ... the refusal says the operator grants it at a terminal" "$ERR" "operator"
run hp grant --key HIMMEL-9207 --repo "$R" --chief-doc "$DCH" .github/workflows/ci.yml
same "C6 the chief cannot grant a .github/ path" "$RC" 1
same "C6 ... and writes no grant" "$(find "$(slugdir)" -name '*.grant.HIMMEL-9207' | wc -l | tr -d ' ')" 0
same "C7 grant-route: a trust path is the chief's" "$(hp grant-route --repo "$R" scripts/check-ci.sh)" chief
same "C7 grant-route: a settings path is the operator's" "$(hp grant-route --repo "$R" .claude/settings.json)" operator
same "C7 grant-route: any other path is any" "$(hp grant-route --repo "$R" scripts/c01.sh)" any
tty_run scripts/check-ci.sh python3 -I "$SUT" grant --key HIMMEL-9208 --repo "$R" scripts/check-ci.sh
same "O1 the operator at a terminal who types the path back grants a trust path" "$RC" 0
same "O1 ... the grant file says grantor=operator" "$(cut -f3 "$(grantf scripts/check-ci.sh HIMMEL-9208)" 2>/dev/null)" operator
contains "O1 ... and events.log records it" "$(tail -n 1 "$EVENTS")" "grantor=operator"
tty_run .claude/settings.json python3 -I "$SUT" grant --key HIMMEL-9209 --repo "$R" .claude/settings.json
same "O2 the operator at a terminal grants a settings path" "$RC" 0
same "O2 ... recorded grantor=operator" "$(cut -f3 "$(grantf .claude/settings.json HIMMEL-9209)" 2>/dev/null)" operator
tty_run scripts/other.sh python3 -I "$SUT" grant --key HIMMEL-9210 --repo "$R" scripts/check-ci.sh
same "O3 a wrong path typed back: refused" "$RC" 1
same "O3 ... and writes no grant" "$([ -e "$(grantf scripts/check-ci.sh HIMMEL-9210)" ] && echo grant || echo none)" none
tty_run scripts/check-ci.sh env CLAUDECODE=1 python3 -I "$SUT" grant --key HIMMEL-9211 --repo "$R" scripts/check-ci.sh
same "O4 a terminal inside a Claude Code session (CLAUDECODE set) is no operator: refused" "$RC" 1
tty_run scripts/check-ci.sh env HIMMEL_CONSOLE_LEG=1 python3 -I "$SUT" grant --key HIMMEL-9212 --repo "$R" scripts/check-ci.sh
same "O5 a worker session at a terminal is refused" "$RC" 1
tty_run scripts/check-ci.sh env CLAUDE_CODE_ENTRYPOINT=cli python3 -I "$SUT" grant --key HIMMEL-9220 --repo "$R" scripts/check-ci.sh
same "O6 a terminal carrying a CLAUDE_CODE_* marker is no operator: refused" "$RC" 1
OUT=$(printf 'scripts/check-ci.sh\n' | noclaude python3 -I "$SUT" grant --key HIMMEL-9221 --repo "$R" scripts/check-ci.sh 2>&1); RC=$?
same "O7 a non-TTY stdin typing the right path, markers unset: refused" "$RC" 1
same "O7 ... and none of these writes a grant" "$(find "$(slugdir)" -name '*.grant.HIMMEL-922[01]' | wc -l | tr -d ' ')" 0

# ---- the register stays true on its own: on seeds, gc drops Done keys, summary and asks feed the tick
# (a) `on` runs backfill for the chief's fleet manifest: workers launched while the barrier was off get rows
R9="$W/repo-9186"; mkdir -p "$R9"; git -C "$R9" init -q -b main
S1="$(mkdoc HIMMEL-9601-N1-case.md '> **Writes:** scripts/s9601.sh')"
S2="$(mkdoc HIMMEL-9602-N2-case.md '> **Writes:** scripts/s9602.sh')"
printf '{"schema":1,"workers":[{"doc":"%s","label":"N1"},{"doc":"%s","label":"N2"}]}\n' "$S1" "$S2" > "$W/fleet-9186.json"
run hp off --reason "9186 seeding"
same "9186 off writes the sentinel" "$RC" 0
run hp on --workers-from "$W/fleet-9186.json" --repo "$R9"
same "9186 on with a manifest exits 0" "$RC" 0
run hp read --repo "$R9" --keys
contains "9186 after off then on, the first manifest worker's key has rows" "$OUT" "HIMMEL-9601"
contains "9186 after off then on, the second manifest worker's key has rows" "$OUT" "HIMMEL-9602"
run hp on
same "9186 on with no manifest is the plain sentinel removal (exit 0)" "$RC" 0

# (b) gc drops brief and pr rows of a Done key or a merged PR, and keeps those of an open one (control)
mkdir -p "$W/mirror9186"
printf -- '---\nkey: "HIMMEL-9611"\nstatus: "Done"\nstatusCategory: "Done"\n---\n' > "$W/mirror9186/HIMMEL-9611.md"
printf -- '---\nkey: "HIMMEL-9613"\nstatus: "In Progress"\nstatusCategory: "In Progress"\n---\n' > "$W/mirror9186/HIMMEL-9613.md"
cat > "$W/bin/gh-bynum" <<'STUB'
#!/usr/bin/env bash
case "$3" in 4701) echo MERGED ;; *) echo OPEN ;; esac
STUB
chmod +x "$W/bin/gh-bynum"
G1="$(mkdoc HIMMEL-9611-case.md)"; lock_hold "$G1"   # the Done key's worker still holds its lock: alive to the judge
G2="$(mkdoc HIMMEL-9612-case.md)"
G3="$(mkdoc HIMMEL-9613-case.md)"
put_row scripts/g9611.sh HIMMEL-9611 lab "$G1" brief "" "$R9"
put_row scripts/g9612.sh HIMMEL-9612 lab "$G2" pr 4701 "$R9"
put_row scripts/g9613.sh HIMMEL-9613 lab "$G3" pr 4702 "$R9"
: > "$(rowf scripts/g9611.sh "$R9").grant.HIMMEL-9699"
run env HOLDS_GH="$W/bin/gh-bynum" HOLDS_MIRROR="$W/mirror9186" python3 -I "$SUT" gc --repo "$R9"
same "9186 gc exits 0" "$RC" 0
same "9186 gc removes the brief row of a key the mirror says is Done, though its worker's lock is held" "$([ -e "$(rowf scripts/g9611.sh "$R9")" ] && echo row || echo none)" none
same "9186 gc removes the grant siblings of that key's row" "$([ -e "$(rowf scripts/g9611.sh "$R9").grant.HIMMEL-9699" ] && echo grant || echo none)" none
same "9186 gc removes the pr row whose PR reads merged" "$([ -e "$(rowf scripts/g9612.sh "$R9")" ] && echo row || echo none)" none
same "9186 gc keeps the row of an open PR on an in-progress key (control)" "$([ -e "$(rowf scripts/g9613.sh "$R9")" ] && echo row || echo none)" row

# (c) summary: live workers with no rows / stale rows / pending trust-path asks, from local state only
R10="$W/repo-9186-summary"; mkdir -p "$R10/scripts/lib"; git -C "$R10" init -q -b main
: > "$R10/scripts/lib/rename-aliases.tsv"
L1="$(mkdoc HIMMEL-9621-N1-case.md '> **Writes:** scripts/s9621.sh')"      # live, has Writes, no rows
L2="$(mkdoc HIMMEL-9622-N2-case.md '# a doc with no Writes line')"          # live, nothing to hold: not counted
put_row scripts/s9623.sh HIMMEL-9611 lab "$G1" brief "" "$R10"             # a stale row (Done key)
put_row scripts/s9624.sh HIMMEL-9613 lab "$G3" pr 4702 "$R10"               # a pr row whose PR is still open
put_row scripts/check-ci.sh HIMMEL-9625 holder "$(mkdoc HIMMEL-9625-case.md)" brief "" "$R10"
lock_hold "$(mkdoc HIMMEL-9625-case.md)"
run hp claim --key HIMMEL-9626 --label asker --doc "$(mkdoc HIMMEL-9626-case.md)" --repo "$R10" scripts/check-ci.sh
same "9186 a claim on a held trust path is refused (the deny the ask is read from)" "$RC" 1
OUT=$(printf '%s\n%s\n' "$L1" "$L2" | env HOLDS_MIRROR="$W/mirror9186" python3 -I "$SUT" summary --repo "$R10" --live-docs - --open-prs '#4702' 2>/dev/null)
same "9186 summary: one live worker with no rows, one stale row, one pending trust-path ask" "$OUT" "1/1/1"
run env HOLDS_MIRROR="$W/mirror9186" python3 -I "$SUT" asks --repo "$R10"
KIT_P="$(git -C "$HERE" rev-parse --path-format=absolute --git-common-dir)"; KIT_P="${KIT_P%/.git}"  # the checkout holds.py runs from, not the repo --repo names (R10 has no kit)
same "9186 asks names the key, the path and the full paste-ready grant command, located from the running kit" "$OUT" "$(printf 'HIMMEL-9626\tscripts/check-ci.sh\tHIMMEL-9625\tpython3 -I %s/scripts/handover/chief-kit/holds.py grant --key HIMMEL-9626 --repo %s scripts/check-ci.sh' "$KIT_P" "$R10")"
OUT=$(printf '%s\n' "$L1" | env HOLDS_MIRROR="$W/mirror9186" python3 -I "$SUT" summary --repo "$R10" --live-docs - --open-prs none 2>/dev/null)
same "9186 summary: with no open PR the pr row is stale too (2), no other count moves" "$OUT" "1/2/1"
: > "$(rowf scripts/check-ci.sh "$R10").grant.HIMMEL-9626"
run env HOLDS_MIRROR="$W/mirror9186" python3 -I "$SUT" asks --repo "$R10"
same "9186 a granted ask is no longer pending" "$OUT" ""
run hp summary --repo "$W/repo-9186-no-register"
same "9186 summary prints nothing when this repo has never had a register directory" "$RC:$OUT" "0:"
if [ "$(id -u)" != 0 ]; then  # root reads a mode-000 directory
    chmod 000 "$(slugdir "$R10")"
    run hp summary --repo "$R10"
    chmod 755 "$(slugdir "$R10")"
    same "9186 summary on an unreadable register directory exits 3 with no count (the tick shows hreg=?)" "$RC:$OUT" "3:"
fi

# the refusal text names the route that exists
put_row scripts/r9186.sh HIMMEL-9628 lab "$(mkdoc HIMMEL-9628-case.md)" brief "" "$R9"
touch "$(rowf scripts/r9186.sh "$R9")"
run hp claim --key HIMMEL-9627 --label asker --doc "$(mkdoc HIMMEL-9627-case.md)" --repo "$R9" scripts/r9186.sh
case "$ERR" in *"ask your chief: HOLD-ASK"*) fail "9186 the refusal no longer names the HOLD-ASK route that has no consumer" ;; *) pass "9186 the refusal no longer names the HOLD-ASK route that has no consumer" ;; esac
same "8725 the path off every list routes any" "$(hp grant-route --repo "$R9" scripts/r9186.sh)" any
contains "8725 route any: the refusal sends a HOLD-ASK" "$ERR" "Message your chief: HOLD-ASK scripts/r9186.sh HIMMEL-9627"
case "$ERR" in *WRITE_HOLD_OK*) fail "8725 route any: the refusal does not name the bypass" ;; *) pass "8725 route any: the refusal does not name the bypass" ;; esac
# refused_text <path> <asker key>: a live rival's row on the path, then that asker's claim; $ERR is the refusal
refused_text() {
    local rival=HIMMEL-9628
    put_row "$1" "$rival" lab "$(mkdoc "$rival-case.md")" brief "" "$R9"
    touch "$(rowf "$1" "$R9")"
    run hp claim --key "$2" --label asker --doc "$(mkdoc "$2-case.md")" --repo "$R9" "$1"
}
same "8725 scripts/check-ci.sh routes chief" "$(hp grant-route --repo "$R9" scripts/check-ci.sh)" chief
refused_text scripts/check-ci.sh HIMMEL-9626
same "8725 route chief: the claim is refused" "$RC" 1
contains "9186 the refusal tells the worker the chief sees the deny on its tick and grants it" "$ERR" "hreg="
contains "8725 route chief: the refusal names the chief's stamp" "$ERR" "can stamp a grant with --chief-doc"
contains "8725 route chief: the refusal names waiting and the bypass launch" "$ERR" "Otherwise wait for its release, or the operator launches with WRITE_HOLD_OK=1"
case "$ERR" in *HOLD-ASK*) fail "8725 route chief: the refusal sends no HOLD-ASK" ;; *) pass "8725 route chief: the refusal sends no HOLD-ASK" ;; esac
same "8725 a CI workflow routes operator" "$(hp grant-route --repo "$R9" .github/workflows/x.yml)" operator
refused_text .github/workflows/x.yml HIMMEL-9625
same "8725 route operator: the claim is refused" "$RC" 1
contains "8725 route operator: only the operator grants" "$ERR" "only the operator grants it"
contains "8725 route operator: the refusal names waiting and the bypass launch" "$ERR" "Otherwise wait for its release, or the operator launches with WRITE_HOLD_OK=1"
case "$ERR" in *--chief-doc*|*HOLD-ASK*) fail "8725 route operator: the refusal names no chief stamp and no HOLD-ASK" ;; *) pass "8725 route operator: the refusal names no chief stamp and no HOLD-ASK" ;; esac
# copy_claim <list content for printf %b, or - for no list> <path> <asker key>: the same claim, by a holds.py copy beside that
# list. Every caller reads rc 1 as a deny and passes on rc 2, so a bad list must leave the deny a deny.
copy_claim() {
    local d="$W/trust-$3" rival=HIMMEL-9628
    mkdir -p "$d/scripts/handover/chief-kit" "$d/scripts/ci"
    cp "$SUT" "$d/scripts/handover/chief-kit/holds.py"
    if [ "$1" != - ]; then printf '%b' "$1" > "$d/scripts/ci/ci-trust-paths.txt"; fi
    put_row "$2" "$rival" lab "$(mkdoc "$rival-case.md")" brief "" "$R9"
    touch "$(rowf "$2" "$R9")"
    run python3 -I "$d/scripts/handover/chief-kit/holds.py" claim --key "$3" --label asker --doc "$(mkdoc "$3-case.md")" --repo "$R9" "$2"
}
copy_claim '^scripts/tl-good\\.sh$\n' scripts/tl-good.sh HIMMEL-9624
same "8725 control: a copy beside a good list is refused" "$RC" 1
contains "8725 control: the copy reads its own list, the path routes chief" "$ERR" "can stamp a grant with --chief-doc"
copy_claim '*bad\n' scripts/tl-invalid.sh HIMMEL-9623
same "8725 an invalid pattern in the list: the claim is still refused" "$RC" 1
contains "8725 an invalid pattern in the list: the refusal is a holds: line" "$ERR" "holds: scripts/tl-invalid.sh is held by"
copy_claim '\0377\n' scripts/tl-bytes.sh HIMMEL-9622
same "8725 a non-UTF-8 byte in the list: the claim is still refused" "$RC" 1
contains "8725 a non-UTF-8 byte in the list: the refusal is a holds: line" "$ERR" "holds: scripts/tl-bytes.sh is held by"
copy_claim - scripts/tl-missing.sh HIMMEL-9621
same "8725 no list: the claim is still refused" "$RC" 1
contains "8725 no list: the refusal is a holds: line" "$ERR" "holds: scripts/tl-missing.sh is held by"
copy_claim - .github/workflows/tl-missing.yml HIMMEL-9620
same "8725 no list, a CI workflow: the claim is still refused" "$RC" 1
contains "8725 no list, a CI workflow: it still routes operator" "$ERR" "only the operator grants it"
copy_claim '*bad\n' .github/workflows/tl-invalid.yml HIMMEL-9619
same "8725 an invalid list, a CI workflow: the claim is still refused" "$RC" 1
contains "8725 an invalid list, a CI workflow: it still routes operator" "$ERR" "only the operator grants it"
run python3 -I "$W/trust-HIMMEL-9623/scripts/handover/chief-kit/holds.py" grant --key HIMMEL-9623 --repo "$R9" scripts/tl-invalid.sh
same "8725 an invalid list: a grant still refuses" "$RC" 2
same "8725 an invalid list: a grant writes nothing" "$(find "$(slugdir "$R9")" -name '*.grant.HIMMEL-9623' | wc -l | tr -d ' ')" 0

# ---- 8725 Task 5: git-check --staged and --push read git's own file lists (I2, I7, I12)
# A real repo with an origin and linked worktrees; the commit and push hooks are the real entries of .pre-commit-config.yaml,
# so `git commit -a` and `git commit <path>` run the check against git's temporary index.
CFG="$HERE/../../../.pre-commit-config.yaml"
cat > "$W/entry.py" <<'PY'
import re, sys
lines = open(sys.argv[1], encoding='utf-8').read().split('\n')
want = re.compile(r'\s*- id: ' + re.escape(sys.argv[2]) + r'\s*$')
i = next((n for n, l in enumerate(lines) if want.match(l)), None)
if i is None:
    sys.exit(1)
for j in range(i + 1, len(lines)):
    if re.match(r'\s*- id: ', lines[j]):
        sys.exit(1)
    m = re.match(r'(\s*)entry:\s*(>-|\|-?)?\s*(.*)$', lines[j])
    if not m:
        continue
    if not m.group(2):
        print(m.group(3))
        sys.exit(0)
    body = []
    for l in lines[j + 1:]:
        if l.strip() and len(l) - len(l.lstrip()) <= len(m.group(1)):
            break
        body.append(l.strip())
    print(' '.join(body))
    sys.exit(0)
sys.exit(1)
PY
ENTRY_C="$(python3 -I "$W/entry.py" "$CFG" write-hold-commit)"
ENTRY_P="$(python3 -I "$W/entry.py" "$CFG" write-hold-push)"
same "T5 the config has a write-hold-commit entry" "$([ -n "$ENTRY_C" ] && echo yes || echo no)" yes
same "T5 the config has a write-hold-push entry" "$([ -n "$ENTRY_P" ] && echo yes || echo no)" yes

GC="$W/gc" GCO="$W/gc-origin.git"
git init -q --bare "$GCO"
git init -q -b main "$GC"
git -C "$GC" remote add origin "$GCO"
mkdir -p "$GC/scripts/lib" "$GC/scripts/handover/chief-kit"
: > "$GC/scripts/lib/rename-aliases.tsv"
cp "$SUT" "$GC/scripts/handover/chief-kit/holds.py"
for n in a1 c1 d1 f1 g1 m1 h1 j1 j2 q1 hs hs2 st1; do echo "$n" > "$GC/$n.txt"; done
git -C "$GC" add -A
git -C "$GC" commit -q -m base
git -C "$GC" push -q origin main
BASE0="$(git -C "$GC" rev-parse HEAD)"
mkdir -p "$GC/.git/hooks"  # an image whose git has no template dir creates none
printf '#!/bin/sh\n%s\n' "$ENTRY_C" > "$GC/.git/hooks/pre-commit"
printf '#!/bin/sh\n%s\n' "$ENTRY_P" > "$GC/.git/hooks/pre-push"
chmod +x "$GC/.git/hooks/pre-commit" "$GC/.git/hooks/pre-push"
cat > "$W/bin/gh-base" <<'STUB'
#!/usr/bin/env bash
case "$*" in *baseRefName*) echo "${GH_BASE:-main}" ;; *) echo OPEN ;; esac
STUB
chmod +x "$W/bin/gh-base"
export GH_BASE=main
export HOLDS_QUEUE_LOCK="$QL"  # the temp repo's holds.py copy has no queue-lock.sh beside it

gcwt() { git -C "$GC" worktree add -q "$W/gcw-$1" -b "feat/$1" "${2:-origin/main}" > /dev/null 2>&1; printf '%s' "$W/gcw-$1"; }
# asw <worktree> <key> <doc or ""> <label> <command...>: run in the worktree as that holder
# shellcheck disable=SC2086,SC2329  # the doc path has no whitespace and an empty doc drops the variable; asw is called through run
asw() { local wt=$1 key=$2 doc=$3 label=$4; shift 4; ( cd "$wt" && env HIMMEL_HOLD_KEY="$key" ${doc:+HIMMEL_HOLD_DOC="$doc"} HIMMEL_HOLD_LABEL="$label" "$@" ); }
gcdoc_a="$(mkdoc "$K1-gc.md")"; lock_hold "$gcdoc_a"
gcdoc_b="$(mkdoc "$K2-gc.md")"; lock_hold "$gcdoc_b"
GCQ=(python3 -I "$SUT" git-check)

# a shell write (sed -i) then a commit by key B on a file key A holds: git's own list, no shell text involved
GW="$(gcwt sed)"
put_row a1.txt $K1 alpha "$gcdoc_a" brief "" "$GC"
( cd "$GW" && sed -i 's/^/x/' a1.txt && git add a1.txt )  # gnu-ok: this suite is Linux-only (header)
run asw "$GW" $K2 "$gcdoc_b" beta git commit -q -m sed-change
same "T5 an in-place shell rewrite then a commit by B on a file A holds is refused" "$((RC != 0))" 1
contains "T5 the refusal names the holder" "$ERR" "$K1"
same "T5 the refused file is not committed" "$(git -C "$GW" log --format=%s -1)" base
git -C "$GW" reset -q; git -C "$GW" checkout -q -- a1.txt

# an unheld file: the commit passes and claims a row carrying doc and label
GW="$(gcwt claim)"
( cd "$GW" && echo b >> c1.txt && git add c1.txt )
run asw "$GW" $K2 "$gcdoc_b" beta git commit -q -m claim-it
same "T5 an unheld commit passes" "$RC" 0
same "T5 the commit claims a row with doc and label" "$(cut -f1-4 "$(rowf c1.txt "$GC")" 2>/dev/null | tr '\t' ' ')" "$K2 beta $gcdoc_b claim"

# I12: that row aged past the grace, the holder's real lock held: a rival's commit is refused
touch -d '2 hours ago' "$(rowf c1.txt "$GC")"
GW="$(gcwt rival)"
( cd "$GW" && echo r >> c1.txt && git add c1.txt )
run asw "$GW" $K1 "$gcdoc_a" alpha git commit -q -m rival
same "T5 I12 an aged own row with the holder's lock held refuses a rival" "$((RC != 0))" 1
contains "T5 I12 the refusal names the holder" "$ERR" "$K2"

# HIMMEL_HOLD_KEY with no HIMMEL_HOLD_DOC: the commit passes and publishes no row
GW="$(gcwt nodoc)"
( cd "$GW" && echo b >> d1.txt && git add d1.txt )
run asw "$GW" $K2 "" beta git commit -q -m nodoc
same "T5 no HIMMEL_HOLD_DOC: the commit passes" "$RC" 0
same "T5 no HIMMEL_HOLD_DOC: no row" "$([ -e "$(rowf d1.txt "$GC")" ] && echo row || echo none)" none

# I2: two keys on disjoint files both commit and push
GW1="$(gcwt disj-a)"; GW2="$(gcwt disj-b)"
( cd "$GW1" && echo 1 > e1.txt && git add e1.txt )
( cd "$GW2" && echo 2 > e2.txt && git add e2.txt )
run asw "$GW1" $K1 "$gcdoc_a" alpha git commit -q -m e1
same "T5 I2 key A commits its file" "$RC" 0
run asw "$GW2" $K2 "$gcdoc_b" beta git commit -q -m e2
same "T5 I2 key B commits its file" "$RC" 0
run asw "$GW1" $K1 "$gcdoc_a" alpha git push -q origin HEAD
same "T5 I2 key A pushes" "$RC" 0
run asw "$GW2" $K2 "$gcdoc_b" beta git push -q origin HEAD
same "T5 I2 key B pushes" "$RC" 0

# git mv and git rm claim both names
GW="$(gcwt mvrm)"
( cd "$GW" && git mv f1.txt f2.txt && git rm -q g1.txt )
run asw "$GW" $K2 "$gcdoc_b" beta git commit -q -m mvrm
same "T5 git mv and git rm commit" "$RC" 0
same "T5 git mv claims the old name" "$(cut -f1 "$(rowf f1.txt "$GC")" 2>/dev/null)" $K2
same "T5 git mv claims the new name" "$(cut -f1 "$(rowf f2.txt "$GC")" 2>/dev/null)" $K2
same "T5 git rm claims the removed name" "$(cut -f1 "$(rowf g1.txt "$GC")" 2>/dev/null)" $K2

# a conflicted merge-forward carries a third party's files: the commit passes and claims nothing
GW="$(gcwt merge "$BASE0")"
( cd "$GW" && echo mine > m1.txt && git add m1.txt && git commit -q -m mine )
( cd "$GC" && echo theirs > m1.txt && echo x > x1.txt && echo y > y1.txt && git add -A && git commit -q -m main-moves && git push -q origin main )
put_row x1.txt $K1 alpha "$gcdoc_a" brief "" "$GC"
( cd "$GW" && git merge -q origin/main > /dev/null 2>&1; echo resolved > m1.txt; git add -A )
run asw "$GW" $K2 "$gcdoc_b" beta git commit -q --no-edit
same "T5 a conflicted merge-forward commit passes (a rival holds a file of main's delta)" "$RC" 0
same "T5 a conflicted merge-forward claims nothing of main's delta" "$([ -e "$(rowf y1.txt "$GC")" ] && echo row || echo none)" none

# a rebase in progress is skipped (control: the same staged file is refused once it is over)
GW="$(gcwt rebase)"
put_row h1.txt $K1 alpha "$gcdoc_a" brief "" "$GC"
( cd "$GW" && echo z >> h1.txt && git add h1.txt && mkdir "$(git rev-parse --git-path rebase-merge)" )
run asw "$GW" $K2 "$gcdoc_b" beta "${GCQ[@]}" --staged
same "T5 a rebase in progress is skipped" "$RC" 0
( cd "$GW" && rmdir "$(git rev-parse --git-path rebase-merge)" )
run asw "$GW" $K2 "$gcdoc_b" beta "${GCQ[@]}" --staged
same "T5 control: the staged held file is refused once the rebase is over" "$RC" 1

# a push after a rebase lists only the worker's files (main's delta holds x1.txt, which a rival holds)
GW="$(gcwt rebased "$BASE0")"
( cd "$GW" && echo r > r1.txt && git add r1.txt && git commit -q -m r1 && git rebase -q origin/main > /dev/null 2>&1 )
run asw "$GW" $K2 "$gcdoc_b" beta "${GCQ[@]}" --push
same "T5 a push after a rebase lists only the worker's files" "$RC" 0

# pr rows on push: a fresh row refuses, over 30 minutes passes, the own branch's row passes
GW="$(gcwt prrow)"
( cd "$GW" && echo q >> q1.txt && git add q1.txt && WRITE_HOLD_OK=1 git commit -q -m q1 )
put_row q1.txt $K1 branch:feat/other "" pr 55 "$GC"; touch "$(rowf q1.txt "$GC")"
run asw "$GW" $K2 "$gcdoc_b" beta env HOLDS_GH="$W/bin/gh-base" "${GCQ[@]}" --push
same "T5 a push over a file a fresh pr row holds is refused" "$RC" 1
contains "T5 the push refusal names the holder" "$ERR" "$K1"
touch -d '31 minutes ago' "$(rowf q1.txt "$GC")"
run asw "$GW" $K2 "$gcdoc_b" beta env HOLDS_GH="$W/bin/gh-base" "${GCQ[@]}" --push
same "T5 a pr row over 30 minutes old passes" "$RC" 0
put_row q1.txt $K1 branch:feat/prrow "" pr 55 "$GC"; touch "$(rowf q1.txt "$GC")"
run asw "$GW" $K2 "$gcdoc_b" beta env HOLDS_GH="$W/bin/gh-base" "${GCQ[@]}" --push
same "T5 a pr row of the own branch passes" "$RC" 0

# A narrowed pr row (it carries a doc: narrow --apply made it) is never stale, however old; a doc-less pr row
# (sync-prs) over 30 minutes still passes. The holder's lock is held, gh fails, the row is aged 2 hours.
printf '#!/usr/bin/env bash\nexit 1\n' > "$W/bin/gh-down"; chmod +x "$W/bin/gh-down"
put_row q1.txt $K1 branch:feat/other "" pr 55 "$GC"
run asw "$GW" $K2 "$gcdoc_b" beta env HOLDS_GH="$W/bin/gh-down" "${GCQ[@]}" --push
same "T5 F1 control: a doc-less pr row aged 2 h passes --push" "$RC" 0
run asw "$GW" $K2 "$gcdoc_b" beta env HOLDS_GH="$W/bin/gh-down" python3 -I "$SUT" narrow --check --key $K2 --repo "$GC" --doc "$gcdoc_b" --base main --label beta
same "T5 F1 control: a doc-less pr row aged 2 h passes narrow --check" "$RC" 0
put_row q1.txt $K1 alpha "$gcdoc_a" pr 55 "$GC"
run asw "$GW" $K2 "$gcdoc_b" beta env HOLDS_GH="$W/bin/gh-down" "${GCQ[@]}" --push
same "T5 F1 a narrowed pr row aged 2 h, its holder's lock held, refuses --push" "$RC" 1
contains "T5 F1 the --push refusal names the holder" "$ERR" "$K1"
run asw "$GW" $K2 "$gcdoc_b" beta env HOLDS_GH="$W/bin/gh-down" python3 -I "$SUT" narrow --check --key $K2 --repo "$GC" --doc "$gcdoc_b" --base main --label beta
same "T5 F1 a narrowed pr row aged 2 h refuses narrow --check" "$RC" 1
contains "T5 F1 narrow --check names the holder" "$ERR" "$K1"
contains "T5 F2 a doc with no Writes line still runs the rival check, the line is unavailable" "$OUT" "outside-writes: unavailable (no Writes line)"
GW="$(gcwt narrowed)"
( cd "$GW" && echo q >> q1.txt && git add q1.txt )
run asw "$GW" $K2 "$gcdoc_b" beta env HOLDS_GH="$W/bin/gh-down" "${GCQ[@]}" --staged
same "T5 F1 a narrowed pr row aged 2 h refuses --staged" "$RC" 1
put_row q1.txt $K1 branch:feat/other "" pr 55 "$GC"
run asw "$GW" $K2 "$gcdoc_b" beta env HOLDS_GH="$W/bin/gh-down" "${GCQ[@]}" --staged
same "T5 F1 control: a doc-less pr row aged 2 h passes --staged" "$RC" 0
git -C "$GW" reset -q; git -C "$GW" checkout -q -- q1.txt

# git commit -a and git commit <path> run the hook against a temporary index
GW="$(gcwt tmpidx)"
put_row j1.txt $K1 alpha "$gcdoc_a" brief "" "$GC"; put_row j2.txt $K1 alpha "$gcdoc_a" brief "" "$GC"
( cd "$GW" && echo 1 >> j1.txt )
run asw "$GW" $K2 "$gcdoc_b" beta git commit -q -a -m all
same "T5 git commit -a on a file a rival holds is refused" "$((RC != 0))" 1
contains "T5 git commit -a names the holder" "$ERR" "$K1"
git -C "$GW" checkout -q -- j1.txt
( cd "$GW" && echo 2 >> j2.txt )
run asw "$GW" $K2 "$gcdoc_b" beta git commit -q -m path j2.txt
same "T5 git commit <path> on a file a rival holds is refused" "$((RC != 0))" 1
contains "T5 git commit <path> names the holder" "$ERR" "$K1"

# a stacked child with a live parent PR: the base is the parent branch, so its files are not the child's
( cd "$GC" && git checkout -q -b feat/parent origin/main && echo p > p1.txt && git add p1.txt && git commit -q -m parent && git push -q origin feat/parent && git checkout -q main )
GW="$(gcwt child origin/feat/parent)"
( cd "$GW" && echo c > c9.txt && git add c9.txt && git commit -q -m child )
put_row p1.txt $K1 branch:feat/parent "" pr 77 "$GC"; touch "$(rowf p1.txt "$GC")"
run asw "$GW" $K2 "$gcdoc_b" beta env HOLDS_GH="$W/bin/gh-base" GH_BASE=feat/parent "${GCQ[@]}" --push
same "T5 a stacked child with a live parent PR passes its push" "$RC" 0
run asw "$GW" $K2 "$gcdoc_b" beta env HOLDS_GH="$W/bin/gh-base" GH_BASE=main "${GCQ[@]}" --push
same "T5 control: the same push against origin/main lists the parent's file and is refused" "$RC" 1

# the bypass, the OFF sentinel and the marker each pass both checks
GW="$(gcwt bypass)"
put_row hs.txt $K1 alpha "$gcdoc_a" brief "" "$GC"; put_row hs2.txt $K1 alpha "$gcdoc_a" brief "" "$GC"
( cd "$GW" && echo 1 >> hs.txt && git add hs.txt && WRITE_HOLD_OK=1 git commit -q -m hs && echo 2 >> hs2.txt && git add hs2.txt )
run asw "$GW" $K2 "$gcdoc_b" beta "${GCQ[@]}" --staged
same "T5 control: --staged refuses a held file" "$RC" 1
run asw "$GW" $K2 "$gcdoc_b" beta "${GCQ[@]}" --push
same "T5 control: --push refuses a held file" "$RC" 1
run asw "$GW" $K2 "$gcdoc_b" beta env WRITE_HOLD_OK=1 "${GCQ[@]}" --staged
same "T5 WRITE_HOLD_OK=1 passes --staged" "$RC" 0
run asw "$GW" $K2 "$gcdoc_b" beta env WRITE_HOLD_OK=1 "${GCQ[@]}" --push
same "T5 WRITE_HOLD_OK=1 passes --push" "$RC" 0
: > "$REG/OFF"
run asw "$GW" $K2 "$gcdoc_b" beta "${GCQ[@]}" --staged
same "T5 the OFF sentinel passes --staged" "$RC" 0
run asw "$GW" $K2 "$gcdoc_b" beta "${GCQ[@]}" --push
same "T5 the OFF sentinel passes --push" "$RC" 0
rm -f "$REG/OFF"
: > "$GC/.single-writer"
run asw "$GW" $K2 "$gcdoc_b" beta "${GCQ[@]}" --staged
same "T5 the marker at the primary passes --staged" "$RC" 0
run asw "$GW" $K2 "$gcdoc_b" beta "${GCQ[@]}" --push
same "T5 the marker at the primary passes --push" "$RC" 0
rm -f "$GC/.single-writer"

# faults pass: an unreadable register, and origin/main missing
if [ "$(id -u)" != 0 ]; then
    chmod 000 "$(slugdir "$GC")"
    run asw "$GW" $K2 "$gcdoc_b" beta "${GCQ[@]}" --staged
    chmod 755 "$(slugdir "$GC")"
    same "T5 an unreadable register exits 0" "$RC" 0
fi
GN="$W/gc-noremote"
git init -q -b main "$GN"; echo n > "$GN/n1.txt"; git -C "$GN" add -A; git -C "$GN" commit -q -m base
git -C "$GN" checkout -q -b feat/n; echo m >> "$GN/n1.txt"; git -C "$GN" add -A; git -C "$GN" commit -q -m n
put_row n1.txt $K1 alpha "$gcdoc_a" brief "" "$GN"
run asw "$GN" $K2 "$gcdoc_b" beta "${GCQ[@]}" --push
same "T5 origin/main missing exits 0" "$RC" 0
git -C "$GN" update-ref refs/remotes/origin/main "$(git -C "$GN" rev-parse main)"
run asw "$GN" $K2 "$gcdoc_b" beta "${GCQ[@]}" --push
same "T5 control: with origin/main present the same push is refused" "$RC" 1

# the real entry: a holds.py that exits 1 with no holds: line lets the commit pass; a holds: line refuses; OFF is read first
GW="$(gcwt entry)"
( cd "$GW" && printf 'import sys\nsys.exit(1)\n' > scripts/handover/chief-kit/holds.py && echo e >> st1.txt && git add st1.txt )
run asw "$GW" $K2 "$gcdoc_b" beta git commit -q -m stub
same "T5 a holds.py stub exiting 1 with no holds: line lets the commit pass" "$RC" 0
( cd "$GW" && printf 'def (:\n' > scripts/handover/chief-kit/holds.py && echo e >> st1.txt && git add st1.txt )
run asw "$GW" $K2 "$gcdoc_b" beta git commit -q -m syntax
same "T5 a holds.py with a SyntaxError lets the commit pass" "$RC" 0
( cd "$GW" && printf 'import sys\nsys.stderr.write("holds: stub refusal\\n")\nsys.exit(1)\n' > scripts/handover/chief-kit/holds.py && echo e >> st1.txt && git add st1.txt )
run asw "$GW" $K2 "$gcdoc_b" beta git commit -q -m refuse
same "T5 control: a stub exiting 1 with a holds: line refuses the commit" "$((RC != 0))" 1
: > "$REG/OFF"
run asw "$GW" $K2 "$gcdoc_b" beta git commit -q -m off
same "T5 the entry stats OFF first: the refusing stub is never run" "$RC" 0
rm -f "$REG/OFF"
unset HOLDS_QUEUE_LOCK GH_BASE

# ---- the real register was never touched
# a before/after compare of the live register fails when a real worker writes during the run. Every row this
# suite writes names a doc or repo under $W, a path unique to this run: none may appear in the real register.
same "no row or event of this suite reached the real ~/.himmel/state/holds" "$(grep -rlF "$W" "$REAL_HOME/.himmel/state/holds" 2>/dev/null | grep -c . || true)" 0

if [ "$fails" -eq 0 ]; then
    printf 'test-holds: %d passed, 0 failed\n' "$total"
    exit 0
fi
printf 'test-holds: %d passed, %d failed\n' "$((total - fails))" "$fails"
exit 1
