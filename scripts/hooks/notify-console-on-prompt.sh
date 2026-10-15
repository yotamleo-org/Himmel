#!/usr/bin/env bash
# notify-console-on-prompt.sh — Notification hook: tell the console when its
# leg stops on a permission prompt.
#
# WHY: a headed leg parked on the auto-mode dialog keeps a fresh lock heartbeat
# and reads as busy; the tick's parked= field catches it only on its next poll.
# This posts ONE line to the owning console's inbox within seconds, using the
# existing inbox-send.sh channel (parked-on-prompt.sh / tick parked= stay the
# poll-side detector; this is the push side).
#
# Fires only for a console-spawned leg (HIMMEL_CONSOLE_LEG=1 with
# HIMMEL_CONSOLE_NAME set) on a permission_prompt notification. Debounced per
# session (HIMMEL_PROMPT_ALERT_DEBOUNCE seconds, default 600). The line names
# the leg's worktree basename and session id prefix only — never the
# notification text, which can carry the denied command. The console must NOT
# answer the prompt for the leg (no cross-session approval); it only learns of it.
#
# An observability tap: never blocks, always exits 0, fails open.
# env: HIMMEL_PROMPT_ALERT_DIR (debounce state). The sender is always the
# inbox-send.sh beside this hook; tests run a copy of the hook next to a stub.
#
# PLATFORM GUARD: no .ps1 twin, by design — Linux-only console-kit leg surface.
# Bash 3.2-compatible.
set -uo pipefail
trap 'exit 0' EXIT

[ "${HIMMEL_CONSOLE_LEG:-}" = "1" ] && [ -n "${HIMMEL_CONSOLE_NAME:-}" ] || exit 0
command -v jq >/dev/null 2>&1 || exit 0
input=""
IFS= read -r -d '' input 2>/dev/null || true
[ -n "$input" ] || exit 0

ntype="$(printf '%s' "$input" | jq -r '.notification_type // ""' 2>/dev/null)" || exit 0
[ "$ntype" = "permission_prompt" ] || exit 0
sid="$(printf '%s' "$input" | jq -r '.session_id // ""' 2>/dev/null)" || exit 0
cwd="$(printf '%s' "$input" | jq -r '.cwd // ""' 2>/dev/null)" || exit 0
case "$sid" in ''|*[!0-9A-Za-z-]*) exit 0 ;; esac

debounce="${HIMMEL_PROMPT_ALERT_DEBOUNCE:-600}"
case "$debounce" in ''|*[!0-9]*) debounce=600 ;; esac
dir="${HIMMEL_PROMPT_ALERT_DIR:-$HOME/.himmel/state/prompt-alerts}"
umask 077
mkdir -p "$dir" 2>/dev/null || exit 0
stamp="$dir/$sid"
now="$(date +%s)"
if [ -f "$stamp" ]; then
    last="$(stat -c %Y "$stamp" 2>/dev/null || echo 0)"
    [ $((now - last)) -ge "$debounce" ] || exit 0
fi

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
sender="$here/../handover/console-kit/inbox-send.sh"
[ -r "$sender" ] || exit 0
leg="$(basename "${cwd:-unknown}")"
case "$leg" in ""|*[!0-9A-Za-z._+-]*) leg=unknown ;; esac
if timeout 8 bash "$sender" "$HIMMEL_CONSOLE_NAME" "PARKED-ON-PROMPT leg=$leg session=${sid%%-*} - stopped on a permission prompt; the operator answers it, the console never does" >/dev/null 2>&1; then
    : > "$stamp" 2>/dev/null
fi
exit 0
