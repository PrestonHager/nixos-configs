{ config, inputs, ... }:

{
  imports = [
    inputs.disko.nixosModules.disko
    ./disko.nix
    ./hardware.nix
    ../../nixos/monitoring/promtail.nix
  ];

  # Keep disko.devices in git for future nixos-anywhere; never format on switch.
  disko.enableConfig = false;

  # Root keys come from hosts/pterodactyl-nodes (workstation bootstrap key and
  # root@ace's automation key). The old root@ph-nixos RSA key that ace used
  # while bootstrapping this host is no longer authorized.

  networking = {
    hostName = "elara";
    useDHCP = false;
    interfaces.eno1 = {
      useDHCP = false;
      ipv4.addresses = [{
        address = "192.168.5.8";
        prefixLength = 24;
      }];
    };
    defaultGateway = "192.168.5.1";
    nameservers = [ "192.168.5.5" "1.1.1.1" ];
    hosts = {
      "192.168.5.5" = [
        "panel.prestonhager.com"
        "ace.internal.prestonhager.com"
      ];
      "192.168.5.8" = [ "elara.internal.prestonhager.com" ];
    };
  };
}
