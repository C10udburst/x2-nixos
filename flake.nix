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

      dashboardTest = pkgs.writeShellScriptBin "dashboard-test" ''
        set -e
        ROOT_DIR="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
        cd "$ROOT_DIR"

        echo "==> 1. Building dashboard frontend (Tailwind 4 + daisyUI 5)..."
        if [ ! -d "$ROOT_DIR/modules/dash/frontend/node_modules" ]; then
          echo "Installing frontend dependencies..."
          (cd "$ROOT_DIR/modules/dash/frontend" && npm ci)
        fi
        (cd "$ROOT_DIR/modules/dash/frontend" && npm run build)

        echo ""
        echo "==> 2. Starting local CGI server (backend FastCGI + frontend preview)..."
        exec ${pkgs.python3}/bin/python3 "$ROOT_DIR/modules/dash/test-server.py" "$@"
      '';
    in
    {
      devShells.${system}.default = pkgs.mkShell {
        name = "evo-x2-frontend-dev";
        packages = with pkgs; [
          nodejs
          python3
          dashboardTest
        ];
        shellHook = ''
          echo "============================================================"
          echo "  GMKtec EVO-X2 Dashboard Development Shell"
          echo "============================================================"
          echo "  Node.js: $(node --version) | npm: $(npm --version)"
          echo "  Python:  $(python3 --version)"
          echo ""
          echo "  Run 'dashboard-test' to:"
          echo "    1. Build the dashboard frontend (Tailwind + daisyUI)"
          echo "    2. Serve the full static frontend and CGI backend locally"
          echo "============================================================"
        '';
      };

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
