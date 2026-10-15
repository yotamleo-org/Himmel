#!/usr/bin/env bash
# tracker-local.sh — file-backed backend for the tracker seam.
# Sourced by tracker.sh; not run directly.
#
# Store: $TRACKER_STORE, else <handover root>/<user>/<bucket>/tracker/ (never a
# hardcoded path). It holds `next-id` (one integer) and one <PREFIX>-<n>.md per
# item: YAML front matter (id, title, type, status, fix_version, epic, created,
# links) then a markdown body ending in a `## Log` section. Prefix: git config
# himmel.trackerPrefix, default LOCAL.
#
# Minting is atomic: a mkdir lock on <store>/.lock holding the owner pid in
# <store>/.lock/owner, so a lock whose pid is dead is reclaimed (I5) and one
# whose pid is alive blocks. The tracker=none backend mints through here too.

_TRACKER_LOCAL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# _tracker_local_store — print the store dir (not created). rc 2 when unresolved.
_tracker_local_store() {
    local root slug common bucket
    if [ -n "${TRACKER_STORE:-}" ]; then
        printf '%s\n' "$TRACKER_STORE"
        return 0
    fi
    # shellcheck source=scripts/lib/handover-path.sh
    # shellcheck disable=SC1091
    . "$_TRACKER_LOCAL_DIR/handover-path.sh"
    # shellcheck source=scripts/lib/user-slug.sh
    # shellcheck disable=SC1091
    . "$_TRACKER_LOCAL_DIR/user-slug.sh"
    if [ -z "${HANDOVER_DIR:-}" ] || [ -z "${USER_SLUG:-}" ]; then
        # shellcheck source=scripts/lib/load-dotenv.sh
        # shellcheck disable=SC1091
        . "$_TRACKER_LOCAL_DIR/load-dotenv.sh" 2>/dev/null &&
            load_dotenv --root "$(_load_dotenv_primary_for "$PWD" 2>/dev/null)" HANDOVER_DIR USER_SLUG >/dev/null 2>&1 || true
    fi
    root=$(handover_root) || { echo "tracker(local): no handover root (set TRACKER_STORE or HANDOVER_DIR)" >&2; return 2; }
    slug=$(user_slug 2>/dev/null) || { echo "tracker(local): cannot resolve the user slug (set USER_SLUG or TRACKER_STORE)" >&2; return 2; }
    common=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || { echo "tracker(local): not in a git repo (set TRACKER_STORE)" >&2; return 2; }
    bucket=$(basename "$(dirname "$common")" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//')
    printf '%s/%s/%s/tracker\n' "$root" "$slug" "$bucket"
}

# _tracker_local_prefix — validated id prefix.
_tracker_local_prefix() {
    local p
    p=$(git config --get himmel.trackerPrefix 2>/dev/null) || p=""
    [ -n "$p" ] || p=LOCAL
    case "$p" in
        [A-Z]*) ;;
        *) p="" ;;
    esac
    case "$p" in
        ''|*[!A-Z0-9]*)
            echo "tracker(local): invalid git config himmel.trackerPrefix (expected an uppercase letter, then A-Z/0-9)" >&2
            return 2
            ;;
    esac
    printf '%s\n' "$p"
}

_tracker_local_id_ok() {
    case "$1" in
        [A-Z]*-[0-9]*) ;;
        *) return 1 ;;
    esac
    case "$1" in *[!A-Z0-9-]*|*-*-*) return 1 ;; esac
    case "${1#*-}" in ''|*[!0-9]*) return 1 ;; esac
    return 0
}

_tracker_local_pid_alive() {
    kill -0 "$1" 2>/dev/null || ps -p "$1" >/dev/null 2>&1
}

