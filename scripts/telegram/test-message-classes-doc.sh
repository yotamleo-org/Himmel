#!/usr/bin/env bash
# The docs side of the Telegram message classes: every chief reply command a chief copies from the docs
# passes --kind chief-reply among its leading flags (the router reads flags only before the chat id), and
# docs/configuration.md documents the two monitoring env keys the poller reads from the bridge env file.
# The doc table's kinds and classes are checked by test-message-classes.sh, not here.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
T="$(mktemp -d "${TMPDIR:-/tmp}/message-classes-doc.XXXXXX")" || exit 1
trap 'rm -rf "$T"' EXIT
DOCS="docs/handover/running-a-chief.md docs/handover/chief-sections/voice-lines.md docs/telegram-bridge.md docs/handover/chief-template.md"
CONFIG="$REPO/docs/configuration.md"
PASS=0; FAILN=0

pass() { PASS=$((PASS + 1)); echo "ok - $1"; }
fail() { FAILN=$((FAILN + 1)); echo "not ok - $1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/    /'; return 0; }

cat > "$T/lint.py" <<'PY'
import re, sys

SPAN = re.compile(r'`([^`]*chief-route\.ts"?\s+reply\s[^`]*)`')
FLAGS = {"--chief", "--satellite", "--kind", "--owed", "--doc"}
errs = []
for path in sys.argv[1:]:
    text = open(path, encoding="utf-8").read()
    spans = SPAN.findall(text)
    if not spans:
        errs.append("%s: no chief-route.ts reply command found" % path)
    for span in spans:
        words = re.split(r'chief-route\.ts"?\s+reply\s+', span, maxsplit=1)[1].split()
        kind = None
        while len(words) >= 2 and words[0] in FLAGS:
            if words[0] == "--kind":
                kind = words[1]
            words = words[2:]
        if kind != "chief-reply":
            errs.append("%s: %s" % (path, span))
print("\n".join(errs))
sys.exit(1 if errs else 0)
PY

lint() { python3 -I "$T/lint.py" "$@"; }

real=()
for d in $DOCS; do real+=("$REPO/$d"); done

if out="$(lint "${real[@]}")"; then
    pass "every chief-route.ts reply command in the four chief docs passes --kind chief-reply before the chat id"
else
    fail "every chief-route.ts reply command in the four chief docs passes --kind chief-reply before the chat id" "$out"
fi

mkdir -p "$T/copy"
for d in $DOCS; do cp "$REPO/$d" "$T/copy/$(basename "$d")"; done
sed '0,/ --kind chief-reply /s// /' "$REPO/docs/handover/chief-sections/voice-lines.md" > "$T/copy/voice-lines.md"
out="$(lint "$T/copy/"*.md)"; rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q 'voice-lines.md: .*voice asked'; then
    pass "a doc copy with one reply command's --kind chief-reply stripped fails the lint naming that command"
else
    fail "a doc copy with one reply command's --kind chief-reply stripped fails the lint naming that command" "rc=$rc out=$out"
fi

# shellcheck disable=SC2016  # literal doc text: the backticks must NOT expand
printf 'reply with `bun scripts/telegram/chief-route.ts reply <chat_id> --kind chief-reply "<text>"`\n' > "$T/late-kind.md"
if ! lint "$T/late-kind.md" > /dev/null; then
    pass "a --kind after the chat id fails the lint (the router reads flags only before it)"
else
    fail "a --kind after the chat id fails the lint (the router reads flags only before it)"
fi

for key in TELEGRAM_MONITOR_BOT_TOKEN TELEGRAM_MONITOR_CHAT_ID; do
    if grep -q "^| \`$key\` | .*bridge" "$CONFIG"; then
        pass "docs/configuration.md has a $key row naming the bridge env file"
    else
        fail "docs/configuration.md has a $key row naming the bridge env file"
    fi
done

echo "1..$((PASS + FAILN)) pass=$PASS fail=$FAILN"
[ "$FAILN" -eq 0 ]
