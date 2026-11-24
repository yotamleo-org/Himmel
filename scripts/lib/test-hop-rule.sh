#!/usr/bin/env bash
# scripts/lib/test-hop-rule.sh - hermetic suite for hop_rule.py and the one-hour write weight.
# No transcript, no launch, no network: the rule is a pure function of its arguments.
#  1. rule-table: a fixed table of inputs and answers, by the command's exit code;
#  2. rule-weights: r is the owner's cache_read_weight, and an unknown model has no answer;
#  3. rule-1h-weight: burn-weights.sh and burn_weights.py own the one-hour write weight.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
HR="$HERE/hop_rule.py"
BW="$HERE/../lanes/lib/burn-weights.sh"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/hop-rule-test.XXXXXX")" || { echo "test-hop-rule: mktemp -d failed" >&2; exit 1; }
trap 'rm -rf "$TMP"' EXIT
fails=0
check() { if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: expected [$2] got [$3]"; fails=$((fails + 1)); fi; }
OPUS=claude-opus-5-5
SONNET=claude-sonnet-5-5

hop() { python3 -I "$HR" --context "$1" --calls "$2" --model "$3" "${@:4}" >"$TMP/out" 2>"$TMP/err"; echo $?; }

echo "1. rule-table (base 30000, relaunch 25000, r 0.05, w 2, m 2, h 3)"
check "rule-table: below the floor no hop, however many calls" 1 "$(hop 150000 100000 $OPUS --base 30000 --relaunch 25000)"
check "rule-table: pays once but not twice: no hop" 1 "$(hop 300000 12 $OPUS --base 30000 --relaunch 25000)"
check "rule-table: pays twice: hop" 0 "$(hop 300000 20 $OPUS --base 30000 --relaunch 25000)"
check "rule-table: the h term alone turns hop into no hop (19 calls)" 1 "$(hop 300000 19 $OPUS --base 30000 --relaunch 25000)"
check "rule-table: without the h term the same case would hop" 1 "$(python3 -I -c 'print(int(0.05 * (300000 - 30000) * 19 >= 2 * (2.0 * 30000 + 25000)))')"
check "rule-table: --base alone turns hop into no hop" 1 "$(hop 300000 20 $OPUS --base 100000 --relaunch 25000)"
check "rule-table: the floor itself is at or above" 0 "$(hop 200000 1000 $OPUS --base 30000 --relaunch 25000)"
check "rule-table: the defaults are the named constants" 0 "$(python3 -I -c '
import sys; sys.path.insert(0, sys.argv[1]); import hop_rule as h
print(int(h.should_hop(300000, 20, "claude-opus-5-5") == h.should_hop(300000, 20, "claude-opus-5-5", base=h.B, relaunch=h.K)) - 1)' "$HERE")"

echo "2. rule-weights"
for m in $OPUS $SONNET; do
    hop 300000 19 "$m" --base 30000 --relaunch 25000 >/dev/null
    want="$(python3 -I -c 'import sys; sys.path.insert(0, sys.argv[1]); import burn_weights as b; print(b.cache_read_weight(sys.argv[2]))' "$HERE" "$m")"
    check "rule-weights: $m prints the owner's r" 1 "$(grep -c "^r=$want\b" "$TMP/out")"
done
check "rule-weights: 19 calls at r 0.05 is no hop" 1 "$(hop 300000 19 $OPUS --base 30000 --relaunch 25000)"
check "rule-weights: the same case at a flat 0.1 is a hop" 0 "$(WORKER_SESSION_BURN_W_CACHE_READ=0.1 python3 -I "$HR" --context 300000 --calls 19 --model $OPUS --base 30000 --relaunch 25000 >/dev/null 2>&1; echo $?)"
rc="$(hop 300000 50 claude-nope-9 --base 30000 --relaunch 25000)"
check "rule-weights: an unknown model exits 3" 3 "$rc"
check "rule-weights: it says unknown model" 1 "$(grep -c 'unknown model' "$TMP/err")"
check "rule-weights: and prints no answer" 0 "$(grep -c . "$TMP/out")"
check "rule-weights: should_hop raises for an unknown model" 1 "$(python3 -I -c '
import sys; sys.path.insert(0, sys.argv[1]); import hop_rule as h
try:
    h.should_hop(300000, 50, "claude-nope-9")
except ValueError:
    print(1)' "$HERE")"

echo "3. rule-1h-weight"
check "rule-1h-weight: burn-weights.sh defaults to 2.0" 2.0 "$(bash -c '. "$1"; echo "$WORKER_SESSION_BURN_W_CACHE_CREATE_1H"' _ "$BW")"
check "rule-1h-weight: burn-weights.sh takes the env value" 3.5 "$(WORKER_SESSION_BURN_W_CACHE_CREATE_1H=3.5 bash -c '. "$1"; echo "$WORKER_SESSION_BURN_W_CACHE_CREATE_1H"' _ "$BW")"
check "rule-1h-weight: the reader returns 2.0 by default" 2.0 "$(python3 -I -c 'import sys; sys.path.insert(0, sys.argv[1]); import burn_weights as b; print(b.cache_create_1h_weight())' "$HERE")"
check "rule-1h-weight: the reader returns the env value when set" 3.5 "$(WORKER_SESSION_BURN_W_CACHE_CREATE_1H=3.5 python3 -I -c 'import sys; sys.path.insert(0, sys.argv[1]); import burn_weights as b; print(b.cache_create_1h_weight())' "$HERE")"

if [ "$fails" -ne 0 ]; then echo "FAIL - test-hop-rule.sh ($fails failure(s))"; exit 1; fi
echo "PASS - test-hop-rule.sh"
