#!/usr/bin/env bash
# test-tick-repair.sh — tick.sh held=<n>:<sig8>, unfiled=<n>, repair=off:<why> and the detached
# `jira release repair <R> --apply --repo <slug>` launch. The tick only READS release/<R>/repair-state.json, the one
# record the jira CLI writes (10231), and writes no repair file; stand-ins for the CLI leave the record a real run leaves.
# The state read and the repair are stubbed: nothing touches Jira, the real journal or the real ledgers, and no Fix Version is written.
#
# PLATFORM GUARD: The chief kit is Linux-only.
# shellcheck disable=SC2015,SC2016  # `[ cond ] && pass || fail`: pass() cannot fail; single-quoted stub bodies expand at run time
set -uo pipefail

if [ "$(uname -s)" = Darwin ]; then
  echo "SKIP - tick.sh is Linux-only by design (tick.sh:11-12); HIMMEL-7641"
  exit 0
fi

HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="$HERE/tick.sh"
DOCPAGE="$HERE/../../../docs/handover/chief-sections/release-manager.md"
W="$(mktemp -d "${TMPDIR:-/tmp}/tick-repair-test.XXXXXX")" || exit 1
trap 'kill $(jobs -p) 2>/dev/null; rm -rf "$W"' EXIT
fails=0
pass() { printf 'ok - %s\n' "$1"; }
fail() { printf 'FAIL - %s\n' "$1"; fails=$((fails + 1)); }
check() { # <name> <want> <got>
    if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (want '$2' got '$3')"; fi
}

mkdir -p "$W/repo/scripts/handover" "$W/repo/scripts/lib" "$W/repo/scripts/lanes/lib" "$W/handover/inbox/.cursor" "$W/bin" "$W/proc" "$W/home" "$W/projects/p" "$W/chief-work/chain"

cat > "$W/repo/scripts/handover/queue-lock.sh" <<'STUB'
#!/usr/bin/env bash
case "$1" in
  heartbeat) exit 0 ;;
  status) printf '%s\n' free; exit 0 ;;
esac
exit 2
STUB
printf '#!/usr/bin/env bash\nprintf "%%s\\n" 28\n' > "$W/repo/scripts/context-fill.sh"
cat > "$W/bin/date" <<'STUB'
#!/usr/bin/env bash
case "$1" in +%H:%M) printf '%s\n' 12:34 ;; *) /bin/date "$@" ;; esac
STUB
printf '#!/usr/bin/env bash\nexit 1\n' > "$W/bin/pgrep"
printf '#!/usr/bin/env bash\nexit 0\n' > "$W/bin/atq"
printf '#!/usr/bin/env bash\nexit 1\n' > "$W/bin/gh"
printf '#!/usr/bin/env bash\ncat "$PS_FIXTURE"\n' > "$W/bin/ps"
printf '#!/usr/bin/env bash\nexit 1\n' > "$W/bin/bun"
printf '%s\n' '    1     0 40-00:00:01 /sbin/init' > "$W/ps-none.txt"
cp "$HERE/../../lanes/ceiling-conformance.sh" "$W/repo/scripts/lanes/ceiling-conformance.sh"
cp "$HERE/../../lanes/lib/claude-sessions.sh" "$W/repo/scripts/lanes/lib/claude-sessions.sh"
cat > "$W/repo/scripts/lib/usage-preflight.sh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' 'bank-preflight: FLEET native=1 claudex=0 openrouter=0 reserved=0 total=1/8' >&2
printf '%s\n' PROCEED
STUB
chmod +x "$W/repo/scripts/handover/queue-lock.sh" "$W/repo/scripts/context-fill.sh" "$W/repo/scripts/lanes/ceiling-conformance.sh" "$W/repo/scripts/lib/usage-preflight.sh" "$W/bin/"*
printf '%s\n' '{"five_hour":{"utilization":30},"seven_day":{"utilization":28}}' > "$W/bank.json"
git init -q "$W/repo"

unset HIMMEL_CONSOLE_LEG HIMMEL_RELEASE_MANAGER  # a worker session sets the fence variables; the rows that need them set them
export PATH="$W/bin:$PATH"
export HOME="$W/home"
export HANDOVER_DIR="$W/handover" REPO="$W/repo" TICK_TMPDIR="$W" PS_FIXTURE="$W/ps-none.txt"
export TICK_BANK_CACHE_FILE="$W/bank.json" TICK_STATE_DIR="$W/state" CLAUDE_SESSIONS_PROC="$W/proc"
export TICK_LAUNCH_DIR="$W/chief-work" TICK_PROJECTS_DIR="$W/projects"
export TOKEN=t WORKERS=''
export HIMMEL_RELEASE_STATE_DIR="$W/releases" USER_SLUG=tester
export HIMMEL_VERSION_WRITES="$W/journal.jsonl"
export NEXT_DISPATCH_MIRROR="$W/mirror/TESTKEY"
RDIR="$W/releases/R1"
mkdir -p "$RDIR"

