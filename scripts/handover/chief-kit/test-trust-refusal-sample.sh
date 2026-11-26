#!/usr/bin/env bash
# test-trust-refusal-sample.sh - fixture suite for trust-refusal-sample.sh (slice 2 of the 24-hour trust run, sampler 3).
# The first rows are the plan's control: one launch refusal, one known over-deny and the same classifier denial
# in a transcript and in the denial log give three rows, the over-deny `false`. Hermetic: transcripts, denial log,
# launch record and front-matter record are fixtures under fixtures/trust-refusal/; friction.py is the real reader.
#
# PLATFORM GUARD: the chief kit is Linux-only; this Bash 3.2 suite exercises that platform-specific script.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="$HERE/trust-refusal-sample.sh"
FIX="$HERE/fixtures/trust-refusal"
fails=0
pass() { printf 'PASS - %s\n' "$1"; }
fail() { printf 'FAIL - %s\n' "$1"; fails=$((fails + 1)); }
same() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (got '$2', want '$3')"; fi; }

W="$(mktemp -d "${TMPDIR:-/tmp}/test-trust-refusal.XXXXXX")" || exit 1
trap 'rm -rf "$W"' EXIT
mkdir -p "$W/empty-bucket"

SINCE=2026-11-25T10:00:00Z
NOW=2026-11-25T11:00:00Z
run() {
    bash "$SUT" --projects "$FIX/projects" --denials "$FIX/classifier-denials.jsonl" --launch-refusals "$FIX/launch-refusals.jsonl" \
        --bucket "$W/empty-bucket" --since "$SINCE" --now "$NOW" "$@" 2>/dev/null
}
count() { printf '%s\n' "$1" | grep -c '^{'; }
jf() { printf '%s\n' "$1" | jq -r "$2" 2>/dev/null; }

before="$(cd "$FIX" && find . -type f -exec cksum {} + | sort | cksum)"

out="$(run)"; rc=$?
same 'control: one launch refusal, one over-deny and one classifier denial seen twice give three rows' "$(count "$out")" '3'
same 'control: the known over-deny is verdict false' "$(jf "$out" 'select(.source == "hook:guard-pr-check-literal") | .verdict')" 'false'
same 'control: the classifier denial seen in transcript and log is one row' "$(jf "$out" 'select(.source == "classifier") | .kind' | grep -c command)" '1'

same 'the run exits 0' "$rc" '0'
same 'every row has exactly ts, kind, source, reason and verdict' "$(printf '%s\n' "$out" | jq -c 'keys' | sort -u)" '["kind","reason","source","ts","verdict"]'
same 'the launch refusal is kind launch, unsorted, with the stated reason' "$(jf "$out" 'select(.kind == "launch") | [.source, .reason, .verdict] | join(" | ")')" 'launch:brief-lint | the brief front matter did not parse | unsorted'
same 'a classifier denial is unsorted until sorted by hand' "$(jf "$out" 'select(.source == "classifier") | .verdict')" 'unsorted'
same 'a command refusal carries its reason class, not the command' "$(jf "$out" 'select(.source == "classifier") | .reason | startswith("classifier-out-of-place-publication")')" 'true'
same 'a row has its time in UTC' "$(jf "$out" 'select(.kind == "launch") | .ts')" '2026-11-25T10:30:00Z'
same 'rows are in time order' "$(jf "$out" '.ts' | sort -c && echo sorted)" 'sorted'
same 'no row carries command text' "$(printf '%s\n' "$out" | grep -c LEAKCHECK)" '0'
same 'a refusal before the window is not a row' "$(printf '%s\n' "$out" | grep -c -E 'unauthorized-persistence|fleet-cap')" '0'
same 'an attempt-started and a launched row are not refusals' "$(jf "$out" 'select(.kind == "launch") | .ts' | wc -l | tr -d ' ')" '1'

out2="$(run --denials "$FIX/classifier-denials-extra.jsonl")"
same 'a denial of another session, and one only in the log, are rows of their own' "$(count "$out2")" '5'
same 'the log-only denial is a command row' "$(jf "$out2" 'select(.reason == "classifier-unauthorized-persistence") | .kind')" 'command'
out3="$(run --bucket "$FIX/bucket")"
same 'the front-matter refusal of a brief already refused at launch is counted once' "$(count "$out3")" '4'
same 'a front-matter refusal of another brief is a launch row' "$(jf "$out3" 'select(.source == "front-matter") | .reason')" 'brief front matter did not parse (line 4)'

out4="$(run --bucket "$FIX/bucket-twice")"
same 'a launch refusal matches one front-matter refusal, so a second of the same brief is a row' "$(count "$out4")" '4'
out5="$(run --projects "$FIX/projects-merge")"
same 'a merge refusal is kind merge' "$(jf "$out5" 'select(.kind == "merge") | .source')" 'hook:block-unresolved-cr-merge'
same 'a merge refusal is unsorted whatever friction.py judged' "$(jf "$out5" 'select(.kind == "merge") | .verdict')" 'unsorted'

primary_name="$(basename "$(dirname "$(git -C "$HERE" rev-parse --path-format=absolute --git-common-dir)")")"
mkdir -p "$W/ho/fixture/$primary_name"
dflt="$(HANDOVER_DIR="$W/ho" USER_SLUG=fixture bash "$SUT" --projects "$FIX/projects" --denials "$FIX/classifier-denials.jsonl" --launch-refusals "$FIX/launch-refusals.jsonl" --since "$SINCE" --now "$NOW" 2>/dev/null)"
same 'with no --bucket the handover root, user slug and primary checkout name give the bucket' "$dflt" "$out"
u="$(HANDOVER_DIR="$W/ho" USER_SLUG=nobody bash "$SUT" --projects "$FIX/projects" --denials "$FIX/classifier-denials.jsonl" --launch-refusals "$FIX/launch-refusals.jsonl" --since "$SINCE" --now "$NOW" 2>/dev/null)"; urc=$?
same 'a bucket that is not there prints UNKNOWN bucket' "$u" 'UNKNOWN bucket'
same 'a bucket that is not there exits 3' "$urc" '3'

u="$(bash "$SUT" --projects "$W/no-projects" --denials "$FIX/classifier-denials.jsonl" --launch-refusals "$FIX/launch-refusals.jsonl" --bucket "$W/empty-bucket" --since "$SINCE" --now "$NOW" 2>/dev/null)"; urc=$?
same 'no transcript directory prints UNKNOWN transcripts' "$u" 'UNKNOWN transcripts'
same 'no transcript directory exits 3' "$urc" '3'
u="$(run --denials "$W/none.jsonl")"; urc=$?
same 'a missing denial log prints UNKNOWN classifier-denials' "$u" 'UNKNOWN classifier-denials'
same 'a missing denial log exits 3' "$urc" '3'
u="$(run --launch-refusals "$W/none.jsonl")"; urc=$?
same 'a missing launch record prints UNKNOWN launch-refusals' "$u" 'UNKNOWN launch-refusals'
same 'a missing launch record exits 3' "$urc" '3'
mkdir -p "$W/bad-bucket/front-matter-refusals.jsonl"
u="$(run --bucket "$W/bad-bucket")"; urc=$?
same 'a front-matter record that cannot be read prints UNKNOWN front-matter-refusals' "$u" 'UNKNOWN front-matter-refusals'
same 'a front-matter record that cannot be read exits 3' "$urc" '3'

after="$(cd "$FIX" && find . -type f -exec cksum {} + | sort | cksum)"
same 'the sampler writes nothing under its sources' "$after" "$before"

printf '%s\n' "$fails failing row(s)"
[ "$fails" -eq 0 ]
