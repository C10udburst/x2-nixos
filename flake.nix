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

      # The router as a standalone package, so `nix build .#switcher` works without deploying.
      # It is the same derivation `modules/switcher/service.nix` puts in ExecStart.
      packages = nixpkgs.lib.genAttrs [ "x86_64-linux" ] (system: {
        switcher = import ./modules/switcher/default.nix {
          lib = nixpkgs.lib;
          rustPlatform = nixpkgs.legacyPackages.${system}.rustPlatform;
        };
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
