{
  description = "Bare-Minimal NixOS configuration for GMKtec EVO-X2 (AMD Ryzen AI Max+ 395 128GB) LLM inference";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
  };

  outputs = {
    self,
    nixpkgs,
    ...
  }: {
    nixosConfigurations = {
      evo-x2 = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        modules = [
          ./configuration.nix
        ];
      };
      default = self.nixosConfigurations.evo-x2;
    };
  };
}
