# The libosmos engine as a workload of this machine: package, port, user, directories.
#
# libosmos (https://github.com/mrsirg97-rgb/libosmos) is the engine for the MoE packs that
# do not fit in memory at all - DeepSeek-V4.1-Flash streams its experts from the SSD while
# it runs. It is a GPU engine (gfx1151 kernels) and takes the GPU domain like gufo,
# llama.cpp and kyojin do, so `mkLibosmos` units join `gpuExclusiveUnits` and evict them.
#
# Two host prerequisites are outside Nix, both checked by `--doctor` upstream:
#
#   * the GPU may map ~113 GiB of the unified pool. modules/minimal.nix already sets
#     `ttm.pages_limit=31457280` (120 GiB), which is above what the packs need;
#   * the pack files themselves, placed by ./dl.sh under services.libosmos.modelsDir.
{
  config,
  lib,
  pkgs,
  inputs ? { },
  ...
}:
let
  cfg = config.services.libosmos;

  # The flake input, or a message naming what to add. Referenced only through `package`,
  # so a host with services.libosmos.enable = false never evaluates it.
  # A `flake = false` input is a plain source path, so it is tested for and not inspected.
  defaultPackage =
    if inputs ? libosmos then
      import ./package.nix {
        inherit pkgs;
        source = inputs.libosmos;
        libevt = inputs.libevt or (throw ''
          services.libosmos needs a `libevt` input beside `libosmos`: it is the engine's
          git submodule (third_party/libevt), and a flake input carries an empty directory
          where a submodule was.
            inputs.libevt = { url = "github:mrsirg97-rgb/libevt"; flake = false; };
        '');
      }
    else
      throw ''
        services.libosmos needs a `libosmos` flake input (the engine has no flake of its
        own, so it is pinned as a plain source):
            inputs.libosmos = { url = "github:mrsirg97-rgb/libosmos"; flake = false; };
      '';
in
{
  options.services.libosmos = {
    enable = lib.mkEnableOption "libosmos MoE inference engine base support" // {
      default = true;
    };

    package = lib.mkOption {
      type = lib.types.package;
      default = defaultPackage;
      defaultText = lib.literalExpression "import ./package.nix { inherit pkgs; source = inputs.libosmos; libevt = inputs.libevt; }";
      description = "The libosmos engine (osmos-api + osmos-serve) in every mkLibosmos unit.";
    };

    backendPort = lib.mkOption {
      type = lib.types.port;
      default = 8086;
      description = "Default loopback port for libosmos backend instances.";
    };

    modelsDir = lib.mkOption {
      type = lib.types.str;
      default = "/srv/models";
      description = "Host directory holding the packs ./dl.sh lays out.";
    };

    stateDir = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/osmos";
      description = ''
        Where an osmos-serve process keeps its saved conversations
        (`OSMOS_SLOT_DIR/<modelId>`). Upstream defaults to a `slots/` folder inside the
        pack; that folder is shared with every other engine here, and a pack is meant to
        be read-only state, so the slots get a directory of the engine's own.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    users.users.libosmos = {
      isSystemUser = true;
      group = "libosmos";
      home = cfg.stateDir;
      createHome = true;
      extraGroups = [
        "render"
        "video"
      ];
    };
    users.groups.libosmos = { };

    systemd.tmpfiles.rules = [
      "d ${cfg.modelsDir} 0775 libosmos render - -"
      "d ${cfg.stateDir} 0755 libosmos libosmos - -"
      "d ${cfg.stateDir}/slots 0755 libosmos libosmos - -"
      "d /run/model-lock 0777 root root - -"
    ];
  };
}
