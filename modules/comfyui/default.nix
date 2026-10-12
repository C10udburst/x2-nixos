{
  config,
  lib,
  pkgs,
  inputs ? {},
  ...
}: let
  cfg = config.services.comfyui;
  mkWakeScript = import ../on-demand/mkWakeScript.nix {inherit pkgs lib;};

  comfyuiPkg =
    if cfg.package != null
    then cfg.package
    else if inputs ? comfyui-nix && inputs.comfyui-nix ? packages
    then
      (
        if cfg.gpuSupport == "rocm"
        then inputs.comfyui-nix.packages.${pkgs.system}.rocm
        else if cfg.gpuSupport == "cuda"
        then inputs.comfyui-nix.packages.${pkgs.system}.cuda
        else inputs.comfyui-nix.packages.${pkgs.system}.default
      )
    else pkgs.comfyui;

  launcher = pkgs.writeShellScript "comfyui-launcher" ''
    set -euo pipefail

    mkdir -p "${cfg.dataDir}"
    mkdir -p "${cfg.dataDir}/models" "${cfg.dataDir}/custom_nodes" "${cfg.dataDir}/input" "${cfg.dataDir}/output"
    cd "${cfg.dataDir}"

    ${lib.optionalString (cfg.command != null) ''
      echo "Launching ComfyUI via custom command..."
      exec ${cfg.command}
    ''}

    COMFY_BIN="${comfyuiPkg}/bin/comfy-ui"
    if [ ! -x "$COMFY_BIN" ]; then
      COMFY_BIN="${lib.getExe comfyuiPkg}"
    fi

    echo "Launching ComfyUI (${cfg.gpuSupport}) on 127.0.0.1:${toString cfg.backendPort}..."
    exec "$COMFY_BIN" \
      --listen 127.0.0.1 \
      --port "${toString cfg.backendPort}" \
      --base-directory "${cfg.dataDir}" \
      ${lib.escapeShellArgs cfg.extraArgs}
  '';

  wakeNetcatScript = mkWakeScript {
    workloadId = "comfyui";
    serviceName = "comfyui.service";
    backendPort = cfg.backendPort;
    healthCheckCmd = "${pkgs.curl}/bin/curl -s -f http://127.0.0.1:${toString cfg.backendPort}/ >/dev/null 2>&1";
    timeoutSec = cfg.timeoutSec;
    description = "ComfyUI backend";
    stopScript = config.services.workload-manager.stopScript;
  };
in {
  disabledModules = ["services/misc/comfyui.nix"];

  options.services.comfyui = {
    enable = lib.mkEnableOption "ComfyUI with dynamic workload unloading" // {
      default = true;
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 8188;
      description = "Public ComfyUI port exposed to network for incoming requests.";
    };

    backendPort = lib.mkOption {
      type = lib.types.port;
      default = 8189;
      description = "Internal loopback port for ComfyUI backend.";
    };

    dataDir = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/comfyui";
      description = "Working and data directory for ComfyUI.";
    };

    gpuSupport = lib.mkOption {
      type = lib.types.enum ["rocm" "cuda" "cpu"];
      default = "rocm";
      description = "GPU acceleration backend from comfyui-nix flake (rocm for AMD APU).";
    };

    package = lib.mkOption {
      type = lib.types.nullOr lib.types.package;
      default = null;
      description = "ComfyUI package. If null, automatically resolved from comfyui-nix flake.";
    };

    command = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Custom command to start ComfyUI. If null, automated launcher is used.";
    };

    extraArgs = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = ["--preview-method" "auto"];
      description = "Extra CLI arguments to pass to ComfyUI.";
    };

    environment = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = {
        HSA_OVERRIDE_GFX_VERSION = "11.5.1";
        ROCM_PATH = "/run/current-system/sw";
        HIP_VISIBLE_DEVICES = "0";
      };
      description = "Environment variables for ComfyUI (e.g. ROCm gfx1151 overrides for Ryzen AI Max+ 395).";
    };

    timeoutSec = lib.mkOption {
      type = lib.types.int;
      default = 60;
      description = "Timeout in seconds to wait for ComfyUI backend to become responsive.";
    };
  };

  config = lib.mkIf cfg.enable {
    # System user for ComfyUI with direct GPU/APU access
    users.users.comfyui = {
      isSystemUser = true;
      group = "comfyui";
      home = cfg.dataDir;
      createHome = true;
      extraGroups = [
        "render"
        "video"
      ];
    };
    users.groups.comfyui = {};

    # Cache & state directories
    systemd.tmpfiles.rules = [
      "d ${cfg.dataDir} 0775 comfyui comfyui - -"
    ];

    # 1. Netcat Wake-on-Request Socket on public port (8188)
    systemd.sockets.comfyui-listener = {
      description = "ComfyUI Netcat Wake-on-Request Socket";
      wantedBy = ["sockets.target"];
      socketConfig = {
        ListenStream = toString cfg.port;
        Accept = true;
      };
    };

    # 2. Socket-activated connection instance forwarder using netcat
    systemd.services."comfyui-listener@" = {
      description = "ComfyUI Netcat Connection Handler";
      serviceConfig = {
        Type = "simple";
        User = "comfyui";
        Group = "comfyui";
        StandardInput = "socket";
        StandardOutput = "socket";
        ExecStart = "${wakeNetcatScript}";
      };
    };

    # 3. ComfyUI Backend Service (started on demand, stopped when LLM or Immich is requested)
    systemd.services.comfyui = {
      description = "ComfyUI Generative AI Backend Service";
      after = ["network.target"];

      environment = {
        COMFYUI_HOST = "127.0.0.1";
        COMFYUI_PORT = toString cfg.backendPort;
      } // cfg.environment;

      serviceConfig = {
        Type = "simple";
        User = "comfyui";
        Group = "comfyui";
        SupplementaryGroups = [
          "render"
          "video"
        ];
        WorkingDirectory = cfg.dataDir;
        DeviceAllow = [
          "/dev/kfd rw"
          "/dev/dri/renderD128 rw"
          "/dev/dri/card0 rw"
        ];

        ExecStartPre = [
          "${pkgs.coreutils}/bin/sh -c '${pkgs.coreutils}/bin/echo comfyui > /run/model-lock/active_model'"
        ];
        ExecStart = "${launcher}";
        ExecStopPost = [
          "${pkgs.coreutils}/bin/sh -c 'if [ \"$(${pkgs.coreutils}/bin/cat /run/model-lock/active_model 2>/dev/null)\" = comfyui ]; then ${pkgs.coreutils}/bin/rm -f /run/model-lock/active_model; fi'"
        ];

        KillSignal = "SIGINT";
        TimeoutStopSec = 15;
        Restart = "no";
        LimitMEMLOCK = "infinity";
        LimitNOFILE = 1048576;
      };
    };

    # Open ComfyUI public port in firewall
    networking.firewall.allowedTCPPorts = [cfg.port];
  };
}
