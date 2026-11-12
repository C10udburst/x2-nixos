# NPU domain model registry (AMD XDNA 2 / Ryzen AI), served by OpenFlowLM.
#
# Raw declarations only - see ./gpu.nix for the same idea on the iGPU side and
# ../modules/models.nix for the schema, the factories and the orchestration.
#
# The engine is OpenFlowLM (`oflm serve`), so an entry is a *tag*, not a weights path:
# `mkOpenFlow` looks the tag up in the engine's own catalogue at eval time to get the
# directory name and the context window, and the weights themselves are host state under
# `services.npu.openflowlm.modelStore`. Nothing here downloads anything - a model that is
# not in place fails in `ExecStartPre` with the pull command to run. Place weights once:
#
#     sudo -u npu env OFLM_MODEL_PATH=/srv/models/oflm HOME=/var/lib/oflm \
#          oflm pull llama3.2:1b
#
# Why the registry key is the tag: the router resolves `model` from the request and
# forwards the body untouched, so the name that reaches `oflm` has to be one it resolves
# (`llama3.2:1b`, `whisper-v3:turbo`). A prettier key would 404 at the backend.
#
# Rule 1 is still enforced per domain: these entries join `npuExclusiveUnits` and evict
# each other, never a warm GPU model.
{
  config,
  lib,
  mkOpenFlow,
  ...
}:
let
  npuEnabled = config.services.npu or { enable = false; };
in
{
  config = lib.mkIf npuEnabled.enable {
    services.models = {
      # 14. Llama 3.2 1B Instruct on the XDNA 2 NPU (Q4_1, `Llama-3.2-1B-NPU2`).
      #     The catalogue declares 131072 context; 8192 is what this host actually runs, so
      #     the KV cache stays next to a warm GPU model instead of eating unified memory.
      "llama3.2:1b" = mkOpenFlow {
        modelId = "llama3.2:1b";
        description = "Llama 3.2 1B Instruct Q4_1 on the Ryzen AI NPU via OpenFlowLM - light chat alongside the GPU LLM";
        port = 8083;
        context = 8192;
      };

      # 15. Llama 3.2 3B Instruct (Q4_1, ~2.7 GB footprint). Same tag family, so a client
      #     can ask for either by name and the router picks the unit - which means two
      #     units, two ports, and one NPU: switching one in evicts the other.
      "llama3.2:3b" = mkOpenFlow {
        modelId = "llama3.2:3b";
        description = "Llama 3.2 3B Instruct Q4_1 on the Ryzen AI NPU via OpenFlowLM";
        port = 8084;
        context = 8192;
      };

      # 16. Whisper large-v3 turbo as a standalone ASR server (`--asr 1` with no chat tag:
      #     `serve` loads no LLM, and POST /v1/audio/transcriptions answers on its own).
      #     Context is fixed at 448 tokens / 30 s windows by the architecture, so there is
      #     nothing to pass and the catalogue's value is only reported to /v1/models.
      "whisper-v3:turbo" = mkOpenFlow {
        modelId = "whisper-v3:turbo";
        description = "Whisper large-v3 turbo on the Ryzen AI NPU via OpenFlowLM - ASR / speech-to-text";
        port = 8087;
        kind = "asr";
      };

      # 17. EmbeddingGemma 300M as a standalone encoder server (`--embed 1` with no chat tag).
      #     Measured on this host: 768-dim vectors, ~0.7 s for a two-sentence batch, and the
      #     open embedding kernel came up with 6 of its 7 NPU matmul shapes - the 2048x3072x768
      #     one is refused by the driver (`CREATE_HWCTX … err=-22`), so the longest bucket runs
      #     elsewhere. It answers, which is more than AMD's ONNX artifact ever did here.
      #     Port 8088; 8085 is the iGPU's kyojin, not free.
      "embed-gemma:300m" = mkOpenFlow {
        modelId = "embed-gemma:300m";
        description = "EmbeddingGemma 300M on the Ryzen AI NPU via OpenFlowLM - 768-dim text embeddings";
        port = 8088;
        kind = "embeddings";
      };

      # The four BERT sets (`all-minilm:l12-v2`, `all-minilm:l6-v2`, `bge-base:en-v1.5`,
      # `bge-large:en-v1.5`) take the same `kind = "embeddings"` shape whenever they are
      # wanted; they need their own weights pull, nothing here changes.
    };
  };
}
