{
  config,
  lib,
  pkgs,
  ...
}:
{
  nix.settings = {
    experimental-features = [
      "nix-command"
      "flakes"
    ];

    trusted-users = [
      "root"
      "@wheel"
    ];

    # Binary caches / substituters including ComfyUI, nix-community, and optional ROCm cache
    extra-substituters = [
      "https://comfyui.cachix.org"
      "https://nix-community.cachix.org"
      "https://cache.nixos-cuda.org"
      "https://numtide.cachix.org"
      # "https://nixos-rocm.cachix.org"
    ];

    extra-trusted-public-keys = [
      "comfyui.cachix.org-1:33mf9VzoIjzVbp0zwj+fT51HG0y31ZTK3nzYZAX0rec="
      "nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs="
      "cache.nixos-cuda.org:74DUi4Ye579gUqzH4ziL9IyiJBlDpMRn9MBN8oNan9M="
      "numtide.cachix.org-1:psk1bDfU1UhVfiVNyPCxyhR+FtmpNkamWT0DwIK+jic="
      # "nixos-rocm.cachix.org-1:VEpsf7pRIijjd8csKjFNBGzkBqOmw8H9PRmgAq14LnE="
    ];

    auto-optimise-store = true;
    warn-dirty = false;
  };

  # Periodic garbage collection for headless server
  nix.gc = {
    automatic = true;
    dates = "weekly";
    options = "--delete-older-than 7d";
  };

  # Periodic nix store hardlink optimisation
  nix.optimise.automatic = true;

  # Allow unfree packages
  nixpkgs.config.allowUnfree = true;
}
