#!/usr/bin/env bash
# test-trust-owner-sample.sh - fixture suite for trust-owner-sample.sh (slice 2 of the 24-hour trust run, sampler 1).
# The first two rows are the plan's control: a started ticket with no live owner reports UNOWNED, the
# same kind of ticket bound to a T3 thread reports t3. Hermetic: the fixture tree is built under a
# scratch dir by fixtures/trust-owner/build.sh; no live mirror, fleet, process table or network.
#
# PLATFORM GUARD: the chief kit is Linux-only (the pid proof reads /proc through a seam dir here);
# this Bash 3.2 suite exercises that platform-specific script.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="$HERE/trust-owner-sample.sh"
fails=0
pass() { printf 'PASS - %s\n' "$1"; }
fail() { printf 'FAIL - %s\n' "$1"; fails=$((fails + 1)); }
same() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (got '$2', want '$3')"; fi; }

W="$(mktemp -d "${TMPDIR:-/tmp}/test-trust-owner.XXXXXX")" || exit 1
trap 'rm -rf "$W"' EXIT
F="$W/f"
bash "$HERE/fixtures/trust-owner/build.sh" "$F" || { printf 'FAIL - fixture build\n'; exit 1; }
NOW=2026-11-26T01:00:00Z
run() { CLAUDE_SESSIONS_PROC="$F/proc" bash "$SUT" --mirror "$F/mirror-root/HIMMEL" --bucket "$F/bucket" --config-dir "$F/config" --now "$NOW" "$@" 2>/dev/null; }
field() { printf '%s\n' "$1" | jq -r --arg k "$2" --arg f "$3" 'select(.key == $k) | .[$f]' 2>/dev/null; }

before="$(cd "$F" && find . -type f -exec cksum {} + | sort | cksum)"
out="$(run)"; rc=$?

same 'control: a started ticket with no live owner is UNOWNED' "$(field "$out" FIX-1 owner_kind)" 'UNOWNED'
same 'control: the same kind of ticket bound to a T3 thread is t3' "$(field "$out" FIX-3 owner_kind)" 't3'
same 'the t3 row names the thread' "$(field "$out" FIX-3 owner)" 'thr-3'
same 'the run exits 0' "$rc" '0'

same 'a worker whose session id is proven by a live pid is worker' "$(field "$out" FIX-2 owner_kind)" 'worker'
case "$(field "$out" FIX-2 proof)" in *4242*) pass 'the worker row names the proven pid' ;; *) fail "the worker row names the proven pid (got '$(field "$out" FIX-2 proof)')" ;; esac
same 'a live cloud session of the last 48 h is cloud' "$(field "$out" FIX-4 owner_kind)" 'cloud'
same 'a READY bullet in a chief doc is chief-go' "$(field "$out" FIX-5 owner_kind)" 'chief-go'
same 'the chief-go row names the chief doc' "$(field "$out" FIX-5 owner)" 'FIX-nextleg-2026-11-26A-fixture-chief.md'
same 'a fleet row of lane peer is peer' "$(field "$out" FIX-10 owner_kind)" 'peer'

same 'a recycled pid (start time differs) is not a live worker' "$(field "$out" FIX-8 owner_kind)" 'UNOWNED'
same 'a cloud session older than 48 h is not an owner' "$(field "$out" FIX-9 owner_kind)" 'UNOWNED'
same 'FIX-10 owning a doc does not give FIX-1 an owner (key prefix)' "$(field "$out" FIX-1 owner_kind)" 'UNOWNED'
same 'only started tickets get a row (To Do and Done get none)' "$(printf '%s\n' "$out" | grep -c '^{')" '8'
same 'a To Do ticket has no row' "$(field "$out" FIX-6 owner_kind)" ''
same 'a Done ticket has no row' "$(field "$out" FIX-7 owner_kind)" ''

same 'every row carries the sample time' "$(printf '%s\n' "$out" | jq -r 'select(.ts != "2026-11-26T01:00:00Z") | .key')" ''
same 'a mirror synced 10 minutes ago is 600 s old' "$(field "$out" FIX-1 mirror_age_s)" '600'
same 'a mirror inside 15 minutes is not stale' "$(field "$out" FIX-1 stale)" 'false'
same 'every row carries status' "$(field "$out" FIX-3 status)" 'In Review'
late="$(NOW=x run --now 2026-11-26T01:30:00Z)"
same 'a stale sample still lists every started ticket' "$(printf '%s\n' "$late" | grep -c '^{')" '8'
same 'a mirror older than 15 minutes marks every row stale' "$(printf '%s\n' "$late" | jq -r 'select(.stale != true) | .key')" ''
same 'a stale mirror still reports the age (40 min)' "$(field "$late" FIX-1 mirror_age_s)" '2400'

u="$(CLAUDE_SESSIONS_PROC="$F/proc" bash "$SUT" --mirror "$W/nomirror" --bucket "$F/bucket" --config-dir "$F/config" --now "$NOW" 2>/dev/null)"; urc=$?
same 'a missing mirror prints UNKNOWN mirror' "$u" 'UNKNOWN mirror'
same 'a missing mirror exits 3' "$urc" '3'
mkdir -p "$W/nomanifest"
cp "$F/bucket/cloud-sessions.tsv" "$W/nomanifest/"
u="$(CLAUDE_SESSIONS_PROC="$F/proc" bash "$SUT" --mirror "$F/mirror-root/HIMMEL" --bucket "$W/nomanifest" --config-dir "$F/config" --now "$NOW" 2>/dev/null)"; urc=$?
same 'a bucket with no fleet manifest prints UNKNOWN manifests' "$u" 'UNKNOWN manifests'
same 'a bucket with no fleet manifest exits 3' "$urc" '3'
mkdir -p "$W/nocloud"
cp "$F/bucket/"*.fleet.json "$F/bucket/"*.md "$W/nocloud/"
u="$(CLAUDE_SESSIONS_PROC="$F/proc" bash "$SUT" --mirror "$F/mirror-root/HIMMEL" --bucket "$W/nocloud" --config-dir "$F/config" --now "$NOW" 2>/dev/null)"; urc=$?
same 'a bucket with no cloud-sessions.tsv prints UNKNOWN cloud-sessions' "$u" 'UNKNOWN cloud-sessions'
same 'a bucket with no cloud-sessions.tsv exits 3' "$urc" '3'
printf '{"workers":[' > "$W/nomanifest/broken.fleet.json"
u="$(CLAUDE_SESSIONS_PROC="$F/proc" bash "$SUT" --mirror "$F/mirror-root/HIMMEL" --bucket "$W/nomanifest" --config-dir "$F/config" --now "$NOW" 2>/dev/null)"; urc=$?
same 'a manifest that is not JSON prints UNKNOWN manifests' "$u" 'UNKNOWN manifests'
same 'a manifest that is not JSON exits 3' "$urc" '3'

after="$(cd "$F" && find . -type f -exec cksum {} + | sort | cksum)"
same 'the sampler writes nothing under its sources' "$after" "$before"

printf '%s\n' "$fails failing row(s)"
[ "$fails" -eq 0 ]
