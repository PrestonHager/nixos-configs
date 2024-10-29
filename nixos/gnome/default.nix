{ config, pkgs, ... }:

{
  imports = [
    ./desktop.nix
    ./programs/steam.nix
  ];
}
