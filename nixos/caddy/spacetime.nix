{ config, ... }:

## deny non-local requests for publishing
#"/v1/publish" = {
#proxyPass = "http://localhost:8084/";
#extraConfig = ''
#allow 192.168.8.0/24;
#deny all;
#proxy_http_version 1.1;
#proxy_set_header Upgrade $http_upgrade;
#proxy_set_header Connection "upgrade";
#'';

{
  services.caddy = {
    virtualHosts."spacetime.prestonhager.com".extraConfig = ''
      @allowedSubnet {
        path /v1/publish
        remote_ip 192.168.8.0/24
        remote_ip 10.88.0.0/16
      }

      # Any request to /v1/publish
      @restrictRoute {
        path /v1/publish
      }

      # Handle: allowed subnet for /v1/publish
      handle @allowedSubnet {
        reverse_proxy http://localhost:8084
      }

      # Handle: /v1/publish but not in allowed subnet
      handle @restrictRoute {
        respond "Forbidden" 403
      }

      # Handle: everything else
      handle {
        reverse_proxy http://localhost:8084
      }
    '';
  };
}

