{ config, lib, ... }:

let
  cfg = config.homelab.security;
in {
  config = lib.mkIf cfg.enable {
    services.fail2ban = {
      enable = true;
      bantime = "1h";
      maxretry = 5;
      # Not the whole LAN: a compromised LAN host or container must be bannable.
      # ace runs the automation (deploys, Coolify), and the admin workstation
      # has a DHCP LAN address, so it is trusted through the tailnet instead.
      ignoreIP = [
        "127.0.0.1/8"
        "::1"
        "192.168.5.5"
        "100.64.0.0/10"
      ];
      jails.sshd.settings = {
        enabled = true;
        backend = "systemd";
        # OpenSSH 10 logs authentication from the per-connection
        # sshd-session process; fail2ban's stock filter (_daemon =
        # sshd(?:-session)?) parses both. Same as upstream's journalmatch.
        journalmatch = "_SYSTEMD_UNIT=sshd.service + _COMM=sshd + _COMM=sshd-session";
        maxretry = 5;
      };
    };
  };
}
