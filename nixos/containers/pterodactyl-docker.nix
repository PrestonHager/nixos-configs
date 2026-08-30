{ pkgs, ... }:

let
  version = "1.15.1";
  pterodactyPanelSrc = "https://github.com/pterodactyl/panel.git";
  forkPanelSrc = "https://github.com/PrestonHager/panel.git";

  gitConfig = pkgs.writeTextFile {
    name = "pterodactyl-gitconfig";
    destination = "/etc/gitconfig";
    text = ''
      [safe]
        directory = /var/www/pterodactyl
        directory = *
      [url "https://github.com/"]
        insteadOf = git@github.com:
      [url "https://github.com/"]
        insteadOf = ssh://git@github.com/
    '';
  };

  # Production panel tracks official Pterodactyl releases.
  panelUpdateEnvStock = {
    APP_ENVIRONMENT_ONLY = "true";
    GIT_CONFIG_SYSTEM = "/etc/gitconfig";
  };

    # Test panel uses stock Pterodactyl + upstream Blueprint (see pterodactyl-test-blueprint.nix).
  panelUpdateEnvTest = panelUpdateEnvStock;

  waitForServices = ''
    set -e

    echo "Waiting for MariaDB at $DB_HOST..."
    until mysql -h"$DB_HOST" -P"$DB_PORT" -uroot -p"$MARIADB_ROOT_PASSWORD" -e "SELECT 1;"; do
      echo "  Waiting for DB..."
      sleep 2
    done

    echo "Creating database and user if they do not exist..."
    mysql -h"$DB_HOST" -P"$DB_PORT" -uroot -p"$MARIADB_ROOT_PASSWORD" <<EOF
