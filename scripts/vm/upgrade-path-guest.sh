#!/usr/bin/env bash
# upgrade-path-guest.sh -- GUEST side of the VM e2e upgrade-path stage.
#
# Runs ON the VM against a staged himmel tree (scripts/vm/upgrade-path-e2e.sh stages
# it and calls this). It proves an upgrade works end to end before a station roll:
#   1. baseline: install the tree's own pins (ast-grep, graphify, cli-proxy-api, qmd);
#      himmel-doctor -> "before"
#   2. upgrade: move ast-grep / graphify / cli-proxy-api to the stage INPUTS (the
#      station targets; they are inputs, not repo pins, so this stage is independent
#      of whichever dependency PR carries them) via himmel-update.sh / the installers
#   3. assert: himmel-doctor shows no new FAIL and no worsened check other than the
#      named harness artefacts; graphify update + query; qmd add + search; cli-proxy
#      GET /v1/models 200; lane-canary.sh --dry-run
#
# Live lane canaries stay a HOST step after a station roll (the golden guest is
# credential-free by design: no claude login, no lane keys, no konsole).
#
# Inputs (env, ALL required; refuses with exit 2 when one is missing or malformed):
#   UPGRADE_AST_GREP_VERSION     e.g. 0.50.0
#   UPGRADE_GRAPHIFY_VERSION     e.g. 0.9.85
#   UPGRADE_CLIPROXY_VERSION     e.g. 8.0.23
#   UPGRADE_CLIPROXY_SHA256      sha256 of that release's linux_amd64 asset
#
# Usage: bash scripts/vm/upgrade-path-guest.sh [repo-root]
# Exit: 0 every assertion passed; 1 an assertion failed; 2 bad/missing inputs.
# The final line is `RESULT: N failure(s)`.
#
# Sourced (BASH_SOURCE != $0) it defines only the pure helpers, for the hermetic test.

# --- doctor comparison (pure; unit-tested) ----------------------------------

# Check names whose WARN is an artefact of the harness, not of the upgrade: C32 sees
# a git repo because the guest tree is git-init'd for himmel-update.sh; C42 cannot
# reach `gh` in the credential-free guest. Allowlisted by NAME, never by count.
DOCTOR_ARTEFACT_ALLOW="C32-main-ref-guard C42-sweep-health"

# doctor_worst <doctor-output> -- one "<check-id> <SEV>" line per check, worst
# severity wins (a check id may print several rows, e.g. C7-shipped).
doctor_worst() {
  awk '
    /^(OK|INFO|WARN|FAIL) +[A-Za-z0-9]/ {
      sev = $1; id = $2; sub(/:$/, "", id)
      r = (sev == "OK") ? 0 : (sev == "INFO") ? 1 : (sev == "WARN") ? 2 : 3
      if (!(id in w) || r > w[id]) w[id] = r
    }
    END {
      split("OK INFO WARN FAIL", n, " ")
      for (id in w) print id, n[w[id] + 1]
    }' "$1" | sort
}

# doctor_valid <doctor-output> -- 0 only when the capture holds at least one check row
# AND the Summary line; an empty or truncated capture must not read as "no regression".
doctor_valid() {
  [ -s "$1" ] || return 1
  grep -Eq '^(OK|INFO|WARN|FAIL) +[A-Za-z0-9]' "$1" || return 1
  grep -q '^Summary:' "$1"
}

# first_semver <text> -- the first x.y.z token, so "0.9.8" never matches "0.9.85".
first_semver() { printf '%s\n' "$1" | grep -Eo '[0-9]+\.[0-9]+\.[0-9]+' | head -1; }

# both_ok <updater-rc> <check-rc> -- 0 only when the command AND its follow-up check
# succeeded, so a failed updater cannot ride on a leftover binary or a stale artefact.
both_ok() { [ "$1" -eq 0 ] && [ "$2" -eq 0 ]; }

