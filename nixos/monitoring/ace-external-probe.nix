{ pkgs, ... }:
let
  probeScript = pkgs.writeShellScriptBin "external-probe-push" (builtins.readFile ../../scripts/external-probe-push.sh);
in {
  environment.systemPackages = [ probeScript ];

  systemd.services.ace-external-probe-push = {
    description = "Push external HTTP probe metrics via Pushgateway (public DNS view)";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    path = with pkgs; [ bash coreutils curl bind dig ];
    serviceConfig = {
      Type = "oneshot";
      User = "root";
      Environment = [
        "PUSHGATEWAY_URL=http://127.0.0.1:9091"
        "DNS_RESOLVER=1.1.1.1"
        "PROBE_SOURCE=ace-public-dns"
      ];
      ExecStart = "${probeScript}/bin/external-probe-push";
    };
  };

  systemd.timers.ace-external-probe-push = {
    description = "Run external HTTP probes every 5 minutes";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "5min";
      OnUnitActiveSec = "5m";
      Unit = "ace-external-probe-push.service";
    };
  };
}
