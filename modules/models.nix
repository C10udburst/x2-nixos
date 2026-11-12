# Model registry scaffold.
#
# This module owns the *shape* of the registry, never the entries themselves:
#
#   * the engine factories (`mkGufo`, `mkLlamaCpp`, `mkKyojin`, `mkNpuModel`,
#     `mkOpenFlow`), exposed to every other module through `_module.args` so a registry
#     file needs no imports;
#   * the contract itself - `services.models.<id>` (see the option below) and
#     `services.defaultModel`;
#   * the orchestration glue: one systemd unit per registry entry with intra-domain
#     `Conflicts=` and `wantedBy` for the default model.
#
# The raw model declarations live in <repo>/models/gpu.nix (RDNA 3.5 iGPU) and
# <repo>/models/npu.nix (XDNA 2), one file per hardware domain.
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
  mkOpenFlow = import ./npu/mkOpenFlow.nix { inherit pkgs lib config; };
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
    ../models/gpu.nix
    ../models/npu.nix
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
            # Reported verbatim by /v1/models as `context_length` and used by the dashboard's
            # context-length filter. `null` means the runner decides (no -c/--context passed).
            context = lib.mkOption {
              type = lib.types.nullOr lib.types.int;
              default = null;
              description = "Context window per session in tokens, or null when unset.";
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
    # Every registry file (models/*.nix) gets the factories as plain function arguments:
    # one factory per engine, each returning an entry that satisfies the contract above.
    _module.args = {
      inherit
        mkGufo
        mkLlamaCpp
        mkKyojin
        mkNpuModel
        mkOpenFlow
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
  };
}
