{ config, ... }:

{
  services.caddy = {
    virtualHosts."loftiawiki.org".extraConfig = ''
      root * /mw/html
      @dotFiles {
        path */.*
        not path /.well-known/*
      }
      respond @dotFiles 404
      @mediawikiPrettyUrls {
        not path */.*
        not path /api.php
        not path /rest.php
        not path /index.php
      }
      rewrite @mediawikiPrettyUrls /index.php?{query}
      file_server
      php_fastcgi http://localhost:8091 {
        root /mw/html
        env SCRIPT_FILENAME /var/www/html{http.request.uri.path}
        env DOCUMENT_ROOT /var/www/html
      }
      encode zstd gzip
    '';
    virtualHosts."loftiawiki.com".extraConfig = ''
      redir https://loftiawiki.org{uri} permanent
    '';
    virtualHosts."upgrade.loftiawiki.org".extraConfig = ''
      root * /mw/mediawiki-1.45.3
      @dotFiles {
        path */.*
        not path /.well-known/*
      }
      respond @dotFiles 404
      file_server
      php_fastcgi http://localhost:8101
      encode zstd gzip
    '';
  };
}