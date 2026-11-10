#!/usr/bin/env bash
# Hermetic test for the lint-job step of ci.yml that runs the tree-only
# pre-commit gates (bundle-registry-lint, no-mcp-sdk-v1, fail-open-lint,
# pip-hashes) from their BASE copies. The step text is extracted from the real
# workflow and run in a throwaway repo shaped like a PR checkout.
set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
CI_YML="$REPO_ROOT/.github/workflows/ci.yml"
# shellcheck source=scripts/lib/fixture-tempdir.sh
# shellcheck disable=SC1091
. "$REPO_ROOT/scripts/lib/fixture-tempdir.sh"
failures=0
pass() { printf '  PASS  %s\n' "$1"; }
fail() { printf '  FAIL  %s\n' "$1"; failures=$((failures+1)); }

T="$(mktemp -d "${TMPDIR:-/tmp}/ci-tree-gates.XXXXXX")" || exit 1
trap 'rm -rf "$T"' EXIT

STEP="$T/step.sh"
awk '
    /^  [a-z][a-z0-9-]*:/ { injob = ($1 == "lint:") }
    injob && /^      - name: tree-only pre-commit gates/ { instep = 1; next }
    instep && /^        run: \|/ { inrun = 1; next }
    inrun && /^          / { sub(/^          /, ""); print; next }
    inrun { exit }
' "$CI_YML" > "$STEP"
if [ -s "$STEP" ]; then pass "lint job has a tree-only gates step"; else fail "no tree-only gates step in the lint job of ci.yml"; fi

S="$T/repo"; mkdir -p "$S/tmp" "$S/scripts/lint" "$S/scripts/hooks" "$S/scripts/install" "$S/scripts/lanes" "$S/scripts/guardrails" "$S/docs/setup"
git -C "$S" init -q -b main
git -C "$S" config user.email t@t; git -C "$S" config user.name t
cp "$REPO_ROOT/scripts/lint/check-mcp-sdk-v1.sh" "$S/scripts/lint/"
cp "$REPO_ROOT/scripts/hooks/check-fail-open-lint.sh" "$REPO_ROOT/scripts/hooks/check-pip-hashes.sh" "$S/scripts/hooks/"
# himmelctl/lib/probes.js requires the hook launcher (and its integrity lib)
cp "$REPO_ROOT/scripts/hooks/run-hook-with-bash.js" "$REPO_ROOT/scripts/hooks/hook-integrity.js" "$S/scripts/hooks/"
cp "$REPO_ROOT/scripts/install/bundle-registry-lint.mjs" "$REPO_ROOT/scripts/install/manifest.json" "$S/scripts/install/"
cp "$REPO_ROOT/scripts/himmel-doctor.sh" "$S/scripts/"
cp "$REPO_ROOT/scripts/lanes/lanes.json" "$S/scripts/lanes/"
cp "$REPO_ROOT/docs/setup/settings-template.json" "$S/docs/setup/"
cp -R "$REPO_ROOT/scripts/himmelctl" "$S/scripts/himmelctl"
cp -R "$REPO_ROOT/scripts/guardrails/." "$S/scripts/guardrails/"
cp -R "$REPO_ROOT/scripts/hooks/." "$S/scripts/hooks/"
cp -R "$REPO_ROOT/scripts/lanes/." "$S/scripts/lanes/"
cp "$REPO_ROOT/.pre-commit-config.yaml" "$S/"
# the other guard surfaces the fail-open suite expects to find
mkdir -p "$S/scripts/graphify" "$S/scripts/telegram"
cp "$REPO_ROOT/scripts/graphify/refresh-graph-map.sh" "$S/scripts/graphify/"
cp "$REPO_ROOT/scripts/claude-codex" "$S/scripts/"
printf 'pkg==1.0 --hash=sha256:abc\n' > "$S/requirements.txt"
printf 'x\n' > "$S/a.txt"
git -C "$S" add -A; git -C "$S" commit -q -m base
BASE="$(git -C "$S" rev-parse HEAD)"

