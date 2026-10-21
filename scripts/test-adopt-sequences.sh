#!/usr/bin/env bash
# test-adopt-sequences.sh — seeded install/uninstall SEQUENCE driver
# The per-step suites (test-adopt.sh, test-uninstall*.sh) prove
# each step alone; install-sequence bugs only show when steps are chained. This suite chains adopt / adopt --scope project /
# uninstall / uninstall --purge-state / adopt-with-failure-at-step-k on a
# fixture HOME + project and asserts, after EVERY step:
#   - after an uninstall the fixture equals its pre-install snapshot (the
#     ALLOWLIST aside) and the rc is non-zero iff something remains;
#   - after a (non-injected) adopt, `himmelctl status` has no red row and
#     the doctor install checks are green.
#
# Verbs in a sequence:  A  adopt --scope user      P  adopt --scope project
#   U  uninstall       X  uninstall --purge-state   W  uninstall that must
#   exit 0   N  (first verb) seed an explicit-null hooks container   T  corrupt
#   the backups of that null   S  strict mode (no known-residue tolerance)
#   D  claude stub stops declaring marketplaces in settings   B  stray file
#   (control row)   F<k>  adopt --scope user with the kth `claude` call failing.
#
# KNOWN-RED rows (xfail): a sequence tagged with a ticket key pins a defect
# that is live at head. It must FAIL the contract (that is the expected
# result); if it PASSES (XPASS) the suite fails and names the ticket — the fix
# PR promotes the row by deleting its tag.
#
# Fixture HOME only: every sequence runs under its own mktemp HOME with a
# hermetic PATH (only the fixture bin: no host tool such as qmd, node, pre-commit, at or crontab, so the result is the same on a workstation and a CI runner) and
# a stateful pure-bash `claude` stub. Sequences run in parallel (<=8 at once).
#
# Usage: bash scripts/test-adopt-sequences.sh [--seed N] [--break-restore]
#   --seed N         seed for the generated sequences (default 6626)
#   --only ID        run just that sequence
#   --seq "A U ..."  run one ad-hoc sequence of verbs
#   --keep DIR      build the fixtures in DIR and leave them (debugging)
#   --break-restore  RED control: sabotage the restore in the control row so
#                    it must fail a green row (not part of the normal run)
#   SEQ_BUDGET_SECS  wall-clock budget in seconds (default 120, 640 when CI is set)
#   --check-budget E  exit 0 iff elapsed E seconds is within the budget
set -u

R="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# wall-clock budget: 120 s on a workstation; the shared CI runner measured 191-198 s, and up to 319 s under load on 2026-10-21, so CI gets 640 s (2x the loaded measurement)
CI_BUDGET=640
BUDGET="${SEQ_BUDGET_SECS:-$([ -n "${CI:-}" ] && echo "$CI_BUDGET" || echo 120)}"
SEED=6626
BREAK=0
ONLY=
KEEP=
ADHOC=
CHECK=
while [ $# -gt 0 ]; do
  case "$1" in
    --seed)
      SEED="${2:?}"
      case "$SEED" in *[!0-9]*) echo "--seed needs a decimal number" >&2; exit 2 ;; esac
      SEED=$((10#$SEED)); shift 2 ;;
    --only) ONLY="${2:?}"; shift 2 ;;
    --keep) KEEP="${2:?}"; shift 2 ;;
    --seq) ADHOC="${2:?}"; shift 2 ;;
    --break-restore) BREAK=1; shift ;;
    --check-budget) CHECK="${2:?}"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done
# --check-budget <elapsed>: exit 0 iff that elapsed time is within the budget
# (SEQ_BUDGET_SECS when set, else the CI budget); runs without the 5-minute suite
within_budget() { [ "$1" -le "$2" ]; }
[ -z "$CHECK" ] || { within_budget "$CHECK" "${SEQ_BUDGET_SECS:-$CI_BUDGET}"; exit $?; }

fail() { echo "FAIL: $*" >&2; exit 1; }
# shellcheck source=lib/hermetic-path.sh
. "$R/scripts/lib/hermetic-path.sh"

