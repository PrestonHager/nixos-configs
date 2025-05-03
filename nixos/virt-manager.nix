{ config, pkgs, ... }:

{
  programs.virt-manager.enable = true;
  users.groups.libvirt.members = [ "prestonh" ];
  virtualisation = {
    libvirtd.enable = true;
    spiceUSBRedirection.enable = true;
  };

  # add user to libvirt group
  users.users.prestonh.extraGroups = [ "libvirt" ];
}

