#!/usr/bin/env bash
# Cadence-scoped PreToolUse Bash ALLOW hook.
#
# WHY: the daily vault-lint cadence leg runs the
# obsidian-triage:vault-lint skill, whose engine is
#   python <himmel-root>/marketplace/plugins/obsidian-triage/skills/vault-lint/vault_lint.py <vault>
# `python` is deliberately NOT in auto-approve-safe-bash.sh's safe set (it is a
# programmable interpreter), so the literal engine command prompts for approval
# — and a prompt at 04:00 with nobody to answer it wastes the run (a permission plea once killed the vault lint,
# classified as a vacuous "complete"). The runner fires claude in the VAULT cwd (not the himmel
# repo), so the model emits an ABSOLUTE engine path; that path's Windows drive
# colon also breaks the allow-list `:*` prefix syntax, so a static
# `permissions.allow` belt is unreliable here. This hook is the authoritative
# fix: it reads the full command TEXT and decides itself, so neither the static
# matcher's metacharacter bail nor the colon problem can reach it.
#
# This hook grants ONLY the enumerated cadence engine scripts — initially just
# the vault-lint engine. Grow ENGINE_LIST per leg as more cadence engines are
# added (each entry: <binary>:<normalized-path-suffix>, suffix with `\`->`/`).
#
# CONTRACT (inverted vs the block-* hooks; mirrors auto-approve-safe-bash):
#   * NEVER blocks/denies. Worst case it stays silent and the command falls
#     through to the normal permission flow. FAIL-OPEN: missing jq, unparseable
#     input, not-an-enumerated-engine -> silent exit 0, no decision.
#   * Only ever EMITS "allow". The deny-list + block-* deny hooks remain the
#     hard backstop; a deny from them WINS over an allow here.
#   * Wired ONLY in cadence-settings.json (--settings for cadence runs), so
#     interactive sessions are untouched.
#
# SAFETY MODEL — a command is granted ONLY when ALL hold:
#   1. tool_name is Bash.
#   2. No command/process substitution anywhere: no `$(`  `` ` ``  `<(`  `>(`.
#   3. No shell-level redirect to a real file (`>`/`>>` output, `<` input) and
#      no heredoc; only /dev/null sinks and fd-dups (`2>&1`, `<&0`) are
#      tolerated — a grant must never reshape the process's I/O at the shell
#      level.
#   4. The command is read once by the shared command model (scripts/lib/
#      bash-ast.sh, bash_ast_positions, which needs shfmt): every command in it
#      is a plain top-level or piped simple command (no subshell, group,
#      compound, background, wrapper or eval) and is EITHER an enumerated
#      engine invocation, a read-shaped gh api call, OR a benign nav wrapper
#      (cd/pushd), so a `cd <repo> && python <engine> <vault>` paraphrase is
#      covered. Any other command -> fall through (do not grant). Every word is
#      judged as bash hands it to the process (quotes and escapes removed), and
#      relative args are judged against each directory the model says the
#      command can run in. Without shfmt nothing is granted and the message
#      names shfmt.
#   5. An enumerated engine invocation is:
#        binary == python|python3|node|bash   (bare interpreter name; no path,
#                                    no .exe — a `$cmd`/absolute interpreter
#                                    binary is NOT granted: fail-safe).
#                                    It also grants
#                                    THREE engines (harvest-clip-body-batch.py,
#                                    ig-media-fetch.py, x-media-fetch.py) invoked as `uv run
#                                    [--python <ver>] python <script>` — the
#                                    shape their own leg docs use — via
#                                    match_uv_prefix below, optionally preceded
#                                    by the single literal `PYTHONUTF8=1`
#                                    assignment those same docs also use
#                                    (RETASK R2124A: innocuous, unlike
#                                    PYTHONPATH — cannot shadow a module).
#                                    Every other engine still requires the
#                                    bare interpreter with no leading anything.
#        AND the token IMMEDIATELY after the binary (no python interpreter flag
#            such as -c/-m in between, so `python -c "evil" …` is NOT granted)
#            is a LITERAL path (no $ ` or substitution) whose normalised form
#            equals <himmel-root>/<enumerated suffix> EXACTLY, where
#            himmel-root is derived from THIS hook's own location. A tail-only
#            match is not enough — see ROOT ANCHOR.
#            Consequently a RELATIVE engine path is never granted: it depends
#            on a cwd the hook cannot vouch for.
#      Cache root anchor: the obsidian-triage plugin
#      itself RUNS from the Claude Code plugin cache
#      (~/.claude/plugins/cache/himmel/obsidian-triage/<version>/...), so a
#      leg session's engine path legitimately resolves there, not just under
#      this checkout -- both are sanctioned copies of the same plugin. The
#      grant additionally requires the cache dir basename to be
#      version-shaped AND the specific engine file to actually exist under it
#      -- stricter than the checkout anchor, since a cache install is
#      optional and its presence on disk is the only proof it is real. Every
#      other rule above and below (bare interpreter, literal-path-only,
#      flag/arg constraints) is unchanged; this only widens WHERE the same
#      enumerated file may live.
#   6. Trailing args are constrained too: an unconstrained trailing-arg grant let an injected `--config <file>`
#      point vault_lint.py's report_path -- join()'d without containment and
#      opened "w" -- at an attacker-writable path riding this hook's auto-allow.
#      Every remaining token after the engine script must be EITHER:
#        - a per-engine safe flag: boolean, no value, cannot redirect I/O (see
#          flag_is_safe; vault-lint's set is `--json`/`--no-report`, derived
#          from its SKILL.md documented flags. `--config` and any future
#          path-valued output flag are deliberately excluded), OR
#        - a path argument that can only ever resolve inside the vault the
#          cadence session is running in: a RELATIVE token with no `..`
#          segment (cannot escape whatever directory it resolves against), or
#          an ABSOLUTE token that names -- or nests under -- the session's own
#          cwd, resolved from this hook's payload `.tool_input.cwd`/`.cwd`
#          field (same field block-graphify-egress.sh / block-terminal-write-
#          fence.sh already trust for their own containment checks; the
#          cadence runner fires claude in the vault cwd -- see the file header
#          above).
#      A token containing `$` (unprovable literal -- the cadence's environment
#      is not something this hook can audit), a leading `~` (tilde expansion),
#      a brace `{`/`}` (brace expansion), a glob metacharacter `*`/`?`/`[`
#      (filename expansion -- all of these are shell-expanded at runtime to a
#      path this hook cannot see from the token text alone), a `..` segment,
#      or an absolute path with no resolvable session cwd is refused:
#      fail-safe, the whole segment (and so the command) falls through
#      ungranted, same posture as every other rule in this file.
#      vault_lint.py's OWN containment (its `--config`/report_path join has
#      none) is a separate, not-yet-fixed engine-side concern -- tracked for a
#      follow-up ticket, out of scope for this hook.
#   7. A `gh api repos/...` segment is ALSO granted, but ONLY
#      when it is READ-shaped -- the harvest/luna-ingest legs only ever read
#      github metadata through this hook, never write it. Granted iff ALL
#      hold: the (quote-reassembled) endpoint right after `api` starts with
#      `repos/`, carries no `$`, and carries no `..`; AND every other token is
#      one of a small explicit safe-flag ALLOWLIST (`--jq`/`-q`, `--paginate`,
#      `--cache`, `--slurp`, `-H`/`--header`, plus the value immediately after
#      a value-taking one of those). RETASK R2124A: this is deliberately an
#      ALLOWLIST, not a denylist of dangerous flags -- a denylist for an
#      external CLI's flag surface is structurally unwinnable (there is
#      always one more flag, and a mangled/escaped token can evade a literal
#      pattern match). See segment_is_gh_read. Any token not on the allowlist
#      -- a write verb, `--hostname`, a non-`repos/` endpoint, or anything
#      unrecognised, escaped or not -- falls through ungranted by the same
#      default branch, same fail-safe posture as every rule above.
#
# No bypass env var — there is nothing to bypass (the hook only grants).
# To DISABLE, remove it from cadence-settings.json.
# bash 3.2-compatible (no mapfile / associative arrays).
set -uo pipefail

