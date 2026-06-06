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

      # Zitadel API, OIDC, SAML endpoints
      handle {
        reverse_proxy http://127.0.0.1:9080 {
          header_up Host {host}
          header_up X-Forwarded-Proto {scheme}
          header_up X-Forwarded-Host {host}
        }
      }
    '';
  };
}