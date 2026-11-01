#!/bin/bash
# ApexForge by Alex Harte (https://alexanderharte.com)
# Do NOT use set -e — git pull failures should not kill the whole script

# --- Configuration ---
APEXFORGE_VERSION="1.1.0"
COMFYUI_DIR="/comfyui/ComfyUI"
ARGS_FILE="/comfyui/comfyui_args.txt"
CHECKPOINTS_DIR="$COMFYUI_DIR/models/checkpoints"
DIFFUSION_MODELS_DIR="$COMFYUI_DIR/models/diffusion_models"
TEXT_ENCODERS_DIR="$COMFYUI_DIR/models/text_encoders"
VAE_DIR="$COMFYUI_DIR/models/vae"

# Optional: Civitai API key for the Skin Texture LoRA download.
# In the RunPod template, set CIVITAI_TOKEN={{ RUNPOD_SECRET_civitai }} so the
# key lives in RunPod Secrets instead of plain text. Sent as a header, never in the URL.
CIVITAI_TOKEN="${CIVITAI_TOKEN:-}"

# Optional: set APEXFORGE_UNCENSORED_ENCODERS=true to also download the
# community "abliterated"/"heretic" Qwen3-4B text encoders. Off by default;
# the bundled workflows use the official Qwen3-4B encoders.
APEXFORGE_UNCENSORED_ENCODERS="${APEXFORGE_UNCENSORED_ENCODERS:-false}"

# --- Pinned versions ---
# ComfyUI, custom nodes and SageAttention are pinned to versions tested with
# this release. Set APEXFORGE_TRACK_LATEST=true to pull the newest code instead
# (untested — things may break).
APEXFORGE_TRACK_LATEST="${APEXFORGE_TRACK_LATEST:-false}"
# Python packages live on the container disk, which is wiped when the pod
# stops, so the "dependencies installed" markers must live there too (not on
# the network volume).
DEPS_MARKERS="/root/.apexforge_deps"
mkdir -p "$DEPS_MARKERS"
COMFYUI_REF="v0.43.0"
SAGEATTENTION_REF="v2.2.0"
# dir|repo|commit
CUSTOM_NODES=(
    "ComfyUI-KJNodes|https://github.com/kijai/ComfyUI-KJNodes.git|ab72eda7ffad6280422d71ab7d54d3fb87c0ba18"
    "Civicomfy|https://github.com/MoonGoblinDev/Civicomfy.git|555e984bbcb02fc955075cb8eb699a6884c51239"
    "ComfyUI-MMAudio|https://github.com/kijai/ComfyUI-MMAudio.git|8eaeb72edc3aaf2059b57f2d96a1f6f689f19ae2"
    "ComfyUI-Frame-Interpolation|https://github.com/Fannovel16/ComfyUI-Frame-Interpolation.git|26545cc2dd95bc3d27f056016300673bdeee78f5"
    "ComfyUI-Chatterbox|https://github.com/wildminder/ComfyUI-Chatterbox.git|7175b1e42d652e12482da57c1b44f74194649c4a"
    "ComfyUI-GGUF|https://github.com/city96/ComfyUI-GGUF.git|6ea2651e7df66d7585f6ffee804b20e92fb38b8a"
    "rgthree-comfy|https://github.com/rgthree/rgthree-comfy.git|bc48c6aaeca87bedbc14245d89f9bc6be37a630e"
    "ComfyUI-VideoHelperSuite|https://github.com/Kosinkadink/ComfyUI-VideoHelperSuite.git|4d907bee61e92c2e65af3bd6383a4e4d356126d1"
    "comfyui_controlnet_aux|https://github.com/Fannovel16/comfyui_controlnet_aux.git|a587a4c1594524c1d2de5cd1a86cd868ff448e1c"
    "facerestore_cf|https://github.com/mav-rik/facerestore_cf.git|ff4d7a5c102441d8f058dd6135797ffb57b6c6ad"
    "ComfyUI-WanVideoWrapper|https://github.com/kijai/ComfyUI-WanVideoWrapper.git|088128b224242e110d3906c6750e9a3a348a659b"
    "ACE-Step-ComfyUI|https://github.com/ace-step/ACE-Step-ComfyUI.git|5de16c9bc43abdbe9a3104d220bba9f71b51165a"
    "ComfyUI-TiledDiffusion|https://github.com/shiimizu/ComfyUI-TiledDiffusion.git|a155b1bac39147381aeaa52b9be42e545626a44f"
)

# Clone a repo if missing, then move it to the pinned ref (or latest when
# APEXFORGE_TRACK_LATEST=true).
sync_repo() {
    local dir="$1" url="$2" ref="$3"
    if [ ! -d "$dir/.git" ]; then
        git clone "$url" "$dir" || { echo "WARNING: Could not clone $url"; return 1; }
    fi
    if [ "$APEXFORGE_TRACK_LATEST" = "true" ]; then
        local branch
        branch=$(git -C "$dir" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null)
        git -C "$dir" checkout -q "${branch#origin/}" 2>/dev/null || git -C "$dir" checkout -q main 2>/dev/null
        git -C "$dir" pull -q || echo "WARNING: Could not update $dir."
    elif [ "$(git -C "$dir" rev-parse HEAD 2>/dev/null)" != "$(git -C "$dir" rev-parse "$ref^{commit}" 2>/dev/null)" ]; then
        git -C "$dir" fetch -q --tags origin || echo "WARNING: Could not fetch $dir."
        git -C "$dir" checkout -q "$ref" || echo "WARNING: Could not check out $ref in $dir."
    fi
}

# --- Use system Python (has PyTorch 2.10.0 stable baked into image) ---
# SageAttention is installed at runtime on first boot (requires live GPU)

# --- Function Definitions ---

# Function to start JupyterLab in the background
# Same pattern as RunPod's official images (github.com/runpod/containers):
# JupyterLab only starts with a password (JUPYTER_PASSWORD, which RunPod sets
# when "Start Jupyter Notebook" is ticked) or an explicit JUPYTER_DISABLE_AUTH=true.
start_jupyter() {
    if [ "$JUPYTER_DISABLE_AUTH" = "true" ]; then
        echo "WARNING: JUPYTER_DISABLE_AUTH=true — JupyterLab has NO password."
        echo "WARNING: Anyone with this pod's port 8888 URL gets a root shell."
        JUPYTER_TOKEN=""
    elif [ -n "$JUPYTER_PASSWORD" ]; then
        JUPYTER_TOKEN="$JUPYTER_PASSWORD"
    else
        echo "JupyterLab not started: set JUPYTER_PASSWORD to enable it."
        return
    fi

    echo "=========================================="
    echo "Starting JupyterLab on port 8888"
    echo "=========================================="
    mkdir -p /comfyui
    nohup jupyter lab \
        --ip=0.0.0.0 \
        --port=8888 \
        --no-browser \
        --allow-root \
        --IdentityProvider.token="$JUPYTER_TOKEN" \
        --ServerApp.root_dir=/comfyui \
        > /comfyui/jupyter.log 2>&1 &
    echo "JupyterLab started on port 8888"
}

# Function to install or update ComfyUI (pinned to COMFYUI_REF)
setup_comfyui() {
    mkdir -p /comfyui
    if [ ! -d "$COMFYUI_DIR" ]; then
        echo "ComfyUI not found. Cloning repository ($COMFYUI_REF)..."
    else
        echo "ComfyUI found. Checking version ($COMFYUI_REF)..."
    fi
    sync_repo "$COMFYUI_DIR" https://github.com/Comfy-Org/ComfyUI.git "$COMFYUI_REF"
    cd "$COMFYUI_DIR" || return
    # Install dependencies once per container, and again if the ComfyUI version changes
    if [ "$(cat "$DEPS_MARKERS/ComfyUI" 2>/dev/null)" != "$(git rev-parse HEAD)" ]; then
        echo "Installing ComfyUI + ComfyUI-Manager dependencies..."
        pip install --no-cache-dir -r requirements.txt -r manager_requirements.txt \
            && git rev-parse HEAD > "$DEPS_MARKERS/ComfyUI" \
            || echo "WARNING: Could not install core dependencies."
    fi
    cd "$COMFYUI_DIR"
    echo "ComfyUI version: $(git describe --tags 2>/dev/null || git rev-parse --short HEAD)"
}

# Keep ComfyUI-Manager on its safe default security level. Manager v4 stores
# its config in ComfyUI's protected user/__manager folder.
configure_manager() {
    local cfg="$COMFYUI_DIR/user/__manager/config.ini"
    mkdir -p "$(dirname "$cfg")"
    if [ ! -f "$cfg" ]; then
        printf '[default]\nsecurity_level = normal\n' > "$cfg"
    elif grep -qE '^security_level *= *(weak|normal-)' "$cfg"; then
        echo "Raising ComfyUI-Manager security_level to normal."
        sed -i -E 's/^security_level *=.*/security_level = normal/' "$cfg"
    fi
}