# A missing prim.sh leaves canon_path unset, so the grant check below refuses.
# shellcheck source=../lib/prim.sh
. "$(dirname "${BASH_SOURCE[0]}")/../lib/prim.sh" 2>/dev/null

# Enumerated cadence engines. Add legs here as `<bin>:<normalized suffix>`
# pairs. The suffix is the per-leg registry key; it is joined to the ROOT ANCHOR
# below and matched EXACTLY (backslashes folded to `/`, case-insensitively), so
# it stays machine-independent while still naming one specific file on disk.
# List every interpreter binary a leg may use (python AND python3) so a
# paraphrased interpreter name still matches the same engine.
VAULT_LINT_SUFFIX="marketplace/plugins/obsidian-triage/skills/vault-lint/vault_lint.py"
# The harvest/triage/ig-media-enrich cadence legs, enumerated exactly
# as those leg sessions specified. All live under the obsidian-triage plugin's
# tools/ dir (tools/lib/ for evidence-kind.mjs), same ROOT ANCHOR posture as
# vault_lint above -- one specific file beside this hook's own checkout, never
# a same-named file elsewhere.
HARVEST_SUFFIX="marketplace/plugins/obsidian-triage/tools/harvest-clip-body-batch.py"
IS_THIN_SUFFIX="marketplace/plugins/obsidian-triage/tools/is-thin-cli.mjs"
EVIDENCE_KIND_SUFFIX="marketplace/plugins/obsidian-triage/tools/lib/evidence-kind.mjs"
DAILY_TIMELINE_SUFFIX="marketplace/plugins/obsidian-triage/tools/daily-timeline.mjs"
IG_MEDIA_FETCH_SUFFIX="marketplace/plugins/obsidian-triage/tools/ig-media-fetch.py"
X_MEDIA_FETCH_SUFFIX="marketplace/plugins/obsidian-triage/tools/x-media-fetch.py"
ENSURE_DEPS_SUFFIX="marketplace/plugins/obsidian-triage/tools/ensure-deps.sh"
# The harvest-clips.md thin-body
# enrich rungs (~lines 210-211) dispatch these two X/reddit enrichers, but
# they were missing from ENGINE_LIST -- 5 thin X-tweet clips parked as
# retryable partial on a permission plea because of it. Same tools/ root +
# node binary as IS_THIN_SUFFIX/EVIDENCE_KIND_SUFFIX/DAILY_TIMELINE_SUFFIX
# above.
FXTWITTER_SUFFIX="marketplace/plugins/obsidian-triage/tools/fxtwitter-enrich.mjs"
REDDIT_ENRICH_SUFFIX="marketplace/plugins/obsidian-triage/tools/reddit-enrich.mjs"
ENGINE_LIST="python:${VAULT_LINT_SUFFIX} python3:${VAULT_LINT_SUFFIX} \
python:${HARVEST_SUFFIX} python3:${HARVEST_SUFFIX} \
python:${IG_MEDIA_FETCH_SUFFIX} python3:${IG_MEDIA_FETCH_SUFFIX} \
python:${X_MEDIA_FETCH_SUFFIX} python3:${X_MEDIA_FETCH_SUFFIX} \
node:${IS_THIN_SUFFIX} node:${EVIDENCE_KIND_SUFFIX} node:${DAILY_TIMELINE_SUFFIX} \
node:${FXTWITTER_SUFFIX} node:${REDDIT_ENRICH_SUFFIX} \
bash:${ENSURE_DEPS_SUFFIX}"

# `--print-engine-list` prints ENGINE_LIST one token per
# line, then exits -- placed AFTER the assembly above (so it reflects the
# real value) but BEFORE both the ENGINE_ROOT_POSIX guard below (which would
# otherwise silently `exit 0` and swallow the print on a machine where the
# root cannot be resolved) and stdin is ever read (a PreToolUse invocation of
# this flag passes no JSON payload, so reading stdin first would hang). This
# is so `himmelctl status` (a later PR) can shell out to it instead of a
# copied literal or a JS regex over this file -- the hook stays the SINGLE
# source of the allow-list. `"${1:-}"` is set -u/-o pipefail safe: $1 may be
# unset on a normal PreToolUse invocation.
if [ "${1:-}" = "--print-engine-list" ]; then
    for entry in $ENGINE_LIST; do
        printf '%s\n' "$entry"
    done
    exit 0