ORIG_PATH="$PATH"
REALNODE="$(command -v node || true)"
[ -n "$REALNODE" ] || fail "node is required (himmelctl status runs under it)"
if [ -n "$KEEP" ]; then TMP="$KEEP"; mkdir -p "$TMP"; else TMP="$(mktemp -d "${TMPDIR:-/tmp}/adopt-sequences.XXXXXX")" || exit 1; fi
[ -n "$KEEP" ] || trap 'rm -rf "$TMP"' EXIT

# Paths whose presence after an uninstall is NOT a defect: the provenance
# ledger and its backups are the uninstall's own record.
ALLOWLIST_RE='^(home/\.himmel(/|$)|home/\.claude/himmel(/|$)|home/\.claude/plugins(/|$)|.*\.himmel-uninstall-backup$)'

# ── the stateful claude stub ────────────────────────────────────────────────
write_stub() { # $1 = bin dir
  cat > "$1/claude" <<'STUB_EOF'
#!/usr/bin/env bash
# Stateful pure-bash `claude plugin ...` stub. State lives in $STUB_STATE:
# plugins.json [{id,scope,projectPath?}], marketplaces.json [{name,scope}].
# `marketplace add` declares extraKnownMarketplaces[name] in the scope's
# settings.json, `plugin install` writes enabledPlugins[spec]=true there, and
# `marketplace remove` of a marketplace the scope's settings do not declare
# fails ("not declared in <scope> settings"), as the real CLI does.
set -u
st="$STUB_STATE"
n=$(( $(cat "$st/calls" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$st/calls"
printf '%s\n' "$*" >> "$st/log"
if [ -n "${STUB_FAIL_AT:-}" ] && [ "$n" -eq "$STUB_FAIL_AT" ]; then
  echo "$n" > "$st/injected"
  echo "stub: injected failure at call $n" >&2; exit 1
fi
[ -s "$st/plugins.json" ] || echo '[]' > "$st/plugins.json"
[ -s "$st/marketplaces.json" ] || echo '[]' > "$st/marketplaces.json"
settings_for() { # scope -> settings.json path
  case "$1" in user) echo "$HOME/.claude/settings.json" ;; *) echo "$PWD/.claude/settings.json" ;; esac
}
scope_of() { # last --scope value among args
  local s=user a prev=""
  for a in "$@"; do [ "$prev" = --scope ] && s="$a"; prev="$a"; done
  echo "$s"
}
jedit() { local f="$1"; shift; mkdir -p "$(dirname "$f")"; [ -s "$f" ] || echo '{}' > "$f"; jq "$@" "$f" > "$f.stub" && mv "$f.stub" "$f"; }
write_installed() { # installed_plugins.json twin of plugins.json
  mkdir -p "$HOME/.claude/plugins"
  jq --arg ip "$HOME/.claude/plugins" '{version:2, plugins:(reduce .[] as $p ({}; .[$p.id] += [{scope:$p.scope, installPath:$ip} + (if $p.projectPath then {projectPath:$p.projectPath} else {} end)]))}' "$st/plugins.json" > "$HOME/.claude/plugins/installed_plugins.json"
}
case "${1:-} ${2:-} ${3:-}" in
  "plugin list --json") cat "$st/plugins.json" ;;
  "plugin list "*) jq -r '.[] | "  ❯ \(.id)  (\(.scope))"' "$st/plugins.json" ;;
  "plugin marketplace list")
    if [ "${4:-}" = --json ]; then cat "$st/marketplaces.json"; else jq -r '.[] | "  \(.name)"' "$st/marketplaces.json"; fi ;;
  "plugin marketplace add")
    src="$4"; scope="$(scope_of "$@")"
    case "$src" in
      */marketplace) name=himmel ;;
      *) name="$(jq -r --arg s "$src" '.extraKnownMarketplaces | to_entries[] | select((.value.source | .repo // .url // .path // "") == $s) | .key' "$STUB_TEMPLATE" | head -1)"
         [ -n "$name" ] || name="$(basename "$src" .git)" ;;
    esac
    if ! jq -e --arg n "$name" --arg s "$scope" 'any(.[]; .name==$n and .scope==$s)' "$st/marketplaces.json" >/dev/null; then
      jq --arg n "$name" --arg s "$scope" '. + [{name:$n,scope:$s}]' "$st/marketplaces.json" > "$st/m.next" && mv "$st/m.next" "$st/marketplaces.json"
    fi
    if [ "${STUB_UNDECLARED:-0}" != 1 ]; then
      jedit "$(settings_for "$scope")" --arg n "$name" --arg s "$src" '.extraKnownMarketplaces[$n] = (.extraKnownMarketplaces[$n] // {source:{source:"stub",url:$s}})'
    fi
    echo "Marketplace '$name' added" ;;
  "plugin marketplace remove")
    name="$4"; scope="$(scope_of "$@")"
    if ! jq -e --arg n "$name" '.extraKnownMarketplaces[$n] // empty' "$(settings_for "$scope")" >/dev/null 2>&1; then
      echo "Marketplace '$name' is not declared in $scope settings" >&2; exit 1
    fi
    jedit "$(settings_for "$scope")" --arg n "$name" 'del(.extraKnownMarketplaces[$n])'
    jq --arg n "$name" --arg s "$scope" '[.[] | select(.name!=$n or .scope!=$s)]' "$st/marketplaces.json" > "$st/m.next" && mv "$st/m.next" "$st/marketplaces.json" ;;
  "plugin install "*)
    spec="$3"; scope="$(scope_of "$@")"
    if ! jq -e --arg i "$spec" --arg s "$scope" 'any(.[]; .id==$i and .scope==$s)' "$st/plugins.json" >/dev/null; then
      jq --arg i "$spec" --arg s "$scope" --arg p "$PWD" '. + [{id:$i,scope:$s} + (if $s=="project" then {projectPath:$p} else {} end)]' "$st/plugins.json" > "$st/p.next" && mv "$st/p.next" "$st/plugins.json"
    fi
    jedit "$(settings_for "$scope")" --arg i "$spec" '.enabledPlugins[$i] = true'
    write_installed ;;
  "plugin uninstall "*)
    spec="$3"; scope="$(scope_of "$@")"
    jq --arg i "$spec" --arg s "$scope" '[.[] | select(.id!=$i or .scope!=$s)]' "$st/plugins.json" > "$st/p.next" && mv "$st/p.next" "$st/plugins.json"
    jedit "$(settings_for "$scope")" --arg i "$spec" 'del(.enabledPlugins[$i])'
    write_installed ;;
  *) exit 0 ;;
