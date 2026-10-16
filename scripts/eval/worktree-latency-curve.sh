#!/usr/bin/env bash
# worktree-latency-curve.sh: measure git latency against live worktree count.
#
# Builds a throwaway repo under mktemp, grows it to each --steps count of linked
# worktrees, and at each step times (monotonic clock, median of 3 samples, ms):
#   list    git worktree list
#   status  git status in the main worktree
#   add     git worktree add of one more worktree
#   remove  git worktree remove of that worktree
# One TSV row per step on stdout, a '#' header first. Never touches the calling
# repo or the real HOME; the scratch tree is removed on exit.
#
# Usage: worktree-latency-curve.sh [--steps 10,25,50,100,200] [--max 200]
#                                  [--timeout 300] [--samples 3]
# Exit: 0 ok; 2 bad usage (including a step above --max); 124 timeout.
#
# Bash 3.2-safe; needs python3 for the clock.

set -euo pipefail

STEPS="10,25,50,100,200"
MAX=200
TIMEOUT=300
SAMPLES=3

usage() { sed -n '2,17p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }
die() { printf 'worktree-latency-curve: %s\n' "$1" >&2; exit 2; }

while [ $# -gt 0 ]; do
    case "$1" in
        --steps)   [ $# -ge 2 ] || die "--steps needs a value"; STEPS="$2"; shift 2 ;;
        --max)     [ $# -ge 2 ] || die "--max needs a value"; MAX="$2"; shift 2 ;;
        --timeout) [ $# -ge 2 ] || die "--timeout needs a value"; TIMEOUT="$2"; shift 2 ;;
        --samples) [ $# -ge 2 ] || die "--samples needs a value"; SAMPLES="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) die "unknown argument: $1" ;;
    esac
done

is_pos_int() { case "$1" in ''|*[!0-9]*|0*) return 1 ;; *) return 0 ;; esac; }

is_pos_int "$MAX" || die "--max must be a positive integer: $MAX"
is_pos_int "$TIMEOUT" || die "--timeout must be a positive integer: $TIMEOUT"
is_pos_int "$SAMPLES" || die "--samples must be a positive integer: $SAMPLES"
[ $(( SAMPLES % 2 )) -eq 1 ] || die "--samples must be odd so the median is one sample: $SAMPLES"
case "$STEPS" in
    ''|,*|*,|*,,*|*[!0-9,]*) die "--steps must be comma-separated positive integers: '$STEPS'" ;;
esac
prev=0
for s in $(printf '%s' "$STEPS" | tr ',' ' '); do
    is_pos_int "$s" || die "step must be a positive integer: $s"
    [ "$s" -gt "$prev" ] || die "steps must be strictly ascending: $STEPS"
    [ "$s" -le "$MAX" ] || die "step $s exceeds --max $MAX"
    prev="$s"
done
command -v python3 >/dev/null 2>&1 || die "python3 is required for the clock"

# Re-run under a hard wall-clock bound; the marker stops the recursion.
if [ -z "${WLC_BOUNDED:-}" ]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    # shellcheck source=../lib/timeout-bin.sh
    . "$SCRIPT_DIR/../lib/timeout-bin.sh"
    [ -n "$_TIMEOUT_BIN" ] || die "no timeout binary: refusing to run unbounded"
    export WLC_BOUNDED=1
    exec "$_TIMEOUT_BIN" -k 5 "$TIMEOUT" bash "${BASH_SOURCE[0]}" \
        --steps "$STEPS" --max "$MAX" --timeout "$TIMEOUT" --samples "$SAMPLES"
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/wlc.XXXXXX")" || exit 1
trap 'rm -rf "$WORK"' EXIT
trap 'exit 143' INT TERM

export HOME="$WORK/home"
mkdir -p "$HOME"
export XDG_CONFIG_HOME="$HOME/.config"
export GIT_CONFIG_NOSYSTEM=1
unset GIT_CONFIG_GLOBAL GIT_CONFIG_SYSTEM GIT_CONFIG_COUNT GIT_CONFIG_PARAMETERS
unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE \
    GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES

REPO="$WORK/repo"
git init -q "$REPO"
git -C "$REPO" config user.email "wlc@test.local"
git -C "$REPO" config user.name "wlc"
i=0
while [ "$i" -lt 20 ]; do
    printf 'file %s\n' "$i" > "$REPO/f$i.txt"
    i=$(( i + 1 ))
done
git -C "$REPO" add -A
git -C "$REPO" commit -q -m init

# median_ms <cmd...>: run it SAMPLES times, print the median wall time in ms.
# The timer runs inside python3 around the child only, so interpreter startup
# is not measured.
median_ms() {
    python3 -I - "$SAMPLES" "$@" <<'PY'
import subprocess, sys, time
n = int(sys.argv[1]); cmd = sys.argv[2:]
t = []
for _ in range(n):
    a = time.perf_counter()
    subprocess.run(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=True)
    t.append((time.perf_counter() - a) * 1000.0)
t.sort()
print("%.2f" % t[len(t) // 2])
PY
}

# add_remove_ms: time SAMPLES add/remove pairs of one extra worktree, print
# "<add median> <remove median>".
add_remove_ms() {
    python3 -I - "$SAMPLES" "$REPO" "$WORK/extra" <<'PY'
import subprocess, sys, time
n = int(sys.argv[1]); repo = sys.argv[2]; path = sys.argv[3]
def run(*a):
    a0 = time.perf_counter()
    subprocess.run(["git", "-C", repo] + list(a), stdout=subprocess.DEVNULL,
                   stderr=subprocess.DEVNULL, check=True)
    return (time.perf_counter() - a0) * 1000.0
adds, rems = [], []
for _ in range(n):
    adds.append(run("worktree", "add", "--detach", path))
    rems.append(run("worktree", "remove", "--force", path))
adds.sort(); rems.sort()
print("%.2f %.2f" % (adds[len(adds) // 2], rems[len(rems) // 2]))
PY
}

printf '# steps=%s max=%s samples=%s median ms\n' "$STEPS" "$MAX" "$SAMPLES"
printf '# worktrees\tlist\tstatus\tadd\tremove\n'

count=0
for s in $(printf '%s' "$STEPS" | tr ',' ' '); do
    while [ "$count" -lt "$s" ]; do
        git -C "$REPO" worktree add -q --detach "$WORK/wt/$count" >/dev/null 2>&1
        count=$(( count + 1 ))
    done
    l="$(median_ms git -C "$REPO" worktree list)"
    st="$(median_ms git -C "$REPO" status)"
    ar="$(add_remove_ms)"
    printf '%s\t%s\t%s\t%s\t%s\n' "$s" "$l" "$st" "${ar% *}" "${ar#* }"
done