fi

# ROOT ANCHOR. The suffix above
# is a REGISTRY key, never sufficient on its own: a bare tail match is not tied
# to any particular checkout, so combined with the benign `cd` wrapper below,
#   cd /tmp/evil && python marketplace/.../vault_lint.py
# matched on suffix alone and handed an automatic allow to an ATTACKER-supplied
# vault_lint.py. That is the exact opposite of this hook's contract. The grant
# is therefore pinned to the engine that ships beside THIS hook: the candidate
# must resolve to <himmel-root>/<suffix> exactly, so a relative path (which
# depends on a cwd the hook cannot vouch for) and a same-suffix path under any
# other root are both refused. This matters because the cadence session
# processes untrusted vault clips — prompt injection into the emitted command
# is the threat this anchor closes.
ENGINE_ROOT_POSIX="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." 2>/dev/null && pwd)"
# An unresolvable root would collapse the anchor to a bare "/<suffix>" match,
# which is a grant this hook must never make. No root -> no decision.
[ -n "$ENGINE_ROOT_POSIX" ] || exit 0
ENGINE_ROOT_MIXED="$ENGINE_ROOT_POSIX"
if command -v cygpath >/dev/null 2>&1; then
    ENGINE_ROOT_MIXED=$(cygpath -m "$ENGINE_ROOT_POSIX" 2>/dev/null || printf '%s' "$ENGINE_ROOT_POSIX")
fi

# Secondary (plugin-cache) anchor. obsidian-triage
# leg sessions actually run the plugin from the Claude Code plugin cache, not
# this checkout, so a cache-rooted engine path is an equally sanctioned copy
# — see SAFETY MODEL point 5 addendum above. Derived from $HOME (same pattern
# as ENGINE_ROOT_POSIX deriving from this hook's own location); no new bypass
# env var — tests override $HOME itself when invoking the hook.
PLUGIN_CACHE_BASE="$HOME/.claude/plugins/cache/himmel/obsidian-triage"

# Lowercase helper — Windows path case (and drive-letter case) differs between
# the cygpath -m form and whatever the model emits, so the anchor compares
# case-insensitively. bash 3.2 has no ${v,,}.
_lc() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

# Is $1 (already normalized) the engine <root>/<suffix> beside this hook?
# EXACT match against both the POSIX (/c/...) and mixed (C:/...) absolute forms.
path_is_rooted_engine() {
    local cand lc_cand lc_b
    cand="$1"
    # POSIX form: EXACT compare. A case-only difference names a different file
    # on a case-sensitive filesystem, so folding case here would widen the grant
    [ "$cand" = "${ENGINE_ROOT_POSIX}/$2" ] && return 0
    # Mixed (Windows) form: case-insensitive, per the drive-letter/path-case note
    # — but ONLY when cygpath actually produced a DISTINCT Windows-style root.
    # Without cygpath, ENGINE_ROOT_MIXED is the SAME string as ENGINE_ROOT_POSIX,
    # so a case-insensitive re-compare here would auto-allow a case-twin POSIX
    # path that names a DIFFERENT file on a case-sensitive filesystem.
    # Refuse rather than re-compare the
    # identical POSIX string; this keeps every accept branch at most as
    # permissive as the exact POSIX byte-for-byte compare above.
    if [ "$ENGINE_ROOT_MIXED" != "$ENGINE_ROOT_POSIX" ]; then
        lc_cand=$(_lc "$cand")
        lc_b=$(_lc "${ENGINE_ROOT_MIXED}/$2")
        [ "$lc_cand" = "$lc_b" ] && return 0
    fi
    # Checkout anchor missed -- try the plugin-cache secondary anchor
    # Before giving up.
    path_is_cache_rooted_engine "$cand" "$2"
}

