{ config, ... }:

{
  # Enable the HTTP/HTTPS ports on the firewall
  networking.firewall.allowedTCPPorts = [
    80
    443
    8080
  ];

  security.acme = {
    acceptTerms = true;
    defaults.email = "admin+acme@prestonhager.com";
    certs = {
      "portunus.prestonhager.com" = {
        postRun = ''
          #!/usr/bin/env bash
          # Ensure Let's Encrypt root certificates are downloaded
          curl -s -o /etc/ssl/certs/isrgrootx1.pem https://letsencrypt.org/certs/isrgrootx1.pem
          curl -s -o /etc/ssl/certs/isrgrootx2.pem https://letsencrypt.org/certs/isrg-root-x2.pem
          # Merge the chain.pem with the ISRG root certificates
          cat chain.pem /etc/ssl/certs/isrgrootx1.pem /etc/ssl/certs/isrgrootx2.pem > ca.merged.pem
          cat chain.pem /etc/ssl/certs/isrgrootx1.pem > ca.merged.pem
          chown acme:nginx ca.merged.pem
          chmod 640 ca.merged.pem
        '';
      };
    };
  };

  services.nginx = {
    enable = true;
    recommendedProxySettings = true;
    recommendedTlsSettings = true;
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
      "cloud.prestonhager.com" = (SSL // {
        locations = {
          "/" = {
            proxyPass = "http://localhost:8083/";
            proxyWebsockets = true;
            extraConfig = ''
              proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
              proxy_set_header X-Forwarded-Port $server_port;
              proxy_set_header X-Forwarded-Scheme $scheme;
              proxy_set_header X-Forwarded-Proto $scheme;
              proxy_set_header X-Real-IP $remote_addr;
              proxy_set_header Host $host;
              proxy_set_header Early-Data $ssl_early_data;
            '';
          };
        };
        extraConfig = ''
          proxy_buffering off;
          proxy_request_buffering off;

          client_max_body_size 0;
          client_body_buffer_size 512k;
          proxy_read_timeout 86400s;

          location /.well-known/carddav {
            return 301 $scheme://$host/remote.php/dav;
          }
          location /.well-known/caldav {
            return 301 $scheme://$host/remote.php/dav;
          }
          location ^~ /.well-known {
            return 301 $scheme://$host/index.php$request_uri;
          }
          proxy_hide_header Upgrade;
        '';
      });

      "loftiawiki.org" = (SSL // {
        locations."/" = {
          proxyPass = "http://127.0.0.1:8090/";
          proxyWebsockets = true;
        };
      });
      "loftiawiki.com" = (SSL // {
        locations."/" = {
          extraConfig = ''
            return 301 $scheme://loftiawiki.org$request_uri;
          '';
        };
      });

      "portunus.prestonhager.com" = (SSL // {
        locations."/" = {
          proxyPass = "http://localhost:8086/";
          proxyWebsockets = true;
          extraConfig = ''
            allow 192.168.8.1/24;
            deny all;
          '';
        };
      });

      "test.sui.prestonhager.com" = (SSL // {
        locations."/".proxyPass = "http://localhost:9000/";
      });
      "faucet.test.sui.prestonhager.com" = (SSL // {
        locations."/".proxyPass = "http://localhost:9123/";
      });
      "indexer.test.sui.prestonhager.com" = (SSL // {
        locations."/".proxyPass = "http://localhost:9124/";
      });

      # Spacetime DB Backend
      "spacetime.prestonhager.com" = (SSL // {
        locations = {
          "/" = {
            proxyPass = "http://localhost:8084/";
            proxyWebsockets = true;
          };
          # deny non-local requests for publishing
          "/v1/publish" = {
            proxyPass = "http://localhost:8084/";
            extraConfig = ''
              allow 192.168.8.0/24;
              deny all;
              proxy_http_version 1.1;
              proxy_set_header Upgrade $http_upgrade;
              proxy_set_header Connection "upgrade";
            '';
          };
        };
      });

      # Jellyfin server
      "jellyfin.prestonhager.com" = (SSL // {
        locations."/" = {
          proxyPass = "http://localhost:8096/";
          proxyWebsockets = true;
        };
      });

      # Games from pterodactyl panel
      "pong.prestonhager.com" = (SSL // {
        locations."/" = {
          proxyPass = "http://192.168.8.6:9001/";
          extraConfig = ''
            proxy_http_version 1.1;
            proxy_set_header Upgrade $http_upgrade;
            proxy_set_header Connection "upgrade";
          '';
        };
      });

      # Pterodacyl panel
      "panel.prestonhager.com" = (SSL // {
        locations."/" = {
          proxyPass = "http://192.168.8.6:80/";
          proxyWebsockets = true;
        };
      });

      "node-01.lc1.nm.us.prestonhager.com" = (SSL // {
        locations."/" = {
          proxyPass = "http://192.168.8.6:443";
          proxyWebsockets = true;
        };
      });
    };
  };
}

