#!/usr/bin/env bash
# scripts/ci/test-gcp-runners.sh -- regression suite for scripts/ci/gcp-runners.sh
# the ephemeral GCP spot runner pool. gcloud and gh are stubs on
# $GCLOUD / $GH; no live call is made. Pins: `up` refuses N above 4, every
# create is SPOT + max-run-duration + DELETE + labelled + impersonated and
# carries its own JIT config in a metadata FILE (never argv), `up` tops the
# pool up, `down` deletes every pool VM and deregisters offline gcp runners.
#
# Usage: bash scripts/ci/test-gcp-runners.sh
# Exit codes: 0 -- all cases passed; 1 -- at least one failed.
# shellcheck disable=SC2329  # the waitfor predicates are invoked indirectly
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SUT="$ROOT/scripts/ci/gcp-runners.sh"
fails=0
ok()  { echo "ok - $1"; }
bad() { echo "FAIL - $1" >&2; fails=$((fails + 1)); }

T="$(mktemp -d -t gcp-runners-test.XXXXXX)" || exit 1
trap 'rm -rf "$T"' EXIT

cat > "$T/gcloud" <<'STUB'
#!/usr/bin/env bash
# Logs one line per call; `instances list` prints $STUB_INSTANCES; a
# --metadata-from-file key=path is dumped so the test can read the files.
printf 'GCLOUD %s\n' "$*" >> "$STUB_LOG"
for a in "$@"; do
    case "$a" in
        --metadata-from-file=*)
            IFS=, read -ra kv <<< "${a#--metadata-from-file=}"
            for p in "${kv[@]}"; do
                printf 'FILE %s <<\n' "${p%%=*}" >> "$STUB_LOG"
                cat "${p#*=}" >> "$STUB_LOG"
                printf '\n>>\n' >> "$STUB_LOG"
            done ;;
    esac
done
case "$*" in
    *"instances list"*) [ "${STUB_FAIL:-}" = list ] && exit 1; cat "$STUB_INSTANCES" ;;
    *"subnets describe"*) [ "${STUB_FAIL:-}" = subnet ] && exit 1 ;;
    *"instances delete"*) [ "${STUB_FAIL:-}" = delete ] && exit 1 ;;
esac
exit 0
STUB
cat > "$T/gh" <<'STUB'
#!/usr/bin/env bash
printf 'GH %s\n' "$*" >> "$STUB_LOG"
case "$*" in
    *generate-jitconfig*) echo "JITCFG-abc123" ;;
    *"actions/runners --jq"*) printf '4242\n' ;;
    *"variable get CI_GCP"*) cat "$STUB_VAR" ;;
esac
exit 0
STUB
chmod +x "$T/gcloud" "$T/gh"

mkdir "$T/tmp" && export TMPDIR="$T/tmp"
export GCLOUD="$T/gcloud" GH="$T/gh" STUB_LOG="$T/log" STUB_INSTANCES="$T/instances" STUB_VAR="$T/civar" GCP_RUNNERS_LOCK="$T/lock"
run() { : > "$STUB_LOG"; bash "$SUT" "$@" > "$T/out" 2>&1; echo $?; }
creates() { grep -c 'instances create' "$STUB_LOG"; }

# 1. up refuses N above 4 and N that is not a positive integer; nothing is created.
: > "$STUB_INSTANCES"
for n in 5 0 abc; do
    rc="$(run up "$n")"
    if [ "$rc" -ne 0 ] && [ "$(creates)" -eq 0 ]; then ok "up $n is refused"; else bad "up $n: rc=$rc creates=$(creates)"; fi
done

# 2. up 4 is allowed; up with no N defaults to 2.
rc="$(run up 4)"; if [ "$rc" -eq 0 ] && [ "$(creates)" -eq 4 ]; then ok "up 4 creates 4"; else bad "up 4: rc=$rc creates=$(creates)"; fi
rc="$(run up)";   if [ "$rc" -eq 0 ] && [ "$(creates)" -eq 2 ]; then ok "up defaults to 2"; else bad "up default: rc=$rc creates=$(creates)"; fi