# the state read: `release state <R> --json`, its body is $W/state.json; the repair stub logs its argv and JIRA_PROJECT_KEY.
printf '#!/bin/sh\necho "$@" >> "%s/state-asked"\ncat "%s/state.json"\nexit "${TICK_RMQ_EXIT:-0}"\n' "$W" "$W" > "$W/rmq-probe.sh"
printf '#!/bin/sh\necho "$@" >> "%s/rmrun-ran"\n' "$W" > "$W/rmrun-probe.sh"
printf '#!/bin/sh\necho "$* key=$JIRA_PROJECT_KEY" >> "%s/repair-ran"\n' "$W" > "$W/repair-probe.sh"
# the dead launcher: logs one line to a tally file and exits 127, so the probe never runs and no run ends
printf '#!/bin/sh\necho x >> "%s/launch-tried"\nexit 127\n' "$W" > "$W/bin/deadlaunch"
chmod +x "$W/bin/deadlaunch"
export TICK_RMQ_PROBE="$W/rmq-probe.sh" TICK_RMRUN_PROBE="$W/rmrun-probe.sh" TICK_REPAIR_PROBE="$W/repair-probe.sh" TICK_RMRUN_LAUNCHER=env

SIG64=abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789
# mkstate <leaks (unauthorized) as a JSON list> <operator head> <requests head> <mirror head>; no open requests, so no rm-run.
mkstate() { printf '{"status":"OK","versions":["v1.1.3","v1.1.4"],"lease":null,"requests":{"open":[],"claimed":[],"oldest_open":null},"leaks":{"unauthorized":%s,"ruled_in_non_member":[]},"heads":{"rulings":"x","operator":"%s","events":"e","requests":"%s","mirror":"%s"}}\n' "$1" "$2" "$3" "$4" > "$W/state.json"; }
base_state() { mkstate '["K-1@v1.1.4"]' op1 rq1 mi1; }
mkdoc() { printf '# chief\nrelease: %s\n' "$1" > "$W/handover/chief.md"; }