# Is $1 (already normalized) an obsidian-triage engine rooted under a
# VERSION-SHAPED dir of PLUGIN_CACHE_BASE, where the engine file actually
# exists on disk? Suffix $2 must live under
# marketplace/plugins/obsidian-triage/ -- only that plugin's engines get
# cache anchoring; every other suffix (there are none today, but the guard
# stays fail-safe against a future non-obsidian-triage entry) is refused
# outright. Mirrors path_is_rooted_engine's dual-form (exact POSIX,
# case-insensitive mixed-only-when-distinct) compare, per version dir.
path_is_cache_rooted_engine() {
    local cand="$1" suf="$2" tail _vd _b vd_posix vd_mixed lc_cand lc_b
    tail="${suf#marketplace/plugins/obsidian-triage/}"
    [ "$tail" != "$suf" ] || return 1
    for _vd in "$PLUGIN_CACHE_BASE"/*/; do
        [ -d "$_vd" ] || continue
        _b="$(basename "$_vd")"
        # Version-shaped basename only: digits and dots, no empty/leading/
        # trailing/doubled dot. Same fail-safe pattern style as
        # match_uv_prefix's version check below.
        case "$_b" in ''|*[!0-9.]*|.*|*.|*..*) continue ;; esac
        # The engine file must actually exist under this version dir -- pins
        # the grant to a real installed engine (stricter than the checkout
        # anchor, deliberately: a cache install is optional).
        [ -f "${_vd%/}/$tail" ] || continue
        vd_posix="$(cd "$_vd" 2>/dev/null && pwd)"
        [ -n "$vd_posix" ] || continue
        [ "$cand" = "${vd_posix}/$tail" ] && return 0
        vd_mixed="$vd_posix"
        if command -v cygpath >/dev/null 2>&1; then
            vd_mixed=$(cygpath -m "$vd_posix" 2>/dev/null || printf '%s' "$vd_posix")
        fi
        # Same guard as above: only re-compare case-insensitively
        # when cygpath produced a DISTINCT mixed form.
        [ "$vd_mixed" != "$vd_posix" ] || continue
        lc_cand=$(_lc "$cand")
        lc_b=$(_lc "${vd_mixed}/$tail")
        [ "$lc_cand" = "$lc_b" ] && return 0
    done
    return 1
}

is_engine_binary() {
    case "$1" in
        python|python3|node|bash) return 0 ;;
    esac
    return 1
}

# Optional `uv run [--python <ver>] python` prefix ahead of the script token
# -- the one shape harvest-clip-body-batch.py's own leg docs use
# (ig-media-enrich.md/x-media-enrich.md). Only this segment's own caller
# (segment_is_engine) may treat a match as an engine invocation, and it does
# so ONLY for the harvest, ig-media-fetch and x-media-fetch suffixes -- see the
# via_uv guard there. `--python`'s
# value must be a literal digits-and-dots version string (no $, no glob): same
# fail-safe posture as every other literal-token check in this file. Sets
# UV_PREFIX_LEN to the number of tokens the matched prefix consumed. Returns 1
# (no match, do not grant) on anything else, including a bare `uv` with no
# `run` or no trailing `python`.
match_uv_prefix() {
    local -a w=("$@")
    local n=${#w[@]}
    UV_PREFIX_LEN=0
    [ "$n" -ge 3 ] || return 1
    [ "${w[0]}" = "uv" ] && [ "${w[1]}" = "run" ] || return 1
    local idx=2 ver
    if [ "$idx" -lt "$n" ] && [ "${w[$idx]}" = "--python" ]; then
        ver="${w[$((idx + 1))]:-}"
        # Digits-and-dots only (rejects $, globs, an absent value), AND a real
        # numeric version shape -- RETASK R2124A codex-3: the digits-and-dots
        # charset check alone still let `.`/`..` through (neither contains a
        # char outside 0-9.). Equivalent to ^[0-9]+(\.[0-9]+)*$: also refuses
        # empty, a leading or trailing dot, and a doubled dot.
        case "$ver" in
            ''|*[!0-9.]*|.*|*.|*..*) return 1 ;;
        esac
        idx=$((idx + 2))
    fi
    [ "$idx" -lt "$n" ] && [ "${w[$idx]}" = "python" ] || return 1
    UV_PREFIX_LEN=$((idx + 1))
    return 0
}

# Is $1 (already normalized) the session's own cwd -- SESSION_CWD_POSIX /
# SESSION_CWD_MIXED, computed later in the main flow from the hook payload's
# `.tool_input.cwd`/`.cwd` -- or nested under it? Mirrors path_is_rooted_engine's
# dual-form (exact POSIX, case-insensitive mixed) compare and the same
# cygpath-less guard: without a cygpath-produced
# DISTINCT mixed root, re-comparing the identical POSIX string case-
# insensitively would auto-allow a case-twin POSIX path naming a DIFFERENT
# file on a case-sensitive filesystem.
path_is_under_session_cwd() {
    local cand="$1" lc_cand lc_root
    [ "$cand" = "$SESSION_CWD_POSIX" ] && return 0
    case "$cand" in "$SESSION_CWD_POSIX"/*) return 0 ;; esac
    [ "$SESSION_CWD_MIXED" != "$SESSION_CWD_POSIX" ] || return 1
    lc_cand=$(_lc "$cand")
    lc_root=$(_lc "$SESSION_CWD_MIXED")
    [ "$lc_cand" = "$lc_root" ] && return 0
    case "$lc_cand" in "$lc_root"/*) return 0 ;; esac
    return 1
}

# Fold backslashes to forward slashes. The word is already what bash hands the
# process (the command model removed its quotes and escapes), so nothing else
# is stripped here.
norm_path() {
    local p="$1"
    # Fold backslashes to forward slashes so a Windows engine path matches the
    # suffix. `'\\'` is correct: single quotes pass two backslashes literally and
    # tr unescapes them to one (SC1003 is a false positive on this idiom).
    # shellcheck disable=SC1003
    printf '%s' "$p" | tr '\\' '/'
}

# Is `flag` a known-safe boolean flag for the engine matched at suffix `esuf`?
# Safe = takes no value and cannot redirect input/output outside the vault.
# Per-engine, keyed by suffix so a future leg's flags stay scoped to its own
# engine. vault-lint's set is derived from its SKILL.md documented flags
# (marketplace/plugins/obsidian-triage/skills/vault-lint/SKILL.md):
#   --json       prints full detail to stdout only; no file I/O change.
#   --no-report  suppresses the written report; removes a write, adds none.
# `--config PATH` is deliberately EXCLUDED: it points the engine at an attacker-choosable JSON file whose
# `report_path` is join()'d without containment and opened "w" in
# vault_lint.py -- an arbitrary-file-write primitive riding this hook's
# auto-allow. vault_lint.py's argparse defines no other path-valued flag, so
# none is added here; a future one would need its own containment check, not
# a bare inclusion in this list.
#
# Several of the newly-enumerated engines document
# VALUE-taking flags (`--limit N`, `--scan-only FILE`, ...). This function only
# ever judges the FLAG TOKEN itself -- segment_is_engine's tail loop checks
# each token independently, so a flag's value is a SEPARATE token that still
# has to clear arg_is_vault_safe on its own merits (path containment, no `..`,
# no `$`/glob/tilde). That is exactly the same one-hop safety vault_lint's
# --json/--no-report get; it differs from vault_lint's excluded --config only
# in that none of these tools re-read their path argument as a config file
# with a SECOND, uncontained embedded path (the two-hop risk --config carries)
# -- each value here is used directly, so containing the CLI token is enough.
flag_is_safe() {
    local esuf="$1" flag="$2"
    case "$esuf" in
        "$VAULT_LINT_SUFFIX")
            case "$flag" in
                --json|--no-report) return 0 ;;
            esac
            return 1 ;;
        "$HARVEST_SUFFIX")
            case "$flag" in
                --dry-run|--rescan-flags|--firecrawl-thin| \
                --limit|--date|--scan-only|--firecrawl-budget) return 0 ;;
            esac
            return 1 ;;
        "$IG_MEDIA_FETCH_SUFFIX")
            case "$flag" in
                --dry-run|--include-evidence| \
                --limit|--whisper-model|--apply-digest|--digest-file| \
                --flag-screen|--detail) return 0 ;;
            esac
            return 1 ;;
        "$X_MEDIA_FETCH_SUFFIX")
            case "$flag" in
                --dry-run|--include-evidence|--include-done| \
                --limit|--whisper-model|--apply-digest|--digest-file| \
                --flag-screen|--detail) return 0 ;;
            esac
            return 1 ;;
        "$EVIDENCE_KIND_SUFFIX")
            case "$flag" in
                --type|--url|--tags) return 0 ;;
            esac
            return 1 ;;
        "$DAILY_TIMELINE_SUFFIX")
            case "$flag" in
                --vault|--date|--daily) return 0 ;;
            esac
            return 1 ;;
        "$FXTWITTER_SUFFIX")
            # --vault/--limit are value-taking
            # but the value is a SEPARATE token still gated by
            # arg_is_vault_safe (same one-hop pattern as DAILY_TIMELINE_SUFFIX's
            # --vault / HARVEST_SUFFIX's --limit above); --dry-run/--reflag take
            # no value at all. No --config-shaped (embedded second path) or
            # output-redirect flag exists in fxtwitter-enrich.mjs's parser
            # (tools/fxtwitter-enrich.mjs argv loop) -- nothing to exclude.
            case "$flag" in
                --vault|--limit|--dry-run|--reflag) return 0 ;;
            esac
            return 1 ;;
        "$REDDIT_ENRICH_SUFFIX")
            # Same one-hop reasoning as FXTWITTER_SUFFIX above; reddit-enrich.mjs's
            # own argv loop defines --vault/--limit/--dry-run/--include-evidence
            # and nothing path-valued beyond --vault. No --config-shaped flag to
            # exclude.
            case "$flag" in
                --vault|--limit|--dry-run|--include-evidence) return 0 ;;
            esac
            return 1 ;;
    esac
    return 1
}

# Is $1 a token that can only ever resolve inside the vault the cadence
# session is running in? A RELATIVE token with no `..` segment can never
# escape whatever directory it is resolved against, so it is safe regardless
# of what that directory actually is. An ABSOLUTE token (POSIX or Windows
# drive-letter) is trusted only when it names -- or nests under -- the
# session's own cwd (SESSION_CWD_POSIX/SESSION_CWD_MIXED, resolved in the
# main flow). No resolvable session cwd -> an absolute token is refused
# outright: fail-safe, mirrors the ROOT ANCHOR's "no root -> no grant".
arg_is_vault_safe() {
    local tok="$1" norm
    # Unprovable literal -- a shell variable can resolve to anything the
    # cadence's environment holds, which this hook cannot audit (same
    # fail-safe rule already applied to the engine script token).
    case "$tok" in *'$'*) return 1 ;; esac
    norm=$(norm_path "$tok")
    [ -n "$norm" ] || return 1
    # Same fail-safe for the other shell-expansion forms: a literal-looking relative token
    # still expands OUTSIDE the vault at shell runtime via tilde expansion
    # (`~/private-vault`), brace expansion (`{a,b}`), or glob metacharacters
    # (`*`, `?`, `[`) -- none of those are provable from the token text
    # alone, so refuse rather than trust the literal reading. Checked on the
    # quote-stripped `norm` (not the raw `tok`) so a quoted `"~/foo"` -- whose
    # leading char is the quote, not the tilde -- is still caught.
    case "$norm" in '~'*) return 1 ;; esac
    case "$norm" in *'{'*|*'}'*|*'*'*|*'?'*|*'['*) return 1 ;; esac
    case "/$norm/" in */../*) return 1 ;; esac
    case "$norm" in
        /*|[A-Za-z]:/*)
            [ -n "$SESSION_CWD_POSIX" ] || return 1
            path_is_under_session_cwd "$norm" || return 1
            path_is_physically_in_vault "$norm" ;;
        *)
            # The shell resolves this token in every directory the command can
            # run in (BASES), so it must stay contained in each of them.
            local b
            for b in "${BASES[@]}"; do
                [ -n "$b" ] || continue
                path_is_physically_in_vault "$b/$norm" "$b" || return 1
            done
            return 0 ;;
    esac
}

# Does $1 still sit inside the vault once every symlink is resolved? The
# lexical checks above cannot see a symlinked directory inside the vault that
# points out of it. Resolves the deepest EXISTING ancestor (an argument may name
# a file the engine will create) and refuses when that cannot be resolved.
path_is_physically_in_vault() {
    local p="$1" root="${2:-$SESSION_CWD_PHYS}" rest="" d real
    while [ ! -e "$p" ] && [ ! -L "$p" ]; do
        rest="/$(basename "$p")$rest"
        d=$(dirname "$p")
        [ "$d" != "$p" ] || return 1
        p="$d"
    done
    # canon_path takes a directory. A directory resolves whole; a file resolves
    # its parent and keeps the leaf, and a symlink leaf is refused rather than
    # followed out of the vault.
    if [ -L "$p" ]; then
        return 1
    elif [ -d "$p" ]; then
        real=$(canon_path "$p") || return 1 # swallow-ok: failure refuses the grant
    else
        real=$(canon_path "$(dirname "$p")") || return 1 # swallow-ok: failure refuses the grant
        real="$real/$(basename "$p")"
    fi
    [ -n "$real" ] || return 1
    real="$real$rest"
    [ "$real" = "$root" ] && return 0
    case "$real" in "$root"/*) return 0 ;; esac
    return 1
}

# --whisper-model M makes faster-whisper download M from Hugging Face unless it
# is a built-in size name or an existing local directory, so an arbitrary
# org/repo would pull an untrusted model on an unattended run. Granted: a
# faster-whisper size name, or a directory that already exists in the vault.
whisper_model_is_safe() {
    local norm b
    norm=$(norm_path "$1")
    case "$norm" in
        tiny|tiny.en|base|base.en|small|small.en|medium|medium.en| \
        large|large-v1|large-v2|large-v3)
            # A same-named path on disk wins over the built-in size name.
            local shadowed=0
            for b in "${BASES[@]}"; do
                [ -n "$b" ] || continue
                if [ -e "$b/$norm" ] || [ -L "$b/$norm" ]; then shadowed=1; fi
            done
            [ "$shadowed" -eq 0 ] && return 0 ;;
    esac
    arg_is_vault_safe "$norm" || return 1
    case "$norm" in
        /*) [ -d "$norm" ] ;;
        *)  # The engine may run in any of BASES (a skipped cd, a pipe), so the dir must exist in each.
            for b in "${BASES[@]}"; do
                [ -n "$b" ] && [ -d "$b/$norm" ] || return 1
            done
            return 0 ;;
    esac
}

# Does `script` end with any enumerated suffix for binary `bin`? The list is
# <bin>:<suffix> pairs; we match the bin explicitly so a future leg's suffix
# cannot be reached via the wrong interpreter.
script_matches_engine() {
    local bin="$1" script="$2" norm entry ebin esuf
    norm=$(norm_path "$script")
    [ -n "$norm" ] || return 1
    local OLDIFS="$IFS"
    IFS=' '
    for entry in $ENGINE_LIST; do
        ebin="${entry%%:*}"
        esuf="${entry#*:}"
        [ "$ebin" = "$bin" ] || continue
        if path_is_rooted_engine "$norm" "$esuf"; then
            # Consumed by segment_is_engine to scope flag_is_safe to the
            # engine that actually matched.
            MATCHED_SUFFIX="$esuf"
            IFS="$OLDIFS"; return 0
        fi
    done
    IFS="$OLDIFS"
    return 1
}

# Is this one command an enumerated engine invocation? "$@" is its argv, one
# element per word after quote removal, so a quoted flag or path arrives as the
# text bash hands the process. Returns 0 = an allowed engine call.
segment_is_engine() {
    local -a w=("$@")
    local n=${#w[@]}
    [ "$n" -ge 2 ] || return 1
    local bin script_idx via_uv=0
    if [ "${w[0]}" = "uv" ]; then
        # `uv run [--python <ver>] python <script>` -- the shape
        # harvest-clip-body-batch.py's and ig-media-fetch.py's own leg docs
        # use. Restricted to those three engines below (after
        # script_matches_engine resolves MATCHED_SUFFIX), not opened up to
        # every python-based engine.
        match_uv_prefix "${w[@]}" || return 1
        bin="python"
        script_idx=$UV_PREFIX_LEN
        via_uv=1
    else
        is_engine_binary "${w[0]}" || return 1
        bin="${w[0]}"
        script_idx=1
    fi
    [ "$script_idx" -lt "$n" ] || return 1
    local script="${w[$script_idx]}"
    # The script must be a non-empty LITERAL path. A `$` that survived quote
    # removal cannot be proven to be the enumerated engine, so do not grant.
    [ -n "$script" ] || return 1
    # shellcheck disable=SC2016 # '$' is a literal dollar-sign match pattern
    case "$script" in
        *'$'*) return 1 ;;
    esac
    script_matches_engine "$bin" "$script" || return 1
    # The uv-run prefix is granted ONLY for the three engines documented as
    # using it -- a match against any other python-bin suffix (e.g.
    # vault_lint) via `uv run ... python <script>` is refused: that leg's own
    # docs invoke it with the bare interpreter, so widening this to "any
    # python engine, via uv" is not something any leg actually needs.
    if [ "$via_uv" -eq 1 ]; then
        case "$MATCHED_SUFFIX" in
            "$HARVEST_SUFFIX"|"$IG_MEDIA_FETCH_SUFFIX"|"$X_MEDIA_FETCH_SUFFIX") ;;
            *) return 1 ;;
        esac
    fi
    # Trailing args are constrained too (see the file header SAFETY MODEL
    # point 6). MATCHED_SUFFIX was set by script_matches_engine above. Every
    # remaining word must be a per-engine safe flag or a path that can only
    # resolve inside the vault; ANY other word -> do not grant (fall through
    # to the normal permission flow).
    local idx=$((script_idx + 1)) tok model_next=""
    while [ "$idx" -lt "$n" ]; do
        tok=$(norm_path "${w[$idx]}")
        idx=$((idx + 1))
        case "$tok" in
            -*) flag_is_safe "$MATCHED_SUFFIX" "$tok" || return 1
                model_next=""
                [ "$tok" = "--whisper-model" ] && model_next=yes ;;
            *)  if [ -n "$model_next" ]; then
                    whisper_model_is_safe "$tok" || return 1
                    model_next=""
                else
                    arg_is_vault_safe "$tok" || return 1
                fi ;;
        esac
    done
    return 0
}

# BASES: the physical directories the command being judged can run in, one per
# cwd candidate bash-ast gives it (CHAINS: each a US-joined chain of cd targets
# from the session cwd). An empty entry is a session cwd the hook was not given.
# A chain that cannot be resolved refuses the command.
set_bases() {
    local chain b t
    local -a els
    BASES=()
    for chain in "${CHAINS[@]}"; do
        b="$SESSION_CWD_PHYS"
        if [ -n "$chain" ]; then
            IFS=$'\x1f' read -ra els <<< "$chain"
            for t in "${els[@]}"; do
                case "$t" in
                    /*) ;;
                    *) [ -n "$b" ] || return 1; t="$b/$t" ;;
                esac
                b=$(cd -P "$t" 2>/dev/null && pwd -P) || return 1 # swallow-ok: failure refuses the grant
            done
        fi
        BASES+=("$b")
    done
    [ "${#BASES[@]}" -gt 0 ]
}

# A benign nav command (cd/pushd) that may prefix the engine call. Only the vault
# root or the checkout root is a contained target; a deeper one would re-root the
# later relative args, whose containment is judged against the base they run in.
# The target is judged from every base the cd itself can run in, and the engine's
# own cwd candidates come from the model, so a cd that was skipped (`||`), run in
# a pipe's subshell or run after the engine is not credited to the engine.
nav_target_is_contained() {
    local norm p real root b
    # shellcheck disable=SC1003 # '\' is a literal backslash match pattern
    case "$1" in *'\'*) return 1 ;; esac
    norm=$(norm_path "$1")
    case "$norm" in ''|-*|+*) return 1 ;; esac
    case "$norm" in
        *'$'*|'~'*|*'{'*|*'}'*|*'*'*|*'?'*|*'['*) return 1 ;;
    esac
    case "/$norm/" in */../*) return 1 ;; esac
    root=$(cd -P "$ENGINE_ROOT_POSIX" 2>/dev/null && pwd -P) || return 1 # swallow-ok: failure refuses the grant
    for b in "${BASES[@]}"; do
        case "$norm" in
            /*) p="$norm" ;;
            *)  [ -n "$b" ] || return 1
                p="$b/$norm" ;;
        esac
        real=$(cd -P "$p" 2>/dev/null && pwd -P) || return 1 # swallow-ok: failure refuses the grant
        [ -n "$real" ] || return 1
        if [ -n "$SESSION_CWD_PHYS" ] && [ "$real" = "$SESSION_CWD_PHYS" ]; then
            continue
        fi
        [ "$real" = "$root" ] || return 1
    done
    return 0
}

# Is this command a READ-shaped `gh api repos/...` call (see
# SAFETY MODEL point 7)? "$@" is its argv after quote removal. The endpoint is
# the word immediately after `api` (every documented cadence usage puts it
# there, e.g. `gh api repos/cli/cli` / `gh api "repos/${owner}/${repo}/issues/${n}"`);
# it must start with `repos/`, carry no `$`, and carry no `..` (a variable
# endpoint cannot be vouched for, and `..` has no legitimate reason to appear
# in a repo-scoped API path).
#
# Every OTHER word must be in an explicit ALLOWLIST of known-safe `gh api`
# flags -- ANYTHING else refuses the whole command. A denylist for an external
# CLI's flag surface is structurally unwinnable (there is always one more
# flag); an allowlist closes the whole family at once: `--raw-field`,
# `--hostname`, a future gh write flag, AND a mangled token are all just "not
# in the allowlist". Safe flags (gh api's own docs):
#   --jq/-q <expr>     read-only local JSON filtering
#   --paginate         follows pagination links (still GET-only under this
#                      gate, since -X/--method aren't on the allowlist at all)
#   --cache <dur>      client-side response caching
#   --slurp            wraps paginated --jq results in an array
#   -H/--header <val>  a request header; cannot induce a write or change host
# The word immediately after a value-taking safe flag is consumed as ITS value
# without being separately classified (it's free-form content, e.g. a jq
# expression -- not a flag to allowlist against).
segment_is_gh_read() {
    local -a w=("$@")
    local n=${#w[@]}
    [ "$n" -ge 3 ] || return 1
    [ "${w[0]}" = "gh" ] && [ "${w[1]}" = "api" ] || return 1
    local endpoint
    endpoint=$(norm_path "${w[2]}")
    [ -n "$endpoint" ] || return 1
    # shellcheck disable=SC2016 # '$' is a literal dollar-sign match pattern
    case "$endpoint" in *'$'*) return 1 ;; esac
    case "$endpoint" in repos/*) ;; *) return 1 ;; esac
    case "$endpoint" in *'..'*) return 1 ;; esac
    local idx=3 tok
    while [ "$idx" -lt "$n" ]; do
        tok=$(norm_path "${w[$idx]}")
        idx=$((idx + 1))
        case "$tok" in
            --paginate|--slurp) ;;
            --jq|-q|--cache|-H|--header)
                # Value-taking safe flag: skip the NEXT word as its value.
                # Missing value -> refuse (fail-safe).
                [ "$idx" -lt "$n" ] || return 1
                idx=$((idx + 1)) ;;
            *) return 1 ;;
        esac
    done
    return 0
}

# The command model's output, reduced to what this hook judges. Input: the
# bash_ast_positions array. Output: the single line REFUSE, or per command
#   P<prog> / [U] / C<cd chain, US-joined> (one per cwd candidate) / A<word> (one per argv word) / E
# A command is refused when it is not a plain top-level (or piped) simple
# command: opaque or wrapped programs, any enclosing compound/subshell/bg
# context, an unknown cwd, a non-literal or glob word, a control byte, a
# redirect other than a /dev/null sink or an fd-dup (a heredoc included), or a
# prefix assignment other than PYTHONUTF8 on `uv`.
IFS= read -r -d '' _CAE_JQ <<'CAE_JQ_EOF' || true # swallow-ok: read -d '' returns 1 at the heredoc's end
def ctl: test("[\u0001-\u001f\u007f]");
def okredir:
  .hdoc == false
  and (.fd == null or (.fd | type == "string" and test("^[0-9]+$")))
  and .w != null and .w.t == "lit" and (.w.g | not)
  and ( ((.op | IN(">", ">>", "&>", "&>>")) and .w.v == "/dev/null")
        or (.op == ">&" and (.w.v | test("^[0-9]$")))
        or (.op == "<&" and (.w.v | test("^[0-9-]$"))) );
def okpos:
  .opaque == null and ((.via | length) == 0)
  and (.in | all(. == "pipe"))
  and ((.cwd | length) > 0)
  and (.cwd | all(. != null and all(type == "string" and length > 0 and (ctl | not))))
  and (.redirs | all(okredir))
  and .prog != null and ((.argv | length) > 0)
  and (.argv | all(.t == "lit" and (.g | not) and (.v | ctl | not)))
  and .argv[0].v == .prog
  and (((.assigns | length) == 0) or (.prog == "uv" and .assigns == ["PYTHONUTF8"]));
if length > 0 and all(okpos) then
  .[] | ("P" + .prog),
        (if (.assigns | length) > 0 then "U" else empty end),
        (.cwd[] | "C" + join("\u001f")),
        (.argv[] | "A" + .v),
        "E"
else "REFUSE" end
CAE_JQ_EOF

emit_allow() {
    local reason
    reason=$(printf 'cadence-approve-engines: %s' "$1" | jq -Rs . 2>/dev/null) || reason='"enumerated cadence engine"'
    printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow","permissionDecisionReason":%s}}\n' "$reason"
    exit 0
}

# --- Fail open on anything we cannot evaluate ---
command -v jq >/dev/null 2>&1 || exit 0
input=$(cat 2>/dev/null || true)
[ -n "$input" ] || exit 0
tool=$(printf '%s' "$input" | jq -r '.tool_name // empty' 2>/dev/null || true)
[ "$tool" = "Bash" ] || exit 0
cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // empty' 2>/dev/null || true)
[ -n "$cmd" ] || exit 0

# Session cwd, same field + fallback order
# block-graphify-egress.sh / block-terminal-write-fence.sh already trust: the
# tool call's own cwd wins over the session-level one, since that is where the
# agent will actually run the command. This is the vault root arg_is_vault_safe
# containment-checks an absolute trailing arg against — the cadence runner
# fires claude in the vault cwd (see file header). Unresolvable/absent ->
# both stay empty, and arg_is_vault_safe refuses every absolute arg (fail-safe;
# relative, `..`-free args need no cwd and are unaffected).
cwd_raw=$(printf '%s' "$input" | jq -r '.tool_input.cwd // .cwd // empty' 2>/dev/null || true)
SESSION_CWD_POSIX=""
SESSION_CWD_MIXED=""
SESSION_CWD_PHYS=""
if [ -n "$cwd_raw" ]; then
    # shellcheck disable=SC1003 # '\\' is tr's two-char escape for one backslash
    cwd_folded=$(printf '%s' "$cwd_raw" | tr '\\' '/')
    SESSION_CWD_POSIX="$(cd "$cwd_folded" 2>/dev/null && pwd)"
    SESSION_CWD_PHYS="$(cd -P "$cwd_folded" 2>/dev/null && pwd -P)" # swallow-ok: empty leaves relative args to the lexical check
    if [ -n "$SESSION_CWD_POSIX" ]; then
        if command -v cygpath >/dev/null 2>&1; then
            SESSION_CWD_MIXED=$(cygpath -m "$SESSION_CWD_POSIX" 2>/dev/null || printf '%s' "$SESSION_CWD_POSIX")
        else
            SESSION_CWD_MIXED="$SESSION_CWD_POSIX"
        fi
    fi
fi

# --- Global tripwires: never grant dynamic execution / substitution ---
# shellcheck disable=SC2016 # the single-quoted $( etc. are literal match patterns
case "$cmd" in
    *'$('*|*'`'*|*'<('*|*'>('*)        exit 0 ;;
esac

# Hot path: every Bash call of a cadence run reaches here, and only a command
# that names an enumerated engine or `gh` can be granted, so any other never
# pays for shfmt.
names_candidate=0
for entry in $ENGINE_LIST; do
    case "$cmd" in *"${entry##*/}"*) names_candidate=1; break ;; esac
