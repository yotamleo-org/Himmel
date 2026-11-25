#!/usr/bin/env bash
# skillspector-scan.sh — SkillSpector scan of one skill directory. Stores
# the JSON report where the caller asks (beside the adoption note or clipped
# skill).
#
# Two modes, chosen by SKILLSPECTOR_PROVIDER (there is no default: unset is
# refused, because upstream would silently pick nv_build):
#   ollama (local, no egress): Stage 1 only (--no-llm), advisory: a finding
#     means "read the flagged line before adopting or using", never a block.
#   nv_build or anthropic (the vendoring path): the full scan, Stage 2 (the AI
#     review) included. The key must be in the environment: NVIDIA_INFERENCE_KEY
#     for nv_build, ANTHROPIC_API_KEY for anthropic; a missing key is a named
#     refusal. The scanner's stderr is kept in the stored report
#     (`wrapper_stderr`, keys redacted). A HIGH or CRITICAL finding that
#     survives Stage 2 stops the vendoring (rc 4) until a person has read the
#     line and recorded its match_fingerprint in `<report>.ack`, one per line.
#
# Usage: skillspector-scan.sh <skill-dir> <report.json>
#   Exit codes: 0 scan ran and the report was stored (and any HIGH is
#     acknowledged); 1 bad usage;
#   2 refused (SKILLSPECTOR_PROVIDER unset or not one of the three, the
#     provider key missing, or SKILLSPECTOR_OFFLINE=1 and the network cannot
#     be denied on this host or Stage 2 needs it);
#   3 unavailable (skillspector missing, failed, produced no JSON, or Stage 2
#     did not run to completion);
#   4 blocked: Stage 2 confirmed a HIGH or CRITICAL finding nobody has
#     acknowledged; the report is stored so the line can be read.
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

full=0
case "${SKILLSPECTOR_PROVIDER-}" in
    ollama) ;;
    nv_build)
        full=1
        if [ -z "${NVIDIA_INFERENCE_KEY-}" ]; then
            echo "skillspector-scan: refused: SKILLSPECTOR_PROVIDER=nv_build needs NVIDIA_INFERENCE_KEY in the environment, and it is not set" >&2
            exit 2
        fi ;;
    anthropic)
        full=1
        if [ -z "${ANTHROPIC_API_KEY-}" ]; then
            echo "skillspector-scan: refused: SKILLSPECTOR_PROVIDER=anthropic needs ANTHROPIC_API_KEY in the environment, and it is not set" >&2
            exit 2
        fi ;;
    *)
        echo "skillspector-scan: refused: SKILLSPECTOR_PROVIDER must be 'nv_build' or 'anthropic' (the full scan, key in the environment) or 'ollama' (Stage 1 only, no egress); unset would default to nv_build" >&2
        exit 2 ;;
esac

bin="${SKILLSPECTOR_BIN:-skillspector}"
if ! command -v "$bin" >/dev/null 2>&1; then
    echo "skillspector-scan: unavailable: '$bin' not found (install only in a throwaway sandbox or the test VM)" >&2
    exit 3
fi

offline=0
netdeny=()
if [ "${SKILLSPECTOR_OFFLINE-}" = "1" ] && [ "$full" = "1" ]; then
    echo "skillspector-scan: refused: SKILLSPECTOR_OFFLINE=1 denies the network, and Stage 2 (provider ${SKILLSPECTOR_PROVIDER}) needs it" >&2
    exit 2
fi
if [ "${SKILLSPECTOR_OFFLINE-}" = "1" ]; then
    offline=1
    netdeny=(unshare --user --map-root-user --net --)
    if ! "${netdeny[@]}" true >/dev/null 2>&1; then
        echo "skillspector-scan: refused: SKILLSPECTOR_OFFLINE=1 but the network cannot be denied here (needs unshare with unprivileged user namespaces)" >&2
        exit 2
    fi
fi

