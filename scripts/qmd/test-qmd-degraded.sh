#!/usr/bin/env bash
# Unit tests for marketplace/plugins/qmd/scripts/qmd-degraded.sh.
#
# The detector classifies the host from two probes (nvidia-smi, vulkaninfo), so
# every case drives FAKE probes through the QMD_DEGRADED_* seams: hermetic, no
# GPU needed. The vulkaninfo fixture is copied from the real OVERLORD8 station
# (2026-10-14, RTX 4090 on RMA): `vulkaninfo --summary` lists only the RADV
# iGPU, and nvidia-smi prints "NVIDIA-SMI has failed ..." and exits 9.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$SCRIPT_DIR/../../marketplace/plugins/qmd/scripts/qmd-degraded.sh"

PASS=0
FAIL=0
TMP_ROOT="$(mktemp -d)" || exit 1
trap 'rm -rf "$TMP_ROOT"' EXIT

pass() { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; if [ $# -ge 2 ]; then printf '    %s\n' "$2"; fi; FAIL=$((FAIL+1)); }

mkfake() { # name, exit code, stdout
    printf '#!/usr/bin/env bash\nprintf "%%s\\n" %q\nexit %s\n' "$3" "$2" > "$TMP_ROOT/$1"
    chmod +x "$TMP_ROOT/$1"
}

# Real station captures (see header).
IGPU_ONLY=$'\tdeviceType         = PHYSICAL_DEVICE_TYPE_INTEGRATED_GPU\n\tdeviceName         = AMD Ryzen 9 7950X3D 16-Core Processor (RADV RAPHAEL_MENDOCINO)\n\tdriverName         = radv'
WITH_4090=$'\tdeviceType         = PHYSICAL_DEVICE_TYPE_DISCRETE_GPU\n\tdeviceName         = NVIDIA GeForce RTX 4090\n\tdriverName         = NVIDIA\n\tdeviceType         = PHYSICAL_DEVICE_TYPE_INTEGRATED_GPU\n\tdeviceName         = AMD Ryzen 9 7950X3D (RADV RAPHAEL_MENDOCINO)'
NV_FAIL="NVIDIA-SMI has failed because it couldn't communicate with the NVIDIA driver. Make sure that the latest NVIDIA driver is installed and running."
NV_OK="GPU 0: NVIDIA GeForce RTX 4090 (UUID: GPU-x)"

run() { # nvidia-smi fake, vulkaninfo fake -> sets OUT, RC
    set +e
    OUT="$(QMD_DEGRADED_NVIDIA_SMI="$TMP_ROOT/$1" QMD_DEGRADED_VULKANINFO="$TMP_ROOT/$2" bash "$SCRIPT" 2>&1)"
    RC=$?
    set -e
}

echo "qmd-degraded.sh"

mkfake nv_fail 9 "$NV_FAIL"; mkfake nv_ok 0 "$NV_OK"
mkfake vk_igpu 0 "$IGPU_ONLY"; mkfake vk_4090 0 "$WITH_4090"; mkfake vk_none 1 ""

run nv_fail vk_igpu
if [ "$RC" = 10 ] && grep -qF 'degraded' <<<"$OUT" && grep -qF 'rerank' <<<"$OUT"; then pass "iGPU only, no NVIDIA -> degraded rc 10 naming rerank"; else fail "iGPU only" "rc=$RC out=$OUT"; fi

run nv_ok vk_4090
if [ "$RC" = 0 ] && grep -qF 'ok' <<<"$OUT"; then pass "4090 back -> ok rc 0 (auto-reverts)"; else fail "4090 back" "rc=$RC out=$OUT"; fi

run nv_ok vk_igpu
if [ "$RC" = 0 ]; then pass "NVIDIA works, Vulkan lists only iGPU -> ok (not our failure shape)"; else fail "nvidia ok" "rc=$RC out=$OUT"; fi

run nv_fail vk_none
if [ "$RC" = 0 ]; then pass "no NVIDIA and no Vulkan iGPU -> ok (CPU-only host, nothing to hang)"; else fail "no vulkan" "rc=$RC out=$OUT"; fi

run nv_fail vk_4090
if [ "$RC" = 0 ]; then pass "NVIDIA smi failing but a discrete GPU is listed -> ok (not iGPU only)"; else fail "discrete listed" "rc=$RC out=$OUT"; fi

QMD_DEGRADED_NVIDIA_SMI="$TMP_ROOT/missing" QMD_DEGRADED_VULKANINFO="$TMP_ROOT/vk_igpu" bash "$SCRIPT" >/dev/null 2>&1 && RC=0 || RC=$?
if [ "$RC" = 10 ]; then pass "nvidia-smi not installed + iGPU -> degraded"; else fail "missing nvidia-smi" "rc=$RC"; fi

FLAG="$TMP_ROOT/state/qmd-degraded.flag"
runflag() {
    set +e
    OUT="$(QMD_DEGRADED_FLAG="$FLAG" QMD_DEGRADED_NVIDIA_SMI="$TMP_ROOT/$1" QMD_DEGRADED_VULKANINFO="$TMP_ROOT/$2" bash "$SCRIPT" --write-flag 2>&1)"
    RC=$?
    set -e
}
runflag nv_fail vk_igpu
if [ "$RC" = 10 ] && [ -s "$FLAG" ] && grep -qF 'degraded' "$FLAG"; then pass "--write-flag creates the flag when degraded"; else fail "flag create" "rc=$RC"; fi
runflag nv_ok vk_4090
if [ "$RC" = 0 ] && [ ! -e "$FLAG" ]; then pass "--write-flag removes the flag when the 4090 is back"; else fail "flag remove" "rc=$RC"; fi

echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = 0 ]
