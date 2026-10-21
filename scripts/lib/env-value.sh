#!/usr/bin/env bash
# env-value.sh — the one reader for environment-specific values (repo and owner
# slugs, Pages URLs, image paths, accounts) that must not be literals in scripts.
# See docs/internals/hardcoded-env-values.md.
#
# Sourced (not run). bash 3.2-safe; uses `return`, never `exit`.
#
# env_value <KEY> [discovery-cmd [args...]] — print the value, rc 0; else rc 1
# and print nothing. Resolution order:
#   1. ~/.himmel/config.json .env_values.<KEY>  (operator-owned file)
#   2. the discovery command's stdout (git origin, gh, github.repository)
#   3. fail closed
# There is deliberately NO environment-variable seam: a value that widens a
# safety boundary (merge-on-green's allowed public origin) must not be settable
# by a launching environment. A config.json that exists but cannot be read, or
# holds a non-string value for KEY, fails closed rather than falling through to
# discovery, so a typo cannot silently swap the source.
# Values already owned by .env (JIRA_BASE_URL) keep that home; read them directly.

# _env_value_config <KEY> — rc 0 and the value on stdout when config.json has
# it; rc 1 when config.json or the key is absent; rc 2 when it is unreadable or
# the value is not a single-line string.
_env_value_config() {
    local file="$HOME/.himmel/config.json"
    [ -f "$file" ] || return 1
    node -e '
        const fs = require("fs");
        const [file, key] = process.argv.slice(1);
        let doc;
        try { doc = JSON.parse(fs.readFileSync(file, "utf8")); } catch { process.exit(2); }
        const vals = doc && typeof doc === "object" ? doc.env_values : undefined;
        if (vals === undefined || vals === null) process.exit(1);
        if (typeof vals !== "object" || Array.isArray(vals)) process.exit(2);
        if (!Object.prototype.hasOwnProperty.call(vals, key)) process.exit(1);
        const v = vals[key];
        if (typeof v !== "string" || v === "" || /[\r\n\0]/.test(v)) process.exit(2);
        process.stdout.write(v + "\n");
    ' "$file" "$1" 2>/dev/null
}

env_value() {
    local key="${1:-}" val rc
    shift || true
    case "$key" in
        ''|*[!A-Za-z0-9_]*) return 1 ;;
    esac
    val=$(_env_value_config "$key"); rc=$?
    case "$rc" in
        0) printf '%s\n' "$val"; return 0 ;;
        1) ;;
        *) return 1 ;;
    esac
    [ "$#" -gt 0 ] || return 1
    # The trailing x keeps command substitution from stripping every trailing
    # newline, so `value` plus a blank line is seen as two lines, not one.
    val=$("$@" 2>/dev/null; rc=$?; printf x; exit "$rc") || return 1
    val=${val%x}
    val=${val%$'\n'}
    case "$val" in ''|*[[:cntrl:]]*) return 1 ;; esac
    printf '%s\n' "$val"
}
