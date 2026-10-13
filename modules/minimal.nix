{
  config,
  lib,
  pkgs,
  ...
}:
{
  # 1. Headless Bare-Minimal Target
  systemd.defaultUnit = "multi-user.target";

  # Strip all documentation, man pages, and info pages to minimize disk & closure footprint
  documentation = {
    enable = false;
    nixos.enable = false;
    man.enable = false;
    doc.enable = false;
    info.enable = false;
  };

  # Disable desktop sound/audio subsystems
  services.pipewire.enable = false;
  services.pulseaudio.enable = false;

  # Disable printing and bluetooth
  services.printing.enable = false;
  hardware.bluetooth.enable = false;

  # Prevent server from sleeping or suspending
  systemd.targets = {
    sleep.enable = false;
    suspend.enable = false;
    hibernate.enable = false;
    hybrid-sleep.enable = false;
  };

  # 2. Journald In-Memory Volatile Footprint (Capped at 32MB RAM)
  services.journald.settings.Journal = {
    Storage = "volatile";
    RuntimeMaxUse = "32M";
    SystemMaxUse = "32M";
  };

  # 3. Kernel & Memory Tuning for 128GB Unified Strix Halo APU
  # AMD Ryzen AI Max+ 395 (Zen 5 + gfx1151 RDNA 3.5) requires modern kernel
  boot.kernelPackages = pkgs.linuxPackages_latest;
  hardware.enableRedistributableFirmware = true;

  boot.kernelParams = [
    # Allow AMDGPU/ROCm to map up to 120 GB of the 128 GB unified system RAM as GTT VRAM
    "amdgpu.gttsize=122880"
    "ttm.pages_limit=31457280"
    "ttm.page_pool_size=31457280"
    "amdttm.pages_limit=31457280"
    "amdttm.page_pool_size=31457280"
    "panic=10"
    "boot.panic_on_fail"
  ];

  boot.kernel.sysctl = {
    # Keep LLM weights pinned in RAM; do not swap aggressively
    "vm.swappiness" = 10;
    "vm.vfs_cache_pressure" = 50;

    # Huge mmap limit required for memory-mapping large 70B+ GGUF model files
    "vm.max_map_count" = 2147483642;

    # Dirty page writeback tuning
    "vm.dirty_background_ratio" = 5;
    "vm.dirty_ratio" = 10;

    # High-throughput low-latency networking
    "net.core.default_qdisc" = "cake";
    "net.ipv4.tcp_congestion_control" = "bbr";
    "net.ipv4.tcp_fastopen" = 3;

    # Reboot after panic
    "kernel.panic" = 10;
  };

  # Performance CPU frequency governor for minimal inference latency
  powerManagement.cpuFreqGovernor = lib.mkDefault "performance";

  # 5. AMD RDNA 3.5 APU (gfx1151) ROCm & HIP runtime environment
  environment.variables = {
    HSA_OVERRIDE_GFX_VERSION = "11.5.1";
    HIP_VISIBLE_DEVICES = "0";
  };

  # Security limits for LLM inference (unlimited locked memory and large fd count)
  security.pam.loginLimits = [
    {
      domain = "*";
      item = "memlock";
      type = "-";
      value = "unlimited";
    }
    {
      domain = "*";
      item = "nofile";
      type = "-";
      value = "1048576";
    }
  ];

  # 4. Swapfile (16GB headroom)
  swapDevices = [
    {
      device = "/var/lib/swapfile";
      size = 16 * 1024; # 16384 MB (16 GB)
    }
  ];

}