# 3. every create carries the safety flags; every gcloud call is impersonated.
rc="$(run up 2)"
for f in '--provisioning-model=SPOT' '--max-run-duration=45m' '--instance-termination-action=DELETE' \
         '--labels=himmel-ci-runner=gcp' '--impersonate-service-account=himmel-ci-runner@himmel-ci.iam.gserviceaccount.com' \
         '--project=himmel-ci' '--no-service-account' '--no-scopes' '--network=himmel-ci-net' '--subnet=himmel-ci-net' '--no-address' '--zone=us-central1-a'; do
    n="$(grep 'instances create' "$STUB_LOG" | grep -cF -- "$f")"
    if [ "$n" -eq 2 ]; then ok "both creates carry $f"; else bad "creates carrying $f: $n of 2"; fi
done
total="$(grep -c '^GCLOUD ' "$STUB_LOG")"
imp="$(grep '^GCLOUD ' "$STUB_LOG" | grep -c -- '--impersonate-service-account=himmel-ci-runner@himmel-ci.iam.gserviceaccount.com')"
if [ "$total" -gt 0 ] && [ "$total" -eq "$imp" ]; then ok "all $total gcloud calls impersonate the runner SA"; else bad "impersonated $imp of $total gcloud calls"; fi

# 4. each VM gets its own JIT config through a metadata file, never argv; the
#    startup script runs it behind the runner-side fork guard, then powers off.
if grep '^GCLOUD ' "$STUB_LOG" | grep -q 'JITCFG-abc123'; then bad "JIT config leaked into a gcloud argv"; else ok "JIT config is not in any gcloud argv"; fi
if grep -q '^FILE jit-config <<' "$STUB_LOG" && grep -q 'JITCFG-abc123' "$STUB_LOG"; then ok "JIT config is passed as a metadata file"; else bad "JIT config metadata file missing"; fi
if ! grep -q 'registration-token' "$STUB_LOG"; then ok "no shared registration token is requested"; else bad "registration token still requested"; fi
n="$(grep -c 'generate-jitconfig' "$STUB_LOG")"; if [ "$n" -eq 2 ]; then ok "one JIT config per VM"; else bad "JIT configs requested: $n of 2"; fi
if grep 'generate-jitconfig' "$STUB_LOG" | grep -qF 'labels[]=gcp' && grep 'generate-jitconfig' "$STUB_LOG" | grep -q 'name=himmel-ci-'; then ok "JIT config carries the gcp label and a unique name"; else bad "JIT config lacks gcp label / name"; fi
if grep -q '^FILE startup-script <<' "$STUB_LOG" && grep -q -- '--jitconfig' "$STUB_LOG"; then ok "startup script starts the runner with --jitconfig"; else bad "startup script lacks --jitconfig"; fi
if grep -q 'ACTIONS_RUNNER_HOOK_JOB_STARTED' "$STUB_LOG" && grep -q '^FILE job-started-hook <<' "$STUB_LOG" && grep -q 'fork guard' "$STUB_LOG"; then ok "fork guard hook is installed and wired as the job-started hook"; else bad "fork guard hook not wired"; fi
if grep -q 'poweroff' "$STUB_LOG"; then ok "startup script powers the VM off after the one job"; else bad "startup script never powers off"; fi

# 4b. the per-VM JIT config files are removed when up exits.
if [ -z "$(ls -A "$TMPDIR")" ]; then ok "up leaves no JIT config on disk"; else bad "up left files in TMPDIR: $(ls "$TMPDIR")"; fi

# 5. up tops the pool back to N: one existing VM means one create for up 2.
printf 'himmel-ci-existing-1\n' > "$STUB_INSTANCES"
rc="$(run up 2)"; if [ "$rc" -eq 0 ] && [ "$(creates)" -eq 1 ]; then ok "up 2 with 1 live VM creates 1"; else bad "top-up: rc=$rc creates=$(creates)"; fi
printf 'a\nb\n' > "$STUB_INSTANCES"
rc="$(run up 2)"; if [ "$rc" -eq 0 ] && [ "$(creates)" -eq 0 ]; then ok "up 2 with 2 live VMs creates 0"; else bad "full pool: rc=$rc creates=$(creates)"; fi

# 6. down deletes every pool VM, creates none, deregisters the offline gcp runner.
printf 'vm-a\nvm-b\n' > "$STUB_INSTANCES"
rc="$(run down)"
if [ "$rc" -eq 0 ] && [ "$(creates)" -eq 0 ]; then ok "down exits 0 and creates nothing"; else bad "down: rc=$rc creates=$(creates)"; fi
if grep 'instances delete' "$STUB_LOG" | grep -q 'vm-a' && grep 'instances delete' "$STUB_LOG" | grep -q 'vm-b'; then ok "down deletes every pool VM"; else bad "down did not delete vm-a and vm-b"; fi
if grep -q 'GH api -X DELETE repos/yotamleo/Himmel/actions/runners/4242' "$STUB_LOG"; then ok "down deregisters the offline gcp runner"; else bad "down did not deregister the offline runner"; fi

