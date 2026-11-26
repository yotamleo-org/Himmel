#!/usr/bin/env bash
# stop-chief-ask-mirror.sh — Stop hook.
#
# WHY: scripts/handover/chief-kit/ask-mirror.sh posts each `Needs you:` block of
# a finished chief reply to the operator's Telegram, but a post waits for a send
# receipt, far longer than a Stop hook may block. This hook is the thin caller:
# when the reply holds `Needs you:` it hands the payload to ask-mirror.sh through
# the bounded stop queue and returns at once. The chief gate, the parse and the
# dedupe stay in ask-mirror.sh.
#
# The queue key carries a digest of the reply: the queue keys a waiting entry by
# (name, session) and a newer enqueue replaces it, so a plain key would drop a
# first ask when a second ask-bearing reply is queued behind it.
#
# The payload carries reply text, so the queue entry (0600, under HOME) holds it
# until the job runs; stop-queue.mjs names this caller as that exception.
#
# FAIL-OPEN: a workflow nudge. No jq or node, an unparseable payload, no reply or
# no marker all exit 0. It prints nothing and always exits 0.
# bash 3.2-safe.
set -u

HOOKS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HOOKS/../.." && pwd)"

command -v jq >/dev/null 2>&1 || exit 0
command -v node >/dev/null 2>&1 || exit 0

payload=""
IFS= read -r -t 5 -d '' payload
[ -n "$payload" ] || exit 0

reply="$(printf '%s' "$payload" | jq -r '.last_assistant_message // empty' 2>/dev/null)" || exit 0  # swallow-ok: junk payload holds no ask
[ -n "$reply" ] || exit 0
case "$reply" in *"Needs you:"*) ;; *) exit 0 ;; esac

if command -v sha256sum >/dev/null 2>&1; then digest="$(printf '%s' "$reply" | sha256sum | cut -c1-16)"
elif command -v shasum >/dev/null 2>&1; then digest="$(printf '%s' "$reply" | shasum -a 256 | cut -c1-16)"
else exit 0; fi
[ -n "$digest" ] || exit 0

printf '%s' "$payload" | HIMMEL_STOP_QUEUE_ENV_EXTRA="${HIMMEL_STOP_QUEUE_ENV_EXTRA:+$HIMMEL_STOP_QUEUE_ENV_EXTRA,}HANDOVER_DIR,BRIDGE_ROOT,TELEGRAM_ACCESS_PATH" \
    node "$HOOKS/stop-queue.mjs" enqueue --key "chief-ask-mirror-$digest" -- bash "$REPO/scripts/handover/chief-kit/ask-mirror.sh" >/dev/null 2>&1  # swallow-ok: the queue falls back on its own, a nudge never blocks
exit 0
