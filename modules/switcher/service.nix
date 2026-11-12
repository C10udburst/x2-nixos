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
  # NOTE: everything above this `in` is one `let` block (package, registry, lockDir).
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

  # Single source of truth for where locks and per-domain state files live. It appears three
  # times that must never disagree: the --lock-dir argument, the ReadWritePaths hole punched in
  # the sandbox, and the tmpfiles entries in modules/workload-manager.nix.
  lockDir = "/run/model-lock";

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
          lockDir
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

        # ProtectSystem=strict makes /run read-only, and RuntimeDirectory= only re-writes its own
        # subdirectory (/run/switcher). Without this the router cannot open `<device>.lock` for
        # writing nor update `active_<device>`, so every request that actually needs a workload
        # switch fails with EROFS while the already-resident fast path keeps working - which is
        # exactly the split behaviour seen when switching to a model that is not loaded yet.
        # The directory itself is created by modules/workload-manager.nix's tmpfiles rules.
        ReadWritePaths = [ lockDir ];
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
