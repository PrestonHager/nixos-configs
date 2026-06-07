{ config, ... }:

{
  # Specify the networking IP address and hostname for this machine
  networking = {
    hostName = "crux";
    interfaces.enp0s31f6 = {
      useDHCP = false;
      ipv4.addresses = [{
        address = "192.168.5.6";
        prefixLength = 24;
      }];
    };
    defaultGateway = "192.168.5.1";
    # LanCache on ace for split-horizon DNS (LAN probe perspective).
    nameservers = [ "192.168.5.5" "1.1.1.1" ];

    # Setup IP's for local network
    hosts = {
      "192.168.5.5" = [
        "panel.prestonhager.com"
        "ace.internal.prestonhager.com"
      ];
      "192.168.5.6" = [
        "crux.internal.prestonhager.com"
      ];
    };
  };

  imports = [
    ../../nixos/monitoring/crux-probes.nix
  ];
}
