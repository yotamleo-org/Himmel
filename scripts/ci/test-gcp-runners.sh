#!/usr/bin/env bash
# scripts/ci/test-gcp-runners.sh -- regression suite for scripts/ci/gcp-runners.sh
# the ephemeral GCP spot runner pool. gcloud and gh are stubs on
# $GCLOUD / $GH; no live call is made. Pins: `up` refuses N above 4, every
# create is SPOT + max-run-duration + DELETE + labelled + impersonated and
# carries the registration token in a metadata FILE (never argv), `up` tops the
# pool up, `down` deletes every pool VM and deregisters offline gcp runners.
#
# Usage: bash scripts/ci/test-gcp-runners.sh
# Exit codes: 0 -- all cases passed; 1 -- at least one failed.
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
    *"instances delete"*) [ "${STUB_FAIL:-}" = delete ] && exit 1 ;;
esac
exit 0
STUB
cat > "$T/gh" <<'STUB'
#!/usr/bin/env bash
printf 'GH %s\n' "$*" >> "$STUB_LOG"
case "$*" in
    *registration-token*) echo "REGTOKEN-abc123" ;;
    *"actions/runners --jq"*) printf '4242\n' ;;
esac
exit 0
STUB
chmod +x "$T/gcloud" "$T/gh"

export GCLOUD="$T/gcloud" GH="$T/gh" STUB_LOG="$T/log" STUB_INSTANCES="$T/instances"
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
for f in '--provisioning-model=SPOT' '--max-run-duration=30m' '--instance-termination-action=DELETE' \
         '--labels=himmel-ci-runner=gcp' '--impersonate-service-account=himmel-ci-runner@himmel-ci.iam.gserviceaccount.com' \
         '--project=himmel-ci' '--no-service-account' '--no-scopes'; do
    n="$(grep 'instances create' "$STUB_LOG" | grep -cF -- "$f")"
    if [ "$n" -eq 2 ]; then ok "both creates carry $f"; else bad "creates carrying $f: $n of 2"; fi
done
total="$(grep -c '^GCLOUD ' "$STUB_LOG")"
imp="$(grep '^GCLOUD ' "$STUB_LOG" | grep -c -- '--impersonate-service-account=himmel-ci-runner@himmel-ci.iam.gserviceaccount.com')"
if [ "$total" -gt 0 ] && [ "$total" -eq "$imp" ]; then ok "all $total gcloud calls impersonate the runner SA"; else bad "impersonated $imp of $total gcloud calls"; fi

# 4. the registration token reaches the VM through a metadata file, never argv;
#    the startup script registers one --ephemeral runner labelled gcp.
if grep '^GCLOUD ' "$STUB_LOG" | grep -q 'REGTOKEN-abc123'; then bad "registration token leaked into a gcloud argv"; else ok "registration token is not in any gcloud argv"; fi
if grep -q '^FILE reg-token <<' "$STUB_LOG" && grep -q 'REGTOKEN-abc123' "$STUB_LOG"; then ok "registration token is passed as a metadata file"; else bad "registration token metadata file missing"; fi
if grep -q '^FILE startup-script <<' "$STUB_LOG" && grep -q -- '--ephemeral' "$STUB_LOG" && grep -q -- '--labels gcp' "$STUB_LOG"; then ok "startup script registers an --ephemeral runner labelled gcp"; else bad "startup script lacks --ephemeral / --labels gcp"; fi
if grep -q 'poweroff' "$STUB_LOG"; then ok "startup script powers the VM off after the one job"; else bad "startup script never powers off"; fi

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

# 7. unknown subcommand is refused.
rc="$(run frobnicate)"; if [ "$rc" -ne 0 ]; then ok "unknown subcommand is refused"; else bad "unknown subcommand accepted"; fi

if [ "$fails" -eq 0 ]; then echo "PASS: $0"; exit 0; fi
echo "FAILED: $fails case(s)" >&2
exit 1
