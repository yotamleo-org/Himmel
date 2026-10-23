#!/usr/bin/env bash
# Every hook wired in .claude/settings.json and .codex/hooks.json
# must pass hook-integrity's source resolution, transitively.
#
# Why: #2202 added `. "$(dirname "$lib")/load-dotenv.sh"` to 7 hooks.
# hook-integrity.js could not resolve that statement, so it denied every tool
# call of every session running main's hooks until an admin revert (#2211). CI,
# /pr-check and the judge all missed it because nothing ran the REAL hook set
# through the resolver. This suite does: it enumerates the wired hook scripts,
# walks each one's sourced closure with hook-integrity's own sourcedClosure()
# (the function verifyIntegrity uses), and fails on an unresolved source
# statement or a sourced lib that is missing or outside the project.
#
# ponytail: checks the resolution step only, not the per-session pin check
# (that needs a session record); the pin check can only fail after resolution
# succeeds. Upgrade path: also drive verifyProjectHookIntegrity with a
# synthesized record.
#
# Usage: bash scripts/hooks/test-wired-hooks-integrity-resolution.sh
#        bash scripts/hooks/test-wired-hooks-integrity-resolution.sh <tree>   # sweep another tree (RED demos)
set -uo pipefail

ROOT="${1:-${HOOK_SRC_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}}"
PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  FAIL $1"; }

# check_closure <root> <script> -> prints one problem per line, nothing when clean
check_closure() {
  # shellcheck disable=SC2016  # node source, not shell
  node -e '
    const fs = require("fs"), path = require("path");
    const root = fs.realpathSync(process.argv[1]);
    const { sourcedClosure } = require(path.join(root, "scripts/hooks/hook-integrity.js"));
    const queue = [path.resolve(process.argv[2])], seen = new Set(queue);
    const list = [];
    while (queue.length) {
      const file = queue.shift();
      list.push(path.relative(root, file));
      let c;
      try { c = sourcedClosure(file, root); }
      catch (e) { console.log(`${path.relative(root, file)}: unreadable (${e.code || e.message})`); continue; }
      for (const u of c.unresolved) console.log(`${path.relative(root, file)}: unresolved source statement: ${u}`);
      for (const lib of c.libs) {
        const rel = path.relative(root, lib);
        if (rel.startsWith("..") || path.isAbsolute(rel)) { console.log(`${path.relative(root, file)}: sourced lib outside project: ${lib}`); continue; }
        if (!fs.existsSync(lib)) { console.log(`${path.relative(root, file)}: sourced lib missing: ${rel}`); continue; }
        if (!seen.has(lib)) { seen.add(lib); queue.push(lib); }
      }
    }
    if (process.env.CLOSURE_OUT) fs.appendFileSync(process.env.CLOSURE_OUT, list.join("\n") + "\n");
  ' "$1" "$2"
}

# uncovered <root> <paths-file> -> the paths no impacted-suites.sh scan_roots row
# maps to THIS suite, so a change to them would not select it in PR CI
uncovered() {
  local globs g s rest f hit
  globs="$(sed -n '/^scan_roots() {/,/^EOF$/p' "$1/scripts/cr/impacted-suites.sh" |
    while read -r g s rest; do
      [ "$s" = "scripts/hooks/test-wired-hooks-integrity-resolution.sh" ] && printf '%s\n' "$g"
    done)"
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    hit=0
    while IFS= read -r g; do
      [ -n "$g" ] || continue
      # shellcheck disable=SC2254  # the scan_roots glob is a pattern on purpose
      case "$f" in $g) hit=1; break ;; esac
    done <<< "$globs"
    [ "$hit" -eq 1 ] || printf '%s\n' "$f"
  done < "$2"
}

