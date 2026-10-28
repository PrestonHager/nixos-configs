{ config, ... }:

let
  caddyLib = import ./lib.nix;
in
{
  services.caddy = {
    # WireGuard Portal (admin + self-service UI, Zitadel OIDC login). Not on
    # the internet: peers are created and their configs downloaded from the
    # LAN, the tailnet or an existing VPN connection (lib.nix lanRanges).
    virtualHosts."wg.prestonhager.com".extraConfig = ''
      ${caddyLib.securityHeaders}
      ${caddyLib.lanOnly ''
        reverse_proxy http://localhost:8888
      ''}
    '';
    virtualHosts."metrics.wg.prestonhager.com".extraConfig = ''
      ${caddyLib.lanOnly ''
        reverse_proxy http://localhost:8787
      ''}
    '';
  };
}
