#!/usr/bin/env bash
# snyk-scan.sh — scan the himmel checkout with the Snyk CLI (Open Source + Code),
# write the raw JSON plus a short summary into the state repo, and exit 1 on any
# High or Critical finding.
#
#   snyk-scan.sh [--repo <path>] [--out-dir <dir>] [--date YYYY-MM-DD]
#   snyk-scan.sh --forks [...]    scan the forks himmel vendors or pins instead of the checkout
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
# Forks mode (--forks): shallow-fetches each fork at the ref himmel pins (qmd and graphify from
# scripts/lib/*-bin.sh, claude-hud from scripts/upstreams.json, obsidian-second-brain and
# claude-obsidian from marketplace.json) into a scratch dir, runs the Open Source scan on it and
# writes <date>.forks.json plus <date>.forks.summary.md with one section per fork. A fork that
# tracks its upstream also gets a scan of the upstream default branch, and each finding is
# marked fixed upstream or not. Exit 1 on any High or Critical; exit 2 when a pin cannot be read, a
# fork cannot be fetched or scanned (snyk failed, uv missing, osv.dev unreachable), the monthly quota
# would be passed, or the usage ledger cannot be written; exit 0 otherwise. The other forks still run.
# Snyk (1.1308.2) cannot read uv.lock ("Could not detect package manager"), and its pip scan needs
# the packages installed; a uv.lock is exported with `uv export` and looked up on osv.dev instead.
# ponytail: osv.dev findings carry the advisory's own severity (GHSA database_specific, unrated = medium) and no reachability, upgrade path: osv-scanner or a Snyk uv.lock parser once released.
#
# Seams (tests): SNYK_BIN, SNYK_SCAN_STATE_DIR, SNYK_SCAN_OUT_DIR, SNYK_SCAN_OS_CAP, SNYK_SCAN_CODE_CAP,
# SNYK_SCAN_FORKS (rows `name|repo-url|ref|up-or-dash` replacing the pin table), SNYK_SCAN_OSV_URL,
# SNYK_SCAN_UV (the uv binary).
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

repo="" out_dir="${SNYK_SCAN_OUT_DIR:-}" date_arg="" check=0 forks=0
while [ $# -gt 0 ]; do
    case "$1" in
        --repo|--out-dir|--date)
            [ $# -ge 2 ] || { err "$1 needs a value"; exit 2; }
            case "$1" in --repo) repo="$2" ;; --out-dir) out_dir="$2" ;; --date) date_arg="$2" ;; esac
            shift 2 ;;
        --check) check=1; shift ;;
        --forks) forks=1; shift ;;
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
EXCL_RE="(^|/)($(printf '%s' "$EXCLUDES" | tr ',' '|' | sed 's/\./\\./g'))/"
# manifest dirs snyk --all-projects would count: tracked, outside the excluded dir names
manifest_dirs() { # <tree>
    git -C "$1" ls-files 2>/dev/null \
        | grep -E '(^|/)(package\.json|package-lock\.json|yarn\.lock|pnpm-lock\.yaml|bun\.lock|requirements\.txt|Pipfile|pyproject\.toml|poetry\.lock|go\.mod|Gemfile\.lock)$' \
        | grep -Ev "$EXCL_RE" \
        | xargs -r -n1 dirname | sort -u | wc -l | tr -d ' '
}
est_os="$(manifest_dirs "$repo")"
used_os="$(used open_source)"
if [ "$forks" -eq 0 ] && [ $((used_os + est_os)) -gt "$OS_CAP" ]; then
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

# a project result is an object with a vulnerabilities array and no error key; a per-project error entry or any other shape is a failed scan, never a clean one
PROJ_JQ='def proj: type=="object" and ((.vulnerabilities | type) == "array") and (has("error") | not);
    if type=="array" then (if all(.[]; proj) then . else empty end) elif proj then [.] else empty end'
