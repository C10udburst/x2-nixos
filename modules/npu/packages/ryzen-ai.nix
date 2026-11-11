# Ryzen AI NPU runtime as real derivations - no install scripts, everything pinned by hash.
#
# AMD ships the NPU stack as one 12 GB tarball of Linux wheels plus a separate XRT zip of
# Debian packages (pypi.amd.com is not usable here: it answers 403 from both the workstation
# and the box). So the recipe is:
#
#   dist        fetchurl the tarball, extract ONLY the three wheels the inference stack needs
#               (1.5 GB of the 12 GB) plus deployment.tar.gz -> deployment/lib (2.5 GB).
#   xrt         fetchurl the zip, dpkg-deb -x its four .deb files into one tree.
#   libs        symlink farm of everything the native libs dlopen: AMD deployment libs, XRT
#               libs, plus the host .so files the wheels expect (z, uuid, ncurses, tinfo,
#               libpython3.12). This is what LD_LIBRARY_PATH points at.
#   amdPythonEnv pip-install the three wheels into one prefix (they all write into
#               onnxruntime/capi, so they must share a site-packages, exactly like upstream's
#               setup script does) and smoke-test that the VitisAI EP registers.
#   pythonPath  search path for the interpreter: AMD wheels + the PyPI deps they need.
#
# Two things the derivations fix up that a plain unpack would not:
#   * PT_GNU_STACK executable-stack requests (kernel >= 6.6 refuses them on dlopen) -
#     see strip-execstack.py.
#   * nothing else: the objects are found through LD_LIBRARY_PATH, no rpath rewriting needed.
#
# `voe` (2.8 GB), `ryzenai_dynamic_dispatch*` (2.7 GB) and `cardano` (0.3 GB) are deliberately
# NOT installed: voe is a calibration/quantisation tool, cardano is the AIE *compiler* client,
# and the dynamic-dispatch runtime those wheels wrap already lives in deployment/lib
# (libdyn_bins.so 1.38 GB + libdyn_dispatch_core.so 206 MB). Verified by running the AMD
# quicktest end to end on the NPU without them.
{
  lib,
  stdenv,
  runCommand,
  fetchurl,
  unzip,
  dpkg,
  python312,
  zlib,
  libuuid,
  ncurses,
  # Anything else the runners should see on PYTHONPATH, e.g. python312.pkgs.tokenizers for
  # runners/embeddings_runner.py (see services.npu.extraPythonPackages).
  extraPythonPackages ? [ ],
}:
let
  # The wheels' dependencies come from nixpkgs' CPython 3.12 package set - the AMD wheels are
  # CPython 3.12 ABI specific, which is why services.npu.pythonPackage defaults to python312.
  #
  # `tokenizers` is deliberately absent: in nixpkgs it carries a check-input chain
  # (datasets -> httpx -> anyio) whose tests currently fail, which would make the whole NPU
  # environment unbuilt-able. It is not needed by the genai runner (OGA ships its own
  # tokenizer); add it through services.npu.extraPythonPackages when a runner really wants it.
  py = python312.pkgs;
  pythonDeps = [
    py.numpy
    py.coloredlogs
    py.flatbuffers
    py.packaging
    py.protobuf
    py.sympy
  ] ++ extraPythonPackages;

  version = "1.9.0";

  baseUrl = "https://download.amd.com/opendownload/RyzenAI/${version}";

  distSrc = fetchurl {
    url = "${baseUrl}/ryzen_ai-${version}.tgz";
    hash = "sha256-9CRhlh1rTzlXBO00P+881lKO7ChRAfpS6gLc2QTw0H8=";
  };

  xrtSrc = fetchurl {
    # AMD names the XRT zip without the patch level: RAI_1.9_..., not RAI_1.9.0_....
    url = "${baseUrl}/RAI_1.9_Linux_NPU_XRT.zip";
    hash = "sha256-B0yYH62DnqS3YjM39j7XcuNGn1IS0WwiCw9viwAreHc=";
  };

  stripExecstack = ./strip-execstack.py;

  # Clear PT_GNU_STACK X on every ELF object below $out.
  stripExecstackPhase = ''
    find "$out" -type f \( -name '*.so' -o -name '*.so.*' \) -print0 \
      | xargs -0 --no-run-if-empty ${python312.interpreter} ${stripExecstack}
  '';

  # Named by the tarball listing of ryzen_ai-1.9.0.tgz. The wildcards keep the recipe readable
  # across patch releases; the tarball hash is what actually pins them.
  wheelGlobs = [
    "./onnxruntime_vitisai-*.whl"
    "./onnxruntime_providers_ryzenai-*.whl"
    "./onnxruntime_genai_ryzenai-*.whl"
  ];

  dist = runCommand "ryzen-ai-dist-${version}" {
    src = distSrc;
    nativeBuildInputs = [ python312 ];
  } ''
    mkdir -p "$out/wheels" "$out/deployment" work

    # The tarball is 12 GB; only these members matter for inference.
    tar -xf "$src" -C work --wildcards \
      ${lib.concatMapStringsSep " " (glob: "'${glob}'") wheelGlobs} \
      './deployment.tar.gz'

    mv work/*.whl "$out/wheels/"
    tar -xf work/deployment.tar.gz --strip-components=1 -C "$out/deployment"

    # AMD builds these with an executable stack; the kernel rejects that on dlopen.
    ${stripExecstackPhase}

    test -f "$out/deployment/lib/libonnxruntime.so"
    test -f "$out/deployment/lib/libonnxruntime_providers_vitisai.so"
    test -f "$out/deployment/lib/libdyn_bins.so"
    test -f "$out/deployment/lib/libdyn_dispatch_core.so"
    # (no compgen in a non-interactive stdenv shell)
    test "$(find "$out/wheels" -name 'onnxruntime_vitisai-*.whl' | wc -l)" -eq 1
    test "$(find "$out/wheels" -name '*.whl' | wc -l)" -eq 3
  '';

  # XRT arrives as Debian packages; unpack them into one tree instead of installing dpkg.
  xrt = runCommand "ryzen-ai-xrt-${version}" {
    src = xrtSrc;
    nativeBuildInputs = [
      unzip
      dpkg
      python312
    ];
  } ''
    mkdir -p "$out" work
    unzip -q "$src" -d work
    for deb in work/*.deb; do
      dpkg-deb -x "$deb" "$out"
    done
    rm -rf work

    ${stripExecstackPhase}

    test -d "$out/opt/xilinx/xrt/lib"
    test -f "$out/opt/xilinx/xrt/lib/libxrt_core.so"
  '';

  # Out-of-tree amdxdna driver source shipped by XRT, unpacked for a DKMS build. Needed when
  # the in-tree driver lags the runtime userspace (see PLAN.md: BO creation fails on 7.2.9).
  amdxdnaSource = runCommand "amdxdna-driver-src" { } ''
    mkdir -p "$out"
    tar -xf ${xrt}/opt/xilinx/xrt/share/amdxdna/amdxdna.tar.gz -C "$out" --strip-components=1
  '';

  # Everything the AMD/XRT objects DT_NEED outside of themselves, in one directory for
  # LD_LIBRARY_PATH.
  libs = runCommand "ryzen-ai-libs-${version}" { } ''
    mkdir -p "$out/lib"

    link() {
      for f in $1; do
        [ -e "$f" ] || continue
        ln -sf "$f" "$out/lib/$(basename "$f")"
      done
    }

    link "${dist}/deployment/lib/*.so"
    link "${dist}/deployment/lib/*.so.*"
    link "${xrt}/opt/xilinx/xrt/lib/*.so"
    link "${xrt}/opt/xilinx/xrt/lib/*.so.*"

    # Host libraries the AMD wheels were linked against on Ubuntu.
    link "${zlib}/lib/libz.so*"
    link "${libuuid.lib}/lib/libuuid.so*"
    link "${ncurses}/lib/libncurses.so*"
    link "${ncurses}/lib/libtinfo.so*"
    link "${python312}/lib/libpython3.12.so*"
  '';

  # Relative path of the Ryzen AI execution provider inside the env, handed to ORT through
  # RYZENAI_EP_PATH.
  ryzenaiProvider = "lib/python3.12/site-packages/onnxruntime/capi/libonnxruntime_providers_ryzenai.so";

  # The three wheels all install files into onnxruntime/capi, so they have to land in one
  # prefix. --no-deps is intentional: their dependencies come from nixpkgs via pythonPath,
  # and the heavyweight ones (voe) are not needed at runtime.
  amdPythonEnv = stdenv.mkDerivation {
    pname = "ryzen-ai-python-env";
    inherit version;

    src = dist;
    # Host libs the wheels' objects DT_NEED; present at build time so the install check's
    # import resolves exactly like it does in the unit.
    nativeBuildInputs = [
      python312
      py.pip
      zlib
      libuuid
      ncurses
    ];

    configurePhase = "true";
    buildPhase = "true";

    installPhase = ''
      runHook preInstall
      export HOME="$TMPDIR"
      export PIP_BREAK_SYSTEM_PACKAGES=1
      export PIP_NO_CACHE_DIR=1

      ${python312.interpreter} -m pip install \
        --no-deps --no-index --no-build-isolation \
        --prefix="$out" \
        "$src"/wheels/onnxruntime_vitisai-*.whl \
        "$src"/wheels/onnxruntime_providers_ryzenai-*.whl \
        "$src"/wheels/onnxruntime_genai_ryzenai-*.whl

      runHook postInstall
    '';

    postInstall = stripExecstackPhase;

    # Build-time proof that the stack is loadable, not just unpacked: the same provider
    # handshake the runners perform at start-up. installCheck (not check) because the wheels
    # only exist after installPhase.
    doInstallCheck = true;
    installCheckPhase = ''
      runHook preInstallCheck
      export LD_LIBRARY_PATH="${libs}/lib"
      export HOME="$TMPDIR"
      export PYTHONPATH="$out/lib/python3.12/site-packages:${
        lib.makeSearchPath "lib/python3.12/site-packages" pythonDeps
      }"
      ${python312.interpreter} - <<'PY'
      import onnxruntime as ort

      print("onnxruntime", ort.__version__, ort.get_available_providers())
      assert "VitisAIExecutionProvider" in ort.get_available_providers()
      assert "CPUExecutionProvider" in ort.get_available_providers()
      PY
      runHook postInstallCheck
    '';
  };

  # Search path for the interpreter: AMD wheels first, then the PyPI deps they require.
  pythonPath = lib.makeSearchPath "lib/python3.12/site-packages" ([ amdPythonEnv ] ++ pythonDeps);
in
{
  inherit
    dist
    xrt
    amdxdnaSource
    libs
    amdPythonEnv
    pythonPath
    ;

  # Environment for the runner processes, ready to hand to systemd's `environment`.
  runtimeEnv = {
    XILINX_XRT = "${xrt}/opt/xilinx/xrt";
    LD_LIBRARY_PATH = "${libs}/lib";
    PYTHONPATH = pythonPath;
    RYZENAI_EP_PATH = "${amdPythonEnv}/${ryzenaiProvider}";
  };
}
