#!/usr/bin/env bash
# launch-cloud.sh — The console's cloud launch: one `claude --cloud`
# session in its own konsole window. `claude --cloud` creates the session,
# prints its URL and exits; script(1) keeps a TTY and captures that output.
#
# Usage: bash scripts/handover/chief-kit/launch-cloud.sh <ticket-number>
#   e.g. 4757 -> reads <bucket>/cloud-brief-HIMMEL-4757.md, appends one
#   tab-separated row to <bucket>/cloud-sessions.tsv.
#
# <bucket> is <handover_root>/<user_slug>/<repo-dir-name>; HIMMEL_BUCKET_DIR
# overrides it (test seam). HIMMEL_CONSOLE_RUNDIR overrides the run dir
# (default: the per-uid himmel-console dir console.sh uses).
# CLOUD_LAUNCH_POLLS / CLOUD_LAUNCH_SLEEP bound the wait for the session line
# (default 20 x 3s).
#
# Exit: 0 launched and recorded; 1 no session line appeared; 2 usage, missing
# brief or unresolvable bucket. bash 3.2-safe.
set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"

if [ "$#" -ne 1 ] || [ -z "$1" ]; then
    echo "usage: launch-cloud.sh <ticket-number>" >&2
    exit 2
fi
t="$1"
case "$t" in
    *[!0-9A-Za-z_-]*) echo "launch-cloud: ticket must be alphanumeric, got '$t'" >&2; exit 2 ;;
esac

bucket="${HIMMEL_BUCKET_DIR:-}"
if [ -z "$bucket" ]; then
    # shellcheck source=../../lib/load-dotenv.sh
    # shellcheck disable=SC1091
    . "$HERE/../../lib/load-dotenv.sh"
    # shellcheck source=../../lib/user-slug.sh
    # shellcheck disable=SC1091
    . "$HERE/../../lib/user-slug.sh"
    # shellcheck source=../../lib/handover-path.sh
    # shellcheck disable=SC1091
    . "$HERE/../../lib/handover-path.sh"
    load_dotenv --root "$(_load_dotenv_primary_for "$HERE/../../..")" HANDOVER_DIR USER_SLUG
    root="$(handover_root)" || { echo "launch-cloud: set HANDOVER_DIR or run /handover-setup" >&2; exit 2; }
    slug="$(cd "$HERE/../../.." && user_slug)" || { echo "launch-cloud: cannot resolve USER_SLUG" >&2; exit 2; }
    # shellcheck source=../../lib/git-clean.sh
    # shellcheck disable=SC1091
    . "$HERE/../../lib/git-clean.sh"
    common="$(cd "$HERE/../../.." && git_env_scrub && git rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" \
        || { echo "launch-cloud: cannot resolve the primary checkout" >&2; exit 2; }
    repo="$(basename "$(dirname "$common")")"
    bucket="$root/$slug/$repo"
fi

brief="$bucket/cloud-brief-HIMMEL-$t.md"
[ -r "$brief" ] || { echo "launch-cloud: no brief $brief" >&2; exit 2; }

rundir="${HIMMEL_CONSOLE_RUNDIR:-}"
if [ -z "$rundir" ]; then
    if [ -n "${XDG_RUNTIME_DIR:-}" ] && [ -d "$XDG_RUNTIME_DIR" ] && [ -O "$XDG_RUNTIME_DIR" ]; then
        rundir="$XDG_RUNTIME_DIR/himmel-console"
    else
        rundir="${TMPDIR:-/tmp}/himmel-console-$(id -u)"
    fi
fi
# shellcheck disable=SC2174 # only the final directory is ours.
mkdir -m 700 -p "$rundir"
if [ -L "$rundir" ] || [ ! -O "$rundir" ]; then
    echo "launch-cloud: run dir $rundir is not a directory we own" >&2
    exit 2
fi
# mkdir -m leaves an existing dir's mode alone; make sure no one else can write.
chmod 700 "$rundir"

# per-invocation files: two launches of one ticket must not share a log.
log="$rundir/cloud-$t.$$.log"
inner="$rundir/cloud-$t.$$.run.sh"
: > "$log"
# shellcheck disable=SC2016 # the $(cat ...) expands in the inner script, not here.
printf '#!/usr/bin/env bash\nexec claude --cloud "$(cat %q)" --permission-mode auto\n' "$brief" > "$inner"
chmod +x "$inner"

setsid nohup konsole --separate -p tabtitle="cloud-HIMMEL-$t" -e script -q -c "$(printf '%q' "$inner")" "$log" > /dev/null 2>&1 &  # t13b-ok: one-shot konsole window, exits when claude --cloud returns; not a service

polls="${CLOUD_LAUNCH_POLLS:-20}"
nap="${CLOUD_LAUNCH_SLEEP:-3}"
i=0
while [ "$i" -lt "$polls" ]; do
    grep -aq 'Created cloud session' "$log" 2>/dev/null && break
    sleep "$nap"
    i=$((i + 1))
done

out=$(grep -a -E 'Created cloud session|View:|teleport|rror' "$log" 2>/dev/null | tr -d '\r' | sed 's/^.*Created cloud/Created cloud/') || true
[ -n "$out" ] || { echo "launch-cloud: no output yet in $log"; exit 1; }
echo "$out"

# Durable record for teleport/shepherding: one line per session in the bucket.
sid=$(printf '%s\n' "$out" | grep -o 'session_[A-Za-z0-9]*' | head -n 1) || true
[ -n "$sid" ] || { echo "launch-cloud: no session id in the output; nothing recorded" >&2; exit 1; }
printf '%s\tHIMMEL-%s\t%s\tclaude --teleport %s\n' "$(date +%FT%T)" "$t" "$sid" "$sid" >> "$bucket/cloud-sessions.tsv"
