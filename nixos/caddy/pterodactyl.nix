{ config, ... }:

let
  websocketHosts = {
    "nova.lc1.nm.us.prestonhager.com" = {
      ip = "192.168.8.46";
      port = "443";
    };
    "crux.lc1.nm.us.prestonhager.com" = {
      ip = "192.168.8.6";
      port = "443";
    };
  };
in {
  # Add caddy to the pterodactyl user group so it can access the files
  users.users.caddy.extraGroups = [ "pterodactyl" ];

  services.caddy = {
    virtualHosts = {
      "panel.prestonhager.com".extraConfig = ''
        root * /pterodactyl/html/public

        file_server

        php_fastcgi localhost:9001 {
            root /pterodactyl/html/public
            index index.php

            env SCRIPT_FILENAME /var/www/pterodactyl/public{path}
            env DOCUMENT_ROOT /var/www/pterodactyl/public

            env PHP_VALUE "upload_max_filesize = 100M
            post_max_size = 100M"
            env HTTP_PROXY ""
            env HTTPS "on"

            read_timeout 300s
            dial_timeout 300s
            write_timeout 300s
        }

        header Strict-Transport-Security "max-age=16768000; preload;"
        header X-Content-Type-Options "nosniff"
        header X-XSS-Protection "1; mode=block;"
        header X-Robots-Tag "none"
        header Content-Security-Policy "frame-ancestors 'self'"
        header X-Frame-Options "DENY"
        header Referrer-Policy "same-origin"

        request_body {
            max_size 100m
        }

        respond /.ht* 403
      '';
    } // builtins.mapAttrs (websocketHost: websocketConfig: {
      extraConfig = ''
        @ws path_regexp wsSuffix .*/ws(/.*)?$
        reverse_proxy @ws https://${websocketHost}:${websocketConfig.port} {
          header_up Host {host}
          header_up X-Real-IP {remote}
          header_up X-Forwarded-Port {server_port}

          header_up Connection {http.request.header.Connection}
          header_up Upgrade {http.request.header.Upgrade}

          transport http {
            tls
            read_timeout 0s
            write_timeout 0s
            dial_timeout 30s
          }
        }
        reverse_proxy https://${websocketHost}:${websocketConfig.port}
      '';
    }) websocketHosts;
  };
}

