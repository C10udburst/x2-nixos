# `modules/npu` — AMD Ryzen AI NPU inference domain

Second, **independent** resource domain next to the RDNA 3.5 iGPU:

| domain | device | units | state file |
| --- | --- | --- | --- |
| GPU | `/dev/dri/renderD128` | `gufo-*`, `llama-*`, `kyojin-*`, `immich-ml`, `comfyui` | `/run/model-lock/active_gpu` |
| NPU | `/dev/accel/accel0` | `npu-*` | `/run/model-lock/active_npu` |

Rule 1 is enforced **per domain**: one GPU workload **and** one NPU workload may be resident at
the same time, and unloading one never evicts the other. `stop-other-workloads <device>
<target-unit>` takes the device explicitly for exactly that reason — a mistyped target can
never evict across domains.

## Layout

```
default.nix              services.npu: user, accel device, base environment
openflow.nix             services.npu.openflowlm: engine, kernel set, model store, power mode
openflow-kernels.nix     prebuilt xclbin set taken from the flake source (no kernel toolchain)
mkOpenFlow.nix           catalogue tag -> one `oflm serve` process + one systemd unit
README.md                this file
packages/ryzen-ai.nix    AMD's proprietary ONNX stack, for the legacy runners below
packages/amdxdna-driver.nix  AMD's out-of-tree NPU driver (services.npu.xrtDriver)
packages/strip-execstack.py  clears PT_GNU_STACK X (kernel >= 6.6 rejects it on dlopen)
runners/                 legacy Python runners (onnxruntime-genai, VitisAI EP) — unused by the registry
```

Weights are host state under `services.npu.openflowlm.modelStore` (`/srv/models/oflm`) and the
operator installs them. Nothing in this repo downloads a model.

## The engine: OpenFlowLM

