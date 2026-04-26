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

# --- Use system Python (has PyTorch 2.11.0 stable + SageAttention baked into image) ---
# No venv needed — everything is installed at the system level in the Docker image

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

install_sageattention() {
    if python -c "import sageattention" 2>/dev/null; then
        echo "SageAttention already installed."
        return
    fi
    echo "Installing SageAttention (requires GPU - first boot only)..."
    git clone https://github.com/thu-ml/SageAttention.git /comfyui/SageAttention
    cd /comfyui/SageAttention
    pip install --no-cache-dir -e . --no-build-isolation
    cd /
    echo "SageAttention installed."
}
# Function to download Juggernaut XL model
download_model() {
    echo "=========================================="
    echo "Checking for Juggernaut XIII model..."
    echo "=========================================="
    mkdir -p "$CHECKPOINTS_DIR"

    MODEL_PATH="$CHECKPOINTS_DIR/juggernautXIII_ragnarok.safetensors"
    if [ ! -f "$MODEL_PATH" ]; then
        echo "Downloading Juggernaut XIII: Ragnarok model (6.62 GB)..."
        JUGG_URL="https://civitai.com/api/download/models/1759168?type=Model&format=SafeTensor&size=full&fp=fp16"
        [ -n "$CIVITAI_TOKEN" ] && JUGG_URL="${JUGG_URL}&token=${CIVITAI_TOKEN}"
        curl -L -o "$MODEL_PATH" "$JUGG_URL"
        
        if [ -f "$MODEL_PATH" ]; then
            FILE_SIZE=$(stat -c%s "$MODEL_PATH" 2>/dev/null || echo 0)
            if [ "$FILE_SIZE" -lt 1000000 ]; then
                echo "ERROR: Juggernaut download too small — likely needs CIVITAI_TOKEN env var. Removing..."
                rm -f "$MODEL_PATH"
            else
                echo "Download complete! File size: $FILE_SIZE bytes"
            fi
        else
            echo "ERROR: Download failed."
        fi
    else
        echo "Juggernaut XIII model already exists."
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

# Function to download pre-built workflows into the user workflows folder
setup_workflows() {
    echo "=========================================="
    echo "Setting up pre-built workflows..."
    echo "=========================================="

    WORKFLOWS_DIR="$COMFYUI_DIR/user/default/workflows"
    mkdir -p "$WORKFLOWS_DIR"

    # -------------------------------------------------------
    # Clone official Comfy-Org workflow templates
    # This gives us official workflows for ALL our models:
    # Z-Image, FLUX Dev, FLUX Kontext, Wan2.1, Wan2.2,
    # InfiniteTalk, ACE-Step, MMAudio, and more
    # -------------------------------------------------------
    TEMPLATES_DIR="$WORKFLOWS_DIR/official_templates"
    if [ ! -d "$TEMPLATES_DIR/.git" ]; then
        echo "Cloning official ComfyUI workflow templates..."
        git clone --depth=1 \
            https://github.com/Comfy-Org/workflow_templates.git \
            "$TEMPLATES_DIR" || echo "WARNING: Could not clone workflow templates."
    else
        echo "Updating official workflow templates..."
        cd "$TEMPLATES_DIR"
        git pull || echo "WARNING: Could not update workflow templates."
        cd "$COMFYUI_DIR"
    fi

    # -------------------------------------------------------
    # Copy the actual JSON workflow files to the root workflows dir
    # so they show up directly in ComfyUI's workflow browser
    # -------------------------------------------------------
    if [ -d "$TEMPLATES_DIR/templates" ]; then
        echo "Copying workflow JSONs to workflow browser..."
        cp -n "$TEMPLATES_DIR/templates/"*.json "$WORKFLOWS_DIR/" 2>/dev/null || true
        echo "Workflows copied."
    fi

    echo "=========================================="
    echo "Workflows available in ComfyUI workflow browser!"
    echo "Key workflows included:"
    echo "  image_z_image_turbo.json       - Z-Image Turbo T2I"
    echo "  image_flux_1_dev.json          - FLUX Dev T2I"
    echo "  image_flux_1_kontext_dev.json  - FLUX Kontext image editing"
    echo "  video_wan2_2_14B_i2v.json      - Wan2.2 image-to-video"
    echo "  video_wan2_2_14B_t2v.json      - Wan2.2 text-to-video"
    echo "  audio_ace_step_1_5.json        - ACE-Step music generation"
    echo "  video_wan2_1_infinitetalk.json - InfiniteTalk talking video"
    echo "  ...and many more"
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
    ACE_STEP="$COMFYUI_DIR/models/checkpoints/ace_step_1.5_turbo_aio.safetensors"
    if [ ! -f "$ACE_STEP" ]; then
        echo "Downloading ACE-Step 1.5 Turbo music generation model (~7.7 GB)..."
        wget --progress=bar:force:noscroll -O "$ACE_STEP" \
            "https://huggingface.co/Comfy-Org/ace_step_1.5_ComfyUI_files/resolve/main/checkpoints/ace_step_1.5_turbo_aio.safetensors?download=true"
    else
        echo "ACE-Step 1.5 already exists."
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

# Function to update custom nodes
update_custom_nodes() {
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
        echo "--use-sage-attention" >> "$ARGS_FILE"
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
echo "=========================================="
echo "RunPod ComfyUI - RTX 5090 / Blackwell"
echo "CUDA 12.8 + PyTorch 2.11.0 stable + SageAttention"
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
start_comfyui
