#!/usr/bin/env bash
# Suite: every slash command the vault template's manual names is provided by a
# himmel plugin. An agent in an adopter vault follows the manual literally, so a
# command no plugin provides sends it to a dead end.
#
# "The manual" = templates/luna-second-brain/_CLAUDE.md, AGENTS.md and the
# reference files under its docs/. "Provided" = a plugin under marketplace/plugins/
# or plugins/ ships commands/<name>.md or skills/<name>/SKILL.md.
#
# A command is a "/name" after a line start, a space, a backtick or "(", and not
# followed by "/" or ".", so paths (docs/luna, ~/.local, /usr/bin/env) never match.
#
# Cases: 1. the manual names no unprovided command; 2. control: /contra is named
# and provided; 3. a fixture proves the check flags a dead command and only it,
# also beside a live one on the same line; 4. a missing manual file is reported.
#
# Platform guard (posix-bash): pure POSIX bash 3.2+ plus awk/grep/sed/mktemp.
#
# Usage: bash scripts/docs/test-vault-manual-commands.sh
# Exit:  0 = every case passed, 1 = at least one failed (all are reported).
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TPL="$ROOT/templates/luna-second-brain"

pass=0
fail=0
ok() { echo "ok: $*"; pass=$((pass + 1)); }
bad() { echo "FAIL: $*" >&2; fail=$((fail + 1)); }

named_commands() {
    awk '{
        s = " " $0
        while (match(s, /[ \t`(]\/[a-z]([a-z0-9-]*[a-z0-9])?/)) {
            name = substr(s, RSTART + 1, RLENGTH - 1)
            s = substr(s, RSTART + RLENGTH)
            if (s !~ /^[a-zA-Z0-9\/._-]/) print NR ":" name
        }
    }' "$1"
}

provided() {
    local f
    for f in "$ROOT"/marketplace/plugins/*/commands/"$1".md \
             "$ROOT"/marketplace/plugins/*/skills/"$1"/SKILL.md \
             "$ROOT"/plugins/*/commands/"$1".md \
             "$ROOT"/plugins/*/skills/"$1"/SKILL.md; do
        [ -f "$f" ] && return 0
    done
    return 1
}

dead_commands() {
    local f hit
    for f in "$@"; do
        [ -r "$f" ] || { echo "${f#"$ROOT"/}: missing or unreadable"; continue; }
        while IFS= read -r hit; do
            [ -n "$hit" ] || continue
            provided "${hit#*:/}" || echo "${f#"$ROOT"/}:${hit%%:*}: ${hit#*:}"
        done <<EOF
$(named_commands "$f")
EOF
    done
}

shopt -s nullglob
dead="$(dead_commands "$TPL/_CLAUDE.md" "$TPL/AGENTS.md" "$TPL"/docs/*.md "$TPL"/docs/*/*.md)"
if [ -z "$dead" ]; then
    ok "the vault manual names only commands a plugin provides"
else
    bad "the vault manual names commands no plugin provides:"
    printf '%s\n' "$dead" | sed 's/^/  /' >&2
fi

if named_commands "$TPL/_CLAUDE.md" | grep -q ':/contra$' && provided contra; then
    ok "control: /contra is named in _CLAUDE.md and provided"
else
    bad "control: /contra is not named in _CLAUDE.md or no plugin provides it"
fi

fx="$(mktemp "${TMPDIR:-/tmp}/vault-manual-cmds.XXXXXX")" || exit 1
trap 'rm -f "$fx"' EXIT
cat > "$fx" <<'EOF'
Run `/contra` daily.
Then /contra /not-a-real-command on one line.
See docs/luna and ~/.local/share and /usr/bin/env.
EOF
got="$(dead_commands "$fx")"
if [ "$got" = "$fx:2: /not-a-real-command" ]; then
    ok "fixture: only /not-a-real-command is flagged"
else
    bad "fixture: expected only /not-a-real-command flagged, got: $got"
fi
missing="$(dead_commands "$fx.absent")"
if [ "$missing" = "$fx.absent: missing or unreadable" ]; then
    ok "fixture: a missing manual file is reported"
else
    bad "fixture: a missing manual file was not reported, got: $missing"
fi

echo "vault-manual-commands: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
