# The libosmos engine (https://github.com/mrsirg97-rgb/libosmos) as a derivation.
#
# Upstream ships no flake and no Nix expression - one Makefile, gcc for the host library,
# ROCm's hipcc for the kernels - so the input is `flake = false` and this file is the whole
# build. Exactly two binaries are installed, and they are the pair every `mkLibosmos` unit
# runs: `osmos-api` is the OpenAI-compatible front and spawns `osmos-serve` - the engine -
# looking for it **beside itself** (`/proc/self/exe`, `--engine` overrides), which is why
# both must land in one bin directory.
#
# Three things the Makefile wants that nixpkgs does not hand over for free:
#
#   * `LIBEVT=<dir>` - the event loop is a git submodule (`third_party/libevt`), and a flake
#     input carries an empty directory where one was. The Makefile documents
#     `LIBEVT=<dir>` for "another checkout", so it arrives as its own input and is named
#     here; nothing is vendored.
#   * `ROCM=<root>` - the Makefile runs `$(ROCM)/bin/hipcc`, compiles with
#     `-I$(ROCM)/include` and links with `-Wl,-rpath,$(ROCM)/lib`. nixpkgs splits that root:
#     `clr` is hipcc plus the HIP headers plus libamdhip64, `rocm-runtime` is hsa's headers
#     plus libhsa-runtime64, and `src/**/hip_*.c` includes both. The joined root below is
#     what the RUNPATH then points at - so no unit has to carry a ROCM variable or an
#     `LD_LIBRARY_PATH`, and `mkGufo`'s `HSA_OVERRIDE_GFX_VERSION` is not needed either
#     (gfx1151 is targeted natively by ROCm 7).
#   * the device bitcode - clang looks for its bitcode next to its own install, and nixpkgs
#     keeps `rocm-device-libs` in a separate output, so `bin/hipcc` inside the root is a
#     one-line wrapper that names it. Without it every kernel dies with "cannot find ROCm
#     device library".
#
# `HIP_ARCH` is pinned to gfx1151 rather than taken from the build machine, the same reason
# `modules/llama-cpp/packages/ricursive.nix` pins it: the host is the GMKtec's RDNA 3.5 iGPU
# and a reproducible build must not depend on which box compiled it.
#
# `NPU=0` (the Makefile's default) is deliberate: the engine's NPU lane needs XRT headers
# and libxrt_coreutil, and the NPU domain on this machine belongs to OpenFlowLM
# (modules/npu). `requant_dspark` is not built either - it needs a llama.cpp tree.
{
  pkgs,
  source,
  libevt,
  gpuTarget ? "gfx1151",
}:
let
  rocm = pkgs.rocmPackages;

  # hipcc, with the two things nixpkgs splits away from a ROCm root: the device bitcode
  # (its own output, which clang cannot locate on its own) and the library search path the
  # Makefile never writes (`-lhsa-runtime64` is passed bare, and the HIP runtime lives in
  # clr while hsa's lives in rocm-runtime).
  hipcc = pkgs.writeShellScript "hipcc" ''
    exec ${rocm.clr}/bin/hipcc \
      --rocm-device-lib-path=${rocm.rocm-device-libs}/amdgcn/bitcode \
      -L${rocm.clr}/lib -L${rocm.rocm-runtime}/lib "$@"
  '';

  # One ROCm root out of the three outputs the Makefile's $(ROCM) expects to be whole.
  rocmRoot = pkgs.runCommand "libosmos-rocm-root" { } ''
    mkdir -p $out/bin $out/include $out/lib

    ln -s ${hipcc} $out/bin/hipcc

    # The HIP headers (clr) and hsa's (rocm-runtime) side by side, as one tree has them.
    ln -s ${rocm.clr}/include/hip $out/include/hip
    ln -s ${rocm.clr}/include/CL $out/include/CL
    ln -s ${rocm.clr}/include/rocm-core $out/include/rocm-core
    ln -s ${rocm.rocm-runtime}/include/hsa $out/include/hsa
    ln -s ${rocm.rocm-runtime}/include/hsakmt $out/include/hsakmt

    # Link-time -lhsa-runtime64 and the RUNPATH the Makefile writes both read this dir.
    for f in ${rocm.clr}/lib/*.so* ${rocm.rocm-runtime}/lib/*.so*; do
      ln -s "$f" "$out/lib/$(basename "$f")"
    done
  '';

  makeFlags = [
    "ROCM=${rocmRoot}"
    "HIP_ARCH=${gpuTarget}"
    "LIBEVT=${libevt}"
  ];
in
pkgs.stdenv.mkDerivation (finalAttrs: {
  pname = "libosmos";
  # Upstream's own release string (include/osmos/version.h), which `--version` prints.
  version = "0.7.6";

  src = source;

  # A real bash array for makeFlags: without this a list becomes one space-joined word
  # and `make` reads "ROCM=… HIP_ARCH=… LIBEVT=…" as a single variable assignment.
  __structuredAttrs = true;
  strictDeps = true;
  dontConfigure = true;
  inherit makeFlags;

  # `all` is the host library alone; the HIP library, the kernels and the two binaries
  # come with the `serve` and `api` targets, which is upstream's own split.
  buildPhase = ''
    runHook preBuild
    make -j$NIX_BUILD_CORES "''${makeFlags[@]}"
    make -j$NIX_BUILD_CORES "''${makeFlags[@]}" serve api
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    install -Dm755 bin/osmos-serve $out/bin/osmos-serve
    install -Dm755 bin/osmos-api $out/bin/osmos-api
    runHook postInstall
  '';

  # Both binaries answer `--version` without touching a GPU, so this catches a broken
  # RUNPATH (the failure mode of the joined root above) at build time. doCheck is off by
  # default in nixpkgs, and with it doInstallCheck - an install check nobody runs is a
  # comment, so it is switched on here.
  doInstallCheck = true;
  installCheckPhase = ''
    $out/bin/osmos-api --version
    $out/bin/osmos-serve --version
  '';

  meta = {
    description = "Bit-reproducible HIP inference engine for DeepSeek-V4.1-Flash and Qwen3.8-Flash-Next on Strix Halo (gfx1151)";
    homepage = "https://github.com/mrsirg97-rgb/libosmos";
    license = pkgs.lib.licenses.mit;
    mainProgram = "osmos-api";
    platforms = [ "x86_64-linux" ];
  };
})
