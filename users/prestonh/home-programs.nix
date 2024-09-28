{ config, pkgs, ... }:

{
  # Import larger program configurations
  imports = [
    ./programs/tmux.nix
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
