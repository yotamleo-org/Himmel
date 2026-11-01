#!/usr/bin/env bash
# shellcheck disable=SC2015,SC2016,SC2088  # A && B || C is intentional in check(); stub bodies and guest tildes are literal
# scripts/vm/test-launch-guest.sh - suite for launch-guest.sh, the one sanctioned
# way a worker starts a claude session on a himmel test VM.
# Asserts: bad shape / unregistered VM / station VM refuse before any ssh; the
# dry-run guest command carries an explicit --permission-mode acceptEdits and an
# --allowedTools list, and never a skip-permissions flag.
# Platform: POSIX bash 3.2+.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
SCRIPT="$HERE/launch-guest.sh"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/launch-guest-test.XXXXXX")" || exit 1
trap 'rm -rf "$tmp"' EXIT
fails=0
check()    { [ "$2" = "$3" ] && echo "ok - $1" || { echo "FAIL - $1: [$2] != [$3]"; fails=$((fails+1)); }; }
contains() { case "$2" in *"$3"*) echo "ok - $1" ;; *) echo "FAIL - $1: missing [$3] in [$2]"; fails=$((fails+1)) ;; esac; }
lacks()    { case "$2" in *"$3"*) echo "FAIL - $1: found [$3]"; fails=$((fails+1)) ;; *) echo "ok - $1" ;; esac; }

# the prompt must live under the cwd's git worktree, so the suite runs from a scratch repo
tmp="$(cd "$tmp" && pwd -P)"
mkdir -p "$tmp/repo" && git -C "$tmp/repo" init -q || exit 1
printf 'do the thing\n' > "$tmp/repo/prompt.txt"
cat > "$tmp/vms.json" <<'J'
{
  "ubuntu_new": { "os": "ubuntu", "ssh_port": 2222, "user": "himmel" },
  "himmel-claudex": { "os": "ubuntu", "ssh_port": 2229, "user": "himmel" },
  "win11_base_himmel": { "os": "windows", "ssh_port": 2223, "user": "himmel" },
  "win2": { "os": "windows", "kind": "station", "host": "win2" },
  "ubuntu_new;id": { "os": "ubuntu", "ssh_port": 2225, "user": "himmel" },
  "ubuntu_station": { "os": "ubuntu", "kind": "station", "ssh_port": 2224, "user": "himmel" }
}
J
P="$tmp/repo/prompt.txt"
# no launch in this suite may write the operator's real cost ledger
export LAUNCH_GUEST_COST_LEDGER="$tmp/default-ledger.jsonl"
unset LAUNCH_GUEST_TICKET LAUNCH_GUEST_ACCOUNT
run() { (cd "$tmp/repo" && LAUNCH_GUEST_VMS_JSON="$tmp/vms.json" bash "$SCRIPT" "$@" 2>&1); }

rc=0; out="$(run)" || rc=$?
check "no args: exit 2" "$rc" "2"
rc=0; out="$(run ubuntu_new)" || rc=$?
check "one arg: exit 2" "$rc" "2"
rc=0; out="$(run nosuchvm "$P")" || rc=$?
check "unregistered vm: exit 2" "$rc" "2"
contains "unregistered vm: says so" "$out" "not a registered test VM"
rc=0; out="$(run win2 "$P")" || rc=$?
check "station vm: exit 2" "$rc" "2"
rc=0; out="$(run ubuntu_station "$P")" || rc=$?
check "ubuntu station with port and user: exit 2" "$rc" "2"
rc=0; out="$(run win11_base_himmel "$P")" || rc=$?
check "windows vm: exit 2 (ubuntu guests only)" "$rc" "2"
rc=0; out="$(run ubuntu_new "$tmp/repo/missing.txt")" || rc=$?
check "missing prompt file: exit 2" "$rc" "2"
rc=0; out="$(run 'ubuntu_new;id' "$P")" || rc=$?
check "metacharacter vm name: exit 2" "$rc" "2"