# Wired commands that run no shell hook script this sweep can resolve (a node/bun
# entry point, a PATH tool, an inline node). A command is skipped only when it
# starts with one of these prefixes and names no .sh/.js script; any other
# command that yields no script path fails the enumeration.
# shellcheck disable=SC2016  # the commands keep a literal $CLAUDE_PROJECT_DIR
WIRED_ALLOW='node "$CLAUDE_PROJECT_DIR/scripts/trust/shadow-ledger.mjs"
bun "$CLAUDE_PROJECT_DIR/scripts/observability/session-run-hook.ts"
node "$CLAUDE_PROJECT_DIR/scripts/hooks/stop-queue.mjs" enqueue
command -v graphify >/dev/null 2>&1 && exec graphify hook-guard search
node -e "(async()=>{const root=process.env.CLAUDE_PLUGIN_ROOT||process.env.PLUGIN_ROOT;if(root)await import(require('"'"'node:url'"'"').pathToFileURL(require('"'"'node:path'"'"').join(root,'"'"'hooks'"'"','"'"'always-on.mjs'"'"')).href)})().catch(()=>{})"'

# wired_scripts <root> -> repo-relative hook script paths, one per line, deduped;
# rc 4, naming each command, when a wired command yields no path and is not allowlisted
wired_scripts() {
  # shellcheck disable=SC2016  # node source, not shell
  WIRED_ALLOW="$WIRED_ALLOW" node -e '
    const fs = require("fs"), path = require("path");
    const root = process.argv[1], out = new Set(), unparsed = [];
    const allow = process.env.WIRED_ALLOW.split("\n").filter(Boolean);
    // an allowlisted prefix never exempts a command that also names a .sh/.js script
    const found = (f, c, n) => { if (n === 0 && !(allow.some((a) => c.startsWith(a)) && !/\.(sh|js)\b/.test(c))) unparsed.push(f + ": " + c); };
    const cmds = (f) => {
      const p = path.join(root, f);
      if (!fs.existsSync(p)) { console.error("missing wiring file: " + f); process.exit(3); }
      const j = JSON.parse(fs.readFileSync(p, "utf8"));
      const r = [];
      const walk = (n) => { if (Array.isArray(n)) n.forEach(walk); else if (n && typeof n === "object") { if (typeof n.command === "string") r.push(n.command); Object.values(n).forEach(walk); } };
      walk(j.hooks || j);
      return r;
    };
    for (const c of cmds(".claude/settings.json")) {
      let n = 0;
      for (const m of c.matchAll(/\$\{?CLAUDE_PROJECT_DIR\}?\/([^"\s;]+\.(?:sh|js))/g)) { out.add(m[1]); n++; }
      found(".claude/settings.json", c, n);
    }
    for (const c of cmds(".codex/hooks.json")) {
      const m = c.match(/run-hook\.sh\s+(?:--\S+\s+)*([A-Za-z0-9_.+-]+\.sh(?:\+[A-Za-z0-9_.+-]+\.sh)*)/);
      if (m) for (const n of m[1].split("+")) out.add("scripts/hooks/" + n);
      found(".codex/hooks.json", c, m ? 1 : 0);
    }
    // HIMMEL-5085: plugin hooks.json commands. CLAUDE_PLUGIN_ROOT is the plugin dir,
    // marketplace/plugins/<name>, in this tree; CLAUDE_PROJECT_DIR is the project root.
    const pdir = path.join(root, "marketplace/plugins");
    if (fs.existsSync(pdir)) for (const name of fs.readdirSync(pdir).sort()) {
      const rel = "marketplace/plugins/" + name + "/hooks/hooks.json";
      if (!fs.existsSync(path.join(root, rel))) continue;
      for (const c of cmds(rel)) {
        let n = 0;
        for (const m of c.matchAll(/\$\{?CLAUDE_PLUGIN_ROOT\}?\/([^"\s;]+\.(?:sh|js))/g)) { out.add("marketplace/plugins/" + name + "/" + m[1]); n++; }
        for (const m of c.matchAll(/\$\{?CLAUDE_PROJECT_DIR\}?\/([^"\s;]+\.(?:sh|js))/g)) { out.add(m[1]); n++; }
        found(rel, c, n);
      }
    }
    if (unparsed.length) {
      console.error("wired command(s) yield no script path and are not on the WIRED_ALLOW list:\n" + unparsed.join("\n"));
      process.exit(4);
    }
    console.log([...out].sort().join("\n"));
  ' "$1"
}

echo "== fixture rows (the resolver must flag what it flagged on 2026-10-08)"
FX="$(mktemp -d "${TMPDIR:-/tmp}/wired-hooks-integrity.XXXXXX")" || exit 1
trap 'rm -rf "$FX"' EXIT
mkdir -p "$FX/scripts/hooks" "$FX/scripts/lib"
cp "$ROOT/scripts/hooks/hook-integrity.js" "$FX/scripts/hooks/"
printf '# lib\n' > "$FX/scripts/lib/load-dotenv.sh"
# shellcheck disable=SC2016
printf '#!/usr/bin/env bash\nlib=/x/handover-path.sh\n. "$(dirname "$lib")/load-dotenv.sh"\n' > "$FX/scripts/hooks/bad.sh"
# shellcheck disable=SC2016
printf '#!/usr/bin/env bash\n. "$(dirname "$0")/../lib/load-dotenv.sh"\n' > "$FX/scripts/hooks/good.sh"
if [ -n "$(check_closure "$FX" "$FX/scripts/hooks/bad.sh")" ]; then ok "the #2202 source form is reported unresolved"; else bad "the #2202 source form passed the resolver (suite cannot fail)"; fi
if good_out="$(check_closure "$FX" "$FX/scripts/hooks/good.sh" 2>&1)" && [ -z "$good_out" ]; then ok "a dirname-relative source of a real lib resolves"; else bad "a resolvable source form was flagged"; fi

# RED control: a path under a directory no row covers must be reported
printf 'scripts/lib/x.sh\nscripts/newdir/x.sh\n' > "$FX/paths"
if [ "$(uncovered "$ROOT" "$FX/paths")" = "scripts/newdir/x.sh" ]; then ok "an uncovered closure directory is reported, a covered one is not"; else bad "closure-coverage check cannot fail"; fi

# A plugin hooks.json command (${CLAUDE_PLUGIN_ROOT}/...) must be enumerated
# and held to the same resolution + coverage as a repo hook.
PX="$FX/plug"; mkdir -p "$PX/.claude" "$PX/.codex" "$PX/marketplace/plugins/p/hooks"
printf '{"hooks":{}}\n' > "$PX/.claude/settings.json"; printf '{"hooks":{}}\n' > "$PX/.codex/hooks.json"
# shellcheck disable=SC2016
printf '{"hooks":{"PreToolUse":[{"hooks":[{"type":"command","command":"bash \\"${CLAUDE_PLUGIN_ROOT}/hooks/a.sh\\""}]}]}}\n' > "$PX/marketplace/plugins/p/hooks/hooks.json"
if [ "$(wired_scripts "$PX" 2>&1)" = "marketplace/plugins/p/hooks/a.sh" ]; then ok "a plugin hooks.json command is enumerated under its plugin dir"; else bad "plugin hooks.json commands are not enumerated"; fi
printf 'marketplace/plugins/p/weird/x.sh\n' > "$FX/ppaths"
if [ "$(uncovered "$ROOT" "$FX/ppaths")" = "marketplace/plugins/p/weird/x.sh" ]; then ok "a plugin hook in an unscanned dir is reported uncovered"; else bad "plugin hook in an unscanned dir passes coverage"; fi

# A wired command that yields no script path must fail the enumeration (else its
# hook drops out of the sweep and an uncovered source passes), unless it is on
# the explicit allowlist in wired_scripts. The fx8 spellings: the quote closing
# before the slash, and an absolute path.
wire_fixture() { # <dir> <settings.json command|""> <plugin hooks.json command|"">
  rm -rf "$1"; mkdir -p "$1/.claude" "$1/.codex" "$1/marketplace/plugins/p/hooks"
  printf '{"hooks":{}}\n' > "$1/.codex/hooks.json"
  local f c
  for f in ".claude/settings.json:$2" "marketplace/plugins/p/hooks/hooks.json:$3"; do
    c="${f#*:}"; f="${f%%:*}"
    if [ -z "$c" ]; then printf '{"hooks":{}}\n' > "$1/$f"; continue; fi
    node -e 'console.log(JSON.stringify({hooks:{PreToolUse:[{hooks:[{type:"command",command:process.argv[1]}]}]}}))' "$c" > "$1/$f"
  done
}
UX="$FX/unparsed"
# shellcheck disable=SC2016
wire_fixture "$UX" "" 'bash "${CLAUDE_PLUGIN_ROOT}"/hooks/x.sh'
if ux_out="$(wired_scripts "$UX" 2>&1)"; then bad "a plugin command with the quote closing before the slash was silently dropped (rc 0): $ux_out"; else ok "a plugin command with the quote closing before the slash fails the enumeration"; fi
wire_fixture "$UX" "" 'bash /opt/plug/hooks/x.sh'
if ux_out="$(wired_scripts "$UX" 2>&1)"; then bad "an absolute-path plugin command was silently dropped (rc 0): $ux_out"; else ok "an absolute-path plugin command fails the enumeration"; fi
# shellcheck disable=SC2016
wire_fixture "$UX" 'bash "$CLAUDE_PROJECT_DIR"/scripts/hooks/x.sh' ""
if ux_out="$(wired_scripts "$UX" 2>&1)"; then bad "a settings.json command with the quote closing before the slash was silently dropped (rc 0): $ux_out"; else ok "a settings.json command with the quote closing before the slash fails the enumeration"; fi
case "$ux_out" in *'scripts/hooks/x.sh'*) ok "the failure names the unparsed command" ;; *) bad "the failure does not name the unparsed command: $ux_out" ;; esac
# shellcheck disable=SC2016
wire_fixture "$UX" 'node "$CLAUDE_PROJECT_DIR/scripts/trust/shadow-ledger.mjs" pre' ""
if ux_out="$(wired_scripts "$UX" 2>&1)"; then ok "an allowlisted non-shell command does not fail the enumeration"; else bad "an allowlisted command failed the enumeration: $ux_out"; fi
# an allowlisted prefix must not exempt a hook script chained after it
# shellcheck disable=SC2016
wire_fixture "$UX" 'node "$CLAUDE_PROJECT_DIR/scripts/trust/shadow-ledger.mjs" pre; bash /opt/hooks/x.sh' ""
if ux_out="$(wired_scripts "$UX" 2>&1)"; then bad "an allowlisted prefix hid a chained shell hook (rc 0): $ux_out"; else ok "an allowlisted prefix does not exempt a chained shell hook"; fi

echo "== every wired hook script resolves"
N=0
CL="$FX/closure"; : > "$CL"; export CLOSURE_OUT="$CL"
if ! SCRIPTS="$(wired_scripts "$ROOT" 2>&1)"; then bad "wiring enumeration failed: $SCRIPTS"; SCRIPTS=""; fi
if [ -z "$SCRIPTS" ]; then bad "no wired hook scripts found in settings.json / hooks.json"; fi
while IFS= read -r rel; do
  [ -n "$rel" ] || continue
  case "$rel" in
    # The launcher itself runs BEFORE hook-integrity (it starts node); it is not
    # a hook script and is never passed through verifyProjectHookIntegrity.
    scripts/lib/run-node.sh|marketplace/plugins/*/hooks/run-node.sh) continue ;;
    *.sh) ;;
    *) continue ;;
  esac
  N=$((N + 1))
  # --optional (the himmel-ops plugin hooks) skips a missing script at run time,
  # but this sweep runs on the full checkout, so a wired path with no file is a
  # defect (deleted or misspelled hook), not a no-op.
  if [ ! -f "$ROOT/$rel" ]; then bad "$rel (wired but not present)"; continue; fi
  if out="$(check_closure "$ROOT" "$ROOT/$rel" 2>&1)"; then
    if [ -z "$out" ]; then ok "$rel"; else bad "$rel"; printf '       %s\n' "$out"; fi
  else
    bad "$rel (resolver failed to run)"; printf '       %s\n' "$out"
  fi
done <<< "$SCRIPTS"
CLOSURE_OUT="" # the fixture rows above are done; stop recording
# Every file hook-integrity walks must sit where impacted-suites.sh selects this
# suite, else a PR touching only that file (guardrails/lib.sh, queue-lock.sh)
# adds an unresolvable source and CI never runs the sweep.
sort -u "$CL" > "$CL.u"
if unc="$(uncovered "$ROOT" "$CL.u")" && [ -z "$unc" ]; then ok "every closure file is selected by a scan_roots row"; else bad "closure files outside scan_roots coverage (add a row in scripts/cr/impacted-suites.sh): $(printf '%s' "$unc" | tr '\n' ' ')"; fi
if [ "$N" -ge 10 ]; then ok "enumerated $N wired hook scripts"; else bad "only $N wired hook scripts enumerated (parser drift?)"; fi

echo "passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
