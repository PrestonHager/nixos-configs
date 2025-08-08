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
      "8080:8888/tcp"
    ];

    # Add network admin capabilities and use the host network
    extraOptions = [
      "--cap-add=NET_ADMIN"
      "--cap-add=SYS_MODULE"
      "--cap-add=NET_RAW"
      "--sysctl=net.ipv4.conf.all.src_valid_mark=1"
      "--sysctl=net.ipv4.ip_forward=1"
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

