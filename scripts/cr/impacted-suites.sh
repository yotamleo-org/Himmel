#!/usr/bin/env bash
# scripts/cr/impacted-suites.sh — which test suites exercise the files a PR
# changed.
#
# WHY. PR #2261 changed scripts/machine-setup/uninstall-plugins.sh and merged
# with scripts/test-uninstall.sh — a suite one directory UP that drives it end
# to end — never run: its implementor swept the owning directory, its certifier
# ran /pr-check, and nothing in the ship tail computed "which suites reference
# what this PR changed". Private main went red and it surfaced only on public
# CI. "Owning suites" was prose resolved by directory proximity; this is the
# structural replacement.
#
# Usage:
#   impacted-suites.sh [<base>..<head>] [--shell]
#       With no range, use $(git merge-base origin/main HEAD)..HEAD
#       — origin/HEAD's target when set — and print that range to stderr.
#       Print the union, one repo-relative path per line, sorted. For every
#       file changed between merge-base(<base>,<head>) and <head> (deletions
#       included, renames counted as delete+add), list each suite at <head>
#       whose text references the file's basename — or, for a slash command or
#       skill, `/<name>`. A changed *.sh whose stem holds a `-` or `_` is also
#       matched by its bare stem (`guard_rc block-foo`, no .sh).
#       A changed suite lists itself. --shell keeps only
#       test-*.sh (what run-shell-tests.sh can run); the *.test.mjs / .js / .ts
#       suites are listed without it and are run by their own runner — see
#       --runner below for which one.
#       The union is widened over shell SOURCE and repo IMPORT CLOSURES: a
#       suite reaching a changed file through sourced helpers or JS/Python
#       module imports (any depth) is listed too. A file that sets the
#       fence-lifting HIMMEL_UNINSTALL_REAL_HOME variable also lists the
#       path-scanning callers suite that never names it.
#   impacted-suites.sh --paths-file <path> <base>..<head> [--shell]
#       Query each newline-delimited path against the same head snapshot. Print
#       TSV path/suite rows, or path plus an empty field when none are selected.
#       An absent path is an add probe; an existing path is a content modify.
#       Uses the same selection function as a normal diff, with per-head setup
#       shared across queries. Refuses verdict/runner modes and symlink inputs.
#   impacted-suites.sh --selector-miss <base>..<head> --red-file <path>
#       Selector-miss evidence. <path> lists suites (one per line)
#       that went red on a main-push full sweep. For each red suite the PR's
#       selection did NOT list, print `selector-miss: <suite> <changed-file>`
#       per changed file of the range, exit 1; exit 0 and print nothing when
#       every red suite was selected. Meant to be called by the post-merge
#       full-sweep job with the merged
#       PR's range, and its rows kept as the miss ledger.
#   impacted-suites.sh --check <base>..<head> [--from-file <path>]
#       The verdict gate. Reads one line per impacted suite from stdin, or
#       from --from-file <path> when given: replaces the
#       cut inline heredoc/`<` redirect shapes — write the lines with a real
#       editing tool, then run ONE simple literal command naming the path):
#           SUITE <path> = PASS
#           SUITE <path> = SKIP <reason>          (reason required)
#           SUITE <path> = BLOCKED <denial>       (denial required)
#           SUITE <path> = CI                     (CI runs it)
#       `= CI` is accepted only for a test-*.sh the range did not change, that
#       scripts/handover/suite-coverage.sh says runs in PR CI, and never with
#       HIMMEL_SUITES_LOCAL=1 set; else `CI NOT ACCEPTED <path> (<reason>)` on
#       stderr, the suite counts as unverdicted, and the exit is 1.
#       Exit 0 when every impacted suite has a PASS, SKIP or accepted CI; exit 1,
#       naming each on stderr, when any is missing; exit 3 when every suite has a
#       verdict but one is BLOCKED — accounted for, yet the suite did not run,
#       so the /pr-check row is NOT clean until the chief/operator rules.
#       With --record --branch <b> --head <40-hex>, it first appends one
#       `impacted` row (counts, SKIP count, that exit code) to the git-common
#       CR ledger; the exit code is unchanged, and a failed append exits 4.
#       The range must end at --head and start from its merge-base with the
#       remote default branch, else exit 2 and no row.
#   impacted-suites.sh --plan <base>..<head>
#       Which impacted suites run on this machine and which are left to CI
#       (operator decision 775: little on the host, the rest in CI).
#       One line per suite: `LOCAL <path> (<reason>)` or `CI <path>`, then
#       `impacted-suites: plan N impacted, L local, C to CI`. LOCAL means the
#       suite the PR changed (run it, with its failing-first proof), a suite CI
#       cannot run (the reason is suite-coverage.sh's own words), or a
#       non-test-*.sh suite (no per-suite CI proof yet); every other
#       impacted test-*.sh is CI. HIMMEL_SUITES_LOCAL=1 plans every suite
#       LOCAL. Read-only; exit 0, or 2 on an unresolvable range; it cannot be
#       combined with --check or any other mode.
#   impacted-suites.sh --runner <path>
#       Print the ONE command CI uses to run a JS/TS suite path,
#       e.g. `node --test scripts/hooks/foo.test.mjs` or
#       `cd scripts/jira && npx vitest run src/foo.test.ts`. The map is read
#       off .github/workflows/ci.yml, never guessed — a path CI does not run
#       (or a runner directory this script does not yet know) refuses non-zero
#       naming the path, rather than defaulting to `bun test` (a
#       node:test suite can pass under node --test and fail under bun test on
#       an unrelated bun fs quirk — a false red no code change caused).
#   impacted-suites.sh --runner-check
#       Drift check over ci.yml's run: lines, naming the offending line, exit
#       1 on any of: (a) unmapped — a JS/TS test invocation (node --test, bun
#       test, npm test, a direct npx/bunx vitest or vitest run, or
#       check-hook-lib-suites.sh) that no known marker recognises; (b) drifted
#       — a recognised marker's line now invokes a DIFFERENT runner family
#       than --runner emits for it (e.g. a mapped suite's `node --test`
#       switched to `bun test`); (c) ambiguous — a single line names more than
#       one runner family (cannot attribute one runner to it), reported
#       distinctly and failed closed rather than guessed. Exit 0 when every
#       matched line is mapped, in-kind, and unambiguous.
#   impacted-suites.sh --run <path>
#       Run ONE impacted suite (a test-*.sh, or a JS/TS suite via --runner),
#       first installing its owning package's deps when the nearest
#       package.json ancestor has no node_modules (a fresh
#       worktree is created with --no-install, so every package but the jira
#       CLI starts with no node_modules — a worker running a suite raw sees a
#       false SKIP/FAIL it mislabels "pre-existing"). The install is frozen
#       and offline-first (npm ci / bun install --frozen-lockfile) from
#       whichever lockfile the package dir commits. A suite with no
#       package.json ancestor, or whose node_modules already exists, runs
#       unchanged. Exit 2, naming the package dir and the install command,
#       on a missing lockfile or a failed install — never a SKIP, never a
#       bare FAIL — before the suite itself ever runs.
#
# Exit codes: 0 ok / clean; 1 EITHER --check found a missing verdict OR
# --runner-check found an unmapped/drifted/ambiguous invocation — these are
# two distinct checks that never run in the same invocation, so the meaning
# of exit 1 is fixed by which flag was passed; 2 usage, an unresolvable
# range, a failed search, --runner found no mapping, or --run's dep install
# failed; 3 --check found a BLOCKED suite; 4 --record could not append its
# row. A range that cannot be resolved
# (or searched) is an ERROR, never an empty list: an empty impacted set reads
# as "nothing to run". --run otherwise exits with the suite's own exit code.
#
# ponytail: source edges and JS/Python imports are followed by basename.
# A suite that reaches a changed file through an intermediate shell script
# it EXECUTES (bash a.sh, no source line), or builds the path at runtime
# ("$dir/uninstall-$kind.sh"), is still not found — the union under-
# approximates there; the --selector-miss ledger is how such a gap surfaces, and
# a suite can widen its own text with the basename it really drives. A
# path-scanning suite is covered by content_rules, one row each.
# A basename shared by many files (lib.sh) over-approximates on purpose; the
# safe direction for a gate is a suite too many, never one too few.
#
# Platform guard: POSIX bash 3.2+ (no mapfile / associative arrays); git + grep.
set -uo pipefail
# A relative-entry copy that is not the anchor's hands off to it.
case "${BASH_SOURCE[0]}" in */*) _ah_d="${BASH_SOURCE[0]%/*}" ;; *) _ah_d=. ;; esac
. "$_ah_d/anchor-handoff.sh" || exit 2
is_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)" || exit 2

# io_fail <what> — a step that builds the impacted list or the verdict set did
# not run; an empty or partial list must never read as "nothing to run".
io_fail() {
    echo "impacted-suites: ${1} failed — cannot trust the impacted list" >&2
    exit 2
}

usage() {
    sed -n '2,/^set -uo/p' "$0" | sed -n 's/^# \{0,1\}//p' >&2
}

# runner_for <path> — print the ONE command CI uses to run a JS/TS suite path,
# read off .github/workflows/ci.yml. Exit 2, naming the path,
# for anything this table does not cover — never a guessed default (a
# node:test suite can genuinely disagree with `bun test` on an unrelated bun
# fs quirk, so guessing is not a safe fallback here).
runner_for() {
    local path="$1" rel
    case "$path" in
        scripts/hooks/*.test.mjs|scripts/lib/*.test.mjs|scripts/lanes/tests/*.test.mjs|scripts/trust/tests/*.test.mjs|scripts/where-are-we/tests/*.test.mjs|scripts/lessons/tests/*.test.mjs|scripts/op-env-parity.test.mjs|scripts/observability/*.test.mjs)
            printf 'node --test %q\n' "$path" ;;
        scripts/observability/*.test.ts)
            printf 'bun test %q --dots\n' "$path" ;;
        scripts/jira/*.test.ts)
            rel="${path#scripts/jira/}"
            printf 'cd scripts/jira && npx vitest run %q\n' "$rel" ;;
        scripts/bitbucket/*.test.ts)
            rel="${path#scripts/bitbucket/}"
            printf 'cd scripts/bitbucket && npx vitest run %q\n' "$rel" ;;
        scripts/himmel-run/*.test.ts)
            rel="${path#scripts/himmel-run/}"
            printf 'cd scripts/himmel-run && npx vitest run %q\n' "$rel" ;;
        scripts/ci-orchestrator/*.test.ts)
            rel="${path#scripts/ci-orchestrator/}"
            printf 'cd scripts/ci-orchestrator && npx vitest run %q\n' "$rel" ;;
        scripts/luna-vitals/*.test.mjs|scripts/luna-vitals/*.test.js|scripts/luna-vitals/*.test.ts)
            rel="${path#scripts/luna-vitals/}"
            printf 'cd scripts/luna-vitals && bun test %q\n' "$rel" ;;
        scripts/telegram/*.test.mjs|scripts/telegram/*.test.js|scripts/telegram/*.test.ts)
            printf 'bun test %q --dots\n' "$path" ;;
        scripts/vault/tests/*.test.mjs|scripts/vault/tests/*.test.js|scripts/vault/tests/*.test.ts)
            printf 'bun test %q --dots\n' "$path" ;;
        scripts/config-ui/tests/*.test.mjs|scripts/config-ui/tests/*.test.js|scripts/config-ui/tests/*.test.ts)
            printf 'bun test %q --dots\n' "$path" ;;
        marketplace/plugins/luna-correlate/*.test.mjs|marketplace/plugins/luna-correlate/*.test.js|marketplace/plugins/luna-correlate/*.test.ts)
            rel="${path#marketplace/plugins/luna-correlate/}"
            printf 'cd marketplace/plugins/luna-correlate && bun test %q\n' "$rel" ;;
        marketplace/plugins/telegram-himmel/*.test.mjs|marketplace/plugins/telegram-himmel/*.test.js|marketplace/plugins/telegram-himmel/*.test.ts)
            rel="${path#marketplace/plugins/telegram-himmel/}"
            printf 'cd marketplace/plugins/telegram-himmel && bun test %q\n' "$rel" ;;
        *)
            echo "impacted-suites.sh: --runner has no CI-runner mapping for '${path}' — refusing to guess" >&2
            return 2 ;;
    esac
}

# runner_known_markers — one `label|kind|locate` row per JS/TS invocation
# ci.yml is known to run today. `locate` is the literal substring that
# identifies the line (a path/glob, or the bare command for the ambiguous
# multi-directory cases); `kind` is the runner family runner_for's own
# command for that suite belongs to (node-test, bun-test, vitest, npm-test,
# or hook-lib — a script call, not a runner). Keep this list in lockstep with
# runner_for by hand; there is no way to derive one from the other without
# reimplementing the YAML.
#
# ponytail: this scans `run:` LINES only — a JS/TS test invocation written
# inside a `run: |` block scalar body (the command on a following indented
# line, not the `run:` line itself) is invisible to it. No current ci.yml step
# does this; widen the grep to a block-scalar-aware scan if one ever does.
#
# ponytail: the `npm test` marker (kind npm-test) matches by SUBSTRING only,
# with no directory context — it is satisfied by `npm test` run from ANY
# working directory, including a future one runner_for has no case for, and
# it cannot detect drift within itself (unlike the single-line markers below,
# nothing on the `run: npm test` line names which vitest directory it covers
# or would show a swap to a different runner there). Narrowing it means
# parsing ci.yml's `working-directory:` keys, which this grep-based check
# deliberately does not do — a line-level scan fails closed instead (see
# runner_check's ambiguous case) rather than guess at that attribution.
runner_known_markers() {
    cat <<'EOF'
lanes-node-suites|node-test|scripts/lanes/tests/**/*.test.mjs
trust-suites|node-test|scripts/trust/tests/*.test.mjs
hook-lib-suites|hook-lib|check-hook-lib-suites.sh
matrix-npm-test|npm-test|npm test
luna-vitals|bun-test|scripts/luna-vitals && bun install
telegram-suites|bun-test|scripts/telegram --dots
vault-suites|bun-test|scripts/vault/tests --dots
config-ui-suites|bun-test|scripts/config-ui --dots
luna-correlate|bun-test|marketplace/plugins/luna-correlate && bun install
telegram-himmel|bun-test|marketplace/plugins/telegram-himmel && bun install
where-are-we|node-test|scripts/where-are-we/tests/*.test.mjs
lessons|node-test|scripts/lessons/tests/*.test.mjs
op-env-observability-mjs|node-test|"scripts/observability/*.test.mjs"
observability|bun-test|scripts/observability --path-ignore-patterns=
EOF
}

# line_kind <line> — which runner family a run: line invokes, by literal
# substring, bash 3.2/grep-level (no YAML parsing). "ambiguous" when more than
# one family's substring appears on the same line — that line cannot be
# attributed to one runner, so runner_check fails it closed rather than guess.
line_kind() {
    local line="$1" n=0 kind=""
    case "$line" in *"node --test"*) n=$((n + 1)); kind=node-test ;; esac
    case "$line" in *"bun test"*|*"run-bun-tests.sh"*) n=$((n + 1)); kind=bun-test ;; esac
    case "$line" in *"npm test"*) n=$((n + 1)); kind=npm-test ;; esac
    case "$line" in *"npx vitest"*|*"bunx vitest"*|*"vitest run"*) n=$((n + 1)); kind=vitest ;; esac
    case "$line" in *"check-hook-lib-suites.sh"*) n=$((n + 1)); kind=hook-lib ;; esac
    if [ "$n" -gt 1 ]; then
        echo ambiguous
    elif [ "$n" -eq 0 ]; then
        echo unknown
    else
        echo "$kind"
    fi
}

runner_check() {
    local ci="$PWD/.github/workflows/ci.yml" line kind label exp_kind locate matched drift missing=0
    [ -f "$ci" ] || io_fail "reading ci.yml for --runner-check"
    while IFS= read -r line; do
        kind=$(line_kind "$line")
        if [ "$kind" = ambiguous ]; then
            echo "impacted-suites: --runner-check: ambiguous JS/TS test invocation — more than one runner family on one line, refusing to guess: ${line}" >&2
            missing=1
            continue
        fi
        matched=0
        drift=""
        while IFS='|' read -r label exp_kind locate; do
            case "$line" in
                *"$locate"*)
                    matched=1
                    [ "$exp_kind" = "$kind" ] || drift="${label} expects ${exp_kind}, ci.yml now runs ${kind}"
                    ;;
            esac
        done < <(runner_known_markers)
        if [ "$matched" -eq 0 ]; then
            echo "impacted-suites: --runner-check: ci.yml runs a JS/TS test invocation --runner does not map: ${line}" >&2
            missing=1
        elif [ -n "$drift" ]; then
            echo "impacted-suites: --runner-check: runner drift — ${drift}: ${line}" >&2
            missing=1
        fi
    done < <(grep -vE '^[[:space:]]*#' "$ci" | grep -E 'run:.*(node --test|bun test|run-bun-tests\.sh|npm test|npx vitest|bunx vitest|vitest run|check-hook-lib-suites\.sh)')
    [ "$missing" -eq 0 ]
}

# pkg_dir_for <suite_path> — the nearest ancestor directory (repo-relative,
# walking from the suite's own directory up to the repo root) that owns a
# package.json. Prints it and returns 0; returns 1 with no output when the
# suite has no package.json ancestor (a suite with no npm/bun deps at all).
pkg_dir_for() {
    local dir parent
    dir=$(dirname -- "$1")
    while :; do
        if [ -f "$dir/package.json" ]; then
            printf '%s\n' "$dir"
            return 0
        fi
        [ "$dir" = "." ] && return 1
        parent=$(dirname -- "$dir")
        [ "$parent" = "$dir" ] && return 1
        dir="$parent"
    done
}

# install_cmd_for <pkg_dir> — the ONE offline-first, frozen-lockfile install
# command for a package dir, chosen by the lockfile it commits
# (package-lock.json -> npm ci; bun.lock/bun.lockb -> bun install
# --frozen-lockfile). --ignore-scripts on both: a dependency's own postinstall
# reaching the network (a Playwright browser download N446) must
# never block or slow a test-dep install; nothing this table maps needs its
# own postinstall to run to be test-ready: every
# mapped package.json builds its TS via an explicit `pretest`/`build` script,
# never npm lifecycle). Exit 2, naming the dir, when NEITHER lockfile exists —
# a missing lockfile is a hard fail, never a guessed install.
install_cmd_for() {
    local dir="$1"
    if [ -f "$dir/package-lock.json" ]; then
        printf 'npm ci --no-audit --no-fund --ignore-scripts\n'
        return 0
    fi
    if [ -f "$dir/bun.lock" ] || [ -f "$dir/bun.lockb" ]; then
        printf 'bun install --frozen-lockfile --ignore-scripts\n'
        return 0
    fi
    echo "impacted-suites: no lockfile (package-lock.json or bun.lock) in '${dir}' — refusing to guess an install" >&2
    return 2
}

# ensure_deps <suite_path> — install a suite's owning package's deps when its
# node_modules is missing (a fresh worktree is created with
# --no-install, so every package but the jira CLI starts with none). No-op
# (exit 0, silent) for a suite with no package.json ancestor, or one whose
# node_modules already exists — "no change to suites that need no npm deps".
# Exit 2 on a missing lockfile or a failed install command: a loud, named
# failure carrying the package dir and the install command, never a SKIP and
# never a bare FAIL a worker could mislabel "pre-existing".
ensure_deps() {
    local suite="$1" dir cmd rc
    dir=$(pkg_dir_for "$suite") || return 0
    [ -d "$dir/node_modules" ] && return 0
    cmd=$(install_cmd_for "$dir") || { echo "impacted-suites: FAIL_INSTALL ${suite} — no lockfile in ${dir}" >&2; return 2; }
    echo "impacted-suites: installing deps for ${dir} (${cmd})" >&2
    rc=0
    (cd "$dir" && eval "$cmd") || rc=$?
    if [ "$rc" -ne 0 ]; then
        echo "impacted-suites: FAIL_INSTALL ${suite} — '${cmd}' failed in ${dir} (rc=${rc})" >&2
        return 2
    fi
    echo "impacted-suites: installed deps for ${dir}" >&2
    return 0
}

# run_suite <suite_path> — ensure_deps, then run the suite: its own CI runner
# command for a JS/TS path (via runner_for), or `bash <path>` for a
# test-*.sh. Propagates ensure_deps's exit 2 (never runs a suite whose deps
# failed to install) and otherwise the suite's own exit code.
run_suite() {
    local path="$1" cmd
    case "$path" in
        ./*) path="${path#./}" ;;
    esac
    ensure_deps "$path" || return 2
    case "$path" in
        *.test.mjs|*.test.js|*.test.ts)
            cmd=$(runner_for "$path") || return 2
            eval "$cmd"
            return $? ;;
        *)
            bash "$path"
            return $? ;;
    esac
}

check=0
plan=0
shell_only=0
range=""
runner_path=""
runner_check_mode=0
run_path=""
from_file=""
selector_miss=0
red_file=""
paths_file=""
record=0
rec_branch=""
rec_head=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        --check) check=1; shift ;;
        --plan) plan=1; shift ;;
        --record) record=1; shift ;;
        --branch)
            [ "$#" -ge 2 ] || { echo "impacted-suites.sh: --branch requires a name" >&2; exit 2; }
            rec_branch="$2"; shift 2 ;;
        --head)
            [ "$#" -ge 2 ] || { echo "impacted-suites.sh: --head requires a SHA" >&2; exit 2; }
            rec_head="$2"; shift 2 ;;
        --shell) shell_only=1; shift ;;
        --from-file)
            [ "$#" -ge 2 ] || { echo "impacted-suites.sh: --from-file requires a path" >&2; exit 2; }
            from_file="$2"; shift 2 ;;
        --runner)
            [ "$#" -ge 2 ] || { echo "impacted-suites.sh: --runner requires a path" >&2; exit 2; }
            runner_path="$2"; shift 2 ;;
        --runner-check) runner_check_mode=1; shift ;;
        --selector-miss) selector_miss=1; shift ;;
        --paths-file)
            [ "$#" -ge 2 ] || { echo "impacted-suites.sh: --paths-file requires a path" >&2; exit 2; }
            paths_file="$2"; shift 2 ;;
        --red-file)
            [ "$#" -ge 2 ] || { echo "impacted-suites.sh: --red-file requires a path" >&2; exit 2; }
            red_file="$2"; shift 2 ;;
        --run)
            [ "$#" -ge 2 ] || { echo "impacted-suites.sh: --run requires a path" >&2; exit 2; }
            run_path="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        -*) echo "impacted-suites.sh: unknown flag: $1" >&2; exit 2 ;;
        *)
            if [ -n "$range" ]; then
                echo "impacted-suites.sh: unexpected argument: $1" >&2; exit 2
            fi
            range="$1"; shift ;;
    esac
done

if [ -n "$paths_file" ]; then
    if [ "$check" -eq 1 ] || [ "$selector_miss" -eq 1 ] || [ -n "$runner_path" ] || [ "$runner_check_mode" -eq 1 ] || [ -n "$run_path" ]; then
        echo "impacted-suites.sh: --paths-file cannot be combined with verdict or runner modes" >&2; exit 2
    fi
    if [ -L "$paths_file" ] || [ ! -f "$paths_file" ] || [ ! -r "$paths_file" ]; then
        echo "impacted-suites.sh: --paths-file is not a readable regular file (symlinks refused): $paths_file" >&2; exit 2
    fi
    case "$paths_file" in /*) ;; *) paths_file="$PWD/$paths_file" ;; esac
fi

if [ "$plan" -eq 1 ] && { [ "$check" -eq 1 ] || [ "$record" -eq 1 ] || [ -n "$from_file" ] || [ "$selector_miss" -eq 1 ] || [ -n "$paths_file" ] || [ -n "$runner_path" ] || [ "$runner_check_mode" -eq 1 ] || [ -n "$run_path" ]; }; then
    echo "impacted-suites.sh: --plan is its own mode: it cannot be combined with --check, --record, --from-file, --selector-miss, --paths-file, --runner, --runner-check or --run" >&2; exit 2
fi
if [ "$record" -eq 1 ] && { [ "$check" -eq 0 ] || [ -z "$rec_branch" ] || [ -z "$rec_head" ]; }; then
    echo "impacted-suites.sh: --record requires --check, --branch <name> and --head <sha>" >&2; exit 2
fi
if [ "$record" -eq 0 ] && { [ -n "$rec_branch" ] || [ -n "$rec_head" ]; }; then
    echo "impacted-suites.sh: --branch and --head require --record" >&2; exit 2
fi
if [ -n "$from_file" ] && [ "$check" -eq 0 ]; then
    echo "impacted-suites.sh: --from-file requires --check" >&2; exit 2
fi
if [ "$selector_miss" -eq 1 ] && [ "$check" -eq 1 ]; then
    echo "impacted-suites.sh: --selector-miss and --check are separate modes" >&2; exit 2
fi
if [ "$selector_miss" -eq 1 ] && [ -z "$red_file" ]; then
    echo "impacted-suites.sh: --selector-miss requires --red-file <path>" >&2; exit 2
fi
if [ -n "$red_file" ] && [ "$selector_miss" -eq 0 ]; then
    echo "impacted-suites.sh: --red-file requires --selector-miss" >&2; exit 2
fi
if [ -n "$red_file" ]; then
    if [ -L "$red_file" ] || [ ! -f "$red_file" ] || [ ! -r "$red_file" ]; then
        echo "impacted-suites.sh: --red-file is not a readable regular file (symlinks refused): $red_file" >&2; exit 2
    fi
fi
# Same fail-closed contract as write-verdicts.sh's
# --from-file — refuse a symlinked, missing or unreadable path before the
# --check awk ever reads it. A genuinely empty regular file is NOT refused:
# /pr-check's own runbook mandates an empty --from-file when zero suites are
# impacted, and --check's own n_impacted/n_missing reconciliation below
# already catches an empty file paired with a NON-empty impacted set (it is
# computed independently, from the diff, not from this file).
if [ -n "$from_file" ]; then
    if [ -L "$from_file" ]; then
        echo "impacted-suites.sh: refusing to read through a symlink at $from_file" >&2; exit 2
    fi
    if [ ! -f "$from_file" ]; then
        echo "impacted-suites.sh: --from-file path does not exist or is not a regular file: $from_file" >&2; exit 2
    fi
    if [ ! -r "$from_file" ]; then
        echo "impacted-suites.sh: --from-file path is not readable: $from_file" >&2; exit 2
    fi
    exec < "$from_file"
fi

if [ -n "$runner_path" ]; then
    runner_for "$runner_path"
    exit $?
fi
if [ "$runner_check_mode" -eq 1 ]; then
    top=$(git rev-parse --show-toplevel) || { echo "impacted-suites.sh: not inside a git work tree" >&2; exit 2; }
    cd "$top" || exit 2
    if runner_check; then
        exit 0
    else
        exit 1
    fi
fi
if [ -n "$run_path" ]; then
    top=$(git rev-parse --show-toplevel) || { echo "impacted-suites.sh: not inside a git work tree" >&2; exit 2; }
    cd "$top" || exit 2
    run_suite "$run_path"
    exit $?
fi

# No range = merge-base(default branch, HEAD)..HEAD, announced on
# stderr. Sourced only here: CI always passes a range, and its base-extracted
# copy (scripts/ci/impacted-selection.sh) carries no scripts/lib.
if [ -z "$range" ]; then
    # shellcheck source=scripts/lib/review-default-base.sh
    # shellcheck disable=SC1091
    case "${BASH_SOURCE[0]}" in */*) _is_d="${BASH_SOURCE[0]%/*}" ;; *) _is_d=. ;; esac
    . "$_is_d/../lib/review-default-base.sh" || exit 2
    if ! default_ref=$(cr_default_base_ref); then
        echo "impacted-suites.sh: no range given and neither origin/HEAD nor origin/main resolves; run: git fetch origin" >&2
        echo "  then re-run: bash scripts/cr/impacted-suites.sh" >&2
        exit 2
    fi
    if ! default_mb=$(git merge-base "$default_ref" HEAD); then
        if [ "$(git rev-parse --is-shallow-repository 2>/dev/null)" = true ]; then
            echo "impacted-suites.sh: no range given and ${default_ref} shares no history with this shallow HEAD; run: git fetch --unshallow origin" >&2
            echo "  then re-run: bash scripts/cr/impacted-suites.sh" >&2
        else
            echo "impacted-suites.sh: no range given and ${default_ref} shares no history with HEAD (unrelated, not shallow); pass an explicit range: bash scripts/cr/impacted-suites.sh <base>..HEAD" >&2
        fi
        exit 2
    fi
    range="${default_mb}..HEAD"
    echo "impacted-suites.sh: no range given; using ${range} (merge-base of ${default_ref#refs/remotes/} and HEAD)" >&2
