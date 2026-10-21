#!/usr/bin/env bash
# scripts/ci/test-ci-container-jobs.sh -- the ci.yml Linux jobs that run in the
# prebuilt CI image (.github/ci-image/Dockerfile, docs/internals/ci-image.md).
#
#   K1  each containerized job has a block-form container: with the canonical
#       image expression, registry credentials from github.token, --init (so
#       orphaned descendants are reaped), --user 1001 (plus --privileged where
#       bwrap needs it) and packages: read, and sets defaults.run.shell to
#       bash (a container's default run shell is sh, which has no pipefail)
#   K2  every job names the same default ref, pinned by digest
#   K3  the image expression is EVALUATED (python3 translation of the GitHub
#       expression subset): push, schedule, dispatch and a same-repo PR get the
#       image or the vars.CI_IMAGE override; a fork PR, a dependabot[bot] run
#       and a shell-unit shard on a self-hosted route get '' (the host path)
#   K4  the old `<fork> && '' || <image>` form lets a fork through ('' is
#       falsy); the evaluator must see that, so K3 is not vacuous
#   K5  in those jobs every host setup step (setup-node, setup-bun, apt, pip,
#       the gitleaks download) is gated on !job.container.id, and
#       shell-unit-shard starts atd in the container
#
# Usage: bash scripts/ci/test-ci-container-jobs.sh
# Exit codes: 0 -- all cases passed; 1 -- at least one failed.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CI_YML="${CI_YML:-$ROOT/.github/workflows/ci.yml}"
fails=0
ok()  { echo "ok - $1"; }
bad() { echo "FAIL - $1" >&2; fails=$((fails + 1)); }

JOBS="ci-quick lint lanes-and-trust-suites bun-suites security-scan shell-unit-shard guard-corpus-full"
PRIVILEGED="ci-quick shell-unit-shard guard-corpus-full"
SELF_HOSTED="shell-unit-shard"
FORK="github.event_name == 'pull_request' && github.event.pull_request.head.repo.full_name != github.repository || github.actor == 'dependabot[bot]'"
ROUTES=" || vars.HIMMEL_VM_RUNNER == 'on' || vars.CI_GCP == 'on'"
REF_RE='^ghcr\.io/yotamleo-org/himmel-ci@sha256:[0-9a-f]{64}$'

# The hardcoded-env-values gate's marker is the one trailing comment an image line may carry.
job_block() { awk -v job="$1" '$0 == "  " job ":" { j = 1; print; next } j && /^  [A-Za-z0-9_-]+:[ ]*(#.*)?$/ { exit } j { print }' "$CI_YML" | sed 's/ # env-literal-ok: .*$//'; }
in_list() { case " $2 " in *" $1 "*) return 0 ;; esac; return 1; }
image_of() { sed -n 's/^      image: //p' <<< "$1"; }
# k1_shell_ok <job block>: the job-level defaults.run.shell is bash.
k1_shell_ok() {
  awk '$0 == "    defaults:" { d = 1; next }
       d && /^    [^ ]/ { d = 0; r = 0 }
       d && $0 == "      run:" { r = 1; next }
       r && /^      [^ ]/ { r = 0 }
       r && /^        shell: bash( -e [{]0[}])?$/ { f = 1 }
       END { exit !f }' <<< "$1"
}

# evaluate <expr> <event> <head_repo> <actor> <ci_image> <vm_runner> <ci_gcp>
evaluate() {
  python3 -I - "$@" <<'PY'
import re, sys
expr, event, head, actor, ci_image, vm, gcp = sys.argv[1:8]
class C(dict):
    def __getattr__(self, k): return self.get(k, "")
def wrap(d): return C({k: wrap(v) if isinstance(v, dict) else v for k, v in d.items()})
ctx = wrap({
    "github": {"event_name": event, "repository": "yotamleo-org/Himmel", "actor": actor,
               "event": {"pull_request": {"head": {"repo": {"full_name": head}}}}},
    "vars": {"CI_IMAGE": ci_image, "HIMMEL_VM_RUNNER": vm, "CI_GCP": gcp},
})
body = re.fullmatch(r"\$\{\{\s*(.*?)\s*\}\}", expr).group(1)
body = body.replace("&&", " and ").replace("||", " or ")
body = re.sub(r"!(?!=)", " not ", body)
print(eval(body, {"__builtins__": {}}, dict(ctx)))
PY
}

