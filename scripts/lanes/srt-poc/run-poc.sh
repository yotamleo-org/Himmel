#!/usr/bin/env bash
# shellcheck disable=SC2015,SC2016
# run-poc.sh — POC driver. Run on a throwaway test VM guest, never
# the station. Builds a scratch repo, a VM-local bare origin outside every
# writable root and a dummy credential file, then runs worker-battery.sh under
# `srt claude` (a stub `claude` execs the battery, no model, no gateway).
#
#   SRT=<path to srt> bash run-poc.sh <impl|research|failure-modes>
#
# Prints the ROW lines of worker-battery.sh plus the launcher-side assertions.
set -u
# the full repository-redirecting set, as scripts/lib/git-clean.sh git_env_scrub
# (inline: this script runs where the lib may not be reachable)
unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE \
    GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_PREFIX \
    GIT_IMPLICIT_WORK_TREE GIT_GRAFT_FILE \
    GIT_REPLACE_REF_BASE GIT_SHALLOW_FILE GIT_CONFIG \
    GIT_CONFIG_PARAMETERS GIT_CONFIG_COUNT

HERE="$(cd "$(dirname "$0")" && pwd)"
SRT="${SRT:-srt}"
mode="${1:-impl}"
run_rc=0
# cleanup removes only files this run created: record what already exists
outside_pre=0
[ -e "$HOME/outside-write.txt" ] && outside_pre=1
dummy_made=0
base="$HOME/poc-$mode"
REQ_DOMAIN="${POC_REQ_DOMAIN:-example.com}"
DENY_DOMAIN="${POC_DENY_DOMAIN:-example.org}"

echo "srt: $("$SRT" --version 2>&1 | head -1)"
echo "mode: $mode  base: $base"

fresh() {
    rm -rf "$base"
    mkdir -p "$base"/{scratch/req,handover,victim,bin}
    echo precious >"$base/victim/keep.txt"
    git init -q --bare "$base/origin.git"
    git init -q --bare "$base/scratch/inside-origin.git"
    git clone -q "$base/origin.git" "$base/wt" 2>/dev/null
    (
        cd "$base/wt" || exit 1
        git config user.email t@example.invalid
        git config user.name t
        git checkout -q -b main
        echo base >README
        git add README
        git commit -q -m base
        git push -q origin main
        git checkout -q -b feat/poc
    )
    # dummy credential, removed at the end (never a real key)
    mkdir -p "$HOME/.ssh"
    if [ ! -e "$HOME/.ssh/poc_dummy" ]; then
        echo "not-a-real-key" >"$HOME/.ssh/poc_dummy"
        dummy_made=1
    fi
    printf '#!/usr/bin/env bash\nexec bash "%s/worker-battery.sh"\n' "$HERE" >"$base/bin/claude"
    chmod +x "$base/bin/claude"
}

launch() { # <profile> -> runs the battery under srt claude
    profile="$1"
    # one argument per line, so a path with spaces or globs stays one word
    printf '%s\n' "$profile" "$base/wt" "$base/scratch" "$base/handover" >"$base/render.args"
    rargs=()
    while IFS= read -r a; do rargs+=("$a"); done <"$base/render.args"
    bash "$HERE/render-settings.sh" "${rargs[@]}" >"$base/settings.json"
    # launch-time assertion: srt starts on defaults when settings are absent
    if [ ! -s "$base/settings.json" ] || ! grep -q allowedDomains "$base/settings.json"; then
        echo "ASSERT settings-not-loaded: refusing to launch"
        return 3
    fi
    echo "ASSERT settings-loaded: $(wc -c <"$base/settings.json") bytes, profile=$profile"
    main_before="$(git --git-dir="$base/origin.git" rev-parse main)"
    echo "$REQ_DOMAIN" >"$base/approve.list"
    mkfifo "$base/ctl"
    exec 4<>"$base/ctl"
    bash "$HERE/launcher-broker.sh" "$base/scratch" "$base/wt" feat/poc "$base/ctl" "$base/approve.list" "$base/render.args" "$base/approvals.log" &
    broker=$!
    env PATH="$base/bin:$PATH" POC_PROFILE="$profile" POC_WT="$base/wt" POC_SCRATCH="$base/scratch" \
        POC_VICTIM="$base/victim" POC_ORIGIN="$base/origin.git" POC_INSIDE_ORIGIN="$base/scratch/inside-origin.git" \
        POC_DENIED_FILE="$HOME/.ssh/poc_dummy" POC_HOME_OUTSIDE="$HOME/outside-write.txt" \
        POC_REQ_DOMAIN="$REQ_DOMAIN" POC_DENY_DOMAIN="$DENY_DOMAIN" \
        "$SRT" --settings "$base/settings.json" --control-fd 3 claude 3<"$base/ctl" >"$base/run.out" 2>&1
    srt_rc=$?
    cat "$base/run.out"
    echo "srt exit rc=$srt_rc"
    [ "$srt_rc" -eq 0 ] || run_rc=1
    if grep -q '^ROW .* FAIL' "$base/run.out"; then run_rc=1; fi
    # every profile row must be present and PASS, not just one row and no FAIL
    want=(B0-worker-commit B1-benign-python B2-rm-rf-outside B3-write-outside B4-direct-force-push-outside
        B5-force-push-inside-root-passes B6-wrapper-own-branch B7-wrapper-refuses-force B8-wrapper-refuses-main
        B8b-wrapper-refuses-plus B9-credential-read B10-allowed-host B11-proxy-bypass B12-profile-domain B15-worktree-commit)
    case "$profile" in
        impl) want+=(B13-domain-request-approved B14-domain-request-default-deny) ;;
        research) want+=(B12b-research-not-unlimited) ;;
    esac
    for r in "${want[@]}"; do
        grep -q "^ROW $r PASS" "$base/run.out" || { echo "ASSERT FAIL row $r missing or not PASS"; run_rc=1; }
    done
    touch "$base/scratch/broker.stop"
    wait "$broker" 2>/dev/null
    exec 4>&-
    [ -f "$base/approvals.log" ] && { echo "approvals.log:"; cat "$base/approvals.log"; } # fail-open-ok: report output only, no decision reads it
    echo "origin.git refs after run:"
    git --git-dir="$base/origin.git" for-each-ref --format='  %(refname) %(objectname:short)'
    now="$(git --git-dir="$base/origin.git" rev-parse main)"
    if [ "$now" = "$main_before" ]; then echo "ASSERT origin main untouched: $now"; else echo "ASSERT FAIL origin main moved: $main_before -> $now"; run_rc=1; fi
}

