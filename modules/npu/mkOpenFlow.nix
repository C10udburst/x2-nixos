# OpenFlowLM model entry: one `oflm serve` process, one port, one systemd unit.
#
# The same shape as ./mkGufo.nix / ./mkKyojin.nix, with two OpenFlowLM-specific parts:
#
# * **The registry key is the engine's own tag.** The router resolves a model and forwards
#   the body untouched, so `services.models.<id>` has to be a tag the engine itself
#   resolves: `llama3.2:1b`, `whisper-v3:turbo`. There is no alias layer to invent a
#   friendlier name, and inventing one would answer 404 at the backend.
# * **The entry is read out of the engine's catalogue at eval time.** `model_list.json` from
#   the flake source supplies the on-disk directory name (`Llama-3.2-1B-NPU2`), the declared
#   context window and the footprint, so an entry cannot drift from what the deployed engine
#   serves, and a tag that does not exist is a Nix eval error rather than a runtime 404.
#
# `kind` selects the command line:
#
#     chat       -> oflm serve <tag> --port N …
#     asr        -> oflm serve --asr 1 --asrmodel <tag> --port N …
#     embeddings -> oflm serve --embed 1 --embeddingmodel <tag> --port N …
#
# Both modality-only forms are real standalone servers: `serve` without a chat tag loads no
# LLM (the `model-faker` sentinel), so Whisper holds ~1 GB and an embedding model loads on its
# own. Only the CLI `/input` voice→text→LLM flow wants a chat model loaded beside it.
{ pkgs, lib, config, ... }:
{
  modelId,
  description ? "",
  port,
  # "chat" (an LLM behind /v1/chat/completions), "asr" (Whisper behind
  # /v1/audio/transcriptions) or "embeddings" (a BERT-style encoder behind /v1/embeddings).
  # A plain argument rather than an enum, like mkNpuModel's `kind`: a new modality is one
  # branch here and nothing anywhere else.
  kind ? "chat",
  # Context window passed as `--ctx-len`. `null` leaves it to the engine, which uses the
  # catalogue's `default_context_length` - and that is what /v1/models reports either way,
  # so the dashboard's context filter stays honest.
  context ? null,
  sessions ? 1,
  # Passed to `oflm serve` verbatim: --prefill-chunk-len, --prefill-mode, --preemption, …
  extraArgs ? [ ],
  extraEnv ? { },
}:
let
  npuCfg = config.services.npu or { };
  cfg = npuCfg.openflowlm or { };

  # ---------------------------------------------------------------- the catalogue
  parts = lib.splitString ":" modelId;
  familyName = lib.head parts;
  variantName = lib.concatStringsSep ":" (lib.drop 1 parts);

  family =
    cfg.catalogue.models.${familyName}
    or (throw ''
      mkOpenFlow: '${modelId}' is not in the OpenFlowLM catalogue.
      Known families: ${lib.concatStringsSep ", " (lib.attrNames cfg.catalogue.models)}
    '');

  entry =
    family.${variantName}
    or (throw ''
      mkOpenFlow: '${modelId}' has no '${variantName}' variant.
      Known variants of '${familyName}': ${lib.concatStringsSep ", " (lib.attrNames family)}
    '');

  # Where the weights live: <OFLM_MODEL_PATH>/models/<catalogue name>.
  weightsDir = "${cfg.modelStore}/models/${entry.name}";

  # Reported to /v1/models as context_length; the engine's own default when unset.
  declaredContext = if context != null then context else (entry.default_context_length or null);

  capabilities = {
    chat = [ "chat" "completions" ];
    asr = [ "audio-transcriptions" ];
    embeddings = [ "embeddings" ];
  }
  .${kind}
  or (throw "mkOpenFlow: unknown kind '${kind}' (chat, asr, embeddings)");

  # The modality switches. `--asr`/`--embed` load the model *instead of* a chat model, so the
  # tag travels in the matching --asrmodel/--embeddingmodel flag and no positional tag is
  # given - passing one would pull the LLM in beside it.
  kindArgs = {
    chat = [ modelId ];
    asr = [ "--asr" "1" "--asrmodel" modelId ];
    embeddings = [ "--embed" "1" "--embeddingmodel" modelId ];
  }
  .${kind}
  or [ ];

  serveArgs =
    [
      "serve"
      "--host"
      "127.0.0.1"
      "--port"
      (toString port)
      "--pmode"
      cfg.powerMode
      # nginx is the only client; a wildcard CORS header on a loopback-originated request
      # buys nothing the gateway's own header does not already give.
      "--cors"
      "0"
    ]
    ++ kindArgs
    ++ lib.optionals (kind == "chat" && context != null) [ "--ctx-len" (toString context) ]
    ++ extraArgs;

  # systemd unit names have no room for a tag's ':'.
  slug = lib.replaceStrings [ ":" "/" " " ] [ "-" "-" "-" ] modelId;

  launcher = pkgs.writeShellScript "openflow-run-${slug}" ''
    set -euo pipefail

    # Defaults, so the launcher is also runnable by hand from a shell.
    export OFLM_MODEL_PATH="''${OFLM_MODEL_PATH:-${cfg.modelStore}}"
    export HOME="''${HOME:-/var/lib/oflm}"

    ${lib.concatStringsSep "\n" (lib.mapAttrsToList (name: value: "export ${name}=${lib.escapeShellArg value}") extraEnv)}

    # Deliberately NOT OFLM_XCLBIN_PATH: the engine searches `<exe_dir>/../share/oflm`
    # first, and that is where the kernel package is linked. Exporting the variable would
    # only make `oflm add` try to write kernels into the read-only store.
    exec ${lib.escapeShellArgs ([ "${cfg.package}/bin/oflm" ] ++ serveArgs)}
  '';