fi

case "$range" in
    *..*) ;;
    *) echo "impacted-suites.sh: expected <base>..<head>, got '${range}'" >&2; exit 2 ;;
esac
base="${range%%..*}"
head="${range#*..}"
head="${head#.}"   # tolerate <base>...<head>
if [ -z "$base" ] || [ -z "$head" ]; then
    echo "impacted-suites.sh: expected <base>..<head>, got '${range}'" >&2; exit 2
fi

# git ls-tree and git grep are scoped to the cwd while git diff emits
# repo-relative paths: from a subdirectory the suites above it would drop out.
if ! top=$(git rev-parse --show-toplevel) || ! cd "$top"; then
    echo "impacted-suites.sh: not inside a git work tree" >&2; exit 2
fi

if ! base_sha=$(git rev-parse --verify --quiet --end-of-options "${base}^{commit}"); then
    echo "impacted-suites.sh: base '${base}' does not resolve to a commit" >&2; exit 2
fi
if ! head_sha=$(git rev-parse --verify --quiet --end-of-options "${head}^{commit}"); then
    echo "impacted-suites.sh: head '${head}' does not resolve to a commit" >&2; exit 2
fi
if ! mb=$(git merge-base "$base_sha" "$head_sha"); then
    echo "impacted-suites.sh: no merge-base between '${base}' and '${head}'" >&2; exit 2
