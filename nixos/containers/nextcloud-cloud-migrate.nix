{ config, pkgs, lib, ... }:

let
  ncRoot = "/stor/nextcloud";
  cloudMigrateApp = pkgs.runCommand "nextcloud-cloudmigrate-app" { } ''
    mkdir -p $out
    cp -r ${../../apps/cloudmigrate}/. $out/
  '';
in
{
  systemd.tmpfiles.rules = lib.mkAfter [
    "d ${ncRoot}/data/custom_apps 0755 www-data www-data -"
    "L+ ${ncRoot}/data/custom_apps/cloudmigrate - - - - ${cloudMigrateApp}"
  ];
}
