#!/usr/bin/env bash
# Branch-scoped /pr-check review-round state and round-4 cap.
# The first round and a start --full review the whole PR; every later one reviews the
# increment from the reviewed head R (increment_of) and its class decides the
# spend: carried, a free class (<branch>.free) or work.
# After three full rounds the only round left is ONE delta round for a work
# increment, when R raised a finding, or through the triggers below.
# A 4th full round and a second delta are refused. Every start writes
# <branch>.scope, which defer reads.
# State lives under the repository's shared git common directory, so head
# commits and merge-forwards do not reset it and linked worktrees agree.
# A third trigger - a judge NO-GO on the last reviewed head, as
# chief-kit/write-verdict.sh records it in this repo's verdict scope - buys
# one more delta round per reviewed head, even after the fix delta was used.
# Consumed records are kept in <branch>.verdicts; their repeated-class veto
# runs for every class past the cap.
# A conflict-resolving merge whose lines are not all inside conflict spans needs
# a judge GO carrying `delta-scope: merge-resolution` and `delta-from:`, bound
# like the scope records.
# Every verdict record read here (NO-GO delta, layer-decision,
# scope) must carry write-verdict.sh's mac under the GO key; a hand-written or
# edited record disqualifies its qid. Scope records also bind to this branch's
# PR/branch, and any NO-GO for the new head blocks the scope round. The key is
# readable by the same uid, so the ceiling is a same-uid forger;
# a lint-only record still rests on the judge's word.
# Once the delta round ran, one more delta round, from the head it
# reviewed, is admitted without a judge record when that head raised critic
# findings and every one is recorded fixed there. Consumed once: the .delta pair
# carries trigger postcap-fixed and a post-cap round never chains into another.
# A CI-red reviewed head (delta round spent or not) buys ONE bounded delta
# round with no judge record: the last reviewed head has a COMPLETED check-run with conclusion failure (read through
# gh api, none still running), the increment since it is at most 40 diff lines, and
# the PR has not had this unlock before (.cired). Recorded in the ledger.
# A non-empty --base-sha is verified once at intake against the
# REMOTE only (gh api: default branch name, then compare <sha>...<default> must
# be identical or ahead); no local ref names or vouches for it. Offline, no gh
# or an unreadable answer therefore refuses every --base-sha round (exit 8).
# A start at the head the last counted round ran on, below the cap, reuses that
# round; bookkeeping-only heads get their ledger row from the `evidence` verb.
# A panel whose critics were all unavailable falls back to the session's
# claude-only floor review, the outcome that counts: that round is settled.
# A start with --head first writes <branch>.start.bak, a snapshot of every round
# file before and after it. A round whose panel aborted after start reviewed
# nothing and spends nothing: `abort` restores the snapshot, so the count, the
# delta slot, the CI-red unlock and a consumed judge record all come back. A
# round a dead session left with no panel row is continued by a start at its
# head, or given back by a start at another head two hours after it began;
# `settle` keeps such a round counted and drops its snapshot.
# defer exits 6 when automatic residual filing cannot resolve the parent from
# the open PR title (or, before round four, the branch's commit subjects) or
# cannot create a ticket; supply --defer-to to recover
# against the recorded findings without rerunning the panel. A hardening
# finding with no recorded fu_why also exits 6 until --fu-why <code> names one
# of unseen-failure|no-check|vacuous-check|no-recovery|silent-rot.
# Decisions 746, 762: a polish Suggestion/nit files no ticket. With no
# --defer-to, defer amends its row verdict=deferred, fu_class=polish with no
# deferred_to, and the marker still clears. The record of that note depends on
# the tracker (project-mode.sh, after the .env is loaded): on a Jira repo it is a
# polish-noted comment on the PR's own ticket, posted by note-polish.sh before
# anything is commented, filed or amended (no PR ticket, or a failed comment,
# exits 6 with nothing written; an unresolvable tracker exits 6 too); on a local
# or none repo it is the note in the PR body. A Suggestion keeps its ledger class:
# escape blocks (exit 4) and hardening takes the hardening road on a Jira repo.
# A finding raised Critical or Important and amended lower is routed by the
# severity it was raised with, so defer never notes it as polish (exit 4). A
# hardening finding is filed only with --fu-override <judge verdict id|decision-N>;
# without one defer exits 6 naming the flag. A pre-existing Important classed polish
# cannot be noted: reclassify it or supply --defer-to <plain ticket>.
# A Suggestions-only round below the cap closes early on a change that touches
# no CI trust path. Its polish rows file nothing (see above); an explicit
# --defer-to attaches every pending finding to that existing ticket, and a
# hardening row with an override is filed as ONE
# batch residual per branch and keeps its key in
# <branch>.deferred-to, which every later early close reuses, adding its
# findings to that ticket as a comment (a failed comment exits 6; rerun to
# retry it); the start of a
# new loop's first round removes it and cr-reset.sh moves it aside. With no PR
# title key the batch's parent is the first [KEY-n] in the branch's commit
# subjects. A .deferred-to that cannot be removed or written exits 5, like
# every other state-file error; a write failure names the filed key for
# --defer-to.
# start runs bounded: an outer holds CR_REVIEW_START_TIMEOUT_SECS (1 to 280, default
# 240) over a body in its own process group, with its output in temp files. A body that
# answered, or exited by itself, is never refused. At the bound the outer stops the
# body's group, releases the counter lock only when its record names the body, and
# exits 5 with one line naming the last step reached and the processes it was waiting
# on. It does not give the round back: the files stay as a hand kill leaves them, and
# the next start settles them. When ps cannot confirm the caller, start does not split
# and runs unbounded, with one stderr line saying so.
# Bash 3.2-safe.
# Platform guard: requires POSIX Bash 3.2+; on Windows, run under Git Bash.
set -uo pipefail
# A relative-entry copy that is not the anchor's hands off to it.
case "${BASH_SOURCE[0]}" in */*) _ah_d="${BASH_SOURCE[0]%/*}" ;; *) _ah_d=. ;; esac
. "$_ah_d/anchor-handoff.sh" || exit 2
# Classify the real commit trees, never refs/replace substitutes.
export GIT_NO_REPLACE_OBJECTS=1
unset GIT_CONFIG

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HIMMEL_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# every read-only GitHub call below rides the second, read-only token
# (scripts/lib/gh-read.sh) so a spent main token does not stop a review round; a
# refused or missing read token falls back to the main one inside the router. The
# executed form, not the function: these calls sit behind `timeout`, which cannot
# run a shell function. A copy without the lib (a fixture) keeps plain gh. Writes
# never go through here.
if [ -f "$HIMMEL_ROOT/scripts/lib/gh-read.sh" ]; then _RR_GH=(bash "$HIMMEL_ROOT/scripts/lib/gh-read.sh"); else _RR_GH=(gh); fi

usage() {
    echo "usage: review-round.sh start --branch <name> [--head <sha> [--base-sha <sha>]] [--full]   (prints <round>, <round> increment <L>, <round> delta <L> or <round> carried <R>; --full reviews the whole PR and is never classified)" >&2
    echo "       review-round.sh defer --branch <name> --head <sha> [--defer-to <ticket>] [--fu-why <code>] [--fu-override <id>]" >&2
    echo "       review-round.sh promote [--check] --branch <name> --head <sha>   (--check: the same verdict, read only, nothing written)" >&2
    echo "       review-round.sh judge-go --branch <name> --head <sha> [--open-threads-ok <reason>]   (after the cap: a signed judge GO at <sha> stands in for the review; refused while the PR has an unresolved review thread unless the chief names the override)" >&2
    echo "       review-round.sh evidence --branch <name> --head <sha>   (ledger ok row for a tests-only head after a reviewed head; spends no round)" >&2
    echo "       review-round.sh abort --branch <name> --head <sha>   (give back the round started at <sha> when its panel reviewed nothing)" >&2
    echo "       review-round.sh settle --branch <name> --head <sha>   (the round started at <sha> stays counted; its snapshot is dropped, so no later start waits on it)" >&2
    echo "       review-round.sh trivial-descendant [--tests-only] <from-sha> <to-sha>   (exit 0 yes, 1 no)" >&2
    echo "       review-round.sh clean-merge-forward <base-sha> <from-sha> <to-sha>   (exit 0 when <to>'s tree is the merge of the base into <from> with no conflict marker left; 1 no)" >&2
    echo "       review-round.sh start|check --pr <n> --head <40-hex sha>   (an outside PR reviewed from its diff, its branch not checked out; check reads only)" >&2
    echo "       review-round.sh abort --pr <n> --head <40-hex sha>   (give back that PR's round when its panel reviewed nothing)" >&2
    exit 2
}

rr_phase_file=""
rr_caller="$PPID"
rr_body=""
rr_wd=""
rr_dir=""
rr_bound=240
rr_usr1=0
rr_lock_clause=""
rr_phase() { [ -z "$rr_phase_file" ] || printf '%s\n' "$1" > "$rr_phase_file" 2>/dev/null; return 0; }

rr_tree() {
    local f="$1" n=0
    {
        { ps -ww -A -o pgid=,pid=,ppid=,stat=,args= 2>/dev/null || ps -A -o pgid=,pid=,ppid=,stat=,args= 2>/dev/null; } \
            | awk -v g="$rr_body" '
                { pg[NR] = $1; pd[NR] = $2; pp[NR] = $3; st[NR] = $4; ln[NR] = $0; n = NR; if ($1 == g) ing[$2] = 1 }
                END {
                    for (i = 1; i <= n; i++) if (st[i] !~ /^Z/ && (pg[i] == g || (pp[i] in ing))) {
                        s = ln[i]
                        sub(/^[ \t]*[0-9]+[ \t]+[0-9]+[ \t]+[0-9]+[ \t]+[^ \t]+[ \t]*/, "", s)
                        print pd[i] " " substr(s, 1, 100)
                    }
                }' > "$f.part"
    } </dev/null >/dev/null 2>&1 3>&- 4>&- 5>&- 6>&- 7>&- 8>&- 9>&- &
    rr_rt=$!
    while [ "$n" -lt 20 ] && kill -0 "$rr_rt" 2>/dev/null; do n=$((n + 1)); sleep 0.1; done
    if kill -0 "$rr_rt" 2>/dev/null || ! cat "$f.part" > "$f" 2>/dev/null; then
        printf 'tree not read\n' > "$f"
    fi
    return 0
}

rr_stop_group() {
    local n=0
    kill -TERM -- "-$rr_body" 2>/dev/null || return 0
    while [ "$n" -lt 2 ]; do
        sleep 1
        kill -0 -- "-$rr_body" 2>/dev/null || return 0
        n=$((n + 1))
    done
    kill -KILL -- "-$rr_body" 2>/dev/null
    return 0
}

rr_stop_watchdog() {
    kill -KILL -- "-$rr_wd" 2>/dev/null
    wait "$rr_wd" 2>/dev/null
    return 0
}

rr_release_lock() {
    local lib="$HIMMEL_ROOT/scripts/lib/shared-branch-lock.sh" rec rc
    rr_lock_clause="the counter lock was not checked"
    [ -f "$lib" ] && [ -f "$HIMMEL_ROOT/scripts/lib/qmd-bounded.sh" ] || return 0
    # shellcheck source=scripts/lib/qmd-bounded.sh
    # shellcheck disable=SC1091
    . "$HIMMEL_ROOT/scripts/lib/qmd-bounded.sh" 2>/dev/null || return 0
    # swallow-ok: rc 2 or 124 from the capped status call leaves the clause at "not checked"
    rec="$(SHARED_BRANCH_LOCK_NS=himmel-cr-review-round QMD_KILL_GRACE_SECS=1 qmd_bounded 10 bash "$lib" status "." "$branch" 2>/dev/null)"
    rc=$?
    case "$rc" in
        0) rr_lock_clause="it holds no counter lock" ;;
        11)
            case "$rec" in
                "{\"pid\":$rr_body,"*|"{\"pid\":$rr_body}"*)
                    SHARED_BRANCH_LOCK_NS=himmel-cr-review-round QMD_KILL_GRACE_SECS=1 \
                        qmd_bounded 10 bash "$lib" release-if-owner "." "$branch" "$rec" >/dev/null 2>&1
                    case $? in
                        0) rr_lock_clause="the counter lock it held was released" ;;
                        3) rr_lock_clause="it holds no counter lock" ;;
                    esac ;;
                '{"pid":'*) rr_lock_clause="it holds no counter lock" ;;
                *) rr_lock_clause="the counter lock has no owner record; if no start or grant is running on $branch, clear it with SHARED_BRANCH_LOCK_NS=himmel-cr-review-round bash scripts/lib/shared-branch-lock.sh release . $branch" ;;
            esac ;;
    esac
    return 0
}

rr_refuse() {
    local last="unknown" tree round
    [ -e "$rr_dir/flag" ] || rr_tree "$rr_dir/tree"
    rr_stop_group
    rr_stop_watchdog
    rr_release_lock
    cat "$rr_dir/err" >&2 2>/dev/null
    [ ! -s "$rr_dir/phase" ] || read -r last < "$rr_dir/phase" || last="unknown"
    # swallow-ok: an unreadable tree file reads as "nothing recorded" in the refusal line
    tree="$(awk 'NR > 1 { printf "; " } { printf "%s", $0 }' "$rr_dir/tree" 2>/dev/null)"
    [ -n "$tree" ] || tree="nothing recorded"
    case "$last" in
        snapshot-write|delta-write|persist)
            round="its round may stay counted; a restart at ${head_sha:-unknown} continues it, and a start at another head may wait up to two hours" ;;
        *) round="its round files are left as a killed start leaves them, and the next start settles them" ;;
    esac
    printf 'review-round: start on %s at %s %s (last step: %s) - %s; %s; it was waiting on: %s\n' \
        "$branch" "${head_sha:-unknown}" "$1" "$last" "$rr_lock_clause" "$round" "$tree" >&2
    exit 5
}
rr_on_signal() {
    trap : TERM INT HUP
    rr_refuse "was stopped by signal inside its ${rr_bound}s bound"
}

rr_start_outer() {
    local why="" pp
    # swallow-ok: a failed ps read leaves start unsplit, and the stderr line says why
    pp="$(ps -o ppid= -p "$$" 2>/dev/null)" || pp=""
    pp="${pp//[[:space:]]/}"
    if [ "$pp" != "$PPID" ]; then why="ps cannot confirm the caller"
    elif ! command -v sleep >/dev/null 2>&1; then why="no sleep on PATH"
    # prim-ok: fixture copies of this script have no scripts/lib/prim.sh
    elif ! rr_dir="$(mktemp -d "${TMPDIR:-/tmp}/review-round-start.XXXXXX" 2>/dev/null)"; then why="no temp dir"  # swallow-ok: a failed mktemp leaves start unsplit, and the stderr line says why
    fi
    if [ -n "$why" ]; then
        rr_dir=""
        echo "review-round: start runs unbounded ($why)" >&2
        return 0
    fi
    trap 'rm -rf "$rr_dir"' EXIT
    rr_bound="${CR_REVIEW_START_TIMEOUT_SECS:-240}"
    case "$rr_bound" in ''|*[!0-9]*) rr_bound=240 ;; esac
    { [ "$rr_bound" -ge 1 ] && [ "$rr_bound" -le 280 ]; } 2>/dev/null || rr_bound=240
    trap 'rr_usr1=1' USR1
    set -m
    _RR_START_INNER=1 _RR_START_CALLER="$PPID" _RR_START_PHASE="$rr_dir/phase" "$BASH" "$0" start ${rr_args[@]+"${rr_args[@]}"} \
        </dev/null >"$rr_dir/out" 2>"$rr_dir/err" 3>&- 4>&- 5>&- 6>&- 7>&- 8>&- 9>&- &
    rr_body=$!
    (
        sleep "$rr_bound"
        rr_tree "$rr_dir/tree"
        : > "$rr_dir/flag"
        rr_stop_group
        kill -USR1 "$$" 2>/dev/null
    ) </dev/null >/dev/null 2>&1 3>&- 4>&- 5>&- 6>&- 7>&- 8>&- 9>&- &
    rr_wd=$!
    set +m
    trap rr_on_signal TERM INT HUP
    local w=0 w2 st rc=0
    while :; do
        wait "$rr_body" 2>/dev/null
        w=$?
        if kill -0 "$rr_body" 2>/dev/null; then
            if [ "$rr_usr1" -eq 1 ]; then
                # swallow-ok: no stat means the body is gone, which the next wait settles
                st="$(ps -o stat= -p "$rr_body" 2>/dev/null)"
                st="${st//[[:space:]]/}"
                case "$st" in ''|Z*) continue ;; *) rc=137; break ;; esac
            fi
            continue
        fi
        if [ "$rr_usr1" -eq 1 ] && [ "$w" -gt 128 ]; then
            wait "$rr_body" 2>/dev/null
            w2=$?
            [ "$w2" -eq 127 ] || w="$w2"
        fi
        rc="$w"
        break
    done
    trap : TERM INT HUP
    if [ -s "$rr_dir/out" ]; then
        rr_stop_watchdog
        cat "$rr_dir/err" >&2
        cat "$rr_dir/out"
        [ "$rc" -le 128 ] || rc=0
        exit "$rc"
    fi
    if [ "$rc" -ne 0 ] && [ "$rc" -le 128 ]; then
        rr_stop_watchdog
        cat "$rr_dir/err" >&2
        exit "$rc"
    fi
    if [ -e "$rr_dir/flag" ]; then rr_refuse "did not finish within ${rr_bound}s"
    elif [ "$rc" -gt 128 ]; then rr_refuse "was killed by signal $((rc - 128))"
    else rr_refuse "exited 0 but its answer was lost"
    fi
}

# test_path_p <path>: the test-path rule of the scope record.
# Filename patterns match the basename only: * crosses / in case.
test_path_p() {
    case "$1" in
        */tests/*|tests/*|*/test/*|test/*|*/__tests__/*) return 0 ;;
    esac
    case "${1##*/}" in
        test-*.sh|*.test.[a-z]*) return 0 ;;
    esac
    return 1
}

# plugin_json_path <path>: a marketplace plugin's manifest. plugin_version,
# semver_gt and version_bump_only sit up here because the trivial-descendant
# verb below runs before the rest of the file is defined.
plugin_json_path() {
    case "$1" in
        marketplace/plugins/*/.claude-plugin/plugin.json) ;;
        *) return 1 ;;
    esac
    _pj_name="${1#marketplace/plugins/}"
    _pj_name="${_pj_name%/.claude-plugin/plugin.json}"
    case "$_pj_name" in ''|*/*) return 1 ;; esac
    return 0
}
# plugin_version <file>: prints the one "version" value, which must sit alone
# on its line as plain X.Y.Z; fails on any other shape or a second version key.
# The key must also be the file's top-level one, not nested.
# shellcheck disable=SC2016  # JavaScript source is literal here
plugin_version() {
    [ "$(awk '/"version"[[:space:]]*:/ { n++ } END { print n + 0 }' "$1")" = "1" ] || return 1
    _pv_v="$(sed -n -E 's/^[[:space:]]*"version"[[:space:]]*:[[:space:]]*"([0-9]{1,9}\.[0-9]{1,9}\.[0-9]{1,9})"[[:space:]]*,?[[:space:]]*$/\1/p' "$1")"
    [ -n "$_pv_v" ] || return 1
    PV_FILE="$1" PV_WANT="$_pv_v" node -e '
const fs = require("fs"), e = process.env;
const o = JSON.parse(fs.readFileSync(e.PV_FILE, "utf8"));
process.exit(o && typeof o === "object" && !Array.isArray(o) && o.version === e.PV_WANT ? 0 : 1);
' 2>/dev/null || return 1
    printf '%s\n' "$_pv_v"
}
# semver_gt <a> <b>: a > b for two plain X.Y.Z values.
semver_gt() {
    _sg_a="$1"; _sg_b="$2"
    for _sg_i in 1 2 3; do
        _sg_x="${_sg_a%%.*}"; _sg_y="${_sg_b%%.*}"
        _sg_a="${_sg_a#*.}"; _sg_b="${_sg_b#*.}"
        [ "$((10#$_sg_x))" -gt "$((10#$_sg_y))" ] && return 0
        [ "$((10#$_sg_x))" -lt "$((10#$_sg_y))" ] && return 1
    done
    return 1
}
# version_bump_only <from> <to> <path> succeeds when <path> is a plain-file
# plugin.json in both commits whose only difference is a strictly higher
# "version" value: the bump plugin-version-bump-required forces on a plugin PR.
version_bump_only() {
    _vb_tmp="$(mktemp -d "${TMPDIR:-/tmp}/review-round.XXXXXX")" || return 1  # prim-ok: the same idiom version_only_merge uses; this script does not source prim.sh
    _vb_ok=1
    for _vb_side in "$1:old" "$2:new"; do
        _vb_c="${_vb_side%:*}"; _vb_n="${_vb_side##*:}"
        if [ "$(git ls-tree "$_vb_c" -- "$3" 2>/dev/null | cut -c1-6)" != "100644" ] \
            || ! git cat-file blob "$_vb_c:$3" > "$_vb_tmp/$_vb_n" 2>/dev/null \
            || ! plugin_version "$_vb_tmp/$_vb_n" > "$_vb_tmp/$_vb_n.v" \
            || ! sed -E 's/^([[:space:]]*"version"[[:space:]]*:[[:space:]]*")[0-9.]*"/\1"/' \
                "$_vb_tmp/$_vb_n" > "$_vb_tmp/$_vb_n.n"; then
            _vb_ok=0; break
        fi
    done
    if [ "$_vb_ok" -eq 1 ]; then
        semver_gt "$(cat "$_vb_tmp/new.v")" "$(cat "$_vb_tmp/old.v")" \
            && cmp -s "$_vb_tmp/old.n" "$_vb_tmp/new.n" || _vb_ok=0
    fi
    rm -rf "$_vb_tmp"
    [ "$_vb_ok" -eq 1 ]
}

# trivial_descendant <from> <to> succeeds when <to> is a strict
# descendant of <from> and <from>..<to> changes only test paths (the
# judge_scope_record rule, plus a version-only plugin.json bump beside at
# least one test path) or only comment lines. A judge often reviews a head
# after such a commit, which never got its own panel round. Also the one
# classifier chief-kit/write-verdict.sh --bind-reviewed asks, through the
# `trivial-descendant` verb below, so the writer and the gate cannot disagree.
trivial_descendant() {
    [ "$1" != "$2" ] || return 1
    git merge-base --is-ancestor "$1" "$2" 2>/dev/null || return 1
    tests_only_paths "$1" "$2" && return 0
    # --tests-only drops the comment branch for the clear-cr-marker
    # fallback, which clears with no critic review of from..to.
    [ "${_td_tests_only:-0}" -eq 0 ] || return 1
    comment_only_diff "$1" "$2"
}

tests_only_paths() {
    _td_paths="$(git -c core.quotepath=off diff --no-renames --name-only "$1" "$2" 2>/dev/null)" || return 1
    [ -n "$_td_paths" ] || return 1
    _td_ok=1
    _td_tests=0
    while IFS= read -r _td_p; do
        if plugin_json_path "$_td_p"; then
            # A manifest is never a test path, even under a plugin named tests.
            version_bump_only "$1" "$2" "$_td_p" || { _td_ok=0; break; }
        elif test_path_p "$_td_p"; then
            _td_tests=1
        else
            _td_ok=0; break
        fi
    done <<EOF
$_td_paths
EOF
    # A hook-forced plugin version bump rides along with tests, never alone.
    [ "$_td_ok" -eq 1 ] && [ "$_td_tests" -eq 1 ]
}

comment_only_diff() {
    # Binary edits and mode/create/delete changes carry no +/- text line, so a
    # text-only scan would miss them: refuse any of them outright.
    _td_bin="$(git diff --no-renames --numstat "$1" "$2" 2>/dev/null | grep -E '^-' || true)"
    [ -z "$_td_bin" ] || return 1
    _td_sum="$(git diff --no-renames --summary "$1" "$2" 2>/dev/null)" || return 1
    [ -z "$_td_sum" ] || return 1
    # Every added or removed line must be a comment or blank.
    _td_lines="$(git diff --no-renames --no-color -U0 "$1" "$2" 2>/dev/null | sed -n -e '/^+++ /d' -e '/^--- /d' -e '/^[-+]/p')" || return 1
    [ -n "$_td_lines" ] || return 1
    _td_bad="$(printf '%s\n' "$_td_lines" | grep -vE '^[-+][[:space:]]*($|#([[:space:]#]|$)|//)' || true)"
    [ -z "$_td_bad" ] || return 1
    # Directive words, encoding declarations (coding: / coding=) and C
    # preprocessor lines change meaning although they start with #.
    # Build constraints, type/format/lint pragmas and editor modelines too.
    _td_dir="$(printf '%s\n' "$_td_lines" | grep -iE '^[-+][[:space:]]*((#|//).*(shellcheck|disable|noqa|nolint|eslint|pragma|gitleaks|-ok:|coding[:=]|go:|\+build|@ts-|type:|fmt:|isort|pylint|mypy|pyright|yapf|-\*-|vim?:|<reference|sourceMappingURL)|#[[:space:]]*(define|include|undef|ifn?def|if|else|elif|endif|line|error|import)([^[:alnum:]_]|$))' || true)"
    [ -z "$_td_dir" ] || return 1
    return 0
}