fi
# -z, because without it git C-quotes a name holding a double quote,
# backslash or tab ("a\"b.sh"): no needle matched it and the run listed nothing
# and exited 0. -z output is raw; tr turns it into the one-per-line lists the
# loops below read. ponytail: a name holding a newline still splits in two (a
# bogus path, never a missed one); upgrade path is NUL-reading loops if one ever appears.
# --record certifies the whole PR at --head: the range must end at that head
# and start from its merge-base with the remote default branch.
if [ "$record" -eq 1 ]; then
    if [ "$head_sha" != "$rec_head" ]; then
        echo "impacted-suites.sh: --record --head ${rec_head} is not the range's head (${head_sha})" >&2; exit 2
    fi
    case "${BASH_SOURCE[0]}" in */*) _is_d="${BASH_SOURCE[0]%/*}" ;; *) _is_d=. ;; esac
    # shellcheck source=scripts/lib/review-default-base.sh
    # shellcheck disable=SC1091
    . "$_is_d/../lib/review-default-base.sh" || exit 2
    if ! rec_ref=$(cr_default_base_ref) || ! rec_mb=$(git merge-base "$rec_ref" "$head_sha") || [ "$rec_mb" != "$mb" ]; then
        echo "impacted-suites.sh: --record needs a range from the merge-base of the remote default branch and ${head_sha}" >&2; exit 2
    fi
fi
if ! changed=$(git diff -z --name-only --no-renames "$mb" "$head_sha" | tr '\0' '\n'); then
    echo "impacted-suites.sh: git diff ${mb}..${head_sha} failed" >&2; exit 2
fi
if ! tree=$(git ls-tree -r -z --name-only "$head_sha" | tr '\0' '\n'); then
    echo "impacted-suites.sh: git ls-tree ${head_sha} failed" >&2; exit 2
fi

# prim-ok: impacted-selection.sh extracts a BASE-commit copy of this script into a temp dir with no scripts/lib, so it cannot source prim.sh
work=$(mktemp -d "${TMPDIR:-/tmp}/impacted-suites.XXXXXX") || { echo "impacted-suites.sh: mktemp failed" >&2; exit 2; }
trap 'rm -rf "$work"' EXIT
pats="$work/patterns"
lits="$work/literals"   # HIMMEL-5363: one literal per pattern in $pats, see grep_narrowed
found="$work/found"
: > "$pats"
: > "$lits"
: > "$found"

suite_re='(^|/)test-[^/]*\.sh$|\.test\.(mjs|js|ts)$'
# No here-string or here-document below carries the tree, the changed
# list or the suite list. A here-string goes through a temp file once it outgrows a
# pipe (always, on bash before 5.1); on a full temp dir it fails, the command never
# runs and its rc 1 read as "no match" — a short list at rc 0. A checked write to a
# file under $work fails closed instead, and every later read is a plain file.
printf '%s\n' "$tree" > "$work/tree" || io_fail "writing the tree listing"
printf '%s\n' "$changed" > "$work/changed" || io_fail "writing the changed-file list"
suites="$work/suites"   # the suite paths at head, one per line
# Create each output file in a checked step first: a redirect that cannot open its
# target also returns rc 1, which `|| grep_rc=$?` below would read as "none".
: > "$suites" || io_fail "creating the suite list"
grep_rc=0
grep -E "$suite_re" "$work/tree" > "$suites" || grep_rc=$?   # rc 1 = none
[ "$grep_rc" -le 1 ] || io_fail "listing suites"
# Basenames that name nothing on their own: match them by "<parent>/<name>"
# (a repo-root file has no parent, so it falls back to the bare name).
generic_re='^(README\.md|CLAUDE\.md|SKILL\.md|CHANGELOG\.md|index\.(js|mjs|ts)|package\.json|package-lock\.json|\.gitignore|LICENSE)$'

# needle_ere <literal> — one ERE per needle: a literal bounded so `install.sh`
# never matches `uninstall.sh` and `/pr-check` never matches `/pr-check_x`.
needle_ere() {
    local esc
    esc=$(printf '%s' "$1" | sed 's/[.[\*^$+?(){}|]/\\&/g') || io_fail "escaping a needle"
    case "$1" in
        # A `/name` needle (extensionless file) is its own boundary:
        # it matches `guard-corpus/diff`, the full path and a variable-built
        # `$HERE/diff`, but never a bare `diff -u`.
        /*) printf '%s($|[^A-Za-z0-9_-])' "$esc" ;;
        *) printf '(^|[^A-Za-z0-9_.-])%s($|[^A-Za-z0-9_-])' "$esc" ;;
    esac
}
# needle_tail_ere <literal> — the needle without its leading boundary, for a
# caller whose own pattern already ends in the separating character.
needle_tail_ere() {
    local esc
    esc=$(printf '%s' "$1" | sed 's/[.[\*^$+?(){}|]/\\&/g') || io_fail "escaping a needle"
    printf '%s($|[^A-Za-z0-9_-])' "$esc"
}
add_needle() {
    { needle_ere "$1"; printf '\n'; } >> "$pats" || io_fail "writing a needle"
    printf '%s\n' "$1" >> "$lits" || io_fail "writing a needle literal"
}
# add_stem_needle <path> — a suite often names a script without its
# extension (`guard_rc block-chokepoint-env-prefix`), so a changed *.sh whose
# stem holds a `-` or `_` also gets its bare stem as a needle. A one-word stem
# (`gate`, `run`) is a common word and is skipped. The leading boundary is
# needle_ere's, so `test-<stem>` and `x-<stem>` are other words; the trailing one
# also refuses `.`, so `<stem>.bak` and a longer `<stem>-extra` are not matched
# (the basename needle already matches `<stem>.sh`).
# ponytail: a sentence-final `<stem>.` is missed, and a stem shared by two
# directories over-approximates; upgrade path is a --selector-miss row naming one.
add_stem_needle() {
    local st="${1##*/}" esc
    case "$st" in *.sh) st="${st%.sh}" ;; *) return 0 ;; esac
    case "$st" in *[-_]*) ;; *) return 0 ;; esac
    esc=$(printf '%s' "$st" | sed 's/[.[\*^$+?(){}|]/\\&/g') || io_fail "escaping a stem needle"
    printf '(^|[^A-Za-z0-9_.-])%s($|[^A-Za-z0-9_.-])\n' "$esc" >> "$pats" || io_fail "writing a stem needle"
    printf '%s\n' "$st" >> "$lits" || io_fail "writing a stem needle literal"
}

