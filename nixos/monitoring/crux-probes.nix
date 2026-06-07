{ config, pkgs, lib, ... }:
let
  blackboxCfg = import ./crux-blackbox-config.nix { inherit lib; };
  aceIp = "192.168.5.5";
  probeScript = pkgs.writeShellScriptBin "ace-external-probe-push" (
    builtins.readFile ../../scripts/ace-external-probe-push.sh
  );
in {
  services.prometheus.exporters.blackbox = {
    enable = true;
    port = 9115;
    configFile = pkgs.writeText "crux-blackbox.yml" blackboxCfg.blackboxYml;
  };

  networking.firewall.extraCommands = lib.mkAfter ''
    iptables -A nixos-fw -p tcp -s ${aceIp} --dport 9115 -j nixos-fw-accept
  '';

  environment.systemPackages = [ probeScript ];

  systemd.services.ace-external-probe-push = {
    description = "Push external HTTP probe metrics to ace Pushgateway (WAN perspective)";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    path = with pkgs; [ bash coreutils curl bind dig gawk ];
    serviceConfig = {
      Type = "oneshot";
      User = "root";
      Environment = [
        "PUSHGATEWAY_URL=http://${aceIp}:9091"
        "DNS_RESOLVER=1.1.1.1"
        "PROBE_SOURCE=crux"
        "PROBE_JOB=external-http-probe"
      ];
      ExecStart = "${probeScript}/bin/ace-external-probe-push";
    };
  };

  systemd.timers.ace-external-probe-push = {
    description = "Run external HTTP probes from crux every 5 minutes";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "5min";
      OnUnitActiveSec = "5m";
      Unit = "ace-external-probe-push.service";
    };
  };
}
