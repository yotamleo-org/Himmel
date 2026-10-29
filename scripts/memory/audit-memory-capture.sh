#!/usr/bin/env bash
# Decoupled audit of the auto-memory capture discipline.
#
# Runs OFF the compound cadence on purpose: compound now runs weeks-to-months
# apart, so a detector riding it would grow its own latency in proportion to
# the design working (D1). This script is the standalone detector for the
# design's worst failure mode — silent fact loss — plus the index hygiene the
# capture hook (scripts/hooks/guard-memory-capture.sh) enforces structurally.
#
# Reads the capture log the hook appends to MEMORY_CAPTURE_LOG (default
# $MEMDIR/.capture-log.jsonl): one JSON object per line, fields
# {ts,event,rule,hash,excerpt,target,lines_delta,lane}. 'deny' = a capture the
# hook rejected; 'write' = an allowed MEMORY.md pointer-line delta.
#
# Usage: audit-memory-capture.sh                      plain audit (checks 1-5)
#        audit-memory-capture.sh --structure          structure checks 2,4,6,7,8 (+9 WARN)
#        audit-memory-capture.sh --lost-lines <dir>   print every line in snapshot <dir> now gone
#
# Checks (Rev2-amended — base was PRE-Rev2, do NOT ship the plan's base as-is):
#   1. ORPHANED DENIES (P2-13/P2-14) — a fact the model was denied and never
#      re-landed in the substrate. Windowed to a trailing epoch window so a
#      reworded/re-landed fact stops ringing once its deny ages out. If denies
#      exist but the substrate is genuinely unresolvable, emits a WARN rather
#      than silently reporting 'clean'.
#   2. UNREACHABLE TOPIC FILES (Rev2 INVERTS the old '>2 topic files = drift'
#      check — topic files ARE the design now, accumulation is expected) — a
#      topic file not reachable from MEMORY.md by following ](x.md) and [[x]]
#      links through any store file (a hub's sub-files are reachable).
#   3. LINE-COUNT TRIPWIRE — net MEMORY.md pointer-line growth over the
#      trailing window.
#   4. INDEX BUDGET + over-length-line discipline (length in CHARACTERS via
#      scripts/hooks/memory-line-check.sh).
#   5. COLLECTION FRESHNESS (best-effort, Rev2 D8) — if the qmd CLI is on
#      PATH, warn when the luna collection is absent; skip cleanly
#      otherwise (never hard-fails on qmd absence).
#   6. TOPIC CAP — a top-level *.md other than MEMORY.md over MEMORY_TOPIC_MAX
#      (8192) bytes.
#   7. DEAD LINK — a ](x.md) whose target is not in the store; a [[x]] with no
#      x.md in the store and no vault note x. The wikilink half needs the vault:
#      --structure exits 2 when it does not resolve, the plain audit WARNs.
#   8. LOAD LIMIT — MEMORY.md over MEMORY_LOAD_LINES (200) lines, over
#      MEMORY_BUDGET_BYTES, or over MEMORY_LINE_CEIL (60) pointer lines.
#   9. STALE (WARN, never changes the exit code) — modified under metadata:
#      older than 30 days, or none ("unknown").
#
# Counting rules (links, code stripping, reachability) are pinned to the
# memory epic's P0 baseline link script; sizes are bytes, so invalid UTF-8 is
# sized and scanned (LC_ALL=C).
#
# Exit: 0 clean, 1 findings, 2 cannot run (missing memory dir, --structure
# without a resolvable vault). bash 3.2-safe; no `date -d` (Git-Bash-unreliable).
set -uo pipefail
export LC_ALL=C

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
usage() { printf '%s\n' 'usage: audit-memory-capture.sh [--structure | --lost-lines <snapshot-dir>]' >&2; exit "${1:-2}"; }

MODE=plain; SNAP=""
while [ $# -gt 0 ]; do
    case "$1" in
        --structure) MODE=structure; shift ;;
        --lost-lines) [ $# -ge 2 ] || usage 2; MODE=lost; SNAP="$2"; shift 2 ;;
        -h|--help) usage 0 ;;
        *) usage 2 ;;
    esac
