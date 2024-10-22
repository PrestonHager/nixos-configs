{ config, ... }:

{
  # Enable the HTTP/HTTPS ports on the firewall
  networking.firewall.allowedTCPPorts = [
    80
    443
  ];

  security.acme = {
    acceptTerms = true;
    defaults.email = "admin+acme@prestonhager.com";
  };

  services.nginx = {
    enable = true;
    recommendedProxySettings = true;
    virtualHosts = let
      SSL = {
        enableACME = true;
        forceSSL = true;
      };
    in {
      "vault.prestonhager.com" = (SSL // {
        locations."/".proxyPass = "http://localhost:8081/";
        # Some settings we can't modify directly such as passing the proxy
        # headers for websockets (Upgrade and Connection).
        extraConfig = ''
          proxy_http_version 1.1;
          proxy_set_header Upgrade $http_upgrade;
          proxy_set_header Connection "upgrade";
        '';
      });

      # Pterodacyl panel
      "panel.prestonhager.com" = (SSL // {
        locations."/" = {
          proxyPass = "http://192.168.8.6:80/";
          extraConfig = ''
            proxy_http_version 1.1;
            proxy_set_header Upgrade $http_upgrade;
            proxy_set_header Connection "upgrade";
          '';
        };
      });

      "node-01.lc1.nm.us.prestonhager.com" = (SSL // {
        locations."/" = {
          proxyPass = "http://192.168.8.6:443/";
          extraConfig = ''
            proxy_http_version 1.1;
            proxy_set_header Upgrade $http_upgrade;
            proxy_set_header Connection "upgrade";
          '';
        };
      "cloud.prestonhager.com" = (SSL // {
        locations."/".proxyPass = "http://localhost:8080/";
      });
    };
  };
}

