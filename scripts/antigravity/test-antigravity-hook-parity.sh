#!/usr/bin/env bash
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/../.." || exit 1

is_settings_tracked() {
  local dir="$1" path="$2" in_index in_head rc
  command -v git >/dev/null 2>&1 || { echo unknown; return; }
  git -C "$dir" rev-parse --is-inside-work-tree >/dev/null 2>&1 || { echo unknown; return; }

  if git -C "$dir" ls-files --error-unmatch "$path" >/dev/null 2>&1; then
    in_index=yes
  else
    rc=$?
    if [ "$rc" -eq 1 ]; then in_index=no; else in_index=unknown; fi
  fi

  if git -C "$dir" rev-parse --verify -q HEAD >/dev/null 2>&1; then
    if git -C "$dir" rev-parse --verify -q "HEAD:$path" >/dev/null 2>&1; then
      in_head=yes
    else
      rc=$?
      if [ "$rc" -eq 1 ]; then in_head=no; else in_head=unknown; fi
    fi
  else
    rc=$?
    if [ "$rc" -eq 1 ]; then in_head=unborn; else in_head=unknown; fi
  fi

  if [ "$in_index" = yes ] || [ "$in_head" = yes ]; then
    echo tracked
  elif [ "$in_index" = no ] && { [ "$in_head" = no ] || [ "$in_head" = unborn ]; }; then
    echo untracked
  else
    echo unknown
  fi
}

if [ ! -f ".claude/settings.json" ]; then
  if [ "$(is_settings_tracked . .claude/settings.json)" = untracked ]; then
    echo "[SKIP] test-antigravity-hook-parity.sh — .claude/settings.json not tracked in this checkout (public mirror)."
    exit 0
  fi
  echo "FAIL - .claude/settings.json is tracked but missing from working tree." >&2
  exit 1
fi

fails=0
assert_empty() {
  if [ -z "${2//[[:space:]]/}" ]; then
    echo "  ok   $1"
  else
    echo "  FAIL $1: $2"
    fails=$((fails + 1))
  fi
}

ANTIGRAVITY_ONLY="block-terminal-write-fence.sh block-antigravity-read-fence.sh"
ANTIGRAVITY_REQUIRED="block-edit-on-main.sh block-read-secrets.sh block-antigravity-read-fence.sh block-graphify-egress.sh block-backend-tier.sh block-docker-privesc.sh block-rogue-claude-schedule.sh block-merged-pr-commit.sh block-terminal-write-fence.sh block-edit-live-settings.sh block-chokepoint-env-prefix.sh block-rogue-codex-exec.sh require-quiet-run.sh block-tail-pipe-on-gates.sh block-jira-compound-write.sh block-write-into-main-checkout.sh guard-t3-thread-tools.sh block-t3code-unwatch-open-pr.sh mcp-policy.sh peer-taint-gate.sh peer-taint-resume.sh record-primary-baseline.sh detect-dirty-primary.sh record-hook-integrity.sh"
ANTIGRAVITY_POST_EXEMPT="detect-token-in-output.sh peer-taint-mark.sh phi-read-mark.sh"

echo "== antigravity hook inventory parity =="

