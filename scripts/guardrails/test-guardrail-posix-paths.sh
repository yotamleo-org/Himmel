#!/usr/bin/env bash
# A POSIX single-letter root must not alias a drive-letter root.
# Exercise the real graphify-fence.sh and lesson-write-fence.sh entry points.
set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
BASH_BIN="$(command -v bash)"
WS="$(mktemp -d "${TMPDIR:-/tmp}/guardrail-posix.XXXXXX")" || exit 1
trap 'rm -rf "$WS"' EXIT
mkdir -p "$WS/home" "$WS/handover" "$WS/phi" || exit 1
failures=0
checks=0

check_graphify() {
    local expected="$1" name="$2" root="$3" target="$4" out rc
    local root_var="${5:-GRAPHIFY_HIMMEL_ROOT}" backend="${6:-deepseek}"
    checks=$((checks + 1))
    out=$(env -i PATH="$PATH" HOME="$WS/home" HANDOVER_DIR="$WS/handover" \
        CLAUDE_GLM_CONFIG_DIR="$WS/phi" "$root_var=$root" \
        "$BASH_BIN" "$REPO_ROOT/scripts/guardrails/graphify-fence.sh" \
        "graphify update $target --backend $backend" 2>&1); rc=$?
    if [ "$rc" -eq "$expected" ]; then
        printf 'PASS %s\n' "$name"
    else
        printf 'FAIL %s: expected rc=%s got rc=%s: %s\n' "$name" "$expected" "$rc" "$out"
        failures=$((failures + 1))
    fi
}

check_graphify 0 'literal /c/ root matches its own corpus' /c/fake/himmel /c/fake/himmel/doc.md
check_graphify 2 '/c/ does not alias C:/' C:/fake/himmel /c/fake/himmel/doc.md
check_graphify 2 '/c/ does not alias luna C:/' C:/fake/luna /c/fake/luna/journal.md LUNA_VAULT_PATH claude-cli
check_graphify 2 'C:/ does not alias /c/' /c/fake/himmel C:/fake/himmel/doc.md
check_graphify 0 'bare /c remains a POSIX root' /c /c
check_graphify 0 '/c/.. traversal resolves into the POSIX corpus' /fake/himmel /c/../fake/himmel/README.md

# No privileged /c directory is needed: the fence normalizes lexically before
# looking up the real repo, so /c/../<repo> must still protect its hooks.
checks=$((checks + 1))
target="/c/..$REPO_ROOT/scripts/hooks/example.sh"
out=$(env -i PATH="$PATH" HOME="$WS/home" "$BASH_BIN" \
    "$REPO_ROOT/scripts/guardrails/lesson-write-fence.sh" check "$target" 2>&1); rc=$?
if [ "$rc" -eq 2 ] && [ "$out" = "$(printf 'deny\thooks\t%s' "$target")" ]; then
    printf 'PASS lesson /c/.. traversal stays an enforcement path\n'
else
    printf 'FAIL lesson /c/.. traversal: expected hooks deny, got rc=%s: %s\n' "$rc" "$out"
    failures=$((failures + 1))
fi

printf '%s checks, %s failures\n' "$checks" "$failures"
[ "$failures" -eq 0 ]
