# mkSGLang: a model served by SGLang instead of llama.cpp/Gufo/Kyojin.
#
# Same contract as the other helpers (serviceName / remappedModel / url /
# systemdService), so workload-manager, the /v1 switcher and the dashboard pick it up
# unchanged. What differs is how the process starts:
#
#   * SGLang serves Hugging Face model *directories*, not GGUF files, so `modelPath`
#     points at a directory under services.sglang.modelsDir;
#   * the engine runs inside an FHS environment (Python + ROCm runtime) with PYTHONPATH
#     merging the engine and its dependency closure from the store;
#   * Strix Halo posture comes from upstream's docker/rocm-gfx1151.Dockerfile:
#     SGLANG_USE_AITER=0 (aiter's compiled attention/RMSNorm kernels are CDNA-only:
#     v_pk_mul_f32 plus wave64 templates) and therefore --attention-backend triton,
#     which that Dockerfile's own run line also passes.
#
# Speculative decoding is where SGLang earns its keep here: Ripple-65B is dense, so
# decode is bound by the 256 GB/s LPDDR5x bus, and Ricursive publishes a DFlash2 drafter
# (parallel block drafting, 16 tokens/block). The drafter reads intermediate hidden
# states of the target, so it must be unquantised BF16 (~8.1 GB) next to the target.
{
  pkgs,
  lib,
  config,
  ...
}: {
  modelId ? name,
  name ? null,
  # Directory (relative to modelsDir) holding config.json + safetensors for the target.
  modelPath,
  remappedModel ? modelId,
  description ? "",
  context ? null,
  sessions ? 1,
  port ? (config.services.sglang.backendPort or 8084),
  modelsDir ? (config.services.sglang.modelsDir or "/srv/models"),
  stateDir ? (config.services.sglang.stateDir or "/var/lib/sglang"),
  package ? (config.services.sglang.package or null),
  fhsEnvironment ? (config.services.sglang.fhsEnvironment or null),
  pythonPath ? (config.services.sglang.pythonPath or []),
  engineVersion ? (config.services.sglang.version or ""),
  # ---- speculative decoding (DFlash2) -------------------------------------------
  speculativeDraftPath ? null,
  # 16 = the drafter's native block size (ricursiveAI/Ripple-65B-Preview-DFlash2).
  numDraftTokens ? 16,
  # DGX Spark reference pins the draft's own attention window at 16K.
  draftWindowSize ? 16384,
  draftQuantization ? "unquant",
  # ---- memory shaping ------------------------------------------------------------
  # Fraction of the device (== unified RAM on an APU) reserved for weights + KV at
  # init. Everything above it is left for the OS, the Triton JIT arena and page cache.
  memFractionStatic ? 0.85,
  # Explicit pool size keeps the reservation exact instead of "whatever was left".
  maxTotalTokens ? null,
  maxRunningRequests ? 1,
  tpSize ? 1,
  dtype ? "bfloat16",
  kvCacheDtype ? "bfloat16",
  attentionBackend ? "triton",
  # Radix prefix cache is off in the vendor's local recipe; agentic workloads hit it
  # hard, so it stays on unless a caller says otherwise.
  radixCache ? true,
  # CUDA graphs cut launch overhead, but each captured batch size reserves memory.
  cudaGraphDecodeBatchSize ? [ 1 ],
  disableCudaGraph ? false,
  reasoningParser ? null,
  toolCallParser ? null,
  extraArgs ? [],
  env ? {},
  # Interpreter that carries the dependency closure (services.sglang's python3.withPackages).
  engineInterpreter ? (config.services.sglang.interpreter or pkgs.python3),
}: let
  inherit (lib) concatMapStringsSep escapeShellArg optionalString;

  # Nix renders a float with six decimals, so 0.85 shows up as "0.850000". Argparse would
  # accept it, but the command line should read like the config. Only trailing zeros after a
  # decimal point are removed: 1.0005 stays 1.0005, 1.0 becomes 1.
  numText = n:
    let
      initStr = s: builtins.substring 0 (builtins.stringLength s - 1) s;
      stripZeros = s: if lib.hasSuffix "0" s then stripZeros (initStr s) else s;
      stripDot = s: if lib.hasSuffix "." s then initStr s else s;
    in
      if builtins.typeOf n == "float" then stripDot (stripZeros (toString n)) else toString n;

  sglangPkg =
    if package != null
    then package
    else throw "mkSGLang: no engine package. Enable services.sglang (it defaults the package).";

  # The engine always runs as this exact interpreter: buildFHSEnv builds its /usr/bin view
  # from targetPkgs, so a bare `python3` would resolve to whichever copy the environment
  # happens to link rather than the one carrying the dependency closure. The store is bound
  # into the sandbox, so the absolute path works inside it too.
  pythonBin = "${engineInterpreter}/bin/python3";

  runEngine =
    if fhsEnvironment != null
    then ''
      exec ${fhsEnvironment}/bin/${fhsEnvironment.name} \
        'exec ${pythonBin} -m sglang.launch_server "$$@"' sh "''${ARGS[@]}"
    ''
    else ''
      exec ${pythonBin} -m sglang.launch_server "''${ARGS[@]}"
    '';

  pythonPathStr = concatMapStringsSep ":" (p: p) pythonPath;

  # `$$@` in the last block is deliberate: it expands in *this* script, quoting each engine
  # argument separately before the sandbox's shell re-quotes them. shellcheck cannot see that
  # and would flag SC2086.
  launcher = pkgs.writeShellScript "sglang-run-${modelId}" ''
    set -euo pipefail

    # Triton/torch-inductor write their JIT caches under HOME; keep them on disk in
    # the engine's state dir so restarts reuse them instead of recompiling for minutes.
    export HOME="${stateDir}"
    export TMPDIR="${stateDir}/tmp"
    mkdir -p "$TMPDIR"

    # Store engine + dependencies (no venv, no pip at run time).
    export PYTHONPATH="${pythonPathStr}"

    # gfx1151 is natively targeted by the pinned ROCm stack: an HSA override would
    # pretend to be another chip and select the wrong ISA.
    unset HSA_OVERRIDE_GFX_VERSION || true
    export HIP_VISIBLE_DEVICES="0"

    # aiter ships CDNA-only compiled kernels (v_pk_mul_f32, wave64 templates); force the
    # Triton paths, exactly like upstream's rocm-gfx1151 image.
    export SGLANG_USE_AITER="0"

    TARGET_PATH="${modelsDir}/${modelPath}"
    if [ ! -d "$TARGET_PATH" ]; then
      echo "Error: SGLang needs a model *directory*, $TARGET_PATH does not exist!" >&2
      exit 1
    fi

    echo "Launching SGLang with model: $TARGET_PATH (served as: ${remappedModel})"

    ARGS=(
      --model-path "$TARGET_PATH"
      --served-model-name "${remappedModel}"
      --host 127.0.0.1
      --port "${toString port}"
      --tp-size "${toString tpSize}"
      --dtype "${dtype}"
      --kv-cache-dtype "${kvCacheDtype}"
      --attention-backend "${attentionBackend}"
      --mem-fraction-static "${numText memFractionStatic}"
      --max-running-requests "${toString maxRunningRequests}"
      --watchdog-timeout 1800
    )

    ${optionalString (context != null) ''ARGS+=(--context-length "${toString context}")''}
    ${optionalString (maxTotalTokens != null) ''ARGS+=(--max-total-tokens "${toString maxTotalTokens}")''}
    ${optionalString (!radixCache) ''ARGS+=(--disable-radix-cache)''}
    ${optionalString disableCudaGraph ''ARGS+=(--disable-cuda-graph)''}
    ${optionalString (cudaGraphDecodeBatchSize != [ ] && !disableCudaGraph) ''
      ARGS+=(--cuda-graph-bs-decode ${concatMapStringsSep " " (b: toString b) cudaGraphDecodeBatchSize})
    ''}
    ${optionalString (reasoningParser != null) ''ARGS+=(--reasoning-parser "${reasoningParser}")''}
    ${optionalString (toolCallParser != null) ''ARGS+=(--tool-call-parser "${toolCallParser}")''}

    ${optionalString (speculativeDraftPath != null) ''
      DRAFT_PATH="${modelsDir}/${speculativeDraftPath}"
      if [ ! -d "$DRAFT_PATH" ]; then
        echo "Error: speculative draft $DRAFT_PATH does not exist!" >&2
        exit 1
      fi
      ARGS+=(
        --speculative-algorithm DFLASH
        --speculative-draft-model-path "$DRAFT_PATH"
        --speculative-draft-model-quantization "${draftQuantization}"
        --speculative-num-draft-tokens "${toString numDraftTokens}"
        --speculative-draft-window-size "${toString draftWindowSize}"
        --speculative-draft-attention-backend triton
      )
    ''}

    ${concatMapStringsSep "\n" (arg: "ARGS+=(${escapeShellArg arg})") extraArgs}

    # Hand off to the engine. Inside the sandbox `$$@` expands here, in this script, into
    # separately quoted words; the inner script then forwards them verbatim.
    ${runEngine}
  '';
