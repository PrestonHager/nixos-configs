{ config, ... }:

{
  services.caddy = {
    virtualHosts."loftiawiki.org".extraConfig = ''
      reverse_proxy http://localhost:8090
    '';
    virtualHosts."loftiawiki.com".extraConfig = ''
      redir https://loftiawiki.org{uri} permanent
    '';
    virtualHosts."upgrade.loftiawiki.org".extraConfig = ''
      root * /mw/mediawiki-1.45.3
      php_fastcgi http://localhost:8101
      encode zstd gzip
      @dotFiles {
        path */.*
        not path /.well-known/*
      }
    '';
  };
}

