#!/usr/bin/env bash
set -euo pipefail

# Qwen-Image-Edit-2511 (Unsloth GGUF) - self-deploying ComfyUI start script
# Idempotent: installs ComfyUI + GGUF node and downloads models only if missing.
# Everything durable lives under /workspace/qwen-edit (Network Volume).

# GPU profiles (set QWEN_GPU_PROFILE):
# rtx-pro-4000 – RTX PRO 4000 Blackwell (24 GB GDDR7) → Q4_K_M, no --lowvram
# a40 – NVIDIA A40 Ampere (48 GB GDDR6) → Q5_K_M default, no --lowvram
# rtx-3090 – NVIDIA RTX 3090 (24 GB GDDR6X) → Q4_K_M, no --lowvram (original)
# custom – use env vars directly (QWEN_QUANT, QWEN_LOWVRAM, QWEN_RES)

# Reproducibility (optional, unset by default):
# COMFYUI_PINNED_COMMIT / GGUF_NODE_PINNED_COMMIT – pin ComfyUI and the
#   ComfyUI-GGUF node to a specific commit SHA instead of tracking upstream
#   HEAD on every boot. Leave unset to keep the original "always pull latest"
#   behavior. To adopt a pin: run once with these unset, note the commit
#   hashes this script prints under "Pinned commit reference" below, then
#   set both env vars on the pod to freeze future boots to that exact state.
# ALLOW_UPSTREAM_UPDATE=1 – if a pin is set, this forces a one-time pull to
#   upstream HEAD anyway (use to deliberately move to a newer commit, then
#   re-pin).

export DEBIAN_FRONTEND=noninteractive
export QWEN_ROOT=/workspace/qwen-edit
export HF_HOME="$QWEN_ROOT/.cache/huggingface"
export TORCH_HOME="$QWEN_ROOT/.cache/torch"

# ---------------------------------------------------------------------------
# GPU profile defaults
# ---------------------------------------------------------------------------
GPU_PROFILE="${QWEN_GPU_PROFILE:-rtx-pro-4000}"

case "$GPU_PROFILE" in
rtx-pro-4000)
# 24 GB GDDR7, Blackwell — same VRAM budget as RTX 3090
DEFAULT_QUANT="q4_k_m"
DEFAULT_LOWVRAM="0"
DEFAULT_RES="1024x1024"
;;
a40)
# 48 GB GDDR6, Ampere — comfortable headroom for Q5_K_M
DEFAULT_QUANT="q5_k_m"
DEFAULT_LOWVRAM="0"
DEFAULT_RES="1024x1024"
;;
rtx-3090)
# 24 GB GDDR6X, Ampere — original profile
DEFAULT_QUANT="q4_k_m"
DEFAULT_LOWVRAM="0"
DEFAULT_RES="1024x1024"
;;
custom)
# Any unlisted/unknown GPU. build_no_docker.sh's auto-detect falls back
# here with a conservative Q4_K_S + --lowvram combo when it cannot
# confirm the card has >= 20 GB of VRAM, to avoid OOM on smaller cards.
DEFAULT_QUANT="${QWEN_QUANT:-q4_k_s}"
DEFAULT_LOWVRAM="${QWEN_LOWVRAM:-1}"
DEFAULT_RES="${QWEN_RES:-1024x1024}"
;;
*)
echo "WARNING: Unknown QWEN_GPU_PROFILE='$GPU_PROFILE', falling back to rtx-pro-4000 defaults."
DEFAULT_QUANT="q4_k_m"
DEFAULT_LOWVRAM="0"
DEFAULT_RES="1024x1024"
;;
esac

export QWEN_QUANT="${QWEN_QUANT:-$DEFAULT_QUANT}"
export QWEN_LOWVRAM="${QWEN_LOWVRAM:-$DEFAULT_LOWVRAM}"
export QWEN_RES="${QWEN_RES:-$DEFAULT_RES}"

echo "=== Qwen-Image-Edit-2511 ComfyUI Bootstrap ==="
echo " GPU Profile : $GPU_PROFILE"
echo " Quantization: $QWEN_QUANT"
echo " LowVRAM mode: $QWEN_LOWVRAM"
echo " Target res  : $QWEN_RES"
echo "=============================================="

# ---------------------------------------------------------------------------
# Preserve base RunPod template services (SSH/Jupyter) if present
# ---------------------------------------------------------------------------
if [ -x /start.sh ] && [ "${RUNPOD_SKIP_BASE_START:-0}" != "1" ]; then
/start.sh >/tmp/runpod-base-start.log 2>&1 &
fi

