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
      reverse_proxy http://localhost:8084

      # Restrict /v1/publish by default
      @restrictRoute {
        path /v1/publish
      }

      # Allow only a subnet to access /v1/publish
      @allowedSubnet {
        path /v1/publish
        remote_ip 192.168.8.0/24
      }

      respond @restrictRoute "Forbidden" 403
      reverse_proxy @allowedSubnet http://localhost:8084
    '';
  };
}

