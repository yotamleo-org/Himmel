#!/usr/bin/env bash
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
OWE="${OWE_SH:-$HERE/owe.sh}"

fails=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; fails=$((fails + 1)); }
check() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (got '$2', want '$3')"; fi; }
contains() { case "$2" in *"$3"*) pass "$1" ;; *) fail "$1 (no '$3' in '$2')" ;; esac; }
lacks() { case "$2" in *"$3"*) fail "$1 ('$3' in '$2')" ;; *) pass "$1" ;; esac; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/owe-test.XXXXXX")" || { echo "mktemp -d failed" >&2; exit 1; }
trap 'rm -rf "$WORK"' EXIT
B="$WORK/bucket"; mkdir -p "$B"
F="$B/owed.jsonl"
NOW=1800000000
export OWE_NOW_EPOCH=$NOW

out="$(bash "$OWE" add --bucket "$B" --chief Z --kind ticket --text 'file the fold bug' 2>&1)"; rc=$?
check "add ticket exits 0" "$rc" "0"
check "add prints the new id" "$out" "o1"
check "one row written" "$(wc -l < "$F" | tr -d ' ')" "1"
check "row kind" "$(jq -r .kind "$F")" "ticket"
check "row chief" "$(jq -r .chief "$F")" "Z"
check "row text" "$(jq -r .text "$F")" "file the fold bug"
check "ticket row has no key" "$(jq -r '.key // "none"' "$F")" "none"
check "row ts is UTC ISO" "$(jq -r .ts "$F")" "2027-01-15T08:00:00Z"
check "row epoch" "$(jq -r .epoch "$F")" "$NOW"

bash "$OWE" add --bucket "$B" --chief Z --kind bogus --text x >/dev/null 2>&1; rc=$?
check "an unknown kind exits 2" "$rc" "2"
bash "$OWE" add --bucket "$B" --chief Z --kind ticket --text '' >/dev/null 2>&1; rc=$?
check "an empty text exits 2" "$rc" "2"
bash "$OWE" add --bucket "$B" --chief Z --kind ticket --text $'two\nlines' >/dev/null 2>&1; rc=$?
check "a multi-line text exits 2" "$rc" "2"
bash "$OWE" add --bucket "$WORK/absent" --chief Z --kind ticket --text x >/dev/null 2>&1; rc=$?
check "an absent bucket exits 3" "$rc" "3"
check "refusals append nothing" "$(wc -l < "$F" | tr -d ' ')" "1"

bash "$OWE" add --bucket "$B" --chief Z --kind proof --text $'live "succession"\tproof' >/dev/null
check "second id" "$(jq -r .id < <(sed -n 2p "$F"))" "o2"
check "a quote and a tab survive in the row" "$(jq -r .text < <(sed -n 2p "$F"))" $'live "succession"\tproof'

list="$(bash "$OWE" list --bucket "$B")"
check "list shows both open rows" "$(printf '%s\n' "$list" | wc -l | tr -d ' ')" "2"
check "list row one" "$(printf '%s\n' "$list" | sed -n 1p)" "$(printf 'o1\tticket\t%s\t\tZ\tfile the fold bug' "$NOW")"
lacks "a tab in the text is flattened in list" "$(printf '%s\n' "$list" | sed -n 2p | cut -f6)" $'\t'

before="$(cat "$F")"
bash "$OWE" close --bucket "$B" --id o1 >/dev/null 2>&1; rc=$?
check "close without a key exits 2" "$rc" "2"
bash "$OWE" close --bucket "$B" --id o1 --key '' >/dev/null 2>&1; rc=$?
check "close with an empty key exits 2" "$rc" "2"
bash "$OWE" close --bucket "$B" --id o9 --key HIMMEL-1 >/dev/null 2>&1; rc=$?
check "close of an unknown id exits 1" "$rc" "1"
check "refused closes append nothing" "$(cat "$F")" "$before"

