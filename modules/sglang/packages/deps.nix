# Dependency closure for the SGLang engine (modules/sglang/packages/source.nix).
#
# Why this is hand-maintained instead of `pip install "sglang[all]"`:
#   * the wheel's own Requires-Dist is the CUDA list (torch==2.14.1,
#     flashinfer_python[cu13], cuda-python, nvidia-*, sgl-deep-gemm, quack-kernels,
#     tilelang, ...). None of it resolves on a gfx1151 box, so pip dies before
#     installing anything;
#   * upstream's own answer for this APU - docker/rocm-gfx1151.Dockerfile at v0.5.23 -
#     installs from pyproject_other.toml's torch-version-agnostic `srt_hip` extra on top
#     of a ROCm PyTorch base image, and runs with SGLANG_USE_AITER=0 because aiter's
#     compiled attention/RMSNorm kernels are CDNA-only.
#
# The list below mirrors `runtime_base + runtime_common + srt_hip`, minus:
#   * CUDA/NVIDIA/CUTLASS/FlashInfer packages (no meaning on RDNA 3.5),
#   * sgl-amd-mono (monokernels_hip): its AOT build only accepts gfx942/gfx950/gfx1250,
#   * wave-lang and petit_kernel: optional backend / quant method behind try-except
#     ImportError (srt/layers/attention/wave_backend.py, srt/layers/quantization/
#     petit_utils.py); neither applies to gfx1151,
#   * nvidia-ml-py: GPU telemetry comes from rocm-smi in the FHS env instead.
#
# PyTorch comes from nixpkgs' ROCm variant (`torch.override { rocmSupport = true; }`).
# comfyui-nix pins prebuilt ROCm wheels as an alternative if that build ever gets
# expensive; see services.comfyui in ../comfyui/default.nix for that path.
#
# Verification note: derived from sglang's two manifests, not from a resolved install.
# A missing distribution surfaces as ModuleNotFoundError on first engine start - add it
# here (nixpkgs catalogue first, PyPI fallback second).
{
  lib,
  pkgs,
  python3,
  sglangEngine ? null,
}: let
  # Exactly one torch per environment, enforced by replacing the attribute that every other
  # package looks torch up through. Overriding the dependents individually does not work:
  # compressed-tensors, xgrammar, timm, bitsandbytes and friends each propagate the plain
  # CPU torch, and two torch derivations both exporting bin/.torchfrtrace-wrapped make
  # pkgs.buildEnv abort before compiling anything. Upstream's image gets this for free by
  # installing a single torch wheel that nothing else can replace.
  py = python3.pkgs.overrideScope (final: prev: {
    # `prev.torch` is the attribute the dependents would otherwise resolve to, so overriding
    # it here is what keeps the whole graph on the HIP build.
    # Deliberately NOT `rocmPackages = pkgs.rocmPackages.gfx1151`, which is what the llama.cpp
    # build passes: that scoped set still routes MIOpen through composable_kernel, and
    # composable_kernel-gfx1151 is marked broken in this nixpkgs revision, so even evaluating
    # torch throws. Plain rocmPackages meta passes and lists gfx1151 among its targets, which
    # is all SGLang needs - it runs Triton kernels on this APU, not pre-generated CK tiles.
    torch = prev.torch.override { rocmSupport = true; };
  });

  nixpkgsDeps = with py; [
    aiohttp
    anthropic
    av
    blobfile
    build
    compressed-tensors
    datasets
    einops
    fastapi
    gguf
    interegular
    ipython
    llguidance
    mistral-common
    msgspec
    ninja
    numba
    numpy
    openai
    orjson
    packaging
    partial-json-parser
    pillow
    prometheus-client
    psutil
    pybase64
    pydantic
    python-dateutil
    python-multipart
    pyzmq
    regex
    requests
    safetensors
    scipy
    sentencepiece
    setproctitle
    soundfile
    tiktoken
    tokenizers
    torchvision
    tqdm
    transformers
    uvicorn
    uvloop
    watchfiles
    xgrammar
    xxhash
    zstandard
  ] ++ [
    # Quantisation kernels reached through torch (pure Python + Triton, so it runs on ROCm
    # where the CUDA-only equivalents do not exist). Listed explicitly because it is not a
    # hard dependency of anything above and SGLang imports it for quantised checkpoints.
    torchao
  ] ++ lib.optional (sglangEngine != null) sglangEngine;
in
nixpkgsDeps
