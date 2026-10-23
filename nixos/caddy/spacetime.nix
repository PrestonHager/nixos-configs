{ config, ... }:

# SpacetimeDB: clients (subscribe, reducer calls, identities) are public;
# everything that changes or inspects a database from outside is
# LAN/tailnet/VPN only: publishing (POST/PUT /v1/database[/<name>] and the
# older /v1/publish), deleting (DELETE), renaming (/names), SQL, logs and
# energy.
let
  caddyLib = import ./lib.nix;
  proxy = ''
    reverse_proxy http://localhost:8084
  '';
in
{
  services.caddy = {
    virtualHosts."spacetime.prestonhager.com".extraConfig = ''
      ${caddyLib.securityHeaders}
      ${caddyLib.lanMatcher}

      @spacetimeManage path_regexp spacetimeManage ^/v1/(publish|energy)(/|$)|^/v1/database/[^/]+/(sql|logs|names)(/|$)
      handle @spacetimeManage {
        ${caddyLib.lanGuard proxy}
      }

      @spacetimeWrite {
        method POST PUT PATCH DELETE
        path_regexp spacetimeWrite ^/v1/database(/[^/]+)?/?$
      }
      handle @spacetimeWrite {
        ${caddyLib.lanGuard proxy}
      }

      handle {
        ${proxy}
      }
    '';
  };
}
