{ config, pkgs, ... }:

{
  # Create NFS server for other users to connect to
  # it is mounted to /stor/shares/private which is where we copy the certs from
  # caddy after they are renewed.
  fileSystems."/export/pterodactyl-share" = {
    device = "/stor/shares/private";
    options = [ "bind" "ro" ];
  };

  services.nfs.server = {
    enable = true;
    exports = ''
      /export                   192.168.5.6(ro,fsid=0,no_root_squash,no_subtree_check)
      /export                   192.168.5.7(ro,fsid=0,no_root_squash,no_subtree_check)
      /export/pterodactyl-share 192.168.5.6(ro,sync,no_root_squash,no_subtree_check)
      /export/pterodactyl-share 192.168.5.7(ro,sync,no_root_squash,no_subtree_check)
    '';
  };

  networking.firewall.allowedTCPPorts = [ 2049 ]; # NFS
}