bash "$OWE" close --bucket "$B" --id o1 --key HIMMEL-10099 >/dev/null; rc=$?
check "close with a key exits 0" "$rc" "0"
check "earlier rows are byte-identical after a close" "$(head -n 2 "$F")" "$before"
check "the close is a new last row" "$(wc -l < "$F" | tr -d ' ')" "3"
check "closing row key" "$(sed -n 3p "$F" | jq -r .key)" "HIMMEL-10099"
check "closing row names its target" "$(sed -n 3p "$F" | jq -r .ref)" "o1"
list="$(bash "$OWE" list --bucket "$B")"
check "list drops the closed row" "$(printf '%s\n' "$list" | cut -f1)" "o2"
all="$(bash "$OWE" list --bucket "$B" --all)"
contains "list --all keeps the closed row with its key" "$all" "$(printf 'o1\tticket\t%s\tHIMMEL-10099\tZ' "$NOW")"
bash "$OWE" close --bucket "$B" --id o1 --key HIMMEL-10099 >/dev/null 2>&1; rc=$?
check "closing a closed row exits 1" "$rc" "1"

K3=HIMMEL-3
JIRA_STUB="$WORK/jira-stub"
cat > "$JIRA_STUB" <<'STUB'
#!/bin/sh
echo "$*" >> "$STUB_DIR/calls.log"
case "$1" in
    comment) [ -z "${STUB_FAIL:-}" ] || exit 1; [ -n "${STUB_DROP:-}" ] || printf '%s\n' "$3" >> "$STUB_DIR/comments.$2" ;;
    comments) cat "$STUB_DIR/comments.$2" 2>/dev/null; exit 0 ;;
esac
STUB
chmod +x "$JIRA_STUB"
export OWE_JIRA_CLI="$JIRA_STUB" STUB_DIR="$WORK"
before="$(cat "$F")"
out="$(bash "$OWE" close --bucket "$B" --id o2 --key 0123abc 2>&1)"; rc=$?
check "10911 a proof row closed with no PROOF flags exits 2" "$rc" "2"
contains "10911 the refusal names the PROOF form" "$out" "PROOF <row-id> PASS|FAIL"
check "10911 the refused proof close appends nothing" "$(cat "$F")" "$before"
bash "$OWE" close --bucket "$B" --id o2 --key 0123abc --proof-result PASS --proof-artifact doc:706 >/dev/null 2>&1; rc=$?
check "10911 a proof row with no ticket key and no --ticket exits 2" "$rc" "2"
bash "$OWE" close --bucket "$B" --id o2 --key 0123abc --proof-result MAYBE --proof-artifact doc:706 --ticket HIMMEL-3 >/dev/null 2>&1; rc=$?
check "10911 a result that is not PASS or FAIL exits 2" "$rc" "2"
bash "$OWE" close --bucket "$B" --id o2 --key 0123abc --proof-result PASS --proof-artifact 'two words' --ticket HIMMEL-3 >/dev/null 2>&1; rc=$?
check "10911 an artifact of two words exits 2" "$rc" "2"
check "10911 nothing was posted by a refusal" "$(cat "$WORK/calls.log" 2>/dev/null)" ""
STUB_FAIL=1 bash "$OWE" close --bucket "$B" --id o2 --key 0123abc --proof-result PASS --proof-artifact doc:706 --ticket HIMMEL-3 >/dev/null 2>&1; rc=$?
check "10911 a comment the CLI refuses exits 5" "$rc" "5"
check "10911 the row stays open after a refused comment" "$(bash "$OWE" list --bucket "$B" | cut -f1)" "o2"
STUB_DROP=1 bash "$OWE" close --bucket "$B" --id o2 --key 0123abc --proof-result PASS --proof-artifact doc:706 --ticket HIMMEL-3 >/dev/null 2>&1; rc=$?
check "10911 a comment the read-back cannot find exits 5" "$rc" "5"
check "10911 the row stays open after a failed read-back" "$(bash "$OWE" list --bucket "$B" | cut -f1)" "o2"
rm -f "$WORK/calls.log"
bash "$OWE" close --bucket "$B" --id o2 --key 0123abc --proof-result PASS --proof-artifact doc:706 --ticket HIMMEL-3 >/dev/null; rc=$?
check "10911 a proof closes with its PROOF comment" "$rc" "0"
check "10911 the close wrote the PROOF line on the ticket" "$(cat "$WORK/comments.$K3")" "PROOF o2 PASS 2027-01-15 doc:706"
check "10911 the close row carries the key" "$(tail -n 1 "$F" | jq -r '.op + " " + .ref + " " + .key')" "close o2 0123abc"
check "nothing is open" "$(bash "$OWE" list --bucket "$B")" ""
P="$WORK/p-bucket"; mkdir -p "$P"
bash "$OWE" add --bucket "$P" --chief Z --kind proof --key HIMMEL-3 --text 'live proof' >/dev/null
bash "$OWE" add --bucket "$P" --chief Z --kind step --key HIMMEL-3 --text 'proof by 2027-02-01' --metadata '{"actor":"proof"}' >/dev/null
bash "$OWE" close --bucket "$P" --id o1 --key 0123abc --proof-result FAIL --proof-artifact specs/audits/x.md >/dev/null 2>&1; rc=$?
check "10911 the ticket comes from the row key and FAIL closes too" "$rc" "0"
check "10911 the FAIL line is on the row's ticket" "$(tail -n 1 "$WORK/comments.$K3")" "PROOF o1 FAIL 2027-01-15 specs/audits/x.md"
bash "$OWE" close --bucket "$P" --id o2 --key HIMMEL-3 >/dev/null 2>&1; rc=$?
check "10911 a proof step closed by the chief's discharge needs no PROOF flags" "$rc" "0"
bash "$OWE" add --bucket "$P" --chief Z --kind proof --key HIMMEL-3 --text 'again' >/dev/null
printf 'PROOF o3 PASS 2027-01-15 doc:1\n' >> "$WORK/comments.HIMMEL-3"; rm -f "$WORK/calls.log"
bash "$OWE" close --bucket "$P" --id o3 --key 0123abc --proof-result PASS --proof-artifact doc:1 >/dev/null 2>&1; rc=$?
check "10911 a close whose PROOF line is already on the ticket exits 0" "$rc" "0"
check "10911 and it posts nothing a second time" "$(grep -c '^comment ' "$WORK/calls.log")" "0"
unset OWE_JIRA_CLI STUB_DIR