esac
STUB_EOF
  chmod 755 "$1/claude" || return 1
}

# ── fixture ─────────────────────────────────────────────────────────────────
# new_fixture <dir>: HOME + project + hermetic bin, holding operator state the
# restore must give back.
new_fixture() {
  local d="$1" t
  mkdir -p "$d/home/.claude" "$d/proj/.claude" "$d/bin" "$d/state"
  for t in bash git jq python3 grep sed cat cp mv rm ln mkdir chmod diff wc tr head tail \
           basename dirname mktemp dd sort cut xargs date stat uname id awk cmp find \
           sha256sum readlink env ls; do
    link_hermetic_tool "$t" "$d/bin"
  done
  write_stub "$d/bin" || return 1
  printf '{"env":{"OPERATOR_KEY":"keep"},"model":"opus"}\n' > "$d/home/.claude/settings.json"
  printf '# operator notes\nkeep me\n' > "$d/home/.claude/CLAUDE.md"
  printf '{"permissions":{"allow":["Bash(ls:*)"]}}\n' > "$d/proj/.claude/settings.json"
  git -C "$d/proj" init -q -b main || return 1
  git -C "$d/proj" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init || return 1
  printf '#!/bin/sh\n# foreign hook\nexit 0\n' > "$d/proj/.git/hooks/pre-commit"
  chmod 755 "$d/proj/.git/hooks/pre-commit" || return 1
}

