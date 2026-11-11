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
packages/strip-execstack.py  clears PT_GNU_STACK X (kernel >= 6.6 rejects it on dlopen)
runners/npu_http.py      minimal /health + modality routes, SSE streaming, one session/lock
runners/genai_runner.py  onnxruntime-genai model -> /v1/chat/completions, /v1/completions
runners/embeddings_runner.py  ONNX + VitisAI EP -> /v1/embeddings
dl-npu.sh                weights downloader (the only script here: weights are host state)
```

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
  modelPath = "llama-3.2-1b-npu";
  remappedModel = "Llama-3.2-1B-Instruct_rai_1.9.0_npu";
  kind = "genai";
  port = 8083;
};
```

`kind` selects the runner (`genai` | `embeddings` | `asr` | `image-gen`) and the advertised
capabilities; `modelPath` is resolved against `services.npu.modelsDir` and checked in
`ExecStartPre`, so a missing download fails with a pointer to `dl-npu.sh` instead of a
half-open connection.

## Status: the stack is validated, the two MVP artifacts are not shippable yet

Verified **on this machine** (`llm`, kernel 7.2.9, driver `amdxdna`, `/dev/accel/accel0`):

* ORT 1.30 accepts `providers=["VitisAIExecutionProvider"]`, reports
  `['VitisAIExecutionProvider', 'CPUExecutionProvider']`, and honours `provider_options`
  (`load_as_static=1`, `session_use_graph_batching`).
* AMD's official quicktest CNN builds the VitisAI Prefix graph (`Compiled model cost: 0.123s`,
  `VitisEP: Found Ep compatible nodes in this module: 225`), executes on the NPU
  (`Using dpu : NPU0`, `NPU kernel time: 3234 us`), and returns numerics identical to CPU.
* Execstack and all missing sonames are handled by the derivations, so this needs no manual
  environment fiddling.

Two AMD-side blockers, each isolated so the other still works:

1. **LLM path (`genai_runner.py`) — needs the newer amdxdna driver.** Every LLM session
   (ONNX Runtime GenAI *and* plain ORT on AMD's Llama-3.2-1B NPU artifact) fails identically
   inside the driver:
   `DRM_IOCTL_AMDXDNA_CREATE_BO ... failed (err=-14: Bad address)` /
   `amdxdna_get_ubuf: Failed to pin pages ret -14`, after ~980 ms of real NPU work.
   `io_uring` (used by the 1.9.0 BO path) is enabled here, and the failure reproduces with
   `load_as_static`, graph batching, and the tokenizer stripped out, so it is not a usage
   error. XRT ships the out-of-tree driver source (`services.npu` exposes it as
   `ryzenAi.amdxdnaSource`); installing it via DKMS is the fix and is tracked in PLAN.md.
2. **Embeddings path (`embeddings_runner.py`) — AMD artifact cannot be loaded by any runtime.**
   `amd/embeddinggemma-300m_npu_rai_1.8.0_npu_4K` references `com.ryzenai:CastAvx`, which no
   1.8.0/1.9.0 runtime registers (same class as open
   [amd/RyzenAI-SW#387](https://github.com/amd/RyzenAI-SW/issues/387), filed against 1.8.0
   and still open). `libvitis_ai_custom_opset.so` only exports `com.ryzenai:LayerNorm` /
   `com.ryzenai:NPU`, so it is not a missing-library problem. The runner also fixes the
   artifact's `metadata_int8` schema drift (`scale_f` → `value`) for the files that do load.

Neither is wired into the gateway until it works: `modules/models.nix` registers
`llama-3.2-1b-npu` (so the NPU domain is exercised end to end: dashboard, `/v1/*` routing,
per-domain lock) and keeps the embeddings entry commented out with this reason.
