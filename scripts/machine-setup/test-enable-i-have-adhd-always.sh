#!/usr/bin/env bash
# test-enable-i-have-adhd-always.sh — Hermetic: every path is under
# a mktemp dir passed as CLAUDE_CONFIG_DIR/HOME; the real HOME is never touched.
# shellcheck disable=SC2015  # `A && ok || bad`: ok/bad never fail, so C cannot run after A is true
# shellcheck disable=SC2016  # the wiring greps match literal `$script` / `$SCRIPT_DIR` text on purpose
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
SCRIPT="$HERE/enable-i-have-adhd-always.sh"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/adhd-always.XXXXXX")" || exit 1
trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
ok()  { pass=$((pass + 1)); echo "ok   - $1"; }
bad() { fail=$((fail + 1)); echo "FAIL - $1"; }

mkcfg() {   # <name> <installed 0|1> -> prints the config dir
    local d="$TMP/$1"
    mkdir -p "$d/plugins"
    if [ "$2" = 1 ]; then
        echo '{"version":2,"plugins":{"i-have-adhd@himmel":[{"scope":"user","version":"0.4.1"}]}}' > "$d/plugins/installed_plugins.json"
    else
        echo '{"version":2,"plugins":{"lean-skills@himmel":[{"scope":"user","version":"0.2.4"}]}}' > "$d/plugins/installed_plugins.json"
    fi
    echo "$d"
}
run() {   # <cfg> [env...] -- args  (HOME is a decoy so a leak is visible)
    local cfg="$1"; shift
    env HOME="$TMP/decoy-home" CLAUDE_CONFIG_DIR="$cfg" "$@"
}

# 1. installed + no flag -> created, one line printed
cfg="$(mkcfg a 1)"
out="$(run "$cfg" bash "$SCRIPT")"
[ -f "$cfg/.i-have-adhd-always" ] && ok "creates the flag when the plugin is installed" || bad "flag not created"
[ "$(printf '%s\n' "$out" | grep -c 'always-on enabled')" = 1 ] && ok "prints exactly one enabled line" || bad "enabled line count: $out"

# 2. re-run -> silent no-op, mtime untouched
before="$(stat -c %Y "$cfg/.i-have-adhd-always" 2>/dev/null || stat -f %m "$cfg/.i-have-adhd-always")"
out="$(run "$cfg" bash "$SCRIPT")"
after="$(stat -c %Y "$cfg/.i-have-adhd-always" 2>/dev/null || stat -f %m "$cfg/.i-have-adhd-always")"
[ -z "$out" ] && [ "$before" = "$after" ] && ok "re-run is a silent no-op" || bad "re-run not a no-op: '$out'"

# 3. opt-out + no flag -> not created
cfg="$(mkcfg b 1)"
out="$(run "$cfg" HIMMEL_NO_ADHD_ALWAYS=1 bash "$SCRIPT")"
[ ! -e "$cfg/.i-have-adhd-always" ] && [ -z "$out" ] && ok "opt-out skips creation" || bad "opt-out created the flag"

# 4. opt-out after the operator deleted the flag -> stays deleted across runs
run "$cfg" bash "$SCRIPT" >/dev/null
rm -f "$cfg/.i-have-adhd-always"
run "$cfg" HIMMEL_NO_ADHD_ALWAYS=1 bash "$SCRIPT" >/dev/null
[ ! -e "$cfg/.i-have-adhd-always" ] && ok "deleted flag is not recreated under opt-out" || bad "recreated under opt-out"

# 5. plugin not installed -> not created
cfg="$(mkcfg c 0)"
run "$cfg" bash "$SCRIPT" >/dev/null
[ ! -e "$cfg/.i-have-adhd-always" ] && ok "no flag when the plugin is not installed" || bad "flag created without the plugin"

# 6. --check writes nothing
cfg="$(mkcfg d 1)"
out="$(run "$cfg" bash "$SCRIPT" --check)"
[ ! -e "$cfg/.i-have-adhd-always" ] && printf '%s' "$out" | grep -q 'would create' && ok "--check reports and writes nothing" || bad "--check wrote or was silent: $out"

# 7. real HOME decoy untouched
[ ! -e "$TMP/decoy-home" ] && ok "HOME was never written" || bad "HOME decoy was written"

# 8. wiring: both entry points call the helper
fn="$(grep -A10 '^enable_adhd_always()' "$ROOT/scripts/himmel-update.sh")"
grep -Eq 'script="\$ROOT/scripts/machine-setup/enable-i-have-adhd-always\.sh"' <<< "$fn" \
    && grep -Eq '^[[:space:]]*bash "\$script" \|\| true' <<< "$fn" \
    && grep -Eq '^[[:space:]]*bash "\$script" --check \|\| true' <<< "$fn" \
    && ok "himmel-update.sh invokes the helper (apply and check)" || bad "himmel-update.sh not wired"
grep -Eq '^[[:space:]]*bash "\$SCRIPT_DIR/enable-i-have-adhd-always\.sh"' "$ROOT/scripts/machine-setup/install-plugins.sh" \
    && ok "install-plugins.sh invokes the helper" || bad "install-plugins.sh not wired"

echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
