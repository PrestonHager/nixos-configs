{ config, pkgs, lib ? pkgs.lib, ... }:

{
  # Import larger declarations of packages here
  imports = [ ];

  home.packages = with pkgs; [
    # Clipboard manager
    xclip

    # GitHub CLI
    gh
    gnupg

    # Terminal based image viewer
    timg

    # NodeJS is required for the Copilot plugin used in neovim
    nodejs

    # Yubikey Tools
    yubikey-personalization
    yubikey-personalization-gui
    yubikey-manager
    yubikey-manager-qt
  ];

  # Add unfree packages, only allowing specific packages so that other configs
  # can't install unwanted unfree packages
#  nixpkgs.config.allowUnfreePredicate = pkg: builtins.elem (lib.getName pkg) [
#     "pkg-name"
#  ];

}
