{ config, ... }:

{
  imports = [
    ../../nixos
    ../../nixos/headless
    # hardware configuration for the Dell Workstations
    ../../hardware/dell-optiplex-7050/hardware-configuration.nix
    # include any users
    ../../users/prestonh
  ];
}

