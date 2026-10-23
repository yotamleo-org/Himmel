#!/usr/bin/env bash
# snyk-scan.sh — scan the himmel checkout with the Snyk CLI (Open Source + Code),
# write the raw JSON plus a short summary into the state repo, and exit 1 on any
# High or Critical finding.
#
#   snyk-scan.sh [--repo <path>] [--out-dir <dir>] [--date YYYY-MM-DD]
#   snyk-scan.sh --check          preflight only: prints OK or WARN, always exits 0
#
# Output: <out-dir>/<date>.json (raw Open Source result array + raw Code SARIF +
# code_status) and <out-dir>/<date>.summary.md. --out-dir defaults to
# <handover root>/<user>/<bucket>/specs/security/snyk (the state repo bucket).
#
# Exit: 0 clean, 1 High/Critical found, 2 preflight/quota/scan failure.
#
# Preflight: snyk on PATH and `snyk whoami --experimental` succeeds. The token
# lives in snyk's own config; this script never reads it and never prints it.
#
# Open Source runs `snyk test --all-projects --json --severity-threshold=medium`
# (Low is noise at this scale); the High/Critical gate is this script's own count.
# A result that is not a project object (vulnerabilities array, no error key) exits 2.
# ponytail: no --fail-fast, because snyk then aborts on any manifest without installed dependencies (the baseline on main trips on marketplace/plugins/luna-correlate) and every weekly run would go red; a manifest snyk skips is counted in the project total only, upgrade path: compare the project count with the manifest estimate.
# Code runs `snyk code test --json` (SARIF; level error = High, warning = Medium).
# An org without Snyk Code reports `SKIPPED not-enabled` and does not fail the run.
#
# Quota: the free plan allows 400 Open Source, 100 Code, 300 IaC and 100
# Container tests per period (docs.snyk.io/snyk-platform-administration/
# groups-and-organizations/usage-settings). Open Source counts ONE TEST PER
# MANIFEST under --all-projects, Code one per repository
# (docs.snyk.io/working-with-snyk/what-counts-as-a-test), so the guard counts
# tests, not runs. It sums <state dir>/usage-YYYY-MM.tsv (date, product, tests)
# and refuses a run whose estimated tests would pass the cap. Caps default well
# below the free limits: SNYK_SCAN_OS_CAP=200, SNYK_SCAN_CODE_CAP=50.
#
# ponytail: the Open Source estimate is the number of tracked manifest dirs, an upper bound on what snyk counts; the ledger records the real project count after the run, upgrade path: read the live usage from the Snyk API.
#
# Seams (tests): SNYK_BIN, SNYK_SCAN_STATE_DIR, SNYK_SCAN_OUT_DIR, SNYK_SCAN_OS_CAP, SNYK_SCAN_CODE_CAP.
# Platform: Linux station (needs jq).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SNYK="${SNYK_BIN:-snyk}"
STATE_DIR="${SNYK_SCAN_STATE_DIR:-${HOME:-}/.himmel/state/snyk-scan}"
OS_CAP="${SNYK_SCAN_OS_CAP:-200}"
CODE_CAP="${SNYK_SCAN_CODE_CAP:-50}"
# directory names snyk must not walk: dependencies, test fixtures, other worktrees, generated graphs
EXCLUDES="node_modules,fixtures,worktrees,graphify-out,.venv"

err() { printf 'ERR snyk-scan: %s\n' "$*" >&2; }

repo="" out_dir="${SNYK_SCAN_OUT_DIR:-}" date_arg="" check=0
while [ $# -gt 0 ]; do
    case "$1" in
        --repo|--out-dir|--date)
            [ $# -ge 2 ] || { err "$1 needs a value"; exit 2; }
            case "$1" in --repo) repo="$2" ;; --out-dir) out_dir="$2" ;; --date) date_arg="$2" ;; esac
            shift 2 ;;
        --check) check=1; shift ;;
        *) err "unknown arg: $1"; exit 2 ;;
    esac
done

# preflight: sets PRE_MSG on failure. Never touches the token.
preflight() {
    if ! command -v "$SNYK" >/dev/null 2>&1 && [ ! -x "$SNYK" ]; then
        PRE_MSG="snyk not found on PATH (install the Snyk CLI, then run: snyk auth)"
        return 1
    fi
    if ! "$SNYK" whoami --experimental >/dev/null 2>&1; then
        PRE_MSG="snyk is not authenticated (run: snyk auth)"
        return 1
    fi
    return 0
}

if [ "$check" -eq 1 ]; then
    if preflight; then echo "OK snyk $("$SNYK" --version 2>/dev/null | head -n 1) authenticated"
    else echo "WARN snyk: $PRE_MSG"; fi
    exit 0
fi

command -v jq >/dev/null 2>&1 || { err "jq not found"; exit 2; }
preflight || { err "$PRE_MSG"; exit 2; }

if [ -z "$repo" ]; then
    common="$(git -C "$SCRIPT_DIR" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || { err "cannot resolve the repo"; exit 2; }
    repo="$(dirname "$common")"
