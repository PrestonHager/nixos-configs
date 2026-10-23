{ config, ... }:

let
  caddyLib = import ./lib.nix;
in
{
  services.caddy = {
    virtualHosts."prometheus.prestonhager.com".extraConfig = ''
      ${caddyLib.securityHeaders}
      ${caddyLib.lanOnly ''
        reverse_proxy http://localhost:9090
      ''}
    '';
  };
}
