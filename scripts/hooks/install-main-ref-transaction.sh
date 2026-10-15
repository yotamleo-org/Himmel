#!/usr/bin/env bash
# Install the main-branch reference-transaction guard.
#
# `pre-commit install --hook-type` does NOT support "reference-transaction"
# (its own --help lists only commit-msg, post-checkout, post-commit,
# post-merge, post-rewrite, pre-commit, pre-merge-commit, pre-push,
# pre-rebase, prepare-commit-msg) -- that is exactly why this installer
# exists, mirroring install-cr-pre-push-legacy.sh's reason for being (a hook
# type pre-commit cannot wire, installed as a tiny shim that execs the
# tracked, reviewable, testable script).
#
# PLATFORM GUARD (no .ps1 twin -- this note is that decision, not a
# placeholder for one): this script is plain POSIX shell, so under Git Bash
# on Windows it would run and install correctly the same way it does on
# Linux/macOS -- nothing here needs a PowerShell-specific rewrite. The real
# gap is that it is never INVOKED there at all: `scripts/setup.sh` and
# `scripts/setup-hooks.sh` both call this installer, but their Windows twin
# `scripts/setup-hooks.ps1` has no call to it whatsoever -- so a Windows
# station's setup run installs every OTHER hook and silently skips this one,
# leaving main completely unguarded with no error, no warning, nothing in
# `himmel-doctor` to catch it until C32 happens to be checked from a git
# context that can see it. That gap is tracked deliberately
# rather than closed here (this session cannot test PowerShell). A future
# `.ps1` twin -- or a call to this same script added to `setup-hooks.ps1` --
# is what resolves it; this note exists so nobody mistakes "no twin" for
# "no gap".
#
# DESIGN RULE: writing a file that LOOKS like protection is not protection, and
# re-deriving either "where does git look" or "how do I safely embed one string
# in another" keeps re-opening the gap. So:
#   - The shim fails OPEN on its own broken target: reference-transaction fires
#     on EVERY ref update, not just main, so a broken shim must not brick the
#     repo (see the shim's own comment, below).
#   - "We wrote the file" != "git runs it": core.hooksPath, when set, is the
#     ONLY place git looks (.git/hooks/ is ignored entirely), and git silently
#     ignores a hook that lost its +x bit.
#   - Ask git where a hook belongs instead of computing it:
#     `git rev-parse --path-format=absolute --git-path hooks` is git's OWN
#     resolution, correct for core.hooksPath unset/relative/absolute, from any
#     invoking cwd, per worktree. (A RELATIVE core.hooksPath resolves PER
#     WORKTREE, and `--git-common-dir` is relative to the INVOKING DIRECTORY,
#     so joining it against repo_root gives the WRONG path from a subdirectory.)
#     scripts/cr/install-cr-gate.sh and pr-check-context.sh rely on
#     `--path-format=absolute` the same way.
#   - himmel-doctor's check_c32 never `eval`s anything extracted from the hook
#     file: a marker comment authenticates NOTHING (anyone can copy it), so a
#     hostile `target=$(...)` line would run during a read-only doctor run.
#   - The check-script path is never embedded in the hook file at all (any
#     embedding is a hand-rolled escaping scheme; an embedded NEWLINE byte,
#     legal in a POSIX path, terminates a comment line and injects shell). It
#     lives in EXACTLY ONE place, `git config --local himmel-main-ref.target
#     <path>`, set once by this installer and shared by every linked worktree.
#     git's own reader/writer round-trips any byte string exactly, newlines,
#     quotes, `$` and backticks included. The generated shim is fully STATIC
#     (the same bytes for every install, NO per-checkout interpolation) and
#     reads the value back the same way at hook-run time, as does check_c32.
#     Nothing is parsed out of the hook FILE beyond the marker-presence check.
#   - Worktree coverage: `extensions.worktreeConfig` lets any ONE worktree
#     override core.hooksPath independently, so "usually shared" is not "always
#     shared"; the installer always enumerates every worktree and resolves each
#     one's own hooks directory. The enumeration uses `--porcelain -z`
#     (NUL-terminated, since a worktree PATH may contain a newline) read via
#     `read -r -d ''` fed by process substitution, not captured into a variable
#     first (a captured `$(cmd -z)` truncates at the first NUL byte; bash cannot
#     store one in a variable).
#   - Partial coverage never reports exit 0: `fail_count > 0` exits non-zero
#     (successful installs are still KEPT, there is no rollback), and the
#     fallback below -- when enumeration itself fails and only the current
#     worktree can be installed -- forces a non-zero exit (`enumeration_failed`)
#     even if its own single install succeeded, because other worktrees may
#     exist and be left uncovered.
#
# GIT VERSION: every `--path-format=absolute` call below (there are three:
# the per-worktree loop, and the single-worktree fallback) needs git >=
# 2.31 -- but this repo's declared minimum is git 2.30
# (docs/setup/new-machine.md, scripts/install/deps.json). CodeRabbit (PR
# #2195) caught the SAME exposure in himmel-doctor.sh's C32; a first pass
# at fixing both here concluded that an unsupported `--path-format` simply
# makes `rev-parse` fail, so a 2.30 station would loudly refuse rather than
# install anything -- THAT CONCLUSION WAS WRONG, and was reported as fact
# without being tested. Proven directly on this station instead of
# reasoned about: `git rev-parse --totally-unknown-option --git-path
# hooks` prints the unknown option back as an ordinary output line, THEN
# the (relative, since the format request was never honoured) resolved
# path -- and still exits 0. `git rev-parse` does not reject options it
# does not recognise; it echoes them. So on git < 2.31, `rev-parse
# --path-format=absolute --git-path hooks` returns rc=0 with a
# multi-line, non-absolute value -- NOT an error -- and this script would
# have installed the guard at a bogus path built from that garbage while
# reporting success, the exact "looks protected, is not" class this whole
# ticket exists to close. The fix (below, `looks_like_absolute_path`) does
# not trust the exit status at all: every `--path-format=absolute` result
# is validated as an actual single-line absolute path before use, which
# closes this regardless of which git versions echo which options --
# validating the VALUE does not require trusting our own reading of
# version-specific behaviour the way a version check would.
set -uo pipefail

