{ config, ... }:

let
  SAMBA_USERS = [ "prestonh" "pterodactyl" ];
  SAMBDA_GROUPS = [ "sambashare" ];
in
{
  users.groups."sambashare" = {};

  systemd.tmpfiles.rules = [
    "d /stor/shares/private 0770 root sambashare -"
  ];

  services.samba = {
    enable = true;
    openFirewall = true;
    settings = {
      global = {
        workgroup = "WORKGROUP";
        serverString = "Ace Samba Server";
        netbiosName = config.networking.hostName;
        security = "user";
        mapToGuest = "Bad User";
        unixExtensions = true;
        #hostsAllow = "192.168.8. 127.0.0.1 localhost";
        #hostsDeny = "0.0.0.0/0";
        minProtocol = "SMB2";
        extraConfig = ''
          interfaces = 192.168.8.1/24
          bind interfaces only = yes
        '';
      };
      "private" = {
        comment = "Private Share";
        path = "/stor/shares/private";
        browsable = true;
        readOnly = false;
        guestOk = false;
        validUsers = SAMBA_USERS;
        createMask = 0644;
        directoryMask = 0755;
      };
    };
  };

  services.samba-wsdd = {
    enable = true;
    openFirewall = true;
  };

  networking.firewall.allowedTCPPorts = [ 139 445 ];
  networking.firewall.allowedUDPPorts = [ 137 138 ];
}

