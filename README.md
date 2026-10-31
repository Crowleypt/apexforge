# ApexForge

**A ready-to-run ComfyUI pod for RunPod, by [Alex Harte](https://alexanderharte.com).**

Image, video, talking-avatar, music and upscaling workflows, with every model they need downloaded to your network volume on first boot. Built for the RTX 5090 (Blackwell) with CUDA 12.8, PyTorch 2.10 and SageAttention.

**Deploy on RunPod:** https://runpod.io/console/deploy?template=dmguns4e84

Walkthroughs and guides: https://alexanderharte.com

## What's included

| Folder | Workflows |
|---|---|
| 01 - Image Generation | Juggernaut Reborn (SD1.5) T2I / I2I / LoRA / ControlNet, FLUX.1 Dev, Z-Image Turbo (AIO, FP8, GGUF, LoRA, ControlNet), Z-Image Base |
| 02 - Image Editing | FLUX.1 Kontext Dev |
| 03 - Video Generation | Wan 2.2 I2V, Wan 2.2 T2V, Wan 2.2 I2V 4-step, Wan 2.1 I2V |
| 04 - Talking Avatars | InfiniteTalk (single), MultiTalk |
| 05 - Audio | ACE-Step 1.5 music, MMAudio video-to-sound |
| 06 - Post Processing | Upscale (simple, ESRGAN), Z-Image AI upscaler, CodeFormer face restore, RIFE frame interpolation |

Custom nodes: ComfyUI-Manager (built in), KJNodes, Civicomfy, MMAudio, Frame-Interpolation, Chatterbox, GGUF, rgthree, VideoHelperSuite, controlnet_aux, facerestore_cf, WanVideoWrapper, ACE-Step, TiledDiffusion.

## Setup

1. Create a **network volume** (models need several hundred GB) and attach it at `/comfyui`.
2. Deploy the template. First boot downloads all models (hundreds of GB) and builds SageAttention, so it can take an hour or more. Later boots reuse the volume and start in a few minutes.
3. Open **port 8188** for ComfyUI. Workflows are in the sidebar under the folders above.

## Environment variables

| Variable | Default | What it does |
|---|---|---|
| `JUPYTER_PASSWORD` | set by RunPod | Password for JupyterLab on port 8888. RunPod sets it when "Start Jupyter Notebook" is ticked. Without it, JupyterLab does not start. |
| `JUPYTER_DISABLE_AUTH` | `false` | `true` runs JupyterLab with no password. Not recommended: anyone with the URL gets a root shell. |
| `CIVITAI_TOKEN` | empty | Civitai API key, needed for the Skin Texture LoRA. Store it as a RunPod Secret and set the value to `{{ RUNPOD_SECRET_civitai }}`. |
| `APEXFORGE_UNCENSORED_ENCODERS` | `false` | `true` also downloads the community "abliterated" / "heretic" Qwen3-4B text encoders. Select them in the text encoder loader of the Z-Image workflows. |
| `APEXFORGE_TRACK_LATEST` | `false` | `true` pulls the newest ComfyUI and custom nodes on every boot instead of the tested versions. Things may break. |

Extra ComfyUI launch arguments go in `/comfyui/comfyui_args.txt`, one per line.

## Security notes

- ComfyUI on port 8188 has no login. Anyone with your pod's proxy URL can use it, so don't share the URL or show it in screenshots. Stop the pod when you're not using it.
- JupyterLab only runs with a password (see above).
- ComfyUI, the custom nodes and SageAttention are pinned to tested versions, so a boot never pulls untested code unless you opt in.
- ComfyUI-Manager is kept at security level `normal`.

## Versions

Each release is tagged (`v1.1.0`, …) on GitHub and Docker Hub (`alexharte/apexforge:v1.1.0`). `:latest` follows the newest release.

### v1.1.0
- JupyterLab now requires a password (RunPod's standard pattern).
- ComfyUI pinned to v0.43.0; custom nodes and SageAttention pinned; no more updates on every boot.
- ComfyUI-Manager moved to the built-in version (`--enable-manager`).
- Civitai key sent as a request header and supported via RunPod Secrets.
- Z-Image workflows use the official Qwen3-4B text encoders; uncensored encoders are opt-in.
- Workflows downloaded from the matching release tag.

## Credits

ApexForge is built and maintained by Alex Harte — https://alexanderharte.com. Models and custom nodes belong to their respective authors; check each model's license before commercial use.
