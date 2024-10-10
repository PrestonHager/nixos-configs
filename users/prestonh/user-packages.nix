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

    # Obsidian Application
    obsidian
  ];

  # Add unfree packages, only allowing specific packages so that other configs
  # can't install unwanted unfree packages
  nixpkgs.config.allowUnfreePredicate = pkg: builtins.elem (lib.getName pkg) [
     "obsidian"
  ];

}
