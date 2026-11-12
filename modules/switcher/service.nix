{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.services.switcher;

  registryFile = import ./registry.nix {
    inherit lib pkgs;
    models = config.services.models;
    defaultModel = config.services.defaultModel;
  };

  switcherPackage = import ./default.nix {
    inherit lib;
    rustPlatform = pkgs.rustPlatform;
  };
in {
  options.services.switcher = {
    enable = lib.mkEnableOption ''
      the Rust /v1/* model router (replaces the FastCGI switcher.sh CGI script)
    '';

    socketPath = lib.mkOption {
      type = lib.types.str;
      default = "/run/switcher/switcher.sock";
      description = "Unix socket nginx proxies /v1/* to.";
    };

    extraArgs = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "--listen" "tcp:127.0.0.1:8082" ];
      description = "Extra command line arguments for the router.";
    };
  };

  config = lib.mkIf cfg.enable {
    # The router is a long-lived daemon instead of eight preforked CGI workers: an idle accept()
    # costs no CPU at all, which is what keeps an unloaded gateway at zero cycles.
    systemd.services.switcher = {
      description = "Inference model router (/v1/* hot path)";
      after = [ "network.target" ];
      wantedBy = [ "multi-user.target" ];

      serviceConfig = {
        ExecStart = lib.concatStringsSep " " ([
          "${switcherPackage}/bin/switcher"
          "--registry"
          "${registryFile}"
          "--listen"
          "unix:${cfg.socketPath}"
          "--socket-mode"
          "0660"
          "--lock-dir"
          "/run/model-lock"
          "--systemctl"
          "${pkgs.systemd}/bin/systemctl"
          "--sudo"
          "/run/wrappers/bin/sudo"
          "--stop-script"
          "${config.services.workload-manager.stopScript}"
        ]
        ++ cfg.extraArgs);

        User = "gateway";
        Group = "gateway";

        RuntimeDirectory = "switcher";
        Restart = "always";
        RestartSec = "2s";

        # Orchestration only: systemctl + flock + reading tmpfs state.
        NoNewPrivileges = false; # needs sudo -> systemctl
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        LimitNOFILE = 65536;
      };
    };

    # nginx connects as the `gateway` user; the socket group must match.
    systemd.tmpfiles.rules = [
      "d /run/switcher 0755 gateway gateway - -"
    ];
  };
}
