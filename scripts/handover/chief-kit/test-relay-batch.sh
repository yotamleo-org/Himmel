#!/usr/bin/env bash
# test-relay-batch.sh — Exercises relay-batch.sh: one command that
# relays a chief succession to every worker, never minting or rotating a token.
# inbox-send.sh is stubbed (INBOX_SEND). bash 3.2-safe.
#
# RELAY_BATCH overrides the script under test (the RED control).
#
# Run: bash scripts/handover/chief-kit/test-relay-batch.sh
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
RB="${RELAY_BATCH:-$HERE/relay-batch.sh}"

fails=0
check() { # <name> <expected> <actual>
    if [ "$2" = "$3" ]; then echo "PASS: $1"; else echo "FAIL: $1 (want '$2' got '$3')"; fails=$((fails + 1)); fi
}

WORK="$(mktemp -d "${TMPDIR:-/tmp}/relay-batch-test.XXXXXX")" || { echo "mktemp -d failed" >&2; exit 1; }
trap 'rm -rf "$WORK"' EXIT
export BRIDGE_ROOT="$WORK/bridge"

DOC="$WORK/DEMO-nextleg-2026-10-08A-chief.md"
LEG1="$WORK/DEMO-1-N7-alpha.md"
LEG2="$WORK/DEMO-2-N8-beta.md"
: > "$LEG1"; : > "$LEG2"
cat > "$DOC" <<'EOF'
# chief

## Live state

legs: `N7:tok-seven:lock7:11` `N8:tok-eight:lock8:22`
`N9:tok-nine:lock9:33` extra prose
queue: none
last GO: none

## Results
EOF
printf '{"schema":1,"legs":[{"doc":"%s","label":"N7","added":"x","lane":"native"},{"doc":"%s","label":"N8","added":"x","lane":"claudex"}]}\n' "$LEG1" "$LEG2" > "${DOC%.md}.fleet.json"

SEND="$WORK/send.sh"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "%s/send.log"\n' "$WORK" > "$SEND"
export INBOX_SEND="$SEND"
# The live process census (claude_sessions format: pid<TAB>name<TAB>model<TAB>autocompact).
CENSUS="$WORK/census.sh"
printf '#!/usr/bin/env bash\ncat "%s/census.txt"\n' "$WORK" > "$CENSUS"
export RELAY_BATCH_CENSUS="$CENSUS"
census() { : > "$WORK/census.txt"; for n in "$@"; do printf '100\t%s\topus\t200000\n' "$n" >> "$WORK/census.txt"; done; }
census DEMO-1-N7-alpha DEMO-2-N8-beta
# The himmel-bus CLI: logs `<verb> <to>` and the body file it was handed.
BUS="$WORK/bus.sh"
# shellcheck disable=SC2016  # $1-$3 expand in the stub, not here; read-sink-ok: $3 is the body file relay-batch.sh mktemps
LOGBUS="$(printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$1 $2" >> "%s/bus.log"; cat "$3" >> "%s/bus.body"\n' "$WORK" "$WORK")"
printf '%s\n' "$LOGBUS" > "$BUS"
chmod +x "$BUS"
export RELAY_BATCH_BUS="$BUS"
# The outgoing chief's own bus identity: without one, no bus record is sent.
export HIMMEL_BUS_NAME=DEMO-nextleg-2026-10-08A-chief

