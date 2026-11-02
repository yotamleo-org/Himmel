#!/usr/bin/env bash
# live-state.sh — Renders a chief doc's `## Live state` `workers:`
# entries from its fleet manifest (<chief doc stem>.fleet.json,
# fleet-manifest.sh) instead of the chief hand-editing them on every dispatch
# and wrap.
#
#   live-state.sh <chief doc> [--print] [--nonce <label>=<nonce>]... [--pid <label>=<pid>]...
#   live-state.sh <chief doc> --digest
#
# --digest is read-only, needs no manifest, and prints status, head, workers,
# queue, lock and open ruling titles (at most 55 lines, never ruling bodies).
# status, head and lock print only when present: a chief doc carries none.
# Open rulings are ### headings or unchecked top-level checklist entries.
#
# An entry is `<label>:<nonce>:<lock-token>:<pid>` (chief-template.md). Where
# each field comes from:
#   label       the manifest's `workers[].label` (worker-identity.sh's N<k>)
#   lock-token  the worker's held queue lock (`queue-lock.sh status <doc>` owner.json
#               `session`): read from the lock on every render, never typed
#   nonce       AUTHORITY-BEARING and chief-only: kept from the entry already on
#               the workers: line, or given with --nonce for a worker not yet listed.
#               Never read from the worker doc or the manifest, which a worker or a
#               manifest edit could set
#   pid         informational: kept from the existing entry, else --pid, else the
#               `pid<digits>` suffix of the lock token
# A manifest worker that holds no lock is left out (tick reads a listed worker whose
# lock is gone as livestate=DRIFT); a worker off the manifest drops. A new worker
# with no nonce is refused and the doc is not touched.
#
# Only the workers: block (the `workers:` line plus the lines wrapped under it, ended
# as tick.sh ends it) inside `## Live state` is rewritten, to ONE `workers:` line:
# the entries, then whatever prose the old block carried. A doc still carrying the
# pre-rename `legs:` block (read only while legacy names are on) has that block
# REPLACED by the one `workers:` line, in place. Every other line is
# copied through. --print writes nothing and prints the new line.
# tick.sh is unchanged: livestate=DRIFT/MALFORMED and nonces= read the result as
# they read a hand-written line.
#
# a manifest row marked lockless (an eval/pilot row) is not a worker that
# lost its lock: it is listed on its own `lockless: <label> (<lane>) <doc>; ...` line
# right after the workers: line (replaced on every render), for succession to carry.
#
# Exit: 0 ok; 1 refused (no manifest, no workers: line, new worker without a nonce);
# 2 usage. PLATFORM GUARD: Linux-only kit, bash 3.2-safe; needs jq.
# shellcheck disable=SC2016  # backtick spans and awk programs are literal, not expansions
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
    echo "usage: live-state.sh <chief doc> [--digest | [--print] [--nonce <label>=<nonce>]... [--pid <label>=<pid>]...]" >&2
}

