{ config, ... }:

let
  SAMBA_USERS = [ "prestonh" "pterodactyl" ];
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
        serverSigning = "auto";
        workgroup = "ASTRASPRING";
        serverString = "Ace Samba Server";
        netbiosName = config.networking.hostName;
        security = "user";
        mapToGuest = "Bad User";
        unixExtensions = true;
        minProtocol = "SMB2";
        interfaces = "192.168.8.50/24 192.168.8.52/24";
        "bind interfaces only" = "yes";
      };
      "private" = {
        comment = "Private Share";
        path = "/stor/shares/private";
        browsable = true;
        readOnly = false;
        writable = true;
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
