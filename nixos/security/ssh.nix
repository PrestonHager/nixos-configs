# sshd hardening shared by every host that enables homelab.security.
{ config, lib, ... }:

let
  cfg = config.homelab.security;
in {
  options.homelab.security.ssh = {
    restrictForwarding = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Disable TCP, agent, Unix-socket and X11 forwarding in sshd. Deploys
        (nixos-rebuild --target-host, nix copy) and Coolify's multiplexed
        sessions do not need any of them; an SSH login should not double as a
        tunnel into the LAN.
      '';
    };

    declarativeKeysOnly = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Ignore ~/.ssh/authorized_keys: only keys declared in Nix
        (users.users.<name>.openssh.authorizedKeys) are accepted. Enable it
        only on hosts whose admin keys are all declared, or it locks you out.
      '';
    };
  };

  config = lib.mkIf cfg.enable (lib.mkMerge [
    (lib.mkIf cfg.ssh.restrictForwarding {
      services.openssh.settings = {
        AllowTcpForwarding = false;
        AllowAgentForwarding = false;
        AllowStreamLocalForwarding = false;
        X11Forwarding = false;
        PermitTunnel = false;
      };
    })
    (lib.mkIf cfg.ssh.declarativeKeysOnly {
      services.openssh.authorizedKeysInHomedir = false;
    })
  ]);
}
