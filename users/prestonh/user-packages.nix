{ config, pkgs, lib ? pkgs.lib, ... }:

{
  # Import larger declarations of packages here
  imports = [
  ];

  home.packages = with pkgs; [
    # GitHub CLI
    gh
    gnupg

    # Terminal based image viewer
    timg

    # Obsidian Application
    obsidian

    # Arudino IDE
    arduino

    # Wireguard VPN
    wireguard-tools

    # Go Dot engine and editor
    godot_4

    # MPV crossplatform multimedia player
    mpv
  ];
}