in {
  serviceName = "sglang-${modelId}.service";
  type = "sglang";
  inherit remappedModel description sessions;
  url = "http://127.0.0.1:${toString port}";

  systemdService = {
    description = "SGLang ${engineVersion} LLM Service: ${modelId} (${description})";
    after = [ "network.target" ];
    environment = {
      HOME = stateDir;
      SGLANG_USE_AITER = "0";
      HIP_VISIBLE_DEVICES = "0";
    } // env;

    serviceConfig = {
      Type = "simple";
      User = "sglang";
      Group = "sglang";
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
        "/bin/sh -c '${pkgs.coreutils}/bin/mkdir -p ${stateDir}/tmp && ${pkgs.coreutils}/bin/echo ${escapeShellArg modelId} > /run/model-lock/active_model && (${pkgs.coreutils}/bin/chmod 666 /run/model-lock/active_model 2>/dev/null || true)'"
      ];
      ExecStart = "${launcher}";
      ExecStopPost = [
        "/bin/sh -c 'if [ \"$(${pkgs.coreutils}/bin/cat /run/model-lock/active_model 2>/dev/null)\" = ${escapeShellArg modelId} ]; then ${pkgs.coreutils}/bin/rm -f /run/model-lock/active_model; fi'"
      ];

      KillSignal = "SIGINT";
      TimeoutStopSec = 30;
      # A cold start imports torch, loads safetensors through the ROCm runtime and may
      # JIT Triton kernels. Several minutes is normal on first boot; afterwards the
      # engine only has to read weights.
      TimeoutStartSec = 1800;
      Restart = "no";
      LimitMEMLOCK = "infinity";
      LimitNOFILE = 1048576;
    };
  };
}
