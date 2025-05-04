{ config, inputs, ... }:

{
  imports = [
    # modules
    ../modules/users.nix
    inputs.home-manager.nixosModules.default
  ];
}