done
case "$cmd" in *gh*) names_candidate=1 ;; esac
[ "$names_candidate" -eq 1 ] || exit 0

# The command model (shfmt) reads the command once; a station without shfmt only
# loses the grant, and the message says what to install.
ast_lib="$(dirname "${BASH_SOURCE[0]}")/../lib/bash-ast.sh"
# shellcheck source=../lib/bash-ast.sh
if ! { [ -r "$ast_lib" ] && . "$ast_lib"; } 2>/dev/null; then
    exit 0
fi
ast_rc=0
pos=$(bash_ast_positions "$cmd" 2>/dev/null) || ast_rc=$? # swallow-ok: the rc is read next
if [ "$ast_rc" -ne 0 ]; then
    if [ "$ast_rc" -eq 2 ]; then
        echo "cadence-approve-engines: shfmt not on PATH, so this command that names a cadence engine or gh api cannot be read and is not auto-approved; it falls through to the normal permission flow. Install shfmt (a station install goes to a test VM first)." >&2
    fi
    exit 0
fi
lines=$(printf '%s' "$pos" | jq -r "$_CAE_JQ" 2>/dev/null) || exit 0 # swallow-ok: a jq failure exits 0 with no grant
[ -n "$lines" ] && [ "$lines" != "REFUSE" ] || exit 0

