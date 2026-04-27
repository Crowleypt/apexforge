#!/bin/bash
# Do NOT use set -e — git pull failures should not kill the whole script

# --- Configuration ---
COMFYUI_DIR="/comfyui/ComfyUI"
ARGS_FILE="/comfyui/comfyui_args.txt"
CHECKPOINTS_DIR="$COMFYUI_DIR/models/checkpoints"
DIFFUSION_MODELS_DIR="$COMFYUI_DIR/models/diffusion_models"
TEXT_ENCODERS_DIR="$COMFYUI_DIR/models/text_encoders"
VAE_DIR="$COMFYUI_DIR/models/vae"

# Optional: set CIVITAI_TOKEN as a RunPod environment variable for gated models
# Without this, Civitai downloads (Juggernaut, Skin Texture LoRA) may fail silently
CIVITAI_TOKEN="${CIVITAI_TOKEN:-}"

# --- Use system Python (has PyTorch 2.10.0 stable baked into image) ---
# SageAttention is installed at runtime on first boot (requires live GPU)

# --- Function Definitions ---

# Function to start JupyterLab in the background
start_jupyter() {
    echo "=========================================="
    echo "Starting JupyterLab on port 8888"
    echo "=========================================="
    
    mkdir -p /root/.jupyter
    
    if [ ! -f /root/.jupyter/jupyter_lab_config.py ]; then
        jupyter lab --generate-config
    fi
    
    nohup jupyter lab \
        --ip=0.0.0.0 \
        --port=8888 \
        --no-browser \
        --allow-root \
        --ServerApp.token='' \
        --ServerApp.password='' \
        --ServerApp.root_dir=/comfyui \
        --ServerApp.allow_origin='*' \
        > /comfyui/jupyter.log 2>&1 &
    
    echo "JupyterLab started on port 8888"
}

