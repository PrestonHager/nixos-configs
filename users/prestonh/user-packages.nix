{ config, pkgs, lib ? pkgs.lib, ... }:

{
  # Import larger declarations of packages here
  imports = [ ];

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

    # Wireguard VPN
    wireguard-tools
  ];
}