done

# shellcheck source=../lib/memory-slug.sh
# shellcheck source=../lib/prim.sh
. "$HERE/../lib/prim.sh" || exit 2
. "$HERE/../lib/memory-slug.sh"
if [ -z "${MEMDIR:-}" ]; then
    MEMDIR="$(memory_resolve_memdir)" || exit 1
fi
if [ ! -d "$MEMDIR" ]; then
    printf 'memory-capture audit: memory dir not found: %s\n' "$MEMDIR" >&2
    exit 2
fi
LOG="${MEMORY_CAPTURE_LOG:-$MEMDIR/.capture-log.jsonl}"
LINE_MAX="${MEMORY_LINE_MAX:-200}"
LINE_CEIL="${MEMORY_LINE_CEIL:-60}"
TOPIC_MAX="${MEMORY_TOPIC_MAX:-8192}"
LOAD_LINES="${MEMORY_LOAD_LINES:-200}"
BUDGET="${MEMORY_BUDGET_BYTES:-24400}"
WINDOW_DAYS="${MEMORY_AUDIT_WINDOW_DAYS:-7}"
QMD_SKIP="${MEMORY_AUDIT_SKIP_QMD:-0}"
findings=0
cannot=0

# Fail fast on a non-numeric override before it reaches the arithmetic below
# (a garbage WINDOW_DAYS would break the epoch cutoff; a garbage LINE_MAX/BUDGET
# the [ -gt ] comparisons). These are operator-set env knobs — reject, don't guess.
is_uint() { case "$1" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac; }
for _v in "$LINE_MAX" "$LINE_CEIL" "$TOPIC_MAX" "$LOAD_LINES" "$BUDGET" "$WINDOW_DAYS"; do
    is_uint "$_v" || {
        printf '%s\n' 'memory-capture audit: LINE_MAX / LINE_CEIL / TOPIC_MAX / LOAD_LINES / BUDGET / WINDOW_DAYS must be non-negative integers' >&2
        exit 1
    }
done

note() { printf '%s\n' "$1"; findings=$((findings+1)); }
warn() { printf '%s\n' "$1"; }

# Top-level regular files of a memory dir, one name per line, minus the capture
# log and the snapshot manifest (never part of the store's content).
store_files() { ( cd "$1" && find . -maxdepth 1 -type f | sed 's|^\./||' | grep -vxF -e .capture-log.jsonl -e .snapshot-manifest ); }

# ---- --lost-lines: every non-blank, non-frontmatter line of the snapshot that
# no current file still holds (multiset: a line held twice with one copy gone
# prints once; a line that only moved to another file prints nothing). ----
if [ "$MODE" = lost ]; then
    [ -d "$SNAP" ] || { printf 'memory-capture audit: snapshot dir not found: %s\n' "$SNAP" >&2; exit 2; }
    TMP="$(tmpdir)" || exit 2
    trap 'rm -rf "$TMP"' EXIT
    body_lines() {
        local d="$1" n
        store_files "$d" | while IFS= read -r n; do
            awk 'FNR==1 { fm = ($0 == "---") ? 1 : 0; if (fm) next }
                 fm == 1 { if ($0 == "---") fm = 2; next }
                 $0 !~ /^[[:space:]]*$/ { print }' "$d/$n"
        done
    }
    body_lines "$SNAP" | sort > "$TMP/snap"
    body_lines "$MEMDIR" | sort > "$TMP/cur"
    comm -23 "$TMP/snap" "$TMP/cur" > "$TMP/lost"
    n_lost="$(awk 'END{print NR+0}' "$TMP/lost")"
    cat "$TMP/lost"
    printf 'memory-capture audit: %s lost line(s)\n' "$n_lost" >&2
    [ "$n_lost" -eq 0 ] && exit 0
    exit 1
fi

