#!/usr/bin/env bash
# scripts/ci/test-pages-workflow.sh -- static suite for Pages
# source is build_type=workflow, so pages.yml must deploy once a day plus on
# demand, never on every push (the legacy branch build redeployed the site on
# every push to main, ~30 deployments in 12 h). Properties asserted over the
# workflow text:
#   1. triggers are exactly a daily schedule (cron 17 3 * * *) plus
#      workflow_dispatch (no push, no pull_request, no tags);
#   2. two jobs, build and deploy (needs: build). The workflow token is
#      contents:read only and the build job holds no write permission; the
#      deploy job holds pages:write + id-token:write;
#   3. build job: checkout with persist-credentials:false, `npm ci --ignore-scripts`
#      and `npm run build` in one step with working-directory: site, then the
#      upload-pages-artifact step (after the build) whose own with.path is
#      site/dist; deploy job: configure-pages + deploy-pages, no repo code;
#      docs/.nojekyll exists;
#   4. concurrency group pages, never cancelling a running deploy;
#   5. a timeout-minutes on each job; the workflow is not named `CI`
#      (cut-tag.sh keys on a workflow named exactly CI).
# Mutation controls prove each check can fail; no network.
#
# Usage: bash scripts/ci/test-pages-workflow.sh
# Exit codes: 0 -- all cases passed; 1 -- at least one failed.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
WF="${PAGES_YML:-$ROOT/.github/workflows/pages.yml}"
fails=0
ok()  { echo "ok - $1"; }
bad() { echo "FAIL - $1" >&2; fails=$((fails + 1)); }

strip_comments() { sed -e 's/^[[:space:]]*#.*$//' -e 's/[[:space:]][[:space:]]*#.*$//' "$1"; }

# job_of <job> -- stdin: workflow text; print the lines of that top-level job.
job_of() {
    awk -v j="$1" '
        $0 ~ "^  " j ":[[:space:]]*$" { f = 1; print; next }
        f && /^  [A-Za-z0-9_-]+:/ { f = 0 }
        f && /^[^[:space:]]/ { f = 0 }
        f' # pipefail-ok: small input
}

# step_of <ere> -- stdin: a job block; print the first step whose text matches.
step_of() {
    awk -v re="$1" '
        /^      - / { if (buf ~ re) { printf "%s", buf; found = 1; exit } buf = "" }
        { buf = buf $0 "\n" }
        END { if (!found && buf ~ re) printf "%s", buf }' # pipefail-ok: small input
}

