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

    # Command line tools
    # zoxide is the new cd command allowing fuzzy directory changes
    zoxide
    # fzf (fuzzy finder) allows finding of files via a search box
    fzf
    # Startship is a prompt tool
    starship
    # Carapace, cross-shell autocomplete system
    carapace
    # lsd (ls-deluxe) makes listings colorful and easier to read
    lsd
    # list the directory structure of directory in a branching/tree format
    tree
    # thefuck is a fun command corrector, trying to guess what you meant when
    # mistyping a command
    thefuck
    # markdown viewer (with edit button)
    glow

    # GitHub CLI
    gh
    gnupg

    # Terminal based image viewer
    timg

    # htop for viewing processes
    htop-vim
    iotop
  ];
}