if [ "$MODE" = plain ]; then
    # Fail CLOSED when jq is unavailable: the orphaned-deny (check 1) and tripwire
    # (check 3) detectors parse the JSONL log with jq. Without jq those `jq … 2>/dev/null`
    # calls yield empty, and the audit would report "clean" having never run its two
    # most important silent-fact-loss detectors — the exact false-clean this script exists
    # to prevent. Refuse rather than pass blind.
    command -v jq >/dev/null 2>&1 || {
        printf '%s\n' 'memory-capture audit: jq not found — the orphaned-deny and tripwire detectors cannot run; refusing to report clean (fail-closed)' >&2
        exit 1
    }
else
    printf 'store: %s\n' "$MEMDIR"
fi

# Fixed once: the trailing-window cutoff. Epoch math without `date -d`.
now_s="$(date -u +%s)"
cutoff=$((now_s - WINDOW_DAYS * 24 * 3600))

# Resolve the substrate to grep for re-landed facts. Mirrors graphmap-cadence /
# pipeline-cadence default_vault: LUNA_VAULT_PATH first, else <home>/Documents/luna.
# Empty when genuinely unresolvable — drives the P2-13 WARN path (never silent).
SUB=""
if [ -n "${LUNA_VAULT_PATH:-}" ]; then
    SUB="$LUNA_VAULT_PATH"
else
    _h="${HOME:-}"; [ -n "$_h" ] || _h="${USERPROFILE:-}"
    [ -n "$_h" ] && SUB="$_h/Documents/luna"
fi
substrate_ok=0
{ [ -n "$SUB" ] && [ -d "$SUB" ]; } && substrate_ok=1

TMP="$(tmpdir)" || exit 2
trap 'rm -rf "$TMP"' EXIT

# 1. Orphaned denies — the ONLY detector for silent fact loss: a capture the
#    hook denied and the model never re-landed.
if [ "$MODE" = plain ] && [ -f "$LOG" ]; then
    n_inwin=0
    while IFS= read -r rec; do
        [ -n "$rec" ] || continue
        # P2-14: window to the trailing N days. jq fromdateiso8601 parses the
        # hook's `date -u +%Y-%m-%dT%H:%M:%SZ`; `try` drops a malformed ts
        # (null >= number is false in jq, so bad rows are skipped, not rung).
        ex="$(printf '%s' "$rec" | jq -r --argjson c "$cutoff" '
            select(.event=="deny")
            | (.ts | try fromdateiso8601) as $t
            | select($t >= $c)
            | .excerpt // empty' 2>/dev/null)"
        [ -n "$ex" ] || continue
        n_inwin=$((n_inwin+1))
        [ "$substrate_ok" -eq 1 ] || continue
        # -F: excerpts carry regex metachars (em-dashes, ../..).
        #
        # KNOWN MATCHING LIMIT (P2-14): the hook stores the excerpt of the
        # DENIED capture (the attempted memory line); rewording on re-landing
        # changes the wording, so a substring match CAN MISS a genuinely
        # re-landed fact. The time window above bounds how long such a miss
        # rings — it does not eliminate it.
        #
        # Why `hash` is written by the hook but never read here: it is the
        # sha256 of the denied CONTENT. There is no re-landed body to hash-match
        # against, and a reword changes any would-be hash too — so hash cannot
        # confirm resolution. Resolution is detected by substance (substring),
        # which is inherently fuzzy; the window — not the hash — is the
        # resolution-aging mechanism.
        if ! grep -rqF -- "$ex" "$SUB" 2>/dev/null; then
            note "ORPHANED DENY (in-window): $ex"
        fi
    done < "$LOG"
    # P2-13: denies exist but the substrate is genuinely unresolvable -> WARN,
    # never a silent 'clean'. The check must NOT disable itself when
    # LUNA_VAULT_PATH is unset; it surfaces that re-landing could not be verified.
    if [ "$substrate_ok" -eq 0 ] && [ "$n_inwin" -gt 0 ]; then
        note "WARN: $n_inwin in-window deny(ies) but substrate unresolvable (LUNA_VAULT_PATH unset and no <home>/Documents/luna) — cannot verify re-landing"
    fi
