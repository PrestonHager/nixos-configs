{ config, ... }:

{
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

      # Loftia wiki Phorge instance
      "phorge.loftiawiki.org" = (SSL // {
        locations."/" = {
          proxyPass = "http://127.0.0.1:8091/";
          proxyWebsockets = true;
          extraConfig = ''
            allow 192.168.8.0/24;
            deny all;
          '';
        };
      });
      "phorge.loftiawiki.com" = (SSL // {
        locations."/" = {
          extraConfig = ''
            return 301 $scheme://phorge.loftiawiki.org$request_uri;
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

      # Wireguard Portal
      "wg.prestonhager.com" = (SSL // {
        locations."/" = {
          proxyPass = "http://localhost:8080/";
          proxyWebsockets = true;
        };
      });

      # Games from pterodactyl panel
      "pong.prestonhager.com" = (SSL // {
        locations."/" = {
          proxyPass = "http://192.168.5.6:9001/";
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
          proxyPass = "http://192.168.5.6:80/";
          proxyWebsockets = true;
        };
      });

      "node-01.lc1.nm.us.prestonhager.com" = (SSL // {
        locations."/" = {
          proxyPass = "http://192.168.5.6:443";
          proxyWebsockets = true;
        };
      });
      "node-02.lc1.nm.us.prestonhager.com" = (SSL // {
        locations."/" = {
          proxyPass = "http://192.168.5.6:443";
          proxyWebsockets = true;
        };
      });
    };
  };
}

