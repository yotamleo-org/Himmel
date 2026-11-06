#!/usr/bin/env bash
# Generate CHANGELOG.md from conventional-commit history (newest first), grouped
# by version tag: `## [Unreleased]` for commits after the newest version tag,
# then one `## [<tag>] - <date>` section per release, newest release first.
# With NO version tags (the pre-first-release state) the output is a single
# `## [Unreleased]` over all history — byte-identical to the pre-version-tag
# generator, so a tagless repo sees no churn.
# Non-conventional/merge/revert → ### Other.
# Ticket keys (any case) and a trailing `(#n)` are stripped from every subject.
# A tag whose docs/release/<tag>-notes.md passes gen-release-notes.sh --check
# renders that file (the tag's own copy) as its section; while VERSION names no
# tag yet, the working tree's notes file is read the same way and a failing
# file, or one with no release date, exits 1.
# Fully generated; do not hand-edit. Idempotent on immediate re-run.
#
# Usage:
#   gen-changelog.sh            regenerate CHANGELOG.md in place
#   gen-changelog.sh --check    write nothing; exit 1 if the committed file is
#                               stale (prints the missing-entry count). This is
#                               the staleness primitive the morning report and
#                               the release step read.
set -euo pipefail
ROOT="$(git rev-parse --show-toplevel)"
OUT="$ROOT/CHANGELOG.md"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Every temp file this script creates is removed from ONE place. Bash EXIT traps
# are GLOBAL, not per-function: a second `trap ... EXIT` anywhere in the script
# would silently REPLACE this one, so the merge-base sentinel created inside
# generate() is cleaned here rather than at its own creation site (
# private #2077). The INT/TERM traps exist only to reach EXIT at all -- an
# untrapped signal terminates the shell WITHOUT running the EXIT trap, which is
# how an interrupted run used to leave `gen-changelog-mb-err.*` behind.
# `rm -f ""` is a silent no-op, so an unset slot costs nothing. The `--`
# terminator matters: a relative TMPDIR beginning with `-` would otherwise
# make `rm` parse the generated path as an option and leak both files --
# a cleanup that silently fails to clean is the defect the traps prevent.
#
# Bash also DEFERS a trapped signal while it waits on a synchronous child, so a
# wedged `git` kept the script alive and the temp files leaked despite the traps
# above. generate() therefore runs in the background and the main
# shell only `wait`s on it -- `wait` is interrupted by a trapped signal at once --
# and the EXIT trap kills that job's process tree before removing files.
# The wedged git can sit several shells deep (the tag filter runs it inside a
# process-substitution pipeline), so the whole tree under the job is killed.
kill_tree() {
    local c
    for c in $(pgrep -P "$1" 2>/dev/null || true); do kill_tree "$c"; done
    kill "$1" 2>/dev/null || true
}
tmp=""
mb_err_file=""
notes_tmp=""
gen_pid=""
trap '[ -z "$gen_pid" ] || kill_tree "$gen_pid"; rm -f -- "$tmp" "$mb_err_file" "$notes_tmp"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
# shellcheck disable=SC1091
. "$SCRIPT_DIR/lib/commit-class.sh"

# Version tags only. The repo also carries non-version tags (recovery stashes
# etc.); matching them would invent phantom release sections, so the glob is
# `v` + digit — the scheme proposed (`vMAJOR.MINOR.PATCH`, with
# `-rc.N` pre-releases sorting inside the same glob).
VERSION_TAG_GLOB='v[0-9]*'
# The glob above is a cheap pre-filter and also matches non-version tags like
# `v1-backup` or a bare `v1.2` (too few components) — this anchored regex is
# the real gate: `vMAJOR.MINOR.PATCH` with an optional `-rc.1`-style suffix.
VERSION_TAG_RE='^v[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?$'