fi

# Link scan (checks 2, 7, 9): one awk pass over every top-level *.md. The
# counting rules are the P0 baseline link script's: fenced blocks and inline
# `code` spans are stripped first; a markdown link is [text](target) with the
# target cut at '#' and whitespace; url/anchor/path-bearing targets are not
# store links; a wikilink drops |alias and #heading; reachability is a walk
# from MEMORY.md over every store file's links.
cat > "$TMP/scan.awk" <<'AWK'
function strip_inline(t,   res, p, k, run, mk, i, rest, q, matched) {
    res = ""
    while ((p = index(t, "`")) > 0) {
        res = res substr(t, 1, p - 1)
        t = substr(t, p)
        run = 0
        while (substr(t, run + 1, 1) == "`") run++
        matched = 0
        for (k = run; k >= 1 && !matched; k--) {
            mk = ""
            for (i = 1; i <= k; i++) mk = mk "`"
            if (substr(t, k + 1, k) == mk) continue
            rest = substr(t, k + 2)
            q = index(rest, mk)
            if (q > 0) { t = substr(t, k + 1 + q + k); matched = 1 }
        }
        if (!matched) { res = res "`"; t = substr(t, 2) }
    }
    return res t
}
function finish(   i, j, mk, found, text, src, rest, m, t, s0, l0, q, last, off, tmp, name, tgt, inmeta, fm, v) {
    src = cur
    if (src != "MEMORY.md" && src ~ /\.md$/) {
        v = ""; fm = 0; inmeta = 0
        if (line[1] == "---") {
            for (i = 2; i <= n && line[i] != "---"; i++) {
                if (line[i] ~ /^metadata:[[:space:]]*$/) { inmeta = 1; continue }
                if (inmeta && line[i] ~ /^[[:space:]]+modified:/) {
                    v = line[i]; sub(/^[[:space:]]+modified:[[:space:]]*/, "", v); gsub(/[[:space:]]+$/, "", v)
                    break
                }
                if (inmeta && line[i] !~ /^[[:space:]]/ && line[i] != "") inmeta = 0
            }
        }
        mod[src] = v
    }
    text = ""; i = 1
    while (i <= n) {
        mk = substr(line[i], 1, 3)
        if (mk == "```" || mk == "~~~") {
            found = 0
            for (j = i + 1; j <= n; j++) if (substr(line[j], 1, 3) == mk) { found = 1; break }
            if (found) { text = text "\n"; i = j + 1; continue }
        }
        text = text line[i] "\n"; i++
    }
    text = strip_inline(text)
    rest = text
    while (match(rest, /\[([^][]|\[[^][]*\])*\]\([^)[:space:]]*([[:space:]]+"[^"]*")?\)/)) {
        s0 = RSTART; l0 = RLENGTH
        m = substr(rest, s0, l0)
        if (s0 > 1 && substr(rest, s0 - 1, 1) == "!") { rest = substr(rest, s0 + 1); continue }
        rest = substr(rest, s0 + l0)
        last = 0; off = 0; tmp = m
        while ((q = index(tmp, "](")) > 0) { last = off + q; off += q; tmp = substr(tmp, q + 1) }
        t = substr(m, last + 2); sub(/\)$/, "", t)
        if (match(t, /[[:space:]]/)) t = substr(t, 1, RSTART - 1)
        sub(/#.*/, "", t)
        if (t ~ /^[A-Za-z][A-Za-z0-9+.-]*:/ || t == "" || index(t, "/") > 0) continue
        nmd++
        if (!(t in exist)) print "DEADLINK\t" src "\t" t
        else adj[src] = adj[src] t "\n"
    }
    rest = text
    while (match(rest, /\[\[[^][]+\]\]/)) {
        name = substr(rest, RSTART + 2, RLENGTH - 4); rest = substr(rest, RSTART + RLENGTH)
        sub(/\|.*/, "", name); sub(/#.*/, "", name); gsub(/^[[:space:]]+|[[:space:]]+$/, "", name)
        nwiki++
        if ((name ".md") in exist) tgt = name ".md"
        else if (name in exist) tgt = name
        else tgt = ""
        if (tgt == "") print "DEADWIKI\t" src "\t" name
        else adj[src] = adj[src] tgt "\n"
    }
}
FILENAME == LIST { exist[$0] = 1; ord[++nl] = $0; next }
{
    fn = FILENAME; sub(/^\.\//, "", fn)
    if (fn != cur) { if (cur != "") finish(); cur = fn; n = 0; split("", line) }
    line[++n] = $0
}
END {
    if (cur != "") finish()
    stack[1] = "MEMORY.md"; sp = 1; seen["MEMORY.md"] = 1
    while (sp > 0) {
        f = stack[sp--]
        na = split(adj[f], arr, "\n")
        for (k = 1; k <= na; k++) {
            tgt = arr[k]
            if (tgt ~ /\.md$/ && !(tgt in seen)) { seen[tgt] = 1; stack[++sp] = tgt }
        }
    }
    for (k = 1; k <= nl; k++) {
        f = ord[k]
        if (f !~ /\.md$/ || f == "MEMORY.md") continue
        if (!(f in seen)) print "UNREACHABLE\t" f
        print "MOD\t" f "\t" mod[f]
    }
    print "LINKS\t" nmd + 0 "\t" nwiki + 0
}
AWK
ls -A "$MEMDIR" > "$TMP/listing"
set --
while IFS= read -r _f; do
    # ./ keeps awk from reading a name shaped like var=value as an assignment
    [ -f "$MEMDIR/$_f" ] && set -- "$@" "./$_f"
done < <(grep '\.md$' "$TMP/listing")
( cd "$MEMDIR" && awk -v LIST="$TMP/listing" -f "$TMP/scan.awk" "$TMP/listing" "$@" ) > "$TMP/scan.out" || {
    printf '%s\n' 'memory-capture audit: link scan failed (awk) — refusing to report clean' >&2
    exit 2
}

TAB="$(printf '\t')"
n_unreach=0; n_deadmd=0; n_md_links=0; n_wiki_links=0
: > "$TMP/deadwiki"; : > "$TMP/mods"
while IFS="$TAB" read -r kind a b; do
    case "$kind" in
        UNREACHABLE) n_unreach=$((n_unreach+1)); note "UNREACHABLE: $a" ;;
        DEADLINK) if [ "$MODE" = structure ]; then n_deadmd=$((n_deadmd+1)); note "DEAD LINK: $a -> $b"; fi ;;
        DEADWIKI) printf '%s\t%s\n' "$a" "$b" >> "$TMP/deadwiki" ;;
        MOD) printf '%s\t%s\n' "$a" "$b" >> "$TMP/mods" ;;
        LINKS) n_md_links="$a"; n_wiki_links="$b" ;;
    esac
