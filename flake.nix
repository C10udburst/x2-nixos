{
  description = "Bare-Minimal NixOS configuration for GMKtec EVO-X2 (AMD Ryzen AI Max+ 395 128GB) LLM inference";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    gufo = {
      url = "github:gufo-org/gufo";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    disko = {
      url = "github:nix-community/disko";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = {
    self,
    nixpkgs,
    gufo,
    disko,
    ...
  } @ inputs: {
    nixosConfigurations = {
      evo-x2 = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        specialArgs = {inherit inputs;};
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
