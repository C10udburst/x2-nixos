# Static frontend build for the dashboard: Tailwind CSS 4 + daisyUI 5 (halloween
# theme) + Lightweight Charts(TM), bundled by esbuild.
#
# Result: a static site directory served directly by Nginx
#   index.html
#   assets/app.<content-hash>.js
#   assets/app.<content-hash>.css
#
# Iterate locally without Nix:
#   cd modules/dash/frontend && npm ci && npm run build     # -> frontend/dist
#
# After touching package.json / package-lock.json, refresh npmDepsHash:
#   set it to lib.fakeHash, build, and copy the reported "got: sha256-…" back in.
{ pkgs, lib }:
pkgs.buildNpmPackage {
  pname = "evo-x2-dashboard";
  version = "1.0.0";

  # node_modules/ and dist/ are build artefacts and must never reach the store
  src = builtins.filterSource (path: _type:
    let
      rel = lib.removePrefix (toString ./frontend + "/") (toString path);
    in
      !lib.hasPrefix "node_modules/" rel && !lib.hasPrefix "dist/" rel
  ) ./frontend;

  npmDepsHash = "sha256-6UVTzsj/RS1CaYZVBZQo1WeooItprLFmfrw+Liheav4=";

  # The output is a static site, not a Node.js module: skip the `npm pack` install hook
  npmInstallHook = pkgs.emptyFile;
  dontNpmPrune = true;

  installPhase = ''
    runHook preInstall
    mkdir -p $out
    cp -r dist/* $out/
    runHook postInstall
  '';
}
