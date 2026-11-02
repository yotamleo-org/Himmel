#!/usr/bin/env bash
# shellcheck disable=SC2016  # the backticks are literal text in the planted fixtures
# Smoke test for scripts/ci/check-taught-search-forms.sh: the taught files keep a working
# search form, and a planted bare form is refused.
#
# Usage: bash scripts/ci/test-check-taught-search-forms.sh
set -uo pipefail

CHECK="$(cd "$(dirname "$0")" && pwd)/check-taught-search-forms.sh"
FAILED=0
T="$(mktemp -d "${TMPDIR:-/tmp}/taught-forms.XXXXXX")" || exit 1
trap 'rm -rf "$T"' EXIT

expect() {
    local label=$1 want=$2 got=$3
    if [ "$got" = "$want" ]; then
        echo "PASS $label (rc=$got)"
    else
        echo "FAIL $label - expected rc=$want, got rc=$got"
        FAILED=$((FAILED + 1))
    fi
}

run() { bash "$CHECK" "$@" >/dev/null 2>&1; echo $?; }

# The taught files in this repo pass.
expect "the taught files pass" 0 "$(run)"
# CLAUDE.md's Retrieval routing line teaches both wrapper commands. This pins it now that the steering-cull
# suite no longer pins the old l71-qmd-graphify span (that line was rewritten on purpose).
REPO="$(cd "$(dirname "$CHECK")/../.." && pwd)"
expect "CLAUDE.md teaches the qmd wrapper form" 0 "$(grep -q -F 'bash scripts/lib/qmd-bounded.sh query -c' "$REPO/CLAUDE.md"; echo $?)"
expect "CLAUDE.md teaches the graph wrapper form" 0 "$(grep -q -F 'bash scripts/graphify/worker-graph.sh query|explain|path' "$REPO/CLAUDE.md"; echo $?)"

# Default mode scans the listed files, and a listed file or filter that yields no line cannot be evaluated.
# A copy of the check sits in a fake repo root whose listed files this test writes.
fake_root() {
    local r=$1 f
    mkdir -p "$r/scripts/ci" "$r/scripts/hooks" "$r/docs/handover" "$r/marketplace/plugins/qmd/skills/qmd"
    cp "$CHECK" "$r/scripts/ci/check-taught-search-forms.sh"
    for f in CLAUDE.md docs/token-economy.md docs/handover/chief-template.md docs/handover/running-a-chief.md \
        docs/handover/worker-brief-template.md marketplace/plugins/qmd/skills/qmd/SKILL.md; do
        printf 'bash scripts/lib/qmd-bounded.sh query -c luna "x"\n' >"$r/$f"
    done
    printf 'echo "Retrieval nudge: bash scripts/lib/qmd-bounded.sh query -c luna x"\n' >"$r/scripts/hooks/retrieval-nudge.sh"
    printf 'echo "for read-only queries use: bash scripts/graphify/worker-graph.sh query x"\n' >"$r/scripts/hooks/block-graphify-egress.sh"
}
run_fake() { bash "$1/scripts/ci/check-taught-search-forms.sh" >/dev/null 2>&1; echo $?; }
fake_root "$T/fake-ok"
expect "default mode: a clean fake root passes" 0 "$(run_fake "$T/fake-ok")"
fake_root "$T/fake-bare"
printf 'qmd query "x"\n' >"$T/fake-bare/docs/token-economy.md"
expect "default mode: a bare form in a listed file fails" 1 "$(run_fake "$T/fake-bare")"
fake_root "$T/fake-nofilter"
printf 'echo "the nudge line was reworded"\n' >"$T/fake-nofilter/scripts/hooks/retrieval-nudge.sh"
expect "default mode: a filter that matches no line cannot be evaluated" 2 "$(run_fake "$T/fake-nofilter")"
fake_root "$T/fake-empty"
: >"$T/fake-empty/docs/handover/running-a-chief.md"
expect "default mode: an emptied listed file cannot be evaluated" 2 "$(run_fake "$T/fake-empty")"

