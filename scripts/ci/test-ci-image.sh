#!/usr/bin/env bash
# scripts/ci/test-ci-image.sh -- the prebuilt CI image carries every
# tool ci.yml and gcp-runner-startup.sh install today, at the SAME pins, and its
# build workflow pushes to GHCR only when the Dockerfile changes.
#
# The expected package list and pins are read live from ci.yml, .bun-version and
# gcp-runner-startup.sh (the real environment), never retyped here, so a bump in
# one place that skips the Dockerfile fails this suite. Pure text assertions; no
# docker, no network.
#
# Usage: bash scripts/ci/test-ci-image.sh
# Exit codes: 0 -- all rows pass; 1 -- at least one fails.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CI_YML="${CI_YML:-$ROOT/.github/workflows/ci.yml}"
STARTUP="${STARTUP:-$ROOT/scripts/ci/gcp-runner-startup.sh}"
DOCKERFILE="${DOCKERFILE:-$ROOT/.github/ci-image/Dockerfile}"
WORKFLOW="${WORKFLOW:-$ROOT/.github/workflows/ci-image.yml}"
fails=0
ok()  { echo "ok - $1"; }
bad() { echo "FAIL - $1" >&2; fails=$((fails + 1)); }

if [ ! -f "$DOCKERFILE" ]; then
  bad "Dockerfile missing: ${DOCKERFILE#"$ROOT"/}"
  echo "$fails failed" >&2
  exit 1
fi
# dockerfile_text: the Dockerfile with full-line and trailing comments stripped, so a
# pin written only in a comment satisfies no row.
dockerfile_text() { sed -e '/^[[:space:]]*#/d' -e 's/[[:space:]]#.*$//'; }
df_text="$(dockerfile_text < "$DOCKERFILE")"
# the apt-get install stanza only: a package named by a later RUN line is not installed by apt.
apt_stanza() { awk '/apt-get install/ {f=1} f {print} f && !/\\$/ {exit}'; }
apt_text="$(apt_stanza <<< "$df_text")"
# has <token> [haystack]: the token as a whole word, so BUN_VERSION=1.4.3 does not match =1.4.30.
has() {
  local esc
  esc="$(printf '%s' "$1" | sed 's/[][\.*^$/]/\\&/g')"
  grep -Eq -- "(^|[[:space:]])${esc}([[:space:]\\\\=]|\$)" <<< "${2:-$df_text}"
}

# 1. every apt package ci.yml hands to apt-install.sh (version pin stripped to the name)
# apt_install_pkgs: the package names every apt-install.sh call on stdin passes, in a
# `run: |` body or a single-line `run:` alike.
apt_install_pkgs() {
  grep -E '^ +(- )?(run: )?bash \.github/scripts/apt-install\.sh ' \
    | sed -E "s/[[:space:]]#.*$//; s/^.*bash \.github\/scripts\/apt-install\.sh //; s/'//g" | tr ' ' '\n' | sed -E 's/=.*//' | grep -v '^$' | sort -u
}
ci_pkgs="$(apt_install_pkgs < "$CI_YML")"
[ -n "$ci_pkgs" ] || bad "no apt-install.sh packages found in ci.yml (parse failure)"
for p in $ci_pkgs; do
  if has "$p" "$apt_text"; then ok "Dockerfile installs ci.yml apt package $p"
  else bad "Dockerfile lacks ci.yml apt package $p"; fi
done

# 2. the GCP runner's apt list (gcp-runner-startup.sh), minus iptables (VM-only) and
#    nodejs/npm (the image ships the pinned nodejs.org build, row 5)
gcp_pkgs="$(grep -E '^apt-get install ' "$STARTUP" | sed -E 's/^apt-get install -y -qq //; s/ \|\|.*//' | tr ' ' '\n' | grep -vxE 'iptables|nodejs|npm' | sort -u)"
[ -n "$gcp_pkgs" ] || bad "no apt-get install list found in gcp-runner-startup.sh (parse failure)"
for p in $gcp_pkgs; do
  if has "$p" "$apt_text"; then ok "Dockerfile installs gcp-runner apt package $p"
  else bad "Dockerfile lacks gcp-runner apt package $p"; fi
done

