#!/usr/bin/env bash
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

SPAN = re.compile(r'`((?:[^`]*chief-route\.ts"?\s+)?reply\s+--[^`]*|[^`]*chief-route\.ts"?\s+reply\s[^`]*)`')
FLAGS = {"--chief", "--satellite", "--kind", "--owed", "--doc"}
errs = []
for path in sys.argv[1:]:
    text = open(path, encoding="utf-8").read()
    spans = SPAN.findall(text)
    if not spans:
        errs.append("%s: no chief-route.ts reply command found" % path)
    for span in spans:
        words = re.split(r'(?:chief-route\.ts"?\s+|^)reply\s+', span, maxsplit=1)[1].split()
        kind = None
        while len(words) >= 2 and words[0] in FLAGS:
            if words[0] == "--kind":
                kind = words[1]
            words = words[2:]
        if kind not in ("chief-reply", "chief-status"):
            errs.append("%s: %s" % (path, span))
print("\n".join(errs))
sys.exit(1 if errs else 0)
PY

lint() { python3 -I "$T/lint.py" "$@"; }

real=()
for d in $DOCS; do real+=("$REPO/$d"); done

if out="$(lint "${real[@]}")"; then
    pass "every chief-route.ts reply command and bare reply --flag form in the four chief docs passes a chief kind before the chat id"
else
    fail "every chief-route.ts reply command and bare reply --flag form in the four chief docs passes a chief kind before the chat id" "$out"
fi

sites=0
for d in $DOCS; do
    while IFS=: read -r n _; do
        sites=$((sites + 1))
        mkdir -p "$T/copy"
        for c in $DOCS; do cp "$REPO/$c" "$T/copy/$(basename "$c")"; done
        sed "${n}s/ --kind chief-reply / /" "$REPO/$d" > "$T/copy/$(basename "$d")"
        out="$(lint "$T/copy/"*.md)"; rc=$?
        if [ "$rc" -ne 0 ] && grep -q "$(basename "$d"): " <<< "$out"; then
            pass "removing the --kind chief-reply at $d:$n fails the lint naming that doc"
        else
            fail "removing the --kind chief-reply at $d:$n fails the lint naming that doc" "rc=$rc out=$out"
        fi
    done < <(grep -n -- ' --kind chief-reply ' "$REPO/$d")
done
if [ "$sites" -eq 6 ]; then
    pass "the four chief docs carry six --kind chief-reply commands, each removed once above"
else
    fail "the four chief docs carry six --kind chief-reply commands, each removed once above" "found $sites"
fi

# shellcheck disable=SC2016
printf 'reply with `bun scripts/telegram/chief-route.ts reply <chat_id> --kind chief-reply "<text>"`\n' > "$T/late-kind.md"
if ! lint "$T/late-kind.md" > /dev/null; then
    pass "a --kind after the chat id fails the lint (the router reads flags only before it)"
else
    fail "a --kind after the chat id fails the lint (the router reads flags only before it)"
fi

# shellcheck disable=SC2016
printf 'send a status with `bun scripts/telegram/chief-route.ts reply --kind chief-status operator "<text>"`\n' > "$T/status-kind.md"
if out="$(lint "$T/status-kind.md")"; then
    pass "K15: a reply span with --kind chief-status passes the lint"
else
    fail "K15: a reply span with --kind chief-status passes the lint" "$out"
fi
# shellcheck disable=SC2016
printf 'send with `bun scripts/telegram/chief-route.ts reply --kind chief-stat operator "<text>"`\n' > "$T/unknown-kind.md"
if ! lint "$T/unknown-kind.md" > /dev/null; then
    pass "K15: a reply span with an unknown kind fails the lint"
else
    fail "K15: a reply span with an unknown kind fails the lint"
fi
if grep -q -- 'chief-route.ts reply --kind chief-status ' "$REPO/docs/handover/running-a-chief.md"; then
    pass "K15: running-a-chief.md names the --kind chief-status reply command"
else
    fail "K15: running-a-chief.md names the --kind chief-status reply command"
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
