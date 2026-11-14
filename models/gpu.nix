# GPU domain model registry (RDNA 3.5 iGPU, unified memory pool).
#
# Raw declarations only: the schema (`services.models`), the engine factories and the
# orchestration live in ../modules/models.nix. `mkGufo`, `mkLlamaCpp`, `mkKyojin` and
# `mkNpuModel` are handed to every module through `_module.args`, so this file adds no
# imports of its own.
#
# Rule 1: every unit declared here conflicts with every other GPU workload - see
# modules/workload-manager.nix. NPU models live in ./npu.nix and never displace them.
{
  pkgs,
  mkGufo,
  mkLlamaCpp,
  mkKyojin,
  ...
}:
{
  services.models = {
    # 1. Primary Model: Qwen 3.8 Flash Next with MTP speculative decoding & vision
    "qwen3.8-flash-next" = mkGufo {
      modelId = "qwen3.8-flash-next";
      description = "Qwen 3.8 Flash Next UD-Q4_K_XL with MTP speculative decoding & vision";
      modelPath = "qwen3.8-flash-next/UD-Q4_K_XL";
      mmprojPath = "qwen3.8-flash-next/mmproj-BF16.gguf";
      mtpModelPath = "qwen3.8-flash-next/MTP/mtp-Qwen3.8-Flash-Next-shared-Q8_0.gguf";
      context = 262144;
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
    "ripple-65b" = mkLlamaCpp {
      modelId = "ripple-65b";
      description = "Ripple-65B Preview AD-Q6_K - dense 65B agentic coder (SWA + NoPE, ricursive arch)";
      modelPath = "ripple-65b/Ripple-65B-Preview-AD-Q6_K-00001-of-00002.gguf";
      # ricursive was merged upstream on 2026-11-05 (ggml-org/llama.cpp#31692); the
      # nixpkgs llama-cpp this flake pins predates it.
      package = pkgs.callPackage ../modules/llama-cpp/packages/ricursive.nix {
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
  };
}
