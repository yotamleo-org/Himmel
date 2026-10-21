#!/usr/bin/env bash
# Tests for guard-rm-writes.sh. Mode 1 (every session): a raw Edit/Write or a
# Bash redirect/tee/cp/mv/sed -i onto a release authority file is denied, and
# the Jira CLI's `release` op is the sanctioned writer. Mode 2
# (HIMMEL_RELEASE_MANAGER=1, exported by headed-arm-leg.sh --profile
# release-manager): the release manager's Jira, git/gh, file and MCP fence,
# failing closed.
#
# Usage: bash scripts/hooks/test-guard-rm-writes.sh
#
# Platform guard (gitbash-only): Git Bash on Windows / any POSIX bash 3.2+.
# Pure bash + jq over a temp sandbox; not ported to native PowerShell — the
# release-manager lane (headed-arm-leg.sh) is Linux-only.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$SCRIPT_DIR/guard-rm-writes.sh"

BASH_ABS=$(command -v bash)
[ -n "$BASH_ABS" ] || { echo "FATAL: cannot resolve bash on PATH" >&2; exit 1; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/rm-guard-test.XXXXXX")" || { echo "FATAL: mktemp failed" >&2; exit 1; }
TMP="$(cd "$TMP" && pwd -P)"
trap 'rm -rf "$TMP"' EXIT

FAKE_HOME="$TMP/home"
ROOT="$TMP/handovers"
REL="$ROOT/u/himmel/release/R113"
mkdir -p "$FAKE_HOME/.config/himmel/release" "$REL/proposals" "$ROOT/u/himmel/release/R200" "$TMP/repo"
RM_DOC="$ROOT/u/himmel/HIMMEL-1-rm-2026-10-21.md"
JIRA='node /repo/scripts/jira/dist/index.js'
# The session scratchpad lives under /tmp/claude-<uid>.
TMP_SCRATCH="/tmp/claude-$(id -u)"
mkdir -p "$TMP_SCRATCH"

pass=0
fail=0

# check <label> <want rc> <payload> <env...> — runs the hook under env.
check() {
    local label="$1" want="$2" payload="$3" got
    shift 3
    printf '%s' "$payload" | env -u HIMMEL_RELEASE_MANAGER -u HIMMEL_RM_DOC -u HIMMEL_RM_RELEASE \
        HOME="$FAKE_HOME" HANDOVER_DIR="$ROOT" "$@" "$BASH_ABS" "$HOOK" >/dev/null 2>&1
    got=$?
    if [ "$got" = "$want" ]; then
        echo "ok   $label (rc=$got)"; pass=$((pass + 1))
    else
        echo "FAIL $label — expected rc=$want, got rc=$got"; fail=$((fail + 1))
    fi
}
# rm <label> <want> <payload> — the release-manager session (mode 2).
rm_row() { check "rm: $1" "$2" "$3" HIMMEL_RELEASE_MANAGER=1 HIMMEL_RM_DOC="$RM_DOC" HIMMEL_RM_RELEASE=R113; }
# any <label> <want> <payload> — an ordinary session (mode 1 only).
any_row() { check "any session: $1" "$2" "$3" PATH="$PATH"; }

bash_payload() { jq -nc --arg c "$1" '{tool_name:"Bash", tool_input:{command:$c}}'; }
file_payload() { jq -nc --arg t "$1" --arg p "$2" '{tool_name:$t, tool_input:{file_path:$p}}'; }
mcp_payload() { jq -nc --arg t "$1" '{tool_name:$t, tool_input:{}}'; }

# --- mode 2: denied ---
rm_row "jira create" 2 "$(bash_payload "$JIRA create --type Task --title x")"
rm_row "release operator" 2 "$(bash_payload "$JIRA release operator R113 --decision 1 --keys HIMMEL-1 --op add")"
rm_row "release request" 2 "$(bash_payload "$JIRA release request R113 --verb INTAKE --key HIMMEL-1")"
rm_row "edit --add-labels folded" 2 "$(bash_payload "$JIRA edit HIMMEL-1 --add-labels folded")"
rm_row "edit --add-labels backlog,folded" 2 "$(bash_payload "$JIRA edit HIMMEL-1 --add-labels backlog,folded")"
rm_row "edit --labels x" 2 "$(bash_payload "$JIRA edit HIMMEL-1 --labels x")"
rm_row "edit --add-labels backlog --fix-version v1.1.3" 2 "$(bash_payload "$JIRA edit HIMMEL-1 --add-labels backlog --fix-version v1.1.3")"
rm_row "edit --add-fix-version" 2 "$(bash_payload "$JIRA edit HIMMEL-1 --add-fix-version v1.1.3")"
rm_row "transition" 2 "$(bash_payload "$JIRA transition HIMMEL-1 Done")"
rm_row "fix-version" 2 "$(bash_payload "$JIRA fix-version HIMMEL-1 v1.1.3")"
rm_row "edit-batch" 2 "$(bash_payload "$JIRA edit-batch --file x.json")"
rm_row "link" 2 "$(bash_payload "$JIRA link HIMMEL-1 HIMMEL-2")"
rm_row "assign" 2 "$(bash_payload "$JIRA assign HIMMEL-1 me")"
rm_row "delete" 2 "$(bash_payload "$JIRA delete HIMMEL-1")"
rm_row "version-release" 2 "$(bash_payload "$JIRA version-release v1.1.3")"
rm_row "version-edit --name" 2 "$(bash_payload "$JIRA version-edit v1.1.3 --name v9.9.9")"
rm_row "comment without --comment-file" 2 "$(bash_payload "$JIRA comment HIMMEL-1 'inline text'")"
rm_row "comment --adf-file" 2 "$(bash_payload "$JIRA comment HIMMEL-1 --comment-file c.md --adf-file a.json")"
rm_row "the global jira shim, create" 2 "$(bash_payload 'jira create --type Task --title x')"
rm_row "a second jira call writes" 2 "$(bash_payload "$JIRA get HIMMEL-1 && $JIRA create --title x")"
rm_row "leg-jira-status" 2 "$(bash_payload 'bash scripts/handover/console-kit/leg-jira-status.sh HIMMEL-1 Done')"
rm_row "git commit" 2 "$(bash_payload 'git commit -m x')"
rm_row "git push" 2 "$(bash_payload 'git push origin HEAD')"
rm_row "gh pr create" 2 "$(bash_payload 'gh pr create --title x')"
rm_row "gh api -X POST" 2 "$(bash_payload 'gh api -X POST repos/o/r/issues')"
rm_row "leg-pr-open" 2 "$(bash_payload 'bash scripts/lanes/leg-pr-open.sh t b')"
rm_row "merge-on-green" 2 "$(bash_payload 'bash scripts/handover/merge-on-green.sh')"
rm_row "go.sh" 2 "$(bash_payload 'bash scripts/handover/console-kit/go.sh 1 abc')"
rm_row "inbox-send" 2 "$(bash_payload 'bash scripts/handover/inbox-send.sh x')"
rm_row "unsetting the marker" 2 "$(bash_payload 'unset HIMMEL_RELEASE_MANAGER; true')"
rm_row "an Edit of rulings.jsonl" 2 "$(file_payload Edit "$REL/rulings.jsonl")"
rm_row "an Edit of another leg's doc" 2 "$(file_payload Edit "$ROOT/u/himmel/HIMMEL-2-other-2026-10-21.md")"
rm_row "a status file of another release" 2 "$(file_payload Write "$ROOT/u/himmel/release/R200/status-1.md")"
rm_row "a repo file" 2 "$(file_payload Write "$TMP/repo/x.sh")"
rm_row "a relative path" 2 "$(file_payload Write "x.md")"
rm_row "a '..' segment" 2 "$(file_payload Write "$REL/proposals/../rulings.jsonl")"
rm_row "mcp__x__create_issue" 2 "$(mcp_payload 'mcp__x__create_issue')"
rm_row "mcp__atlassian__editJiraIssue" 2 "$(mcp_payload 'mcp__atlassian__editJiraIssue')"
rm_row "an unparseable payload" 2 "not json"

# --- mode 2: allowed ---
rm_row "release rule" 0 "$(bash_payload "$JIRA release rule R113 --req Q-R113-0001 --outcome ADMIT")"
rm_row "release state" 0 "$(bash_payload "JIRA_PROJECT_KEY=HIMMEL $JIRA release state R113 --json")"
rm_row "release claim / apply / lease" 0 "$(bash_payload "$JIRA release claim R113 && $JIRA release apply R113 R-R113-0001 && $JIRA release lease acquire R113")"
rm_row "edit --add-labels backlog" 0 "$(bash_payload "$JIRA edit HIMMEL-1 --add-labels backlog")"
rm_row "edit --remove-labels needs-placement,scope-ci" 0 "$(bash_payload "$JIRA edit HIMMEL-1 --remove-labels needs-placement,scope-ci")"
rm_row "edit --add-labels=deferred" 0 "$(bash_payload "$JIRA edit HIMMEL-1 --add-labels=deferred")"
rm_row "comment --comment-file" 0 "$(bash_payload "$JIRA comment HIMMEL-1 --comment-file /tmp/c.md")"
rm_row "version-edit --description" 0 "$(bash_payload "$JIRA version-edit v1.1.3 --description frozen")"
rm_row "jira reads" 0 "$(bash_payload "$JIRA get HIMMEL-1; $JIRA list --jql x; $JIRA comments HIMMEL-1; $JIRA links HIMMEL-1; $JIRA mirror sync; $JIRA versions; $JIRA transitions HIMMEL-1")"
rm_row "git log" 0 "$(bash_payload 'git log -1 --format=%H')"
rm_row "gh pr view" 0 "$(bash_payload 'gh pr view 12 --json state')"
rm_row "append-results" 0 "$(bash_payload "bash scripts/handover/console-kit/append-results.sh $RM_DOC 'LIVE x'")"
rm_row "an Edit of HIMMEL_RM_DOC" 0 "$(file_payload Edit "$RM_DOC")"
rm_row "a Write of its RM-HANDOFF sibling" 0 "$(file_payload Write "$ROOT/u/himmel/HIMMEL-1-rm-2026-10-21-RM-HANDOFF.md")"
rm_row "status / burndown / ready / proposals" 0 "$(file_payload Write "$REL/status-3.md")"
rm_row "burndown.md" 0 "$(file_payload Write "$REL/burndown.md")"
rm_row "ready-<sha>.md" 0 "$(file_payload Write "$REL/ready-abc123.md")"
rm_row "proposals/" 0 "$(file_payload Write "$REL/proposals/v1.1.4-baseline.md")"
rm_row "the session scratchpad" 0 "$(file_payload Write "$TMP_SCRATCH/rm-guard-test-$$.md")"
rm_row "qmd MCP" 0 "$(mcp_payload 'mcp__qmd__query')"
rm_row "a read-shaped MCP tool" 0 "$(mcp_payload 'mcp__context7__query-docs')"

# --- mode 1 (no env): denied ---
any_row "an Edit of .../release/R113/rulings.jsonl" 2 "$(file_payload Edit "$REL/rulings.jsonl")"
any_row "a Write of a baseline" 2 "$(file_payload Write "$REL/baseline-v1.1.3-g1.json")"
any_row "a Write of the release key" 2 "$(file_payload Write "$FAKE_HOME/.config/himmel/release/R113.key")"
any_row "a MultiEdit of release.json" 2 "$(file_payload MultiEdit "$REL/release.json")"
any_row "echo x > .../lease.json" 2 "$(bash_payload "echo x > $REL/lease.json")"
any_row "echo x >> .../events.jsonl" 2 "$(bash_payload "echo x >>$REL/events.jsonl")"
any_row "tee onto requests.jsonl" 2 "$(bash_payload "echo x | tee -a $REL/requests.jsonl")"
any_row "cp onto operator.jsonl" 2 "$(bash_payload "cp /tmp/x $REL/operator.jsonl")"
any_row "mv onto ~/.config/himmel/release" 2 "$(bash_payload 'mv /tmp/k ~/.config/himmel/release/R113.key')"
# gnu-ok: payload text for the hook, never run.
any_row "sed -i on rulings.jsonl" 2 "$(bash_payload "sed -i 's/a/b/' $REL/rulings.jsonl")"
any_row "cp into a release state directory" 2 "$(bash_payload "cp /tmp/release.json $REL/")"
any_row "cp -t into a release state directory" 2 "$(bash_payload "cp -t $REL /tmp/lease.json")"
any_row "mv into the key directory" 2 "$(bash_payload 'mv /tmp/k ~/.config/himmel/release')"
any_row "mv an authority file away" 2 "$(bash_payload "mv $REL/lease.json /tmp/lease.bak")"
any_row "tee naming jira release as arguments" 2 "$(bash_payload "tee $REL/rulings.jsonl jira release")"
any_row "cp with the release CLI later in the segment" 2 "$(bash_payload "cp $JIRA release state /tmp/x $REL/lease.json")"
any_row "cp onto lease.json with a trailing redirect" 2 "$(bash_payload "cp /tmp/x $REL/lease.json 2>/dev/null")"

# --- mode 1: allowed ---
any_row "release state" 0 "$(bash_payload "$JIRA release state R113")"
any_row "the release CLI writing its own files" 0 "$(bash_payload "$JIRA release rule R113 --verbatim-file $REL/proposals/x.md | tee /tmp/out")"
any_row "the release CLI under an env prefix" 0 "$(bash_payload "JIRA_PROJECT_KEY=HIMMEL $JIRA release rule R113 --note tee $REL/rulings.jsonl")"
any_row "cp an authority file elsewhere" 0 "$(bash_payload "cp $REL/rulings.jsonl /tmp/rulings.bak")"
any_row "an Edit elsewhere" 0 "$(file_payload Edit "$TMP/repo/x.sh")"
any_row "an Edit of a status report" 0 "$(file_payload Edit "$REL/status-3.md")"
any_row "reading lease.json" 0 "$(bash_payload "jq . $REL/lease.json 2>/dev/null")"
any_row "jira create (mode 2 off)" 0 "$(bash_payload "$JIRA create --type Task --title x")"
any_row "git commit (mode 2 off)" 0 "$(bash_payload 'git commit -m x')"
any_row "an MCP write tool (mode 2 off)" 0 "$(mcp_payload 'mcp__x__create_issue')"
any_row "an unparseable payload" 0 "not json"

echo
echo "RESULTS: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
