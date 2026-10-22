#!/usr/bin/env bash
# scripts/ci/lint-required-check-cancel.sh -- a workflow that provides a required
# check must not let one run replace another that nothing re-triggers.
#
# A cancelled run leaves a CANCELLED context behind. GitHub's merge gate wants the
# required context green, so a superseded run is only harmless when a later run
# posts the SAME context on the SAME head. Two ways that fails, both recorded in
# scripts/ci/check-run-timelines/testdata/:
#   cancel   a concurrency group with cancel-in-progress that can be true, on a
#            workflow whose cancelled run is not on a stale head (recorded in
#            3588-pr1226-cancelled-contexts: PR 1226 sat BLOCKED on three CANCELLED
#            codeowner-review-gate contexts while the latest runs were green). The one accepted shape is the
#            ci.yml one, cancel-in-progress: ${{ github.event_name == 'pull_request' }},
#            where a cancelled run only ever belongs to a superseded head.
#   shared   several triggering events share one concurrency group that carries
#            no github.event_name, so GitHub's single pending slot per group lets
#            a pull_request_review run replace the pending pull_request run, the
#            only one that satisfies the check (recorded in
#            6562-pr3194-review-event-expected: PR 3194 stayed Expected and BLOCKED).
#
# Usage: lint-required-check-cancel.sh --required FILE WORKFLOW.yml...
#   FILE   the rules/branches response (required_status_checks rules), or a text
#          file with one required context per line
# Exit: 0 clean; 1 at least one finding (printed as `path: kind: detail`);
#       2 usage, unreadable input or PyYAML missing.
set -uo pipefail

REQ=""
FILES=()
while [ "$#" -gt 0 ]; do
    case "$1" in
        --required) REQ="${2:-}"; shift 2 || { echo "usage: $0 --required FILE WORKFLOW.yml..." >&2; exit 2; } ;;
        -*) echo "usage: $0 --required FILE WORKFLOW.yml..." >&2; exit 2 ;;
        *) FILES[${#FILES[@]}]="$1"; shift ;;
    esac
done
if [ -z "$REQ" ] || [ "${#FILES[@]}" -eq 0 ]; then
    echo "usage: $0 --required FILE WORKFLOW.yml..." >&2
    exit 2
fi
[ -r "$REQ" ] || { echo "lint-required-check-cancel: cannot read $REQ" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "lint-required-check-cancel: python3 not found" >&2; exit 2; }
python3 -I -c 'import yaml' 2>/dev/null || { echo "lint-required-check-cancel: PyYAML missing" >&2; exit 2; }

python3 -I - "$REQ" "${FILES[@]}" <<'PY'
import json, re, sys, yaml

req_path, paths = sys.argv[1], sys.argv[2:]
raw = open(req_path).read()
try:
    rules = json.loads(raw)
    required = {c["context"] for r in rules if r.get("type") == "required_status_checks"
                for c in r.get("parameters", {}).get("required_status_checks", [])}
except (ValueError, AttributeError, TypeError):
    required = {l.strip() for l in raw.splitlines() if l.strip() and not l.lstrip().startswith("#")}

def provides(name):
    pat = re.escape(name)
    pat = re.sub(r"\\\$\\\{\\\{.*?\\\}\\\}", ".*", pat)
    return any(re.fullmatch(pat, c) for c in required)

def expr(s):
    s = str(s).strip()
    m = re.fullmatch(r"\$\{\{(.*)\}\}", s)
    return (m.group(1) if m else s).strip()

SAFE_CANCEL = "github.event_name == 'pull_request'"
findings = 0
for p in paths:
    try:
        doc = yaml.safe_load(open(p)) or {}
    except Exception as e:
        print(f"lint-required-check-cancel: cannot parse {p}: {e}", file=sys.stderr)
        sys.exit(2)
    on = doc.get(True, doc.get("on"))
    events = list(on) if isinstance(on, (dict, list)) else ([on] if on else [])
    jobs = doc.get("jobs") or {}
    providers = [k for k, j in jobs.items() if isinstance(j, dict)
                 and (provides(str(j.get("name", k))) or provides(k))]
    if not providers:
        continue
    scopes = [("workflow", doc.get("concurrency"))] + \
             [(f"job {k}", jobs[k].get("concurrency")) for k in providers]
    for label, c in scopes:
        if c is None:
            continue
        group, cip = (c, False) if isinstance(c, str) else (str(c.get("group", "")), c.get("cancel-in-progress", False))
        if not (cip is False or str(cip).strip().lower() == "false" or expr(cip) == SAFE_CANCEL):
            print(f"{p}: cancel: {label} concurrency cancel-in-progress={cip!r} can cancel a run of the required check(s) {', '.join(providers)}")
            findings += 1
        if len(events) > 1 and "github.event_name" not in group and "github.run_id" not in group:
            print(f"{p}: shared: {label} concurrency group {group!r} is shared by events {', '.join(map(str, events))}; a run of one replaces the pending run of another")
            findings += 1
sys.exit(1 if findings else 0)
PY