# looks_like_absolute_path VALUE -- true only if VALUE is a plausible
# absolute path (POSIX /... or a Windows drive-letter form), used to
# validate every `git rev-parse --path-format=absolute ...` result before
# trusting it (see the GIT VERSION note above for why exit status alone is
# not proof: older git echoes an unrecognised --path-format back as output
# and still exits 0). Deliberately NOT also rejecting embedded newlines --
# a worktree whose own path legitimately contains one is already covered
# elsewhere in this installer and in check-main-ref-transaction.sh's test
# suite (the newline-worktree-path case), and a genuine absolute path
# still starts with `/` (or a drive letter) regardless of what it
# contains further in -- while the garbage this validates against starts
# with the echoed option text itself (`-`), which this prefix check alone
# already rejects.
looks_like_absolute_path() {
    case "$1" in
        /*|[A-Za-z]:[/\\]*) return 0 ;;
        *) return 1 ;;
    esac
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
check_script="$SCRIPT_DIR/check-main-ref-transaction.sh"
if [ ! -f "$check_script" ]; then
    echo "install-main-ref-transaction: cannot find $check_script -- refusing to install" >&2
    exit 2
fi

git rev-parse --show-toplevel >/dev/null 2>&1 || {
    echo "install-main-ref-transaction: not a git repository" >&2
    exit 2
}

# THE single authoritative value (see DESIGN RULE above): stored ONCE via git
# config, shared automatically by every linked worktree of this repo
# (`--local` writes the shared repo config, not a per-worktree override --
# proven empirically; `extensions.worktreeConfig` does not change this
# unless `--worktree` is explicitly requested, which this never does).
# Idempotent: setting the same key to the same value twice is a no-op as
# far as anything downstream can observe.
if ! git config --local himmel-main-ref.target "$check_script"; then
    echo "install-main-ref-transaction: could not record the target in git config (himmel-main-ref.target) -- refusing to install" >&2
    exit 2
fi

# install_one_hook HOOK_PATH -- idempotent single-location installer for the
# STATIC shim (see DESIGN RULE above: no per-checkout data is interpolated into
# it at all, so the same bytes are written everywhere). Prints its own
# diagnostics; returns 0 on success, nonzero on failure (a foreign hook
# already there, or a write/chmod failure).
install_one_hook() {
    local hook_path="$1"
    local owner_marker="# himmel-main-ref-transaction-v1"
    if [ -e "$hook_path" ] && ! grep -Fq "$owner_marker" "$hook_path"; then
        echo "install-main-ref-transaction: refusing to overwrite existing non-Himmel hook at $hook_path" >&2
        echo "Merge that hook with scripts/hooks/check-main-ref-transaction.sh manually, then re-run setup." >&2
        return 2
    fi
    if ! mkdir -p "$(dirname "$hook_path")"; then
        echo "install-main-ref-transaction: cannot create hooks directory for $hook_path" >&2
        return 2
    fi
    # Write the shim to a SAME-DIRECTORY temp file, then `mv` it over
    # hook_path -- never a direct `cat > hook_path` (a plain redirect opens
    # the target O_TRUNC before a single byte of the new content is
    # written, so a concurrent `git` operation racing this reinstall -- and
    # reference-transaction fires on EVERY ref update -- can observe an
    # empty or partially-written hook and proceed unprotected). A rename
    # within one filesystem is atomic: any reader sees either the complete
    # old hook or the complete new one, never a truncated file in between.
    # Same directory (not $TMPDIR) so the rename cannot cross filesystems,
    # which would make it a copy, not a rename.
    local tmp_path
    tmp_path=$(mktemp "$(dirname "$hook_path")/.himmel-main-ref-transaction.XXXXXX" 2>/dev/null) || {
        echo "install-main-ref-transaction: cannot create a temp file next to $hook_path" >&2
        return 2
    }
    if ! cat > "$tmp_path" <<'HOOK'
#!/usr/bin/env bash
# himmel-main-ref-transaction-v1
# Shim installed by scripts/hooks/install-main-ref-transaction.sh
# (HIMMEL-2095). Runs the tracked, reviewable check script via bash
# EXPLICITLY (never relying on the target's own exec bit surviving every
# checkout/platform) -- "$@" and stdin (the reference-transaction line
# stream) pass through unchanged.
#
# This file is 100% STATIC -- identical bytes at every install site, no
# per-checkout path baked in here at all. The one variable (which checkout
# to run) lives in `git config --local himmel-main-ref.target`, set once by
# the installer and shared automatically across every linked worktree; see
# that installer's own header for why (round 5: no escaping question left
# to get wrong, because git's own config subsystem already solved "store
# and retrieve one arbitrary string exactly").
#
# FAIL-OPEN, DELIBERATELY: if the configured target is missing, unreadable,
# not a regular file, or was never configured at all (the checkout that ran
# the installer got moved, renamed, or pruned; or install never ran), ALLOW
# rather than refuse. reference-transaction fires on EVERY ref update in
# this repo (fetch's refs/remotes/*, stash, tags, every branch), so
# treating a broken target as a refusal would fail every such operation
# repo-wide, recoverable only by knowing to delete this untracked file.
# Silently-absent protection is strictly better than a bricked repo; see
# this installer's own header for the full rationale. `himmel-doctor`
# check C32 is the structural catch for exactly this state.
#
# `-f`, not just `-r` (round 9): the target is always the installer-set
# path to check-main-ref-transaction.sh, so there is no realistic route by
# which it becomes a directory -- but `[ -r DIR ]` is TRUE for a readable
# directory, so a bare readability check would have let that shape reach
# `exec bash "$target"` below, where bash fails on a directory argument and
# this hook would FAIL-CLOSED instead of fail-open: every ref update in the
# repo refused, recoverable only by deleting an untracked file no `git
# diff` ever shows -- the exact brick this whole guard was designed
# against. Negligible probability, catastrophic and near-undiagnosable
# impact, one-line fix: worth guarding on purpose, not dead weight to
# simplify away.
target=$(git config --local --get himmel-main-ref.target 2>/dev/null)
if [ -z "$target" ] || [ ! -f "$target" ] || [ ! -r "$target" ]; then
    echo "reference-transaction (himmel-main-ref-transaction-v1): target check script unconfigured/missing/unreadable/not-a-regular-file: '$target' -- ALLOWING this ref update unconditionally (the main-branch guard is NOT protecting; re-run: bash <repo>/scripts/hooks/install-main-ref-transaction.sh)" >&2
    # DRAIN STDIN before exiting -- check-main-ref-transaction.sh's own
    # header states the contract this shim must honour too: git writes ONE
    # line per ref in the transaction, and a transaction can carry many
    # (a `fetch` touching hundreds of refs/remotes/* at once). Exiting here
    # without reading would leave git writing into a pipe nobody drains --
    # once the kernel buffer fills, git sees a broken pipe and the
    # operation can fail outright, which is exactly the outcome this
    # fail-open branch exists to avoid.
    cat >/dev/null
    exit 0
fi
exec bash "$target" "$@"
HOOK
    then
        echo "install-main-ref-transaction: cannot write $tmp_path" >&2
        rm -f "$tmp_path"
        return 2
    fi
    if ! chmod +x "$tmp_path"; then
        echo "install-main-ref-transaction: cannot make $tmp_path executable" >&2
        rm -f "$tmp_path"
        return 2
    fi
    # Verify the bit actually took -- git silently ignores a non-executable
    # hook on Unix, so a chmod that reported success but didn't stick (an
    # unusual filesystem/mount) must not be reported as installed. Checked
    # on the TEMP file, before the rename -- the live hook_path (if any)
    # must never be touched by a write that ends up failing here.
    if [ ! -x "$tmp_path" ]; then
        echo "install-main-ref-transaction: $tmp_path is not executable after chmod +x -- refusing to report success" >&2
        rm -f "$tmp_path"
        return 2
    fi
    if ! mv -f "$tmp_path" "$hook_path"; then
        echo "install-main-ref-transaction: cannot move $tmp_path into place at $hook_path -- any previously-installed hook there is untouched" >&2
        rm -f "$tmp_path"
        return 2
    fi
    echo "Himmel main-branch reference-transaction guard installed at $hook_path"
    return 0
}

# ALWAYS enumerate and resolve EVERY EXISTING linked worktree individually
# -- never assume core.hooksPath is shared just because THIS invocation's
# own value is unset or absolute: `extensions.
# worktreeConfig` lets any ONE worktree override core.hooksPath
# independently of the others, so "usually shared" is not the same fact as
# "always shared" -- this is a security guard, and an earlier version's
# single-install shortcut for the unset/absolute case silently trusted that
# assumption. `git worktree list` always lists every worktree regardless of
# which one is invoking (including this one), and `git -C <worktree>
# rev-parse --path-format=absolute --git-path hooks` resolves EACH
# worktree's own hooks directory correctly no matter how core.hooksPath
# ended up set there (shared, absolute, or a per-worktree override) -- so
# looping unconditionally is both simpler and correct, replacing what used
# to be a hookspath-value classification plus two separate code paths.
#
# SCOPE, stated plainly (a Suggestion this installer accepts as a real,
# documented limitation rather than silently ignoring): this only covers
# worktrees that exist AT INSTALL TIME. A worktree created afterwards has
# no shim of its own and can move refs/heads/main unguarded until this
# installer is re-run. There is no git hook for "a worktree was just
# created" to hang an automatic re-install off; the honest fix is
# operational, not code -- re-run this installer (or scripts/setup.sh /
# scripts/setup-hooks.sh, which call it) after `git worktree add`. See
# enforcement.md.
ok_count=0
fail_count=0
enumeration_failed=0

# `-z`: plain `git worktree list --porcelain`
# newline-delimited output treats a worktree path that itself contains a
# literal newline byte (legal on POSIX filesystems) as if it ended at that
# newline -- the SAME "parse structured git output as plain text and get
# bitten by an embedded newline" lesson the DESIGN RULE above designs OUT of
# the target path, reappearing on the enumeration side. `-z`
# NUL-terminates each field instead, so `read -r -d ''` below reads a
# worktree path's embedded newline as ordinary path content rather than a
# field boundary. Fed via process substitution, NOT captured into a
# variable first -- `x=$(cmd -z)` truncates at the first NUL byte (bash
# cannot store one in a variable), which would silently re-break this the
# same way capturing into a plain `worktree_list` variable used to.
# Process substitution alone discards the producer's exit status (`$?`
# after the loop would be `read`'s, not `git worktree list`'s) -- so an
# enumeration that emits SOME entries and then fails partway (a transient
# git error mid-listing) used to be indistinguishable from one that
# completed: the entries already seen install fine, ok_count/fail_count
# both end up looking like full coverage, and the caller never learns that
# worktrees beyond the failure point were never even seen. Captured here by
# appending the producer's own exit status as one more NUL-terminated field
# after its real output, in the SAME process-substitution subshell that ran
# it -- so the loop below sees it as an ordinary extra record, matched by
# its own case arm. Process substitution is kept (not a `| while` pipe) so
# ok_count/fail_count still mutate the caller's own shell variables rather
# than a subshell's copy.
wt_enum_status=""
while IFS= read -r -d '' wt_field; do
    case "$wt_field" in
        "worktree "*)
            wt_path="${wt_field#worktree }"
            wt_hooks_dir=$(git -C "$wt_path" rev-parse --path-format=absolute --git-path hooks 2>/dev/null) || wt_hooks_dir=""
            # Validate the VALUE, not just the exit status -- see the GIT
            # VERSION note above: git < 2.31 echoes an unrecognised
            # --path-format=absolute back as output and still exits 0.
            if ! looks_like_absolute_path "$wt_hooks_dir"; then
                echo "install-main-ref-transaction: could not resolve an absolute hooks directory for worktree $wt_path (got: '$wt_hooks_dir') -- skipping (NOT covered; this repo needs git >= 2.31 for --path-format, see this installer's own GIT VERSION note)" >&2
                fail_count=$((fail_count + 1))
                continue
            fi
            if install_one_hook "$wt_hooks_dir/reference-transaction"; then
                ok_count=$((ok_count + 1))
            else
                fail_count=$((fail_count + 1))
            fi
            ;;
        wt_enum_status=*) wt_enum_status="${wt_field#wt_enum_status=}" ;;
    esac
done < <(git worktree list --porcelain -z 2>/dev/null; printf 'wt_enum_status=%s\0' "$?")

if [ "$wt_enum_status" != "0" ]; then
    # Some (possibly zero) entries were processed above, but the producer
    # itself did not report success -- coverage of anything beyond what was
    # actually seen is unknown, the same "partial reported as complete"
    # class the ok_count/fail_count bookkeeping below already guards for
    # the per-location case. Reusing enumeration_failed (rather than a new
    # flag) folds this into the SAME non-zero-exit policy that flag already
    # drives further down.
    echo "install-main-ref-transaction: git worktree list --porcelain -z exited non-zero (status=${wt_enum_status:-unknown}) -- coverage of any worktree not already processed above is UNKNOWN" >&2
    enumeration_failed=1
fi

if [ "$ok_count" -eq 0 ] && [ "$fail_count" -eq 0 ]; then
    # Enumeration itself produced nothing at all (old git without -z
    # support, or some other failure) -- fall back to installing only into
    # this worktree, so a genuine enumeration failure still leaves SOME
    # protection rather than none. This is ITSELF the partial-coverage case
    # Enumeration failing means this script has
    # NO IDEA whether other worktrees exist, so even a successful install
    # here can only ever mean "this one location is covered" -- never
    # "every location is covered". Recorded via enumeration_failed, not
    # fail_count (there was no per-location failure to count -- the failure
    # is that enumeration could not tell us how many locations there are),
    # but it must drive the SAME non-zero-exit-on-anything-less-than-full-
    # coverage policy the fail_count>0 branch below enforces, or this path
    # keeps the exact "partial coverage indistinguishable from full
    # coverage" property that policy exists to prevent.
    echo "install-main-ref-transaction: could not enumerate worktrees (git worktree list --porcelain -z produced no output) -- installing only into this worktree; others are NOT covered" >&2
    enumeration_failed=1
    this_hooks_dir=$(git rev-parse --path-format=absolute --git-path hooks 2>/dev/null) || this_hooks_dir=""
    # Validate the VALUE, not just the exit status -- see the GIT VERSION
    # note above: git < 2.31 echoes an unrecognised --path-format=absolute
    # back as output and still exits 0.
    if ! looks_like_absolute_path "$this_hooks_dir"; then
        echo "install-main-ref-transaction: could not resolve an absolute hooks directory for this worktree (got: '$this_hooks_dir') -- refusing to install (this repo needs git >= 2.31 for --path-format, see this installer's own GIT VERSION note)" >&2
        exit 2
    fi
    if install_one_hook "$this_hooks_dir/reference-transaction"; then
        ok_count=$((ok_count + 1))
    else
        fail_count=$((fail_count + 1))
    fi
fi

if [ "$ok_count" -eq 0 ]; then
    echo "install-main-ref-transaction: every install attempt failed ($fail_count failure(s)) -- refusing to report success" >&2
    exit 2
fi
if [ "$fail_count" -gt 0 ]; then
    # Partial failure: some location(s) DID get the
    # guard installed -- those are kept, there is no rollback -- but a
    # caller that only checks this script's exit code must be able to tell
    # "every location is protected" apart from "some are, some are not".
    # Reporting exit 0 here made that impossible: a partially-covered repo
    # looked identical to a fully-covered one to anything scripting against
    # this installer. Exit non-zero so partial coverage is never
    # indistinguishable from complete coverage, while still leaving every
    # successfully-installed hook in place.
    echo "install-main-ref-transaction: WARNING: $fail_count of $((ok_count + fail_count)) location(s) did NOT get the guard installed (see above) -- those are NOT protected" >&2
    exit 1
fi
if [ "$enumeration_failed" -eq 1 ]; then
    echo "install-main-ref-transaction: WARNING: worktree enumeration failed, so coverage of any worktree OTHER than this one is UNKNOWN (not confirmed installed, not confirmed absent) -- re-run from each worktree individually to be sure" >&2
    exit 1
fi
exit 0
