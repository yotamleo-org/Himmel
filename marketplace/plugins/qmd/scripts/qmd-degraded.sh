#!/usr/bin/env bash
# qmd-degraded.sh — say whether qmd is running in the degraded iGPU shape
# Pure READ: two probes, no qmd call, no daemon touch.
#
# WHY: with the RTX 4090 away (RMA) the only Vulkan device is the RADV iGPU.
# Measured 2026-10-14: embed and vec search work there, but the reranker hangs
# on that device and poisons the process ("Rerank did not finish within
# 60000ms"), so every default `query` costs up to 60 s and then restarts the
# daemon. Nothing signalled it. The shape is derived from the hardware, not
# from a flag, so it reverts by itself when an NVIDIA GPU is back.
#
# DEGRADED = no working NVIDIA GPU (nvidia-smi absent or failing) AND Vulkan
# lists an INTEGRATED_GPU and no DISCRETE_GPU. Each probe is bounded to 5 s. Anything else is ok, including a CPU-only host
# (nothing to hang there).
#
# --write-flag also keeps ~/.himmel/state/qmd-degraded.flag in step: created
# (holding the line) when degraded, removed when ok, so it reverts by itself.
# ensure-qmd-daemon.sh runs it at every SessionStart and echoes the line.
#
# Exit: 0 ok | 10 degraded (one line on stdout either way).
# Seams (tests): QMD_DEGRADED_NVIDIA_SMI, QMD_DEGRADED_VULKANINFO, QMD_DEGRADED_FLAG.
set -uo pipefail

NVIDIA_SMI="${QMD_DEGRADED_NVIDIA_SMI:-nvidia-smi}"
VULKANINFO="${QMD_DEGRADED_VULKANINFO:-vulkaninfo}"

nvidia_ok=0
if command -v "$NVIDIA_SMI" >/dev/null 2>&1 && timeout 5 "$NVIDIA_SMI" -L >/dev/null 2>&1; then
    nvidia_ok=1
fi

igpu=0
if [ "$nvidia_ok" = 0 ] && command -v "$VULKANINFO" >/dev/null 2>&1; then
    vk="$(timeout 5 "$VULKANINFO" --summary 2>/dev/null)"
    if grep -qF PHYSICAL_DEVICE_TYPE_INTEGRATED_GPU <<<"$vk" && ! grep -qF PHYSICAL_DEVICE_TYPE_DISCRETE_GPU <<<"$vk"; then
        igpu=1
    fi
fi

FLAG="${QMD_DEGRADED_FLAG:-$HOME/.himmel/state/qmd-degraded.flag}"
write_flag=0
[ "${1:-}" = "--write-flag" ] && write_flag=1

if [ "$nvidia_ok" = 0 ] && [ "$igpu" = 1 ]; then
    msg="qmd-degraded: degraded — no NVIDIA GPU, Vulkan iGPU only; qmd rerank hangs on it (pass rerank:false, hybrid search only)"
    if [ "$write_flag" = 1 ]; then
        mkdir -p "$(dirname "$FLAG")" 2>/dev/null && printf '%s\n' "$msg" > "$FLAG" 2>/dev/null || true
    fi
    echo "$msg"
    exit 10
fi
[ "$write_flag" = 1 ] && rm -f "$FLAG" 2>/dev/null
echo "qmd-degraded: ok"
exit 0