bash "$OWE" add --bucket "$B" --chief $'Z\tX' --kind ticket --text x >/dev/null 2>&1; rc=$?
check "a tab in --chief exits 2" "$rc" "2"
bash "$OWE" add --bucket "$B" --chief $'Z\nX' --kind ticket --text x >/dev/null 2>&1; rc=$?
check "a newline in --chief exits 2" "$rc" "2"

bash "$OWE" add --bucket "$B" --chief $'Z\037X' --kind ticket --text x >/dev/null 2>&1; rc=$?
check "a unit separator in --chief exits 2" "$rc" "2"
bash "$OWE" add --bucket "$B" --chief Z --kind ticket --text $'a\037b' >/dev/null 2>&1; rc=$?
check "a unit separator in --text exits 2" "$rc" "2"

NF="$WORK/noflock-bin"; mkdir -p "$NF"
for _t in jq date sh rm sleep mktemp dirname bash python3; do ln -s "$(command -v "$_t")" "$NF/$_t"; done
NB="$WORK/noflock"; mkdir -p "$NB"
PATH="$NF" "$(command -v bash)" "$OWE" add --bucket "$NB" --chief Z --kind ticket --text x >/dev/null 2>&1; rc=$?
check "an add on a host with no flock locks through with_lock and exits 0" "$rc" "0"
check "and writes one row" "$(wc -l < "$NB/owed.jsonl" | tr -d ' ')" "1"
check "and removes its lock file" "$([ -e "$NB/owed.jsonl.lock" ] && echo present || echo absent)" "absent"
NC="$WORK/noflock-concurrent"; mkdir -p "$NC"
for _n in 1 2 3 4 5 6; do PATH="$NF" "$(command -v bash)" "$OWE" add --bucket "$NC" --chief Z --kind ticket --text "row $_n" >/dev/null 2>&1 & done
wait
check "six concurrent no-flock adds get six distinct ids" "$(jq -r .id "$NC/owed.jsonl" | sort -u | wc -l | tr -d ' ')" "6"

C="$WORK/concurrent"; mkdir -p "$C"
for _n in 1 2 3 4 5 6 7 8; do bash "$OWE" add --bucket "$C" --chief Z --kind ticket --text "row $_n" >/dev/null & done
wait
check "eight concurrent adds write eight rows" "$(wc -l < "$C/owed.jsonl" | tr -d ' ')" "8"
check "eight concurrent adds get eight distinct ids" "$(jq -r .id "$C/owed.jsonl" | sort -u | wc -l | tr -d ' ')" "8"
bash "$OWE" close --bucket "$C" --id o3 --key HIMMEL-1 >/dev/null 2>&1; rc=$?
check "a row added concurrently can be closed" "$rc" "0"

