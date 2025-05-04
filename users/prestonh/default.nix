{ config, ... }:

{
  imports = [
    # import any necessary user modules
    ../default.nix
  ];

  # short-users allows us to create users quickly
  short-users = [
    {
      username = "prestonh";
      name = "Preston Hager";
      home-manager.enable = true;
    }
  ];

  # Configure sub UID/GID ranges to use tools such as docker/podman
  users.users.prestonh.uid = 1000;
  users.extraUsers."prestonh" = {
    subUidRanges = [ { startUid = 100000; count = 65536; } ];
    subGidRanges = [ { startGid = 100000; count = 65536; } ];
  };
}

