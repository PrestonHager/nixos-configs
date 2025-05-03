{ config, ... }:

{
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

  # Create the data directory
  systemd.tmpfiles.rules = [
    "d /srv/wireguard/etc 0770 wireguard wireguard -"
    "d /srv/wireguard/data 0770 wireguard wireguard -"
    "d /srv/wireguard/config 0770 wireguard wireguard -"
  ];

  # Define the container
  virtualisation.oci-containers.containers."wg-portal" = {
    autoStart = true;

    # Add network admin capabilities and use the host network
    extraOptions = [
      "--cap-add=NET_ADMIN"
      "--network=host"
    ];

    # User and group to run the container as
    user = "wg-portal:wg-portal";

    # Volumes to make persistent in the host/container
    volumes = [
      "/etc/passwd:/etc/passwd:ro"
      "/etc/group:/etc/group:ro"
      "/srv/wireguard/etc/:/etc/wireguard/"
      "/srv/wireguard/data/:/app/data"
      "/srv/wireguard/config/:/app/config"
    ];

    environment = {
    };

    # Finally, the wireguard image and version
    image = "docker.io/wgportal/wg-portal:latest";
  };
}

