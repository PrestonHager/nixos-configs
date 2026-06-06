{ config, ... }:

{
  # Create the jellyfin user and group
  users.users.jellyfin = {
    isSystemUser = true;
    description = "Jellyfin";
    group = "jellyfin";
  };
  users.groups.jellyfin = {};

  # Create the data directory
  systemd.tmpfiles.rules = [
    "d /jf 0770 jellyfin jellyfin -"
    "d /jf/config 0770 jellyfin jellyfin -"
    "d /jf/cache 0770 jellyfin jellyfin -"
    "d /jf/media 0770 jellyfin jellyfin -"
  ];

  # Define the container
  virtualisation.oci-containers.containers."jellyfin" = {
    autoStart = true;

    # <hostPort>:<containerPort>
    ports = [
      "8096:8096"
    ];

    # User and group to run the container as
    user = "jellyfin:jellyfin";

    # Volumes to make persistent in the host/container
    volumes = [
      "/etc/passwd:/etc/passwd:ro"
      "/etc/group:/etc/group:ro"
      "/jf/config:/config"
      "/jf/cache:/cache"
      "/jf/media:/media"
    ];

    extraOptions = [
      "--userns=keep-id"
    ];

    # Finally, the jellyfin image and version
    image = "docker.io/jellyfin/jellyfin:latest";
  };
}