# Function to install or update ComfyUI
setup_comfyui() {
    if [ ! -d "$COMFYUI_DIR" ]; then
        echo "ComfyUI not found. Cloning repository..."
        mkdir -p /comfyui
        git clone https://github.com/Comfy-Org/ComfyUI.git "$COMFYUI_DIR"
        cd "$COMFYUI_DIR"
        echo "Installing ComfyUI dependencies into system Python..."
        pip install --no-cache-dir -r requirements.txt
    else
        echo "ComfyUI found. Checking for updates..."
        cd "$COMFYUI_DIR"
        git pull || echo "WARNING: Could not pull ComfyUI updates. Continuing with existing version."
        echo "Updating core dependencies..."
        pip install --no-cache-dir -r requirements.txt || echo "WARNING: Could not update core dependencies."
    fi
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
        wget --progress=bar:force:noscroll -O "$MODEL_PATH" \
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
        wget --progress=bar:force:noscroll -O "$WAN_I2V" \
            "https://huggingface.co/Comfy-Org/Wan_2.1_ComfyUI_repackaged/resolve/main/split_files/diffusion_models/wan2.1_i2v_480p_14B_fp16.safetensors?download=true"
    else
        echo "Wan2.1 I2V 14B 480p already exists."
    fi

    # --- InfiniteTalk Single (from MeiGen-AI official HuggingFace) ---
    INFINITETALK_SINGLE="$DIFFUSION_MODELS_DIR/InfiniteTalk/infinitetalk_single.safetensors"
    if [ ! -f "$INFINITETALK_SINGLE" ]; then
        echo "Downloading InfiniteTalk Single..."
        wget --progress=bar:force:noscroll -O "$INFINITETALK_SINGLE" \
            "https://huggingface.co/MeiGen-AI/InfiniteTalk/resolve/main/comfyui/infinitetalk_single.safetensors?download=true"
    else
        echo "InfiniteTalk Single already exists."
    fi

    # --- InfiniteTalk Multi (from MeiGen-AI official HuggingFace) ---
    INFINITETALK_MULTI="$DIFFUSION_MODELS_DIR/InfiniteTalk/infinitetalk_multi.safetensors"
    if [ ! -f "$INFINITETALK_MULTI" ]; then
        echo "Downloading InfiniteTalk Multi..."
        wget --progress=bar:force:noscroll -O "$INFINITETALK_MULTI" \
            "https://huggingface.co/MeiGen-AI/InfiniteTalk/resolve/main/comfyui/infinitetalk_multi.safetensors?download=true"
    else
        echo "InfiniteTalk Multi already exists."
    fi

    # --- MultiTalk model (9.95 GB, from MeiGen-AI official HuggingFace) ---
    MULTITALK="$DIFFUSION_MODELS_DIR/multitalk.safetensors"
    if [ ! -f "$MULTITALK" ]; then
        echo "Downloading MultiTalk model (9.95 GB)..."
        wget --progress=bar:force:noscroll -O "$MULTITALK" \
            "https://huggingface.co/MeiGen-AI/MeiGen-MultiTalk/resolve/main/multitalk.safetensors?download=true"
    else
        echo "MultiTalk model already exists."
    fi

    # --- LightX2V I2V LoRA rank64 (738 MB) - speed acceleration LoRA ---
    LIGHTX2V="$COMFYUI_DIR/models/loras/Lightx2v/lightx2v_I2V_14B_480p_cfg_step_distill_rank64_bf16.safetensors"
    if [ ! -f "$LIGHTX2V" ]; then
        echo "Downloading LightX2V I2V LoRA rank64 (738 MB)..."
        wget --progress=bar:force:noscroll -O "$LIGHTX2V" \
            "https://huggingface.co/Kijai/WanVideo_comfy/resolve/main/Lightx2v/lightx2v_I2V_14B_480p_cfg_step_distill_rank64_bf16.safetensors?download=true"
    else
        echo "LightX2V LoRA already exists."
    fi

    # --- UMT5 XXL text encoder fp8 (from Comfy-Org official) ---
    UMT5="$COMFYUI_DIR/models/text_encoders/umt5_xxl_fp8_e4m3fn_scaled.safetensors"
    if [ ! -f "$UMT5" ]; then
        echo "Downloading UMT5 XXL text encoder..."
        wget --progress=bar:force:noscroll -O "$UMT5" \
            "https://huggingface.co/Comfy-Org/Wan_2.1_ComfyUI_repackaged/resolve/main/split_files/text_encoders/umt5_xxl_fp8_e4m3fn_scaled.safetensors?download=true"
    else
        echo "UMT5 text encoder already exists."
    fi

    # --- Wan 2.1 VAE (from Comfy-Org official) ---
    WAN_VAE="$COMFYUI_DIR/models/vae/wan_2.1_vae.safetensors"
    if [ ! -f "$WAN_VAE" ]; then
        echo "Downloading Wan 2.1 VAE..."
        wget --progress=bar:force:noscroll -O "$WAN_VAE" \
            "https://huggingface.co/Comfy-Org/Wan_2.1_ComfyUI_repackaged/resolve/main/split_files/vae/wan_2.1_vae.safetensors?download=true"
    else
        echo "Wan 2.1 VAE already exists."
    fi

    # --- CLIP Vision H (from Comfy-Org official) ---
    CLIP_VISION="$COMFYUI_DIR/models/clip_vision/clip_vision_h.safetensors"
    if [ ! -f "$CLIP_VISION" ]; then
        echo "Downloading CLIP Vision H..."
        wget --progress=bar:force:noscroll -O "$CLIP_VISION" \
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
        wget --progress=bar:force:noscroll -O "$CLIP_L" \
            "https://huggingface.co/comfyanonymous/flux_text_encoders/resolve/main/clip_l.safetensors?download=true"
    else
        echo "clip_l already exists."
    fi

    # t5xxl fp8 scaled (~4.6GB) - shared by all Flux models
    T5XXL="$COMFYUI_DIR/models/text_encoders/t5xxl_fp8_e4m3fn_scaled.safetensors"
    if [ ! -f "$T5XXL" ]; then
        echo "Downloading FLUX t5xxl fp8 text encoder (~4.6 GB)..."
        wget --progress=bar:force:noscroll -O "$T5XXL" \
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
        wget --progress=bar:force:noscroll -O "$FLUX_DEV" \
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
        wget --progress=bar:force:noscroll -O "$FLUX_KONTEXT" \
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
        wget --progress=bar:force:noscroll -O "$ULTRASHARP" \
            "https://huggingface.co/philz1337x/upscaler/resolve/main/4x-UltraSharp.pth?download=true"
    else
        echo "4x-UltraSharp already exists."
    fi

    # RealESRGAN_x4plus - best general-purpose upscaler for real photos
    REALESRGAN="$COMFYUI_DIR/models/upscale_models/RealESRGAN_x4plus.pth"
    if [ ! -f "$REALESRGAN" ]; then
        echo "Downloading RealESRGAN x4plus upscaler..."
        wget --progress=bar:force:noscroll -O "$REALESRGAN" \
            "https://github.com/xinntao/Real-ESRGAN/releases/download/v0.1.0/RealESRGAN_x4plus.pth"
    else
        echo "RealESRGAN_x4plus already exists."
    fi

    # 4x_NMKD-Siax_200k - highly popular balanced upscaler
    NMKD="$COMFYUI_DIR/models/upscale_models/4x_NMKD-Siax_200k.pth"
    if [ ! -f "$NMKD" ]; then
        echo "Downloading 4x NMKD-Siax upscaler..."
        wget --progress=bar:force:noscroll -O "$NMKD" \
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
        wget --progress=bar:force:noscroll -O "$CODEFORMER" \
            "https://github.com/sczhou/CodeFormer/releases/download/v0.1.0/codeformer.pth"
    else
        echo "CodeFormer already exists."
    fi

    # GFPGANv1.4 - fast face enhancement, good for quick fixes
    GFPGAN="$COMFYUI_DIR/models/facerestore_models/GFPGANv1.4.pth"
    if [ ! -f "$GFPGAN" ]; then
        echo "Downloading GFPGAN v1.4 face restore model..."
        wget --progress=bar:force:noscroll -O "$GFPGAN" \
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

    # Workflows are baked into the Docker image at /workflows/
    # (Add to Dockerfile: COPY workflows/ /workflows/)
    WF_SRC="/workflows"
    WORKFLOWS_DIR="$COMFYUI_DIR/user/default/workflows"

    # Create curated folder structure
    mkdir -p "$WORKFLOWS_DIR/01 - Image Generation"
    mkdir -p "$WORKFLOWS_DIR/02 - Image Editing"
    mkdir -p "$WORKFLOWS_DIR/03 - Video Generation"
    mkdir -p "$WORKFLOWS_DIR/04 - Talking Avatars"
    mkdir -p "$WORKFLOWS_DIR/05 - Audio"
    mkdir -p "$WORKFLOWS_DIR/06 - Post Processing"

    # Helper: copy workflow from image, skip if already exists
    cpwf() {
        local src="$1"
        local dest="$2"
        if [ ! -f "$dest" ]; then
            if [ -f "$src" ]; then
                cp "$src" "$dest"
                echo "  ✓ $(basename $dest)"
            else
                echo "  ✗ MISSING SOURCE: $src"
            fi
        else
            echo "  ✓ $(basename $dest) already exists"
        fi
    }

    # ── 01 Image Generation ──────────────────────────────────
    echo "--- Image Generation ---"
    cpwf "$WF_SRC/01 - Image Generation/juggernaut_reborn_t2i.json" \
         "$WORKFLOWS_DIR/01 - Image Generation/juggernaut_reborn_t2i.json"
    cpwf "$WF_SRC/01 - Image Generation/juggernaut_reborn_i2i.json" \
         "$WORKFLOWS_DIR/01 - Image Generation/juggernaut_reborn_i2i.json"
    cpwf "$WF_SRC/01 - Image Generation/juggernaut_reborn_t2i_lora.json" \
         "$WORKFLOWS_DIR/01 - Image Generation/juggernaut_reborn_t2i_lora.json"
    cpwf "$WF_SRC/01 - Image Generation/juggernaut_reborn_t2i_controlnet.json" \
         "$WORKFLOWS_DIR/01 - Image Generation/juggernaut_reborn_t2i_controlnet.json"
    cpwf "$WF_SRC/01 - Image Generation/flux_dev_t2i.json" \
         "$WORKFLOWS_DIR/01 - Image Generation/flux_dev_t2i.json"
    cpwf "$WF_SRC/01 - Image Generation/z_image_turbo_aio_t2i.json" \
         "$WORKFLOWS_DIR/01 - Image Generation/z_image_turbo_aio_t2i.json"
    cpwf "$WF_SRC/01 - Image Generation/z_image_turbo_fp8_t2i.json" \
         "$WORKFLOWS_DIR/01 - Image Generation/z_image_turbo_fp8_t2i.json"
    cpwf "$WF_SRC/01 - Image Generation/z_image_turbo_gguf_t2i.json" \
         "$WORKFLOWS_DIR/01 - Image Generation/z_image_turbo_gguf_t2i.json"
    cpwf "$WF_SRC/01 - Image Generation/z_image_turbo_aio_t2i_lora.json" \
         "$WORKFLOWS_DIR/01 - Image Generation/z_image_turbo_aio_t2i_lora.json"
    cpwf "$WF_SRC/01 - Image Generation/z_image_turbo_aio_t2i_controlnet.json" \
         "$WORKFLOWS_DIR/01 - Image Generation/z_image_turbo_aio_t2i_controlnet.json"
    cpwf "$WF_SRC/01 - Image Generation/z_image_turbo_t2i.json" \
         "$WORKFLOWS_DIR/01 - Image Generation/z_image_turbo_t2i.json"
    cpwf "$WF_SRC/01 - Image Generation/z_image_base_t2i.json" \
         "$WORKFLOWS_DIR/01 - Image Generation/z_image_base_t2i.json"

    # ── 02 Image Editing ─────────────────────────────────────
    echo "--- Image Editing ---"
    cpwf "$WF_SRC/02 - Image Editing/flux_kontext_edit.json" \
         "$WORKFLOWS_DIR/02 - Image Editing/flux_kontext_edit.json"

    # ── 03 Video Generation ──────────────────────────────────
    echo "--- Video Generation ---"
    cpwf "$WF_SRC/03 - Video Generation/wan2_2_i2v.json" \
         "$WORKFLOWS_DIR/03 - Video Generation/wan2_2_i2v.json"
    cpwf "$WF_SRC/03 - Video Generation/wan2_2_t2v.json" \
         "$WORKFLOWS_DIR/03 - Video Generation/wan2_2_t2v.json"
    cpwf "$WF_SRC/03 - Video Generation/wan2_2_i2v_4step.json" \
         "$WORKFLOWS_DIR/03 - Video Generation/wan2_2_i2v_4step.json"
    cpwf "$WF_SRC/03 - Video Generation/wan2_1_i2v.json" \
         "$WORKFLOWS_DIR/03 - Video Generation/wan2_1_i2v.json"

    # ── 04 Talking Avatars ───────────────────────────────────
    echo "--- Talking Avatars ---"
    cpwf "$WF_SRC/04 - Talking Avatars/infinitetalk_single.json" \
         "$WORKFLOWS_DIR/04 - Talking Avatars/infinitetalk_single.json"
    cpwf "$WF_SRC/04 - Talking Avatars/multitalk.json" \
         "$WORKFLOWS_DIR/04 - Talking Avatars/multitalk.json"

    # ── 05 Audio ─────────────────────────────────────────────
    echo "--- Audio ---"
    cpwf "$WF_SRC/05 - Audio/ace_step_music_generation.json" \
         "$WORKFLOWS_DIR/05 - Audio/ace_step_music_generation.json"
    cpwf "$WF_SRC/05 - Audio/mmaudio_video_sound.json" \
         "$WORKFLOWS_DIR/05 - Audio/mmaudio_video_sound.json"

    # ── 06 Post Processing ───────────────────────────────────
    echo "--- Post Processing ---"
    cpwf "$WF_SRC/06 - Post Processing/upscale_simple_no_model.json" \
         "$WORKFLOWS_DIR/06 - Post Processing/upscale_simple_no_model.json"
    cpwf "$WF_SRC/06 - Post Processing/upscale_with_model.json" \
         "$WORKFLOWS_DIR/06 - Post Processing/upscale_with_model.json"
    cpwf "$WF_SRC/06 - Post Processing/z_image_upscaler.json" \
         "$WORKFLOWS_DIR/06 - Post Processing/z_image_upscaler.json"
    cpwf "$WF_SRC/06 - Post Processing/face_restore_codeformer.json" \
         "$WORKFLOWS_DIR/06 - Post Processing/face_restore_codeformer.json"
    cpwf "$WF_SRC/06 - Post Processing/rife_frame_interpolation.json" \
         "$WORKFLOWS_DIR/06 - Post Processing/rife_frame_interpolation.json"

    echo "=========================================="
    echo "ApexForge workflows ready!"
    echo "  01 - Image Generation  (Juggernaut Reborn T2I/I2I/LoRA/CN, Flux Dev, Z-Image Turbo AIO/FP8/GGUF/LoRA/CN, Z-Image Turbo Official, Z-Image Base)"
    echo "  02 - Image Editing     (Flux Kontext)"
    echo "  03 - Video Generation  (Wan2.2 I2V, Wan2.2 T2V, Wan2.2 I2V 4-step, Wan2.1 I2V)"
    echo "  04 - Talking Avatars   (InfiniteTalk Single, MultiTalk)"
    echo "  05 - Audio             (ACE-Step Music, MMAudio)"
    echo "  06 - Post Processing   (Upscale Simple, Upscale ESRGAN, Z-Image Upscaler, Face Restore, RIFE)"
    echo "=========================================="
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
        wget --progress=bar:force:noscroll -O "$ACE_STEP_15" \
            "https://huggingface.co/Comfy-Org/ace_step_1.5_ComfyUI_files/resolve/main/checkpoints/ace_step_1.5_turbo_aio.safetensors?download=true"
    else
        echo "ACE-Step 1.5 Turbo already exists."
    fi

    # ACE-Step v1 3.5B — used by the uploaded ace_step_music_generation.json workflow
    ACE_STEP_V1="$COMFYUI_DIR/models/checkpoints/ace_step_v1_3.5b.safetensors"
    if [ ! -f "$ACE_STEP_V1" ]; then
        echo "Downloading ACE-Step v1 3.5B music generation model (~7 GB)..."
        wget --progress=bar:force:noscroll -O "$ACE_STEP_V1" \
            "https://huggingface.co/ACE-Step/ACE-Step/resolve/main/ace_step_v1_3.5b.safetensors?download=true"
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
        wget --progress=bar:force:noscroll -O "$MMAUDIO_MAIN" \
            "https://huggingface.co/Kijai/MMAudio_safetensors/resolve/main/mmaudio_large_44k_v2_fp16.safetensors?download=true"
    else
        echo "MMAudio main model already exists."
    fi

    MMAUDIO_SYNCH="$COMFYUI_DIR/models/mmaudio/mmaudio_synchformer_fp16.safetensors"
    if [ ! -f "$MMAUDIO_SYNCH" ]; then
        echo "Downloading MMAudio synchformer fp16..."
        wget --progress=bar:force:noscroll -O "$MMAUDIO_SYNCH" \
            "https://huggingface.co/Kijai/MMAudio_safetensors/resolve/main/mmaudio_synchformer_fp16.safetensors?download=true"
    else
        echo "MMAudio synchformer already exists."
    fi

    MMAUDIO_VAE="$COMFYUI_DIR/models/mmaudio/mmaudio_vae_44k_fp16.safetensors"
    if [ ! -f "$MMAUDIO_VAE" ]; then
        echo "Downloading MMAudio VAE fp16..."
        wget --progress=bar:force:noscroll -O "$MMAUDIO_VAE" \
            "https://huggingface.co/Kijai/MMAudio_safetensors/resolve/main/mmaudio_vae_44k_fp16.safetensors?download=true"
    else
        echo "MMAudio VAE already exists."
    fi

    MMAUDIO_CLIP="$COMFYUI_DIR/models/mmaudio/apple_DFN5B-CLIP-ViT-H-14-384_fp16.safetensors"
    if [ ! -f "$MMAUDIO_CLIP" ]; then
        echo "Downloading MMAudio Apple CLIP fp16..."
        wget --progress=bar:force:noscroll -O "$MMAUDIO_CLIP" \
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
        wget --progress=bar:force:noscroll -O "$RIFE" \
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
        wget --progress=bar:force:noscroll -O "$XLABS_REALISM" \
            "https://huggingface.co/XLabs-AI/flux-RealismLora/resolve/main/lora.safetensors?download=true"
    else
        echo "XLabs Realism LoRA already exists."
    fi

    # --- Shakker-Labs Add Details - enhances realism and natural skin, no trigger needed ---
    ADD_DETAILS="$FLUX_LORA_DIR/flux_dev_add_details.safetensors"
    if [ ! -f "$ADD_DETAILS" ]; then
        echo "Downloading Flux Add Details LoRA (natural skin, realism)..."
        wget --progress=bar:force:noscroll -O "$ADD_DETAILS" \
            "https://huggingface.co/Shakker-Labs/FLUX.1-dev-LoRA-add-details/resolve/main/FLUX-dev-lora-add_details.safetensors?download=true"
    else
        echo "Flux Add Details LoRA already exists."
    fi

    # --- Shakker-Labs AntiBlur - sharpens deep depth of field, great for portraits ---
    ANTI_BLUR="$FLUX_LORA_DIR/flux_dev_anti_blur.safetensors"
    if [ ! -f "$ANTI_BLUR" ]; then
        echo "Downloading Flux AntiBlur LoRA (sharpness, DoF)..."
        wget --progress=bar:force:noscroll -O "$ANTI_BLUR" \
            "https://huggingface.co/Shakker-Labs/FLUX.1-dev-LoRA-AntiBlur/resolve/main/FLUX-dev-lora-AntiBlur.safetensors?download=true"
    else
        echo "Flux AntiBlur LoRA already exists."
    fi

    # --- Alimama Turbo Alpha - 8-step speed LoRA for Flux Dev (official Alibaba) ---
    FLUX_TURBO="$FLUX_LORA_DIR/flux_turbo_alpha.safetensors"
    if [ ! -f "$FLUX_TURBO" ]; then
        echo "Downloading Flux Turbo Alpha LoRA (8-step speed)..."
        wget --progress=bar:force:noscroll -O "$FLUX_TURBO" \
            "https://huggingface.co/alimama-creative/FLUX.1-Turbo-Alpha/resolve/main/diffusion_pytorch_model.safetensors?download=true"
    else
        echo "Flux Turbo Alpha LoRA already exists."
    fi

    # --- ByteDance Hyper-SD 8-step LoRA - best quality/speed balance for Flux Dev ---
    HYPER_SD="$FLUX_LORA_DIR/hyper_flux_dev_8step.safetensors"
    if [ ! -f "$HYPER_SD" ]; then
        echo "Downloading ByteDance Hyper-SD 8-step LoRA..."
        wget --progress=bar:force:noscroll -O "$HYPER_SD" \
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
        wget --progress=bar:force:noscroll -O "$DISTILL_4" \
            "https://huggingface.co/alibaba-pai/Z-Image-Fun-Lora-Distill/resolve/main/Z-Image-Fun-Lora-Distill-4-Steps-2603.safetensors?download=true"
    else
        echo "Z-Image Distill 4-step already exists."
    fi

    # --- Official Alibaba-PAI Distill 8-step LoRA (balanced speed/quality) ---
    DISTILL_8="$LORA_DIR/Z-Image-Fun-Lora-Distill-8-Steps-2603.safetensors"
    if [ ! -f "$DISTILL_8" ]; then
        echo "Downloading Z-Image Distill 8-step LoRA..."
        wget --progress=bar:force:noscroll -O "$DISTILL_8" \
            "https://huggingface.co/alibaba-pai/Z-Image-Fun-Lora-Distill/resolve/main/Z-Image-Fun-Lora-Distill-8-Steps-2603.safetensors?download=true"
    else
        echo "Z-Image Distill 8-step already exists."
    fi

    # --- Flow-DPO v1 - improves lighting, color fidelity, realism (170MB) ---
    FLOW_DPO="$LORA_DIR/zit_fdpo_v1.safetensors"
    if [ ! -f "$FLOW_DPO" ]; then
        echo "Downloading Z-Image Flow-DPO LoRA (lighting & realism)..."
        wget --progress=bar:force:noscroll -O "$FLOW_DPO" \
            "https://huggingface.co/F16/z-image-turbo-flow-dpo/resolve/main/zit_fdpo_v1.safetensors?download=true"
    else
        echo "Z-Image Flow-DPO already exists."
    fi

    # --- SDA v1 - diversity recovery, reduces repetitive outputs (170MB) ---
    SDA="$LORA_DIR/zit_sda_v1.safetensors"
    if [ ! -f "$SDA" ]; then
        echo "Downloading Z-Image SDA LoRA (output diversity)..."
        wget --progress=bar:force:noscroll -O "$SDA" \
            "https://huggingface.co/F16/z-image-turbo-sda/resolve/main/zit_sda_v1.safetensors?download=true"
    else
        echo "Z-Image SDA already exists."
    fi

    # --- Realistic Skin Texture Style v3 - detailed skin pores (supports ZIB) ---
    SKIN_TEXTURE="$LORA_DIR/skin_texture_style_v3.safetensors"
    if [ ! -f "$SKIN_TEXTURE" ]; then
        echo "Downloading Realistic Skin Texture LoRA..."
        SKIN_URL="https://civitai.com/api/download/models/691191?type=Model&format=SafeTensor"
        [ -n "$CIVITAI_TOKEN" ] && SKIN_URL="${SKIN_URL}&token=${CIVITAI_TOKEN}"
        wget --progress=bar:force:noscroll -O "$SKIN_TEXTURE" "$SKIN_URL"
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
        wget --progress=bar:force:noscroll -O "$WAN22_I2V_HIGH" \
            "https://huggingface.co/Comfy-Org/Wan_2.2_ComfyUI_Repackaged/resolve/main/split_files/diffusion_models/wan2.2_i2v_high_noise_14B_fp8_scaled.safetensors?download=true"
    else
        echo "Wan2.2 I2V high noise already exists."
    fi

    # --- Wan2.2 I2V low noise fp8 (~14.3 GB) ---
    WAN22_I2V_LOW="$DIFFUSION_MODELS_DIR/wan2.2_i2v_low_noise_14B_fp8_scaled.safetensors"
    if [ ! -f "$WAN22_I2V_LOW" ]; then
        echo "Downloading Wan2.2 I2V low noise fp8 (~14.3 GB)..."
        wget --progress=bar:force:noscroll -O "$WAN22_I2V_LOW" \
            "https://huggingface.co/Comfy-Org/Wan_2.2_ComfyUI_Repackaged/resolve/main/split_files/diffusion_models/wan2.2_i2v_low_noise_14B_fp8_scaled.safetensors?download=true"
    else
        echo "Wan2.2 I2V low noise already exists."
    fi

    # --- Wan2.2 T2V high noise fp8 (~14.3 GB) - also used for T2I ---
    WAN22_T2V_HIGH="$DIFFUSION_MODELS_DIR/wan2.2_t2v_high_noise_14B_fp8_scaled.safetensors"
    if [ ! -f "$WAN22_T2V_HIGH" ]; then
        echo "Downloading Wan2.2 T2V high noise fp8 (~14.3 GB)..."
        wget --progress=bar:force:noscroll -O "$WAN22_T2V_HIGH" \
            "https://huggingface.co/Comfy-Org/Wan_2.2_ComfyUI_Repackaged/resolve/main/split_files/diffusion_models/wan2.2_t2v_high_noise_14B_fp8_scaled.safetensors?download=true"
    else
        echo "Wan2.2 T2V high noise already exists."
    fi

    # --- Wan2.2 T2V low noise fp8 (~14.3 GB) - also used for T2I ---
    WAN22_T2V_LOW="$DIFFUSION_MODELS_DIR/wan2.2_t2v_low_noise_14B_fp8_scaled.safetensors"
    if [ ! -f "$WAN22_T2V_LOW" ]; then
        echo "Downloading Wan2.2 T2V low noise fp8 (~14.3 GB)..."
        wget --progress=bar:force:noscroll -O "$WAN22_T2V_LOW" \
            "https://huggingface.co/Comfy-Org/Wan_2.2_ComfyUI_Repackaged/resolve/main/split_files/diffusion_models/wan2.2_t2v_low_noise_14B_fp8_scaled.safetensors?download=true"
    else
        echo "Wan2.2 T2V low noise already exists."
    fi

    # --- Wan2.2 VAE (1.41 GB - improved over 2.1 VAE) ---
    WAN22_VAE="$COMFYUI_DIR/models/vae/wan2.2_vae.safetensors"
    if [ ! -f "$WAN22_VAE" ]; then
        echo "Downloading Wan2.2 VAE (1.41 GB)..."
        wget --progress=bar:force:noscroll -O "$WAN22_VAE" \
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
        wget --progress=bar:force:noscroll \
            -O "$ZIMAGE_TURBO_PATH" \
            "https://huggingface.co/Comfy-Org/z_image_turbo/resolve/main/split_files/diffusion_models/z_image_turbo_bf16.safetensors?download=true"
    else
        echo "Z-Image Turbo already exists."
    fi

    # --- Z-Image Base bf16 (better for Distill LoRAs and training) ---
    ZIMAGE_DIFFUSION_PATH="$DIFFUSION_MODELS_DIR/z_image_bf16.safetensors"
    if [ ! -f "$ZIMAGE_DIFFUSION_PATH" ]; then
        echo "Downloading z-image Base bf16 diffusion model..."
        wget --progress=bar:force:noscroll \
            -O "$ZIMAGE_DIFFUSION_PATH" \
            "https://huggingface.co/Comfy-Org/z_image/resolve/main/split_files/diffusion_models/z_image_bf16.safetensors?download=true"
    else
        echo "z-image Base diffusion model already exists."
    fi

    ZIMAGE_TEXT_ENCODER_PATH="$TEXT_ENCODERS_DIR/qwen_3_4b.safetensors"
    if [ ! -f "$ZIMAGE_TEXT_ENCODER_PATH" ]; then
        echo "Downloading z-image text encoder (Qwen 3 4B)..."
        wget --progress=bar:force:noscroll \
            -O "$ZIMAGE_TEXT_ENCODER_PATH" \
            "https://huggingface.co/Comfy-Org/z_image/resolve/main/split_files/text_encoders/qwen_3_4b.safetensors?download=true"
    else
        echo "z-image text encoder already exists."
    fi

    ZIMAGE_VAE_PATH="$VAE_DIR/ae.safetensors"
    if [ ! -f "$ZIMAGE_VAE_PATH" ]; then
        echo "Downloading z-image VAE..."
        wget --progress=bar:force:noscroll \
            -O "$ZIMAGE_VAE_PATH" \
            "https://huggingface.co/Comfy-Org/z_image/resolve/main/split_files/vae/ae.safetensors?download=true"
    else
        echo "z-image VAE already exists."
    fi
    
    echo "z-image model setup complete!"
}

