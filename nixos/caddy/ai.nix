# ai.prestonhager.com — OpenClaw gateway + optional Ollama API (K80 stack).
# LAN-only: Caddy @lan remote_ip matcher (RFC1918 + homelab 192.168.5.0/24).
# External clients get HTTP 403; other ace vhosts remain WAN-accessible via NAT.
# Enable after services.aceK80 is live on ace:
#   1. Uncomment import in nixos/caddy/default.nix
#   2. nixos-rebuild switch --flake /etc/nixos#ace

{ config, ... }:

{
  services.caddy = {
    virtualHosts."ai.prestonhager.com".extraConfig = ''
      @lan {
        remote_ip 192.168.5.0/24 192.168.0.0/16 10.0.0.0/8 172.16.0.0/12
      }

      handle @lan {
        # OpenClaw gateway (default port 18789, loopback)
        handle /ollama/* {
          uri strip_prefix /ollama
          reverse_proxy http://127.0.0.1:11434
        }
        handle {
          reverse_proxy http://127.0.0.1:18789
        }
      }

      handle {
        respond "Forbidden" 403
      }
    '';
  };
}
