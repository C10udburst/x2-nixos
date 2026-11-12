# OpenFlowLM as the engine of the NPU domain.
#
# OpenFlowLM (https://github.com/Atomic-Germ/OpenFlowLM-Next) is a community fork of
# ROCm/FastFlowLM: one process, one OpenAI-compatible server (`oflm serve`), weights and
# kernel sets discovered at runtime. `mkOpenFlow` renders one unit per model exactly like
# `mkGufo`/`mkKyojin` do for the GPU side.
#
# Two packaging decisions live here, both about *not* building the world:
#
#   1. `package` replaces the flake's `openflowlm-open-kernels` argument. The default kernel
#      set is the xclbin tree the repository itself tracks (`src/xclbins`, AMD's prebuilt
#      closed sets, 234 files), so no AIE toolchain enters the closure: no mlir-aie, no
#      Peano, no IRON venv, no `__noChroot` for the BERT sets. To ship the open kernels
#      instead: `kernelsPackage = openflowlm.packages.${system}.openflowlm-open-kernels;`
#   2. Nothing here inherits `services.npu.runtimeEnv`. That environment (Ryzen AI wheels,
#      `RYZENAI_EP_PATH`, the AMD onnxruntime LD path) belongs to the ONNX runners in
#      ./runners. `oflm` links against nixpkgs' XRT + the amdxdna plugin, and its own
#      launcher already defaults `XILINX_XRT`/`LD_LIBRARY_PATH` to them; a unit
#      `Environment=` would beat the wrapper's `--set-default` and hand the engine a
#      foreign XRT.
{
  config,
  lib,
  pkgs,
  inputs ? { },
  ...
}:
let
  cfg = config.services.npu.openflowlm;

  # The flake, or a message that says what to add. Referenced only through `source`, so a
  # host with services.npu.enable = false never evaluates it.
  source = inputs.openflowlm or (throw ''
    services.npu.openflowlm needs an `openflowlm` flake input:
        inputs.openflowlm.url = "github:Atomic-Germ/OpenFlowLM-Next";
    # nixpkgs deliberately does NOT follow: see the note in flake.nix.
  '');

  flakePackages = source.packages.${pkgs.stdenv.hostPlatform.system} or (throw ''
    The openflowlm input provides no package for ${pkgs.stdenv.hostPlatform.system}.
  '');

  # A kernel package with the shape the engine expects
  # (<pkg>/share/oflm/xclbins/<Model>/…), without compiling a single kernel.
  repoKernels = import ./openflow-kernels.nix {
    inherit pkgs;
    source = "${source}";
  };
in
{
  options.services.npu.openflowlm = {
    enable = lib.mkOption {
      type = lib.types.bool;
      # Follows the domain: turning the NPU on is the decision, this option exists to take
      # the engine off while keeping the ONNX runners (or the other way round).
      default = config.services.npu.enable;
      description = "Whether OpenFlowLM is the engine of the NPU domain.";
    };

    package = lib.mkOption {
      type = lib.types.package;
      default = flakePackages.oflm.override {
        openflowlm-open-kernels = cfg.kernelsPackage;
      };
      defaultText = lib.literalExpression ''
        openflowlm.packages.''${system}.oflm.override {
          openflowlm-open-kernels = kernelsPackage;
        }
      '';
      description = ''
        The `oflm` engine in `ExecStart` of every `mkOpenFlow` unit. The kernel set is
        substituted through `kernelsPackage`, which is what keeps the AIE toolchain out of
        the closure.
      '';
    };

    kernelsPackage = lib.mkOption {
      type = lib.types.package;
      default = repoKernels;
      defaultText = lib.literalExpression "<symlink to the flake source's src/xclbins>";
      description = ''
        Anything shaped like `<pkg>/share/oflm/xclbins`. The default exposes the closed
        xclbin sets the OpenFlowLM repository checks in - the same firmware FastFlowLM
        ships - at the cost of one symlink instead of a kernel build.
      '';
    };

    # Read from the flake source, never from the built package: `services.models` is built
    # during evaluation, and importing the catalogue from `$out` would build the engine to
    # evaluate a registry.
    catalogue = lib.mkOption {
      type = lib.types.attrs;
      default = builtins.fromJSON (builtins.readFile "${source}/src/model_list.json");
      description = ''
        The engine's own model registry (`src/model_list.json`). `mkOpenFlow` reads the
        on-disk directory name and the declared context window out of it, so a registry
        entry cannot drift from what the deployed engine serves.
      '';
    };

    modelStore = lib.mkOption {
      type = lib.types.str;
      default = "${config.services.npu.modelsDir}/oflm";
      description = ''
        `OFLM_MODEL_PATH`. The engine reads weights from `<modelStore>/models/<Name>`, with
        `<Name>` the catalogue's own model name (`Llama-3.2-1B-NPU2`), so this is the
        directory that HOLDS the tree. Weights stay host state: no unit here downloads
        anything, and a missing directory fails in `ExecStartPre`.
      '';
    };

    powerMode = lib.mkOption {
      type = lib.types.enum [
        "default"
        "powersaver"
        "balanced"
        "performance"
        "turbo"
      ];
      default = "performance";
      description = ''
        `--pmode` for every workload of the domain. One value for all of them: a Whisper
        left on `powersaver` beside a `turbo` LLM reads as a model regression.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    # The model store and its per-model subdirectory, so `oflm pull` on the host has
    # somewhere to write. 0775/render mirrors modules/gufo: the operator places weights,
    # the service reads them.
    systemd.tmpfiles.rules = [
      "d ${cfg.modelStore} 0775 ${config.services.npu.user} render - -"
      "d ${cfg.modelStore}/models 0775 ${config.services.npu.user} render - -"
    ];

    # `oflm list` / `oflm pull` on the host runs the very store path the units start, so
    # what you inspect is what is deployed.
    environment.systemPackages = [ cfg.package ];
  };
}