done < "$TMP/scan.out"

# 7 (wikilink half). A [[x]] with no store file is dead only when the vault has
# no note x either; without a resolvable vault that cannot be told, so the plain
# audit WARNs and --structure refuses to pass unchecked (exit 2).
n_deadwiki=0
if [ -s "$TMP/deadwiki" ]; then
    if [ "$substrate_ok" -eq 1 ]; then
        if [ "$MODE" = structure ]; then
            ( cd "$SUB" && find . -name '.?*' -prune -o \( -type f -o -type l \) -name '*.md' -print ) \
                | sed -e 's#.*/##' -e 's#\.md$##' | sort -u > "$TMP/vaultnames"
            while IFS="$TAB" read -r a b; do
                grep -qxF -- "$b" "$TMP/vaultnames" && continue
                n_deadwiki=$((n_deadwiki+1)); note "DEAD WIKILINK: $a [[$b]]"
            done < "$TMP/deadwiki"
        fi
    else
        n_dw_unchecked="$(awk 'END{print NR+0}' "$TMP/deadwiki")"
        if [ "$MODE" = structure ]; then
            cannot=1
            warn "memory-capture audit: $n_dw_unchecked [[wikilink]](s) name no store file and the vault is unresolvable (LUNA_VAULT_PATH unset and no <home>/Documents/luna) — cannot check them"
        else
            warn "WARN: $n_dw_unchecked [[wikilink]](s) name no store file and the vault is unresolvable — not checked"
        fi
    fi
