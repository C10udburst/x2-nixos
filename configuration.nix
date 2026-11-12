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
    ./modules/switcher/service.nix
    ./modules/tailscale.nix
    ./modules/users.nix
  ];

  networking.hostName = "evo-x2";

  # Minimal NetworkManager for dual 2.5G LAN and Wi-Fi 7
  networking.networkmanager.enable = true;

  # Boot with 0 VRAM used until models are downloaded to /srv/models
  services.defaultModel = null;

  # /v1/* is routed by the Rust daemon (unix socket) instead of the FastCGI switcher.sh CGI.
  services.switcher.enable = true;

  # Second inference domain: the XDNA 2 NPU runs its own single workload in parallel with the
  # iGPU (per-domain Rule 1). See modules/npu/README.md for what AMD still blocks.
  services.npu.enable = true;

  # Mainline's amdxdna (0.10.0-era) cannot create the buffer objects AMD's Ryzen AI 1.9.0
  # userspace asks for (DRM_IOCTL_AMDXDNA_CREATE_BO err=-14), so build the driver AMD ships
  # inside XRT. Takes effect on the next reboot; `updates/amdxdna.ko` shadows the in-tree one.
  services.npu.xrtDriver = true;
services.npu.extraPythonPackages = [ pkgs.python312.pkgs.tokenizers ];  # needed by runners/stt_runner.py (ASR)

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