CREATE DATABASE IF NOT EXISTS \`$DB_DATABASE\`;
CREATE USER IF NOT EXISTS '$DB_USERNAME'@'%' IDENTIFIED BY '$DB_PASSWORD';
GRANT ALL PRIVILEGES ON \`$DB_DATABASE\`.* TO '$DB_USERNAME'@'%' WITH GRANT OPTION;
FLUSH PRIVILEGES;
EOF

    if [ -n "$REDIS_HOST" ]; then
      echo "Redis host set: $REDIS_HOST:''${REDIS_PORT:-6379}"
      until redis-cli -h "$REDIS_HOST" -p "''${REDIS_PORT:-6379}" ping | grep -q PONG; do
        echo "  Waiting for Redis..."
        sleep 2
      done
    else
      echo "No Redis host configured. Skipping Redis wait."
    fi
  '';

  sharedSetupLogic = ''
    if [ ! -d /var/www/pterodactyl/.git ]; then
      echo "Cloning Pterodactyl source code..."
      if [ ! -d /var/www/pterodactyl ]; then
        git clone --depth 1 --branch release/v${version} ${pterodactyPanelSrc} /var/www/pterodactyl
      else
        pushd /var/www/pterodactyl
        git init -b release/v${version}
        git remote add origin ${pterodactyPanelSrc}
        git fetch --depth=1 origin release/v${version}
        git checkout release/v${version}
        popd
      fi
      chmod -R 755 /var/www/pterodactyl/storage/* /var/www/pterodactyl/bootstrap/cache/
    fi

    cd /var/www/pterodactyl

    if [ ! -f /var/www/pterodactyl/.env ]; then
      if [ -f /var/www/pterodactyl/.env.initial ]; then
        echo "Copying initial .env file..."
        cp .env.initial .env
      else
        echo "Creating example .env file, please change with your values"
        cp .env.example .env
      fi
      chown pterodactyl:pterodactyl .env
      chmod 644 .env
    fi

    if [ ! -f .setup_done ]; then
      echo "Running initial setup..."

      /bin/wait-for-services

      echo "Installing dependencies..."
      composer install --no-dev --optimize-autoloader

      if ! grep -q "APP_KEY=" .env || grep -q "APP_KEY=$" .env; then
        echo "Generating APP_KEY..."
        php artisan key:generate --force
      fi

      echo "Running database migrations..."
      [ ! -f .env ] || export $(grep -v '^#' .env | xargs)
      php artisan migrate --seed --force

      echo "Making initial user..."
      if [ -z "$PTERODACTYL_ADMIN_PASSWORD" ]; then
        PTERODACTYL_ADMIN_PASSWORD=$(openssl rand -base64 12)
        echo "Generated random admin password: $PTERODACTYL_ADMIN_PASSWORD"
      fi
      php artisan p:user:make \
        --email="''${PTERODACTYL_ADMIN_EMAIL:-admin@localhost}" \
        --username="''${PTERODACTYL_ADMIN_USERNAME:-admin}" \
        --name-first="''${PTERODACTYL_ADMIN_FIRST_NAME:-Admin}" \
        --name-last="''${PTERODACTYL_ADMIN_LAST_NAME:-User}" \
        --password="$PTERODACTYL_ADMIN_PASSWORD" \
        --admin=1
      echo "Created new admin user with email $PTERODACTYL_ADMIN_EMAIL"

      touch .setup_done
      echo "Setup complete."
    else
      echo "Setup already completed. Skipping."
      [ ! -f .env ] || export $(grep -v '^#' .env | xargs)
    fi
  '';

  schedulerScript = pkgs.writeScriptBin "scheduler-entrypoint" ''
    #!/bin/env bash
    echo "Running Pterodactyl scheduler..."
    while true; do
      php /var/www/pterodactyl/artisan schedule:run >> /dev/null 2>&1
      sleep 60
    done
  '';
  queueScript = pkgs.writeScriptBin "queue-entrypoint" ''
    #!/bin/env bash
    echo "Running Pterodactyl queue worker..."
    until php /var/www/pterodactyl/artisan queue:work --queue=high,standard,low --sleep=3 --tries=3 >> /dev/null 2>&1; do
      echo "Queue worker failed, restarting..."
      sleep 5
    done
  '';

  waitScript = pkgs.writeScriptBin "wait-for-services" ''
    #!/bin/env bash
    ${waitForServices}
  '';

  setupScript = pkgs.writeScriptBin "setup-entrypoint" ''
    #!/bin/env bash

    set -e
    ${sharedSetupLogic}
  '';

  runtimeScript = pkgs.writeScriptBin "runtime-entrypoint" ''
    #!/bin/env bash

    set -e
    cd /var/www/pterodactyl

    if [ ! -f .setup_done ]; then
      echo "No setup detected, running setup automatically..."
      ${sharedSetupLogic}
    fi

    echo "Starting scheduler..."
    ${schedulerScript}/bin/scheduler-entrypoint &

    echo "Starting queue worker..."
    ${queueScript}/bin/queue-entrypoint &

    echo "Starting PHP-FPM listening on $PHP_FPM_LISTEN..."
    exec php-fpm --nodaemonize -y /etc/php-fpm.conf
  '';

  phpIni = pkgs.writeTextFile {
    name = "pterodactyl-php.ini";
    destination = "/etc/php83/php.ini";
    text = ''
      [PHP]
      realpath_cache_size = 4096K
      realpath_cache_ttl = 600

      [opcache]
      opcache.enable = 1
      opcache.enable_cli = 0
      opcache.memory_consumption = 256
      opcache.interned_strings_buffer = 16
      opcache.max_accelerated_files = 20000
      opcache.validate_timestamps = 1
      opcache.revalidate_freq = 2
      opcache.jit = 1255
      opcache.jit_buffer_size = 64M
    '';
  };

  phpFpmConf = pkgs.writeTextFile rec {
    name = "php-fpm.conf";
    destination = "/etc/${name}";
    text =''
      [global]
      error_log = /proc/self/fd/2
      daemonize = no

      pid = /run/php-fpm/php-fpm.pid
      include = /etc/php-fpm.d/*.conf
    '';
  };
  phpFpmWwwConf = pkgs.writeTextFile rec {
    name = "www.conf";
    destination = "/etc/php-fpm.d/${name}";
    text = ''
      [www]
      clear_env = no

      user = pterodactyl
      group = pterodactyl

      listen = 0.0.0.0:9000
      listen.owner = pterodactyl
      listen.group = pterodactyl
      listen.mode = 0775
      listen.backlog = 511

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

  sharedPackages = [
    waitScript
    phpIni
    phpFpmConf
    phpFpmWwwConf
    gitConfig
    schedulerScript
    queueScript
    pkgs.coreutils
    pkgs.procps
    pkgs.bash
    pkgs.php83
    pkgs.php83Packages.composer
    pkgs.php83Extensions.gd
    pkgs.php83Extensions.mbstring
    pkgs.php83Extensions.bcmath
    pkgs.php83Extensions.xml
    pkgs.php83Extensions.curl
    pkgs.php83Extensions.zip
    pkgs.php83Extensions.opcache
    pkgs.php83Extensions.pdo
    pkgs.php83Extensions.pdo_mysql
    pkgs.php83Extensions.redis
    pkgs.redis
    pkgs.mariadb.client
    pkgs.gnugrep
    pkgs.gnused
    pkgs.cacert
    pkgs.git
    pkgs.openssh
    pkgs.curl
    pkgs.gnutar
    # Blueprint framework build tools
    pkgs.nodejs_22
    pkgs.yarn
    pkgs.zip
    pkgs.unzip
    pkgs.ncurses
    pkgs.gawk
    pkgs.diffutils
    pkgs.findutils
    pkgs.gzip
    pkgs.cron
    pkgs.systemd
    pkgs.nettools
    pkgs.busybox
  ];
in
{
  inherit panelUpdateEnvStock panelUpdateEnvTest forkPanelSrc version;

  setupImage = pkgs.dockerTools.buildImage {
    name = "pterodactyl-setup";
    tag = "v${version}";
    fromImageName = "alpine";
    fromImageTag = "latest";

    copyToRoot = pkgs.buildEnv {
      name = "setup-root";
      paths = sharedPackages ++ [
        setupScript
      ];
      pathsToLink = [ "/bin" "/usr/bin" "/etc" ];
    };

    config = {
      Entrypoint = [ "/bin/setup-entrypoint" ];
      Volumes = {
        "/tmp" = {};
        "/var/log" = {};
        "/var/www/pterodactyl" = {};
      };
      Env = [
        "SSL_CERT_FILE=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt"
        "GIT_CONFIG_SYSTEM=/etc/gitconfig"
      ];
    };
  };

  runtimeImage = pkgs.dockerTools.buildImage {
    name = "pterodactyl-runtime";
    tag = "v${version}";
    fromImageName = "alpine";
    fromImageTag = "latest";

    copyToRoot = pkgs.buildEnv {
      name = "runtime-root";
      paths = sharedPackages ++ [
        runtimeScript
      ];
      pathsToLink = [ "/bin" "/usr/bin" "/etc" ];
    };

    config = {
      Entrypoint = [ "/bin/runtime-entrypoint" ];
      ExposedPorts = { "9000/tcp" = {}; };
      Volumes = {
        "/tmp" = {};
        "/var/log" = {};
        "/var/www/pterodactyl" = {};
      };
      Env = [
        "SSL_CERT_FILE=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt"
        "PHP_FPM_LISTEN=/run/php-fpm/php-fpm.sock"
        "GIT_CONFIG_SYSTEM=/etc/gitconfig"
      ];
    };
  };
}
