{ config, lib, ... }:

let
  cfg = config.homelab.security;
in {
  config = lib.mkIf cfg.enable {
    services.fail2ban = {
      enable = true;
      bantime = "1h";
      maxretry = 5;
      ignoreIP = [
        "127.0.0.1/8"
        "::1"
        "192.168.5.0/24"
      ];
      jails.sshd.settings = {
        enabled = true;
        backend = "systemd";
        journalmatch = "_SYSTEMD_UNIT=sshd.service + _COMM=sshd";
        maxretry = 5;
      };
    };
  };
}
