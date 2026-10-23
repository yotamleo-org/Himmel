#!/usr/bin/env bash
# scripts/ci/test-site-sidebar-slugs.sh -- static suite for the docs site sidebar
# Every `slug: '<x>'` (or double-quoted) in site/astro.config.mjs must resolve to a page the site
# builds: an entry of site/allowlist.txt (slug derived as slugOf() in
# site/src/plugins/remark-docs.mjs does) whose docs/ file exists, or the
# generated `index`. A sidebar slug with no built page is a live 404 link.
# Mutation controls prove the check fails on a fake slug and a missing doc; no network.
#
# Usage: bash scripts/ci/test-site-sidebar-slugs.sh
# Exit codes: 0 -- all cases passed; 1 -- at least one failed.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CFG="${SITE_CONFIG:-$ROOT/site/astro.config.mjs}"
ALLOW="${SITE_ALLOWLIST:-$ROOT/site/allowlist.txt}"
DOCS="${SITE_DOCS:-$ROOT/docs}"
fails=0
ok()  { echo "ok - $1"; }
bad() { echo "FAIL - $1" >&2; fails=$((fails + 1)); }

# slug_of <rel> -- mirrors slugOf() in site/src/plugins/remark-docs.mjs.
slug_of() {
    case "$1" in
        README.md) echo docs-map ;;
        *) local s="${1%.md}"; s="${s%/README}"; [ "$s" = README ] && s=""; echo "${s:-index}" ;;
    esac
}

# check <config> <allowlist> -- print one line per sidebar slug with no built page.
check() {
    local cfg="$1" allow="$2" rel built slug
    built=$'\nindex'
    while IFS= read -r rel; do
        [ -f "$DOCS/$rel" ] || continue
        built="$built"$'\n'"$(slug_of "$rel")"
    done < <(sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' "$allow" | grep -vE '^(#|$)') # pipefail-ok: small input
    while IFS= read -r slug; do
        grep -qxF -- "$slug" <<< "$built" || echo "sidebar-slug-not-built:$slug"
    done < <(grep -oE "slug: ['\"][^'\"]+['\"]" "$cfg" | sed -e 's/^slug: .//' -e 's/.$//') # pipefail-ok: small input
}

[ -f "$CFG" ] && [ -f "$ALLOW" ] || { bad "config or allowlist missing"; exit 1; }
n=$(grep -cE "slug: ['\"][^'\"]+['\"]" "$CFG")
if [ "$n" -gt 0 ]; then ok "found $n sidebar slugs"; else bad "no sidebar slugs found in $CFG"; fi

got=$(check "$CFG" "$ALLOW")
if [ -z "$got" ]; then ok "every sidebar slug resolves to a built page"; else bad "unbuilt sidebar slugs: ${got//$'\n'/ }"; fi

tmp=$(mktemp -d "${TMPDIR:-/tmp}/sidebar-slugs.XXXXXX") || exit 1; trap 'rm -rf "$tmp"' EXIT

# control: a fake slug is detected
sed -e "s/slug: ['\"]credits['\"]/slug: 'no-such-page'/" "$CFG" > "$tmp/fake.mjs"
if grep -qx 'sidebar-slug-not-built:no-such-page' <<< "$(check "$tmp/fake.mjs" "$ALLOW")"; then ok "control: fake slug detected"; else bad "control: fake slug NOT detected"; fi

# control: a double-quoted fake slug is detected
sed -e "s/slug: ['\"]credits['\"]/slug: \"no-such-page\"/" "$CFG" > "$tmp/fake2.mjs"
if grep -qx 'sidebar-slug-not-built:no-such-page' <<< "$(check "$tmp/fake2.mjs" "$ALLOW")"; then ok "control: double-quoted fake slug detected"; else bad "control: double-quoted fake slug NOT detected"; fi

# control: a slug whose allowlist line is dropped is detected
grep -vxF 'credits.md' "$ALLOW" > "$tmp/allow.txt"
if grep -qx 'sidebar-slug-not-built:credits' <<< "$(check "$CFG" "$tmp/allow.txt")"; then ok "control: dropped allowlist entry detected"; else bad "control: dropped allowlist entry NOT detected"; fi

[ "$fails" -eq 0 ] || exit 1
echo "all cases passed"