rc=0; out="$(run --dry-run ubuntu_new "$P")" || rc=$?
check "dry-run: exit 0" "$rc" "0"
contains "dry-run: ssh to the registered port" "$out" "-p 2222"
contains "dry-run: ssh user from the registry" "$out" "himmel@127.0.0.1"
contains "dry-run: explicit permission mode" "$out" "--permission-mode acceptEdits"
contains "dry-run: allowedTools list" "$out" "--allowedTools"
contains "dry-run: json output" "$out" "--output-format json"
lacks "dry-run: no skip-permissions" "$out" "skip-permissions"
lacks "dry-run: no bypassPermissions" "$out" "bypassPermissions"
contains "dry-run: bounded connect" "$out" "ConnectTimeout=15"

# the prompt file is read on the host, so it is confined to the worktree or the session scratchpad
printf 'x\n' > "$tmp/outside.txt"
rc=0; out="$(run --dry-run ubuntu_new "$tmp/outside.txt")" || rc=$?
check "prompt outside the worktree: exit 2" "$rc" "2"
contains "prompt outside the worktree: says so" "$out" "must live under"
printf 'SECRET=1\n' > "$tmp/repo/.env"
rc=0; out="$(run --dry-run ubuntu_new "$tmp/repo/.env")" || rc=$?
check "env file inside the worktree: exit 2" "$rc" "2"
for n in server.pem id_ed25519 credentials.json; do
    printf 'x\n' > "$tmp/repo/$n"
    rc=0; out="$(run --dry-run ubuntu_new "$tmp/repo/$n")" || rc=$?
    check "secret-shaped basename $n: exit 2" "$rc" "2"
done
ln -s "$tmp/repo/.env" "$tmp/repo/innocent.txt"
rc=0; out="$(run --dry-run ubuntu_new "$tmp/repo/innocent.txt")" || rc=$?
check "symlink to an env file: exit 2" "$rc" "2"
ln -s "$tmp/outside.txt" "$tmp/repo/escape.txt"
rc=0; out="$(run --dry-run ubuntu_new "$tmp/repo/escape.txt")" || rc=$?
check "symlink out of the worktree: exit 2" "$rc" "2"
rc=0; out="$(run --dry-run ubuntu_new "$tmp/repo/../outside.txt")" || rc=$?
check "dotdot out of the worktree: exit 2" "$rc" "2"
mkdir -p "$tmp/tmpbase/claude-$(id -u)/proj/sess/scratchpad"
printf 'x\n' > "$tmp/tmpbase/claude-$(id -u)/proj/sess/scratchpad/p.txt"
rc=0; out="$(TMPDIR="$tmp/tmpbase" run --dry-run ubuntu_new "$tmp/tmpbase/claude-$(id -u)/proj/sess/scratchpad/p.txt")" || rc=$?
check "session scratchpad prompt: exit 0" "$rc" "0"

rc=0; out="$(LAUNCH_GUEST_TIMEOUT=0 run --dry-run ubuntu_new "$P")" || rc=$?
check "zero timeout: exit 2" "$rc" "2"
rc=0; out="$(LAUNCH_GUEST_TIMEOUT=00 run --dry-run ubuntu_new "$P")" || rc=$?
check "all-zero timeout: exit 2" "$rc" "2"

mkdir -p "$tmp/bin"
printf '#!/bin/sh\necho STUB-SSH "$@"\n' > "$tmp/bin/ssh"; chmod +x "$tmp/bin/ssh"
printf '#!/bin/sh\necho SKIPPED-BANK\n' > "$tmp/pre-skip.sh"
printf '#!/bin/sh\necho PROCEED\n' > "$tmp/pre-ok.sh"
rc=0; out="$(PATH="$tmp/bin:$PATH" LAUNCH_GUEST_PREFLIGHT="$tmp/pre-skip.sh" run ubuntu_new "$P")" || rc=$?
check "exhausted bank: exit 2" "$rc" "2"
lacks "exhausted bank: no ssh" "$out" "STUB-SSH"
rc=0; out="$(PATH="$tmp/bin:$PATH" LAUNCH_GUEST_PREFLIGHT="$tmp/pre-ok.sh" run ubuntu_new "$P")" || rc=$?
check "bank ok: exit 0" "$rc" "0"
contains "bank ok: ssh runs" "$out" "STUB-SSH -p 2222"

