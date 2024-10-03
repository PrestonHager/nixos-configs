{ config, pkgs, lib ? pkgs.lib, ... }:

{
  # Import larger declarations of packages here
  imports = [ ];

  home.packages = with pkgs; [
    # basic C toolchain
    gcc
    xclip

    # Python support, latest is 3.13 as of 28 Sep. 2024
    python313Full
    poetry
    python311Packages.pyopengl

    # NodeJS environments
    nodejs
    nodenv

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
