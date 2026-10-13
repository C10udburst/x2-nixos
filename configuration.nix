{
  config,
  pkgs,
  lib,
  ...
}: {
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

  # Temporarily disable ComfyUI during initial OS bootstrap to avoid building from source on live media
  services.comfyui.enable = false;

  nixpkgs.overlays = [
    (final: prev: {
      pythonPackagesExtensions = prev.pythonPackagesExtensions ++ [
        (python-final: python-prev: {
          anyio = python-prev.anyio.overridePythonAttrs (_: {
            doCheck = false;
            doInstallCheck = false;
          });
        })
      ];
    })
  ];

  # Time & Locale
  time.timeZone = "Europe/Warsaw";
  i18n.defaultLocale = "en_US.UTF-8";

  system.stateVersion = "26.05";
}