# snapshot <X> <out>: type+mode+symlink target+path for everything under home/ and proj/,
# plus sha256 of each file; proj/.git is limited to hooks/ and config.
snapshot() {
  ( cd "$1" || exit 1
    find home proj -mindepth 1 \
      \( -path 'proj/.git/*' ! -path 'proj/.git/hooks' ! -path 'proj/.git/hooks/*' ! -path 'proj/.git/config' \) -prune \
      -o -type d \
      -o -printf '%y %m %l %p\n' | sort -k3
    find home proj -type f \
      \( -path 'proj/.git/*' ! -path 'proj/.git/hooks' ! -path 'proj/.git/hooks/*' ! -path 'proj/.git/config' \) -prune \
      -o -type f -exec sha256sum {} + | sort -k2 ) > "$2"
}

# Compare JSON values, not formatting; strict mode tolerates no leftover keys.
norm_settings() {
  jq -S --argjson strict "$STRICT" '
    if $strict == 1 then . else
      (if .enabledPlugins then .enabledPlugins |= with_entries(select(.value != false)) else . end
       | if .enabledPlugins == {} then del(.enabledPlugins) else . end
       | if .extraKnownMarketplaces == {} then del(.extraKnownMarketplaces) else . end)
    end' "$1" 2>/dev/null || cat "$1"
}

# remaining <X> <before> -> prints the paths that differ from the pre-install snapshot, allowlist aside
remaining() {
  local d="$1" after="$1/snap.now" p pre
  snapshot "$d" "$after"
  if [ ! -s "$2" ] || [ ! -s "$after" ]; then echo "snapshot-unreadable"; return; fi
  diff "$2" "$after" > "$d/snap.diff"
  if [ "$?" -gt 1 ]; then echo "snapshot-diff-failed"; return; fi
  grep -E '^[<>]' "$d/snap.diff" | awk '{print $NF}' | sort -u | grep -vE "$ALLOWLIST_RE" | while IFS= read -r p; do
    if [ "$STRICT" -ne 1 ]; then
      [ "$p" = home/.claude/.i-have-adhd-always ] && continue
      [ "$p" = proj/.gitignore ] && [ "$(cat "$d/$p")" = ".claude/worktrees/" ] && continue
    fi
    case "$p" in
      home/.claude/settings.json) pre="$d/pre/home-settings.json" ;;
      proj/.claude/settings.json) pre="$d/pre/proj-settings.json" ;;
      *) pre="" ;;
    esac
    if [ -n "$pre" ] && [ -f "$d/$p" ] && [ ! -L "$d/$p" ] \
        && [ "$(stat -c %a "$pre" 2>/dev/null || stat -f %Lp "$pre")" = "$(stat -c %a "$d/$p" 2>/dev/null || stat -f %Lp "$d/$p")" ] \
        && [ "$(norm_settings "$pre")" = "$(norm_settings "$d/$p")" ]; then continue; fi
    echo "$p"
  done || true
}

# ── verbs ───────────────────────────────────────────────────────────────────
# Each verb appends one line per assertion to $X/rows: "ok <what>" / "bad <what>".
row() { echo "$1 $2" >> "$X/rows"; }

fixture_env() {
  export HOME="$X/home" CLAUDE_CONFIG_DIR="$X/home/.claude" STUB_STATE="$X/state" STUB_TEMPLATE="$R/docs/setup/settings-template.json"
  export PATH="$X/bin"
  unset HIMMEL_PROVENANCE_DIR STUB_FAIL_AT STUB_UNDECLARED
}

