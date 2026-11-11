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
default.nix              services.npu: user, device, runtime environment, stack self-check
mkNpuModel.nix           per-model registry entry -> one runner process + one systemd unit
packages/ryzen-ai.nix    the AMD runtime as derivations (fetched by hash, fixed, smoke-tested)
packages/amdxdna-driver.nix  AMD's out-of-tree NPU driver from XRT, for kernels whose
                             in-tree amdxdna lags the userspace (services.npu.xrtDriver)
packages/strip-execstack.py  clears PT_GNU_STACK X (kernel >= 6.6 rejects it on dlopen)
runners/npu_http.py      minimal /health + modality routes, SSE streaming, one session/lock
runners/genai_runner.py  onnxruntime-genai model -> /v1/chat/completions, /v1/completions
runners/embeddings_runner.py  ONNX + VitisAI EP -> /v1/embeddings
```

Model weights are host state under `services.npu.modelsDir` (`/srv/models/<registry id>`) and
are installed by the operator - nothing in this module downloads anything.

## The runtime is a package, not a script install

`packages/ryzen-ai.nix` builds the whole stack from AMD's pinned tarballs:

| attribute | contents |
| --- | --- |
| `dist` | wheels + `deployment/lib` extracted from `ryzen-ai-1.9.0.tgz` (only the members inference needs, not all 12 GB) |
| `xrt` | the four `RAI_1.9_Linux_NPU_XRT` Debian packages unpacked into one tree (`$xrt/opt/xilinx/xrt`) |
| `amdxdnaSource` | out-of-tree amdxdna driver source shipped inside XRT, ready for a DKMS build |
| `libs` | `LD_LIBRARY_PATH`: AMD deployment libs + XRT libs + `libz`/`libuuid`/`libncurses`/`libtinfo`/`libpython3.12` |
| `amdPythonEnv` | the three wheels pip-installed into one prefix (they share `onnxruntime/capi`), with `checkPhase` asserting `VitisAIExecutionProvider` registers |
| `pythonPath` | `PYTHONPATH`: AMD wheels + nixpkgs `numpy tokenizers coloredlogs flatbuffers packaging protobuf sympy` |
| `runtimeEnv` | the four variables a runner needs, ready for systemd `Environment=` |

Why not `pypi.amd.com`: it answers **403** from both the workstation and the box, so
upstream's `pip install --index-url ...` recipe cannot be used here. `voe` (2.8 GB),
`ryzenai_dynamic_dispatch*` (2.7 GB) and `cardano` (0.3 GB) are intentionally excluded —
voe is a quantisation tool, cardano is the AIE compiler client, and the dynamic-dispatch
runtime those wheels wrap already ships in `deployment/lib` (`libdyn_bins.so` 1.38 GB,
`libdyn_dispatch_core.so` 206 MB). The AMD quicktest runs on the NPU without them.

## One runner per model, like the GPU side

`mkNpuModel` produces the same shape as `mkGufo`/`mkLlamaCpp`: a `writeShellScript` launcher,
one engine process bound to one port, `Restart = no`, and the workload switch is literally
"stop this unit, start that one". No dispatcher, no adapter registry, no `/v1/models` — the
gateway switcher (`modules/dash/switcher.sh`) owns routing, remapping and the catalogue.

```nix
"llama-3.2-1b-npu" = mkNpuModel {
  modelId = "llama-3.2-1b-npu";
  description = "Llama 3.2 1B Instruct int4 on the XDNA 2 NPU (~2 W, off the GPU)";
  remappedModel = "Llama-3.2-1B-Instruct_rai_1.9.0_npu";
  kind = "genai";
  port = 8083;
  context = 8192; # declared window: exported as NPU_CONTEXT_LENGTH, shown by /v1/models
};
```

`kind` selects the runner (`genai` | `embeddings` | `asr` | `image-gen`) and the advertised
capabilities; the weights directory is `services.npu.modelsDir/<modelId>`, checked in
`ExecStartPre`, so weights that are not in place fail in the journal with the missing path
instead of leaving the gateway on a half-open connection. `context` is optional: without it
the runner keeps whatever `genai_config.json` declares.

## Status: LLMs run on the NPU (with `services.npu.xrtDriver`), embeddings still do not

Verified **on this machine** (`llm`, kernel 7.2.9, `/dev/accel/accel0`):

* ORT 1.30 accepts `providers=["VitisAIExecutionProvider"]`, reports
  `['VitisAIExecutionProvider', 'CPUExecutionProvider']`, and honours `provider_options`
  (`load_as_static=1`, `session_use_graph_batching`).
* AMD's official quicktest CNN builds the VitisAI Prefix graph (`Compiled model cost: 0.123s`,
  `VitisEP: Found Ep compatible nodes in this module: 225`), executes on the NPU
  (`Using dpu : NPU0`, `NPU kernel time: 3234 us`), and returns numerics identical to CPU.
* Execstack and all missing sonames are handled by the derivations, so this needs no manual
  environment fiddling.

```
curl :8199/v1/chat/completions  {"messages":[…"Name three cities in Japan"…]}
  -> "1. Tokyo  2. Osaka  3. Fukuoka"   finish_reason=stop, 45+21 tokens
measured decode: 59.3 tok/s (Llama-3.2-1B int4, og.Generator loop, NPU)
```

### The LLM path needed AMD's out-of-tree driver (fixed)

With mainline's `amdxdna` every LLM session (ONNX Runtime GenAI *and* plain ORT on AMD's
Llama-3.2-1B NPU artifact) failed identically inside the driver, after ~1 s of real NPU work:
`DRM_IOCTL_AMDXDNA_CREATE_BO … (err=-14: Bad address)` /
`amdxdna_get_ubuf: Failed to pin pages ret -14`.

That was a driver/userspace version gap, not a usage error (reproduced with `load_as_static`,
graph batching, the tokenizer removed, and with two different artifacts). Mainline's driver is
0.10.0-era and has no `amdxdna_ubuf_get_pages`, no `amdxdna_dpt.c` and no `npu6_regs`; AMD
develops the driver out-of-tree ([amd/xdna-driver](https://github.com/amd/xdna-driver), 2.2x)
and ships it inside XRT as a DKMS package. `nix flake update` therefore cannot fix it — there
is no synced mainline release to update to.

`services.npu.xrtDriver = true;` builds that tree for the running kernel
(`packages/amdxdna-driver.nix`) and installs it as `updates/amdxdna.ko`, which depmod prefers
over the in-tree copy — no nixpkgs kernel patching, no DKMS daemon, nothing outside the store.
It took effect live here with `rmmod amdxdna && insmod …/updates/amdxdna.ko` (0.10.0 → 0.16.0,
`version: 2.26.260102.59.release`); a reboot is what makes it permanent.

### Embeddings still need an AMD fix

`runners/embeddings_runner.py` is code-complete, but the only artifact AMD publishes for it,
`amd/embeddinggemma-300m_npu_rai_1.8.0_npu_4K`, references `com.ryzenai:CastAvx`, which no
1.8.0/1.9.0 runtime registers (same class as open
[amd/RyzenAI-SW#387](https://github.com/amd/RyzenAI-SW/issues/387), filed against 1.8.0 and
still open). `libvitis_ai_custom_opset.so` only exports `com.ryzenai:LayerNorm` /
`com.ryzenai:NPU`, so it is not a missing-library problem. The runner does fix the artifact's
`metadata_int8` schema drift (`scale_f` → `value`) for the files that do load.

`models/npu.nix` registers `llama-3.2-1b-npu` (dashboard, `/v1/*` routing, per-domain lock)
and keeps the embeddings entry commented out with the reason above.