# doctor_regressions <before-file> <after-file> [allow-id ...]
# Prints one line per violation; returns 1 if there is any:
#   NEW-FAIL <id>   a check is FAIL after and was not FAIL before (never allowlisted)
#   WORSE <id> <a> <b>   a check moved to a worse severity and its name is not allowlisted
#   MISSING <id>    a check printed before no longer prints at all
doctor_regressions() {
  local before="$1" after="$2"; shift 2
  local allow=" $* " bad=0 id sev bsev rb ra
  _rank() { case "$1" in OK) echo 0 ;; INFO) echo 1 ;; WARN) echo 2 ;; FAIL) echo 3 ;; *) echo 0 ;; esac; }
  local bmap; bmap="$(doctor_worst "$before")"
  while read -r id sev; do
    [ -n "$id" ] || continue
    bsev="$(printf '%s\n' "$bmap" | awk -v k="$id" '$1 == k { print $2 }')"
    [ -n "$bsev" ] || bsev="OK"
    rb="$(_rank "$bsev")"; ra="$(_rank "$sev")"
    [ "$ra" -gt "$rb" ] || continue
    if [ "$sev" = "FAIL" ]; then
      echo "NEW-FAIL $id"; bad=1
    else
      case "$allow" in *" $id "*) continue ;; esac
      echo "WORSE $id $bsev $sev"; bad=1
    fi
  done <<EOF
$(doctor_worst "$after")
EOF
  local amap; amap="$(doctor_worst "$after")"
  while read -r id sev; do
    [ -n "$id" ] || continue
    printf '%s\n' "$amap" | awk -v k="$id" '$1 == k { f = 1 } END { exit !f }' || { echo "MISSING $id"; bad=1; }
  done <<EOF
$bmap
EOF
  [ "$bad" -eq 0 ]
}

# Sourced for the helpers only: stop here.
if [ "${BASH_SOURCE[0]}" != "$0" ]; then
  # shellcheck disable=SC2317  # reached when sourced
  return 0
fi

# --- stage ------------------------------------------------------------------
set -uo pipefail

ROOT="${1:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)}"
fails=0
pass() { echo "PASS  $1"; }
fail() { echo "FAIL  $1"; fails=$((fails + 1)); }
note() { echo "----  $1"; }
verdict() { if [ "$1" -eq 0 ]; then pass "$2"; else fail "$3"; fi; }

for v in UPGRADE_AST_GREP_VERSION UPGRADE_GRAPHIFY_VERSION UPGRADE_CLIPROXY_VERSION UPGRADE_CLIPROXY_SHA256; do
  if [ -z "${!v:-}" ]; then echo "upgrade-path-guest: $v is required (a station target is an input)" >&2; exit 2; fi