# Function to install pre-configured custom nodes
install_custom_nodes() {
    echo "=========================================="
    echo "Installing pre-configured custom nodes..."
    echo "=========================================="
    cd "$COMFYUI_DIR/custom_nodes"
    
    if [ ! -d "ComfyUI-Manager" ]; then
        echo "Installing ComfyUI-Manager..."
        git clone https://github.com/ltdrdata/ComfyUI-Manager.git
        cd ComfyUI-Manager
        [ -f "requirements.txt" ] && pip install --no-cache-dir -r requirements.txt
        cd ..
    fi
    
    if [ ! -d "ComfyUI-KJNodes" ]; then
        echo "Installing ComfyUI-KJNodes..."
        git clone https://github.com/kijai/ComfyUI-KJNodes.git
        cd ComfyUI-KJNodes
        [ -f "requirements.txt" ] && pip install --no-cache-dir -r requirements.txt
        cd ..
    fi
    
    if [ ! -d "Civicomfy" ]; then
        echo "Installing Civicomfy..."
        git clone https://github.com/MoonGoblinDev/Civicomfy.git
        cd Civicomfy
        [ -f "requirements.txt" ] && pip install --no-cache-dir -r requirements.txt
        cd ..
    fi

    # Install ComfyUI-MMAudio (video-to-audio synthesis)
    if [ ! -d "ComfyUI-MMAudio" ]; then
        echo "Installing ComfyUI-MMAudio..."
        git clone https://github.com/kijai/ComfyUI-MMAudio.git
        cd ComfyUI-MMAudio
        [ -f "requirements.txt" ] && pip install --no-cache-dir -r requirements.txt
        cd ..
    fi

    # Install ComfyUI-Frame-Interpolation (RIFE video FPS doubling)
    if [ ! -d "ComfyUI-Frame-Interpolation" ]; then
        echo "Installing ComfyUI-Frame-Interpolation..."
        git clone https://github.com/Fannovel16/ComfyUI-Frame-Interpolation.git
        cd ComfyUI-Frame-Interpolation
        [ -f "requirements.txt" ] && pip install --no-cache-dir -r requirements.txt
        cd ..
    fi

    # Install ComfyUI-Chatterbox (TTS + voice cloning - auto-downloads its models)
    if [ ! -d "ComfyUI-Chatterbox" ]; then
        echo "Installing ComfyUI-Chatterbox TTS..."
        git clone https://github.com/wildminder/ComfyUI-Chatterbox.git
        cd ComfyUI-Chatterbox
        [ -f "requirements.txt" ] && pip install --no-cache-dir -r requirements.txt
        cd ..
    fi

    # Install ComfyUI-GGUF (required for GGUF model loading — InfiniteTalk + Z-Image GGUF workflows)
    if [ ! -d "ComfyUI-GGUF" ]; then
        echo "Installing ComfyUI-GGUF..."
        git clone https://github.com/city96/ComfyUI-GGUF.git
        cd ComfyUI-GGUF
        [ -f "requirements.txt" ] && pip install --no-cache-dir -r requirements.txt
        cd ..
    fi

    # Install rgthree-comfy (required for Z-Image ControlNet + InfiniteTalk workflows)
    if [ ! -d "rgthree-comfy" ]; then
        echo "Installing rgthree-comfy..."
        git clone https://github.com/rgthree/rgthree-comfy.git
        cd rgthree-comfy
        [ -f "requirements.txt" ] && pip install --no-cache-dir -r requirements.txt
        cd ..
    fi

    # Install ComfyUI-VideoHelperSuite (required for InfiniteTalk/MultiTalk video handling)
    if [ ! -d "ComfyUI-VideoHelperSuite" ]; then
        echo "Installing ComfyUI-VideoHelperSuite..."
        git clone https://github.com/Kosinkadink/ComfyUI-VideoHelperSuite.git
        cd ComfyUI-VideoHelperSuite
        [ -f "requirements.txt" ] && pip install --no-cache-dir -r requirements.txt
        cd ..
    fi

    # Install comfyui_controlnet_aux (required for ControlNet preprocessing — Juggernaut + Z-Image ControlNet workflows)
    if [ ! -d "comfyui_controlnet_aux" ]; then
        echo "Installing comfyui_controlnet_aux..."
        git clone https://github.com/Fannovel16/comfyui_controlnet_aux.git
        cd comfyui_controlnet_aux
        [ -f "requirements.txt" ] && pip install --no-cache-dir -r requirements.txt
        cd ..
    fi

    # Install ComfyUI-facerestore-cf (required for codeformer face restoration workflow)
    if [ ! -d "facerestore_cf" ]; then
        echo "Installing facerestore_cf..."
        git clone https://github.com/mav-rik/facerestore_cf.git
        cd facerestore_cf
        [ -f "requirements.txt" ] && pip install --no-cache-dir -r requirements.txt
        cd ..
    fi

    # Install ComfyUI-WanVideoWrapper (required for InfiniteTalk + MultiTalk)
    if [ ! -d "ComfyUI-WanVideoWrapper" ]; then
        echo "Installing ComfyUI-WanVideoWrapper (Kijai)..."
        git clone https://github.com/kijai/ComfyUI-WanVideoWrapper.git
        cd ComfyUI-WanVideoWrapper
        [ -f "requirements.txt" ] && pip install --no-cache-dir -r requirements.txt
        cd ..
    fi

    # Install ACE-Step ComfyUI node (official — for music generation)
    # NOTE: ACE-Step 1.5 is natively supported in ComfyUI core as of 2026.
    # The official ace-step/ACE-Step-ComfyUI node adds extra controls (cover,
    # repaint, remix modes) on top. Model lives in models/checkpoints/ which
    # matches the official Comfy-Org workflow templates we pull in setup_workflows.
    if [ ! -d "ACE-Step-ComfyUI" ]; then
        echo "Installing ACE-Step-ComfyUI (official music generation node)..."
        git clone https://github.com/ace-step/ACE-Step-ComfyUI.git
        cd ACE-Step-ComfyUI
        [ -f "requirements.txt" ] && pip install --no-cache-dir -r requirements.txt
        cd ..
    fi
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
        wget --progress=bar:force:noscroll -O "$ZIMAGE_AIO" \
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
        wget --progress=bar:force:noscroll -O "$ZIMAGE_KJ" \
            "https://huggingface.co/Kijai/Z-Image_comfy_fp8_scaled/resolve/main/z-image-turbo_fp8_scaled_e5m2_KJ.safetensors?download=true"
    else
        echo "Z-Image Turbo fp8 KJ already exists."
    fi

    # Qwen3 fp8 mixed text encoder (used by 5b workflow)
    QWEN_FP8="$COMFYUI_DIR/models/text_encoders/Huihui-Qwen3-4B-abliterated-v2_fp8mixed.safetensors"
    if [ ! -f "$QWEN_FP8" ]; then
        echo "Downloading Qwen3-4B fp8 mixed text encoder..."
        wget --progress=bar:force:noscroll -O "$QWEN_FP8" \
            "https://huggingface.co/silveroxides/Qwen3-4B-ComfyQuants-SingleFiles/resolve/main/Huihui-Qwen3-4B-abliterated-v2_fp8mixed.safetensors?download=true"
    else
        echo "Qwen3-4B fp8 mixed already exists."
    fi

    # -------------------------------------------------------
    # Z-IMAGE GGUF (used by 5c workflow)
    # -------------------------------------------------------
    ZIMAGE_GGUF="$DIFFUSION_MODELS_DIR/z-image/z-image-turbo-q4_k_s.gguf"
    if [ ! -f "$ZIMAGE_GGUF" ]; then
        echo "Downloading Z-Image Turbo Q4_K_S GGUF (~5 GB)..."
        wget --progress=bar:force:noscroll -O "$ZIMAGE_GGUF" \
            "https://huggingface.co/gguf-org/z-image-gguf/resolve/main/z-image-turbo-q4_k_s.gguf?download=true"
    else
        echo "Z-Image Turbo GGUF already exists."
    fi

    # Qwen GGUF text encoder (used by 5c workflow)
    QWEN_GGUF="$COMFYUI_DIR/models/text_encoders/qwen-4b-zimage-heretic-q8.gguf"
    if [ ! -f "$QWEN_GGUF" ]; then
        echo "Downloading Qwen GGUF text encoder (heretic q8)..."
        wget --progress=bar:force:noscroll -O "$QWEN_GGUF" \
            "https://huggingface.co/Lockout/qwen3-4b-heretic-zimage/resolve/main/qwen-4b-zimage-heretic-q8.gguf?download=true"
    else
        echo "Qwen GGUF text encoder already exists."
    fi

    # -------------------------------------------------------
    # CONTROLNET SD1.5 MODELS (used by Juggernaut ControlNet workflow)
    # -------------------------------------------------------
    mkdir -p "$COMFYUI_DIR/models/controlnet/sd15"
    CANNY_CN="$COMFYUI_DIR/models/controlnet/sd15/control_v11p_sd15_canny_fp16.safetensors"
    if [ ! -f "$CANNY_CN" ]; then
        echo "Downloading ControlNet SD1.5 Canny fp16..."
        wget --progress=bar:force:noscroll -O "$CANNY_CN" \
            "https://huggingface.co/comfyanonymous/ControlNet-v1-1_fp16_safetensors/resolve/main/control_v11p_sd15_canny_fp16.safetensors?download=true"
    else
        echo "ControlNet Canny SD1.5 already exists."
    fi

    DEPTH_CN="$COMFYUI_DIR/models/controlnet/sd15/control_v11f1p_sd15_depth_fp16.safetensors"
    if [ ! -f "$DEPTH_CN" ]; then
        echo "Downloading ControlNet SD1.5 Depth fp16..."
        wget --progress=bar:force:noscroll -O "$DEPTH_CN" \
            "https://huggingface.co/comfyanonymous/ControlNet-v1-1_fp16_safetensors/resolve/main/control_v11f1p_sd15_depth_fp16.safetensors?download=true"
    else
        echo "ControlNet Depth SD1.5 already exists."
    fi

    POSE_CN="$COMFYUI_DIR/models/controlnet/sd15/control_v11p_sd15_openpose_fp16.safetensors"
    if [ ! -f "$POSE_CN" ]; then
        echo "Downloading ControlNet SD1.5 OpenPose fp16..."
        wget --progress=bar:force:noscroll -O "$POSE_CN" \
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
        wget --progress=bar:force:noscroll -O "$ZIMAGE_CN" \
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
        wget --progress=bar:force:noscroll -O "$WAN21_I2V_GGUF" \
            "https://huggingface.co/city96/Wan2.1-I2V-14B-480P-gguf/resolve/main/wan2.1-i2v-14b-480p-Q4_0.gguf?download=true"
    else
        echo "Wan2.1 I2V GGUF already exists."
    fi

    # InfiniteTalk Single GGUF
    IT_SINGLE_GGUF="$DIFFUSION_MODELS_DIR/Wan2_1-InfiniteTalk_Single_Q8.gguf"
    if [ ! -f "$IT_SINGLE_GGUF" ]; then
        echo "Downloading InfiniteTalk Single Q8 GGUF..."
        wget --progress=bar:force:noscroll -O "$IT_SINGLE_GGUF" \
            "https://huggingface.co/Kijai/WanVideo_comfy_GGUF/resolve/main/InfiniteTalk/Wan2_1-InfiniteTalk_Single_Q8.gguf?download=true"
    else
        echo "InfiniteTalk Single GGUF already exists."
    fi

    # InfiniteTalk Multi GGUF
    IT_MULTI_GGUF="$DIFFUSION_MODELS_DIR/Wan2_1-InfiniteTalk_Multi_Q8.gguf"
    if [ ! -f "$IT_MULTI_GGUF" ]; then
        echo "Downloading InfiniteTalk Multi Q8 GGUF..."
        wget --progress=bar:force:noscroll -O "$IT_MULTI_GGUF" \
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
        wget --progress=bar:force:noscroll -O "$WAV2VEC_SF" \
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
        wget --progress=bar:force:noscroll -O "$UMT5_CLIP" \
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
        wget --progress=bar:force:noscroll -O "$WAN22_LORA_LOW" \
            "https://huggingface.co/Comfy-Org/Wan_2.2_ComfyUI_Repackaged/resolve/main/split_files/loras/wan2.2_i2v_lightx2v_4steps_lora_v1_low_noise.safetensors?download=true"
    else
        echo "Wan2.2 LightX2V low noise LoRA already exists."
    fi

    WAN22_LORA_HIGH="$COMFYUI_DIR/models/loras/wan2.2_i2v_lightx2v_4steps_lora_v1_high_noise.safetensors"
    if [ ! -f "$WAN22_LORA_HIGH" ]; then
        echo "Downloading Wan2.2 LightX2V high noise LoRA..."
        wget --progress=bar:force:noscroll -O "$WAN22_LORA_HIGH" \
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
        wget --progress=bar:force:noscroll -O "$CAKE_LORA" \
            "https://huggingface.co/mnemic/CakeStyle-SD1.5-LoRA/resolve/main/CakeStyle.safetensors?download=true"
    else
        echo "CakeStyle LoRA already exists."
    fi

    echo "=========================================="
    echo "Workflow-required models complete!"
    echo "=========================================="
}

    cd "$COMFYUI_DIR/custom_nodes"

    echo "Checking for custom node updates..."
    for node_dir in */; do
        if [ -d "$node_dir" ]; then
            echo "--- Checking node: $node_dir ---"
            cd "$node_dir"
            if [ -d ".git" ]; then
                git pull || echo "WARNING: Could not update $node_dir."
            fi
            [ -f "requirements.txt" ] && pip install --no-cache-dir -r requirements.txt
            [ -f "install.py" ] && python install.py
            cd ..
        fi
    done
    
    cd "$COMFYUI_DIR"
}