# merge_forward_shape <from> <to> succeeds when <to> merges the
# captured base into <from> and nothing else: at least one merge, every
# non-merge commit it brought already on the base, and every merge a plain
# two-parent merge whose first parent descends from <from> (not on the base)
# and whose second parent is a point on the base newer than the base point
# <from> had.
merge_forward_shape() {
    [ -n "$base_sha" ] || return 1
    [ -n "$(git rev-list --merges "$1..$2" "^$base_sha" 2>/dev/null)" ] || return 1
    [ -z "$(git rev-list --no-merges "$1..$2" "^$base_sha" 2>/dev/null)" ] || return 1
    _mf_old="$(git merge-base "$1" "$base_sha" 2>/dev/null)" || return 1
    [ -n "$_mf_old" ] || return 1
    for _mf_m in $(git rev-list --merges "$1..$2" "^$base_sha" 2>/dev/null); do
        _mf_p1="" _mf_p2="" _mf_p3=""
        read -r _mf_p1 _mf_p2 _mf_p3 <<EOF
$(git rev-list --parents -n 1 "$_mf_m" 2>/dev/null | cut -d' ' -f2-)
EOF
        [ -n "$_mf_p2" ] && [ -z "$_mf_p3" ] || return 1
        git merge-base --is-ancestor "$1" "$_mf_p1" 2>/dev/null || return 1
        ! git merge-base --is-ancestor "$_mf_p1" "$base_sha" 2>/dev/null || return 1
        git merge-base --is-ancestor "$_mf_p2" "$base_sha" 2>/dev/null || return 1
        [ "$_mf_p2" != "$_mf_old" ] || return 1
        git merge-base --is-ancestor "$_mf_old" "$_mf_p2" 2>/dev/null || return 1
    done
    [ -n "$(git merge-base "$2" "$base_sha" 2>/dev/null)" ]
}
# increment_of <R> <H>: L is R, or with a merge of the base in R..H a fixed-identity
# commit wrapping T, the pinned merge-tree of R with B (the base point H holds),
# so git diff L H never holds the base's merged content. Sets inc_l, inc_b,
# inc_t, inc_merge, inc_mt_out, inc_mt_rc, inc_empty and inc_size (empty when
# unknown); fails when there is no increment. .delta and .free record R, not L.
increment_of() {
    rr_phase increment
    inc_l="" inc_b="" inc_t="" inc_merge=0 inc_mt_out="" inc_mt_rc=0 inc_empty=0 inc_size=""
    git merge-base --is-ancestor "$1" "$2" 2>/dev/null || return 1
    if [ -n "$base_sha" ]; then
        _io_m="$(git rev-list --merges "$1..$2" "^$base_sha" 2>/dev/null)" || return 1
        [ -z "$_io_m" ] || inc_merge=1
    fi
    if [ "$inc_merge" -eq 1 ]; then
        inc_b="$(git merge-base "$2" "$base_sha" 2>/dev/null)" && [ -n "$inc_b" ] || return 1
        # The merge reads no gitattributes (merge drivers, marker sizes): an
        # empty attribute tree, no global or system file. info/attributes has no
        # off switch, so with a non-empty one there is no trusted increment base
        # and no increment: the caller reviews the whole PR or refuses.
        _io_empty="$(git hash-object -t tree /dev/null 2>&1)" || { printf 'review-round: empty tree hash failed: %s\n' "$_io_empty" >&2; return 1; }
        case "$_io_empty" in ''|*[!0-9a-f]*) printf 'review-round: empty tree hash unreadable: %s\n' "$_io_empty" >&2; return 1 ;; esac
        _io_info="$(git rev-parse --git-path info/attributes 2>&1)" || { printf 'review-round: info/attributes path failed: %s\n' "$_io_info" >&2; return 1; }
        _io_tab="$(printf '\t')"
        if [ -e "$_io_info" ] && { [ ! -f "$_io_info" ] || LC_ALL=C grep -qv "^[ $_io_tab]*\(#.*\)\{0,1\}\$" "$_io_info"; }; then
            printf 'review-round: %s sets attributes, so no trusted increment base exists\n' "$_io_info" >&2
            return 1
        fi
        _io_drv="$(git config --get-regexp '^merge\..*\.driver$' 2>&1)"
        case "$?" in
            1) ;;
            0) printf 'review-round: a merge driver is configured, so no trusted increment base exists\n' >&2; return 1 ;;
            *) printf 'review-round: reading merge drivers failed: %s\n' "$_io_drv" >&2; return 1 ;;
        esac
        inc_mt_out="$(GIT_ATTR_NOSYSTEM=1 git -c core.attributesFile=/dev/null -c merge.conflictStyle=merge -c merge.default=text --attr-source="$_io_empty" \
            merge-tree --write-tree --name-only --no-messages "$1" "$inc_b" 2>/dev/null)"
        inc_mt_rc=$?
        [ "$inc_mt_rc" -eq 0 ] || [ "$inc_mt_rc" -eq 1 ] || return 1
        inc_t="$(printf '%s\n' "$inc_mt_out" | sed -n '1p')"
        [ -n "$inc_t" ] || return 1
        inc_l="$(GIT_AUTHOR_NAME=review-round GIT_AUTHOR_EMAIL=review-round@invalid GIT_AUTHOR_DATE=2000-01-01T00:00:00Z \
            GIT_COMMITTER_NAME=review-round GIT_COMMITTER_EMAIL=review-round@invalid GIT_COMMITTER_DATE=2000-01-01T00:00:00Z \
            git -c i18n.commitEncoding=UTF-8 commit-tree --no-gpg-sign "$inc_t" -p "$1" -p "$inc_b" -m 'review-round increment base' 2>/dev/null)" \
            && [ -n "$inc_l" ] || return 1
    else
        inc_l="$(git rev-parse --verify --quiet "$1^{commit}" 2>/dev/null)" && [ -n "$inc_l" ] || return 1
    fi
    _io_rc=0
    git diff --quiet "$inc_l" "$2" 2>/dev/null || _io_rc=$?
    case "$_io_rc" in 0) inc_empty=1 ;; 1) ;; *) return 1 ;; esac
    _io_num="$(git diff --numstat --no-renames "$inc_l" "$2" 2>/dev/null)" || return 1
    inc_size="$(printf '%s\n' "$_io_num" | awk '$1 == "-" || $2 == "-" { bad = 1 } NF { n += $1 + $2 } END { if (!bad) print n + 0 }')"
}

inc_no_markers() {
    [ "$inc_mt_rc" -eq 0 ] && return 0
    while IFS= read -r _nm_p; do
        [ -n "$_nm_p" ] || continue
        git cat-file -e "$inc_t:$_nm_p" 2>/dev/null || return 1
        _nm_rc=0
        git --literal-pathspecs grep -qE '^(<{7,}( |$)|={7,}$|>{7,}( |$)|[|]{7,}( |$))' "$inc_t" -- "$_nm_p" >/dev/null 2>&1 || _nm_rc=$?
        [ "$_nm_rc" -eq 1 ] || return 1
    done <<EOF
$(printf '%s\n' "$inc_mt_out" | sed '1d')
EOF
    return 0
}

inc_resolution_only() {
    _ro_paths="$(git -c core.quotepath=off diff --numstat --no-renames "$inc_l" "$1" 2>/dev/null)" || return 1
    [ -n "$_ro_paths" ] || return 1
    _ro_conf="$(printf '%s\n' "$inc_mt_out" | sed '1d')"
    _ro_tab="$(printf '\t')"
    while IFS="$_ro_tab" read -r _ro_a _ro_d _ro_p; do
        [ -n "$_ro_p" ] || return 1
        case "$_ro_a$_ro_d" in *[!0-9]*) return 1 ;; esac
        ! plugin_json_path "$_ro_p" || return 1
        case "
$_ro_conf
" in *"
$_ro_p
"*) ;; *) return 1 ;; esac
        _ro_sum="$(git diff --no-renames --summary "$inc_l" "$1" -- "$_ro_p" 2>/dev/null)" || return 1
        [ -z "$_ro_sum" ] || return 1
        _ro_spans="$(git cat-file blob "$inc_t:$_ro_p" 2>/dev/null | awk '/^<<<<<<< / { s = NR } /^>>>>>>> / { if (s) print s, NR; s = 0 }')" || return 1
        [ -n "$_ro_spans" ] || return 1
        _ro_hunks="$(git diff -U0 --no-color --no-ext-diff --no-textconv --no-renames "$inc_l" "$1" -- "$_ro_p" 2>/dev/null | sed -n 's/^@@ -\([0-9][0-9]*\)\(,\([0-9][0-9]*\)\)\{0,1\} .*/\1 \3/p')" || return 1
        [ -n "$_ro_hunks" ] || return 1
        SPANS="$_ro_spans" awk '
            BEGIN { n = split(ENVIRON["SPANS"], v, /[ \n]/); for (i = 1; i + 1 <= n; i += 2) { s[++k] = v[i] + 0; e[k] = v[i + 1] + 0 } }
            { a = $1 + 0; c = ($2 == "") ? 1 : $2 + 0; ok = 0
              for (j = 1; j <= k; j++) {
                  if (c == 0 && s[j] <= a && a < e[j]) ok = 1
                  if (c > 0 && s[j] <= a && a + c - 1 <= e[j]) ok = 1
              }
              if (!ok) bad = 1 }
            END { exit bad ? 1 : 0 }' <<EOF_HUNKS || return 1
$_ro_hunks
EOF_HUNKS
    done <<EOF
$_ro_paths
EOF
    return 0
}

free_cap=5
free_size_cap=80
finding_heads() {
    printf '%s\n' "$1"
    { [ -f "$free_state" ] && [ ! -L "$free_state" ]; } || return 0
    _fh_cur="$1" _fh_n=0
    while [ "$_fh_n" -lt "$free_cap" ]; do
        _fh_prev="$(awk -v c="$_fh_cur" '$2 == c { p = $1 } END { if (p != "") print p }' "$free_state")" || return 0
        { [ -n "$_fh_prev" ] && [ "$_fh_prev" != "$_fh_cur" ]; } || return 0
        printf '%s\n' "$_fh_prev"
        _fh_cur="$_fh_prev"
        _fh_n=$((_fh_n + 1))
    done
}
free_reaches() {
    _fr_hit="$(finding_heads "$1" | awk -v d="$2" '$0 == d { print "y"; exit }')" || return 1
    [ "$_fr_hit" = y ]
}
increment_touches_only_open_finding_files() {
    _fx_files=""
    while IFS= read -r _fx_h; do
        [ -n "$_fx_h" ] || continue
        _fx_f="$(ledger_query findfiles "$_fx_h")" || return 1
        [ -z "$_fx_f" ] || _fx_files="$_fx_files
$_fx_f"
    done <<EOF
$(finding_heads "$1")
EOF
    [ -n "$_fx_files" ] || return 1
    _fx_paths="$(git -c core.quotepath=off diff --no-renames --name-only "$inc_l" "$2")" || return 1
    [ -n "$_fx_paths" ] || return 1
    _fx_cited=0
    while IFS= read -r _fx_p; do
        [ -n "$_fx_p" ] || continue
        if test_path_p "$_fx_p"; then continue; fi
        case "
$_fx_files
" in
            *"
$_fx_p
"*) _fx_cited=1 ;;
            *) return 1 ;;
        esac
    done <<EOF
$_fx_paths
EOF
    [ "$_fx_cited" -eq 1 ]
}
# increment_class <R> <H>: sets inc_class to carried, tests, comments, merge-resolution, fix or
# work; a free class needs a non-empty increment of known size at most
# free_size_cap and fewer than free_cap free rounds (free_count).
increment_class() {
    if [ "$inc_merge" -eq 1 ] && [ "$inc_empty" -eq 1 ] && inc_no_markers; then
        inc_class=carried
        return 0
    fi
    inc_class=work
    [ "$inc_empty" -eq 0 ] && [ -n "$inc_size" ] && [ "$inc_size" -le "$free_size_cap" ] \
        && [ "${free_count:-$free_cap}" -lt "$free_cap" ] || return 0
    if tests_only_paths "$inc_l" "$2"; then
        inc_class=tests
    elif comment_only_diff "$inc_l" "$2"; then
        inc_class=comments
    elif [ "$inc_merge" -eq 1 ] && merge_forward_shape "$1" "$2" \
        && { inc_resolution_only "$2" || version_only_merge "$1" "$inc_b" "$2" "$inc_mt_out" "$inc_mt_rc"; }; then
        inc_class=merge-resolution
    elif increment_touches_only_open_finding_files "$1" "$2"; then
        inc_class=fix
    fi
    return 0
}

clean_merge_forward() {
    increment_of "$1" "$2" || return 1
    [ "$inc_merge" -eq 1 ] && [ "$inc_empty" -eq 1 ] && inc_no_markers
}

verb="${1:-}"
[ -n "$verb" ] || usage
shift
rr_args=("$@")
# read-only, writes no state, so it needs no --branch: the answer
# is a pure function of the two commits in cwd's repository.
if [ "$verb" = "trivial-descendant" ]; then
    _td_tests_only=0
    if [ "${1:-}" = "--tests-only" ]; then _td_tests_only=1; shift; fi
    [ $# -eq 2 ] || usage
    trivial_descendant "$1" "$2"
    exit $?
fi
if [ "$verb" = "clean-merge-forward" ]; then
    [ $# -eq 3 ] && [[ "$1" =~ ^[0-9a-f]{40}$ ]] || usage
    git cat-file -e "$1^{commit}" 2>/dev/null || exit 1
    base_sha="$1"
    clean_merge_forward "$2" "$3"
    exit $?
fi
branch=""
pr=""
head_sha=""
base_sha=""
defer_to="${CR_DEFER_TO:-}"
fu_why_arg=""
fu_override_arg=""
threads_ok=""
check_only=0
full_arg=0
while [ $# -gt 0 ]; do
    case "$1" in
        --check) check_only=1; shift ;;
        --full) full_arg=1; shift ;;
        --open-threads-ok) [ $# -ge 2 ] && [ -n "$2" ] || usage; threads_ok="$2"; shift 2 ;;
        --branch) [ $# -ge 2 ] || usage; branch="$2"; shift 2 ;;
        --pr) [ $# -ge 2 ] || usage; pr="$2"; shift 2 ;;
        --head) [ $# -ge 2 ] || usage; head_sha="$2"; shift 2 ;;
        --base-sha) [ $# -ge 2 ] || usage; base_sha="$2"; shift 2 ;;
        --defer-to) [ $# -ge 2 ] || usage; defer_to="$2"; shift 2 ;;
        --fu-why) [ $# -ge 2 ] || usage; fu_why_arg="$2"; shift 2 ;;
        --fu-override) [ $# -ge 2 ] || usage; fu_override_arg="$2"; shift 2 ;;
        *) usage ;;
    esac
done
# --pr keys the state on outside-<n>, so it never takes --branch, and only start, check
# (read only) and abort accept it. Its head is a full sha, and the PR number a plain integer.
if [ -n "$pr" ]; then
    [ -z "$branch" ] && [ "$check_only" -eq 0 ] || usage
    case "$verb" in start|check|abort) ;; *) usage ;; esac
    [[ "$pr" =~ ^[1-9][0-9]{0,8}$ ]] && [[ "$head_sha" =~ ^[0-9a-f]{40}$ ]] || usage
    branch="outside-$pr"
fi
[ -n "$branch" ] || usage
[ "$check_only" -eq 0 ] || [ "$verb" = "promote" ] || usage
[ -z "$threads_ok" ] || [ "$verb" = "judge-go" ] || usage
[ "$full_arg" -eq 0 ] || { [ "$verb" = "start" ] && [ -z "$pr" ]; } || usage
case "$verb" in
    check) [ -n "$pr" ] || usage ;;
    start) [ -n "$head_sha" ] || [ -z "$base_sha" ] || usage ;;
    defer) [ -n "$head_sha" ] || usage ;;
    promote) [ -n "$head_sha" ] || usage ;;
    judge-go) [ -n "$head_sha" ] || usage ;;
    evidence) [ -n "$head_sha" ] || usage ;;
    abort) [ -n "$head_sha" ] || usage ;;
    settle) [ -n "$head_sha" ] && [ -z "$base_sha" ] || usage ;;
    *) usage ;;
esac

if [ "$verb" = "start" ] && [ "${_RR_START_INNER:-}" = 1 ]; then
    rr_c="${_RR_START_CALLER:-}"
    rr_phase_file="${_RR_START_PHASE:-}"
    unset _RR_START_INNER _RR_START_CALLER _RR_START_PHASE
    # swallow-ok: a failed ps read cannot confirm the caller, and the body then exits 5
    rr_pp="$(ps -o ppid= -p "$PPID" 2>/dev/null)" || rr_pp=""
    rr_pp="${rr_pp//[[:space:]]/}"
    if [ -n "$rr_c" ] && [ "$rr_pp" = "$rr_c" ]; then
        rr_caller="$rr_c"
    else
        echo "review-round: cannot confirm the caller of start" >&2
        exit 5
    fi
elif [ "$verb" = "start" ]; then
    rr_start_outer
fi

if ! git check-ref-format --branch "$branch" >/dev/null 2>&1; then
    echo "review-round: invalid branch name '$branch'" >&2
    exit 2
fi
# Every verb writes shared per-branch state (round counter,
# ledger amends, marker clearance), and a relative run is auto-allowed from any
# worker's worktree - so only the branch checked out in cwd may be written. A
# detached HEAD has no branch and is refused too.
current_branch="$(git branch --show-current 2>/dev/null)" || current_branch=""
# promote --check writes nothing, so it may read a branch this directory does not hold.
# --pr names no branch of ours: the PR's head lives in its own state key.
if [ "$check_only" -eq 0 ] && [ -z "$pr" ] && { [ -z "$current_branch" ] || [ "$current_branch" != "$branch" ]; }; then
    echo "review-round: --branch '$branch' is not the branch checked out in this directory ('${current_branch:-detached HEAD}') - run it from that branch's worktree" >&2
    exit 2
fi

# --base-sha is caller input and every merge-forward and CI-red
# measure below trusts it, so it is verified once, here, before any consumer
# reads it. No local ref names or vouches for the base: the default branch name
# is read from the remote (gh api repos/{owner}/{repo}) and the remote compare
# <sha>...<default> must report identical or ahead. The value must be a full
# 40-hex sha and, once verified, base_sha is reassigned to the resolved commit so
# no consumer re-resolves the caller string. Offline, no gh, an unreadable
# answer or any other status refuses EVERY --base-sha round (exit 8, fail closed).
if [ -n "$base_sha" ]; then
    rr_phase verify-base
    # shellcheck source=scripts/lib/timeout-bin.sh
    # shellcheck disable=SC1091
    . "$HIMMEL_ROOT/scripts/lib/timeout-bin.sh" 2>/dev/null || _TIMEOUT_BIN=""
    # Only a full sha is a stable name: a ref or short sha would be re-resolved
    # by every consumer below, and a racing update-ref could retarget them after
    # this check passed.
    case "$base_sha" in
        *[!0-9a-f]*|'')
            echo "review-round: --base-sha '$base_sha' must be exactly 40 lowercase hex chars - refused" >&2
            exit 8 ;;
    esac
    if [ "${#base_sha}" -ne 40 ]; then
        echo "review-round: --base-sha '$base_sha' must be exactly 40 lowercase hex chars - refused" >&2
        exit 8
    fi
    _vb_got="$(git rev-parse --verify --quiet "$base_sha^{commit}" 2>/dev/null)" || _vb_got=""
    _vb_def="$(${_TIMEOUT_BIN:+"$_TIMEOUT_BIN" -k 5 30} "${_RR_GH[@]}" api "repos/{owner}/{repo}" --jq .default_branch 2>/dev/null)" || _vb_def=""
    case "$_vb_def" in
        ''|*[!A-Za-z0-9._/-]*) _vb_def="" ;;
    esac
    if [ -z "$_vb_got" ] || [ -z "$_vb_def" ] || ! git check-ref-format --branch "$_vb_def" >/dev/null 2>&1; then
        echo "review-round: --base-sha '$base_sha' cannot be verified (unresolvable commit or unreadable remote default branch) - refused" >&2
        exit 8
    fi
    _vb_status="$(${_TIMEOUT_BIN:+"$_TIMEOUT_BIN" -k 5 30} "${_RR_GH[@]}" api "repos/{owner}/{repo}/compare/$_vb_got...$_vb_def" --jq .status 2>/dev/null)" || _vb_status=""
    case "$_vb_status" in
        identical|ahead) base_sha="$_vb_got" ;;
        *)
            echo "review-round: --base-sha $_vb_got is not on the remote $_vb_def history (gh compare says '${_vb_status:-unreadable}') - refused" >&2
            exit 8 ;;
    esac
fi

git_dir="$(git rev-parse --git-common-dir 2>/dev/null)" || git_dir=""
if [ -z "$git_dir" ]; then
    echo "review-round: cannot resolve the shared git common directory" >&2
    exit 5
fi
state="$git_dir/cr-review-rounds/$branch.round"
# "<from> <to> <trigger>" of the one delta round, once it ran.
delta_state="$git_dir/cr-review-rounds/$branch.delta"
# The pid of the caller of the last counted round's start.
delta_run="$git_dir/cr-review-rounds/$branch.delta.run"
# "<from> <to> <qid>/<name>", one line per judge-triggered round.
verdict_state="$git_dir/cr-review-rounds/$branch.verdicts"
# The head the last counted round ran on (start --head).
head_state="$git_dir/cr-review-rounds/$branch.head"
# The last critic-reviewed head start replaced in .head.
prev_state="$git_dir/cr-review-rounds/$branch.head.prev"
# "<from> <to> <failing check names>" once the CI-red unlock was used.
cired_state="$git_dir/cr-review-rounds/$branch.cired"
# One line: the key of the branch's batch residual, filed by the first early
# close and reused by every later one. It lives as long as the round count.
deferred_to_state="$git_dir/cr-review-rounds/$branch.deferred-to"
free_state="$git_dir/cr-review-rounds/$branch.free"
scope_state="$git_dir/cr-review-rounds/$branch.scope"
snap_state="$git_dir/cr-review-rounds/$branch.start.bak"
snap_wait=7200
state_dir="$(dirname "$state")"
mkdir -p "$state_dir" || {
    echo "review-round: cannot create state directory $state_dir" >&2
    exit 5
}

read_round() {
    round=0
    if [ -f "$state" ]; then
        round="$(cat "$state" 2>/dev/null)" || round=""
        case "$round" in
            ''|*[!0-9]*)
                echo "review-round: invalid counter state in $state — refusing to reset it silently" >&2
                return 5
                ;;
        esac
    fi
    return 0
}

# ledger_query <avail|finding|findfiles|allfixed|row|seen> <full sha> reads only critic-panel
# rows on this branch at that sha (full or >=7-char prefix); claude,
# claude-floor and codex-adv rows are the session's own and never count (the
# clear-cr-marker gate 3b exclusion). "avail" prints "ok" when a critic
# reviewed the sha. "finding" prints "finding" when a critic finding there
# still asks for a fix: its verdict after amends is agreed, fixed or unset,
# and no row ever deferred or disproved it. "row" prints "row"
# when any critic finding row exists there, whatever its verdict. "seen"
# prints "seen" when any avail or finding row of any model exists there.
ledger_query() {
    LEDGER="$git_dir/cr-critic-scores.jsonl" BRANCH="$branch" MATCH_ANY_BRANCH="${pr:+1}" MODE="$1" FROM="$2" AMEND_AUTH="$SCRIPT_DIR/ledger-amend-auth.js" node -e '
const fs = require("fs"), e = process.env;
let lines = [];
try { lines = fs.readFileSync(e.LEDGER, "utf8").split("\n").filter(Boolean); } catch (err) { process.exit(err.code === "ENOENT" ? 0 : 2); }
const at = (h) => { h = String(h || "").toLowerCase(); return h.length >= 7 && e.FROM.startsWith(h); };
const critic = (m) => m !== "claude" && m !== "claude-floor" && m !== "codex-adv";
let reviewed = false, rowed = false, seen = false;
const verdicts = new Map(), settled = new Set(), files = new Map();
// One finding is id + artifact + perspective, as the defer
// analysis and clear-cr-marker key it; a bare id merges distinct findings.
const keyOf = (o) => [String(o.finding_id), o.artifact || "diff", o.perspective || "off"].join("\u001f");
const note = (id, v) => {
  verdicts.set(id, v);
  if (v === "deferred" || v === "disproved") settled.add(id);
};
// Past the cutover only a signed lowering amend counts (ledger-amend-auth.js).
for (const line of require(e.AMEND_AUTH).filterLines(lines)) {
  let o;
  try { o = JSON.parse(line); } catch { continue; }
  if (!o || (e.MATCH_ANY_BRANCH !== "1" && o.branch !== e.BRANCH)) continue;
  if ((o.kind === "avail" || o.kind === "finding") && at(o.head)) seen = true;
  if (o.kind === "avail" && o.status === "ok" && critic(o.model) && at(o.head)) reviewed = true;
  if (o.kind === "finding" && critic(o.model) && at(o.head)) { rowed = true; note(keyOf(o), String(o.verdict || "")); files.set(keyOf(o), String(o.file || "")); }
  if (o.kind === "amend" && at(o.target_head) && verdicts.has(keyOf(o))
      && o.set && typeof o.set.verdict === "string") note(keyOf(o), o.set.verdict);
}
if (e.MODE === "avail") { if (reviewed) process.stdout.write("ok"); }
else if (e.MODE === "row") { if (rowed) process.stdout.write("row"); }
else if (e.MODE === "seen") { if (seen) process.stdout.write("seen"); }
else if (e.MODE === "allfixed") { if (rowed && [...verdicts.values()].every((v) => v === "fixed")) process.stdout.write("allfixed"); }
else if (e.MODE === "findfiles") { const out = new Set(); for (const [id, v] of verdicts) if (!settled.has(id) && (v === "" || v === "agreed" || v === "fixed") && files.get(id)) out.add(files.get(id)); if (out.size) process.stdout.write([...out].join("\n")); }
else if ([...verdicts].some(([id, v]) => !settled.has(id) && (v === "" || v === "agreed" || v === "fixed"))) process.stdout.write("finding");
'
}