# The record the jira CLI writes (release/<R>/repair-state.json); the tick only reads it.
# rec <state> <reason|-> <reviewed 0|1> <signature|-> <launched epoch|-> <lost_count> <pid|-> [held [unfiled]]
ident_of() { ( . "$HERE/../../lib/proc-tree.sh"; proc_tree_process_identity "$1" ); }  # <pid>: the identity the tick compares
json_str() { python3 -I -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$1"; }
# REC_IDENT (the owner identity), REC_ATT (attempted epoch) and REC_ATTN (attempts) shape the record rec writes; unset they are null, null and 0
rec() {
    local st="$1" why="$2" rv="$3" sg="$4" la="$5" k="$6" pid="$7" held="${8:-0}" unf="${9:-0}" keys="" i
    local idt="${REC_IDENT:--}" att="${REC_ATT:--}" atn="${REC_ATTN:-0}"
    if [ "$idt" = - ]; then idt=null; else idt="$(json_str "$idt")"; fi
    [ "$att" = - ] && att=null
    for ((i = 0; i < held; i++)); do keys="$keys${keys:+,}\"K-$i\""; done
    [ "$why" = - ] && why=null || why="\"$why\""
    [ "$rv" = 1 ] && rv='"2026-11-03T00:00:00Z"' || rv=null
    [ "$sg" = - ] && sg=''
    [ "$la" = - ] && la=null
    [ "$pid" = - ] && pid=null
    printf '{"release":"R1","state":"%s","reason":%s,"reviewed_at":%s,"signature":"%s","held_signature":"%s","held_keys":[%s],"unfiled":%s,"launched":%s,"pid":%s,"pid_identity":%s,"attempted":%s,"attempts":%s,"lost_count":%s,"operator_command":null,"last_exit":null,"ts":"2026-11-03T00:00:00Z"}\n' \
        "$st" "$why" "$rv" "$sg" "$SIG64" "$keys" "$unf" "$la" "$pid" "$idt" "$att" "$atn" "$k" > "$RDIR/repair-state.json"
}
heldrec() { rec off unreviewed 0 - - 0 - "$1" "$2"; }  # <held> <unfiled>
reviewed() { rec idle - 1 - - 0 -; }
lostrec() { rec lost lost 1 "${3:-$SIG64}" "$(( $(date +%s) - $1 ))" "$2" -; }  # <age-secs> <lost_count> [signature]
sig_now() { python3 -I "$W/emu.py" sig; }
# What the real CLI does at the end of a run, so a probe that stands in for it leaves the record a real run would.
cat > "$W/emu.py" <<'PY'
import hashlib, json, os, sys
W, RDIR = os.environ["W"], os.environ["RDIR"]
def sig():
    d = json.load(open(W + "/state.json"))
    l, h = d["leaks"], d["heads"]
    leaks = sorted(set(l.get("unauthorized", []) + l.get("ruled_in_non_member", [])))
    try:
        j = hashlib.sha256(open(os.environ["HIMMEL_VERSION_WRITES"], "rb").read()).hexdigest()
    except OSError:
        j = ""
    rows = ["leak=" + k for k in leaks] + ["operator=" + str(h["operator"]), "requests=" + str(h["requests"]), "journal=" + j, "mirror=" + str(h["mirror"])]
    return hashlib.sha256("\n".join(rows).encode()).hexdigest()
mode = sys.argv[1]
if mode == "sig":
    print(sig())
    sys.exit(0)
if mode == "attempt":
    import time
    try:
        r = json.load(open(RDIR + "/repair-state.json"))
    except OSError:
        r = {"release": "R1", "state": "off", "reason": "unreviewed", "reviewed_at": None, "signature": "", "held_signature": "", "held_keys": [], "unfiled": 0,
             "launched": None, "pid": None, "pid_identity": None, "lost_count": 0, "operator_command": None, "last_exit": None, "ts": "x"}
    r["attempted"] = int(time.time())
    r["attempts"] = min(64, int(r.get("attempts", 0)) + 1)
    open(RDIR + "/repair-state.json", "w").write(json.dumps(r))
    sys.exit(0)
state, reason = {"clean": ("idle", None), "stop": ("off", "mirror-unknown"), "error": ("off", "error")}[mode]
rec = {"release": "R1", "state": state, "reason": reason, "reviewed_at": "2026-11-03T00:00:00Z", "signature": "" if mode == "error" else sig(),
       "held_signature": "a" * 64, "held_keys": [], "unfiled": 0, "launched": 1, "pid": None, "pid_identity": None, "attempted": None, "attempts": 0, "lost_count": 0, "operator_command": None,
       "last_exit": 0 if mode == "clean" else 3, "ts": "2026-11-03T00:00:00Z"}
open(RDIR + "/repair-state.json", "w").write(json.dumps(rec))
PY
export W RDIR
# the CLI stand-ins: each logs its argv and leaves the record a run of that kind leaves
for mode in clean stop error; do
    printf '#!/bin/sh\necho "$* key=$JIRA_PROJECT_KEY" >> "%s/repair-ran"\npython3 -I "%s/emu.py" %s\n' "$W" "$W" "$mode" > "$W/$mode-probe.sh"
done
export TICK_REPAIR_PROBE="$W/clean-probe.sh"
# the CLI's record read: a missing record is published as off:unreviewed with no review marker
cat > "$W/state-read-probe.sh" <<'STUB'
#!/bin/sh
echo "$@" >> "$W/state-read"
case " $* " in *" --attempt "*) [ -z "${ATTEMPT_FAIL:-}" ] || exit 1; python3 -I "$W/emu.py" attempt; exit $? ;; esac
[ -e "$RDIR/repair-state.json" ] || printf %s '{"release":"R1","state":"off","reason":"unreviewed","reviewed_at":null,"signature":"","held_signature":"","held_keys":[],"unfiled":0,"launched":null,"pid":null,"pid_identity":null,"attempted":null,"attempts":0,"lost_count":0,"operator_command":"jira release repair R1 --apply --repo acme/widgets","last_exit":null,"ts":"x"}' > "$RDIR/repair-state.json"
STUB
export TICK_REPAIR_STATE_PROBE="$W/state-read-probe.sh"
reset() {
    rm -f "$W/repair-ran" "$W/launch-tried" "$W/rmrun-ran" "$W/state-asked" "$W/state-read" "$W/journal.jsonl"
    rm -rf "$W/state" "$RDIR"; mkdir -p "$RDIR"
    git -C "$W/repo" remote remove origin 2>/dev/null
    git -C "$W/repo" remote add origin git@github.com:acme/widgets.git
    base_state
    mkdoc R1
}
age_log() { touch -d '20 minutes ago' "$RDIR/repair-run.log"; }
tried() { # wait up to 5 s for the dead launcher to log <n> lines, then print how many it logged
    local n="$1" i=0
    while [ "$( [ -f "$W/launch-tried" ] && wc -l < "$W/launch-tried" | tr -d ' ' || echo 0)" -lt "$n" ] && [ "$i" -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
    [ -f "$W/launch-tried" ] && wc -l < "$W/launch-tried" | tr -d ' ' || echo 0
}
none_tried() { sleep 1; [ -f "$W/launch-tried" ] && wc -l < "$W/launch-tried" | tr -d ' ' || echo 0; }
tick() { bash "$SUT" --doc "$W/handover/chief.md" 2>/dev/null; }
field() { # <field> <tick output>
    printf '%s\n' "$2" | tr ' ' '\n' | sed -n "s/^$1=//p" | head -n 1
}
launched() { # wait up to 5 s for the detached stub to log <n> lines, then print how many it logged
    local n="$1" i=0
    while [ "$( [ -f "$W/repair-ran" ] && wc -l < "$W/repair-ran" | tr -d ' ' || echo 0)" -lt "$n" ] && [ "$i" -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
    [ -f "$W/repair-ran" ] && wc -l < "$W/repair-ran" | tr -d ' ' || echo 0
}
none_launched() { sleep 1; [ -f "$W/repair-ran" ] && wc -l < "$W/repair-ran" | tr -d ' ' || echo 0; }
nofile() { [ -e "$RDIR/$1" ] && echo 1 || echo 0; }  # <name>: 1 when the tick (or anyone) left that file

# --- held= and unfiled= (read from repair-state.json; elided at zero)
reset; heldrec 3 2
out1="$(tick)"; out2="$(tick)"
check 'held field prints each tick while nonzero, elided at zero' '3:abcdef01 3:abcdef01' "$(field held "$out1") $(field held "$out2")"
heldrec 0 0
out="$(tick)"
check 'held field prints each tick while nonzero, elided at zero (zero elides)' '' "$(field held "$out")"
check 'unfiled field likewise' '' "$(field unfiled "$out")"
heldrec 3 2
out1="$(tick)"; out2="$(tick)"
check 'unfiled field likewise (nonzero, each tick)' '2 2' "$(field unfiled "$out1") $(field unfiled "$out2")"
rm -f "$RDIR/repair-state.json"
out="$(tick)"
check 'no record prints neither held nor unfiled' '' "$(field held "$out")$(field unfiled "$out")"
printf '{"state":"held"' > "$RDIR/repair-state.json"
out="$(tick)"
check 'a malformed record prints neither held nor unfiled and the repair field reads off:unread' 'off:unread' "$(field repair "$out")"
check 'a malformed record prints neither held nor unfiled' '' "$(field held "$out")$(field unfiled "$out")"

reset; heldrec 3 2
out1="$(tick)"
printf '{"ts":"2026-11-03T00:00:00Z","key":"K-9"}\n' >> "$W/journal.jsonl"
out2="$(tick)"
check 'journal head alone leaves held sig unchanged' "$(field held "$out1")" "$(field held "$out2")"

# --- the wake key: chief-wait.sh names no held/unfiled/repair field (a read, not a change)
fields_line="$(awk -F'\t' '$0 !~ /^#/ && $5 == "key" { print $1 }' "$HERE/wake-rules.tsv" | paste -sd' ' -)"
case "$fields_line" in *workers*) ;; *) fields_line="" ;; esac
res=absent
case " $fields_line " in *" held "*|*" unfiled "*|*" repair "*) res=present ;; esac
[ -n "$fields_line" ] || res=unread
check 'held and repair fields stay out of the wake key' absent "$res"

