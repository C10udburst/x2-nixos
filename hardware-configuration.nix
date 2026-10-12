{
  config,
  lib,
  pkgs,
  modulesPath,
  ...
}: {
  imports = [
    (modulesPath + "/installer/scan/not-detected.nix")
  ];

  # Bootloader setup
  boot.loader.systemd-boot.enable = true;
  boot.loader.systemd-boot.configurationLimit = 5;
  boot.loader.efi.canTouchEfiVariables = true;

  # Initrd & Kernel Modules for AMD Ryzen AI Max+ 395 (Strix Halo)
  boot.initrd.availableKernelModules = [
    "nvme"
    "xhci_pci"
    "thunderbolt"
    "usb_storage"
    "sd_mod"
  ];
  boot.initrd.kernelModules = ["amdgpu"];
  boot.kernelModules = ["kvm-amd"];
  boot.extraModulePackages = [];

  # Filesystem mounts matching disko configuration (/dev/nvme0n1)
  fileSystems."/" = {
    device = lib.mkDefault "/dev/disk/by-partlabel/disk-main-root";
    fsType = "btrfs";
    options = [ "subvol=@" "compress=zstd" "ssd" "noatime" ];
  };

  fileSystems."/nix" = {
    device = lib.mkDefault "/dev/disk/by-partlabel/disk-main-root";
    fsType = "btrfs";
    options = [ "subvol=@nix" "compress=zstd" "ssd" "noatime" ];
  };

  fileSystems."/home" = {
    device = lib.mkDefault "/dev/disk/by-partlabel/disk-main-root";
    fsType = "btrfs";
    options = [ "subvol=@home" "compress=zstd" "ssd" "noatime" ];
  };

  fileSystems."/srv" = {
    device = lib.mkDefault "/dev/disk/by-partlabel/disk-main-root";
    fsType = "btrfs";
    options = [ "subvol=@srv" "compress=none" "ssd" "noatime" ];
  };

  fileSystems."/boot" = {
    device = lib.mkDefault "/dev/disk/by-partlabel/disk-main-ESP";
    fsType = "vfat";
    options = [ "fmask=0077" "dmask=0077" ];
  };

  swapDevices = [];

  # Platform
  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";
  hardware.cpu.amd.updateMicrocode = lib.mkDefault config.hardware.enableRedistributableFirmware;
}