# ---------------------------------------------------------------------------
# OS libraries are baked into the custom Docker image.
# Only run apt if forced (e.g. different base image).
# ---------------------------------------------------------------------------
if [ "${RUN_APT_ON_STARTUP:-0}" = "1" ]; then
apt-get update -y
apt-get install -y --no-install-recommends \
git curl python3 python3-venv libgl1 libglib2.0-0 ffmpeg ca-certificates
rm -rf /var/lib/apt/lists/*
fi

mkdir -p "$QWEN_ROOT"
cd "$QWEN_ROOT"

# ---------------------------------------------------------------------------
# ComfyUI + venv (reuse the image's CUDA-matched torch)
# ---------------------------------------------------------------------------
if [ ! -d .venv ]; then
python3 -m venv --system-site-packages .venv
fi

# ---------------------------------------------------------------------------
# Git sync helper: clones a repo if missing, then checks out an explicit pin
# when configured. Without a pin it tracks the named upstream branch. Set
# ALLOW_UPSTREAM_UPDATE=1 to deliberately update a pinned checkout for this
# boot; the configured pin remains unchanged for the next boot.
# ---------------------------------------------------------------------------
sync_git_repo() {
  local repo_url="$1"
  local repo_dir="$2"
  local pinned_commit="$3"
  local branch="$4"
  local label="$5"

  if [ ! -d "$repo_dir/.git" ]; then
    rm -rf "$repo_dir"
    mkdir -p "$(dirname "$repo_dir")"
    git clone --branch "$branch" "$repo_url" "$repo_dir"
  fi

  git -C "$repo_dir" fetch --tags --prune origin

  if [ -n "$pinned_commit" ] && [ "${ALLOW_UPSTREAM_UPDATE:-0}" != "1" ]; then
    if ! git -C "$repo_dir" cat-file -e "${pinned_commit}^{commit}" 2>/dev/null; then
      echo "ERROR: $label pin is unavailable or is not a commit: $pinned_commit"
      return 1
    fi
    git -C "$repo_dir" checkout --quiet --detach "$pinned_commit"
    echo " $label mode    : pinned"
  elif [ "${ALLOW_UPSTREAM_UPDATE:-0}" = "1" ]; then
    git -C "$repo_dir" checkout --quiet "$branch"
    git -C "$repo_dir" pull --ff-only origin "$branch"
    echo " $label mode    : updated to origin/$branch"
    if [ -n "$pinned_commit" ]; then
      echo " WARNING: The configured pin remains ${pinned_commit}."
      echo "          Replace it with the revision below to retain this update next boot."
    fi
  else
    git -C "$repo_dir" checkout --quiet "$branch"
    git -C "$repo_dir" pull --ff-only origin "$branch"
    echo " $label mode    : tracking origin/$branch"
  fi

  printf ' %s revision: %s
' "$label" "$(git -C "$repo_dir" rev-parse HEAD)"
}
sync_git_repo \
  "https://github.com/comfyanonymous/ComfyUI.git" \
  "ComfyUI" \
  "${COMFYUI_PINNED_COMMIT:-}" \
  "master" \
  "ComfyUI"

source .venv/bin/activate

# Install/reinstall ComfyUI deps if the commit changed since last install
CURRENT_COMFYUI_COMMIT="$(cd ComfyUI && git rev-parse HEAD)"
if [ ! -f "$QWEN_ROOT/.deps_comfyui" ] || \
[ "$(cat "$QWEN_ROOT/.deps_comfyui" 2>/dev/null)" != "$CURRENT_COMFYUI_COMMIT" ]; then
pip install --upgrade pip
pip install -r ComfyUI/requirements.txt
echo "$CURRENT_COMFYUI_COMMIT" > "$QWEN_ROOT/.deps_comfyui"
fi

# ---------------------------------------------------------------------------
# ComfyUI-GGUF custom node
# ---------------------------------------------------------------------------
sync_git_repo \
  "https://github.com/city96/ComfyUI-GGUF.git" \
  "ComfyUI/custom_nodes/ComfyUI-GGUF" \
  "${GGUF_NODE_PINNED_COMMIT:-}" \
  "main" \
  "ComfyUI-GGUF"

CURRENT_GGUF_COMMIT="$(cd ComfyUI/custom_nodes/ComfyUI-GGUF && git rev-parse HEAD)"
if [ ! -f "$QWEN_ROOT/.deps_gguf" ] || \
[ "$(cat "$QWEN_ROOT/.deps_gguf" 2>/dev/null)" != "$CURRENT_GGUF_COMMIT" ]; then
pip install -r ComfyUI/custom_nodes/ComfyUI-GGUF/requirements.txt
echo "$CURRENT_GGUF_COMMIT" > "$QWEN_ROOT/.deps_gguf"
fi

echo "--- Pinned commit reference (copy into COMFYUI_PINNED_COMMIT / GGUF_NODE_PINNED_COMMIT to freeze this state) ---"
echo " ComfyUI       : $CURRENT_COMFYUI_COMMIT"
echo " ComfyUI-GGUF  : $CURRENT_GGUF_COMMIT"

# ---------------------------------------------------------------------------
# Verify torch sees CUDA
# ---------------------------------------------------------------------------
python - <<'PY'
import torch
print("torch:", torch.__version__, "cuda:", torch.version.cuda,
"cuda_available:", torch.cuda.is_available())
if not torch.cuda.is_available():
raise SystemExit("CUDA is not available in torch. Use the official "
"RunPod PyTorch template or fix the torch install.")
print("gpu:", torch.cuda.get_device_name(0))
PY

# ---------------------------------------------------------------------------
# Model folders + unet symlink (legacy GGUF loaders look under models/unet)
# ---------------------------------------------------------------------------
mkdir -p ComfyUI/models/diffusion_models ComfyUI/models/text_encoders ComfyUI/models/vae
cd ComfyUI/models
[ -e unet ] || ln -s diffusion_models unet
cd "$QWEN_ROOT"

# ---------------------------------------------------------------------------
# Fast HF downloads: huggingface_hub's CLI gives concurrent chunked transfer
# (via hf_transfer) and integrity-checked downloads, vs. single-stream curl.

# IMPORTANT: as of huggingface_hub 0.23.0+, "--local-dir" downloads go
# straight to the target folder with NO cache duplication and NO symlinks
# (deliberate redesign — see huggingface_hub v0.23.0 release notes).
# "--local-dir-use-symlinks" is deprecated/ignored on modern CLI versions,
# so it is intentionally NOT passed here. We always pin a floor version
# below, since skipping the upgrade whenever *some* version is already
# importable could otherwise leave a pre-0.23 install in place that still
# exhibits the old cache+local_dir duplication behavior.
# ---------------------------------------------------------------------------
echo "Ensuring huggingface_hub[cli] >= 0.23 (+ hf_transfer) for accelerated, non-duplicating downloads..."
pip install -q -U "huggingface_hub[cli]>=0.23.0,<1.0.0" hf_transfer
export HF_HUB_ENABLE_HF_TRANSFER=1
HF_DL_TMP="$QWEN_ROOT/.hf_dl_tmp"
mkdir -p "$HF_DL_TMP"

# Prefer the modern "hf" CLI entry point; fall back to the legacy
# "huggingface-cli" alias if present; fall back to curl if neither exists.
HF_DL_CMD=""
if command -v hf >/dev/null 2>&1; then
HF_DL_CMD="hf"
elif command -v huggingface-cli >/dev/null 2>&1; then
HF_DL_CMD="huggingface-cli"
fi

# SECURITY: HF_TOKEN is intentionally NOT passed as a "--token" CLI argument
# below. Command-line arguments are visible to any process that can read
# /proc/<pid>/cmdline or run `ps -ef` on the box, for the lifetime of the
# process. huggingface_hub's CLI and library both natively auto-detect and
# use the HF_TOKEN environment variable when no --token flag is given, so
# exporting it for the duration of the download phase is sufficient.
if [ -n "${HF_TOKEN:-}" ]; then
export HF_TOKEN
fi

safe_download() {
local url="$1"
local dest="$2"
local tmp="${dest}.part"

if [ -f "$dest" ]; then
echo " [skip] $dest already exists"
return 0
fi
rm -f "$tmp"
mkdir -p "$(dirname "$dest")"

# Parse "https://huggingface.co/<repo_id>/resolve/main/<filename>"
local hf_path="${url#https://huggingface.co/}"
local repo_id="${hf_path%%/resolve/*}"
local hf_filename="${hf_path#*/resolve/main/}"

