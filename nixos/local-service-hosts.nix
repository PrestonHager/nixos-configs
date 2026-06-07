# Local /etc/hosts entries for services terminated by Caddy on this host (ace).
# Lets on-box tools (curl, health checks, CLI) resolve *.prestonhager.com to loopback
# instead of timing out on public DNS / hairpin NAT.
#
# Install:
#   bash ~/nixos/apply-local-hosts.sh
#   sudo nixos-rebuild switch --flake /etc/nixos#ace

{ ... }:

{
  networking.hosts."127.0.0.1" = [
    # Pterodactyl
    "panel.prestonhager.com"
    "test.panel.prestonhager.com"

    # Monitoring & media
    "grafana.prestonhager.com"
    "prometheus.prestonhager.com"
    "jellyfin.prestonhager.com"
    "cloud.prestonhager.com"

    # Identity / infra
    "vault.prestonhager.com"
    "wg.prestonhager.com"
    "metrics.wg.prestonhager.com"
    "dns.prestonhager.com"
    "zitadel.prestonhager.com"
    "git.prestonhager.com"

    # Matrix / wiki / other Caddy vhosts on ace
    "matrix.prestonhager.com"
    "spacetime.prestonhager.com"
    "test.sui.prestonhager.com"
    "faucet.test.sui.prestonhager.com"
    "indexer.test.sui.prestonhager.com"
    "loftiawiki.org"
    "loftiawiki.com"
    "upgrade.loftiawiki.org"
  ];

  networking.hosts."192.168.5.5" = [ "ace.internal.prestonhager.com" ];
  networking.hosts."192.168.5.6" = [ "crux.internal.prestonhager.com" ];
  networking.hosts."192.168.5.7" = [ "nova.internal.prestonhager.com" ];
}
