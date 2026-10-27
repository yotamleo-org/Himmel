#!/usr/bin/env bash
# worker-identity.sh — the ONE derivation of a worker's identity.
#
# A chief files a worker's brief as a handover doc and launches the worker under a
# session name (`claude -n <session>`). Every instrument that joins the two --
# tick.sh's workers=/procs=/models=/livestate=, and any later reader that maps a
# worker doc to a live session -- must derive the mapping HERE, never re-guess it
# with a local regex: a guess that silently matches nothing reads as a
# confident zero.
#
# Canonical (docs/handover/worker-brief-template.md):
#   doc     <TICKET>-N<k>-<slug>-<date>-RESUME.md      (the -RESUME and the
#   session <TICKET>-N<k>-<slug>                        -<date> are both optional)
#   label   N<k>   -- the token docs/handover/chief-template.md tells a chief
#                     to write in its `## Live state` legs: line.
# Also accepted, because live and archived docs carry it: the legacy family
#   <TICKET>[-<slug>]-leg[N]<k>-<date>-RESUME.md
# (the older template spelled it -leg<k>-, older chiefs -legN<k>-).
# It yields the same N<k> label, and the session name the chief derives
# for it: <TICKET>-N<k>[-<slug>]. Anything else falls back to the whole stem as
# its own label, which is self-consistent but joins to no session.
#
# A SUCCESSOR worker carries its letters: N38b is a different session
# from N38, so the label keeps them -- a label that dropped them would let
# tick.sh's livestate=/procs= conflate two live sessions. The base an instrument
# that counts relaunches of ONE worker groups by is worker_base, below.
# A legacy doc's ticket key is <KEY>-<digits>, or -- for the
# handful of drift/gh-named workers -- a bare UPPERCASE <KEY> alone, and then only
# with the N spelling (HIMMEL-drift-graphify-0955-legN5). Lowercase prose
# ("next-session-leg5") and an N-less fleet series (HIMMEL-linux-fleet-...-leg1,
# a different numbering that would collide with the real N1) stay fallbacks.
#
# Source this file; it defines functions and one constant, runs nothing.
# Bash 3.2-compatible (no arrays beyond BASH_REMATCH, no mapfile).

# Characters a label may contain. tick.sh builds its `legs:` span parser from the
# same class, so a label this file emits is always one the parser accepts.
WORKER_SESSION_LABEL_CLASS='A-Za-z0-9_.-'

# worker_identity <worker doc path or stem>
# Prints ONE line: <label><TAB><name>[,<name>...]
# <name>s are every session name the worker may be running under (stem without
# -RESUME, the same without its trailing date, and the derived session for a
# legacy-family doc); a census row matching any of them belongs to this worker.
worker_identity() {
    local stem="$1" session undated sfx derived="" label=""
    local re_canon='^[A-Za-z][A-Za-z]*-[0-9]+-(N[0-9]+[a-z]*)(-.*)?$'
    local re_legacy='^([A-Za-z][A-Za-z]*-[0-9]+)(-(.*))?-leg(N?)([0-9]+)([a-z]*)(-.*)?$'
    local re_legacy_key='^([A-Z][A-Z]*)(-(.*))?-leg(N)([0-9]+)([a-z]*)(-.*)?$'
    stem="${stem##*/}"
    stem="${stem%.md}"
    session="${stem%-RESUME}"
    undated="$(printf '%s' "$session" | sed -E 's/-[0-9]{4}-[0-9]{2}-[0-9]{2}$//')"
    if [[ $stem =~ $re_canon ]]; then
        label="${BASH_REMATCH[1]}"
    elif [[ $stem =~ $re_legacy ]] || [[ $stem =~ $re_legacy_key ]]; then
        label="N${BASH_REMATCH[5]}${BASH_REMATCH[6]}"
        # A slug AFTER the worker token (-legN3-worker-<date>) belongs in the session
        # too; the trailing -RESUME and -<date> do not.
        sfx="${BASH_REMATCH[7]%-RESUME}"
        sfx="$(printf '%s' "$sfx" | sed -E 's/-[0-9]{4}-[0-9]{2}-[0-9]{2}$//')"
        derived="${BASH_REMATCH[1]}-${label}${BASH_REMATCH[3]:+-${BASH_REMATCH[3]}}${sfx}"
    else
        label="$stem"
    fi
    label="$(printf '%s' "$label" | tr -c "$WORKER_SESSION_LABEL_CLASS" '_')"
    local names="$session"
    [ "$undated" = "$session" ] || names="$names,$undated"
    [ -z "$derived" ] || names="$names,$derived"
    printf '%s\t%s\n' "$label" "$names"
}

# worker_label <worker doc path or stem> -- just the label, for callers that need no names.
worker_label() {
    local ident
    ident="$(worker_identity "$1")"
    printf '%s' "${ident%%$'\t'*}"
}

# worker_base <worker doc path or stem> -- the worker a successor continues: the label with
# a trailing successor suffix dropped (N38b -> N38). A label with no suffix, and the
# whole-stem fallback of a non-worker doc, come back unchanged. This is the metric's
# grouping key, never an identity: two live sessions N38 and N38b share a base and
# must not share a label.
worker_base() {
    local label
    label="$(worker_label "$1")"
    if [[ $label =~ ^(N[0-9]+)[a-z]+$ ]]; then
        printf '%s' "${BASH_REMATCH[1]}"
    else
        printf '%s' "$label"
    fi
}

# A worker's human description -- one plain-language line saying what
# the worker is doing and why, shown NEXT TO the label (never instead: tooling keys
# on the label). It lives in the worker doc's front matter as `description: <text>`
# (docs/handover/worker-brief-template.md). Every reader goes through these
# functions; none parses a doc for it itself.

