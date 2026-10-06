{ config, pkgs, lib, ... }:

{
  environment.systemPackages = [
    (import ../scripts/nextcloud-migrate { inherit pkgs lib; })
  ];
}
