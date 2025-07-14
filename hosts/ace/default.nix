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

    # Containers submodule
    ../nixos/containers
    # nginx module, further customization available in nginx folder
    ../nixos/nginx
    # Virt-manager
    # see https://nixos.wiki/wiki/Virt-manager for more
    ../nixos/virt-manager.nix
    # Wireguard server
    ../nixos/wireguard.nix
  ];
  
}

