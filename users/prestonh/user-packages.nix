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

    # samba. CephFS off: nothing here serves shares from Ceph, and ceph 20.2.4
    # fails to build in nixpkgs 2026-10-23 (bundled qatlib), which is not cached.
    (sambaFull.override { enableCephFS = false; })
  ];
}
