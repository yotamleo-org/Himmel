#!/usr/bin/env bash
# Smoke test for scripts/ci/check-claude-md-budget.sh.
#
# The gate budgets ONLY himmel's own bytes: the `## graphify` section is
# upstream-owned (written verbatim by `graphify install --platform claude`) and
# excluded from the count with the installer's own boundary rule. Exercises the
# guard's direct-file mode against hermetic fixtures (mktemp -d), the real repo
# CLAUDE.md, and — when the uv-managed graphifyy venv is present — the REAL
# installer (`graphify.install.claude_install`) for the idempotence contract:
# a reinstall over the committed file changes nothing.
#
# Usage: bash scripts/ci/test-check-claude-md-budget.sh
#
# Exit codes:
#   0 — all cases passed
#   1 — at least one case failed
set -uo pipefail

GUARD="$(cd "$(dirname "$0")" && pwd)/check-claude-md-budget.sh"
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

failures=0
pass() { printf '  PASS  %s\n' "$1"; }
fail() { printf '  FAIL  %s\n' "$1"; failures=$((failures+1)); }

tmp=$(mktemp -d "${TMPDIR:-/tmp}/h2038.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

# A minimal graphify section every valid fixture carries (content is
# irrelevant to the gate — the section is excluded from the count).
section=$'## graphify\n\nupstream text, not ours.\n'

# Case A: a file comfortably under the budget (ours tiny + a section) → exit 0
echo "== Case A: under budget =="
printf '# tiny\n\n%s' "$section" > "$tmp/under.md"
bash "$GUARD" "$tmp/under.md"; rc=$?
if [ "$rc" -eq 0 ]; then pass "under.md -> exit 0"; else fail "under.md -> expected 0 got $rc"; fi

# Case B: over-budget HIMMEL content is refused, and the message names the
# overage and the exclusion. 20000 'x' outside the section vs the 6144 default.
echo "== Case B: over budget (ours) is refused =="
{ awk 'BEGIN { for (i = 0; i < 20000; i++) printf "x"; printf "\n\n" }'; printf '%s' "$section"; } > "$tmp/over.md"
out_b=$(bash "$GUARD" "$tmp/over.md" 2>&1); rc=$?
if [ "$rc" -eq 1 ]; then pass "over.md -> exit 1"; else fail "over.md -> expected 1 got $rc"; fi
if grep -q 'over the 6144 B always-on budget' <<< "$out_b" && grep -q 'graphify.*section is excluded' <<< "$out_b"; then
    pass "over.md -> message names the budget and the exclusion"
else
    fail "over.md -> message wrong: $out_b"
fi

# Case B2: a HUGE graphify section does NOT count against the budget.
echo "== Case B2: upstream section bytes are free =="
{ printf '# tiny\n\n## graphify\n\n'; awk 'BEGIN { for (i = 0; i < 20000; i++) printf "x"; printf "\n" }'; } > "$tmp/bigsection.md"
bash "$GUARD" "$tmp/bigsection.md"; rc=$?
if [ "$rc" -eq 0 ]; then pass "20 KB inside the section -> exit 0"; else fail "bigsection.md -> expected 0 got $rc"; fi

# Case C: CLAUDE_MD_MAX_BYTES overrides the limit (both directions).
echo "== Case C: env override =="
CLAUDE_MD_MAX_BYTES=3 bash "$GUARD" "$tmp/under.md" >/dev/null 2>&1; rc=$?
if [ "$rc" -eq 1 ]; then pass "limit 3 -> under.md now refused"; else fail "limit 3 -> expected 1 got $rc"; fi
CLAUDE_MD_MAX_BYTES=99999 bash "$GUARD" "$tmp/over.md"; rc=$?
if [ "$rc" -eq 0 ]; then pass "limit 99999 -> over.md now accepted"; else fail "limit 99999 -> expected 0 got $rc"; fi

# Case D: a non-numeric limit is a config error, not a silent pass.
echo "== Case D: bad limit fails closed =="
CLAUDE_MD_MAX_BYTES=lots bash "$GUARD" "$tmp/under.md" >/dev/null 2>&1; rc=$?
if [ "$rc" -eq 2 ]; then pass "CLAUDE_MD_MAX_BYTES=lots -> exit 2"; else fail "bad limit -> expected 2 got $rc"; fi

# Case E: duplicate graphify sections are refused (the installer replaces only
# the LAST one, so duplicates never self-heal).
echo "== Case E: duplicate sections refused =="
printf '# tiny\n\n%s\n%s' "$section" "$section" > "$tmp/dup.md"
out_e=$(bash "$GUARD" "$tmp/dup.md" 2>&1); rc=$?
if [ "$rc" -eq 1 ]; then pass "dup.md -> exit 1"; else fail "dup.md -> expected 1 got $rc"; fi
if grep -q "2 '## graphify' headings" <<< "$out_e"; then
    pass "dup.md -> message counts the duplicates"
else
    fail "dup.md -> message wrong: $out_e"
fi

# Case E2: no graphify section at all is refused with the reinstall hint.
echo "== Case E2: missing section refused =="
printf '# rules\n' > "$tmp/none.md"
out_e2=$(bash "$GUARD" "$tmp/none.md" 2>&1); rc=$?
if [ "$rc" -eq 1 ]; then pass "none.md -> exit 1"; else fail "none.md -> expected 1 got $rc"; fi
if grep -q 'graphify install --platform claude' <<< "$out_e2"; then
    pass "none.md -> reinstall hint present"
else
    fail "none.md -> no reinstall hint: $out_e2"
fi
# ' -- then ' in a pasted shell line ends option parsing for `graphify install`
# and turns the re-price command into junk positional argv;
# the hint must not contain that sequence.
if grep -q -- ' -- then ' <<< "$out_e2"; then
    fail "none.md -> reinstall hint has the unrunnable ' -- then ' copy-paste trap"
else
    pass "none.md -> reinstall hint has no ' -- then ' copy-paste trap"
fi
if grep -q 're-price the hooks: bash scripts/lib/graphify-bin.sh price-hooks' <<< "$out_e2"; then
    pass "none.md -> re-price hint present"
else
    fail "none.md -> no re-price hint: $out_e2"
fi

# Case F: a missing file fails closed rather than passing vacuously.
echo "== Case F: missing file fails closed =="
bash "$GUARD" "$tmp/nope.md" >/dev/null 2>&1; rc=$?
if [ "$rc" -eq 2 ]; then pass "missing file -> exit 2"; else fail "missing file -> expected 2 got $rc"; fi

# Case G: the REAL committed CLAUDE.md passes.
echo "== Case G: repo CLAUDE.md is within budget =="
bash "$GUARD" "$REPO_ROOT/CLAUDE.md"; rc=$?
if [ "$rc" -eq 0 ]; then
    pass "repo CLAUDE.md -> exit 0 (total $(wc -c < "$REPO_ROOT/CLAUDE.md" | tr -d ' ') B)"
else
    fail "repo CLAUDE.md -> expected 0 got $rc"
fi

# Case H (venv-gated): the REAL installer over the committed file changes no
# himmel-owned byte (everything outside the upstream-owned `## graphify`
# section) and is idempotent. The section's own wording moves with the graphify
# version, so it is NOT compared.
echo "== Case H: real claude_install is idempotent over the repo file =="
py=""
tool_dir="$(uv tool dir 2>/dev/null | tr -d '\r')"
for cand in "$tool_dir/graphifyy/Scripts/python.exe" "$tool_dir/graphifyy/bin/python"; do
  [ -n "$tool_dir" ] && [ -x "$cand" ] && { py="$cand"; break; }
done
# install_into <src> <dir>: run the real installer over a copy of <src> in
# <dir>/CLAUDE.md.
install_into() {
    mkdir -p "$2"
    cp "$1" "$2/CLAUDE.md"
    # a crashed installer must not read as "unchanged"
    if ! "$py" - "$2" <<'PY' >/dev/null
import sys, pathlib
from graphify import install
install.claude_install(project_dir=pathlib.Path(sys.argv[1]))
PY
    then
        return 1
    fi
}
# outside_section <file>: the file minus its `## graphify` section (heading to
# the next `## ` heading or EOF) — the section is upstream-owned and its
# wording changes with the graphify version, so only the rest is compared.
outside_section() {
    awk '/^## graphify$/ { skip = 1; next } /^## / { skip = 0 } !skip' "$1"
}
if [ -n "$py" ] && "$py" -c 'import graphify.install' 2>/dev/null; then
    if ! install_into "$REPO_ROOT/CLAUDE.md" "$tmp/proj"; then
        fail "Case H: the real installer failed — idempotence unproven"
    elif cmp -s <(outside_section "$REPO_ROOT/CLAUDE.md") <(outside_section "$tmp/proj/CLAUDE.md"); then
        pass "claude_install leaves every himmel-owned byte outside the graphify section untouched"
    else
        fail "claude_install CHANGED himmel-owned text outside the graphify section"
    fi
    # idempotence: a second install over the first one's output changes nothing
    if install_into "$tmp/proj/CLAUDE.md" "$tmp/proj3" && cmp -s "$tmp/proj/CLAUDE.md" "$tmp/proj3/CLAUDE.md"; then
        pass "claude_install is idempotent (second install -> byte-identical)"
    else
        fail "claude_install is not idempotent over its own output"
    fi
    n=$(grep -c '^## graphify$' "$tmp/proj/CLAUDE.md")
    if [ "$n" -eq 1 ]; then pass "still exactly one section"; else fail "$n sections after install"; fi
    bash "$GUARD" "$tmp/proj/CLAUDE.md" >/dev/null 2>&1; rc=$?
    if [ "$rc" -eq 0 ]; then pass "gate green after install"; else fail "gate -> expected 0 got $rc"; fi

    # Case H2: the compare keeps its teeth. (a) a stock-text variant of the
    # section (installer wording from another graphify version) must still
    # pass; (b) drift in himmel-owned text outside the section must be seen;
    # (c) a duplicated section is still refused by the gate (cases E/E2).
    echo "== Case H2: stock variants pass, himmel-text drift still fails =="
    # reword every bullet inside the section: a stand-in for another version's stock text
    sed '/^## graphify$/,$ s/^- .*$/- ALT STOCK WORDING./' "$REPO_ROOT/CLAUDE.md" > "$tmp/variant.md"
    if cmp -s "$REPO_ROOT/CLAUDE.md" "$tmp/variant.md"; then
        fail "H2a fixture did not mutate the section (no bullets under the heading?)"
    elif install_into "$tmp/variant.md" "$tmp/proj2" \
        && cmp -s <(outside_section "$tmp/variant.md") <(outside_section "$tmp/proj2/CLAUDE.md"); then
        pass "H2a: a stock-text variant of the section passes"
    else
        fail "H2a: a stock-text variant of the section was rejected"
    fi
    sed 's/^## WORKFLOWS$/## WORKFLOWS-DRIFT/' "$REPO_ROOT/CLAUDE.md" > "$tmp/drifted.md"
    # cmp: 0 equal, 1 differ, 2 trouble — only 1 proves the drift was seen
    cmp -s <(outside_section "$REPO_ROOT/CLAUDE.md") <(outside_section "$tmp/drifted.md"); cmp_rc=$?
    if [ "$cmp_rc" -eq 0 ]; then
        fail "H2b: drift outside the section compared equal — the compare has no teeth"
    elif [ "$cmp_rc" -eq 1 ]; then
        pass "H2b: drift outside the section is detected"
    else
        fail "H2b: cmp could not compare (rc=$cmp_rc) — drift detection unproven"
    fi
else
    echo "  SKIP  no uv-managed graphifyy venv — real-installer idempotence not exercised here"
fi

echo
if [ "$failures" -eq 0 ]; then echo "ALL PASS"; else echo "$failures FAILURE(S)"; fi
exit $(( failures > 0 ? 1 : 0 ))
