{ config, ... }:

{
  networking.interfaces.enp0s31f6.ipv4.addresses = [{
    address = "192.168.5.7";
    prefixLength = 24;
  }];

  networking.hosts."192.168.5.7" = [ "nova.internal.prestonhager.com" ];

  imports = [
    ../../nixos/monitoring/promtail.nix
  ];
}
