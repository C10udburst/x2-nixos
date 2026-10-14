{
  config,
  pkgs,
  lib,
  ...
}:
{
  imports = [
    ./hardware-configuration.nix
    ./modules/dash
    ./modules/minimal.nix
    ./modules/models.nix
    ./modules/network.nix
    ./modules/nix.nix
    ./modules/pkgs.nix
    ./modules/tailscale.nix
    ./modules/users.nix
  ];

  networking.hostName = "evo-x2";

  # Minimal NetworkManager for dual 2.5G LAN and Wi-Fi 7
  networking.networkmanager.enable = true;

  # Boot with 0 VRAM used until models are downloaded to /srv/models
  services.defaultModel = null;

  nixpkgs.overlays = [
    (final: prev: {
      pythonPackagesExtensions = prev.pythonPackagesExtensions ++ [
        # ComfyUI uses python3.12
        (
          python-final: python-prev:
          prev.lib.optionalAttrs (python-prev.isPy312 or false) {
            buildPythonPackage = {
              __functor =
                self: args:
                (python-prev.buildPythonPackage args).overridePythonAttrs (_: {
                  doCheck = false;
                  doInstallCheck = false;
                  dontCheck = true;
                  dontUsePythonImportsCheck = true;
                  pythonImportsCheck = [ ];
                  dontCheckRuntimeDeps = true;
                  dontCheckPythonMetadata = true;
                });
              override =
                newArgs:
                let
                  base = python-prev.buildPythonPackage.override newArgs;
                in
                {
                  __functor =
                    self: args:
                    (base args).overridePythonAttrs (_: {
                      doCheck = false;
                      doInstallCheck = false;
                      dontCheck = true;
                      dontUsePythonImportsCheck = true;
                      pythonImportsCheck = [ ];
                      dontCheckRuntimeDeps = true;
                      dontCheckPythonMetadata = true;
                    });
                  override = base.override;
                };
            };
          }
        )
      ];
    })
  ];

  # Time & Locale
  time.timeZone = "Europe/Warsaw";
  i18n.defaultLocale = "en_US.UTF-8";

  system.stateVersion = "26.05";
}
