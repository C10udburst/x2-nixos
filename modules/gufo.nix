{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.services.gufo;

  # Serialized models metadata for switcher.py
  modelsConfig = {
    backend_port = cfg.backendPort;
    default_model = cfg.defaultModel;
    models = lib.mapAttrs (name: m: {
      alias = m.alias;
      description = m.description;
      context = m.context;
      speculative = m.speculative;
      systemd_unit = "gufo-${name}.service";
    }) cfg.models;
  };

  modelsJsonFile = pkgs.writeText "gufo-models.json" (builtins.toJSON modelsConfig);
  dashboardHtmlFile = ./dashboard.html;
  switcherPyFile = ./switcher.py;

  # Launcher script wrapper for each model
  mkModelLauncher = name: m:
    pkgs.writeShellScript "gufo-run-${name}" ''
      set -euo pipefail

      HOST_MODELS_DIR="${cfg.modelsDir}"
      TARGET_PATH="${cfg.modelsDir}/${m.modelPath}"

      # 1. Resolve first shard
      if [ -d "$TARGET_PATH" ]; then
        FIRST_SHARD=$(${pkgs.findutils}/bin/find "$TARGET_PATH" -maxdepth 1 -type f -name "*.gguf" | ${pkgs.coreutils}/bin/sort | ${pkgs.coreutils}/bin/head -n 1)
        if [ -z "$FIRST_SHARD" ]; then
          echo "Error: No .gguf model found in $TARGET_PATH" >&2
          exit 1
        fi
      elif [ -f "$TARGET_PATH" ]; then
        FIRST_SHARD="$TARGET_PATH"
      elif [ -f "${m.modelPath}" ]; then
        FIRST_SHARD="${m.modelPath}"
      else
        echo "Error: Model path $TARGET_PATH does not exist!" >&2
        exit 1
      fi

      REL_MODEL_PATH="''${FIRST_SHARD#"''${HOST_MODELS_DIR}/"}"
      CONTAINER_MODEL_PATH="/models/''${REL_MODEL_PATH}"

      echo "Resolved model: ''${CONTAINER_MODEL_PATH}"

      ARGS=(
        gufo serve
        --host 0.0.0.0
        --port 8080
        llm
        --alias "${m.alias}"
        --model "''${CONTAINER_MODEL_PATH}"
        --sessions "${toString m.sessions}"
        --context "${toString m.context}"
      )

      ${lib.optionalString (m.mmprojPath != null) ''
        REL_MMPROJ="${m.mmprojPath}"
        REL_MMPROJ="''${REL_MMPROJ#"''${HOST_MODELS_DIR}/"}"
        ARGS+=(--mmproj "/models/''${REL_MMPROJ}")
      ''}

      ${lib.optionalString (m.speculative != null) ''
        ARGS+=(--speculative "${m.speculative}")
      ''}

      ${lib.optionalString (m.mtpModelPath != null) ''
        REL_MTP="${m.mtpModelPath}"
        REL_MTP="''${REL_MTP#"''${HOST_MODELS_DIR}/"}"
        ARGS+=(--mtp-model "/models/''${REL_MTP}")
      ''}

      ${lib.optionalString (m.draftModelPath != null) ''
        REL_DRAFT="${m.draftModelPath}"
        REL_DRAFT="''${REL_DRAFT#"''${HOST_MODELS_DIR}/"}"
        ARGS+=(--draft-model "/models/''${REL_DRAFT}")
      ''}

      ${lib.concatMapStringsSep "\n" (arg: "ARGS+=(${lib.escapeShellArg arg})") m.extraArgs}

      # Clean up any leftover active container
      ${pkgs.podman}/bin/podman rm -f "gufo-active" 2>/dev/null || true

      # Exec podman container with ROCm / KFD hardware access
      exec ${pkgs.podman}/bin/podman run --rm \
        --name "gufo-active" \
        --device /dev/kfd \
        --device /dev/dri \
        --group-add keep-groups \
        --ulimit memlock=-1 \
        -p 127.0.0.1:${toString cfg.backendPort}:8080 \
        -v "''${HOST_MODELS_DIR}:/models:ro" \
        ${lib.concatStringsSep " " (lib.mapAttrsToList (k: v: "-e ${lib.escapeShellArg "${k}=${v}"}") m.env)} \
        "${cfg.containerImage}" \
        "''${ARGS[@]}"
    '';

  # Generate systemd services for all defined models
  modelServices = lib.mapAttrs' (
    name: m: let
      otherModelUnits = lib.mapAttrsToList (
        otherName: _: "gufo-${otherName}.service"
      ) (lib.filterAttrs (n: _: n != name) cfg.models);
      launcher = mkModelLauncher name m;
    in
      lib.nameValuePair "gufo-${name}" {
        description = "Gufo LLM Model: ${name} (${m.description})";
        after = ["network.target"];
        conflicts = otherModelUnits; # Systemd automatically stops any other model before starting this one!
        wantedBy = lib.optional (cfg.defaultModel == name) "multi-user.target";

        serviceConfig = {
          Type = "simple";
          User = "root";
          ExecStartPre = [
            "${pkgs.coreutils}/bin/mkdir -p /run/gufo"
            "${pkgs.coreutils}/bin/sh -c '${pkgs.coreutils}/bin/echo ${lib.escapeShellArg name} > /run/gufo/active_model'"
            "${pkgs.podman}/bin/podman rm -f gufo-active 2>/dev/null || true"
          ];
          ExecStart = "${launcher}";
          ExecStop = "${pkgs.podman}/bin/podman stop -t 5 gufo-active";
          ExecStopPost = [
            "${pkgs.podman}/bin/podman rm -f gufo-active 2>/dev/null || true"
            "${pkgs.coreutils}/bin/rm -f /run/gufo/active_model"
          ];
          Restart = "no";
          LimitMEMLOCK = "infinity";
          LimitNOFILE = 1048576;
        };
      }
  ) cfg.models;

  # FastCGI wrapper script executed by fcgiwrap
  fcgiScript = pkgs.writeShellScript "gufo-fcgi-gateway" ''
    export GUFO_CONFIG_PATH="${modelsJsonFile}"
    export GUFO_DASHBOARD_HTML="${dashboardHtmlFile}"
    export SYSTEMCTL="${pkgs.systemd}/bin/systemctl"
    exec ${pkgs.python3}/bin/python3 ${switcherPyFile} "$@"
  '';
