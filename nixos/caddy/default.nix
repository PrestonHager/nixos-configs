{ config, inputs, pkgs, ... }:

# Shared guards and headers for the vhosts live in ./lib.nix (imported by the
# vhost files, not a module): lanOnly / lanGuard restrict a site or path to
# loopback, 192.168.5.0/24, the tailnet and WireGuard clients; securityHeaders
# adds HSTS, nosniff and Referrer-Policy where the app does not set them.
{
  # Comment or uncomment the following imports to customize caddy
  imports = [
    ./acme-dns.nix
    ./certificates.nix
    # Reverse proxy configuration
    ./animal-search.nix
    ./coolify.nix
    #./forgejo.nix
    ./jellyfin.nix
    ./loopback-health.nix
    ./ace-service-update.nix
    ./matrix.nix
    ./technitium.nix
    ./grafana.nix
    ./mediawiki.nix
    ./nextcloud.nix
    #./phorge.nix
    ./prometheus.nix
    ./pterodactyl.nix
    #./spacetime.nix
    #./sui.nix
    ./vaultwarden.nix
    ./wg-portal.nix
    ./zitadel.nix
    ./serverdocs.nix
    # K80 / AI stack — docs/ace-k80-gpu.md
    # TEMPORARILY DISABLED — ai.prestonhager.com / OpenClaw (re-enable with services.aceK80.enableOpenClaw)
    # ./ai.nix
  ];

  # Enable the HTTP/HTTPS ports on the firewall
  networking.firewall.allowedTCPPorts = [
    80
    443
    853 # Technitium DNS-over-TLS (native TLS, not proxied by Cloudflare)
  ];
  networking.firewall.allowedUDPPorts = [
    443 # Caddy HTTP/3 (QUIC)
  ];

  services.caddy = {
    enable = true;
    globalConfig = ''
      admin 127.0.0.1:2019
      servers {
        protocols h1 h2 h3
        metrics
      }
    '';
    # Prometheus (in a container) scrapes this via the podman0 gateway; the admin API
    # stays on loopback. Port 2020 is not opened in nixos-fw, so the LAN cannot reach it.
    virtualHosts."http://:2020".extraConfig = ''
      metrics /metrics
    '';
  };
}