refs=""
for j in $JOBS; do
  b="$(job_block "$j")"
  if [ -z "$b" ]; then bad "K1 no job $j"; continue; fi
  img="$(image_of "$b")"
  ref="$(sed -nE "s/.*\(vars\.CI_IMAGE \|\| '([^']*)'\).*/\1/p" <<< "$img")"
  routes=""; in_list "$j" "$SELF_HOSTED" && routes="$ROUTES"
  want="\${{ !($FORK$routes) && (vars.CI_IMAGE || '$ref') || '' }}"
  opts="--init --user 1001"; in_list "$j" "$PRIVILEGED" && opts="$opts --privileged"
  # K1
  miss=""
  for l in "    container:" "      image: $want" "      credentials:" \
           "        username: \${{ github.actor }}" "        password: \${{ github.token }}" \
           "      options: $opts" "      packages: read"; do
    grep -qxF -- "$l" <<< "$b" || miss="$miss [$l]"
  done
  if [ -n "$img" ] && [ -z "$miss" ]; then ok "K1 $j runs in the image ($opts, packages: read)"
  else bad "K1 $j container shape: missing${miss:- image line}"; fi
  if k1_shell_ok "$b"; then ok "K1 $j sets defaults.run.shell: bash"
  else bad "K1 $j has no defaults.run.shell: bash, so its run steps get the container's sh"; fi
  # K2
  if [[ "$ref" =~ $REF_RE ]]; then ok "K2 $j default ref is digest-pinned"; else bad "K2 $j default ref '${ref:-<none>}' is not ghcr.io/yotamleo-org/himmel-ci@sha256:<64 hex>"; fi
  refs="$refs$ref"$'\n'
  # K3
  [ -n "$img" ] || continue
  chk() { # <label> <want> <event> <head> <actor> <ci_image> <vm> <gcp>
    local got; got="$(evaluate "$img" "$3" "$4" "$5" "$6" "$7" "$8" 2>&1)"
    if [ "$got" = "$2" ]; then ok "K3 $j: $1"; else bad "K3 $j: $1: want '$2' got '$got'"; fi
  }
  O='ghcr.io/yotamleo-org/himmel-ci@sha256:1111111111111111111111111111111111111111111111111111111111111111'
  chk "push to main gets the image"              "$ref" push              ""                  yotamleo "" "" ""
  chk "schedule gets the image"                  "$ref" schedule          ""                  yotamleo "" "" ""
  chk "dispatch gets the image"                  "$ref" workflow_dispatch ""                  yotamleo "" "" ""
  chk "same-repo PR gets the image"              "$ref" pull_request      yotamleo-org/Himmel yotamleo "" "" ""
  chk "vars.CI_IMAGE overrides the default"      "$O"   pull_request      yotamleo-org/Himmel yotamleo "$O" "" ""
  chk "fork PR runs on the host"                 ""     pull_request      someone/Himmel      someone  "" "" ""
  chk "fork PR ignores vars.CI_IMAGE"            ""     pull_request      someone/Himmel      someone  "$O" "" ""
  chk "dependabot[bot] PR runs on the host"      ""     pull_request      yotamleo-org/Himmel 'dependabot[bot]' "" "" ""
  chk "dependabot[bot] push runs on the host"    ""     push              ""                  'dependabot[bot]' "" "" ""
  if in_list "$j" "$SELF_HOSTED"; then
    chk "HIMMEL_VM_RUNNER on runs on the host"   ""     pull_request      yotamleo-org/Himmel yotamleo "" on ""
    chk "CI_GCP on runs on the host"             ""     workflow_dispatch ""                  yotamleo "" "" on
  else
    chk "the self-hosted switches leave it in the image" "$ref" pull_request yotamleo-org/Himmel yotamleo "" on on
  fi
done
# K1: a step-level shell under a defaults block that sets no shell is not a job default.
mut=$'  lint:\n    defaults:\n      run:\n        working-directory: .\n    steps:\n      - run: set -o pipefail\n        shell: bash -e {0}'
if k1_shell_ok "$mut"; then bad "K1 a step-level shell: bash passes for defaults.run.shell"
else ok "K1 a step-level shell: bash is not defaults.run.shell"; fi
if [ "$(sort -u <<< "$refs" | grep -c .)" -eq 1 ]; then ok "K2 every job names the same default ref"; else bad "K2 the jobs name different default refs: $(sort -u <<< "$refs" | tr '\n' ' ')"; fi

# K4: the evaluator is not vacuous -- the old form lets a fork into the image.
D='ghcr.io/yotamleo-org/himmel-ci@sha256:2222222222222222222222222222222222222222222222222222222222222222'
old="\${{ ($FORK) && '' || (vars.CI_IMAGE || '$D') }}"
if [ "$(evaluate "$old" pull_request someone/Himmel someone "" "" "")" = "$D" ]; then ok "K4 the old <fork> && '' || <image> form lets a fork through"
else bad "K4 the evaluator no longer sees the old form leak a fork"; fi

# K5
for j in $JOBS; do
  b="$(job_block "$j")"
  [ -n "$b" ] || continue
  # "<if>\t<one-line body>" per step
  steps="$(awk '
    function flush() { if (inst) print (cond == "" ? "-" : cond) "\t" body; cond = ""; body = ""; inst = 0 }
    /^    steps:/ { s = 1; next }
    s && /^      - / { flush(); inst = 1 }
    s && inst && /^        if: / { cond = $0; sub(/^        if: /, "", cond) }
    s && inst && /^      - if: / { cond = $0; sub(/^      - if: /, "", cond) }
    s && inst && !/^[[:space:]]*#/ { body = body " " $0 }
    END { flush() }' <<< "$b")"
  n=0
  while IFS=$'\t' read -r cond body; do
    case "$body" in
      *actions/setup-node@*|*oven-sh/setup-bun@*|*apt-install.sh*|*"pip install"*|*"key: apt-"*|*ImageVersion*|*gitleaks/releases/download*) ;;
      *) continue ;;
    esac
    n=$((n + 1))
    case "$cond" in
      *'!job.container.id'*) ;;
      *) bad "K5 $j host setup step runs in the container (if: '$cond'):$(cut -c1-120 <<< "$body")" ;;
    esac
  done <<< "$steps"
  ok "K5 $j: checked $n host setup step(s)"
done
atd_step="$(job_block shell-unit-shard | awk '/^      - name: Start atd \(CI image\)$/ { f = 1; next } f && /^      - / { exit } f')"
# shellcheck disable=SC2016 # a literal ${{ }} GitHub expression
if grep -qxF '        if: ${{ job.container.id }}' <<< "$atd_step" && grep -qE '^          sudo atd$' <<< "$atd_step"; then
  ok "K5 shell-unit-shard starts atd in the container"
else
  bad "K5 shell-unit-shard has no 'Start atd (CI image)' step gated on job.container.id"
fi

[ "$fails" -eq 0 ] && { echo "all passed"; exit 0; }
echo "$fails failed" >&2
exit 1
