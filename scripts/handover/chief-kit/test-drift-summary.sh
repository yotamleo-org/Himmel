#!/usr/bin/env bash
# shellcheck disable=SC2015  # A && B || C is intentional in the pass/fail reporting lines
# test-drift-summary.sh — Exercises drift-summary.mjs (rows sorted into real, known checker bug
# and transient; stale and unknown; the team-mode key) and known-bugs-sync.sh (the known-bug
# file kept in step with the checker ticket's Jira links, the newer edit winning). A fake jira
# (KBS_JIRA) answers `links` and `history --json` from fixture files and records every call, so
# nothing reaches the live project. DRIFT_SUMMARY and KNOWN_BUGS_SYNC override the scripts under
# test (the RED control: a missing script fails every row). bash 3.2-safe apart from date -d,
# which the chief kit may use (Linux only).
#
# Run: bash scripts/handover/chief-kit/test-drift-summary.sh
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
SUM="${DRIFT_SUMMARY:-$HERE/drift-summary.mjs}"
SYNC="${KNOWN_BUGS_SYNC:-$HERE/known-bugs-sync.sh}"

fails=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; fails=$((fails + 1)); }
has() { case "$2" in *"$3"*) pass "$1" ;; *) fail "$1 (missing '$3' in: $2)" ;; esac; }
lacks() { case "$2" in *"$3"*) fail "$1 (found '$3')" ;; *) pass "$1" ;; esac; }
eq() { [ "$2" = "$3" ] && pass "$1" || fail "$1 (got '$2', want '$3')"; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/drift-summary-test.XXXXXX")" || exit 1
trap 'rm -rf "$WORK"' EXIT
export HOME="$WORK/home"; mkdir -p "$HOME"
export HIMMEL_CONFIG_DIR="$WORK/conf"; mkdir -p "$HIMMEL_CONFIG_DIR"
unset JIRA_PROJECT_KEY
MIR="$WORK/mirror"; mkdir -p "$MIR"
NOW=1792000000

mirror() { # <key> <statusCategory>
    printf -- '---\nkey: "%s"\nstatus: "%s"\nstatusCategory: "%s"\n---\n' "$1" "$2" "$2" > "$MIR/$1.md"
}
mirror HIMMEL-7980 "To Do"

DRIFT="$WORK/focus-drift.txt"
KNOWN="$WORK/known.tsv"
export DRIFT_SUMMARY_KNOWN="$KNOWN"
printf '# checker\tclass\tkey\tedited-at\n' > "$KNOWN"
for row in 'DERIVE-MISMATCH HIMMEL-7848' 'UNOWNED HIMMEL-7848' 'WORKER-COMMENT HIMMEL-7848' 'UNOWNED HIMMEL-7588'; do
    printf 'HIMMEL-7980\t%s\t%s\t2026-10-28T22:00:00Z\n' "${row% *}" "${row#* }" >> "$KNOWN"
done
# the E12 file: three real, four paired with the checker ticket, one transient
cat > "$DRIFT" <<'EOF'
VERSION-DRIFT HIMMEL-6691 Done in v1.1.4, current v1.1.3 | writer=release-manager | fix=x
VERSION-DRIFT HIMMEL-7891 Done in v1.1.4, current v1.1.3 | writer=release-manager | fix=x
VERSION-DRIFT HIMMEL-7944 Done in v1.1.4, current v1.1.3 | writer=release-manager | fix=x
DERIVE-MISMATCH HIMMEL-7848 jira=In Review, derived=To Do | writer=a | fix=b
UNOWNED HIMMEL-7848 In Review, no open PR | writer=a | fix=b
WORKER-COMMENT HIMMEL-7848 record hash 1 | writer=a | fix=b
UNOWNED HIMMEL-7588 In Progress, no open PR | writer=a | fix=b
WORKER-COMMENT HIMMEL-4862 the record's hash differs | writer=a | fix=b
sdrift=8:abcd1234
EOF
touch -d "@$((NOW - 600))" "$DRIFT"

# shellcheck disable=SC2119,SC2120  # extra arguments are optional; most calls pass none
sum() { node "$SUM" --json --drift "$DRIFT" --mirror-dir "$MIR" --now "$NOW" "$@" 2>&1; }
jqv() { printf '%s' "$1" | jq -r "$2" 2>&1; }

out="$(sum)"
eq 'E12 three real rows count' "$(jqv "$out" '.counts.real')" 3
eq 'E12 four rows pair with the open checker ticket' "$(jqv "$out" '.counts.known')" 4
eq 'E12 one transient row is listed apart' "$(jqv "$out" '.counts.transient')" 1
eq 'E12 the real rows are the three hand closes' "$(jqv "$out" '[.real[].key] | sort | join(",")')" 'HIMMEL-6691,HIMMEL-7891,HIMMEL-7944'
eq 'E12 the known rows name their checker ticket' "$(jqv "$out" '[.known[].checker] | unique | join(",")')" 'HIMMEL-7980'
eq 'E12 the transient row is the unpaired WORKER-COMMENT' "$(jqv "$out" '.transient[0].key')" 'HIMMEL-4862'
eq 'E15 a fresh file is not stale' "$(jqv "$out" '.stale')" false
eq 'E15 a readable sdrift is not unknown' "$(jqv "$out" '.unknown')" false
eq 'E14 the saved run time is reported' "$(jqv "$out" '.file.writtenAt')" "$((NOW - 600))"

# E13: no drift
printf 'sdrift=0:00000000\n' > "$DRIFT"; touch -d "@$((NOW - 60))" "$DRIFT"
out="$(sum)"
eq 'E13 sdrift=0 counts nothing' "$(jqv "$out" '.counts.real + .counts.known + .counts.transient')" 0

# E15: unknown and stale never read as zero
printf 'HEALTH - jira: could not read | writer=- | fix=-\nsdrift=unknown\n' > "$DRIFT"; touch -d "@$((NOW - 60))" "$DRIFT"
out="$(sum)"
eq 'E15 sdrift=unknown is marked unknown' "$(jqv "$out" '.unknown')" true
printf 'sdrift=0:00000000\n' > "$DRIFT"; touch -d "@$((NOW - 40000))" "$DRIFT"
out="$(sum)"
eq 'E15 a file older than one focus refresh is marked stale' "$(jqv "$out" '.stale')" true
out="$(node "$SUM" --json --drift "$WORK/absent.txt" --mirror-dir "$MIR" --now "$NOW" 2>&1)"
eq 'E15 an absent file reports exists=false' "$(jqv "$out" '.file.exists')" false

# E23 and K2: a known pair counts again once its ticket is Done; an unpaired row counts at once
cat > "$DRIFT" <<'EOF'
UNOWNED HIMMEL-7588 In Progress, no open PR | writer=a | fix=b
UNOWNED HIMMEL-9001 a row new since the last run | writer=a | fix=b
DONE-WITH-OPEN-PR HIMMEL-7588 the same key under another class | writer=a | fix=b
sdrift=3:11111111
EOF
touch -d "@$((NOW - 60))" "$DRIFT"
out="$(sum)"
eq 'E23 while the checker ticket is open the paired row is known' "$(jqv "$out" '[.known[].class] | join(",")')" 'UNOWNED'
eq 'K2 a row with no pairing counts at once' "$(jqv "$out" '[.real[].key] | sort | join(",")')" 'HIMMEL-7588,HIMMEL-9001'
mirror HIMMEL-7980 Done
out="$(sum)"
eq 'E23 once the checker ticket is Done the same row counts' "$(jqv "$out" '.counts.real')" 3
eq 'E23 and no row is listed as a known checker bug' "$(jqv "$out" '.counts.known')" 0
rm -f "$MIR/HIMMEL-7980.md"
out="$(sum)"
eq 'E23 an unreadable checker status counts the row (a drift is a bug until shown otherwise)' "$(jqv "$out" '.counts.real')" 3
mirror HIMMEL-7980 "To Do"

# E21: the mode key, default off
eq 'E21 no key reads single-user' "$(jqv "$out" '.mode')" single-user
eq 'E21 and says it is the default' "$(jqv "$out" '.modeSource')" default
printf 'HIMMEL_TRACKER_TEAM_MODE=on\n' > "$HIMMEL_CONFIG_DIR/himmel.conf"
out="$(sum)"
eq 'E21 the key on reads team' "$(jqv "$out" '.mode')" team
printf 'HIMMEL_TRACKER_TEAM_MODE=off\n' > "$HIMMEL_CONFIG_DIR/himmel.conf.local"
out="$(sum)"
eq 'E21 himmel.conf.local wins over himmel.conf' "$(jqv "$out" '.mode')" single-user
rm -f "$HIMMEL_CONFIG_DIR/himmel.conf" "$HIMMEL_CONFIG_DIR/himmel.conf.local"

# --- the sync with the checker ticket's Jira links (K1, E32) ---
JF="$WORK/jfx"; mkdir -p "$JF"
cat > "$WORK/jira" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$JF/calls"
case "\$1" in
    links) cat "$JF/links" ;;
    history) cat "$JF/history.json" ;;
    link) echo "linked \$2 \$3" ;;
    *) exit 2 ;;
