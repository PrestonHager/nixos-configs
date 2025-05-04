{
  description = "Nixos config flake";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";

    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    tree-sitter-parsers = {
      url = "github:ratson/nix-treesitter";
    };

    sops-nix = {
      url = "github:Mic92/sops-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # Our sops repository so we can host secrets seperately
    nix-secrets = {
      url = "git+ssh://git@github.com/PrestonHager/nixos-secrets.git";
    };
  };

  outputs = { self, nixpkgs, tree-sitter-parsers, ... }@inputs: {
    nixosConfigurations = let
        defaultModules = [
          inputs.home-manager.nixosModules.default
          inputs.sops-nix.nixosModules.sops
        ];
      in {
      # Different configuration are selected by adding #config after the nixos
      # directory. For example `nixos-rebuild switch --flake /etc/nixos#default`
      # The default configuration configures a headless system.
      headless = nixpkgs.lib.nixosSystem {
        specialArgs = {inherit inputs;};
        modules = [
          ./nixos
          ./nixos/headless
          inputs.home-manager.nixosModules.default
        ];
      };
      ph-nixos = nixpkgs.lib.nixosSystem {
        specialArgs = {inherit inputs;};
        modules = defaultModules ++ [
          ./hosts/ph-nixos
        ];
      };
    };
  };
}
