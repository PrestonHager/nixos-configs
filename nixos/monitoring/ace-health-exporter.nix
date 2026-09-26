{ pkgs, ... }:
{
  systemd.services.ace-health-exporter = {
    description = "Export server-health.sh metrics for Prometheus";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    wantedBy = [ "multi-user.target" ];
    path = with pkgs; [ bash coreutils jq podman sudo ];
    serviceConfig = {
      Type = "oneshot";
      User = "root";
      ExecStart = pkgs.writeShellScript "ace-health-exporter-run" ''
        ${./scripts/ace-health-to-prom.sh}
        ${./scripts/php-perf-to-prom.sh}
      '';
    };
  };

  systemd.timers.ace-health-exporter = {
    description = "Run ace health exporter every minute";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "2min";
      OnUnitActiveSec = "1min";
      Unit = "ace-health-exporter.service";
    };
  };
}
