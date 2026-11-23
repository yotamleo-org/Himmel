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
#   2 refused (SKILLSPECTOR_PROVIDER unset or not the local value, or
#     SKILLSPECTOR_OFFLINE=1 and the network cannot be denied on this host);
#   3 unavailable (skillspector missing, failed, or produced no JSON).
#   Env: SKILLSPECTOR_PROVIDER must be `ollama` (local): upstream defaults an
#   unset provider to nv_build, which sends skill text to build.nvidia.com.
#   SKILLSPECTOR_BIN overrides the binary (tests stub it).
#   OSV lookup: Stage 1 posts the lockfile package names and versions to
#   api.osv.dev to check them for known CVEs; this is the scan's one network
#   call and it stays on by default. SKILLSPECTOR_OFFLINE=1 skips it: the scan
#   runs in an empty network namespace (`unshare --user --net`), refused where
#   that is unavailable (macOS, user namespaces disabled), the dependencies
#   are checked against SkillSpector's small built-in list only, and the
#   summary says deps=offline-fallback.
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

offline=0
netdeny=()
if [ "${SKILLSPECTOR_OFFLINE-}" = "1" ]; then
    offline=1
    netdeny=(unshare --user --map-root-user --net --)
    if ! "${netdeny[@]}" true >/dev/null 2>&1; then
        echo "skillspector-scan: refused: SKILLSPECTOR_OFFLINE=1 but the network cannot be denied here (needs unshare with unprivileged user namespaces)" >&2
        exit 2
    fi
fi

out="$(mktemp "${TMPDIR:-/tmp}/skillspector-scan.XXXXXX")" || exit 3
trap 'rm -f "$out"' EXIT

# rc 1 is skillspector's HIGH-finding exit, so the report decides there; any
# other non-zero rc is a crash and never yields a stored report.
"${netdeny[@]+"${netdeny[@]}"}" "$bin" scan "$skill_dir" --no-llm --format json > "$out" 2>/dev/null
scan_rc=$?
if [ "$scan_rc" -ne 0 ] && [ "$scan_rc" -ne 1 ]; then
    echo "skillspector-scan: unavailable: skillspector failed (rc $scan_rc)" >&2
    exit 3
fi
summary="$(node -e '
const r = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
const score = r && r.risk_assessment && r.risk_assessment.score;
if (!Array.isArray(r && r.issues) || typeof score !== "number") process.exit(1);
const ac = r.analysis_completeness;
if (r.execution_successful !== undefined && typeof r.execution_successful !== "boolean") process.exit(1);
if (ac && ac.is_complete !== undefined && typeof ac.is_complete !== "boolean") process.exit(1);
if (r.execution_successful === false) process.exit(1);
const osvAnalyzer = "static_patterns_supply_chain_dependencies_analyzer_runtime_error";
const isOsvDenied = (e) => !!e && e.reason_code === "analyzer_runtime_error" && e.error_class === "ConnectError" &&
    Array.isArray(e.analyzers) && e.analyzers.length === 1 && e.analyzers[0] === osvAnalyzer;
let offline = false;
if (ac && ac.is_complete === false) {
    if (process.argv[2] !== "1") process.exit(1);
    const ex = Array.isArray(ac.ledger_exceptions) ? ac.ledger_exceptions : [];
    const osv = ex.filter(isOsvDenied);
    const lims = Array.isArray(ac.limitations) ? ac.limitations : [null];
    offline = osv.length > 0 &&
        ex.every((e) => isOsvDenied(e) || (!!e && e.reason_code === "reference_missing")) &&
        lims.every((l) => l === "Analyzer static_patterns_supply_chain status: degraded.") &&
        ac.entirely_uninspected_files === 0 &&
        typeof ac.partially_inspected_files === "number" &&
        ac.partially_inspected_files <= new Set(osv.map((e) => e.path)).size;
    if (!offline) process.exit(1);
}
const issues = r.issues;
const high = issues.filter((i) => i.severity === "HIGH").length;
console.log("score=" + score + " issues=" + issues.length + " high=" + high +
    (offline ? " deps=offline-fallback (api.osv.dev not reached; dependency CVEs checked against the static fallback list only)" : ""));
' "$out" "$offline" 2>/dev/null)" || summary=""
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
