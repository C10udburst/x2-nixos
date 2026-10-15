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
# package-lock.json is trimmed to linux/x64 binaries (frontend/scripts/prune-lockfile.mjs),
# because npmDepsHash prefetches every tarball it lists. Refresh it after a dependency
# bump with:  npm run lockfile
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

  npmDepsHash = "sha256-udHygis9rEei3Ljwbzfe2LEECXzmo2nyHv8kYxBpoPw=";

  # Guard rail: an unpruned lockfile silently drags ~100 foreign platform binaries
  # into the npmDeps fetch (and makes it fragile). See scripts/prune-lockfile.mjs.
  doCheck = true;
  checkPhase = ''
    runHook preCheck
    if grep -qE '"(darwin|win32|freebsd|android)"' package-lock.json; then
      echo "package-lock.json still lists foreign platform binaries" >&2
      echo "fix it with: (cd modules/dash/frontend && npm run lockfile)" >&2
      exit 1
    fi
    runHook postCheck
  '';

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
