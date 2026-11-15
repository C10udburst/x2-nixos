# libosmos model entry: one `osmos-api` front, one port, one systemd unit.
#
# The same shape as ./gufo/mkGufo.nix and ./kyojin/mkKyojin.nix, with two things of its
# own:
#
# * **The engine is a pair of processes.** `osmos-api` is the OpenAI server; it spawns
#   `osmos-serve` (the engine) beside itself and drives it over stdin/stdout. systemd
#   therefore gets `SIGTERM` and a stop timeout past the front's own 120 s wait
#   (`API_QUIT_S` in tools/api/main.c): on a graceful end `osmos-serve` writes every
#   live conversation to its slot folder before it exits.
#
# * **Its command line is a JSON file, not flags.** The engine reads `osmos.json` and
#   refuses any key it does not know, so the file is generated here from the declared
#   paths - the same role the flag array plays in the other factories. Weights stay host
#   state (modules/libosmos/dl.sh places them); only the shape of the run is in Nix.
#
# One pack directory can back several registry entries: the abliteration is *one key* in
# the config (`overlay`, a GGUF whose tensors stand in for the model's of the same
# names), so the stock and the uncensored model share their hundreds of gigabytes instead
# of duplicating them - exactly how mkKyojin's `glm-5.3-flash-uncensored` reuses its base.
#
# The engine names itself `osmos-<pack>` on `/v1/models` and ignores the `model` a request
# carries, so `remappedModel` defaults to that name rather than to the registry key: it is
# the string the backend itself answers with.
{ pkgs, lib, config, ... }:
{
  modelId ? name,
  name ? null,
  # The pack's FIRST shard, relative to modelsDir (absolute paths pass through). osmos
  # opens a split model by shard one alone and derives its siblings' names from it
  # (`-00002-of-00005` and friends), so this is the only path it needs of the shards.
  modelPath,
  remappedModel ? "osmos-${modelId}",
  description ? "",
  # `max_context` in the config: the window the engine reserves. DeepSeek's packs ship at
  # 1M and Qwen's at 512K; a shorter window is a smaller KV cache, not a different model.
  context ? null,
  # `parallel`: conversations the engine interleaves. Its determinism claim holds across
  # them (the whole point of the engine), so this is a throughput knob, not a risk.
  sessions ? 1,
  port ? (config.services.libosmos.backendPort or 8086),
  modelsDir ? (config.services.libosmos.modelsDir or "/srv/models"),
  package ? config.services.libosmos.package,
  # The expert pick profile (a pack's own: `picks/UD-IQ1_M/osmos-picks.bin`).
  picksPath ? null,
  # The drafter: a DSpark directory (`dspark/`), or one GGUF for an MTP head.
  drafterPath ? null,
  # huihui-ai's abliteration, applied at load as a tensor overlay. Nothing else differs.
  overlayPath ? null,
  # Tokens one answer may take (the packs ship 4096: the engine's own step size).
  maxTokens ? null,
  # GiB of expert/dense weights kept resident, `auto` when unset (the engine sizes itself
  # to what the GPU may map). `draftedBudgetGib` is the same bound with a drafter loaded.
  budgetGib ? null,
  draftedBudgetGib ? null,
  # GiB of system RAM the engine leaves free beside the model (upstream default 8).
  fillGib ? null,
  noGuess ? false,
  streamNgram ? false,
  # Passed to osmos-api verbatim: --ctx 512k, ...
  extraArgs ? [ ],
  env ? { },
}:
let
  cfg = config.services.libosmos or { };
  modelsHome = cfg.stateDir or "/var/lib/osmos";

  resolvePath = p: if lib.hasPrefix "/" p then p else "${modelsDir}/${p}";
  modelFile = resolvePath modelPath;
  packDir = builtins.dirOf modelFile;

  # osmos-api's own rule: the file is read whole and an unknown key is refused by name, so
  # only fields with a value are written, and only fields tools/api/config.c knows.
  osmosConfig = {
    pack = modelId;
    title = description;
    model = modelFile;
  } // lib.optionalAttrs (picksPath != null) {
    picks = resolvePath picksPath;
  } // lib.optionalAttrs (drafterPath != null) {
    drafter = resolvePath drafterPath;
  } // lib.optionalAttrs (overlayPath != null) {
    overlay = resolvePath overlayPath;
  } // lib.optionalAttrs (context != null) {
    max_context = context;
  } // lib.optionalAttrs (sessions != null) {
    parallel = sessions;
  } // lib.optionalAttrs (maxTokens != null) {
    max_tokens = maxTokens;
  } // lib.optionalAttrs (budgetGib != null) {
    budget_gib = budgetGib;
  } // lib.optionalAttrs (draftedBudgetGib != null) {
    drafted_budget_gib = draftedBudgetGib;
  } // lib.optionalAttrs (fillGib != null) {
    fill_gib = fillGib;
  } // lib.optionalAttrs noGuess {
    no_guess = true;
  } // lib.optionalAttrs streamNgram {
    stream_ngram = true;
  };

  configJson = pkgs.writeText "osmos-${modelId}.json" (builtins.toJSON osmosConfig);

  launcher = pkgs.writeShellScript "libosmos-run-${modelId}" ''
    set -euo pipefail

    # The weights are host state, so the one thing this can say about a missing pack is
    # the command that places it.
    FIRST_SHARD="${modelFile}"
    if [ ! -f "$FIRST_SHARD" ]; then
      echo "Error: $FIRST_SHARD is not there - the pack was never downloaded." >&2
      echo "On this host, from a checkout of the repo: ./modules/libosmos/dl.sh" >&2
      exit 1
    fi

    # The engine answers /v1/models with "osmos-" + the pack in its config; remappedModel
    # defaults to exactly that, so the two agreeing is the check that the config is ours.
    echo "Launching libosmos with pack: $FIRST_SHARD (served as: ${remappedModel})"

    ARGS=(
      --config "${configJson}"
      --host 127.0.0.1
      --port "${toString port}"
    )

    ${lib.concatMapStringsSep "\n" (arg: "ARGS+=(${lib.escapeShellArg arg})") extraArgs}

    exec ${package}/bin/osmos-api "''${ARGS[@]}"
  '';