run_step() { # <base sha> -> OUT, RC
  OUT="$(cd "$S" && BASE_SHA="$1" RUNNER_TEMP="$T/rt" bash -e "$STEP" 2>&1)"; RC=$?
}
branch() { git -C "$S" checkout -q -B "$1" "$BASE"; }
commit() { git -C "$S" add -A; git -C "$S" commit -q -m "$1"; }
has() { case "$OUT" in *"$1"*) return 0 ;; *) return 1 ;; esac; }

branch clean; printf 'y\n' > "$S/b.txt"; commit clean
run_step "$BASE"
if [ "$RC" -eq 0 ]; then pass "clean PR range passes"; else fail "clean PR -> rc=$RC: $OUT"; fi

branch mcp; printf "import { Server } from '@modelcontextprotocol/sdk/server/index.js';\n" > "$S/srv.ts"; commit mcp
run_step "$BASE"
if [ "$RC" -ne 0 ] && has "srv.ts"; then pass "PR adding a v1 MCP SDK import fails"; else fail "mcp -> rc=$RC: $OUT"; fi

branch pip; printf 'pkg==2.0\n' > "$S/requirements-extra.txt"; commit pip
run_step "$BASE"
if [ "$RC" -ne 0 ] && has "requirements-extra.txt"; then pass "PR adding an unhashed requirements file fails"; else fail "pip -> rc=$RC: $OUT"; fi

branch bundle
node -e 'const f=process.argv[1],fs=require("fs"),m=JSON.parse(fs.readFileSync(f,"utf8"));m.items.push({id:"zz-unmapped-row"});fs.writeFileSync(f,JSON.stringify(m,null,2))' "$S/scripts/install/manifest.json"
commit bundle
run_step "$BASE"
if [ "$RC" -ne 0 ] && has "UNMAPPED zz-unmapped-row"; then pass "PR adding an unmapped feed row fails"; else fail "bundle -> rc=$RC: $OUT"; fi

branch libweaken
node -e 'const f=process.argv[1],fs=require("fs"),m=JSON.parse(fs.readFileSync(f,"utf8"));m.items.push({id:"zz-unmapped-row"});fs.writeFileSync(f,JSON.stringify(m,null,2))' "$S/scripts/install/manifest.json"
{ printf 'process.exit(0);\n'; cat "$S/scripts/himmelctl/lib/config-feed.js"; } > "$T/cf.js"; cp "$T/cf.js" "$S/scripts/himmelctl/lib/config-feed.js"
commit libweaken
run_step "$BASE"
if [ "$RC" -ne 0 ] && has "UNMAPPED zz-unmapped-row"; then pass "PR weakening the himmelctl lib is still judged by the base copy"; else fail "libweaken -> rc=$RC: $OUT"; fi

branch failopen; printf '#!/usr/bin/env bash\necho regression >&2\nexit 1\n' > "$S/scripts/guardrails/test-lint-fail-open.sh"; commit failopen
run_step "$BASE"
if [ "$RC" -eq 0 ]; then pass "PR's own copy of the fail-open suite is ignored (base suite judges the tree)"; else fail "failopen -> rc=$RC: $OUT"; fi

# a fail-open violation in a guard surface, shipped by a PR that also neuters the lint or its suite
violation() { cp "$S/scripts/guardrails/fixtures/fail-open/instance1-unreadable-denylist.sh.fxt" "$S/scripts/hooks/zz-fail-open.sh"; }
branch violation; violation; commit violation
run_step "$BASE"
if [ "$RC" -ne 0 ] && has "zz-fail-open.sh"; then pass "PR adding a fail-open violation fails"; else fail "violation -> rc=$RC: $OUT"; fi

branch guardsurface; cp "$S/scripts/guardrails/fixtures/fail-open/instance1-unreadable-denylist.sh.fxt" "$S/scripts/guardrails/check-git-env-scrub.sh"; commit guardsurface
run_step "$BASE"
if [ "$RC" -ne 0 ] && has "check-git-env-scrub.sh"; then pass "PR edit to an existing guardrails file is still scanned"; else fail "guardsurface -> rc=$RC: $OUT"; fi

