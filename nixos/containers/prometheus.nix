{ config, pkgs, inputs, ... }:

let
  sops-path = builtins.toString inputs.nix-secrets;
in
{
  #sops.secrets = {
  #  "prometheus-config" = {
  #    sopsFile = "${sops-path}/secrets/containers/prometheus-config.yaml";
  #  };
  #};

  # Create the wireguard user and group
  users.users = {
    prometheus = {
      isSystemUser = true;
      description = "Prometheus";
      group = "prometheus";
    };
  };
  users.groups = {
    prometheus = {};
  };

  # Create the data directory
  systemd.tmpfiles.rules = [
    "d /prometheus/etc 0770 prometheus prometheus -"
    "d /prometheus/data 0770 prometheus prometheus -"
  ];

  # Define the container
  virtualisation.oci-containers.containers."prometheus" = {
    autoStart = true;

    ports = [
      "9090:9090/tcp"
    ];

    # User and group to run the container as
    user = "prometheus:prometheus";

    # Volumes to make persistent in the host/container
    volumes = [
      "/etc/passwd:/etc/passwd:ro"
      "/etc/group:/etc/group:ro"
      "/prometheus/data:/prometheus"
      "/prometheus/etc:/etc/prometheus"
      #"${config.sops.secrets."prometheus-config".path}:/app/config/config.yaml:ro"
    ];

    environment = {
    };

    # Finally, the wireguard image and version
    image = "docker.io/prom/prometheus:latest";
  };
}