[OpenFlowLM-Next](https://github.com/Atomic-Germ/OpenFlowLM-Next) is an open fork of
ROCm/FastFlowLM for XDNA 2. It is a C++ engine whose HTTP server already speaks OpenAI, so the
NPU domain gets the same shape as every other domain: **one process, one model, one port**.

```nix
# models/npu.nix
"llama3.2:1b"      = mkOpenFlow { modelId = "llama3.2:1b";      port = 8083; };
"llama3.2:3b"      = mkOpenFlow { modelId = "llama3.2:3b";      port = 8084; };
"whisper-v3:turbo" = mkOpenFlow { modelId = "whisper-v3:turbo"; port = 8087; kind = "asr"; };
```

Decisions worth knowing before touching this:

* **The registry key is the engine's tag** (`llama3.2:1b`, not `llama-3.2-1b-npu`). The Rust
  router resolves a model and forwards the body **verbatim** — there is no body rewrite
  anywhere in the pipeline, so `remappedModel` cannot paper over a key the backend does not
  know. Ollama-style tags keep `/v1/models`, the dashboard and the wire format in one name.
* **The catalogue is read at eval time.** `mkOpenFlow` opens
  `<openflowlm source>/src/model_list.json` to get the on-disk directory name, the declared
  context window and the description. An unknown tag is a Nix eval error that lists the valid
  ones (chat tags and ASR tags separately), not a unit that fails at 03:00.
* **Kernels are not built here.** `openflow-kernels.nix` copies the precompiled AMD xclbins
  that ship in the repository into `<pkg>/share/oflm/xclbins`, which is the first path the
  engine searches. The alternative — the flake's own `openflowlm-open-kernels` — drags in
  mlir-aie, Peano and the IRON venv, and its BERT sets need `/dev/accel*` at build time
  (`__noChroot`), which a sandboxed `nixos-rebuild` refuses. `.#openflowlm-full` builds those
  on purpose, on a host, when someone wants open kernels.
* **The input is pinned as a GitHub archive URL.** The repository has an uninitialized gitlink
  (`third_party/tokenizers-cpp`) and the git fetcher normalizes that empty directory
  differently across nix patch releases: the same rev produced two different NAR hashes on the
  two machines used here, so a `github:` pin resolved on one host would not download on the
  other. The archive hashes identically everywhere and the engine never needs that submodule
  (its `package.nix` deletes `third_party/tokenizers-cpp` and fetches its own).
* **`nixpkgs` does not follow.** The engine builds against its own pin and pulls nix-amd-ai's
  XRT + amdxdna plugin through it; following ours would re-hash that closure and lose every
  prebuilt artifact the upstream cache carries.
* **Health check is `/api/version`.** The runners expose no `/health`, and the engine has no
  `/v1/models`-style readiness either; `modules/switcher/src/http.rs` already treats
  `/api/version` as healthy. Note that the engine's own `/v1/models` answers with the *whole
  catalogue*, not the loaded model — the gateway's `/v1/models` is generated from
  `services.models` and is what the dashboard reads.
* **`SIGINT`, not `SIGTERM`.** `oflm` tears down its server thread on Ctrl-C; SIGTERM can cut
  mid-context and leave the AIE partition to the driver's cleanup.

## Operation

```bash
# weights, as the service user, into the store the units read
sudo -u npu env OFLM_MODEL_PATH=/srv/models/oflm HOME=/var/lib/oflm \
    oflm pull llama3.2:1b
sudo -u npu env OFLM_MODEL_PATH=/srv/models/oflm HOME=/var/lib/oflm \
    oflm pull whisper-v3:turbo

# what is available, and what is installed (⏬ marks the missing ones)
oflm list
```

`HOME` matters: `oflm` keeps its registry and `settings.json` there, and systemd hands a
`User=` service no HOME at all unless the unit sets one — which `mkOpenFlow` does
(`/var/lib/oflm`, also `StateDirectory=`).

Talking to the two services directly, bypassing the gateway:

```bash
curl -s http://127.0.0.1:8083/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"llama3.2:1b","messages":[{"role":"user","content":"hi"}]}'

# ASR: the `model` field is REQUIRED by the engine, 400 without it
curl -s http://127.0.0.1:8087/v1/audio/transcriptions \
  -F model=whisper-v3:turbo -F file=@sample.wav
```

## Measured on this host

Engine build: **240 s** on 12 cores with `https://nix-amd-ai.cachix.org` configured (XRT,
boost, the Rust tokenizer crate all substitute; only the engine itself compiles).

`whisper-v3:turbo` alone, `oflm serve --asr 1 --asrmodel whisper-v3:turbo`, **no chat model
loaded** — the startup log loads nothing but `Whisper-V3-Turbo-NPU2`, and the process holds
**~1 GB RSS**:

```json
{"model":"whisper-v3:turbo","text":" And so, my fellow Americans, ask not what your country can do for you ask what you can do for your country."}
```

11 s of audio in **2.4 s** wall, cold start to serving in ~20 s.

`llama3.2:1b`: **61.9 tok/s decode**, 91.8 tok/s prefill, SSE chunks stream correctly.

## Rejected alternatives

* **Whisper through AMD's `ryzen-ai` ONNX wheels.** Two models deep in the same process —
  the ONNX Runtime *plus* a pipeline wrapper — ~4 GB RSS to transcribe, and no OpenAI route:
  it is a Python API, so a runner has to be written and maintained around it. `oflm` already
  ships the route.
* **FastFlowLM (upstream).** Same build cost, same closed kernels, but no standalone
  `--asr 1` server mode; Whisper there rides along with a chat model.
* **ROCm/llama.cpp for Whisper.** CPU-only for this model class on this box, which is exactly
  the workload the NPU exists to take off the cores.

## Legacy: the ONNX stack (`packages/ryzen-ai.nix`, `runners/`)

`mkNpuModel` still works and still honours the model contract; `models/npu.nix` simply no
longer calls it. It is the path for a **closed** AMD artifact that `oflm` cannot host — the
VitisAI EP is registered by `packages/ryzen-ai.nix` and asserted in its `installCheckPhase`.
Two facts from that work still stand and still bind anything NPU-side:

1. **LLM/genai needs AMD's out-of-tree driver** (`services.npu.xrtDriver`, built by
   `packages/amdxdna-driver.nix`). Mainline's in-tree `amdxdna` is 0.10.0-era: no
   `amdxdna_ubuf_get_pages`, no `amdxdna_dpt.c`, and every LLM session died in
   `DRM_IOCTL_AMDXDNA_CREATE_BO failed (err=-14)`. `nix flake update` cannot close that gap;
   enabling the option needs a reboot. The engine here runs on the same driver stack the
   deployment already carries.
2. **AMD's EmbeddingGemma NPU artifact is unrunnable** with any 1.8/1.9 runtime:
   `com.ryzenai:CastAvx` is referenced by the only published artifact and registered by none
   ([amd/RyzenAI-SW#387](https://github.com/amd/RyzenAI-SW/issues/387)). The registry entry
   stays commented out with that reason.