# shellcheck disable=SC2016
report="$(ANTIGRAVITY_ONLY="$ANTIGRAVITY_ONLY" ANTIGRAVITY_REQUIRED="$ANTIGRAVITY_REQUIRED" ANTIGRAVITY_POST_EXEMPT="$ANTIGRAVITY_POST_EXEMPT" node -e '
const fs = require("fs"), path = require("path");
const allow = new Set(process.env.ANTIGRAVITY_ONLY.split(/\s+/).filter(Boolean));
const required = new Set(process.env.ANTIGRAVITY_REQUIRED.split(/\s+/).filter(Boolean));
const postExempt = new Set(process.env.ANTIGRAVITY_POST_EXEMPT.split(/\s+/).filter(Boolean));
const claudeBashExempt = {
  "auto-approve-safe-bash.sh": "Claude permission auto-approver; Antigravity forbids emitting allow",
  "allow-thread-resolve.sh": "Claude permission auto-approver; Antigravity forbids emitting allow",
  "approval-grant-check.sh": "Claude permission-grant helper, not a deny guard",
  "auto-arm-on-cap.sh": "Claude subscription usage-cap auto-arm (Claude-only)",
  "check-cr-marker-on-pr-create.sh": "Subsumed by block-terminal-write-fence.sh (denies gh pr create)",
  "block-fork-sync-pr.sh": "Subsumed by block-terminal-write-fence.sh (denies gh pr mutations)",
  "block-unresolved-cr-merge.sh": "Subsumed by block-terminal-write-fence.sh (denies gh pr merge)",
  "guard-worker-context-handoff.sh": "Worker role only; no Antigravity worker role is wired yet (Decision 1306: one shared trust model; the role guards land with that role)",
  "block-worker-write-fence.sh": "Worker role only; no Antigravity worker role is wired yet (Decision 1306: one shared trust model; the role guards land with that role)",
  "guard-chief-foreground.sh": "Chief role only; no Antigravity chief role is wired yet (Decision 1306: one shared trust model; the role guards land with that role)",
  "guard-relay-writes.sh": "Chief relay role only; no Antigravity chief relay role is wired yet (Decision 1306: one shared trust model; the role guards land with that role)",
  "guard-judge-writes.sh": "Judge role only (plugin-local); no Antigravity judge role is wired yet (Decision 1306: one shared trust model; the role guards land with that role)",
  "guard-rm-writes.sh": "Release-manager role only (plugin-local); no Antigravity release-manager role is wired yet (Decision 1306: one shared trust model; the role guards land with that role)",
  "guard-readiness-tools.sh": "Native Claude readiness role only",
  "block-subagent-release-operator.sh": "Relies on Claude agent_id payload field omitted by Antigravity (C-1215)",
  "block-subagent-park.sh": "Relies on Claude agent_id and Monitor/run_in_background fields omitted by Antigravity (C-1215)",
  "block-agent-native-egress.sh": "Plugin-local guard; Antigravity MCP allowlist denies agent-native-dispatch",
  "block-busy-loop.sh": "Plugin-local guard outside scripts/hooks/",
  "block-vault-sweep.sh": "Plugin-local guard outside scripts/hooks/"
};
const read = (p) => JSON.parse(fs.readFileSync(p, "utf8"));

const lines = [];
const hooksJson = read(".agents/hooks.json");
const specNames = Object.keys(hooksJson);
if (specNames.length !== 1) lines.push("SPEC-COUNT " + specNames.length + " (" + specNames.join(",") + ")");
const spec = hooksJson[specNames[0]] || {};

for (const ev of ["SessionStart", "Stop"]) {
  const arr = spec[ev] || [];
  if (!Array.isArray(arr) || arr.length === 0) { lines.push("MISSING-EVENT " + ev); continue; }
  for (const h of arr) {
    if (typeof h.timeout !== "number" || h.timeout <= 0) lines.push("NOTIMEOUT " + ev);
    if (!String(h.command || "").includes("antigravity-hook-adapter.sh")) lines.push("BADCMD " + ev);
    if (!String(h.command || "").includes("--git-common-dir")) lines.push("NOPRIMARY " + ev);
  }
}
for (const ev of ["PreToolUse", "PostToolUse"]) {
  const groups = spec[ev] || [];
  if (!Array.isArray(groups) || groups.length === 0) { lines.push("MISSING-EVENT " + ev); continue; }
  for (const g of groups) {
    for (const h of g.hooks || []) {
      if (typeof h.timeout !== "number" || h.timeout <= 0) lines.push("NOTIMEOUT " + ev);
      if (!String(h.command || "").includes("antigravity-hook-adapter.sh")) lines.push("BADCMD " + ev);
      if (!String(h.command || "").includes("--git-common-dir")) lines.push("NOPRIMARY " + ev);
    }
  }
}

const adapterSrc = fs.readFileSync("scripts/hooks/antigravity-hook-adapter.sh", "utf8");
const agyGuards = new Set();
for (const m of adapterSrc.matchAll(/\b([a-z][a-z0-9-]*\.sh)\b/g)) {
  const s = m[1];
  if (s === "antigravity-hook-adapter.sh" || s === "run-node.sh") continue;
  agyGuards.add(s);
}
const runCmdBlock = adapterSrc.match(/^\s*run_command\)([\s\S]*?)^\s*;;/m);
const agyBashGuards = new Set();
if (runCmdBlock) {
  for (const m of runCmdBlock[1].matchAll(/\b([a-z][a-z0-9-]*\.sh)\b/g)) {
    const s = m[1];
    if (s === "antigravity-hook-adapter.sh" || s === "run-node.sh") continue;
    agyBashGuards.add(s);
  }
}
lines.push("COUNT " + agyGuards.size);

