# SGLang for AMD Strix Halo (gfx1151 / RDNA 3.5 iGPU) — base support module.
#
# Why the engine is not just another nixpkgs package:
#   * nixpkgs has no sglang at all, and PyPI only publishes wheels built from the
#     CUDA-side pyproject.toml (torch + flashinfer[cu13] + cuda-python);
#   * upstream's supported path for this exact APU is `docker/rocm-gfx1151.Dockerfile`
#     (tag v0.5.23): rocm/pytorch base, python/pyproject.toml replaced by
#     pyproject_other.toml (the torch-version-agnostic `srt_hip` extra), and
#     SGLANG_USE_AITER=0 because aiter's compiled attention/RMSNorm kernels are
#     CDNA-only (v_pk_mul_f32, wave64 templates).
#
# We reproduce that recipe without Docker:
#   modules/sglang/packages/source.nix   pure-Python engine, dependencies cut off pip
#   modules/sglang/packages/deps.nix     those dependencies as a Nix call graph
#                                        (nixpkgs catalogue + ROCm-enabled torch)
#   modules/sglang/mkSGLang.nix          per-model `sglang serve` services
#
# The engine runs inside an FHS environment because it dlopen()s the ROCm runtime and
# JIT-compiles Triton/Gluon kernels at run time.
{
  config,
  lib,
  pkgs,
  inputs ? { },
  ...
}: let
  cfg = config.services.sglang;

  # SGLang publishes CPython-extension wheels for 3.11-3.13 only, while nixpkgs defaults to
  # 3.14, so the whole stack is built against an explicitly chosen interpreter instead of
  # `pkgs.python3`. mkSGLang and deps.nix receive this same value: mixing interpreters would
  # fail inside the engine's extension modules rather than with a clean import error.
  sglangPythonPackage = pkgs.python313;

  engine = pkgs.callPackage ./packages/source.nix {
    inherit (cfg) version;
    python = sglangPythonPackage;
  };

  # The engine's dependency closure as a Nix call graph (no pip resolution at run time).
  pythonEnv = pkgs.callPackage ./packages/deps.nix {
    python3 = sglangPythonPackage;
  };

  # That interpreter with the closure attached. Passing the *list* to withPackages (rather
  # than an attribute set built from `python3.pkgs`) matters: buildFHSEnv evaluates every
  # element of targetPkgs, so an attr-set-style reference drags unrelated broken candidates
  # (tensorflow) into evaluation.
  sglangPython = sglangPythonPackage.withPackages (_ps: pythonEnv);

  # What the sandbox exists for: ROCm userspace + a C toolchain for Triton's JIT. Everything
  # else the engine needs is reachable by absolute store path, which buildFHSEnv binds
  # read-write, so this list stays short on purpose - each entry is a directory in the FHS
  # view, and the environment's own closure is what gets rebuilt when nixpkgs moves.
  fhsEnv = pkgs.buildFHSEnv (finalAttrs: {
    name = "sglang-env";
    # What the engine needs to see outside the store: the ROCm userspace it dlopen()s, and
    # the toolchain Triton JIT-compiles with. The whole store is bound read-write by
    # buildFHSEnv, so anything reachable by absolute path (the model directories, HOME) does
    # not have to be listed here.
    targetPkgs =
      fpkgs:
      with fpkgs; [
        gcc
        gnumake
        ninja
        pkg-config
        which
        openssl
        zlib
        stdenv.cc.cc.lib
        rocmPackages.clr
        rocmPackages.hipblas
        rocmPackages.rocblas
        rocmPackages.rocm-runtime
        rocmPackages.rocm-smi
        rocmPackages.rocminfo
        rocmPackages.rccl
      ];
    extraOutputsToInstall = [ "dev" ];
    # Triton needs a visible C compiler + ROCm headers when it JIT-compiles, and the ROCm
    # runtime has to be on LD_LIBRARY_PATH because torch dlopen()s it instead of linking it.
    extraEnv = {
      LD_LIBRARY_PATH = "/usr/lib:${pkgs.rocmPackages.rocm-runtime}/lib";
      C_INCLUDE_PATH = "${pkgs.rocmPackages.rocm-runtime}/include";
      CPLUS_INCLUDE_PATH = "${pkgs.rocmPackages.rocm-runtime}/include";
    };
    runScript = "bash";
  });
  # One flat import namespace: the interpreter's own site-packages (deps.nix) plus the
  # pure-Python engine on top. This is what `pip install sglang` would have produced, minus
  # the copy and the venv. Torch pins its own Triton by absolute store path, so the exact
  # interpreter derivation matters more than the version string.
  pythonPath = [
    "${sglangPython}/${sglangPython.libPrefix}/site-packages"
    "${engine}/lib/${sglangPython.libPrefix}/site-packages"
  ];

in {
  options.services.sglang = {
    enable = lib.mkEnableOption "SGLang native LLM inference engine base support" // {
      default = true;
    };

    version = lib.mkOption {
      type = lib.types.str;
      default = "0.5.23";
      description = "SGLang release used by every mkSGLang model.";
    };

    package = lib.mkOption {
      type = lib.types.package;
      default = engine;
      description = "SGLang engine package (pure-Python tree, launched by the FHS env).";
    };

    fhsEnvironment = lib.mkOption {
      type = with lib.types; nullOr package;
      default = fhsEnv;
      description = ''
        FHS environment providing the ROCm userspace and the Triton JIT toolchain.
        Set to null to run the engine directly on the host instead: the store is bound
        into the sandbox anyway, so this only removes the /usr/lib view, the bundled
        compiler and the device-node isolation.
      '';
    };

    backendPort = lib.mkOption {
      type = lib.types.port;
      default = 8084;
      description = "Default loopback port for SGLang backend instances.";
    };

    modelsDir = lib.mkOption {
      type = lib.types.str;
      default = "/srv/models";
      description = "Host directory containing Hugging Face model directories.";
    };

    stateDir = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/sglang";
      description = "HOME of the engine: Triton/torch inductor caches live here.";
    };

    interpreter = lib.mkOption {
      type = lib.types.package;
      default = sglangPython;
      visible = false;
      description = "Python interpreter carrying the engine dependency closure.";
    };

    pythonPath = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = pythonPath;
      visible = false;
      description = "PYTHONPATH entries merging the engine and its dependency closure.";
    };
  };

  config = lib.mkIf cfg.enable {
    users.users.sglang = {
      isSystemUser = true;
      group = "sglang";
      home = cfg.stateDir;
      createHome = true;
      extraGroups = [
        "render"
        "video"
      ];
    };
    users.groups.sglang = { };

    systemd.tmpfiles.rules = [
      "d ${cfg.modelsDir} 0775 sglang render - -"
      "d ${cfg.stateDir} 0775 sglang sglang - -"
      "d /run/model-lock 0777 root root - -"
    ];

  };
}