done
for v in UPGRADE_AST_GREP_VERSION UPGRADE_GRAPHIFY_VERSION UPGRADE_CLIPROXY_VERSION; do
  if ! [[ "${!v}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "upgrade-path-guest: $v '${!v}' is not a plain x.y.z version" >&2; exit 2
  fi
done
if ! [[ "$UPGRADE_CLIPROXY_SHA256" =~ ^[0-9a-f]{64}$ ]]; then
  echo "upgrade-path-guest: UPGRADE_CLIPROXY_SHA256 is not a lowercase 64-char hex sha256" >&2; exit 2
fi

export PATH="$HOME/.local/bin:$HOME/.npm-global/bin:$HOME/.bun/bin:$PATH"
# The golden image's npm prefix is /usr (root-owned): keep global installs in the HOME.
export NPM_CONFIG_PREFIX="$HOME/.npm-global"; mkdir -p "$NPM_CONFIG_PREFIX"
cd "$ROOT" || { echo "upgrade-path-guest: cannot cd to $ROOT" >&2; exit 2; }
WORK="$HOME/.himmel-upgrade-stage"   # fixed: the stage rm -rf's it, so no caller-chosen path
rm -rf "$WORK"; mkdir -p "$WORK"
KEY="upgrade-stage-throwaway-key"
export CLIPROXY_API_KEY="$KEY"
export HANDOVER_DIR="$WORK/handovers"; mkdir -p "$HANDOVER_DIR"

echo "---- VM: $(uname -srm) ----"

# The staged tree is a plain copy (no .git); himmel-update.sh and doctor read git.
if [ ! -d .git ]; then
  git init -q -b main . && git -c user.email=stage@vm -c user.name=stage add -A \
    && git -c user.email=stage@vm -c user.name=stage commit -qm "upgrade-path stage baseline" --no-verify \
    && note "git-initialised $ROOT"
fi

# uv is graphify's installer and is not in the golden image.
if ! command -v uv >/dev/null 2>&1; then
  note "installing uv (graphify's installer) from the astral release tarball"
  mkdir -p "$WORK/uv" "$HOME/.local/bin"
  if curl -sfL -o "$WORK/uv.tgz" https://github.com/astral-sh/uv/releases/latest/download/uv-x86_64-unknown-linux-gnu.tar.gz \
     && tar -xzf "$WORK/uv.tgz" -C "$WORK/uv" --strip-components=1; then
    cp "$WORK/uv/uv" "$WORK/uv/uvx" "$HOME/.local/bin/"
  fi
fi
command -v uv >/dev/null 2>&1; verdict $? "uv present ($(uv --version 2>&1 | head -1))" "uv could not be installed"

# --- 1. baseline: the tree's own pins ---------------------------------------
note "baseline: ast-grep (tree pin)"
bash scripts/machine-setup/install-code-kit-clis.sh >"$WORK/ast-grep-base.log" 2>&1; irc=$?
if [ "$irc" -eq 0 ]; then pass "baseline ast-grep installer rc=0"; else fail "baseline ast-grep installer rc=$irc (see $WORK/ast-grep-base.log)"; fi
BASE_AST=""; command -v ast-grep >/dev/null 2>&1 && BASE_AST="$(ast-grep --version 2>&1 | head -1)"
# shellcheck disable=SC2016  # the sed pattern matches the literal ${AST_GREP_VERSION:-x} text
TREE_AST="$(sed -n 's/^AST_GREP_VERSION="${AST_GREP_VERSION:-\(.*\)}"$/\1/p' scripts/machine-setup/install-code-kit-clis.sh | head -1)"
if [ -n "$TREE_AST" ] && [ "$(first_semver "$BASE_AST")" = "$TREE_AST" ]; then pass "baseline ast-grep: $BASE_AST (tree pin $TREE_AST)"; else fail "baseline ast-grep '${BASE_AST:-none}' is not the tree pin '${TREE_AST:-?}' (see $WORK/ast-grep-base.log)"; fi

note "baseline: graphify (tree pin)"
( . scripts/lib/graphify-bin.sh && graphify_install ) >"$WORK/graphify-base.log" 2>&1; irc=$?
if [ "$irc" -eq 0 ]; then pass "baseline graphify installer rc=0"; else fail "baseline graphify installer rc=$irc (see $WORK/graphify-base.log)"; fi
BASE_GRAPHIFY="$(graphify --version 2>&1)"; grc=$?
BASE_GRAPHIFY="$(first_semver "$BASE_GRAPHIFY")"
TREE_GRAPHIFY="$( . scripts/lib/graphify-bin.sh && _graphify_version )"
if [ "$grc" -eq 0 ] && [ -n "$TREE_GRAPHIFY" ] && [ "$BASE_GRAPHIFY" = "$TREE_GRAPHIFY" ]; then pass "baseline graphify: $BASE_GRAPHIFY (tree pin $TREE_GRAPHIFY)"; else fail "baseline graphify '${BASE_GRAPHIFY:-none}' is not the tree pin '${TREE_GRAPHIFY:-?}' (see $WORK/graphify-base.log)"; fi

note "baseline: cli-proxy-api (tree pin)"
bash scripts/setup/cli-proxy-lane.sh --install >"$WORK/proxy-base.log" 2>&1; irc=$?
if [ "$irc" -eq 0 ]; then pass "baseline cli-proxy-api installer rc=0"; else fail "baseline cli-proxy-api installer rc=$irc (see $WORK/proxy-base.log)"; fi
BASE_PROXY="$(cat "$HOME/.cli-proxy-api/cli-proxy-api.version" 2>/dev/null)"
TREE_PROXY="$(sed -n 's/^VERSION="\(.*\)"$/\1/p' scripts/setup/cli-proxy-lane.sh | head -1)"
if [ -n "$TREE_PROXY" ] && [ "$BASE_PROXY" = "$TREE_PROXY" ]; then pass "baseline cli-proxy-api: v$BASE_PROXY (tree pin $TREE_PROXY)"; else fail "baseline cli-proxy-api '${BASE_PROXY:-none}' is not the tree pin '${TREE_PROXY:-?}' (see $WORK/proxy-base.log)"; fi

# qmd is part of the baseline so doctor-before sees the same qmd-dependent checks
# (C44/C49) as doctor-after; without it they flip INFO -> FAIL merely because qmd appeared.
note "baseline: qmd fork (himmel-update --only qmd_fork)"
bash scripts/himmel-update.sh --only qmd_fork >"$WORK/qmd-base.log" 2>&1; urc=$?
( . scripts/lib/qmd-bin.sh && qmd_cmd --version >/dev/null 2>&1 ); crc=$?
both_ok "$urc" "$crc"; verdict $? "baseline qmd present" "baseline qmd updater rc=$urc, present check rc=$crc (see $WORK/qmd-base.log)"

note "baseline: himmel-update.sh --versions (read-only table)"
bash scripts/himmel-update.sh --versions >"$WORK/versions-before.txt" 2>&1
bash scripts/himmel-doctor.sh --no-color >"$WORK/doctor-before.txt" 2>&1
doctor_valid "$WORK/doctor-before.txt"; verdict $? "doctor-before capture holds check rows + Summary" "doctor-before capture is empty or malformed (see $WORK/doctor-before.txt)"
note "doctor before: $(tail -1 "$WORK/doctor-before.txt")"

# --- 2. upgrade to the stage inputs -----------------------------------------
note "upgrade: jira cli rebuild (himmel-update --only jira_cli)"
bash scripts/himmel-update.sh --only jira_cli >"$WORK/up-jira.log" 2>&1; verdict $? "himmel-update --only jira_cli" "himmel-update --only jira_cli (see $WORK/up-jira.log)"

note "upgrade: graphify -> $UPGRADE_GRAPHIFY_VERSION (himmel-update --only graphify)"
GRAPHIFY_VERSION="$UPGRADE_GRAPHIFY_VERSION" bash scripts/himmel-update.sh --only graphify >"$WORK/up-graphify.log" 2>&1; irc=$?
GOT="$(first_semver "$(graphify --version 2>&1)")"
if [ "$irc" -eq 0 ] && [ "$GOT" = "$UPGRADE_GRAPHIFY_VERSION" ]; then pass "graphify now: $GOT"; else fail "graphify install rc=$irc, version '$GOT', wanted $UPGRADE_GRAPHIFY_VERSION (see $WORK/up-graphify.log)"; fi

note "upgrade: qmd fork (himmel-update --only qmd_fork)"
bash scripts/himmel-update.sh --only qmd_fork >"$WORK/up-qmd.log" 2>&1; verdict $? "himmel-update --only qmd_fork" "himmel-update --only qmd_fork (see $WORK/up-qmd.log)"

note "upgrade: ast-grep -> $UPGRADE_AST_GREP_VERSION (install-code-kit-clis, AST_GREP_VERSION)"
AST_GREP_VERSION="$UPGRADE_AST_GREP_VERSION" bash scripts/machine-setup/install-code-kit-clis.sh >"$WORK/up-ast-grep.log" 2>&1; irc=$?
GOT=""; command -v ast-grep >/dev/null 2>&1 && GOT="$(first_semver "$(ast-grep --version 2>&1)")"
if [ "$irc" -eq 0 ] && [ "$GOT" = "$UPGRADE_AST_GREP_VERSION" ]; then pass "ast-grep now: $GOT"; else fail "ast-grep install rc=$irc, version '$GOT', wanted $UPGRADE_AST_GREP_VERSION (see $WORK/up-ast-grep.log)"; fi

note "upgrade: cli-proxy-api -> v$UPGRADE_CLIPROXY_VERSION (CLIPROXY_API_VERSION + CLIPROXY_API_SHA256)"
CLIPROXY_API_VERSION="$UPGRADE_CLIPROXY_VERSION" CLIPROXY_API_SHA256="$UPGRADE_CLIPROXY_SHA256" \
  bash scripts/setup/cli-proxy-lane.sh --install >"$WORK/up-proxy.log" 2>&1; irc=$?
GOT="$(cat "$HOME/.cli-proxy-api/cli-proxy-api.version" 2>/dev/null)"
if [ "$irc" -eq 0 ] && [ "$GOT" = "$UPGRADE_CLIPROXY_VERSION" ]; then pass "cli-proxy-api now: v$GOT"; else
  fail "cli-proxy-api install rc=$irc, version '${GOT:-none}', wanted $UPGRADE_CLIPROXY_VERSION: $(grep -E 'checksum mismatch|failed' "$WORK/up-proxy.log" | head -1 | cut -c1-200)"
fi

# --- 3. assertions ------------------------------------------------------------
note "assert: himmel-doctor (no new FAIL; harness-artefact WARNs allowlisted by name)"
bash scripts/himmel-doctor.sh --no-color >"$WORK/doctor-after.txt" 2>&1
doctor_valid "$WORK/doctor-after.txt"; verdict $? "doctor-after capture holds check rows + Summary" "doctor-after capture is empty or malformed (see $WORK/doctor-after.txt)"
note "doctor after: $(tail -1 "$WORK/doctor-after.txt")"
# shellcheck disable=SC2086  # the allowlist is a space-separated name list
REG="$(doctor_regressions "$WORK/doctor-before.txt" "$WORK/doctor-after.txt" $DOCTOR_ARTEFACT_ALLOW)"
verdict $? "himmel-doctor: no new FAIL, no un-allowlisted regression" "himmel-doctor regressed:"
[ -z "$REG" ] || printf '%s\n' "$REG" | sed 's/^/        /'

note "assert: cli-proxy-api serves GET /v1/models with the existing config"
PRE="$(curl -s -m 3 -o /dev/null -w '%{http_code}' http://127.0.0.1:8317/ 2>/dev/null)"
if [ "$PRE" != "000" ]; then
  fail "port 8317 already has a listener (HTTP $PRE): cannot prove the upgraded proxy answers"
else
  "$HOME/.cli-proxy-api/cli-proxy-api" -config "$HOME/.cli-proxy-api/config.yaml" >"$WORK/proxy.log" 2>&1 &
  PPID_PROXY=$!
  code="000"; alive=0
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    sleep 1
    code="$(curl -s -m 5 -o "$WORK/models.json" -w '%{http_code}' -H "Authorization: Bearer $KEY" http://127.0.0.1:8317/v1/models)"
    [ "$code" = "200" ] && break
  done
  kill -0 "$PPID_PROXY" 2>/dev/null && alive=1
  kill "$PPID_PROXY" 2>/dev/null; wait "$PPID_PROXY" 2>/dev/null
  if [ "$code" = "200" ] && [ "$alive" -eq 1 ]; then pass "GET /v1/models -> 200 from the launched proxy"; else fail "GET /v1/models -> $code, launched proxy alive=$alive (see $WORK/proxy.log)"; fi
fi

note "assert: graphify update + query"
mkdir -p "$WORK/gsmoke"
printf 'def alpha():\n    return beta()\n\ndef beta():\n    return 1\n' > "$WORK/gsmoke/m.py"
graphify update "$WORK/gsmoke" >"$WORK/graphify-update.log" 2>&1; urc=$?
if [ "$urc" -ne 0 ]; then
  fail "graphify update rc=$urc (see $WORK/graphify-update.log)"
elif [ -f "$WORK/gsmoke/graphify-out/graph.json" ]; then
  Q="$(graphify query "what does alpha call" --graph "$WORK/gsmoke/graphify-out/graph.json" 2>"$WORK/graphify-query.err")"; qrc=$?
  if [ "$qrc" -eq 0 ] && [ -n "$Q" ]; then pass "graphify update built a graph and query answered"; else fail "graphify query rc=$qrc or empty (see $WORK/graphify-query.err)"; fi
else
  fail "graphify update built no graph.json (see $WORK/graphify-update.log)"
fi

note "assert: qmd collection add + search"
mkdir -p "$WORK/qsmoke"
printf '# Alpha\nthe upgrade path smoke note about pinned versions\n' > "$WORK/qsmoke/a.md"
(
  export XDG_CONFIG_HOME="$WORK/qcfg" XDG_CACHE_HOME="$WORK/qcache"
  . scripts/lib/qmd-bin.sh
  qmd_cmd collection add "$WORK/qsmoke" --name smoke >"$WORK/qmd-add.log" 2>&1 || exit 41
  qmd_cmd search "pinned versions" -c smoke >"$WORK/qmd-search.log" 2>&1 || exit 42
)
qrc=$?
if [ "$qrc" -eq 0 ] && grep -q 'a\.md\|Alpha' "$WORK/qmd-search.log"; then
  pass "qmd add + search found the note"
else
  fail "qmd add + search rc=$qrc or the note was not found (see $WORK/qmd-add.log, $WORK/qmd-search.log)"
fi

note "assert: lane-canary.sh --dry-run"
LC="$(timeout 60 bash scripts/lanes/lane-canary.sh --lanes native,openrouter --dry-run 2>&1)"; lcrc=$?
if [ "$lcrc" -eq 0 ]; then pass "lane-canary --dry-run rc=0"; else fail "lane-canary --dry-run rc=$lcrc"; fi
[ "$lcrc" -eq 0 ] || printf '%s\n' "$LC" | tail -6 | sed 's/^/        /'

echo "RESULT: $fails failure(s)"
[ "$fails" -eq 0 ]
