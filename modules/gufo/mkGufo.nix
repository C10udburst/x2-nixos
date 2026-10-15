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

    if [ -d "$TARGET_PATH" ]; then
      FIRST_SHARD=$(${pkgs.findutils}/bin/find "$TARGET_PATH" -maxdepth 1 -type f -name "*.gguf" | ${pkgs.coreutils}/bin/sort | ${pkgs.coreutils}/bin/head -n 1)
      if [ -z "$FIRST_SHARD" ]; then
        echo "Error: No .gguf model found in $TARGET_PATH" >&2
        exit 1
      fi
    elif [ -f "$TARGET_PATH" ]; then
      FIRST_SHARD="$TARGET_PATH"
    elif [ -f "${modelPath}" ]; then
      FIRST_SHARD="${modelPath}"
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
      if [ ! -f "$DSPARK_PATH" ] && [ -f "${dsparkModelPath}" ]; then
        DSPARK_PATH="${dsparkModelPath}"
      fi
      ARGS+=(--dspark-model "$DSPARK_PATH")
    ''}

    ${lib.concatMapStringsSep "\n" (arg: "ARGS+=(${lib.escapeShellArg arg})") extraArgs}

    exec ${gufoPkg}/bin/gufo "''${ARGS[@]}"
  '';
in {
  serviceName = "gufo-${modelId}.service";
  type = "gufo";
  inherit remappedModel description sessions;
  url = "http://127.0.0.1:${toString port}";

  systemdService = {
    description = "Gufo LLM Service: ${modelId} (${description})";
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
        "/bin/sh -c '${pkgs.coreutils}/bin/echo ${lib.escapeShellArg modelId} > /run/model-lock/active_model && ${pkgs.coreutils}/bin/chmod 666 /run/model-lock/active_model'"
      ];
      ExecStart = "${launcher}";
      ExecStopPost = [
        "/bin/sh -c 'if [ \"$(${pkgs.coreutils}/bin/cat /run/model-lock/active_model 2>/dev/null)\" = ${lib.escapeShellArg modelId} ]; then ${pkgs.coreutils}/bin/rm -f /run/model-lock/active_model; fi'"
      ];

      KillSignal = "SIGINT";
      TimeoutStopSec = 10;
      Restart = "no";
      LimitMEMLOCK = "infinity";
      LimitNOFILE = 1048576;
    };
  };
}
