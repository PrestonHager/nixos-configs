{ pkgs, ... }:
{
  systemd.tmpfiles.rules = [
    "d /var/lib/ace-version-cache 0755 root root -"
  ];

  systemd.services.ace-version-check = {
    description = "Export Ace service version metrics for Prometheus";
    after = [ "network-online.target" "podman.service" ];
    wants = [ "network-online.target" ];
    wantedBy = [ "multi-user.target" ];
    path = with pkgs; [ bash coreutils curl jq podman caddy ];
    serviceConfig = {
      Type = "oneshot";
      User = "root";
      ExecStart = pkgs.writeShellScript "ace-version-check-run" ''
        ${./scripts/ace-version-check.sh}
      '';
    };
  };

  systemd.timers.ace-version-check = {
    description = "Run ace version check every 6 hours";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "10min";
      OnUnitActiveSec = "6h";
      RandomizedDelaySec = "15min";
      Unit = "ace-version-check.service";
    };
  };
}