branch exportignore; violation; printf 'scripts/hooks/zz-fail-open.sh export-ignore\n' > "$S/.gitattributes"; commit exportignore
run_step "$BASE"
if [ "$RC" -ne 0 ] && has "zz-fail-open.sh"; then pass "PR export-ignore attribute cannot hide a violating file"; else fail "exportignore -> rc=$RC: $OUT"; fi

branch backslash; cp "$S/scripts/guardrails/fixtures/fail-open/instance1-unreadable-denylist.sh.fxt" "$S/scripts/hooks/zz-back\\slash.sh"; commit backslash
run_step "$BASE"
if [ "$RC" -ne 0 ] && has "zz-back"; then pass "PR violation in a file whose name has a backslash is still scanned"; else fail "backslash -> rc=$RC: $OUT"; fi

branch lintneuter; violation; printf '#!/usr/bin/env bash\nexit 0\n' > "$S/scripts/guardrails/lint-fail-open.sh"; commit lintneuter
run_step "$BASE"
if [ "$RC" -ne 0 ] && has "zz-fail-open.sh"; then pass "PR neutering lint-fail-open.sh is still judged by the base lint"; else fail "lintneuter -> rc=$RC: $OUT"; fi

branch suiteneuter; violation; printf '#!/usr/bin/env bash\nexit 0\n' > "$S/scripts/guardrails/test-lint-fail-open.sh"; commit suiteneuter
run_step "$BASE"
if [ "$RC" -ne 0 ] && has "zz-fail-open.sh"; then pass "PR neutering the suite is still judged by the base suite"; else fail "suiteneuter -> rc=$RC: $OUT"; fi

branch weaken
printf '#!/usr/bin/env bash\nexit 0\n' > "$S/scripts/hooks/check-pip-hashes.sh"
printf 'pkg==2.0\n' > "$S/requirements-extra.txt"; commit weaken
run_step "$BASE"
if [ "$RC" -ne 0 ]; then pass "PR weakening a gate is still judged by the base copy"; else fail "weaken -> rc=$RC: $OUT"; fi

branch clean2
run_step ""
if [ "$RC" -ne 0 ]; then pass "missing base sha fails closed"; else fail "empty base -> rc=$RC: $OUT"; fi
run_step "0000000000000000000000000000000000000000"
if [ "$RC" -ne 0 ]; then pass "unreachable base sha fails closed"; else fail "bad base -> rc=$RC: $OUT"; fi

branch nobasegate; git -C "$S" rm -q scripts/hooks/check-pip-hashes.sh; commit rmgate
NOGATE="$(git -C "$S" rev-parse HEAD)"
branch absent; printf 'z\n' > "$S/c.txt"; git -C "$S" add -A; git -C "$S" commit -q -m c
git -C "$S" checkout -q "$NOGATE"
run_step "$NOGATE"
if [ "$RC" -ne 0 ]; then pass "gate script absent at base fails closed"; else fail "absent gate -> rc=$RC: $OUT"; fi

branch nosuite; git -C "$S" rm -q scripts/guardrails/test-lint-fail-open.sh; commit rmsuite
NOSUITE="$(git -C "$S" rev-parse HEAD)"
branch suiteabsent; printf 'z\n' > "$S/d.txt"; git -C "$S" add -A; git -C "$S" commit -q -m d
git -C "$S" checkout -q "$NOSUITE"
run_step "$NOSUITE"
if [ "$RC" -ne 0 ] && has "fail-open suite absent at base"; then pass "fail-open suite absent at base fails closed"; else fail "absent suite -> rc=$RC: $OUT"; fi

