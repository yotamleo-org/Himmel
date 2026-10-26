# shellcheck shell=bash
# _lib.sh - shared helpers for the fold arm's VM proof scripts. Sourced, never run.
# Each proof script runs from the primary checkout root (run.sh does the cd), drives
# one himmel-ar clone through vmsdk.py and guest-exec.sh only, and ends with one
# `PROOF: PASS|FAIL` line. run.sh holds the vm-lock for the VM around the call.
# ponytail: one fixed VM per run, set FVK_VM for another clone.
set -uo pipefail

VM="${FVK_VM:-himmel-ar-2}"
SNAP="${FVK_SNAP:-suite-ready-v4}"
# shellcheck source=../../../../../lib/prim.sh
. "$(dirname "${BASH_SOURCE[0]}")/../../../../../lib/prim.sh" || exit 2
WORK="$(tmpdir)" || { echo "PROOF: FAIL (no work dir)"; exit 2; }
FAILS=0

sdk() {
    if command -v uv >/dev/null 2>&1; then uv run --quiet scripts/lib/vmsdk.py "$VM" "$@"; else python3 scripts/lib/vmsdk.py "$VM" "$@"; fi
}

# g <timeout> <cmd...> - one guest command, its output on stdout, its rc returned
g() { local t="$1"; shift; bash scripts/vm/guest-exec.sh "$VM" --timeout "$t" -- "$@"; }

vm_fresh() {
    sdk restore "$SNAP" || { echo "CHECK vm-restore FAIL"; final; }
    sdk up || { echo "CHECK vm-up FAIL"; final; }
    trap vm_off EXIT
}

vm_off() { sdk down >/dev/null 2>&1; rm -rf "$WORK"; }

# stage <sha> <guest dir> [extra ref...] - the commit (plus any tags named) as a git clone on the guest
stage() {
    local sha="$1" dest="$2"; shift 2
    local bare="$WORK/stage.git" refs=(refs/heads/eval) r
    git init -q --bare "$bare"
    git -C "$bare" fetch -q --no-tags "$PWD" "$sha:refs/heads/eval" || { echo "CHECK stage-fetch FAIL $sha"; return 1; }
    for r in "$@"; do
        git -C "$bare" fetch -q --no-tags "$PWD" "refs/tags/$r:refs/tags/$r" && refs+=("refs/tags/$r")
    done
    git -C "$bare" bundle create -q "$WORK/stage.bundle" "${refs[@]}" || return 1
    sdk push "$WORK/stage.bundle" /tmp/fvk-stage.bundle >/dev/null || { echo "CHECK stage-push FAIL"; return 1; }
    rm -rf "$bare" "$WORK/stage.bundle"
    g 300 "rm -rf $dest && git clone -q /tmp/fvk-stage.bundle $dest && git -C $dest checkout -q --detach $sha && git -C $dest rev-parse HEAD"
}

# guest_script <name> - push $WORK/<name> to the guest and run it under bash
guest_script() {
    local name="$1" t="${2:-600}"
    sdk push "$WORK/$name" "/tmp/$name" >/dev/null || { echo "CHECK push-$name FAIL"; return 1; }
    g "$t" "bash /tmp/$name"
}

# check <name> <0|nonzero> [detail] - one expectation, as a CHECK line
check() {
    if [ "$2" = 0 ]; then echo "CHECK $1 PASS ${3:-}"; else echo "CHECK $1 FAIL ${3:-}"; FAILS=$((FAILS + 1)); fi
}

# expect <name> <haystack> <needle> - PASS when the needle is in the haystack
expect() { case "$2" in *"$3"*) check "$1" 0 ;; *) check "$1" 1 "missing: $3" ;; esac; }

# tally <output> - fold the guest script's own CHECK lines into FAILS
tally() {
    printf '%s\n' "$1"
    local n; n="$(printf '%s\n' "$1" | grep -c '^CHECK .* FAIL')"
    FAILS=$((FAILS + n))
    grep -q '^CHECK ' <<<"$1" || { echo "CHECK guest-output FAIL no CHECK lines"; FAILS=$((FAILS + 1)); }
}

final() {
    if [ "$FAILS" -eq 0 ]; then echo "PROOF: PASS"; else echo "PROOF: FAIL ($FAILS failed)"; fi
    exit 0
}
