{ config, ... }:

{
  services.caddy = {
    virtualHosts."zitadel.prestonhager.com".extraConfig = ''
      # Zitadel login UI (v2)
      handle /ui/v2/login* {
        reverse_proxy http://127.0.0.1:9081 {
          header_up Host {host}
          header_up X-Forwarded-Proto {scheme}
          header_up X-Forwarded-Host {host}
        }
      }

      # Zitadel API, OIDC, console UI (gRPC-gateway needs h2c; strip TE to avoid hangs)
      handle {
        reverse_proxy h2c://127.0.0.1:9080 {
          header_up Host {host}
          header_up X-Forwarded-Proto {scheme}
          header_up X-Forwarded-Host {host}
          header_up -TE
        }
      }
    '';
  };
}