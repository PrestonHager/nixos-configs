{ config, inputs, pkgs, ... }:

{
  # Comment or uncomment the following imports to customize caddy
  imports = [
    # Reverse proxy configuration
    #./forgejo.nix
    ./jellyfin.nix
    ./matrix.nix
    ./grafana.nix
    ./mediawiki.nix
    #./nextcloud.nix
    #./phorge.nix
    ./portunus.nix
    ./prometheus.nix
    ./pterodactyl.nix
    #./spacetime.nix
    #./sui.nix
    ./vaultwarden.nix
    ./wg-portal.nix
    ./zitadel.nix
  ];

  # Enable the HTTP/HTTPS ports on the firewall
  networking.firewall.allowedTCPPorts = [
    80
    443
  ];

  services.caddy = {
    enable = true;
  };
}

