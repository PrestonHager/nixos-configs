{ config, ... }:
{
  users.users.pushgateway = {
    isSystemUser = true;
    description = "Prometheus Pushgateway";
    group = "pushgateway";
  };
  users.groups.pushgateway = { };

  systemd.tmpfiles.rules = [
    "d /pushgateway/data 0770 pushgateway pushgateway -"
  ];

  virtualisation.oci-containers.containers.pushgateway = {
    autoStart = true;
    ports = [ "9091:9091/tcp" ];
    user = "pushgateway:pushgateway";
    volumes = [
      "/etc/passwd:/etc/passwd:ro"
      "/etc/group:/etc/group:ro"
      "/pushgateway/data:/pushgateway"
    ];
    extraOptions = [
      "--add-host=host.containers.internal:host-gateway"
    ];
    image = "docker.io/prom/pushgateway:latest";
  };
}
