# ApexForge Dockerfile
# RTX 5090 / Blackwell (sm_120) compatible
# PyTorch 2.11.0 stable + CUDA 12.8 + SageAttention

FROM nvidia/cuda:12.8.1-devel-ubuntu22.04

# ── Environment ────────────────────────────────────────────────
ENV DEBIAN_FRONTEND=noninteractive
ENV PYTHONUNBUFFERED=1
ENV CUDA_HOME=/usr/local/cuda
ENV PATH=${CUDA_HOME}/bin:${PATH}
ENV LD_LIBRARY_PATH=${CUDA_HOME}/lib64:${LD_LIBRARY_PATH}
# sm_120 = RTX 5090 (Blackwell). Keep older arches for compatibility.
ENV TORCH_CUDA_ARCH_LIST="8.0;8.6;8.9;9.0;12.0"

WORKDIR /app

# ── System packages ────────────────────────────────────────────
RUN apt-get update && apt-get install -y \
    git \
    wget \
    curl \
    vim \
    nano \
    python3.10 \
    python3.10-venv \
    python3.10-dev \
    python3-pip \
    build-essential \
    ffmpeg \
    libgl1 \
    libglib2.0-0 \
    && rm -rf /var/lib/apt/lists/*

# ── Python defaults ────────────────────────────────────────────
RUN update-alternatives --install /usr/bin/python  python  /usr/bin/python3.10 1 && \
    update-alternatives --install /usr/bin/python3 python3 /usr/bin/python3.10 1 && \
    update-alternatives --install /usr/bin/pip     pip     /usr/bin/pip3        1

RUN pip install --no-cache-dir --upgrade pip

# ── PyTorch 2.11.0 stable with CUDA 12.8 (sm_120 native support) ──
# 2.7.0 was the first stable release to support Blackwell.
# 2.11.0 is the current recommended stable as of April 2026.
# NOTE: Do NOT use --pre (nightly) — nightly breaks randomly and
#       gives paying customers a bad experience.
RUN pip install --no-cache-dir \
    torch==2.10.0 \
    torchvision==00.25.0 \
    torchaudio==2.10.0 \
    --index-url https://download.pytorch.org/whl/cu128

# ── JupyterLab ─────────────────────────────────────────────────
RUN pip install --no-cache-dir \
    jupyterlab \
    ipywidgets \
    jupyter-archive

# ── Startup script ─────────────────────────────────────────────
COPY start_final.sh /app/start.sh
RUN chmod +x /app/start.sh

# ── Ports ──────────────────────────────────────────────────────
# 8188 = ComfyUI
# 8888 = JupyterLab
EXPOSE 8188 8888

CMD ["/app/start.sh"]
