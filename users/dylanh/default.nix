{ config, ... }:

{
  imports = [
    # import any necessary user modules
    ../default.nix
  ];

  # short-users allows us to create users quickly
  short-users = [
    {
      username = "dylanh";
      name = "Dylan Hager";
      home-manager.enable = true;
    }
  ];
}

