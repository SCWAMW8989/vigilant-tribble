# syntax=docker/dockerfile:1
# Qwen-Image-Edit-2511 GGUF / ComfyUI bootstrap image
# Compatible with start_comfyui.sh-GPU-aware-v3.7.sh.
#
# Build example:
#   docker build -f Dockerfile.qwen-image-edit-runpod-v3.7.Dockerfile \
#     -t your-registry/qwen-image-edit:runpod-v3.7 .
#
# RunPod configuration:
#   - Attach the persistent Network Volume at /workspace.
#   - Expose HTTP port 8188.
#   - Optional environment variables are documented in the v3.7 guide.
#   - The start script clones, pins/updates, installs, and downloads models
#     into /workspace/qwen-edit on first boot.

FROM runpod/pytorch:1.0.2-cu1281-torch280-ubuntu2404

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

ENV DEBIAN_FRONTEND=noninteractive \
    QWEN_ROOT=/workspace/qwen-edit \
    HF_HOME=/workspace/qwen-edit/.cache/huggingface \
    TORCH_HOME=/workspace/qwen-edit/.cache/torch \
    PIP_NO_CACHE_DIR=1 \
    PYTHONUNBUFFERED=1

# These packages support the v3.7 script even if the RunPod base image changes.
RUN apt-get update -y \
    && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        ffmpeg \
        git \
        libgl1 \
        libglib2.0-0 \
        python3 \
        python3-venv \
    && rm -rf /var/lib/apt/lists/*

# Copy the matching v3.7 startup script from the Docker build context.
# It is intentionally copied outside /workspace because that mount is replaced
# by the attached RunPod Network Volume at runtime.
COPY --chmod=0755 start_comfyui.sh-GPU-aware-v3.7.sh /opt/start_comfyui.sh

# ComfyUI is served through RunPod's HTTP proxy on this port.
EXPOSE 8188

# Choose this at deployment time if needed:
#   QWEN_GPU_PROFILE=rtx-pro-4000 | a40 | rtx-3090 | custom
# The 24 GB RTX PRO 4000 profile is a conservative default.
ENV QWEN_GPU_PROFILE=rtx-pro-4000 \
    QWEN_LOWVRAM=0

# Do not bake HF_TOKEN, model files, a commit pin, or the Network Volume's
# content into the image. Provide those as RunPod environment variables or
# persistent-volume state at runtime.
CMD ["/bin/bash", "/opt/start_comfyui.sh"]
