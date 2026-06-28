{ config, pkgs, lib, inputs, ... }:

let
  sops-path = builtins.toString inputs.nix-secrets;
  lanCidr = "192.168.5.0/24";
  sharePath = "/stor/ace-drive";
  smbUser = "prestonh";
in
{
  users.groups.sambashare = { };

  users.users.${smbUser}.extraGroups = [ "sambashare" ];

  systemd.tmpfiles.rules = [
    "d ${sharePath} 0770 ${smbUser} sambashare -"
  ];

  sops.secrets."ace-samba-prestonh" = {
    sopsFile = "${sops-path}/secrets/ace.yaml";
    mode = "0400";
  };

  systemd.services.samba-set-prestonh-password = {
    description = "Ensure Samba password for ${smbUser} from sops";
    after = [ "sops-install-secrets.service" ];
    requires = [ "sops-install-secrets.service" ];
    before = [ "smbd.service" "nmbd.service" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = pkgs.writeShellScript "samba-set-prestonh-password" ''
        set -euo pipefail
        PASS="$(tr -d '\r\n' < ${config.sops.secrets."ace-samba-prestonh".path})"
        if pdbedit -L 2>/dev/null | grep -q '^${smbUser}:'; then
          (printf '%s\n' "$PASS"; printf '%s\n' "$PASS") | ${pkgs.samba}/bin/smbpasswd -s ${smbUser}
        else
          (printf '%s\n' "$PASS"; printf '%s\n' "$PASS") | ${pkgs.samba}/bin/smbpasswd -s -a ${smbUser}
        fi
      '';
      RemainAfterExit = true;
    };
    restartTriggers = [ config.sops.secrets."ace-samba-prestonh".path ];
  };

  services.samba = {
    enable = true;
    openFirewall = false;
    settings = {
      global = {
        workgroup = "WORKGROUP";
        "server string" = "Ace Samba Server";
        "netbios name" = "ACE";
        security = "user";
        "map to guest" = "Bad User";
        "min protocol" = "SMB2";
        interfaces = "lo bond0";
        "bind interfaces only" = "yes";
        "store dos attributes" = "yes";
        "unix extensions" = "no";
      };
      AceDrive = {
        comment = "Ace Drive";
        path = sharePath;
        browsable = true;
        "read only" = false;
        "guest ok" = false;
        "valid users" = smbUser;
        "create mask" = "0664";
        "directory mask" = "0775";
        "force user" = smbUser;
        "force group" = "sambashare";
      };
    };
  };

  services.samba-wsdd = {
    enable = true;
    openFirewall = false;
    hostname = "ace";
    workgroup = "WORKGROUP";
  };

  networking.firewall.extraCommands = lib.mkAfter ''
    iptables -A nixos-fw -p tcp -s ${lanCidr} --dport 445 -j nixos-fw-accept
    iptables -A nixos-fw -p tcp -s ${lanCidr} --dport 139 -j nixos-fw-accept
    iptables -A nixos-fw -p udp -s ${lanCidr} --dport 137 -j nixos-fw-accept
    iptables -A nixos-fw -p udp -s ${lanCidr} --dport 138 -j nixos-fw-accept
    iptables -A nixos-fw -p udp -s ${lanCidr} --dport 3702 -j nixos-fw-accept
  '';
}