case "$mode" in
    impl | research)
        fresh
        launch "$mode" || run_rc=1
        ;;
    failure-modes)
        fresh
        bash "$HERE/render-settings.sh" impl "$base/wt" "$base/scratch" "$base/handover" >"$base/empty.json"
        : >"$base/zero.json"
        # F1-F3 must REFUSE: a zero exit or a RAN line means srt ran unsandboxed
        refused() { # <label> <rc> <output file>
            if [ "$2" -eq 0 ] || grep -q RAN "$3"; then echo "ASSERT FAIL $1 did not refuse"; run_rc=1; fi
        }
        echo "F1 invalid settings (zero bytes):"
        "$SRT" --settings "$base/zero.json" -c 'echo RAN' >"$base/f.out" 2>&1; f_rc=$?
        cat "$base/f.out"; echo "  rc=$f_rc (nonzero = refuses)"
        refused F1 "$f_rc" "$base/f.out"
        echo "F2 missing --settings file:"
        "$SRT" --settings "$base/nope.json" -c 'echo RAN' >"$base/f.out" 2>&1; f_rc=$?
        cat "$base/f.out"; echo "  rc=$f_rc (nonzero = refuses)"
        refused F2 "$f_rc" "$base/f.out"
        echo "F3 bwrap absent from PATH:"
        mkdir -p "$base/nobwrap"
        for t in bash env sh socat rg node; do ln -sf "$(command -v "$t")" "$base/nobwrap/$t"; done
        # resolve srt BEFORE restricting PATH: command-not-found must not pass as a refusal
        if srt_bin="$(command -v "$SRT")"; then
            env PATH="$base/nobwrap" "$srt_bin" --settings "$base/empty.json" -c 'echo RAN' >"$base/f.out" 2>&1; f_rc=$?
            cat "$base/f.out"; echo "  rc=$f_rc (nonzero + no RAN = refuses, not unsandboxed)"
            refused F3 "$f_rc" "$base/f.out"
            grep -q 'Sandbox dependencies not available' "$base/f.out" || { echo "ASSERT FAIL F3 refused without srt's dependency error"; run_rc=1; }
        else
            echo "ASSERT FAIL F3 srt not resolvable: $SRT"; run_rc=1
        fi
        echo "F4 settings file absent, no --settings (the launcher assertion exists for this):"
        mkdir -p "$base/emptyhome"
        env HOME="$base/emptyhome" "$SRT" -c 'echo RAN; ls "$HOME" >/dev/null && echo defaults-start' >"$base/f.out" 2>&1; f_rc=$?
        cat "$base/f.out"; echo "  rc=$f_rc (RAN = starts on built-in defaults)"
        if [ "$f_rc" -eq 0 ] && grep -qx RAN "$base/f.out" && grep -qx defaults-start "$base/f.out"; then
            echo "ASSERT F4 srt starts on defaults without --settings (the launcher assertion is required)"
        else
            echo "ASSERT FAIL F4 did not start on defaults: recheck the launcher assertion premise"; run_rc=1
        fi
        ;;
    *)
        echo "usage: run-poc.sh impl|research|failure-modes" >&2
        exit 2
        ;;
esac
if [ "$dummy_made" -eq 1 ]; then rm -f "$HOME/.ssh/poc_dummy"; fi
if [ "$outside_pre" -eq 0 ]; then rm -f "$HOME/outside-write.txt"; fi
exit "$run_rc"
