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
      # php_fastcgi try_files serves real files (load.php, skins/, resources/)
      # and rewrites missing paths (pretty article URLs) to index.php.
      # Do not rewrite *.php / static assets to index.php — that breaks ResourceLoader.
      php_fastcgi http://localhost:8091 {
        root /mw/html
        env SCRIPT_FILENAME /var/www/html{http.request.uri.path}
        env DOCUMENT_ROOT /var/www/html
        env PHP_VALUE "display_errors=0
        log_errors=1
        error_reporting=E_ALL & ~E_DEPRECATED & ~E_STRICT"
      }
      file_server
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
      php_fastcgi http://localhost:8101 {
        root /mw/mediawiki-1.45.3
        env SCRIPT_FILENAME /var/www/html{http.request.uri.path}
        env DOCUMENT_ROOT /var/www/html
        env PHP_VALUE "display_errors=0
        log_errors=1
        error_reporting=E_ALL & ~E_DEPRECATED & ~E_STRICT"
      }
      file_server
      encode zstd gzip
    '';
  };
}