# --- Every command must be an enumerated engine, a read-shaped gh api call or a
# benign cd/pushd, AND at least one must actually BE an engine or gh call.
# Without that, a nav-only command (e.g. a bare `cd /tmp`) satisfied the "every
# command is engine-or-nav" test vacuously and collected an allow with a false
# "vault-lint engine" reason, even though no engine was present. Harmless in
# effect (cd executes nothing), but contradicts this hook's contract of
# granting only enumerated cadence engines.
saw_engine=0
utf8_pos=0
cur_prog=""
CHAINS=()
WORDS=()
BASES=("")
while IFS= read -r line; do
    case "$line" in
        P*) cur_prog="${line#P}"; CHAINS=(); WORDS=() ;;
        U) utf8_pos=$((utf8_pos + 1)) ;;
        C*) CHAINS+=("${line#C}") ;;
        A*) WORDS+=("${line#A}") ;;
        E)
            set_bases || exit 0
            case "$cur_prog" in
                cd|pushd)
                    [ "${#WORDS[@]}" -eq 2 ] && nav_target_is_contained "${WORDS[1]}" || exit 0 ;;
                gh)
                    segment_is_gh_read "${WORDS[@]}" || exit 0
                    saw_engine=1 ;;
                *)
                    segment_is_engine "${WORDS[@]}" || exit 0
                    saw_engine=1 ;;
            esac ;;
        *) exit 0 ;;
    esac
done <<< "$lines"
[ "$saw_engine" -eq 1 ] || exit 0

# A prefix assignment is deliberately NOT part of a grant: `PYTHONPATH=/tmp
# python vault_lint.py` shadows a stdlib module the engine imports and reaches
# arbitrary code execution while collecting an automatic allow. The ONE
# exception is the EXACT literal `PYTHONUTF8=1` directly before `uv`, the
# documented invocation shape of the uv-capable engines (commands/
# ig-media-enrich.md, README.md): a text-encoding runtime knob that cannot
# shadow a module or redirect an import. The model reports an assignment's NAME
# only, so the value is held to the text: every `PYTHONUTF8=` in the command is
# one of the assignments the model found, and each reads `PYTHONUTF8=1 uv `.
utf8_all_text=${cmd//PYTHONUTF8=/}
utf8_ok_text=${cmd//PYTHONUTF8=1 uv /}
[ $(((${#cmd} - ${#utf8_all_text}) / 11)) -eq "$utf8_pos" ] || exit 0
[ $(((${#cmd} - ${#utf8_ok_text}) / 16)) -eq "$utf8_pos" ] || exit 0

emit_allow "enumerated cadence engine or read-only gh api call (HIMMEL-1386/2124)"