# graphify, rtk, the hermes checkout and lanes, bun, uv, gitleaks, shellcheck, gh, the scheduler backend, npm and the built jira CLI are host tools adopt neither writes nor
# removes, and a CI runner lacks them; codex-cli "never provisioned" is the fixture's missing codex
# cache. Every other red stays.
status_unexpected_red() { # <status output>: the red lines that are not a host tool
  grep -E '(^|[[:space:]])red([[:space:]]|$)' "$1" | grep -vE '(^|[[:space:]])red[[:space:]]+(graphify|hermes-checkout|hermes-lanes|rtk|jira-cli-dist-build|bun|uv|gitleaks|shellcheck|gh|scheduler-backend|npm-less-node)([[:space:]]|$)'
}
doctor_unexpected_item() { # <doctor output>: the bullet items that are not a host tool or codex-cli
  grep -E '^ +· ' "$1" | grep -vE '^ +· (red/graphify|red/hermes-checkout|red/hermes-lanes|red/rtk|degraded/codex-cli|red/jira-cli-dist-build|red/bun|red/uv|red/gitleaks|red/shellcheck|red/gh|red/scheduler-backend|red/npm-less-node)([: ]|$)'
}

# a fake red must still fail the filters while the host-tool reds pass them
filter_selftest() {
  local f="$TMP/filter.out"
  printf '  red  graphify  not found\n' > "$f"
  [ -z "$(status_unexpected_red "$f")" ] || { echo "FAIL: filter self-test: a graphify red must be tolerated"; return 1; }  # vacuous-path-ok: parent shell, real PATH
  printf '  red  graphify  not found\n  red  foo  broken\n' > "$f"
  [ -n "$(status_unexpected_red "$f")" ] || { echo "FAIL: filter self-test: a fake red foo passed the status filter"; return 1; }  # vacuous-path-ok: parent shell, real PATH
  printf '   · red/jira-cli-dist-build: x\n   · degraded/codex-cli: y\n' > "$f"
  [ -z "$(doctor_unexpected_item "$f")" ] || { echo "FAIL: filter self-test: the host-tool doctor items must be tolerated"; return 1; }  # vacuous-path-ok: parent shell, real PATH
  printf '   · red/graphify: w\n' > "$f"
  [ -z "$(doctor_unexpected_item "$f")" ] || { echo "FAIL: filter self-test: the doctor red/graphify item must be tolerated"; return 1; }  # vacuous-path-ok: parent shell, real PATH
  printf '  red  hermes-checkout  a\n  red  rtk  b\n  red  jira-cli-dist-build  c\n' > "$f"
  [ -z "$(status_unexpected_red "$f")" ] || { echo "FAIL: filter self-test: the hermes, rtk and jira build status reds must be tolerated"; return 1; }  # vacuous-path-ok: parent shell, real PATH
  printf '  red  bun  a\n  red  scheduler-backend  b\n  red  gh  c\n   · red/uv: d\n   · red/gitleaks: e\n' > "$f"
  [ -z "$(status_unexpected_red "$f")" ] && [ -z "$(doctor_unexpected_item "$f")" ] || { echo "FAIL: filter self-test: the runner toolchain reds must be tolerated"; return 1; }  # vacuous-path-ok: parent shell, real PATH
  printf '  red  rtk-extra  b\n  red  hermes  a\n' > "$f"
  [ "$(status_unexpected_red "$f" | grep -c .)" -eq 2 ] || { echo "FAIL: filter self-test: a near-miss status name must not be tolerated"; return 1; }  # vacuous-path-ok: parent shell, real PATH
  printf '   · red/hermes-checkout: a\n   · red/rtk: b\n' > "$f"
  [ -z "$(doctor_unexpected_item "$f")" ] || { echo "FAIL: filter self-test: the hermes and rtk doctor items must be tolerated"; return 1; }  # vacuous-path-ok: parent shell, real PATH
  printf '   · red/jira-cli-dist-build: x\n   · red/foo: z\n' > "$f"
  [ -n "$(doctor_unexpected_item "$f")" ] || { echo "FAIL: filter self-test: a fake red/foo passed the doctor filter"; return 1; }  # vacuous-path-ok: parent shell, real PATH
}

