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
  };

  outputs = { self, nixpkgs, tree-sitter-parsers, ... }@inputs: {
    nixosConfigurations = {
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
      # The gnome configuration configures the gnome desktop environment
      gnome = nixpkgs.lib.nixosSystem {
        specialArgs = {inherit inputs;};
        modules = [
          ./nixos
          ./nixos/gnome
          inputs.home-manager.nixosModules.default
        ];
      };
      # The i3 configuration configures the i3 desktop environment
      i3 = nixpkgs.lib.nixosSystem {
        specialArgs = {inherit inputs;};
        modules = [
          ./nixos
          ./nixos/i3
          inputs.home-manager.nixosModules.default
        ];
      };
    };
  };
}
