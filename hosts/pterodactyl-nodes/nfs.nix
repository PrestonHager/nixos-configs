{ config, pkgs, lib ? pkgs.lib, ... }:

let
  nfsExports = {
    crux = "ace.internal.prestonhager.com:/export/pterodactyl-crux";
    nova = "ace.internal.prestonhager.com:/export/pterodactyl-nova";
    elara = "ace.internal.prestonhager.com:/export/pterodactyl-elara";
    zenith = "ace.internal.prestonhager.com:/export/pterodactyl-zenith";
  };
  host = config.networking.hostName;
in {
  systemd.tmpfiles.rules = [
    "d /mnt/pterodactyl-share 0755 root root - -"
  ];

  fileSystems."/mnt/pterodactyl-share" = {
    device = nfsExports.${host} or (throw "No NFS cert export configured for host ${host}");
    fsType = "nfs4";
    options = [
      "ro"
      "nofail"
      "_netdev"
      "x-systemd.after=network-online.target"
      "x-systemd.requires=network-online.target"
    ];
  };

  boot.supportedFilesystems = [ "nfs" ];
}
