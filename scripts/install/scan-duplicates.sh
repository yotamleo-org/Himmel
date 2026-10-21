#!/usr/bin/env bash
# scan-duplicates.sh — READ-ONLY post-install scan for duplicated wiring.
#
# llms.txt tells an installing LLM to run this after an install and report the
# output to the user verbatim. It never writes: no files, no settings, no
# `claude plugin` calls. It reads ~/.claude/settings.json, the project's
# .claude/settings.json and settings.local.json, ~/.claude/plugins/
# installed_plugins.json and the hooks.json of each enabled plugin, and reports
#   1. the same hook script wired more than once (settings vs settings, or
#      settings vs an enabled plugin — himmel-guard's block-destructive-commands
#      wired by the harness AND the plugin is the likely case);
#   2. a plugin enabled at more than one scope, or under two marketplaces;
#   3. leftovers a pre-1.1.3 install carries (the retired caveman plugin, an
#      unsubstituted <himmel-path> placeholder).
#
# Usage: bash scripts/install/scan-duplicates.sh [<project-dir>]   (default: $PWD)
# Exit:  0 = scan ran (clean or duplicates found), 2 = could not scan (no jq).
#
# ponytail: a hook is identified by event + script basename, not file content,
#   so two unrelated scripts sharing a basename across a settings file and a
#   plugin read as a duplicate; plugin-vs-plugin is never compared for that
#   reason. Upgrade path: compare the resolved script bytes.
# ponytail: a plugin's hooks come from <installPath>/hooks/hooks.json only; a
#   hooks path declared in plugin.json is not followed.
set -u

command -v jq >/dev/null 2>&1 || { echo "scan-duplicates: jq is required" >&2; exit 2; }

PROJECT=${1:-$PWD}
PROJECT=$(cd "$PROJECT" 2>/dev/null && pwd) || PROJECT=${1:-$PWD}
NL='
'
TAB=$(printf '\t')
USER_FILE="$HOME/.claude/settings.json"
INSTALLED="$HOME/.claude/plugins/installed_plugins.json"

# "<label>|<path>" per settings file, lowest precedence first. The project files
# are skipped when the project IS $HOME (same files as user scope).
FILES="user|$USER_FILE"
if [ "$PROJECT/.claude/settings.json" != "$USER_FILE" ]; then
  FILES="$FILES${NL}project|$PROJECT/.claude/settings.json${NL}local|$PROJECT/.claude/settings.local.json"
fi