# 3. the ffmpeg pin ci.yml uses for the HLS suite
ff_pin="$(grep -oE "ffmpeg=[^' ]+" "$CI_YML" | head -n 1)"
if [ -n "$ff_pin" ] && has "$ff_pin" "$apt_text"; then ok "Dockerfile carries ci.yml's ffmpeg pin $ff_pin"
else bad "Dockerfile lacks ci.yml's ffmpeg pin (${ff_pin:-none found})"; fi

# 4. bun: the version file the runners read
bun_ver="$(tr -d '[:space:]' < "$ROOT/.bun-version")"
if has "BUN_VERSION=${bun_ver}"; then ok "Dockerfile pins bun $bun_ver (.bun-version)"
else bad "Dockerfile does not pin BUN_VERSION=$bun_ver"; fi

# 5. pre-commit, and the node major ci.yml sets up
pc_pin="$(grep -oE 'pre-commit==[0-9.]+' "$CI_YML" | head -n 1)"
if [ -n "$pc_pin" ] && has "$pc_pin"; then ok "Dockerfile pins $pc_pin"
else bad "Dockerfile does not pin ${pc_pin:-pre-commit (none found in ci.yml)}"; fi
node_major="$(grep -oE "node-version: '[0-9]+'" "$CI_YML" | head -n 1 | grep -oE '[0-9]+')"
node_ver="$(sed -n 's/^ARG NODE_VERSION=//p' <<< "$df_text")"
if [ -n "$node_major" ] && [ "${node_ver%%.*}" = "$node_major" ] && grep -Eq '^ARG NODE_SHA256=[0-9a-f]{64}$' <<< "$df_text"; then
  ok "Dockerfile pins node $node_ver (major $node_major) with a sha256"
else bad "Dockerfile does not pin a node ${node_major:-?}.x NODE_VERSION with NODE_SHA256 (found ${node_ver:-none})"; fi

# 5a. the node patch level carries the 2026-10-21 security release (22.23.4)
if [ "$(printf '%s\n' 22.23.4 "$node_ver" | sort -V | head -n 1)" = "22.23.4" ]; then ok "Dockerfile node $node_ver is at or above the patched 22.23.4"
else bad "Dockerfile node ${node_ver:-none} is below the patched 22.23.4"; fi

# 5b. the base image is pinned by digest, not a mutable tag
if grep -Eq '^FROM [^[:space:]@]+@sha256:[0-9a-f]{64}$' <<< "$df_text"; then ok "Dockerfile FROM is pinned by @sha256: digest"
else bad "Dockerfile FROM is not pinned by @sha256: digest"; fi

# 6. gitleaks: the version and sha256 ci.yml verifies
gl_ver="$(grep -oE '^ +ver=[0-9.]+' "$CI_YML" | head -n 1 | sed 's/.*=//')"
gl_sha="$(grep -oE '^ +sha=[0-9a-f]{64}' "$CI_YML" | head -n 1 | sed 's/.*=//')"
if [ -n "$gl_ver" ] && [ -n "$gl_sha" ] && has "GITLEAKS_VERSION=${gl_ver}" && has "GITLEAKS_SHA256=${gl_sha}"; then
  ok "Dockerfile pins gitleaks $gl_ver with ci.yml's sha256"
else bad "Dockerfile does not pin gitleaks ${gl_ver:-?} / ${gl_sha:-?}"; fi

# 7. shellcheck-py at the rev the pre-commit config pins
sc_rev="$(awk '/repo:.*shellcheck-py/ {f=1; next} f && /rev:/ {sub(/^.*rev:[ ]*v?/, ""); print; exit}' "$ROOT/.pre-commit-config.yaml")"
if [ -n "$sc_rev" ] && has "shellcheck-py==${sc_rev}"; then ok "Dockerfile pins shellcheck-py $sc_rev"
else bad "Dockerfile does not pin shellcheck-py==${sc_rev:-?}"; fi

# 9. the parsers themselves, on inline fixtures: a single-line `run:` call is read,
#    and a pin that appears only in a comment satisfies nothing.
if apt_install_pkgs <<< "        run: bash .github/scripts/apt-install.sh fixture-pkg socat" | grep -qx fixture-pkg; then
  ok "parser reads a single-line run: apt-install.sh call"
else bad "parser misses a single-line run: apt-install.sh call"; fi
fx_df="$(printf '%s\n' 'FROM scratch' '# ARG BUN_VERSION=9.9.9' "RUN apt-get install -y \\" '      git # fixture-pkg')"
if has "BUN_VERSION=9.9.9" "$(dockerfile_text <<< "$fx_df")"; then bad "a pin written only in a Dockerfile comment satisfies has()"
else ok "a pin written only in a Dockerfile comment does not count"; fi
if has fixture-pkg "$(dockerfile_text <<< "$fx_df" | apt_stanza)"; then bad "a package named only in an apt-install comment satisfies has()"
else ok "a package named only in an apt-install comment does not count"; fi

# 8. the build workflow
if [ ! -f "$WORKFLOW" ]; then
  bad "build workflow missing: ${WORKFLOW#"$ROOT"/}"
else
  wf="$(grep -v '^ *#' "$WORKFLOW")"
  # wfrow <description> <ERE>...: every pattern must match a non-comment line.
  wfrow() {
    local desc="$1" pat
    shift
    for pat in "$@"; do
      if ! grep -Eq -- "$pat" <<< "$wf"; then bad "workflow: $desc"; return; fi
    done
    ok "workflow: $desc"
  }
  wfrow "builds on push to main when .github/ci-image/** changes" '^    paths:' '\.github/ci-image/\*\*' 'branches: \[main\]'
  wfrow "has a weekly schedule" '^  schedule:' 'cron:'
  wfrow "has workflow_dispatch" 'workflow_dispatch'
  wfrow "tags :<sha> and :latest" 'IMAGE: ghcr\.io/[$][{][{] *github\.repository_owner *[}][}]/himmel-ci( #.*)?$' '[$]IMAGE:[$][{][{] *github\.sha *[}][}]' '[$]IMAGE:latest'
  wfrow "IMAGE line carries env-literal-ok so the base copy of the env-value lint accepts it" 'IMAGE: ghcr\.io/.* # env-literal-ok: [^ ]'
  wfrow "permissions are packages:write + contents:read" '^  packages: write' '^  contents: read'
  wfrow "job runs only on main of the real repo" "^    if: .*github\.repository == 'yotamleo-org/Himmel'.*github\.ref == 'refs/heads/main'"
  wfrow "job has timeout-minutes" 'timeout-minutes:'
  if grep -q 'pull_request' <<< "$wf"; then bad "workflow must not trigger on pull_request (no push from a fork PR)"
  else ok "workflow does not trigger on pull_request"; fi
fi

# 10. tools the suites call that a GitHub-hosted runner carries and ci.yml never
#     installs, so a container without them fails or SKIPs rows: bison + gcc +
#     libc6-dev build the bwk awk, cron gives crontab, zsh the escape-corpus zsh
#     shapes, shfmt the bash-ast engine, uv check-uv-lock, python-is-python3 the
#     bare `python` the obsidian-triage suites call, python3-yaml the PyYAML a
#     suite imports, jq 1.8 the bash-ast engine's jq programs (jq 1.7 rejects an
#     object value that is a bare binary expression). Each is installed and
#     smoke-checked.
for p in bison gcc libc6-dev cron zsh python-is-python3 python3-yaml; do
  if has "$p" "$apt_text"; then ok "Dockerfile installs suite tool package $p"
  else bad "Dockerfile lacks suite tool package $p"; fi
done
if has 'zsh=5.9-*' "$apt_text"; then ok "Dockerfile pins zsh 5.9"
else bad "Dockerfile does not pin zsh=5.9-*"; fi
if grep -Eq '^ARG JQ_VERSION=(1\.([89]|[1-9][0-9])|[2-9]|[1-9][0-9]+)(\.[0-9]+)*$' <<< "$df_text"; then
  ok "Dockerfile pins jq 1.8 or later"
else bad "Dockerfile pins no jq 1.8 or later (the bash-ast jq programs do not compile on 1.7)"; fi
if grep -Fq "jq -n '{a: [1] + [2]}'" <<< "$df_text"; then ok "Dockerfile build compiles a bare binary-expression object value with jq"
else bad "Dockerfile build does not check that jq compiles {a: [1] + [2]}"; fi
for v in SHFMT UV JQ; do
  if grep -Eq "^ARG ${v}_VERSION=[0-9.]+$" <<< "$df_text" && grep -Eq "^ARG ${v}_SHA256=[0-9a-f]{64}$" <<< "$df_text"; then
    ok "Dockerfile pins ${v}_VERSION with a sha256"
  else bad "Dockerfile does not pin ${v}_VERSION with ${v}_SHA256"; fi
  if grep -Eq "curl -fsSL -o [^ ]+ \"https://github\.com/[^\"]*[$][{]${v}_VERSION[}]" <<< "$df_text"; then
    ok "Dockerfile downloads the pinned ${v}_VERSION from github.com"
  else bad "Dockerfile does not download the pinned ${v}_VERSION from github.com"; fi
  if grep -Eq "echo \"[$][{]${v}_SHA256[}]  [^\"]+\" [|] sha256sum -c -" <<< "$df_text"; then
    ok "Dockerfile checks ${v}_SHA256 with sha256sum -c"
  else bad "Dockerfile does not check ${v}_SHA256 with sha256sum -c"; fi
done
if grep -E 'tar -x[a-z]*f /tmp/uv\.tgz' <<< "$df_text" | grep -q -- '--no-same-owner'; then
  ok "Dockerfile untars uv with --no-same-owner"
else bad "Dockerfile untars uv keeping the archive owner (no --no-same-owner)"; fi
smoke="$(grep -oE 'for t in [^;]+' "$WORKFLOW" 2>/dev/null | head -n 1)"
for t in bison gcc crontab shfmt uv zsh python; do
  if has "$t" "$smoke"; then ok "workflow smoke-checks $t"
  else bad "workflow smoke list lacks $t"; fi
done
if grep -v '^ *#' "$WORKFLOW" 2>/dev/null | grep -Fq 'python -c "import yaml"'; then ok "workflow smoke-checks the PyYAML import"
else bad "workflow does not smoke-check import yaml"; fi

[ "$fails" -eq 0 ] && { echo "all passed"; exit 0; }
echo "$fails failed" >&2
exit 1