esac
EOF
chmod +x "$WORK/jira"
export KBS_JIRA="$WORK/jira"
SLOG="$WORK/sync.log"
hist() { # <added|removed> <key> <iso>  -> one changelog entry
    if [ "$1" = added ]; then
        printf '{"created":"%s","items":[{"field":"Link","fromString":null,"toString":"This issue relates to %s"}]}' "$3" "$2"
    else
        printf '{"created":"%s","items":[{"field":"Link","fromString":"This issue relates to %s","toString":null}]}' "$3" "$2"
    fi
}
reset_sync() {
    : > "$JF/calls"; : > "$SLOG"
    printf '# checker\tclass\tkey\tedited-at\n' > "$KNOWN"
    echo 'HIMMEL-7980: no issue links' > "$JF/links"
    echo '[]' > "$JF/history.json"
}
run_sync() { bash "$SYNC" --checker HIMMEL-7980 --tsv "$KNOWN" --log "$SLOG" 2>&1; }

# E32 (RED first): a pairing removed in Jira after the file row's edit is removed from the file
reset_sync
printf 'HIMMEL-7980\tUNOWNED\tHIMMEL-7588\t2026-10-29T10:00:00Z\n' >> "$KNOWN"
printf '[%s,%s]\n' "$(hist added HIMMEL-7588 2026-10-29T09:00:00.000+0000)" "$(hist removed HIMMEL-7588 2026-10-29T11:00:00.000+0000)" > "$JF/history.json"
run_sync > /dev/null
eq "E32 a pairing removed in Jira after the file row's edit is removed from the file" "$(grep -c HIMMEL-7588 "$KNOWN")" 0
has 'E32 the removal leaves one log line' "$(cat "$SLOG")" 'HIMMEL-7588'
lacks 'E32 and nothing is linked back' "$(cat "$JF/calls")" 'link HIMMEL-7980'

