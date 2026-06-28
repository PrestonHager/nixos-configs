# ai.prestonhager.com — OpenClaw gateway + optional Ollama API (K80 stack).
# Enable after services.aceK80 is live on ace:
#   1. Uncomment import in nixos/caddy/default.nix
#   2. nixos-rebuild switch --flake /etc/nixos#ace

{ config, ... }:

{
  services.caddy = {
    virtualHosts."ai.prestonhager.com".extraConfig = ''
      # OpenClaw gateway (default port 18789, loopback)
      handle /ollama/* {
        uri strip_prefix /ollama
        reverse_proxy http://127.0.0.1:11434
      }
      handle {
        reverse_proxy http://127.0.0.1:18789
      }
    '';
  };
}
