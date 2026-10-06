{
  config,
  lib,
  pkgs,
  ...
}: {
  services.tailscale = {
    enable = true;
    useRoutingFeatures = "both";
  };

  # Trust tailscale interface so all services (SSH, Gufo Dashboard, API) are accessible over mesh
  networking.firewall.trustedInterfaces = ["tailscale0"];

  # Allow IP forwarding in case exit node or subnet routing is used
  boot.kernel.sysctl = {
    "net.ipv4.ip_forward" = 1;
    "net.ipv6.conf.all.forwarding" = 1;
  };
}