rc=0
out="$(bash "$RB" "$DOC" --successor DEMO-nextleg-2026-10-08B-chief --claudex N8 2>&1)" || rc=$?
check "relay-batch succeeds for native and claudex relays" "0" "$rc"
check "a native worker also gets a bus record from the outgoing chief" "send DEMO-1-N7-alpha" "$(grep -x 'send DEMO-1-N7-alpha' "$WORK/bus.log" 2>/dev/null)"
check "a claudex worker gets a bus record too, under its doc stem" "send DEMO-2-N8-beta" "$(grep -x 'send DEMO-2-N8-beta' "$WORK/bus.log" 2>/dev/null)"
check "the claudex bus send is reported" "1" "$(printf '%s\n' "$out" | grep -c '^BUS-RELAY N8 ok$')"
check "the bus record names the successor as a whole word, once per relayed worker" "2" "$(grep -cE 'your chief is now DEMO-nextleg-2026-10-08B-chief[. ]' "$WORK/bus.body" 2>/dev/null)"
check "the bus record carries no token" "0" "$(grep -c 'tok-' "$WORK/bus.body" 2>/dev/null)"
check "the bus send is reported" "1" "$(printf '%s\n' "$out" | grep -c '^BUS-RELAY N7 ok$')"
check "a native worker whose bus record lands gets no SendMessage" "0" "$(printf '%s\n' "$out" | grep -c '^SENDMESSAGE to=DEMO-1-N7-alpha ::')"
check "the native bus record is the relay: it names itself an S1 relay" "1" "$(grep -cF 'is an S1 relay' "$WORK/bus.body")"
check "the native bus record gives the exact acknowledgement with no trailing text" "1" "$(grep -c 'SUCCESSION accepted: DEMO-nextleg-2026-10-08B-chief replaces DEMO-nextleg-2026-10-08A-chief$' "$WORK/bus.body")"
check "the native bus record forbids anything after the acknowledgement on its line" "1" "$(grep -cF 'nothing after it on that line' "$WORK/bus.body")"
check "a bus-relayed worker counts as relayed" "1" "$(printf '%s\n' "$out" | grep -c '^RELAYED 2 of 2$')"
check "claudex relay gives the same exact acknowledgement before the send flags" "1" "$(grep -cF 'SUCCESSION accepted: DEMO-nextleg-2026-10-08B-chief replaces DEMO-nextleg-2026-10-08A-chief --token tok-eight' "$WORK/send.log")"
check "claudex relay forbids anything after the acknowledgement on its line" "1" "$(grep -cF 'nothing after it on that line' "$WORK/send.log")"
check "claudex worker goes through inbox-send" "1" "$(printf '%s\n' "$out" | grep -c '^SENT-INBOX N8')"
check "inbox-send is given the worker's token via --token" "1" "$(grep -c -- '--token tok-eight --doc '"$LEG2" "$WORK/send.log")"
check "the claudex worker is not also printed as a SendMessage" "0" "$(printf '%s\n' "$out" | grep -c 'SENDMESSAGE to=DEMO-2')"
check "a worker with no manifest row is skipped, not guessed" "1" "$(printf '%s\n' "$out" | grep -c '^SKIPPED N9')"
# shellcheck disable=SC2016  # the backticks are literal token delimiters
check "no token other than the held ones appears (nothing minted)" "0" "$(printf '%s\n' "$out" | grep -o '`[^`]*`' | grep -vc 'tok-seven\|tok-eight')"
check "the relay never sends LIVE" "0" "$(printf '%s\n' "$out" | grep -c ' LIVE')"
: > "$WORK/bus.body"
bash "$RB" "$DOC" --successor "$WORK/DEMO-nextleg-2026-10-08B-chief.md" --claudex N8 >/dev/null 2>&1; rcp=$?
check "a successor given as its doc path exits 0" "0" "$rcp"
check "a successor given as its doc path is relayed as its session name" "1" "$(grep -c 'SUCCESSION accepted: DEMO-nextleg-2026-10-08B-chief replaces DEMO-nextleg-2026-10-08A-chief$' "$WORK/bus.body")"
check "usage without --successor exits 2" "2" "$(bash "$RB" "$DOC" >/dev/null 2>&1; echo $?)"
# shellcheck disable=SC2016  # $2 expands in the stub, not here
printf '#!/usr/bin/env bash\necho "bus: no edge to $2" >&2; exit 1\n' > "$BUS"
outb="$(bash "$RB" "$DOC" --successor DEMO-nextleg-2026-10-08B-chief --claudex N8 2>&1)"; rcb=$?
check "a refused bus send is reported with its reason" "1" "$(printf '%s\n' "$outb" | grep -c '^BUS-RELAY-FAIL N7 (bus: no edge to DEMO-1-N7-alpha)$')"
check "a refused bus send still prints the SendMessage" "1" "$(printf '%s\n' "$outb" | grep -c '^SENDMESSAGE to=DEMO-1-N7-alpha ::')"
check "a refused bus send does not fail the run" "0" "$rcb"
printf '#!/usr/bin/env bash\nexec sleep 30\n' > "$BUS"
outs="$(RELAY_BATCH_BUS_TIMEOUT=1 bash "$RB" "$DOC" --successor DEMO-nextleg-2026-10-08B-chief --claudex N8 2>&1)"; rcs=$?
check "a stalled bus send is cut off and reported" "1" "$(printf '%s\n' "$outs" | grep -c '^BUS-RELAY-FAIL N7 (timed out after 1s)$')"
check "a stalled bus send still prints the SendMessage" "1" "$(printf '%s\n' "$outs" | grep -c '^SENDMESSAGE to=DEMO-1-N7-alpha ::')"
check "a stalled bus send does not fail the run" "0" "$rcs"
# Four native workers on a stalled bus: every relay prints before any bus send, and the
# sends share one deadline, so the run ends well inside relay-on-live's 60 s kill.
DOC9="$WORK/DEMO-nextleg-2026-10-08E-chief.md"
# shellcheck disable=SC2016  # the backticks are literal Live state markers
printf '# chief\n\n## Live state\n\nlegs: `N50:tok-a:l:1` `N51:tok-b:l:2` `N52:tok-c:l:3` `N53:tok-d:l:4`\nqueue: none\n\n## Results\n' > "$DOC9"
printf '{"schema":1,"legs":[' > "${DOC9%.md}.fleet.json"
for n in 50 51 52 53; do
    : > "$WORK/DEMO-$n-N$n-four.md"
    [ "$n" = 50 ] || printf ',' >> "${DOC9%.md}.fleet.json"
    printf '{"doc":"%s","label":"N%s","lane":"native"}' "$WORK/DEMO-$n-N$n-four.md" "$n" >> "${DOC9%.md}.fleet.json"
