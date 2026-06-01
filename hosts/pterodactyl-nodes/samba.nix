{ config, pkgs, ... }:

{
  services.samba = {
    enable = false;
    package = pkgs.samba;
    
    settings = {
      global = {
        workgroup = "ASTRASPRING";
        security = "user";
        "client signing" = "auto";
        "client use spnego" = "yes";
        "client ntlmv2 auth" = "yes";
        
        # Logging
        "log level" = "1";
        "log file" = "/var/log/samba/log.%m";
        "max log size" = "1000";
        
        # Client settings
        "client min protocol" = "SMB2";
        "client max protocol" = "SMB3";
        
        # Name resolution
        "name resolve order" = "bcast host lmhosts wins";
        
        # Disable server components (we only need client)
        "server services" = "-";
        "disable netbios" = "yes";
      };
    };
  };

  # Install Samba client tools
  environment.systemPackages = with pkgs; [
    samba
    cifs-utils
  ];

  # Create mount point for the Pterodactyl share
  fileSystems."/mnt/pterodactyl-share" = {
    device = "//192.168.8.50/private";
    fsType = "cifs";
    options = [
      "credentials=${config.sops.secrets."crux-samba".path}"
      "uid=1000"
      "gid=1000"
      "iocharset=utf8"
      "file_mode=0775"
      "dir_mode=0775"
      "vers=3.0"
      "cache=strict"
      "mfsymlinks"
      "x-systemd.automount"
      "x-systemd.idle-timeout=60"
      "x-systemd.device-timeout=5s"
      "x-systemd.mount-timeout=5s"
    ];
  };

  # Ensure the mount point directory exists
  systemd.tmpfiles.rules = [
    "d /mnt/pterodactyl-share 0755 root root -"
  ];
}