# render <heading> [<git-log-range>] — emit one version section. An empty range
# means "all history" (the tagless case). Always emits a leading blank line so
# the file ends with exactly one trailing newline (see the trailing-newline note
# below); `return 0` is load-bearing under `set -e` — the last `[ -n … ] && { … }`
# returns 1 when that section is empty, which would otherwise abort the script
# mid-file the moment a repo has no ### Other commits.
render() {
    local heading="$1" range="${2:-}"
    local added="" fixed="" changed="" other="" subj
    # Added/Fixed are single-type sections (the heading conveys feat/fix), so
    # strip the whole `type(scope): ` prefix → just the description (ticket
    # keys are already stripped, cc_strip_keys). `${subj#*: }` removes up to & incl the first
    # `: ` (colon-space); a malformed no-space subject keeps its prefix.
    # Changed is mixed-type (chore/refactor/docs/test) so the type stays
    # informative — keep the full subject; Other keeps the raw subject.
    while IFS= read -r subj; do
        case "$(cc_classify "$subj")" in
            feat)    added="${added}- ${subj#*: }"$'\n';;
            fix)     fixed="${fixed}- ${subj#*: }"$'\n';;
            changed) changed="${changed}- ${subj}"$'\n';;
            *)       other="${other}- ${subj}"$'\n';;
        esac
    done < <(git log --no-merges --format='%s' ${range:+"$range"} | cc_strip_keys)
    echo
    echo "$heading"
    [ -n "$added" ]   && { echo; echo "### Added";   printf '%s' "$added"; }
    [ -n "$fixed" ]   && { echo; echo "### Fixed";   printf '%s' "$fixed"; }
    [ -n "$changed" ] && { echo; echo "### Changed"; printf '%s' "$changed"; }
    [ -n "$other" ]   && { echo; echo "### Other";   printf '%s' "$other"; }
    return 0
}

# notes_valid <file> — the release-notes shape check, exit code only.
notes_valid() {
    bash "$SCRIPT_DIR/release/gen-release-notes.sh" --check "$1" >/dev/null 2>&1
}

# notes_date <file> — the `**Release date:** YYYY-MM-DD` line's date, or nothing.
notes_date() {
    sed -nE 's/^\*\*Release date:\*\* ([0-9]{4}-[0-9]{2}-[0-9]{2})[.]?$/\1/p' "$1" | head -1
}

# emit_notes <heading> <notes-file> — one version section made of the notes'
# five sections demoted to `###`. The title and date lines before the first
# `## ` are dropped, and trailing blank lines too, so the section ends like
# render's does.
emit_notes() {
    echo
    echo "$1"
    echo
    awk '/^## /{s=1; sub(/^## /,"### ")} s{b[n++]=$0} END{while(n>0&&b[n-1]=="")n--; for(i=0;i<n;i++)print b[i]}' "$2"
}

# notes_section <tag> <notes-file> — heading date comes from the notes, never
# the tag, so the bytes do not move when the tag appears. Exits 1 on a passing
# file with no release date.
notes_section() {
    local d
    d="$(notes_date "$2")"
    if [ -z "$d" ]; then
        echo "gen-changelog: ERROR: $1 notes pass the shape check but carry no '**Release date:** YYYY-MM-DD' line" >&2
        exit 1
    fi
    emit_notes "## [$1] - $d" "$2"
}

