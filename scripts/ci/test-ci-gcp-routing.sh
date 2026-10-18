#!/usr/bin/env bash
# scripts/ci/test-ci-gcp-routing.sh -- regression suite: the shell-unit-shard
# runs-on expression in ci.yml resolves to the ephemeral GCP runner
# [self-hosted, gcp] only when repo variable CI_GCP is 'on', the event is a
# workflow_dispatch or a same-repo pull_request, and the actor, the triggering
# actor and (for a PR) the author are operator accounts. The repo is public: a fork
# PR or any other author must never reach a self-hosted runner, and the switch off must always fall back to the
# GitHub-hosted matrix.os, so an empty pool can never wedge CI.
#
# The expression is EVALUATED (python3 translation of the GitHub expression
# subset ci.yml uses), not pattern-matched, so a flipped && or || fails here.
# Context fixtures use the field values a real run carries (repository
# yotamleo/Himmel; a fork PR's head.repo.full_name differs).
#
# Usage: bash scripts/ci/test-ci-gcp-routing.sh
# Exit codes: 0 -- all cases passed; 1 -- at least one failed.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CI_YML="${CI_YML:-$ROOT/.github/workflows/ci.yml}"
fails=0
ok()  { echo "ok - $1"; }
bad() { echo "FAIL - $1" >&2; fails=$((fails + 1)); }

stripped="$(sed -e '/^[[:space:]]*#/d' -e 's/[[:space:]][[:space:]]*#.*$//' "$CI_YML")"
blk="$(awk '$0 == "  shell-unit-shard:" {f=1; next} f && /^  [a-zA-Z_-]+:/ {f=0} f' <<< "$stripped")"
runs_on="$(sed -n 's/^[[:space:]]*runs-on:[[:space:]]*//p' <<< "$blk")"

# resolve <event> <head_repo> <ci_gcp> <vm_runner> -> JSON of the runs-on value;
# ACTOR, TACTOR (triggering actor) and AUTHOR (PR author) default to the operator.
resolve() {
    python3 -I - "$runs_on" "$1" "$2" "$3" "$4" <<'PY'
import json, os, re, sys
expr, event, head, ci_gcp, vm = sys.argv[1:6]
class C(dict):
    def __getattr__(self, k): return self.get(k, "")
def wrap(d): return C({k: wrap(v) if isinstance(v, dict) else v for k, v in d.items()})
ctx = wrap({
    "github": {"event_name": event, "repository": "yotamleo/Himmel", "actor": os.environ.get("ACTOR", "yotamleo"),
               "triggering_actor": os.environ.get("TACTOR", "yotamleo"),
               "event": {"pull_request": {"head": {"repo": {"full_name": head}},
                                          "user": {"login": os.environ.get("AUTHOR", "yotamleo")}}}},
    "vars": {"CI_GCP": ci_gcp, "HIMMEL_VM_RUNNER": vm},
    "matrix": {"os": "ubuntu-latest"},
})
body = re.fullmatch(r"\$\{\{\s*(.*?)\s*\}\}", expr).group(1)
body = body.replace("&&", " and ").replace("||", " or ")
body = re.sub(r"\bfromJSON\(", "json.loads(", body)
env = {"json": json, "contains": lambda a, b: b in a, **ctx}
print(json.dumps(eval(body, {"__builtins__": {}}, env)))
PY
}

GCP='["self-hosted", "gcp"]'
HOSTED='"ubuntu-latest"'
chk() { # <label> <want> <event> <head> <ci_gcp> <vm>
    got="$(resolve "$3" "$4" "$5" "$6" 2>&1)"
    if [ "$got" = "$2" ]; then ok "$1"; else bad "$1: want $2 got $got"; fi
}

if [ -n "$runs_on" ] && [ "$(wc -l <<< "$runs_on")" -eq 1 ]; then ok "shell-unit-shard has exactly one runs-on"; else bad "runs-on missing or repeated"; fi

chk "same-repo PR, CI_GCP on -> gcp"          "$GCP"    pull_request yotamleo/Himmel on  ""
chk "push (no such trigger), CI_GCP on -> hosted" "$HOSTED" push     ""              on  ""
chk "fork PR, CI_GCP on -> hosted"            "$HOSTED" pull_request someone/Himmel  on  ""
chk "same-repo PR, CI_GCP off -> hosted"      "$HOSTED" pull_request yotamleo/Himmel off ""
chk "same-repo PR, CI_GCP unset -> hosted"    "$HOSTED" pull_request yotamleo/Himmel ""  ""
chk "push, CI_GCP off -> hosted"              "$HOSTED" push         ""              off ""
chk "schedule, CI_GCP on -> hosted"           "$HOSTED" schedule     ""              on  ""
chk "workflow_dispatch, CI_GCP on -> gcp"     "$GCP"    workflow_dispatch "" on ""
chk "fork PR, CI_GCP on, VM switch on -> hosted" "$HOSTED" pull_request someone/Himmel on on

# Actor gate: the same three conjunctions as the VM-runner branch.
export AUTHOR=someone
chk "same-repo PR by a non-operator author, CI_GCP on -> hosted" "$HOSTED" pull_request yotamleo/Himmel on ""
unset AUTHOR
export ACTOR=someone
chk "same-repo PR pushed by a non-operator actor, CI_GCP on -> hosted" "$HOSTED" pull_request yotamleo/Himmel on ""
chk "workflow_dispatch by a non-operator, CI_GCP on -> hosted" "$HOSTED" workflow_dispatch "" on ""
unset ACTOR
export TACTOR=someone
chk "same-repo PR re-run by a non-operator, CI_GCP on -> hosted" "$HOSTED" pull_request yotamleo/Himmel on ""
chk "workflow_dispatch re-run by a non-operator, CI_GCP on -> hosted" "$HOSTED" workflow_dispatch "" on ""
unset TACTOR
ACTOR=yotamleo11-test TACTOR=yotamleo11-test chk "workflow_dispatch by the second operator account, CI_GCP on -> gcp" "$GCP" workflow_dispatch "" on ""

if grep -q 'pull_request_target' <<< "$stripped"; then bad "ci.yml uses pull_request_target"; else ok "ci.yml never uses pull_request_target"; fi

if [ "$fails" -eq 0 ]; then echo "PASS: $0"; exit 0; fi
echo "FAILED: $fails case(s)" >&2
exit 1
