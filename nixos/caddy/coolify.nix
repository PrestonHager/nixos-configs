# Coolify dashboard and the apps it deploys.
#
#   coolify.prestonhager.com   -> 127.0.0.1:8000/6001/6002 (nixos/containers/coolify.nix)
#   *.apps.prestonhager.com    -> Coolify's proxy on the deploy server (mars:80)
#   any other hostname         -> mars:80 too, when a Coolify app uses it
#
# TLS terminates here, with certificates from the Cloudflare DNS-01 challenge
# in acme-dns.nix (the wildcard needs DNS-01). Coolify's proxy on mars only
# serves plain HTTP on port 80, so apps in Coolify use http://<host> as their
# domain.
#
# The dashboard, its realtime socket (/app/*), the web terminal (/terminal/ws)
# and the API (/api/*) answer only the LAN, the tailnet and WireGuard clients
# (lib.nix lanRanges); anyone else gets 403. The only public path is
# /webhooks/*, which GitHub (App and manual webhooks) must reach to trigger
# deploys; Coolify verifies those requests with the webhook secret. The API is
# not public because nothing outside the LAN calls it (Sentinel on mars and
# the health probes come from the LAN / loopback), and a leaked API token
# should not be usable from the internet (`publicApi` below opens it).
#
# The catch-all sites below only match hostnames that no other vhost on ace
# claims (Caddy prefers the most specific host). HTTPS certificates for them
# are issued on demand, after coolify-edge-ask (nixos/containers/coolify-edge.nix)
# confirms that a Coolify app uses the name; everything else fails the TLS
# handshake. Those app sites stay public on purpose: they are the apps.
{ lib, ... }:

let
  caddyLib = import ./lib.nix;
  # Set to true to let the internet reach Coolify's token-authenticated API
  # (/api/*), e.g. for deploys triggered from GitHub-hosted Actions runners.
  publicApi = false;
  # Traefik routes on Host; Caddy already sends X-Forwarded-Proto/Host/For.
  proxyToApps = ''
    reverse_proxy 192.168.5.15:80
  '';
in
{
  services.caddy.virtualHosts = {
    "coolify.prestonhager.com".extraConfig = ''
      ${caddyLib.securityHeaders}

      # Public: GitHub App / manual webhooks (signed by the webhook secret).
      handle /webhooks/* {
        reverse_proxy 127.0.0.1:8000
      }
      ${lib.optionalString publicApi ''
        handle /api/* {
          reverse_proxy 127.0.0.1:8000
        }
      ''}

      ${caddyLib.lanOnly ''
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
      ''}
    '';

    "*.apps.prestonhager.com".extraConfig = proxyToApps;

    # The default per-vhost log name would be access-https:__.log, which
    # Caddy fails to open, so these two name their logs explicitly.
    "https://" = {
      logFormat = "output file /var/log/caddy/access-catchall-https.log";
      extraConfig = ''
        tls {
          on_demand
        }
        ${proxyToApps}
      '';
    };

    # Plain HTTP for names no other vhost claims: send it to HTTPS, where the
    # on-demand check decides. Named vhosts keep their own redirects.
    "http://" = {
      logFormat = "output file /var/log/caddy/access-catchall-http.log";
      extraConfig = ''
        redir https://{host}{uri} 308
      '';
    };
  };
}
