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
printf '#!/usr/bin/env bash\necho suite-ok\n' > "$S/scripts/guardrails/test-lint-fail-open.sh"
printf 'pkg==1.0 --hash=sha256:abc\n' > "$S/requirements.txt"
printf 'x\n' > "$S/a.txt"
git -C "$S" add -A; git -C "$S" commit -q -m base
BASE="$(git -C "$S" rev-parse HEAD)"

run_step() { # <base sha> -> OUT, RC
  OUT="$(cd "$S" && BASE_SHA="$1" RUNNER_TEMP="$S/tmp" bash "$STEP" 2>&1)"; RC=$?
}
branch() { git -C "$S" checkout -q -B "$1" "$BASE"; }
commit() { git -C "$S" add -A; git -C "$S" commit -q -m "$1"; }
has() { printf '%s' "$OUT" | grep -qF -- "$1"; }

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

branch failopen; printf '#!/usr/bin/env bash\necho regression >&2\nexit 1\n' > "$S/scripts/guardrails/test-lint-fail-open.sh"; commit failopen
run_step "$BASE"
if [ "$RC" -ne 0 ]; then pass "PR breaking the fail-open lint suite fails"; else fail "failopen -> rc=$RC: $OUT"; fi

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

if [ "$failures" -eq 0 ]; then echo "== all passed =="; else echo "== $failures failed =="; fi
[ "$failures" -eq 0 ]
