#!/usr/bin/env bash
# free-checks.sh -- the unpaid G3 proof runner (design §8: P5, P10 to P17) and the separate G0 record.
#
#   free-checks.sh --out REPORT.json [--require-runtime] [--suite-runner CMD]
#     [P12 live: --bank B --export NAME=DIR... --index DB... --private PATH... --config YML... --run-root DIR]
#     [P15 live: --reach-claude STUB --reach-private PATH --reach-station PATH --reach-home DIR]
#     [G0: --auth-readiness R --lock L --card-sha256 H]
#
# Runs every free check, then writes one nonsecret report: each check PASS, FAIL or SKIP with a
# one-line detail, g3 = PASS only when every check passed (any SKIP is INCOMPLETE: a skipped
# real-Q runtime fixture is never a pass), and the G0 auth-readiness result kept apart: a fixture
# G3 pass never stands in for live paid readiness. No paid or model call is made: the reach probe
# refuses a real (ELF) CLI and only runs a stub; paid_calls is always 0. Exit 0 PASS, 1 otherwise.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
out='' runtime=0 runner=bash bank='' runroot='' rclaude='' rpriv='' rstation='' rhome='' ready='' lock='' card=''
exports=() indexes=() privs=() configs=()
while [ $# -gt 0 ]; do
  case "$1" in
    --out) out=$2; shift 2 ;; --require-runtime) runtime=1; shift ;; --suite-runner) runner=$2; shift 2 ;;
    --bank) bank=$2; shift 2 ;; --export) exports+=("$2"); shift 2 ;; --index) indexes+=("$2"); shift 2 ;;
    --private) privs+=("$2"); shift 2 ;; --config) configs+=("$2"); shift 2 ;; --run-root) runroot=$2; shift 2 ;;
    --reach-claude) rclaude=$2; shift 2 ;; --reach-private) rpriv=$2; shift 2 ;; --reach-station) rstation=$2; shift 2 ;;
    --reach-home) rhome=$2; shift 2 ;;
    --auth-readiness) ready=$2; shift 2 ;; --lock) lock=$2; shift 2 ;; --card-sha256) card=$2; shift 2 ;;
    *) echo "free-checks: unknown argument $1" >&2; exit 2 ;;
  esac
done
[ -n "$out" ] || { echo "free-checks: --out is required" >&2; exit 2; }
T=$(mktemp -d "${TMPDIR:-/tmp}/free-checks.XXXXXX") || exit 2  # prim-ok: Linux-only pilot tool
trap 'rm -rf "$T"' EXIT
: > "$T/results"
rec() { printf '%s\t%s\t%s\n' "$1" "$2" "$3" >> "$T/results"; }
suite() { # <check id> <suite file> [args] -- PASS, FAIL, or SKIP when the suite skipped any row
  local log="$T/$1.log"
  $runner "$HERE/$2" "${@:3}" > "$log" 2>&1
  local rc=$?
  local what="$2${3:+ ${*:3}}"
  if [ "$rc" -ne 0 ]; then rec "$1" FAIL "$what exited $rc"
  elif grep -q '^SKIP - ' "$log"; then rec "$1" SKIP "$what: $(grep -m1 '^SKIP - ' "$log" | cut -c8-120)"
  else rec "$1" PASS "$what ($(grep -c '^ok - ' "$log") rows)"; fi
}
suite P5 test-route-rows.sh
suite P10 test-score.sh
suite P11 test-pins.sh
suite P11-identity test-identity-retention.sh
suite P13-S test-s-tools.sh
if [ "$runtime" = 1 ]; then suite P13-Q test-q-runtime.sh --require-runtime; else suite P13-Q test-q-runtime.sh; fi
suite P13-Q-lists test-q.sh
suite P14-P17 test-run-pilot.sh

if [ -n "$bank" ]; then
  la=(--bank "$bank")
  for e in "${exports[@]}"; do la+=(--export "$e"); done
  for i in "${indexes[@]}"; do la+=(--index "$i"); done
  for p in "${privs[@]}"; do la+=(--private "$p"); done
  for c in "${configs[@]}"; do la+=(--config "$c"); done
  [ -n "$runroot" ] && la+=(--run-root "$runroot")
  if python3 -I "$HERE/leak-scan.py" "${la[@]}" > "$T/leak.json" 2>&1; then rec P12 PASS "$(cat "$T/leak.json")"
  else rec P12 FAIL "$(tail -1 "$T/leak.json")"; fi
else
  rec P12 SKIP "no live copies, indexes and bank given (local read scan only at R4)"
fi

if [ -n "$rclaude" ]; then
  if [ "$(head -c4 "$rclaude" | od -An -c | tr -d ' \n')" = '177ELF' ]; then
    rec P15-live FAIL "the reach probe runs only a stub, never a real CLI"
  else
    h=$(printf '%s\n' "${exports[@]}" | sed -n 's/^himmel=//p'); l=$(printf '%s\n' "${exports[@]}" | sed -n 's/^luna=//p')
    if bash "$HERE/sandbox.sh" --arm V --home "${rhome:-$T}" --himmel "$h" --luna "$l" --claude "$rclaude" \
         --settings "$HERE/session-permissions.json" -- /opt/claude/claude "$rpriv" "$rstation" > "$T/reach.json" 2>&1 &&
       python3 -I -c 'import json,sys; r=json.load(open(sys.argv[1])); sys.exit(0 if r["private"]=="no" and r["station"]=="no" else 1)' "$T/reach.json" 2>/dev/null; then
      rec P15-live PASS "private and station paths unreachable from the session namespace"
    else
      rec P15-live FAIL "a private or station path is reachable from the session namespace"
    fi
  fi
else
  rec P15-live SKIP "no live reach probe inputs"
fi

g0="blocked: no auth-readiness record"
if [ -n "$ready" ]; then
  if python3 -I "$HERE/auth-preflight.py" --readiness "$ready" --lock "$lock" --card-sha256 "$card" > "$T/g0.txt" 2>&1; then g0="ready"
  else g0="blocked: $(sed -n '2p' "$T/g0.txt" | sed 's/^ *- //')"; fi
fi
python3 -I - "$T/results" "$out" "$g0" <<'EOF'
import json, sys
checks = {}
for line in open(sys.argv[1]):
    k, st, d = line.rstrip("\n").split("\t", 2)
    checks[k] = {"status": st, "detail": d}
sts = {c["status"] for c in checks.values()}
g3 = "FAIL" if "FAIL" in sts else ("INCOMPLETE" if "SKIP" in sts else "PASS")
rep = {"g3": g3, "checks": checks, "g0": sys.argv[3], "paid_ready": False, "paid_calls": 0,
       "note": "fixture checks prove harness logic; a G3 PASS is never live G0 readiness, G4 or a paid go"}
json.dump(rep, open(sys.argv[2], "w"), indent=1, sort_keys=True)
print("free-checks: G3 %s, G0 %s" % (g3, sys.argv[3]))
sys.exit(0 if g3 == "PASS" else 1)
EOF
