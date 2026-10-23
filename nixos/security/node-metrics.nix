{ config, lib, ... }:

let
  cfg = config.homelab.security;
in {
  config = lib.mkMerge [
    (lib.mkIf cfg.enable {
      systemd.tmpfiles.rules = [
        "d /var/lib/node-exporter-textfile 0755 node_exporter node_exporter -"
      ];
    })
    (lib.mkIf (cfg.enable && cfg.role == "node" && cfg.nodeExporter.enable) {
      services.prometheus.exporters.node = {
        enable = true;
        port = 9100;
        enabledCollectors = [ "textfile" "systemd" ];
        extraFlags = [
          "--collector.textfile.directory=/var/lib/node-exporter-textfile"
        ];
      };

      # ace's Prometheus only; no allowedTCPPorts entry, which would open the
      # port to the whole LAN (IPv4 and IPv6) ahead of this rule.
      networking.firewall.extraCommands = lib.mkAfter ''
        iptables -A nixos-fw -p tcp -s 192.168.5.5 --dport 9100 -j nixos-fw-accept
      '';
    })
  ];
}