# No --token here: HF_TOKEN (if set) is picked up automatically from the
# environment by the hf/huggingface-cli download command.
local hf_opts=(--local-dir "$HF_DL_TMP")

echo " [download] $repo_id :: $hf_filename -> $dest"
rm -rf "${HF_DL_TMP:?}/${hf_filename}"

if [ -n "$HF_DL_CMD" ] && "$HF_DL_CMD" download "$repo_id" "$hf_filename" "${hf_opts[@]}"; then
mv "$HF_DL_TMP/$hf_filename" "$tmp"
mv "$tmp" "$dest"
else
echo " [warn] HF CLI download unavailable or failed for $hf_filename, falling back to curl"
# SECURITY: the Authorization header is passed via a curl config file on
# stdin ("-K -") instead of "-H ..." on the command line, so the bearer
# token never appears in argv/ps/proc-cmdline. "printf" is a bash builtin
# (no subprocess spawned), so the secret is never handled by anything
# other than curl itself, reading its own stdin.

printf 'url = "%s"\n' "$url"
printf 'output = "%s"\n' "$tmp"
printf 'fail\nlocation\nretry = 5\nretry-delay = 10\ncontinue-at = -\n'
if [ -n "${HF_TOKEN:-}" ]; then
printf 'header = "Authorization: Bearer %s"\n' "$HF_TOKEN"
fi
} | curl -K -
mv "$tmp" "$dest"
fi

