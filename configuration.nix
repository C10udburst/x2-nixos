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
    ./modules/pkgs.nix
    ./modules/tailscale.nix
    ./modules/users.nix
  ];

  networking.hostName = "evo-x2";

  # Minimal NetworkManager for dual 2.5G LAN and Wi-Fi 7
  networking.networkmanager.enable = true;

  # Time & Locale
  time.timeZone = "Europe/Warsaw";
  i18n.defaultLocale = "en_US.UTF-8";

  # Nix package manager settings
  nix.settings = {
    experimental-features = [
      "nix-command"
      "flakes"
    ];
    auto-optimise-store = true;
    warn-dirty = false;
  };

  # Allow unfree packages if needed
  nixpkgs.config.allowUnfree = true;

  system.stateVersion = "26.05";
}