# --- the launch: the tick writes no repair file; the run records its own launch and signature
reset; reviewed
out="$(tick)"
check 'marker present launches apply' '1' "$(launched 1)"
check 'marker present launches apply (the verb and release)' 'release repair R1 --apply --repo acme/widgets' "$(sed -n 1p "$W/repair-ran" | sed 's/^\(.*--repo [^ ]*\).*$/\1/')"
check 'marker present: no repair=off field' '' "$(field repair "$out")"
check 'a tick that launches a repair writes no repair-launch' 0 "$(nofile repair-launch)"
check 'a tick that launches a repair writes no repair-signature' 0 "$(nofile repair-signature)"
check 'launch sets JIRA_PROJECT_KEY' 'key=TESTKEY' "$(sed -n 1p "$W/repair-ran" | sed 's/^.* \(key=[^ ]*\)$/\1/')"
check 'the launch output goes to repair-run.log in the release dir' 1 "$([ -e "$RDIR/repair-run.log" ] && echo 1 || echo 0)"
check 'the state read is asked once for the same release' 'R1 --json' "$(sed -n 1p "$W/state-asked")"

reset; reviewed; git -C "$W/repo" remote set-url origin https://github.com/other/thing.git
tick >/dev/null
check 'launch carries --repo from the remote' 'other/thing' "$(launched 1 >/dev/null; sed -n 's/^.*--repo \([^ ]*\) .*$/\1/p' "$W/repair-ran" | head -n 1)"

reset; reviewed; git -C "$W/repo" remote remove origin
out="$(tick)"
check 'no remote prints repair=off:bad-input' 'off:bad-input' "$(field repair "$out")"
check 'no remote starts nothing' 0 "$(none_launched)"

# --- off:unreviewed: the record says so (the CLI publishes it when none exists) and nothing launches
reset
export TICK_REPAIR_STATE_PROBE="$W/state-read-probe.sh"
out="$(tick)"
check 'no review marker starts no apply and prints repair=off:unreviewed' 'off:unreviewed' "$(field repair "$out")"
check 'no review marker starts no apply (negative control: nothing ran)' 0 "$(none_launched)"
check 'a missing record is asked of the CLI once (release repair-state <R> --json)' 'release repair-state R1 --json' "$(sed -n 1p "$W/state-read")"
check 'the real operator command is in the record the CLI publishes' 'jira release repair R1 --apply --repo acme/widgets' "$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["operator_command"])' "$RDIR/repair-state.json")"
check 'the tick wrote none of the compatibility files' '000' "$(nofile repair-launch)$(nofile repair-signature)$(nofile repair-status)"
reset; heldrec 1 0
tick >/dev/null
check 'an existing record is not re-asked of the CLI' '' "$(cat "$W/state-read" 2>/dev/null)"

reset; reviewed
tick >/dev/null; launched 1 >/dev/null
age_log
out="$(tick)"
check 'unchanged signature starts no process' 1 "$(none_launched)"