# --- the claudex lane (R8-R13) and the pinned known_hosts on every lane (R10) ---
# ssh is a stub that logs one line per call; a --preflight-only call exits $GUEST_PF_RC, any other call is the session.
printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "$SSH_LOG"\ncase "$*" in *--preflight-only*) exit "${GUEST_PF_RC:-0}" ;; esac\necho STUB-SESSION\n' > "$tmp/bin/ssh"
chmod +x "$tmp/bin/ssh"
# the bank stub logs the lane it was asked about and answers per lane
printf '#!/bin/sh\necho "lane=${CADENCE_USAGE_LANE:-none}" >> "$BANK_LOG"\nif [ "${CADENCE_USAGE_LANE:-}" = claudex ]; then echo "${CODEX_V:-PROCEED}"; else echo "${CLAUDE_V:-PROCEED}"; fi\n' > "$tmp/pre-lane.sh"
export SSH_LOG="$tmp/ssh.log" BANK_LOG="$tmp/bank.log"
# the stubs read these; an operator's environment must not steer them
unset GUEST_PF_RC CODEX_V CLAUDE_V CADENCE_USAGE_LANE WORKER_SESSION_LANE
fresh() { rm -f "$SSH_LOG" "$BANK_LOG"; }
runv() { PATH="$tmp/bin:$PATH" LAUNCH_GUEST_PREFLIGHT="$tmp/pre-lane.sh" run "$@"; }
# shellcheck disable=SC2088  # the guest shell expands the tilde
CX=(--lane claudex --classifier-model gateway --debug-file '~/d.log')

fresh
rc=0; out="$(runv --dry-run "${CX[@]}" himmel-claudex "$P")" || rc=$?
check "R8 claudex dry-run: exit 0" "$rc" "0"
for w in "scripts/claude-codex" "--classifier-model gateway" "-p --permission-mode auto" "--settings ~/.config/himmel/worker-settings.json" "--debug-file ~/d.log" "timeout --signal=KILL" "--output-format json" "< $P" "-p 2229"; do
    contains "R8 claudex dry-run carries [$w]" "$out" "$w"
done
check "R8 claudex dry-run runs no ssh and no bank preflight" "$([ -e "$SSH_LOG" ] || [ -e "$BANK_LOG" ] && echo ran || echo none)" "none"

fresh
rc=0; out="$(runv "${CX[@]}" himmel-claudex "$P")" || rc=$?
check "R9 claudex launch: exit 0" "$rc" "0"
sess="$(grep -v -e preflight-only "$SSH_LOG" | tail -n 1)"
contains "R9 session argv carries --permission-mode auto" "$sess" "--permission-mode auto"
lacks "R9 session argv: no dangerously-skip-permissions" "$sess" "dangerously-skip-permissions"
lacks "R9 session argv: no bypassPermissions" "$sess" "bypassPermissions"

NATIVE_WANT="-p 2222 -o BatchMode=yes -o ConnectTimeout=15 -o UserKnownHostsFile=~/.himmel/vm/known_hosts/ubuntu_new -o StrictHostKeyChecking=accept-new himmel@127.0.0.1 bash -lc \"cd ~/Documents/github/himmel && timeout --signal=KILL 1800 claude -p --permission-mode acceptEdits --allowedTools 'Read,Grep,Glob,Edit,Write,Bash(git:*),Bash(bash scripts/*:*)' --output-format json\""
fresh; rc=0; out="$(runv ubuntu_new "$P")" || rc=$?
check "R10 native, no --lane: exact ssh argv" "$(cat "$SSH_LOG")" "$NATIVE_WANT"
fresh; rc=0; out="$(runv --lane native ubuntu_new "$P")" || rc=$?
check "R10 --lane native: exact ssh argv" "$(cat "$SSH_LOG")" "$NATIVE_WANT"
check "R10 native lane asks the default bank only" "$(cat "$BANK_LOG")" "lane=none"
fresh; rc=0; out="$(runv "${CX[@]}" himmel-claudex "$P")" || rc=$?
contains "R10 claudex ssh pins the per-VM known_hosts" "$(cat "$SSH_LOG")" "-o UserKnownHostsFile=~/.himmel/vm/known_hosts/himmel-claudex -o StrictHostKeyChecking=accept-new"

