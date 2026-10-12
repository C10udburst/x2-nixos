{
  config,
  lib,
  pkgs,
  ...
}:
{
  environment.systemPackages = [
    # Hugging Face model download tools
    pkgs.python3Packages.huggingface-hub

    # GPU / APU diagnostics
    pkgs.nvtopPackages.amd # Real-time GPU & VRAM curses monitor
    pkgs.rocmPackages.rocm-smi # ROCm SMI tool
    pkgs.amdgpu_top # Specialized RDNA 3.5 AMDGPU top monitor

    # System inspection
    pkgs.btop
    pkgs.htop
    pkgs.pciutils
    pkgs.usbutils
    pkgs.curl
    pkgs.jq

    # System configuration setup
    pkgs.git
    pkgs.alejandra
  ];
}
