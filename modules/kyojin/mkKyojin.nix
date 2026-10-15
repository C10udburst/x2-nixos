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
  flavor ? "glm",
  context ? null,
  sessions ? 1,
  port ? (config.services.kyojin.backendPort or 8083),
  modelsDir ? (config.services.kyojin.modelsDir or "/srv/models"),
  package ? null,
  numDraft ? 2,
  maxHistory ? null,
  rowBudget ? null,
  chatTemplate ? null,
  defaultTemperature ? null,
  defaultTopP ? null,
  defaultReasoningEffort ? null,
  defaultMaxTokens ? null,
  exactPrefixCache ? false,
  noVision ? false,
  noUncensor ? false,
  uncensor ? null,
  uncensorSpec ? null,
  extraArgs ? [],
  env ? {},
}: let
  kyojinPkg =
    if package != null
    then package
    else if config.services ? kyojin && config.services.kyojin ? package && config.services.kyojin.package != null
    then config.services.kyojin.package
    else if inputs ? kyojin && inputs.kyojin ? packages
    then inputs.kyojin.packages.${pkgs.system}.kyojin
    else pkgs.kyojin or (throw "Kyojin package not found. Ensure inputs.kyojin is passed or specify package.");

  defaultEnv = {
    HIP_VISIBLE_DEVICES = "0";
    HOME = "/var/lib/kyojin";
    TMPDIR = "/var/lib/kyojin/tmp";
  };

  launcher = pkgs.writeShellScript "kyojin-run-${modelId}" ''
    set -euo pipefail

    # ROCm 7 natively targets gfx1151; HSA_OVERRIDE_GFX_VERSION must stay unset
    unset HSA_OVERRIDE_GFX_VERSION

    # Ensure helper modules (serve_compat, image_cache) from kyojin repo are accessible
    ${lib.optionalString (inputs ? kyojin) ''
      export PYTHONPATH="${inputs.kyojin}/tools:${inputs.kyojin}/tools/strix_halo:''${PYTHONPATH:-}"
    ''}

    TARGET_PATH="${modelsDir}/${modelPath}"

    if [ -d "$TARGET_PATH" ]; then
      MODEL_DIR="$TARGET_PATH"
    elif [ -d "${modelPath}" ]; then
      MODEL_DIR="${modelPath}"
    elif [ -d "${modelsDir}/GLM-5.3-Flash-EXL3-Yamz" ] && [[ "${modelId}" == glm-5.3-flash* ]]; then
      MODEL_DIR="${modelsDir}/GLM-5.3-Flash-EXL3-Yamz"
    else
      echo "Error: Model path $TARGET_PATH does not exist!" >&2
      exit 1
    fi

    echo "Launching Kyojin (${flavor}) with model: $MODEL_DIR (served as: ${remappedModel})"

    ARGS=(
      --model "$MODEL_DIR"
      --model-id "${remappedModel}"
      --host 127.0.0.1
      --port "${toString port}"
      --sessions "${toString sessions}"
    )

    ${lib.optionalString (context != null) ''
      ARGS+=(-c "${toString context}")
    ''}

    ${lib.optionalString (numDraft != null) ''
      ARGS+=(--num-draft "${toString numDraft}")
    ''}

    ${lib.optionalString (maxHistory != null) ''
      ARGS+=(--max-history "${toString maxHistory}")
    ''}

    ${lib.optionalString (rowBudget != null) ''
      ARGS+=(--row-budget "${toString rowBudget}")
    ''}

    ${lib.optionalString (chatTemplate != null) ''
      ARGS+=(--chat-template "${chatTemplate}")
    ''}

    ${lib.optionalString (defaultTemperature != null) ''
      ARGS+=(--default-temperature "${toString defaultTemperature}")
    ''}

    ${lib.optionalString (defaultTopP != null) ''
      ARGS+=(--default-top-p "${toString defaultTopP}")
    ''}

    ${lib.optionalString (defaultReasoningEffort != null) ''
      ARGS+=(--default-reasoning-effort "${defaultReasoningEffort}")
    ''}

    ${lib.optionalString (defaultMaxTokens != null) ''
      ARGS+=(--default-max-tokens "${toString defaultMaxTokens}")
    ''}

    ${lib.optionalString exactPrefixCache ''
      ARGS+=(--exact-prefix-cache)
    ''}

    ${lib.optionalString noVision ''
      ARGS+=(--no-vision)
    ''}

    ${lib.optionalString (uncensorSpec != null) ''
      export EXL3_ABLIT_RUNTIME="${uncensorSpec}"
    ''}

    ${lib.optionalString (uncensor == false || noUncensor) ''
      ARGS+=(--no-uncensor)
      export EXL3_ABLIT_RUNTIME="off"
    ''}

    ${lib.optionalString (uncensor == true && uncensorSpec == null) ''
      if [ -f "$MODEL_DIR/uncensor_spec.json" ]; then
        export EXL3_ABLIT_RUNTIME="$MODEL_DIR/uncensor_spec.json"
      elif [ -f "${modelsDir}/glm-5.3-flash/uncensor_spec.json" ]; then
        export EXL3_ABLIT_RUNTIME="${modelsDir}/glm-5.3-flash/uncensor_spec.json"
      fi
    ''}

    ${lib.concatMapStringsSep "\n" (arg: "ARGS+=(${lib.escapeShellArg arg})") extraArgs}

    exec ${kyojinPkg}/bin/kyojin-serve-${flavor} "''${ARGS[@]}"
  '';
in {
  serviceName = "kyojin-${modelId}.service";
  type = "kyojin";
  inherit remappedModel description sessions;
  url = "http://127.0.0.1:${toString port}";

  systemdService = {
    description = "Kyojin LLM Service: ${modelId} (${description})";
    after = ["network.target"];
    environment =
      defaultEnv
      // env
      // (lib.optionalAttrs (uncensorSpec != null) { EXL3_ABLIT_RUNTIME = uncensorSpec; })
      // (lib.optionalAttrs (uncensor == false || noUncensor) { EXL3_ABLIT_RUNTIME = "off"; });

    serviceConfig = {
      Type = "simple";
      User = "kyojin";
      Group = "kyojin";
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
        "/bin/sh -c '${pkgs.coreutils}/bin/mkdir -p /var/lib/kyojin/tmp && ${pkgs.coreutils}/bin/echo ${lib.escapeShellArg modelId} > /run/model-lock/active_model && (${pkgs.coreutils}/bin/chmod 666 /run/model-lock/active_model 2>/dev/null || true)'"
      ];
      ExecStart = "${launcher}";
      ExecStopPost = [
        "/bin/sh -c 'if [ \"$(${pkgs.coreutils}/bin/cat /run/model-lock/active_model 2>/dev/null)\" = ${lib.escapeShellArg modelId} ]; then ${pkgs.coreutils}/bin/rm -f /run/model-lock/active_model; fi'"
      ];

      KillSignal = "SIGINT";
      TimeoutStopSec = 15;
      Restart = "no";
      LimitMEMLOCK = "infinity";
      LimitNOFILE = 1048576;
    };
  };
}