# one row per distinct (project, vulnerability id, package@version)
# shellcheck disable=SC2016  # jq program: $t is a jq variable
ROWS_JQ='.[] | (.displayTargetFile // .path) as $t | (.vulnerabilities // [])
    | unique_by(.id + "@" + (.packageName // "") + "@" + (.version // ""))[]
    | [.severity, .id, ((.packageName // "?") + "@" + (.version // "?")), .title, $t] | @tsv'
count() { # <rows> <severity>
    printf '%s\n' "$1" | awk -F'\t' -v s="$2" '$1==s {n++} END {print n+0}'
}

# --- Forks ----------------------------------------------------------------------
if [ "$forks" -eq 1 ]; then
    UV="${SNYK_SCAN_UV:-uv}"
    OSV_URL="${SNYK_SCAN_OSV_URL:-https://api.osv.dev}"
    SCAN_MSG="" SCAN_PROJECTS=0 SCAN_LOCKS=0

    # name|repo-url|ref|up (also scan the upstream default branch) or - (the fork carries the delta)
    fork_table() {
        local qurl qref gref href sref cref
        qurl="$(sed -n 's/^_qmd_fork_repo().*:-\([^}]*\)}.*/\1/p' "$repo/scripts/lib/qmd-bin.sh" 2>/dev/null)"
        qref="$(sed -n 's/^_qmd_fork_ref().*:-\([0-9a-f]\{40\}\)}.*/\1/p' "$repo/scripts/lib/qmd-bin.sh" 2>/dev/null)"
        gref="$(sed -n 's/^_graphify_fork_ref().*:-\([0-9a-f]\{40\}\)}.*/\1/p' "$repo/scripts/lib/graphify-bin.sh" 2>/dev/null)"
        href="$(jq -r '.entries[] | select(.name=="claude-hud") | .pinned_commit // empty' "$repo/scripts/upstreams.json" 2>/dev/null)"
        sref="$(jq -r '.plugins[] | select(.name=="obsidian-second-brain") | .source.sha // empty' "$repo/marketplace/.claude-plugin/marketplace.json" 2>/dev/null)"
        cref="$(jq -r '.plugins[] | select(.name=="claude-obsidian") | .source.ref // empty' "$repo/marketplace/.claude-plugin/marketplace.json" 2>/dev/null)"
        local pair
        for pair in "qmd:$qurl" "qmd:$qref" "graphify:$gref" "claude-hud:$href" "obsidian-second-brain:$sref" "claude-obsidian:$cref"; do
            [ -n "${pair#*:}" ] || { err "cannot read the ${pair%%:*} pin under $repo"; return 1; }
        done
        printf 'qmd|%s|%s|-\n' "$qurl" "$qref"
        printf 'graphify|https://github.com/yotamleo-org/graphify|%s|-\n' "$gref" # env-literal-ok: the fork's own identity, scan target
        printf 'claude-hud|https://github.com/jarrodwatts/claude-hud|%s|up\n' "$href"
        printf 'obsidian-second-brain|https://github.com/eugeniughelbur/obsidian-second-brain|%s|up\n' "$sref"
        printf 'claude-obsidian|https://github.com/AgriciDaniel/claude-obsidian|%s|up\n' "$cref"
    }

    fetch_tree() { # <url> <ref> <dir>: shallow checkout of one ref
        if mkdir -p "$3" && git -C "$3" init -q 2>/dev/null \
            && git -C "$3" fetch -q --depth 1 "$1" "$2" > "$tmp/git.err" 2>&1 < /dev/null \
            && git -C "$3" checkout -q FETCH_HEAD >> "$tmp/git.err" 2>&1 < /dev/null; then
            return 0
        fi
        SCAN_MSG="cannot fetch $2 from $1: $(head -c 200 "$tmp/git.err")"
        return 1
    }

    # osv.dev findings for one uv.lock, as the same rows snyk prints
    uv_rows() { # <tree> <lock path>
        local d="$1" lock="$2" w="$tmp/osv" id
        command -v "$UV" >/dev/null 2>&1 || [ -x "$UV" ] || { SCAN_MSG="uv not found, cannot read $lock"; return 1; }
        rm -rf "$w"; mkdir -p "$w"
        ( cd "$d/$(dirname "$lock")" && "$UV" export --frozen --no-hashes --no-annotate --no-header --no-emit-project --no-dev --all-extras --format requirements-txt ) \
            > "$w/req.txt" 2> "$w/uv.err" < /dev/null \
            || { SCAN_MSG="uv export failed for $lock: $(head -c 200 "$w/uv.err")"; return 1; }
        sed 's/ *;.*//' "$w/req.txt" | jq -Rn '[inputs | select(test("^[A-Za-z0-9._-]+==")) | split("==") | {package: {name: .[0], ecosystem: "PyPI"}, version: .[1]}] | unique | {queries: .}' > "$w/q.json" \
            || { SCAN_MSG="cannot read the uv export of $lock"; return 1; }
        jq -e '.queries | length > 0' "$w/q.json" >/dev/null || return 0
        if ! { curl -fsS -m 120 -X POST -H 'Content-Type: application/json' -d @"$w/q.json" "$OSV_URL/v1/querybatch" > "$w/batch.json" 2> "$w/curl.err" \
            && jq -e --slurpfile q "$w/q.json" '(.results | type == "array") and (.results | length) == ($q[0].queries | length)
                and all(.results[]; type == "object" and (has("next_page_token") | not))' "$w/batch.json" >/dev/null 2>&1; }; then
            SCAN_MSG="osv.dev querybatch failed, was paged or incomplete for $lock: $(head -c 200 "$w/curl.err")"
            return 1
        fi
        jq -r --slurpfile q "$w/q.json" '.results | to_entries[] | .key as $i | (.value.vulns // [])[] | [.id, $q[0].queries[$i].package.name, $q[0].queries[$i].version] | @tsv' "$w/batch.json" > "$w/pairs.tsv" \
            || { SCAN_MSG="cannot read the osv.dev answer for $lock"; return 1; }
        [ -s "$w/pairs.tsv" ] || return 0
        cut -f1 "$w/pairs.tsv" | sort -u > "$w/ids.txt"
        while IFS= read -r id; do
            [[ "$id" =~ ^[A-Za-z0-9._-]+$ ]] || { SCAN_MSG="osv.dev returned an unusable advisory id for $lock"; return 1; }
            curl -fsS -m 60 "$OSV_URL/v1/vulns/$id" > "$w/v-$id.json" 2> "$w/curl.err" \
                || { SCAN_MSG="osv.dev advisory $id failed: $(head -c 200 "$w/curl.err")"; return 1; }
        done < "$w/ids.txt"
        jq -s '.' "$w"/v-*.json > "$w/vulns.json" || { SCAN_MSG="cannot read the osv.dev advisories for $lock"; return 1; }
        # prefer the GHSA id of an advisory group, keep its highest severity, drop Low like the snyk run does
        jq -rn --arg t "$lock" --rawfile p "$w/pairs.tsv" --slurpfile v "$w/vulns.json" '
            def rank: {"critical": 3, "high": 2, "medium": 1}[.];
            ($v[0] | map({(.id): .}) | add // {}) as $m
            | [$p | split("\n")[] | select(length > 0) | split("\t") | . as [$id, $n, $ver]
                | ($m[$id] // {}) as $d
                | ((([$d.id] + ($d.aliases // [])) | map(select(. != null)) | (map(select(startswith("GHSA-"))) + .)) | first // $id) as $key
                | (($d.database_specific.severity // "") | ascii_downcase | if . == "moderate" then "medium" elif IN("critical", "high", "medium", "low") then . else "medium" end) as $sev
                | select($sev != "low")
                | [$sev, $key, ($n + "@" + $ver), ($d.summary // "?"), $t]]
            | group_by(.[1] + "|" + .[2]) | map(max_by(.[0] | rank))[] | @tsv'
    }

    # Open Source scan of one checkout; rows to <rows file>. rc 1 = scan failed (SCAN_MSG), 3 = quota or unwritable ledger, stops the run
    scan_tree() { # <dir> <rows file>
        local d="$1" rows="$2" rc est lock
        : > "$rows"; SCAN_MSG=""; SCAN_PROJECTS=0; SCAN_LOCKS=0
        est="$(manifest_dirs "$d")"
        if [ $(($(used open_source) + est)) -gt "$OS_CAP" ]; then
            SCAN_MSG="monthly quota: $(used open_source) Open Source tests used in $month plus about $est for $d would pass the cap of $OS_CAP (SNYK_SCAN_OS_CAP; free plan allows 400)"
            return 3
        fi
        ( cd "$d" && "$SNYK" test --all-projects --json --severity-threshold=medium "--exclude=$EXCLUDES" ) > "$tmp/ft.raw" 2> "$tmp/ft.err" < /dev/null
        rc=$?
        case "$rc" in
            0|1) ;;
            3) printf '[]\n' > "$tmp/ft.raw" ;;
            *) SCAN_MSG="snyk test failed (rc $rc): $(head -c 200 "$tmp/ft.err")$(head -c 200 "$tmp/ft.raw")"; return 1 ;;
        esac
        jq -e "$PROJ_JQ" "$tmp/ft.raw" > "$tmp/ft.json" 2>/dev/null || { SCAN_MSG="snyk test printed no usable project results (rc $rc)"; return 1; }
        SCAN_PROJECTS="$(jq 'length' "$tmp/ft.json")"
        record_usage open_source "$SCAN_PROJECTS"
        [ "$usage_failed" -eq 0 ] || { SCAN_MSG="usage ledger write failed; not scanning on unmetered"; return 3; }
        jq -r "$ROWS_JQ" "$tmp/ft.json" >> "$rows" || { SCAN_MSG="cannot read the Open Source findings"; return 1; }
        while IFS= read -r lock; do
            [ -n "$lock" ] || continue
            SCAN_LOCKS=$((SCAN_LOCKS + 1))
            uv_rows "$d" "$lock" >> "$rows" || return 1
        done < <(git -C "$d" ls-files 2>/dev/null | grep -E '(^|/)uv\.lock$' | grep -Ev "$EXCL_RE")
        return 0
    }

    # <rows> <upstream rows> <none|scanned|error>: add a fixed-upstream column (yes, no, n/a, unknown)
    mark_fixed() {
        awk -F'\t' -v OFS='\t' -v st="$3" '
            FILENAME == ARGV[1] { p = $3; sub(/@[^@]*$/, "", p); up[$2 "\t" p] = 1; next }
            { p = $3; sub(/@[^@]*$/, "", p)
              print $0, (st == "none" ? "n/a" : (st == "error" ? "unknown" : (($2 "\t" p) in up ? "no" : "yes"))) }' "$2" "$1"
    }

    if [ -n "${SNYK_SCAN_FORKS:-}" ]; then table="$SNYK_SCAN_FORKS"; else table="$(fork_table)" || exit 2; fi
    : > "$tmp/forks.jsonl"; : > "$tmp/forks.md"
    f_gate=0 f_err=0 f_n=0
    while IFS='|' read -r -u 3 name url ref up; do
        [ -n "$name" ] || continue
        f_n=$((f_n + 1))
        status=ok msg="" projects=0 locks=0 upstream=none up_sha=""
        : > "$tmp/rows.$name"; : > "$tmp/uprows.$name"
        if ! fetch_tree "$url" "$ref" "$tmp/fork-$name"; then
            status=error msg="$SCAN_MSG"
        else
            scan_tree "$tmp/fork-$name" "$tmp/rows.$name"; rc=$?
            projects=$SCAN_PROJECTS locks=$SCAN_LOCKS
            case "$rc" in
                0) ;;
                3) err "$SCAN_MSG"; exit 2 ;;
                *) status=error msg="$SCAN_MSG" ;;
            esac
            if [ "$status" = ok ] && [ "$up" = up ]; then
                upstream=error
                if fetch_tree "$url" HEAD "$tmp/up-$name"; then
                    scan_tree "$tmp/up-$name" "$tmp/uprows.$name"; rc=$?
                    case "$rc" in
                        0) upstream=scanned; up_sha="$(git -C "$tmp/up-$name" rev-parse HEAD 2>/dev/null)" ;;
                        3) err "$SCAN_MSG"; exit 2 ;;
                        *) msg="upstream scan failed: $SCAN_MSG" ;;
                    esac
                else msg="upstream fetch failed: $SCAN_MSG"; fi
                [ "$upstream" = scanned ] || status=error
            fi
        fi
        [ "$status" = ok ] || f_err=$((f_err + 1))
        mark_fixed "$tmp/rows.$name" "$tmp/uprows.$name" "$upstream" > "$tmp/marked.$name"
        rows="$(cat "$tmp/rows.$name")"
        crit="$(count "$rows" critical)"; high="$(count "$rows" high)"; med="$(count "$rows" medium)"
        f_gate=$((f_gate + crit + high))
        jq -Rn --arg name "$name" --arg repo "$url" --arg ref "$ref" --arg status "$status" --arg message "$msg" \
            --arg upstream "$upstream" --arg up_sha "$up_sha" --argjson projects "$projects" --argjson locks "$locks" \
            '{name: $name, repo: $repo, ref: $ref, status: $status, message: $message, projects: $projects, uv_locks: $locks, upstream: $upstream, upstream_head: $up_sha,
              findings: [inputs | split("\t") | {severity: .[0], id: .[1], package: .[2], title: .[3], target: .[4], fixed_upstream: .[5]}]}' \
            < "$tmp/marked.$name" >> "$tmp/forks.jsonl" || { err "cannot build the JSON for $name"; exit 2; }
        {
            printf '## %s\n\n- repo: %s @ %s\n- status: %s%s\n- Open Source projects scanned: %s, uv.lock files checked on osv.dev: %s\n' \
                "$name" "$url" "$ref" "$status" "${msg:+ ($msg)}" "$projects" "$locks"
            case "$upstream" in
                scanned) printf -- '- upstream default branch scanned at %s\n' "$up_sha" ;;
                error) printf -- '- upstream default branch: scan failed, fixed-upstream column unknown\n' ;;
                *) printf -- '- upstream: not compared (this fork carries the delta)\n' ;;
            esac
            printf -- '- critical: %s\n- high: %s\n- medium: %s\n\n' "$crit" "$high" "$med"
            if [ $((crit + high)) -gt 0 ]; then
                printf '### High and Critical findings\n\n'
                awk -F'\t' '$1=="critical"||$1=="high" {printf "- [%s] %s %s — %s (%s) — fixed upstream: %s\n", $1, $2, $3, $4, $5, $6}' "$tmp/marked.$name"
                printf '\n'
            fi
        } >> "$tmp/forks.md"
    done 3<<< "$table"

    mkdir -p "$out_dir" || { err "cannot create $out_dir"; exit 2; }
    jq -s '.' "$tmp/forks.jsonl" > "$out_dir/$date.forks.json" || { err "cannot write $out_dir/$date.forks.json"; exit 2; }
    {
        printf '# Snyk forks scan %s\n\n' "$date"
        printf -- '- forks scanned: %s, failed: %s\n- quota this month (%s): %s of %s Open Source tests\n\n' "$f_n" "$f_err" "$month" "$(used open_source)" "$OS_CAP"
        cat "$tmp/forks.md"
    } > "$out_dir/$date.forks.summary.md" || { err "cannot write the forks summary"; exit 2; }
    echo "snyk-scan: $f_n forks, high or critical=$f_gate, failed=$f_err -> $out_dir/$date.forks.summary.md"
    [ "$f_gate" -eq 0 ] || exit 1
    if [ "$f_err" -ne 0 ] || [ "$usage_failed" -ne 0 ]; then exit 2; fi
    exit 0
fi

# --- Open Source ----------------------------------------------------------------
( cd "$repo" && "$SNYK" test --all-projects --json --severity-threshold=medium "--exclude=$EXCLUDES" ) > "$tmp/os.raw" 2> "$tmp/os.err"
os_rc=$?
case "$os_rc" in
    0|1) ;;
    3) printf '[]\n' > "$tmp/os.raw" ;;
    *) err "snyk test failed (rc $os_rc): $(head -c 300 "$tmp/os.err")$(head -c 300 "$tmp/os.raw")"; exit 2 ;;
esac
# a project result is an object with a vulnerabilities array and no error key; a per-project error entry or any other shape is a failed scan, never a clean one
jq -e "$PROJ_JQ" "$tmp/os.raw" > "$tmp/os.json" 2>/dev/null \
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
os_rows="$(jq -r "$ROWS_JQ" "$tmp/os.json")" \
    || { err "cannot read the Open Source findings from $tmp/os.json"; exit 2; }
code_rows="$(jq -r '(.runs // [])[]? | .results[]? | select(.level == "error" or .level == "warning")
    | [(if .level == "error" then "high" else "medium" end), .ruleId, (.locations[0].physicalLocation.artifactLocation.uri // "?") + ":" + ((.locations[0].physicalLocation.region.startLine // 0) | tostring), (.message.text // "")] | @tsv' "$tmp/code.json")" \
    || { err "cannot read the Code findings from $tmp/code.json"; exit 2; }

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
