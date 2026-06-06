{ config, pkgs, lib ? pkgs.lib, ... }:

{
  networking.hostName = "ace";

  imports = [
    ../../nixos/local-service-hosts.nix
    ../../nixos
    ../../nixos/headless
    # include SAMBA for file sharing
    #../../nixos/samba
    # include nfs for caddy lets encrypt certs
    ../../nixos/nfs
    # matrix home server
    #../../nixos/matrix.nix
    # hardware configuration for the MSI Summit E16 Flip
    ../../hardware/dell-poweredge-730xd/hardware-configuration.nix
    # yubico keys
    ../../nixos/yubikey.nix
    # include any users
    ../../users/prestonh
    ../../users/dylanh
  ];

  # Add prestonh to jellyfin group to allow for rsync into /jf/media folder
  users.users.prestonh.extraGroups = [ "jellyfin" ];

  # Add lynis an auditing tool to system packages
  environment.systemPackages = with pkgs; [
    lynis
  ];

  # Configure networking for the host
  networking = {
    defaultGateway = "192.168.5.1";
    nameservers = [ "192.168.5.2" "1.1.1.1" ];
    interfaces.bond0 = {
      useDHCP = false;
      ipv4.addresses = [ {
        address = "192.168.5.5";
        prefixLength = 24;
      } ];
    };
    bonds.bond0 = {
      interfaces = [ "eno1" "eno2" ];
      driverOptions = {
        mode = "802.3ad";
        lacp_rate = "fast";
        miimon = "100";
      };
    };

    # Setup local IP's for other servers
    hosts = {
      "192.168.5.6" = [
        "crux.lc1.nm.us.prestonhager.com"
      ];
    };
  };
}