fi
repo="$(cd "$repo" 2>/dev/null && pwd)" || { err "repo path does not exist"; exit 2; }
date="${date_arg:-$(date +%Y-%m-%d)}"
[[ "$date" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || { err "--date must be YYYY-MM-DD, got: $date"; exit 2; }
month="${date%-*}"

if [ -z "$out_dir" ]; then
    # shellcheck source=../lib/handover-path.sh
    . "$SCRIPT_DIR/../lib/handover-path.sh" 2>/dev/null || { err "cannot source handover-path.sh; pass --out-dir"; exit 2; }
    # shellcheck source=../lib/go-gate.sh
    . "$SCRIPT_DIR/../lib/go-gate.sh" 2>/dev/null || { err "cannot source go-gate.sh; pass --out-dir"; exit 2; }
    root="$(handover_root 2>/dev/null)" || { err "no handover root; pass --out-dir"; exit 2; }
    scope="$(go_verdict_scope "$repo")" || { err "cannot resolve the state-repo bucket; pass --out-dir"; exit 2; }
    out_dir="$root/$scope/specs/security/snyk"
fi

# --- quota guard --------------------------------------------------------------
usage_file="$STATE_DIR/usage-$month.tsv"
used() { # <product>
    [ -f "$usage_file" ] || { echo 0; return; }
    awk -F'\t' -v p="$1" '$2==p {s+=$3} END {print s+0}' "$usage_file"
}
# manifest dirs snyk --all-projects would count: tracked, outside the excluded dir names
est_os="$(git -C "$repo" ls-files 2>/dev/null \
    | grep -E '(^|/)(package\.json|package-lock\.json|yarn\.lock|pnpm-lock\.yaml|bun\.lock|requirements\.txt|Pipfile|pyproject\.toml|poetry\.lock|go\.mod|Gemfile\.lock)$' \
    | grep -Ev "(^|/)($(printf '%s' "$EXCLUDES" | tr ',' '|' | sed 's/\./\\./g'))/" \
    | xargs -r -n1 dirname | sort -u | wc -l | tr -d ' ')"
used_os="$(used open_source)"
if [ $((used_os + est_os)) -gt "$OS_CAP" ]; then
    err "monthly quota: $used_os Open Source tests used in $month plus about $est_os for this run would pass the cap of $OS_CAP (SNYK_SCAN_OS_CAP; free plan allows 400)"
    exit 2
fi

# fail closed: a ledger that cannot be written would let every run bypass the cap
if ! mkdir -p "$STATE_DIR" 2>/dev/null || [ ! -w "$STATE_DIR" ] || { [ -e "$usage_file" ] && [ ! -w "$usage_file" ]; }; then
    err "cannot write the usage ledger in $STATE_DIR; refusing to scan unmetered"
    exit 2
fi
usage_failed=0
record_usage() { # <product> <tests>
    printf '%s\t%s\t%s\n' "$date" "$1" "$2" >> "$usage_file" \
        || { err "cannot append to the usage ledger $usage_file"; usage_failed=1; }
}

# shellcheck source=../lib/prim.sh
. "$SCRIPT_DIR/../lib/prim.sh" 2>/dev/null || { err "cannot source prim.sh"; exit 2; }
tmp="$(tmpdir)" || { err "mktemp failed"; exit 2; }
trap 'rm -rf "$tmp"' EXIT

# --- Open Source ----------------------------------------------------------------
( cd "$repo" && "$SNYK" test --all-projects --json --severity-threshold=medium "--exclude=$EXCLUDES" ) > "$tmp/os.raw" 2> "$tmp/os.err"
os_rc=$?
case "$os_rc" in
    0|1) ;;
    3) printf '[]\n' > "$tmp/os.raw" ;;
    *) err "snyk test failed (rc $os_rc): $(head -c 300 "$tmp/os.err")$(head -c 300 "$tmp/os.raw")"; exit 2 ;;
esac
# a project result is an object with a vulnerabilities array and no error key; a per-project error entry or any other shape is a failed scan, never a clean one
jq -e 'def proj: type=="object" and ((.vulnerabilities | type) == "array") and (has("error") | not);
    if type=="array" then (if all(.[]; proj) then . else empty end) elif proj then [.] else empty end' "$tmp/os.raw" > "$tmp/os.json" 2>/dev/null \
    || { err "snyk test printed no usable project results (rc $os_rc)"; exit 2; }
os_projects="$(jq 'length' "$tmp/os.json")"
record_usage open_source "$os_projects"

# --- Code -----------------------------------------------------------------------
code_status="ok"
used_code="$(used code)"
if [ $((used_code + 1)) -gt "$CODE_CAP" ]; then
    code_status="quota"
    printf 'null\n' > "$tmp/code.json"
