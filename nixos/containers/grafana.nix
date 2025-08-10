{ config, pkgs, inputs, ... }:

let
  sops-path = builtins.toString inputs.nix-secrets;
in
{
  #sops.secrets = {
  #  "grafana-config" = {
  #    sopsFile = "${sops-path}/secrets/containers/grafana-config.yaml";
  #  };
  #};

  # Create the wireguard user and group
  users.users = {
    grafana = {
      isSystemUser = true;
      description = "Grafana";
      group = "grafana";
    };
  };
  users.groups = {
    grafana = {};
  };

  # Create the data directory
  systemd.tmpfiles.rules = [
    "d /grafana/data 0770 grafana grafana -"
    "d /grafana/conf 0770 grafana grafana -"
  ];

  # Define the container
  virtualisation.oci-containers.containers."grafana" = {
    autoStart = true;

    ports = [
      "8080:3000/tcp"
    ];

    # User and group to run the container as
    user = "grafana:grafana";

    # Volumes to make persistent in the host/container
    volumes = [
      "/etc/passwd:/etc/passwd:ro"
      "/etc/group:/etc/group:ro"
      "/grafana/data:/var/lib/grafana"
      "/grafana/conf:/etc/grafana"
      #"${config.sops.secrets."grafana-config".path}:/app/config/config.yaml:ro"
    ];

    environment = {
    };

    # Finally, the wireguard image and version
    image = "docker.io/grafana/grafana-oss:latest";
  };
}

