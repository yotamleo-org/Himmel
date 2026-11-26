#!/usr/bin/env bash
# stop-chief-ask-mirror.sh — Stop hook: queues ask-mirror.sh for a reply holding `Needs you:`.
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

if command -v sha256sum >/dev/null 2>&1; then reply_digest="$(printf '%s' "$reply" | sha256sum | cut -c1-16)"
elif command -v shasum >/dev/null 2>&1; then reply_digest="$(printf '%s' "$reply" | shasum -a 256 | cut -c1-16)"
else exit 0; fi
[ -n "$reply_digest" ] || exit 0

printf '%s' "$payload" | HIMMEL_STOP_QUEUE_ENV_EXTRA="${HIMMEL_STOP_QUEUE_ENV_EXTRA:+$HIMMEL_STOP_QUEUE_ENV_EXTRA,}HANDOVER_DIR,BRIDGE_ROOT,TELEGRAM_ACCESS_PATH" \
    node "$HOOKS/stop-queue.mjs" enqueue --key "chief-ask-mirror-$reply_digest" -- bash "$REPO/scripts/handover/chief-kit/ask-mirror.sh" >/dev/null 2>&1  # swallow-ok: the queue falls back on its own, a nudge never blocks
exit 0