# ---------------------------------------------------------------------------
# Download models only if missing (safe download prevents corrupt partials)
# ---------------------------------------------------------------------------
echo "--- Downloading models (quant: $QWEN_QUANT) ---"

# Always download Q4_K_M as the baseline diffusion model (~13.2 GB)
safe_download \
"https://huggingface.co/unsloth/Qwen-Image-Edit-2511-GGUF/resolve/main/qwen-image-edit-2511-Q4_K_M.gguf" \
"ComfyUI/models/diffusion_models/qwen-image-edit-2511-Q4_K_M.gguf"

# Download Q5_K_M if requested (~15 GB) — default for A40, optional for 24 GB cards
if [ "$QWEN_QUANT" = "q5_k_m" ]; then
safe_download \
"https://huggingface.co/unsloth/Qwen-Image-Edit-2511-GGUF/resolve/main/qwen-image-edit-2511-Q5_K_M.gguf" \
"ComfyUI/models/diffusion_models/qwen-image-edit-2511-Q5_K_M.gguf"
fi

# Download Q6_K if requested (~16.9 GB) — only viable on 48 GB cards (A40)
if [ "$QWEN_QUANT" = "q6_k" ]; then
safe_download \
"https://huggingface.co/unsloth/Qwen-Image-Edit-2511-GGUF/resolve/main/qwen-image-edit-2511-Q6_K.gguf" \
"ComfyUI/models/diffusion_models/qwen-image-edit-2511-Q6_K.gguf"
fi

# Download Q4_K_S if requested (~12.4 GB) — OOM fallback for 24 GB cards
if [ "$QWEN_QUANT" = "q4_k_s" ]; then
safe_download \
"https://huggingface.co/unsloth/Qwen-Image-Edit-2511-GGUF/resolve/main/qwen-image-edit-2511-Q4_K_S.gguf" \
"ComfyUI/models/diffusion_models/qwen-image-edit-2511-Q4_K_S.gguf"
fi

# Text encoder (~4.8 GB)
safe_download \
"https://huggingface.co/unsloth/Qwen2.5-VL-7B-Instruct-GGUF/resolve/main/Qwen2.5-VL-7B-Instruct-UD-Q4_K_XL.gguf" \
"ComfyUI/models/text_encoders/Qwen2.5-VL-7B-Instruct-UD-Q4_K_XL.gguf"

# mmproj (~1.4 GB) – renamed so the GGUF CLIP loader auto-detects it
safe_download \
"https://huggingface.co/unsloth/Qwen2.5-VL-7B-Instruct-GGUF/resolve/main/mmproj-BF16.gguf" \
"ComfyUI/models/text_encoders/Qwen2.5-VL-7B-Instruct-UD-Q4_K_XL-mmproj.gguf"

# VAE (~0.3 GB)
safe_download \
"https://huggingface.co/Comfy-Org/Qwen-Image_ComfyUI/resolve/main/split_files/vae/qwen_image_vae.safetensors" \
"ComfyUI/models/vae/qwen_image_vae.safetensors"

rm -rf "$HF_DL_TMP"

# ---------------------------------------------------------------------------
# SECURITY: drop HF_TOKEN from the environment before launching ComfyUI.
# All model downloads are complete at this point. ComfyUI executes
# arbitrary third-party custom-node Python code; leaving a credential
# exported into that process (and everything it forks) is unnecessary
# exposure under the principle of least privilege. If you specifically
# need ComfyUI itself to have HF_TOKEN (e.g. a custom node that fetches
# gated models at runtime), re-export it yourself after this script starts,
# or remove this "unset" line for your own deployment.
# ---------------------------------------------------------------------------
unset HF_TOKEN
unset HUGGINGFACE_HUB_TOKEN
unset HUGGING_FACE_HUB_TOKEN

# ---------------------------------------------------------------------------
# Launch ComfyUI
# ---------------------------------------------------------------------------
cd "$QWEN_ROOT/ComfyUI"

LAUNCH_ARGS=(--listen 0.0.0.0 --port 8188)

if [ "$QWEN_LOWVRAM" = "1" ]; then
LAUNCH_ARGS+=(--lowvram)
echo " Launching with --lowvram (reduced VRAM mode)"
fi

echo " Launch command: python main.py ${LAUNCH_ARGS[*]}"
exec python main.py "${LAUNCH_ARGS[@]}"
