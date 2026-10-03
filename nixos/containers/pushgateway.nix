{ config, lib, ... }:
let
  cruxIp = "192.168.5.6";
in {
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
    image = "docker.io/prom/pushgateway:v1.11.3";
  };

  # Accept metric pushes from crux external probe timer only (not WAN).
  networking.firewall.extraCommands = lib.mkAfter ''
    iptables -A nixos-fw -p tcp -s ${cruxIp} --dport 9091 -j nixos-fw-accept
  '';
}
