# Reverse proxies for Animal Search (NMSU-CS-CS371 group project).
#
# Two hostnames, two independent backends, both bound to loopback by
# nixos/containers/animal-search.nix:
#
#   animal-search.prestonhager.com         -> 127.0.0.1:4322  (production)
#   staging.animal-search.prestonhager.com -> 127.0.0.1:4323  (staging)
#
# Neither backend port is exposed off the host: the pod is created with
# `-p 127.0.0.1:<port>:<port>`, so Caddy is the only way in. Both hostnames are
# public — DNS points them at ace's public IP (via ip1.lc1.nm.us.prestonhager.com)
# and Caddy reverse-proxies any client. Certs come from the ACME DNS-01 challenge
# in acme-dns.nix, so no inbound 80/443 to the apps is needed.
{ ... }:

{
  services.caddy.virtualHosts = {
    "animal-search.prestonhager.com" = {
      extraConfig = ''
        reverse_proxy 127.0.0.1:4322 {
          header_up X-Forwarded-Host {host}
          header_up X-Deploy-Environment production
        }
      '';
    };

    "staging.animal-search.prestonhager.com" = {
      extraConfig = ''
        reverse_proxy 127.0.0.1:4323 {
          header_up X-Forwarded-Host {host}
          header_up X-Deploy-Environment staging
        }
      '';
    };
  };
}