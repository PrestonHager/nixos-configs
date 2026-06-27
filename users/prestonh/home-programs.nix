{ config, pkgs, ... }:

{
  # Import larger program configurations
  imports = [
    ./programs/tmux.nix
    ./programs/neovim.nix
    ./programs/ssh.nix
  ];

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
    package = pkgs.git;
    settings = {
      user.name = "Preston Hager";
      user.email = "preston@hagerfamily.com";
      alias.c = "commit -S";
      core.editor = "XDG_CONFIG_HOME=\"$HOME/.config/\" ${pkgs.neovim}/bin/nvim";
      init.defaultBranch = "main";
    };
    signing = {
      signByDefault = true;
      key = "preston@hagerfamily.com";
    };
  };
}