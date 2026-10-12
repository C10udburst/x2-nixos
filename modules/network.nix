{
  config,
  lib,
  pkgs,
  ...
}: {
  networking = {
    # Static network configuration for primary LAN interface (eno1)
    useDHCP = lib.mkDefault false;

    defaultGateway = {
      address = "192.168.1.1";
      interface = "eno1";
    };

    nameservers = [
      "192.168.1.64"
      "192.168.1.1"
    ];

    search = [
      "home.praworzadnyzly.pl"
    ];

    interfaces.eno1 = {
      useDHCP = false;
      ipv4.addresses = [
        {
          address = "192.168.1.80";
          prefixLength = 24;
        }
      ];
    };

    # Declarative NetworkManager connection profile matching eno1 static configuration
    networkmanager.ensureProfiles.profiles = lib.mkIf config.networking.networkmanager.enable {
      eno1 = {
        connection = {
          id = "eno1";
          type = "ethernet";
          interface-name = "eno1";
          autoconnect = "true";
        };
        ipv4 = {
          method = "manual";
          address1 = "192.168.1.80/24,192.168.1.1";
          dns = "192.168.1.64;192.168.1.1;";
          dns-search = "home.praworzadnyzly.pl;";
        };
      };
    };
  };
}