done
printf ']}\n' >> "${DOC9%.md}.fleet.json"
census DEMO-50-N50-four DEMO-51-N51-four DEMO-52-N52-four DEMO-53-N53-four
out4="$(RELAY_BATCH_BUS_TIMEOUT=2 timeout 5 bash "$RB" "$DOC9" --successor DEMO-nextleg-2026-10-08F-chief 2>&1)"; rc4=$?
check "four stalled bus sends share one deadline (the run is not killed)" "0" "$rc4"
check "four stalled bus sends: every SENDMESSAGE is printed" "4" "$(printf '%s\n' "$out4" | grep -c '^SENDMESSAGE to=DEMO-5[0-3]-N5[0-3]-four ::')"
check "four stalled bus sends: the tally is printed" "1" "$(printf '%s\n' "$out4" | grep -c '^RELAYED 4 of 4$')"
check "four stalled bus sends: each is reported timed out" "4" "$(printf '%s\n' "$out4" | grep -c '^BUS-RELAY-FAIL N5[0-3] (timed out after 2s)$')"
check "a fallback SendMessage follows the bus sends" "0" "$(printf '%s\n' "$out4" | awk '/^BUS-RELAY/ { exit } /^SENDMESSAGE/ { n++ } END { print n + 0 }')"
census DEMO-1-N7-alpha DEMO-2-N8-beta
printf '%s\n' "$LOGBUS" > "$BUS"
: > "$WORK/bus.log"
outn="$(HIMMEL_BUS_NAME='' bash "$RB" "$DOC" --successor DEMO-nextleg-2026-10-08B-chief --claudex N8 2>&1)"
check "a chief with no bus identity sends no bus record" "" "$(cat "$WORK/bus.log")"
check "a chief with no bus identity prints no BUS-RELAY line" "0" "$(printf '%s\n' "$outn" | grep -c '^BUS-RELAY')"
check "a chief with no bus identity still prints the SendMessage" "1" "$(printf '%s\n' "$outn" | grep -c '^SENDMESSAGE to=DEMO-1-N7-alpha ::')"
check "the payload names the successor" "1" "$(printf '%s\n' "$outn" | grep '^SENDMESSAGE' | grep -c 'your chief is now DEMO-nextleg-2026-10-08B-chief')"
check "the payload quotes the worker's current token" "1" "$(printf '%s\n' "$outn" | grep '^SENDMESSAGE' | grep -c 'tok-seven')"
check "native relay gives the exact acknowledgement with no trailing text" "1" "$(printf '%s\n' "$outn" | grep '^SENDMESSAGE' | grep -c 'SUCCESSION accepted: DEMO-nextleg-2026-10-08B-chief replaces DEMO-nextleg-2026-10-08A-chief$')"
check "the payload no longer asks the worker to verify the relay" "0" "$(printf '%s\n' "$outn" | grep '^SENDMESSAGE' | grep -cF 'Verify this relay')"
check "the payload names itself an S1 relay" "1" "$(printf '%s\n' "$outn" | grep '^SENDMESSAGE' | grep -cF 'S1 relay')"
# shellcheck disable=SC2016  # literal backticks in the pattern
check "the payload quotes only the worker's current token" "\`tok-seven\`" "$(printf '%s\n' "$outn" | grep '^SENDMESSAGE' | grep -o '`[^`]*`' | tr -d '\n')"
check "native relay forbids anything after the acknowledgement on its line" "1" "$(printf '%s\n' "$outn" | grep '^SENDMESSAGE' | grep -cF 'nothing after it on that line')"
# The rows below exercise the SendMessage path: no bus identity from here on.
export HIMMEL_BUS_NAME=
# Each worker's session is resolved from the LIVE process census, never guessed: the full
# doc stem first, then worker_identity's names; exactly one live match or UNRESOLVED.
LEG3="$WORK/DEMO-3-N10-gamma-2026-10-08.md"
LEG4="$WORK/DEMO-4-N11-delta-2026-10-08-RESUME.md"
LEG5="$WORK/DEMO-5-N12-eps.md"
LEG6="$WORK/DEMO-6-N13-eta-2026-10-08.md"
LEG7="$WORK/DEMO-7-N14-zeta-2026-10-08.md"
: > "$LEG3"; : > "$LEG4"; : > "$LEG5"; : > "$LEG6"; : > "$LEG7"
DOC2="$WORK/DEMO-nextleg-2026-10-08C-chief.md"
cat > "$DOC2" <<'EOF2'
# chief

## Live state

legs: `N10:tok-ten:lock10:1` `N11:tok-eleven:lock11:2` `N12:tok-twelve:lock12:3`
`N13:tok-thirteen:lock13:4` `N14:tok-fourteen:lock14:5`
queue: none

## Results
EOF2
# the lane lives in the manifest. mk_fm2 <lane> gives N10-N12 (and N.0) that
# lane; N13/N14 stay native, since a claudex worker skips the census these two exercise.
mk_fm2() { printf '{"schema":1,"legs":[{"doc":"%s","label":"N10","lane":"%s"},{"doc":"%s","label":"N11","lane":"%s"},{"doc":"%s","label":"N12","lane":"%s"},{"doc":"%s","label":"N13","lane":"native"},{"doc":"%s","label":"N14","lane":"native"},{"doc":"%s","label":"N.0","lane":"%s"}]}\n' "$LEG3" "$1" "$LEG4" "$1" "$LEG5" "$1" "$LEG6" "$LEG7" "$LEG5" "$1" > "${DOC2%.md}.fleet.json"; }
mk_fm2 claudex
census DEMO-3-N10-gamma-2026-10-08 DEMO-4-N11-delta-2026-10-08-RESUME DEMO-5-N12-eps DEMO-7-N14-zeta DEMO-7-N14-zeta-2026-10-08 DEMO-unrelated
: > "$WORK/send.log"
out2="$(bash "$RB" "$DOC2" --successor S2 --claudex N10,N11,N12 2>&1)"
check "session equal to the full dated stem is delivered" "1" "$(printf '%s\n' "$out2" | grep -c '^SENT-INBOX N10 (DEMO-3-N10-gamma-2026-10-08)')"
check "session equal to the full -RESUME stem is delivered" "1" "$(printf '%s\n' "$out2" | grep -c '^SENT-INBOX N11 (DEMO-4-N11-delta-2026-10-08-RESUME)')"
check "session equal to the undated name is delivered" "1" "$(printf '%s\n' "$out2" | grep -c '^SENT-INBOX N12 (DEMO-5-N12-eps)')"
check "inbox-send is handed the census-resolved name" "1" "$(grep -c '^DEMO-3-N10-gamma-2026-10-08 ' "$WORK/send.log")"
check "no live match is UNRESOLVED with its candidates" "1" "$(printf '%s\n' "$out2" | grep '^UNRESOLVED N13' | grep -c 'DEMO-6-N13-eta-2026-10-08')"
check "two live matches are UNRESOLVED" "1" "$(printf '%s\n' "$out2" | grep -c '^UNRESOLVED N14')"
check "an unresolved worker is never reported sent" "0" "$(printf '%s\n' "$out2" | grep -c '^SENT-INBOX N1[34]')"
check "an unresolved worker is never handed to inbox-send" "0" "$(grep -c 'tok-thirteen\|tok-fourteen' "$WORK/send.log")"
check "unresolved workers do not fail the run" "0" "$(bash "$RB" "$DOC2" --successor S2 --claudex N10,N11,N12 >/dev/null 2>&1; echo $?)"
mk_fm2 native
out3="$(bash "$RB" "$DOC2" --successor S2 2>&1)"
check "native payload uses the census-resolved full stem" "1" "$(printf '%s\n' "$out3" | grep -c '^SENDMESSAGE to=DEMO-4-N11-delta-2026-10-08-RESUME ::')"
check "an unresolved native worker prints no SendMessage" "0" "$(printf '%s\n' "$out3" | grep -c '^SENDMESSAGE to=DEMO-[67]-')"
check "a manifest worker missing from Live state is reported by literal label" "1" "$(printf '%s\n' "$out2" | grep -c '^NOT-IN-LIVE-STATE N\.0 ')"
mk_fm2 claudex
census DEMO-1-N7-alpha DEMO-2-N8-beta