check_green() { # <scope> <label>
  local scope="$1" label="$2" cwd="$R" out rc
  mkdir -p "$HOME/.claude/himmel"
  printf '{"role":"adopter","tier":"standard","scope":"%s","vault":{"mode":"none","path":""},"handover":{"mode":"inline","path":""},"pluginSet":"lean","lanes":[],"lanesMeaningful":true,"alwaysOn":false}\n' \
    "$scope" > "$HOME/.claude/himmel/install-profile.json"
  [ "$scope" = project ] && cwd="$X/proj"
  out="$X/status.out"
  ( cd "$cwd" && env PATH="$X/bin:$ORIG_PATH" HIMMELCTL_REPO_ROOT="$R" HIMMELCTL_CACHE_DIR="$HOME/.claude/himmel" "$REALNODE" "$R/scripts/himmelctl/bin.js" status ) > "$out" 2>&1
  rc=$?
  if [ "$rc" -eq 0 ] && [ -z "$(status_unexpected_red "$out")" ]; then row ok "$label: status green"  # vacuous-path-ok: grep is linked into the fixture bin dir
  else row bad "$label: status not green (rc=$rc): $(status_unexpected_red "$out" | cut -c1-200 | head -5 | tr '\n' ';')"; fi
  out="$X/doctor.out"
  ( cd "$cwd" && env PATH="$X/bin:$ORIG_PATH" HIMMELCTL_REPO_ROOT="$R" HIMMELCTL_CACHE_DIR="$HOME/.claude/himmel" bash "$R/scripts/himmel-doctor.sh" --no-color --only C1,C6,C13,C15,C16 ) > "$out" 2>&1
  if grep -q 'Summary: 0 FAIL' "$out" && [ -z "$(doctor_unexpected_item "$out")" ]; then row ok "$label: doctor green"  # vacuous-path-ok: grep is linked into the fixture bin dir
  else row bad "$label: doctor not green: $(grep -E 'FAIL' "$out" | head -2 | tr '\n' ';')$(doctor_unexpected_item "$out" | cut -c1-200 | head -5 | tr '\n' ';')"; fi
}

v_adopt() { # <scope> <label> [fail-at-k]
  local scope="$1" label="$2" k="${3:-}" rc
  : > "$X/state/calls"
  rm -f "$X/state/injected"
  ( cd "$X/proj" && env ${k:+STUB_FAIL_AT=$k} bash "$R/scripts/adopt.sh" --profile core --scope "$scope" --target "$X/proj" </dev/null ) > "$X/adopt.out" 2>&1
  rc=$?
  if [ -n "$k" ]; then
    if [ "$(cat "$X/state/injected" 2>/dev/null)" = "$k" ]; then row ok "$label: adopt ran (rc=$rc, injected)"
    else row bad "$label: injection at claude call $k never fired (only $(cat "$X/state/calls") calls)"; fi
  elif [ "$rc" -eq 0 ]; then row ok "$label: adopt rc 0"; check_green "$scope" "$label"
  else row bad "$label: adopt rc=$rc: $(tail -3 "$X/adopt.out" | tr '\n' ';')"; fi
}

v_uninstall() { # <label> [extra uninstall flags]
  local label="$1" rc left n; shift
  ( cd "$X/proj" && env HIMMEL_UNINSTALL_REAL_HOME=1 bash "$R/scripts/uninstall.sh" --yes --skip-tasks "$@" </dev/null ) > "$X/un.out" 2>&1
  rc=$?
  left="$(remaining "$X" "$X/snap.pre")"
  n="$(printf '%s' "$left" | grep -c . || true)"
  if [ "$rc" -eq 0 ] && [ "$n" -eq 0 ]; then row ok "$label: rc 0 and fixture restored"
  elif [ "$rc" -eq 0 ]; then row bad "$label: rc 0 but $n path(s) differ from the pre-install snapshot: $(printf '%s' "$left" | head -5 | tr '\n' ' ')"
  elif [ "$n" -eq 0 ]; then row bad "$label: rc=$rc but nothing remains: $(sed -n '/^Uninstall INCOMPLETE/,/^Nothing was removed/p' "$X/un.out" | cut -c1-200 | head -8 | tr '\n' ';')"
  else row ok "$label: rc=$rc and $n path(s) remain (consistent)"; fi
  if [ "$MUST_PASS" -eq 1 ] && [ "$rc" -ne 0 ]; then row bad "$label: a clean install must uninstall clean, got rc=$rc: $(grep -m1 'Halted at' "$X/un.out")"; fi
  MUST_PASS=0
}

