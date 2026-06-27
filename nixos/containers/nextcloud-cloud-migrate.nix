{ pkgs, ... }:

{
  cloudMigrateApp = pkgs.runCommand "nextcloud-cloudmigrate-app" { } ''
    mkdir -p $out
    cp -r ${../../apps/cloudmigrate}/. $out/
  '';
}
