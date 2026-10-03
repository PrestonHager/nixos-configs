{ config, inputs, lib, ... }:

{
  imports = [
    inputs.disko.nixosModules.disko
    ../../nixos/monitoring/promtail.nix
  ];

  networking = {
    hostName = "zenith";
    useDHCP = lib.mkDefault true;
    nameservers = [ "192.168.5.5" "1.1.1.1" ];
    hosts = {
      "192.168.5.5" = [
        "panel.prestonhager.com"
        "ace.internal.prestonhager.com"
      ];
      "192.168.5.9" = [ "zenith.internal.prestonhager.com" ];
    };
  };
}
