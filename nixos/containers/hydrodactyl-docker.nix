# Runtime image for the Hydrodactyl panel (hydrodactyl-panel.nix).
#
# The panel tree comes prebuilt from the Nix store. On every start the
# entrypoint syncs it into the bind-mounted /var/www/pterodactyl (so Caddy can
# keep serving public/ from the host path), keeping .env, storage/ and
# bootstrap/cache, then migrates and starts php-fpm, the queue worker and the
# scheduler. The first start over a Pterodactyl install dumps the database
# into storage/ before Hydrodactyl's (one-way) migrations run.
{ pkgs, hydro }:

let
  inherit (hydro) version php root;

  phpIni = pkgs.writeTextFile {
    name = "hydrodactyl-php.ini";
    destination = "/etc/php.d/90-hydrodactyl.ini";
    text = ''
      memory_limit = 512M
      upload_max_filesize = 100M
      post_max_size = 100M
      realpath_cache_size = 4096K
      realpath_cache_ttl = 600
      opcache.enable = 1
      opcache.enable_cli = 0
      opcache.memory_consumption = 256
      opcache.interned_strings_buffer = 16
      opcache.max_accelerated_files = 20000
      ; Code only changes on a new image, which restarts php-fpm.
      opcache.validate_timestamps = 0
      opcache.jit = 1255
      opcache.jit_buffer_size = 64M
    '';
  };

  phpFpmConf = pkgs.writeTextFile {
    name = "hydrodactyl-php-fpm.conf";
    destination = "/etc/php-fpm.conf";
    text = ''
      [global]
      error_log = /proc/self/fd/2
      daemonize = no

      [www]
      clear_env = no
      listen = 0.0.0.0:9000
      pm = dynamic
      pm.max_children = 40
      pm.start_servers = 8
      pm.min_spare_servers = 4
      pm.max_spare_servers = 16
      pm.max_requests = 500
      request_slowlog_timeout = 5s
      slowlog = /proc/self/fd/2
      chdir = /var/www/pterodactyl/public
      catch_workers_output = yes
      php_admin_value[error_log] = /proc/self/fd/2
      php_admin_flag[log_errors] = on
    '';
  };

  entrypoint = pkgs.writeShellScriptBin "hydrodactyl-entrypoint" ''
    set -euo pipefail
    dest=/var/www/pterodactyl
    marker="$dest/.hydrodactyl-build"
    cd "$dest"

    # .env: production mounts its sops secret as .env.initial; the test panel
    # mounts its own .env directly.
    if [ ! -s .env ] && [ -f .env.initial ]; then
      cp .env.initial .env
    fi

    echo "hydrodactyl: waiting for MariaDB and Valkey..."
    until mariadb -h"''${DB_HOST:-127.0.0.1}" -P"''${DB_PORT:-3306}" -uroot -p"$MARIADB_ROOT_PASSWORD" -e 'SELECT 1' >/dev/null 2>&1; do sleep 2; done
    mariadb -h"''${DB_HOST:-127.0.0.1}" -P"''${DB_PORT:-3306}" -uroot -p"$MARIADB_ROOT_PASSWORD" <<EOF
    CREATE DATABASE IF NOT EXISTS \`$DB_DATABASE\`;
    CREATE USER IF NOT EXISTS '$DB_USERNAME'@'%' IDENTIFIED BY '$DB_PASSWORD';
    GRANT ALL PRIVILEGES ON \`$DB_DATABASE\`.* TO '$DB_USERNAME'@'%';
    FLUSH PRIVILEGES;
    EOF
    until redis-cli -h "''${REDIS_HOST:-127.0.0.1}" -p "''${REDIS_PORT:-6379}" ping 2>/dev/null | grep -q PONG; do sleep 2; done

    if [ "$(cat "$marker" 2>/dev/null || true)" != "${root}" ]; then
      # Its own marker, so a later failure in this script never re-dumps on
      # every container restart.
      if [ ! -f "$marker" ] && [ -f artisan ] && [ ! -f storage/hydrodactyl-migration/.dumped ]; then
        # First Hydrodactyl start over an existing (Pterodactyl) panel: keep a
        # dump, since switching back needs the pre-migration schema.
        mkdir -p storage/hydrodactyl-migration
        dump="storage/hydrodactyl-migration/pre-hydrodactyl-$(date -u +%Y%m%dT%H%M%SZ).sql.gz"
        echo "hydrodactyl: first start over an existing panel, dumping database to $dump"
        mariadb-dump -h"''${DB_HOST:-127.0.0.1}" -P"''${DB_PORT:-3306}" -uroot -p"$MARIADB_ROOT_PASSWORD" \
          --single-transaction --routines --triggers "$DB_DATABASE" | gzip > "$dump.tmp"
        mv "$dump.tmp" "$dump"
        cp .env "storage/hydrodactyl-migration/env-$(date -u +%Y%m%dT%H%M%SZ)"
        touch storage/hydrodactyl-migration/.dumped
      fi

      echo "hydrodactyl: installing panel ${version} from ${root}"
      rsync -a --delete --chmod=Du+w,Fu+w \
        --exclude=/.env --exclude=/.env.initial --exclude=/storage/ \
        --exclude=/bootstrap/cache/ --exclude=/.hydrodactyl-build \
        "${root}/" "$dest/"
    fi

    mkdir -p storage/app/public storage/framework/cache/data storage/framework/sessions \
      storage/framework/views storage/logs bootstrap/cache
    rm -f bootstrap/cache/*.php

    # Existing users were migrated to full locale codes; new ones (SSO
    # sign-ups included) get app.locale, which must be one of them too.
    # In place: on the test panel .env is a bind-mounted file, which sed -i
    # (write temp + rename) cannot replace.
    if grep -q '^APP_LOCALE=en$' .env; then
      sed 's/^APP_LOCALE=en$/APP_LOCALE=en-US/' .env > /tmp/env.$$
      cat /tmp/env.$$ > .env
      rm -f /tmp/env.$$
    fi

    php artisan migrate --force
    php artisan config:cache
    php artisan route:cache
    php artisan view:cache
    php artisan event:cache
    php artisan queue:restart || true
    echo "${root}" > "$marker"

    (while true; do php artisan schedule:run >/dev/null 2>&1; sleep 60; done) &
    (until php artisan queue:work --queue=high,standard,low --sleep=3 --tries=3 >/dev/null 2>&1; do sleep 5; done) &

    echo "hydrodactyl: starting php-fpm"
    exec php-fpm --nodaemonize --fpm-config /etc/php-fpm.conf
  '';
in
{
  inherit version;

  runtimeImage = pkgs.dockerTools.buildLayeredImage {
    name = "hydrodactyl-runtime";
    tag = "v${version}";
    contents = [
      entrypoint
      php
      phpIni
      phpFpmConf
      pkgs.bash
      pkgs.coreutils
      pkgs.findutils
      pkgs.gnugrep
      pkgs.gnused
      pkgs.gzip
      pkgs.rsync
      pkgs.procps
      pkgs.mariadb.client
      pkgs.redis
      # Port-forward extension drives the router over SSH.
      pkgs.openssh
      pkgs.cacert
      pkgs.tzdata
    ];
    config = {
      Entrypoint = [ "/bin/hydrodactyl-entrypoint" ];
      ExposedPorts."9000/tcp" = { };
      Env = [
        "SSL_CERT_FILE=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt"
        # The php wrapper's own dir (extension= lines) plus ours; replacing it
        # would load PHP without any extensions.
        "PHP_INI_SCAN_DIR=${php}/lib:/etc/php.d"
        "TZDIR=${pkgs.tzdata}/share/zoneinfo"
      ];
    };
  };
}