# file_literal <path> [src] — the text a suite would use to name the file: its
# basename, or "<parent>/<name>" for a generic one. A single-word extensionless
# basename (`diff`, `gen`, `gh`: no `.`, `-` or `_`) is a common word, so it is
# named `/<name>` (scripts/eval/guard-corpus/diff listed 362 suites
# on a bare `diff`). A distinctive one (`claude-deepseek`, `BASE_SHA`) keeps the
# bare name, since a quoted `'claude-deepseek'` has no `/` before it. The source
# and assignment closures take the same literal (a bare `diff` on an assignment
# line pulled in hundreds of suites); `cg` wants the parent too.
file_literal() {
    local f="$1" name="${1##*/}" parent
    if [[ $name =~ $generic_re ]]; then
        case "$f" in
            */*) parent="${f%/*}"; printf '%s/%s\n' "${parent##*/}" "$name" ;;
            # Repo root: no parent to qualify it, so the bare name is the only
            # needle — it also matches sub-directory copies (over-approximates).
            *) printf '%s\n' "$name" ;;
        esac
    elif [ "${f#*/}" != "$f" ] && case "$name" in *[-_.]*) false ;; *) true ;; esac; then
        # `cg` (the guarded closure scans non-test scripts, where `</diff>` and
        # `head/diff` matched a bare `/diff`) wants the parent too.
        if [ "${2:-}" = cg ]; then
            parent="${f%/*}"; printf '%s/%s\n' "${parent##*/}" "$name"
        else
            printf '/%s\n' "$name"
        fi
    else
        printf '%s\n' "$name"
    fi
}

src_lead='(^[[:space:]]*[({]?|^[[:space:]]*[^#[:space:]].*[[:space:];&|({])'
# bare_source_ere <path> for a nested single-word extensionless
# file (the ones file_literal names `/<name>`), two EREs that match a reference
# with no `/` before the name, which `/<name>` misses: a `source`/`.` operand
# after a `cd` (`cd dir && source diff`) and `# shellcheck source=diff`. Only a
# line that sources it counts, so a plain `diff a b` command stays unselected.
# Prints nothing for any other file.
# ponytail: `cd dir && bash diff` and "$dir/$f" with f=diff stay unfound (no
# source keyword to anchor on); upgrade path is a lint on new suites if a
# --selector-miss row ever names one.
bare_source_ere() {
    local f="$1" name="${1##*/}"
    [ "${f#*/}" != "$f" ] || return 0
    [[ $name =~ $generic_re ]] && return 0
    case "$name" in *[-_.]*) return 0 ;; esac
    # $2: the literal file the caller's grep_narrowed pass reads (the bare name).
    printf '%s\n' "$name" >> "$2" || return 1
    { printf '%s(source|\\.)[[:space:]]+(--[[:space:]]+)?["'"'"']?([^[:space:]"'"'"']*/)?' "$src_lead"; needle_tail_ere "$name"; printf '\n'; } || return 1
    { printf 'shellcheck[[:space:]]+source=([^[:space:]]*/)?'; needle_tail_ere "$name"; printf '\n'; } || return 1
}

varsrc="$work/varsrc"   # every .sh file that sources a "$variable"
# The start of a source-edge match. The keyword is preceded by the
# line start / an indent, or by a separator after a first character that is not
# `#` — so the word "source" in a full-line comment (usage-preflight.sh:
# "# Same source and spelling as tick.sh's ...") is prose, never an edge. Only a
# line whose first non-blank character is `#` is skipped: a `#` later in a line
# (a quoted string, a trailing comment after a real source) never hides one.
# (src_lead is defined above bare_source_ere, which the changed-file loop needs.)
: > "$work/varsrc.raw" || io_fail "creating the variable-sourcer list"   # a failed open is rc 1 below
grep_rc=0
git grep -z -l -E "${src_lead}"'(source|\.)[[:space:]]+["'"'"']?\$' "$head_sha" -- ':(glob)**/*.sh' > "$work/varsrc.raw" || grep_rc=$?
if [ "$grep_rc" -gt 1 ]; then
    echo "impacted-suites: git grep failed (rc=$grep_rc) listing variable-sourcing files — cannot tell which suites are impacted" >&2
    exit 2
fi
tr '\0' '\n' < "$work/varsrc.raw" | sed "s/^${head_sha}://" > "$varsrc" || io_fail "listing variable-sourcing files"

content_rules() {
    cat <<'EOF'
HIMMEL_UNINSTALL_[^A-Za-z]{0,3}REAL_HOME|scripts/test-uninstall-real-home-callers.sh
\.himmel/([A-Za-z0-9_.-]+/)*[A-Za-z0-9_.-]+\.jsonl|scripts/observability/test-ledgers-registry.sh
\.himmel/([A-Za-z0-9_.-]+/)*[A-Za-z0-9_.-]+\.log|scripts/observability/test-ledgers-registry.sh
EOF
}
# A process substitution's rc is lost: write the rows to a checked file first.
content_rules > "$work/content-rules" || io_fail "writing the content rules"

