#!/usr/bin/env bash
# critics-config.sh — the ONE resolver for "which reviewers gate this repo, and
# how hard?". critic-panel.sh (who runs) and cr-merge-gate.sh (who must pass)
# both read the effective reviewer set from here, so they cannot disagree.
#
# critics_config_resolve [<cr-dir>]
#   <cr-dir> holds critics.json and may hold a checkout-local overlay
#   (default: <this dir>/../cr); critic-panel.sh passes its own directory.
#   stdout: the effective config as one JSON line:
#             {"review":"no_code_review"|null,"panel":[row,...],
#              "files":{"base":<path>,"local":<path>|null}}
#           every row carries `mode` (hard | best-effort) and `required`
#           (boolean), defaults filled in.
#   rc 0 = resolved; rc 2 = config error, `<file>: <why>` on stderr;
#   rc 3 = cannot evaluate (node missing), reason on stderr.
#
# Inputs, in order:
#   CRITICS_JSON          wins outright: read as the whole config, no overlay.
#   CRITICS_BASE_JSON     the base (default: <cr-dir>/critics.json).
#   the overlay (critics.local.json, gitignored), first that applies:
#     CRITICS_LOCAL_JSON  when set (a missing file then means no overlay);
#     ${HIMMELCTL_CACHE_DIR:-$HOME/.claude/himmel}/critics.local.json;
#     <cr-dir>/critics.local.json when it exists;
#     the PRIMARY checkout's scripts/cr/critics.local.json, found through
#     `git rev-parse --git-common-dir` from this file's own directory — never
#     a linked worktree's own path, where the gitignored overlay never exists.
#
# Merge is field-wise per slug: a local row's fields override the base row's
# (`{"slug":"coderabbit","mode":"hard"}` keeps provider github-app), a local
# row with "drop":true removes the slug, a local-only slug is appended. A local
# top-level "review" replaces the base's. CR_PROFILE=none resolves to
# review "no_code_review": the explicit opt-out.
#
# Defaults: mode = best-effort for a provider "github-app" row, else hard;
# required = false. Config errors (rc 2): a file that does not parse, a mode
# other than hard / best-effort, a non-boolean required, a review value other
# than "no_code_review". Each names the file that set the bad value.
#
# Sourceable: functions only, `return` never `exit`. bash 3.2-safe.

_ccfg_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# _ccfg_local_path <cr-dir> — the overlay path, per the order above.
_ccfg_local_path() {
    if [ -n "${CRITICS_LOCAL_JSON+x}" ] && [ -n "$CRITICS_LOCAL_JSON" ]; then
        printf '%s\n' "$CRITICS_LOCAL_JSON"; return 0
    fi
    local cache="${HIMMELCTL_CACHE_DIR:-$HOME/.claude/himmel}/critics.local.json"
    if [ -f "$cache" ]; then printf '%s\n' "$cache"; return 0; fi
    if [ -f "$1/critics.local.json" ]; then printf '%s\n' "$1/critics.local.json"; return 0; fi
    local common
    common=$(git -C "$_ccfg_dir" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || common=""
    case "$common" in
        */.git) printf '%s\n' "${common%/.git}/scripts/cr/critics.local.json" ;;
        *)      printf '%s\n' "$1/critics.local.json" ;;
    esac
}

critics_config_resolve() {
    command -v node >/dev/null 2>&1 || { echo "node not on PATH" >&2; return 3; }
    local crdir="${1:-$_ccfg_dir/../cr}" base local_path
    if [ -n "${CRITICS_JSON:-}" ]; then
        base="$CRITICS_JSON"; local_path=""
    else
        base="${CRITICS_BASE_JSON:-$crdir/critics.json}"
        local_path=$(_ccfg_local_path "$crdir")
        [ -f "$local_path" ] || local_path=""
    fi
    CCFG_BASE="$base" CCFG_LOCAL="$local_path" CCFG_PROFILE="${CR_PROFILE:-}" node -e '
const fs = require("fs"), e = process.env;
const fail = (file, why) => { process.stderr.write(file + ": " + why + "\n"); process.exit(2); };
const read = (p) => {
    let txt;
    try { txt = fs.readFileSync(p, "utf8"); } catch (_) { fail(p, "cannot be read"); }
    try { return JSON.parse(txt); } catch (_) { fail(p, "does not parse"); }
};
const base = read(e.CCFG_BASE);
const local = e.CCFG_LOCAL ? read(e.CCFG_LOCAL) : null;
const rows = (j, p) => {
    if (j === null || typeof j !== "object" || Array.isArray(j)) fail(p, "is not a JSON object");
    if (j.panel === undefined) return [];
    if (!Array.isArray(j.panel)) fail(p, "panel is not an array");
    return j.panel;
};
const bp = rows(base, e.CCFG_BASE), lp = local ? rows(local, e.CCFG_LOCAL) : [];
const setBy = new Map();   // slug -> field -> file that set it
const note = (slug, r, file) => {
    const m = setBy.get(slug) || {};
    for (const k of Object.keys(r)) m[k] = file;
    setBy.set(slug, m);
};
const out = [], idx = new Map();
for (const r of bp) {
    if (!r || typeof r !== "object" || typeof r.slug !== "string") continue;
    idx.set(r.slug, out.length); out.push(Object.assign({}, r)); note(r.slug, r, e.CCFG_BASE);
}
for (const r of lp) {
    if (!r || typeof r !== "object" || typeof r.slug !== "string") continue;
    if (r.drop === true) {
        if (idx.has(r.slug)) { out[idx.get(r.slug)] = null; idx.delete(r.slug); }
        continue;
    }
    if (idx.has(r.slug)) Object.assign(out[idx.get(r.slug)], r);
    else { idx.set(r.slug, out.length); out.push(Object.assign({}, r)); }
    note(r.slug, r, e.CCFG_LOCAL);
}
const panel = out.filter(Boolean).map((r) => {
    const from = (k) => (setBy.get(r.slug) || {})[k] || e.CCFG_BASE;
    if (r.mode === undefined) r.mode = r.provider === "github-app" ? "best-effort" : "hard";
    else if (r.mode !== "hard" && r.mode !== "best-effort")
        fail(from("mode"), "row " + r.slug + " has mode " + JSON.stringify(r.mode) + " (want hard or best-effort)");
    if (r.required === undefined) r.required = false;
    else if (typeof r.required !== "boolean")
        fail(from("required"), "row " + r.slug + " has required " + JSON.stringify(r.required) + " (want true or false)");
    return r;
});
let review = null, reviewFile = e.CCFG_BASE;
if (local && Object.prototype.hasOwnProperty.call(local, "review")) { review = local.review; reviewFile = e.CCFG_LOCAL; }
else if (Object.prototype.hasOwnProperty.call(base, "review")) review = base.review;
if (review !== null && review !== "no_code_review")
    fail(reviewFile, "review is " + JSON.stringify(review) + " (the only value is \"no_code_review\")");
if (e.CCFG_PROFILE === "none") review = "no_code_review";
process.stdout.write(JSON.stringify({ review, panel,
    files: { base: e.CCFG_BASE, local: e.CCFG_LOCAL || null } }) + "\n");
'
}
