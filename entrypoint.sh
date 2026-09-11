#!/usr/bin/env bash
# entrypoint.sh — nvidia-smi based GPU auto-detect wrapper for the
# Qwen-Image-Edit RunPod image (v3.9).
#
# Runs before start_comfyui.sh-GPU-aware-v3.7.sh. Auto-detection only kicks
# in when QWEN_GPU_PROFILE is unset or explicitly set to "auto" (the new
# image default). Any other explicit value (rtx-pro-4000, a40, rtx-3090,
# custom) passes through untouched, so manual overrides at the RunPod
# template/pod level always win over detection.
set -euo pipefail

detect_gpu_profile() {
  if ! command -v nvidia-smi >/dev/null 2>&1; then
    echo "WARNING: nvidia-smi not found; cannot auto-detect GPU. Falling back to custom safe profile." >&2
    echo "custom"
    return
  fi

  local gpu_line
  gpu_line="$(nvidia-smi --query-gpu=name,memory.total --format=csv,noheader,nounits 2>/dev/null | head -n1 || true)"

  if [ -z "$gpu_line" ]; then
    echo "WARNING: nvidia-smi returned no data; falling back to custom safe profile." >&2
    echo "custom"
    return
  fi

  local gpu_name vram_mib
  gpu_name="$(echo "$gpu_line" | awk -F',' '{print $1}' | sed 's/^ *//;s/ *$//')"
  vram_mib="$(echo "$gpu_line" | awk -F',' '{print $2}' | sed 's/^ *//;s/ *$//')"

  echo "Detected GPU: $gpu_name (${vram_mib} MiB)" >&2

  case "$gpu_name" in
    *"RTX PRO 4000"*|*"RTX PRO4000"*)
      echo "rtx-pro-4000"
      return
      ;;
    *"A40"*)
      echo "a40"
      return
      ;;
    *"3090"*)
      echo "rtx-3090"
      return
      ;;
  esac

  if ! [[ "$vram_mib" =~ ^[0-9]+$ ]]; then
    echo "WARNING: Could not parse VRAM size from nvidia-smi output; falling back to custom safe profile." >&2
    echo "custom"
    return
  fi

  if [ "$vram_mib" -ge 40960 ]; then
    echo "a40"
  elif [ "$vram_mib" -ge 20480 ]; then
    echo "rtx-pro-4000"
  else
    echo "custom"
  fi
}

if [ -z "${QWEN_GPU_PROFILE:-}" ] || [ "${QWEN_GPU_PROFILE}" = "auto" ]; then
  RESOLVED_PROFILE="$(detect_gpu_profile)"
  export QWEN_GPU_PROFILE="$RESOLVED_PROFILE"
  echo "Auto-detected QWEN_GPU_PROFILE=$QWEN_GPU_PROFILE" >&2

  if [ "$QWEN_GPU_PROFILE" = "custom" ]; then
    export QWEN_QUANT="${QWEN_QUANT:-q4_k_s}"
    export QWEN_LOWVRAM="${QWEN_LOWVRAM:-1}"
    echo "Custom fallback quant/lowvram: QWEN_QUANT=$QWEN_QUANT QWEN_LOWVRAM=$QWEN_LOWVRAM" >&2
  fi
else
  echo "QWEN_GPU_PROFILE explicitly set to '${QWEN_GPU_PROFILE}'; skipping auto-detect." >&2
fi

exec /bin/bash /opt/start_comfyui.sh
