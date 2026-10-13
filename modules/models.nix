{
  config,
  lib,
  pkgs,
  inputs ? {},
  ...
}: let
  mkGufo = import ./gufo/mkGufo.nix {inherit pkgs lib config inputs;};
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
      lib.mapAttrs' (_: m: let
        unitAttr = lib.removeSuffix ".service" m.serviceName;
        otherUnits = lib.filter (u: u != m.serviceName) config.services.workload-manager.allExclusiveUnits;
      in
        lib.nameValuePair unitAttr (m.systemdService // {
          conflicts = (m.systemdService.conflicts or []) ++ otherUnits;
          wantedBy = lib.optional (config.services.defaultModel == m.remappedModel) "multi-user.target";
        })
      ) config.services.models;

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

      # 2. Example Second Model: Qwen 2.5 72B Instruct
      "qwen2.5-72b-instruct" = mkLlamaCpp {
        modelId = "qwen2.5-72b-instruct";
        description = "Qwen 2.5 72B Instruct (Q4_K_M) - High reasoning capability";
        modelPath = "qwen2.5-72b-instruct";
        context = 131072;
        cacheTypeK = "q8_0";
        cacheTypeV = "q8_0";
        gpuLayers = 99;
        parallel = 1;
        flashAttention = true;
        threads = 16;
        jinja = true;
      };

      # 3. Example Third Model: DeepSeek R1 Distill Qwen 32B
      "deepseek-r1-distill-qwen-32b" = mkLlamaCpp {
        modelId = "deepseek-r1-distill-qwen-32b";
        description = "DeepSeek R1 Distill Qwen 32B (Q8_0) - Deep reasoning specialist";
        modelPath = "deepseek-r1-distill-qwen-32b";
        context = 131072;
        cacheTypeK = "q8_0";
        cacheTypeV = "q8_0";
        gpuLayers = 99;
        parallel = 1;
        flashAttention = true;
        threads = 16;
        jinja = true;
      };

      # 4. Example llama.cpp Model (easily add/enable llama.cpp models):
      # "llama-3.2-3b" = mkLlamaCpp {
      #   modelId = "llama-3.2-3b";
      #   description = "Llama 3.2 3B Instruct via llama-server";
      #   modelPath = "llama-3.2-3b/Llama-3.2-3B-Instruct-Q8_0.gguf";
      # };
    };
  };
}