fresh
rc=0; out="$(runv --lane bogus ubuntu_new "$P")" || rc=$?
check "R11 --lane bogus: exit 2" "$rc" "2"
contains "R11 --lane bogus: usage line" "$out" "usage:"
rc=0; out="$(runv "${CX[@]}" ubuntu_new "$P")" || rc=$?
check "R11 claudex on another vm: exit 2" "$rc" "2"
rc=0; out="$(runv --lane claudex --debug-file '~/d.log' himmel-claudex "$P")" || rc=$?
check "R11 claudex without --classifier-model: exit 2" "$rc" "2"
rc=0; out="$(runv --lane claudex --classifier-model gateway himmel-claudex "$P")" || rc=$?
check "R11 claudex without --debug-file: exit 2" "$rc" "2"
rc=0; out="$(runv --lane claudex --classifier-model -p --debug-file '~/d.log' himmel-claudex "$P")" || rc=$?
check "R11 --classifier-model -p: exit 2" "$rc" "2"
check "R11 none of those reached ssh" "$([ -e "$SSH_LOG" ] && echo ran || echo none)" "none"

for g in 21 20 255; do
    fresh; rc=0; out="$(GUEST_PF_RC=$g runv "${CX[@]}" himmel-claudex "$P")" || rc=$?
    check "R12 guest preflight rc $g: refuses" "$rc" "2"
    check "R12 guest preflight rc $g: exactly one ssh call" "$(wc -l < "$SSH_LOG" | tr -d ' ')" "1"
done

fresh; rc=0; out="$(CODEX_V=SKIPPED-BANK runv "${CX[@]}" himmel-claudex "$P")" || rc=$?
check "R12b codex bank SKIPPED: refuses" "$rc" "2"
check "R12b codex bank SKIPPED: no session ssh" "$(grep -c -v preflight-only "$SSH_LOG")" "0"
fresh; rc=0; out="$(CLAUDE_V=SKIPPED-BANK runv --lane claudex --classifier-model claude-sonnet-5 --debug-file '~/d.log' himmel-claudex "$P")" || rc=$?
check "R12b claude bank SKIPPED with a claude classifier: refuses" "$rc" "2"
check "R12b both banks were asked" "$(sort "$BANK_LOG" | tr '\n' ' ')" "lane=claudex lane=native "
fresh; rc=0; out="$(CLAUDE_V=SKIPPED-BANK runv "${CX[@]}" himmel-claudex "$P")" || rc=$?
check "R12b gateway classifier: claude bank not consulted, launches" "$rc" "0"
check "R12b gateway classifier: only the codex bank was asked" "$(cat "$BANK_LOG")" "lane=claudex"