# each input moves the run signature; the gap is aged each time so only the signature decides
trigger() { # <name> <leaks> <operator> <requests> <mirror> <journal line or ''>
    reset; reviewed
    tick >/dev/null; launched 1 >/dev/null
    age_log
    mkstate "$2" "$3" "$4" "$5"
    [ -z "$6" ] || printf '%s\n' "$6" >> "$W/journal.jsonl"
    tick >/dev/null
    check "$1 triggers a run" 2 "$(launched 2)"
}
trigger 'leak set' '["K-1@v1.1.4","K-2@v1.1.4"]' op1 rq1 mi1 ''
trigger 'operator head' '["K-1@v1.1.4"]' op2 rq1 mi1 ''
trigger 'requests head' '["K-1@v1.1.4"]' op1 rq2 mi1 ''
trigger 'mirror head' '["K-1@v1.1.4"]' op1 rq1 mi2 ''
trigger 'journal head' '["K-1@v1.1.4"]' op1 rq1 mi1 '{"key":"K-9"}'
# an event-head-only move is not an input
reset; reviewed
tick >/dev/null; launched 1 >/dev/null
age_log
sed -i 's/"events":"e"/"events":"e2"/' "$W/state.json"  # gnu-ok: console kit is Linux-only
tick >/dev/null
check 'leak set, operator, requests, journal and mirror heads each trigger (an events head alone does not)' 1 "$(none_launched)"

# --- the gap
reset; reviewed
tick >/dev/null; launched 1 >/dev/null
rec idle - 1 - 1 0 -   # a capped run with progress cleared its signature
out="$(tick)"
check 'capped run with progress runs again, no sooner than the gap (inside the gap: nothing)' 1 "$(none_launched)"
age_log
tick >/dev/null
check 'capped run with progress runs again, no sooner than the gap' 2 "$(launched 2)"

reset; reviewed
tick >/dev/null; launched 1 >/dev/null
age_log   # a capped run with no progress left the signature in place
tick >/dev/null
check 'capped run with no progress does not' 1 "$(none_launched)"

reset; rec off error 1 - 1 0 -
out="$(tick)"
check 'error record prints repair=off:error' 'off:error' "$(field repair "$out")"
reset; rec off error 1 - 1 0 -
touch "$RDIR/repair-run.log"          # last launch just now, signature cleared
tick >/dev/null
check 'errored run is retried, no sooner than the gap (inside the gap: nothing)' 0 "$(none_launched)"
age_log
out="$(tick)"
check 'errored run is retried, no sooner than the gap' 1 "$(launched 1)"
check 'errored run still reads repair=off:error until a clean run replaces the record' 'off:error' "$(field repair "$out")"

reset; rec off mirror-unknown 1 "$SIG64" 1 0 -
out="$(tick)"
check 'stop prints repair=off with its reason' 'off:mirror-unknown' "$(field repair "$out")"

# the stand-ins for a run that ends in a stop or an error replace the record as the CLI does
reset; reviewed
TICK_REPAIR_PROBE="$W/stop-probe.sh" tick >/dev/null
check '3 stop: launched once' 1 "$(launched 1)"
age_log
out="$(TICK_REPAIR_PROBE="$W/stop-probe.sh" tick)"
check '3 stop: no relaunch after the gap on the same signature' 1 "$(none_launched)"
check '3 stop: the field reads off:mirror-unknown' 'off:mirror-unknown' "$(field repair "$out")"

# --- a launcher that never starts the CLI: the CLI records each attempt BEFORE the start, so the retry is timed and bounded
age_attempt() { # <secs>: move the recorded attempt back (what the passing of time does to its clock)
    python3 -I -c 'import json,sys; p=sys.argv[1]; r=json.load(open(p)); r["attempted"]-=int(sys.argv[2]); open(p,"w").write(json.dumps(r))' "$RDIR/repair-state.json" "$1"
}
attempts_now() { python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["attempts"])' "$RDIR/repair-state.json"; }
export TICK_RMRUN_LAUNCHER="$W/bin/deadlaunch"
reset; reviewed
tick >/dev/null
check '1a dead launcher: the first tick tries once' 1 "$(tried 1)"
check '1a dead launcher: the CLI recorded the attempt before the start' 1 "$(attempts_now)"
check '1a dead launcher: the tick wrote no stamp and no signature' '00' "$(nofile repair-launch)$(nofile repair-signature)"
out="$(tick)"
check '1b dead launcher: the next tick is inside the retry gap' 1 "$(none_tried 1)"
age_log
tick >/dev/null
check '1b dead launcher: an aged LOG alone does not retry (an old append-only log mtime says nothing about the attempt)' 1 "$(none_tried 1)"
check '1b dead launcher: no repair=off field (nothing is known to be lost)' '' "$(field repair "$out")"
age_attempt 700
tick >/dev/null
check '1c dead launcher: a second try once the attempt itself is a gap old' 2 "$(tried 2)"
check '1c dead launcher: the second attempt is recorded' 2 "$(attempts_now)"
tick >/dev/null
check '1d dead launcher: the very next tick after an aged retry does not try again' 2 "$(none_tried 2)"
age_attempt 700
tick >/dev/null
check '1d dead launcher: one gap after the second attempt is still inside its doubled wait' 2 "$(none_tried 2)"
age_attempt 600
tick >/dev/null
check '1e dead launcher: past the doubled wait it tries a third time' 3 "$(tried 3)"
python3 -I -c 'import json,sys; p=sys.argv[1]; r=json.load(open(p)); r["attempts"]=40; r["attempted"]-=30000; open(p,"w").write(json.dumps(r))' "$RDIR/repair-state.json"
tick >/dev/null
check '1f dead launcher: the doubling is capped (a count of 40 waits no more than 6 h)' 4 "$(tried 4)"

