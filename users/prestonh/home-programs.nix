{ config, pkgs, ... }:

{
  # Import larger program configurations
  imports = [
    ./programs/tmux.nix
  ];

  # Local zsh plugins
  programs.zsh = {
    enable = true;
    enableCompletion = true;
    plugins = [
      {
        name = "zsh-nix-shell";
        file = "nix-shell.plugin.zsh";
        src = pkgs.fetchFromGitHub {
          owner = "chisui";
          repo = "zsh-nix-shell";
          rev = "v0.8.0";
          sha256 = "1lzrn0n4fxfcgg65v0qhnj7wnybybqzs4adz7xsrkgmcsr0ii8b7";
        };
      }
    ];
  };

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
}
