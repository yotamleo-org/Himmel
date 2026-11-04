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
# The check skips CLAUDE.md's installer-owned `## graphify` section, so pin that section here: it names the wrapper,
# not a bare graphify form (a worktree has no graph, so the bare form fails there), and has no `graphify update`.
GSEC="$(awk '/^## graphify[[:space:]]*$/ { on = 1; next } /^## / { on = 0 } on' "$REPO/CLAUDE.md")"
expect "CLAUDE.md graphify section was read" 0 "$(grep -q . <<<"$GSEC"; echo $?)"
expect "CLAUDE.md graphify section names no bare graphify form" 1 "$(grep -Eq '(^|[^A-Za-z0-9_./-])graphify[[:space:]]+(query|explain|path|update)([^A-Za-z0-9_-]|$)' <<<"$GSEC"; echo $?)"
expect "CLAUDE.md graphify section teaches the graph wrapper" 0 "$(grep -q -F 'bash scripts/graphify/worker-graph.sh query' <<<"$GSEC"; echo $?)"

# Default mode scans the listed files, and a listed file or filter that yields no line cannot be evaluated.
# A copy of the check sits in a fake repo root whose listed files this test writes.
# The list as the check holds it, one file[|filter] per line.
TAUGHT_SPECS="$(sed -n "/^TAUGHT='/,/'\$/p" "$CHECK" | sed -e "s/^TAUGHT='//" -e "s/'\$//")"
spec_filter() { case "$1" in *'|'*) printf '%s ' "${1#*|}" ;; esac; }
fake_root() {
    local r=$1 spec f
    mkdir -p "$r/scripts/ci"
    cp "$CHECK" "$r/scripts/ci/check-taught-search-forms.sh"
    while IFS= read -r spec; do
        f=${spec%%|*}
        mkdir -p "$(dirname "$r/$f")"
        printf '%sbash scripts/lib/qmd-bounded.sh query -c luna "x"\n' "$(spec_filter "$spec")" >"$r/$f"
    done <<<"$TAUGHT_SPECS"
}
run_fake() { bash "$1/scripts/ci/check-taught-search-forms.sh" >/dev/null 2>&1; echo $?; }
fake_root "$T/fake-ok"
expect "default mode: a clean fake root passes" 0 "$(run_fake "$T/fake-ok")"
fake_root "$T/fake-bare"
printf 'qmd query "x"\n' >"$T/fake-bare/docs/token-economy.md"
expect "default mode: a bare form in a listed file fails" 1 "$(run_fake "$T/fake-bare")"
fake_root "$T/fake-nofilter"
printf 'echo "the deny line was reworded"\n' >"$T/fake-nofilter/scripts/hooks/block-graphify-egress.sh"
expect "default mode: a filter that matches no line cannot be evaluated" 2 "$(run_fake "$T/fake-nofilter")"
fake_root "$T/fake-empty"
: >"$T/fake-empty/docs/handover/running-a-chief.md"
expect "default mode: an emptied listed file cannot be evaluated" 2 "$(run_fake "$T/fake-empty")"

taught_n="$(printf '%s\n' "$TAUGHT_SPECS" | grep -c .)"
expect "the TAUGHT list was read" 0 "$(grep -q . <<<"$TAUGHT_SPECS"; echo $?)"
expect "the judge brief template is on the TAUGHT list" 0 "$(grep -qxF docs/handover/judge-brief-template.md <<<"$TAUGHT_SPECS"; echo $?)"
# Every listed entry is live: a bare form planted in it fails, and emptying it cannot be evaluated.
mutated=0
while IFS= read -r spec; do
    f=${spec%%|*}
    fake_root "$T/mut-bare-$mutated"
    printf '%sqmd query "x"\n' "$(spec_filter "$spec")" >"$T/mut-bare-$mutated/$f"
    expect "default mode: a bare form planted in $f fails" 1 "$(run_fake "$T/mut-bare-$mutated")"
    fake_root "$T/mut-empty-$mutated"
    : >"$T/mut-empty-$mutated/$f"
    expect "default mode: emptying $f cannot be evaluated" 2 "$(run_fake "$T/mut-empty-$mutated")"
    mutated=$((mutated + 1))
done <<<"$TAUGHT_SPECS"
expect "default mode: the control mutated every TAUGHT entry" "$taught_n" "$mutated"

# awk failing after partial output cannot be evaluated: the rest of the file was never scanned.
real_awk="$(command -v awk)"
mkdir -p "$T/partial-awk" "$T/partial-section-awk"
printf '#!/bin/sh\nIFS= read -r line; printf "%%s\\n" "$line"; exit 1\n' >"$T/partial-awk/awk"
printf '#!/bin/sh\ncase "$1" in *skip*) IFS= read -r line; printf "%%s\\n" "$line"; exit 1 ;; esac\nexec "%s" "$@"\n' "$real_awk" >"$T/partial-section-awk/awk"
chmod +x "$T/partial-awk/awk" "$T/partial-section-awk/awk"
printf 'clean line\nqmd query "x"\n' >"$T/partial.md"
expect "the line-join awk failing after partial output fails closed" 2 "$(PATH="$T/partial-awk:$PATH" bash "$CHECK" "$T/partial.md" >/dev/null 2>&1; echo $?)"
fake_root "$T/fake-partial"
printf 'clean line\nqmd query "x"\n' >"$T/fake-partial/CLAUDE.md"
expect "the section awk failing after partial output fails closed" 2 "$(PATH="$T/partial-section-awk:$PATH" bash "$T/fake-partial/scripts/ci/check-taught-search-forms.sh" >/dev/null 2>&1; echo $?)"

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
printf 'qmd \\\n  query -c luna "x"\n' >"$T/bare-continued.md"
expect "a bare qmd query split over a shell line continuation fails" 1 "$(run "$T/bare-continued.md")"
printf 'bash scripts/lib/qmd-bounded.sh \\\n  query -c luna "x"\n' >"$T/ok-continued.md"
expect "the wrapper form split over a shell line continuation passes" 0 "$(run "$T/ok-continued.md")"

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

# In the repo's own CLAUDE.md the installer-owned graphify section is not scanned; the rest is.
fake_root "$T/section"
printf '# P\n\nsee the wrapper\n\n## graphify\n\n- first run `graphify query "q"`\n' >"$T/section/CLAUDE.md"
expect "a bare form inside the installer-owned graphify section passes" 0 "$(run_fake "$T/section")"
# Only that file has the section: another file named CLAUDE.md is scanned whole.
mkdir -p "$T/nested"
printf '# P\n\nsee the wrapper\n\n## graphify\n\n- first run `graphify query "q"`\n' >"$T/nested/CLAUDE.md"
expect "a bare form in the graphify section of another CLAUDE.md fails" 1 "$(run "$T/nested/CLAUDE.md")"
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