else
    ( cd "$repo" && "$SNYK" code test --json --severity-threshold=medium ) > "$tmp/code.raw" 2> "$tmp/code.err"
    code_rc=$?
    case "$code_rc" in
        0|1) if jq -e '.runs' "$tmp/code.raw" >/dev/null 2>&1; then
                 cp "$tmp/code.raw" "$tmp/code.json"; record_usage code 1
             else code_status="error"; printf 'null\n' > "$tmp/code.json"; fi ;;
        3) code_status="no-supported-files"; printf 'null\n' > "$tmp/code.json" ;;
        *) printf 'null\n' > "$tmp/code.json"
           if grep -qi 'not supported for your current organization' "$tmp/code.raw" "$tmp/code.err" 2>/dev/null; then code_status="not-enabled"
           else code_status="error"; fi ;;
    esac
fi

# --- results --------------------------------------------------------------------
head_sha="$(git -C "$repo" rev-parse HEAD 2>/dev/null || echo unknown)"
mkdir -p "$out_dir" || { err "cannot create $out_dir"; exit 2; }
jq -n --arg date "$date" --arg repo "$repo" --arg head "$head_sha" --arg code_status "$code_status" \
    --slurpfile os "$tmp/os.json" --slurpfile code "$tmp/code.json" \
    '{date:$date, repo:$repo, head:$head, code_status:$code_status, open_source:$os[0], code:$code[0]}' \
    > "$out_dir/$date.json" || { err "cannot write $out_dir/$date.json"; exit 2; }

# one row per distinct (project, vulnerability id, package@version)
os_rows="$(jq -r '.[] | (.displayTargetFile // .path) as $t | (.vulnerabilities // [])
    | unique_by(.id + "@" + (.packageName // "") + "@" + (.version // ""))[]
    | [.severity, .id, ((.packageName // "?") + "@" + (.version // "?")), .title, $t] | @tsv' "$tmp/os.json")" \
    || { err "cannot read the Open Source findings from $tmp/os.json"; exit 2; }
code_rows="$(jq -r '(.runs // [])[]? | .results[]? | select(.level == "error" or .level == "warning")
    | [(if .level == "error" then "high" else "medium" end), .ruleId, (.locations[0].physicalLocation.artifactLocation.uri // "?") + ":" + ((.locations[0].physicalLocation.region.startLine // 0) | tostring), (.message.text // "")] | @tsv' "$tmp/code.json")" \
    || { err "cannot read the Code findings from $tmp/code.json"; exit 2; }

count() { # <rows> <severity>
    printf '%s\n' "$1" | awk -F'\t' -v s="$2" '$1==s {n++} END {print n+0}'
}
os_crit="$(count "$os_rows" critical)"; os_high="$(count "$os_rows" high)"
os_med="$(count "$os_rows" medium)"; os_low="$(count "$os_rows" low)"
code_high="$(count "$code_rows" high)"; code_med="$(count "$code_rows" medium)"
gate=$((os_crit + os_high + code_high))

{
    printf '# Snyk scan %s\n\n' "$date"
    printf -- '- repo head: %s\n- Open Source projects scanned: %s\n- quota this month (%s): %s of %s Open Source tests, %s of %s Code tests\n\n' \
        "$head_sha" "$os_projects" "$month" "$(used open_source)" "$OS_CAP" "$(used code)" "$CODE_CAP"
    printf '## Open Source\n\n- critical: %s\n- high: %s\n- medium: %s\n- low: %s\n\n' "$os_crit" "$os_high" "$os_med" "$os_low"
    printf '## Code\n\n'
    case "$code_status" in
        ok) printf -- '- high: %s\n- medium: %s\n\n' "$code_high" "$code_med" ;;
        not-enabled) printf 'SKIPPED not-enabled: Snyk Code is off for this org; enable it in the Snyk org settings.\n\n' ;;
        quota) printf 'SKIPPED quota: the monthly Code cap of %s tests is reached.\n\n' "$CODE_CAP" ;;
        no-supported-files) printf 'SKIPPED no-supported-files: Snyk Code found nothing it can scan.\n\n' ;;
        *) printf 'ERROR: snyk code test failed or printed no SARIF.\n\n' ;;
    esac
    if [ "$gate" -gt 0 ]; then
        printf '## High and Critical findings\n\n'
        printf '%s\n' "$os_rows" | awk -F'\t' '$1=="critical"||$1=="high" {printf "- [%s] %s %s — %s (%s)\n", $1, $2, $3, $4, $5}'
        printf '%s\n' "$code_rows" | awk -F'\t' '$1=="high" {printf "- [code high] %s %s — %s\n", $2, $3, $4}'
    fi
} > "$out_dir/$date.summary.md" || { err "cannot write the summary"; exit 2; }

echo "snyk-scan: $os_projects projects, open source critical=$os_crit high=$os_high; code $code_status high=$code_high -> $out_dir/$date.summary.md"
[ "$gate" -eq 0 ] || exit 1
# an incomplete scan is never a clean pass: a Code skip (not-enabled, quota, no files) is intended, an error is not
if [ "$code_status" = error ] || [ "$usage_failed" -ne 0 ]; then exit 2; fi
exit 0
