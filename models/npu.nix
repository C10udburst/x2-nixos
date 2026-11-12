# NPU domain model registry (AMD XDNA 2 / Ryzen AI).
#
# Raw declarations only - see ./gpu.nix for the same idea on the iGPU side and
# ../modules/models.nix for the schema, the factories and the orchestration.
#
# The whole block is conditional on `services.npu.enable`: with the Ryzen AI runtime off the
# registry must still evaluate and build as a GPU-only system (no /dev/accel rules, no NPU
# units, nothing referencing the packaged runtime). Rule 1 is enforced per domain, so these
# entries coexist with a warm GPU model and never join the GPU conflict set.
{
  config,
  lib,
  mkNpuModel,
  ...
}:
let
  npuEnabled = config.services.npu or { enable = false; };
in
{
  config = lib.mkIf npuEnabled.enable {
    services.models = {
      # 14. Llama 3.2 1B Instruct on the XDNA 2 NPU (OGA / genai runtime, int4)
      #     Artifact: amd/Llama-3.2-1B-Instruct_rai_1.9.0_npu (ungated, 2.0 GB), installed by
      #     hand into /srv/models/llama-3.2-1b-npu. Weights are host state: no unit downloads.
      "llama-3.2-1b-npu" = mkNpuModel {
        modelId = "llama-3.2-1b-npu";
        remappedModel = "Llama-3.2-1B-Instruct_rai_1.9.0_npu";
        description = "Llama 3.2 1B Instruct int4 on the Ryzen AI NPU - light chat alongside the GPU LLM";
        port = 8083;
        kind = "genai";
        # Exported as NPU_CONTEXT_LENGTH: the declared window is what /v1/models reports and
        # what the dashboard's context filter sorts by (the runner would otherwise read
        # context_length from the artifact's genai_config.json).
        context = 8192;
      };

      # 15. EmbeddingGemma 300M on the NPU - NOT REGISTERED: the only artifact AMD publishes
      #     (amd/embeddinggemma-300m_npu_rai_1.8.0_npu_4K) references a custom op that no
      #     Ryzen AI 1.8/1.9 runtime registers, so the session cannot even be created:
      #     "com.ryzenai:CastAvx(-1) is not a registered function/op"
      #     (https://github.com/amd/RyzenAI-SW/issues/387, verified on this host).
      #     The runner is ready - re-enable this entry when AMD ships a fixed artifact.
      #
      # "embeddinggemma-300m" = mkNpuModel {
      #   modelId = "embeddinggemma-300m";
      #   description = "EmbeddingGemma 300M (ONNX int4, Ryzen AI NPU) - text embeddings";
      #   port = 8084;
      #   kind = "embeddings";
      # };

      # 16. Whisper-small on the NPU (ASR / speech-to-text)
      #     Artifact: amd/whisper-small-onnx-npu (ungated, 970 MB encoder + 617 MB decoder)
      #     Pre-compiled by AMD with static shapes for seq_len, fully VitisAI EP compatible.
      #     Verified on this host: encoder builds + loads in 134 s, produces 10.9 MB .rai cache.
      "whisper-small-onnx-npu" = mkNpuModel {
        modelId = "whisper-small-onnx-npu";
        description = "Whisper-small ONNX on the Ryzen AI NPU - ASR / speech-to-text";
        port = 8087;
        kind = "asr";
      };
    };
  };
}