fresh
for pair in "x; --dangerously-skip-permissions|~/d.log" "gateway|~/a b" "gateway|~/../x"; do
    rc=0; out="$(runv --lane claudex --classifier-model "${pair%%|*}" --debug-file "${pair#*|}" himmel-claudex "$P")" || rc=$?
    check "R13 rejects [$pair]" "$rc" "2"
done
check "R13 none of those reached ssh" "$([ -e "$SSH_LOG" ] && echo ran || echo none)" "none"

# --- one cost ledger row per launched run, summed by vm-cost.sh ---
# the ssh stub now answers like a guest claude -p --output-format json
COST="$HERE/vm-cost.sh"
LEDGER="$tmp/vm-cost.jsonl"
printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "$SSH_LOG"\necho "{\\"type\\":\\"result\\",\\"total_cost_usd\\":1.25}"\n' > "$tmp/bin/ssh"
chmod +x "$tmp/bin/ssh"
runc() { LAUNCH_GUEST_COST_LEDGER="$LEDGER" LAUNCH_GUEST_TICKET=HIMMEL-1 runv "$@"; }
# like runc but stderr is left to the caller, so stdout and stderr can be asserted apart
runo() { _l="$1"; shift; (cd "$tmp/repo" && LAUNCH_GUEST_VMS_JSON="$tmp/vms.json" LAUNCH_GUEST_COST_LEDGER="$_l" LAUNCH_GUEST_TICKET=HIMMEL-1 PATH="$tmp/bin:$PATH" LAUNCH_GUEST_PREFLIGHT="$tmp/pre-lane.sh" bash "$SCRIPT" "$@"); }
rows() { if [ -f "$LEDGER" ]; then wc -l < "$LEDGER" | tr -d ' '; else echo 0; fi; }

fresh; rm -f "$LEDGER"
rc=0; out="$(runo "$LEDGER" ubuntu_new "$P" 2>/dev/null)" || rc=$?
check "C1 stubbed run: exit 0" "$rc" "0"
check "C1 stubbed run: stdout is exactly the guest result" "$out" '{"type":"result","total_cost_usd":1.25}'
check "C1 stubbed run writes exactly one row" "$(rows)" "1"
row="$(cat "$LEDGER" 2>/dev/null)"
check "C1 row: ticket" "$(printf '%s' "$row" | jq -r .ticket 2>/dev/null)" "HIMMEL-1"
check "C1 row: vm" "$(printf '%s' "$row" | jq -r .vm 2>/dev/null)" "ubuntu_new"
check "C1 row: account label defaults to the vm" "$(printf '%s' "$row" | jq -r .account 2>/dev/null)" "ubuntu_new"
check "C1 row: usd from the guest result" "$(printf '%s' "$row" | jq -r .usd 2>/dev/null)" "1.25"
check "C1 row: seconds is a whole number" "$(printf '%s' "$row" | jq -r '.seconds | type' 2>/dev/null)" "number"
check "C1 row: utc stamp" "$(printf '%s' "$row" | jq -r '.ts | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z$")' 2>/dev/null)" "true"

fresh; rm -f "$LEDGER"
rc=0; out="$(runc --dry-run ubuntu_new "$P")" || rc=$?
check "C2 dry-run writes no row" "$(rows)" "0"
rc=0; out="$(runc nosuchvm "$P")" || rc=$?
check "C2 refused vm writes no row" "$(rows)" "0"
rc=0; out="$(PATH="$tmp/bin:$PATH" LAUNCH_GUEST_COST_LEDGER="$LEDGER" LAUNCH_GUEST_PREFLIGHT="$tmp/pre-skip.sh" run ubuntu_new "$P")" || rc=$?
check "C2 exhausted bank writes no row" "$(rows)" "0"

# a guest answer that is not json still records the run, with a null usd and its source
printf '#!/bin/sh\necho NOT-JSON\nexit 7\n' > "$tmp/bin/ssh"
rm -f "$LEDGER"
rc=0; out="$(runc ubuntu_new "$P")" || rc=$?
check "C3 failing guest: rc passes through" "$rc" "7"
row="$(cat "$LEDGER" 2>/dev/null)"
check "C3 non-json answer: one row" "$(rows)" "1"
check "C3 non-json answer: usd null" "$(printf '%s' "$row" | jq -r '.usd' 2>/dev/null)" "null"
check "C3 non-json answer: usd_source unknown" "$(printf '%s' "$row" | jq -r '.usd_source' 2>/dev/null)" "unknown"

# the account label is a label: a token-shaped value is refused before any ssh
fresh; rm -f "$LEDGER"
rc=0; out="$(LAUNCH_GUEST_ACCOUNT='sk-ant x;id' runc ubuntu_new "$P")" || rc=$?
check "C4 bad account label: exit 2" "$rc" "2"
check "C4 bad account label: no row" "$(rows)" "0"
for lbl in sk-ant-api03-abcDEF123 SK-ANT-abc sk-proj-abc; do
    fresh; rm -f "$LEDGER"
    rc=0; out="$(LAUNCH_GUEST_ACCOUNT="$lbl" runc ubuntu_new "$P")" || rc=$?
    check "C4 token-shaped label $lbl: exit 2" "$rc" "2"
    check "C4 token-shaped label $lbl: no row and no ssh" "$(rows)$([ -e "$SSH_LOG" ] && echo ran)" "0"
