# The `/v1/*` router, built from `./src`.
#
# `cargoBuild` rather than a hand-rolled `rustc` call: the crate has **zero** dependencies (see
# Cargo.toml - all libc access is hand-written FFI in `src/ffi.rs`), so there is nothing to
# fetch, vendor, or re-hash when nixpkgs moves, and the build stays offline. That is what keeps
# the hot path free of an HTTP framework while still building reproducibly.
{ lib, rustPlatform }:
rustPlatform.buildRustPackage {
  pname = "switcher";
  version = "0.1.0";

  # `target/` holds a host-built cargo cache; copying it into the store is slow and pointless.
  src = lib.cleanSourceWith {
    src = ./.;
    filter = path: _:
      let
        base = baseNameOf (toString path);
      in
        base != "target" && !(lib.hasPrefix "target/" (lib.removePrefix "${./.}/" (toString path)));
  };

  # Unit tests are part of the crate; running them at build time catches a regression before it
  # reaches the host that has 128 GB of model weights hanging off it.
  doCheck = true;

  # Zero dependencies, so this hashes an empty vendor tree rather than any crate. It still has
  # to be a real fixed-output hash: if a dependency is ever added to Cargo.toml this changes and
  # the build fails instead of silently reaching the network.
  cargoHash = "sha256-lWcmffBfWgI4wKRC3NTsVbr+52DMltWchQQaygyEks0=";

  meta = {
    description = "Model-aware HTTP relay for the EVO-X2 inference gateway";
    license = lib.licenses.mit;
    mainProgram = "switcher";
  };
}