# state_sha <file>: the commit a plain start-written state file names as a
# full sha on its first line, or nothing.
state_sha() {
    { [ -f "$1" ] && [ ! -L "$1" ]; } || return 1
    _ss="$(sed -n '1p' "$1")" || return 1
    case "$_ss" in *[!0-9a-f]*|'') return 1 ;; esac
    { [ "${#_ss}" -eq 40 ] || [ "${#_ss}" -eq 64 ]; } || return 1
    git rev-parse --verify --quiet "$_ss^{commit}" 2>/dev/null
}

# reviewed_head prints the newest critic-reviewed head start persisted: .head
# when a critic reviewed it; else, when the round on .head reviewed nothing
# (aborted, or no critic answered), the reviewed head that round's delta
# scoped from, else the last reviewed head start replaced (.head.prev). Only
# start-written records name a candidate, never a ledger row the session could
# append itself, and a missing .head stays fail-closed.
reviewed_head() {
    rr_phase reviewed-head
    _rh_head="$(state_sha "$head_state")" || return 1
    if [ "$(ledger_query avail "$_rh_head")" = "ok" ]; then
        printf '%s\n' "$_rh_head"
        return 0
    fi
    _rh_from="" _rh_to=""
    if [ -f "$delta_state" ] && [ ! -L "$delta_state" ]; then
        read -r _rh_from _rh_to _ < "$delta_state" 2>/dev/null || _rh_from=""
    fi
    if [ -n "$_rh_from" ] && [ "$_rh_to" = "$_rh_head" ] \
        && _rh_from="$(git rev-parse --verify --quiet "$_rh_from^{commit}")" \
        && [ "$(ledger_query avail "$_rh_from")" = "ok" ]; then
        printf '%s\n' "$_rh_from"
        return 0
    fi
    _rh_prev="$(state_sha "$prev_state")" || return 1
    [ "$(ledger_query avail "$_rh_prev")" = "ok" ] || return 1
    printf '%s\n' "$_rh_prev"
}

# counter_lock takes the review-counter lock start and abort write under and
# sets lock_owner; on failure it says why and returns 5.
counter_lock() {
    lock_lib="$HIMMEL_ROOT/scripts/lib/shared-branch-lock.sh"
    if [ ! -f "$lock_lib" ]; then
        echo "review-round: counter lock library is missing at $lock_lib" >&2
        return 5
    fi
    lock_out=$(SHARED_BRANCH_LOCK_NS=himmel-cr-review-round SHARED_BRANCH_LOCK_HOLDER_PID=$$ \
        bash "$lock_lib" acquire-wait "." "$branch" "review-round" 10 300 2>&1)
    lock_rc=$?
    [ -z "$lock_out" ] || printf '%s\n' "$lock_out" >&2
    if [ "$lock_rc" -ne 0 ]; then
        echo "review-round: cannot acquire the counter lock for $branch (rc=$lock_rc)" >&2
        return 5
    fi
    lock_owner=$(SHARED_BRANCH_LOCK_NS=himmel-cr-review-round \
        bash "$lock_lib" status "." "$branch" 2>/dev/null || true)
    # lock_owner is a single small JSON status line (well under the pipe
    # buffer), so printf's write completes atomically before grep could
    # exit early and SIGPIPE it.
    if ! printf '%s' "$lock_owner" | grep -q '^{"pid":'; then  # pipefail-ok: bounded small input, see comment above
        echo "review-round: counter lock holder state for $branch is missing or unreadable — refusing" >&2
        return 5
    fi
    return 0
}

snap_list=(round "$state" free "$free_state" scope "$scope_state" head "$head_state" prev "$prev_state" delta "$delta_state" cired "$cired_state" verdicts "$verdict_state")
snap_node() {
    node -e '
const fs = require("fs");
const [mode, ...a] = process.argv.slice(1);
const enc = (p) => { try { return "=" + fs.readFileSync(p).toString("base64"); } catch (err) { if (err.code === "ENOENT") return "absent"; throw err; } };
const parse = (p) => {
  const lines = fs.readFileSync(p, "utf8").split("\n");
  if (lines[0] !== "start-snapshot 1") throw new Error("not a snapshot");
  const s = { head: "", pid: "", time: "", continued: "0", answer: null, files: [] };
  for (const l of lines.slice(1)) {
    if (!l) continue;
    const sp = l.indexOf(" ");
    const k = sp < 0 ? l : l.slice(0, sp), v = sp < 0 ? "" : l.slice(sp + 1);
    if (k === "file") {
      const [n, b, af] = v.split(" ");
      if (!n || !b || !af) throw new Error("bad file line");
      s.files.push({ n, b, af });
    } else if (k in s && k !== "files") s[k] = v;
    else throw new Error("bad key");
  }
  if (!/^[0-9a-f]{40}([0-9a-f]{24})?$/.test(s.head) || !/^[0-9]+$/.test(s.time) || !/^[01]$/.test(s.continued) || !s.files.length) throw new Error("bad snapshot");
  return s;
};
const dump = (s) => ["start-snapshot 1", "head " + s.head, "pid " + s.pid, "time " + s.time, "continued " + s.continued]
  .concat(s.answer === null ? [] : ["answer " + s.answer])
  .concat(s.files.map((f) => ["file", f.n, f.b, f.af].join(" "))).join("\n") + "\n";
const list = (rest) => { const m = new Map(); for (let i = 0; i + 1 < rest.length; i += 2) m.set(rest[i], rest[i + 1]); return m; };
const at = (m, n) => { if (!m.has(n)) throw new Error("unknown file " + n); return m.get(n); };
const live = (fs_) => fs_.filter((f) => f.n !== "from");
try {
  if (mode === "before") {
    const [out, head, pid, time, ...rest] = a;
    const s = { head, pid, time, continued: "0", answer: null, files: [] };
    for (const [n, p] of list(rest)) s.files.push({ n, b: enc(p), af: "-" });
    fs.writeFileSync(out, dump(s), { flag: "wx" });
  } else if (mode === "after") {
    const [snap, out, answer, ...rest] = a;
    const s = parse(snap), m = list(rest);
    for (const f of s.files) f.af = enc(at(m, f.n));
    s.answer = answer;
    fs.writeFileSync(out, dump(s), { flag: "wx" });
  } else if (mode === "continue") {
    const [snap, out, pid] = a;
    const s = parse(snap);
    s.pid = pid; s.continued = "1";
    fs.writeFileSync(out, dump(s), { flag: "wx" });
  } else if (mode === "read") {
    const s = parse(a[0]);
    process.stdout.write([s.head, s.pid, s.time, s.continued, s.answer === null ? "0" : "1", s.answer || ""].join("\n") + "\n");
  } else if (mode === "check") {
    const [snap, ...rest] = a;
    const s = parse(snap), m = list(rest);
    let after = true, allowed = true;
    for (const f of live(s.files)) {
      const c = enc(at(m, f.n));
      if (c !== f.af) after = false;
      if (c !== f.af && c !== f.b) allowed = false;
    }
    process.stdout.write(after ? "after" : allowed ? "allowed" : "moved");
  } else if (mode === "restore") {
    const [snap, ...rest] = a;
    const s = parse(snap), m = list(rest);
    for (const f of live(s.files)) {
      const p = at(m, f.n);
      if (enc(p) === f.b) continue;
      if (f.b === "absent") { fs.rmSync(p, { force: true }); continue; }
      const tmp = p + ".tmp." + process.pid;
      fs.writeFileSync(tmp, Buffer.from(f.b.slice(1), "base64"));
      fs.renameSync(tmp, p);
    }
  } else process.exit(2);
} catch (err) { process.exit(3); }
' "$@"
}

snap_load() {
    { [ -e "$snap_state" ] || [ -L "$snap_state" ]; } || return 1
    { [ -f "$snap_state" ] && [ ! -L "$snap_state" ]; } || return 5
    _sl="$(snap_node read "$snap_state")" || return 5
    { read -r snap_head; read -r snap_pid; read -r snap_time; read -r snap_continued; read -r snap_complete; read -r snap_answer; } <<EOF
$_sl
EOF
    case "$snap_pid" in *[!0-9]*) snap_pid="" ;; esac
    return 0
}

snap_starter() {
    if [ -z "$snap_pid" ]; then echo unknown
    elif [ "$snap_pid" = "$rr_caller" ]; then echo caller
    elif kill -0 "$snap_pid" 2>/dev/null; then echo alive
    else echo ended
    fi
}

snap_young() {
    _sy_age=$(( $(date +%s) - snap_time ))
    [ "$_sy_age" -lt "$snap_wait" ] || return 1
    snap_left=$(( (snap_wait - _sy_age + 59) / 60 ))
}

snap_write() {
    _sw_tmp="$snap_state.tmp.$$"
    rm -f "$_sw_tmp"
    _sw_mode="$1"
    shift
    case "$_sw_mode" in
        before) snap_node before "$_sw_tmp" "$@" ;;
        *) snap_node "$_sw_mode" "$snap_state" "$_sw_tmp" "$@" ;;
    esac && mv "$_sw_tmp" "$snap_state" && return 0  # prim-ok: tmp-then-mv under the counter lock; fixture copies of this script have no scripts/lib
    rm -f "$_sw_tmp"
    return 5
}

restore_snapshot() {
    _rs="$(snap_node check "$snap_state" "${snap_list[@]}")" || return 5
    case "$_rs" in
        after|allowed)
            snap_node restore "$snap_state" "${snap_list[@]}" || return 5
            rm -f "$snap_state" || return 5
            return 0 ;;
        moved)
            echo "review-round: a round file on $branch changed after the round at $snap_head started (a grant), so that round stays counted and its snapshot is dropped" >&2
            rm -f "$snap_state" || return 5
            return 1 ;;
    esac
    return 5
}

# plugin-version-bump-required makes a plugin PR bump its
# plugin.json version inside its merge of the base, so that merge never equals
# a clean merge tree. version_only_merge <ours> <theirs> <new> <mt-out> <mt-rc> succeeds only
# when every path where <new>'s tree differs from the merge of <ours> and
# <theirs>, and every path that merge conflicts on, is a
# marketplace/plugins/<p>/.claude-plugin/plugin.json whose "version" in <new>
# is strictly above the version in both <ours> and <theirs>, and whose other
# bytes are exactly the clean three-way merge once the version values are set
# aside. Anything else fails, so the caller keeps refusing it.
version_only_merge() {
    _vo_out="$4" _vo_rc="$5"
    [ "$_vo_rc" -eq 0 ] || [ "$_vo_rc" -eq 1 ] || return 1
    _vo_tree="$(printf '%s\n' "$_vo_out" | sed -n '1p')"
    _vo_new_tree="$(git rev-parse --verify --quiet "$3^{tree}" 2>/dev/null)" || return 1
    _vo_changed="$(git diff-tree -r --name-only --no-renames "$_vo_tree" "$_vo_new_tree" 2>/dev/null)" || return 1
    _vo_paths="$( { printf '%s\n' "$_vo_out" | sed '1d'; printf '%s\n' "$_vo_changed"; } | sed '/^$/d' | sort -u)"
    [ -n "$_vo_paths" ] || return 1
    _vo_mb="$(git merge-base --all "$1" "$2" 2>/dev/null)" || return 1
    case "$_vo_mb" in ''|*"
"*) return 1 ;; esac
    _vo_tmp="$(mktemp -d "${TMPDIR:-/tmp}/review-round.XXXXXX")" || return 1  # prim-ok: test-pr-check-rounds and test-panel-first-pass run fixture copies of this script with no scripts/lib
    _vo_ok=0
    while IFS= read -r _vo_p; do
        _vo_ok=1
        plugin_json_path "$_vo_p" || { _vo_ok=0; break; }
        for _vo_side in "$_vo_mb:base" "$1:ours" "$2:theirs" "$3:new"; do
            _vo_c="${_vo_side%:*}"
            if [ "${_vo_side##*:}" != base ] \
                && [ "$(git ls-tree "$_vo_c" -- "$_vo_p" 2>/dev/null | cut -c1-6)" != "100644" ]; then
                _vo_ok=0; break
            fi
            git cat-file blob "$_vo_c:$_vo_p" > "$_vo_tmp/${_vo_side##*:}" 2>/dev/null || { _vo_ok=0; break; }
            plugin_version "$_vo_tmp/${_vo_side##*:}" > "$_vo_tmp/${_vo_side##*:}.v" || { _vo_ok=0; break; }
            sed -E 's/^([[:space:]]*"version"[[:space:]]*:[[:space:]]*")[0-9.]*"/\1"/' \
                "$_vo_tmp/${_vo_side##*:}" > "$_vo_tmp/${_vo_side##*:}.n" || { _vo_ok=0; break; }
        done
        [ "$_vo_ok" -eq 1 ] || break
        _vo_vn="$(cat "$_vo_tmp/new.v")"
        if ! semver_gt "$_vo_vn" "$(cat "$_vo_tmp/ours.v")" \
            || ! semver_gt "$_vo_vn" "$(cat "$_vo_tmp/theirs.v")" \
            || ! git merge-file -p "$_vo_tmp/ours.n" "$_vo_tmp/base.n" "$_vo_tmp/theirs.n" > "$_vo_tmp/merged.n" 2>/dev/null \
            || ! cmp -s "$_vo_tmp/merged.n" "$_vo_tmp/new.n"; then
            _vo_ok=0; break
        fi
    done <<EOF
$_vo_paths
EOF
    rm -rf "$_vo_tmp"
    [ "$_vo_ok" -eq 1 ]
}

# A branch is one PR. Its consumed qids plus the candidate
# qid are its verdict history, not every other PR in the verdict scope.
# Legacy classless records contribute no classes. A decision in the current
# candidate evidence is the explicit way out of a repeated-class stop.
# shellcheck disable=SC2016  # JavaScript template fields are literal here
judge_class_check() {
    VERDICT_DIR="$5" HISTORY="$verdict_state" CANDIDATE="$1" WANT="$2" SIGNED="$3" ALT="${4:-}" node -e '
const fs = require("fs"), path = require("path"), cp = require("child_process"), crypto = require("crypto"), e = process.env;
// A layer-decision counts only from a record whose mac verified; the
// bash side hands over qid/name:sha256 of the bytes it verified, and the record
// read here must hash to the same bytes (no window between verify and read).
const signed = new Set((e.SIGNED || "").split(" ").filter(Boolean));
const allowed = new Set(["option-parsing", "cwd-indirection", "shell-parsing", "tool-defaults", "reader-allowlist", "other"]);
const seg = /^[A-Za-z0-9][A-Za-z0-9._-]*$/;
const candidates = e.CANDIDATE.split(" ").map(r => r.split("/")[0]);
const records = (qid) => {
  const dir = path.join(e.VERDICT_DIR, qid);
  if (!seg.test(qid) || !fs.lstatSync(dir).isDirectory() || fs.lstatSync(dir).isSymbolicLink()) throw Error("invalid history qid " + qid);
  return fs.readdirSync(dir).filter(n => n.endsWith(".md")).map(n => {
    const file = path.join(dir, n), name = n.slice(0, -3);
    const stat = fs.lstatSync(file);
    if (!stat.isFile() || stat.isSymbolicLink()) throw Error("invalid history file " + file);
    const bytes = fs.readFileSync(file);
    const lines = bytes.toString("utf8").split("\n");
    const isSigned = signed.has(`${qid}/${name}:${crypto.createHash("sha256").update(bytes).digest("hex")}`);
    if (!seg.test(name) || lines[0] !== `# VERDICT ${qid} - ${name}` || lines[1] || lines[4] || lines[6]
        || !/^writer-session: [A-Za-z0-9-]+$/.test(lines[2])
        || !/^written-at: \d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/.test(lines[3]) || lines[5] !== "## Verdict") throw Error("invalid history record " + file);
    const verdict = /^\*\*(GO|NO-GO)\*\* for head `([0-9a-f]{40})`\.?$/.exec(lines[7]);
    if (!verdict) throw Error("invalid history verdict " + file);
    const evidence = lines.slice(8);
    const fields = evidence.filter(l => l.startsWith("class:"));
    let classes = [];
    if (verdict[1] === "NO-GO" && fields.length) {
      classes = fields[0].slice(6).trim().split(",").map(s => s.trim());
      if (fields.length !== 1 || classes.some(c => !allowed.has(c))) throw Error("invalid history class " + file);
    }
    return { head: verdict[2], nogo: verdict[1] === "NO-GO", classes,
      // A layer-decision line that lacks the layer keyword is not honoured; say so.
      malformed: evidence.some(l => /^layer-decision:/.test(l) && !/^layer-decision: (text|os|classifier|accept)\s+\S.*$/.test(l)),
      decision: isSigned && evidence.some(l => /^layer-decision: (text|os|classifier|accept)\s+\S.*$/.test(l)) };
  });
};
try {
  const candidateRecords = candidates.flatMap(records);
  // A NO-GO on a test- or comment-only descendant counts as bound to WANT.
  const alt = new Set((e.ALT || "").split(" ").filter(Boolean));
  const current = candidateRecords.filter(r => r.nogo && (r.head === e.WANT || alt.has(r.head)));
  if (current.some(r => r.decision)) process.exit(0);
  const classes = new Set(current.flatMap(r => r.classes));
  const prior = [];
  let history = "";
  try { history = fs.readFileSync(e.HISTORY, "utf8"); } catch (err) { if (err.code !== "ENOENT") throw err; }
  for (const line of history.split("\n").filter(Boolean)) {
    const [head, , record] = line.split(" ");
    if (!record || !/^[0-9a-f]{40}$/.test(head)) throw Error("invalid consumed verdict history");
    if (head !== e.WANT) prior.push(...records(record.split("/")[0]).filter(r => r.nogo && r.head === head));
  }
  for (const r of candidateRecords) {
    if (!r.nogo || r.head === e.WANT || alt.has(r.head)) continue;
    // Only a clean exit 1 means "not an ancestor"; a git error
    // (128: missing or shallow history), a spawn error or a signal keeps the
    // record, so an unreadable history never drops an earlier NO-GO.
    const anc = cp.spawnSync("git", ["merge-base", "--is-ancestor", r.head, e.WANT]);
    if (anc.status === 1) continue;
    if (anc.status !== 0) console.error(`review-round: ancestry check could not run for ${r.head} (${anc.error ? anc.error.message : anc.signal || "git exit " + anc.status}) - keeping its NO-GO record`);
    prior.push(r);
  }
  const repeated = [...new Set(prior.flatMap(r => r.classes).filter(c => classes.has(c)))];
  if (repeated.length) {
    const lacks = current.some(r => r.malformed) ? " - a layer-decision line is present but lacks a layer keyword, so it is not honoured" : "";
    console.error(`review-round: repeated NO-GO class ${repeated.join(", ")} across heads of this PR - delta round refused; record layer-decision: text|os|classifier|accept <reason> in the candidate evidence${lacks}`);
    process.exit(8);
  }
} catch (err) {
  console.error("review-round: cannot read class history - delta round refused: " + err.message);
  process.exit(8);
}
'
}

# record_binds <l9> <l10> <l11> [prepr] - shared with the scope
# path. A record binds to this branch's PR: its `pr:` line (line 10,
# write-verdict.sh's fixed place) must name the PR gh resolves for the branch,
# and a `branch:` line (line 11, optional) must name the branch. No pr: line, or
# no resolvable PR, binds nothing. The binding only picks which records BUY the
# round: every NO-GO for the head still feeds the class veto, and an
# unresolvable PR (pr_want="-") refuses (exit 8) in the caller. The PR is
# resolved by --head, never `gh pr view <branch>` (a branch named 42 would
# resolve to PR 42), and bounded: this runs under the counter lock. pr_want
# caches it for the calling subshell, which must set it to "" first.
# With a fourth argument `prepr` (judge-go only) a record with no pr: line whose
# line 10 is `branch: <this branch>` also binds, but only while gh answers that
# the branch has no open PR (pr_none=1); a failed lookup or an open PR refuses
# it, so it never stands in for a PR-bound record.
record_binds() {
    [ -z "$1" ] || return 1
    _rb_branch_form=0
    case "$2" in
        'pr: '[1-9]*) ;;
        'branch: '*) [ "${4:-}" = prepr ] && [ "${2#branch: }" = "$branch" ] || return 1
                     _rb_branch_form=1 ;;
        *) return 1 ;;
    esac
    if [ "$_rb_branch_form" -eq 0 ]; then
        case "${2#pr: }" in *[!0-9]*) return 1 ;; esac
        case "$3" in 'branch: '*) [ "${3#branch: }" = "$branch" ] || return 1 ;; esac
    fi
    if [ -z "$pr_want" ]; then
        # shellcheck source=scripts/lib/timeout-bin.sh
        # shellcheck disable=SC1091
        . "$HIMMEL_ROOT/scripts/lib/timeout-bin.sh" 2>/dev/null || _TIMEOUT_BIN=""
        _rb_rc=0
        pr_want="$(${_TIMEOUT_BIN:+"$_TIMEOUT_BIN" -k 5 30} "${_RR_GH[@]}" pr list --head "$branch" --state open \
            --json number -q '.[].number' 2>/dev/null)" || _rb_rc=1
        if [ "$_rb_rc" -ne 0 ]; then pr_want=""; fi
        if [ "$_rb_rc" -eq 0 ] && [ -z "$pr_want" ]; then pr_none=1; fi
        case "$pr_want" in ''|0*|*[!0-9]*)
            if [ "$_rb_branch_form" -eq 0 ] || [ -z "${pr_none:-}" ]; then
                echo "review-round: cannot resolve the one open PR for $branch (gh pr list --head) - no judge record is honoured" >&2
            fi
            pr_want="-" ;;
        esac
    fi
    if [ "$_rb_branch_form" -eq 1 ]; then
        [ -n "${pr_none:-}" ]
        return
    fi
    [ "${2#pr: }" = "$pr_want" ]
}

# pr_repo_nwo prints the owner/name of the origin remote of the current
# directory, taken as the repo the branch's PR lives in, when that is not the
# harness's own repo (HIMMEL_ROOT's origin), so go_verdict_scope reads an
# adopter's bucket (write-verdict.sh --repo writes it). gh does not always
# resolve the PR against origin (a gh default repo, an upstream remote); this
# does not follow it. Prints nothing for the harness's own repo or an origin it
# cannot read as owner/name: that is today's one-argument scope.
pr_repo_nwo() {
    local LC_ALL=C pr_nwo own_nwo
    pr_nwo="$(_origin_nwo .)" && [ -n "$pr_nwo" ] || return 0
    own_nwo="$(_origin_nwo "$HIMMEL_ROOT")" || own_nwo=""
    [ "$(printf '%s' "$pr_nwo" | tr '[:upper:]' '[:lower:]')" != "$(printf '%s' "$own_nwo" | tr '[:upper:]' '[:lower:]')" ] || return 0
    printf '%s\n' "$pr_nwo"
}
_origin_nwo() {
    local url nwo
    url="$(git -C "$1" remote get-url origin 2>/dev/null)" || return 1
    nwo="$(printf '%s' "$url" | sed -nE 's#^(https?://([^/@]+@)?[^/]+/|ssh://([^/@]+@)?[^/]+/|[^/@:]+@[^/:]+:)([A-Za-z0-9._-]+/[A-Za-z0-9._-]+)$#\4#p')"
    printf '%s\n' "${nwo%.git}"
}

# shellcheck disable=SC2016  # JavaScript source is literal here
verdict_select() {
    VS_DIR="$1" VS_WANT="$2" VS_MODE="$3" node -e '
const fs = require("fs"), path = require("path"), e = process.env;
const seg = /^[A-Za-z0-9][A-Za-z0-9._-]*$/;
const nogo = /^\*\*NO-GO\*\* for head `([0-9a-f]{40})`\.?$/;
const want = Buffer.from(e.VS_WANT || "");
let top;
try { top = fs.readdirSync(e.VS_DIR); } catch (_) { process.exit(2); }
const out = [];
let probe = "";
for (const q of top) {
  if (q.startsWith(".")) continue;
  const qdir = path.join(e.VS_DIR, q);
  let names;
  try {
    if (!fs.statSync(qdir).isDirectory()) continue;
    names = fs.readdirSync(qdir);
  } catch (_) { continue; }
  const plain = seg.test(q);
  let named = false;
  for (const n of names) {
    if (n.startsWith(".") || !n.endsWith(".md")) continue;
    const f = path.join(qdir, n);
    let buf;
    try {
      if (!fs.lstatSync(f).isFile()) { named = true; continue; }
      buf = fs.readFileSync(f);
    } catch (_) { named = true; continue; }
    if (buf.length === 0 || buf.includes(0)) { named = true; continue; }
    if (buf.includes(want)) named = true;
    if (e.VS_MODE === "nogo" && plain) {
      const l8 = buf.toString("latin1").split("\n")[7];
      const m = l8 === undefined ? null : nogo.exec(l8.replace(/\r/g, ""));
      if (m && m[1] !== e.VS_WANT) out.push("N " + q + " " + m[1]);
    }
    if (!probe && plain && seg.test(n.slice(0, -3))) probe = q + "/" + n;
  }
  if (named && plain) out.push("S " + q);
}
if (probe) out.push("P " + probe);
if (out.length) process.stdout.write(out.join("\n") + "\n");
'
}