# E32 reverse: the file row is the newer edit, so the Jira link is restored
reset_sync
printf 'HIMMEL-7980\tUNOWNED\tHIMMEL-7588\t2026-10-29T12:00:00Z\n' >> "$KNOWN"
printf '[%s,%s]\n' "$(hist added HIMMEL-7588 2026-10-29T09:00:00.000+0000)" "$(hist removed HIMMEL-7588 2026-10-29T11:00:00.000+0000)" > "$JF/history.json"
run_sync > /dev/null
has 'E32 a file row newer than the Jira removal restores the link' "$(cat "$JF/calls")" 'link HIMMEL-7980 HIMMEL-7588 --type Relates'
eq 'E32 and stays in the file' "$(grep -c HIMMEL-7588 "$KNOWN")" 1
has 'E32 with one log line' "$(cat "$SLOG")" 'HIMMEL-7588'

# a file row Jira never saw is linked
reset_sync
printf 'HIMMEL-7980\tUNOWNED\tHIMMEL-7588\t2026-10-29T12:00:00Z\n' >> "$KNOWN"
run_sync > /dev/null
has 'a file row with no Jira history is linked' "$(cat "$JF/calls")" 'link HIMMEL-7980 HIMMEL-7588 --type Relates'

# a pair that comes in from Jira reads class unset, and still leaves the count
reset_sync
printf '99\tRelates\tinward=HIMMEL-7980\toutward=HIMMEL-7900\tHIMMEL-7980 relates to HIMMEL-7900\n' > "$JF/links"
printf '[%s]\n' "$(hist added HIMMEL-7900 2026-10-29T09:30:00.000+0000)" > "$JF/history.json"
run_sync > /dev/null
eq 'E32 a pair from Jira is written as class unset with its Jira edit time' "$(grep HIMMEL-7900 "$KNOWN")" "$(printf 'HIMMEL-7980\tunset\tHIMMEL-7900\t2026-10-29T09:30:00Z')"
has 'E32 and logged' "$(cat "$SLOG")" 'HIMMEL-7900'
printf 'UNOWNED HIMMEL-7900 x | writer=a | fix=b\nsdrift=1:22222222\n' > "$DRIFT"; touch -d "@$((NOW - 60))" "$DRIFT"
out="$(sum)"
eq 'E32 an unset pair still leaves the count' "$(jqv "$out" '.counts.known')" 1

# a pairing present on both sides writes nothing and logs nothing
reset_sync
printf 'HIMMEL-7980\tUNOWNED\tHIMMEL-7900\t2026-10-29T09:30:00Z\n' >> "$KNOWN"
printf '99\tRelates\tinward=HIMMEL-7980\toutward=HIMMEL-7900\tHIMMEL-7980 relates to HIMMEL-7900\n' > "$JF/links"
printf '[%s]\n' "$(hist added HIMMEL-7900 2026-10-29T09:30:00.000+0000)" > "$JF/history.json"
run_sync > /dev/null
eq 'a pairing on both sides logs nothing' "$(wc -c < "$SLOG" | tr -d ' ')" 0
lacks 'a pairing on both sides links nothing' "$(cat "$JF/calls")" 'link HIMMEL-7980'

# a Blocks link on the checker ticket is not a pairing
reset_sync
printf '5\tBlocks\tinward=HIMMEL-7980\toutward=HIMMEL-7000\tHIMMEL-7980 blocks HIMMEL-7000\n' > "$JF/links"
run_sync > /dev/null
eq 'a Blocks link is not read as a known-bug pairing' "$(grep -c HIMMEL-7000 "$KNOWN")" 0

if [ "$fails" -gt 0 ]; then printf '%s failure(s)\n' "$fails"; exit 1; fi
echo "all passed"
