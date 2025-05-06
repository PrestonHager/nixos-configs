{ config, ... }:

{
  # Create the spacetimedb user and group
  users.users.spacetimedb = {
    isSystemUser = true;
    description = "Spacetime DB";
    group = "spacetimedb";
  };
  users.groups.spacetimedb = {};

  # Create the data directory
  systemd.tmpfiles.rules = [
    "d /stdb 0770 spacetimedb spacetimedb -"
    "d /stdb-keys 0770 spacetimedb spacetimedb -"
  ];

  # Define the container
  virtualisation.oci-containers.containers."spacetimedb" = {
    autoStart = true;

    # <hostPort>:<containerPort>
    ports = [
      "8084:3000"
    ];

    # User and group to run the container as
    user = "spacetimedb:spacetimedb";

    # Volumes to make persistent in the host/container
    volumes = [
      "/etc/passwd:/etc/passwd:ro"
      "/etc/group:/etc/group:ro"
      "/stdb:/stdb"
      "/stdb-keys:/etc/spacetimedb"
    ];

    # Finally, the spacetimedb image and version
    image = "clockworklabs/spacetimedb:latest";
  };
}