# 6b. a failed pool listing is an error, never an empty pool; a failed delete fails down.
export STUB_FAIL=list
rc="$(run up 2)"; if [ "$rc" -ne 0 ] && [ "$(creates)" -eq 0 ]; then ok "up refuses to create when pool discovery fails"; else bad "discovery failure: rc=$rc creates=$(creates)"; fi
export STUB_FAIL=delete
printf 'vm-a\n' > "$STUB_INSTANCES"
rc="$(run down)"; if [ "$rc" -ne 0 ] && ! grep -q 'pool deleted' "$T/out"; then ok "down fails when a delete fails"; else bad "down after failed delete: rc=$rc"; fi
unset STUB_FAIL

# 6c. watch tops up after a VM disappears and stops, running down, once CI_GCP is off.
printf 'a\nb\n' > "$STUB_INSTANCES"; echo on > "$STUB_VAR"; : > "$STUB_LOG"
bash "$SUT" watch 2 --interval 1 > "$T/watch.out" 2>&1 &
wpid=$!
waitfor() { local _; for _ in $(seq 1 100); do "$@" && return 0; sleep 0.1; done; return 1; }
listed() { grep -q "instances list" "$STUB_LOG"; }
topped() { [ "$(creates)" -ge 1 ]; }
stopped() { ! kill -0 "$wpid" 2>/dev/null; }
if waitfor listed && [ "$(creates)" -eq 0 ]; then ok "watch creates nothing while the pool is full"; else bad "watch first pass: creates=$(creates)"; fi
printf 'a\n' > "$STUB_INSTANCES"
if waitfor topped; then ok "watch tops the pool up after a VM disappears"; else bad "watch never topped up"; fi
echo off > "$STUB_VAR"
if waitfor stopped; then ok "watch exits once CI_GCP is off"; else bad "watch still running after CI_GCP off"; kill "$wpid" 2>/dev/null; fi
if grep -q 'instances delete' "$STUB_LOG" && grep -q 'pool deleted' "$T/watch.out"; then ok "watch runs down on exit"; else bad "watch did not run down"; fi
rc="$(run watch 5)"; if [ "$rc" -ne 0 ] && [ "$(creates)" -eq 0 ]; then ok "watch 5 is refused"; else bad "watch 5: rc=$rc"; fi

# 6d. a second up while another holds the lock creates nothing.
: > "$STUB_INSTANCES"
( flock 9; sleep 3 ) 9> "$GCP_RUNNERS_LOCK" &
holder=$!
sleep 0.5
rc="$(run up 2)"; if [ "$rc" -ne 0 ] && [ "$(creates)" -eq 0 ]; then ok "up refuses while another up holds the lock"; else bad "locked up: rc=$rc creates=$(creates)"; fi
wait "$holder"
rc="$(run up 2)"; if [ "$rc" -eq 0 ] && [ "$(creates)" -eq 2 ]; then ok "up proceeds once the lock is free"; else bad "unlocked up: rc=$rc creates=$(creates)"; fi

# 6e. up and watch refuse while the dedicated subnet is missing, naming gcp-net.sh.
export STUB_FAIL=subnet
: > "$STUB_INSTANCES"
rc="$(run up 2)"; if [ "$rc" -ne 0 ] && [ "$(creates)" -eq 0 ] && grep -q 'gcp-net.sh' "$T/out"; then ok "up refuses without the dedicated subnet"; else bad "no-subnet up: rc=$rc creates=$(creates)"; fi
rc="$(run watch 2 --interval 1)"; if [ "$rc" -ne 0 ] && [ "$(creates)" -eq 0 ]; then ok "watch refuses without the dedicated subnet"; else bad "no-subnet watch: rc=$rc"; fi
unset STUB_FAIL

# 7. unknown subcommand is refused.
rc="$(run frobnicate)"; if [ "$rc" -ne 0 ]; then ok "unknown subcommand is refused"; else bad "unknown subcommand accepted"; fi

if [ "$fails" -eq 0 ]; then echo "PASS: $0"; exit 0; fi
echo "FAILED: $fails case(s)" >&2
exit 1
