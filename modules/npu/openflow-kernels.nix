# Kernel-set package for OpenFlowLM, without a kernel build.
#
# OpenFlowLM ships two things in its repository:
#
#   * `src/lib/xrt/*.so`  - the prebuilt closed engine libraries CMake links and installs;
#   * `src/xclbins/<Model>/*.xclbin` - AMD's precompiled NPU firmware, 234 files, tracked
#     in git (the same firmware FastFlowLM ships).
#
# The flake's own `openflowlm-open-kernels` output ignores those and *compiles* open kernels
# with mlir-aie + Peano (the IRON venv), which is a long build and - for the BERT embedding
# sets - needs `/dev/accel*` at build time and therefore `__noChroot`, which a sandboxed
# `nixos-rebuild` forbids. For this host the closed sets are enough, so the whole toolchain
# is replaced by a copy of the firmware.
#
# It is a copy, not a symlink to the flake source: a symlink would drag the entire 500 MB
# checkout - Windows DLLs included - into the runtime closure of every NPU unit, and keep
# the whole source alive in the store.
#
# The engine finds kernels at `<exe_dir>/../share/oflm/xclbins` before it consults
# `OFLM_XCLBIN_PATH`, which is why the package below has exactly that shape.
#
# Build the real open kernels instead with:
#     openflowlm.packages.${system}.openflowlm-open-kernels            # dense, sandboxed
#     openflowlm.packages.${system}.openflowlm-open-kernels-with-bert  # needs an NPU host
{
  pkgs,
  source,
}:
pkgs.runCommand "openflowlm-repo-kernels" {
  meta.description = "OpenFlowLM NPU kernel sets, taken from the pinned flake source";
  meta.platforms = [ "x86_64-linux" ];
} ''
  mkdir -p $out/share/oflm
  cp -R ${source}/src/xclbins $out/share/oflm/xclbins
  chmod -R u+w $out/share/oflm/xclbins
  # A package that silently ships no firmware is a model that fails at load time, so fail
  # here instead: the two sets this host registers must be present.
  test -f $out/share/oflm/xclbins/Llama-3.2-1B-NPU2/layer.xclbin
  test -f $out/share/oflm/xclbins/Whisper-V3-Turbo-NPU2/whisper_head.xclbin
''
