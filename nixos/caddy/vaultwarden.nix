{ config, ... }:

let
  caddyLib = import ./lib.nix;
  proxy = ''
    reverse_proxy http://localhost:8081
  '';
in
{
  services.caddy = {
    virtualHosts."vault.prestonhager.com".extraConfig = ''
      ${caddyLib.securityHeaders}
      ${caddyLib.lanMatcher}

      # The Vaultwarden admin panel (/admin) is LAN/tailnet/VPN only; the
      # vault itself stays public for the clients.
      @vwAdmin path /admin /admin/*
      handle @vwAdmin {
        ${caddyLib.lanGuard proxy}
      }

      handle {
        ${proxy}
      }
    '';
  };
}
