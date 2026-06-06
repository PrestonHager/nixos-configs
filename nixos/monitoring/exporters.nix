{ config, pkgs, lib, ... }:
{
  services.prometheus.exporters.node = {
    enable = true;
    port = 9100;
    enabledCollectors = [ "systemd" "textfile" "mountstats" ];
    extraFlags = [
      "--collector.textfile.directory=/var/lib/node-exporter-textfile"
      "--collector.systemd.unit-whitelist=(caddy|podman-.*)\\.service"
    ];
  };

  services.prometheus.exporters.blackbox = {
    enable = true;
    port = 9115;
    configFile = pkgs.writeText "blackbox.yml" (builtins.readFile ./blackbox.yml);
  };

  systemd.tmpfiles.rules = [
    "d /var/lib/node-exporter-textfile 0755 node_exporter node_exporter -"
  ];

  networking.firewall.trustedInterfaces = lib.mkAfter [ "podman0" ];
}