# Function to start ComfyUI
start_comfyui() {
    cd "$COMFYUI_DIR"

    echo "Updating custom nodes..."
    update_custom_nodes

    FIXED_ARGS="--listen 0.0.0.0 --port 8188"
    CUSTOM_ARGS=""

    if [ -f "$ARGS_FILE" ]; then
        CUSTOM_ARGS=$(grep -v '^#' "$ARGS_FILE" | tr '\n' ' ')
    else
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

    echo "=========================================="
    echo "Starting ComfyUI on port 8188"
    echo "PyTorch: $(python -c 'import torch; print(torch.__version__)')"
    echo "SageAttention: $(python -c 'import sageattention; print(sageattention.__version__)' 2>/dev/null || echo 'not found')"
    echo "sm_120 support: $(python -c 'import torch; print(str(\"sm_120\" in torch.cuda.get_arch_list()))')"
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

    cd "$SAGE_DIR"
    # Pull latest in case repo already exists from previous attempt
    git pull 2>/dev/null || true

    # Install with TORCH_CUDA_ARCH_LIST set for sm_120
    TORCH_CUDA_ARCH_LIST="8.0;8.6;8.9;9.0;12.0" \
        pip install --no-cache-dir -e . --no-build-isolation

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
echo "RunPod ComfyUI - RTX 5090 / Blackwell"
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
install_sageattention
install_custom_nodes
setup_workflows
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