# Blank line goes BEFORE each heading (not after each section) so the file
# ends with exactly one trailing newline — otherwise end-of-file-fixer rewrites
# it on every commit and a freshly regenerated file never matches the committed
# one (breaking the idempotence promise). $added/$fixed/… already end in \n, so
# the section body is emitted with `printf '%s'` (no extra trailing newline).
generate() {
    local tags=() t prev date
    # Sentinel for a real `git merge-base` error (see below): the tag filter
    # runs inside a process-substitution pipeline, so a plain `exit` there
    # only kills that subshell, not this script -- the sentinel file is how
    # the failure is carried back out to fail generation for real. The file is
    # created by run_generate (below) so the main shell's trap can remove it.
    # Order by ANCESTRY (commit count via `git rev-list --count`), newest
    # first — NOT creatordate: a backfilled annotated tag on an older commit
    # can carry a newer creatordate than a tag on a later commit, which would
    # sort it first and compute `<prev>..<tag>` ranges against the wrong
    # predecessor. Assumes a linear release history (this repo's `main`,
    # squash merges) — a tag on a side branch is not orderable this way, so
    # such tags are filtered out below (with a stderr warning) before the
    # count sort even runs.
    while IFS= read -r t; do
        [ -n "$t" ] && tags+=("$t")
    done < <(
        while IFS= read -r vt; do
            [ -n "$vt" ] || continue
            # Reachable-commit-count ordering is only valid for tags that are
            # ancestors of HEAD — a tag on a side branch has no topological
            # relationship to HEAD history, so its count is meaningless and
            # sorting by it corrupts every release range (a
            # side-branch tag with a higher count than the real latest
            # release outranks it, and commits already released reappear
            # under both `## [Unreleased]` and their real release section).
            # Drop it, but never silently: a dropped release tag is a trap
            # for the next operator wondering where a release went.
            # `--is-ancestor` exits 1 for "not an ancestor" but >1 for a real
            # git error (bad object, corrupt ref) -- conflating the two would
            # silently drop a release tag on an operational error instead of
            # failing generation. The error is recorded to
            # $mb_err_file (see above) so it fails the whole script, not just
            # this pipeline subshell.
            mb_rc=0
            git merge-base --is-ancestor "$vt" HEAD 2>/dev/null || mb_rc=$?
            if [ "$mb_rc" -gt 1 ]; then
                echo "gen-changelog: ERROR: git merge-base --is-ancestor failed for tag '$vt' (exit $mb_rc)" >&2
                echo "$mb_rc" > "$mb_err_file"
                exit 1
            elif [ "$mb_rc" -eq 1 ]; then
                echo "gen-changelog: WARNING: version tag '$vt' is not an ancestor of HEAD (side branch) — excluded from CHANGELOG.md" >&2
                continue
            fi
            # Tie-break for equal ancestry counts (two tags on the SAME
            # commit, e.g. an rc promoted to its release): a release sorts
            # before a pre-release of the same version (semver precedence --
            # `v0.1.0` outranks `v0.1.0-rc.1`), then tag name descending, so
            # the order is total. rank=1 (no `-` suffix) sorts ahead of
            # rank=0 (has one) under the `nr` (numeric reverse) sort below.
            case "$vt" in
                (*-*) rank=0 ;;
                (*)   rank=1 ;;
            esac
            printf '%s\t%s\t%s\n' "$(git rev-list --count "$vt")" "$rank" "$vt"
        done < <(git tag --list "$VERSION_TAG_GLOB" | grep -E "$VERSION_TAG_RE") \
          | sort -t $'\t' -k1,1nr -k2,2nr -k3,3r | cut -f3
    )
    if [ -s "$mb_err_file" ]; then
        rm -f -- "$mb_err_file"
        exit 1
    fi
    rm -f -- "$mb_err_file"

    # A final tag at the SAME commit as a pre-release of its own series
    # (v1.0.0 vs v1.0.0-pre.1) absorbs that pre-release: otherwise the final
    # tag's range is empty and the release content sits under the pre-release
    # heading. A pre-release at a different commit, or of another
    # series, keeps its own section.
    local kept=() ft ct
    for t in ${tags[@]+"${tags[@]}"}; do
        case "$t" in
            (*-*)
                ct="$(git rev-parse "$t^{commit}")"
                for ft in "${tags[@]}"; do
                    case "$ft" in (*-*) continue ;; esac
                    case "$t" in ("$ft"-*)
                        [ "$(git rev-parse "$ft^{commit}")" = "$ct" ] && continue 2 ;;
                    esac
                done
                ;;
        esac
        kept+=("$t")
    done
    tags=(${kept[@]+"${kept[@]}"})

    echo "<!-- generated by scripts/gen-changelog.sh; do not hand-edit -->"
    echo "# Changelog"
    if [ "${#tags[@]}" -eq 0 ]; then
        render "## [Unreleased]"
        return 0
    fi
    # Newest tag first: unreleased = everything after it, then each tag's own
    # range down to its predecessor; the oldest tag takes the open-ended range
    # (all history up to that tag).
    # Open range: VERSION names no tag yet and its notes file exists, so the
    # section is rendered from the working tree's notes (a failing file stops
    # generation, never falls back) and the commits since the newest tag live
    # in it, leaving [Unreleased] empty -- the same bytes the tag will produce.
    local ver=""
    if [ -f "$ROOT/VERSION" ]; then
        ver="v$(tr -d '[:space:]' < "$ROOT/VERSION")"
    fi
    if [[ "$ver" =~ $VERSION_TAG_RE ]] \
       && ! git rev-parse -q --verify "refs/tags/$ver" >/dev/null \
       && [ -f "$ROOT/docs/release/$ver-notes.md" ]; then
        if ! notes_valid "$ROOT/docs/release/$ver-notes.md"; then
            echo "gen-changelog: ERROR: docs/release/$ver-notes.md fails 'gen-release-notes.sh --check'; fix it before generating" >&2
            exit 1
        fi
        echo
        echo "## [Unreleased]"
        notes_section "$ver" "$ROOT/docs/release/$ver-notes.md"
    else
        render "## [Unreleased]" "${tags[0]}..HEAD"
    fi
    local i=0
    while [ "$i" -lt "${#tags[@]}" ]; do
        t="${tags[$i]}"
        prev=""
        [ $((i + 1)) -lt "${#tags[@]}" ] && prev="${tags[$((i + 1))]}"
        # A tag's own notes file is its section when it passes the shape
        # check; tag contents never change, so a later edit cannot move it.
        if git show "$t:docs/release/$t-notes.md" > "$notes_tmp" 2>/dev/null && notes_valid "$notes_tmp"; then
            notes_section "$t" "$notes_tmp"
        else
            date="$(git log -1 --format=%ad --date=short "$t")"
            render "## [$t] - $date" "${prev:+$prev..}$t"
        fi
        i=$((i + 1))
    done
    return 0
}

