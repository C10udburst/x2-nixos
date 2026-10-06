# GMKtec EVO-X2 • Bare-Minimal NixOS AI Inference Setup

Target Hardware: **GMKtec EVO-X2 Mini PC**
- **CPU**: AMD Ryzen AI Max+ 395 (Zen 5, 16 Cores / 32 Threads)
- **GPU / APU**: AMD Radeon 8060S (40 CUs RDNA 3.5, `gfx1151`)
- **Memory**: 128 GB Unified LPDDR5X-8533 (Bandwidth ~273 GB/s)
- **Role**: Dedicated headless AI LLM inference node

---

## Architecture Overview

```
                      ┌──────────────────────────────────────┐
                      │    Client Requests (Port 8080)       │
                      │  - Web Browser (Dashboard UI)        │
                      │  - OpenAI API Clients (Cursor, etc.) │
                      │  - Tailscale / SSH Clients           │
                      └──────────────────┬───────────────────┘
                                         │
                   ┌─────────────────────▼─────────────────────┐
                   │    Nginx (Bare-Minimal Reverse Proxy)     │
                   │    Footprint: ~3 MB RAM                   │
                   │    - GET / -> Static dashboard.html       │
                   │    - /v1/*, /api/* -> FastCGI Pass        │
                   └─────────────────────┬─────────────────────┘
                                         │ FastCGI (Unix Socket)
                   ┌─────────────────────▼─────────────────────┐
                   │     fcgiwrap + switcher.py (Python)       │
                   │     Footprint: ~1 MB (Exits on idle)      │
                   │     - Reads request "model" parameter     │
                   │     - Auto-switches systemd units         │
                   │     - Streams SSE tokens (no buffering)   │
                   └─────────────────────┬─────────────────────┘
                                         │ Reverse Proxy (127.0.0.1:8081)
                   ┌─────────────────────▼─────────────────────┐
                   │   Gufo Container (Active Model Service)   │
                   │   podman run (ROCm /dev/kfd, /dev/dri)    │
                   │                                           │
                   │   [gufo-qwen3.8-flash-next.service]       │
                   │   (Only ONE model in VRAM at a time)      │
                   └───────────────────────────────────────────┘
```

---

## Key Features

1. **Bare-Minimal Footprint (< 250 MB Idle OS RAM)**:
   - Stripped headless system (`multi-user.target`): no X11, Wayland, sound/pipewire, bluetooth, or printing.
   - Documentation, man pages, and info caches completely disabled.
   - Journald runs in volatile RAM capped at **32 MB**, preventing disk/memory bloat.
   - CPU governor set to `performance` for instantaneous prompt prefill and token generation.

2. **AMD Strix Halo APU & 128 GB Unified Memory Tuning**:
   - `boot.kernelPackages = pkgs.linuxPackages_latest`: Modern kernel with full Strix Halo Zen 5 and RDNA 3.5 support.
   - `amdgpu.gttsize=114688`: Configures AMDGPU to allocate up to **112 GB** of the 128 GB unified system RAM as VRAM for ROCm/KFD.
   - `vm.max_map_count = 2147483642`: Permits memory-mapping massive multi-shard 70B+ GGUF files.
   - `vm.swappiness = 10` & `LimitMEMLOCK = infinity`: Locks model weights directly into physical memory.

3. **Gufo Inference Engine**:
   - Runs `ghcr.io/gufo-org/toolboxes/gufo-runtime:latest` via Podman with native `/dev/kfd` and `/dev/dri` access.
   - Auto-resolves multi-part shards (`model-00001-of-00004.gguf`) or directory structures.
   - Supports MTP (Multi-Token Prediction) speculative decoding and multimodal vision projectors (`mmproj`).

4. **Modular Systemd Model Services**:
   - Each model is declared in `models.nix` and automatically compiled into a dedicated systemd service (`gufo-<model>.service`).
   - Native systemd `conflicts` ensures that starting one model immediately and cleanly unloads any previously running model from memory.

5. **FastCGI Switcher Wrapper**:
   - Listens on port `8080` (public / Tailscale).
   - Inspects the `"model"` property in incoming `/v1/chat/completions` requests.
   - If the requested model is not currently running, it triggers a systemd switch, polls backend readiness, and proxies the stream.
   - Emits `X-Accel-Buffering: no` so Server-Sent Events (SSE) stream token-by-token with zero buffering.

6. **Client-Side Rendered Dashboard**:
   - Served directly at `http://<ip>:8080/`.
   - All graphs, gauges, and DOM rendering occur inside the client browser to keep the EVO-X2's CPU and RAM completely dedicated to LLM inference.
   - Features real-time RAM (used / available), GPU VRAM / GTT allocations, GPU busy %, CPU load average, one-click model switcher, and an in-browser live token generation playground.

