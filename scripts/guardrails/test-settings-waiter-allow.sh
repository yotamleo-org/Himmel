#!/usr/bin/env bash
# the console event waiter launch (ACTION ZERO step 10 in console-template.md)
# spells the kit by ABSOLUTE quoted path; the tracked allow list must carry a
# valid Bash(...) rule that matches it, widens to no other script, and every
# allow entry must load (no bare-wildcard tool name).
#
# The matcher below mirrors Claude Code's Bash wildcard rule: each `*` becomes
# `.*`, every other regex metacharacter is escaped, a lone trailing ` *` makes
# the arguments optional, and the whole command must match.
#
# Usage: bash scripts/guardrails/test-settings-waiter-allow.sh
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SETTINGS="$ROOT/.claude/settings.json"
TEMPLATE="$ROOT/docs/handover/console-template.md"
fail=0

command -v jq >/dev/null 2>&1 || { echo "FAIL: jq not installed, cannot assert the allow list"; exit 1; }
command -v node >/dev/null 2>&1 || { echo "FAIL: node not installed, cannot match allow rules"; exit 1; }

ok() { echo "PASS: $1"; }
bad() { echo "FAIL: $1"; fail=1; }

# A Bash(...) allow rule applies to a command: prints the matching rules.
# shellcheck disable=SC2016 # the node program is a literal, not shell
matching_rules() {
  jq -c '[.permissions.allow[] | select(startswith("Bash("))]' "$SETTINGS" |
    node -e '
      const rules = JSON.parse(require("fs").readFileSync(0, "utf8"));
      const cmd = process.argv[1];
      for (const rule of rules) {
        const body = rule.slice(5, -1);
        let re;
        if (body.endsWith(":*")) {
          const p = body.slice(0, -2);
          if (cmd === p || cmd.startsWith(p + " ")) console.log(rule);
          continue;
        }
        const stars = (body.match(/\*/g) || []).length;
        let s = body.replace(/[.+?^${}()|[\]\\]/g, "\\$&").replaceAll("*", ".*");
        if (s.endsWith(" .*") && stars === 1) s = s.slice(0, -3) + "( .*)?";
        if (new RegExp("^" + s + "$", "s").test(cmd)) console.log(rule);
      }' "$1"
}

# 1. Every allow entry loads: Tool or Tool(content); a `*` is only allowed in the
# tool position after a literal mcp__<server>__ prefix.
bad_entries=$(jq -r '.permissions.allow[] | select(
    (test("^[A-Za-z_][A-Za-z0-9_-]*(\\(.*\\))?$") | not)
    or (sub("\\(.*$"; "") | test("\\*") and (test("^mcp__[A-Za-z0-9_-]+__") | not)))' "$SETTINGS")
if [ -z "$bad_entries" ]; then
  ok "every allow entry has the Tool(...) shape with no bare-wildcard tool name"
else
  bad "allow entries that would not load: $bad_entries"
fi

# 2. The exact step-10 command, rendered from the template line a console prints.
# The template prints the literal $HIMMEL_REPO spelling (the primary checkout's
# copy of the waiter), so no glob is needed before the path.
# shellcheck disable=SC2016 # literal backticks and $HIMMEL_REPO in the doc line
line=$(grep -m1 'bash "\$HIMMEL_REPO/scripts/handover/console-kit/console-wait.sh"' "$TEMPLATE" | sed -e 's/^[^`]*`//' -e 's/`[^`]*$//')
if [ -z "$line" ]; then
  bad "console-template.md has no step-10 console-wait.sh command"
  exit 1
fi
kit="/srv/tester/himmel/scripts/handover/console-kit"
cmd=$(printf '%s' "$line" | sed -e 's#{{INBOX}}#/tmp/consoles/x-console.md#g' \
  -e 's#{{SESSION_NAME}}#x-console#g' -e 's# \[--succession [^]]*\]##')
cmd_succ=$(printf '%s' "$line" | sed -e 's#{{INBOX}}#/tmp/consoles/x-console.md#g' \
  -e 's#{{SESSION_NAME}}#x-console#g' -e 's#\[--succession \([^]]*\)\]#--succession \1#')

for c in "$cmd" "$cmd_succ"; do
  if [ -n "$(matching_rules "$c")" ]; then
    ok "an allow rule matches: $c"
  else
    bad "no allow rule matches the step-10 command: $c"
  fi
done

# 3. The rule widens to no other script or path.
# shellcheck disable=SC2016 # $HIMMEL_REPO is the literal spelling under test
for c in \
  "bash \"\$HIMMEL_REPO/scripts/handover/console-kit/go.sh\" --pr 1" \
  "bash \"\$HIMMEL_REPO/scripts/handover/console-kit/console-wait.sh.evil\" /tmp/x" \
  "bash \"\$HIMMEL_REPO/scripts/other/console-wait.sh\" /tmp/x" \
  "sh \"\$HIMMEL_REPO/scripts/handover/console-kit/console-wait.sh\" /tmp/x" \
  "bash -x \"\$HIMMEL_REPO/scripts/handover/console-kit/console-wait.sh\" /tmp/x" \
  "bash \"$kit/console-wait.sh\" /tmp/x" \
  "bash -c \"id\" \"scripts/handover/console-kit/console-wait.sh\" /tmp/x" \
  "bash \"-c\" \"id\" \"$kit/console-wait.sh\" /tmp/x" \
  "bash \"-c\" \"id\" \"\$HIMMEL_REPO/scripts/handover/console-kit/console-wait.sh\" /tmp/x"; do
  m=$(matching_rules "$c" | grep 'console-wait' || true)
  if [ -z "$m" ]; then
    ok "no waiter rule matches: $c"
  else
    bad "a waiter rule widens to: $c ($m)"
  fi
done

n=$(jq '[.permissions.allow[] | select(test("console-wait\\.sh"))] | length' "$SETTINGS")
if [ "$n" -le 2 ]; then
  ok "allow list carries $n console-wait rules (relative + \$HIMMEL_REPO)"
else
  bad "allow list carries $n console-wait rules, expected at most 2"
fi

# A glob before the path can span quotes (bash "-c" "id" "<path>"): the only `*`
# a console-wait rule may carry is the trailing arguments wildcard.
globbed=$(jq -r '.permissions.allow[] | select(test("console-wait\\.sh")) | select(
    sub(" \\*\\)$"; ")") | sub(":\\*\\)$"; ")") | test("\\*"))' "$SETTINGS")
if [ -z "$globbed" ]; then
  ok "no console-wait rule globs inside the path"
else
  bad "console-wait rule with a glob before the path: $globbed"
fi

exit "$fail"
