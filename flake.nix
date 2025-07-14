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
        # Define all node names and system types for node-like hosts
        nodes = {
          crux = ./hosts/pterodactyl-nodes;
        };
      in {
      # Different configuration are selected by adding #config after the nixos
      # directory. For example `nixos-rebuild switch --flake /etc/nixos#default`
      # By default it uses the current host name
      ph-nixos = nixpkgs.lib.nixosSystem {
        specialArgs = {inherit inputs;};
        modules = defaultModules ++ [
          ./hosts/ph-nixos
        ];
      };
      ace = nixpkgs.lib.nixosSystem {
        specialArgs = {inherit inputs;};
        modules = defaultModules ++ [
          ./hosts/ace
        ];
      };
      #crux = nixpkgs.lib.nixosSystem {
      #  specialArgs = {inherit inputs;};
      #  modules = defaultModules ++ [
      #    ./hosts/pterodactyl-nodes
      #    {
      #      networking.hostName = "crux";
      #    }
      #  ];
      #};
    } // builtins.mapAttrs (name: value: nixpkgs.lib.nixosSystem {
      specialArgs = {inherit inputs;};
      modules = defaultModules ++ [
        value
        {
          networking.hostName = "${name}";
        }
      ];
    }) nodes;
  };
}
