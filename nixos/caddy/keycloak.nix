{ config, ... }:

let
  caddyLib = import ./lib.nix;
  kc = import ../auth/keycloak-lib.nix;
in
{
  # LAN/tailnet/VPN only: servers and `opkssh login` reach it from home or over
  # the VPN; nothing public needs it yet. No Cloudflare record.
  services.caddy.virtualHosts.${kc.domain}.extraConfig = ''
    ${caddyLib.securityHeaders}
    ${caddyLib.lanOnly ''
      reverse_proxy http://127.0.0.1:9280
    ''}
  '';
}
