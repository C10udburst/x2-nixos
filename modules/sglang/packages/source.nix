# SGLang engine for AMD Strix Halo (gfx1151 / RDNA 3.5).
#
# There is no usable binary for this APU anywhere:
#   * PyPI publishes only manylinux wheels built from the CUDA-side pyproject.toml
#     (torch + flashinfer[cu13] + cuda-python) and no sdist;
#   * nixpkgs has no sglang at all;
#   * upstream's own answer for this chip is docker/rocm-gfx1151.Dockerfile, which
#     starts from rocm/pytorch, swaps python/pyproject.toml for pyproject_other.toml
#     (the torch-version-agnostic `srt_hip` extra) and forces SGLANG_USE_AITER=0
#     because aiter's compiled kernels are CDNA-only.
#
# This expression mirrors that recipe without Docker: it installs the pure-Python
# engine from the pinned release into a site-packages tree whose dependencies come
# from ./python-deps.nix (Nix call graph, ROCm PyTorch), never from pip. The engine
# is then launched inside an FHS environment, because it JIT-compiles Triton kernels
# and dlopen()s the ROCm runtime at run time.
#
# Where the inputs come from:
#   * src: the PyPI wheel of the pinned release. PyPI publishes no sdist, and the wheel
#     is what upstream's own release pipeline produces: pure Python plus five
#     CPython-extension modules (srt/rust_extensions/*, srt/mem_cache/rust_tree_core/*)
#     built against manylinux glibc, which NixOS satisfies. Nothing CUDA-specific is
#     bundled - the native ROCm kernels live in the separate `sglang-kernel`
#     distribution, and gfx1151 does not use them (Triton paths, like upstream's image
#     built with BUILD_SGL_KERNEL=0).
#   * pyproject_other.toml: verbatim copy of python/pyproject_other.toml from the same
#     tag, kept next to the tree for reference and for whoever rebuilds from git.
#   * sglang/_version.py: already generated inside the wheel, so it is left alone. When
#     this is switched to a GitHub tarball it must be written explicitly, otherwise
#     setuptools-scm falls back to 0.0.0.dev0 and the version gates in server_args,
#     tokenizer_manager and the MoE layers misbehave.
{
  lib,
  stdenv,
  fetchurl,
  unzip,
  version ? "0.5.23",
  # Interpreter whose ABI matches pyTag below. Callers must pass the same one that carries
  # the dependency closure, or `import sglang` fails with an undefined-symbol error on the
  # extension modules instead of a clean ModuleNotFoundError.
  python ? throw "sglang source: 'python' must be passed (it selects the wheel ABI tag)",
  pyTag ? "cp313",
  distInfo ? "sglang-${version}.dist-info",
}:
stdenv.mkDerivation (finalAttrs: {
  pname = "sglang";
  inherit version;

  # files.pythonhosted.org URLs are content-addressed per file, so the two-directory prefix
  # is part of what changes when upstream re-uploads; keep it next to the hash.
  src = fetchurl {
    url = "https://files.pythonhosted.org/packages/fb/b9/873f06005ec16594eb576b283370785eceecb5ce881a252ed2d47dcbeb85/sglang-${version}-${pyTag}-${pyTag}-manylinux_2_34_x86_64.whl";
    hash = "sha256-EPCyspyP6mFuSyfLu7FH8yqHm/Pbccl2dCWj2dd6Nss=";
  };

  nativeBuildInputs = [ unzip ];

  # stdenv's unpackPhase keys off the file *extension* and has no rule for .whl, so it fails
  # outright rather than sniffing the archive. Unpack by hand instead: `unzip` reproduces the
  # wheel layout (sglang/, sglang-<version>.dist-info/) exactly as pip would install it.
  dontUnpack = true;

  # Already-built artefacts: no compile phase, no stripping of the extension modules.
  dontBuild = true;
  dontStrip = true;

  installPhase = ''
    runHook preInstall

    mkdir -p wheel
    unzip -q "$src" -d wheel
    cd wheel

    mkdir -p "$out/lib/${python.libPrefix}/site-packages"
    cp -r sglang "$out/lib/${python.libPrefix}/site-packages/"
    cp -r "${distInfo}" "$out/lib/${python.libPrefix}/site-packages/"
    cp -r "${distInfo}"/licenses/* "$out/" 2>/dev/null || true

    runHook postInstall
  '';

  # The interpreter is chosen by the caller and invoked explicitly, so nothing gets wrapped.
  dontWrapPythonPrograms = true;

  passthru = {
    python = python;
    pythonLibDir = "${placeholder "out"}/lib/${python.libPrefix}/site-packages";
  };

  meta = {
    description = "SGLang serving engine (gfx1151 posture: Triton attention, dependencies from the FHS env)";
    homepage = "https://github.com/sgl-project/sglang";
    license = lib.licenses.asl20;
    platforms = [ "x86_64-linux" ];
  };
})
