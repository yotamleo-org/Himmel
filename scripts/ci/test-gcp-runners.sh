#!/usr/bin/env bash
# scripts/ci/test-gcp-runners.sh -- regression suite for scripts/ci/gcp-runners.sh
# the ephemeral GCP spot runner pool. gcloud and gh are stubs on
# $GCLOUD / $GH; no live call is made. Pins: `up` refuses N above 1, every
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
    *"instances remove-metadata"*) [ "${STUB_FAIL:-}" = rmmeta ] && exit 1 ;;
    *"instances create"*) [ "${STUB_FAIL:-}" = create ] && { echo "ERROR: (gcloud.compute.instances.create) Could not fetch resource:" >&2; echo " - Quota 'CPUS' exceeded.  Limit: 8.0 in region us-central1." >&2; exit 1; } ;;
    *"instances describe"*)
        d="$4"
        [ "${STUB_GONE:-}" = 1 ] && { echo "ERROR: (gcloud.compute.instances.describe) Could not fetch resource:" >&2; echo " - The resource 'projects/himmel-ci/zones/us-central1-a/instances/$d' was not found" >&2; exit 1; }
        [ "${STUB_GONE:-}" = other ] && { echo "ERROR: (gcloud.compute.instances.describe) Could not fetch resource:" >&2; echo " - The resource 'projects/himmel-ci/zones/us-central1-a/instances/x' was not found" >&2; exit 1; }
        [ "${STUB_GONE:-}" = err ] && { echo "ERROR: (gcloud.compute.instances.describe) HTTPError 503: backend error" >&2; exit 1; } ;;
    *"regions describe"*)
        # the installed gcloud rejects --filter on regions describe (unrecognized arguments)
        case "$*" in *--filter*) echo "ERROR: (gcloud.compute.regions.describe) unrecognized arguments: --filter=quotas.metric=CPUS" >&2; exit 2 ;; esac
        [ "${STUB_FAIL:-}" = quota ] && exit 1
        # --flatten=quotas --format=value(quotas.metric,quotas.limit,quotas.usage): one tab-separated row per quota
        printf 'INSTANCES\t24000.0\t2.0\nCPUS\t%s\nCPUS_ALL_REGIONS\t12.0\t3.0\n' "${STUB_QUOTA:-8.0	1.0}" ;;
