{
  pkgs,
  lib,
  config,
  ...
}: {
  modelId ? name,
  name ? null,
  modelPath,
  remappedModel ? modelId,
  description ? "",
  context ? null,
  parallel ? 1,
  flashAttention ? true,
  threads ? 16,
  cacheTypeK ? null,
  cacheTypeV ? null,
  jinja ? true,
  mlock ? false,
  port ? (config.services.llamacpp.backendPort or 8082),
  modelsDir ? (config.services.llamacpp.modelsDir or "/srv/models"),
  package ? (config.services.llamacpp.package or (pkgs.llama-cpp.override {rocmSupport = true;})),
  gpuLayers ? 99,
  mmprojPath ? null,
  extraArgs ? [],
  env ? {},
}: let
  defaultEnv = {
    HSA_OVERRIDE_GFX_VERSION = "11.5.1";
    HIP_VISIBLE_DEVICES = "0";
  };

  launcher = pkgs.writeShellScript "llama-cpp-run-${modelId}" ''
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

    echo "Launching llama-server with model: $FIRST_SHARD (alias: ${remappedModel})"

    ARGS=(
      -m "$FIRST_SHARD"
      --host 127.0.0.1
      --port "${toString port}"
      -ngl "${toString gpuLayers}"
      --alias "${remappedModel}"
      -np "${toString parallel}"
    )

    ${lib.optionalString (threads != null) ''
      ARGS+=(-t "${toString threads}")
    ''}

    ${lib.optionalString flashAttention ''
      ARGS+=(-fa on)
    ''}

    ${lib.optionalString jinja ''
      ARGS+=(--jinja)
    ''}

    ${lib.optionalString mlock ''
      ARGS+=(--mlock)
    ''}

    ${lib.optionalString (context != null) ''
      ARGS+=(-c "${toString context}")
    ''}

    ${lib.optionalString (cacheTypeK != null) ''
      ARGS+=(-ctk "${cacheTypeK}")
    ''}

    ${lib.optionalString (cacheTypeV != null) ''
      ARGS+=(-ctv "${cacheTypeV}")
    ''}

    ${lib.optionalString (mmprojPath != null) ''
      MMPROJ_PATH="${modelsDir}/${mmprojPath}"
      if [ ! -f "$MMPROJ_PATH" ] && [ -f "${mmprojPath}" ]; then
        MMPROJ_PATH="${mmprojPath}"
      fi
      ARGS+=(--mmproj "$MMPROJ_PATH")
    ''}

    ${lib.concatMapStringsSep "\n" (arg: "ARGS+=(${lib.escapeShellArg arg})") extraArgs}

    exec ${package}/bin/llama-server "''${ARGS[@]}"
  '';
in {
  serviceName = "llama-cpp-${modelId}.service";
  type = "llama-cpp";
  inherit remappedModel description;
  url = "http://127.0.0.1:${toString port}";

  systemdService = {
    description = "llama.cpp LLM Service: ${modelId} (${description})";
    after = ["network.target"];
    environment = defaultEnv // env;

    serviceConfig = {
      Type = "simple";
      User = "llama-cpp";
      Group = "llama-cpp";
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