# _tracker_local_lock <store> — acquire. rc 1 (message names the owner) when it
# stays held past TRACKER_LOCK_TRIES attempts.
# ponytail: a holder that dies between mkdir and writing `owner` leaves an
# owner-less lock this treats as held (blocks until the tries run out), and a
# reclaimer killed mid-reclaim leaks <store>/.lock.reclaim; upgrade path: the
# same pid-owner rule on the reclaim mutex if either is ever seen in the wild.
_tracker_local_lock() {
    local lock="$1/.lock" tries="${TRACKER_LOCK_TRIES:-200}" owner again
    while :; do
        if mkdir "$lock" 2>/dev/null; then
            # $BASHPID is the real process inside a $(...) mint; $$ (bash 3.2 has
            # no BASHPID) names the parent shell, which can outlive the minter
            printf '%s\n' "${BASHPID:-$$}" > "$lock/owner"
            return 0
        fi
        owner=$(cat "$lock/owner" 2>/dev/null)
        if [ -n "$owner" ] && ! _tracker_local_pid_alive "$owner"; then
            # reclaim under a second mutex so two reclaimers cannot remove a lock
            # the first one has just re-taken
            if mkdir "$1/.lock.reclaim" 2>/dev/null; then
                again=$(cat "$lock/owner" 2>/dev/null)
                [ "$again" != "$owner" ] || rm -rf "$lock"
                rmdir "$1/.lock.reclaim" 2>/dev/null
                continue
            fi
        fi
        tries=$((tries - 1))
        if [ "$tries" -le 0 ]; then
            echo "tracker(local): mint lock $lock is held by pid ${owner:-unknown}" >&2
            return 1
        fi
        sleep 0.05
    done
}

_tracker_local_unlock() { rm -rf "$1/.lock"; }

# _tracker_local_field <file> <key> — one front-matter value.
_tracker_local_field() {
    awk -v k="$2" '
        /^---$/ { n++; if (n == 2) exit; next }
        n == 1 && $0 ~ "^" k ":( |$)" {
            sub("^" k ": ?", "")
            v = $0
            if (v ~ /^".*"$/) {
                v = substr(v, 2, length(v) - 2)
                out = ""
                for (i = 1; i <= length(v); i++) {
                    c = substr(v, i, 1)
                    if (c == "\\" && i < length(v)) { i++; c = substr(v, i, 1) }
                    out = out c
                }
                v = out
            }
            print v
            exit
        }
    ' "$1"
}