printf '#!/usr/bin/env bash\nexit 3\n' > "$SEND"
check "a failed claudex delivery exits 1" "1" "$(bash "$RB" "$DOC" --successor S --claudex N8 >/dev/null 2>&1; echo $?)"

# --- the manifest records each worker's lane; --claudex is derived from it.
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "%s/send.log"\n' "$WORK" > "$SEND"
LEGC="$WORK/DEMO-8-N20-codex-2026-10-09.md"; LEGN="$WORK/DEMO-9-N21-nat-2026-10-09.md"
LEGU="$WORK/DEMO-10-N22-unk-2026-10-09.md"; LEGP="$WORK/DEMO-11-P01-pilot-2026-10-09.md"
: > "$LEGC"; : > "$LEGN"; : > "$LEGU"; : > "$LEGP"
DOC4="$WORK/DEMO-nextleg-2026-10-09A-chief.md"
cat > "$DOC4" <<'EOF4'
# chief

## Live state

legs: `N20:tok-twenty:lock20:1` `N21:tok-twentyone:lock21:2` `N22:tok-twentytwo:lock22:3`
queue: none

## Results
EOF4
FM4="${DOC4%.md}.fleet.json"
printf '{"schema":1,"legs":[{"doc":"%s","label":"N20","lane":"claudex"},{"doc":"%s","label":"N21","lane":"native"},{"doc":"%s","label":"N22","lane":"unknown"},{"doc":"%s","label":"P01","lane":"deepseek","lockless":true}]}\n' "$LEGC" "$LEGN" "$LEGU" "$LEGP" > "$FM4"
# the claudex worker is not a `claude -n` process: no census entry for it at all.
census DEMO-9-N21-nat-2026-10-09
: > "$WORK/send.log"
out4="$(bash "$RB" "$DOC4" --successor S4 2>&1)"; rc4=$?
check "no --claudex: a manifest claudex worker is delivered through the inbox" "1" "$(printf '%s\n' "$out4" | grep -c '^SENT-INBOX N20 (DEMO-8-N20-codex-2026-10-09)')"
check "no --claudex: the claudex worker is not relayed as native" "0" "$(printf '%s\n' "$out4" | grep -c 'SENDMESSAGE to=DEMO-8')"
check "a claudex worker is not UNRESOLVED for lacking a claude -n process" "0" "$(printf '%s\n' "$out4" | grep -c '^UNRESOLVED N20')"
check "inbox-send gets the claudex worker's token" "1" "$(grep -c -- '--token tok-twenty --doc '"$LEGC" "$WORK/send.log")"
check "a native-lane worker still gets a printed SendMessage" "1" "$(printf '%s\n' "$out4" | grep -c '^SENDMESSAGE to=DEMO-9-N21-nat-2026-10-09 ::')"
check "lane unknown prints UNRESOLVED-LANE" "1" "$(printf '%s\n' "$out4" | grep -c '^UNRESOLVED-LANE N22')"
check "lane unknown is never relayed as native" "0" "$(printf '%s\n' "$out4" | grep -c 'SENDMESSAGE to=DEMO-10')"
check "lane unknown is never handed to inbox-send" "0" "$(grep -c 'tok-twentytwo' "$WORK/send.log")"
check "UNRESOLVED-LANE does not fail the run" "0" "$rc4"
check "a lockless row has its own explicit section" "1" "$(printf '%s\n' "$out4" | grep -c '^LOCKLESS P01 lane=deepseek doc='"$LEGP")"
check "a lockless row is not listed as NOT-IN-LIVE-STATE" "0" "$(printf '%s\n' "$out4" | grep -c '^NOT-IN-LIVE-STATE P01')"
check "a lockless row is never sent a relay" "0" "$(printf '%s\n' "$out4" | grep -c 'SENDMESSAGE to=.*pilot')"
: > "$WORK/send.log"
out5="$(bash "$RB" "$DOC4" --successor S4 --claudex N20 2>&1)"
check "--claudex that agrees with the manifest relays" "1" "$(printf '%s\n' "$out5" | grep -c '^SENT-INBOX N20')"
out6="$(bash "$RB" "$DOC4" --successor S4 --claudex N20,N21 2>&1)"; rc6=$?
check "--claudex naming a non-claudex manifest worker is refused (rc 1)" "1" "$rc6"
check "a refused --claudex mismatch sends nothing" "0" "$(printf '%s\n' "$out6" | grep -c '^SENT-INBOX\|^SENDMESSAGE')"
out7="$(bash "$RB" "$DOC4" --successor S4 --claudex N99 2>&1)"; rc7=$?
check "--claudex omitting the manifest's claudex worker is refused (rc 1)" "1" "$rc7"
check "the refusal names the disagreement" "1" "$(printf '%s\n' "$out7" | grep -c 'disagrees with the fleet manifest')"
# a non-lockless worker on a lane with no relay path is UNRESOLVED-LANE, never relayed as native
DOC6="$WORK/DEMO-nextleg-2026-10-09C-chief.md"
# shellcheck disable=SC2016  # the backticks are literal Live state markers
printf '# chief\n\n## Live state\n\nlegs: `N30:tok-thirty:lock30:1`\nqueue: none\n\n## Results\n' > "$DOC6"
printf '{"schema":1,"legs":[{"doc":"%s","label":"N30","lane":"deepseek"}]}\n' "$LEGN" > "${DOC6%.md}.fleet.json"
out9="$(bash "$RB" "$DOC6" --successor S6 2>&1)"
check "an unsupported lane is UNRESOLVED-LANE" "1" "$(printf '%s\n' "$out9" | grep -c '^UNRESOLVED-LANE N30 (lane deepseek')"
check "an unsupported lane is never printed as a SendMessage" "0" "$(printf '%s\n' "$out9" | grep -c '^SENDMESSAGE')"
# a chief whose Live state lists no workers but whose manifest has a lockless row still reports it
DOC5="$WORK/DEMO-nextleg-2026-10-09B-chief.md"
printf '# chief\n\n## Live state\n\nlegs: none\nqueue: none\n\n## Results\n' > "$DOC5"
printf '{"schema":1,"legs":[{"doc":"%s","label":"P01","lane":"deepseek","lockless":true}]}\n' "$LEGP" > "${DOC5%.md}.fleet.json"
out8="$(bash "$RB" "$DOC5" --successor S5 2>&1)"; rc8=$?
check "lockless-only chief still lists the lockless row" "1" "$(printf '%s\n' "$out8" | grep -c '^LOCKLESS P01 lane=deepseek')"
check "lockless-only chief exits 0" "0" "$rc8"