scan_roots() {
    cat <<'EOF'
.github/*.yml scripts/ci/test-check-actions-pinned.sh
.github/*.yaml scripts/ci/test-check-actions-pinned.sh
scripts/guardrails/*.sh scripts/guardrails/test-lint-fail-open.sh
scripts/hooks/*.sh scripts/guardrails/test-lint-fail-open.sh
scripts/lanes/*.sh scripts/guardrails/test-lint-fail-open.sh
scripts/lanes/*.mjs scripts/guardrails/test-lint-fail-open.sh
scripts/lanes/*.ts scripts/guardrails/test-lint-fail-open.sh
scripts/hooks/* scripts/lib/test-override-env.sh
scripts/hooks/* scripts/hooks/test-wired-hooks-integrity-resolution.sh
scripts/lib/* scripts/hooks/test-wired-hooks-integrity-resolution.sh
scripts/guardrails/* scripts/hooks/test-wired-hooks-integrity-resolution.sh
scripts/handover/queue-lock.sh scripts/hooks/test-wired-hooks-integrity-resolution.sh
.claude/settings.json scripts/hooks/test-wired-hooks-integrity-resolution.sh
.codex/hooks.json scripts/hooks/test-wired-hooks-integrity-resolution.sh
marketplace/plugins/*/hooks/* scripts/hooks/test-wired-hooks-integrity-resolution.sh
marketplace/plugins/*/scripts/* scripts/hooks/test-wired-hooks-integrity-resolution.sh
scripts/guardrails/* scripts/lib/test-override-env.sh
scripts/lib/* scripts/lib/test-override-env.sh
marketplace/plugins/himmel-ops/hooks/* scripts/lib/test-override-env.sh
scripts/*test-*.sh scripts/lib/test-red-control-extraction-lint.sh
scripts/hooks/* scripts/testing/test-unwired-hooks.sh
.claude/settings.json scripts/testing/test-unwired-hooks.sh
.codex/hooks.json scripts/testing/test-unwired-hooks.sh
.pre-commit-config.yaml scripts/testing/test-unwired-hooks.sh
.pre-commit-hooks.yaml scripts/testing/test-unwired-hooks.sh
docs/setup/settings-template.json scripts/testing/test-unwired-hooks.sh
marketplace/plugins/*/hooks/hooks.json scripts/testing/test-unwired-hooks.sh
scripts/*.sh scripts/cr/test-pr-check-run.sh
scripts/*.mjs scripts/cr/test-pr-check-run.sh
scripts/*.js scripts/cr/test-pr-check-run.sh
!scripts/cr/test-*.sh scripts/cr/test-pr-check-run.sh
!scripts/handover/test-*.sh scripts/cr/test-pr-check-run.sh
!*.test.mjs scripts/cr/test-pr-check-run.sh
scripts/cr/* scripts/cr/test-cr-guarded-closure.sh
*package.json scripts/test-check-plugin-drift.sh
*package.json scripts/hooks/test-check-npm-licenses.sh
!*/node_modules/* scripts/hooks/test-check-npm-licenses.sh
!scripts/lanes/bench/fixtures/* scripts/hooks/test-check-npm-licenses.sh
marketplace/plugins/*/UPSTREAM_PIN scripts/test-check-plugin-drift.sh
scripts/handover/*.sh scripts/guardrails/test-check-git-env-scrub.sh
scripts/handover/*.mjs scripts/guardrails/test-check-git-env-scrub.sh
scripts/handover/*.js scripts/guardrails/test-check-git-env-scrub.sh
scripts/lanes/*.sh scripts/guardrails/test-check-git-env-scrub.sh
scripts/lanes/*.mjs scripts/guardrails/test-check-git-env-scrub.sh
scripts/lanes/*.js scripts/guardrails/test-check-git-env-scrub.sh
scripts/hooks/*.sh scripts/guardrails/test-check-git-env-scrub.sh
scripts/hooks/*.mjs scripts/guardrails/test-check-git-env-scrub.sh
scripts/hooks/*.js scripts/guardrails/test-check-git-env-scrub.sh
scripts/cr/*.sh scripts/guardrails/test-check-git-env-scrub.sh
scripts/cr/*.mjs scripts/guardrails/test-check-git-env-scrub.sh
scripts/cr/*.js scripts/guardrails/test-check-git-env-scrub.sh
.claude/commands/pr-check.md scripts/cr/test-cr-guarded-closure.sh
.agents/skills/pr-check/SKILL.md scripts/cr/test-cr-guarded-closure.sh
*/SKILL.md scripts/lint/test-skill-lint.sh
scripts/*.sh scripts/lanes/test-launch-site-profiles.sh
scripts/*.ts scripts/lanes/test-launch-site-profiles.sh
scripts/*.mjs scripts/lanes/test-launch-site-profiles.sh
scripts/*.js scripts/lanes/test-launch-site-profiles.sh
!test-* scripts/lanes/test-launch-site-profiles.sh
!*.test.* scripts/lanes/test-launch-site-profiles.sh
!*/node_modules/* scripts/lanes/test-launch-site-profiles.sh
!*/dist/* scripts/lanes/test-launch-site-profiles.sh
!*/fixtures/* scripts/lanes/test-launch-site-profiles.sh
*.[sS][hH] scripts/parity/test-ws5-invariants.sh
*.[bB][aA][sS][hH] scripts/parity/test-ws5-invariants.sh
*.[jJ][sS] scripts/parity/test-ws5-invariants.sh
*.[mM][jJ][sS] scripts/parity/test-ws5-invariants.sh
*.[cC][jJ][sS] scripts/parity/test-ws5-invariants.sh
*.[tT][sS] scripts/parity/test-ws5-invariants.sh
!test-* scripts/parity/test-ws5-invariants.sh
!*.tsv scripts/parity/test-ws5-invariants.sh
!*.test.ts scripts/parity/test-ws5-invariants.sh
!*.test.js scripts/parity/test-ws5-invariants.sh
!*.test.mjs scripts/parity/test-ws5-invariants.sh
!*.test.cjs scripts/parity/test-ws5-invariants.sh
scripts/telegram/* scripts/hooks/run-hook-with-bash.test.mjs
scripts/himmelctl/* scripts/hooks/run-hook-with-bash.test.mjs
scripts/hooks/* scripts/hooks/run-hook-with-bash.test.mjs
scripts/lanes/* scripts/hooks/run-hook-with-bash.test.mjs
marketplace/plugins/* scripts/hooks/run-hook-with-bash.test.mjs
scripts/lanes/bench/* scripts/lanes/tests/bench-no-ledger-write.test.mjs
scripts/lanes/bench/* scripts/lanes/tests/bench-no-telegram-spawner-grep.test.mjs
marketplace/plugins/claude-hud/dist/* marketplace/plugins/claude-hud/tests/build-output.test.js
scripts/hooks/*.sh scripts/hooks/test-check-hook-file-parse.sh
scripts/hooks/*.sh scripts/hooks/test-crlf-boundary.sh
scripts/hooks/*.sh scripts/lint/test-shell-lint.sh
scripts/himmelctl/test/*.sh scripts/himmelctl/test/test-suite-hermeticity.sh
.github/workflows/*.yml scripts/upstreams/test-ci-tool-pins.sh
.github/workflows/*.yaml scripts/upstreams/test-ci-tool-pins.sh
marketplace/plugins/lean-skills/skills/* marketplace/plugins/lean-skills/hooks/test-note-superpowers-prefix.sh
marketplace/plugins/handover/templates/*-next-session.md marketplace/plugins/handover/scripts/test-skill-e2e.sh
marketplace/plugins/*/hooks/hooks.json scripts/codex/test-codex-hook-parity.sh
templates/luna-second-brain/scripts/* templates/luna-second-brain/scripts/test-vault-git.sh
templates/luna-second-brain/.gitignore templates/luna-second-brain/scripts/test-vault-git.sh
templates/luna-second-brain/.gitattributes templates/luna-second-brain/scripts/test-vault-git.sh
templates/luna-second-brain/.pre-commit-config.yaml templates/luna-second-brain/scripts/test-vault-git.sh
templates/luna-second-brain/.gitleaks.toml templates/luna-second-brain/scripts/test-vault-git.sh
templates/luna-second-brain/.env.example templates/luna-second-brain/scripts/test-vault-git.sh
templates/luna-second-brain/.vault-template.json templates/luna-second-brain/scripts/test-vault-git.sh
templates/luna-second-brain/README.md templates/luna-second-brain/scripts/test-vault-git.sh
templates/luna-second-brain/_CLAUDE.md templates/luna-second-brain/scripts/test-vault-git.sh
templates/luna-second-brain/index.md templates/luna-second-brain/scripts/test-vault-git.sh
templates/luna-second-brain/log.md templates/luna-second-brain/scripts/test-vault-git.sh
templates/luna-second-brain/Welcome.md templates/luna-second-brain/scripts/test-vault-git.sh
EOF
}
scan_roots > "$work/scan-roots" || io_fail "writing the scan-roots map"

cg_rc=0
git show "${head_sha}:scripts/cr/pr-check-context.sh" > "$work/ctx" 2>/dev/null || cg_rc=$?
: > "$work/guarded"
if [ "$cg_rc" -eq 0 ]; then
    sed -n '/^cr_guarded="/,/"$/p' "$work/ctx" | sed 's/^cr_guarded="//; s/"$//' | tr ' ' '\n' | sed '/^$/d' > "$work/guarded" || io_fail "reading cr_guarded"
fi

# Imports are a reverse dependency index at this head, shared by batch queries.
# ponytail: module basenames deliberately over-select same-named repo modules;
# runtime-computed imports need a selector-miss row before adding a new parser.
: > "$work/importers" || io_fail "creating the importer list"
: > "$work/import-edges" || io_fail "creating the import index"
# One git grep prints every import-shaped line of every importer ("<head>:<path>"
# NUL "<line>") and one awk indexes them: a git show + awk per importer file spawned
# over a thousand processes on a wide diff. A file with no such line has no edge.
# -a reads a file git calls binary as text. tr turns the NUL after the path into
# \001, the one separator awk can hold. The -c overrides pin the output shape against a
# user's grep.lineNumber / grep.column / color.grep, which would prefix or colour the
# lines the awk reads (the edges would vanish at exit 0); -l never printed lines.
grep_rc=0
git -c grep.lineNumber=false -c grep.column=false -c color.grep=false grep -z -a -E '(^|[^A-Za-z0-9_])(import|from|require)([^A-Za-z0-9_]|$)' "$head_sha" -- \
    ':(glob)**/*.js' ':(glob)**/*.mjs' ':(glob)**/*.cjs' ':(glob)**/*.ts' ':(glob)**/*.py' > "$work/importers" || grep_rc=$?
[ "$grep_rc" -le 1 ] || io_fail "listing importers"
tr '\0' '\001' < "$work/importers" > "$work/import.lines" || io_fail "reading the importer lines"
awk -v pre="${head_sha}:" '
    function emit(module, n, parts) {
        n = split(module, parts, "/")
        module = parts[n]
        if (module ~ /^[A-Za-z0-9_.-]+$/ && module != "." && module != "..")
            print module "|" importer
    }
    {
        i = index($0, "\001")
        importer = substr($0, length(pre) + 1, i - 1 - length(pre))
        $0 = substr($0, i + 1)
    }
    /^[[:space:]]*(#|\/\/|\/\*|\*)/ { next }
    importer ~ /\.py$/ {
        if ($0 !~ /^[[:space:]]*(from|import)[[:space:]]/) next
        sub(/#.*/, "")
        gsub(/[^A-Za-z0-9_.]/, " ")
        for (i = 1; i <= NF; i++) {
            if ($i == "from" || $i == "import" || $i == "as") continue
            n = split($i, parts, ".")
            emit(parts[n])
        }
        next
    }
    /(^|[^A-Za-z0-9_])(import|from|require)([^A-Za-z0-9_]|$)/ {
        text = $0
        while (match(text, /["\047][^"\047]+["\047]/)) {
            module = substr(text, RSTART + 1, RLENGTH - 2)
            if (module ~ /\//) emit(module)
            text = substr(text, RSTART + RLENGTH)
        }
    }
' "$work/import.lines" >> "$work/import-edges" || io_fail "indexing imports"

# Whether git archive may rewrite a blob it unpacks (see grep_narrowed): a .gitattributes
# at head naming an attribute that changes content, or one that is not a regular file.
# git grep over a tree skips a symlink blob, but git archive reads it as attribute text,
# so the modes are listed too.
attr_slow=0
grep_rc=0
git grep -q -a -E 'working-tree-encoding|export-subst|filter=|crlf|(^|[[:space:]])ident([[:space:]]|$)' "$head_sha" -- ':(glob)**/.gitattributes' || grep_rc=$?
[ "$grep_rc" -le 1 ] || io_fail "reading the attribute files"
[ "$grep_rc" -ne 0 ] || attr_slow=1
git ls-tree -r -z "$head_sha" > "$work/tree.modes" || io_fail "listing the tree modes"
tr '\0' '\n' < "$work/tree.modes" | awk -F '\t' '{ n = split($2, p, "/") } p[n] == ".gitattributes" && $1 !~ /^100/' > "$work/attr.nonreg" || io_fail "finding the non-regular attribute files"
[ ! -s "$work/attr.nonreg" ] || attr_slow=1

select_changed() {
    cp "$1" "$work/changed" || io_fail "reading the queried paths"
    # Normal mode starts with fresh files; only batch calls reuse them.
    if [ -n "$paths_file" ]; then
        : > "$pats" || io_fail "resetting patterns"
        : > "$lits" || io_fail "resetting literals"
        : > "$found" || io_fail "resetting selected suites"
    fi
seen="$work/seen"     # every file already in the source closure (visited set)
front="$work/front"   # the files whose sourcers the next round looks for
: > "$seen"
: > "$front"

while IFS= read -r f; do
    [ -n "$f" ] || continue
    if [[ $f =~ $suite_re ]]; then
        # A changed suite is impacted by itself (unless the PR deleted it) —
        # and falls through so its basename is also a needle: a wrapper that
        # invokes it (test-arm-resume-fast.sh -> test-arm-resume.sh) is reached.
        if grep -Fxq -- "$f" "$suites"; then printf '%s\n' "$f" >> "$found" || io_fail "recording a changed suite"; fi
    fi
    name="${f##*/}"
    add_needle "$(file_literal "$f")"
    add_stem_needle "$f"
    bare_source_ere "$f" "$lits" >> "$pats" || io_fail "writing a bare source needle"
    printf '%s\n' "$f" >> "$seen" || io_fail "seeding the source closure"
    printf '%s\n' "$f" >> "$front" || io_fail "seeding the source closure"
    case "$f" in
        .claude/commands/*.md|marketplace/plugins/*/commands/*.md)
            add_needle "/${name%.md}" ;;
        */skills/*/SKILL.md)
            skill="${f%/SKILL.md}"; add_needle "/${skill##*/}" ;;
    esac
done < "$work/changed"

# Source closure: a shell file joins the closure as a sourcer when
# (a) a `source`/`.` line names a file already in the closure, (b) it assigns a
# name containing one (`_LIB="$DIR/x.sh"`, `libs=(x.sh y.sh)`) AND has a
# `source`/`.` line whose operand is a `$var` — the repo idiom, `. "$_lib"` —
# or (c) it carries a `# shellcheck source=<path>` directive for it. Its own
# name then becomes a needle, so a suite that names only the outermost helper is
# still reached. Fail-wide: a variable-sourcing file that assigns the helper's
# name joins even if the variable is not the one sourced. Naming the helper
# anywhere plus any source line was tried and cascades to every suite (557 of
# 557 on a 2-file diff), so (b) is deliberately the narrower idiom.
# The visited set ($seen) makes a source cycle terminate; each round is a few greps.
# ponytail: non-.sh sourcers, `exec` edges, a name built at run time
# (`"$dir/$name"`) and a backslash-continued `source \` are not followed —
# upgrade path is a real dataflow pass if a T6 selector-miss row shows one.

# grep_narrowed <patfile> <litfile> <outfile> <what> <pathspec>... — write to
# <outfile>, one path per line, the files at head under <pathspec>... holding a
# line that matches any ERE in <patfile>. The answer of
# `git grep -z -l -E -f <patfile> <head> -- <pathspec>...`, without its cost: that
# runs EVERY pattern over EVERY line, which on a 321-file vendored diff (~1.2k
# patterns, ~1.7k files, 26 rounds) was 3184 CPU-seconds and a cancelled CI job.
# Every pattern holds one literal of <litfile> as a required substring, so a file
# or a line with none of them cannot match: one fixed-string pass keeps those
# files, a second keeps those lines, and the unchanged ERE runs over what is left.
# ponytail: a path holding a newline splits in two, as with the -z lists above;
# upgrade path is NUL-reading consumers if one ever appears.
grep_narrowed() {
    local pf="$1" lf="$2" out="$3" what="$4" p narrow="$work/narrow.d" src="$work/narrow.src"
    shift 4
    case "$pf" in /* | [A-Za-z]:[\\/]*) ;; *) pf="$PWD/$pf" ;; esac   # the ERE pass runs from $narrow
    case "$lf" in /* | [A-Za-z]:[\\/]*) ;; *) lf="$PWD/$lf" ;; esac   # the fixed-string pass runs from $src
    : > "$out" || io_fail "creating the ${what} hit list"   # a failed open is rc 1 below
    : > "$work/narrow.cand" || io_fail "creating the ${what} candidate list"
    grep_rc=0
    git grep -z -l -F -f "$lf" "$head_sha" -- "$@" > "$work/narrow.cand" || grep_rc=$?
    if [ "$grep_rc" -gt 1 ]; then
        echo "impacted-suites: git grep failed (rc=$grep_rc) ${what} — cannot tell which suites are impacted" >&2
        exit 2
    fi
    [ -s "$work/narrow.cand" ] || return 0
    rm -rf "$narrow"
    mkdir "$narrow" || io_fail "creating the ${what} scratch tree"
    # A git show + grep + mkdir per candidate is 3.8k spawns on a wide diff, over half
    # the read. So the candidates at head are unpacked by a few git archive batches and
    # ONE grep prints the literal-bearing lines of every one. git grep -F -f cannot do
    # that pass: it tests the patterns one at a time per line.
    # git archive writes the working-tree form of a blob, by the attributes of the tree
    # it archives, and that tree is the PR's own head: working-tree-encoding=UTF-16LE on
    # a suite would hand the narrowing a copy holding no literal and drop the suite at
    # exit 0. So when any .gitattributes at head could rewrite content (an encoding,
    # export-subst, ident, a filter, crlf, or a file that is not a regular one: attr_slow,
    # set once above), no candidate is unpacked: all take the
    # per-file path below, which reads the raw blob. A candidate the unpack lacks
    # (export-ignore), or holds as a symlink, takes that path too.
    # ponytail: a pattern hit in a comment of .gitattributes also takes the slow path;
    # an attribute set only in $GIT_DIR/info/attributes is the station's, not the PR's.
    # Upgrade path: git cat-file --batch if the slow path ever matters.
    # The candidate list is "<head>:<path>" NUL entries: strip the prefix first.
    tr '\0' '\n' < "$work/narrow.cand" | sed "s/^${head_sha}://" | tr '\n' '\0' > "$work/narrow.rel" || io_fail "reading the ${what} candidates"
    : > "$work/narrow.reg" || io_fail "creating the ${what} candidate list"
    : > "$work/narrow.irr" || io_fail "creating the ${what} candidate list"
    rm -rf "$src"
    mkdir "$src" || io_fail "creating the ${what} scratch tree"
    if [ "$attr_slow" -eq 1 ]; then
        cp "$work/narrow.rel" "$work/narrow.irr" || io_fail "recording the ${what} candidates"
    else
        # --literal-pathspecs: a name holding * ? [ is itself, not a glob. A failed batch
        # (a name past NAME_MAX cannot be unpacked) stops the run: no suite is dropped.
        # core.autocrlf=false: a user's setting must not add a CR to the unpacked lines.
        # shellcheck disable=SC2016  # the child shell expands its own $1 $2 $@
        xargs -0 sh -c 'h=$1; d=$2; shift 2; git -c core.autocrlf=false --literal-pathspecs archive --format=tar "$h" -- "$@" > "$d.tar" && tar -x -f "$d.tar" -C "$d"' sh "$head_sha" "$src" < "$work/narrow.rel" \
            || io_fail "creating the ${what} scratch copy of the candidates"
        # Split the candidates the unpack holds as regular files from the rest.
        while IFS= read -r -d '' p; do
            # A write that fails (a full disk) must not drop the candidate: it stops the run.
            if [ -f "$src/$p" ] && [ ! -L "$src/$p" ]; then
                printf '%s\0' "$p" >&3 || io_fail "recording a ${what} candidate"
            else
                printf '%s\0' "$p" >&4 || io_fail "recording a ${what} candidate"
            fi
        done < "$work/narrow.rel" 3> "$work/narrow.reg" 4> "$work/narrow.irr" || io_fail "splitting the ${what} candidates"
    fi
    # "<path>" NUL "<line>" for each matching line. -H: a lone file still names itself.
    # LC_ALL=C -a: byte-exact, and a line that is not valid UTF-8 is still text.
    : > "$work/narrow.lines" || io_fail "creating the ${what} candidate list"
    if [ -s "$work/narrow.reg" ]; then
        # xargs reports 123 for any batch that exited 1-125, and grep's 1 is "no match":
        # the wrapper turns rc 1 into success so that only a real error (rc 2) reaches it.
        # shellcheck disable=SC2016  # the child shell expands its own $0 $@
        ( cd "$src" && LC_ALL=C xargs -0 sh -c 'grep -HaF --null -f "$0" -- "$@" || [ $? -eq 1 ]' "$lf" ) < "$work/narrow.reg" > "$work/narrow.lines" || io_fail "narrowing the candidates for ${what}"
    fi
    # The NUL after the path becomes \001 (a byte awk can hold). LC_ALL=C: byte-exact
    # index/substr on a line that is not valid UTF-8.
    tr '\0' '\001' < "$work/narrow.lines" > "$work/narrow.tagged" || io_fail "reading the ${what} candidates"
    # Each candidate's directory, once, created by one mkdir -p batch. Every name
    # starts with $narrow/, so none reads as an option.
    NARROW_DIR="$narrow" LC_ALL=C awk '
        {
            i = index($0, "\001")
            path = substr($0, 1, i - 1)
            if (sub(/[^\/]*$/, "", path) && path != "" && !(path in seen)) { seen[path] = 1; print ENVIRON["NARROW_DIR"] "/" path }
        }
    ' "$work/narrow.tagged" > "$work/narrow.dirs.txt" || io_fail "listing the ${what} scratch directories"
    tr '\n' '\0' < "$work/narrow.dirs.txt" > "$work/narrow.dirs" || io_fail "converting the ${what} scratch directory list"
    if [ -s "$work/narrow.dirs" ]; then
        xargs -0 mkdir -p < "$work/narrow.dirs" || io_fail "creating the ${what} scratch tree"
    fi
    # One scratch copy per candidate, holding its literal-bearing lines. Lines of a
    # file are contiguous in the grep output, so one file is open at a time. A
    # redirect that cannot open its target is rc 1, the code for "no match", and an
    # awk one exits non-zero: either way the suite is never dropped silently.
    NARROW_DIR="$narrow" LC_ALL=C awk '
        {
            i = index($0, "\001")
            path = substr($0, 1, i - 1)
            if (path != cur) { if (cur != "") close(file); cur = path; file = ENVIRON["NARROW_DIR"] "/" path }
            print substr($0, i + 1) > file
        }
        END { if (cur != "") close(file) }
    ' "$work/narrow.tagged" || io_fail "creating the ${what} scratch copy of a candidate"
    # A candidate the unpack does not hold as a regular file is read from git itself.
    while IFS= read -r -d '' p; do
        case "$p" in */*) mkdir -p -- "$narrow/${p%/*}" || io_fail "creating the ${what} scratch tree" ;; esac
        git show "${head_sha}:${p}" > "$work/narrow.blob" || io_fail "reading ${p} at ${head_sha} for ${what}"
        : > "$narrow/$p" || io_fail "creating the ${what} scratch copy of ${p}"
        grep_rc=0
        LC_ALL=C grep -aF -f "$lf" "$work/narrow.blob" > "$narrow/$p" || grep_rc=$?
        [ "$grep_rc" -le 1 ] || io_fail "narrowing ${p} for ${what}"
    done < "$work/narrow.irr"
    : > "$work/narrow.hits" || io_fail "creating the ${what} result file"
    # grep -E builds one DFA for every pattern; `git grep -E -f` tried them
    # one at a time per line (~35 s of a 70 s read on a 900-suite range). The scratch
    # tree holds regular files only, so -r follows no link; -a reads a non-UTF-8 line.
    grep_rc=0
    ( cd "$narrow" || exit 3
      LC_ALL=C grep -r -l -Z -a -E -f "$pf" ) > "$work/narrow.hits" || grep_rc=$?
    if [ "$grep_rc" -gt 1 ]; then
        echo "impacted-suites: grep failed (rc=$grep_rc) ${what} — cannot tell which suites are impacted" >&2
        exit 2
    fi
    tr '\0' '\n' < "$work/narrow.hits" > "$out" || io_fail "reading ${what}"
}
# closure_grep <patfile> <outfile> <what> — the .sh files at head matching any pattern.
closure_grep() {
    grep_narrowed "$1" "$work/srclits" "$2" "$3" ':(glob)**/*.sh'
}
while [ -s "$front" ]; do
    : > "$work/srcpats"
    : > "$work/asgpats"
    : > "$work/dirpats"
    : > "$work/srclits"
    : > "$work/importkeys" || io_fail "resetting import keys"
    while IFS= read -r f; do
        name="${f##*/}"
        printf '%s\n' "$name" >> "$work/importkeys" || io_fail "writing an import key"
        case "$name" in
            *.py|*.js|*.mjs|*.cjs|*.ts) printf '%s\n' "${name%.*}" >> "$work/importkeys" || io_fail "writing an extensionless import key" ;;
        esac
        if [ "$name" = __init__.py ]; then
            parent="${f%/*}"
            printf '%s\n' "${parent##*/}" >> "$work/importkeys" || io_fail "writing a package import key"
        fi
        lit=$(file_literal "$f" src)
        printf '%s\n' "$lit" >> "$work/srclits" || io_fail "writing a source-edge literal"
        # A `/name` needle brings its own boundary: let the prefix reach right up to it.
        case "$lit" in
            /*) src_pre='[^#]*'; dir_pre='[^[:space:]]*' ;;
            *) src_pre='([^#]*[^A-Za-z0-9_.-])?'; dir_pre='([^[:space:]]*/)?' ;;
        esac
        { printf '%s(source|\\.)[[:space:]]%s' "$src_lead" "$src_pre"; needle_tail_ere "$lit"; printf '\n'; } >> "$work/srcpats" || io_fail "writing a source-edge pattern"
        { printf '^[[:space:]]*(export[[:space:]]+|local[[:space:]]+|readonly[[:space:]]+)?[A-Za-z_][A-Za-z0-9_]*\\+?=.*'; needle_ere "$lit"; printf '\n'; } >> "$work/asgpats" || io_fail "writing an assignment pattern"
        { printf 'shellcheck[[:space:]]+source=%s' "$dir_pre"; needle_tail_ere "$lit"; printf '\n'; } >> "$work/dirpats" || io_fail "writing a directive pattern"
        bare_source_ere "$f" "$work/srclits" >> "$work/srcpats" || io_fail "writing a bare source-edge pattern"
    done < "$front"
    closure_grep "$work/srcpats" "$work/hit.src" "walking the source closure"
    closure_grep "$work/dirpats" "$work/hit.dir" "reading shellcheck source directives"
    closure_grep "$work/asgpats" "$work/hit.asg" "reading variable assignments"
    awk -F '|' 'NR == FNR { keys[$0] = 1; next } $1 in keys { sub(/^[^|]*\|/, ""); print }' \
        "$work/importkeys" "$work/import-edges" > "$work/hit.import" || io_fail "walking the import closure"
    grep_rc=0
    grep -Fx -f "$suites" "$work/hit.import" >> "$found" || grep_rc=$?
    [ "$grep_rc" -le 1 ] || io_fail "selecting importing suites"
    cat "$work/hit.src" "$work/hit.dir" "$work/hit.import" > "$work/src.out" || io_fail "merging source-closure hits"
    if [ -s "$work/hit.asg" ] && [ -s "$varsrc" ]; then
        grep_rc=0
        grep -Fx -f "$varsrc" "$work/hit.asg" >> "$work/src.out" || grep_rc=$?
        [ "$grep_rc" -le 1 ] || io_fail "intersecting variable sourcers"
    fi
    : > "$work/next"
    while IFS= read -r hit; do
        [ -n "$hit" ] || continue
        if grep -Fxq -- "$hit" "$seen"; then continue; fi
        printf '%s\n' "$hit" >> "$seen" || io_fail "growing the source closure"
        printf '%s\n' "$hit" >> "$work/next" || io_fail "growing the source closure"
        # The closure hit is the SOURCER, not the sourced file, and a
        # suite may invoke it by its stem alone (`guard_rc <hook>`, the hook sourcing
        # a changed lib), so it gets the stem needle too.
        add_needle "$(file_literal "$hit")"
        add_stem_needle "$hit"
    done < "$work/src.out"
    cp "$work/next" "$front" || io_fail "advancing the source closure"
done

# content_rules — one `ERE|suite` row per path-scanning suite that never names
# the files it guards: a changed file whose text (at the base or
# the head) matches the ERE lists the suite. Add a row, not a new mechanism.
# The row splits on its first `|`, so an ERE never spells one: an alternation is
# one row per branch (the two ledger rows, mirror the registry
# lint's own ~/.himmel ledger pattern, .jsonl and .log).
# ponytail: whole-file, not added-lines — any edit to a file that already spells
# a ledger path runs the registry lint (0s); upgrade path: diff-hunk matching if
# a --selector-miss or cost review shows the widening matters.
# Rows match case-insensitively (the uninstall rule's suite reads
# the name in any case); the ledger rows widen with it, which only over-selects
# a 0 s suite.

while IFS= read -r f; do
    [ -n "$f" ] || continue
    # A side that does not exist (file added or deleted) is skipped; a side that
    # exists but cannot be read fails closed rather than dropping the suite.
    : > "$work/content" || io_fail "resetting the content-rule scratch file"
    for rev in "$head_sha" "$mb"; do
        git ls-tree --name-only "$rev" -- "$f" > "$work/lstree" || io_fail "probing ${f} at ${rev} for the content rules"
        if [ -s "$work/lstree" ]; then
            git show "${rev}:${f}" >> "$work/content" || io_fail "reading ${f} at ${rev} for the content rules"
        fi
    done
    # Also match the text as the shell sees it, continuations
    # joined and every quote and backslash deleted, so a name split by quotes or
    # a continuation (`HIMMEL""_UNINSTALL_...`) still reaches its row. This is
    # the normalisation test-uninstall-real-home-callers.sh's sets_var applies.
    # LC_ALL=C: BSD sed dies on a non-UTF-8 byte in a UTF-8 locale.
    LC_ALL=C sed -e ':a' -e '/\\$/N' -e 's/\\\n//' -e 'ta' "$work/content" \
        | LC_ALL=C sed -e "s/\\\$\\([\"']\\)/\\1/g" -e "s/[\"'\\\\]//g" > "$work/content.norm" \
        || io_fail "normalising ${f} for the content rules"
    cat "$work/content.norm" >> "$work/content" || io_fail "appending the normalised text of ${f}"
    while IFS='|' read -r re rule_suite; do
        [ -n "$re" ] || continue
        cgrep_rc=0
        grep -Eiq -- "$re" "$work/content" || cgrep_rc=$?
        if [ "$cgrep_rc" -gt 1 ]; then
            echo "impacted-suites: content-rule grep failed (rc=$cgrep_rc) on ${f} — cannot tell which suites are impacted" >&2
            exit 2
        fi
        if [ "$cgrep_rc" -eq 0 ] && grep -Fxq -- "$rule_suite" "$suites"; then
            printf '%s\n' "$rule_suite" >> "$found" || io_fail "recording a content-rule suite"
        fi
    done < "$work/content-rules"
done < "$work/changed"

# scan_roots — one `<glob> <suite>` row per suite that WALKS a repo tree —
# a file added, changed or deleted under the tree changes the
# suite's result though no suite names it (PR 1734 added
# scripts/lanes/lib/worker-cost-row.sh; lint-fail-open scans scripts/lanes/ and
# main went red). <glob> is a `case` pattern on the repo-relative
# path, and its `*` crosses `/`. Add a row, not a new mechanism.
# A `!<glob> <suite>` row vetoes a file the suite's walk skips; a
# glob with no `/` matches the basename. Mirror the suite's own skip rule
# exactly, never wider: a veto that over-reaches is an under-selection.
# The WS5 rows cover its shell and JS/TS sources (.sh .bash .js .mjs .cjs .ts,
# extension case-insensitive as WS5 classifies it; test-*, *.tsv and
# *.test.<js|ts|mjs|cjs> skipped). WS5's diff scan also reads other non-md files
# (.py, .mts, .tsx, .json, extensionless) that no row selects it for; upgrade
# path: a row here once a --selector-miss ledger row names one. A VENDORED.md
# tree it skips is not mirrored, so a vendored file over-selects a 0 s suite.
# ponytail: whole-repo walkers are left out on purpose — scripts/test-adopt.sh
# and scripts/himmelctl/test/test-versioned-layout.sh copy the whole tree (a
# `*` row would run 554s+19s on every PR);
# scripts/ci/test-run-shell-tests.sh 23c only reacts to a NEW top-level tree;
# scripts/lib/test-vm-guest-excludes.sh only to a secret-named file. Upgrade
# path: a row here once a --selector-miss ledger row names one of them.

while IFS= read -r f; do
    [ -n "$f" ] || continue
    # A `!<glob> <suite>` row vetoes that suite for a file the suite's walk
    # skips. A glob with no `/` is matched against the basename.
    : > "$work/vetoed" || io_fail "resetting the veto list"
    while read -r glob rule_suite; do
        case "$glob" in !*) ;; *) continue ;; esac
        glob="${glob#!}"
        subject="$f"
        case "$glob" in */*) ;; *) subject="${f##*/}" ;; esac
        # shellcheck disable=SC2254
        case "$subject" in
            $glob) printf '%s\n' "$rule_suite" >> "$work/vetoed" || io_fail "recording a veto" ;;
        esac
    done < "$work/scan-roots"
    while read -r glob rule_suite; do
        [ -n "$glob" ] || continue
        case "$glob" in !*) continue ;; esac
        # $glob unquoted on purpose: it is the case pattern.
        # shellcheck disable=SC2254
        case "$f" in
            $glob) if grep -Fxq -- "$rule_suite" "$suites" && ! grep -Fxq -- "$rule_suite" "$work/vetoed"; then
                       printf '%s\n' "$rule_suite" >> "$found" || io_fail "recording a scan-root suite"
                   fi ;;
        esac
    done < "$work/scan-roots"
