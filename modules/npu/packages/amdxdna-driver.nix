# AMD's out-of-tree amdxdna NPU driver, built for the running kernel.
#
# Why this exists: AMD develops the XDNA driver out-of-tree (amd/xdna-driver, versioned
# 2.x) and syncs it into mainline much later. The in-tree module is 0.10.0-era and has no
# `amdxdna_ubuf_get_pages`, no descriptor page tables (`amdxdna_dpt.c`) and no `npu6_regs`,
# so the Ryzen AI 1.9.0 userspace fails at session creation with
# `DRM_IOCTL_AMDXDNA_CREATE_BO err=-14` (`amdxdna_get_ubuf: Failed to pin pages`).
#
# The source is not downloaded here: XRT ships it (amdxdna.tar.gz) together with the exact
# build recipe AMD's DKMS package uses, and both are already in the store via
# ./ryzen-ai.nix:
#
#   PRE_BUILD  ./configure_kernel.sh            feature-tests the kernel headers into
#                                             drivers/accel/amdxdna/config_kernel.h
#   MAKE       make -C drivers/accel/amdxdna KERNEL_SRC=<kernel build dir>
#   .ko lands  drivers/accel/amdxdna/build/drivers/accel/amdxdna/amdxdna.ko
#
# Two deviations from a plain `make`, both because the Nix sandbox is not a Ubuntu host:
#   * AMD's Makefile builds in $(SRC_DIR)/build via `cp -rs`, so the source tree has to be a
#     writable copy instead of the read-only store path.
#   * configure_kernel.sh probes with `mktemp -d /tmp/conftest-XXXXXX`; there is no /tmp in
#     the sandbox, so the probe directory is redirected to $TMPDIR. Without this every
#     HAVE_* macro would silently test "no" and the driver would be compiled for an old
#     kernel - a broken module, not a build failure. That is why the configure output is
#     echoed to the log: it is the only evidence of what the module was configured for.
#
# The module keeps the in-tree name, and `boot.extraModulePackages` installs it under
# .../updates/, which depmod searches before kernel/ - so it shadows the in-tree driver
# instead of patching nixpkgs' kernel.
{
  lib,
  stdenv,
  kmod,
  kernel,
  amdxdnaSource,
  xrt,
}:
stdenv.mkDerivation (finalAttrs: {
  pname = "amdxdna";
  # XRT's amdxdna.tar.gz carries no version file; this is the XRT build that shipped it
  # (opt/xilinx/xrt/share/amdxdna/dkms.conf: PACKAGE_VERSION).
  version = "2.26.260102.59";

  src = amdxdnaSource;

  nativeBuildInputs = kernel.moduleBuildDependencies ++ [ kmod ];

  kernelBuildDir = "${kernel.dev}/lib/modules/${kernel.modDirVersion}/build";

  # No unpackPhase: AMD's Makefile builds in $(SRC_DIR)/build via `cp -rs`, so the tree has
  # to be a writable copy rather than the read-only store path. configurePhase, buildPhase and
  # installPhase each cd into it.
  phases = [
    "configurePhase"
    "buildPhase"
    "installPhase"
  ];

  workRoot = "$NIX_BUILD_TOP/work";

  configurePhase = ''
    runHook preConfigure

    mkdir -p ${finalAttrs.workRoot}
    cp -r ${finalAttrs.src}/. ${finalAttrs.workRoot}/
    chmod -R u+w ${finalAttrs.workRoot}
    cd ${finalAttrs.workRoot}

    cp ${xrt}/opt/xilinx/xrt/share/amdxdna/configure_kernel.sh .
    substituteInPlace configure_kernel.sh \
      --replace-fail 'mktemp -d /tmp/conftest' 'mktemp -d "$TMPDIR"/conftest' \
      --replace-fail '[ ! -d "$KERNEL_SRC/include/linux" ]' '[ ! -f "$KERNEL_SRC/Makefile" ]'

    # nixpkgs keeps generated headers and scripts under .../build (whose include/ has no
    # linux/ subdir - kbuild resolves that through its `source` symlink), which AMD's
    # Ubuntu-oriented existence check does not know about. The Makefile is the real proof
    # that this is a prepared kernel build tree.

    export KERNEL_SRC=${finalAttrs.kernelBuildDir}
    export TMPDIR="$NIX_BUILD_TOP/tmp"
    mkdir -p "$TMPDIR"

    # Keep the probe results in the log - they decide which kernel API the module targets.
    ./configure_kernel.sh |& tee "$TMPDIR/configure.log"
    grep -c '#define' drivers/accel/amdxdna/config_kernel.h

    runHook postConfigure
  '';

  # XDNA_BUS_TYPE defaults to pci; the driver's own Makefile wraps kbuild and builds in
  # ./build (see the header comment).
  buildPhase = ''
    runHook preBuild
    cd ${finalAttrs.workRoot}
    export TMPDIR="$NIX_BUILD_TOP/tmp"
    make -C drivers/accel/amdxdna KERNEL_SRC=${finalAttrs.kernelBuildDir}
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    cd ${finalAttrs.workRoot}

    ko=drivers/accel/amdxdna/build/drivers/accel/amdxdna/amdxdna.ko
    test -f "$ko"

    install -D -m 644 "$ko" "$out/lib/modules/${kernel.modDirVersion}/updates/amdxdna.ko"

    # Fail the build if the module would not load on this kernel.
    modinfo "$out/lib/modules/${kernel.modDirVersion}/updates/amdxdna.ko" | grep -q \
      "vermagic:.*${kernel.modDirVersion}"

    runHook postInstall
  '';

  meta = {
    description = "AMD XDNA (Ryzen AI NPU) driver from the XRT package, for kernels whose in-tree amdxdna lags the userspace";
    homepage = "https://github.com/amd/xdna-driver";
    license = lib.licenses.gpl2Only;
    platforms = [ "x86_64-linux" ];
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
  };
})
