#!/usr/bin/env bash
# skill-index/ensure-skill-index — idempotently build the /skill-find index
# and register it as the qmd 'skills' collection. Run by the
# himmelctl qmd install flow, so install and `himmelctl ensure` (which the
# update drift pass runs) both leave doctor C44-skill-index green.
#
# Registers or refreshes the collection; never runs `qmd embed` (no model download).
# qmd absent, or an index dir with no items, is a clean skip (rc 0): /skill-find
# is optional on a host without qmd.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../lib/qmd-bin.sh
. "$REPO_ROOT/scripts/lib/qmd-bin.sh"

if ! has_qmd; then
    echo "ensure-skill-index: qmd not resolvable -- skipping (qmd is optional)"
    exit 0
fi

out_dir="${SKILL_INDEX_DIR:-$HOME/.claude/skill-index}"
bash "$SCRIPT_DIR/build-skill-index.sh" --out "$out_dir" || exit $?

first_item=$(find "$out_dir" -maxdepth 1 -name '*.md' 2>/dev/null | head -n 1)
if [ -z "$first_item" ]; then
    echo "ensure-skill-index: no skill items found under $out_dir -- not registering"
    exit 0
fi

collections=$(qmd_cmd collection list) || exit $?
if printf '%s\n' "$collections" | grep -q '^skills[[:space:]]'; then
    qmd_cmd update -c skills
else
    qmd_register_collection "$out_dir" skills
fi
