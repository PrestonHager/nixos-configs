{ config, pkgs, lib ? pkgs.lib, ... }:

{
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
    # Add packages to just this user
    zoxide
    fzf
    lsd

    gcc
    xclip

    python313Full
    poetry
    python311Packages.pyopengl

    nodejs_22
    nodenv

    thefuck

    tree

    glow

    gh    # GitHub CLI
    gnupg

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

  # Add unfree packages, only allowing specific packages so that other configs
  # can't install unwanted unfree packages
#  nixpkgs.config.allowUnfreePredicate = pkg: builtins.elem (lib.getName pkg) [
#     "pkg-name"
#  ];

  # Add the brave browser
  # You can also change package to one of the following:
  #   chromium, google-chrome, google-chrome-beta, google-chrome-dev, brave, or
  #   vivaldi.
  programs.chromium = {
    enable = true;
    package = pkgs.brave;
    extensions = [
      { id = "nngceckbapebfimnlniiiahkandclblb"; }
    ];
    commandLineArgs = [
      # "--argumentHere"
    ];
  };

  # Setup local git configuration
  programs.git = {
    enable = true;
    userName = "Preston Hager";
    userEmail = "preston@hagerfamily.com";
    signing = {
      signByDefault = true;
      key = "preston@hagerfamily.com";
    };
    aliases = {
      ap = "add -p";
    };
  };

  # Home Manager is pretty good at managing dotfiles. The primary way to manage
  # plain files is through 'home.file'.
  home.file = {
    # Recursively add all files from the config directory
    ".config/" = {
      source = ./config;
      recursive = true;
    };

    # zshrc file
    ".zshrc".source = ./zshrc;
  };

  # Create a systemd service that runs once whenever
  # sysinit-reactivation.target is activated to update neovim plugins
  systemd.user.services.update-neovim-plugins = {
    Unit = {
      Description = "Update neovim plugins";
    };
    Install = {
      WantedBy = [ "default.target" "sysinit-reactivation.target" ];
    };
    Service = {
      Type = "oneshot";
      ExecStart = "${pkgs.neovim}/bin/nvim --headless '+Lazy! sync' +qa";
    };
  };

  # Home Manager can also manage your environment variables through
  # 'home.sessionVariables'. If you don't want to manage your shell through Home
  # Manager then you have to manually source 'hm-session-vars.sh' located at
  # either
  #
  #  ~/.nix-profile/etc/profile.d/hm-session-vars.sh
  #
  # or
  #
  #  ~/.local/state/nix/profiles/profile/etc/profile.d/hm-session-vars.sh
  #
  # or
  #
  #  /etc/profiles/per-user/prestonh/etc/profile.d/hm-session-vars.sh
  #
  home.sessionVariables = {
    EDITOR = "nvim";
    VISUAL = "nvim";
    SUDO_EDITOR = "nvim";
#    TERMINAL = "kitty";
  };

  # Let Home Manager install and manage itself.
  programs.home-manager.enable = true;
}