# the attempt cannot be recorded (the CLI is refused, busy, or absent): nothing starts and the field says why
export TICK_RMRUN_LAUNCHER=env
reset; reviewed
out="$(ATTEMPT_FAIL=1 tick)"
check '1g no attempt recorded: nothing starts' 0 "$(none_launched)"
check '1g no attempt recorded: the field reads off:unavailable' 'off:unavailable' "$(field repair "$out")"
reset; reviewed
out="$(TICK_REPAIR_STATE_PROBE='' tick)"
check '1h no CLI to record the attempt: nothing starts and the field reads off:unavailable' 'off:unavailable' "$(field repair "$out")"
check '1h no CLI to record the attempt: no process' 0 "$(none_launched)"
reset; reviewed; ATTEMPT_FAIL=1 tick >/dev/null
out="$(tick)"
check '1i the next tick with a working CLI launches once' 1 "$(launched 1)"
check '1i and the field is quiet again' '' "$(field repair "$out")"
export TICK_RMRUN_LAUNCHER="$W/bin/deadlaunch"  # the lost-launch rows below count launches with the dead launcher

# a pid that is dead and reaped, so no zombie keeps /proc/<pid>
deadpid() { sleep 60 & local p=$!; kill "$p"; wait "$p" 2>/dev/null; echo "$p"; }
lost_field() { # <name> <want> <tick output>
    check "$1" "$2" "$(field repair "$3")"
}

# 4 the bound (I2): wait(3) is 2400 s at the default gap
reset; age_log; lostrec 1500 2
out="$(tick)"
check '4 bound: inside wait(3) nothing launches' 0 "$(none_tried 0)"
lost_field '4 bound: inside wait(3) the field reads off:lost' 'off:lost' "$out"
lostrec 2500 2
tick >/dev/null
check '4 bound: past wait(3) it launches' 1 "$(tried 1)"

# 5 the cap (I2): the doubling stops at 6 h, so k=100 neither overflows nor waits longer than the cap
reset; age_log; lostrec 21000 100
tick >/dev/null
check '5 cap: inside the cap nothing launches' 0 "$(none_tried 0)"
lostrec 21700 100
tick >/dev/null
check '5 cap: past the cap it launches' 1 "$(tried 1)"

# 6 a live owner (I1): the record is running and its pid is alive
reset; age_log
sleep 60 &
holder=$!
REC_IDENT="$(ident_of "$holder")" rec running - 1 "$SIG64" "$(date +%s)" 0 "$holder"
out="$(tick)"
check '6 live owner: nothing launches' 0 "$(none_tried 0)"
lost_field '6 live owner: no off:lost' '' "$out"
kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null

# 7 a mid-run kill: the record is running and names a dead pid
reset; age_log
deadp="$(deadpid)"
rec running - 1 "$SIG64" "$(( $(date +%s) - 1200 ))" 0 "$deadp"
out="$(tick)"
check '7 mid-run kill: it launches' 1 "$(tried 1)"
lost_field '7 mid-run kill: the field reads off:lost' 'off:lost' "$out"

# 8 a launch from before the boot, naming a live pid, is not live
reset; age_log
sleep 60 &
holder=$!
REC_IDENT="$(ident_of "$holder")" rec running - 1 "$SIG64" 1 0 "$holder"
out="$(tick)"
check '8 pre-boot launch: it launches' 1 "$(tried 1)"
lost_field '8 pre-boot launch: the field reads off:lost' 'off:lost' "$out"
kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null

# 9 after a run reached its end the record is idle: a changed signature launches with no backoff
reset; age_log; rec idle - 1 "$SIG64" "$(( $(date +%s) - 1200 ))" 0 -
mkstate '["K-1@v1.1.4"]' op2 rq1 mi1
out="$(tick)"
check '9 end reached: it launches' 1 "$(tried 1)"
lost_field '9 end reached: no off:lost' '' "$out"

# 12 precedence: a lost record shows lost, never a stale reason
reset; age_log; rec lost lost 1 "$SIG64" "$(( $(date +%s) - 1200 ))" 0 -
out="$(tick)"
lost_field '12 precedence: lost shows off:lost' 'off:lost' "$out"

# 13 a malformed record reads as none: no field, no launch
for bad in garbage '{"state":"idle"}' '{"state":"nope","held_keys":[],"unfiled":0,"lost_count":0,"signature":"","held_signature":"","reason":null,"reviewed_at":"x","launched":null,"pid":null}'; do
    reset; printf '%s\n' "$bad" > "$RDIR/repair-state.json"
    out="$(tick)"
    check "13 malformed record '${bad:0:24}': the CLI is asked, cannot publish, and the field reads off:unread" 'off:unread' "$(field repair "$out")"
    check "13 malformed record '${bad:0:24}': nothing launches" 0 "$(none_tried 0)"