done

# vm-cost.sh: a two-row fixture prints the sum per ticket and per account
cat > "$tmp/two.jsonl" <<'J'
{"ticket":"HIMMEL-1","vm":"ubuntu_new","account":"acct-a","seconds":100,"usd":1.5,"usd_source":"guest-json","ts":"2026-11-01T10:00:00Z"}
{"ticket":"HIMMEL-1","vm":"ubuntu_new","account":"acct-b","seconds":200,"usd":2.25,"usd_source":"guest-json","ts":"2026-11-01T11:00:00Z"}
{"ticket":"HIMMEL-2","vm":"ubuntu_new","account":"acct-a","seconds":50,"usd":null,"usd_source":"unknown","ts":"2026-11-01T12:00:00Z"}
J
rc=0; out="$(LAUNCH_GUEST_COST_LEDGER="$tmp/two.jsonl" bash "$COST" 2>&1)" || rc=$?
check "C5 vm-cost: exit 0" "$rc" "0"
check "C5 vm-cost: the whole report is exactly the four expected rows" "$out" "$(printf 'ticket\tHIMMEL-1\t2\t300\t3.75\t0\nticket\tHIMMEL-2\t1\t50\t0\t1\naccount\tacct-a\t2\t150\t1.5\t1\naccount\tacct-b\t1\t200\t2.25\t0')"
rc=0; out="$(LAUNCH_GUEST_COST_LEDGER="$tmp/none.jsonl" bash "$COST" 2>&1)" || rc=$?
check "C5 vm-cost: no ledger: exit 1" "$rc" "1"
rc=0; out="$(LAUNCH_GUEST_COST_LEDGER="$tmp/two.jsonl" bash "$COST" --bogus 2>&1)" || rc=$?
check "C5 vm-cost: bad flag: exit 2" "$rc" "2"
rc=0; out="$(LAUNCH_GUEST_COST_LEDGER="$tmp/two.jsonl" bash "$COST" --path 2>&1)" || rc=$?
check "C5 vm-cost --path: override is printed" "$out" "$tmp/two.jsonl"
mkdir -p "$tmp/hd"
rc=0; out="$(unset LAUNCH_GUEST_COST_LEDGER; HANDOVER_DIR="$tmp/hd" bash "$COST" --path 2>&1)" || rc=$?
check "C5 vm-cost --path: default sits under the handover root" "$out" "$tmp/hd/.ledger/vm-cost.jsonl"
rc=0; out="$(LAUNCH_GUEST_COST_LEDGER="$tmp/two.jsonl" bash "$COST" --path extra 2>&1)" || rc=$?
check "C5 vm-cost --path with an extra argument: exit 2" "$rc" "2"
rc=0; out="$(LAUNCH_GUEST_COST_LEDGER="$tmp/two.jsonl" bash "$COST" '' --bogus 2>&1)" || rc=$?
check "C5 vm-cost: an empty first argument is not the default report: exit 2" "$rc" "2"
rc=0; out="$(LAUNCH_GUEST_COST_LEDGER="$tmp" bash "$COST" 2>&1)" || rc=$?
check "C5 vm-cost: an unreadable ledger (a directory) is not an empty report: nonzero" "$([ "$rc" -ne 0 ] && echo nonzero || echo zero)" "nonzero"

