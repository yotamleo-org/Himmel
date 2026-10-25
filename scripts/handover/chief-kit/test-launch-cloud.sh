#!/usr/bin/env bash
# test-launch-cloud.sh — Exercises launch-cloud.sh with konsole,
# script(1) and claude stubbed on PATH: no real cloud session is ever launched.
# bash 3.2-safe.
#
# LAUNCH_CLOUD overrides the script under test (the RED control: a missing
# script fails every case).
#
# Run: bash scripts/handover/console-kit/test-launch-cloud.sh
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
LAUNCH="${LAUNCH_CLOUD:-$HERE/launch-cloud.sh}"

fails=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; fails=$((fails + 1)); }
check() { # <name> <expected> <actual>
    if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (want '$2' got '$3')"; fi
}
has() { # <name> <needle> <haystack>
    case "$3" in *"$2"*) pass "$1" ;; *) fail "$1 (no '$2' in '$3')" ;; esac
}

WORK="$(mktemp -d "${TMPDIR:-/tmp}/launch-cloud-test.XXXXXX")" || { echo "mktemp -d failed" >&2; exit 1; }
trap 'rm -rf "$WORK"' EXIT

BIN="$WORK/bin"
BUCKET="$WORK/bucket"
RUNDIR="$WORK/run"
mkdir -p "$BIN" "$BUCKET"

# konsole: run everything after -e in the foreground.
cat > "$BIN/konsole" <<'EOF'
#!/usr/bin/env bash
while [ "$#" -gt 0 ]; do
    if [ "$1" = "-e" ]; then shift; exec "$@"; fi
    shift
done
exit 1
EOF
# setsid: absent on macOS; the stub only has to run its command.
cat > "$BIN/setsid" <<'EOF'
#!/bin/sh
exec "$@"
EOF
# script(1): script -q -c <cmd> <logfile>
cat > "$BIN/script" <<'EOF'
#!/usr/bin/env bash
cmd=""; log=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        -q) shift ;;
        -c) cmd="$2"; shift 2 ;;
        *) log="$1"; shift ;;
    esac
done
bash -c "$cmd" > "$log" 2>&1
EOF
# claude: record argv, print the line the real CLI prints.
cat > "$BIN/claude" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$CLAUDE_ARGV"
printf 'Created cloud session session_01ABCxyz\nView: https://claude.ai/code/session_01ABCxyz\n'
EOF
chmod +x "$BIN/konsole" "$BIN/setsid" "$BIN/script" "$BIN/claude"

export PATH="$BIN:$PATH"
export HIMMEL_BUCKET_DIR="$BUCKET"
export HIMMEL_CONSOLE_RUNDIR="$RUNDIR"
export CLAUDE_ARGV="$WORK/claude.argv"
export CLOUD_LAUNCH_POLLS=5
export CLOUD_LAUNCH_SLEEP=0.2

# --- no argument and a missing brief ---------------------------------------
bash "$LAUNCH" >/dev/null 2>&1
check 'no ticket argument exits 2' 2 "$?"

out="$(bash "$LAUNCH" 9999 2>&1)"; rc=$?
check 'missing brief exits 2' 2 "$rc"
has 'missing brief names the brief path' "cloud-brief-HIMMEL-9999.md" "$out"
if [ ! -e "$BUCKET/cloud-sessions.tsv" ]; then pass 'missing brief writes no tsv row'; else fail 'missing brief wrote a tsv row'; fi

# --- happy path --------------------------------------------------------------
printf 'do the cloud work\n' > "$BUCKET/cloud-brief-HIMMEL-1234.md"
out="$(bash "$LAUNCH" 1234 2>&1)"; rc=$?
check 'launch exits 0' 0 "$rc"
has 'prints the Created cloud session line' 'Created cloud session session_01ABCxyz' "$out"

argv="$(cat "$CLAUDE_ARGV" 2>/dev/null)"
has 'claude gets --cloud' '--cloud' "$argv"
has 'claude gets the brief text' 'do the cloud work' "$argv"
has 'claude keeps --permission-mode' '--permission-mode' "$argv"
has 'claude keeps auto mode' 'auto' "$argv"

tsv="$(cat "$BUCKET/cloud-sessions.tsv" 2>/dev/null)"
has 'tsv row has the ticket' 'HIMMEL-1234' "$tsv"
has 'tsv row has the teleport command' 'claude --teleport session_01ABCxyz' "$tsv"
check 'tsv row has 4 tab fields' 4 "$(printf '%s\n' "$tsv" | awk -F'\t' 'END{print NF}')"

