{ config, pkgs, inputs, ... }:

let
  sops-path = builtins.toString inputs.nix-secrets;
  # Pinned for ace-service-auto-update nix-bump (do not use :latest pulls).
  prometheusVersion = "3.15.0";
in
{
  #sops.secrets = {
  #  "prometheus-config" = {
  #    sopsFile = "${sops-path}/secrets/containers/prometheus-config.yaml";
  #  };
  #};

  # Create the prometheus user and group
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
    "d /prometheus/data 0770 prometheus prometheus -"
  ];

  # prometheus.yml is bind-mounted from a store path; restart when it changes.
  systemd.services.podman-prometheus.restartTriggers = [
    config.environment.etc."prometheus/prometheus.yml".source
  ];

  # Define the container
  virtualisation.oci-containers.containers."prometheus" = {
    autoStart = true;

    # Loopback for Caddy and host scripts, podman0 gateway for Grafana
    # (host.containers.internal:9090). Not 0.0.0.0: netavark DNATs ahead of nixos-fw.
    ports = [
      "127.0.0.1:9090:9090/tcp"
      "10.88.0.1:9090:9090/tcp"
    ];

    # User and group to run the container as
    user = "prometheus:prometheus";

    # Volumes to make persistent in the host/container
    volumes = [
      "/etc/passwd:/etc/passwd:ro"
      "/etc/group:/etc/group:ro"
      "/prometheus/data:/prometheus"
      "/etc/prometheus/prometheus.yml:/etc/prometheus/prometheus.yml:ro"
      #"${config.sops.secrets."prometheus-config".path}:/app/config/config.yaml:ro"
    ];

    extraOptions = [
      "--add-host=host.containers.internal:host-gateway"
    ];

    environment = {
    };

    # Finally, the prometheus image and version
    image = "docker.io/prom/prometheus:v${prometheusVersion}";
  };
}

