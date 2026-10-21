#!/usr/bin/env bash
# skillspector-scan.sh — opt-in, advisory SkillSpector Stage 1 (static,
# --no-llm) scan of one skill directory. Stores the JSON report where the
# caller asks (beside the adoption note or clipped skill).
#
# Advisory only: a finding means "read the flagged line before adopting or
# using", never a block. Stage 2 (LLM) is out of scope and never run.
#
# Usage: skillspector-scan.sh <skill-dir> <report.json>
#   Exit codes: 0 scan ran and the report was stored; 1 bad usage;
#   2 refused (SKILLSPECTOR_PROVIDER unset or not the no-egress value);
#   3 unavailable (skillspector missing, failed, or produced no JSON).
#   Env: SKILLSPECTOR_PROVIDER must be `ollama` (local, no egress): upstream
#   defaults an unset provider to nv_build, which sends skill text to
#   build.nvidia.com. SKILLSPECTOR_BIN overrides the binary (tests stub it).
#   This wrapper never installs anything; pip install belongs in a throwaway
#   sandbox or the test VM.

set -u -o pipefail

if [ "$#" -ne 2 ]; then
    echo "usage: skillspector-scan.sh <skill-dir> <report.json>" >&2
    exit 1
fi
skill_dir="$1"
report="$2"

if [ ! -d "$skill_dir" ]; then
    echo "skillspector-scan: not a directory: $skill_dir" >&2
    exit 1
fi

if [ "${SKILLSPECTOR_PROVIDER-}" != "ollama" ]; then
    echo "skillspector-scan: refused: SKILLSPECTOR_PROVIDER must be 'ollama' (no egress); unset defaults to nv_build, which sends skill text to build.nvidia.com" >&2
    exit 2
fi

bin="${SKILLSPECTOR_BIN:-skillspector}"
if ! command -v "$bin" >/dev/null 2>&1; then
    echo "skillspector-scan: unavailable: '$bin' not found (install only in a throwaway sandbox or the test VM)" >&2
    exit 3
fi

out="$(mktemp "${TMPDIR:-/tmp}/skillspector-scan.XXXXXX")" || exit 3
trap 'rm -f "$out"' EXIT

# A finding makes skillspector exit non-zero (rc 1 on a HIGH report), so the
# report decides, not rc.
"$bin" scan "$skill_dir" --no-llm --format json > "$out" 2>/dev/null
summary="$(node -e '
const r = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
const score = r && r.risk_assessment && r.risk_assessment.score;
if (!Array.isArray(r && r.issues) || typeof score !== "number") process.exit(1);
if (r.execution_successful === false) process.exit(1);
if (r.analysis_completeness && r.analysis_completeness.is_complete === false) process.exit(1);
const issues = r.issues;
const high = issues.filter((i) => i.severity === "HIGH").length;
console.log("score=" + score + " issues=" + issues.length + " high=" + high);
' "$out" 2>/dev/null)" || summary=""
if [ -z "$summary" ]; then
    echo "skillspector-scan: unavailable: skillspector produced no complete scan report (need risk_assessment.score, an issues array, and no failed or incomplete run)" >&2
    exit 3
fi

if [ -L "$report" ]; then
    echo "skillspector-scan: unavailable: report destination is a symlink: $report" >&2
    exit 3
fi
cp "$out" "$report" || exit 3
echo "skillspector-scan: report stored at $report"
echo "skillspector-scan: $summary (advisory: read each flagged line before adopting or using)"