# a signal to the launcher reaches the guest ssh and the cut-short run still gets its row.
# pid_state is alive or gone for a real pid and unstarted for an empty or non-numeric one, so a
# stub ssh that never ran can not read as "gone".
pid_state() { case "$1" in ''|*[!0-9]*) echo unstarted ;; *) if kill -0 "$1" 2>/dev/null; then echo alive; else echo gone; fi ;; esac; }
printf '#!/bin/sh\necho $$ > "$SLEEP_PID"\nexec sleep 30\n' > "$tmp/bin/ssh"
export SLEEP_PID="$tmp/sleeper.pid"
rm -f "$LEDGER" "$SLEEP_PID"
(cd "$tmp/repo" && exec env PATH="$tmp/bin:$PATH" LAUNCH_GUEST_VMS_JSON="$tmp/vms.json" LAUNCH_GUEST_PREFLIGHT="$tmp/pre-ok.sh" LAUNCH_GUEST_COST_LEDGER="$LEDGER" LAUNCH_GUEST_TICKET=HIMMEL-1 bash "$SCRIPT" ubuntu_new "$P" > /dev/null 2>&1) &
lpid=$!
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do [ -s "$SLEEP_PID" ] && break; sleep 0.25; done
spid="$(cat "$SLEEP_PID" 2>/dev/null)"
check "C6 SIGTERM: the stub ssh started" "$(pid_state "$spid")" "alive"
check "C6 SIGTERM: the signal reached the launcher" "$(kill -TERM "$lpid" 2>/dev/null && echo sent || echo not-sent)" "sent"
rc=0; wait "$lpid" || rc=$?
check "C6 SIGTERM to the launcher: the guest ssh is gone" "$(pid_state "$spid")" "gone"
check "C6 SIGTERM to the launcher: the cut-short run has its row" "$(rows)" "1"
check "C6 SIGTERM to the launcher: exit is the signalled child's" "$rc" "143"
kill "$spid" 2>/dev/null

# a terminal Ctrl-C or Ctrl-\ must end the guest run. The launcher starts with the default
# disposition (perl resets what a background subshell inherited), and a background child of a
# non-interactive bash starts with SIGINT and SIGQUIT ignored, so a forwarded INT or QUIT would
# be ignored by the ssh: the launcher has to send TERM.
printf '#!/bin/sh\necho $$ > "$SLEEP_PID"\nexec sleep 8\n' > "$tmp/bin/ssh"
for sig in INT QUIT; do
    rm -f "$LEDGER" "$SLEEP_PID"
    (cd "$tmp/repo" && exec perl -e '$SIG{INT} = "DEFAULT"; $SIG{QUIT} = "DEFAULT"; exec @ARGV' env PATH="$tmp/bin:$PATH" LAUNCH_GUEST_VMS_JSON="$tmp/vms.json" LAUNCH_GUEST_PREFLIGHT="$tmp/pre-ok.sh" LAUNCH_GUEST_COST_LEDGER="$LEDGER" LAUNCH_GUEST_TICKET=HIMMEL-1 bash "$SCRIPT" ubuntu_new "$P" > /dev/null 2>&1) &
    lpid=$!
    for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do [ -s "$SLEEP_PID" ] && break; sleep 0.25; done
    spid="$(cat "$SLEEP_PID" 2>/dev/null)"
    check "C7 SIG$sig: the stub ssh started" "$(pid_state "$spid")" "alive"
    check "C7 SIG$sig: the signal reached the launcher" "$(kill -"$sig" "$lpid" 2>/dev/null && echo sent || echo not-sent)" "sent"
    sleep 1
    check "C7 SIG$sig to the launcher: the guest ssh is gone" "$(pid_state "$spid")" "gone"
    kill "$spid" 2>/dev/null
    rc=0; wait "$lpid" || rc=$?
    check "C7 SIG$sig to the launcher: exit is the terminated child's" "$rc" "143"
done

# a ledger that cannot be written never changes the run: the answer and the exit code stay the guest's
printf '#!/bin/sh\necho "{\\"total_cost_usd\\":0.5}"\nexit 3\n' > "$tmp/bin/ssh"
mkdir -p "$tmp/ledger-is-a-dir"
rc=0; out="$(runo "$tmp/ledger-is-a-dir" ubuntu_new "$P" 2>"$tmp/c8.err")" || rc=$?
check "C8 unwritable ledger: the guest's exit code is unchanged" "$rc" "3"
check "C8 unwritable ledger: stdout is exactly the guest answer" "$out" '{"total_cost_usd":0.5}'
contains "C8 unwritable ledger: says the row was not written" "$(cat "$tmp/c8.err")" "could not write the cost ledger row"

echo "---"
if [ "$fails" -eq 0 ]; then echo "PASS - test-launch-guest.sh"; exit 0; fi
echo "FAIL - test-launch-guest.sh ($fails failure(s))"; exit 1