# The lint job and the shell-unit shards fetch GitHub release assets (the wheel build of
# the pinned linter, and shfmt). A 5xx from the release host would redden every open PR
# with no code cause, so both run from an actions/cache entry and a cold-cache miss
# during an outage names the URL and the word infra.
job_block() { awk -v job="$1:" '/^  [a-z][a-z0-9-]*:/ { injob = ($1 == job) } injob' "$CI_YML"; }
step_block() { # <job> <step name prefix> -> the step's lines
  job_block "$1" | awk -v pfx="name: $2" '
      function flush() { if (index(buf, "\n        " pfx) > 0 || index(buf, "      - " pfx) > 0) printf "%s", buf; buf = "" }
      /^      - / { flush() }
      { buf = buf "\n" $0 }
      END { flush() }' | sed '1{/^$/d}'
}
step_run() { # <job> <step name prefix> -> the step's run body, de-indented
  step_block "$1" "$2" | awk '
      /^        run: \|/ { inrun = 1; next }
      /^        run: / { sub(/^        run: /, ""); print; exit }
      inrun && /^          / { sub(/^          /, ""); print; next }
      inrun { exit }'
}
CACHE_PIN='actions/cache@55cc8345863c7cc4c66a329aec7e433d2d1c52a9 # v6.1.0'

LINT_CACHE="$(step_block lint 'Cache pre-commit environments')"
case "$LINT_CACHE" in *"uses: $CACHE_PIN"*) pass "lint job caches the pre-commit environment with the sha-pinned actions/cache" ;; *) fail "lint job has no sha-pinned pre-commit cache step: $LINT_CACHE" ;; esac
case "$LINT_CACHE" in *"path: ~/.cache/pre-commit"*"hashFiles('.pre-commit-config.yaml')"*) pass "pre-commit cache path and key (hash of .pre-commit-config.yaml)" ;; *) fail "pre-commit cache path/key wrong: $LINT_CACHE" ;; esac
lint_cache_line="$(job_block lint | grep -n -F -- 'name: Cache pre-commit environments' | head -n 1 | cut -d: -f1)"
lint_sc_line="$(job_block lint | grep -n -F -- '- name: shellcheck (PR range)' | head -n 1 | cut -d: -f1)"
if [ -n "$lint_cache_line" ] && [ -n "$lint_sc_line" ] && [ "$lint_cache_line" -lt "$lint_sc_line" ]; then pass "pre-commit cache restores before the first shellcheck step"; else fail "cache step ($lint_cache_line) is not before the shellcheck step ($lint_sc_line)"; fi
LINT_INFRA="$(step_block lint 'Name a shellcheck release-host outage')"
case "$LINT_INFRA" in *"failure()"*"cache-hit"*) pass "outage line runs only on a failure with no cache hit" ;; *) fail "outage step missing or ungated: $LINT_INFRA" ;; esac
case "$(step_run lint 'Name a shellcheck release-host outage')" in *'github.com/koalaman/shellcheck/releases/download/'*'infra:'*) pass "outage line names the word infra and the release URL" ;; *) fail "outage line lacks infra or the URL" ;; esac
case "$(step_run lint 'Name a shellcheck release-host outage')" in *'curl -sSfIL '*) pass "outage probe follows the release redirect" ;; *) fail "outage probe does not follow redirects (-L)" ;; esac
n_pins="$(grep -o 'actions/cache@[0-9a-f]\{40\}' "$CI_YML" | sort -u | wc -l | tr -d ' ')"
if [ "$n_pins" -eq 1 ]; then pass "every actions/cache use is one sha pin"; else fail "actions/cache pins differ: $n_pins"; fi

SHFMT_CACHE="$(step_block shell-unit-shard 'Cache pinned shfmt')"
case "$SHFMT_CACHE" in *"uses: $CACHE_PIN"*"shfmt-"*'env.SHFMT_VER'*) pass "shell-unit shards cache the shfmt binary keyed on its version" ;; *) fail "no version-keyed shfmt cache step: $SHFMT_CACHE" ;; esac

