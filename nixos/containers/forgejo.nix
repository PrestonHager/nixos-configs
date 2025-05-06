{ config, ... }:

{
  # Create the forgejo user and group
  users.users.forgejo = {
    isSystemUser = true;
    description = "Forgejo";
    group = "forgejo";
  };
  users.groups.forgejo = {};

  # Create the data directory
  systemd.tmpfiles.rules = [
    "d /forgejo-data 0770 forgejo forgejo -"
  ];

  # Define the container
  virtualisation.oci-containers.containers."forgejo" = {
    autoStart = true;

    # <hostPort>:<containerPort>
    ports = [
      "8082:3000"
      "2222": "22"
      "2222": "2222"
    ];

    # User and group to run the container as
    user = "forgejo:forgejo";

    # Volumes to make persistent in the host/container
    volumes = [
      "/etc/passwd:/etc/passwd:ro"
      "/etc/group:/etc/group:ro"
#      "/etc/timezone:/etc/timezone:ro"
#      "/etc/localtime:/etc/localtime:ro"
      "/forgejo-data/:/data/"
    ];

    environment = {
    };

    # Finally, the forgejo image and version
    image = "codeberg.org/forgejo/forgejo:9-rootless";
  };
}