# check_file <file> -- print one "name" line per violated property.
check_file() {
    local f="$1" s build deploy bstep ustep jobs top_perms
    [ -f "$f" ] || { echo "workflow-missing"; return; }
    s=$(strip_comments "$f")
    build=$(job_of build <<< "$s")
    deploy=$(job_of deploy <<< "$s")
    grep -qE '^name:[[:space:]]*Pages[[:space:]]*$' <<< "$s" || echo "name-not-Pages"
    grep -qE "^[[:space:]]+-[[:space:]]*cron:[[:space:]]*'17 3 \\* \\* \\*'" <<< "$s" || echo "cron-not-daily-0317"
    grep -qE '^[[:space:]]+workflow_dispatch:' <<< "$s" || echo "no-dispatch"
    events=$(awk '/^on:/{f=1;next} /^[^[:space:]]/{f=0} f && /^  [a-z_]+:/{sub(/:.*/,"");gsub(/ /,"");print}' <<< "$s" | sort | tr '\n' ' ') # pipefail-ok: small input
    [ "$events" = "schedule workflow_dispatch " ] || echo "extra-trigger"
    grep -qE '^[[:space:]]+(tags|branches|branches-ignore|paths):' <<< "$s" && echo "extra-trigger"

    # two-job shape
    jobs=$(awk '/^jobs:/{f=1;next} /^[^[:space:]]/{f=0} f && /^  [A-Za-z0-9_-]+:/{sub(/:.*/,"");gsub(/ /,"");print}' <<< "$s" | sort | tr '\n' ' ') # pipefail-ok: small input
    [ "$jobs" = "build deploy " ] || echo "jobs-not-build-deploy"
    grep -qE '^    needs:[[:space:]]*build[[:space:]]*$' <<< "$deploy" || echo "deploy-not-needs-build"

    # permissions: workflow token read-only, build job holds no write, deploy holds the two
    top_perms=$(awk '/^permissions:/{f=1;next} /^[^[:space:]]/{f=0} f' <<< "$s") # pipefail-ok: small input
    grep -qE '^[[:space:]]+contents:[[:space:]]*read' <<< "$top_perms" || echo "no-contents-read"
    grep -qE '^[[:space:]]+[a-z-]+:[[:space:]]*write[[:space:]]*$' <<< "$top_perms" && echo "extra-write-permission"
    grep -qE '^[[:space:]]+[a-z-]+:[[:space:]]*write[[:space:]]*$' <<< "$build" && echo "build-job-writes"
    grep -qE '^      pages:[[:space:]]*write' <<< "$deploy" || echo "no-pages-write"
    grep -qE '^      id-token:[[:space:]]*write' <<< "$deploy" || echo "no-id-token"
    grep -vE '^      (pages|id-token):[[:space:]]*write' <<< "$deploy" | grep -qE '^      [a-z-]+:[[:space:]]*write[[:space:]]*$' && echo "extra-write-permission" # pipefail-ok: small input
    grep -qE '^[[:space:]]*permissions:[[:space:]]*write-all' <<< "$s" && echo "extra-write-permission"
    grep -qE '^[[:space:]]*permissions:[[:space:]]*write-all' <<< "$build" && echo "build-job-writes"

    # build job: credentials, npm ci in site/, build before upload, upload path bound to its own step
    bstep=$(step_of 'uses:[[:space:]]*actions/checkout@' <<< "$build")
    grep -qE '^[[:space:]]+persist-credentials:[[:space:]]*false[[:space:]]*$' <<< "$bstep" || echo "checkout-persists-credentials"
    bstep=$(step_of 'npm run build' <<< "$build")
    grep -qE '^[[:space:]]+npm run build[[:space:]]*$' <<< "$bstep" || echo "no-site-build"
    grep -qE '^[[:space:]]+npm ci --ignore-scripts[[:space:]]*$' <<< "$bstep" || echo "no-npm-ci"
    grep -qE '^[[:space:]]+working-directory:[[:space:]]*site[[:space:]]*$' <<< "$bstep" || echo "no-working-directory-site"
    ustep=$(step_of 'uses:[[:space:]]*actions/upload-pages-artifact@' <<< "$build")
    [ -n "$ustep" ] || echo "no-upload-pages-artifact"
    grep -qE '^[[:space:]]+path:[[:space:]]*site/dist[[:space:]]*$' <<< "$ustep" || echo "upload-path-not-site-dist"
    b_line=$(grep -nE 'npm run build' <<< "$build" | head -1 | cut -d: -f1) # pipefail-ok: small input
    u_line=$(grep -nE 'uses:[[:space:]]*actions/upload-pages-artifact@' <<< "$build" | head -1 | cut -d: -f1) # pipefail-ok: small input
    if [ -n "$b_line" ] && [ -n "$u_line" ] && [ "$u_line" -lt "$b_line" ]; then echo "upload-before-build"; fi

    # deploy job: the Pages actions, no repo code, no npm
    grep -qE "^    if:[[:space:]]*github\.ref == 'refs/heads/main'[[:space:]]*\$" <<< "$deploy" || echo "deploy-not-main-gated"
    grep -qE 'uses:[[:space:]]*actions/configure-pages@' <<< "$deploy" || echo "no-configure-pages"
    grep -qE 'uses:[[:space:]]*actions/deploy-pages@' <<< "$deploy" || echo "no-deploy-pages"
    grep -qE 'uses:[[:space:]]*actions/(checkout|setup-node)@|^[[:space:]]+(-[[:space:]]+)?(run|working-directory):' <<< "$deploy" && echo "deploy-job-runs-repo-code"

    grep -qE '^[[:space:]]+group:[[:space:]]*pages[[:space:]]*$' <<< "$s" || echo "no-pages-group"
    grep -qE '^[[:space:]]+cancel-in-progress:[[:space:]]*false' <<< "$s" || echo "cancels-running-deploy"
    grep -qE '^    timeout-minutes:[[:space:]]*[0-9]+' <<< "$build" || echo "no-timeout"
    grep -qE '^    timeout-minutes:[[:space:]]*[0-9]+' <<< "$deploy" || echo "no-timeout"
}

# expect_clean <label> <file> / expect_violation <label> <file> <name>
got=$(check_file "$WF")
if [ -z "$got" ]; then ok "pages.yml satisfies every property"; else bad "pages.yml violates: ${got//$'\n'/ }"; fi

