{ config, ... }:

let
  caddyLib = import ./lib.nix;
in
{
  services.caddy = {
    virtualHosts."jellyfin.prestonhager.com".extraConfig = ''
      ${caddyLib.securityHeaders}
      reverse_proxy http://localhost:8096
    '';
  };
}
