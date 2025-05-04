{ config, pkgs, ... }:

{
  users.extraGroups.vboxusers.members = [ "prestonh" ];

  virtualisation.virtualbox.host = {
    enable = true;
    enableExtensionPack = true;
  };
}