verdict_sel_read() {
    sel="" vs_heads="" vs_probe=""
    while read -r vs_k vs_q vs_h; do
        case "$vs_k" in
            S) sel="$sel $vs_q" ;;
            N) case " $vs_heads " in *" $vs_h "*) ;; *) vs_heads="${vs_heads:+$vs_heads }$vs_h" ;; esac ;;
            P) vs_probe="$vs_q" ;;
        esac
    done <<EOF
$1
EOF
}

verdict_sel_descendants() {
    vs_crc=0
    [ -n "$vs_heads" ] || return 0
    vs_types="$(printf '%s\n' "$vs_heads" | tr ' ' '\n' | git cat-file --batch-check)" || vs_crc=$?
    [ "$vs_crc" -eq 0 ] || return 1
    vs_keep=""
    while read -r vs_sha vs_type _; do
        case "$vs_type" in
            commit|tag) git merge-base --is-ancestor "$1" "$vs_sha" 2>/dev/null && vs_keep="$vs_keep $vs_sha " ;;
        esac
    done <<EOF
$vs_types
EOF
    while read -r vs_k vs_q vs_h; do
        [ "$vs_k" = N ] || continue
        case "$vs_keep" in *" $vs_h "*) sel="$sel $vs_q" ;; esac
    done <<EOF
$2
EOF
}

# Print space-separated "<qid>/<name>" records ruling NO-GO for
# head $1 (one per qid), in chief-kit/write-verdict.sh format, under this repo's
# verdict scope; rc 1 when there is none. A qid counts only when every record
# in it parses, so a hand-written or edited file disqualifies its qid.
# A consumed qid buys no other round. A qid
# consumed on this branch still contributes current-head class vetoes.
# shellcheck disable=SC2016  # the backticks are the verdict line's literal text
judge_nogo_record() (
    rr_phase judge-nogo
    want="$1"
    lib="$HIMMEL_ROOT/scripts/lib"
    # shellcheck source=scripts/lib/handover-path.sh
    # shellcheck disable=SC1091
    . "$lib/handover-path.sh" 2>/dev/null || exit 1
    # Not followed: its function locals (head_sha) read as subshell writes (SC2031).
    # shellcheck source=/dev/null
    # shellcheck disable=SC1091
    . "$lib/go-gate.sh" 2>/dev/null || exit 1
    root="$(go_resolve_root "$HIMMEL_ROOT")" && [ -n "$root" ] || exit 1
    scope="$(go_verdict_scope "$HIMMEL_ROOT" "$(pr_repo_nwo)")" && [ -n "$scope" ] || exit 1
    dir="$root"
    [ -d "$dir" ] && [ ! -L "$dir" ] || exit 1
    for seg in "${scope%%/*}" "${scope#*/}" verdicts; do
        dir="$dir/$seg"
        [ -d "$dir" ] && [ ! -L "$dir" ] || exit 1
    done
    vs_out="$(verdict_select "$dir" "$want" nogo)"; vs_rc=$?
    if [ "$vs_rc" -ne 0 ]; then
        echo "review-round: verdict selection failed (rc $vs_rc) - the judge record is refused" >&2
        exit 8
    fi
    verdict_sel_read "$vs_out"
    if ! verdict_sel_descendants "$want" "$vs_out"; then
        echo "review-round: verdict selection failed (cat-file rc $vs_crc) - the judge record is refused" >&2
        exit 8
    fi
    if [ -d "$git_dir/cr-review-rounds" ]; then
        vs_scan=0
        grep -rqsF --include='*.verdicts' ' ./' "$git_dir/cr-review-rounds" 2>/dev/null || vs_scan=$?
        if [ "$vs_scan" -ne 1 ]; then
            echo "review-round: cannot scan $git_dir/cr-review-rounds (grep rc $vs_scan) - the judge record is refused" >&2
            exit 8
        fi
    fi
    if [ -e "$verdict_state" ] || [ -L "$verdict_state" ]; then
        vs_scan=0
        grep -qsF ' ./' "$verdict_state" 2>/dev/null || vs_scan=$?
        if [ "$vs_scan" -ne 1 ]; then
            echo "review-round: cannot read $verdict_state for class history - delta round refused" >&2
            exit 8
        fi
    fi
    if [ -n "$vs_probe" ] && ! go_verdict_snapshot "$dir/$vs_probe"; then
        echo "review-round: cannot snapshot a verdict record ($vs_probe) - the judge record is refused" >&2
        exit 8
    fi
    pr_want=""
    re_session='^writer-session: [A-Za-z0-9-]+$'
    re_written='^written-at: [0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$'
    hits="" check_hits="" signed="" alt=""
    for qdir in "$dir"/*/; do
        qdir="${qdir%/}"
        qid="${qdir##*/}"
        if [ ! -d "$qdir" ] || [ -L "$qdir" ]; then continue; fi
        case "$qid" in ''|[!A-Za-z0-9]*|*[!A-Za-z0-9._-]*) continue ;; esac
        case "$qid" in
            [ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789]*)
                case "$qid" in
                    *[!ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-]*) ;;
                    *) case " $sel " in *" $qid "*) ;; *) continue ;; esac ;;
                esac ;;
        esac
        # A qid consumed on any branch buys no other round, so
        # two branches sharing a last reviewed head cannot each spend it.
        # A scan that fails (rc 2) refuses the record - only rc 1
        # means "not consumed".
        consumed=0 bound=""
        if [ -d "$git_dir/cr-review-rounds" ]; then
            scan=0
            grep -rqsF --include='*.verdicts' " $qid/" "$git_dir/cr-review-rounds" 2>/dev/null || scan=$?
            if [ "$scan" -eq 0 ]; then
                consumed=1
                local_scan=1
                if [ -e "$verdict_state" ] || [ -L "$verdict_state" ]; then
                    local_scan=0
                    grep -qsF " $qid/" "$verdict_state" 2>/dev/null || local_scan=$?
                fi
                # intentional: class history is scoped to this branch's consumed qids plus current candidates; a qid consumed elsewhere and absent from verdict_state is skipped
                [ "$local_scan" -ne 1 ] || continue
                if [ "$local_scan" -ne 0 ]; then
                    echo "review-round: cannot read $verdict_state for class history - delta round refused" >&2
                    exit 8
                fi
            elif [ "$scan" -ne 1 ]; then
                echo "review-round: cannot scan $git_dir/cr-review-rounds for a consumed $qid (grep rc $scan) - the judge record is refused" >&2
                exit 1
            fi
        fi
        hit="" bad=0 macbad=0 snapfail=0
        for f in "$qdir"/*.md; do
            [ -e "$f" ] || [ -L "$f" ] || continue
            if [ -L "$f" ] || [ ! -f "$f" ]; then bad=1; break; fi
            name="${f##*/}"; name="${name%.md}"
            case "$name" in ''|[!A-Za-z0-9]*|*[!A-Za-z0-9._-]*) bad=1; break ;; esac
            # One read; the mac and every field come from this copy.
            # A record that cannot be read whole may be a NO-GO: its qid stays in
            # the class history (the class check then fails closed on it).
            if ! go_verdict_snapshot "$f"; then snapfail=1; bad=1; break; fi
            snap=$GO_VERDICT_SNAP
            l1="" l2="" l3="" l4="" l5="" l6="" l7="" l8="" l9="" l10="" l11=""
            { IFS= read -r l1; IFS= read -r l2; IFS= read -r l3; IFS= read -r l4
              IFS= read -r l5; IFS= read -r l6; IFS= read -r l7; IFS= read -r l8
              IFS= read -r l9; IFS= read -r l10; IFS= read -r l11; } <<EOF_SNAP 2>/dev/null
$snap
EOF_SNAP
            if [ "$l1" != "# VERDICT $qid - $name" ] || [ -n "$l2$l5$l7" ] || [ "$l6" != "## Verdict" ] \
                || ! [[ $l3 =~ $re_session ]] || ! [[ $l4 =~ $re_written ]]; then
                bad=1; break
            fi
            word="$(printf '%s\n' "$l8" | sed -nE 's/^\*\*(GO|NO-GO)\*\* for head `([0-9a-f]{40})`\.?$/\1 \2/p')"
            [ -n "$word" ] || { bad=1; break; }
            # A record buys a round only when write-verdict.sh signed
            # it; one hand-written or edited withholds the round from its qid, but
            # its NO-GO still feeds the class veto (a NO-GO only narrows).
            mac_ok=0
            if go_verdict_mac_ok_text "$snap" "$scope" "$qid" "$name"; then mac_ok=1; else macbad=1; fi
            # A NO-GO on a test- or comment-only descendant of the
            # reviewed head is bound to it; the judged head joins the class check.
            judged=""
            case "$word" in
                "NO-GO "[0-9a-f]*)
                    judged="${word#NO-GO }"
                    # The delta's own new head never binds: a NO-GO there is
                    # a finding on the head under review, not on the reviewed one.
                    if [ "$judged" != "$want" ] && [ "$judged" != "${2:-}" ] && trivial_descendant "$want" "$judged"; then
                        case " $alt " in *" $judged "*) ;; *) alt="${alt:+$alt }$judged" ;; esac
                    else
                        judged=""
                    fi ;;
            esac
            if [ "$word" = "NO-GO $want" ] || { [ -n "$judged" ] && [ "$word" = "NO-GO $judged" ]; }; then
                [ -n "$hit" ] || hit="$qid/$name"
                # A layer-decision is honoured only from a signed record bound to
                # this branch's PR; one written for another PR does not lift the stop.
                if record_binds "$l9" "$l10" "$l11"; then
                    [ -n "$bound" ] || bound="$qid/$name"
                    if [ "$mac_ok" -eq 1 ]; then
                        snap_sha="$(printf '%s' "$snap" | _go_sha256)" && signed="${signed:+$signed }$qid/$name:$snap_sha"
                    fi
                fi
            fi
        done
        [ "$snapfail" -eq 0 ] || check_hits="${check_hits:+$check_hits }$qid/unreadable"
        if [ "$bad" -eq 0 ] && [ -n "$hit" ]; then
            check_hits="${check_hits:+$check_hits }$hit"
            if [ "$consumed" -eq 0 ] && [ "$macbad" -eq 0 ] && [ -n "$bound" ]; then hits="${hits:+$hits }$bound"; fi
        fi
    done
    [ -n "$check_hits" ] || exit 1
    judge_class_check "$check_hits" "$want" "$signed" "$alt" "$dir" || exit 8
    [ "$pr_want" != "-" ] || exit 8
    [ -n "$hits" ] || exit 1
    printf '%s\n' "$hits"
)

# Print "<qid>/<name> <scope>" for a judge GO on head $2 (the
# delta's new head) written by chief-kit/write-verdict.sh, whose evidence
# carries exactly one `delta-scope: test-only|lint-only` and one
# `delta-from: $1` line; rc 1 when there is none, rc 8 when a record is
# refused. A test-only record also needs every changed path to be a test path,
# checked here and not taken from the record. A qid already consumed on any
# branch is skipped, so one record buys one round.
# shellcheck disable=SC2016  # the backticks are the verdict line's literal text
judge_scope_record() (
    rr_phase judge-scope
    from="$1" want="$2"
    lib="$HIMMEL_ROOT/scripts/lib"
    # shellcheck source=scripts/lib/handover-path.sh
    # shellcheck disable=SC1091
    . "$lib/handover-path.sh" 2>/dev/null || exit 1
    # shellcheck source=/dev/null
    # shellcheck disable=SC1091
    . "$lib/go-gate.sh" 2>/dev/null || exit 1
    root="$(go_resolve_root "$HIMMEL_ROOT")" && [ -n "$root" ] || exit 1
    scope="$(go_verdict_scope "$HIMMEL_ROOT" "$(pr_repo_nwo)")" && [ -n "$scope" ] || exit 1
    dir="$root"
    [ -d "$dir" ] && [ ! -L "$dir" ] || exit 1
    for seg in "${scope%%/*}" "${scope#*/}" verdicts; do
        dir="$dir/$seg"
        [ -d "$dir" ] && [ ! -L "$dir" ] || exit 1
    done
    re_session='^writer-session: [A-Za-z0-9-]+$'
    re_written='^written-at: [0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$'
    pr_want=""
    vs_out="$(verdict_select "$dir" "$want" scope)"; vs_rc=$?
    if [ "$vs_rc" -ne 0 ]; then
        echo "review-round: verdict selection failed (rc $vs_rc) - the scope round is refused" >&2
        exit 8
    fi
    verdict_sel_read "$vs_out"
    if [ -d "$git_dir/cr-review-rounds" ]; then
        vs_scan=0
        grep -rqsF --include='*.verdicts' ' ./' "$git_dir/cr-review-rounds" 2>/dev/null || vs_scan=$?
        if [ "$vs_scan" -ne 1 ]; then
            echo "review-round: cannot scan $git_dir/cr-review-rounds (grep rc $vs_scan) - the scope record is refused" >&2
            exit 8
        fi
    fi
    if [ -n "$vs_probe" ] && ! go_verdict_snapshot "$dir/$vs_probe"; then
        echo "review-round: $vs_probe cannot be read whole (unreadable, empty or NUL) - the scope round is refused" >&2
        exit 8
    fi
    # Any NO-GO for the new head, in any qid (consumed or not, signed
    # or not - a NO-GO only narrows), blocks the scope round: a GO beside it is
    # not the judges' last word.
    for nf in "$dir"/*/*.md; do
        if [ ! -f "$nf" ] || [ -L "$nf" ]; then continue; fi
        qid="${nf#"$dir"/}"; qid="${qid%%/*}"
        case "$qid" in
            [ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789]*)
                case "$qid" in
                    *[!ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-]*) ;;
                    *) case " $sel " in *" $qid "*) ;; *) continue ;; esac ;;
                esac ;;
        esac
        # A record that cannot be read whole may be a NO-GO: it vetoes, never skips.
        if ! go_verdict_snapshot "$nf"; then
            echo "review-round: ${nf#"$dir"/} cannot be read whole (unreadable, empty or NUL) - the scope round is refused" >&2
            exit 8
        fi
        nl8=$(printf '%s' "$GO_VERDICT_SNAP" | sed -n '8p' | tr -d '\r')
        case "$nl8" in
            "**NO-GO** for head \`$want\`"|"**NO-GO** for head \`$want\`.")
                echo "review-round: ${nf#"$dir"/} rules NO-GO for $want - the scope round is refused" >&2
                exit 8 ;;
        esac
    done
    for qdir in "$dir"/*/; do
        qdir="${qdir%/}"
        qid="${qdir##*/}"
        if [ ! -d "$qdir" ] || [ -L "$qdir" ]; then continue; fi
        case "$qid" in ''|[!A-Za-z0-9]*|*[!A-Za-z0-9._-]*) continue ;; esac
        case "$qid" in
            [ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789]*)
                case "$qid" in
                    *[!ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-]*) ;;
                    *) case " $sel " in *" $qid "*) ;; *) continue ;; esac ;;
                esac ;;
        esac
        if [ -d "$git_dir/cr-review-rounds" ]; then
            scan=0
            grep -rqsF --include='*.verdicts' " $qid/" "$git_dir/cr-review-rounds" 2>/dev/null || scan=$?
            [ "$scan" -ne 0 ] || continue
            if [ "$scan" -ne 1 ]; then
                echo "review-round: cannot scan $git_dir/cr-review-rounds for a consumed $qid (grep rc $scan) - the scope record is refused" >&2
                exit 8
            fi
        fi
        hit="" bad=0
        for f in "$qdir"/*.md; do
            [ -e "$f" ] || [ -L "$f" ] || continue
            if [ -L "$f" ] || [ ! -f "$f" ]; then bad=1; break; fi
            name="${f##*/}"; name="${name%.md}"
            case "$name" in ''|[!A-Za-z0-9]*|*[!A-Za-z0-9._-]*) bad=1; break ;; esac
            # One read; the mac and every field come from this copy.
            if ! go_verdict_snapshot "$f"; then
                echo "review-round: ${f#"$dir"/} cannot be read whole (unreadable, empty or NUL) - the scope round is refused" >&2
                exit 8
            fi
            snap=$GO_VERDICT_SNAP
            l1="" l2="" l3="" l4="" l5="" l6="" l7="" l8="" l9="" l10="" l11=""
            { IFS= read -r l1; IFS= read -r l2; IFS= read -r l3; IFS= read -r l4
              IFS= read -r l5; IFS= read -r l6; IFS= read -r l7; IFS= read -r l8
              IFS= read -r l9; IFS= read -r l10; IFS= read -r l11; } <<EOF_SNAP 2>/dev/null
$snap
EOF_SNAP
            if [ "$l1" != "# VERDICT $qid - $name" ] || [ -n "$l2$l5$l7" ] || [ "$l6" != "## Verdict" ] \
                || ! [[ $l3 =~ $re_session ]] || ! [[ $l4 =~ $re_written ]]; then
                bad=1; break
            fi
            word="$(printf '%s\n' "$l8" | sed -nE 's/^\*\*(GO|NO-GO)\*\* for head `([0-9a-f]{40})`\.?$/\1 \2/p')"
            [ -n "$word" ] || { bad=1; break; }
            # The same bytes the GO is judged on also veto, so a
            # NO-GO that lands after the veto scan above still blocks the round.
            if [ "$word" = "NO-GO $want" ]; then
                echo "review-round: ${f#"$dir"/} rules NO-GO for $want - the scope round is refused" >&2
                exit 8
            fi
            # Signed by write-verdict.sh, or the qid is disqualified.
            go_verdict_mac_ok_text "$snap" "$scope" "$qid" "$name" || { bad=1; break; }
            if [ -n "$hit" ] || [ "$word" != "GO $want" ]; then continue; fi
            # The record names this branch's PR (and branch, when it
            # carries one); a record for another PR or branch is refused.
            if ! record_binds "" "$l10" "$l11"; then
                [ "$pr_want" != "-" ] || exit 8
                continue
            fi
            evidence="$(printf '%s\n' "$snap" | sed -n '9,$p')"
            n_from="$(printf '%s\n' "$evidence" | grep -cE '^delta-from: ')"
            n_from_ok="$(printf '%s\n' "$evidence" | grep -cFx "delta-from: $from")"
            n_scope="$(printf '%s\n' "$evidence" | grep -cE '^delta-scope: ')"
            if [ "$n_from" -eq 1 ] && [ "$n_from_ok" -eq 1 ] && [ "$n_scope" -eq 1 ]; then
                kind="$(printf '%s\n' "$evidence" | sed -nE 's/^delta-scope: (test-only|lint-only|merge-resolution)$/\1/p')"
                [ -z "$kind" ] || hit="$qid/$name $kind"
            fi
        done
        if [ "$bad" -ne 0 ] || [ -z "$hit" ]; then continue; fi
        if [ "${hit#* }" = "test-only" ]; then
            while IFS= read -r changed; do
                # filename patterns match the basename only: * crosses / in case
                if ! test_path_p "$changed"; then
                    echo "review-round: scope record ${hit%% *} is test-only but $from..$want changes non-test path $changed - delta round refused" >&2
                    exit 8
                fi
            done <<EOF
$(git -c core.quotepath=off diff --no-renames --name-only "$from" "$want" 2>/dev/null)
EOF
        fi
        if [ "${hit#* }" = "merge-resolution" ] && ! merge_forward_shape "$from" "$want"; then
            echo "review-round: scope record ${hit%% *} is merge-resolution but $want is not a merge of the base into $from - delta round refused" >&2
            exit 8
        fi
        printf '%s\n' "$hit"
        exit 0
    done
    exit 1
)

# Print "<qid>/<name>" for a signed judge GO on head $1, written
# by chief-kit/write-verdict.sh and bound to this branch's PR; rc 1 when there
# is none, rc 8 when a NO-GO for the head or an unresolvable PR refuses it.
# Unlike a scope record it carries no delta-from, is not consumed (it is bound
# to one head) and buys no round: it stands in for the panel review.
# shellcheck disable=SC2016  # the backticks are the verdict line's literal text
judge_go_record() (
    want="$1"
    lib="$HIMMEL_ROOT/scripts/lib"
    # shellcheck source=scripts/lib/handover-path.sh
    # shellcheck disable=SC1091
    . "$lib/handover-path.sh" 2>/dev/null || exit 1
    # shellcheck source=/dev/null
    # shellcheck disable=SC1091
    . "$lib/go-gate.sh" 2>/dev/null || exit 1
    root="$(go_resolve_root "$HIMMEL_ROOT")" && [ -n "$root" ] || exit 1
    scope="$(go_verdict_scope "$HIMMEL_ROOT" "$(pr_repo_nwo)")" && [ -n "$scope" ] || exit 1
    dir="$root"
    [ -d "$dir" ] && [ ! -L "$dir" ] || exit 1
    for seg in "${scope%%/*}" "${scope#*/}" verdicts; do
        dir="$dir/$seg"
        [ -d "$dir" ] && [ ! -L "$dir" ] || exit 1
    done
    re_session='^writer-session: [A-Za-z0-9-]+$'
    re_written='^written-at: [0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$'
    pr_want="" pr_none=""
    hit=""
    for f in "$dir"/*/*.md; do
        if [ ! -f "$f" ] || [ -L "$f" ]; then continue; fi
        qid="${f#"$dir"/}"; qid="${qid%%/*}"
        name="${f##*/}"; name="${name%.md}"
        case "$qid" in ''|[!A-Za-z0-9]*|*[!A-Za-z0-9._-]*) continue ;; esac
        case "$name" in ''|[!A-Za-z0-9]*|*[!A-Za-z0-9._-]*) continue ;; esac
        if ! go_verdict_snapshot "$f"; then
            echo "review-round: ${f#"$dir"/} cannot be read whole - the judge GO is refused" >&2
            exit 8
        fi
        snap=$GO_VERDICT_SNAP
        l1="" l2="" l3="" l4="" l5="" l6="" l7="" l8="" l9="" l10="" l11=""
        { IFS= read -r l1; IFS= read -r l2; IFS= read -r l3; IFS= read -r l4
          IFS= read -r l5; IFS= read -r l6; IFS= read -r l7; IFS= read -r l8
          IFS= read -r l9; IFS= read -r l10; IFS= read -r l11; } <<EOF_SNAP 2>/dev/null
$snap
EOF_SNAP
        # Any NO-GO for the head, signed or not, is the judges' last word.
        case "$(printf '%s' "$l8" | tr -d '\r')" in
            "**NO-GO** for head \`$want\`"|"**NO-GO** for head \`$want\`.")
                echo "review-round: ${f#"$dir"/} rules NO-GO for $want - the judge GO is refused" >&2
                exit 8 ;;
        esac
        # A symlinked qid dir can only narrow: it never supplies a GO.
        if [ -L "$dir/$qid" ]; then continue; fi
        [ -z "$hit" ] || continue
        if [ "$l1" != "# VERDICT $qid - $name" ] || [ -n "$l2$l5$l7" ] || [ "$l6" != "## Verdict" ] \
            || ! [[ $l3 =~ $re_session ]] || ! [[ $l4 =~ $re_written ]]; then
            continue
        fi
        [ "$l8" = "**GO** for head \`$want\`." ] || [ "$l8" = "**GO** for head \`$want\`" ] || continue
        go_verdict_mac_ok_text "$snap" "$scope" "$qid" "$name" || continue
        if ! record_binds "" "$l10" "$l11" prepr; then
            [ "$pr_want" != "-" ] || [ -n "$pr_none" ] || exit 8
            continue
        fi
        hit="$qid/$name"
    done
    [ -n "$hit" ] || exit 1
    printf '%s\n' "$hit"
)

# judge_go_threads prints the unresolved review threads of the branch's one open
# PR in open_review_threads' shape (a count line, then one line per thread); no
# open PR prints 0. rc 1 = not read (no lib, a failed or ambiguous PR lookup, a
# failed thread query).
judge_go_threads() {
    local jt_lib="$HIMMEL_ROOT/scripts/lib/open-review-threads.sh" jt_pr
    [ -f "$jt_lib" ] || return 1
    # shellcheck source=scripts/lib/open-review-threads.sh
    # shellcheck disable=SC1091
    . "$jt_lib" || return 1
    # shellcheck source=scripts/lib/timeout-bin.sh
    # shellcheck disable=SC1091
    . "$HIMMEL_ROOT/scripts/lib/timeout-bin.sh" 2>/dev/null || _TIMEOUT_BIN=""
    jt_pr="$(${_TIMEOUT_BIN:+"$_TIMEOUT_BIN" -k 5 30} "${_RR_GH[@]}" pr list --head "$branch" --state open \
        --json number -q '.[].number' 2>/dev/null)" || return 1
    [ -n "$jt_pr" ] || { printf '0\n'; return 0; }
    case "$jt_pr" in 0* | *[!0-9]*) return 1 ;; esac
    open_review_threads '{owner}' '{repo}' "$jt_pr" ${_TIMEOUT_BIN:+"$_TIMEOUT_BIN" -k 5 30} "${_RR_GH[@]}"
}