in
{
  device = "gpu";
  serviceName = "libosmos-${modelId}.service";
  type = "libosmos";
  inherit remappedModel description sessions context;
  url = "http://127.0.0.1:${toString port}";
  # The router pre-flights this before it wakes the unit: a pack that was never
  # downloaded answers "model files not found" instead of dying mid-start.
  modelDir = packDir;

  systemdService = {
    description = "libosmos LLM Service: ${modelId} (${description})";
    after = [ "network.target" ];
    environment = {
      # Saved conversations go to the engine's model folder by default; /srv/models is
      # shared with every other engine, so they get a directory of their own instead.
      HOME = modelsHome;
      OSMOS_SLOT_DIR = "${modelsHome}/slots/${modelId}";
    } // env;

    serviceConfig = {
      Type = "simple";
      User = "libosmos";
      Group = "libosmos";
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
        "/bin/sh -c 'mkdir -p ${modelsHome}/slots/${modelId}'"
        "${config.services.workload-manager.claimStateScript} gpu ${lib.escapeShellArg modelId}"
      ];
      ExecStart = "${launcher}";
      ExecStopPost = [
        "/bin/sh -c 'if [ \"$(${pkgs.coreutils}/bin/cat /run/model-lock/active_gpu 2>/dev/null)\" = ${lib.escapeShellArg modelId} ]; then ${pkgs.coreutils}/bin/rm -f /run/model-lock/active_gpu; fi'"
      ];

      # SIGTERM is the front's own graceful end: it QUITs the engine and waits for it to
      # write the conversations (120 s upstream), so the stop timeout must clear that.
      KillSignal = "SIGTERM";
      TimeoutStopSec = 150;
      Restart = "no";
      # The engine reads experts with O_DIRECT and maps the whole quantized model: both
      # need the same room the other GPU engines get.
      LimitMEMLOCK = "infinity";
      LimitNOFILE = 1048576;
    };
  };
}