v_tamper() { # corrupt every backup holding the JSON null a container is restored from, so the restore is declined
  local f n=0
  for f in "$HOME"/.himmel/provenance-backups/*/*; do
    if [ -f "$f" ] && [ "$(jq -c . "$f" 2>/dev/null)" = null ]; then
      printf 'CORRUPT' > "$f" && n=$((n + 1))
    fi
  done
  if [ "$n" -gt 0 ]; then row ok "tamper: corrupted $n null backup(s)"
  else row bad "tamper: no null backup was corrupted"; fi
}

run_seq() { # <id> <verbs...>   (runs in a subshell; results in $X/rows)
  local id="$1" verb i=0; shift
  X="$(mktemp -d "$TMP/seq.XXXXXX")" || exit 1
  printf '%s' "$X" > "$TMP/$id.dir"
  new_fixture "$X" || { echo "fixture setup failed" >&2; exit 1; }
  fixture_env
  if [ "${1:-}" = N ]; then # explicit-null container, seeded before the pre-install snapshot
    shift
    jq '.hooks = null' "$X/home/.claude/settings.json" > "$X/s.n" && mv "$X/s.n" "$X/home/.claude/settings.json"
  fi
  snapshot "$X" "$X/snap.pre"
  mkdir -p "$X/pre"
  cp -p "$X/home/.claude/settings.json" "$X/pre/home-settings.json"
  cp -p "$X/proj/.claude/settings.json" "$X/pre/proj-settings.json"
  STRICT=0 MUST_PASS=0
  : > "$X/rows"
  for verb in "$@"; do
    i=$((i + 1))
    case "$verb" in
      A)  v_adopt user "$id#$i A" ;;
      P)  v_adopt project "$id#$i P" ;;
      F*) v_adopt user "$id#$i $verb" "${verb#F}" ;;
      U)  v_uninstall "$id#$i U" ;;
      X)  v_uninstall "$id#$i X" --purge-state ;;
      T)  v_tamper ;;
      S)  STRICT=1 ;;
      D)  export STUB_UNDECLARED=1 ;;
      W)  MUST_PASS=1; v_uninstall "$id#$i W" ;;
      B)  printf 'stray\n' > "$X/home/.claude/stray-from-broken-restore" ;;
    esac
  done
  : > "$X/done"
}

# ── the sequence table ──────────────────────────────────────────────────────
# id|xfail-ticket|verbs
SEQS=(
  "install-uninstall-user||A U"
  "install-uninstall-project||P U"
  "reinstall-reuninstall-user||A U A U"
  "both-scopes-one-uninstall||A P U"
  "project-then-user||P A U U"
  "purge-state||A X"
  "fail-inject-3-then-uninstall||F3 S W"
  "fail-inject-9-then-uninstall||F9 U"
  "uninstall-on-clean||U A U"
  "declined-restore-HIMMEL-6110|HIMMEL-6110|N A T U"
  "strict-residue-HIMMEL-6729||A P S W"
  "reinstall-reuninstall-HIMMEL-3767|HIMMEL-3767|A U D A W"
)

# generated sequences: LCG over the verb alphabet, seeded
gen_seq() { # <n> -> "verbs"
  local s="$1" i len out="" v
  local -a alpha=(A P U X F4 F12)
  s=$(( (s * 1103515245 + 12345) & 0x7fffffff )); len=$(( 3 + s % 3 ))
  for ((i = 0; i < len; i++)); do
    s=$(( (s * 1103515245 + 12345) & 0x7fffffff ))
    v="${alpha[$(( (s >> 8) % ${#alpha[@]} ))]}"; out+="$v "
  done
  echo "${out}U"
}
for g in 1 2 3; do
  SEQS+=("generated-seed-${SEED}-${g}||$(gen_seq $(( SEED + g )))")
done
SEQS+=("control-broken-restore||A B U")
[ -z "$ADHOC" ] || { SEQS=("adhoc||$ADHOC"); ONLY=adhoc; }

# ── run ─────────────────────────────────────────────────────────────────────
START=$SECONDS
for entry in "${SEQS[@]}"; do
  IFS='|' read -r id xf verbs <<< "$entry"
  [ "$id" = control-broken-restore ] && [ "$BREAK" -ne 1 ] && continue
  [ -z "$ONLY" ] || [ "$ONLY" = "$id" ] || continue
  while [ "$(jobs -rp | wc -l)" -ge 8 ]; do sleep 0.2; done
  # shellcheck disable=SC2086
  ( run_seq "$id" $verbs ) > "$TMP/$id.log" 2>&1 &
done
wait

PASS=0; FAILED=0
if filter_selftest; then echo "ok    filter-selftest"; else FAILED=$((FAILED + 1)); fi
for entry in "${SEQS[@]}"; do
  IFS='|' read -r id xf verbs <<< "$entry"
  [ "$id" = control-broken-restore ] && [ "$BREAK" -ne 1 ] && continue
  [ -z "$ONLY" ] || [ "$ONLY" = "$id" ] || continue
  D="$(cat "$TMP/$id.dir" 2>/dev/null)"
  if [ -z "$D" ] || [ ! -e "$D/done" ]; then
    echo "FAIL  $id [$verbs]: sequence did not complete: $(tail -3 "$TMP/$id.log" | tr '\n' ';')"; FAILED=$((FAILED + 1)); continue
  fi
  bad="$(grep '^bad ' "$D/rows" || true)"
  if [ -n "$xf" ]; then
    case "$xf" in
      HIMMEL-3767) pin='rc=[0-9]+ but nothing remains|a clean install must uninstall clean' ;;
      HIMMEL-6110) pin='rc 0 but [0-9]+ path\(s\) differ from the pre-install snapshot: (home/\.claude/settings\.json ?)+$' ;;
      *) pin='no pin defined for this known-red row$' ;;
    esac
    other="$(printf '%s\n' "$bad" | grep -vE "^bad [^ ]+#[0-9]+ [UWX]: ($pin)" | grep . || true)"
    if [ -n "$other" ]; then echo "FAIL  $id [$verbs]: known-red row failed for another reason: $(printf '%s' "$other" | head -1 | cut -c5-)"; FAILED=$((FAILED + 1))
    elif [ -n "$bad" ]; then echo "XFAIL $id [$verbs] ($xf): $(printf '%s' "$bad" | head -1 | cut -c5-)"; PASS=$((PASS + 1))
    else echo "FAIL  $id [$verbs]: XPASS — known-red row passes; $xf is fixed, drop the tag from this row"; FAILED=$((FAILED + 1)); fi
  elif [ -n "$bad" ]; then
    echo "FAIL  $id [$verbs]"; printf '%s\n' "$bad" | cut -c5- | sed 's/^/        /'; FAILED=$((FAILED + 1))
  else
    echo "ok    $id [$verbs] ($(grep -c '^ok ' "$D/rows") checks)"; PASS=$((PASS + 1))
  fi
done
[ $((PASS + FAILED)) -gt 0 ] || { echo "FAIL: no sequence matched${ONLY:+ --only $ONLY}"; FAILED=1; }
ELAPSED=$((SECONDS - START))
echo "sequences: $PASS ok/xfail, $FAILED failed, ${ELAPSED}s (seed $SEED)"
within_budget "$ELAPSED" "$BUDGET" || { echo "FAIL: suite took ${ELAPSED}s, budget is ${BUDGET}s"; FAILED=$((FAILED + 1)); }
[ "$FAILED" -eq 0 ]
