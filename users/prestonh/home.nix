{ config, pkgs, ... }:

{
  # Import other home manager files
  imports = [
    ./home-config.nix
    ./home-programs.nix
    ./user-packages.nix
  ];

  # Home Manager needs a bit of information about you and the paths it should
  # manage.
  home.username = "prestonh";
  home.homeDirectory = "/home/prestonh";

  # This value determines the Home Manager release that your configuration is
  # compatible with. This helps avoid breakage when a new Home Manager release
  # introduces backwards incompatible changes.
  #
  # You should not change this value, even if you update Home Manager. If you do
  # want to update the value, then make sure to first check the Home Manager
  # release notes.
  home.stateVersion = "24.05"; # Please read the comment before changing.

  # The home.packages option allows you to install Nix packages into your
  # environment.
  home.packages = with pkgs; [
    # Command line tools
    # zoxide is the new cd command allowing fuzzy directory changes
    zoxide
    # fzf (fuzzy finder) allows finding of files via a search box
    fzf
    # lsd (ls-deluxe) makes listings colorful and easier to read
    lsd
    # list the directory structure of directory in a branching/tree format
    tree
    # thefuck is a fun command corrector, trying to guess what you meant when
    # mistyping a command
    thefuck
    # markdown viewer (with edit button)
    glow

    # # It is sometimes useful to fine-tune packages, for example, by applying
    # # overrides. You can do that directly here, just don't forget the
    # # parentheses. Maybe you want to install Nerd Fonts with a limited number of
    # # fonts?
    # (pkgs.nerdfonts.override { fonts = [ "FantasqueSansMono" ]; })

    # # You can also create simple shell scripts directly inside your
    # # configuration. For example, this adds a command 'my-hello' to your
    # # environment:
    # (pkgs.writeShellScriptBin "my-hello" ''
    #   echo "Hello, ${config.home.username}!"
    # '')
  ];

  # Let Home Manager install and manage itself.
  programs.home-manager.enable = true;
}
