{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.llamacpp;
in
{
  options.services.llamacpp = {
    enable = lib.mkEnableOption "llama.cpp server inference base support" // {
      default = true;
    };

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.llama-cpp.override {
        rocmSupport = true;
        #Optimization: restrict Tensile matrix-multiplication kernel generation to gfx1151 only
        rocmPackages = pkgs.rocmPackages.overrideScope (
          self: super: {
            hipblaslt = super.hipblaslt.override {
              gpuTargets = [ "gfx1151" ];
            };
          }
        );
      };
      description = "llama-cpp package containing llama-server binary with ROCm acceleration.";
    };

    backendPort = lib.mkOption {
      type = lib.types.port;
      default = 8082;
      description = "Default loopback port for llama.cpp backend instances.";
    };

    modelsDir = lib.mkOption {
      type = lib.types.str;
      default = "/srv/models";
      description = "Host directory containing GGUF model files.";
    };
  };

  config = lib.mkIf cfg.enable {
    # System user for llama-cpp with direct hardware access
    users.users.llama-cpp = {
      isSystemUser = true;
      group = "llama-cpp";
      extraGroups = [
        "render"
        "video"
      ];
    };
    users.groups.llama-cpp = { };

    # Runtime directories
    systemd.tmpfiles.rules = [
      "d ${cfg.modelsDir} 0775 llama-cpp render - -"
      "d /run/model-lock 0777 root root - -"
    ];
  };
}
