{ config, pkgs, lib, ... }:
let
  # Rootful podman default network gateway. Prometheus (a podman0 container) scrapes the
  # host exporters here; nothing on the LAN or tailnet needs them.
  podmanGateway = "10.88.0.1";

  # 10.88.0.1 only exists once netavark has created podman0 (first container start), so
  # order the exporters after the Prometheus container and keep retrying until the bind
  # succeeds instead of failing with EADDRNOTAVAIL at boot.
  waitForPodman0 = {
    after = [ "podman-prometheus.service" ];
    serviceConfig = {
      Restart = lib.mkForce "always";
      RestartSec = lib.mkForce "5s";
    };
    unitConfig.StartLimitIntervalSec = 0;
  };
in
{
  services.prometheus.exporters.node = {
    enable = true;
    listenAddress = podmanGateway;
    port = 9100;
    enabledCollectors = [ "systemd" "textfile" "mountstats" ];
    extraFlags = [
      "--collector.textfile.directory=/var/lib/node-exporter-textfile"
      "--collector.systemd.unit-whitelist=(caddy|podman-.*)\\.service"
      # node_systemd_service_restart_total, for the ace_unit_restart_loop alert.
      "--collector.systemd.enable-restarts-metrics"
    ];
  };

  services.prometheus.exporters.blackbox = {
    enable = true;
    listenAddress = podmanGateway;
    port = 9115;
    configFile = pkgs.writeText "blackbox.yml" (import ./blackbox-config.nix { inherit lib; }).blackboxYml;
  };

  systemd.services.prometheus-node-exporter = waitForPodman0;
  systemd.services.prometheus-blackbox-exporter = waitForPodman0;

  systemd.tmpfiles.rules = [
    "d /var/lib/node-exporter-textfile 0755 node_exporter node_exporter -"
  ];

  # podman0 is NOT a trusted interface. It carries every rootful container on the default
  # network and, via the wg-portal container, the WireGuard VPN clients (192.168.20.0/24),
  # so only the host ports those flows actually use are opened on it. Ports published by
  # containers (10.88.0.1:9090/8082/8787/5380/9091 and 192.168.5.5:53) are DNATed by
  # netavark and traverse FORWARD, not nixos-fw, so they need no entry here. Other podman
  # bridges (coolify podman1, runner networks) get nothing beyond the global allow list.
  #   53 tcp/udp  DNS (containers started with --dns=192.168.5.5, VPN clients)
  #   80, 443     Caddy: containers reach vhosts via host-gateway (Zitadel OIDC, Nextcloud),
  #               VPN clients browse the LAN sites
  #   443 udp     HTTP/3 to Caddy
  #   2020        Caddy metrics (Prometheus)
  #   3100        Loki HTTP API (Grafana datasource / alert rules)
  #   9100, 9115  node_exporter and blackbox_exporter (Prometheus)
  networking.firewall.interfaces.podman0 = {
    allowedTCPPorts = [ 53 80 443 2020 3100 9100 9115 ];
    allowedUDPPorts = [ 53 443 ];
  };
}
