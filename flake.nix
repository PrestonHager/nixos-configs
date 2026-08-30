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

    # Our pterodactyl-wings binary for any node branches
    pterodactyl-wings = {
      url = "github:PrestonHager/pterodactyl-wings-nix-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # Blueprint plugins
    pterodactyl-dns-records = {
      url = "github:PrestonHager/pterodactyl-blueprint-dns-records";
      flake = false;
    };
    pterodactyl-port-forward = {
      url = "github:PrestonHager/pterodactyl-blueprint-port-forward";
      flake = false;
    };
    pterodactyl-minecraft-tools = {
      url = "github:PrestonHager/pterodactyl-blueprint-minecraft-tools";
      flake = false;
    };

    # Upstream Blueprint framework (test.panel; tracked for rev pinning)
    blueprint-framework = {
      url = "github:BlueprintFramework/framework";
      flake = false;
    };

    disko = {
      url = "github:nix-community/disko";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # Tesla K80 stack (470 driver, CUDA 11.4, Ollama/OpenClaw) — enable in hosts/ace after GPU install
    ace-k80-stack = {
      url = "github:PrestonHager/ace-k80-stack";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, tree-sitter-parsers, ... }@inputs:
    let
      system = "x86_64-linux";
      docsSite = import ./docs/site/default.nix {
        lib = nixpkgs.lib;
        pkgs = nixpkgs.legacyPackages.${system};
        siteSrc = ./docs/site;
        includesSrc = ./docs;
        bootstrapPubkey = ./docs/bootstrap/ssh-ed25519.pub;
      };
    in {
    packages.${system} = let
      pkgs = nixpkgs.legacyPackages.${system};
    in {
      docs = docsSite;
      default = docsSite;
      nextcloud-migrate = import ./scripts/nextcloud-migrate { inherit pkgs; lib = nixpkgs.lib; };
    };

    devShells.${system}.docs-dev = nixpkgs.legacyPackages.${system}.mkShell {
      packages = [
        nixpkgs.legacyPackages.${system}.mdbook
        nixpkgs.legacyPackages.${system}.mdbook-mermaid
      ];
    };

    nixosConfigurations = let
        defaultModules = [
          inputs.home-manager.nixosModules.default
          inputs.sops-nix.nixosModules.sops
        ];
        # Define all node names and system types for node-like hosts
        nodes = {
          crux = ./hosts/pterodactyl-nodes;
          nova = ./hosts/pterodactyl-nodes;
          elara = ./hosts/pterodactyl-nodes;
          zenith = ./hosts/pterodactyl-nodes;
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
        specialArgs = { inherit inputs docsSite; };
        modules = defaultModules ++ [
          ./hosts/ace
        ];
      };
    } // builtins.mapAttrs (name: value: nixpkgs.lib.nixosSystem {
      specialArgs = {inherit inputs;};
      modules = defaultModules ++ [
        value
        {
          networking.hostName = "${name}";
        }
      ]
      # Import a host specific configuration if the file exists
      ++ nixpkgs.lib.optional (builtins.pathExists (./hosts/${name})) (import ./hosts/${name});
    }) nodes;
  };
}