done < "$work/changed"

# The CR guarded closure: scripts/cr/test-cr-guarded-closure.sh
# DERIVES its file set by walking the runbook + scripts/cr call graph and never
# names what it reaches, so no reference grep selects it. Every file that walk
# reaches must lie inside pr-check-context.sh's cr_guarded set (the suite fails
# otherwise), so a change that adds or alters an edge is one of: a file inside
# cr_guarded (the file holding the edge), or a file a cr_guarded file names (the
# newly reached target, e.g. #1851's worker-jira-status.sh). Select the suite for
# both. The runbook twins are seeds, rows in scan_roots.
# ponytail: the second arm matches by basename text in the guarded files, so a
# basename shared with an unrelated file over-selects (the safe direction); a
# target named only through an assembled path is the suite's own ponytail gap.
# The extension is appended below, never written on an assignment line: the suite
# reads a path stored in a variable as an edge, and an edge to itself would walk
# its own file list into the closure.
closure_suite=scripts/cr/test-cr-guarded-closure
closure_suite="${closure_suite}.sh"
if grep -Fxq -- "$closure_suite" "$suites"; then
    # A head whose cr_guarded set cannot be read or parses empty is not proof the
    # closure is untouched: select the suite, which fails loudly on its own.
    if [ ! -s "$work/guarded" ]; then
        printf '%s\n' "$closure_suite" >> "$found" || io_fail "recording the closure suite"
    else
        : > "$work/guarded-specs"
        : > "$work/cg-pats"
        : > "$work/cg-lits"
        while IFS= read -r g; do
            printf ':(top)%s\n' "$g" >> "$work/guarded-specs" || io_fail "writing the guarded pathspecs"
        done < "$work/guarded"
        cg_hit=0
        while IFS= read -r f; do
            [ -n "$f" ] || continue
            while IFS= read -r g; do
                case "$f" in "$g"|"$g"/*) cg_hit=1; break ;; esac
            done < "$work/guarded"
            [ "$cg_hit" -eq 0 ] || break
            { needle_ere "$(file_literal "$f" cg)"; printf '\n'; } >> "$work/cg-pats" || io_fail "writing a guarded-closure needle"
            file_literal "$f" cg >> "$work/cg-lits" || io_fail "writing a guarded-closure literal"
        done < "$work/changed"
        if [ "$cg_hit" -eq 0 ] && [ -s "$work/cg-pats" ]; then
            # One search for every changed file; any path a guarded file can name
            # counts, not just scripts/handover|lanes|lib.
            # shellcheck disable=SC2046  # one pathspec per line, split on purpose
            # The suite's seeds skip test-*, so a test naming the file is no edge.
            grep_narrowed "$work/cg-pats" "$work/cg-lits" "$work/cg.out" "searching the guarded files for the changed files" $(tr '\n' ' ' < "$work/guarded-specs") ':(exclude,glob)**/test-*' ':(exclude,glob)**/*.test.*'
            [ ! -s "$work/cg.out" ] || cg_hit=1
        fi
        if [ "$cg_hit" -eq 1 ]; then printf '%s\n' "$closure_suite" >> "$found" || io_fail "recording the closure suite"; fi
    fi
fi

if [ -s "$pats" ]; then
    # git grep on the resolved <head> tree, not the working tree: the answer is
    # about the PR as pushed. -l prefixes each path with "<head_sha>:".
    # rc 1 is "no match"; anything higher is a search that did not run, which
    # must not read as an empty impacted set.
    # grep_narrowed searches with -z like the diff and ls-tree above:
    # a suite path holding a non-ASCII byte, double quote, backslash or tab must
    # come back as itself, not as a quoted "\303\251" the runner cannot open.
    grep_narrowed "$pats" "$lits" "$work/grep.out" "searching the suites for the changed files" \
        ':(glob)**/test-*.sh' ':(glob)**/*.test.mjs' ':(glob)**/*.test.js' ':(glob)**/*.test.ts'
    cat "$work/grep.out" >> "$found" || io_fail "reading the search result"
fi

# A tree-scan suite asserts a property of the WHOLE tree (every
# script, every launch site, every ledger), so a file it never names can still
# break it, and the textual match above would skip it. A suite that carries the
# header line `# selector: tree-scan` is therefore listed whenever the range adds,
# deletes, renames or retypes (regular file to symlink) any file. The marker is
# read at BOTH the merge-base and the head; a PR that removes a suite's marker
# must also change that suite, which the changed-suite rule already selects, so
# the merge-base read is a second guard, not the only one. A suite no longer in
# the head tree is dropped. ponytail: a content-only edit to a scanned file does
# not trigger it (the cost would be every PR), upgrade path is "always" if a
# modify-only break is ever recorded.
if [ -s "$2" ]; then
    for ts_rev in "$mb" "$head_sha"; do
        : > "$work/treescan.out" || io_fail "creating the tree-scan list"   # a failed open is rc 1 below
        ts_rc=0
        git grep -z -l -E '^# selector: tree-scan$' "$ts_rev" -- \
            ':(glob)**/test-*.sh' > "$work/treescan.out" || ts_rc=$?
        if [ "$ts_rc" -gt 1 ]; then
            echo "impacted-suites: git grep failed (rc=$ts_rc) — cannot tell which tree-scan suites exist" >&2
            exit 2
        fi
        tr '\0' '\n' < "$work/treescan.out" | sed "s/^${ts_rev}://" > "$work/treescan.paths" || io_fail "reading the tree-scan list"
        while IFS= read -r ts; do
            [ -n "$ts" ] || continue
            if grep -Fxq -- "$ts" "$work/tree"; then printf '%s\n' "$ts" >> "$found" || io_fail "recording a tree-scan suite"; fi
        done < "$work/treescan.paths"
    done
