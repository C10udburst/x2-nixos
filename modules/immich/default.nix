{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.services.immich-ml;
  mkWakeScript = import ../on-demand/mkWakeScript.nix {inherit pkgs lib;};

  wakeNetcatScript = mkWakeScript {
    workloadId = "immich-machine-learning";
    serviceName = "immich-machine-learning.service";
    backendPort = cfg.backendPort;
    healthCheckCmd = "${pkgs.curl}/bin/curl -s -f http://127.0.0.1:${toString cfg.backendPort}/ping >/dev/null 2>&1";
    timeoutSec = 60;
    description = "Immich Machine Learning backend";
    stopScript = config.services.workload-manager.stopScript;
  };
in {
  options.services.immich-ml = {
    enable = lib.mkEnableOption "Immich Machine Learning server with dynamic model unloading" // {
      default = true;
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 3003;
      description = "Public Immich ML port exposed to network for incoming requests.";
    };

    backendPort = lib.mkOption {
      type = lib.types.port;
      default = 3004;
      description = "Internal loopback port for immich-machine-learning backend.";
    };

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.immich-machine-learning;
      description = "Immich machine learning package.";
    };

    cacheDir = lib.mkOption {
      type = lib.types.str;
      default = "/var/cache/immich-ml";
      description = "Cache directory for Immich ML models.";
    };

    modelTtl = lib.mkOption {
      type = lib.types.int;
      default = 300;
      description = "TTL in seconds for cached models.";
    };

    environment = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = {};
      description = "Extra environment variables for immich-machine-learning.";
    };
  };

  config = lib.mkIf cfg.enable {
    # System user for Immich ML with direct GPU/APU access
    users.users.immich-ml = {
      isSystemUser = true;
      group = "immich-ml";
      extraGroups = [
        "render"
        "video"
      ];
    };
    users.groups.immich-ml = {};

    # Cache directories
    systemd.tmpfiles.rules = [
      "d ${cfg.cacheDir} 0775 immich-ml immich-ml - -"
    ];

    # 1. Netcat Wake-on-Request Socket on public port (e.g. 3003)
    systemd.sockets.immich-ml-listener = {
      description = "Immich ML Netcat Wake-on-Request Socket";
      wantedBy = ["sockets.target"];
      socketConfig = {
        ListenStream = toString cfg.port;
        Accept = true;
      };
    };

    # 2. Socket-activated connection instance forwarder using netcat
    systemd.services."immich-ml-listener@" = {
      description = "Immich ML Netcat Connection Handler";
      serviceConfig = {
        Type = "simple";
        User = "immich-ml";
        Group = "immich-ml";
        StandardInput = "socket";
        StandardOutput = "socket";
        ExecStart = "${wakeNetcatScript}";
      };
    };

    # 3. Immich ML Backend Service (started on demand, stopped when LLM or ComfyUI is requested)
    systemd.services.immich-machine-learning = {
      description = "Immich Machine Learning Backend Service";
      after = ["network.target"];

      environment = {
        IMMICH_HOST = "127.0.0.1";
        IMMICH_PORT = toString cfg.backendPort;
        MACHINE_LEARNING_HOST = "127.0.0.1";
        MACHINE_LEARNING_PORT = toString cfg.backendPort;
        MACHINE_LEARNING_CACHE_FOLDER = cfg.cacheDir;
        MACHINE_LEARNING_MODEL_TTL = toString cfg.modelTtl;
      } // cfg.environment;

      serviceConfig = {
        Type = "simple";
        User = "immich-ml";
        Group = "immich-ml";
        SupplementaryGroups = [
          "render"
          "video"
        ];
        DeviceAllow = [
          "/dev/kfd rw"
          "/dev/dri/renderD128 rw"
          "/dev/dri/card0 rw"
        ];

        ExecStartPre = [
          "/bin/sh -c '${pkgs.coreutils}/bin/echo immich-machine-learning > /run/model-lock/active_model && ${pkgs.coreutils}/bin/chmod 666 /run/model-lock/active_model'"
        ];
        ExecStart = "${cfg.package}/bin/machine-learning";
        ExecStopPost = [
          "/bin/sh -c 'if [ \"$(${pkgs.coreutils}/bin/cat /run/model-lock/active_model 2>/dev/null)\" = immich-machine-learning ]; then ${pkgs.coreutils}/bin/rm -f /run/model-lock/active_model; fi'"
        ];

        KillSignal = "SIGINT";
        TimeoutStopSec = 15;
        Restart = "no";
        LimitMEMLOCK = "infinity";
        LimitNOFILE = 1048576;
      };
    };

    # Open Immich ML public port in firewall
    networking.firewall.allowedTCPPorts = [cfg.port];
  };
}
