{
  config,
  lib,
  pkgs,
  ...
}: let
  # 1. Collect all model units from services.models
  allModelUnits = lib.mapAttrsToList (_: m: m.serviceName) (config.services.models or {});

  # 2. Collect standalone on-demand units
  onDemandUnits =
    (lib.optional (config.services ? immich-ml && config.services.immich-ml.enable) "immich-machine-learning.service")
    ++ (lib.optional (config.services ? comfyui && config.services.comfyui.enable) "comfyui.service");

  # 3. Complete list of all mutually exclusive heavy units calculated at Nix eval time
  allExclusiveUnits = allModelUnits ++ onDemandUnits;

  # 4. Nix eval-time generated script to stop all active heavy workloads other than TARGET_UNIT
  stopOtherWorkloadsScript = pkgs.writeShellScript "stop-other-workloads" ''
    set -euo pipefail

    TARGET_UNIT="''${1:-}"

    # Eval-time calculated list of all exclusive workload units
    ALL_EXCLUSIVE_UNITS=(
      ${lib.concatStringsSep "\n      " (map (u: "\"${u}\"") allExclusiveUnits)}
    )

    for unit in "''${ALL_EXCLUSIVE_UNITS[@]}"; do
      if [ "$unit" != "$TARGET_UNIT" ]; then
        if sudo -n ${pkgs.systemd}/bin/systemctl is-active --quiet "$unit" 2>/dev/null; then
          sudo -n ${pkgs.systemd}/bin/systemctl stop "$unit" 2>/dev/null || true
        fi
      fi
    done
  '';
in {
  options.services.workload-manager = {
    allExclusiveUnits = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = allExclusiveUnits;
      description = "Eval-time calculated list of all mutually exclusive systemd service units.";
    };

    stopScript = lib.mkOption {
      type = lib.types.package;
      default = stopOtherWorkloadsScript;
      description = "Eval-time generated script to stop all active heavy workloads except the target.";
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
          "immich-ml"
          "comfyui"
        ];
        commands = [
          {
            command = "${pkgs.systemd}/bin/systemctl";
            options = ["NOPASSWD"];
          }
          {
            command = "/run/current-system/sw/bin/systemctl";
            options = ["NOPASSWD"];
          }
          {
            command = "${stopOtherWorkloadsScript}";
            options = ["NOPASSWD"];
          }
        ];
      }
    ];

    # Model lock directory and shared state files
    systemd.tmpfiles.rules = [
      "d /run/model-lock 0777 root root - -"
      "f /run/model-lock/model.lock 0666 root root - -"
      "f /run/model-lock/active_model 0666 root root - -"
    ];

    # Mutual systemd Conflicts across ALL exclusive units
    systemd.services = {
      immich-machine-learning = lib.mkIf (config.services ? immich-ml && config.services.immich-ml.enable) {
        conflicts = lib.filter (u: u != "immich-machine-learning.service") allExclusiveUnits;
      };
      comfyui = lib.mkIf (config.services ? comfyui && config.services.comfyui.enable) {
        conflicts = lib.filter (u: u != "comfyui.service") allExclusiveUnits;
      };
    };
  };
}
