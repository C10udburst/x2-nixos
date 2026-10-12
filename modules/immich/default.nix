{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.services.immich-ml;

  wakeNetcatScript = pkgs.writeShellScript "immich-wake-netcat" ''
    set -euo pipefail

    LOCK_FILE="/run/model-lock/model.lock"
    STATE_FILE="/run/model-lock/active_model"
    BACKEND_PORT="${toString cfg.backendPort}"

    # 1. Acquire independent model lock
    exec 9>"$LOCK_FILE"
    flock -x 9

    # 2. Check if immich-machine-learning is already the active workload
    ACTIVE=$(cat "$STATE_FILE" 2>/dev/null || true)
    if [ "$ACTIVE" != "immich-machine-learning" ]; then
      # Stop any currently active LLM services (gufo or llama-cpp)
      for u in $(systemctl list-units --type=service --state=running --no-legend "gufo-*" "llama-cpp-*" 2>/dev/null | awk '{print $1}'); do
        sudo -n systemctl stop "$u" 2>/dev/null || true
      done

      # Start Immich Machine Learning backend service
      sudo -n systemctl start immich-machine-learning.service

      # Wait for Immich ML backend to become responsive
      DEADLINE=$(( $(date +%s) + 60 ))
      READY=0
      while [ "$(date +%s)" -lt "$DEADLINE" ]; do
        if ${pkgs.curl}/bin/curl -s -f "http://127.0.0.1:''${BACKEND_PORT}/ping" >/dev/null 2>&1; then
          READY=1
          echo "immich-machine-learning" > "$STATE_FILE"
          break
        fi
        sleep 0.2
      done

      if [ "$READY" -eq 0 ]; then
        flock -u 9
        printf "HTTP/1.1 504 Gateway Timeout\r\n"
        printf "Content-Type: text/plain\r\n"
        printf "Connection: close\r\n\r\n"
        printf "Immich Machine Learning backend startup timed out\n"
        exit 0
      fi
    fi
    flock -u 9

    # 3. Transparently forward incoming connection to Immich ML backend using netcat
    exec ${pkgs.netcat-openbsd}/bin/nc 127.0.0.1 "$BACKEND_PORT"
  '';
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

    # Allow immich-ml user to start/stop services via systemctl for swapping
    security.sudo.extraRules = [
      {
        users = ["immich-ml"];
        commands = [
          {
            command = "${pkgs.systemd}/bin/systemctl";
            options = ["NOPASSWD"];
          }
          {
            command = "/run/current-system/sw/bin/systemctl";
            options = ["NOPASSWD"];
          }
        ];
      }
    ];

    # Cache & lock directories
    systemd.tmpfiles.rules = [
      "d ${cfg.cacheDir} 0775 immich-ml immich-ml - -"
      "d /run/model-lock 0777 root root - -"
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

    # 3. Immich ML Backend Service (started on demand, stopped when LLM is requested)
    systemd.services.immich-machine-learning = {
      description = "Immich Machine Learning Backend Service";
      after = ["network.target"];

      environment = {
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
          "${pkgs.coreutils}/bin/sh -c '${pkgs.coreutils}/bin/echo immich-machine-learning > /run/model-lock/active_model'"
        ];
        ExecStart = "${cfg.package}/bin/machine-learning";
        ExecStopPost = [
          "${pkgs.coreutils}/bin/sh -c 'if [ \"$(${pkgs.coreutils}/bin/cat /run/model-lock/active_model 2>/dev/null)\" = immich-machine-learning ]; then ${pkgs.coreutils}/bin/rm -f /run/model-lock/active_model; fi'"
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