check "an empty bucket lists nothing" "$(mkdir -p "$WORK/empty" && bash "$OWE" list --bucket "$WORK/empty"; echo "rc=$?")" "rc=0"

# Durable typed proof actions share the existing writer and lock.
I="$WORK/identity"; mkdir -p "$I"
identity=$(printf proof | sha256sum | cut -d' ' -f1)
meta='{"actor":"chief","action":"validate-proof","validation":"pending","recommendation":"CLOSE"}'
for _n in 1 2 3 4 5 6 7 8; do
    bash "$OWE" add --bucket "$I" --chief Z --kind proof --key HIMMEL-9848 --text validate --identity "$identity" --metadata "$meta" > "$WORK/id.$_n" 2>&1 &
done
wait
check "9848 concurrent identical adds create one action" "$(wc -l < "$I/owed.jsonl" 2>/dev/null | tr -d ' ')" 1
check "9848 all responses return same id" "$(sort -u "$WORK"/id.*)" o1
bash "$OWE" close --bucket "$I" --id o1 --key HIMMEL-9848 >/dev/null 2>&1
OWE_NOW_EPOCH=1800000900 bash "$OWE" add --bucket "$I" --chief successor --kind proof --key HIMMEL-9848 --text replay --identity "$identity" --metadata "$meta" >/dev/null 2>&1
check "9848 replay never reopens closed action" "$(bash "$OWE" list --bucket "$I")" ""
check "9848 replay appends nothing" "$(wc -l < "$I/owed.jsonl" | tr -d ' ')" 2
out=$(bash "$OWE" list --bucket "$I" --all --json 2>/dev/null)
check "9848 JSON retains actor and closure" "$(printf '%s' "$out" | jq -r '.[0] | [.actor,.action,.closed] | @tsv' 2>/dev/null)" $'chief\tvalidate-proof\ttrue'
bash "$OWE" add --bucket "$I" --chief Z --kind proof --text no --metadata '{"unknown":1}' >/dev/null 2>&1
check "9848 unknown metadata field refuses" "$?" 2
for meta in '{"op":"close"}' '{"actor":"operator"}' '{"validation":"passed"}' '{"issues":"hidden"}'; do
    bash "$OWE" add --bucket "$I" --chief Z --kind proof --text no --metadata "$meta" >/dev/null 2>&1
    check "9848 reserved or malformed metadata refuses: $meta" "$?" 2
done
bash "$OWE" add --bucket "$I" --chief Z --kind proof --text no --identity 0123456789ab >/dev/null 2>&1
check "9848 truncated identity refuses" "$?" 2
check "9848 legacy list stays six columns" "$(bash "$OWE" list --bucket "$I" --all | awk -F '\t' '{print NF}')" 6

# Simulate a sync failure after a successful append: no success response, and
# the next writer must sync/reuse the existing action rather than append again.
S="$WORK/sync-fail"; mkdir -p "$S/bin" "$S/bucket"
printf '#!/bin/sh\nexit 1\n' > "$S/bin/python3"; chmod +x "$S/bin/python3"
out=$(PATH="$S/bin:$PATH" bash "$OWE" add --bucket "$S/bucket" --chief Z --kind proof --text pending --identity "$identity" 2>/dev/null); rc=$?
check "9848 fsync failure returns persistence error" "$rc" 4
check "9848 fsync failure acknowledges no id" "$out" ""
out=$(bash "$OWE" add --bucket "$S/bucket" --chief successor --kind proof --text replay --identity "$identity")
check "9848 retry after sync failure returns existing id" "$out" o1
check "9848 retry after sync failure appends nothing" "$(wc -l < "$S/bucket/owed.jsonl" | tr -d ' ')" 1

PW="$WORK/proof-wake"; mkdir -p "$PW"
out=$(bash "$OWE" add --bucket "$PW" --chief chief --kind ruling --text 'HIMMEL-77 proof-wake' --metadata '{"actor":"chief","action":"notify","event":"proof-wake"}' 2>&1); rc=$?
check "10955 a proof-wake notification is an accepted event" "$rc|$out" "0|o1"
bash "$OWE" add --bucket "$PW" --chief chief --kind ruling --text 'bad event' --metadata '{"actor":"chief","action":"notify","event":"proof-launch"}' >/dev/null 2>&1
check "10955 an unknown event is still refused" "$?" 2