# shellcheck disable=SC2016
HOOK_Q='(.hooks // {}) | to_entries[] | .key as $e
  | (.value | to_entries[]) as $g
  | ($g.value.hooks // []) | to_entries[] | .key as $h | .value | select((.command // "") != "")
  | [$e, (($g.value.matcher // "") | if . == "" then "*" else . end), .command, $kind, $src,
     ($file + "#" + $e + "[" + ($g.key | tostring) + "." + ($h | tostring) + "]")] | @tsv'
# shellcheck disable=SC2016
PLUGIN_Q='(.enabledPlugins // {}) | to_entries[] | [.key, (.value | tostring), $scope, $file] | @tsv'

hook_rows=""   # event, matcher, command, kind (S|P), source label, location
plugin_rows="" # key, value, scope, file
placeholders=""
checked=0
unparsed=0

while IFS='|' read -r scope file; do
  [ -f "$file" ] || continue
  jq -e . "$file" >/dev/null 2>&1 || { echo "scan-duplicates: skipping unparsable $file" >&2; unparsed=$((unparsed + 1)); continue; }
  checked=$((checked + 1))
  hook_rows="$hook_rows$(jq -r --arg kind S --arg src "$scope settings" --arg file "$file" "$HOOK_Q" "$file" 2>/dev/null)$NL"
  plugin_rows="$plugin_rows$(jq -r --arg scope "$scope" --arg file "$file" "$PLUGIN_Q" "$file" 2>/dev/null)$NL"
  grep -qF '<himmel-path>' "$file" && placeholders="$placeholders$file$NL"
done <<EOF
$FILES
EOF

# Effective enablement: a later (more specific) settings file overrides an earlier one.
enabled_keys=$(printf '%s' "$plugin_rows" | awk -F'\t' 'NF { v[$1] = $2 } END { for (k in v) if (v[k] == "true") print k }' | sort)

if [ -f "$INSTALLED" ] && ! jq -e . "$INSTALLED" >/dev/null 2>&1; then
  echo "scan-duplicates: skipping unparsable $INSTALLED" >&2
  unparsed=$((unparsed + 1))
elif [ -f "$INSTALLED" ]; then
  while IFS= read -r key; do
    [ -n "$key" ] || continue
    ipaths=$(jq -r --arg k "$key" --arg proj "$PROJECT" \
      '.plugins[$k][]? | select((.projectPath // "") == "" or .projectPath == $proj) | .installPath' "$INSTALLED" 2>/dev/null)
    while IFS= read -r ipath; do
      hf="$ipath/hooks/hooks.json"
      [ -n "$ipath" ] && [ -f "$hf" ] || continue
      jq -e . "$hf" >/dev/null 2>&1 || { echo "scan-duplicates: skipping unparsable $hf" >&2; unparsed=$((unparsed + 1)); continue; }
      hook_rows="$hook_rows$(jq -r --arg kind P --arg src "plugin $key" --arg file "$hf" "$HOOK_Q" "$hf" 2>/dev/null)$NL"
    done <<EOF2
$ipaths
EOF2
  done <<EOF
$enabled_keys
EOF
fi

# Explode each hook command into the scripts it runs; the node/shell wrappers
# are plumbing, not the hook.
script_rows=""
while IFS="$TAB" read -r ev matcher cmd kind src loc; do
  [ -n "$cmd" ] || continue
  for s in $(printf '%s' "$cmd" | grep -oE '[A-Za-z0-9_.-]+\.(sh|js|mjs|py|ps1)' | sort -u); do
    case "$s" in run-hook-with-bash.js|run-node.sh|index.js) continue ;; esac
    script_rows="$script_rows$ev$TAB$matcher$TAB$s$TAB$kind$TAB$src$TAB$loc$NL"
  done
done <<EOF
$hook_rows
EOF

hook_report=$(printf '%s' "$script_rows" | awk -F'\t' '
NF {
  g = $1 SUBSEP $3
  if (!(g in gseen)) { gseen[g] = 1; gord[++gn] = g; gev[g] = $1; gsc[g] = $3 }
  sk = g SUBSEP $5
  if (!(sk in sseen)) {
    sseen[sk] = 1; ns[g]++
    sidx[sk] = ns[g]
    slabel[g, ns[g]] = $5; sfile[g, ns[g]] = $6; sub(/#.*/, "", sfile[g, ns[g]])
    skind[g, ns[g]] = $4
  }
  smat[g, sidx[sk]] = smat[g, sidx[sk]] "|" $2
  mk = g SUBSEP $5 SUBSEP $2
  lk = mk SUBSEP $6
  if (!(lk in lseen)) {
    lseen[lk] = 1; nl[mk]++; mloc[mk, nl[mk]] = $6
    if (nl[mk] == 1) { mord[++mn] = mk; mg[mk] = g; msrc[mk] = $5; mm[mk] = $2 }
  }
}
# Matcher tokens are regexes. "*" matches every tool; a literal token is tested
# against the other token as an anchored regex; two regexes are assumed to overlap.
function isre(t) { return t ~ /[^A-Za-z0-9_]/ }
function tokmatch(x, y) {
  if (x == y || x == "*" || y == "*") return 1
  if (isre(x) && isre(y)) return 1
  if (isre(x)) return (y ~ ("^(" x ")$"))
  if (isre(y)) return (x ~ ("^(" y ")$"))
  return 0
}
function overlap(x, y,   xs, ys, nx, ny, i, j) {
  nx = split(x, xs, "|"); ny = split(y, ys, "|")
  for (i = 1; i <= nx; i++) {
    if (xs[i] == "") continue
    for (j = 1; j <= ny; j++) if (ys[j] != "" && tokmatch(xs[i], ys[j])) return 1
  }
  return 0
}
END {
  for (i = 1; i <= gn; i++) {
    g = gord[i]
    if (ns[g] < 2) continue
    delete inv
    for (a = 1; a <= ns[g]; a++)
      for (b = a + 1; b <= ns[g]; b++)
        if ((skind[g, a] == "S" || skind[g, b] == "S") && overlap(smat[g, a], smat[g, b])) { inv[a] = 1; inv[b] = 1 }
    ninv = 0
    for (a = 1; a <= ns[g]; a++) if (a in inv) ninv++
    if (ninv < 2) continue
    printf "[hook] %s on %s is wired %d times:\n", gsc[g], gev[g], ninv
    for (j = 1; j <= ns[g]; j++) if (j in inv) printf "  - %s: %s\n", slabel[g, j], sfile[g, j]
    print "  fix: keep one copy - remove the hook entry from the settings file, or disable the plugin that ships it."
    print ""
  }
  for (i = 1; i <= mn; i++) {
    mk = mord[i]; g = mg[mk]
    if (nl[mk] < 2 || msrc[mk] ~ /^plugin /) continue
    printf "[hook] %s on %s (matcher %s) is wired %d times in %s:\n", gsc[g], gev[g], mm[mk], nl[mk], msrc[mk]
    for (j = 1; j <= nl[mk]; j++) printf "  - %s\n", mloc[mk, j]
    print "  fix: keep one entry and delete the others."
    print ""
  }
}')

scope_report=$(printf '%s' "$plugin_rows" | awk -F'\t' '
NF && $2 == "true" {
  k = $1; n[k]++; sc[k, n[k]] = $3; fl[k, n[k]] = $4
  if (n[k] == 1) ord[++kn] = k
}
END {
  for (i = 1; i <= kn; i++) {
    k = ord[i]
    if (n[k] < 2) continue
    printf "[plugin] %s is enabled at %d scopes:\n", k, n[k]
    for (j = 1; j <= n[k]; j++) printf "  - %s: %s\n", sc[k, j], fl[k, j]
    print "  fix: enable it at one scope only and remove the other enabledPlugins entry."
    print ""
  }
}')

market_report=$(printf '%s' "$enabled_keys" | awk '
NF {
  name = $0; sub(/@[^@]*$/, "", name)
  n[name]++; keys[name, n[name]] = $0
  if (n[name] == 1) ord[++nn] = name
}
END {
  for (i = 1; i <= nn; i++) {
    name = ord[i]
    if (n[name] < 2) continue
    printf "[plugin] %s is enabled under %d marketplaces:\n", name, n[name]
    for (j = 1; j <= n[name]; j++) printf "  - %s\n", keys[name, j]
    print "  fix: keep one marketplace (prefer @himmel, which pins reviewed SHAs); scripts/machine-setup/migrate-plugin-to-himmel.sh prints the dry-run commands."
    print ""
  }
}')

leftover_report=""
caveman_files=$(printf '%s' "$plugin_rows" | awk -F'\t' '$1 == "caveman@caveman" { print $4 }' | sort -u)
if [ -n "$caveman_files" ]; then
  leftover_report="[leftover] caveman@caveman is a plugin himmel retired:$NL$(printf '%s\n' "$caveman_files" | sed 's/^/  - /')${NL}  fix: scripts/machine-setup/remove-retired-plugin.sh offers the removal."
fi
if [ -n "$placeholders" ]; then
  leftover_report="$leftover_report${leftover_report:+$NL}[leftover] an unsubstituted <himmel-path> placeholder is still in:$NL$(printf '%s' "$placeholders" | sed 's/^/  - /')${NL}  fix: node scripts/himmelctl/bin.js ensure re-wires it."
fi

report=""
for part in "$hook_report" "$scope_report" "$market_report" "$leftover_report"; do
  [ -n "$part" ] && report="$report${report:+$NL$NL}$part"
done

if [ -z "$report" ] && [ "$unparsed" -gt 0 ]; then
  echo "scan-duplicates: incomplete - $unparsed settings file(s) could not be parsed, so the scan cannot call this install clean ($checked checked)"
  exit 0
fi

if [ -z "$report" ]; then
  echo "scan-duplicates: clean - no duplicate hooks, plugins or stale keys found ($checked settings file(s) checked)"
  exit 0
fi

count=$(printf '%s\n' "$report" | grep -c '^\[')
echo "scan-duplicates: $count issue(s) found (read-only scan, nothing was changed)"
echo
printf '%s\n' "$report"
exit 0