if [ -f "$ROOT/docs/.nojekyll" ]; then
    ok "docs/.nojekyll present (Jekyll off, plain static == legacy output)"
else
    bad "docs/.nojekyll missing -- legacy Pages ran Jekyll on docs/"
fi

# Mutation controls: each rewrite of the real workflow must trip its check.
if [ -f "$WF" ]; then
    tmp=$(mktemp -d "${TMPDIR:-/tmp}/pages-wf.XXXXXX") || exit 1; trap 'rm -rf "$tmp"' EXIT
    mutate() { # <name> <sed-expr>
        sed -e "$2" "$WF" > "$tmp/m.yml"
        out=$(check_file "$tmp/m.yml")
        if grep -qx "$1" <<< "$out"; then ok "control: $1 detected"; else bad "control: $1 NOT detected"; fi
    }
    mutate cron-not-daily-0317 "s#'17 3 \* \* \*'#'0 * * * *'#"
    mutate extra-trigger "s#^  schedule:#  push:\n    branches: [main]\n  schedule:#"
    mutate extra-trigger "s#^  schedule:#  pull_request:\n  schedule:#"
    mutate no-dispatch "s#workflow_dispatch:#workflow_x:#"
    mutate no-timeout "s#timeout-minutes:#timeout:#"
    mutate cancels-running-deploy "s#cancel-in-progress: false#cancel-in-progress: true#"
    mutate no-deploy-pages "s#actions/deploy-pages@#actions/other@#"
    mutate name-not-Pages "s#^name: Pages#name: CI#"
    mutate extra-trigger "s#^  workflow_dispatch:#  workflow_run:\n  workflow_dispatch:#"
    mutate extra-trigger "s#^  workflow_dispatch:#  create:\n  workflow_dispatch:#"
    mutate upload-path-not-site-dist "s#path: site/dist#path: docs#"
    # a decoy `path: site/dist` elsewhere must not satisfy the upload step's own path
    mutate upload-path-not-site-dist "s#path: site/dist#path: docs#;s#^      - id: deployment#      - uses: actions/other@v1\n        with:\n          path: site/dist\n      - id: deployment#"
    mutate no-site-build "s#npm run build#npm run lint#"
    mutate extra-write-permission "s#^  contents: read#  contents: read\n  issues: write#"
    mutate extra-write-permission "s#^  contents: read#  contents: read\n  pages: write#"
    mutate extra-write-permission "s#^      id-token: write#      id-token: write\n      issues: write#"
    mutate build-job-writes "s#^  build:#  build:\n    permissions:\n      id-token: write#"
    mutate deploy-not-main-gated "/^    if: github.ref == 'refs\/heads\/main'\$/d"
    mutate deploy-not-main-gated "s#^    if: github.ref == 'refs/heads/main'#    if: github.ref == 'refs/heads/dev'#"
    mutate extra-write-permission "s#^permissions:#permissions: write-all#"
    mutate build-job-writes "s#^  build:#  build:\n    permissions: write-all#"
    mutate no-id-token "s#id-token: write#id-token: read#"
    mutate no-pages-write "s#pages: write#pages: read#"
    mutate jobs-not-build-deploy "/^  deploy:/,\$d"
    mutate jobs-not-build-deploy "s#^  deploy:#  publish:#"
    mutate deploy-not-needs-build "s#needs: build#needs: other#"
    mutate checkout-persists-credentials "s#persist-credentials: false#persist-credentials: true#"
    mutate checkout-persists-credentials "/persist-credentials: false/d"
    mutate no-npm-ci "s#npm ci#npm install#"
    mutate no-working-directory-site "s#working-directory: site#working-directory: .#"
    mutate no-working-directory-site "/working-directory: site/d"
    mutate upload-before-build "s#^    steps:#    steps:\n      - uses: actions/upload-pages-artifact@v5\n        with:\n          path: site/dist#"
    mutate deploy-job-runs-repo-code "s#^      - id: deployment#      - uses: actions/checkout@v7\n      - id: deployment#"
    mutate deploy-job-runs-repo-code "s#^      - id: deployment#      - run: npm ci\n      - id: deployment#"
fi

[ "$fails" -eq 0 ] && { echo "all passed"; exit 0; }
echo "$fails failed" >&2; exit 1
