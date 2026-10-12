{
  config,
  lib,
  pkgs,
  inputs ? {},
  ...
}: let
  cfg = config.services.gufo;

  defaultGufoPkg =
    if inputs ? gufo && inputs.gufo ? packages
    then inputs.gufo.packages.${pkgs.system}.default
    else pkgs.gufo or null;
in {
  options.services.gufo = {
    enable = lib.mkEnableOption "Gufo native LLM inference engine base support" // {
      default = true;
    };

    package = lib.mkOption {
      type = lib.types.package;
      default = defaultGufoPkg;
      description = "Gufo engine package (defaults to github:gufo-org/gufo flake output).";
    };

    backendPort = lib.mkOption {
      type = lib.types.port;
      default = 8081;
      description = "Default loopback port for Gufo backend instances.";
    };

    modelsDir = lib.mkOption {
      type = lib.types.str;
      default = "/srv/models";
      description = "Host directory containing GGUF model files.";
    };
  };

  config = lib.mkIf cfg.enable {
    # System user for gufo with direct hardware access
    users.users.gufo = {
      isSystemUser = true;
      group = "gufo";
      extraGroups = [
        "render"
        "video"
      ];
    };
    users.groups.gufo = {};

    # Runtime directories
    systemd.tmpfiles.rules = [
      "d ${cfg.modelsDir} 0775 gufo render - -"
      "d /run/model-lock 0777 root root - -"
    ];
  };
}
