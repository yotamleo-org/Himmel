#!/usr/bin/env bash
# Suite: a vendored skill never links a file that does not exist, and the
# notes-search skill's allowed-tools is a space-separated list that names no
# bare qmd call. A link left dangling by vendoring sends an agent to a dead end
# mid-skill; a bare qmd pre-approval is one the block-bare-qmd-query hook refuses.
#
# Scope: every .md under marketplace/plugins/lean-skills/skills/ and
# marketplace/plugins/qmd/skills/. Relative markdown links `[text](path)` are
# resolved against the linking file's directory; URLs, `#anchors` and `mailto:`
# are skipped, a `#fragment` or `?query` suffix is stripped, and links inside
# fenced code blocks are template text, not links.
#
# Platform guard (posix-bash): pure POSIX bash 3.2+ plus awk/find/mktemp.
#
# Usage: bash scripts/docs/test-vendored-skill-links.sh
# Exit:  0 = every case passed, 1 = at least one failed (all are reported).
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
ROOTS="marketplace/plugins/lean-skills/skills marketplace/plugins/qmd/skills"

pass=0
fail=0
ok() { echo "ok: $*"; pass=$((pass + 1)); }
bad() { echo "FAIL: $*" >&2; fail=$((fail + 1)); }

links_of() {
    awk '
        /^[ \t]*(```|~~~)/ { fence = !fence; next }
        fence { next }
        {
            s = $0
            while (match(s, /\]\([^)[:space:]]+\)/)) {
                t = substr(s, RSTART + 2, RLENGTH - 3)
                s = substr(s, RSTART + RLENGTH)
                if (t ~ /^[a-zA-Z][a-zA-Z0-9+.-]*:/ || t ~ /^#/) continue
                sub(/[#?].*$/, "", t)
                if (t != "") print NR "\t" t
            }
        }' "$1"
}

tmp=$(mktemp -d "${TMPDIR:-/tmp}/vendored-links.XXXXXX") || exit 1
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/refs"
: >"$tmp/refs/there.md"
cat >"$tmp/doc.md" <<'EOF'
[ok](refs/there.md#frag) [gone](refs/missing.md) [web](https://example.com/x.md) [anchor](#top)
```
[fenced](refs/fenced-missing.md)
```
EOF
got=$(links_of "$tmp/doc.md" | cut -f2 | tr '\n' ' ')
if [ "$got" = "refs/there.md refs/missing.md " ]; then
    ok "link extractor keeps relative links, drops URLs, anchors and fenced text"
else
    bad "link extractor returned '$got'"
fi

scanned=0
for r in $ROOTS; do
    [ -d "$ROOT/$r" ] || { bad "scan root missing: $r"; continue; }
    while IFS= read -r f; do
        scanned=$((scanned + 1))
        dir=$(dirname "$f")
        while IFS="$(printf '\t')" read -r line target; do
            [ -n "$target" ] || continue
            if [ ! -e "$dir/$target" ]; then
                bad "${f#"$ROOT"/}:$line links '$target' which does not exist"
            fi
        done <<EOF
$(links_of "$f")
EOF
    done <<EOF
$(find "$ROOT/$r" -type f -name '*.md' | sort)
EOF
done

if [ "$scanned" -gt 0 ]; then
    ok "scanned $scanned vendored skill files"
else
    bad "scanned zero files (vacuous: the tree changed shape?)"
fi

QMD_SKILL="$ROOT/marketplace/plugins/qmd/skills/qmd/SKILL.md"
allowed=$(awk '/^allowed-tools:/ { sub(/^allowed-tools:[ \t]*/, ""); print; exit }' "$QMD_SKILL")
if [ -z "$allowed" ]; then
    bad "qmd skill has no allowed-tools line"
else
    case "$allowed" in
        *,*) bad "qmd allowed-tools is comma-separated, the standard says spaces: $allowed" ;;
        *) ok "qmd allowed-tools has no commas" ;;
    esac
    case " $allowed " in
        *' Bash(qmd:*)'*|*' Bash(qmd *)'*|*' Bash(qmd)'*) bad "qmd allowed-tools pre-approves a bare qmd call: $allowed" ;;
        *) ok "qmd allowed-tools names no bare qmd call" ;;
    esac
fi

echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
