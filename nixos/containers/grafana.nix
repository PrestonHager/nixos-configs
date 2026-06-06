{ config, pkgs, inputs, ... }:

{
  users.users.grafana = {
    isSystemUser = true;
    description = "Grafana";
    group = "grafana";
  };
  users.groups.grafana = { };

  systemd.tmpfiles.rules = [
    "d /grafana/data 0770 grafana grafana -"
    "d /grafana/conf 0770 grafana grafana -"
  ];

  virtualisation.oci-containers.containers.grafana = {
    autoStart = true;
    image = "docker.io/grafana/grafana-oss:latest";
    user = "grafana:grafana";
    ports = [ "8082:3000/tcp" ];

    extraOptions = [
      "--add-host=host.containers.internal:host-gateway"
    ];

    environment = {
      GF_PATHS_PROVISIONING = "/etc/grafana/provisioning";
      GF_PATHS_DATA = "/var/lib/grafana";
    };

    volumes = [
      "/etc/passwd:/etc/passwd:ro"
      "/etc/group:/etc/group:ro"
      "/grafana/data:/var/lib/grafana"
      "/grafana/conf:/etc/grafana"
      "/etc/grafana/provisioning:/etc/grafana/provisioning:ro"
      "/etc/grafana/dashboards:/etc/grafana/dashboards:ro"
    ];
  };
}