{ config, pkgs, lib, ... }:

let
  cfg = config.homelab.security;
  logDir = "/var/log/cisco-syslog";
in {
  config = lib.mkIf (cfg.enable && cfg.cisco.enable && cfg.role == "central") {
    services.rsyslogd = {
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

    # Only the two Cisco devices may send syslog.
    networking.firewall.extraCommands = lib.mkAfter ''
      iptables -A nixos-fw -p udp -s ${cfg.cisco.astracapHost} --dport 514 -j nixos-fw-accept
      iptables -A nixos-fw -p udp -s ${cfg.cisco.astraquasarHost} --dport 514 -j nixos-fw-accept
    '';
  };
}
