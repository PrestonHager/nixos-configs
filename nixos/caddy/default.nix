{ config, inputs, pkgs, ... }:

{
  # Comment or uncomment the following imports to customize caddy
  imports = [
    ./acme-dns.nix
    ./certificates.nix
    # Reverse proxy configuration
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
    # K80 / AI stack (enable after GPU install — see docs/ace-k80-gpu.md)
    #./ai.nix
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
  };
}



