{ config, pkgs, inputs, ... }:

let
  sops-path = builtins.toString inputs.nix-secrets;
in
{
  sops.secrets = {
    "wg-portal-config" = {
      sopsFile = "${sops-path}/secrets/containers/wg-portal-config.yaml";
    };
  };

  imports = [
    ./wg-portal-scripts.nix
  ];

  # Create the wireguard user and group
  users.users = {
    wireguard = {
      isSystemUser = true;
      group = "wireguard";
    };
    wg-portal = {
      isSystemUser = true;
      description = "Wireguard Portal";
      group = "wg-portal";
      extraGroups = [ "wireguard" ];
    };
  };
  users.groups = {
    wireguard = {};
    wg-portal = {};
  };

  # open the firewall for wireguard port
  networking.firewall.allowedUDPPorts = [
    51825
  ];

  # Setup NAT forwarding from the wireguard interface to the local network.
  #networking.firewall.extraCommands = ''
  #  iptables -t nat -A POSTROUTING -s 192.168.20.0/24 -o eno1 -j MASQUERADE
  #  iptables -t nat -A POSTROUTING -s 192.168.20.0/24 -o eno3 -j MASQUERADE
  #  iptables -A FORWARD -s 192.168.20.0/24 -d 192.168.8.0/24 -j ACCEPT
  #  iptables -A FORWARD -s 192.168.8.0/24 -d 192.168.20.0/24 -j ACCEPT
  #'';

  # Create the data directory
  systemd.tmpfiles.rules = [
    "d /srv/wireguard/etc 0770 wireguard wireguard -"
    "d /srv/wireguard/data 0770 wireguard wireguard -"
  ];

  # Define the container
  virtualisation.oci-containers.containers."wg-portal" = {
    autoStart = true;

    # Add wireguard and web portal ports
    ports = [
      "51825:51825/udp"
      "8888:8888/tcp"
      "8787:8787/tcp"
    ];

    # Add network admin capabilities and use the host network
    extraOptions = [
      #"--network=host"
      "--cap-add=NET_ADMIN"
      "--cap-add=SYS_MODULE"
      #"--cap-add=NET_RAW"
    ];

    # User and group to run the container as
    #user = "wg-portal:wg-portal";
    user = "root:root";

    # Volumes to make persistent in the host/container
    volumes = [
      "/etc/passwd:/etc/passwd:ro"
      "/etc/group:/etc/group:ro"
      "/srv/wireguard/etc/:/etc/wireguard/"
      "/srv/wireguard/data/:/app/data"
      "${config.sops.secrets."wg-portal-config".path}:/app/config/config.yaml:ro"
    ];

    environment = {
    };

    # Finally, the wireguard image and version
    image = "docker.io/wgportal/wg-portal:latest";
  };
}

