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
# and provided; 3. a fixture proves the check flags a dead command and only it.
#
# Platform guard (posix-bash): pure POSIX bash 3.2+ plus grep/sed/mktemp.
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
    grep -n -o -E '(^|[[:space:]`(])/[a-z][a-z0-9-]*[a-z0-9]([^a-zA-Z0-9/._-]|$)' "$1" \
        | sed -E 's#^([0-9]+):[^/]*/([a-z0-9-]+).*#\1:/\2#'
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
        while IFS= read -r hit; do
            [ -n "$hit" ] || continue
            provided "${hit#*:/}" || echo "${f#"$ROOT"/}:${hit%%:*}: ${hit#*:}"
        done <<EOF
$(named_commands "$f")
EOF
    done
}

MANUAL="$TPL/_CLAUDE.md $TPL/AGENTS.md"
for f in "$TPL"/docs/*.md; do MANUAL="$MANUAL $f"; done

# shellcheck disable=SC2086
dead="$(dead_commands $MANUAL)"
if [ -z "$dead" ]; then
    ok "the vault manual names only commands a plugin provides"
else
    bad "the vault manual names commands no plugin provides:"
    printf '%s\n' "$dead" | sed 's/^/  /' >&2
fi

if grep -q -E '(^|[[:space:]`(])/contra([^a-zA-Z0-9/._-]|$)' "$TPL/_CLAUDE.md" && provided contra; then
    ok "control: /contra is named in _CLAUDE.md and provided"
else
    bad "control: /contra is not named in _CLAUDE.md or no plugin provides it"
fi

fx="$(mktemp "${TMPDIR:-/tmp}/vault-manual-cmds.XXXXXX")" || exit 1
trap 'rm -f "$fx"' EXIT
cat > "$fx" <<'EOF'
Run `/contra` daily.
Index with `/obsidian-init`.
See docs/luna and ~/.local/share and /usr/bin/env.
EOF
got="$(dead_commands "$fx")"
if [ "$got" = "$fx:2: /obsidian-init" ]; then
    ok "fixture: only /obsidian-init is flagged"
else
    bad "fixture: expected only /obsidian-init flagged, got: $got"
fi

echo "vault-manual-commands: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