fi

impacted="$work/impacted"
if [ "$shell_only" -eq 1 ]; then
    : > "$work/shell" || io_fail "creating the shell-suite list"   # a failed open is rc 1 below
    grep_rc=0
    grep -E '(^|/)test-[^/]*\.sh$' "$found" > "$work/shell" || grep_rc=$?   # rc 1 = no shell suite
    [ "$grep_rc" -le 1 ] || io_fail "filtering to shell suites"
    sort -u "$work/shell" > "$impacted" || io_fail "sorting the impacted list"
else
    sort -u "$found" > "$impacted" || io_fail "sorting the impacted list"
fi

}

if [ -n "$paths_file" ]; then
    while IFS= read -r query || [ -n "$query" ]; do
        [ -n "$query" ] || continue
        case "$query" in *$'\t'*) echo "impacted-suites.sh: batch paths cannot contain tabs" >&2; exit 2 ;; esac
        printf '%s\n' "$query" > "$work/query" || io_fail "writing a batch query"
        : > "$work/query.shape" || io_fail "resetting a batch shape"
        if ! grep -Fxq -- "$query" "$work/tree"; then
            printf '%s\n' "$query" > "$work/query.shape" || io_fail "writing a batch shape"
        fi
        select_changed "$work/query" "$work/query.shape"
        if [ -s "$impacted" ]; then
            while IFS= read -r suite; do
                printf '%s\t%s\n' "$query" "$suite" || io_fail "writing batch results"
            done < "$impacted"
        else
            printf '%s\t\n' "$query" || io_fail "writing an empty batch result"
        fi
    done < "$paths_file" # read-sink-ok: explicit operator-selected query input; regular/readable/non-symlink checked, parsed only as literal paths
    exit 0
fi

if ! tree_shape=$(git diff -z --diff-filter=ADT --name-only --no-renames "$mb" "$head_sha" | tr '\0' '\n'); then
    echo "impacted-suites.sh: git diff ${mb}..${head_sha} failed" >&2; exit 2
