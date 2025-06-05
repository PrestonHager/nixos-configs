{ config, ... }:

{
  networking.hostName = "ace";

  imports = [
    ../../nixos
    ../../nixos/headless
    # hardware configuration for the MSI Summit E16 Flip
    ../../hardware/dell-poweredge-730xd/hardware-configuration.nix
    # yubico keys
    ../../nixos/yubikey.nix
    # include any users
    ../../users/prestonh
  ];

  # Add prestonh to jellyfin group to allow for rsync into /jf/media folder
  users.users.prestonh.extraGroups = [ "jellyfin" ];
}