in {
  options.services.gufo = {
    enable = lib.mkEnableOption "Gufo LLM inference service and FastCGI switcher gateway";

    port = lib.mkOption {
      type = lib.types.port;
      default = 8080;
      description = "Public port for the web dashboard and OpenAI-compatible API.";
    };

    backendPort = lib.mkOption {
      type = lib.types.port;
      default = 8081;
      description = "Internal loopback port for the active Gufo model container.";
    };

    modelsDir = lib.mkOption {
      type = lib.types.str;
      default = "/srv/models";
      description = "Directory on the host containing GGUF model files.";
    };

    containerImage = lib.mkOption {
      type = lib.types.str;
      default = "ghcr.io/gufo-org/toolboxes/gufo-runtime:latest";
      description = "Gufo OCI runtime container image.";
    };

    defaultModel = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Model to start automatically on boot. If null, starts idle (0 VRAM).";
    };

    models = lib.mkOption {
      type = lib.types.attrsOf (
        lib.types.submodule ({name, ...}: {
          options = {
            name = lib.mkOption {
              type = lib.types.str;
              default = name;
              description = "Unique identifier for this model.";
            };
            alias = lib.mkOption {
              type = lib.types.str;
              default = name;
              description = "OpenAI API alias passed to gufo serve.";
            };
            description = lib.mkOption {
              type = lib.types.str;
              default = "";
              description = "Short human-readable description for dashboard.";
            };
            modelPath = lib.mkOption {
              type = lib.types.str;
              description = "Relative path under modelsDir or directory containing shards.";
            };
            mmprojPath = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
              description = "Optional path to multimodal projector (mmproj) GGUF.";
            };
            speculative = lib.mkOption {
              type = lib.types.nullOr (lib.types.enum ["mtp" "draft"]);
              default = null;
              description = "Speculative decoding mode (e.g. 'mtp' or 'draft').";
            };
            mtpModelPath = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
              description = "Path to MTP draft model GGUF.";
            };
            draftModelPath = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
              description = "Path to draft model GGUF.";
            };
            context = lib.mkOption {
              type = lib.types.int;
              default = 65536;
              description = "Context length tokens.";
            };
            sessions = lib.mkOption {
              type = lib.types.int;
              default = 1;
              description = "Number of parallel sessions.";
            };
            extraArgs = lib.mkOption {
              type = lib.types.listOf lib.types.str;
              default = [];
              description = "Extra CLI arguments passed to gufo serve.";
            };
            env = lib.mkOption {
              type = lib.types.attrsOf lib.types.str;
              default = {};
              description = "Extra environment variables passed to the container (e.g. HSA_OVERRIDE_GFX_VERSION).";
            };
          };
        })
      );
      default = {};
      description = "Declarative list of models available for serving and dynamic switching.";
    };
  };

  config = lib.mkIf cfg.enable {
    # Podman container runtime for Gufo
    virtualisation.podman = {
      enable = true;
      defaultNetwork.settings.dns_enabled = true;
    };

    # Hardware acceleration & ROCm permissions
    hardware.graphics.enable = true;

    # Service user for fcgiwrap gateway
    users.users.gufo = {
      isSystemUser = true;
      group = "gufo";
      extraGroups = ["render" "video"];
    };
    users.groups.gufo = {};

    # Allow gufo user passwordless sudo strictly for systemctl commands
    security.sudo.extraRules = [
      {
        users = ["gufo"];
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

    # Register each model as a separate, mutually exclusive systemd service
    systemd.services = modelServices;

    # Ensure runtime directories exist
    systemd.tmpfiles.rules = [
      "d /run/gufo 0775 gufo gufo - -"
      "d ${cfg.modelsDir} 0775 root root - -"
    ];

    # Bare-minimal fcgiwrap instance (~1MB memory)
    services.fcgiwrap.instances.gufo = {
      process.user = "gufo";
      process.group = "gufo";
      socket = {
        type = "unix";
        address = "/run/fcgiwrap-gufo.sock";
        user = "nginx";
        group = "nginx";
        mode = "0660";
      };
    };

    # Bare-minimal Nginx reverse proxy / FastCGI front (~3MB memory)
    services.nginx = {
      enable = true;
      recommendedOptimisation = true;
      recommendedGzipSettings = false; # Do not buffer or gzip SSE token streams!

      virtualHosts."gufo" = {
        default = true;
        listen = [
          {
            addr = "0.0.0.0";
            port = cfg.port;
          }
        ];

        locations."= /" = {
          alias = "${dashboardHtmlFile}";
          extraConfig = ''
            default_type text/html;
          '';
        };

        locations."= /index.html" = {
          alias = "${dashboardHtmlFile}";
          extraConfig = ''
            default_type text/html;
          '';
        };

        locations."/" = {
          extraConfig = ''
            fastcgi_pass unix:/run/fcgiwrap-gufo.sock;
            include ${pkgs.nginx}/conf/fastcgi_params;
            fastcgi_param SCRIPT_FILENAME ${fcgiScript};
            fastcgi_buffering off;
            fastcgi_read_timeout 600s;
            fastcgi_send_timeout 600s;
            client_max_body_size 100M;
          '';
        };
      };
    };

    # Open firewall port
    networking.firewall.allowedTCPPorts = [cfg.port];
  };
}
