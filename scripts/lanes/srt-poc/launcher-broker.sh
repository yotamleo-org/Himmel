#!/usr/bin/env bash
# launcher-broker.sh — POC. Runs OUTSIDE the sandbox, beside the
# launcher. Serves the two request kinds a sandboxed worker can make by dropping a
# file in <scratch>/req/:
#   <id>.push    one git-push argument per line -> push-wrapper.sh (worker branch fixed here)
#   <id>.domain  "<domain>\t<reason>"           -> chief ruling stand-in
# and answers with <id>.out then <id>.rc. A domain not on the approval list
# is denied (default on no answer is deny); an approved one is written to the
# control fifo as a full settings line, which srt applies to the running worker.
#
#   launcher-broker.sh <scratch> <worktree> <worker-branch> <ctl-fifo> <approve-file> <render-cmd-file> <approvals-log>
# <render-cmd-file> holds the render-settings.sh argument prefix (profile and roots), one per line.
# <approvals-log> must sit OUTSIDE every sandbox-writable root: the worker owns
# <scratch>, so a log there could be a planted symlink to a host file.
set -u

scratch="$1" worktree="$2" worker_branch="$3" ctl="$4" approve="$5" render_args="$6" approvals_log="${7:?approvals-log outside the writable roots}"
here="$(cd "$(dirname "$0")" && pwd)"
approved=()
rargs=()
while IFS= read -r a; do rargs+=("$a"); done <"$render_args"

while [ ! -f "$scratch/broker.stop" ]; do
    for f in "$scratch"/req/*.push "$scratch"/req/*.domain; do
        [ -f "$f" ] && [ -r "$f" ] || continue # unreadable request stays unanswered = denied
        [ -L "$f" ] && continue                # a symlinked request stays unanswered = denied
        base="${f%.*}"
        kind="${f##*.}"
        [ -f "$base.rc" ] && continue
        # the worker owns this directory: never write through a symlink it planted
        if [ -L "$base.out" ] || [ -L "$base.rc" ]; then continue; fi
        case "$kind" in
            push)
                args=()
                while IFS= read -r line; do args+=("$line"); done <"$f"
                (cd "$worktree" && bash "$here/push-wrapper.sh" --worker-branch "$worker_branch" -- "${args[@]}") >"$base.out" 2>&1
                echo $? >"$base.rc"
                ;;
            domain)
                IFS=$'\t' read -r dom reason <"$f"
                if grep -qxF "$dom" "$approve" 2>/dev/null; then
                    approved+=("$dom")
                    bash "$here/render-settings.sh" "${rargs[@]}" "${approved[@]}" >"$ctl"
                    echo "APPROVED $dom (reason: $reason)" >"$base.out"
                    echo "$(date +%H:%M:%S) approve $dom :: $reason" >>"$approvals_log"
                    echo 0 >"$base.rc"
                else
                    echo "DENIED $dom (no approval on record)" >"$base.out"
                    echo "$(date +%H:%M:%S) deny $dom :: $reason" >>"$approvals_log"
                    echo 1 >"$base.rc"
                fi
                ;;
        esac
    done
    sleep 0.2
done