SH_REC="$T/shfmt-rec.sh"; SH_RUN="$T/shfmt-run.sh"
step_run shell-unit-shard 'Record pinned shfmt version' > "$SH_REC"
step_run shell-unit-shard 'Put pinned shfmt on PATH' > "$SH_RUN"
mkdir -p "$T/shim"
cat > "$T/shim/curl" <<'SHIM'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CURL_LOG"
[ "${CURL_FAIL:-0}" = 1 ] && exit 22
while [ $# -gt 0 ]; do [ "$1" = -o ] && { printf 'fakeshfmt' > "$2"; exit 0; }; shift; done
exit 2
SHIM
chmod 755 "$T/shim/curl"
FAKESHA="$(printf fakeshfmt | sha256sum | cut -d' ' -f1)"
sed -E -i "s/^( *sha=)[0-9a-f]{64}\$/\1$FAKESHA/" "$SH_RUN"
run_shfmt() { # <seed: hit|bad|none> <curl fails: 0|1> -> OUT, RC; leaves CURL_LOG
  RT="$T/rt-shfmt"; rm -rf "$RT"; mkdir -p "$RT/shfmt-bin"
  : > "$T/ge"; : > "$T/gp"; CURL_LOG="$T/curl.log"; rm -f "$CURL_LOG"
  case "$1" in hit) printf fakeshfmt > "$RT/shfmt-bin/shfmt" ;; bad) printf corrupt > "$RT/shfmt-bin/shfmt" ;; esac
  [ "$1" = none ] || chmod 755 "$RT/shfmt-bin/shfmt"
  OUT="$(cd "$S" && RUNNER_TEMP="$RT" GITHUB_ENV="$T/ge" GITHUB_PATH="$T/gp" CURL_LOG="$CURL_LOG" CURL_FAIL="$2" PATH="$T/shim:$PATH" bash -e -c 'set -a; . "$0"; . "$1"' "$T/ge-src" "$SH_RUN" 2>&1)"; RC=$?
}
( cd "$S" && RUNNER_TEMP="$T/rt-rec" GITHUB_ENV="$T/ge-src" bash -e "$SH_REC" ) 2>/dev/null
if grep -qx 'SHFMT_VER=3.14.1' "$T/ge-src" 2>/dev/null; then pass "version-record step exports SHFMT_VER"; else fail "SHFMT_VER not recorded: $(cat "$T/ge-src" 2>/dev/null)"; fi

run_shfmt hit 1
if [ "$RC" -eq 0 ] && [ ! -e "$CURL_LOG" ]; then pass "shfmt cache hit: no call to GitHub releases"; else fail "hit -> rc=$RC curl-log=$(cat "$CURL_LOG" 2>/dev/null): $OUT"; fi
run_shfmt none 1
if [ "$RC" -ne 0 ] && [ -e "$CURL_LOG" ]; then pass "shfmt cache miss with the download down fails"; else fail "miss+down -> rc=$RC: $OUT"; fi
n_infra="$(printf '%s\n' "$OUT" | grep -c 'infra')"
case "$OUT" in *"https://github.com/mvdan/sh/releases/download/v3.14.1/shfmt_v3.14.1_linux_amd64"*) url_ok=1 ;; *) url_ok=0 ;; esac
if [ "$n_infra" -eq 1 ] && [ "$url_ok" -eq 1 ]; then pass "miss during an outage prints ONE infra line naming the URL"; else fail "infra line count=$n_infra url_ok=$url_ok: $OUT"; fi
run_shfmt none 0
if [ "$RC" -eq 0 ] && [ -x "$RT/shfmt-bin/shfmt" ] && grep -qx "$RT/shfmt-bin" "$T/gp"; then pass "shfmt cache miss with the host up downloads, verifies and puts it on PATH"; else fail "miss+up -> rc=$RC: $OUT"; fi
run_shfmt bad 0
if [ "$RC" -eq 0 ] && [ -e "$CURL_LOG" ]; then pass "a cached binary failing its sha256 is re-downloaded"; else fail "bad cache -> rc=$RC: $OUT"; fi
run_shfmt bad 1
case "$OUT" in *infra*) bad_infra=1 ;; *) bad_infra=0 ;; esac
if [ "$RC" -ne 0 ] && [ "$bad_infra" -eq 1 ] && [ "$(wc -l < "$CURL_LOG")" -ge 1 ]; then pass "a corrupt cached binary is never accepted when the download is down"; else fail "bad cache + down -> rc=$RC: $OUT"; fi

if [ "$failures" -eq 0 ]; then echo "== all passed =="; else echo "== $failures failed =="; fi
[ "$failures" -eq 0 ]
