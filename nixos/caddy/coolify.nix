# Coolify dashboard and the apps it deploys.
#
#   coolify.prestonhager.com   -> 127.0.0.1:8000/6001/6002 (nixos/containers/coolify.nix)
#   *.apps.prestonhager.com    -> Coolify's proxy on the deploy server (crux:80)
#
# TLS terminates here for both, with certificates from the Cloudflare DNS-01
# challenge in acme-dns.nix (the wildcard needs DNS-01). Coolify's proxy on
# crux only serves plain HTTP on port 80 because Wings already owns crux:443,
# so apps in Coolify use http://<name>.apps.prestonhager.com as their domain.
{ ... }:

let
  appsUpstream = "192.168.5.6:80";
in
{
  services.caddy.virtualHosts = {
    "coolify.prestonhager.com".extraConfig = ''
      # Realtime (Laravel Reverb / Pusher protocol) and the web terminal.
      handle /app/* {
        reverse_proxy 127.0.0.1:6001
      }
      handle /terminal/ws {
        reverse_proxy 127.0.0.1:6002
      }
      handle {
        reverse_proxy 127.0.0.1:8000
      }
    '';

    "*.apps.prestonhager.com".extraConfig = ''
      reverse_proxy ${appsUpstream}
    '';
  };
}

