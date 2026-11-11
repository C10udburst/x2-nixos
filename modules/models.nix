{
  config,
  lib,
  pkgs,
  inputs ? { },
  ...
}:
let
  mkGufo = import ./gufo/mkGufo.nix {
    inherit
      pkgs
      lib
      config
      inputs
      ;
  };
  mkLlamaCpp = import ./llama-cpp/mkLlamaCpp.nix { inherit pkgs lib config; };
  mkKyojin = import ./kyojin/mkKyojin.nix {
    inherit
      pkgs
      lib
      config
      inputs
      ;
  };
  mkNpuModel = import ./npu/mkNpuModel.nix { inherit pkgs lib config; };

  # Rule 1 is enforced per hardware domain, so the NPU entries below coexist with a warm
  # GPU model. They are only added to the registry when the Ryzen AI runtime is enabled:
  # `services.npu.enable = false` must leave a GPU-only registry that still evaluates and
  # builds (no /dev/accel rules, no NPU units).
  npuEnabled = config.services.npu or { enable = false; };

  npuModels = {
    # 14. Llama 3.2 1B Instruct on the XDNA 2 NPU (OGA / genai runtime, int4)
    #     Artifact: amd/Llama-3.2-1B-Instruct_rai_1.9.0_npu (ungated, 2.0 GB), fetched by
    #     /srv/models/dl-npu.sh into /srv/models/llama-3.2-1b-npu.
    "llama-3.2-1b-npu" = mkNpuModel {
      modelId = "llama-3.2-1b-npu";
      remappedModel = "Llama-3.2-1B-Instruct_rai_1.9.0_npu";
      description = "Llama 3.2 1B Instruct int4 on the Ryzen AI NPU - light chat alongside the GPU LLM";
      port = 8083;
      kind = "genai";
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
  };
in
{
  imports = [
    ./workload-manager.nix
    ./gufo
    ./llama-cpp
    ./kyojin
    ./npu
    ./immich
    ./comfyui
  ];

  options.services = {
    defaultModel = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = "qwen3.8-flash-next";
      description = ''
        Default model to activate on boot, matched against the registry key.
        If null, boots with 0 VRAM used. Under dual-domain locking at most one
        default per domain makes sense - enabling one GPU and one NPU model at
        once is legitimate and they run concurrently.
      '';
    };

    models = lib.mkOption {
      type = lib.types.attrsOf (
        lib.types.submodule {
          options = {
            device = lib.mkOption {
              type = lib.types.enum [
                "gpu"
                "npu"
              ];
              default = "gpu";
              description = "Hardware acceleration domain: 'gpu' (RDNA 3.5) or 'npu' (Ryzen AI XDNA 2).";
            };
            serviceName = lib.mkOption {
              type = lib.types.str;
              description = "Systemd service unit name (e.g. gufo-foo.service or npu-bge-m3.service).";
            };
            remappedModel = lib.mkOption {
              type = lib.types.str;
              description = "Model identifier expected by backend engine.";
            };
            url = lib.mkOption {
              type = lib.types.str;
              description = "HTTP backend URL to forward requests to.";
            };
            description = lib.mkOption {
              type = lib.types.str;
              default = "";
              description = "Human-readable description for dashboard.";
            };
            type = lib.mkOption {
              type = lib.types.str;
              default = "gufo";
              description = "Backend inference engine type (e.g. gufo, llama-cpp).";
            };
            sessions = lib.mkOption {
              type = lib.types.int;
              default = 1;
              description = "Maximum concurrent sessions / slots.";
            };
            # Free-form on purpose: the switcher never reads it, so adding a modality
            # (asr, image-gen, rerank, ...) must not require touching this file.
            capabilities = lib.mkOption {
              type = lib.types.listOf lib.types.str;
              default = [ ];
              description = "OpenAI-ish capability tags for UI/model discovery, e.g. [ \"embeddings\" ].";
            };
            # Empty means "no on-disk prerequisite known" - the switcher only pre-flights
            # a directory it was actually told about (NPU entries set this).
            modelDir = lib.mkOption {
              type = lib.types.str;
              default = "";
              description = "Absolute model directory on the host, or \"\" when not applicable.";
            };
            systemdService = lib.mkOption {
              type = lib.types.attrs;
              description = "NixOS systemd.services unit configuration.";
            };
          };
        }
      );
      default = { };
      description = "Global map of model_id -> { serviceName, remappedModel, url, systemdService, ... }";
    };
  };

  config = {
    _module.args = {
      inherit
        mkGufo
        mkLlamaCpp
        mkKyojin
        mkNpuModel
        ;
    };

    # Instantiate model systemd services with mutual Conflicts.
    # Rule 1 is per domain: a model conflicts with the workloads of ITS OWN domain only,
    # so an NPU model never unloads a GPU LLM and vice versa.
    systemd.services = lib.mapAttrs' (
      modelId: m:
      let
        unitAttr = lib.removeSuffix ".service" m.serviceName;
        domainUnits =
          if m.device == "npu" then
            config.services.workload-manager.npuExclusiveUnits
          else
            config.services.workload-manager.gpuExclusiveUnits;
        otherUnits = lib.filter (u: u != m.serviceName) domainUnits;
      in
      lib.nameValuePair unitAttr (
        m.systemdService
        // {
          conflicts = (m.systemdService.conflicts or [ ]) ++ otherUnits;
          wantedBy = lib.optional (config.services.defaultModel == modelId) "multi-user.target";
        }
      )
    ) config.services.models;

    # Global models map definition
    services.models = {
      # NOTE: NPU (XDNA 2) models are appended below the GPU block via npuModels.
      # 1. Primary Model: Qwen 3.8 Flash Next with MTP speculative decoding & vision
      "qwen3.8-flash-next" = mkGufo {
        modelId = "qwen3.8-flash-next";
        description = "Qwen 3.8 Flash Next UD-Q4_K_XL with MTP speculative decoding & vision";
        modelPath = "qwen3.8-flash-next/UD-Q4_K_XL";
        mmprojPath = "qwen3.8-flash-next/mmproj-BF16.gguf";
        mtpModelPath = "qwen3.8-flash-next/MTP/mtp-Qwen3.8-Flash-Next-shared-Q8_0.gguf";
        context = 524288;
        sessions = 2;
      };

      # 2. Qwen 3.8 27B with DFlash2 speculative decoding & vision
      "qwen3.8-27b" = mkGufo {
        modelId = "qwen3.8-27b";
        description = "Qwen 3.8 27B UD-Q4_K_XL with DFlash2 speculative decoding & vision";
        modelPath = "qwen3.8-27b/Qwen3.8-27B-UD-Q4_K_XL.gguf";
        mmprojPath = "qwen3.8-27b/mmproj-BF16.gguf";
        speculative = "dflash2";
        dflashModelPath = "qwen3.8-27b/Qwen3.8-27B-DFlash2-Q4_K_M.gguf";
        context = 32768;
        sessions = 8;
      };

      # 3. Example Second Model: Qwen 2.5 72B Instruct
      "qwen2.5-72b-instruct" = mkLlamaCpp {
        modelId = "qwen2.5-72b-instruct";
        description = "Qwen 2.5 72B Instruct (Q4_K_M) - High reasoning capability";
        modelPath = "qwen2.5-72b-instruct";
        context = 32768;
        cacheTypeK = "q8_0";
        cacheTypeV = "q8_0";
        gpuLayers = 99;
        parallel = 4;
        flashAttention = true;
        threads = 16;
        jinja = true;
      };

      # 4. Example Third Model: DeepSeek R1 Distill Qwen 32B
      "deepseek-r1-distill-qwen-32b" = mkLlamaCpp {
        modelId = "deepseek-r1-distill-qwen-32b";
        description = "DeepSeek R1 Distill Qwen 32B (Q8_0) - Deep reasoning specialist";
        modelPath = "deepseek-r1-distill-qwen-32b";
        context = 131072;
        cacheTypeK = "q8_0";
        cacheTypeV = "q8_0";
        gpuLayers = 99;
        parallel = 4;
        flashAttention = true;
        threads = 16;
        jinja = true;
      };

      # 5. Multimodal OCR: GLM-OCR 0.9B
      "glm-ocr" = mkLlamaCpp {
        modelId = "glm-ocr";
        description = "GLM-OCR 0.9B (Q8_0) - Document OCR";
        modelPath = "glm-ocr/GLM-OCR-Q8_0.gguf";
        mmprojPath = "glm-ocr/mmproj-GLM-OCR-Q8_0.gguf";
        context = 8192;
        cacheTypeK = "q8_0";
        cacheTypeV = "q8_0";
        gpuLayers = 99;
        parallel = 16;
        flashAttention = true;
        threads = 16;
        jinja = true;
      };

      # 6. Uncensored Flash-Next (Q4 Mix) with MTP speculative decoding & vision
      "qwen3.8-flash-next-uncensored" = mkGufo {
        modelId = "qwen3.8-flash-next-uncensored";
        description = "Qwen 3.8 Flash Next Uncensored Q4 Mix with MTP speculative decoding & vision";
        modelPath = "qwen3.8-flash-next-uncensored/Qwen3.8-Flash-Next-Uncensored-Gufo-Q4Mix.gguf";
        mmprojPath = "qwen3.8-flash-next-uncensored/mmproj-BF16.gguf";
        speculative = "mtp";
        draftTokens = 6;
        mtpModelPath = "qwen3.8-flash-next-uncensored/mtp/Qwen3.8-Flash-CIRU-STRIX-Orca-MTP-Q8_0.gguf";
        context = 262144;
        sessions = 2;
      };

      # 7. Liquid AI LFM2.5-8B-A1B (hybrid conv/attention MoE, 1.5B active params)
      "lfm2.5-8b-a1b" = mkLlamaCpp {
        modelId = "lfm2.5-8b-a1b";
        description = "LFM2.5 8B A1B (Q4_K_M) - fast MoE chat/coder, 1.5B active params";
        modelPath = "lfm2.5-8b-a1b/LFM2.5-8B-A1B-Q4_K_M.gguf";
        # 128000 = lfm2moe.context_length in the GGUF (native ceiling, rope base 5e6)
        context = 128000;
        cacheTypeK = "q8_0";
        cacheTypeV = "q8_0";
        gpuLayers = 99;
        parallel = 16;
        flashAttention = true;
        threads = 16;
        jinja = true;
      };

      # 8. GLM-5.3-Flash EXL3 (320B total, 18B active) with MTP speculative decoding & vision
      "glm-5.3-flash" = mkKyojin {
        modelId = "glm-5.3-flash";
        description = "GLM-5.3-Flash EXL3 (320B total, 18B active) with MTP speculative decoding & vision";
        modelPath = "glm-5.3-flash";
        flavor = "glm";
        context = 524288; # Max context fitting in 128GB unified RAM (~118 GiB footprint)
        numDraft = 2;
        sessions = 1;
        uncensor = false;
      };

      # 9. GLM-5.3-Flash EXL3 Uncensored (shares base weights via runtime refusal-direction ablit hook)
      "glm-5.3-flash-uncensored" = mkKyojin {
        modelId = "glm-5.3-flash-uncensored";
        remappedModel = "glm-5.3-flash-uncensored";
        description = "GLM-5.3-Flash EXL3 Uncensored (320B, runtime refusal-direction ablit hook)";
        modelPath = "glm-5.3-flash"; # Zero duplicate weights; reuses base EXL3 pack
        flavor = "glm";
        context = 524288;
        numDraft = 2;
        sessions = 1;
        uncensor = true;
      };

      # 10. Humanizer 12B v2 (fine-tuned Gemma 4 12B) text humanization model
      "humanizer" = mkLlamaCpp {
        modelId = "humanizer";
        description = "Humanizer 12B v2 (Q8_0) - Text humanizer via llama-server";
        modelPath = "humanizer/humanizer-12b-Q8_0.gguf";
        context = 8192;
        cacheTypeK = "q8_0";
        cacheTypeV = "q8_0";
        gpuLayers = 99;
        parallel = 1;
        flashAttention = true;
        threads = 16;
        jinja = true;
      };

      # 11. DeepSeek V4 Flash (IQ2XXS, 80.76 GiB) with DSpark speculative decoding
      "deepseek-v4-flash" = mkGufo {
        modelId = "deepseek-v4-flash";
        description = "DeepSeek V4 Flash IQ2XXS (80.76 GiB) with DSpark speculative decoding";
        modelPath = "deepseek-v4-flash/DeepSeek-V4-Flash-IQ2XXS-w2Q2K-AProjQ8-SExpQ8-OutQ8-chat-v2-imatrix-0731.gguf";
        speculative = "dspark";
        dsparkModelPath = "deepseek-v4-flash/DeepSeek-V4-Flash-DSpark-support-0731.gguf";
        context = 131072; # Maximum native context length (128K tokens) verified on 128GB Strix Halo
        sessions = 1;
      };

      "mimo-v2.6-flash-mopd" = mkLlamaCpp {
        modelId = "mimo-v2.6-flash-mopd";
        description = "MiMo V2.6 Flash MOPD mixed IQ2_XXS/XS + Q8 (309.8B) with vision, audio and video";
        modelPath = "mimo-v2.6-flash-mopd"; # first shard; llama.cpp pulls the other three via split metadata
        mmprojPath = "mimo-v2.6-flash-mopd/mmproj-MiMo-V2.6-Flash-MOPD-BF16.gguf";
        context = 1048576; # selected profile; native ceiling is 1048576 but OOMs on 128 GB
        cacheTypeK = "q8_0";
        cacheTypeV = "q8_0";
        gpuLayers = 999;
        parallel = 2;
        flashAttention = true;
        threads = 16; # 16 physical Zen 5 cores for decode
        jinja = true; # native MiMo chat template: think blocks, tool calls, enable_thinking kwarg
        extraArgs = [
          "-b"
          "2048"
          "-ub"
          "512"
          "-tb"
          "32" # 32 threads only for batch/prefill
          "-fit"
          "off" # keep the full 256K window, do not auto-shrink it
          "-lm"
          "none" # recipe ran with --no-mmap: no page-cache mappings on top of the shared LPDDR5x pool
          "-rea"
          "on"
          "--chat-template-kwargs"
          "{\"enable_thinking\":true}"
        ];
      };

      # 13. Ripple-65B Preview (Ricursive Intelligence) - dense 65B agentic coder
      #     Brand-new llama.cpp architecture (`ricursive`): 80 layers, four 1024-token
      #     sliding-window layers with RoPE + one global NoPE layer per group of five,
      #     peri-norm, sigmoid attention output gate, value residual, SwiGLU clamped at 20.
      #     Needs the pinned engine in modules/llama-cpp/packages/ricursive.nix.
      #
      #     Strix Halo tuning (128 GB unified LPDDR5x @ 256 GB/s, amdgpu.gttsize=120 GB):
      #       * AD-Q6_K (53.75 GiB weights, mean KLD 0.0016 vs BF16). Dense decode is pure
      #         bandwidth (~3.5 tok/s), and Q8_0 buys 0.0006 KLD for 10 GiB more bytes read
      #         per token - not worth it. AD-Q5_K_M / AD-IQ3_S trade quality for ~17% / ~67%
      #         more decode speed if interactivity matters more than reasoning depth.
      #       * context 262144 is cheap for THIS architecture: llama.cpp keeps a short
      #         sliding-window cache for the 64 SWA layers (LLAMA_SWA_TYPE_STANDARD and
      #         swa_full=false by default - never pass --swa-full here) and only the 16
      #         global layers carry full KV: 16 layers x 8 kv-heads x 128 dim x 2 (K+V)
      #         x ~1.06 B (q8_0) ~= 35 KB/token => ~8.7 GB at 256K, plus ~43 MB of window
      #         cache. Total footprint ~= 53.75 + 8.7 GiB, far inside the GTT aperture.
      #       * -fa on keeps the short SWA cache reusable and matches the q8_0 KV path
      #         every other llama-cpp model on this host already uses.
      #       * -b 4096 -ub 1024 widens the prefill chunk: prefill (~130 GFLOP/token),
      #         not decode, is where the RDNA 3.5 iGPU runs out of road on a dense 65B.
      #       * -fit off keeps the full 256K window - the weights always fit, so there is
      #         nothing for auto-fit to protect.
      #       * default load mode (mmap) stays: pages are pinned through the GTT aperture
      #         anyway and remain reclaimable if the box ever runs short.
      #     Ricursive publishes no default sampling settings for the Preview, so none are set.
      "ripple-65b" = mkLlamaCpp {
        modelId = "ripple-65b";
        description = "Ripple-65B Preview AD-Q6_K - dense 65B agentic coder (SWA + NoPE, ricursive arch)";
        modelPath = "ripple-65b/Ripple-65B-Preview-AD-Q6_K-00001-of-00002.gguf";
        # ricursive was merged upstream on 2026-11-05 (ggml-org/llama.cpp#31692); the
        # nixpkgs llama-cpp this flake pins predates it.
        package = pkgs.callPackage ./llama-cpp/packages/ricursive.nix {
          rocmPackages = pkgs.rocmPackages.gfx1151;
        };
        context = 262144; # native ceiling is 2097152; 256K keeps the KV cache under ~9 GiB
        cacheTypeK = "q8_0";
        cacheTypeV = "q8_0";
        gpuLayers = 99; # all 80 layers on the RDNA 3.5 iGPU
        parallel = 1; # single slot: dense 65B decode is bandwidth-bound
        flashAttention = true;
        threads = 16; # 16 physical Zen 5 cores
        jinja = true; # ChatML template with tool calls + <think> reasoning is embedded
        extraArgs = [
          "-b"
          "4096"
          "-ub"
          "1024"
          "-fit"
          "off"
        ];
      };
    }
    // lib.optionalAttrs npuEnabled.enable npuModels;
  };
}