const claude = new Set();
const claudeBash = new Set();
const sources = [".claude/settings.json"];
const pdir = "marketplace/plugins";
for (const p of fs.existsSync(pdir) ? fs.readdirSync(pdir) : []) {
  const f = path.join(pdir, p, "hooks/hooks.json");
  if (fs.existsSync(f)) sources.push(f);
}
const walkCmds = (obj, out) => {
  if (Array.isArray(obj)) obj.forEach((x) => walkCmds(x, out));
  else if (obj && typeof obj === "object") {
    if (typeof obj.command === "string") out.push(obj.command);
    Object.values(obj).forEach((x) => walkCmds(x, out));
  }
};
for (const src of sources) {
  const parsed = read(src);
  const cmds = [];
  walkCmds(parsed.hooks || {}, cmds);
  for (const c of cmds) for (const m of c.matchAll(/([\w.-]+\.sh)/g)) claude.add(m[1]);
  for (const g of (parsed.hooks && parsed.hooks.PreToolUse) || []) {
    const matcher = String(g.matcher || "*");
    if (!/(^|\|)Bash(\||$)|^\*$/.test(matcher)) continue;
    for (const h of g.hooks || []) {
      for (const m of String(h.command || "").matchAll(/([\w.-]+\.sh)/g)) {
        if (m[1] === "run-node.sh") continue;
        claudeBash.add(m[1]);
      }
    }
  }
}

for (const s of [...agyGuards].sort()) {
  if (!fs.existsSync(path.join("scripts/hooks", s))) lines.push("MISSING " + s);
  else if (!claude.has(s) && !allow.has(s)) lines.push("ORPHAN " + s);
}
for (const s of [...allow].sort()) if (!agyGuards.has(s)) lines.push("STALE-ALLOW " + s);
for (const s of [...required].sort()) if (!agyGuards.has(s)) lines.push("UNPORTED " + s);
for (const s of [...postExempt].sort()) if (agyGuards.has(s)) lines.push("STALE-EXEMPT " + s);
for (const s of [...claudeBash].sort()) {
  if (!agyBashGuards.has(s) && !Object.prototype.hasOwnProperty.call(claudeBashExempt, s)) {
    lines.push("CLAUDE-BASH-MISSING " + s);
  }
}
for (const s of Object.keys(claudeBashExempt).sort()) {
  if (!String(claudeBashExempt[s] || "").trim() || !claudeBash.has(s) || agyBashGuards.has(s)) {
    lines.push("STALE-CLAUDE-BASH-EXEMPT " + s);
  }
}

const skillsJson = read(".agents/skills.json");
if (!Array.isArray(skillsJson.exclude) || !skillsJson.exclude.includes("pr-check")) {
  lines.push("PRCHECK-NOT-EXCLUDED .agents/skills.json");
}

console.log(lines.join("\n"));
')"

field() { printf '%s\n' "$report" | sed -n "s/^$1 //p" | tr '\n' "${2:- }"; }

assert_empty ".agents/hooks.json has exactly one named spec" "$(field SPEC-COUNT '|')"
assert_empty "all four Antigravity lifecycle events are wired" "$(field MISSING-EVENT)"
assert_empty "every Antigravity hook handler carries an explicit timeout" "$(field NOTIMEOUT)"
assert_empty "every Antigravity hook invokes antigravity-hook-adapter.sh" "$(field BADCMD)"
assert_empty "every Antigravity hook resolves primary checkout via --git-common-dir" "$(field NOPRIMARY)"

count="$(field COUNT)"; count="${count% }"
if [ -n "$count" ] && [ "$count" -ge 16 ]; then
  echo "  ok   parsed $count guardrail(s) from antigravity-hook-adapter.sh"
else
  echo "  FAIL parsed too few guardrails ($count)"
  fails=$((fails + 1))
fi

assert_empty "every Antigravity-wired guardrail exists under scripts/hooks/" "$(field MISSING)"
assert_empty "no Antigravity-only guardrail outside allowlist" "$(field ORPHAN)"
assert_empty "no stale ANTIGRAVITY_ONLY allowlist entry" "$(field STALE-ALLOW)"
assert_empty "every required invariant guardrail is wired on Antigravity" "$(field UNPORTED)"
assert_empty "PostToolUse output-body-dependent guards stay explicitly exempt" "$(field STALE-EXEMPT)"
assert_empty "every Claude PreToolUse Bash guard is wired or explicitly exempted" "$(field CLAUDE-BASH-MISSING)"
assert_empty "no stale Claude PreToolUse Bash exemption entry" "$(field STALE-CLAUDE-BASH-EXEMPT)"
assert_empty ".agents/skills.json excludes pr-check" "$(field PRCHECK-NOT-EXCLUDED)"

if [ "$fails" -eq 0 ]; then echo "OK: all cases passed"; exit 0; fi
echo "FAIL: $fails case(s) failed"; exit 1
