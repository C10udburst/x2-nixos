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
    else
      let
        versions = import "${inputs.comfyui-nix}/nix/versions.nix";
        pythonOverrides = import "${inputs.comfyui-nix}/nix/python-overrides.nix" {
          inherit pkgs versions;
          gpuSupport = "rocm";
        };
        comfyPackages = import "${inputs.comfyui-nix}/nix/packages.nix" {
          inherit pkgs versions pythonOverrides;
          lib = pkgs.lib;
          gpuSupport = "rocm";
        };
      in
        comfyPackages.default;

  launcher = pkgs.writeShellScript "comfyui-launcher" ''
    set -euo pipefail

    export LD_PRELOAD="${pkgs.rocmPackages.rocm-runtime}/lib/libhsa-runtime64.so''${LD_PRELOAD:+:$LD_PRELOAD}"
    export PATH="${pkgs.rocmPackages.rocminfo}/bin:$PATH"

    mkdir -p "${cfg.dataDir}"/{models,custom_nodes,input,output}
    cd "${cfg.dataDir}"

    ${lib.optionalString (cfg.command != null) ''
      exec ${cfg.command}
    ''}

    exec ${comfyuiPkg}/bin/comfy-ui \
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
    description = "ComfyUI ROCm backend";
    stopScript = config.services.workload-manager.stopScript;
  };
in {
  disabledModules = ["services/misc/comfyui.nix"];

  options.services.comfyui = {
    enable = lib.mkEnableOption "ComfyUI with dynamic ROCm workload unloading" // {
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

    package = lib.mkOption {
      type = lib.types.nullOr lib.types.package;
      default = null;
      description = "ComfyUI ROCm package override. Defaults to comfyui-nix.packages.rocm.";
    };

    command = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Custom command to start ComfyUI. If null, comfy-ui binary is used.";
    };

    extraArgs = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = ["--preview-method" "auto"];
      description = "Extra CLI arguments to pass to ComfyUI.";
    };

    environment = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = {};
      description = "Extra environment variables for ComfyUI.";
    };

    timeoutSec = lib.mkOption {
      type = lib.types.int;
      default = 60;
      description = "Timeout in seconds to wait for ComfyUI backend to become responsive.";
    };
  };

  config = lib.mkIf cfg.enable {
    # System user for ComfyUI with direct APU/GPU access
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

    # 2. Socket-activated connection instance forwarder
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

    # 3. ComfyUI Backend Service (started on demand, stopped when other heavy workloads request VRAM)
    systemd.services.comfyui = {
      description = "ComfyUI Generative AI Backend Service (ROCm gfx1151)";
      after = ["network.target"];

      path = [
        pkgs.rocmPackages.rocminfo
      ];

      environment = {
        COMFYUI_HOST = "127.0.0.1";
        COMFYUI_PORT = toString cfg.backendPort;
        # AMD Ryzen AI Max+ 395 (gfx1151 RDNA 3.5 APU) settings
        HSA_OVERRIDE_GFX_VERSION = "11.5.1";
        HIP_VISIBLE_DEVICES = "0";
        LD_PRELOAD = "${pkgs.rocmPackages.rocm-runtime}/lib/libhsa-runtime64.so";
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
          "/bin/sh -c '${pkgs.coreutils}/bin/echo comfyui > /run/model-lock/active_model && ${pkgs.coreutils}/bin/chmod 666 /run/model-lock/active_model'"
        ];
        ExecStart = "${launcher}";
        ExecStopPost = [
          "/bin/sh -c 'if [ \"$(${pkgs.coreutils}/bin/cat /run/model-lock/active_model 2>/dev/null)\" = comfyui ]; then ${pkgs.coreutils}/bin/rm -f /run/model-lock/active_model; fi'"
        ];

        KillSignal = "SIGINT";
        TimeoutStopSec = 15;
        Restart = "no";
        LimitMEMLOCK = "infinity";
        LimitNOFILE = 1048576;
      };
    };

    networking.firewall.allowedTCPPorts = [cfg.port];
  };
}