# --- b/N3: label collisions and the lockless predicate.
# a lockless row ahead of a locked worker with the same label never drops the worker silently
DOC7="$WORK/DEMO-nextleg-2026-10-09D-chief.md"
# shellcheck disable=SC2016  # the backticks are literal Live state markers
printf '# chief\n\n## Live state\n\nlegs: `N21:tok-twentyone:lock21:2`\nqueue: none\n\n## Results\n' > "$DOC7"
printf '{"schema":1,"legs":[{"doc":"%s","label":"N21","lane":"deepseek","lockless":true},{"doc":"%s","label":"N21","lane":"native"}]}\n' "$LEGP" "$LEGN" > "${DOC7%.md}.fleet.json"
census DEMO-9-N21-nat-2026-10-09
out10="$(bash "$RB" "$DOC7" --successor S7 2>&1)"
check "B1: a locked worker behind a same-label lockless row is still relayed" "1" "$(printf '%s\n' "$out10" | grep -c '^SENDMESSAGE to=DEMO-9-N21-nat-2026-10-09 ::')"
# two locked rows under one label are ambiguous: UNRESOLVED, nothing sent
printf '{"schema":1,"legs":[{"doc":"%s","label":"N21","lane":"native"},{"doc":"%s","label":"N21","lane":"claudex"}]}\n' "$LEGN" "$LEGC" > "${DOC7%.md}.fleet.json"
: > "$WORK/send.log"
out11="$(bash "$RB" "$DOC7" --successor S7 2>&1)"
check "B1: two locked rows with one label print UNRESOLVED" "1" "$(printf '%s\n' "$out11" | grep -c '^UNRESOLVED N21 (2 manifest rows')"
check "B1: an ambiguous label sends nothing" "0 sendlog-bytes=0" "$(printf '%s\n' "$out11" | grep -c '^SENDMESSAGE\|^SENT-INBOX') sendlog-bytes=$(wc -c < "$WORK/send.log" | tr -d ' ')"
# a live entry whose only manifest row is lockless is reported, not skipped silently
printf '{"schema":1,"legs":[{"doc":"%s","label":"N21","lane":"deepseek","lockless":true}]}\n' "$LEGP" > "${DOC7%.md}.fleet.json"
out12="$(bash "$RB" "$DOC7" --successor S7 2>&1)"
check "B1: a live worker whose only row is lockless prints UNRESOLVED" "1" "$(printf '%s\n' "$out12" | grep -c '^UNRESOLVED N21 ')"
# B1b: only the boolean true is lockless; the string "true" stays a visible, relayed row
printf '{"schema":1,"legs":[{"doc":"%s","label":"N21","lane":"native","lockless":"true"}]}\n' "$LEGN" > "${DOC7%.md}.fleet.json"
out13="$(bash "$RB" "$DOC7" --successor S7 2>&1)"
check "B1b: a string true is not lockless: the worker is relayed" "1" "$(printf '%s\n' "$out13" | grep -c '^SENDMESSAGE to=DEMO-9-N21-nat-2026-10-09 ::')"
check "B1b: a string true is not listed as LOCKLESS" "0" "$(printf '%s\n' "$out13" | grep -c '^LOCKLESS')"
# N3: an empty lane is unknown, not the next field
printf '{"schema":1,"legs":[{"doc":"%s","label":"N21","lane":""},{"doc":"%s","label":"P01","lane":"","lockless":true}]}\n' "$LEGN" "$LEGP" > "${DOC7%.md}.fleet.json"
out14="$(bash "$RB" "$DOC7" --successor S7 2>&1)"
check "N3: an empty lane prints UNRESOLVED-LANE unknown" "1" "$(printf '%s\n' "$out14" | grep -c '^UNRESOLVED-LANE N21 (manifest lane unknown')"
check "N3: an empty lockless lane lists as unknown" "1" "$(printf '%s\n' "$out14" | grep -c '^LOCKLESS P01 lane=unknown ')"

