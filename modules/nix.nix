{
  config,
  lib,
  pkgs,
  ...
}:
let
  cachePublicKey = "x2-nixos-1:IuXoIiJ2fNOuT4EVh7C13AXaGGm01vRBbpYlcKZKVqQ=";
  cacheEnabled = cachePublicKey != "";
in
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
      # The NPU engine's dependency closure (XRT + amdxdna plugin, boost, the Rust tokenizer
      # crates). The engine itself is not cached upstream, but its ~130-input closure is,
      # which is the difference between a short engine compile and rebuilding XRT too.
      # NOT a flake `nixConfig` entry on purpose: a substituter declared that way applies
      # only to trusted users and is otherwise ignored in silence.
      "https://nix-amd-ai.cachix.org"
      # "https://nixos-rocm.cachix.org"
    ];

    extra-trusted-public-keys = [
      "comfyui.cachix.org-1:33mf9VzoIjzVbp0zwj+fT51HG0y31ZTK3nzYZAX0rec="
      "nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs="
      "cache.nixos-cuda.org:74DUi4Ye579gUqzH4ziL9IyiJBlDpMRn9MBN8oNan9M="
      "numtide.cachix.org-1:psk1bDfU1UhVfiVNyPCxyhR+FtmpNkamWT0DwIK+jic="
      "nix-amd-ai.cachix.org-1:F4OU4vw/lV2oiG6SBHZ+nqjl4EFJuqI4X9A7pvaBmhQ="
      # "nixos-rocm.cachix.org-1:VEpsf7pRIijjd8csKjFNBGzkBqOmw8H9PRmgAq14LnE="
    ];

    auto-optimise-store = true;
    warn-dirty = false;
  };

  # What CI publishes to ghcr.io/<owner>/<repo>/nix-cache. GHCR cannot be a substituter on
  # its own, so nixcache-proxy answers narinfos from the cache index and streams the NAR
  # blobs on localhost; the package is public, so the proxy pulls anonymously.
  services.nixcache-proxy = lib.mkIf cacheEnabled {
    enable = true;
    repo = "c10udburst/x2-nixos";
    publicKey = cachePublicKey;
  };

  # What the proxy forwards a miss to: every cache above, minus itself.
  systemd.services.nixcache-proxy.environment.NIXCACHE_UPSTREAM = lib.mkIf cacheEnabled (
    let
      all = lib.unique (
        (config.nix.settings.substituters or [ "https://cache.nixos.org" ])
        ++ (config.nix.settings.extra-substituters or [ ])
      );
      isLocal = s: lib.hasPrefix "http://localhost" s || lib.hasPrefix "http://127.0.0.1" s;
    in
      builtins.concatStringsSep " " (
        map (lib.removeSuffix "/") (builtins.filter (s: !isLocal s) all)
      )
  );

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
