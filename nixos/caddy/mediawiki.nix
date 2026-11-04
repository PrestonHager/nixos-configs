{ config, lib, pkgs, ... }:

let
  caddyLib = import ./lib.nix;
  # Served by Caddy (MediaWiki would otherwise redirect /robots.txt to the
  # wiki page "Robots.txt"). Every crawler, search and AI alike, gets one
  # group: crawl articles, files and the CSS/JS needed to render them; skip
  # the endless edit/history/diff/special-page URL variants. Googlebot obeys
  # only the most specific group naming it, so the named agents share these
  # rules instead of getting groups of their own.
  # To keep AI search but opt out of model training, give GPTBot,
  # Google-Extended, Applebot-Extended and CCBot their own "Disallow: /" group.
  robotsTxt = pkgs.writeTextDir "robots.txt" ''
    # Loftia Community Wiki: search engines and AI crawlers are welcome.
    User-agent: *
    User-agent: Googlebot
    User-agent: Googlebot-Image
    User-agent: Bingbot
    User-agent: DuckDuckBot
    User-agent: Applebot
    User-agent: Google-Extended
    User-agent: Applebot-Extended
    User-agent: GPTBot
    User-agent: OAI-SearchBot
    User-agent: ChatGPT-User
    User-agent: ClaudeBot
    User-agent: Claude-SearchBot
    User-agent: Claude-User
    User-agent: PerplexityBot
    User-agent: Perplexity-User
    User-agent: CCBot
    Allow: /
    Allow: /load.php
    Allow: /img_auth.php/
    Allow: /skins/
    Allow: /resources/
    Allow: /extensions/
    Disallow: /index.php
    Disallow: /api.php
    Disallow: /rest.php
    Disallow: /Special:
    Disallow: /Special%3A
    Disallow: /MediaWiki:
    Disallow: /*?action=
    Disallow: /*&action=
    Disallow: /*?oldid=
    Disallow: /*&oldid=
    Disallow: /*?diff=
    Disallow: /*&diff=
    Disallow: /*?curid=
    Disallow: /*?printable=
    Disallow: /*&printable=
    Disallow: /*?veaction=
    Disallow: /*&veaction=

    Sitemap: https://loftiawiki.org/sitemap.xml
  '';
  # Never serve the web installer, backups, logs, or anything that is only
  # meant for the CLI. A LocalSettings.php.bak once leaked every secret
  # this way, and debug.log leaked session data. Case-sensitive on purpose:
  # articles live at /$1 with a capitalised first letter, so "/Maintenance"
  # is a page title while "/maintenance/" is the script directory. Paths
  # with a ":" are namespaced titles (File:Foo.zip) and are left alone.
  # Uploads are exempt: img_auth.php serves only the upload directory and
  # enforces read rights itself, and without the exemption every uploaded
  # .zip/.gz/.tar/.sql/.log file 404s (/img_auth.php/a/ab/Foo.zip matched).
  # /images/ is redirected to img_auth.php before this matcher runs anyway.
  privatePaths = ''
    @private {
      path_regexp private ^/(mw-config|cache|maintenance|tests|sql|vendor/composer)(/|$)|^/composer\.|^/LocalSettings\.php.|^/[^:]*(\.(log|bak|old|orig|swp|sql|gz|tar|zip)|~)$
      not path /img_auth.php/* /images/* /Images/*
    }
    respond @private 404
  '';
in
{
  services.caddy = {
    virtualHosts."loftiawiki.org".extraConfig = ''
      ${caddyLib.securityHeaders}
      root * /mw/html
      @dotFiles {
        path */.*
        not path /.well-known/*
      }
      respond @dotFiles 404
      handle /robots.txt {
        root * ${robotsTxt}
        header Content-Type "text/plain; charset=utf-8"
        file_server
      }
      # Written daily by mediawiki-sitemap.service (nixos/containers/mediawiki.nix).
      rewrite /sitemap.xml /sitemap/sitemap-index-loftiawiki.xml
      # Uploads live in /mw/images, which is mounted only inside the container,
      # so file_server can't see them. MediaWiki serves them through
      # img_auth.php ($wgUploadPath), which also enforces the private-wiki read
      # rights. Send old /images/ links, and the /Images/ title redirect that
      # index.php turns them into, to the same place.
      @uploads path_regexp uploads ^/[Ii]mages/(.*)$
      redir @uploads /img_auth.php/{re.uploads.1} permanent
      ${privatePaths}
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
    # Only while the mediawiki-upgrade pod exists (nixos/containers/mediawiki.nix);
    # otherwise this vhost just 502s and its probe fails.
    virtualHosts."upgrade.loftiawiki.org" = lib.mkIf config.homelab.mediawiki.enableUpgrade {
      extraConfig = ''
        root * /mw/mediawiki-1.45.3
        # Staging copy used only while upgrading: LAN admins only, and the same
        # private-path rules as the production vhost above.
        # No handle blocks in this site, so respond (ordered before
        # php_fastcgi/file_server) runs first. Ranges: lib.nix lanRanges.
        @notLan not remote_ip ${caddyLib.lanRangesStr}
        respond @notLan 403
        @dotFiles {
          path */.*
          not path /.well-known/*
        }
        respond @dotFiles 404
        ${privatePaths}
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
  };
}