out="$(mktemp "${TMPDIR:-/tmp}/skillspector-scan.XXXXXX")" || exit 3
errf="$(mktemp "${TMPDIR:-/tmp}/skillspector-scan.err.XXXXXX")" || exit 3
trap 'rm -f "$out" "$out.full" "$errf"' EXIT

# rc 1 is skillspector's HIGH-finding exit, so the report decides there; any
# other non-zero rc is a crash and never yields a stored report.
llmflag=(--no-llm)
[ "$full" = "1" ] && llmflag=()
"${netdeny[@]+"${netdeny[@]}"}" "$bin" scan "$skill_dir" "${llmflag[@]+"${llmflag[@]}"}" --format json > "$out" 2> "$errf"
scan_rc=$?
if [ "$full" = "1" ]; then
    node -e '
const fs = require("fs");
let err = fs.readFileSync(process.argv[1], "utf8");
for (const k of [process.env.NVIDIA_INFERENCE_KEY, process.env.ANTHROPIC_API_KEY]) if (k) err = err.split(k).join("[redacted]");
fs.writeFileSync(process.argv[1], err);
' "$errf" || exit 3
fi
if [ "$scan_rc" -ne 0 ] && [ "$scan_rc" -ne 1 ]; then
    echo "skillspector-scan: unavailable: skillspector failed (rc $scan_rc)" >&2
    [ "$full" = "1" ] && head -c 2000 "$errf" >&2
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
if (process.argv[3] === "1" && !(r.metadata && r.metadata.meta_analysis_applied === true)) process.exit(1);
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
' "$out" "$offline" "$full" 2>/dev/null)" || summary=""
if [ -z "$summary" ]; then
    echo "skillspector-scan: unavailable: skillspector produced no complete scan report (need risk_assessment.score, an issues array, no failed or incomplete run, and for the full scan a Stage 2 that ran)" >&2
    if [ "$full" = "1" ]; then
        node -e '
try { const m = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")).metadata || {};
  if (m.llm_error) console.error("skillspector-scan: scanner says: " + String(m.llm_error).slice(0, 500)); } catch (e) {}
' "$out"
        head -c 2000 "$errf" >&2
    fi
    exit 3
fi

if [ -L "$report" ]; then
    echo "skillspector-scan: unavailable: report destination is a symlink: $report" >&2
    exit 3
fi
if [ "$full" = "1" ]; then
    node -e '
const fs = require("fs");
const r = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
r.wrapper_stderr = fs.readFileSync(process.argv[2], "utf8");
fs.writeFileSync(process.argv[3], JSON.stringify(r, null, 2) + "\n");
' "$out" "$errf" "$out.full" || exit 3
    mv "$out.full" "$out" || exit 3
fi
cp "$out" "$report" || exit 3
echo "skillspector-scan: report stored at $report"
echo "skillspector-scan: $summary (advisory: read each flagged line before adopting or using)"
if [ "$full" = "1" ]; then
    unacked="$(node -e '
const fs = require("fs");
const r = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
let ack = [];
try { ack = fs.readFileSync(process.argv[2], "utf8").split("\n").map((l) => l.trim()).filter(Boolean); } catch (e) {}
for (const i of r.issues) {
    if (i.severity !== "HIGH" && i.severity !== "CRITICAL") continue;
    const fp = typeof i.match_fingerprint === "string" ? i.match_fingerprint : "";
    if (fp && ack.includes(fp)) continue;
    const loc = i.location || {};
    console.log(i.severity + " " + String(loc.file) + ":" + String(loc.start_line) + " " + String(i.pattern) + " fingerprint=" + (fp || "none"));
}
' "$report" "$report.ack" 2>/dev/null)" || unacked="unreadable report"
    if [ -n "$unacked" ]; then
        echo "skillspector-scan: BLOCKED: Stage 2 confirmed a HIGH finding. Read each flagged line in $report, then record its fingerprint, one per line, in $report.ack and run the scan again:" >&2
        printf '%s\n' "$unacked" >&2
        exit 4
    fi
fi