L="$WORK/bad-ledger"; mkdir -p "$L"
ln -s "$L/absent" "$L/owed.jsonl"
bash "$OWE" list --bucket "$L" --json >/dev/null 2>&1
check "9848 dangling ledger is unreadable, not empty" "$?" 4

M="$WORK/metadata-stdin"; mkdir -p "$M"
python3 - "$M/large.json" <<'PY'
import json,sys
with open(sys.argv[1], 'w') as stream:
    json.dump({'proof_rows': ['x' * 200000]}, stream)
PY
out=$(bash "$OWE" add --bucket "$M" --chief Z --kind proof --text observations --metadata-stdin < "$M/large.json" 2>/dev/null); rc=$?
check "metadata stdin avoids the per-argument byte limit" "$rc|$out" "0|o1"
check "metadata stdin retains every supplied observation byte" "$(jq -r '.proof_rows[0] | length' "$M/owed.jsonl" 2>/dev/null)" 200000
for meta in '{"op":"close"}' '{"actor":"operator"}' '{"validation":"passed"}' '{"observation_counts":{"issues":{"total":1,"omitted":2,"truncated_chars":0}}}' '{"observation_counts":{"unknown":{"total":1,"omitted":0,"truncated_chars":0}}}'; do
    printf '%s' "$meta" | bash "$OWE" add --bucket "$M" --chief Z --kind proof --text invalid --metadata-stdin >/dev/null 2>&1
    check "stdin retains reserved-key and count-shape protection: $meta" "$?" 2
done
printf '{}' | bash "$OWE" add --bucket "$M" --chief Z --kind proof --text invalid --metadata '{}' --metadata-stdin >/dev/null 2>&1
check "metadata arguments and stdin are mutually exclusive" "$?" 2
python3 - "$M/oversize.json" <<'PY'
import json,sys
with open(sys.argv[1], 'w') as stream:
    json.dump({'proof_rows': ['x' * 1048576]}, stream)
PY
bash "$OWE" add --bucket "$M" --chief Z --kind proof --text oversize --metadata-stdin < "$M/oversize.json" >/dev/null 2>&1
check "stdin metadata has a fixed byte bound" "$?" 2
bash "$OWE" add --bucket "$M" --chief Z --kind proof --text multivalue --metadata '{}{}' >/dev/null 2>&1
check "legacy metadata still refuses multiple top-level values" "$?" 2
check "refused metadata never appends an action" "$(wc -l < "$M/owed.jsonl" 2>/dev/null | tr -d ' ')" 1

