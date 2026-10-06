{
  config,
  lib,
  pkgs,
  inputs ? {},
  ...
}: let
  cfg = config.services.gufo;

  # Native gufo package from inputs.gufo or fallback to pkgs.gufo
  defaultGufoPkg =
    if inputs ? gufo && inputs.gufo ? packages
    then inputs.gufo.packages.${pkgs.system}.default
    else pkgs.gufo or null;

  # Shell launcher for each model service
  mkModelLauncher = name: m:
    pkgs.writeShellScript "gufo-run-${name}" ''
      set -euo pipefail

      TARGET_PATH="${cfg.modelsDir}/${m.modelPath}"

      # Resolve first shard if modelPath is a directory
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

      echo "Launching Gufo with model: $FIRST_SHARD"

      ARGS=(
        serve
        --host 127.0.0.1
        --port "${toString cfg.backendPort}"
        --sessions "${toString m.sessions}"
        llm
        --model "$FIRST_SHARD"
        --served-model-name "${m.alias}"
        --context "${toString m.context}"
      )

      ${lib.optionalString (m.mmprojPath != null) ''
        MMPROJ_PATH="${cfg.modelsDir}/${m.mmprojPath}"
        if [ ! -f "$MMPROJ_PATH" ] && [ -f "${m.mmprojPath}" ]; then
          MMPROJ_PATH="${m.mmprojPath}"
        fi
        ARGS+=(--mmproj "$MMPROJ_PATH")
      ''}

      ${lib.optionalString (m.speculative != null) ''
        ARGS+=(--speculative "${m.speculative}")
      ''}

      ${lib.optionalString (m.mtpModelPath != null) ''
        MTP_PATH="${cfg.modelsDir}/${m.mtpModelPath}"
        if [ ! -f "$MTP_PATH" ] && [ -f "${m.mtpModelPath}" ]; then
          MTP_PATH="${m.mtpModelPath}"
        fi
        ARGS+=(--mtp-model "$MTP_PATH")
      ''}

      ${lib.optionalString (m.draftModelPath != null) ''
        DRAFT_PATH="${cfg.modelsDir}/${m.draftModelPath}"
        if [ ! -f "$DRAFT_PATH" ] && [ -f "${m.draftModelPath}" ]; then
          DRAFT_PATH="${m.draftModelPath}"
        fi
        ARGS+=(--draft-model "$DRAFT_PATH")
      ''}

      ${lib.concatMapStringsSep "\n" (arg: "ARGS+=(${lib.escapeShellArg arg})") m.extraArgs}

      exec ${cfg.package}/bin/gufo "''${ARGS[@]}"
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
        description = "Gufo LLM Service: ${name} (${m.description})";
        after = ["network.target"];
        conflicts = otherModelUnits; # Systemd enforces single active model in VRAM
        wantedBy = lib.optional (cfg.defaultModel == name) "multi-user.target";

        environment = m.env;

        serviceConfig = {
          Type = "simple";
          User = "gufo";
          Group = "gufo";
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
            "${pkgs.coreutils}/bin/mkdir -p /run/gufo"
            "${pkgs.coreutils}/bin/sh -c '${pkgs.coreutils}/bin/echo ${lib.escapeShellArg name} > /run/gufo/active_model'"
          ];
          ExecStart = "${launcher}";
          ExecStopPost = [
            "${pkgs.coreutils}/bin/rm -f /run/gufo/active_model"
          ];

          KillSignal = "SIGINT";
          TimeoutStopSec = 10;
          Restart = "no";
          LimitMEMLOCK = "infinity";
          LimitNOFILE = 1048576;
        };
      }
  ) cfg.models;
in {
  options.services.gufo = {
    enable = lib.mkEnableOption "Gufo native LLM inference systemd services";

    package = lib.mkOption {
      type = lib.types.package;
      default = defaultGufoPkg;
      description = "Gufo engine package (defaults to github:gufo-org/gufo flake output).";
    };

    backendPort = lib.mkOption {
      type = lib.types.port;
      default = 8081;
      description = "Internal loopback port for the active Gufo service.";
    };

    modelsDir = lib.mkOption {
      type = lib.types.str;
      default = "/srv/models";
      description = "Host directory containing GGUF model files.";
    };

    defaultModel = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Model to start on system boot. If null, remains idle with 0 VRAM used.";
    };

    models = lib.mkOption {
      type = lib.types.attrsOf (
        lib.types.submodule ({name, ...}: {
          options = {
            name = lib.mkOption {
              type = lib.types.str;
              default = name;
              description = "Model name identifier.";
            };
            alias = lib.mkOption {
              type = lib.types.str;
              default = name;
              description = "Model alias exposed over OpenAI API.";
            };
            description = lib.mkOption {
              type = lib.types.str;
              default = "";
              description = "Human-readable description for dashboard.";
            };
            modelPath = lib.mkOption {
              type = lib.types.str;
              description = "Relative path under modelsDir or directory containing shards.";
            };
            mmprojPath = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
              description = "Optional path to multimodal vision projector GGUF.";
            };
            speculative = lib.mkOption {
              type = lib.types.nullOr (lib.types.enum ["mtp" "draft" "dspark" "dflash2"]);
              default = null;
              description = "Speculative decoding mode.";
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
              description = "Environment variables for this model service.";
            };
          };
        })
      );
      default = {};
      description = "Declarative list of models.";
    };
  };

  config = lib.mkIf cfg.enable {
    # System user for gufo with direct hardware access
    users.users.gufo = {
      isSystemUser = true;
      group = "gufo";
      extraGroups = [
        "render"
        "video"
      ];
    };
    users.groups.gufo = {};

    # Systemd model services
    systemd.services = modelServices;

    # Ensure models and runtime directories exist
    systemd.tmpfiles.rules = [
      "d /run/gufo 0775 gufo gufo - -"
      "d ${cfg.modelsDir} 0775 gufo gufo - -"
    ];
  };
}