fi
printf '%s' "$tree_shape" > "$work/diff.shape" || io_fail "writing the tree-shape list"
# Keep the diff input separate: select_changed resets work/changed.
printf '%s\n' "$changed" > "$work/diff.changed" || io_fail "writing the diff list"
select_changed "$work/diff.changed" "$work/diff.shape"

if [ "$selector_miss" -eq 1 ]; then
    miss=0
    while IFS= read -r red || [ -n "$red" ]; do
        red="${red%$'\r'}"
        [ -n "$red" ] || continue
        if ! grep -Fxq -- "$red" "$impacted"; then
            miss=1
            while IFS= read -r f; do
                [ -n "$f" ] || continue
                printf 'selector-miss: %s %s\n' "$red" "$f"
            done < "$work/changed"
        fi
    done < "$red_file"
    exit "$miss"
fi

# --plan: which impacted suites run on this machine and which are left to CI.
# The same tests --check applies to a `= CI` verdict, run forward: a suite the PR changed
# (its failing-first proof), a non-test-*.sh suite (no per-suite CI proof) and a suite
# suite-coverage.sh says CI does not run are LOCAL with the reason named; every other one is CI.
if [ "$plan" -eq 1 ]; then
    plan_local="$work/plan.local"
    plan_ci="$work/plan.ci"
    plan_cand="$work/plan.cand"
    : > "$plan_local"
    : > "$plan_ci"
    : > "$plan_cand"
    while IFS= read -r s; do
        if [ "${HIMMEL_SUITES_LOCAL:-0}" != 0 ]; then
            printf 'LOCAL %s (HIMMEL_SUITES_LOCAL=1: every impacted suite runs locally)\n' "$s" >> "$plan_local" || io_fail "writing the plan"
            continue
        fi
        if grep -Fxq -- "$s" "$work/diff.changed"; then
            printf 'LOCAL %s (changed: failing-first proof required)\n' "$s" >> "$plan_local" || io_fail "writing the plan"
            continue
        fi
        case "${s##*/}" in
            test-*.sh) printf '%s\n' "$s" >> "$plan_cand" || io_fail "writing the plan candidates" ;;
            *) printf 'LOCAL %s (not a test-*.sh: a JS/TS suite has no per-suite CI proof)\n' "$s" >> "$plan_local" || io_fail "writing the plan" ;;
        esac
    done < "$impacted"
    if [ -s "$plan_cand" ]; then
        plan_args=()
        while IFS= read -r s; do plan_args+=("$s"); done < "$plan_cand"
        cov_rc=0
        bash "$top/scripts/handover/suite-coverage.sh" "${plan_args[@]}" > "$work/plan.cov" 2> "$work/plan.cov.err" || cov_rc=$?
        case "$cov_rc" in 0|3) ;; *) io_fail "suite-coverage.sh (rc ${cov_rc}: $(head -n 1 "$work/plan.cov.err"))" ;; esac
        while IFS= read -r s; do
            line=$(awk -v p="$s: " 'index($0, p) == 1 { print substr($0, length(p) + 1); exit }' "$work/plan.cov") || io_fail "reading suite-coverage.sh's answer"
            case "$line" in
                "runs in PR CI"*) printf 'CI %s\n' "$s" >> "$plan_ci" || io_fail "writing the plan" ;;
                "") printf 'LOCAL %s (unknown: suite-coverage.sh printed no line for it)\n' "$s" >> "$plan_local" || io_fail "writing the plan" ;;
                *) printf 'LOCAL %s (%s)\n' "$s" "$line" >> "$plan_local" || io_fail "writing the plan" ;;
            esac
        done < "$plan_cand"
    fi
    sort "$plan_local" || io_fail "printing the local plan"
    sort "$plan_ci" || io_fail "printing the CI plan"
    n_pl=$(wc -l < "$plan_local" | tr -d ' ')
    n_pc=$(wc -l < "$plan_ci" | tr -d ' ')
    printf 'impacted-suites: plan %s impacted, %s local, %s to CI\n' "$(wc -l < "$impacted" | tr -d ' ')" "$n_pl" "$n_pc"
    exit 0
fi

if [ "$check" -eq 0 ]; then
    cat "$impacted" || io_fail "listing the impacted suites"
    exit 0
fi

# --check: every impacted suite needs a valid verdict line on stdin.
have="$work/have"
blocked_raw="$work/blocked.raw"
ci_raw="$work/ci.raw"
skip_raw="$work/skip.raw"
pass_raw="$work/pass.raw"
ruled_raw="$work/ruled.raw"
: > "$blocked_raw"
: > "$ci_raw"
: > "$skip_raw"
: > "$pass_raw"
: > "$ruled_raw"
awk -v blockedf="$blocked_raw" -v cif="$ci_raw" -v skipf="$skip_raw" -v passf="$pass_raw" -v ruledf="$ruled_raw" '
    # The path is everything between "SUITE " and the FIRST " = " (a suite path
    # may contain spaces); the verdict word and reason rules follow it.
    /^SUITE +/ {
        i = index($0, " = ")
        if (i == 0) next
        path = substr($0, 1, i - 1)
        sub(/^SUITE +/, "", path)
        sub(/ +$/, "", path)
        rest = substr($0, i + 3)
        sub(/^ +/, "", rest)
        if (path == "") next
        # `= CI` hands the suite on to CI; it is checked below, never taken as is.
        if (rest ~ /^CI[ \t\r]*$/) { print path > cif; next }
        if (rest !~ /^(PASS|SKIP|BLOCKED)( +.*)?$/) next
        verdict = rest
        sub(/[ ].*$/, "", verdict)
        reason = rest
        sub(/^(PASS|SKIP|BLOCKED) */, "", reason)
        if (verdict == "PASS" || reason ~ /[^ \t\r]/) {
            print path
            if (verdict == "BLOCKED") print path > blockedf
            if (verdict == "SKIP") print path > skipf
            if (verdict == "PASS") print path > passf
            # a ruled SKIP names a chief session and a reason; the form is checked, not the truth
            ruled = rest
            sub(/\r$/, "", ruled)
            if (ruled ~ /^SKIP ruled [A-Za-z0-9._-]*chief[A-Za-z0-9._-]* .*[^ ].*$/) print path > ruledf
        }
    }
' | sort -u > "$have.local" || io_fail "reading the verdicts"
# `SUITE <p> = CI` is accepted only for a test-*.sh the PR did not
# change or add, that suite-coverage.sh says runs in PR CI, and never under
# HIMMEL_SUITES_LOCAL=1. A refused one counts as no verdict and exits 1. This is
# a pre-filter for the suites CI can never run; ready-check item 19 is the gate
# that reads CI's per-suite proof at the head. suite-coverage.sh is the reviewed
# tree's copy, because the tables it reads are the ones that tree's CI runs.
ci_list="$work/ci"
ci_ok="$work/ci.ok"
ci_cand="$work/ci.cand"
: > "$ci_ok"
: > "$ci_cand"
sort -u "$ci_raw" | comm -12 "$impacted" - > "$ci_list" || io_fail "reading the CI verdicts"
ci_bad=0
refuse_ci() { printf 'impacted-suites: CI NOT ACCEPTED %s (%s)\n' "$1" "$2" >&2; ci_bad=1; }
while IFS= read -r s; do
    if [ "${HIMMEL_SUITES_LOCAL:-0}" != 0 ]; then
        refuse_ci "$s" "HIMMEL_SUITES_LOCAL=1: every impacted suite runs locally"; continue
    fi
    case "${s##*/}" in
        test-*.sh) ;;
        *) refuse_ci "$s" "not a test-*.sh: a JS/TS suite has no per-suite CI proof, run it locally"; continue ;;
    esac
    if grep -Fxq -- "$s" "$work/diff.changed"; then
        refuse_ci "$s" "the PR changed it: a changed or added suite runs locally"; continue
    fi
    printf '%s\n' "$s" >> "$ci_cand" || io_fail "writing the CI candidates"
done < "$ci_list"
if [ -s "$ci_cand" ]; then
    ci_args=()
    while IFS= read -r s; do ci_args+=("$s"); done < "$ci_cand"
    cov_rc=0
    bash "$top/scripts/handover/suite-coverage.sh" "${ci_args[@]}" > "$work/cov" 2> "$work/cov.err" || cov_rc=$?
    # rc 3 = some path is unknown, judged per path below; anything else is a failed read.
    case "$cov_rc" in 0|3) ;; *) io_fail "suite-coverage.sh (rc ${cov_rc}: $(head -n 1 "$work/cov.err"))" ;; esac
    while IFS= read -r s; do
        # The line whose exact prefix is "<path>: "; none (a truncated answer) is unknown.
        line=$(awk -v p="$s: " 'index($0, p) == 1 { print substr($0, length(p) + 1); exit }' "$work/cov") || io_fail "reading suite-coverage.sh's answer"
        case "$line" in
            "runs in PR CI"*) printf '%s\n' "$s" >> "$ci_ok" || io_fail "writing the CI verdicts" ;;
            "") refuse_ci "$s" "unknown: suite-coverage.sh printed no line for it" ;;
            *) refuse_ci "$s" "$line" ;;
        esac
    done < "$ci_cand"
fi
sort -u "$have.local" "$ci_ok" > "$have" || io_fail "merging the verdicts"
missing="$work/missing"
comm -23 "$impacted" "$have" > "$missing" || io_fail "comparing verdicts to the impacted list"
n_impacted=$(wc -l < "$impacted" | tr -d ' ')
n_missing=$(wc -l < "$missing" | tr -d ' ')
# check_exit <rc>: with --record, one impacted row on the git-common ledger
# first (ready-check item 16 reads it); a failed append exits 4.
check_exit() {
    if [ "$record" -eq 1 ]; then
        n_skip=$(sort -u "$skip_raw" | comm -12 "$impacted" - | wc -l | tr -d ' ') || io_fail "counting SKIP verdicts"
        rec_ledger="$(git rev-parse --path-format=absolute --git-common-dir)/cr-critic-scores.jsonl" || exit 4
        # the PASS and ruled-SKIP paths, only those on the impacted list, one per line
        sort -u "$pass_raw" | comm -12 "$impacted" - > "$work/local_pass" || io_fail "listing the PASS verdicts"
        sort -u "$ruled_raw" | comm -12 "$impacted" - > "$work/ruled_skip" || io_fail "listing the ruled SKIP verdicts"
        if ! CR_LEDGER="$rec_ledger" bash "$is_dir/ledger-append.sh" impacted --branch "$rec_branch" --head "$rec_head" \
            --impacted "$n_impacted" --unverdicted "$n_missing" --skip "$n_skip" --rc "$1" \
            --local-pass-file "$work/local_pass" --ruled-skip-file "$work/ruled_skip" >/dev/null; then
            echo "impacted-suites.sh: could not record the impacted row (ledger-append.sh, reason above)" >&2
            exit 4
        fi
    fi
    exit "$1"
}
n_ci=$(wc -l < "$ci_ok" | tr -d ' ')
printf 'impacted-suites: %s impacted, %s without a verdict, %s to CI\n' "$n_impacted" "$n_missing" "$n_ci"
if [ "$n_missing" -gt 0 ]; then
    while IFS= read -r s; do
        printf 'impacted-suites: MISSING VERDICT %s\n' "$s" >&2
    done < "$missing"
    check_exit 1
fi
[ "$ci_bad" -eq 0 ] || check_exit 1
# Every suite has a verdict; a BLOCKED one is accounted for but did not run.
blocked="$work/blocked"
sort -u "$blocked_raw" | comm -12 "$impacted" - > "$blocked" || io_fail "finding BLOCKED verdicts"
if [ -s "$blocked" ]; then
    printf 'impacted-suites: %s BLOCKED (accounted for, NOT clean — the suite did not run)\n' "$(wc -l < "$blocked" | tr -d ' ')" >&2
    while IFS= read -r s; do
        printf 'impacted-suites: BLOCKED %s\n' "$s" >&2
    done < "$blocked"
    check_exit 3
fi
check_exit 0
