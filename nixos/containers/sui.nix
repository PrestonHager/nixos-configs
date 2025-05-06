{ config, pkgs, ... }:

{
  # Create the sui user and group
  users.users.sui = {
    isSystemUser = true;
    description = "SUI";
    group = "sui";
  };
  users.groups.sui = {};

  # Create the data directory
  systemd.tmpfiles.rules = [
    "d /sui/ 0770 sui sui -"
  ];

  # Setup firewall to allow the SUI port
  networking.firewall.allowedTCPPorts = [ 9000 ];

  # Define the container
  virtualisation.oci-containers.containers."sui" = {
    autoStart = true;

    # <hostPort>:<containerPort>
    ports = [
      "9000:9000"
      "9123:9123"
      "9124:9124"
    ];

    # User and group to run the container as
    user = "root:root";

    # Volumes to make persistent in the host/container
    volumes = [
      "/etc/passwd:/etc/passwd:ro"
      "/etc/group:/etc/group:ro"
    ];

    environment = {
    };

    image = "prestonhager/sui:latest";
  };
}

