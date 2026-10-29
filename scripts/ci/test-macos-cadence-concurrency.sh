#!/usr/bin/env bash
# scripts/ci/test-macos-cadence-concurrency.sh -- the concurrency
# group of .github/workflows/macos-cadence.yml carries the run mode, so a
# `suites` dispatch never queues behind a full run on the same ref (the audit
# saw 31-103 min waits), while two runs of one mode on one ref still queue.
# Parses the workflow with PyYAML (python3 -I, as lint-required-check-cancel.sh
# does). No network.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
WF="${WF:-$ROOT/.github/workflows/macos-cadence.yml}"
fails=0
ok()  { echo "ok - $1"; }
bad() { echo "FAIL - $1" >&2; fails=$((fails + 1)); }

# check_wf <workflow file>: prints one line per failed assertion, rc 1 if any.
# A `suites` input renders one group, an empty one another; the two must differ
# and both must still be per-ref. A ref-only group (main's) fails the mode test.
check_wf() {
  python3 -I - "$1" <<'PY'
import re, sys, yaml

doc = yaml.safe_load(open(sys.argv[1]))
conc = doc.get("concurrency")
group = str(conc.get("group", "")) if isinstance(conc, dict) else str(conc or "")
bad = []

def render(suites):
    out = group.replace("${{ github.ref }}", "refs/heads/b")
    def expr(m):
        cond, yes, no = m.group(1), m.group(2), m.group(3)
        return yes if (cond == "!=") == (suites != "") else no
    return re.sub(r"\$\{\{ inputs\.suites (!=|==) '' && '([^']*)' \|\| '([^']*)' \}\}", expr, out)

full, suites = render(""), render("a.sh b.sh")
if "${{" in full or "${{" in suites:
    bad.append("group has an expression this check cannot render: %r" % group)
if "refs/heads/b" not in full:
    bad.append("group is not per-ref: %r" % group)
if full == suites:
    bad.append("group is the same for a full and a suites run (%r): the mode is not in it" % full)
if isinstance(conc, dict) and conc.get("cancel-in-progress") is not False:
    bad.append("cancel-in-progress is %r (want false: a dispatch never kills a running scheduled run)" % conc.get("cancel-in-progress"))
for b in bad:
    print(b)
sys.exit(1 if bad else 0)
PY
}

# 1. the real workflow.
if out="$(check_wf "$WF")"; then ok "concurrency group carries the run mode, per ref, cancel-in-progress false"
else bad "macos-cadence.yml concurrency: $out"; fi

# 2. RED control: the ref-only block the workflow had before the mode was added
# (copied verbatim from the workflow at a2c3581) must fail the check.
tmpd="$(mktemp -d -t macos-conc.XXXXXX)" || exit 1
trap 'rm -rf "$tmpd"' EXIT
old="$tmpd/old.yml"
cat > "$old" <<'YML'
concurrency:
  group: macos-cadence-${{ github.ref }}
  cancel-in-progress: false
YML
if out="$(check_wf "$old")"; then bad "the pre-8052 ref-only group passes the check (the check is vacuous)"
else
  case "$out" in
    *"mode is not in it"*) ok "the ref-only group of main is rejected: the mode is missing" ;;
    *) bad "ref-only group rejected for the wrong reason: $out" ;;
  esac
fi

# 3. a schedule or PR run has no suites input: it must land in the full group,
# the same one a full dispatch uses, so those runs queue with each other as before.
if grep -q "^  group: macos-cadence-\${{ github.ref }}-\${{ inputs.suites != '' && 'suites' || 'full' }}\$" "$WF"; then
  ok "empty suites (schedule, PR, full dispatch) maps to the 'full' group"
else bad "group is not macos-cadence-<ref>-<suites|full> keyed on inputs.suites != ''"; fi

[ "$fails" -eq 0 ] || { echo "$fails failed" >&2; exit 1; }
echo "all passed"