# ci_red_unlock <from> <to> succeeds when <from>, the last reviewed
# head, is CI-red and <from>..<to> is within the line cap. Red means a COMPLETED
# check-run with conclusion failure read from the API for <from>, and no
# check-run there still running. Sets ci_red_names. The caller has already
# established that .cired is absent and the delta state is readable.
ci_red_cap=40
ci_red_unlock() {
    # shellcheck source=scripts/lib/timeout-bin.sh
    # shellcheck disable=SC1091
    . "$HIMMEL_ROOT/scripts/lib/timeout-bin.sh" 2>/dev/null || _TIMEOUT_BIN=""
    ci_red_names=""
    _cr_rows="$(${_TIMEOUT_BIN:+"$_TIMEOUT_BIN" -k 5 30} "${_RR_GH[@]}" api --paginate "repos/{owner}/{repo}/commits/$1/check-runs" \
        --jq '.check_runs[] | [.status, (.conclusion // ""), .name] | @tsv' 2>/dev/null)" || {
        echo "review-round: cannot read the check-runs of $1 (gh api) - no CI-red unlock" >&2
        return 1
    }
    _cr_pending=0
    _cr_tab="$(printf '\t')"
    while IFS="$_cr_tab" read -r _cr_s _cr_c _cr_n; do
        [ -n "$_cr_s" ] || continue
        if [ "$_cr_s" != "completed" ]; then _cr_pending=1; continue; fi
        [ "$_cr_c" != "failure" ] || ci_red_names="${ci_red_names:+$ci_red_names,}$_cr_n"
    done <<EOF
$_cr_rows
EOF
    if [ "$_cr_pending" -eq 1 ]; then
        echo "review-round: a check-run of $1 is still running - no CI-red unlock" >&2
        return 1
    fi
    if [ -z "$ci_red_names" ]; then
        echo "review-round: $1 has no completed failing check-run - no CI-red unlock" >&2
        return 1
    fi
    case "$inc_size" in ''|*[!0-9]*)
        echo "review-round: the increment $1..$2 has no known size (a binary change) - no CI-red unlock" >&2
        return 1 ;;
    esac
    if [ "$inc_size" -gt "$ci_red_cap" ]; then
        echo "review-round: the increment $1..$2 changes $inc_size diff lines, over the $ci_red_cap-line CI-red cap - no CI-red unlock" >&2
        return 1
    fi
    return 0
}

# Record the unlock: one ledger row naming the failing checks, then
# the once-per-PR marker staged as $cired_tmp. The caller moves it into place
# only after the .delta round is recorded, so a failed state write never
# consumes the unlock. Readers key on kind, so the row is ignored by every
# gate and scorecard reader.
ci_red_record() {
    CR_LEDGER="$git_dir/cr-critic-scores.jsonl" bash "$SCRIPT_DIR/ledger-append.sh" ci-red-unlock \
        --branch "$branch" --head "$delta_from" --reason "$ci_red_names" \
        --detail "round runs on $delta_to" || return 1
    printf '%s %s %s\n' "$delta_from" "$delta_to" "$ci_red_names" > "$cired_tmp" || return 1
}

# Decide whether a round past the cap may run. Sets delta_from (R), delta_to,
# delta_class and the increment descriptor; a work round also sets
# delta_trigger. Says why not and returns 8 (2 for an unresolvable --head). A
# judge NO-GO on the last reviewed head is a trigger; it sets delta_verdict.
delta_check() {
    full_note="a 4th full round is refused"
    delta_reuse=0
    delta_class=""
    delta_used=""
    delta_verdict=""
    if [ "$full_arg" -eq 1 ]; then
        echo "review-round: $branch already ran 3 full rounds - a --full round past the cap is refused; a round past the cap reviews the increment" >&2
        return 8
    fi
    if [ -f "$delta_state" ]; then
        # A delta round whose panel produced no critic rows is
        # still pending, so the SAME <from> <to> pair may start again. Any
        # other pair, or a head a critic already reviewed, has used it up.
        read -r pend_from pend_to pend_trigger < "$delta_state" 2>/dev/null || pend_from=""
        if [ -n "$head_sha" ] && [ -n "$pend_from" ] && [ -n "$pend_to" ] \
            && cur_to="$(git rev-parse --verify --quiet "$head_sha^{commit}" 2>/dev/null)" \
            && [ "$cur_to" = "$pend_to" ] \
            && [ "$(ledger_query avail "$pend_to")" != "ok" ] \
            && [ "$(ledger_query row "$pend_to")" != "row" ]; then
            # The first start's caller is still alive, so its
            # panel may be running; a second panel would only burn the bank.
            run_pid=""
            [ ! -f "$delta_run" ] || read -r run_pid < "$delta_run" || run_pid=""
            case "$run_pid" in
                ''|*[!0-9]*) run_pid="" ;;
            esac
            if [ -n "$run_pid" ] && [ "$run_pid" != "$rr_caller" ] && kill -0 "$run_pid" 2>/dev/null; then
                echo "review-round: the delta round on $branch is already running (start by pid $run_pid) - wait for it" >&2
                return 8
            fi
            delta_from="$pend_from"
            delta_to="$pend_to"
            delta_trigger="${pend_trigger:-fix}"
            delta_reuse=1
            delta_class=work
            # swallow-ok: a pending pair whose increment cannot be read reviews from R, as before
            increment_of "$delta_from" "$delta_to" || inc_l="$delta_from"
            return 0
        fi
        delta_used="$(cat "$delta_state" 2>/dev/null)"
        [ -n "$delta_used" ] || delta_used="unreadable"
    fi
    if [ -z "$head_sha" ]; then
        delta_refuse "review-round: $branch already ran 3 full rounds - $full_note; only a delta round (start --head) can run"
        return 8
    fi
    if ! delta_to="$(git rev-parse --verify --quiet "$head_sha^{commit}" 2>/dev/null)" || [ -z "$delta_to" ]; then
        if [ -n "$delta_used" ]; then
            delta_refuse "review-round: --head $head_sha does not resolve to a commit"
            return 8
        fi
        echo "review-round: --head $head_sha does not resolve to a commit" >&2
        return 2
    fi
    # The scope starts at the head the last counted round ran on, as start
    # persisted it - never at a ledger row the session could append itself.
    last_reviewed="$(cat "$head_state" 2>/dev/null)" || last_reviewed=""
    delta_from=""
    if [ -n "$last_reviewed" ]; then
        delta_from="$(git rev-parse --verify --quiet "$last_reviewed^{commit}" 2>/dev/null)" || delta_from=""
    fi
    # Start persists .head before the panel runs, so a delta round
    # whose panel left no critic rows (unavailable, claude-only) leaves .head on
    # an unreviewed head. The used pair's <from> is then the latest
    # critic-reviewed head, so scope from it: the judge record and the
    # one-round-per-reviewed-head check stay keyed on a head a critic reviewed.
    if [ -n "$delta_from" ] && [ "$(ledger_query avail "$delta_from")" != "ok" ] \
        && [ "$delta_used" != "unreadable" ] && [ -n "$delta_used" ]; then
        read -r used_from used_to _ <<EOF
$delta_used
EOF
        if [ -n "$used_from" ] && [ "$used_to" = "$delta_from" ] \
            && used_base="$(git rev-parse --verify --quiet "$used_from^{commit}" 2>/dev/null)" \
            && [ "$(ledger_query avail "$used_base")" = "ok" ]; then
            delta_from="$used_base"
        fi
    fi
    if [ -z "$delta_from" ] || [ "$(ledger_query avail "$delta_from")" != "ok" ]; then
        delta_refuse "review-round: no critic-reviewed head of the last counted round on $branch to scope a delta round from (${last_reviewed:-none} has no critic avail row) - $full_note"
        return 8
    fi
    if [ "$delta_from" = "$delta_to" ]; then
        delta_refuse "review-round: $delta_to is the last reviewed head on $branch - $full_note"
        return 8
    fi
    if ! git merge-base --is-ancestor "$delta_from" "$delta_to" 2>/dev/null; then
        delta_refuse "review-round: $delta_to does not descend from the last reviewed head $delta_from - $full_note"
        return 8
    fi
    delta_verdict="$(judge_nogo_record "$delta_from" "$delta_to")"
    judge_rc=$?
    rr_phase delta-check
    [ "$judge_rc" -ne 8 ] || return 8
    if ! increment_of "$delta_from" "$delta_to"; then
        delta_refuse "review-round: no increment from $delta_from to $delta_to can be computed (git could not answer or merge-tree failed) - $full_note"
        return 8
    fi
    increment_class "$delta_from" "$delta_to"
    delta_class="$inc_class"
    case "$delta_class" in
        carried|tests|comments|merge-resolution|fix) delta_verdict=""; return 0 ;;
    esac
    if [ "$inc_empty" -eq 1 ]; then
        delta_refuse "review-round: the increment $delta_from..$delta_to changes nothing - no delta round to run"
        return 8
    fi
    if [ -z "$delta_used" ]; then
        if [ "$(ledger_query finding "$delta_from")" = "finding" ]; then
            delta_trigger="fix"
            return 0
        fi
    fi
    # One judge-triggered round per last reviewed head.
    # An unreadable .verdicts refuses, never reads as unconsumed.
    head_scan=1
    if [ -e "$verdict_state" ] || [ -L "$verdict_state" ]; then
        head_scan=0
        grep -q "^$delta_from " "$verdict_state" 2>/dev/null || head_scan=$?
        if [ "$head_scan" -gt 1 ]; then
            echo "review-round: cannot read $verdict_state (grep rc $head_scan) - no judge NO-GO is honoured for $delta_from" >&2
        fi
    fi
    # The delta round ran on <delta_from>, critic findings were
    # raised there and every one is recorded fixed at that head: one more delta
    # round, from it, with no judge record. Consumed once: the .delta pair then
    # carries the trigger, so a post-cap round never chains into another, and a
    # head a judge record already bought a round from is not eligible. Any
    # finding not fixed (deferred, disproved, agreed, open), no critic finding,
    # or a fixed verdict recorded against another head refuses (ledger_query
    # reads only critic rows and amends at <delta_from>).
    if [ -n "$delta_used" ] && [ "$delta_used" != "unreadable" ] && [ "$head_scan" -eq 1 ]; then
        read -r used_from used_to used_trigger <<EOF
$delta_used
EOF
        if [ -n "$used_from" ] && [ -n "$used_to" ] && free_reaches "$delta_from" "$used_to" \
            && [ "${used_trigger:-}" != "postcap-fixed" ] \
            && [ "${used_trigger:-}" != "postcap-ci-red" ] \
            && [ "$(ledger_query allfixed "$used_to")" = "allfixed" ]; then
            delta_trigger="postcap-fixed"
            delta_verdict=""
            return 0
        fi
    fi
    if [ "$head_scan" -eq 1 ] && [ "$judge_rc" -eq 0 ] && [ -n "$delta_verdict" ]; then
        first_verdict="${delta_verdict%% *}"
        delta_trigger="verdict:${first_verdict%%/*}"
        return 0
    fi
    # A judge-signed test- or lint-only record for the new head.
    scope_hit="$(judge_scope_record "$delta_from" "$delta_to")"
    scope_rc=$?
    rr_phase delta-check
    [ "$scope_rc" -ne 8 ] || return 8
    if [ "$scope_rc" -eq 0 ] && [ -n "$scope_hit" ]; then
        scope_hit="${scope_hit%% *}"
        delta_verdict="$scope_hit"
        delta_trigger="scope:${scope_hit%%/*}"
        return 0
    fi
    delta_verdict=""
    # The last reviewed head is CI-red: one bounded round, once per PR, no
    # judge record needed - whether or not the delta round was spent.
    if [ "$delta_used" != "unreadable" ] \
        && [ ! -e "$cired_state" ] && [ ! -L "$cired_state" ] \
        && ci_red_unlock "$delta_from" "$delta_to"; then
        delta_trigger="postcap-ci-red"
        return 0
    fi
    delta_refuse "review-round: new product work after three rounds: split the PR or narrow the change; or ask the chief for a judge NO-GO or a grant. $delta_to neither answers a round-3 finding nor only merges the base into $delta_from, and no judge NO-GO for $delta_from is recorded (chief-kit/write-verdict.sh) - $full_note; new work after the cap goes to the chief"
    return 8
}

# Once the delta was used every refusal keeps naming it; otherwise print $1.
delta_refuse() {
    if [ -n "$delta_used" ]; then
        # Name the check that fired; the used-delta note follows it.
        [ -z "$1" ] || echo "$1" >&2
        echo "review-round: the one delta round was already used on $branch ($delta_used) - a second delta round is refused, and $full_note; only a judge NO-GO on the last reviewed head (chief-kit/write-verdict.sh) buys another; ask the chief" >&2
    else
        echo "$1" >&2
    fi
}

# judge-go: after the round cap, a signed judge GO at --head stands in for the
# panel review of the delta since the last critic-reviewed head.
# Exit 0 = accepted: prints <qid>/<name> and records one ledger row with
# source=judge:<qid>/<name>. The row is audit-only: its kind is not one
# ledger-append.sh writes, and every gate reader keys on kind and ignores it.
# 1 = no GO record, or a round is still available;
# 8 = refused (NO-GO at the head, head not a descendant of a reviewed head, or an
# unresolved review thread on the branch's open PR).
if [ "$verb" = "judge-go" ]; then
    # swallow-ok: an unresolvable head is refused on the next line (exit 2)
    if ! jg_head="$(git rev-parse --verify --quiet "$head_sha^{commit}" 2>/dev/null)" || [ -z "$jg_head" ]; then
        echo "review-round: --head $head_sha does not resolve to a commit" >&2
        exit 2
    fi
    case "$branch" in
        *[\"\\]*|*[[:cntrl:]]*)
            echo "review-round: branch name $branch cannot be written into a ledger row - the judge GO is refused" >&2
            exit 2 ;;
    esac
    case "$threads_ok" in
        *[\"\\]*|*[[:cntrl:]]*)
            echo "review-round: the --open-threads-ok reason cannot be written into a ledger row (no quote, backslash or control character) - the judge GO is refused" >&2
            exit 2 ;;
    esac
    jg_note=""
    # swallow-ok: an unread thread list is named on the next lines and the GO goes on
    if ! jg_th="$(judge_go_threads)"; then
        echo "review-round: WARNING - could not read the review threads of the open PR of $branch; this judge GO is not checked against open threads (check-ci still refuses the merge over one)" >&2
    elif [ "${jg_th%%$'\n'*}" != 0 ]; then
        if [ -z "$threads_ok" ]; then
            printf 'review-round: %s unresolved review thread(s) on the open PR of %s - a judge GO is never taken over an open thread; read, answer and resolve each, or the chief names the override with --open-threads-ok "<reason>":\n%s' \
                "${jg_th%%$'\n'*}" "$branch" "${jg_th#*$'\n'}" >&2
            exit 8
        fi
        printf 'review-round: WARNING - judge GO taken over %s unresolved review thread(s) on the open PR of %s, by the override (%s):\n%s' \
            "${jg_th%%$'\n'*}" "$branch" "$threads_ok" "${jg_th#*$'\n'}" >&2
        jg_note=",\"open_threads_ok\":\"${jg_th%%$'\n'*} open, $threads_ok\""
    fi
    read_round || exit 5
    if [ "$round" -lt 3 ]; then
        echo "review-round: $branch has run $round of 3 full rounds - run /pr-check, a judge GO does not replace an available round" >&2
        exit 1
    fi
    # swallow-ok: no critic-reviewed head in the start records leaves jg_from empty, which is refused (exit 8)
    jg_from="$(reviewed_head)" || jg_from=""
    if [ -z "$jg_from" ] || ! git merge-base --is-ancestor "$jg_from" "$jg_head" 2>/dev/null; then
        echo "review-round: $jg_head does not descend from a critic-reviewed head of $branch - the judge GO is refused" >&2
        exit 8
    fi
    jg_hit="$(judge_go_record "$jg_head")"
    jg_rc=$?
    if [ "$jg_rc" -eq 1 ]; then
        echo "review-round: no signed judge GO at $jg_head is bound to $branch (a record naming its open PR, or the branch while it has no PR yet) - the judge GO is refused" >&2
    fi
    [ "$jg_rc" -eq 0 ] && [ -n "$jg_hit" ] || exit "$jg_rc"
    jg_ledger="$git_dir/cr-critic-scores.jsonl"
    if ! grep -qsF "\"head\":\"$jg_head\",\"status\":\"ok\",\"source\":\"judge:$jg_hit\"$jg_note" "$jg_ledger"; then
        printf '{"kind":"judge-go","ts":"%s","branch":"%s","head":"%s","status":"ok","source":"judge:%s"%s}\n' \
            "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$branch" "$jg_head" "$jg_hit" "$jg_note" >> "$jg_ledger" || exit 5
    fi
    printf '%s\n' "$jg_hit"
    exit 0
fi

# evidence: a ledger row for a head that only changes test paths after the
# critic-reviewed head, so ready-check's CR row exists without spending a round.
# Exit 0 = recorded (or already there); 8 = refused (not a descendant of a
# reviewed head, or the diff changes non-test paths).
if [ "$verb" = "evidence" ]; then
    # swallow-ok: an unresolvable head is refused on the next line (exit 2)
    if ! ev_head="$(git rev-parse --verify --quiet "$head_sha^{commit}" 2>/dev/null)" || [ -z "$ev_head" ]; then
        echo "review-round: --head $head_sha does not resolve to a commit" >&2
        exit 2
    fi
    case "$branch" in
        *[\"\\]*|*[[:cntrl:]]*)
            echo "review-round: branch name $branch cannot be written into a ledger row - evidence is refused" >&2
            exit 2 ;;
    esac
    # swallow-ok: no critic-reviewed head in the start records leaves ev_from empty, which is refused (exit 8)
    ev_from="$(reviewed_head)" || ev_from=""
    # tests-only: evidence clears with no critic review of from..to, so the
    # comment branch (a code line that looks like a comment) is not admitted.
    if [ -z "$ev_from" ] \
        || [ "$(ledger_query finding "$ev_from")" = "finding" ] \
        || ! ( _td_tests_only=1; trivial_descendant "$ev_from" "$ev_head" ); then
        echo "review-round: $ev_head is not a tests-only descendant of a critic-reviewed head of $branch with no open finding - no evidence row (run /pr-check)" >&2
        exit 8
    fi
    ev_ledger="$git_dir/cr-critic-scores.jsonl"
    if ! grep -qsF "\"branch\":\"$branch\",\"head\":\"$ev_head\",\"status\":\"ok\",\"source\":\"evidence\"" "$ev_ledger"; then
        printf '{"kind":"evidence","ts":"%s","branch":"%s","head":"%s","status":"ok","source":"evidence"}\n' \
            "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$branch" "$ev_head" >> "$ev_ledger" || exit 5
    fi
    printf 'evidence %s\n' "$ev_head"
    exit 0
fi

if [ "$verb" = "settle" ]; then
    # swallow-ok: an unresolvable head is refused on the next line (exit 2)
    if ! st_head="$(git rev-parse --verify --quiet "$head_sha^{commit}" 2>/dev/null)" || [ -z "$st_head" ]; then
        echo "review-round: --head $head_sha does not resolve to a commit" >&2
        exit 2
    fi
    counter_lock || exit 5
    st_rc=0
    snap_load || st_rc=$?
    case "$st_rc" in
        0) if [ "$snap_head" = "$st_head" ] && ! rm -f "$snap_state"; then st_rc=5; fi ;;
        1) st_rc=0 ;;
        *) echo "review-round: cannot read the round snapshot $snap_state" >&2; st_rc=5 ;;
    esac
    SHARED_BRANCH_LOCK_NS=himmel-cr-review-round \
        bash "$lock_lib" release-if-owner "." "$branch" "$lock_owner" >/dev/null 2>&1 || true
    exit "$st_rc"
fi

# abort: a round whose panel aborted after start reviewed nothing, so it spends
# nothing. With no avail or finding row at --head (on .head) and a starter that
# is the caller or has ended, the start's snapshot is restored: every round file,
# so a delta round also gets back its slot, CI-red unlock and judge record. A
# starter not the caller, or a continued round, waits two hours from the start.
# No snapshot: .head goes back to the last reviewed head, the round is uncounted
# (a pending delta round keeps its count).
# Exit 0 = given back (prints "<round> <head .head names, or none>"); 1 = --head
# is not on .head; 8 = refused (rows, unreadable ledger or snapshot, a running or
# unrecorded starter, under two hours, a file another writer changed); 5 = error.
if [ "$verb" = "abort" ]; then
    # swallow-ok: an unresolvable head is refused on the next line (exit 2)
    if ! ab_head="$(git rev-parse --verify --quiet "$head_sha^{commit}" 2>/dev/null)" || [ -z "$ab_head" ]; then
        echo "review-round: --head $head_sha does not resolve to a commit" >&2
        exit 2
    fi
    counter_lock || exit 5
    ab_rc=0
    read_round || ab_rc=5
    # swallow-ok: a missing or unreadable .head is "not --head" (exit 1)
    ab_cur="$(state_sha "$head_state")" || ab_cur=""
    ab_snap=0
    snap_rc=0
    snap_load || snap_rc=$?
    [ "$snap_rc" -ne 0 ] || [ "$snap_head" != "$ab_head" ] || ab_snap=1
    run_pid=""
    if [ "$ab_snap" -eq 1 ]; then
        run_pid="$snap_pid"
    else
        [ ! -f "$delta_run" ] || read -r run_pid < "$delta_run" || run_pid=""
    fi
    case "$run_pid" in ''|*[!0-9]*) run_pid="" ;; esac
    run_alive=""
    if [ -n "$pr" ] && [ -f "$delta_run" ]; then
        while read -r run_other; do
            case "$run_other" in ''|*[!0-9]*) continue ;; esac
            if [ "$run_other" != "$PPID" ] && kill -0 "$run_other" 2>/dev/null; then run_alive="$run_other"; fi
        done < "$delta_run"
    fi
    if [ "$ab_rc" -ne 0 ]; then
        :
    elif [ "$ab_cur" != "$ab_head" ]; then
        echo "review-round: $ab_head is not the head the last counted round on $branch ran on (${ab_cur:-none}) - nothing to give back" >&2
        ab_rc=1
    elif ! ab_seen="$(ledger_query seen "$ab_head")"; then
        echo "review-round: cannot read the panel ledger for $ab_head, so the round cannot be shown to have reviewed nothing - it is not given back" >&2
        ab_rc=8
    elif [ "$ab_seen" = "seen" ]; then
        echo "review-round: the round on $ab_head has panel rows, so it reviewed something - it is not given back" >&2
        ab_rc=8
    elif [ "$snap_rc" -eq 5 ]; then
        echo "review-round: cannot read the round snapshot $snap_state, so the round's starter and bytes are unknown - it is not given back" >&2
        ab_rc=8
    elif [ -z "$run_pid" ]; then
        echo "review-round: no start caller is recorded for the round on $ab_head, so it cannot be shown to have ended - it is not given back" >&2
        ab_rc=8
    elif [ -n "$run_alive" ] || { [ "$run_pid" != "$PPID" ] && kill -0 "$run_pid" 2>/dev/null; }; then
        echo "review-round: the round on $ab_head is still running (start by pid ${run_alive:-$run_pid}) - it is not given back" >&2
        ab_rc=8
    elif [ "$ab_snap" -eq 1 ] && [ "$snap_complete" = 1 ] \
        && { [ "$run_pid" != "$PPID" ] || [ "$snap_continued" = 1 ]; } && snap_young; then
        echo "review-round: a dead round at $ab_head is younger than two hours ($snap_left min left) - it is not given back" >&2
        ab_rc=8
    elif [ "$ab_snap" -eq 1 ]; then
        restore_snapshot
        case $? in
            0) ;;
            1) ab_rc=8 ;;
            *) echo "review-round: cannot give back the round on $ab_head for $branch from its snapshot" >&2; ab_rc=5 ;;
        esac
        # swallow-ok: a missing counter file after the restore reads as zero
        ab_round="$(cat "$state" 2>/dev/null)" || ab_round=""
        ab_round="${ab_round:-0}"
        # swallow-ok: no .head after the restore prints none
        ab_back="$(state_sha "$head_state")" || ab_back=""
    else
        # swallow-ok: no critic-reviewed head in the start records removes .head below
        ab_back="$(reviewed_head)" || ab_back=""
        ab_to=""
        if [ -f "$delta_state" ] && [ ! -L "$delta_state" ]; then
            read -r _ ab_to _ < "$delta_state" 2>/dev/null || ab_to=""
        fi
        ab_round="$round"
        [ "$ab_to" = "$ab_head" ] || [ "$round" -eq 0 ] || ab_round=$((round - 1))
        # .head first: a failed counter write after it leaves the round spent,
        # never a free one.
        tmp_head="$head_state.tmp.$$"
        tmp_state="$state.tmp.$$"
        if [ -n "$ab_back" ]; then
            { printf '%s\n' "$ab_back" > "$tmp_head" && mv "$tmp_head" "$head_state"; } || ab_rc=5  # prim-ok: start's tmp-then-mv idiom under the counter lock; this script does not source prim.sh
        else
            rm -f "$head_state" || ab_rc=5
        fi
        if [ "$ab_rc" -eq 0 ] && [ "$ab_round" != "$round" ]; then
            { printf '%s\n' "$ab_round" > "$tmp_state" && mv "$tmp_state" "$state"; } || ab_rc=5  # prim-ok: start's tmp-then-mv idiom under the counter lock; this script does not source prim.sh
        fi
        rm -f "$tmp_head" "$tmp_state"
        [ "$ab_rc" -eq 0 ] || echo "review-round: cannot give back the round on $ab_head for $branch" >&2
    fi
    SHARED_BRANCH_LOCK_NS=himmel-cr-review-round \
        bash "$lock_lib" release-if-owner "." "$branch" "$lock_owner" >/dev/null 2>&1 || true
    [ "$ab_rc" -ne 0 ] || printf '%s %s\n' "$ab_round" "${ab_back:-none}"
    exit "$ab_rc"