7. **Inspection & Access**:
   - Pre-installed CLI monitors: `nvtop` (AMD-capable GPU monitor), `amdgpu_top` (dedicated RDNA 3.5 monitor), `rocm-smi`, `btop`.
   - OpenSSH enabled with pre-configured public key authentication.
   - Tailscale VPN daemon enabled with trusted mesh firewall rules.

---

## Repository Structure

```
.
├── flake.nix                  # Flake entrypoint (evo-x2 configuration)
├── configuration.nix          # Base host configuration
├── hardware-configuration.nix # Bootloader, disks, and AMD APU hardware settings
├── models.nix                 # Declarative model definitions
└── modules/
    ├── gufo.nix               # Modular Gufo systemd services + FastCGI & Nginx
    ├── switcher.py            # FastCGI model switcher & reverse proxy script
    ├── dashboard.html         # Client-side rendered live dashboard
    ├── minimal.nix            # RAM minimization, sysctl, journald tuning, CLI tools
    ├── openssh.nix            # Hardened OpenSSH daemon
    └── tailscale.nix          # Tailscale mesh VPN
```

---

## Deployment Instructions

### 1. Model Storage Preparation
Ensure your model weights are placed in `/srv/models`. For example, for Qwen 3.8 Flash Next:
```bash
sudo mkdir -p /srv/models/qwen3.8-flash-next/UD-Q4_K_XL
sudo mkdir -p /srv/models/qwen3.8-flash-next/MTP

# Copy your model shards into the directory:
# /srv/models/qwen3.8-flash-next/UD-Q4_K_XL/*.gguf
# /srv/models/qwen3.8-flash-next/MTP/mtp-Qwen3.8-Flash-Next-shared-Q8_0.gguf
# /srv/models/qwen3.8-flash-next/mmproj-BF16.gguf
```

### 2. Adjusting Disk UUIDs
Inspect `hardware-configuration.nix` and ensure `fileSystems."/"` and `fileSystems."/boot"` match your partition labels or UUIDs (e.g., using `lsblk -f`).

### 3. Deploying with NixOS Rebuild
To evaluate and build the configuration on the GMKtec EVO-X2:
```bash
# Check configuration
nix flake check

# Build and activate
sudo nixos-rebuild switch --flake .#evo-x2
```

---

## Adding or Modifying Models

Edit `models.nix` to declare any number of models:

```nix
services.gufo.models."my-new-model" = {
  alias = "my-new-model";
  description = "Llama 3.3 70B Instruct Q4_K_M";
  modelPath = "llama-70b";           # Points to /srv/models/llama-70b (resolves first .gguf)
  context = 32768;
  sessions = 1;
  # Optional multimodal projector:
  # mmprojPath = "llama-70b/mmproj.gguf";
  # Optional speculative decoding:
  # speculative = "draft";
  # draftModelPath = "llama-70b/draft.gguf";
};
```

After modifying `models.nix`, run:
```bash
sudo nixos-rebuild switch --flake .#evo-x2
```
The new model will instantly appear in the web dashboard and in the OpenAI `/v1/models` endpoint.

---

## API & Usage Examples

### 1. Web Dashboard
Open in your browser:
```
http://<evo-x2-ip>:8080/
```
Or via your Tailscale node name:
```
http://evo-x2:8080/
```

### 2. OpenAI API Request (with Auto-Switching)
Send any OpenAI-compatible request. The switcher will automatically load the requested model if it is not already in memory:

```bash
curl http://localhost:8080/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "qwen3.8-flash-next",
    "messages": [
      {"role": "user", "content": "Explain unified memory architecture on AMD APUs."}
    ],
    "stream": true
  }'
```

### 3. List Available Models
```bash
curl http://localhost:8080/v1/models | jq .
```

### 4. Switch Model via API
```bash
curl -X POST http://localhost:8080/api/switch \
  -H "Content-Type: application/json" \
  -d '{"model": "qwen3.8-flash-next"}'
```

### 5. Free GPU Memory (Unload Active Model)
```bash
curl -X POST http://localhost:8080/api/stop
```

---

## Hardware Inspection CLI Commands

Over SSH or local terminal:

| Command | Purpose |
| :--- | :--- |
| `nvtop` | Real-time GPU utilization, VRAM usage, and engine activity graph |
| `amdgpu_top` | Dedicated AMD APU monitor for RDNA 3.5, showing GTT & VRAM allocations |
| `rocm-smi` | ROCm command-line management and compute unit telemetry |
| `btop` | CPU core load, per-core clocks, and unified system memory |
| `journalctl -u gufo-* -f` | Follow live model startup, shard loading, and inference logs |
