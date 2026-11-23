{
  pkgs,
  lib,
  config,
  inputs ? {},
  ...
}: {
  modelId ? name,
  name ? null,
  modelPath,
  remappedModel ? modelId,
  description ? "",
  context ? null,
  sessions ? 1,
  port ? (config.services.gufo.backendPort or 8081),
  modelsDir ? (config.services.gufo.modelsDir or "/srv/models"),
  package ? null,
  # Engine modality -> the `gufo serve <kind>` subcommand and the on-disk shape it expects:
  #   llm    a GGUF (or a directory of shards) behind /v1/chat/completions
  #   image  a Qwen-Image Diffusers snapshot behind /v1/images/generations and /v1/images/edits
  # Plain attr set rather than an enum, so a new modality upstream is one branch here.
  kind ? "llm",
  # Extra public names the engine answers to besides `remappedModel` (which is the primary
  # `--served-model-name`; these are appended as aliases).
  aliases ? [],
  # Dashboard / /v1/models discovery tags only; the switcher ignores them entirely.
  capabilities ? null,
  mmprojPath ? null,
  speculative ? null,
  draftTokens ? null,
  mtpModelPath ? null,
  draftModelPath ? null,
  dflashModelPath ? (
    if speculative == "dflash2"
    then draftModelPath
    else null
  ),
  dsparkModelPath ? (
    if speculative == "dspark"
    then draftModelPath
    else null
  ),
  extraArgs ? [],
  env ? {},
}: let
  kinds = {
    llm = "llm";
    image = "image";
  };

  # Read through the set, so an unknown modality throws here - with the list of known ones -
  # rather than silently taking the text branch.
  kindArg =
    kinds.${kind}
    or (throw "mkGufo: unknown kind '${kind}' (known: ${lib.concatStringsSep ", " (lib.attrNames kinds)})");

  imageMode = kindArg == "image";

  defaultCapabilities = {
    llm = [ ];
    image = [ "images" ];
  };

  gufoPkg =
    if package != null
    then package
    else if inputs ? gufo && inputs.gufo ? packages
    then inputs.gufo.packages.${pkgs.system}.default
    else pkgs.gufo or null;

  defaultEnv = {
    HSA_OVERRIDE_GFX_VERSION = "11.5.1";
    HIP_VISIBLE_DEVICES = "0";
  };

  launcher = pkgs.writeShellScript "gufo-run-${modelId}" ''
    set -euo pipefail

    TARGET_PATH="${modelsDir}/${modelPath}"

    ${
      if imageMode then
        ''
        # A Diffusers snapshot, not a GGUF: the engine wants the *directory* that holds
        # model_index.json (transformer/, vae/, text_encoder/, processor/, scheduler/), and
        # it maps the safetensors instead of reading them, so nothing is known to fail until
        # a request arrives. Check the layout here, where the journal says why.
        if [ ! -d "$TARGET_PATH" ] && [ -d "${modelPath}" ]; then
          TARGET_PATH="${modelPath}"
        fi
        if [ ! -f "$TARGET_PATH/model_index.json" ]; then
          echo "Error: $TARGET_PATH is no Qwen-Image snapshot (model_index.json missing)" >&2
          exit 1
        fi

        echo "Launching Gufo image service with snapshot: $TARGET_PATH (served as: ${remappedModel})"

        # No --sessions: the image server has no slot pool to preallocate (it serializes
        # generations behind its own gate) and rejects the flag as unknown.
        ARGS=(
          serve
          --host 127.0.0.1
          --port "${toString port}"
          image
          --model "$TARGET_PATH"
          --served-model-name "${remappedModel}"
        )
        ''
      else
        ''
        if [ -d "$TARGET_PATH" ]; then
          FIRST_SHARD=$(${pkgs.findutils}/bin/find "$TARGET_PATH" -maxdepth 1 -type f -name "*.gguf" ! -iname "*dflash*" ! -iname "*dspark*" ! -iname "*mtp*" ! -iname "*mmproj*" | ${pkgs.coreutils}/bin/sort | ${pkgs.coreutils}/bin/head -n 1)
          if [ -z "$FIRST_SHARD" ]; then
            FIRST_SHARD=$(${pkgs.findutils}/bin/find "$TARGET_PATH" -maxdepth 1 -type f -name "*.gguf" | ${pkgs.coreutils}/bin/sort | ${pkgs.coreutils}/bin/head -n 1)
          fi
          if [ -z "$FIRST_SHARD" ]; then
            echo "Error: No .gguf model found in $TARGET_PATH" >&2
            exit 1
          fi
        elif [ -f "$TARGET_PATH" ]; then
          FIRST_SHARD="$TARGET_PATH"
        elif [ -f "${modelPath}" ]; then
          FIRST_SHARD="${modelPath}"
        elif [ -d "$(dirname "$TARGET_PATH")" ] && [ -n "$(${pkgs.findutils}/bin/find "$(dirname "$TARGET_PATH")" -maxdepth 1 -type f -name "*.gguf" 2>/dev/null | ${pkgs.coreutils}/bin/head -n 1)" ]; then
          FIRST_SHARD=$(${pkgs.findutils}/bin/find "$(dirname "$TARGET_PATH")" -maxdepth 1 -type f -name "*.gguf" ! -iname "*dflash*" ! -iname "*dspark*" ! -iname "*mtp*" ! -iname "*mmproj*" 2>/dev/null | ${pkgs.coreutils}/bin/sort | ${pkgs.coreutils}/bin/head -n 1)
        else
          echo "Error: Model path $TARGET_PATH does not exist!" >&2
          exit 1
        fi

        echo "Launching Gufo with model: $FIRST_SHARD (served as: ${remappedModel})"

        ARGS=(
          serve
          --host 127.0.0.1
          --port "${toString port}"
          --sessions "${toString sessions}"
          llm
          --model "$FIRST_SHARD"
          --served-model-name "${remappedModel}"
        )

        ${lib.optionalString (context != null) ''
          ARGS+=(--context "${toString context}")
        ''}

        ${lib.optionalString (mmprojPath != null) ''
          MMPROJ_PATH="${modelsDir}/${mmprojPath}"
          if [ ! -f "$MMPROJ_PATH" ] && [ -f "${mmprojPath}" ]; then
            MMPROJ_PATH="${mmprojPath}"
          fi
          ARGS+=(--mmproj "$MMPROJ_PATH")
        ''}

        ${lib.optionalString (speculative != null) ''
          ARGS+=(--speculative "${speculative}")
        ''}

        ${lib.optionalString (draftTokens != null) ''
          ARGS+=(--draft-tokens "${toString draftTokens}")
        ''}

        ${lib.optionalString (mtpModelPath != null) ''
          MTP_PATH="${modelsDir}/${mtpModelPath}"
          if [ ! -f "$MTP_PATH" ] && [ -f "${mtpModelPath}" ]; then
            MTP_PATH="${mtpModelPath}"
          fi
          ARGS+=(--mtp-model "$MTP_PATH")
        ''}

        ${lib.optionalString (dflashModelPath != null) ''
          DFLASH_PATH="${modelsDir}/${dflashModelPath}"
          if [ ! -f "$DFLASH_PATH" ] && [ -f "${dflashModelPath}" ]; then
            DFLASH_PATH="${dflashModelPath}"
          fi
          ARGS+=(--dflash-model "$DFLASH_PATH")
        ''}

        ${lib.optionalString (dsparkModelPath != null) ''
          DSPARK_PATH="${modelsDir}/${dsparkModelPath}"
          if [ -d "$DSPARK_PATH" ]; then
            DSPARK_FILE=$(${pkgs.findutils}/bin/find "$DSPARK_PATH" -maxdepth 1 -type f \( -iname "*dspark*" -o -name "*.gguf" \) | ${pkgs.coreutils}/bin/head -n 1)
            if [ -n "$DSPARK_FILE" ]; then
              DSPARK_PATH="$DSPARK_FILE"
            fi
          elif [ ! -f "$DSPARK_PATH" ] && [ -f "${dsparkModelPath}" ]; then
            DSPARK_PATH="${dsparkModelPath}"
          elif [ ! -f "$DSPARK_PATH" ] && [ -d "$(dirname "$DSPARK_PATH")" ]; then
            DSPARK_FILE=$(${pkgs.findutils}/bin/find "$(dirname "$DSPARK_PATH")" -maxdepth 1 -type f -iname "*dspark*" 2>/dev/null | ${pkgs.coreutils}/bin/head -n 1)
            if [ -n "$DSPARK_FILE" ]; then
              DSPARK_PATH="$DSPARK_FILE"
            fi
          fi
          ARGS+=(--dspark-model "$DSPARK_PATH")
        ''}
        ''
    }

    ${lib.concatMapStringsSep "\n" (alias: "ARGS+=(--served-model-name ${lib.escapeShellArg alias})") aliases}

    ${lib.concatMapStringsSep "\n" (arg: "ARGS+=(${lib.escapeShellArg arg})") extraArgs}

    exec ${gufoPkg}/bin/gufo "''${ARGS[@]}"
  '';