mkroute() {
    mkdir -p "$1/etc/himmel" "$1/usr/local/libexec/himmel/ops"
    printf '{"enabled": true, "ops": {"enabled": true}, "helper_update": {"enabled": %s, "checkout": "/x", "repo": "a/b"}}\n' "$2" > "$1/etc/himmel/afk-sudo.json"
    [ "$3" = yes ] && : > "$1/usr/local/libexec/himmel/ops/docker.sh"
    return 0
}
OT="$WORK/op-route"; mkdir -p "$OT"
OPTXT='Live proof (op-request docker action=start): owed to operator by 2026-12-08'
OPMETA='{"actor":"operator"}'
RID=$(printf r2 | sha256sum | cut -d' ' -f1)
mkroute "$WORK/r-off" false no; mkroute "$WORK/r-on" true yes; mkroute "$WORK/r-hu-on-no-op" true no
out=$(OWE_AFKSUDO_ROOT="$WORK/r-off" bash "$OWE" add --bucket "$OT" --chief Z --kind step --text "$OPTXT" --metadata "$OPMETA" 2>&1); rc=$?
check "10970 R1 a dead op route refuses with exit 2" "$rc" 2
contains "10970 R1 prints the route's failure line" "$out" "helper_update is not enabled in the config"
contains "10970 R1 prints the one unblocking command" "$out" "sudoedit /etc/himmel/afk-sudo.json"
check "10970 R1 appends nothing" "$(wc -l < "$OT/owed.jsonl" 2>/dev/null | tr -d ' ')" 0
out=$(OWE_AFKSUDO_ROOT="$WORK/r-hu-on-no-op" bash "$OWE" add --bucket "$OT" --chief Z --kind step --text "$OPTXT" --metadata "$OPMETA" 2>&1); rc=$?
check "10970 R1b op not installed with helper_update on refuses" "$rc" 2
contains "10970 R1b names the missing op" "$out" "docker"
out=$(OWE_AFKSUDO_ROOT="$WORK/r-on" bash "$OWE" add --bucket "$OT" --chief Z --kind step --text "$OPTXT" --identity "$RID" --metadata "$OPMETA" 2>&1); rc=$?
check "10970 R2 control: an enabled route with the op installed is accepted" "$rc|$out" "0|o1"
out=$(OWE_AFKSUDO_ROOT="$WORK/r-off" bash "$OWE" add --bucket "$OT" --chief Z --kind step --text "$OPTXT" --identity "$RID" --metadata "$OPMETA" 2>&1); rc=$?
check "10970 R2c a replay of an existing row returns its id even when the route is now dead" "$rc|$out" "0|o1"
out=$(OWE_AFKSUDO_ROOT="$WORK/r-off" bash "$OWE" add --bucket "$OT" --chief Z --kind step --text "$OPTXT" --metadata '{"actor":"chief"}' 2>&1); rc=$?
check "10970 R3 a row owed to anyone but the operator is not probed" "$rc" 0
out=$(OWE_AFKSUDO_ROOT="$WORK/r-off" bash "$OWE" add --bucket "$OT" --chief Z --kind step --text 'owed to operator: sudoedit the config' --metadata "$OPMETA" 2>&1); rc=$?
check "10970 R3b an operator row with no op-request route is not probed" "$rc" 0
mkdir -p "$WORK/r-bad/etc/himmel"; printf 'not json' > "$WORK/r-bad/etc/himmel/afk-sudo.json"
out=$(OWE_AFKSUDO_ROOT="$WORK/r-bad" bash "$OWE" add --bucket "$OT" --chief Z --kind step --text "$OPTXT" --metadata "$OPMETA" 2>&1); rc=$?
check "10970 R4 an unreadable config refuses" "$rc" 2
contains "10970 R4 prints the unknown line" "$out" "route unknown"
mkdir -p "$WORK/r-empty/etc/himmel/../../usr/local/libexec/himmel/ops"; : > "$WORK/r-empty/etc/himmel/afk-sudo.json"; : > "$WORK/r-empty/usr/local/libexec/himmel/ops/docker.sh"
out=$(OWE_AFKSUDO_ROOT="$WORK/r-empty" bash "$OWE" add --bucket "$OT" --chief Z --kind step --text "$OPTXT" --metadata "$OPMETA" 2>&1); rc=$?
check "10970 R4b an empty config with the op installed refuses as unknown" "$rc" 2

mkroute "$WORK/r-hu" false no; : > "$WORK/r-hu/usr/local/libexec/himmel/ops/helper-update.sh"
out=$(OWE_AFKSUDO_ROOT="$WORK/r-hu" bash "$OWE" add --bucket "$OT" --chief Z --kind step --text 'proof (op-request helper-update commit=abc): owed' --metadata "$OPMETA" 2>&1); rc=$?
check "10970 R5 op helper-update with helper_update off refuses even though the op is installed" "$rc" 2
contains "10970 R5 prints the helper_update line" "$out" "helper_update is not enabled in the config"
out=$(OWE_AFKSUDO_ROOT="$WORK/r-on" bash "$OWE" add --bucket "$OT" --chief Z --kind step --text 'op-request docker a=1 then op-request ghost b=2' --metadata "$OPMETA" 2>&1); rc=$?
check "10970 R6 a row naming several ops probes each of them" "$rc" 2
contains "10970 R6 names the uninstalled second op" "$out" "ghost"
for spelled in 'op-request --session S --ticket T docker action=start' 'op-request -- docker action=start' 'op-request --session S -- docker'; do
    OWE_AFKSUDO_ROOT="$WORK/r-off" bash "$OWE" add --bucket "$OT" --chief Z --kind step --text "proof ($spelled): owed" --metadata "$OPMETA" >/dev/null 2>&1
    check "10970 R7 the documented spelling is probed: $spelled" "$?" 2
done
out=$(OWE_AFKSUDO_ROOT="$WORK/r-off" bash "$OWE" add --bucket "$OT" --chief Z --kind step --text 'ask for an op-request for docker later' --metadata "$OPMETA" 2>&1); rc=$?
check "10970 R8 prose after op-request is not read as an op name" "$rc" 0

[ "$fails" -eq 0 ] || { echo "$fails check(s) failed"; exit 1; }
echo "test-owe: all checks passed"
