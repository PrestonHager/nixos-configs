{ config, pkgs, ... }:

{
  environment.systemPackages = with pkgs; [
    mediawiki
  ];
}