fi

# start|check --pr <n> --head <H>: an outside PR reviewed from its diff, its
# branch never checked out. State is keyed outside-<n>. This is the one owner of the cap
# for such a PR: outside_pr_authorize reads the author and the head from the forge itself
# and is told how many full rounds were used, so a listed author gets three, and a fourth
# (or any round for an unlisted author) needs a recorded review approval for exactly this
# head. There is no delta round here: past the cap the answer is exit 5. `check` is the
# same decision with nothing written. Exit 0 prints the round number; 5 = not authorized,
# or a state or lock error.
if [ -n "$pr" ]; then
    # shellcheck source=scripts/lib/outside-contributors.sh
    # shellcheck disable=SC1091
    . "$HIMMEL_ROOT/scripts/lib/outside-contributors.sh" || {
        echo "review-round: cannot load scripts/lib/outside-contributors.sh - a --pr round is refused" >&2
        exit 5
    }
    pr_unlock() {
        [ "$verb" != "start" ] || SHARED_BRANCH_LOCK_NS=himmel-cr-review-round \
            bash "$lock_lib" release-if-owner "." "$branch" "$lock_owner" >/dev/null 2>&1 || true
    }
    if [ "$verb" = "start" ]; then rr_phase lock; counter_lock || exit 5; fi
    read_round || { pr_unlock; exit 5; }
    # A start at the head the counted round already ran on is bookkeeping: it reuses that
    # round, and that round does not count against the cap when it is authorized.
    pr_used="$round"
    pr_reuse=0
    # swallow-ok: a missing or unreadable .head is "a new head"
    pr_rec="$(cat "$head_state" 2>/dev/null)" || pr_rec=""
    if [ "$round" -ge 1 ] && [ "$pr_rec" = "$head_sha" ]; then
        pr_reuse=1
        pr_used=$((round - 1))
    fi
    rr_phase authorize
    if ! pr_auth="$(outside_pr_authorize "$pr" "$head_sha" "$pr_used")"; then
        pr_unlock
        echo "review-round: PR #$pr at $head_sha is not authorized for a no-checkout review (author not on the allowlist, no recorded approval for exactly this head, the full-round cap used, or the forge could not be read) - nothing was recorded" >&2
        exit 5
    fi
    if [ "$pr_reuse" -eq 1 ]; then
        [ "$verb" != "start" ] || { [ -f "$delta_run" ] && printf '%s\n' "$rr_caller" >> "$delta_run" 2>/dev/null; } || rm -f "$delta_run" 2>/dev/null
        pr_unlock
        if [ "$verb" = "check" ]; then printf '%s %s\n' "$round" "$pr_auth"; else printf '%s\n' "$round"; fi
        exit 0
    fi
    pr_next=$((round + 1))
    if [ "$verb" = "check" ]; then
        printf '%s %s\n' "$pr_next" "$pr_auth"
        exit 0
    fi
    rr_phase persist
    pr_tmp_state="$state.tmp.$$"
    pr_tmp_head="$head_state.tmp.$$"
    # swallow-ok: an unreadable lock status reads as "not the owner", which refuses the write below
    pr_owner="$(SHARED_BRANCH_LOCK_NS=himmel-cr-review-round bash "$lock_lib" status "." "$branch" 2>/dev/null || true)"
    if [ "$pr_owner" != "$lock_owner" ] \
        || ! printf '%s\n' "$pr_next" > "$pr_tmp_state" \
        || ! printf '%s\n' "$head_sha" > "$pr_tmp_head" \
        || ! { mv "$pr_tmp_state" "$state" && mv "$pr_tmp_head" "$head_state"; }; then  # prim-ok: tmp-then-mv under the counter lock, like start; fixture copies of this script have no scripts/lib
        rm -f "$pr_tmp_state" "$pr_tmp_head"
        pr_unlock
        echo "review-round: cannot persist round $pr_next for PR #$pr under the counter lock" >&2
        exit 5
    fi
    printf '%s\n' "$rr_caller" > "$delta_run" 2>/dev/null || rm -f "$delta_run" 2>/dev/null
    if ! SHARED_BRANCH_LOCK_NS=himmel-cr-review-round \
        bash "$lock_lib" release-if-owner "." "$branch" "$lock_owner" >/dev/null 2>&1; then
        echo "review-round: persisted round $pr_next for PR #$pr but could not release its counter lock" >&2
        exit 5
    fi
    printf '%s\n' "$pr_next"
    exit 0
fi

if [ "$verb" = "start" ]; then
    rr_phase lock
    counter_lock || exit 5
    start_unlock() {
        SHARED_BRANCH_LOCK_NS=himmel-cr-review-round \
            bash "$lock_lib" release-if-owner "." "$branch" "$lock_owner" >/dev/null 2>&1 || true
    }
    if ! read_round; then
        start_unlock
        exit 5
    fi
    start_head=""
    if [ -n "$head_sha" ]; then
        # swallow-ok: an unresolvable head takes today's path and writes no snapshot
        start_head="$(git rev-parse --verify --quiet "$head_sha^{commit}" 2>/dev/null)" || start_head=""
    fi
    snap_wrote=0
    snap_rc=1
    rr_phase snapshot
    [ -z "$start_head" ] || { snap_rc=0; snap_load || snap_rc=$?; }
    if [ "$snap_rc" -eq 5 ]; then
        start_unlock
        echo "review-round: cannot read the round snapshot $snap_state - refusing (cr-reset.sh moves it aside)" >&2
        exit 5
    fi
    if [ "$snap_rc" -eq 0 ]; then
        if ! snap_seen="$(ledger_query seen "$snap_head")"; then
            start_unlock
            echo "review-round: cannot read the panel ledger for $snap_head, the head of the last round's snapshot - refusing" >&2
            exit 8
        fi
        snap_who="$(snap_starter)"
        # swallow-ok: an unreadable round file reads as moved, which never restores
        snap_files="$(snap_node check "$snap_state" "${snap_list[@]}")" || snap_files=moved
        snap_rc=0
        if [ "$snap_seen" = "seen" ]; then
            rm -f "$snap_state" || snap_rc=5
        elif [ "$snap_who" = alive ]; then
            start_unlock
            echo "review-round: the round on $branch at $snap_head is already running (start by pid $snap_pid) - wait for it" >&2
            exit 8
        elif [ "$snap_files" = moved ]; then
            restore_snapshot || [ $? -eq 1 ] || snap_rc=5
        elif [ "$snap_files" = allowed ]; then
            restore_snapshot || snap_rc=5
        elif [ "$snap_head" = "$start_head" ] && [ "$snap_complete" = 1 ] \
            && { [ "$snap_who" = caller ] || [ "$snap_who" = ended ]; }; then
            if ! snap_write continue "$rr_caller"; then
                start_unlock
                echo "review-round: cannot record the restart in the round snapshot $snap_state" >&2
                exit 5
            fi
            printf '%s\n' "$rr_caller" > "$delta_run" 2>/dev/null || rm -f "$delta_run" 2>/dev/null
            start_unlock
            printf '%s\n' "$snap_answer"
            exit 0
        elif [ "$snap_complete" = 1 ] && snap_young; then
            start_unlock
            echo "review-round: a dead round at $snap_head is younger than two hours ($snap_left min left) - a start at another head waits, a restart at $snap_head continues it" >&2
            exit 8
        else
            restore_snapshot || snap_rc=5
        fi
        if [ "$snap_rc" -ne 0 ] || ! read_round; then
            start_unlock
            echo "review-round: cannot give back the round in the snapshot $snap_state" >&2
            exit 5
        fi
    fi
    # A start at the head the counted round already ran on is bookkeeping, not
    # a new round: reuse it. From the cap on, the same head stays refused below.
    if [ "$round" -ge 1 ] && [ "$round" -lt 3 ] && [ -n "$head_sha" ]; then
        # swallow-ok: an unresolvable or unrecorded head just takes the normal count
        same_cur="$(git rev-parse --verify --quiet "$head_sha^{commit}" 2>/dev/null)" || same_cur=""
        # swallow-ok: same as above
        same_rec="$(cat "$head_state" 2>/dev/null)" || same_rec=""
        if [ -n "$same_cur" ] && [ "$same_cur" = "$same_rec" ]; then
            SHARED_BRANCH_LOCK_NS=himmel-cr-review-round \
                bash "$lock_lib" release-if-owner "." "$branch" "$lock_owner" >/dev/null 2>&1 || true
            printf '%s\n' "$round"
            exit 0
        fi
    fi
    delta_from=""
    delta_reuse=0
    free_count=0
    if [ -e "$free_state" ] || [ -L "$free_state" ]; then
        if [ ! -f "$free_state" ] || [ -L "$free_state" ] \
            || ! free_count="$(awk 'NF { n++ } END { print n + 0 }' "$free_state" 2>/dev/null)"; then
            start_unlock
            echo "review-round: cannot read the free-round record $free_state - refusing (cr-reset.sh moves it aside)" >&2
            exit 5
        fi
    fi
    postcap=0
    [ "$round" -lt 3 ] || postcap=1
    start_class=full
    start_r=""
    inc_l=""
    if [ "$postcap" -eq 0 ]; then
        if [ "$full_arg" -eq 0 ] && [ "$round" -ge 1 ] && [ -n "$start_head" ] \
            && start_r="$(reviewed_head)" && increment_of "$start_r" "$start_head"; then
            increment_class "$start_r" "$start_head"
            start_class="$inc_class"
        fi
    else
        rr_phase delta-check
        delta_check
        delta_rc=$?
        if [ "$delta_rc" -ne 0 ]; then
            start_unlock
            exit "$delta_rc"
        fi
        start_class="$delta_class"
        start_r="$delta_from"
    fi
    if [ "$start_class" = carried ]; then
        start_unlock
        printf '%s carried %s\n' "$round" "$start_r"
        exit 0
    fi
    snap_start() {
        [ -n "$start_head" ] || return 0
        rr_phase snapshot-write
        if ! snap_write before "$start_head" "$rr_caller" "$(date +%s)" "${snap_list[@]}"; then
            echo "review-round: cannot write the round snapshot $snap_state - no round is started" >&2
            return 5
        fi
        snap_wrote=1
    }
    snap_drop() { [ "$snap_wrote" -eq 0 ] || rm -f "$snap_state"; }
    if ! snap_start; then
        start_unlock
        exit 5
    fi
    if [ "$postcap" -eq 1 ]; then
        delta_rc=0
        if [ "$start_class" = work ] && [ "${delta_reuse:-0}" -eq 0 ]; then
            rr_phase delta-write
            # The delta round is recorded first and the judge
            # record consumed after it; a failed consume restores the prior
            # .delta, so a record is never spent on a round that never started.
            # Once both land, a failed counter write below is the
            # pending pair, which restarts without the record.
            tmp_delta="$delta_state.tmp.$$"
            cired_tmp="$cired_state.tmp.$$"
            bak_delta="$delta_state.bak.$$"
            had_delta=0
            if { [ -n "$delta_verdict" ] || [ "$delta_trigger" = "postcap-ci-red" ]; } && [ -f "$delta_state" ]; then
                had_delta=1
                cp -p "$delta_state" "$bak_delta" 2>/dev/null || delta_rc=5
            fi
            if [ "$delta_rc" -eq 0 ] && [ "$delta_trigger" = "postcap-ci-red" ] && ! ci_red_record; then
                echo "review-round: cannot record the CI-red unlock for $branch" >&2
                delta_rc=5
            fi
            if [ "$delta_rc" -ne 0 ] \
                || ! printf '%s %s %s\n' "$delta_from" "$delta_to" "$delta_trigger" > "$tmp_delta" \
                || ! mv "$tmp_delta" "$delta_state" || # prim-ok: the delta and CI-red files are one rolled-back record, and test-pr-check-rounds copies this script without scripts/lib
                ! { [ "$delta_trigger" != "postcap-ci-red" ] || mv "$cired_tmp" "$cired_state"; }; then
                # A CI-red round that did not fully land puts the
                # spent .delta back, so the unlock is not half-consumed.
                if [ "$delta_trigger" = "postcap-ci-red" ] && [ -f "$bak_delta" ]; then
                    mv -f "$bak_delta" "$delta_state" 2>/dev/null || true
                elif [ "$delta_trigger" = "postcap-ci-red" ] && [ "$had_delta" -eq 0 ]; then
                    rm -f "$delta_state"
                fi
                rm -f "$tmp_delta" "$bak_delta" "$cired_tmp"
                echo "review-round: cannot record the delta round for $branch" >&2
                delta_rc=5
            elif [ -n "$delta_verdict" ]; then
                tmp_verdicts="$verdict_state.tmp.$$"
                if ! { cat "$verdict_state" 2>/dev/null || [ ! -e "$verdict_state" ]; } > "$tmp_verdicts" \
                    || ! ( for record in $delta_verdict; do
                        printf '%s %s %s\n' "$delta_from" "$delta_to" "$record" || exit 1
                    done ) >> "$tmp_verdicts" \
                    || ! mv "$tmp_verdicts" "$verdict_state"; then  # prim-ok: tmp-then-mv under the counter lock with a restore of .delta; fixture copies of this script have no scripts/lib
                    rm -f "$tmp_verdicts"
                    if [ "$had_delta" -eq 1 ]; then
                        # A failed restore keeps the new pair: still "used".
                        mv -f "$bak_delta" "$delta_state" 2>/dev/null || true
                    else
                        rm -f "$delta_state"
                    fi
                    echo "review-round: cannot record the judge record $delta_verdict for $branch" >&2
                    delta_rc=5
                fi
                rm -f "$bak_delta"
            fi
            rm -f "$bak_delta" "$cired_tmp"
        fi
        if [ "$delta_rc" -ne 0 ]; then
            snap_drop
            start_unlock
            exit "$delta_rc"
        fi
    fi
    rr_phase persist
    counted=1
    case "$start_class" in tests|comments|merge-resolution|fix) counted=0 ;; esac
    # A reused pending delta round keeps the counter it already took.
    [ "${delta_reuse:-0}" -eq 1 ] || [ "$counted" -eq 0 ] || round=$((round + 1))
    # The first round opens a new loop, which never reuses the last loop's
    # batch residual.
    if [ "$round" -eq 1 ] && [ "$counted" -eq 1 ] && ! rm -f "$deferred_to_state"; then
        snap_drop
        start_unlock
        echo "review-round: cannot remove $deferred_to_state for a new round 1" >&2
        exit 5
    fi
    current_owner=$(SHARED_BRANCH_LOCK_NS=himmel-cr-review-round \
        bash "$lock_lib" status "." "$branch" 2>/dev/null || true)
    if [ "$counted" -eq 0 ]; then
        tmp_free="$free_state.tmp.$$"
        if [ "$current_owner" != "$lock_owner" ] \
            || ! { cat "$free_state" 2>/dev/null || [ ! -e "$free_state" ]; } > "$tmp_free" \
            || ! printf '%s %s %s\n' "$start_r" "$start_head" "$start_class" >> "$tmp_free" \
            || ! mv "$tmp_free" "$free_state"; then  # prim-ok: tmp-then-mv under the counter lock; fixture copies of this script have no scripts/lib
            rm -f "$tmp_free"
            snap_drop
            start_unlock
            echo "review-round: cannot record the free $start_class round for $branch under the counter lock" >&2
            exit 5
        fi
    else
        tmp_state="$state.tmp.$$"
        if [ "$current_owner" != "$lock_owner" ] \
            || ! printf '%s\n' "$round" > "$tmp_state" \
            || ! mv "$tmp_state" "$state"; then  # prim-ok: tmp-then-mv under the counter lock; fixture copies of this script have no scripts/lib
            rm -f "$tmp_state"
            snap_drop
            start_unlock
            echo "review-round: cannot persist round $round for $branch under the counter lock" >&2
            exit 5
        fi
    fi
    # Record the head this round runs on, the next increment's start. Without
    # --head, or on a failed write, no head is kept, so a later round fails
    # closed instead of scoping from an older round.
    round_head=""
    if [ -n "$head_sha" ]; then
        round_head="$(git rev-parse --verify --quiet "$head_sha^{commit}" 2>/dev/null)" || round_head=""
    fi
    # A reviewed head this round replaces is kept in .head.prev, so a round
    # that reviews nothing can fall back to it; a first round has none.
    tmp_prev="$prev_state.tmp.$$"
    if [ "$round" -eq 1 ] && [ "$counted" -eq 1 ]; then
        rm -f "$prev_state"
    elif old_head="$(state_sha "$head_state")" && [ "$(ledger_query avail "$old_head")" = "ok" ]; then
        { printf '%s\n' "$old_head" > "$tmp_prev" && mv "$tmp_prev" "$prev_state"; } || rm -f "$tmp_prev" "$prev_state"  # prim-ok: start's tmp-then-mv idiom under the counter lock; this script does not source prim.sh
    fi
    tmp_head="$head_state.tmp.$$"
    if [ -z "$round_head" ] \
        || ! printf '%s\n' "$round_head" > "$tmp_head" \
        || ! mv "$tmp_head" "$head_state"; then  # prim-ok: tmp-then-mv under the counter lock; fixture copies of this script have no scripts/lib
        rm -f "$tmp_head" "$head_state" "$prev_state"
    fi
    tmp_scope="$scope_state.tmp.$$"
    if [ -z "$round_head" ] \
        || ! printf '%s %s %s\n' "$round_head" "$start_class" "$postcap" > "$tmp_scope" \
        || ! mv "$tmp_scope" "$scope_state"; then  # prim-ok: start's tmp-then-mv idiom under the counter lock; this script does not source prim.sh
        rm -f "$tmp_scope" "$scope_state"
    fi
    # Written under the counter lock, so the pid checks in delta_check and
    # abort and this claim cannot interleave between two starts.
    # Best effort - a failed write only loses the guard.
    printf '%s\n' "$rr_caller" > "$delta_run" 2>/dev/null || rm -f "$delta_run" 2>/dev/null
    if [ "$postcap" -eq 1 ]; then
        start_answer="$round delta $inc_l"
    elif [ "$start_class" != full ] && [ "$inc_empty" -eq 0 ]; then
        start_answer="$round increment $inc_l"
    else
        start_answer="$round"
    fi
    if [ "$snap_wrote" -eq 1 ] && ! snap_write after "$start_answer" "${snap_list[@]}"; then
        snap_drop
        start_unlock
        echo "review-round: persisted round $round for $branch but could not complete its snapshot - the round stays counted" >&2
        exit 5
    fi
    if ! SHARED_BRANCH_LOCK_NS=himmel-cr-review-round \
        bash "$lock_lib" release-if-owner "." "$branch" "$lock_owner" >/dev/null 2>&1; then
        snap_drop
        echo "review-round: persisted round $round for $branch but could not release its counter lock" >&2
        exit 5
    fi
    printf '%s\n' "$start_answer"
    exit 0
fi

# promote: the /pr-check flow writes verdict=agreed as a worker-agrees
# intermediate (write-verdicts.sh + step 4.5's ledger-append.sh amend) and
# nothing ever promotes it to a terminal verdict — until now it was only ever
# hand-amended to `fixed`. Given a CLEAN round at --head (the caller asserts
# this — promote does not itself re-check the panel, same posture as `defer`
# not re-running it), every `finding` row on --branch whose LATEST amend
# (joined on target_head + finding_id + artifact + perspective — NOT branch,
# since older rows can carry branch:"") is `agreed` is promoted to
# `fixed` UNLESS (a) its OWN row is recorded exactly at --head — a finding
# raised and agreed in the very round being certified clean has had no later
# commit that could have fixed it, so it is left agreed rather than stamped
# resolved on zero evidence — or (b) it is
# re-raised at --head: a DIFFERENT finding row on the same branch, at --head,
# sharing the same stored `fingerprint` (ledger-append.sh already computes
# this at write time — promote reads it, never recomputes it) whose OWN
# effective verdict is still live (empty/agreed/conflict/unaddressed/deferred,
# never fixed/disproved — a matching
# occurrence that is itself already fixed/disproved is not an open re-raise;
# `deferred` stays live — it means the issue
# is REAL and tracked, so it must not let an older occurrence be stamped
# fixed) — or (c) --head is not actually a git descendant of that finding own
# head (an unrelated or divergent --head
# never reviewed past that commit, so its absence there is not evidence of
# anything). Terminal rows (fixed/disproved/deferred) are left untouched;
# conflict/unaddressed were never agreed and are only WARNed. A finding whose
# stored fingerprint is empty (pre-fingerprint row, or no --text was ever
# supplied) cannot be safely checked for re-raise, so it is conservatively
# left agreed (counted as still-open) rather than guessed at. Idempotent: a
# second run sees the fixed amend via the same effective-state merge and
# skip-terminals it, writing nothing.
# A row whose effective verdict is EMPTY (no amend at all) is also still-open,
# tagged `(unadjudicated)`: nobody looked, so the round cannot be certified
# clean over it either — never counted as WARN (that means a human already
# disagreed) and never silently skipped.
# Exit 0 = no still-open findings; exit 3 = one or more rows are still-open
# (the caller's round was not actually clean for that finding, whether it was
# left agreed or never adjudicated at all); exit 1 = a malformed ledger row
# or a ledger write failure, or a finding row with a BLANK head and no later row
# that looks like its retry (same branch, finding id, model, severity, file,
# artifact and perspective, at a head that names a commit here). With such a row the blank
# one is skipped and counted and that row decides; the match is a heuristic and
# can pass a blank row that was not a retry; exit 2 = --head does not resolve to a commit;
# exit 5 = the CR ledger file itself is missing.
# `promote --check` is the same verdict as a read: every decision above is made from the ledger as it
# stands, then the amends are skipped (a promotable row prints `would-promote` and counts as promoted,
# as it will once the real verb runs), so it exits 0, 3, 1, 2 or 5 exactly as the real verb would on
# that ledger and writes nothing. The branch need not be the one checked out in cwd. Callers: the
# marker's --check-findings (the GO-time read of gate 4c), through which ready-check.sh item 18 reads it.
if [ "$verb" = "promote" ]; then
    if ! full_head="$(git rev-parse --verify --quiet "$head_sha^{commit}" 2>/dev/null)" || [ -z "$full_head" ]; then
        echo "review-round: --head $head_sha does not resolve to a commit" >&2
        exit 2
    fi
    ledger="$git_dir/cr-critic-scores.jsonl"
    if [ ! -f "$ledger" ]; then
        echo "review-round: CR ledger is missing at $ledger" >&2
        exit 5
    fi
    decisions_tmp="$(mktemp -t cr-promote-decisions.XXXXXX)" || { echo "review-round: cannot create scratch state" >&2; exit 1; }
    analysis="$(FULL_HEAD="$full_head" LEDGER="$ledger" BRANCH="$branch" DECISIONS_FILE="$decisions_tmp" AMEND_AUTH="$SCRIPT_DIR/ledger-amend-auth.js" node -e '
