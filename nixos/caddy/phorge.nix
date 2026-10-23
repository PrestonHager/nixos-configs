{ config, ... }:

let
  caddyLib = import ./lib.nix;
in
{
  services.caddy = {
    virtualHosts."phorge.loftiawiki.org".extraConfig = ''
      ${caddyLib.securityHeaders}
      ${caddyLib.lanOnly ''
        reverse_proxy http://localhost:8091
      ''}
    '';
    virtualHosts."phorge.loftiawiki.com".extraConfig = ''
      redir https://phorge.loftiawiki.org{uri} permanent
    '';
  };
}