in {
  device = "gpu";
  serviceName = "gufo-${modelId}.service";
  # `gufo` for the text engine (the label every existing entry and client already sees),
  # `gufo-image` for the modality that answers on /v1/images instead of /v1/chat.
  type = "gufo" + lib.optionalString imageMode "-image";
  inherit remappedModel description sessions context;
  url = "http://127.0.0.1:${toString port}";
  # An image entry is always a snapshot directory, so the router can pre-flight its
  # existence and answer "weights missing" instead of starting a unit that cannot load.
  modelDir = lib.optionalString imageMode "${modelsDir}/${modelPath}";
  capabilities = if capabilities != null then capabilities else defaultCapabilities.${kindArg};

  systemdService = {
    description =
      if imageMode then
        "Gufo image service: ${modelId} (${description})"
      else
        "Gufo LLM Service: ${modelId} (${description})";
    after = ["network.target"];
    environment = defaultEnv // env;

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
        # Claim the GPU domain (unlink + recreate, so a state file left behind by another engine
        # user can never fail this unit: chmod by a non-owner is EPERM and a failed ExecStartPre
        # aborts the start before ExecStart).
        "${config.services.workload-manager.claimStateScript} gpu ${lib.escapeShellArg modelId}"
      ];
      ExecStart = "${launcher}";
      ExecStopPost = [
        "/bin/sh -c 'if [ \"$(${pkgs.coreutils}/bin/cat /run/model-lock/active_gpu 2>/dev/null)\" = ${lib.escapeShellArg modelId} ]; then ${pkgs.coreutils}/bin/rm -f /run/model-lock/active_gpu; fi'"
      ];

      KillSignal = "SIGINT";
      TimeoutStopSec = 10;
      Restart = "no";
      LimitMEMLOCK = "infinity";
      LimitNOFILE = 1048576;
    };
  };
}
