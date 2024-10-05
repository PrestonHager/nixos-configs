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

  ];

  # Add unfree packages, only allowing specific packages so that other configs
  # can't install unwanted unfree packages
#  nixpkgs.config.allowUnfreePredicate = pkg: builtins.elem (lib.getName pkg) [
#     "pkg-name"
#  ];

}
