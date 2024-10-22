{ config, pkgs, lib ? pkgs.lib, ... }:

{
  # Import larger declarations of packages here
  imports = [ ];

  home.packages = with pkgs; [
    # GitHub CLI
    gh
    gnupg

    # Terminal based image viewer
    timg

    # Obsidian Application
    obsidian

    # Wireguard VPN
    wireguard-tools
  ];
}