[ "$#" -ge 1 ] || { usage; exit 2; }
orig_args=("$@")
doc="$1"; shift
print_only=0; digest=0
nonces=""
pids=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        --print) print_only=1; shift ;;
        --digest) digest=1; shift ;;
        --nonce|--pid)
            [ "$#" -ge 2 ] || { usage; exit 2; }
            case "$2" in
                [A-Za-z0-9_.-]*=?*) ;;
                *) usage; exit 2 ;;
            esac
            case "$2" in *[[:space:]\`:\\]*) echo "live-state: $1 value must have no whitespace, backtick, colon or backslash: $2" >&2; exit 2 ;; esac
            if [ "$1" = --nonce ]; then nonces="$nonces$2"$'\n'; else pids="$pids$2"$'\n'; fi
            shift 2 ;;
        *) usage; exit 2 ;;
    esac
done

if [ "$digest" -eq 1 ] && { [ "$print_only" -ne 0 ] || [ -n "$nonces$pids" ]; }; then usage; exit 2; fi
[ -f "$doc" ] || { echo "live-state: no such chief doc: $doc" >&2; exit 1; }

# The manifest worker array is `workers`; a manifest not yet rewritten holds the pre-rename `legs`.
# The Live state line is `workers:`; the pre-rename `legs:` line is read only while legacy names
# are on, and `workers:` wins when a doc carries both. The block is read under the key the doc has
# and written back as `workers:`.
# shellcheck source=../../lib/legacy-names.sh
. "$HERE/../../lib/legacy-names.sh"
if legacy_names_on; then JQ_W='def W: (.workers // .legs);'; else JQ_W='def W: .workers;'; fi
pick_live_key() {
    if ! awk '$0 == "## Live state" { s = 1; next } s && /^## / { exit } s && /^workers:/ { f = 1 } END { exit !f }' "$doc" && legacy_names_on; then echo legs; else echo workers; fi
}
live_key="$(pick_live_key)"

# Rendering and digest share tick.sh's section and wrapped-workers boundaries.
block_awk='
    digest && !status && tolower($0) ~ /^(status:|\*\*status:\*\*)/ { status = $0 }
    digest && /^## / { rulings = (tolower($0) == "## open rulings") }
    digest && rulings && (/^### / || /^[-*+] \[ \] /) {
        title = $0
        sub(/^(###[[:space:]]+|[-*+][[:space:]]+)/, "", title)
        if (title !~ /^\[[xX]\]/) {
            sub(/^\[ \][[:space:]]*/, "", title)
            if (title != "" && tolower(title) != "none") {
                count++
                if (count <= 48) titles[count] = title
            }
        }
    }
    $0 == "## Live state" { s = 1; seen = 1; next }
    s && /^## / { s = 0 }
    digest && s && /^head:/ && !head { head = $0 }
    digest && s && /^queue:/ && !queue { queue = $0 }
    digest && s && /^lock:/ && !lock { lock = $0 }
    s && index($0, k ":") == 1 { f = 1; if (digest) workers = $0; else print; next }
    f && (/^[[:space:]]*$/ || /^[A-Za-z][A-Za-z ]*:/ || /^[[:space:]]*([-*+]|[0-9]+[.)])[[:space:]]/ || /^[[:space:]]*[>#]/) { f = 0 }
    f {
        if (digest) { line = $0; sub(/^[[:space:]]+/, "", line); workers = workers " " line }
        else print
    }
    END {
        if (digest) {
            if (!seen) exit 1
            if (status) print status
            if (head) print head
            print (workers ? workers : k ": unavailable")
            print (queue ? queue : "queue: unavailable")
            if (lock) print lock
            print "open rulings: " count + 0
            for (i = 1; i <= count && i <= 48; i++) print "- " titles[i]
            if (count > 48) print "additional ruling titles omitted: " count - 48
        }
    }'
if [ "$digest" -eq 1 ]; then
    awk -v digest=1 -v k="$live_key" "$block_awk" "$doc"
    exit $?
fi

manifest="${doc%.md}.fleet.json"
[ -f "$manifest" ] || { echo "live-state: no fleet manifest: $manifest" >&2; exit 1; }
rows="$(jq -r "$JQ_W"'W[] | [.label, .doc, ((.lane // "") | if . == "" then "unknown" else . end), ((.lockless == true) | tostring)] | @tsv' "$manifest" 2>/dev/null)" \
    || { echo "live-state: unreadable fleet manifest: $manifest" >&2; exit 1; }
old_block="$(awk -v k="$live_key" "$block_awk" "$doc")"
if [ -z "$old_block" ]; then
    # Another render may have replaced pre-rename legs: with workers: since the key was picked: start over before refusing.
    [ "$(pick_live_key)" = "$live_key" ] || exec bash "$HERE/live-state.sh" "${orig_args[@]}"
    echo "live-state: no workers: line under '## Live state' in $doc" >&2
    exit 1
fi

entry_re='`[A-Za-z0-9_.-]+:[^`:[:space:]]+:[^`:[:space:]]+:[^`:[:space:]]+`'
old_entries="$(printf '%s\n' "$old_block" | grep -oE "$entry_re" | tr -d '`')"

new_entries=""
missing=""
lockless_rows=""
while IFS=$'\t' read -r label ldoc llane llockless; do
    [ -n "$label" ] || continue
    # a lockless row (eval/pilot) holds no lock by design: it is carried
    # in its own `lockless:` line, never left out as a worker that lost its lock.
    if [ "$llockless" = true ]; then
        lockless_rows="$lockless_rows$label ($llane) $ldoc; "
        continue
    fi
    out="$(bash "$HERE/../queue-lock.sh" status "$ldoc" 2>/dev/null)"; rc=$?
    case "$rc" in
        11|12) ;;
        0) echo "live-state: $label holds no lock, left out" >&2; continue ;;
        *) echo "live-state: $label: lock status failed (rc=$rc), doc not rewritten" >&2; exit 1 ;;
    esac
    token="$(printf '%s\n' "$out" | head -1 | jq -r '.session // empty' 2>/dev/null)"
    [ -n "$token" ] || { echo "live-state: $label: unreadable lock owner, doc not rewritten" >&2; exit 1; }
    # The token is a field of a backtick span tick.sh splits on `:` and rejects on whitespace.
    case "$token" in
        *[:\`[:space:]]*) echo "live-state: $label: lock owner session has a span delimiter (colon, backtick or whitespace), doc not rewritten" >&2; exit 1 ;;
    esac
    old="$(printf '%s\n' "$old_entries" | awk -F: -v l="$label" '$1 == l { print; exit }')"
    nonce="$(printf '%s' "$old" | cut -d: -f2)"
    pid="$(printf '%s' "$old" | cut -d: -f4)"
    [ -n "$nonce" ] || nonce="$(printf '%s' "$nonces" | sed -n "s/^$label=//p" | head -1)"
    [ -z "$pid" ] && pid="$(printf '%s' "$pids" | sed -n "s/^$label=//p" | head -1)"
    [ -z "$pid" ] && pid="$(printf '%s' "$token" | sed -n 's/.*pid\([0-9][0-9]*\)$/\1/p')"
    if [ -z "$nonce" ] || [ -z "$pid" ]; then
        missing="$missing $label"
        continue
    fi
    new_entries="$new_entries\`$label:$nonce:$token:$pid\` "
done <<EOF
$rows
EOF
if [ -n "$missing" ]; then
    echo "live-state: new worker(s) need --nonce <label>=<nonce> (and --pid when the lock token has no pid suffix):$missing" >&2
    exit 1
fi

prose="$(printf '%s\n' "$old_block" | sed -E "s/^${live_key}:[[:space:]]*//; s/$entry_re//g" | tr '\n' ' ' | sed -E 's/[[:space:]]+/ /g; s/^ //; s/ $//; s/^none$//; s/^none //')"
if [ -n "$new_entries" ]; then new_line="workers: $new_entries$prose"; else new_line="workers: none${prose:+ $prose}"; fi
new_line="$(printf '%s' "$new_line" | sed -E 's/ +$//')"
# The lockless section follows the workers: line; a stale `lockless:` line is replaced.
[ -z "$lockless_rows" ] || new_line="$new_line"$'\n'"lockless: ${lockless_rows%; }"

if [ "$print_only" -eq 1 ]; then
    printf '%s\n' "$new_line"
    exit 0
fi

# rewrite under the lock every doc writer shares, so a chief
# bullet append-results.sh appends meanwhile waits for the mv instead of landing
# on the replaced doc. The awk below re-reads the whole doc under the lock. No
# flock (rc 3) or a lock that cannot be taken (rc 1) rewrites unlocked, as before.
# shellcheck source=scripts/handover/chief-kit/worker-doc-lock.sh
. "$HERE/worker-doc-lock.sh"
doc_lock "$doc" live-state || true
# Another render may have replaced the pre-rename legs: block with workers: while this one waited: start over on the new key.
if [ "$(pick_live_key)" != "$live_key" ]; then
    doc_unlock
    exec bash "$HERE/live-state.sh" "${orig_args[@]}"
fi
tmp="$(mktemp "$doc.XXXXXX")" || { echo "live-state: cannot create a temp file next to $doc" >&2; exit 1; }
chmod --reference="$doc" "$tmp" 2>/dev/null  # gnu-ok: Linux-only kit; the rewrite keeps the doc mode
if ! NL="$new_line" awk -v k="$live_key" '
    $0 == "## Live state" { s = 1; print; next }
    s && /^## / { s = 0 }
    s && index($0, k ":") == 1 { f = 1; print ENVIRON["NL"]; next }
    s && /^lockless:/ { f = 0; next }
    f && (/^[[:space:]]*$/ || /^[A-Za-z][A-Za-z ]*:/ || /^[[:space:]]*([-*+]|[0-9]+[.)])[[:space:]]/ || /^[[:space:]]*[>#]/) { f = 0 }
    f { next }
    # prim-ok: the temp takes the doc mode via chmod --reference; atomic_write would reset it to 0600
    { print }' "$doc" > "$tmp" || ! mv -f "$tmp" "$doc"; then
    rm -f "$tmp"
    echo "live-state: cannot write $doc" >&2
    exit 1
fi
