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
in
{
  imports = [
    ./workload-manager.nix
    ./gufo
    ./llama-cpp
    ./kyojin
    ./immich
    ./comfyui
  ];

  options.services = {
    defaultModel = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = "qwen3.8-flash-next";
      description = "Default model to activate on boot. If null, boots with 0 VRAM used.";
    };

    models = lib.mkOption {
      type = lib.types.attrsOf (
        lib.types.submodule {
          options = {
            serviceName = lib.mkOption {
              type = lib.types.str;
              description = "Systemd service unit name (e.g. gufo-foo.service).";
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
      inherit mkGufo mkLlamaCpp mkKyojin;
    };

    # Instantiate model systemd services with mutual Conflicts (Rule 1: single heavy workload in VRAM)
    systemd.services = lib.mapAttrs' (
      _: m:
      let
        unitAttr = lib.removeSuffix ".service" m.serviceName;
        otherUnits = lib.filter (u: u != m.serviceName) config.services.workload-manager.allExclusiveUnits;
      in
      lib.nameValuePair unitAttr (
        m.systemdService
        // {
          conflicts = (m.systemdService.conflicts or [ ]) ++ otherUnits;
          wantedBy = lib.optional (config.services.defaultModel == m.remappedModel) "multi-user.target";
        }
      )
    ) config.services.models;

    # Global models map definition
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
        sessions = 1;
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
    };
  };
}