done

# 14 a zero gap does not turn the backoff off (I2): base is floored at 60
reset; lostrec 10 0
out="$(TICK_RMRUN_MIN_SECS=0 tick)"
check '14 zero gap: inside the floor nothing launches' 0 "$(none_tried 0)"
lost_field '14 zero gap: the field reads off:lost' 'off:lost' "$out"

# 15 a pending launch after a lost one (I2): a changed signature does not shorten the wait
reset; lostrec 10 1 "$(printf '%064d' 0)"
out="$(TICK_RMRUN_MIN_SECS=0 tick)"
check '15 pending after lost: nothing launches' 0 "$(none_tried 0)"
lost_field '15 pending after lost: the field reads off:lost' 'off:lost' "$out"

# 16 a launch time in the future cannot time a backoff: the lost run still relaunches at the log gap, never stalls on a bad clock
reset; age_log; rec lost lost 1 "$SIG64" "$(( $(date +%s) + 3600 ))" 1 -
out="$(tick)"
check '16 future launch time: a lost record still launches at the gap' 1 "$(tried 1)"
lost_field '16 future launch time: the field reads off:lost' 'off:lost' "$out"

# 18 an EPERM pid is live (I1); pid 1 is probe-able when this user may signal it, so the row is skipped then
if kill -0 1 2>/dev/null; then
    pass '18 EPERM pid: skipped (pid 1 is probe-able for this user)'
else
    reset; age_log; REC_IDENT="$(ident_of 1)" rec running - 1 "$SIG64" "$(( $(date +%s) - 1200 ))" 0 1
    out="$(tick)"
    check '18 EPERM pid: nothing launches' 0 "$(none_tried 0)"
    lost_field '18 EPERM pid: no off:lost' '' "$out"
fi

# 19 a leading-zero gap is decimal, not octal
reset; age_log; lostrec 900 0
out="$(TICK_RMRUN_MIN_SECS=0800 tick)"
check '19 leading-zero gap: it launches' 1 "$(tried 1)"
lost_field '19 leading-zero gap: the field reads off:lost' 'off:lost' "$out"
export TICK_RMRUN_LAUNCHER=env

# --- the fence and the owner
reset; reviewed
for fence in HIMMEL_CONSOLE_LEG HIMMEL_RELEASE_MANAGER; do
    rm -f "$W/repair-ran"
    out="$(env "$fence=1" bash "$SUT" --doc "$W/handover/chief.md" 2>/dev/null)"
    check "fence variables skip the launch ($fence: no process)" 0 "$(none_launched)"
    check "fence variables write no repair file ($fence: none)" '00' "$(nofile repair-signature)$(nofile repair-launch)"
done
out="$(tick)"
check 'fence variables skip the launch (negative control: unset, it launches)' 1 "$(launched 1)"

reset; sleep 60 &
holder=$!
REC_IDENT="$(ident_of "$holder")" rec running - 1 - "$(( $(date +%s) - 1200 ))" 0 "$holder"
tick >/dev/null
check 'second chief does not start a second run' 0 "$(none_launched)"
check 'second chief does not start a second run (the tick left the record as it was)' 'running' "$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["state"])' "$RDIR/repair-state.json")"
kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null
tick >/dev/null
check 'a record whose owner is gone does not block the launch' 1 "$(launched 1)"

# 7 the owner is bound to its process identity, never the pid alone
reset; age_log
sleep 60 &
holder=$!
rec running - 1 "$SIG64" "$(( $(date +%s) - 1200 ))" 0 "$holder"
out="$(tick)"
lost_field '7 identity: a live pid with no recorded identity is not a live owner' 'off:lost' "$out"
check '7 identity: ... and it relaunches on the lost backoff' 1 "$(launched 1)"
kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null
reset; age_log
sleep 60 &
holder=$!
REC_IDENT='posix:Thu Jan  1 00:00:00 1970 not this process' rec running - 1 "$SIG64" "$(( $(date +%s) - 1200 ))" 0 "$holder"
out="$(tick)"
lost_field '7 identity: a live pid showing another identity (a recycled pid) is lost' 'off:lost' "$out"
check '7 identity: ... and it relaunches' 1 "$(launched 1)"
kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null

# 8 a first run that died before any review is shown and recovered by the review-needed act, not hidden behind the marker
reset; age_log
deadp="$(deadpid)"
rec running - 0 "$SIG64" "$(( $(date +%s) - 1200 ))" 0 "$deadp"
out="$(tick)"
lost_field '8 first-run crash: the field reads off:lost although no review marker exists' 'off:lost' "$out"
check '8 first-run crash: nothing launches without the review marker' 0 "$(none_launched)"
reset; age_log
sleep 60 &
holder=$!
REC_IDENT="$(ident_of "$holder")" rec running - 0 "$SIG64" "$(date +%s)" 0 "$holder"
out="$(tick)"
lost_field '8 control: a live first run is quiet' '' "$out"
kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null
reset; rec off unreviewed 0 - - 0 -
out="$(tick)"
lost_field '8 control: an unreviewed idle record still reads off:unreviewed' 'off:unreviewed' "$out"