# --- a WRAPPED worker (lock free, tail WRAPPED) is neither relayed nor counted; the run ends in n of m.
DOC8="$WORK/DEMO-nextleg-2026-10-20A-chief.md"
LEGW="$WORK/DEMO-12-N40-wrapped-2026-10-20.md"; LEGL="$WORK/DEMO-13-N41-live-2026-10-20.md"; LEGX="$WORK/DEMO-14-N42-gone-2026-10-20.md"
printf '# worker\n\n## Results\n\n- 10:00 LIVE - x\n- 10:30 WRAPPED - done\n' > "$LEGW"
printf '# worker\n\n## Results\n\n- 10:00 LIVE - x\n' > "$LEGL"
printf '# worker\n\n## Results\n\n- 10:00 LIVE - x\n- 10:30 WRAPPED - done\n' > "$LEGX"
# shellcheck disable=SC2016  # the backticks are literal Live state markers
printf '# chief\n\n## Live state\n\nlegs: `N40:tok-forty:lock40:1` `N41:tok-fortyone:lock41:2`\nqueue: none\n\n## Results\n' > "$DOC8"
printf '{"schema":1,"legs":[{"doc":"%s","label":"N40","lane":"native"},{"doc":"%s","label":"N41","lane":"native"},{"doc":"%s","label":"N42","lane":"native"}]}\n' "$LEGW" "$LEGL" "$LEGX" > "${DOC8%.md}.fleet.json"
census DEMO-12-N40-wrapped-2026-10-20 DEMO-13-N41-live-2026-10-20
out15="$(bash "$RB" "$DOC8" --successor S8 2>&1)"; rc15=$?
check "the wrapped-worker relay exits 0" "0" "$rc15"
check "a wrapped worker on Live state is not relayed" "0" "$(printf '%s\n' "$out15" | grep -c 'N40')"
check "a wrapped worker off Live state is not reported" "0" "$(printf '%s\n' "$out15" | grep -c 'N42')"
check "the live worker is relayed" "1" "$(printf '%s\n' "$out15" | grep -c '^SENDMESSAGE to=DEMO-13-N41-live-2026-10-20 ::')"
check "the summary shows n of m with m the live fleet" "1" "$(printf '%s\n' "$out15" | grep -c '^RELAYED 1 of 1$')"
census DEMO-9-N21-nat-2026-10-09
out16="$(bash "$RB" "$DOC4" --successor S4 2>&1)"; rc16=$?
check "the relay with an undeliverable worker exits 0" "0" "$rc16"
check "workers the relay could not deliver count in m but not n" "1" "$(printf '%s\n' "$out16" | grep -c '^RELAYED 2 of 3$')"

