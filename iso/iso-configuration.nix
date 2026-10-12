{
  config,
  pkgs,
  lib,
  ...
}:
let
  autoInstallScript = pkgs.writeShellApplication {
    name = "auto-install";
    runtimeInputs = [
      pkgs.bash
      pkgs.git
      pkgs.curl
      pkgs.jq
      pkgs.newt # provides whiptail
      pkgs.iputils # ping
      pkgs.btrfs-progs
      pkgs.nixos-install-tools
      pkgs.coreutils
      pkgs.gnugrep
      pkgs.shadow # mkpasswd, chpasswd
    ];
    text = builtins.readFile ./auto-install.sh;
  };
in
{
  # Minimal ISO base options
  image.baseName = lib.mkForce "evo-x2-nixos-installer";

  # Enable flakes and modern nix-command
  nix.settings.experimental-features = [
    "nix-command"
    "flakes"
  ];

  # Networking
  networking.networkmanager.enable = true;
  networking.wireless.enable = lib.mkForce false;

  # Additional packages available on the live media
  environment.systemPackages = [
    autoInstallScript
    pkgs.git
    pkgs.newt
    pkgs.btrfs-progs
    pkgs.pciutils
    pkgs.usbutils
    pkgs.htop
    pkgs.nvme-cli
  ];

  # Autologin on tty1 for automated experience
  services.getty.autologinUser = lib.mkDefault "nixos";

  # Run auto-install automatically on login on tty1
  environment.interactiveShellInit = ''
    if [ "$(tty)" = "/dev/tty1" ]; then
      auto-install
    fi
  '';
}
