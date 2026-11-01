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

echo "---"
if [ "$fails" -eq 0 ]; then echo "PASS - test-launch-guest.sh"; exit 0; fi
echo "FAIL - test-launch-guest.sh ($fails failure(s))"; exit 1
