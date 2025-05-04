{ config, ... }:

{
  networking.hostName = "ph-nixos";

  imports = [
    ../../nixos
    ../../nixos/gnome
    # hardware configuration for the MSI Summit E16 Flip
    ../../hardware/msi-summit-e16flip/hardware-configuration.nix
    # yubico keys
    ../../nixos/yubikey.nix
    # include any users
    ../../users/prestonh
  ];
  
}

