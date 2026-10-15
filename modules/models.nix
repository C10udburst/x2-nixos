{
  config,
  lib,
  pkgs,
  inputs ? {},
  ...
}: let
  mkGufo = import ./gufo/mkGufo.nix {
    inherit
      pkgs
      lib
      config
      inputs
      ;
  };
  mkLlamaCpp = import ./llama-cpp/mkLlamaCpp.nix {inherit pkgs lib config;};
in {
  imports = [
    ./workload-manager.nix
    ./gufo
    ./llama-cpp
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
      default = {};
      description = "Global map of model_id -> { serviceName, remappedModel, url, systemdService, ... }";
    };
  };

  config = {
    _module.args = {
      inherit mkGufo mkLlamaCpp;
    };

    # Instantiate model systemd services with mutual Conflicts (Rule 1: single heavy workload in VRAM)
    systemd.services =
      lib.mapAttrs' (
        _: m: let
          unitAttr = lib.removeSuffix ".service" m.serviceName;
          otherUnits = lib.filter (u: u != m.serviceName) config.services.workload-manager.allExclusiveUnits;
        in
          lib.nameValuePair unitAttr (
            m.systemdService
            // {
              conflicts = (m.systemdService.conflicts or []) ++ otherUnits;
              wantedBy = lib.optional (config.services.defaultModel == m.remappedModel) "multi-user.target";
            }
          )
      )
      config.services.models;

    # Global models map definition
    services.models = {
      # 1. Primary Model: Qwen 3.8 Flash Next with MTP speculative decoding & vision
      "qwen3.8-flash-next" = mkGufo {
        modelId = "qwen3.8-flash-next";
        description = "Qwen 3.8 Flash Next UD-Q4_K_XL with MTP speculative decoding & vision";
        modelPath = "qwen3.8-flash-next/UD-Q4_K_XL";
        mmprojPath = "qwen3.8-flash-next/mmproj-BF16.gguf";
        speculative = "mtp";
        mtpModelPath = "qwen3.8-flash-next/MTP/mtp-Qwen3.8-Flash-Next-shared-Q8_0.gguf";
        context = 262144;
        sessions = 1;
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
        sessions = 4;
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

      # 6. Liquid AI LFM2.5-8B-A1B (hybrid conv/attention MoE, 1.5B active params)
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
    };
  };
}
