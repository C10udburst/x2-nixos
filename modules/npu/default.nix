# AMD Ryzen AI NPU subsystem (XDNA 2) for the EVO-X2.
#
# Two independent resource domains share one lock protocol:
#   GPU  - RDNA 3.5 iGPU, /dev/dri/renderD128   (gufo, llama-server, kyojin, immich-ml, comfyui)
#   NPU  - XDNA 2,          /dev/accel/accel0   (ryzen-ai runners managed by this module)
#
# Rule 1 ("one workload in memory") is enforced PER DOMAIN. A GPU workload and an NPU
# workload may be loaded at the same time; unloading one never touches the other.
#
# The proprietary AMD runtime is a build-time derivation (packages/ryzen-ai.nix): fetched by
# hash, unpacked, executable-stack-fixed, and smoke-tested in checkPhase. Nothing is installed
# by a script and nothing lives under /srv except model weights.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.npu;
  ryzenAi = pkgs.callPackage ./packages/ryzen-ai.nix {
    extraPythonPackages = cfg.extraPythonPackages;
  };
  types = lib.types;

  npuGroup = "render";

  # systemd Environment= entries for the runner processes.
  #   XILINX_XRT       -> XRT core + amdxdna driver plugin used by the VitisAIPrefix pipeline
  #   LD_LIBRARY_PATH  -> AMD deployment libs + XRT libs + the Ubuntu .so files they need
  #   PYTHONPATH       -> AMD wheels + their PyPI deps
  #   RYZENAI_EP_PATH  -> providers plugin handed to onnxruntime by the runners
  runtimeEnv = {
    XILINX_XRT = ryzenAi.xrt + "/opt/xilinx/xrt";
    LD_LIBRARY_PATH = ryzenAi.libs + "/lib";
    PYTHONPATH = ryzenAi.pythonPath;
    RYZENAI_EP_PATH = ryzenAi.runtimeEnv.RYZENAI_EP_PATH;
  };
in
{
  # NOTE: ./mkNpuModel.nix is *not* a module - it is a plain factory called from
  # modules/models.nix, exactly like ./../gufo/mkGufo.nix.

  options.services.npu = {
    enable = lib.mkEnableOption "AMD Ryzen AI NPU inference domain";

    # CPython 3.12 ABI is what AMD's wheels are built against; overriding this needs wheels
    # for the interpreter you pick.
    pythonPackage = lib.mkPackageOption pkgs "python312" { };

    runnerSrc = lib.mkOption {
      type = types.path;
      default = ./runners;
      readOnly = true;
      description = "Directory with the per-modality runner scripts.";
    };

    extraPythonPackages = lib.mkOption {
      type = with types; listOf package;
      default = [ ];
      example = lib.literalExpression "[ pkgs.python312.pkgs.tokenizers ]";
      description = ''
        Extra Python packages on the runners' {env}`PYTHONPATH`. The default set covers the
        genai runner; {file}`runners/embeddings_runner.py` additionally wants
        `python312.pkgs.tokenizers`, which is not defaulted in because its nixpkgs check-input
        chain is currently broken (see {file}`packages/ryzen-ai.nix`).
      '';
    };

    runtimeEnv = lib.mkOption {
      type = types.attrsOf types.str;
      default = runtimeEnv;
      description = ''
        Environment exported by every NPU runner service. Defaults to the store paths built by
        {file:modules/npu/packages/ryzen-ai.nix}.
      '';
    };

    modelsDir = lib.mkOption {
      type = types.str;
      default = "/srv/models";
      description = "Base directory holding one subdirectory per NPU model.";
    };

    device = lib.mkOption {
      type = types.str;
      default = "/dev/accel/accel0";
      description = "XDNA accelerator character device granted to NPU services.";
    };

    user = lib.mkOption {
      type = types.str;
      default = "npu";
      description = ''
        User running NPU workloads. Kept separate from the GPU users so a compromised
        inference process cannot read another engine's material, while group `render` still
        grants /dev/accel/accel0.
      '';
    };
  };

  config = lib.mkMerge [
    (lib.mkIf cfg.enable {
      # The wheel environment is validated at build time, so a start-up failure here means the
      # host itself is the problem (missing device node, wrong group).
      systemd.services.npu-runtime-check = {
        description = "Verify the AMD Ryzen AI NPU stack is usable";
        after = [ "systemd-udev-settle.service" ];
        wants = [ "systemd-udev-settle.service" ];
        wantedBy = [ "multi-user.target" ];
        environment = cfg.runtimeEnv;
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          User = cfg.user;
          Group = npuGroup;
          SupplementaryGroups = [ npuGroup ];
        };
        script = ''
          ${cfg.pythonPackage}/bin/python3 - <<'PY'
          import os
          import sys

          import onnxruntime as ort

          device = "${cfg.device}"
          if not os.path.exists(device):
              print(f"NPU: {device} missing - is the amdxdna driver loaded?", file=sys.stderr)
              sys.exit(1)

          providers = ort.get_available_providers()
          print(f"NPU: onnxruntime {ort.__version__} providers={providers}")
          if "VitisAIExecutionProvider" not in providers:
              print("NPU: VitisAIExecutionProvider is not registered", file=sys.stderr)
              sys.exit(1)
          PY
        '';
      };
    })

    {
      # Users and groups exist unconditionally so mkNpuModel units can reference them,
      # mirroring modules/gufo/default.nix and modules/kyojin/default.nix.
      users.users.${cfg.user} = {
        isSystemUser = true;
        group = npuGroup;
        extraGroups = [ npuGroup ];
        home = "/var/empty";
        description = "AMD Ryzen AI NPU inference service";
      };
    }
  ];
}