# --- a bus relay needs no token, so a manifest worker missing from Live state is relayed too.
DOC10="$WORK/DEMO-nextleg-2026-10-24A-chief.md"
LEGA="$WORK/DEMO-15-N60-in-2026-10-24.md"; LEGB="$WORK/DEMO-16-N61-off-2026-10-24.md"; LEGG="$WORK/DEMO-17-N62-gone-2026-10-24.md"
: > "$LEGA"; : > "$LEGB"; : > "$LEGG"
# shellcheck disable=SC2016  # the backticks are literal Live state markers
printf '# chief\n\n## Live state\n\nlegs: `N60:tok-sixty:lock60:1`\nqueue: none\n\n## Results\n' > "$DOC10"
printf '{"schema":1,"legs":[{"doc":"%s","label":"N60","lane":"native"},{"doc":"%s","label":"N61","lane":"native"},{"doc":"%s","label":"N62","lane":"native"}]}\n' "$LEGA" "$LEGB" "$LEGG" > "${DOC10%.md}.fleet.json"
census DEMO-15-N60-in-2026-10-24 DEMO-16-N61-off-2026-10-24
printf '%s\n' "$LOGBUS" > "$BUS"
: > "$WORK/bus.log"; : > "$WORK/bus.body"
out17="$(HIMMEL_BUS_NAME=DEMO-nextleg-2026-10-24A-chief bash "$RB" "$DOC10" --successor DEMO-nextleg-2026-10-24B-chief 2>&1)"; rc17=$?
check "bus relay of an off-Live-state worker exits 0" "0" "$rc17"
check "a Live-state worker is relayed by bus" "1" "$(grep -cx 'send DEMO-15-N60-in-2026-10-24' "$WORK/bus.log")"
check "a manifest worker missing from Live state is relayed by bus" "1" "$(grep -cx 'send DEMO-16-N61-off-2026-10-24' "$WORK/bus.log")"
check "the off-Live-state bus record carries no token" "0" "$(grep -c 'tok-' "$WORK/bus.body")"
check "no SendMessage is printed when every bus record lands" "0" "$(printf '%s\n' "$out17" | grep -c '^SENDMESSAGE')"
check "a bus-relayed off-Live-state worker is not reported for a hand relay" "0" "$(printf '%s\n' "$out17" | grep -c '^NOT-IN-LIVE-STATE N61 ')"
check "an off-Live-state worker with no live session is left for a hand relay" "1" "$(printf '%s\n' "$out17" | grep -c '^NOT-IN-LIVE-STATE N62 ')"
check "the tally counts both bus relays" "1" "$(printf '%s\n' "$out17" | grep -c '^RELAYED 2 of 3$')"
# shellcheck disable=SC2016  # $2 expands in the stub, not here
printf '#!/usr/bin/env bash\necho "bus: no edge to $2" >&2; exit 1\n' > "$BUS"
out18="$(HIMMEL_BUS_NAME=DEMO-nextleg-2026-10-24A-chief bash "$RB" "$DOC10" --successor DEMO-nextleg-2026-10-24B-chief 2>&1)"; rc18=$?
check "a relay with refused bus records exits 0" "0" "$rc18"
check "a refused bus record falls back to the SendMessage for a Live-state worker" "1" "$(printf '%s\n' "$out18" | grep -c '^SENDMESSAGE to=DEMO-15-N60-in-2026-10-24 :: .*tok-sixty')"
check "a refused bus record leaves an off-Live-state worker for a hand relay" "1" "$(printf '%s\n' "$out18" | grep -c '^NOT-IN-LIVE-STATE N61 ')"
check "an off-Live-state worker is never printed a token-less SendMessage" "0" "$(printf '%s\n' "$out18" | grep -c '^SENDMESSAGE to=DEMO-16-')"
check "the fallback tally counts only the printed relay" "1" "$(printf '%s\n' "$out18" | grep -c '^RELAYED 1 of 3$')"
# a manifest row with no lane keeps its doc in the doc field (tab-separated empty fields do not collapse)
LEGL="$WORK/DEMO-18-N63-nolane-2026-10-24.md"; : > "$LEGL"
printf '{"schema":1,"legs":[{"doc":"%s","label":"N60","lane":"native"},{"doc":"%s","label":"N63"}]}\n' "$LEGA" "$LEGL" > "${DOC10%.md}.fleet.json"
out19="$(HIMMEL_BUS_NAME=DEMO-nextleg-2026-10-24A-chief bash "$RB" "$DOC10" --successor DEMO-nextleg-2026-10-24B-chief 2>&1)"; rc19=$?
check "a relay with a lane-less manifest worker exits 0" "0" "$rc19"
check "a lane-less off-Live-state worker is reported with its own doc" "1" "$(printf '%s\n' "$out19" | grep -cF "NOT-IN-LIVE-STATE N63 ($LEGL)")"
# a live claudex worker missing from Live state gets no bus relay: its relay is the inbox, which needs its token
LEGC="$WORK/DEMO-19-N64-cdx-2026-10-24.md"; : > "$LEGC"
printf '{"schema":1,"legs":[{"doc":"%s","label":"N60","lane":"native"},{"doc":"%s","label":"N64","lane":"claudex"}]}\n' "$LEGA" "$LEGC" > "${DOC10%.md}.fleet.json"
census DEMO-15-N60-in-2026-10-24 DEMO-19-N64-cdx-2026-10-24
printf '%s\n' "$LOGBUS" > "$BUS"; : > "$WORK/bus.log"
out20="$(HIMMEL_BUS_NAME=DEMO-nextleg-2026-10-24A-chief bash "$RB" "$DOC10" --successor DEMO-nextleg-2026-10-24B-chief 2>&1)"; rc20=$?
check "a relay with an off-Live-state claudex worker exits 0" "0" "$rc20"
check "an off-Live-state claudex worker is sent no bus relay" "0" "$(grep -c 'DEMO-19-N64' "$WORK/bus.log")"
check "an off-Live-state claudex worker is left for a hand relay" "1" "$(printf '%s\n' "$out20" | grep -c '^NOT-IN-LIVE-STATE N64 ')"
# a Live state that lists no worker still relays the manifest's locked workers
DOC11="$WORK/DEMO-nextleg-2026-10-24C-chief.md"
printf '# chief\n\n## Live state\n\nlegs: none\nqueue: none\n\n## Results\n' > "$DOC11"
printf '{"schema":1,"legs":[{"doc":"%s","label":"N61","lane":"native"}]}\n' "$LEGB" > "${DOC11%.md}.fleet.json"
census DEMO-16-N61-off-2026-10-24
: > "$WORK/bus.log"
out21="$(HIMMEL_BUS_NAME=DEMO-nextleg-2026-10-24C-chief bash "$RB" "$DOC11" --successor DEMO-nextleg-2026-10-24D-chief 2>&1)"; rc21=$?
check "a relay with an empty Live state exits 0" "0" "$rc21"
check "an empty Live state still bus-relays a manifest worker" "1" "$(grep -cx 'send DEMO-16-N61-off-2026-10-24' "$WORK/bus.log")"
check "an empty Live state tallies the manifest worker" "1" "$(printf '%s\n' "$out21" | grep -c '^RELAYED 1 of 1$')"

