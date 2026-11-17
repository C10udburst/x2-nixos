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
  sessions ? parallel,
  flashAttention ? true,
  threads ? 16,
  cacheTypeK ? "q8_0",
  cacheTypeV ? "q8_0",
  jinja ? true,
  mlock ? false,
  port ? (config.services.llamacpp.backendPort or 8082),
  modelsDir ? (config.services.llamacpp.modelsDir or "/srv/models"),
  package ? (config.services.llamacpp.package or (pkgs.llama-cpp.override {rocmSupport = true;})),
  gpuLayers ? 999,
  mmprojPath ? null,
  # Sampling (null = llama.cpp's own default).
  temp ? null,
  topP ? null,
  topK ? null,
  minP ? null,
  repeatPenalty ? null,
  presencePenalty ? null,
  frequencyPenalty ? null,
  # Batching (null = llama.cpp's own default: -b 2048 -ub 512).
  batchSize ? null,
  ubatchSize ? null,
  # Speculative decoding.
  speculative ? null,
  draftModelPath ? null,
  draftTokens ? null,
  draftPMin ? null,
  draftGpuLayers ? gpuLayers,
  draftCacheTypeK ? cacheTypeK,
  draftCacheTypeV ? cacheTypeV,
  draftThreads ? null,
  # Memory.
  noMmap ? false,
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
    elif [ -d "$(dirname "$TARGET_PATH")" ] && [ -n "$(${pkgs.findutils}/bin/find "$(dirname "$TARGET_PATH")" -maxdepth 1 -type f -name "*.gguf" 2>/dev/null | ${pkgs.coreutils}/bin/head -n 1)" ]; then
      FIRST_SHARD=$(${pkgs.findutils}/bin/find "$(dirname "$TARGET_PATH")" -maxdepth 1 -type f -name "*.gguf" | ${pkgs.coreutils}/bin/sort | ${pkgs.coreutils}/bin/head -n 1)
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
      -np "${toString sessions}"
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
      ARGS+=(-c "${toString (context * sessions)}")
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

    ${lib.optionalString (temp != null) ''
      ARGS+=(--temp "${toString temp}")
    ''}

    ${lib.optionalString (topP != null) ''
      ARGS+=(--top-p "${toString topP}")
    ''}

    ${lib.optionalString (topK != null) ''
      ARGS+=(--top-k "${toString topK}")
    ''}

    ${lib.optionalString (minP != null) ''
      ARGS+=(--min-p "${toString minP}")
    ''}

    ${lib.optionalString (repeatPenalty != null) ''
      ARGS+=(--repeat-penalty "${toString repeatPenalty}")
    ''}

    ${lib.optionalString (presencePenalty != null) ''
      ARGS+=(--presence-penalty "${toString presencePenalty}")
    ''}

    ${lib.optionalString (frequencyPenalty != null) ''
      ARGS+=(--frequency-penalty "${toString frequencyPenalty}")
    ''}

    ${lib.optionalString (batchSize != null) ''
      ARGS+=(-b "${toString batchSize}")
    ''}

    ${lib.optionalString (ubatchSize != null) ''
      ARGS+=(-ub "${toString ubatchSize}")
    ''}

    ${lib.optionalString (draftModelPath != null) ''
      DRAFT_PATH="${modelsDir}/${draftModelPath}"
      if [ ! -f "$DRAFT_PATH" ] && [ -f "${draftModelPath}" ]; then
        DRAFT_PATH="${draftModelPath}"
      fi
      ARGS+=(-md "$DRAFT_PATH")
    ''}

    ${lib.optionalString (draftModelPath != null && speculative != null) ''
      ARGS+=(--spec-type "${speculative}")
    ''}

    ${lib.optionalString (draftModelPath != null && draftTokens != null) ''
      ARGS+=(--spec-draft-n-max "${toString draftTokens}")
    ''}

    ${lib.optionalString (draftModelPath != null && draftPMin != null) ''
      ARGS+=(--spec-draft-p-min "${toString draftPMin}")
    ''}

    ${lib.optionalString (draftModelPath != null && draftGpuLayers != null) ''
      ARGS+=(-ngld "${toString draftGpuLayers}")
    ''}

    ${lib.optionalString (draftModelPath != null && draftCacheTypeK != null) ''
      ARGS+=(-ctkd "${draftCacheTypeK}")
    ''}

    ${lib.optionalString (draftModelPath != null && draftCacheTypeV != null) ''
      ARGS+=(-ctvd "${draftCacheTypeV}")
    ''}

    ${lib.optionalString (draftModelPath != null && draftThreads != null) ''
      ARGS+=(-td "${toString draftThreads}")
    ''}

    ${lib.optionalString noMmap ''
      ARGS+=(--no-mmap)
    ''}

    ${lib.concatMapStringsSep "\n" (arg: "ARGS+=(${lib.escapeShellArg arg})") extraArgs}

    exec ${package}/bin/llama-server "''${ARGS[@]}"
  '';
in {
  device = "gpu";
  serviceName = "llama-cpp-${modelId}.service";
  type = "llama-cpp";
  inherit remappedModel description sessions context;
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
