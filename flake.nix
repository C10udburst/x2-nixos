{
  description = "Bare-Minimal NixOS configuration for GMKtec EVO-X2 (AMD Ryzen AI Max+ 395 128GB) LLM inference";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    gufo = {
      url = "github:gufo-org/gufo";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    comfyui-nix = {
      url = "github:utensils/comfyui-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    disko = {
      url = "github:nix-community/disko";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    kyojin = {
      url = "github:Yamz-Labs/kyojin";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    # The NPU domain's engine: open NPU kernels + `oflm serve` for Ryzen AI (XDNA 2).
    #
    # `nixpkgs` deliberately does NOT follow here, unlike every other input. This flake
    # builds against its own pinned nixpkgs (and pulls nix-amd-ai's XRT + amdxdna plugin
    # through the same pin); following ours would re-hash that whole closure and lose every
    # prebuilt xrt/boost/rust artifact the upstream binary cache carries. A second nixpkgs
    # in the graph is the cheaper answer by a wide margin.
    #
    # Pinned as the GitHub archive URL rather than `github:`. The repository carries an
    # uninitialized gitlink (`third_party/tokenizers-cpp`), and the git fetcher normalizes
    # that empty directory differently across nix patch releases: the identical rev hashed to
    # two different NARs on the two machines used here, so a `github:` pin resolved on one
    # host refused to download on the other. A plain archive has no git metadata and hashes
    # the same everywhere. Updating is still a one-liner (`nix flake lock
    # --update-input openflowlm` rewrites the rev inside the URL only if you change it here,
    # so bump the rev by hand and refresh narHash). The engine never needs the submodule:
    # its package.nix deletes `third_party/tokenizers-cpp` and fetches its own tokenizer tree.
    openflowlm = {
      url = "https://github.com/Atomic-Germ/OpenFlowLM-Next/archive/96b915d42d216e2a545db746fbd0d7387bed3157.tar.gz";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      gufo,
      disko,
      ...
    }@inputs:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};

      # There is no local mock server for the dashboard on purpose: /api/* is FastCGI on top
      # of systemctl and /v1/* is the workload switcher, so neither can ever answer locally.
      # Build the bundle here, deploy it, look at it on the host.
      frontendBuild = pkgs.writeShellScriptBin "dashboard-build" ''
        set -e
        ROOT_DIR="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
        cd "$ROOT_DIR/modules/dash/frontend"
        [ -d node_modules ] || npm ci
        npm run build
      '';
    in
    {
      devShells.${system}.default = pkgs.mkShell {
        name = "evo-x2-frontend-dev";
        packages = with pkgs; [
          nodejs
          python3
          frontendBuild
        ];
        shellHook = ''
          echo "============================================================"
          echo "  GMKtec EVO-X2 Dashboard Development Shell"
          echo "============================================================"
          echo "  Node.js: $(node --version) | npm: $(npm --version)"
          echo "  Python:  $(python3 --version)"
          echo ""
          echo "  Run 'dashboard-build' to compile the dashboard (-> modules/dash/frontend/dist)."
          echo "  The API (/api/*, /v1/*) lives on the host only - deploy and open it there."
          echo "============================================================"
        '';
      };

      # Standalone packages, so they can be built or inspected without deploying. Each is
      # the very derivation the corresponding module puts in ExecStart.
      packages = nixpkgs.lib.genAttrs [ "x86_64-linux" ] (system: {
        switcher = import ./modules/switcher/default.nix {
          lib = nixpkgs.lib;
          rustPlatform = nixpkgs.legacyPackages.${system}.rustPlatform;
        };

        # `nix build .#openflowlm` - the NPU engine with the repository's prebuilt xclbins,
        # i.e. without the mlir-aie/Peano kernel toolchain. `nix build .#openflowlm-full`
        # builds the open kernels from source instead (long, and the BERT embedding sets in
        # it need an NPU plus `__noChroot`).
        openflowlm = inputs.openflowlm.packages.${system}.oflm.override {
          openflowlm-open-kernels = import ./modules/npu/openflow-kernels.nix {
            inherit pkgs;
            source = "${inputs.openflowlm}";
          };
        };
        openflowlm-full = inputs.openflowlm.packages.${system}.oflm;
      });

      nixosConfigurations = {
        evo-x2 = nixpkgs.lib.nixosSystem {
          system = "x86_64-linux";
          specialArgs = { inherit inputs; };
          modules = [
            disko.nixosModules.disko
            ./disko.nix
            ./configuration.nix
          ];
        };
        default = self.nixosConfigurations.evo-x2;
      };
    };
}