# worker_description_field <worker doc path> -- the front-matter `description:` value,
# trimmed, one pair of surrounding quotes dropped. Prints nothing when the doc
# is unreadable, has no front matter or no such key, or the value is empty or
# still the template's `<placeholder>`. Only the leading `---` block counts.
worker_description_field() {
    local doc="$1" val
    [ -r "$doc" ] || return 0
    val="$(awk '
        { sub(/\r$/, "") }
        NR == 1 { if ($0 != "---") exit; next }
        $0 == "---" { exit }
        /^description:/ { sub(/^description:/, ""); print; exit }
    ' < "$doc" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"
    case "$val" in
        \"*\") val="${val#\"}"; val="${val%\"}" ;;
        \'*\') val="${val#\'}"; val="${val%\'}" ;;
    esac
    val="$(printf '%s' "$val" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"
    case "$val" in
        "<"*">") val="" ;;
    esac
    printf '%s' "$val"
}

# worker_description <worker doc path> -- the line a surface prints next to the label.
# Fallback, never empty: the description field; then the ticket's title (the tracker
# seam, keyed by the doc stem's ticket); then the title of the PR the doc's Results
# name (the forge seam, stripped by board-user.mjs's goalOf, the one copy); then the
# brief's H1 scope
# (`# <TICKET> — <scope> — worker N<k> (...)`, and the `# <TICKET>: <scope>. Worker
# N<k> (...)` chiefs also write, give <scope>; an H1 not led by a ticket key
# is used whole);
# then the doc stem. A seam that fails or answers nothing is skipped, never fatal.
_WI_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
worker_description() {
    local doc="$1" val stem key pr json
    val="$(worker_description_field "$doc")"
    if [ -z "$val" ]; then
        stem="${doc##*/}"
        key="$(printf '%s' "$stem" | sed -nE 's/^([A-Za-z][A-Za-z0-9]*-[0-9]+).*/\1/p')"
        if [ -n "$key" ]; then
            command -v tracker_title >/dev/null 2>&1 || . "$_WI_LIB_DIR/tracker.sh" 2>/dev/null
            val="$(tracker_title "$key" 2>/dev/null | head -n 1)" || val=""
        fi
    fi
    if [ -z "$val" ] && [ -r "$doc" ]; then
        # read-sink-ok: $doc is the handover doc the caller asks about, read-only
        pr="$(awk '/^## Results/ { inr = 1; next } inr && /^## / { inr = 0 } inr' < "$doc" \
            | grep -E '^- ([0-9]{1,2}:[0-9]{2} +)?(LIVE *(-|–|—|:)? *PR *#?[0-9]{2,} +open|READY +#?[0-9]{2,} +[0-9a-f]{7,}|MERGED +#[0-9]{2,})' \
            | tail -n 1 | sed -E 's/^- ([0-9]{1,2}:[0-9]{2} +)?//' | grep -oE '[0-9]{2,}' | head -n 1)" || pr=""
        if [ -n "$pr" ]; then
            command -v forge_change_view >/dev/null 2>&1 || . "$_WI_LIB_DIR/forge.sh" 2>/dev/null
            json="$(forge_change_view "$pr" 2>/dev/null)" || json=""
            # shellcheck disable=SC2016  # the node program is single-quoted on purpose
            [ -z "$json" ] || val="$(printf '%s' "$json" | node --input-type=module -e '
                const { goalOf } = await import(`file://${process.argv[1]}`);
                let s = ""; process.stdin.on("data", (d) => { s += d; }).on("end", () => {
                    try { process.stdout.write(goalOf(JSON.parse(s).title)); } catch { /* no title */ }
                });' "$_WI_LIB_DIR/../handover/chief-kit/board-user.mjs" 2>/dev/null)"
        fi
    fi
    if [ -z "$val" ] && [ -r "$doc" ]; then
        val="$(sed -n -E '/^# /{s/^# +//;p;q;}' "$doc" \
            | sed -E 's/[[:space:]]+$//; /^[A-Za-z][A-Za-z0-9]*-[0-9]+[ :]/{s/^[A-Za-z][A-Za-z0-9]*-[0-9]+( \+ [A-Za-z][A-Za-z0-9]*-[0-9]+)*( \([^)]*\))?( —| -|:) //; s/( —| -|\.)? ([Ll]eg|[Ww]orker) N[0-9]+[a-z]*( \([^)]*\))?(,? [0-9]{4}-[0-9]{2}-[0-9]{2})?$//; s/( —|\.|,| -) ([Ll]eg|[Ww]orker) N[0-9]+[a-z]*( .*)?$//;}; s/[[:space:]]+$//')"
    fi
    if [ -z "$val" ]; then
        stem="${doc##*/}"
        val="${stem%.md}"
    fi
    printf '%s' "$val"
}

# worker_doc_has_run <worker doc path> -- exit 0 when the doc's `## Results` section
# already holds a `- ` bullet: the worker has been launched and has reported, so a
# relaunch is a resume. A fresh brief's Results section is empty. A launch gate
# that is new for fresh briefs uses this so a doc written before the gate
# existed still resumes.
worker_doc_has_run() {
    [ -r "$1" ] || return 1
    awk '
        /^## Results/ { inr = 1; next }
        inr && /^## / { inr = 0 }
        inr && /^- / { found = 1; exit }
        END { exit found ? 0 : 1 }
    ' < "$1"  # read-sink-ok: $1 is the handover doc the caller asks about
}