# Download to <file>.part and rename only on success. A plain wget -O leaves
# a broken file behind when a download fails (e.g. a 29-byte error page),
# and the "[ ! -f ]" checks would then skip it on every later boot.
# Usage: download -O <file> <url>
download() {
    local out="" url="" arg
    while [ $# -gt 0 ]; do
        arg="$1"; shift
        if [ "$arg" = "-O" ]; then out="$1"; shift; else url="$arg"; fi
    done
    if wget --progress=bar:force:noscroll -O "$out.part" "$url"; then
        mv "$out.part" "$out"
    else
        rm -f "$out.part"
        echo "WARNING: download failed, will retry next boot: $url"
    fi
}

# Remove model files left broken by failed downloads in earlier versions.
# Real models are far larger than 64 KB; embeddings are skipped (they can be tiny).
remove_broken_downloads() {
    find "$COMFYUI_DIR/models" -path "$COMFYUI_DIR/models/embeddings" -prune -o -type f \
        \( -name "*.safetensors" -o -name "*.gguf" -o -name "*.pth" -o -name "*.ckpt" -o -name "*.pt" -o -name "*.bin" \) \
        -size -64k -print 2>/dev/null | while read -r f; do
        echo "Removing broken download: $f"
        rm -f "$f"
    done
}

# Function to download Juggernaut Reborn model (SD 1.5)
download_model() {
    echo "=========================================="
    echo "Checking for Juggernaut Reborn model..."
    echo "=========================================="

    # Reborn is SD 1.5 — lives in checkpoints/sd15/
    mkdir -p "$CHECKPOINTS_DIR/sd15"

    MODEL_PATH="$CHECKPOINTS_DIR/sd15/juggernaut_reborn.safetensors"
    if [ ! -f "$MODEL_PATH" ]; then
        echo "Downloading Juggernaut Reborn model (~2 GB) from HuggingFace..."
        download -O "$MODEL_PATH" \
            "https://huggingface.co/HyperX-Sentience/Juggernaut-Reborn/resolve/main/juggernaut_reborn.safetensors?download=true"

        if [ -f "$MODEL_PATH" ]; then
            FILE_SIZE=$(stat -c%s "$MODEL_PATH" 2>/dev/null || echo 0)
            if [ "$FILE_SIZE" -lt 1000000 ]; then
                echo "ERROR: Juggernaut Reborn download too small — removing..."
                rm -f "$MODEL_PATH"
            else
                echo "Download complete! File size: $FILE_SIZE bytes"
            fi
        else
            echo "ERROR: Download failed."
        fi
    else
        echo "Juggernaut Reborn model already exists."
    fi
}

# Function to download all InfiniteTalk + MultiTalk models
download_talking_models() {
    echo "=========================================="
    echo "Checking for InfiniteTalk / MultiTalk models..."
    echo "=========================================="

    # --- Directories ---
    mkdir -p "$DIFFUSION_MODELS_DIR/InfiniteTalk"
    mkdir -p "$COMFYUI_DIR/models/loras/Lightx2v"
    mkdir -p "$COMFYUI_DIR/models/text_encoders"
    mkdir -p "$COMFYUI_DIR/models/vae"
    mkdir -p "$COMFYUI_DIR/models/clip_vision"
    mkdir -p "$COMFYUI_DIR/models/audio_encoders/chinese-wav2vec2-base"

    # --- Wan2.1 I2V 14B 480p base model (32.8 GB) ---
    WAN_I2V="$DIFFUSION_MODELS_DIR/wan2.1_i2v_480p_14B_fp16.safetensors"
    if [ ! -f "$WAN_I2V" ]; then
        echo "Downloading Wan2.1 I2V 14B 480p (32.8 GB)..."
        download -O "$WAN_I2V" \
            "https://huggingface.co/Comfy-Org/Wan_2.1_ComfyUI_repackaged/resolve/main/split_files/diffusion_models/wan2.1_i2v_480p_14B_fp16.safetensors?download=true"
    else
        echo "Wan2.1 I2V 14B 480p already exists."
    fi

    # --- InfiniteTalk Single (from MeiGen-AI official HuggingFace) ---
    INFINITETALK_SINGLE="$DIFFUSION_MODELS_DIR/InfiniteTalk/infinitetalk_single.safetensors"
    if [ ! -f "$INFINITETALK_SINGLE" ]; then
        echo "Downloading InfiniteTalk Single..."
        download -O "$INFINITETALK_SINGLE" \
            "https://huggingface.co/MeiGen-AI/InfiniteTalk/resolve/main/comfyui/infinitetalk_single.safetensors?download=true"
    else
        echo "InfiniteTalk Single already exists."
    fi

    # --- InfiniteTalk Multi (from MeiGen-AI official HuggingFace) ---
    INFINITETALK_MULTI="$DIFFUSION_MODELS_DIR/InfiniteTalk/infinitetalk_multi.safetensors"
    if [ ! -f "$INFINITETALK_MULTI" ]; then
        echo "Downloading InfiniteTalk Multi..."
        download -O "$INFINITETALK_MULTI" \
            "https://huggingface.co/MeiGen-AI/InfiniteTalk/resolve/main/comfyui/infinitetalk_multi.safetensors?download=true"
    else
        echo "InfiniteTalk Multi already exists."
    fi

    # --- MultiTalk model (9.95 GB, from MeiGen-AI official HuggingFace) ---
    MULTITALK="$DIFFUSION_MODELS_DIR/multitalk.safetensors"
    if [ ! -f "$MULTITALK" ]; then
        echo "Downloading MultiTalk model (9.95 GB)..."
        download -O "$MULTITALK" \
            "https://huggingface.co/MeiGen-AI/MeiGen-MultiTalk/resolve/main/multitalk.safetensors?download=true"
    else
        echo "MultiTalk model already exists."
    fi

    # --- LightX2V I2V LoRA rank64 (738 MB) - speed acceleration LoRA ---
    LIGHTX2V="$COMFYUI_DIR/models/loras/Lightx2v/lightx2v_I2V_14B_480p_cfg_step_distill_rank64_bf16.safetensors"
    if [ ! -f "$LIGHTX2V" ]; then
        echo "Downloading LightX2V I2V LoRA rank64 (738 MB)..."
        download -O "$LIGHTX2V" \
            "https://huggingface.co/Kijai/WanVideo_comfy/resolve/main/Lightx2v/lightx2v_I2V_14B_480p_cfg_step_distill_rank64_bf16.safetensors?download=true"
    else
        echo "LightX2V LoRA already exists."
    fi

    # --- UMT5 XXL text encoder fp8 (from Comfy-Org official) ---
    UMT5="$COMFYUI_DIR/models/text_encoders/umt5_xxl_fp8_e4m3fn_scaled.safetensors"
    if [ ! -f "$UMT5" ]; then
        echo "Downloading UMT5 XXL text encoder..."
        download -O "$UMT5" \
            "https://huggingface.co/Comfy-Org/Wan_2.1_ComfyUI_repackaged/resolve/main/split_files/text_encoders/umt5_xxl_fp8_e4m3fn_scaled.safetensors?download=true"
    else
        echo "UMT5 text encoder already exists."
    fi

    # --- Wan 2.1 VAE (from Comfy-Org official) ---
    WAN_VAE="$COMFYUI_DIR/models/vae/wan_2.1_vae.safetensors"
    if [ ! -f "$WAN_VAE" ]; then
        echo "Downloading Wan 2.1 VAE..."
        download -O "$WAN_VAE" \
            "https://huggingface.co/Comfy-Org/Wan_2.1_ComfyUI_repackaged/resolve/main/split_files/vae/wan_2.1_vae.safetensors?download=true"
    else
        echo "Wan 2.1 VAE already exists."
    fi

    # --- CLIP Vision H (from Comfy-Org official) ---
    CLIP_VISION="$COMFYUI_DIR/models/clip_vision/clip_vision_h.safetensors"
    if [ ! -f "$CLIP_VISION" ]; then
        echo "Downloading CLIP Vision H..."
        download -O "$CLIP_VISION" \
            "https://huggingface.co/Comfy-Org/Wan_2.1_ComfyUI_repackaged/resolve/main/split_files/clip_vision/clip_vision_h.safetensors?download=true"
    else
        echo "CLIP Vision H already exists."
    fi

    # --- Chinese wav2vec2-base audio encoder (required for MultiTalk/InfiniteTalk) ---
    WAV2VEC_CONFIG="$COMFYUI_DIR/models/audio_encoders/chinese-wav2vec2-base/config.json"
    if [ ! -f "$WAV2VEC_CONFIG" ]; then
        echo "Downloading chinese-wav2vec2-base audio encoder..."
        # huggingface_hub is pre-installed as a dependency of other packages
        python -c "
from huggingface_hub import snapshot_download
snapshot_download(
    repo_id='TencentGameMate/chinese-wav2vec2-base',
    local_dir='$COMFYUI_DIR/models/audio_encoders/chinese-wav2vec2-base'
)
print('chinese-wav2vec2-base downloaded.')
"
    else
        echo "chinese-wav2vec2-base already exists."
    fi

    echo "=========================================="
    echo "InfiniteTalk / MultiTalk models complete!"
    echo "=========================================="
}

# Function to download Flux Dev, Flux Kontext + shared encoders, upscalers, face restore
download_utility_models() {
    echo "=========================================="
    echo "Checking for Flux, upscaler, and face restore models..."
    echo "=========================================="

    mkdir -p "$DIFFUSION_MODELS_DIR"
    mkdir -p "$COMFYUI_DIR/models/text_encoders"
    mkdir -p "$COMFYUI_DIR/models/vae"
    mkdir -p "$COMFYUI_DIR/models/upscale_models"
    mkdir -p "$COMFYUI_DIR/models/facerestore_models"

    # -------------------------------------------------------
    # FLUX SHARED TEXT ENCODERS (used by Flux Dev + Kontext)
    # -------------------------------------------------------

    # clip_l (235MB) - shared by all Flux models
    CLIP_L="$COMFYUI_DIR/models/text_encoders/clip_l.safetensors"
    if [ ! -f "$CLIP_L" ]; then
        echo "Downloading FLUX clip_l text encoder..."
        download -O "$CLIP_L" \
            "https://huggingface.co/comfyanonymous/flux_text_encoders/resolve/main/clip_l.safetensors?download=true"
    else
        echo "clip_l already exists."
    fi

    # t5xxl fp8 scaled (~4.6GB) - shared by all Flux models
    T5XXL="$COMFYUI_DIR/models/text_encoders/t5xxl_fp8_e4m3fn_scaled.safetensors"
    if [ ! -f "$T5XXL" ]; then
        echo "Downloading FLUX t5xxl fp8 text encoder (~4.6 GB)..."
        download -O "$T5XXL" \
            "https://huggingface.co/comfyanonymous/flux_text_encoders/resolve/main/t5xxl_fp8_e4m3fn_scaled.safetensors?download=true"
    else
        echo "t5xxl fp8 already exists."
    fi

    # -------------------------------------------------------
    # FLUX.1 DEV fp8 (~12GB) - best open-source T2I, massive LoRA ecosystem
    # -------------------------------------------------------
    FLUX_DEV="$DIFFUSION_MODELS_DIR/flux1-dev-fp8.safetensors"
    if [ ! -f "$FLUX_DEV" ]; then
        echo "Downloading FLUX.1 Dev fp8 (~12 GB)..."
        download -O "$FLUX_DEV" \
            "https://huggingface.co/Comfy-Org/flux1-dev/resolve/main/flux1-dev-fp8.safetensors?download=true"
    else
        echo "FLUX.1 Dev already exists."
    fi

    # -------------------------------------------------------
    # FLUX.1 KONTEXT DEV fp8 (~12GB) - best open-source image editing
    # Edit images with text: change hair, swap backgrounds, etc.
    # -------------------------------------------------------
    FLUX_KONTEXT="$DIFFUSION_MODELS_DIR/flux1-dev-kontext_fp8_scaled.safetensors"
    if [ ! -f "$FLUX_KONTEXT" ]; then
        echo "Downloading FLUX.1 Kontext Dev fp8 (~12 GB)..."
        download -O "$FLUX_KONTEXT" \
            "https://huggingface.co/Comfy-Org/flux1-kontext-dev_ComfyUI/resolve/main/split_files/diffusion_models/flux1-dev-kontext_fp8_scaled.safetensors?download=true"
    else
        echo "FLUX.1 Kontext Dev already exists."
    fi

    # -------------------------------------------------------
    # UPSCALERS - go in models/upscale_models/
    # -------------------------------------------------------

    # 4x-UltraSharp - most popular upscaler, best for photos/realistic
    ULTRASHARP="$COMFYUI_DIR/models/upscale_models/4x-UltraSharp.pth"
    if [ ! -f "$ULTRASHARP" ]; then
        echo "Downloading 4x-UltraSharp upscaler..."
        download -O "$ULTRASHARP" \
            "https://huggingface.co/philz1337x/upscaler/resolve/main/4x-UltraSharp.pth?download=true"
    else
        echo "4x-UltraSharp already exists."
    fi

    # RealESRGAN_x4plus - best general-purpose upscaler for real photos
    REALESRGAN="$COMFYUI_DIR/models/upscale_models/RealESRGAN_x4plus.pth"
    if [ ! -f "$REALESRGAN" ]; then
        echo "Downloading RealESRGAN x4plus upscaler..."
        download -O "$REALESRGAN" \
            "https://github.com/xinntao/Real-ESRGAN/releases/download/v0.1.0/RealESRGAN_x4plus.pth"
    else
        echo "RealESRGAN_x4plus already exists."
    fi

    # 4x_NMKD-Siax_200k - highly popular balanced upscaler
    NMKD="$COMFYUI_DIR/models/upscale_models/4x_NMKD-Siax_200k.pth"
    if [ ! -f "$NMKD" ]; then
        echo "Downloading 4x NMKD-Siax upscaler..."
        download -O "$NMKD" \
            "https://huggingface.co/uwg/upscaler/resolve/main/ESRGAN/4x_NMKD-Siax_200k.pth?download=true"
    else
        echo "4x NMKD-Siax already exists."
    fi

    # -------------------------------------------------------
    # FACE RESTORATION - go in models/facerestore_models/
    # -------------------------------------------------------

    # CodeFormer - best face restoration, works great on InfiniteTalk outputs
    CODEFORMER="$COMFYUI_DIR/models/facerestore_models/codeformer.pth"
    if [ ! -f "$CODEFORMER" ]; then
        echo "Downloading CodeFormer face restore model..."
        download -O "$CODEFORMER" \
            "https://github.com/sczhou/CodeFormer/releases/download/v0.1.0/codeformer.pth"
    else
        echo "CodeFormer already exists."
    fi

    # GFPGANv1.4 - fast face enhancement, good for quick fixes
    GFPGAN="$COMFYUI_DIR/models/facerestore_models/GFPGANv1.4.pth"
    if [ ! -f "$GFPGAN" ]; then
        echo "Downloading GFPGAN v1.4 face restore model..."
        download -O "$GFPGAN" \
            "https://github.com/TencentARC/GFPGAN/releases/download/v1.3.4/GFPGANv1.4.pth"
    else
        echo "GFPGANv1.4 already exists."
    fi

    echo "=========================================="
    echo "Flux, upscaler, and face restore models complete!"
    echo "Note: FLUX models share clip_l + t5xxl encoders and ae.safetensors VAE."
    echo "Note: ae.safetensors VAE is already downloaded with z-image models."
    echo "=========================================="
}

# Function to copy pre-built ApexForge workflows from Docker image into network volume
setup_workflows() {
    echo "=========================================="
    echo "Setting up ApexForge curated workflows..."
    echo "=========================================="

    WORKFLOWS_DIR="$COMFYUI_DIR/user/default/workflows"
    REPO_TMP="/tmp/apexforge_repo"

    # Create curated folder structure on network volume
    mkdir -p "$WORKFLOWS_DIR/01 - Image Generation"
    mkdir -p "$WORKFLOWS_DIR/02 - Image Editing"
    mkdir -p "$WORKFLOWS_DIR/03 - Video Generation"
    mkdir -p "$WORKFLOWS_DIR/04 - Talking Avatars"
    mkdir -p "$WORKFLOWS_DIR/05 - Audio"
    mkdir -p "$WORKFLOWS_DIR/06 - Post Processing"

    # Clone the workflows matching this image's release tag (falls back to main)
    # Uses --depth 1 for speed (no history needed)
    echo "Cloning ApexForge workflows (v$APEXFORGE_VERSION)..."
    rm -rf "$REPO_TMP"
    if git clone --depth 1 --branch "v$APEXFORGE_VERSION" \
        https://github.com/Crowleypt/apexforge.git "$REPO_TMP" 2>&1 \
        || git clone --depth 1 https://github.com/Crowleypt/apexforge.git "$REPO_TMP" 2>&1; then

        WF_SRC="$REPO_TMP/workflows"

        # Helper: copy only if destination doesn't exist yet
        cpwf() {
            local src="$1"
            local dest="$2"
            if [ ! -f "$dest" ]; then
                if [ -f "$src" ]; then
                    cp "$src" "$dest"
                    echo "  ✓ $(basename $dest)"
                else
                    echo "  ✗ MISSING: $src"
                fi
            else
                echo "  ✓ $(basename $dest) already exists"
            fi
        }

        # ── 01 Image Generation ──────────────────────────────────
        echo "--- Image Generation ---"
        cpwf "$WF_SRC/01-Image-Generation/juggernaut_reborn_t2i.json" \
             "$WORKFLOWS_DIR/01 - Image Generation/juggernaut_reborn_t2i.json"
        cpwf "$WF_SRC/01-Image-Generation/juggernaut_reborn_i2i.json" \
             "$WORKFLOWS_DIR/01 - Image Generation/juggernaut_reborn_i2i.json"
        cpwf "$WF_SRC/01-Image-Generation/juggernaut_reborn_t2i_lora.json" \
             "$WORKFLOWS_DIR/01 - Image Generation/juggernaut_reborn_t2i_lora.json"
        cpwf "$WF_SRC/01-Image-Generation/juggernaut_reborn_t2i_controlnet.json" \
             "$WORKFLOWS_DIR/01 - Image Generation/juggernaut_reborn_t2i_controlnet.json"
        cpwf "$WF_SRC/01-Image-Generation/flux_dev_t2i.json" \
             "$WORKFLOWS_DIR/01 - Image Generation/flux_dev_t2i.json"
        cpwf "$WF_SRC/01-Image-Generation/z_image_turbo_aio_t2i.json" \
             "$WORKFLOWS_DIR/01 - Image Generation/z_image_turbo_aio_t2i.json"
        cpwf "$WF_SRC/01-Image-Generation/z_image_turbo_fp8_t2i.json" \
             "$WORKFLOWS_DIR/01 - Image Generation/z_image_turbo_fp8_t2i.json"
        cpwf "$WF_SRC/01-Image-Generation/z_image_turbo_gguf_t2i.json" \
             "$WORKFLOWS_DIR/01 - Image Generation/z_image_turbo_gguf_t2i.json"
        cpwf "$WF_SRC/01-Image-Generation/z_image_turbo_aio_t2i_lora.json" \
             "$WORKFLOWS_DIR/01 - Image Generation/z_image_turbo_aio_t2i_lora.json"
        cpwf "$WF_SRC/01-Image-Generation/z_image_turbo_aio_t2i_controlnet.json" \
             "$WORKFLOWS_DIR/01 - Image Generation/z_image_turbo_aio_t2i_controlnet.json"
        cpwf "$WF_SRC/01-Image-Generation/z_image_turbo_t2i.json" \
             "$WORKFLOWS_DIR/01 - Image Generation/z_image_turbo_t2i.json"
        cpwf "$WF_SRC/01-Image-Generation/z_image_base_t2i.json" \
             "$WORKFLOWS_DIR/01 - Image Generation/z_image_base_t2i.json"

        # ── 02 Image Editing ─────────────────────────────────────
        echo "--- Image Editing ---"
        cpwf "$WF_SRC/02-Image-Editing/flux_kontext_edit.json" \
             "$WORKFLOWS_DIR/02 - Image Editing/flux_kontext_edit.json"

        # ── 03 Video Generation ──────────────────────────────────
        echo "--- Video Generation ---"
        cpwf "$WF_SRC/03-Video-Generation/wan2_2_i2v.json" \
             "$WORKFLOWS_DIR/03 - Video Generation/wan2_2_i2v.json"
        cpwf "$WF_SRC/03-Video-Generation/wan2_2_t2v.json" \
             "$WORKFLOWS_DIR/03 - Video Generation/wan2_2_t2v.json"
        cpwf "$WF_SRC/03-Video-Generation/wan2_2_i2v_4step.json" \
             "$WORKFLOWS_DIR/03 - Video Generation/wan2_2_i2v_4step.json"
        cpwf "$WF_SRC/03-Video-Generation/wan2_1_i2v.json" \
             "$WORKFLOWS_DIR/03 - Video Generation/wan2_1_i2v.json"

        # ── 04 Talking Avatars ───────────────────────────────────
        echo "--- Talking Avatars ---"
        cpwf "$WF_SRC/04-Talking-Avatar/infinitetalk_single.json" \
             "$WORKFLOWS_DIR/04 - Talking Avatars/infinitetalk_single.json"
        cpwf "$WF_SRC/04-Talking-Avatar/multitalk.json" \
             "$WORKFLOWS_DIR/04 - Talking Avatars/multitalk.json"

        # ── 05 Audio ─────────────────────────────────────────────
        echo "--- Audio ---"
        cpwf "$WF_SRC/05-Audio/ace_step_music_generation.json" \
             "$WORKFLOWS_DIR/05 - Audio/ace_step_music_generation.json"
        cpwf "$WF_SRC/05-Audio/mmaudio_video_sound.json" \
             "$WORKFLOWS_DIR/05 - Audio/mmaudio_video_sound.json"

        # ── 06 Post Processing ───────────────────────────────────
        echo "--- Post Processing ---"
        cpwf "$WF_SRC/06-Post-Processing/upscale_simple_no_model.json" \
             "$WORKFLOWS_DIR/06 - Post Processing/upscale_simple_no_model.json"
        cpwf "$WF_SRC/06-Post-Processing/upscale_with_model.json" \
             "$WORKFLOWS_DIR/06 - Post Processing/upscale_with_model.json"
        cpwf "$WF_SRC/06-Post-Processing/z_image_upscaler.json" \
             "$WORKFLOWS_DIR/06 - Post Processing/z_image_upscaler.json"
        cpwf "$WF_SRC/06-Post-Processing/face_restore_codeformer.json" \
             "$WORKFLOWS_DIR/06 - Post Processing/face_restore_codeformer.json"
        cpwf "$WF_SRC/06-Post-Processing/rife_frame_interpolation.json" \
             "$WORKFLOWS_DIR/06 - Post Processing/rife_frame_interpolation.json"

        # Clean up the temp clone
        rm -rf "$REPO_TMP"

        echo "=========================================="
        echo "ApexForge workflows ready!"
        echo "  01 - Image Generation  (Juggernaut Reborn T2I/I2I/LoRA/CN, Flux Dev, Z-Image Turbo AIO/FP8/GGUF/LoRA/CN, Z-Image Turbo Official, Z-Image Base)"
        echo "  02 - Image Editing     (Flux Kontext)"
        echo "  03 - Video Generation  (Wan2.2 I2V, Wan2.2 T2V, Wan2.2 I2V 4-step, Wan2.1 I2V)"
        echo "  04 - Talking Avatars   (InfiniteTalk Single, MultiTalk)"
        echo "  05 - Audio             (ACE-Step Music, MMAudio)"
        echo "  06 - Post Processing   (Upscale Simple, Upscale ESRGAN, Z-Image Upscaler, Face Restore, RIFE)"
        echo "=========================================="
    else
        echo "WARNING: Could not clone ApexForge repo — workflows not installed."
        echo "Check network connectivity and try rebooting the pod."
    fi
}

# Function to download audio generation + frame interpolation models
download_audio_and_video_utils() {
    echo "=========================================="
    echo "Checking for audio and video utility models..."
    echo "=========================================="

    mkdir -p "$COMFYUI_DIR/models/checkpoints"
    mkdir -p "$COMFYUI_DIR/models/frame_interpolation"
    mkdir -p "$COMFYUI_DIR/models/mmaudio"

    # -------------------------------------------------------
    # ACE-STEP 1.5 TURBO AIO - Music generation from text/lyrics
    # Under 0.5s per song on 5090. Commercial-safe training data.
    # -------------------------------------------------------
    ACE_STEP_15="$COMFYUI_DIR/models/checkpoints/ace_step_1.5_turbo_aio.safetensors"
    if [ ! -f "$ACE_STEP_15" ]; then
        echo "Downloading ACE-Step 1.5 Turbo AIO music generation model (~7.7 GB)..."
        download -O "$ACE_STEP_15" \
            "https://huggingface.co/Comfy-Org/ace_step_1.5_ComfyUI_files/resolve/main/checkpoints/ace_step_1.5_turbo_aio.safetensors?download=true"
    else
        echo "ACE-Step 1.5 Turbo already exists."
    fi

    # ACE-Step v1 3.5B — used by the uploaded ace_step_music_generation.json workflow
    ACE_STEP_V1="$COMFYUI_DIR/models/checkpoints/ace_step_v1_3.5b.safetensors"
    if [ ! -f "$ACE_STEP_V1" ]; then
        echo "Downloading ACE-Step v1 3.5B music generation model (~7 GB)..."
        download -O "$ACE_STEP_V1" \
            "https://huggingface.co/Comfy-Org/ACE-Step_ComfyUI_repackaged/resolve/main/all_in_one/ace_step_v1_3.5b.safetensors?download=true"
    else
        echo "ACE-Step v1 3.5B already exists."
    fi

    # -------------------------------------------------------
    # MMAUDIO - Video-to-audio synthesis (add sound effects to videos)
    # Synced audio from Wan/InfiniteTalk video outputs
    # Models via Kijai's safetensors repo
    # -------------------------------------------------------
    MMAUDIO_MAIN="$COMFYUI_DIR/models/mmaudio/mmaudio_large_44k_v2_fp16.safetensors"
    if [ ! -f "$MMAUDIO_MAIN" ]; then
        echo "Downloading MMAudio large 44k v2 fp16..."
        download -O "$MMAUDIO_MAIN" \
            "https://huggingface.co/Kijai/MMAudio_safetensors/resolve/main/mmaudio_large_44k_v2_fp16.safetensors?download=true"
    else
        echo "MMAudio main model already exists."
    fi

    MMAUDIO_SYNCH="$COMFYUI_DIR/models/mmaudio/mmaudio_synchformer_fp16.safetensors"
    if [ ! -f "$MMAUDIO_SYNCH" ]; then
        echo "Downloading MMAudio synchformer fp16..."
        download -O "$MMAUDIO_SYNCH" \
            "https://huggingface.co/Kijai/MMAudio_safetensors/resolve/main/mmaudio_synchformer_fp16.safetensors?download=true"
    else
        echo "MMAudio synchformer already exists."
    fi

    MMAUDIO_VAE="$COMFYUI_DIR/models/mmaudio/mmaudio_vae_44k_fp16.safetensors"
    if [ ! -f "$MMAUDIO_VAE" ]; then
        echo "Downloading MMAudio VAE fp16..."
        download -O "$MMAUDIO_VAE" \
            "https://huggingface.co/Kijai/MMAudio_safetensors/resolve/main/mmaudio_vae_44k_fp16.safetensors?download=true"
    else
        echo "MMAudio VAE already exists."
    fi

    MMAUDIO_CLIP="$COMFYUI_DIR/models/mmaudio/apple_DFN5B-CLIP-ViT-H-14-384_fp16.safetensors"
    if [ ! -f "$MMAUDIO_CLIP" ]; then
        echo "Downloading MMAudio Apple CLIP fp16..."
        download -O "$MMAUDIO_CLIP" \
            "https://huggingface.co/Kijai/MMAudio_safetensors/resolve/main/apple_DFN5B-CLIP-ViT-H-14-384_fp16.safetensors?download=true"
    else
        echo "MMAudio CLIP already exists."
    fi

    # -------------------------------------------------------
    # RIFE v4.26 - Frame interpolation (doubles FPS of video output)
    # Essential post-process for InfiniteTalk/Wan video smoothing
    # -------------------------------------------------------
    RIFE="$COMFYUI_DIR/models/frame_interpolation/rife_v4.26.safetensors"
    if [ ! -f "$RIFE" ]; then
        echo "Downloading RIFE v4.26 frame interpolation (22 MB)..."
        download -O "$RIFE" \
            "https://huggingface.co/Comfy-Org/frame_interpolation/resolve/main/frame_interpolation/rife_v4.26.safetensors?download=true"
    else
        echo "RIFE v4.26 already exists."
    fi

    echo "=========================================="
    echo "Audio and video utility models complete!"
    echo "Required custom nodes (install via ComfyUI Manager):"
    echo "  - ComfyUI-MMAudio (kijai) - for MMAudio video-to-audio"
    echo "  - ComfyUI_ACE-Step - for music generation"
    echo "  - ComfyUI-Frame-Interpolation (Fannovel16) - for RIFE"
    echo "  - ComfyUI-Chatterbox - for TTS (auto-downloads its own models)"
    echo "=========================================="
}

# Function to download Flux Dev LoRAs
download_flux_loras() {
    echo "=========================================="
    echo "Checking for FLUX Dev LoRAs..."
    echo "=========================================="

    FLUX_LORA_DIR="$COMFYUI_DIR/models/loras/Flux"
    mkdir -p "$FLUX_LORA_DIR"

    # --- XLabs Realism LoRA - most popular photorealism LoRA for Flux Dev ---
    XLABS_REALISM="$FLUX_LORA_DIR/xlabs_flux_realism_lora.safetensors"
    if [ ! -f "$XLABS_REALISM" ]; then
        echo "Downloading XLabs Flux Realism LoRA..."
        download -O "$XLABS_REALISM" \
            "https://huggingface.co/XLabs-AI/flux-RealismLora/resolve/main/lora.safetensors?download=true"
    else
        echo "XLabs Realism LoRA already exists."
    fi

    # --- Shakker-Labs Add Details - enhances realism and natural skin, no trigger needed ---
    ADD_DETAILS="$FLUX_LORA_DIR/flux_dev_add_details.safetensors"
    if [ ! -f "$ADD_DETAILS" ]; then
        echo "Downloading Flux Add Details LoRA (natural skin, realism)..."
        download -O "$ADD_DETAILS" \
            "https://huggingface.co/Shakker-Labs/FLUX.1-dev-LoRA-add-details/resolve/main/FLUX-dev-lora-add_details.safetensors?download=true"
    else
        echo "Flux Add Details LoRA already exists."
    fi

    # --- Shakker-Labs AntiBlur - sharpens deep depth of field, great for portraits ---
    ANTI_BLUR="$FLUX_LORA_DIR/flux_dev_anti_blur.safetensors"
    if [ ! -f "$ANTI_BLUR" ]; then
        echo "Downloading Flux AntiBlur LoRA (sharpness, DoF)..."
        download -O "$ANTI_BLUR" \
            "https://huggingface.co/Shakker-Labs/FLUX.1-dev-LoRA-AntiBlur/resolve/main/FLUX-dev-lora-AntiBlur.safetensors?download=true"
    else
        echo "Flux AntiBlur LoRA already exists."
    fi

    # --- Alimama Turbo Alpha - 8-step speed LoRA for Flux Dev (official Alibaba) ---
    FLUX_TURBO="$FLUX_LORA_DIR/flux_turbo_alpha.safetensors"
    if [ ! -f "$FLUX_TURBO" ]; then
        echo "Downloading Flux Turbo Alpha LoRA (8-step speed)..."
        download -O "$FLUX_TURBO" \
            "https://huggingface.co/alimama-creative/FLUX.1-Turbo-Alpha/resolve/main/diffusion_pytorch_model.safetensors?download=true"
    else
        echo "Flux Turbo Alpha LoRA already exists."
    fi

    # --- ByteDance Hyper-SD 8-step LoRA - best quality/speed balance for Flux Dev ---
    HYPER_SD="$FLUX_LORA_DIR/hyper_flux_dev_8step.safetensors"
    if [ ! -f "$HYPER_SD" ]; then
        echo "Downloading ByteDance Hyper-SD 8-step LoRA..."
        download -O "$HYPER_SD" \
            "https://huggingface.co/ByteDance/Hyper-SD/resolve/main/Hyper-FLUX.1-dev-8steps-lora.safetensors?download=true"
    else
        echo "Hyper-SD 8-step LoRA already exists."
    fi

    echo "=========================================="
    echo "FLUX LoRAs complete!"
    echo "Usage notes:"
    echo "  XLabs Realism: trigger 'realism' (weight 0.7-1.0)"
    echo "  Add Details: no trigger needed (weight 1.0)"
    echo "  AntiBlur: no trigger needed (weight 1.0-1.5)"
    echo "  Turbo Alpha: use guidance_scale=3.5, 8 steps"
    echo "  Hyper-SD: use 8 steps, cfg=3.5"
    echo "=========================================="
}

# Function to download Z-Image LoRAs
download_zimage_loras() {
    echo "=========================================="
    echo "Checking for Z-Image LoRAs..."
    echo "=========================================="

    LORA_DIR="$COMFYUI_DIR/models/loras/Z-Image"
    mkdir -p "$LORA_DIR"

    # --- Official Alibaba-PAI Distill 4-step LoRA (fast generation) ---
    DISTILL_4="$LORA_DIR/Z-Image-Fun-Lora-Distill-4-Steps-2603.safetensors"
    if [ ! -f "$DISTILL_4" ]; then
        echo "Downloading Z-Image Distill 4-step LoRA..."
        download -O "$DISTILL_4" \
            "https://huggingface.co/alibaba-pai/Z-Image-Fun-Lora-Distill/resolve/main/Z-Image-Fun-Lora-Distill-4-Steps-2603.safetensors?download=true"
    else
        echo "Z-Image Distill 4-step already exists."
    fi

    # --- Official Alibaba-PAI Distill 8-step LoRA (balanced speed/quality) ---
    DISTILL_8="$LORA_DIR/Z-Image-Fun-Lora-Distill-8-Steps-2603.safetensors"
    if [ ! -f "$DISTILL_8" ]; then
        echo "Downloading Z-Image Distill 8-step LoRA..."
        download -O "$DISTILL_8" \
            "https://huggingface.co/alibaba-pai/Z-Image-Fun-Lora-Distill/resolve/main/Z-Image-Fun-Lora-Distill-8-Steps-2603.safetensors?download=true"
    else
        echo "Z-Image Distill 8-step already exists."
    fi

    # --- Flow-DPO v1 - improves lighting, color fidelity, realism (170MB) ---
    FLOW_DPO="$LORA_DIR/zit_fdpo_v1.safetensors"
    if [ ! -f "$FLOW_DPO" ]; then
        echo "Downloading Z-Image Flow-DPO LoRA (lighting & realism)..."
        download -O "$FLOW_DPO" \
            "https://huggingface.co/F16/z-image-turbo-flow-dpo/resolve/main/zit_fdpo_v1.safetensors?download=true"
    else
        echo "Z-Image Flow-DPO already exists."
    fi

    # --- SDA v1 - diversity recovery, reduces repetitive outputs (170MB) ---
    SDA="$LORA_DIR/zit_sda_v1.safetensors"
    if [ ! -f "$SDA" ]; then
        echo "Downloading Z-Image SDA LoRA (output diversity)..."
        download -O "$SDA" \
            "https://huggingface.co/F16/z-image-turbo-sda/resolve/main/zit_sda_v1.safetensors?download=true"
    else
        echo "Z-Image SDA already exists."
    fi

    # --- Realistic Skin Texture Style v3 - detailed skin pores (supports ZIB) ---
    SKIN_TEXTURE="$LORA_DIR/skin_texture_style_v3.safetensors"
    if [ ! -f "$SKIN_TEXTURE" ]; then
        echo "Downloading Realistic Skin Texture LoRA..."
        SKIN_URL="https://civitai.com/api/download/models/691191?type=Model&format=SafeTensor"
        AUTH_HEADER=()
        [ -n "$CIVITAI_TOKEN" ] && AUTH_HEADER=(-H "Authorization: Bearer $CIVITAI_TOKEN")
        # curl (not wget) because it drops the auth header when Civitai
        # redirects to its storage host, so the key only goes to civitai.com
        curl -fL --progress-bar "${AUTH_HEADER[@]}" -o "$SKIN_TEXTURE" "$SKIN_URL"
        FILE_SIZE=$(stat -c%s "$SKIN_TEXTURE" 2>/dev/null || echo 0)
        if [ "$FILE_SIZE" -lt 1000000 ]; then
            echo "WARNING: Skin Texture LoRA download may have failed (needs CIVITAI_TOKEN?). Removing..."
            rm -f "$SKIN_TEXTURE"
        fi
    else
        echo "Skin Texture LoRA already exists."
    fi

    echo "=========================================="
    echo "Z-Image LoRAs complete!"
    echo "Trigger words for skin texture: 'skin texture style', 'detailed skin pore', 'realistic skin style'"
    echo "=========================================="
}

# Function to download Wan2.2 models (I2V, T2V, T2I)
download_wan22_models() {
    echo "=========================================="
    echo "Checking for Wan2.2 models..."
    echo "=========================================="

    mkdir -p "$DIFFUSION_MODELS_DIR"
    mkdir -p "$COMFYUI_DIR/models/vae"

    # --- Wan2.2 I2V high noise fp8 (~14.3 GB) ---
    WAN22_I2V_HIGH="$DIFFUSION_MODELS_DIR/wan2.2_i2v_high_noise_14B_fp8_scaled.safetensors"
    if [ ! -f "$WAN22_I2V_HIGH" ]; then
        echo "Downloading Wan2.2 I2V high noise fp8 (~14.3 GB)..."
        download -O "$WAN22_I2V_HIGH" \
            "https://huggingface.co/Comfy-Org/Wan_2.2_ComfyUI_Repackaged/resolve/main/split_files/diffusion_models/wan2.2_i2v_high_noise_14B_fp8_scaled.safetensors?download=true"
    else
        echo "Wan2.2 I2V high noise already exists."
    fi

    # --- Wan2.2 I2V low noise fp8 (~14.3 GB) ---
    WAN22_I2V_LOW="$DIFFUSION_MODELS_DIR/wan2.2_i2v_low_noise_14B_fp8_scaled.safetensors"
    if [ ! -f "$WAN22_I2V_LOW" ]; then
        echo "Downloading Wan2.2 I2V low noise fp8 (~14.3 GB)..."
        download -O "$WAN22_I2V_LOW" \
            "https://huggingface.co/Comfy-Org/Wan_2.2_ComfyUI_Repackaged/resolve/main/split_files/diffusion_models/wan2.2_i2v_low_noise_14B_fp8_scaled.safetensors?download=true"
    else
        echo "Wan2.2 I2V low noise already exists."
    fi

    # --- Wan2.2 T2V high noise fp8 (~14.3 GB) - also used for T2I ---
    WAN22_T2V_HIGH="$DIFFUSION_MODELS_DIR/wan2.2_t2v_high_noise_14B_fp8_scaled.safetensors"
    if [ ! -f "$WAN22_T2V_HIGH" ]; then
        echo "Downloading Wan2.2 T2V high noise fp8 (~14.3 GB)..."
        download -O "$WAN22_T2V_HIGH" \
            "https://huggingface.co/Comfy-Org/Wan_2.2_ComfyUI_Repackaged/resolve/main/split_files/diffusion_models/wan2.2_t2v_high_noise_14B_fp8_scaled.safetensors?download=true"
    else
        echo "Wan2.2 T2V high noise already exists."
    fi

    # --- Wan2.2 T2V low noise fp8 (~14.3 GB) - also used for T2I ---
    WAN22_T2V_LOW="$DIFFUSION_MODELS_DIR/wan2.2_t2v_low_noise_14B_fp8_scaled.safetensors"
    if [ ! -f "$WAN22_T2V_LOW" ]; then
        echo "Downloading Wan2.2 T2V low noise fp8 (~14.3 GB)..."
        download -O "$WAN22_T2V_LOW" \
            "https://huggingface.co/Comfy-Org/Wan_2.2_ComfyUI_Repackaged/resolve/main/split_files/diffusion_models/wan2.2_t2v_low_noise_14B_fp8_scaled.safetensors?download=true"
    else
        echo "Wan2.2 T2V low noise already exists."
    fi

    # --- Wan2.2 VAE (1.41 GB - improved over 2.1 VAE) ---
    WAN22_VAE="$COMFYUI_DIR/models/vae/wan2.2_vae.safetensors"
    if [ ! -f "$WAN22_VAE" ]; then
        echo "Downloading Wan2.2 VAE (1.41 GB)..."
        download -O "$WAN22_VAE" \
            "https://huggingface.co/Comfy-Org/Wan_2.2_ComfyUI_Repackaged/resolve/main/split_files/vae/wan2.2_vae.safetensors?download=true"
    else
        echo "Wan2.2 VAE already exists."
    fi

    echo "=========================================="
    echo "Wan2.2 models complete!"
    echo "Note: Use wan2.2_t2v_*_noise models with 1 frame for text-to-image generation."
    echo "Note: umt5_xxl_fp8_e4m3fn_scaled.safetensors (text encoder) is shared with InfiniteTalk."
    echo "=========================================="
}

# Function to download z-image models
download_zimage_models() {
    echo "=========================================="
    echo "Checking for z-image models..."
    echo "=========================================="
    
    mkdir -p "$DIFFUSION_MODELS_DIR"
    mkdir -p "$TEXT_ENCODERS_DIR"
    mkdir -p "$VAE_DIR"

    # --- Z-Image Turbo bf16 (needed for Flow-DPO, SDA, and skin texture LoRAs) ---
    ZIMAGE_TURBO_PATH="$DIFFUSION_MODELS_DIR/z_image_turbo_bf16.safetensors"
    if [ ! -f "$ZIMAGE_TURBO_PATH" ]; then
        echo "Downloading Z-Image Turbo bf16..."
        download \
            -O "$ZIMAGE_TURBO_PATH" \
            "https://huggingface.co/Comfy-Org/z_image_turbo/resolve/main/split_files/diffusion_models/z_image_turbo_bf16.safetensors?download=true"
    else
        echo "Z-Image Turbo already exists."
    fi

    # --- Z-Image Base bf16 (better for Distill LoRAs and training) ---
    ZIMAGE_DIFFUSION_PATH="$DIFFUSION_MODELS_DIR/z_image_bf16.safetensors"
    if [ ! -f "$ZIMAGE_DIFFUSION_PATH" ]; then
        echo "Downloading z-image Base bf16 diffusion model..."
        download \
            -O "$ZIMAGE_DIFFUSION_PATH" \
            "https://huggingface.co/Comfy-Org/z_image/resolve/main/split_files/diffusion_models/z_image_bf16.safetensors?download=true"
    else
        echo "z-image Base diffusion model already exists."
    fi

    ZIMAGE_TEXT_ENCODER_PATH="$TEXT_ENCODERS_DIR/qwen_3_4b.safetensors"
    if [ ! -f "$ZIMAGE_TEXT_ENCODER_PATH" ]; then
        echo "Downloading z-image text encoder (Qwen 3 4B)..."
        download \
            -O "$ZIMAGE_TEXT_ENCODER_PATH" \
            "https://huggingface.co/Comfy-Org/z_image/resolve/main/split_files/text_encoders/qwen_3_4b.safetensors?download=true"
    else
        echo "z-image text encoder already exists."
    fi

    ZIMAGE_VAE_PATH="$VAE_DIR/ae.safetensors"
    if [ ! -f "$ZIMAGE_VAE_PATH" ]; then
        echo "Downloading z-image VAE..."
        download \
            -O "$ZIMAGE_VAE_PATH" \
            "https://huggingface.co/Comfy-Org/z_image/resolve/main/split_files/vae/ae.safetensors?download=true"
    else
        echo "z-image VAE already exists."
    fi
    
    echo "z-image model setup complete!"
}

# Function to install pre-configured custom nodes (pinned in CUSTOM_NODES)
install_custom_nodes() {
    echo "=========================================="
    echo "Installing pre-configured custom nodes..."
    echo "=========================================="
    cd "$COMFYUI_DIR/custom_nodes" || return

    # ComfyUI-Manager now ships with ComfyUI (pip package + --enable-manager).
    # Disable the old custom_nodes copy from earlier ApexForge versions.
    if [ -d "ComfyUI-Manager" ]; then
        echo "Disabling legacy custom_nodes/ComfyUI-Manager (now built into ComfyUI)..."
        rm -rf "ComfyUI-Manager.disabled"
        mv "ComfyUI-Manager" "ComfyUI-Manager.disabled"
    fi

    # Undo the local wav2vec2 patch so syncing the node never conflicts
    git -C "$COMFYUI_DIR/custom_nodes/ComfyUI-WanVideoWrapper" checkout -- multitalk/wav2vec2.py 2>/dev/null

    local entry name url ref
    for entry in "${CUSTOM_NODES[@]}"; do
        IFS='|' read -r name url ref <<< "$entry"
        echo "--- $name ---"
        sync_repo "$COMFYUI_DIR/custom_nodes/$name" "$url" "$ref" || continue
        cd "$COMFYUI_DIR/custom_nodes/$name"
        # Install dependencies once per container, and again if the version changes
        if [ "$(cat "$DEPS_MARKERS/$name" 2>/dev/null)" != "$(git rev-parse HEAD)" ]; then
            [ -f "requirements.txt" ] && pip install --no-cache-dir -r requirements.txt
            [ -f "install.py" ] && python install.py
            git rev-parse HEAD > "$DEPS_MARKERS/$name"
        fi
        cd "$COMFYUI_DIR/custom_nodes"
    done

    patch_wanvideo_wav2vec2
}

# InfiniteTalk / MultiTalk fail on transformers v5 with "'NoneType' object is
# not subscriptable": the v5 Wav2Vec2Encoder ignores output_hidden_states, so
# MultiTalkWav2VecEmbeds gets hidden_states=None
# (https://github.com/kijai/ComfyUI-WanVideoWrapper/issues/2052).
# Collect the per-layer states with forward hooks instead, which works on
# transformers v4 and v5. Skipped if upstream changes the file.
patch_wanvideo_wav2vec2() {
    local target="$COMFYUI_DIR/custom_nodes/ComfyUI-WanVideoWrapper/multitalk/wav2vec2.py"
    [ -f "$target" ] || return
    python - "$target" <<'PYEOF'
import sys
path = sys.argv[1]
src = open(path).read()
if "_apexforge_encode" in src:
    sys.exit(0)
call = """        encoder_outputs = self.encoder(
            hidden_states,
            attention_mask=attention_mask,
            output_attentions=output_attentions,
            output_hidden_states=output_hidden_states,
            return_dict=return_dict,
        )
"""
anchor = "from transformers.modeling_outputs import BaseModelOutput\n"
if src.count(call) != 2 or anchor not in src:
    print("WARNING: WanVideoWrapper wav2vec2.py changed upstream, ApexForge patch not applied")
    sys.exit(0)
helper = '''
# ApexForge patch (WanVideoWrapper#2052): transformers v5 ignores
# output_hidden_states in Wav2Vec2Encoder, so collect them with hooks.
def _apexforge_encode(encoder, hidden_states, attention_mask, output_attentions, output_hidden_states):
    if not output_hidden_states:
        return encoder(hidden_states, attention_mask=attention_mask,
                       output_attentions=output_attentions, return_dict=True)
    collected = []
    def before_first(module, args, kwargs):
        collected.append(args[0] if args else kwargs["hidden_states"])
    def after_each(module, args, output):
        collected.append(output[0] if isinstance(output, (tuple, list)) else output)
    hooks = [encoder.layers[0].register_forward_pre_hook(before_first, with_kwargs=True)]
    hooks += [layer.register_forward_hook(after_each) for layer in encoder.layers]
    try:
        out = encoder(hidden_states, attention_mask=attention_mask,
                      output_attentions=output_attentions, return_dict=True)
    finally:
        for h in hooks:
            h.remove()
    return BaseModelOutput(last_hidden_state=out[0], hidden_states=tuple(collected),
                           attentions=getattr(out, "attentions", None))
'''
src = src.replace(anchor, anchor + helper, 1)
src = src.replace(call, "        encoder_outputs = _apexforge_encode(self.encoder, hidden_states, attention_mask, output_attentions, output_hidden_states)\n")
open(path, "w").write(src)
print("Applied ApexForge wav2vec2 hidden_states patch (WanVideoWrapper#2052)")
PYEOF
}

# Function to download models required by uploaded custom workflows
# These were identified as missing from the original startup script
download_workflow_models() {
    echo "=========================================="
    echo "Checking for workflow-required models..."
    echo "=========================================="

    # -------------------------------------------------------
    # Z-IMAGE AIO CHECKPOINT (used by 5a + 6 + 7 workflows)
    # All-in-one: includes VAE + text encoder baked in
    # -------------------------------------------------------
    mkdir -p "$CHECKPOINTS_DIR/z-image"
    ZIMAGE_AIO="$CHECKPOINTS_DIR/z-image/z-image-turbo-fp8-aio.safetensors"
    if [ ! -f "$ZIMAGE_AIO" ]; then
        echo "Downloading Z-Image Turbo FP8 AIO checkpoint (~10 GB)..."
        download -O "$ZIMAGE_AIO" \
            "https://huggingface.co/SeeSee21/Z-Image-Turbo-AIO/resolve/main/z-image-turbo-fp8-aio.safetensors?download=true"
    else
        echo "Z-Image Turbo AIO checkpoint already exists."
    fi

    # -------------------------------------------------------
    # Z-IMAGE SPLIT FILES (used by 5b workflow — Kijai fp8 variant)
    # -------------------------------------------------------
    mkdir -p "$DIFFUSION_MODELS_DIR/z-image"
    ZIMAGE_KJ="$DIFFUSION_MODELS_DIR/z-image/z-image-turbo_fp8_scaled_e5m2_KJ.safetensors"
    if [ ! -f "$ZIMAGE_KJ" ]; then
        echo "Downloading Z-Image Turbo fp8 scaled (Kijai variant, ~6 GB)..."
        download -O "$ZIMAGE_KJ" \
            "https://huggingface.co/Kijai/Z-Image_comfy_fp8_scaled/resolve/main/z-image-turbo_fp8_scaled_e5m2_KJ.safetensors?download=true"
    else
        echo "Z-Image Turbo fp8 KJ already exists."
    fi

    # The 5b workflow uses the official qwen_3_4b.safetensors text encoder
    # (downloaded in download_zimage_models)

    # -------------------------------------------------------
    # Z-IMAGE GGUF (used by 5c workflow)
    # -------------------------------------------------------
    ZIMAGE_GGUF="$DIFFUSION_MODELS_DIR/z-image/z-image-turbo-q4_k_s.gguf"
    if [ ! -f "$ZIMAGE_GGUF" ]; then
        echo "Downloading Z-Image Turbo Q4_K_S GGUF (~5 GB)..."
        download -O "$ZIMAGE_GGUF" \
            "https://huggingface.co/gguf-org/z-image-gguf/resolve/main/z-image-turbo-q4_k_s.gguf?download=true"
    else
        echo "Z-Image Turbo GGUF already exists."
    fi

    # Official Qwen3-4B Q8 GGUF text encoder (used by 5c workflow)
    QWEN_GGUF="$TEXT_ENCODERS_DIR/Qwen3-4B-Q8_0.gguf"
    if [ ! -f "$QWEN_GGUF" ]; then
        echo "Downloading Qwen3-4B Q8 GGUF text encoder (official)..."
        download -O "$QWEN_GGUF" \
            "https://huggingface.co/Qwen/Qwen3-4B-GGUF/resolve/main/Qwen3-4B-Q8_0.gguf?download=true"
    else
        echo "Qwen3-4B GGUF text encoder already exists."
    fi

    # Optional uncensored community encoders (APEXFORGE_UNCENSORED_ENCODERS=true).
    # Select them in the CLIPLoader / CLIPLoaderGGUF node of the Z-Image workflows.
    if [ "$APEXFORGE_UNCENSORED_ENCODERS" = "true" ]; then
        QWEN_ABLIT="$TEXT_ENCODERS_DIR/Huihui-Qwen3-4B-abliterated-v2.Q8_0.gguf"
        if [ ! -f "$QWEN_ABLIT" ]; then
            echo "Downloading uncensored Qwen3-4B GGUF text encoder (abliterated q8)..."
            download -O "$QWEN_ABLIT" \
                "https://huggingface.co/mradermacher/Huihui-Qwen3-4B-abliterated-v2-GGUF/resolve/main/Huihui-Qwen3-4B-abliterated-v2.Q8_0.gguf?download=true"
        else
            echo "Uncensored Qwen3-4B fp8 already exists."
        fi
        QWEN_HERETIC="$TEXT_ENCODERS_DIR/qwen-4b-zimage-heretic-q8.gguf"
        if [ ! -f "$QWEN_HERETIC" ]; then
            echo "Downloading uncensored Qwen3-4B GGUF text encoder (heretic q8)..."
            download -O "$QWEN_HERETIC" \
                "https://huggingface.co/Lockout/qwen3-4b-heretic-zimage/resolve/main/qwen-4b-zimage-heretic-q8.gguf?download=true"
        else
            echo "Uncensored Qwen3-4B GGUF already exists."
        fi
    fi

    # -------------------------------------------------------
    # CONTROLNET SD1.5 MODELS (used by Juggernaut ControlNet workflow)
    # -------------------------------------------------------
    mkdir -p "$COMFYUI_DIR/models/controlnet/sd15"
    CANNY_CN="$COMFYUI_DIR/models/controlnet/sd15/control_v11p_sd15_canny_fp16.safetensors"
    if [ ! -f "$CANNY_CN" ]; then
        echo "Downloading ControlNet SD1.5 Canny fp16..."
        download -O "$CANNY_CN" \
            "https://huggingface.co/comfyanonymous/ControlNet-v1-1_fp16_safetensors/resolve/main/control_v11p_sd15_canny_fp16.safetensors?download=true"
    else
        echo "ControlNet Canny SD1.5 already exists."
    fi

    DEPTH_CN="$COMFYUI_DIR/models/controlnet/sd15/control_v11f1p_sd15_depth_fp16.safetensors"
    if [ ! -f "$DEPTH_CN" ]; then
        echo "Downloading ControlNet SD1.5 Depth fp16..."
        download -O "$DEPTH_CN" \
            "https://huggingface.co/comfyanonymous/ControlNet-v1-1_fp16_safetensors/resolve/main/control_v11f1p_sd15_depth_fp16.safetensors?download=true"
    else
        echo "ControlNet Depth SD1.5 already exists."
    fi

    POSE_CN="$COMFYUI_DIR/models/controlnet/sd15/control_v11p_sd15_openpose_fp16.safetensors"
    if [ ! -f "$POSE_CN" ]; then
        echo "Downloading ControlNet SD1.5 OpenPose fp16..."
        download -O "$POSE_CN" \
            "https://huggingface.co/comfyanonymous/ControlNet-v1-1_fp16_safetensors/resolve/main/control_v11p_sd15_openpose_fp16.safetensors?download=true"
    else
        echo "ControlNet OpenPose SD1.5 already exists."
    fi

    # -------------------------------------------------------
    # Z-IMAGE CONTROLNET UNION (used by 7 - Z-Image ControlNet workflow)
    # -------------------------------------------------------
    mkdir -p "$COMFYUI_DIR/models/model_patches"
    ZIMAGE_CN="$COMFYUI_DIR/models/model_patches/Z-Image-Turbo-Fun-Controlnet-Union.safetensors"
    if [ ! -f "$ZIMAGE_CN" ]; then
        echo "Downloading Z-Image ControlNet Union model patch..."
        download -O "$ZIMAGE_CN" \
            "https://huggingface.co/alibaba-pai/Z-Image-Turbo-Fun-Controlnet-Union/resolve/main/Z-Image-Turbo-Fun-Controlnet-Union.safetensors?download=true"
    else
        echo "Z-Image ControlNet Union already exists."
    fi

    # -------------------------------------------------------
    # INFINITETALK / MULTITALK GGUF MODELS
    # NOTE: The uploaded workflows use GGUF versions (via WanVideoWrapper)
    # not the .safetensors versions downloaded in download_talking_models()
    # -------------------------------------------------------
    mkdir -p "$DIFFUSION_MODELS_DIR"

    # Wan2.1 I2V GGUF base (required by both InfiniteTalk workflows)
    WAN21_I2V_GGUF="$DIFFUSION_MODELS_DIR/wan2.1-i2v-14b-480p-Q4_0.gguf"
    if [ ! -f "$WAN21_I2V_GGUF" ]; then
        echo "Downloading Wan2.1 I2V 14B GGUF Q4_0 (~9 GB)..."
        download -O "$WAN21_I2V_GGUF" \
            "https://huggingface.co/city96/Wan2.1-I2V-14B-480P-gguf/resolve/main/wan2.1-i2v-14b-480p-Q4_0.gguf?download=true"
    else
        echo "Wan2.1 I2V GGUF already exists."
    fi

    # InfiniteTalk Single GGUF
    IT_SINGLE_GGUF="$DIFFUSION_MODELS_DIR/Wan2_1-InfiniteTalk_Single_Q8.gguf"
    if [ ! -f "$IT_SINGLE_GGUF" ]; then
        echo "Downloading InfiniteTalk Single Q8 GGUF..."
        download -O "$IT_SINGLE_GGUF" \
            "https://huggingface.co/Kijai/WanVideo_comfy_GGUF/resolve/main/InfiniteTalk/Wan2_1-InfiniteTalk_Single_Q8.gguf?download=true"
    else
        echo "InfiniteTalk Single GGUF already exists."
    fi

    # InfiniteTalk Multi GGUF
    IT_MULTI_GGUF="$DIFFUSION_MODELS_DIR/Wan2_1-InfiniteTalk_Multi_Q8.gguf"
    if [ ! -f "$IT_MULTI_GGUF" ]; then
        echo "Downloading InfiniteTalk Multi Q8 GGUF..."
        download -O "$IT_MULTI_GGUF" \
            "https://huggingface.co/Kijai/WanVideo_comfy_GGUF/resolve/main/InfiniteTalk/Wan2_1-InfiniteTalk_Multi_Q8.gguf?download=true"
    else
        echo "InfiniteTalk Multi GGUF already exists."
    fi

    # -------------------------------------------------------
    # WAV2VEC2 SAFETENSORS (WanVideoWrapper needs single .safetensors file)
    # Different from the chinese-wav2vec2-base folder downloaded previously
    # -------------------------------------------------------
    mkdir -p "$COMFYUI_DIR/models/wav2vec2"
    WAV2VEC_SF="$COMFYUI_DIR/models/wav2vec2/wav2vec2-chinese-base_fp16.safetensors"
    if [ ! -f "$WAV2VEC_SF" ]; then
        echo "Downloading wav2vec2-chinese-base fp16 safetensors..."
        download -O "$WAV2VEC_SF" \
            "https://huggingface.co/Kijai/wav2vec2_safetensors/resolve/main/wav2vec2-chinese-base_fp16.safetensors?download=true"
    else
        echo "wav2vec2 safetensors already exists."
    fi

    # -------------------------------------------------------
    # UMT5 TEXT ENCODER FOR WANVIDEOWRAPPER (models/clip/ path)
    # Different from the text_encoders/ version — WanVideoWrapper
    # specifically loads from models/clip/
    # -------------------------------------------------------
    mkdir -p "$COMFYUI_DIR/models/clip"
    UMT5_CLIP="$COMFYUI_DIR/models/clip/umt5-xxl-enc-bf16.safetensors"
    if [ ! -f "$UMT5_CLIP" ]; then
        echo "Downloading UMT5 XXL text encoder for WanVideoWrapper (models/clip/)..."
        download -O "$UMT5_CLIP" \
            "https://huggingface.co/ALGOTECH/WanVideo_comfy/resolve/main/umt5-xxl-enc-bf16.safetensors?download=true"
    else
        echo "UMT5 clip encoder already exists."
    fi

    # -------------------------------------------------------
    # WAN2.2 LIGHTX2V LORAS (used by wan2_2_image_to_video.json workflow)
    # -------------------------------------------------------
    WAN22_LORA_LOW="$COMFYUI_DIR/models/loras/wan2.2_i2v_lightx2v_4steps_lora_v1_low_noise.safetensors"
    if [ ! -f "$WAN22_LORA_LOW" ]; then
        echo "Downloading Wan2.2 LightX2V low noise LoRA..."
        download -O "$WAN22_LORA_LOW" \
            "https://huggingface.co/Comfy-Org/Wan_2.2_ComfyUI_Repackaged/resolve/main/split_files/loras/wan2.2_i2v_lightx2v_4steps_lora_v1_low_noise.safetensors?download=true"
    else
        echo "Wan2.2 LightX2V low noise LoRA already exists."
    fi

    WAN22_LORA_HIGH="$COMFYUI_DIR/models/loras/wan2.2_i2v_lightx2v_4steps_lora_v1_high_noise.safetensors"
    if [ ! -f "$WAN22_LORA_HIGH" ]; then
        echo "Downloading Wan2.2 LightX2V high noise LoRA..."
        download -O "$WAN22_LORA_HIGH" \
            "https://huggingface.co/Comfy-Org/Wan_2.2_ComfyUI_Repackaged/resolve/main/split_files/loras/wan2.2_i2v_lightx2v_4steps_lora_v1_high_noise.safetensors?download=true"
    else
        echo "Wan2.2 LightX2V high noise LoRA already exists."
    fi

    # -------------------------------------------------------
    # SD1.5 LORAS
    # -------------------------------------------------------
    mkdir -p "$COMFYUI_DIR/models/loras/sd15"
    CAKE_LORA="$COMFYUI_DIR/models/loras/sd15/CakeStyle.safetensors"
    if [ ! -f "$CAKE_LORA" ]; then
        echo "Downloading CakeStyle SD1.5 LoRA (demo asset for Juggernaut LoRA workflow)..."
        download -O "$CAKE_LORA" \
            "https://huggingface.co/mnemic/CakeStyle-SD1.5-LoRA/resolve/main/CakeStyle.safetensors?download=true"
    else
        echo "CakeStyle LoRA already exists."
    fi

    echo "=========================================="
    echo "Workflow-required models complete!"
    echo "=========================================="
}

# Function to start ComfyUI
start_comfyui() {
    cd "$COMFYUI_DIR"

    FIXED_ARGS="--listen 0.0.0.0 --port 8188 --enable-manager"

    if [ ! -f "$ARGS_FILE" ]; then
        echo "# Add one argument per line" > "$ARGS_FILE"
        echo "--preview-method auto" >> "$ARGS_FILE"
        # Only add --use-sage-attention if SageAttention is actually installed
        # It will be added automatically on next boot once installed
        if python -c "import sageattention" 2>/dev/null; then
            echo "--use-sage-attention" >> "$ARGS_FILE"
        fi
    fi

    # If args file exists but sage attention flag is set without the package, remove it
    if [ -f "$ARGS_FILE" ] && grep -q "use-sage-attention" "$ARGS_FILE"; then
        if ! python -c "import sageattention" 2>/dev/null; then
            echo "WARNING: SageAttention not installed — removing --use-sage-attention flag"
            sed -i '/use-sage-attention/d' "$ARGS_FILE"
        fi
    fi

    # If SageAttention is now installed, add the flag if not already present
    if python -c "import sageattention" 2>/dev/null; then
        if ! grep -q "use-sage-attention" "$ARGS_FILE"; then
            echo "--use-sage-attention" >> "$ARGS_FILE"
            echo "SageAttention detected — enabled in ComfyUI args"
        fi
    fi

    # Read args only after the SageAttention flag has been added or removed,
    # so this boot uses the same args the file now holds
    CUSTOM_ARGS=$(grep -v '^#' "$ARGS_FILE" | tr '\n' ' ')

    echo "=========================================="
    echo "Starting ComfyUI on port 8188"
    echo "PyTorch: $(python -c 'import torch; print(torch.__version__)')"
    echo "SageAttention: $(python -c 'import sageattention; print(sageattention.__version__)' 2>/dev/null || echo 'not found')"
    echo "sm_120 support: $(python -c 'import torch; print("sm_120" in torch.cuda.get_arch_list())')"
    echo "=========================================="

    python main.py $FIXED_ARGS $CUSTOM_ARGS 2>&1 | tee /comfyui/comfyui.log
}

# --- Network Readiness ---
wait_for_network() {
    echo "Waiting for network..."
    echo "nameserver 8.8.8.8" > /etc/resolv.conf
    echo "nameserver 8.8.4.4" >> /etc/resolv.conf

    for i in $(seq 1 15); do
        if curl -s --max-time 5 --head https://github.com > /dev/null 2>&1; then
            echo "Network is ready!"
            return 0
        fi
        echo "Attempt $i/15: waiting 5 seconds..."
        sleep 5
    done
    echo "WARNING: Network may not be ready. Proceeding anyway..."
}

# --- Main Program ---

# Function to install SageAttention at runtime (requires live GPU)
install_sageattention() {
    if python -c "import sageattention" 2>/dev/null; then
        echo "SageAttention already installed — skipping."
        return
    fi

    echo "=========================================="
    echo "Installing SageAttention (first boot only)"
    echo "This requires a live GPU and takes 10-15 mins"
    echo "=========================================="

    # Install cupy pre-built wheel first — avoids compilation failure
    # Use the cu128 pre-built wheel matching our CUDA version
    pip install --no-cache-dir cupy-cuda12x 2>/dev/null || \
        echo "WARNING: cupy install failed — SageAttention may still work without it"

    # Clone and install SageAttention from source
    SAGE_DIR="/comfyui/SageAttention"
    if [ ! -d "$SAGE_DIR" ]; then
        git clone https://github.com/thu-ml/SageAttention.git "$SAGE_DIR"
    fi

    # Build the pinned release, not whatever is on master today
    git -C "$SAGE_DIR" fetch -q --tags origin 2>/dev/null
    git -C "$SAGE_DIR" checkout -q "$SAGEATTENTION_REF" || echo "WARNING: Could not check out SageAttention $SAGEATTENTION_REF"
    cd "$SAGE_DIR"

    # Build only for the GPU in this pod. v2.2.0's setup.py applies every
    # listed arch to every kernel, so a list with 9.0 plus any other arch
    # compiles the Hopper-only (wgmma) kernel for that arch and ptxas fails.
    # The package lives on the container disk and is rebuilt per container,
    # so building for the current GPU is always correct.
    # Not editable (-e): the v2.2.0 build backend has no editable support.
    # ninja is required, not just faster: without it torch falls back to its
    # distutils backend, which swaps a shared compiler between nvcc and g++
    # per file. SageAttention builds its extensions on parallel threads, so
    # a .cpp file can be handed to nvcc ("nvcc fatal: Unknown option '-fopenmp'").
    pip install --no-cache-dir ninja

    SAGE_ARCH=$(nvidia-smi --query-gpu=compute_cap --format=csv,noheader 2>/dev/null | head -1 | tr -d ' ')
    SAGE_ARCH=${SAGE_ARCH:-12.0}
    echo "Building SageAttention for compute capability $SAGE_ARCH"
    TORCH_CUDA_ARCH_LIST="$SAGE_ARCH" \
        pip install --no-cache-dir . --no-build-isolation

    cd /

    # Verify
    if python -c "import sageattention; print('SageAttention OK:', sageattention.__version__)" 2>/dev/null; then
        echo "SageAttention installed successfully!"
    else
        echo "WARNING: SageAttention install failed — ComfyUI will run without it"
        echo "This is non-fatal. Everything else works normally."
    fi
}

echo "=========================================="
echo "ApexForge v$APEXFORGE_VERSION by Alex Harte"
echo "Guides & workflows: https://alexanderharte.com"
echo "ComfyUI $COMFYUI_REF - RTX 5090 / Blackwell"
echo "CUDA 12.8 + PyTorch 2.10.0 stable + SageAttention"
echo "=========================================="

if [ -d "$COMFYUI_DIR" ]; then
    echo ">>> NETWORK VOLUME DETECTED: Fast boot mode."
else
    echo ">>> FIRST-TIME INSTALL: Full setup will begin."
fi
echo "=========================================="

wait_for_network
start_jupyter
setup_comfyui
configure_manager
install_sageattention
install_custom_nodes
setup_workflows
remove_broken_downloads
download_model
download_zimage_models
download_zimage_loras
download_flux_loras
download_talking_models
download_wan22_models
download_utility_models
download_audio_and_video_utils
download_workflow_models
start_comfyui
