# Reverse proxies for Animal Search (NMSU-CS-CS371 group project).
#
# Two hostnames, two independent backends, both bound to loopback by
# nixos/containers/animal-search.nix:
#
#   animal-search.prestonhager.com         -> 127.0.0.1:4322  (production)
#   staging.animal-search.prestonhager.com -> 127.0.0.1:4323  (staging)
#
# Neither backend port is exposed on the LAN: the pod is created with
# `-p 127.0.0.1:<port>:<port>`, so Caddy is the only way in. The `@lan` matcher
# below keeps the whole site LAN-only, matching every other vhost in this repo
# (see serverdocs.nix, ai.nix).
#
# TLS: public certificates come from the ACME DNS-01 challenge configured in
# acme-dns.nix, so no inbound 80/443 to the apps is needed and no HTTP-01
# redirect is issued.
{ ... }:

{
  services.caddy.virtualHosts = {
    "animal-search.prestonhager.com" = {
      extraConfig = ''
        @lan remote_ip 192.168.5.0/24 192.168.0.0/16 10.0.0.0/8 172.16.0.0/12

        handle @lan {
          reverse_proxy 127.0.0.1:4322 {
            header_up X-Forwarded-Host {host}
            header_up X-Deploy-Environment production
          }
        }

        handle {
          respond "Animal Search (production) is LAN-only." 403
        }
      '';
    };

    "staging.animal-search.prestonhager.com" = {
      extraConfig = ''
        @lan remote_ip 192.168.5.0/24 192.168.0.0/16 10.0.0.0/8 172.16.0.0/12

        handle @lan {
          reverse_proxy 127.0.0.1:4323 {
            header_up X-Forwarded-Host {host}
            header_up X-Deploy-Environment staging
          }
        }

        handle {
          respond "Animal Search (staging) is LAN-only." 403
        }
      '';
    };
  };
}