const fs = require("fs"), cp = require("child_process"), e = process.env;
const lines = fs.readFileSync(e.LEDGER, "utf8").split("\n").filter(Boolean);
const SEP = String.fromCharCode(31);
let malformed = 0;
const rows = [];
for (const line of lines) {
  let o;
  try { o = JSON.parse(line); } catch { malformed++; continue; }
  rows.push(o);
}
if (malformed !== 0) {
  process.stdout.write(JSON.stringify({malformed}));
  process.exit(0);
}
const commitCache = new Map();
function isCommit(value) {
  const h = String(value || "");
  if (!commitCache.has(h)) {
    let ok = false;
    try {
      cp.execFileSync("git", ["rev-parse", "--verify", "--quiet", h + "^{commit}"], {stdio: "ignore"});
      ok = true;
    } catch { ok = false; }
    commitCache.set(h, ok);
  }
  return commitCache.get(h);
}
const resolveCache = new Map();
function resolvesToHead(value) {
  const h = String(value || "");
  if (h === e.FULL_HEAD) return true;
  if (!/^[0-9a-f]{7,64}$/i.test(h)) return false;
  if (!resolveCache.has(h)) {
    let resolved = "";
    try {
      resolved = cp.execFileSync("git", ["rev-parse", "--verify", "--quiet", h + "^{commit}"],
        {encoding: "utf8", stdio: ["ignore", "pipe", "ignore"]}).trim();
    } catch { resolved = ""; }
    resolveCache.set(h, resolved);
  }
  return resolveCache.get(h) === e.FULL_HEAD;
}
// "not re-raised at --head" is only
// meaningful evidence of a fix when --head actually descends from the
// finding own commit — otherwise an unrelated or divergent clean head
// (a stale/incomparable --head) would let a later, never-reviewed commit
// findings get marked fixed with no real evidence either way.
const ancestorCache = new Map();
function isAncestorOfHead(commit) {
  const h = String(commit || "");
  if (!h) return false;
  if (h === e.FULL_HEAD) return true;
  if (!ancestorCache.has(h)) {
    let ok = false;
    try {
      cp.execFileSync("git", ["merge-base", "--is-ancestor", h, e.FULL_HEAD], {stdio: "ignore"});
      ok = true;
    } catch { ok = false; }
    ancestorCache.set(h, ok);
  }
  return ancestorCache.get(h);
}
// Merge every amend.set for a (branch, target_head, finding_id, artifact,
// perspective) key in ledger (chronological) order — a later amend field
// wins, a field a later amend never touched keeps its earlier value. Same
// shape as ledger-append.shs own amendsByKey/effective().
// The key gains branch, matching ledger-append.sh,
// clear-review-marker.sh and handover-bridge.sh byte-for-byte. Two
// branches can legitimately sit at the same head, and finding
// ids are minted in per-producer stream order (not globally unique), so an
// amend recorded while judging one branch must never leak into this gate
// judgment of another. A legacy amend row with an empty branch (written
// before branches were stamped) still applies to ANY branch — looked up
// through the same "" bucket every branch checks, merged under whatever
// branch-specific amend exists (branch-specific merges LAST and wins field
// conflicts, since every branch-specific amend post-dates the legacy ones).
const amendsByKey = new Map();
// Past the cutover only a signed lowering amend counts (ledger-amend-auth.js).
for (const o of require(e.AMEND_AUTH).filterRows(rows)) {
  if (o.kind !== "amend" || !o.set || typeof o.set !== "object") continue;
  const k = [o.branch || "", o.target_head, o.finding_id, o.artifact || "diff", o.perspective || "off"].join(SEP);
  amendsByKey.set(k, Object.assign({}, amendsByKey.get(k) || {}, o.set));
}
const amendSetFor = (branch, head, id, artifact, perspective) => {
  const legacy = amendsByKey.get(["", head, id, artifact, perspective].join(SEP));
  const scoped = amendsByKey.get([branch || "", head, id, artifact, perspective].join(SEP));
  return (legacy || scoped) ? Object.assign({}, legacy || {}, scoped || {}) : null;
};
const findingRows = rows.filter((o) => o.kind === "finding" && o.branch === e.BRANCH);
const atHead = findingRows.filter((o) => resolvesToHead(o.head));
// Only a LIVE occurrence at --head is a genuine re-raise: a matching finding at --head that is itself already
// fixed/disproved is a DISPOSITIONED instance, not an open one, and must not
// keep an older agreed row still-open forever just because its fingerprint
// once reappeared. deferred stays LIVE:
// deferred means the issue is REAL and tracked, never fixed, so a deferred
// reappearance must not let an older agreed occurrence of the SAME issue be
// promoted to fixed — that would be a false claim the code changed.
const liveVerdicts = new Set(["", "agreed", "conflict", "unaddressed", "deferred"]);
const fpAtHead = new Map();
for (const o of atHead) {
  if (!o.fingerprint) continue;
  const idKey = [o.head, o.finding_id, o.artifact || "diff", o.perspective || "off"].join(SEP);
  const effectiveAtHead = Object.assign({}, o, amendSetFor(o.branch || "", o.head, o.finding_id, o.artifact || "diff", o.perspective || "off") || {});
  if (!liveVerdicts.has(String(effectiveAtHead.verdict || "").trim())) continue;
  if (!fpAtHead.has(o.fingerprint)) fpAtHead.set(o.fingerprint, new Set());
  fpAtHead.get(o.fingerprint).add(idKey);
}
const outLines = [];
const blankRefused = [];
for (let ri = 0; ri < findingRows.length; ri++) {
  const row = findingRows[ri];
  if (!String(row.head || "").trim()) {
    // A row written with no head cannot be amended (amend finds a
    // row by head) and no later commit relates to it. It is skipped only when
    // a row that looks like its retry exists: written later in the ledger, on
    // this branch, at a head that names a commit here, with the same finding id, model,
    // severity, file, artifact and perspective. That row is judged on its own
    // below. Finding ids recur across PRs, so the id alone proves nothing, and
    // even this match is a heuristic: it can pass a blank row that was not a
    // retry. With no such row there is nothing to judge it by, and promote
    // refuses rather than guess.
    const hasTwin = !!row.finding_id && findingRows.some((t, ti) => ti > ri && /^[0-9a-f]{7,64}$/i.test(String(t.head || "")) && isCommit(t.head) &&
      t.finding_id === row.finding_id && (t.artifact || "diff") === (row.artifact || "diff") &&
      (t.perspective || "off") === (row.perspective || "off") && (t.model || "") === (row.model || "") &&
      (t.severity || "") === (row.severity || "") && (t.file || "") === (row.file || ""));
    if (hasTwin) outLines.push(JSON.stringify({action: "skip-blank-head", id: row.finding_id, head: "", branch: row.branch}));
    else blankRefused.push(row.finding_id || "(no id)");
    continue;
  }
  const idKey = [row.head, row.finding_id, row.artifact || "diff", row.perspective || "off"].join(SEP);
  const effective = Object.assign({}, row, amendSetFor(row.branch || "", row.head, row.finding_id, row.artifact || "diff", row.perspective || "off") || {});
  const verdict = String(effective.verdict || "").trim();
  let action;
  if (verdict === "fixed" || verdict === "disproved" || verdict === "deferred") action = "skip-terminal";
  else if (verdict === "conflict" || verdict === "unaddressed") action = "warn-unadjudicated";
  else if (verdict === "") action = "still-open-unadjudicated";
  else if (verdict !== "agreed") continue;
  else if ((row.artifact === "spec" || row.artifact === "plan") && effective.head && !/^[0-9a-f]{7,64}$/i.test(String(effective.head))) {
    // A design-skill finding (artifact exactly spec or plan, head not a commit
    // hex) edits a document outside the tree: no later commit could fix it, so
    // it can never be promoted. The head is the amended one, as in the sweep
    // gate, so a row re-keyed onto a commit stays open. An amend cannot set the
    // artifact, so it cannot relabel a code finding into this case.
    continue;
  } else if (resolvesToHead(row.head)) {
    // A finding raised (and agreed) AT the
    // very head being asserted clean has had no later commit that could have
    // fixed it — promoting it here would stamp an untouched, still-present
    // issue as resolved on zero evidence. Leave it agreed; it needs a real
    // disposition (a follow-up fix at a fresh head, or a deferral), the same
    // way the round-4 cap defers a same-head pending suggestion instead of
    // fabricating a fix for it.
    action = "still-open";
  } else if (!isAncestorOfHead(row.head)) {
    // Not an ancestor of --head: the clean round at --head never actually
    // reviewed past this commit, so its absence there proves nothing.
    action = "still-open";
  } else {
    const fp = effective.fingerprint || "";
    const present = fp ? fpAtHead.get(fp) : null;
    const reraised = !fp || (present && [...present].some((k) => k !== idKey));
    action = reraised ? "still-open" : "promote";
  }
  outLines.push(JSON.stringify({
    action, id: row.finding_id, head: row.head, branch: row.branch,
    artifact: row.artifact || "diff", perspective: row.perspective || "off", verdict,
  }));
}
fs.writeFileSync(e.DECISIONS_FILE, outLines.length ? outLines.join("\n") + "\n" : "");
process.stdout.write(JSON.stringify({malformed: 0, blank: blankRefused.join(", ")}));
' 2>/dev/null)"
    node_rc=$?
    malformed="$(printf '%s' "$analysis" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>process.stdout.write(String(JSON.parse(s).malformed)))' 2>/dev/null)" || malformed=""
    if [ "$node_rc" -ne 0 ] || [ -z "$malformed" ]; then
        rm -f "$decisions_tmp"
        echo "review-round: could not evaluate the ledger for promotion" >&2
        exit 1
    fi
    if [ "$malformed" -ne 0 ]; then
        rm -f "$decisions_tmp"
        echo "review-round: malformed CR ledger row(s) — refusing automatic promotion" >&2
        exit 1
    fi
    if ! blank_refused="$(printf '%s' "$analysis" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>process.stdout.write(String(JSON.parse(s).blank||"")))')"; then
        rm -f "$decisions_tmp"
        echo "review-round: could not evaluate the ledger for promotion" >&2
        exit 1
    fi
    if [ -n "$blank_refused" ]; then
        rm -f "$decisions_tmp"
        echo "review-round: finding row(s) with a blank head and no later row on $branch that looks like their retry (same finding id, model, severity, file, artifact and perspective, at a commit that exists here): $blank_refused - the ledger is append-only, so record each again with ledger-append.sh finding --head <sha>; nothing was promoted" >&2
        exit 1
    fi
    head8="$(printf '%s' "$full_head" | cut -c1-8)"
    promoted=0 still_open=0 skip_terminal=0 warn_count=0 blank_skipped=0 write_fail=0
    while IFS= read -r decision || [ -n "$decision" ]; do
        [ -n "$decision" ] || continue
        action="$(printf '%s' "$decision" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>process.stdout.write(JSON.parse(s).action))' 2>/dev/null)" || action=""
        id="$(printf '%s' "$decision" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>process.stdout.write(JSON.parse(s).id))' 2>/dev/null)" || id=""
        row_head="$(printf '%s' "$decision" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>process.stdout.write(JSON.parse(s).head))' 2>/dev/null)" || row_head=""
        row_branch="$(printf '%s' "$decision" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>process.stdout.write(JSON.parse(s).branch))' 2>/dev/null)" || row_branch=""
        row_artifact="$(printf '%s' "$decision" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>process.stdout.write(JSON.parse(s).artifact))' 2>/dev/null)" || row_artifact=""
        row_perspective="$(printf '%s' "$decision" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>process.stdout.write(JSON.parse(s).perspective))' 2>/dev/null)" || row_perspective=""
        row_verdict="$(printf '%s' "$decision" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>process.stdout.write(JSON.parse(s).verdict))' 2>/dev/null)" || row_verdict=""
        if [ "$action" = "skip-blank-head" ] && [ -n "$id" ]; then
            echo "skip-blank-head ${id} (blank head; the row at a real head decides)"
            blank_skipped=$((blank_skipped + 1))
            continue
        fi
        if [ -z "$action" ] || [ -z "$id" ] || [ -z "$row_head" ]; then
            write_fail=1
            break
        fi
        row_head8="$(printf '%s' "$row_head" | cut -c1-8)"
        case "$action" in
            promote)
                if [ "$check_only" -eq 1 ]; then
                    echo "would-promote ${id}@${row_head8}"
                    promoted=$((promoted + 1))
                    continue
                fi
                if ! CR_LEDGER="$ledger" bash "$SCRIPT_DIR/ledger-append.sh" amend \
                    --branch "$row_branch" --head "$row_head" --id "$id" \
                    --artifact "$row_artifact" --perspective "$row_perspective" \
                    --set verdict=fixed \
                    --reason "Promoted from agreed: no re-raise at clean round head $head8"; then
                    write_fail=1
                    break
                fi
                echo "promoted ${id}@${row_head8}"
                promoted=$((promoted + 1))
                ;;
            still-open)
                echo "still-open ${id}@${row_head8}"
                still_open=$((still_open + 1))
                ;;
            still-open-unadjudicated)
                echo "still-open ${id}@${row_head8} (unadjudicated)"
                still_open=$((still_open + 1))
                ;;
            skip-terminal)
                echo "skip-terminal ${id}@${row_head8} (verdict=${row_verdict})"
                skip_terminal=$((skip_terminal + 1))
                ;;
            warn-unadjudicated)
                echo "WARN unadjudicated ${id}@${row_head8} (verdict=${row_verdict})"
                warn_count=$((warn_count + 1))
                ;;
        esac
    done < "$decisions_tmp"
    rm -f "$decisions_tmp"
    if [ "$write_fail" -ne 0 ]; then
        echo "review-round: ledger write failed during promotion" >&2
        exit 1
    fi
    echo "review-round promote: $promoted promoted, $still_open still-open, $skip_terminal skip-terminal, $warn_count warn, $blank_skipped blank-head skipped (head $head8)"
    [ "$still_open" -eq 0 ] || exit 3
    exit 0
fi

read_round || exit $?

if [ "$round" -lt 1 ]; then
    echo "review-round: $branch is at round $round; automatic deferral starts at round 1 on a change that touches no CI trust path, round 4 otherwise" >&2
    exit 2
fi
if ! full_head="$(git rev-parse --verify --quiet "$head_sha^{commit}" 2>/dev/null)" || [ -z "$full_head" ]; then
    echo "review-round: --head $head_sha does not resolve to a commit" >&2
    exit 2
fi
ledger="$git_dir/cr-critic-scores.jsonl"
if [ ! -f "$ledger" ]; then
    echo "review-round: CR ledger is missing at $ledger" >&2
    exit 5
fi
scope_head="" scope_class="" scope_post=""
if [ -f "$scope_state" ] && [ ! -L "$scope_state" ]; then
    # swallow-ok: an unreadable .scope names no head, so the .delta and .round tests decide
    read -r scope_head scope_class scope_post _ < "$scope_state" 2>/dev/null || scope_head=""
fi
scope_known=0
if [ "$scope_head" = "$full_head" ] && { [ "$scope_post" = 0 ] || [ "$scope_post" = 1 ]; }; then scope_known=1; fi
delta_mode=0
if [ "$scope_known" -eq 1 ]; then
    [ "$scope_post" != 1 ] || delta_mode=1
elif [ "$round" -ge 4 ] && [ -f "$delta_state" ]; then
    delta_reviewed="$(awk '{print $2; exit}' "$delta_state" 2>/dev/null)" || delta_reviewed=""
    [ "$delta_reviewed" = "$full_head" ] && delta_mode=1
fi
early_close=0
if [ "$round" -lt 4 ] && [ "$delta_mode" -eq 0 ]; then early_close=1; fi
# Rounds 1 to 3 close early only when the change at --head matches no pattern
# in the default branch's ci-trust-paths.txt (trust_path_check, the question
# merge-on-green asks). The change is the branch's one open PR, headed at
# --head; any other gh answer (no PR, several, or a gh failure) asks the
# local-git mode about br-<branch> instead, whose <default>...<head> diff holds
# every file a PR diff would. Any answer but none, a refusal included, leaves
# the round-4 cap in force.
if [ "$early_close" -eq 1 ]; then
    early_refuse() {
        echo "review-round: $branch is at round $round; an early close needs $1 - automatic deferral starts at round 4" >&2
        exit 2
    }
    # shellcheck source=scripts/lib/timeout-bin.sh
    # shellcheck disable=SC1091
    . "$HIMMEL_ROOT/scripts/lib/timeout-bin.sh" 2>/dev/null || _TIMEOUT_BIN=""
    early_pr="$(${_TIMEOUT_BIN:+"$_TIMEOUT_BIN" -k 5 30} "${_RR_GH[@]}" pr list --head "$branch" --state open \
        --json number -q 'if length == 1 then .[0].number else "" end' 2>/dev/null)" || early_pr=""
    case "$early_pr" in
        ''|*[!0-9]*) early_pr="" ;;
    esac
    early_repo="$(${_TIMEOUT_BIN:+"$_TIMEOUT_BIN" -k 5 30} "${_RR_GH[@]}" repo view --json owner,name,defaultBranchRef \
        --jq '"\(.owner.login)/\(.name) \(.defaultBranchRef.name // "")"' 2>/dev/null)" || early_repo=""
    early_nwo="${early_repo%% *}"
    early_default="${early_repo#* }"
    case "$early_repo" in
        *" "*) ;;
        *) early_refuse "the repository and its default branch, and gh could not read them" ;;
    esac
    [ -n "$early_nwo" ] && [ -n "$early_default" ] \
        || early_refuse "the repository and its default branch, and gh could not read them"
    unset -f trust_path_check 2>/dev/null || true
    # shellcheck source=scripts/lib/go-gate.sh
    # shellcheck disable=SC1091
    if ! . "$HIMMEL_ROOT/scripts/lib/go-gate.sh" 2>/dev/null || ! declare -F trust_path_check >/dev/null 2>&1; then
        early_refuse "the trust-path check, and scripts/lib/go-gate.sh could not be loaded"
    fi
    if [ -n "$early_pr" ]; then
        early_what="PR #$early_pr"
        early_trust="$(trust_path_check "$early_nwo" "$early_pr" "$full_head" "$early_default" "$HIMMEL_ROOT")" || early_trust="refused ${early_trust:-with no reason}"
    else
        early_what="branch $branch"
        # swallow-ok: an empty common dir is refused on the next line (exit 2)
        early_common="$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || early_common=""
        [ -n "$early_common" ] \
            || early_refuse "the local trust-path check, and git could not resolve the common directory"
        early_trust="$(trust_path_check "local:$early_common" "br-$branch" "$full_head" "$early_default" "$HIMMEL_ROOT")" || early_trust="refused ${early_trust:-with no reason}"
    fi
    case "$early_trust" in
        none) ;;
        "hit "*) early_refuse "a PR that touches no CI trust path, and $early_what touches trust path ${early_trust#hit }" ;;
        *) early_refuse "a trust-path answer of none for $early_what, and the check said: $early_trust" ;;
    esac
fi
cap_reason='Suggestion deferred after the three-round /pr-check cap.'
delta_reason='Finding deferred in the one delta round after the three-round /pr-check cap.'
early_reason='Suggestion deferred: a Suggestions-only round 2 or later closes the review loop on a PR that touches no CI trust path.'
# An Important deferred in the second or third round because its ledger row
# carries the structured pre_existing field (an amend row critic-pre-existing-tag.py
# wrote after git blame placed the cited line before the PR). Never read from text.
pre_reason='Important finding deferred: the cited code is older than this PR (tagged pre-existing).'
# A polish Suggestion/nit files no ticket: its row is amended
# verdict=deferred, fu_class=polish with no deferred_to, and this reason.
note_reason='Polish finding noted in the PR body: no ticket filed (decisions 746, 762).'
amend_why='deferred by review-round.sh after the three-round cap'
if [ "$delta_mode" -eq 1 ]; then
    defer_reason="$delta_reason"
    round_label="the delta round"
elif [ "$round" -lt 4 ]; then
    defer_reason="$early_reason"
    round_label="round $round"
    amend_why='deferred by review-round.sh: a Suggestions-only round closes the loop on a non-trust PR'
else
    defer_reason="$cap_reason"
    round_label="round $round"
fi

pre_ok=0
if [ "$scope_known" -eq 1 ]; then
    if [ "$scope_post" = 0 ] && { [ "$scope_class" != full ] || [ "$round" -ge 2 ]; }; then pre_ok=1; fi
elif [ "$delta_mode" -eq 0 ] && { [ "$round" -eq 2 ] || [ "$round" -eq 3 ]; }; then pre_ok=1; fi
# shellcheck source=scripts/lib/load-dotenv.sh
# shellcheck disable=SC1091
if ! . "$HIMMEL_ROOT/scripts/lib/load-dotenv.sh" 2>/dev/null \
    || ! . "$HIMMEL_ROOT/scripts/lib/project-mode.sh" 2>/dev/null; then
    echo "review-round: could not load the tracker resolver (scripts/lib/load-dotenv.sh, scripts/lib/project-mode.sh); marker remains pending" >&2
    exit 6
fi
load_dotenv JIRA_PROJECT_KEY >/dev/null 2>&1 || true
if ! defer_tracker="$(project_mode_tracker)"; then
    echo "review-round: the tracker setting could not be resolved (see above); marker remains pending, nothing amended" >&2
    exit 6
fi
tracker_jira=0
if [ "$defer_tracker" = jira ]; then tracker_jira=1; fi
explicit_defer=0
if [[ $defer_to =~ ^[A-Z][A-Z0-9]*-[0-9]+$ ]]; then explicit_defer=1; fi
analysis="$(FULL_SHA="$full_head" LEDGER="$ledger" DELTA="$delta_mode" PRE_OK="$pre_ok" PRE_REASON="$pre_reason" CAP_REASON="$cap_reason" DEFER_REASON="$defer_reason" DELTA_REASON="$delta_reason" NOTE_REASON="$note_reason" TRACKER_JIRA="$tracker_jira" EXPLICIT_DEFER="$explicit_defer" AMEND_AUTH="$SCRIPT_DIR/ledger-amend-auth.js" node -e '
const fs = require("fs"), cp = require("child_process"), e = process.env;
const lines = fs.readFileSync(e.LEDGER, "utf8").split("\n").filter(Boolean);
const SEP = String.fromCharCode(31), amends = new Map(), findings = new Map();
let malformed = 0;
// Past the cutover only a signed lowering amend counts (ledger-amend-auth.js).
for (const line of require(e.AMEND_AUTH).filterLines(lines)) {
  let o;
  try { o = JSON.parse(line); } catch { malformed++; continue; }
  if (o.kind === "amend" && o.set && typeof o.set === "object") {
    const key = [o.target_head, o.finding_id, o.artifact || "diff", o.perspective || "off"].join(SEP);
    amends.set(key, Object.assign({}, amends.get(key) || {}, o.set));
  }
}
const cache = new Map();
function resolvesToHead(value) {
  const h = String(value || "");
  if (h === e.FULL_SHA) return true;
  if (!/^[0-9a-f]{7,64}$/.test(h) || !e.FULL_SHA.startsWith(h)) return false;
  if (!cache.has(h)) {
    let resolved = "";
    try { resolved = cp.execFileSync("git", ["rev-parse", "--verify", "--quiet", h + "^{commit}"], {encoding:"utf8", stdio:["ignore","pipe","ignore"]}).trim(); }
    catch { resolved = ""; }
    cache.set(h, resolved);
  }
  return cache.get(h) === e.FULL_SHA;
}
const origSeverities = new Map();
for (const line of lines) {
  let o;
  try { o = JSON.parse(line); } catch { continue; }
  if (o.kind !== "finding") continue;
  const raisedAs = String(o.severity || "");
  const original = [o.head, o.finding_id, o.artifact || "diff", o.perspective || "off"].join(SEP);
  if (amends.has(original)) o = Object.assign({}, o, amends.get(original));
  if (!resolvesToHead(o.head)) continue;
  const key = [o.finding_id || "?", o.artifact || "diff", o.perspective || "off"].join(SEP);
  if (!origSeverities.has(key)) origSeverities.set(key, raisedAs);
  findings.set(key, o);
}
const pending = [], capDeferred = [], blocking = [], unclassified = [];
const CAP_REASONS = [e.CAP_REASON, e.DELTA_REASON];
const RANK = {nit: 0, sug: 1, imp: 2, crit: 3};
const rankOf = (s) => (s in RANK ? RANK[s] : -1);
const severityRaisedWithWhenLowered = (raisedAs, effective) =>
  (raisedAs === "crit" || raisedAs === "imp") && rankOf(effective) < rankOf(raisedAs) ? raisedAs : effective;
function sugClass(fuClass) {
  if (fuClass === "escape") return {fu_class: "escape", class_source: "ledger"};
  if (fuClass === "hardening") return e.TRACKER_JIRA === "1" ? {fu_class: "hardening", class_source: "ledger"} : {fu_class: "polish", class_source: "default"};
  return {fu_class: "polish", class_source: fuClass === "polish" ? "ledger" : "default"};
}
function pendingRow(o, id, severity, fuClass, classSource, extra) {
  return Object.assign({
    id,
    artifact: o.artifact || "diff",
    perspective: o.perspective || "off",
    severity,
    fu_class: fuClass,
    fu_why: typeof o.fu_why === "string" ? o.fu_why.trim() : "",
    class: typeof o.class === "string" ? o.class.trim() : "",
    class_source: classSource,
    file: typeof o.file === "string" ? o.file : "",
    line: o.line === undefined || o.line === null ? "" : String(o.line),
    text: typeof o.text === "string" ? o.text.replace(/\s+/g, " ").trim() : ""
  }, extra || {});
}
for (const [key, o] of findings) {
  const id = String(o.finding_id || "?");
  const origSeverity = origSeverities.get(key) || "";
  const severity = severityRaisedWithWhenLowered(origSeverity, String(o.severity || ""));
  const verdict = typeof o.verdict === "string" ? o.verdict.trim() : "";
  const ticket = typeof o.deferred_to === "string" ? o.deferred_to.trim() : "";
  const reason = typeof o.reason === "string" ? o.reason.trim() : "";
  const trackedDeferred = verdict === "deferred" && /^[A-Z][A-Z0-9]*-[0-9]+$/.test(ticket) && reason;
  const notedPolish = verdict === "deferred" && !ticket && reason === e.NOTE_REASON &&
    (severity === "sug" || severity === "nit") && (origSeverity === "sug" || origSeverity === "nit") &&
    String(o.fu_class || "").trim() === "polish";
  const resolved = verdict === "disproved" || trackedDeferred || notedPolish;
  const settled = resolved || verdict === "fixed";
  if (e.DELTA === "1") {
    // The delta round blocks only on Critical or escape-class;
    // every other open finding is deferred. An Important needs an explicit
    // fu_class amend from the adjudicator first: an escape-class Important
    // is fixed in the PR, so it is never deferred by default.
    const fuClass = typeof o.fu_class === "string" ? o.fu_class.trim() : "";
    if ((severity === "crit" || fuClass === "escape") && !resolved) blocking.push(id);
    else if (!resolved && (!verdict || verdict === "agreed") && severity === "imp" && fuClass !== "hardening") unclassified.push(id);
    else if (!resolved && (!verdict || verdict === "agreed")) {
      const c = severity === "imp" ? {fu_class: fuClass, class_source: "ledger"} : sugClass(fuClass);
      pending.push(pendingRow(o, id, severity, c.fu_class, c.class_source));
    }
    else if (trackedDeferred && CAP_REASONS.includes(reason)) capDeferred.push({id, ticket});
    else if (notedPolish) capDeferred.push({id, ticket: ""});
    else if (!settled) blocking.push(id);
    continue;
  }
  // I1: a Critical is never deferred by the pre_existing field. Only the
  // boolean true on the effective row counts, never a [pre-existing] in text.
  const preExisting = e.PRE_OK === "1" && severity === "imp" && o.pre_existing === true;
  // The finding keeps its own class and none is forced: an escape-class Important
  // is fixed in the PR, and one with no class cannot be told from it, so only a
  // hardening or polish class from the adjudicator defers it.
  const preClass = typeof o.fu_class === "string" ? o.fu_class.trim() : "";
  if (preExisting && !resolved && (!verdict || verdict === "agreed")) {
    if (preClass === "hardening" || preClass === "polish") pending.push(pendingRow(o, id, severity, preClass, "ledger", {reason: e.PRE_REASON}));
    else if (preClass === "escape") blocking.push(id);
    else unclassified.push(id);
  }
  else if (preExisting && trackedDeferred && reason === e.PRE_REASON) capDeferred.push({id, ticket});
  else if ((severity === "crit" || severity === "imp") && !settled) blocking.push(id);
  else if ((severity === "sug" || severity === "nit") &&
           (!verdict || (verdict === "agreed" && (preClass === "escape" || preClass === "hardening")))) {
    const c = sugClass(preClass);
    if (c.fu_class === "escape") blocking.push(id);
    else if (!verdict || c.fu_class === "hardening") pending.push(pendingRow(o, id, severity, c.fu_class, c.class_source));
  }
  else if ((severity === "sug" || severity === "nit") && trackedDeferred &&
           reason === e.DEFER_REASON) {
    capDeferred.push({id, ticket});
  }
  else if (notedPolish) capDeferred.push({id, ticket: ""});
  else if (!verdict) blocking.push(id);
}
for (const f of pending) f.noted = e.EXPLICIT_DEFER !== "1" && f.fu_class === "polish" && (f.severity === "sug" || f.severity === "nit");
const noted = pending.filter((f) => f.noted);
process.stdout.write(JSON.stringify({malformed, pending, noted, capDeferred, blocking, unclassified}));
' 2>/dev/null)"
if [ -z "$analysis" ]; then
    echo "review-round: could not evaluate findings at $full_head" >&2
    exit 5
