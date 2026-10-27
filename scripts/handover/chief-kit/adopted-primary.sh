#!/usr/bin/env bash
# adopted-primary.sh <dir>
#
# Exit 0 when <dir> is the PRIMARY checkout of a registered himmel adopter repo:
# its origin nwo is in scripts/guardrails/himmel-adapters.json (read from THIS
# harness's primary checkout, which a worker never edits) AND its realpath is
# listed in the handover registry. Both must hold: a clone anywhere with a
# copied origin, or a sibling dir named like the adopter, is not in the registry.
# himmel's own primary checkout never matches.
#
# Shared by worker-pretrust.sh and block-write-into-main-checkout.sh; one match,
# no second copy.
# Exit: 0 match, 1 no match, 2 usage.
set -uo pipefail

# shellcheck source=../../lib/git-clean.sh
. "$(dirname "$0")/../../lib/git-clean.sh"
git_env_scrub   # an inherited GIT_DIR would make the checks read the wrong repo

dir="${1:-}"
[ -n "$dir" ] || { echo "adopted-primary: usage: adopted-primary.sh <dir>" >&2; exit 2; }
[ -d "$dir" ] || exit 1
command -v node >/dev/null 2>&1 || exit 1

abs="$(cd -P "$dir" 2>/dev/null && pwd -P)" || exit 1 # swallow-ok: an unresolvable dir is no match (exit 1)
top="$(git -C "$abs" rev-parse --show-toplevel 2>/dev/null)" || top="" # swallow-ok: empty top fails the match
top="$(cd -P "$top" 2>/dev/null && pwd -P)" || top="" # swallow-ok: same, an unresolvable top is never matched
harness_common="$(git -C "$(dirname "$0")" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || harness_common="" # swallow-ok: no harness root, no registry, no match
harness_root="$(cd -P "$harness_common/.." 2>/dev/null && pwd -P)" || harness_root="" # swallow-ok: same
origin_url="$(git -C "$abs" remote get-url origin 2>/dev/null)" || origin_url="" # swallow-ok: no origin is no adopter match

[ -n "$top" ] && [ "$top" = "$abs" ] && [ -n "$harness_root" ] && [ "$abs" != "$harness_root" ] || exit 1
WT_URL="$origin_url" WT_REG="$harness_root/scripts/guardrails/himmel-adapters.json" node -e '
    const m = /^(?:https:\/\/(?:[^\/@]+@)?|ssh:\/\/git@|git@)github\.com[:\/]([^\/]+\/[^\/]+?)(?:\.git)?\/?$/.exec(process.env.WT_URL || "");
    if (!m) process.exit(1);
    const want = m[1].toLowerCase();
    const reg = JSON.parse(require("fs").readFileSync(process.env.WT_REG, "utf8"));
    process.exit(Array.isArray(reg) && reg.some((e) => String(e.nwo).toLowerCase() === want) ? 0 : 1);' 2>/dev/null || exit 1
bash "$(dirname "$0")/../register-state.sh" --check --repo-path "$abs" >/dev/null 2>&1 || exit 1
exit 0