# _tracker_local_id_new <type> <title> [body-file]
_tracker_local_id_new() {
    local type="$1" title store prefix n id file
    # double-quoted scalar (YAML-valid for ": " and " #"); readers unquote it
    title=$(printf '%s' "$2" | tr '\n\r\t' '   ' | tr -d '\000-\010\013\014\016-\037' | sed 's/\\/\\\\/g; s/"/\\"/g')
    case "$type" in
        ''|[!A-Za-z]*|*[!A-Za-z0-9\ _-]*)
            echo "tracker(local): invalid item type '$type'" >&2
            return 2
            ;;
    esac
    store=$(_tracker_local_store) || return 2
    prefix=$(_tracker_local_prefix) || return 2
    if [ -n "${3:-}" ] && [ ! -f "$3" ]; then
        echo "tracker(local): body file '$3' is not a file" >&2
        return 2
    fi
    mkdir -p "$store" || return 1
    _tracker_local_lock "$store" || return 1
    n=$(cat "$store/next-id" 2>/dev/null)
    case "$n" in ''|*[!0-9]*) n=1 ;; *) n=$((10#$n)) ;; esac
    # never reuse an id whose item exists (a lost or malformed next-id, or a crash
    # between the item write and the advance)
    while [ -e "$store/$prefix-$n.md" ]; do n=$((n + 1)); done
    id="$prefix-$n"
    file="$store/$id.md"
    # steps chained with && so a failed body read returns here (never exits the caller)
    if ! {
        printf -- '---\nid: %s\ntitle: "%s"\ntype: %s\nstatus: To Do\nfix_version:\nepic:\ncreated: %s\nlinks:\n---\n\n' \
            "$id" "$title" "$type" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$file" &&
            { [ -z "${3:-}" ] || { cat "$3" && printf '\n'; } >> "$file"; } &&
            printf '\n## Log\n' >> "$file"
    }; then
        rm -f "$file"
        _tracker_local_unlock "$store"
        return 1
    fi
    if ! { printf '%s\n' "$((n + 1))" > "$store/next-id.tmp" && mv "$store/next-id.tmp" "$store/next-id"; }; then
        # an id that was not advanced would be minted again over this item
        rm -f "$file" "$store/next-id.tmp"
        _tracker_local_unlock "$store"
        echo "tracker(local): cannot advance $store/next-id" >&2
        return 1
    fi
    _tracker_local_unlock "$store"
    printf '%s\n' "$id"
}

_tracker_local_id_pattern() { project_mode_id_pattern; }

# _tracker_local_item <id> — print the item file path; rc 2 bad id, rc 3 absent.
_tracker_local_item() {
    local store
    _tracker_local_id_ok "$1" || { echo "tracker(local): '$1' is not an item id" >&2; return 2; }
    store=$(_tracker_local_store) || return 2
    [ -f "$store/$1.md" ] || return 3
    printf '%s/%s.md\n' "$store" "$1"
}

_tracker_local_get() {
    local f
    f=$(_tracker_local_item "$1") || return $?
    node "$_TRACKER_LOCAL_DIR/tracker.mjs" local-get "$f"
}

_tracker_local_title() {
    local f
    f=$(_tracker_local_item "$1") || return $?
    _tracker_local_field "$f" title
}

# Item edits are read-modify-write on one file, so they take the same store lock
# as minting: two concurrent edits cannot share <file>.tmp or lose an append.
_tracker_local_transition() {
    local f cur back=0 store rc=0
    [ "${3:-}" = --allow-back ] && back=1
    f=$(_tracker_local_item "$1") || return $?
    store=$(dirname "$f")
    _tracker_local_lock "$store" || return 1
    cur=$(_tracker_local_field "$f" status)
    if _tracker_should_move "$cur" "$2" "$back"; then
        awk -v s="$2" '
            /^---$/ { n++ }
            n == 1 && !done && /^status:( |$)/ { print "status: " s; done = 1; next }
            { print }
        ' "$f" > "$f.tmp" && mv "$f.tmp" "$f" || rc=1
    fi
    _tracker_local_unlock "$store"
    return $rc
}

_tracker_local_comment() {
    local f store rc=0
    f=$(_tracker_local_item "$1") || return $?
    store=$(dirname "$f")
    _tracker_local_lock "$store" || return 1
    grep -q '^## Log$' "$f" || printf '\n## Log\n' >> "$f" || rc=1
    { printf '\n### %s\n\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"; cat "$2"; } >> "$f" || rc=1
    _tracker_local_unlock "$store"
    return $rc
}

_tracker_local_link() {
    local f store rc=0 link
    f=$(_tracker_local_item "$1") || return $?
    case "$2" in *$'\n'*|*$'\r'*) echo "tracker(local): a link target must be one line" >&2; return 2 ;; esac
    link=$(printf '%s' "$2" | tr '\t' ' ' | tr -d '\000-\010\013\014\016-\037' | sed 's/\\/\\\\/g; s/"/\\"/g')
    store=$(dirname "$f")
    _tracker_local_lock "$store" || return 1
    LINK="$link" awk '
        /^---$/ { n++; if (n == 2) print "  - \"" ENVIRON["LINK"] "\"" }
        { print }
    ' "$f" > "$f.tmp" && mv "$f.tmp" "$f" || rc=1
    _tracker_local_unlock "$store"
    return $rc
}

# _tracker_local_query [field=value ...] — every item whose front matter matches
# all filters, as <id> TAB <status> TAB <title>, in id order.
_tracker_local_query() {
    local store f a want got keep
    store=$(_tracker_local_store) || return 2
    [ -d "$store" ] || return 0
    for f in "$store"/*.md; do
        [ -f "$f" ] || continue
        _tracker_local_id_ok "$(basename "$f" .md)" || continue
        keep=1
        for a in "$@"; do
            want="${a#*=}"
            got=$(_tracker_local_field "$f" "${a%%=*}")
            [ "$got" = "$want" ] || { keep=0; break; }
        done
        [ "$keep" -eq 1 ] || continue
        printf '%s\t%s\t%s\n' "$(_tracker_local_field "$f" id)" "$(_tracker_local_field "$f" status)" "$(_tracker_local_field "$f" title)"
    done | sort -t'-' -k2,2n
}
