{config, pkgs, ... }:

{
  # Create a client for the NFS server that Ace is hosting
  fileSystems."/mnt/pterodactyl-share" = {
    device = "ace.internal.prestonhager.com:/pterodactyl-share";
    fsType = "nfs";
    # set owner and group to root:root and permissions to 755
    options = [ "ro" "nofail" "_netdev" ];
    #options = [ "rw" "uid=0" "gid=0" "file_mode=0755" "dir_mode=0755" ];
  };

  boot.supportedFilesystems = [ "nfs" ];
}
