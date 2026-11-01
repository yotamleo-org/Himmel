#!/usr/bin/env bash
# shellcheck disable=SC2015,SC2016 # compact status assertions; the backticks in the message are literal
# Suite for scripts/hooks/afk-prompt-to-request.sh: a Bash permission prompt is
# denied with the exact `afk-run --blocked-by prompt` line only while the root helper's `mode`
# answers enabled=true and run_enabled=true; every other case passes through (no output).
# A fake `sudo` on PATH stands in for the root helper; a stub gate-shapes hook sits beside the
# copy under test.
# env: HOOK overrides the hook under test (RED run against a tree without it).
#
# bash 3.2-safe.
set -uo pipefail
unset AFK_PROMPT_TO_REQUEST_OFF

HERE="$(cd "$(dirname "$0")" && pwd)"
HOOK="${HOOK:-$HERE/afk-prompt-to-request.sh}"
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not on PATH"; exit 0; }

pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }

T="$(mktemp -d "${TMPDIR:-/tmp}/afk-prompt.XXXXXX")" || exit 1
T="$(cd "$T" && pwd -P)" || exit 1
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/repo/scripts/hooks" "$T/repo/scripts/lib" "$T/bin" || exit 1
cp "$HOOK" "$T/repo/scripts/hooks/afk-prompt-to-request.sh" 2>/dev/null
cp "$HERE/../lib/git-clean.sh" "$T/repo/scripts/lib/git-clean.sh" || exit 1
H="$T/repo/scripts/hooks/afk-prompt-to-request.sh"
RUN="$T/repo/scripts/lib/afk-run"
# The stub gate-shapes hook allows one shape only.
cat > "$T/repo/scripts/hooks/permission-allow-gate-shapes.sh" <<'EOF'
#!/usr/bin/env bash
case "$(cat)" in *'"command":"bash scripts/cr/review-round.sh"'*)
    printf '%s\n' '{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}' ;;
esac
EOF
# Fake sudo: answers `mode` from $T/mode; refuses when it is absent (helper not installed).
cat > "$T/bin/sudo" <<EOF
#!/usr/bin/env bash
[ "\$1 \$2 \$3" = "-n /usr/local/libexec/himmel/afk-sudo mode" ] || exit 1
[ -r "$T/mode" ] || { echo "sudo: a password is required" >&2; exit 1; }
cat "$T/mode"
EOF
chmod +x "$T/bin/sudo"
# A systemctl on PATH on every runner, so the plain-argv row does not depend on the host.
printf '#!/bin/sh\nexit 0\n' > "$T/bin/systemctl"
chmod +x "$T/bin/systemctl"
git init -q -b feat/himmel-8067-x "$T/wt" || exit 1
mkdir -p "$T/nobranch"
ON='result=mode mode=afk enabled=true run_enabled=true'
setmode() { if [ -n "$1" ]; then printf '%s\n' "$1" > "$T/mode"; else rm -f "$T/mode"; fi; }

# run <tool> <command> [cwd] -> hook stdout
run() {
    jq -cn --arg tool "$1" --arg cmd "$2" --arg cwd "${3:-$T/wt}" \
        '{hook_event_name:"PermissionRequest",session_id:"S-1",cwd:$cwd,tool_name:$tool,tool_input:{command:$cmd}}' \
        | PATH="$T/bin:$PATH" bash "$H" 2>/dev/null
}
msg() { printf '%s' "$1" | jq -r '.hookSpecificOutput.decision.message // empty' 2>/dev/null; }
beh() { printf '%s' "$1" | jq -r '.hookSpecificOutput.decision.behavior // empty' 2>/dev/null; }
# denies_with <label> <expected afk-run line> <tool> <command> [cwd]
denies_with() {
    local label="$1" want="$2" out
    shift 2
    out="$(run "$@")"
    if [ "$(beh "$out")" = deny ] && [ "$(msg "$out" | sed -n 1p)" = "operator is AFK: file \`$want\`" ]; then
        ok "$label"
    else
        bad "$label (got: $out)"
    fi
}
# passes <label> <tool> <command>
passes() {
    local label="$1" out
    shift
    out="$(run "$@")"
    if [ -z "$out" ]; then ok "$label"; else bad "$label (got: $out)"; fi
}

echo "== run kind on: a Bash prompt is denied with the exact afk-run line =="
setmode "$ON"
denies_with "a plain command is named as its own argv" \
    "$RUN --session S-1 --ticket HIMMEL-8067 --blocked-by prompt --cwd $T/wt -- systemctl restart nginx" \
    Bash "systemctl restart nginx"
denies_with "a command with shell syntax runs as bash -c, quoted" \
    "$RUN --session S-1 --ticket HIMMEL-8067 --blocked-by prompt --cwd $T/wt -- bash -c $(printf '%q' 'ls /root | head -1')" \
    Bash "ls /root | head -1"
denies_with "no ticket in the branch names ticket none" \
    "$RUN --session S-1 --ticket none --blocked-by prompt --cwd $T/nobranch -- id" \
    Bash "id" "$T/nobranch"
denies_with "a leading assignment runs as bash -c" \
    "$RUN --session S-1 --ticket HIMMEL-8067 --blocked-by prompt --cwd $T/wt -- bash -c $(printf '%q' 'FOO=bar env')" \
    Bash "FOO=bar env"
denies_with "a shell builtin runs as bash -c" \
    "$RUN --session S-1 --ticket HIMMEL-8067 --blocked-by prompt --cwd $T/wt -- bash -c $(printf '%q' 'cd /work')" \
    Bash "cd /work"
out="$(run Bash "id")"
case "$(msg "$out")" in *AFK_PROMPT_TO_REQUEST_OFF=1*) ok "the deny names its bypass" ;; *) bad "the deny names its bypass (got: $out)" ;; esac
line="$(msg "$(run Bash "ls /root | head -1")" | sed -n 1p | sed 's/^operator is AFK: file `//; s/`$//')"
argv="$(eval "set -- $line; shift 10; printf '%s|' \"\$@\"")"
[ "$argv" = "bash|-c|ls /root | head -1|" ] && ok "the quoted line parses back to the exact command" || bad "the quoted line parses back to the exact command (got: $argv)"

echo "== everything else passes through =="
passes "a command the gate-shapes hook allows is left to it" Bash "bash scripts/cr/review-round.sh"
passes "a non-Bash tool" Edit "x"
setmode 'result=mode mode=afk enabled=true run_enabled=false'
passes "run kind off" Bash "id"
setmode 'result=mode mode=present enabled=false run_enabled=true'
passes "station off" Bash "id"
setmode ''
passes "helper absent or sudo refused" Bash "id"
setmode "$ON"
out="$(jq -cn '{tool_name:"Bash",session_id:"S-1",tool_input:{command:"id"}}' | AFK_PROMPT_TO_REQUEST_OFF=1 PATH="$T/bin:$PATH" bash "$H" 2>/dev/null)"
[ -z "$out" ] && ok "the bypass lets the dialog open" || bad "the bypass lets the dialog open (got: $out)"
out="$(printf 'not json' | PATH="$T/bin:$PATH" bash "$H" 2>/dev/null; echo "rc=$?")"
[ "$out" = "rc=0" ] && ok "unparseable input fails open" || bad "unparseable input fails open (got: $out)"

echo
echo "afk-prompt-to-request: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