esac
exit 0
STUB
cat > "$T/gh" <<'STUB'
#!/usr/bin/env bash
printf 'GH %s\n' "$*" >> "$STUB_LOG"
case "$*" in
    *generate-jitconfig*) [ "${STUB_FAIL:-}" = jit ] && exit 1; echo "JITCFG-abc123" ;;
    *'status=="online"'*) [ "${STUB_ONLINE:-}" = none ] || grep -o 'name=himmel-ci-[^ ]*' "$STUB_LOG" | cut -d= -f2 ;;
    *"actions/runners --jq"*'select(.name=='*)
        rn="$(printf '%s' "$*" | sed -n 's/.*select(\.name=="\([^"]*\)").*/\1/p')"
        [ -n "$rn" ] && grep -qF "name=$rn" "$STUB_LOG" && printf '4242\n' ;;
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

# 1. up refuses N above 1 (the 8-vCPU CPUS pin minus the proxy's 1 vCPU leaves room for one
#    e2-standard-4) and N that is not a positive integer; nothing is created.
: > "$STUB_INSTANCES"
for n in 2 3 5 0 abc; do
    rc="$(run up "$n")"
    if [ "$rc" -ne 0 ] && [ "$(creates)" -eq 0 ]; then ok "up $n is refused"; else bad "up $n: rc=$rc creates=$(creates)"; fi
done

# 1b. the quota arithmetic behind the cap: the measured CPUS usage with only the proxy up is 1.0
#     (the e2-micro counts as a whole vCPU), so the runners get 8 - 1 = 7 vCPUs. The cap fits
#     in that and one more VM does not; a 2nd runner is refused before any JIT request or create.
cap="$(sed -n 's/^MAX_N=\([0-9]*\).*/\1/p' "$SUT")"
vcpus="$(sed -n 's/^MACHINE=.*:-e2-standard-\([0-9]*\)}".*/\1/p' "$SUT")"
if [ -n "$cap" ] && [ -n "$vcpus" ] && [ $((1 + cap * vcpus)) -le 8 ] && [ $((1 + (cap + 1) * vcpus)) -gt 8 ]; then ok "MAX_N=$cap x $vcpus vCPU plus the 1-vCPU proxy fits the 8-vCPU pin, one more VM does not"; else bad "quota arithmetic: cap='$cap' vcpus='$vcpus'"; fi
printf 'himmel-ci-existing-1\n' > "$STUB_INSTANCES"
rc="$(run up 2)"
if [ "$rc" -ne 0 ] && [ "$(creates)" -eq 0 ] && ! grep -q 'generate-jitconfig' "$STUB_LOG"; then ok "a 2nd runner is refused before any JIT request or create"; else bad "2nd runner: rc=$rc creates=$(creates)"; fi
: > "$STUB_INSTANCES"

# 2. up 1 is allowed; up with no N defaults to 1.
rc="$(run up 1)"; if [ "$rc" -eq 0 ] && [ "$(creates)" -eq 1 ]; then ok "up 1 creates 1"; else bad "up 1: rc=$rc creates=$(creates)"; fi
rc="$(run up)";   if [ "$rc" -eq 0 ] && [ "$(creates)" -eq 1 ]; then ok "up defaults to 1"; else bad "up default: rc=$rc creates=$(creates)"; fi

# 3. every create carries the safety flags; every gcloud call is impersonated.
rc="$(run up 1)"
for f in '--provisioning-model=SPOT' '--max-run-duration=75m' '--instance-termination-action=DELETE' \
         '--labels=himmel-ci-runner=gcp' '--impersonate-service-account=himmel-ci-runner@himmel-ci.iam.gserviceaccount.com' \
         '--machine-type=e2-standard-4' '--boot-disk-type=pd-balanced' '--boot-disk-size=50GB' '--project=himmel-ci' '--no-service-account' '--no-scopes' '--network=himmel-ci-net' '--subnet=himmel-ci-net' '--no-address' '--zone=us-central1-a'; do
    n="$(grep 'instances create' "$STUB_LOG" | grep -cF -- "$f")"
    if [ "$n" -eq 1 ]; then ok "the create carries $f"; else bad "creates carrying $f: $n of 1"; fi
done
total="$(grep -c '^GCLOUD ' "$STUB_LOG")"
imp="$(grep '^GCLOUD ' "$STUB_LOG" | grep -c -- '--impersonate-service-account=himmel-ci-runner@himmel-ci.iam.gserviceaccount.com')"
if [ "$total" -gt 0 ] && [ "$total" -eq "$imp" ]; then ok "all $total gcloud calls impersonate the runner SA"; else bad "impersonated $imp of $total gcloud calls"; fi

# 4. each VM gets its own JIT config through a metadata file, never argv; the
#    startup script runs it behind the runner-side fork guard, then powers off.
if grep '^GCLOUD ' "$STUB_LOG" | grep -q 'JITCFG-abc123'; then bad "JIT config leaked into a gcloud argv"; else ok "JIT config is not in any gcloud argv"; fi
if grep -q '^FILE jit-config <<' "$STUB_LOG" && grep -q 'JITCFG-abc123' "$STUB_LOG"; then ok "JIT config is passed as a metadata file"; else bad "JIT config metadata file missing"; fi
if ! grep -q 'registration-token' "$STUB_LOG"; then ok "no shared registration token is requested"; else bad "registration token still requested"; fi
n="$(grep -c 'generate-jitconfig' "$STUB_LOG")"; if [ "$n" -eq 1 ]; then ok "one JIT config per VM"; else bad "JIT configs requested: $n of 1"; fi
if grep 'generate-jitconfig' "$STUB_LOG" | grep -qF 'labels[]=gcp' && grep 'generate-jitconfig' "$STUB_LOG" | grep -qF 'labels[]=self-hosted' && grep 'generate-jitconfig' "$STUB_LOG" | grep -q 'name=himmel-ci-'; then ok "JIT config carries the self-hosted and gcp labels and a unique name"; else bad "JIT config lacks labels / name"; fi
# shellcheck disable=SC2016  # the literal startup-script line, not an expansion
if grep -q '^FILE startup-script <<' "$STUB_LOG" && grep -q '^export ACTIONS_RUNNER_INPUT_JITCONFIG="$jit"' "$STUB_LOG" && ! grep -q -- '--jitconfig' "$STUB_LOG"; then ok "startup script hands the JIT config to run.sh through the environment, never argv"; else bad "startup script passes the JIT config on argv or not at all"; fi

# 4a. the subnet only lets tcp:3128 out: the proxy env is a metadata file, set before apt, kept in the runner .env.
if grep -q '^FILE proxy-env <<' "$STUB_LOG" && grep -q '^HTTPS_PROXY=http://[0-9.]*:3128$' "$STUB_LOG" && grep -q '^NO_PROXY=169.254.169.254' "$STUB_LOG"; then ok "proxy env is passed as the proxy-env metadata file"; else bad "proxy-env metadata file missing"; fi
# shellcheck disable=SC2016  # the literal startup-script text, not an expansion
if grep -q 'md proxy-env' "$STUB_LOG" && grep -q 'apt.conf.d/95ci-proxy' "$STUB_LOG" && grep -q '"\$proxy_env" > /opt/runner/.env || exit 1$' "$STUB_LOG" && grep -q '^chown runner:runner /opt/runner/.env || exit 1$' "$STUB_LOG"; then ok "startup script wires the proxy into apt and the runner .env"; else bad "startup script does not wire the proxy"; fi
pe="$(grep -n 'md proxy-env' "$STUB_LOG" | head -1 | cut -d: -f1)"; au="$(grep -n 'apt-get update' "$STUB_LOG" | head -1 | cut -d: -f1)"
if [ -n "$pe" ] && [ -n "$au" ] && [ "$pe" -lt "$au" ]; then ok "the proxy is set before the first apt call"; else bad "proxy set after apt (pe=$pe au=$au)"; fi

# 4c. the JIT config does not outlive its read: removed from instance metadata once the runner is online,
#     and the runner uid is walled off from the metadata server.
n="$(grep 'instances remove-metadata' "$STUB_LOG" | grep -c -- '--keys=jit-config')"
if [ "$n" -eq 1 ]; then ok "jit-config is removed from each VM's metadata"; else bad "remove-metadata calls: $n of 1"; fi
last_create="$(grep -n 'instances create' "$STUB_LOG" | tail -1 | cut -d: -f1)"; first_rm="$(grep -n 'instances remove-metadata' "$STUB_LOG" | head -1 | cut -d: -f1)"
if [ -n "$last_create" ] && [ -n "$first_rm" ] && [ "$first_rm" -gt "$last_create" ]; then ok "jit-config is removed only after the VMs are created"; else bad "remove-metadata order: create=$last_create rm=$first_rm"; fi
if grep -q 'iptables -A OUTPUT -d 169.254.169.254 -m owner --uid-owner runner -j REJECT' "$STUB_LOG"; then ok "startup script rejects metadata-server traffic from the runner uid"; else bad "no iptables owner-match REJECT"; fi
# shellcheck disable=SC2016  # the literal startup-script line, not an expansion
if grep -q "^printf 'ACTIONS_RUNNER_HOOK_JOB_STARTED=/usr/local/lib/himmel/job-started-hook.sh" "$STUB_LOG" && grep -q '^FILE job-started-hook <<' "$STUB_LOG" && grep -q 'fork guard' "$STUB_LOG"; then ok "fork guard hook is installed and wired as the job-started hook"; else bad "fork guard hook not wired"; fi
if grep -q '^md job-started-hook > /usr/local/lib/himmel/job-started-hook.sh || exit 1$' "$STUB_LOG" && grep -q '^\[ -s /usr/local/lib/himmel/job-started-hook.sh \] || exit 1$' "$STUB_LOG"; then ok "startup script fails closed on a missing or empty fork guard hook"; else bad "fork guard hook write is not checked"; fi
if grep -q 'poweroff' "$STUB_LOG"; then ok "startup script powers the VM off after the one job"; else bad "startup script never powers off"; fi
bun_want="$(tr -d '[:space:]' < "$ROOT/.bun-version")"
if grep -q "^BUN_VERSION=$bun_want\$" "$STUB_LOG" && grep -q '^BUN_SHA256=[0-9a-f]\{64\}$' "$STUB_LOG" && grep -q 'sha256sum -c' "$STUB_LOG" && grep -q 'install -D -m 755 -o runner -g runner .* /home/runner/.bun/bin/bun' "$STUB_LOG"; then ok "startup script bakes the pinned bun (sha256-checked) at the path setup-bun expects"; else bad "bun is not baked into the runner image"; fi
if grep -q '^python3 -m pip install --break-system-packages --ignore-installed .*pre-commit==' "$STUB_LOG"; then ok "pre-commit pip install ignores the apt-owned packaging (no uninstall)"; else bad "pip install can try to uninstall a debian package"; fi

# 4b. the per-VM JIT config files are removed when up exits.
if [ -z "$(ls -A "$TMPDIR")" ]; then ok "up leaves no JIT config on disk"; else bad "up left files in TMPDIR: $(ls "$TMPDIR")"; fi

# 4d. a runner that never comes online still loses its jit-config at the deadline.
export STUB_ONLINE=none GCP_RUNNERS_ONLINE_WAIT=1 GCP_RUNNERS_ONLINE_POLL=1
: > "$STUB_INSTANCES"
rc="$(run up 1)"
n="$(grep 'instances remove-metadata' "$STUB_LOG" | grep -c -- '--keys=jit-config')"
if [ "$rc" -eq 0 ] && [ "$n" -eq 1 ]; then ok "jit-config is removed even when the runner never comes online"; else bad "never-online: rc=$rc removals=$n"; fi
unset STUB_ONLINE GCP_RUNNERS_ONLINE_WAIT GCP_RUNNERS_ONLINE_POLL

# 5. up tops the pool back to N: an empty pool means one create, a full pool none.
: > "$STUB_INSTANCES"
rc="$(run up 1)"; if [ "$rc" -eq 0 ] && [ "$(creates)" -eq 1 ]; then ok "up 1 with an empty pool creates 1"; else bad "top-up: rc=$rc creates=$(creates)"; fi
printf 'a\n' > "$STUB_INSTANCES"
rc="$(run up 1)"; if [ "$rc" -eq 0 ] && [ "$(creates)" -eq 0 ]; then ok "up 1 with 1 live VM creates 0"; else bad "full pool: rc=$rc creates=$(creates)"; fi

# 6. down deletes every pool VM, creates none, deregisters the offline gcp runner.
printf 'vm-a\nvm-b\n' > "$STUB_INSTANCES"
rc="$(run down)"
if [ "$rc" -eq 0 ] && [ "$(creates)" -eq 0 ]; then ok "down exits 0 and creates nothing"; else bad "down: rc=$rc creates=$(creates)"; fi
if grep 'instances delete' "$STUB_LOG" | grep -q 'vm-a' && grep 'instances delete' "$STUB_LOG" | grep -q 'vm-b'; then ok "down deletes every pool VM"; else bad "down did not delete vm-a and vm-b"; fi
if grep -q 'GH api -X DELETE repos/yotamleo/Himmel/actions/runners/4242' "$STUB_LOG"; then ok "down deregisters the offline gcp runner"; else bad "down did not deregister the offline runner"; fi

# 6b. a failed pool listing is an error, never an empty pool; a failed delete fails down.
export STUB_FAIL=list
rc="$(run up 1)"; if [ "$rc" -ne 0 ] && [ "$(creates)" -eq 0 ]; then ok "up refuses to create when pool discovery fails"; else bad "discovery failure: rc=$rc creates=$(creates)"; fi
export STUB_FAIL=delete
printf 'vm-a\n' > "$STUB_INSTANCES"
rc="$(run down)"; if [ "$rc" -ne 0 ] && ! grep -q 'pool deleted' "$T/out"; then ok "down fails when a delete fails"; else bad "down after failed delete: rc=$rc"; fi
unset STUB_FAIL

# 6c. watch tops up after a VM disappears and stops, running down, once CI_GCP is off.
printf 'a\n' > "$STUB_INSTANCES"; echo on > "$STUB_VAR"; : > "$STUB_LOG"
bash "$SUT" watch 1 --interval 1 > "$T/watch.out" 2>&1 &
wpid=$!
waitfor() { local _; for _ in $(seq 1 100); do "$@" && return 0; sleep 0.1; done; return 1; }
# shellcheck disable=SC2317  # invoked indirectly through waitfor
listed() { grep -q "instances list" "$STUB_LOG"; }
# shellcheck disable=SC2317
topped() { [ "$(creates)" -ge 1 ]; }
# shellcheck disable=SC2317
stopped() { ! kill -0 "$wpid" 2>/dev/null; }
if waitfor listed && [ "$(creates)" -eq 0 ]; then ok "watch creates nothing while the pool is full"; else bad "watch first pass: creates=$(creates)"; fi
: > "$STUB_INSTANCES"
if waitfor topped; then ok "watch tops the pool up after a VM disappears"; else bad "watch never topped up"; fi
printf 'a\n' > "$STUB_INSTANCES"
echo off > "$STUB_VAR"
if waitfor stopped; then ok "watch exits once CI_GCP is off"; else bad "watch still running after CI_GCP off"; kill "$wpid" 2>/dev/null; fi
if grep -q 'instances delete' "$STUB_LOG" && grep -q 'pool deleted' "$T/watch.out"; then ok "watch runs down on exit"; else bad "watch did not run down"; fi
for n in 2 5; do
    rc="$(run watch "$n")"; if [ "$rc" -ne 0 ] && [ "$(creates)" -eq 0 ]; then ok "watch $n is refused"; else bad "watch $n: rc=$rc"; fi
done

# 6d. a second up while another holds the lock creates nothing.
: > "$STUB_INSTANCES"
if [ "$(uname -s)" = Linux ]; then
    ( flock 9; sleep 3 ) 9> "$GCP_RUNNERS_LOCK" &
    holder=$!
    sleep 0.5
    rc="$(run up 1)"; if [ "$rc" -ne 0 ] && [ "$(creates)" -eq 0 ]; then ok "up refuses while another up holds the lock"; else bad "locked up: rc=$rc creates=$(creates)"; fi
    wait "$holder"
    rc="$(run up 1)"; if [ "$rc" -eq 0 ] && [ "$(creates)" -eq 1 ]; then ok "up proceeds once the lock is free"; else bad "unlocked up: rc=$rc creates=$(creates)"; fi
else
    ok "flock lock cases skipped: not Linux"
fi

# 6f. flock is Linux-only: up refuses on any other platform before it creates anything.
: > "$STUB_INSTANCES"
rc="$(GCP_RUNNERS_UNAME=Darwin run up 1)"; if [ "$rc" -ne 0 ] && [ "$(creates)" -eq 0 ] && grep -q 'Linux' "$T/out"; then ok "up refuses off Linux"; else bad "non-Linux up: rc=$rc creates=$(creates)"; fi

# 6g. a failure part-way through `up` still strips jit-config from every VM already created.
export STUB_FAIL=create
rc="$(run up 1)"
n="$(grep 'instances remove-metadata' "$STUB_LOG" | grep -c -- '--keys=jit-config')"
if [ "$rc" -ne 0 ] && [ "$n" -eq 1 ]; then ok "a failed create drops jit-config from the VM attempted"; else bad "create fail: rc=$rc removals=$n of 1"; fi
export STUB_FAIL=jit
rc="$(run up 1)"
n="$(grep 'instances remove-metadata' "$STUB_LOG" | grep -c -- '--keys=jit-config')"
if [ "$rc" -ne 0 ] && [ "$n" -eq 0 ] && [ "$(creates)" -eq 0 ]; then ok "a failed JIT request creates no VM and removes nothing"; else bad "jit fail: rc=$rc removals=$n creates=$(creates)"; fi
unset STUB_FAIL

# 6g2. a create that failed and left no instance (quota, stockout) gets no remove-metadata or delete,
#      its minted runner registration is deleted, and the error names the instance.
#      The stub error is the real gcloud text from the live GCP runner drill.
export STUB_FAIL=create STUB_GONE=1
rc="$(run up 1)"
if [ "$rc" -ne 0 ] && ! grep -q 'instances remove-metadata' "$STUB_LOG" && ! grep -q 'instances delete' "$STUB_LOG" && grep -q 'instances create failed for himmel-ci-' "$T/out"; then ok "a create that left no instance makes no remove-metadata or delete call"; else bad "gone create: rc=$rc"; fi
if grep -q 'GH api -X DELETE repos/yotamleo/Himmel/actions/runners/4242' "$STUB_LOG"; then ok "the runner minted for a failed create is deleted"; else bad "orphan runner not deleted"; fi
unset STUB_FAIL STUB_GONE

# 6g2b. a describe that fails for any reason but not-found is uncertain: the VM is treated as
#       possibly live (jit-config stripped) and its runner registration is kept.
export STUB_FAIL=create STUB_GONE=err
rc="$(run up 1)"
if [ "$rc" -ne 0 ] && grep -q 'instances remove-metadata' "$STUB_LOG" && ! grep -q 'GH api -X DELETE' "$STUB_LOG"; then ok "an uncertain describe keeps the jit-config cleanup and the runner"; else bad "uncertain describe: rc=$rc"; fi
unset STUB_FAIL STUB_GONE
export STUB_FAIL=create STUB_GONE=other
rc="$(run up 1)"
if [ "$rc" -ne 0 ] && grep -q 'instances remove-metadata' "$STUB_LOG" && ! grep -q 'GH api -X DELETE' "$STUB_LOG"; then ok "a not-found for a different resource is treated as uncertain"; else bad "other not-found: rc=$rc"; fi
unset STUB_FAIL STUB_GONE

# 6g2c. a quota reading that is not a plain decimal fails closed.
for q in ".	1.0" "8.0	1..0"; do
    export STUB_QUOTA="$q"
    rc="$(run up 1)"
    if [ "$rc" -ne 0 ] && [ "$(creates)" -eq 0 ]; then ok "malformed quota '$q' refuses to create"; else bad "malformed quota '$q': rc=$rc creates=$(creates)"; fi
done
unset STUB_QUOTA

# 6g3. the regional CPUS quota is read before any JIT request or create; too little headroom
#      (limit capped at 8 vCPU) creates nothing; an unreadable quota fails closed.
: > "$STUB_INSTANCES"
for q in "8.0	7.0" "8.0	5.0" "16.0	6.0"; do
    export STUB_QUOTA="$q"
    rc="$(run up 1)"
    if [ "$rc" -ne 0 ] && [ "$(creates)" -eq 0 ] && ! grep -q 'generate-jitconfig' "$STUB_LOG" && grep -q 'CPUS' "$T/out"; then ok "quota '$q' leaves no headroom for 4 vCPU: nothing minted or created"; else bad "quota '$q': rc=$rc creates=$(creates)"; fi
done
export STUB_QUOTA="8.0	4.0"
rc="$(run up 1)"; if [ "$rc" -eq 0 ] && [ "$(creates)" -eq 1 ]; then ok "quota with exactly 4 vCPU headroom creates the VM"; else bad "exact headroom: rc=$rc"; fi
export STUB_QUOTA="8.0	4.0" GCP_RUNNERS_MACHINE=e2-custom-4-8192
rc="$(run up 1)"; if [ "$rc" -eq 0 ] && [ "$(creates)" -eq 1 ]; then ok "a custom machine type counts its vCPU field, not the memory"; else bad "custom machine: rc=$rc"; fi
export STUB_QUOTA="8.0	4.0" GCP_RUNNERS_MACHINE=n2-custom-4-32768-ext
rc="$(run up 1)"; if [ "$rc" -eq 0 ] && [ "$(creates)" -eq 1 ]; then ok "an extended-memory custom type (-ext suffix) counts its vCPU field"; else bad "custom -ext machine: rc=$rc"; fi
unset STUB_QUOTA GCP_RUNNERS_MACHINE
export STUB_FAIL=quota
rc="$(run up 1)"; if [ "$rc" -ne 0 ] && [ "$(creates)" -eq 0 ]; then ok "an unreadable quota refuses to create"; else bad "quota read fail: rc=$rc"; fi
unset STUB_FAIL

# 6h. a jit-config that cannot be removed gets its VM deleted and fails `up`.
export STUB_FAIL=rmmeta
rc="$(run up 1)"
if [ "$rc" -ne 0 ] && grep -q 'instances delete himmel-ci-' "$STUB_LOG" && ! grep -q 'created 1 VM' "$T/out"; then ok "an undroppable jit-config deletes the VM and fails up"; else bad "rmmeta fail: rc=$rc"; fi
unset STUB_FAIL

# 6i. bash 3.2 under set -u: the empty-array expansions are guarded on the executable lines.
# shellcheck disable=SC2016  # the literal script text, not an expansion
if grep -qF 'pending=(${left[@]+"${left[@]}"})' "$SUT" && ! grep -qF 'pending=("${left[@]}")' "$SUT"; then ok "drop_jit guards the empty left[] expansion"; else bad "drop_jit expands left[] unguarded"; fi

# 6j. startup script hardening, pinned on the executable lines.
SS="$ROOT/scripts/ci/gcp-runner-startup.sh"
if grep -q '^chown root:root /usr/local/lib/himmel/job-started-hook.sh || exit 1$' "$SS" && grep -q '^chmod 755 /usr/local/lib/himmel/job-started-hook.sh || exit 1$' "$SS"; then ok "fork guard hook chown/chmod fail closed"; else bad "hook chown/chmod can fail silently"; fi
if grep -q '^systemctl enable --now atd' "$SS" && ! grep '^systemctl enable --now atd' "$SS" | grep -q '|| true' && grep -q '^systemctl is-active --quiet atd || exit 1$' "$SS"; then ok "a failed atd start fails the startup"; else bad "atd start failure is swallowed"; fi
# Fixture: the checksum line of the pinned release's notes, copied from the real
# `gh api repos/actions/runner/releases/latest --jq .body` (v2.338.0).
fixture='- actions-runner-linux-x64-2.338.0.tar.gz <!-- BEGIN SHA linux-x64 -->af4b794c1bc41d73d40535e3fe092a39f9679cd8d965954c2aca25a05ca41d32<!-- END SHA linux-x64 -->'
fix_sha="$(sed -n 's/.*BEGIN SHA linux-x64 -->\([0-9a-f]\{64\}\)<!--.*/\1/p' <<< "$fixture")"
pin_ver="$(sed -n 's/^RUNNER_VERSION=\([0-9.]*\)$/\1/p' "$SS")"; pin_sha="$(sed -n 's/^RUNNER_SHA256=\([0-9a-f]\{64\}\)$/\1/p' "$SS")"
if [ "$pin_ver" = 2.338.0 ] && [ -n "$pin_sha" ] && [ "$pin_sha" = "$fix_sha" ]; then ok "startup script pins the runner version and the release's sha256"; else bad "runner pin: ver='$pin_ver' sha='$pin_sha'"; fi
if ! grep -q 'releases/latest' "$SS"; then ok "startup script no longer resolves the latest runner release"; else bad "startup script still resolves releases/latest"; fi
ck="$(grep -n 'sha256sum -c' "$SS" | head -1 | cut -d: -f1)"; tx="$(grep -n 'tar -xz' "$SS" | head -1 | cut -d: -f1)"
if [ -n "$ck" ] && [ -n "$tx" ] && [ "$ck" -lt "$tx" ] && grep 'sha256sum -c' "$SS" | grep -q '|| exit 1$'; then ok "the tarball checksum is verified, fail closed, before extract"; else bad "checksum check missing or after extract (ck=$ck tx=$tx)"; fi

# 6e. up and watch refuse while the dedicated subnet is missing, naming gcp-net.sh.
export STUB_FAIL=subnet
: > "$STUB_INSTANCES"
rc="$(run up 1)"; if [ "$rc" -ne 0 ] && [ "$(creates)" -eq 0 ] && grep -q 'gcp-net.sh' "$T/out"; then ok "up refuses without the dedicated subnet"; else bad "no-subnet up: rc=$rc creates=$(creates)"; fi
rc="$(run watch 1 --interval 1)"; if [ "$rc" -ne 0 ] && [ "$(creates)" -eq 0 ]; then ok "watch refuses without the dedicated subnet"; else bad "no-subnet watch: rc=$rc"; fi
unset STUB_FAIL

# 7. unknown subcommand is refused.
rc="$(run frobnicate)"; if [ "$rc" -ne 0 ]; then ok "unknown subcommand is refused"; else bad "unknown subcommand accepted"; fi

if [ "$fails" -eq 0 ]; then echo "PASS: $0"; exit 0; fi
echo "FAILED: $fails case(s)" >&2
exit 1
