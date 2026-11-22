{
  config,
  lib,
  pkgs,
  inputs ? { },
  ...
}:
let
  cfg = config.services.kyojin;

  rawKyojinPkg =
    if inputs ? kyojin && inputs.kyojin ? packages then
      inputs.kyojin.packages.${pkgs.system}.kyojin
    else
      pkgs.kyojin or null;

  # Upstream `kyojinServe` now ships the *entire* `tools/` tree into
  # $out/share/kyojin (`cp -rL`, dereferencing the ../strix_halo symlinks) and puts that
  # directory on PYTHONPATH in every kyojin-serve-* wrapper, so serve_compat.py and
  # strix_halo/image_cache.py are already installed. Copying them in a `postInstall`
  # hook is not only redundant: the store output is made read-only by makeBinaryHolder's
  # rightsHook before postInstall runs, so the copy fails with "Permission denied".
  defaultKyojinPkg = rawKyojinPkg;
in
{
  options.services.kyojin = {
    enable = lib.mkEnableOption "Kyojin exllamav3 inference engine base support" // {
      default = true;
    };

    package = lib.mkOption {
      type = lib.types.package;
      default = defaultKyojinPkg;
      description = "Kyojin inference server package (defaults to github:Yamz-Labs/kyojin flake output).";
    };

    backendPort = lib.mkOption {
      type = lib.types.port;
      default = 8085;
      description = "Default loopback port for Kyojin backend instances.";
    };

    modelsDir = lib.mkOption {
      type = lib.types.str;
      default = "/srv/models";
      description = "Host directory containing EXL3 model files.";
    };
  };

  config = lib.mkIf cfg.enable {
    # System user for kyojin with direct hardware access
    users.users.kyojin = {
      isSystemUser = true;
      group = "kyojin";
      home = "/var/lib/kyojin";
      createHome = true;
      extraGroups = [
        "render"
        "video"
      ];
    };
    users.groups.kyojin = { };

    # Runtime directories
    systemd.tmpfiles.rules = [
      "d ${cfg.modelsDir} 0775 kyojin render - -"
      "d /var/lib/kyojin 0775 kyojin render - -"
      "d /run/model-lock 0777 root root - -"
    ];
  };
}
