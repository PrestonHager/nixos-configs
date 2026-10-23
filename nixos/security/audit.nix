{ config, lib, ... }:

let
  cfg = config.homelab.security;
in {
  config = lib.mkIf cfg.enable {
    security.audit.enable = true;

    security.audit.backlogLimit = 16384;

    # The rules alone only feed the kernel's printk fallback. auditd writes
    # /var/log/audit/audit.log (root-only, 0700 directory) and does not stop
    # journald from receiving the same records over
    # systemd-journald-audit.socket, which is how they reach Loki.
    # root-exec is chatty on Docker hosts, so cap the log at 4 x 50 MB.
    security.auditd = {
      enable = true;
      settings = {
        max_log_file = 50;
        num_logs = 4;
        max_log_file_action = "rotate";
      };
    };

    security.audit.rules = [
      "-a always,exit -F arch=b64 -S execve -F euid=0 -k root-exec"
      "-w /etc/passwd -p wa -k identity"
      "-w /etc/group -p wa -k identity"
      "-w /etc/nixos -p wa -k nixos-config"
      "-w /etc/ssh/sshd_config -p wa -k sshd-config"
    ] ++ lib.optionals cfg.phase2.enable [
      "-w /etc/sudoers -p wa -k sudoers"
      "-w /etc/sudoers.d -p wa -k sudoers"
    ];
  };
}