fi

# 6. TOPIC CAP (sizes in bytes: a topic file is read whole on a keyword match).
n_cap=0
if [ "$MODE" = structure ]; then
    find "$MEMDIR" -maxdepth 1 -name '*.md' ! -name MEMORY.md ! -type d -size +"$TOPIC_MAX"c | sort > "$TMP/caps"
    while IFS= read -r f; do
        [ -n "$f" ] || continue
        n_cap=$((n_cap+1))
        note "TOPIC CAP: $(basename "$f") $(wc -c < "$f" | tr -d ' ')B > ${TOPIC_MAX}B"
    done < "$TMP/caps"
fi

# 3. Line-count tripwire — net MEMORY.md pointer-line growth over the trailing
#    window. >1 line of net growth means themes may be degenerating into
#    per-fact lines (the O(themes) guard).
if [ "$MODE" = plain ] && [ -f "$LOG" ]; then
    delta="$(jq -r --argjson c "$cutoff" '
        select(.event=="write")
        | (.ts | try fromdateiso8601) as $t
        | select($t >= $c)
        | .lines_delta // 0' "$LOG" 2>/dev/null | awk '{s+=$1} END{print s+0}')"
    if [ "${delta:-0}" -gt 1 ]; then
        note "TRIPWIRE: index grew ${delta} pointer lines in ${WINDOW_DAYS}d — themes may be degenerating into per-fact lines"
    fi
fi

# 4. Index budget + over-length-line discipline (length in characters, shared
#    with the capture guard), and 8. the load limit.
n_topic="$(grep -c '\.md$' "$TMP/listing")"; [ -f "$MEMDIR/MEMORY.md" ] && n_topic=$((n_topic-1))
if [ -f "$MEMDIR/MEMORY.md" ]; then
    b="$(wc -c < "$MEMDIR/MEMORY.md" | tr -d ' ')"
    over="$(MEMORY_LINE_MAX="$LINE_MAX" bash "$HERE/../hooks/memory-line-check.sh" < "$MEMDIR/MEMORY.md" | awk 'END{print NR+0}')"
    printf 'index: %sB (budget %sB), over-length lines: %s, topic files: %s\n' "$b" "$BUDGET" "$over" "$n_topic"
    [ "$MODE" = plain ] && [ "$b" -gt "$BUDGET" ] && note "OVER BUDGET: ${b}B > ${BUDGET}B — content is being silently dropped"
    [ "$over" -gt 0 ] && note "LINE DISCIPLINE: $over line(s) exceed ${LINE_MAX} chars"
    if [ "$MODE" = structure ]; then
        idx_lines="$(awk 'END{print NR+0}' "$MEMDIR/MEMORY.md")"
        idx_ptrs="$(awk '/^- /{n++} END{print n+0}' "$MEMDIR/MEMORY.md")"
        [ "$idx_lines" -gt "$LOAD_LINES" ] && note "LOAD LIMIT: MEMORY.md has $idx_lines lines > $LOAD_LINES — the harness does not load the rest"
        [ "$b" -gt "$BUDGET" ] && note "LOAD LIMIT: MEMORY.md is ${b}B > ${BUDGET}B — the harness does not load the rest"
        [ "$idx_ptrs" -gt "$LINE_CEIL" ] && note "LOAD LIMIT: MEMORY.md has $idx_ptrs pointer lines > $LINE_CEIL (routing ceiling)"
    fi
fi

