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
    image = "docker.io/prom/pushgateway@sha256:91a56b89b97dd8a5e1e4fa8b5bbbd86dd57a87a2a3cee3a3ce3368b40ef158ef"; # pushgateway v1.11.4
  };

  # Accept metric pushes from the crux external probe timer only (not WAN, not other LAN
  # hosts). The port stays on 0.0.0.0 for crux, but netavark DNATs it in nat PREROUTING
  # before nixos-fw sees it, so the filter is in raw PREROUTING. Loopback and podman0
  # (the Prometheus scrape) are untouched.
  networking.firewall.extraCommands = lib.mkAfter ''
    iptables -t raw -D PREROUTING -p tcp --dport 9091 ! -i podman0 ! -s ${cruxIp} -j DROP 2>/dev/null || true
    iptables -t raw -A PREROUTING -p tcp --dport 9091 ! -i podman0 ! -s ${cruxIp} -j DROP
  '';
  networking.firewall.extraStopCommands = lib.mkAfter ''
    iptables -t raw -D PREROUTING -p tcp --dport 9091 ! -i podman0 ! -s ${cruxIp} -j DROP 2>/dev/null || true
  '';
}