# --- --fresh <label>=<token> puts the successor's fresh token next to the
# held one, in the native SendMessage line and the claudex inbox relay (never in a bus record).
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "%s/send.log"\n' "$WORK" > "$SEND"
printf '%s\n' "$LOGBUS" > "$BUS"
census DEMO-1-N7-alpha DEMO-2-N8-beta
: > "$WORK/send.log"; : > "$WORK/bus.log"; : > "$WORK/bus.body"
outf="$(HIMMEL_BUS_NAME='' bash "$RB" "$DOC" --successor S9 --fresh N7=fresh-seven --fresh N8=fresh-eight 2>&1)"; rcf=$?
check "--fresh: the run succeeds" "0" "$rcf"
check "--fresh: a native SENDMESSAGE line quotes the held and the fresh token" "1" "$(printf '%s\n' "$outf" | grep '^SENDMESSAGE to=DEMO-1-N7-alpha ::' | grep 'tok-seven' | grep -c 'fresh-seven')"
check "--fresh: the claudex inbox relay quotes the held and the fresh token" "1" "$(grep -- '--token tok-eight' "$WORK/send.log" | grep -c 'fresh-eight')"
check "--fresh: a worker given no fresh token is relayed as before" "0" "$(printf '%s\n' "$outf" | grep '^SENDMESSAGE to=DEMO-1-N7-alpha ::' | grep -c 'fresh-eight')"
# a bus record carries no token, so a native worker owed a fresh token is sent the SendMessage instead
outfb="$(HIMMEL_BUS_NAME=DEMO-nextleg-2026-10-08A-chief bash "$RB" "$DOC" --successor S9 --fresh N7=fresh-seven --fresh N8=fresh-eight 2>&1)"
check "--fresh: a native worker owed a fresh token gets the SendMessage, not a bus record" "1" "$(printf '%s\n' "$outfb" | grep '^SENDMESSAGE to=DEMO-1-N7-alpha ::' | grep -c 'fresh-seven')"
check "--fresh: that worker is sent no bus record" "0" "$(grep -cx 'send DEMO-1-N7-alpha' "$WORK/bus.log")"
check "--fresh: the claudex bus record is still sent" "1" "$(grep -cx 'send DEMO-2-N8-beta' "$WORK/bus.log")"
check "--fresh: no bus record carries a token" "0" "$(grep -c 'tok-\|fresh-' "$WORK/bus.body")"
check "--fresh: a fresh token naming no relayed worker is reported" "1" "$(HIMMEL_BUS_NAME='' bash "$RB" "$DOC" --successor S9 --fresh N99=fresh-x 2>&1 | grep -c '^FRESH-UNUSED N99 ')"
check "--fresh: a value with no label=token shape is a usage error" "2" "$(bash "$RB" "$DOC" --successor S9 --fresh nonsense >/dev/null 2>&1; echo $?)"
# the claudex bus record follows its own inbox relay at once, not after the whole loop
ORDER="$WORK/order.log"; : > "$ORDER"
OSEND="$WORK/osend.sh"; OBUS="$WORK/obus.sh"
# shellcheck disable=SC2016  # $1 expands in the stub, not here
printf '#!/usr/bin/env bash\nprintf "inbox %%s\\n" "$1" >> "%s"\n' "$ORDER" > "$OSEND"
# shellcheck disable=SC2016  # $2 expands in the stub, not here
printf '#!/usr/bin/env bash\nprintf "bus %%s\\n" "$2" >> "%s"\n' "$ORDER" > "$OBUS"
chmod +x "$OBUS"
LEGQ1="$WORK/DEMO-20-N70-cdxa-2026-10-27.md"; LEGQ2="$WORK/DEMO-21-N71-cdxb-2026-10-27.md"; : > "$LEGQ1"; : > "$LEGQ2"
DOC12="$WORK/DEMO-nextleg-2026-10-27A-chief.md"
# shellcheck disable=SC2016  # the backticks are literal Live state markers
printf '# chief\n\n## Live state\n\nlegs: `N70:tok-a:l:1` `N71:tok-b:l:2`\nqueue: none\n\n## Results\n' > "$DOC12"
printf '{"schema":1,"legs":[{"doc":"%s","label":"N70","lane":"claudex"},{"doc":"%s","label":"N71","lane":"claudex"}]}\n' "$LEGQ1" "$LEGQ2" > "${DOC12%.md}.fleet.json"
INBOX_SEND="$OSEND" RELAY_BATCH_BUS="$OBUS" HIMMEL_BUS_NAME=DEMO-nextleg-2026-10-27A-chief bash "$RB" "$DOC12" --successor S9 >/dev/null 2>&1
check "a claudex bus record is sent right after its inbox relay, before the next worker" "inbox DEMO-20-N70-cdxa-2026-10-27 bus DEMO-20-N70-cdxa-2026-10-27 inbox DEMO-21-N71-cdxb-2026-10-27 bus DEMO-21-N71-cdxb-2026-10-27" "$(tr '\n' ' ' < "$ORDER" | sed 's/ $//')"
# a stalled bus store spends the shared deadline once: later notices are skipped, not each given a second
: > "$ORDER"
OSLOW="$WORK/oslow.sh"
# shellcheck disable=SC2016  # $2 expands in the stub, not here
printf '#!/usr/bin/env bash\nprintf "bus %%s\\n" "$2" >> "%s"\nsleep 5\n' "$ORDER" > "$OSLOW"
chmod +x "$OSLOW"
outslow="$(INBOX_SEND="$OSEND" RELAY_BATCH_BUS="$OSLOW" RELAY_BATCH_BUS_TIMEOUT=1 HIMMEL_BUS_NAME=DEMO-nextleg-2026-10-27A-chief bash "$RB" "$DOC12" --successor S9 2>&1)"
check "a spent bus deadline skips the later notices" "1" "$(grep -c '^bus ' "$ORDER")"
check "a skipped notice is reported" "1" "$(printf '%s\n' "$outslow" | grep -c '^BUS-RELAY-FAIL N71 (bus deadline spent)')"
check "--fresh: a repeated label is a usage error" "2" "$(bash "$RB" "$DOC" --successor S9 --fresh N7=fresh-a --fresh N7=fresh-b >/dev/null 2>&1; echo $?)"
# a run disarms the chief's relay-on-live marker for its successor, so a hand or --fresh run and the waiter never relay twice
ROL="$BRIDGE_ROOT/consoles/DEMO-nextleg-2026-10-08A-chief.md.relay-on-live"
mkdir -p "$BRIDGE_ROOT/consoles"
printf 'DEMO-nextleg-2026-10-08B-chief\n%s\n' "$WORK/DEMO-nextleg-2026-10-08B-chief.md" > "$ROL"
bash "$RB" "$DOC" --successor DEMO-nextleg-2026-10-08B-chief >/dev/null 2>&1
check "a run for the marker's successor removes the relay-on-live marker" "no" "$([ -f "$ROL" ] && echo yes || echo no)"
printf 'DEMO-nextleg-2026-10-08B-chief\n%s\n' "$WORK/DEMO-nextleg-2026-10-08B-chief.md" > "$ROL"
bash "$RB" "$DOC" --successor DEMO-nextleg-2026-10-08C-chief >/dev/null 2>&1
check "a run for another successor leaves the marker armed" "yes" "$([ -f "$ROL" ] && echo yes || echo no)"
rm -f "$ROL"
check "a run with no marker still succeeds" "0" "$(bash "$RB" "$DOC" --successor DEMO-nextleg-2026-10-08B-chief >/dev/null 2>&1; echo $?)"

if [ "$fails" -eq 0 ]; then echo "ALL PASS"; else echo "$fails FAILED"; exit 1; fi
