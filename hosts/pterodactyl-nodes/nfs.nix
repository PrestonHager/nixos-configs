{config, pkgs, ... }:

{
  # Create a client for the NFS server that Ace is hosting
  fileSystems."/mnt/pterodactyl-share" = {
    device = "ace.internal.prestonhager.com:/pterodactyl-share";
    fsType = "nfs";
    # set owner and group to root:root and permissions to 755
    options = [ "ro" "nofail" "_netdev" "x-systemd.automount" "x-systemd.idle-timeout=60" ];
  };

  boot.supportedFilesystems = [ "nfs" ];
}
