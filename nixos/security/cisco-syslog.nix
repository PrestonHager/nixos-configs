{ config, pkgs, lib, ... }:

let
  cfg = config.homelab.security;
  logDir = "/var/log/cisco-syslog";
in {
  config = lib.mkIf (cfg.enable && cfg.cisco.enable && cfg.role == "central") {
    services.rsyslog = {
      enable = true;
      extraConfig = ''
        # Cisco IOS / IOS-XE remote syslog (UDP 514)
        module(load="imudp")
        input(type="imudp" port="514")

        if ($fromhost-ip == "${cfg.cisco.astracapHost}" or $fromhost-ip == "${cfg.cisco.astraquasarHost}") then {
          action(
            type="omfile"
            file="${logDir}/cisco.log"
            template="RSYSLOG_TraditionalFileFormat"
          )
          stop
        }
      '';
    };

    systemd.tmpfiles.rules = [
      "d ${logDir} 0750 root root -"
    ];

    networking.firewall.allowedUDPPorts = lib.mkAfter [ 514 ];
  };
}