# run_generate <outfile> — generate > <outfile> as a background job the main
# shell waits on, so INT/TERM reach the trap immediately. The
# sentinel is created here, not in generate(), because generate() now runs in a
# subshell whose variable assignments never reach the main shell's trap. `wait`
# returns generate's exit status, so `set -e` fails the script exactly as the
# foreground call did.
run_generate() {
    mb_err_file="$(mktemp "${TMPDIR:-/tmp}/gen-changelog-mb-err.XXXXXX")" || {
        echo "gen-changelog: mktemp failed" >&2
        exit 1
    }
    notes_tmp="$(mktemp "${TMPDIR:-/tmp}/gen-changelog-notes.XXXXXX")" || {
        echo "gen-changelog: mktemp failed" >&2
        exit 1
    }
    local rc=0
    generate > "$1" &
    gen_pid=$!
    wait "$gen_pid" || rc=$?
    gen_pid=""
    return "$rc"
}

if [ "${1:-}" = "--check" ]; then
    if [ ! -f "$OUT" ]; then
        echo "STALE gen-changelog: CHANGELOG.md is missing — run scripts/gen-changelog.sh"
        exit 1
    fi
    # Explicit template (BSD/macOS portability); capture failure before
    # generate builds paths on an unset $tmp. The EXIT trap that removes this
    # file is installed once at the top of the script, not here.
    tmp="$(mktemp "${TMPDIR:-/tmp}/gen-changelog.XXXXXX")" || {
        echo "gen-changelog: mktemp failed" >&2
        exit 1
    }
    run_generate "$tmp"
    if cmp -s "$tmp" "$OUT"; then
        echo "OK gen-changelog: CHANGELOG.md is current"
        exit 0
    fi
    # Count only entry lines (`- ...`), not section headings/blank lines a new
    # section introduces — `diff` marks an added line `> `, so an entry line
    # shows as `> - `.
    # `|| true` rescues the pipeline: diff exits 1 on a difference and pipefail
    # would propagate that into the command substitution under `set -e`.
    missing="$(diff "$OUT" "$tmp" 2>/dev/null | grep -c '^> - ' || true)"
    if [ "$missing" -eq 0 ]; then
        # A tag-only restructure (a release tag added with no new commits)
        # moves existing entries between sections without adding any --
        # "0 entr(ies) behind" reads as a bug in the checker, not staleness.
        # Report the true shape instead; morning-report.sh's counted-line
        # regex only matches "is <digits> entr(ies) behind", so this line
        # correctly falls through to its verbatim fallback.
        echo "STALE gen-changelog: CHANGELOG.md structure changed with no new entries — run scripts/gen-changelog.sh"
    else
        echo "STALE gen-changelog: CHANGELOG.md is $missing entr(ies) behind — run scripts/gen-changelog.sh"
    fi
    exit 1
fi

# Generate aside and copy over only on success, so a refusal (exit 1) leaves
# the committed file as it was instead of truncated.
tmp="$(mktemp "${TMPDIR:-/tmp}/gen-changelog.XXXXXX")" || {
    echo "gen-changelog: mktemp failed" >&2
    exit 1
}
run_generate "$tmp"
cat "$tmp" > "$OUT"
