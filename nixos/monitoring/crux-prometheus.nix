{ config, pkgs, lib, ... }:
let
  aceIp = "192.168.5.5";
  promCfg = import ./crux-prometheus-config.nix { inherit lib; };
in {
  services.prometheus = {
    enable = true;
    listenAddress = "0.0.0.0";
    port = 9090;
    retentionTime = "15d";
    scrapeConfigs = promCfg.scrapeConfigs;
  };

  services.prometheus.exporters.node = {
    enable = true;
    port = 9100;
    enabledCollectors = [ "systemd" ];
    extraFlags = [
      "--collector.systemd.unit-whitelist=(pterodactyl|prometheus|blackbox).*\\.service"
    ];
  };

  networking.firewall.extraCommands = lib.mkAfter ''
    iptables -A nixos-fw -p tcp -s ${aceIp} --dport 9090 -j nixos-fw-accept
  '';
}