fi
malformed="$(printf '%s' "$analysis" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>process.stdout.write(String(JSON.parse(s).malformed)))' 2>/dev/null)" || malformed=""
blocking="$(printf '%s' "$analysis" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>process.stdout.write(JSON.parse(s).blocking.join(" ")))' 2>/dev/null)" || blocking=""
pending_count="$(printf '%s' "$analysis" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>process.stdout.write(String(JSON.parse(s).pending.length)))' 2>/dev/null)" || pending_count=""
cap_deferred_count="$(printf '%s' "$analysis" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>process.stdout.write(String(JSON.parse(s).capDeferred.length)))' 2>/dev/null)" || cap_deferred_count=""
if [ -z "$malformed" ] || [ -z "$pending_count" ] || [ -z "$cap_deferred_count" ]; then
    echo "review-round: could not parse the ledger evaluation" >&2
    exit 5
fi
if [ "$malformed" -ne 0 ]; then
    echo "review-round: malformed CR ledger row(s) — refusing automatic disposition" >&2
    exit 5
fi
if [ -n "$blocking" ] && [ "$delta_mode" -eq 1 ]; then
    echo "review-round: Critical or escape-class finding(s) remain blocking in the delta round: $blocking" >&2
    exit 4
fi
unclassified="$(printf '%s' "$analysis" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>process.stdout.write(JSON.parse(s).unclassified.join(" ")))' 2>/dev/null)" || unclassified=""
if [ -n "$unclassified" ] && [ "$delta_mode" -eq 0 ]; then
    echo "review-round: pre-existing Important finding(s) need an explicit fu_class amend before they can be deferred: $unclassified - amend each with --set fu_class=escape (fix it in this PR), --set fu_class=hardening (with its fu_why) or --set fu_class=polish, then re-run defer" >&2
    exit 4
fi
if [ -n "$unclassified" ]; then
    echo "review-round: Important finding(s) in the delta round need an explicit fu_class amend before they can be deferred: $unclassified - amend each with --set fu_class=escape (fix it in this PR) or --set fu_class=hardening (exactly; polish or any other class does not qualify), then re-run defer" >&2
    exit 4
fi
if [ -n "$blocking" ]; then
    echo "review-round: Critical, Important or escape-class finding(s) remain blocking at round $round: $blocking" >&2
    exit 4
fi
if [ "$pending_count" -eq 0 ] && [ "$cap_deferred_count" -eq 0 ]; then
    exit 0
fi

# Every pending hardening finding needs a valid reason of its own or the
# supplied --fu-why, checked once before anything is commented, filed or
# amended, so a refused run leaves nothing behind for a retry to repeat.
hardening_unreasoned="$(printf '%s' "$analysis" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{const ok=/^(unseen-failure|no-check|vacuous-check|no-recovery|silent-rot)$/;process.stdout.write(JSON.parse(s).pending.filter(f=>f.fu_class==="hardening"&&!ok.test(f.fu_why||"")).map(f=>f.id).join(" "))})')" || exit 5
if [ -n "$hardening_unreasoned" ]; then
    case "$fu_why_arg" in
        unseen-failure|no-check|vacuous-check|no-recovery|silent-rot) ;;
        *)
            echo "review-round: hardening finding(s) with no valid fu_why: $hardening_unreasoned; marker remains pending" >&2
            echo "review-round: supply --fu-why <unseen-failure|no-check|vacuous-check|no-recovery|silent-rot> to recover without rerunning the panel" >&2
            exit 6
            ;;
    esac
fi

# Decisions 746, 762: with no ticket the worker named, a polish
# Suggestion/nit files nothing (its row is amended below with no deferred_to), and
# a hardening finding is filed only with a named --fu-override. Both are checked
# here, once, before anything is commented, filed or amended, so a refused run
# leaves nothing behind for a retry to repeat.
ticketed_analysis="$analysis"
ticketed_count="$pending_count"
if [ "$explicit_defer" -eq 0 ] && [ "$pending_count" -gt 0 ]; then
    ticketed_analysis="$(printf '%s' "$analysis" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{const a=JSON.parse(s);a.pending=a.pending.filter(f=>!f.noted);process.stdout.write(JSON.stringify(a))})')" || exit 5
    ticketed_count="$(printf '%s' "$ticketed_analysis" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>process.stdout.write(String(JSON.parse(s).pending.length)))')" || exit 5
    polish_unnotable="$(printf '%s' "$ticketed_analysis" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>process.stdout.write(JSON.parse(s).pending.filter(f=>f.fu_class==="polish").map(f=>f.id).join(" ")))')" || exit 5
    if [ -n "$polish_unnotable" ]; then
        echo "review-round: pre-existing Important finding(s) classed polish cannot be noted without a ticket: $polish_unnotable; marker remains pending" >&2
        echo "review-round: polish is not filed (decisions 746, 762). Reclassify each with ledger-append.sh amend --set fu_class=hardening --set fu_why=<code> (then supply --fu-override <judge verdict id|decision-N>), or file a plain ticket someone will work, link it from the PR ticket with jira link <PR ticket> <plain ticket>, and supply --defer-to <plain ticket>" >&2
        exit 6
    fi
    if [ "$ticketed_count" -gt 0 ] && ! [[ $fu_override_arg =~ ^(decision-[0-9]+|[A-Z]{2}-j[0-9]+-[0-9]+)$ ]]; then
        echo "review-round: hardening finding(s) are filed only with a named override (decisions 746, 762); marker remains pending" >&2
        echo "review-round: supply --fu-override <judge verdict id of the form XX-jNNNN-N|decision-N> to file them (the id is printed into the ticket and not verified), or file a plain ticket, link it from the PR ticket with jira link <PR ticket> <plain ticket>, and supply --defer-to <plain ticket>; no ticket was filed" >&2
        exit 6
    fi
fi
# defer_to is a single small ticket-key string (well under the pipe
# buffer), so printf's write completes atomically before grep could exit
# early and SIGPIPE it.
# An early close with no --defer-to reuses the branch's batch residual. An
# unreadable or malformed key is not reused: a new batch replaces it.
batch_reused=0
if [ "$early_close" -eq 1 ] && ! [[ $defer_to =~ ^[A-Z][A-Z0-9]*-[0-9]+$ ]]; then
    # swallow-ok: an unreadable key is not reused; a new batch residual is filed instead
    batch_key="$(sed -n '1p' "$deferred_to_state" 2>/dev/null)" || batch_key=""
    if [[ $batch_key =~ ^[A-Z][A-Z0-9]*-[0-9]+$ ]]; then
        defer_to="$batch_key"
        batch_reused=1
    fi
fi
# The numbered finding list of a batch body or a reuse comment.
pending_list_js='let s="";process.stdin.on("data",d=>s+=d).on("end",()=>JSON.parse(s).pending.forEach((f,i)=>process.stdout.write((i+1)+". "+f.id+" (class: "+(f.class||"unclassified")+")\n"+(f.text?"   "+f.text+"\n":""))))'
primary_root="$HIMMEL_ROOT"
if [ "$pending_count" -gt 0 ]; then
    himmel_common="$(git -C "$HIMMEL_ROOT" rev-parse --git-common-dir 2>/dev/null)" || himmel_common=""
    if [ -n "$himmel_common" ]; then
        case "$himmel_common" in
            /*) ;;
            *) himmel_common="$HIMMEL_ROOT/$himmel_common" ;;
        esac
        resolved_primary="$(cd "$himmel_common/.." 2>/dev/null && pwd)" || resolved_primary=""
        [ -n "$resolved_primary" ] && primary_root="$resolved_primary"
    fi
fi
if [ "$tracker_jira" -eq 1 ] && [ "$explicit_defer" -eq 0 ]; then
    noted_list="$(mktemp -t cr-noted-list.XXXXXX)" || exit 5
    if ! printf '%s' "$analysis" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{for(const f of JSON.parse(s).noted) process.stdout.write(JSON.stringify({id:f.id,file:f.file,line:f.line,severity:f.severity,class_source:f.class_source,text:f.text})+"\n")})' > "$noted_list"; then
        rm -f "$noted_list"
        exit 5
    fi
    if [ -s "$noted_list" ]; then
        note_rc=0
        JIRA_CMD="node $primary_root/scripts/jira/dist/index.js" bash "$SCRIPT_DIR/note-polish.sh" \
            --branch "$branch" --head "$full_head" --list-file "$noted_list" || note_rc=$?
        if [ "$note_rc" -ne 0 ]; then
            rm -f "$noted_list"
            echo "review-round: could not record the polish finding(s) noted with no ticket on the PR ticket; marker remains pending" >&2
            echo "review-round: put the PR's ticket key in its title as [KEY-n] (or in the branch name), then rerun the same command" >&2
            exit 6
        fi
    fi
    rm -f "$noted_list"
fi
# A reused batch ticket gets this round's findings as a comment, before any
# ledger row points at it, so a failed comment leaves nothing to undo.
if [ "$batch_reused" -eq 1 ] && [ "$ticketed_count" -gt 0 ]; then
    batch_comment="$(mktemp -t cr-batch-comment.XXXXXX)" || exit 5
    if ! { printf 'Findings deferred on %s at %s:\n' "$branch" "$full_head" \
            && printf '%s' "$ticketed_analysis" | node -e "$pending_list_js"; } > "$batch_comment"; then
        rm -f "$batch_comment"
        exit 5
    fi
    comment_rc=0
    comment_out="$(JIRA_PROJECT_KEY=${defer_to%%-*} node "$primary_root/scripts/jira/dist/index.js" comment \
        "$defer_to" --comment-file "$batch_comment" 2>&1)" || comment_rc=$?
    rm -f "$batch_comment"
    if [ "$comment_rc" -ne 0 ]; then
        echo "review-round: could not add this round's findings to the batch residual $defer_to; marker remains pending. ${comment_out}" >&2
        echo "review-round: rerun the same command to retry the comment without filing another residual" >&2
        exit 6
    fi
fi
auto_defer=0
if [ "$ticketed_count" -gt 0 ] && ! printf '%s' "$defer_to" | grep -qE '^[A-Z][A-Z0-9]*-[0-9]+$'; then  # pipefail-ok: bounded small input, see comment above
    auto_defer=1
    # shellcheck source=scripts/lib/timeout-bin.sh
    # shellcheck disable=SC1091
    . "$HIMMEL_ROOT/scripts/lib/timeout-bin.sh" 2>/dev/null || _TIMEOUT_BIN=""
    pr_title="$(${_TIMEOUT_BIN:+"$_TIMEOUT_BIN" -k 5 30} "${_RR_GH[@]}" pr list --head "$branch" --state open \
        --json title -q 'if length == 1 then .[0].title else "" end' 2>/dev/null)" || pr_title=""
    residual_parent="$(printf '%s\n' "$pr_title" | grep -oE '[A-Z][A-Z0-9]*-[0-9]+' | sed -n '1p')" || residual_parent=""
    # An early close usually has no PR yet: the conventional-commit hook puts
    # a [KEY-n] in every subject, and the oldest one names the parent.
    if [ -z "$residual_parent" ] && [ "$early_close" -eq 1 ]; then
        residual_parent="$(git log --reverse --format=%s "refs/heads/$early_default..$full_head" 2>/dev/null \
            | grep -oE '\[[A-Z][A-Z0-9]*-[0-9]+\]' | sed -n '1{s/^\[//;s/\]$//;p;}')" || residual_parent=""
    fi
    if [ -z "$residual_parent" ]; then
        echo "review-round: $round_label cannot file residuals: no parent ticket in the one open PR title (or, before round 4, the branch's commit subjects); supply --defer-to <ticket> to resume without rerunning the panel" >&2
        exit 6
    fi
fi
# An early close files ONE batch residual for the whole round and remembers
# its key, so the loop below amends every finding to it and files nothing more.
if [ "$auto_defer" -eq 1 ] && [ "$early_close" -eq 1 ]; then
    batch_body="$(mktemp -t cr-batch-body.XXXXXX)" || exit 5
    if ! { cat "$HIMMEL_ROOT/scripts/cr/deferred-ticket-body.md" \
            && printf '\nFindings deferred on %s at %s:\n' "$branch" "$full_head" \
            && printf '%s' "$ticketed_analysis" | node -e "$pending_list_js"; } > "$batch_body"; then
        rm -f "$batch_body"
        exit 5
    fi
    # The batch takes the most severe class it holds. Suggestions and nits are
    # polish; a pre-existing Important may be hardening (escape never reaches a
    # deferral), and a hardening batch needs a valid reason, taken from its first
    # hardening finding or from --fu-why.
    if ! batch_why="$(printf '%s' "$analysis" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{const h=JSON.parse(s).pending.filter(f=>f.fu_class==="hardening");const ok=h.map(f=>f.fu_why).find(w=>/^(unseen-failure|no-check|vacuous-check|no-recovery|silent-rot)$/.test(w));process.stdout.write(h.length?(ok||"invalid"):"")})')"; then
        rm -f "$batch_body"
        exit 5
    fi
    batch_class=polish
    batch_why_args=()
    if [ -n "$batch_why" ]; then
        batch_class=hardening
        if [ "$batch_why" = invalid ]; then batch_why="$fu_why_arg"; fi
        case "$batch_why" in
            unseen-failure|no-check|vacuous-check|no-recovery|silent-rot) batch_why_args=(--fu-why "$batch_why" --fu-override "$fu_override_arg") ;;
            *)
                rm -f "$batch_body"
                echo "review-round: the batch holds a hardening finding but none has a valid fu_why; marker remains pending" >&2
                echo "review-round: supply --fu-why <unseen-failure|no-check|vacuous-check|no-recovery|silent-rot> to recover without rerunning the panel" >&2
                exit 6
                ;;
        esac
    fi
    create_rc=0
    created="$(JIRA_PROJECT_KEY=${residual_parent%%-*} node "$primary_root/scripts/jira/dist/index.js" create \
        --type Task --title "Review follow-ups for $branch" --sector 'Ship loop' --labels standalone \
        --desc-file "$batch_body" --residual-of "$residual_parent" --fu-class "$batch_class" ${batch_why_args[@]+"${batch_why_args[@]}"} \
        --new-reason "review-round: early-close batch residual for ${branch} at ${full_head}; no batch key was remembered for this branch")" || create_rc=$?
    rm -f "$batch_body"
    defer_to="$(printf '%s\n' "$created" | sed -nE 's/^Created ([A-Z][A-Z0-9]*-[0-9]+)$/\1/p')"
    if [ "$create_rc" -ne 0 ] || ! [[ $defer_to =~ ^[A-Z][A-Z0-9]*-[0-9]+$ ]]; then
        echo "review-round: could not file the batch residual for $branch; marker remains pending. ${created}" >&2
        echo "review-round: supply --defer-to <ticket> to recover without rerunning the panel" >&2
        exit 6
    fi
    if ! printf '%s\n' "$defer_to" > "$deferred_to_state.tmp.$$" \
        || ! mv "$deferred_to_state.tmp.$$" "$deferred_to_state"; then  # prim-ok: tmp-then-mv; fixture copies of this script have no scripts/lib
        rm -f "$deferred_to_state.tmp.$$"
        echo "review-round: filed $defer_to but could not record it in $deferred_to_state; marker remains pending" >&2
        echo "review-round: supply --defer-to $defer_to to recover without filing another residual" >&2
        exit 5
    fi
    auto_defer=0
fi

ids_tmp="$(mktemp -t cr-round-ids.XXXXXX)" || exit 5
verdicts_tmp="$(mktemp -t cr-round-verdicts.XXXXXX)" || { rm -f "$ids_tmp"; exit 5; }
if ! printf '%s' "$analysis" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{for(const finding of JSON.parse(s).pending) process.stdout.write(JSON.stringify(finding)+"\n")})' > "$ids_tmp" \
    || ! printf '%s' "$analysis" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{for(const finding of JSON.parse(s).capDeferred) if(finding.ticket) process.stdout.write("VERDICT ["+finding.id+"] = deferred -> "+finding.ticket+"\n")})' > "$verdicts_tmp"; then
    rm -f "$ids_tmp" "$verdicts_tmp"
    echo "review-round: could not prepare the deferred finding recovery state" >&2
    exit 5
fi
amend_rc=0
while IFS= read -r finding_identity || [ -n "$finding_identity" ]; do
    [ -n "$finding_identity" ] || continue
    finding_id="$(printf '%s' "$finding_identity" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>process.stdout.write(JSON.parse(s).id))' 2>/dev/null)" || finding_id=""
    artifact="$(printf '%s' "$finding_identity" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>process.stdout.write(JSON.parse(s).artifact))' 2>/dev/null)" || artifact=""
    perspective="$(printf '%s' "$finding_identity" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>process.stdout.write(JSON.parse(s).perspective))' 2>/dev/null)" || perspective=""
    fu_class="$(printf '%s' "$finding_identity" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>process.stdout.write(JSON.parse(s).fu_class))' 2>/dev/null)" || fu_class=""
    # A finding may carry its own deferral reason (a pre-existing Important);
    # the rest take the round's.
    finding_reason="$(printf '%s' "$finding_identity" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>process.stdout.write(JSON.parse(s).reason||""))' 2>/dev/null)" || finding_reason=""   # swallow-ok: an empty reason takes the round's reason
    if [ -z "$finding_id" ] || [ -z "$artifact" ] || [ -z "$perspective" ] || [ -z "$fu_class" ]; then
        amend_rc=5
        break
    fi
    finding_noted="$(printf '%s' "$finding_identity" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>process.stdout.write(JSON.parse(s).noted?"1":"0"))')" || finding_noted=""
    if [ "$finding_noted" != 0 ] && [ "$finding_noted" != 1 ]; then
        amend_rc=5
        break
    fi
    if [ "$finding_noted" = 1 ]; then
        if ! bash "$SCRIPT_DIR/ledger-append.sh" amend \
            --branch "$branch" --head "$full_head" --id "$finding_id" \
            --artifact "$artifact" --perspective "$perspective" \
            --set verdict=deferred --set fu_class=polish \
            --set class=unattributed --set "reason=$note_reason" \
            --reason "$amend_why"; then
            amend_rc=5
            break
        fi
        continue
    fi
    fu_why=""
    fu_why_args=()
    if [ "$fu_class" = "hardening" ]; then
        fu_why="$(printf '%s' "$finding_identity" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>process.stdout.write(JSON.parse(s).fu_why||""))')" || fu_why=""
        case "$fu_why" in
            unseen-failure|no-check|vacuous-check|no-recovery|silent-rot) ;;
            *) fu_why="$fu_why_arg" ;;
        esac
        case "$fu_why" in
            unseen-failure|no-check|vacuous-check|no-recovery|silent-rot) fu_why_args=(--fu-why "$fu_why" --fu-override "$fu_override_arg") ;;
            *)
                echo "review-round: finding $finding_id is hardening but has no valid fu_why; marker remains pending" >&2
                echo "review-round: supply --fu-why <unseen-failure|no-check|vacuous-check|no-recovery|silent-rot> to recover without rerunning the panel" >&2
                amend_rc=6
                break
                ;;
        esac
    fi
    if [ "$auto_defer" -eq 1 ]; then
        if ! finding_class="$(printf '%s' "$finding_identity" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>process.stdout.write(JSON.parse(s).class))')"; then
            amend_rc=5
            break
        fi
        if ! finding_text="$(printf '%s' "$finding_identity" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>process.stdout.write(JSON.parse(s).text||""))')"; then
            amend_rc=5
            break
        fi
        class_args=()
        body_file="$HIMMEL_ROOT/scripts/cr/deferred-ticket-body.md"
        body_tmp=""
        class_line=""
        if [ -n "$finding_class" ]; then
            class_args=(--class "$finding_class")
        else
            echo "review-round: finding $finding_id has no class id; omitting --class" >&2
            class_line='class: unclassified'
        fi
        if [ -n "$class_line" ] || [ -n "$finding_text" ]; then
            if ! body_tmp="$(mktemp -t cr-residual-body.XXXXXX)"; then
                amend_rc=5
                break
            fi
            if ! { cat "$body_file" \
                    && { [ -z "$class_line" ] || printf '\n%s\n' "$class_line"; } \
                    && { [ -z "$finding_text" ] || printf '\nFinding on %s at %s:\n%s\n' "$branch" "$full_head" "$finding_text"; }; } > "$body_tmp"; then
                rm -f "$body_tmp"
                amend_rc=5
                break
            fi
            body_file="$body_tmp"
        fi
        create_rc=0
        created="$(JIRA_PROJECT_KEY=${residual_parent%%-*} node "$primary_root/scripts/jira/dist/index.js" create \
            --type Task --title "Deferred /pr-check finding $finding_id" --sector 'Ship loop' --labels standalone \
            --desc-file "$body_file" \
            --residual-of "$residual_parent" --fu-class "$fu_class" ${fu_why_args[@]+"${fu_why_args[@]}"} ${class_args[@]+"${class_args[@]}"} \
            --new-reason "review-round: deferred finding ${finding_id} on ${branch} at ${full_head}; one residual per finding")" || create_rc=$?
        if [ -n "$body_tmp" ]; then rm -f "$body_tmp"; fi
        defer_to="$(printf '%s\n' "$created" | sed -nE 's/^Created ([A-Z][A-Z0-9]*-[0-9]+)$/\1/p')"
        if [ "$create_rc" -ne 0 ] || ! [[ $defer_to =~ ^[A-Z][A-Z0-9]*-[0-9]+$ ]]; then
            echo "review-round: could not file residual for $finding_id; marker remains pending. ${created}" >&2
            echo "review-round: supply --defer-to <ticket> to recover without rerunning the panel" >&2
            amend_rc=6
            break
        fi
    fi
    if ! bash "$SCRIPT_DIR/ledger-append.sh" amend \
        --branch "$branch" --head "$full_head" --id "$finding_id" \
        --artifact "$artifact" --perspective "$perspective" \
        --set verdict=deferred --set "deferred_to=$defer_to" --set "fu_class=$fu_class" ${fu_why:+--set "fu_why=$fu_why"} \
        --set class=unattributed --set "reason=${finding_reason:-$defer_reason}" \
        --reason "$amend_why"; then
        amend_rc=5
        break
    fi
    printf 'VERDICT [%s] = deferred -> %s\n' "$finding_id" "$defer_to" >> "$verdicts_tmp"
done < "$ids_tmp"
rm -f "$ids_tmp"
if [ "$amend_rc" -ne 0 ]; then
    rm -f "$verdicts_tmp"
    exit "$amend_rc"
fi

write_recovered_verdicts() {
    verdict_mode="$1"
    existing_verdicts="$2"
    merged_tmp="$(mktemp -t cr-round-merged.XXXXXX)" || return 5
    dedup_tmp="$(mktemp -t cr-round-dedup.XXXXXX)" || { rm -f "$merged_tmp"; return 5; }
    : > "$merged_tmp"
    if [ -f "$existing_verdicts" ] && ! cat "$existing_verdicts" >> "$merged_tmp"; then
        rm -f "$merged_tmp" "$dedup_tmp"
        return 5
    fi
    if ! cat "$verdicts_tmp" >> "$merged_tmp" \
        || ! awk 'NF && !seen[$0]++' "$merged_tmp" > "$dedup_tmp" \
        || ! bash "$SCRIPT_DIR/write-verdicts.sh" "$verdict_mode" --branch "$branch" < "$dedup_tmp"; then
        rm -f "$merged_tmp" "$dedup_tmp"
        return 5
    fi
    rm -f "$merged_tmp" "$dedup_tmp"
    return 0
}

if ! write_recovered_verdicts prior-blocking "$git_dir/cr-prior-blocking/$branch" \
    || ! write_recovered_verdicts aggregate "$git_dir/cr-aggregate-verdicts/$branch"; then
    rm -f "$verdicts_tmp"
    exit 5
fi
rm -f "$verdicts_tmp"
bash "$SCRIPT_DIR/clear-review-marker.sh" "$branch"
