{ config, ... }:

let
  caddyLib = import ./lib.nix;
in
{
  services.caddy.virtualHosts."dns.prestonhager.com".extraConfig = ''
    ${caddyLib.securityHeaders}

    # DoH (RFC 8484) — TLS + HTTP/1.1/2/3 terminated by Caddy, plain DNS-over-HTTP to Technitium.
    # Public on purpose.
    handle /dns-query* {
      reverse_proxy http://127.0.0.1:8053 {
        header_up Host {host}
        header_up X-Real-IP {remote_host}
        header_up X-Forwarded-For {remote_host}
        header_up X-Forwarded-Proto {scheme}
      }
    }

    # Technitium web console: LAN/tailnet/VPN only.
    ${caddyLib.lanOnly ''
      reverse_proxy http://localhost:5380
    ''}
  '';
}
