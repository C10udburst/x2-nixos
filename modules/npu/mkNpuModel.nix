{ pkgs, lib, config, ... }:
{
  modelId,
  remappedModel ? modelId,
  description ? "",
  port,
  # Modality -> runner script under services.npu.runnerSrc. Deliberately a plain attr
  # set, not a lib.types.enum: adding a modality means one runner file plus one line
  # here, nothing in the workload manager, the switcher or the dashboard.
  kind,
  # Dashboard / /v1/models discovery tags only; the switcher ignores them entirely.
  capabilities ? null,
  sessions ? 1,
  # Declared context window (tokens). `null` leaves it to the artifact's
  # genai_config.json; a number is exported as NPU_CONTEXT_LENGTH *and* reported to the
  # dashboard, which filters models on it.
  context ? null,
  modelsDir ? (config.services.npu.modelsDir or "/srv/models"),
  extraEnv ? { },
}:
let
  npuCfg = config.services.npu or { };
  modelDir = "${modelsDir}/${modelId}";

  runners = {
    genai = "genai_runner.py";
    embeddings = "embeddings_runner.py";
  };

  runnerFile =
    runners.${kind}
    or (throw "mkNpuModel: unknown kind '${kind}' (known: ${lib.concatStringsSep ", " (lib.attrNames runners)})");

  defaultCapabilities = {
    genai = [ "chat" "completions" ];
    embeddings = [ "embeddings" ];
    asr = [ "audio-transcriptions" ];
    image-gen = [ "images" ];
  };

  runtimeEnv = npuCfg.runtimeEnv or { };

  # Engine-style launcher: same shape as mkGufo / mkLlamaCpp. One process, one model,
  # killed and restarted to switch workloads.
  launcher = pkgs.writeShellScript "npu-run-${modelId}" ''
    set -euo pipefail

    # The canonical values come from services.npu.runtimeEnv (unit environment); these
    # fallbacks keep the launcher runnable by hand from a shell.
    export XILINX_XRT="''${XILINX_XRT:-${runtimeEnv.XILINX_XRT or ""}}"
    export RYZENAI_EP_PATH="''${RYZENAI_EP_PATH:-${runtimeEnv.RYZENAI_EP_PATH or ""}}"
    export LD_LIBRARY_PATH="''${LD_LIBRARY_PATH:-${runtimeEnv.LD_LIBRARY_PATH or ""}}"

    export NPU_MODEL_ID="${remappedModel}"

    ${lib.optionalString (context != null) ''
      # The declared window is what the runner uses (and what /v1/models reports); an
      # externally exported NPU_CONTEXT_LENGTH still wins, so hand runs stay tunable.
      export NPU_CONTEXT_LENGTH="''${NPU_CONTEXT_LENGTH:-${toString context}}"
    ''}

    ${lib.concatStringsSep "\n" (lib.mapAttrsToList (name: value: "export ${name}=${lib.escapeShellArg value}") extraEnv)}

    exec "${npuCfg.pythonPackage}/bin/python3" "${npuCfg.runnerSrc}/${runnerFile}" \
      --model "${modelDir}" \
      --alias "${remappedModel}" \
      --host 127.0.0.1 \
      --port "${toString port}"
  '';
in
{
  device = "npu";
  serviceName = "npu-${modelId}.service";
  type = "npu-${kind}";
  inherit remappedModel description sessions context;
  url = "http://127.0.0.1:${toString port}";
  modelDir = toString modelDir;
  capabilities = if capabilities != null then capabilities else (defaultCapabilities.${kind} or [ ]);

  systemdService = {
    description = "NPU Service: ${modelId} (${description})";
    after = [ "network.target" ];
    environment = (npuCfg.runtimeEnv or { }) // {
      NPU_MODEL_DIR = modelDir;
      NPU_MODEL_ID = remappedModel;
    };

    serviceConfig = {
      Type = "simple";
      # The `npu` user's primary group is `render`, which owns /dev/accel/accel0. Deny
      # everything else, then grant the one accelerator node (modules/gufo does the same for
      # the GPU domain).
      User = "npu";
      Group = "render";
      DevicePolicy = "closed";
      DeviceAllow = [ npuCfg.device ];

      ExecStartPre = [
        # Fail fast with a readable journal line when the weights are not in place (units
        # never fetch anything - weights are placed on the host by the operator), then claim
        # the NPU state file (never active_gpu - the domains are independent).
        "/bin/sh -c 'test -d ${lib.escapeShellArg modelDir} || { echo \"model directory ${modelDir} is missing\" >&2; exit 1; }'"
        "/bin/sh -c '${pkgs.coreutils}/bin/echo ${lib.escapeShellArg modelId} > /run/model-lock/active_npu && (${pkgs.coreutils}/bin/chmod 666 /run/model-lock/active_npu 2>/dev/null || true)'"
      ];

      ExecStart = "${launcher}";

      ExecStopPost = [
        "/bin/sh -c 'if [ \"$(${pkgs.coreutils}/bin/cat /run/model-lock/active_npu 2>/dev/null)\" = ${lib.escapeShellArg modelId} ]; then ${pkgs.coreutils}/bin/rm -f /run/model-lock/active_npu; fi'"
      ];

      KillSignal = "SIGINT";
      TimeoutStopSec = 15;
      Restart = "no";
      NoNewPrivileges = true;
      PrivateTmp = true;
      LimitMEMLOCK = "infinity";
      LimitNOFILE = 1048576;
    };
  };
}
