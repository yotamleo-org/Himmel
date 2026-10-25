#!/usr/bin/env bash
# selector: tree-scan
# Suite for docs/team.md, the "Meet the team" page, and its generator
# scripts/docs/gen-team-page.sh.
#
#   1. FRESH   — the committed page equals what the generator builds from the
#                role sources (gen-team-page.sh --check exits 0).
#   2. PLANTED — a fixture tree with an extra .claude/agents role and no card
#                fails, naming the source.
#   3. GONE    — a fixture tree with a card's role source deleted fails,
#                naming it.
#   4. STALE   — a fixture tree whose page was edited by hand fails.
#   5. DRIFT   — a fixture tree whose source lost a card's anchor (the judge's
#                `model:` line) fails.
#   6. NO JS   — the page is one plain <details> with a <summary> per card and
#                carries no script.
#   7. CONTROL — an untouched fixture copy passes, so 2 to 5 fail for their
#                planted cause and not for the copy.
#
# Usage: bash scripts/docs/test-team-page.sh
# Exit:  0 = every case passed, 1 = at least one failed (all are reported).
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
GEN="$HERE/gen-team-page.sh"
PAGE="$ROOT/docs/team.md"
. "$HERE/../lib/fixture-tempdir.sh" || exit 1
TMP=$(fixture_mktemp_dir) || exit 1
trap 'rm -rf "$TMP"' EXIT

pass=0
fail=0
ok() { pass=$((pass + 1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf 'FAIL %s\n' "$1"; [ -n "${2:-}" ] && printf '       %s\n' "$2"; }

# fixture <name>: a copy of the files the generator reads, under $TMP/<name>.
fixture() {
    local d="$TMP/$1"
    mkdir -p "$d/.claude" "$d/scripts/cr" "$d/scripts/jira/src/commands" || return 1
    cp -R "$ROOT/docs" "$d/docs" || return 1
    cp -R "$ROOT/.claude/agents" "$d/.claude/agents" || return 1
    cp "$ROOT/scripts/cr/critics.json" "$d/scripts/cr/" || return 1
    cp "$ROOT/scripts/jira/src/commands/release.ts" "$d/scripts/jira/src/commands/" || return 1
    echo "$d"
}

# expect_fail <case> <root> <stderr substring>
expect_fail() {
    local err rc
    err=$(bash "$GEN" --check --root "$2" 2>&1 >/dev/null)
    rc=$?
    if [ "$rc" -eq 1 ] && printf '%s' "$err" | grep -qF -- "$3"; then
        ok "$1"
    else
        bad "$1" "rc=$rc, wanted 1 with '$3'; got: $err"
    fi
}

# 1. FRESH
err=$(bash "$GEN" --check 2>&1 >/dev/null)
rc=$?
if [ "$rc" -eq 0 ]; then ok "fresh: docs/team.md equals the generated page"; else bad "fresh: docs/team.md equals the generated page" "rc=$rc: $err"; fi

# 7. CONTROL
if d=$(fixture control); then
    err=$(bash "$GEN" --check --root "$d" 2>&1 >/dev/null)
    rc=$?
    if [ "$rc" -eq 0 ]; then ok "control: an untouched fixture copy passes"; else bad "control: an untouched fixture copy passes" "rc=$rc: $err"; fi
else
    bad "control: fixture copy" "could not build the fixture"
fi

# 2. PLANTED
if d=$(fixture planted); then
    printf -- '---\nname: planner\ndescription: Plans a shift.\nmodel: sonnet\n---\n\nYou plan.\n' >"$d/.claude/agents/planner.md"
    expect_fail "planted: an agent role with no card fails" "$d" "role source with no card: .claude/agents/planner.md"
else
    bad "planted: fixture" "could not build the fixture"
fi

# 3. GONE
if d=$(fixture gone); then
    rm -f "$d/docs/handover/rm-preface.md"
    expect_fail "gone: a card whose role source was deleted fails" "$d" "no longer exists: docs/handover/rm-preface.md"
else
    bad "gone: fixture" "could not build the fixture"
fi

# 4. STALE
if d=$(fixture stale); then
    if [ -f "$d/docs/team.md" ]; then
        printf '<details>\n<summary>The planner</summary>\n\n- **Its job:** plans.\n\n</details>\n' >>"$d/docs/team.md"
    fi
    expect_fail "stale: a hand-added card fails" "$d" "docs/team.md is"
else
    bad "stale: fixture" "could not build the fixture"
fi

# 5. DRIFT
if d=$(fixture drift); then
    grep -v '^model:' "$ROOT/.claude/agents/judge-ro.md" >"$d/.claude/agents/judge-ro.md"
    expect_fail "drift: a source that lost a card's anchor fails" "$d" "no frontmatter model: in .claude/agents/judge-ro.md"
else
    bad "drift: fixture" "could not build the fixture"
fi

# 6. NO JS
if [ -f "$PAGE" ]; then
    opens=$(grep -c '^<details>$' "$PAGE")
    sums=$(grep -c '^<summary>[^<]*</summary>$' "$PAGE")
    closes=$(grep -c '^</details>$' "$PAGE")
    if [ "$opens" -ge 5 ] && [ "$opens" = "$sums" ] && [ "$opens" = "$closes" ] && ! grep -qi '<script' "$PAGE"; then
        ok "no js: $opens plain <details> cards, each with a <summary>, no script"
    else
        bad "no js: plain <details> cards, no script" "details=$opens summary=$sums close=$closes"
    fi
else
    bad "no js: plain <details> cards, no script" "docs/team.md missing"
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