# 9. STALE — WARN only, never a finding: modified under metadata: older than 30 days.
if [ "$MODE" = structure ]; then
    days_from_civil() {
        local y=$1 m=$((10#$2)) d=$((10#$3)) era yoe doy doe
        [ "$m" -le 2 ] && y=$((y-1))
        era=$(( (y >= 0 ? y : y-399) / 400 )); yoe=$((y - era*400))
        doy=$(( (153*(m + (m > 2 ? -3 : 9)) + 2)/5 + d-1 )); doe=$((yoe*365 + yoe/4 - yoe/100 + doy))
        echo $((era*146097 + doe - 719468))
    }
    now_days=$((now_s / 86400)); n_unknown=0; unknown_names=""
    while IFS="$TAB" read -r a b; do
        d10="$(printf '%s' "$b" | cut -c1-10)"
        case "$d10" in
            [0-9][0-9][0-9][0-9]-[0-1][0-9]-[0-3][0-9])
                age=$((now_days - $(days_from_civil "${d10%%-*}" "$(printf '%s' "$d10" | cut -c6-7)" "$(printf '%s' "$d10" | cut -c9-10)")))
                [ "$age" -gt 30 ] && warn "STALE: $a modified $d10 (${age} days old)" ;;
            *) n_unknown=$((n_unknown+1)); [ "$n_unknown" -le 5 ] && unknown_names="$unknown_names $a" ;;
        esac
    done < "$TMP/mods"
    [ "$n_unknown" -gt 0 ] && warn "modified unknown: $n_unknown topic file(s) have no parseable modified under metadata: (first:$unknown_names)"
    printf 'structure: over-cap=%s unreachable=%s dead-md=%s dead-wiki=%s (links: md %s, wiki %s)\n' "$n_cap" "$n_unreach" "$n_deadmd" "$n_deadwiki" "$n_md_links" "$n_wiki_links"
fi

# 5. Collection freshness (best-effort, Rev2 D8). The orphaned-deny verdict is
#    only as good as the substrate it greps; qmd findability of the luna
#    collection is the structural guarantee that re-landed facts are
#    discoverable. If the qmd CLI is present, warn when luna is absent. Skips
#    cleanly on any failure or MEMORY_AUDIT_SKIP_QMD=1 (tests set the latter for
#    hermeticity). Staleness (updated-age parsing) is a future refinement — only
#    absence here.
if [ "$MODE" = plain ] && [ "$QMD_SKIP" != "1" ] && command -v qmd >/dev/null 2>&1; then
    # Group-bounded: a plain `qmd status` can wedge, and
    # timeout(1) would orphan qmd's bun child.
    # shellcheck source=../lib/qmd-bounded.sh
    . "$HERE/../lib/qmd-bounded.sh"
    if qmd_status="$(qmd_bounded "${QMD_TIMEOUT_SECS:-60}" qmd status 2>/dev/null)"; then
        if ! grep -qF -- 'luna (qmd://luna/)' <<< "$qmd_status"; then
            note "COLLECTION FRESHNESS: qmd is on PATH but the luna collection is absent — re-landed facts may not be findable"
        fi
    fi
fi

# Deliberate omission (recorded, not forgotten — P2-12): criterion-3's
# NORMALIZED ratio (lines-added / facts-captured, valid only in a >=10-fact
# window) is NOT implemented. The raw weekly line-delta tripwire (check 3) is
# the primary degeneration signal; the normalized ratio is second-order, and
# its >=10-fact 7-day window is rarely met on this personal store, so it would
# be a mostly-dormant soft signal adding noise. Raw weekly delta only. (Mirrors
# the plan's existing omission note for criterion-5's after-day-30 sub-checks.)

[ "$cannot" -eq 1 ] && { echo "memory-capture audit: $findings finding(s), and a check could not run"; exit 2; }
[ "$findings" -eq 0 ] && { echo "memory-capture audit: clean"; exit 0; }
echo "memory-capture audit: $findings finding(s)"
exit 1
