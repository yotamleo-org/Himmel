#!/usr/bin/env bash
# billed-exempt: launcher into a test VM; the operator or console arming it is the billed act
# scripts/vm/launch-guest.sh - start ONE claude session on a himmel test VM.
#
# The sanctioned guest launch for the leg-vm profile: the profile's
# only extra allow rule names this script, so a leg never types ssh or a claude
# launch itself. The guest session runs on the guest's own claude login with an
# explicit --permission-mode acceptEdits and a fixed --allowedTools list, never a
# skip-permissions flag (docs/internals/enforcement.md, Claude invocation billing).
#
# Usage: launch-guest.sh [--dry-run] <vm> <prompt-file>
#   <vm>          a key of scripts/lib/vms.json that is an ubuntu guest with an
#                 ssh_port and a user, and not kind=station. Anything else exits 2
#                 before any connection.
#   <prompt-file> a host file sent to the guest claude on stdin; it must resolve
#                 under the cwd's git worktree or the session scratchpad and not
#                 have a secret-shaped name (.env*, *.pem, *.key, id_*, credentials*).
#   --dry-run     print the ssh command instead of running it.
# stdout: the guest session's --output-format json result. rc: the guest's, or 2
#   on a refused argument.
# Env: LAUNCH_GUEST_VMS_JSON (registry path; default scripts/lib/vms.json),
#      LAUNCH_GUEST_PREFLIGHT (bank preflight script; default scripts/lib/usage-preflight.sh),
#      LAUNCH_GUEST_TIMEOUT (seconds above 0, default 1800).
# Platform: POSIX bash 3.2+, node, ssh with key auth to the guest.
# launch-profile-ok-file: the claude runs on the guest's own login and config, where no host profile applies
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
VMS_JSON="${LAUNCH_GUEST_VMS_JSON:-$HERE/../lib/vms.json}"
# shellcheck disable=SC2088  # the guest shell, not this one, expands the tilde
GUEST_REPO='~/Documents/github/himmel'
ALLOWED_TOOLS='Read,Grep,Glob,Edit,Write,Bash(git:*),Bash(bash scripts/*:*)'
DRY=0
[ "${1:-}" = "--dry-run" ] && { DRY=1; shift; }
if [ "$#" -ne 2 ]; then
    echo "usage: launch-guest.sh [--dry-run] <vm> <prompt-file>" >&2
    exit 2
fi
VM="$1"; PROMPT="$2"
TIMEOUT="${LAUNCH_GUEST_TIMEOUT:-1800}"
case "$VM" in ''|*[!A-Za-z0-9_-]*) echo "launch-guest: '$VM' is not a registered test VM name" >&2; exit 2 ;; esac
case "$TIMEOUT" in ''|*[!0-9]*|0*) echo "launch-guest: LAUNCH_GUEST_TIMEOUT must be whole seconds above 0, no leading zero" >&2; exit 2 ;; esac
[ -f "$PROMPT" ] || { echo "launch-guest: prompt file '$PROMPT' not found" >&2; exit 2; }
# the prompt is read on the host and its answer comes back, so it is confined to
# the cwd's git worktree or the session scratchpad, after resolving symlinks and
# dotdot, and a secret-shaped name is refused anywhere.
TOP="$(git rev-parse --show-toplevel 2>/dev/null || true)"
# shellcheck disable=SC2016  # the dollar signs are javascript regex syntax
if ! RESOLVED="$(node -e '
const fs = require("fs"), path = require("path");
const [p, top, tmp] = process.argv.slice(1);
const real = (x) => { try { return fs.realpathSync(x); } catch { return ""; } };
const r = real(p), t = real(top), s = real(tmp);
const secret = /^\.env|\.pem$|\.key$|^id_|^credentials/i;
if (!r || secret.test(path.basename(p)) || secret.test(path.basename(r))) process.exit(1);
const scratch = s && new RegExp("^" + s.replace(/[.*+?^${}()|[\]\\]/g, "\\$&") + "/claude-" + process.getuid() + "/[^/]+/[^/]+/scratchpad/");
if ((t && r.startsWith(t + path.sep)) || (scratch && scratch.test(r))) console.log(r); else process.exit(1);
' "$PROMPT" "$TOP" "${TMPDIR:-/tmp}" 2>/dev/null)" || [ -z "$RESOLVED" ]; then
    echo "launch-guest: prompt file '$PROMPT' must live under the worktree or the session scratchpad and not be a secret-shaped file" >&2
    exit 2
fi
PROMPT="$RESOLVED"
# port and user come from the registry; a VM that is not an ubuntu guest, is a
# station, or lacks either field prints nothing and is refused.
if ! ROW="$(node -e '
const [file, vm] = process.argv.slice(1);
const e = JSON.parse(require("fs").readFileSync(file, "utf8"))[vm];
if (e && e.os === "ubuntu" && e.kind !== "station" && Number.isInteger(e.ssh_port) && /^[a-z_][a-z0-9_-]*$/.test(e.user ?? "")) console.log(e.ssh_port + " " + e.user);
' "$VMS_JSON" "$VM" 2>/dev/null)" || [ -z "$ROW" ]; then
    echo "launch-guest: '$VM' is not a registered test VM (an ubuntu guest in $VMS_JSON with ssh_port and user, not a station)" >&2
    exit 2
fi
PORT="${ROW%% *}"; GUSER="${ROW#* }"
INNER="cd $GUEST_REPO && timeout --signal=KILL $TIMEOUT claude -p --permission-mode acceptEdits --allowedTools '$ALLOWED_TOOLS' --output-format json"
CMD=(ssh -p "$PORT" -o BatchMode=yes -o ConnectTimeout=15 "$GUSER@127.0.0.1" "bash -lc \"$INNER\"")
if [ "$DRY" -eq 1 ]; then
    echo "ssh -p $PORT -o BatchMode=yes -o ConnectTimeout=15 $GUSER@127.0.0.1 bash -lc \"$INNER\" < $PROMPT"
    exit 0
fi
# an unattended claude session draws the same subscription budget as any other:
# preflight the bank and refuse on an exhausted verdict (unknown/stale fail open).
PREFLIGHT="${LAUNCH_GUEST_PREFLIGHT:-$HERE/../lib/usage-preflight.sh}"
VERDICT="$(bash "$PREFLIGHT" 2>/dev/null | tail -n 1)"
case "$VERDICT" in
    SKIPPED-*) echo "launch-guest: bank preflight said $VERDICT - not launching a guest session" >&2; exit 2 ;;
esac
exec "${CMD[@]}" < "$PROMPT"
