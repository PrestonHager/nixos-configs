{ config, lib, ... }:

let
  cfg = config.homelab.security;
in {
  config = lib.mkIf cfg.enable {
    security.audit.enable = true;

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
