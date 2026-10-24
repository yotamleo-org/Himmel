# shellcheck shell=bash
# shellcheck disable=SC2034 # the suites that source this read what it assigns
# scripts/lib/adopt-test-fixture.sh — the fixture scripts/test-adopt.sh and
# scripts/test-adopt-features.sh both source: helpers, the throwaway $work dir,
# the stubbed claude, the jira dist/.env backup + restore trap, the hermetic PATH
# and the state the adopt.sh scenarios share (base_home, pchome, the pre-commit
# stub in pcbin, native_free_path). Sourced by a suite that has already run
# `set -euo pipefail`; it runs no scenario of its own.

# grepq <text> [grep-args...] — a `grep -q` test against <text> with NO
# pipeline. printf/echo-into-`grep -q` is a trap under this file's
# `set -o pipefail`: grep -q exits the instant it matches, the producer
# then takes SIGPIPE writing the remainder, and pipefail reports the
# PIPELINE as failed — so a SUCCESSFUL match returns non-zero whenever
# the match lands early in a large input. A here-string is not a pipeline,
# so the status is grep's own verdict alone.
grepq() { local _t="$1"; shift; grep -q "$@" <<< "$_t"; }

# dir_is_empty <dir> — true (rc 0) iff <dir> has no entries, dotfiles
# included, using only bash builtins/globs -- no `ls`.
# round-2: under the hermetic PATH built below, `ls` is NOT guaranteed
# reachable -- scrub_path() drops a PATH directory WHOLESALE to remove a
# named tool, and on a box where `ls` shares a directory with one of the
# scrubbed tools (e.g. /usr/bin holding node/npm/uv/bun), `ls` goes with it.
# A missing `ls` makes `[ -z "$(ls -A "$dir")" ]` evaluate `[ -z "" ]` --
# TRUE no matter what is actually in the directory, silently turning a
# containment assertion into one that can never fail (already hit 3x per
# scripts/lib/hermetic-path.sh:). Without `nullglob`
# an unmatched glob stays literal, so an unmatched literal must still be
# filtered out -- but `[ -e "$f" ]` ALONE follows a symlink to test its
# TARGET, so a DANGLING symlink (an unmatched-glob false positive's exact
# opposite: a real directory entry whose target does not exist) is `-e`
# false and was silently skipped, reporting an occupied directory as empty
# (this is what let the
# round-5 cr2771r5-symlink-dangling control's whole subject, a dangling
# symlink, slip past this assertion undetected). `[ -L "$f" ]` sees the
# LINK ITSELF regardless of what it points at (or fails to), so an
# unmatched literal is still excluded (no entry is ever a symlink) while a
# genuine dangling entry now counts. "." and ".." are excluded by
# construction (.[!.]* skips them, ..?* only matches a dotfile whose name
# is LONGER than "..").
dir_is_empty() {
  local d="$1" f
  for f in "$d"/* "$d"/.[!.]* "$d"/..?*; do
    { [ -e "$f" ] || [ -L "$f" ]; } || continue
    return 1
  done
  return 0
}

repo_root=$(git rev-parse --show-toplevel)
adopt="$repo_root/scripts/adopt.sh"
[ -f "$adopt" ] || { echo "FAIL: $adopt not found" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "FAIL: jq required" >&2; exit 1; }

fail() { echo "FAIL: $1" >&2; exit 1; }

# Normalize a path the same way wire-luna-vault.sh stores it: passing a path as a
# jq arg triggers MSYS POSIX->Windows path mangling on Git-Bash (e.g.
# /tmp/x -> C:/Users/.../x) and is an identity on Linux. Normalizing the EXPECTED
# value through the same jq hop makes the LUNA_VAULT_PATH assertions below
# cross-platform without hard-coding either path form.
norm() { jq -rn --arg v "$1" '$v'; }

work=$(mktemp -d) || exit 1 # prim-ok: test fixture shared by the adopt suites, cleaned by the trap below
# adopt.sh records what it installs; keep every run out of the real
# provenance ledger under ~/.himmel (individual cases below pin their own ledger).
export HIMMEL_PROVENANCE_DIR="$work/prov"

# scripts/jira/dist + scripts/jira/node_modules are
# gitignored build artifacts that MAY already exist in this checkout (a primary
# checkout that has run adopt.sh/setup.sh before). build_jira_cli's "already
# built" skip fires the instant either is present, which would make scenarios
# 14-19 below assert on the WRONG branch. Move any existing dist/node_modules
# aside for the whole suite and restore unconditionally on exit — mirrors the
# real_jira_dist/dist_backup + trap cleanup EXIT pattern in
# scripts/test-preflight-adopter.sh.
real_jira_dist="$repo_root/scripts/jira/dist"
real_jira_node_modules="$repo_root/scripts/jira/node_modules"
dist_backup=""
node_modules_backup=""
if [ -e "$real_jira_dist" ]; then
  dist_backup="$work/dist-backup"
  mv "$real_jira_dist" "$dist_backup"
fi
if [ -e "$real_jira_node_modules" ]; then
  node_modules_backup="$work/node_modules-backup"
  mv "$real_jira_node_modules" "$node_modules_backup"
fi
# The repo-.env-preserve scenario below temporarily
# writes a HANDOVER_DIR= line into THIS repo's real .env ($HIMMEL_ROOT is
# resolved by adopt.sh from its own script path — not overridable via HOME —
# so there is no fake-checkout stand-in for it). Declared here, set only at
# the point of mutation, and restored unconditionally in cleanup() — same
# backup-then-trap-restore shape as the jira dist/node_modules pair above, so
# a `fail()` (which exits immediately) mid-scenario can never strand a
# mutated .env in the real worktree.
real_env="$repo_root/.env"
env_backup=""
env_mutated=0
cleanup() {
  rm -rf "$real_jira_dist" "$real_jira_node_modules"
  if [ -n "$dist_backup" ]; then mv "$dist_backup" "$real_jira_dist"; fi
  if [ -n "$node_modules_backup" ]; then mv "$node_modules_backup" "$real_jira_node_modules"; fi
  if [ -n "$env_backup" ]; then
    mv "$env_backup" "$real_env"
  elif [ "$env_mutated" -eq 1 ]; then
    rm -f "$real_env"
  fi
  rm -rf "$work"
}
trap cleanup EXIT

# Stub claude so adopt's install-plugins step is a no-op. `plugin list` must echo
# the enabled plugin specs so install-plugins.sh's presence-verify
# passes offline — without it `set -e` aborts adopt at the first core install.
mkdir -p "$work/bin"
cat > "$work/bin/claude" <<STUB
#!/usr/bin/env bash
if [ "\$1" = "plugin" ] && [ "\$2" = "list" ]; then
  jq -r '.enabledPlugins | keys[]' "$repo_root/docs/setup/settings-template.json"
fi
exit 0
STUB
chmod +x "$work/bin/claude"

# shellcheck source=lib/hermetic-path.sh
# shellcheck disable=SC1091
. "$repo_root/scripts/lib/hermetic-path.sh"

# xargs: Arch co-locates node with coreutils in /usr/bin, so the toolchain
# scrub drops it (same class as the sed fix).
for _tool in bash git jq python3 grep sed cat cp mv rm ln mkdir chmod diff wc tr head tail basename dirname mktemp dd sort cut xargs; do
  link_hermetic_tool "$_tool"
done
# adopt.sh records what it installs; provenance.sh (and copy_recorded's
# cmp) need these under the scrubbed PATH, or every record warns instead of writing.
for _tool in date stat uname id awk cmp find; do
  link_hermetic_tool "$_tool"
done
if command -v sha256sum >/dev/null 2>&1; then link_hermetic_tool sha256sum; else link_hermetic_tool shasum; fi

# Derive the expected suffix from an INDEPENDENT platform probe, never from
# HERMETIC_EXE_SUFFIX — the very variable link_hermetic_tool writes with.
# Reusing the writer's value makes this test tautological: if the detection in
# hermetic-path.sh regressed to an empty suffix, the writer would emit
# extensionless stubs, the expectation below would ALSO go extensionless and
# still match, and the rejection branch would be skipped by its own
# [ -n ... ] guard. The test could then never fail.
case "$(uname -s 2>/dev/null || echo unknown)" in
  MINGW*|MSYS*|CYGWIN*|Windows_NT*) hermetic_suffix='.exe' ;;
  *)                                hermetic_suffix='' ;;
esac
[ -f "$work/bin/bash$hermetic_suffix" ] || fail "link_hermetic_tool self-test: platform-named bash stub was not created"
# `find` with a literal -name match is REQUIRED here; do not "simplify" this to
# [ -e "$work/bin/bash" ]. On MSYS/Git-Bash, test -e resolves bash -> bash.exe,
# so the plain file test reports an extensionless stub that does not exist and
# this check fires on every healthy Windows run. find matches real directory
# entries and does not do the .exe fallback. A reviewer proposed the
# [ -e ]/[ -L ] form on portability grounds; the premise is wrong -- BSD find
# does support -maxdepth -- and the replacement breaks the suite on Windows.
# Verified live: swapping it made the green baseline fail.)
if [ -n "$hermetic_suffix" ] && [ -n "$(find "$work/bin" -maxdepth 1 -name bash -print -quit)" ]; then
  fail "link_hermetic_tool self-test: extensionless bash stub was created on Windows"
fi

# ── unit test: link_hermetic_tool's two failure-fallback branches ──
# Force `ln -s` to fail deterministically (a stub `ln` fronting PATH — the
# function calls bare `ln`, so it resolves via PATH) and assert both
# fallbacks: the wrapper-script proxy (any non-bash tool, here jq) and the
# copy fallback (bash, finding 1 above). Uses an isolated dest dir (the
# function's optional 2nd arg) so it can't disturb the suite's real
# $work/bin; the PATH= prefix is scoped to each function call only.
ut="$work/ut-link"; mkdir -p "$ut/bin" "$ut/stub"
printf '#!/usr/bin/env bash\nexit 1\n' > "$ut/stub/ln"; chmod +x "$ut/stub/ln"

PATH="$ut/stub:$PATH" link_hermetic_tool jq "$ut/bin"
[ -f "$ut/bin/jq$hermetic_suffix" ] || fail "link_hermetic_tool self-test: wrapper-fallback did not create jq wrapper"
[ -x "$ut/bin/jq$hermetic_suffix" ] || fail "link_hermetic_tool self-test: jq wrapper is not executable"
"$ut/bin/jq$hermetic_suffix" --version >/dev/null 2>&1 || fail "link_hermetic_tool self-test: jq wrapper does not proxy correctly"

PATH="$ut/stub:$PATH" link_hermetic_tool bash "$ut/bin"
[ -f "$ut/bin/bash$hermetic_suffix" ] || fail "link_hermetic_tool self-test: bash copy-fallback did not create bash"
[ -x "$ut/bin/bash$hermetic_suffix" ] || fail "link_hermetic_tool self-test: bash copy is not executable"
[ "$("$ut/bin/bash$hermetic_suffix" -c 'echo ok')" = "ok" ] || fail "link_hermetic_tool self-test: bash copy-fallback produced a non-working bash"
echo "ok: link_hermetic_tool wrapper-fallback (jq) + bash copy-fallback verified under forced ln failure"

# Hermeticity: scrub every dir carrying a real qmd, bun, npm,
# node, uv, or pipx from the suite-wide PATH. With bun absent, wire_qmd_core
# takes its documented clean-skip branch, so NO test can fire a real
# fix-qmd-stub (~/.claude mutation), a real `qmd pull` (~2.1 GB), or a real
# collection registration on a dev box that has the toolchain installed. Tests
# 10/11 re-add their own stubbed bun on top of this scrubbed base to exercise
# the qmd path.
#
# ALSO scrub npm dirs (node + npm share a bin dir, so this drops
# real node too). With npm AND bun both absent suite-wide, build_jira_cli takes
# its "no npm or bun - skipping build" branch, so NO test fires a real
# `npm install` in scripts/jira (network + repo mutation). Tests 14/15 re-add a
# stubbed npm on top of this scrubbed base to exercise the build path; 12/13
# re-add a stubbed node (and 13 a stubbed bun) for the npm-less-node preflight.
#
# Factored out (scripts/lib/hermetic-path.sh) so the exact scrub logic can
# also run over a synthetic PATH (self-test below) without touching the
# suite's real PATH.
#
# The himmelctl wizard + shim suites appended at the bottom
# need a REAL node — they shell out to bin.js — so they cannot run under the
# scrubbed PATH below. Capture the pre-scrub environment PATH here and pass it
# to each of those suites explicitly.
# pip bootstrap must stay offline while real Python still handles
# the adopter's JSON/file operations.
real_python3=$(command -v python3)
rm -f "$work/bin/python3"
cat > "$work/bin/python3" <<STUB
#!/usr/bin/env bash
if [ "\$1" = "-m" ] && [ "\$2" = "pip" ]; then
  echo 'pip unavailable in offline test fixture' >&2
  exit 1
fi
exec "$real_python3" "\$@"
STUB
chmod +x "$work/bin/python3"

# wire-statusline.sh drops the hud config under
# ${CLAUDE_CONFIG_DIR:-$HOME/.claude}. Every case here already fakes HOME, but a
# RUNNER that exports CLAUDE_CONFIG_DIR would win over that and take the drop to
# their real config dir — pin it at a throwaway dir for the whole suite.
export CLAUDE_CONFIG_DIR="$work/claude-config"

saved_path="$PATH"
qmd_free_path=$(scrub_path "$PATH" qmd bun npm node uv pipx)
export PATH="$work/bin:$qmd_free_path"
PATH="$work/bin" command -v bash >/dev/null 2>&1 \
  || fail "hermetic stub dir must provide bash even if every scrubbed dir is removed"
for _tool in qmd bun npm node uv pipx; do
  if command -v "$_tool" >/dev/null 2>&1; then
    fail "hermetic PATH leaked $_tool: $(command -v "$_tool")"
  fi
done

base_home="$work/home-base"; mkdir -p "$base_home"
pcbin="$work/pcbin"; mkdir -p "$pcbin"
pchome="$work/pchome"; mkdir -p "$pchome"
# A stub `pre-commit` in a dedicated $pcbin dir (put FIRST on PATH, ahead of
# any real pre-commit the dev box might have installed via pipx/uv outside
# the qmd/bun/npm/node/uv/pipx scrub list) logs its argv to a file and exits
# 0 or 1 on demand — this proves adopt.sh actually shells out to `pre-commit
# install ...` against $TARGET, not just that it prints a message. Scoped to
# the scenarios that need it (PATH= prefix per invocation, never exported) so
# the stub can never leak into an earlier scenario or run against a real repo —
# every $TARGET is a disposable temp dir the scenario git-inits itself.
cat > "$pcbin/pre-commit" <<STUB
#!/usr/bin/env bash
echo "\$*" >> "$work/pre-commit.argv"
exit 0
STUB
chmod +x "$pcbin/pre-commit"
native_free_path=$(scrub_path "$qmd_free_path" pre-commit uv pipx)
