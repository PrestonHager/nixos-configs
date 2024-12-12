{ config, pkgs, lib ? pkgs.lib, ... }:

{
  # Import larger declarations of packages here
  imports = [
  ];

  home.packages = with pkgs; [
    # basic C toolchain
    gcc
    xclip

    # neovim Copilot requires nodejs
    nodejs

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