# --- no release line
reset; reviewed; heldrec 3 2
printf '# chief\n' > "$W/handover/chief.md"
out="$(tick)"
check 'no release line prints nothing' '' "$(field held "$out")$(field unfiled "$out")$(field repair "$out")"
check 'no release line launches nothing' 0 "$(none_launched)"

# --- the signature the tick compares is the one the CLI records (same inputs, same sha256)
reset; reviewed
check 'the emulated CLI signature is the tick signature (the unchanged-signature row above relies on it)' 64 "$(sig_now | tr -d '\n' | wc -c | tr -d ' ')"

# --- the doc
doc_ok=1
for f in 'held=' 'unfiled=' 'repair=off:'; do grep -qF "$f" "$DOCPAGE" || doc_ok=0; done
check 'the doc names all three fields' 1 "$doc_ok"
doc_flat="$(tr '\n' ' ' < "$DOCPAGE")"
doc_lost=0; case "$doc_flat" in *'`lost` (a launched run'*) doc_lost=1 ;; esac
check 'the doc names the lost reason' 1 "$doc_lost"
doc_rule=0; case "$doc_flat" in *'or when the last launch left no end record'*) doc_rule=1 ;; esac
check 'the doc states the retry in the launch rule' 1 "$doc_rule"
doc_rec=0; case "$doc_flat" in *'repair-state.json'*'the tick reads it and writes no repair file'*) doc_rec=1 ;; esac
check 'the doc names the one record and says the tick writes no repair file' 1 "$doc_rec"

# --- 10231 / 10229 (trace T8-267ec6b7 clause 7): the repair wake carries the REAL CLI's remedy through the real tick and the real waiter.
# Every row above uses a stand-in for the CLI; here the record is what `jira release repair-state` itself produces, never a record the test authors.
REALCLI="$HERE/../../jira/dist/index.js"
real_cli() { JIRA_PROJECT_KEY=TESTKEY HIMMEL_RELEASE_STATE_DIR="$W/releases" HIMMEL_RELEASE_KEY_DIR="$W/keys" node "$REALCLI" "$@"; }
if [ ! -f "$REALCLI" ]; then
    printf 'ok - SKIPPED the real-CLI wake rows: the built jira CLI (scripts/jira/dist/index.js) is absent in this checkout\n'
else
    reset
    real="$(real_cli release repair-state R1 --json --repo acme/widgets 2>/dev/null)"
    want='jira release repair R1 --apply --repo acme/widgets'
    check 'the real CLI prints a record whose operator command is the one review-and-apply command' "$want" "$(printf '%s' "$real" | python3 -I -c 'import json,sys; print(json.load(sys.stdin)["operator_command"])' 2>/dev/null)"
    if [ -e "$RDIR/repair-state.json" ]; then
        printf 'ok - the real CLI published the record itself\n'
    else
        # A CLI in other pid or user namespaces than the host (a sandbox) is fenced: it prints the record and cannot publish it, so its own
        # printed bytes are stored where it publishes them on a station.
        printf '%s\n' "$real" > "$RDIR/repair-state.json"
        printf 'ok - the real CLI is fenced here and printed the record; its own output is stored as the record\n'
    fi
    export TICK_REPAIR_STATE_PROBE=''
    out="$(tick)"
    check 'the real tick reads the real CLI record: repair=off:unreviewed' 'off:unreviewed' "$(field repair "$out")"
    check 'the real tick launches nothing for an unreviewed repair' 0 "$(none_launched)"
    rm -rf "$W/inbox-real"
    wake="$(printf '%s\n' "$out" | python3 -I "$HERE/wake-rules.py" --inbox "$W/inbox-real" --doc "$W/handover/chief.md" --release-root "$W/releases")"
    check 'the waiter rule wakes once with the exact remedy the CLI printed (never the unavailable fallback)' "WAKE repair off:unreviewed remedy=$want" "$wake"
    check 'the same tick line wakes only once' '' "$(printf '%s\n' "$out" | python3 -I "$HERE/wake-rules.py" --inbox "$W/inbox-real" --doc "$W/handover/chief.md" --release-root "$W/releases")"
    rm -f "$RDIR/repair-state.json"
    rm -rf "$W/inbox-real2"
    out="$(tick)"
    wake="$(printf '%s\n' "$out" | python3 -I "$HERE/wake-rules.py" --inbox "$W/inbox-real2" --doc "$W/handover/chief.md" --release-root "$W/releases")"
    case "$wake" in *"remedy=$want"*) wk=real ;; *'unavailable; reconcile CLI-owned repair-state record'*) wk=unavailable ;; *) wk="other:$wake" ;; esac
    check 'control: with no record the wake never invents a command (the unavailable remedy)' 'unavailable' "$wk"
fi

echo
if [ "$fails" -eq 0 ]; then echo "ALL PASS"; else echo "$fails FAILED"; exit 1; fi
