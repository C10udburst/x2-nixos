{
  config,
  lib,
  pkgs,
  ...
}: let
  models = config.services.models or { };

  modelsOnDevice = device: lib.filterAttrs (_: m: (m.device or "gpu") == device) models;

  # 1. Model units, partitioned by hardware domain
  gpuModelUnits = lib.mapAttrsToList (_: m: m.serviceName) (modelsOnDevice "gpu");
  npuModelUnits = lib.mapAttrsToList (_: m: m.serviceName) (modelsOnDevice "npu");

  # 2. Standalone on-demand units (both live on the RDNA 3.5 iGPU today)
  gpuOnDemandUnits =
    (lib.optional (config.services ? immich-ml && config.services.immich-ml.enable) "immich-machine-learning.service")
    ++ (lib.optional (config.services ? comfyui && config.services.comfyui.enable) "comfyui.service");
  npuOnDemandUnits = [ ];

  # 3. Complete lists per domain, calculated at Nix eval time (Rule 1 applies per domain:
  #    at most one GPU workload AND at most one NPU workload may be resident at once)
  gpuExclusiveUnits = gpuModelUnits ++ gpuOnDemandUnits;
  npuExclusiveUnits = npuModelUnits ++ npuOnDemandUnits;
  allExclusiveUnits = gpuExclusiveUnits ++ npuExclusiveUnits;

  mkUnitList = units:
    if units == [ ] then "()" else ''(
      ${lib.concatStringsSep "\n      " (map (u: "\"${u}\"") units)}
    )'';

  # 4. Eval-time generated stop script: stop-other-workloads <device> <target_unit>
  #    Every caller MUST pass an explicit device; there is deliberately no default,
  #    because a silent "gpu" fallback would let an NPU request unload a 300 GB GPU model.
  stopOtherWorkloadsScript = pkgs.writeShellScript "stop-other-workloads" ''
    set -euo pipefail

    DEVICE="''${1:-}"
    TARGET_UNIT="''${2:-}"

    GPU_UNITS=${mkUnitList gpuExclusiveUnits}
    NPU_UNITS=${mkUnitList npuExclusiveUnits}

    case "$DEVICE" in
      gpu) UNITS=("''${GPU_UNITS[@]}") ;;
      npu) UNITS=("''${NPU_UNITS[@]}") ;;
      all) UNITS=("''${GPU_UNITS[@]}" "''${NPU_UNITS[@]}") ;;
      *)
        echo "Unknown device domain: ''${DEVICE:-<empty>}" >&2
        exit 1
        ;;
    esac

    for unit in "''${UNITS[@]}"; do
      if [ -n "$unit" ] && [ "$unit" != "$TARGET_UNIT" ]; then
        if sudo -n ${pkgs.systemd}/bin/systemctl is-active --quiet "$unit" 2>/dev/null; then
          sudo -n ${pkgs.systemd}/bin/systemctl stop "$unit" 2>/dev/null || true
        fi
      fi
    done
  '';
in {
  options.services.workload-manager = {
    gpuExclusiveUnits = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = gpuExclusiveUnits;
      description = "Eval-time calculated list of mutually exclusive GPU (RDNA 3.5) workload units.";
    };

    npuExclusiveUnits = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = npuExclusiveUnits;
      description = "Eval-time calculated list of mutually exclusive NPU (XDNA 2) workload units.";
    };

    allExclusiveUnits = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = allExclusiveUnits;
      description = "Every exclusive workload unit across both hardware domains.";
    };

    lockFiles = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = {
        gpu = "/run/model-lock/gpu.lock";
        npu = "/run/model-lock/npu.lock";
      };
      description = "Per-domain flock files.";
    };

    stateFiles = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = {
        gpu = "/run/model-lock/active_gpu";
        npu = "/run/model-lock/active_npu";
      };
      description = "Per-domain active workload state files.";
    };

    stopScript = lib.mkOption {
      type = lib.types.package;
      default = stopOtherWorkloadsScript;
      description = "Eval-time generated script stopping active workloads of one domain: <device> <target>.";
    };
  };

  config = {
    # Consolidated passwordless sudo for workload orchestration
    security.sudo.extraRules = [
      {
        users = [
          "gateway"
          "gufo"
          "llama-cpp"
          "kyojin"
          "immich-ml"
          "comfyui"
        ];
        commands = [
          {
            command = "${pkgs.systemd}/bin/systemctl";
            options = [ "NOPASSWD" ];
          }
          {
            command = "/run/current-system/sw/bin/systemctl";
            options = [ "NOPASSWD" ];
          }
          {
            command = "${stopOtherWorkloadsScript}";
            options = [ "NOPASSWD" ];
          }
        ];
      }
    ];

    # Model lock directory and one lock + state file per hardware domain.
    # No legacy `model.lock` / `active_model` symlinks: every reader lives in this repo
    # and a dangling active_model -> active_gpu link would make os.path.exists() report a
    # stale model while the GPU domain is idle.
    systemd.tmpfiles.rules = [
      "d /run/model-lock 0777 root root - -"
      "f /run/model-lock/gpu.lock 0666 root root - -"
      "f /run/model-lock/active_gpu 0666 root root - -"
      "f /run/model-lock/npu.lock 0666 root root - -"
      "f /run/model-lock/active_npu 0666 root root - -"
    ];

    # Mutual systemd Conflicts - strictly intra-domain (Rule 1 per domain).
    systemd.services = {
      immich-machine-learning = lib.mkIf (config.services ? immich-ml && config.services.immich-ml.enable) {
        conflicts = lib.filter (u: u != "immich-machine-learning.service") gpuExclusiveUnits;
      };
      comfyui = lib.mkIf (config.services ? comfyui && config.services.comfyui.enable) {
        conflicts = lib.filter (u: u != "comfyui.service") gpuExclusiveUnits;
      };
    };
  };
}
