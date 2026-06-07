{ config, lib, ... }:

let
  websocketHosts = {
    "nova.lc1.nm.us.prestonhager.com" = {
      ip = "192.168.5.7";
      port = "443";
    };
    "crux.lc1.nm.us.prestonhager.com" = {
      ip = "192.168.5.6";
      port = "443";
    };
  };

  phpBlock = { hostPath, containerPath, phpPort ? "9001" }:
    ''
      rewrite * /index.php?{query}
      php_fastcgi localhost:${phpPort} {
        root ${hostPath}
        index index.php
        env SCRIPT_FILENAME ${containerPath}/public/index.php
        env DOCUMENT_ROOT ${containerPath}/public
        env PHP_VALUE "upload_max_filesize = 100M
        post_max_size = 100M"
        env HTTP_PROXY ""
        env HTTPS "on"
        read_timeout 300s
        dial_timeout 300s
        write_timeout 300s
      }
    '';

  panelSite = { hostPath, containerPath, phpPort ? "9001", oauth ? false }:
    ''
      root * ${hostPath}
      encode gzip

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

      ${lib.optionalString oauth ''
      handle /oauth2/* {
        reverse_proxy 127.0.0.1:4180
      }

      handle /auth/zitadel* {
        redir https://panel.prestonhager.com/oauth2/start?rd={query.rd} 302
      }
      ''}

      @existing file {path}
      handle @existing {
        file_server
      }

      ${if oauth then ''
      @local_auth {
        path /api/*
        path /auth/login*
        path /auth/password*
      }

      handle @local_auth {
        ${phpBlock { inherit hostPath containerPath phpPort; }}
      }

      handle {
        forward_auth 127.0.0.1:4180 {
          uri /oauth2/auth
          copy_headers X-Auth-Request-User X-Auth-Request-Email X-Auth-Request-Groups
        }
        request_header X-Auth-Username {http.auth.header.X-Auth-Request-User}
        request_header X-Auth-Email {http.auth.header.X-Auth-Request-Email}
        request_header X-Auth-Groups {http.auth.header.X-Auth-Request-Groups}
        ${phpBlock { inherit hostPath containerPath phpPort; }}
      }
      '' else ''
      handle {
        ${phpBlock { inherit hostPath containerPath phpPort; }}
      }
      ''}
    '';

in {
  users.users.caddy.extraGroups = [ "pterodactyl" ];

  services.caddy = {
    virtualHosts = {
      "panel.prestonhager.com".extraConfig = panelSite {
        hostPath = "/pterodactyl/html/public";
        containerPath = "/var/www/pterodactyl";
        oauth = true;
      };
      "test.panel.prestonhager.com".extraConfig = panelSite {
        hostPath = "/pterodactyl-test/public";
        containerPath = "/var/www/pterodactyl";
        phpPort = "9002";
      };
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