in
{
  device = "npu";
  serviceName = "npu-${slug}.service";
  type = "openflow-${kind}";
  # The backend resolves this tag itself; the router forwards bodies verbatim.
  remappedModel = modelId;
  inherit description sessions;
  context = declaredContext;
  url = "http://127.0.0.1:${toString port}";
  modelDir = weightsDir;
  inherit capabilities;

  systemdService = {
    description = "OpenFlowLM Service: ${modelId} (${description})";
    after = [ "network.target" ];
    environment = {
      OFLM_MODEL_PATH = cfg.modelStore;
      # `oflm` writes settings.json here and `oflm add` installs under it.
      HOME = "/var/lib/oflm";
    } // extraEnv;

    serviceConfig = {
      Type = "simple";
      # Group `render` owns /dev/accel/accel0; everything else is denied (as in mkGufo).
      User = npuCfg.user or "npu";
      Group = "render";
      DevicePolicy = "closed";
      DeviceAllow = [ npuCfg.device ];

      StateDirectory = "oflm";

      ExecStartPre = [
        # Fail with the missing path in the journal instead of letting the engine start an
        # HuggingFace download as a service user: units never fetch weights.
        "/bin/sh -c 'test -d ${lib.escapeShellArg weightsDir} || { echo \"model directory ${weightsDir} is missing - on the host: oflm pull ${modelId}\" >&2; exit 1; }'"
        "/bin/sh -c '${pkgs.coreutils}/bin/echo ${lib.escapeShellArg modelId} > /run/model-lock/active_npu && (${pkgs.coreutils}/bin/chmod 666 /run/model-lock/active_npu 2>/dev/null || true)'"
      ];

      ExecStart = "${launcher}";

      ExecStopPost = [
        "/bin/sh -c 'if [ \"$(${pkgs.coreutils}/bin/cat /run/model-lock/active_npu 2>/dev/null)\" = ${lib.escapeShellArg modelId} ]; then ${pkgs.coreutils}/bin/rm -f /run/model-lock/active_npu; fi'"
      ];

      # `oflm` handles SIGINT and stops its server thread; SIGTERM would tear the process
      # down mid-context and leave the amdxdna context to fd teardown.
      KillSignal = "SIGINT";
      TimeoutStopSec = 30;
      Restart = "no";
      NoNewPrivileges = true;
      PrivateTmp = true;
      # Pinned NPU buffers (user buffers / BO registration) need unbounded memlock.
      LimitMEMLOCK = "infinity";
      LimitNOFILE = 1048576;
    };
  };
}
