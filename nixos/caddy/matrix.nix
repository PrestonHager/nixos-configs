{ config, ... }:

let
  caddyLib = import ./lib.nix;
  proxy = ''
    reverse_proxy http://localhost:6167 {
      header_up Host {host}
      header_up X-Forwarded-For {remote_host}
      header_up X-Forwarded-Proto {scheme}
    }
  '';
in
{
  services.caddy = {
    virtualHosts."matrix.prestonhager.com".extraConfig = ''
      ${caddyLib.securityHeaders}
      ${caddyLib.lanMatcher}

      # Server admin API: LAN/tailnet/VPN only. Client and federation APIs
      # stay public.
      @synapseAdmin path /_synapse/admin /_synapse/admin/*
      handle @synapseAdmin {
        ${caddyLib.lanGuard proxy}
      }

      handle {
        ${proxy}
      }
    '';
  };
}