# A planted bare form is refused, in each of the forms a session copies.
printf 'Search with:\n\nqmd query "question"\n' >"$T/bare-query.md"
expect "a planted bare qmd query fails" 1 "$(run "$T/bare-query.md")"
printf 'Try `qmd search keywords` first.\n' >"$T/bare-search.md"
expect "a planted bare qmd search in prose fails" 1 "$(run "$T/bare-search.md")"
printf '$ qmd vsearch "x"\n' >"$T/bare-vsearch.md"
expect "a planted bare qmd vsearch fails" 1 "$(run "$T/bare-vsearch.md")"
printf 'then `graphify explain "concept"` for structure\n' >"$T/bare-graph.md"
expect "a planted bare graphify explain fails" 1 "$(run "$T/bare-graph.md")"
printf 'graphify path "A" "B"\n' >"$T/bare-path.md"
expect "a planted bare graphify path fails" 1 "$(run "$T/bare-path.md")"

# The working forms, an MCP tool name, a sourced-script call and a marked mention pass.
printf 'bash scripts/lib/qmd-bounded.sh query -c luna "question"\n' >"$T/ok-wrapper.md"
expect "the qmd wrapper form passes" 0 "$(run "$T/ok-wrapper.md")"
printf 'bash scripts/graphify/worker-graph.sh query "question"\nbash scripts/graphify/worker-graph.sh path "A" "B"\n' >"$T/ok-graph.md"
expect "the graph wrapper forms pass" 0 "$(run "$T/ok-graph.md")"
printf 'use mcp__qmd__query or qmd get "#abc"\n' >"$T/ok-mcp.md"
expect "an MCP tool name and a non-search verb pass" 0 "$(run "$T/ok-mcp.md")"
printf 'qmd_bounded 60 qmd query x\n' >"$T/ok-sourced.md"
expect "a qmd_bounded call in a sourced script passes" 0 "$(run "$T/ok-sourced.md")"
printf 'the refused form is qmd query x <!-- taught-form-ok -->\n' >"$T/ok-marked.md"
expect "a marked mention of the refused form passes" 0 "$(run "$T/ok-marked.md")"

# An exempt token hides only itself: a bare form on the same line still fails.
printf 'use mcp__qmd__query or qmd query x\n' >"$T/mixed-mcp.md"
expect "a bare form beside an MCP tool name fails" 1 "$(run "$T/mixed-mcp.md")"
printf 'qmd_bounded 60 qmd query x, then qmd search y\n' >"$T/mixed-sourced.md"
expect "a bare form beside a qmd_bounded call fails" 1 "$(run "$T/mixed-sourced.md")"

# An unreadable file cannot be evaluated.
printf 'x\n' >"$T/unreadable.md"
chmod 000 "$T/unreadable.md"
if [ -r "$T/unreadable.md" ]; then
    echo "SKIP an unreadable file fails closed (this user reads mode 000 files)"
else
    expect "an unreadable file fails closed" 2 "$(run "$T/unreadable.md")"
fi

# In CLAUDE.md the installer-owned graphify section is not scanned; the rest is.
mkdir -p "$T/section"
printf '# P\n\nsee the wrapper\n\n## graphify\n\n- first run `graphify query "q"`\n' >"$T/section/CLAUDE.md"
expect "a bare form inside the installer-owned graphify section passes" 0 "$(run "$T/section/CLAUDE.md")"
mkdir -p "$T/outside"
printf '# P\n\nuse `graphify query "q"`\n\n## graphify\n\n- text\n' >"$T/outside/CLAUDE.md"
expect "a bare form outside the section in CLAUDE.md fails" 1 "$(run "$T/outside/CLAUDE.md")"

# A listed file that is missing cannot be evaluated.
expect "a missing file fails closed" 2 "$(run "$T/no-such-file.md")"

if [ "$FAILED" -eq 0 ]; then
    echo "ALL PASS"
    exit 0
fi
echo "$FAILED FAILED"
exit 1
