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


  networking.firewall.extraCommands = lib.mkAfter ''
    iptables -A nixos-fw -p tcp -s 127.0.0.1 --dport 9100 -j nixos-fw-accept
    iptables -A nixos-fw -p tcp -s 127.0.0.1 --dport 9115 -j nixos-fw-accept
  '';
}