# --- a second launch appends --------------------------------------------------
printf 'second\n' > "$BUCKET/cloud-brief-HIMMEL-5678.md"
bash "$LAUNCH" 5678 >/dev/null 2>&1
check 'second launch appends a row' 2 "$(wc -l < "$BUCKET/cloud-sessions.tsv" | tr -d ' ')"

# --- guards: a prompt-free allow rule runs this script, so each must be pinned --
rows_before="$(wc -l < "$BUCKET/cloud-sessions.tsv" | tr -d ' ')"

# (a) a ticket with a path separator is refused before anything is written. The
# traversal target exists, so without the guard the launch would go through.
RUN_A="$WORK/run-a"
mkdir -p "$RUN_A/cloud-a" "$BUCKET/cloud-brief-HIMMEL-a"
printf 'traversal\n' > "$BUCKET/cloud-brief-HIMMEL-a/b.md"
HIMMEL_CONSOLE_RUNDIR="$RUN_A" bash "$LAUNCH" a/b >/dev/null 2>&1; rc=$?
check 'ticket with a slash exits 2' 2 "$rc"
check 'ticket with a slash creates no log or inner script' 0 "$(find "$RUN_A" -type f | wc -l | tr -d ' ')"
check 'ticket with a slash adds no tsv row' "$rows_before" "$(wc -l < "$BUCKET/cloud-sessions.tsv" | tr -d ' ')"

# (b) a symlinked run dir is refused and nothing is written through it.
rows_before="$(wc -l < "$BUCKET/cloud-sessions.tsv" | tr -d ' ')"
REAL_B="$WORK/real-b"
mkdir -p "$REAL_B"
ln -s "$REAL_B" "$WORK/link-b"
HIMMEL_CONSOLE_RUNDIR="$WORK/link-b" bash "$LAUNCH" 1234 >/dev/null 2>&1; rc=$?
check 'symlinked run dir exits 2' 2 "$rc"
check 'symlinked run dir receives no files' 0 "$(find "$REAL_B" -type f | wc -l | tr -d ' ')"
check 'symlinked run dir adds no tsv row' "$rows_before" "$(wc -l < "$BUCKET/cloud-sessions.tsv" | tr -d ' ')"

# (c) an existing run dir with loose permissions is tightened to 700.
RUN_C="$WORK/run-c"
mkdir -p "$RUN_C"
chmod 755 "$RUN_C"
HIMMEL_CONSOLE_RUNDIR="$RUN_C" bash "$LAUNCH" 1234 >/dev/null 2>&1; rc=$?
check 'launch into a pre-existing run dir exits 0' 0 "$rc"
check 'pre-existing 0755 run dir is mode 700 after a launch' 1 "$(find "$RUN_C" -maxdepth 0 -perm 700 | wc -l | tr -d ' ')"

# --- no output ever appears ---------------------------------------------------
cat > "$BIN/claude" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
printf 'third\n' > "$BUCKET/cloud-brief-HIMMEL-4242.md"
rows_pre="$(wc -l < "$BUCKET/cloud-sessions.tsv" | tr -d ' ')"
out="$(bash "$LAUNCH" 4242 2>&1)"; rc=$?
check 'no output exits 1' 1 "$rc"
check 'no output adds no tsv row' "$rows_pre" "$(wc -l < "$BUCKET/cloud-sessions.tsv" | tr -d ' ')"

# --- portability: no hardcoded user path ---------------------------------------
hardcode_re='/home/[A-Za-z]|yotamleo|/run/user/[0-9]'
printf 'x=/%s/someone/y\n' home > "$WORK/positive-control.txt"
if grep -qE "$hardcode_re" "$WORK/positive-control.txt"; then
    pass 'portability matcher detects a hardcoded path (positive control)'
else
    fail 'portability matcher misses a hardcoded path'
fi
grep -qE "$hardcode_re" "$LAUNCH"; g=$?
case "$g" in
    1) pass 'script has no hardcoded user path' ;;
    0) fail 'script hardcodes a user path' ;;
    *) fail "portability grep errored (rc=$g)" ;;
esac

if [ "$fails" -eq 0 ]; then printf 'ALL PASS\n'; exit 0; fi
printf '%s FAILED\n' "$fails"
exit 1
