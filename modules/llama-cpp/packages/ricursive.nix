# llama.cpp with the `ricursive` architecture (Ripple-65B Preview), ROCm/gfx1151 build.
#
# Why a dedicated package:
#   Ripple-65B Preview ships a brand-new llama.cpp architecture (`ricursive`:
#   80 layers, 4x sliding-window (1024, RoPE) + 1x global NoPE per group, peri-norm,
#   sigmoid output gate, value residual, clamped SwiGLU). Support was merged upstream
#   in ggml-org/llama.cpp#31692 on 2026-11-05, i.e. AFTER llama.cpp v0.9.0 / b12141 and
#   after the nixpkgs llama-cpp this flake pins, so no release tarball loads these
#   GGUFs yet. Pin the first master commits that carry the port plus its follow-ups:
#     fecdc81  model  : add Ripple (ricursiveai) (#31692)
#     e8df20d  models : recursive fix (#31749)
#     6023692  llama  : fix kv shifting, per-model build_rope (#31683)
#
#   TODO(remove-after-upstream): once nixpkgs ships a llama-cpp release containing
#   #31692, delete this file and let the model fall back to the default
#   `pkgs.llama-cpp.override { rocmSupport = true; }` in mkLlamaCpp.nix.
#
# The expression is a trimmed copy of nixpkgs' llama-cpp package: ROCm backend only,
# and the embedded Web UI is switched off (LLAMA_USE_PREBUILT_UI defaults to ON
# upstream, which would fetch the prebuilt UI from the network at build time).
{
  lib,
  stdenv,
  blas,
  cmake,
  fetchFromGitHub,
  installShellFiles,
  ninja,
  openssl,
  pkg-config,
  rocmPackages,
  rocmSupport ? true,
  # AMD Ryzen AI Max+ 395 iGPU (RDNA 3.5). Pinned instead of using
  # rocmPackages.clr.localGpuTargets so the build is reproducible and does not
  # depend on which machine compiles it.
  rocmGpuTargets ? [
    "gfx1151"
  ],
  cpuArchDynamicDispatch ? true,
  blasSupport ? !rocmSupport,
}:
stdenv.mkDerivation (finalAttrs: {
  pname = "llama-cpp-ricursive";
  version = "0.9.0-dev-e14a779";

  # Informational only (llama-server --version and /props), the tarball has no .git.
  buildNumber = "12139";
  buildCommit = "e14a779";

  __structuredAttrs = true;
  strictDeps = true;

  outputs = [
    "out"
    "dev"
  ];

  src = fetchFromGitHub {
    owner = "ggml-org";
    repo = "llama.cpp";
    rev = "e14a779719652200cec7ad58dfa4820edc347182";
    hash = "sha256-wLlB/7EJbVYE4L8haBAvjLftFYC+CyVcBEw8SDdXtZk=";
  };

  nativeBuildInputs = [
    cmake
    installShellFiles
    ninja
    pkg-config
  ];

  buildInputs = [
    openssl
  ]
  ++ lib.optionals rocmSupport (
    with rocmPackages;
    [
      clr
      hipblas
      rocblas
    ]
  )
  ++ lib.optionals blasSupport [ blas ];

  cmakeFlags = [
    (lib.cmakeBool "GGML_NATIVE" false) # -march=native would make the build non-deterministic
    (lib.cmakeBool "LLAMA_BUILD_EXAMPLES" false)
    (lib.cmakeBool "LLAMA_BUILD_SERVER" true)
    (lib.cmakeBool "LLAMA_BUILD_TESTS" false)
    (lib.cmakeBool "LLAMA_TESTS_INSTALL" false)
    (lib.cmakeBool "LLAMA_BUILD_IS_DEV" false)
    (lib.cmakeBool "LLAMA_OPENSSL" true)
    (lib.cmakeBool "BUILD_SHARED_LIBS" true)
    # No embedded Web UI: keeps node out of the closure and the build offline.
    (lib.cmakeBool "LLAMA_BUILD_UI" false)
    (lib.cmakeBool "LLAMA_USE_PREBUILT_UI" false)
    (lib.cmakeBool "GGML_BLAS" blasSupport)
    (lib.cmakeBool "GGML_CUDA" false)
    (lib.cmakeBool "GGML_HIP" rocmSupport)
    (lib.cmakeBool "GGML_METAL" false)
    (lib.cmakeBool "GGML_RPC" false)
    (lib.cmakeBool "GGML_VULKAN" false)
    (lib.cmakeFeature "LLAMA_BUILD_NUMBER" finalAttrs.buildNumber)
    (lib.cmakeFeature "LLAMA_BUILD_COMMIT" finalAttrs.buildCommit)
  ]
  ++ lib.optionals cpuArchDynamicDispatch [
    # Build every CPU backend variant and load them dynamically: AVX2/AVX512 kernels
    # for the Zen 5 cores without -march=native.
    (lib.cmakeBool "GGML_CPU_ALL_VARIANTS" true)
    (lib.cmakeBool "GGML_BACKEND_DL" true)
    (lib.cmakeFeature "GGML_BACKEND_DIR" "${placeholder "out"}/bin")
  ]
  ++ lib.optionals rocmSupport [
    (lib.cmakeFeature "CMAKE_HIP_COMPILER" "${rocmPackages.clr.hipClangPath}/clang++")
    (lib.cmakeFeature "CMAKE_HIP_ARCHITECTURES" (lib.concatStringsSep ";" rocmGpuTargets))
  ];

  postInstall = lib.optionalString (stdenv.buildPlatform.canExecute stdenv.hostPlatform) ''
    installShellCompletion --cmd llama-server --bash <($out/bin/llama-server --completion-bash)
  '';

  doCheck = false;

  meta = {
    description = "llama.cpp (ROCm ${lib.concatStringsSep "," rocmGpuTargets}) with the ricursive/Ripple architecture";
    homepage = "https://github.com/ggml-org/llama.cpp";
    license = lib.licenses.mit;
    mainProgram = "llama-server";
    platforms = lib.platforms.linux;
  };
})
